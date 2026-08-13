// Citadel — hidden feature flags.
//
// Off by default; opt in per machine with `defaults write`, e.g.
//   defaults write cc.jorviksoftware.Citadel Godmode -bool true
// Read live (computed on each access), so toggling via `defaults write` takes
// effect on the next frame that reads the flag — no relaunch needed.

import Foundation

enum FeatureFlags {
    private static var d: UserDefaults { .standard }

    /// Enables the screen-capture control: the F key (keyboard) and a
    /// rebindable gamepad button. Saves a 1920×1080 nearest-neighbour PNG to
    /// the Desktop.
    static var screenshotKey: Bool { d.bool(forKey: "ScreenshotKey") }

    // ── Optics ────────────────────────────────────────────────────────────────
    //
    // Both default to OFF, and deliberately so: Citadel is shipped and public, and
    // neither of these should change what an existing player sees until they have
    // been looked at frame by frame against the shot baseline. They are live knobs
    // rather than booleans because the right value is a judgement made by eye —
    // dial it, look, and bake the number in when it is right.

    /// Lens flare strength, 0 = off. Sensible range 0.1 – 0.6.
    ///
    /// **Why this is defensible in a Doom-idiom game.** Not as a camera artefact —
    /// there is no camera — but as **glass**: the player is looking through a
    /// helmet visor, which Citadel already draws. Flare is what a bright source
    /// does to a visor, and the game already ships HDR bloom, an ACES tonemap and
    /// a vignette, none of which existed in 1993 either.
    ///
    /// It is *occasional* by construction rather than by a timer: the effect rides
    /// only the bright energy above a threshold, so it appears when you are looking
    /// at a lamp, a fire or the plant, and is absent the rest of the time. Nothing
    /// randomises it.
    static var lensFlare: Double { d.double(forKey: "LensFlare") }

    /// Distance at which the lens flare reaches half strength, in world units.
    ///
    /// The streak is a fixed fraction of frame width — a property of the optic — while
    /// a source's apparent size goes as 1/depth, so the streak only reads as *light*
    /// when it is long relative to the source. Close sources are large on screen and
    /// the same smear becomes a smudge across their edges. This is the knee of the
    /// `d/(d+d0)` falloff that fades them out.
    ///
    /// Defaults to 5. Larger pushes flare further away (only distant points streak);
    /// smaller lets nearer sources flare again.
    static var flareNearFade: Double {
        let v = d.double(forKey: "FlareNearFade")
        return v > 0 ? v : 5
    }

    /// Depth-of-field strength, 0 = off. Sensible range 0.2 – 1.0.
    ///
    /// **Read `dofFocus` before turning this up in gameplay.** Blurring distance in
    /// a shooter attacks the thing the player most needs — reading a drone at range
    /// — and the frame is 1280×800 blitted *nearest-neighbour*, so a blur upscales
    /// into soft blocks rather than a soft image. It earns its keep on the surfaces
    /// where legibility is not at stake: the automap, the lift ride, the endgame.
    static var depthOfField: Double { d.double(forKey: "DepthOfField") }

    /// Focus distance in world units for `depthOfField`.
    ///
    /// **Zero means far-field**: everything softens with distance and the near
    /// field stays sharp, which is the only variant that is safe in play. A
    /// positive value focuses *at* that distance and softens either side of it,
    /// which is the cinematic look and belongs on cinematic surfaces.
    static var dofFocus: Double { d.double(forKey: "DofFocus") }

    /// How far from focus a pixel has to be to reach full blur, in world units.
    /// Larger is gentler. Defaults to 12 rather than 0, because a zero range would
    /// mean "everything not exactly in focus is fully blurred".
    static var dofRange: Double {
        let v = d.double(forKey: "DofRange")
        return v > 0 ? v : 12
    }

    /// Start the Sparkle auto-updater at launch.
    ///
    /// The default is decided by WHICH BUILD THIS IS, not by a `defaults` key, because the two
    /// audiences want opposite answers and a single default served the wrong one. A local build
    /// wants it OFF — the appcast isn't published, so an automatic startup check throws a
    /// missing-feed dialog — while a SHIPPED build must have it on, or the release strands itself:
    /// Sparkle is the only remediation channel Citadel has, and until this was split, a bare
    /// `d.bool(forKey:)` meant every 1.0 install would have gone out with automatic checks dead and
    /// `SUEnableAutomaticChecks` in Info.plist inert. Only players who happened to find
    /// "Check for Updates…" would ever have seen 1.0.1.
    ///
    /// `CITADEL_HARNESS` is exactly the right discriminator: release.mk defines it only when
    /// `SIGN_ID` is the ad-hoc `-`, and strips it from every signed release. So this needs no
    /// per-machine setup on either side, and the key remains an override for both — an opt-IN
    /// during development, an opt-OUT for a player who wants no update checks.
    static var updater: Bool {
        #if CITADEL_HARNESS
        return d.bool(forKey: "Updater")                                              // dev: off unless asked
        #else
        return d.object(forKey: "Updater") == nil ? true : d.bool(forKey: "Updater")   // shipped: on unless refused
        #endif
    }

    // Cheats — undocumented by design; the curious can find them in the source
    // (or via `strings` on the binary). Read live.
    static var godMode: Bool    { d.bool(forKey: "Godmode") }     // no damage
    static var revealMap: Bool  { d.bool(forKey: "RevealMap") }   // automap fully revealed
    static var fastMonsters: Bool { d.bool(forKey: "FastMonsters") } // -nightmare- speed

    /// The marine's headlamp in the rasterised renderer. Default ON; disable to judge
    /// the world lit purely by its OWN fixtures (lamps + emissive + baked propagation):
    ///   defaults write cc.jorviksoftware.Citadel Headlamp -bool false
    static var headlamp: Bool { d.object(forKey: "Headlamp") == nil ? true : d.bool(forKey: "Headlamp") }



    /// THE SEVEN — the last people in the cluster, sealed into fuel stores (one pool of seven for
    /// the whole run, 0–2 per building, no repeat; see Progression.survivors). Not a scatter: seven
    /// individuals, and that is all a player will ever find. Default ON; set false to strip them:
    ///   defaults write cc.jorviksoftware.Citadel FallenColonists -bool false
    static var fallenColonists: Bool { d.object(forKey: "FallenColonists") == nil ? true : d.bool(forKey: "FallenColonists") }

    /// Scattered papers — the flat floor-decal spread of spilled records near
    /// office desks. Default ON; set false to strip them (a perf A/B — the decal
    /// runs a small per-covered-pixel sheet loop):
    ///   defaults write cc.jorviksoftware.Citadel ScatteredPapers -bool false
    static var scatteredPapers: Bool { d.object(forKey: "ScatteredPapers") == nil ? true : d.bool(forKey: "ScatteredPapers") }

    /// Environmental AFTERMATH — the permanent seeded decals (doorway/scattered
    /// blood, scorch scars, spilled papers) that make a floor read as a fallen
    /// colony from the moment you arrive. They are NEVER evicted, so the per-floor-
    /// pixel decal loop runs from frame one of every level (at RC1 it stayed
    /// dormant until combat). Default ON; set false to test the loop's cost —
    /// this is the single biggest new fixed per-pixel cost since RC1:
    ///   defaults write cc.jorviksoftware.Citadel Aftermath -bool false
    static var aftermath: Bool { d.object(forKey: "Aftermath") == nil ? true : d.bool(forKey: "Aftermath") }

    /// Overhead-lamp brightness. Scales the ceiling lamps as a UNIT — their
    /// emissive glow AND the warm pools they cast onto the world and the weapon —
    /// leaving the headlamp, the ambient sector fill, and the dramatic point
    /// lights alone. 0.5 = the shipping default: the moody look the game is tuned
    /// for. The original authored lamps sit at 1.0, which washes out the early
    /// floors — raise toward it only if you want them brighter. Read live (next
    /// frame):
    ///   defaults write cc.jorviksoftware.Citadel OverheadLight -float 1.0
    static var overheadLight: Float {
        (d.object(forKey: "OverheadLight") as? Double).map { Float($0) } ?? 0.5
    }

    /// Force a specific level seed for testing (0 = off, use the run's seed).
    static var fixedSeed: UInt64 {
        let v = d.integer(forKey: "FixedSeed")
        return v > 0 ? UInt64(v) : 0
    }

    /// Warp new runs to a specific floor for testing (0 = off, start on floor 1).
    /// Clamped to the campaign's full content span — every distinct floor (the six
    /// planets × floorsPerBuilding), after which the structure only repeats with
    /// deeper scaling. Bounding it here keeps the level-scaled world-gen arithmetic
    /// (e.g. MapGen's `40 + level*2`) from overflowing or spawning a pathological
    /// monster count if StartLevel is set absurdly high via `defaults write`.
    static var startLevel: Int {
        let v = d.integer(forKey: "StartLevel")
        guard v > 0 else { return 0 }
        return min(v, Progression.planets.count * Progression.floorsPerBuilding)
    }
}
