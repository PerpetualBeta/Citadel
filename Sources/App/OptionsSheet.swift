// Citadel — settings sheet (audio + controls + reset scores).
//
// Programmatic AppKit. Volume sliders apply live and persist to GameSettings;
// mouse-look, sensitivity, turn speed, deadzone and always-run toggles; and a
// destructive "reset high scores" with confirmation.

import Cocoa

private func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: weight)
}

final class OptionsSheet: NSObject {
    private static var current: OptionsSheet?
    private let sheet: NSWindow
    private weak var parent: NSWindow?
    private let audio: AudioEngine
    private let gamepad: Gamepad
    private let highScores: HighScores

    private let musicVal = NSTextField(labelWithString: "")
    private let sfxVal = NSTextField(labelWithString: "")
    private let ambVal = NSTextField(labelWithString: "")
    private let mouseVal = NSTextField(labelWithString: "")
    private let turnVal = NSTextField(labelWithString: "")
    private let dzVal = NSTextField(labelWithString: "")

    static func present(over window: NSWindow, audio: AudioEngine, gamepad: Gamepad, highScores: HighScores) {
        guard current == nil else { return }
        let s = OptionsSheet(audio: audio, gamepad: gamepad, highScores: highScores, parent: window)
        current = s
        gamepad.configuring = true
        window.beginSheet(s.sheet) { _ in
            gamepad.configuring = false
            current = nil
            window.makeFirstResponder(window.contentView)
        }
    }

    private init(audio: AudioEngine, gamepad: Gamepad, highScores: HighScores, parent: NSWindow) {
        self.audio = audio; self.gamepad = gamepad; self.highScores = highScores; self.parent = parent
        // Taller for the LENS EFFECTS section: `rows` is pinned to the top and the buttons
        // to the bottom, so rows that outgrow the gap would run underneath Done rather
        // than making the sheet scroll. Three new rows plus the section heading and its
        // spacing is about 95pt; 470 leaves margin.
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 470),
                         styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        build()
    }

    private func build() {
        let title = NSTextField(labelWithString: "SETTINGS")
        title.font = mono(15, .bold)

        let rows = NSStackView(views: [
            title,
            volumeRow("MUSIC", audio.musicGain, musicVal, #selector(musicChanged(_:))),
            volumeRow("SOUND", audio.sfxGain, sfxVal, #selector(sfxChanged(_:))),
            volumeRow("AMBIENT", audio.ambientGain, ambVal, #selector(ambChanged(_:))),
            toggleRow("MOUSE LOOK", GameSettings.shared.mouseEnabled, #selector(mouseToggled(_:))),
            sliderRow("MOUSE SENS", Double(GameSettings.shared.mouseSensitivity), 0.2, 3.0, mouseVal, #selector(mouseSensChanged(_:))),
            sliderRow("TURN SPEED", Double(GameSettings.shared.turnSpeed), 0.4, 2.0, turnVal, #selector(turnChanged(_:))),
            sliderRow("DEADZONE", Double(gamepad.deadzone), 0.05, 0.5, dzVal, #selector(deadzoneChanged(_:))),
            toggleRow("ALWAYS RUN", GameSettings.shared.autorun, #selector(autorunToggled(_:))),
            sectionRow("LENS EFFECTS"),
            toggleRow("DEPTH OF FIELD", GameSettings.shared.lensDoF, #selector(lensDoFToggled(_:))),
            toggleRow("ANAMORPHIC", GameSettings.shared.lensAnamorphic, #selector(lensAnamorphicToggled(_:))),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 9
        rows.translatesAutoresizingMaskIntoConstraints = false

        let reset = NSButton(title: "Reset High Scores", target: self, action: #selector(resetScores))
        reset.bezelStyle = .rounded
        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [reset, done])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        sheet.contentView = content
        content.addSubview(rows)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])
        updateValues()
    }

    private func volumeRow(_ name: String, _ value: Float, _ label: NSTextField, _ action: Selector) -> NSStackView {
        sliderRow(name, Double(value), 0, 1, label, action)
    }

    private func sliderRow(_ name: String, _ value: Double, _ lo: Double, _ hi: Double, _ label: NSTextField, _ action: Selector) -> NSStackView {
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = mono(11)
        nameLabel.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let slider = NSSlider(value: value, minValue: lo, maxValue: hi, target: self, action: action)
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        label.font = mono(10)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 46).isActive = true
        let row = NSStackView(views: [nameLabel, slider, label])
        row.orientation = .horizontal; row.spacing = 10
        return row
    }

    /// A section heading inside the sheet's single column.
    ///
    /// Returned as a one-view `NSStackView` so it drops into the same `rows` list as every
    /// other row without the caller needing to know it is not a control. Indented to the
    /// same leading edge as the labels, and spaced above by padding rather than by a
    /// separator: the sheet is nine rows of monospaced text, and a rule across it would
    /// weigh more than the grouping it announces.
    private func sectionRow(_ name: String) -> NSStackView {
        let label = NSTextField(labelWithString: name)
        label.font = mono(11, .bold)
        label.textColor = .secondaryLabelColor
        let row = NSStackView(views: [label])
        row.orientation = .horizontal
        row.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)
        return row
    }

    private func toggleRow(_ name: String, _ on: Bool, _ action: Selector) -> NSStackView {
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = mono(11)
        nameLabel.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let sw = NSButton(checkboxWithTitle: "", target: self, action: action)
        sw.state = on ? .on : .off
        let row = NSStackView(views: [nameLabel, sw])
        row.orientation = .horizontal; row.spacing = 10
        return row
    }

    private func updateValues() {
        musicVal.stringValue = "\(Int(audio.musicGain * 100))%"
        sfxVal.stringValue = "\(Int(audio.sfxGain * 100))%"
        ambVal.stringValue = "\(Int(audio.ambientGain * 100))%"
        mouseVal.stringValue = String(format: "%.1f", GameSettings.shared.mouseSensitivity)
        turnVal.stringValue = String(format: "%.1f", GameSettings.shared.turnSpeed)
        dzVal.stringValue = String(format: "%.2f", gamepad.deadzone)
    }

    @objc private func musicChanged(_ s: NSSlider) { audio.musicGain = Float(s.doubleValue); GameSettings.shared.musicVolume = audio.musicGain; updateValues() }
    @objc private func sfxChanged(_ s: NSSlider) { audio.sfxGain = Float(s.doubleValue); GameSettings.shared.sfxVolume = audio.sfxGain; audio.pickup(); updateValues() }
    @objc private func ambChanged(_ s: NSSlider) { audio.ambientGain = Float(s.doubleValue); GameSettings.shared.ambientVolume = audio.ambientGain; updateValues() }
    @objc private func mouseToggled(_ b: NSButton) { GameSettings.shared.mouseEnabled = b.state == .on }
    @objc private func mouseSensChanged(_ s: NSSlider) { GameSettings.shared.mouseSensitivity = Float(s.doubleValue); updateValues() }
    @objc private func turnChanged(_ s: NSSlider) { GameSettings.shared.turnSpeed = Float(s.doubleValue); updateValues() }
    @objc private func deadzoneChanged(_ s: NSSlider) { gamepad.deadzone = Float(s.doubleValue); updateValues() }
    @objc private func autorunToggled(_ b: NSButton) { GameSettings.shared.autorun = b.state == .on }

    // Nothing to notify: `FeatureFlags` reads these on every frame, so flipping either
    // switch takes effect on the next one — visibly, while the sheet is still open.
    @objc private func lensDoFToggled(_ b: NSButton) { GameSettings.shared.lensDoF = b.state == .on }
    @objc private func lensAnamorphicToggled(_ b: NSButton) { GameSettings.shared.lensAnamorphic = b.state == .on }

    @objc private func resetScores() {
        let alert = NSAlert()
        alert.messageText = "Reset all high scores?"
        alert.informativeText = "This permanently clears the Hall of the Fallen and the terminal arcade high scores."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            highScores.clear()
            ArcadeScores.shared.clear()   // the arcade table wipes together with the main game's
        }
    }

    @objc private func close() {
        if let p = parent { p.endSheet(sheet) }
    }
}
