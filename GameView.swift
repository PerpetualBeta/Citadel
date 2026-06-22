// Citadel — the Metal view, keyboard, and mouse.
//
// Subclasses MTKView. Captures the keyboard (with a rebindable action map),
// optional mouse-look (relative deltas while the pointer is associated off),
// and high-score name entry. Writes the keyboard source of InputState; the
// renderer (the view's delegate) reads it.

import Cocoa
import MetalKit

// Stable macOS virtual key codes (ANSI hardware positions).
enum VK {
    static let a = 0, s = 1, d = 2, f = 3, h = 4, g = 5, z = 6, x = 7, c = 8, v = 9
    static let b = 11, q = 12, w = 13, e = 14, r = 15, y = 16
    static let one = 18, two = 19, three = 20, four = 21, six = 22, five = 23, seven = 26, eight = 28
    static let leftBracket = 33, rightBracket = 30, i = 34, p = 35, l = 37, m = 46
    static let space = 49, ret = 36, esc = 53, tab = 48, delete = 51, shift = 56
    static let left = 123, right = 124, down = 125, up = 126
}

enum KeyAction: String, CaseIterable {
    case forward, back, strafeLeft, strafeRight, turnLeft, turnRight, run, fire, use, weaponNext, weaponPrev

    var title: String {
        switch self {
        case .forward: return "MOVE FORWARD"
        case .back: return "MOVE BACK"
        case .strafeLeft: return "STRAFE LEFT"
        case .strafeRight: return "STRAFE RIGHT"
        case .turnLeft: return "TURN LEFT"
        case .turnRight: return "TURN RIGHT"
        case .run: return "RUN (HOLD)"
        case .fire: return "FIRE"
        case .use: return "USE / OPEN"
        case .weaponNext: return "NEXT WEAPON"
        case .weaponPrev: return "PREV WEAPON"
        }
    }
    var defaultKey: Int {
        switch self {
        case .forward: return VK.w
        case .back: return VK.s
        case .strafeLeft: return VK.a
        case .strafeRight: return VK.d
        case .turnLeft: return VK.left
        case .turnRight: return VK.right
        case .run: return VK.shift
        case .fire: return VK.space
        case .use: return VK.e
        case .weaponNext: return VK.rightBracket
        case .weaponPrev: return VK.leftBracket
        }
    }
}

final class KeyBindings {
    static let shared = KeyBindings()
    private var overrides: [String: Int]
    private var reverse: [Int: KeyAction] = [:]
    /// Fixed keys that cannot be rebound to (reserved for the UI).
    static let reserved: Set<Int> = [VK.esc, VK.p, VK.m, VK.tab, VK.ret,
                                     VK.one, VK.two, VK.three, VK.four, VK.five, VK.six, VK.seven, VK.eight]

    private init() { overrides = GameSettings.shared.keyBindings; rebuild() }

    func binding(for a: KeyAction) -> Int { overrides[a.rawValue] ?? a.defaultKey }
    func action(for code: Int) -> KeyAction? { reverse[code] }

    func setBinding(_ code: Int, for a: KeyAction) {
        // if another action already used this code, clear it
        if let other = reverse[code], other != a { overrides[other.rawValue] = -1 }
        overrides[a.rawValue] = code
        GameSettings.shared.keyBindings = overrides
        rebuild()
    }
    func resetDefaults() {
        overrides = [:]; GameSettings.shared.keyBindings = [:]; rebuild()
    }
    private func rebuild() {
        reverse.removeAll()
        for a in KeyAction.allCases {
            let code = overrides[a.rawValue] ?? a.defaultKey
            if code >= 0 { reverse[code] = a }
        }
    }
    static func friendlyName(_ code: Int) -> String {
        let names: [Int: String] = [
            VK.space: "SPACE", VK.ret: "RETURN", VK.esc: "ESC", VK.tab: "TAB", VK.shift: "SHIFT",
            VK.left: "LEFT", VK.right: "RIGHT", VK.up: "UP", VK.down: "DOWN", VK.delete: "DEL",
            VK.leftBracket: "[", VK.rightBracket: "]",
            VK.a: "A", VK.b: "B", VK.c: "C", VK.d: "D", VK.e: "E", VK.f: "F", VK.g: "G", VK.h: "H",
            VK.i: "I", VK.l: "L", VK.m: "M", VK.p: "P", VK.q: "Q", VK.r: "R", VK.s: "S", VK.v: "V",
            VK.w: "W", VK.x: "X", VK.y: "Y", VK.z: "Z",
        ]
        return names[code] ?? "KEY\(code)"
    }
}

final class GameView: MTKView {
    let input: InputState
    weak var gamepad: Gamepad?
    var onOpenKeyboard: (() -> Void)?
    var onOpenController: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private var mouseCaptured = false

    init(frame: CGRect, device: MTLDevice, input: InputState) {
        self.input = input
        super.init(frame: frame, device: device)
        self.colorPixelFormat = .bgra8Unorm
        self.framebufferOnly = true
        self.preferredFramesPerSecond = 60
        self.isPaused = false
        self.enableSetNeedsDisplay = false
    }
    required init(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    // ── mouse-look ──
    func updateMouseCapture(_ wanted: Bool) {
        let want = wanted && GameSettings.shared.mouseEnabled && (window?.isKeyWindow ?? false)
        if want == mouseCaptured { return }
        mouseCaptured = want
        if want { NSCursor.hide(); CGAssociateMouseAndMouseCursorPosition(0) }
        else { CGAssociateMouseAndMouseCursorPosition(1); NSCursor.unhide() }
    }

    override func mouseMoved(with event: NSEvent) { applyMouse(event) }
    override func mouseDragged(with event: NSEvent) { applyMouse(event) }
    private func applyMouse(_ event: NSEvent) {
        guard mouseCaptured else { return }
        let sens = GameSettings.shared.mouseSensitivity * 0.003
        input.mouseTurn += Float(event.deltaX) * sens
    }
    override func mouseDown(with event: NSEvent) { if mouseCaptured { input.kb.fire = true } else { super.mouseDown(with: event) } }
    override func mouseUp(with event: NSEvent) { input.kb.fire = false }

    // ── keyboard ──
    override func keyDown(with event: NSEvent) {
        if input.nameEntryActive { handleNameEntry(event); return }
        let code = Int(event.keyCode)
        if let act = KeyBindings.shared.action(for: code) { set(act, true); return }
        switch code {
        case VK.up: input.kb.forward = true
        case VK.down: input.kb.back = true
        case VK.p: input.kb.pause = true
        case VK.m: input.kb.mute = true
        case VK.tab: input.kb.map = true
        case VK.esc: input.kb.cancel = true
        case VK.b: input.kb.briefing = true
        case VK.i: input.kb.intel = true
        case VK.g: input.kb.deployMine = true
        case VK.f: if FeatureFlags.screenshotKey { input.kb.screenshot = true }
        case VK.ret, VK.space: input.kb.restart = true
        case VK.one: input.weaponDigit = 1
        case VK.two: input.weaponDigit = 2
        case VK.three: input.weaponDigit = 3
        case VK.four: input.weaponDigit = 4
        case VK.five: input.weaponDigit = 5
        case VK.six: input.weaponDigit = 6
        case VK.seven: input.weaponDigit = 7
        case VK.eight: input.weaponDigit = 8
        case VK.k: onOpenKeyboard?()
        case VK.c: onOpenController?()
        default: super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if input.nameEntryActive { return }
        let code = Int(event.keyCode)
        if let act = KeyBindings.shared.action(for: code) { set(act, false); return }
        switch code {
        case VK.up: input.kb.forward = false
        case VK.down: input.kb.back = false
        case VK.p: input.kb.pause = false
        case VK.m: input.kb.mute = false
        case VK.tab: input.kb.map = false
        case VK.esc: input.kb.cancel = false
        case VK.b: input.kb.briefing = false
        case VK.i: input.kb.intel = false
        case VK.g: input.kb.deployMine = false
        case VK.f: input.kb.screenshot = false
        case VK.ret, VK.space: input.kb.restart = false
        default: super.keyUp(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        // command-comma → settings; track shift for run if bound to shift
        if event.modifierFlags.contains(.command) { return }
        let shiftDown = event.modifierFlags.contains(.shift)
        if KeyBindings.shared.binding(for: .run) == VK.shift { input.kb.run = shiftDown }
    }

    private func set(_ a: KeyAction, _ down: Bool) {
        switch a {
        case .forward: input.kb.forward = down
        case .back: input.kb.back = down
        case .strafeLeft: input.kb.strafeLeft = down
        case .strafeRight: input.kb.strafeRight = down
        case .turnLeft: input.kb.turnLeft = down
        case .turnRight: input.kb.turnRight = down
        case .run: input.kb.run = down
        case .fire: input.kb.fire = down
        case .use: input.kb.use = down
        case .weaponNext: input.kb.weaponNext = down
        case .weaponPrev: input.kb.weaponPrev = down
        }
    }

    private func handleNameEntry(_ event: NSEvent) {
        let code = Int(event.keyCode)
        if code == VK.ret { input.nameCommitted = true; return }
        if code == VK.delete {
            if !input.nameBuffer.isEmpty { input.nameBuffer.removeLast() }
            return
        }
        if code == VK.esc { input.nameCommitted = true; return }
        if let chars = event.characters, !chars.isEmpty {
            for ch in chars where !ch.isNewline && (ch == " " || !ch.unicodeScalars.contains(where: { $0.value < 32 })) {
                if input.nameBuffer.count < 32 { input.nameBuffer.append(ch) }
            }
        }
    }
}

extension VK { static let k = 40 }
