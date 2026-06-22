// Citadel — controller setup sheet.
//
// Shows the live controller status and one rebindable row per pad action.
// Rebinding is arm-then-press: click a binding, release everything, then press
// the control you want — a poll timer captures it.

import Cocoa

private func monoC(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: weight)
}

final class ControllerSheet: NSObject {
    private static var current: ControllerSheet?
    private let sheet: NSWindow
    private weak var parent: NSWindow?
    private let gamepad: Gamepad
    private let statusLabel = NSTextField(labelWithString: "")
    private var buttons: [NSButton] = []
    private var captureAction: PadAction?
    private var captureArmed = false
    private var timer: Timer?

    static func present(over window: NSWindow, gamepad: Gamepad) {
        guard current == nil else { return }
        let s = ControllerSheet(gamepad: gamepad, parent: window)
        current = s
        gamepad.configuring = true
        window.beginSheet(s.sheet) { _ in
            gamepad.configuring = false
            s.timer?.invalidate()
            current = nil
            window.makeFirstResponder(window.contentView)
        }
        s.timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak s] _ in s?.refresh() }
    }

    private init(gamepad: Gamepad, parent: NSWindow) {
        self.gamepad = gamepad; self.parent = parent
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
                         styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        build()
    }

    private func build() {
        let title = NSTextField(labelWithString: "CONTROLLER")
        title.font = monoC(15, .bold)
        statusLabel.font = monoC(11, .semibold)
        let hint = NSTextField(labelWithString: "Left stick moves · right stick turns. Click a binding, then press a button.")
        hint.font = monoC(9); hint.textColor = .secondaryLabelColor

        var rows: [NSView] = [title, statusLabel, hint]
        for (i, action) in PadAction.activeCases.enumerated() {
            let label = NSTextField(labelWithString: action.title)
            label.font = monoC(11)
            label.widthAnchor.constraint(equalToConstant: 150).isActive = true
            let btn = NSButton(title: gamepad.binding(for: action), target: self, action: #selector(beginCapture(_:)))
            btn.bezelStyle = .rounded; btn.font = monoC(11, .semibold); btn.tag = i
            btn.widthAnchor.constraint(equalToConstant: 120).isActive = true
            buttons.append(btn)
            let row = NSStackView(views: [label, btn])
            row.orientation = .horizontal; row.spacing = 12
            rows.append(row)
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.bezelStyle = .rounded; done.keyEquivalent = "\r"
        done.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        sheet.contentView = content
        content.addSubview(stack); content.addSubview(done)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            done.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            done.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])
        refresh()
    }

    @objc private func beginCapture(_ sender: NSButton) {
        let cases = PadAction.activeCases
        guard sender.tag >= 0 && sender.tag < cases.count else { return }
        captureAction = cases[sender.tag]
        captureArmed = false
        refreshTitles()
    }

    private func refresh() {
        if gamepad.connected {
            statusLabel.stringValue = "DETECTED: \(gamepad.name)"
            statusLabel.textColor = .systemGreen
        } else {
            statusLabel.stringValue = "NO CONTROLLER — KEYBOARD ACTIVE"
            statusLabel.textColor = .systemOrange
        }
        if let action = captureAction {
            if !captureArmed {
                if gamepad.capturedControl() == nil { captureArmed = true }
            } else if let control = gamepad.capturedControl() {
                gamepad.setBinding(control, for: action)
                captureAction = nil
                refreshTitles()
            }
        }
    }

    private func refreshTitles() {
        for (i, action) in PadAction.activeCases.enumerated() {
            buttons[i].title = (captureAction == action) ? "PRESS…" : gamepad.binding(for: action)
        }
    }

    @objc private func close() { if let p = parent { p.endSheet(sheet) } }
}
