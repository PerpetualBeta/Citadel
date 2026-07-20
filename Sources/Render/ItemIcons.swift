// Citadel — dossier pickup icons, rendered from the ACTUAL in-world geometry.
//
// The Field Intel codex used to show the low-poly MeshItems sprites, but the game
// renders pickups as SDF objects in the raymarch kernel (GPURaymarch.itemShapes)
// — a white auto-injector with a GREEN cross, a brass-banded mine crate with its
// trigger lamp, a cyan-ringed cell — which look nothing like the little boxes the
// codex was drawing. So the codex now renders its icons from those SAME shapes,
// with a compact CPU sphere-tracer, so it can never drift from what the marine
// actually picks up. One 3/4 hero bust per kind, warmed once at launch, cached.
//
// The SDF math mirrors the kernel's shapeDist (sdRoundCone / rounded box / flat-
// cap cylinders / sphere) exactly — same primitives, same encodings — so the icon
// is the pickup, not a re-drawing of it.

import Foundation
import simd

enum ItemIcons {
    typealias GShape = GPURaymarch.GShape

    private static let lock = NSLock()
    private static var cache: [Int: Sprite] = [:]
    private static var wcache: [Int: Sprite] = [:]

    /// The three carried weapons, drawn from their ACTUAL first-person viewmodel
    /// geometry (Viewmodel.swift) — the same SDF the marine sees in her hands.
    private static func weaponShapes(_ wk: WeaponKind) -> [GShape] {
        switch wk {
        case .plasma:       return Viewmodel.plasma(fire: 0, flash: 0)
        case .flamethrower: return Viewmodel.flamethrower(fire: 0, flash: 0, time: 0)
        case .rocket:       return Viewmodel.rocket(fire: 0, flash: 0)
        }
    }

    /// Kick the icons off in the background (called at launch); the codex falls
    /// back to the MeshItems sprite until they land.
    static func warm() { DispatchQueue.global(qos: .utility).async { ensureRendered() } }

    /// Block until every icon exists — harnesses want them deterministically.
    static func ensureRendered() {
        lock.lock(); let have = cache.count; lock.unlock()
        if have >= ItemKind.allCases.count { return }
        let kinds = ItemKind.allCases
        var out = [Sprite?](repeating: nil, count: kinds.count)
        out.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: buf.count) { i in
                buf[i] = render(GPURaymarch.itemShapes(kinds[i]), yaw: 0.62, pitch: 0.52)
            }
        }
        // the three weapons, viewed side-on-3/4 (a weapon reads by its profile, not top-down)
        let wk = WeaponKind.allCases
        var wout = [Sprite?](repeating: nil, count: wk.count)
        wout.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: buf.count) { i in
                buf[i] = render(weaponShapes(wk[i]), yaw: 1.15, pitch: 0.30)
            }
        }
        lock.lock()
        for (i, k) in kinds.enumerated() where out[i] != nil { cache[k.rawValue] = out[i] }
        for (i, k) in wk.enumerated() where wout[i] != nil { wcache[k.rawValue] = wout[i] }
        lock.unlock()
    }

    /// The SDF icon, or nil until warmed (caller falls back to the MeshItems sprite).
    static func cached(_ k: ItemKind) -> Sprite? { lock.lock(); defer { lock.unlock() }; return cache[k.rawValue] }
    /// The SDF weapon icon (from the viewmodel geometry), or nil until warmed.
    static func weapon(_ k: WeaponKind) -> Sprite? { lock.lock(); defer { lock.unlock() }; return wcache[k.rawValue] }

    // ── the sphere-tracer ──────────────────────────────────────────────────────
    private static let target = 120        // icon side (before trim)
    private static let ss = 2              // supersample → smooth silhouette

    @inline(__always) private static func v3(_ s: SIMD4<Float>) -> SIMD3<Float> { SIMD3(s.x, s.y, s.z) }
    @inline(__always) private static func vabs(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(abs(v.x), abs(v.y), abs(v.z)) }

    /// One shape's signed distance — mirrors GPURaymarch's shapeDist encodings.
    private static func shapeDist(_ sh: GShape, _ p: SIMD3<Float>) -> Float {
        let a = v3(sh.a), bw = sh.b.w
        if bw < -4.5 { return simd_length(p - a) - sh.a.w }                       // emissive sphere
        if bw < -3.5 {                                                            // z-axis flat-cap cylinder
            let q = p - a
            let dcy = SIMD2<Float>(simd_length(SIMD2(q.x, q.y)) - (sh.a.w - sh.b.x), abs(q.z) - (sh.b.y - sh.b.x))
            return min(max(dcy.x, dcy.y), 0) + simd_length(SIMD2(max(dcy.x, 0), max(dcy.y, 0))) - sh.b.x
        }
        if bw < -2.5 {                                                            // y-axis flat-cap cylinder
            let q = p - a
            let dcy = SIMD2<Float>(simd_length(SIMD2(q.x, q.z)) - (sh.a.w - sh.b.x), abs(q.y) - (sh.b.y - sh.b.x))
            return min(max(dcy.x, dcy.y), 0) + simd_length(SIMD2(max(dcy.x, 0), max(dcy.y, 0))) - sh.b.x
        }
        if bw < -1.5 {                                                            // rounded box
            let q = vabs(p - a) - v3(sh.b)
            return simd_length(SIMD3(max(q.x, 0), max(q.y, 0), max(q.z, 0))) + min(max(q.x, max(q.y, q.z)), 0) - sh.a.w
        }
        if bw < 0 { return simd_length(p - a) - sh.a.w }                          // sphere
        return roundCone(p, a, v3(sh.b), sh.a.w, sh.b.w)                          // round-cone
    }

    private static func roundCone(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ r1: Float, _ r2: Float) -> Float {
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
        if sgnZ * a2 * z2 > k { return (x2 + z2).squareRoot() * il2 - r2 }
        let sgnY: Float = y < 0 ? -1 : (y > 0 ? 1 : 0)
        if sgnY * a2 * y2 < k { return (x2 + y2).squareRoot() * il2 - r1 }
        return ((x2 * a2 * il2).squareRoot() + y * rr) * il2 - r1
    }

    /// Nearest-surface field: distance + the winning shape's colour (plain min —
    /// items are authored with crisp, low-k parts, so the union reads sharp).
    private static func field(_ p: SIMD3<Float>, _ shapes: [GShape]) -> (d: Float, col: SIMD3<Float>) {
        var best: Float = 1e9, col = SIMD3<Float>(0.6, 0.6, 0.6)
        for sh in shapes {
            let d = shapeDist(sh, p)
            if d < best { best = d; col = v3(sh.col) }
        }
        return (best, col)
    }
    @inline(__always) private static func dist(_ p: SIMD3<Float>, _ shapes: [GShape]) -> Float {
        var best: Float = 1e9
        for sh in shapes { best = min(best, shapeDist(sh, p)) }
        return best
    }

    private static func aabb(_ sh: GShape) -> (SIMD3<Float>, SIMD3<Float>) {
        let a = v3(sh.a), bw = sh.b.w
        if bw < -4.5 { let r = SIMD3(repeating: sh.a.w); return (a - r, a + r) }
        if bw < -3.5 { let r = SIMD3(sh.a.w, sh.a.w, sh.b.y); return (a - r, a + r) }   // z-cyl: radius xy, half z
        if bw < -2.5 { let r = SIMD3(sh.a.w, sh.b.y, sh.a.w); return (a - r, a + r) }   // y-cyl: radius xz, half y
        if bw < -1.5 { let r = v3(sh.b) + SIMD3(repeating: sh.a.w); return (a - r, a + r) }  // box
        if bw < 0 { let r = SIMD3(repeating: sh.a.w); return (a - r, a + r) }           // sphere
        let b = v3(sh.b)                                                                // cone endpoints ± radii
        let lo = SIMD3(min(a.x - sh.a.w, b.x - sh.b.w), min(a.y - sh.a.w, b.y - sh.b.w), min(a.z - sh.a.w, b.z - sh.b.w))
        let hi = SIMD3(max(a.x + sh.a.w, b.x + sh.b.w), max(a.y + sh.a.w, b.y + sh.b.w), max(a.z + sh.a.w, b.z + sh.b.w))
        return (lo, hi)
    }

    private static func render(_ shapes: [GShape], yaw: Float, pitch: Float) -> Sprite {
        guard !shapes.isEmpty else { return Sprite(w: 1, h: 1, pixels: [0]) }
        var lo = SIMD3<Float>(repeating: 1e9), hi = SIMD3<Float>(repeating: -1e9)
        for sh in shapes { let (l, h) = aabb(sh); lo = simd_min(lo, l); hi = simd_max(hi, h) }
        let center = (lo + hi) * 0.5

        let cp = cos(pitch), sp = sin(pitch)
        let off = simd_normalize(SIMD3<Float>(sin(yaw) * cp, sp, cos(yaw) * cp))   // centre → camera
        let d = -off                                                              // view direction
        let right = simd_normalize(simd_cross(d, SIMD3<Float>(0, 1, 0)))
        let up = simd_normalize(simd_cross(right, d))

        // orthographic extents from the AABB corners projected onto the basis
        var halfW: Float = 0, halfH: Float = 0, depthMin: Float = 1e9, depthMax: Float = -1e9
        for cx in [lo.x, hi.x] { for cy in [lo.y, hi.y] { for cz in [lo.z, hi.z] {
            let rel = SIMD3(cx, cy, cz) - center
            halfW = max(halfW, abs(simd_dot(rel, right)))
            halfH = max(halfH, abs(simd_dot(rel, up)))
            let dd = simd_dot(rel, d); depthMin = min(depthMin, dd); depthMax = max(depthMax, dd)
        } } }
        let margin = (halfW + halfH) * 0.06 + 0.01
        halfW += margin; halfH += margin
        // square the frame to the larger extent so nothing is distorted at trim
        let half = max(halfW, halfH)

        let R = target * ss
        var big = [UInt32](repeating: 0, count: R * R)
        let L = simd_normalize(SIMD3<Float>(-0.42, 0.86, 0.45))     // key light, upper-left-front
        let toCam = -d
        let eps: Float = 0.0006

        big.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: R) { j in
                let v = 1 - (Float(j) + 0.5) / Float(R) * 2
                for i in 0..<R {
                    let u = (Float(i) + 0.5) / Float(R) * 2 - 1
                    let base = center + right * (u * half) + up * (v * half)
                    var t = depthMin - 0.03
                    let endT = depthMax + 0.03
                    var hit = false
                    var p = SIMD3<Float>(0, 0, 0)
                    for _ in 0..<72 {
                        p = base + d * t
                        let dd = dist(p, shapes)
                        if dd < eps { hit = true; break }
                        t += max(dd, 0.0008)
                        if t > endT { break }
                    }
                    guard hit else { continue }
                    let e: Float = 0.0015
                    let nx = dist(p + SIMD3(e, 0, 0), shapes) - dist(p - SIMD3(e, 0, 0), shapes)
                    let ny = dist(p + SIMD3(0, e, 0), shapes) - dist(p - SIMD3(0, e, 0), shapes)
                    let nz = dist(p + SIMD3(0, 0, e), shapes) - dist(p - SIMD3(0, 0, e), shapes)
                    let n = simd_normalize(SIMD3(nx, ny, nz))
                    let col = field(p, shapes).col
                    let diff = max(0, simd_dot(n, L))
                    let rim = powf(1 - max(0, simd_dot(n, toCam)), 3) * 0.32
                    var lit = col * (0.42 + 0.72 * diff) + SIMD3(repeating: rim * 0.7)
                    let m = max(col.x, max(col.y, col.z))
                    if m > 0.88 { lit += col * 0.55 }              // vivid accents (cyan ring, red lamps) read as glow
                    lit = simd_min(lit, SIMD3(repeating: 1))
                    buf[j * R + i] = packRGBA(UInt8(lit.x * 255), UInt8(lit.y * 255), UInt8(lit.z * 255), 255)
                }
            }
        }

        // downsample ss×ss (premultiplied) → smooth, partially-transparent edges
        var small = [UInt32](repeating: 0, count: target * target)
        let n = ss * ss
        for j in 0..<target { for i in 0..<target {
            var r = 0, g = 0, b = 0, a = 0
            for sy in 0..<ss { for sx in 0..<ss {
                let c = big[(j * ss + sy) * R + (i * ss + sx)]
                let aa = Int((c >> 24) & 0xFF)
                r += Int(c & 0xFF) * aa; g += Int((c >> 8) & 0xFF) * aa; b += Int((c >> 16) & 0xFF) * aa; a += aa
            } }
            if a == 0 { small[j * target + i] = 0; continue }
            small[j * target + i] = packRGBA(UInt8(r / a), UInt8(g / a), UInt8(b / a), UInt8(a / n))
        } }
        return trim(small, target, target)
    }

    /// Crop the transparent margins to a tight sprite (a small feather kept).
    private static func trim(_ px: [UInt32], _ w: Int, _ h: Int) -> Sprite {
        var minX = w, maxX = -1, minY = h, maxY = -1
        for j in 0..<h { for i in 0..<w where (px[j * w + i] >> 24) > 6 {
            if i < minX { minX = i }; if i > maxX { maxX = i }
            if j < minY { minY = j }; if j > maxY { maxY = j }
        } }
        guard maxX >= minX, maxY >= minY else { return Sprite(w: 1, h: 1, pixels: [0]) }
        let pad = 2
        minX = max(0, minX - pad); maxX = min(w - 1, maxX + pad)
        minY = max(0, minY - pad); maxY = min(h - 1, maxY + pad)
        let tw = maxX - minX + 1, th = maxY - minY + 1
        var out = [UInt32](repeating: 0, count: tw * th)
        for j in 0..<th { for i in 0..<tw { out[j * tw + i] = px[(minY + j) * w + (minX + i)] } }
        return Sprite(w: tw, h: th, pixels: out)
    }
}
