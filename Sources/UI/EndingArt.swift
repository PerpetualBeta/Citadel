// Citadel — THE ENDING: ARC's ceremony.
//
// Reached exactly once, by retaking all six citadels of the Strataris cluster — every floor of
// every building. Almost nobody will ever see it, which is precisely why it is built like this:
//   • it is driven as a SEQUENCE of framings off one plate, not a single held shot, because a
//     still crowd betrays itself the moment the camera stops moving;
//   • every scrap of motion over it is procedural and lives in PLATE space, so it travels with
//     the camera instead of floating on top;
//   • and it is reachable headlessly (CITADEL_ENDINGSHOT) and covered by the shot harness, since
//     no play-test will ever get here and this is the one screen in the game that could rot for
//     years without anybody noticing.
//
// Two beats. Beat A holds one framing under ARC's citation — words and a moving ground fight each
// other, so the camera only creeps. Beat B releases: the text clears, the image becomes the
// subject, and the framings start to cut.

import Cocoa

enum EndingArt {
    // ── the plate ───────────────────────────────────────────────────────────────────────────
    // Decoded at its NATIVE 2048×1280 (1.6 × the 1280×800 frame) rather than the usual 1.06
    // margin. A plate that only ever does one gentle push-in needs almost no slack; one driven as
    // a sequence needs enough to sit well off-centre AND enough source pixels that a tight shot is
    // not a blow-up of a downsampled copy. At 1.6 the decode is exactly the source, so `ctx.draw`
    // becomes a 1:1 copy with no resample at all, and there is 768×480 of pan to play with. Costs
    // 10.5 MB against 4.6, once, for the game's final screen.
    private static let margin = 1.6
    private static let plate: CinematicPlate? = CinematicPlate(resource: "ending_bg", margin: margin)
    static var available: Bool { plate != nil }

    // Bulb flutter scaled DOWN for this plate. The amplitude was tuned against the two dark plates
    // (mean grey 42 and 27), whose ×1.062 peak crushes ~0.18% of the frame to white. This hall is
    // mean 81 and clips 1.29% at full amplitude, dead centre where the eye already is. 0.45 brings
    // the clipped fraction back in line with the reference plates — chosen off that measurement
    // rather than by eye, and without dimming the art to suit the effect.
    private static let flicker: Float = 0.45

    // Grain likewise. The ±48 swing was authored against dark plates; over this hall's bright, smooth
    // expanses it competes with the picture instead of sitting under it. Pulled back to a little over
    // half, which still boils — and boiling emulsion over a still crowd does a lot of the work of
    // making the crowd read as alive.
    private static let grain: Float = 0.55

    // ── landmarks, measured off ending_bg.png (normalised 0…1 across the whole image) ─────────
    // Authored data about the asset, kept in one table so a re-crop is one edit rather than a hunt.
    private static let medal = SIMD2<Float>(0.484, 0.341)     // the gold disc on its ribbon
    private static let window = SIMD2<Float>(0.476, 0.234)    // the backlit shaft — the scene's light

    // ── ARC's citation ──────────────────────────────────────────────────────────────────────
    // The mission briefing is the marine's voice. This is the CORPORATION's: measured,
    // proprietorial, pleased with itself. It is also the trilogy's hinge — the hall is cheering ARC
    // for clearing up ARC's own disaster, and the last block is where the player is told, politely,
    // to stop asking. The planet names come from Progression, so they cannot drift out of step with
    // the run the player just finished.
    static let citation: [[String]] = [
        ["ALL SIX CITADELS OF THE STRATARIS CLUSTER",
         "ARE CERTIFIED CLEAR.",
         Progression.planets.joined(separator: "   ·   ")],
        ["Production resumes within the quarter.",
         "The colonist transports are already under way."],
        ["The Board records its gratitude.",
         "Asolar Resource Corporation has never lost",
         "a colony it could not recover."],
        ["The signal you logged at depth has been reclassified.",
         "You will not be debriefed on it."],
    ]
    // Blocks REPLACE one another rather than accumulating: eleven lines at once would fill the dark
    // band the citation depends on for legibility, and a citation reads better a thought at a time.
    static let blockIn: Float = 0.9, blockHold: Float = 3.8, blockOut: Float = 0.9
    static var blockTime: Float { blockIn + blockHold + blockOut }
    static var citationTime: Float { Float(citation.count) * blockTime }

    // ── the shot list ───────────────────────────────────────────────────────────────────────
    struct Shot {
        let zoom0, zoom1, restX, restY, hold: Float
        /// The settle deliberately outlasts the hold, so the ease-out never arrives and the shot is
        /// still travelling when we cut away. A locked-off camera over a still crowd is the tell.
        var settleT: Float { hold * 2.2 }
    }

    static let dissolve: Float = 0.8

    /// Beat A — one framing, held under the citation, creeping ~4% across the whole read.
    /// Sub-perceptual second to second so it never disturbs reading, but no two moments are
    /// identical, so it cannot read as a frozen frame. `restY` biased above centre so the push eats
    /// empty vault rather than the near crowd, who are the life of the shot.
    private static var beatA: Shot {
        Shot(zoom0: 1.60, zoom1: 1.52, restX: 0.5, restY: 0.35, hold: citationTime)
    }

    /// Beat B — the release. Only now does the camera move between framings.
    private static let beatB: [Shot] = [
        Shot(zoom0: 0.58, zoom1: 0.50, restX: 0.485, restY: 0.203, hold: 5.0),   // the medal
        Shot(zoom0: 0.74, zoom1: 0.66, restX: 0.500, restY: 1.000, hold: 5.0),   // raised hands
        Shot(zoom0: 0.79, zoom1: 0.71, restX: 0.481, restY: 0.000, hold: 6.0),   // up into the window
        Shot(zoom0: 1.38, zoom1: 1.50, restX: 0.500, restY: 0.400, hold: 5.0),   // back out — the release
    ]

    private static var shots: [Shot] { [beatA] + beatB }

    /// Each shot's start time. Consecutive shots OVERLAP by `dissolve`, so a shot's own clock runs
    /// continuously through the cross-fade instead of snapping back to zero half way through it.
    private static var starts: [Float] {
        var out: [Float] = [], acc: Float = 0
        for s in shots { out.append(acc); acc += s.hold - dissolve }
        return out
    }

    /// How long the whole ceremony runs.
    static var duration: Float { (starts.last ?? 0) + (shots.last?.hold ?? 0) }

    // ── the crowd ───────────────────────────────────────────────────────────────────────────
    //
    // The hall's own sound, cut from ONE session of field-recorded crowd (Gregor Quendel, CC-BY
    // 4.0 — see CREDITS.md, without which the licence is void). The recording's OWN shape chose
    // the cuts: its loudest passage is a five-second cheer, its second a rhythmic chant, and a
    // separate ambience take holds within 1.4 dB for eleven seconds, which is what a bed wants.
    // Playing a take whole was the tempting thing and the wrong one — its biggest cheer would
    // have landed under the citation, the one place a peak must not go, because the text has to
    // read. So: a low bed throughout, and the two cheers spent on the two beats that earn them.
    //
    // The gains are only HALF the score. Under all of this the title theme plays, and it was
    // written for an abandoned colony: the crowd celebrates, the music does not. The citation
    // ends on "You will not be debriefed on it" and only THEN does the cheering start.
    static let crowdQuiet: Float = 0.34      // under the citation — a hall breathing, not a hall shouting
    static let crowdFull: Float = 0.72       // through the release, once there are no words to read
    /// Length of the two swell stems on disk. A swell must never outlast its stem, or the loop
    /// wraps mid-cheer and the crowd audibly restarts; the smoke suite holds the shot list to it.
    static let crowdSwellSeconds: Float = 5.75

    /// The holds of the two shots a swell is spent on — the medal and the raised hands. Exposed so
    /// the smoke suite can hold them against the stems' actual length on disk.
    static var swellHolds: [Float] { [beatB[0].hold, beatB[1].hold] }

    /// The three crowd gains at ceremony time `t`. Keyed off `starts`, not off typed seconds, so a
    /// cheer stays welded to the cut it belongs to even if a shot's hold is retimed. A swell's
    /// window opening is also its cue (see `AudioEngine.ceremonyCrowd`), and each closes with a
    /// release well inside its stem's length, so nothing wraps and nothing clicks off.
    static func crowd(at t: Float) -> (bed: Float, cheer: Float, chant: Float) {
        let st = starts, ss = shots
        guard st.count >= 3 else { return (0, 0, 0) }
        // CLAMPED past the end, not zeroed. The ceremony's last moments keep running under the fade
        // to black, and the hall has to be carried out BY that fade — zeroing here instead would
        // snap a packed auditorium off mid-breath one frame before the picture even starts to go.
        // Silence outside the ceremony is the renderer's single authority, not this curve's.
        let t = max(0, min(t, duration - 1e-3))
        // the bed lifts across the cut out of the citation and into the release
        let lift = ramp(t, from: st[1] - dissolve, to: st[1] + dissolve)
        let bed = crowdQuiet + (crowdFull - crowdQuiet) * lift
        return (bed, swell(t, cue: st[1], hold: ss[1].hold), swell(t, cue: st[2], hold: ss[2].hold))
    }

    /// A swell's envelope: nothing before its cut, a fast rise so the cheer arrives WITH the edit,
    /// full for the shot, then a release that starts before the shot ends so the hall is already
    /// settling as the camera moves on.
    private static func swell(_ t: Float, cue: Float, hold: Float) -> Float {
        guard t >= cue else { return 0 }
        let attack: Float = 0.25, release = hold * 0.45
        return min(ramp(t, from: cue, to: cue + attack),
                   1 - ramp(t, from: cue + hold - release, to: cue + hold))
    }

    /// Smoothstep from 0 at `from` to 1 at `to`.
    private static func ramp(_ t: Float, from a: Float, to b: Float) -> Float {
        guard b > a else { return t >= b ? 1 : 0 }
        let x = max(0, min(1, (t - a) / (b - a)))
        return x * x * (3 - 2 * x)
    }

    // ── drawing ─────────────────────────────────────────────────────────────────────────────

    static func draw(_ c: Canvas2D, t: Float) {
        guard let plate = plate else {
            // No plate → flat black, so the citation drawn over the top still reads.
            c.fillRect(0, 0, RenderConfig.width, RenderConfig.height, packRGBA(6, 5, 4))
            return
        }
        let ss = shots, st = starts
        var cur = 0
        for (i, s) in st.enumerated() where t >= s { cur = i }

        func paint(_ i: Int, _ alpha: Float) -> CinematicPlate.Viewport {
            let s = ss[i], local = max(0, t - st[i])
            // `t` drives the grain and the bulb so they keep boiling across a cut; `shotT` drives
            // the framing, so each shot's push starts from its own zero.
            plate.draw(c, t: t, shotT: local, restX: s.restX, restY: s.restY, settleT: s.settleT,
                       zoomStart: s.zoom0, zoomRest: s.zoom1, flicker: flicker, grain: grain,
                       alpha: alpha)
            return plate.viewport(t: local, restX: s.restX, restY: s.restY, settleT: s.settleT,
                                  zoomStart: s.zoom0, zoomRest: s.zoom1)
        }

        // Mid-dissolve the previous shot is still on screen underneath.
        var vp: CinematicPlate.Viewport
        let into = t - st[cur]
        if cur > 0, into < dissolve {
            _ = paint(cur - 1, 1)
            let mix = max(0, min(1, into / dissolve))
            vp = paint(cur, mix)
            // The overlays follow whichever framing DOMINATES, so they never straddle two.
            if mix < 0.5 {
                vp = plate.viewport(t: max(0, t - st[cur - 1]), restX: ss[cur - 1].restX,
                                    restY: ss[cur - 1].restY, settleT: ss[cur - 1].settleT,
                                    zoomStart: ss[cur - 1].zoom0, zoomRest: ss[cur - 1].zoom1)
            }
        } else {
            vp = paint(cur, 1)
        }

        breathe(c, vp, t)
        motes(c, vp, t)
        confetti(c, vp, t)
        glint(c, vp, t)
    }

    // ── the motion layer ────────────────────────────────────────────────────────────────────

    @inline(__always) private static func frac(_ x: Float) -> Float { x - floorf(x) }

    /// Stable per-particle randoms — the same fleck keeps its identity for the whole ceremony, so
    /// nothing pops or reshuffles between frames.
    @inline(__always) private static func hash(_ i: Float, _ salt: Float) -> Float {
        frac(sinf(i * salt + salt) * 43758.5453)
    }

    /// Is this point inside the framebuffer, with a margin for the sprite's own size?
    @inline(__always) private static func onscreen(_ x: Float, _ y: Float, _ pad: Float) -> Bool {
        x > -pad && y > -pad && x < Float(RenderConfig.width) + pad && y < Float(RenderConfig.height) + pad
    }

    /// PROCEDURAL CONFETTI. The plate is deliberately confetti-free, and that was the whole point of
    /// re-commissioning it: a fleck frozen in mid-air is the one element of a still that has no
    /// innocent reading — a person can hold a pose, a fleck cannot hold an altitude. Adding moving
    /// flecks beside baked ones reads worse than either alone, because the moving ones teach the eye
    /// what to look for. So every scrap of it lives here.
    private static let confettiPerMegapixel = 230
    private static func confetti(_ c: Canvas2D, _ vp: CinematicPlate.Viewport, _ t: Float) {
        // Scaled by frame area so the shower has the same density at any RenderConfig scale — the
        // game has one resolution knob and this must not be a second one.
        let n = max(24, confettiPerMegapixel * RenderConfig.width * RenderConfig.height / 1_000_000)
        let palette = [packRGBA(214, 64, 58), packRGBA(72, 118, 196),
                       packRGBA(238, 232, 216), packRGBA(214, 176, 84)]
        for i in 0..<n {
            let f = Float(i)
            let h1 = hash(f, 12.9898), h2 = hash(f, 78.233), h3 = hash(f, 37.719)
            // Fall rate in plate-heights per second, varied per fleck so the shower never pulses.
            let fall = 0.040 + 0.085 * h2
            let v = frac(h1 + t * fall) * 1.3 - 0.18            // spawns above frame, falls past it
            let u = frac(h2 * 0.97 + 0.021 * sinf(t * (0.31 + 0.4 * h3) + f * 2.1))
            let p = vp.screen(u, v)
            // Size in PLATE pixels converted through the framing, so flecks grow as we push in
            // rather than staying a fixed pixel size and shrinking out of the scene.
            // Sized so a fleck still READS in the widest framing: the first pass authored 2.6×3.8
            // plate px, which the wide shot shrank to a 2×2 dot and the busy hall swallowed whole.
            let w = min(6, max(2, Int((5.0 * vp.mag).rounded())))
            // Tumble: a fleck seen edge-on is a line. Scaling only the height reads as rotation for
            // a fraction of the cost of actually rotating a quad.
            let tumble = abs(cosf(t * (2.0 + 3.6 * h3) + f))
            let hgt = min(10, max(1, Int((7.6 * vp.mag * (0.16 + 0.84 * tumble)).rounded())))
            guard onscreen(p.x, p.y, Float(max(w, hgt) + 2)) else { continue }
            // Softer the further we push in. A flat saturated block is the giveaway at high
            // magnification, where real foreground confetti would be well outside the focal plane —
            // capping the size and thinning the alpha stands in for that defocus for nothing.
            let focus = min(1, 1.15 / max(0.35, vp.mag))
            // Lit by the shaft: a fleck crossing the window flares, which is what makes it belong
            // to the scene rather than sit over it.
            let d = SIMD2<Float>(u, v) - window
            let lit = 1 + 1.5 * expf(-(d.x * d.x + d.y * d.y) / 0.018)
            let col = palette[i % palette.count]
            c.fillRectBlend(Int(p.x), Int(p.y), w, hgt, col, min(0.96, 0.74 * lit * focus))
            if lit > 1.6 {                                       // the flare itself, additive
                c.blendAdd(Int(p.x), Int(p.y), packRGBA(255, 244, 214),
                           min(0.5, 0.24 * (lit - 1) * focus))
            }
        }
    }

    /// Finer, slower DUST, biased into the shaft — dust only shows where the light finds it. Purely
    /// additive and one pixel across, so it reads as air rather than as objects.
    private static func motes(_ c: Canvas2D, _ vp: CinematicPlate.Viewport, _ t: Float) {
        let n = max(40, 260 * RenderConfig.width * RenderConfig.height / 1_000_000)
        for i in 0..<n {
            let f = Float(i) + 0.5
            let h1 = hash(f, 5.113), h2 = hash(f, 91.77), h3 = hash(f, 23.31)
            // Clustered around the window column, thinning outward; a slow downward drift.
            let u = window.x + (h1 - 0.5) * 0.46
            let v = frac(h2 + t * (0.012 + 0.03 * h3)) * 0.86
            let p = vp.screen(u, v + 0.02 * sinf(t * 0.6 + f))
            guard onscreen(p.x, p.y, 2) else { continue }
            let d = SIMD2<Float>(u, v) - window
            let lit = expf(-(d.x * d.x * 3.2 + d.y * d.y) / 0.10)
            let a = (0.10 + 0.34 * h3) * lit * (0.6 + 0.4 * sinf(t * (1.2 + 2 * h1) + f))
            if a > 0.012 { c.blendAdd(Int(p.x), Int(p.y), packRGBA(255, 248, 226), min(0.55, a)) }
        }
    }

    /// A specular TWINKLE on the medal. It sits at the composition's focal point, so a handful of
    /// lines of motion here buys more than the same lines anywhere else in frame.
    private static func glint(_ c: Canvas2D, _ vp: CinematicPlate.Viewport, _ t: Float) {
        let period: Float = 3.1
        let k = frac(t / period)
        let env = expf(-powf((k - 0.42) * 8, 2))                 // one soft pulse per period
        guard env > 0.02 else { return }
        let p = vp.screen(medal.x, medal.y)
        let r = max(2, Int((7 * vp.mag).rounded()))
        guard onscreen(p.x, p.y, Float(r) * 4) else { return }
        let cx = Int(p.x), cy = Int(p.y)
        let col = packRGBA(255, 250, 232)
        // A CORE of a few pixels, not one: the medal is gold on a warm ground, so a single additive
        // pixel disappeared into it entirely on the first pass.
        for oy in -1...1 { for ox in -1...1 {
            c.blendAdd(cx + ox, cy + oy, col, min(1, env * (ox == 0 && oy == 0 ? 1.5 : 0.9)))
        } }
        // Four arms with a linear falloff — a star, not a blob.
        for s in 2...(r * 4) {
            let a = env * (1 - Float(s) / Float(r * 4 + 1)) * 0.85
            if a < 0.01 { break }
            c.blendAdd(cx + s, cy, col, a); c.blendAdd(cx - s, cy, col, a)
            c.blendAdd(cx, cy + s, col, a * 0.75); c.blendAdd(cx, cy - s, col, a * 0.75)
        }
    }

    /// The window BREATHES. The shaft is the scene's only light, so swelling and settling it is the
    /// cheapest way to make the whole hall feel alive rather than lit once and left. Bounded to a
    /// box around the window so this stays a local pass, not a second full-frame loop.
    private static func breathe(_ c: Canvas2D, _ vp: CinematicPlate.Viewport, _ t: Float) {
        let swell = 0.5 + 0.5 * sinf(t * 0.23) * sinf(t * 0.11 + 1.3)
        let gain = 0.014 + 0.030 * swell
        let p = vp.screen(window.x, window.y)
        let r = 0.20 * vp.ph * vp.mag                            // plate-relative radius, in screen px
        guard r > 1, onscreen(p.x, p.y, r) else { return }
        let x0 = max(0, Int(p.x - r)), x1 = min(RenderConfig.width - 1, Int(p.x + r))
        let y0 = max(0, Int(p.y - r)), y1 = min(RenderConfig.height - 1, Int(p.y + r))
        guard x1 > x0, y1 > y0 else { return }
        let col = packRGBA(255, 236, 198)
        let inv = 1 / (r * r)
        for y in y0...y1 {
            let dy = Float(y) - p.y
            let row = y * RenderConfig.width
            for x in x0...x1 {
                let dx = Float(x) - p.x
                let q = 1 - (dx * dx + dy * dy) * inv
                guard q > 0 else { continue }
                // Weight by the HEADROOM already in the frame. Adding light indiscriminately over a
                // window that is nearly white just washes the shot out — the first attempt at this
                // bleached the whole medal framing. Physically it is the right rule too: you see a
                // shaft in the AIR around a light source, not on the source itself.
                let px = c.framebuffer[row + x]
                let lum = Float(redOf(px) * 2 + greenOf(px) * 5 + blueOf(px)) * 0.125
                let head = max(0, 1 - lum / 255)
                c.blendAdd(x, y, col, gain * q * q * head)
            }
        }
    }
}
