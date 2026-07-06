// Citadel — organic-alien mockup lab (CITADEL_CREATURES[=gif]).
//
// NOT shipping code yet. Designs the occupation bestiary as organic creatures
// built from fused soft volumes (metaballs / round-cones) and RAYMARCHED with a
// painterly, inked 2-D finish. Because there is real 3-D underneath, the look is
// fleshy and hand-arty (Option C) but rotation + animation come for free — which
// is what makes them animatable in a first-person game.
//
//   CITADEL_CREATURES=1     → roster still-sheet only (fast, for design tuning)
//   CITADEL_CREATURES=gif   → roster sheet + animated GIFs (turntables + a walk)
//
// Output: ~/Desktop/Citadel-Aliens/

import Foundation
import AppKit
import simd
import ImageIO
import UniformTypeIdentifiers

enum CreatureLab {
    // ── soft-volume shapes ───────────────────────────────────────────────────
    struct Shape {
        var a: SIMD3<Float>, b: SIMD3<Float>, r1: Float, r2: Float
        var col: SIMD3<Float>, k: Float, sphere: Bool
        @inline(__always) func dist(_ p: SIMD3<Float>) -> Float {
            sphere ? simd_length(p - a) - r1 : sdRoundCone(p, a, b, r1, r2)
        }
    }
    static func S(_ c: SIMD3<Float>, _ r: Float, _ col: SIMD3<Float>, _ k: Float = 0.14) -> Shape {
        Shape(a: c, b: c, r1: r, r2: r, col: col, k: k, sphere: true)
    }
    static func C(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ r1: Float, _ r2: Float, _ col: SIMD3<Float>, _ k: Float = 0.12) -> Shape {
        Shape(a: a, b: b, r1: r1, r2: r2, col: col, k: k, sphere: false)
    }

    static func sdRoundCone(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ r1: Float, _ r2: Float) -> Float {
        let ba = b - a
        let l2 = simd_dot(ba, ba)
        if l2 < 1e-7 { return simd_length(p - a) - r1 }
        let rr = r1 - r2, a2 = l2 - rr * rr, il2 = 1 / l2
        let pa = p - a
        let y = simd_dot(pa, ba), z = y - l2
        let xp = pa * l2 - ba * y
        let x2 = simd_dot(xp, xp), y2 = y * y * l2, z2 = z * z * l2
        let sgnR: Float = rr < 0 ? -1 : (rr > 0 ? 1 : 0)
        let k = sgnR * rr * rr * x2
        let sgnZ: Float = z < 0 ? -1 : (z > 0 ? 1 : 0)
        if sgnZ * a2 * z2 > k { return sqrt(x2 + z2) * il2 - r2 }
        let sgnY: Float = y < 0 ? -1 : (y > 0 ? 1 : 0)
        if sgnY * a2 * y2 < k { return sqrt(x2 + y2) * il2 - r1 }
        return (sqrt(x2 * a2 * il2) + y * rr) * il2 - r1
    }

    struct CDef {
        let name: String, role: String, blurb: String
        let viewH: Float, groundY: Float    // world height the tile spans / world y at tile bottom
        let build: (_ ph: Float, _ atk: Float) -> [Shape]
    }

    static let L = simd_normalize(SIMD3<Float>(-0.5, 0.62, -0.62))
    static let bayer: [[Int]] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]

    // ── raymarch a single tile (straight-alpha RGBA, inked silhouette) ────────
    static func renderShapes(_ shapes: [Shape], viewH: Float, groundY: Float, yaw: Float, w: Int, h: Int,
                             inkAlpha: UInt8 = 255) -> [UInt32] {
        let aspect = Float(w) / Float(h)
        let sy = sin(yaw), cy = cos(yaw)
        @inline(__always) func rot(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(p.x * cy - p.z * sy, p.y, p.x * sy + p.z * cy) }
        func sdf(_ p0: SIMD3<Float>) -> (Float, SIMD3<Float>) {
            let p = rot(p0)
            var d: Float = 1e9, c = SIMD3<Float>(0, 0, 0)
            for s in shapes {
                let sd = s.dist(p)
                if d > 1e8 { d = sd; c = s.col; continue }
                let k = s.k
                let hh = max(0, min(1, 0.5 + 0.5 * (sd - d) / k))
                d = (sd * (1 - hh) + d * hh) - k * hh * (1 - hh)
                c = s.col * (1 - hh) + c * hh
            }
            return (d, c)
        }
        func nrm(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let e: Float = 0.004
            let dx = sdf(p + SIMD3(e, 0, 0)).0 - sdf(p - SIMD3(e, 0, 0)).0
            let dy = sdf(p + SIMD3(0, e, 0)).0 - sdf(p - SIMD3(0, e, 0)).0
            let dz = sdf(p + SIMD3(0, 0, e)).0 - sdf(p - SIMD3(0, 0, e)).0
            return simd_normalize(SIMD3(dx, dy, dz))
        }

        var col = [SIMD3<Float>](repeating: .zero, count: w * h)
        var cov = [Bool](repeating: false, count: w * h)
        var dep = [Float](repeating: 0, count: w * h)
        var edge = [Float](repeating: 0, count: w * h)   // near-miss coverage → silhouette AA
        let aaBand = viewH / Float(h) * 1.5               // ~1.5px feather, in world units
        for j in 0..<h { for i in 0..<w {
            let wy = groundY + (1 - (Float(j) + 0.5) / Float(h)) * viewH
            let wx = ((Float(i) + 0.5) / Float(w) - 0.5) * viewH * aspect
            var t: Float = 0, hit = false, minD: Float = 1e9, p = SIMD3<Float>(wx, wy, -4)
            for _ in 0..<72 {
                p = SIMD3(wx, wy, -4 + t)
                let d = sdf(p).0
                if d < 0.0025 { hit = true; break }
                if d < minD { minD = d }
                t += max(d * 0.85, 0.008)
                if t > 9 { break }
            }
            let idx = j * w + i
            if !hit { edge[idx] = max(0, 1 - minD / aaBand); continue }   // how close the ray grazed the surface
            let n = nrm(p), base = sdf(p).1
            // scaly micro-relief in creature space (shading-only — never perturbs
            // the marched SDF) so the hide reads as pebbled skin, not smooth pudding
            let rp = rot(p)
            let bump = SIMD3<Float>(sin(rp.x * 39 + rp.y * 27), sin(rp.y * 41 + rp.z * 31), sin(rp.z * 37 + rp.x * 23))
            let n2 = simd_normalize(n + bump * 0.13)
            let diff = max(0, simd_dot(n2, L))
            let rim = pow(1 - min(1, abs(n2.z)), 2.6)
            // wet/slimy sheen: a tight specular toward the camera (rays travel +z)
            let half = simd_normalize(L + SIMD3<Float>(0, 0, -1))
            // WET skin: a broad sheen plus a tight, bright glint — the double
            // highlight reads as a slick, secreting, glistening surface
            let nh = max(0, simd_dot(n2, half))
            let spec = pow(nh, 16) * 0.7 + pow(nh, 80) * 1.7
            // a low ambient floor keeps the unlit side in shadow — menace, not pudding —
            // with enough key + rim to read the biomechanical sculpt
            let light = 0.18 + 0.82 * diff + 0.24 * rim
            col[idx] = base * light + SIMD3<Float>(104, 112, 124) * min(1.6, spec)   // cold wet glint
            cov[idx] = true; dep[idx] = t
        } }

        // post: depth-crease shading, inked silhouette, banded dither
        func covAt(_ x: Int, _ y: Int) -> Bool { x >= 0 && x < w && y >= 0 && y < h && cov[y * w + x] }
        var out = [UInt32](repeating: 0, count: w * h)
        for j in 0..<h { for i in 0..<w {
            let idx = j * w + i
            if cov[idx] {
                var c = col[idx]
                var crease: Float = 0
                for (ox, oy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] where covAt(i + ox, j + oy) {
                    if dep[(j + oy) * w + (i + ox)] - dep[idx] > 0.05 { crease = 1 }
                }
                if crease > 0 { c = c * 0.5 }
                let dd = (Float(bayer[j & 3][i & 3]) - 7.5) / 15 * 13
                func q(_ v: Float) -> Int { min(255, max(0, Int((((v + dd) / 19).rounded()) * 19))) }
                out[idx] = packRGBA(q(c.x), q(c.y), q(c.z), 255)
            } else if edge[idx] > 0.02 {
                // anti-aliased inked silhouette: alpha = sub-pixel coverage, so the
                // organic edges feather into the background instead of stair-stepping.
                let aa = min(255, Int(edge[idx] * Float(inkAlpha)))
                out[idx] = packRGBA(10, 7, 9, aa)
            }
        } }
        return out
    }

    static func mix3(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a * (1 - t) + b * t }

    static func renderTile(_ def: CDef, ph: Float, atk: Float, yaw: Float, w: Int, h: Int) -> [UInt32] {
        renderShapes(def.build(ph, atk), viewH: def.viewH, groundY: def.groundY, yaw: yaw, w: w, h: h)
    }
    static func renderDeath(_ def: CDef, d: Float, gib: Bool, yaw: Float, w: Int, h: Int) -> [UInt32] {
        renderShapes(deadShapes(def.build(0, 0), d: d, gib: gib), viewH: def.viewH + 0.3, groundY: def.groundY - 0.25, yaw: yaw, w: w, h: h)
    }

    /// Transform a live creature's shapes into a death state: a collapsing,
    /// bleeding heap (gib == false) or a burst of gory chunks (gib == true).
    /// `decals`: the spreading blood pool + arterial spurts are a 2-D sprite-bake
    /// trick (the floor clips the pool into a flat puddle). The 3-D SDF renderer
    /// has no such clip, so it passes decals: false — those become grotesque
    /// floating blobs otherwise.
    /// A corpse being consumed by fire: it must NEVER shrink like a deflating
    /// balloon. Tissue burns from the outside in — thin extremities (claws,
    /// fangs, pipes, tail tip) wither and vanish first, then the masses slump
    /// to the deck, draw inward and FUSE (k rises) into a low charred mound.
    /// Full scale throughout; the char colour ramp lives in packCreatures.
    static func charShapes(_ base: [Shape], burn: Float) -> [Shape] {
        guard burn > 0 else { return base }
        let b = min(1, burn)
        var out = [Shape]()
        for s in base {
            let thin = max(s.r1, s.r2) < 0.05
            if thin && b > 0.35 { continue }                        // consumed
            var a = s.a, bb = s.b
            let slump = 1 - 0.8 * b
            a.y = max(0.04, a.y * slump); bb.y = max(0.04, bb.y * slump)
            a.x *= 1 - 0.35 * b; bb.x *= 1 - 0.35 * b               // caving toward the centreline
            a.z *= 1 - 0.35 * b; bb.z *= 1 - 0.35 * b
            var r1 = s.r1, r2 = s.r2
            if thin { r1 *= 1 - b; r2 *= 1 - b }                    // withering before it vanishes
            // k stays FIXED: raising the smooth-blend during the burn inflated the
            // union (smin adds material between shapes) — the corpse visibly puffed
            out.append(Shape(a: a, b: bb, r1: r1, r2: r2, col: s.col, k: s.k, sphere: s.sphere))
        }
        return out
    }

    static func deadShapes(_ base: [Shape], d: Float, gib: Bool, decals: Bool = true, sprawl: Float = 1) -> [Shape] {
        var cen = SIMD3<Float>(0, 0, 0)
        for s in base { cen += s.a }
        cen /= Float(max(1, base.count))
        let blood = SIMD3<Float>(150, 22, 20), bloodDk = SIMD3<Float>(78, 14, 14), bright = SIMD3<Float>(236, 72, 60)
        let pain = max(0, 1 - d * 6)
        var out = [Shape]()
        for (i, s) in base.enumerated() {
            var a = s.a, b = s.b, r1 = s.r1, r2 = s.r2, col = s.col
            if gib {
                let scatter = SIMD3<Float>(Float((i % 5) - 2) * 0.12, 0, Float((i % 3) - 1) * 0.12)
                let dir = simd_normalize((s.a - cen) + SIMD3(0, 0.25, 0) + scatter)
                let fly = d * d, grav = d * d * 0.9
                a = s.a + dir * fly; a.y = max(0.05, a.y - grav)
                b = s.b + dir * fly; b.y = max(0.05, b.y - grav)
                r1 = max(0.01, r1 * (1 - d * 0.3)); r2 = max(0, r2 * (1 - d * 0.3))
                col = mix3(col, blood, 0.45 * d)
                out.append(Shape(a: a, b: b, r1: r1, r2: r2, col: col, k: s.k, sphere: s.sphere))
            } else {
                // collapse: the body crumples and leans to one side into a heap,
                // keeping ~40% of its height. The lean is GENTLE and the spread
                // modest — a violent topple flings tall parts sideways past the
                // sprite frame, where the tile clips them into a hard straight edge.
                func sink(_ p: SIMD3<Float>) -> SIMD3<Float> {
                    // `sprawl` scales the sideways spread + topple: the drone keels
                    // over (1); the rooted Queen only SLUMPS (≈0.15) — the generic
                    // topple smeared her huge sac sideways into a balloon.
                    let droop = 1 - d * 0.62
                    let topple = p.y * d * 0.24 * sprawl
                    return SIMD3(p.x * (1 + d * 0.16 * sprawl) + topple,
                                 max(0.05, p.y * droop),
                                 p.z * (1 + d * 0.20 * sprawl))
                }
                a = sink(s.a); b = sink(s.b)
                r1 = s.r1 * (1 + d * 0.10); r2 = s.r2 * (1 + d * 0.10)
                col = mix3(mix3(s.col, bright, pain * 0.5), bloodDk, 0.42 * d)
                out.append(Shape(a: a, b: b, r1: r1, r2: r2, col: col, k: s.k + d * 0.12, sphere: s.sphere))
            }
        }
        // spreading blood pool
        if decals && d > 0.02 {
            func pool(_ x: Float, _ z: Float, _ rad: Float) -> Shape { S(SIMD3(x, -(rad - 0.05), z), rad, blood, 0.06) }
            out.append(pool(0, 0.05, 0.36 + 0.8 * d))
            out.append(pool(-0.4 * d, 0.14, 0.3 * d + 0.16))
            out.append(pool(0.46 * d, -0.05, 0.28 * d + 0.14))
            out.append(pool(0.08, -0.24 * d, 0.24 * d + 0.12))
        }
        // arterial spurts (early)
        if decals && d > 0.02 && d < 0.6 {
            let sp = 1 - d / 0.6
            for n in 0..<6 {
                let a = Float(n) / 6 * 2 * .pi
                out.append(C(SIMD3(cos(a) * 0.12, 0.45, sin(a) * 0.12), SIMD3(cos(a) * 0.34, 0.4 + sp * 0.6, sin(a) * 0.34), 0.045 * sp, 0.0, blood, 0.04))
            }
        }
        // gory chunks for an overkill gib
        if gib && d > 0.1 {
            for n in 0..<7 {
                let a = Float(n) / 7 * 2 * .pi, rr = 0.2 + d * (0.4 + Float(n % 3) * 0.15)
                let bc = base[min(n, base.count - 1)].col
                out.append(S(SIMD3(cos(a) * rr, max(0.06, 0.1 + sin(Float(n)) * 0.05), sin(a) * rr * 0.7), 0.06 + Float(n % 3) * 0.02, mix3(bc, blood, 0.5), 0.05))
            }
        }
        return out
    }

    // ── THE QUEEN'S DEATH — an event, not a crumple ──────────────────────────
    // The brood-mother rears back screaming, convulses as the plasma cooks
    // her, then the whole upper mass topples forward and CRASHES to the deck.
    // The timeline is normalised 0…1 (World.queenDeathTime maps it to
    // seconds); the final frame lands EXACTLY on deadShapes(d:1, sprawl:0.15)
    // so the corpse / burn / revive pipeline takes over with no visible pop.
    // Phase fences, as fractions of the death:
    static let queenRearT: Float = 0.20      // the scream arch peaks
    static let queenConvulseT: Float = 0.55  // convulsions weaken to nothing
    static let queenImpactT: Float = 0.78    // the mass hits the deck (World keys the floor-shake/thud to this)

    static func queenDeathShapes(_ base: [Shape], t: Float) -> [Shape] {
        let tt = max(0, min(1, t))
        func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
            let u = max(0, min(1, (x - e0) / (e1 - e0))); return u * u * (3 - 2 * u)
        }
        // the upper body's pitch through the stages (radians; positive rears back)
        let rearAngle: Float = 0.80, sag: Float = 0.14, fallAngle: Float = -1.30
        let rearEnv = smooth(0, queenRearT, tt)
        var pitch = rearAngle * rearEnv
        var shudder: Float = 0                              // lateral convulsion whip
        var heave: Float = 0                                // the sac's violent breathing
        var lurch: Float = 0                                // the whole mass pitching into the fall
        if tt >= queenRearT && tt < queenConvulseT {
            let c = (tt - queenRearT) / (queenConvulseT - queenRearT)
            let fade = 1 - c * 0.6                          // ~7 Hz spasms, weakening
            shudder = sinf(c * 44) * 0.16 * fade
            heave = sinf(c * 44) * 0.06 * fade
            pitch += sinf(c * 31) * 0.09 * fade - sag * c
        } else if tt >= queenConvulseT {
            // gravity takes her: a quadratic fall with no easing back
            let f = min(1, (tt - queenConvulseT) / (queenImpactT - queenConvulseT))
            pitch = (rearAngle - sag) + (fallAngle - (rearAngle - sag)) * f * f
            lurch = f * f
        }
        let settle = tt <= queenImpactT ? 0 : smooth(queenImpactT, 1, tt)
        if settle > 0 { pitch += sinf(settle * 2 * .pi) * 0.07 * (1 - settle); lurch = 1 }   // the crash rings out
        let lean = smooth(queenConvulseT, queenImpactT, tt) * 0.18                // she goes down slightly to one side
        let glow = max(0, 1 - tt * 2.4)                     // the plasma-scream flush, fading
        let bright = SIMD3<Float>(236, 72, 60)
        let corpse = deadShapes(base, d: 1, gib: false, decals: false, sprawl: 0.15)
        let pivot = SIMD3<Float>(0, 0.72, -0.05)            // where the torso rises from the rooted sac
        var out = [Shape]()
        for (i, s) in base.enumerated() {
            func fall(_ p: SIMD3<Float>) -> SIMD3<Float> {
                // the sac is ROOTED: only the torso/head/crest arc (w rises with
                // height), so the mass pivots where it grows from the body…
                let w = smooth(0.6, 1.15, p.y)
                let th = pitch * w
                var q = p - pivot
                q.x += shudder * w
                let cy = cosf(th), sy = sinf(th)
                q = SIMD3(q.x, q.y * cy - q.z * sy, q.y * sy + q.z * cy)
                var r = q + pivot
                r.x += lean * w
                // …but the MASS still tells the story: she gathers herself up for
                // the scream, the sac heaves with each convulsion, and the whole
                // body lurches forward into the fall
                r.y *= 1 + (0.10 * rearEnv + heave) * (1 - w)
                r.z -= lurch * (0.12 + 0.30 * w)
                // the rooted skirt spasms with the convulsions, each tentacle on
                // its own beat
                r.x += shudder * (1 - w) * 0.35 * sinf(Float(i) * 1.7)
                r.y = max(0.05, r.y)
                return r
            }
            var a = fall(s.a), b = fall(s.b)
            var r1 = s.r1, r2 = s.r2
            var col = mix3(s.col, bright, glow * 0.45)
            var k = s.k
            if settle > 0 {                                 // blend onto the exact corpse pose
                let c = corpse[i]
                a = mix3(a, c.a, settle); b = mix3(b, c.b, settle)
                r1 += (c.r1 - r1) * settle; r2 += (c.r2 - r2) * settle
                col = mix3(col, c.col, settle); k += (c.k - k) * settle
            }
            out.append(Shape(a: a, b: b, r1: r1, r2: r2, col: col, k: k, sphere: s.sphere))
        }
        return out
    }

    // ════════════════════════════════════════════════════════════════════════
    static func run(gif: Bool) {
        let dir = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/Citadel-Aliens")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let defs = roster()

        // roster still-sheet — each creature across three angles (the elongated
        // skull, back-pipes, crown and bladed tail only read once you turn them).
        let angles: [(String, Float)] = [("FRONT", 0.15), ("THREE-QUARTER", 0.85), ("PROFILE", 1.55)]
        let cols = angles.count, cw = 360, ch = 392
        let sheet = Canvas2D(width: cols * cw, height: 70 + defs.count * ch)
        for y in 0..<sheet.height { sheet.hLine(0, sheet.width - 1, y, mixRGBA(packRGBA(16, 12, 14), packRGBA(28, 19, 21), Float(y) / Float(sheet.height))) }
        sheet.labelCentered("CITADEL — THE HIVE   ·   bespoke DRONE + QUEEN   (raymarched mock-up)", 22, size: 24, color: packRGBA(240, 196, 96), weight: .heavy)
        let tw = 240, th = 300
        for (i, d) in defs.enumerated() {
            let gy = 70 + i * ch
            for (a, ang) in angles.enumerated() {
                let gx = a * cw
                let tile = renderTile(d, ph: 0.12, atk: 0, yaw: ang.1, w: tw, h: th)
                for jj in -10...10 { for ii in -(tw / 3)...(tw / 3) {
                    let dd = Float(ii * ii) / Float((tw / 3) * (tw / 3)) + Float(jj * jj) / 100
                    if dd < 1 { sheet.blend(gx + cw / 2 + ii, gy + th + 6 + jj, packRGBA(0, 0, 0), (1 - dd) * 0.4) }
                } }
                sheet.blitBitmap(tile, tw, th, gx + (cw - tw) / 2, gy)
                sheet.labelCentered2(ang.0, gx, cw, gy + 4, size: 13, color: packRGBA(150, 150, 162), weight: .bold)
            }
            sheet.labelCentered2(d.name, 0, cols * cw, gy + th + 20, size: 24, color: packRGBA(236, 210, 170), weight: .heavy)
            sheet.labelCentered2(d.role + "   ·   " + d.blurb, 0, cols * cw, gy + th + 48, size: 15, color: packRGBA(206, 150, 140), weight: .bold)
        }
        Captures.writePNG(sheet.framebuffer, w: sheet.width, h: sheet.height, scale: 1, to: dir.appendingPathComponent("00-roster.png"))
        print("  wrote 00-roster.png")

        // walk-cycle filmstrips — one full stride laid out frame-by-frame (read
        // left→right; it loops). Side-on 3/4 so the gait and tail-sway show.
        do {
            let frames = 8, fw = 150, fh = 192
            let strip = Canvas2D(width: frames * fw, height: 64 + defs.count * (fh + 34))
            for y in 0..<strip.height { strip.hLine(0, strip.width - 1, y, mixRGBA(packRGBA(16, 12, 14), packRGBA(28, 19, 21), Float(y) / Float(strip.height))) }
            strip.labelCentered("WALK CYCLES   ·   one full stride, looping", 20, size: 22, color: packRGBA(240, 196, 96), weight: .heavy)
            for (i, d) in defs.enumerated() {
                let gy = 64 + i * (fh + 34)
                for k in 0..<frames {
                    let tile = renderTile(d, ph: Float(k) / Float(frames), atk: 0, yaw: 0.9, w: fw - 12, h: fh)
                    strip.blitBitmap(tile, fw - 12, fh, k * fw + 6, gy)
                }
                strip.labelCentered2(d.name, 0, frames * fw, gy + fh + 4, size: 16, color: packRGBA(236, 210, 170), weight: .heavy)
            }
            Captures.writePNG(strip.framebuffer, w: strip.width, h: strip.height, scale: 1, to: dir.appendingPathComponent("01-walk-strip.png"))
            print("  wrote 01-walk-strip.png")
        }

        // death preview — collapse (MAULER) vs gib overkill (HUSK)
        do {
            let dcols = 5, dcw = 224, dch = 250, dt = 176, dh2 = 214
            let ds = Canvas2D(width: dcols * dcw, height: 2 * dch + 56)
            for y in 0..<ds.height { ds.hLine(0, ds.width - 1, y, mixRGBA(packRGBA(18, 12, 13), packRGBA(30, 16, 17), Float(y) / Float(ds.height))) }
            ds.labelCentered("DEATH — collapse into a bleeding heap (top)   ·   gib overkill (bottom)", 18, size: 22, color: packRGBA(236, 120, 110), weight: .heavy)
            let collapse = mauler(), gibd = husk()
            let steps: [Float] = [0, 0.3, 0.55, 0.8, 1.0]
            for (c, dv) in steps.enumerated() {
                ds.blitBitmap(renderDeath(collapse, d: dv, gib: false, yaw: 0.4, w: dt, h: dh2), dt, dh2, c * dcw + (dcw - dt) / 2, 48)
                ds.blitBitmap(renderDeath(gibd, d: dv, gib: true, yaw: 0.4, w: dt, h: dh2), dt, dh2, c * dcw + (dcw - dt) / 2, 48 + dch)
                ds.labelCentered2(String(format: "%.0f%%", dv * 100), c * dcw, dcw, 40 + dch * 2, size: 14, color: packRGBA(184, 152, 152), weight: .medium)
            }
            Captures.writePNG(ds.framebuffer, w: ds.width, h: ds.height, scale: 1, to: dir.appendingPathComponent("08-death-preview.png"))
            print("  wrote 08-death-preview.png")
        }

        // the QUEEN'S staged death — rear → convulse → topple → crash → settle,
        // in profile so the arch and the forward fall read
        do {
            let qdef = queen()
            let steps: [Float] = [0, 0.1, 0.2, 0.32, 0.44, 0.55, 0.65, 0.72, 0.78, 0.86, 1.0]
            let qw2 = 250, qh2 = 260, qcw = qw2 + 10
            let qs = Canvas2D(width: steps.count * qcw, height: qh2 + 92)
            for y in 0..<qs.height { qs.hLine(0, qs.width - 1, y, mixRGBA(packRGBA(18, 12, 13), packRGBA(30, 16, 17), Float(y) / Float(qs.height))) }
            qs.labelCentered("THE QUEEN'S DEATH   ·   rear → convulse → topple → CRASH → settle", 18, size: 22, color: packRGBA(236, 120, 110), weight: .heavy)
            let base = qdef.build(0, 0)
            for (c, tv) in steps.enumerated() {
                let tile = renderShapes(queenDeathShapes(base, t: tv), viewH: qdef.viewH + 0.3, groundY: qdef.groundY - 0.15,
                                        yaw: 1.55, w: qw2, h: qh2)
                qs.blitBitmap(tile, qw2, qh2, c * qcw + 5, 52)
                let tag = tv <= queenRearT ? "REAR" : (tv < queenConvulseT ? "CONVULSE" : (tv < queenImpactT ? "TOPPLE" : (tv < 0.82 ? "CRASH" : "SETTLE")))
                qs.labelCentered2(String(format: "t %.2f  ·  %@", tv, tag), c * qcw, qcw, qh2 + 58, size: 13, color: packRGBA(184, 152, 152), weight: .medium)
            }
            Captures.writePNG(qs.framebuffer, w: qs.width, h: qs.height, scale: 1, to: dir.appendingPathComponent("09-queen-death.png"))
            print("  wrote 09-queen-death.png")
        }

        if gif {
            let gw = 160, gh = 200, scale = 2
            for (i, d) in defs.enumerated() {
                let slug = d.name.lowercased()
                // turntable — idle breathing while it rotates a full 360°
                var turn: [[UInt32]] = []
                let N = 24
                for f in 0..<N { turn.append(renderTile(d, ph: Float(f) / Float(N), atk: 0, yaw: Float(f) / Float(N) * 2 * .pi, w: gw, h: gh)) }
                writeGIF(turn, w: gw, h: gh, scale: scale, delay: 0.07, to: dir.appendingPathComponent(String(format: "%02d-%@-turntable.gif", i + 1, slug)))
                print("  wrote \(String(format: "%02d-%@-turntable.gif", i + 1, slug))")
                // walk — one full stride, looping, fixed 3/4 view
                var walk: [[UInt32]] = []
                let M = 16
                for f in 0..<M { walk.append(renderTile(d, ph: Float(f) / Float(M), atk: 0, yaw: 0.9, w: gw, h: gh)) }
                writeGIF(walk, w: gw, h: gh, scale: scale, delay: 0.065, to: dir.appendingPathComponent(String(format: "%02d-%@-walk.gif", i + 1, slug)))
                print("  wrote \(String(format: "%02d-%@-walk.gif", i + 1, slug))")
                // death — collapse into a bleeding heap
                var fr: [[UInt32]] = []
                for f in 0..<16 { fr.append(renderDeath(d, d: Float(f) / 15, gib: false, yaw: 0.6, w: gw, h: gh)) }
                writeGIF(fr, w: gw, h: gh, scale: scale, delay: 0.08, to: dir.appendingPathComponent(String(format: "%02d-%@-death.gif", i + 1, slug)))
                print("  wrote \(String(format: "%02d-%@-death.gif", i + 1, slug))")
            }
        }
        print("Citadel: aliens written to \(dir.path)")
    }

    // ── GIF encoder (ImageIO), tiles composited over a dark stage ─────────────
    static func writeGIF(_ tiles: [[UInt32]], w: Int, h: Int, scale: Int, delay: Double, to url: URL) {
        let bg = packRGBA(22, 15, 17)
        let uw = w * scale, uh = h * scale
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, tiles.count, nil) else { return }
        CGImageDestinationSetProperties(dst, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let fp = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
        for tile in tiles {
            var big = [UInt32](repeating: bg, count: uw * uh)
            for j in 0..<h { for i in 0..<w {
                let c = tile[j * w + i]
                let px: UInt32 = (c >> 24) == 0 ? bg : c
                for sy in 0..<scale { let row = (j * scale + sy) * uw
                    for sx in 0..<scale { big[row + i * scale + sx] = px } }
            } }
            if let img = cgImage(big, uw, uh) { CGImageDestinationAddImage(dst, img, fp) }
        }
        CGImageDestinationFinalize(dst)
    }
    static func cgImage(_ buf: [UInt32], _ w: Int, _ h: Int) -> CGImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
              colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32), let data = rep.bitmapData else { return nil }
        buf.withUnsafeBytes { _ = memcpy(data, $0.baseAddress, w * h * 4) }
        return rep.cgImage
    }

    // ════════════════════════════════════════════════════════════════════════
    // THE ROSTER — six organic occupiers
    // ════════════════════════════════════════════════════════════════════════
    static func roster() -> [CDef] {
        // #42 mock-up pass — the redesign's surviving pair, Giger/xenomorph language.
        [drone(), queen()]
    }

    // 1 — HUSK: gaunt swarmer (grunt). Emaciated, gaping fanged maw, raking claws.
    static func husk() -> CDef {
        let skin = SIMD3<Float>(118, 128, 98), dark = SIMD3<Float>(70, 80, 58)
        let claw = SIMD3<Float>(210, 204, 180), eye = SIMD3<Float>(255, 150, 48)
        let maw = SIMD3<Float>(28, 10, 14), fang = SIMD3<Float>(214, 206, 182)
        return CDef(name: "HUSK", role: "SWARMER", blurb: "Starved infantry. Weak, never alone — all jaws and claws.",
                    viewH: 2.5, groundY: -0.05) { ph, atk in
            let g = sin(ph * 2 * .pi), bob = abs(sin(ph * 2 * .pi)) * 0.04
            var s = [Shape]()
            // spindly legs, splayed knees
            s.append(C(SIMD3(-0.17, 0.94 + bob, g * 0.06), SIMD3(-0.24, 0.5, 0.05 + g * 0.12), 0.075, 0.055, dark))
            s.append(C(SIMD3(-0.24, 0.5, 0.05 + g * 0.12), SIMD3(-0.25, 0.03, g * 0.18), 0.055, 0.04, dark))
            s.append(C(SIMD3(0.17, 0.94 + bob, -g * 0.06), SIMD3(0.24, 0.5, 0.05 - g * 0.12), 0.075, 0.055, dark))
            s.append(C(SIMD3(0.24, 0.5, 0.05 - g * 0.12), SIMD3(0.25, 0.03, -g * 0.18), 0.055, 0.04, dark))
            // narrow pelvis + emaciated, deeply hunched torso
            s.append(S(SIMD3(0, 0.98 + bob, 0), 0.15, skin))
            s.append(C(SIMD3(0, 1.0 + bob, 0.04), SIMD3(0, 1.62 + bob, -0.16), 0.19, 0.15, skin))
            // visible ribs / sunken sternum
            for ri in 0..<3 {
                let y = 1.18 + Float(ri) * 0.16 + bob
                s.append(S(SIMD3(0, y, -0.14 - Float(ri) * 0.02), 0.085, dark, 0.16))
            }
            // shoulders + long raking arms reaching forward
            for sx in [Float(-1), 1] {
                s.append(S(SIMD3(sx * 0.24, 1.58 + bob, -0.08), 0.1, skin))
                let reach = -0.22 - atk * 0.22 + (sx > 0 ? g : -g) * 0.07
                let elbow = SIMD3(sx * 0.42, 1.08 + bob, reach)
                s.append(C(SIMD3(sx * 0.24, 1.58 + bob, -0.08), elbow, 0.07, 0.05, skin))
                let hand = SIMD3(sx * 0.46, 0.56, reach - 0.2 - atk * 0.24)
                s.append(C(elbow, hand, 0.05, 0.04, skin))
                // long curved claws
                for cl in 0..<3 { s.append(C(hand, hand + SIMD3(Float(cl - 1) * 0.06, -0.22, -0.16), 0.028, 0.0, claw, 0.04)) }
            }
            // elongated skull pushed forward, gaping fanged maw, sunken glowing eyes
            s.append(S(SIMD3(0, 1.68 + bob, -0.2), 0.14, skin))
            s.append(C(SIMD3(0, 1.62 + bob, -0.28), SIMD3(0, 1.56 + bob, -0.46), 0.12, 0.09, skin))   // snout
            s.append(S(SIMD3(0, 1.56 + bob, -0.42), 0.08 + atk * 0.04, maw, 0.06))                    // gaping maw
            for tt in 0..<5 {
                let x = -0.07 + Float(tt) * 0.035
                s.append(C(SIMD3(x, 1.6 + bob, -0.46), SIMD3(x, 1.52 + bob - atk * 0.04, -0.48), 0.018, 0.0, fang, 0.015))
            }
            s.append(S(SIMD3(-0.07, 1.74 + bob, -0.3), 0.03, eye, 0.04))
            s.append(S(SIMD3(0.07, 1.74 + bob, -0.3), 0.03, eye, 0.04))
            return s
        }
    }

    // 2 — SPITTER: hunched, bulbous bile-beast (ranged trooper).
    static func spitter() -> CDef {
        let skin = SIMD3<Float>(126, 148, 70), dark = SIMD3<Float>(72, 92, 42)
        let gut = SIMD3<Float>(150, 196, 92), eye = SIMD3<Float>(224, 70, 54)
        let maw = SIMD3<Float>(26, 14, 12), bile = SIMD3<Float>(180, 255, 120)
        return CDef(name: "SPITTER", role: "RANGED", blurb: "Hunched bile-beast. Spits burning ichor from a gaping maw.",
                    viewH: 2.3, groundY: -0.05) { ph, atk in
            let g = sin(ph * 2 * .pi), breathe = sin(ph * 2 * .pi) * 0.015
            var s = [Shape]()
            // short splayed legs
            for sx in [Float(-1), 1] {
                s.append(C(SIMD3(sx * 0.22, 0.56, 0.06), SIMD3(sx * 0.32, 0.04, (sx > 0 ? g : -g) * 0.06), 0.075, 0.05, dark))
            }
            // segmented, asymmetric gut (no single centred bulge)
            s.append(S(SIMD3(0, 0.62 + breathe, 0.1), 0.4, gut))
            s.append(S(SIMD3(-0.2, 0.46, -0.04), 0.23, gut, 0.22))
            s.append(S(SIMD3(0.18, 0.54, 0.16), 0.2, gut, 0.22))
            s.append(S(SIMD3(0, 0.86, 0.16), 0.22, gut, 0.2))
            // pustules / mottling on the back of the gut
            s.append(S(SIMD3(0.12, 0.92, 0.28), 0.07, dark, 0.1))
            s.append(S(SIMD3(-0.14, 0.84, 0.26), 0.06, dark, 0.1))
            s.append(S(SIMD3(0.02, 1.0, 0.22), 0.055, dark, 0.1))
            // hunched neck leaning forward over the gut
            s.append(C(SIMD3(0, 0.92, -0.04), SIMD3(0, 1.26, -0.26), 0.16, 0.11, skin))
            // head, low and forward, with a wide gaping maw
            s.append(S(SIMD3(0, 1.32, -0.32), 0.17, skin))
            s.append(S(SIMD3(0, 1.26, -0.46), 0.1 + atk * 0.05, maw, 0.07))   // gaping mouth
            if atk > 0.01 { s.append(S(SIMD3(0, 1.26, -0.54), 0.07 * atk, bile, 0.04)) }   // charging bile
            // eye cluster above the maw
            for (ex, ey, ez) in [(-0.07, 1.42, -0.42), (0.07, 1.42, -0.42), (0.0, 1.48, -0.4), (-0.04, 1.36, -0.45), (0.05, 1.36, -0.45)] {
                s.append(S(SIMD3(Float(ex), Float(ey), Float(ez)), 0.028, eye, 0.03))
            }
            // thin arms hanging forward
            for sx in [Float(-1), 1] {
                s.append(C(SIMD3(sx * 0.24, 1.04, -0.08), SIMD3(sx * 0.34, 0.62, -0.2), 0.05, 0.035, dark))
            }
            return s
        }
    }

    // 3 — MAULER: hulking carapaced charger (heavy brute).
    static func mauler() -> CDef {
        let muscle = SIMD3<Float>(146, 56, 46), plate = SIMD3<Float>(92, 60, 52)
        let tusk = SIMD3<Float>(212, 202, 176), eye = SIMD3<Float>(255, 200, 90), dark = SIMD3<Float>(70, 30, 28)
        return CDef(name: "MAULER", role: "HEAVY", blurb: "Carapaced shock-beast. Soaks punishment, charges, hurls.",
                    viewH: 2.7, groundY: -0.05) { ph, atk in
            let g = sin(ph * 2 * .pi), lunge = atk * 0.18
            var s = [Shape]()
            // thick short legs
            for sx in [Float(-1), 1] {
                s.append(C(SIMD3(sx * 0.34, 0.86, 0.02), SIMD3(sx * 0.4, 0.06, (sx > 0 ? g : -g) * 0.12), 0.2, 0.15, muscle))
            }
            // massive hunched torso, pushed forward on attack
            s.append(S(SIMD3(0, 1.16, 0.04 - lunge), 0.5, muscle))
            s.append(S(SIMD3(0, 1.62, 0.0 - lunge), 0.46, muscle))
            // carapace back ridge
            for r in 0..<4 { s.append(C(SIMD3(0, 1.2 + Float(r) * 0.22, 0.34), SIMD3(0, 1.28 + Float(r) * 0.22, 0.5), 0.13, 0.04, plate, 0.05)) }
            // broad shoulders + heavy arms (raised on attack)
            for sx in [Float(-1), 1] {
                s.append(S(SIMD3(sx * 0.52, 1.74, -0.02), 0.24, muscle))
                let elbow = SIMD3(sx * 0.66, 1.2 + atk * 0.4, -0.16 - lunge)
                s.append(C(SIMD3(sx * 0.52, 1.74, -0.02), elbow, 0.16, 0.13, muscle))
                let fist = SIMD3(sx * 0.6, 0.84 + atk * 0.5, -0.28 - lunge)
                s.append(C(elbow, fist, 0.13, 0.15, muscle))
                s.append(S(fist, 0.17, plate, 0.12))
            }
            // low horned head, tusks, eyes
            s.append(S(SIMD3(0, 1.42, -0.34 - lunge), 0.22, muscle))
            s.append(C(SIMD3(-0.1, 1.34, -0.5 - lunge), SIMD3(-0.22, 1.5, -0.66 - lunge), 0.05, 0.0, tusk, 0.04))
            s.append(C(SIMD3(0.1, 1.34, -0.5 - lunge), SIMD3(0.22, 1.5, -0.66 - lunge), 0.05, 0.0, tusk, 0.04))
            s.append(S(SIMD3(-0.08, 1.5, -0.5 - lunge), 0.04, eye, 0.04))
            s.append(S(SIMD3(0.08, 1.5, -0.5 - lunge), 0.04, eye, 0.04))
            s.append(S(SIMD3(0, 1.18, -0.42 - lunge), 0.11, dark, 0.1))   // gaping maw
            for tt in 0..<5 { let x = -0.07 + Float(tt) * 0.035; s.append(C(SIMD3(x, 1.22, -0.5 - lunge), SIMD3(x, 1.12, -0.52 - lunge), 0.022, 0.0, tusk, 0.02)) }
            // jutting shoulder / back spikes
            for (sx2, sy2, sz2) in [(-0.52, 1.92, 0.18), (0.52, 1.92, 0.18), (-0.26, 2.02, 0.28), (0.26, 2.02, 0.28)] {
                s.append(C(SIMD3(Float(sx2), Float(sy2), Float(sz2)), SIMD3(Float(sx2) * 1.15, Float(sy2) + 0.34, Float(sz2) + 0.12), 0.06, 0.0, plate, 0.04))
            }
            return s
        }
    }

    // 4 — DRIFTER: floating gasbag horror (flyer). One huge slit-pupil eye.
    static func drifter() -> CDef {
        let body = SIMD3<Float>(150, 80, 178), dark = SIMD3<Float>(96, 44, 120), darker = SIMD3<Float>(60, 26, 82)
        let eyeW = SIMD3<Float>(238, 236, 246), slit = SIMD3<Float>(16, 6, 12)
        let bloodshot = SIMD3<Float>(180, 60, 80), fang = SIMD3<Float>(222, 214, 192), maw = SIMD3<Float>(28, 8, 16)
        return CDef(name: "DRIFTER", role: "FLYER", blurb: "Airborne horror — one slit eye, a gaping fanged maw.",
                    viewH: 2.5, groundY: -0.15) { ph, atk in
            let bobY = sin(ph * 2 * .pi) * 0.07, open = 0.04 + atk * 0.14
            var s = [Shape]()
            let cy = 1.36 + bobY
            // lumpy, asymmetric bulb (not a smooth breast-sphere)
            s.append(S(SIMD3(0, cy, 0), 0.46, body))
            s.append(S(SIMD3(-0.26, cy - 0.04, 0.12), 0.2, body, 0.24))
            s.append(S(SIMD3(0.24, cy + 0.06, 0.14), 0.18, body, 0.24))
            s.append(S(SIMD3(0.06, cy + 0.3, 0.06), 0.12, darker, 0.16))
            s.append(S(SIMD3(-0.18, cy + 0.22, -0.04), 0.1, darker, 0.14))
            // heavy brow/socket ridge so the eye reads as an EYE
            s.append(S(SIMD3(0, cy + 0.09, -0.32), 0.27, dark, 0.12))
            s.append(S(SIMD3(0, cy + 0.05, -0.47), 0.185, bloodshot, 0.05))  // bloodshot rim
            s.append(S(SIMD3(0, cy + 0.05, -0.49), 0.165, eyeW, 0.04))       // sclera
            s.append(C(SIMD3(0, cy + 0.21, -0.62), SIMD3(0, cy - 0.11, -0.62), 0.038, 0.038, slit, 0.02))  // vertical slit pupil
            s.append(S(SIMD3(-0.05, cy + 0.13, -0.64), 0.03, SIMD3(250, 246, 250), 0.02))                  // catchlight
            // gaping fanged maw below the eye
            s.append(S(SIMD3(0, cy - 0.34, -0.34), 0.17 + open, maw, 0.1))
            for tt in 0..<8 {
                let x = -0.24 + Float(tt) * 0.068
                s.append(C(SIMD3(x, cy - 0.24, -0.42), SIMD3(x, cy - 0.32 - open, -0.44), 0.026, 0.0, fang, 0.02))  // upper fangs
                s.append(C(SIMD3(x, cy - 0.46 - open, -0.42), SIMD3(x, cy - 0.38 - open, -0.44), 0.024, 0.0, fang, 0.02))
            }
            // longer, sharper dorsal + radial spines
            for a in stride(from: 0, to: 360, by: 30) {
                let r = Float(a) * .pi / 180
                s.append(C(SIMD3(cos(r) * 0.42, cy + 0.3, sin(r) * 0.42 + 0.12), SIMD3(cos(r) * 0.66, cy + 0.72, sin(r) * 0.66 + 0.16), 0.055, 0.0, dark, 0.04))
            }
            // writhing tentacles
            for tt in 0..<6 {
                let x = -0.34 + Float(tt) * 0.14, sw = sin(ph * 2 * .pi + Float(tt) * 1.3) * 0.1
                s.append(C(SIMD3(x, cy - 0.42, 0.06), SIMD3(x + sw, cy - 1.05, 0.08 + sw), 0.055, 0.015, dark, 0.05))
            }
            return s
        }
    }

    // 5 — STALKER: low scuttling ambusher (fast melee, the new sixth).
    static func stalker() -> CDef {
        let chitin = SIMD3<Float>(60, 112, 110), belly = SIMD3<Float>(150, 172, 150)
        let mand = SIMD3<Float>(206, 200, 176), eye = SIMD3<Float>(120, 250, 120), dark = SIMD3<Float>(34, 64, 62)
        return CDef(name: "STALKER", role: "AMBUSHER", blurb: "Low, fast, leaps from the dark. Mandibles and speed.",
                    viewH: 1.7, groundY: -0.05) { ph, atk in
            let g = sin(ph * 4 * .pi) * 0.12, lunge = atk * 0.2   // quick scuttle gait
            var s = [Shape]()
            // elongated low body (front toward -z, head low)
            s.append(C(SIMD3(0, 0.5, 0.34), SIMD3(0, 0.44, -0.34 - lunge), 0.22, 0.16, chitin))
            s.append(S(SIMD3(0, 0.42, 0.08), 0.2, belly, 0.18))          // pale underbelly
            // four splayed legs (diagonal gait)
            let phases: [Float] = [g, -g, -g, g]
            let pos: [(Float, Float)] = [(-0.24, 0.28), (0.24, 0.28), (-0.24, -0.2), (0.24, -0.2)]
            for li in 0..<4 {
                let (lx, lz) = pos[li]
                s.append(C(SIMD3(lx, 0.46, lz), SIMD3(lx * 1.9, 0.42, lz + phases[li]), 0.05, 0.04, dark))
                s.append(C(SIMD3(lx * 1.9, 0.42, lz + phases[li]), SIMD3(lx * 2.0, 0.02, lz + phases[li] * 1.4), 0.04, 0.025, dark))
            }
            // head + mandibles
            s.append(S(SIMD3(0, 0.46, -0.46 - lunge), 0.15, chitin))
            for sx in [Float(-1), 1] {
                let spread = atk * 0.1
                s.append(C(SIMD3(sx * 0.08, 0.42, -0.56 - lunge), SIMD3(sx * (0.2 + spread), 0.4, -0.74 - lunge), 0.04, 0.0, mand, 0.04))
            }
            s.append(S(SIMD3(-0.07, 0.54, -0.54 - lunge), 0.035, eye, 0.03))
            s.append(S(SIMD3(0.07, 0.54, -0.54 - lunge), 0.035, eye, 0.03))
            // dorsal spine ridge
            for sp in 0..<5 { let z = 0.3 - Float(sp) * 0.14; s.append(C(SIMD3(0, 0.58, z), SIMD3(0, 0.92, z - 0.05), 0.045, 0.0, dark, 0.04)) }
            // raised stinger tail
            s.append(C(SIMD3(0, 0.5, 0.4), SIMD3(0, 1.02, 0.54), 0.08, 0.0, chitin, 0.06))
            s.append(C(SIMD3(0, 1.02, 0.54), SIMD3(0, 1.18, 0.4), 0.05, 0.0, mand, 0.04))   // stinger barb
            return s
        }
    }

    // 6 — MONARCH: towering citadel commander (boss).
    static func monarch() -> CDef {
        let skin = SIMD3<Float>(96, 74, 122), plate = SIMD3<Float>(52, 42, 72)
        let core = SIMD3<Float>(255, 140, 60), horn = SIMD3<Float>(200, 190, 168)
        let eye = SIMD3<Float>(255, 212, 92), coreHot = SIMD3<Float>(255, 238, 180)
        return CDef(name: "MONARCH", role: "COMMANDER", blurb: "The thing that holds the world. Many eyes, a burning core.",
                    viewH: 3.1, groundY: -0.05) { ph, atk in
            let g = sin(ph * 2 * .pi), flare = 1 + atk * 0.3 + sin(ph * 4 * .pi) * 0.05
            var s = [Shape]()
            // heavy legs
            for sx in [Float(-1), 1] {
                s.append(C(SIMD3(sx * 0.32, 1.1, 0), SIMD3(sx * 0.4, 0.58, (sx > 0 ? g : -g) * 0.1), 0.2, 0.16, skin))
                s.append(C(SIMD3(sx * 0.4, 0.58, 0), SIMD3(sx * 0.42, 0.04, 0), 0.16, 0.12, skin))
            }
            // broad upright torso with exposed glowing core
            s.append(S(SIMD3(0, 1.5, 0.02), 0.46, skin))
            s.append(S(SIMD3(0, 2.05, -0.02), 0.42, skin))
            s.append(S(SIMD3(0, 1.62, -0.36), 0.2 * flare, core, 0.1))    // heart/core
            s.append(S(SIMD3(0, 1.62, -0.48), 0.1 * flare, coreHot, 0.05))
            for r in 0..<3 { s.append(C(SIMD3(Float(r - 1) * 0.26, 1.5, 0.3), SIMD3(Float(r - 1) * 0.26, 1.5, 0.46), 0.12, 0.04, plate, 0.05)) }
            // four arms — two great, two small upper tendrils (spread on attack)
            for sx in [Float(-1), 1] {
                s.append(S(SIMD3(sx * 0.48, 2.16, -0.02), 0.2, skin))
                let elbow = SIMD3(sx * (0.7 + atk * 0.15), 1.62, -0.16)
                s.append(C(SIMD3(sx * 0.48, 2.16, -0.02), elbow, 0.14, 0.11, skin))
                let hand = SIMD3(sx * (0.78 + atk * 0.2), 1.04, -0.28)
                s.append(C(elbow, hand, 0.11, 0.08, skin))
                for cl in 0..<3 { s.append(C(hand, hand + SIMD3(Float(cl - 1) * 0.06, -0.2, -0.12), 0.035, 0.0, horn, 0.04)) }
                // upper tendril
                s.append(C(SIMD3(sx * 0.36, 2.3, 0.04), SIMD3(sx * (0.5 + atk * 0.3), 2.7 + g * 0.06, -0.1), 0.06, 0.02, skin, 0.05))
            }
            // crowned head, crown of horns, eye cluster
            s.append(S(SIMD3(0, 2.46, -0.06), 0.26, skin))
            for hx in stride(from: -0.22, through: 0.22, by: 0.11) {
                s.append(C(SIMD3(Float(hx), 2.62, 0.0), SIMD3(Float(hx) * 1.5, 3.0, 0.06), 0.05, 0.0, horn, 0.04))
            }
            for (ex, ey) in [(-0.1, 2.5), (0.1, 2.5), (0.0, 2.56), (-0.05, 2.42), (0.05, 2.42)] {
                s.append(S(SIMD3(Float(ex), Float(ey), -0.28), 0.03, eye, 0.03))
            }
            // gaping fanged maw beneath the eye-cluster
            s.append(S(SIMD3(0, 2.3, -0.26), 0.09 + atk * 0.04, SIMD3(18, 8, 14), 0.06))
            for tt in 0..<6 { let x = -0.09 + Float(tt) * 0.036; s.append(C(SIMD3(x, 2.34, -0.32), SIMD3(x, 2.26 - atk * 0.04, -0.34), 0.016, 0.0, horn, 0.014)) }
            return s
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // #42 REDESIGN PAIR — bespoke DRONE + QUEEN (replace the stalker/monarch
    // placeholders MonsterBake currently borrows). Brief: DRONE = scaly/slimy
    // dark grey-green melee pack-hunter; QUEEN = large slimy scaly grey-brown
    // brood-mother with a head + tentacles, lairs in the dark.
    // ════════════════════════════════════════════════════════════════════════

    // DRONE (primary) — hunched, digitigrade pack-hunter. Long raking arms, a
    // smooth predatory skull (no big glowing eyes — it hunts by scent), a pale
    // slimy underbelly and a scaly dorsal ridge over dark grey-green hide.
    static func drone() -> CDef {
        let carapace = SIMD3<Float>(40, 54, 44), dark = SIMD3<Float>(16, 22, 18)
        let bone = SIMD3<Float>(196, 190, 164), maw = SIMD3<Float>(30, 8, 10)
        return CDef(name: "DRONE", role: "HIVE MELEE", blurb: "Biomechanical hunter — domed skull, back-pipes, bladed tail.",
                    viewH: 2.3, groundY: -0.05) { ph, atk in
            let g = sin(ph * 2 * .pi), bob = abs(sin(ph * 2 * .pi)) * 0.04, lunge = atk * 0.22
            var s = [Shape]()
            // ── long digitigrade legs (haunch high, ankle kicked back, clawed toes) ──
            for sx in [Float(-1), 1] {
                let kn = (sx > 0 ? g : -g) * 0.22           // stride swing (drives the walk)
                s.append(C(SIMD3(sx * 0.15, 0.94 + bob, 0.12), SIMD3(sx * 0.27, 0.5, -0.08 + kn), 0.09, 0.06, carapace))
                s.append(C(SIMD3(sx * 0.27, 0.5, -0.08 + kn), SIMD3(sx * 0.29, 0.08, 0.16 + kn), 0.06, 0.04, carapace))
                s.append(C(SIMD3(sx * 0.29, 0.08, 0.16 + kn), SIMD3(sx * 0.31, 0.02, -0.2 + kn), 0.045, 0.0, dark, 0.03))
                for c in 0..<2 { s.append(C(SIMD3(sx * 0.31, 0.04, -0.18 + kn), SIMD3(sx * 0.31 + Float(c) * 0.05, 0.0, -0.36 + kn), 0.02, 0.0, bone, 0.015)) }
            }
            // ── hunched, ribbed torso curving forward ──
            s.append(S(SIMD3(0, 0.92 + bob, 0.06), 0.16, carapace))                                   // pelvis
            s.append(C(SIMD3(0, 0.96 + bob, 0.08), SIMD3(0, 1.46 + bob, -0.18 - lunge * 0.4), 0.18, 0.15, carapace))
            for ri in 0..<4 {
                let y = 1.04 + Float(ri) * 0.12 + bob, z = -Float(ri) * 0.03
                for sx in [Float(-1), 1] { s.append(C(SIMD3(0, y, z - 0.1), SIMD3(sx * 0.16, y - 0.02, z + 0.04), 0.03, 0.012, dark, 0.02)) }
            }
            // ── dorsal back-pipes — sweep them BACK low over the spine, not up beside
            //    the head (where, head-on, they read as a teddy bear's ears) ──
            for sx in [Float(-1), 1] {
                s.append(C(SIMD3(sx * 0.1, 1.42 + bob, 0.14), SIMD3(sx * 0.17, 1.62 + bob, 0.72), 0.05, 0.03, dark, 0.03))
                s.append(C(SIMD3(sx * 0.2, 1.36 + bob, 0.14), SIMD3(sx * 0.29, 1.52 + bob, 0.66), 0.045, 0.026, dark, 0.03))
            }
            // ── MUSCULATURE ── corded masses fused over the frame (smooth-blend k
            //    melts them into the hide): trapezius cords into the neck, heavy
            //    deltoids, biceps bulges, pectoral plates and haunch quads — the
            //    drone reads as strung muscle under the chitin, not tubing.
            for sx in [Float(-1), 1] {
                s.append(C(SIMD3(sx * 0.16, 1.5 + bob, 0.06), SIMD3(0, 1.54 + bob, -0.16), 0.05, 0.03, carapace, 0.05))    // trapezius cord
                s.append(S(SIMD3(sx * 0.25, 1.45 + bob, -0.01), 0.1, carapace, 0.05))                                       // deltoid mass
                s.append(C(SIMD3(sx * 0.27, 1.4 + bob, -0.04), SIMD3(sx * 0.4, 1.1 + bob, -0.18), 0.075, 0.045, carapace, 0.05))   // biceps bulge
                s.append(C(SIMD3(sx * 0.05, 1.3 + bob, -0.14), SIMD3(sx * 0.19, 1.24 + bob, -0.1), 0.065, 0.05, carapace, 0.045))  // pectoral plate
                let kn = (sx > 0 ? g : -g) * 0.22
                s.append(C(SIMD3(sx * 0.16, 0.94 + bob, 0.1), SIMD3(sx * 0.27, 0.62, -0.02 + kn * 0.7), 0.105, 0.06, carapace, 0.05))  // haunch quad
            }
            // ── long spindly arms swinging to the floor, ending in raking claws ──
            for sx in [Float(-1), 1] {
                let sw = (sx > 0 ? -g : g) * 0.06           // arms counter-swing to the legs
                s.append(S(SIMD3(sx * 0.22, 1.44 + bob, 0.0), 0.08, carapace))
                let elbow = SIMD3(sx * 0.46, 0.9 + bob, -0.28 - lunge + sw)
                s.append(C(SIMD3(sx * 0.22, 1.44 + bob, 0.0), elbow, 0.05, 0.036, carapace))
                let wrist = SIMD3(sx * 0.48, 0.38, -0.46 - lunge + sw)
                s.append(C(elbow, wrist, 0.034, 0.024, carapace))
                // a bone spur juts back off each elbow; a sinew cord rides the forearm
                s.append(C(elbow, elbow + SIMD3(sx * 0.08, 0.1, 0.14), 0.02, 0.0, bone, 0.01))
                s.append(C(elbow + SIMD3(sx * 0.015, 0, -0.02), wrist + SIMD3(sx * 0.015, 0.04, 0), 0.014, 0.01, dark, 0.015))
                for f in 0..<4 { let o = Float(f) - 1.5; s.append(C(wrist, wrist + SIMD3(sx * 0.02 + o * 0.035, -0.22, -0.24), 0.016, 0.0, carapace, 0.012)) }
            }
            // ── neck + a long, low skull that THRUSTS forward at the prey ──
            s.append(C(SIMD3(0, 1.46 + bob, -0.14 - lunge), SIMD3(0, 1.5 + bob, -0.34 - lunge), 0.1, 0.1, carapace))   // neck
            // cranium = a low wedge driving forward, swept back into a crest (no dome)
            s.append(C(SIMD3(0, 1.5 + bob, -0.54 - lunge), SIMD3(0, 1.64 + bob, 0.6 - lunge * 0.5), 0.115, 0.04, carapace, 0.07))   // upper skull → crest (narrowed: no dome)
            s.append(C(SIMD3(0, 1.4 + bob, -0.64 - lunge), SIMD3(0, 1.5 + bob, 0.12 - lunge * 0.5), 0.09, 0.06, carapace, 0.05))    // lower skull, jutting forward
            // armored cheek plates sweep back from the muzzle — head-on the skull
            // reads as a narrow bladed wedge, not a smooth dome
            for sx in [Float(-1), 1] {
                s.append(C(SIMD3(sx * 0.055, 1.5 + bob, -0.5 - lunge), SIMD3(sx * 0.14, 1.42 + bob, -0.12 - lunge * 0.5), 0.045, 0.02, dark, 0.03))
            }
            s.append(C(SIMD3(0, 1.64 + bob, 0.42 - lunge * 0.5), SIMD3(0, 1.46 + bob, 1.12 - lunge * 0.5), 0.05, 0.0, carapace, 0.05))  // crest tip, swept back
            // a segmented sagittal crest — raised vertebral ridges down the skull, so
            // the head reads ribbed and predatory rather than a smooth shell
            for cr in 0..<4 { let z = -0.36 + Float(cr) * 0.22; s.append(S(SIMD3(0, 1.61 + bob - Float(cr) * 0.012, z - lunge * 0.5), 0.042 - Float(cr) * 0.006, carapace, 0.02)) }
            // a heavy brow jutting forward over deep, wide-set sockets — a permanent scowl
            s.append(C(SIMD3(-0.15, 1.48 + bob, -0.58 - lunge), SIMD3(0.15, 1.48 + bob, -0.58 - lunge), 0.05, 0.05, carapace, 0.02))   // brow bar
            for sx in [Float(-1), 1] { s.append(S(SIMD3(sx * 0.085, 1.43 + bob, -0.6 - lunge), 0.046, dark, 0.02)) }   // sunken sockets
            // ── a long lipless jaw + a wide GAPING maw, long interlocking fangs ──
            s.append(C(SIMD3(0, 1.42 + bob, -0.5 - lunge), SIMD3(0, 1.27 + bob, -0.84 - lunge), 0.105, 0.058, carapace))   // jaw, thrust forward-down
            let mawR = 0.085 + atk * 0.06
            let mawDeep = SIMD3<Float>(16, 4, 6)
            s.append(S(SIMD3(0, 1.34 + bob, -0.74 - lunge), mawR, mawDeep, 0.025))   // gaping mouth — near-black gullet, not a red ball
            // needle fangs: thinner, duller bone, interlocking — a trap, not a grin
            let fang = SIMD3<Float>(168, 156, 128)
            for tt in 0..<7 {
                let x = -0.075 + Float(tt) * 0.025
                s.append(C(SIMD3(x, 1.41 + bob, -0.76 - lunge), SIMD3(x * 1.15, 1.28 + bob, -0.83 - lunge), 0.011, 0.0, fang, 0.005))        // upper needle, curving in
                s.append(C(SIMD3(x + 0.012, 1.25 + bob, -0.8 - lunge), SIMD3(x + 0.012, 1.38 + bob, -0.85 - lunge), 0.009, 0.0, fang, 0.005))  // lower needle
            }
            // inner jaw — the xenomorph second mouth, lunges out on the strike
            let ij = -0.82 - lunge - atk * 0.2
            s.append(C(SIMD3(0, 1.34 + bob, -0.74 - lunge), SIMD3(0, 1.33 + bob, ij), 0.036, 0.024, maw, 0.02))
            for c in 0..<3 { let x = Float(c - 1) * 0.024; s.append(C(SIMD3(x, 1.34 + bob, ij), SIMD3(x, 1.32 + bob, ij - 0.06), 0.013, 0.0, bone, 0.007)) }
            // ── long segmented bladed tail sweeping back and up ──
            var tp = SIMD3<Float>(0, 0.92 + bob, 0.18)
            let pts = [SIMD3<Float>(0.12, 0.82, 0.6), SIMD3<Float>(0.28, 0.92, 0.98), SIMD3<Float>(0.4, 1.3, 1.12), SIMD3<Float>(0.5, 1.7, 1.0)]
            var rad: Float = 0.09
            for (i, np) in pts.enumerated() { let sw = SIMD3<Float>(g * 0.05 * Float(i), 0, 0); s.append(C(tp, np + sw, rad, rad * 0.7, carapace, 0.04)); tp = np + sw; rad *= 0.72 }
            s.append(C(tp, tp + SIMD3(0.04, 0.34, -0.08), 0.05, 0.0, bone, 0.02))   // blade barb
            return s
        }
    }

    // DRONE · LOW (alt) — same hide, slung low on four legs: a scaly hound that
    // reads instantly as "fast, coming at your knees" rather than a stooped biped.
    static func droneLow() -> CDef {
        let hide = SIMD3<Float>(70, 92, 68), dark = SIMD3<Float>(38, 52, 40), belly = SIMD3<Float>(118, 136, 108)
        let claw = SIMD3<Float>(196, 196, 168), eye = SIMD3<Float>(228, 150, 60), maw = SIMD3<Float>(24, 14, 14)
        return CDef(name: "DRONE · LOW", role: "ALT — QUADRUPED", blurb: "Same hide, slung low on four legs. Faster read.",
                    viewH: 1.7, groundY: -0.05) { ph, atk in
            let g = sin(ph * 4 * .pi) * 0.12, lunge = atk * 0.18
            var s = [Shape]()
            s.append(C(SIMD3(0, 0.56, 0.36), SIMD3(0, 0.5, -0.4 - lunge), 0.22, 0.14, hide))   // long body
            s.append(S(SIMD3(0, 0.46, 0.04), 0.18, belly, 0.2))
            let pos: [(Float, Float)] = [(-0.2, 0.3), (0.2, 0.3), (-0.2, -0.22), (0.2, -0.22)]
            let phs: [Float] = [g, -g, -g, g]
            for li in 0..<4 {
                let (lx, lz) = pos[li]
                s.append(C(SIMD3(lx, 0.52, lz), SIMD3(lx * 1.7, 0.46, lz + phs[li]), 0.06, 0.045, dark))
                s.append(C(SIMD3(lx * 1.7, 0.46, lz + phs[li]), SIMD3(lx * 1.8, 0.04, lz + phs[li] * 1.3), 0.045, 0.03, dark))
            }
            for sp in 0..<6 { let z = 0.34 - Float(sp) * 0.13; s.append(C(SIMD3(0, 0.66, z), SIMD3(0, 0.92, z - 0.04), 0.05, 0.0, dark, 0.04)) }   // scaly ridge
            s.append(S(SIMD3(0, 0.5, -0.5 - lunge), 0.15, hide))
            s.append(C(SIMD3(0, 0.46, -0.58 - lunge), SIMD3(0, 0.4, -0.78 - lunge), 0.1, 0.07, hide))
            s.append(S(SIMD3(0, 0.42, -0.72 - lunge), 0.06 + atk * 0.03, maw, 0.05))
            for tt in 0..<4 { let x = -0.045 + Float(tt) * 0.03; s.append(C(SIMD3(x, 0.45, -0.76 - lunge), SIMD3(x, 0.39, -0.78 - lunge), 0.013, 0.0, claw, 0.012)) }
            s.append(S(SIMD3(-0.06, 0.56, -0.6 - lunge), 0.03, eye, 0.03)); s.append(S(SIMD3(0.06, 0.56, -0.6 - lunge), 0.03, eye, 0.03))
            s.append(C(SIMD3(0, 0.54, 0.42), SIMD3(0, 0.5, 0.78), 0.07, 0.02, hide, 0.05))   // tail
            return s
        }
    }

    // QUEEN (primary) — bloated grey-brown brood-mother, low and wide, rooted to
    // her lair. Egg-heavy sac, a hunched head over a gaping maw, an eye cluster,
    // and a ring of slimy tentacles splaying out across the floor.
    static func queen() -> CDef {
        let carapace = SIMD3<Float>(46, 38, 30), dark = SIMD3<Float>(20, 16, 12)
        let crestC = SIMD3<Float>(58, 48, 38), bone = SIMD3<Float>(192, 184, 158)
        let maw = SIMD3<Float>(32, 8, 10), sac = SIMD3<Float>(66, 54, 42)
        return CDef(name: "QUEEN", role: "HIVE MOTHER", blurb: "Rooted brood-mother — a bulbous birthing sac, a writhing tentacle skirt, a crowned head. Plasma kills; fire ends her.",
                    viewH: 2.7, groundY: -0.05) { ph, atk in
            let g = sin(ph * 2 * .pi), breathe = sin(ph * 2 * .pi) * 0.04, lunge = atk * 0.2
            let hsway = sin(ph * 2 * .pi * 0.7) * 0.09          // idle head roving — rooted, but never still
            var s = [Shape]()
            // ── ROOTED BULBOUS EGG-SAC — her body AND base: wider than tall (volume,
            //    not height), a pulsing birthing mass planted on the floor. No legs. ──
            s.append(S(SIMD3(0, 0.6 + breathe, 0.22), 0.74, sac))                  // central mass
            s.append(S(SIMD3(0.52, 0.46 + breathe * 0.6, 0.3), 0.5, sac, 0.45))    // girth right
            s.append(S(SIMD3(-0.52, 0.46 + breathe * 0.6, 0.3), 0.5, sac, 0.45))   // girth left
            s.append(S(SIMD3(0, 0.46, 0.82), 0.56, sac, 0.45))                     // swollen rear
            s.append(S(SIMD3(0, 0.34, 1.32), 0.4, sac, 0.4))                       // ovipositor swell
            for k in 0..<7 { let a = Float(k) / 7 * 6.2832                          // translucent egg-nodes over the sac
                s.append(S(SIMD3(cos(a) * 0.58, 0.52 + breathe + sin(a * 1.7) * 0.12, 0.28 + sin(a) * 0.46), 0.12, dark, 0.3)) }
            // ── A WRITHING SKIRT OF TENTACLES splaying from the sac, each flailing
            //    on its own phase ──
            let nt = 11
            for k in 0..<nt {
                let a = Float(k) / Float(nt) * 6.2832
                let ph2 = ph * 2 * .pi + Float(k) * 0.83
                let writhe = sin(ph2), curl = cos(ph2 * 1.3)
                let base = SIMD3(cos(a) * 0.64, 0.16, 0.28 + sin(a) * 0.56)
                let mid  = base + SIMD3(cos(a) * 0.46 + writhe * 0.2, 0.24 + abs(curl) * 0.16, sin(a) * 0.46)
                let tip  = mid  + SIMD3(cos(a) * 0.42 + writhe * 0.32, 0.06 + curl * 0.24, sin(a) * 0.42)
                s.append(C(base, mid, 0.075, 0.05, carapace, 0.05))
                s.append(C(mid, tip, 0.05, 0.0, dark, 0.04))
            }
            // ── huge egg-sac abdomen trailing back and down ──
            s.append(S(SIMD3(0, 0.7 + breathe, 0.5), 0.42, sac))
            s.append(S(SIMD3(0, 0.56, 1.0), 0.4, sac, 0.3))
            s.append(S(SIMD3(0, 0.46, 1.5), 0.34, sac, 0.3))
            s.append(S(SIMD3(0, 0.4, 1.95), 0.26, sac, 0.3))
            for tt in 0..<5 { let x = -0.28 + Float(tt) * 0.14; let sw = sin(ph * 2 * .pi + Float(tt)) * 0.06
                s.append(C(SIMD3(x, 0.34, 1.9), SIMD3(x + sw, 0.04, 2.2 + sw), 0.05, 0.0, dark, 0.04)) }   // ovipositor tendrils
            // ── upper torso rising from the FRONT of the sac, forward-leaning, ribbed ──
            s.append(C(SIMD3(0, 0.78, -0.2), SIMD3(hsway * 0.5, 1.5, -0.42 - lunge * 0.3), 0.34, 0.22, carapace))
            for ri in 0..<3 { let y = 1.04 + Float(ri) * 0.16; for sx in [Float(-1), 1] { s.append(C(SIMD3(0, y, -0.36), SIMD3(sx * 0.3, y - 0.04, -0.12), 0.05, 0.02, dark, 0.02)) } }
            // ── two raised TENTACLE-ARMS that flail by the head, not rigid limbs ──
            for sx in [Float(-1), 1] {
                let ph3 = ph * 2 * .pi + (sx > 0 ? 0 : 3.0)
                let shoulder = SIMD3(sx * 0.4, 1.18, -0.2)
                let mid = SIMD3(sx * 0.64 + sin(ph3) * 0.2, 1.5 + cos(ph3) * 0.24, -0.34 - lunge * 0.4)
                let tip = SIMD3(sx * 0.72 + sin(ph3 * 1.4) * 0.36, 1.16 + sin(ph3) * 0.36, -0.66 - lunge)
                s.append(S(shoulder, 0.12, carapace))
                s.append(C(shoulder, mid, 0.09, 0.06, carapace, 0.05))
                s.append(C(mid, tip, 0.06, 0.02, dark, 0.04))
                for f in 0..<3 { let o = Float(f - 1); s.append(C(tip, tip + SIMD3(sx * 0.02 + o * 0.04, -0.14, -0.12), 0.02, 0.0, bone, 0.014)) }   // grasping claws
            }
            // ── long neck + elongated head thrust forward, swaying (rooted, but her
            //    head roves and snaps) ──
            let hx = hsway
            s.append(C(SIMD3(0, 1.5, -0.42 - lunge), SIMD3(hx, 1.56, -0.62 - lunge), 0.17, 0.13, carapace))
            s.append(S(SIMD3(hx, 1.54, -0.66 - lunge), 0.19, carapace))                                   // skull
            s.append(C(SIMD3(hx, 1.46, -0.66 - lunge), SIMD3(hx, 1.32, -1.04 - lunge), 0.14, 0.07, carapace))   // long jaw
            s.append(S(SIMD3(hx, 1.4, -0.96 - lunge), 0.1 + atk * 0.06, maw, 0.04))                        // gaping maw
            for tt in 0..<8 { let x = hx - 0.1 + Float(tt) * 0.026; s.append(C(SIMD3(x, 1.46, -0.98 - lunge), SIMD3(x, 1.34 - atk * 0.04, -1.02 - lunge), 0.014, 0.0, bone, 0.01)) }
            let ij = -1.02 - lunge - atk * 0.2                                                            // inner jaw
            s.append(C(SIMD3(hx, 1.4, -0.96 - lunge), SIMD3(hx, 1.39, ij), 0.04, 0.025, maw, 0.02))
            for c in 0..<3 { let x = hx + Float(c - 1) * 0.025; s.append(C(SIMD3(x, 1.4, ij), SIMD3(x, 1.38, ij - 0.06), 0.012, 0.0, bone, 0.01)) }
            // (no drool — strands hanging off the front of the face read as "snot",
            //  not menace; a dry fanged maw is more frightening)
            // ── THE CROWN CREST — a big flat shield, ribs fused into one plate,
            //    swept wide and back over the body (the Queen's signature) ──
            let cbase = SIMD3<Float>(hx, 1.66, -0.5 - lunge)
            for cr in 0..<9 {
                let f = Float(cr) / 8, xo = (f - 0.5) * 1.6            // spread ±0.8
                let tip = SIMD3(hx + xo, 2.0 + 0.42 * (1 - abs(f - 0.5) * 2) + g * 0.04, 0.2 - abs(xo) * 0.16)
                s.append(C(cbase + SIMD3(xo * 0.34, 0, 0), tip, 0.085, 0.025, crestC, 0.12))   // high k → fuses into a shield
            }
            for sx in [Float(-1), 1] { s.append(C(SIMD3(hx + sx * 0.16, 1.78, -0.48 - lunge), SIMD3(hx + sx * 0.42, 2.1, -0.34 - lunge), 0.05, 0.0, bone, 0.02)) }   // flanking horns
            // Rooted: no walk gait and no dragging tail — the mass is planted; only the
            // head, crown and the tentacle skirt/arms move (plus a slow breathing swell).
            return s
        }
    }

    // QUEEN · TALL (alt) — the same brood-mother reared up: a squat sac base, a
    // towering torso, a crested head presiding over the room, two raised tentacle
    // arms and a draping skirt of tentacles. Less "rooted", more "looms over you".
    static func queenTall() -> CDef {
        let hide = SIMD3<Float>(122, 102, 78), dark = SIMD3<Float>(76, 60, 44), sac = SIMD3<Float>(150, 130, 98)
        let tent = SIMD3<Float>(92, 74, 54), crest = SIMD3<Float>(60, 48, 36), eye = SIMD3<Float>(228, 120, 60), maw = SIMD3<Float>(26, 14, 12)
        return CDef(name: "QUEEN · TALL", role: "ALT — TOWERING", blurb: "Upright, crested, tentacle skirt. Presiding, not rooted.",
                    viewH: 3.0, groundY: -0.05) { ph, atk in
            let breathe = sin(ph * 2 * .pi) * 0.02, g = sin(ph * 2 * .pi)
            var s = [Shape]()
            // squat bloated base → tapering upright torso
            s.append(S(SIMD3(0, 0.7 + breathe, 0.04), 0.5, sac))
            s.append(S(SIMD3(0, 1.3 + breathe, 0.0), 0.42, hide, 0.3))
            s.append(S(SIMD3(0, 1.9 + breathe, -0.02), 0.34, hide, 0.28))
            for (mx, my, mz) in [(0.14, 1.4, 0.3), (-0.16, 1.1, 0.3), (0.0, 2.0, 0.2)] {
                s.append(S(SIMD3(Float(mx), Float(my), Float(mz)), 0.08, dark, 0.12))
            }
            // crested head + gaping maw + eye cluster
            s.append(S(SIMD3(0, 2.34, -0.08), 0.24, hide))
            for hx in stride(from: -0.2, through: 0.2, by: 0.1) {
                s.append(C(SIMD3(Float(hx), 2.5, 0.0), SIMD3(Float(hx) * 1.5, 2.92 + g * 0.04, 0.06), 0.05, 0.0, crest, 0.04))
            }
            s.append(S(SIMD3(0, 2.2, -0.28), 0.1 + atk * 0.04, maw, 0.06))
            for (ex, ey) in [(-0.09, 2.38), (0.09, 2.38), (0.0, 2.44), (-0.05, 2.3), (0.05, 2.3)] {
                s.append(S(SIMD3(Float(ex), Float(ey), -0.26), 0.028, eye, 0.03))
            }
            // two raised tentacle-arms
            for sx in [Float(-1), 1] {
                let sw = sin(ph * 2 * .pi + (sx > 0 ? 0 : 1.6)) * 0.12
                s.append(C(SIMD3(sx * 0.4, 1.9, -0.04), SIMD3(sx * (0.7 + atk * 0.2) + sw, 1.4, -0.2), 0.1, 0.05, tent, 0.05))
                s.append(C(SIMD3(sx * (0.7 + atk * 0.2) + sw, 1.4, -0.2), SIMD3(sx * 0.8 + sw * 1.6, 0.8, -0.3), 0.05, 0.02, tent, 0.04))
            }
            // draping skirt of tentacles from the lower sac
            for tt in 0..<8 {
                let a = Float(tt) / 8 * 2 * .pi
                let bx = cos(a) * 0.46, bz = sin(a) * 0.46
                let sw = sin(ph * 2 * .pi + Float(tt) * 0.9) * 0.1
                s.append(C(SIMD3(Float(bx), 0.66, Float(bz)), SIMD3(Float(bx) * 1.4 + sw, 0.05, Float(bz) * 1.4), 0.06, 0.02, tent, 0.05))
            }
            return s
        }
    }
}
