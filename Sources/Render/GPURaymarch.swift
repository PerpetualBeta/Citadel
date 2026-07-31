// Citadel — the SDF shape library.
//
// Despite the file name, there is no raymarcher here any more. This was the GPU SDF renderer's
// Metal kernel plus the Swift that fed it; the renderer was retired on 2026-07-29 (RasterRenderer
// replaced it, GPUWorldRenderer deleted), and on 2026-07-29 the kernel itself went too — 1,701
// lines of MSL and its pipeline builder, once their last caller (an obsolete billboard-mock
// harness) was retired with it.
//
// What remains, and why the rasteriser cannot do without it — it makes ~34 calls in here:
//
//   • the SHAPE LIBRARY: furnitureShapes (every prop in the game, and furnitureFootprint derives
//     the colliders from it, so what you walk into matches what you see), itemShapes, socketShapes,
//     mineShapes, pipeRunShapes, tapeDeckShapes, flushToWall, and the iBox/iSphere/iCone/iCylinder
//     constructors the shapes are written in.
//   • SHARED SCENE DATA: GShape, GPULight, FireEmitter, gatherDynLights (the transient combat
//     lights), gatherFireEmitters, packProjectiles, projColor/projRadius, wallEmissive, puddleField.
//   • buildDistanceField — the rasteriser samples this wall-distance field to trim a creature's
//     swaying limbs at a wall face instead of letting them merge into a corner.
//   • makeTextureArray, bestCorridorView.
//
// The shapes are authored in PROP-LOCAL space (local +Z is the piece's front, y=0 its footing), a
// convention inherited from the SDF instance renderer and still honoured by the rasteriser's
// tessellator — which is why that history is worth knowing even though the marcher is gone.
//
// Renaming this file to match what it is would be honest; it is also pure churn, so it waits on
// Jonathan's word.

import Foundation
import Metal
import simd

enum GPURaymarch {
    static let sub = 8        // distance-field samples per cell (wall-face crispness)


    // ── Euclidean distance transform (Felzenszwalb & Huttenlocher, squared) ────
    private static func edt1d(_ f: inout [Float], _ n: Int, _ stride: Int, _ off: Int) {
        var d = [Float](repeating: 0, count: n)
        var v = [Int](repeating: 0, count: n)
        var z = [Float](repeating: 0, count: n + 1)
        var k = 0
        v[0] = 0; z[0] = -.greatestFiniteMagnitude; z[1] = .greatestFiniteMagnitude
        @inline(__always) func fv(_ q: Int) -> Float { f[off + q * stride] }
        for q in 1..<n {
            var s = ((fv(q) + Float(q * q)) - (fv(v[k]) + Float(v[k] * v[k]))) / Float(2 * q - 2 * v[k])
            while s <= z[k] {
                k -= 1
                s = ((fv(q) + Float(q * q)) - (fv(v[k]) + Float(v[k] * v[k]))) / Float(2 * q - 2 * v[k])
            }
            k += 1; v[k] = q; z[k] = s; z[k + 1] = .greatestFiniteMagnitude
        }
        k = 0
        for q in 0..<n {
            while z[k + 1] < Float(q) { k += 1 }
            let dq = Float(q - v[k])
            d[q] = dq * dq + fv(v[k])
        }
        for q in 0..<n { f[off + q * stride] = d[q] }
    }

    /// True when a door's jambs lie on the x-axis (walls at x±1) — so its panels
    /// part along x. Otherwise they part along z.
    private static func doorSlidesAlongX(_ map: GameMap, _ cx: Int, _ cy: Int) -> Bool {
        let lx = map.inBounds(cx - 1, cy) && map.wall[map.idx(cx - 1, cy)] != 0
        let rx = map.inBounds(cx + 1, cy) && map.wall[map.idx(cx + 1, cy)] != 0
        return lx && rx
    }

    /// Through-axis centre of the ELEVATOR door plane: offset toward the open
    /// (room) side, so the rest of the cell is the car interior. 0.5 when the
    /// open side can't be determined (degrades to an ordinary centred door).
    private static func elevatorPlane(_ map: GameMap, _ cx: Int, _ cy: Int, slideX: Bool) -> Float {
        let (nx, ny) = slideX ? (cx, cy - 1) : (cx - 1, cy)       // lower-side neighbour on the through axis
        let (px, py) = slideX ? (cx, cy + 1) : (cx + 1, cy)
        let lowOpen  = map.inBounds(nx, ny) && map.wall[map.idx(nx, ny)] == 0
        let highOpen = map.inBounds(px, py) && map.wall[map.idx(px, py)] == 0
        if lowOpen == highOpen { return 0.5 }
        return lowOpen ? 0.20 : 0.80
    }

    /// Pack the live doors for the kernel: (cellX, cellY, part 0…1,
    /// flags bit0 = slides-along-x · bit1 = elevator). The kernel uses this for
    /// leaf-anchored texture UVs, so each leaf's artwork rides its sliding panel.
    static func packDoors(_ map: GameMap) -> [SIMD4<Float>] {
        map.doors.map { (i, d) in
            let cx = i % map.w, cy = i / map.w
            let slideX = doorSlidesAlongX(map, cx, cy)
            let part = min(1, d.open / GameMap.passThreshold)
            let flags = (slideX ? 1 : 0) + ((i == map.exitCell || i == map.entryCell) ? 2 : 0)
            return SIMD4(Float(cx), Float(cy), part, Float(flags))
        }
    }

    /// Distance (world units) from every sub-cell texel to the nearest wall.
    /// Doors are sampled at sub-cell resolution as CENTRE-SPLIT sliding panels: the
    /// parted gap (empty) grows from the cell centre out to the jambs as `open` →
    /// passThreshold, so the door visibly slides apart in the march / AO / shadows /
    /// reflections — not a binary pop. (The caller rebuilds the field as it slides.)
    static func buildDistanceField(_ map: GameMap) -> (data: [Float], sw: Int, sh: Int) {
        let S = sub
        let sw = map.w * S, sh = map.h * S
        let big: Float = Float(sw * sw + sh * sh)
        let invS = 1 / Float(S)
        var f = [Float](repeating: 0, count: sw * sh)
        for j in 0..<sh {
            let cy = j / S, sj = j % S
            for i in 0..<sw {
                let cx = i / S, si = i % S
                let ci = map.idx(cx, cy)
                var solid = map.wall[ci] != 0
                if solid, let d = map.doors[ci] {
                    let part = min(1, d.open / GameMap.passThreshold)        // 0 closed … 1 fully parted
                    let slideX = doorSlidesAlongX(map, cx, cy)
                    let slideC = (slideX ? Float(si) : Float(sj)) * invS + invS * 0.5   // along the wall (slide axis)
                    let thruC  = (slideX ? Float(sj) : Float(si)) * invS + invS * 0.5   // through the doorway
                    // The door is a THIN sliding panel set in the doorway — independent
                    // of the wall, NOT a full-depth block of it (which read as the wall
                    // moving). Solid only near the doorway plane (thin in the through
                    // axis) and only outside the parted centre gap, so a slim panel
                    // centre-splits and slides into the jambs while the wall stays put.
                    // The ELEVATOR (the exit cell's door) offsets its plane to the
                    // ROOM-side face: the cell interior behind the leaves becomes the
                    // car — the marine steps through, stands clear of the plane, and
                    // the doors close in front of his face for the ride down.
                    let thruMid = (ci == map.exitCell || ci == map.entryCell)
                        ? elevatorPlane(map, cx, cy, slideX: slideX) : 0.5
                    solid = (abs(thruC - thruMid) < 0.14) && (abs(slideC - 0.5) >= 0.5 * part)
                }
                f[j * sw + i] = solid ? 0 : big
            }
        }
        for j in 0..<sh { edt1d(&f, sw, 1, j * sw) }       // rows
        for i in 0..<sw { edt1d(&f, sh, sw, i) }           // columns
        for k in 0..<f.count { f[k] = sqrt(f[k]) * invS }  // texel² → world distance
        // Two channels, interleaved rg: .r = wall distance · .g = pipe-routing enable,
        // bilinear-upsampled from the cell-res map.pipe so the kernel reads it FREE
        // alongside the distance (no extra texture fetch in the march). The smooth
        // upsample gives the pipe its ~1-cell dive into the wall at every terminus.
        let pipe = map.pipe.isEmpty ? [Float](repeating: 0, count: map.w * map.h) : map.pipe
        var data = [Float](repeating: 0, count: sw * sh * 2)
        for j in 0..<sh {
            let fy = (Float(j) + 0.5) * invS - 0.5
            let y0 = max(0, min(map.h - 1, Int(floorf(fy)))), y1 = max(0, min(map.h - 1, y0 + 1))
            let ty = max(0, min(1, fy - Float(y0)))
            for i in 0..<sw {
                let fx = (Float(i) + 0.5) * invS - 0.5
                let x0 = max(0, min(map.w - 1, Int(floorf(fx)))), x1 = max(0, min(map.w - 1, x0 + 1))
                let tx: Float = max(0, min(1, fx - Float(x0)))
                let a: Float = pipe[y0 * map.w + x0]
                let b: Float = pipe[y0 * map.w + x1]
                let c: Float = pipe[y1 * map.w + x0]
                let e: Float = pipe[y1 * map.w + x1]
                let p0: Float = a + (b - a) * tx
                let p1: Float = c + (e - c) * tx
                let k = j * sw + i
                data[2 * k] = f[k]
                data[2 * k + 1] = p0 + (p1 - p0) * ty
            }
        }
        return (data, sw, sh)
    }

    struct Uniforms { var ro, fwd, right, up, params, grid, extra: SIMD4<Float>
                      var env: SIMD4<Float> = SIMD4(0, 0, 0, 0)     // extra.x = decalCount · env.xy = water-table offset · env.zw = viewmodel shape start/count
                      var vmA: SIMD4<Float> = SIMD4(0, 0, 0, 0)     // viewmodel: gun anchor.xyz + local bound radius
                      var vmB: SIMD4<Float> = SIMD4(0, 0, 0, 0)     // viewmodel: gun-local bound centre
                      var dbg: SIMD4<Float> = SIMD4(0, 0, 0, 0)     // dbg.x = 1 → disable the per-ray creature mask (harness invariant checks)
                      var tune: SIMD4<Float> = SIMD4(1, 0, 0, 0) }  // tune.x = overhead-lamp brightness gain (1 = as-authored) · tune.y = fire-emitter count (0 ⇒ fire buffer never read)
    struct GPULight { var posR, colI: SIMD4<Float> }   // posR=(x,y,z,1/r²)  colI=(r,g,b,intensity)
    struct FireEmitter { var p0, p1, p2: SIMD4<Float> }   // p0=base.xyz+baseR · p1=flowDir.xyz(unit)+length · p2=intensity,seed,kind,spare
    struct GShape { var a, b, col: SIMD4<Float>; var bnd: SIMD4<Float> = .zero }   // a.xyz/r1 ; b.xyz/r2(<0 sphere) ; col.rgb/k ; bnd = enclosing sphere
    struct GMonster { var a, b, c: SIMD4<Float> }      // a=(x,z,yaw,scale) b=(start,count,boundR,boundCY) c=(minY,…)

    /// Fill each shape's enclosing sphere (bnd = centre.xyz + radius) from its
    /// primitive params. The kernel uses it as a cheap LOWER bound on the true
    /// The frame's FIRE emitters — the flamethrower jet, explosion fireballs and burning-corpse
    /// pyres — as a single tuned set SHARED by both renderers (the raymarcher marches them as
    /// volumetric puffs; the raster path draws the same emitters as CPU puff-chains). Encoding:
    /// p0 = base.xyz + envelope radius · p1 = flow dir.xyz(unit) + length · p2 = vigor, seed, kind
    /// (1 = jet, 0 = pyre/ball), soot. Budget-capped to the jet + the 16 nearest columns.
    static func gatherFireEmitters(_ world: World) -> [FireEmitter] {
        var out: [FireEmitter] = []
        // ── the flamethrower jet ── flow horizontal down the aim; kind = 1
        let j = world.flameJet
        if j.t > 0 {
            let strength = min(1, j.t / 0.10)
            let len = max(0.5, j.reach - 0.15)
            out.append(FireEmitter(
                p0: SIMD4(j.nozzle.x, 0.5, j.nozzle.y, 0.42),      // nozzle · puff-envelope radius
                p1: SIMD4(j.dir.x, 0, j.dir.y, len),               // horizontal flow, length clipped at the wall
                p2: SIMD4(1.9 * strength, 3.1, 1, 0)))             // vigor · seed · kind=jet · smoke=0
        }
        func ss(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = max(0, min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t) }
        // ── explosion fireballs ── drum ruptures + rocket splashes: bloom fast off the flash, die to soot
        for (k, fb) in world.fireballs.enumerated() {
            let t = min(1, fb.age / fb.life)
            let expand = 1 - (1 - t) * (1 - t)
            let vigor  = 2.2 * (1 - ss(0.40, 1.0, t))
            if vigor < 0.05 { continue }
            let br = fb.size * (0.35 + 0.80 * expand)
            out.append(FireEmitter(
                p0: SIMD4(fb.pos.x, 0.30, fb.pos.y, br),
                p1: SIMD4(0, 1, 0, br * 1.4),                      // short column → a rising ball, not a tower
                p2: SIMD4(vigor, Float(k) * 7.1 + 2.0, 0, fb.soot)))
        }
        // ── corpse pyres ── a fuel fire consuming a mass: ignites at once, flares, then dies as the body spends
        let pp = world.player.pos
        var pyres: [(d: Float, e: FireEmitter)] = []
        for (i, m) in world.monsters.enumerated() where m.state == .dead && m.burn > 0 && m.burn < 1 {
            let b = m.burn
            let ignite = ss(0, 0.10, b)
            let decay  = 1 - ss(0.42, 1.0, b)
            let flare  = ignite * (0.30 + 0.70 * decay)
            let burst  = (1 - ss(0.0, 0.20, b)) * ignite
            let queen  = m.kind == .queen
            let rad = m.def.radius
            let baseR = rad * (queen ? 1.5 : 1.35) * (0.80 + 0.55 * flare + 0.40 * burst)
            let tall: Float = (queen ? 1.9 : 1.4) * (0.70 + 0.40 * flare + 0.25 * burst)
            let vigor = (queen ? 1.20 : 1.0) * (0.55 + 0.55 * flare + 0.70 * burst)
            let e = FireEmitter(
                p0: SIMD4(m.pos.x, 0.02, m.pos.y, baseR),
                p1: SIMD4(0, 1, 0, tall),
                p2: SIMD4(vigor, Float(i) * 1.7 + 0.3, 0, queen ? 1 : 0))
            let rel = m.pos - pp
            pyres.append((rel.x * rel.x + rel.y * rel.y, e))
        }
        let budget = 16 - out.count
        if pyres.count > budget { pyres.sort { $0.d < $1.d }; pyres = Array(pyres.prefix(budget)) }
        out.append(contentsOf: pyres.map { $0.e })
        return out
    }

    /// distance so the smin loop can skip shapes that provably can't move the
    /// blend — MUST run on every shape list before it becomes a GPU buffer, or
    /// a zero bnd makes the kernel skip everything (invisible geometry).
    static func fillShapeBounds(_ shapes: inout [GShape]) {
        for i in shapes.indices {
            let sh = shapes[i]
            if sh.b.w < -2.5 {            // flat-capped cylinder: radius a.w, half-height b.y
                shapes[i].bnd = SIMD4(sh.a.x, sh.a.y, sh.a.z, simd_length(SIMD2(sh.a.w, sh.b.y)))
            } else if sh.b.w < -1.5 {     // rounded box: half-extents b.xyz + rounding a.w
                shapes[i].bnd = SIMD4(sh.a.x, sh.a.y, sh.a.z, simd_length(SIMD3(sh.b.x, sh.b.y, sh.b.z)) + sh.a.w)
            } else if sh.b.w < 0 {        // sphere
                shapes[i].bnd = SIMD4(sh.a.x, sh.a.y, sh.a.z, sh.a.w)
            } else {                      // round cone: hull of sphere(a, r1) ∪ sphere(b, r2)
                let av = SIMD3(sh.a.x, sh.a.y, sh.a.z), bv = SIMD3(sh.b.x, sh.b.y, sh.b.z)
                let c = (av + bv) * 0.5
                shapes[i].bnd = SIMD4(c.x, c.y, c.z, simd_length(bv - av) * 0.5 + max(sh.a.w, sh.b.w))
            }
        }
    }

    /// Replace each monster's yaw (a.z) with cos(-yaw) and stash sin(-yaw) in
    /// the spare c.w — the kernel's local-space transform runs per STEP per
    /// PIXEL, so the two transcendentals are hoisted to once per frame here.
    /// Destructive (a.z stops being an angle): run ONCE per packed list, right
    /// before the list becomes a GPU buffer, wherever fillShapeBounds runs.
    static func fillMonsterTrig(_ mons: inout [GMonster]) {
        for i in mons.indices {
            let yaw = mons[i].a.z
            mons[i].a.z = cosf(-yaw)
            mons[i].c.w = sinf(-yaw)
        }
    }

    /// Restructure monster shape lists for the GPU: per monster, prepend GROUP
    /// entries — one enclosing sphere (bnd) per run of 8 consecutive shapes,
    /// col.w = the run's max smin k — then the shapes themselves. The kernel
    /// tests a group once and skips all 8 members wholesale; skipping is the
    /// same EXACT smin no-op as the per-shape test (each member's lower bound
    /// ≥ the group's). Shapes are authored body-part by body-part, so
    /// consecutive runs are spatially tight — a 90-shape drone collapses to
    /// ~12 group tests per step for rays not grazing that body part.
    /// Layout per monster: [ceil(N/8) groups][N shapes]; b.x → group start,
    /// b.y stays N. Also fills shape bounds and hoists monster trig, so this
    /// REPLACES fillShapeBounds/fillMonsterTrig at monster-buffer sites.
    /// Run it BEFORE appending non-monster shapes (the viewmodel overlay):
    /// the rebuild keeps only monster-owned ranges.
    static func packShapeGroups(_ mons: inout [GMonster], _ shapes: inout [GShape]) {
        fillShapeBounds(&shapes)
        fillMonsterTrig(&mons)
        var out: [GShape] = []
        out.reserveCapacity(shapes.count + shapes.count / 8 + mons.count)
        for i in mons.indices {
            let start = Int(mons[i].b.x), n = Int(mons[i].b.y)
            mons[i].b.x = Float(out.count)
            guard n > 0 else { continue }
            for g in 0..<((n + 7) / 8) {
                let lo = start + g * 8, hi = min(lo + 8, start + n)
                var c = SIMD3<Float>.zero
                for si in lo..<hi { c += SIMD3(shapes[si].bnd.x, shapes[si].bnd.y, shapes[si].bnd.z) }
                c /= Float(hi - lo)
                var r: Float = 0, kmax: Float = 0
                for si in lo..<hi {
                    let b = shapes[si].bnd
                    r = max(r, simd_length(SIMD3(b.x, b.y, b.z) - c) + b.w)
                    kmax = max(kmax, shapes[si].col.w)
                }
                out.append(GShape(a: .zero, b: .zero, col: SIMD4(0, 0, 0, kmax), bnd: SIMD4(c.x, c.y, c.z, r)))
            }
            out.append(contentsOf: shapes[start..<(start + n)])
        }
        shapes = out
    }


    // ── item pickups as SDF objects (same kernel field as creatures) ──────────
    // GShape encodings: b.w = -1 sphere(r=a.w) · b.w = -2 rounded box(half=b.xyz, round=a.w) · b.w ≥ 0 round-cone.
    static func iBox(_ c: SIMD3<Float>, _ h: SIMD3<Float>, _ round: Float, _ col: SIMD3<Float>, _ k: Float = 0.008) -> GShape {
        GShape(a: SIMD4(c.x, c.y, c.z, round), b: SIMD4(h.x, h.y, h.z, -2), col: SIMD4(col.x, col.y, col.z, k))
    }
    static func iSphere(_ c: SIMD3<Float>, _ r: Float, _ col: SIMD3<Float>, _ k: Float = 0.008) -> GShape {
        GShape(a: SIMD4(c.x, c.y, c.z, r), b: SIMD4(0, 0, 0, -1), col: SIMD4(col.x, col.y, col.z, k))
    }
    static func iCone(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ r1: Float, _ r2: Float, _ col: SIMD3<Float>, _ k: Float = 0.02) -> GShape {
        GShape(a: SIMD4(a.x, a.y, a.z, r1), b: SIMD4(b.x, b.y, b.z, r2), col: SIMD4(col.x, col.y, col.z, k))
    }
    /// A flat-capped VERTICAL cylinder (Y axis) — the only primitive with genuinely
    /// FLAT top and bottom (boxes are square, cones/spheres dome at the ends). This
    /// is what an oil drum needs. Encoded with the sentinel b.w = -3: centre a.xyz,
    /// radius a.w, half-height b.y, edge-round b.x.
    static func iCylinder(_ c: SIMD3<Float>, r: Float, halfH: Float, round: Float, _ col: SIMD3<Float>, _ k: Float = 0.01) -> GShape {
        GShape(a: SIMD4(c.x, c.y, c.z, r), b: SIMD4(round, halfH, 0, -3), col: SIMD4(col.x, col.y, col.z, k))
    }
    /// A flat-capped cylinder whose axis is local +Z (FORWARD) — a thin disc FACING
    /// the room, where iCylinder's Y-axis disc lies flat and foreshortens. Radius `r`
    /// in the local XY plane, half-length `halfL` along Z. Shapes are evaluated in
    /// prop-local space, so this composes with the prop's yaw (it always faces the
    /// room). Encoded with the sentinel b.w = -4. Used for the reel-to-reel faces.
    static func iDisc(_ c: SIMD3<Float>, r: Float, halfL: Float, round: Float, _ col: SIMD3<Float>, _ k: Float = 0.006) -> GShape {
        GShape(a: SIMD4(c.x, c.y, c.z, r), b: SIMD4(round, halfL, 0, -4), col: SIMD4(col.x, col.y, col.z, k))
    }

    /// Procedural 3-D design for each pickup (local space, feet ≈ y0). Each kind
    /// is built from a few crisply-coloured parts (low smin `k` on the detail so
    /// the cross / bands / stripe stay sharp, not melted) — a recognisable object,
    /// not a tinted blob. Shaded by the kernel's dedicated pickup path (controlled
    /// key+rim, held below the bloom threshold) so the form reads.
    static func itemShapes(_ kind: ItemKind) -> [GShape] {
        let white = SIMD3<Float>(0.90, 0.91, 0.95), red = SIMD3<Float>(0.86, 0.12, 0.10)
        let green = SIMD3<Float>(0.20, 0.72, 0.34), blue = SIMD3<Float>(0.30, 0.55, 0.97)
        let brass = SIMD3<Float>(0.82, 0.64, 0.20), darkM = SIMD3<Float>(0.14, 0.14, 0.17)
        let steel = SIMD3<Float>(0.40, 0.41, 0.46), olive = SIMD3<Float>(0.34, 0.39, 0.20)
        let cyan = SIMD3<Float>(0.40, 0.98, 1.15), yellow = SIMD3<Float>(0.95, 0.80, 0.16)
        let black = SIMD3<Float>(0.07, 0.07, 0.08)
        let d: Float = 0.0025                                   // crisp boundary for surface detail
        switch kind {
        case .stim:                                            // slim auto-injector: white barrel + GREEN chem charge & cross — a quick shot, deliberately NOT the red-cross case
            let barrel = white
            let chem = green
            return [iCylinder(SIMD3(0, 0.26, 0), r: 0.055, halfH: 0.15, round: 0.012, barrel, 0.004),   // glass barrel, upright
                    iCylinder(SIMD3(0, 0.20, 0), r: 0.059, halfH: 0.07, round: 0.004, chem, d),          // the charge — green fluid (protrudes a hair)
                    iCylinder(SIMD3(0, 0.435, 0), r: 0.085, halfH: 0.014, round: 0.006, steel, 0.004),   // plunger flange (thumb rest)
                    iBox(SIMD3(0, 0.475, 0), SIMD3(0.022, 0.03, 0.022), 0.008, steel, 0.004),            // plunger rod
                    iCone(SIMD3(0, 0.11, 0), SIMD3(0, 0.0, 0), 0.028, 0.0, steel),                       // needle: hub → point, down to the floor
                    iBox(SIMD3(0, 0.34, 0.056), SIMD3(0.05, 0.011, 0.012), 0.003, chem, d),              // green cross bar (front, on the white)
                    iBox(SIMD3(0, 0.34, 0.056), SIMD3(0.011, 0.032, 0.012), 0.003, chem, d)]             // green cross upright (front)
        case .medkit:                                          // white briefcase + bold red cross on top & front (the big heal)
            let body = white
            let cross = red
            let bx: Float = 0.26, by: Float = 0.12, bz: Float = 0.15, cy: Float = 0.17
            return [iBox(SIMD3(0, cy, 0), SIMD3(bx, by, bz), 0.01, body, 0.004),                      // case (wide, flat — briefcase)
                    iBox(SIMD3(0, cy + by + 0.022, -bz * 0.62), SIMD3(0.085, 0.02, 0.018), 0.012, steel, 0.004),  // handle (back edge, clear of cross)
                    iBox(SIMD3(0, cy + by, 0), SIMD3(0.12, 0.022, 0.038), 0.004, cross, d),            // top cross bar — always read from above
                    iBox(SIMD3(0, cy + by, 0), SIMD3(0.038, 0.022, 0.10), 0.004, cross, d),            // top cross bar
                    iBox(SIMD3(0, cy, bz), SIMD3(0.11, 0.032, 0.022), 0.004, cross, d),                // front cross
                    iBox(SIMD3(0, cy, bz), SIMD3(0.032, 0.10, 0.022), 0.004, cross, d)]                // front cross
        case .armor, .megaArmor:                               // chest plate + shoulders + chevron
            let c = kind == .megaArmor ? blue : green
            return [iBox(SIMD3(0, 0.26, 0), SIMD3(0.21, 0.24, 0.10), 0.03, c, 0.006),                 // breastplate
                    iBox(SIMD3(-0.23, 0.36, 0), SIMD3(0.06, 0.09, 0.10), 0.03, c, 0.006),             // L pauldron
                    iBox(SIMD3( 0.23, 0.36, 0), SIMD3(0.06, 0.09, 0.10), 0.03, c, 0.006),             // R pauldron
                    iBox(SIMD3(0, 0.30, 0.105), SIMD3(0.055, 0.13, 0.02), 0.004, SIMD3(0.95, 0.96, 1.0), d),   // chevron front
                    iBox(SIMD3(0, 0.30, -0.105), SIMD3(0.055, 0.13, 0.02), 0.004, SIMD3(0.95, 0.96, 1.0), d)]  // chevron back
        case .mineCrate:                                       // explosives crate + proximity mine sat on the lid
            return [iBox(SIMD3(0, 0.16, 0), SIMD3(0.24, 0.15, 0.16), 0.01, olive, 0.005),             // crate body (crisp)
                    iBox(SIMD3(0, 0.31, 0), SIMD3(0.235, 0.025, 0.155), 0.004, darkM, d),             // lid seam (top)
                    iBox(SIMD3(0, 0.10, 0), SIMD3(0.245, 0.02, 0.165), 0.004, brass, d),              // brass band — rings all sides
                    iBox(SIMD3(0, 0.22, 0), SIMD3(0.245, 0.02, 0.165), 0.004, brass, d),              // brass band — rings all sides
                    iCone(SIMD3(0, 0.33, 0), SIMD3(0, 0.395, 0), 0.10, 0.10, steel),                  // mine puck on the lid
                    iSphere(SIMD3(0, 0.43, 0), 0.035, SIMD3<Float>(1.0, 0.18, 0.12))]                 // red trigger lamp (glows)
        case .ammoFuel:                                        // pressurised fuel drum: red cylinder + cap + hazard band
            let fuelRed = SIMD3<Float>(0.62, 0.16, 0.10)
            return [iCone(SIMD3(0, 0.05, 0), SIMD3(0, 0.40, 0), 0.13, 0.13, fuelRed),                 // drum body
                    iCone(SIMD3(0, 0.40, 0), SIMD3(0, 0.45, 0), 0.135, 0.135, darkM),                 // top rim
                    iCone(SIMD3(0.05, 0.45, 0), SIMD3(0.05, 0.52, 0), 0.04, 0.04, brass),             // spout cap
                    iBox(SIMD3(0, 0.24, 0), SIMD3(0.15, 0.03, 0.15), 0.004, yellow, d)]               // hazard band (wraps)
        case .ammoRockets:                                     // warhead + fins (radial — reads at any spin)
            return [iCone(SIMD3(0, 0.06, 0), SIMD3(0, 0.40, 0), 0.075, 0.075, olive),                 // body
                    iCone(SIMD3(0, 0.40, 0), SIMD3(0, 0.54, 0), 0.075, 0.0, red),                     // tip
                    iBox(SIMD3(0.075, 0.10, 0), SIMD3(0.03, 0.06, 0.012), 0.004, darkM, d),           // fin
                    iBox(SIMD3(-0.075, 0.10, 0), SIMD3(0.03, 0.06, 0.012), 0.004, darkM, d),          // fin
                    iBox(SIMD3(0, 0.10, 0.075), SIMD3(0.012, 0.06, 0.03), 0.004, darkM, d),           // fin
                    iBox(SIMD3(0, 0.10, -0.075), SIMD3(0.012, 0.06, 0.03), 0.004, darkM, d)]          // fin
        case .ammoCells:                                       // battery: dark casing + glowing cyan RING + terminal
            return [iBox(SIMD3(0, 0.20, 0), SIMD3(0.15, 0.21, 0.12), 0.015, darkM, 0.005),            // casing
                    iBox(SIMD3(0, 0.15, 0), SIMD3(0.175, 0.045, 0.145), 0.004, cyan, d),              // glowing ring — wraps, protrudes
                    iBox(SIMD3(0, 0.26, 0), SIMD3(0.175, 0.04, 0.145), 0.004, cyan, d),               // second ring
                    iBox(SIMD3(0, 0.41, 0), SIMD3(0.06, 0.025, 0.05), 0.01, steel, d)]                // terminal cap (top)
        case .weaponRocket:                                    // echoes the held launcher: olive tube, red safety band + warhead, red aim bead
            let len: Float = 0.40
            let launcher = SIMD3<Float>(0.20, 0.27, 0.15)      // olive drab, matching the viewmodel tube
            return [iCone(SIMD3(-len, 0.24, 0), SIMD3(len, 0.24, 0), 0.07, 0.07, launcher),           // main tube (olive drab)
                    iCone(SIMD3(len * 0.34, 0.24, 0), SIMD3(len * 0.48, 0.24, 0), 0.078, 0.078, red), // red safety band
                    iCone(SIMD3(len - 0.02, 0.24, 0), SIMD3(len + 0.07, 0.24, 0), 0.05, 0.0, red),    // red warhead peeking, pointed
                    iBox(SIMD3(-len * 0.2, 0.12, 0), SIMD3(0.045, 0.09, 0.045), 0.015, black, 0.005), // grip
                    iBox(SIMD3(0, 0.32, 0), SIMD3(0.04, 0.04, 0.03), 0.01, darkM, 0.005),             // sight rail
                    iSphere(SIMD3(0, 0.365, 0), 0.016, SIMD3<Float>(1.0, 0.20, 0.12))]                // red aim bead (glows, like the held one)
        case .keyRed, .keyBlue, .keyYellow:                    // flat keycard: card + mag stripe + chip
            let c = kind == .keyRed ? red : (kind == .keyBlue ? blue : yellow)
            return [iBox(SIMD3(0, 0.24, 0), SIMD3(0.14, 0.20, 0.02), 0.008, c, 0.004),                // card
                    iBox(SIMD3(0, 0.31, 0.022), SIMD3(0.14, 0.035, 0.006), 0.002, black, d),          // mag stripe (front)
                    iBox(SIMD3(0, 0.31, -0.022), SIMD3(0.14, 0.035, 0.006), 0.002, black, d),         // mag stripe (back)
                    iBox(SIMD3(-0.07, 0.16, 0.022), SIMD3(0.04, 0.03, 0.006), 0.002, brass, d),       // chip (front)
                    iBox(SIMD3(-0.07, 0.16, -0.022), SIMD3(0.04, 0.03, 0.006), 0.002, brass, d)]      // chip (back)
        }
    }

    private static func shapeYExtent(_ sh: GShape) -> (lo: Float, hi: Float) {
        if sh.b.w < -3.5 { return (sh.a.y - sh.a.w, sh.a.y + sh.a.w) }                      // z-disc (radius spans Y)
        if sh.b.w < -2.5 { return (sh.a.y - sh.b.y, sh.a.y + sh.b.y) }                      // cylinder (half-height b.y)
        if sh.b.w < -1.5 { return (sh.a.y - sh.b.y - sh.a.w, sh.a.y + sh.b.y + sh.a.w) }   // box
        if sh.b.w < 0   { return (sh.a.y - sh.a.w, sh.a.y + sh.a.w) }                       // sphere
        return (min(sh.a.y - sh.a.w, sh.b.y - sh.b.w), max(sh.a.y + sh.a.w, sh.b.y + sh.b.w))
    }
    private static func shapeRadius(_ sh: GShape, _ cy: Float) -> Float {
        if sh.b.w < -2.5 {                          // cylinder: radius a.w (XZ), half-height b.y (Y)
            let horiz = (sh.a.x * sh.a.x + sh.a.z * sh.a.z).squareRoot() + sh.a.w
            let vert = abs(sh.a.y - cy) + sh.b.y
            return (horiz * horiz + vert * vert).squareRoot()
        }
        if sh.b.w < -1.5 {
            let dx = abs(sh.a.x) + sh.b.x + sh.a.w, dy = abs(sh.a.y - cy) + sh.b.y + sh.a.w, dz = abs(sh.a.z) + sh.b.z + sh.a.w
            return (dx * dx + dy * dy + dz * dz).squareRoot()
        }
        if sh.b.w < 0 { return simd_length(SIMD3(sh.a.x, sh.a.y - cy, sh.a.z)) + sh.a.w }
        return max(simd_length(SIMD3(sh.a.x, sh.a.y - cy, sh.a.z)) + sh.a.w,
                   simd_length(SIMD3(sh.b.x, sh.b.y - cy, sh.b.z)) + sh.b.w)
    }

    /// Pack pickups into the same GMonster/GShape buffers — scaled small, hovering
    /// (c.y), gently spinning (yaw), so they read as floating 3-D objects.
    static func packItems(_ items: [Item], time: Float) -> ([GMonster], [GShape]) {
        var mons: [GMonster] = [], shapes: [GShape] = []
        for (idx, it) in items.enumerated() {
            let sl = itemShapes(it.kind)
            if sl.isEmpty { continue }
            var loY: Float = 1e9, hiY: Float = -1e9
            for sh in sl { let e = shapeYExtent(sh); loY = min(loY, e.lo); hiY = max(hiY, e.hi) }
            let boundCY = (loY + hiY) / 2
            var boundR: Float = 0
            for sh in sl { boundR = max(boundR, shapeRadius(sh, boundCY)) }
            boundR += 0.04
            // One shared scale (authored item-units ≈ ½ a wall) so each pickup keeps
            // its designed proportions — renormalising every kind to a fixed height
            // stretched the flat crates and oversized everything.
            let scale: Float = 0.55
            let phase = Float(idx) * 1.7 + it.bob
            let floatH: Float = 0.18 + sin(time * 2 + phase) * 0.04   // gentle bob
            let yaw = time * 0.8 + phase                              // slow spin
            let start = shapes.count
            shapes.append(contentsOf: sl)
            mons.append(GMonster(a: SIMD4(it.pos.x, it.pos.y, yaw, scale),
                                 b: SIMD4(Float(start), Float(sl.count), boundR, boundCY),
                                 c: SIMD4(loY, floatH, 1, 0)))   // c.z = 1 → pickup material (controlled shading)
        }
        return (mons, shapes)
    }

    // ── rubble debris at battle-damage sites (static SDF geometry) ─────────────
    /// A small pile of charred chunks, deterministic from a per-site seed so it's
    /// stable frame-to-frame. Authored feet-on-floor (y≈0) in the same local space
    /// the creature/item path uses — packed as a no-spin GMonster.
    static func debrisShapes(_ seed: UInt32) -> [GShape] {
        func h(_ n: UInt32) -> Float {
            var x = seed &* 747796405 &+ (n &+ 1) &* 2891336453
            x = (x ^ (x >> 16)) &* 2246822519
            x = x ^ (x >> 13)
            return Float(x & 0xFFFF) / 65535
        }
        let charred = SIMD3<Float>(0.10, 0.10, 0.12), rust = SIMD3<Float>(0.22, 0.13, 0.08)
        let pale = SIMD3<Float>(0.30, 0.29, 0.31)
        let chunks = 3 + Int(h(0) * 2.99)                          // 3–5 chunks
        var out: [GShape] = []
        for i in 0..<chunks {
            let k = UInt32(i) * 7
            let ang = h(k + 1) * 6.2832, rad = 0.04 + h(k + 2) * 0.24
            let sx = 0.045 + h(k + 3) * 0.085, sy = 0.03 + h(k + 4) * 0.06, sz = 0.045 + h(k + 5) * 0.085
            let cy = sy + h(k + 6) * 0.015                          // resting on the floor
            let pick = h(k + 9)
            let col = pick < 0.55 ? charred : (pick < 0.82 ? rust : pale)
            out.append(iBox(SIMD3(cos(ang) * rad, cy, sin(ang) * rad), SIMD3(sx, sy, sz), 0.012, col, 0.01))
        }
        return out
    }

    /// Pack rubble piles into the shared GMonster/GShape buffers (no bob, no spin).
    static func packDebris(_ piles: [(pos: SIMD2<Float>, seed: UInt32)], budget: Int = 240) -> ([GMonster], [GShape]) {
        var mons: [GMonster] = [], shapes: [GShape] = []
        for d in piles {
            let sl = debrisShapes(d.seed)
            if sl.isEmpty || shapes.count + sl.count > budget { break }
            var loY: Float = 1e9, hiY: Float = -1e9
            for sh in sl { let e = shapeYExtent(sh); loY = min(loY, e.lo); hiY = max(hiY, e.hi) }
            let boundCY = (loY + hiY) / 2
            var boundR: Float = 0
            for sh in sl { boundR = max(boundR, shapeRadius(sh, boundCY)) }
            boundR += 0.05
            let start = shapes.count
            shapes.append(contentsOf: sl)
            mons.append(GMonster(a: SIMD4(d.pos.x, d.pos.y, 0, 1),
                                 b: SIMD4(Float(start), Float(sl.count), boundR, boundCY),
                                 c: SIMD4(loY, 0, 0, 0)))
        }
        return (mons, shapes)
    }

    // ── environmental props: furniture & fixtures (static SDF, material c.z = 3) ─
    // Authored feet-on-floor (y≈0) in a 1-unit-tall room (floor 0 → ceiling 1),
    // FRONT facing local +Z and the wall behind at local −Z, so MapGen orients
    // each piece by setting yaw = atan2(-inward.x, inward.z). Built from the same
    // iBox/iCone/iSphere parts as the pickups, but flagged opaque (c.z = 3) so the
    // kernel shades them as lit industrial steel — a powered terminal screen is
    // authored over-bright so it self-glows.
    // The reel-to-reel deck, factored out so packProps can rebuild it live: `spin`
    // rotates the spoke-windows (advanced each frame while playing) and `playing`
    // lights the REC LED bright red instead of a dim standby ember.
    static func tapeDeckShapes(spin: Float, playing: Bool) -> [GShape] {
        let top = SIMD3<Float>(0.37, 0.38, 0.41), steel = SIMD3<Float>(0.40, 0.42, 0.47)
        let chassis = SIMD3<Float>(0.17, 0.18, 0.21), panel = SIMD3<Float>(0.22, 0.23, 0.27)
        let flange = SIMD3<Float>(0.60, 0.63, 0.68), tape = SIMD3<Float>(0.06, 0.05, 0.045)
        let hubc = SIMD3<Float>(0.42, 0.44, 0.48)
        let plate = SIMD3<Float>(0.72, 0.70, 0.63)
        let amberEm = SIMD3<Float>(1.45, 1.15, 0.52), redEm = SIMD3<Float>(2.6, 0.10, 0.06), grnEm = SIMD3<Float>(0.12, 2.1, 0.5)
        let recEm: SIMD3<Float> = playing ? SIMD3(3.4, 0.12, 0.07) : SIMD3(0.42, 0.05, 0.04)  // bright when rolling, dim standby ember when idle
        var s: [GShape] = [
            iBox(SIMD3(0, 0.30, 0), SIMD3(0.36, 0.018, 0.19), 0.008, top, 0.005),            // desk top
            iBox(SIMD3(0, 0.15, -0.15), SIMD3(0.34, 0.15, 0.018), 0.004, top * 0.8, 0.005),  // modesty panel (wall side)
            iBox(SIMD3(-0.30, 0.15, 0.13), SIMD3(0.025, 0.15, 0.025), 0.004, steel, 0.003),  // legs
            iBox(SIMD3(0.30, 0.15, 0.13), SIMD3(0.025, 0.15, 0.025), 0.004, steel, 0.003),
            iBox(SIMD3(0, 0.352, 0.02), SIMD3(0.30, 0.036, 0.13), 0.012, chassis, 0.006),    // deck chassis (controls)
            iBox(SIMD3(0, 0.51, -0.07), SIMD3(0.30, 0.135, 0.02), 0.012, panel, 0.006),      // upright reel panel
            iBox(SIMD3(0, 0.44, -0.048), SIMD3(0.155, 0.006, 0.006), 0.002, tape, 0.001),    // tape path between reels
            iBox(SIMD3(0, 0.44, -0.045), SIMD3(0.03, 0.02, 0.014), 0.004, hubc, 0.003),      // head block
            iBox(SIMD3(-0.10, 0.352, 0.151), SIMD3(0.055, 0.03, 0.004), 0.006, amberEm, 0.002),  // VU meters (emissive)
            iBox(SIMD3(0.10, 0.352, 0.151), SIMD3(0.055, 0.03, 0.004), 0.006, amberEm, 0.002),
            iSphere(SIMD3(0.24, 0.38, 0.15), 0.010, recEm, 0.002),                           // REC LED (bright while playing)
            iSphere(SIMD3(-0.24, 0.38, 0.15), 0.009, grnEm, 0.002),                          // power LED
        ]
        // two reels standing on the panel, faces toward the player (+Z): a metal
        // flange, a hub boss, and 3 dark spoke-windows (the tape pack showing).
        // Each reel is a genuine flat DISC facing the player (iDisc — a forward-
        // axis flat-cap cylinder), so it reads as a circle, not a foreshortened
        // sliver or a domed blob. A hub boss + 3 dark spoke-windows sit proud on
        // the face; `spin` rotates the windows so the reel turns when playing.
        for (cx, a0) in [(Float(-0.15), Float(0.4)), (Float(0.15), Float(1.25))] {
            let rc = SIMD3<Float>(cx, 0.545, -0.05)                                          // on the panel face, disc toward the room
            s.append(iDisc(rc, r: 0.10, halfL: 0.012, round: 0.004, flange, 0.004))          // flange disc
            s.append(iDisc(rc + SIMD3(0, 0, 0.014), r: 0.032, halfL: 0.010, round: 0.004, hubc, 0.003))  // hub boss (proud)
            for k in 0..<3 {
                let a = a0 + spin + Float(k) * (2 * Float.pi / 3)
                let wp = rc + SIMD3(cos(a) * 0.052, sin(a) * 0.052, 0.010)
                s.append(iDisc(wp, r: 0.023, halfL: 0.010, round: 0.003, tape, 0.002))       // dark spoke window (proud)
            }
        }
        // warning placards along the top of the panel, facing the player:
        // "THE SIGNAL" (amber) + "DO NOT OVERWRITE" (red)
        s.append(iBox(SIMD3(-0.13, 0.66, -0.048), SIMD3(0.10, 0.026, 0.004), 0.004, plate, 0.003))
        s.append(iBox(SIMD3(-0.13, 0.66, -0.044), SIMD3(0.088, 0.011, 0.004), 0.002, amberEm, 0.002))
        s.append(iBox(SIMD3(0.14, 0.66, -0.048), SIMD3(0.11, 0.026, 0.004), 0.004, plate, 0.003))
        s.append(iBox(SIMD3(0.14, 0.66, -0.044), SIMD3(0.098, 0.011, 0.004), 0.002, redEm, 0.002))
        return s
    }

    static func furnitureShapes(_ kind: FurnitureKind) -> [GShape] {
        let steel = SIMD3<Float>(0.40, 0.42, 0.47), darkM = SIMD3<Float>(0.13, 0.13, 0.16)
        let d: Float = 0.0025
        switch kind {
        case .bunk:                                            // barracks bunk (platform bed) — pillow at the wall (−Z)
            let mat = SIMD3<Float>(0.34, 0.37, 0.32), blanket = SIMD3<Float>(0.19, 0.32, 0.58)   // institutional BLUE blanket (matches the raster bed)
            let pillow = SIMD3<Float>(0.60, 0.58, 0.52)
            let hl: Float = 0.42, hw: Float = 0.20
            // Lean (5 shapes, no separate legs) — every shape is re-evaluated for any
            // ray inside the bunk's bounding sphere, so fewer parts = less GPU.
            return [iBox(SIMD3(0, 0.07, 0), SIMD3(hw + 0.02, 0.07, hl + 0.02), 0.012, steel, 0.006),        // platform base (sits on the deck)
                    iBox(SIMD3(0, 0.155, 0.02), SIMD3(hw, 0.04, hl - 0.02), 0.03, mat, 0.012),              // mattress
                    iBox(SIMD3(0, 0.175, 0.16), SIMD3(hw - 0.01, 0.03, hl - 0.22), 0.02, blanket, 0.012),   // blanket, foot half
                    iBox(SIMD3(0, 0.185, -hl + 0.11), SIMD3(hw - 0.03, 0.034, 0.085), 0.03, pillow, 0.01),  // pillow at the head
                    iBox(SIMD3(0, 0.22, -hl - 0.01), SIMD3(hw + 0.02, 0.14, 0.02), 0.01, steel, 0.005)]     // headboard against the wall
        case .desk:                                            // office desk + still-powered terminal facing the room
            // screen = ARC amber phosphor (title-screen ratio 240:196:96), authored
            // over-bright (lum ≈ 1.2, same as the old teal) so it self-glows.
            let top = SIMD3<Float>(0.37, 0.38, 0.41), screen = SIMD3<Float>(1.45, 1.18, 0.58)
            return [iBox(SIMD3(0, 0.30, 0), SIMD3(0.36, 0.018, 0.19), 0.008, top, 0.005),                  // desk top
                    iBox(SIMD3(0, 0.15, -0.15), SIMD3(0.34, 0.15, 0.018), 0.004, top * 0.8, 0.005),        // modesty panel (wall side)
                    iBox(SIMD3(-0.30, 0.15, 0.13), SIMD3(0.025, 0.15, 0.025), 0.004, steel, d),            // front legs
                    iBox(SIMD3( 0.30, 0.15, 0.13), SIMD3(0.025, 0.15, 0.025), 0.004, steel, d),
                    iBox(SIMD3(0, 0.45, -0.05), SIMD3(0.155, 0.115, 0.045), 0.01, darkM, 0.005),           // monitor housing
                    iBox(SIMD3(0, 0.45, 0.0), SIMD3(0.125, 0.092, 0.012), 0.004, screen, d),               // glowing screen (faces +Z)
                    iBox(SIMD3(0, 0.315, 0.06), SIMD3(0.10, 0.012, 0.05), 0.004, darkM, d)]                // keyboard
        case .chair:                                           // office chair (back at −Z so it tucks into a desk)
            let c = SIMD3<Float>(0.19, 0.20, 0.23)
            return [iBox(SIMD3(0, 0.21, 0), SIMD3(0.115, 0.02, 0.115), 0.02, c, 0.008),                    // seat
                    iBox(SIMD3(0, 0.33, -0.10), SIMD3(0.115, 0.115, 0.018), 0.02, c, 0.008),               // backrest
                    iCone(SIMD3(0, 0.0, 0), SIMD3(0, 0.20, 0), 0.024, 0.03, darkM),                        // post
                    iBox(SIMD3(0, 0.02, 0), SIMD3(0.10, 0.014, 0.10), 0.01, darkM, d)]                     // base
        case .locker:                                          // tall, NARROW steel locker (was fridge-wide)
            // The old locker was as wide as it was tall and read as a fridge. A real
            // barracks locker is narrow and full-height, with a recessed door, a vent
            // grille near the top, a vertical latch and a base plinth.
            let body = SIMD3<Float>(0.28, 0.30, 0.35), door = SIMD3<Float>(0.34, 0.36, 0.41)
            let vent = SIMD3<Float>(0.13, 0.14, 0.17)
            let hw: Float = 0.115, hd: Float = 0.105
            return [iBox(SIMD3(0, 0.435, -0.01), SIMD3(hw, 0.435, hd), 0.012, body, 0.006),                 // carcass (full-height, slim)
                    iBox(SIMD3(0, 0.45, hd - 0.004), SIMD3(hw - 0.018, 0.40, 0.012), 0.006, door, 0.004),   // recessed door face, set proud
                    iBox(SIMD3(0, 0.70, hd + 0.006), SIMD3(0.062, 0.05, 0.006), 0.003, vent, d),            // vent grille near the top
                    iBox(SIMD3(0.084, 0.45, hd + 0.012), SIMD3(0.012, 0.065, 0.012), 0.004, darkM, d),      // vertical latch handle (right edge)
                    iBox(SIMD3(0, 0.045, 0), SIMD3(hw - 0.004, 0.045, hd - 0.004), 0.004, darkM, 0.004)]    // base plinth (stands it off the deck)
        case .papers:                                          // paper is too THIN to read as SDF (it came out like stacked
            return []                                          // books). It renders as a FLAT floor DECAL instead — see World.buildAftermath.
        case .tapeDeck:                                        // the control-room reel-to-reel: "THE SIGNAL" archive
            // A desk carrying an UPRIGHT broadcast deck — the two reels stand on a
            // vertical front panel FACING the player (flat-on-top reels foreshorten to
            // slivers from standing height), each a metal flange with a hub + 3 spoke
            // windows showing the dark tape pack beneath. Below: a head block + tape
            // path, glowing VU meters, status LEDs, and two warning placards. The
            // spoke-windows are spun by packProps when the deck is playing.
            return tapeDeckShapes(spin: 0, playing: false)
        // ── PLANT MACHINERY (floors 7–8) ──
        // These four are imported meshes in the raster path (Resources/machine_*.obj). What lives
        // here is the coarse bulk: it is what the SDF raymarcher draws, and — because
        // furnitureFootprint measures these shapes — it is also what derives the COLLIDER. So the
        // half-extents are the mesh's own measured game-space bounds, not an eyeballed box:
        // tools/3ds2obj.py reports each source bound, and scaling by (target height / source height)
        // gives the numbers below. Re-run the converter and re-measure if a mesh is ever re-sourced.
        case .machineFilter:
            // Three tanks in a gantry — 2.817 W × 1.027 D × 1.500 H. Two stacked boxes read as the
            // frame and the tank bank; the mesh carries the real silhouette in the shipping renderer.
            return [iBox(SIMD3(0, 0.30, 0), SIMD3(1.408, 0.30, 0.513), 0.02, darkM, 0.01),   // gantry base + legs
                    iBox(SIMD3(0, 1.00, 0), SIMD3(1.300, 0.44, 0.460), 0.10, steel, 0.01)]   // the tank bank above it
        case .machineColumn:
            // Vertical vessel on a base with side drums — 2.698 W × 2.329 D × 1.600 H. The vessel is
            // the mass that matters; the drums are inside the same footprint.
            return [iBox(SIMD3(0, 0.22, 0), SIMD3(1.349, 0.22, 1.164), 0.02, darkM, 0.01),          // base raft + side drums
                    iCylinder(SIMD3(0, 1.00, 0), r: 0.42, halfH: 0.60, round: 0.06, steel, 0.01)]   // the column itself
        case .machineCompressor:
            // Cabinet + twin receivers + manifold — 1.019 W × 1.410 D × 1.000 H. Lines a wall, so the
            // caller shoves it flush; the receivers sit high on the cabinet.
            return [iBox(SIMD3(0, 0.34, 0), SIMD3(0.509, 0.34, 0.705), 0.02, darkM, 0.008),         // cabinet
                    iCylinder(SIMD3(0, 0.80, -0.10), r: 0.19, halfH: 0.42, round: 0.04, steel, 0.01)] // receiver drum
        case .machineSwitchgear:
            // Distribution cabinet with a lever isolator — 0.469 W × 0.367 D × 0.850 H. Compact
            // enough for one cell, and cheap enough to rank several along a wall.
            return [iBox(SIMD3(0, 0.425, 0), SIMD3(0.234, 0.425, 0.183), 0.015, darkM, 0.006),      // carcass
                    iBox(SIMD3(0.18, 0.52, 0.19), SIMD3(0.02, 0.09, 0.02), 0.008, steel, 0.004)]    // lever handle
        case .column:                                          // riveted-steel structural column, floor → ceiling (y 0…1)
            // A slender ROUND steel post with a proud base plinth and a capital that meets the
            // roof; the steel's baked relief/rivet grain does the "riveted" read. Free-standing
            // (placed with againstWall=false), so no flushToWall shove. Kept to 3 cylinders.
            let r: Float = 0.11                                                                       // slender round shaft
            return [iCylinder(SIMD3(0, 0.5, 0),  r: r,        halfH: 0.5,  round: 0.01, steel, 0.01), // shaft
                    iCylinder(SIMD3(0, 0.05, 0), r: r + 0.06, halfH: 0.05, round: 0.01, darkM, 0.008),// base plinth
                    iCylinder(SIMD3(0, 0.95, 0), r: r + 0.06, halfH: 0.05, round: 0.01, darkM, 0.008)]// capital (meets the ceiling)
        case .console:
            // OPERATIONS CONSOLE — the operator sits on the +Z side, so the amber screen and keyboard face +Z
            // while the −Z face (toward the big board the operator is watching) carries an indicator strip
            // rather than a blank slab. Screen is ARC amber phosphor, over-bright so it self-glows like every
            // other terminal in the complex; the big board is the ONE display that breaks into full colour.
            let work = SIMD3<Float>(0.34, 0.35, 0.39), amber = SIMD3<Float>(1.04, 0.78, 0.34)
            let lampW = SIMD3<Float>(1.06, 0.96, 0.74)
            return [iBox(SIMD3(0, 0.16, 0), SIMD3(0.30, 0.16, 0.20), 0.012, work, 0.006),                  // console pedestal
                    iBox(SIMD3(0, 0.345, 0), SIMD3(0.32, 0.022, 0.22), 0.008, work * 1.1, 0.005),          // worktop
                    iBox(SIMD3(0, 0.52, -0.06), SIMD3(0.26, 0.16, 0.05), 0.012, darkM, 0.006),             // monitor bank housing
                    iBox(SIMD3(0, 0.535, -0.004), SIMD3(0.125, 0.082, 0.012), 0.004, amber, d),            // glowing amber screen (faces +Z) — modest, framed by the housing
                    iBox(SIMD3(0, 0.372, 0.10), SIMD3(0.155, 0.014, 0.055), 0.004, darkM, d),              // keyboard
                    iBox(SIMD3(0, 0.30, -0.205), SIMD3(0.22, 0.032, 0.014), 0.004, amber * 0.42, d),       // indicator strip, board side
                    iBox(SIMD3(0.245, 0.60, -0.02), SIMD3(0.013, 0.115, 0.013), 0.005, steel, d),          // task-lamp stalk
                    iBox(SIMD3(0.245, 0.715, 0.03), SIMD3(0.055, 0.022, 0.045), 0.012, lampW, d)]          // task-lamp head (warm)
        case .cabinet:
            // MEDICAL stainless counter: a plinth, a bright worktop lipped at the front, and drawer fronts with
            // pull handles. Authored back-to-wall (−Z) so it lines a wall like the lockers do.
            let inox = SIMD3<Float>(0.66, 0.68, 0.72), inoxT = SIMD3<Float>(0.76, 0.78, 0.82)
            var cab: [GShape] = [
                iBox(SIMD3(0, 0.21, -0.02), SIMD3(0.34, 0.21, 0.17), 0.01, inox, 0.005),                  // carcass
                iBox(SIMD3(0, 0.435, -0.01), SIMD3(0.36, 0.022, 0.19), 0.008, inoxT, 0.004),              // worktop
                iBox(SIMD3(0, 0.405, 0.175), SIMD3(0.36, 0.018, 0.014), 0.006, inoxT, 0.004),             // front lip
            ]
            for k in 0..<3 {                                                                              // drawer fronts + handles
                let dy = 0.10 + Float(k) * 0.115
                cab.append(iBox(SIMD3(0, dy, 0.152), SIMD3(0.315, 0.048, 0.014), 0.006, inox * 1.06, 0.004))
                cab.append(iBox(SIMD3(0, dy + 0.032, 0.172), SIMD3(0.12, 0.010, 0.012), 0.005, inoxT, 0.004))
            }
            return cab
        case .sink:
            // MEDICAL scrub sink: stainless basin recessed into a counter, splashback up the wall, mixer tap
            // with a long lever — the fitting that says "clinical" more than anything else in the room.
            let inox2 = SIMD3<Float>(0.66, 0.68, 0.72), inoxB = SIMD3<Float>(0.78, 0.80, 0.84)
            return [iBox(SIMD3(0, 0.21, -0.02), SIMD3(0.30, 0.21, 0.16), 0.01, inox2, 0.005),             // pedestal
                    iBox(SIMD3(0, 0.435, -0.01), SIMD3(0.32, 0.022, 0.18), 0.008, inoxB, 0.004),          // counter
                    iBox(SIMD3(0, 0.408, 0.00), SIMD3(0.19, 0.020, 0.115), 0.03, inox2 * 0.72, 0.004),    // recessed basin
                    iBox(SIMD3(0, 0.70, -0.175), SIMD3(0.32, 0.245, 0.014), 0.006, inoxB, 0.004),         // splashback
                    iBox(SIMD3(0, 0.50, -0.12), SIMD3(0.016, 0.055, 0.016), 0.008, inoxB, 0.004),         // tap riser
                    iBox(SIMD3(0, 0.552, -0.075), SIMD3(0.014, 0.014, 0.055), 0.008, inoxB, 0.004),       // spout
                    iBox(SIMD3(0.055, 0.565, -0.115), SIMD3(0.055, 0.012, 0.012), 0.006, inoxB, 0.004)]   // lever handle
        case .range:
            // CANTEEN range: a stainless block with a hob top, four rings, an oven door with a handle, and the
            // extraction hood over it. Authored back-to-wall (−Z) so it lines the galley wall.
            let inoxR = SIMD3<Float>(0.62, 0.64, 0.68), inoxL = SIMD3<Float>(0.76, 0.78, 0.82)
            let hobD = SIMD3<Float>(0.11, 0.11, 0.12)
            var rg: [GShape] = [
                iBox(SIMD3(0, 0.22, -0.02), SIMD3(0.34, 0.22, 0.17), 0.012, inoxR, 0.006),                // range body
                iBox(SIMD3(0, 0.452, -0.01), SIMD3(0.35, 0.020, 0.185), 0.008, hobD, 0.004),              // hob top
                iBox(SIMD3(0, 0.30, 0.165), SIMD3(0.30, 0.135, 0.016), 0.008, inoxR * 1.08, 0.005),       // oven door
                iBox(SIMD3(0, 0.40, 0.192), SIMD3(0.26, 0.016, 0.016), 0.008, inoxL, 0.004),              // oven handle
                iBox(SIMD3(0, 0.88, -0.06), SIMD3(0.36, 0.10, 0.20), 0.02, inoxL, 0.006),                 // extraction hood
                iBox(SIMD3(0, 0.755, -0.06), SIMD3(0.30, 0.028, 0.165), 0.012, hobD, 0.005),              // hood filter throat
            ]
            for (rx, rz) in [(-0.16, -0.07), (0.16, -0.07), (-0.16, 0.06), (0.16, 0.06)] {                // four rings
                rg.append(iCylinder(SIMD3(Float(rx), 0.470, Float(rz)), r: 0.062, halfH: 0.006, round: 0.004, inoxR * 0.8, 0.004))
            }
            return rg
        case .canteenTable:
            // CANTEEN table with a bench either side — one prop, so a row of them ranks up cleanly. Wipe-clean
            // stainless top on a steel frame; the benches are backless, as a works canteen would be.
            let topM = SIMD3<Float>(0.70, 0.72, 0.75), frameM = SIMD3<Float>(0.34, 0.36, 0.40)
            let benchM = SIMD3<Float>(0.42, 0.40, 0.37)
            var ct: [GShape] = [
                iBox(SIMD3(0, 0.36, 0), SIMD3(0.40, 0.022, 0.24), 0.008, topM, 0.004),                    // table top
                iBox(SIMD3(-0.32, 0.18, 0), SIMD3(0.022, 0.18, 0.20), 0.006, frameM, 0.004),              // end frames
                iBox(SIMD3( 0.32, 0.18, 0), SIMD3(0.022, 0.18, 0.20), 0.006, frameM, 0.004),
                iBox(SIMD3(0, 0.10, 0), SIMD3(0.30, 0.018, 0.020), 0.005, frameM, 0.004),                 // stretcher rail
            ]
            for bz in [Float(-0.42), 0.42] {                                                              // a bench each side
                ct.append(iBox(SIMD3(0, 0.235, bz), SIMD3(0.38, 0.020, 0.085), 0.006, benchM, 0.004))
                ct.append(iBox(SIMD3(-0.28, 0.115, bz), SIMD3(0.020, 0.115, 0.065), 0.005, frameM, 0.004))
                ct.append(iBox(SIMD3( 0.28, 0.115, bz), SIMD3(0.020, 0.115, 0.065), 0.005, frameM, 0.004))
            }
            return ct
        case .washTrough:
            // SANITARY trough basin: one long stainless trough on brackets, a run of pillar taps, and a mirror
            // panel above it. Authored back-to-wall (−Z). The mirror is a bright, low-roughness plate — enough
            // to read as glass without needing a reflection.
            let inoxW = SIMD3<Float>(0.68, 0.70, 0.74), inoxD = SIMD3<Float>(0.40, 0.42, 0.45)
            let mirror = SIMD3<Float>(0.74, 0.79, 0.82)
            var wt: [GShape] = [
                iBox(SIMD3(0, 0.40, -0.02), SIMD3(0.36, 0.030, 0.15), 0.012, inoxW, 0.005),               // trough rim
                iBox(SIMD3(0, 0.365, -0.02), SIMD3(0.32, 0.032, 0.115), 0.03, inoxD, 0.005),              // the basin well
                iBox(SIMD3(-0.30, 0.24, -0.10), SIMD3(0.022, 0.14, 0.030), 0.006, inoxD, 0.004),          // brackets
                iBox(SIMD3( 0.30, 0.24, -0.10), SIMD3(0.022, 0.14, 0.030), 0.006, inoxD, 0.004),
                iBox(SIMD3(0, 0.145, -0.09), SIMD3(0.040, 0.10, 0.040), 0.010, inoxD, 0.004),             // waste trap
                iBox(SIMD3(0, 0.80, -0.175), SIMD3(0.34, 0.185, 0.012), 0.006, mirror, 0.003),            // mirror panel
            ]
            for tx in [Float(-0.20), 0.0, 0.20] {                                                         // pillar taps
                wt.append(iBox(SIMD3(tx, 0.455, -0.115), SIMD3(0.014, 0.045, 0.014), 0.007, inoxW, 0.004))
                wt.append(iBox(SIMD3(tx, 0.495, -0.075), SIMD3(0.012, 0.012, 0.045), 0.007, inoxW, 0.004))
            }
            return wt
        case .shower:
            // SANITARY shower stall: a tiled divider each side, the head on its riser, and a mixer valve. Open
            // fronted (no door), which is what a works washroom has.
            let divid = SIMD3<Float>(0.72, 0.78, 0.75), chrome = SIMD3<Float>(0.74, 0.76, 0.80)
            return [iBox(SIMD3(-0.34, 0.50, -0.06), SIMD3(0.030, 0.50, 0.20), 0.008, divid, 0.005),       // divider L
                    iBox(SIMD3( 0.34, 0.50, -0.06), SIMD3(0.030, 0.50, 0.20), 0.008, divid, 0.005),       // divider R
                    iBox(SIMD3(0, 0.02, -0.06), SIMD3(0.33, 0.022, 0.20), 0.008, divid * 0.86, 0.005),    // shallow tray upstand
                    iBox(SIMD3(0, 0.72, -0.175), SIMD3(0.016, 0.20, 0.016), 0.008, chrome, 0.004),        // riser
                    iBox(SIMD3(0, 0.905, -0.115), SIMD3(0.014, 0.014, 0.062), 0.008, chrome, 0.004),      // arm
                    iCylinder(SIMD3(0, 0.885, -0.06), r: 0.055, halfH: 0.012, round: 0.006, chrome, 0.004), // rose
                    iBox(SIMD3(0, 0.46, -0.168), SIMD3(0.045, 0.045, 0.020), 0.012, chrome, 0.004)]       // mixer valve
        case .cubicle:
            // SANITARY WC cubicle: two partitions with a gap over and under (as they always have), a part-open
            // door, and the pan with its cistern inside.
            let part = SIMD3<Float>(0.70, 0.74, 0.72), porc = SIMD3<Float>(0.86, 0.87, 0.86)
            return [iBox(SIMD3(-0.34, 0.52, -0.04), SIMD3(0.026, 0.44, 0.22), 0.008, part, 0.005),        // partition L
                    iBox(SIMD3( 0.34, 0.52, -0.04), SIMD3(0.026, 0.44, 0.22), 0.008, part, 0.005),        // partition R
                    iBox(SIMD3(-0.20, 0.52, 0.175), SIMD3(0.135, 0.44, 0.022), 0.008, part * 1.04, 0.005), // door, part open
                    iBox(SIMD3(0, 0.155, -0.10), SIMD3(0.115, 0.155, 0.105), 0.03, porc, 0.005),          // pan
                    iBox(SIMD3(0, 0.315, -0.10), SIMD3(0.135, 0.022, 0.125), 0.012, porc, 0.004),         // seat
                    iBox(SIMD3(0, 0.42, -0.185), SIMD3(0.145, 0.125, 0.055), 0.010, porc, 0.005)]         // cistern
        case .wallPipe:
            return pipeRunShapes(length: 1)                    // length comes from the Prop at pack time
        }
    }

    /// A CONTINUOUS pipe run for the wall-ceiling corner: parallel pipes + a thin
    /// conduit spanning `length` along local X, sat flush at the wall (local −Z) up
    /// near the ceiling, with brackets at intervals. Pipes carry something somewhere
    /// — so they run the length of the wall and tuck into the corner, never free-
    /// stand mid-room or stop dead at one cell (the beauty-shot read).
    static func pipeRunShapes(length: Float) -> [GShape] {
        let pipe = SIMD3<Float>(0.38, 0.40, 0.44), rusty = SIMD3<Float>(0.32, 0.25, 0.17)
        let darkM = SIMD3<Float>(0.12, 0.12, 0.15)
        let h = max(0.6, length) * 0.5                         // half-run
        let zw: Float = -0.40                                  // hard against the wall (cell centre is 0.5 off the wall face)
        // Kept deliberately LEAN (2 pipes + a couple of saddles): a pipe run's
        // bounding sphere is large, so every extra shape is evaluated for a big
        // fraction of the room's rays — the GPU cost lives here, not in the look.
        var out: [GShape] = [
            iCone(SIMD3(-h, 0.86, zw), SIMD3(h, 0.86, zw), 0.050, 0.050, pipe),            // main feed pipe
            iCone(SIMD3(-h, 0.74, zw + 0.05), SIMD3(h, 0.74, zw + 0.05), 0.036, 0.036, rusty)]   // return pipe, rustier, sits proud
        var x = -h + 0.5                                       // saddle brackets clamping the run to the wall
        while x <= h - 0.2 {
            out.append(iBox(SIMD3(x, 0.80, zw + 0.03), SIMD3(0.018, 0.16, 0.09), 0.005, darkM, 0.004))
            x += 2.4
        }
        return out
    }

    // ── fuel drums (material c.z = 4) — a weathered 200-litre industrial barrel ──
    // Authored standing on the floor (y 0 → ~0.46), front = local +Z. Deliberately
    // LEAN: just a body + a domed lid (2 shapes); the rolling hoop ribs, rust and
    // grime are painted in the kernel's drum branch (free), not modelled. A drum is
    // about chest height — the reference barrel — in red-oxide or a blue-grey steel.
    static func drumShapes(red: Bool) -> [GShape] {
        let body = red ? SIMD3<Float>(0.46, 0.17, 0.12) : SIMD3<Float>(0.20, 0.25, 0.31)   // red-oxide / blue-grey
        let rim = body * 0.7
        // a 200-litre steel barrel: a flat-capped cylinder standing FLAT on the deck
        // (centre 0.225, half-height 0.225 → base at y0, top at 0.45) + a rolled top
        // rim that sticks proud. Rolling hoops + rust are painted in the drum branch.
        return [iCylinder(SIMD3(0, 0.225, 0), r: 0.155, halfH: 0.225, round: 0.02, body, 0.012),  // body, flat top + flat base
                iCylinder(SIMD3(0, 0.452, 0), r: 0.168, halfH: 0.022, round: 0.012, rim, 0.012)]   // rolled top rim
    }

    /// A wall-mounted MARINE BULKHEAD LIGHT (~0.3 m): a steel base plate, a warm glass dome, and a
    /// protective wire cage of ribs + a hoop. Authored back-to-wall (−Z), dome facing +Z into the room,
    /// at eye height — mount via emitProp/packProp yaw + flush-to-wall. The dome is over-bright so it
    /// self-glows (low wattage — modest peak). The single geometry source, reused wherever a bulkhead hangs.
    static func bulkheadShapes() -> [GShape] {
        let steel = SIMD3<Float>(0.24, 0.25, 0.28)
        let cage  = SIMD3<Float>(0.13, 0.13, 0.15)
        let dome  = SIMD3<Float>(2.0, 1.45, 0.72)        // warm low-watt glow (over-bright → emissive)
        let y: Float = 0.56                              // eye height (mounted at authored height, floored:false)
        var out: [GShape] = [
            iBox(SIMD3(0, y, 0.018), SIMD3(0.105, 0.078, 0.024), 0.03, steel, 0.01),   // oval-ish steel base plate (rounded)
            iBox(SIMD3(0, y, 0.028), SIMD3(0.088, 0.061, 0.02), 0.02, steel * 1.15, 0.008), // raised bezel ring
            iSphere(SIMD3(0, y, 0.052), 0.062, dome),                                   // warm glass dome
        ]
        // wire cage: two verticals + one horizontal hoop bar across the dome
        for dx in [Float(-0.042), 0.042] {
            out.append(iBox(SIMD3(dx, y, 0.066), SIMD3(0.006, 0.066, 0.006), 0.003, cage, 0.002))
        }
        out.append(iBox(SIMD3(0, y, 0.078), SIMD3(0.07, 0.006, 0.006), 0.003, cage, 0.002))   // horizontal cage bar
        out.append(iBox(SIMD3(0, y + 0.086, 0.03), SIMD3(0.03, 0.012, 0.016), 0.006, steel, 0.004))  // top conduit lug
        return out
    }

    // ── recharge socket (material c.z = 5) — a flush WALL PANEL, not a floor unit ──
    // Wall-mounted infrastructure: a recessed housing with a vertical capacity bar
    // (segments lit up to the remaining charge) and a plug-in port, at chest height.
    // Authored back-to-wall (−Z) with the readout facing +Z into the room; packSockets
    // mounts it on the wall via yaw + the flush-to-wall shift, at its authored height
    // (NOT floored). The lit segments are over-bright so the kernel self-glows them.
    static func socketShapes(chargeFrac: Float, depleted: Bool = false) -> [GShape] {
        let housing = SIMD3<Float>(0.17, 0.19, 0.23), face = SIMD3<Float>(0.07, 0.08, 0.10)
        let lit = SIMD3<Float>(0.40, 1.45, 1.70), off = SIMD3<Float>(0.10, 0.13, 0.15)
        // drained: every lamp on the panel turns RED until the reserve re-arms
        let redLit = SIMD3<Float>(3.30, 0.16, 0.10), redOff = SIMD3<Float>(0.34, 0.05, 0.04)   // over-bright so the drained indicator still self-glows: red carries low luminance, so it must be high to cross the emissive gate — keeps the panel lit rather than winking out (which read as a local "dim")
        let frac = max(0, min(1, chargeFrac))
        let cy: Float = 0.52                                                                   // chest height
        var out: [GShape] = [
            iBox(SIMD3(0, cy, 0.02), SIMD3(0.135, 0.17, 0.035), 0.012, housing, 0.006),        // recessed housing (shallow)
            iBox(SIMD3(0, cy, 0.05), SIMD3(0.115, 0.15, 0.012), 0.004, face, 0.003),           // dark inset faceplate
        ]
        let segs = 4                                                                            // capacity bar
        for k in 0..<segs {
            let f = (Float(k) + 0.5) / Float(segs)
            let col = depleted ? (k == 0 ? redLit : redOff) : (f <= frac ? lit : off)
            out.append(iBox(SIMD3(-0.055, cy - 0.10 + Float(k) * 0.067, 0.062), SIMD3(0.05, 0.026, 0.006), 0.002, col, 0.0015))
        }
        out.append(iBox(SIMD3(0.07, cy, 0.06), SIMD3(0.04, 0.05, 0.008), 0.006, face, 0.003))   // plug-in port recess
        // PORT LAMP — a hemisphere standing ON the recess face, so its equator is exactly the surface
        // it emerges from. Its centre used to sit at z 0.066, two millimetres BEHIND that face (the
        // recess front is at 0.052 + 0.008 × 2 = 0.068), which showed slightly more than half a ball
        // with the faceplate cutting across it — a lamp that read as three-quarters of a sphere
        // clipped by the panel rather than as a domed indicator set into it.
        out.append(iSphere(SIMD3(0.07, cy, 0.068), 0.02,
                           depleted ? SIMD3<Float>(0.85, 0.14, 0.10) : SIMD3<Float>(0.22, 0.50, 0.60)))
        return out
    }

    private static func shapeZExtent(_ sh: GShape) -> (lo: Float, hi: Float) {
        if sh.b.w < -3.5 { return (sh.a.z - sh.b.y, sh.a.z + sh.b.y) }                      // z-disc (half-length b.y along Z)
        if sh.b.w < -2.5 { return (sh.a.z - sh.a.w, sh.a.z + sh.a.w) }                      // cylinder (radius a.w)
        if sh.b.w < -1.5 { return (sh.a.z - sh.b.z - sh.a.w, sh.a.z + sh.b.z + sh.a.w) }   // box
        if sh.b.w < 0   { return (sh.a.z - sh.a.w, sh.a.z + sh.a.w) }                       // sphere
        return (min(sh.a.z - sh.a.w, sh.b.z - sh.b.w), max(sh.a.z + sh.a.w, sh.b.z + sh.b.w))
    }
    private static func shapeXExtent(_ sh: GShape) -> (lo: Float, hi: Float) {
        if sh.b.w < -2.5 { return (sh.a.x - sh.a.w, sh.a.x + sh.a.w) }                      // cylinder (radius a.w)
        if sh.b.w < -1.5 { return (sh.a.x - sh.b.x - sh.a.w, sh.a.x + sh.b.x + sh.a.w) }   // box
        if sh.b.w < 0   { return (sh.a.x - sh.a.w, sh.a.x + sh.a.w) }                       // sphere
        return (min(sh.a.x - sh.a.w, sh.b.x - sh.b.w), max(sh.a.x + sh.a.w, sh.b.x + sh.b.w))
    }
    /// A piece of furniture's floor footprint as half-extents (X = along the wall, Z =
    /// into the room), derived from its authored geometry — the SINGLE source for both
    /// the rendered shape and the solid-collision box, so they can never drift apart.
    static func furnitureFootprint(_ kind: FurnitureKind) -> (halfW: Float, halfD: Float) {
        let sl = furnitureShapes(kind)
        var minX: Float = 1e9, maxX: Float = -1e9, minZ: Float = 1e9, maxZ: Float = -1e9
        for sh in sl {
            let ex = shapeXExtent(sh), ez = shapeZExtent(sh)
            minX = min(minX, ex.lo); maxX = max(maxX, ex.hi)
            minZ = min(minZ, ez.lo); maxZ = max(maxZ, ez.hi)
        }
        return ((maxX - minX) * 0.5, (maxZ - minZ) * 0.5)
    }
    /// Shove a wall piece back so its rear face sits flush against the wall. Local −Z
    /// is the wall side; the cell centre is 0.5 off the wall face, so the back lands
    /// at −wallBack (just shy of −0.5 to avoid z-fighting). Derived from the authored
    /// geometry, so it never drifts from the model — no per-kind magic depth.
    private static func flushToWall(_ shapes: inout [GShape], wallBack: Float = 0.46) {
        var minZ: Float = 1e9
        for sh in shapes { minZ = min(minZ, shapeZExtent(sh).lo) }
        let dz = -wallBack - minZ
        for i in shapes.indices {
            shapes[i].a.z += dz
            if shapes[i].b.w >= 0 { shapes[i].b.z += dz }   // round-cone: second endpoint is a real position
        }
    }

    /// Pack furniture/fixtures into the shared GMonster/GShape buffers (no bob, no
    /// spin — they sit where MapGen placed them, oriented by yaw). Material c.z = 3.
    static func packProps(_ props: [Prop], time: Float = 0, signalDeck: SIMD2<Float>? = nil, budget: Int = 220) -> ([GMonster], [GShape]) {
        var mons: [GMonster] = [], shapes: [GShape] = []
        for pr in props {
            var sl: [GShape]
            if pr.kind == .wallPipe {
                sl = pipeRunShapes(length: pr.length)
            } else if pr.kind == .tapeDeck, let dk = signalDeck, abs(dk.x - pr.pos.x) < 0.3, abs(dk.y - pr.pos.y) < 0.3 {
                sl = tapeDeckShapes(spin: time * 2.6, playing: true)   // this deck is rolling — reels turn, REC lit
            } else {
                sl = furnitureShapes(pr.kind)
            }
            if sl.isEmpty { continue }                          // a decal-only prop (papers) has no SDF — SKIP it, don't break the loop (that dropped every prop packed after it → furniture popped in/out)
            if shapes.count + sl.count > budget { break }
            // Wall pieces sit flush to the wall (bunk/desk/locker stood ~⅓-cell proud
            // before — "approx 1m" off). A free-standing chair keeps its placement.
            if pr.againstWall && pr.kind != .wallPipe { flushToWall(&sl) }
            var loY: Float = 1e9, hiY: Float = -1e9
            for sh in sl { let e = shapeYExtent(sh); loY = min(loY, e.lo); hiY = max(hiY, e.hi) }
            let boundCY = (loY + hiY) / 2
            var boundR: Float = 0
            for sh in sl { boundR = max(boundR, shapeRadius(sh, boundCY)) }
            boundR += 0.05
            let start = shapes.count
            shapes.append(contentsOf: sl)
            // Floor furniture sits feet-on-deck (loY → floor); a WALL-MOUNTED pipe run
            // is authored at its true height up the wall, so it must keep it (yOff 0) —
            // flooring dragged the run down into the bunks.
            let yOff: Float = pr.kind == .wallPipe ? 0 : loY
            mons.append(GMonster(a: SIMD4(pr.pos.x, pr.pos.y, pr.yaw, 1),
                                 b: SIMD4(Float(start), Float(sl.count), boundR, boundCY),
                                 c: SIMD4(yOff, 0, 3, 0)))   // c.z = 3 → opaque industrial prop
        }
        return (mons, shapes)
    }

    /// Pack fuel drums (material c.z = 4). Red/blue alternates by a stable hash of
    /// the drum's cell so a barrel keeps its colour frame-to-frame. Feet on the deck.
    static func packDrums(_ drums: [Drum], budget: Int = 96) -> ([GMonster], [GShape]) {
        var mons: [GMonster] = [], shapes: [GShape] = []
        for d in drums {
            let key = Int(d.pos.x.rounded()) &* 73856093 ^ Int(d.pos.y.rounded()) &* 19349663
            let sl = drumShapes(red: (key & 1) == 0)
            if shapes.count + sl.count > budget { break }
            var loY: Float = 1e9, hiY: Float = -1e9
            for sh in sl { let e = shapeYExtent(sh); loY = min(loY, e.lo); hiY = max(hiY, e.hi) }
            let boundCY = (loY + hiY) / 2
            var boundR: Float = 0
            for sh in sl { boundR = max(boundR, shapeRadius(sh, boundCY)) }
            boundR += 0.05
            let start = shapes.count
            shapes.append(contentsOf: sl)
            mons.append(GMonster(a: SIMD4(d.pos.x, d.pos.y, 0, 1),
                                 b: SIMD4(Float(start), Float(sl.count), boundR, boundCY),
                                 c: SIMD4(loY, 0, 4, 0)))   // c.z = 4 → fuel drum
        }
        return (mons, shapes)
    }

    /// Pack recharge sockets (material c.z = 5). A charged socket's cell self-glows;
    /// a drained one is authored dark so the marine reads it as spent.
    static func packSockets(_ sockets: [Socket], budget: Int = 64) -> ([GMonster], [GShape]) {
        var mons: [GMonster] = [], shapes: [GShape] = []
        for sk in sockets {
            var sl = socketShapes(chargeFrac: Float(sk.charge) / Float(max(1, sk.maxCharge)), depleted: sk.depleted)
            if shapes.count + sl.count > budget { break }
            flushToWall(&sl)                                   // mount the panel flush on the wall behind
            var loY: Float = 1e9, hiY: Float = -1e9
            for sh in sl { let e = shapeYExtent(sh); loY = min(loY, e.lo); hiY = max(hiY, e.hi) }
            let boundCY = (loY + hiY) / 2
            var boundR: Float = 0
            for sh in sl { boundR = max(boundR, shapeRadius(sh, boundCY)) }
            boundR += 0.05
            let start = shapes.count
            shapes.append(contentsOf: sl)
            mons.append(GMonster(a: SIMD4(sk.pos.x, sk.pos.y, sk.yaw, 1),   // yaw mounts it onto the wall
                                 b: SIMD4(Float(start), Float(sl.count), boundR, boundCY),
                                 c: SIMD4(0, 0, 5, 0)))        // yOff 0 → keep its authored chest height (not floored)
        }
        return (mons, shapes)
    }

    // ── deployed proximity mine (material c.z = 6) — a low floor puck + a pulsing
    // red trigger LED, so you can spot a live mine in the dark (and not cross your own)
    static func mineShapes() -> [GShape] {
        let body = SIMD3<Float>(0.16, 0.17, 0.20), collar = SIMD3<Float>(0.10, 0.11, 0.13)
        // a small, LOW disc the marine steps over (≈0.23 across, ≈0.12 tall — in line
        // with the old sprite, not larger). No collision; aliens cross it to trigger it.
        return [iCylinder(SIMD3(0, 0.026, 0), r: 0.115, halfH: 0.026, round: 0.01, body, 0.01),    // low puck on the deck
                iCylinder(SIMD3(0, 0.060, 0), r: 0.06, halfH: 0.016, round: 0.008, collar, 0.01),  // collar
                iSphere(SIMD3(0, 0.090, 0), 0.024, SIMD3<Float>(1.6, 0.10, 0.08))]                  // bright red trigger LED
    }
    /// Pack deployed mines (material c.z = 6), feet on the deck.
    static func packMines(_ mines: [Mine], budget: Int = 48) -> ([GMonster], [GShape]) {
        var mons: [GMonster] = [], shapes: [GShape] = []
        for mn in mines {
            let sl = mineShapes()
            if shapes.count + sl.count > budget { break }
            var loY: Float = 1e9, hiY: Float = -1e9
            for sh in sl { let e = shapeYExtent(sh); loY = min(loY, e.lo); hiY = max(hiY, e.hi) }
            let boundCY = (loY + hiY) / 2
            var boundR: Float = 0
            for sh in sl { boundR = max(boundR, shapeRadius(sh, boundCY)) }
            boundR += 0.05
            let start = shapes.count
            shapes.append(contentsOf: sl)
            mons.append(GMonster(a: SIMD4(mn.pos.x, mn.pos.y, 0, 1),
                                 b: SIMD4(Float(start), Float(sl.count), boundR, boundCY),
                                 c: SIMD4(loY, 0, 6, 0)))   // c.z = 6 → deployed mine
        }
        return (mons, shapes)
    }

    // ── projectiles as in-kernel emissive orbs (material c.z = 2) ──────────────
    static func projColor(_ k: ProjectileKind) -> SIMD3<Float> {
        switch k {
        case .plasma:   return SIMD3(0.28, 0.72, 1.20)
        case .rocket:   return SIMD3(1.00, 0.52, 0.18)
        case .bolt:     return SIMD3(1.00, 0.80, 0.26)
        case .fireball: return SIMD3(1.00, 0.38, 0.12)
        case .bfgBall:  return SIMD3(0.40, 1.15, 0.38)
        }
    }
    static func projRadius(_ k: ProjectileKind) -> Float {
        switch k {
        case .bfgBall:  return 0.26
        case .fireball: return 0.17
        case .rocket:   return 0.15
        case .plasma:   return 0.12
        case .bolt:     return 0.11
        }
    }
    /// Pack projectiles as single emissive spheres at eye height, flagged c.z = 2
    /// so the kernel shades them as glowing orbs (paired with the dynamic light
    /// each already casts, so they glow AND light the room).
    static func packProjectiles(_ projs: [Projectile], eyeY: Float = 0.5, cap: Int = 24) -> ([GMonster], [GShape]) {
        var mons: [GMonster] = [], shapes: [GShape] = []
        for pr in projs {
            if mons.count >= cap { break }
            let r = projRadius(pr.kind)
            let start = shapes.count
            let col = projColor(pr.kind)
            // a bolt in flight is a STREAK, not a dot: the head orb plus a
            // fading tail stretched over ~45 ms of its own motion. Without it
            // a fast bolt lives three frames as a barely-visible dot, and
            // close-range fire has no visual at all.
            let speed = simd_length(pr.vel)
            let len = min(0.8, speed * 0.045)
            let yaw = atan2(pr.vel.y, pr.vel.x) + .pi / 2            // local -z = direction of flight
            // geometry is centred on the streak's midpoint so the bounding
            // sphere hugs it: anchored at the head the bound was len+r wide
            // and every ray inside it paid the detail evaluation — with a
            // dozen bolts in flight that was real frame time.
            shapes.append(iSphere(SIMD3(0, 0, -len / 2), r, col, 0.01))
            if len > 0.05 {
                shapes.append(iCone(SIMD3(0, 0, -len / 2), SIMD3(0, 0, len / 2), r * 0.85, r * 0.25, col * 0.55, 0.02))
            }
            let dirU = speed > 0.001 ? pr.vel / speed : SIMD2<Float>(1, 0)
            let anchor = pr.pos - dirU * (len / 2)                   // head stays exactly at pr.pos
            mons.append(GMonster(a: SIMD4(anchor.x, anchor.y, yaw, 1),
                                 b: SIMD4(Float(start), Float(shapes.count - start), len / 2 + r + 0.05, 0),
                                 c: SIMD4(0, eyeY, 2, 0)))           // centred at eye height; c.z = 2 (orb)
        }
        return (mons, shapes)
    }

    /// Build the kernel light buffer: the emitter point lights culled to what can
    /// reach the camera, ordered shadow-casters-first (so `extra.z` can gate which
    /// few march a shadow), the muzzle/projectile lights appended, capped to the
    /// buffer budget. Returns the packed lights and how many lead lights shadow.
    static func packLights(_ emitters: [Lighting.PointLight], camera: SIMD2<Float>,
                           muzzle: [GPULight] = [], maxLights: Int = 16, maxShadow: Int = 3) -> (lights: [GPULight], shadowCount: Int) {
        func toGPU(_ l: Lighting.PointLight) -> GPULight {
            GPULight(posR: SIMD4(l.pos.x, l.pos.y, l.pos.z, 1 / (l.radius * l.radius)),
                     colI: SIMD4(l.color.x, l.color.y, l.color.z, l.intensity))
        }
        func d2(_ l: Lighting.PointLight) -> Float { simd_length_squared(SIMD2(l.pos.x, l.pos.z) - camera) }
        // only fixtures whose reach can touch the camera neighbourhood matter
        let near = emitters.filter { d2($0) < ($0.radius + 6) * ($0.radius + 6) }
        let keys  = near.filter { $0.shadow }.sorted { d2($0) < d2($1) }
        let fills = near.filter { !$0.shadow }.sorted { d2($0) < d2($1) }
        // shadowed keys first (capped), then the muzzle lights (also shadowed — they
        // are the player's own dramatic light), then the cheap unshadowed colour fills
        let shadowKeys = Array(keys.prefix(maxShadow))
        var ordered = shadowKeys.map(toGPU)
        ordered.append(contentsOf: muzzle)
        let shadowCount = ordered.count                        // keys + muzzle all shadow
        ordered.append(contentsOf: fills.map(toGPU))
        if ordered.count > maxLights { ordered = Array(ordered.prefix(maxLights)) }
        return (ordered, min(shadowCount, ordered.count))
    }


    /// The procedural texture set (with baked relief) as a sampled 2-D array —
    /// the GPU walls/flats look up their cell's material id and sample this.
    static func makeTextureArray(_ device: MTLDevice, _ texs: [Texture]) -> MTLTexture? {
        guard let first = texs.first else { return nil }
        let sz = first.size
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray; d.pixelFormat = .rgba8Unorm
        d.width = sz; d.height = sz; d.arrayLength = texs.count
        d.usage = .shaderRead; d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        for (i, t) in texs.enumerated() {
            // The array assumes a uniform tile size (every Texture is `size` today).
            // A mismatched tile would make replace() read past its pixel buffer —
            // assert in dev, and skip the slice in release rather than read OOB.
            assert(t.size == sz && t.pixels.count >= sz * sz, "makeTextureArray: non-uniform tile (\(t.size) vs \(sz))")
            guard t.size == sz, t.pixels.count >= sz * sz else { continue }
            t.pixels.withUnsafeBytes {
                tex.replace(region: MTLRegionMake2D(0, 0, sz, sz), mipmapLevel: 0, slice: i,
                            withBytes: $0.baseAddress!, bytesPerRow: sz * 4, bytesPerImage: sz * sz * 4)
            }
        }
        return tex
    }

    /// Per-cell material-id grid (nearest-read in the kernel).
    static func makeIdTexture(_ device: MTLDevice, _ ids: [Int], _ w: Int, _ h: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Uint, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead; d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        let u = ids.map { UInt16(clamping: $0) }
        u.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 2) }
        return tex
    }

    /// Camera at the mouth of the longest *narrow* corridor in the map, looking
    /// straight down its long axis — a dark receding hallway directly comparable
    /// to the BeautyProof corridor hero. (The player's spawn lands in a bright,
    /// wide open room, which is useless for judging the moody-corridor target
    /// look — that mismatch is why earlier GPU stills read as "a bright test room".)
    static func bestCorridorView(_ map: GameMap) -> (pos: SIMD2<Float>, dir: Float, depth: Int)? {
        @inline(__always) func open(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < map.w && y < map.h && map.wall[map.idx(x, y)] == 0
        }
        let dirs: [(dx: Int, dy: Int, ang: Float)] = [
            (1, 0, 0), (-1, 0, .pi), (0, 1, .pi / 2), (0, -1, -.pi / 2)]
        var best: (score: Float, pos: SIMD2<Float>, dir: Float, depth: Int)?
        for y in 0..<map.h {
            for x in 0..<map.w where open(x, y) {
                for d in dirs {
                    if open(x - d.dx, y - d.dy) { continue }        // camera sits at a closed end
                    var len = 0, cx = x, cy = y
                    while open(cx, cy) && len < 64 { cx += d.dx; cy += d.dy; len += 1 }
                    if len < 5 { continue }
                    let px = d.dy, py = d.dx                         // perpendicular axis
                    var width = 1, k = 1
                    while open(x + px * k, y + py * k) { width += 1; k += 1 }
                    k = 1
                    while open(x - px * k, y - py * k) { width += 1; k += 1 }
                    let score = Float(len) - Float(width) * 1.5      // long + narrow wins
                    if best == nil || score > best!.score {
                        best = (score, SIMD2(Float(x) + 0.5, Float(y) + 0.5), d.ang, len)
                    }
                }
            }
        }
        guard let b = best else { return nil }
        return (b.pos, b.dir, b.depth)
    }

    // ── transient COMBAT lights ─────────────────────────────────────────────────
    // Muzzle flash, flamethrower, blasts, burning pyres, projectiles: a pure function of `world`,
    // so both render paths light the scene identically. It lived on GPUWorldRenderer until that
    // renderer was retired; it belongs here beside GPULight and the rest of the shared scene data.
    /// Muzzle flash + projectile glows as point lights for the GPU kernel
    /// (mirrors WorldLight.gatherLights, at eye height in 3-D).
    // Pure function of `world` (muzzle/flame/elevator/teleport/blast/pyre/projectile point lights) —
    // STATIC so the raster path reuses it too. (M6: relocate to GPURaymarch alongside packLights.)
    static func gatherDynLights(_ world: World) -> [GPURaymarch.GPULight] {
        var out: [GPURaymarch.GPULight] = []
        let p = world.player
        if p.muzzle > 0 && world.flameJet.t <= 0 {   // the flamethrower has its own warm light (below) — no cold muzzle flash
            let mz = min(1, p.muzzle / 0.07), rad: Float = 6.5
            out.append(GPURaymarch.GPULight(posR: SIMD4(p.pos.x, 0.5, p.pos.y, 1 / (rad * rad)),
                                            colI: SIMD4(1.0, 0.86, 0.55, 1.7 * mz)))
        }
        // the flamethrower jet throws warm firelight down the aim — the stream
        // lights the room ahead and flares against the wall it splashes on,
        // guttering on two incommensurate rates so it never pulses in rhythm
        let jt = world.flameJet
        if jt.t > 0 {
            let s0 = min(1, jt.t / 0.10)
            let flick = 0.80 + 0.20 * sinf(world.elapsed * 31) + 0.12 * sinf(world.elapsed * 67 + 1.3)
            let reach = max(0.6, jt.reach)
            let mid = jt.nozzle + jt.dir * min(reach * 0.5, 1.6)
            let far = jt.nozzle + jt.dir * (reach - 0.2)
            let rM: Float = 4.2, rF: Float = 3.0
            out.append(GPURaymarch.GPULight(posR: SIMD4(mid.x, 0.5, mid.y, 1 / (rM * rM)),
                                            colI: SIMD4(1.0, 0.55, 0.20, 1.6 * s0 * flick)))
            out.append(GPURaymarch.GPULight(posR: SIMD4(far.x, 0.45, far.y, 1 / (rF * rF)),
                                            colI: SIMD4(1.0, 0.48, 0.16, 1.1 * s0 * flick)))
        }
        // elevator cabin light — the car interior is pitch dark once the leaves
        // shut (no baked light reaches it), so a car in use carries its own lamp.
        // During the descent the lamp sways and shaft lights sweep past the cage.
        func cabin(_ cell: Int, descending: Bool) -> GPURaymarch.GPULight {
            let cx = Float(cell % world.map.w) + 0.5, cz = Float(cell / world.map.w) + 0.5
            var inten: Float = 0.85
            if descending {
                let t = world.elapsed
                inten = 0.55 + 0.20 * sinf(t * 2.6)                    // the cabin lamp swaying
                inten += 1.1 * powf(max(0, sinf(t * 3.6)), 12)         // a shaft light sweeping past
            }
            let rad: Float = 2.6
            return GPURaymarch.GPULight(posR: SIMD4(cx, 0.78, cz, 1 / (rad * rad)),
                                        colI: SIMD4(1.0, 0.93, 0.76, inten))
        }
        if world.elevatorPhase != .idle, world.map.exitCell >= 0 {
            out.append(cabin(world.map.exitCell, descending: world.elevatorPhase == .descending))
        }
        if world.map.entryCell >= 0, (world.map.doors[world.map.entryCell]?.open ?? 0) > 0.01 {
            out.append(cabin(world.map.entryCell, descending: false))
        }
        // teleporter pads carry their own COLD light, hugging the deck (a lamp at
        // eye height washes the chamber to white): the exit pad breathes on
        // standby, lifts under a boarder, and flares as the charge ramps; the
        // arrival receiver glows as the marine materialises, then dies down.
        func padLight(_ cell: Int, _ inten: Float, _ reach: Float) -> GPURaymarch.GPULight {
            let cx = Float(cell % world.map.w) + 0.5, cz = Float(cell / world.map.w) + 0.5
            return GPURaymarch.GPULight(posR: SIMD4(cx, 0.18, cz, 1 / (reach * reach)),
                                        colI: SIMD4(0.55, 0.85, 1.0, inten))
        }
        if world.isTeleportFloor, world.map.exitCell >= 0, world.map.wall[world.map.exitCell] == 0 {
            let charge: Float = world.teleportPhase == .charging ? world.teleportT
                              : (world.teleportPhase == .await ? 0.12 : 0)
            let breathe = 0.16 + 0.04 * sinf(world.elapsed * 2.2)
            out.append(padLight(world.map.exitCell, breathe + 1.2 * charge, 2.0 + 1.6 * charge))
        }
        if world.arrivalGlow > 0.01, world.map.entryCell >= 0 {
            out.append(padLight(world.map.entryCell, 0.10 + 0.45 * world.arrivalGlow, 2.2))
        }
        // impact flashes light the room — fierce, decaying, coloured per cause
        // (warm for detonations, plasma-cyan for bolt splashes)
        for b in world.blasts {
            let f = max(0, b.t / 0.3)
            let rad: Float = 5.5
            out.append(GPURaymarch.GPULight(posR: SIMD4(b.pos.x, 0.5, b.pos.y, 1 / (rad * rad)),
                                            colI: SIMD4(b.col.x, b.col.y, b.col.z, 2.4 * f)))
        }
        // burning corpses cast a live orange firelight that builds and dies with
        // the pyre — the room flickers while a body burns
        for (i, m) in world.monsters.enumerated() where m.state == .dead && m.burn > 0 && m.burn < 1 {
            let flare = sinf(m.burn * .pi)
            // gutter on two incommensurate rates, desynced per corpse — no rhythm
            let ph = Float(i) * 1.7
            let flick = 0.80 + 0.14 * sinf(world.elapsed * 13 + ph) + 0.10 * sinf(world.elapsed * 29 + ph * 2.3)
            let rad: Float = 3.6
            out.append(GPURaymarch.GPULight(posR: SIMD4(m.pos.x, 0.45, m.pos.y, 1 / (rad * rad)),
                                            colI: SIMD4(1.0, 0.55, 0.22, (0.4 + 1.3 * flare) * flick)))
            if out.count >= 14 { break }
        }
        for pr in world.projectiles {
            let c: (Float, Float, Float), rad: Float, it: Float
            switch pr.kind {
            case .plasma:   c = (0.50, 0.85, 1.00); rad = 3.6; it = 1.0
            case .rocket:   c = (1.00, 0.70, 0.40); rad = 3.0; it = 0.8
            case .bolt:     c = (1.00, 0.85, 0.40); rad = 3.0; it = 0.9
            case .fireball: c = (1.00, 0.45, 0.18); rad = 4.0; it = 1.2
            case .bfgBall:  c = (0.50, 1.00, 0.45); rad = 5.5; it = 1.6
            }
            out.append(GPURaymarch.GPULight(posR: SIMD4(pr.pos.x, 0.5, pr.pos.y, 1 / (rad * rad)),
                                            colI: SIMD4(c.0, c.1, c.2, it)))
            if out.count >= 16 { break }
        }
        return out
    }
}
