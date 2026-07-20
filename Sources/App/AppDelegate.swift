// Citadel — app delegate: window, menu bar, About, Sparkle, input wiring.
//
// Opens a single maximised Metal window, builds the menu bar in code, owns the
// renderer + audio + input, and routes the configuration sheets. Sparkle drives
// in-app updates with the canonical Jorvik focus-guard so the update dialog
// comes to the front from a borderless game window.

import Cocoa
import MetalKit
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var view: GameView!
    private var renderer: Renderer!
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

        installMenu()
        if FeatureFlags.updater { updater = makeUpdater() }   // auto-check only when opted in
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

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
                string: "A first-person retake of the occupied colonies — set in the Strataris universe. Every pixel, sprite and sound generated in code.\n\nA Jorvik Software game.",
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
