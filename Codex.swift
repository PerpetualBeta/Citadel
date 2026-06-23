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

    static func title(_ c: Canvas2D, t: Float, hs: HighScores) {
        backdrop(c, t)
        c.labelCentered("CITADEL", uiS(44), size: uiSf(96), color: red, weight: .heavy, shadow: true, glow: redGlow)
        c.labelCentered("A STRATARIS WAR STORY", uiS(158), size: uiSf(21), color: amber, weight: .semibold)
        c.labelCentered("The aliens hold the colonies. Take them back.", uiS(192), size: uiSf(20), color: dim, weight: .medium)
        if let top = hs.entries.first {
            c.labelCentered("TOP — \(short(top.name))   \(top.score)", uiS(226), size: uiSf(18), color: packRGBA(200, 196, 150), weight: .semibold)
        }
        if Int(t * 1.5) % 2 == 0 {
            c.labelCentered("PRESS  FIRE  TO  DESCEND", uiS(268), size: uiSf(34), color: amber, weight: .bold, glow: packRGBA(60, 48, 0))
        }
        c.labelCentered("B  Briefing          I  Enemy Intel", uiS(322), size: uiSf(20), color: packRGBA(150, 178, 220), weight: .medium)
        c.labelCentered("K  Keyboard      C  Controller      ⌘,  Settings", uiS(350), size: uiSf(18), color: dim, weight: .medium)
        c.labelCentered("A Jorvik Software game", H - uiS(26), size: uiSf(17), color: packRGBA(120, 120, 138), weight: .regular)
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
