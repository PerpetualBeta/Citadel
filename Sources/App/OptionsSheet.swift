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
        // Sized from its content in `build()`, not here — this rect is a placeholder.
        // It was a hard-coded height, which meant every row added to the sheet needed
        // someone to do arithmetic and get it right, and the last one was committed with
        // a note saying it had never been looked at.
        sheet = NSWindow(contentRect: NSRect(origin: .zero, size: Metrics.minContentSize),
                         styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        build()
    }

    private func build() {
        let title = NSTextField(labelWithString: "SETTINGS")
        title.font = mono(15, .bold)

        // Every control sits under a named section, in the order the suite uses:
        // app-specific groups top to bottom, destructive actions last. This sheet had no
        // sections at all until LENS EFFECTS was added, which left it reading as eight
        // unlabelled rows followed by one labelled group — the heading made the absence
        // of the others obvious rather than tidying anything.
        let rows = NSStackView(views: [
            title,
            sectionRow("AUDIO"),
            volumeRow("MUSIC", audio.musicGain, musicVal, #selector(musicChanged(_:))),
            volumeRow("SOUND", audio.sfxGain, sfxVal, #selector(sfxChanged(_:))),
            volumeRow("AMBIENT", audio.ambientGain, ambVal, #selector(ambChanged(_:))),
            sectionRow("CONTROLS"),
            toggleRow("MOUSE LOOK", GameSettings.shared.mouseEnabled, #selector(mouseToggled(_:))),
            sliderRow("MOUSE SENS", Double(GameSettings.shared.mouseSensitivity), 0.2, 3.0, mouseVal, #selector(mouseSensChanged(_:))),
            sliderRow("TURN SPEED", Double(GameSettings.shared.turnSpeed), 0.4, 2.0, turnVal, #selector(turnChanged(_:))),
            sliderRow("DEADZONE", Double(gamepad.deadzone), 0.05, 0.5, dzVal, #selector(deadzoneChanged(_:))),
            toggleRow("ALWAYS RUN", GameSettings.shared.autorun, #selector(autorunToggled(_:))),
            sectionRow("LENS EFFECTS"),
            toggleRow("DEPTH OF FIELD", GameSettings.shared.lensDoF, #selector(lensDoFToggled(_:))),
            toggleRow("ANAMORPHIC", GameSettings.shared.lensAnamorphic, #selector(lensAnamorphicToggled(_:))),
            captionRow("Optical effects on the visor. Both off by default."),
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

        // The rows live in a scroller so that a sheet capped by the rule below scrolls
        // instead of clipping. On any ordinary display the content fits and the scroller
        // is invisible; on a small one it is the difference between a reachable Done
        // button and a sheet with its bottom rows cut off.
        let scroller = NSScrollView()
        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.hasVerticalScroller = true
        scroller.drawsBackground = false
        scroller.autohidesScrollers = true
        scroller.documentView = rows

        let content = NSView()
        sheet.contentView = content
        content.addSubview(scroller)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroller.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            scroller.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            scroller.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            rows.topAnchor.constraint(equalTo: scroller.contentView.topAnchor),
            rows.leadingAnchor.constraint(equalTo: scroller.contentView.leadingAnchor),
            // Completes the vertical chain, which is what makes `fittingSize` meaningful:
            // without a link from the rows to the buttons the content view had no height
            // of its own and could only ever be told one.
            buttons.topAnchor.constraint(equalTo: scroller.bottomAnchor, constant: 18),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])
        sizeToContent(rows: rows, buttons: buttons)
        updateValues()
    }

    /// Size the sheet to what it contains, floored and capped.
    ///
    /// Mirrors the suite's settings-window rule (`JorvikKit/JorvikSettingsView`): grow or
    /// shrink to the content, never below a floor worth looking at, never above a fraction
    /// of the display it opens on. Citadel keeps its own copy because this sheet is
    /// programmatic AppKit in the game's monospaced face rather than the shared SwiftUI
    /// shell — the numbers are shared, the widget tree is not.
    private func sizeToContent(rows: NSStackView, buttons: NSStackView) {
        rows.layoutSubtreeIfNeeded()
        let rowsSize = rows.fittingSize
        let buttonsSize = buttons.fittingSize

        // Insets from the constraints above, kept in one expression so a change there is
        // visible here rather than silently making the sheet the wrong size.
        let wanted = NSSize(width: 24 + max(rowsSize.width, buttonsSize.width) + 20,
                            height: 20 + rowsSize.height + 18 + buttonsSize.height + 16)

        // The sheet's own title bar comes out of the height budget: `setContentSize` takes
        // a CONTENT height and the chrome is added on top, so counting it twice would let
        // the sheet exceed the cap by exactly the height of its own title bar.
        let chrome = NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled]).height
        let visible = (parent?.screen ?? NSScreen.main)?.visibleFrame.size ?? Metrics.assumedScreenSize
        let floor = Metrics.minContentSize
        // `max(..., floor)` on each ceiling, so a display too small for the floor gives the
        // floor rather than an inverted range.
        let ceilingW = max(visible.width * Metrics.maxDisplayFraction, floor.width)
        let ceilingH = max(visible.height * Metrics.maxDisplayFraction - chrome, floor.height)

        sheet.setContentSize(NSSize(width: min(max(wanted.width, floor.width), ceilingW),
                                    height: min(max(wanted.height, floor.height), ceilingH)))
    }

    /// Shared with `JorvikKit/JorvikSettingsView`'s `JorvikSettingsMetrics`. If those
    /// change, change these — they describe one house rule, not two.
    private enum Metrics {
        /// The smallest the sheet gets, however little it contains.
        static let minContentSize = NSSize(width: 420, height: 400)
        /// The most of a display's visible area it may take. A fraction rather than a
        /// fixed inset, because one inset cannot suit a laptop panel and a 27-inch alike.
        static let maxDisplayFraction: CGFloat = 0.80
        /// Fallback when there is no screen to measure.
        static let assumedScreenSize = NSSize(width: 1200, height: 900)
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

    /// Secondary explanatory line under a control, for the settings whose *names* do not
    /// carry their meaning. The suite's SwiftUI sheets use caption + secondary colour for
    /// this; the same idea in the game's monospaced face.
    private func captionRow(_ text: String) -> NSStackView {
        let label = NSTextField(labelWithString: text)
        label.font = mono(10)
        label.textColor = .secondaryLabelColor
        let row = NSStackView(views: [label])
        row.orientation = .horizontal
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
