// Citadel — GPU SDF world renderer (the shipping render path).
//
// Sphere-traces the level's distance field + floor/ceiling + native SDF creatures
// through the GPURaymarch compute kernel, grades the HDR result (bloom / ACES /
// teal-amber / vignette), reads the graded view into the top viewHeight rows of a
// Canvas2D framebuffer, then composites the billboards the kernel doesn't raymarch
// (props + particles) via SpriteCompositor with per-pixel depth occlusion.
//
// Owns its Metal pipelines + per-level textures, keyed to the world's identity so
// the (expensive) per-level setup is rebuilt only when the level changes. Reusable:
// the live Renderer drives it each frame, and the headless capture tools drive it
// off a system-default device to render the same picture the player sees.

import Foundation
import Metal
import simd

final class GPUWorldRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let raymarch: MTLComputePipelineState
    private let post: MTLComputePipelineState
    private let spriteCompositor = SpriteCompositor()
    /// Optional textured-mesh renderer for the Queen (dev 3D-asset direction).
    /// nil when the flag is off or the asset/GPU setup is missing → SDF queen.
    private let meshCreature: MeshCreature?
    private let meshDrone: MeshCreature?

    private var dtTex, liTex, gpuViewTex, gpuHDRTex, gpuDepthTex: MTLTexture?
    private var gpuDepth = [Float]()   // per-pixel scene depth, read back for sprite occlusion
    private var wallArrTex, flatArrTex: MTLTexture?           // procedural texture set (built once)
    private var wallIdTex, floorIdTex, ceilIdTex: MTLTexture? // per-level material-id grids
    private var gpuMapW = 0, gpuMapH = 0
    private var gpuEmitterLights: [Lighting.PointLight] = []   // the level's fixtures as dramatic point lights
    private var gpuDoorSig: UInt64 = 0
    private var gpuWorldID: ObjectIdentifier?
    private var gpuReady = false
    // Grow-only per-frame GPU scratch for the packed creature/shape arrays: reused
    // across frames (memcpy into .contents()) instead of allocating two fresh
    // MTLBuffers every frame. Safe because render() waits for GPU completion before
    // the next frame overwrites them; capacity only grows, never shrinks.
    private var monScratch: MTLBuffer?
    private var monScratchCap = 0
    private var shpScratch: MTLBuffer?
    private var shpScratchCap = 0
    /// Harness-only: force the kernel's per-ray creature mask fully on. The mask
    /// is a pure optimisation, so flipping this must not change a pixel — the
    /// load probe diffs the two renders to prove it (catches sign/margin/window
    /// bugs in one invariant).
    var disableCreatureMask = false
    /// Harness-only: disable the march's window-entry step clamp — reintroduces
    /// the leap-over-small-windows bug ON PURPOSE so the probe can verify its
    /// invariant check still detects that disease before trusting a PASS.
    var disableWindowClamp = false

    /// Fails (returns nil) if the compute pipelines or a command queue can't be
    /// built — the caller then has no GPU path (the live renderer falls back to
    /// the CPU raycaster; the tools skip).
    init?(device: MTLDevice) {
        guard let p = GPURaymarch.makePipelines(device), let q = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = q
        self.raymarch = p.raymarch
        self.post = p.post
        self.meshCreature = FeatureFlags.meshQueen ? MeshCreature(device: device) : nil
        self.meshDrone = FeatureFlags.meshDrone ? MeshCreature(device: device, kind: .drone) : nil
    }

    /// Upload `arr` into a reused grow-only shared buffer and return it for the
    /// encoder — reallocating (doubling) only when the element count outgrows the
    /// current capacity, otherwise just memcpy'ing into the live buffer. `arr` must
    /// be non-empty (callers pad to ≥1 so `setBytes`/`setBuffer` never see 0 length).
    private func uploadScratch<T>(_ arr: [T], _ buf: inout MTLBuffer?, _ cap: inout Int) -> MTLBuffer? {
        let need = arr.count
        if buf == nil || cap < need {
            let grow = max(need, cap * 2)
            guard let nb = device.makeBuffer(length: MemoryLayout<T>.stride * grow, options: .storageModeShared) else { return nil }
            buf = nb; cap = grow
        }
        arr.withUnsafeBufferPointer { _ = memcpy(buf!.contents(), $0.baseAddress!, MemoryLayout<T>.stride * need) }
        return buf
    }

    /// Draw `world`'s 3-D view into the top viewHeight rows of `canvas`. Returns
    /// false if the GPU couldn't render this frame (the caller may fall back). The
    /// per-level texture setup is cached and rebuilt only when the world changes.
    @discardableResult
    func render(_ world: World, into canvas: Canvas2D) -> Bool {
        let id = ObjectIdentifier(world)
        if gpuWorldID != id { prepareLevel(world); gpuWorldID = id }   // (re)build per level
        return renderFrame(world, into: canvas)
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

    /// Build the level-INDEPENDENT GPU resources up front — at launch, while the
    /// title screen is up — so the first gameplay frame doesn't stall generating the
    /// procedural texture bank and uploading the wall/flat texture arrays the instant
    /// the player hits fire. The per-level distance field stays lazy (it's cheap).
    func prewarm() {
        if wallArrTex == nil { wallArrTex = GPURaymarch.makeTextureArray(device, Textures.shared.walls) }
        if flatArrTex == nil { flatArrTex = GPURaymarch.makeTextureArray(device, Textures.shared.flats) }
    }

    /// Render the Field Intel dossier busts from the SAME mesh instances the game
    /// draws, and cache them in MeshPortraits — so the codex shows the actual
    /// creatures, not the SDF sculpts. Only for the castes whose mesh flag is on
    /// (else the codex falls back to IntelPortraits). Synchronous; call once.
    func renderPortraits() {
        if let q = meshCreature { MeshPortraits.store(.queen, q.portrait(spin: MeshPortraits.spin(.queen), gain: MeshPortraits.gain(.queen))) }
        if let d = meshDrone   { MeshPortraits.store(.alien, d.portrait(spin: MeshPortraits.spin(.alien), gain: MeshPortraits.gain(.alien))) }
    }

    /// Non-blocking variant for launch: the codex is rarely the first screen
    /// reached, and it degrades gracefully (SDF fallback) until this lands.
    func warmPortraits() {
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.renderPortraits() }
    }

    private func prepareLevel(_ world: World) {
        let map = world.map
        gpuReady = false
        gpuMapW = map.w; gpuMapH = map.h
        let (df, sw, sh) = GPURaymarch.buildDistanceField(map)
        let dtDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: sw, height: sh, mipmapped: false)   // .r wall distance · .g pipe-routing enable
        dtDesc.usage = .shaderRead; dtDesc.storageMode = .shared
        dtTex = device.makeTexture(descriptor: dtDesc)
        df.withUnsafeBytes { dtTex?.replace(region: MTLRegionMake2D(0, 0, sw, sh), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: sw * 8) }
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
                && wallArrTex != nil && flatArrTex != nil && wallIdTex != nil
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
            if d > 32 { continue }                               // render distance (was 26 — creatures popped in too close)
            if d > 2 && simd_dot(rel, fwd) < -0.5 { continue }   // clearly behind the camera
            cand.append((m, d))
        }
        // The Queen is the level objective and the most shape-heavy creature; never
        // let nearer drones crowd her out of the capped set (she'd wink in and out,
        // "especially the Queen"). Float her to the front so she's always included
        // and packed first — guaranteeing she fits the GPU shape budget. Then fill
        // the remaining slots with the nearest.
        cand.sort { a, b in
            let qa = (a.0.kind == .queen), qb = (b.0.kind == .queen)
            if qa != qb { return qa }
            return a.1 < b.1
        }
        // Cap the render set for perf, but generously: a level-8 room spawns up to
        // ~6 drones plus the Queen, and neighbours converge — a cap of 6 left the
        // extras invisible (not in the GPU buffer at all). 10 covers a Queen + a full
        // pack; only the very farthest of a huge convergence can still drop.
        return cand.prefix(10).map { $0.0 }
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

    /// Nearest furniture/fixtures in view — static SDF props raymarched this frame.
    private func visibleProps(_ world: World) -> [Prop] {
        let p = world.player
        let fwd = SIMD2<Float>(cos(p.dir), sin(p.dir))
        var cand: [(Prop, Float)] = []
        for pr in world.props {
            let rel = pr.pos - p.pos
            let d = simd_length(rel)
            if d > 13 { continue }
            if d > 1.5 && simd_dot(rel, fwd) < -0.3 { continue }
            cand.append((pr, d))
        }
        cand.sort { $0.1 < $1.1 }
        // Props are STATIC but still cost per-raymarch-step (every instance is bound-
        // tested + evaluated at every step). Keep the live set tight — rooms are small
        // now, so the nearest 8 in front covers the room you're in; more than that just
        // heats the GPU (the fans) for furniture you're mostly not looking at.
        return cand.prefix(8).map { $0.0 }
    }

    /// Nearest fuel drums in view — SDF barrels raymarched this frame (were sprites).
    private func visibleDrums(_ world: World) -> [Drum] {
        let p = world.player
        let fwd = SIMD2<Float>(cos(p.dir), sin(p.dir))
        var cand: [(Drum, Float)] = []
        for d in world.drums where d.health > 0 {
            let rel = d.pos - p.pos
            let dd = simd_length(rel)
            if dd > 15 { continue }
            if dd > 1.5 && simd_dot(rel, fwd) < -0.3 { continue }
            cand.append((d, dd))
        }
        cand.sort { $0.1 < $1.1 }
        return cand.prefix(8).map { $0.0 }   // a fuel store can cluster several — cap the visible set
    }

    /// Nearest recharge sockets in view — SDF pedestals raymarched this frame.
    private func visibleSockets(_ world: World) -> [Socket] {
        let p = world.player
        let fwd = SIMD2<Float>(cos(p.dir), sin(p.dir))
        var cand: [(Socket, Float)] = []
        for sk in world.sockets {
            let rel = sk.pos - p.pos
            let dd = simd_length(rel)
            if dd > 16 { continue }
            if dd > 1.5 && simd_dot(rel, fwd) < -0.3 { continue }
            cand.append((sk, dd))
        }
        cand.sort { $0.1 < $1.1 }
        return cand.prefix(4).map { $0.0 }
    }

    /// Nearest deployed mines in view — SDF pucks raymarched this frame (were sprites).
    private func visibleMines(_ world: World) -> [Mine] {
        let p = world.player
        let fwd = SIMD2<Float>(cos(p.dir), sin(p.dir))
        var cand: [(Mine, Float)] = []
        for mn in world.deployedMines {
            let rel = mn.pos - p.pos
            let dd = simd_length(rel)
            if dd > 14 { continue }
            if dd > 1.5 && simd_dot(rel, fwd) < -0.3 { continue }
            cand.append((mn, dd))
        }
        cand.sort { $0.1 < $1.1 }
        return cand.prefix(6).map { $0.0 }
    }

    /// Muzzle flash + projectile glows as point lights for the GPU kernel
    /// (mirrors WorldLight.gatherLights, at eye height in 3-D).
    private func gatherDynLights(_ world: World) -> [GPURaymarch.GPULight] {
        var out: [GPURaymarch.GPULight] = []
        let p = world.player
        if p.muzzle > 0 && world.flameJet.t <= 0 {   // the flamethrower has its own warm light (below) — no cold muzzle flash
            let mz = min(1, p.muzzle / 0.07), rad: Float = 6.5
            out.append(GPURaymarch.GPULight(posR: SIMD4(p.pos.x, 0.5, p.pos.y, 1 / (rad * rad)),
                                            colI: SIMD4(1.0, 0.86, 0.55, 1.7 * mz)))
        }
        // the flamethrower jet throws warm firelight down the aim — the stream
        // lights the room ahead and flares against the wall it splashes on,
        // guttering on two incommensurate rates so it never pulses in rhythm
        let jt = world.flameJet
        if jt.t > 0 {
            let s0 = min(1, jt.t / 0.10)
            let flick = 0.80 + 0.20 * sinf(world.elapsed * 31) + 0.12 * sinf(world.elapsed * 67 + 1.3)
            let reach = max(0.6, jt.reach)
            let mid = jt.nozzle + jt.dir * min(reach * 0.5, 1.6)
            let far = jt.nozzle + jt.dir * (reach - 0.2)
            let rM: Float = 4.2, rF: Float = 3.0
            out.append(GPURaymarch.GPULight(posR: SIMD4(mid.x, 0.5, mid.y, 1 / (rM * rM)),
                                            colI: SIMD4(1.0, 0.55, 0.20, 1.6 * s0 * flick)))
            out.append(GPURaymarch.GPULight(posR: SIMD4(far.x, 0.45, far.y, 1 / (rF * rF)),
                                            colI: SIMD4(1.0, 0.48, 0.16, 1.1 * s0 * flick)))
        }
        // elevator cabin light — the car interior is pitch dark once the leaves
        // shut (no baked light reaches it), so a car in use carries its own lamp.
        // During the descent the lamp sways and shaft lights sweep past the cage.
        func cabin(_ cell: Int, descending: Bool) -> GPURaymarch.GPULight {
            let cx = Float(cell % world.map.w) + 0.5, cz = Float(cell / world.map.w) + 0.5
            var inten: Float = 0.85
            if descending {
                let t = world.elapsed
                inten = 0.55 + 0.20 * sinf(t * 2.6)                    // the cabin lamp swaying
                inten += 1.1 * powf(max(0, sinf(t * 3.6)), 12)         // a shaft light sweeping past
            }
            let rad: Float = 2.6
            return GPURaymarch.GPULight(posR: SIMD4(cx, 0.78, cz, 1 / (rad * rad)),
                                        colI: SIMD4(1.0, 0.93, 0.76, inten))
        }
        if world.elevatorPhase != .idle, world.map.exitCell >= 0 {
            out.append(cabin(world.map.exitCell, descending: world.elevatorPhase == .descending))
        }
        if world.map.entryCell >= 0, (world.map.doors[world.map.entryCell]?.open ?? 0) > 0.01 {
            out.append(cabin(world.map.entryCell, descending: false))
        }
        // teleporter pads carry their own COLD light, hugging the deck (a lamp at
        // eye height washes the chamber to white): the exit pad breathes on
        // standby, lifts under a boarder, and flares as the charge ramps; the
        // arrival receiver glows as the marine materialises, then dies down.
        func padLight(_ cell: Int, _ inten: Float, _ reach: Float) -> GPURaymarch.GPULight {
            let cx = Float(cell % world.map.w) + 0.5, cz = Float(cell / world.map.w) + 0.5
            return GPURaymarch.GPULight(posR: SIMD4(cx, 0.18, cz, 1 / (reach * reach)),
                                        colI: SIMD4(0.55, 0.85, 1.0, inten))
        }
        if world.isTeleportFloor, world.map.exitCell >= 0, world.map.wall[world.map.exitCell] == 0 {
            let charge: Float = world.teleportPhase == .charging ? world.teleportT
                              : (world.teleportPhase == .await ? 0.12 : 0)
            let breathe = 0.16 + 0.04 * sinf(world.elapsed * 2.2)
            out.append(padLight(world.map.exitCell, breathe + 1.2 * charge, 2.0 + 1.6 * charge))
        }
        if world.arrivalGlow > 0.01, world.map.entryCell >= 0 {
            out.append(padLight(world.map.entryCell, 0.10 + 0.45 * world.arrivalGlow, 2.2))
        }
        // impact flashes light the room — fierce, decaying, coloured per cause
        // (warm for detonations, plasma-cyan for bolt splashes)
        for b in world.blasts {
            let f = max(0, b.t / 0.3)
            let rad: Float = 5.5
            out.append(GPURaymarch.GPULight(posR: SIMD4(b.pos.x, 0.5, b.pos.y, 1 / (rad * rad)),
                                            colI: SIMD4(b.col.x, b.col.y, b.col.z, 2.4 * f)))
        }
        // burning corpses cast a live orange firelight that builds and dies with
        // the pyre — the room flickers while a body burns
        for (i, m) in world.monsters.enumerated() where m.state == .dead && m.burn > 0 && m.burn < 1 {
            let flare = sinf(m.burn * .pi)
            // gutter on two incommensurate rates, desynced per corpse — no rhythm
            let ph = Float(i) * 1.7
            let flick = 0.80 + 0.14 * sinf(world.elapsed * 13 + ph) + 0.10 * sinf(world.elapsed * 29 + ph * 2.3)
            let rad: Float = 3.6
            out.append(GPURaymarch.GPULight(posR: SIMD4(m.pos.x, 0.45, m.pos.y, 1 / (rad * rad)),
                                            colI: SIMD4(1.0, 0.55, 0.22, (0.4 + 1.3 * flare) * flick)))
            if out.count >= 14 { break }
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

    /// Burning sources for the GPU volumetric flame (`fireEmission` in the kernel):
    /// the flamethrower jet (a fat gout down the live aim, clipped at the wall) and
    /// every corpse pyre (a rising column, taller over the Queen). The kernel loops
    /// this per ray with a cheap bounding-sphere reject, so it stays tight — capped,
    /// and the nearest pyres win when a whole pack ignites at once.
    private func gatherFireEmitters(_ world: World) -> [GPURaymarch.FireEmitter] {
        guard FeatureFlags.gpuFire else { return [] }
        var out: [GPURaymarch.FireEmitter] = []
        // ── the flamethrower jet ── flow horizontal down the aim; kind = 1
        let j = world.flameJet
        if j.t > 0 {
            let strength = min(1, j.t / 0.10)
            let len = max(0.5, j.reach - 0.15)
            out.append(GPURaymarch.FireEmitter(
                p0: SIMD4(j.nozzle.x, 0.5, j.nozzle.y, 0.42),      // nozzle · puff-envelope radius
                p1: SIMD4(j.dir.x, 0, j.dir.y, len),               // horizontal flow, length clipped at the wall
                p2: SIMD4(1.9 * strength, 3.1, 1, 0)))             // vigor · seed · kind=jet · smoke=0
        }
        // ── corpse pyres ── a FUEL FIRE consuming a mass: ignites at once, flares
        // ferociously for a beat, then dies down as the body is spent. Taller and
        // wider than the corpse so the blaze ROARS UP AND OUT of it — clearing the
        // mesh corpse's silhouette (which is drawn over the kernel), not a timid
        // stub hidden behind it. The Queen, a far greater mass, burns hardest.
        func ss(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = max(0, min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t) }
        let pp = world.player.pos
        var pyres: [(d: Float, e: GPURaymarch.FireEmitter)] = []
        for (i, m) in world.monsters.enumerated() where m.state == .dead && m.burn > 0 && m.burn < 1 {
            let b = m.burn
            let ignite = ss(0, 0.10, b)                            // catches almost at once
            let decay  = 1 - ss(0.42, 1.0, b)                     // falls away over the back half
            let flare  = ignite * (0.30 + 0.70 * decay)          // held high, then tapering (not a symmetric bell)
            let burst  = (1 - ss(0.0, 0.20, b)) * ignite         // a fireball at ignition — the fuel catching
            let queen  = m.kind == .queen
            let rad = m.def.radius
            let baseR = rad * (queen ? 1.5 : 1.35) * (0.80 + 0.55 * flare + 0.40 * burst)   // puff-chain envelope width
            let tall: Float = (queen ? 1.9 : 1.4) * (0.70 + 0.40 * flare + 0.25 * burst)    // overshoots the ceiling → upper puffs pile into rolling smoke
            // vigor drives puff opacity + brightness (colour is temperature, decoupled);
            // ignites hard, holds, then dies as fuel spends. Queen burns hotter + sootier.
            let vigor = (queen ? 1.20 : 1.0) * (0.55 + 0.55 * flare + 0.70 * burst)         // ~0.55 … 2.1
            let e = GPURaymarch.FireEmitter(
                p0: SIMD4(m.pos.x, 0.02, m.pos.y, baseR),
                p1: SIMD4(0, 1, 0, tall),
                p2: SIMD4(vigor, Float(i) * 1.7 + 0.3, 0, queen ? 1 : 0))   // vigor · seed · kind=pyre · smokeBias(Queen sootier)
            let rel = m.pos - pp
            pyres.append((rel.x * rel.x + rel.y * rel.y, e))
        }
        // keep the jet + the nearest pyres within a tight budget (a mine can ignite
        // a whole pack; distant columns cull cheaply per ray but needn't be sent)
        let budget = 16 - out.count
        if pyres.count > budget { pyres.sort { $0.d < $1.d }; pyres = Array(pyres.prefix(budget)) }
        out.append(contentsOf: pyres.map { $0.e })
        return out
    }

    private func renderFrame(_ world: World, into canvas: Canvas2D) -> Bool {
        guard gpuReady, let dt = dtTex, let li = liTex,
              let outT = gpuViewTex, let hdr = gpuHDRTex, let depthT = gpuDepthTex else { return false }
        // rebuild the distance field only when a door's passability flips
        let sig = doorSignature(world.map)
        if sig != gpuDoorSig {
            gpuDoorSig = sig
            let (df, sw, sh) = GPURaymarch.buildDistanceField(world.map)
            df.withUnsafeBytes { dt.replace(region: MTLRegionMake2D(0, 0, sw, sh), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: sw * 8) }
        }
        let p = world.player
        let plane = RenderConfig.cameraPlane
        // elevator ride: the car judders — a small deterministic eye jitter
        // (vertical + view-lateral), scaled by the world's rideShake envelope
        var eye = SIMD3<Float>(p.pos.x, 0.5, p.pos.y)
        if world.rideShake > 0.001 {
            let t = world.elapsed, s = world.rideShake
            let lat = s * 0.006 * sinf(t * 47 + 1.7)
            eye.y += s * 0.010 * sinf(t * 34)
            eye.x += lat * -sinf(p.dir)
            eye.z += lat * cosf(p.dir)
        }
        // a heavy mass hitting the deck (the Queen's topple): one hard,
        // mostly-vertical jolt ringing down — squared so the attack is sharp
        if world.impactShake > 0.001 {
            let t = world.elapsed, s = world.impactShake * world.impactShake
            eye.y += s * 0.05 * sinf(t * 31)
            let lat = s * 0.02 * sinf(t * 23 + 0.9)
            eye.x += lat * -sinf(p.dir)
            eye.z += lat * cosf(p.dir)
        }
        var u = GPURaymarch.Uniforms(
            ro: SIMD4(eye.x, eye.y, eye.z, world.elapsed),   // .w = time (lamp flicker)
            fwd: SIMD4(cos(p.dir), 0, sin(p.dir), 0),
            right: SIMD4(-sin(p.dir) * plane, 0, cos(p.dir) * plane, 0),
            up: SIMD4(0, 1, 0, 0),
            params: SIMD4(Float(RenderConfig.width), Float(RenderConfig.viewHeight), Float(RenderConfig.horizon), 1),
            grid: SIMD4(Float(gpuMapW), Float(gpuMapH), world.elapsed, 0),
            extra: SIMD4(0, 0, 0, 0))
        u.dbg.x = disableCreatureMask ? 1 : 0   // harness invariant: mask off must be pixel-identical
        u.dbg.y = disableWindowClamp ? 1 : 0    // harness calibration: reintroduce the window-leap bug
        u.dbg.z = world.powerDim                // scene dim 0…1 — the lights sag + flicker with a distant electrical fault
        u.tune.x = FeatureFlags.overheadLight   // overhead-lamp brightness (OverheadLight default; 1 = as-authored)
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
        // volumetric GPU fire — the jet + corpse pyres (count → tune.y, so the
        // kernel skips the whole block, and the buffer, when nothing burns)
        var fires = gatherFireEmitters(world)
        u.tune.y = Float(fires.count)
        if fires.isEmpty { fires = [GPURaymarch.FireEmitter(p0: .zero, p1: .zero, p2: .zero)] }   // ≥1 elem for setBytes
        // When the mesh Queen is active she's drawn by MeshCreature (rasterised
        // after the kernel) through ALL states — including death, which deforms the
        // SAME mesh (slump/topple/extinguish) rather than popping to an SDF corpse —
        // so keep every queen out of the SDF creature pack (else she'd render twice).
        let allCreatures = visibleCreatures(world)
        func isMeshQueen(_ m: Monster) -> Bool { m.kind == .queen && meshCreature != nil }
        // gibbed drones (rocket / mine) leave NO corpse — only the gore splatter; route
        // them to the SDF path, which emits nothing for a gibbed creature (as before).
        func isMeshDrone(_ m: Monster) -> Bool { m.kind == .alien && meshDrone != nil && !m.gibbed }
        let meshQueens = allCreatures.filter(isMeshQueen)
        let meshDrones = allCreatures.filter(isMeshDrone)
        let sdfCreatures = allCreatures.filter { !isMeshQueen($0) && !isMeshDrone($0) }
        // Pack every SDF instance group up front (each is independent of cmons/cshapes),
        // then reserve the EXACT final capacity from the real counts before appending —
        // this kills the incremental array reallocations as the eight groups accumulate
        // (O4). The running shape-range base offsets below still read cshapes.count in
        // sequence, so they stay correct.
        var (cmons, cshapes) = GPURaymarch.packCreatures(sdfCreatures)
        let (imons, ishapes) = GPURaymarch.packItems(visibleItems(world), time: world.elapsed)
        let (dmons, dshapes) = GPURaymarch.packDebris(visibleDebris(world))            // static rubble piles
        let (fmons, fshapes) = GPURaymarch.packProps(visibleProps(world))              // furniture & fixtures
        let (umons, ushapes) = GPURaymarch.packDrums(visibleDrums(world))              // fuel barrels (SDF — were sprites)
        let (smons, sshapes) = GPURaymarch.packSockets(visibleSockets(world))          // recharge panels (SDF — were sprites)
        let (nmons, nshapes) = GPURaymarch.packMines(visibleMines(world))              // deployed mines (SDF — were sprites)
        let (pmons, pshapes) = GPURaymarch.packProjectiles(world.projectiles)          // glowing energy orbs
        cmons.reserveCapacity(cmons.count + imons.count + dmons.count + fmons.count + umons.count + smons.count + nmons.count + pmons.count)
        cshapes.reserveCapacity(cshapes.count + ishapes.count + dshapes.count + fshapes.count + ushapes.count + sshapes.count + nshapes.count + pshapes.count)

        let ibase = cshapes.count
        for im0 in imons { var im = im0; im.b.x += Float(ibase); cmons.append(im) }   // offset shape range
        cshapes.append(contentsOf: ishapes)
        let dbase = cshapes.count
        for dm0 in dmons { var dm = dm0; dm.b.x += Float(dbase); cmons.append(dm) }
        cshapes.append(contentsOf: dshapes)
        let fbase = cshapes.count
        for fm0 in fmons { var fm = fm0; fm.b.x += Float(fbase); cmons.append(fm) }
        cshapes.append(contentsOf: fshapes)
        let ubase = cshapes.count
        for um0 in umons { var um = um0; um.b.x += Float(ubase); cmons.append(um) }
        cshapes.append(contentsOf: ushapes)
        let sbase = cshapes.count
        for sm0 in smons { var sm = sm0; sm.b.x += Float(sbase); cmons.append(sm) }
        cshapes.append(contentsOf: sshapes)
        let nbase = cshapes.count
        for nm0 in nmons { var nm = nm0; nm.b.x += Float(nbase); cmons.append(nm) }
        cshapes.append(contentsOf: nshapes)
        let pbase = cshapes.count
        for pm0 in pmons { var pm = pm0; pm.b.x += Float(pbase); cmons.append(pm) }
        cshapes.append(contentsOf: pshapes)
        u.grid.z = Float(cmons.count)                                                // creatures + items + debris + projectiles
        // group-bound restructure + shape bounds + trig hoist — MUST precede the
        // viewmodel append below (the rebuild keeps only monster-owned shapes)
        GPURaymarch.packShapeGroups(&cmons, &cshapes)
        // the held weapon (SDF viewmodel): shapes ride the same buffer but are
        // marched as an overlay — the kernel takes their range via env.zw and
        // the gun's world anchor + local bound via vmA/vmB. It anchors to the
        // SHAKEN eye, so lift judder and the Queen's floor-jolt carry into
        // the marine's hands. Lowered only when the marine is down.
        if !world.player.dead {
            let vm = Viewmodel.pack(player: world.player, time: world.elapsed)
            u.env.z = Float(cshapes.count)
            u.env.w = Float(vm.shapes.count)
            cshapes.append(contentsOf: vm.shapes)
            let rU = SIMD3<Float>(-sinf(p.dir), 0, cosf(p.dir))
            let fU = SIMD3<Float>(cosf(p.dir), 0, sinf(p.dir))
            let anchor = eye + fU * Viewmodel.anchorFwd + rU * Viewmodel.anchorRight
                             - SIMD3<Float>(0, 1, 0) * Viewmodel.anchorDown
            u.vmA = SIMD4(anchor.x, anchor.y, anchor.z, vm.boundR)
            u.vmB = SIMD4(vm.boundC.x, vm.boundC.y, vm.boundC.z, 0)
        }
        // CPU-placed pipe fittings (valves/gauges) — count rides vmB.w
        var fitsPack = world.map.pipeFittings
        u.vmB.w = Float(fitsPack.count)
        if fitsPack.isEmpty { fitsPack = [SIMD4<Float>(0, 0, 0, 0)] }         // ≥1 elem for setBytes
        // located damage decals (blood at kills, scorch under burned-out corpses)
        var decals = world.decals
        u.extra.x = Float(decals.count)
        u.extra.y = Lighting.floodLevel(level: world.level)                          // floor flooding (lowest floor only)
        u.env.x = world.waterOff.x; u.env.y = world.waterOff.y                       // this level's puddle-field offset
        if decals.isEmpty { decals = [SIMD4<Float>(0, 0, 0, 0)] }                     // ≥1 elem for setBytes
        // live doors → leaf-anchored texture UVs in the kernel
        var doorsPack = GPURaymarch.packDoors(world.map)
        u.extra.w = Float(doorsPack.count)
        if doorsPack.isEmpty { doorsPack = [SIMD4<Float>(-1, -1, 0, 0)] }             // ≥1 elem; (-1,-1) matches no cell
        if cmons.isEmpty { cmons = [GPURaymarch.GMonster(a: .zero, b: .zero, c: .zero)] }
        if cshapes.isEmpty { cshapes = [GPURaymarch.GShape(a: .zero, b: .zero, col: .zero)] }
        guard let monBuf = uploadScratch(cmons, &monScratch, &monScratchCap),
              let shpBuf = uploadScratch(cshapes, &shpScratch, &shpScratchCap) else { return false }
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { return false }
        enc.setComputePipelineState(raymarch)
        enc.setTexture(dt, index: 0); enc.setTexture(li, index: 1); enc.setTexture(hdr, index: 2)
        enc.setTexture(wallArrTex, index: 3); enc.setTexture(flatArrTex, index: 4)
        enc.setTexture(wallIdTex, index: 5); enc.setTexture(floorIdTex, index: 6); enc.setTexture(ceilIdTex, index: 7)
        enc.setTexture(depthT, index: 8)
        enc.setBytes(&u, length: MemoryLayout<GPURaymarch.Uniforms>.stride, index: 0)
        enc.setBytes(&dyn, length: MemoryLayout<GPURaymarch.GPULight>.stride * dyn.count, index: 1)
        enc.setBuffer(monBuf, offset: 0, index: 2)
        enc.setBuffer(shpBuf, offset: 0, index: 3)
        enc.setBytes(&decals, length: MemoryLayout<SIMD4<Float>>.stride * decals.count, index: 4)
        enc.setBytes(&doorsPack, length: MemoryLayout<SIMD4<Float>>.stride * doorsPack.count, index: 5)
        enc.setBytes(&fitsPack, length: MemoryLayout<SIMD4<Float>>.stride * fitsPack.count, index: 6)
        enc.setBytes(&fires, length: MemoryLayout<GPURaymarch.FireEmitter>.stride * fires.count, index: 7)
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
        // drums + sockets + mines are all SDF now (raymarched above); only particles
        // remain billboards on the GPU path — so the ~4 MB depth read-back and the
        // sprite composite are only needed on frames that actually have particles.
        // Out of combat there are none, so skip both entirely (the depth texture is
        // still written by the kernel; we just don't pull it back to the CPU).
        // Draw only queens ahead of the camera and in range — skips the cost (and
        // any near-plane edge cases) when she's behind you or across the level.
        let fwd2 = SIMD2<Float>(cos(p.dir), sin(p.dir))
        func inView(_ m: Monster) -> Bool {
            let rel = m.pos - p.pos
            let ahead = rel.x * fwd2.x + rel.y * fwd2.y
            return ahead > 0.15 && (rel.x * rel.x + rel.y * rel.y) < 22 * 22
        }
        let liveQueens = meshQueens.filter(inView)
        // Drones use the visibleCreatures set DIRECTLY — it already drops behind-camera
        // ones, caps range + count. No extra range/LoS gate: those made alive/dead/dust
        // drones vanish until you closed in. Off-screen ones clip away for free, and the
        // depth composite occludes whatever's behind a wall per-pixel.
        let liveDrones = meshDrones
        // Depth is needed by the mesh creatures (occlusion + writing their own depth)
        // and by the particle compositor — pull it back if any is in play this frame.
        let needDepth = !world.particles.isEmpty || !liveQueens.isEmpty || !liveDrones.isEmpty
        if needDepth {
            let vh = RenderConfig.viewHeight
            gpuDepth.withUnsafeMutableBytes {
                depthT.getBytes($0.baseAddress!, bytesPerRow: RenderConfig.width * 4,
                                from: MTLRegionMake2D(0, 0, RenderConfig.width, vh), mipmapLevel: 0)
            }
        }
        // the 3-D mesh Queen — rasterised into the frame, and her perp-depth written
        // back so particles composited afterwards occlude against her
        if let mc = meshCreature, !liveQueens.isEmpty {
            gpuDepth.withUnsafeMutableBufferPointer { dp in
                for q in liveQueens {
                    let sector = WorldLight.lightAt(world.map, q.pos.x, q.pos.y)
                    // topple accelerates into the CRASH at queenImpactT (0.78·deathTime)
                    // so the mesh's landing lines up with World's floor-thump/tremor.
                    let death: Float
                    if q.state == .dead { death = 1 }
                    else if q.state == .dying {
                        let f = min(1, (q.stateTime / World.queenDeathTime) / CreatureLab.queenImpactT)
                        death = f * f
                    } else { death = 0 }
                    mc.composite(into: canvas, depth: dp.baseAddress!, eye: eye, dir: p.dir,
                                 pos: q.pos, faceTarget: p.pos, sector: sector, time: world.elapsed,
                                 map: world.map, death: death, burn: q.burn, ashed: q.ashed,
                                 wallField: dtTex, mapW: Float(gpuMapW), mapH: Float(gpuMapH))
                }
            }
        }
        // the 3-D mesh DRONES — a whole pack in ONE batched pass; each writes its
        // perp-depth so particles + one another occlude correctly (composited over
        // the queen's pixels, so ordering against her is right too)
        if let md = meshDrone, !liveDrones.isEmpty {
            let insts: [MeshCreature.DroneInst] = liveDrones.map { m in
                let death: Float
                if m.state == .dead { death = 1 }
                else if m.state == .dying { death = min(1, m.stateTime / World.droneDeathTime) }
                else { death = 0 }
                let move: Float
                switch m.state {
                case .chase: move = 1
                case .pain:  move = 0.5
                case .attack: move = 0.35
                default:     move = 0
                }
                // gait is distance-matched (animTime accrues travel), so the stride
                // tracks movement instead of sliding; naturally desynced per-drone
                let dissolve: Float = m.dissolving ? min(1, m.dissolveT / 1.8) : 0
                // the corpse renders EXACTLY where it died (m.pos) — never displaced —
                // so flames, ash and blood always land on it (a render-only settle slid
                // the body off its own fire).
                return MeshCreature.DroneInst(
                    pos: m.pos, dir: m.dir, gait: m.animTime * 5.0, move: move, rear: m.rearAmt,
                    dissolve: dissolve, seed: m.deathSeed, death: death, burn: m.burn, ashed: m.ashed,
                    sector: WorldLight.lightAt(world.map, m.pos.x, m.pos.y))
            }
            gpuDepth.withUnsafeMutableBufferPointer { dp in
                md.compositeDrones(into: canvas, depth: dp.baseAddress!, eye: eye, camDir: p.dir, instances: insts,
                                   wallField: dtTex, mapW: Float(gpuMapW), mapH: Float(gpuMapH))
            }
        }
        if !world.particles.isEmpty {
            gpuDepth.withUnsafeBufferPointer { spriteCompositor.overlayThings(world, into: canvas, depth: $0.baseAddress, includeProjectiles: false, includeDrums: false, includeSockets: false, includeMines: false) }
        }
        return true
    }
}
