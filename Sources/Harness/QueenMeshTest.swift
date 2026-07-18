// Citadel — QUEEN 3D-MESH look-test (CITADEL_QUEENMESH). Dev-only R&D.
//
// The next question after "can we get a mesh": does a real 3D model of the queen
// sit convincingly in Citadel's OWN lighting? We render the actual lair through
// the raymarch kernel (framebuffer + perpendicular depth), then rasterise the
// Tripo mesh into the same frame through a matching pinhole camera, lit per-pixel
// by a headlamp + ambient + sector tint (the thing billboards can't do — light
// rakes across her form), and depth-composite against the lair. Not shipped.
//
// The raster camera reproduces the kernel's ray model exactly:
//   cameraX = 2*(x+0.5)/W - 1 ;  vcomp = (horizon-(y+0.5))/(0.5*W)
//   rd = fwd + right*cameraX + up*vcomp ;  perp-depth = t*dot(rd,fwd)
// so the mesh lines up with the walls and the depth test is valid.

import Foundation
import Cocoa
import simd
import Metal
import MetalKit
import ModelIO

enum QueenMeshTest {

    private static let shaderSrc = """
    #include <metal_stdlib>
    using namespace metal;
    struct Cam {
        float4x4 model;
        float4 eyePlane;    // eye.xyz, cameraPlane
        float4 fwdHor;      // fwd.xyz (unit), horizon
        float4 rightSW;     // right_hat.xyz (unit), screenW
        float4 upVH;        // up.xyz (unit), viewH
        float4 nearFar;     // near, far, 0, 0
        float4 sector;      // sector light rgb, 0
    };
    struct VIn  { float3 pos [[attribute(0)]]; float3 nrm [[attribute(1)]]; float2 uv [[attribute(2)]]; };
    struct VOut { float4 clip [[position]]; float3 wpos; float3 wnrm; float2 uv; float fdepth; };

    vertex VOut vmain(VIn in [[stage_in]], constant Cam& C [[buffer(1)]]) {
        float4 wp = C.model * float4(in.pos, 1.0);
        float3 rel = wp.xyz - C.eyePlane.xyz;
        float f = dot(rel, C.fwdHor.xyz);
        float rightC = dot(rel, C.rightSW.xyz);
        float upC = dot(rel, C.upVH.xyz);
        float ff = max(f, 1e-3);
        float cameraX = rightC / (ff * C.eyePlane.w);
        float vcomp = upC / ff;
        float screenW = C.rightSW.w, viewH = C.upVH.w, horizon = C.fwdHor.w;
        float px = (cameraX + 1.0) * 0.5 * screenW - 0.5;
        float py = horizon - vcomp * 0.5 * screenW - 0.5;
        float ndcX = (px + 0.5) / screenW * 2.0 - 1.0;
        float ndcY = 1.0 - (py + 0.5) / viewH * 2.0;
        float zN = (f - C.nearFar.x) / (C.nearFar.y - C.nearFar.x);
        VOut o;
        o.clip = float4(ndcX * f, ndcY * f, zN * f, f);
        float3x3 nm = float3x3(C.model[0].xyz, C.model[1].xyz, C.model[2].xyz);
        o.wnrm = normalize(nm * in.nrm);
        o.wpos = wp.xyz; o.uv = in.uv; o.fdepth = f;
        return o;
    }

    struct FOut { float4 color [[color(0)]]; float depth [[color(1)]]; };
    fragment FOut fmain(VOut in [[stage_in]],
                        texture2d<float> albedo [[texture(0)]],
                        constant Cam& C [[buffer(1)]]) {
        constexpr sampler s(filter::linear, address::repeat);
        float3 alb = albedo.sample(s, in.uv).rgb;
        float3 N = normalize(in.wnrm);
        float3 toEye = C.eyePlane.xyz - in.wpos;
        float dist = length(toEye);
        float3 Ld = toEye / max(dist, 1e-3);
        // headlamp: a forward cone from the eye, per-pixel N·L (the 3-D win)
        float cosA = dot(-Ld, C.fwdHor.xyz);
        float cone = smoothstep(0.34, 0.92, cosA);
        float distF = max(0.0, 1.0 - dist / 13.0); distF *= distF;
        float ndl = max(0.0, dot(N, Ld));
        float3 lamp = float3(0.78, 0.85, 1.0) * (cone * distF * (0.4 + 0.6 * ndl) * 2.6);
        float3 amb = float3(0.17, 0.19, 0.25) * (0.5 + 0.5 * N.y);
        float3 sector = C.sector.rgb * 0.5;
        // warm emissive from bright-warm albedo (the ova)
        float warm = max(0.0, alb.r - alb.b);
        float val = max(alb.r, max(alb.g, alb.b));
        float emis = smoothstep(0.22, 0.55, warm) * smoothstep(0.4, 0.8, val);
        float3 col = alb * (amb + lamp + sector) + alb * emis * float3(1.0, 0.55, 0.22) * 1.3;
        FOut o; o.color = float4(col, 1.0); o.depth = in.fdepth; return o;
    }
    """

    struct Cam {
        var model: simd_float4x4
        var eyePlane: SIMD4<Float>
        var fwdHor: SIMD4<Float>
        var rightSW: SIMD4<Float>
        var upVH: SIMD4<Float>
        var nearFar: SIMD4<Float>
        var sector: SIMD4<Float>
    }

    private static func T(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4; m.columns.3 = SIMD4(x, y, z, 1); return m
    }
    private static func S(_ s: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4; m.columns.0.x = s; m.columns.1.y = s; m.columns.2.z = s; return m
    }
    private static func Rx(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1))
    }
    private static func Ry(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1))
    }

    static func run(meshPath: String?, outDir: String?) {
        guard let device = MTLCreateSystemDefaultDevice() else { print("Citadel: no Metal device"); return }
        let mesh = meshPath ?? (NSHomeDirectory() + "/Desktop/Citadel-QueenMock/demonic+creature+3d+model.usdz")
        let texPath = NSHomeDirectory() + "/Desktop/Citadel-QueenMock/_tex/textures/demonic_creature_3d_model_basecolor.JPEG"
        let dir = URL(fileURLWithPath: outDir ?? NSHomeDirectory() + "/Desktop/Citadel-QueenMock")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // ── load the mesh (add normals, force a known interleaved layout) ─────────
        let allocator = MTKMeshBufferAllocator(device: device)
        let vdesc = MDLVertexDescriptor()
        vdesc.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        vdesc.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0)
        vdesc.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: 24, bufferIndex: 0)
        (vdesc.layouts[0] as? MDLVertexBufferLayout)?.stride = 32
        let asset = MDLAsset(url: URL(fileURLWithPath: mesh), vertexDescriptor: nil, bufferAllocator: allocator)
        guard let mdl = asset.childObjects(of: MDLMesh.self).first as? MDLMesh else { print("Citadel: no MDLMesh in \(mesh)"); return }
        mdl.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.4)
        mdl.vertexDescriptor = vdesc
        guard let mtk = try? MTKMesh(mesh: mdl, device: device) else { print("Citadel: MTKMesh build failed"); return }

        let loader = MTKTextureLoader(device: device)
        let albedo = try? loader.newTexture(URL: URL(fileURLWithPath: texPath),
                                            options: [.SRGB: true, .generateMipmaps: true, .origin: MTKTextureLoader.Origin.flippedVertically])

        // ── render pipeline ──────────────────────────────────────────────────────
        guard let lib = try? device.makeLibrary(source: shaderSrc, options: nil) else { print("Citadel: mesh shader compile failed"); return }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "vmain")
        pd.fragmentFunction = lib.makeFunction(name: "fmain")
        pd.vertexDescriptor = MTKMetalVertexDescriptorFromModelIO(vdesc)
        pd.colorAttachments[0].pixelFormat = .rgba8Unorm
        pd.colorAttachments[1].pixelFormat = .r32Float
        pd.depthAttachmentPixelFormat = .depth32Float
        guard let pipe = try? device.makeRenderPipelineState(descriptor: pd) else { print("Citadel: mesh pipeline failed"); return }
        let dsd = MTLDepthStencilDescriptor(); dsd.depthCompareFunction = .less; dsd.isDepthWriteEnabled = true
        let dss = device.makeDepthStencilState(descriptor: dsd)!

        // ── the lair (env + perp-depth) from the existing mock scaffolding ────────
        guard let plate = QueenMock.renderLair(level: 8) else { print("Citadel: lair render failed"); return }
        let W = plate.W, H = plate.H
        let queue = device.makeCommandQueue()!

        // targets
        func tex(_ fmt: MTLPixelFormat, _ store: MTLStorageMode, _ usage: MTLTextureUsage) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: W, height: H, mipmapped: false)
            d.storageMode = store; d.usage = usage; return device.makeTexture(descriptor: d)!
        }
        let colTex = tex(.rgba8Unorm, .shared, [.renderTarget])
        let depTex = tex(.r32Float, .shared, [.renderTarget])
        let zTex = tex(.depth32Float, .private, [.renderTarget])

        // camera basis (matches renderLair's Uniforms exactly)
        let camPos = plate.camPos, camDir = plate.camDir
        print("  QMESH camDir=\(camDir)  FRONT0(camDir+pi/2)=\(camDir + Float.pi / 2)")
        let plane = RenderConfig.cameraPlane
        let fwd = SIMD3<Float>(cos(camDir), 0, sin(camDir))
        let rightHat = SIMD3<Float>(-sin(camDir), 0, cos(camDir))
        let up = SIMD3<Float>(0, 1, 0)
        let eye = SIMD3<Float>(camPos.x, 0.5, camPos.y)

        // place her down the corridor, standing on the floor, facing the camera
        let fwd2 = SIMD2<Float>(cos(camDir), sin(camDir))
        let qpos = camPos + fwd2 * 4.2
        let height: Float = 2.7                                   // world units tall (ceilH is 3.2)
        let scale = height / 0.99                                 // her mesh is ~0.99 tall in local Z
        let sector = WorldLight.lightAt(plate.world.map, qpos.x, qpos.y)

        func render(_ name: String, yaw: Float) {
            let model = T(qpos.x, 0, qpos.y) * Ry(yaw) * S(scale) * Rx(-Float.pi / 2)   // Z-up→Y-up, scaled, placed
            var cam = Cam(model: model,
                          eyePlane: SIMD4(eye.x, eye.y, eye.z, plane),
                          fwdHor: SIMD4(fwd.x, fwd.y, fwd.z, Float(RenderConfig.horizon)),
                          rightSW: SIMD4(rightHat.x, rightHat.y, rightHat.z, Float(W)),
                          upVH: SIMD4(up.x, up.y, up.z, Float(H)),
                          nearFar: SIMD4(0.02, 64, 0, 0),
                          sector: SIMD4(sector.x, sector.y, sector.z, 0))

            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = colTex
            rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            rp.colorAttachments[1].texture = depTex
            rp.colorAttachments[1].loadAction = .clear; rp.colorAttachments[1].storeAction = .store
            rp.colorAttachments[1].clearColor = MTLClearColor(red: 1e9, green: 0, blue: 0, alpha: 0)
            rp.depthAttachment.texture = zTex
            rp.depthAttachment.loadAction = .clear; rp.depthAttachment.storeAction = .dontCare
            rp.depthAttachment.clearDepth = 1.0

            let cmd = queue.makeCommandBuffer()!
            let enc = cmd.makeRenderCommandEncoder(descriptor: rp)!
            enc.setRenderPipelineState(pipe)
            enc.setDepthStencilState(dss)
            enc.setCullMode(.none)
            enc.setVertexBytes(&cam, length: MemoryLayout<Cam>.stride, index: 1)
            enc.setFragmentBytes(&cam, length: MemoryLayout<Cam>.stride, index: 1)
            enc.setFragmentTexture(albedo, index: 0)
            for (i, vb) in mtk.vertexBuffers.enumerated() { enc.setVertexBuffer(vb.buffer, offset: vb.offset, index: i) }
            for sm in mtk.submeshes {
                enc.drawIndexedPrimitives(type: sm.primitiveType, indexCount: sm.indexCount,
                                          indexType: sm.indexType, indexBuffer: sm.indexBuffer.buffer,
                                          indexBufferOffset: sm.indexBuffer.offset)
            }
            enc.endEncoding()
            cmd.commit(); cmd.waitUntilCompleted()

            // read back + composite over the lair with perp-depth occlusion
            var mcol = [UInt32](repeating: 0, count: W * H)
            mcol.withUnsafeMutableBytes { colTex.getBytes($0.baseAddress!, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0) }
            var mdep = [Float](repeating: 0, count: W * H)
            mdep.withUnsafeMutableBytes { depTex.getBytes($0.baseAddress!, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0) }

            var fb = plate.fb
            for i in 0..<W * H {
                if alphaOf(mcol[i]) > 2 && mdep[i] < plate.depth[i] { fb[i] = mcol[i] | 0xFF00_0000 }
            }
            QueenMock.writeFB(fb, W, H, to: dir.appendingPathComponent(name))
            print("  wrote \(name)")
        }

        // a few yaws so we can pick the facing that reads best
        render("mesh-lair-a.png", yaw: 0)
        render("mesh-lair-b.png", yaw: Float.pi)
        render("mesh-lair-c.png", yaw: Float.pi * 0.5)
        render("mesh-lair-d.png", yaw: -Float.pi * 0.5)
        print("Citadel: queen MESH look-test — wrote 4 facings to \(dir.path)")
    }

    /// Drive the REAL live renderer (GPUWorldRenderer + the mesh hook) headlessly:
    /// spawn a level, teleport the player in front of its queen, render one frame,
    /// dump it. Proves the in-game wire-in (SDF-queen exclusion + mesh composite).
    static func verifyLive(outDir: String?) {
        guard let device = MTLCreateSystemDefaultDevice() else { print("Citadel: no Metal device"); return }
        let dir = URL(fileURLWithPath: outDir ?? NSHomeDirectory() + "/Desktop/Citadel-QueenMock")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let world = World(level: 8, colonyIndex: 7, seed: 8080)
        guard let queen = world.monsters.first(where: { $0.kind == .queen }) else { print("Citadel: no queen on level"); return }
        let qpos = queen.pos, map = world.map
        func open(_ p: SIMD2<Float>) -> Bool { map.wallAt(Int(p.x), Int(p.y)) == 0 }
        // find an open standpoint with a clear line to her
        var stand = qpos + SIMD2<Float>(2, 0), ang: Float = 0, found = false
        for k in 0..<24 where !found {
            let a = Float(k) / 24 * 2 * .pi, d = SIMD2<Float>(cos(a), sin(a))
            for r: Float in [3.0, 3.5, 4.0, 4.5, 5.0] {
                let sp = qpos + d * r
                if !open(sp) { continue }
                var clear = true
                let steps = max(2, Int(r * 4))
                for s in 1...steps { if !open(qpos + d * (r * Float(s) / Float(steps))) { clear = false; break } }
                if clear { stand = sp; ang = a; found = true; break }
            }
        }
        // find an open standpoint near a target angle around the queen (for the
        // head-tracking check: body faces the FIRST standpoint, head tracks later ones)
        func findOpen(near targetAng: Float) -> (SIMD2<Float>, Float)? {
            for dk in 0...9 { for sgn in [Float(1), -1] {
                let aa = targetAng + Float(dk) * 0.13 * sgn
                let dd = SIMD2<Float>(cos(aa), sin(aa))
                for r: Float in [2.0, 2.4, 2.8, 3.2] {
                    let sp = qpos + dd * r
                    if !open(sp) { continue }
                    var clear = true; let steps = max(2, Int(r * 4))
                    for s in 1...steps { if !open(qpos + dd * (r * Float(s) / Float(steps))) { clear = false; break } }
                    if clear { return (sp, aa) }
                }
            } }
            return nil
        }

        let canvas = Canvas2D()
        guard let gpu = GPUWorldRenderer(device: device) else { print("Citadel: no GPU renderer"); return }
        func shot(_ name: String, _ sp: SIMD2<Float>, _ faceAng: Float) {
            world.player.pos = sp
            world.player.dir = faceAng
            _ = gpu.render(world, into: canvas)
            Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.height, scale: 1,
                              to: dir.appendingPathComponent(name))
            print("  wrote \(name) (player \(sp))")
        }
        let d = SIMD2<Float>(cos(ang), sin(ang))
        // 1) front — establishes her fixed body facing (toward this standpoint)
        shot("mesh-live.png", stand, ang + .pi)
        // 2) side — player ~75° around; her BODY should stay put, HEAD should turn to face the player
        if let (sideSp, sideAng) = findOpen(near: ang + 1.3) {
            shot("mesh-live-side.png", sideSp, sideAng + .pi)
        }
        // 3) near-plane stress (old smear repro)
        shot("mesh-live-close.png", qpos + d * 0.7, ang + .pi)
        // 4) death: mid-topple, fully down, and burnt (charred — no glow)
        if let qi = world.monsters.firstIndex(where: { $0.kind == .queen }) {
            world.monsters[qi].state = .dying; world.monsters[qi].stateTime = 0.8
            shot("mesh-live-dying.png", stand, ang + .pi)
            world.monsters[qi].state = .dead
            shot("mesh-live-death.png", stand, ang + .pi)
            world.monsters[qi].burn = 1.0
            shot("mesh-live-burnt.png", stand, ang + .pi)
            world.monsters[qi].ashed = 1.0
            shot("mesh-live-ash.png", qpos + d * 1.9, ang + .pi)
            world.monsters[qi].ashed = 2.0
            shot("mesh-live-ashflat.png", qpos + d * 1.9, ang + .pi)
            world.monsters[qi].state = .idle; world.monsters[qi].burn = 0; world.monsters[qi].ashed = 0
        }
        // 5) head-deform test — force the head yaw left/right from a fixed FRONT camera
        let closeFront = qpos + d * 1.7
        UserDefaults.standard.set(-1.2, forKey: "MeshQueenHeadYaw"); shot("head-left.png", closeFront, ang + .pi)
        UserDefaults.standard.set(1.2, forKey: "MeshQueenHeadYaw"); shot("head-right.png", closeFront, ang + .pi)
        UserDefaults.standard.removeObject(forKey: "MeshQueenHeadYaw")
        print("Citadel: mesh live-verify — queen \(qpos) (found=\(found))")
    }
}
