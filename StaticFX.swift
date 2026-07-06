// Citadel — analog-static painter (the teleport sequence).
//
// The planet jump reads as a SIGNAL: the visor feed dissolves to broadband
// static, holds — for however long the next citadel takes to build on the
// background queue — then burns off in the new location. Coarse 2×2 grain to
// match the framebuffer's pixel-art scale, a rolling dark band (vertical hold
// slipping), rare hot flecks, and a per-block dissolve threshold so a partial
// coverage eats the picture the way real interference does — speckle by
// speckle, not a crossfade.

import Foundation

enum StaticFX {
    /// Full-screen static (the hold state between citadels).
    static func fill(_ c: Canvas2D, t: Float) { overlay(c, coverage: 1, t: t) }

    /// Dissolve overlay: each 2×2 block flips to static once its hash falls
    /// under `coverage` — 0 leaves the scene untouched, 1 is pure static.
    static func overlay(_ c: Canvas2D, coverage: Float, t: Float) {
        let cov = min(1, coverage)
        guard cov > 0.001 else { return }
        let W = c.width, H = c.height
        let frame = UInt32(truncatingIfNeeded: Int(t * 60))
        // the band scrolls a little faster than the grain refreshes, so it reads
        // as a signal artefact rather than part of the noise
        let bandH = H / 9
        let bandY = Int((t * 140).truncatingRemainder(dividingBy: Float(H + bandH))) - bandH
        let fb = c.framebuffer
        var by = 0
        while by < H {
            let inBand = by >= bandY && by < bandY + bandH
            let rowBase = by * W
            var bx = 0
            while bx < W {
                var h = UInt32(truncatingIfNeeded: bx) &* 374_761_393
                    &+ UInt32(truncatingIfNeeded: by) &* 668_265_263
                    &+ frame &* 2_654_435_761
                h = (h ^ (h >> 13)) &* 1_274_126_177
                h ^= h >> 16
                let gate = Float(h & 0x3FF) / 1024
                if gate < cov {
                    var v = Int((h >> 10) & 0xFF)
                    if inBand { v = v * 2 / 5 }
                    if (h >> 18) & 0x7F == 0 { v = 255 }              // a rare hot fleck
                    let col = packRGBA(v, v, min(255, v + 8))         // faintly blue — screen phosphor
                    let i = rowBase + bx
                    fb[i] = col
                    if bx + 1 < W { fb[i + 1] = col }
                    if by + 1 < H {
                        fb[i + W] = col
                        if bx + 1 < W { fb[i + W + 1] = col }
                    }
                }
                bx += 2
            }
            by += 2
        }
        // scanlines settle over a mostly-static frame
        if cov > 0.85 {
            var y = 0
            while y < H { c.fillRectBlend(0, y, W, 1, packRGBA(0, 0, 0), 0.10 * cov); y += uiS(2) }
        }
    }
}
