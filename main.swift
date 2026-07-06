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
import Metal
import QuartzCore

if ProcessInfo.processInfo.environment["CITADEL_SMOKE"] != nil {
    SmokeTest.run()
    exit(0)
}

// CITADEL_TIMING=1 → print where the fire-press → first-gameplay-frame time
// actually goes (ride world, first GPU frame, level generation, sprite bake),
// then exit. Diagnostic only.
if ProcessInfo.processInfo.environment["CITADEL_TIMING"] != nil {
    func timed(_ label: String, _ body: () -> Void) {
        let t0 = CACurrentMediaTime()
        body()
        print(String(format: "  %-46s %6.0f ms", (label as NSString).utf8String!, (CACurrentMediaTime() - t0) * 1000))
    }
    print("Citadel timing")
    var gpu: GPUWorldRenderer!
    timed("GPUWorldRenderer init (kernel compile)") { gpu = GPUWorldRenderer(device: MTLCreateSystemDefaultDevice()!) }
    timed("prewarm (procedural texture bake + upload)") { gpu.prewarm() }
    var ride: World!
    timed("liftRideShaft (the ride world)") { ride = World.liftRideShaft() }
    let c = Canvas2D()
    timed("first ride frame (prepare + dispatch + readback)") { _ = gpu.render(ride, into: c) }
    timed("second ride frame (steady state)") { _ = gpu.render(ride, into: c) }
    var w1: World!
    timed("World(level:1) generation (the hidden build)") { w1 = World(level: 1, colonyIndex: 0, seed: 12345) }
    timed("first real-world frame (SDF field + textures)") { _ = gpu.render(w1, into: c) }
    timed("Sprites.shared bake (first access)") { _ = Sprites.shared.weaponFrames(.plasma) }
    timed("first HUD draw") { HUD().draw(w1, into: c) }
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

if let v = ProcessInfo.processInfo.environment["CITADEL_ROOMS"] {
    RoomShots.run(outDir: v.isEmpty || v == "1" ? nil : v)
    exit(0)
}

// Single-instance guard. Two live copies each sphere-trace the scene and contend
// for the GPU + the per-frame readback — enough stacked instances will drag the
// whole machine to a beachball (a real hazard during rapid dev relaunches). If
// another Citadel is already running, hand focus to it and bow out. Headless
// modes (smoke / captures) have already exited above, so this only gates the GUI.
if let bundleID = Bundle.main.bundleIdentifier {
    let mine = NSRunningApplication.current.processIdentifier
    let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .first { $0.processIdentifier != mine }
    if let other {
        other.activate()
        exit(0)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
