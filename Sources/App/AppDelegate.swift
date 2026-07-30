// Citadel — app delegate: window, menu bar, About, Sparkle, input wiring.
//
// Opens a single maximised Metal window, builds the menu bar in code, owns the
// renderer + audio + input, and routes the configuration sheets. Sparkle drives
// in-app updates with the canonical Jorvik focus-guard so the update dialog
// comes to the front from a borderless game window.

import Cocoa
import MetalKit
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private var view: GameView!
    private var renderer: Renderer!
    // held so validateMenuItem can grey them out when there is nothing to save or nothing to load
    private var saveItem: NSMenuItem?
    private var loadItem: NSMenuItem?
    private var gamepad: Gamepad!
    private let input = InputState()
    private let audio = AudioEngine()
    private let highScores = HighScores()

    private let userDriverDelegate = CitadelUserDriverDelegate()
    // Sparkle is OFF by default during development — the appcast isn't published
    // yet, so the automatic startup check throws a "missing feed" dialog. Opt in
    // per machine:  defaults write cc.jorviksoftware.Citadel Updater -bool true
    private var updater: SPUStandardUpdaterController?
    private func makeUpdater() -> SPUStandardUpdaterController {
        SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: userDriverDelegate)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Citadel requires a Metal-capable Mac.")
        }

        let screenFrame = (NSScreen.main?.visibleFrame) ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        window = NSWindow(contentRect: screenFrame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Citadel"
        window.collectionBehavior = [.fullScreenPrimary]
        window.acceptsMouseMovedEvents = true
        window.backgroundColor = .black

        gamepad = Gamepad()
        view = GameView(frame: screenFrame, device: device, input: input)
        view.gamepad = gamepad
        renderer = Renderer(device: device, view: view, input: input, gamepad: gamepad,
                            audio: audio, highScores: highScores)
        view.delegate = renderer

        view.onOpenKeyboard = { [weak self] in self?.openKeyboard() }
        view.onOpenController = { [weak self] in self?.openController() }
        view.onOpenSettings = { [weak self] in self?.openSettings() }

        window.contentView = view
        window.makeFirstResponder(view)
        window.setFrame(screenFrame, display: true)
        window.makeKeyAndOrderFront(nil)
        window.delegate = self                              // for miniaturise → pause

        installMenu()
        if FeatureFlags.updater { updater = makeUpdater() }   // auto-check only when opted in
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // ── lifecycle: idle the game + audio when Citadel isn't on screen ──────────
    // Stop the render/sim loop (MTKView.isPaused) and pause the audio engine
    // whenever the app is inactive (backgrounded / hidden / Cmd-tabbed away) or the
    // window is miniaturised — no fans spinning and no sound from a window you can't
    // see. The sim's dt is clamped (Renderer), so the first resumed frame can't jump.
    func applicationDidResignActive(_ n: Notification)     { updateRunState() }
    func applicationDidBecomeActive(_ n: Notification)     { updateRunState() }
    func windowDidMiniaturize(_ n: Notification)           { updateRunState() }
    func windowDidDeminiaturize(_ n: Notification)         { updateRunState() }

    private func updateRunState() {
        guard let view = view else { return }
        // Run only when actually on screen. isActive + isMiniaturized are synchronous
        // and reliable (unlike occlusionState, which is racy at launch).
        let hidden = !NSApp.isActive || (window?.isMiniaturized ?? false)
        view.isPaused = hidden
        if hidden { audio.suspend() } else { audio.resume() }
    }

    // ── menu ─────────────────────────────────────────────────────────────────

    private func installMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu

        let about = NSMenuItem(title: "About Citadel", action: #selector(showAbout), keyEquivalent: "")
        about.target = self; appMenu.addItem(about)
        appMenu.addItem(.separator())

        let scores = NSMenuItem(title: "Hall of the Fallen", action: #selector(viewHighScores), keyEquivalent: "")
        scores.target = self; appMenu.addItem(scores)
        appMenu.addItem(.separator())

        // SAVE / LOAD live here and ONLY here. The front-end screens are composed to the pixel and a
        // SAVE prompt bolted onto them would cost more than it bought; a Mac player looks in the menu
        // first anyway. ⌘S / ⌘O go through the menu, so they can never collide with a movement key.
        saveItem = NSMenuItem(title: "Save Game…", action: #selector(saveGame), keyEquivalent: "s")
        saveItem?.target = self; appMenu.addItem(saveItem!)
        loadItem = NSMenuItem(title: "Load Game…", action: #selector(loadGame), keyEquivalent: "o")
        loadItem?.target = self; appMenu.addItem(loadItem!)
        appMenu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self; appMenu.addItem(settings)
        let kb = NSMenuItem(title: "Keyboard Setup…", action: #selector(openKeyboard), keyEquivalent: "")
        kb.target = self; appMenu.addItem(kb)
        let ctl = NSMenuItem(title: "Controller Setup…", action: #selector(openController), keyEquivalent: "")
        ctl.target = self; appMenu.addItem(ctl)
        appMenu.addItem(.separator())

        let upd = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        upd.target = self; appMenu.addItem(upd)
        appMenu.addItem(.separator())

        appMenu.addItem(NSMenuItem(title: "Hide Citadel", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Quit Citadel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let winItem = NSMenuItem()
        mainMenu.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winItem.submenu = winMenu
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let fs = winMenu.addItem(withTitle: "Enter Full Screen",
                                 action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = winMenu
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Citadel",
            .applicationVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1",
            .credits: NSAttributedString(
                string: "A first-person retake of the occupied colonies — set in the Strataris universe. Procedural citadels, descended floor by floor.\n\nA Jorvik Software game.",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]),
        ])
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        if updater == nil { updater = makeUpdater() }   // create on demand for a manual check
        updater?.checkForUpdates(sender)
    }

    @objc private func openSettings() {
        guard let win = window, !gamepad.configuring else { return }
        OptionsSheet.present(over: win, audio: audio, gamepad: gamepad, highScores: highScores)
    }
    @objc private func viewHighScores() {
        renderer.viewHighScores()
        window?.makeFirstResponder(view)                    // return focus so [FIRE]/[ESC] dismiss it
    }

    // ── save / load ───────────────────────────────────────────────────────────
    //
    // Native sheets, because this is a Mac app and because the game screens are not going to grow a
    // save browser. Both PAUSE the run first: a modal spins its own run loop, and a game that keeps
    // advancing behind a dialog is a game that can kill you while you type a slot name.

    /// Grey the items out when they cannot do anything, rather than letting them fail with an alert.
    /// Conformed to `NSMenuItemValidation` rather than left to the informal protocol, so the call is
    /// guaranteed: relying on ObjC seeing a Swift method is how a menu item silently stays enabled.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item == saveItem { return renderer?.savableCheckpoint != nil }
        if item == loadItem { return !(renderer?.saves.isEmpty ?? true) }
        return true
    }

    @objc private func saveGame() {
        guard let renderer, let c = renderer.savableCheckpoint else { return }
        renderer.pauseForDialog()
        let a = NSAlert()
        a.messageText = "Save Game"
        a.informativeText = "Saving records the start of FLOOR \(c.level), \(c.colonyName) — \(c.score) points. "
                          + "Restoring rides the lift back down to it."
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 30, width: 320, height: 24), pullsDown: false)
        for i in 0..<SaveGames.slotCount {
            let s = renderer.saves.slots[i]
            picker.addItem(withTitle: "\(i + 1).  " + (s.map { $0.summary } ?? "— empty —"))
        }
        // default to the first empty slot, so the common case never overwrites by accident
        picker.selectItem(at: renderer.saves.slots.firstIndex(where: { $0 == nil }) ?? 0)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Name this save"
        field.stringValue = "FLOOR \(c.level), \(c.colonyName)"
        box.addSubview(picker); box.addSubview(field)
        a.accessoryView = box
        a.window.initialFirstResponder = field

        if a.runModal() == .alertFirstButtonReturn {
            renderer.saveRun(named: field.stringValue, to: picker.indexOfSelectedItem)
        }
        window?.makeFirstResponder(view)
    }

    @objc private func loadGame() {
        guard let renderer, !renderer.saves.isEmpty else { return }
        renderer.pauseForDialog()
        let used = renderer.saves.used
        let a = NSAlert()
        a.messageText = "Load Game"
        a.informativeText = renderer.world != nil
            ? "The run in progress will be abandoned."
            : "Resume from a saved checkpoint."
        a.addButton(withTitle: "Load"); a.addButton(withTitle: "Cancel")

        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 24), pullsDown: false)
        for (i, s) in used { picker.addItem(withTitle: "\(i + 1).  \(s.summary)") }
        a.accessoryView = picker
        a.window.initialFirstResponder = picker

        if a.runModal() == .alertFirstButtonReturn {
            let pick = picker.indexOfSelectedItem
            if pick >= 0, pick < used.count { renderer.restoreRun(used[pick].slot) }
        }
        window?.makeFirstResponder(view)
    }
    @objc private func openKeyboard() {
        guard let win = window, !gamepad.configuring else { return }
        KeyboardSheet.present(over: win, gamepad: gamepad)
    }
    @objc private func openController() {
        guard let win = window, !gamepad.configuring else { return }
        ControllerSheet.present(over: win, gamepad: gamepad)
    }
}

/// Brings Citadel to the front when Sparkle wants to show update UI, and keeps
/// it there for the duration of the update session (the canonical Jorvik guard).
final class CitadelUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    private var sessionObserver: NSObjectProtocol?

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        startGuard(); bringForward()
    }
    func standardUserDriverWillFinishUpdateSession() { stopGuard() }

    private func bringForward() {
        NSApp.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
    }
    private func startGuard() {
        guard sessionObserver == nil else { return }
        sessionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            self?.bringForward()
        }
    }
    private func stopGuard() {
        if let o = sessionObserver { NotificationCenter.default.removeObserver(o); sessionObserver = nil }
    }
}
