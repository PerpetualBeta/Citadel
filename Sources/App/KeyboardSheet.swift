// Citadel — keyboard rebinding sheet.
//
// One row per rebindable action; click a binding and the next key you press
// (captured by a local event monitor) becomes the new binding. Reserved UI keys
// (Esc, P, M, Tab, Return, 1–7) can't be claimed.

import Cocoa

private func monoK(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: weight)
}

final class KeyboardSheet: NSObject {
    private static var current: KeyboardSheet?
    private let sheet: NSWindow
    private weak var parent: NSWindow?
    private var buttons: [NSButton] = []
    private var captureAction: KeyAction?
    private var monitor: Any?

    static func present(over window: NSWindow, gamepad: Gamepad) {
        guard current == nil else { return }
        let s = KeyboardSheet(parent: window)
        current = s
        gamepad.configuring = true
        window.beginSheet(s.sheet) { _ in
            gamepad.configuring = false
            if let m = s.monitor { NSEvent.removeMonitor(m) }
            current = nil
            window.makeFirstResponder(window.contentView)
        }
        s.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak s] ev in
            guard let s = s, let action = s.captureAction else { return ev }
            let code = Int(ev.keyCode)
            if code == VK.esc { s.captureAction = nil; s.refresh(); return nil }
            if KeyBindings.reserved.contains(code) { NSSound.beep(); return nil }
            KeyBindings.shared.setBinding(code, for: action)
            s.captureAction = nil
            s.refresh()
            return nil
        }
    }

    private init(parent: NSWindow) {
        self.parent = parent
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                         styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        build()
    }

    private func build() {
        let title = NSTextField(labelWithString: "KEYBOARD")
        title.font = monoK(15, .bold)
        let hint = NSTextField(labelWithString: "Click a binding, then press a key.")
        hint.font = monoK(10); hint.textColor = .secondaryLabelColor

        var rows: [NSView] = [title, hint]
        for (i, action) in KeyAction.allCases.enumerated() {
            let label = NSTextField(labelWithString: action.title)
            label.font = monoK(11)
            label.widthAnchor.constraint(equalToConstant: 160).isActive = true
            let btn = NSButton(title: KeyBindings.friendlyName(KeyBindings.shared.binding(for: action)),
                               target: self, action: #selector(beginCapture(_:)))
            btn.bezelStyle = .rounded; btn.font = monoK(11, .semibold); btn.tag = i
            btn.widthAnchor.constraint(equalToConstant: 110).isActive = true
            buttons.append(btn)
            let row = NSStackView(views: [label, btn])
            row.orientation = .horizontal; row.spacing = 12
            rows.append(row)
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false

        let reset = NSButton(title: "Defaults", target: self, action: #selector(resetDefaults))
        reset.bezelStyle = .rounded
        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.bezelStyle = .rounded; done.keyEquivalent = "\r"
        let buttonsRow = NSStackView(views: [reset, done])
        buttonsRow.orientation = .horizontal; buttonsRow.spacing = 12
        buttonsRow.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        sheet.contentView = content
        content.addSubview(stack); content.addSubview(buttonsRow)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            buttonsRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            buttonsRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])
    }

    @objc private func beginCapture(_ sender: NSButton) {
        let cases = KeyAction.allCases
        guard sender.tag >= 0 && sender.tag < cases.count else { return }
        captureAction = cases[sender.tag]
        refresh()
    }

    private func refresh() {
        for (i, action) in KeyAction.allCases.enumerated() {
            buttons[i].title = (captureAction == action) ? "PRESS…"
                : KeyBindings.friendlyName(KeyBindings.shared.binding(for: action))
        }
    }

    @objc private func resetDefaults() { KeyBindings.shared.resetDefaults(); captureAction = nil; refresh() }
    @objc private func close() { if let p = parent { p.endSheet(sheet) } }
}
