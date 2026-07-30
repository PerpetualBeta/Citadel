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

enum GameState { case title, briefing, intel, riding, playing, paused, automap, teleport, gameOver, ending, coda, highScores, terminal }

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState!
    private var texture: MTLTexture!
    private let bytesPerRow = RenderConfig.width * 4
    private weak var view: MTKView?

    // The world's 3-D view is drawn by the GPU SDF renderer — the only renderer
    // (the CPU raycaster was removed once the GPU path reached parity).
    private var rasterRenderer: RasterRenderer?      // the renderer. The SDF raymarcher it grew up beside was retired 2026-07-29.

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
    private var carryScore = 0             // score the marine arrives on a floor with (a fresh run starts at 0)
    /// The state she began the CURRENT floor on — what ⌘S writes, whenever it is pressed.
    private var checkpoint: SaveSlot?
    let saves = SaveGames()

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
    /// Set only by the ceremony, so the tally that follows it reports a retaken cluster rather than
    /// telling the one player who finished the game that she died.
    private var victory = false
    private var lastRank = -1
    private var scoresReturn: GameState = .title   // where the Hall returns to (menu view → prior screen; post-game → title)

    // ── terminal easter eggs ──
    private var seenEggs: Set<Int> = []    // indices into TerminalEgg.all seen THIS session (in-memory → resets each launch)
    private var currentEgg = -1            // egg on screen, or -1 = GURU MEDITATION (pool exhausted)
    private var terminalReturn: GameState = .playing
    private var termClosing = false        // zooming back out
    private var termPage = 0                // current page of a multi-page document
    private var pTermL = false, pTermR = false   // LEFT/RIGHT page-turn edge tracking
    private let invaders = SpaceInvaders() // the arcade mini-game egg (played on the CRT glass)

    // edge tracking
    private var pConfirm = false, pEsc = false, pBrief = false, pIntel = false
    private var pPause = false, pMute = false, pShot = false, pMap = false, pUse = false
    // the intel codex — current page + page-turn edge tracking (◀ ▶ / strafe keys)
    private var intelPage = 0
    private var pPageL = false, pPageR = false
    private var pausedDrawn = false        // pause freezes the frame — render it ONCE, then idle (no GPU raymarch while paused → fans don't spin on a frozen scene)
    private var backdropBuf: [UInt32] = [] // cached raymarch of the frozen world behind .terminal / .automap
    private var backdropValid = false      // invalidated whenever the world is stepped (tickPlaying)

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
        guard let q = device.makeCommandQueue() else { fatalError("Citadel: no Metal command queue — the GPU is unavailable.") }
        self.queue = q
        self.view = view
        self.input = input
        self.gamepad = gamepad
        self.audio = audio
        self.highScores = highScores
        super.init()
        buildPipeline(view: view)
        buildTexture()
        rasterRenderer = RasterRenderer(device: device)
        warmKernel()                     // …and pay the kernel's first-dispatch compile now too
        rasterRenderer?.warmPortraits()   // the mesh dossier busts the codex shows
        ItemIcons.warm()                 // …and the SDF pickup icons (match the in-world geometry)
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
        case .intel: tickIntel(dt)
        case .riding: tickRiding(dt)
        case .playing: tickPlaying(dt)
        case .paused: tickPaused(dt)
        case .automap: tickAutomap(dt)
        case .teleport: tickTeleport(dt)
        case .gameOver: tickGameOver(dt)
        case .ending: tickEnding(dt)
        case .coda: tickCoda(dt)
        case .highScores: tickHighScores(dt)
        case .terminal: tickTerminal(dt)
        }
        tickTransition(dt)

        // ── the teleport static bed ── ONE authority drives the loop's volume
        // every frame, wherever the story is: swelling with the pad charge,
        // full through the interstitial hold, fading with the arrival burn-off,
        // silent everywhere else (so no path can leave it running).
        let staticLevel: Float
        if state == .teleport { staticLevel = 1 }
        else if state == .playing, let w = world, w.teleportPhase == .charging { staticLevel = 0.2 + 0.8 * w.teleportT }
        else if state == .playing { staticLevel = arrivalStatic }
        else { staticLevel = 0 }
        audio.staticBed(staticLevel)

        // ── the ceremony's crowd ── same single-authority rule as the static bed above: the gains
        // are computed from the shot list and arrive every frame, so leaving the screen (finished
        // or skipped) silences the hall by construction rather than by remembering to.
        let crowd = state == .ending ? EndingArt.crowd(at: screenT) : (bed: 0, cheer: 0, chant: 0)
        audio.ceremonyCrowd(bed: crowd.bed, cheer: crowd.cheer, chant: crowd.chant)

        // ── PAUSED MEANS SILENT ── the world stops when you pause, so the world's noise has to stop
        // with it. It did not: the frame froze while the ambient bed, the machinery, the flames and a
        // drone mid-hiss all played on, which reads as the game still running behind the pause. Ducked
        // at the final mixer stage, the one place proven to catch everything (per-bus zeroing leaks
        // ~-24 dB, and the synth fallback is wired past the buses entirely). Not an instant cut —
        // a very short ramp, so pausing does not click.
        //
        // A transition owns the gain while one is running (it is fading picture and sound together),
        // so this only speaks when there is no fade in flight.
        if transition == nil {
            let target: Float = state == .paused ? 0 : 1
            let k = 1 - expf(-dt / 0.05)                // ~50 ms — quick enough to feel instant, slow enough not to click
            audio.transitionGain += (target - audio.transitionGain) * k
        }

        updateEdges()
        present(view)
    }

    private func rising(_ now: Bool, _ prev: Bool) -> Bool { now && !prev }

    // ── faded screen changes ──────────────────────────────────────────────────
    //
    // The outgoing screen keeps drawing under a rising black veil while every sound ducks with it;
    // at full black the new screen takes over, and the veil falls away again. ONE mechanism, because
    // the ending needs three of these — skipped ceremony → title, ceremony → coda, coda → title —
    // and three hand-rolled fades would drift apart in feel.
    private struct Transition {
        var t: Float = 0
        let out: Float          // seconds down to black
        let into: Float         // seconds back up on the new screen (0 = arrive already black)
        let next: GameState
        var switched = false
    }
    private var transition: Transition?

    /// Begin a faded change of screen. Ignored if one is already running, so a held key or a
    /// coincidence of timings cannot stack two fades and double-duck the sound.
    private func beginTransition(to next: GameState, out: Float, into: Float) {
        guard transition == nil else { return }
        transition = Transition(out: out, into: into, next: next)
    }

    /// Drive the veil and the duck. Runs AFTER the state's own draw, so it lays over whatever was
    /// drawn — and the frame the switch happens on is at full black, where nothing shows anyway.
    private func tickTransition(_ dt: Float) {
        guard var tr = transition else { return }
        tr.t += dt
        if !tr.switched && tr.t >= tr.out {
            tr.switched = true
            tr.t = tr.out                       // the fall starts from full black, never part way down
            enterFaded(tr.next)
        }
        let a: Float = tr.switched
            ? (tr.into > 0 ? 1 - smoothstep01((tr.t - tr.out) / tr.into) : 0)
            : smoothstep01(tr.t / tr.out)
        if a > 0.002 { canvas.fillRectBlend(0, 0, RenderConfig.width, RenderConfig.height, packRGBA(0, 0, 0), a) }
        audio.transitionGain = 1 - a
        if tr.switched && tr.t >= tr.out + tr.into {
            audio.transitionGain = 1
            transition = nil
        } else {
            transition = tr
        }
    }

    /// The state change at the bottom of a fade, with whatever each destination expects set up.
    private func enterFaded(_ next: GameState) {
        switch next {
        case .coda:
            state = next; screenT = 0
            // The coda is silent by construction rather than by a held-down gain — stopping the
            // stems means no path can leave the hall running under the last card.
            audio.stopMusic()
        case .gameOver:
            // Through enterGameOver, NEVER by setting the state: that call is what arms name entry,
            // and a bare state change would land on the tally and quietly fail to record the run.
            enterGameOver()
            // The theme back from silence, rising with the picture. The alternative is a dead
            // screen: the coda has just stopped everything, and the tally has a job to do.
            audio.startMusic(.title)
        case .title:
            state = next; screenT = 0
            // The theme from its top, rising with the picture: the title screen always opens on
            // its first bar, never half way through a track the ceremony had been playing.
            audio.startMusic(.title)
        default:
            state = next; screenT = 0
        }
    }

    @inline(__always) private func smoothstep01(_ x: Float) -> Float {
        let t = max(0, min(1, x)); return t * t * (3 - 2 * t)
    }

    private func updateEdges() {
        pConfirm = input.restart; pEsc = input.esc; pBrief = input.briefing
        pIntel = input.intel; pPause = input.pause; pMute = input.mute; pShot = input.screenshot
        pMap = input.map; pUse = input.use
    }

    // ── states ─────────────────────────────────────────────────────────────

    private func tickTitle(_ dt: Float) {
        FrontEnd.title(canvas, t: screenT, hs: highScores, pad: gamepad.connected)
        if rising(input.restart, pConfirm) { startGame() }
        else if rising(input.briefing, pBrief) { state = .briefing; screenT = 0 }
        else if rising(input.intel, pIntel) { state = .intel; intelPage = 0; screenT = 0 }
    }

    private func tickInfo(_ dt: Float, _ draw: (Canvas2D, Float) -> Void) {
        draw(canvas, screenT)
        if rising(input.esc, pEsc) || rising(input.restart, pConfirm) { state = .title; screenT = 0 }
    }

    /// The intel codex: ◀ ▶ (or strafe / dpad) leaf through the pages, wrapping.
    private func tickIntel(_ dt: Float) {
        FrontEnd.intel(canvas, t: screenT, page: intelPage)
        let left = input.turnLeft || input.strafeLeft
        let right = input.turnRight || input.strafeRight
        if rising(left, pPageL) { intelPage = (intelPage + FrontEnd.intelPages - 1) % FrontEnd.intelPages }
        if rising(right, pPageR) { intelPage = (intelPage + 1) % FrontEnd.intelPages }
        pPageL = left; pPageR = right
        if rising(input.esc, pEsc) || rising(input.restart, pConfirm) { state = .title; screenT = 0 }
    }

    private func tickPlaying(_ dt: Float) {
        guard let world = world else { state = .title; return }
        backdropValid = false                       // the world is advancing — any cached .terminal/.automap backdrop is now stale
        // The moment an exit commits (car dropping / pad charging), the next
        // floor starts building on the background queue; the transition holds
        // until it lands (holdRide keeps the car dropping past its nominal ride).
        if world.elevatorPhase == .descending || world.teleportPhase == .charging {
            let next = world.level + 1
            beginWorldBuild(level: next, seed: Renderer.floorSeed(baseSeed, next))
        }
        world.holdRide = pendingWorld == nil
        world.update(dt: dt, input: input, audio: audio)
        // the marine USEd a computer-desk terminal → zoom in to read an easter egg,
        // suspending play. (Consume the flag; the .terminal state owns it from here.)
        if world.terminalUsePending {
            world.terminalUsePending = false
            enterTerminal()
            return
        }
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
            // THE RUN ENDS HERE, and this test must come BEFORE the exit-type fork below. The last
            // floor of every citadel — floor 48 included — leaves by TELEPORTER, which routes through
            // .teleport and installs the next world directly; it never calls nextLevel(). Gating the
            // ending in nextLevel() therefore gated the one route that cannot reach it, and finishing
            // the game rolled quietly back to Demeter. Both exit types converge here, so here is the
            // only place the decision belongs.
            if Progression.isFinalFloor(world.level) {
                audio.stopMusic()
                beginEnding()
            } else if Progression.isLastFloor(world.level) {
                state = .teleport; screenT = 0
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
        drawFrozenBackdrop(world)                  // dimmed world stays as backdrop; no HUD clutter (cached — no raymarch/frame)
        Automap.draw(world, into: canvas, t: screenT, input: input, dt: dt)
        if rising(input.map, pMap) || rising(input.esc, pEsc) { state = .playing }
    }

    // Citadel secured — the planet jump. The feed dissolved to static during the
    // pad charge; this state HOLDS pure static (the story card glitching through
    // it) while the next planet's first floor builds, then installs the world and
    // lets the static burn off the new view (arrivalStatic in tickPlaying).
    private func tickTeleport(_ dt: Float) {
        guard let world = world else { state = .title; return }
        StaticFX.fill(canvas, t: screenT)
        // The cluster-fallen beat that used to live here is gone: it fired when the sixth citadel fell
        // and the descent rolled back to Demeter, and nothing rolls back any more — floor 48 is caught
        // by the ending gate above and never reaches this state. So every arrival here is an ordinary
        // planet jump. (FrontEnd.clusterCard is now unreachable in game.)
        FrontEnd.teleportCard(canvas, world: world, t: screenT)
        // (the static's sound is the looping noise bed — one volume authority
        // in tick() drives it through charge → hold → burn-off seamlessly)
        let minHold: Float = 2.6
        if screenT >= minHold, let w = pendingWorld {
            arrivalStatic = 1
            // arrival: a quiet falling tone under the fading static
            audio.trigger(wave: AudioEngine.sine, f0: 1200, f1: 130, dur: 0.9, amp: 0.12, attack: 0.06)
            installWorld(w)
        }
    }

    /// Enter the ceremony. The world stays alive — it carries the score the tally reports.
    private func beginEnding() {
        genEpoch += 1                    // orphan any floor-49 build that was already in flight
        pendingWorld = nil; pendingLevel = 0
        rideWorld = nil
        arrivalStatic = 0
        audio.elevatorMove(false)        // the car is still ringing; quench it before the hall
        audio.startMusic(.ceremony)      // the theme returns, and the crowd layers over it
        state = .ending; screenT = 0
    }

    /// The ceremony runs itself and then hands to the coda. Skippable, but not in the first second —
    /// the marine has just pressed fire to leave the last floor, and a held key must not eat the one
    /// screen she spent 48 floors earning.
    ///
    /// Both exits fade, and both end at the TALLY, because the score is the point: 48 floors is the
    /// highest-scoring run the game has, and neither watching the ceremony nor skipping it may cost
    /// a player their place in the Hall. What skipping forfeits is the coda, nothing more.
    private func tickEnding(_ dt: Float) {
        guard world != nil else { state = .title; return }
        FrontEnd.ending(canvas, t: screenT, pad: gamepad.connected)
        guard transition == nil else { return }
        if rising(input.restart, pConfirm) && screenT > 1.0 {
            victory = true                  // the run was finished either way — skipping the cinematic doesn't undo it
            beginTransition(to: .gameOver, out: Renderer.skipFade, into: Renderer.fadeUp)
        } else if screenT >= EndingArt.duration {
            victory = true
            // Down to black over a longer beat than a skip, and the sound goes with it: the coda
            // has to arrive in silence for its line to land.
            beginTransition(to: .coda, out: Renderer.codaFadeOut, into: 0)
        }
    }

    /// The last card. It holds indefinitely — there is no prompt, and nothing to read but the line
    /// — and it cannot be cut away until the words have finished arriving.
    private func tickCoda(_ dt: Float) {
        FrontEnd.coda(canvas, t: screenT)
        guard transition == nil, screenT > FrontEnd.codaIn else { return }
        if rising(input.restart, pConfirm) {
            beginTransition(to: .gameOver, out: Renderer.codaFadeOut, into: Renderer.fadeUp)
        }
    }

    /// Fade lengths for the ending. A skip is brisk — the player has asked to move on — while the
    /// run to black at the end of the ceremony is slow enough to read as an ending.
    static let skipFade: Float = 0.9
    static let codaFadeOut: Float = 1.8
    static let fadeUp: Float = 1.2

    private func tickGameOver(_ dt: Float) {
        guard let world = world else { state = .title; return }
        FrontEnd.gameOver(canvas, world: world, input: input, qualifies: qualifies, t: screenT,
                          pad: gamepad.connected, victory: victory)
        if qualifies && input.nameEntryActive {
            if input.nameCommitted { recordScore(world); scoresReturn = .title; state = .highScores; screenT = 0 }
        } else if rising(input.restart, pConfirm) && screenT > 0.4 {
            scoresReturn = .title; state = .highScores; screenT = 0
        }
    }

    // ── manual save / restore ─────────────────────────────────────────────────
    //
    // Driven entirely from the macOS menu (⌘S / ⌘O). Nothing about it appears on a game screen: the
    // front end has been composed to within a pixel and a SAVE prompt bolted onto it would cost more
    // than it bought. A native menu is also where a Mac player looks first.

    /// Freeze the run before a modal dialog opens. A modal spins its own run loop, and a game left
    /// advancing behind one can kill the marine while the player types a slot name.
    func pauseForDialog() {
        guard state == .playing else { return }
        state = .paused; pausedDrawn = false
    }

    /// Is there a run to write down? Only while one is genuinely IN FLIGHT — she has to be standing
    /// on a floor. Not at the title, not on the ride down (the checkpoint there still belongs to the
    /// floor she just left), and not after death: a corpse has nothing to save. ⌘S greys out for all
    /// of those rather than failing with an alert.
    var savableCheckpoint: SaveSlot? {
        let live: Set<GameState> = [.playing, .paused, .automap, .terminal]
        return world != nil && live.contains(state) ? checkpoint : nil
    }

    /// Write the checkpoint into a slot under the player's own label.
    @discardableResult
    func saveRun(named name: String, to slotIndex: Int) -> Bool {
        guard var c = checkpoint, world != nil else { return false }
        c.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? "FLOOR \(c.level)" : String(name.prefix(32))
        c.stardate = Renderer.stardate()          // stamped when SAVED, not when the floor began
        return saves.write(c, to: slotIndex)
    }

    /// Resume a saved run: she rides the lift down to the floor she saved on, and play picks up from
    /// that checkpoint. Deliberately the SAME path a fresh run takes — the descent is the loading
    /// screen either way, so a restore has no code of its own to go stale.
    func restoreRun(_ s: SaveSlot) {
        genEpoch += 1                             // orphan any floor still building for the old run
        pendingWorld = nil; pendingLevel = 0
        world = nil                               // …so installWorld does not carry the abandoned run over
        arrivalStatic = 0
        audio.elevatorMove(false)
        transition = nil
        victory = false
        baseSeed = s.runSeed                      // the run's identity: every floor, and the seven, follow from it
        level = max(1, s.level); colonyIndex = Progression.planetIndex(level)
        carryScore = s.score
        // A standard-issue marine, then overwritten with what she was carrying. Built this way round
        // so a save written before a weapon or ammo type existed still lands on a valid player: the
        // arrays below are only copied as far as they go.
        var p = Player(at: .zero, dir: 0)
        p.health = s.health; p.armor = s.armor; p.mines = s.mines
        p.current = WeaponKind(rawValue: s.current) ?? .plasma
        for i in 0..<min(p.weapons.count, s.weapons.count) { p.weapons[i] = s.weapons[i] }
        for i in 0..<min(p.ammo.count, s.ammo.count) { p.ammo[i] = s.ammo[i] }
        carry = p                                 // applyCarry lands it on the rebuilt floor
        beginWorldBuild(level: level, seed: Renderer.floorSeed(baseSeed, level))
        rideWorld = World.liftRideShaft()
        rideT = 0; rideRumbleT = 0
        state = .riding; screenT = 0
        audio.stopMusic()
    }

    /// Show the Hall of the Fallen on demand (the menu item), returning to whatever
    /// screen it was opened from so it never abandons a run in progress.
    func viewHighScores() {
        guard state != .highScores else { return }
        scoresReturn = state
        lastRank = -1
        state = .highScores; screenT = 0
    }

    private func tickHighScores(_ dt: Float) {
        FrontEnd.highScores(canvas, hs: highScores, t: screenT, highlight: lastRank, pad: gamepad.connected)
        if (rising(input.restart, pConfirm) || rising(input.esc, pEsc)) && screenT > 0.4 {
            lastRank = -1
            let ret = scoresReturn; scoresReturn = .title
            state = ret; screenT = 0
            if ret == .title { audio.startMusic(.title) }
            if ret == .paused { pausedDrawn = false }       // the Hall overwrote the frozen frame — redraw it
        }
    }

    // ── terminal easter eggs ──────────────────────────────────────────────────
    private func enterTerminal() {
        // pick a random UNSEEN egg; once the pool is spent, every terminal shows the
        // Amiga guru meditation (currentEgg = -1). Seen-set is per session (in memory).
        // Each PHYSICAL terminal shows one egg: a fresh desk draws the next unseen
        // egg from the session pool; re-using a desk it already showed (or once the
        // pool is spent) falls back to the guru meditation.
        let deskIdx = world?.terminalDeskIndex ?? -1
        if world?.usedTerminals.contains(deskIdx) == true {
            currentEgg = -1                                  // this unit's egg is spent → guru
        } else {
            let unseen = TerminalEgg.all.indices.filter { !seenEggs.contains($0) }
            if let pick = unseen.randomElement() { seenEggs.insert(pick); currentEgg = pick }
            else { currentEgg = -1 }
            world?.usedTerminals.insert(deskIdx)
        }
        if currentEgg >= 0, TerminalEgg.all[currentEgg].kind == .miniGame { invaders.reset() }
        terminalReturn = .playing
        termClosing = false
        termPage = 0
        pTermL = termLeft(); pTermR = termRight()   // a held move key must not flip the first page
        state = .terminal; screenT = 0
        pUse = true          // guard: the same USE press that opened it must not close it
    }

    // LEFT / RIGHT from any bound source — pages documents, drives the arcade cannon.
    private func termLeft()  -> Bool { input.turnLeft  || input.strafeLeft  || input.moveX < -0.35 }
    private func termRight() -> Bool { input.turnRight || input.strafeRight || input.moveX >  0.35 }

    /// Reading a terminal — play is suspended (world not stepped). USE (or ESC)
    /// again zooms back out. The frozen world stays behind, dimmed.
    private func tickTerminal(_ dt: Float) {
        guard let world = world else { state = .title; return }
        drawFrozenBackdrop(world)                // frozen backdrop, cached (no world.update, no per-frame raymarch)
        hud.draw(world, into: canvas)
        let egg: TerminalEgg? = (currentEgg >= 0 && currentEgg < TerminalEgg.all.count) ? TerminalEgg.all[currentEgg] : nil
        let isGame = egg?.kind == .miniGame
        // zoom scale — same ease in either direction
        let s: Float
        if !termClosing { let z = min(1, screenT / 0.28); s = z * z * (3 - 2 * z) }
        else            { let z = 1 - min(1, screenT / 0.22); s = z * z * (3 - 2 * z) }

        let live = !termClosing && screenT >= 0.28   // fully zoomed in and not backing out
        if isGame {
            let f = Terminal.frame(canvas, scale: s, t: screenT, guru: false)
            if live { invaders.update(dt: dt, left: termLeft(), right: termRight(), fire: input.fire, audio: audio) }
            if f.cf > 0.01 { invaders.draw(canvas, f.x0, f.y0, f.sw, f.sh, a: f.cf, t: screenT) }
        } else {
            // LEFT / RIGHT page through a multi-page document (clamped at the ends)
            if live, let e = egg, e.pageCount > 1 {
                if rising(termRight(), pTermR) { termPage = min(e.pageCount - 1, termPage + 1) }
                if rising(termLeft(),  pTermL) { termPage = max(0, termPage - 1) }
            }
            Terminal.draw(canvas, egg: egg, page: termPage, scale: s, t: screenT)
        }
        pTermL = termLeft(); pTermR = termRight()

        // USE / ESC steps back out (never FIRE, so the arcade keeps its trigger)
        if !termClosing {
            if rising(input.use, pUse) || rising(input.esc, pEsc) { termClosing = true; screenT = 0 }
        } else if screenT >= 0.22 {
            state = terminalReturn; screenT = 0; termClosing = false
        }
    }

    // ── flow ─────────────────────────────────────────────────────────────────

    /// The seed a given floor of a given run is built from. ONE formula, because a restored save has
    /// to rebuild the floor the player actually walked — and it did not: `startGame` seeded floor N
    /// with `base + N` while every descent seeded it `base + N*1000`, so the same run produced two
    /// different floor Ns depending on how you arrived. Harmless while you could only ever arrive one
    /// way; a wrong map the moment a save can drop you straight onto a floor.
    static func floorSeed(_ base: UInt64, _ level: Int) -> UInt64 { base &+ UInt64(level) &* 1000 }

    private func startGame() {
        baseSeed = FeatureFlags.fixedSeed > 0 ? FeatureFlags.fixedSeed : UInt64.random(in: 1...UInt64.max)
        level = max(1, FeatureFlags.startLevel); colonyIndex = Progression.planetIndex(level); carry = nil
        carryScore = 0; checkpoint = nil          // a fresh run carries no score and no checkpoint
        victory = false                           // …and it has not been won yet
        world = nil                               // a fresh run carries nothing over
        beginWorldBuild(level: level, seed: Renderer.floorSeed(baseSeed, level))
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
        let run = baseSeed                       // the RUN's identity — picks which of the seven this floor holds
        Renderer.genQueue.async { [weak self] in
            let w = World(level: level, colonyIndex: colony, seed: seed, runSeed: run)
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
            carryScore = old.score
        }
        w.score = carryScore
        world = w
        level = w.level; colonyIndex = w.colonyIndex
        applyCarry()
        // ── THE CHECKPOINT ── snapshot the state she STARTS this floor on, before a shot is fired.
        // This is what a save writes, whenever it is taken: saving in the thick of a fight records
        // the floor's beginning, not the fight. See SaveGame.swift for why that is the design and
        // not a limitation.
        checkpoint = SaveSlot(name: "", stardate: Renderer.stardate(),
                              runSeed: baseSeed, level: w.level, colonyName: w.colonyName, score: w.score,
                              health: w.player.health, armor: w.player.armor, mines: w.player.mines,
                              current: w.player.current.rawValue,
                              weapons: w.player.weapons, ammo: w.player.ammo)
        pendingWorld = nil; pendingLevel = 0
        input.resetControls()
        deathTimer = 0
        state = .playing
        audio.elevatorMove(false)
        // THE FAR SIGNAL fades in across the DEPTHS — the last `deepFloors` floors of
        // each citadel (the deck-free floors, where the player already knows the sound).
        // Faint as you enter them, full at the deepest, so reaching the bottom is the payoff.
        let deepFloors = 3
        let intoDepths = Progression.floorInBuilding(level) - (Progression.floorsPerBuilding - deepFloors)
        let farGain = max(0, min(1, Float(intoDepths) / Float(deepFloors)))
        audio.startMusic(.level, depth: level, farSignalGain: farGain)
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
                           seed: Renderer.floorSeed(baseSeed, next), runSeed: baseSeed))
    }

    private func applyCarry() {
        guard let c = carry, let w = world else { return }
        w.player.weapons = c.weapons
        w.player.ammo = c.ammo
        w.player.mines = c.mines         // mines live outside the ammo array — they ride down too
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

    /// THE ONLY WAY INTO THE TALLY — do not set `state = .gameOver` anywhere else. Arming name
    /// entry is what makes a qualifying run record at all, so a bare state change would land on the
    /// screen, show the score, take no name, and lose it. Both endings come through here (death,
    /// and the ceremony) precisely so neither can drift away from that.
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

    /// The frozen backdrop behind .terminal / .automap: raymarch the (unchanging)
    /// world ONCE, cache the framebuffer, and thereafter restore the cached pixels
    /// instead of re-running the ~1M-thread SDF kernel + post pass every frame. The
    /// world isn't stepped in these states, so the backdrop is byte-identical; only
    /// the cheap CPU overlay (HUD + CRT, or the dimmed orbit map) redraws on top.
    /// Same reasoning as the paused fix — the fans must not spin on a static scene.
    private func drawFrozenBackdrop(_ world: World) {
        let n = canvas.width * canvas.height
        if backdropValid && backdropBuf.count == n {
            backdropBuf.withUnsafeBufferPointer { _ = memcpy(canvas.framebuffer, $0.baseAddress!, n * 4) }
        } else {
            renderWorld(world)
            if backdropBuf.count != n { backdropBuf = [UInt32](repeating: 0, count: n) }
            backdropBuf.withUnsafeMutableBufferPointer { _ = memcpy($0.baseAddress!, canvas.framebuffer, n * 4) }
            backdropValid = true
        }
    }

    // ── world 3-D view: the GPU SDF renderer ───────────────────────────────────
    private func renderWorld(_ world: World) {
        guard gpuWarm else {                                // kernel still compiling (launch)
            canvas.fillRect(0, 0, RenderConfig.width, RenderConfig.height, packRGBA(4, 4, 6))
            return
        }
        _ = rasterRenderer?.render(world, into: canvas)
    }

    /// One throwaway render on a scratch shaft world, off the main thread, while the title screen
    /// is up: Metal compiles a shader at its first dispatch, and that is a multi-second stall we do
    /// not want on the first fire-press. Until it completes, renderWorld paints dark — in practice
    /// the compile finishes long before anyone presses fire.
    private func warmKernel() {
        guard let rr = rasterRenderer else { gpuWarm = true; return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scratch = Canvas2D()
            _ = rr.render(World.liftRideShaft(), into: scratch)
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
