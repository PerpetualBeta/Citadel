import Foundation
import Metal
import simd
import ModelIO

// ============================================================================
//  RasterRenderer — the rasterised world renderer
//
//  Built ALONGSIDE the SDF raymarcher (GPUWorldRenderer), selected by
//  FeatureFlags.rasterRenderer. Renders the grid world as triangle meshes with
//  PBR shading, into the same Canvas2D framebuffer the HUD then draws over.
//
//  M1: walkable geometry + one key + flat ambient.
//  M2: the game's BAKED ambient-light field (spatially-varying mood), MULTIPLE
//      lamp lights (pools; the nearest shadow-mapped), and EMISSIVE surfaces
//      (lit panels, screens, toxic pools, teleporter, exit switch).
// ============================================================================
final class RasterRenderer {

    // pos, normal, and the surface's baked PBR material (albedo, rough, metal, emissive).
    struct PVert { var px, py, pz, nx, ny, nz, ar, ag, ab, rough, metal, er, eg, eb: Float; var tid: Float = -1 }   // tid≥0 = sample walls[id]; -1 = flat material

    struct Cam {
        var mvp: simd_float4x4
        var lmvp0: simd_float4x4    // up to 3 nearest-lamp shadow projections — ORTHO top-down from each
        var lmvp1: simd_float4x4    // lamp's STATIC world position, so the shadows are world-anchored
        var lmvp2: simd_float4x4    // (fixed in the level; only the headlamp / moving occluders change them)
        var eye: SIMD4<Float>       // xyz + gradeFlag
        var params: SIMD4<Float>    // lightCount, shadowLampCount, mapW, mapH
        var amb: SIMD4<Float>       // (unused rgb) + baked-field scale
        var headFwd: SIMD4<Float>   // view forward xyz + headlamp intensity
        var shX: SIMD4<Float>       // shadowed lamp CELL x for slices 0,1,2 (.w unused; -1 = none)
        var shZ: SIMD4<Float>       // shadowed lamp CELL z for slices 0,1,2 (.w unused; -1 = none)
        var camFwd: SIMD4<Float>    // TRUE camera forward (cos,0,sin) — the main pass writes perp-depth = dot(wp-eye, camFwd) so mesh creatures composite with correct occlusion
        var water: SIMD4<Float>     // M6 liquids: x = global flood level (lowest floor drowns) · yz = this level's puddle-field offset (World.waterOff) · w unused
    }
    typealias Light = GPURaymarch.GPULight   // posR=(x,y,z,1/r²)  colI=(rgb,intensity)

    // Overhead ceiling-lamp grid — the SINGLE source of truth for both buildMesh (housing + mask)
    // and the shader's injected constants, so lamp placement, the presence mask, and the analytic
    // light can never drift. Lamps sit at every OPEN cell where (x%stride==phase && y%stride==phase);
    // lamp world centre = cell+0.5, i.e. XZ ∈ {stride·k + phase + 0.5}. His "first rule": no magic numbers.
    static let lampGridStride = 4
    static let lampGridPhase  = 2
    static let lampPoolRadius: Float = 2.7
    static let lampLightY:     Float = 0.9
    static let lampIntensity:  Float = 3.9

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let mainPS: MTLRenderPipelineState
    private let shadowPS: MTLRenderPipelineState
    private let dss: MTLDepthStencilState
    private let colTex: MTLTexture
    private let zTex: MTLTexture
    private let perpTex: MTLTexture             // r32Float: per-pixel perp-depth (dot(wp-eye, camFwd)) so mesh creatures composite with correct occlusion
    private var perpScratch: [Float]            // CPU read-back of perpTex (W·H) — read ONCE per frame, for the particle compositor
    private let colSnap: MTLTexture             // the tonemapped frame BEFORE any creature drew (the creature fire-wash samples it)
    private let perpSnap: MTLTexture            // perpTex BEFORE any creature drew (the creature depth test samples it)
    /// Fall back to the pre-2026-07-28 creature merge: offscreen pass → flush → read colour+perp
    /// back → merge a million pixels on the CPU, per creature group. Kept because it is the ONLY
    /// way to prove the GPU path faithful (render both, diff the pixels — see CreatureMergeProbe),
    /// and because it is a working escape hatch if the direct path ever misbehaves on some GPU.
    /// `defaults write cc.jorviksoftware.Citadel creatureReadback -bool YES`.
    private let creatureReadback = UserDefaults.standard.bool(forKey: "creatureReadback")
    private let shadowArr: MTLTexture           // one depth slice per shadowed lamp (cast from the lamp's STATIC position)
    private let W = RenderConfig.width, H = RenderConfig.viewHeight, SHADOW = 1024
    private let SHADOW_LAMPS = 3                // nearest N overhead lamps get a real cast shadow

    private var vbuf: MTLBuffer?
    private var nVerts = 0
    private var fieldTex: MTLTexture?          // baked per-cell incident light (map.lightColor)
    private var lampMaskData: [UInt8] = []     // per-cell R8: 0 = solid wall · 128 = open · 255 = open + overhead lamp
    private var lampMaskTex: MTLTexture?       // ^ the fragment fetches this to find its lamps AND walk line-of-sight
    private var floorIdData: [UInt8] = []      // M6 per-cell R8: the FlatTex id of each open floor cell (nukage=3/rock=7/blood=8 drive the liquid treatment); 0 elsewhere
    private var floorIdTex: MTLTexture?        // ^ the floor fragment fetches this by integer cell to know whether it's toxic pool / pooling rock / flooded deck
    private var distTex: MTLTexture?           // rg32Float wall-distance field (.r) — the mesh-creature wall-clip trims limbs at wall faces
    private var mapW = 1, mapH = 1
    private var lampCells: [SIMD2<Float>] = [] // centres of the overhead ceiling lamps (even/even open cells)
    // The industrial floors (7–8) have NO ceiling strip grid: the plant is lit by wall BULKHEAD fixtures.
    // Honoured by buildMesh (housing + mask + lampCells) and by the shader's analytic lamp loop via Cam.water.w,
    // so lamp, housing, mask and light stay in lockstep exactly as the grid statics intend.
    private var ceilingLampsOn = true
    /// Wall-mounted bulkhead fixtures that light the PLANT floors (7–8), which carry no ceiling grid.
    /// Computed once per level (a whole-map walk); (mount on the wall, yaw so the lens faces the room, lens pos).
    private var plantLamps: [(pos: SIMD2<Float>, yaw: Float, light: SIMD2<Float>)] = []
    private var hallLamps: [SIMD3<Float>] = []  // downlights slung under the halls' roof trusses (see buildHallSteelwork)
    private var pipeVerts = 0                  // vertices the static pipework contributes (reported by the harness)
    private var machineVerts = 0               // vertices the static plant machinery contributes (reported by the harness)
    #if CITADEL_HARNESS
    var debugLightCap = -1                     // ≥0 → clamp the per-frame light list (CITADEL_GPUPROBE)
    static func machineKind(_ k: FurnitureKind) -> Bool { machineSpec(k) != nil }
    var staticVertCount: Int { nVerts }
    var machineVertCount: Int { machineVerts }
    #endif
    // ── FRAME BUDGET PROBE ── always TIMED (a handful of clock reads costs nothing), but only ever WRITTEN when
    // a frame misses its budget, and then only if `frameLog` is enabled. The point is not a running FPS number:
    // it is that when the game stutters we get told WHICH stage ate the frame, because guessing at a stutter
    // from a screenshot is hopeless. Rate-limited so one bad patch can't fill the disk.
    private var fpStamps: [(String, Double)] = []
    private var fpLastLog: Double = 0
    private var fpFrames = 0, fpSlow = 0
    private var fpWorst: Double = 0
    private var fpLogEnabled = UserDefaults.standard.bool(forKey: "frameLog")
    /// One 60 Hz refresh interval, plus a whisker so the clock reads themselves can't trip it. A frame
    /// that overruns this has already missed a vsync and been held for the next one — which IS the
    /// micro-stutter we're hunting, so that is where the threshold belongs. (The first cut of this
    /// probe used 20 ms; every frame between 16.7 and 20 dropped a vsync and went unreported.)
    private static let fpBudget = 1.0 / 60.0 + 0.0003     // 17.0 ms
    @inline(__always) private func fpMark(_ name: String) {
        guard fpLogEnabled else { return }
        fpStamps.append((name, ProcessInfo.processInfo.systemUptime))
    }
    /// Append a diagnostic line, off unless `defaults write cc.jorviksoftware.Citadel frameLog -bool YES`.
    /// Mirrors AudioEngine.alog: ~/Library/Logs/Citadel/frame.log.
    private func flog(_ msg: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Citadel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("frame.log")
        let line = Data(String(format: "%.3f  %@\n", ProcessInfo.processInfo.systemUptime, msg).utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: url) }
    }
    /// Close the frame: if it overran the budget, report the stage breakdown, worst offender first, with the
    /// scene counts that usually explain it. Also drops a periodic summary so a steady low frame rate — which
    /// never trips a single dramatic spike — still shows up.
    private func fpEnd(_ world: World) {
        guard fpLogEnabled, fpStamps.count > 1 else { fpStamps.removeAll(keepingCapacity: true); return }
        let t0 = fpStamps.first!.1, total = fpStamps.last!.1 - t0
        fpFrames += 1
        fpWorst = max(fpWorst, total)
        let now = ProcessInfo.processInfo.systemUptime
        if total > Self.fpBudget {
            fpSlow += 1
            if now - fpLastLog > 0.5 {                       // rate-limit: at most two reports a second
                fpLastLog = now
                var stages: [(String, Double)] = []
                for i in 1..<fpStamps.count { stages.append((fpStamps[i].0, fpStamps[i].1 - fpStamps[i - 1].1)) }
                let worst = stages.sorted { $0.1 > $1.1 }.prefix(4)
                    .map { String(format: "%@ %.1fms", $0.0, $0.1 * 1000) }.joined(separator: " · ")
                flog(String(format: "SLOW %.1fms (%.0f fps) — %@  [lvl %d · props %d verts · static %d · mons %d · parts %d · projs %d · lights %d]",
                            total * 1000, 1.0 / max(total, 1e-6), worst,
                            world.level, nDynVerts, nVerts, world.monsters.count,
                            world.particles.count, world.projectiles.count, Int(lastLightCount)))
            }
        }
        if fpFrames >= 600 {                                 // ~10 s at 60 fps: a periodic health line
            flog(String(format: "SUMMARY %d frames, %d slow (%.1f%%), worst %.1fms", fpFrames, fpSlow,
                        Double(fpSlow) / Double(fpFrames) * 100, fpWorst * 1000))
            fpFrames = 0; fpSlow = 0; fpWorst = 0
        }
        fpStamps.removeAll(keepingCapacity: true)
    }
    private var lastLightCount: Float = 0
    #if CITADEL_HARNESS
    var pipeVertCount: Int { pipeVerts }
    var totalVertCount: Int { nVerts }
    var dynVertCount: Int { nDynVerts }
    var dynCapacity: Int { dynCap }
    #endif
    // The level cache key must be a WEAK REFERENCE, never an ObjectIdentifier: an identifier outlives the
    // object it names, and a freed World's address is readily reused by the next one — so a stored identifier
    // could MATCH a brand-new level and skip prepareLevel, leaving the previous floor's mesh/floor-ids/light
    // field on screen. A weak ref goes nil when the old world dies, so a new level always rebuilds.
    private weak var lastWorld: World?

    private let dynBuf: MTLBuffer              // per-frame prop mesh (visible furniture/drums/sockets/mines/debris)
    private var dynScratch: [PVert] = []       // reusable CPU staging so the frame loop allocates nothing
    private let dynCap = 300_000               // max prop verts/frame (buffer sized once; overflow is dropped)
    private var nDynVerts = 0
    private let vmBuf: MTLBuffer               // per-frame first-person weapon viewmodel mesh (drawn as an always-on-top overlay)
    private var vmScratch: [PVert] = []
    private let vmCap = 20_000
    private var nVMVerts = 0
    // ── HDR pipeline: the whole raster frame renders to half-float, blooms, then tonemaps to 8-bit ──
    private let hdrTex: MTLTexture             // rgba16Float: the linear-HDR world + viewmodel (before fire/bloom/tonemap)
    private let fireHDR: MTLTexture            // rgba16Float: world + fire composited in HDR
    private let bloomA, bloomB: MTLTexture     // rgba16Float ping-pong for the bright-pass blur
    private let firePS, brightPS, blurPS, compositePS: MTLRenderPipelineState
    // ── particle billboards (smoke · embers · steam · sparks · flame) ──
    /// One quad per particle, built on the CPU so the projection is the SAME arithmetic the CPU
    /// compositor used (a re-derivation through the scene MVP would have drifted), then rasterised
    /// and blended by the GPU instead of splatting up to a quarter-viewport of pixels per particle
    /// through a Swift loop. `misc` carries the centre pixel + perp so the vertex stage can cull the
    /// whole sprite against the scene depth exactly as the CPU's single centre-sample test did.
    private struct SprVert {
        var clip: SIMD2<Float>       // NDC
        var local: SIMD2<Float>      // soft sprites: −1…1 across the quad · sparks: PIXELS from the glint
        var rgba: SIMD4<Float>       // linear-ish colour + centre alpha
        var misc: SIMD4<Float>       // x,y = centre pixel (clamped) · z = perp depth · w = mode
    }
    private static let sprCap = 6 * 4096          // 6 verts per particle; World never holds this many
    private let particlePS: MTLRenderPipelineState
    private let sprBuf: MTLBuffer
    private var sprScratch: [SprVert] = []
    private var nSprVerts = 0
    private struct FireU { var invVP: simd_float4x4; var eye, camFwd, misc: SIMD4<Float> }
    private struct Fx { var a: SIMD4<Float> }
    private let wallArrTex: MTLTexture?        // the baked wall-texture array (the SAME art the raymarcher samples) → textured walls

    // ── M4 creatures: the animated Tripo meshes (reused verbatim from the raymarch path;
    // they reproduce this renderer's camera exactly), composited over the lit world using
    // the perp-depth buffer above. Colonist corpse meshes are lazy-loaded per variant.
    private let meshQueen: MeshCreature?
    private let meshDrone: MeshCreature?
    private var colonistMeshes: [Int: MeshCreature] = [:]
    private var colonistTried: Set<Int> = []
    private let spriteCompositor = SpriteCompositor()   // M5: CPU billboards/particles (gibs/sparks/smoke/ash + projectiles) over the frame
    private var bedMesh: [PVert]?                        // imported Institutional Bed (bed.obj) → local-space PVerts, centred on XZ, base at y=0
    private var bedTried = false
    private var machineMeshes: [FurnitureKind: [PVert]] = [:]   // imported plant machinery, normalised to height 1
    private var machineTried: Set<FurnitureKind> = []
    private var bulkheadMesh: [PVert]?                   // imported wall bulkhead lamp (bulkhead.usdz) → local PVerts, centred at origin, ~0.3m
    private var bulkheadTried = false
    private var bedHalfLen: Float = 0                    // half-extent along the bed's LENGTH axis (game X), unscaled — for flush seating
    private let bedScale: Float = 0.55                   // ~0.90 m tall (1.63·0.55) → fits under the y=1 ceiling

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device; self.queue = queue
        guard let lib = try? device.makeLibrary(source: RasterRenderer.shaderSrc, options: nil) else {
            print("RasterRenderer: shader compile failed"); return nil
        }
        let mpd = MTLRenderPipelineDescriptor()
        mpd.vertexFunction = lib.makeFunction(name: "rr_vertex")
        mpd.fragmentFunction = lib.makeFunction(name: "rr_fragment")
        mpd.colorAttachments[0].pixelFormat = .rgba16Float       // LINEAR HDR (emissives/fire >1) — tonemapped in the final pass
        mpd.colorAttachments[1].pixelFormat = .r32Float          // perp-depth output (for the mesh-creature composite)
        mpd.depthAttachmentPixelFormat = .depth32Float
        let spd = MTLRenderPipelineDescriptor()
        spd.vertexFunction = lib.makeFunction(name: "rr_shadow_vertex")
        spd.fragmentFunction = nil
        spd.depthAttachmentPixelFormat = .depth32Float
        guard let mps = try? device.makeRenderPipelineState(descriptor: mpd),
              let sps = try? device.makeRenderPipelineState(descriptor: spd) else {
            print("RasterRenderer: pipeline failed"); return nil
        }
        self.mainPS = mps; self.shadowPS = sps
        let dd = MTLDepthStencilDescriptor(); dd.depthCompareFunction = .less; dd.isDepthWriteEnabled = true
        self.dss = device.makeDepthStencilState(descriptor: dd)!
        func tex(_ f: MTLPixelFormat, _ w: Int, _ h: Int, _ store: MTLStorageMode, _ u: MTLTextureUsage) -> MTLTexture {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: false)
            td.storageMode = store; td.usage = u; return device.makeTexture(descriptor: td)!
        }
        self.colTex = tex(.rgba8Unorm, W, H, .shared, [.renderTarget, .shaderRead])   // .shaderRead: the fire pass samples it as background
        self.zTex = tex(.depth32Float, W, H, .private, [.renderTarget])
        self.perpTex = tex(.r32Float, W, H, .shared, [.renderTarget, .shaderRead])    // .shaderRead: the fire pass reads it as tmax
        self.perpScratch = [Float](repeating: 1e9, count: W * H)
        // Pre-creature snapshots of the two buffers the creature passes WRITE. A render target
        // can't be sampled by the pass writing it, so the tonemap lands in colSnap and perpTex is
        // copied to perpSnap; the creature fragment reads those to test the world's depth and to
        // judge how much fire sits in the pixel. Two on-GPU copies replace what used to be four
        // megabytes of GPU→CPU transfer and a million-pixel CPU merge per creature group.
        self.colSnap  = tex(.rgba8Unorm, W, H, .private, [.renderTarget, .shaderRead])
        self.perpSnap = tex(.r32Float, W, H, .private, [.renderTarget, .shaderRead])
        // HDR pipeline — half-float targets + full-screen bloom/tonemap pipelines
        self.hdrTex  = tex(.rgba16Float, W, H, .private, [.renderTarget, .shaderRead])
        self.fireHDR = tex(.rgba16Float, W, H, .private, [.renderTarget, .shaderRead])
        self.bloomA  = tex(.rgba16Float, W, H, .private, [.renderTarget, .shaderRead])
        self.bloomB  = tex(.rgba16Float, W, H, .private, [.renderTarget, .shaderRead])
        guard let flib = try? device.makeLibrary(source: RasterRenderer.fireSrc, options: nil) else {
            print("RasterRenderer: fire shader compile failed"); return nil
        }
        func firePipe(_ frag: String, _ fmt: MTLPixelFormat) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = flib.makeFunction(name: "fs_vertex")
            d.fragmentFunction = flib.makeFunction(name: frag)
            d.colorAttachments[0].pixelFormat = fmt
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let fps = firePipe("fire_frag", .rgba16Float), let bps = firePipe("bright_frag", .rgba16Float),
              let blps = firePipe("blur_frag", .rgba16Float), let cps = firePipe("composite_frag", .rgba8Unorm) else {
            print("RasterRenderer: fire pipeline failed"); return nil
        }
        self.firePS = fps; self.brightPS = bps; self.blurPS = blps; self.compositePS = cps
        // ── PARTICLE BILLBOARDS ──
        // ONE pipeline serves both blend modes the smoke/ember/spark stack needs, because the shader
        // emits PREMULTIPLIED colour: src·1 + dst·(1−srcAlpha). Output alpha = coverage → ordinary
        // alpha blending (smoke, steam); output alpha = 0 → pure addition (flame, sparks). Two
        // pipelines would have forced the additive and alpha sprites into separate draws, and the
        // back-to-front order that alpha blending depends on would have been lost.
        guard let plib = try? device.makeLibrary(source: RasterRenderer.particleSrc, options: nil) else {
            print("RasterRenderer: particle shader compile failed"); return nil
        }
        let ppd = MTLRenderPipelineDescriptor()
        ppd.vertexFunction = plib.makeFunction(name: "spr_vertex")
        ppd.fragmentFunction = plib.makeFunction(name: "spr_frag")
        ppd.colorAttachments[0].pixelFormat = .rgba8Unorm
        ppd.colorAttachments[0].isBlendingEnabled = true
        ppd.colorAttachments[0].rgbBlendOperation = .add
        ppd.colorAttachments[0].alphaBlendOperation = .add
        ppd.colorAttachments[0].sourceRGBBlendFactor = .one            // premultiplied: the shader already scaled by alpha
        ppd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        ppd.colorAttachments[0].sourceAlphaBlendFactor = .one
        ppd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pps = try? device.makeRenderPipelineState(descriptor: ppd),
              let pbuf = device.makeBuffer(length: MemoryLayout<SprVert>.stride * RasterRenderer.sprCap,
                                           options: .storageModeShared) else {
            print("RasterRenderer: particle pipeline failed"); return nil
        }
        self.particlePS = pps; self.sprBuf = pbuf
        self.wallArrTex = GPURaymarch.makeTextureArray(device, Textures.shared.walls)   // baked wall art (textured walls)
        self.meshQueen = MeshCreature(device: device, kind: .queen)
        self.meshDrone = MeshCreature(device: device, kind: .drone)
        let sd = MTLTextureDescriptor()
        sd.textureType = .type2DArray; sd.pixelFormat = .depth32Float
        sd.width = SHADOW; sd.height = SHADOW; sd.arrayLength = SHADOW_LAMPS
        sd.storageMode = .private; sd.usage = [.renderTarget, .shaderRead]
        guard let sa = device.makeTexture(descriptor: sd) else { print("RasterRenderer: shadow array alloc failed"); return nil }
        self.shadowArr = sa
        guard let db = device.makeBuffer(length: MemoryLayout<PVert>.stride * 300_000, options: .storageModeShared) else {
            print("RasterRenderer: prop buffer alloc failed"); return nil
        }
        self.dynBuf = db
        guard let vb = device.makeBuffer(length: MemoryLayout<PVert>.stride * 20_000, options: .storageModeShared) else {
            print("RasterRenderer: viewmodel buffer alloc failed"); return nil
        }
        self.vmBuf = vb
    }

    // ── entry point (mirrors GPUWorldRenderer.render(_:into:)) ────────────────
    @discardableResult
    func render(_ world: World, into canvas: Canvas2D) -> Bool {
        fpMark("start")
        if lastWorld !== world { prepareLevel(world); lastWorld = world }
        fpMark("prepareLevel")
        guard let vbuf, nVerts > 0, let fieldTex, let lampMaskTex, let floorIdTex else {
            fpStamps.removeAll(keepingCapacity: true); return false      // a bailed frame must not leak its marks
        }

        // ── camera from the live player (matches the raymarcher's basis) ──
        let p = world.player
        var eye = SIMD3<Float>(p.pos.x, 0.5, p.pos.y)
        if world.rideShake > 0.001 {
            let t = world.elapsed, s = world.rideShake
            let lat = s * 0.006 * sinf(t * 47 + 1.7)
            eye.y += s * 0.010 * sinf(t * 34); eye.x += lat * -sinf(p.dir); eye.z += lat * cosf(p.dir)
        }
        if world.impactShake > 0.001 {
            let t = world.elapsed, s = world.impactShake * world.impactShake
            eye.y += s * 0.05 * sinf(t * 31)
            let lat = s * 0.02 * sinf(t * 23 + 0.9); eye.x += lat * -sinf(p.dir); eye.z += lat * cosf(p.dir)
        }

        // ── lights ──
        //  The overhead ceiling LAMPS are no longer in this list — they are computed ANALYTICALLY
        //  per-pixel in the shader from the regular grid + the presence mask, so a lamp's pool
        //  depends ONLY on the lamp cell and the surface, never on the player. That permanently
        //  kills the pop (every earlier attempt kept some player/view term in the selection).
        //  This CPU list now carries only the sparse wall/floor FIXTURES (Lighting.pointLights) —
        //  also player-independent: constant intensity, stable map-scan order, no cull/fade.
        var lights: [Light] = []
        for l in Lighting.pointLights(world.map) {
            let r = max(0.5, l.radius)
            lights.append(Light(posR: SIMD4(l.pos.x, l.pos.y, l.pos.z, 1 / (r * r)), colI: SIMD4(l.color, l.intensity)))
        }
        if lights.count > 48 { lights = Array(lights.prefix(48)) }         // reserve room for the transient FX lights below (stable-order, NEVER player-sorted)
        // M5: transient COMBAT lights (muzzle flash, flamethrower, blasts, burning pyres, projectiles) —
        // a pure function of `world`, so the same builder the raymarch path uses lights the raster world.
        let dynLights = GPUWorldRenderer.gatherDynLights(world)
        lights.append(contentsOf: dynLights)
        lastLightCount = Float(lights.count)
        // fuel-store bulkhead lights — warm, low-wattage, tight radius (the store has no overhead; these light it)
        for b in fuelBulkheads(world.map) {
            lights.append(GPURaymarch.GPULight(posR: SIMD4(b.light.x, 0.56, b.light.y, 1 / (2.2 * 2.2)),
                                               colI: SIMD4(1.0, 0.72, 0.40, 1.0)))
        }
        // NB: the door warning lamps are emissive geometry on the leaves (bloom only) — NO point light here, as the
        //     raster fixture lights are unshadowed and would leak amber through the closed door into the store.
        // PLANT floors (7–8): the bulkheads ARE the lighting (no ceiling grid), so surface the nearest few as real
        // point lights — nearest-first, since a whole floor's worth would blow the shader's light budget.
        if !plantLamps.isEmpty {
            let near = plantLamps.map { (simd_length($0.light - p.pos), $0) }
                                 .sorted { $0.0 < $1.0 }.prefix(10)
            for (_, b) in near {
                lights.append(GPURaymarch.GPULight(posR: SIMD4(b.light.x, 0.56, b.light.y, 1 / (3.4 * 3.4)),
                                                   colI: SIMD4(1.0, 0.74, 0.42, 1.35)))
            }
        }
        // the halls' truss downlights — a wider, cooler pool from above, so the double-height volume reads
        if !hallLamps.isEmpty {
            let near = hallLamps.map { (simd_length(SIMD2($0.x, $0.z) - p.pos), $0) }
                                .sorted { $0.0 < $1.0 }.prefix(6)
            for (_, l) in near {
                lights.append(GPURaymarch.GPULight(posR: SIMD4(l.x, l.y, l.z, 1 / (5.0 * 5.0)),
                                                   colI: SIMD4(0.94, 0.90, 0.80, 1.5)))
            }
        }
        if lights.count > 64 { lights = Array(lights.prefix(64)) }
        #if CITADEL_HARNESS
        // Harness only: clamp the light list so a probe can vary the fragment shader's light loop
        // INDEPENDENTLY of everything else. The frame log could never separate light count from
        // combat — they rise together, so the correlation there was suggestive and nothing more.
        if debugLightCap >= 0 { lights = Array(lights.prefix(debugLightCap)) }
        #endif
        if lights.isEmpty { lights = [Light(posR: SIMD4(0, -99, 0, 1), colI: SIMD4(0, 0, 0, 0))] }   // dummy so setFragmentBytes has length>0 (dr2>=1 skips it)
        // Shadows: the nearest overhead lamp CELLS select which lamps CAST (the selection may follow
        // the player, but pool BRIGHTNESS no longer does — the shadow only darkens up-facing surfaces,
        // never the analytic pool magnitude). Each slice's ortho geometry stays anchored to the lamp's
        // static cell; the shader matches a candidate lamp to its slice by exact integer cell equality.
        var near = lampCells.map { (simd_length($0 - p.pos), $0) }
        near.sort { $0.0 < $1.0 }
        let shadowN = min(SHADOW_LAMPS, near.count)
        var lmvps = [matrix_identity_float4x4, matrix_identity_float4x4, matrix_identity_float4x4]
        var shX = SIMD4<Float>(repeating: -1), shZ = SIMD4<Float>(repeating: -1)
        for k in 0..<shadowN {
            let c = near[k].1                                   // lamp centre (cellX+0.5, cellZ+0.5)
            lmvps[k] = lampShadowMVP(lampX: c.x, lampZ: c.y, half: 3.4)
            shX[k] = (c.x - 0.5).rounded(); shZ[k] = (c.y - 0.5).rounded()   // integer lamp cell for the shader match
        }
        let headFwd = simd_normalize(SIMD3<Float>(cos(p.dir), -0.4, sin(p.dir)))   // headlamp aimed slightly down (lights the floor ahead)
        let headInt: Float = FeatureFlags.headlamp ? 1.7 : 0                       // gentle assist (doesn't flood the pools); 0 → off
        let camFwd = SIMD3<Float>(cosf(p.dir), 0, sinf(p.dir))                     // TRUE camera forward (matches MeshCreature's fwd) → perp-depth
        // M5 aftermath decals (blood/scorch/papers/ash/offal) — world.decals (x,z,radius,w) fed to the
        // floor fragment; capped for the setFragmentBytes lane, dummy when empty so the bind has length>0.
        var decalArr: [SIMD4<Float>] = world.decals.isEmpty ? [SIMD4(0, -99, 0, 0)] : Array(world.decals.prefix(72))
        let nDecals = world.decals.isEmpty ? 0 : decalArr.count
        var cam = Cam(
            mvp: camMVP(eye: eye, dir: p.dir, near: 0.03, far: 64),
            lmvp0: lmvps[0], lmvp1: lmvps[1], lmvp2: lmvps[2],
            eye: SIMD4(eye, 1),
            params: SIMD4(Float(lights.count), Float(shadowN), Float(mapW), Float(mapH)),
            amb: SIMD4(Float(nDecals), world.elapsed, 0, 0.07),  // x = decal count · y = time (ash-ember flicker) · w = baked-field scale
            headFwd: SIMD4(headFwd, headInt),                   // the marine's headlamp — a broad pool, tilted DOWN to light footing
            shX: shX, shZ: shZ,                                 // shadowed lamp cells (integer) for the analytic loop's shadow match
            camFwd: SIMD4(camFwd, 0),
            water: SIMD4(Lighting.floodLevel(level: world.level), world.waterOff.x, world.waterOff.y,
                         ceilingLampsOn ? 1 : 0)   // M6: flood + puddle-field offset (matches the raymarch/CPU field) · w = ceiling-lamp grid on (0 on the plant floors)
        )

        // ── per-frame prop mesh: tessellate the visible furniture/drums/sockets/mines/debris
        dynScratch.removeAll(keepingCapacity: true)
        buildProps(world, into: &dynScratch)
        fpMark("buildProps")
        nDynVerts = min(dynScratch.count, dynCap)
        if dynScratch.count > dynCap {                     // silent truncation makes props pop as the camera turns
            print("RasterRenderer: prop buffer OVERFLOW — \(dynScratch.count) verts, cap \(dynCap); geometry dropped")
        }
        if nDynVerts > 0 {
            dynScratch.withUnsafeBytes { _ = memcpy(dynBuf.contents(), $0.baseAddress!, nDynVerts * MemoryLayout<PVert>.stride) }
        }
        // the marine's held weapon (first-person viewmodel) — tessellated at the eye anchor, drawn last as
        // an always-on-top overlay (pass 2b) so a near wall never eats it.
        vmScratch.removeAll(keepingCapacity: true)
        buildViewmodel(world, eye: eye, dir: p.dir, into: &vmScratch)
        fpMark("buildViewmodel")
        nVMVerts = min(vmScratch.count, vmCap)
        if nVMVerts > 0 {
            vmScratch.withUnsafeBytes { _ = memcpy(vmBuf.contents(), $0.baseAddress!, nVMVerts * MemoryLayout<PVert>.stride) }
        }

        // Which creatures will actually be drawn — decided BEFORE the command buffer opens, because
        // it determines where the tonemap lands (see the composite pass below).
        let vis = visibleCreatures(world, dir: p.dir)

        guard let cmd = queue.makeCommandBuffer() else { return false }

        // pass 1 — one shadow-depth slice per shadowed lamp, cast from its static position
        for k in 0..<shadowN {
            let srp = MTLRenderPassDescriptor()
            srp.depthAttachment.texture = shadowArr
            srp.depthAttachment.slice = k
            srp.depthAttachment.loadAction = .clear; srp.depthAttachment.storeAction = .store; srp.depthAttachment.clearDepth = 1.0
            guard let se = cmd.makeRenderCommandEncoder(descriptor: srp) else { continue }
            se.setRenderPipelineState(shadowPS); se.setDepthStencilState(dss); se.setCullMode(.none)
            se.setVertexBuffer(vbuf, offset: 0, index: 0)
            var lm = lmvps[k]
            se.setVertexBytes(&lm, length: MemoryLayout<simd_float4x4>.stride, index: 2)
            se.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: nVerts)
            if nDynVerts > 0 {                                    // props cast shadows too
                se.setVertexBuffer(dynBuf, offset: 0, index: 0)
                se.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: nDynVerts)
            }
            se.endEncoding()
        }
        // pass 2 — main PBR: baked ambient field + point lights + emission
        let mrp = MTLRenderPassDescriptor()
        mrp.colorAttachments[0].texture = hdrTex           // LINEAR HDR world target (bloomed + tonemapped → colTex below)
        mrp.colorAttachments[0].loadAction = .clear; mrp.colorAttachments[0].storeAction = .store
        mrp.colorAttachments[0].clearColor = MTLClearColor(red: 0.008, green: 0.009, blue: 0.013, alpha: 1)
        mrp.colorAttachments[1].texture = perpTex          // perp-depth for the mesh composite; cleared FAR so empty pixels never occlude a creature
        mrp.colorAttachments[1].loadAction = .clear; mrp.colorAttachments[1].storeAction = .store
        mrp.colorAttachments[1].clearColor = MTLClearColor(red: 1e9, green: 0, blue: 0, alpha: 0)
        mrp.depthAttachment.texture = zTex
        mrp.depthAttachment.loadAction = .clear; mrp.depthAttachment.storeAction = .dontCare; mrp.depthAttachment.clearDepth = 1.0
        if let me = cmd.makeRenderCommandEncoder(descriptor: mrp) {
            me.setRenderPipelineState(mainPS); me.setDepthStencilState(dss); me.setCullMode(.none)
            me.setVertexBuffer(vbuf, offset: 0, index: 0)
            me.setVertexBytes(&cam, length: MemoryLayout<Cam>.stride, index: 1)
            me.setFragmentBytes(&cam, length: MemoryLayout<Cam>.stride, index: 1)
            me.setFragmentBytes(&lights, length: MemoryLayout<Light>.stride * lights.count, index: 2)
            me.setFragmentBytes(&decalArr, length: MemoryLayout<SIMD4<Float>>.stride * decalArr.count, index: 3)   // aftermath decals
            me.setFragmentTexture(shadowArr, index: 0)
            me.setFragmentTexture(fieldTex, index: 1)
            me.setFragmentTexture(lampMaskTex, index: 2)   // analytic overhead lamp presence
            me.setFragmentTexture(floorIdTex, index: 3)    // M6 per-cell floor id → liquid surface treatment
            me.setFragmentTexture(wallArrTex, index: 4)    // baked wall-texture array → textured walls (display walls, lit panels)
            me.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: nVerts)
            if nDynVerts > 0 {                                    // the visible props, lit by the same forward pass
                me.setVertexBuffer(dynBuf, offset: 0, index: 0)
                me.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: nDynVerts)
            }
            me.endEncoding()
        }
        // full-screen pass helper (fire, bloom, tonemap) — a fixed 3-vertex triangle through a chosen pipeline
        func fullscreen(_ ps: MTLRenderPipelineState, to target: MTLTexture, _ setup: (MTLRenderCommandEncoder) -> Void) {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = target; rp.colorAttachments[0].loadAction = .dontCare; rp.colorAttachments[0].storeAction = .store
            guard let e = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
            e.setRenderPipelineState(ps); e.setCullMode(.none); setup(e)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); e.endEncoding()
        }
        // ── VOLUMETRIC FIRE ── the raymarcher's fireEmission over the lit HDR world (walls occlude via
        // perp-depth): bg·transmittance + emission → fireHDR. Runs BEFORE the gun + creatures so a corpse
        // reads over its own pyre; the whole HDR frame is bloomed + tonemapped below.
        let fireEmitters = GPURaymarch.gatherFireEmitters(world)
        if !fireEmitters.isEmpty {
            var fu = FireU(invVP: cam.mvp.inverse, eye: SIMD4(eye, world.elapsed),
                           camFwd: SIMD4(camFwd, 1.0), misc: SIMD4(Float(fireEmitters.count), Float(W), Float(H), 0))
            var emitters = fireEmitters
            fullscreen(firePS, to: fireHDR) { e in
                e.setFragmentBytes(&fu, length: MemoryLayout<FireU>.stride, index: 0)
                e.setFragmentBytes(&emitters, length: MemoryLayout<GPURaymarch.FireEmitter>.stride * emitters.count, index: 1)
                e.setFragmentTexture(hdrTex, index: 0); e.setFragmentTexture(perpTex, index: 1)
            }
        }
        let frame = fireEmitters.isEmpty ? hdrTex : fireHDR    // the current HDR frame (world, + fire if any)
        // pass 2b — the first-person weapon, drawn INTO the HDR frame (its emissives bloom too). Own cleared
        // depth so it self-occludes but a near wall never eats it; writes a near perp-depth so creatures stay behind.
        if nVMVerts > 0 {
            cam.amb.z = 1                                          // VIEWMODEL mode → the gun writes a negative (nearest) perp
            let vrp = MTLRenderPassDescriptor()
            vrp.colorAttachments[0].texture = frame;   vrp.colorAttachments[0].loadAction = .load;  vrp.colorAttachments[0].storeAction = .store
            vrp.colorAttachments[1].texture = perpTex; vrp.colorAttachments[1].loadAction = .load;  vrp.colorAttachments[1].storeAction = .store
            vrp.depthAttachment.texture = zTex; vrp.depthAttachment.loadAction = .clear; vrp.depthAttachment.storeAction = .dontCare; vrp.depthAttachment.clearDepth = 1.0
            if let ve = cmd.makeRenderCommandEncoder(descriptor: vrp) {
                ve.setRenderPipelineState(mainPS); ve.setDepthStencilState(dss); ve.setCullMode(.none)
                ve.setVertexBuffer(vmBuf, offset: 0, index: 0)
                ve.setVertexBytes(&cam, length: MemoryLayout<Cam>.stride, index: 1)
                ve.setFragmentBytes(&cam, length: MemoryLayout<Cam>.stride, index: 1)
                ve.setFragmentBytes(&lights, length: MemoryLayout<Light>.stride * lights.count, index: 2)
                ve.setFragmentBytes(&decalArr, length: MemoryLayout<SIMD4<Float>>.stride * decalArr.count, index: 3)
                ve.setFragmentTexture(shadowArr, index: 0)
                ve.setFragmentTexture(fieldTex, index: 1)
                ve.setFragmentTexture(lampMaskTex, index: 2)
                ve.setFragmentTexture(floorIdTex, index: 3)
                ve.setFragmentTexture(wallArrTex, index: 4)
                ve.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: nVMVerts)
                ve.endEncoding()
            }
        }
        // ── BLOOM + TONEMAP ── bright-pass the WHOLE HDR frame (emissive fixtures, plasma, LEDs + fire cores),
        // separable blur, then add the bloom and ACES-grade/gamma/vignette down to the 8-bit colTex.
        var bx = Fx(a: SIMD4(0, 0, Float(W), Float(H)))
        fullscreen(brightPS, to: bloomA) { e in e.setFragmentBytes(&bx, length: MemoryLayout<Fx>.stride, index: 0); e.setFragmentTexture(frame, index: 0) }
        var bh = Fx(a: SIMD4(1.0 / Float(W), 0, Float(W), Float(H)))
        fullscreen(blurPS, to: bloomB) { e in e.setFragmentBytes(&bh, length: MemoryLayout<Fx>.stride, index: 0); e.setFragmentTexture(bloomA, index: 0) }
        var bv = Fx(a: SIMD4(0, 1.0 / Float(H), Float(W), Float(H)))
        fullscreen(blurPS, to: bloomA) { e in e.setFragmentBytes(&bv, length: MemoryLayout<Fx>.stride, index: 0); e.setFragmentTexture(bloomB, index: 0) }
        var cx = Fx(a: SIMD4(0.7, 0, Float(W), Float(H)))                            // bloom gain (dialled back — less blown-out)
        // With creatures merging on the GPU the tonemap lands in colSnap, because the creature passes
        // both WRITE colTex and READ the pre-creature frame (a render target can't be sampled by the
        // pass writing it). Nothing to draw — or the legacy read-back path — → straight to colTex.
        let directCreatures = !vis.isEmpty && !creatureReadback
        fullscreen(compositePS, to: directCreatures ? colSnap : colTex) { e in
            e.setFragmentBytes(&cx, length: MemoryLayout<Fx>.stride, index: 0)
            e.setFragmentTexture(frame, index: 0); e.setFragmentTexture(bloomA, index: 1); e.setFragmentTexture(perpTex, index: 2)
        }
        fpMark("encode")
        // ── M4 creatures — rasterised STRAIGHT into the tonemapped frame, in THIS command buffer.
        // They used to render offscreen, flush the queue, copy colour + perp back to the CPU and merge
        // a million pixels by hand — per creature GROUP, so the cost stepped up and down with what was
        // in view and rotating on the spot juddered. Now: two on-GPU snapshot copies, then the passes
        // join the frame. fmain does the world-occlusion test and the fire wash itself, and every group
        // shares one depth buffer, so creature-vs-creature ordering is exact rather than merge-order.
        if directCreatures {
            if let blit = cmd.makeBlitCommandEncoder() {
                blit.copy(from: colSnap, to: colTex)       // carry the lit frame forward; creatures overwrite where they win
                blit.copy(from: perpTex, to: perpSnap)      // the depth they test against
                blit.endEncoding()
            }
            encodeCreatures(world, vis, into: .direct(cmd), eye: eye, dir: p.dir, dynLights: dynLights)
        }
        fpMark("creatures")          // CPU cost of posing + encoding them; their GPU cost lands in gpuWait
        // ── M5 particles ── smoke / steam / embers / sparks / flame, as GPU billboards over the
        // finished frame. This was the last CPU compositor: it splatted up to a quarter-viewport of
        // pixels per particle through a Swift loop, cost 1.0 ms at 20 particles rising to 7.2 ms at
        // 105, and every sub-20 ms breach in the 2026-07-29 frame log was this plus gpuWait.
        if !creatureReadback && !world.particles.isEmpty {
            sprScratch.removeAll(keepingCapacity: true)
            buildParticles(world, dir: p.dir, into: &sprScratch)
            nSprVerts = sprScratch.count
            if nSprVerts > 0 {
                sprScratch.withUnsafeBytes { _ = memcpy(sprBuf.contents(), $0.baseAddress!, nSprVerts * MemoryLayout<SprVert>.stride) }
                encodeParticles(cmd)
            }
        } else {
            nSprVerts = 0
        }
        fpMark("particles")
        cmd.commit(); cmd.waitUntilCompleted()
        fpMark("gpuWait")            // the CPU stalls here until the GPU has finished the whole frame

        colTex.getBytes(canvas.framebuffer, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        fpMark("readbackColour")     // the ONE transfer left: the finished frame, for Canvas2D to present

        // ── legacy CPU tail (creatureReadback only) ──
        // Both compositors move together: creatures merge on the CPU here, so the particles that layer
        // over them must too. On the default path nothing below runs and perpTex never comes back at all.
        // Each mark fires only when its work ran, so a stage in the log always cost what the log says.
        if creatureReadback && (!vis.isEmpty || !world.particles.isEmpty) {
            perpScratch.withUnsafeMutableBytes {
                perpTex.getBytes($0.baseAddress!, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
            }
            fpMark("readbackDepth")
            if !vis.isEmpty {
                perpScratch.withUnsafeMutableBufferPointer { dp in
                    encodeCreatures(world, vis, into: .readback(canvas, dp.baseAddress!),
                                    eye: eye, dir: p.dir, dynLights: dynLights)
                }
                fpMark("creaturesCPU")
            }
            if !world.particles.isEmpty {
                perpScratch.withUnsafeBufferPointer { dp in
                    spriteCompositor.overlayThings(world, into: canvas, depth: dp.baseAddress,
                                                   includeProjectiles: false,      // projectiles are emissive orb+streak meshes (buildProps)
                                                   includeDrums: false, includeSockets: false, includeMines: false)   // those are raster prop meshes
                }
                fpMark("particlesCPU")
            }
        }
        fpEnd(world)
        return true
    }

    /// Project every live particle to a screen-space quad.
    ///
    /// Deliberately the SAME arithmetic as `SpriteCompositor.drawParticle`: the sprite projection is
    /// the raycaster's (tX/tY, projHeight/tY, horizon), NOT the scene MVP, so re-deriving it through
    /// the MVP would have shifted every particle. Sorted back-to-front, because the smoke sprites
    /// alpha-blend and so are order-dependent (the flame and sparks add, which is commutative).
    private func buildParticles(_ world: World, dir: Float, into v: inout [SprVert]) {
        let p = world.player
        let dirX = cosf(dir), dirY = sinf(dir)
        let planeX = -sinf(dir) * RenderConfig.cameraPlane
        let planeY = cosf(dir) * RenderConfig.cameraPlane
        let invDet = 1 / (planeX * dirY - dirX * planeY)
        let horizon = Float(RenderConfig.horizon)
        let fw = Float(W), fh = Float(H)
        // ── OPEN QUESTION, deliberately left as a live knob ──
        // Dropping the CPU splat's load-shedding (see `r` below) restored the fire to its authored
        // size, which measured 1.562× the light the old path laid down under a heavy pyre — see
        // CreatureMergeProbe's "particles heavy" scene. Jonathan chose authored brightness on
        // 2026-07-29, with the caveat that more play-testing might want it pulled back, so the way
        // back is a knob rather than a re-derivation:
        //     defaults write cc.jorviksoftware.Citadel ParticleGain -float 0.55
        // measures 0.982 of the old brightness on that scene. Read every frame, so it can be dialled
        // while the game runs.
        //
        // Two things to know before trusting a number here. It is NOT 1/1.562 = 0.64: the additive
        // stack clips at 8 bits, so deposited light is not linear in alpha (0.64 measures 1.117).
        // Re-measure with the probe rather than computing a ratio. And it is a GLOBAL dimmer, not a
        // reproduction of the shed — the shed only bit when a frame's estimated blend load ran over
        // budget, so pulling this down also dims quiet scenes the old path never touched (gain 0.64
        // measures 0.794 on "particles light"). Predictable, but not the same curve.
        //
        // It dims rather than SHRINKS, which is the nicer half of what the shed did: the fire keeps
        // its authored size and simply burns less fiercely. If a play-test ever wants the smaller
        // fire back too, the lever for that is `r`, not this.
        let gain = (UserDefaults.standard.object(forKey: "ParticleGain") as? Double).map { Float($0) } ?? 1

        @inline(__always) func rgb(_ c: UInt32) -> SIMD3<Float> {
            SIMD3(Float(c & 0xFF), Float((c >> 8) & 0xFF), Float((c >> 16) & 0xFF)) / 255
        }
        @inline(__always) func lerp(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
            a + (b - a) * max(0, min(1, t))
        }
        /// One sprite: a pixel rect mapped to a local rect, plus the centre + depth used to cull it.
        func quad(px0: Float, py0: Float, px1: Float, py1: Float,
                  u0: Float, v0: Float, u1: Float, v1: Float,
                  rgba: SIMD4<Float>, mode: Float, cx: Float, cy: Float, perp: Float) {
            guard v.count + 6 <= RasterRenderer.sprCap else { return }
            func ndc(_ x: Float, _ y: Float) -> SIMD2<Float> { SIMD2(x / fw * 2 - 1, 1 - y / fh * 2) }
            let misc = SIMD4<Float>(min(max(cx, 0), fw - 1), min(max(cy, 0), fh - 1), perp, mode)
            let a = SprVert(clip: ndc(px0, py0), local: SIMD2(u0, v0), rgba: rgba, misc: misc)
            let b = SprVert(clip: ndc(px1, py0), local: SIMD2(u1, v0), rgba: rgba, misc: misc)
            let c = SprVert(clip: ndc(px1, py1), local: SIMD2(u1, v1), rgba: rgba, misc: misc)
            let d = SprVert(clip: ndc(px0, py1), local: SIMD2(u0, v1), rgba: rgba, misc: misc)
            v.append(a); v.append(b); v.append(c)
            v.append(a); v.append(c); v.append(d)
        }

        var order = world.particles.indices.map { ($0, simd_length_squared(world.particles[$0].pos - p.pos)) }
        order.sort { $0.1 > $1.1 }

        for (idx, _) in order {
            let pa = world.particles[idx]
            let rel = pa.pos - p.pos
            let tX = invDet * (dirY * rel.x - dirX * rel.y)
            let tY = invDet * (-planeY * rel.x + planeX * rel.y)
            if tY <= 0.15 { continue }
            let lineFull = Float(RenderConfig.projHeight) / tY
            let cx = fw / 2 * (1 + tX / tY)
            let cy = horizon + lineFull * 0.5 - lineFull * pa.height
            if cx < 0 || cx >= fw { continue }
            let lifeF = max(0, min(1, pa.life / pa.maxLife))
            // The viewH/4 radius cap is ARTISTIC — a near flame is meant to fill the view — and stays.
            // What has gone is the CPU path's `particleScale`, which shrank every radius when the frame's
            // estimated blend load ran over budget: graceful degradation for a Swift pixel loop that no
            // longer exists. Under a mine-into-drum chain the fire is now as big as it was authored.
            let r = max(1, min(lineFull * 0.05 * pa.size, fh / 4))

            if pa.fire && pa.color == 0 {
                // FLAME — additive, age-ramped white-hot → orange → deep red → soot, so overlapping
                // tongues build a body of fire. Same three anchors and same breakpoints as the CPU path.
                let age = 1 - lifeF
                let hot = rgb(packRGBA(255, 250, 210)), mid = rgb(packRGBA(255, 196, 70))
                let deep = rgb(packRGBA(232, 96, 26)), soot = rgb(packRGBA(60, 46, 44))
                let col: SIMD3<Float> = age < 0.25 ? lerp(hot, mid, age / 0.25)
                                      : age < 0.6  ? lerp(mid, deep, (age - 0.25) / 0.35)
                                                   : lerp(deep, soot, (age - 0.6) / 0.4)
                quad(px0: cx - r, py0: cy - r, px1: cx + r, py1: cy + r,
                     u0: -1, v0: -1, u1: 1, v1: 1,
                     rgba: SIMD4(col, (1 - age) * pa.maxAlpha * gain), mode: 1, cx: cx, cy: cy, perp: tY)
            } else if pa.fire {
                // SPARK — a tight glint plus a streak trailing UP behind its arc, so a burst reads as a
                // shower rather than a scatter of dots. Local coords are PIXELS: ±2 across, 8 up, 2 down.
                quad(px0: cx - 2, py0: cy - 8, px1: cx + 2, py1: cy + 2,
                     u0: -2, v0: -8, u1: 2, v1: 2,
                     rgba: SIMD4(rgb(pa.color), lifeF * pa.maxAlpha * gain), mode: 2, cx: cx, cy: cy, perp: tY)
            } else {
                // SMOKE / STEAM / ASH — soft, alpha-blended, fading with life.
                quad(px0: cx - r, py0: cy - r, px1: cx + r, py1: cy + r,
                     u0: -1, v0: -1, u1: 1, v1: 1,
                     rgba: SIMD4(rgb(pa.color), lifeF * pa.maxAlpha * gain), mode: 0, cx: cx, cy: cy, perp: tY)
            }
        }
    }

    /// Encode the particle billboards over the finished frame. They are the LAST layer, occluded by
    /// the world and by the creatures — both of which have written their perp-depth into perpTex by
    /// now, so one texture read per sprite settles visibility and nothing has to come back to the CPU.
    private func encodeParticles(_ cmd: MTLCommandBuffer) {
        guard nSprVerts > 0 else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = colTex
        rp.colorAttachments[0].loadAction = .load; rp.colorAttachments[0].storeAction = .store
        guard let e = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        e.setRenderPipelineState(particlePS)
        e.setCullMode(.none)
        e.setVertexBuffer(sprBuf, offset: 0, index: 0)
        e.setVertexTexture(perpTex, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: nSprVerts)
        e.endEncoding()
    }

    /// The creatures that will be drawn this frame. Pure selection, no GPU work — the frame needs
    /// the answer before it opens a command buffer, because an empty set means the tonemap can go
    /// straight to colTex and skip both snapshot copies.
    private struct VisibleCreatures {
        var queens: [Monster] = []
        var drones: [Monster] = []
        var colonists: [Colonist] = []
        var isEmpty: Bool { queens.isEmpty && drones.isEmpty && colonists.isEmpty }
    }

    private func visibleCreatures(_ world: World, dir: Float) -> VisibleCreatures {
        let p = world.player
        let fwd = SIMD2<Float>(cosf(dir), sinf(dir))
        // visible + capped creature set (nearest 10, Queen floated to front, behind-camera dropped)
        var cand: [(Monster, Float)] = []
        for m in world.monsters {
            let rel = m.pos - p.pos, d = simd_length(rel)
            if d > 32 { continue }
            if d > 2 && simd_dot(rel, fwd) < -0.5 { continue }
            cand.append((m, d))
        }
        cand.sort { a, b in
            let qa = (a.0.kind == .queen), qb = (b.0.kind == .queen)
            if qa != qb { return qa }
            return a.1 < b.1
        }
        let near = cand.prefix(10).map { $0.0 }
        var v = VisibleCreatures()
        v.queens = near.filter { $0.kind == .queen }
        v.drones = near.filter { $0.kind == .alien && !$0.gibbed }
        v.colonists = FeatureFlags.fallenColonists ? world.colonists.filter { c in
            guard c.variant >= 0 else { return false }
            let rel = c.pos - p.pos, ahead = rel.x * fwd.x + rel.y * fwd.y
            return ahead > -1.5 && (rel.x * rel.x + rel.y * rel.y) < 24 * 24
        } : []
        return v
    }

    /// Encode the mesh creatures (fallen colonists, then the queen, then the drone pack) into the
    /// caller's command buffer, rasterising straight into the tonemapped frame. Every group shares
    /// one depth buffer — cleared by whichever draws first — so creature-vs-creature occlusion is
    /// resolved per-pixel by the z-test instead of by the order the groups were merged in. The
    /// world-occlusion test and the fire wash happen in fmain against colSnap/perpSnap.
    /// Lit by the creature shader's own sector+camera fill plus the transient COMBAT lights only
    /// (nearest 12) — their baked `sector` already stands in for the room fixtures, so feeding
    /// those too would double-light them. Corpses render as well as the living.
    private enum CreatureMerge {
        case direct(MTLCommandBuffer)                              // join the frame's command buffer
        case readback(Canvas2D, UnsafeMutablePointer<Float>)        // legacy CPU merge (see creatureReadback)
    }

    private func encodeCreatures(_ world: World, _ vis: VisibleCreatures, into merge: CreatureMerge,
                                 eye: SIMD3<Float>, dir: Float, dynLights: [GPURaymarch.GPULight]) {
        let p = world.player
        let creatureLights = Array(dynLights.prefix(12))
        var first = true                       // the first DIRECT pass clears the shared depth buffer
        func frame() -> MeshCreature.Sink {
            switch merge {
            case .readback(let canvas, let depth): return .readback(canvas: canvas, depth: depth)
            case .direct(let cmd):
                defer { first = false }
                return .direct(MeshCreature.Frame(cmd: cmd, colour: colTex, perp: perpTex, zbuf: zTex,
                                                  colourSnapshot: colSnap, perpSnapshot: perpSnap, first: first))
            }
        }
        // fallen colonists first (deck layer), batched per variant
        for v in Set(vis.colonists.map { $0.variant }).sorted() {   // sorted: Set order is per-process random, so the group draw order would vary run to run
            guard let mesh = colonistMesh(v) else { continue }
            let insts = vis.colonists.filter { $0.variant == v }.map {
                MeshCreature.ColonistInst(pos: $0.pos, yaw: $0.yaw, seed: $0.seed, burn: $0.burn, ashed: $0.ashed,
                                          sector: WorldLight.lightAt(world.map, $0.pos.x, $0.pos.y))
            }
            mesh.compositeColonists(into: frame(), eye: eye, camDir: dir, instances: insts,
                                    lights: creatureLights, wallField: distTex, mapW: Float(mapW), mapH: Float(mapH))
        }
        // the mesh Queen(s)
        if let mc = meshQueen {
            for q in vis.queens {
                let death: Float
                if q.state == .dead { death = 1 }
                else if q.state == .dying { let f = min(1, (q.stateTime / World.queenDeathTime) / World.queenImpactT); death = f * f }
                else { death = 0 }
                mc.composite(into: frame(), eye: eye, dir: dir, pos: q.pos, faceTarget: p.pos,
                             sector: WorldLight.lightAt(world.map, q.pos.x, q.pos.y), time: world.elapsed, map: world.map,
                             death: death, burn: q.burn, ashed: q.ashed, lights: creatureLights, wallField: distTex, mapW: Float(mapW), mapH: Float(mapH))
            }
        }
        // the drone pack, one batched pass
        if let md = meshDrone, !vis.drones.isEmpty {
            let insts: [MeshCreature.DroneInst] = vis.drones.map { m in
                let death: Float
                if m.state == .dead { death = 1 }
                else if m.state == .dying { death = min(1, m.stateTime / World.droneDeathTime) }
                else { death = 0 }
                let move: Float
                switch m.state { case .chase: move = 1; case .pain: move = 0.5; case .attack: move = 0.35; default: move = 0 }
                let dissolve: Float = m.dissolving ? min(1, m.dissolveT / 1.8) : 0
                return MeshCreature.DroneInst(pos: m.pos, dir: m.dir, gait: m.animTime * 5.0, move: move, rear: m.rearAmt,
                                              dissolve: dissolve, seed: m.deathSeed, death: death, burn: m.burn, ashed: m.ashed,
                                              sector: WorldLight.lightAt(world.map, m.pos.x, m.pos.y))
            }
            md.compositeDrones(into: frame(), eye: eye, camDir: dir, instances: insts,
                               lights: creatureLights, wallField: distTex, mapW: Float(mapW), mapH: Float(mapH), map: world.map,
                               props: world.propColliders)
        }
    }

    /// Lazily-loaded, cached corpse mesh for a colonist variant (a failed load is remembered).
    private func colonistMesh(_ v: Int) -> MeshCreature? {
        if let m = colonistMeshes[v] { return m }
        if colonistTried.contains(v) { return nil }
        colonistTried.insert(v)
        guard v >= 0, v < Colonist.modelNames.count,
              let m = MeshCreature(device: device, kind: .colonist,
                                   meshOverride: Colonist.modelNames[v],
                                   texOverride: Colonist.modelNames[v] + "_basecolor",
                                   poseSeed: Float(v) * 1.7 + 0.3)
        else { return nil }
        colonistMeshes[v] = m
        return m
    }

    // ── per-level build: world mesh + baked light-field texture ───────────────
    private func prepareLevel(_ world: World) {
        // The imported bed is loaded from disk on first use, and its ONE caller is buildProps — so the
        // parse landed on whichever frame first had a bed in view, mid-play. The 2026-07-29 frame log
        // caught it as a 22.5 ms buildProps spike on 16k verts of geometry. Pull it forward: the cost
        // now lands with the level build, where a hitch is expected and unavoidable anyway.
        _ = loadBed()
        ceilingLampsOn = Progression.floorInBuilding(world.level) < 7   // 7–8 = the plant: bulkheads, not ceiling strips
        buildPlantLamps(world.map)
        buildMesh(world)
        mapW = world.map.w; mapH = world.map.h
        var lc = [SIMD4<Float>](repeating: .zero, count: mapW * mapH)
        for k in 0..<lc.count { let c = world.map.lightColor[k]; lc[k] = SIMD4(c.x, c.y, c.z, 1) }   // mirror liTex upload
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: mapW, height: mapH, mipmapped: false)
        d.usage = [.shaderRead]; d.storageMode = .managed
        let t = device.makeTexture(descriptor: d)
        lc.withUnsafeBytes { t?.replace(region: MTLRegionMake2D(0, 0, mapW, mapH), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: mapW * 16) }
        fieldTex = t
        // lamp-presence mask (R8) — the fragment fetches this by integer cell to find its own
        // overhead lamps analytically (no CPU per-frame selection → no player dependence → no pop).
        let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: mapW, height: mapH, mipmapped: false)
        md.usage = [.shaderRead]; md.storageMode = .managed
        let mt = device.makeTexture(descriptor: md)
        lampMaskData.withUnsafeBytes { mt?.replace(region: MTLRegionMake2D(0, 0, mapW, mapH), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: mapW) }
        lampMaskTex = mt
        // M6 floor-id mask (R8) — the floor fragment fetches this by integer cell to tell toxic pool
        // (nukage) / pooling rock / flooded deck apart, and give each the animated liquid surface.
        let fid = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Uint, width: mapW, height: mapH, mipmapped: false)
        fid.usage = [.shaderRead]; fid.storageMode = .managed
        let ft = device.makeTexture(descriptor: fid)
        floorIdData.withUnsafeBytes { ft?.replace(region: MTLRegionMake2D(0, 0, mapW, mapH), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: mapW) }
        floorIdTex = ft
        // wall-distance field (same builder the raymarcher uses) — the mesh-creature wall-clip samples
        // this (normalised by mapW/mapH) and discards fragments inside a wall, so a creature's swaying
        // limbs/tentacles are TRIMMED at a wall face instead of merging into a convex corner.
        let (df, sw, sh) = GPURaymarch.buildDistanceField(world.map)
        let dtd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: sw, height: sh, mipmapped: false)
        dtd.usage = [.shaderRead]; dtd.storageMode = .shared
        let dtt = device.makeTexture(descriptor: dtd)
        df.withUnsafeBytes { dtt?.replace(region: MTLRegionMake2D(0, 0, sw, sh), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: sw * 8) }
        distTex = dtt
    }

    private func buildMesh(_ world: World) {
        let map = world.map
        var v: [PVert] = []; v.reserveCapacity(map.w * map.h * 12)
        lampCells.removeAll(keepingCapacity: true)
        lampMaskData = [UInt8](repeating: 0, count: map.w * map.h)   // per-cell lamp-presence, stamped at the same site as the housing
        floorIdData = [UInt8](repeating: 0, count: map.w * map.h)     // M6 per-cell floor id (nukage/rock/blood drive the liquid treatment in the fragment)
        func openGeo(_ x: Int, _ y: Int) -> Bool {
            guard map.inBounds(x, y) else { return false }
            let i = map.idx(x, y); return map.wall[i] == 0 || map.doors[i] != nil
        }
        func vert(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ m: Mat, _ tid: Float = -1) -> PVert {
            PVert(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z,
                  ar: m.a.x, ag: m.a.y, ab: m.a.z, rough: m.r, metal: m.m, er: m.e.x, eg: m.e.y, eb: m.e.z, tid: tid)
        }
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ n: SIMD3<Float>, _ m: Mat, _ tid: Float = -1) {
            v += [vert(a, n, m, tid), vert(b, n, m, tid), vert(c, n, m, tid), vert(a, n, m, tid), vert(c, n, m, tid), vert(d, n, m, tid)]
        }
        // the solid wall id at a neighbour cell → the texture slice to sample (−1 = out of bounds)
        func wallIdF(_ x: Int, _ y: Int) -> Float { map.inBounds(x, y) ? Float(map.wall[map.idx(x, y)]) : -1 }
        // A floor/ceiling cell is emitted as an 8-triangle CENTRE FAN whose material is C0-continuous
        // across cell edges: corner verts carry the mean material of the 2×2 open cells meeting there,
        // edge-midpoints the mean of the two open cells sharing that edge, and only the CENTRE vert keeps
        // the cell's own pure material. Two neighbours therefore compute IDENTICAL shared-edge/corner
        // materials, so a lone darker flat (grate/metal patch) feathers into its surroundings over ~0.5 m
        // instead of meeting concrete at a razor grid line — the "hard dark quad on the floor". The centre
        // stays full-strength so the patch (and emissive floors' cores) still read. NO lighting is touched.
        func blendedSurface(_ mx: Int, _ my: Int, _ yy: Float, _ nrm: SIMD3<Float>, _ src: (Int) -> Int) {
            let own = flatMat(src(map.idx(mx, my)))
            let fx = Float(mx), fz = Float(my)
            func avg(_ cells: [(Int, Int)]) -> Mat {
                var a = SIMD3<Float>.zero, r: Float = 0, m: Float = 0, e = SIMD3<Float>.zero, n: Float = 0
                for (ox, oy) in cells where openGeo(ox, oy) {
                    let mt = flatMat(src(map.idx(ox, oy)))
                    a += mt.a; r += mt.r; m += mt.m; e += mt.e; n += 1
                }
                return n > 0 ? Mat(a: a / n, r: r / n, m: m / n, e: e / n) : own
            }
            let c00 = avg([(mx-1,my-1),(mx,my-1),(mx-1,my),(mx,my)])
            let c10 = avg([(mx,my-1),(mx+1,my-1),(mx,my),(mx+1,my)])
            let c11 = avg([(mx,my),(mx+1,my),(mx,my+1),(mx+1,my+1)])
            let c01 = avg([(mx-1,my),(mx,my),(mx-1,my+1),(mx,my+1)])
            let en = avg([(mx,my),(mx,my-1)]), ee = avg([(mx,my),(mx+1,my)])
            let es = avg([(mx,my),(mx,my+1)]), ew = avg([(mx,my),(mx-1,my)])
            let ring: [(SIMD3<Float>, Mat)] = [
                (SIMD3(fx,       yy, fz),       c00), (SIMD3(fx + 0.5, yy, fz),       en),
                (SIMD3(fx + 1,   yy, fz),       c10), (SIMD3(fx + 1,   yy, fz + 0.5), ee),
                (SIMD3(fx + 1,   yy, fz + 1),   c11), (SIMD3(fx + 0.5, yy, fz + 1),   es),
                (SIMD3(fx,       yy, fz + 1),   c01), (SIMD3(fx,       yy, fz + 0.5), ew),
            ]
            let ctr = SIMD3<Float>(fx + 0.5, yy, fz + 0.5)
            for k in 0..<8 {
                let (p0, m0) = ring[k], (p1, m1) = ring[(k + 1) % 8]
                v += [vert(ctr, nrm, own), vert(p0, nrm, m0), vert(p1, nrm, m1)]
            }
        }
        for y in 0..<map.h {
            for x in 0..<map.w where openGeo(x, y) {
                let i = map.idx(x, y), fx = Float(x), fz = Float(y)
                lampMaskData[i] = 128   // this cell is OPEN (128) — used by the shader's line-of-sight walk (solid cells stay 0); lamp cells are bumped to 255 below
                floorIdData[i] = UInt8(truncatingIfNeeded: map.floor[i])   // M6: the fragment reads this to give nukage/rock/blood cells the liquid surface
                // PER-CELL CEILING HEIGHT: a plant hall stands twice a storey while its corridors stay normal,
                // so walls rise to THIS cell's ceiling and the ceiling flat is emitted at that height.
                let ch = map.ceilY[i]
                blendedSurface(x, y, 0, SIMD3(0, 1, 0)) { map.floor[$0] }
                blendedSurface(x, y, ch, SIMD3(0, -1, 0)) { map.ceil[$0] }
                if !openGeo(x - 1, y) { quad(SIMD3(fx, 0, fz), SIMD3(fx, 0, fz + 1), SIMD3(fx, ch, fz + 1), SIMD3(fx, ch, fz), SIMD3(1, 0, 0), wallTexAt(map, x - 1, y), wallIdF(x - 1, y)) }
                if !openGeo(x + 1, y) { quad(SIMD3(fx + 1, 0, fz + 1), SIMD3(fx + 1, 0, fz), SIMD3(fx + 1, ch, fz), SIMD3(fx + 1, ch, fz + 1), SIMD3(-1, 0, 0), wallTexAt(map, x + 1, y), wallIdF(x + 1, y)) }
                if !openGeo(x, y - 1) { quad(SIMD3(fx + 1, 0, fz), SIMD3(fx, 0, fz), SIMD3(fx, ch, fz), SIMD3(fx + 1, ch, fz), SIMD3(0, 0, 1), wallTexAt(map, x, y - 1), wallIdF(x, y - 1)) }
                if !openGeo(x, y + 1) { quad(SIMD3(fx, 0, fz + 1), SIMD3(fx + 1, 0, fz + 1), SIMD3(fx + 1, ch, fz + 1), SIMD3(fx, ch, fz + 1), SIMD3(0, 0, -1), wallTexAt(map, x, y + 1), wallIdF(x, y + 1)) }
                // SOFFIT: where this cell's ceiling is HIGHER than an open neighbour's, close the step with a
                // vertical band from the neighbour's ceiling up to ours, facing INTO this cell — otherwise the
                // taller hall would open onto a gap above the corridor's ceiling slab and you'd see the void.
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nx = x + dx, ny = y + dy
                    guard openGeo(nx, ny) else { continue }                      // solid neighbours already got a full wall
                    let nch = map.inBounds(nx, ny) ? map.ceilY[map.idx(nx, ny)] : ch
                    guard ch - nch > 0.001 else { continue }
                    let sm = flatMat(map.ceil[i])                                 // the lower slab's own edge
                    if dx == -1 { quad(SIMD3(fx, nch, fz), SIMD3(fx, nch, fz + 1), SIMD3(fx, ch, fz + 1), SIMD3(fx, ch, fz), SIMD3(1, 0, 0), sm) }
                    if dx ==  1 { quad(SIMD3(fx + 1, nch, fz + 1), SIMD3(fx + 1, nch, fz), SIMD3(fx + 1, ch, fz), SIMD3(fx + 1, ch, fz + 1), SIMD3(-1, 0, 0), sm) }
                    if dy == -1 { quad(SIMD3(fx + 1, nch, fz), SIMD3(fx, nch, fz), SIMD3(fx, ch, fz), SIMD3(fx + 1, ch, fz), SIMD3(0, 0, 1), sm) }
                    if dy ==  1 { quad(SIMD3(fx, nch, fz + 1), SIMD3(fx + 1, nch, fz + 1), SIMD3(fx + 1, ch, fz + 1), SIMD3(fx, ch, fz + 1), SIMD3(0, 0, -1), sm) }
                }
                // overhead ceiling lamp (one per open cell on the grid — see the lamp* statics):
                // a VISIBLE glowing housing so the pools it casts have a source you can see, PLUS
                // the presence-mask bit AND (via the shared statics) the shader's analytic light —
                // all authored HERE so lamp / housing / mask / light can never drift apart.
                if ceilingLampsOn, x % Self.lampGridStride == Self.lampGridPhase && y % Self.lampGridStride == Self.lampGridPhase {
                    lampCells.append(SIMD2(fx + 0.5, fz + 0.5))
                    lampMaskData[i] = 255
                    let cx = fx + 0.5, cz = fz + 0.5, hs: Float = 0.26, y0: Float = ch - 0.015   // recessed into THIS cell's ceiling
                    let lm = Mat(a: SIMD3(0.80, 0.85, 0.95), r: 0.4, m: 0.0, e: WorldLight.lampColor * 3.4)   // bright recessed housing
                    quad(SIMD3(cx - hs, y0, cz - hs), SIMD3(cx - hs, y0, cz + hs), SIMD3(cx + hs, y0, cz + hs), SIMD3(cx + hs, y0, cz - hs), SIMD3(0, -1, 0), lm)
                }
            }
        }
        buildHallSteelwork(map, into: &v)     // roof trusses + slung downlights over the double-height halls
        buildWallFixtures(map, into: &v)      // wall bulkhead fixtures — static, and far too heavy to rebuild per frame
        let prePipe = v.count
        buildPipework(map, into: &v)          // copper wall runs + valves/gauges — static, so it lives in this mesh
        pipeVerts = v.count - prePipe
        let preMach = v.count
        buildMachines(world, into: &v)        // imported plant machinery — it never moves, so it is level geometry
        machineVerts = v.count - preMach
        if machineVerts > 0 || world.props.contains(where: { RasterRenderer.machineSpec($0.kind) != nil }) {
            let n = world.props.filter { RasterRenderer.machineSpec($0.kind) != nil }.count
            print("RasterRenderer: machinery — \(n) placed, \(machineVerts) static verts")
        }
        nVerts = v.count
        vbuf = v.isEmpty ? nil : device.makeBuffer(bytes: v, length: MemoryLayout<PVert>.stride * v.count)
    }

    /// ROOF STEELWORK over the double-height machine halls: lattice trusses spanning the hall high up, with
    /// downlights hung beneath them. Two jobs — it gives the eye something at height so the extra storey
    /// actually READS (an empty black void above you just looks like fog), and it explains the architecture:
    /// the corridors are a storey high because they run under this steel deck. Lamp positions are collected for
    /// render() to surface as point lights, so the halls are lit from above as well as by the wall bulkheads.
    private func buildHallSteelwork(_ map: GameMap, into v: inout [PVert]) {
        hallLamps.removeAll(keepingCapacity: true)
        guard !ceilingLampsOn else { return }              // plant floors only (they carry the tall halls)
        let steel  = M(SIMD3(0.30, 0.31, 0.34), 0.52, 0.72)
        let strut  = M(SIMD3(0.26, 0.27, 0.30), 0.56, 0.70)
        let shade  = M(SIMD3(0.22, 0.22, 0.24), 0.50, 0.60)
        let lampE  = M(SIMD3(0.95, 0.88, 0.72), 0.40, 0.0, SIMD3(2.3, 1.85, 1.15))   // the lit face, over-bright → blooms
        let chordTop: Float = 1.42, chordBot: Float = 1.24  // the truss sits high in the hall, clear of sightlines
        func tall(_ x: Int, _ y: Int) -> Bool {
            guard map.inBounds(x, y) else { return false }
            let i = map.idx(x, y); return map.wall[i] == 0 && map.doors[i] == nil && map.ceilY[i] > 1.5
        }
        // group the tall cells into halls (4-way flood fill) so each hall is trussed on its own axis
        var seen = [Bool](repeating: false, count: map.w * map.h)
        for y0 in 0..<map.h { for x0 in 0..<map.w where tall(x0, y0) && !seen[map.idx(x0, y0)] {
            var region: [(Int, Int)] = [], stack = [(x0, y0)]
            seen[map.idx(x0, y0)] = true
            var lo = (x0, y0), hi = (x0, y0)
            while let (cx, cy) = stack.popLast() {
                region.append((cx, cy))
                lo = (min(lo.0, cx), min(lo.1, cy)); hi = (max(hi.0, cx), max(hi.1, cy))
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = cx + dx, ny = cy + dy
                    guard tall(nx, ny), !seen[map.idx(nx, ny)] else { continue }
                    seen[map.idx(nx, ny)] = true; stack.append((nx, ny))
                }
            }
            let wide = hi.0 - lo.0 + 1, deep = hi.1 - lo.1 + 1
            guard min(wide, deep) >= 3, region.count >= 12 else { continue }   // a real hall, not a nook
            let inSet = Set(region.map { map.idx($0.0, $0.1) })
            // trusses SPAN the shorter dimension and repeat along the longer one
            let spanAlongX = wide <= deep
            let alongLo = spanAlongX ? lo.1 : lo.0, alongHi = spanAlongX ? hi.1 : hi.0
            var a = alongLo + 1
            var bay = 0
            while a <= alongHi - 1 {
                // the truss's extent across the hall on this line = the contiguous tall cells through it
                let mid = spanAlongX ? (lo.0 + hi.0) / 2 : (lo.1 + hi.1) / 2
                guard inSet.contains(map.idx(spanAlongX ? mid : a, spanAlongX ? a : mid)) else { a += 3; continue }
                var s = mid, e = mid
                while inSet.contains(map.idx(spanAlongX ? s - 1 : a, spanAlongX ? a : s - 1)) { s -= 1 }
                while inSet.contains(map.idx(spanAlongX ? e + 1 : a, spanAlongX ? a : e + 1)) { e += 1 }
                guard e - s >= 2 else { a += 3; continue }
                let c = Float(a) + 0.5, p0 = Float(s), p1 = Float(e + 1)
                let hw: Float = 0.055                                          // chord half-width
                // top + bottom chords
                if spanAlongX {
                    emitAABB(SIMD3(p0, chordTop - 0.035, c - hw), SIMD3(p1, chordTop + 0.035, c + hw), steel, into: &v)
                    emitAABB(SIMD3(p0, chordBot - 0.030, c - hw * 0.8), SIMD3(p1, chordBot + 0.030, c + hw * 0.8), steel, into: &v)
                } else {
                    emitAABB(SIMD3(c - hw, chordTop - 0.035, p0), SIMD3(c + hw, chordTop + 0.035, p1), steel, into: &v)
                    emitAABB(SIMD3(c - hw * 0.8, chordBot - 0.030, p0), SIMD3(c + hw * 0.8, chordBot + 0.030, p1), steel, into: &v)
                }
                // zig-zag web bracing between the chords — what makes it read as a truss, not two bars
                var t = p0
                var up = true
                while t < p1 - 0.001 {
                    let t2 = min(t + 0.5, p1)
                    let yA = up ? chordBot : chordTop, yB = up ? chordTop : chordBot
                    let pa = spanAlongX ? SIMD3<Float>(t, yA, c) : SIMD3<Float>(c, yA, t)
                    let pb = spanAlongX ? SIMD3<Float>(t2, yB, c) : SIMD3<Float>(c, yB, t2)
                    emitTube(pa, pb, r: 0.022, sides: 4, strut, caps: false, into: &v)
                    t = t2; up = !up
                }
                // every other bay carries a downlight slung under the truss
                if bay % 2 == 0 {
                    let lx = spanAlongX ? Float(s + e + 1) * 0.5 : c
                    let lz = spanAlongX ? c : Float(s + e + 1) * 0.5
                    let hangTop = chordBot, lampY: Float = chordBot - 0.16
                    emitTube(SIMD3(lx, hangTop, lz), SIMD3(lx, lampY + 0.05, lz), r: 0.012, sides: 5, strut, caps: false, into: &v)
                    emitAABB(SIMD3(lx - 0.10, lampY + 0.02, lz - 0.10), SIMD3(lx + 0.10, lampY + 0.07, lz + 0.10), shade, into: &v)
                    emitQuad(SIMD3(lx, lampY + 0.019, lz), SIMD3(0.085, 0, 0), SIMD3(0, 0, 0.085), SIMD3(0, -1, 0), lampE, into: &v)
                    hallLamps.append(SIMD3(lx, lampY, lz))
                }
                bay += 1
                a += 3                                                         // one truss every three cells
            }
        } }
    }

    /// A cast TEE: the main passes through a slightly fatter body, and the branch leaves it square. Real plant
    /// pipework never just abuts — a branch is taken off a tee, so this is what a junction must look like.
    private func emitTee(at p: SIMD3<Float>, run: SIMD3<Float>, branch: SIMD3<Float>, r: Float, _ body: Mat, into v: inout [PVert]) {
        emitTube(p - run * 0.052, p + run * 0.052, r: r * 1.34, sides: 9, body, caps: false, into: &v)   // the tee body on the main
        emitTube(p, p + branch * 0.055, r: r * 1.18, sides: 9, body, caps: false, into: &v)              // the branch socket
    }

    /// A 90° ELBOW: a fatter short sleeve on each leg where the two directions meet, so the corner reads as a
    /// cast fitting rather than two pipes mitred into each other.
    private func emitElbow(at p: SIMD3<Float>, legA: SIMD3<Float>, legB: SIMD3<Float>, r: Float, _ body: Mat, into v: inout [PVert]) {
        emitTube(p, p + legA * 0.055, r: r * 1.26, sides: 9, body, caps: false, into: &v)
        emitTube(p, p + legB * 0.055, r: r * 1.26, sides: 9, body, caps: false, into: &v)
    }

    /// WALL PIPEWORK — the copper runs the raymarcher draws in its SDF (`wallPipes` + `fittingsField`), ported
    /// to real geometry so the raster gets them too. Dimensions are taken from the kernel so both renderers
    /// agree: the run sits 0.10 off the wall face at (ceiling − 0.28), radius 0.038, with bolted flange collars
    /// where it turns square into the wall, plus the CPU-placed fittings from `map.pipeFittings` — a shut-off
    /// valve (tapered bonnet, rising stem, red-enamel handwheel) or a pressure gauge (stub + dial).
    /// Emitted into the STATIC mesh: pipework never moves, so it costs nothing per frame.
    private func buildPipework(_ map: GameMap, into v: inout [PVert]) {
        let copper = M(SIMD3(0.60, 0.35, 0.25), 0.44, 0.85)      // drawn copper, warm against the iron
        let flange = M(SIMD3(0.42, 0.26, 0.19), 0.52, 0.80)
        let steel  = M(SIMD3(0.34, 0.36, 0.40), 0.40, 0.80)
        let enamel = M(SIMD3(0.40, 0.045, 0.035), 0.34, 0.10)    // red-enamel handwheel
        let dialF  = M(SIMD3(0.82, 0.80, 0.74), 0.35, 0.05)
        // Pipework hangs at ONE height for the whole level — the standard storey less the kernel's 0.28 drop.
        // Keying it to each cell's own ceiling made a run jump a whole storey at a hall/corridor boundary and
        // let a fitting sit off its own run; a constant also matches the raymarcher (which uses a global ceilH).
        let pipeR: Float = 0.038, off: Float = 0.10, drop: Float = 0.28
        let runY: Float = 1.0 - drop
        func routed(_ x: Int, _ y: Int) -> Bool {
            guard map.inBounds(x, y) else { return false }
            let i = map.idx(x, y); return map.wall[i] == 0 && map.pipe[i] > 0.5
        }
        // A run is plumbed as a SPAN, not cell by cell. Emitting per-cell produced illogical plant: every tall
        // cell at the end of a stretch grew its own riser, so two risers could join the SAME pair of mains where
        // one is all that is needed. Group contiguous cells that share a wall into a span, then plumb the span
        // once: one continuous main, and exactly one riser feeding any high main.
        /// The wall a cell's run hugs — its FIRST solid neighbour in a fixed order, so every cell along a wall
        /// agrees and spans join up. (The kernel gets the same effect from distance-to-wall.)
        func wallOf(_ x: Int, _ y: Int) -> (Int, Int)? {
            guard routed(x, y) else { return nil }
            for (dx, dy) in [(0, -1), (0, 1), (-1, 0), (1, 0)] {
                let nx = x + dx, ny = y + dy
                guard map.inBounds(nx, ny), map.wall[map.idx(nx, ny)] != 0, map.doors[map.idx(nx, ny)] == nil else { continue }
                // Services are never run across the operations big board — nobody plumbs pipework over the
                // plot displays. The board wall is skipped, so the run either picks another wall or stops.
                if map.wall[map.idx(nx, ny)] == WallTex.opsBoard.rawValue { continue }
                return (dx, dy)
            }
            return nil
        }
        for (wdx, wdy) in [(0, -1), (0, 1), (-1, 0), (1, 0)] {
            let horiz = (wdy != 0)                                         // wall to N/S → the run travels along X
            let outer = horiz ? map.h : map.w                              // lines across the wall's normal
            let inner = horiz ? map.w : map.h                              // cells along the run
            for o in 0..<outer {
                var k = 0
                while k < inner {
                    func cell(_ t: Int) -> (Int, Int) { horiz ? (t, o) : (o, t) }
                    let (sx, sy) = cell(k)
                    guard let wd = wallOf(sx, sy), wd == (wdx, wdy) else { k += 1; continue }
                    var end = k                                            // extend while the same wall continues
                    while end + 1 < inner {
                        let (nx, ny) = cell(end + 1)
                        guard let nwd = wallOf(nx, ny), nwd == (wdx, wdy) else { break }
                        end += 1
                    }
                    defer { k = end + 1 }
                    let inward = SIMD2<Float>(-Float(wdx), -Float(wdy))    // wall → room
                    let axis = SIMD2<Float>(horiz ? 1 : 0, horiz ? 0 : 1)  // along the wall, increasing
                    let intoWall = SIMD3<Float>(-inward.x, 0, -inward.y)
                    // the wall face, pushed into the room; the span runs the full length of its cells
                    let fixedPos: SIMD2<Float> = horiz
                        ? SIMD2(0, wdy > 0 ? Float(o + 1) : Float(o))
                        : SIMD2(wdx > 0 ? Float(o + 1) : Float(o), 0)
                    func at(_ t: Float, _ lateral: Float) -> SIMD2<Float> {
                        let along = axis * t
                        return SIMD2(horiz ? along.x : fixedPos.x, horiz ? fixedPos.y : along.y) + inward * (off + lateral)
                    }
                    let t0 = Float(k), t1 = Float(end + 1)                 // outer edges of the first/last cell
                    /// One continuous service along the span, mitred square into the wall at both ends.
                    /// `sides` stays lean and caps are dropped where an end is buried in a wall or behind a
                    /// flange — pipework dominates the level mesh, so an invisible cap is pure cost.
                    func service(_ py: Float, _ r: Float, _ mat: Mat, _ lateral: Float, _ sides: Int) {
                        let a2 = at(t0, lateral), b2 = at(t1, lateral)
                        let a = SIMD3<Float>(a2.x, py, a2.y), b = SIMD3<Float>(b2.x, py, b2.y)
                        emitTube(a, b, r: r, sides: sides, mat, caps: false, into: &v)
                        for (pt, dir) in [(a, SIMD3<Float>(-axis.x, 0, -axis.y)), (b, SIMD3<Float>(axis.x, 0, axis.y))] {
                            let face = pt + intoWall * (off + lateral + 0.04)
                            emitTube(pt, face, r: r, sides: sides, mat, caps: false, into: &v)     // spur square into the wall
                            emitElbow(at: pt, legA: dir * -1, legB: intoWall, r: r, flange, into: &v)
                            emitTube(face - intoWall * 0.012, face + intoWall * 0.012, r: r * 1.6, sides: 8, flange, into: &v)
                        }
                    }
                    service(runY, pipeR, copper, 0, 10)                     // the copper main
                    service(runY - 0.105, pipeR * 0.66, steel, 0.012, 8)    // a thinner steel line beneath it
                    // HIGH MAIN: carried under a double-height hall's own ceiling, fed by ONE riser off the low
                    // main via a real tee, and terminating into the wall through an elbow at its far end.
                    var t = k
                    while t <= end {
                        let (cx, cy) = cell(t)
                        guard map.ceilY[map.idx(cx, cy)] > 1.5 else { t += 1; continue }
                        var hi = t
                        while hi + 1 <= end {
                            let (nx2, ny2) = cell(hi + 1)
                            guard map.ceilY[map.idx(nx2, ny2)] > 1.5 else { break }
                            hi += 1
                        }
                        let highY = map.ceilY[map.idx(cx, cy)] - drop
                        let hr = pipeR * 0.92, lateral: Float = 0.02
                        let riserT = Float(t) + 0.35                        // the single feed, just inside the hall
                        let hEnd = Float(hi + 1) - 0.06
                        if hEnd - riserT > 0.15 {
                            let r2 = at(riserT, lateral), e2 = at(hEnd, lateral)
                            let footY = runY, top = SIMD3<Float>(r2.x, highY, r2.y), foot = SIMD3<Float>(r2.x, footY, r2.y)
                            emitTube(foot, top, r: hr, sides: 9, copper, caps: false, into: &v)                       // the riser
                            emitTube(top, SIMD3(e2.x, highY, e2.y), r: hr, sides: 9, copper, caps: false, into: &v)    // the high main
                            let up = SIMD3<Float>(0, 1, 0), along = SIMD3<Float>(axis.x, 0, axis.y)
                            emitTee(at: SIMD3(r2.x, footY, r2.y), run: along, branch: up, r: pipeR, flange, into: &v)  // branch off the low main
                            emitElbow(at: top, legA: -up, legB: along, r: hr, flange, into: &v)                        // riser turns into the high main
                            let fEnd = SIMD3<Float>(e2.x, highY, e2.y)
                            emitTube(fEnd, fEnd + intoWall * (off + lateral + 0.04), r: hr, sides: 9, copper, caps: false, into: &v)
                            emitElbow(at: fEnd, legA: -along, legB: intoWall, r: hr, flange, into: &v)                 // and back into the wall
                        }
                        t = hi + 1
                    }
                }
            }
        }
        // ── FITTINGS (map.pipeFittings: x, z, outward-normal angle, kind 0 valve · 1 gauge) ──
        for f in map.pipeFittings {
            let cx = Int(f.x), cz = Int(f.y)
            guard map.inBounds(cx, cz) else { continue }
            let py = runY
            let n2 = SIMD2<Float>(cosf(f.z), sinf(f.z))                    // wall outward normal (into the room)
            let base = SIMD3<Float>(f.x, py, f.y)
            let outw = SIMD3<Float>(n2.x, 0, n2.y)
            if f.w < 0.5 {                                                 // ── SHUT-OFF VALVE ──
                emitTube(base + outw * 0.10, base + outw * 0.152, r: 0.032, sides: 10, copper, into: &v)   // tapered bonnet
                emitTube(base + outw * 0.150, base + outw * 0.196, r: 0.011, sides: 8, steel, into: &v)    // rising stem
                let hubC = base + outw * 0.19, rimR: Float = 0.052
                let t = SIMD3<Float>(-n2.y, 0, n2.x), up = SIMD3<Float>(0, 1, 0)
                let seg = 14                                                                              // handwheel RIM as a ring of chords
                var prev = hubC + t * rimR
                for k in 1...seg {
                    let ang = Float(k) / Float(seg) * 2 * Float.pi
                    let cur = hubC + t * (cosf(ang) * rimR) + up * (sinf(ang) * rimR)
                    emitTube(prev, cur, r: 0.0095, sides: 6, enamel, caps: false, into: &v)
                    prev = cur
                }
                for k in 0..<4 {                                                                          // four spokes
                    let ang = Float(k) / 4 * 2 * Float.pi
                    emitTube(hubC, hubC + t * (cosf(ang) * rimR) + up * (sinf(ang) * rimR), r: 0.007, sides: 6, enamel, into: &v)
                }
                emitTube(hubC - outw * 0.014, hubC + outw * 0.014, r: 0.014, sides: 8, steel, into: &v)    // stem nut
            } else {                                                       // ── PRESSURE GAUGE ──
                let stubTop = base + SIMD3<Float>(0, 0.09, 0)
                emitTube(base + outw * 0.10, stubTop + outw * 0.10, r: 0.013, sides: 8, copper, into: &v)  // stub up off the run
                let dialC = base + SIMD3<Float>(0, 0.105, 0) + outw * 0.10
                emitTube(dialC - outw * 0.016, dialC + outw * 0.016, r: 0.038, sides: 14, steel, into: &v) // dial body
                let t = SIMD3<Float>(-n2.y, 0, n2.x), up = SIMD3<Float>(0, 1, 0)
                emitEllipse(dialC + outw * 0.018, t, up, 0.031, 0.031, outw, dialF, into: &v)              // pale dial face
                emitTube(dialC + outw * 0.019, dialC + outw * 0.019 + t * 0.012 + up * 0.020, r: 0.0035, sides: 5,
                         M(SIMD3(0.08, 0.07, 0.06), 0.5, 0.1), into: &v)                                  // needle
            }
        }
    }

    /// Site the PLANT floors' bulkhead fixtures (7–8 only; the upper floors keep their ceiling grid). Walk a
    /// coarse grid of open cells and, where one backs onto a solid wall, hang a fixture on that wall facing into
    /// the room at eye height. Deliberately offset from the ceiling-lamp grid's phase so the two never coincide.
    private func buildPlantLamps(_ map: GameMap) {
        plantLamps.removeAll(keepingCapacity: true)
        guard !ceilingLampsOn else { return }
        let stride = 4, phase = 1                                   // one fixture per ~4 cells of wall run — enough to
                                                                    // navigate by; the plant stays deliberately gloomy
        for y in 1..<(map.h - 1) where y % stride == phase {
            for x in 1..<(map.w - 1) where x % stride == phase {
                let i = map.idx(x, y)
                guard map.wall[i] == 0, map.doors[i] == nil, !map.hazard[i] else { continue }
                for (dx, dy) in [(0, -1), (0, 1), (-1, 0), (1, 0)] {          // first solid neighbour = the mounting wall
                    let wx = x + dx, wy = y + dy
                    guard map.inBounds(wx, wy) else { continue }
                    let wi = map.idx(wx, wy)
                    guard map.wall[wi] != 0, map.doors[wi] == nil else { continue }
                    let inward = SIMD2<Float>(-Float(dx), -Float(dy))          // wall → room
                    let mount = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5) - inward * 0.46   // sit on the wall face
                    plantLamps.append((mount, atan2(-inward.x, inward.y), mount + inward * 0.16))
                    break
                }
            }
        }
    }

    private func wallTexAt(_ map: GameMap, _ x: Int, _ y: Int) -> Mat {
        guard map.inBounds(x, y) else { return wallMat(.steelPanel) }
        return wallMat(WallTex(rawValue: map.wall[map.idx(x, y)]) ?? .steelPanel)
    }

    // ── procedural PBR material tables (asset-light) ──────────────────────────
    struct Mat { var a: SIMD3<Float>; var r: Float; var m: Float; var e: SIMD3<Float> }
    private func M(_ a: SIMD3<Float>, _ r: Float, _ m: Float, _ e: SIMD3<Float> = .zero) -> Mat { Mat(a: a, r: r, m: m, e: e) }
    private func wallMat(_ t: WallTex) -> Mat {
        switch t {
        case .none:           return M(SIMD3(0.45, 0.45, 0.50), 0.60, 0.50)
        case .ironPlate:      return M(SIMD3(0.40, 0.35, 0.31), 0.66, 0.55)
        case .brushedSteel:   return M(SIMD3(0.56, 0.59, 0.66), 0.44, 0.75)
        case .steelPanel:     return M(SIMD3(0.38, 0.40, 0.46), 0.52, 0.62)
        case .litPanel:       return M(SIMD3(0.40, 0.44, 0.52), 0.45, 0.40, SIMD3(0.12, 0.26, 0.23))   // soft strip-light glow
        case .ribbedSteel:    return M(SIMD3(0.42, 0.44, 0.50), 0.50, 0.66)
        case .pipework:       return M(SIMD3(0.44, 0.46, 0.52), 0.34, 0.78)
        case .glass:          return M(SIMD3(0.14, 0.22, 0.28), 0.14, 0.25)
        case .stone:          return M(SIMD3(0.40, 0.36, 0.31), 0.90, 0.02)
        case .stoneSteel:     return M(SIMD3(0.36, 0.34, 0.31), 0.80, 0.22)
        case .computer:       return M(SIMD3(0.22, 0.26, 0.32), 0.50, 0.35, SIMD3(0.32, 0.24, 0.10))   // amber CRT
        case .hazard:         return M(SIMD3(0.52, 0.44, 0.12), 0.60, 0.35)
        case .doorPanel:      return M(SIMD3(0.44, 0.46, 0.50), 0.50, 0.60)
        case .doorRed:        return M(SIMD3(0.48, 0.16, 0.14), 0.55, 0.40, SIMD3(0.24, 0.03, 0.02))
        case .doorBlue:       return M(SIMD3(0.16, 0.24, 0.48), 0.55, 0.40, SIMD3(0.03, 0.06, 0.24))
        case .doorYellow:     return M(SIMD3(0.52, 0.46, 0.12), 0.55, 0.40, SIMD3(0.22, 0.18, 0.03))
        case .exitSwitch:     return M(SIMD3(0.20, 0.44, 0.24), 0.50, 0.30, SIMD3(0.10, 0.36, 0.16))   // green exit glow
        case .doorHazard:     return M(SIMD3(0.50, 0.44, 0.12), 0.60, 0.35)
        case .elevatorSealed: return M(SIMD3(0.40, 0.42, 0.47), 0.50, 0.60)
        case .liftWall:       return M(SIMD3(0.42, 0.44, 0.49), 0.50, 0.62)
        case .concrete:       return M(SIMD3(0.52, 0.51, 0.48), 0.92, 0.02)   // matte poured concrete — no metal, no glow
        case .opsBoard:       return M(SIMD3(0.05, 0.055, 0.065), 0.42, 0.20)   // dark glass; the RGB content is emissive (see rr_fragment)
        case .medWall:        return M(SIMD3(0.82, 0.83, 0.82), 0.68, 0.02)     // white painted concrete — bright, matte, sterile
        case .subwayTile:     return M(SIMD3(0.86, 0.87, 0.86), 0.24, 0.04)     // glazed ceramic — bright and a touch shiny
        case .sanTile:        return M(SIMD3(0.70, 0.78, 0.74), 0.20, 0.04)     // glazed pale green — wet-room shine
        }
    }
    private func flatMat(_ id: Int) -> Mat {
        switch FlatTex(rawValue: id) ?? .concrete {
        case .concrete:    return M(SIMD3(0.34, 0.33, 0.31), 0.85, 0.02)
        case .metalFloor:  return M(SIMD3(0.31, 0.31, 0.33), 0.55, 0.32)   // near-neutral, less metal so it doesn't crush to a dark blue patch vs concrete
        case .grate:       return M(SIMD3(0.23, 0.23, 0.24), 0.55, 0.45)   // dark IRON grate — clearly darker than concrete but not a blue void (also lifts tier-3/4 base floor)
        case .nukage:      return M(SIMD3(0.22, 0.34, 0.12), 0.30, 0.00, SIMD3(0.15, 0.36, 0.09))      // toxic glow
        case .ceilTech:    return M(SIMD3(0.17, 0.19, 0.23), 0.70, 0.32)
        case .ceilDark:    return M(SIMD3(0.10, 0.11, 0.13), 0.72, 0.22)
        case .ceilStone:   return M(SIMD3(0.30, 0.28, 0.25), 0.85, 0.02)
        case .ceilWhite:   return M(SIMD3(0.80, 0.81, 0.80), 0.60, 0.02, SIMD3(0.10, 0.10, 0.098))   // painted panels + a faint light run
        case .rock:        return M(SIMD3(0.32, 0.29, 0.25), 0.90, 0.00)
        case .blood:       return M(SIMD3(0.18, 0.05, 0.05), 0.40, 0.00)
        case .teleportPad: return M(SIMD3(0.20, 0.30, 0.50), 0.30, 0.20, SIMD3(0.16, 0.30, 0.62))      // teleporter glow
        }
    }

    // ══ prop meshing ═════════════════════════════════════════════════════════
    //  Tessellate the game's SDF prop DEFINITIONS (the [GShape] composites that the
    //  raymarcher blends) into triangles, so the rasteriser shows the SAME objects —
    //  drums, furniture, sockets, the reel-to-reel — reusing every prop's authored
    //  art for free. Each shape is decoded by its b.w sentinel (see GShape/iBox…iDisc):
    //    b.w < -3.5  Z-disc (cylinder along local +Z)   · b.w < -2.5  Y-cylinder
    //    b.w < -1.5  box (half-extents b.xyz)           · b.w < 0     sphere (r=a.w)
    //    b.w ≥ 0     round cone (A=a.xyz r1=a.w → B=b.xyz r2=b.w)
    //  Colours over 1.0 denote an emissive/bloom part (LEDs, charged sockets, screens).
    //  Winding is irrelevant — the passes cull .none — so only the NORMALS must be right.

    /// A GShape colour → PBR material. Over-bright (peak channel > 1) = a self-lit part
    /// (the raymarcher's emissive convention); otherwise the prop CLASS's rough/metal.
    private func propMat(_ col: SIMD3<Float>, _ rough: Float, _ metal: Float) -> Mat {
        let peak = max(col.x, max(col.y, col.z))
        if peak > 1.0 {                       // authored bloom → emissive fixture part
            let base = col / peak             // hue at unit brightness
            return M(base * 0.30, 0.40, 0.0, base * peak * 0.9)
        }
        return M(col, rough, metal)           // greasy industrial metal (grime added in-shader)
    }

    /// Tessellate one prop shape into `v`, mapping local→world with `xf` (position:
    /// yaw + translate) and `xn` (normal: yaw only). Emits per-vertex normals.
    private func tessShape(_ sh: GPURaymarch.GShape, rough: Float, metal: Float,
                           _ xf: (SIMD3<Float>) -> SIMD3<Float>,
                           _ xn: (SIMD3<Float>) -> SIMD3<Float>,
                           into v: inout [PVert]) {
        let m = propMat(SIMD3(sh.col.x, sh.col.y, sh.col.z), rough, metal)
        func push(_ lp: SIMD3<Float>, _ ln: SIMD3<Float>) {
            let p = xf(lp); let n = simd_normalize(xn(ln))
            v.append(PVert(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z,
                           ar: m.a.x, ag: m.a.y, ab: m.a.z, rough: m.r, metal: m.m, er: m.e.x, eg: m.e.y, eb: m.e.z))
        }
        func tri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                 _ na: SIMD3<Float>, _ nb: SIMD3<Float>, _ nc: SIMD3<Float>) { push(a, na); push(b, nb); push(c, nc) }
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ n: SIMD3<Float>) {
            tri(a, b, c, n, n, n); tri(a, c, d, n, n, n)
        }
        let c = SIMD3(sh.a.x, sh.a.y, sh.a.z), bw = sh.b.w
        if bw < -3.5 {                        // ── Z-disc: flat-capped cylinder along local +Z
            tessAxial(c, r: sh.a.w, half: sh.b.y, axis: SIMD3(0, 0, 1), rad1: SIMD3(1, 0, 0), rad2: SIMD3(0, 1, 0), tri: tri)
        } else if bw < -2.5 {                 // ── Y-cylinder: oil-drum axis
            tessAxial(c, r: sh.a.w, half: sh.b.y, axis: SIMD3(0, 1, 0), rad1: SIMD3(1, 0, 0), rad2: SIMD3(0, 0, 1), tri: tri)
        } else if bw < -1.5 {                 // ── box
            tessBox(c, h: SIMD3(sh.b.x, sh.b.y, sh.b.z), quad: quad)
        } else if bw < 0 {                    // ── sphere
            tessSphere(c, r: sh.a.w, tri: tri)
        } else {                              // ── round cone A(r1) → B(r2)
            tessCone(c, SIMD3(sh.b.x, sh.b.y, sh.b.z), r1: sh.a.w, r2: sh.b.w, tri: tri)
        }
    }

    private func tessBox(_ c: SIMD3<Float>, h: SIMD3<Float>,
                         quad: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) -> Void) {
        let x0 = c.x - h.x, x1 = c.x + h.x, y0 = c.y - h.y, y1 = c.y + h.y, z0 = c.z - h.z, z1 = c.z + h.z
        func P(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { SIMD3(x, y, z) }
        quad(P(x1, y0, z0), P(x1, y0, z1), P(x1, y1, z1), P(x1, y1, z0), SIMD3(1, 0, 0))
        quad(P(x0, y0, z1), P(x0, y0, z0), P(x0, y1, z0), P(x0, y1, z1), SIMD3(-1, 0, 0))
        quad(P(x0, y1, z0), P(x1, y1, z0), P(x1, y1, z1), P(x0, y1, z1), SIMD3(0, 1, 0))
        quad(P(x0, y0, z1), P(x1, y0, z1), P(x1, y0, z0), P(x0, y0, z0), SIMD3(0, -1, 0))
        quad(P(x1, y0, z1), P(x0, y0, z1), P(x0, y1, z1), P(x1, y1, z1), SIMD3(0, 0, 1))
        quad(P(x0, y0, z0), P(x1, y0, z0), P(x1, y1, z0), P(x0, y1, z0), SIMD3(0, 0, -1))
    }

    /// A CHAMFERED box — the 6 faces inset by `r` in their in-plane axes, joined by 12 bevel quads and 8
    /// corner tris (45° facets). Rounds off the razor edges/corners so a hand-carried weapon reads as worn
    /// steel, not a machined block. Winding is irrelevant (passes cull .none) — only the NORMALS matter.
    private func tessRoundBox(_ o: SIMD3<Float>, _ h: SIMD3<Float>, _ r0: Float,
                              quad: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) -> Void,
                              tri: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) -> Void) {
        let r = min(r0, min(h.x, min(h.y, h.z)) * 0.9)
        let ix = h.x - r, iy = h.y - r, iz = h.z - r
        func P(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { SIMD3(o.x + x, o.y + y, o.z + z) }
        let S: [Float] = [-1, 1]
        for s in S {                                                     // 6 inset faces
            quad(P(s*h.x,-iy,-iz), P(s*h.x,iy,-iz), P(s*h.x,iy,iz), P(s*h.x,-iy,iz), SIMD3(s,0,0))
            quad(P(-ix,s*h.y,-iz), P(ix,s*h.y,-iz), P(ix,s*h.y,iz), P(-ix,s*h.y,iz), SIMD3(0,s,0))
            quad(P(-ix,-iy,s*h.z), P(ix,-iy,s*h.z), P(ix,iy,s*h.z), P(-ix,iy,s*h.z), SIMD3(0,0,s))
        }
        let q: Float = 0.70710678
        for a in S { for b in S {                                        // 12 edge bevels (45°)
            quad(P(a*h.x,b*iy,-iz), P(a*h.x,b*iy,iz), P(a*ix,b*h.y,iz), P(a*ix,b*h.y,-iz), SIMD3(a*q,b*q,0))   // along Z
            quad(P(a*h.x,-iy,b*iz), P(a*h.x,iy,b*iz), P(a*ix,iy,b*h.z), P(a*ix,-iy,b*h.z), SIMD3(a*q,0,b*q))   // along Y
            quad(P(-ix,a*h.y,b*iz), P(ix,a*h.y,b*iz), P(ix,a*iy,b*h.z), P(-ix,a*iy,b*h.z), SIMD3(0,a*q,b*q))   // along X
        } }
        let u: Float = 0.57735027
        for a in S { for b in S { for c in S {                           // 8 corner tris
            tri(P(a*h.x,b*iy,c*iz), P(a*ix,b*h.y,c*iz), P(a*ix,b*iy,c*h.z),
                SIMD3(a*u,b*u,c*u), SIMD3(a*u,b*u,c*u), SIMD3(a*u,b*u,c*u))
        } } }
    }

    private func tessSphere(_ c: SIMD3<Float>, r: Float,
                            tri: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) -> Void) {
        let LON = 12, LAT = 8, tau = 2 * Float.pi
        func nrm(_ la: Int, _ lo: Int) -> SIMD3<Float> {
            let ph = Float(la) / Float(LAT) * Float.pi, s = Float(lo) / Float(LON) * tau
            return SIMD3(sinf(ph) * cosf(s), cosf(ph), sinf(ph) * sinf(s))
        }
        for la in 0..<LAT { for lo in 0..<LON {
            let n00 = nrm(la, lo), n01 = nrm(la, lo + 1), n10 = nrm(la + 1, lo), n11 = nrm(la + 1, lo + 1)
            tri(c + r * n00, c + r * n01, c + r * n11, n00, n01, n11)
            tri(c + r * n00, c + r * n11, c + r * n10, n00, n11, n10)
        } }
    }

    /// A flat-capped cylinder about an arbitrary local `axis` (with `rad1`,`rad2` the
    /// two unit directions spanning the circular cross-section). Serves both the
    /// Y-cylinder (drums) and the Z-disc (reel faces) — same body, different axis.
    private func tessAxial(_ c: SIMD3<Float>, r: Float, half: Float,
                           axis: SIMD3<Float>, rad1: SIMD3<Float>, rad2: SIMD3<Float>,
                           tri: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) -> Void) {
        let SEG = 18, tau = 2 * Float.pi
        let cb = c - axis * half, ct = c + axis * half   // bottom/top cap centres
        func rd(_ s: Int) -> SIMD3<Float> { let a = Float(s) / Float(SEG) * tau; return cosf(a) * rad1 + sinf(a) * rad2 }
        for s in 0..<SEG {
            let d0 = rd(s), d1 = rd(s + 1)
            let b0 = cb + r * d0, b1 = cb + r * d1, t0 = ct + r * d0, t1 = ct + r * d1
            tri(b0, b1, t1, d0, d1, d1); tri(b0, t1, t0, d0, d1, d0)   // side (radial normals)
            tri(ct, t0, t1, axis, axis, axis)                          // top cap (+axis)
            tri(cb, b1, b0, -axis, -axis, -axis)                       // bottom cap (−axis)
        }
    }

    private func tessCone(_ A: SIMD3<Float>, _ B: SIMD3<Float>, r1: Float, r2: Float,
                          tri: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) -> Void) {
        let ab = B - A, L = simd_length(ab)
        let axis = L > 1e-5 ? ab / L : SIMD3<Float>(0, 1, 0)
        let up = abs(axis.y) < 0.99 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        let u = simd_normalize(simd_cross(up, axis)), vv = simd_cross(axis, u)
        let slope = L > 1e-5 ? (r2 - r1) / L : 0
        let SEG = 14, tau = 2 * Float.pi
        func rd(_ s: Int) -> SIMD3<Float> { let a = Float(s) / Float(SEG) * tau; return cosf(a) * u + sinf(a) * vv }
        for s in 0..<SEG {
            let d0 = rd(s), d1 = rd(s + 1)
            let a0 = A + r1 * d0, a1 = A + r1 * d1, b0 = B + r2 * d0, b1 = B + r2 * d1
            let n0 = simd_normalize(d0 - axis * slope), n1 = simd_normalize(d1 - axis * slope)   // slope-corrected side normal
            tri(a0, a1, b1, n0, n1, n1); tri(a0, b1, b0, n0, n1, n0)
            if r1 > 1e-4 { tri(A, a1, a0, -axis, -axis, -axis) }
            if r2 > 1e-4 { tri(B, b0, b1, axis, axis, axis) }
        }
    }

    // ══ first-person weapon viewmodel ════════════════════════════════════════
    //  Reuses the SHARED gun geometry (Viewmodel.pack → gun-local GShapes, x=right y=up z=forward),
    //  so the raster gun is the SAME model the raymarcher marches. Tessellated at the eye anchor and
    //  drawn in pass 2b as an always-on-top overlay, lit by the world's PBR pass.

    /// Tessellate the held weapon at its eye-anchored transform into `v`. Hidden when the marine is down.
    private func buildViewmodel(_ world: World, eye: SIMD3<Float>, dir: Float, into v: inout [PVert]) {
        guard !world.player.dead else { return }
        let vm = Viewmodel.pack(player: world.player, time: world.elapsed)
        let rU = SIMD3<Float>(-sinf(dir), 0, cosf(dir))     // gun-local +x → world right
        let up = SIMD3<Float>(0, 1, 0)                      // gun-local +y → world up
        let fU = SIMD3<Float>(cosf(dir), 0, sinf(dir))      // gun-local +z → world forward
        let anchor = eye + fU * Viewmodel.anchorFwd + rU * Viewmodel.anchorRight - up * Viewmodel.anchorDown
        let xf: (SIMD3<Float>) -> SIMD3<Float> = { l in anchor + rU * l.x + up * l.y + fU * l.z }
        let xn: (SIMD3<Float>) -> SIMD3<Float> = { n in rU * n.x + up * n.y + fU * n.z }
        for sh in vm.shapes { tessVMShape(sh, xf, xn, into: &v) }
    }

    /// Tessellate ONE viewmodel GShape. Unlike tessShape (props), a glow sphere (b.w=-5) is a real
    /// emissive sphere, and the cylinder/glow `em` term drives self-illumination (the prop path keys
    /// emission off colour>1 only) — so the plasma cell, LEDs, pilot flame and muzzle flash bloom.
    private func tessVMShape(_ sh: GPURaymarch.GShape,
                             _ xf: (SIMD3<Float>) -> SIMD3<Float>,
                             _ xn: (SIMD3<Float>) -> SIMD3<Float>,
                             into v: inout [PVert]) {
        let col = SIMD3(sh.col.x, sh.col.y, sh.col.z), bw = sh.b.w
        var em: Float = 0                                    // emission gain: glow packs it in b.x, cylinders in b.z
        if bw < -4.5 { em = sh.b.x } else if bw < -2.5 { em = sh.b.z }
        let peak = max(col.x, max(col.y, col.z))
        let m: Mat
        if em > 0.001 || peak > 1.0 {                        // self-lit part → low albedo + HDR emission
            let base = peak > 1e-3 ? col / peak : col
            let gain = max(em, peak > 1 ? peak : 0)
            m = M(base * 0.25, 0.40, 0.0, base * gain * 0.9)
        } else {
            m = M(col, 0.34, 0.55)                           // gunmetal: semi-glossy, fairly metallic
        }
        func push(_ lp: SIMD3<Float>, _ ln: SIMD3<Float>) {
            let p = xf(lp); let n = simd_normalize(xn(ln))
            v.append(PVert(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z,
                           ar: m.a.x, ag: m.a.y, ab: m.a.z, rough: m.r, metal: m.m, er: m.e.x, eg: m.e.y, eb: m.e.z))
        }
        func tri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                 _ na: SIMD3<Float>, _ nb: SIMD3<Float>, _ nc: SIMD3<Float>) { push(a, na); push(b, nb); push(c, nc) }
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ n: SIMD3<Float>) {
            tri(a, b, c, n, n, n); tri(a, c, d, n, n, n)
        }
        let c = SIMD3(sh.a.x, sh.a.y, sh.a.z)
        if bw < -4.5 {                                       // glow → emissive sphere
            tessSphere(c, r: sh.a.w, tri: tri)
        } else if bw < -3.5 {                                // z-cylinder (barrel / coils / nozzle) — axis +Z
            tessAxial(c, r: sh.a.w, half: sh.b.y, axis: SIMD3(0, 0, 1), rad1: SIMD3(1, 0, 0), rad2: SIMD3(0, 1, 0), tri: tri)
        } else if bw < -2.5 {                                // y-cylinder (fuel tank / cell housing) — axis +Y
            tessAxial(c, r: sh.a.w, half: sh.b.y, axis: SIMD3(0, 1, 0), rad1: SIMD3(1, 0, 0), rad2: SIMD3(0, 0, 1), tri: tri)
        } else if bw < -1.5 {                                // box → CHAMFERED (a hand-carried weapon has worn, rounded edges)
            let hb = SIMD3(sh.b.x, sh.b.y, sh.b.z)
            tessRoundBox(c, hb, min(hb.x, min(hb.y, hb.z)) * 0.32, quad: quad, tri: tri)
        } else if bw < 0 {                                   // sphere
            tessSphere(c, r: sh.a.w, tri: tri)
        } else {                                             // round cone A(r1) → B(r2)
            tessCone(c, SIMD3(sh.b.x, sh.b.y, sh.b.z), r1: sh.a.w, r2: sh.b.w, tri: tri)
        }
    }

    // ── per-frame prop mesh: the visible set, tessellated fresh each frame ─────
    //  Props can't bake into the static level mesh — mines are deployed at runtime,
    //  drums rupture, sockets/decks change state, the signal reels spin. So gather the
    //  visible instances each frame (cheap: a few dozen objects) and rebuild the dynamic
    //  buffer, which draws in the SAME shadow+main passes → props cast/receive the pools.

    private func rrShapeYExtent(_ s: GPURaymarch.GShape) -> (Float, Float) {
        let a = s.a, b = s.b
        if b.w < -3.5 { return (a.y - a.w, a.y + a.w) }               // z-disc: radius a.w spans Y
        if b.w < -2.5 { return (a.y - b.y, a.y + b.y) }               // Y-cylinder: half-height b.y
        if b.w < -1.5 { return (a.y - b.y - a.w, a.y + b.y + a.w) }   // box
        if b.w < 0    { return (a.y - a.w, a.y + a.w) }               // sphere
        return (min(a.y - a.w, b.y - b.w), max(a.y + a.w, b.y + b.w)) // cone
    }
    private func rrShapeZExtent(_ s: GPURaymarch.GShape) -> (Float, Float) {
        let a = s.a, b = s.b
        if b.w < -3.5 { return (a.z - b.y, a.z + b.y) }               // z-disc: half-length b.y along Z
        if b.w < -2.5 { return (a.z - a.w, a.z + a.w) }               // Y-cylinder: radius a.w
        if b.w < -1.5 { return (a.z - b.z - a.w, a.z + b.z + a.w) }   // box
        if b.w < 0    { return (a.z - a.w, a.z + a.w) }               // sphere
        return (min(a.z - a.w, b.z - b.w), max(a.z + a.w, b.z + b.w)) // cone
    }
    /// Shove a wall piece back so its rear face sits flush at local −wallBack (mirrors
    /// GPURaymarch.flushToWall — private there, so replicated here to match exactly).
    private func rrFlushToWall(_ shapes: inout [GPURaymarch.GShape], wallBack: Float = 0.46) {
        var minZ: Float = 1e9
        for s in shapes { minZ = min(minZ, rrShapeZExtent(s).0) }
        let dz = -wallBack - minZ
        for i in shapes.indices { shapes[i].a.z += dz; if shapes[i].b.w >= 0 { shapes[i].b.z += dz } }
    }

    /// Emit an axis-aligned box [lo,hi] with flat outward normals and material `m`. Winding is
    /// irrelevant (the passes cull .none) — only the NORMALS must point out. Used for door leaves.
    private func emitAABB(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>, _ m: Mat, tid: Float = -1, into v: inout [PVert]) {
        func vert(_ p: SIMD3<Float>, _ n: SIMD3<Float>) -> PVert {
            PVert(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z,
                  ar: m.a.x, ag: m.a.y, ab: m.a.z, rough: m.r, metal: m.m, er: m.e.x, eg: m.e.y, eb: m.e.z, tid: tid)
        }
        func face(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ n: SIMD3<Float>) {
            v += [vert(a, n), vert(b, n), vert(c, n), vert(a, n), vert(c, n), vert(d, n)]
        }
        let x0 = lo.x, y0 = lo.y, z0 = lo.z, x1 = hi.x, y1 = hi.y, z1 = hi.z
        face(SIMD3(x0, y0, z1), SIMD3(x1, y0, z1), SIMD3(x1, y1, z1), SIMD3(x0, y1, z1), SIMD3(0, 0, 1))    // +Z
        face(SIMD3(x1, y0, z0), SIMD3(x0, y0, z0), SIMD3(x0, y1, z0), SIMD3(x1, y1, z0), SIMD3(0, 0, -1))   // −Z
        face(SIMD3(x1, y0, z1), SIMD3(x1, y0, z0), SIMD3(x1, y1, z0), SIMD3(x1, y1, z1), SIMD3(1, 0, 0))    // +X
        face(SIMD3(x0, y0, z0), SIMD3(x0, y0, z1), SIMD3(x0, y1, z1), SIMD3(x0, y1, z0), SIMD3(-1, 0, 0))   // −X
        face(SIMD3(x0, y1, z1), SIMD3(x1, y1, z1), SIMD3(x1, y1, z0), SIMD3(x0, y1, z0), SIMD3(0, 1, 0))    // +Y top
        face(SIMD3(x0, y0, z0), SIMD3(x1, y0, z0), SIMD3(x1, y0, z1), SIMD3(x0, y0, z1), SIMD3(0, -1, 0))   // −Y bottom
    }

    /// A single flat quad (two triangles), centred at `c`, spanning ±`u` (right) and ±`w` (up), facing `n`.
    private func emitQuad(_ c: SIMD3<Float>, _ u: SIMD3<Float>, _ w: SIMD3<Float>, _ n: SIMD3<Float>, _ m: Mat, into v: inout [PVert]) {
        func vert(_ p: SIMD3<Float>) -> PVert {
            PVert(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z,
                  ar: m.a.x, ag: m.a.y, ab: m.a.z, rough: m.r, metal: m.m, er: m.e.x, eg: m.e.y, eb: m.e.z, tid: -1)
        }
        let a = c - u - w, b = c + u - w, cc = c + u + w, dd = c - u + w
        v += [vert(a), vert(b), vert(cc), vert(a), vert(cc), vert(dd)]
    }

    /// A capped cylinder between two world points. The GShape cylinders the prop path uses are Y-axis or
    /// Z-axis only, but a pipe run lies along an ARBITRARY axis, so tessellate it directly here.
    private func emitTube(_ a: SIMD3<Float>, _ b: SIMD3<Float>, r: Float, sides: Int = 10, _ m: Mat, caps: Bool = true, into v: inout [PVert]) {
        let ax = b - a; let len = simd_length(ax)
        guard len > 1e-5, r > 1e-5 else { return }
        let d = ax / len
        let up = abs(d.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        let t = simd_normalize(simd_cross(up, d)), s = simd_cross(d, t)
        func vert(_ p: SIMD3<Float>, _ n: SIMD3<Float>) -> PVert {
            PVert(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z,
                  ar: m.a.x, ag: m.a.y, ab: m.a.z, rough: m.r, metal: m.m, er: m.e.x, eg: m.e.y, eb: m.e.z, tid: -1)
        }
        var prevN = t, prevA = a + t * r, prevB = b + t * r
        for i in 1...sides {
            let ang = Float(i) / Float(sides) * 2 * Float.pi
            let n = t * cosf(ang) + s * sinf(ang)
            let ca = a + n * r, cb = b + n * r
            v += [vert(prevA, prevN), vert(ca, n), vert(cb, n), vert(prevA, prevN), vert(cb, n), vert(prevB, prevN)]
            if caps {
                v += [vert(a, -d), vert(prevA, -d), vert(ca, -d)]      // near cap
                v += [vert(b, d), vert(cb, d), vert(prevB, d)]         // far cap
            }
            prevN = n; prevA = ca; prevB = cb
        }
    }

    /// A flat filled ELLIPSE (triangle-fan), radii `ru`×`rv` in the (u, up) plane, centred at `c`, facing `n`.
    private func emitEllipse(_ c: SIMD3<Float>, _ u: SIMD3<Float>, _ up: SIMD3<Float>, _ ru: Float, _ rv: Float, _ n: SIMD3<Float>, _ m: Mat, into v: inout [PVert]) {
        func vert(_ p: SIMD3<Float>) -> PVert {
            PVert(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z,
                  ar: m.a.x, ag: m.a.y, ab: m.a.z, rough: m.r, metal: m.m, er: m.e.x, eg: m.e.y, eb: m.e.z, tid: -1)
        }
        let seg = 20
        var prev = c + u * ru
        for i in 1...seg {
            let a = Float(i) / Float(seg) * 2 * Float.pi
            let cur = c + u * (cosf(a) * ru) + up * (sinf(a) * rv)
            v += [vert(c), vert(prev), vert(cur)]; prev = cur
        }
    }

    /// A flat DIAMOND (rotated-square) decal — tip up/down/left/right — centred at `c`, facing `n`.
    private func emitDiamond(_ c: SIMD3<Float>, _ u: SIMD3<Float>, _ up: SIMD3<Float>, _ s: Float, _ n: SIMD3<Float>, _ m: Mat, into v: inout [PVert]) {
        func vert(_ p: SIMD3<Float>) -> PVert {
            PVert(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z,
                  ar: m.a.x, ag: m.a.y, ab: m.a.z, rough: m.r, metal: m.m, er: m.e.x, eg: m.e.y, eb: m.e.z, tid: -1)
        }
        let top = c + up * s, rgt = c + u * s, bot = c - up * s, lft = c - u * s
        v += [vert(top), vert(rgt), vert(bot), vert(top), vert(bot), vert(lft)]
    }

    /// A flame silhouette (fan-triangulated outline) centred at `c`, in the (u, up) plane, facing `n`.
    private func emitFlame(_ c: SIMD3<Float>, _ u: SIMD3<Float>, _ up: SIMD3<Float>, _ s: Float, _ n: SIMD3<Float>, _ m: Mat, into v: inout [PVert]) {
        let pts: [SIMD2<Float>] = [                                    // x=across, y=up; a licking flame with a hooked tip
            SIMD2(0.00, -0.55), SIMD2(0.42, -0.30), SIMD2(0.22, -0.02), SIMD2(0.46, 0.18),
            SIMD2(0.10, 0.30), SIMD2(0.28, 0.62), SIMD2(0.02, 0.60), SIMD2(0.16, 1.00),
            SIMD2(-0.18, 0.58), SIMD2(-0.08, 0.24), SIMD2(-0.42, 0.12), SIMD2(-0.14, -0.06), SIMD2(-0.40, -0.34)]
        func vert(_ p2: SIMD2<Float>) -> PVert {
            let p = c + u * (p2.x * s) + up * (p2.y * s)
            return PVert(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z,
                         ar: m.a.x, ag: m.a.y, ab: m.a.z, rough: m.r, metal: m.m, er: m.e.x, eg: m.e.y, eb: m.e.z, tid: -1)
        }
        var s2 = SIMD2<Float>(0, 0); for p in pts { s2 += p }
        let ctr = s2 / Float(pts.count)
        for i in 0..<pts.count { v += [vert(ctr), vert(pts[i]), vert(pts[(i + 1) % pts.count])] }
    }

    /// A SINGLE oil placard PAINTED on the drum — a yellow warning diamond (dark border + symbol), like a
    /// real barrel. Billboarded to face the player so the one label always reads; sits flush on the r≈0.155
    /// body between the rolling hoops. Kept off the drum-weathering flag so the rust doesn't eat it.
    private func emitDrumLabel(pos: SIMD2<Float>, toward pp: SIMD2<Float>, into v: inout [PVert]) {
        let border = M(SIMD3(0.06, 0.05, 0.03), 0.6, 0.05)   // dark diamond border
        let plate  = M(SIMD3(0.80, 0.64, 0.05), 0.6, 0.05)   // hazard yellow (printed, not metal)
        let mark   = M(SIMD3(0.06, 0.05, 0.03), 0.6, 0.05)   // dark central symbol
        let rel = pp - pos, dist = simd_length(rel)
        let f = dist > 1e-4 ? SIMD3<Float>(rel.x / dist, 0, rel.y / dist) : SIMD3<Float>(0, 0, 1)   // face the player
        let u = SIMD3<Float>(-f.z, 0, f.x), up = SIMD3<Float>(0, 1, 0)
        let c = SIMD3<Float>(pos.x, 0.235, pos.y) + f * 0.161                                        // between the hoops, proud of the body
        emitDiamond(c,            u, up, 0.062, f, border, into: &v)
        emitDiamond(c + f * 0.002, u, up, 0.050, f, plate,  into: &v)
        emitFlame(c + f * 0.004, u, up, 0.030, f, mark, into: &v)   // flammable flame pictogram
    }

    /// Tessellate a prop's local shapes into `v`, applying the kernel's LOCAL→WORLD
    /// transform inverted: XZ rotation about +yaw, translate to `pos`, drop the lowest
    /// authored point to the floor when `floored` (yOff = loY; wall-pipes/sockets keep
    /// their authored height). `rough`/`metal` are the prop class's PBR base.
    private func emitProp(_ shapes: [GPURaymarch.GShape], pos: SIMD2<Float>, yaw: Float,
                          floored: Bool, rough: Float, metal: Float, yScale: Float = 1, into v: inout [PVert]) {
        var yOff: Float = 0
        if floored { var lo: Float = 1e9; for s in shapes { lo = min(lo, rrShapeYExtent(s).0) }; yOff = lo }
        let cy = cosf(yaw), sy = sinf(yaw)
        // yScale stretches a floor-to-ceiling prop (the structural column, authored y 0…1) to its cell's own
        // ceiling — in a double-height machine hall an unscaled column would stop halfway up as a floating stub.
        let xf: (SIMD3<Float>) -> SIMD3<Float> = { l in SIMD3(pos.x + l.x * cy - l.z * sy, (l.y - yOff) * yScale, pos.y + l.x * sy + l.z * cy) }
        let xn: (SIMD3<Float>) -> SIMD3<Float> = { n in SIMD3(n.x * cy - n.z * sy, n.y, n.x * sy + n.z * cy) }
        for s in shapes { tessShape(s, rough: rough, metal: metal, xf, xn, into: &v) }
    }

    /// Parse the imported wall-bulkhead lamp (bulkhead.usdz) via ModelIO: walk the USD hierarchy accumulating
    /// each node's composed transform, collect WORLD-space triangles (skipping the scene backdrop plane),
    /// recompute flat normals, centre at origin and scale to ~0.34 m. Steel material; cached.
    private func loadBulkhead() -> [PVert]? {
        if let m = bulkheadMesh { return m }
        if bulkheadTried { return nil }
        bulkheadTried = true
        guard let url = Bundle.main.url(forResource: "bulkhead", withExtension: "usdz") else {
            print("RasterRenderer: bulkhead.usdz not found"); return nil
        }
        let asset = MDLAsset(url: url)
        var tris: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        func appendMesh(_ mesh: MDLMesh, _ world: simd_float4x4) {
            guard let pa = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else { return }
            let base = pa.dataStart, stride = pa.stride, vc = mesh.vertexCount
            func pos(_ i: Int) -> SIMD3<Float> {
                let f = base.advanced(by: i * stride).assumingMemoryBound(to: Float.self)
                let w = world * SIMD4<Float>(f[0], f[1], f[2], 1); return SIMD3(w.x, w.y, w.z)
            }
            for sm in (mesh.submeshes as? [MDLSubmesh] ?? []) {
                let map = sm.indexBuffer(asIndexType: .uInt32).map()
                let idx = map.bytes.assumingMemoryBound(to: UInt32.self)
                var i = 0
                while i + 2 < sm.indexCount {
                    let a = Int(idx[i]), b = Int(idx[i + 1]), c = Int(idx[i + 2])
                    if a < vc, b < vc, c < vc { tris.append((pos(a), pos(b), pos(c))) }
                    i += 3
                }
            }
        }
        func walk(_ obj: MDLObject, _ parent: simd_float4x4) {
            let world = parent * (obj.transform?.matrix ?? matrix_identity_float4x4)
            if let mesh = obj as? MDLMesh, !mesh.name.lowercased().contains("plane") { appendMesh(mesh, world) }
            for c in obj.children.objects { walk(c, world) }
        }
        for i in 0..<asset.count { walk(asset.object(at: i), matrix_identity_float4x4) }
        guard !tris.isEmpty else { print("RasterRenderer: bulkhead no triangles"); return nil }
        var mn = SIMD3<Float>(repeating: 1e18), mx = SIMD3<Float>(repeating: -1e18)
        for (a, b, c) in tris { for p in [a, b, c] { mn = simd_min(mn, p); mx = simd_max(mx, p) } }
        let size = mx - mn, ctr = (mn + mx) * 0.5
        let sc = 0.34 / max(size.x, max(size.y, size.z))
        let steel = M(SIMD3(0.66, 0.48, 0.17), 0.34, 0.92)   // BRASS frame (was steel) — matches the marine bulkhead reference
        func vert(_ p: SIMD3<Float>, _ n: SIMD3<Float>) -> PVert {
            PVert(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z,
                  ar: steel.a.x, ag: steel.a.y, ab: steel.a.z, rough: steel.r, metal: steel.m,
                  er: steel.e.x, eg: steel.e.y, eb: steel.e.z, tid: -1)
        }
        // centre + scale, then ROLL 90° about the depth (Z→room) axis so the lamp's long axis stands VERTICAL
        func L(_ p: SIMD3<Float>) -> SIMD3<Float> { let q = (p - ctr) * sc; return SIMD3(-q.y, q.x, q.z) }
        var out: [PVert] = []
        for (a, b, c) in tris {
            let la = L(a), lb = L(b), lc = L(c)
            var n = simd_cross(lb - la, lc - la); let l = simd_length(n); n = l > 1e-6 ? n / l : SIMD3(0, 1, 0)
            out += [vert(la, n), vert(lb, n), vert(lc, n)]
        }
        print("RasterRenderer: bulkhead loaded \(tris.count) tris, world size (\(size.x),\(size.y),\(size.z)), scale \(sc)")
        bulkheadMesh = out
        return out
    }

    /// Emit the imported bulkhead lamp (centred local PVerts) at a wall mount: yaw about +Y, lifted to `height`.
    private func emitBulkheadMesh(_ mesh: [PVert], pos: SIMD2<Float>, yaw: Float, height: Float, into v: inout [PVert]) {
        let cy = cosf(yaw), sy = sinf(yaw)
        for pv in mesh {
            v.append(PVert(px: pos.x + pv.px * cy - pv.pz * sy, py: pv.py + height, pz: pos.y + pv.px * sy + pv.pz * cy,
                           nx: pv.nx * cy - pv.nz * sy, ny: pv.ny, nz: pv.nx * sy + pv.nz * cy,
                           ar: pv.ar, ag: pv.ag, ab: pv.ab, rough: pv.rough, metal: pv.metal, er: pv.er, eg: pv.eg, eb: pv.eb, tid: pv.tid))
        }
    }

    /// A floating PICKUP: like emitProp but UNIFORMLY scaled about its origin, its base
    /// dropped to 0 then lifted by `floatH` (hover), and spun by `yaw` — mirrors the
    /// raymarcher's packItems so items read identically. Emissive parts (peak>1 colours,
    /// e.g. cell rings) light themselves via propMat; the rest is semi-glossy canister metal.
    private func emitItem(_ shapes: [GPURaymarch.GShape], pos: SIMD2<Float>, yaw: Float,
                          scale: Float, floatH: Float, into v: inout [PVert]) {
        var loY: Float = 1e9
        for s in shapes { loY = min(loY, rrShapeYExtent(s).0) }
        let cy = cosf(yaw), sy = sinf(yaw)
        let xf: (SIMD3<Float>) -> SIMD3<Float> = { l in
            let sx = l.x * scale, sz = l.z * scale
            return SIMD3(pos.x + sx * cy - sz * sy, (l.y - loY) * scale + floatH, pos.y + sx * sy + sz * cy)
        }
        let xn: (SIMD3<Float>) -> SIMD3<Float> = { n in SIMD3(n.x * cy - n.z * sy, n.y, n.x * sy + n.z * cy) }
        for s in shapes { tessShape(s, rough: 0.42, metal: 0.40, xf, xn, into: &v) }
    }

    /// Parse the imported bed OBJ (positions + faces) into local-space PVerts with flat normals and a
    /// height-split material (steel frame low, pale mattress high), centred on XZ with its base at y=0.
    /// Cached; a failed load is remembered. (Institutional Bed 5, archibase.net — asset exception.)
    private func loadBed() -> [PVert]? {
        if let m = bedMesh { return m }
        if bedTried { return nil }
        bedTried = true
        guard let url = Bundle.main.url(forResource: "bed", withExtension: "obj"),
              let txt = try? String(contentsOf: url, encoding: .utf8) else { print("RasterRenderer: bed.obj not found"); return nil }
        var pos: [SIMD3<Float>] = []; var tris: [(Int, Int, Int)] = []
        for line in txt.split(separator: "\n") {
            let f = line.split(separator: " ")
            guard f.count >= 4 else { continue }
            if f[0] == "v" {
                pos.append(SIMD3(Float(f[1]) ?? 0, Float(f[2]) ?? 0, Float(f[3]) ?? 0))
            } else if f[0] == "f" {
                func vi(_ s: Substring) -> Int { (Int(s.split(separator: "/")[0]) ?? 0) - 1 }   // OBJ is 1-indexed; strip v/vt/vn
                tris.append((vi(f[1]), vi(f[2]), vi(f[3])))
            }
        }
        guard !pos.isEmpty, !tris.isEmpty else { return nil }
        for i in pos.indices { let p = pos[i]; pos[i] = SIMD3(p.x, p.z, -p.y) }   // .3DS is Z-up → rotate to the game's Y-up (its 1.63 axis is HEIGHT: a two-tier bunk)
        var lo = pos[0], hi = pos[0]
        for p in pos { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let ctr = SIMD3<Float>((lo.x + hi.x) * 0.5, lo.y, (lo.z + hi.z) * 0.5)   // centre XZ, floor to y=0
        bedHalfLen = (hi.x - lo.x) * 0.5                                         // length axis = game X (the long footprint) → flush seating
        let H = max(1e-4, hi.y - lo.y)                                           // total bunk height (two tiers)
        let frame   = Mat(a: SIMD3(0.26, 0.28, 0.32), r: 0.38, m: 0.70, e: .zero)   // dark steel frame/legs (reads as metal, not washed)
        let bedding = Mat(a: SIMD3(0.19, 0.32, 0.58), r: 0.90, m: 0.0,  e: .zero)    // institutional BLUE blanket — matte wool, the mesh's authored colour
        // No materials in the OBJ, so tell blanket from frame by geometry: the two mattress SLABS sit in
        // known height bands (lower ≈0.24–0.42, upper ≈0.71–0.90 of the bunk height — measured from the
        // mesh) and read as roughly-HORIZONTAL top surfaces; a face there is bedding (blue), everything
        // else (legs, rails, end-frames — vertical, or outside the bands) is steel.
        func isBedding(_ y: Float, _ ny: Float) -> Bool {
            let h = (y - lo.y) / H
            let inBand = (h > 0.24 && h < 0.42) || (h > 0.71 && h < 0.90)
            return inBand && abs(ny) > 0.45
        }
        func vert(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ m: Mat) -> PVert {
            PVert(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z,
                  ar: m.a.x, ag: m.a.y, ab: m.a.z, rough: m.r, metal: m.m, er: m.e.x, eg: m.e.y, eb: m.e.z)
        }
        var out: [PVert] = []; out.reserveCapacity(tris.count * 3)
        for (a, b, c) in tris where a >= 0 && b >= 0 && c >= 0 && a < pos.count && b < pos.count && c < pos.count {
            let pa = pos[a] - ctr, pb = pos[b] - ctr, pc = pos[c] - ctr
            var n = simd_cross(pb - pa, pc - pa); let l = simd_length(n); n = l > 1e-6 ? n / l : SIMD3(0, 1, 0)
            let m = isBedding((pa.y + pb.y + pc.y) / 3 + ctr.y, n.y) ? bedding : frame
            out += [vert(pa, n, m), vert(pb, n, m), vert(pc, n, m)]
        }
        bedMesh = out
        return out
    }

    /// Emit an imported mesh (local PVerts, base at y=0) at a prop: uniform scale, yaw about +Y, translate.
    // ── PLANT MACHINERY (floors 7–8) ────────────────────────────────────────────
    /// One imported machine: which mesh, how tall, and how to tell its carcass from its vessels.
    ///
    /// `height` is in GAME UNITS, not metres — the world is vertically compressed (a two-tier bunk
    /// is 0.90 and nearly fills a 1.0 corridor; the plant halls are 2.0), so metres would mislead.
    /// It is also a live `defaults` knob, read per frame, so a machine can be dialled in-game
    /// instead of described in a screenshot: `defaults write cc.jorviksoftware.Citadel
    /// MachineFilterHeight -float 1.7`.
    private struct MachineSpec {
        let res: String            // Resources/<res>.obj
        let key: String            // live height knob
        let height: Float          // default height, game units
        let split: Float           // height fraction: below is carcass, above is vessel
        let carcass: Mat
        let vessel: Mat
    }

    private static func machineSpec(_ kind: FurnitureKind) -> MachineSpec? {
        // Materials are assigned from GEOMETRY, not from the file — the OBJs carry positions and
        // triangles only. A height split is enough because these machines are all built the same
        // way: a dark painted base or frame carrying brighter bare-metal vessels above it. Same
        // idiom as the bed's bedding/frame split, and it costs no authoring per mesh.
        // Dark and ROUGH. The first pass used showroom values (albedo ~0.40, metal ~0.90) and every
        // machine blew out to near-white under the halls' downlights — the plant floors are meant to be
        // "dark, damp, noisy… oil stains, greasy surfaces, lots of grime", and a mirror-finish tank
        // reads as a museum piece standing in a mine. Metal is kept moderate for the same reason: a
        // high metal term with nothing to reflect but rock goes to specular mush.
        let vesselM = Mat(a: SIMD3(0.23, 0.24, 0.26), r: 0.56, m: 0.72, e: .zero)   // grimy bare metal
        let drumM   = Mat(a: SIMD3(0.19, 0.20, 0.21), r: 0.62, m: 0.66, e: .zero)   // duller still
        switch kind {
        case .machineFilter:
            return MachineSpec(res: "machine_filter", key: "MachineFilterHeight", height: 1.50, split: 0.40,
                               carcass: Mat(a: SIMD3(0.09, 0.10, 0.11), r: 0.72, m: 0.40, e: .zero), vessel: vesselM)
        case .machineColumn:
            return MachineSpec(res: "machine_column", key: "MachineColumnHeight", height: 1.60, split: 0.28,
                               carcass: Mat(a: SIMD3(0.10, 0.12, 0.11), r: 0.74, m: 0.34, e: .zero), vessel: drumM)
        case .machineCompressor:
            return MachineSpec(res: "machine_compressor", key: "MachineCompressorHeight", height: 1.00, split: 0.62,
                               carcass: Mat(a: SIMD3(0.10, 0.14, 0.15), r: 0.76, m: 0.28, e: .zero), vessel: drumM)
        case .machineSwitchgear:
            // Almost all carcass: only the isolator handle and the cap read as bare steel.
            return MachineSpec(res: "machine_switchgear", key: "MachineSwitchgearHeight", height: 0.85, split: 0.92,
                               carcass: Mat(a: SIMD3(0.13, 0.16, 0.14), r: 0.80, m: 0.20, e: .zero), vessel: vesselM)
        default: return nil
        }
    }

    /// The live height for a machine (see MachineSpec.height).
    private func machineHeight(_ kind: FurnitureKind) -> Float {
        guard let s = RasterRenderer.machineSpec(kind) else { return 1 }
        return (UserDefaults.standard.object(forKey: s.key) as? Double).map { Float($0) } ?? s.height
    }

    /// Load a machine mesh, NORMALISED to height 1.0 with its base on the deck and centred on XZ —
    /// so the live height knob applies at emit time and the cache never goes stale. Cached per kind;
    /// a failed load is remembered. (ArchiBase.net meshes; see CREDITS.md — asset exception.)
    private func loadMachine(_ kind: FurnitureKind) -> [PVert]? {
        if let m = machineMeshes[kind] { return m }
        if machineTried.contains(kind) { return nil }
        machineTried.insert(kind)
        guard let spec = RasterRenderer.machineSpec(kind),
              let url = Bundle.main.url(forResource: spec.res, withExtension: "obj"),
              let txt = try? String(contentsOf: url, encoding: .utf8) else {
            print("RasterRenderer: \(spec_res(kind)) not found"); return nil
        }
        var pos: [SIMD3<Float>] = []; var tris: [(Int, Int, Int)] = []
        for line in txt.split(separator: "\n") {
            let f = line.split(separator: " ")
            guard f.count >= 4, f[0] == "v" || f[0] == "f" else { continue }
            if f[0] == "v" {
                pos.append(SIMD3(Float(f[1]) ?? 0, Float(f[2]) ?? 0, Float(f[3]) ?? 0))
            } else {
                func vi(_ s: Substring) -> Int { (Int(s.split(separator: "/")[0]) ?? 0) - 1 }
                tris.append((vi(f[1]), vi(f[2]), vi(f[3])))
            }
        }
        guard !pos.isEmpty, !tris.isEmpty else { return nil }
        for i in pos.indices { let p = pos[i]; pos[i] = SIMD3(p.x, p.z, -p.y) }   // .3DS is Z-up → the game's Y-up
        var lo = pos[0], hi = pos[0]
        for p in pos { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let H = max(1e-5, hi.y - lo.y)
        let ctr = SIMD3<Float>((lo.x + hi.x) * 0.5, lo.y, (lo.z + hi.z) * 0.5)
        var out: [PVert] = []; out.reserveCapacity(tris.count * 3)
        for (a, b, c) in tris where a >= 0 && b >= 0 && c >= 0 && a < pos.count && b < pos.count && c < pos.count {
            let pa = (pos[a] - ctr) / H, pb = (pos[b] - ctr) / H, pc = (pos[c] - ctr) / H
            var n = simd_cross(pb - pa, pc - pa); let l = simd_length(n); n = l > 1e-6 ? n / l : SIMD3(0, 1, 0)
            let h = (pa.y + pb.y + pc.y) / 3                       // 0 at the deck, 1 at the top
            let m = h > spec.split ? spec.vessel : spec.carcass
            // Weathering — rust, oil film, settled dust — is NOT baked in here. It lives in the
            // fragment shader behind tid −6, keyed to world position, exactly as the fuel drums do it
            // (tid −5). A per-vertex grease gradient was the first attempt and it was flat: it darkened
            // the feet uniformly, so a bare panel still shaded as a bare panel. Grime has to vary
            // ACROSS a surface to break it up, which means per-pixel.
            func vert(_ p: SIMD3<Float>) -> PVert {
                PVert(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z,
                      ar: m.a.x, ag: m.a.y, ab: m.a.z, rough: m.r, metal: m.m, er: m.e.x, eg: m.e.y, eb: m.e.z,
                      tid: -6)
            }
            out += [vert(pa), vert(pb), vert(pc)]
        }
        machineMeshes[kind] = out
        return out
    }

    private func spec_res(_ kind: FurnitureKind) -> String { RasterRenderer.machineSpec(kind)?.res ?? "machine" }

    /// Every plant machine on this floor, emitted ONCE into the static level mesh.
    ///
    /// Machinery never moves, so it is level geometry, not per-frame props — the same call the
    /// bulkhead fixtures make, and for the same reason. Each machine is ~9.9k vertices; a plant
    /// floor's worth rebuilt every frame is tens of thousands of vertices of re-tessellation for a
    /// picture that cannot change, and the fixtures already showed where that leads (over the 300k
    /// per-frame cap, silently truncated, furniture popping in and out as the camera turned).
    ///
    /// One consequence worth knowing: the live height knobs (MachineFilterHeight and friends) are
    /// therefore read at LEVEL BUILD, not per frame. Dialling one takes effect on the next floor —
    /// warp with StartLevel to see it. That is a fair trade for taking the cost off the frame clock.
    private func buildMachines(_ world: World, into v: inout [PVert]) {
        for pr in world.props {
            guard RasterRenderer.machineSpec(pr.kind) != nil, let mesh = loadMachine(pr.kind) else { continue }
            // Wall machines seat FLUSH: the mesh is centred on its footprint, so pushing it into the
            // room by (halfDepth − 0.5) puts its back face on the wall face instead of burying it
            // behind. Depth comes from the shape bounds, so it tracks the mesh rather than a
            // hand-tuned per-kind number.
            var seat = pr.pos
            if pr.againstWall {
                let fp = GPURaymarch.furnitureFootprint(pr.kind)
                let inward = SIMD2<Float>(-sinf(pr.yaw), cosf(pr.yaw))
                seat += inward * max(0, fp.halfD - 0.5)
            }
            emitMesh(mesh, pos: seat, yaw: pr.yaw, scale: machineHeight(pr.kind), into: &v)
            // A CENTREPIECE gets its own downlight. The truss lamps are slung on a fixed bay stride,
            // so whether the hall's hero machine happens to stand under one is luck — and one that
            // doesn't is a dark mass you cannot read at all. These floors are meant to be dark, but
            // the thing the room exists for should not be the part you can't see. Wall machines get
            // nothing: they are furniture, and the bulkheads already wash the walls they stand on.
            if pr.kind == .machineFilter || pr.kind == .machineColumn {
                hallLamps.append(SIMD3(seat.x, GameMap.tallCeiling - 0.22, seat.y))
            }
        }
    }

    private func emitMesh(_ mesh: [PVert], pos: SIMD2<Float>, yaw: Float, scale: Float, into v: inout [PVert]) {
        let cy = cosf(yaw), sy = sinf(yaw)
        for pv in mesh {
            let lx = pv.px * scale, ly = pv.py * scale, lz = pv.pz * scale
            let nx = pv.nx, nz = pv.nz
            v.append(PVert(px: pos.x + lx * cy - lz * sy, py: ly, pz: pos.y + lx * sy + lz * cy,
                           nx: nx * cy - nz * sy, ny: pv.ny, nz: nx * sy + nz * cy,
                           ar: pv.ar, ag: pv.ag, ab: pv.ab, rough: pv.rough, metal: pv.metal, er: pv.er, eg: pv.eg, eb: pv.eb,
                           // FORWARD the material id. This argument was missing, so it defaulted to −1 and
                           // EVERY imported mesh arrived at the fragment claiming "plain flat material" —
                           // which is why the machinery's tid −6 weathering branch never once executed.
                           // Nothing complained: the vertex still built, the mesh still drew, it just
                           // quietly lost the one field that selects a surface treatment.
                           tid: pv.tid))
        }
    }

    /// The elevator CAR interior — a recessed overhead light and a 7-segment LED floor indicator on the
    /// car's back wall (opposite the door), for both cars. The digit is world.elevatorFloorDisplay, which
    /// flips to the destination floor just before the descent arrives. Per-frame (the digit + ride change).
    private func buildElevatorInterior(_ world: World, into v: inout [PVert]) {
        let map = world.map
        let floor = max(0, world.elevatorFloorDisplay)
        let digits: [Int] = floor >= 10 ? [floor / 10, floor % 10] : [floor % 10]      // one digit for floors 1–9
        let segMask = [63, 6, 91, 79, 102, 109, 125, 7, 127, 111]                       // 7-seg bitmask per 0–9 (a=1 … g=64)
        let seg: [(Float, Float, Float, Float)] = [                                     // (u across, w up, halfU, halfW)
            (0, 0.11, 0.05, 0.013), (0.05, 0.056, 0.013, 0.045), (0.05, -0.056, 0.013, 0.045),
            (0, -0.11, 0.05, 0.013), (-0.05, -0.056, 0.013, 0.045), (-0.05, 0.056, 0.013, 0.045), (0, 0, 0.05, 0.013)]
        let lit  = M(SIMD3(0.55, 0.16, 0.03), 0.6, 0.0, SIMD3(2.8, 0.85, 0.12))         // amber LED — emissive, blooms
        let dark = M(SIMD3(0.014, 0.011, 0.009), 0.75, 0.1)                             // dark LED glass (blacks read black)
        let lamp = M(SIMD3(0.90, 0.92, 1.00), 0.4, 0.0, SIMD3(2.2, 2.15, 2.0))          // overhead panel — emissive
        let ledY: Float = 0.80, scale: Float = 0.5                                       // scale: the LED glyph is authored large, shrunk to a realistic ~30 cm digit
        for cell in [map.exitCell, map.entryCell] where cell >= 0 {
            let cx = cell % map.w, cy = cell / map.w
            let ccx = Float(cx) + 0.5, ccz = Float(cy) + 0.5
            if simd_length(SIMD2(ccx, ccz) - world.player.pos) > 24 { continue }
            var fdx = 0, fdy = 0
            for (dx, dy) in [(0, 1), (0, -1), (1, 0), (-1, 0)]
                where map.inBounds(cx + dx, cy + dy) && map.wall[map.idx(cx + dx, cy + dy)] == 0 { fdx = dx; fdy = dy; break }
            if fdx == 0 && fdy == 0 { continue }
            emitAABB(SIMD3(ccx - 0.26, 0.965, ccz - 0.26), SIMD3(ccx + 0.26, 0.996, ccz + 0.26), lamp, into: &v)   // overhead light
            // LED on the BACK wall (opposite the door); thin box per lit segment, facing into the car
            let fixedZ = fdy != 0
            let back: Float = fixedZ ? (fdy > 0 ? Float(cy) + 0.05 : Float(cy + 1) - 0.05)
                                     : (fdx > 0 ? Float(cx) + 0.05 : Float(cx + 1) - 0.05)
            let sign: Float = fixedZ ? Float(fdy) : Float(fdx)
            // The LED faces the viewer standing in the doorway (looking along −front). With the game basis
            // forward=(cos,0,sin), right=(−sin,0,cos), that viewer's right is (fdy,0,−fdx) — so glyph +u
            // (glyph-right) must flip on Z-cars facing −Z and X-cars facing +X, else the digit reads mirrored.
            let uFlip: Float = fixedZ ? Float(fdy) : Float(-fdx)
            let tanC: Float = fixedZ ? ccx : ccz
            func box(_ fc: Float, _ tc: Float, _ y: Float, _ hu: Float, _ hw: Float, _ th: Float, _ m: Mat) {
                if fixedZ { emitAABB(SIMD3(tc - hu, y - hw, fc - th), SIMD3(tc + hu, y + hw, fc + th), m, into: &v) }
                else      { emitAABB(SIMD3(fc - th, y - hw, tc - hu), SIMD3(fc + th, y + hw, tc + hu), m, into: &v) }
            }
            let span = Float(digits.count)
            box(back, tanC, ledY, (0.075 * span + 0.03) * scale, 0.16 * scale, 0.02, dark)   // dark backing panel
            for (k, dig) in digits.enumerated() {
                let dc = tanC + uFlip * (Float(k) - (span - 1) * 0.5) * 0.16 * scale          // per-digit centre (most-significant on the viewer's left)
                let mask = segMask[min(9, dig)]
                for s in 0..<7 where (mask & (1 << s)) != 0 {
                    box(back + 0.02 * sign, dc + uFlip * seg[s].0 * scale, ledY + seg[s].1 * scale, seg[s].2 * scale, seg[s].3 * scale, 0.012, lit)   // lit segment, proud of the backing
                }
            }
        }
    }

    /// The fuel store's two wall-mounted BULKHEAD lights: one on each of the chamber's side walls (the walls
    /// running along its depth), at eye height, facing inward. Returns (mount on the wall, yaw so the dome
    /// faces the room, dome position for the point light) — shared by the mesh pass and the light pass.
    private func fuelBulkheads(_ m: GameMap) -> [(pos: SIMD2<Float>, yaw: Float, light: SIMD2<Float>)] {
        guard !m.fuelStore.isEmpty else { return [] }
        var dcx = -1, dcy = -1, outX = 0, outY = 0                       // hazard door + outward (door→chamber)
        outer: for c in m.fuelStore {
            let cx = c % m.w, cy = c / m.w
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = cx + dx, ny = cy + dy
                guard m.inBounds(nx, ny) else { continue }
                let ni = m.idx(nx, ny)
                if m.doors[ni] != nil, m.wall[ni] == WallTex.doorHazard.rawValue {
                    dcx = nx; dcy = ny; outX = -dx; outY = -dy; break outer
                }
            }
        }
        guard dcx >= 0 else { return [] }
        let doorC = SIMD2<Float>(Float(dcx) + 0.5, Float(dcy) + 0.5)
        let O = SIMD2<Float>(Float(outX), Float(outY)), P = SIMD2<Float>(Float(outY), Float(outX))   // depth axis, 2-wide axis
        func mount(_ side: Float) -> (SIMD2<Float>, Float, SIMD2<Float>) {
            let inward = -side * P                                        // side −1 → −P wall faces +P; side +1 → +P wall faces −P
            let pos = doorC + O * 1.5 + P * (side < 0 ? -0.5 : 1.5)
            let yaw = atan2(-inward.x, inward.y)                          // local +Z (dome) → inward
            return (pos, yaw, pos + inward * 0.16)
        }
        return [mount(-1), mount(1)]
    }

    /// Wall-mount ONE bulkhead fixture: the imported brass lamp plus its lit, ribbed lens (or the procedural
    /// caged lamp if the mesh is unavailable). Shared by every placement — the fuel store and the plant floors.
    private func emitBulkheadFixture(pos: SIMD2<Float>, yaw: Float, inward: SIMD2<Float>, into v: inout [PVert]) {
        let glow = M(SIMD3(0.95, 0.78, 0.5), 0.4, 0.0, SIMD3(1.7, 1.05, 0.42))     // warm GOLDEN lens (matches the brass reference), modest so the frame reads
        guard let lamp = loadBulkhead() else {                            // fallback: the procedural caged lamp
            emitProp(GPURaymarch.bulkheadShapes(), pos: pos, yaw: yaw, floored: false, rough: 0.5, metal: 0.7, into: &v)
            return
        }
        emitBulkheadMesh(lamp, pos: pos, yaw: yaw, height: 0.56, into: &v)  // imported bulkhead mesh (vertical), at eye height
        // a lit lens — a warm, VERTICAL rounded glow set just inside the cage so the frame stays visible over it
        let n = SIMD3<Float>(inward.x, 0, inward.y), u = SIMD3<Float>(-inward.y, 0, inward.x), up = SIMD3<Float>(0, 1, 0)
        let c = SIMD3<Float>(pos.x, 0.56, pos.y) + n * 0.03
        emitEllipse(c, u, up, 0.045, 0.11, n, glow, into: &v)
        // fluted-glass RIBBING (the reference's ribbed lens): a few thin darker verticals over the glow
        let rib = M(SIMD3(0.5, 0.36, 0.12), 0.5, 0.0, SIMD3(0.5, 0.34, 0.12))
        for rx in [Float(-0.026), 0, 0.026] {
            emitEllipse(c + n * 0.002 + u * rx, u, up, 0.004, 0.095, n, rib, into: &v)
        }
    }

    /// Mount the wall BULKHEAD fixtures — the fuel store's pair, plus (on the plant floors 7–8, which carry no
    /// ceiling grid) the fixtures that light the workings. Their glow is added as point lights in render().
    /// Every wall BULKHEAD fixture, emitted into the STATIC level mesh. These were being rebuilt into the
    /// per-frame prop buffer, and the imported lamp is ~3.5k triangles: thirty of them on a plant floor
    /// exceeded the whole 300k-vertex prop budget on their own, so the furniture emitted after them was
    /// silently truncated — and which pieces survived changed as the camera turned, which is why columns and
    /// furniture popped in and out within a single room. They never move, so they are static geometry.
    private func buildWallFixtures(_ map: GameMap, into v: inout [PVert]) {
        for b in fuelBulkheads(map) {
            emitBulkheadFixture(pos: b.pos, yaw: b.yaw, inward: simd_normalize(b.light - b.pos), into: &v)
        }
        for b in plantLamps {
            emitBulkheadFixture(pos: b.pos, yaw: b.yaw, inward: simd_normalize(b.light - b.pos), into: &v)
        }
    }

    private func buildProps(_ world: World, into v: inout [PVert]) {
        let pp = world.player.pos, dir = world.player.dir
        let fwd = SIMD2<Float>(cosf(dir), sinf(dir))
        func visible(_ pos: SIMD2<Float>, _ maxD: Float) -> Bool {
            let rel = pos - pp; let d = simd_length(rel)
            if d > maxD { return false }
            if d > 1.5 && simd_dot(rel / d, fwd) < -0.5 { return false }   // strongly behind → skip (saves tessellation)
            return true
        }
        // DOORS + the elevator front — a door cell is geometry-OPEN (you walk/shoot through as it parts),
        // so buildMesh draws its jambs but never the LEAF: doors (and the elevator, whose front IS a door
        // cell) rendered as empty gaps though they still operated. Emit the sliding centre-split leaves
        // here, per-frame (they animate): two half-panels that retract from the cell centre into the jambs.
        let dmap = world.map
        // Sorted: iterating the dictionary emits the door geometry in a per-process random order.
        // Depth resolves it visually, but it makes the vertex buffer differ between identical runs —
        // which defeats any byte comparison, and would make WHICH doors survive a buffer overflow
        // arbitrary rather than repeatable.
        for i in dmap.doors.keys.sorted() {
            let dstate = dmap.doors[i]!
            let cx = i % dmap.w, cy = i / dmap.w
            if !visible(SIMD2(Float(cx) + 0.5, Float(cy) + 0.5), 26) { continue }
            let part = min(1, dstate.open / GameMap.passThreshold)         // 0 closed … 1 fully parted
            let halfOpen = 0.5 * (1 - part)                                // each leaf's remaining half-width
            if halfOpen < 0.012 { continue }                              // fully open → nothing to draw
            let lx = dmap.inBounds(cx - 1, cy) && dmap.wall[dmap.idx(cx - 1, cy)] != 0
            let rx = dmap.inBounds(cx + 1, cy) && dmap.wall[dmap.idx(cx + 1, cy)] != 0
            let slideX = lx && rx                                         // both side walls solid → slides along X (mirrors doorSlidesAlongX)
            // TEXTURED leaves — sample the cell's baked art (door panels 12–18; a SECRET door keeps its
            // WALL id, so its leaf textures as the surrounding wall and stays disguised). World-anchored UV
            // (the vertex shader) → a closed door shows the full art with the seam at centre; a secret door
            // aligns with the neighbouring wall.
            let mat = wallMat(WallTex(rawValue: dmap.wall[i]) ?? .doorPanel)
            let tid = Float(dmap.wall[i])
            let t: Float = 0.07                                          // leaf half-thickness (through-axis)
            let fx = Float(cx), fz = Float(cy)
            // The elevator car AND the fuel store read as the FRONT FACE of a box, not a mid-cell leaf. A
            // normal door sits at the cell centre (recessed half a cell into the wall) — which read the closed
            // box as a lit alcove with the doors at its BACK. Push these leaves out to the room-facing boundary
            // so the box interior (elevator light+LED / fuel-store concrete + drums) sits entirely BEHIND them.
            let isElevator = (i == dmap.exitCell || i == dmap.entryCell)
            let isFuelDoor = dmap.wall[i] == WallTex.doorHazard.rawValue
            let frontFace = isElevator || isFuelDoor
            var rfx = 0, rfy = 0                                         // room ("front") direction (the fuel store is open on BOTH sides, so exclude the chamber)
            if frontFace {
                for (dx, dy) in [(0, 1), (0, -1), (1, 0), (-1, 0)]
                    where dmap.inBounds(cx + dx, cy + dy) && dmap.wall[dmap.idx(cx + dx, cy + dy)] == 0
                       && !(isFuelDoor && dmap.fuelStore.contains(dmap.idx(cx + dx, cy + dy))) { rfx = dx; rfy = dy; break }
            }
            if slideX {
                let zc = (frontFace && rfy != 0) ? (rfy > 0 ? fz + 1 - t : fz + t) : fz + 0.5
                emitAABB(SIMD3(fx, 0, zc - t),            SIMD3(fx + halfOpen, 1, zc + t), mat, tid: tid, into: &v)   // left leaf → its jamb
                emitAABB(SIMD3(fx + 1 - halfOpen, 0, zc - t), SIMD3(fx + 1, 1, zc + t), mat, tid: tid, into: &v)      // right leaf → its jamb
            } else {
                let xc = (frontFace && rfx != 0) ? (rfx > 0 ? fx + 1 - t : fx + t) : fx + 0.5
                emitAABB(SIMD3(xc - t, 0, fz),            SIMD3(xc + t, 1, fz + halfOpen), mat, tid: tid, into: &v)   // near leaf
                emitAABB(SIMD3(xc - t, 0, fz + 1 - halfOpen), SIMD3(xc + t, 1, fz + 1), mat, tid: tid, into: &v)      // far leaf
            }
            // FUEL STORE — a round amber warning lamp on EACH leaf, mounted on the room face so it TRAVELS with
            // the leaf as the door parts and is occluded from inside the store. Emissive-only (blooms as a lamp);
            // no point light (raster fixture lights are unshadowed and would leak amber into the sealed store).
            if isFuelDoor, rfx != 0 || rfy != 0 {
                let blink = 0.14 + 0.86 * powf(max(0, sinf(Float(world.elapsed) * 3.4)), 0.35)   // a warning beacon's amber pulse
                let lm = M(SIMD3(0.02, 0.015, 0.005), 0.6, 0.0, SIMD3(7.0, 2.2, 0.15) * blink)   // near-black lens; only the orange-amber glow reads
                let ly: Float = 0.81, lr: Float = 0.03, up = SIMD3<Float>(0, 1, 0)
                for lu in [halfOpen * 0.5, 1 - halfOpen * 0.5] {                                  // centre of each leaf → rides it into the jamb as it opens
                    if slideX {
                        let zc = rfy > 0 ? fz + 1 - t : fz + t
                        emitEllipse(SIMD3(fx + lu, ly, zc + Float(rfy) * (t + 0.01)), SIMD3(1, 0, 0), up, lr, lr, SIMD3(0, 0, Float(rfy)), lm, into: &v)
                    } else {
                        let xc = rfx > 0 ? fx + 1 - t : fx + t
                        emitEllipse(SIMD3(xc + Float(rfx) * (t + 0.01), ly, fz + lu), SIMD3(0, 0, 1), up, lr, lr, SIMD3(Float(rfx), 0, 0), lm, into: &v)
                    }
                }
            }
        }
        buildElevatorInterior(world, into: &v)
        // furniture / fixtures / pipe runs / the reel-to-reel (material: rough painted metal)
        for pr in world.props where visible(pr.pos, 20) {
            // BEDS: the imported Institutional Bed MESH replaces the SDF platform bunk (yaw +90° so the
            // bed's length runs along the prop's local Z, head at the wall like the old bunk).
            // PLANT MACHINERY is STATIC — baked into the level mesh by buildMachines, not rebuilt
            // here every frame. At ~9.9k verts each, a plant floor's worth in the per-frame buffer
            // would be tens of thousands of vertices of pointless re-tessellation, and the bulkhead
            // fixtures already taught us where that ends: over the 300k cap, silently truncated,
            // furniture popping as the camera turned.
            if RasterRenderer.machineSpec(pr.kind) != nil { continue }
            if pr.kind == .bunk, let bed = loadBed() {
                // The bed's LENGTH runs along the prop's local Z after +90°; the extra +180° puts the
                // PILLOW/head at the wall (it was reversed). For a wall bunk, seat the frame FLUSH: the
                // mesh is centred, so push it into the room by (halfLen−0.5) so its head face meets the
                // wall face instead of burying the rear of the frame behind it.
                var seat = pr.pos
                if pr.againstWall {
                    let inward = SIMD2<Float>(-sinf(pr.yaw), cosf(pr.yaw))          // yawFor⁻¹: the into-room direction
                    seat += inward * max(0, bedHalfLen * bedScale - 0.5)
                }
                emitMesh(bed, pos: seat, yaw: pr.yaw + .pi / 2 + .pi, scale: bedScale, into: &v)
                continue
            }
            var sl: [GPURaymarch.GShape]
            var floored = true
            if pr.kind == .wallPipe {
                sl = GPURaymarch.pipeRunShapes(length: pr.length); floored = false     // authored up the wall
            } else if pr.kind == .tapeDeck, let dk = world.signalDeckPos,
                      abs(dk.x - pr.pos.x) < 0.3, abs(dk.y - pr.pos.y) < 0.3, world.elapsed < world.signalPlayUntil {
                sl = GPURaymarch.tapeDeckShapes(spin: world.elapsed * 2.6, playing: true)   // reels turn, REC lit
            } else {
                sl = GPURaymarch.furnitureShapes(pr.kind)
            }
            if sl.isEmpty { continue }                                                 // papers → floor decal, no SDF
            if pr.againstWall && pr.kind != .wallPipe { rrFlushToWall(&sl) }
            // a structural column runs floor-to-ceiling, so stretch it to ITS cell's ceiling (double-height halls)
            var ys: Float = 1
            if pr.kind == .column {
                let cxi = Int(pr.pos.x), cyi = Int(pr.pos.y)
                if dmap.inBounds(cxi, cyi) { ys = dmap.ceilY[dmap.idx(cxi, cyi)] }
            }
            emitProp(sl, pos: pr.pos, yaw: pr.yaw, floored: floored, rough: 0.82, metal: 0.12, yScale: ys, into: &v)
        }
        // fuel drums (red/blue by the same stable cell hash the packer uses) — MATTE painted steel, weathered
        // with rust/grime in the shader (tid=−5, matching the raymarcher), plus flat FLAMMABLE label decals
        for d in world.drums where d.health > 0 && visible(d.pos, 20) {
            let key = Int(d.pos.x.rounded()) &* 73856093 ^ Int(d.pos.y.rounded()) &* 19349663
            var body: [PVert] = []
            emitProp(GPURaymarch.drumShapes(red: (key & 1) == 0), pos: d.pos, yaw: 0, floored: true, rough: 0.86, metal: 0.20, into: &body)
            for i in body.indices { body[i].tid = -5 }        // flag → drum rust/grime weathering in rr_fragment
            v += body
            emitDrumLabel(pos: d.pos, toward: pp, into: &v)    // a single painted-on oil diamond (billboarded to the player)
        }
        // recharge sockets (wall-mounted; live charge/depleted readout, kept at chest height)
        for sk in world.sockets where visible(sk.pos, 20) {
            var sl = GPURaymarch.socketShapes(chargeFrac: Float(sk.charge) / Float(max(1, sk.maxCharge)), depleted: sk.depleted)
            rrFlushToWall(&sl)
            emitProp(sl, pos: sk.pos, yaw: sk.yaw, floored: false, rough: 0.80, metal: 0.15, into: &v)
        }
        // deployed proximity mines (runtime-spawned pucks + red LED)
        for mn in world.deployedMines where visible(mn.pos, 18) {
            emitProp(GPURaymarch.mineShapes(), pos: mn.pos, yaw: 0, floored: true, rough: 0.60, metal: 0.20, into: &v)
        }
        // rubble piles at damage sites (rough rock)
        for db in world.debris where visible(db.pos, 18) {
            emitProp(GPURaymarch.debrisShapes(db.seed), pos: db.pos, yaw: 0, floored: true, rough: 0.92, metal: 0.02, into: &v)
        }
        // ── ITEMS / pickups (M4): hover + slow spin, tessellated like props so they are
        // lit by the same forward pass and cast/receive the lamp pools + shadows ──────
        let t = world.elapsed
        for (idx, it) in world.items.enumerated() where !it.taken && visible(it.pos, 22) {
            let sl = GPURaymarch.itemShapes(it.kind)
            if sl.isEmpty { continue }
            let phase = Float(idx) * 1.7 + it.bob
            let floatH: Float = 0.18 + sinf(t * 2 + phase) * 0.04    // gentle bob (mirrors packItems)
            let yaw = t * 0.8 + phase                                // slow spin
            emitItem(sl, pos: it.pos, yaw: yaw, scale: 0.55, floatH: floatH, into: &v)
        }
        // ── PROJECTILES (M5): a bright emissive HEAD ORB + a tapering STREAK stretched along the flight
        // direction (mirrors GPURaymarch.packProjectiles), at eye height — so a bolt reads as a bolt of
        // energy and a rocket streaks nose-forward, not as a flat camera-facing sprite. Emissive (col
        // over-bright → propMat self-lit); each also casts a dynamic light (gathered above). ────────────
        let eyeY: Float = 0.5
        for pr in world.projectiles where visible(pr.pos, 40) {
            let r = GPURaymarch.projRadius(pr.kind), col = GPURaymarch.projColor(pr.kind)
            let speed = simd_length(pr.vel)
            let dirU = speed > 0.001 ? pr.vel / speed : SIMD2<Float>(1, 0)
            let head = SIMD3<Float>(pr.pos.x, eyeY, pr.pos.y)
            let tail = head - SIMD3<Float>(dirU.x, 0, dirU.y) * min(0.8, speed * 0.045)
            tessShape(GPURaymarch.iSphere(head, r, col * 2.6, 0.01), rough: 0.4, metal: 0.0, { $0 }, { $0 }, into: &v)
            if simd_distance(head, tail) > 0.05 {
                tessShape(GPURaymarch.iCone(head, tail, r * 0.9, r * 0.2, col * 1.5, 0.02), rough: 0.4, metal: 0.0, { $0 }, { $0 }, into: &v)
            }
        }
    }

    // ── camera matrices (reproduce the raymarch ray model) ────────────────────
    private func view(_ eye: SIMD3<Float>, _ r: SIMD3<Float>, _ u: SIMD3<Float>, _ f: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(SIMD4(r.x, u.x, f.x, 0), SIMD4(r.y, u.y, f.y, 0), SIMD4(r.z, u.z, f.z, 0),
                      SIMD4(-simd_dot(r, eye), -simd_dot(u, eye), -simd_dot(f, eye), 1))
    }
    private func proj(plane: Float, horizon: Float, w: Float, h: Float, near: Float, far: Float) -> simd_float4x4 {
        let a = far / (far - near), b = -far * near / (far - near)
        return simd_float4x4(SIMD4(1 / plane, 0, 0, 0), SIMD4(0, w / h, 0, 0),
                             SIMD4(0, 1 - 2 * horizon / h, a, 1), SIMD4(0, 0, b, 0))
    }
    private func camMVP(eye: SIMD3<Float>, dir: Float, near: Float, far: Float) -> simd_float4x4 {
        let f = SIMD3<Float>(cos(dir), 0, sin(dir)), r = SIMD3<Float>(-sin(dir), 0, cos(dir)), u = SIMD3<Float>(0, 1, 0)
        return proj(plane: RenderConfig.cameraPlane, horizon: Float(RenderConfig.horizon), w: Float(W), h: Float(H), near: near, far: far) * view(eye, r, u, f)
    }
    /// ORTHOGRAPHIC top-down shadow projection for a ceiling lamp at (lampX, *, lampZ):
    /// world → clip mapping a `half`-metre square under the lamp onto the shadow slice, with
    /// depth running from the ceiling (near) to just below the floor (far). Orthographic (not
    /// perspective) so the whole lamp POOL is covered without fisheye distortion, and the shadow
    /// is anchored to the lamp's fixed position — it stays put in the world as the player moves.
    private func lampShadowMVP(lampX: Float, lampZ: Float, half S: Float) -> simd_float4x4 {
        // near plane JUST BELOW the ceiling/housing (0.96 < housing 0.985 < ceiling 1.0), far plane
        // just below the floor. The ceiling must NOT be captured: from a top-down projector it is the
        // nearest surface and would shadow the entire floor pool the instant a lamp enters the
        // shadowed set — the "distant light turns off as I approach" bug. Only real occluders BELOW
        // the lamp (props ≤ ~0.9, walls, the floor itself) are recorded. (An earlier try at this
        // blacked the scene, but that was the OLD all-lamps-shadowed code; now only floor pools are
        // shadowed, so excluding the ceiling is safe and contained.)
        let yTop: Float = 0.96, yBot: Float = -0.12, dz = yTop - yBot
        return simd_float4x4(
            SIMD4(1 / S, 0, 0, 0),          // wx → clip.x
            SIMD4(0, 0, -1 / dz, 0),        // wy → clip.z (depth, ceiling→floor)
            SIMD4(0, 1 / S, 0, 0),          // wz → clip.y
            SIMD4(-lampX / S, -lampZ / S, yTop / dz, 1)
        )
    }

    // ════════════════════════════════════════════════════════════════════════
    static let shaderSrc = """
    #include <metal_stdlib>
    using namespace metal;

    // overhead ceiling-lamp grid constants — injected from the RasterRenderer statics so the
    // shader's analytic lamps, buildMesh's housings, and the presence mask share one definition.
    constant int    kStride    = \(RasterRenderer.lampGridStride);
    constant int    kPhase     = \(RasterRenderer.lampGridPhase);
    constant float  kGridStep  = \(Float(RasterRenderer.lampGridStride));
    constant float  kGridOff   = \(Float(RasterRenderer.lampGridPhase) + 0.5);   // lamp centre = kStride·k + kPhase + 0.5
    constant float3 kLampCol   = float3(\(WorldLight.lampColor.x), \(WorldLight.lampColor.y), \(WorldLight.lampColor.z));
    constant float  kLampInt   = \(RasterRenderer.lampIntensity);
    constant float  kLampInvR2 = \(1 / (RasterRenderer.lampPoolRadius * RasterRenderer.lampPoolRadius));   // 1/radius²
    constant float  kLampY     = \(RasterRenderer.lampLightY);

    struct Cam { float4x4 mvp; float4x4 lmvp[3]; float4 eye; float4 params; float4 amb; float4 headFwd; float4 shX; float4 shZ; float4 camFwd; float4 water; };
    struct Light { float4 posR; float4 colI; };          // posR=(x,y,z,1/r²)  colI=(rgb,intensity)
    struct PV { float px,py,pz, nx,ny,nz, ar,ag,ab, rough, metal, er,eg,eb, tid; };
    struct VOut { float4 clip [[position]]; float3 wp; float3 wn; float3 alb; float rgh; float mtl; float3 emis; float2 uv; float tid; };
    struct SOut { float4 clip [[position]]; };

    float h21(float2 p){ p = fract(p*float2(127.1,311.7)); p += dot(p,p+34.5); return fract(p.x*p.y); }
    float vnoise(float2 p){ float2 i=floor(p),f=fract(p); f=f*f*(3-2*f);
        float a=h21(i),b=h21(i+float2(1,0)),c=h21(i+float2(0,1)),d=h21(i+float2(1,1));
        return mix(mix(a,b,f.x),mix(c,d,f.x),f.y); }
    float fbm(float2 p){ float s=0,a=0.5; for(int i=0;i<5;i++){ s+=a*vnoise(p); p*=2.03; a*=0.5;} return s; }
    // Height field for BLASTED ROCK: a few octaves with a ridged fold, so faces break into chunky planes
    // separated by sharp fractures rather than rolling smoothly. Sampled in the wall's own tangent plane and
    // differenced for the normal — that gradient, not the baked colour, is what makes rock read as rock.
    // One Voronoi layer of TILTED PLANES: each cell is a facet, and because dot(offset, dir) is linear inside
    // a cell every facet differentiates to a constant normal, so neighbours meet at a sharp crease — how
    // fractured stone actually breaks. (Smooth fbm ridges read as brain coral; stacked fbm reads as moss.)
    float voroFacet(float2 p, float seed){
        float2 ip = floor(p), fp = fract(p);
        float bd = 1e9, bid = 0.0; float2 br = float2(0.0);
        for(int j=-1;j<=1;j++){ for(int i=-1;i<=1;i++){
            float2 g = float2(float(i), float(j));
            float2 o = float2(h21(ip+g+seed), h21(ip+g+seed+31.7));    // jittered site in that cell
            float2 r = g + o - fp;
            float d = dot(r,r);
            if(d < bd){ bd = d; br = r; bid = h21(ip+g+seed+7.3); }
        }}
        float a = bid * 6.2831853;                                     // per-facet tilt direction
        return bid*0.55 + dot(br, float2(cos(a), sin(a)))*0.45;
    }
    float rockH(float2 p){
        // A raw Voronoi alone reads as regular CRAZY PAVING, so DOMAIN-WARP it first: the cells stretch and
        // shear into irregular shards. Two scales — big broken chunks plus smaller chips knocked off their
        // edges — then a whisper of grit.
        float2 q = p * 2.4;
        q += float2(fbm(q*0.5), fbm(q*0.5 + 19.0)) * 1.5;
        return voroFacet(q, 0.0) * 1.00
             + voroFacet(q*2.7 + 13.0, 5.0) * 0.28
             + vnoise(q*4.0) * 0.06;
    }
    // ── M6 standing water: the INTEGER-hash value-noise puddle field, byte-identical to
    // Lighting.puddle / GPURaymarch.puddleField, so the raster water pools EXACTLY where the
    // game wades + drips and the raymarcher draws it (the fixtureBusted lockstep trick). ──
    uint  rIhash(int x,int y){ uint h=uint(x)*374761393u+uint(y)*668265263u; h=(h^(h>>13))*1274126177u; return h^(h>>16); }
    float rIhash01(int x,int y){ return float(rIhash(x,y)&0xFFFFu)/65535.0; }
    float rInoise2(float2 q){ float2 i=floor(q),f=fract(q); f=f*f*(3-2*f); int2 c=int2(i);
        float a=rIhash01(c.x,c.y),b=rIhash01(c.x+1,c.y),cc=rIhash01(c.x,c.y+1),d=rIhash01(c.x+1,c.y+1);
        return mix(mix(a,b,f.x),mix(cc,d,f.x),f.y); }
    float rPuddleField(float2 xz){ return 0.65*rInoise2(xz*0.55)+0.35*rInoise2(xz*1.9+31.0); }
    float rPuddleMask(float f){ return smoothstep(0.50,0.60,f); }
    float3 triNoise(float3 wp, float3 n, float scale){
        float3 an=abs(n); an/=(an.x+an.y+an.z);
        float2 uvX=wp.zy*scale, uvY=wp.xz*scale, uvZ=wp.xy*scale; float e=0.35/scale;
        float vX=fbm(uvX), vY=fbm(uvY), vZ=fbm(uvZ);
        return float3(vX*an.x+vY*an.y+vZ*an.z, fbm(uvY+float2(e,0))-vY, fbm(uvY+float2(0,e))-vY);
    }
    float D_GGX(float ndh,float a){ float a2=a*a; float d=ndh*ndh*(a2-1)+1; return a2/(3.14159265*d*d+1e-6); }
    float G_Smith(float ndv,float ndl,float a){ float k=(a+1)*(a+1)/8; float gv=ndv/(ndv*(1-k)+k); float gl=ndl/(ndl*(1-k)+k); return gv*gl; }
    float3 F_Schlick(float vdh,float3 f0){ return f0 + (1-f0)*pow(1.0-vdh,5.0); }

    vertex VOut rr_vertex(uint vid [[vertex_id]], constant PV* vs [[buffer(0)]], constant Cam& C [[buffer(1)]]){
        PV p=vs[vid]; float3 wp=float3(p.px,p.py,p.pz);
        VOut o; o.clip=C.mvp*float4(wp,1); o.wp=wp; o.wn=normalize(float3(p.nx,p.ny,p.nz));
        o.alb=float3(p.ar,p.ag,p.ab); o.rgh=p.rough; o.mtl=p.metal; o.emis=float3(p.er,p.eg,p.eb);
        // wall texture UV: along-wall (world X or Z by facing) × height, tiled per cell (repeat sampler). Flip
        // the along-wall axis by the wall's NORMAL sign so baked directional art (the ARC seal, door glyphs)
        // reads the SAME way from the side that's actually open — otherwise it mirrors on opposite facings.
        float wu = abs(o.wn.x) > 0.5 ? (o.wn.x > 0.0 ? -wp.z : wp.z) : (o.wn.z > 0.0 ? wp.x : -wp.x);
        o.uv=float2(wu, 1.0 - wp.y); o.tid=p.tid; return o;
    }
    vertex SOut rr_shadow_vertex(uint vid [[vertex_id]], constant PV* vs [[buffer(0)]], constant float4x4& lmvp [[buffer(2)]]){
        PV p=vs[vid]; SOut o; o.clip=lmvp*float4(p.px,p.py,p.pz,1); return o;
    }

    // Soft cast shadow from one lamp's ORTHO top-down slice. A 16-tap Poisson disk over a
    // WIDE radius gives a diffused penumbra (real fixtures never cast razor edges); ortho, so
    // clip.w=1 and clip.xyz are already NDC. Outside this lamp's covered square → unshadowed.
    constant float2 kPoisson[16] = {
        float2(-0.326,-0.406), float2(-0.840,-0.074), float2(-0.696, 0.457), float2(-0.203, 0.621),
        float2( 0.962,-0.195), float2( 0.473,-0.480), float2( 0.519, 0.767), float2( 0.185,-0.893),
        float2( 0.507, 0.064), float2( 0.896, 0.412), float2(-0.322,-0.933), float2(-0.792,-0.598),
        float2( 0.080, 0.990), float2(-0.985, 0.144), float2(-0.126, 0.113), float2( 0.235, 0.386) };
    float pcfLamp(depth2d_array<float> smap, uint slice, float3 wp, float4x4 lmvp){
        float3 ndc=(lmvp*float4(wp,1)).xyz;               // ortho → w==1
        float2 uv=float2(ndc.x*0.5+0.5, 0.5-ndc.y*0.5);
        if(any(uv<float2(0.0))||any(uv>float2(1.0))||ndc.z<0.0||ndc.z>1.0) return 1.0;
        constexpr sampler ss(coord::normalized, address::clamp_to_edge, filter::linear);
        float bias=0.004, lit=0, r=22.0/1024.0;           // r = penumbra radius — WIDE (~0.15 m world) for soft diffused edges, never razor-sharp
        for(int j=0;j<16;j++){ float d=smap.sample(ss, uv+kPoisson[j]*r, slice); lit += (ndc.z-bias<=d)?1.0:0.0; }
        return lit/16.0;
    }

    // per-id wall self-illumination (matches GPURaymarch.wallEmissive): litPanel/computer/exit/doors glow
    inline float wallEmis(uint id){
        if(id==4u) return 0.85; if(id==16u) return 1.05; if(id==10u) return 0.60;
        if(id==13u||id==14u||id==15u||id==17u) return 0.45; if(id==18u) return 0.5; return 0.0;
    }
    struct RROut { float4 color [[color(0)]]; float perp [[color(1)]]; };
    fragment RROut rr_fragment(VOut in [[stage_in]], constant Cam& C [[buffer(1)]],
                                constant Light* lights [[buffer(2)]],
                                constant float4* decals [[buffer(3)]],
                                depth2d_array<float> smap [[texture(0)]], texture2d<float> field [[texture(1)]],
                                texture2d<float> lampMask [[texture(2)]], texture2d<uint> floorId [[texture(3)]],
                                texture2d_array<float> wallArr [[texture(4)]]){
        float3 alb=in.alb; float rough=in.rgh, metal=in.mtl; float wemis=0.0; float3 wallGlow=float3(0.0);
        if(in.tid>=0.0){                                    // TEXTURED WALL — the SAME baked art the raymarcher samples
            constexpr sampler ws(address::repeat, filter::linear);
            uint wid=uint(in.tid+0.5);
            alb=wallArr.sample(ws, in.uv, wid).rgb;
            wemis=wallEmis(wid);                            // self-lit fixtures (CRT screens, strip-lights) → bloom in the HDR pass
            float wt=C.amb.y;                               // time
            if(wid==10u){
                // COMPUTER BANK — live ANIMATED amber monitors (ported from the SDF renderer): a 4×4 grid,
                // each a distinct readout (scrolling log · oscilloscope · spectrum · dashboard), pure
                // time-driven math OVER the baked screen so the content genuinely MOVES.
                float2 g4=in.uv*4.0; float2 mcell=floor(g4); float2 muv=fract(g4);
                float mh=h21(mcell), mh2=h21(mcell+7.0); bool dead=h21(mcell+19.0)>0.86;
                float2 s=(muv-0.09)/0.82;
                if(s.x>0.0&&s.x<1.0&&s.y>0.0&&s.y<1.0&&!dead){
                    float sp=0.6+1.6*mh2;
                    float glow=0.05*(step(0.92,fract(s.x*8.0))+step(0.92,fract(s.y*6.0)));   // graticule
                    if(mh<0.34){ float ry=s.y*13.0+wt*(1.3+sp); float row=floor(ry);          // SCROLLING LOG
                        float len=0.15+0.80*h21(float2(row,mcell.x+mcell.y*3.0));
                        float ch=step(0.40,fract(s.x*16.0+h21(float2(row,2.0))*17.0));
                        glow+=0.85*ch*step(s.x,len)*step(0.20,fract(ry)); }
                    else if(mh<0.56){ float y=0.5+0.20*sin(s.x*16.0+wt*(3.0+sp))+0.09*sin(s.x*37.0-wt*(5.0+sp));
                        glow+=1.0-smoothstep(0.0,0.035,abs(s.y-y)); }                           // OSCILLOSCOPE
                    else if(mh<0.78){ float bar=floor(s.x*14.0);                                // SPECTRUM
                        float h=0.12+0.80*pow(0.5+0.5*sin(wt*(2.4+sp)+bar*0.8+mh*6.0),2.0);
                        glow+=0.85*step(s.y,h)*step(0.28,fract(s.x*14.0)); }
                    else { if(s.y>0.64){ float meter=(s.y>0.82)?0.45+0.45*sin(wt*(1.4+sp)):0.30+0.55*fract(wt*0.35+mh);
                            glow+=0.85*step(s.x,meter)*step(0.10,fract(s.x*26.0)); }            // DASHBOARD
                        else if(s.y>0.28){ float row=floor(s.y*8.0+wt*(0.8+sp));
                            glow+=0.80*step(0.50,fract(s.x*18.0+row*4.0))*step(s.x,0.92); }
                        else { glow+=1.0-smoothstep(0.0,0.03,abs(s.y-(0.14+0.09*sin(s.x*26.0+wt*4.0)))); } }
                    glow*=0.9+0.15*(0.6+0.4*sin(wt*31.0+mh*17.0));                              // tube flicker
                    // Content lives ONLY in the emissive term; the glass stays near-BLACK so unlit screen
                    // reads black (high contrast), and glow² crushes the graticule/dim mids so only the
                    // real readout glows + blooms — no tan wash.
                    alb=float3(0.006,0.004,0.002); rough=1.0; metal=0.0;                        // near-BLACK MATTE CRT glass — no amber env-spec sheen, room can't lift it
                    wallGlow=float3(1.0,0.60,0.13)*pow(clamp(glow,0.0,1.5),1.5)*2.5;            // amber content, self-lit (γ crush → dark mids, bright readout)
                    wemis=0.0;
                } else { alb=dead?float3(0.012,0.012,0.014):float3(0.02,0.022,0.026); rough=1.0; wemis=0.0; }  // dark MATTE steel bezel / dead unit → blacks read black
            } else if(wid==21u){
                // ── THE BIG BOARD (ops centre) ── the ONE full-colour display in the colony: everything else
                // is amber phosphor, so the plot board reads as the room that matters. Four panels, each a live
                // operational picture: ORBITAL ground-track, MINING shaft/tonnage, SHIPPING manifest+bays, and
                // LAUNCH pad status. Drawn per-fragment so it genuinely moves — a static plot board is a poster.
                float2 g2 = in.uv * float2(0.5, 2.0);                               // BIG panels: one per 2 cells, 2 high
                float2 pc = floor(g2); float2 q = fract(g2);
                // PARITY, not the raw cell index: the along-wall coordinate grows without bound and goes
                // NEGATIVE (the U axis flips by wall facing), so indexing on it put every panel in one branch.
                float ax = fract(pc.x * 0.5) * 2.0, ay = fract(pc.y * 0.5) * 2.0;    // each 0 or 1
                float panel = ax + ay * 2.0;                                         // 0..3
                float2 s = (q - 0.055) / 0.89;                                      // inside the bezel
                float3 pic = float3(0.0);
                if(s.x > 0.0 && s.x < 1.0 && s.y > 0.0 && s.y < 1.0){
                    float grid = 0.035 * (step(0.965, fract(s.x*10.0)) + step(0.965, fract(s.y*7.0)));
                    if(panel < 0.5){
                        // ORBITAL OPERATIONS — a ground track sinusoid crawling over a plate carrée world
                        pic += float3(0.05,0.12,0.22) + float3(0.0,0.10,0.18)*grid*4.0;         // ocean
                        float land = vnoise(float2(s.x*7.0, s.y*4.0));
                        pic = mix(pic, float3(0.10,0.26,0.14), smoothstep(0.52,0.60,land));      // landmass
                        float track = 0.5 + 0.30*sin(s.x*9.4 - wt*0.30);
                        pic += float3(0.20,1.00,0.55) * (1.0 - smoothstep(0.0,0.010,abs(s.y-track)));
                        float sx = fract(wt*0.055);                                              // the vehicle
                        float d2 = length((s - float2(sx, 0.5 + 0.30*sin(sx*9.4 - wt*0.30))) * float2(1.0,1.6));
                        pic += float3(1.0,0.85,0.30) * (1.0 - smoothstep(0.0,0.030,d2));
                    } else if(panel < 1.5){
                        // MINING — shaft section with ore seams + a live tonnage histogram
                        pic += float3(0.16,0.13,0.10)*(0.5+0.5*vnoise(float2(s.x*9.0,s.y*9.0))) + grid;
                        float seam = vnoise(float2(s.x*5.0, s.y*3.0 + 11.0));
                        pic = mix(pic, float3(0.95,0.55,0.12), smoothstep(0.62,0.72,seam)*0.85); // ore seam
                        if(s.y < 0.42){                                                          // tonnage bars
                            float b = floor(s.x*11.0);
                            float hgt = 0.06 + 0.34*pow(0.5+0.5*sin(wt*0.9 + b*1.7), 1.6);
                            float on = step(s.y, hgt) * step(0.18, fract(s.x*11.0));
                            pic = mix(pic, mix(float3(0.15,0.85,0.35), float3(0.95,0.25,0.15), smoothstep(0.22,0.38,hgt)), on);
                        }
                        pic += float3(0.9,0.15,0.10) * step(0.985, fract(wt*0.5)) * 0.6;         // fault klaxon flash
                    } else if(panel < 2.5){
                        // SHIPPING — a cargo-bay allocation grid beside a scrolling manifest
                        pic += float3(0.05,0.06,0.09) + grid;
                        if(s.x < 0.52){                                                          // bay grid
                            float2 c2 = floor(float2(s.x*7.0, s.y*6.0));
                            float st = h21(c2 + floor(wt*0.20));
                            float3 col = st > 0.72 ? float3(0.15,0.80,0.35) : (st > 0.42 ? float3(0.95,0.72,0.12) : float3(0.20,0.28,0.40));
                            float ins = step(0.14, fract(s.x*7.0)) * step(0.16, fract(s.y*6.0));
                            pic = mix(pic, col, ins*0.9);
                        } else {                                                                 // manifest rows
                            float row = floor(s.y*12.0 + wt*0.55);
                            float len = 0.10 + 0.34*h21(float2(row, 3.0));
                            float ch = step(0.42, fract((s.x-0.54)*22.0 + h21(float2(row,7.0))*13.0));
                            pic += float3(0.55,0.85,1.00) * ch * step(s.x-0.54, len) * step(0.22, fract(s.y*12.0 + wt*0.55));
                        }
                    } else {
                        // LAUNCH / LANDING — pad status lamps over an ascent profile
                        pic += float3(0.04,0.05,0.07) + grid;
                        float prof = pow(clamp(s.x*1.15, 0.0, 1.0), 2.2);                        // ascent curve
                        pic += float3(0.35,0.75,1.00) * (1.0 - smoothstep(0.0,0.012,abs(s.y - 0.10 - prof*0.72)));
                        for(int pi = 0; pi < 4; pi++){                                           // four pads
                            float fx2 = 0.13 + float(pi)*0.25;
                            float ph2 = fract(wt*0.13 + float(pi)*0.31);
                            float3 lamp = ph2 < 0.45 ? float3(0.15,0.85,0.30) : (ph2 < 0.75 ? float3(0.95,0.70,0.10) : float3(0.95,0.20,0.12));
                            float d3 = length((s - float2(fx2, 0.88)) * float2(1.0,1.5));
                            pic += lamp * (1.0 - smoothstep(0.012,0.030,d3));
                        }
                        float cd = fract(wt*0.09);                                               // countdown bar
                        pic += float3(0.95,0.85,0.25) * step(s.y,0.055) * step(s.x,cd) * step(0.03,s.y);
                    }
                    pic *= 0.94 + 0.10*sin(wt*23.0 + panel*5.0);                                 // panel refresh shimmer
                }
                wallGlow += pic * 0.45;
            } else if(wid==4u){
                wemis*=0.86+0.14*sin(wt*9.0+h21(floor(in.wp.xz))*23.0);                         // litPanel/bulkhead strip: gentle flicker
            }
        }
        float3 gn=normalize(in.wn);
        // Surfaces are CONTINUOUS — no per-metre panel grid (that read as tiled squares). Large-scale
        // form + grime come from the tri-planar noise below; real panel JOINTS are authored into the
        // map's materials, not stamped on every cell.
        float3 tn=triNoise(in.wp, gn, 5.5);
        float3 T=normalize(abs(gn.y)<0.9?cross(float3(0,1,0),gn):float3(1,0,0)), B=cross(gn,T);
        float3 N=normalize(gn - (tn.y*T+tn.z*B)*0.3);
        float grime=tn.x; rough=clamp(rough+(grime-0.5)*0.32,0.05,1.0); alb *= (0.74+0.48*grime);

        // ── BLASTED ROCK (wall ids 8 stone · 9 stoneSteel) ── the baked art alone reads as flat CAMO blotches:
        //    rock needs 3-D form. Compress the blotchy albedo toward one stone hue, then rebuild the surface
        //    from multi-scale triplanar noise: chunky broken faces, chisel/blast fractures cut as sharp creases,
        //    and crevice AO. The normal — not the colour — is what makes it read as hewn rock.
        if(in.tid >= 7.5 && in.tid < 9.5){
            // 1. KILL THE CAMO: the baked art's blotches live in its luminance, so compress that range hard to
            //    one dry stone hue. Colour must stay near-uniform — the FORM has to come from the normal.
            float lum = dot(alb, float3(0.299,0.587,0.114));
            float flat = 0.5 + (lum - 0.5) * 0.18;                        // ±0.09 instead of the full swing
            alb = float3(0.335,0.305,0.272) * (0.72 + 0.56*flat);
            // 2. REBUILD THE SURFACE from a height field sampled in the wall's OWN tangent plane, differenced
            //    for a correct gradient (the triplanar helper's derivatives are Y-plane only — wrong on a
            //    vertical face, which is why the wall stayed flat).
            float2 rp = float2(dot(in.wp, T), dot(in.wp, B));
            float e = 0.045;
            float hC = rockH(rp);
            float2 grad = float2(rockH(rp + float2(e,0)) - hC, rockH(rp + float2(0,e)) - hC) / e;
            N = normalize(gn - (T*grad.x + B*grad.y) * 0.38);             // chunky broken faces
            // 3. crevice AO + a touch of dust catching on the up-facing ledges
            float lowness = smoothstep(1.05, 0.35, hC);                   // 1 deep in a fracture, 0 on a proud face
            alb *= mix(1.0, 0.62, lowness);                               // gentle: heavy AO outlines every facet like mortar
            alb *= 0.88 + 0.24 * smoothstep(0.0, 0.5, dot(N, float3(0,1,0)));   // ledges lighter (settled dust)
            rough = clamp(0.88 + 0.10*fbm(rp*22.0), 0.74, 0.99);          // dry, matte, never shiny
            metal = 0.0;
        }

        // ── FUEL DRUM weathering (tid≈−5) — a matte, rusted, ribbed industrial barrel, ported from the
        //    raymarcher's drum branch so raster drums read the same: rolling hoops, mottled rust eating the
        //    paint, streaks bleeding down, a darker steel lid. (Emitted matte: metal 0.20, rough 0.86.)
        if(in.tid < -4.5 && in.tid > -5.5){
            float3 rust = float3(0.30,0.12,0.055), rustDk = float3(0.17,0.07,0.035);
            float py = in.wp.y;                                                        // barrel stands base≈0, top≈0.45
            alb = mix(alb, alb*0.5, smoothstep(0.58,0.9,gn.y));                         // darker flat steel lid
            alb *= mix(0.62, 1.0, smoothstep(0.0,0.13,py));                             // grime pooled at the base
            float rib = max(smoothstep(0.022,0.0,abs(py-0.15)), smoothstep(0.022,0.0,abs(py-0.32)));
            alb *= 1.0 - 0.52*rib;                                                      // two rolling hoops (recessed bands)
            // HIGH frequencies: a barrel is only ~0.3 wide, so the rust must vary across that span
            float big = fbm(in.wp.xz*13.0 + py*4.0);                                    // large rust blooms
            float fine = fbm(in.wp.xz*36.0);                                            // + fine pitting
            float patch = 0.6*big + 0.4*fine;
            float rustA = smoothstep(0.46,0.72,patch);                                  // moderate coverage → the clean paint stays glossy metal
            float streak = smoothstep(0.55,0.92, fbm(float2((in.wp.x-in.wp.z)*24.0, py*1.5))) * clamp(1.15-py*1.5,0.2,1.0);
            alb = mix(alb, rust, rustA*0.85);                                           // mottled rust eating the paint
            alb = mix(alb, rustDk, smoothstep(0.72,0.9,patch)*0.8);                     // deep rust cores
            alb = mix(alb, rust*0.6, streak*0.6);                                       // streaks bleed down from the rim
            float rf = clamp(rustA + streak*0.5, 0.0, 1.0);                             // 0 clean → 1 rusty
            metal = mix(0.80, 0.10, rf);                                                // GLOSSY painted steel where clean; matte where rust eats it
            rough = mix(0.30, 0.92, rf);
        }

        // ── PLANT MACHINERY (tid ≈ −6) ── the imported machines on floors 7–8. These are WORKING kit
        // that has stood in a wet hole for years, and bare geometry with two flat materials read as
        // exactly that: a blank sheet under the headlamp, and an unreadable dark mass away from it.
        // Three treatments break a panel up, and they have to OPPOSE each other to register — matte
        // rust, glossy oil, pale dust. Same darkness with a different finish is what the eye picks up.
        if(in.tid < -5.5 && in.tid > -6.5){
            float py = in.wp.y;                                                         // base ≈ 0, top ≈ 1.0–1.6
            // Offsetting the noise field BY HEIGHT is load-bearing, not decoration: a vertical face has
            // only one xz coordinate down its whole span, so plain fbm(wp.xz) would smear into vertical
            // stripes — the same trap the rock walls fell into before the tangent-plane rewrite. Adding
            // py makes the field vary in every direction on every facing, for one multiply.
            // Frequencies are far LOWER than the drums' 13/36: those were tuned for a 0.3-wide barrel,
            // and these machines are 1.0–2.8 across, where that rate turns to visual noise at any range.
            float bloom = fbm(in.wp.xz*5.5 + py*3.1);
            float fine  = fbm(in.wp.xz*15.0 + py*7.0);
            float patch = 0.62*bloom + 0.38*fine;
            // MOTTLE EVERYWHERE, before any rust. Coverage alone does not fix a blank panel: wherever the
            // rust mask happened to miss, the paint was still perfectly uniform and still read as sheet
            // metal off a roll. Worn paint is never one value, so vary all of it — the rust below then
            // sits on a surface that already has life rather than doing the whole job itself.
            alb *= 0.76 + 0.34*patch;
            rough = mix(rough, min(1.0, rough + 0.12), fine);
            float rustA = smoothstep(0.40, 0.70, patch);
            // STREAKS — rust bleeds DOWN from seams and fixings, and it is the single strongest cue
            // that something has been left standing in the damp. Stretching the noise along Y draws the
            // blotches out into runs; without this the rust reads as camouflage, not corrosion.
            float streak = smoothstep(0.44, 0.82, fbm(float2((in.wp.x - in.wp.z)*11.0, py*1.1)));
            streak *= smoothstep(0.02, 0.30, py);                                       // runs start off the deck, not at the feet
            float3 rust = float3(0.28,0.12,0.055), rustDk = float3(0.15,0.065,0.03);
            alb = mix(alb, rust, rustA*0.86);
            alb = mix(alb, rustDk, smoothstep(0.76,0.93,patch)*0.75);                   // deep cores where it has eaten through
            alb = mix(alb, rust*0.55, streak*0.62);
            float rf = clamp(rustA + streak*0.45, 0.0, 1.0);
            rough = mix(rough, 0.95, rf);
            metal = mix(metal, 0.06, rf);                                               // oxide is not metal
            // OIL — a wet film wicking up from the greased deck. GLOSSY, which is the whole point: it
            // sits at the same darkness as the rust, so only the finish separates them.
            float oil = clamp(1.0 - py/0.55, 0.0, 1.0);
            oil *= 0.45 + 0.55*fbm(in.wp.xz*8.0 + py*2.0);
            alb *= 1.0 - 0.62*oil;
            rough = mix(rough, 0.16, oil*0.8);
            metal = mix(metal, 0.50, oil*0.45);
            // DUST settles on whatever faces the roof, and it is the only PALE term here — so it peels
            // the horizontal surfaces away from the vertical ones without a second material.
            float up = smoothstep(0.45, 0.95, gn.y);
            alb = mix(alb, float3(0.20,0.19,0.17), up*0.42*(0.55+0.45*fine));
            rough = mix(rough, 0.92, up*0.5);
        }

        // ── M5 aftermath DECALS on FLOOR fragments (blood/scorch/scattered-papers/ash/offal) — ported
        // from the raymarch floor blend; modifies alb (+ a self-lit term) BEFORE the PBR lighting below.
        // Cheap AABB→circle reject so uncovered floor pixels pay almost nothing (nD>0 across the deck). ──
        float decalEmis = 0.0;
        int nD = int(C.amb.x);
        if(nD > 0 && gn.y > 0.5){
            float dtime = C.amb.y, dn = -1.0;
            for(int di=0; di<nD; di++){
                float4 dc = decals[di];
                float2 dxz = in.wp.xz - dc.xy; float rad = max(dc.z, 0.05);
                if(abs(dxz.x) >= rad || abs(dxz.y) >= rad) continue;
                float dd2 = dot(dxz, dxz); if(dd2 >= rad*rad) continue;
                if(dn < 0.0) dn = 0.5 + 0.5*fbm(in.wp.xz*3.3 + 5.0);
                float rr = sqrt(dd2)/rad;
                float fall = (1.0 - smoothstep(0.15, 1.0, rr)) * (0.62 + 0.38*dn);   // solid core, noise erodes the rim
                if(dc.w > 3.0){                                               // scattered papers
                    float st = clamp(dc.w - 3.0, 0.0, 1.0);
                    float2 q = in.wp.xz - dc.xy; float cover = 0.0, tone = 0.9;
                    for(int sk=0; sk<6; sk++){
                        float s = float(sk)*1.7 + dc.x*3.1 + dc.y*5.7;
                        float2 cc = (float2(fract(sin(s*12.9)*4137.1), fract(sin(s*78.2)*2619.7)) - 0.5) * (dc.z*1.2);
                        float ang = fract(sin(s*37.7)*7351.3) * 6.2831853;
                        float2 hs = float2(0.085 + 0.05*fract(sin(s*5.3)*1234.5), 0.11 + 0.06*fract(sin(s*9.1)*9182.3));
                        float2 dq = q - cc;
                        float2 lp2 = float2(dq.x*cos(ang) + dq.y*sin(ang), -dq.x*sin(ang) + dq.y*cos(ang));
                        float ins = smoothstep(-0.004, 0.004, min(hs.x - abs(lp2.x), hs.y - abs(lp2.y)));
                        if(ins > cover){ cover = ins; tone = 0.86 + 0.16*fract(sin(s*3.3)*111.1); }
                    }
                    cover *= st;
                    alb = mix(alb, float3(0.86,0.84,0.77)*tone, cover); decalEmis += cover*0.20;
                } else if(dc.w > 2.0){                                        // smoldering ash + live embers
                    float st = clamp(dc.w - 2.0, 0.0, 1.0), lump = vnoise(in.wp.xz*26.0);
                    float ash = smoothstep(0.45, 0.70, lump)*fall*st;
                    alb = mix(alb, float3(0.07,0.065,0.06), min(1.0, ash*1.8));
                    float fleck = smoothstep(0.80, 0.95, lump)*fall*st, glowT = 0.55 + 0.45*sin(dtime*2.3 + lump*37.0);
                    alb = mix(alb, float3(0.9,0.35,0.08), fleck*glowT*0.8); decalEmis += fleck*glowT*0.5;
                } else if(dc.w >= 0.0){ alb *= 1.0 - 0.93*fall*dc.w;          // scorch → charred black
                } else if(dc.w > -2.0){ float b = clamp(fall*(-dc.w)*1.1, 0.0, 1.0);   // blood → dark wet pool
                    alb = mix(alb, float3(0.13,0.014,0.011), b);
                } else {                                                      // offal (gibbed remains)
                    float st = clamp(-(dc.w+2.0), 0.0, 1.0), lump = vnoise(in.wp.xz*22.0);
                    float meat = smoothstep(0.55, 0.75, lump)*fall*st;
                    alb = mix(alb, float3(0.30,0.035,0.03), min(1.0, meat*1.7));
                    float glisten = smoothstep(0.74, 0.92, lump)*fall*st;
                    alb = mix(alb, float3(0.52,0.10,0.08), glisten);
                }
            }
        }

        // ── M6 LIQUIDS on FLOOR fragments: toxic pools (nukage), blood pools, the drowned lowest
        // floor, and floor-7's rock puddles — an animated wet surface. The floor id (read by integer
        // cell) tells liquid from pooling-rock; the flood scalar drowns the lowest floor; the puddle
        // field (byte-identical to the game's, so you splash exactly where you see water) says where
        // the rock pools. Mirrors the raymarch floor-liquid blend: churn the normal, glaze it glossy,
        // darken + cool the bed, and (nukage) pulse the glow. Applied BEFORE the PBR lighting below. ──
        float3 waterEmis = float3(0.0);
        if(gn.y > 0.5){
            uint2 fc = uint2(clamp(int2(floor(in.wp.xz)), int2(0), int2(int(C.params.z)-1, int(C.params.w)-1)));
            int fid = int(floorId.read(fc).r);
            bool liquid = (fid == 3 || fid == 8);                       // nukage / blood — liquid at any depth
            // FLOOR GRATE (fid 2) — raster floors are flat materials (only walls are textured), so a vent's
            // grate cell read as plain deck and the steam looked like it rose out of solid concrete. Draw the
            // grate procedurally: a recessed dark duct behind slotted iron bars, with a bevelled kerb frame.
            if(fid == 2){
                float2 g = fract(in.wp.xz);
                float2 e = min(g, 1.0 - g);                              // distance to the cell edge
                float kerb = smoothstep(0.10, 0.06, min(e.x, e.y));      // raised frame around the opening
                float slot = 1.0 - smoothstep(0.16, 0.30, abs(fract(in.wp.x * 9.0) - 0.5));   // bar/gap run
                float duct = slot * (1.0 - kerb);                        // the dark gaps between the bars
                alb = mix(alb * (0.55 + 0.35 * kerb), float3(0.020, 0.021, 0.023), duct * 0.88);
                rough = mix(rough, 0.42, 1.0 - duct);                    // worn iron bars catch a little sheen
                metal = mix(metal, 0.62, 1.0 - duct);
            }
            // PLANT DECK STAINS (floors 7–8, flagged by C.water.w == 0 — those floors run no ceiling grid):
            // the deck stays SMOOTH, but decades of machinery leave it stained — broad dark grease pools,
            // spilled-lubricant slicks that go glossy, and a scatter of drip marks. Albedo + roughness only.
            if(C.water.w < 0.5 && !liquid){
                float2 q = in.wp.xz;
                float pool  = smoothstep(0.52, 0.86, fbm(q*0.55));               // big soaked-in grease patches
                float slick = smoothstep(0.68, 0.93, fbm(q*1.9 + 17.0));         // fresher lubricant, still wet-looking
                float drips = smoothstep(0.80, 0.97, fbm(q*7.5 + 43.0));         // small drip marks + spatter
                float oil = clamp(pool*0.85 + drips*0.5, 0.0, 1.0);
                alb = mix(alb, float3(0.055,0.048,0.042), oil*0.80);             // grease darkens the deck
                alb = mix(alb, float3(0.035,0.032,0.030), slick*0.70);           // lubricant slick, darker still
                rough = mix(rough, 0.22, slick*0.85);                            // slicks read WET/glossy
                rough = clamp(rough + oil*0.10, 0.05, 1.0);                      // dried grease is duller
                metal = mix(metal, 0.12, slick*0.5);
            }
            float flood = C.water.x, dtime = C.amb.y;
            float wet = max(flood, liquid ? 1.0 : 0.0);                 // the lowest floor drowns (flood); pools always wet
            if(!liquid && fid == 7 && wet < 0.01){                      // floor-7 rock: water finds its way down → it POOLS
                float pf = rPuddleField(in.wp.xz + C.water.yz);
                float pool = rPuddleMask(pf);
                float damp = smoothstep(0.36, 0.50, pf) * (1.0 - pool);
                alb *= 1.0 - 0.22 * damp;                              // a damp soaked-in margin rings each pool
                wet = pool;
            }
            if(liquid){                                                // hazard pool — a live rippling glassy surface
                float2 q = in.wp.xz;
                float2 w1 = q*3.1 + float2(dtime*0.55, dtime*-0.41);
                float2 w2 = q*6.9 + float2(dtime*-0.33, dtime*0.49);
                float e = 0.09;
                float gx = (fbm(w1+float2(e,0))-fbm(w1-float2(e,0))) + 0.5*(fbm(w2+float2(e,0))-fbm(w2-float2(e,0)));
                float gz = (fbm(w1+float2(0,e))-fbm(w1-float2(0,e))) + 0.5*(fbm(w2+float2(0,e))-fbm(w2-float2(0,e)));
                N = normalize(N + float3(gx,0,gz)*2.4);                 // churning ripples from flowing noise
                if(fid == 3){ float pulse = fbm(q*1.6 + float2(dtime*0.5, dtime*0.37));
                    waterEmis += in.emis * (pulse - 0.5); }             // nukage: base·(0.5+pulse) via a delta on the always-added in.emis → an irregular pulse
                alb *= 0.55; rough = 0.10; metal = 0.0;                 // glassy hazard liquid
            } else if(wet > 0.01){                                      // standing water — the drowned deck / floor-7 pools
                float2 q = in.wp.xz;
                N = normalize(N + float3(cos(q.x*5.1 + dtime*1.1), 0.0, cos(q.y*4.7 - dtime*1.3)) * (0.14*wet));   // slow standing ripples
                alb = mix(alb, alb*float3(0.30,0.34,0.42), wet);        // water darkens + cools the bed under it
                rough = mix(rough, 0.08, wet); metal = 0.0;             // glazes the deck glossy
            }
        }

        float3 Vv=normalize(C.eye.xyz-in.wp); float ndv=max(dot(N,Vv),1e-3);
        float3 f0=mix(float3(0.04),alb,metal), diffCol=alb*(1-metal), col=float3(0);

        // ── wall/floor FIXTURES (sparse point lights) — unshadowed, player-independent ──
        int count=int(C.params.x);
        for(int i=0;i<count;i++){
            Light lp=lights[i]; float3 Ld=lp.posR.xyz-in.wp; float d2=dot(Ld,Ld);
            float dr2=d2*lp.posR.w; if(dr2>=1.0) continue;                 // outside the fixture's radius
            float dist=sqrt(max(d2,1e-6)); float3 L=Ld/dist;
            float ndl=max(dot(N,L),0.0); if(ndl<=0.0) continue;
            float3 Hh=normalize(L+Vv); float ndh=max(dot(N,Hh),0.0), vdh=max(dot(Vv,Hh),0.0);
            float atten=lp.colI.w * pow(1.0-dr2,2.0);                      // radius-bounded f·f falloff
            float3 spec=D_GGX(ndh,rough*rough)*G_Smith(ndv,ndl,rough)*F_Schlick(vdh,f0)/(4*ndv*ndl+1e-4);
            col += (diffCol/3.14159265 + spec) * lp.colI.rgb * (ndl*atten);
        }

        // ── analytic overhead ceiling-lamp GRID ──
        //  A pool's brightness derives ONLY from (lamp cell, surface) — there is NO player or view
        //  term, so it can never pop on move OR turn. Each fragment brackets its own 2×2 grid nodes
        //  (provably every lamp within the 2.7 m pool, since the 4 m spacing exceeds the radius),
        //  checks presence via the R8 mask (integer cell fetch, bounds-guarded), and lights from each
        //  real lamp at (cell+0.5, kLampY, cell+0.5). The nearest-3 shadow slices apply by EXACT cell
        //  match, gated to up-facing surfaces (a top-down ortho map is meaningless on a vertical wall).
        if(C.water.w > 0.5){                 // no ceiling-lamp grid on the plant floors (7–8) — bulkheads light those
            int shadowN=int(C.params.y+0.5);
            int mw=int(C.params.z), mh=int(C.params.w);
            int gx0=int(floor((in.wp.x-kGridOff)/kGridStep));
            int gz0=int(floor((in.wp.z-kGridOff)/kGridStep));
            float up=smoothstep(0.25,0.7,gn.y);
            float shx[3]={C.shX.x,C.shX.y,C.shX.z};
            float shz[3]={C.shZ.x,C.shZ.y,C.shZ.z};
            constexpr sampler maskPt(coord::normalized, address::clamp_to_edge, filter::nearest);   // exact cell (presence)
            constexpr sampler maskLin(coord::normalized, address::clamp_to_edge, filter::linear);    // interpolated (soft LOS)
            float2 mapSz=float2(mw,mh);
            for(int dz=0;dz<2;dz++){ for(int dx=0;dx<2;dx++){
                int gx=gx0+dx, gz=gz0+dz;
                int cx=kStride*gx+kPhase, cz=kStride*gz+kPhase;    // integer lamp cell = kStride·k + kPhase
                if(cx<0||cz<0||cx>=mw||cz>=mh) continue;           // map-edge guard BEFORE the fetch
                if(lampMask.sample(maskPt,(float2(cx,cz)+0.5)/mapSz).r < 0.75) continue; // 0 solid · 0.5 open · 1 lamp — need a real lamp
                float3 Lp=float3(float(cx)+0.5, kLampY, float(cz)+0.5);
                float3 Ld=Lp-in.wp; float d2=dot(Ld,Ld);
                float dr2=d2*kLampInvR2; if(dr2>=1.0) continue;    // outside the pool
                float dist=sqrt(max(d2,1e-6)); float3 L=Ld/dist;
                float ndl=max(dot(N,L),0.0); if(ndl<=0.0) continue;
                // SOFT line-of-sight: walk lamp→fragment sampling the presence mask BILINEARLY, and
                // accumulate a smooth transmittance (solid→0, open→1 over a ~1-cell ramp). This keeps a
                // pool from bleeding THROUGH a wall (the original leak) but with a diffused edge instead
                // of the grid-hard block — light still spreads freely across open cells + doorways.
                float vis=1.0;
                { float2 a=float2(float(cx)+0.5,float(cz)+0.5), b=in.wp.xz, e=b-a;
                  int ns=max(1,int(ceil(length(e)/0.35)));   // ~0.35 m steps
                  for(int s=1;s<ns;s++){ float2 pp=a+e*(float(s)/float(ns));
                      float m=lampMask.sample(maskLin, pp/mapSz).r;
                      vis=min(vis, smoothstep(0.12, 0.42, m)); }
                }
                if(vis<=0.001) continue;
                float sh=1.0;
                if(up>0.001){ for(int s=0;s<shadowN;s++){ if(cx==int(shx[s]) && cz==int(shz[s])){ sh=mix(1.0, pcfLamp(smap, uint(s), in.wp, C.lmvp[s]), up); break; } } }
                float3 Hh=normalize(L+Vv); float ndh=max(dot(N,Hh),0.0), vdh=max(dot(Vv,Hh),0.0);
                float atten=kLampInt * pow(1.0-dr2,2.0);
                float3 spec=D_GGX(ndh,rough*rough)*G_Smith(ndv,ndl,rough)*F_Schlick(vdh,f0)/(4*ndv*ndl+1e-4);
                col += (diffCol/3.14159265 + spec) * kLampCol * (ndl*atten*sh*vis);
            }}
        }

        // headlamp — the marine's helmet lamp (man-made), gated by headFwd.w (0 = off).
        if(C.headFwd.w > 0.001){
        { float3 toF=in.wp-C.eye.xyz; float dist=length(toF); float3 dir=toF/max(dist,1e-4);
          float cone=smoothstep(-0.15,0.55,dot(dir,C.headFwd.xyz));    // broad forward pool (lights the near floor/walls/ceiling)
          if(cone>0.0){ float3 L=-dir; float ndl=max(dot(N,L),0.0);
            float3 Hh=normalize(L+Vv); float ndh=max(dot(N,Hh),0.0), vdh=max(dot(Vv,Hh),0.0);
            float atten=C.headFwd.w*cone/(0.45+0.30*dist*dist);
            float3 spec=D_GGX(ndh,rough*rough)*G_Smith(ndv,ndl,rough)*F_Schlick(vdh,f0)/(4*ndv*ndl+1e-4);
            col += (diffCol/3.14159265 + spec) * float3(0.95,0.97,1.0) * (ndl*atten); } }
        // near-field spill — a little headlamp light always leaks around the marine
        // (short range), so no look direction leaves you blind on your own footing.
        { float3 Ld=C.eye.xyz-in.wp; float dn2=dot(Ld,Ld); float3 L=Ld*rsqrt(max(dn2,1e-6));
          float ndl=max(dot(N,L),0.0); float atten=0.9/(0.3+2.4*dn2);
          col += diffCol/3.14159265 * float3(0.90,0.93,1.0) * (ndl*atten); }
        }

        // ambient = the level's OWN fixtures propagated through the map (baked field) —
        // NO sourceless fill. Underground: unlit reaches fall to dark (intended).
        constexpr sampler ls(coord::normalized, address::clamp_to_edge, filter::linear);
        float3 baked = field.sample(ls, in.wp.xz/float2(C.params.z, C.params.w)).rgb;
        float ao = clamp(0.55+0.45*grime, 0.35, 1.0);
        col += baked * C.amb.w * alb * ao;
        col += f0 * baked * 0.6 * pow(1.0-ndv,3.0) * (1.0-rough);                    // env-ish spec off the baked field
        // textured walls carry their emission via the texture (wemis/wallGlow), so drop the flat-material
        // emissive there (it was a uniform amber wash washing the CRT blacks out).
        float3 baseEmis = (in.tid >= 0.0) ? float3(0.0) : in.emis;
        float3 emisTerm = baseEmis + decalEmis + waterEmis + alb * wemis + wallGlow;  // self-lit fixtures + decals + textured-wall glow (CRT/panel) + CRT content
        col += emisTerm;
        // LINEAR HDR out; alpha = EMISSION MASK so only emitters bloom (never merely bright-lit walls).
        // The whole frame is bloomed, then ACES-graded, gamma-corrected and vignetted ONCE in composite_frag.
        float emL = dot(emisTerm, float3(0.299, 0.587, 0.114));
        // C.amb.z>0.5 = the first-person VIEWMODEL pass: force perp NEGATIVE so it is always nearest — mesh
        // creatures never composite over the gun (#15), and the composite skips bloom over it (#14, stays opaque).
        RROut o; o.color=float4(max(col, 0.0), min(emL, 1.0));
        o.perp = (C.amb.z > 0.5) ? -1.0 : dot(in.wp - C.eye.xyz, C.camFwd.xyz);
        return o;
    }
    """

    // ════════════════════════════════════════════════════════════════════════
    //  VOLUMETRIC FIRE + BLOOM — the raster path runs the SAME fire the raymarcher
    //  marches (fireEmission: 3-D turbulence puffs, blackbody temperature, absorbing
    //  smoke), as a full-screen pass: reconstruct the view ray, take tmax from the
    //  world's perp-depth so walls occlude it, composite bg·transmittance + emission
    //  into an HDR target, then bright-pass → blur → additive composite so the
    //  white-hot cores BLOOM (the LDR frame has no HDR of its own). Same code as the
    //  GPU → same look.
    static let fireSrc = """
    #include <metal_stdlib>
    using namespace metal;

    struct FireEmitter { float4 p0, p1, p2; };
    struct FireU { float4x4 invVP; float4 eye; float4 camFwd; float4 misc; };   // eye.w=time · camFwd.w=ceilH · misc=(count,W,H,0)
    struct Fx { float4 a; };                                                    // blur: a=(dirX,dirY,W,H) · composite: a=(bloomGain,0,W,H)
    struct FSOut { float4 clip [[position]]; };

    // ── ported verbatim from GPURaymarch (the raymarcher's fire) ──
    static inline float f_hash13(float3 p){ p=fract(p*0.1031); p+=dot(p,p.zyx+31.32); return fract((p.x+p.y)*p.z); }
    static inline float f_vnoise3(float3 p){
        float3 i=floor(p), f=fract(p); f=f*f*(3.0-2.0*f);
        float a=f_hash13(i+float3(0,0,0)), b=f_hash13(i+float3(1,0,0));
        float c=f_hash13(i+float3(0,1,0)), d=f_hash13(i+float3(1,1,0));
        float e=f_hash13(i+float3(0,0,1)), g=f_hash13(i+float3(1,0,1));
        float h=f_hash13(i+float3(0,1,1)), k=f_hash13(i+float3(1,1,1));
        return mix(mix(mix(a,b,f.x),mix(c,d,f.x),f.y), mix(mix(e,g,f.x),mix(h,k,f.x),f.y), f.z);
    }
    static inline float f_fbm3(float3 p){ float s=0.0,a=0.5; for(int i=0;i<3;i++){ s+=a*f_vnoise3(p); p*=2.02; a*=0.5; } return s; }
    static inline float3 f_blackbody(float T){ T=clamp(T,0.0,1.0); return float3(1.90*T, 1.15*T*T*T, 0.35*T*T*T*T*T); }

    static inline float3 fireEmission(float3 ro, float3 rd, float tmax, float ceilH,
                                      constant FireEmitter* F, int n, float time, thread float& bgTransOut) {
        float3 acc = float3(0.0);
        float bgTrans = 1.0;
        for (int i = 0; i < n; i++) {
            float3 base = F[i].p0.xyz;  float baseR = F[i].p0.w;
            float3 flow = F[i].p1.xyz;  float len   = F[i].p1.w;
            float vigor = F[i].p2.x;    float seed  = F[i].p2.y;
            bool  jet   = F[i].p2.z > 0.5;  float smokeBias = F[i].p2.w;
            float3 bc = base + flow * (len * 0.5);
            float  bR = len * 0.6 + baseR * 2.4 + 0.35;
            float3 oc = ro - bc; float bq = dot(oc, rd);
            if (bq * bq - (dot(oc, oc) - bR * bR) <= 0.0) continue;
            float3 up = fabs(flow.y) < 0.9 ? float3(0,1,0) : float3(1,0,0);
            float3 e1 = normalize(cross(flow, up));
            float3 e2 = cross(flow, e1);
            float fk    = 0.80 + 0.14 * sin(time * 11.0 + seed * 6.3) + 0.10 * sin(time * 27.0 + seed * 15.1);
            float opac  = clamp(vigor * 0.60, 0.38, 1.0);
            float bright= clamp(vigor * 0.85, 0.30, 1.6) * fk;
            int   NP    = jet ? 8 : 10;
            float rate  = jet ? 2.2 : 0.9;
            float drift = fract(time * rate);
            float scr   = jet ? 3.2 : 1.7;
            float trans = 1.0;
            float3 localAcc = float3(0.0);
            for (int k = 0; k < NP; k++) {
                float age  = (float(k) + drift) / float(NP);
                float fade = smoothstep(0.0, 0.10, age) * (1.0 - smoothstep(0.86, 1.0, age));
                if (fade < 0.02) continue;
                float ph  = seed * 6.3 + float(k) * 1.7;
                float wob = baseR * (jet ? 0.35 : 0.85) * (0.35 + 1.9 * age);
                float wa  = sin(age * 5.1 + ph)       + 0.5 * sin(age * 11.7 + ph * 1.7);
                float wb  = cos(age * 4.3 + ph * 1.3) + 0.5 * sin(age *  9.3 + ph * 0.7);
                float3 C  = base + flow * (age * len) + (e1 * wa + e2 * wb) * (wob * 0.5);
                if (!jet) C.y = min(C.y, ceilH - 0.05);
                float R = jet ? baseR * (0.16 + 1.05 * age) : baseR * (0.45 + 0.75 * age);
                float3 rel = ro - C;
                float b2 = dot(rel, rd);
                float c2 = dot(rel, rel) - R * R;
                float disc = b2 * b2 - c2;
                if (disc <= 0.0) continue;
                float sq = sqrt(disc);
                float t0 = max(0.0, -b2 - sq);
                float t1 = min(tmax, -b2 + sq);
                if (t1 <= t0) continue;
                float thick = (t1 - t0) / (2.0 * R);
                float3 sp   = (ro + rd * t0) * 7.0 - flow * (time * scr) + seed * 11.0;
                float  turb = f_fbm3(sp);
                float dens = smoothstep(0.05, 0.42, thick - (0.72 - turb) * 0.60) * fade;
                if (dens < 0.004) continue;
                float axial = jet ? (1.0 - 0.65 * age) : (smoothstep(0.0, 0.16, age) * (1.0 - 0.75 * age));
                float heat  = clamp(axial * (0.35 + 0.85 * turb) * (0.50 + 0.65 * thick), 0.0, 1.0);
                float smokeF= smoothstep(0.42 - 0.14 * smokeBias, 0.88, age);
                float flameA= dens * opac * (1.0 - smokeF);
                float smokeA= dens * (0.55 + 0.40 * smokeBias) * smokeF;
                float3 emis     = f_blackbody(heat) * bright;
                float3 smokeCol = mix(float3(0.05,0.035,0.028), float3(0.012,0.012,0.013), smokeF);
                localAcc += emis * (flameA * trans) + smokeCol * (smokeA * trans);
                trans    *= (1.0 - flameA) * (1.0 - smokeA);
                if (trans < 0.02) break;
            }
            acc += localAcc * bgTrans;
            bgTrans *= trans;
        }
        bgTransOut = bgTrans;
        return acc * 2.0;
    }

    vertex FSOut fs_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
        FSOut o; o.clip = float4(p[vid], 0, 1); return o;
    }

    // FIRE → HDR (bg·transmittance + emission)
    fragment float4 fire_frag(FSOut in [[stage_in]],
                              constant FireU& U [[buffer(0)]],
                              constant FireEmitter* F [[buffer(1)]],
                              texture2d<float> bgTex [[texture(0)]],
                              texture2d<float> perpTex [[texture(1)]]) {
        float2 uv = in.clip.xy / U.misc.yz;                               // pixel → 0..1 (top-left origin)
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);          // Metal NDC: +Y up
        float4 wf = U.invVP * float4(ndc, 1.0, 1.0); wf /= wf.w;          // far-plane world point
        float3 ro = U.eye.xyz;
        float3 rd = normalize(wf.xyz - ro);
        float perp = perpTex.sample(s, uv).r;
        float denom = max(1e-3, dot(rd, U.camFwd.xyz));
        float tmax = perp >= 1e8 ? 1e8 : perp / denom;                   // perp-depth → ray distance
        float4 bg = bgTex.sample(s, uv);
        float bgTrans;
        float3 emis = fireEmission(ro, rd, tmax, U.camFwd.w, F, int(U.misc.x), U.eye.w, bgTrans);
        float emL = dot(emis, float3(0.299, 0.587, 0.114));                  // fire cores glow
        return float4(bg.rgb * bgTrans + emis, max(bg.a * bgTrans, min(emL, 1.0)));   // preserve world emission mask under the flame
    }

    // BRIGHT-PASS — bloom the EMITTERS only, via the emission mask in alpha (fixtures, plasma cells, LEDs,
    // lit screens, fire cores). A bright-LIT wall has alpha 0 and never blooms — no headlamp white-out.
    fragment float4 bright_frag(FSOut in [[stage_in]], constant Fx& X [[buffer(0)]], texture2d<float> src [[texture(0)]]) {
        float2 uv = in.clip.xy / X.a.zw;
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c = src.sample(s, uv);
        return float4(c.rgb * clamp(c.a, 0.0, 1.0), 1.0);
    }

    // separable Gaussian blur (a.xy = texel step)
    fragment float4 blur_frag(FSOut in [[stage_in]], constant Fx& X [[buffer(0)]], texture2d<float> src [[texture(0)]]) {
        float2 uv = in.clip.xy / X.a.zw;
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float w[5] = { 0.227027, 0.194595, 0.121622, 0.054054, 0.016216 };
        float3 acc = src.sample(s, uv).rgb * w[0];
        for (int i = 1; i < 5; i++) {
            acc += src.sample(s, uv + X.a.xy * float(i)).rgb * w[i];
            acc += src.sample(s, uv - X.a.xy * float(i)).rgb * w[i];
        }
        return float4(acc, 1.0);
    }

    // FINAL TONEMAP — HDR frame + bloom → the headlamp grade (dim + warm/cool luma tint), ACES filmic
    // tonemap, gamma and vignette, all applied ONCE to the whole composited frame → 8-bit. (X.a.x = bloom gain.)
    fragment float4 composite_frag(FSOut in [[stage_in]], constant Fx& X [[buffer(0)]],
                                   texture2d<float> hdr [[texture(0)]], texture2d<float> bloom [[texture(1)]],
                                   texture2d<float> perp [[texture(2)]]) {
        float2 uv = in.clip.xy / X.a.zw;
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float bloomMask = perp.sample(s, uv).r < 0.0 ? 0.0 : 1.0;             // no bloom bleed over the viewmodel (perp<0) — keeps the gun opaque
        float3 c = hdr.sample(s, uv).rgb + X.a.x * bloom.sample(s, uv).rgb * bloomMask;    // HDR world/fire + bloom
        c *= 0.9;                                                             // headlamp dim
        float lum = dot(c, float3(0.299, 0.587, 0.114));
        c = mix(c * float3(0.84, 0.96, 1.16), c * float3(1.14, 1.0, 0.80), clamp(lum, 0.0, 1.0));   // cool shadows, warm highs
        c = (c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14);         // ACES filmic
        c = pow(clamp(c, 0.0, 1.0), float3(1.0 / 2.2));                       // gamma
        float2 dd = uv * 2.0 - 1.0; c *= 1.0 - 0.20 * dot(dd, dd);            // vignette
        return float4(c, 1.0);
    }
    """

    // ── particle billboards ───────────────────────────────────────────────────
    // The quads arrive already projected (see buildParticles), so this stage only culls, shades the
    // radial profile and blends. Output is PREMULTIPLIED: alpha 0 = pure addition (flame, sparks),
    // alpha = coverage = ordinary alpha blending (smoke, steam).
    static let particleSrc = """
    #include <metal_stdlib>
    using namespace metal;
    struct SV { float2 clip; float2 local; float4 rgba; float4 misc; };
    struct SO { float4 pos [[position]]; float2 local; float4 rgba; float mode; };

    vertex SO spr_vertex(uint vid [[vertex_id]],
                         const device SV* v [[buffer(0)]],
                         texture2d<float> scenePerp [[texture(0)]]) {
        SV s = v[vid];
        SO o;
        o.local = s.local; o.rgba = s.rgba; o.mode = s.misc.w;
        // Whole-sprite occlusion, from ONE sample at the sprite's centre — the same test the CPU
        // compositor made, so a spark behind a sealed door stays hidden. Doing it here rather than
        // per fragment means an occluded sprite costs six vertex invocations and no shading at all:
        // collapse it to a point outside the clip volume and the rasteriser drops it.
        if (s.misc.z >= scenePerp.read(uint2(s.misc.xy)).r) { o.pos = float4(2.0, 2.0, 2.0, 1.0); return o; }
        o.pos = float4(s.clip, 0.0, 1.0);
        return o;
    }

    fragment float4 spr_frag(SO in [[stage_in]]) {
        if (in.mode > 1.5) {
            // SPARK — a sharp glint with a comet streak trailing UP through its arc. `local` is in
            // PIXELS here: the CPU path drew a 1px core plus six fading pixels above it, which is
            // one analytic taper. −y is up.
            float q = length(in.local);
            float core = smoothstep(1.7, 0.0, q);
            float tail = (in.local.y < 0.0 && abs(in.local.x) < 0.9) ? max(0.0, 1.0 + in.local.y / 7.0) : 0.0;
            float a = in.rgba.a * max(core, tail);
            return float4(in.rgba.rgb * a, 0.0);                       // additive
        }
        // SOFT ORB — the CPU path's falloff table was (1 − sqrt(d²/r²))², i.e. (1 − d/r)² exactly;
        // evaluated here instead of read from a 257-entry LUT, so it is the same curve without the
        // quantisation. Radial cutoff keeps the quad's corners out of the blend.
        float q = length(in.local);
        if (q > 1.0) discard_fragment();
        float f = 1.0 - q; f *= f;
        float a = in.rgba.a * f;
        return float4(in.rgba.rgb * a, in.mode > 0.5 ? 0.0 : a);       // 1 = additive flame · 0 = alpha smoke
    }
    """

    // ── headless preview (CITADEL_RASTERSHOT=<dir>) ───────────────────────────
    #if CITADEL_HARNESS
    static func shot(outDir: String?) {
        guard let device = MTLCreateSystemDefaultDevice(), let rr = RasterRenderer(device: device) else {
            print("RASTERSHOT: no device/renderer"); return
        }
        let base = outDir.map { ($0 as NSString).expandingTildeInPath } ?? ("~/Desktop" as NSString).expandingTildeInPath
        let dir = URL(fileURLWithPath: base, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let canvas = Canvas2D()
        for (n, seed) in [UInt64(3), 7, 12].enumerated() {
            let world = World(level: 1, colonyIndex: 0, seed: seed)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            // frame a prop: stand in a nearby open cell and look straight at it
            func aimAt(_ target: SIMD2<Float>) -> Bool {
                let tx = Int(target.x), ty = Int(target.y)
                for rad in [2, 3, 4, 5] {
                    for (dx, dy) in [(0, rad), (0, -rad), (rad, 0), (-rad, 0), (rad, rad), (-rad, -rad), (rad, -rad), (-rad, rad)] {
                        guard op(tx + dx, ty + dy) else { continue }
                        let cpos = SIMD2(Float(tx + dx) + 0.5, Float(ty + dy) + 0.5)
                        world.player.pos = cpos
                        world.player.dir = atan2f(target.y - cpos.y, target.x - cpos.x)
                        return true
                    }
                }
                return false
            }
            // seed 0 → a drum, 1 → a socket, 2 → furniture — each falls through if that type is absent
            let drum = world.drums.first.map { $0.pos }
            let sock = world.sockets.first.map { $0.pos }
            let furn = world.props.first(where: { $0.kind != .papers && $0.kind != .wallPipe }).map { $0.pos }
            let order: [SIMD2<Float>?] = [[drum, sock, furn], [sock, furn, drum], [furn, drum, sock]][n]
            var framed = false
            for target in order.compactMap({ $0 }) where aimAt(target) { framed = true; break }
            if !framed {   // no props in this seed → fall back to a long open vista
                let dirs: [(Int, Int, Float)] = [(1, 0, 0), (-1, 0, .pi), (0, 1, .pi / 2), (0, -1, -.pi / 2)]
                search: for cy in 2..<(m.h - 2) { for cx in 2..<(m.w - 2) where op(cx, cy) {
                    for (dx, dy, ang) in dirs {
                        var k = 1; while k < 8 && op(cx + dx * k, cy + dy * k) { k += 1 }
                        if k >= 6 { world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy) + 0.5); world.player.dir = ang; break search }
                    }
                } }
            }
            _ = rr.render(world, into: canvas)
            let name = "raster-L1-\(n).png"
            Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent(name))
            print("RASTERSHOT: wrote \(name) (seed \(seed))")
        }

        // dedicated soft-shadow check: a drum placed one cell off-centre under a ceiling lamp
        // (so the floor pool is lit AND the lamp is up-and-to-one-side → a long cast shadow),
        // camera low a few cells back looking at it — the cast shadow falls across the lit pool.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            search: for cy in 4..<(m.h - 4) { for cx in 4..<(m.w - 5) where cx % 4 == 2 && cy % 4 == 2 && op(cx, cy) {
                // need a lateral open run EAST of the lamp for a side-on camera, and the drum cell
                guard op(cx, cy + 1), op(cx + 1, cy + 1), op(cx + 2, cy + 1), op(cx + 3, cy + 1), op(cx + 4, cy + 1) else { continue }
                world.drums.append(Drum(pos: SIMD2(Float(cx) + 0.5, Float(cy + 1) + 0.5), fuel: 100, health: 30))  // 1 cell S of the lamp → shadow throws S
                world.player.pos = SIMD2(Float(cx + 4) + 0.5, Float(cy + 1) + 0.5)                                 // stand 4 cells E, at the drum's row
                world.player.dir = .pi                                                                            // face west, drum side-on → its floor shadow lies across the lit pool
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-shadow.png"))
                print("RASTERSHOT: wrote raster-shadow.png (drum under lamp, side-on)")
                break search
            } }
        }

        // corridor light-STABILITY check (matches Jonathan's view; headlamp off): look down a
        // long straight run from two positions 3 cells apart. The far lamp pools should be
        // present and IDENTICAL between the two — any pop/occlusion of a distant pool shows here.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 7)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            let dirs: [(Int, Int, Float)] = [(1, 0, 0), (-1, 0, .pi), (0, 1, .pi / 2), (0, -1, -.pi / 2)]
            outer: for cy in 2..<(m.h - 2) { for cx in 2..<(m.w - 2) where op(cx, cy) {
                for (dx, dy, ang) in dirs {
                    var k = 1; while k < 24 && op(cx + dx * k, cy + dy * k) { k += 1 }
                    if k >= 14 {   // a long straight run
                        for (n, step) in [0, 3].enumerated() {
                            world.player.pos = SIMD2(Float(cx + dx * step) + 0.5, Float(cy + dy * step) + 0.5)
                            world.player.dir = ang
                            _ = rr.render(world, into: canvas)
                            Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-corr-\(n).png"))
                        }
                        print("RASTERSHOT: wrote raster-corr-0/1.png (corridor, 2 positions 3 cells apart)")
                        break outer
                    }
                }
            } }
        }

        // GRATE-CELL check (the "hard dark quad on the floor" culprit was a lone grate/metal floor cell
        // meeting concrete at a razor grid line): DETERMINISTICALLY stamp a grate cell INSIDE a lamp pool
        // (so it is well lit by the overhead pool, headlamp off) and frame it from a few cells back. After
        // the buildMesh cross-cell material feathering it must read as a SOFT-EDGED darker iron patch that
        // fades into the concrete over ~0.5 m — NOT a razor-sharp grid-aligned quad. The map floor is
        // mutated BEFORE the first render() so the fresh mesh bakes the grate.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            search: for cy in 4..<(m.h - 4) { for cx in 4..<(m.w - 4) where cx % 4 == 2 && cy % 4 == 2 && op(cx, cy) {
                // a clear run EAST of the lamp to stand a grate 1 cell out (in the pool) + a camera 3 cells out
                guard op(cx + 1, cy), op(cx + 2, cy), op(cx + 3, cy), op(cx + 4, cy) else { continue }
                m.floor[m.idx(cx + 1, cy)] = FlatTex.grate.rawValue   // grate one cell E of the lamp → inside its lit pool
                world.player.pos = SIMD2(Float(cx + 4) + 0.5, Float(cy) + 0.5)
                world.player.dir = .pi                                // face W, back over the grate toward the lamp
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-grate.png"))
                print("RASTERSHOT: wrote raster-grate.png (grate in lamp pool at \(cx + 1),\(cy))")
                break search
            } }
        }

        // ITEMS check (M4): line a spread of pickup kinds across a lamp pool and frame them from a few
        // cells back — verify the hover, the slow spin, the emissive parts (cell rings / lamps) and the
        // PBR metal all read, and that each pickup is lit + grounded by the overhead pool like the props.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            let kinds: [ItemKind] = [.stim, .ammoCells, .weaponRocket]
            search: for cy in 4..<(m.h - 4) { for cx in 4..<(m.w - 4) where cx % 4 == 2 && cy % 4 == 2 && op(cx, cy) {
                guard op(cx - 1, cy), op(cx + 1, cy), op(cx, cy + 1), op(cx, cy + 2), op(cx, cy + 3) else { continue }
                world.items = [
                    Item(kind: kinds[0], pos: SIMD2(Float(cx - 1) + 0.5, Float(cy) + 0.5)),
                    Item(kind: kinds[1], pos: SIMD2(Float(cx)     + 0.5, Float(cy) + 0.5)),
                    Item(kind: kinds[2], pos: SIMD2(Float(cx + 1) + 0.5, Float(cy) + 0.5)),
                ]
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy + 3) + 0.5)
                world.player.dir = -.pi / 2                            // face N (−y), toward the row of pickups under the lamp
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-items.png"))
                print("RASTERSHOT: wrote raster-items.png (\(kinds.count) pickups in a lamp pool at \(cx),\(cy))")
                break search
            } }
        }

        // CREATURES check (M4): drop a DRONE + the QUEEN into a lamp-lit room and frame them — verify the
        // animated meshes composite over the raster world, are occluded by geometry via the perp-depth,
        // stand on the floor, face right, and are lit consistently with the room.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            // any open patch with two side-by-side creature cells + a 4-cell standback (creatures are
            // lit by the mesh shader's own camera fill, so no lamp is required to see them)
            search: for cy in 3..<(m.h - 6) { for cx in 3..<(m.w - 3) where op(cx, cy) {
                guard op(cx - 1, cy), op(cx + 1, cy), op(cx, cy + 1), op(cx, cy + 2),
                      op(cx, cy + 3), op(cx, cy + 4) else { continue }
                var drone = Monster(kind: .alien, pos: SIMD2(Float(cx - 1) + 0.5, Float(cy) + 0.5))
                drone.dir = .pi / 2; drone.state = .chase              // face S toward the camera, mid-stride
                let queen = Monster(kind: .queen, pos: SIMD2(Float(cx + 1) + 0.5, Float(cy) + 0.5))
                world.monsters = [drone, queen]
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy + 4) + 0.5)
                world.player.dir = -.pi / 2                            // face N toward the creatures
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-creatures.png"))
                print("RASTERSHOT: wrote raster-creatures.png (drone+queen at \(cx),\(cy))")
                break search
            } }
        }

        // WALL-CLIP check (M4 corner-merge fix + the close-up merge Jonathan flagged 2026-07-26): stand a
        // drone straddling a wall boundary (body centre ON the wall face) with the camera CLOSE and head-on,
        // so its INSIDE half must be discarded by the distance-field clip → a clean cut at the wall, not a
        // drone smeared into it. The close framing matches the in-game case (a drone right in the player's face).
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            func solid(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] != 0 && m.doors[m.idx(x, y)] == nil }
            search: for cy in 3..<(m.h - 3) { for cx in 4..<(m.w - 4)
                where op(cx, cy) && solid(cx - 1, cy) {                 // open cell with a SOLID west neighbour (wall face at x = cx)
                guard op(cx + 1, cy), op(cx + 2, cy), op(cx + 3, cy) else { continue }   // open run EAST for the camera to stand back
                var drone = Monster(kind: .alien, pos: SIMD2(Float(cx), Float(cy) + 0.5))   // centre ON the wall face → west half is inside the wall
                drone.dir = 0; drone.state = .chase
                world.monsters = [drone]; world.props = []; world.drums = []; world.items = []; world.sockets = []
                world.player.pos = SIMD2(Float(cx + 3) + 0.5, Float(cy) + 0.5)             // ~3 cells EAST, head-on
                world.player.dir = .pi                                                     // face WEST → drone big in frame, west wall right behind it
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-creature-clip.png"))
                print("RASTERSHOT: wrote raster-creature-clip.png (drone on wall face at \(cx),\(cy))")
                break search
            } }
        }

        // WALL-MERGE repro (Jonathan 2026-07-26): a drone whose body pokes LATERALLY into a SIDE wall,
        // framed like the in-game shot (wall running away on the right, creature extent lapping into it).
        // The clip should cut the drone at the side-wall face; a smear across the wall means it isn't.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            func solid(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] != 0 && m.doors[m.idx(x, y)] == nil }
            search: for cy in 4..<(m.h - 3) { for cx in 4..<(m.w - 4)
                where op(cx, cy) && solid(cx + 1, cy) && op(cx, cy - 1) {   // open cell, SOLID east neighbour (side wall at x = cx+1), open north
                guard op(cx, cy + 1), op(cx, cy + 2), op(cx, cy + 3) else { continue }
                var drone = Monster(kind: .alien, pos: SIMD2(Float(cx) + 0.85, Float(cy) + 0.5))   // pushed EAST → its right side laps into the side wall
                drone.dir = -.pi / 2; drone.state = .chase
                world.monsters = [drone]; world.props = []; world.drums = []; world.items = []; world.sockets = []
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy + 3) + 0.5)   // ~3 cells SOUTH, side wall recedes on the right
                world.player.dir = -.pi / 2                                       // face NORTH toward the drone
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-wallmerge.png"))
                print("RASTERSHOT: wrote raster-wallmerge.png (drone lapping a side wall at \(cx),\(cy))")
                break search
            } }
        }

        // SNOUT-INTO-WALL repro (Jonathan 2026-07-26): the drone FACES a wall so its long snout pokes
        // straight INTO it. The body push-out clears the lateral footprint but NOT the forward snout
        // reach, so this is the case still broken — the snout enters the wall and the backstop clip saws
        // it. Framed side-on so the snout crossing the wall face reads clearly. THE repro to fix.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            func solid(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] != 0 && m.doors[m.idx(x, y)] == nil }
            search: for cy in 4..<(m.h - 4) { for cx in 5..<(m.w - 4)
                where op(cx, cy) && solid(cx - 1, cy) {                       // open cell, SOLID west neighbour (wall face at x = cx)
                guard op(cx + 1, cy), op(cx + 2, cy), op(cx, cy + 1), op(cx + 1, cy + 1), op(cx + 1, cy + 2) else { continue }
                var drone = Monster(kind: .alien, pos: SIMD2(Float(cx) + 0.5, Float(cy) + 0.5))
                drone.dir = .pi; drone.state = .chase                        // face WEST → the snout drives into the west wall
                world.monsters = [drone]; world.props = []; world.drums = []; world.items = []; world.sockets = []
                world.player.pos = SIMD2(Float(cx + 2) + 0.5, Float(cy + 2) + 0.5)                        // SE of the drone
                world.player.dir = atan2(Float(cy) - Float(cy + 2), Float(cx) - Float(cx + 2))            // face NW toward drone + west wall
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-snoutmerge.png"))
                print("RASTERSHOT: wrote raster-snoutmerge.png (drone snout into west wall at \(cx),\(cy))")
                break search
            } }
        }

        // SNOUT-DEEP repro: a drone pressed HARD against a wall it faces dead-on, framed CLOSE and side-on
        // so the snout↔wall meeting fills the frame (the point-blank case Jonathan sees). Stress-tests the
        // conform at the deepest realistic penetration — the snout must mold onto the face, not spear through.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            func solid(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] != 0 && m.doors[m.idx(x, y)] == nil }
            search: for cy in 4..<(m.h - 4) { for cx in 5..<(m.w - 4)
                where op(cx, cy) && solid(cx - 1, cy) {                       // west wall face at x = cx
                guard op(cx, cy + 1), op(cx, cy + 2), op(cx + 1, cy), op(cx + 1, cy + 1), op(cx + 1, cy + 2) else { continue }
                var drone = Monster(kind: .alien, pos: SIMD2(Float(cx) + 0.1, Float(cy) + 0.5))   // jammed at the wall
                drone.dir = .pi; drone.rearAmt = 0; drone.state = .chase                          // face WEST dead-on, snout low + forward
                world.monsters = [drone]; world.props = []; world.drums = []; world.items = []; world.sockets = []
                world.player.pos = SIMD2(Float(cx) + 0.9, Float(cy + 2) + 0.4)                    // CLOSE, just south-east
                world.player.dir = atan2(Float(cy) + 0.3 - (Float(cy + 2) + 0.4), Float(cx) - 0.15 - (Float(cx) + 0.9))   // aim at the snout/wall corner
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-snoutdeep.png"))
                print("RASTERSHOT: wrote raster-snoutdeep.png (drone jammed at west wall at \(cx),\(cy))")
                break search
            } }
        }

        // POCKET repro (Jonathan 2026-07-26): a drone cornered in a 1-wide DEAD-END (walls N, E, W; open S)
        // facing the back wall. Push-out can only shove it SOUTH, so the long snout stays JAMMED inside the
        // north wall — the head-genuinely-inside case the open-room repros couldn't force. Camera behind, as
        // in-game. THE test that the planar clip culls the in-wall snout cleanly (flat cut, no distortion).
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            func solid(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] != 0 && m.doors[m.idx(x, y)] == nil }
            _ = solid   // (pocket is constructed below, not searched for)
            search: for cy in 6..<(m.h - 6) { for cx in 5..<(m.w - 5)
                where cx % 4 == 2 && cy % 4 == 2 && op(cx, cy) {
                guard op(cx, cy + 1), op(cx, cy + 2), op(cx, cy + 3) else { continue }               // open run to the south
                m.wall[m.idx(cx, cy - 1)] = WallTex.steelPanel.rawValue                               // CONSTRUCT a 1-wide dead-end:
                m.wall[m.idx(cx - 1, cy)] = WallTex.steelPanel.rawValue                               //   back (N) + sides (E, W)
                m.wall[m.idx(cx + 1, cy)] = WallTex.steelPanel.rawValue
                var drone = Monster(kind: .alien, pos: SIMD2(Float(cx) + 0.5, Float(cy) + 0.3))
                drone.dir = -.pi / 2; drone.rearAmt = 0; drone.state = .chase                         // face NORTH into the dead-end
                world.monsters = [drone]; world.props = []; world.drums = []; world.items = []; world.sockets = []
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy + 3) + 0.5)                        // BEHIND the drone
                world.player.dir = -.pi / 2
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-conformwarp.png"))
                print("RASTERSHOT: wrote raster-conformwarp.png (drone jammed in a pocket at \(cx),\(cy))")
                break search
            } }
        }

        // EFFECTS check (M5): spawn fire + spark + smoke particles and a plasma bolt in front of the
        // camera and confirm the CPU sprite compositor draws them over the lit world, depth-occluded.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            search: for cy in 3..<(m.h - 5) { for cx in 3..<(m.w - 3) where op(cx, cy) {
                guard op(cx, cy + 1), op(cx, cy + 2), op(cx, cy + 3) else { continue }
                let o = SIMD2<Float>(Float(cx) + 0.5, Float(cy) + 0.5)   // effect origin, 3 cells ahead of the camera
                for i in 0..<12 { let a = Float(i)                       // rising flame column (additive age-ramp)
                    world.particles.append(Particle(pos: o + SIMD2(sinf(a) * 0.12, cosf(a * 1.3) * 0.12), vel: .zero,
                        life: 0.6, maxLife: 0.8, color: 0, size: 1.5, height: 0.25 + a * 0.05, rise: 0.4, maxAlpha: 1, fire: true)) }
                for i in 0..<8 { let a = Float(i) * 0.8                  // sparks (additive coloured glints)
                    world.particles.append(Particle(pos: o, vel: SIMD2(cosf(a), sinf(a)) * 2, life: 0.4, maxLife: 0.5,
                        color: packRGBA(255, 200, 90), size: 1, height: 0.5, rise: 0, maxAlpha: 1, fire: true)) }
                for i in 0..<6 { let a = Float(i)                       // smoke wisps (soft alpha)
                    world.particles.append(Particle(pos: o + SIMD2(0, 0.08 * a), vel: .zero, life: 1.0, maxLife: 1.2,
                        color: packRGBA(64, 64, 70), size: 2.2, height: 0.9 + a * 0.1, rise: 0.3, maxAlpha: 0.5, fire: false)) }
                world.projectiles.append(Projectile(pos: o + SIMD2(0.5, 0), vel: SIMD2(0, -4), kind: .plasma, damage: 20, fromPlayer: true, life: 2))
                world.projectiles.append(Projectile(pos: o + SIMD2(-0.7, 0.2), vel: SIMD2(-7, 0), kind: .rocket, damage: 60, fromPlayer: true, life: 3))   // fast, sideways → verify the streak points along travel
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy + 3) + 0.5)
                world.player.dir = -.pi / 2
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-effects.png"))
                print("RASTERSHOT: wrote raster-effects.png (fire/spark/smoke + plasma bolt at \(cx),\(cy))")
                break search
            } }
        }

        // DECALS check (M5): stamp blood / scorch / scattered-papers on the floor of a lamp-lit room and
        // frame them — confirm the floor fragment blends each type (dark wet pool / charred black / pale
        // sheets) with soft noise-eroded edges, lit by the pool, on the raster floor.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            search: for cy in 4..<(m.h - 4) { for cx in 4..<(m.w - 4) where cx % 4 == 2 && cy % 4 == 2 && op(cx, cy) {
                guard op(cx - 1, cy), op(cx + 1, cy), op(cx, cy + 1), op(cx, cy + 2), op(cx, cy + 3) else { continue }
                world.decals = [
                    SIMD4(Float(cx - 1) + 0.5, Float(cy) + 0.5, 0.6, -1.6),   // blood (w in −2…0)
                    SIMD4(Float(cx)     + 0.5, Float(cy) + 0.5, 0.7,  1.0),   // scorch (w 0…2)
                    SIMD4(Float(cx + 1) + 0.5, Float(cy) + 0.5, 0.6,  3.7),   // scattered papers (w>3)
                ]
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy + 3) + 0.5)
                world.player.dir = -.pi / 2
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-decals.png"))
                print("RASTERSHOT: wrote raster-decals.png (blood/scorch/papers at \(cx),\(cy))")
                break search
            } }
        }

        // BED check: force a .bunk prop into a lamp-lit room and frame it — verify the imported
        // Institutional Bed mesh loads, orients, scales, sits on the floor, and is lit like the world.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            search: for cy in 4..<(m.h - 4) { for cx in 4..<(m.w - 4) where cx % 4 == 2 && cy % 4 == 2 && op(cx, cy) {
                guard op(cx, cy + 1), op(cx, cy + 2), op(cx, cy + 3) else { continue }
                world.props = [Prop(kind: .bunk, pos: SIMD2(Float(cx) + 0.5, Float(cy) + 0.5), yaw: 0)]
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy + 3) + 0.5)
                world.player.dir = -.pi / 2
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-bed.png"))
                print("RASTERSHOT: wrote raster-bed.png (institutional bed at \(cx),\(cy))")
                break search
            } }
        }

        // VIEWMODEL check: stand in a lamp-lit room and frame each held weapon (plasma / flamethrower /
        // rocket) — verify the first-person gun tessellates from the shared Viewmodel shapes, anchors to the
        // eye, is lit by the room (glinting under the lamp) and blooms its emissive parts (cell / pilot / bead).
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            world.monsters = []; world.props = []; world.drums = []
            search: for cy in 4..<(m.h - 4) { for cx in 4..<(m.w - 4) where cx % 4 == 2 && cy % 4 == 2 && op(cx, cy) {
                guard op(cx, cy - 1), op(cx, cy - 2), op(cx, cy - 3) else { continue }
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy) + 0.5)
                world.player.dir = -.pi / 2                                  // look down −Z into the open room
                for w in WeaponKind.allCases {
                    world.player.current = w
                    _ = rr.render(world, into: canvas)
                    Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-viewmodel-\(w).png"))
                    print("RASTERSHOT: wrote raster-viewmodel-\(w).png (held weapon at \(cx),\(cy))")
                }
                break search
            } }
        }

        // FIRE check: the volumetric fire (raymarcher's fireEmission), run as a raster HDR pass + bloom.
        // Two representative shots at a normal viewing distance (~4 cells back, so the eye is OUTSIDE the
        // plume): a lone burning-corpse PYRE, and the FLAMETHROWER JET. Verify turbulence, blackbody colour,
        // absorbing smoke and the bloomed hot core — occluded by the world via perp-depth.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            world.colonists = []; world.props = []; world.drums = []
            let baseMons = world.monsters
            search: for cy in 8..<(m.h - 4) { for cx in 4..<(m.w - 4) where cx % 4 == 2 && cy % 4 == 2 && op(cx, cy) {
                guard op(cx, cy - 1), op(cx, cy - 2), op(cx, cy - 3), op(cx, cy - 4), op(cx, cy - 5) else { continue }
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy) + 0.5)
                world.player.dir = -.pi / 2                                  // look down −Z
                let fwd = SIMD2<Float>(cosf(world.player.dir), sinf(world.player.dir))
                // 1 · lone PYRE — a mid-burn DRONE corpse ~4 cells ahead, no jet (NOT the Queen — she burns huge)
                world.flameJet = World.FlameJet()
                let dr = baseMons.first(where: { $0.kind == .alien }) ?? baseMons.first
                if var corpse = dr {
                    corpse.pos = SIMD2(Float(cx) + 0.5, Float(cy - 4) + 0.5)
                    corpse.state = .dead; corpse.burn = 0.32; corpse.kind = .alien   // the DRONE caste (not the Queen — she burns huge)
                    world.monsters = [corpse]
                }
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-fire-pyre.png"))
                print("RASTERSHOT: wrote raster-fire-pyre.png (burning corpse ~4 cells ahead at \(cx),\(cy))")
                // 2 · FLAMETHROWER JET — no corpse, jet fired forward down the room
                world.monsters = []
                world.flameJet = World.FlameJet(t: 0.2, nozzle: world.player.pos + fwd * 0.35, dir: fwd, reach: 3.5)
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-fire-jet.png"))
                print("RASTERSHOT: wrote raster-fire-jet.png (flamethrower jet at \(cx),\(cy))")
                break search
            } }
        }

        // DISPLAY WALL check: paint a 3-wide amber CRT bank on a wall ahead and render it at THREE times —
        // verify the live animated monitors (scrolling log / oscilloscope / spectrum / dashboard) genuinely
        // MOVE frame-to-frame, glow and bloom, plus the surrounding walls now carry their baked art.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
            world.monsters = []; world.props = []; world.drums = []; world.colonists = []
            search: for cy in 5..<(m.h - 5) { for cx in 5..<(m.w - 5) where op(cx, cy) {
                guard m.inBounds(cx, cy - 1), m.wall[m.idx(cx, cy - 1)] != 0, m.doors[m.idx(cx, cy - 1)] == nil,
                      op(cx, cy + 1), op(cx, cy + 2) else { continue }
                for dx in -1...1 where m.inBounds(cx + dx, cy - 1) && m.wall[m.idx(cx + dx, cy - 1)] != 0
                                    && m.doors[m.idx(cx + dx, cy - 1)] == nil {
                    m.wall[m.idx(cx + dx, cy - 1)] = WallTex.computer.rawValue          // amber CRT bank
                }
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy + 2) + 0.5)
                world.player.dir = -.pi / 2                                            // face the bank (−Z)
                for (n, t) in [Float(0.0), 0.6, 1.4].enumerated() {
                    world.elapsed = t
                    _ = rr.render(world, into: canvas)
                    Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-display-\(n).png"))
                }
                print("RASTERSHOT: wrote raster-display-0/1/2.png (animated CRT bank at \(cx),\(cy))")
                break search
            } }
        }

        // DOOR check: paint a wall cell ahead as a door and frame it from a few cells back — a RED key door
        // part-open (textured leaves + centre-split gap), then a SECRET door closed (keeps its WALL id, so
        // its leaf textures as the surrounding wall → invisible until it parts).
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
            world.monsters = []; world.props = []; world.drums = []; world.colonists = []
            search: for cy in 5..<(m.h - 5) { for cx in 5..<(m.w - 5) where op(cx, cy) {
                // need a solid wall ahead (cy-1) with solid sides (slide-X) and clear standoff behind
                guard m.inBounds(cx, cy - 1), m.wall[m.idx(cx, cy - 1)] != 0, m.doors[m.idx(cx, cy - 1)] == nil,
                      m.wall[m.idx(cx - 1, cy - 1)] != 0, m.wall[m.idx(cx + 1, cy - 1)] != 0,
                      op(cx, cy + 1), op(cx, cy + 2), op(cx, cy + 3) else { continue }
                let dcell = m.idx(cx, cy - 1)
                let origWall = m.wall[dcell]
                m.wall[m.idx(cx, cy - 2)] = 0                                          // carve a cell behind so the door opens onto a gap
                m.wall[m.idx(cx, cy - 3)] = 0
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy + 2) + 0.5)
                world.player.dir = -.pi / 2
                // 1 · RED key door, part-open
                m.wall[dcell] = WallTex.doorRed.rawValue; m.doors[dcell] = DoorState(open: 0.35)
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-door-red.png"))
                // 2 · SECRET door, closed — keeps the wall id so its leaf reads as the surrounding wall
                m.wall[dcell] = origWall; m.doors[dcell] = DoorState(secret: true)   // open 0 = closed
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-door-secret.png"))
                print("RASTERSHOT: wrote raster-door-red.png + raster-door-secret.png (door at \(cx),\(cy-1))")
                break search
            } }
        }

        // TOXIC-POOL check (M6): flood a 5×5 patch of nukage floor cells in a cleared room, centred OFF the
        // overhead-lamp grid (cx%4==0,cy%4==0 — the point farthest from any lamp) so the lamp doesn't wash
        // the surface white and the pool's OWN green shows — verify the raster floor fragment gives it the
        // LIQUID surface: green self-glow that PULSES, churning ripples off the normal, glassy low roughness.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            func clear() { world.props = []; world.drums = []; world.deployedMines = []; world.sockets = []; world.items = [] }
            search: for cy in 6..<(m.h - 8) { for cx in 6..<(m.w - 6) where cx % 4 == 0 && cy % 4 == 0 && op(cx, cy) {
                guard op(cx, cy + 1), op(cx, cy + 2), op(cx, cy + 3), op(cx, cy + 4), op(cx, cy + 5), op(cx - 1, cy), op(cx + 1, cy) else { continue }
                clear()
                for py in (cy - 2)...(cy + 2) { for px in (cx - 2)...(cx + 2) where op(px, py) {
                    m.floor[m.idx(px, py)] = FlatTex.nukage.rawValue
                } }
                world.elapsed = 3.0                                                   // a non-zero phase so the ripples/glow are mid-animation
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy + 5) + 0.5)        // stand back so the pool is seen at a GRAZING angle (head-on + close, the bright headlamp washes the green out)
                world.player.dir = -.pi / 2
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-toxic.png"))
                print("RASTERSHOT: wrote raster-toxic.png (nukage pool at \(cx),\(cy))")
                break search
            } }
        }

        // STANDING-WATER check (M6): force a 9×9 rock floor in a cleared lamp-lit room — the shared puddle
        // field pools water across roughly half of it, so this frames the representative "water finds its
        // way down" look: dark cool glazed puddles with damp margins, on dry rock, all lit. (The floor-8
        // FLOOD path is the same fragment code with a global wet=0.85 instead of the pooled mask.)
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            search: for cy in 7..<(m.h - 8) { for cx in 7..<(m.w - 7) where cx % 4 == 2 && cy % 4 == 2 && op(cx, cy) {
                guard op(cx, cy + 1), op(cx, cy + 2), op(cx, cy + 3), op(cx, cy + 4), op(cx, cy + 5) else { continue }
                world.props = []; world.drums = []; world.deployedMines = []; world.sockets = []; world.items = []
                for py in (cy - 3)...(cy + 3) { for px in (cx - 3)...(cx + 3) where op(px, py) {
                    m.floor[m.idx(px, py)] = FlatTex.rock.rawValue
                } }
                world.elapsed = 3.0
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy + 5) + 0.5)
                world.player.dir = -.pi / 2
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-water.png"))
                print("RASTERSHOT: wrote raster-water.png (rock puddles at \(cx),\(cy))")
                break search
            } }
        }

        // STEAM check (M6): seat a floor grate and spawn a rising steam PLUME (staggered heights, so one
        // frame shows the column) — confirm the CPU sprite compositor draws the faint grey steam over the
        // lit world, dispersing as it climbs, out of a visible vent grate. (Steam = fire:false particles.)
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            search: for cy in 5..<(m.h - 6) { for cx in 5..<(m.w - 5) where cx % 4 == 2 && cy % 4 == 2 && op(cx, cy) {
                guard op(cx, cy + 1), op(cx, cy + 2), op(cx, cy + 3), op(cx - 1, cy), op(cx + 1, cy),
                      op(cx - 1, cy + 1), op(cx + 1, cy + 1) else { continue }         // a genuinely open bay so the plume isn't lost against a near wall
                world.monsters = []; world.props = []; world.drums = []; world.items = []   // clear so the plume reads against the deck
                m.floor[m.idx(cx, cy)] = FlatTex.grate.rawValue                        // the vent's visible source
                let base = SIMD2<Float>(Float(cx) + 0.5, Float(cy) + 0.5)
                // GRATE first, with NO plume — the dense steam hides its own source, so verify the vent
                // itself reads as a slotted iron grate cut into the deck (not blank floor) in its own frame.
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy) + 3.6)   // stand back: floor <1 cell ahead falls below the frame edge
                world.player.dir = -.pi / 2
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-vent.png"))
                for k in 0..<50 {                                                      // a plume frozen mid-rise (dense so the compositor's output is unmistakable): height climbs, it spreads + thins
                    let t = Float(k) / 49.0, a = Float(k) * 0.7
                    world.particles.append(Particle(pos: base + SIMD2(sinf(a) * (0.10 + t * 0.30), cosf(a * 1.3) * (0.10 + t * 0.30)),
                        vel: .zero, life: 1.5, maxLife: 1.9, color: packRGBA(210, 214, 220),
                        size: 6 + t * 7, height: 0.05 + t * 0.85, rise: 0.5, maxAlpha: 0.5 * (1.0 - t * 0.4), fire: false))
                }
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy + 2) + 0.5)
                world.player.dir = -.pi / 2
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-steam.png"))
                print("RASTERSHOT: wrote raster-steam.png (steam vent at \(cx),\(cy))")
                break search
            } }
        }

        // DOOR check (parity fix): find a door cell with an open through-side, stand 3 cells back facing
        // it and render it PART-OPEN — verify the sliding centre-split leaves now DRAW (they were never
        // emitted, so doors vanished though they operated: you saw straight through the doorway). The gap
        // between the two panels proves it's a door, not a wall.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
            // SORTED, not dictionary order. Swift randomises hash seeding per process, so iterating
            // m.doors directly framed a DIFFERENT door on every run — the shot could never be compared
            // against a baseline, and eyeballing it compared different subjects. Worse, this block
            // leaves its chosen door part-open on the shared map, so the arbitrary choice leaked into
            // later frames too (shotcheck caught raster-door, raster-tee and raster-industrial all
            // moving between identical runs).
            for i in m.doors.keys.sorted() {
                let cx = i % m.w, cy = i / m.w
                let slideX = (m.inBounds(cx - 1, cy) && m.wall[m.idx(cx - 1, cy)] != 0)
                          && (m.inBounds(cx + 1, cy) && m.wall[m.idx(cx + 1, cy)] != 0)
                let tx = slideX ? 0 : 1, ty = slideX ? 1 : 0                          // through-axis (open passage) direction
                var placed = false
                for sgn in [1, -1] where !placed {                                    // stand on whichever through-side is open
                    guard op(cx + tx * sgn, cy + ty * sgn), op(cx + tx * 3 * sgn, cy + ty * 3 * sgn) else { continue }
                    m.doors[i] = DoorState(open: 0.30)                               // part-open → the centre-split gap shows
                    world.player.pos = SIMD2(Float(cx + tx * 3 * sgn) + 0.5, Float(cy + ty * 3 * sgn) + 0.5)
                    world.player.dir = atan2(Float(-ty * sgn), Float(-tx * sgn))     // face the door
                    _ = rr.render(world, into: canvas)
                    Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-door.png"))
                    print("RASTERSHOT: wrote raster-door.png (\(slideX ? "X" : "Z")-slide door at \(cx),\(cy), part-open)")
                    placed = true
                }
                if placed { break }
            }
        }

        // ELEVATOR check (parity fix): frame the exit elevator — its front IS a door cell, so it vanished
        // with the rest. Stand 3 cells back on its open through-side, force it closed → verify the
        // machined-steel car front renders as a solid leaf (was an open gap into the shaft).
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
            let i = m.exitCell
            if i >= 0, m.doors[i] != nil {
                let cx = i % m.w, cy = i / m.w
                world.monsters = []; world.props = []; world.drums = []   // the Queen spawns AT the exit elevator — clear her so she doesn't fill the view
                let slideX = (m.inBounds(cx - 1, cy) && m.wall[m.idx(cx - 1, cy)] != 0)
                          && (m.inBounds(cx + 1, cy) && m.wall[m.idx(cx + 1, cy)] != 0)
                let tx = slideX ? 0 : 1, ty = slideX ? 1 : 0
                var placed = false
                for sgn in [-1, 1] where !placed {                                    // the room is on the open through-side of the shaft
                    let dist = op(cx + tx * 4 * sgn, cy + ty * 4 * sgn) ? 4
                             : (op(cx + tx * 3 * sgn, cy + ty * 3 * sgn) ? 3 : (op(cx + tx * 2 * sgn, cy + ty * 2 * sgn) ? 2 : 0))
                    guard dist > 0 else { continue }
                    world.player.pos = SIMD2(Float(cx + tx * dist * sgn) + 0.5, Float(cy + ty * dist * sgn) + 0.5)
                    world.player.dir = atan2(Float(-ty * sgn), Float(-tx * sgn))     // face the elevator
                    // CLOSED then OPEN — the pair PROVES the leaf: closed hides the car (grey steel front),
                    // open reveals the lit interior. Before the fix BOTH looked the same (open gap → no leaf).
                    m.doors[i] = DoorState()                                          // closed
                    _ = rr.render(world, into: canvas)
                    Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-elevator.png"))
                    m.doors[i] = DoorState(open: 1.0)                                 // fully parted
                    _ = rr.render(world, into: canvas)
                    Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-elevator-open.png"))
                    // LED CLOSE-UP — step to the car mouth (1 cell out) so the 7-segment floor indicator reads large
                    world.player.pos = SIMD2(Float(cx + tx * sgn) + 0.5, Float(cy + ty * sgn) + 0.5)
                    _ = rr.render(world, into: canvas)
                    Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-elevator-led.png"))
                    print("RASTERSHOT: wrote raster-elevator.png + raster-elevator-open.png + raster-elevator-led.png (exit elevator at \(cx),\(cy), dist \(dist), floor \(world.elevatorFloorDisplay))")
                    placed = true
                }
                if !placed { print("RASTERSHOT: elevator check skipped (no open standoff)") }
            } else {
                print("RASTERSHOT: elevator check skipped (no exit-cell door)")
            }
        }

        // SANITARY check — stand off a trough basin and look along the wash wall, so the pale tile, the mirrors
        // and the showers/cubicles on the neighbouring walls all read.
        for lvl in [3, 4] {
            let world = World(level: lvl, colonyIndex: 0, seed: 3)
            let m = world.map
            world.monsters = []; world.colonists = []
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
            var shot = false
            for pr in world.props where !shot && (pr.kind == .washTrough || pr.kind == .shower) {
                for (dx, dy) in [(0, 1), (0, -1), (1, 0), (-1, 0)] {
                    let sx = Int(pr.pos.x) + dx * 3, sy = Int(pr.pos.y) + dy * 3
                    guard op(sx, sy), op(Int(pr.pos.x) + dx, Int(pr.pos.y) + dy), op(Int(pr.pos.x) + dx * 2, Int(pr.pos.y) + dy * 2) else { continue }
                    world.player.pos = SIMD2(Float(sx) + 0.5, Float(sy) + 0.5)
                    world.player.dir = atan2(Float(-dy), Float(-dx))
                    _ = rr.render(world, into: canvas)
                    Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1,
                                      to: dir.appendingPathComponent("raster-sanitary-\(lvl).png"))
                    let tiles = (0..<(m.w * m.h)).filter { m.wall[$0] == WallTex.sanTile.rawValue }.count
                    let fits = world.props.filter { $0.kind == .washTrough || $0.kind == .shower || $0.kind == .cubicle }.count
                    print("RASTERSHOT: wrote raster-sanitary-\(lvl).png (\(tiles) tiled cells, \(fits) fittings)")
                    shot = true; break
                }
            }
            if !shot { print("RASTERSHOT: sanitary check skipped on level \(lvl)") }
        }

        // CANTEEN check — stand off the range and look down the galley line, so the subway tile, the stainless
        // fittings under the extraction hood and (where they share the room) the dining tables all read.
        for lvl in [3, 4] {
            let world = World(level: lvl, colonyIndex: 0, seed: 3)
            let m = world.map
            world.monsters = []; world.colonists = []
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
            var shot = false
            for pr in world.props where !shot && pr.kind == .range {
                for (dx, dy) in [(0, 1), (0, -1), (1, 0), (-1, 0)] {
                    let sx = Int(pr.pos.x) + dx * 3, sy = Int(pr.pos.y) + dy * 3
                    guard op(sx, sy), op(Int(pr.pos.x) + dx, Int(pr.pos.y) + dy), op(Int(pr.pos.x) + dx * 2, Int(pr.pos.y) + dy * 2) else { continue }
                    world.player.pos = SIMD2(Float(sx) + 0.5, Float(sy) + 0.5)
                    world.player.dir = atan2(Float(-dy), Float(-dx))     // look back at the galley
                    _ = rr.render(world, into: canvas)
                    Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1,
                                      to: dir.appendingPathComponent("raster-canteen-\(lvl).png"))
                    let tiles = (0..<(m.w * m.h)).filter { m.wall[$0] == WallTex.subwayTile.rawValue }.count
                    let tables = world.props.filter { $0.kind == .canteenTable }.count
                    print("RASTERSHOT: wrote raster-canteen-\(lvl).png (\(tiles) tiled cells, \(tables) tables)")
                    shot = true; break
                }
            }
            if !shot { print("RASTERSHOT: canteen check skipped on level \(lvl)") }
        }

        // MEDICAL CENTRE check — stand back from a bed that sits in a white-walled room and look across it, so
        // the sterile surfaces, the ward beds and the stainless fittings all read in one frame.
        for lvl in [1, 3] {
            let world = World(level: lvl, colonyIndex: 0, seed: 3)
            let m = world.map
            world.monsters = []; world.colonists = []
            func medNear(_ p: SIMD2<Float>) -> Bool {                       // a white wall within a cell or two
                let cx = Int(p.x), cy = Int(p.y)
                for oy in -2...2 { for ox in -2...2 {
                    let wx = cx + ox, wy = cy + oy
                    guard m.inBounds(wx, wy) else { continue }
                    if m.wall[m.idx(wx, wy)] == WallTex.medWall.rawValue { return true }
                } }
                return false
            }
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
            var shot = false
            for pr in world.props where !shot && pr.kind == .bunk && medNear(pr.pos) {
                for (dx, dy) in [(0, 1), (0, -1), (1, 0), (-1, 0)] {
                    let sx = Int(pr.pos.x) + dx * 3, sy = Int(pr.pos.y) + dy * 3
                    guard op(sx, sy), op(Int(pr.pos.x) + dx, Int(pr.pos.y) + dy), op(Int(pr.pos.x) + dx * 2, Int(pr.pos.y) + dy * 2) else { continue }
                    world.player.pos = SIMD2(Float(sx) + 0.5, Float(sy) + 0.5)
                    world.player.dir = atan2(Float(-dy), Float(-dx))        // look back at the bed
                    _ = rr.render(world, into: canvas)
                    Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1,
                                      to: dir.appendingPathComponent("raster-medical-\(lvl).png"))
                    let white = (0..<(m.w * m.h)).filter { m.wall[$0] == WallTex.medWall.rawValue }.count
                    let fittings = world.props.filter { $0.kind == .cabinet || $0.kind == .sink }.count
                    print("RASTERSHOT: wrote raster-medical-\(lvl).png (\(white) white-wall cells, \(fittings) stainless fittings)")
                    shot = true; break
                }
            }
            if !shot { print("RASTERSHOT: medical check skipped on level \(lvl)") }
        }

        // OPERATIONS CENTRE check — stand at the back of the room on the board's axis, looking down the ranks of
        // amber consoles at the full-colour big board: the one display in the colony that isn't amber phosphor.
        for lvl in [1, 3] {
            let world = World(level: lvl, colonyIndex: 0, seed: 3)
            let m = world.map
            world.monsters = []; world.colonists = []
            let board = (0..<(m.w * m.h)).filter { m.wall[$0] == WallTex.opsBoard.rawValue }
            guard !board.isEmpty else { print("RASTERSHOT: ops centre check skipped (no board on level \(lvl))"); continue }
            // the board's centre cell, and the room direction is whichever side of it is open
            let bc = board[board.count / 2], bx = bc % m.w, by = bc / m.w
            var rdx = 0, rdy = 0
            for (dx, dy) in [(0, 1), (0, -1), (1, 0), (-1, 0)]
                where m.inBounds(bx + dx, by + dy) && m.wall[m.idx(bx + dx, by + dy)] == 0 { rdx = dx; rdy = dy; break }
            guard rdx != 0 || rdy != 0 else { continue }
            var back = 1                                                       // walk out from the board while open
            while back < 5, m.inBounds(bx + rdx * (back + 1), by + rdy * (back + 1)),
                  m.wall[m.idx(bx + rdx * (back + 1), by + rdy * (back + 1))] == 0 { back += 1 }
            // …and never stand INSIDE a console: its own screen then fills the whole frame (which is exactly
            // how this check first misled me into thinking the board was blown out).
            while back > 1, world.props.contains(where: { $0.kind == .console &&
                  simd_length($0.pos - SIMD2(Float(bx + rdx * back) + 0.5, Float(by + rdy * back) + 0.5)) < 0.7 }) { back -= 1 }
            world.player.pos = SIMD2(Float(bx + rdx * back) + 0.5, Float(by + rdy * back) + 0.5)
            world.player.dir = atan2(Float(-rdy), Float(-rdx))                 // face the board
            _ = rr.render(world, into: canvas)
            Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1,
                              to: dir.appendingPathComponent("raster-ops-\(lvl).png"))
            let consoles = world.props.filter { $0.kind == .console }.count
            print("RASTERSHOT: wrote raster-ops-\(lvl).png (board \(board.count) cells at \(bx),\(by); \(consoles) consoles; stood \(back) back)")
        }

        // CORPSE/DRONE POSE-RESOLVE check — a NUMERIC assertion, not a picture: a body settling into a wall at a
        // corner is near-impossible to stage as a screenshot, but the invariant is exact. Drop a body deep inside
        // every kind of wall corner, over a sweep of facings, resolve it, then measure how far any capsule sample
        // still penetrates a solid. Every case must come out at ~0.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            let back: Float = -0.35, front: Float = 0.45, r: Float = 0.30      // representative drone capsule
            /// How far a circle of radius `rr` at `p` overlaps any blocking cell (0 = clear).
            func penetration(_ p: SIMD2<Float>, _ rr: Float) -> Float {
                var worst: Float = 0
                let cx = Int(p.x.rounded(.down)), cy = Int(p.y.rounded(.down))
                for oy in -1...1 { for ox in -1...1 {
                    let wx = cx + ox, wy = cy + oy
                    guard m.inBounds(wx, wy), m.wall[m.idx(wx, wy)] != 0 else { continue }
                    if let d = m.doors[m.idx(wx, wy)], d.open >= GameMap.passThreshold { continue }
                    if p.x > Float(wx), p.x < Float(wx + 1), p.y > Float(wy), p.y < Float(wy + 1) {
                        let dl = p.x - Float(wx), dr = Float(wx + 1) - p.x, db = p.y - Float(wy), dt = Float(wy + 1) - p.y
                        worst = max(worst, rr + min(min(dl, dr), min(db, dt))); continue      // strictly inside
                    }
                    let nx = min(max(p.x, Float(wx)), Float(wx + 1)), ny = min(max(p.y, Float(wy)), Float(wy + 1))
                    let dist = simd_length(p - SIMD2(nx, ny))
                    if dist < rr { worst = max(worst, rr - dist) }
                } }
                return worst
            }
            func capsuleWorst(_ pos: SIMD2<Float>, _ dir: SIMD2<Float>, _ taperMin: Float) -> Float {
                var worst: Float = 0
                for i in 0...5 {
                    let t = back + (front - back) * Float(i) / 5
                    let taper = t <= 0 ? 1.0 : max(taperMin, 1.0 - 0.6 * (t / max(1e-3, front)))
                    worst = max(worst, penetration(pos + dir * t, r * taper))
                }
                return worst
            }
            // The capsule is bigger than a cell, so total clearance is unachievable in a corridor. The invariant
            // that MUST hold is the TRUNK being clear — a buried trunk is the "body vanished into the wall" bug.
            // Extremity overlap is reported separately and only needs to stay modest.
            var cases = 0, trunkFail = 0
            var trunkBefore: Float = 0, trunkAfter: Float = 0, tipAfter: Float = 0
            for cy in 1..<(m.h - 1) { for cx in 1..<(m.w - 1) where m.wall[m.idx(cx, cy)] == 0 && m.doors[m.idx(cx, cy)] == nil {
                // an OPEN cell touching a wall CORNER — where a body realistically dies and settles
                var solidN = 0
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] where m.wall[m.idx(cx + dx, cy + dy)] != 0 { solidN += 1 }
                guard solidN >= 2 else { continue }                            // two walls meeting = a corner
                if (cx * 7 + cy * 13) % 11 != 0 { continue }                   // sample the map, don't grind all of it
                for k in 0..<8 {                                               // a sweep of facings
                    let ang = Float(k) / 8 * 2 * Float.pi
                    let dir = SIMD2<Float>(cosf(ang), sinf(ang))
                    // start shoved hard INTO the corner, as a death slide would leave it
                    let start = SIMD2<Float>(Float(cx) + 0.5, Float(cy) + 0.5) + dir * 0.45
                    cases += 1
                    trunkBefore = max(trunkBefore, penetration(start, r))
                    let fixed = MeshCreature.resolvePoseOutOfSolids(start, fwd: dir, r: r, back: back, front: front,
                                                                   map: m, props: world.propColliders, taperMin: 0.8)
                    let tp = penetration(fixed, r)
                    trunkAfter = max(trunkAfter, tp)
                    tipAfter = max(tipAfter, capsuleWorst(fixed, dir, 0.8))
                    if tp > 0.02 { trunkFail += 1 }
                }
            } }
            print(String(format: "RASTERSHOT: pose-resolve %d corner cases · TRUNK penetration before %.3f → after %.3f (%d buried) · worst extremity overlap %.3f",
                         cases, trunkBefore, trunkAfter, trunkFail, tipAfter))
        }

        // INDUSTRIAL FLOORS check (7–8): the working plant. Frame the longest clear run in a floor-7 level and
        // the widest room — verify raw ROCK walls with riveted IRON where a run was finished, rock deck, and
        // NO display banks / NO dormitory bunks (those belong to the upper floors).
        do {
            let world = World(level: 7, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
            world.monsters = []; world.colonists = []                     // clear so the architecture reads
            // longest clear axis-run → a corridor/hall view down its length
            var best = (len: 0, x: 0, y: 0, dx: 1, dy: 0)
            for y in 1..<(m.h - 1) { for x in 1..<(m.w - 1) where op(x, y) {
                for (dx, dy) in [(1, 0), (0, 1)] {
                    var n = 0
                    while op(x + dx * n, y + dy * n) { n += 1 }
                    if n > best.len { best = (n, x, y, dx, dy) }
                }
            } }
            if best.len >= 5 {
                world.player.pos = SIMD2(Float(best.x) + 0.5 + Float(best.dx) * 0.6, Float(best.y) + 0.5 + Float(best.dy) * 0.6)
                world.player.dir = atan2(Float(best.dy), Float(best.dx))
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-industrial.png"))
                let banks = (0..<(m.w * m.h)).filter { m.wall[$0] == WallTex.computer.rawValue }.count
                let bunks = world.props.filter { $0.kind == .bunk }.count
                let rock = (0..<(m.w * m.h)).filter { m.wall[$0] == WallTex.stone.rawValue }.count
                let iron = (0..<(m.w * m.h)).filter { m.wall[$0] == WallTex.ironPlate.rawValue }.count
                print("RASTERSHOT: wrote raster-industrial.png (floor 7, run \(best.len) at \(best.x),\(best.y); rock \(rock), iron \(iron), display-bank cells \(banks), bunks \(bunks); static \(rr.totalVertCount) verts, per-frame props \(rr.dynVertCount)/\(rr.dynCapacity))")
            } else { print("RASTERSHOT: industrial check skipped (no long run)") }
            // PIPEWORK — frame a placed FITTING (valve or gauge) head-on: stand a couple of cells off the wall
            // it hangs on, looking at it, so the copper run, its flanges and the fitting all read.
            for f in m.pipeFittings.prefix(24) {
                let fx = Int(f.x), fz = Int(f.y)
                let n2 = SIMD2<Float>(cosf(f.z), sinf(f.z))               // wall outward normal (into the room)
                let sx = f.x + n2.x * 2.1, sz = f.y + n2.y * 2.1
                guard op(Int(sx), Int(sz)), op(Int(f.x + n2.x), Int(f.y + n2.y)) else { continue }
                world.player.pos = SIMD2(sx, sz)
                world.player.dir = atan2(-n2.y, -n2.x)                    // face back at the wall
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-pipework.png"))
                let routedCells = (0..<(m.w * m.h)).filter { m.wall[$0] == 0 && m.pipe[$0] > 0.5 }.count
                print("RASTERSHOT: wrote raster-pipework.png (\(f.w < 0.5 ? "valve" : "gauge") at \(fx),\(fz); \(m.pipeFittings.count) fittings, \(routedCells) routed cells, \(rr.pipeVertCount) pipe verts of \(rr.totalVertCount) total)")
                break
            }
            // TEE + RISER close-up — find the START of a tall stretch along a wall (the renderer feeds the high
            // main there with a single riser off a tee) and stand off it, so the junction bodies read.
            var teeShot = false
            for yy in 1..<(m.h - 1) where !teeShot {
                for xx in 1..<(m.w - 1) where !teeShot {
                    let i = m.idx(xx, yy)
                    guard m.wall[i] == 0, m.pipe[i] > 0.5, m.ceilY[i] > 1.5 else { continue }
                    guard m.inBounds(xx, yy - 1), m.wall[m.idx(xx, yy - 1)] != 0, m.doors[m.idx(xx, yy - 1)] == nil else { continue }
                    let prevI = m.idx(xx - 1, yy)                                      // wall to the N → run travels along X
                    guard !(m.wall[prevI] == 0 && m.pipe[prevI] > 0.5 && m.ceilY[prevI] > 1.5) else { continue }  // a stretch START
                    guard op(xx, yy + 1), op(xx, yy + 2) else { continue }
                    world.player.pos = SIMD2(Float(xx) + 0.85, Float(yy) + 2.3)
                    world.player.dir = -.pi / 2                                        // face the wall the run hugs
                    _ = rr.render(world, into: canvas)
                    Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-tee.png"))
                    print("RASTERSHOT: wrote raster-tee.png (riser + tee at the tall stretch starting \(xx),\(yy))")
                    teeShot = true
                }
            }
            // DOUBLE-HEIGHT HALL — stand in a normal-height cell looking into a tall one, so the storey change
            // and the soffit that closes the step both read in one frame.
            var shot = false
            for yy in 1..<(m.h - 1) where !shot {
                for xx in 1..<(m.w - 1) where !shot && op(xx, yy) && m.ceilY[m.idx(xx, yy)] < 1.5 {
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let tx = xx + dx, ty = yy + dy
                        guard op(tx, ty), m.ceilY[m.idx(tx, ty)] > 1.5 else { continue }        // a tall cell next door
                        guard op(tx + dx * 3, ty + dy * 3) else { continue }                    // and depth beyond it to see
                        world.player.pos = SIMD2(Float(xx) + 0.5, Float(yy) + 0.5)
                        world.player.dir = atan2(Float(dy), Float(dx))
                        _ = rr.render(world, into: canvas)
                        Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-tallhall.png"))
                        let tall = (0..<(m.w * m.h)).filter { m.ceilY[$0] > 1.5 }.count
                        print("RASTERSHOT: wrote raster-tallhall.png (from \(xx),\(yy) into the hall at \(tx),\(ty); \(tall) tall cells)")
                        shot = true; break
                    }
                }
            }
            // BULKHEAD on the plant wall — mirror buildPlantLamps' rule (open cell on the 5/1 grid backing onto
            // solid wall) and stand off it, so the fixture that lights these floors is verified in place.
            outer: for y in 1..<(m.h - 1) where y % 4 == 1 {
                for x in 1..<(m.w - 1) where x % 4 == 1 && op(x, y) {
                    for (dx, dy) in [(0, -1), (0, 1), (-1, 0), (1, 0)] {
                        let wx = x + dx, wy = y + dy
                        guard m.inBounds(wx, wy), m.wall[m.idx(wx, wy)] != 0, m.doors[m.idx(wx, wy)] == nil else { continue }
                        guard op(x - dx * 2, y - dy * 2), op(x - dx * 3, y - dy * 3) else { continue }   // room to stand back and face it
                        // nothing in the sight line — a structural column in the way hides the fixture entirely
                        let sight = (0...2).map { SIMD2<Float>(Float(x - dx * $0) + 0.5, Float(y - dy * $0) + 0.5) }
                        if world.props.contains(where: { pr in sight.contains { simd_length(pr.pos - $0) < 0.75 } }) { continue }
                        world.player.pos = SIMD2(Float(x - dx * 3) + 0.5, Float(y - dy * 3) + 0.5)
                        world.player.dir = atan2(Float(dy), Float(dx))
                        _ = rr.render(world, into: canvas)
                        Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-plantlamp.png"))
                        print("RASTERSHOT: wrote raster-plantlamp.png (bulkhead on the wall at \(wx),\(wy))")
                        break outer
                    }
                }
            }
        }

        // MACHINE HALL check (7–8): the imported plant machinery in place. One view standing well back from
        // the hall's centrepiece so its full height reads against the double-height roof steel, and one down
        // a wall where the compressors and switchgear are ranked. Machinery is STATIC level geometry, so what
        // these frames show is baked into the level mesh, not rebuilt per frame.
        for lvl in [7, 8] {
            let world = World(level: lvl, colonyIndex: 0, seed: 3)
            let m = world.map
            world.monsters = []; world.colonists = []                    // clear so the architecture reads
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
            /// Stand back from `t` and look at it. Maximising distance is the wrong objective — it parks
            /// the camera in whichever side passage reaches furthest and fills half the frame with the
            /// rock beside it. So cap the range at a distance that still shows the whole machine, and
            /// insist the standpoint has open floor to BOTH sides: that is what distinguishes standing
            /// in the hall from standing in a corridor leading out of it.
            func frame(_ t: SIMD2<Float>, _ tag: String) {
                var best = (d: Float(0), pos: SIMD2<Float>(0, 0))
                for a in stride(from: Float(0), to: 6.2831, by: 0.26) {
                    let dir = SIMD2<Float>(cos(a), sin(a)), side = SIMD2<Float>(-dir.y, dir.x)
                    var k: Float = 1.8
                    while k <= 5.2 {
                        let q = t + dir * k
                        if !op(Int(q.x), Int(q.y)) { break }
                        let lf = q + side, rt = q - side
                        if k > best.d, op(Int(lf.x), Int(lf.y)), op(Int(rt.x), Int(rt.y)) { best = (k, q) }
                        k += 0.4
                    }
                }
                guard best.d >= 2.0 else { print("RASTERSHOT: \(tag) — no standpoint"); return }
                world.player.pos = best.pos
                world.player.dir = atan2f(t.y - best.pos.y, t.x - best.pos.x)
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1,
                                  to: dir.appendingPathComponent("\(tag).png"))
                print("RASTERSHOT: wrote \(tag).png (from \(best.pos), \(String(format: "%.1f", best.d)) back)")
            }
            if let hero = world.props.first(where: { $0.kind == .machineFilter || $0.kind == .machineColumn }) {
                frame(hero.pos, "raster-machinehall-L\(lvl)")
            } else {
                print("RASTERSHOT: L\(lvl) has no centrepiece machine")
            }
            if let comp = world.props.first(where: { $0.kind == .machineCompressor }) {
                frame(comp.pos, "raster-machinewall-L\(lvl)")
            }
            // COST OF THE MACHINERY, measured rather than assumed. It is static geometry, so it costs
            // no CPU rebuild — but it is ~296k vertices added to a ~550k static mesh, drawn in full
            // every frame including the shadow passes, and that lands squarely on the GPU time that the
            // frame log already showed as the dominant remaining cost on these floors. A/B by stripping
            // the machine props and rebuilding the level, from the same camera.
            func medianMS(_ w: World) -> Double {
                var ms: [Double] = []
                for _ in 0..<12 { let t = ProcessInfo.processInfo.systemUptime; _ = rr.render(w, into: canvas); ms.append((ProcessInfo.processInfo.systemUptime - t) * 1000) }
                ms.sort(); return ms[ms.count / 2]
            }
            let withMach = medianMS(world)
            let bare = World(level: lvl, colonyIndex: 0, seed: 3)
            bare.monsters = []; bare.colonists = []
            bare.props.removeAll { RasterRenderer.machineSpec($0.kind) != nil }
            bare.player.pos = world.player.pos; bare.player.dir = world.player.dir
            let without = medianMS(bare)
            print(String(format: "RASTERSHOT: L%d machinery frame cost — %.2fms with, %.2fms without (+%.2fms, %+.0f%%)",
                         lvl, withMach, without, withMach - without, (withMach / max(without, 1e-6) - 1) * 100))
        }

        // FUEL STORE check: the 2×2 hazard-doored fuel chamber — how it reads from OUTSIDE (the hazard-striped
        // door set in the room wall = the "fuel store" sign), framed THROUGH the open doorway, and from INSIDE
        // (a tight lit chamber packed with red/blue oil drums, the marine's only refuel).
        do {
            var done = false
            for seed in [UInt64(3), 7, 12, 21, 33, 44, 58, 71] where !done {
                let world = World(level: 1, colonyIndex: 0, seed: seed)
                let m = world.map
                guard !m.fuelStore.isEmpty else { continue }
                var doorI = -1
                for i in m.doors.keys.sorted() where m.wall[i] == WallTex.doorHazard.rawValue { doorI = i; break }   // sorted: dictionary order is per-process random
                guard doorI >= 0 else { continue }
                let dcx = doorI % m.w, dcy = doorI / m.w
                var outX = 0, outY = 0                                             // door → chamber direction
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)]
                    where m.inBounds(dcx + dx, dcy + dy) && m.fuelStore.contains(m.idx(dcx + dx, dcy + dy)) { outX = dx; outY = dy; break }
                guard outX != 0 || outY != 0 else { continue }
                let face = atan2(Float(outY), Float(outX))                         // look from the room toward the chamber
                func openRoom(_ k: Int) -> Bool { let x = dcx - outX * k, y = dcy - outY * k
                    return m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
                let perpX = outY, perpY = outX                                     // 2-wide axis (matches MapGen)
                // OUTSIDE — hazard door CLOSED, facing it from 1 cell back (the door fills the frame). The
                // warning lamps flash amber; freeze elapsed at a BRIGHT phase, then a DIM phase, to show the blink.
                m.doors[doorI] = DoorState()
                let backOut = openRoom(2) ? 2 : 1                                   // 2 cells reads the door set in the wall (1 overexposes at point-blank)
                world.player.pos = SIMD2(Float(dcx - outX * backOut) + 0.5, Float(dcy - outY * backOut) + 0.5)
                world.player.dir = face
                world.elapsed = 0.462                                              // sin(elapsed·3.4) ≈ 1 → lamps lit
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-fuelstore-out.png"))
                world.elapsed = 0.924                                              // sin ≈ 0 → lamps dim (the OFF beat)
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-fuelstore-out-dim.png"))
                // THROUGH THE DOORWAY — from the front room cell, door OPEN: the drum stack framed by the hazard jamb
                world.elapsed = 0.462
                m.doors[doorI] = DoorState(open: 1.0)
                world.player.pos = SIMD2(Float(dcx - outX) + 0.5, Float(dcy - outY) + 0.5)
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-fuelstore-open.png"))
                // INSIDE — stand in the drum-free throat cell and aim at the CENTROID of the store's drums, so the
                // packed 2×2 stack of red/blue barrels fills the frame (the wide FOV from the doorway read as a room).
                let storeDrums = world.drums.filter { m.fuelStore.contains(m.idx(Int($0.pos.x), Int($0.pos.y))) }
                let throat = SIMD2<Float>(Float(dcx + outX) + 0.5, Float(dcy + outY) + 0.5)
                let centroid = storeDrums.isEmpty ? throat + SIMD2(Float(outX), Float(outY))
                    : storeDrums.reduce(SIMD2<Float>(0, 0), { $0 + $1.pos }) / Float(storeDrums.count)
                world.player.pos = throat
                world.player.dir = atan2(centroid.y - throat.y, centroid.x - throat.x)
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-fuelstore-in.png"))
                // BULKHEAD — from the throat, aim at the +perp side-wall fixture (concrete wall + caged lamp + a drum)
                let bh = SIMD2<Float>(Float(dcx) + 0.5 + Float(outX) * 1.5 + Float(perpX) * 1.5,
                                      Float(dcy) + 0.5 + Float(outY) * 1.5 + Float(perpY) * 1.5)
                world.player.dir = atan2(bh.y - throat.y, bh.x - throat.x)
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-fuelstore-bulkhead.png"))
                print("RASTERSHOT: wrote raster-fuelstore-{out,out-dim,open,in,bulkhead}.png (seed \(seed), door \(dcx),\(dcy), chamber+(\(outX),\(outY)), \(m.fuelStore.count) cells, \(storeDrums.count) drums)")
                done = true
            }
            if !done { print("RASTERSHOT: fuel store check skipped (none carved)") }
        }

        // DORMITORY check: generate levels until one has a dorm (a bunk cluster), then frame the hall
        // from one end looking down it — verify the locker-bunk wall rows, centre rows, riveted columns,
        // flush/perpendicular bunks, plain walls, and the clear central aisle a body can walk.
        do {
            var done = false
            for seed in [UInt64(3), 7, 12, 21, 33, 44, 58] where !done {
                let world = World(level: 1, colonyIndex: 0, seed: seed)
                let m = world.map
                let bunks = world.props.filter { $0.kind == .bunk }
                guard bunks.count >= 8 else { continue }
                var lo = bunks[0].pos, hi = bunks[0].pos
                for b in bunks { lo = simd_min(lo, b.pos); hi = simd_max(hi, b.pos) }
                let alongX = (hi.x - lo.x) >= (hi.y - lo.y)
                func openAt(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
                let colCells = Set(world.props.filter { $0.kind == .column }.map { m.idx(Int($0.pos.x), Int($0.pos.y)) })
                var opens: [SIMD2<Float>] = []
                for y in (Int(lo.y) - 4)...(Int(hi.y) + 4) { for x in (Int(lo.x) - 4)...(Int(hi.x) + 4) where openAt(x, y) && !colCells.contains(m.idx(x, y)) {
                    opens.append(SIMD2(Float(x) + 0.5, Float(y) + 0.5))
                } }
                guard !opens.isEmpty else { continue }
                // stand INSIDE the hall near one end, offset into a side aisle (off the centre line so a
                // column isn't point-blank), looking down the long axis — sees the rows receding + columns.
                let mid: Float = alongX ? (lo.y + hi.y) * 0.5 : (lo.x + hi.x) * 0.5
                let aisleOff: Float = (alongX ? (hi.y - lo.y) : (hi.x - lo.x)) * 0.32
                let stand = alongX ? SIMD2(lo.x + 0.5, mid - aisleOff) : SIMD2(mid - aisleOff, lo.y + 0.5)
                let far   = alongX ? SIMD2(hi.x + 1, mid) : SIMD2(mid, hi.y + 1)
                let cam = opens.min(by: { simd_distance($0, stand) < simd_distance($1, stand) })!
                world.monsters = []                 // a dorm can be the Queen's lair — clear it so nothing blocks the view
                world.player.pos = cam
                world.player.dir = atan2(far.y - cam.y, far.x - cam.x)
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-dorm.png"))
                print("RASTERSHOT: wrote raster-dorm.png (dormitory, seed \(seed), \(bunks.count) bunks)")
                done = true
            }
            if !done { print("RASTERSHOT: dorm check found no dormitory in the sampled seeds") }
        }
    }
    #endif
}
