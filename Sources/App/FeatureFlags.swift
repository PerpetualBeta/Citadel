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

    /// Start the Sparkle auto-updater. Off by default in development — the
    /// appcast isn't published yet, so the automatic startup check would throw a
    /// missing-feed dialog. The "Check for Updates…" menu still works on demand.
    static var updater: Bool { d.bool(forKey: "Updater") }

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
