// Citadel — renderer & game-state machine.
//
// Owns the Canvas2D framebuffer, the GPU world renderer, the HUD, the front-end screens,
// audio and high scores. Each frame it polls input, advances the current
// state (title / briefing / intel / playing / paused / level-cleared /
// game-over / high-scores), draws into the framebuffer, then uploads it to a
// Metal texture and blits it nearest-neighbour, aspect-correct and letterboxed,
// to the drawable — the period-correct pixelated look.

import Cocoa
import MetalKit
import QuartzCore

enum GameState { case title, briefing, intel, riding, playing, paused, automap, teleport, gameOver, highScores }

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState!
    private var texture: MTLTexture!
    private let bytesPerRow = RenderConfig.width * 4
    private weak var view: MTKView?

    // The world's 3-D view is drawn by the GPU SDF renderer — the only renderer
    // (the CPU raycaster was removed once the GPU path reached parity).
    private var gpuWorldRenderer: GPUWorldRenderer?

    let canvas = Canvas2D()
    private let hud = HUD()
    let audio: AudioEngine
    let highScores: HighScores
    private let input: InputState
    private let gamepad: Gamepad

    private(set) var state: GameState = .title
    var world: World?
    private var baseSeed: UInt64 = 1
    private var level = 1
    private var colonyIndex = 0
    private var carry: Player?

    // ── background level generation ── every floor is built on a background
    // queue while the player is inside a transition the fiction owns: the lift
    // ride (title descent + floor-to-floor) or the teleport static (planet
    // jumps). The transitions HOLD until the world lands here, so the game
    // never stalls a frame on MapGen.
    private var pendingWorld: World?
    private var pendingLevel = 0          // absolute floor being built (0 = none)
    private var genEpoch = 0              // stale-build guard: bumped on abandon/restart
    // the title-descent ride (a hand-built shaft world, renderer-driven)
    private var rideWorld: World?
    private var rideT: Float = 0
    private var rideRumbleT: Float = 0
    // teleport arrival: static burning off the new floor's first view
    private var arrivalStatic: Float = 0
    private var staticAudioT: Float = 0
    // The raymarch kernel's FIRST dispatch pays the driver's deferred back-end
    // compile (~3 s measured; mapgen itself is ~1 ms) — the real source of the
    // old fire-press stall. It's paid at launch, off the main thread, on a
    // throwaway shaft world while the title is up; this flag gates gameplay
    // rendering so nothing races that warm-up dispatch.
    private var gpuWarm = false

    private var lastTime = CACurrentMediaTime()
    private var screenT: Float = 0
    private var deathTimer: Float = 0

    private var qualifies = false
    private var lastRank = -1

    // edge tracking
    private var pConfirm = false, pEsc = false, pBrief = false, pIntel = false
    private var pPause = false, pMute = false, pShot = false, pMap = false
    private var pausedDrawn = false        // pause freezes the frame — render it ONCE, then idle (no GPU raymarch while paused → fans don't spin on a frozen scene)

    private static let blitShaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VSOut { float4 position [[position]]; float2 uv; };
    vertex VSOut v_blit(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VSOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }
    fragment float4 f_blit(VSOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return tex.sample(s, in.uv);
    }
    """

    init(device: MTLDevice, view: MTKView, input: InputState, gamepad: Gamepad,
         audio: AudioEngine, highScores: HighScores) {
        self.device = device
        self.queue = device.makeCommandQueue()!
        self.view = view
        self.input = input
        self.gamepad = gamepad
        self.audio = audio
        self.highScores = highScores
        super.init()
        buildPipeline(view: view)
        buildTexture()
        gpuWorldRenderer = GPUWorldRenderer(device: device)
        gpuWorldRenderer?.prewarm()      // build the level-independent GPU resources now (title is up), not on the first fire-press
        warmKernel()                     // …and pay the kernel's first-dispatch compile now too
        audio.startMusic(.title)
    }

    private func buildPipeline(view: MTKView) {
        do {
            let library = try device.makeLibrary(source: Renderer.blitShaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "v_blit")
            desc.fragmentFunction = library.makeFunction(name: "f_blit")
            desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch { fatalError("Citadel: blit pipeline build failed — \(error)") }
    }

    private func buildTexture() {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: RenderConfig.width, height: RenderConfig.height, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .managed
        texture = device.makeTexture(descriptor: d)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    // ── frame ────────────────────────────────────────────────────────────────

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        var dt = Float(now - lastTime)
        lastTime = now
        if dt > 0.05 { dt = 0.05 }
        if dt < 0 { dt = 0 }

        gamepad.poll(input)
        audio.updateMusic(dt)
        (view as? GameView)?.updateMouseCapture(state == .playing)

        // global mute toggle
        if input.mute && !pMute { audio.muted.toggle() }

        screenT += dt
        switch state {
        case .title: tickTitle(dt)
        case .briefing: tickInfo(dt, FrontEnd.briefing)
        case .intel: tickInfo(dt, FrontEnd.intel)
        case .riding: tickRiding(dt)
        case .playing: tickPlaying(dt)
        case .paused: tickPaused(dt)
        case .automap: tickAutomap(dt)
        case .teleport: tickTeleport(dt)
        case .gameOver: tickGameOver(dt)
        case .highScores: tickHighScores(dt)
        }

        updateEdges()
        present(view)
    }

    private func rising(_ now: Bool, _ prev: Bool) -> Bool { now && !prev }

    private func updateEdges() {
        pConfirm = input.restart; pEsc = input.esc; pBrief = input.briefing
        pIntel = input.intel; pPause = input.pause; pMute = input.mute; pShot = input.screenshot
        pMap = input.map
    }

    // ── states ─────────────────────────────────────────────────────────────

    private func tickTitle(_ dt: Float) {
        FrontEnd.title(canvas, t: screenT, hs: highScores, pad: gamepad.connected)
        if rising(input.restart, pConfirm) { startGame() }
        else if rising(input.briefing, pBrief) { state = .briefing; screenT = 0 }
        else if rising(input.intel, pIntel) { state = .intel; screenT = 0 }
    }

    private func tickInfo(_ dt: Float, _ draw: (Canvas2D, Float) -> Void) {
        draw(canvas, screenT)
        if rising(input.esc, pEsc) || rising(input.restart, pConfirm) { state = .title; screenT = 0 }
    }

    private func tickPlaying(_ dt: Float) {
        guard let world = world else { state = .title; return }
        // The moment an exit commits (car dropping / pad charging), the next
        // floor starts building on the background queue; the transition holds
        // until it lands (holdRide keeps the car dropping past its nominal ride).
        if world.elevatorPhase == .descending || world.teleportPhase == .charging {
            let next = world.level + 1
            beginWorldBuild(level: next, seed: baseSeed &+ UInt64(next) &* 1000)
        }
        world.holdRide = pendingWorld == nil
        world.update(dt: dt, input: input, audio: audio)
        let cue = world.audioCue()       // drive the reactive ambient bed from live danger
        audio.setTension(threat: cue.threat, queen: cue.queen, health: cue.health, combat: cue.combat)
        renderWorld(world)
        hud.draw(world, into: canvas)
        if world.elevatorPhase == .awaitFire {
            FrontEnd.descendReport(canvas, world: world, t: world.elapsed)
        } else if world.teleportPhase == .await {
            FrontEnd.securedReport(canvas, world: world, t: world.elapsed)
        }
        // the teleport charge dissolves the whole visor feed — HUD and all —
        // to static; an arrival burns the static back off the new view
        if world.teleportT > 0 {
            StaticFX.overlay(canvas, coverage: world.teleportT, t: world.elapsed)
        }
        if arrivalStatic > 0 {
            arrivalStatic = max(0, arrivalStatic - dt / 0.8)
            StaticFX.overlay(canvas, coverage: arrivalStatic, t: world.elapsed)
        }

        if FeatureFlags.screenshotKey && rising(input.screenshot, pShot) { saveScreenshot() }

        if rising(input.map, pMap) { state = .automap }
        else if rising(input.pause, pPause) { state = .paused; pausedDrawn = false }
        else if world.player.dead {
            deathTimer += dt
            if deathTimer > 1.3 { enterGameOver() }
        } else if world.levelComplete {
            // The floor report + FIRE prompt already happened INSIDE the car
            // (World.awaitFire), and the ride has been ridden — so an ordinary
            // floor flows straight into the next level: the arrival car's doors
            // part as it fades in. Only the last floor of a citadel keeps its
            // interstitial: the feed is FULL STATIC now, and .teleport holds it
            // there (story card over the noise) until the next planet is ready.
            if Progression.isLastFloor(world.level) {
                state = .teleport; screenT = 0; staticAudioT = 0
                audio.stopMusic()
            } else {
                audio.stopMusic()
                nextLevel()
            }
        }
    }

    /// The title descent: "PRESS FIRE TO DESCEND" is taken literally — the run
    /// starts inside the car, riding down into the citadel while floor 1 builds
    /// on the background queue. The ride holds until the world is ready, then
    /// the cut lands inside the (identical) arrival car with the doors parting.
    private func tickRiding(_ dt: Float) {
        guard let ride = rideWorld else { state = .title; return }
        rideT += dt
        if pendingWorld == nil { rideT = min(rideT, World.rideTime - 0.5) }   // hold just before the ease-out
        ride.elapsed += dt
        let up = min(1, rideT * 2.5)
        let down = min(1, max(0, (World.rideTime - rideT) / 0.5))
        ride.rideShake = up * down
        // keep the winch + sub-bass alive for however long generation takes
        rideRumbleT -= dt
        if rideRumbleT <= 0 {
            rideRumbleT = 2.2
            audio.trigger(wave: AudioEngine.noise, f0: 1, dur: 2.4, amp: 0.22, attack: 0.4)
            audio.trigger(wave: AudioEngine.sine, f0: 48, f1: 34, dur: 2.4, amp: 0.30, attack: 0.3)
        }
        renderWorld(ride)
        FrontEnd.rideOverlay(canvas, level: level, t: ride.elapsed)
        if rideT >= World.rideTime, let w = pendingWorld {
            rideWorld = nil
            installWorld(w)
        } else if rising(input.esc, pEsc) {
            rideWorld = nil
            abandonRun()
        }
    }

    private func tickPaused(_ dt: Float) {
        // The scene is frozen, so raymarch it ONCE on entry and then leave the frame
        // standing — present() keeps re-uploading the same pixels. Re-running the full
        // GPU raymarch every frame for an unchanging image was pure waste (it pinned
        // the GPU and span the fans on a paused game for no benefit).
        if !pausedDrawn {
            if let world = world { renderWorld(world); hud.draw(world, into: canvas) }
            FrontEnd.paused(canvas)
            pausedDrawn = true
        }
        if rising(input.pause, pPause) { state = .playing }
        else if rising(input.esc, pEsc) { abandonRun() }
    }

    // Full-screen automap. The world is frozen while it's open (no damage taken
    // reading the map); Tab / the bound pad button or Esc closes it.
    private func tickAutomap(_ dt: Float) {
        guard let world = world else { state = .title; return }
        renderWorld(world)                         // dimmed world stays as backdrop; no HUD clutter
        Automap.draw(world, into: canvas, t: screenT)
        if rising(input.map, pMap) || rising(input.esc, pEsc) { state = .playing }
    }

    // Citadel secured — the planet jump. The feed dissolved to static during the
    // pad charge; this state HOLDS pure static (the story card glitching through
    // it) while the next planet's first floor builds, then installs the world and
    // lets the static burn off the new view (arrivalStatic in tickPlaying).
    private func tickTeleport(_ dt: Float) {
        guard let world = world else { state = .title; return }
        StaticFX.fill(canvas, t: screenT)
        FrontEnd.teleportCard(canvas, world: world, t: screenT)
        // the static HISSES for the whole hold: long overlapping noise voices
        // (each ramps in while the last is still decaying) make one continuous
        // crackle bed — short discrete bursts read as rhythmic clicks
        staticAudioT -= dt
        if staticAudioT <= 0 {
            staticAudioT = 0.8
            audio.trigger(wave: AudioEngine.noise, f0: 1, dur: 1.8, amp: 0.55, attack: 0.35)
        }
        let minHold: Float = 2.6                       // the story beat needs to land
        if screenT >= minHold, let w = pendingWorld {
            arrivalStatic = 1
            // arrival: a soft materialisation whoosh + a quiet falling tone —
            // it outlives the 0.8 s static burn-off so nothing cuts dead
            audio.trigger(wave: AudioEngine.noise, f0: 1, dur: 1.1, amp: 0.30, attack: 0.08)
            audio.trigger(wave: AudioEngine.sine, f0: 1200, f1: 130, dur: 0.9, amp: 0.12, attack: 0.06)
            installWorld(w)
        }
    }

    private func tickGameOver(_ dt: Float) {
        guard let world = world else { state = .title; return }
        FrontEnd.gameOver(canvas, world: world, input: input, qualifies: qualifies, t: screenT, pad: gamepad.connected)
        if qualifies && input.nameEntryActive {
            if input.nameCommitted { recordScore(world); state = .highScores; screenT = 0 }
        } else if rising(input.restart, pConfirm) && screenT > 0.4 {
            state = .highScores; screenT = 0
        }
    }

    private func tickHighScores(_ dt: Float) {
        FrontEnd.highScores(canvas, hs: highScores, t: screenT, highlight: lastRank, pad: gamepad.connected)
        if rising(input.restart, pConfirm) && screenT > 0.4 {
            lastRank = -1; state = .title; screenT = 0; audio.startMusic(.title)
        }
    }

    // ── flow ─────────────────────────────────────────────────────────────────

    private func startGame() {
        baseSeed = FeatureFlags.fixedSeed > 0 ? FeatureFlags.fixedSeed : UInt64.random(in: 1...UInt64.max)
        level = max(1, FeatureFlags.startLevel); colonyIndex = Progression.planetIndex(level); carry = nil
        world = nil                               // a fresh run carries nothing over
        beginWorldBuild(level: level, seed: baseSeed &+ UInt64(level))
        // the descent IS the loading screen: ride the car down while the floor builds
        rideWorld = World.liftRideShaft()
        rideT = 0; rideRumbleT = 0; arrivalStatic = 0
        state = .riding; screenT = 0
        audio.stopMusic()
        audio.elevatorMove(true)
    }

    /// One SERIAL generation queue: MapGen keeps single-threaded scratch state,
    /// so an abandoned build must fully drain before the next run's kicks off.
    private static let genQueue = DispatchQueue(label: "cc.jorviksoftware.Citadel.worldgen", qos: .userInitiated)

    /// Generate a floor on the background queue; the result lands in
    /// pendingWorld on the main thread. Idempotent per floor — safe to call
    /// every frame while a transition runs. The ride/static screens hold until
    /// it arrives; a bumped genEpoch orphans stale builds (abandon/restart).
    private func beginWorldBuild(level: Int, seed: UInt64) {
        guard pendingLevel != level else { return }
        pendingLevel = level
        pendingWorld = nil
        genEpoch += 1
        let epoch = genEpoch
        let colony = Progression.planetIndex(level)
        Renderer.genQueue.async { [weak self] in
            let w = World(level: level, colonyIndex: colony, seed: seed)
            DispatchQueue.main.async {
                guard let self, self.genEpoch == epoch else { return }
                self.pendingWorld = w
            }
        }
    }

    /// Swap the built floor in as the live world (carrying the marine over from
    /// the outgoing one) and drop straight into play — the arrival car's doors
    /// part / the receiver pad's glow dies down as the first frames land.
    private func installWorld(_ w: World) {
        if let old = world {                       // floor-to-floor: the run carries over
            carry = old.player
            w.score = old.score
        }
        world = w
        level = w.level; colonyIndex = w.colonyIndex
        applyCarry()
        pendingWorld = nil; pendingLevel = 0
        input.resetControls()
        deathTimer = 0
        state = .playing
        audio.elevatorMove(false)
        audio.startMusic(.level, depth: level)
    }

    private func nextLevel() {
        if let w = pendingWorld, w.level == level + 1 {
            installWorld(w)
            return
        }
        // fallback: generate synchronously (the ride holds until the build lands,
        // so this only runs if a transition was somehow skipped)
        let next = level + 1
        installWorld(World(level: next, colonyIndex: Progression.planetIndex(next),
                           seed: baseSeed &+ UInt64(next) &* 1000))
    }

    private func applyCarry() {
        guard let c = carry, let w = world else { return }
        w.player.weapons = c.weapons
        w.player.ammo = c.ammo
        w.player.health = max(c.health, 1)
        w.player.armor = c.armor
        w.player.current = c.current
        w.player.berserk = 0
    }

    private func abandonRun() {
        genEpoch += 1                    // orphan any in-flight background build
        pendingWorld = nil; pendingLevel = 0
        rideWorld = nil
        arrivalStatic = 0
        audio.elevatorMove(false)
        world = nil
        carry = nil
        state = .title; screenT = 0
        audio.startMusic(.title)
    }

    private func enterGameOver() {
        guard let world = world else { state = .title; return }
        genEpoch += 1                    // orphan any in-flight background build
        pendingWorld = nil; pendingLevel = 0
        state = .gameOver; screenT = 0
        qualifies = highScores.qualifies(world.score)
        if qualifies {
            input.nameEntryActive = true
            input.nameBuffer = ""
            input.nameCommitted = false
        }
    }

    private func recordScore(_ world: World) {
        input.nameEntryActive = false
        let name = input.nameBuffer.trimmingCharacters(in: .whitespaces).isEmpty ? "MARINE" : input.nameBuffer
        lastRank = highScores.add(name: name, score: world.score, depth: world.level,
                                  colony: world.colonyName, stardate: Renderer.stardate())
        input.nameBuffer = ""
        input.nameCommitted = false
    }

    static func stardate() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'::'HHmm"
        return f.string(from: Date())
    }

    // ── present ────────────────────────────────────────────────────────────

    private func present(_ view: MTKView) {
        texture.replace(region: MTLRegionMake2D(0, 0, RenderConfig.width, RenderConfig.height),
                        mipmapLevel: 0, withBytes: canvas.framebuffer, bytesPerRow: bytesPerRow)
        guard let drawable = view.currentDrawable,
              let rp = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let drawSize = view.drawableSize
        let srcAspect = Float(RenderConfig.width) / Float(RenderConfig.height)
        let dstAspect = Float(drawSize.width) / Float(drawSize.height)
        var vp: MTLViewport
        if dstAspect > srcAspect {
            let h = drawSize.height
            let w = h * CGFloat(srcAspect)
            vp = MTLViewport(originX: Double((drawSize.width - w) / 2), originY: 0,
                             width: Double(w), height: Double(h), znear: 0, zfar: 1)
        } else {
            let w = drawSize.width
            let h = w / CGFloat(srcAspect)
            vp = MTLViewport(originX: 0, originY: Double((drawSize.height - h) / 2),
                             width: Double(w), height: Double(h), znear: 0, zfar: 1)
        }
        enc.setViewport(vp)
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(texture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    // ── world 3-D view: the GPU SDF renderer ───────────────────────────────────
    private func renderWorld(_ world: World) {
        guard gpuWarm else {                                // kernel still compiling (launch)
            canvas.fillRect(0, 0, RenderConfig.width, RenderConfig.height, packRGBA(4, 4, 6))
            return
        }
        gpuWorldRenderer?.render(world, into: canvas)
    }

    /// One throwaway dispatch on a scratch shaft world, off the main thread,
    /// while the title screen is up. Until it completes, renderWorld paints
    /// dark — in practice the compile finishes long before a fire press.
    private func warmKernel() {
        guard let gpu = gpuWorldRenderer else { gpuWarm = true; return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scratch = Canvas2D()
            gpu.render(World.liftRideShaft(), into: scratch)
            DispatchQueue.main.async { self?.gpuWarm = true }
        }
    }

    private func saveScreenshot() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let stamp = Renderer.stardate().replacingOccurrences(of: "::", with: "-")
        let url = dir.appendingPathComponent("Citadel-\(stamp).png")
        Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.height, scale: 4, to: url)
        world?.message("SCREENSHOT SAVED")
    }
}
