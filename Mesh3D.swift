// Citadel — tiny software 3-D mesh renderer.
//
// The representational art (weapons now; monsters next) is built from low-poly
// geometry — boxes and cylinders — and rendered flat-shaded into an RGBA sprite
// tile by a barycentric triangle rasteriser with a per-pixel depth buffer. This
// is the Strataris technique (real form, flat-shaded), reproducing how Doom's
// own art was 3-D-derived. Faces are lit by a fixed directional light plus
// ambient; normals are oriented outward from the model centroid so winding
// doesn't matter. The resulting Sprite drops straight into the existing 2-D
// compositor (HUD viewmodel, and later the billboarded enemies).

import Foundation
import simd

struct Tri3 { let a: Int, b: Int, c: Int; let color: UInt32 }

struct Model3 {
    var v: [SIMD3<Float>] = []
    var t: [Tri3] = []

    mutating func box(_ c: SIMD3<Float>, _ s: SIMD3<Float>, _ color: UInt32) {
        let i = v.count
        let h = s * 0.5
        let signs: [(Float, Float, Float)] = [(-1, -1, -1), (1, -1, -1), (1, 1, -1), (-1, 1, -1),
                                              (-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)]
        for (dx, dy, dz) in signs { v.append(c + SIMD3(dx * h.x, dy * h.y, dz * h.z)) }
        let faces = [(0, 1, 2), (0, 2, 3), (4, 5, 6), (4, 6, 7), (0, 4, 7), (0, 7, 3),
                     (1, 5, 6), (1, 6, 2), (3, 7, 6), (3, 6, 2), (0, 1, 5), (0, 5, 4)]
        for (a, b, cc) in faces { t.append(Tri3(a: i + a, b: i + b, c: i + cc, color: color)) }
    }

    /// Cylinder with its axis along Z, centred at (cx, cy), spanning z0…z1.
    mutating func cylZ(_ cx: Float, _ cy: Float, _ z0: Float, _ z1: Float, _ r: Float, _ sides: Int, _ color: UInt32) {
        let base = v.count
        for k in 0..<sides {
            let a = Float(k) / Float(sides) * 2 * .pi
            v.append(SIMD3(cx + cos(a) * r, cy + sin(a) * r, z0))
            v.append(SIMD3(cx + cos(a) * r, cy + sin(a) * r, z1))
        }
        let cap0 = v.count; v.append(SIMD3(cx, cy, z0))
        let cap1 = v.count; v.append(SIMD3(cx, cy, z1))
        for k in 0..<sides {
            let a0 = base + k * 2, b0 = base + ((k + 1) % sides) * 2
            t.append(Tri3(a: a0, b: b0, c: a0 + 1, color: color))
            t.append(Tri3(a: b0, b: b0 + 1, c: a0 + 1, color: color))
            t.append(Tri3(a: cap0, b: a0, c: b0, color: color))
            t.append(Tri3(a: cap1, b: b0 + 1, c: a0 + 1, color: color))
        }
    }

    /// Cylinder with its axis along Y (grips, vertical posts), centred (cx, cz), y0…y1.
    mutating func cylY(_ cx: Float, _ cz: Float, _ y0: Float, _ y1: Float, _ r: Float, _ sides: Int, _ color: UInt32) {
        let base = v.count
        for k in 0..<sides {
            let a = Float(k) / Float(sides) * 2 * .pi
            v.append(SIMD3(cx + cos(a) * r, y0, cz + sin(a) * r))
            v.append(SIMD3(cx + cos(a) * r, y1, cz + sin(a) * r))
        }
        let cap0 = v.count; v.append(SIMD3(cx, y0, cz))
        let cap1 = v.count; v.append(SIMD3(cx, y1, cz))
        for k in 0..<sides {
            let a0 = base + k * 2, b0 = base + ((k + 1) % sides) * 2
            t.append(Tri3(a: a0, b: b0, c: a0 + 1, color: color))
            t.append(Tri3(a: b0, b: b0 + 1, c: a0 + 1, color: color))
            t.append(Tri3(a: cap0, b: b0, c: a0, color: color))
            t.append(Tri3(a: cap1, b: a0 + 1, c: b0 + 1, color: color))
        }
    }

    /// Low-poly UV sphere (faceted when seg/rings are small) — fists, joints.
    mutating func sphereMesh(_ c: SIMD3<Float>, _ r: Float, _ seg: Int, _ rings: Int, _ color: UInt32) {
        let base = v.count
        for ri in 0...rings {
            let theta = Float(ri) / Float(rings) * .pi
            let y = cos(theta) * r, rr = sin(theta) * r
            for si in 0..<seg {
                let phi = Float(si) / Float(seg) * 2 * .pi
                v.append(c + SIMD3(cos(phi) * rr, y, sin(phi) * rr))
            }
        }
        for ri in 0..<rings { for si in 0..<seg {
            let a = base + ri * seg + si, b = base + ri * seg + (si + 1) % seg
            let cc = base + (ri + 1) * seg + si, d = base + (ri + 1) * seg + (si + 1) % seg
            t.append(Tri3(a: a, b: b, c: d, color: color)); t.append(Tri3(a: a, b: d, c: cc, color: color))
        } }
    }

    var centroid: SIMD3<Float> {
        if v.isEmpty { return .zero }
        var s = SIMD3<Float>.zero
        for p in v { s += p }
        return s / Float(v.count)
    }
}

enum MeshRender {
    static let lightDir = simd_normalize(SIMD3<Float>(-0.45, 0.7, -0.55))
    static let ambient: Float = 0.4
    static let diffuse: Float = 0.62

    @inline(__always) private static func rotX(_ p: SIMD3<Float>, _ s: Float, _ c: Float) -> SIMD3<Float> {
        SIMD3(p.x, p.y * c - p.z * s, p.y * s + p.z * c)
    }
    @inline(__always) private static func rotY(_ p: SIMD3<Float>, _ s: Float, _ c: Float) -> SIMD3<Float> {
        SIMD3(p.x * c + p.z * s, p.y, -p.x * s + p.z * c)
    }

    /// Render `model` (rotated by pitch/yaw, translated to `t`) into a `w×h`
    /// RGBA tile via perspective projection. Returns transparent where empty.
    static func render(_ model: Model3, pitch: Float, yaw: Float, t: SIMD3<Float>,
                       f: Float, w: Int, h: Int) -> [UInt32] {
        var px = [UInt32](repeating: 0, count: w * h)
        var depth = [Float](repeating: .greatestFiniteMagnitude, count: w * h)
        let cx = Float(w) / 2, cy = Float(h) / 2
        let sp = sin(pitch), cp = cos(pitch), sy = sin(yaw), cyw = cos(yaw)

        func xform(_ p: SIMD3<Float>) -> SIMD3<Float> { rotX(rotY(p, sy, cyw), sp, cp) + t }
        let cen = xform(model.centroid)

        for tri in model.t {
            let p0 = xform(model.v[tri.a]), p1 = xform(model.v[tri.b]), p2 = xform(model.v[tri.c])
            if p0.z < 0.05 || p1.z < 0.05 || p2.z < 0.05 { continue }
            var n = simd_normalize(simd_cross(p1 - p0, p2 - p0))
            let faceC = (p0 + p1 + p2) / 3
            if simd_dot(n, faceC - cen) < 0 { n = -n }
            let lit = ambient + diffuse * max(0, simd_dot(n, lightDir))
            let color = shade(tri.color, lit)

            let s0 = SIMD3(cx + p0.x / p0.z * f, cy - p0.y / p0.z * f, p0.z)
            let s1 = SIMD3(cx + p1.x / p1.z * f, cy - p1.y / p1.z * f, p1.z)
            let s2 = SIMD3(cx + p2.x / p2.z * f, cy - p2.y / p2.z * f, p2.z)
            raster(s0, s1, s2, color, &px, &depth, w, h)
        }
        return px
    }

    private static func raster(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                               _ color: UInt32, _ px: inout [UInt32], _ depth: inout [Float], _ w: Int, _ h: Int) {
        let minx = max(0, Int(floor(min(a.x, b.x, c.x)))), maxx = min(w - 1, Int(ceil(max(a.x, b.x, c.x))))
        let miny = max(0, Int(floor(min(a.y, b.y, c.y)))), maxy = min(h - 1, Int(ceil(max(a.y, b.y, c.y))))
        if minx > maxx || miny > maxy { return }
        func edge(_ ax: Float, _ ay: Float, _ bx: Float, _ by: Float, _ px2: Float, _ py2: Float) -> Float {
            (bx - ax) * (py2 - ay) - (by - ay) * (px2 - ax)
        }
        let area = edge(a.x, a.y, b.x, b.y, c.x, c.y)
        if abs(area) < 0.001 { return }
        let inv = 1 / area
        for py in miny...maxy { for pxX in minx...maxx {
            let fx = Float(pxX) + 0.5, fy = Float(py) + 0.5
            let w0 = edge(b.x, b.y, c.x, c.y, fx, fy) * inv
            let w1 = edge(c.x, c.y, a.x, a.y, fx, fy) * inv
            let w2 = edge(a.x, a.y, b.x, b.y, fx, fy) * inv
            if w0 < 0 || w1 < 0 || w2 < 0 { continue }
            let z = w0 * a.z + w1 * b.z + w2 * c.z
            let idx = py * w + pxX
            if z < depth[idx] { depth[idx] = z; px[idx] = color }
        } }
    }

    static func projectPoint(_ p: SIMD3<Float>, pitch: Float, yaw: Float, t: SIMD3<Float>, f: Float, w: Int, h: Int) -> (Int, Int)? {
        let sp = sin(pitch), cp = cos(pitch), sy = sin(yaw), cyw = cos(yaw)
        let r = rotX(rotY(p, sy, cyw), sp, cp) + t
        if r.z < 0.05 { return nil }
        return (Int(Float(w) / 2 + r.x / r.z * f), Int(Float(h) / 2 - r.y / r.z * f))
    }
}

// ── Weapon viewmodels, built from low-poly geometry ──────────────────────────
enum MeshWeapons {
    static let TW = 300, TH = 244
    static let F: Float = 314

    static func frames(_ k: WeaponKind) -> [Sprite] {
        let (model, muzzle, flashColor, hasFlash) = build(k)
        return [render(model, muzzle: muzzle, flash: nil, recoil: 0),
                render(model, muzzle: muzzle, flash: hasFlash ? flashColor : nil, recoil: 0.32)]
    }

    /// The raw weapon geometry, for reuse as a floor pickup.
    static func model(_ k: WeaponKind) -> Model3 { build(k).0 }

    private static func render(_ model: Model3, muzzle: SIMD3<Float>, flash: UInt32?, recoil: Float) -> Sprite {
        let pitch: Float = -0.34 - (recoil > 0 ? 0.05 : 0)   // slight top-down view; barrel still aims forward
        let yaw: Float = 0                                    // centred → points straight at the crosshair
        let t = SIMD3<Float>(0, -1.0, 4.7 - recoil)           // held low-centre; recoil pulls toward camera
        var px = MeshRender.render(model, pitch: pitch, yaw: yaw, t: t, f: F, w: TW, h: TH)
        if let fc = flash, let (mx, my) = MeshRender.projectPoint(muzzle, pitch: pitch, yaw: yaw, t: t, f: F, w: TW, h: TH) {
            drawFlash(&px, TW, TH, mx, my, 20, fc)
        }
        return Sprite(w: TW, h: TH, pixels: px)
    }

    private static func drawFlash(_ px: inout [UInt32], _ w: Int, _ h: Int, _ cx: Int, _ cy: Int, _ r: Int, _ c: UInt32) {
        let white = packRGBA(255, 255, 244)
        let mid = mixRGBA(c, white, 0.55)
        for a in stride(from: 0, to: 360, by: 20) {
            let rad = Float(a) * .pi / 180
            let ex = cx + Int(cos(rad) * Float(r + 10)), ey = cy + Int(sin(rad) * Float(r + 10))
            line(&px, w, h, cx, cy, ex, ey, c)
        }
        disc(&px, w, h, cx, cy, r, c); disc(&px, w, h, cx, cy, r * 2 / 3, mid); disc(&px, w, h, cx, cy, r / 3, white)
    }
    private static func disc(_ px: inout [UInt32], _ w: Int, _ h: Int, _ cx: Int, _ cy: Int, _ r: Int, _ c: UInt32) {
        for j in (cy - r)...(cy + r) { for i in (cx - r)...(cx + r) {
            if i < 0 || i >= w || j < 0 || j >= h { continue }
            let dx = i - cx, dy = j - cy
            if dx * dx + dy * dy <= r * r { px[j * w + i] = c }
        } }
    }
    private static func line(_ px: inout [UInt32], _ w: Int, _ h: Int, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: UInt32) {
        var x0 = x0, y0 = y0; let dx = abs(x1 - x0), dy = -abs(y1 - y0)
        let sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1; var err = dx + dy
        while true {
            for oy in -1...1 { for ox in -1...1 { let xx = x0 + ox, yy = y0 + oy; if xx >= 0 && xx < w && yy >= 0 && yy < h { px[yy * w + xx] = c } } }
            if x0 == x1 && y0 == y1 { break }
            let e2 = 2 * err; if e2 >= dy { err += dy; x0 += sx }; if e2 <= dx { err += dx; y0 += sy }
        }
    }

    // local space: +z forward (away), +y up, +x right
    private static func build(_ k: WeaponKind) -> (Model3, SIMD3<Float>, UInt32, Bool) {
        let metal = packRGBA(122, 126, 142), metalDk = packRGBA(70, 74, 88), grip = packRGBA(98, 72, 48)
        var m = Model3()
        switch k {
        case .rocket:
            m.cylZ(0, 0, -0.7, 3.0, 0.72, 12, metal)                              // tube
            m.cylZ(0, 0, 2.55, 3.05, 0.52, 12, packRGBA(20, 20, 26))              // dark bore
            m.box(SIMD3(0, -1.25, -0.5), SIMD3(0.7, 1.4, 1.0), grip)              // grip
            m.box(SIMD3(-0.5, 0.85, 0.2), SIMD3(0.3, 0.5, 0.7), metalDk)          // sight
            return (m, SIMD3(0, 0, 3.1), packRGBA(255, 190, 100), true)
        case .plasma:
            m.box(SIMD3(0, 0, 0.5), SIMD3(1.0, 1.25, 2.7), packRGBA(58, 74, 120))  // body
            m.cylZ(0, 0.1, 2.3, 3.0, 0.45, 10, packRGBA(124, 234, 255))            // emitter (glow)
            m.box(SIMD3(0, -1.2, -0.6), SIMD3(0.66, 1.4, 0.96), grip)
            return (m, SIMD3(0, 0.1, 3.0), packRGBA(124, 234, 255), true)
        case .flamethrower:
            let tank = packRGBA(150, 86, 38), tankDk = packRGBA(96, 54, 26)
            m.cylZ(0, 0.05, -0.4, 3.4, 0.34, 12, metal)                          // barrel
            m.cylZ(0, 0.05, 2.7, 0.55, 0.5, 12, metalDk)                         // flared nozzle
            m.cylZ(0, 0.05, 3.0, 0.18, 0.34, 10, packRGBA(40, 26, 20))           // bore
            m.cylZ(-0.62, -0.35, -1.3, 2.4, 0.42, 12, tank)                      // side fuel cylinder
            m.cylZ(-0.62, -0.35, -1.5, 0.25, 0.46, 12, tankDk)                   // tank cap
            m.box(SIMD3(0.1, -1.2, -0.5), SIMD3(0.64, 1.4, 0.96), grip)          // grip
            m.box(SIMD3(0, -0.55, 1.3), SIMD3(0.18, 0.4, 0.3), packRGBA(60, 50, 46)) // pilot stub
            return (m, SIMD3(0, 0.05, 3.2), packRGBA(255, 150, 60), true)        // warm pilot flash
        }
    }
}

// ── Pickups, built from low-poly geometry ───────────────────────────────────
enum MeshItems {
    static func sprite(_ k: ItemKind) -> Sprite {
        switch k {
        case .weaponRocket: return weaponPickup(.rocket)
        default:
            let px = MeshRender.render(build(k), pitch: -0.5, yaw: 0.6, t: SIMD3(0, -0.05, 3.3), f: 82, w: 54, h: 54)
            return Sprite(w: 54, h: 54, pixels: px)
        }
    }

    private static func weaponPickup(_ wk: WeaponKind) -> Sprite {
        // the held weapon model, laid at a floor-pickup angle
        let px = MeshRender.render(MeshWeapons.model(wk), pitch: -0.15, yaw: 1.22, t: SIMD3(0, -0.25, 9.5), f: 132, w: 86, h: 56)
        return Sprite(w: 86, h: 56, pixels: px)
    }

    private static func build(_ k: ItemKind) -> Model3 {
        let white = packRGBA(228, 230, 236), red = packRGBA(214, 52, 48)
        let brass = packRGBA(226, 206, 96), dkmetal = packRGBA(72, 76, 90)
        var m = Model3()
        switch k {
        case .medkit:
            m.box(SIMD3(0, 0, 0), SIMD3(1.0, 0.72, 0.72), white)
            m.box(SIMD3(0, 0, 0.38), SIMD3(0.5, 0.16, 0.06), red)
            m.box(SIMD3(0, 0, 0.38), SIMD3(0.16, 0.5, 0.06), red)
        case .stim:
            m.box(SIMD3(0, -0.05, 0), SIMD3(0.62, 0.5, 0.5), white)
            m.box(SIMD3(0, 0.22, 0), SIMD3(0.66, 0.12, 0.52), red)
            m.box(SIMD3(0, 0, 0.28), SIMD3(0.26, 0.09, 0.06), red); m.box(SIMD3(0, 0, 0.28), SIMD3(0.09, 0.26, 0.06), red)
        case .armor, .megaArmor:
            let col = k == .armor ? packRGBA(54, 184, 86) : packRGBA(64, 104, 226)
            m.box(SIMD3(0, -0.1, 0), SIMD3(0.95, 0.8, 0.42), col)
            m.box(SIMD3(0, 0.45, 0), SIMD3(0.5, 0.3, 0.34), col)
            m.box(SIMD3(0, -0.1, 0.23), SIMD3(0.5, 0.4, 0.06), mixRGBA(col, white, 0.4))
        case .ammoFuel:                                         // pressurised fuel canister — red drum, brass cap
            let fuelRed = packRGBA(176, 58, 40), fuelDk = packRGBA(112, 36, 26)
            m.cylY(0, -0.05, -0.5, 0.46, 0.34, 12, fuelRed)     // drum body
            m.cylY(0, -0.05, 0.46, 0.6, 0.36, 12, fuelDk)       // top rim
            m.cylY(0.12, -0.05, 0.58, 0.74, 0.12, 8, brass)     // spout cap
            m.box(SIMD3(0, 0.28, 0), SIMD3(0.74, 0.1, 0.06), packRGBA(232, 196, 70))  // hazard band
        case .mineCrate:                                        // explosives crate — dark box, red mine peeking out
            let crate = packRGBA(66, 70, 60), crateDk = packRGBA(40, 44, 38)
            m.box(SIMD3(0, -0.12, 0), SIMD3(0.92, 0.62, 0.72), crate)
            m.box(SIMD3(0, -0.12, 0.38), SIMD3(0.5, 0.34, 0.05), packRGBA(214, 168, 40))  // stencil panel
            for sx in [Float(-0.42), 0.42] { m.box(SIMD3(sx, -0.12, 0), SIMD3(0.06, 0.64, 0.74), crateDk) }  // edge straps
            m.cylY(0, 0.28, -0.06, 0.18, 0.26, 10, packRGBA(96, 100, 104))     // mine puck on top
            m.sphereMesh(SIMD3(0, 0.46, 0), 0.1, 6, 4, packRGBA(255, 60, 50))  // red trigger lamp
        case .ammoRockets:
            m.cylZ(0, 0, -0.45, 0.35, 0.16, 8, packRGBA(120, 122, 132))
            m.sphereMesh(SIMD3(0, 0, 0.5), 0.17, 6, 4, red)
            m.box(SIMD3(0, -0.2, -0.45), SIMD3(0.06, 0.24, 0.22), dkmetal); m.box(SIMD3(0, 0.2, -0.45), SIMD3(0.06, 0.24, 0.22), dkmetal)
        case .ammoCells:
            m.box(SIMD3(0, 0, 0), SIMD3(0.55, 0.72, 0.5), packRGBA(44, 64, 96))
            m.box(SIMD3(0, 0.3, 0), SIMD3(0.42, 0.14, 0.38), packRGBA(124, 234, 255))
        case .keyRed, .keyBlue, .keyYellow:
            let col = k == .keyRed ? packRGBA(222, 52, 52) : (k == .keyBlue ? packRGBA(72, 112, 232) : packRGBA(232, 202, 52))
            m.box(SIMD3(0, 0.1, 0), SIMD3(0.55, 0.8, 0.12), col)
            m.box(SIMD3(0, 0.28, 0.08), SIMD3(0.5, 0.16, 0.04), white)
            m.box(SIMD3(0.2, -0.4, 0), SIMD3(0.16, 0.22, 0.12), col)
        default:
            m.box(SIMD3(0, 0, 0), SIMD3(0.6, 0.6, 0.6), white)
        }
        return m
    }
}

// ── World props (placed by MapGen, persist & react in World) ─────────────────
enum PropKind: Int, CaseIterable { case fuelDrum, proxMine }

enum MeshProps {
    static func sprite(_ k: PropKind) -> Sprite {
        switch k {
        case .fuelDrum:
            // a standing industrial drum — viewed near-level so it reads as a
            // floor prop you walk up to, not a top-down pickup
            let px = MeshRender.render(drum(), pitch: -0.16, yaw: 0.5, t: SIMD3(0, -0.08, 4.1), f: 96, w: 60, h: 96)
            return Sprite(w: 60, h: 96, pixels: px)
        case .proxMine:
            // a low puck on the floor — steeper top-down so the trigger lamp shows
            let px = MeshRender.render(mine(), pitch: -0.66, yaw: 0.4, t: SIMD3(0, 0.04, 2.7), f: 84, w: 54, h: 40)
            return Sprite(w: 54, h: 40, pixels: px)
        }
    }

    private static func drum() -> Model3 {
        var m = Model3()
        let red = packRGBA(168, 52, 38), rim = packRGBA(96, 30, 22)
        let band = packRGBA(228, 196, 70), brass = packRGBA(226, 206, 96)
        m.cylY(0, 0, -1.0, 0.92, 0.5, 16, red)          // body
        m.cylY(0, 0, 0.92, 1.06, 0.54, 16, rim)         // top rim
        m.cylY(0, 0, -1.06, -0.92, 0.54, 16, rim)       // base rim
        m.box(SIMD3(0, 0.36, 0), SIMD3(1.06, 0.16, 0.04), band)   // hazard band (front face)
        m.box(SIMD3(0, -0.36, 0), SIMD3(1.06, 0.16, 0.04), band)
        m.cylY(0.16, 0, 1.04, 1.22, 0.12, 8, brass)     // spout cap
        return m
    }

    private static func mine() -> Model3 {
        var m = Model3()
        let body = packRGBA(60, 64, 70), dk = packRGBA(34, 36, 42), lamp = packRGBA(255, 58, 46)
        m.cylY(0, 0, -0.12, 0.16, 0.42, 12, body)       // puck
        m.cylY(0, 0, 0.16, 0.24, 0.3, 10, dk)           // collar
        m.sphereMesh(SIMD3(0, 0.34, 0), 0.13, 6, 4, lamp)  // red trigger lamp
        for a in stride(from: Float(0), to: 6.28, by: 1.05) {   // stubby trigger prongs
            m.box(SIMD3(cos(a) * 0.42, 0.0, sin(a) * 0.42), SIMD3(0.07, 0.14, 0.07), dk)
        }
        return m
    }
}

// ── Monsters, low-poly geometry rendered at 8 rotations ──────────────────────
enum MeshMonsters {
    static let TW = 128, TH = 176

    static func sprites(_ k: MonsterKind) -> MonsterSprites {
        func eight(_ f: MFrame) -> [Sprite] { (0..<8).map { render(build(k, f), yaw: Float($0) * (.pi / 4)) } }
        return MonsterSprites(walk: [eight(.walkA), eight(.walkB)], attack: eight(.attack),
                              death: [eight(.die1), eight(.dead)])
    }

    /// The raw walk-A geometry for a kind — used by the art-preview harness.
    static func previewModel(_ k: MonsterKind) -> Model3 { build(k, .walkA) }

    private static func render(_ m: Model3, yaw: Float) -> Sprite {
        // model: feet at y=0, front (eyes) toward -z. t.y drops the feet to the tile bottom.
        let px = MeshRender.render(m, pitch: -0.05, yaw: yaw, t: SIMD3(0, -1.25, 5.6), f: 374, w: TW, h: TH)
        return Sprite(w: TW, h: TH, pixels: px)
    }

    // shared parametric humanoid (grunt / trooper / brute / overlord)
    private struct Spec {
        let skin: UInt32, dark: UInt32, accent: UInt32, eye: UInt32
        let tw: Float, th: Float, td: Float                  // torso w/h/d
        let legR: Float, legSpread: Float, legH: Float
        let armR: Float, armSpread: Float
        let headR: Float, headY: Float, horns: Float
        let armored: Bool, ranged: Bool, hurl: Bool, core: Bool, bone: Bool
    }

    private static func build(_ k: MonsterKind, _ f: MFrame) -> Model3 {
        // Legacy low-poly preview meshes (ArtPreview only); the shipping art is the
        // CreatureLab/MonsterBake raymarch. DRONE = low scaled green predator;
        // QUEEN = bulky gray/brown bulk.
        switch k {
        case .alien: return humanoid(f, Spec(skin: packRGBA(70, 96, 74), dark: packRGBA(36, 56, 42), accent: packRGBA(150, 220, 120), eye: packRGBA(180, 250, 150),
                                             tw: 0.78, th: 0.62, td: 0.52, legR: 0.14, legSpread: 0.3, legH: 0.58, armR: 0.12, armSpread: 0.46,
                                             headR: 0.22, headY: 1.34, horns: 0, armored: false, ranged: false, hurl: false, core: false, bone: false))
        case .queen: return humanoid(f, Spec(skin: packRGBA(120, 104, 88), dark: packRGBA(64, 54, 44), accent: packRGBA(150, 120, 90), eye: packRGBA(255, 196, 120),
                                             tw: 1.5, th: 1.1, td: 0.9, legR: 0.28, legSpread: 0.46, legH: 0.7, armR: 0.24, armSpread: 0.9,
                                             headR: 0.3, headY: 1.9, horns: 0.2, armored: false, ranged: false, hurl: false, core: true, bone: true))
        }
    }

    private static func humanoid(_ f: MFrame, _ s: Spec) -> Model3 {
        if f == .dead { return deadHeap(s, big: false) }
        if f == .die1 { return deadHeap(s, big: true) }
        var m = Model3()
        let attack = f == .attack
        let swing: Float = f == .walkB ? -0.2 : (f == .walkA ? 0.2 : 0)
        let hunch: Float = s.armored ? 0 : -0.06            // imps/brutes lean forward, menacing
        // legs + feet
        m.cylY(-s.legSpread, swing, 0, s.legH, s.legR, 8, s.dark)
        m.cylY(s.legSpread, -swing, 0, s.legH, s.legR, 8, s.dark)
        m.box(SIMD3(-s.legSpread, 0.04, swing - 0.06), SIMD3(s.legR * 2.2, 0.1, s.legR * 3), s.dark)
        m.box(SIMD3(s.legSpread, 0.04, -swing - 0.06), SIMD3(s.legR * 2.2, 0.1, s.legR * 3), s.dark)
        let torsoY = s.legH + s.th / 2
        m.box(SIMD3(0, torsoY, (attack ? -0.08 : 0) + hunch), SIMD3(s.tw, s.th, s.td), s.skin)
        if s.armored { m.box(SIMD3(0, torsoY, -s.td / 2 - 0.03), SIMD3(s.tw * 0.7, s.th * 0.62, 0.08), mixRGBA(s.skin, packRGBA(255, 255, 255), 0.16)) }
        if s.bone {
            m.sphereMesh(SIMD3(-s.tw / 2 - 0.04, torsoY + s.th * 0.3, 0), 0.27, 8, 6, packRGBA(202, 182, 152))
            m.sphereMesh(SIMD3(s.tw / 2 + 0.04, torsoY + s.th * 0.3, 0), 0.27, 8, 6, packRGBA(202, 182, 152))
        }
        let reach: Float = attack ? -0.46 : 0.04
        m.cylY(-s.armSpread, reach, s.legH * 0.4, torsoY + s.th * 0.42, s.armR, 8, s.dark)
        m.cylY(s.armSpread, reach, s.legH * 0.4, torsoY + s.th * 0.42, s.armR, 8, s.dark)
        // claws on clawed (non-armoured) hands
        if !s.armored {
            for dx in [-s.armSpread, s.armSpread] {
                for c in 0..<3 { m.sphereMesh(SIMD3(dx + Float(c - 1) * s.armR * 0.85, s.legH * 0.4 - 0.03, reach - s.armR - 0.05), 0.055, 4, 3, packRGBA(222, 212, 184)) }
            }
        }
        // head (hunched slightly forward)
        let hz: Float = -0.04 + hunch
        m.sphereMesh(SIMD3(0, s.headY, hz), s.headR, 10, 8, s.skin)
        if s.armored { m.box(SIMD3(0, s.headY + s.headR * 0.45, hz), SIMD3(s.headR * 2.0, s.headR, s.headR * 2.0), s.dark) }
        if s.horns > 0 {
            m.box(SIMD3(-s.headR * 0.7, s.headY + s.headR + s.horns / 2, hz + 0.05), SIMD3(0.09, s.horns, 0.09), s.dark)
            m.box(SIMD3(s.headR * 0.7, s.headY + s.headR + s.horns / 2, hz + 0.05), SIMD3(0.09, s.horns, 0.09), s.dark)
            m.box(SIMD3(-s.headR * 0.98, s.headY + s.headR + s.horns * 0.85, hz + 0.05), SIMD3(0.08, s.horns * 0.5, 0.08), s.dark)   // splayed tips
            m.box(SIMD3(s.headR * 0.98, s.headY + s.headR + s.horns * 0.85, hz + 0.05), SIMD3(0.08, s.horns * 0.5, 0.08), s.dark)
        }
        // big glowing eyes
        m.sphereMesh(SIMD3(-s.headR * 0.42, s.headY + 0.04, hz - s.headR - 0.02), 0.085, 5, 4, s.eye)
        m.sphereMesh(SIMD3(s.headR * 0.42, s.headY + 0.04, hz - s.headR - 0.02), 0.085, 5, 4, s.eye)
        if s.armored { m.box(SIMD3(0, s.headY, hz - s.headR - 0.03), SIMD3(s.headR * 1.3, 0.1, 0.05), s.accent) }   // visor
        // teeth in non-armoured maws
        if !s.armored {
            for t in 0..<5 { m.box(SIMD3(-s.headR * 0.5 + Float(t) * s.headR * 0.25, s.headY - s.headR * 0.5, hz - s.headR + 0.02), SIMD3(0.05, 0.08, 0.04), packRGBA(226, 222, 205)) }
        }
        if s.ranged {
            m.box(SIMD3(0.18, torsoY - 0.05, -0.35), SIMD3(0.16, 0.16, s.td + 0.85), packRGBA(60, 62, 72))
            if attack { m.sphereMesh(SIMD3(0.18, torsoY - 0.05, -s.td / 2 - 0.75), 0.14, 5, 4, packRGBA(255, 232, 150)) }
        }
        // back spikes on heavy/boss
        if s.bone || s.core {
            for i in 0..<3 { m.box(SIMD3(Float(i - 1) * s.tw * 0.3, torsoY + s.th * 0.2, s.td / 2 + 0.04), SIMD3(0.1, 0.3, 0.18), s.dark) }
        }
        if s.core {
            m.sphereMesh(SIMD3(0, torsoY, -s.td / 2 - 0.02), attack ? 0.27 : 0.23, 8, 6, s.accent)
            m.sphereMesh(SIMD3(0, torsoY, -s.td / 2 - 0.13), 0.1, 5, 4, packRGBA(255, 240, 180))
        }
        if s.hurl && attack { m.sphereMesh(SIMD3(s.armSpread + 0.05, s.legH * 0.4, reach - 0.28), 0.22, 7, 5, s.accent) }
        return m
    }

    private static func floater(_ f: MFrame) -> Model3 {
        if f == .dead || f == .die1 { return deadHeap(Spec(skin: packRGBA(150, 72, 170), dark: packRGBA(92, 40, 116), accent: 0, eye: 0,
                                                          tw: 1, th: 1, td: 1, legR: 0, legSpread: 0, legH: 0, armR: 0, armSpread: 0,
                                                          headR: 0, headY: 0, horns: 0, armored: false, ranged: false, hurl: false, core: false, bone: false), big: f == .die1) }
        var m = Model3()
        let body = packRGBA(150, 72, 170), dark = packRGBA(92, 40, 116)
        m.sphereMesh(SIMD3(0, 1.1, 0), 0.58, 12, 9, body)                                   // smooth round body
        m.sphereMesh(SIMD3(0, 1.18, -0.5), 0.24, 9, 7, packRGBA(244, 244, 252))             // big eye
        m.sphereMesh(SIMD3(0, 1.18, -0.7), 0.11, 7, 5, f == .attack ? packRGBA(255, 90, 90) : packRGBA(205, 45, 45))
        // gaping maw with teeth, under the eye
        let open: Float = f == .attack ? 0.14 : 0.05
        m.box(SIMD3(0, 0.78, -0.44), SIMD3(0.5, open, 0.3), packRGBA(28, 8, 14))
        for t in 0..<6 { m.box(SIMD3(-0.22 + Float(t) * 0.09, 0.83, -0.52), SIMD3(0.05, 0.1, 0.05), packRGBA(226, 222, 205)) }
        let sway: Float = f == .walkB ? 0.12 : -0.12
        for i in 0..<5 { m.cylY(-0.36 + Float(i) * 0.18, sway, 0.08, 0.62, 0.06, 6, dark) }   // tentacles
        for a in stride(from: 0, to: 360, by: 45) {
            let r = Float(a) * .pi / 180
            m.box(SIMD3(cos(r) * 0.52, 1.46, sin(r) * 0.52 + 0.08), SIMD3(0.1, 0.3, 0.1), dark)   // spines
        }
        if f == .attack { m.sphereMesh(SIMD3(0, 0.8, -0.56), 0.16, 6, 5, packRGBA(255, 150, 80)) }
        return m
    }

    private static func deadHeap(_ s: Spec, big: Bool) -> Model3 {
        var m = Model3()
        let blood = packRGBA(150, 28, 26)
        m.box(SIMD3(0, 0.05, 0), SIMD3(1.35, 0.1, 1.0), shade(blood, 0.7))               // pool
        m.box(SIMD3(0, 0.24, 0), SIMD3(0.95, big ? 0.5 : 0.34, 0.62), s.skin)            // heap
        m.sphereMesh(SIMD3(0.32, 0.3, 0.12), 0.2, 6, 4, s.dark)                          // chunk
        m.sphereMesh(SIMD3(-0.28, 0.26, -0.1), 0.16, 6, 4, s.skin)
        m.cylZ(-0.55, 0.18, -0.3, 0.4, 0.1, 6, s.dark)                                   // splayed limb
        return m
    }
}
