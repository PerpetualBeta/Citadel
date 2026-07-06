// Citadel — raymarched beauty proof (CITADEL_BEAUTY).
//
// NOT shipping yet — a TARGET-LOOK study. This is the same signed-distance-field
// scene and lighting model we would run per-pixel in a Metal fragment shader at
// 60fps, evaluated offline on the CPU here so the aesthetic can be judged BEFORE
// committing to the real-time port. Proving the look first de-risks the rewrite.
//
// Everything is procedural — zero asset files, the Jorvik hook turned into the
// reason it looks good:
//   • the corridor is an SDF (planes + boxes + pipes), materials are noise
//     (rust, grime, wet-floor variance) with procedural normal detail;
//   • the creature is the EXISTING CreatureLab SDF rendered NATIVELY — no sprite
//     bake, true volumetric flesh, lit per-pixel and casting a real soft shadow;
//   • per-pixel lighting with IQ soft shadows, SDF ambient occlusion, one-bounce
//     wet-floor reflections, raymarched volumetric god-rays, bloom and an ACES
//     filmic tonemap with a teal/amber grade.
//
// Output: ~/Desktop/Citadel-Beauty/

import Foundation
import simd

enum BeautyProof {
    typealias V3 = SIMD3<Float>

    // ── small math helpers (explicit, to avoid Float/Double overload surprises)
    @inline(__always) static func pf(_ a: Float, _ b: Float) -> Float { powf(a, b) }
    @inline(__always) static func ef(_ x: Float) -> Float { expf(x) }
    @inline(__always) static func fl(_ v: Float) -> Float { v.rounded(.down) }
    @inline(__always) static func fr(_ v: Float) -> Float { v - v.rounded(.down) }
    @inline(__always) static func cl01(_ v: Float) -> Float { min(1, max(0, v)) }
    @inline(__always) static func mixf(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
    @inline(__always) static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = cl01((x - a) / (b - a)); return t * t * (3 - 2 * t)
    }
    @inline(__always) static func mix3(_ a: V3, _ b: V3, _ t: Float) -> V3 { a + (b - a) * t }
    @inline(__always) static func sat3(_ v: V3) -> V3 { V3(cl01(v.x), cl01(v.y), cl01(v.z)) }
    @inline(__always) static func abs3(_ v: V3) -> V3 { V3(abs(v.x), abs(v.y), abs(v.z)) }
    @inline(__always) static func max0(_ v: V3) -> V3 { V3(max(0, v.x), max(0, v.y), max(0, v.z)) }
    @inline(__always) static func fr3(_ v: V3) -> V3 { V3(fr(v.x), fr(v.y), fr(v.z)) }

    // ── procedural noise ──────────────────────────────────────────────────────
    @inline(__always) static func hash31(_ p: V3) -> Float {
        var p3 = fr3(p * 0.1031)
        p3 += simd_dot(p3, V3(p3.y, p3.z, p3.x) + 33.33)
        return fr((p3.x + p3.y) * p3.z)
    }
    static func vnoise(_ x: V3) -> Float {
        let i = V3(fl(x.x), fl(x.y), fl(x.z)), f = x - i
        let u = f * f * (3 - 2 * f)
        func h(_ a: Float, _ b: Float, _ c: Float) -> Float { hash31(i + V3(a, b, c)) }
        let x00 = mixf(h(0,0,0), h(1,0,0), u.x), x10 = mixf(h(0,1,0), h(1,1,0), u.x)
        let x01 = mixf(h(0,0,1), h(1,0,1), u.x), x11 = mixf(h(0,1,1), h(1,1,1), u.x)
        return mixf(mixf(x00, x10, u.y), mixf(x01, x11, u.y), u.z)
    }
    static func fbm(_ p0: V3, _ oct: Int = 5) -> Float {
        var p = p0, a: Float = 0.5, s: Float = 0
        for _ in 0..<oct { s += a * vnoise(p); p *= 2.03; a *= 0.5 }
        return s
    }

    // ── SDF primitives ──────────────────────────────────────────────────────
    @inline(__always) static func sdBox(_ p: V3, _ b: V3) -> Float {
        let q = abs3(p) - b
        return simd_length(max0(q)) + min(max(q.x, max(q.y, q.z)), 0)
    }

    // ── the creature (native SDF — no sprite bake) ──────────────────────────
    static var creature: [CreatureLab.Shape] = []
    static let creaturePos = V3(0.62, 0, 7.4)
    static let creatureYaw: Float = 0.55

    static func creatureSDF(_ p: V3) -> (Float, V3) {
        var lp = p - creaturePos
        let s = sin(creatureYaw), c = cos(creatureYaw)
        lp = V3(lp.x * c - lp.z * s, lp.y, lp.x * s + lp.z * c)
        let bnd = simd_length(lp - V3(0, 1.15, 0)) - 1.75      // bounding sphere → cheap skip
        if bnd > 0.25 { return (bnd, V3(0.45, 0.18, 0.15)) }
        var d: Float = 1e9, col = V3(0.45, 0.18, 0.15)
        for sh in creature {
            let sd = sh.dist(lp)
            if d > 1e8 { d = sd; col = sh.col / 255; continue }
            let k = sh.k
            let hh = cl01(0.5 + 0.5 * (sd - d) / k)
            d = mixf(sd, d, hh) - k * hh * (1 - hh)
            col = mix3(sh.col / 255, col, hh)
        }
        return (d, col)
    }

    // ── the scene SDF: (distance, materialID) ────────────────────────────────
    // 0 wet floor · 1 ceiling · 2 iron wall · 3 lamp housing(emissive) ·
    // 4 teal panel(emissive) · 5 pipe · 6 creature flesh
    static func map(_ p: V3) -> (Float, Int) {
        var d = p.y; var mat = 0                                   // floor
        let dc = 3.4 - p.y; if dc < d { d = dc; mat = 1 }          // ceiling
        let dwl = p.x + 2.75; if dwl < d { d = dwl; mat = 2 }      // left wall
        let dwr = 2.75 - p.x; if dwr < d { d = dwr; mat = 2 }      // right wall
        let dfar = 27 - p.z; if dfar < d { d = dfar; mat = 2 }     // far backdrop

        // vertical wall ribs / pilasters, repeated every 4 in z
        let zr = p.z - 4 * (p.z / 4).rounded()
        let rib = sdBox(V3(abs(p.x) - 2.62, p.y - 1.7, zr), V3(0.16, 1.7, 0.32))
        if rib < d { d = rib; mat = 2 }

        // ceiling lamp housings (emissive), every 6 in z
        let zl = p.z - 6 * ((p.z - 0) / 6).rounded()
        let lamp = sdBox(V3(p.x, p.y - 3.33, zl), V3(0.55, 0.1, 0.55))
        if lamp < d { d = lamp; mat = 3 }

        // teal emergency panels set into the walls, every 6 in z (offset)
        let zp = p.z - 6 * ((p.z - 3) / 6).rounded()
        let panL = sdBox(V3(p.x + 2.68, p.y - 1.9, zp - 3), V3(0.04, 0.55, 0.1))
        if panL < d { d = panL; mat = 4 }
        let panR = sdBox(V3(p.x - 2.68, p.y - 1.35, zp - 3), V3(0.04, 0.55, 0.1))
        if panR < d { d = panR; mat = 4 }

        // pipework running the top corners (infinite in z)
        let pipeL = simd_length(SIMD2<Float>(p.x + 2.4, p.y - 3.0)) - 0.13
        if pipeL < d { d = pipeL; mat = 5 }
        let pipeR = simd_length(SIMD2<Float>(p.x - 2.4, p.y - 3.1)) - 0.1
        if pipeR < d { d = pipeR; mat = 5 }

        let cd = creatureSDF(p).0
        if cd < d { d = cd; mat = 6 }
        return (d, mat)
    }

    static func calcNormal(_ p: V3) -> V3 {
        let e: Float = 0.0015
        let dx = map(p + V3(e,0,0)).0 - map(p - V3(e,0,0)).0
        let dy = map(p + V3(0,e,0)).0 - map(p - V3(0,e,0)).0
        let dz = map(p + V3(0,0,e)).0 - map(p - V3(0,0,e)).0
        return simd_normalize(V3(dx, dy, dz))
    }

    // procedural surface detail: nudge the normal along the gradient of noise so
    // walls get rivets/grain and the wet floor gets micro-ripples that catch light
    static func bumped(_ p: V3, _ n: V3, _ mat: Int) -> V3 {
        guard mat == 0 || mat == 2 else { return n }
        let scale: Float = mat == 0 ? 2.2 : 2.6
        let amt: Float = mat == 0 ? 0.09 : 0.16
        let e: Float = 0.09
        let g = V3(fbm((p + V3(e,0,0)) * scale, 3) - fbm((p - V3(e,0,0)) * scale, 3),
                   fbm((p + V3(0,e,0)) * scale, 3) - fbm((p - V3(0,e,0)) * scale, 3),
                   fbm((p + V3(0,0,e)) * scale, 3) - fbm((p - V3(0,0,e)) * scale, 3)) / (2 * e)
        let gt = g - n * simd_dot(g, n)
        return simd_normalize(n - amt * gt)
    }

    static func march(_ ro: V3, _ rd: V3, _ maxT: Float = 70) -> (Float, Int) {
        var t: Float = 0.03
        for _ in 0..<170 {
            let (d, m) = map(ro + rd * t)
            if d < 0.0007 * t { return (t, m) }
            t += d * 0.9
            if t > maxT { break }
        }
        return (-1, -1)
    }

    static func softShadow(_ ro: V3, _ rd: V3, _ maxt: Float, _ k: Float) -> Float {
        var res: Float = 1, t: Float = 0.03, i = 0
        while t < maxt && i < 42 {
            let h = map(ro + rd * t).0
            if h < 0.0008 { return 0 }
            res = min(res, k * h / t)
            t += max(0.014, h)
            i += 1
        }
        return cl01(res)
    }

    // a much coarser shadow used inside the volumetric march (hot O(steps²) path)
    static func volShadow(_ ro: V3, _ rd: V3, _ maxt: Float) -> Float {
        var res: Float = 1, t: Float = 0.1, i = 0
        while t < maxt && i < 14 {
            let h = map(ro + rd * t).0
            if h < 0.02 { return 0 }
            res = min(res, 11 * h / t)
            t += max(0.09, h * 1.3)
            i += 1
        }
        return cl01(res)
    }

    static func calcAO(_ p: V3, _ n: V3) -> Float {
        var occ: Float = 0, sca: Float = 1
        for i in 0..<5 {
            let h = 0.02 + 0.12 * Float(i)
            occ += (h - map(p + n * h).0) * sca
            sca *= 0.9
        }
        return cl01(1 - 1.8 * occ)
    }

    struct Light { var pos: V3; var col: V3; var power: Float; var shadow: Bool }
    static let lights: [Light] = [
        Light(pos: V3(0.0, 3.15, 6.0), col: V3(1.0, 0.74, 0.45), power: 30, shadow: true),   // warm key
        Light(pos: V3(0.3, 2.7, 13.0), col: V3(1.0, 0.72, 0.42), power: 18, shadow: true),   // warm deep
        Light(pos: V3(-2.6, 1.9, 3.0), col: V3(0.10, 0.85, 0.78), power: 6, shadow: false),  // teal L
        Light(pos: V3(2.6, 1.35, 9.0), col: V3(0.10, 0.85, 0.78), power: 5, shadow: false),  // teal R
        Light(pos: V3(0.0, 1.4, 24.0), col: V3(1.0, 0.16, 0.10), power: 14, shadow: false),  // red emergency
    ]

    static func material(_ mat: Int, _ p: V3) -> (alb: V3, rough: Float, metal: Float, emis: V3) {
        switch mat {
        case 0:
            let grime = fbm(p * 1.3, 4)
            let alb = mix3(V3(0.028,0.032,0.038), V3(0.06,0.055,0.05), grime)
            let wet = cl01(0.55 + 0.6 * fbm(p * 0.6 + V3(10,0,0), 4))
            return (alb, mixf(0.05, 0.34, 1 - wet), 0.88, V3(0,0,0))
        case 1:
            return (V3(0.045,0.045,0.055), 0.72, 0.2, V3(0,0,0))
        case 2:
            let grain = fbm(p * 2.1, 4)
            let rust = cl01(fbm(p * 0.55 + V3(0,3,0), 4) * 1.5 - 0.45)
            var alb = mix3(V3(0.12,0.12,0.125), V3(0.19,0.17,0.15), grain)
            alb = mix3(alb, V3(0.22,0.11,0.05), rust * 0.45)
            return (alb, mixf(0.42, 0.72, grain), 0.5, V3(0,0,0))
        case 3:
            return (V3(0.2,0.2,0.2), 0.4, 0.1, V3(4.0, 2.7, 1.5))
        case 4:
            return (V3(0.04,0.09,0.09), 0.3, 0.2, V3(0.2, 3.2, 2.7))
        case 5:
            return (V3(0.15,0.15,0.17), 0.26, 0.8, V3(0,0,0))
        default:
            return (creatureSDF(p).1, 0.74, 0.0, V3(0,0,0))
        }
    }

    static func shade(_ p: V3, _ n: V3, _ rd: V3, _ mat: Int, allowRefl: Bool) -> V3 {
        let m = material(mat, p)
        let V = -rd
        let ao = calcAO(p, n)
        var col = m.emis
        // hemisphere ambient (cool sky / warm bounce), occluded
        let amb = mix3(V3(0.018,0.022,0.03), V3(0.05,0.045,0.04), 0.5 + 0.5 * n.y)
        col += m.alb * amb * ao
        let f0 = mix3(V3(0.04,0.04,0.04), m.alb, m.metal)
        for L in lights {
            let toL = L.pos - p
            let dist = simd_length(toL)
            let Ld = toL / dist
            let atten = L.power / (1 + dist * dist * 0.22)
            var sh: Float = 1
            if L.shadow { sh = softShadow(p + n * 0.02, Ld, dist - 0.1, 14) }
            if sh <= 0.001 { continue }
            let ndl = max(0, simd_dot(n, Ld))
            let diff = m.alb * (1 - m.metal) * ndl
            let H = simd_normalize(Ld + V)
            let ndh = max(0, simd_dot(n, H))
            let specPow = mixf(8, 340, pf(1 - m.rough, 1.4))
            let fres = f0 + (V3(1,1,1) - f0) * pf(1 - max(0, simd_dot(H, V)), 5)
            let spec = fres * (pf(ndh, specPow) * (specPow + 8) / 25)
            col += (diff + spec) * L.col * (atten * sh)
            if mat == 6 {                                   // fleshy backscatter (subsurface-ish)
                let back = pf(max(0, simd_dot(V, -Ld)), 2) * 0.5
                col += m.alb * back * L.col * (atten * sh * ao)
            }
        }
        // one-bounce reflection on smooth surfaces (wet floor, pipes)
        if allowRefl && m.rough < 0.34 {
            let R = rd - 2 * simd_dot(rd, n) * n
            let (rt, rm) = march(p + n * 0.03, R, 45)
            var refl: V3
            if rt > 0 {
                let rp = p + n * 0.03 + R * rt
                refl = shade(rp, calcNormal(rp), R, rm, allowRefl: false)
            } else {
                refl = background(R)
            }
            let fr = mixf(0.025, 1, pf(1 - max(0, simd_dot(n, V)), 5))
            col = mix3(col, refl, fr * cl01(1 - m.rough * 2.6))
        }
        return col
    }

    static func background(_ rd: V3) -> V3 {
        let h = cl01(rd.y * 0.5 + 0.5)
        return mix3(V3(0.012,0.016,0.024), V3(0.02,0.03,0.045), h)
    }

    // raymarched volumetric in-scattering — god-rays under the lamps + haze.
    // The key lamp casts a (coarse) volumetric shadow for the beams; the deeper
    // lamp + red glow add unshadowed in-scatter cheaply.
    static func volumetric(_ ro: V3, _ rd: V3, _ tmax: Float, _ jitter: Float) -> V3 {
        let steps = 30
        let far = min(tmax, 34)
        let dt = far / Float(steps)
        var t = dt * (0.3 + 0.7 * jitter)
        var acc = V3(0,0,0)
        var trans: Float = 1
        let key = lights[0], deep = lights[1], red = lights[4]
        for _ in 0..<steps {
            let p = ro + rd * t
            var dens: Float = 0.0035
            dens += 0.025 * smooth(0.0, 1.0, fbm(p * 0.55 + V3(0, 0, 4), 3)) * smooth(2.2, 0.4, p.y)
            if dens > 0.0005 {
                let toK = key.pos - p, dK = simd_length(toK)
                var g = key.col * (key.power / (1 + dK * dK * 0.22) * volShadow(p, toK / dK, dK - 0.1))
                let dD = simd_length(deep.pos - p)
                g += deep.col * (deep.power / (1 + dD * dD * 0.22) * 0.6)
                let dR = simd_length(red.pos - p)
                g += red.col * (red.power / (1 + dR * dR * 0.22) * 0.5)
                acc += g * (dens * dt * trans)              // this step's in-scatter
                trans *= ef(-dens * dt * 1.4)
                if trans < 0.02 { break }
            }
            t += dt
        }
        return acc * 0.3
    }

    static func render(_ ro: V3, _ rd: V3, _ jitter: Float) -> V3 {
        let (t, mat) = march(ro, rd)
        var col: V3
        if t > 0 {
            let p = ro + rd * t
            let n = bumped(p, calcNormal(p), mat)
            col = shade(p, n, rd, mat, allowRefl: true)
            let fog = 1 - ef(-t * 0.010)                    // aerial perspective
            col = mix3(col, V3(0.02,0.028,0.04), fog * 0.4)
        } else {
            col = background(rd)
        }
        col += volumetric(ro, rd, t > 0 ? t : 34, jitter)
        return col
    }

    // ── tonemap / grade ──────────────────────────────────────────────────────
    static func aces(_ x: V3) -> V3 {
        let a: Float = 2.51, b: Float = 0.03, c: Float = 2.43, d: Float = 0.59, e: Float = 0.14
        return sat3((x * (a * x + b)) / (x * (c * x + d) + e))
    }

    // ── render a single hero shot ────────────────────────────────────────────
    static func renderShot(_ name: String, ro: V3, ta: V3, fovDeg: Float,
                           w: Int, h: Int, ss: Int, dir: URL) {
        let aspect = Float(w) / Float(h)
        let f = simd_normalize(ta - ro)
        let r = simd_normalize(simd_cross(f, V3(0,1,0)))
        let u = simd_cross(r, f)
        let tanF = tan(fovDeg * .pi / 180 * 0.5)

        var hdr = [V3](repeating: .zero, count: w * h)
        hdr.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: h) { j in
                for i in 0..<w {
                    var c = V3(0,0,0)
                    for sy in 0..<ss { for sx in 0..<ss {
                        let px = (Float(i) + (Float(sx) + 0.5) / Float(ss)) / Float(w) * 2 - 1
                        let py = (Float(j) + (Float(sy) + 0.5) / Float(ss)) / Float(h) * 2 - 1
                        let rd = simd_normalize(f + r * (px * aspect * tanF) + u * (-py * tanF))
                        let jit = hash31(V3(Float(i), Float(j), Float(sy * ss + sx)))
                        c += render(ro, rd, jit)
                    } }
                    buf[j * w + i] = c / Float(ss * ss)
                }
            }
        }

        // bloom: bright-pass → separable blur (3 widening box passes ≈ gaussian)
        var bright = [V3](repeating: .zero, count: w * h)
        for idx in 0..<(w * h) {
            let c = hdr[idx]
            bright[idx] = max0(c - V3(1.5, 1.5, 1.5))
        }
        for radius in [3, 6, 10] { boxBlur(&bright, w, h, radius) }
        for idx in 0..<(w * h) { hdr[idx] += bright[idx] * 0.32 }

        // tonemap + grade + vignette → 8-bit RGBA
        let out = UnsafeMutablePointer<UInt32>.allocate(capacity: w * h)
        defer { out.deallocate() }
        for j in 0..<h { for i in 0..<w {
            var c = hdr[j * w + i]
            // gentle teal/amber grade: lift shadows cool, warm the highlights
            let lum = simd_dot(c, V3(0.299, 0.587, 0.114))
            c = mix3(c * V3(0.92, 0.98, 1.06), c * V3(1.08, 1.0, 0.9), cl01(lum))
            var m = aces(c * 1.05)
            // gamma to sRGB-ish
            m = V3(pf(m.x, 1/2.2), pf(m.y, 1/2.2), pf(m.z, 1/2.2))
            // vignette
            let nx = Float(i) / Float(w) * 2 - 1, ny = Float(j) / Float(h) * 2 - 1
            let vig = 1 - 0.32 * (nx * nx + ny * ny)
            m *= vig
            let r8 = UInt32(min(255, max(0, Int(m.x * 255))))
            let g8 = UInt32(min(255, max(0, Int(m.y * 255))))
            let b8 = UInt32(min(255, max(0, Int(m.z * 255))))
            out[j * w + i] = 0xFF00_0000 | (b8 << 16) | (g8 << 8) | r8
        } }
        Captures.writePNG(out, w: w, h: h, scale: 1, to: dir.appendingPathComponent(name))
        print("  wrote \(name)")
    }

    static func boxBlur(_ buf: inout [V3], _ w: Int, _ h: Int, _ rad: Int) {
        var tmp = buf
        let inv = 1 / Float(2 * rad + 1)
        // horizontal
        for j in 0..<h {
            let base = j * w
            for i in 0..<w {
                var s = V3(0,0,0)
                for k in -rad...rad { s += buf[base + min(w - 1, max(0, i + k))] }
                tmp[base + i] = s * inv
            }
        }
        // vertical
        for i in 0..<w {
            for j in 0..<h {
                var s = V3(0,0,0)
                for k in -rad...rad { s += tmp[min(h - 1, max(0, j + k)) * w + i] }
                buf[j * w + i] = s * inv
            }
        }
    }

    static func run(outDir: String?) {
        creature = CreatureLab.mauler().build(0, 0)
        let dir = URL(fileURLWithPath: outDir ?? NSHomeDirectory() + "/Desktop/Citadel-Beauty")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        print("Citadel: rendering raymarched beauty proof (this is offline — minutes, not frames)…")

        // Hero: down the corridor, the Mauler standing in the warm lamp pool.
        renderShot("01-corridor-hero.png", ro: V3(-0.5, 1.62, 0.4), ta: V3(0.35, 1.15, 8),
                   fovDeg: 64, w: 1024, h: 640, ss: 2, dir: dir)
        // Creature close: low angle, rim-lit, wet floor reflection beneath it.
        renderShot("02-mauler-closeup.png", ro: V3(-0.4, 0.95, 4.7), ta: V3(0.62, 1.05, 7.4),
                   fovDeg: 52, w: 960, h: 720, ss: 2, dir: dir)
        // Atmosphere: looking deep down the hall — god-rays, haze, red glow.
        renderShot("03-depth-atmosphere.png", ro: V3(0.0, 1.7, 1.0), ta: V3(0.05, 1.5, 16),
                   fovDeg: 70, w: 1024, h: 576, ss: 2, dir: dir)

        print("Citadel: beauty proof written to \(dir.path)")
    }
}
