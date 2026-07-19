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

    /// Render the Queen as a textured 3D mesh (Resources/queen.usdz) instead of
    /// the native SDF sculpt. ON by default while we evaluate the 3D-asset
    /// direction; set false to A/B against the SDF queen:
    ///   defaults write cc.jorviksoftware.Citadel MeshQueen -bool false
    static var meshQueen: Bool { d.object(forKey: "MeshQueen") == nil ? true : d.bool(forKey: "MeshQueen") }
    /// Drones drawn as 3-D textured meshes (Tripo) instead of SDF. Default ON;
    ///   defaults write cc.jorviksoftware.Citadel MeshDrone -bool false   to A/B vs SDF.
    static var meshDrone: Bool { d.object(forKey: "MeshDrone") == nil ? true : d.bool(forKey: "MeshDrone") }

    /// Overhead-lamp brightness. Scales the ceiling lamps as a UNIT — their
    /// emissive glow AND the warm pools they cast onto the world and the weapon —
    /// leaving the headlamp, the ambient sector fill, and the dramatic point
    /// lights alone. 1.0 = as-authored; lower it to darken the early floors, which
    /// light brighter than this game wants. Read live (next frame):
    ///   defaults write cc.jorviksoftware.Citadel OverheadLight -float 0.7
    static var overheadLight: Float {
        (d.object(forKey: "OverheadLight") as? Double).map { Float($0) } ?? 1.0
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
