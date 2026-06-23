// Citadel — renderer & game-state machine.
//
// Owns the Canvas2D framebuffer, the raycaster, the HUD, the front-end screens,
// audio and high scores. Each frame it polls input, advances the current
// state (title / briefing / intel / playing / paused / level-cleared /
// game-over / high-scores), draws into the framebuffer, then uploads it to a
// Metal texture and blits it nearest-neighbour, aspect-correct and letterboxed,
// to the drawable — the period-correct pixelated look.

import Cocoa
import MetalKit
import QuartzCore

enum GameState { case title, briefing, intel, playing, paused, automap, levelComplete, gameOver, highScores }

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState!
    private var texture: MTLTexture!
    private let bytesPerRow = RenderConfig.width * 4
    private weak var view: MTKView?

    // GPU SDF renderer (Stage 1 of the renderer pivot) — gated by
    // FeatureFlags.metalRenderer; renderWorld() falls back to the CPU raycaster
    // when off. The kernel writes the 3-D view straight into the framebuffer's
    // top viewHeight rows; the HUD then draws over it exactly as before.
    private var gpuPipe: MTLComputePipelineState?
    private var gpuPostPipe: MTLComputePipelineState?
    private var dtTex, liTex, gpuViewTex, gpuHDRTex, gpuDepthTex: MTLTexture?
    private var gpuDepth = [Float]()   // per-pixel scene depth, read back for sprite occlusion
    private var wallArrTex, flatArrTex: MTLTexture?           // procedural texture set (built once)
    private var wallIdTex, floorIdTex, ceilIdTex: MTLTexture? // per-level material-id grids
    private var gpuMapW = 0, gpuMapH = 0
    private var gpuEmitterLights: [Lighting.PointLight] = []   // the level's fixtures as dramatic point lights
    private var gpuDoorSig: UInt64 = 0
    private var gpuWorldID: ObjectIdentifier?
    private var gpuReady = false

    let canvas = Canvas2D()
    private let raycaster = Raycaster()
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
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
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
        if let p = GPURaymarch.makePipelines(device) { gpuPipe = p.raymarch; gpuPostPipe = p.post }
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
        else if rising(input.pause, pPause) { state = .paused }
        else if world.player.dead {
            deathTimer += dt
            if deathTimer > 1.3 { enterGameOver() }
        } else if world.levelComplete {
            state = .levelComplete; screenT = 0; audio.stopMusic()
        }
    }

    private func tickPaused(_ dt: Float) {
        if let world = world { renderWorld(world); hud.draw(world, into: canvas) }
        FrontEnd.paused(canvas)
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
        level = 1; colonyIndex = 0; carry = nil
        world = World(level: level, colonyIndex: colonyIndex, seed: baseSeed &+ UInt64(level))
        input.resetControls()
        deathTimer = 0
        state = .playing
        audio.startMusic(.level, depth: level)
    }

    private func nextLevel() {
        carry = world?.player
        let carriedScore = world?.score ?? 0      // the run total persists across floors
        level += 1; colonyIndex += 1
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

    // ── world 3-D view: GPU SDF raymarch (Stage 1) or the CPU raycaster ───────
    private func renderWorld(_ world: World) {
        guard FeatureFlags.metalRenderer, gpuPipe != nil else {
            raycaster.render(world, into: canvas); return
        }
        let id = ObjectIdentifier(world)
        if gpuWorldID != id { prepareGPULevel(world); gpuWorldID = id }   // (re)build per level / on toggle
        gpuRenderWorld(world)
    }

    /// Order-independent signature of the doors' current visual state — the
    /// distance field is rebuilt when this changes. `open` is quantised so a
    /// sliding door refreshes the field ~16 times as it parts (smooth animation),
    /// yet the signature is stable once every door is fully closed or fully open.
    private func doorSignature(_ map: GameMap) -> UInt64 {
        var h: UInt64 = 0
        for (i, d) in map.doors {
            var k = UInt64(bitPattern: Int64(i)) &* 2654435761
            let q = UInt64(max(0, min(16, (d.open / GameMap.passThreshold * 16).rounded())))
            k ^= (q &* 0x9E3779B1)
            h ^= (k | 1)
        }
        return h
    }

    private func prepareGPULevel(_ world: World) {
        let map = world.map
        gpuReady = false
        gpuMapW = map.w; gpuMapH = map.h
        let (df, sw, sh) = GPURaymarch.buildDistanceField(map)
        let dtDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: sw, height: sh, mipmapped: false)
        dtDesc.usage = .shaderRead; dtDesc.storageMode = .shared
        dtTex = device.makeTexture(descriptor: dtDesc)
        df.withUnsafeBytes { dtTex?.replace(region: MTLRegionMake2D(0, 0, sw, sh), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: sw * 4) }
        var lc = [SIMD4<Float>](repeating: .zero, count: map.w * map.h)
        for k in 0..<lc.count { let c = map.lightColor[k]; lc[k] = SIMD4(c.x, c.y, c.z, 1) }
        let liDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: map.w, height: map.h, mipmapped: false)
        liDesc.usage = .shaderRead; liDesc.storageMode = .shared
        liTex = device.makeTexture(descriptor: liDesc)
        lc.withUnsafeBytes { liTex?.replace(region: MTLRegionMake2D(0, 0, map.w, map.h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: map.w * 16) }
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: RenderConfig.width, height: RenderConfig.viewHeight, mipmapped: false)
        outDesc.usage = [.shaderWrite, .shaderRead]; outDesc.storageMode = .shared
        gpuViewTex = device.makeTexture(descriptor: outDesc)
        let hdrDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: RenderConfig.width, height: RenderConfig.viewHeight, mipmapped: false)
        hdrDesc.usage = [.shaderWrite, .shaderRead]; hdrDesc.storageMode = .private
        gpuHDRTex = device.makeTexture(descriptor: hdrDesc)
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: RenderConfig.width, height: RenderConfig.viewHeight, mipmapped: false)
        depthDesc.usage = [.shaderWrite, .shaderRead]; depthDesc.storageMode = .shared
        gpuDepthTex = device.makeTexture(descriptor: depthDesc)
        gpuDepth = [Float](repeating: 0, count: RenderConfig.width * RenderConfig.viewHeight)
        if wallArrTex == nil { wallArrTex = GPURaymarch.makeTextureArray(device, Textures.shared.walls) }
        if flatArrTex == nil { flatArrTex = GPURaymarch.makeTextureArray(device, Textures.shared.flats) }
        wallIdTex = GPURaymarch.makeIdTexture(device, map.wall, map.w, map.h)
        floorIdTex = GPURaymarch.makeIdTexture(device, map.floor, map.w, map.h)
        ceilIdTex = GPURaymarch.makeIdTexture(device, map.ceil, map.w, map.h)
        gpuEmitterLights = Lighting.pointLights(map)        // fixtures → dramatic point lights (culled per frame)
        gpuDoorSig = doorSignature(map)
        gpuReady = dtTex != nil && liTex != nil && gpuViewTex != nil && gpuHDRTex != nil && gpuDepthTex != nil
                && wallArrTex != nil && flatArrTex != nil && wallIdTex != nil && gpuPostPipe != nil
    }

    /// Nearest monsters in front of the camera (capped) — the ones worth
    /// raymarching natively this frame.
    private func visibleCreatures(_ world: World) -> [Monster] {
        let p = world.player
        let fwd = SIMD2<Float>(cos(p.dir), sin(p.dir))
        var cand: [(Monster, Float)] = []
        for m in world.monsters {
            let rel = m.pos - p.pos
            let d = simd_length(rel)
            if d > 26 { continue }
            if d > 2 && simd_dot(rel, fwd) < -0.5 { continue }   // clearly behind the camera
            cand.append((m, d))
        }
        cand.sort { $0.1 < $1.1 }
        return cand.prefix(6).map { $0.0 }
    }

    /// Nearest non-taken pickups in view — rendered as SDF objects this frame.
    private func visibleItems(_ world: World) -> [Item] {
        let p = world.player
        let fwd = SIMD2<Float>(cos(p.dir), sin(p.dir))
        var cand: [(Item, Float)] = []
        for it in world.items where !it.taken {
            let rel = it.pos - p.pos
            let d = simd_length(rel)
            if d > 22 { continue }
            if d > 1.5 && simd_dot(rel, fwd) < -0.3 { continue }
            cand.append((it, d))
        }
        cand.sort { $0.1 < $1.1 }
        return cand.prefix(10).map { $0.0 }
    }

    /// Nearest rubble piles in view — static SDF debris raymarched this frame.
    private func visibleDebris(_ world: World) -> [(pos: SIMD2<Float>, seed: UInt32)] {
        let p = world.player
        let fwd = SIMD2<Float>(cos(p.dir), sin(p.dir))
        var cand: [((pos: SIMD2<Float>, seed: UInt32), Float)] = []
        for d in world.debris {
            let rel = d.pos - p.pos
            let dd = simd_length(rel)
            if dd > 16 { continue }
            if dd > 1.5 && simd_dot(rel, fwd) < -0.3 { continue }
            cand.append((d, dd))
        }
        cand.sort { $0.1 < $1.1 }
        return cand.prefix(8).map { $0.0 }
    }

    /// Muzzle flash + projectile glows as point lights for the GPU kernel
    /// (mirrors the raycaster's gatherLights, at eye height in 3-D).
    private func gatherDynLights(_ world: World) -> [GPURaymarch.GPULight] {
        var out: [GPURaymarch.GPULight] = []
        let p = world.player
        if p.muzzle > 0 {
            let mz = min(1, p.muzzle / 0.07), rad: Float = 6.5
            out.append(GPURaymarch.GPULight(posR: SIMD4(p.pos.x, 0.5, p.pos.y, 1 / (rad * rad)),
                                            colI: SIMD4(1.0, 0.86, 0.55, 1.7 * mz)))
        }
        for pr in world.projectiles {
            let c: (Float, Float, Float), rad: Float, it: Float
            switch pr.kind {
            case .plasma:   c = (0.50, 0.85, 1.00); rad = 3.6; it = 1.0
            case .rocket:   c = (1.00, 0.70, 0.40); rad = 3.0; it = 0.8
            case .bolt:     c = (1.00, 0.85, 0.40); rad = 3.0; it = 0.9
            case .fireball: c = (1.00, 0.45, 0.18); rad = 4.0; it = 1.2
            case .bfgBall:  c = (0.50, 1.00, 0.45); rad = 5.5; it = 1.6
            }
            out.append(GPURaymarch.GPULight(posR: SIMD4(pr.pos.x, 0.5, pr.pos.y, 1 / (rad * rad)),
                                            colI: SIMD4(c.0, c.1, c.2, it)))
            if out.count >= 16 { break }
        }
        return out
    }

    private func gpuRenderWorld(_ world: World) {
        guard gpuReady, let pipe = gpuPipe, let post = gpuPostPipe, let dt = dtTex, let li = liTex,
              let outT = gpuViewTex, let hdr = gpuHDRTex, let depthT = gpuDepthTex else {
            raycaster.render(world, into: canvas); return
        }
        // rebuild the distance field only when a door's passability flips
        let sig = doorSignature(world.map)
        if sig != gpuDoorSig {
            gpuDoorSig = sig
            let (df, sw, sh) = GPURaymarch.buildDistanceField(world.map)
            df.withUnsafeBytes { dt.replace(region: MTLRegionMake2D(0, 0, sw, sh), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: sw * 4) }
        }
        let p = world.player
        let plane = RenderConfig.cameraPlane
        var u = GPURaymarch.Uniforms(
            ro: SIMD4(p.pos.x, 0.5, p.pos.y, world.elapsed),   // .w = time (lamp flicker)
            fwd: SIMD4(cos(p.dir), 0, sin(p.dir), 0),
            right: SIMD4(-sin(p.dir) * plane, 0, cos(p.dir) * plane, 0),
            up: SIMD4(0, 1, 0, 0),
            params: SIMD4(Float(RenderConfig.width), Float(RenderConfig.viewHeight), Float(RenderConfig.horizon), 1),
            grid: SIMD4(Float(gpuMapW), Float(gpuMapH), world.elapsed, 0),
            extra: SIMD4(0, 0, 0, 0))
        // dramatic lighting = the level's fixtures (warm keys shadow, colour fills
        // don't) culled to the player, plus the player's own muzzle/projectile glows
        // appended after — so extra.z gates the few shadow-casters to the emitter keys.
        let (emit, eshadow) = GPURaymarch.packLights(gpuEmitterLights, camera: p.pos, maxLights: 11)
        var dyn = emit
        dyn.append(contentsOf: gatherDynLights(world))
        if dyn.count > 16 { dyn = Array(dyn.prefix(16)) }
        u.grid.w = Float(dyn.count)
        u.extra.z = Float(eshadow)                                                   // leading emitter keys cast shadows
        if dyn.isEmpty { dyn = [GPURaymarch.GPULight(posR: .zero, colI: .zero)] }   // ≥1 elem for setBytes
        var (cmons, cshapes) = GPURaymarch.packCreatures(visibleCreatures(world))
        let (imons, ishapes) = GPURaymarch.packItems(visibleItems(world), time: world.elapsed)
        let ibase = cshapes.count
        for im0 in imons { var im = im0; im.b.x += Float(ibase); cmons.append(im) }   // offset shape range
        cshapes.append(contentsOf: ishapes)
        let (dmons, dshapes) = GPURaymarch.packDebris(visibleDebris(world))            // static rubble piles
        let dbase = cshapes.count
        for dm0 in dmons { var dm = dm0; dm.b.x += Float(dbase); cmons.append(dm) }
        cshapes.append(contentsOf: dshapes)
        let (pmons, pshapes) = GPURaymarch.packProjectiles(world.projectiles)          // glowing energy orbs
        let pbase = cshapes.count
        for pm0 in pmons { var pm = pm0; pm.b.x += Float(pbase); cmons.append(pm) }
        cshapes.append(contentsOf: pshapes)
        u.grid.z = Float(cmons.count)                                                // creatures + items + debris + projectiles
        // located damage decals (blood at kills, scorch under burned-out corpses)
        var decals = world.decals
        u.extra.x = Float(decals.count)
        u.extra.y = Lighting.floodLevel(level: world.level)                          // floor flooding (lowest floors only)
        if decals.isEmpty { decals = [SIMD4<Float>(0, 0, 0, 0)] }                     // ≥1 elem for setBytes
        if cmons.isEmpty { cmons = [GPURaymarch.GMonster(a: .zero, b: .zero, c: .zero)] }
        if cshapes.isEmpty { cshapes = [GPURaymarch.GShape(a: .zero, b: .zero, col: .zero)] }
        let monBuf = device.makeBuffer(bytes: cmons, length: MemoryLayout<GPURaymarch.GMonster>.stride * cmons.count, options: .storageModeShared)
        let shpBuf = device.makeBuffer(bytes: cshapes, length: MemoryLayout<GPURaymarch.GShape>.stride * cshapes.count, options: .storageModeShared)
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else {
            raycaster.render(world, into: canvas); return
        }
        enc.setComputePipelineState(pipe)
        enc.setTexture(dt, index: 0); enc.setTexture(li, index: 1); enc.setTexture(hdr, index: 2)
        enc.setTexture(wallArrTex, index: 3); enc.setTexture(flatArrTex, index: 4)
        enc.setTexture(wallIdTex, index: 5); enc.setTexture(floorIdTex, index: 6); enc.setTexture(ceilIdTex, index: 7)
        enc.setTexture(depthT, index: 8)
        enc.setBytes(&u, length: MemoryLayout<GPURaymarch.Uniforms>.stride, index: 0)
        enc.setBytes(&dyn, length: MemoryLayout<GPURaymarch.GPULight>.stride * dyn.count, index: 1)
        enc.setBuffer(monBuf, offset: 0, index: 2)
        enc.setBuffer(shpBuf, offset: 0, index: 3)
        enc.setBytes(&decals, length: MemoryLayout<SIMD4<Float>>.stride * decals.count, index: 4)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (RenderConfig.width + 15) / 16, height: (RenderConfig.viewHeight + 15) / 16, depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.endEncoding()
        // post pass: bloom + exposure + ACES + vignette (HDR → LDR)
        let penc = cmd.makeComputeCommandEncoder()!
        penc.setComputePipelineState(post)
        penc.setTexture(hdr, index: 0)
        penc.setTexture(outT, index: 1)
        penc.setBytes(&u, length: MemoryLayout<GPURaymarch.Uniforms>.stride, index: 0)
        penc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        penc.endEncoding()
        cmd.commit(); cmd.waitUntilCompleted()
        // read the graded 3-D view straight into the framebuffer's top viewHeight rows
        outT.getBytes(canvas.framebuffer, bytesPerRow: RenderConfig.width * 4,
                      from: MTLRegionMake2D(0, 0, RenderConfig.width, RenderConfig.viewHeight), mipmapLevel: 0)
        // read back per-pixel scene depth, then composite the sprite things (items /
        // projectiles / particles) over the GPU view with correct per-pixel occlusion
        let vh = RenderConfig.viewHeight
        gpuDepth.withUnsafeMutableBytes {
            depthT.getBytes($0.baseAddress!, bytesPerRow: RenderConfig.width * 4,
                            from: MTLRegionMake2D(0, 0, RenderConfig.width, vh), mipmapLevel: 0)
        }
        gpuDepth.withUnsafeBufferPointer { raycaster.overlayThings(world, into: canvas, depth: $0.baseAddress, includeProjectiles: false) }
    }

    private func saveScreenshot() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let stamp = Renderer.stardate().replacingOccurrences(of: "::", with: "-")
        let url = dir.appendingPathComponent("Citadel-\(stamp).png")
        Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.height, scale: 4, to: url)
        world?.message("SCREENSHOT SAVED")
    }
}
