// Citadel — textured-mesh creature renderer (dev/R&D path).
//
// Rasterises a rigless 3D creature mesh (Tripo-from-flux) into the live frame:
// the raymarch kernel draws the world + perpendicular depth, then this draws the
// mesh through a perspective camera that reproduces the kernel's ray model, lit
// per-pixel, and composites into the framebuffer with depth occlusion (writing
// her perp-depth back so particles occlude against her).
//
// ANIMATION without a rig: the mesh has no skeleton (Tripo auto-rig fails on the
// tentacle anatomy), so we deform it PROCEDURALLY BY REGION in the vertex shader,
// weighting vertices by their local height (Z, base 0 → crown ~1):
//   • head/crown — rotates around a neck pivot: yaw (±100°) + pitch TRACK the
//     player; the BODY stays planted (fixed facing = into the room).
//   • torso/ova  — breathing swell.
//   • tentacles  — travelling undulation.
//   • arms       — gentle sway.
//   • DEATH      — a death amount (0→1) slumps + topples her forward, droops the
//     head, fades the tracking, extinguishes the ova and chars the albedo. She
//     stays the SAME mesh through death (no pop to an SDF corpse).
//
// Body facing is captured on first draw as the most-OPEN direction from her cell
// (into the room / toward the entrance), not toward a wall.
//
// Live-tunable defaults (read each draw): MeshQueenHeight, MeshQueenLight,
// MeshQueenAnimSpeed, MeshQueenFront0.
//
// Gated by FeatureFlags.meshQueen; asset in Resources/queen.usdz (+ _basecolor).

import Foundation
import Metal
import MetalKit
import ModelIO
import simd

final class MeshCreature {

    private static let shaderSrc = """
    #include <metal_stdlib>
    using namespace metal;
    struct Cam {
        float4x4 model;
        float4x4 mvp;
        float4 eye;         // eye.xyz
        float4 fwd;         // fwd.xyz (unit)
        float4 sector;      // sector light rgb
        float4 anim;        // headYaw, headPitch, breathe, swayPhase
        float4 misc;        // localHeight, tentAmp, armAmp, 0
        float4 tune;        // lightGain, death, 0, 0
    };
    struct VIn  { float3 pos [[attribute(0)]]; float3 nrm [[attribute(1)]]; float2 uv [[attribute(2)]]; };
    struct VOut { float4 clip [[position]]; float3 wpos; float3 wnrm; float2 uv; float fdepth; };

    static inline float3 rotZ(float3 p, float a) { float c = cos(a), s = sin(a); return float3(c*p.x - s*p.y, s*p.x + c*p.y, p.z); }
    static inline float3 rotX(float3 p, float a) { float c = cos(a), s = sin(a); return float3(p.x, c*p.y - s*p.z, s*p.y + c*p.z); }

    vertex VOut vmain(VIn in [[stage_in]], constant Cam& C [[buffer(1)]]) {
        float3 lp = in.pos;
        float3 nrm = in.nrm;
        float H = C.misc.x;
        float Zn = lp.z / max(H, 1e-4);
        float dth = C.tune.y;

        // head: yaw + pitch around a neck pivot; fades out + droops as she dies
        float headW = smoothstep(0.60, 0.80, Zn);
        if (headW > 0.001) {
            float3 pivot = float3(0.0, 0.0, 0.62 * H);
            float hy = headW * C.anim.x * (1.0 - dth);
            float hp = headW * (C.anim.y * (1.0 - dth) - 0.55 * dth);
            float3 rel = lp - pivot;
            rel = rotX(rotZ(rel, hy), hp);
            lp = pivot + rel;
            nrm = rotX(rotZ(nrm, hy), hp);
        }
        // torso breathing
        float torsoW = smoothstep(0.28, 0.44, Zn) * (1.0 - smoothstep(0.58, 0.72, Zn));
        lp.xy *= (1.0 + torsoW * C.anim.z);
        // tentacle undulation
        float tentW = 1.0 - smoothstep(0.0, 0.34, Zn);
        if (tentW > 0.001) {
            float pa = atan2(lp.y, lp.x);
            float ph = C.anim.w + lp.z * 9.0 + pa * 2.0;
            lp.x += tentW * C.misc.y * sin(ph);
            lp.y += tentW * C.misc.y * cos(ph * 0.9);
        }
        // arm sway
        float armW = smoothstep(0.46, 0.58, Zn) * (1.0 - smoothstep(0.74, 0.84, Zn)) * smoothstep(0.24, 0.40, abs(lp.x));
        lp.x += armW * C.misc.z * sin(C.anim.w * 0.7);
        lp.z += armW * C.misc.z * 0.5 * sin(C.anim.w * 0.7 + 1.3);

        // death: slump + topple forward about the base
        if (dth > 0.001) {
            lp.z *= (1.0 - 0.4 * dth);
            float tp = dth * 1.15;
            float c = cos(tp), s = sin(tp);
            lp  = float3(lp.x,  c*lp.y  - s*lp.z,  s*lp.y  + c*lp.z);
            nrm = float3(nrm.x, c*nrm.y - s*nrm.z, s*nrm.y + c*nrm.z);
        }
        // ash: charred remains crumble INWARD + DOWN into a compact 3-D dust mound
        // (not a flat splat) — gather every vertex toward a small low dome, with a
        // per-vertex grit jitter so it reads as dust + debris, not a smooth blob.
        float ash = C.tune.w;                    // 0→1 collapse to a mound · 1→2 tread flat
        if (ash > 0.001) {
            float mound = min(ash, 1.0);
            float flat = clamp(ash - 1.0, 0.0, 1.0);
            float r = length(lp.xy);
            float2 dir = r > 1e-4 ? lp.xy / r : float2(1.0, 0.0);
            float heapR = 0.30;
            float grit = fract(sin(dot(in.pos.xy, float2(91.7, 47.3))) * 4137.1);
            float tr = min(r, heapR) * 0.6;                       // pull the footprint in tight
            float td = clamp(1.0 - tr / heapR, 0.0, 1.0);          // 1 centre → 0 rim
            float2 targetXY = dir * tr + (grit - 0.5) * 0.05;      // scatter debris a touch
            float targetZ = 0.22 * td * td + grit * 0.07;          // low dome + grainy top
            lp.xy = mix(lp.xy, targetXY, mound);
            lp.z  = mix(lp.z, targetZ, mound);
            // trodden ON the mound → kicked flat, spread into a low dust smear
            lp.z  *= (1.0 - 0.82 * flat);
            lp.xy *= (1.0 + 1.3 * flat);
        }

        float4 lpp = float4(lp, 1.0);
        float4 wp = C.model * lpp;
        VOut o;
        o.clip = C.mvp * lpp;
        float3x3 nm = float3x3(C.model[0].xyz, C.model[1].xyz, C.model[2].xyz);
        o.wnrm = normalize(nm * nrm);
        o.wpos = wp.xyz;
        o.uv = in.uv;
        o.fdepth = dot(wp.xyz - C.eye.xyz, C.fwd.xyz);
        return o;
    }

    struct FOut { float4 color [[color(0)]]; float depth [[color(1)]]; };
    fragment FOut fmain(VOut in [[stage_in]],
                        texture2d<float> albedo [[texture(0)]],
                        constant Cam& C [[buffer(1)]]) {
        constexpr sampler s(filter::linear, address::repeat);
        float3 alb = albedo.sample(s, in.uv).rgb;
        float3 N = normalize(in.wnrm);
        float3 toEye = C.eye.xyz - in.wpos;
        float dist = length(toEye);
        float3 Ld = toEye / max(dist, 1e-3);
        float g = C.tune.x;                       // light gain
        float cosA = dot(-Ld, C.fwd.xyz);
        float cone = smoothstep(0.34, 0.92, cosA);
        float distF = max(0.0, 1.0 - dist / 13.0); distF *= distF;
        float ndl = max(0.0, dot(N, Ld));
        float3 lamp = float3(0.78, 0.85, 1.0) * (cone * distF * (0.4 + 0.6 * ndl) * 2.6 * g);
        float3 amb = float3(0.20, 0.22, 0.28) * ((0.5 + 0.5 * N.y) * g);
        float3 sector = C.sector.rgb * 0.5;
        float death = C.tune.y;
        float warm = max(0.0, alb.r - alb.b);
        float val = max(alb.r, max(alb.g, alb.b));
        float emis = smoothstep(0.22, 0.55, warm) * smoothstep(0.4, 0.8, val) * (1.0 - death);
        float3 col = alb * (amb + lamp + sector) + alb * emis * float3(1.0, 0.55, 0.22) * 1.3;
        col *= (1.0 - 0.4 * death);               // darken as she dies
        float burn = C.tune.z;                    // charred remains: kill the glow, desaturate to ash
        if (burn > 0.001) {
            float lum = dot(col, float3(0.299, 0.587, 0.114));
            float3 charCol = float3(lum) * float3(0.42, 0.40, 0.38);
            col = mix(col, charCol, burn);
        }
        float ash = C.tune.w;                     // crumbled remains → grainy dust + debris
        if (ash > 0.001) {
            float g = fract(sin(dot(floor(in.uv * 240.0), float2(12.9898, 78.233))) * 43758.5);
            float3 dust = mix(float3(0.12, 0.11, 0.10), float3(0.34, 0.32, 0.29), g);  // dark debris flecks ↔ pale dust
            col = mix(col, dust, min(1.0, ash));
            col *= (1.0 - 0.4 * clamp(ash - 1.0, 0.0, 1.0));   // flattened smear thins/dims
        }
        FOut o; o.color = float4(col, 1.0); o.depth = in.fdepth; return o;
    }
    """

    private struct Cam {
        var model: simd_float4x4
        var mvp: simd_float4x4
        var eye: SIMD4<Float>
        var fwd: SIMD4<Float>
        var sector: SIMD4<Float>
        var anim: SIMD4<Float>
        var misc: SIMD4<Float>
        var tune: SIMD4<Float>
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipe: MTLRenderPipelineState
    private let dss: MTLDepthStencilState
    private let mtk: MTKMesh
    private let albedo: MTLTexture?
    private let colTex, depTex, zTex: MTLTexture
    private let W: Int, H: Int
    let localHeight: Float
    let front0: Float
    private var mcol: [UInt32]
    private var mdep: [Float]
    /// Fixed body facing per queen (world angle), captured on first draw, keyed by
    /// quantised spawn position (she's rooted, so position is a stable identity).
    private var bodyYaw: [Int: Float] = [:]
    /// Eased head yaw/pitch per queen so the head visibly LAGS toward the player
    /// (instant tracking reads as "locked on", not "turning").
    private var headState: [Int: (yaw: Float, pitch: Float, t: Float)] = [:]

    init?(device: MTLDevice) {
        self.device = device
        guard let q = device.makeCommandQueue() else { return nil }
        self.queue = q
        let vw = RenderConfig.width, vh = RenderConfig.viewHeight
        self.W = vw; self.H = vh

        guard let meshURL = Bundle.main.url(forResource: "queen", withExtension: "usdz") else { return nil }
        let texURL = Bundle.main.url(forResource: "queen_basecolor", withExtension: "jpg")

        let allocator = MTKMeshBufferAllocator(device: device)
        let vdesc = MDLVertexDescriptor()
        vdesc.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        vdesc.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0)
        vdesc.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: 24, bufferIndex: 0)
        (vdesc.layouts[0] as? MDLVertexBufferLayout)?.stride = 32
        let asset = MDLAsset(url: meshURL, vertexDescriptor: nil, bufferAllocator: allocator)
        guard let mdl = asset.childObjects(of: MDLMesh.self).first as? MDLMesh else { return nil }
        let bb = mdl.boundingBox
        self.localHeight = max(0.001, bb.maxBounds.z - bb.minBounds.z)
        mdl.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.4)
        mdl.vertexDescriptor = vdesc
        guard let m = try? MTKMesh(mesh: mdl, device: device) else { return nil }
        self.mtk = m

        if let texURL {
            self.albedo = try? MTKTextureLoader(device: device).newTexture(
                URL: texURL, options: [.SRGB: true, .generateMipmaps: true,
                                       .origin: MTKTextureLoader.Origin.flippedVertically])
        } else { self.albedo = nil }

        guard let lib = try? device.makeLibrary(source: Self.shaderSrc, options: nil) else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "vmain")
        pd.fragmentFunction = lib.makeFunction(name: "fmain")
        pd.vertexDescriptor = MTKMetalVertexDescriptorFromModelIO(vdesc)
        pd.colorAttachments[0].pixelFormat = .rgba8Unorm
        pd.colorAttachments[1].pixelFormat = .r32Float
        pd.depthAttachmentPixelFormat = .depth32Float
        guard let ps = try? device.makeRenderPipelineState(descriptor: pd) else { return nil }
        self.pipe = ps
        let d = MTLDepthStencilDescriptor(); d.depthCompareFunction = .less; d.isDepthWriteEnabled = true
        self.dss = device.makeDepthStencilState(descriptor: d)!

        func mk(_ f: MTLPixelFormat, _ store: MTLStorageMode) -> MTLTexture {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: vw, height: vh, mipmapped: false)
            td.storageMode = store; td.usage = [.renderTarget]; return device.makeTexture(descriptor: td)!
        }
        self.colTex = mk(.rgba8Unorm, .shared)
        self.depTex = mk(.r32Float, .shared)
        self.zTex = mk(.depth32Float, .private)
        self.mcol = [UInt32](repeating: 0, count: vw * vh)
        self.mdep = [Float](repeating: 0, count: vw * vh)

        let baked: Float = 1.5707963
        if let v = UserDefaults.standard.object(forKey: "MeshQueenFront0") as? Double { self.front0 = Float(v) }
        else { self.front0 = baked }

        warm()
    }

    private func warm() {
        var cam = Cam(model: matrix_identity_float4x4, mvp: matrix_identity_float4x4,
                      eye: .zero, fwd: SIMD4(0, 0, 1, 0), sector: .zero,
                      anim: .zero, misc: SIMD4(localHeight, 0, 0, 0), tune: SIMD4(1, 0, 0, 0))
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = colTex; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .dontCare
        rp.colorAttachments[1].texture = depTex; rp.colorAttachments[1].loadAction = .clear; rp.colorAttachments[1].storeAction = .dontCare
        rp.depthAttachment.texture = zTex; rp.depthAttachment.loadAction = .clear; rp.depthAttachment.storeAction = .dontCare
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(pipe); enc.setDepthStencilState(dss); enc.setCullMode(.none)
        enc.setVertexBytes(&cam, length: MemoryLayout<Cam>.stride, index: 1)
        enc.setFragmentBytes(&cam, length: MemoryLayout<Cam>.stride, index: 1)
        enc.setFragmentTexture(albedo, index: 0)
        for (i, vb) in mtk.vertexBuffers.enumerated() { enc.setVertexBuffer(vb.buffer, offset: vb.offset, index: i) }
        for sm in mtk.submeshes {
            enc.drawIndexedPrimitives(type: sm.primitiveType, indexCount: sm.indexCount,
                                      indexType: sm.indexType, indexBuffer: sm.indexBuffer.buffer, indexBufferOffset: sm.indexBuffer.offset)
        }
        enc.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
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
    private static func view(_ eye: SIMD3<Float>, _ right: SIMD3<Float>, _ up: SIMD3<Float>, _ fwd: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(SIMD4(right.x, up.x, fwd.x, 0),
                      SIMD4(right.y, up.y, fwd.y, 0),
                      SIMD4(right.z, up.z, fwd.z, 0),
                      SIMD4(-dot(right, eye), -dot(up, eye), -dot(fwd, eye), 1))
    }
    private static func proj(plane: Float, horizon: Float, W: Float, H: Float, near: Float, far: Float) -> simd_float4x4 {
        let a = far / (far - near), b = -far * near / (far - near)
        return simd_float4x4(SIMD4(1 / plane, 0, 0, 0),
                             SIMD4(0, W / H, 0, 0),
                             SIMD4(0, 1 - 2 * horizon / H, a, 1),
                             SIMD4(0, 0, b, 0))
    }
    @inline(__always) private static func wrapPi(_ d: Float) -> Float { atan2(sin(d), cos(d)) }
    @inline(__always) private static func f(_ key: String, _ def: Float) -> Float {
        (UserDefaults.standard.object(forKey: key) as? Double).map { Float($0) } ?? def
    }

    /// Body facing (world angle) for a queen at `pos`: toward the CENTROID of nearby
    /// open cells — i.e. into the room's bulk (where the player roams), never a wall.
    /// Falls back to the most-open ray if the centroid is degenerate (she's centred).
    private static func openFacing(_ map: GameMap, _ pos: SIMD2<Float>) -> Float {
        let px = Int(pos.x), py = Int(pos.y), R = 9
        var cx: Float = 0, cy: Float = 0, n: Float = 0
        for dy in -R...R { for dx in -R...R {
            let xi = px + dx, yi = py + dy
            if map.inBounds(xi, yi) && map.wallAt(xi, yi) == 0 {
                cx += Float(xi) + 0.5; cy += Float(yi) + 0.5; n += 1
            }
        } }
        if n > 0 {
            let dx = cx / n - pos.x, dy = cy / n - pos.y
            if dx * dx + dy * dy > 0.25 { return atan2(dy, dx) }   // ≥0.5 cell off-centre → face the bulk
        }
        var bestA: Float = 0, bestClear: Float = -1
        for k in 0..<32 {
            let aa = Float(k) / 32 * 2 * .pi
            let dd = SIMD2<Float>(cos(aa), sin(aa))
            var clear: Float = 0, step: Float = 0.5
            while step < 22 {
                let s = pos + dd * step
                if !map.inBounds(Int(s.x), Int(s.y)) || map.wallAt(Int(s.x), Int(s.y)) != 0 { break }
                clear = step; step += 0.5
            }
            if clear > bestClear { bestClear = clear; bestA = aa }
        }
        return bestA
    }

    /// Draw the creature at `pos` (world x,z; base on the floor). Body faces into the
    /// room (fixed); the head tracks `faceTarget`. `time` drives breathing/sway;
    /// `death` (0…1) slumps/topples/extinguishes her. Live-tunable via defaults.
    func composite(into canvas: Canvas2D, depth: UnsafeMutablePointer<Float>,
                   eye: SIMD3<Float>, dir: Float, pos: SIMD2<Float>,
                   faceTarget: SIMD2<Float>, sector: SIMD3<Float>, time: Float,
                   map: GameMap, death: Float, burn: Float, ashed: Float) {
        let height = Self.f("MeshQueenHeight", 1.0)
        let lightGain = Self.f("MeshQueenLight", 1.75)
        let animSpeed = Self.f("MeshQueenAnimSpeed", 1.4)
        let deathC = max(0, min(1, death))
        let aliveF = 1 - deathC                    // freezes breathing/sway once she's down

        let fwd = SIMD3<Float>(cos(dir), 0, sin(dir))
        let right = SIMD3<Float>(-sin(dir), 0, cos(dir))
        let up = SIMD3<Float>(0, 1, 0)

        // fixed body facing = the open room direction (captured once); head tracks
        let key = Int((pos.x * 8).rounded()) &* 65_536 &+ Int((pos.y * 8).rounded())
        let body = bodyYaw[key] ?? { let a = Self.openFacing(map, pos); bodyYaw[key] = a; return a }()
        let toPlayer = atan2(faceTarget.y - pos.y, faceTarget.x - pos.x)
        let trackYaw = max(-1.745, min(1.745, Self.wrapPi(body - toPlayer)))   // negated: head was tracking the wrong way
        let headWorldY = height * 0.86
        let horiz = max(0.4, simd_length(faceTarget - pos))
        let targetPitch = max(-0.45, min(0.45, atan2(eye.y - headWorldY, horiz)))
        // eased tracking — the head LAGS toward the target so you SEE it swing to
        // follow you (instant tracking reads as locked-on / not moving)
        var hs = headState[key] ?? (yaw: trackYaw, pitch: targetPitch, t: time)
        let dtt = max(0, min(0.2, time - hs.t))
        let kl = 1 - exp(-dtt * 7.0)
        hs.yaw += Self.wrapPi(trackYaw - hs.yaw) * kl
        hs.pitch += (targetPitch - hs.pitch) * kl
        hs.t = time
        headState[key] = hs
        let headYaw = (UserDefaults.standard.object(forKey: "MeshQueenHeadYaw") as? Double).map { Float($0) } ?? hs.yaw
        let headPitch = hs.pitch
        let breathe = 0.05 * sin(time * 1.6 * animSpeed) * aliveF
        let sway = time * 1.1 * animSpeed

        let scale = height / localHeight
        let model = Self.T(pos.x, 0, pos.y) * Self.Ry(front0 - body) * Self.S(scale) * Self.Rx(-Float.pi / 2)
        let V = Self.view(eye, right, up, fwd)
        let P = Self.proj(plane: RenderConfig.cameraPlane, horizon: Float(RenderConfig.horizon),
                          W: Float(W), H: Float(H), near: 0.05, far: 64)
        let mvp = P * V * model
        var cam = Cam(model: model, mvp: mvp,
                      eye: SIMD4(eye, 0), fwd: SIMD4(fwd, 0), sector: SIMD4(sector, 0),
                      anim: SIMD4(headYaw, headPitch, breathe, sway),
                      misc: SIMD4(localHeight, 0.03 * aliveF, 0.02 * aliveF, 0),
                      tune: SIMD4(lightGain, deathC, max(0, min(1, burn)), max(0, min(2, ashed))))

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

        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
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

        mcol.withUnsafeMutableBytes { colTex.getBytes($0.baseAddress!, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0) }
        mdep.withUnsafeMutableBytes { depTex.getBytes($0.baseAddress!, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0) }

        let fb = canvas.framebuffer
        for i in 0..<W * H {
            if alphaOf(mcol[i]) > 2 && mdep[i] < depth[i] {
                fb[i] = mcol[i] | 0xFF00_0000
                depth[i] = mdep[i]
            }
        }
    }
}
