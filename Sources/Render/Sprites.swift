// Citadel — procedural sprites.
//
// Zero asset files. Everything is built from shaded primitives: spheres (heads,
// eyes, cores, the floater) lit from the upper-left, cylinders (limbs, barrels)
// for round metal/flesh, and bevelled boxes (armour, receivers). A glowing-
// feature pass (eyes/cores/muzzles with bloom) and a 1-px dark outline finish
// each sprite. The dead lie FLAT on the floor as a gib pile, not standing.

import Foundation

struct Sprite { let w: Int; let h: Int; let pixels: [UInt32] }

private struct Buf {
    let w: Int, h: Int
    var px: [UInt32]
    init(_ w: Int, _ h: Int) { self.w = w; self.h = h; px = [UInt32](repeating: 0, count: w * h) }

    @inline(__always) mutating func set(_ x: Int, _ y: Int, _ c: UInt32) {
        if x >= 0 && x < w && y >= 0 && y < h && (c >> 24) != 0 { px[y * w + x] = c }
    }
    @inline(__always) func isSet(_ x: Int, _ y: Int) -> Bool { x >= 0 && x < w && y >= 0 && y < h && (px[y * w + x] >> 24) != 0 }
    mutating func rect(_ x: Int, _ y: Int, _ rw: Int, _ rh: Int, _ c: UInt32) {
        for j in y..<(y + rh) { for i in x..<(x + rw) { set(i, j, c) } }
    }
    mutating func ellipse(_ cx: Int, _ cy: Int, _ rx: Int, _ ry: Int, _ c: UInt32) {
        if rx <= 0 || ry <= 0 { return }
        for j in (cy - ry)...(cy + ry) { for i in (cx - rx)...(cx + rx) {
            let dx = Float(i - cx) / Float(rx), dy = Float(j - cy) / Float(ry)
            if dx * dx + dy * dy <= 1 { set(i, j, c) } } }
    }
    mutating func disc(_ cx: Int, _ cy: Int, _ r: Int, _ c: UInt32) { ellipse(cx, cy, r, r, c) }
    mutating func hline(_ x0: Int, _ x1: Int, _ y: Int, _ c: UInt32) { for x in min(x0, x1)...max(x0, x1) { set(x, y, c) } }
    mutating func line(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: UInt32) {
        var x0 = x0, y0 = y0; let dx = abs(x1 - x0), dy = -abs(y1 - y0)
        let sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1; var err = dx + dy
        while true { set(x0, y0, c); if x0 == x1 && y0 == y1 { break }
            let e2 = 2 * err; if e2 >= dy { err += dy; x0 += sx }; if e2 <= dx { err += dx; y0 += sy } }
    }
    mutating func thickLine(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ wd: Int, _ c: UInt32) {
        for o in -(wd / 2)...(wd / 2) { line(x0 + o, y0, x1 + o, y1, c); line(x0, y0 + o, x1, y1 + o, c) }
    }
    /// Sphere lit from the upper-left → reads as a 3-D ball.
    mutating func sphere(_ cx: Int, _ cy: Int, _ r: Int, _ base: UInt32, _ light: UInt32, _ dark: UInt32) {
        if r < 1 { return }
        for j in (cy - r)...(cy + r) { for i in (cx - r)...(cx + r) {
            let dx = Float(i - cx) / Float(r), dy = Float(j - cy) / Float(r)
            if dx * dx + dy * dy > 1 { continue }
            let nl = -dx * 0.7 - dy * 0.7
            set(i, j, nl > 0.38 ? light : (nl < -0.3 ? dark : base))
        } }
    }
    /// Vertical metal/flesh cylinder, shaded left(light)→right(dark).
    mutating func cylinderV(_ cx: Int, _ y0: Int, _ y1: Int, _ hw: Int, _ base: UInt32, _ light: UInt32, _ dark: UInt32) {
        if y1 < y0 || hw < 1 { return }
        for y in y0...y1 { for x in (cx - hw)...(cx + hw) {
            let f = Float(x - (cx - hw)) / Float(2 * hw)
            set(x, y, f < 0.22 ? light : (f > 0.72 ? dark : base))
        } }
        for y in y0...y1 { set(cx - hw + 1, y, light) }
    }
    mutating func cylinderH(_ x0: Int, _ x1: Int, _ cy: Int, _ hh: Int, _ base: UInt32, _ light: UInt32, _ dark: UInt32) {
        if x1 < x0 || hh < 1 { return }
        for x in x0...x1 { for y in (cy - hh)...(cy + hh) {
            let f = Float(y - (cy - hh)) / Float(2 * hh)
            set(x, y, f < 0.25 ? light : (f > 0.72 ? dark : base))
        } }
        for x in x0...x1 { set(x, cy - hh + 1, light) }
    }
    mutating func boxBevel(_ x: Int, _ y: Int, _ rw: Int, _ rh: Int, _ base: UInt32, _ light: UInt32, _ dark: UInt32) {
        for j in y..<(y + rh) { for i in x..<(x + rw) {
            var c = base
            if i == x || j == y { c = light } else if i == x + rw - 1 || j == y + rh - 1 { c = dark }
            set(i, j, c)
        } }
    }
    mutating func shadeFilled(top: Float, bottom: Float) {
        var minY = h, maxY = -1
        for y in 0..<h { for x in 0..<w where (px[y * w + x] >> 24) != 0 { if y < minY { minY = y }; if y > maxY { maxY = y } } }
        if maxY < minY { return }
        for y in minY...maxY { let f = Float(y - minY) / Float(max(1, maxY - minY)); let m = top + (bottom - top) * f
            for x in 0..<w { let i = y * w + x; if (px[i] >> 24) != 0 { px[i] = shade(px[i], m) } } }
    }
    mutating func outline(_ color: UInt32) {
        let snap = px
        for y in 0..<h { for x in 0..<w {
            if (snap[y * w + x] >> 24) != 0 { continue }
            var adj = false
            for (ox, oy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
                let nx = x + ox, ny = y + oy
                if nx >= 0 && nx < w && ny >= 0 && ny < h && (snap[ny * w + nx] >> 24) != 0 { adj = true; break }
            }
            if adj { px[y * w + x] = color }
        }}
    }
    func sprite() -> Sprite { Sprite(w: w, h: h, pixels: px) }
}

enum MFrame { case walkA, walkB, attack, die1, dead }
struct MonsterSprites { var walk: [[Sprite]]; var attack: [Sprite]; var death: [[Sprite]] }   // inner arrays = 8 rotation views

private let OUT = packRGBA(16, 11, 13)

private struct Build {
    let w: Int, h: Int
    let dark: UInt32, base: UInt32, light: UInt32, eye: UInt32, accent: UInt32
    let horns: Int
    let armored: Bool, ranged: Bool, claws: Bool, hurl: Bool, core: Bool
}

final class Sprites {
    static let shared = Sprites()

    private var monsterCache: [Int: MonsterSprites] = [:]
    private var itemCache: [Int: Sprite] = [:]
    private var propCache: [Int: Sprite] = [:]
    private var projCache: [Int: Sprite] = [:]
    private var weaponIconCache: [Int: Sprite] = [:]
    private(set) var faces: [Sprite] = []

    private let mMet = packRGBA(104, 108, 122), mLit = packRGBA(168, 172, 188), mDk = packRGBA(48, 50, 60)
    private let mGrip = packRGBA(96, 70, 48), mGripL = packRGBA(140, 104, 70), mGripD = packRGBA(58, 42, 28)

    private init() {
        for k in ItemKind.allCases { itemCache[k.rawValue] = buildItem(k) }
        for k in PropKind.allCases { propCache[k.rawValue] = MeshProps.sprite(k) }
        for k in ProjectileKind.allCases { projCache[k.rawValue] = buildProjectile(k) }
        for k in WeaponKind.allCases { weaponIconCache[k.rawValue] = MeshItems.weaponIcon(k) }
        for bracket in 0..<5 { for dir in 0..<3 { faces.append(buildFace(bracket, dir)) } }
    }

    // Creatures are drawn NATIVELY by the GPU renderer now — SDF drones and the
    // mesh Queen — so these billboards go unused on the shipping path (the only
    // drawThings caller passes includeMonsters:false; the CPU raycaster that once
    // drew them is gone). The offline bake is the expensive one: 5 frames × 8
    // angles of SDF raymarch PER creature (~3.8 s, and it used to land on the first
    // gameplay frame as a multi-second freeze the instant you left the lift). Bake
    // it lazily so it only ever runs if a caller genuinely asks for a billboard.
    func monster(_ k: MonsterKind) -> MonsterSprites {
        if let s = monsterCache[k.rawValue] { return s }
        let s = buildMonsterSet(k); monsterCache[k.rawValue] = s; return s
    }
    func item(_ k: ItemKind) -> Sprite { itemCache[k.rawValue]! }
    func weaponIcon(_ k: WeaponKind) -> Sprite { weaponIconCache[k.rawValue]! }
    func prop(_ k: PropKind) -> Sprite { propCache[k.rawValue]! }
    func projectile(_ k: ProjectileKind) -> Sprite { projCache[k.rawValue]! }
    func face(bracket: Int, dir: Int) -> Sprite { faces[max(0, min(4, bracket)) * 3 + max(0, min(2, dir))] }

    // Organic raymarched creatures (CreatureLab → MonsterBake).
    private func buildMonsterSet(_ k: MonsterKind) -> MonsterSprites { MonsterBake.sprites(k) }

    // ── Items — low-poly 3-D meshes (Mesh3D.swift) ────────────────────────────
    private func buildItem(_ k: ItemKind) -> Sprite { MeshItems.sprite(k) }

    // (First-person weapons are no longer sprites — they are SDF viewmodels
    //  raymarched in the world render: Viewmodel.swift + GPURaymarch.vmField.
    //  MeshWeapons lives on for the floor-pickup sprite only.)

    // ── Projectiles ────────────────────────────────────────────────────────────
    private func buildProjectile(_ k: ProjectileKind) -> Sprite {
        var b = Buf(18, 18); let cx = 9
        switch k {
        case .plasma: b.sphere(cx, cx, 6, packRGBA(120, 230, 255), packRGBA(220, 255, 255), packRGBA(40, 120, 190)); b.disc(cx, cx, 2, packRGBA(255, 255, 255))
        case .rocket: b.cylinderH(3, 13, cx, 3, packRGBA(140, 140, 152), packRGBA(190, 190, 204), packRGBA(70, 70, 84)); b.disc(4, cx, 2, packRGBA(255, 160, 60)); b.line(14, cx, 17, cx, packRGBA(206, 64, 44))
        case .bolt: b.sphere(cx, cx, 5, packRGBA(255, 214, 96), packRGBA(255, 252, 204), packRGBA(180, 120, 30))
        case .fireball: b.sphere(cx, cx, 7, packRGBA(255, 120, 44), packRGBA(255, 226, 130), packRGBA(170, 50, 20)); b.disc(cx, cx, 2, packRGBA(255, 250, 220))
        case .bfgBall: b.sphere(cx, cx, 8, packRGBA(120, 255, 150), packRGBA(232, 255, 232), packRGBA(40, 150, 70))
        }
        return b.sprite()
    }

    // ── Reactive marine face (30×40, detailed) ───────────────────────────────
    private func buildFace(_ bracket: Int, _ dir: Int) -> Sprite {
        var b = Buf(30, 40)
        let cx = 15
        let skin = packRGBA(206, 156, 112), skinL = packRGBA(236, 192, 146), skinD = packRGBA(148, 100, 68)
        let helm = packRGBA(84, 92, 72), helmL = packRGBA(116, 124, 98), helmD = packRGBA(46, 52, 40)

        if bracket == 0 {   // dead — pale, slack, helmet knocked askew, bloodied
            b.rect(cx - 5, 34, 10, 5, packRGBA(150, 124, 114))
            b.ellipse(cx, 24, 10, 12, packRGBA(178, 152, 140))
            b.ellipse(cx - 3, 20, 5, 7, packRGBA(198, 174, 162))
            b.ellipse(cx + 1, 11, 13, 7, helmD); b.ellipse(cx - 3, 9, 5, 3, packRGBA(70, 76, 60))   // slipped helmet
            b.line(8, 20, 12, 25, packRGBA(74, 0, 0)); b.line(12, 20, 8, 25, packRGBA(74, 0, 0))     // X eyes
            b.line(18, 20, 22, 25, packRGBA(74, 0, 0)); b.line(22, 20, 18, 25, packRGBA(74, 0, 0))
            b.rect(11, 31, 8, 2, packRGBA(70, 14, 14))
            bloodStreaks(&b, 6); b.outline(OUT)
            return b.sprite()
        }

        // neck + face (oval), highlight, ears, jaw stubble
        b.rect(cx - 5, 33, 10, 7, skinD)
        b.ellipse(cx, 24, 10, 12, skin)
        b.ellipse(cx - 3, 21, 5, 7, skinL)                       // cheek highlight
        b.set(5, 24, skinD); b.set(24, 24, skinD)                // ears
        for j in 28..<35 { for i in (cx - 8)...(cx + 8) where b.isSet(i, j) && (i &* 3 + j) % 4 == 0 { b.set(i, j, skinD) } }  // stubble
        // combat helmet (dome + rim + highlight) — replaces the awkward hair
        b.ellipse(cx, 9, 12, 7, helm)
        b.ellipse(cx - 4, 7, 5, 3, helmL)                        // helmet highlight
        b.rect(3, 14, 24, 2, helmD)                              // rim shadow
        b.set(3, 12, helmD); b.set(26, 12, helmD)
        // brow shadow under the rim, angrier as health drops
        let furrow = 4 - bracket
        b.thickLine(7, 18 - furrow / 2, 13, 18, 1, skinD); b.thickLine(17, 18, 23, 18 - furrow / 2, 1, skinD)
        // eyes (whites + pupils, shifted by look dir)
        let eo = (dir - 1) * 2, pup = packRGBA(24, 32, 62)
        b.rect(8 + eo, 19, 4, 3, packRGBA(242, 242, 242)); b.set(9 + eo + (dir - 1), 20, pup); b.set(10 + eo + (dir - 1), 20, pup)
        b.rect(18 + eo, 19, 4, 3, packRGBA(242, 242, 242)); b.set(19 + eo + (dir - 1), 20, pup); b.set(20 + eo + (dir - 1), 20, pup)
        // nose
        b.rect(14, 22, 3, 5, skinD); b.set(14, 22, skinL); b.set(13, 27, skinD); b.set(17, 27, skinD)
        // mouth by health — stern → set → gritted → snarl
        if bracket >= 4 { b.rect(11, 31, 8, 1, packRGBA(122, 72, 58)) }
        else if bracket == 3 { b.rect(10, 31, 10, 2, packRGBA(118, 64, 52)) }
        else if bracket == 2 { b.rect(10, 30, 10, 3, packRGBA(110, 52, 44)); for tx in stride(from: 11, through: 19, by: 2) { b.set(tx, 31, packRGBA(228, 226, 216)) } }
        else { b.ellipse(cx, 31, 5, 3, packRGBA(72, 16, 16)); for tx in stride(from: 11, through: 19, by: 2) { b.set(tx, 30, packRGBA(230, 228, 218)) } }
        if bracket <= 2 { bloodStreaks(&b, 4 - bracket) }
        b.set(cx - 6, 19, packRGBA(255, 242, 222))               // sweat glint
        b.outline(OUT)
        return b.sprite()
    }
    private func bloodStreaks(_ b: inout Buf, _ n: Int) {
        let blood = packRGBA(182, 26, 26); let xs = [7, 22, 11, 18, 9, 15]
        for i in 0..<min(n, xs.count) { b.line(xs[i], 18 + i, xs[i] + (i % 2 == 0 ? 1 : -1), 29 + (i % 4), blood) }
    }
}
