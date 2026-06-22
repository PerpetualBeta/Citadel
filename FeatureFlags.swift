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

    /// Renderer pivot (Stage 1): draw the 3-D view with the GPU SDF raymarcher
    /// (GPURaymarch kernel) instead of the CPU raycaster. Off by default during
    /// development; falls back cleanly to the raycaster when off.
    static var metalRenderer: Bool { d.bool(forKey: "MetalRenderer") }

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

    /// Force a specific level seed for testing (0 = off, use the run's seed).
    static var fixedSeed: UInt64 {
        let v = d.integer(forKey: "FixedSeed")
        return v > 0 ? UInt64(v) : 0
    }
}
