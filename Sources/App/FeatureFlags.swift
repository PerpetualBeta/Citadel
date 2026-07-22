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
    static var allWeapons: Bool { d.bool(forKey: "AllWeapons") }  // full arsenal + ammo at spawn
    static var noClip: Bool     { d.bool(forKey: "NoClip") }      // walk through walls
    static var revealMap: Bool  { d.bool(forKey: "RevealMap") }   // automap fully revealed
    static var fastMonsters: Bool { d.bool(forKey: "FastMonsters") } // -nightmare- speed

    /// Volumetric GPU fire — the flamethrower jet and corpse pyres rendered as
    /// procedural, domain-warped flame tongues in the raymarch kernel (plus their
    /// flickering firelight), instead of the old CPU additive-orb billboards.
    /// Default ON; set false to A/B against the legacy CPU flame:
    ///   defaults write cc.jorviksoftware.Citadel GPUFire -bool false
    static var gpuFire: Bool { d.object(forKey: "GPUFire") == nil ? true : d.bool(forKey: "GPUFire") }

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
