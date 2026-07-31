// Citadel — the rasteriser's geometry emitters.
//
// Every function here APPENDS TRIANGLES to a `[PVert]` and touches no renderer state at all. That was
// the finding that made splitting the renderer possible: measured, all fourteen emitters and their
// tessellation helpers are PURE. So they were never renderer behaviour — they are a geometry library
// that both the static level-mesh build and the per-frame prop pass call into, and keeping them
// private on the renderer is what had those two jobs welded together.
//
// STATIC, in an extension on RasterRenderer rather than a namespace of their own, for one concrete
// reason: PVert and Mat are nested in RasterRenderer and referenced nowhere else in the game, so an
// extension lets these resolve them unqualified. Hoisting those two types to file scope to allow a
// standalone type would have been churn across the whole renderer for no gain. (`Emit`, the obvious
// name for such a namespace, is taken by Lighting.swift in any case.)
//
// Mat and its M() shorthand come along because the emitters are written in terms of them, and M() is
// called fifty-odd times — it earns its one-letter name.
//
// ONE emitter had to change to get here. emitBulkheadFixture called loadBulkhead(), which caches into
// renderer state; it now takes the loaded mesh as a parameter. That single edit is what let the whole
// library come loose.

import Foundation
import Metal
import simd

extension RasterRenderer {
    // ── procedural PBR material tables (asset-light) ──────────────────────────
    struct Mat { var a: SIMD3<Float>; var r: Float; var m: Float; var e: SIMD3<Float> }

    static func M(_ a: SIMD3<Float>, _ r: Float, _ m: Float, _ e: SIMD3<Float> = .zero) -> Mat { Mat(a: a, r: r, m: m, e: e) }

    /// Tessellate one prop shape into `v`, mapping local→world with `xf` (position:
    /// yaw + translate) and `xn` (normal: yaw only). Emits per-vertex normals.
    static func tessShape(_ sh: GPURaymarch.GShape, rough: Float, metal: Float,
                           _ xf: (SIMD3<Float>) -> SIMD3<Float>,
                           _ xn: (SIMD3<Float>) -> SIMD3<Float>,
                           into v: inout [PVert]) {
        let m = propMat(SIMD3(sh.col.x, sh.col.y, sh.col.z), rough, metal)
        func push(_ lp: SIMD3<Float>, _ ln: SIMD3<Float>) {
            let p = xf(lp); let n = simd_normalize(xn(ln))
            v.append(PVert(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z,
                           ar: m.a.x, ag: m.a.y, ab: m.a.z, rough: m.r, metal: m.m, er: m.e.x, eg: m.e.y, eb: m.e.z))
        }
        func tri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                 _ na: SIMD3<Float>, _ nb: SIMD3<Float>, _ nc: SIMD3<Float>) { push(a, na); push(b, nb); push(c, nc) }
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ n: SIMD3<Float>) {
            tri(a, b, c, n, n, n); tri(a, c, d, n, n, n)
        }
        let c = SIMD3(sh.a.x, sh.a.y, sh.a.z), bw = sh.b.w
        if bw < -3.5 {                        // ── Z-disc: flat-capped cylinder along local +Z
            tessAxial(c, r: sh.a.w, half: sh.b.y, axis: SIMD3(0, 0, 1), rad1: SIMD3(1, 0, 0), rad2: SIMD3(0, 1, 0), tri: tri)
        } else if bw < -2.5 {                 // ── Y-cylinder: oil-drum axis
            tessAxial(c, r: sh.a.w, half: sh.b.y, axis: SIMD3(0, 1, 0), rad1: SIMD3(1, 0, 0), rad2: SIMD3(0, 0, 1), tri: tri)
        } else if bw < -1.5 {                 // ── box
            tessBox(c, h: SIMD3(sh.b.x, sh.b.y, sh.b.z), quad: quad)
        } else if bw < 0 {                    // ── sphere
            tessSphere(c, r: sh.a.w, tri: tri)
        } else {                              // ── round cone A(r1) → B(r2)
            tessCone(c, SIMD3(sh.b.x, sh.b.y, sh.b.z), r1: sh.a.w, r2: sh.b.w, tri: tri)
        }
    }

    static func tessBox(_ c: SIMD3<Float>, h: SIMD3<Float>,
                         quad: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) -> Void) {
        let x0 = c.x - h.x, x1 = c.x + h.x, y0 = c.y - h.y, y1 = c.y + h.y, z0 = c.z - h.z, z1 = c.z + h.z
        func P(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { SIMD3(x, y, z) }
        quad(P(x1, y0, z0), P(x1, y0, z1), P(x1, y1, z1), P(x1, y1, z0), SIMD3(1, 0, 0))
        quad(P(x0, y0, z1), P(x0, y0, z0), P(x0, y1, z0), P(x0, y1, z1), SIMD3(-1, 0, 0))
        quad(P(x0, y1, z0), P(x1, y1, z0), P(x1, y1, z1), P(x0, y1, z1), SIMD3(0, 1, 0))
        quad(P(x0, y0, z1), P(x1, y0, z1), P(x1, y0, z0), P(x0, y0, z0), SIMD3(0, -1, 0))
        quad(P(x1, y0, z1), P(x0, y0, z1), P(x0, y1, z1), P(x1, y1, z1), SIMD3(0, 0, 1))
        quad(P(x0, y0, z0), P(x1, y0, z0), P(x1, y1, z0), P(x0, y1, z0), SIMD3(0, 0, -1))
    }

    /// `segments` scales the longitude/latitude count. The default 1 is the house budget for props and
    /// creature detail, where a sphere is metres away and 12×8 facets are invisible. The held weapon is
    /// INCHES from the eye, so its small round parts — the charge LEDs above all — show every facet at
    /// that density; they pass a higher count, and only they pay for it.
    static func tessSphere(_ c: SIMD3<Float>, r: Float, segments: Int = 1,
                            tri: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) -> Void) {
        let LON = 12 * segments, LAT = 8 * segments, tau = 2 * Float.pi
        func nrm(_ la: Int, _ lo: Int) -> SIMD3<Float> {
            let ph = Float(la) / Float(LAT) * Float.pi, s = Float(lo) / Float(LON) * tau
            return SIMD3(sinf(ph) * cosf(s), cosf(ph), sinf(ph) * sinf(s))
        }
        for la in 0..<LAT { for lo in 0..<LON {
            let n00 = nrm(la, lo), n01 = nrm(la, lo + 1), n10 = nrm(la + 1, lo), n11 = nrm(la + 1, lo + 1)
            tri(c + r * n00, c + r * n01, c + r * n11, n00, n01, n11)
            tri(c + r * n00, c + r * n11, c + r * n10, n00, n11, n10)
        } }
    }

    static func tessCone(_ A: SIMD3<Float>, _ B: SIMD3<Float>, r1: Float, r2: Float,
                          tri: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) -> Void) {
        let ab = B - A, L = simd_length(ab)
        let axis = L > 1e-5 ? ab / L : SIMD3<Float>(0, 1, 0)
        let up = abs(axis.y) < 0.99 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        let u = simd_normalize(simd_cross(up, axis)), vv = simd_cross(axis, u)
        let slope = L > 1e-5 ? (r2 - r1) / L : 0
        let SEG = 14, tau = 2 * Float.pi
        func rd(_ s: Int) -> SIMD3<Float> { let a = Float(s) / Float(SEG) * tau; return cosf(a) * u + sinf(a) * vv }
        for s in 0..<SEG {
            let d0 = rd(s), d1 = rd(s + 1)
            let a0 = A + r1 * d0, a1 = A + r1 * d1, b0 = B + r2 * d0, b1 = B + r2 * d1
            let n0 = simd_normalize(d0 - axis * slope), n1 = simd_normalize(d1 - axis * slope)   // slope-corrected side normal
            tri(a0, a1, b1, n0, n1, n1); tri(a0, b1, b0, n0, n1, n0)
            if r1 > 1e-4 { tri(A, a1, a0, -axis, -axis, -axis) }
            if r2 > 1e-4 { tri(B, b0, b1, axis, axis, axis) }
        }
    }

    /// A flat-capped cylinder about an arbitrary local `axis` (with `rad1`,`rad2` the
    /// two unit directions spanning the circular cross-section). Serves both the
    /// Y-cylinder (drums) and the Z-disc (reel faces) — same body, different axis.
    static func tessAxial(_ c: SIMD3<Float>, r: Float, half: Float,
                           axis: SIMD3<Float>, rad1: SIMD3<Float>, rad2: SIMD3<Float>,
                           tri: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) -> Void) {
        let SEG = 18, tau = 2 * Float.pi
        let cb = c - axis * half, ct = c + axis * half   // bottom/top cap centres
        func rd(_ s: Int) -> SIMD3<Float> { let a = Float(s) / Float(SEG) * tau; return cosf(a) * rad1 + sinf(a) * rad2 }
        for s in 0..<SEG {
            let d0 = rd(s), d1 = rd(s + 1)
            let b0 = cb + r * d0, b1 = cb + r * d1, t0 = ct + r * d0, t1 = ct + r * d1
            tri(b0, b1, t1, d0, d1, d1); tri(b0, t1, t0, d0, d1, d0)   // side (radial normals)
            tri(ct, t0, t1, axis, axis, axis)                          // top cap (+axis)
            tri(cb, b1, b0, -axis, -axis, -axis)                       // bottom cap (−axis)
        }
    }

    static func rrShapeYExtent(_ s: GPURaymarch.GShape) -> (Float, Float) {
        let a = s.a, b = s.b
        if b.w < -3.5 { return (a.y - a.w, a.y + a.w) }               // z-disc: radius a.w spans Y
        if b.w < -2.5 { return (a.y - b.y, a.y + b.y) }               // Y-cylinder: half-height b.y
        if b.w < -1.5 { return (a.y - b.y - a.w, a.y + b.y + a.w) }   // box
        if b.w < 0    { return (a.y - a.w, a.y + a.w) }               // sphere
        return (min(a.y - a.w, b.y - b.w), max(a.y + a.w, b.y + b.w)) // cone
    }

    /// A GShape colour → PBR material. Over-bright (peak channel > 1) = a self-lit part
    /// (the raymarcher's emissive convention); otherwise the prop CLASS's rough/metal.
    static func propMat(_ col: SIMD3<Float>, _ rough: Float, _ metal: Float) -> Mat {
        let peak = max(col.x, max(col.y, col.z))
        if peak > 1.0 {                       // authored bloom → emissive fixture part
            let base = col / peak             // hue at unit brightness
            return M(base * 0.30, 0.40, 0.0, base * peak * 0.9)
        }
        return M(col, rough, metal)           // greasy industrial metal (grime added in-shader)
    }

    /// Emit an axis-aligned box [lo,hi] with flat outward normals and material `m`. Winding is
    /// irrelevant (the passes cull .none) — only the NORMALS must point out. Used for door leaves.
    static func emitAABB(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>, _ m: Mat, tid: Float = -1, into v: inout [PVert]) {
        func vert(_ p: SIMD3<Float>, _ n: SIMD3<Float>) -> PVert {
            PVert(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z,
                  ar: m.a.x, ag: m.a.y, ab: m.a.z, rough: m.r, metal: m.m, er: m.e.x, eg: m.e.y, eb: m.e.z, tid: tid)
        }
        func face(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ n: SIMD3<Float>) {
            v += [vert(a, n), vert(b, n), vert(c, n), vert(a, n), vert(c, n), vert(d, n)]
        }
        let x0 = lo.x, y0 = lo.y, z0 = lo.z, x1 = hi.x, y1 = hi.y, z1 = hi.z
        face(SIMD3(x0, y0, z1), SIMD3(x1, y0, z1), SIMD3(x1, y1, z1), SIMD3(x0, y1, z1), SIMD3(0, 0, 1))    // +Z
        face(SIMD3(x1, y0, z0), SIMD3(x0, y0, z0), SIMD3(x0, y1, z0), SIMD3(x1, y1, z0), SIMD3(0, 0, -1))   // −Z
        face(SIMD3(x1, y0, z1), SIMD3(x1, y0, z0), SIMD3(x1, y1, z0), SIMD3(x1, y1, z1), SIMD3(1, 0, 0))    // +X
        face(SIMD3(x0, y0, z0), SIMD3(x0, y0, z1), SIMD3(x0, y1, z1), SIMD3(x0, y1, z0), SIMD3(-1, 0, 0))   // −X
        face(SIMD3(x0, y1, z1), SIMD3(x1, y1, z1), SIMD3(x1, y1, z0), SIMD3(x0, y1, z0), SIMD3(0, 1, 0))    // +Y top
        face(SIMD3(x0, y0, z0), SIMD3(x1, y0, z0), SIMD3(x1, y0, z1), SIMD3(x0, y0, z1), SIMD3(0, -1, 0))   // −Y bottom
    }

    /// A single flat quad (two triangles), centred at `c`, spanning ±`u` (right) and ±`w` (up), facing `n`.
    static func emitQuad(_ c: SIMD3<Float>, _ u: SIMD3<Float>, _ w: SIMD3<Float>, _ n: SIMD3<Float>, _ m: Mat, into v: inout [PVert]) {
        func vert(_ p: SIMD3<Float>) -> PVert {
            PVert(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z,
                  ar: m.a.x, ag: m.a.y, ab: m.a.z, rough: m.r, metal: m.m, er: m.e.x, eg: m.e.y, eb: m.e.z, tid: -1)
        }
        let a = c - u - w, b = c + u - w, cc = c + u + w, dd = c - u + w
        v += [vert(a), vert(b), vert(cc), vert(a), vert(cc), vert(dd)]
    }

    /// A capped cylinder between two world points. The GShape cylinders the prop path uses are Y-axis or
    /// Z-axis only, but a pipe run lies along an ARBITRARY axis, so tessellate it directly here.
    /// `nearCap: false` caps only the FAR end (`b`). A fitting sleeve starts inside the junction it belongs to,
    /// with the pipe running through it, so its near disc can never be seen — and pipework is the geometry that
    /// dominates the level mesh, which is the whole reason caps are optional here. Capping both ends of every
    /// sleeve measured +43% on the pipe vertex count; capping only the exposed ends is half of that.
    static func emitTube(_ a: SIMD3<Float>, _ b: SIMD3<Float>, r: Float, sides: Int = 10, _ m: Mat,
                         caps: Bool = true, nearCap: Bool = true, into v: inout [PVert]) {
        let ax = b - a; let len = simd_length(ax)
        guard len > 1e-5, r > 1e-5 else { return }
        let d = ax / len
        let up = abs(d.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        let t = simd_normalize(simd_cross(up, d)), s = simd_cross(d, t)
        func vert(_ p: SIMD3<Float>, _ n: SIMD3<Float>) -> PVert {
            PVert(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z,
                  ar: m.a.x, ag: m.a.y, ab: m.a.z, rough: m.r, metal: m.m, er: m.e.x, eg: m.e.y, eb: m.e.z, tid: -1)
        }
        var prevN = t, prevA = a + t * r, prevB = b + t * r
        for i in 1...sides {
            let ang = Float(i) / Float(sides) * 2 * Float.pi
            let n = t * cosf(ang) + s * sinf(ang)
            let ca = a + n * r, cb = b + n * r
            v += [vert(prevA, prevN), vert(ca, n), vert(cb, n), vert(prevA, prevN), vert(cb, n), vert(prevB, prevN)]
            if caps {
                if nearCap { v += [vert(a, -d), vert(prevA, -d), vert(ca, -d)] }   // near cap
                v += [vert(b, d), vert(cb, d), vert(prevB, d)]                     // far cap
            }
            prevN = n; prevA = ca; prevB = cb
        }
    }

    /// A flat filled ELLIPSE (triangle-fan), radii `ru`×`rv` in the (u, up) plane, centred at `c`, facing `n`.
    static func emitEllipse(_ c: SIMD3<Float>, _ u: SIMD3<Float>, _ up: SIMD3<Float>, _ ru: Float, _ rv: Float, _ n: SIMD3<Float>, _ m: Mat, into v: inout [PVert]) {
        func vert(_ p: SIMD3<Float>) -> PVert {
            PVert(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z,
                  ar: m.a.x, ag: m.a.y, ab: m.a.z, rough: m.r, metal: m.m, er: m.e.x, eg: m.e.y, eb: m.e.z, tid: -1)
        }
        let seg = 20
        var prev = c + u * ru
        for i in 1...seg {
            let a = Float(i) / Float(seg) * 2 * Float.pi
            let cur = c + u * (cosf(a) * ru) + up * (sinf(a) * rv)
            v += [vert(c), vert(prev), vert(cur)]; prev = cur
        }
    }

    /// A flat DIAMOND (rotated-square) decal — tip up/down/left/right — centred at `c`, facing `n`.
    static func emitDiamond(_ c: SIMD3<Float>, _ u: SIMD3<Float>, _ up: SIMD3<Float>, _ s: Float, _ n: SIMD3<Float>, _ m: Mat, into v: inout [PVert]) {
        func vert(_ p: SIMD3<Float>) -> PVert {
            PVert(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z,
                  ar: m.a.x, ag: m.a.y, ab: m.a.z, rough: m.r, metal: m.m, er: m.e.x, eg: m.e.y, eb: m.e.z, tid: -1)
        }
        let top = c + up * s, rgt = c + u * s, bot = c - up * s, lft = c - u * s
        v += [vert(top), vert(rgt), vert(bot), vert(top), vert(bot), vert(lft)]
    }

    /// A flame silhouette (fan-triangulated outline) centred at `c`, in the (u, up) plane, facing `n`.
    static func emitFlame(_ c: SIMD3<Float>, _ u: SIMD3<Float>, _ up: SIMD3<Float>, _ s: Float, _ n: SIMD3<Float>, _ m: Mat, into v: inout [PVert]) {
        let pts: [SIMD2<Float>] = [                                    // x=across, y=up; a licking flame with a hooked tip
            SIMD2(0.00, -0.55), SIMD2(0.42, -0.30), SIMD2(0.22, -0.02), SIMD2(0.46, 0.18),
            SIMD2(0.10, 0.30), SIMD2(0.28, 0.62), SIMD2(0.02, 0.60), SIMD2(0.16, 1.00),
            SIMD2(-0.18, 0.58), SIMD2(-0.08, 0.24), SIMD2(-0.42, 0.12), SIMD2(-0.14, -0.06), SIMD2(-0.40, -0.34)]
        func vert(_ p2: SIMD2<Float>) -> PVert {
            let p = c + u * (p2.x * s) + up * (p2.y * s)
            return PVert(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z,
                         ar: m.a.x, ag: m.a.y, ab: m.a.z, rough: m.r, metal: m.m, er: m.e.x, eg: m.e.y, eb: m.e.z, tid: -1)
        }
        var s2 = SIMD2<Float>(0, 0); for p in pts { s2 += p }
        let ctr = s2 / Float(pts.count)
        for i in 0..<pts.count { v += [vert(ctr), vert(pts[i]), vert(pts[(i + 1) % pts.count])] }
    }

    /// A SINGLE oil placard PAINTED on the drum — a yellow warning diamond (dark border + symbol), like a
    /// real barrel. Billboarded to face the player so the one label always reads; sits flush on the r≈0.155
    /// body between the rolling hoops. Kept off the drum-weathering flag so the rust doesn't eat it.
    static func emitDrumLabel(pos: SIMD2<Float>, toward pp: SIMD2<Float>, into v: inout [PVert]) {
        let border = M(SIMD3(0.06, 0.05, 0.03), 0.6, 0.05)   // dark diamond border
        let plate  = M(SIMD3(0.80, 0.64, 0.05), 0.6, 0.05)   // hazard yellow (printed, not metal)
        let mark   = M(SIMD3(0.06, 0.05, 0.03), 0.6, 0.05)   // dark central symbol
        let rel = pp - pos, dist = simd_length(rel)
        let f = dist > 1e-4 ? SIMD3<Float>(rel.x / dist, 0, rel.y / dist) : SIMD3<Float>(0, 0, 1)   // face the player
        let u = SIMD3<Float>(-f.z, 0, f.x), up = SIMD3<Float>(0, 1, 0)
        let c = SIMD3<Float>(pos.x, 0.235, pos.y) + f * 0.161                                        // between the hoops, proud of the body
        emitDiamond(c,            u, up, 0.062, f, border, into: &v)
        emitDiamond(c + f * 0.002, u, up, 0.050, f, plate,  into: &v)
        emitFlame(c + f * 0.004, u, up, 0.030, f, mark, into: &v)   // flammable flame pictogram
    }

    /// Tessellate a prop's local shapes into `v`, applying the kernel's LOCAL→WORLD
    /// transform inverted: XZ rotation about +yaw, translate to `pos`, drop the lowest
    /// authored point to the floor when `floored` (yOff = loY; wall-pipes/sockets keep
    /// their authored height). `rough`/`metal` are the prop class's PBR base.
    static func emitProp(_ shapes: [GPURaymarch.GShape], pos: SIMD2<Float>, yaw: Float,
                          floored: Bool, rough: Float, metal: Float, yScale: Float = 1, into v: inout [PVert]) {
        var yOff: Float = 0
        if floored { var lo: Float = 1e9; for s in shapes { lo = min(lo, rrShapeYExtent(s).0) }; yOff = lo }
        let cy = cosf(yaw), sy = sinf(yaw)
        // yScale stretches a floor-to-ceiling prop (the structural column, authored y 0…1) to its cell's own
        // ceiling — in a double-height machine hall an unscaled column would stop halfway up as a floating stub.
        let xf: (SIMD3<Float>) -> SIMD3<Float> = { l in SIMD3(pos.x + l.x * cy - l.z * sy, (l.y - yOff) * yScale, pos.y + l.x * sy + l.z * cy) }
        let xn: (SIMD3<Float>) -> SIMD3<Float> = { n in SIMD3(n.x * cy - n.z * sy, n.y, n.x * sy + n.z * cy) }
        for s in shapes { tessShape(s, rough: rough, metal: metal, xf, xn, into: &v) }
    }

    /// Emit the imported bulkhead lamp (centred local PVerts) at a wall mount: yaw about +Y, lifted to `height`.
    static func emitBulkheadMesh(_ mesh: [PVert], pos: SIMD2<Float>, yaw: Float, height: Float, into v: inout [PVert]) {
        let cy = cosf(yaw), sy = sinf(yaw)
        for pv in mesh {
            v.append(PVert(px: pos.x + pv.px * cy - pv.pz * sy, py: pv.py + height, pz: pos.y + pv.px * sy + pv.pz * cy,
                           nx: pv.nx * cy - pv.nz * sy, ny: pv.ny, nz: pv.nx * sy + pv.nz * cy,
                           ar: pv.ar, ag: pv.ag, ab: pv.ab, rough: pv.rough, metal: pv.metal, er: pv.er, eg: pv.eg, eb: pv.eb, tid: pv.tid))
        }
    }

    /// A floating PICKUP: like emitProp but UNIFORMLY scaled about its origin, its base
    /// dropped to 0 then lifted by `floatH` (hover), and spun by `yaw` — mirrors the
    /// raymarcher's packItems so items read identically. Emissive parts (peak>1 colours,
    /// e.g. cell rings) light themselves via propMat; the rest is semi-glossy canister metal.
    static func emitItem(_ shapes: [GPURaymarch.GShape], pos: SIMD2<Float>, yaw: Float,
                          scale: Float, floatH: Float, into v: inout [PVert]) {
        var loY: Float = 1e9
        for s in shapes { loY = min(loY, rrShapeYExtent(s).0) }
        let cy = cosf(yaw), sy = sinf(yaw)
        let xf: (SIMD3<Float>) -> SIMD3<Float> = { l in
            let sx = l.x * scale, sz = l.z * scale
            return SIMD3(pos.x + sx * cy - sz * sy, (l.y - loY) * scale + floatH, pos.y + sx * sy + sz * cy)
        }
        let xn: (SIMD3<Float>) -> SIMD3<Float> = { n in SIMD3(n.x * cy - n.z * sy, n.y, n.x * sy + n.z * cy) }
        for s in shapes { tessShape(s, rough: 0.42, metal: 0.40, xf, xn, into: &v) }
    }

    static func emitMesh(_ mesh: [PVert], pos: SIMD2<Float>, yaw: Float, scale: Float, into v: inout [PVert]) {
        let cy = cosf(yaw), sy = sinf(yaw)
        for pv in mesh {
            let lx = pv.px * scale, ly = pv.py * scale, lz = pv.pz * scale
            let nx = pv.nx, nz = pv.nz
            v.append(PVert(px: pos.x + lx * cy - lz * sy, py: ly, pz: pos.y + lx * sy + lz * cy,
                           nx: nx * cy - nz * sy, ny: pv.ny, nz: nx * sy + nz * cy,
                           ar: pv.ar, ag: pv.ag, ab: pv.ab, rough: pv.rough, metal: pv.metal, er: pv.er, eg: pv.eg, eb: pv.eb,
                           // FORWARD the material id. This argument was missing, so it defaulted to −1 and
                           // EVERY imported mesh arrived at the fragment claiming "plain flat material" —
                           // which is why the machinery's tid −6 weathering branch never once executed.
                           // Nothing complained: the vertex still built, the mesh still drew, it just
                           // quietly lost the one field that selects a surface treatment.
                           tid: pv.tid))
        }
    }

    /// A cast TEE: the main passes through a slightly fatter body, and the branch leaves it square. Real plant
    /// pipework never just abuts — a branch is taken off a tee, so this is what a junction must look like.
    static func emitTee(at p: SIMD3<Float>, run: SIMD3<Float>, branch: SIMD3<Float>, r: Float, _ body: Mat, into v: inout [PVert]) {
        // The body straddles the main, so BOTH its ends stand in open air; the branch socket starts inside the
        // junction, so only its outer end can be seen.
        emitTube(p - run * 0.052, p + run * 0.052, r: r * 1.34, sides: 9, body, caps: true, into: &v)
        emitTube(p, p + branch * 0.055, r: r * 1.18, sides: 9, body, caps: true, nearCap: false, into: &v)
    }

    /// A 90° ELBOW: a fatter short sleeve on each leg where the two directions meet, so the corner reads as a
    /// cast fitting rather than two pipes mitred into each other.
    ///
    /// CAPPED, unlike the runs. The runs drop their caps because every end is buried in a wall or hidden behind
    /// a flange, and an invisible cap is pure cost on the geometry that dominates the level mesh — but a fitting
    /// sleeve is WIDER than the pipe it wraps, so its outer end is an annulus standing in open air. Uncapped,
    /// you looked straight through that annulus into the inside of the sleeve's far wall, and the fitting read
    /// as a torn hollow cage rather than a casting. The pipe emerging through the middle hides the centre of
    /// each disc, so what you see is the flat end face a real cast fitting has.
    /// `capNear` closes the discs at `p` itself. Mid-run — a riser turning into a high main — the two
    /// sleeves leave `p` with pipe inside each, so those discs are buried and omitting them is free.
    /// At a run TERMINUS they are not: the wedge between two perpendicular sleeves is open to the
    /// room, and you see through it into whatever the sleeves failed to close.
    static func emitElbow(at p: SIMD3<Float>, legA: SIMD3<Float>, legB: SIMD3<Float>, r: Float, _ body: Mat,
                          capNear: Bool = false, into v: inout [PVert]) {
        // At a TERMINUS the sleeve starts slightly BEHIND `p` rather than on it. The run's own end disc
        // is at `p`, and a sleeve cap placed exactly there is coplanar with it — two surfaces at one
        // depth, fighting, which is what made a finished pipe end read as a pale mismatched disc
        // instead of a casting. Backing the sleeve off puts its cap unambiguously in front, so the
        // run's disc is hidden behind a face rather than competing with one. Mid-run the sleeves start
        // at `p` as before: their near discs are inside the junction and never drawn.
        let back = capNear ? Float(0.014) : 0
        emitTube(p - legA * back, p + legA * 0.055, r: r * 1.26, sides: 9, body, caps: true, nearCap: capNear, into: &v)
        emitTube(p - legB * back, p + legB * 0.055, r: r * 1.26, sides: 9, body, caps: true, nearCap: capNear, into: &v)
    }

    /// Wall-mount ONE bulkhead fixture: the imported brass lamp plus its lit, ribbed lens (or the procedural
    /// caged lamp if the mesh is unavailable). Shared by every placement — the fuel store and the plant floors.
    /// `lamp` is the imported bulkhead mesh, or nil to fall back to the procedural caged lamp.
    static func emitBulkheadFixture(pos: SIMD2<Float>, yaw: Float, inward: SIMD2<Float>,
                                    lamp: [PVert]?, into v: inout [PVert]) {
        let glow = M(SIMD3(0.95, 0.78, 0.5), 0.4, 0.0, SIMD3(1.7, 1.05, 0.42))     // warm GOLDEN lens (matches the brass reference), modest so the frame reads
        guard let lamp else {                            // fallback: the procedural caged lamp
            emitProp(GPURaymarch.bulkheadShapes(), pos: pos, yaw: yaw, floored: false, rough: 0.5, metal: 0.7, into: &v)
            return
        }
        emitBulkheadMesh(lamp, pos: pos, yaw: yaw, height: 0.56, into: &v)  // imported bulkhead mesh (vertical), at eye height
        // a lit lens — a warm, VERTICAL rounded glow set just inside the cage so the frame stays visible over it
        let n = SIMD3<Float>(inward.x, 0, inward.y), u = SIMD3<Float>(-inward.y, 0, inward.x), up = SIMD3<Float>(0, 1, 0)
        let c = SIMD3<Float>(pos.x, 0.56, pos.y) + n * 0.03
        emitEllipse(c, u, up, 0.045, 0.11, n, glow, into: &v)
        // fluted-glass RIBBING (the reference's ribbed lens): a few thin darker verticals over the glow
        let rib = M(SIMD3(0.5, 0.36, 0.12), 0.5, 0.0, SIMD3(0.5, 0.34, 0.12))
        for rx in [Float(-0.026), 0, 0.026] {
            emitEllipse(c + n * 0.002 + u * rx, u, up, 0.004, 0.095, n, rib, into: &v)
        }
    }

    // ══ the surface material palette ═══════════════════════════════════════════════
    //  Three tables mapping a map cell's texture id to its PBR material. They live beside
    //  `propMat` because they are the same kind of thing and were the same kind of thing all
    //  along — pure id → Mat lookups with no renderer state — and because both the STATIC
    //  level mesh and the PER-FRAME door mesh read them. Split across two files they would
    //  have to be reachable from both anyway; together, the whole palette is one place.

    static func wallTexAt(_ map: GameMap, _ x: Int, _ y: Int) -> Mat {
        guard map.inBounds(x, y) else { return wallMat(.steelPanel) }
        return wallMat(WallTex(rawValue: map.wall[map.idx(x, y)]) ?? .steelPanel)
    }

    static func wallMat(_ t: WallTex) -> Mat {
        switch t {
        case .none:           return Self.M(SIMD3(0.45, 0.45, 0.50), 0.60, 0.50)
        case .ironPlate:      return Self.M(SIMD3(0.40, 0.35, 0.31), 0.66, 0.55)
        case .brushedSteel:   return Self.M(SIMD3(0.56, 0.59, 0.66), 0.44, 0.75)
        case .steelPanel:     return Self.M(SIMD3(0.38, 0.40, 0.46), 0.52, 0.62)
        case .litPanel:       return Self.M(SIMD3(0.40, 0.44, 0.52), 0.45, 0.40, SIMD3(0.12, 0.26, 0.23))   // soft strip-light glow
        case .ribbedSteel:    return Self.M(SIMD3(0.42, 0.44, 0.50), 0.50, 0.66)
        case .pipework:       return Self.M(SIMD3(0.44, 0.46, 0.52), 0.34, 0.78)
        case .glass:          return Self.M(SIMD3(0.14, 0.22, 0.28), 0.14, 0.25)
        case .stone:          return Self.M(SIMD3(0.40, 0.36, 0.31), 0.90, 0.02)
        case .stoneSteel:     return Self.M(SIMD3(0.36, 0.34, 0.31), 0.80, 0.22)
        case .computer:       return Self.M(SIMD3(0.22, 0.26, 0.32), 0.50, 0.35, SIMD3(0.32, 0.24, 0.10))   // amber CRT
        case .hazard:         return Self.M(SIMD3(0.52, 0.44, 0.12), 0.60, 0.35)
        case .doorPanel:      return Self.M(SIMD3(0.44, 0.46, 0.50), 0.50, 0.60)
        case .doorRed:        return Self.M(SIMD3(0.48, 0.16, 0.14), 0.55, 0.40, SIMD3(0.24, 0.03, 0.02))
        case .doorBlue:       return Self.M(SIMD3(0.16, 0.24, 0.48), 0.55, 0.40, SIMD3(0.03, 0.06, 0.24))
        case .doorYellow:     return Self.M(SIMD3(0.52, 0.46, 0.12), 0.55, 0.40, SIMD3(0.22, 0.18, 0.03))
        case .exitSwitch:     return Self.M(SIMD3(0.20, 0.44, 0.24), 0.50, 0.30, SIMD3(0.10, 0.36, 0.16))   // green exit glow
        case .doorHazard:     return Self.M(SIMD3(0.50, 0.44, 0.12), 0.60, 0.35)
        case .elevatorSealed: return Self.M(SIMD3(0.40, 0.42, 0.47), 0.50, 0.60)
        case .liftWall:       return Self.M(SIMD3(0.42, 0.44, 0.49), 0.50, 0.62)
        case .concrete:       return Self.M(SIMD3(0.52, 0.51, 0.48), 0.92, 0.02)   // matte poured concrete — no metal, no glow
        case .opsBoard:       return Self.M(SIMD3(0.05, 0.055, 0.065), 0.42, 0.20)   // dark glass; the RGB content is emissive (see rr_fragment)
        case .medWall:        return Self.M(SIMD3(0.82, 0.83, 0.82), 0.68, 0.02)     // white painted concrete — bright, matte, sterile
        case .subwayTile:     return Self.M(SIMD3(0.86, 0.87, 0.86), 0.24, 0.04)     // glazed ceramic — bright and a touch shiny
        case .sanTile:        return Self.M(SIMD3(0.70, 0.78, 0.74), 0.20, 0.04)     // glazed pale green — wet-room shine
        }
    }

    static func flatMat(_ id: Int) -> Mat {
        switch FlatTex(rawValue: id) ?? .concrete {
        case .concrete:    return Self.M(SIMD3(0.34, 0.33, 0.31), 0.85, 0.02)
        case .metalFloor:  return Self.M(SIMD3(0.31, 0.31, 0.33), 0.55, 0.32)   // near-neutral, less metal so it doesn't crush to a dark blue patch vs concrete
        case .grate:       return Self.M(SIMD3(0.23, 0.23, 0.24), 0.55, 0.45)   // dark IRON grate — clearly darker than concrete but not a blue void (also lifts tier-3/4 base floor)
        case .nukage:      return Self.M(SIMD3(0.22, 0.34, 0.12), 0.30, 0.00, SIMD3(0.15, 0.36, 0.09))      // toxic glow
        case .ceilTech:    return Self.M(SIMD3(0.17, 0.19, 0.23), 0.70, 0.32)
        case .ceilDark:    return Self.M(SIMD3(0.10, 0.11, 0.13), 0.72, 0.22)
        case .ceilStone:   return Self.M(SIMD3(0.30, 0.28, 0.25), 0.85, 0.02)
        case .ceilWhite:   return Self.M(SIMD3(0.80, 0.81, 0.80), 0.60, 0.02, SIMD3(0.10, 0.10, 0.098))   // painted panels + a faint light run
        case .rock:        return Self.M(SIMD3(0.32, 0.29, 0.25), 0.90, 0.00)
        case .blood:       return Self.M(SIMD3(0.18, 0.05, 0.05), 0.40, 0.00)
        case .teleportPad: return Self.M(SIMD3(0.20, 0.30, 0.50), 0.30, 0.20, SIMD3(0.16, 0.30, 0.62))      // teleporter glow
        }
    }
}
