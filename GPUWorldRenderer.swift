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

    private var dtTex, liTex, gpuViewTex, gpuHDRTex, gpuDepthTex: MTLTexture?
    private var gpuDepth = [Float]()   // per-pixel scene depth, read back for sprite occlusion
    private var wallArrTex, flatArrTex: MTLTexture?           // procedural texture set (built once)
    private var wallIdTex, floorIdTex, ceilIdTex: MTLTexture? // per-level material-id grids
    private var gpuMapW = 0, gpuMapH = 0
    private var gpuEmitterLights: [Lighting.PointLight] = []   // the level's fixtures as dramatic point lights
    private var gpuDoorSig: UInt64 = 0
    private var gpuWorldID: ObjectIdentifier?
    private var gpuReady = false

    /// Fails (returns nil) if the compute pipelines or a command queue can't be
    /// built — the caller then has no GPU path (the live renderer falls back to
    /// the CPU raycaster; the tools skip).
    init?(device: MTLDevice) {
        guard let p = GPURaymarch.makePipelines(device), let q = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = q
        self.raymarch = p.raymarch
        self.post = p.post
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

    private func prepareLevel(_ world: World) {
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
    /// (mirrors WorldLight.gatherLights, at eye height in 3-D).
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

    private func renderFrame(_ world: World, into canvas: Canvas2D) -> Bool {
        guard gpuReady, let dt = dtTex, let li = liTex,
              let outT = gpuViewTex, let hdr = gpuHDRTex, let depthT = gpuDepthTex else { return false }
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
        gpuDepth.withUnsafeBufferPointer { spriteCompositor.overlayThings(world, into: canvas, depth: $0.baseAddress, includeProjectiles: false) }
        return true
    }
}
