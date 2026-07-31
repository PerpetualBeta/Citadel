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

// ── Test / capture harness — dev builds only ──────────────────────────────────
// The entire CITADEL_* env-var dispatch below is compiled ONLY into local / ad-hoc
// builds: release.mk defines CITADEL_HARNESS when SIGN_ID is the ad-hoc "-", and
// omits it for a signed, notarised release. So a shipped Citadel ignores every
// CITADEL_* variable and goes straight to the game window. The harness TYPES stay
// compiled (Captures is load-bearing for the renderer); only these entry points
// are gated out of release.
#if CITADEL_HARNESS

// EVERY harness run is hard-muted before the first AudioEngine can exist:
// CITADEL_MUTE stops the engine from ever opening the output device, so a
// harness is PHYSICALLY incapable of sound — volume-0 approaches proved
// fragile (a forgotten node, an init race, a device-open pop all leak).
// CITADEL_AUDIOPROBE is exempt by construction: it renders offline.
for key in ["CITADEL_SMOKE", "CITADEL_TIMING",
            "CITADEL_SHOTS", "CITADEL_MATERIALS",
            "CITADEL_AUTOMAP", "CITADEL_ROOMS", "CITADEL_DISPLAYVID",
            "CITADEL_TITLESHOT", "CITADEL_ENDINGSHOT", "CITADEL_QUEENMESH",
            "CITADEL_MESHVERIFY", "CITADEL_DRONEMESH", "CITADEL_COLONISTMESH", "CITADEL_CORPSES", "CITADEL_DECKCHECK", "CITADEL_TERMSHOT", "CITADEL_PROOFROOM", "CITADEL_RASTERSHOT",
            "CITADEL_CREATUREPROBE", "CITADEL_GPUPROBE"]
    where ProcessInfo.processInfo.environment[key] != nil {
    setenv("CITADEL_MUTE", "1", 1)
    break
}

if ProcessInfo.processInfo.environment["CITADEL_SMOKE"] != nil {
    SmokeTest.run()
    exit(0)
}

// CITADEL_AUDIOPROBE=1 → offline-render the real audio graph and print RMS
// measurements for the paths under suspicion. Silent; diagnostic only.
if ProcessInfo.processInfo.environment["CITADEL_AUDIOPROBE"] != nil {
    AudioProbe.run()
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
    var gpu: RasterRenderer!
    timed("RasterRenderer init (shader compile)") { gpu = RasterRenderer(device: MTLCreateSystemDefaultDevice()!) }
    var ride: World!
    timed("liftRideShaft (the ride world)") { ride = World.liftRideShaft() }
    let c = Canvas2D()
    timed("first ride frame (prepare + dispatch + readback)") { _ = gpu.render(ride, into: c) }
    timed("second ride frame (steady state)") { _ = gpu.render(ride, into: c) }
    var w1: World!
    timed("World(level:1) generation (the hidden build)") { w1 = World(level: 1, colonyIndex: 0, seed: 12345) }
    timed("first real-world frame (level mesh + textures)") { _ = gpu.render(w1, into: c) }
    timed("Sprites.shared bake (first access)") { _ = Sprites.shared.item(.medkit) }
    timed("first HUD draw") { HUD().draw(w1, into: c) }
    exit(0)
}

if let dir = ProcessInfo.processInfo.environment["CITADEL_SHOTS"] {
    Captures.run(outDir: dir)
    exit(0)
}

if ProcessInfo.processInfo.environment["CITADEL_MATERIALS"] != nil {
    MaterialPreview.run()
    exit(0)
}


// CITADEL_QUEENMESH[=mesh.usdz] → rasterise the 3D queen mesh into the live lair
// (matched pinhole + perp-depth composite + per-pixel lighting), to judge 3D.
if let v = ProcessInfo.processInfo.environment["CITADEL_QUEENMESH"] {
    QueenMeshTest.run(meshPath: (v.isEmpty || v == "1") ? nil : v, outDir: nil)
    exit(0)
}

// CITADEL_MESHVERIFY → drive the REAL live renderer with a queen in view + dump
// one frame, to verify the in-game mesh-Queen wire-in headlessly.
if ProcessInfo.processInfo.environment["CITADEL_MESHVERIFY"] != nil {
    QueenMeshTest.verifyLive(outDir: nil)
    exit(0)
}

// CITADEL_DRONEMESH → look-test the DRONE mesh in the lair (4 facings), like QUEENMESH.
if ProcessInfo.processInfo.environment["CITADEL_DRONEMESH"] != nil {
    let m = Bundle.main.url(forResource: "drone", withExtension: "usdz")?.path
    let t = Bundle.main.url(forResource: "drone_basecolor", withExtension: "jpg")?.path
    QueenMeshTest.run(meshPath: m, texPath: t, height: 1.4, tag: "drone-lair", outDir: nil)
    exit(0)
}

// CITADEL_COLONISTMESH[=mesh.usdz] → load-test a fallen-colonist mesh in the lair
// (4 facings), like DRONEMESH. Tex via CITADEL_COLONISTTEX, out via CITADEL_COLONISTOUT.
// Confirms an updated/rigged mesh LOADS (bind-pose geometry) and shows its pose.
if let v = ProcessInfo.processInfo.environment["CITADEL_COLONISTMESH"] {
    let env = ProcessInfo.processInfo.environment
    let m = (v.isEmpty || v == "1") ? Bundle.main.url(forResource: "colonist_woman", withExtension: "usdz")?.path : v
    let t = env["CITADEL_COLONISTTEX"] ?? Bundle.main.url(forResource: "colonist_woman_basecolor", withExtension: "jpg")?.path
    QueenMeshTest.run(meshPath: m, texPath: t, height: 1.75, tag: "colonist", outDir: env["CITADEL_COLONISTOUT"])
    exit(0)
}

// CITADEL_CORPSES → drive the live renderer at each fallen colonist in a generated
// level (procedural-topple pose check). Out via CITADEL_COLONISTOUT.
if ProcessInfo.processInfo.environment["CITADEL_CORPSES"] != nil {
    QueenMeshTest.verifyColonists(outDir: ProcessInfo.processInfo.environment["CITADEL_COLONISTOUT"])
    exit(0)
}

// CITADEL_RIGPROBE[=mesh.usdz] → print the skeleton + skin-weight data ModelIO
// exposes from a rigged USDZ (groundwork for the humanoid poser).
if let v = ProcessInfo.processInfo.environment["CITADEL_RIGPROBE"] {
    RigProbe.run(path: (v.isEmpty || v == "1") ? nil : v)
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

if let v = ProcessInfo.processInfo.environment["CITADEL_PROOFROOM"] {
    ProofRoom.run(outDir: v.isEmpty || v == "1" ? nil : v)
    exit(0)
}

if let v = ProcessInfo.processInfo.environment["CITADEL_RASTERSHOT"] {
    RasterRenderer.shot(outDir: v.isEmpty || v == "1" ? nil : v)
    exit(0)
}

// CITADEL_CREATUREPROBE[=dir] → render the same creature scenes through BOTH merge paths
// (GPU-direct vs the legacy CPU read-back) and diff the pixels. Proves the merge rewrite
// faithful and prints the speed-up.
// CITADEL_GPUPROBE → decompose the GPU frame by subtraction (light loop, vertex load,
// fire pass), answering what the frame log could only correlate.
if ProcessInfo.processInfo.environment["CITADEL_GPUPROBE"] != nil {
    GPUProbe.run()
    exit(0)
}

if let v = ProcessInfo.processInfo.environment["CITADEL_CREATUREPROBE"] {
    CreatureMergeProbe.run(outDir: v.isEmpty || v == "1" ? nil : v)
    exit(0)
}

// CITADEL_SETTLEPROBE → sweep the mesh-settle solver's inputs finely and report the largest
// jump its output takes, i.e. whether a drawn body can teleport. No GUI.
if ProcessInfo.processInfo.environment["CITADEL_SETTLEPROBE"] != nil {
    SettleProbe.run()
    exit(0)
}

// CITADEL_DORMDEBUG → dump a few generated levels as ASCII (walls #, doors +, floor ·,
// bunk B, locker L, column I, desk d, chair c, tape T, papers p, pipe =) to eyeball the
// dormitory layout algorithm (row alternation, centre rows, columns, clear aisles). No GUI.
if ProcessInfo.processInfo.environment["CITADEL_DORMDEBUG"] != nil {
    for lvl in [1, 2, 3, 4, 7, 8] {
        let g = MapGen.generate(level: lvl, colonyIndex: 0, seed: UInt64(lvl &* 2654435761 &+ 12345))
        let m = g.map
        var grid = [[Character]](repeating: [Character](repeating: " ", count: m.w), count: m.h)
        for y in 0..<m.h { for x in 0..<m.w {
            let i = m.idx(x, y)
            grid[y][x] = m.wall[i] != 0 ? (m.doors[i] != nil ? "+" : "#") : "·"
        } }
        for pr in g.props {
            let x = Int(pr.pos.x), y = Int(pr.pos.y)
            guard x >= 0, y >= 0, y < m.h, x < m.w else { continue }
            switch pr.kind {
            case .bunk: grid[y][x] = "B"; case .locker: grid[y][x] = "L"; case .column: grid[y][x] = "I"
            case .desk: grid[y][x] = "d"; case .chair: grid[y][x] = "c"; case .tapeDeck: grid[y][x] = "T"
            case .papers: grid[y][x] = "p"; case .wallPipe: grid[y][x] = "="
            case .console: grid[y][x] = "O"
            case .cabinet: grid[y][x] = "n"; case .sink: grid[y][x] = "s"
            case .range: grid[y][x] = "R"; case .canteenTable: grid[y][x] = "t"
            case .washTrough: grid[y][x] = "w"; case .shower: grid[y][x] = "h"; case .cubicle: grid[y][x] = "u"
            case .machineFilter: grid[y][x] = "F"; case .machineColumn: grid[y][x] = "V"
            case .machineCompressor: grid[y][x] = "K"; case .machineSwitchgear: grid[y][x] = "e"
            }
        }
        let boardCells = (0..<(m.w * m.h)).filter { m.wall[$0] == WallTex.opsBoard.rawValue }.count
        let medCells = (0..<(m.w * m.h)).filter { m.wall[$0] == WallTex.medWall.rawValue }.count
        let beds = g.props.filter { $0.kind == .bunk }.count
        let stainless = g.props.filter { $0.kind == .cabinet || $0.kind == .sink }.count
        let tiles = (0..<(m.w * m.h)).filter { m.wall[$0] == WallTex.subwayTile.rawValue }.count
        let tables = g.props.filter { $0.kind == .canteenTable }.count
        let ranges = g.props.filter { $0.kind == .range }.count
        let sanTiles = (0..<(m.w * m.h)).filter { m.wall[$0] == WallTex.sanTile.rawValue }.count
        let sanFit = g.props.filter { $0.kind == .washTrough || $0.kind == .shower || $0.kind == .cubicle }.count
        let consoles = g.props.filter { $0.kind == .console }.count
        print("=== LEVEL \(lvl)  \(m.w)x\(m.h)  rooms=\(MapGen.debugRoomCount)  props=\(g.props.count) items=\(g.items.count) drums=\(g.drums.count) opsRoom=\(MapGen.debugOpsRoom) board=\(boardCells) consoles=\(consoles) medWalls=\(medCells) beds=\(beds) stainless=\(stainless) tiles=\(tiles) tables=\(tables) range=\(ranges) sanTiles=\(sanTiles) sanFit=\(sanFit) ===")
        print("    rooms (w×h, biggest first): " + MapGen.debugRoomDims.map { "\($0.0)×\($0.1)" }.joined(separator: " "))
        for row in grid { print(String(row)) }
        print("")
    }
    exit(0)
}

if let v = ProcessInfo.processInfo.environment["CITADEL_DISPLAYVID"] {
    let fault = v.hasPrefix("fault")                          // "fault" or "fault:<dir>" stages an electrical fault mid-clip
    let path = v.hasPrefix("fault:") ? String(v.dropFirst(6))
             : (v.isEmpty || v == "1" || v == "fault" ? nil : v)
    DisplayVid.run(outDir: path, fault: fault)
    exit(0)
}

// CITADEL_TITLESHOT[=path] → render the title screen to a PNG (default ~/Desktop),
// then exit. A no-window way to preview the front-end art without launching.
if let v = ProcessInfo.processInfo.environment["CITADEL_TITLESHOT"] {
    let out = (v.isEmpty || v == "1") ? NSHomeDirectory() + "/Desktop/citadel-title.png" : v
    let c = Canvas2D()
    FrontEnd.title(c, t: 3.0, hs: HighScores(), pad: false)
    Captures.writePNG(c.framebuffer, w: RenderConfig.width, h: RenderConfig.height, scale: 1,
                      to: URL(fileURLWithPath: out))
    print("Citadel: wrote title screenshot to \(out)")
    exit(0)
}

// CITADEL_ENDINGSHOT[=dir] → render the WHOLE ending ceremony to a PNG sequence (default
// ~/Desktop/citadel-ending), then exit. CITADEL_ENDINGFPS sets the rate (default 30).
//
// This exists because the ending is reached exactly once, by clearing every floor of every
// citadel — so no play-test will ever arrive there, and it is the one screen in the game that
// could break and stay broken for years with nobody in a position to notice. Rendering it
// headlessly makes it reviewable (pipe the frames through ffmpeg to watch it) and, via the shot
// harness, guarded by shotcheck like everything else.
if let v = ProcessInfo.processInfo.environment["CITADEL_ENDINGSHOT"] {
    let dir = (v.isEmpty || v == "1") ? NSHomeDirectory() + "/Desktop/citadel-ending" : v
    let fps = Float(ProcessInfo.processInfo.environment["CITADEL_ENDINGFPS"] ?? "") ?? 30
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    guard EndingArt.available else {
        print("Citadel: no ending plate (Resources/ending_bg.png) — nothing to render")
        exit(1)
    }
    // The WHOLE ending, not just the ceremony: the run to black, and the coda that holds after it.
    // Those two are the parts nobody can see any other way — the ceremony at least has still frames
    // in the shot harness, while the fade and the last card only exist in motion.
    let fadeOut = Renderer.codaFadeOut
    let codaHold = FrontEnd.codaIn + 3.5          // the line arrives, then sits, as it will in game
    let total = EndingArt.duration + fadeOut + codaHold
    let frames = Int((total * fps).rounded())
    let c = Canvas2D()
    // The soundtrack's gain table goes out beside the frames, so a preview cut can be mixed from
    // the SAME numbers the engine plays rather than from a hand-copy of them — the whole point of a
    // preview being that it is trustworthy. Every column is already multiplied by its per-sound
    // trim, its bus, and the transition duck, so the mixer needs no knowledge of any of it.
    var csv = "t,bed,cheer,chant,music\n"
    let ambBus = GameSettings.shared.ambientVolume, musBus = GameSettings.shared.musicVolume
    for i in 0..<frames {
        let t = Float(i) / fps
        let intoFade = t - EndingArt.duration
        // duck and veil are the same curve the renderer's transition runs
        let veil: Float = intoFade <= 0 ? 0 : min(1, max(0, intoFade / fadeOut))
        let eased = veil * veil * (3 - 2 * veil)
        if intoFade < fadeOut {
            // the ceremony keeps running under the rising veil — the shot is still travelling when
            // the black takes it, exactly as it is at every other cut in the sequence
            FrontEnd.ending(c, t: t)
            if eased > 0.002 {
                c.fillRectBlend(0, 0, RenderConfig.width, RenderConfig.height, packRGBA(0, 0, 0), eased)
            }
        } else {
            FrontEnd.coda(c, t: intoFade - fadeOut)
        }
        Captures.writePNG(c.framebuffer, w: RenderConfig.width, h: RenderConfig.height, scale: 1,
                          to: URL(fileURLWithPath: dir + String(format: "/f%05d.png", i)))
        let duck = intoFade < fadeOut ? 1 - eased : 0     // the coda is silent: the stems are stopped
        let g = EndingArt.crowd(at: t)
        csv += String(format: "%.4f,%.5f,%.5f,%.5f,%.5f\n", t,
                      g.bed * AudioEngine.Sound.crowdBed.gain * ambBus * duck,
                      g.cheer * AudioEngine.Sound.crowdCheer.gain * ambBus * duck,
                      g.chant * AudioEngine.Sound.crowdChant.gain * ambBus * duck, musBus * duck)
    }
    try? csv.write(to: URL(fileURLWithPath: dir + "/crowd.csv"), atomically: true, encoding: .utf8)
    print("Citadel: wrote \(frames) frames + crowd.csv — ceremony \(String(format: "%.1f", EndingArt.duration))s "
          + "+ fade \(String(format: "%.1f", fadeOut))s + coda \(String(format: "%.1f", codaHold))s @ \(Int(fps))fps to \(dir)")
    exit(0)
}

// CITADEL_DECKCHECK → print how many SIGNAL decks each floor gets (verify the
// rarity: 1–2 per building, floors 1–5 only, none on 6–8).
if ProcessInfo.processInfo.environment["CITADEL_DECKCHECK"] != nil {
    for base in [UInt64(1000), 2000, 3000] {
        var deckLine = "base \(base) decks:", paperLine = "base \(base) papers:"
        for level in 1...8 {
            let w = World(level: level, colonyIndex: Progression.planetIndex(level), seed: base &+ UInt64(level))
            deckLine += " L\(level)=\(w.props.filter { $0.kind == .tapeDeck }.count)"
            let pProps = w.props.filter { $0.kind == .papers }.count
            let pDecals = w.decals.filter { $0.w > 3.0 }.count       // papers render as w>3 decals (buildAftermath)
            paperLine += " L\(level)=\(pProps)prop/\(pDecals)decal"
        }
        print(deckLine); print(paperLine)
    }
    exit(0)
}

// CITADEL_TERMSHOT[=dir] → render each terminal easter egg + the guru meditation
// to PNGs (default ~/Desktop), then exit. Previews the amber CRT without playing.
if let v = ProcessInfo.processInfo.environment["CITADEL_TERMSHOT"] {
    let dir = (v.isEmpty || v == "1") ? NSHomeDirectory() + "/Desktop" : v
    func write(_ c: Canvas2D, _ name: String) {
        Captures.writePNG(c.framebuffer, w: RenderConfig.width, h: RenderConfig.height, scale: 1,
                          to: URL(fileURLWithPath: dir + "/\(name).png"))
    }
    func shot(_ egg: TerminalEgg?, _ name: String, page: Int = 0, _ t: Float) {
        let c = Canvas2D()
        c.fillRect(0, 0, c.width, c.height, packRGBA(34, 38, 44))   // stand-in room behind the terminal
        Terminal.draw(c, egg: egg, page: page, scale: 1, t: t)
        write(c, name)
    }
    // the text eggs (page 1) + guru (skip the mini-game — it draws itself, below)
    for (i, egg) in TerminalEgg.all.enumerated() where egg.kind != .miniGame { shot(egg, "term-\(i)", 0.3) }
    shot(nil, "term-guru", 0.0)
    // a later Director's Log page — shows the ◀ PAGE n / N ▶ paging footer
    shot(TerminalEgg.all[0], "term-log-p2", page: 2, 0.3)
    // the arcade mini-game — three staged states, in the same CRT
    ArcadeScores.shared.harnessSeed([
        ArcadeEntry(name: "ARC", score: 4820), ArcadeEntry(name: "JON", score: 3260),
        ArcadeEntry(name: "CPL", score: 2140), ArcadeEntry(name: "MUM", score: 1780),
        ArcadeEntry(name: "DAD", score: 990),
    ])
    func shotGame(_ name: String, _ t: Float, _ setup: (SpaceInvaders) -> Void) {
        let c = Canvas2D()
        c.fillRect(0, 0, c.width, c.height, packRGBA(34, 38, 44))
        let g = SpaceInvaders(); setup(g)
        let f = Terminal.frame(c, scale: 1, t: t, guru: false)
        g.draw(c, f.x0, f.y0, f.sw, f.sh, a: 1, t: t)
        write(c, name)
    }
    shotGame("inv-play", 0.2) { $0.harnessMidPlay() }
    shotGame("inv-initials", 0.2) { $0.harnessInitials(score: 3260) }
    shotGame("inv-scores", 0.2) { $0.harnessScoreboard() }
    print("Citadel: wrote terminal shots + guru + 3 arcade frames to \(dir)")
    exit(0)
}

#endif  // CITADEL_HARNESS

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
