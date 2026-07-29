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

    static func tessSphere(_ c: SIMD3<Float>, r: Float,
                            tri: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) -> Void) {
        let LON = 12, LAT = 8, tau = 2 * Float.pi
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
    static func emitTube(_ a: SIMD3<Float>, _ b: SIMD3<Float>, r: Float, sides: Int = 10, _ m: Mat, caps: Bool = true, into v: inout [PVert]) {
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
                v += [vert(a, -d), vert(prevA, -d), vert(ca, -d)]      // near cap
                v += [vert(b, d), vert(cb, d), vert(prevB, d)]         // far cap
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
        emitTube(p - run * 0.052, p + run * 0.052, r: r * 1.34, sides: 9, body, caps: false, into: &v)   // the tee body on the main
        emitTube(p, p + branch * 0.055, r: r * 1.18, sides: 9, body, caps: false, into: &v)              // the branch socket
    }

    /// A 90° ELBOW: a fatter short sleeve on each leg where the two directions meet, so the corner reads as a
    /// cast fitting rather than two pipes mitred into each other.
    static func emitElbow(at p: SIMD3<Float>, legA: SIMD3<Float>, legB: SIMD3<Float>, r: Float, _ body: Mat, into v: inout [PVert]) {
        emitTube(p, p + legA * 0.055, r: r * 1.26, sides: 9, body, caps: false, into: &v)
        emitTube(p, p + legB * 0.055, r: r * 1.26, sides: 9, body, caps: false, into: &v)
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
}
