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

    /// The prompt verb for "confirm", by input device: a connected pad's FIRE
    /// button confirms menus; on the keyboard it's the return key (fire does
    /// NOT confirm the title — saying "press fire" there sent people clicking).
    static func confirmName(pad: Bool) -> String { pad ? "FIRE" : "[ENTER]" }

    /// The title is an ARC subsurface terminal. Most of it is glyph-rain; the brand
    /// lives in the corner seal and the boot-log, never explained.
    static func title(_ c: Canvas2D, t: Float, hs: HighScores, pad: Bool = false) {
        TitleArt.draw(c, t: t)                              // the animated xenomorph plate

        // Legibility scrim: a soft left→right fade so the UI column reads over the
        // plate's near-black left side (and settles the grain under the text).
        let scrimW = uiS(330)
        for x in 0..<scrimW {
            let a = 0.6 * powf(1 - Float(x) / Float(scrimW), 1.6)
            if a > 0.012 { c.fillRectBlend(x, 0, 1, H, packRGBA(0, 0, 0), a) }
        }

        let lx = uiS(30)
        let black = packRGBA(0, 0, 0)

        // ── ARC seal + node tag (brand seeding — cold, clinical, unexplained) ──
        arcSeal(c, cx: lx + uiS(15), cy: uiS(30), r: uiS(14), color: coldDim, alpha: 0.72)
        let hsLine = hs.entries.first.map { "// High Score: \($0.name) - \(commaSep($0.score))" } ?? "// No scores logged"
        c.label(hsLine, lx + uiS(38), uiS(25), size: uiSf(11),
                color: mixRGBA(black, cold, 0.72), weight: .medium, shadow: false, mono: true)

        // ── CITADEL — left-aligned, bright amber core + soft halo + chromatic fringe ──
        let logoSz = uiSf(78), ly = uiS(88)
        let lw = c.labelWidth("CITADEL", size: logoSz, weight: .heavy)
        let halo = mixRGBA(black, amber, 0.22)
        for (ox, oy) in [(-uiS(1), 0), (uiS(1), 0), (0, -uiS(1)), (0, uiS(1)), (-uiS(2), 0), (uiS(2), 0), (0, -uiS(2)), (0, uiS(2))] {
            c.label("CITADEL", lx + ox, ly + oy, size: logoSz, color: halo, weight: .heavy, shadow: false)
        }
        c.label("CITADEL", lx + uiS(1), ly, size: logoSz, color: red,     weight: .heavy, shadow: false)
        c.label("CITADEL", lx - uiS(1), ly, size: logoSz, color: cold,    weight: .heavy, shadow: false)
        c.label("CITADEL", lx,          ly, size: logoSz, color: amberHi, weight: .heavy, shadow: false, glow: packRGBA(110, 80, 28))
        // subtitle centred under the CITADEL wordmark
        let subtitle = "A STRATARIS WAR STORY", subSz = uiSf(16)
        let subW = c.labelWidth(subtitle, size: subSz, weight: .semibold, mono: true)
        c.label(subtitle, lx + (lw - subW) / 2, uiS(162), size: subSz,
                color: amber, weight: .semibold, shadow: false, mono: true)

        // ── console: descend prompt (blink) + menu ──
        if Int(t * 1.5) % 2 == 0 {
            c.label("> PRESS \(confirmName(pad: pad)) TO DESCEND", lx, uiS(266), size: uiSf(25),
                    color: amberHi, weight: .bold, shadow: false, glow: packRGBA(60, 44, 0), mono: true)
        }
        c.label("[B] BRIEFING      [I] FIELD INTEL", lx, uiS(298), size: uiSf(15),
                color: amber, weight: .medium, shadow: false, mono: true)
        // Keyboard / Controller / Settings live in the app menu now, not on the title.

        // ── bottom: top score + studio credit, kept in the clear left column ──
        // studio credit, bottom-right — two lines, teal with a black outline so it
        // reads over the alien's lit leg.
        let crSz = uiSf(12), crRight = W - uiS(24)
        func credit(_ s: String, _ y: Int) {
            let w = c.labelWidth(s, size: crSz, weight: .semibold, mono: true)
            c.label(s, crRight - w, y, size: crSz, color: cold, weight: .semibold, shadow: false, glow: packRGBA(0, 0, 0), mono: true)
        }
        credit("Produced by", uiS(356))
        credit("Jorvik Software", uiS(374))
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
        "We held the skies over the Strataris cluster for as",
        "long as we could. We did not hold them long enough.",
        "The fleet we fought did not withdraw. It landed.",
        "Demeter went dark, then Tantalus, Boreas, Pandora,",
        "Vulcan, and Vesper.",
        "",
        "The citadels are occupied.",
        "",
        "Whatever the landings carried has nested. Every floor",
        "is crawling, and each brood keeps a Queen - kill her",
        "and BURN her, or she rises again behind you.",
        "",
        "You are going in on foot. Alone. Clear each citadel,",
        "floor by floor. Find the exit. Descend. Do not stop.",
        "Corporate has withdrawn its channels. There is no",
        "evacuation order — only how deep you get.",
    ]
    static func briefing(_ c: Canvas2D, t: Float) {
        HallArt.draw(c, t: t)                               // the drone concept plate — mirrors the title / Hall

        // left→right legibility scrim so the transmission reads over the dark flank
        let scrimW = uiS(376)
        for x in 0..<scrimW {
            let a = 0.66 * powf(1 - Float(x) / Float(scrimW), 1.4)
            if a > 0.012 { c.fillRectBlend(x, 0, 1, H, packRGBA(0, 0, 0), a) }
        }

        let lx = uiS(30)
        let black = packRGBA(0, 0, 0)
        let cyan = packRGBA(150, 214, 244)                  // the briefing's "transmission" identity

        // ── masthead: MISSION / BRIEFING — the wordmark treatment (halo + glow), in the
        //    transmission cyan rather than the title's amber ──
        func head(_ s: String, _ y: Int) {
            let sz = uiSf(40)
            let halo = mixRGBA(black, cyan, 0.22)
            for (ox, oy) in [(-uiS(1), 0), (uiS(1), 0), (0, -uiS(1)), (0, uiS(1)), (-uiS(2), 0), (uiS(2), 0)] {
                c.label(s, lx + ox, y + oy, size: sz, color: halo, weight: .heavy, shadow: false)
            }
            c.label(s, lx, y, size: sz, color: cyan, weight: .heavy, shadow: false, glow: packRGBA(10, 44, 64))
        }
        head("MISSION", uiS(22))
        head("BRIEFING", uiS(58))
        c.label("// incoming transmission", lx, uiS(102), size: uiSf(14),
                color: packRGBA(120, 200, 150), weight: .medium, shadow: false, mono: true)

        // ── transmission body — left-aligned in the dark column ──
        var y = uiS(128)
        for line in briefingLines {
            if line.isEmpty { y += uiS(8) }
            else { c.label(line, lx, y, size: uiSf(13), color: ink, weight: .medium, shadow: false); y += uiS(15) }
        }
        if Int(t * 1.5) % 2 == 0 {
            c.label("> Good hunting, marine.   [ESC]", lx, H - uiS(30), size: uiSf(15),
                    color: amberHi, weight: .semibold, shadow: false, glow: packRGBA(60, 44, 0), mono: true)
        }
    }

    // ── FIELD INTEL — a paged dossier of cards ────────────────────────────────
    // Five leaves: the two castes (a mesh HERO BUST — the actual creature the game
    // renders, via MeshPortraits, with the SDF sculpt as fallback — beside a data
    // card), the arsenal, the field supply, and what hurts. Every entry is its own
    // card so nothing crams into a list. ◀ ▶ leaf through it; nothing animates but
    // the backdrop — it's a codex, not a slideshow.
    static let intelPages = 5
    private static let intelMagenta = packRGBA(224, 130, 224)

    static func intel(_ c: Canvas2D, t: Float, page: Int = 0) {
        backdrop(c, t, top: packRGBA(14, 8, 18), bottom: packRGBA(26, 10, 26))
        c.labelCentered("FIELD INTEL", uiS(16), size: uiSf(30), color: intelMagenta, weight: .heavy, shadow: true, glow: packRGBA(50, 10, 50))
        c.fillRectBlend(uiS(24), uiS(52), W - uiS(48), 1, packRGBA(150, 80, 150), 0.5)
        switch page {
        case 0: creaturePage(c, .alien)
        case 1: creaturePage(c, .queen)
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

    /// A dossier card: a translucent panel, a hairline border tinted by the accent,
    /// and a left accent spine so each entry reads as its own filed record.
    private static func card(_ c: Canvas2D, _ x: Int, _ y: Int, _ w: Int, _ h: Int,
                             accent: UInt32, fill: UInt32 = packRGBA(24, 18, 30), alpha: Float = 0.70) {
        c.fillRectBlend(x, y, w, h, fill, alpha)
        let bd = mixRGBA(packRGBA(64, 56, 74), accent, 0.35)
        c.fillRectBlend(x, y, w, 1, bd, 0.85)
        c.fillRectBlend(x, y + h - 1, w, 1, bd, 0.85)
        c.fillRectBlend(x, y, 1, h, bd, 0.85)
        c.fillRectBlend(x + w - 1, y, 1, h, bd, 0.85)
        c.fillRect(x, y, uiS(3), h, accent)                       // accent spine
    }

    /// A small label-over-value stat, for the creature data card.
    private static func statCell(_ c: Canvas2D, _ x: Int, _ y: Int, _ key: String, _ value: String, _ col: UInt32) {
        c.label(key, x, y, size: uiSf(11), color: dim, weight: .semibold, shadow: false, mono: true)
        c.label(value, x, y + uiS(14), size: uiSf(20), color: col, weight: .heavy, shadow: false)
    }

    /// The dossier bust: the mesh portrait the game actually renders (packed-RGBA,
    /// transparent background), cached by MeshPortraits when the renderer warms.
    private static func heroPlate(_ kind: MonsterKind) -> (px: [UInt32], w: Int, h: Int, footY: Int)? {
        if let m = MeshPortraits.plate(kind) { return (m.pixels, m.w, m.h, m.footY) }
        return nil
    }

    /// Fit an arbitrary sprite into a box (centred, whole, aspect-preserved).
    private static func spriteFit(_ c: Canvas2D, _ spr: Sprite, _ x: Int, _ y: Int, boxW: Int, boxH: Int) {
        let s = min(Float(boxW) / Float(spr.w), Float(boxH) / Float(spr.h))
        c.blitBitmapF(spr.pixels, spr.w, spr.h,
                      x + (boxW - Int(Float(spr.w) * s)) / 2, y + (boxH - Int(Float(spr.h) * s)) / 2, scale: s)
    }

    /// A colour-swatch damage tag ("■ PLASMA"), matching the HUD's ammo colours so
    /// the codex speaks the same colour language as the live readout.
    private static func damageTag(_ c: Canvas2D, _ x: Int, _ y: Int, _ label: String, _ col: UInt32) -> Int {
        c.fillRect(x, y + uiS(2), uiS(9), uiS(9), col)
        c.label(label, x + uiS(14), y, size: uiSf(12), color: mixRGBA(ink, col, 0.35), weight: .semibold, shadow: false)
        return uiS(14) + c.labelWidth(label, size: uiSf(12), weight: .semibold) + uiS(18)
    }

    // ── page: one caste — a hero bust card beside a data card ──
    private static func creaturePage(_ c: Canvas2D, _ kind: MonsterKind) {
        let top = uiS(64), bodyH = uiS(292)
        let accent = kind == .queen ? packRGBA(212, 92, 150) : packRGBA(150, 200, 120)

        // ── portrait card (left): the bust, a ground shadow, a caste tag ──
        // A wide card so the low, long drone bust fills it; the tall Queen is
        // height-bound either way. The bust is scaled to fit and vertically centred.
        let pcX = uiS(24), pcW = uiS(250)
        card(c, pcX, top, pcW, bodyH, accent: accent)
        let pad = uiS(10)
        let ix = pcX + uiS(3) + pad, iy = top + pad
        let iw = pcW - uiS(3) - pad * 2, ih = bodyH - pad * 2 - uiS(20)   // leave room for the tag
        if let hp = heroPlate(kind) {
            let k = min(Float(iw) / Float(hp.w), Float(ih) / Float(hp.h))
            let dw = Int(Float(hp.w) * k), dh = Int(Float(hp.h) * k)
            let bx = ix + (iw - dw) / 2, by = iy + (ih - dh) / 2          // vertically centred
            let footY = by + Int(Float(hp.footY) * k)
            let cx = bx + dw / 2, hw = max(uiS(24), dw * 2 / 5), hh = uiS(6)
            for jj in -hh...hh { for ii in -hw...hw {                     // soft ground shadow
                let dd = Float(ii * ii) / Float(hw * hw) + Float(jj * jj) / Float(hh * hh)
                if dd < 1 { c.blend(cx + ii, footY + jj, packRGBA(0, 0, 0), (1 - dd) * 0.5) }
            } }
            c.blitBitmapF(hp.px, hp.w, hp.h, bx, by, scale: k)
        } else {
            c.labelCentered2("DECRYPTING", pcX, pcW, top + bodyH / 2 - uiS(6), size: uiSf(13), color: dim, weight: .semibold, shadow: false)
        }
        let tag = kind == .queen ? "CASTE II · BROODMOTHER" : "CASTE I · PACK HUNTER"
        c.labelCentered2(tag, pcX, pcW, top + bodyH - uiS(16), size: uiSf(11),
                         color: mixRGBA(dim, accent, 0.45), weight: .semibold, shadow: false, mono: true)

        // ── data card (right): name, stats, weakness, dossier ──
        let icX = uiS(282), icW = W - icX - uiS(24)
        card(c, icX, top, icW, bodyH, accent: accent)
        let lx = icX + uiS(3) + uiS(16), rInner = icW - uiS(3) - uiS(32)
        var y = top + uiS(16)
        c.label(kind.displayName, lx, y, size: uiSf(34), color: amberHi, weight: .heavy, shadow: false, glow: packRGBA(70, 50, 12))
        y += uiS(42)
        statCell(c, lx, y, "INTEGRITY", "\(kind.def.maxHealth) HP", accent)
        statCell(c, lx + uiS(150), y, "BOUNTY", "\(kind.def.points) PTS", amber)
        y += uiS(46)
        c.fillRectBlend(lx, y - uiS(8), rInner, 1, packRGBA(80, 70, 92), 0.5)
        c.label("VULNERABLE TO", lx, y, size: uiSf(11), color: dim, weight: .semibold, shadow: false, mono: true)
        y += uiS(16)
        // colour-swatch damage tags, matching the HUD ammo colours (cells / fuel / rocket)
        let weak: [(String, UInt32)] = kind == .queen
            ? [("PLASMA", packRGBA(120, 210, 255)), ("FIRE", packRGBA(255, 150, 80))]
            : [("PLASMA", packRGBA(120, 210, 255)), ("FIRE", packRGBA(255, 150, 80)), ("ROCKET", packRGBA(224, 96, 72))]
        var wx = lx
        for (name, col) in weak { wx += damageTag(c, wx, y, name, col) }
        y += uiS(24)
        c.fillRectBlend(lx, y - uiS(8), rInner, 1, packRGBA(80, 70, 92), 0.5)
        for line in wrapLines(c, kind.codexText.capitalizedSentence, size: uiSf(13), weight: .medium, maxW: rInner) {
            c.label(line, lx, y, size: uiSf(13), color: ink, weight: .medium, shadow: false); y += uiS(16)
        }
    }

    // ── page: the arsenal — one card per weapon, 2×2 (real weapon models as icons) ──
    private static func arsenalPage(_ c: Canvas2D) {
        let rows: [(sprite: Sprite, name: String, tag: String, accent: UInt32, desc: String)] = [
            (ItemIcons.weapon(.plasma) ?? Sprites.shared.weaponIcon(.plasma), "PLASMA RIFLE", "CELLS · \(AmmoType.cells.capacity)", packRGBA(90, 200, 235),
             "Always carried. Fast energy bolts — the workhorse, and the only weapon that wounds the Queen. Refills at wall sockets."),
            (ItemIcons.weapon(.flamethrower) ?? Sprites.shared.weaponIcon(.flamethrower), "FLAMETHROWER", "FUEL · \(AmmoType.fuel.capacity)", packRGBA(240, 150, 60),
             "Always carried. A short cone of fire — the only thing that burns a corpse, or the Queen, away for good. Refills at fuel drums."),
            (ItemIcons.weapon(.rocket) ?? Sprites.shared.weaponIcon(.rocket), "ROCKET LAUNCHER", "ROCKETS · \(AmmoType.rockets.capacity)", packRGBA(224, 84, 60),
             "Found in the field. Heavy splash — clears a packed corridor and ruptures drums across the room. Its blast does not know your name."),
            (ItemIcons.cached(.mineCrate) ?? Sprites.shared.item(.mineCrate), "PROXIMITY MINES", "[G] DEPLOY · \(Player.maxMines)", packRGBA(230, 200, 90),
             "The meanest bang you carry. Arms in a second, then takes whatever crosses it — you too. Blasts chain into drums and mines."),
        ]
        let top = uiS(64), mx = uiS(24), gap = uiS(14)
        let cw = (W - mx * 2 - gap) / 2, ch = uiS(139)
        for (i, r) in rows.enumerated() {
            let cx = mx + (i % 2) * (cw + gap), cy = top + (i / 2) * (ch + gap)
            card(c, cx, cy, cw, ch, accent: r.accent)
            let inx = cx + uiS(3) + uiS(14)
            spriteFit(c, r.sprite, inx, cy + uiS(20), boxW: uiS(50), boxH: uiS(40))
            let tx = inx + uiS(60)
            c.label(r.name, tx, cy + uiS(20), size: uiSf(17), color: amberHi, weight: .bold, shadow: false)
            c.label(r.tag, tx, cy + uiS(42), size: uiSf(11), color: mixRGBA(dim, r.accent, 0.45), weight: .semibold, shadow: false, mono: true)
            var dy = cy + uiS(64)
            for line in wrapLines(c, r.desc, size: uiSf(12), weight: .medium, maxW: cw - uiS(34)) {
                c.label(line, inx, dy, size: uiSf(12), color: ink, weight: .medium, shadow: false); dy += uiS(14)
            }
        }
    }

    // ── page: the field supply — a chip per pickup, then the fixed hardware ──
    private static func supplyPage(_ c: Canvas2D) {
        let mx = uiS(24), gap = uiS(10)
        let green = packRGBA(120, 220, 140), blue = packRGBA(130, 180, 245)
        // Fuel is NOT a floor pickup (drums only). Only red + blue keycards spawn
        // (MapGen places ≤2 locks; yellow is never reached).
        let picks: [(icons: [ItemKind], name: String, value: String, accent: UInt32)] = [
            ([.stim], "STIMPACK", "+\(ItemKind.stimHeal) HEALTH", green),
            ([.medkit], "MEDKIT", "+\(ItemKind.medkitHeal) HEALTH", green),
            ([.armor], "ARMOUR PLATE", "+\(ItemKind.armorRepair) · TO \(ItemKind.armorRepairCap)", packRGBA(120, 205, 150)),
            ([.megaArmor], "FULL ARMOUR", "FRESH SUIT · \(Player.maxArmor)", blue),
            ([.ammoCells, .ammoRockets], "AMMUNITION", "\(ItemKind.cellsPerPickup) CELLS · \(ItemKind.rocketsPerPickup) ROCKETS", packRGBA(200, 170, 90)),
            ([.mineCrate], "MINE CRATE", "+\(ItemKind.minesPerCrate) MINES", packRGBA(230, 200, 90)),
            ([.keyRed, .keyBlue], "KEYCARDS", "OPEN SEALED DOORS", packRGBA(214, 108, 108)),
        ]
        var y = uiS(60)
        c.label("CARRIED & COLLECTED", mx, y, size: uiSf(13), color: amber, weight: .bold, shadow: false, mono: true)
        y += uiS(20)
        let cols = 3, cw = (W - mx * 2 - gap * (cols - 1)) / cols, ch = uiS(46)
        for (i, p) in picks.enumerated() {
            let cx = mx + (i % cols) * (cw + gap), cy = y + (i / cols) * (ch + uiS(8))
            card(c, cx, cy, cw, ch, accent: p.accent)
            let leftX = cx + uiS(3) + uiS(10)
            // line 1: icon(s) + name.  line 2: the value, on its own full-width line
            // (never crowded against the border, whatever the icon count).
            var ix = leftX
            for icon in p.icons { itemIcon(c, icon, ix, cy + uiS(6), box: uiS(17)); ix += uiS(19) }
            c.label(p.name, ix + uiS(6), cy + uiS(8), size: uiSf(13), color: ink, weight: .semibold, shadow: false)
            c.label(p.value, leftX, cy + uiS(27), size: uiSf(11), color: mixRGBA(dim, p.accent, 0.45), weight: .medium, shadow: false, mono: true)
        }

        // ── the fixed installations you WORK, not carry — a card each, room to breathe ──
        var hy = y + 3 * (ch + uiS(8)) + uiS(6)
        c.label("FIELD HARDWARE", mx, hy, size: uiSf(13), color: amber, weight: .bold, shadow: false, mono: true)
        hy += uiS(20)
        let hw = (W - mx * 2 - gap) / 2, hh = uiS(58)
        card(c, mx, hy, hw, hh, accent: packRGBA(80, 205, 235))
        socketIcon(c, mx + uiS(3) + uiS(12), hy + uiS(14), h: uiS(30))
        c.label("RECHARGE SOCKET", mx + uiS(3) + uiS(42), hy + uiS(12), size: uiSf(14), color: ink, weight: .semibold, shadow: false)
        for line in wrapLines(c, "Stand close — the plasma rifle drinks its cells. A drained panel recovers in time.",
                              size: uiSf(11), weight: .medium, maxW: hw - uiS(56)) {
            c.label(line, mx + uiS(3) + uiS(42), hy + uiS(30), size: uiSf(11), color: dim, weight: .medium, shadow: false); hy += uiS(13)
        }
        let hx2 = mx + hw + gap
        var hy2 = y + 3 * (ch + uiS(8)) + uiS(6) + uiS(20)
        card(c, hx2, hy2, hw, hh, accent: packRGBA(224, 120, 60))
        drumIcon(c, hx2 + uiS(3) + uiS(14), hy2 + uiS(14), h: uiS(30))
        c.label("FUEL DRUM", hx2 + uiS(3) + uiS(42), hy2 + uiS(12), size: uiSf(14), color: ink, weight: .semibold, shadow: false)
        for line in wrapLines(c, "Stand close to refuel the flamethrower — or shoot it: a drum is a bomb.",
                              size: uiSf(11), weight: .medium, maxW: hw - uiS(56)) {
            c.label(line, hx2 + uiS(3) + uiS(42), hy2 + uiS(30), size: uiSf(11), color: dim, weight: .medium, shadow: false); hy2 += uiS(13)
        }
    }

    /// A floor pickup, drawn from the SAME SDF geometry the game renders in-world
    /// (ItemIcons), fitted into a square box. Falls back to the MeshItems sprite
    /// until the SDF icons warm at launch.
    private static func itemIcon(_ c: Canvas2D, _ kind: ItemKind, _ x: Int, _ y: Int, box: Int) {
        let spr = ItemIcons.cached(kind) ?? Sprites.shared.item(kind)
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

    // ── page: survival — a card per threat, then a staying-alive card ──
    private static func survivalPage(_ c: Canvas2D) {
        let mx = uiS(24), gap = uiS(14), orange = packRGBA(240, 140, 60)
        var y = uiS(60)
        c.label("WHAT HURTS", mx, y, size: uiSf(13), color: packRGBA(224, 120, 120), weight: .bold, shadow: false, mono: true)
        y += uiS(20)
        let threats: [(name: String, sev: String, col: UInt32, note: String)] = [
            ("DRONE BITE", "MAJOR", orange, "Small on its own — but the pack flanks, and the wounds add up fast."),
            ("QUEEN STRIKE", "SEVERE", red, "Up to half your health in one blow. Stay out of her reach."),
            ("ACID POOLS", "MINOR", amber, "A slow burn underfoot — and it seeps straight through armour."),
            ("BLAST SPLASH", "SEVERE", red, "Rockets, mines and drums burn friend and foe alike. Stand clear."),
        ]
        let cw = (W - mx * 2 - gap) / 2, ch = uiS(78)
        for (i, th) in threats.enumerated() {
            let cx = mx + (i % 2) * (cw + gap), cy = y + (i / 2) * (ch + uiS(12))
            card(c, cx, cy, cw, ch, accent: th.col)
            let inx = cx + uiS(3) + uiS(14)
            c.label(th.name, inx, cy + uiS(12), size: uiSf(16), color: ink, weight: .semibold, shadow: false)
            c.labelRight(th.sev, cx + cw - uiS(14), cy + uiS(13), size: uiSf(12), color: th.col, weight: .bold, shadow: false, mono: true)
            var dy = cy + uiS(34)
            for line in wrapLines(c, th.note, size: uiSf(12), weight: .medium, maxW: cw - uiS(34)) {
                c.label(line, inx, dy, size: uiSf(12), color: dim, weight: .medium, shadow: false); dy += uiS(14)
            }
        }
        // ── STAYING ALIVE — one card, the three rules that keep you breathing ──
        var ay = y + 2 * (ch + uiS(12)) + uiS(6)
        c.label("STAYING ALIVE", mx, ay, size: uiSf(13), color: packRGBA(120, 220, 140), weight: .bold, shadow: false, mono: true)
        ay += uiS(20)
        let aw = W - mx * 2, ah = uiS(78)
        card(c, mx, ay, aw, ah, accent: packRGBA(120, 220, 140))
        var ly = ay + uiS(14)
        for line in ["Armour turns away a third of every hit — acid excepted.",
                     "Stims and medkits mend flesh; plates and suits restore armour.",
                     "Sockets refill cells, drums refill fuel — health only from crates."] {
            c.label("›  " + line, mx + uiS(3) + uiS(16), ly, size: uiSf(13), color: ink, weight: .medium, shadow: false); ly += uiS(20)
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

    /// THE LOOP PAYOFF — burned through the teleport static when the SIXTH and last
    /// citadel falls and the whole Strataris cluster is "secured". The restrained
    /// trilogy hook: ARC — the financier whose seal has haunted the title since the
    /// first frame — is the one who actually won; the marine was the disposable tool,
    /// and the descent only resumes, deeper. Same weak-carrier jitter as teleportCard,
    /// but it holds steadier and longer — this beat is meant to land.
    static func clusterCard(_ c: Canvas2D, world: World, t: Float) {
        func jx(_ k: Float) -> Int { Int(sinf(t * 34 + k) * 1.4 + sinf(t * 57 + k * 2.3)) }
        let x0 = W / 2
        c.fillRectBlend(0, uiS(74), W, uiS(250), packRGBA(0, 0, 0), 0.58)
        c.fillRectBlend(0, uiS(74), W, 1, cold, 0.4)
        c.fillRectBlend(0, uiS(324) - 1, W, 1, cold, 0.4)
        func row(_ s: String, _ y: Int, _ size: CGFloat, _ col: UInt32, _ w: NSFont.Weight, _ k: Float, glow: UInt32? = nil) {
            if Int((t + k) * 9) % 19 == 0 { return }                 // rare dropout — steadier than a mid-jump card
            let tw = c.labelWidth(s, size: size, weight: w, mono: true)
            c.label(s, x0 - tw / 2 + jx(k), y, size: size, color: col, weight: w, shadow: false, glow: glow, mono: true)
        }
        row("THE STRATARIS CLUSTER HAS FALLEN", uiS(90), uiSf(26), packRGBA(150, 210, 245), .heavy, 0.7, glow: packRGBA(14, 34, 52))
        row("Six citadels retaken.  Six worlds emptied.", uiS(126), uiSf(15), ink, .medium, 1.9)
        // the ARC seal + the cold reveal — clinical, alien to the colony's warm phosphor
        arcSeal(c, cx: x0, cy: uiS(176), r: uiS(15), color: cold, alpha: 0.9)
        row("ARC  //  CLAIM CONFIRMED", uiS(206), uiSf(17), cold, .bold, 2.6)
        row("No relief fleet was ever dispatched.", uiS(234), uiSf(14), dim, .semibold, 3.4)
        row("There was only you — all ARC ever needed.", uiS(254), uiSf(14), dim, .semibold, 4.2)
        row("The signal stirs again, far below.", uiS(290), uiSf(14), packRGBA(210, 160, 160), .semibold, 5.1)
        row("DESCENT RESUMES  ·  \(Progression.planetName(world.level + 1))", uiS(312), uiSf(18), amber, .heavy, 5.9, glow: packRGBA(60, 48, 0))
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
            c.drawNameEntry(name, showCaret: Int(t * 2) % 2 == 0, uiS(310), fontSize: uiSf(40), 1, 1, 0.65)
            c.labelCentered("[RETURN]", uiS(362), size: uiSf(18), color: dim, weight: .medium)
        } else if Int(t * 2) % 2 == 0 {
            c.labelCentered("PRESS  \(confirmName(pad: pad))", uiS(300), size: uiSf(28), color: amber, weight: .bold)
        }
    }

    static func highScores(_ c: Canvas2D, hs: HighScores, t: Float, highlight: Int = -1, pad: Bool = false) {
        HallArt.draw(c, t: t)                                // the drone concept plate — mirrors the title screen

        // Legibility scrim: a soft left→right fade so the table reads over the plate's
        // dark left flank (and settles the grain under the text).
        let scrimW = uiS(372)
        for x in 0..<scrimW {
            let a = 0.64 * powf(1 - Float(x) / Float(scrimW), 1.45)
            if a > 0.012 { c.fillRectBlend(x, 0, 1, H, packRGBA(0, 0, 0), a) }
        }

        let lx = uiS(30)
        let black = packRGBA(0, 0, 0)

        // ── masthead: HALL OF / THE FALLEN — the CITADEL wordmark treatment (amber core,
        //    soft halo, chromatic fringe), left-aligned over the dark flank ──
        func masthead(_ s: String, _ y: Int) {
            let sz = uiSf(44)
            let halo = mixRGBA(black, amber, 0.22)
            for (ox, oy) in [(-uiS(1), 0), (uiS(1), 0), (0, -uiS(1)), (0, uiS(1)), (-uiS(2), 0), (uiS(2), 0)] {
                c.label(s, lx + ox, y + oy, size: sz, color: halo, weight: .heavy, shadow: false)
            }
            c.label(s, lx + uiS(1), y, size: sz, color: red,     weight: .heavy, shadow: false)
            c.label(s, lx - uiS(1), y, size: sz, color: cold,    weight: .heavy, shadow: false)
            c.label(s, lx,          y, size: sz, color: amberHi, weight: .heavy, shadow: false, glow: packRGBA(110, 80, 28))
        }
        masthead("HALL OF",    uiS(24))
        masthead("THE FALLEN", uiS(63))

        // ── score table — left column, over the beast's dark flank. Fixed slots with
        //    clear gaps: rank · name (left) | colony·depth (dim) | score (right). ──
        let colR = uiS(214)                                 // colony/depth right edge
        let scoreR = uiS(346)                               // score right edge
        var y = uiS(132)
        if hs.entries.isEmpty {
            c.label("No records logged —", lx, y, size: uiSf(20), color: dim, weight: .medium)
            c.label("be the first to fall.", lx, y + uiS(26), size: uiSf(20), color: dim, weight: .medium)
        }
        for (i, e) in hs.entries.enumerated() {
            let lead = i == 0 || i == highlight                    // the record holder + a fresh entry stand out
            let col = i == highlight ? amberHi : (i == 0 ? packRGBA(236, 236, 246) : ink)
            let name = e.name.count > 10 ? String(e.name.prefix(9)) + "…" : e.name   // keep the name in its slot
            c.label("\(i + 1).", lx, y, size: uiSf(18), color: lead ? amber : dim, weight: .bold)
            c.label(name, lx + uiS(30), y, size: uiSf(18), color: col, weight: lead ? .bold : .medium)
            c.labelRight("\(e.colony) D\(e.depth)", colR, y + uiS(3), size: uiSf(11), color: coldDim, weight: .regular, mono: true)
            c.labelRight(commaSep(e.score), scoreR, y, size: uiSf(18), color: col, weight: .bold, mono: true)
            y += uiS(25)
        }

        if Int(t * 2) % 2 == 0 {
            let prompt = "> PRESS \(confirmName(pad: pad))"
            let pw = c.labelWidth(prompt, size: uiSf(22), weight: .bold, mono: true)
            c.label(prompt, W - uiS(30) - pw, H - uiS(34), size: uiSf(22),         // bottom-right, under the beast
                    color: amberHi, weight: .bold, shadow: true, glow: packRGBA(60, 44, 0), mono: true)
        }
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

    /// Format an integer with comma thousands separators (109365 → "109,365").
    private static func commaSep(_ n: Int) -> String {
        var out = "", c = 0
        for ch in String(n).reversed() { if c > 0 && c % 3 == 0 { out.append(",") }; out.append(ch); c += 1 }
        return String(out.reversed())
    }
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
