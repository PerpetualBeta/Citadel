import Foundation
import Metal
import simd
import ModelIO

// ============================================================================
//  RasterRenderer — the rasterised world renderer
//
//  THE renderer. It grew up alongside the SDF raymarcher and replaced it outright on
//  2026-07-29; what remains of that path is the shape library in GPURaymarch.swift.
//  Renders the grid world as triangle meshes with PBR shading, into the same Canvas2D
//  framebuffer the HUD then draws over.
//
//  The three Metal shader sources live in RasterShaders.swift — same type, via an
//  extension, so RasterRenderer.shaderSrc / .fireSrc / .particleSrc still resolve here.
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
    /// Render, and hand back the per-pixel PERPENDICULAR depth as well as the frame.
    ///
    /// For harnesses that composite something of their own over a rendered backdrop and need the
    /// scene depth to occlude it — QueenMeshTest does exactly that with a creature mesh. The normal
    /// frame only reads perpTex back when there are particles to occlude, so this forces the copy.
    func renderWithPerpDepth(_ world: World, into canvas: Canvas2D) -> [Float] {
        _ = render(world, into: canvas)
        perpScratch.withUnsafeMutableBytes {
            perpTex.getBytes($0.baseAddress!, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        }
        return perpScratch
    }
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

    // ── entry point ───────────────────────────────────────────────────────────
    @discardableResult
    func render(_ world: World, into canvas: Canvas2D) -> Bool {
        fpMark("start")
        if lastWorld !== world { prepareLevel(world); lastWorld = world }
        installMeshPoseResolve(world)
        // Settle every body clear of solids BEFORE anything is drawn. It happens here, at the one
        // gate every render passes through, rather than inside the update tick — so a caller that
        // builds a world and draws it without ticking (the shot harnesses) still gets bodies that
        // agree with what a shot would hit.
        world.refreshDrawnPositions()
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
        let dynLights = GPURaymarch.gatherDynLights(world)
        lights.append(contentsOf: dynLights)
        lastLightCount = Float(lights.count)
        // fuel-store bulkhead lights — warm, low-wattage, tight radius (the store has no overhead; these light it)
        for b in RasterRenderer.fuelBulkheads(world.map) {
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

    // ── codex dossier busts ─────────────────────────────────────────────────────
    /// Render the Field Intel dossier busts from the SAME mesh instances the game draws, and cache
    /// them in MeshPortraits — so the codex shows the actual creatures. Synchronous; call once.
    /// Moved here from GPUWorldRenderer when that renderer was retired: it only ever needed the two
    /// MeshCreature instances, which this renderer owns.
    func renderPortraits() {
        if let q = meshQueen { MeshPortraits.store(.queen, q.portrait(spin: MeshPortraits.spin(.queen), gain: MeshPortraits.gain(.queen))) }
        if let d = meshDrone { MeshPortraits.store(.alien, d.portrait(spin: MeshPortraits.spin(.alien), gain: MeshPortraits.gain(.alien))) }
    }

    /// Non-blocking variant for launch: the codex is rarely the first screen reached, and it
    /// degrades gracefully until this lands.
    func warmPortraits() {
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.renderPortraits() }
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
                mc.composite(into: frame(), eye: eye, dir: dir, pos: q.pos, faceTarget: p.pos,
                             sector: WorldLight.lightAt(world.map, q.pos.x, q.pos.y), time: world.elapsed, map: world.map,
                             death: q.deathProgress, burn: q.burn, ashed: q.ashed, lights: creatureLights, wallField: distTex, mapW: Float(mapW), mapH: Float(mapH))
            }
        }
        // the drone pack, one batched pass
        if let md = meshDrone, !vis.drones.isEmpty {
            let insts: [MeshCreature.DroneInst] = vis.drones.map { m in
                let move: Float
                switch m.state { case .chase: move = 1; case .pain: move = 0.5; case .attack: move = 0.35; default: move = 0 }
                // drawn at the SETTLED position (what a shot tests against); LIT from the logical
                // cell, which is the cell the alien is actually standing in
                return MeshCreature.DroneInst(pos: m.drawnPos, dir: m.dir, gait: m.animTime * 5.0, move: move, rear: m.rearAmt,
                                              dissolve: m.dissolveProgress, seed: m.deathSeed, death: m.deathProgress,
                                              burn: m.burn, ashed: m.ashed,
                                              sector: WorldLight.lightAt(world.map, m.pos.x, m.pos.y))
            }
            md.compositeDrones(into: frame(), eye: eye, camDir: dir, instances: insts,
                               lights: creatureLights, wallField: distTex, mapW: Float(mapW), mapH: Float(mapH))
        }
    }

    /// Hand the sim the mesh pose-resolve, so `Monster.drawnPos` is authoritative for BOTH the
    /// draw call and every aim and hit test. It has to be installed from here: the resolve needs
    /// mesh extents and the rig's facing convention, and those only exist once a mesh has loaded.
    /// A kind with no mesh (or a mesh that failed to load) simply keeps its logical position.
    private func installMeshPoseResolve(_ world: World) {
        guard world.meshPoseResolve == nil else { return }
        let drone = meshDrone, queen = meshQueen        // capture the meshes, NOT self — no cycle through the renderer
        world.meshPoseResolve = { kind, pos, dir, corpse, map, props in
            switch kind {
            case .alien: return drone?.drawnDronePosition(pos: pos, dir: dir, corpse: corpse, map: map, props: props) ?? pos
            case .queen: return queen?.drawnQueenPosition(pos: pos, map: map) ?? pos
            }
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
        // The level mesh is built by LevelMeshBuilder and RETURNED, not written into this object. The
        // caches stay here because they must outlive the level: the OBJ parses are multi-megabyte and the
        // builder is thrown away per floor. `machineHeight` is applied here so the live height knob is
        // read at build time and the cache never goes stale.
        let built = LevelMeshBuilder.build(world: world, ceilingLampsOn: ceilingLampsOn,
                                           bulkhead: loadBulkhead()) { kind in
            guard RasterRenderer.machineSpec(kind) != nil, let mesh = self.loadMachine(kind) else { return nil }
            return (mesh, self.machineHeight(kind))
        }
        lampCells = built.lampCells; lampMaskData = built.lampMask; floorIdData = built.floorIds
        plantLamps = built.plantLamps; hallLamps = built.hallLamps
        pipeVerts = built.pipeVerts; machineVerts = built.machineVerts
        nVerts = built.verts.count
        vbuf = built.verts.isEmpty ? nil
             : device.makeBuffer(bytes: built.verts, length: MemoryLayout<PVert>.stride * built.verts.count)
        let machineProps = world.props.filter { RasterRenderer.machineKind($0.kind) }.count
        if machineVerts > 0 || machineProps > 0 {
            print("RasterRenderer: machinery — \(machineProps) placed, \(machineVerts) static verts")
        }
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
            m = Self.M(base * 0.25, 0.40, 0.0, base * gain * 0.9)
        } else {
            m = Self.M(col, 0.34, 0.55)                           // gunmetal: semi-glossy, fairly metallic
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
            Self.tessSphere(c, r: sh.a.w, tri: tri)
        } else if bw < -3.5 {                                // z-cylinder (barrel / coils / nozzle) — axis +Z
            Self.tessAxial(c, r: sh.a.w, half: sh.b.y, axis: SIMD3(0, 0, 1), rad1: SIMD3(1, 0, 0), rad2: SIMD3(0, 1, 0), tri: tri)
        } else if bw < -2.5 {                                // y-cylinder (fuel tank / cell housing) — axis +Y
            Self.tessAxial(c, r: sh.a.w, half: sh.b.y, axis: SIMD3(0, 1, 0), rad1: SIMD3(1, 0, 0), rad2: SIMD3(0, 0, 1), tri: tri)
        } else if bw < -1.5 {                                // box → CHAMFERED (a hand-carried weapon has worn, rounded edges)
            let hb = SIMD3(sh.b.x, sh.b.y, sh.b.z)
            tessRoundBox(c, hb, min(hb.x, min(hb.y, hb.z)) * 0.32, quad: quad, tri: tri)
        } else if bw < 0 {                                   // sphere
            Self.tessSphere(c, r: sh.a.w, tri: tri)
        } else {                                             // round cone A(r1) → B(r2)
            Self.tessCone(c, SIMD3(sh.b.x, sh.b.y, sh.b.z), r1: sh.a.w, r2: sh.b.w, tri: tri)
        }
    }

    // ── per-frame prop mesh: the visible set, tessellated fresh each frame ─────
    //  Props can't bake into the static level mesh — mines are deployed at runtime,
    //  drums rupture, sockets/decks change state, the signal reels spin. So gather the
    //  visible instances each frame (cheap: a few dozen objects) and rebuild the dynamic
    //  buffer, which draws in the SAME shadow+main passes → props cast/receive the pools.

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
        let steel = Self.M(SIMD3(0.66, 0.48, 0.17), 0.34, 0.92)   // BRASS frame (was steel) — matches the marine bulkhead reference
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
        let lit  = Self.M(SIMD3(0.55, 0.16, 0.03), 0.6, 0.0, SIMD3(2.8, 0.85, 0.12))         // amber LED — emissive, blooms
        let dark = Self.M(SIMD3(0.014, 0.011, 0.009), 0.75, 0.1)                             // dark LED glass (blacks read black)
        let lamp = Self.M(SIMD3(0.90, 0.92, 1.00), 0.4, 0.0, SIMD3(2.2, 2.15, 2.0))          // overhead panel — emissive
        let ledY: Float = 0.80, scale: Float = 0.5                                       // scale: the LED glyph is authored large, shrunk to a realistic ~30 cm digit
        for cell in [map.exitCell, map.entryCell] where cell >= 0 {
            let cx = cell % map.w, cy = cell / map.w
            let ccx = Float(cx) + 0.5, ccz = Float(cy) + 0.5
            if simd_length(SIMD2(ccx, ccz) - world.player.pos) > 24 { continue }
            var fdx = 0, fdy = 0
            for (dx, dy) in [(0, 1), (0, -1), (1, 0), (-1, 0)]
                where map.inBounds(cx + dx, cy + dy) && map.wall[map.idx(cx + dx, cy + dy)] == 0 { fdx = dx; fdy = dy; break }
            if fdx == 0 && fdy == 0 { continue }
            Self.emitAABB(SIMD3(ccx - 0.26, 0.965, ccz - 0.26), SIMD3(ccx + 0.26, 0.996, ccz + 0.26), lamp, into: &v)   // overhead light
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
                if fixedZ { Self.emitAABB(SIMD3(tc - hu, y - hw, fc - th), SIMD3(tc + hu, y + hw, fc + th), m, into: &v) }
                else      { Self.emitAABB(SIMD3(fc - th, y - hw, tc - hu), SIMD3(fc + th, y + hw, tc + hu), m, into: &v) }
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
    static func fuelBulkheads(_ m: GameMap) -> [(pos: SIMD2<Float>, yaw: Float, light: SIMD2<Float>)] {
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
            let mat = Self.wallMat(WallTex(rawValue: dmap.wall[i]) ?? .doorPanel)
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
                Self.emitAABB(SIMD3(fx, 0, zc - t),            SIMD3(fx + halfOpen, 1, zc + t), mat, tid: tid, into: &v)   // left leaf → its jamb
                Self.emitAABB(SIMD3(fx + 1 - halfOpen, 0, zc - t), SIMD3(fx + 1, 1, zc + t), mat, tid: tid, into: &v)      // right leaf → its jamb
            } else {
                let xc = (frontFace && rfx != 0) ? (rfx > 0 ? fx + 1 - t : fx + t) : fx + 0.5
                Self.emitAABB(SIMD3(xc - t, 0, fz),            SIMD3(xc + t, 1, fz + halfOpen), mat, tid: tid, into: &v)   // near leaf
                Self.emitAABB(SIMD3(xc - t, 0, fz + 1 - halfOpen), SIMD3(xc + t, 1, fz + 1), mat, tid: tid, into: &v)      // far leaf
            }
            // FUEL STORE — a round amber warning lamp on EACH leaf, mounted on the room face so it TRAVELS with
            // the leaf as the door parts and is occluded from inside the store. Emissive-only (blooms as a lamp);
            // no point light (raster fixture lights are unshadowed and would leak amber into the sealed store).
            if isFuelDoor, rfx != 0 || rfy != 0 {
                let blink = 0.14 + 0.86 * powf(max(0, sinf(Float(world.elapsed) * 3.4)), 0.35)   // a warning beacon's amber pulse
                let lm = Self.M(SIMD3(0.02, 0.015, 0.005), 0.6, 0.0, SIMD3(7.0, 2.2, 0.15) * blink)   // near-black lens; only the orange-amber glow reads
                let ly: Float = 0.81, lr: Float = 0.03, up = SIMD3<Float>(0, 1, 0)
                for lu in [halfOpen * 0.5, 1 - halfOpen * 0.5] {                                  // centre of each leaf → rides it into the jamb as it opens
                    if slideX {
                        let zc = rfy > 0 ? fz + 1 - t : fz + t
                        Self.emitEllipse(SIMD3(fx + lu, ly, zc + Float(rfy) * (t + 0.01)), SIMD3(1, 0, 0), up, lr, lr, SIMD3(0, 0, Float(rfy)), lm, into: &v)
                    } else {
                        let xc = rfx > 0 ? fx + 1 - t : fx + t
                        Self.emitEllipse(SIMD3(xc + Float(rfx) * (t + 0.01), ly, fz + lu), SIMD3(0, 0, 1), up, lr, lr, SIMD3(Float(rfx), 0, 0), lm, into: &v)
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
                Self.emitMesh(bed, pos: seat, yaw: pr.yaw + .pi / 2 + .pi, scale: bedScale, into: &v)
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
            Self.emitProp(sl, pos: pr.pos, yaw: pr.yaw, floored: floored, rough: 0.82, metal: 0.12, yScale: ys, into: &v)
        }
        // fuel drums (red/blue by the same stable cell hash the packer uses) — MATTE painted steel, weathered
        // with rust/grime in the shader (tid=−5, matching the raymarcher), plus flat FLAMMABLE label decals
        for d in world.drums where d.health > 0 && visible(d.pos, 20) {
            let key = Int(d.pos.x.rounded()) &* 73856093 ^ Int(d.pos.y.rounded()) &* 19349663
            var body: [PVert] = []
            Self.emitProp(GPURaymarch.drumShapes(red: (key & 1) == 0), pos: d.pos, yaw: 0, floored: true, rough: 0.86, metal: 0.20, into: &body)
            for i in body.indices { body[i].tid = -5 }        // flag → drum rust/grime weathering in rr_fragment
            v += body
            Self.emitDrumLabel(pos: d.pos, toward: pp, into: &v)    // a single painted-on oil diamond (billboarded to the player)
        }
        // recharge sockets (wall-mounted; live charge/depleted readout, kept at chest height)
        for sk in world.sockets where visible(sk.pos, 20) {
            var sl = GPURaymarch.socketShapes(chargeFrac: Float(sk.charge) / Float(max(1, sk.maxCharge)), depleted: sk.depleted)
            rrFlushToWall(&sl)
            Self.emitProp(sl, pos: sk.pos, yaw: sk.yaw, floored: false, rough: 0.80, metal: 0.15, into: &v)
        }
        // deployed proximity mines (runtime-spawned pucks + red LED)
        for mn in world.deployedMines where visible(mn.pos, 18) {
            Self.emitProp(GPURaymarch.mineShapes(), pos: mn.pos, yaw: 0, floored: true, rough: 0.60, metal: 0.20, into: &v)
        }
        // rubble piles at damage sites (rough rock)
        for db in world.debris where visible(db.pos, 18) {
            Self.emitProp(GPURaymarch.debrisShapes(db.seed), pos: db.pos, yaw: 0, floored: true, rough: 0.92, metal: 0.02, into: &v)
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
            Self.emitItem(sl, pos: it.pos, yaw: yaw, scale: 0.55, floatH: floatH, into: &v)
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
            Self.tessShape(GPURaymarch.iSphere(head, r, col * 2.6, 0.01), rough: 0.4, metal: 0.0, { $0 }, { $0 }, into: &v)
            if simd_distance(head, tail) > 0.05 {
                Self.tessShape(GPURaymarch.iCone(head, tail, r * 0.9, r * 0.2, col * 1.5, 0.02), rough: 0.4, metal: 0.0, { $0 }, { $0 }, into: &v)
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


}
