import Foundation
import Metal
import simd

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
    struct PVert { var px, py, pz, nx, ny, nz, ar, ag, ab, rough, metal, er, eg, eb: Float }

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
    private var perpScratch: [Float]            // CPU read-back of perpTex (W·H), fed to the MeshCreature merge
    private let shadowArr: MTLTexture           // one depth slice per shadowed lamp (cast from the lamp's STATIC position)
    private let W = RenderConfig.width, H = RenderConfig.viewHeight, SHADOW = 1024
    private let SHADOW_LAMPS = 3                // nearest N overhead lamps get a real cast shadow

    private var vbuf: MTLBuffer?
    private var nVerts = 0
    private var fieldTex: MTLTexture?          // baked per-cell incident light (map.lightColor)
    private var lampMaskData: [UInt8] = []     // per-cell R8: 0 = solid wall · 128 = open · 255 = open + overhead lamp
    private var lampMaskTex: MTLTexture?       // ^ the fragment fetches this to find its lamps AND walk line-of-sight
    private var distTex: MTLTexture?           // rg32Float wall-distance field (.r) — the mesh-creature wall-clip trims limbs at wall faces
    private var mapW = 1, mapH = 1
    private var lampCells: [SIMD2<Float>] = [] // centres of the overhead ceiling lamps (even/even open cells)
    private var worldID: ObjectIdentifier?

    private let dynBuf: MTLBuffer              // per-frame prop mesh (visible furniture/drums/sockets/mines/debris)
    private var dynScratch: [PVert] = []       // reusable CPU staging so the frame loop allocates nothing
    private let dynCap = 300_000               // max prop verts/frame (buffer sized once; overflow is dropped)
    private var nDynVerts = 0

    // ── M4 creatures: the animated Tripo meshes (reused verbatim from the raymarch path;
    // they reproduce this renderer's camera exactly), composited over the lit world using
    // the perp-depth buffer above. Colonist corpse meshes are lazy-loaded per variant.
    private let meshQueen: MeshCreature?
    private let meshDrone: MeshCreature?
    private var colonistMeshes: [Int: MeshCreature] = [:]
    private var colonistTried: Set<Int> = []

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device; self.queue = queue
        guard let lib = try? device.makeLibrary(source: RasterRenderer.shaderSrc, options: nil) else {
            print("RasterRenderer: shader compile failed"); return nil
        }
        let mpd = MTLRenderPipelineDescriptor()
        mpd.vertexFunction = lib.makeFunction(name: "rr_vertex")
        mpd.fragmentFunction = lib.makeFunction(name: "rr_fragment")
        mpd.colorAttachments[0].pixelFormat = .rgba8Unorm
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
        self.colTex = tex(.rgba8Unorm, W, H, .shared, [.renderTarget])
        self.zTex = tex(.depth32Float, W, H, .private, [.renderTarget])
        self.perpTex = tex(.r32Float, W, H, .shared, [.renderTarget])
        self.perpScratch = [Float](repeating: 1e9, count: W * H)
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
    }

    // ── entry point (mirrors GPUWorldRenderer.render(_:into:)) ────────────────
    @discardableResult
    func render(_ world: World, into canvas: Canvas2D) -> Bool {
        let id = ObjectIdentifier(world)
        if worldID != id { prepareLevel(world); worldID = id }
        guard let vbuf, nVerts > 0, let fieldTex, let lampMaskTex else { return false }

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
        if lights.count > 64 { lights = Array(lights.prefix(64)) }         // stable-order safety cap (NEVER player-sorted)
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
        var cam = Cam(
            mvp: camMVP(eye: eye, dir: p.dir, near: 0.03, far: 64),
            lmvp0: lmvps[0], lmvp1: lmvps[1], lmvp2: lmvps[2],
            eye: SIMD4(eye, 1),
            params: SIMD4(Float(lights.count), Float(shadowN), Float(mapW), Float(mapH)),
            amb: SIMD4(0, 0, 0, 0.07),                          // ambient scale (baked-field fill only; no sourceless light)
            headFwd: SIMD4(headFwd, headInt),                   // the marine's headlamp — a broad pool, tilted DOWN to light footing
            shX: shX, shZ: shZ,                                 // shadowed lamp cells (integer) for the analytic loop's shadow match
            camFwd: SIMD4(camFwd, 0)
        )

        // ── per-frame prop mesh: tessellate the visible furniture/drums/sockets/mines/debris
        dynScratch.removeAll(keepingCapacity: true)
        buildProps(world, into: &dynScratch)
        nDynVerts = min(dynScratch.count, dynCap)
        if nDynVerts > 0 {
            dynScratch.withUnsafeBytes { _ = memcpy(dynBuf.contents(), $0.baseAddress!, nDynVerts * MemoryLayout<PVert>.stride) }
        }

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
        mrp.colorAttachments[0].texture = colTex
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
            me.setFragmentTexture(shadowArr, index: 0)
            me.setFragmentTexture(fieldTex, index: 1)
            me.setFragmentTexture(lampMaskTex, index: 2)   // analytic overhead lamp presence
            me.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: nVerts)
            if nDynVerts > 0 {                                    // the visible props, lit by the same forward pass
                me.setVertexBuffer(dynBuf, offset: 0, index: 0)
                me.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: nDynVerts)
            }
            me.endEncoding()
        }
        cmd.commit(); cmd.waitUntilCompleted()

        colTex.getBytes(canvas.framebuffer, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)

        // ── M4 creatures: composite the animated meshes over the lit world, occluded by
        // the perp-depth just rendered. Reuses MeshCreature verbatim (its camera == ours). ──
        compositeCreatures(world, into: canvas, eye: eye, dir: p.dir)
        return true
    }

    /// Draw the mesh creatures (fallen colonists, then the queen, then the drone pack) over the
    /// framebuffer, each depth-tested against the scene's perp-depth (read back from perpTex) and
    /// writing its own depth so later layers occlude correctly — mirrors GPUWorldRenderer's order.
    /// Lit by the creature shader's own sector+camera fill (dynamic lights + wall-clip are deferred:
    /// mapW/H = 0 disables the clip, an empty light list still lights them). Corpses render too.
    private func compositeCreatures(_ world: World, into canvas: Canvas2D, eye: SIMD3<Float>, dir: Float) {
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
        let vis = cand.prefix(10).map { $0.0 }
        let queens = vis.filter { $0.kind == .queen }
        let drones = vis.filter { $0.kind == .alien && !$0.gibbed }
        let colonists = FeatureFlags.fallenColonists ? world.colonists.filter { c in
            guard c.variant >= 0 else { return false }
            let rel = c.pos - p.pos, ahead = rel.x * fwd.x + rel.y * fwd.y
            return ahead > -1.5 && (rel.x * rel.x + rel.y * rel.y) < 24 * 24
        } : []

        guard !queens.isEmpty || !drones.isEmpty || !colonists.isEmpty else { return }

        // scene perp-depth → CPU (the mesh merge tests + writes against it)
        perpScratch.withUnsafeMutableBytes {
            perpTex.getBytes($0.baseAddress!, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        }
        let noLights: [GPURaymarch.GPULight] = []   // dynamic muzzle/flame lights on creatures: deferred to M5
        perpScratch.withUnsafeMutableBufferPointer { dp in
            let depth = dp.baseAddress!
            // fallen colonists first (deck layer), batched per variant
            if !colonists.isEmpty {
                for v in Set(colonists.map { $0.variant }) {
                    guard let mesh = colonistMesh(v) else { continue }
                    let insts = colonists.filter { $0.variant == v }.map {
                        MeshCreature.ColonistInst(pos: $0.pos, yaw: $0.yaw, seed: $0.seed, burn: $0.burn, ashed: $0.ashed,
                                                  sector: WorldLight.lightAt(world.map, $0.pos.x, $0.pos.y))
                    }
                    mesh.compositeColonists(into: canvas, depth: depth, eye: eye, camDir: dir, instances: insts,
                                            lights: noLights, wallField: distTex, mapW: Float(mapW), mapH: Float(mapH))
                }
            }
            // the mesh Queen(s)
            if let mc = meshQueen, !queens.isEmpty {
                for q in queens {
                    let death: Float
                    if q.state == .dead { death = 1 }
                    else if q.state == .dying { let f = min(1, (q.stateTime / World.queenDeathTime) / World.queenImpactT); death = f * f }
                    else { death = 0 }
                    mc.composite(into: canvas, depth: depth, eye: eye, dir: dir, pos: q.pos, faceTarget: p.pos,
                                 sector: WorldLight.lightAt(world.map, q.pos.x, q.pos.y), time: world.elapsed, map: world.map,
                                 death: death, burn: q.burn, ashed: q.ashed, lights: noLights, wallField: distTex, mapW: Float(mapW), mapH: Float(mapH))
                }
            }
            // the drone pack, one batched pass
            if let md = meshDrone, !drones.isEmpty {
                let insts: [MeshCreature.DroneInst] = drones.map { m in
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
                md.compositeDrones(into: canvas, depth: depth, eye: eye, camDir: dir, instances: insts,
                                   lights: noLights, wallField: distTex, mapW: Float(mapW), mapH: Float(mapH))
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
        buildMesh(world.map)
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

    private func buildMesh(_ map: GameMap) {
        var v: [PVert] = []; v.reserveCapacity(map.w * map.h * 12)
        lampCells.removeAll(keepingCapacity: true)
        lampMaskData = [UInt8](repeating: 0, count: map.w * map.h)   // per-cell lamp-presence, stamped at the same site as the housing
        func openGeo(_ x: Int, _ y: Int) -> Bool {
            guard map.inBounds(x, y) else { return false }
            let i = map.idx(x, y); return map.wall[i] == 0 || map.doors[i] != nil
        }
        func vert(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ m: Mat) -> PVert {
            PVert(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z,
                  ar: m.a.x, ag: m.a.y, ab: m.a.z, rough: m.r, metal: m.m, er: m.e.x, eg: m.e.y, eb: m.e.z)
        }
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ n: SIMD3<Float>, _ m: Mat) {
            v += [vert(a, n, m), vert(b, n, m), vert(c, n, m), vert(a, n, m), vert(c, n, m), vert(d, n, m)]
        }
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
                blendedSurface(x, y, 0, SIMD3(0, 1, 0)) { map.floor[$0] }
                blendedSurface(x, y, 1, SIMD3(0, -1, 0)) { map.ceil[$0] }
                if !openGeo(x - 1, y) { quad(SIMD3(fx, 0, fz), SIMD3(fx, 0, fz + 1), SIMD3(fx, 1, fz + 1), SIMD3(fx, 1, fz), SIMD3(1, 0, 0), wallTexAt(map, x - 1, y)) }
                if !openGeo(x + 1, y) { quad(SIMD3(fx + 1, 0, fz + 1), SIMD3(fx + 1, 0, fz), SIMD3(fx + 1, 1, fz), SIMD3(fx + 1, 1, fz + 1), SIMD3(-1, 0, 0), wallTexAt(map, x + 1, y)) }
                if !openGeo(x, y - 1) { quad(SIMD3(fx + 1, 0, fz), SIMD3(fx, 0, fz), SIMD3(fx, 1, fz), SIMD3(fx + 1, 1, fz), SIMD3(0, 0, 1), wallTexAt(map, x, y - 1)) }
                if !openGeo(x, y + 1) { quad(SIMD3(fx, 0, fz + 1), SIMD3(fx + 1, 0, fz + 1), SIMD3(fx + 1, 1, fz + 1), SIMD3(fx, 1, fz + 1), SIMD3(0, 0, -1), wallTexAt(map, x, y + 1)) }
                // overhead ceiling lamp (one per open cell on the grid — see the lamp* statics):
                // a VISIBLE glowing housing so the pools it casts have a source you can see, PLUS
                // the presence-mask bit AND (via the shared statics) the shader's analytic light —
                // all authored HERE so lamp / housing / mask / light can never drift apart.
                if x % Self.lampGridStride == Self.lampGridPhase && y % Self.lampGridStride == Self.lampGridPhase {
                    lampCells.append(SIMD2(fx + 0.5, fz + 0.5))
                    lampMaskData[i] = 255
                    let cx = fx + 0.5, cz = fz + 0.5, hs: Float = 0.26, y0: Float = 0.985
                    let lm = Mat(a: SIMD3(0.80, 0.85, 0.95), r: 0.4, m: 0.0, e: WorldLight.lampColor * 3.4)   // bright recessed housing
                    quad(SIMD3(cx - hs, y0, cz - hs), SIMD3(cx - hs, y0, cz + hs), SIMD3(cx + hs, y0, cz + hs), SIMD3(cx + hs, y0, cz - hs), SIMD3(0, -1, 0), lm)
                }
            }
        }
        nVerts = v.count
        vbuf = v.isEmpty ? nil : device.makeBuffer(bytes: v, length: MemoryLayout<PVert>.stride * v.count)
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

    /// Tessellate a prop's local shapes into `v`, applying the kernel's LOCAL→WORLD
    /// transform inverted: XZ rotation about +yaw, translate to `pos`, drop the lowest
    /// authored point to the floor when `floored` (yOff = loY; wall-pipes/sockets keep
    /// their authored height). `rough`/`metal` are the prop class's PBR base.
    private func emitProp(_ shapes: [GPURaymarch.GShape], pos: SIMD2<Float>, yaw: Float,
                          floored: Bool, rough: Float, metal: Float, into v: inout [PVert]) {
        var yOff: Float = 0
        if floored { var lo: Float = 1e9; for s in shapes { lo = min(lo, rrShapeYExtent(s).0) }; yOff = lo }
        let cy = cosf(yaw), sy = sinf(yaw)
        let xf: (SIMD3<Float>) -> SIMD3<Float> = { l in SIMD3(pos.x + l.x * cy - l.z * sy, l.y - yOff, pos.y + l.x * sy + l.z * cy) }
        let xn: (SIMD3<Float>) -> SIMD3<Float> = { n in SIMD3(n.x * cy - n.z * sy, n.y, n.x * sy + n.z * cy) }
        for s in shapes { tessShape(s, rough: rough, metal: metal, xf, xn, into: &v) }
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

    private func buildProps(_ world: World, into v: inout [PVert]) {
        let pp = world.player.pos, dir = world.player.dir
        let fwd = SIMD2<Float>(cosf(dir), sinf(dir))
        func visible(_ pos: SIMD2<Float>, _ maxD: Float) -> Bool {
            let rel = pos - pp; let d = simd_length(rel)
            if d > maxD { return false }
            if d > 1.5 && simd_dot(rel / d, fwd) < -0.5 { return false }   // strongly behind → skip (saves tessellation)
            return true
        }
        // furniture / fixtures / pipe runs / the reel-to-reel (material: rough painted metal)
        for pr in world.props where visible(pr.pos, 20) {
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
            emitProp(sl, pos: pr.pos, yaw: pr.yaw, floored: floored, rough: 0.82, metal: 0.12, into: &v)
        }
        // fuel drums (red/blue by the same stable cell hash the packer uses)
        for d in world.drums where d.health > 0 && visible(d.pos, 20) {
            let key = Int(d.pos.x.rounded()) &* 73856093 ^ Int(d.pos.y.rounded()) &* 19349663
            emitProp(GPURaymarch.drumShapes(red: (key & 1) == 0), pos: d.pos, yaw: 0, floored: true, rough: 0.86, metal: 0.20, into: &v)
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

    struct Cam { float4x4 mvp; float4x4 lmvp[3]; float4 eye; float4 params; float4 amb; float4 headFwd; float4 shX; float4 shZ; float4 camFwd; };
    struct Light { float4 posR; float4 colI; };          // posR=(x,y,z,1/r²)  colI=(rgb,intensity)
    struct PV { float px,py,pz, nx,ny,nz, ar,ag,ab, rough, metal, er,eg,eb; };
    struct VOut { float4 clip [[position]]; float3 wp; float3 wn; float3 alb; float rgh; float mtl; float3 emis; };
    struct SOut { float4 clip [[position]]; };

    float h21(float2 p){ p = fract(p*float2(127.1,311.7)); p += dot(p,p+34.5); return fract(p.x*p.y); }
    float vnoise(float2 p){ float2 i=floor(p),f=fract(p); f=f*f*(3-2*f);
        float a=h21(i),b=h21(i+float2(1,0)),c=h21(i+float2(0,1)),d=h21(i+float2(1,1));
        return mix(mix(a,b,f.x),mix(c,d,f.x),f.y); }
    float fbm(float2 p){ float s=0,a=0.5; for(int i=0;i<5;i++){ s+=a*vnoise(p); p*=2.03; a*=0.5;} return s; }
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
        o.alb=float3(p.ar,p.ag,p.ab); o.rgh=p.rough; o.mtl=p.metal; o.emis=float3(p.er,p.eg,p.eb); return o;
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

    struct RROut { float4 color [[color(0)]]; float perp [[color(1)]]; };
    fragment RROut rr_fragment(VOut in [[stage_in]], constant Cam& C [[buffer(1)]],
                                constant Light* lights [[buffer(2)]],
                                depth2d_array<float> smap [[texture(0)]], texture2d<float> field [[texture(1)]],
                                texture2d<float> lampMask [[texture(2)]]){
        float3 alb=in.alb; float rough=in.rgh, metal=in.mtl;
        float3 gn=normalize(in.wn);
        // Surfaces are CONTINUOUS — no per-metre panel grid (that read as tiled squares). Large-scale
        // form + grime come from the tri-planar noise below; real panel JOINTS are authored into the
        // map's materials, not stamped on every cell.
        float3 tn=triNoise(in.wp, gn, 5.5);
        float3 T=normalize(abs(gn.y)<0.9?cross(float3(0,1,0),gn):float3(1,0,0)), B=cross(gn,T);
        float3 N=normalize(gn - (tn.y*T+tn.z*B)*0.3);
        float grime=tn.x; rough=clamp(rough+(grime-0.5)*0.32,0.05,1.0); alb *= (0.74+0.48*grime);

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
        {
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
        col += in.emis;                                                              // self-lit fixtures

        if(C.eye.w>0.5){
            col *= 0.9;
            float lum=dot(col,float3(0.299,0.587,0.114));
            col=mix(col*float3(0.84,0.96,1.16), col*float3(1.14,1.0,0.80), clamp(lum,0.0,1.0));
            col=(col*(2.51*col+0.03))/(col*(2.43*col+0.59)+0.14);
            col=pow(clamp(col,0.0,1.0), float3(1.0/2.2));
            float2 dd=(in.clip.xy/float2(1280.0,800.0))*2.0-1.0; col *= 1.0-0.20*dot(dd,dd);
        } else { col=pow(clamp(col,0.0,1.0), float3(1.0/2.2)); }
        RROut o; o.color=float4(col,1); o.perp=dot(in.wp - C.eye.xyz, C.camFwd.xyz);   // perp-depth for the mesh composite
        return o;
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

        // WALL-CLIP check (M4 corner-merge fix): stand a drone straddling a wall boundary (body centre ON
        // the wall face) so its INSIDE half must be discarded by the distance-field clip → a clean vertical
        // cut at the wall, not a drone drawn on top of it. Confirms the clip trims limbs at convex corners.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            func solid(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] != 0 && m.doors[m.idx(x, y)] == nil }
            search: for cy in 3..<(m.h - 6) { for cx in 4..<(m.w - 3)
                where op(cx, cy) && solid(cx - 1, cy) {                 // open cell with a SOLID west neighbour (wall face at x = cx)
                guard op(cx, cy + 1), op(cx, cy + 2), op(cx, cy + 3) else { continue }
                var drone = Monster(kind: .alien, pos: SIMD2(Float(cx), Float(cy) + 0.5))   // centre ON the wall face → west half is inside the wall
                drone.dir = .pi / 2; drone.state = .chase
                world.monsters = [drone]
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy + 3) + 0.5)
                world.player.dir = -.pi / 2
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-creature-clip.png"))
                print("RASTERSHOT: wrote raster-creature-clip.png (drone on wall face at \(cx),\(cy))")
                break search
            } }
        }
    }
    #endif
}
