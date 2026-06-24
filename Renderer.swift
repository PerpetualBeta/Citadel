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

enum GameState { case title, briefing, intel, playing, paused, automap, levelComplete, teleport, gameOver, highScores }

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
        case .playing: tickPlaying(dt)
        case .paused: tickPaused(dt)
        case .automap: tickAutomap(dt)
        case .levelComplete: tickLevelComplete(dt)
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
        FrontEnd.title(canvas, t: screenT, hs: highScores)
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
        world.update(dt: dt, input: input, audio: audio)
        let cue = world.audioCue()       // drive the reactive ambient bed from live danger
        audio.setTension(threat: cue.threat, queen: cue.queen, health: cue.health, combat: cue.combat)
        renderWorld(world)
        hud.draw(world, into: canvas)

        if FeatureFlags.screenshotKey && rising(input.screenshot, pShot) { saveScreenshot() }

        if rising(input.map, pMap) { state = .automap }
        else if rising(input.pause, pPause) { state = .paused; pausedDrawn = false }
        else if world.player.dead {
            deathTimer += dt
            if deathTimer > 1.3 { enterGameOver() }
        } else if world.levelComplete {
            // last floor of a citadel → teleport to the next planet; else descend a floor
            state = Progression.isLastFloor(world.level) ? .teleport : .levelComplete
            screenT = 0; audio.stopMusic()
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

    private func tickLevelComplete(_ dt: Float) {
        guard let world = world else { state = .title; return }
        FrontEnd.levelComplete(canvas, world: world, t: screenT)
        if rising(input.restart, pConfirm) && screenT > 0.4 { nextLevel() }
    }

    // Citadel secured — the planet-to-planet teleport shown between buildings.
    private func tickTeleport(_ dt: Float) {
        guard let world = world else { state = .title; return }
        FrontEnd.teleport(canvas, world: world, t: screenT)
        if rising(input.restart, pConfirm) && screenT > 0.4 { nextLevel() }
    }

    private func tickGameOver(_ dt: Float) {
        guard let world = world else { state = .title; return }
        FrontEnd.gameOver(canvas, world: world, input: input, qualifies: qualifies, t: screenT)
        if qualifies && input.nameEntryActive {
            if input.nameCommitted { recordScore(world); state = .highScores; screenT = 0 }
        } else if rising(input.restart, pConfirm) && screenT > 0.4 {
            state = .highScores; screenT = 0
        }
    }

    private func tickHighScores(_ dt: Float) {
        FrontEnd.highScores(canvas, hs: highScores, t: screenT, highlight: lastRank)
        if rising(input.restart, pConfirm) && screenT > 0.4 {
            lastRank = -1; state = .title; screenT = 0; audio.startMusic(.title)
        }
    }

    // ── flow ─────────────────────────────────────────────────────────────────

    private func startGame() {
        baseSeed = FeatureFlags.fixedSeed > 0 ? FeatureFlags.fixedSeed : UInt64.random(in: 1...UInt64.max)
        level = 1; colonyIndex = Progression.planetIndex(level); carry = nil
        world = World(level: level, colonyIndex: colonyIndex, seed: baseSeed &+ UInt64(level))
        input.resetControls()
        deathTimer = 0
        state = .playing
        audio.startMusic(.level, depth: level)
    }

    private func nextLevel() {
        carry = world?.player
        let carriedScore = world?.score ?? 0      // the run total persists across floors
        level += 1; colonyIndex = Progression.planetIndex(level)   // planet changes only at building boundaries
        world = World(level: level, colonyIndex: colonyIndex, seed: baseSeed &+ UInt64(level) &* 1000)
        applyCarry()
        world?.score = carriedScore
        input.resetControls()
        deathTimer = 0
        state = .playing
        audio.startMusic(.level, depth: level)
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
        world = nil
        carry = nil
        state = .title; screenT = 0
        audio.startMusic(.title)
    }

    private func enterGameOver() {
        guard let world = world else { state = .title; return }
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
        gpuWorldRenderer?.render(world, into: canvas)
    }

    private func saveScreenshot() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let stamp = Renderer.stardate().replacingOccurrences(of: "::", with: "-")
        let url = dir.appendingPathComponent("Citadel-\(stamp).png")
        Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.height, scale: 4, to: url)
        world?.message("SCREENSHOT SAVED")
    }
}
