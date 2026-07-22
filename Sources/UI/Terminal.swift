// Citadel — terminal easter-egg screen (amber CRT).
//
// Rendered when the marine USEs a computer desk: the view zooms into the terminal
// (a dark monitor shell + a curved, scanlined amber screen) and shows one of the
// EasterEggs entries. When the pool is spent, `guru = true` draws the famous
// Commodore Amiga GURU MEDITATION instead. Everything is amber-on-black to match
// the ARC display walls; `scale` (0→1) drives the zoom, `t` the CRT flicker/cursor
// blink. `frame(…)` draws the shared tube and returns the inner glass rect + a
// content fade-in factor, so the arcade mini-game (Invaders) can play inside the
// very same CRT the texts read on.

import Foundation
import CoreGraphics

enum Terminal {
    static let amber    = packRGBA(240, 196, 96)
    static let amberHi  = packRGBA(255, 233, 176)
    static let amberDim = packRGBA(150, 118, 52)
    static let screenBg = packRGBA(12, 9, 4)       // warm near-black glass
    static let shell    = packRGBA(24, 25, 28)     // dark steel monitor body
    static let shellHi  = packRGBA(54, 56, 62)     // lit top/left bevel

    /// Draw the shared monitor + amber glass over the (frozen, dimmed) world and
    /// return the inner glass rect `(x0, y0, w, h)` plus `cf` — the 0→1 factor by
    /// which on-glass content should fade in over the last of the zoom. Callers
    /// paint their own content into the rect (text eggs, guru, or the mini-game).
    @discardableResult
    static func frame(_ c: Canvas2D, scale: Float, t: Float, guru: Bool, showHint: Bool = true)
        -> (x0: Int, y0: Int, sw: Int, sh: Int, cf: Float)
    {
        let W = c.width, H = c.height
        let s = max(0, min(1, scale))
        // pull focus off the world
        c.fillRectBlend(0, 0, W, H, packRGBA(0, 0, 0), 0.62 * min(1, s * 1.6))
        // monitor rect grows from a small centred box to full as we zoom in
        let fullW = Int(Float(W) * 0.72), fullH = Int(Float(H) * 0.64)
        let sw = max(2, Int(Float(fullW) * (0.28 + 0.72 * s)))
        let sh = max(2, Int(Float(fullH) * (0.28 + 0.72 * s)))
        let x0 = (W - sw) / 2, y0 = (H - sh) / 2
        // ── monitor shell (a chunky bevelled slab) ──
        let b = uiS(16)
        c.fillRect(x0 - b, y0 - b, sw + 2 * b, sh + 2 * b, shell)
        c.fillRect(x0 - b, y0 - b, sw + 2 * b, uiS(3), shellHi)               // top bevel highlight
        c.fillRect(x0 - b, y0 - b, uiS(3), sh + 2 * b, shellHi)               // left bevel highlight
        // ── glass ──
        c.fillRect(x0, y0, sw, sh, screenBg)
        // corner vignette (fake tube curvature): darken the edges of the glass
        let vig = max(uiS(6), sw / 20)
        c.fillRectBlend(x0, y0, sw, vig, packRGBA(0, 0, 0), 0.5)
        c.fillRectBlend(x0, y0 + sh - vig, sw, vig, packRGBA(0, 0, 0), 0.5)
        c.fillRectBlend(x0, y0, vig, sh, packRGBA(0, 0, 0), 0.5)
        c.fillRectBlend(x0 + sw - vig, y0, vig, sh, packRGBA(0, 0, 0), 0.5)
        // scanlines
        var yy = y0
        while yy < y0 + sh { c.fillRectBlend(x0, yy, sw, 1, packRGBA(0, 0, 0), 0.22); yy += uiS(2) }
        // power LED on the shell (amber throughout — the whole terminal glows amber)
        if s > 0.4 {
            let lx = x0 + sw + b - uiS(9), ly = y0 + sh + b - uiS(9)
            c.fillRect(lx, ly, uiS(4), uiS(4), packRGBA(120, 220, 90))
        }
        // content fades in over the last of the zoom
        let cf = max(0, min(1, (s - 0.5) / 0.5))
        // close hint, under the shell
        if showHint && cf > 0.6 {
            c.labelCentered("[ USE ] STEP BACK", y0 + sh + b + uiS(5), size: CGFloat(uiS(9)),
                            color: amberDim, weight: .semibold, shadow: false, mono: true)
        }
        return (x0, y0, sw, sh, cf)
    }

    /// Draw the terminal over the (already-rendered, frozen) world. `egg == nil` →
    /// the pool is exhausted → GURU MEDITATION. `page` selects which screen of a
    /// multi-page document is showing (clamped).
    static func draw(_ c: Canvas2D, egg: TerminalEgg?, page: Int, scale: Float, t: Float) {
        let (x0, y0, sw, sh, cf) = frame(c, scale: scale, t: t, guru: egg == nil)
        if cf > 0.01 {
            let flick = 0.9 + 0.1 * sin(t * 33) + 0.04 * sin(t * 71)          // gentle CRT gutter
            if let egg = egg {
                let p = max(0, min(egg.pages.count - 1, page))
                let pg = egg.pages.isEmpty ? TerminalPage(sub: "", body: []) : egg.pages[p]
                if egg.kind == .blankMessage { drawBlank(c, pg.body, x0, y0, sw, sh, a: cf * flick, t: t) }
                else { drawEgg(c, egg, pg, page: p, x0, y0, sw, sh, a: cf * flick, t: t) }
            } else { drawGuru(c, x0, y0, sw, sh, a: cf, t: t) }
        }
    }

    // A bare screen with a few lines centred both ways — for the pop-culture nods
    // (Zero Wing's "All your base…", the KLF's "…justified & ancient / Mu Mu!").
    private static func drawBlank(_ c: Canvas2D, _ lines: [String], _ x0: Int, _ y0: Int, _ sw: Int, _ sh: Int, a: Float, t: Float) {
        let sz = CGFloat(max(uiS(10), Int(Float(sh) * 0.070)))
        let lineH = Int(sz) + uiS(10)
        let n = lines.count
        var y = y0 + sh / 2 - (n * lineH) / 2 - Int(sz) / 2
        for (i, line) in lines.enumerated() {
            // first line brightest; a soft blink keeps the bare screen alive
            let pulse = 0.82 + 0.18 * sin(t * 2.2 + Float(i))
            let col = tint(i == 0 ? amberHi : amber, a * pulse)
            c.labelCentered2(line, x0, sw, y, size: sz, color: col, weight: .bold, shadow: false, mono: true)
            y += lineH
        }
        // a lone blinking cursor low-centre, the way a bare terminal sits waiting
        if (Int(t * 2) & 1) == 0 {
            c.fillRect(x0 + sw / 2 - Int(sz) / 4, y0 + sh - sh / 6, Int(sz * 0.5), Int(sz * 0.16), tint(amber, a))
        }
    }

    static func tint(_ col: UInt32, _ a: Float) -> UInt32 { mixRGBA(screenBg, col, max(0, min(1, a))) }

    private static func drawEgg(_ c: Canvas2D, _ egg: TerminalEgg, _ pg: TerminalPage, page: Int, _ x0: Int, _ y0: Int, _ sw: Int, _ sh: Int, a: Float, t: Float) {
        let padX = sw / 12, padY = sh / 12
        let lx = x0 + padX
        let bodySz = CGFloat(max(uiS(8), Int(Float(sh) * 0.046)))
        let bannerSz = bodySz * 1.35
        let lineH = Int(bodySz) + uiS(3)
        var y = y0 + padY
        // masthead + a status blip, the way the ARC screens read
        c.label(egg.kind.banner, lx, y, size: bannerSz, color: tint(amberHi, a), weight: .bold, shadow: false, mono: true)
        c.labelRight("\u{25B8} ARC//SYS", x0 + sw - padX, y + uiS(3), size: bodySz * 0.8, color: tint(amberDim, a), weight: .semibold, shadow: false, mono: true)
        y += Int(bannerSz) + uiS(6)
        c.label(pg.sub, lx, y, size: bodySz * 0.82, color: tint(amber, a * 0.85), weight: .semibold, shadow: false, mono: true)
        y += Int(bodySz) + uiS(6)
        c.fillRectBlend(lx, y, sw - 2 * padX, max(1, uiS(1)), tint(amberDim, a), 1)   // divider
        y += uiS(10)
        for line in pg.body {
            c.label(line, lx, y, size: bodySz, color: tint(amber, a), weight: .regular, shadow: false, mono: true)
            y += lineH
        }
        // blinking cursor at the end of the page
        if (Int(t * 2) & 1) == 0 {
            c.fillRect(lx, y + uiS(1), Int(bodySz * 0.55), Int(bodySz * 0.9), tint(amberHi, a))
        }
        // ── page footer: ◀ PAGE n / N ▶ (only for multi-page documents) ──
        if egg.pages.count > 1 {
            let fy = y0 + sh - padY - Int(bodySz)
            c.fillRectBlend(lx, fy - uiS(6), sw - 2 * padX, max(1, uiS(1)), tint(amberDim, a * 0.7), 1)
            let prev = page > 0, next = page < egg.pages.count - 1
            let footer = "\(prev ? "\u{25C0}" : "\u{2013}")   PAGE \(page + 1) / \(egg.pages.count)   \(next ? "\u{25B6}" : "\u{2013}")"
            c.labelCentered2(footer, x0, sw, fy, size: bodySz * 0.86, color: tint(amber, a), weight: .semibold, shadow: false, mono: true)
        }
    }

    // The famous Commodore Amiga GURU MEDITATION — blinking border + text on a
    // black screen. Rendered in AMBER (not the original red) so it belongs to the
    // same terminal glow as the rest of the eggs. The guru number carries a small
    // C0DE wink.
    private static func drawGuru(_ c: Canvas2D, _ x0: Int, _ y0: Int, _ sw: Int, _ sh: Int, a: Float, t: Float) {
        c.fillRect(x0, y0, sw, sh, packRGBA(0, 0, 0))                          // the guru screen is PURE black
        let on = (Int(t * 1.6) & 1) == 0                                      // ~0.8 s blink
        guard on else { return }
        let glow = mixRGBA(packRGBA(0, 0, 0), amber, a)
        let bw = max(uiS(2), sh / 60)                                         // border thickness
        let mx = sw / 24, my = sh / 6                                         // border near the screen edge, text fits inside
        let bx = x0 + mx, by = y0 + my, bwid = sw - 2 * mx, bhei = sh - 2 * my
        c.fillRect(bx, by, bwid, bw, glow); c.fillRect(bx, by + bhei - bw, bwid, bw, glow)   // top/bottom
        c.fillRect(bx, by, bw, bhei, glow); c.fillRect(bx + bwid - bw, by, bw, bhei, glow)   // left/right
        let sz = CGFloat(max(uiS(8), Int(Float(sh) * 0.040)))
        let cy = y0 + sh / 2
        c.labelCentered2("Software Failure.   Press left mouse button to continue.",
                         bx, bwid, cy - Int(sz), size: sz, color: glow, weight: .semibold, shadow: false, mono: true)
        c.labelCentered2("Guru Meditation #00000025.0000C0DE",
                         bx, bwid, cy + Int(sz) / 2, size: sz, color: glow, weight: .semibold, shadow: false, mono: true)
    }
}
