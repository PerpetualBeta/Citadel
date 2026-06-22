// Citadel — persisted user settings.
//
// A thin, typed wrapper over UserDefaults: the single source of truth for the
// player's audio volumes and control preferences. AudioEngine and Gamepad read
// these on launch; the options / controller / keyboard sheets write them.
// Everything survives across sessions.

import Foundation

final class GameSettings {
    static let shared = GameSettings()

    private let d = UserDefaults.standard

    private enum Key {
        static let musicVolume   = "musicVolume"
        static let sfxVolume     = "sfxVolume"
        static let ambientVolume = "ambientVolume"
        static let mouseEnabled  = "mouseEnabled"
        static let mouseSensitivity = "mouseSensitivity"
        static let turnSpeed     = "turnSpeed"
        static let autorun       = "autorun"
        static let deadzone      = "deadzone"
        static let padBindings   = "padBindings"
        static let keyBindings   = "keyBindings"
    }

    private init() {
        d.register(defaults: [
            Key.musicVolume:   0.7,
            Key.sfxVolume:     0.9,
            Key.ambientVolume: 0.6,
            Key.mouseEnabled:  false,
            Key.mouseSensitivity: 1.0,
            Key.turnSpeed:     1.0,
            Key.autorun:       false,
            Key.deadzone:      0.22,
        ])
    }

    // Audio — linear gains in 0...1.
    var musicVolume: Float   { get { d.float(forKey: Key.musicVolume) }   set { d.set(newValue, forKey: Key.musicVolume) } }
    var sfxVolume: Float     { get { d.float(forKey: Key.sfxVolume) }     set { d.set(newValue, forKey: Key.sfxVolume) } }
    var ambientVolume: Float { get { d.float(forKey: Key.ambientVolume) } set { d.set(newValue, forKey: Key.ambientVolume) } }

    // Controls.
    var mouseEnabled: Bool      { get { d.bool(forKey: Key.mouseEnabled) }      set { d.set(newValue, forKey: Key.mouseEnabled) } }
    var mouseSensitivity: Float { get { d.float(forKey: Key.mouseSensitivity) } set { d.set(newValue, forKey: Key.mouseSensitivity) } }
    var turnSpeed: Float        { get { d.float(forKey: Key.turnSpeed) }        set { d.set(newValue, forKey: Key.turnSpeed) } }
    var autorun: Bool           { get { d.bool(forKey: Key.autorun) }           set { d.set(newValue, forKey: Key.autorun) } }
    var deadzone: Float         { get { d.float(forKey: Key.deadzone) }         set { d.set(newValue, forKey: Key.deadzone) } }

    // Controller button rebinds: [PadAction.rawValue: control name]. Empty until
    // the player changes something; Gamepad falls back to per-action defaults.
    var padBindings: [String: String] {
        get { d.dictionary(forKey: Key.padBindings) as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: Key.padBindings) }
    }

    // Keyboard rebinds: [KeyAction.rawValue: virtual key code]. Empty until the
    // player changes something; KeyBindings falls back to per-action defaults.
    var keyBindings: [String: Int] {
        get { d.dictionary(forKey: Key.keyBindings) as? [String: Int] ?? [:] }
        set { d.set(newValue, forKey: Key.keyBindings) }
    }
}
