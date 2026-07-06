// Citadel — game controller support.
//
// Any Extended Gamepad (Xbox / DualShock / MFi) is detected automatically. The
// left stick moves, the right stick turns; the discrete actions (fire, use,
// run, weapon next/prev, pause) are rebindable and persisted. Keyboard always
// works alongside — InputState ORs the two sources together.

import Foundation
import GameController

enum PadAction: String, CaseIterable {
    case fire, use, run, weaponNext, weaponPrev, pause, map, screenshot

    var title: String {
        switch self {
        case .fire: return "FIRE"
        case .use: return "USE / OPEN"
        case .run: return "RUN (HOLD)"
        case .weaponNext: return "NEXT WEAPON"
        case .weaponPrev: return "PREV WEAPON"
        case .pause: return "PAUSE"
        case .map: return "AUTOMAP"
        case .screenshot: return "SCREENSHOT"
        }
    }

    var defaultControl: String {
        switch self {
        case .fire: return "RT"
        case .use: return "A"
        case .run: return "LB"
        case .weaponNext: return "RB"
        case .weaponPrev: return "LT"
        case .pause: return "MENU"
        case .map: return "X"
        case .screenshot: return "Y"
        }
    }

    static var activeCases: [PadAction] {
        var c: [PadAction] = [.fire, .use, .run, .weaponNext, .weaponPrev, .pause, .map]
        if FeatureFlags.screenshotKey { c.append(.screenshot) }
        return c
    }
}

final class Gamepad {
    private(set) var bindings: [PadAction: String] = [:]
    var configuring = false

    // live state (for the controller sheet preview)
    private(set) var connected = false
    private(set) var name = "—"
    private(set) var stickX: Float = 0
    private(set) var stickY: Float = 0
    private(set) var turning: Float = 0
    private(set) var firing = false
    private(set) var usePressed = false
    private(set) var running = false
    private(set) var menu = false

    var deadzone: Float = GameSettings.shared.deadzone { didSet { GameSettings.shared.deadzone = deadzone } }

    static let bindableControls = ["A", "B", "X", "Y", "LB", "RB", "LT", "RT", "MENU", "OPTIONS", "L3", "R3",
                                   "DPAD-UP", "DPAD-DOWN", "DPAD-LEFT", "DPAD-RIGHT"]

    init() {
        var b: [PadAction: String] = [:]
        let saved = GameSettings.shared.padBindings
        for a in PadAction.allCases { b[a] = saved[a.rawValue] ?? a.defaultControl }
        bindings = b
        GCController.startWirelessControllerDiscovery(completionHandler: {})
    }

    func binding(for a: PadAction) -> String { bindings[a] ?? a.defaultControl }

    func setBinding(_ control: String, for a: PadAction) {
        bindings[a] = control
        var d: [String: String] = [:]
        for (act, c) in bindings { d[act.rawValue] = c }
        GameSettings.shared.padBindings = d
    }

    static func friendlyName(_ c: String) -> String { c }

    static func controlValue(_ name: String, _ gp: GCExtendedGamepad) -> Float {
        switch name {
        case "A": return gp.buttonA.value
        case "B": return gp.buttonB.value
        case "X": return gp.buttonX.value
        case "Y": return gp.buttonY.value
        case "LB": return gp.leftShoulder.value
        case "RB": return gp.rightShoulder.value
        case "LT": return gp.leftTrigger.value
        case "RT": return gp.rightTrigger.value
        case "MENU": return gp.buttonMenu.value
        case "OPTIONS": return gp.buttonOptions?.value ?? 0
        case "L3": return gp.leftThumbstickButton?.value ?? 0
        case "R3": return gp.rightThumbstickButton?.value ?? 0
        case "DPAD-UP": return gp.dpad.up.value
        case "DPAD-DOWN": return gp.dpad.down.value
        case "DPAD-LEFT": return gp.dpad.left.value
        case "DPAD-RIGHT": return gp.dpad.right.value
        default: return 0
        }
    }

    /// A control currently pressed past a high threshold (for rebind capture).
    func capturedControl() -> String? {
        guard let gp = GCController.controllers().first?.extendedGamepad else { return nil }
        for c in Gamepad.bindableControls where Gamepad.controlValue(c, gp) > 0.6 { return c }
        return nil
    }

    private func down(_ a: PadAction, _ gp: GCExtendedGamepad) -> Bool {
        Gamepad.controlValue(binding(for: a), gp) > 0.4
    }

    func poll(_ input: InputState) {
        guard let gc = GCController.controllers().first, let gp = gc.extendedGamepad else {
            connected = false; name = "—"
            input.gp = .init(); input.moveX = 0; input.moveY = 0; input.lookX = 0
            stickX = 0; stickY = 0; firing = false; usePressed = false; running = false; menu = false
            return
        }
        connected = true
        name = gc.vendorName ?? "Controller"

        let lx = gp.leftThumbstick.xAxis.value
        let ly = gp.leftThumbstick.yAxis.value
        let rx = gp.rightThumbstick.xAxis.value
        stickX = lx; stickY = ly; turning = rx

        if configuring {
            // freeze gameplay input while remapping
            input.gp = .init(); input.moveX = 0; input.moveY = 0; input.lookX = 0
            firing = false; usePressed = false; running = false; menu = false
            return
        }

        var c = InputState.Controls()
        let dz = deadzone
        input.moveX = abs(lx) > dz ? lx : 0
        input.moveY = abs(ly) > dz ? ly : 0
        input.lookX = abs(rx) > dz ? rx : 0
        // also let the dpad drive discrete movement
        if gp.dpad.left.value > 0.5 { c.strafeLeft = true }
        if gp.dpad.right.value > 0.5 { c.strafeRight = true }
        if gp.dpad.up.value > 0.5 { c.forward = true }
        if gp.dpad.down.value > 0.5 { c.back = true }

        firing = down(.fire, gp)
        usePressed = down(.use, gp)
        running = down(.run, gp)
        menu = down(.pause, gp)
        if firing { c.fire = true; c.restart = true }   // fire confirms menus
        if menu { c.pause = true; c.restart = true }
        if usePressed { c.use = true }
        if running { c.run = true }
        if down(.weaponNext, gp) { c.weaponNext = true }
        if down(.weaponPrev, gp) { c.weaponPrev = true }
        if down(.map, gp) { c.map = true }
        if (gp.leftThumbstickButton?.value ?? 0) > 0.5 { c.deployMine = true }   // L3 drops a mine
        if gp.buttonB.value > 0.5 { c.cancel = true }
        if FeatureFlags.screenshotKey && down(.screenshot, gp) { c.screenshot = true }
        input.gp = c
    }
}
