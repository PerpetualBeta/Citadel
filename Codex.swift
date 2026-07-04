// Citadel — front-end screens (title, briefing, enemy intel, level cleared,
// game over / name entry, high scores, pause). Drawn into the same Canvas2D
// with crisp Core Text, laid out for the 640×400 framebuffer.

import Foundation

enum FrontEnd {
    static let W = RenderConfig.width
    static let H = RenderConfig.height

    static let red = packRGBA(214, 58, 44)
    static let redGlow = packRGBA(70, 12, 10)
    static let amber = packRGBA(240, 196, 96)
    static let ink = packRGBA(206, 210, 220)
    static let dim = packRGBA(150, 154, 168)

    static func backdrop(_ c: Canvas2D, _ t: Float, top: UInt32 = packRGBA(20, 11, 14),
                         bottom: UInt32 = packRGBA(46, 18, 14)) {
        for y in 0..<H { c.hLine(0, W - 1, y, mixRGBA(top, bottom, Float(y) / Float(H))) }
        for i in 0..<90 {
            let fx = Float((i * 53) % W) + 4 * sin(t * 0.7 + Float(i))
            let speed = 9 + Float(i % 5) * 7
            let fy = Float(H) - (t * speed + Float(i * 61)).truncatingRemainder(dividingBy: Float(H))
            let a = 0.25 + 0.3 * (0.5 + 0.5 * sin(t * 2 + Float(i)))
            c.blend(Int(fx), Int(fy), packRGBA(255, 160, 80), a)
            c.blend(Int(fx), Int(fy) + 1, packRGBA(200, 90, 40), a * 0.5)
        }
        for y in 0..<H {
            let edge = max(0, 1 - Float(min(y, H - 1 - y)) / 54)
            if edge > 0 { c.fillRectBlend(0, y, W, 1, packRGBA(0, 0, 0), edge * 0.5) }
        }
        for y in stride(from: 0, to: H, by: 2) { c.fillRectBlend(0, y, W, 1, packRGBA(0, 0, 0), 0.1) }
    }

    // ── terminal title palette ──
    static let amberHi = packRGBA(255, 233, 176)
    static let amberDim = packRGBA(150, 118, 52)
    static let cold = packRGBA(150, 200, 212)        // ARC — clinical, alien to the warm phosphor
    static let coldDim = packRGBA(104, 150, 162)
    // a memory-dump glyph set (system-font-safe: hex, Greek, symbols)
    private static let rainGlyphs = Array("0123456789ABCDEFΣΦΩΔΞΨ<>/=+*").map(String.init)

    /// The title is an ARC subsurface terminal. Most of it is glyph-rain; the brand
    /// lives in the corner seal and the boot-log, never explained.
    static func title(_ c: Canvas2D, t: Float, hs: HighScores) {
        c.fillRect(0, 0, W, H, packRGBA(8, 9, 7))          // dead phosphor screen
        terminalRain(c, t)
        crtOverlay(c)

        // ── boot-log: a left-aligned terminal readout in the TOP-LEFT corner ──
        let bx = uiS(24); var by = uiS(20); let bs = uiSf(10)
        // recessive readout: small, dim, lighter-weight — it sets tone, never competes.
        // monospace ⇒ pin the status keywords to a FIXED column; pad each label with a
        // dotted leader up to it, so LINK LOST / BREACHED / … all left-align.
        let bootLabel = packRGBA(116, 92, 42)
        let bootRed = mixRGBA(packRGBA(0, 0, 0), red, 0.6)
        let bootAmber = mixRGBA(packRGBA(0, 0, 0), amber, 0.62)
        let cw = c.labelWidth("0", size: bs, weight: .medium, mono: true)
        let statusCol = bx + 21 * cw
        func boot(_ label: String, _ status: String, _ sc: UInt32) {
            var pre = label
            if !status.isEmpty { pre += " "; while pre.count < 20 { pre += "." } }
            c.label(pre, bx, by, size: bs, color: bootLabel, weight: .medium, shadow: false, mono: true)
            if !status.isEmpty { c.label(status, statusCol, by, size: bs, color: sc, weight: .semibold, shadow: false, mono: true) }
            by += uiS(12)
        }
        boot("ARC // SUBSURFACE  NODE 0x7F", "", 0)
        boot("> RELAY STRATARIS", "LINK LOST", bootRed)
        boot("> POWER", "ON RESERVE", bootAmber)
        boot("> SECTOR SEAL", "BREACHED", bootRed)
        boot("> BIOSIGN SWEEP", "ANOMALOUS", bootRed)
        if Int(t * 1.6) % 2 == 0 { c.label("> \u{2588}", bx, by, size: bs, color: bootAmber, weight: .regular, shadow: false, mono: true) }

        arcSeal(c, cx: W - uiS(52), cy: uiS(46), r: uiS(24), color: coldDim, alpha: 0.72)

        // ── CITADEL — bright core + a SOFT, SYMMETRIC phosphor glow (no hard extrude)
        //    and a faint 1px chromatic-aberration fringe (crimson right / cyan left) ──
        let lw = c.labelWidth("CITADEL", size: uiSf(82), weight: .heavy)
        let lx = (W - lw) / 2, ly = uiS(96)
        let halo = mixRGBA(packRGBA(0, 0, 0), amber, 0.22)
        for (ox, oy) in [(-uiS(1), 0), (uiS(1), 0), (0, -uiS(1)), (0, uiS(1)), (-uiS(2), 0), (uiS(2), 0), (0, -uiS(2)), (0, uiS(2))] {
            c.label("CITADEL", lx + ox, ly + oy, size: uiSf(82), color: halo, weight: .heavy, shadow: false)
        }
        c.label("CITADEL", lx + uiS(1), ly, size: uiSf(82), color: red,  weight: .heavy, shadow: false)
        c.label("CITADEL", lx - uiS(1), ly, size: uiSf(82), color: cold, weight: .heavy, shadow: false)
        c.label("CITADEL", lx,          ly, size: uiSf(82), color: amberHi, weight: .heavy, shadow: false, glow: packRGBA(110, 80, 28))
        c.labelCentered("A STRATARIS WAR STORY", uiS(188), size: uiSf(17), color: amber, weight: .semibold, shadow: false, mono: true)

        // ── lower console ──
        if Int(t * 1.5) % 2 == 0 {
            c.labelCentered("> PRESS  FIRE  TO  DESCEND", uiS(252), size: uiSf(28), color: amberHi, weight: .bold, glow: packRGBA(60, 44, 0), mono: true)
        }
        c.labelCentered("[ B ]  BRIEFING        [ I ]  ENEMY INTEL", uiS(288), size: uiSf(16), color: amber, weight: .medium, shadow: false, mono: true)
        c.labelCentered("K  Keyboard      C  Controller      \u{2318},  Settings", uiS(312), size: uiSf(13), color: amberDim, weight: .medium, shadow: false, mono: true)

        // ── bottom status bar: three columns under a thin rule ──
        let sbY = uiS(356)
        c.fillRectBlend(uiS(20), sbY, W - uiS(40), uiS(1), amberDim, 0.45)
        let sy = sbY + uiS(7), sCol = packRGBA(150, 130, 80)
        c.label(hs.entries.first.map { "TOP \($0.score)  \(short($0.name))" } ?? "TOP --", uiS(26), sy, size: uiSf(12), color: sCol, weight: .medium, shadow: false, mono: true)
        c.labelRight("A JORVIK SOFTWARE GAME", W - uiS(26), sy, size: uiSf(12), color: packRGBA(120, 104, 66), weight: .medium, shadow: false, mono: true)
    }

    /// Deterministic digital-rain derived purely from `t` (the front-end keeps no
    /// per-frame state): each column streams at its own speed/phase, glyphs flicker
    /// on a time bucket, the head is bright (rarely crimson), the tail fades to black.
    private static func terminalRain(_ c: Canvas2D, _ t: Float) {
        func hash(_ a: Int, _ b: Int = 0) -> Int { var x = (a &* 73856093) ^ (b &* 19349663); x = (x >> 13) ^ x; return x & 0x7fffffff }
        // fine + dim: the rain reads BEHIND the title, never competing with it
        let cellW = uiS(11), cellH = uiS(13), tail = 11
        let cols = W / cellW + 1, rows = H / cellH, cycle = rows + tail
        let bucket = Int(t * 7)
        for i in 0..<cols {
            let hs = hash(i)
            let speed = 5.5 + Float(hs % 100) / 100 * 9
            let phase = Float(hs % cycle)
            let headRow = Int((t * speed + phase).truncatingRemainder(dividingBy: Float(cycle)))
            let crimsonHead = (hs % 17) == 0
            let x = i * cellW
            for k in 0..<tail {
                let row = headRow - k
                if row < 0 || row > rows { continue }
                let g = rainGlyphs[hash(i, row &* 31 &+ bucket) % rainGlyphs.count]
                let col = k == 0 ? (crimsonHead ? red : mixRGBA(packRGBA(0, 0, 0), amberHi, 0.82))
                                 : mixRGBA(packRGBA(0, 0, 0), amber, powf(1 - Float(k) / Float(tail), 2.1) * 0.62)
                c.label(g, x, row * cellH, size: uiSf(11), color: col, weight: .regular, shadow: false, mono: true)
            }
        }
    }

    /// CRT finish over the rain: tube vignette + scanlines (drawn before the UI text,
    /// so the logo and console stay crisp on top).
    private static func crtOverlay(_ c: Canvas2D) {
        for y in 0..<H {
            let edge = max(0, 1 - Float(min(y, H - 1 - y)) / Float(uiS(80)))
            if edge > 0 { c.fillRectBlend(0, y, W, 1, packRGBA(0, 0, 0), edge * 0.5) }
        }
        var y = 0
        while y < H { c.fillRectBlend(0, y, W, uiS(1), packRGBA(0, 0, 0), 0.16); y += uiS(2) }
    }


    /// The ARC corporate seal — a broken outer ring + an inner dome over "ARC",
    /// drawn from primitives so it scales with the UI. Used on the title and (faintly)
    /// in the HUD. Cold and clinical: ARC is meant to feel alien wherever it appears.
    static func arcSeal(_ c: Canvas2D, cx: Int, cy: Int, r: Int, color: UInt32, alpha: Float) {
        let R = Float(r), CX = Float(cx), CY = Float(cy)
        let steps = max(72, r * 8), top: Float = 4.712389        // gap at the top of the ring
        for s in 0..<steps {
            let ang = Float(s) / Float(steps) * 6.2831853
            var d = abs(ang - top); if d > 3.14159 { d = 6.2831853 - d }
            if d < 0.5 { continue }
            let x = Int(CX + cosf(ang) * R), y = Int(CY + sinf(ang) * R)
            c.blend(x, y, color, alpha); c.blend(x, y + 1, color, alpha * 0.5)
        }
        let ir = R * 0.52                                         // inner dome (upper arc)
        for s in 0...steps {
            let ang = 3.14159 + Float(s) / Float(steps) * 3.14159
            c.blend(Int(CX + cosf(ang) * ir), Int(CY + sinf(ang) * ir - R * 0.04), color, alpha)
        }
        c.labelCentered2("ARC", cx - r, r * 2, cy + Int(R * 0.04), size: uiSf(11), color: color, weight: .semibold, shadow: false)
    }

    static let briefingLines = [
        "We held the skies over the colony cluster",
        "for as long as we could. We did not hold",
        "them long enough.", "",
        "The fleet you fought at Strataris did not",
        "withdraw. It landed. Demeter went dark,",
        "then Tantalus, Boreas, Pandora, Vulcan,",
        "and Vesper. The citadels are occupied.", "",
        "You are going in on foot. Alone.",
        "Clear each citadel, floor by floor.",
        "Find the exit. Descend. Do not stop.", "",
        "There is no evacuation order — only how deep you get.",
    ]
    static func briefing(_ c: Canvas2D, t: Float) {
        backdrop(c, t, top: packRGBA(8, 14, 20), bottom: packRGBA(12, 26, 32))
        c.labelCentered("MISSION BRIEFING", uiS(30), size: uiSf(42), color: packRGBA(110, 200, 240), weight: .heavy, shadow: true, glow: packRGBA(10, 40, 60))
        c.labelCentered("// incoming transmission", uiS(84), size: uiSf(18), color: packRGBA(120, 200, 150), weight: .medium)
        var y = uiS(124)
        for line in briefingLines { c.labelCentered(line, y, size: uiSf(20), color: ink, weight: .medium); y += uiS(22) }
        if Int(t * 1.5) % 2 == 0 { c.labelCentered("Good hunting, marine.    [ ESC ]", H - uiS(32), size: uiSf(20), color: amber, weight: .semibold) }
    }

    static func intel(_ c: Canvas2D, t: Float) {
        backdrop(c, t, top: packRGBA(14, 8, 18), bottom: packRGBA(26, 10, 26))
        c.labelCentered("ENEMY INTEL", uiS(30), size: uiSf(42), color: packRGBA(220, 120, 220), weight: .heavy, shadow: true, glow: packRGBA(50, 10, 50))
        let kinds = MonsterKind.allCases
        let kind = kinds[Int(t / 2.6) % kinds.count]
        let ms = Sprites.shared.monster(kind)
        let spr = ms.walk[Int(t * 4) % 2][Int(t * 1.5) % 8]   // slowly rotates through the 8 views
        let k = Float(RenderConfig.num) / Float(RenderConfig.den)
        c.blitBitmapF(spr.pixels, spr.w, spr.h, (W - Int(Float(spr.w) * k)) / 2, uiS(86), scale: k)
        var dotX = (W - kinds.count * uiS(14)) / 2
        for i in kinds.indices { c.fillRect(dotX, uiS(268), uiS(9), uiS(5), i == kinds.firstIndex(of: kind) ? amber : packRGBA(80, 80, 92)); dotX += uiS(14) }
        c.labelCentered(kind.displayName, uiS(282), size: uiSf(34), color: amber, weight: .heavy, glow: packRGBA(50, 36, 0))
        c.labelCentered("THREAT \(kind.def.maxHealth) HP        \(kind.def.points) PTS", uiS(322), size: uiSf(18), color: packRGBA(220, 120, 120), weight: .semibold)
        c.labelCentered(kind.codexText.capitalizedSentence, uiS(346), size: uiSf(18), color: ink, weight: .medium)
        c.labelCentered("◀  ESC  ▶", H - uiS(20), size: uiSf(18), color: dim, weight: .medium)
    }

    /// The floor report shown INSIDE the elevator car (doors parted, world live
    /// behind it): a translucent panel over the 3-D view, not a separate screen.
    /// FIRE commits the descent (World swallows the shot).
    static func descendReport(_ c: Canvas2D, world: World, t: Float) {
        let pw = uiS(430), ph = world.secretTotal > 0 ? uiS(240) : uiS(208)
        let x0 = (W - pw) / 2, y0 = uiS(58)
        c.fillRectBlend(x0, y0, pw, ph, packRGBA(4, 10, 6), 0.78)
        for i in 0..<2 {                                            // green hairline frame
            c.fillRect(x0, y0 + (ph - 1) * i, pw, 1, packRGBA(60, 160, 90))
            c.fillRect(x0 + (pw - 1) * i, y0, 1, ph, packRGBA(60, 160, 90))
        }
        c.labelCentered("FLOOR CLEARED", y0 + uiS(16), size: uiSf(30), color: packRGBA(120, 230, 150), weight: .heavy, shadow: true, glow: packRGBA(10, 50, 24))
        c.labelCentered("\(world.colonyName) · FLOOR \(Progression.floorInBuilding(world.level))", y0 + uiS(54), size: uiSf(17), color: ink, weight: .semibold)
        var y = y0 + uiS(88)
        statRow(c, "KILLS", "\(world.killCount) / \(world.monsterTotal)", y); y += uiS(30)
        if world.secretTotal > 0 { statRow(c, "SECRETS", "\(world.secretsFound) / \(world.secretTotal)", y); y += uiS(30) }
        statRow(c, "SCORE", "\(world.score)", y, color: amber); y += uiS(38)
        if Int(t * 2) % 2 == 0 { c.labelCentered("PRESS  FIRE  TO  DESCEND", y, size: uiSf(22), color: amber, weight: .bold) }
    }

    static func levelComplete(_ c: Canvas2D, world: World, t: Float) {
        backdrop(c, t, top: packRGBA(6, 16, 10), bottom: packRGBA(10, 30, 16))
        c.labelCentered("CITADEL FLOOR CLEARED", uiS(74), size: uiSf(42), color: packRGBA(120, 230, 150), weight: .heavy, shadow: true, glow: packRGBA(10, 50, 24))
        c.labelCentered("\(world.colonyName) · FLOOR \(Progression.floorInBuilding(world.level))", uiS(126), size: uiSf(22), color: ink, weight: .semibold)
        statRow(c, "KILLS", "\(world.killCount) / \(world.monsterTotal)", uiS(184))
        if world.secretTotal > 0 { statRow(c, "SECRETS", "\(world.secretsFound) / \(world.secretTotal)", uiS(216)) }
        statRow(c, "SCORE", "\(world.score)", world.secretTotal > 0 ? uiS(248) : uiS(216), color: amber)
        if Int(t * 2) % 2 == 0 { c.labelCentered("PRESS  FIRE  TO  DESCEND", uiS(308), size: uiSf(28), color: amber, weight: .bold) }
    }

    // Citadel secured → the teleport jump to the next planet (shown between buildings).
    static func teleport(_ c: Canvas2D, world: World, t: Float) {
        backdrop(c, t, top: packRGBA(8, 10, 28), bottom: packRGBA(14, 16, 46))   // cold blue — a jump, not a descent
        c.labelCentered("CITADEL SECURED", uiS(60), size: uiSf(44), color: packRGBA(150, 200, 255), weight: .heavy, shadow: true, glow: packRGBA(18, 30, 72))
        c.labelCentered("\(world.colonyName) has fallen. The teleporter spins up.", uiS(116), size: uiSf(20), color: ink, weight: .medium)
        c.labelCentered("TELEPORTING TO", uiS(172), size: uiSf(20), color: dim, weight: .semibold)
        c.labelCentered(Progression.planetName(world.level + 1), uiS(202), size: uiSf(54), color: amber, weight: .heavy, shadow: true, glow: packRGBA(60, 48, 0))
        statRow(c, "SCORE", "\(world.score)", uiS(286), color: amber)
        if Int(t * 2) % 2 == 0 { c.labelCentered("PRESS  FIRE  TO  JUMP", uiS(328), size: uiSf(28), color: amber, weight: .bold) }
    }

    private static func statRow(_ c: Canvas2D, _ k: String, _ v: String, _ y: Int, color: UInt32 = 0xFFEEEEEE) {
        c.label(k, W / 2 - uiS(160), y, size: uiSf(22), color: dim, weight: .semibold)
        c.labelRight(v, W / 2 + uiS(160), y, size: uiSf(22), color: color, weight: .bold)
    }

    static func gameOver(_ c: Canvas2D, world: World, input: InputState, qualifies: Bool, t: Float) {
        backdrop(c, t, top: packRGBA(22, 4, 4), bottom: packRGBA(44, 8, 8))
        c.labelCentered("YOU DIED", uiS(64), size: uiSf(88), color: red, weight: .heavy, shadow: true, glow: redGlow)
        c.labelCentered("The \(world.colonyName) citadel holds.", uiS(168), size: uiSf(22), color: packRGBA(210, 160, 160), weight: .medium)
        statRow(c, "DEPTH REACHED", "\(world.level)", uiS(208))
        statRow(c, "FINAL SCORE", "\(world.score)", uiS(242), color: amber)
        if qualifies && input.nameEntryActive {
            c.labelCentered("A NEW RECORD — ENTER YOUR NAME", uiS(286), size: uiSf(20), color: packRGBA(120, 230, 150), weight: .semibold)
            let name = input.nameBuffer.isEmpty ? " " : input.nameBuffer
            let cursor = Int(t * 2) % 2 == 0 ? "_" : " "
            c.drawUnicodeCentered(name + cursor, uiS(310), fontSize: uiSf(40), 1, 1, 0.65)
            c.labelCentered("[ RETURN ]", uiS(362), size: uiSf(18), color: dim, weight: .medium)
        } else if Int(t * 2) % 2 == 0 {
            c.labelCentered("PRESS  ENTER", uiS(300), size: uiSf(28), color: amber, weight: .bold)
        }
    }

    static func highScores(_ c: Canvas2D, hs: HighScores, t: Float, highlight: Int = -1) {
        backdrop(c, t, top: packRGBA(10, 10, 22), bottom: packRGBA(16, 16, 36))
        c.labelCentered("HALL OF THE FALLEN", uiS(30), size: uiSf(42), color: packRGBA(200, 204, 244), weight: .heavy, shadow: true, glow: packRGBA(12, 12, 50))
        var y = uiS(90)
        if hs.entries.isEmpty { c.labelCentered("No records yet — be the first.", uiS(190), size: uiSf(22), color: dim, weight: .medium) }
        for (i, e) in hs.entries.enumerated() {
            let col = i == highlight ? amber : (i == 0 ? packRGBA(230, 230, 240) : ink)
            c.label("\(i + 1).", uiS(72), y, size: uiSf(21), color: col, weight: .bold)
            c.label(short(e.name), uiS(116), y, size: uiSf(21), color: col, weight: i == highlight ? .bold : .medium)
            c.labelRight("\(e.colony) D\(e.depth)", W - uiS(180), y, size: uiSf(18), color: dim, weight: .regular)
            c.labelRight("\(e.score)", W - uiS(72), y, size: uiSf(21), color: col, weight: .bold)
            y += uiS(27)
        }
        if Int(t * 2) % 2 == 0 { c.labelCentered("PRESS  ENTER", H - uiS(32), size: uiSf(24), color: amber, weight: .bold) }
    }

    static func paused(_ c: Canvas2D) {
        c.fillRectBlend(0, 0, W, H, packRGBA(0, 0, 0), 0.6)
        c.labelCentered("PAUSED", H / 2 - uiS(38), size: uiSf(66), color: amber, weight: .heavy, shadow: true)
        c.labelCentered("P  Resume          ESC  Abandon Run", H / 2 + uiS(36), size: uiSf(22), color: ink, weight: .medium)
    }

    private static func short(_ s: String) -> String { s.count > 16 ? String(s.prefix(16)) : s }
}

private extension String {
    var capitalizedSentence: String {
        let lower = lowercased(); guard let first = lower.first else { return self }
        return String(first).uppercased() + lower.dropFirst()
    }
}
