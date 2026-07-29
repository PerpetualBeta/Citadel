// Citadel — cinematic image plate.
//
// The shared engine behind Citadel's image backdrops (the title screen and the
// Hall of the Fallen — the game's only image assets besides audio; see
// CREDITS.md). A decoded plate given subtle cinematic life so it reads as a live
// scene, not a flat wallpaper:
//   • a slow Ken-Burns push/drift (the plate is decoded a touch larger than the
//     framebuffer, and we pan a window across it, bilinearly),
//   • a faint projector-bulb flicker (a per-frame 256-entry LUT, so it costs a
//     table lookup per pixel, not a multiply), and
//   • heavy, coarse film grain plus the occasional vertical scratch.
// Falls back to flat black if the plate is missing, so overlaid text still reads.

import Cocoa

final class CinematicPlate {
    // Decode a touch larger than the framebuffer so the pan has slack to travel
    // into without ever exposing an edge. A plate that only ever does one gentle
    // push-in needs barely any (the default); one driven as a SEQUENCE of framings
    // needs enough slack to sit off-centre AND enough source pixels that a tight
    // shot isn't a blow-up of a downsampled copy — pass the ratio that decodes it
    // at its native size and both come free (see EndingArt).
    static let defaultMargin = 1.06

    private let px: [UInt32]
    let w: Int, h: Int

    init?(resource: String, margin: Double = CinematicPlate.defaultMargin) {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "png"),
              let img = NSImage(contentsOf: url),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = Int((Double(RenderConfig.width) * margin).rounded())
        let h = Int((Double(RenderConfig.height) * margin).rounded())
        var buf = [UInt32](repeating: packRGBA(0, 0, 0), count: w * h)
        buf.withUnsafeMutableBytes { raw in
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
        self.px = buf; self.w = w; self.h = h
    }

    /// Where the pan window sits inside the plate for a given framing — the ONE place
    /// that maps plate space to the framebuffer. Overlays that belong to the SCENE
    /// (confetti, dust, a glint on a medal) have to travel with the camera, and they
    /// can only do that by asking the same question `draw` asks.
    struct Viewport {
        let ox, oy, stepX, stepY: Float
        let pw, ph: Float                                        // the decoded plate's size
        /// Normalised plate coordinate (0…1 across the whole image) → framebuffer pixel.
        @inline(__always) func screen(_ u: Float, _ v: Float) -> (x: Float, y: Float) {
            ((u * pw - ox) / stepX, (v * ph - oy) / stepY)
        }
        /// Framebuffer pixels per plate pixel — how hard this framing magnifies, so an
        /// overlay drawn at a fixed physical size grows and shrinks with the shot.
        var mag: Float { 1 / stepX }
    }

    /// The framing at time `t`, given the same arguments `draw` takes.
    func viewport(t: Float, restX: Float = 0.5, restY: Float = 0.5,
                  settleT: Float = 0, zoomStart: Float = 1.0, zoomRest: Float = 1.0) -> Viewport {
        let W = RenderConfig.width, H = RenderConfig.height
        // One-shot settle, ease-out cubic. A push whose `settleT` outlasts the time the
        // plate is on screen never arrives, so it is still moving when we cut away.
        let k = settleT > 0 ? min(1, t / settleT) : 1
        let e = 1 - powf(1 - k, 3)
        let zoom = zoomStart + (zoomRest - zoomStart) * e
        let vpW = Float(W) * zoom, vpH = Float(H) * zoom
        return Viewport(ox: max(0, min(1, restX)) * max(0, Float(w) - vpW),
                        oy: max(0, min(1, restY)) * max(0, Float(h) - vpH),
                        stepX: vpW / Float(W), stepY: vpH / Float(H),
                        pw: Float(w), ph: Float(h))
    }

    /// Paint the full framebuffer with the animated plate.
    /// - restX/restY: where the pan window rests within the plate's slack (0…1;
    ///   0.5 = centred). Lets a plate be framed left/right of centre.
    /// - settleT: seconds of the one-shot push-in (0 = static at `zoomRest`).
    /// - zoomStart/zoomRest: viewport scale at t=0 and after the settle.
    /// - flicker: scales the projector-bulb flutter. The amplitude below was tuned
    ///   against the two DARK plates (mean grey 42 and 27), where its ×1.062 peak
    ///   crushes only ~0.18% of the frame to white. A bright plate has no such
    ///   headroom — the ending hall (mean 81) clips 1.29% at full amplitude, and
    ///   right in the middle of frame. Scale it down until the clipped fraction
    ///   matches the reference plates rather than dimming the art to suit the effect.
    /// - alpha: below 1, the plate BLENDS over what is already in the framebuffer instead of
    ///   overwriting it, which is what lets one framing cross-dissolve into another (draw the
    ///   outgoing shot at 1, the incoming at the mix). Both passes take the same `t`, so the grain
    ///   and the bulb flutter are identical in each and the dissolve cannot double them.
    /// - shotT: the clock the FRAMING runs on, when it differs from the clock the film stock runs on.
    ///   A sequence of framings needs each shot's push to start from its own zero, while the grain
    ///   and the bulb must keep boiling straight through the cut — one clock cannot do both.
    ///   Defaults to `t`, so a single-shot plate needs no second argument.
    func draw(_ c: Canvas2D, t: Float, shotT: Float? = nil, restX: Float = 0.5, restY: Float = 0.5,
              settleT: Float = 0, zoomStart: Float = 1.0, zoomRest: Float = 1.0,
              flicker: Float = 1.0, grain: Float = 1.0, alpha: Float = 1.0) {
        let W = RenderConfig.width, H = RenderConfig.height
        let aw = w, ah = h

        // Bilinear off the ONE mapping (see `viewport`), so the push is smooth sub-pixel rather
        // than stair-stepped and the scene overlays land exactly where the plate puts them.
        let vp = viewport(t: shotT ?? t, restX: restX, restY: restY, settleT: settleT,
                          zoomStart: zoomStart, zoomRest: zoomRest)
        let ox = vp.ox, oy = vp.oy, stepX = vp.stepX, stepY = vp.stepY
        let maxX = Float(aw - 2), maxY = Float(ah - 2)
        let fade = alpha < 0.999

        // ── Old-film light: the projector bulb is never quite steady — a continuous
        //    gentle brightness flutter with an occasional deeper dip (a worn print).
        var bright = 1.0 + flicker * (0.028 * sinf(t * 9.1) + 0.020 * sinf(t * 14.7 + 1.2) + 0.014 * sinf(t * 23.3 + 0.4))
        let wIdx = floorf(t / 5.0)
        let evAt = 0.6 + sinf(wIdx * 91.7).magnitude * 3.4      // occasional deeper flutter, varied time
        let dd = (t - wIdx * 5.0) - evAt
        if dd >= 0, dd < 0.5 { bright -= flicker * 0.30 * (1 - dd / 0.5) * (0.55 + 0.45 * sinf(dd * 52)) }
        let fk = max(0.6, min(1.12, Float(bright)))
        var lut = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 { lut[i] = UInt8(clamping: Int(Float(i) * fk)) }

        // ── Heavy, COARSE film grain: 2×2 clumps read as grain rather than fine
        //    digital noise, reseeded every frame so it boils like real emulsion.
        //    Amplitude is per-plate (`grain`): ±48 suits a plate whose mean grey is in the
        //    twenties or forties, and is far too loud over a bright, smooth, high-key image,
        //    where it stops reading as emulsion and starts reading as a screen door.
        let grainSeed = Int(t * 60) &* 2654435761
        // 128-entry table so the per-plate scaling costs nothing per pixel: the hash below yields
        // 0…127, and this maps it to the signed swing once, up front.
        var gtab = [Int](repeating: 0, count: 128)
        for i in 0..<128 { gtab[i] = Int((Float(i) - 63.5) * 0.756 * max(0, grain)) }
        px.withUnsafeBufferPointer { src in
            lut.withUnsafeBufferPointer { lp in
                for y in 0..<H {
                    let fy = min(maxY, max(0, oy + Float(y) * stepY))
                    let y0 = Int(fy), wy = fy - Float(Int(fy))
                    let r0 = y0 * aw, r1 = (y0 + 1) * aw
                    let iy0 = 1 - wy
                    let drow = y * W
                    let gyb = ((y >> 1) &+ grainSeed) &* 668265263      // coarse (2px) grain row bucket
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
                        // A proper avalanche rather than an XOR of two multiplicative terms. The old
                        // mix left visible STRUCTURE — a regular cross-hatch lattice — which the two
                        // dark plates hid and a bright one puts on open display. Grain has exactly one
                        // job, which is to look like noise.
                        var hsh = ((x >> 1) &* 374761393) &+ gyb
                        hsh = (hsh ^ (hsh >> 13)) &* 1274126177
                        hsh = hsh ^ (hsh >> 16)
                        let n = gtab[hsh & 0x7F]
                        let out = packRGBA(Int(lp[Int(rr)]) + n, Int(lp[Int(gg)]) + n, Int(lp[Int(bb)]) + n, 255)
                        c.framebuffer[drow + x] = fade ? mixRGBA(c.framebuffer[drow + x], out, alpha) : out
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
            // scaled by `alpha` too — a scratch at full strength over a half-faded plate would
            // announce the dissolve it is meant to sit inside
            c.fillRectBlend(sx, 0, uiS(1), H, col, (0.08 + 0.16 * env * env) * alpha)
        }
    }
}
