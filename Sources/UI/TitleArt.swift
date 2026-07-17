// Citadel — animated title-screen backdrop.
//
// The title art is Citadel's ONE image asset — the game is otherwise generated
// in code (audio is the other deliberate exception; see CREDITS.md). A Giger-
// xenomorph hero plate, amber rim-lit on black, loaded once and given subtle
// cinematic life so it reads as a live scene rather than a flat wallpaper:
//   • a slow Ken-Burns drift (the plate is decoded a touch larger than the
//     framebuffer, and we pan a window across it),
//   • a faint power flicker (the colony's failing emergency light breathes the
//     whole plate a few percent — applied through a per-frame 256-entry LUT so
//     it costs a table lookup per pixel, not a multiply), and
//   • fine film grain.
// Falls back to flat black if the plate is ever missing, so the title text still
// reads.

import Cocoa

enum TitleArt {
    // Decode a touch larger than the framebuffer so the pan has slack to travel
    // into without ever exposing an edge.
    private static let margin = 1.06

    private static let art: (px: [UInt32], w: Int, h: Int)? = load()
    static var available: Bool { art != nil }

    private static func load() -> (px: [UInt32], w: Int, h: Int)? {
        guard let url = Bundle.main.url(forResource: "title_bg", withExtension: "png"),
              let img = NSImage(contentsOf: url),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = Int((Double(RenderConfig.width) * margin).rounded())
        let h = Int((Double(RenderConfig.height) * margin).rounded())
        var px = [UInt32](repeating: packRGBA(0, 0, 0), count: w * h)
        px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            // A CGImage blit into a CGBitmapContext already lands row 0 = top, matching
            // Canvas2D — no manual flip (adding one puts the plate upside down).
            ctx.interpolationQuality = .high
            var rect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
            if let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            }
        }
        return (px, w, h)
    }

    /// Paint the full framebuffer with the animated backdrop.
    static func draw(_ c: Canvas2D, t: Float) {
        let W = RenderConfig.width, H = RenderConfig.height
        guard let art = art else { c.fillRect(0, 0, W, H, packRGBA(6, 5, 4)); return }
        let aw = art.w, ah = art.h

        // ── One-shot settle: a slow cinematic push-in that eases from the full plate
        //    into the hero framing over ~5s, then HOLDS dead still (no perpetual
        //    drift — the back-and-forth read as restless). Sampled BILINEARLY so the
        //    push is smooth sub-pixel, not stair-stepped.
        let settle: Float = 5.0
        let k = min(1, t / settle)
        let e = 1 - powf(1 - k, 3)                               // ease-out cubic
        let zoom = 1.06 - 0.12 * e                               // full plate → tighter hero, then fixed
        let vpW = Float(W) * zoom, vpH = Float(H) * zoom
        let ox = 0.5 * max(0, Float(aw) - vpW)                   // rest centred in the slack
        let oy = 0.5 * max(0, Float(ah) - vpH)
        let stepX = vpW / Float(W), stepY = vpH / Float(H)
        let maxX = Float(aw - 2), maxY = Float(ah - 2)

        // ── Old-film light: the projector bulb is never quite steady — a CONTINUOUS
        //    gentle brightness flutter, always present, with an occasional deeper dip
        //    (a worn, damaged print). This is what reads as "old movie" rather than a
        //    brief digital glitch.
        var bright = 1.0 + 0.028 * sinf(t * 9.1) + 0.020 * sinf(t * 14.7 + 1.2) + 0.014 * sinf(t * 23.3 + 0.4)
        let wIdx = floorf(t / 5.0)
        let evAt = 0.6 + sinf(wIdx * 91.7).magnitude * 3.4      // occasional deeper flutter, varied time
        let dd = (t - wIdx * 5.0) - evAt
        if dd >= 0, dd < 0.5 { bright -= 0.30 * (1 - dd / 0.5) * (0.55 + 0.45 * sinf(dd * 52)) }
        let fk = max(0.6, min(1.12, Float(bright)))
        var lut = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 { lut[i] = UInt8(clamping: Int(Float(i) * fk)) }

        // ── Heavy, COARSE film grain: 2×2 clumps read as grain rather than fine
        //    digital noise, reseeded every frame so it boils like real emulsion.
        let grainSeed = Int(t * 60) &* 2654435761
        art.px.withUnsafeBufferPointer { src in
            lut.withUnsafeBufferPointer { lp in
                for y in 0..<H {
                    let fy = min(maxY, max(0, oy + Float(y) * stepY))
                    let y0 = Int(fy), wy = fy - Float(Int(fy))
                    let r0 = y0 * aw, r1 = (y0 + 1) * aw
                    let iy0 = 1 - wy
                    let drow = y * W
                    let gyb = ((y >> 1) &+ grainSeed) &* 19349663      // coarse (2px) grain row bucket
                    for x in 0..<W {
                        let fx = min(maxX, max(0, ox + Float(x) * stepX))
                        let x0 = Int(fx), wx = fx - Float(Int(fx))
                        let ix0 = 1 - wx
                        let w00 = ix0 * iy0, w10 = wx * iy0, w01 = ix0 * wy, w11 = wx * wy
                        let p00 = src[r0 + x0], p10 = src[r0 + x0 + 1]
                        let p01 = src[r1 + x0], p11 = src[r1 + x0 + 1]
                        let rr = Float(p00 & 0xFF) * w00 + Float(p10 & 0xFF) * w10 + Float(p01 & 0xFF) * w01 + Float(p11 & 0xFF) * w11
                        let gg = Float((p00 >> 8) & 0xFF) * w00 + Float((p10 >> 8) & 0xFF) * w10 + Float((p01 >> 8) & 0xFF) * w01 + Float((p11 >> 8) & 0xFF) * w11
                        let bb = Float((p00 >> 16) & 0xFF) * w00 + Float((p10 >> 16) & 0xFF) * w10 + Float((p01 >> 16) & 0xFF) * w01 + Float((p11 >> 16) & 0xFF) * w11
                        var hsh = ((x >> 1) &* 73856093) ^ gyb
                        hsh = (hsh >> 13) ^ hsh
                        let n = (((hsh & 0x7F) * 96) >> 7) - 48        // ≈ ±48 coarse grain — heavy, filmic
                        c.framebuffer[drow + x] = packRGBA(Int(lp[Int(rr)]) + n, Int(lp[Int(gg)]) + n, Int(lp[Int(bb)]) + n, 255)
                    }
                }
            }
        }

        // ── Occasional vertical film SCRATCHES: a bright (or dark) hairline that flicks
        //    in for a moment and jitters, like a damaged print. Drawn under the crisp UI.
        for s in 0..<3 {
            let per = 4.3 + Float(s) * 1.7
            let wi = floorf(t / per)
            let seed = sinf(wi * (17.1 + Float(s) * 3.3))
            if seed.magnitude < 0.5 { continue }                       // present only some windows
            let life = 0.2 + seed.magnitude * 0.5
            let lt = t - wi * per
            if lt < 0 || lt > life { continue }
            let env = 1 - lt / life
            let baseX = (sinf(wi * (5.7 + Float(s))) * 0.5 + 0.5) * Float(W - 4) + 2
            let sx = min(W - uiS(1), max(0, Int(baseX + sinf(t * 47 + Float(s) * 2) * 2)))
            let col = s == 0 ? packRGBA(255, 250, 235) : packRGBA(16, 12, 8)   // bright / dark scratch
            c.fillRectBlend(sx, 0, uiS(1), H, col, 0.08 + 0.16 * env * env)
        }
    }
}
