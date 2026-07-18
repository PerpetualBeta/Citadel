// Citadel — QUEEN hero-plate harness (dev builds only).
//
// Renders the in-game QUEEN as a title-screen candidate that is OURS: the
// game's own creature (CreatureLab.queen), so it honours the contract the
// title makes to the player AND carries no third-party IP. Same composition as
// the current plate — creature hard right, warm-rim-lit out of near-black, a
// clean gutter on the left for the type — but built from the SDF the player
// actually fights, then given the game's cinematic finish (HDR lighting →
// bloom → ACES → vignette → film grain).
//
//   CITADEL_QUEENHERO[=path]                 → ~/Desktop/citadel-queen-hero.png
//   CITADEL_QUEENHERO="yaw=-0.6 atk=0.4 ..." → tweak pose/framing without a code edit
//
// Knobs: yaw (turn), atk (maw gape), phase (breath), fx (creature centre across
// the plate, 0..1), glowx/glowy (furnace-glow centre). Then exit.

import Cocoa
import simd

enum QueenHero {
    static func run(outDir: String?) {
        // ── knobs (defaults chosen for a menacing 3/4 turn, facing the type) ──
        var yaw: Float = -0.62, atk: Float = 0.42, phase: Float = 0.17
        var fx: Float = 0.66, glowX: Float = 0.80, glowY: Float = 0.56
        var outPath = NSHomeDirectory() + "/Desktop/citadel-queen-hero.png"
        if let raw = outDir, !raw.isEmpty, raw != "1" {
            if raw.contains("=") {
                for tok in raw.split(whereSeparator: { $0 == " " || $0 == "," }) {
                    let kv = tok.split(separator: "=")
                    guard kv.count == 2, let val = Float(kv[1]) else { continue }
                    switch kv[0] {
                    case "yaw": yaw = val
                    case "atk": atk = val
                    case "phase": phase = val
                    case "fx": fx = val
                    case "glowx": glowX = val
                    case "glowy": glowY = val
                    default: break
                    }
                }
            } else { outPath = raw }
        }

        let W = 1280, H = 800
        let spanY: Float = 3.05                    // world height the plate spans
        let groundY: Float = -0.05
        let wpp = spanY / Float(H)                 // world units per pixel

        // ── build the queen, posed ──
        let shapes = CreatureLab.queen().build(phase, atk)
        let sy = sin(yaw), cy = cos(yaw)
        @inline(__always) func rot(_ p: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(p.x * cy - p.z * sy, p.y, p.x * sy + p.z * cy)
        }

        // creature-space AABB, then its world-space x/y bounds (rotated corners)
        // so we only march the rectangle she actually occupies — the gutter and
        // the sky above are pure background, never marched.
        var mn = SIMD3<Float>(repeating: 1e9), mx = SIMD3<Float>(repeating: -1e9)
        for s in shapes {
            let r = max(s.r1, s.r2)
            for pt in [s.a, s.b] { mn = simd_min(mn, pt - SIMD3(repeating: r)); mx = simd_max(mx, pt + SIMD3(repeating: r)) }
        }
        var wxMin: Float = 1e9, wxMax: Float = -1e9
        for xc in [mn.x, mx.x] { for zc in [mn.z, mx.z] {          // rot⁻¹ of the box corners (about Y)
            let wx = xc * cy + zc * sy
            wxMin = min(wxMin, wx); wxMax = max(wxMax, wx)
        } }
        let wyMin = mn.y, wyMax = mx.y

        // ── SDF (smin-blended soft volumes, sampled in creature space) ──
        func sdf(_ p0: SIMD3<Float>) -> (Float, SIMD3<Float>, Float) {
            let p = rot(p0)
            var d: Float = 1e9, c = SIMD3<Float>(0, 0, 0), em: Float = 0
            for s in shapes {
                let sd = s.dist(p)
                if d > 1e8 { d = sd; c = s.col; em = s.emissive; continue }
                let hh = max(0, min(1, 0.5 + 0.5 * (sd - d) / s.k))
                d = (sd * (1 - hh) + d * hh) - s.k * hh * (1 - hh)
                c = s.col * (1 - hh) + c * hh
                em = s.emissive * (1 - hh) + em * hh
            }
            return (d, c, em)
        }
        func nrm(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let e: Float = 0.0035
            let dx = sdf(p + SIMD3(e, 0, 0)).0 - sdf(p - SIMD3(e, 0, 0)).0
            let dy = sdf(p + SIMD3(0, e, 0)).0 - sdf(p - SIMD3(0, e, 0)).0
            let dz = sdf(p + SIMD3(0, 0, e)).0 - sdf(p - SIMD3(0, 0, e)).0
            return simd_normalize(SIMD3(dx, dy, dz))
        }

        // ── cinematic 3-point rig: warm key upper-left-front, a STRONG amber
        //    furnace rim from behind-right (the hero light), a dim cool fill ──
        let keyDir = simd_normalize(SIMD3<Float>(-0.45, 0.55, -0.75))
        let rimDir = simd_normalize(SIMD3<Float>(0.55, 0.42, 0.85))
        let fillDir = simd_normalize(SIMD3<Float>(0.70, -0.15, -0.55))
        let keyCol = SIMD3<Float>(1.00, 0.74, 0.45), keyI: Float = 0.85
        let rimCol = SIMD3<Float>(1.00, 0.60, 0.26), rimI: Float = 2.35
        let fillCol = SIMD3<Float>(0.34, 0.44, 0.52), fillI: Float = 0.22
        let ambient = SIMD3<Float>(0.055, 0.05, 0.05)
        let aaBand = wpp * 1.4

        // HDR accumulation buffers (linear, may exceed 1 for bloom)
        var hdr = [SIMD3<Float>](repeating: .zero, count: W * H)

        // 1) background plate: near-black warm + a furnace glow behind-right + haze
        @inline(__always) func hash2(_ x: Int, _ y: Int) -> Float {
            var h = UInt32(bitPattern: Int32(truncatingIfNeeded: x &* 73856093 ^ y &* 19349663))
            h = (h ^ (h >> 13)) &* 0x5bd1e995; h ^= h >> 15
            return Float(h & 0xFFFF) / 65535.0
        }
        let glowCol = SIMD3<Float>(1.00, 0.50, 0.18)
        let gcx = glowX * Float(W), gcy = glowY * Float(H), gsig = Float(W) * 0.34
        for j in 0..<H { for i in 0..<W {
            let dx = Float(i) - gcx, dy = Float(j) - gcy
            let g = expf(-(dx * dx + dy * dy) / (gsig * gsig))
            let haze = 0.6 + 0.4 * hash2(i >> 2, j >> 2)              // soft dust breakup
            let glowTerm = glowCol * (g * 0.55 * haze)
            let bgBase = SIMD3<Float>(0.020, 0.017, 0.014)
            hdr[j * W + i] = bgBase + glowTerm
        } }

        // 2) march the creature within her world bbox and composite over the plate
        let iMin = max(0, Int((wxMin) / wpp + Float(W) * fx) - 2)
        let iMax = min(W - 1, Int((wxMax) / wpp + Float(W) * fx) + 2)
        let jMin = max(0, Int(Float(H) - (wyMax - groundY) / wpp) - 2)
        let jMax = min(H - 1, Int(Float(H) - (wyMin - groundY) / wpp) + 2)
        for j in jMin...jMax {
            let wy = groundY + (Float(H) - (Float(j) + 0.5)) * wpp
            for i in iMin...iMax {
                let wx = (Float(i) + 0.5 - Float(W) * fx) * wpp
                var t: Float = 0, hit = false, minD: Float = 1e9, p = SIMD3<Float>(wx, wy, -4)
                for _ in 0..<64 {
                    p = SIMD3(wx, wy, -4 + t)
                    let d = sdf(p).0
                    if d < 0.003 { hit = true; break }
                    if d < minD { minD = d }
                    t += max(d * 0.85, 0.007)
                    if t > 8 { break }
                }
                let idx = j * W + i
                if !hit {
                    // silhouette feather: darken the plate slightly where she nearly
                    // grazes, so the edge reads crisp against the glow (soft AA).
                    let e = max(0, 1 - minD / aaBand)
                    if e > 0.02 { hdr[idx] = hdr[idx] * (1 - 0.85 * e) }
                    continue
                }
                let hitv = sdf(p)
                let n = nrm(p)
                let base = hitv.1 / 255.0
                let emis = hitv.2
                // pebbled micro-relief (shading only) so the hide isn't smooth pudding
                let rp = rot(p)
                let bump = SIMD3<Float>(sinf(rp.x * 39 + rp.y * 27), sinf(rp.y * 41 + rp.z * 31), sinf(rp.z * 37 + rp.x * 23))
                let nb = simd_normalize(n + bump * 0.12)
                let fres = powf(1 - min(1, abs(nb.z)), 2.2)
                let diff = max(0, simd_dot(nb, keyDir))
                let rim = powf(max(0, simd_dot(nb, rimDir)), 2.0) * (0.35 + 0.65 * fres)
                let fill = max(0, simd_dot(nb, fillDir))
                let half = simd_normalize(keyDir + SIMD3<Float>(0, 0, -1))
                let nh = max(0, simd_dot(nb, half))
                let spec = powf(nh, 22) * 0.5 + powf(nh, 90) * 1.4        // wet double-glint
                // Decomposed into single-operator SIMD steps — a fused expression here
                // sends Swift's overloaded-operator type-checker exponential.
                let keyTerm = keyCol * (diff * keyI)
                let fillTerm = fillCol * (fill * fillI)
                var lit = ambient + keyTerm
                lit = lit + fillTerm
                var col = base * lit
                let rimTerm = rimCol * (rim * rimI)                       // the hero rim
                col = col + rimTerm
                let specCol = SIMD3<Float>(1.0, 0.85, 0.6)
                col = col + specCol * (spec * 1.1)                        // warm wet sheen
                col = col + base * emis                                   // self-lit amber ova (glow → bloom)
                hdr[idx] = col
            }
        }

        // 3) bloom: bright-pass → blur at 1/4 res → add back (cheap, filmic)
        let bw = W / 4, bh = H / 4
        var bright = [SIMD3<Float>](repeating: .zero, count: bw * bh)
        for j in 0..<bh { for i in 0..<bw {
            var acc = SIMD3<Float>.zero
            for oy in 0..<4 { for ox in 0..<4 { acc += hdr[(j * 4 + oy) * W + (i * 4 + ox)] } }
            acc /= 16
            let l = acc.x * 0.2126 + acc.y * 0.7152 + acc.z * 0.0722
            if l > 0.7 {
                bright[j * bw + i] = acc * min(1, (l - 0.7) * 1.6)
            } else {
                bright[j * bw + i] = SIMD3<Float>.zero
            }
        } }
        func blur(_ src: [SIMD3<Float>], _ w: Int, _ h: Int, _ r: Int) -> [SIMD3<Float>] {
            var tmp = [SIMD3<Float>](repeating: .zero, count: w * h)
            var out = [SIMD3<Float>](repeating: .zero, count: w * h)
            let inv = 1 / Float(2 * r + 1)
            for j in 0..<h { for i in 0..<w {
                var a = SIMD3<Float>.zero
                for k in -r...r { a += src[j * w + min(w - 1, max(0, i + k))] }
                tmp[j * w + i] = a * inv
            } }
            for j in 0..<h { for i in 0..<w {
                var a = SIMD3<Float>.zero
                for k in -r...r { a += tmp[min(h - 1, max(0, j + k)) * w + i] }
                out[j * w + i] = a * inv
            } }
            return out
        }
        let bloom = blur(blur(bright, bw, bh, 9), bw, bh, 9)
        @inline(__always) func bloomAt(_ i: Int, _ j: Int) -> SIMD3<Float> {   // bilinear upsample
            let fxp = Float(i) / 4, fyp = Float(j) / 4
            let x0 = min(bw - 1, Int(fxp)), y0 = min(bh - 1, Int(fyp))
            let x1 = min(bw - 1, x0 + 1), y1 = min(bh - 1, y0 + 1)
            let tx = fxp - Float(x0), ty = fyp - Float(y0)
            let a0 = bloom[y0 * bw + x0] * (1 - tx)
            let a1 = bloom[y0 * bw + x1] * tx
            let b0 = bloom[y1 * bw + x0] * (1 - tx)
            let b1 = bloom[y1 * bw + x1] * tx
            let a = a0 + a1
            let b = b0 + b1
            let top = a * (1 - ty)
            let bot = b * ty
            return top + bot
        }

        // 4) tonemap (ACES) + vignette + subtle film grain → 8-bit
        @inline(__always) func aces(_ x: Float) -> Float {
            let a: Float = 2.51, b: Float = 0.03, c: Float = 2.43, d: Float = 0.59, e: Float = 0.14
            return max(0, min(1, (x * (a * x + b)) / (x * (c * x + d) + e)))
        }
        let cv = Canvas2D(width: W, height: H)
        let cxp = Float(W) * 0.5, cyp = Float(H) * 0.5, vmax = cxp * cxp + cyp * cyp
        let exposure: Float = 1.15
        for j in 0..<H { for i in 0..<W {
            let bl = bloomAt(i, j) * 0.9
            var c = hdr[j * W + i] + bl
            c = c * exposure
            // vignette
            let vx = Float(i) - cxp, vy = Float(j) - cyp
            let vig = 1 - 0.42 * powf((vx * vx + vy * vy) / vmax, 1.3)
            c = c * max(0, vig)
            // coarse, subtle film grain (a still — no boil)
            let n = (hash2(i >> 1, j >> 1) - 0.5) * 0.055
            let r = aces(c.x) + n, g = aces(c.y) + n, b = aces(c.z) + n
            let ri = min(255, max(0, Int(r * 255)))
            let gi = min(255, max(0, Int(g * 255)))
            let bi = min(255, max(0, Int(b * 255)))
            cv.framebuffer[j * W + i] = packRGBA(ri, gi, bi, 255)
        } }

        Captures.writePNG(cv.framebuffer, w: W, h: H, scale: 1, to: URL(fileURLWithPath: outPath))
        print("Citadel: wrote QUEEN hero candidate to \(outPath)  [yaw=\(yaw) atk=\(atk) fx=\(fx)]")
    }
}
