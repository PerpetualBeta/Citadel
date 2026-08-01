// Citadel — the static level mesh.
//
// Everything in a floor that NEVER MOVES, built once when the level is entered: walls, floors and
// ceilings, the roof steelwork over the double-height halls, wall pipework, the imported plant
// machinery, and the bulkhead light fixtures. One vertex array, one GPU buffer, drawn every frame
// without being touched again. The per-frame prop pass (doors, drums, sockets, the weapon) is a
// separate, much smaller buffer and stays in the renderer.
//
// WHY THIS IS ITS OWN TYPE. This was 425 lines inside RasterRenderer, and it did not just build a
// mesh — it wrote its results into EIGHT of the renderer's stored properties: the lamp cells, two
// per-cell mask arrays, the plant and hall lamp lists, two vertex counters, the buffer itself. Read
// as a function it took a world and returned nothing; what it actually did was leave its output
// scattered across the object. That is what made it impossible to read the level build in isolation,
// and it is why "move these five functions to another file" was not available: text alone would have
// meant widening sixteen private fields to internal, trading one coupling for a worse one.
//
// So it OWNS its state and RETURNS it. `Built` is the whole output, by value, and the renderer stores
// what it needs. The renderer's own concerns stayed behind on purpose:
//
//   • THE GPU BUFFER. The builder returns `[PVert]`; making an MTLBuffer out of it is resource
//     management, and a mesh builder that needs an MTLDevice to answer is not a mesh builder.
//   • THE MESH CACHES. loadMachine/loadBulkhead memoise multi-megabyte OBJ parses and must outlive
//     any one level, so they cannot belong to a per-level object. The loaded meshes arrive as inputs
//     instead — `bulkhead` directly, machines through a closure, since which kinds are asked for
//     depends on what the floor generated.
//
// The geometry emitters and the material palette are in MeshEmit.swift, shared with the per-frame
// pass. This file is the ORDER those pieces are assembled in — which is all a level build ever was.

import Foundation
import simd

struct LevelMeshBuilder {

    typealias PVert = RasterRenderer.PVert
    typealias Mat = RasterRenderer.Mat

    /// The complete result of a level build. Nothing else changes when `build` runs.
    struct Built {
        var verts: [PVert] = []
        /// Cell centres carrying a ceiling lamp — the renderer surfaces the nearest few as point lights.
        var lampCells: [SIMD2<Float>] = []
        /// Per-cell R8 masks uploaded as textures: lamp presence (0 solid · 128 open · 255 lamp) and
        /// the M6 floor id the fragment reads to give nukage/rock/blood their liquid surface.
        var lampMask: [UInt8] = []
        var floorIds: [UInt8] = []
        /// Light SITES, kept apart from the mesh because the renderer picks the nearest handful per
        /// frame: wall bulkheads on the plant floors, downlights slung under the hall trusses.
        var plantLamps: [(pos: SIMD2<Float>, yaw: Float, light: SIMD2<Float>)] = []
        var hallLamps: [SIMD3<Float>] = []
        /// Vertex tallies for the harness probes, which report what each subsystem costs.
        var pipeVerts = 0
        var machineVerts = 0
    }

    // ── inputs ──
    let world: World
    /// False on the plant floors (7–8), which are lit by wall bulkheads instead of a ceiling grid.
    /// It gates the lamp grid, the roof steelwork and the plant lamps alike, so it is one flag, not three.
    let ceilingLampsOn: Bool
    /// The imported bulkhead-lamp mesh, or nil to fall back to the procedural caged lamp.
    let bulkhead: [PVert]?
    /// The imported machine mesh for a prop kind, normalised to height 1, with the live height knob
    /// already applied — nil for a kind that is not machinery or whose load failed.
    let machine: (FurnitureKind) -> (mesh: [PVert], scale: Float)?

    private var out = Built()

    /// Build the level. The two calls are in the order they must run: the plant lamps are SITED first
    /// because the wall fixtures then emit geometry at each site.
    static func build(world: World, ceilingLampsOn: Bool, bulkhead: [PVert]?,
                      machine: @escaping (FurnitureKind) -> (mesh: [PVert], scale: Float)?) -> Built {
        var b = LevelMeshBuilder(world: world, ceilingLampsOn: ceilingLampsOn, bulkhead: bulkhead, machine: machine)
        b.buildPlantLamps(world.map)
        b.buildMesh(world)
        return b.out
    }

    /// Site the PLANT floors' bulkhead fixtures (7–8 only; the upper floors keep their ceiling grid). Walk a
    /// coarse grid of open cells and, where one backs onto a solid wall, hang a fixture on that wall facing into
    /// the room at eye height. Deliberately offset from the ceiling-lamp grid's phase so the two never coincide.
    /// WHERE the plant floors' bulkhead fixtures hang — a PURE function of the map, and `static`
    /// deliberately: MapGen calls it too, before it furnishes, so the furnishing passes can keep a
    /// locker off a wall that carries a lamp. Two systems each deciding this for themselves is how a
    /// wardrobe ended up parked in front of a light fixture; sharing the one walk makes that
    /// impossible rather than unlikely. Returns the mount, its yaw, the light point, and the WALL
    /// CELL it is bolted to (which is what MapGen needs).
    static func plantLampSites(_ map: GameMap) -> [(pos: SIMD2<Float>, yaw: Float, light: SIMD2<Float>, wall: Int)] {
        var out: [(SIMD2<Float>, Float, SIMD2<Float>, Int)] = []
        let stride = 4, phase = 1                                   // one fixture per ~4 cells of wall run — enough to
                                                                    // navigate by; the plant stays deliberately gloomy
        for y in 1..<(map.h - 1) where y % stride == phase {
            for x in 1..<(map.w - 1) where x % stride == phase {
                let i = map.idx(x, y)
                guard map.wall[i] == 0, map.doors[i] == nil, !map.hazard[i] else { continue }
                for (dx, dy) in [(0, -1), (0, 1), (-1, 0), (1, 0)] {          // first solid neighbour = the mounting wall
                    let wx = x + dx, wy = y + dy
                    guard map.inBounds(wx, wy) else { continue }
                    let wi = map.idx(wx, wy)
                    guard map.wall[wi] != 0, map.doors[wi] == nil else { continue }
                    let inward = SIMD2<Float>(-Float(dx), -Float(dy))          // wall → room
                    let mount = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5) - inward * 0.46   // sit on the wall face
                    out.append((mount, atan2(-inward.x, inward.y), mount + inward * 0.16, wi))
                    break
                }
            }
        }
        return out
    }

    private mutating func buildPlantLamps(_ map: GameMap) {
        out.plantLamps.removeAll(keepingCapacity: true)
        guard !ceilingLampsOn else { return }
        out.plantLamps = LevelMeshBuilder.plantLampSites(map).map { ($0.pos, $0.yaw, $0.light) }
    }

    private mutating func buildMesh(_ world: World) {
        let map = world.map
        var v: [PVert] = []; v.reserveCapacity(map.w * map.h * 12)
        out.lampCells.removeAll(keepingCapacity: true)
        out.lampMask = [UInt8](repeating: 0, count: map.w * map.h)   // per-cell lamp-presence, stamped at the same site as the housing
        out.floorIds = [UInt8](repeating: 0, count: map.w * map.h)     // M6 per-cell floor id (nukage/rock/blood drive the liquid treatment in the fragment)
        func openGeo(_ x: Int, _ y: Int) -> Bool {
            guard map.inBounds(x, y) else { return false }
            let i = map.idx(x, y); return map.wall[i] == 0 || map.doors[i] != nil
        }
        func vert(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ m: Mat, _ tid: Float = -1) -> PVert {
            PVert(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z,
                  ar: m.a.x, ag: m.a.y, ab: m.a.z, rough: m.r, metal: m.m, er: m.e.x, eg: m.e.y, eb: m.e.z, tid: tid)
        }
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ n: SIMD3<Float>, _ m: Mat, _ tid: Float = -1) {
            v += [vert(a, n, m, tid), vert(b, n, m, tid), vert(c, n, m, tid), vert(a, n, m, tid), vert(c, n, m, tid), vert(d, n, m, tid)]
        }
        // the solid wall id at a neighbour cell → the texture slice to sample (−1 = out of bounds)
        func wallIdF(_ x: Int, _ y: Int) -> Float { map.inBounds(x, y) ? Float(map.wall[map.idx(x, y)]) : -1 }
        // A floor/ceiling cell is emitted as an 8-triangle CENTRE FAN whose material is C0-continuous
        // across cell edges: corner verts carry the mean material of the 2×2 open cells meeting there,
        // edge-midpoints the mean of the two open cells sharing that edge, and only the CENTRE vert keeps
        // the cell's own pure material. Two neighbours therefore compute IDENTICAL shared-edge/corner
        // materials, so a lone darker flat (grate/metal patch) feathers into its surroundings over ~0.5 m
        // instead of meeting concrete at a razor grid line — the "hard dark quad on the floor". The centre
        // stays full-strength so the patch (and emissive floors' cores) still read. NO lighting is touched.
        func blendedSurface(_ mx: Int, _ my: Int, _ yy: Float, _ nrm: SIMD3<Float>, _ src: (Int) -> Int) {
            let own = RasterRenderer.flatMat(src(map.idx(mx, my)))
            let fx = Float(mx), fz = Float(my)
            func avg(_ cells: [(Int, Int)]) -> Mat {
                var a = SIMD3<Float>.zero, r: Float = 0, m: Float = 0, e = SIMD3<Float>.zero, n: Float = 0
                for (ox, oy) in cells where openGeo(ox, oy) {
                    let mt = RasterRenderer.flatMat(src(map.idx(ox, oy)))
                    a += mt.a; r += mt.r; m += mt.m; e += mt.e; n += 1
                }
                return n > 0 ? Mat(a: a / n, r: r / n, m: m / n, e: e / n) : own
            }
            let c00 = avg([(mx-1,my-1),(mx,my-1),(mx-1,my),(mx,my)])
            let c10 = avg([(mx,my-1),(mx+1,my-1),(mx,my),(mx+1,my)])
            let c11 = avg([(mx,my),(mx+1,my),(mx,my+1),(mx+1,my+1)])
            let c01 = avg([(mx-1,my),(mx,my),(mx-1,my+1),(mx,my+1)])
            let en = avg([(mx,my),(mx,my-1)]), ee = avg([(mx,my),(mx+1,my)])
            let es = avg([(mx,my),(mx,my+1)]), ew = avg([(mx,my),(mx-1,my)])
            let ring: [(SIMD3<Float>, Mat)] = [
                (SIMD3(fx,       yy, fz),       c00), (SIMD3(fx + 0.5, yy, fz),       en),
                (SIMD3(fx + 1,   yy, fz),       c10), (SIMD3(fx + 1,   yy, fz + 0.5), ee),
                (SIMD3(fx + 1,   yy, fz + 1),   c11), (SIMD3(fx + 0.5, yy, fz + 1),   es),
                (SIMD3(fx,       yy, fz + 1),   c01), (SIMD3(fx,       yy, fz + 0.5), ew),
            ]
            let ctr = SIMD3<Float>(fx + 0.5, yy, fz + 0.5)
            for k in 0..<8 {
                let (p0, m0) = ring[k], (p1, m1) = ring[(k + 1) % 8]
                v += [vert(ctr, nrm, own), vert(p0, nrm, m0), vert(p1, nrm, m1)]
            }
        }
        for y in 0..<map.h {
            for x in 0..<map.w where openGeo(x, y) {
                let i = map.idx(x, y), fx = Float(x), fz = Float(y)
                out.lampMask[i] = 128   // this cell is OPEN (128) — used by the shader's line-of-sight walk (solid cells stay 0); lamp cells are bumped to 255 below
                out.floorIds[i] = UInt8(truncatingIfNeeded: map.floor[i])   // M6: the fragment reads this to give nukage/rock/blood cells the liquid surface
                // PER-CELL CEILING HEIGHT: a plant hall stands twice a storey while its corridors stay normal,
                // so walls rise to THIS cell's ceiling and the ceiling flat is emitted at that height.
                let ch = map.ceilY[i]
                blendedSurface(x, y, 0, SIMD3(0, 1, 0)) { map.floor[$0] }
                blendedSurface(x, y, ch, SIMD3(0, -1, 0)) { map.ceil[$0] }
                if !openGeo(x - 1, y) { quad(SIMD3(fx, 0, fz), SIMD3(fx, 0, fz + 1), SIMD3(fx, ch, fz + 1), SIMD3(fx, ch, fz), SIMD3(1, 0, 0), RasterRenderer.wallTexAt(map, x - 1, y), wallIdF(x - 1, y)) }
                if !openGeo(x + 1, y) { quad(SIMD3(fx + 1, 0, fz + 1), SIMD3(fx + 1, 0, fz), SIMD3(fx + 1, ch, fz), SIMD3(fx + 1, ch, fz + 1), SIMD3(-1, 0, 0), RasterRenderer.wallTexAt(map, x + 1, y), wallIdF(x + 1, y)) }
                if !openGeo(x, y - 1) { quad(SIMD3(fx + 1, 0, fz), SIMD3(fx, 0, fz), SIMD3(fx, ch, fz), SIMD3(fx + 1, ch, fz), SIMD3(0, 0, 1), RasterRenderer.wallTexAt(map, x, y - 1), wallIdF(x, y - 1)) }
                if !openGeo(x, y + 1) { quad(SIMD3(fx, 0, fz + 1), SIMD3(fx + 1, 0, fz + 1), SIMD3(fx + 1, ch, fz + 1), SIMD3(fx, ch, fz + 1), SIMD3(0, 0, -1), RasterRenderer.wallTexAt(map, x, y + 1), wallIdF(x, y + 1)) }
                // SOFFIT: where this cell's ceiling is HIGHER than an open neighbour's, close the step with a
                // vertical band from the neighbour's ceiling up to ours, facing INTO this cell — otherwise the
                // taller hall would open onto a gap above the corridor's ceiling slab and you'd see the void.
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nx = x + dx, ny = y + dy
                    guard openGeo(nx, ny) else { continue }                      // solid neighbours already got a full wall
                    let nch = map.inBounds(nx, ny) ? map.ceilY[map.idx(nx, ny)] : ch
                    guard ch - nch > 0.001 else { continue }
                    let sm = RasterRenderer.flatMat(map.ceil[i])                                 // the lower slab's own edge
                    if dx == -1 { quad(SIMD3(fx, nch, fz), SIMD3(fx, nch, fz + 1), SIMD3(fx, ch, fz + 1), SIMD3(fx, ch, fz), SIMD3(1, 0, 0), sm) }
                    if dx ==  1 { quad(SIMD3(fx + 1, nch, fz + 1), SIMD3(fx + 1, nch, fz), SIMD3(fx + 1, ch, fz), SIMD3(fx + 1, ch, fz + 1), SIMD3(-1, 0, 0), sm) }
                    if dy == -1 { quad(SIMD3(fx + 1, nch, fz), SIMD3(fx, nch, fz), SIMD3(fx, ch, fz), SIMD3(fx + 1, ch, fz), SIMD3(0, 0, 1), sm) }
                    if dy ==  1 { quad(SIMD3(fx, nch, fz + 1), SIMD3(fx + 1, nch, fz + 1), SIMD3(fx + 1, ch, fz + 1), SIMD3(fx, ch, fz + 1), SIMD3(0, 0, -1), sm) }
                }
                // overhead ceiling lamp (one per open cell on the grid — see the lamp* statics):
                // a VISIBLE glowing housing so the pools it casts have a source you can see, PLUS
                // the presence-mask bit AND (via the shared statics) the shader's analytic light —
                // all authored HERE so lamp / housing / mask / light can never drift apart.
                if ceilingLampsOn, x % RasterRenderer.lampGridStride == RasterRenderer.lampGridPhase && y % RasterRenderer.lampGridStride == RasterRenderer.lampGridPhase {
                    out.lampCells.append(SIMD2(fx + 0.5, fz + 0.5))
                    out.lampMask[i] = 255
                    let cx = fx + 0.5, cz = fz + 0.5, hs: Float = 0.26, y0: Float = ch - 0.015   // recessed into THIS cell's ceiling
                    let lm = Mat(a: SIMD3(0.80, 0.85, 0.95), r: 0.4, m: 0.0, e: WorldLight.lampColor * 3.4)   // bright recessed housing
                    quad(SIMD3(cx - hs, y0, cz - hs), SIMD3(cx - hs, y0, cz + hs), SIMD3(cx + hs, y0, cz + hs), SIMD3(cx + hs, y0, cz - hs), SIMD3(0, -1, 0), lm)
                }
            }
        }
        buildHallSteelwork(map, into: &v)     // roof trusses + slung downlights over the double-height halls
        buildWallFixtures(map, into: &v)      // wall bulkhead fixtures — static, and far too heavy to rebuild per frame
        let prePipe = v.count
        buildPipework(map, into: &v)          // copper wall runs + valves/gauges — static, so it lives in this mesh
        out.pipeVerts = v.count - prePipe
        let preMach = v.count
        buildMachines(world, into: &v)        // imported plant machinery — it never moves, so it is level geometry
        out.machineVerts = v.count - preMach
        out.verts = v
    }

    /// ROOF STEELWORK over the double-height machine halls: lattice trusses spanning the hall high up, with
    /// downlights hung beneath them. Two jobs — it gives the eye something at height so the extra storey
    /// actually READS (an empty black void above you just looks like fog), and it explains the architecture:
    /// the corridors are a storey high because they run under this steel deck. Lamp positions are collected for
    /// render() to surface as point lights, so the halls are lit from above as well as by the wall bulkheads.
    private mutating func buildHallSteelwork(_ map: GameMap, into v: inout [PVert]) {
        out.hallLamps.removeAll(keepingCapacity: true)
        guard !ceilingLampsOn else { return }              // plant floors only (they carry the tall halls)
        let steel  = RasterRenderer.M(SIMD3(0.30, 0.31, 0.34), 0.52, 0.72)
        let strut  = RasterRenderer.M(SIMD3(0.26, 0.27, 0.30), 0.56, 0.70)
        let shade  = RasterRenderer.M(SIMD3(0.22, 0.22, 0.24), 0.50, 0.60)
        let lampE  = RasterRenderer.M(SIMD3(0.95, 0.88, 0.72), 0.40, 0.0, SIMD3(2.3, 1.85, 1.15))   // the lit face, over-bright → blooms
        let chordTop: Float = 1.42, chordBot: Float = 1.24  // the truss sits high in the hall, clear of sightlines
        func tall(_ x: Int, _ y: Int) -> Bool {
            guard map.inBounds(x, y) else { return false }
            let i = map.idx(x, y); return map.wall[i] == 0 && map.doors[i] == nil && map.ceilY[i] > 1.5
        }
        // group the tall cells into halls (4-way flood fill) so each hall is trussed on its own axis
        var seen = [Bool](repeating: false, count: map.w * map.h)
        for y0 in 0..<map.h { for x0 in 0..<map.w where tall(x0, y0) && !seen[map.idx(x0, y0)] {
            var region: [(Int, Int)] = [], stack = [(x0, y0)]
            seen[map.idx(x0, y0)] = true
            var lo = (x0, y0), hi = (x0, y0)
            while let (cx, cy) = stack.popLast() {
                region.append((cx, cy))
                lo = (min(lo.0, cx), min(lo.1, cy)); hi = (max(hi.0, cx), max(hi.1, cy))
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = cx + dx, ny = cy + dy
                    guard tall(nx, ny), !seen[map.idx(nx, ny)] else { continue }
                    seen[map.idx(nx, ny)] = true; stack.append((nx, ny))
                }
            }
            let wide = hi.0 - lo.0 + 1, deep = hi.1 - lo.1 + 1
            guard min(wide, deep) >= 3, region.count >= 12 else { continue }   // a real hall, not a nook
            let inSet = Set(region.map { map.idx($0.0, $0.1) })
            // trusses SPAN the shorter dimension and repeat along the longer one
            let spanAlongX = wide <= deep
            let alongLo = spanAlongX ? lo.1 : lo.0, alongHi = spanAlongX ? hi.1 : hi.0
            var a = alongLo + 1
            var bay = 0
            while a <= alongHi - 1 {
                // the truss's extent across the hall on this line = the contiguous tall cells through it
                let mid = spanAlongX ? (lo.0 + hi.0) / 2 : (lo.1 + hi.1) / 2
                guard inSet.contains(map.idx(spanAlongX ? mid : a, spanAlongX ? a : mid)) else { a += 3; continue }
                var s = mid, e = mid
                while inSet.contains(map.idx(spanAlongX ? s - 1 : a, spanAlongX ? a : s - 1)) { s -= 1 }
                while inSet.contains(map.idx(spanAlongX ? e + 1 : a, spanAlongX ? a : e + 1)) { e += 1 }
                guard e - s >= 2 else { a += 3; continue }
                let c = Float(a) + 0.5, p0 = Float(s), p1 = Float(e + 1)
                let hw: Float = 0.055                                          // chord half-width
                // top + bottom chords
                if spanAlongX {
                    RasterRenderer.emitAABB(SIMD3(p0, chordTop - 0.035, c - hw), SIMD3(p1, chordTop + 0.035, c + hw), steel, into: &v)
                    RasterRenderer.emitAABB(SIMD3(p0, chordBot - 0.030, c - hw * 0.8), SIMD3(p1, chordBot + 0.030, c + hw * 0.8), steel, into: &v)
                } else {
                    RasterRenderer.emitAABB(SIMD3(c - hw, chordTop - 0.035, p0), SIMD3(c + hw, chordTop + 0.035, p1), steel, into: &v)
                    RasterRenderer.emitAABB(SIMD3(c - hw * 0.8, chordBot - 0.030, p0), SIMD3(c + hw * 0.8, chordBot + 0.030, p1), steel, into: &v)
                }
                // zig-zag web bracing between the chords — what makes it read as a truss, not two bars
                var t = p0
                var up = true
                while t < p1 - 0.001 {
                    let t2 = min(t + 0.5, p1)
                    let yA = up ? chordBot : chordTop, yB = up ? chordTop : chordBot
                    let pa = spanAlongX ? SIMD3<Float>(t, yA, c) : SIMD3<Float>(c, yA, t)
                    let pb = spanAlongX ? SIMD3<Float>(t2, yB, c) : SIMD3<Float>(c, yB, t2)
                    RasterRenderer.emitTube(pa, pb, r: 0.022, sides: 4, strut, caps: false, into: &v)
                    t = t2; up = !up
                }
                // every other bay carries a downlight slung under the truss
                if bay % 2 == 0 {
                    let lx = spanAlongX ? Float(s + e + 1) * 0.5 : c
                    let lz = spanAlongX ? c : Float(s + e + 1) * 0.5
                    let hangTop = chordBot, lampY: Float = chordBot - 0.16
                    RasterRenderer.emitTube(SIMD3(lx, hangTop, lz), SIMD3(lx, lampY + 0.05, lz), r: 0.012, sides: 5, strut, caps: false, into: &v)
                    RasterRenderer.emitAABB(SIMD3(lx - 0.10, lampY + 0.02, lz - 0.10), SIMD3(lx + 0.10, lampY + 0.07, lz + 0.10), shade, into: &v)
                    RasterRenderer.emitQuad(SIMD3(lx, lampY + 0.019, lz), SIMD3(0.085, 0, 0), SIMD3(0, 0, 0.085), SIMD3(0, -1, 0), lampE, into: &v)
                    out.hallLamps.append(SIMD3(lx, lampY, lz))
                }
                bay += 1
                a += 3                                                         // one truss every three cells
            }
        } }
    }

    /// WALL PIPEWORK — the copper runs the raymarcher draws in its SDF (`wallPipes` + `fittingsField`), ported
    /// to real geometry so the raster gets them too. Dimensions are taken from the kernel so both renderers
    /// agree: the run sits 0.10 off the wall face at (ceiling − 0.28), radius 0.038, with bolted flange collars
    /// where it turns square into the wall, plus the CPU-placed fittings from `map.pipeFittings` — a shut-off
    /// valve (tapered bonnet, rising stem, red-enamel handwheel) or a pressure gauge (stub + dial).
    /// Emitted into the STATIC mesh: pipework never moves, so it costs nothing per frame.
    private mutating func buildPipework(_ map: GameMap, into v: inout [PVert]) {
        let copper = RasterRenderer.M(SIMD3(0.60, 0.35, 0.25), 0.44, 0.85)      // drawn copper, warm against the iron
        let steel  = RasterRenderer.M(SIMD3(0.34, 0.36, 0.40), 0.40, 0.80)
        // A fitting is a CASTING: duller and a shade darker than the drawn pipe it joins, so the
        // junction reads as a separate part — and it matches ITS OWN pipe. One shared warm `flange`
        // for every service is what put copper elbows on the grey steel line.
        let copperFit = RasterRenderer.M(SIMD3(0.42, 0.26, 0.19), 0.52, 0.80)
        let steelFit  = RasterRenderer.M(SIMD3(0.25, 0.27, 0.30), 0.54, 0.72)
        let enamel = RasterRenderer.M(SIMD3(0.40, 0.045, 0.035), 0.34, 0.10)    // red-enamel handwheel
        let dialF  = RasterRenderer.M(SIMD3(0.82, 0.80, 0.74), 0.35, 0.05)
        // Pipework hangs at ONE height for the whole level — the standard storey less the kernel's 0.28 drop.
        // Keying it to each cell's own ceiling made a run jump a whole storey at a hall/corridor boundary and
        // let a fitting sit off its own run; a constant also matches the raymarcher (which uses a global ceilH).
        let pipeR: Float = 0.038, off: Float = 0.10, drop: Float = 0.28
        let runY: Float = 1.0 - drop
        func routed(_ x: Int, _ y: Int) -> Bool {
            guard map.inBounds(x, y) else { return false }
            let i = map.idx(x, y); return map.wall[i] == 0 && map.pipe[i] > 0.5
        }
        // A run is plumbed as a SPAN, not cell by cell. Emitting per-cell produced illogical plant: every tall
        // cell at the end of a stretch grew its own riser, so two risers could join the SAME pair of mains where
        // one is all that is needed. Group contiguous cells that share a wall into a span, then plumb the span
        // once: one continuous main, and exactly one riser feeding any high main.
        /// The wall a cell's run hugs — its FIRST solid neighbour in a fixed order, so every cell along a wall
        /// agrees and spans join up. (The kernel gets the same effect from distance-to-wall.)
        func wallOf(_ x: Int, _ y: Int) -> (Int, Int)? {
            guard routed(x, y) else { return nil }
            for (dx, dy) in [(0, -1), (0, 1), (-1, 0), (1, 0)] {
                let nx = x + dx, ny = y + dy
                guard map.inBounds(nx, ny), map.wall[map.idx(nx, ny)] != 0, map.doors[map.idx(nx, ny)] == nil else { continue }
                // Services are never run across the operations big board — nobody plumbs pipework over the
                // plot displays. The board wall is skipped, so the run either picks another wall or stops.
                if map.wall[map.idx(nx, ny)] == WallTex.opsBoard.rawValue { continue }
                return (dx, dy)
            }
            return nil
        }
        for (wdx, wdy) in [(0, -1), (0, 1), (-1, 0), (1, 0)] {
            let horiz = (wdy != 0)                                         // wall to N/S → the run travels along X
            let outer = horiz ? map.h : map.w                              // lines across the wall's normal
            let inner = horiz ? map.w : map.h                              // cells along the run
            for o in 0..<outer {
                var k = 0
                while k < inner {
                    func cell(_ t: Int) -> (Int, Int) { horiz ? (t, o) : (o, t) }
                    let (sx, sy) = cell(k)
                    guard let wd = wallOf(sx, sy), wd == (wdx, wdy) else { k += 1; continue }
                    var end = k                                            // extend while the same wall continues
                    while end + 1 < inner {
                        let (nx, ny) = cell(end + 1)
                        guard let nwd = wallOf(nx, ny), nwd == (wdx, wdy) else { break }
                        end += 1
                    }
                    defer { k = end + 1 }
                    let inward = SIMD2<Float>(-Float(wdx), -Float(wdy))    // wall → room
                    let axis = SIMD2<Float>(horiz ? 1 : 0, horiz ? 0 : 1)  // along the wall, increasing
                    let intoWall = SIMD3<Float>(-inward.x, 0, -inward.y)
                    // the wall face, pushed into the room; the span runs the full length of its cells
                    let fixedPos: SIMD2<Float> = horiz
                        ? SIMD2(0, wdy > 0 ? Float(o + 1) : Float(o))
                        : SIMD2(wdx > 0 ? Float(o + 1) : Float(o), 0)
                    func at(_ t: Float, _ lateral: Float) -> SIMD2<Float> {
                        let along = axis * t
                        return SIMD2(horiz ? along.x : fixedPos.x, horiz ? fixedPos.y : along.y) + inward * (off + lateral)
                    }
                    let t0 = Float(k), t1 = Float(end + 1)                 // outer edges of the first/last cell
                    /// One continuous service along the span, mitred square into the wall at both ends.
                    /// `sides` stays lean and caps are dropped where an end is buried in a wall or behind a
                    /// flange — pipework dominates the level mesh, so an invisible cap is pure cost.
                    /// `fit` is the FITTING material, taken per service rather than shared: a single warm
                    /// `flange` on every service put copper castings on the steel line.
                    func service(_ py: Float, _ r: Float, _ mat: Mat, _ fit: Mat, _ lateral: Float, _ sides: Int) {
                        let a2 = at(t0, lateral), b2 = at(t1, lateral)
                        let a = SIMD3<Float>(a2.x, py, a2.y), b = SIMD3<Float>(b2.x, py, b2.y)
                        // CAPPED at both ends. The run stops at the outer edge of its first and last cell,
                        // and where the wall stretch ends at a room corner that edge stands in open air —
                        // so its bore was a black hole you could look straight down, framed by the fitting.
                        // The sleeves around it hid nothing: they are wider than the pipe, and the wedge
                        // between the two perpendicular ones is exactly where the bore showed through.
                        // THE STRAIGHT STOPS SHORT AT EACH END and the bend spans the gap — that is what
                        // makes it one continuous pipe turning a corner rather than a corner with
                        // something bolted to it. No caps needed on the run any more: both its ends are
                        // now inside a bend rather than standing open at the wall's end.
                        let br = RasterRenderer.pipeBendRadius(r)
                        let axis3 = SIMD3<Float>(axis.x, 0, axis.y)
                        RasterRenderer.emitTube(a + axis3 * br, b - axis3 * br, r: r, sides: sides, mat, caps: false, into: &v)
                        for (pt, dir) in [(a, SIMD3<Float>(-axis.x, 0, -axis.y)), (b, SIMD3<Float>(axis.x, 0, axis.y))] {
                            let face = pt + intoWall * (off + lateral + 0.04)
                            // the spur likewise starts a bend-radius in, and runs on into the wall
                            RasterRenderer.emitTube(pt + intoWall * br, face, r: r, sides: sides, mat, caps: false, into: &v)
                            RasterRenderer.emitElbow(at: pt, legA: dir * -1, legB: intoWall, r: r, mat, into: &v)
                            RasterRenderer.emitTube(face - intoWall * 0.012, face + intoWall * 0.012, r: r * 1.6, sides: 8, fit, into: &v)
                        }
                    }
                    service(runY, pipeR, copper, copperFit, 0, 10)                     // the copper main
                    service(runY - 0.105, pipeR * 0.66, steel, steelFit, 0.012, 8)     // a thinner steel line beneath it
                    // HIGH MAIN: carried under a double-height hall's own ceiling, fed by ONE riser off the low
                    // main via a real tee, and terminating into the wall through an elbow at its far end.
                    var t = k
                    while t <= end {
                        let (cx, cy) = cell(t)
                        guard map.ceilY[map.idx(cx, cy)] > 1.5 else { t += 1; continue }
                        var hi = t
                        while hi + 1 <= end {
                            let (nx2, ny2) = cell(hi + 1)
                            guard map.ceilY[map.idx(nx2, ny2)] > 1.5 else { break }
                            hi += 1
                        }
                        let highY = map.ceilY[map.idx(cx, cy)] - drop
                        let hr = pipeR * 0.92, lateral: Float = 0.02
                        let riserT = Float(t) + 0.35                        // the single feed, just inside the hall
                        let hEnd = Float(hi + 1) - 0.06
                        if hEnd - riserT > 0.15 {
                            let r2 = at(riserT, lateral), e2 = at(hEnd, lateral)
                            let footY = runY, top = SIMD3<Float>(r2.x, highY, r2.y), foot = SIMD3<Float>(r2.x, footY, r2.y)
                            RasterRenderer.emitTube(foot, top, r: hr, sides: 9, copper, caps: false, into: &v)                       // the riser
                            RasterRenderer.emitTube(top, SIMD3(e2.x, highY, e2.y), r: hr, sides: 9, copper, caps: true, nearCap: false, into: &v)   // the high main; its far end is the wall terminus
                            let up = SIMD3<Float>(0, 1, 0), along = SIMD3<Float>(axis.x, 0, axis.y)
                            RasterRenderer.emitTee(at: SIMD3(r2.x, footY, r2.y), run: along, branch: up, r: pipeR, copperFit, into: &v)  // branch off the low main
                            RasterRenderer.emitElbow(at: top, legA: -up, legB: along, r: hr, copperFit, into: &v)                        // riser turns into the high main
                            let fEnd = SIMD3<Float>(e2.x, highY, e2.y)
                            RasterRenderer.emitTube(fEnd, fEnd + intoWall * (off + lateral + 0.04), r: hr, sides: 9, copper, caps: false, into: &v)
                            RasterRenderer.emitElbow(at: fEnd, legA: -along, legB: intoWall, r: hr, copperFit, capNear: true, into: &v)  // and back into the wall
                        }
                        t = hi + 1
                    }
                }
            }
        }
        // ── FITTINGS (map.pipeFittings: x, z, outward-normal angle, kind 0 valve · 1 gauge) ──
        for f in map.pipeFittings {
            let cx = Int(f.x), cz = Int(f.y)
            guard map.inBounds(cx, cz) else { continue }
            let py = runY
            let n2 = SIMD2<Float>(cosf(f.z), sinf(f.z))                    // wall outward normal (into the room)
            let base = SIMD3<Float>(f.x, py, f.y)
            let outw = SIMD3<Float>(n2.x, 0, n2.y)
            if f.w < 0.5 {                                                 // ── SHUT-OFF VALVE ──
                RasterRenderer.emitTube(base + outw * 0.10, base + outw * 0.152, r: 0.032, sides: 10, copper, into: &v)   // tapered bonnet
                RasterRenderer.emitTube(base + outw * 0.150, base + outw * 0.196, r: 0.011, sides: 8, steel, into: &v)    // rising stem
                let hubC = base + outw * 0.19, rimR: Float = 0.052
                let t = SIMD3<Float>(-n2.y, 0, n2.x), up = SIMD3<Float>(0, 1, 0)
                let seg = 14                                                                              // handwheel RIM as a ring of chords
                var prev = hubC + t * rimR
                for k in 1...seg {
                    let ang = Float(k) / Float(seg) * 2 * Float.pi
                    let cur = hubC + t * (cosf(ang) * rimR) + up * (sinf(ang) * rimR)
                    RasterRenderer.emitTube(prev, cur, r: 0.0095, sides: 6, enamel, caps: false, into: &v)
                    prev = cur
                }
                for k in 0..<4 {                                                                          // four spokes
                    let ang = Float(k) / 4 * 2 * Float.pi
                    RasterRenderer.emitTube(hubC, hubC + t * (cosf(ang) * rimR) + up * (sinf(ang) * rimR), r: 0.007, sides: 6, enamel, into: &v)
                }
                RasterRenderer.emitTube(hubC - outw * 0.014, hubC + outw * 0.014, r: 0.014, sides: 8, steel, into: &v)    // stem nut
            } else {                                                       // ── PRESSURE GAUGE ──
                let stubTop = base + SIMD3<Float>(0, 0.09, 0)
                RasterRenderer.emitTube(base + outw * 0.10, stubTop + outw * 0.10, r: 0.013, sides: 8, copper, into: &v)  // stub up off the run
                let dialC = base + SIMD3<Float>(0, 0.105, 0) + outw * 0.10
                RasterRenderer.emitTube(dialC - outw * 0.016, dialC + outw * 0.016, r: 0.038, sides: 14, steel, into: &v) // dial body
                let t = SIMD3<Float>(-n2.y, 0, n2.x), up = SIMD3<Float>(0, 1, 0)
                RasterRenderer.emitEllipse(dialC + outw * 0.018, t, up, 0.031, 0.031, outw, dialF, into: &v)              // pale dial face
                RasterRenderer.emitTube(dialC + outw * 0.019, dialC + outw * 0.019 + t * 0.012 + up * 0.020, r: 0.0035, sides: 5,
                         RasterRenderer.M(SIMD3(0.08, 0.07, 0.06), 0.5, 0.1), into: &v)                                  // needle
            }
        }
    }

    /// Every plant machine on this floor, emitted ONCE into the static level mesh.
    ///
    /// Machinery never moves, so it is level geometry, not per-frame props — the same call the
    /// bulkhead fixtures make, and for the same reason. Each machine is ~9.9k vertices; a plant
    /// floor's worth rebuilt every frame is tens of thousands of vertices of re-tessellation for a
    /// picture that cannot change, and the fixtures already showed where that leads (over the 300k
    /// per-frame cap, silently truncated, furniture popping in and out as the camera turned).
    ///
    /// One consequence worth knowing: the live height knobs (MachineFilterHeight and friends) are
    /// therefore read at LEVEL BUILD, not per frame. Dialling one takes effect on the next floor —
    /// warp with StartLevel to see it. That is a fair trade for taking the cost off the frame clock.
    private mutating func buildMachines(_ world: World, into v: inout [PVert]) {
        for pr in world.props {
            guard let m = machine(pr.kind) else { continue }
            // Wall machines seat FLUSH: the mesh is centred on its footprint, so pushing it into the
            // room by (halfDepth − 0.5) puts its back face on the wall face instead of burying it
            // behind. Depth comes from the shape bounds, so it tracks the mesh rather than a
            // hand-tuned per-kind number.
            var seat = pr.pos
            if pr.againstWall {
                let fp = GPURaymarch.furnitureFootprint(pr.kind)
                let inward = SIMD2<Float>(-sinf(pr.yaw), cosf(pr.yaw))
                seat += inward * max(0, fp.halfD - 0.5)
            }
            RasterRenderer.emitMesh(m.mesh, pos: seat, yaw: pr.yaw, scale: m.scale, into: &v)
            // A CENTREPIECE gets its own downlight. The truss lamps are slung on a fixed bay stride,
            // so whether the hall's hero machine happens to stand under one is luck — and one that
            // doesn't is a dark mass you cannot read at all. These floors are meant to be dark, but
            // the thing the room exists for should not be the part you can't see. Wall machines get
            // nothing: they are furniture, and the bulkheads already wash the walls they stand on.
            if pr.kind == .machineFilter || pr.kind == .machineColumn {
                out.hallLamps.append(SIMD3(seat.x, GameMap.tallCeiling - 0.22, seat.y))
            }
        }
    }

    /// Mount the wall BULKHEAD fixtures — the fuel store's pair, plus (on the plant floors 7–8, which carry no
    /// ceiling grid) the fixtures that light the workings. Their glow is added as point lights in render().
    /// Every wall BULKHEAD fixture, emitted into the STATIC level mesh. These were being rebuilt into the
    /// per-frame prop buffer, and the imported lamp is ~3.5k triangles: thirty of them on a plant floor
    /// exceeded the whole 300k-vertex prop budget on their own, so the furniture emitted after them was
    /// silently truncated — and which pieces survived changed as the camera turned, which is why columns and
    /// furniture popped in and out within a single room. They never move, so they are static geometry.
    private mutating func buildWallFixtures(_ map: GameMap, into v: inout [PVert]) {
        for b in RasterRenderer.fuelBulkheads(map) {
            RasterRenderer.emitBulkheadFixture(pos: b.pos, yaw: b.yaw, inward: simd_normalize(b.light - b.pos), lamp: bulkhead, into: &v)
        }
        for b in out.plantLamps {
            RasterRenderer.emitBulkheadFixture(pos: b.pos, yaw: b.yaw, inward: simd_normalize(b.light - b.pos), lamp: bulkhead, into: &v)
        }
    }
}
