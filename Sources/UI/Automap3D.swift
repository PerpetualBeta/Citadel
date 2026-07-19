// Citadel — free-orbit 3-D automap renderer.
//
// The automap's overview is a real perspective render of the EXPLORED level
// geometry, orbited by the player. It reuses the same offscreen-render → readback
// → composite pattern as MeshCreature: build a vertex soup of the walls/floor the
// marine has actually seen (fog-of-war preserved — only cells bordering visited
// floor are emitted), rasterise it with a Metal pipeline from an orbit camera into
// an RGBA texture, read it back, and composite it over the dimmed view. The 2-D
// chrome (title, legend, close hint) is drawn on top by Automap.
//
// World axes match the game: cell (x, y) sits at world (x, 0, y) — xz is the
// ground plane, +y is up, walls rise from y=0 to `wallH`.

import Foundation
import Metal
import simd

/// One flat vertex: position, normal, colour — nine floats (stride 36), laid out
/// to match the Metal `struct V` byte-for-byte so it uploads with no descriptor.
struct AMVert {
    var px, py, pz: Float
    var nx, ny, nz: Float
    var r, g, b: Float
}

final class Automap3D {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipe: MTLRenderPipelineState
    private let dss: MTLDepthStencilState
    private let colTex, zTex: MTLTexture
    private let W: Int, H: Int
    private var mcol: [UInt32]

    // geometry cache — the explored set only changes between openings (the world is
    // frozen while the map is up), so rebuild the soup + buffer only when it changes.
    private var cachedBuf: MTLBuffer?
    private var cachedCount = 0
    private var cachedSig = -1

    private static let wallH: Float = 0.9

    init?(device: MTLDevice) {
        self.device = device
        guard let q = device.makeCommandQueue() else { return nil }
        self.queue = q
        let vw = RenderConfig.width, vh = RenderConfig.height    // locals: mk must not touch self before init
        guard let lib = try? device.makeLibrary(source: Self.shaderSrc, options: nil) else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "amVertex")
        pd.fragmentFunction = lib.makeFunction(name: "amFragment")
        pd.colorAttachments[0].pixelFormat = .rgba8Unorm
        pd.depthAttachmentPixelFormat = .depth32Float
        guard let ps = try? device.makeRenderPipelineState(descriptor: pd) else { return nil }
        self.pipe = ps
        let d = MTLDepthStencilDescriptor(); d.depthCompareFunction = .less; d.isDepthWriteEnabled = true
        guard let ds = device.makeDepthStencilState(descriptor: d) else { return nil }
        self.dss = ds
        func mk(_ f: MTLPixelFormat, _ mode: MTLStorageMode) -> MTLTexture? {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: vw, height: vh, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]; td.storageMode = mode
            return device.makeTexture(descriptor: td)
        }
        guard let ct = mk(.rgba8Unorm, .shared), let zt = mk(.depth32Float, .private) else { return nil }
        self.W = vw; self.H = vh
        self.colTex = ct; self.zTex = zt
        self.mcol = [UInt32](repeating: 0, count: vw * vh)
    }

    // ── public draw ──────────────────────────────────────────────────────────
    /// Render the orbit view into `canvas` and return the view-projection matrix so
    /// the caller can project world points (e.g. the EXIT label) onto the frame.
    @discardableResult
    func render(_ world: World, into canvas: Canvas2D,
                azimuth: Float, elevation: Float, zoom: Float) -> simd_float4x4 {
        let map = world.map
        let sig = world.level &* 1_000_003 &+ map.visited.reduce(0) { $0 + ($1 ? 1 : 0) }
        if sig != cachedSig {
            let verts = buildGeometry(world)
            cachedCount = verts.count
            cachedBuf = verts.isEmpty ? nil
                : device.makeBuffer(bytes: verts, length: MemoryLayout<AMVert>.stride * verts.count, options: .storageModeShared)
            cachedSig = sig
        }
        guard let vbuf = cachedBuf, cachedCount > 0 else { return matrix_identity_float4x4 }

        // orbit camera around the centroid of the explored floor
        let (center, extent) = exploredBounds(world)
        let fovY: Float = 50 * .pi / 180
        let el = max(0.12, min(1.40, elevation))                    // avoid the straight-down gimbal
        let dir = SIMD3<Float>(cos(el) * cos(azimuth), sin(el), cos(el) * sin(azimuth))
        let fitDist = (extent * 0.5) / tan(fovY / 2) * 1.18
        let dist = max(3, fitDist / max(0.35, zoom))
        let eye = center + dir * dist
        let mvp = Self.perspective(fovY: fovY, aspect: Float(W) / Float(H), near: 0.1, far: dist + extent * 2 + 10)
                * Self.lookAt(eye: eye, center: center, up: SIMD3(0, 1, 0))

        var u = AMUniforms(mvp: mvp, lightDir: SIMD4(normalize(SIMD3<Float>(0.35, 0.92, 0.28)), 0))

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = colTex
        rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.depthAttachment.texture = zTex
        rp.depthAttachment.loadAction = .clear; rp.depthAttachment.storeAction = .dontCare
        rp.depthAttachment.clearDepth = 1.0
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return mvp }
        enc.setRenderPipelineState(pipe)
        enc.setDepthStencilState(dss)
        enc.setCullMode(.none)
        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<AMUniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<AMUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: cachedCount)
        enc.endEncoding()
        cmd.commit(); cmd.waitUntilCompleted()

        mcol.withUnsafeMutableBytes { colTex.getBytes($0.baseAddress!, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0) }
        let fb = canvas.framebuffer
        for i in 0..<W * H where alphaOf(mcol[i]) > 2 { fb[i] = mcol[i] | 0xFF00_0000 }
        return mvp
    }

    /// Project a world point to framebuffer pixels; nil if behind the camera.
    static func project(_ p: SIMD3<Float>, _ mvp: simd_float4x4, _ w: Int, _ h: Int) -> (Int, Int)? {
        let clip = mvp * SIMD4<Float>(p.x, p.y, p.z, 1)
        guard clip.w > 1e-4 else { return nil }
        let nx = clip.x / clip.w, ny = clip.y / clip.w
        return (Int(((nx * 0.5 + 0.5) * Float(w)).rounded()),
                Int(((1 - (ny * 0.5 + 0.5)) * Float(h)).rounded()))
    }

    // ── geometry ───────────────────────────────────────────────────────────
    private func exploredBounds(_ world: World) -> (center: SIMD3<Float>, extent: Float) {
        let map = world.map
        var minX = Float(map.w), maxX: Float = 0, minZ = Float(map.h), maxZ: Float = 0, n: Float = 0
        for y in 0..<map.h { for x in 0..<map.w where map.visited[map.idx(x, y)] && map.wall[map.idx(x, y)] == 0 {
            minX = min(minX, Float(x)); maxX = max(maxX, Float(x + 1))
            minZ = min(minZ, Float(y)); maxZ = max(maxZ, Float(y + 1)); n += 1
        } }
        if n == 0 { return (SIMD3(Float(map.w) / 2, 0, Float(map.h) / 2), Float(max(map.w, map.h))) }
        let cx = (minX + maxX) / 2, cz = (minZ + maxZ) / 2
        return (SIMD3(cx, Self.wallH * 0.35, cz), max(6, max(maxX - minX, maxZ - minZ)))
    }

    private func buildGeometry(_ world: World) -> [AMVert] {
        let map = world.map
        var v: [AMVert] = []
        v.reserveCapacity(map.w * map.h * 8)

        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ nn: SIMD3<Float>, _ col: SIMD3<Float>) {
            for p in [a, b, c, a, c, d] {
                v.append(AMVert(px: p.x, py: p.y, pz: p.z, nx: nn.x, ny: nn.y, nz: nn.z, r: col.x, g: col.y, b: col.z))
            }
        }
        func prism(_ cx: Float, _ cz: Float, _ hw: Float, _ ht: Float, _ col: SIMD3<Float>) {
            let x0 = cx - hw, x1 = cx + hw, z0 = cz - hw, z1 = cz + hw, y1 = ht
            quad(SIMD3(x0, 0, z0), SIMD3(x0, 0, z1), SIMD3(x0, y1, z1), SIMD3(x0, y1, z0), SIMD3(-1, 0, 0), col)
            quad(SIMD3(x1, 0, z1), SIMD3(x1, 0, z0), SIMD3(x1, y1, z0), SIMD3(x1, y1, z1), SIMD3(1, 0, 0), col)
            quad(SIMD3(x0, 0, z0), SIMD3(x1, 0, z0), SIMD3(x1, y1, z0), SIMD3(x0, y1, z0), SIMD3(0, 0, -1), col)
            quad(SIMD3(x1, 0, z1), SIMD3(x0, 0, z1), SIMD3(x0, y1, z1), SIMD3(x1, y1, z1), SIMD3(0, 0, 1), col)
            quad(SIMD3(x0, y1, z0), SIMD3(x1, y1, z0), SIMD3(x1, y1, z1), SIMD3(x0, y1, z1), SIMD3(0, 1, 0), col)
        }

        let floorCol = SIMD3<Float>(0.17, 0.21, 0.29)
        let steelCol = SIMD3<Float>(0.47, 0.59, 0.77)
        let h = Self.wallH

        func wallColor(_ nx: Int, _ ny: Int) -> SIMD3<Float> {
            guard map.inBounds(nx, ny), let door = map.doors[map.idx(nx, ny)] else { return steelCol }
            if let lock = door.locked { return keyRGB(lock) }
            return SIMD3(0.91, 0.77, 0.38)           // unlocked door — amber
        }
        func solid(_ x: Int, _ y: Int) -> Bool { !map.inBounds(x, y) || map.wall[map.idx(x, y)] != 0 }

        for y in 0..<map.h { for x in 0..<map.w {
            let i = map.idx(x, y)
            guard map.visited[i], map.wall[i] == 0 else { continue }
            let fx = Float(x), fz = Float(y)
            // explored floor tile
            quad(SIMD3(fx, 0, fz), SIMD3(fx + 1, 0, fz), SIMD3(fx + 1, 0, fz + 1), SIMD3(fx, 0, fz + 1), SIMD3(0, 1, 0), floorCol)
            // a wall face on each solid side (fog-of-war: only walls that border seen floor)
            if solid(x + 1, y) { quad(SIMD3(fx + 1, 0, fz), SIMD3(fx + 1, 0, fz + 1), SIMD3(fx + 1, h, fz + 1), SIMD3(fx + 1, h, fz), SIMD3(-1, 0, 0), wallColor(x + 1, y)) }
            if solid(x - 1, y) { quad(SIMD3(fx, 0, fz + 1), SIMD3(fx, 0, fz), SIMD3(fx, h, fz), SIMD3(fx, h, fz + 1), SIMD3(1, 0, 0), wallColor(x - 1, y)) }
            if solid(x, y + 1) { quad(SIMD3(fx + 1, 0, fz + 1), SIMD3(fx, 0, fz + 1), SIMD3(fx, h, fz + 1), SIMD3(fx + 1, h, fz + 1), SIMD3(0, 0, -1), wallColor(x, y + 1)) }
            if solid(x, y - 1) { quad(SIMD3(fx, 0, fz), SIMD3(fx + 1, 0, fz), SIMD3(fx + 1, h, fz), SIMD3(fx, h, fz), SIMD3(0, 0, 1), wallColor(x, y - 1)) }
        } }

        // markers — vertical prisms so they read from any orbit angle
        if map.exitCell >= 0 {
            let ex = map.exitCell % map.w, ey = map.exitCell / map.w
            let seen = [(1, 0), (-1, 0), (0, 1), (0, -1)].contains { map.inBounds(ex + $0.0, ey + $0.1) && map.visited[map.idx(ex + $0.0, ey + $0.1)] }
            if seen { prism(Float(ex) + 0.5, Float(ey) + 0.5, 0.22, h * 1.6, SIMD3(0.38, 0.89, 0.47)) }
        }
        for it in world.items where !it.taken {
            guard let kc = keyColorOf(it.kind) else { continue }
            let cx = Int(it.pos.x), cy = Int(it.pos.y)
            guard map.inBounds(cx, cy), map.visited[map.idx(cx, cy)] else { continue }
            prism(it.pos.x, it.pos.y, 0.16, h * 1.3, keyRGB(kc))
        }
        // the marine — a bright CYAN pillar (distinct from the green exit) plus a floor
        // wedge pointing his facing
        let px = world.player.pos.x, pz = world.player.pos.y
        prism(px, pz, 0.17, h * 1.7, SIMD3(0.30, 0.82, 1.0))
        let fdir = SIMD2<Float>(cos(world.player.dir), sin(world.player.dir))
        let side = SIMD2<Float>(-fdir.y, fdir.x)
        let tip = SIMD2(px, pz) + fdir * 0.55
        let bl = SIMD2(px, pz) - fdir * 0.10 + side * 0.24
        let br = SIMD2(px, pz) - fdir * 0.10 - side * 0.24
        let pc = SIMD3<Float>(0.55, 0.92, 1.0)
        quad(SIMD3(tip.x, 0.02, tip.y), SIMD3(bl.x, 0.02, bl.y), SIMD3(br.x, 0.02, br.y), SIMD3(tip.x, 0.02, tip.y), SIMD3(0, 1, 0), pc)

        return v
    }

    private func keyColorOf(_ k: ItemKind) -> KeyColor? {
        switch k {
        case .keyRed: return .red
        case .keyBlue: return .blue
        case .keyYellow: return .yellow
        default: return nil
        }
    }
    private func keyRGB(_ k: KeyColor) -> SIMD3<Float> {
        switch k {
        case .red: return SIMD3(0.89, 0.24, 0.22)
        case .blue: return SIMD3(0.33, 0.49, 0.93)
        case .yellow: return SIMD3(0.92, 0.80, 0.24)
        }
    }

    // ── camera math (left-handed, camera looks +z, depth 0…1) ────────────────
    private static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = normalize(center - eye)
        let r = normalize(cross(up, f))
        let u = cross(f, r)
        return simd_float4x4(SIMD4(r.x, u.x, f.x, 0),
                             SIMD4(r.y, u.y, f.y, 0),
                             SIMD4(r.z, u.z, f.z, 0),
                             SIMD4(-dot(r, eye), -dot(u, eye), -dot(f, eye), 1))
    }
    private static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let ys = 1 / tan(fovY / 2), xs = ys / aspect
        let a = far / (far - near), b = -far * near / (far - near)
        return simd_float4x4(SIMD4(xs, 0, 0, 0),
                             SIMD4(0, ys, 0, 0),
                             SIMD4(0, 0, a, 1),
                             SIMD4(0, 0, b, 0))
    }

    private struct AMUniforms { var mvp: simd_float4x4; var lightDir: SIMD4<Float> }

    private static let shaderSrc = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float px, py, pz, nx, ny, nz, r, g, b; };
    struct U { float4x4 mvp; float4 lightDir; };
    struct VOut { float4 pos [[position]]; float3 nrm; float3 col; };
    vertex VOut amVertex(uint vid [[vertex_id]], constant V* vs [[buffer(0)]], constant U& u [[buffer(1)]]) {
        V v = vs[vid];
        VOut o;
        o.pos = u.mvp * float4(v.px, v.py, v.pz, 1.0);
        o.nrm = float3(v.nx, v.ny, v.nz);
        o.col = float3(v.r, v.g, v.b);
        return o;
    }
    fragment float4 amFragment(VOut in [[stage_in]], constant U& u [[buffer(1)]]) {
        float3 N = normalize(in.nrm);
        float ndl = max(0.0, dot(N, normalize(u.lightDir.xyz)));
        float sh = 0.42 + 0.58 * ndl;                 // soft key + fill so faces read as 3-D
        return float4(in.col * sh, 1.0);
    }
    """
}
