// Citadel — entry point.
//
// Three launch paths:
//   • CITADEL_SMOKE=1   → headless smoke test (map solvability, AI/combat/
//     scoring/persistence, the framebuffer draws, a best-effort GPU render),
//     then exit. Runs from a shell / CI with no window.
//   • CITADEL_SHOTS[=dir] → render the doc/marketing screenshots headlessly via
//     the real draw path, then exit.
//   • otherwise → bring up the Cocoa app and the Metal-backed game window.

import Cocoa

if ProcessInfo.processInfo.environment["CITADEL_SMOKE"] != nil {
    SmokeTest.run()
    exit(0)
}

if let dir = ProcessInfo.processInfo.environment["CITADEL_SHOTS"] {
    Captures.run(outDir: dir)
    exit(0)
}

if let v = ProcessInfo.processInfo.environment["CITADEL_ARTPREVIEW"] {
    ArtPreview.run(outDir: v.isEmpty || v == "1" ? nil : v)
    exit(0)
}

if let v = ProcessInfo.processInfo.environment["CITADEL_CREATURES"] {
    CreatureLab.run(gif: v == "gif")
    exit(0)
}

if ProcessInfo.processInfo.environment["CITADEL_MATERIALS"] != nil {
    MaterialPreview.run()
    exit(0)
}

if let v = ProcessInfo.processInfo.environment["CITADEL_LIGHT"] {
    LightPreview.run(outDir: v.isEmpty || v == "1" ? nil : v)
    exit(0)
}

if let v = ProcessInfo.processInfo.environment["CITADEL_BEAUTY"] {
    BeautyProof.run(outDir: v.isEmpty || v == "1" ? nil : v)
    exit(0)
}

if let v = ProcessInfo.processInfo.environment["CITADEL_GPU"] {
    GPURaymarch.run(outDir: v.isEmpty || v == "1" ? nil : v)
    exit(0)
}

if let v = ProcessInfo.processInfo.environment["CITADEL_AUTOMAP"] {
    Automap.run(outDir: v.isEmpty || v == "1" ? nil : v)
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
