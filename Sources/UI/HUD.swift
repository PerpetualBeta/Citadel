// Citadel — the visor HUD.
//
// The marine sees the world through her helmet's visor; everything here is
// information PROJECTED onto the lens — no status-bar panel, no chrome. One
// digital design language throughout: translucent pods with corner brackets,
// monospaced phosphor type, segmented bars. Cold ARC-cyan for telemetry (the
// kit is ARC-issued), amber for cautions, red for critical.
//
// Also owns the weapon viewmodel (bob, recoil, muzzle flash), the damage /
// pickup flashes and the message ticker. Laid out in the logical 640×400
// space via uiS, over the full-height 3-D view.

import Foundation

struct HUD {
    let W = RenderConfig.width
    let viewH = RenderConfig.viewHeight

    // ── the visor's phosphor palette ──
    static let vBright = packRGBA(196, 238, 248)   // values
    static let vMid    = packRGBA(112, 182, 200)   // labels, frames
    static let vDim    = packRGBA(58, 102, 116)    // furniture
    static let warn    = packRGBA(240, 196, 96)    // caution
    static let crit    = packRGBA(255, 74, 52)     // critical
    static let good    = packRGBA(120, 230, 150)   // objective clear
    static let backing = packRGBA(4, 12, 16)       // pod glass

    func draw(_ world: World, into c: Canvas2D) {
        drawFlashes(world, c)
        drawViewmodel(world, c)
        drawTracker(world, c)
        drawVitals(world.player, c)
        drawWeaponPod(world.player, c)
        drawMissionBlock(world, c)
        drawMessages(world, c)
        drawCrosshair(c)
        // the ARC seal, top-centre: worn visor furniture (the kit is ARC-issued) —
        // clear of the viewmodel, never explained
        FrontEnd.arcSeal(c, cx: W / 2, cy: uiS(24), r: uiS(11),
                         color: mixRGBA(packRGBA(0, 0, 0), FrontEnd.cold, 0.30), alpha: 0.55)
    }

    // ── shared visor furniture ────────────────────────────────────────────────

    /// A projected pod: translucent glass + corner brackets. The brackets (not a
    /// full frame) are what make every element read as ONE projection system.
    private func pod(_ c: Canvas2D, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        c.fillRectBlend(x, y, w, h, HUD.backing, 0.38)
        var sy = y + uiS(1)
        while sy < y + h { c.fillRectBlend(x, sy, w, 1, packRGBA(0, 0, 0), 0.07); sy += uiS(2) }
        let L = uiS(7), a: Float = 0.85
        for (cx, cy, dx, dy) in [(x, y, 1, 1), (x + w - 1, y, -1, 1),
                                 (x, y + h - 1, 1, -1), (x + w - 1, y + h - 1, -1, -1)] {
            c.fillRectBlend(min(cx, cx + dx * (L - 1)), cy, L, 1, HUD.vMid, a)
            c.fillRectBlend(cx, min(cy, cy + dy * (L - 1)), 1, L, HUD.vMid, a)
        }
    }

    /// A segmented (digital) bar. `frac` 0…1 lights segments left→right.
    private func segBar(_ c: Canvas2D, _ x: Int, _ y: Int, _ w: Int, _ h: Int,
                        _ frac: Float, _ color: UInt32, segs: Int = 12) {
        let gap = uiS(1)
        let sw = max(1, (w - gap * (segs - 1)) / segs)
        let lit = Int((max(0, min(1, frac)) * Float(segs)).rounded())
        var sx = x
        for i in 0..<segs {
            if i < lit { c.fillRectBlend(sx, y, sw, h, color, 0.95) }
            else { c.fillRectBlend(sx, y, sw, h, color, 0.16) }
            sx += sw + gap
        }
    }

    // ── full-visor flashes ────────────────────────────────────────────────────

    private func drawFlashes(_ world: World, _ c: Canvas2D) {
        let p = world.player
        if p.berserk > 0 { c.fillRectBlend(0, 0, W, viewH, packRGBA(180, 20, 20), 0.08) }
        if p.hurtFlash > 0 { c.fillRectBlend(0, 0, W, viewH, packRGBA(220, 20, 20), min(0.55, p.hurtFlash * 0.5)) }
        if p.pickupFlash > 0 { c.fillRectBlend(0, 0, W, viewH, packRGBA(220, 200, 120), min(0.35, p.pickupFlash * 0.3)) }
        for y in 0..<viewH {
            let e = max(0, 1 - Float(min(y, viewH - 1 - y)) / 40)
            if e > 0 { c.fillRectBlend(0, y, W, 1, packRGBA(0, 0, 0), e * 0.18) }
        }
        // suit integrity critical: a slow red pulse bleeding in from the visor edge
        if p.health < 25 && !p.dead {
            let pulse = 0.05 + 0.05 * sinf(world.elapsed * 4)
            for d in 0..<uiS(22) {
                let a = pulse * (1 - Float(d) / Float(uiS(22)))
                c.fillRectBlend(0, d, W, 1, HUD.crit, a)
                c.fillRectBlend(0, viewH - 1 - d, W, 1, HUD.crit, a)
                c.fillRectBlend(d, 0, 1, viewH, HUD.crit, a * 0.7)
                c.fillRectBlend(W - 1 - d, 0, 1, viewH, HUD.crit, a * 0.7)
            }
        }
    }

    private func drawCrosshair(_ c: Canvas2D) {
        let cx = W / 2, cy = RenderConfig.horizon
        let col = packRGBA(210, 225, 232)
        c.blend(cx, cy, col, 0.9)
        for d in uiS(5)...uiS(8) {
            c.blend(cx - d, cy, col, 0.5); c.blend(cx + d, cy, col, 0.5)
            c.blend(cx, cy - d, col, 0.5); c.blend(cx, cy + d, col, 0.5)
        }
    }

    private func drawViewmodel(_ world: World, _ c: Canvas2D) {
        // The weapon is no longer a baked sprite blitted over the frame — it is
        // an SDF viewmodel raymarched IN the world render (Viewmodel.swift +
        // GPURaymarch.vmField), lit by the same rig as everything else. All
        // that remains here is the muzzle flash's splash on the visor glass.
        if world.player.muzzle > 0 { c.fillRectBlend(0, viewH - uiS(90), W, uiS(90), packRGBA(255, 228, 150), 0.10) }
    }

    // ── top-left: the comms/message feed ──────────────────────────────────────

    private func drawMessages(_ world: World, _ c: Canvas2D) {
        var y = uiS(10)
        for m in world.messages.suffix(4) {
            let fade = min(1, m.time)
            let col = mixRGBA(packRGBA(24, 40, 44), HUD.vBright, fade)
            c.label("▸", uiS(10), y, size: uiSf(12), color: mixRGBA(packRGBA(0, 0, 0), HUD.vMid, fade),
                    weight: .semibold, shadow: false, mono: true)
            c.label(m.text, uiS(22), y, size: uiSf(12), color: col, weight: .semibold, shadow: false, mono: true)
            y += uiS(16)
        }
    }

    // ── top-right: locator + objective + keys ─────────────────────────────────

    private func drawMissionBlock(_ world: World, _ c: Canvas2D) {
        let rx = W - uiS(10)
        var y = uiS(10)
        c.labelRight("\(world.colonyName) · FLOOR \(Progression.floorInBuilding(world.level))",
                     rx, y, size: uiSf(12), color: HUD.vMid, weight: .semibold, shadow: false, mono: true)
        y += uiS(15)
        // the counter is a true clear-meter (births are counted): at n/n every
        // alien this floor ever held is dead — the line goes clear-green
        let cleared = world.monsterTotal > 0 && world.killCount >= world.monsterTotal
        c.labelRight(cleared ? "KILLS \(world.killCount)/\(world.monsterTotal) · CLEAR"
                             : "KILLS \(world.killCount)/\(world.monsterTotal)", rx, y,
                     size: uiSf(11), color: cleared ? HUD.good : HUD.vDim,
                     weight: cleared ? .bold : .medium, shadow: false, mono: true)
        y += uiS(15)
        let (objective, ocol) = objectiveStatus(world)
        // the objective line blinks gently while the target is live
        let blink = ocol == HUD.good || Int(world.elapsed * 1.6) % 4 != 0
        if blink {
            c.labelRight(objective, rx, y, size: uiSf(11), color: ocol, weight: .bold, shadow: false, mono: true)
        }
        y += uiS(16)
        // key chips — ONLY the locks this floor actually has (plus anything
        // already held): dim = a lock you still need the card for, lit = held.
        // A chip for a colour the level never placed is pure noise.
        let lockColors = Set(world.map.doors.values.compactMap { $0.locked })
        var kx = rx - uiS(12)
        let keyColors: [(KeyColor, UInt32)] = [(.red, packRGBA(222, 52, 52)), (.blue, packRGBA(82, 122, 238)), (.yellow, packRGBA(232, 202, 52))]
        for (kc, col) in keyColors.reversed() where lockColors.contains(kc) || world.player.keys.contains(kc) {
            if world.player.keys.contains(kc) {
                c.fillRectBlend(kx, y, uiS(12), uiS(7), col, 0.95)
                c.fillRectBlend(kx, y + uiS(7), uiS(12), 1, packRGBA(255, 255, 255), 0.7)
            } else {
                c.fillRectBlend(kx, y, uiS(12), uiS(7), col, 0.22)
            }
            kx -= uiS(16)
        }
    }

    private func objectiveStatus(_ world: World) -> (String, UInt32) {
        if let q = world.monsters.first(where: { $0.kind == .queen }) {
            if q.alive { return ("TARGET · QUEEN", HUD.crit) }
            if !world.queenDefeated { return ("BURN THE QUEEN", HUD.warn) }
        }
        return (world.isTeleportFloor ? "TELEPORT ENABLED" : "EXIT ENABLED", HUD.good)
    }

    // ── bottom-left: the motion tracker (with the objective caret on its rim) ──

    /// An Aliens-style scope: the marine at centre, forward = up, awake drones as
    /// green phosphor blips that brighten as they close, the live Queen as a fat
    /// red return. The rim caret points at the current objective (Queen → exit).
    private func drawTracker(_ world: World, _ c: Canvas2D) {
        let R = uiS(52)
        let cx = uiS(74), cy = viewH - uiS(74)
        let range: Float = 14
        let p = world.player
        // scope face — dark translucent disc + rings + cross
        for oy in -R...R { for ox in -R...R {
            let d2 = ox * ox + oy * oy
            if d2 > R * R { continue }
            c.blend(cx + ox, cy + oy, packRGBA(4, 14, 8), 0.55)
        }}
        for ring in [R, R * 2 / 3, R / 3] {
            var a: Float = 0
            while a < 6.2832 {
                c.blend(cx + Int(cosf(a) * Float(ring)), cy + Int(sinf(a) * Float(ring)), packRGBA(40, 110, 62), 0.5)
                a += 0.55 / Float(ring)
            }
        }
        for d in -R...R { c.blend(cx + d, cy, packRGBA(30, 80, 46), 0.25); c.blend(cx, cy + d, packRGBA(30, 80, 46), 0.25) }
        // a slow radial sweep, phosphor-fading — pure dressing, but it sells it
        let swA = world.elapsed * 2.4
        for tail in 0..<14 {
            let a = swA - Float(tail) * 0.05
            let fade = (1 - Float(tail) / 14) * 0.35
            var rr: Float = 4
            while rr < Float(R) {
                c.blend(cx + Int(cosf(a) * rr), cy - Int(sinf(a) * rr), packRGBA(60, 170, 96), fade)
                rr += 1
            }
        }
        // blips — rotated into scope space (forward = up)
        let fwd = SIMD2<Float>(cosf(p.dir), sinf(p.dir))
        let right = SIMD2<Float>(-fwd.y, fwd.x)
        let scale = Float(R - 4) / range
        for m in world.monsters where m.alive {
            if m.kind != .queen && !m.awake { continue }        // the tracker reads MOTION
            let rel = m.pos - p.pos
            let d = vlen(rel)
            if d > range { continue }
            let bx = cx + Int((rel.x * right.x + rel.y * right.y) * scale)
            let by = cy - Int((rel.x * fwd.x + rel.y * fwd.y) * scale)
            let near = 1 - d / range
            let pulse = 0.7 + 0.3 * sinf(world.elapsed * 6 + d)
            let br = m.kind == .queen ? 4 : 2
            let col = m.kind == .queen ? packRGBA(255, 70, 50) : packRGBA(110, 255, 140)
            for oy in -br...br { for ox in -br...br {
                if ox * ox + oy * oy > br * br { continue }
                c.blend(bx + ox, by + oy, col, (0.45 + 0.55 * near) * pulse)
            }}
        }
        // the marine — a steady centre dot
        for oy in -1...1 { for ox in -1...1 { c.blend(cx + ox, cy + oy, packRGBA(220, 245, 225), 0.9) } }
        drawObjectiveCaret(world, c, cx: cx, cy: cy, R: R)
        c.label("TRACKER", cx - uiS(24), cy + R + uiS(6), size: uiSf(10), color: packRGBA(70, 160, 96),
                weight: .semibold, shadow: false, mono: true)
    }

    /// The rim caret: a small arrowhead riding the scope's outer ring at the
    /// objective's bearing — the living Queen, then the exit once she is ash.
    private func drawObjectiveCaret(_ world: World, _ c: Canvas2D, cx: Int, cy: Int, R: Int) {
        let p = world.player
        var target: SIMD2<Float>?
        var live = false
        if let q = world.monsters.first(where: { $0.kind == .queen && $0.alive }) { target = q.pos; live = true }
        else if world.map.exitCell >= 0 {
            let e = world.map.exitCell, w = world.map.w
            target = SIMD2(Float(e % w) + 0.5, Float(e / w) + 0.5)
        }
        guard let t = target else { return }
        let to = t - p.pos
        let ahead = SIMD2<Float>(cosf(p.dir), sinf(p.dir))
        // bearing: 0 = dead ahead (scope-up); cross>0 = target to the right
        let rel = atan2(ahead.x * to.y - ahead.y * to.x, ahead.x * to.x + ahead.y * to.y)
        let dist = vlen(to)
        let near = max(0, min(1, 1 - dist / 6))
        let col = live ? mixRGBA(packRGBA(238, 156, 56), packRGBA(255, 56, 36), near) : packRGBA(96, 200, 255)
        // caret geometry: tip just outside the ring, base just inside, at bearing angle
        let dir = SIMD2<Float>(sinf(rel), -cosf(rel))              // scope space (up = ahead)
        let perp = SIMD2<Float>(cosf(rel), sinf(rel))
        let tip = SIMD2<Float>(Float(cx), Float(cy)) + dir * Float(R + uiS(6))
        let base = SIMD2<Float>(Float(cx), Float(cy)) + dir * Float(R + uiS(1))
        let half = Float(uiS(4))
        c.line(Int(tip.x), Int(tip.y), Int(base.x + perp.x * half), Int(base.y + perp.y * half), col)
        c.line(Int(tip.x), Int(tip.y), Int(base.x - perp.x * half), Int(base.y - perp.y * half), col)
        c.line(Int(base.x + perp.x * half), Int(base.y + perp.y * half),
               Int(base.x - perp.x * half), Int(base.y - perp.y * half), col)
    }

    // ── bottom-left inboard: suit vitals ──────────────────────────────────────

    private func drawVitals(_ p: Player, _ c: Canvas2D) {
        let pw = uiS(170), ph = uiS(52)
        let px = uiS(150), py = viewH - uiS(14) - ph
        pod(c, px, py, pw, ph)
        let colW = pw / 2
        func column(_ x0: Int, _ name: String, _ value: Int, _ vcol: UInt32, _ bcol: UInt32) {
            c.label(name, x0 + uiS(10), py + uiS(6), size: uiSf(9), color: HUD.vDim,
                    weight: .semibold, shadow: false, mono: true)
            c.label("\(value)", x0 + uiS(10), py + uiS(15), size: uiSf(22), color: vcol,
                    weight: .heavy, shadow: false, glow: mixRGBA(packRGBA(0, 0, 0), vcol, 0.25), mono: true)
            segBar(c, x0 + uiS(10), py + ph - uiS(9), colW - uiS(20), uiS(3),
                   Float(value) / 100, bcol, segs: 10)
        }
        let hCol = p.health < 25 ? HUD.crit : (p.health < 50 ? HUD.warn : HUD.vBright)
        column(px, "HEALTH", p.health, hCol, hCol)
        column(px + colW, "ARMOUR", p.armor, HUD.vBright, packRGBA(118, 178, 240))
        c.fillRectBlend(px + colW, py + uiS(6), 1, ph - uiS(12), HUD.vDim, 0.5)
    }

    // ── bottom-right: weapon + ammunition + reserves ──────────────────────────

    private func drawWeaponPod(_ p: Player, _ c: Canvas2D) {
        let pw = uiS(158), ph = uiS(84)
        let px = W - uiS(10) - pw, py = viewH - uiS(14) - ph
        pod(c, px, py, pw, ph)
        let inX = px + uiS(10), rX = px + pw - uiS(10)

        // slot chips 1…3 (owned = mid, current = lit chip)
        var sx = inX
        for (i, w) in WeaponKind.allCases.enumerated() {
            let owned = p.has(w), cur = p.current == w
            if cur { c.fillRectBlend(sx - uiS(2), py + uiS(5), uiS(11), uiS(13), HUD.vMid, 0.30) }
            c.label("\(i + 1)", sx, py + uiS(6), size: uiSf(11),
                    color: cur ? HUD.vBright : (owned ? HUD.vMid : mixRGBA(packRGBA(0, 0, 0), HUD.vDim, 0.6)),
                    weight: cur ? .heavy : .medium, shadow: false, mono: true)
            sx += uiS(14)
        }
        c.labelRight(p.current.def.name, rX, py + uiS(6), size: uiSf(11), color: HUD.vMid,
                     weight: .bold, shadow: false, mono: true)

        // the big round count for what's in her hands
        let def = p.current.def
        let ammo = def.ammo == .none ? -1 : p.ammoCount(def.ammo)
        let cap = def.ammo == .none ? 0 : def.ammo.capacity
        let frac = cap > 0 ? Float(ammo) / Float(cap) : 1
        let aCol: UInt32 = ammo < 0 ? HUD.vBright : (frac <= 0.001 ? HUD.crit : (frac < 0.2 ? HUD.warn : HUD.vBright))
        c.label("AMMO", inX, py + uiS(24), size: uiSf(9), color: HUD.vDim, weight: .semibold, shadow: false, mono: true)
        let ammoStr = ammo < 0 ? "∞" : "\(ammo)"
        let ammoW = c.labelWidth(ammoStr, size: uiSf(24), weight: .heavy, mono: true)
        c.label(ammoStr, rX - ammoW, py + uiS(20), size: uiSf(24), color: aCol,
                weight: .heavy, shadow: false, glow: mixRGBA(packRGBA(0, 0, 0), aCol, 0.25), mono: true)
        segBar(c, inX, py + uiS(47), pw - uiS(20), uiS(3), frac, aCol)

        // reserve telemetry — the three finite resources the run is budgeted in
        let colW = (pw - uiS(20)) / 3
        let rows: [(String, Int, Int, UInt32)] = [
            ("CELLS", p.ammoCount(.cells), AmmoType.cells.capacity, packRGBA(120, 210, 255)),
            ("FUEL", p.ammoCount(.fuel), AmmoType.fuel.capacity, packRGBA(255, 150, 80)),
            ("MINES", p.mines, p.maxMines, packRGBA(232, 200, 90)),
        ]
        for (i, r) in rows.enumerated() {
            let x0 = inX + i * colW
            c.label(r.0, x0, py + uiS(56), size: uiSf(8), color: HUD.vDim, weight: .semibold, shadow: false, mono: true)
            c.label("\(r.1)", x0, py + uiS(64), size: uiSf(12), color: mixRGBA(HUD.vBright, r.3, 0.5),
                    weight: .bold, shadow: false, mono: true)
            let f = r.2 > 0 ? Float(r.1) / Float(r.2) : 0
            segBar(c, x0, py + ph - uiS(7), colW - uiS(8), uiS(2), f, r.3, segs: 8)
        }
    }
}
