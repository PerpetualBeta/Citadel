// Citadel — heads-up display.
//
// Weapon viewmodel (bob, recoil, muzzle flash), screen damage/pickup flashes,
// message ticker, and the bottom status bar with the reactive marine face,
// ammo, health, armour, keys and arsenal. Laid out for the 640×400 framebuffer.

import Foundation

struct HUD {
    let W = RenderConfig.width
    let viewH = RenderConfig.viewHeight
    let barY = RenderConfig.viewHeight
    let barH = RenderConfig.statusBarHeight

    func draw(_ world: World, into c: Canvas2D) {
        drawFlashes(world, c)
        drawViewmodel(world, c)
        drawCrosshair(c)
        drawMessages(world, c)
        drawStatusBar(world, c)
    }

    private func drawFlashes(_ world: World, _ c: Canvas2D) {
        let p = world.player
        if p.berserk > 0 { c.fillRectBlend(0, 0, W, viewH, packRGBA(180, 20, 20), 0.08) }
        if p.hurtFlash > 0 { c.fillRectBlend(0, 0, W, viewH, packRGBA(220, 20, 20), min(0.55, p.hurtFlash * 0.5)) }
        if p.pickupFlash > 0 { c.fillRectBlend(0, 0, W, viewH, packRGBA(220, 200, 120), min(0.35, p.pickupFlash * 0.3)) }
        for y in 0..<viewH {
            let e = max(0, 1 - Float(min(y, viewH - 1 - y)) / 40)
            if e > 0 { c.fillRectBlend(0, y, W, 1, packRGBA(0, 0, 0), e * 0.18) }
        }
    }

    private func drawCrosshair(_ c: Canvas2D) {
        let cx = W / 2, cy = RenderConfig.horizon
        let col = packRGBA(210, 220, 230)
        c.blend(cx, cy, col, 0.9)
        for d in uiS(5)...uiS(8) {
            c.blend(cx - d, cy, col, 0.5); c.blend(cx + d, cy, col, 0.5)
            c.blend(cx, cy - d, col, 0.5); c.blend(cx, cy + d, col, 0.5)
        }
    }

    private func drawViewmodel(_ world: World, _ c: Canvas2D) {
        let p = world.player
        let frames = Sprites.shared.weaponFrames(p.current)
        let firing = p.fireAnim > 0 && frames.count > 1
        let spr = firing ? frames[1] : frames[0]
        let k = Float(RenderConfig.num) / Float(RenderConfig.den)     // framebuffer scale
        let bobX = Int(sin(p.bobPhase) * 7 * p.bob * k)
        let bobY = Int(abs(sin(p.bobPhase * 2)) * 6 * p.bob * k)
        let lower = Int(p.switchAnim * 200 * k)
        let sw = Int(Float(spr.w) * k), sh = Int(Float(spr.h) * k)
        let dx = (W - sw) / 2 + bobX
        let dy = viewH - sh + bobY + lower + uiS(6)
        if p.muzzle > 0 { c.fillRectBlend(0, viewH - uiS(90), W, uiS(90), packRGBA(255, 228, 150), 0.12) }
        c.blitBitmapF(spr.pixels, spr.w, spr.h, dx, dy, scale: k)
    }

    private func drawMessages(_ world: World, _ c: Canvas2D) {
        var y = uiS(10)
        for m in world.messages.suffix(4) {
            let fade = min(1, m.time)
            let col = mixRGBA(packRGBA(40, 40, 36), packRGBA(236, 236, 210), fade)
            c.label(m.text, uiS(10), y, size: uiSf(20), color: col, weight: .semibold)
            y += uiS(24)
        }
        c.labelRight("\(world.colonyName) · FLOOR \(Progression.floorInBuilding(world.level))", W - uiS(10), uiS(10), size: uiSf(19), color: packRGBA(150, 174, 224), weight: .semibold)
        c.labelRight("KILLS \(world.killCount)/\(world.monsterTotal)", W - uiS(10), uiS(34), size: uiSf(16), color: packRGBA(150, 150, 162), weight: .medium)
        drawResourceGauges(world.player, c)
    }

    /// Always-visible economy telemetry (top-right, under KILLS): the three finite
    /// resources — energy cells, flamethrower fuel and proximity mines — each a
    /// number over a thin fill bar, so the survival maths is legible at a glance.
    private func drawResourceGauges(_ p: Player, _ c: Canvas2D) {
        let rx = W - uiS(10), bw = uiS(66)
        var ry = uiS(58)
        func gauge(_ name: String, _ val: Int, _ cap: Int, _ col: UInt32) {
            c.labelRight("\(name) \(val)", rx, ry, size: uiSf(15), color: col, weight: .semibold)
            let frac = cap > 0 ? max(0, min(1, Float(val) / Float(cap))) : 0
            let by = ry + uiS(18), bh = uiS(3), bx = rx - bw
            c.fillRect(bx, by, bw, bh, packRGBA(28, 28, 34))
            if frac > 0 { c.fillRect(bx, by, max(1, Int(Float(bw) * frac)), bh, col) }
            ry += uiS(24)
        }
        gauge("CELLS", p.ammoCount(.cells), AmmoType.cells.capacity, packRGBA(120, 210, 255))
        gauge("FUEL",  p.ammoCount(.fuel),  AmmoType.fuel.capacity,  packRGBA(255, 150, 80))
        gauge("MINES", p.mines, p.maxMines, packRGBA(232, 200, 90))
    }

    private func recess(_ c: Canvas2D, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        c.fillRect(x, y, w, h, packRGBA(28, 29, 36))
        c.hLine(x, x + w - 1, y, packRGBA(18, 18, 24)); c.vLine(x, y, y + h - 1, packRGBA(18, 18, 24))
        c.hLine(x, x + w - 1, y + h - 1, packRGBA(66, 68, 80)); c.vLine(x + w - 1, y, y + h - 1, packRGBA(66, 68, 80))
    }

    /// Objective compass — a single rotating arrow that points to the living
    /// Queen (the kill-and-burn target that gates the exit), then swings to the
    /// exit switch once she is ash. The arrow reddens as the Queen closes in.
    /// "Up" is dead ahead; bearing is the target's angle relative to facing.
    private func drawObjectiveCompass(_ world: World, _ c: Canvas2D, _ bx: Int, _ by: Int, _ bw: Int, _ bh: Int) {
        let p = world.player
        var target: SIMD2<Float>?
        var live = false
        if let q = world.monsters.first(where: { $0.kind == .queen && $0.alive }) { target = q.pos; live = true }
        else if world.map.exitCell >= 0 {
            let e = world.map.exitCell, w = world.map.w
            target = SIMD2(Float(e % w) + 0.5, Float(e / w) + 0.5)
        }
        let label = live ? "QUEEN" : "EXIT"
        guard let t = target else { return }
        let to = t - p.pos, dist = vlen(to)
        let ahead = SIMD2<Float>(cos(p.dir), sin(p.dir))
        // bearing: 0 = dead ahead; cross>0 = target is to the right (matches the
        // raycaster's own sprite projection, so the arrow agrees with the world).
        let rel = atan2(ahead.x * to.y - ahead.y * to.x, ahead.x * to.x + ahead.y * to.y)
        let F = SIMD2<Float>(sin(rel), -cos(rel)), perp = SIMD2<Float>(cos(rel), sin(rel))
        let near = max(0, min(1, 1 - dist / 6))
        let col = live ? mixRGBA(packRGBA(238, 156, 56), packRGBA(255, 56, 36), near) : packRGBA(96, 200, 255)
        let cx = bx + bw / 2, cy = by + (bh - uiS(11)) / 2
        let r = max(uiS(8), min(bw, bh - uiS(13)) / 2 - uiS(2))
        let L = Float(r) * 0.95, headBase = L - Float(r) * 0.6
        for oy in -r...r { for ox in -r...r where ox * ox + oy * oy <= r * r {
            let fwd = Float(ox) * F.x + Float(oy) * F.y
            let side = abs(Float(ox) * perp.x + Float(oy) * perp.y)
            var inside = false
            if fwd >= headBase && fwd <= L { inside = side <= Float(r) * 0.52 * ((L - fwd) / (L - headBase)) }   // arrowhead
            else if fwd >= -L * 0.72 && fwd < headBase { inside = side <= Float(r) * 0.17 }                       // shaft
            if inside { c.plot(cx + ox, cy + oy, col) }
        } }
        c.labelCentered2(label, bx, bw, by + bh - uiS(11), size: uiSf(10), color: col, weight: .bold)
    }

    // ── status bar — five clean, non-overlapping zones (authored in 640-logical,
    //    scaled through uiS). AMMO | HEALTH | FACE | ARMOUR | ARSENAL. ────────────
    private func drawStatusBar(_ world: World, _ c: Canvas2D) {
        let p = world.player
        c.fillRect(0, barY, W, barH, packRGBA(50, 51, 60))
        c.fillRect(0, barY, W, barH / 2, packRGBA(56, 57, 68))
        c.fillRect(0, barY, W, uiS(3), packRGBA(102, 104, 118))
        c.fillRect(0, barY + uiS(3), W, uiS(1), packRGBA(26, 26, 32))
        for x in [uiS(104), uiS(212), uiS(406), uiS(512)] {   // zone separators (clear of every recess)
            c.vLine(x, barY + uiS(7), barY + barH - uiS(7), packRGBA(30, 30, 38)); c.vLine(x + 1, barY + uiS(7), barY + barH - uiS(7), packRGBA(68, 70, 82))
        }
        let lab = packRGBA(152, 154, 166)
        let topY = barY + uiS(10)
        let numY = topY + uiS(18)
        let labSize = uiSf(13)
        let boxY = numY - uiS(2), boxH = uiS(44)

        // Pick ONE number size that keeps the widest reading inside every recess
        // (stable as values change), then centre each value in its box — so a big
        // value like "100%" can never punch out of the panel.
        func fit(_ s: String, _ bw: Int) -> CGFloat {
            let t = uiSf(38)
            let w = c.labelWidth(s, size: t, weight: .heavy), h = c.labelHeight(s, size: t, weight: .heavy)
            var sz = t
            if w > 0 { sz = min(sz, t * CGFloat(bw - uiS(12)) / CGFloat(w)) }
            if h > 0 { sz = min(sz, t * CGFloat(boxH - uiS(8)) / CGFloat(h)) }
            return sz
        }
        let numSize = min(fit("888", uiS(88)), fit("100%", uiS(98)), fit("100%", uiS(96)))
        func drawNum(_ s: String, _ bx: Int, _ bw: Int, _ color: UInt32) {
            let tw = c.labelWidth(s, size: numSize, weight: .heavy), th = c.labelHeight(s, size: numSize, weight: .heavy)
            c.label(s, bx + (bw - tw) / 2, boxY + (boxH - th) / 2, size: numSize, color: color, weight: .heavy)
        }

        c.label("AMMO", uiS(12), topY, size: labSize, color: lab, weight: .semibold)
        recess(c, uiS(10), boxY, uiS(88), boxH)
        let def = p.current.def
        let ammoStr = def.ammo == .none ? "∞" : String(p.ammoCount(def.ammo))
        drawNum(ammoStr, uiS(10), uiS(88), packRGBA(236, 202, 76))

        c.label("HEALTH", uiS(110), topY, size: labSize, color: lab, weight: .semibold)
        recess(c, uiS(108), boxY, uiS(98), boxH)
        let hCol = p.health < 25 ? packRGBA(232, 64, 52) : packRGBA(232, 234, 240)
        drawNum("\(p.health)%", uiS(108), uiS(98), hCol)

        // OBJECTIVE COMPASS (replaces the marine mugshot) — a dial that points to
        // the living Queen, then to the exit switch once she has been burned to ash.
        let cbw = uiS(60), cbh = barH - uiS(14)
        let cbx = (W - cbw) / 2, cby = barY + uiS(7)
        recess(c, cbx, cby, cbw, cbh)
        drawObjectiveCompass(world, c, cbx, cby, cbw, cbh)

        c.label("ARMOUR", uiS(414), topY, size: labSize, color: lab, weight: .semibold)
        recess(c, uiS(412), boxY, uiS(96), boxH)
        drawNum("\(p.armor)%", uiS(412), uiS(96), packRGBA(118, 178, 240))

        // ARSENAL zone (right of the divider at 512): keys (top) · weapon name
        // (middle) · the 1–7 slots (bottom) — nothing crosses into ARMOUR now.
        let rEdge = W - uiS(10)
        let keyColors: [(KeyColor, UInt32)] = [(.red, packRGBA(222, 52, 52)), (.blue, packRGBA(72, 112, 232)), (.yellow, packRGBA(232, 202, 52))]
        var kx = rEdge - uiS(12)
        for (kc, col) in keyColors.reversed() {
            let held = p.keys.contains(kc)
            c.fillRect(kx, topY, uiS(12), uiS(15), held ? col : shade(col, 0.22))
            if held { c.strokeRect(kx, topY, uiS(12), uiS(15), packRGBA(255, 255, 255)) }
            kx -= uiS(16)
        }
        c.labelRight(def.name, rEdge, topY + uiS(20), size: uiSf(15), color: packRGBA(196, 198, 208), weight: .bold)
        var ax = uiS(516)
        for (i, w) in WeaponKind.allCases.enumerated() {
            let owned = p.has(w), cur = p.current == w
            let col = cur ? packRGBA(255, 240, 120) : (owned ? packRGBA(196, 198, 208) : packRGBA(74, 74, 84))
            if cur { c.fillRect(ax - uiS(2), barY + barH - uiS(24), uiS(14), uiS(20), packRGBA(70, 62, 20)) }
            c.label("\(i + 1)", ax, barY + barH - uiS(23), size: uiSf(14), color: col, weight: cur ? .heavy : .medium, shadow: false)
            ax += uiS(15)
        }
    }
}
