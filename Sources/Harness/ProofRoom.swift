#if CITADEL_HARNESS
import Foundation
import Metal
import MetalKit
import ModelIO
import simd

// ============================================================================
//  ProofRoom — a "convincing look" proof (CITADEL_PROOFROOM)
//
//  Renders ONE industrial room the CONVENTIONAL way — real triangle geometry,
//  physically-based shading (Cook-Torrance GGX), a shadow-mapped key light for
//  crisp contact shadows, and PROCEDURAL surface materials (fbm-driven normal +
//  roughness + grime, so no texture assets are needed for this first proof).
//
//  The question it answers: does a rasterised + PBR + shadowed pipeline read as
//  a REAL place, where the SDF raymarcher reads as plasticky? Compare the output
//  against a current-renderer room shot (CITADEL_ROOMS) side by side.
//
//  Headless only. Writes PNGs to the Desktop (or a passed dir). No GUI, no audio.
// ============================================================================
enum ProofRoom {

    // One interleaved vertex: position, normal, material id. UVs are derived
    // triplanar in the shader (world-scale), so no per-vertex UV is needed.
    struct PVert { var px, py, pz, nx, ny, nz, mat: Float }

    // Uniforms shared by vertex + fragment (≤ 4KB → setVertexBytes/setFragmentBytes).
    struct Cam {
        var mvp: simd_float4x4       // main camera  P * V   (model = identity, world space)
        var lightMVP: simd_float4x4  // key light    P * V   (for the shadow lookup)
        var eye: SIMD4<Float>        // xyz + pad
        var keyPos: SIMD4<Float>     // xyz + intensity
        var keyCol: SIMD4<Float>     // rgb + pad
        var fillPos: SIMD4<Float>    // xyz + intensity
        var ambient: SIMD4<Float>    // rgb + grade(0/1)
        var meshModel: simd_float4x4 // model matrix for the creature mesh (identity when unused)
    }

    // ── tiny matrix builders (column-major) ──
    private static func T(_ t: SIMD3<Float>) -> simd_float4x4 { var m = matrix_identity_float4x4; m.columns.3 = SIMD4(t.x, t.y, t.z, 1); return m }
    private static func S(_ s: Float) -> simd_float4x4 { simd_float4x4(diagonal: SIMD4(s, s, s, 1)) }
    private static func rotX(_ a: Float) -> simd_float4x4 { let c = cos(a), s = sin(a)
        return simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1)) }
    private static func rotY(_ a: Float) -> simd_float4x4 { let c = cos(a), s = sin(a)
        return simd_float4x4(SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1)) }

    static let W = 1280, H = 800, SHADOW = 1024

    // ── geometry helpers ────────────────────────────────────────────────────
    private static func v(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ m: Float) -> PVert {
        PVert(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z, mat: m)
    }
    private static func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                             _ n: SIMD3<Float>, _ m: Float, _ out: inout [PVert]) {
        out += [v(a, n, m), v(b, n, m), v(c, n, m), v(a, n, m), v(c, n, m), v(d, n, m)]
    }
    /// Axis-aligned box. `inward` flips normals (for the room shell you stand inside).
    private static func box(_ c: SIMD3<Float>, _ h: SIMD3<Float>, _ m: Float, inward: Bool, _ out: inout [PVert]) {
        let s: Float = inward ? -1 : 1
        let lo = c - h, hi = c + h
        // +X / -X
        quad(SIMD3(hi.x, lo.y, lo.z), SIMD3(hi.x, lo.y, hi.z), SIMD3(hi.x, hi.y, hi.z), SIMD3(hi.x, hi.y, lo.z), SIMD3(s, 0, 0), m, &out)
        quad(SIMD3(lo.x, lo.y, hi.z), SIMD3(lo.x, lo.y, lo.z), SIMD3(lo.x, hi.y, lo.z), SIMD3(lo.x, hi.y, hi.z), SIMD3(-s, 0, 0), m, &out)
        // +Y / -Y
        quad(SIMD3(lo.x, hi.y, lo.z), SIMD3(hi.x, hi.y, lo.z), SIMD3(hi.x, hi.y, hi.z), SIMD3(lo.x, hi.y, hi.z), SIMD3(0, s, 0), m, &out)
        quad(SIMD3(lo.x, lo.y, hi.z), SIMD3(hi.x, lo.y, hi.z), SIMD3(hi.x, lo.y, lo.z), SIMD3(lo.x, lo.y, lo.z), SIMD3(0, -s, 0), m, &out)
        // +Z / -Z
        quad(SIMD3(lo.x, lo.y, hi.z), SIMD3(lo.x, hi.y, hi.z), SIMD3(hi.x, hi.y, hi.z), SIMD3(hi.x, lo.y, hi.z), SIMD3(0, 0, s), m, &out)
        quad(SIMD3(hi.x, lo.y, lo.z), SIMD3(hi.x, hi.y, lo.z), SIMD3(lo.x, hi.y, lo.z), SIMD3(lo.x, lo.y, lo.z), SIMD3(0, 0, -s), m, &out)
    }
    /// Room shell: six inward-facing quads (floor/ceiling/walls) with per-face materials.
    private static func room(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>, wall: Float, floor: Float, ceil: Float, _ out: inout [PVert]) {
        quad(SIMD3(lo.x, lo.y, lo.z), SIMD3(hi.x, lo.y, lo.z), SIMD3(hi.x, lo.y, hi.z), SIMD3(lo.x, lo.y, hi.z), SIMD3(0, 1, 0), floor, &out)  // floor
        quad(SIMD3(lo.x, hi.y, lo.z), SIMD3(lo.x, hi.y, hi.z), SIMD3(hi.x, hi.y, hi.z), SIMD3(hi.x, hi.y, lo.z), SIMD3(0, -1, 0), ceil, &out)  // ceiling
        quad(SIMD3(lo.x, lo.y, lo.z), SIMD3(lo.x, lo.y, hi.z), SIMD3(lo.x, hi.y, hi.z), SIMD3(lo.x, hi.y, lo.z), SIMD3(1, 0, 0), wall, &out)    // x=lo
        quad(SIMD3(hi.x, lo.y, hi.z), SIMD3(hi.x, lo.y, lo.z), SIMD3(hi.x, hi.y, lo.z), SIMD3(hi.x, hi.y, hi.z), SIMD3(-1, 0, 0), wall, &out)   // x=hi
        quad(SIMD3(hi.x, lo.y, lo.z), SIMD3(lo.x, lo.y, lo.z), SIMD3(lo.x, hi.y, lo.z), SIMD3(hi.x, hi.y, lo.z), SIMD3(0, 0, 1), wall, &out)    // z=lo
        quad(SIMD3(lo.x, lo.y, hi.z), SIMD3(hi.x, lo.y, hi.z), SIMD3(hi.x, hi.y, hi.z), SIMD3(lo.x, hi.y, hi.z), SIMD3(0, 0, -1), wall, &out)   // z=hi
    }
    /// A capped cylinder from p0 to p1 (drum, pipe).
    private static func cyl(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, r: Float, seg: Int, _ m: Float, _ out: inout [PVert]) {
        let axis = simd_normalize(p1 - p0)
        var up = SIMD3<Float>(0, 1, 0)
        if abs(simd_dot(axis, up)) > 0.9 { up = SIMD3(1, 0, 0) }
        let u = simd_normalize(simd_cross(axis, up)), w = simd_cross(axis, u)
        func ring(_ i: Int, _ base: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
            let a = Float(i) / Float(seg) * 2 * .pi
            let dir = cos(a) * u + sin(a) * w
            return (base + dir * r, dir)   // point, radial normal
        }
        for i in 0..<seg {
            let (a0, n0) = ring(i, p0), (a1, n1) = ring(i + 1, p0)
            let (b0, _) = ring(i, p1), (b1, _) = ring(i + 1, p1)
            out += [v(a0, n0, m), v(a1, n1, m), v(b1, n1, m), v(a0, n0, m), v(b1, n1, m), v(b0, n0, m)]
            // caps
            out += [v(p0, -axis, m), v(a1, -axis, m), v(a0, -axis, m)]
            out += [v(p1, axis, m), v(b0, axis, m), v(b1, axis, m)]
        }
    }

    // ── camera matrices (copied from the MeshCreature convention that reproduces
    //    the raymarch ray model, so this lines up with the game's FOV) ──────────
    private static func view(_ eye: SIMD3<Float>, _ r: SIMD3<Float>, _ u: SIMD3<Float>, _ f: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(SIMD4(r.x, u.x, f.x, 0), SIMD4(r.y, u.y, f.y, 0), SIMD4(r.z, u.z, f.z, 0),
                      SIMD4(-simd_dot(r, eye), -simd_dot(u, eye), -simd_dot(f, eye), 1))
    }
    private static func proj(plane: Float, horizon: Float, w: Float, h: Float, near: Float, far: Float) -> simd_float4x4 {
        let a = far / (far - near), b = -far * near / (far - near)
        return simd_float4x4(SIMD4(1 / plane, 0, 0, 0), SIMD4(0, w / h, 0, 0),
                             SIMD4(0, 1 - 2 * horizon / h, a, 1), SIMD4(0, 0, b, 0))
    }
    /// Camera from an eye + a horizontal look direction (the game has no pitch).
    private static func camMVP(eye: SIMD3<Float>, dir: Float, near: Float, far: Float) -> simd_float4x4 {
        let f = SIMD3<Float>(cos(dir), 0, sin(dir)), r = SIMD3<Float>(-sin(dir), 0, cos(dir)), u = SIMD3<Float>(0, 1, 0)
        return proj(plane: 0.66, horizon: 400, w: Float(W), h: Float(H), near: near, far: far) * view(eye, r, u, f)
    }
    /// Light camera (look-at) for the shadow map — same right = cross(fwd,up) basis.
    private static func lightMVP(pos: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(target - pos)
        let r = simd_normalize(simd_cross(f, SIMD3<Float>(0, 1, 0)))
        let u = simd_normalize(simd_cross(r, f))
        return proj(plane: 0.95, horizon: Float(SHADOW / 2), w: Float(SHADOW), h: Float(SHADOW), near: 0.15, far: 14) * view(pos, r, u, f)
    }

    static func run(outDir: String?) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            print("ProofRoom: no Metal device"); return
        }
        let base = outDir.map { ($0 as NSString).expandingTildeInPath } ?? ("~/Desktop" as NSString).expandingTildeInPath
        let dir = URL(fileURLWithPath: base, isDirectory: true)

        // ── scene ────────────────────────────────────────────────────────────
        // A 6×6 cell room, ceiling at y=1 (one Citadel cell = 1 world unit).
        var verts: [PVert] = []
        room(SIMD3(0, 0, 0), SIMD3(6, 1, 6), wall: 0, floor: 1, ceil: 2, &verts)
        cyl(SIMD3(3.0, 0.0, 3.2), SIMD3(3.0, 0.62, 3.2), r: 0.30, seg: 40, 3, &verts)   // fuel drum (blue steel)
        box(SIMD3(4.25, 0.26, 3.7), SIMD3(0.28, 0.26, 0.30), 5, inward: false, &verts)  // crate (painted iron)
        cyl(SIMD3(0.15, 0.80, 5.85), SIMD3(5.85, 0.80, 5.85), r: 0.055, seg: 20, 4, &verts) // wall pipe run (steel)
        cyl(SIMD3(0.15, 0.66, 5.72), SIMD3(5.85, 0.66, 5.72), r: 0.035, seg: 16, 4, &verts) // a thinner conduit under it

        guard let vbuf = device.makeBuffer(bytes: verts, length: MemoryLayout<PVert>.stride * verts.count) else { return }
        let nVerts = verts.count

        // ── load the drone creature mesh (Z-up USDZ → Y-up, scaled, feet on floor) ──
        let vdesc = MDLVertexDescriptor()
        vdesc.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        vdesc.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0)
        vdesc.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: 24, bufferIndex: 0)
        (vdesc.layouts[0] as? MDLVertexBufferLayout)?.stride = 32
        var creatureMesh: MTKMesh? = nil
        var meshModel = matrix_identity_float4x4
        if let meshURL = Bundle.main.url(forResource: "drone", withExtension: "usdz") {
            let asset = MDLAsset(url: meshURL, vertexDescriptor: nil, bufferAllocator: MTKMeshBufferAllocator(device: device))
            if let mdl = asset.childObjects(of: MDLMesh.self).first as? MDLMesh {
                let bb = mdl.boundingBox
                let bmin = SIMD3<Float>(bb.minBounds.x, bb.minBounds.y, bb.minBounds.z)
                let bmax = SIMD3<Float>(bb.maxBounds.x, bb.maxBounds.y, bb.maxBounds.z)
                mdl.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.4)
                mdl.vertexDescriptor = vdesc
                if let m = try? MTKMesh(mesh: mdl, device: device) {
                    creatureMesh = m
                    let center = (bmin + bmax) * 0.5
                    let heightZ = max(0.001, bmax.z - bmin.z)                  // the mesh is Z-up
                    let s = 0.66 / heightZ                                     // ~0.66 tall (fits under the 1.0 ceiling)
                    let m0 = rotY(2.3) * S(s) * rotX(-.pi / 2) * T(-center)    // Z-up→Y-up, scale, yaw (tweak to face the lens)
                    var lo = SIMD3<Float>(repeating: 1e9), hi = SIMD3<Float>(repeating: -1e9)
                    for cx in [bmin.x, bmax.x] { for cy in [bmin.y, bmax.y] { for cz in [bmin.z, bmax.z] {
                        let p = m0 * SIMD4<Float>(cx, cy, cz, 1); let q = SIMD3(p.x, p.y, p.z)
                        lo = simd_min(lo, q); hi = simd_max(hi, q) } } }
                    let place = SIMD3<Float>(3.5, 0, 2.4)                      // right-of-centre, nearer the lens than the drum
                    let off = SIMD3<Float>(place.x - (lo.x + hi.x) * 0.5, place.y - lo.y, place.z - (lo.z + hi.z) * 0.5)
                    meshModel = T(off) * m0
                }
            }
        }
        if creatureMesh == nil { print("ProofRoom: WARNING — drone mesh not loaded (room only)") }

        // ── camera + lights ───────────────────────────────────────────────────
        let eye = SIMD3<Float>(0.85, 0.5, 0.85)
        let dir45: Float = atan2(4.6 - eye.z, 4.6 - eye.x)   // look toward the far corner + props
        let keyPos = SIMD3<Float>(4.9, 0.82, 2.1)            // RIGHT side (opposite the camera) so props throw shadows LEFT, toward the lens
        let keyTarget = SIMD3<Float>(2.6, 0.04, 4.2)
        var cam = Cam(
            mvp: camMVP(eye: eye, dir: dir45, near: 0.03, far: 64),
            lightMVP: lightMVP(pos: keyPos, target: keyTarget),
            eye: SIMD4(eye, 0),
            keyPos: SIMD4(keyPos, 4.6),                       // intensity
            keyCol: SIMD4(0.80, 0.86, 1.00, 0),               // WorldLight.lampColor
            fillPos: SIMD4(0.9, 0.8, 2.2, 0.34),              // cool fill from the camera side (lifts the creature's near face), no shadow
            ambient: SIMD4(0.035, 0.042, 0.058, 1),           // low ambient; .w=1 → apply filmic grade
            meshModel: meshModel
        )

        // ── build pipelines ────────────────────────────────────────────────────
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: shaderSrc, options: nil) }
        catch { print("ProofRoom: shader compile failed:\n\(error)"); return }
        let mainPD = MTLRenderPipelineDescriptor()
        mainPD.vertexFunction = lib.makeFunction(name: "pr_vertex")
        mainPD.fragmentFunction = lib.makeFunction(name: "pr_fragment")
        mainPD.colorAttachments[0].pixelFormat = .rgba8Unorm
        mainPD.depthAttachmentPixelFormat = .depth32Float
        let shadowPD = MTLRenderPipelineDescriptor()
        shadowPD.vertexFunction = lib.makeFunction(name: "pr_shadow_vertex")
        shadowPD.fragmentFunction = nil                        // depth-only
        shadowPD.depthAttachmentPixelFormat = .depth32Float
        guard let mainPS = try? device.makeRenderPipelineState(descriptor: mainPD),
              let shadowPS = try? device.makeRenderPipelineState(descriptor: shadowPD) else { print("ProofRoom: pipeline failed"); return }
        let dsd = MTLDepthStencilDescriptor(); dsd.depthCompareFunction = .less; dsd.isDepthWriteEnabled = true
        let dss = device.makeDepthStencilState(descriptor: dsd)!

        // creature-mesh pipelines — drawn through the SAME PBR fragment + shadow map,
        // so the drone is lit identically to the room AND casts a real shadow.
        var meshMainPS: MTLRenderPipelineState? = nil
        var meshShadowPS: MTLRenderPipelineState? = nil
        if creatureMesh != nil {
            let mmPD = MTLRenderPipelineDescriptor()
            mmPD.vertexFunction = lib.makeFunction(name: "pr_mesh_vertex")
            mmPD.fragmentFunction = lib.makeFunction(name: "pr_fragment")
            mmPD.colorAttachments[0].pixelFormat = .rgba8Unorm
            mmPD.depthAttachmentPixelFormat = .depth32Float
            mmPD.vertexDescriptor = MTKMetalVertexDescriptorFromModelIO(vdesc)
            let msPD = MTLRenderPipelineDescriptor()
            msPD.vertexFunction = lib.makeFunction(name: "pr_mesh_shadow_vertex")
            msPD.fragmentFunction = nil
            msPD.depthAttachmentPixelFormat = .depth32Float
            msPD.vertexDescriptor = MTKMetalVertexDescriptorFromModelIO(vdesc)
            meshMainPS = try? device.makeRenderPipelineState(descriptor: mmPD)
            meshShadowPS = try? device.makeRenderPipelineState(descriptor: msPD)
        }
        func drawCreature(_ enc: MTLRenderCommandEncoder, _ ps: MTLRenderPipelineState?) {
            guard let mesh = creatureMesh, let ps else { return }
            enc.setRenderPipelineState(ps); enc.setDepthStencilState(dss); enc.setCullMode(.none)
            for (i, vb) in mesh.vertexBuffers.enumerated() { enc.setVertexBuffer(vb.buffer, offset: vb.offset, index: i) }
            enc.setVertexBytes(&cam, length: MemoryLayout<Cam>.stride, index: 1)
            for sm in mesh.submeshes {
                enc.drawIndexedPrimitives(type: sm.primitiveType, indexCount: sm.indexCount, indexType: sm.indexType,
                                          indexBuffer: sm.indexBuffer.buffer, indexBufferOffset: sm.indexBuffer.offset)
            }
        }

        func tex(_ f: MTLPixelFormat, _ w: Int, _ h: Int, _ store: MTLStorageMode, _ usage: MTLTextureUsage) -> MTLTexture {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: false)
            td.storageMode = store; td.usage = usage; return device.makeTexture(descriptor: td)!
        }
        let shadowTex = tex(.depth32Float, SHADOW, SHADOW, .private, [.renderTarget, .shaderRead])
        let colTex = tex(.rgba8Unorm, W, H, .shared, [.renderTarget])
        let zTex = tex(.depth32Float, W, H, .private, [.renderTarget])

        // ── pass 1: shadow depth from the key light ─────────────────────────────
        let cmd = queue.makeCommandBuffer()!
        let srp = MTLRenderPassDescriptor()
        srp.depthAttachment.texture = shadowTex
        srp.depthAttachment.loadAction = .clear; srp.depthAttachment.storeAction = .store; srp.depthAttachment.clearDepth = 1.0
        let se = cmd.makeRenderCommandEncoder(descriptor: srp)!
        se.setRenderPipelineState(shadowPS); se.setDepthStencilState(dss); se.setCullMode(.none)
        se.setVertexBuffer(vbuf, offset: 0, index: 0)
        se.setVertexBytes(&cam, length: MemoryLayout<Cam>.stride, index: 1)
        se.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: nVerts)
        drawCreature(se, meshShadowPS)                          // drone casts into the shadow map too
        se.endEncoding()

        // ── pass 2: main PBR render, sampling the shadow map ────────────────────
        let mrp = MTLRenderPassDescriptor()
        mrp.colorAttachments[0].texture = colTex
        mrp.colorAttachments[0].loadAction = .clear; mrp.colorAttachments[0].storeAction = .store
        mrp.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1)
        mrp.depthAttachment.texture = zTex
        mrp.depthAttachment.loadAction = .clear; mrp.depthAttachment.storeAction = .dontCare; mrp.depthAttachment.clearDepth = 1.0
        let me = cmd.makeRenderCommandEncoder(descriptor: mrp)!
        me.setRenderPipelineState(mainPS); me.setDepthStencilState(dss); me.setCullMode(.none)
        me.setVertexBuffer(vbuf, offset: 0, index: 0)
        me.setVertexBytes(&cam, length: MemoryLayout<Cam>.stride, index: 1)
        me.setFragmentBytes(&cam, length: MemoryLayout<Cam>.stride, index: 1)
        me.setFragmentTexture(shadowTex, index: 0)
        me.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: nVerts)
        drawCreature(me, meshMainPS)                            // drone, PBR-lit + shadowed like everything else
        me.endEncoding()
        cmd.commit(); cmd.waitUntilCompleted()

        // ── read back → PNG ─────────────────────────────────────────────────────
        var px = [UInt32](repeating: 0, count: W * H)
        px.withUnsafeMutableBytes { colTex.getBytes($0.baseAddress!, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        px.withUnsafeMutableBufferPointer {
            Captures.writePNG($0.baseAddress!, w: W, h: H, scale: 1, to: dir.appendingPathComponent("proof-room-raster.png"))
        }
        print("ProofRoom: wrote proof-room-raster.png (\(nVerts) verts) → \(dir.path)")
    }

    // ════════════════════════════════════════════════════════════════════════
    static let shaderSrc = """
    #include <metal_stdlib>
    using namespace metal;

    struct Cam {
        float4x4 mvp;
        float4x4 lightMVP;
        float4 eye;
        float4 keyPos;    // xyz + intensity
        float4 keyCol;
        float4 fillPos;   // xyz + intensity
        float4 ambient;   // rgb + grade
        float4x4 meshModel;
    };
    struct PV { float px, py, pz, nx, ny, nz, mat; };
    struct VOut { float4 clip [[position]]; float3 wp; float3 wn; float mat; };
    struct SOut { float4 clip [[position]]; };

    // ── procedural noise ──
    float h21(float2 p){ p = fract(p*float2(127.1,311.7)); p += dot(p,p+34.5); return fract(p.x*p.y); }
    float vnoise(float2 p){ float2 i=floor(p),f=fract(p); f=f*f*(3-2*f);
        float a=h21(i),b=h21(i+float2(1,0)),c=h21(i+float2(0,1)),d=h21(i+float2(1,1));
        return mix(mix(a,b,f.x),mix(c,d,f.x),f.y); }
    float fbm(float2 p){ float s=0,a=0.5; for(int i=0;i<5;i++){ s+=a*vnoise(p); p*=2.03; a*=0.5;} return s; }
    // dark groove near 1-unit cell boundaries → reads as assembled panels/plates, not fog
    float panelSeam(float2 uv){ float2 f=abs(fract(uv)-0.5); float2 g=smoothstep(0.44,0.5,f); return max(g.x,g.y); }

    struct Mat { float3 albedo; float rough; float metal; };
    Mat matFor(float id){
        if(id<0.5) return Mat{ float3(0.58,0.61,0.68), 0.48, 0.72 };   // 0 brushed-steel wall
        if(id<1.5) return Mat{ float3(0.30,0.31,0.35), 0.62, 0.38 };   // 1 dark metal floor
        if(id<2.5) return Mat{ float3(0.17,0.19,0.23), 0.70, 0.30 };   // 2 dark tech ceiling
        if(id<3.5) return Mat{ float3(0.10,0.20,0.42), 0.34, 0.80 };   // 3 blue-steel drum
        if(id<4.5) return Mat{ float3(0.44,0.46,0.52), 0.30, 0.88 };   // 4 steel pipe
        if(id<5.5) return Mat{ float3(0.47,0.41,0.31), 0.55, 0.35 };   // 5 painted-iron crate
        return         Mat{ float3(0.13,0.15,0.13), 0.44, 0.14 };      // 6 organic chitin (creature)
    }

    // Triplanar world-scale sample of the fbm field (returns value + a gradient for bump).
    float3 triNoise(float3 wp, float3 n, float scale){
        float3 an = abs(n); an /= (an.x+an.y+an.z);
        float2 uvX = wp.zy*scale, uvY = wp.xz*scale, uvZ = wp.xy*scale;
        float e = 0.35/scale;
        float vX = fbm(uvX), vY = fbm(uvY), vZ = fbm(uvZ);
        float v  = vX*an.x + vY*an.y + vZ*an.z;
        // cheap gradient in the two dominant tangent axes
        float gx = (fbm(uvY+float2(e,0))-vY);
        float gz = (fbm(uvY+float2(0,e))-vY);
        return float3(v, gx, gz);
    }

    // ── PBR (Cook-Torrance GGX) ──
    float D_GGX(float ndh, float a){ float a2=a*a; float d=ndh*ndh*(a2-1)+1; return a2/(3.14159265*d*d+1e-6); }
    float G_Smith(float ndv, float ndl, float a){ float k=(a+1)*(a+1)/8; float gv=ndv/(ndv*(1-k)+k); float gl=ndl/(ndl*(1-k)+k); return gv*gl; }
    float3 F_Schlick(float vdh, float3 f0){ return f0 + (1-f0)*pow(1.0-vdh,5.0); }

    vertex VOut pr_vertex(uint vid [[vertex_id]], constant PV* vs [[buffer(0)]], constant Cam& C [[buffer(1)]]){
        PV p = vs[vid]; float3 wp = float3(p.px,p.py,p.pz);
        VOut o; o.clip = C.mvp * float4(wp,1); o.wp = wp; o.wn = normalize(float3(p.nx,p.ny,p.nz)); o.mat = p.mat; return o;
    }
    vertex SOut pr_shadow_vertex(uint vid [[vertex_id]], constant PV* vs [[buffer(0)]], constant Cam& C [[buffer(1)]]){
        PV p = vs[vid]; SOut o; o.clip = C.lightMVP * float4(p.px,p.py,p.pz,1); return o;
    }
    // ── creature mesh (MTKMesh, stage_in) — same PBR fragment + shadow map as the room ──
    struct MV { float3 pos [[attribute(0)]]; float3 nrm [[attribute(1)]]; float2 uv [[attribute(2)]]; };
    vertex VOut pr_mesh_vertex(MV v [[stage_in]], constant Cam& C [[buffer(1)]]){
        float3 wp = (C.meshModel * float4(v.pos,1)).xyz;
        VOut o; o.clip = C.mvp * float4(wp,1); o.wp = wp;
        o.wn = normalize((C.meshModel * float4(v.nrm,0.0)).xyz);
        o.mat = 6.0; return o;
    }
    vertex SOut pr_mesh_shadow_vertex(MV v [[stage_in]], constant Cam& C [[buffer(1)]]){
        SOut o; o.clip = C.lightMVP * (C.meshModel * float4(v.pos,1)); return o;
    }

    float pcfShadow(depth2d<float> smap, float3 wp, float4x4 lmvp, float ndl){
        float4 lc = lmvp * float4(wp,1); if(lc.w<=0) return 1.0;
        float3 ndc = lc.xyz/lc.w;
        float2 uv = float2(ndc.x*0.5+0.5, 0.5-ndc.y*0.5);
        if(any(uv<float2(0.0))||any(uv>float2(1.0))) return 1.0;
        constexpr sampler ss(coord::normalized, address::clamp_to_edge, filter::nearest);
        float bias = max(0.004*(1.0-ndl), 0.0012);
        float lit=0; float t=1.0/1024.0;
        for(int j=-1;j<=1;j++) for(int i=-1;i<=1;i++){
            float d = smap.sample(ss, uv+float2(i,j)*t);
            lit += (ndc.z-bias <= d) ? 1.0 : 0.0;
        }
        return lit/9.0;
    }

    fragment float4 pr_fragment(VOut in [[stage_in]], constant Cam& C [[buffer(1)]], depth2d<float> smap [[texture(0)]]){
        Mat m = matFor(in.mat);
        // panel seams on structural surfaces (floor/wall/ceiling) — the "constructed, not fog" cue
        if(in.mat < 2.5){
            float3 gn = normalize(in.wn); float3 an = abs(gn);
            float2 puv = an.y>0.5 ? in.wp.xz : (an.x>0.5 ? in.wp.zy : in.wp.xy);
            float seam = panelSeam(puv);
            m.albedo *= (1.0 - 0.5*seam);
            m.rough = min(1.0, m.rough + 0.25*seam);
        }
        float3 N = normalize(in.wn);

        // procedural surface: bump the normal, vary roughness + darken with grime.
        float scale = (in.mat<0.5||in.mat>4.5) ? 3.0 : 6.0;     // walls/crate coarser, metal finer
        float3 tn = triNoise(in.wp, N, scale);
        // tangent-ish bump: perturb N by the noise gradient (kept subtle on metal)
        float bumpAmt = (in.mat<2.5) ? 0.35 : 0.22;
        float3 T = normalize(abs(N.y)<0.9 ? cross(float3(0,1,0),N) : float3(1,0,0));
        float3 B = cross(N,T);
        N = normalize(N - (tn.y*T + tn.z*B)*bumpAmt);
        float grime = tn.x;
        m.rough = clamp(m.rough + (grime-0.5)*0.34, 0.05, 1.0);
        m.albedo *= (0.72 + 0.5*grime);                          // dirt/wear variation
        // vertical grime streaks on walls
        if(in.mat<0.5){ float st = fbm(float2(in.wp.x+in.wp.z, in.wp.y*0.6)*float2(2.0,7.0)); m.albedo *= (0.82+0.3*st); }

        float3 Vv = normalize(C.eye.xyz - in.wp);
        float ndv = max(dot(N,Vv),1e-3);
        float3 f0 = mix(float3(0.04), m.albedo, m.metal);
        float3 diffCol = m.albedo*(1-m.metal);
        float3 col = float3(0);

        float keyShadow = 1.0;
        // key light (shadow-mapped point light)
        {
            float3 Ld = C.keyPos.xyz - in.wp; float dist = length(Ld); float3 L = Ld/dist;
            float ndl = max(dot(N,L),0.0);
            float3 Hh = normalize(L+Vv); float ndh=max(dot(N,Hh),0.0), vdh=max(dot(Vv,Hh),0.0);
            float atten = C.keyPos.w / (0.6 + 0.22*dist*dist);
            keyShadow = pcfShadow(smap, in.wp, C.lightMVP, ndl);
            float3 spec = D_GGX(ndh,m.rough*m.rough)*G_Smith(ndv,ndl,m.rough)*F_Schlick(vdh,f0) / (4*ndv*ndl+1e-4);
            col += (diffCol/3.14159265 + spec) * C.keyCol.rgb * (ndl*atten*keyShadow);
        }
        // fill light (no shadow, cool, diffuse-ish)
        {
            float3 Ld = C.fillPos.xyz - in.wp; float dist=length(Ld); float3 L=Ld/dist;
            float ndl=max(dot(N,L),0.0); float atten=C.fillPos.w/(0.5+dist*dist);
            float3 Hh=normalize(L+Vv); float ndh=max(dot(N,Hh),0.0), vdh=max(dot(Vv,Hh),0.0);
            float3 spec = D_GGX(ndh,m.rough*m.rough)*G_Smith(ndv,ndl,m.rough)*F_Schlick(vdh,f0)/(4*ndv*ndl+1e-4);
            col += (diffCol/3.14159265 + spec) * float3(0.55,0.62,0.80) * (ndl*atten);
        }
        // ambient with a crude cavity AO (crevices + floor contact from the noise)
        float ao = clamp(0.55 + 0.45*grime, 0.35, 1.0);
        col += C.ambient.rgb * m.albedo * ao;
        // ambient spec (env-ish) so metal isn't dead in shadow
        col += f0 * C.ambient.rgb * 2.2 * pow(1.0-ndv, 3.0) * (1.0-m.rough);

        // ── filmic grade (the "beauty proof" post, minus the grain) ──
        if(C.ambient.w > 0.5){
            col *= 0.9;
            float lum = dot(col, float3(0.299,0.587,0.114));
            col = mix(col*float3(0.84,0.96,1.16), col*float3(1.14,1.0,0.80), clamp(lum,0.0,1.0));  // teal shadows / amber lights
            col = (col*(2.51*col+0.03))/(col*(2.43*col+0.59)+0.14);   // ACES
            col = pow(clamp(col,0.0,1.0), float3(1.0/2.2));           // gamma
            float2 d = (in.clip.xy/float2(1280.0,800.0))*2.0-1.0; col *= 1.0 - 0.20*dot(d,d);  // vignette
        } else {
            col = pow(clamp(col,0.0,1.0), float3(1.0/2.2));
        }
        return float4(col, 1);
    }
    """
}
#endif
