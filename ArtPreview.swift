// Citadel — art-direction preview harness (CITADEL_ARTPREVIEW[=dir]).
//
// NOT shipping code. Renders a side-by-side gallery of candidate art directions
// to ~/Desktop so the look can be chosen from real pixels rather than argument:
//
//   01 diagnosis    — same grunt: current 128px bake vs clean supersampled vs smooth
//   02 option A     — real-time 3D, hard-surface MECHANISED aliens (flat-shaded)
//   03 option B     — organic monster (smooth-shaded; proxy for asset-baked sprites)
//   04 option C     — procedural 2D pixel-art creature (SDF volume shading)
//   05 option D     — stylised crystalline / neon construct (flat-shaded + edge glow)
//
// The 3-D renders use a higher-quality path than the game (NxN supersample →
// box downsample with coverage alpha, optional Gouraud smooth shading, optional
// wire-edge glow) so they fairly represent live full-resolution rendering.

import Foundation
import AppKit
import simd

// ── extra primitives for the preview models ─────────────────────────────────
extension Model3 {
    /// Sphere scaled per-axis — organic muscle masses.
    mutating func ellipsoid(_ c: SIMD3<Float>, _ r: SIMD3<Float>, _ seg: Int, _ rings: Int, _ color: UInt32) {
        let base = v.count
        for ri in 0...rings {
            let theta = Float(ri) / Float(rings) * .pi
            let y = cos(theta), rr = sin(theta)
            for si in 0..<seg {
                let phi = Float(si) / Float(seg) * 2 * .pi
                v.append(c + SIMD3(cos(phi) * rr * r.x, y * r.y, sin(phi) * rr * r.z))
            }
        }
        for ri in 0..<rings { for si in 0..<seg {
            let a = base + ri * seg + si, b = base + ri * seg + (si + 1) % seg
            let cc = base + (ri + 1) * seg + si, d = base + (ri + 1) * seg + (si + 1) % seg
            t.append(Tri3(a: a, b: b, c: d, color: color)); t.append(Tri3(a: a, b: d, c: cc, color: color))
        } }
    }

    /// Tapered prism between two arbitrary points — crystal shards, horns, claws.
    mutating func shard(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ r0: Float, _ r1: Float, _ sides: Int, _ color: UInt32) {
        let axis = simd_normalize(p1 - p0)
        let up: SIMD3<Float> = abs(axis.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let u = simd_normalize(simd_cross(up, axis)), w = simd_cross(axis, u)
        let base = v.count
        for k in 0..<sides {
            let a = Float(k) / Float(sides) * 2 * .pi
            let dir = u * cos(a) + w * sin(a)
            v.append(p0 + dir * r0); v.append(p1 + dir * r1)
        }
        let cap0 = v.count; v.append(p0)
        let cap1 = v.count; v.append(p1)
        for k in 0..<sides {
            let a0 = base + k * 2, b0 = base + ((k + 1) % sides) * 2
            t.append(Tri3(a: a0, b: b0, c: a0 + 1, color: color))
            t.append(Tri3(a: b0, b: b0 + 1, c: a0 + 1, color: color))
            t.append(Tri3(a: cap0, b: b0, c: a0, color: color))
            t.append(Tri3(a: cap1, b: a0 + 1, c: b0 + 1, color: color))
        }
    }
}

enum ArtPreview {
    static let lightDir = simd_normalize(SIMD3<Float>(-0.42, 0.74, -0.55))

    // ── high-quality mesh render (supersample + AA + optional smooth/edge) ───
    private static func vertexNormals(_ m: Model3) -> [SIMD3<Float>] {
        var n = [SIMD3<Float>](repeating: .zero, count: m.v.count)
        let cen = m.centroid
        for tri in m.t {
            let p0 = m.v[tri.a], p1 = m.v[tri.b], p2 = m.v[tri.c]
            var fn = simd_cross(p1 - p0, p2 - p0)
            if simd_dot(fn, (p0 + p1 + p2) / 3 - cen) < 0 { fn = -fn }
            n[tri.a] += fn; n[tri.b] += fn; n[tri.c] += fn
        }
        return n.map { simd_length($0) > 1e-6 ? simd_normalize($0) : SIMD3<Float>(0, 1, 0) }
    }

    /// Render `model` to a `w×h` straight-alpha RGBA tile (transparent where empty).
    static func render(_ m: Model3, pitch: Float, yaw: Float, t: SIMD3<Float>, f: Float,
                       w: Int, h: Int, ss: Int = 3, ambient: Float = 0.34, diffuse: Float = 0.72,
                       smooth: Bool = false, edgeGlow: UInt32? = nil) -> [UInt32] {
        let W = w * ss, H = h * ss, F = f * Float(ss)
        var px = [UInt32](repeating: 0, count: W * H)
        var depth = [Float](repeating: .greatestFiniteMagnitude, count: W * H)
        let cx = Float(W) / 2, cy = Float(H) / 2
        let sp = sin(pitch), cp = cos(pitch), sy = sin(yaw), cyw = cos(yaw)
        func rY(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(p.x * cyw + p.z * sy, p.y, -p.x * sy + p.z * cyw) }
        func rX(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(p.x, p.y * cp - p.z * sp, p.y * sp + p.z * cp) }
        func xform(_ p: SIMD3<Float>) -> SIMD3<Float> { rX(rY(p)) + t }
        func xnorm(_ nn: SIMD3<Float>) -> SIMD3<Float> { rX(rY(nn)) }
        func lit(_ nn: SIMD3<Float>) -> Float { ambient + diffuse * max(0, simd_dot(nn, lightDir)) }
        let cen = xform(m.centroid)
        let vn = smooth ? vertexNormals(m) : []

        for tri in m.t {
            let p0 = xform(m.v[tri.a]), p1 = xform(m.v[tri.b]), p2 = xform(m.v[tri.c])
            if p0.z < 0.05 || p1.z < 0.05 || p2.z < 0.05 { continue }
            var fn = simd_normalize(simd_cross(p1 - p0, p2 - p0))
            if simd_dot(fn, (p0 + p1 + p2) / 3 - cen) < 0 { fn = -fn }
            let l0: Float, l1: Float, l2: Float
            if smooth {
                l0 = lit(xnorm(vn[tri.a])); l1 = lit(xnorm(vn[tri.b])); l2 = lit(xnorm(vn[tri.c]))
            } else { let l = lit(fn); l0 = l; l1 = l; l2 = l }
            let s0 = SIMD3(cx + p0.x / p0.z * F, cy - p0.y / p0.z * F, p0.z)
            let s1 = SIMD3(cx + p1.x / p1.z * F, cy - p1.y / p1.z * F, p1.z)
            let s2 = SIMD3(cx + p2.x / p2.z * F, cy - p2.y / p2.z * F, p2.z)
            raster(s0, s1, s2, tri.color, l0, l1, l2, &px, &depth, W, H, edgeGlow)
        }
        return downsample(px, W, H, w, h, ss)
    }

    private static func raster(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ base: UInt32,
                               _ la: Float, _ lb: Float, _ lc: Float,
                               _ px: inout [UInt32], _ depth: inout [Float], _ w: Int, _ h: Int, _ edgeGlow: UInt32?) {
        let minx = max(0, Int(floor(min(a.x, b.x, c.x)))), maxx = min(w - 1, Int(ceil(max(a.x, b.x, c.x))))
        let miny = max(0, Int(floor(min(a.y, b.y, c.y)))), maxy = min(h - 1, Int(ceil(max(a.y, b.y, c.y))))
        if minx > maxx || miny > maxy { return }
        func edge(_ ax: Float, _ ay: Float, _ bx: Float, _ by: Float, _ px2: Float, _ py2: Float) -> Float {
            (bx - ax) * (py2 - ay) - (by - ay) * (px2 - ax)
        }
        let area = edge(a.x, a.y, b.x, b.y, c.x, c.y)
        if abs(area) < 0.0001 { return }
        let inv = 1 / area
        for py in miny...maxy { for pxX in minx...maxx {
            let fx = Float(pxX) + 0.5, fy = Float(py) + 0.5
            let w0 = edge(b.x, b.y, c.x, c.y, fx, fy) * inv
            let w1 = edge(c.x, c.y, a.x, a.y, fx, fy) * inv
            let w2 = edge(a.x, a.y, b.x, b.y, fx, fy) * inv
            if w0 < 0 || w1 < 0 || w2 < 0 { continue }
            let z = w0 * a.z + w1 * b.z + w2 * c.z
            let idx = py * w + pxX
            if z >= depth[idx] { continue }
            depth[idx] = z
            var col = shade(base, w0 * la + w1 * lb + w2 * lc)
            if let eg = edgeGlow {
                let m = min(w0, min(w1, w2))
                if m < 0.014 { col = mixRGBA(col, eg, 1 - m / 0.014) }
            }
            px[idx] = col | 0xFF00_0000
        } }
    }

    /// Box-downsample with coverage → straight-alpha (AA against any backdrop).
    private static func downsample(_ src: [UInt32], _ W: Int, _ H: Int, _ w: Int, _ h: Int, _ ss: Int) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: w * h)
        let total = Float(ss * ss)
        for y in 0..<h { for x in 0..<w {
            var r: Float = 0, g: Float = 0, b: Float = 0, cov = 0
            for sy in 0..<ss { let row = (y * ss + sy) * W
                for sx in 0..<ss {
                    let c = src[row + x * ss + sx]
                    if (c >> 24) == 0 { continue }
                    r += Float(c & 0xFF); g += Float((c >> 8) & 0xFF); b += Float((c >> 16) & 0xFF); cov += 1
                } }
            if cov == 0 { continue }
            let fc = 1 / Float(cov)
            out[y * w + x] = packRGBA(Int(r * fc), Int(g * fc), Int(b * fc), Int((Float(cov) / total * 255).rounded()))
        } }
        return out
    }

    // ── sheet helpers ────────────────────────────────────────────────────────
    private static func sheet(_ w: Int, _ h: Int, top: UInt32, bottom: UInt32) -> Canvas2D {
        let c = Canvas2D(width: w, height: h)
        for y in 0..<h { c.hLine(0, w - 1, y, mixRGBA(top, bottom, Float(y) / Float(h))) }
        for y in 0..<h {            // vignette
            let e = max(0, 1 - Float(min(y, h - 1 - y)) / 70)
            if e > 0 { c.fillRectBlend(0, y, w, 1, packRGBA(0, 0, 0), e * 0.4) }
        }
        return c
    }
    private static func shadow(_ c: Canvas2D, _ cx: Int, _ cy: Int, _ rx: Int, _ ry: Int) {
        for j in -ry...ry { for i in -rx...rx {
            let d = Float(i * i) / Float(rx * rx) + Float(j * j) / Float(ry * ry)
            if d < 1 { c.blend(cx + i, cy + j, packRGBA(0, 0, 0), (1 - d) * 0.42) }
        } }
    }
    /// Centre a tile on a stage at (cx, groundY) with a contact shadow.
    private static func stage(_ c: Canvas2D, _ tile: [UInt32], _ tw: Int, _ th: Int, _ cx: Int, _ groundY: Int) {
        shadow(c, cx, groundY, tw / 3, max(8, th / 18))
        c.blitBitmap(tile, tw, th, cx - tw / 2, groundY - th + 6)
    }

    // ════════════════════════════════════════════════════════════════════════
    static func run(outDir: String?) {
        let base = outDir ?? (NSHomeDirectory() + "/Desktop")
        let dir = URL(fileURLWithPath: base).appendingPathComponent("Citadel-Art-Options")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func write(_ c: Canvas2D, _ name: String) {
            Captures.writePNG(c.framebuffer, w: c.width, h: c.height, scale: 1, to: dir.appendingPathComponent(name))
            print("  wrote \(name)")
        }
        let amber = packRGBA(240, 196, 96), ink = packRGBA(208, 212, 222), dim = packRGBA(150, 154, 168)

        // ── 01 diagnosis ─────────────────────────────────────────────────────
        do {
            let c = sheet(1180, 760, top: packRGBA(20, 16, 22), bottom: packRGBA(34, 24, 30))
            c.labelCentered("WHY IT LOOKS BLOCKY — HALF OF IT IS THE BAKE", 34, size: 34, color: amber, weight: .heavy)
            c.labelCentered("Identical geometry, rendered three ways. The game currently ships (1).", 78, size: 19, color: dim, weight: .medium)
            let model = MeshMonsters.previewModel(.alien)
            let tw = 240, th = 320, gy = 600
            // (1) current shipping bake — the real 128px sprite, nearest-upscaled
            let baked = Sprites.shared.monster(.alien).walk[0][0]
            let bscale = 2
            shadow(c, 200, gy, baked.w * bscale / 3, 14)
            c.blitBitmap(baked.pixels, baked.w, baked.h, 200 - baked.w * bscale / 2, gy - baked.h * bscale + 6, scale: bscale)
            // (2) same model, clean supersampled flat render
            let flat = render(model, pitch: -0.05, yaw: 0, t: SIMD3(0, -1.25, 5.6), f: 680, w: tw, h: th, ss: 3)
            stage(c, flat, tw, th, 590, gy)
            // (3) + smooth (gouraud) shading
            let sm = render(model, pitch: -0.05, yaw: 0, t: SIMD3(0, -1.25, 5.6), f: 680, w: tw, h: th, ss: 3, smooth: true)
            stage(c, sm, tw, th, 980, gy)
            c.label("1 — SHIPPING NOW  (128px bake, flat)", 96, gy + 22, size: 18, color: ink, weight: .bold)
            c.label("2 — RENDERED CLEAN  (full-res, AA)", 470, gy + 22, size: 18, color: packRGBA(150, 220, 160), weight: .bold)
            c.label("3 — + SMOOTH SHADING", 880, gy + 22, size: 18, color: packRGBA(150, 220, 160), weight: .bold)
            c.labelCentered("The same primitive imp still reads as primitives — but the bake is throwing away most of the quality before you ever see it.", 716, size: 18, color: dim, weight: .medium)
            write(c, "01-diagnosis.png")
        }

        // ── 02 option A — mechanised, hard-surface (flat-shaded, the pitch) ────
        do {
            let c = sheet(1180, 780, top: packRGBA(14, 16, 22), bottom: packRGBA(26, 30, 40))
            c.labelCentered("OPTION A — REAL-TIME 3D, HARD-SURFACE ALIENS", 34, size: 32, color: amber, weight: .heavy)
            c.labelCentered("Flat-shaded low-poly — exactly the Strataris technique — on subjects it nails: machines. 100% procedural, zero assets.", 78, size: 18, color: dim, weight: .medium)
            let gy = 640
            stage(c, render(sentinel(), pitch: -0.04, yaw: 0.5, t: SIMD3(0, -1.45, 6.6), f: 980, w: 300, h: 440, ss: 3), 300, 440, 230, gy)
            stage(c, render(warden(), pitch: -0.04, yaw: -0.55, t: SIMD3(0, -1.7, 7.4), f: 980, w: 320, h: 460, ss: 3), 320, 460, 590, gy)
            stage(c, render(stalkerDrone(), pitch: -0.02, yaw: 0.6, t: SIMD3(0, -1.15, 6.2), f: 980, w: 300, h: 420, ss: 3), 300, 420, 950, gy)
            c.label("SENTINEL", 165, gy + 22, size: 19, color: ink, weight: .bold)
            c.label("WARDEN", 540, gy + 22, size: 19, color: ink, weight: .bold)
            c.label("STALKER-DRONE", 880, gy + 22, size: 19, color: ink, weight: .bold)
            c.labelCentered("Every facet reads as a hull panel, not a lump — and machines fit the universe (Strataris' aliens are craft).", 736, size: 18, color: packRGBA(150, 200, 230), weight: .medium)
            write(c, "02-optionA-mechanised.png")
        }

        // ── 03 option B — organic monster (smooth-shaded proxy for assets) ─────
        do {
            let c = sheet(1180, 780, top: packRGBA(22, 14, 16), bottom: packRGBA(38, 20, 22))
            c.labelCentered("OPTION B — ORGANIC MONSTERS (ASSET-BAKED SPRITES)", 34, size: 31, color: amber, weight: .heavy)
            c.labelCentered("Below: the best organic I can do procedurally (smooth-shaded). Real Blender-modelled, textured sprites would clearly exceed even this.", 78, size: 16, color: dim, weight: .medium)
            let gy = 660
            stage(c, render(demon(), pitch: -0.05, yaw: 0.45, t: SIMD3(0, -1.55, 6.8), f: 1000, w: 340, h: 470, ss: 3, ambient: 0.32, diffuse: 0.76, smooth: true), 340, 470, 360, gy)
            stage(c, render(maw(), pitch: -0.03, yaw: 0.3, t: SIMD3(0, -1.2, 6.0), f: 1000, w: 320, h: 430, ss: 3, ambient: 0.34, diffuse: 0.74, smooth: true), 320, 430, 820, gy)
            c.label("smooth-shaded procedural proxy", 230, gy + 22, size: 17, color: dim, weight: .medium)
            c.label("smooth-shaded procedural proxy", 700, gy + 22, size: 17, color: dim, weight: .medium)
            c.labelCentered("Trade-off: this is the quality ceiling — but it BREAKS the ~1 MB zero-asset brand hook and needs a real modelling / render pipeline.", 736, size: 18, color: packRGBA(230, 160, 160), weight: .medium)
            write(c, "03-optionB-organic.png")
        }

        // ── 04 option C — procedural 2D pixel art ──────────────────────────────
        do {
            let c = sheet(1180, 780, top: packRGBA(16, 18, 16), bottom: packRGBA(28, 32, 28))
            c.labelCentered("OPTION C — PROCEDURAL 2D PIXEL ART", 34, size: 32, color: amber, weight: .heavy)
            c.labelCentered("No 3D at all — sprites painted in code (SDF volume shading). How the ORIGINAL Doom did it. Zero assets; organic possible; hardest to nail.", 78, size: 18, color: dim, weight: .medium)
            let gy = 660
            stage(c, pixelImp(300, 420, hue: 0), 300, 420, 360, gy)
            stage(c, pixelImp(300, 420, hue: 1), 300, 420, 820, gy)
            c.label("painted sprite — 2 colourways", 250, gy + 22, size: 17, color: dim, weight: .medium)
            c.labelCentered("Volume from a distance field, rim light, glowing eyes — all generated. Genuinely good 2D is slow, iterative work with an uncertain ceiling.", 736, size: 16, color: packRGBA(160, 220, 170), weight: .medium)
            write(c, "04-optionC-pixelart.png")
        }

        // ── 05 option D — crystalline / neon ───────────────────────────────────
        do {
            let c = sheet(1180, 780, top: packRGBA(8, 10, 22), bottom: packRGBA(16, 12, 32))
            c.labelCentered("OPTION D — STYLISED CRYSTALLINE / NEON", 34, size: 32, color: amber, weight: .heavy)
            c.labelCentered("Lean INTO geometry: faceted crystal horrors with glowing edges. Plays to procedural strengths; fully on-brand; low risk.", 78, size: 18, color: dim, weight: .medium)
            let gy = 650
            stage(c, render(shardWraith(), pitch: -0.04, yaw: 0.5, t: SIMD3(0, -1.5, 6.8), f: 980, w: 340, h: 470, ss: 3,
                            ambient: 0.5, diffuse: 0.5, edgeGlow: packRGBA(180, 245, 255)), 340, 470, 360, gy)
            stage(c, render(prismFiend(), pitch: -0.03, yaw: -0.5, t: SIMD3(0, -1.4, 6.6), f: 980, w: 320, h: 450, ss: 3,
                            ambient: 0.52, diffuse: 0.46, edgeGlow: packRGBA(255, 150, 230)), 320, 450, 820, gy)
            c.label("SHARD-WRAITH", 290, gy + 22, size: 19, color: packRGBA(170, 235, 255), weight: .bold)
            c.label("PRISM-FIEND", 760, gy + 22, size: 19, color: packRGBA(255, 170, 235), weight: .bold)
            c.labelCentered("A different vibe — TRON / Rez crystalline menace rather than fleshy horror. Cohesive and achievable now.", 726, size: 18, color: packRGBA(170, 200, 255), weight: .medium)
            write(c, "05-optionD-crystalline.png")
        }

        print("Citadel: art options written to \(dir.path)")
    }

    // ════════════════════════════════════════════════════════════════════════
    // MECHANISED (Option A) — feet at y=0, front toward -z, centred x=0
    // ════════════════════════════════════════════════════════════════════════
    private static func sentinel() -> Model3 {
        var m = Model3()
        let gun = packRGBA(96, 104, 120), dk = packRGBA(50, 54, 66), plate = packRGBA(126, 134, 150)
        let amber = packRGBA(255, 178, 70), eye = packRGBA(255, 214, 130), joint = packRGBA(38, 40, 50)
        // legs
        for sx in [Float(-0.28), 0.28] {
            m.box(SIMD3(sx, 0.07, -0.06), SIMD3(0.28, 0.14, 0.5), dk)      // foot
            m.box(SIMD3(sx, 0.46, 0), SIMD3(0.24, 0.68, 0.26), gun)        // shin
            m.box(SIMD3(sx, 0.86, 0), SIMD3(0.18, 0.16, 0.2), joint)       // knee
            m.box(SIMD3(sx, 1.16, 0), SIMD3(0.3, 0.6, 0.32), gun)          // thigh
        }
        m.box(SIMD3(0, 1.42, 0), SIMD3(0.74, 0.34, 0.42), dk)              // pelvis
        m.box(SIMD3(0, 1.86, 0), SIMD3(0.82, 0.74, 0.46), gun)            // torso
        m.box(SIMD3(0, 1.9, -0.25), SIMD3(0.62, 0.56, 0.06), plate)       // chest plate
        m.box(SIMD3(0, 1.98, -0.3), SIMD3(0.18, 0.18, 0.05), amber)       // chest light
        m.box(SIMD3(0, 1.86, 0.26), SIMD3(0.52, 0.6, 0.16), dk)           // backpack
        // shoulders + arms
        for sx in [Float(-0.56), 0.56] {
            m.box(SIMD3(sx, 2.14, 0), SIMD3(0.36, 0.32, 0.46), plate)      // pauldron
            m.box(SIMD3(sx, 2.28, 0), SIMD3(0.3, 0.12, 0.4), gun)
            m.box(SIMD3(sx, 1.78, 0.02), SIMD3(0.22, 0.5, 0.24), gun)      // upper arm
            m.box(SIMD3(sx, 1.36, -0.06), SIMD3(0.24, 0.46, 0.26), dk)     // forearm
        }
        m.cylZ(0.56, 1.36, -0.45, 0.4, 0.12, 8, joint)                     // right wrist-gun barrel
        m.box(SIMD3(0.56, 1.36, -0.2), SIMD3(0.3, 0.3, 0.3), gun)
        // head
        m.box(SIMD3(0, 2.32, 0), SIMD3(0.36, 0.16, 0.4), dk)              // neck/collar
        m.box(SIMD3(0, 2.54, -0.02), SIMD3(0.36, 0.34, 0.38), gun)        // head
        m.box(SIMD3(0, 2.54, -0.22), SIMD3(0.3, 0.09, 0.05), eye)         // visor slit
        m.cylY(0.12, 0.05, 2.72, 3.0, 0.03, 6, plate)                      // antenna
        return m
    }

    private static func warden() -> Model3 {
        var m = Model3()
        let steel = packRGBA(120, 86, 70), dk = packRGBA(64, 44, 36), plate = packRGBA(150, 112, 92)
        let hot = packRGBA(255, 130, 50), core = packRGBA(255, 224, 150), joint = packRGBA(40, 34, 30)
        for sx in [Float(-0.44), 0.44] {
            m.box(SIMD3(sx, 0.1, -0.05), SIMD3(0.46, 0.2, 0.7), dk)        // big foot
            m.box(SIMD3(sx, 0.6, 0), SIMD3(0.4, 0.9, 0.42), steel)         // leg
            m.box(SIMD3(sx, 1.1, 0), SIMD3(0.3, 0.2, 0.26), joint)
        }
        m.box(SIMD3(0, 1.5, 0.05), SIMD3(1.1, 0.5, 0.6), dk)              // hips
        m.box(SIMD3(0, 2.05, 0.08), SIMD3(1.3, 0.86, 0.74), steel)        // huge torso (hunched fwd)
        m.box(SIMD3(0, 2.05, -0.36), SIMD3(0.9, 0.66, 0.08), plate)       // chest plate
        m.sphereMesh(SIMD3(0, 2.05, -0.42), 0.2, 9, 7, hot)               // glowing core
        m.sphereMesh(SIMD3(0, 2.05, -0.5), 0.09, 6, 5, core)
        // exhaust stacks
        for sx in [Float(-0.3), 0.0, 0.3] { m.cylY(sx, 0.5, 2.5, 2.95, 0.08, 6, joint) }
        // shoulders (massive) + small sunk head between
        for sx in [Float(-0.78), 0.78] {
            m.box(SIMD3(sx, 2.5, 0.05), SIMD3(0.56, 0.5, 0.66), plate)
            m.box(SIMD3(sx, 2.74, 0.05), SIMD3(0.46, 0.16, 0.5), steel)
        }
        m.box(SIMD3(0, 2.46, -0.1), SIMD3(0.4, 0.36, 0.4), dk)            // head (sunk)
        m.box(SIMD3(0, 2.46, -0.32), SIMD3(0.3, 0.08, 0.05), hot)        // eye band
        // right arm = cannon, left = clamp
        m.box(SIMD3(0.86, 1.95, 0.05), SIMD3(0.34, 0.66, 0.36), steel)
        m.cylZ(0.86, 1.7, -0.7, 0.5, 0.22, 10, dk)                        // cannon barrel
        m.cylZ(0.86, 1.7, -0.74, -0.5, 0.12, 8, hot)
        m.box(SIMD3(-0.86, 1.95, 0.05), SIMD3(0.34, 0.66, 0.36), steel)
        m.box(SIMD3(-0.86, 1.5, -0.18), SIMD3(0.14, 0.4, 0.3), joint)     // clamp prongs
        m.box(SIMD3(-0.86, 1.5, 0.18), SIMD3(0.14, 0.4, 0.3), joint)
        return m
    }

    private static func stalkerDrone() -> Model3 {
        var m = Model3()
        let gun = packRGBA(104, 110, 126), dk = packRGBA(54, 58, 70), plate = packRGBA(132, 140, 156)
        let glow = packRGBA(120, 220, 255), hot = packRGBA(220, 245, 255)
        m.box(SIMD3(0, 1.3, 0.04), SIMD3(0.78, 0.56, 0.66), gun)          // core pod
        m.box(SIMD3(0, 1.3, -0.34), SIMD3(0.5, 0.5, 0.06), plate)         // face plate
        m.sphereMesh(SIMD3(0, 1.3, -0.42), 0.26, 10, 8, dk)               // eye housing
        m.sphereMesh(SIMD3(0, 1.3, -0.56), 0.17, 9, 7, glow)              // optic
        m.sphereMesh(SIMD3(0, 1.3, -0.66), 0.07, 6, 5, hot)
        // side thruster fins (angled blades)
        m.shard(SIMD3(-0.42, 1.42, 0.1), SIMD3(-0.9, 1.66, 0.2), 0.14, 0.04, 4, plate)
        m.shard(SIMD3(0.42, 1.42, 0.1), SIMD3(0.9, 1.66, 0.2), 0.14, 0.04, 4, plate)
        m.shard(SIMD3(-0.4, 1.2, 0.1), SIMD3(-0.78, 0.96, 0.16), 0.12, 0.03, 4, gun)
        m.shard(SIMD3(0.4, 1.2, 0.1), SIMD3(0.78, 0.96, 0.16), 0.12, 0.03, 4, gun)
        // hanging claws (menace)
        for sx in [Float(-0.24), 0.24] { m.shard(SIMD3(sx, 1.04, -0.2), SIMD3(sx * 1.6, 0.5, -0.3), 0.09, 0.0, 4, dk) }
        m.cylY(0, 0.0, 1.58, 1.84, 0.03, 6, plate)                        // top sensor mast
        m.sphereMesh(SIMD3(0, 1.86, 0), 0.06, 6, 5, glow)
        return m
    }

    // ════════════════════════════════════════════════════════════════════════
    // ORGANIC (Option B proxy) — smooth-shaded
    // ════════════════════════════════════════════════════════════════════════
    private static func demon() -> Model3 {
        var m = Model3()
        let flesh = packRGBA(150, 70, 58), dark = packRGBA(96, 40, 36), horn = packRGBA(208, 196, 168)
        let eye = packRGBA(255, 196, 70), claw = packRGBA(222, 212, 188)
        for sx in [Float(-0.3), 0.3] {
            m.ellipsoid(SIMD3(sx, 0.5, 0), SIMD3(0.22, 0.52, 0.24), 10, 8, dark)    // thigh+calf mass
            m.ellipsoid(SIMD3(sx, 1.0, -0.02), SIMD3(0.2, 0.4, 0.22), 10, 8, flesh)
            m.box(SIMD3(sx, 0.06, -0.1), SIMD3(0.26, 0.12, 0.42), dark)             // hoof
        }
        m.ellipsoid(SIMD3(0, 1.55, -0.02), SIMD3(0.46, 0.5, 0.36), 12, 9, flesh)    // torso
        m.ellipsoid(SIMD3(0, 1.18, 0.02), SIMD3(0.36, 0.34, 0.3), 11, 8, dark)      // gut
        // arms reaching slightly forward
        for sx in [Float(-0.52), 0.52] {
            m.ellipsoid(SIMD3(sx, 1.62, -0.04), SIMD3(0.2, 0.34, 0.22), 10, 8, flesh)   // upper
            m.ellipsoid(SIMD3(sx * 1.05, 1.18, -0.18), SIMD3(0.17, 0.32, 0.2), 10, 8, dark)  // fore
            for c in 0..<3 { m.shard(SIMD3(sx * 1.05 + Float(c - 1) * 0.1, 0.95, -0.28), SIMD3(sx * 1.05 + Float(c - 1) * 0.12, 0.78, -0.42), 0.05, 0.0, 4, claw) }
        }
        m.ellipsoid(SIMD3(-0.46, 1.94, 0), SIMD3(0.2, 0.18, 0.2), 9, 7, flesh)      // shoulders
        m.ellipsoid(SIMD3(0.46, 1.94, 0), SIMD3(0.2, 0.18, 0.2), 9, 7, flesh)
        m.ellipsoid(SIMD3(0, 2.12, -0.04), SIMD3(0.27, 0.28, 0.27), 12, 9, flesh)   // head
        m.ellipsoid(SIMD3(0, 2.02, -0.24), SIMD3(0.2, 0.12, 0.12), 9, 7, flesh)     // snout/brow
        // horns sweeping back
        m.shard(SIMD3(-0.16, 2.32, 0.02), SIMD3(-0.34, 2.74, 0.3), 0.07, 0.0, 5, horn)
        m.shard(SIMD3(0.16, 2.32, 0.02), SIMD3(0.34, 2.74, 0.3), 0.07, 0.0, 5, horn)
        // glowing eyes
        m.sphereMesh(SIMD3(-0.1, 2.14, -0.27), 0.05, 6, 5, eye)
        m.sphereMesh(SIMD3(0.1, 2.14, -0.27), 0.05, 6, 5, eye)
        // teeth
        for tt in 0..<5 { m.box(SIMD3(-0.12 + Float(tt) * 0.06, 1.96, -0.3), SIMD3(0.03, 0.06, 0.03), horn) }
        return m
    }

    private static func maw() -> Model3 {   // a cacodemon-style floating maw
        var m = Model3()
        let body = packRGBA(140, 58, 64), dark = packRGBA(92, 34, 42), tooth = packRGBA(224, 218, 198)
        let eye = packRGBA(250, 240, 250), pupil = packRGBA(220, 50, 50)
        m.ellipsoid(SIMD3(0, 1.3, 0), SIMD3(0.66, 0.6, 0.58), 14, 11, body)         // bulb
        // gaping mouth
        m.ellipsoid(SIMD3(0, 1.08, -0.4), SIMD3(0.34, 0.16, 0.18), 10, 7, packRGBA(40, 10, 16))
        for tt in 0..<7 { let x = -0.26 + Float(tt) * 0.087; m.box(SIMD3(x, 1.18, -0.5), SIMD3(0.05, 0.1, 0.05), tooth); m.box(SIMD3(x, 1.0, -0.5), SIMD3(0.05, 0.09, 0.05), tooth) }
        // big eye
        m.sphereMesh(SIMD3(0, 1.42, -0.42), 0.22, 12, 9, eye)
        m.sphereMesh(SIMD3(0, 1.44, -0.58), 0.1, 9, 7, pupil)
        // horns + spines around
        for a in stride(from: 0, to: 360, by: 40) {
            let r = Float(a) * .pi / 180
            m.shard(SIMD3(cos(r) * 0.56, 1.3 + sin(r) * 0.5, 0.16), SIMD3(cos(r) * 0.84, 1.3 + sin(r) * 0.78, 0.34), 0.07, 0.0, 4, dark)
        }
        return m
    }

    // ════════════════════════════════════════════════════════════════════════
    // CRYSTALLINE (Option D)
    // ════════════════════════════════════════════════════════════════════════
    private static func shardWraith() -> Model3 {
        var m = Model3()
        let ice = packRGBA(120, 210, 250), deep = packRGBA(70, 130, 210), violet = packRGBA(160, 130, 245)
        let coreC = packRGBA(235, 250, 255)
        m.shard(SIMD3(0, 0.5, 0), SIMD3(0, 2.4, 0), 0.3, 0.05, 4, ice)             // body spire
        m.sphereMesh(SIMD3(0, 1.4, -0.06), 0.34, 10, 8, coreC)                     // glowing core
        // arms
        m.shard(SIMD3(-0.2, 1.7, 0), SIMD3(-0.95, 1.25, -0.1), 0.14, 0.0, 4, deep)
        m.shard(SIMD3(0.2, 1.7, 0), SIMD3(0.95, 1.3, -0.1), 0.14, 0.0, 4, deep)
        // shoulder spikes
        m.shard(SIMD3(-0.22, 1.85, 0), SIMD3(-0.6, 2.7, 0.1), 0.12, 0.0, 4, violet)
        m.shard(SIMD3(0.22, 1.85, 0), SIMD3(0.62, 2.75, 0.1), 0.12, 0.0, 4, violet)
        // legs / trailing shards
        m.shard(SIMD3(-0.16, 0.9, 0), SIMD3(-0.42, 0.0, 0.12), 0.13, 0.0, 4, deep)
        m.shard(SIMD3(0.16, 0.9, 0), SIMD3(0.42, 0.0, 0.12), 0.13, 0.0, 4, deep)
        // back fins
        m.shard(SIMD3(0, 1.6, 0.18), SIMD3(0, 2.5, 0.7), 0.16, 0.0, 4, violet)
        m.shard(SIMD3(-0.12, 1.3, 0.18), SIMD3(-0.3, 1.9, 0.7), 0.1, 0.0, 4, ice)
        m.shard(SIMD3(0.12, 1.3, 0.18), SIMD3(0.3, 1.9, 0.7), 0.1, 0.0, 4, ice)
        // eyes
        m.sphereMesh(SIMD3(-0.1, 1.95, -0.18), 0.05, 6, 5, coreC)
        m.sphereMesh(SIMD3(0.1, 1.95, -0.18), 0.05, 6, 5, coreC)
        // floating debris shards
        m.shard(SIMD3(-0.7, 2.2, -0.2), SIMD3(-0.55, 2.45, -0.1), 0.06, 0.0, 4, ice)
        m.shard(SIMD3(0.74, 0.6, -0.2), SIMD3(0.6, 0.85, -0.1), 0.06, 0.0, 4, ice)
        return m
    }

    private static func prismFiend() -> Model3 {
        var m = Model3()
        let mag = packRGBA(230, 90, 200), rose = packRGBA(255, 150, 230), gold = packRGBA(255, 210, 140)
        let core = packRGBA(255, 240, 250)
        // squat angular crystal beast — quad legs, low body, crested head
        m.sphereMesh(SIMD3(0, 1.1, 0), 0.4, 10, 8, core)                           // core
        m.shard(SIMD3(0, 0.7, 0.1), SIMD3(0, 1.7, -0.2), 0.36, 0.08, 4, mag)       // body
        // four legs
        for (sx, sz) in [(Float(-0.3), Float(-0.2)), (0.3, -0.2), (-0.3, 0.3), (0.3, 0.3)] {
            m.shard(SIMD3(sx, 0.85, sz), SIMD3(sx * 1.4, 0.0, sz), 0.12, 0.0, 4, rose)
        }
        // head crest forward
        m.shard(SIMD3(0, 1.45, -0.2), SIMD3(0, 1.75, -0.85), 0.2, 0.04, 4, mag)
        m.shard(SIMD3(0, 1.6, -0.3), SIMD3(0, 2.25, -0.4), 0.12, 0.0, 4, gold)     // crest spike
        // jaw spikes
        m.sphereMesh(SIMD3(-0.07, 1.62, -0.6), 0.045, 6, 5, core)
        m.sphereMesh(SIMD3(0.07, 1.62, -0.6), 0.045, 6, 5, core)
        // back spikes
        for i in 0..<3 { m.shard(SIMD3(0, 1.4 + Float(i) * 0.12, 0.2 + Float(i) * 0.18), SIMD3(0, 1.9 + Float(i) * 0.12, 0.5 + Float(i) * 0.2), 0.1, 0.0, 4, rose) }
        return m
    }

    // ════════════════════════════════════════════════════════════════════════
    // 2D PIXEL ART (Option C) — SDF volume shading, no 3D
    // ════════════════════════════════════════════════════════════════════════
    private static func pixelImp(_ w: Int, _ h: Int, hue: Int) -> [UInt32] {
        // skin colourways
        let skin: SIMD3<Float> = hue == 0 ? SIMD3(150, 78, 60) : SIMD3(96, 120, 78)
        let skinDk: SIMD3<Float> = hue == 0 ? SIMD3(70, 30, 26) : SIMD3(42, 60, 36)
        let bone = SIMD3<Float>(214, 204, 178), boneDk = SIMD3<Float>(120, 110, 90)
        let L = simd_normalize(SIMD2<Float>(-0.6, -0.8))   // light upper-left

        struct Shape { var seg: (SIMD2<Float>, SIMD2<Float>); var r: Float; var mat: Int }   // capsule; mat 0 skin,1 bone
        func P(_ x: Float, _ y: Float) -> SIMD2<Float> { SIMD2(x, y) }
        // layout (tile space). hunched imp, claws presented.
        let s: [Shape] = [
            Shape(seg: (P(132, 302), P(118, 384)), r: 17, mat: 0),   // L leg
            Shape(seg: (P(168, 302), P(182, 384)), r: 17, mat: 0),   // R leg
            Shape(seg: (P(112, 388), P(132, 392)), r: 12, mat: 0),   // L foot
            Shape(seg: (P(188, 388), P(168, 392)), r: 12, mat: 0),   // R foot
            Shape(seg: (P(150, 300), P(150, 212)), r: 40, mat: 0),   // torso
            Shape(seg: (P(150, 210), P(150, 158)), r: 34, mat: 0),   // chest / shoulders
            Shape(seg: (P(118, 196), P(86, 286)), r: 15, mat: 0),    // L arm
            Shape(seg: (P(182, 196), P(214, 286)), r: 15, mat: 0),   // R arm
            Shape(seg: (P(86, 286), P(78, 320)), r: 11, mat: 0),     // L hand
            Shape(seg: (P(214, 286), P(222, 320)), r: 11, mat: 0),   // R hand
            Shape(seg: (P(150, 150), P(150, 116)), r: 36, mat: 0),   // head
            Shape(seg: (P(126, 120), P(100, 52)), r: 9, mat: 1),     // L horn
            Shape(seg: (P(174, 120), P(200, 52)), r: 9, mat: 1),     // R horn
            Shape(seg: (P(74, 320), P(66, 346)), r: 5, mat: 1),      // L claws
            Shape(seg: (P(226, 320), P(234, 346)), r: 5, mat: 1),    // R claws
        ]
        func sdCap(_ p: SIMD2<Float>, _ sh: Shape) -> Float {
            let a = sh.seg.0, b = sh.seg.1, pa = p - a, ba = b - a
            let hh = max(0, min(1, simd_dot(pa, ba) / simd_dot(ba, ba)))
            return simd_length(pa - ba * hh) - sh.r
        }
        func smin(_ a: Float, _ b: Float, _ k: Float) -> (Float, Float) {  // returns (dist, mixToB)
            let hh = max(0, min(1, 0.5 + 0.5 * (b - a) / k))
            return (b * (1 - hh) + a * hh - k * hh * (1 - hh), hh)
        }
        // pass 1: distance + material + height
        var dist = [Float](repeating: 1e9, count: w * h)
        var matF = [Float](repeating: 0, count: w * h)   // 0 skin … 1 bone
        var hgt = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let p = SIMD2(Float(x), Float(y))
            var d = 1e9 as Float, mat = 0 as Float
            for sh in s {
                let dd = sdCap(p, sh)
                if d > 1e8 { d = dd; mat = Float(sh.mat); continue }
                let (nd, hh) = smin(d, dd, 16)
                d = nd; mat = mat * hh + Float(sh.mat) * (1 - hh)   // mix(b,a,h): a (current) weighted by h
            }
            let idx = y * w + x
            dist[idx] = d; matF[idx] = mat
            hgt[idx] = d < 0 ? sqrt(max(0, -d) / 50) : 0       // dome height inside
        } }
        // pass 2: shade from height-field normal
        var out = [UInt32](repeating: 0, count: w * h)
        func hAt(_ x: Int, _ y: Int) -> Float { (x < 0 || x >= w || y < 0 || y >= h) ? 0 : hgt[y * w + x] }
        func hash(_ x: Int, _ y: Int) -> Float { let n = (x * 374761393 + y * 668265263) & 0x7fffffff; return Float(n % 1000) / 1000 }
        for y in 0..<h { for x in 0..<w {
            let idx = y * w + x
            let d = dist[idx]
            if d > 1.2 { continue }                            // outside (with 1px AA band)
            let aa = Float(max(0, min(1, 0.5 - d)))            // coverage at the edge
            let nx = hAt(x - 1, y) - hAt(x + 1, y)
            let ny = hAt(x, y - 1) - hAt(x, y + 1)
            let n = simd_normalize(SIMD3<Float>(nx * 3, ny * 3, 0.9))
            var light = 0.36 + 0.7 * max(0, simd_dot(SIMD3(n.x, n.y, n.z), SIMD3(L.x, L.y, 0.55)))
            // rim light near silhouette, ambient occlusion in deep crevices
            let rim = pow(max(0, 1 - hgt[idx] * 2.2), 3) * max(0, -(n.x * L.x + n.y * L.y))
            light += rim * 0.5
            light *= 0.82 + 0.18 * (0.5 + hgt[idx])            // depth shade
            light += (hash(x, y) - 0.5) * 0.06                 // skin grain
            var base = mix3(skin, skinDk, max(0, min(1, 0.5 - hgt[idx] * 1.6)))
            if matF[idx] > 0.5 { base = mix3(bone, boneDk, max(0, min(1, 0.6 - hgt[idx]))) }
            var col = clampC(base * light)
            // glowing eyes
            for ex in [Float(134), 166] {
                let dd = simd_length(SIMD2(Float(x), Float(y)) - SIMD2(ex, 126))
                if dd < 9 { let g = 1 - dd / 9; col = mix3(col, SIMD3(255, 210, 70), g); if dd < 4 { col = SIMD3(255, 245, 200) } }
            }
            // mouth + teeth
            if y > 142 && y < 156 && x > 128 && x < 172 {
                col = SIMD3(24, 10, 12)
                if (x % 8 < 4) && (y < 149) { col = SIMD3(212, 202, 176) }   // upper teeth
            }
            out[idx] = packRGBA(Int(col.x), Int(col.y), Int(col.z), Int((aa * 255).rounded()))
        } }
        return out
    }

    private static func mix3(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a * (1 - t) + b * t }
    private static func clampC(_ c: SIMD3<Float>) -> SIMD3<Float> { SIMD3(min(255, max(0, c.x)), min(255, max(0, c.y)), min(255, max(0, c.z))) }
}
