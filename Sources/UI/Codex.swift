// Citadel — front-end screens (title, briefing, enemy intel, floor/secured
// reports, ride + teleport interstitials, game over / name entry, high scores,
// pause). Drawn into the same Canvas2D with crisp Core Text, laid out for the
// logical 640×400 space.

import Foundation
import AppKit

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

    /// The prompt verb for "confirm", by input device: a connected pad's FIRE
    /// button confirms menus; on the keyboard it's the return key (fire does
    /// NOT confirm the title — saying "press fire" there sent people clicking).
    static func confirmName(pad: Bool) -> String { pad ? "FIRE" : "[ENTER]" }

    /// The title is an ARC subsurface terminal. Most of it is glyph-rain; the brand
    /// lives in the corner seal and the boot-log, never explained.
    static func title(_ c: Canvas2D, t: Float, hs: HighScores, pad: Bool = false) {
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
            c.labelCentered("> PRESS  \(confirmName(pad: pad))  TO  DESCEND", uiS(252), size: uiSf(28), color: amberHi, weight: .bold, glow: packRGBA(60, 44, 0), mono: true)
        }
        c.labelCentered("[B]  BRIEFING        [I]  FIELD INTEL", uiS(288), size: uiSf(16), color: amber, weight: .medium, shadow: false, mono: true)
        // [CMD,] not [⌘,]: the ⌘ glyph falls back out of the mono font and its
        // clashing metrics wreck the kerning — and a terminal wouldn't own it.
        // The "]" is hand-kerned into the comma's mono cell (which is mostly
        // whitespace on the right), or "[CMD,]" gapes before the bracket.
        let hint1 = "[K]  Keyboard      [C]  Controller      [CMD,"
        let hint2 = "]  Settings"
        let hintSz = uiSf(13)
        let hw1 = c.labelWidth(hint1, size: hintSz, weight: .medium, mono: true)
        let hw2 = c.labelWidth(hint2, size: hintSz, weight: .medium, mono: true)
        let kern = c.labelWidth(",", size: hintSz, weight: .medium, mono: true) * 2 / 5
        let hx = (W - (hw1 + hw2 - kern)) / 2
        c.label(hint1, hx, uiS(312), size: hintSz, color: amberDim, weight: .medium, shadow: false, mono: true)
        c.label(hint2, hx + hw1 - kern, uiS(312), size: hintSz, color: amberDim, weight: .medium, shadow: false, mono: true)

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
        "We held the skies over the colony cluster for as",
        "long as we could. We did not hold them long enough.",
        "",
        "The fleet you fought at Strataris did not withdraw.",
        "It landed. Demeter went dark, then Tantalus, Boreas,",
        "Pandora, Vulcan, and Vesper. The citadels are occupied.",
        "",
        "Whatever the landings carried has nested. Every floor",
        "is crawling, and each brood keeps a Queen — kill her",
        "and BURN her, or she rises again behind you.",
        "",
        "You are going in on foot. Alone. Clear each citadel,",
        "floor by floor. Find the exit. Descend. Do not stop.",
        "",
        "Corporate has withdrawn its channels. There is no",
        "evacuation order — only how deep you get.",
    ]
    static func briefing(_ c: Canvas2D, t: Float) {
        backdrop(c, t, top: packRGBA(8, 14, 20), bottom: packRGBA(12, 26, 32))
        c.labelCentered("MISSION BRIEFING", uiS(26), size: uiSf(40), color: packRGBA(110, 200, 240), weight: .heavy, shadow: true, glow: packRGBA(10, 40, 60))
        c.labelCentered("// incoming transmission", uiS(76), size: uiSf(17), color: packRGBA(120, 200, 150), weight: .medium)
        var y = uiS(106)
        for line in briefingLines { c.labelCentered(line, y, size: uiSf(16), color: ink, weight: .medium); y += uiS(16) }
        if Int(t * 1.5) % 2 == 0 { c.labelCentered("Good hunting, marine.    [ESC]", H - uiS(24), size: uiSf(17), color: amber, weight: .semibold) }
    }

    // ── FIELD INTEL — a paged dossier ────────────────────────────────────────
    // Five plates: the two castes (static front + left-profile portraits,
    // framed from their own bounds so nothing crops — IntelPortraits), the
    // arsenal, the field supply, and what actually hurts. ◀ ▶ leaf through it;
    // it's a codex, not a slideshow — nothing animates but the backdrop.
    static let intelPages = 5

    static func intel(_ c: Canvas2D, t: Float, page: Int = 0) {
        backdrop(c, t, top: packRGBA(14, 8, 18), bottom: packRGBA(26, 10, 26))
        c.labelCentered("FIELD INTEL", uiS(20), size: uiSf(36), color: packRGBA(220, 120, 220), weight: .heavy, shadow: true, glow: packRGBA(50, 10, 50))
        switch page {
        case 0: creaturePage(c, .alien, t)
        case 1: creaturePage(c, .queen, t)
        case 2: arsenalPage(c)
        case 3: supplyPage(c)
        default: survivalPage(c)
        }
        var dotX = (W - intelPages * uiS(14)) / 2
        for i in 0..<intelPages { c.fillRect(dotX, H - uiS(28), uiS(9), uiS(5), i == page ? amber : packRGBA(80, 80, 92)); dotX += uiS(14) }
        c.labelCentered("◀ ▶  TURN PAGE        [ESC]  CLOSE", H - uiS(17), size: uiSf(13), color: dim, weight: .medium)
    }

    /// Wrap body copy to a width (one long label used to run off both edges).
    private static func wrapLines(_ c: Canvas2D, _ text: String, size: CGFloat, weight: NSFont.Weight, maxW: Int) -> [String] {
        var lines: [String] = [""]
        for word in text.split(separator: " ") {
            let cand = lines[lines.count - 1].isEmpty ? String(word) : lines[lines.count - 1] + " " + word
            if c.labelWidth(cand, size: size, weight: weight) > maxW { lines.append(String(word)) }
            else { lines[lines.count - 1] = cand }
        }
        return lines
    }

    // ── page: one caste — front + left profile, then the dossier line ──
    private static func creaturePage(_ c: Canvas2D, _ kind: MonsterKind, _ t: Float) {
        c.labelCentered(kind.displayName, uiS(58), size: uiSf(26), color: amber, weight: .heavy, glow: packRGBA(50, 36, 0))
        let boxTop = uiS(86)
        let views: [(IntelPortraits.View, String)] = [(.front, "FRONT"), (.profile, "LEFT PROFILE")]
        let plates = views.map { IntelPortraits.plate(kind, $0.0) }
        // pair layout from the plates' true widths; downscale only if the pair
        // would overflow the page margins
        let gap = uiS(56), nominalW = IntelPortraits.plateH * 3 / 4
        let w0 = plates[0]?.w ?? nominalW, w1 = plates[1]?.w ?? nominalW
        var k: Float = 1
        let maxPair = W - uiS(80)
        if w0 + w1 + gap > maxPair { k = Float(maxPair - gap) / Float(w0 + w1) }
        var x = (W - (Int(Float(w0) * k) + Int(Float(w1) * k) + gap)) / 2
        for (i, (_, tag)) in views.enumerated() {
            let dw = Int(Float(i == 0 ? w0 : w1) * k)
            if let p = plates[i] {
                // soft ground shadow at the creature's true foot line, plate over it
                let footY = boxTop + Int(Float(p.footY) * k)
                let cx = x + dw / 2, hw = max(uiS(20), dw * 2 / 5), hh = uiS(5)
                for jj in -hh...hh { for ii in -hw...hw {
                    let dd = Float(ii * ii) / Float(hw * hw) + Float(jj * jj) / Float(hh * hh)
                    if dd < 1 { c.blend(cx + ii, footY + jj, packRGBA(0, 0, 0), (1 - dd) * 0.45) }
                } }
                c.blitBitmapF(p.pixels, p.w, p.h, x, boxTop, scale: k)
            } else {
                // plates render in the background from launch; if the codex is
                // reached first, the feed is still decoding
                let dh = Int(Float(IntelPortraits.plateH) * k)
                for e in 0..<2 {
                    c.fillRectBlend(x, boxTop + (dh - 1) * e, dw, 1, packRGBA(150, 90, 160), 0.5)
                    c.fillRectBlend(x + (dw - 1) * e, boxTop, 1, dh, packRGBA(150, 90, 160), 0.5)
                }
                if Int(t * 2) % 2 == 0 {
                    c.labelCentered2("DECRYPTING", x, dw, boxTop + dh / 2 - uiS(8), size: uiSf(13), color: dim, weight: .semibold, shadow: false)
                }
            }
            c.labelCentered2(tag, x, dw, boxTop + Int(Float(IntelPortraits.plateH) * k) + uiS(6), size: uiSf(12), color: dim, weight: .semibold, shadow: false)
            x += dw + gap
        }
        c.labelCentered("THREAT \(kind.def.maxHealth) HP        \(kind.def.points) PTS", uiS(300), size: uiSf(15), color: packRGBA(220, 120, 120), weight: .semibold)
        var ty = uiS(320)
        for line in wrapLines(c, kind.codexText.capitalizedSentence, size: uiSf(15), weight: .medium, maxW: uiS(580)) {
            c.labelCentered(line, ty, size: uiSf(15), color: ink, weight: .medium); ty += uiS(16)
        }
    }

    // ── page: the arsenal — what kills, what feeds it, what it's FOR ──
    private static func arsenalPage(_ c: Canvas2D) {
        c.labelCentered("THE ARSENAL", uiS(58), size: uiSf(26), color: amber, weight: .heavy, glow: packRGBA(50, 36, 0))
        let rows: [(icon: ItemKind, name: String, tag: String, desc: String)] = [
            (.ammoCells, "PLASMA RIFLE", "CELLS · CARRY \(AmmoType.cells.capacity)",
             "Always carried. Fast energy bolts — the workhorse, and the only weapon that wounds the Queen. Refills at wall sockets."),
            (.ammoFuel, "FLAMETHROWER", "FUEL · CARRY \(AmmoType.fuel.capacity)",
             "Always carried. A short cone of fire — the only thing that burns a corpse, or the Queen, away for good. Refills at fuel drums."),
            (.weaponRocket, "ROCKET LAUNCHER", "ROCKETS · CARRY \(AmmoType.rockets.capacity)",
             "Found in the field. Heavy splash — clears a packed corridor and ruptures drums across the room. Its blast does not know your name."),
            (.mineCrate, "PROXIMITY MINES", "[G] DEPLOY · CARRY \(Player.maxMines)",
             "The meanest bang you carry. Arms in a second, then takes whatever crosses it — you included. Blasts chain into drums and other mines."),
        ]
        var y = uiS(88)
        for r in rows {
            itemIcon(c, r.icon, uiS(92), y, box: uiS(30))
            c.label(r.name, uiS(140), y, size: uiSf(17), color: amberHi, weight: .bold, shadow: false)
            c.labelRight(r.tag, W - uiS(92), y + uiS(3), size: uiSf(12), color: dim, weight: .semibold, shadow: false, mono: true)
            var dy = y + uiS(20)
            for line in wrapLines(c, r.desc, size: uiSf(13), weight: .medium, maxW: uiS(448)) {
                c.label(line, uiS(140), dy, size: uiSf(13), color: ink, weight: .medium, shadow: false); dy += uiS(14)
            }
            y += uiS(64)
        }
    }

    // ── page: the field supply — every pickup, and the hardware that refills you ──
    private static func supplyPage(_ c: Canvas2D) {
        c.labelCentered("FIELD SUPPLY", uiS(58), size: uiSf(26), color: amber, weight: .heavy, glow: packRGBA(50, 36, 0))
        let green = packRGBA(120, 220, 140), blue = packRGBA(130, 180, 245)
        let rows: [(icons: [ItemKind], name: String, tint: UInt32, effect: String)] = [
            ([.stim], "STIMPACK", ink, "+\(ItemKind.stimHeal) HEALTH"),
            ([.medkit], "MEDKIT", ink, "+\(ItemKind.medkitHeal) HEALTH"),
            ([.armor], "ARMOUR REPAIR", green, "+\(ItemKind.armorRepair) ARMOUR · UP TO \(ItemKind.armorRepairCap)"),
            ([.megaArmor], "FULL ARMOUR", blue, "A FRESH SUIT — ARMOUR \(Player.maxArmor)"),
            ([.ammoCells, .ammoFuel, .ammoRockets], "AMMUNITION", ink,
             "CELLS \(ItemKind.cellsPerPickup) · FUEL \(ItemKind.fuelPerPickup) · ROCKETS \(ItemKind.rocketsPerPickup)"),
            ([.mineCrate], "MINE CRATE", ink, "+\(ItemKind.minesPerCrate) PROXIMITY MINES"),
            ([.keyRed, .keyBlue, .keyYellow], "KEYCARDS", ink, "EACH OPENS ITS COLOUR-SEALED DOOR"),
        ]
        var y = uiS(86)
        for r in rows {
            var ix = uiS(88)
            for icon in r.icons { itemIcon(c, icon, ix, y - uiS(3), box: uiS(22)); ix += uiS(24) }
            c.label(r.name, uiS(164), y, size: uiSf(15), color: r.tint, weight: .semibold, shadow: false)
            c.labelRight(r.effect, W - uiS(88), y + uiS(2), size: uiSf(12), color: dim, weight: .medium, shadow: false, mono: true)
            y += uiS(25)
        }
        // the fixed installations — the wall/floor hardware you work rather than
        // carry. Name + a description line, so the mechanic has room to breathe.
        c.labelCentered("FIELD HARDWARE", uiS(270), size: uiSf(15), color: amber, weight: .bold, shadow: false)
        socketIcon(c, uiS(90), uiS(290), h: uiS(22))
        c.label("RECHARGE SOCKET", uiS(140), uiS(290), size: uiSf(15), color: ink, weight: .semibold, shadow: false)
        c.label("Stand close — the plasma rifle drinks cells; a drained panel recovers in time.",
                uiS(140), uiS(307), size: uiSf(13), color: dim, weight: .medium, shadow: false)
        drumIcon(c, uiS(92), uiS(326), h: uiS(22))
        c.label("FUEL DRUM", uiS(140), uiS(326), size: uiSf(15), color: ink, weight: .semibold, shadow: false)
        c.label("Stand close to refuel the flamethrower — or shoot it: a drum is a bomb.",
                uiS(140), uiS(343), size: uiSf(13), color: dim, weight: .medium, shadow: false)
    }

    /// A floor pickup's actual sprite, fitted into a square box (centred, whole).
    private static func itemIcon(_ c: Canvas2D, _ kind: ItemKind, _ x: Int, _ y: Int, box: Int) {
        let spr = Sprites.shared.item(kind)
        let s = min(Float(box) / Float(spr.w), Float(box) / Float(spr.h))
        c.blitBitmapF(spr.pixels, spr.w, spr.h,
                      x + (box - Int(Float(spr.w) * s)) / 2, y + (box - Int(Float(spr.h) * s)) / 2, scale: s)
    }

    /// The recharge socket, as it reads in the world: dark housing, cyan charge bar.
    private static func socketIcon(_ c: Canvas2D, _ x: Int, _ y: Int, h: Int) {
        let w = h * 3 / 4
        c.fillRect(x, y, w, h, packRGBA(43, 48, 59))                          // housing
        c.fillRect(x + uiS(2), y + uiS(2), w - uiS(4), h - uiS(4), packRGBA(18, 20, 26))   // inset faceplate
        let segs = 4, segH = max(1, (h - uiS(10)) / segs - 1)
        for k in 0..<segs {                                                   // lit capacity bar
            c.fillRect(x + uiS(4), y + h - uiS(6) - (k + 1) * (segH + 1), w / 2 - uiS(4), segH, packRGBA(80, 220, 250))
        }
        c.fillRect(x + w - uiS(8), y + h / 2 - uiS(2), uiS(4), uiS(4), packRGBA(56, 128, 153))   // port lamp
    }

    /// A fuel drum, as it reads in the world: red-oxide barrel, rolled rim, hoops.
    private static func drumIcon(_ c: Canvas2D, _ x: Int, _ y: Int, h: Int) {
        let w = h * 3 / 4
        let body = packRGBA(117, 43, 31), rim = packRGBA(82, 30, 22)
        c.fillRect(x, y + uiS(2), w, h - uiS(2), body)
        c.fillRect(x - uiS(1), y, w + uiS(2), uiS(3), rim)                    // rolled top rim, proud
        for k in 1...2 { c.fillRect(x, y + uiS(2) + k * (h - uiS(4)) / 3, w, uiS(1), rim) }   // rolling hoops
    }

    // ── page: survival — what hurts, how badly, and what mends it ──
    private static func survivalPage(_ c: Canvas2D) {
        c.labelCentered("SURVIVAL", uiS(58), size: uiSf(26), color: amber, weight: .heavy, glow: packRGBA(50, 36, 0))
        let orange = packRGBA(240, 140, 60)
        c.labelCentered("WHAT HURTS", uiS(86), size: uiSf(15), color: packRGBA(220, 120, 120), weight: .bold, shadow: false)
        let threats: [(name: String, sev: String, col: UInt32, note: String)] = [
            ("DRONE BITE", "MAJOR", orange, "small on its own — but the pack flanks, and the wounds add up fast"),
            ("QUEEN STRIKE", "SEVERE", red, "up to half your health in one blow — stay out of her reach"),
            ("ACID POOLS", "MINOR", amber, "a slow burn underfoot — and it seeps straight through armour"),
            ("BLAST SPLASH", "SEVERE", red, "rockets, mines and drums burn friend and foe alike — stand well clear"),
        ]
        var y = uiS(106)
        for th in threats {
            c.label(th.name, uiS(150), y, size: uiSf(16), color: ink, weight: .semibold, shadow: false)
            c.labelRight(th.sev, W - uiS(150), y, size: uiSf(16), color: th.col, weight: .bold, shadow: false)
            c.label(th.note, uiS(150), y + uiS(18), size: uiSf(13), color: dim, weight: .medium, shadow: false)
            y += uiS(38)
        }
        c.labelCentered("STAYING ALIVE", uiS(262), size: uiSf(15), color: packRGBA(120, 220, 140), weight: .bold, shadow: false)
        var ly = uiS(282)
        for line in ["Armour turns away a third of every hit — acid excepted.",
                     "Stims and medkits mend flesh; green plate patches armour, blue replaces the suit.",
                     "Sockets refill cells and drums refill fuel — health only comes in crates."] {
            c.labelCentered(line, ly, size: uiSf(14), color: ink, weight: .medium); ly += uiS(18)
        }
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

    /// The citadel-secured report shown ON the teleporter pad (world live behind
    /// it): same diegetic panel language as the descend report, but cold — the
    /// transit machinery is ARC's, not the colony's. FIRE commits the jump.
    static func securedReport(_ c: Canvas2D, world: World, t: Float) {
        let pw = uiS(430), ph = world.secretTotal > 0 ? uiS(240) : uiS(208)
        let x0 = (W - pw) / 2, y0 = uiS(58)
        c.fillRectBlend(x0, y0, pw, ph, packRGBA(4, 8, 12), 0.78)
        for i in 0..<2 {                                            // cold hairline frame
            c.fillRect(x0, y0 + (ph - 1) * i, pw, 1, packRGBA(70, 140, 170))
            c.fillRect(x0 + (pw - 1) * i, y0, 1, ph, packRGBA(70, 140, 170))
        }
        c.labelCentered("CITADEL SECURED", y0 + uiS(16), size: uiSf(30), color: packRGBA(150, 210, 245), weight: .heavy, shadow: true, glow: packRGBA(14, 34, 52))
        c.labelCentered("\(world.colonyName) retaken · destination \(Progression.planetName(world.level + 1))", y0 + uiS(54), size: uiSf(17), color: ink, weight: .semibold)
        var y = y0 + uiS(88)
        statRow(c, "KILLS", "\(world.killCount) / \(world.monsterTotal)", y); y += uiS(30)
        if world.secretTotal > 0 { statRow(c, "SECRETS", "\(world.secretsFound) / \(world.secretTotal)", y); y += uiS(30) }
        statRow(c, "SCORE", "\(world.score)", y, color: amber); y += uiS(38)
        if Int(t * 2) % 2 == 0 { c.labelCentered("PRESS  FIRE  TO  JUMP", y, size: uiSf(22), color: packRGBA(150, 210, 245), weight: .bold) }
    }

    /// The descent readout over the title-ride lift car: destination + a
    /// blinking transit cursor. This is the LOADING screen — it stays up
    /// exactly as long as generation takes. Deliberately nothing else: the
    /// car itself (swaying lamp, shaft lights sweeping past) sells the drop,
    /// same as every between-floor ride.
    static func rideOverlay(_ c: Canvas2D, level: Int, t: Float) {
        let planet = Progression.planetName(level)
        let floor = Progression.floorInBuilding(level)
        c.fillRectBlend(0, uiS(24), W, uiS(56), packRGBA(0, 0, 0), 0.35)
        c.labelCentered("ARC TRANSIT // DESCENDING", uiS(32), size: uiSf(13), color: coldDim, weight: .semibold, shadow: false, mono: true)
        let cursor = Int(t * 2) % 2 == 0 ? "\u{2588}" : " "
        c.labelCentered("\(planet) · FLOOR \(floor) \(cursor)", uiS(50), size: uiSf(20), color: cold, weight: .bold, shadow: false, mono: true)
    }

    /// The story card burned through the teleport static: the citadel is down,
    /// where the beam is taking you, the running score. The text jitters and
    /// drops rows like a weak carrier riding broadband noise.
    static func teleportCard(_ c: Canvas2D, world: World, t: Float) {
        func jx(_ k: Float) -> Int { Int(sinf(t * 37 + k) * 1.7 + sinf(t * 61 + k * 2.3)) }
        let x0 = W / 2
        c.fillRectBlend(0, uiS(96), W, uiS(180), packRGBA(0, 0, 0), 0.5)
        c.fillRectBlend(0, uiS(96), W, 1, packRGBA(120, 180, 210), 0.4)
        c.fillRectBlend(0, uiS(276) - 1, W, 1, packRGBA(120, 180, 210), 0.4)
        // each row occasionally drops out for a frame — carrier slipping
        func row(_ s: String, _ y: Int, _ size: CGFloat, _ col: UInt32, _ w: NSFont.Weight, _ k: Float, glow: UInt32? = nil) {
            if Int((t + k) * 9) % 13 == 0 { return }
            let tw = c.labelWidth(s, size: size, weight: w, mono: true)
            c.label(s, x0 - tw / 2 + jx(k), y, size: size, color: col, weight: w, shadow: false, glow: glow, mono: true)
        }
        row("CITADEL SECURED", uiS(108), uiSf(30), packRGBA(150, 210, 245), .heavy, 0.7, glow: packRGBA(14, 34, 52))
        row("\(world.colonyName) RETAKEN", uiS(148), uiSf(15), ink, .medium, 1.9)
        row("TELEPORTING TO", uiS(178), uiSf(14), dim, .semibold, 3.1)
        row(Progression.planetName(world.level + 1), uiS(196), uiSf(44), amber, .heavy, 4.3, glow: packRGBA(60, 48, 0))
        row("SCORE \(world.score)", uiS(252), uiSf(16), amber, .bold, 5.6)
    }

    private static func statRow(_ c: Canvas2D, _ k: String, _ v: String, _ y: Int, color: UInt32 = 0xFFEEEEEE) {
        c.label(k, W / 2 - uiS(160), y, size: uiSf(22), color: dim, weight: .semibold)
        c.labelRight(v, W / 2 + uiS(160), y, size: uiSf(22), color: color, weight: .bold)
    }

    static func gameOver(_ c: Canvas2D, world: World, input: InputState, qualifies: Bool, t: Float, pad: Bool = false) {
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
            c.labelCentered("[RETURN]", uiS(362), size: uiSf(18), color: dim, weight: .medium)
        } else if Int(t * 2) % 2 == 0 {
            c.labelCentered("PRESS  \(confirmName(pad: pad))", uiS(300), size: uiSf(28), color: amber, weight: .bold)
        }
    }

    static func highScores(_ c: Canvas2D, hs: HighScores, t: Float, highlight: Int = -1, pad: Bool = false) {
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
        if Int(t * 2) % 2 == 0 { c.labelCentered("PRESS  \(confirmName(pad: pad))", H - uiS(32), size: uiSf(24), color: amber, weight: .bold) }
    }

    static func paused(_ c: Canvas2D) {
        // frosted glass: blur the frozen frame, then a light dark wash — the
        // world stays readable behind the card (pause renders ONCE, so the
        // CPU blur costs nothing per frame)
        c.boxBlur(radius: uiS(5), passes: 3)
        c.fillRectBlend(0, 0, W, H, packRGBA(6, 8, 12), 0.38)
        c.labelCentered("PAUSED", H / 2 - uiS(38), size: uiSf(66), color: amber, weight: .heavy, shadow: true)
        c.labelCentered("[P] Resume          [ESC] Abandon Run", H / 2 + uiS(36), size: uiSf(22), color: ink, weight: .medium)
    }

    private static func short(_ s: String) -> String { s.count > 16 ? String(s.prefix(16)) : s }
}

private extension String {
    /// Lower-case the (ALL-CAPS authored) dossier text, then capitalise the start
    /// of every sentence — the old version only lifted the first letter, so
    /// "...pack hunter. carries no weapon..." shipped mid-sentence-looking.
    var capitalizedSentence: String {
        var out = "", startOfSentence = true
        for ch in lowercased() {
            if startOfSentence && ch.isLetter { out.append(Character(ch.uppercased())); startOfSentence = false }
            else { out.append(ch); if ch == "." || ch == "!" || ch == "?" { startOfSentence = true } }
        }
        return out
    }
}
