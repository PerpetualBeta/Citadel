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
        float howl = smoothstep(0.03, 0.20, dth) * (1.0 - smoothstep(0.40, 0.62, dth));  // rapid death-throe thrash, before the slump

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
        // tentacle undulation — a gentle living sway; a RAPID thrash as she howls
        float tentW = 1.0 - smoothstep(0.0, 0.34, Zn);
        if (tentW > 0.001) {
            float pa = atan2(lp.y, lp.x);
            float ph  = C.anim.w + lp.z * 9.0 + pa * 2.0;      // slow, alive
            float phH = C.misc.w + lp.z * 9.0 + pa * 2.0;      // fast, howling (C.misc.w = rapid thrash phase)
            float ampH = 0.12 * howl;
            lp.x += tentW * (C.misc.y * sin(ph)       + ampH * sin(phH));
            lp.y += tentW * (C.misc.y * cos(ph * 0.9) + ampH * cos(phH * 0.9));
        }
        // arm sway — gentle alive; frantic thrash as she howls
        float armW = smoothstep(0.46, 0.58, Zn) * (1.0 - smoothstep(0.74, 0.84, Zn)) * smoothstep(0.24, 0.40, abs(lp.x));
        float armH = 0.14 * howl;
        lp.x += armW * (C.misc.z * sin(C.anim.w * 0.7)             + armH * sin(C.misc.w));
        lp.z += armW * (C.misc.z * 0.5 * sin(C.anim.w * 0.7 + 1.3) + armH * 0.6 * sin(C.misc.w * 1.1 + 1.3));

        // death: she HOWLS (limbs thrash, above) then SLUMPS — the upper body FOLDS
        // forward+down about a WAIST hinge. A hinge is a rotation, so the torso keeps
        // its volume (a vertical crush flattened her into a plane); the lower body +
        // tentacle skirt stay ROOTED to the floor, so she folds over in place. Gentler
        // than a full base-topple, which swung her hollow underside toward the camera
        // and let the player circle behind and see inside the mesh.
        if (dth > 0.001) {
            float slump = smoothstep(0.32, 1.0, dth);
            float waist = 0.40 * H;                              // hinge height
            if (lp.z > waist) {
                float fold = slump * 0.95;                       // bow angle (below the old 1.15 topple)
                float c = cos(fold), s = sin(fold);
                float3 rel = lp - float3(0.0, 0.0, waist);
                rel = float3(rel.x, c * rel.y - s * rel.z, s * rel.y + c * rel.z);   // tip forward + down
                lp  = float3(0.0, 0.0, waist) + rel;
                nrm = float3(nrm.x, c * nrm.y - s * nrm.z, s * nrm.y + c * nrm.z);
            }
            lp.z *= (1.0 - 0.10 * slump);                        // a slight overall settle onto the floor
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

    // ── DRONE — a low pack-hunter that PROWLS (rigless, region-weighted). Local
    // space is Z-up (pre-Rx): +x = nose/forward, −x = tail, ±y = lateral, +z = up.
    // anim.x = gait phase (distance-matched) · anim.y = locomotion 0..1 ·
    // anim.z = rear-up 0..1 · tune = (light, death, burn, ash).
    vertex VOut vmainDrone(VIn in [[stage_in]], constant Cam& C [[buffer(1)]]) {
        float3 lp = in.pos;
        float3 nrm = in.nrm;
        float H = C.misc.x;
        float Zn = lp.z / max(H, 1e-4);
        float gait = C.anim.x;
        float move = C.anim.y;
        float rear = C.anim.z;
        float dth = C.tune.y;
        float aliveF = 1.0 - smoothstep(0.0, 0.3, dth);
        float g = move * aliveF * (1.0 - rear);           // stride only while alive, moving, not reared

        // NARROW the stance — the raw mesh stands crab-wide; draw the feet toward the
        // centreline so it reads as a lean prowler, not a splay-legged crab.
        float footW = 1.0 - smoothstep(0.0, 0.32, Zn);
        lp.xy *= mix(1.0, 0.58, footW);

        // prowl gait — LEG-driven and low; no whole-body bounce
        float legW = 1.0 - smoothstep(0.12, 0.46, Zn);
        if (legW > 0.001) {
            float diag = (lp.x * lp.y > 0.0) ? 0.0 : 3.14159265;   // diagonal pairs, trot
            float ph = gait + diag;
            lp.x += legW * 0.10 * g * sin(ph);            // fore/aft reach (matches travel)
            lp.z += legW * 0.03 * g * max(0.0, sin(ph));  // a small lift on the forward swing
        }
        // body — a lateral weight-shift + only a whisper of vertical (NOT a bounce)
        float bodyW = smoothstep(0.20, 0.55, Zn);
        lp.y += bodyW * 0.035 * g * sin(gait);
        lp.z += bodyW * 0.010 * g * sin(gait * 2.0);
        // head — a small nod (nose +x, mid height)
        float headW = smoothstep(0.20, 0.45, lp.x) * smoothstep(0.20, 0.55, Zn);
        lp.z += headW * 0.02 * g * sin(gait * 2.0 + 1.4);
        // tail — the high arcing tail (the TOP of the mesh) lashes side to side, and
        // curls; it lives even at rest, so it's only lightly gated by movement.
        float tailW = smoothstep(0.52, 1.0, Zn);
        if (tailW > 0.001) {
            float ts = (0.35 + 0.65 * move) * aliveF;
            lp.y += tailW * 0.20 * ts * sin(gait * 0.9 + 0.6);
            lp.x += tailW * 0.06 * ts * sin(gait * 0.9 + 2.1);
        }

        // REAR UP — on the strike it pivots its front up onto the hind legs
        if (rear > 0.001) {
            float3 pivot = float3(-0.30, 0.0, 0.12 * H);      // the hind-leg line
            float a = rear * 1.15;                            // ~66° up
            float c = cos(a), s = sin(a);
            float3 rel = lp - pivot;
            rel = float3(c * rel.x - s * rel.z, rel.y, s * rel.x + c * rel.z);   // nose (+x) swings up (+z)
            lp = pivot + rel;
            nrm = float3(c * nrm.x - s * nrm.z, nrm.y, s * nrm.x + c * nrm.z);
        }

        // DEATH — it collapses onto the deck. The THIN legs (and the low snout) fold
        // flat beneath it — natural for a downed beast — while the upper body + tail
        // SINK with them keeping their full volume (a translate, not a crush). By
        // construction every vertex stays at or above the floor, so nothing merges into
        // it and nothing gets clamped flat. Head ends down, tail arcing up.
        if (dth > 0.001) {
            float slump = smoothstep(0.05, 1.0, dth);
            float seed = C.misc.y;                              // frozen per-corpse (0…1)
            float v1 = fract(seed + 0.13), v2 = fract(seed * 7.3 + 0.37);
            float legTop = 0.34 * H;
            float tailW = smoothstep(0.50, 1.0, Zn);                            // the high arcing tail
            float headW = smoothstep(0.20, 0.46, lp.x) * smoothstep(0.30, 0.75, Zn);  // the raised head

            // COLLAPSE IN PLACE — the beast crumples where it stood. Its FOOTPRINT and
            // CENTRE are untouched (no shrink, no roll, no lateral shift): the corpse stays
            // over m.pos so blood / flames / ash land ON it, and it reaches no further into
            // walls or furniture than the LIVE drone did (the wall-clip trims walls, as it
            // did before). The LEGS fold flat (scaled toward the deck) while the BODY + TAIL
            // DROP by a bounded translate — keeping their full 3-D thickness, so it's a
            // lower heap, never a flattened plane. The head and arcing tail loll the rest of
            // the way down. Per-corpse fold depth for variety; nothing crosses the floor.
            float fold = (0.62 + 0.26 * v2) * slump;
            if (lp.z < legTop) { lp.z *= (1.0 - fold); }       // legs splay flat to the deck
            else { lp.z -= legTop * fold; }                    // body + tail drop, keeping thickness
            lp.z -= tailW * (0.16 + 0.14 * v1) * H * slump;    // the arcing tail flops down onto the deck
            lp.z -= headW * (0.12 + 0.14 * v1) * H * slump;    // the head lolls down
            lp.z  = max(0.0, lp.z);                            // guard: never below the deck
        }
        // DISSOLVE — died in the toxic pool: the carcass sinks into the acid and shrivels
        // away (parts that drop below the floor are occluded by it — eaten by the pool).
        float diss = C.anim.w;
        if (diss > 0.001) {
            lp.z  -= diss * 0.55 * H;              // sink into the pool
            lp.xy *= (1.0 - 0.45 * diss);         // shrivel inward
            lp.z  *= (1.0 - 0.50 * diss);         // and down as it's consumed
        }
        // ASH — crumble to a compact grainy MOUND (as the queen does), then a flat smear
        float ash = C.tune.w;
        if (ash > 0.001) {
            float mound = min(ash, 1.0), flat = clamp(ash - 1.0, 0.0, 1.0);
            float r = length(lp.xy);
            float2 dd = r > 1e-4 ? lp.xy / r : float2(1.0, 0.0);
            float heapR = 0.26;
            float grit = fract(sin(dot(in.pos.xy, float2(91.7, 47.3))) * 4137.1);
            float tr = min(r, heapR) * 0.6;
            float td = clamp(1.0 - tr / heapR, 0.0, 1.0);
            float2 tgt = dd * tr + (grit - 0.5) * 0.05;
            float tz = 0.18 * td * td + grit * 0.06;
            lp.xy = mix(lp.xy, tgt, mound);
            lp.z  = mix(lp.z, tz, mound);
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
                        texture2d<float> wallField [[texture(1)]],
                        constant Cam& C [[buffer(1)]]) {
        // WALL CLIP — discard fragments inside a wall so an extremity is cut at the
        // surface instead of poking through (a live drone's reach, or a corpse's head
        // near a door). Safe for corpses now they collapse COMPACT within the cleared
        // radius, so this only trims a small intrusion — it can't slice a whole body.
        // (eye.w = map width, fwd.w = map height; 0 in the warm pass → clip disabled.)
        if (C.eye.w > 0.5) {
            constexpr sampler ws(filter::linear, address::clamp_to_edge);
            float wd = wallField.sample(ws, in.wpos.xz / float2(C.eye.w, C.fwd.w)).r;
            if (wd < 0.06) discard_fragment();
        }
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
        float slump = smoothstep(0.32, 1.0, death);   // ova blaze through the howl, then die as she slumps
        float warm = max(0.0, alb.r - alb.b);
        float val = max(alb.r, max(alb.g, alb.b));
        float emis = smoothstep(0.22, 0.55, warm) * smoothstep(0.4, 0.8, val) * (1.0 - slump);
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
        // Reduce contrast so the creatures SIT in the world rather than reading as
        // high-contrast cut-outs — lift the shadows + ease the highlights around a dark
        // room-mid pivot (shared by queen + drone).
        col = (col - 0.17) * 0.80 + 0.17;
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

    enum Kind { case queen, drone }
    let kind: Kind

    init?(device: MTLDevice, kind: Kind = .queen) {
        self.device = device
        self.kind = kind
        guard let q = device.makeCommandQueue() else { return nil }
        self.queue = q
        let vw = RenderConfig.width, vh = RenderConfig.viewHeight
        self.W = vw; self.H = vh

        let meshName = kind == .queen ? "queen" : "drone"
        let texName  = kind == .queen ? "queen_basecolor" : "drone_basecolor"
        guard let meshURL = Bundle.main.url(forResource: meshName, withExtension: "usdz") else { return nil }
        let texURL = Bundle.main.url(forResource: texName, withExtension: "jpg")

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
        pd.vertexFunction = lib.makeFunction(name: kind == .queen ? "vmain" : "vmainDrone")
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

        let baked: Float = kind == .queen ? 1.5707963 : 0.0
        let f0key = kind == .queen ? "MeshQueenFront0" : "MeshDroneFront0"
        if let v = UserDefaults.standard.object(forKey: f0key) as? Double { self.front0 = Float(v) }
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
                   map: GameMap, death: Float, burn: Float, ashed: Float,
                   wallField: MTLTexture?, mapW: Float, mapH: Float) {
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
                      eye: SIMD4(eye, mapW), fwd: SIMD4(fwd, mapH), sector: SIMD4(sector, 0),
                      anim: SIMD4(headYaw, headPitch, breathe, sway),
                      misc: SIMD4(localHeight, 0.03 * aliveF, 0.02 * aliveF, time * 8.0 * animSpeed),   // .w = rapid howl-thrash phase
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
        enc.setFragmentTexture(wallField, index: 1)
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

    /// One in-view drone to draw this frame.
    struct DroneInst {
        var pos: SIMD2<Float>
        var dir: Float          // world facing (it turns its whole body toward the player)
        var gait: Float         // stride phase (per-drone, distance-matched from Monster.animTime)
        var move: Float         // 0…1 locomotion intensity (idle → running)
        var rear: Float         // 0…1 eased rear-up on the strike
        var dissolve: Float     // 0…1 melting into a toxic pool
        var seed: Float         // frozen per-corpse 0…1 → varies the death posture
        var death: Float, burn: Float, ashed: Float
        var sector: SIMD3<Float>
    }

    /// Draw a whole PACK of drones in ONE offscreen pass + ONE readback + ONE
    /// composite (drones spawn in numbers — per-instance readback would be brutal).
    /// The shared depth buffer resolves inter-drone occlusion; each drone writes its
    /// perp-depth so the composite occludes correctly against the world + particles.
    func compositeDrones(into canvas: Canvas2D, depth: UnsafeMutablePointer<Float>,
                         eye: SIMD3<Float>, camDir: Float, instances: [DroneInst],
                         wallField: MTLTexture?, mapW: Float, mapH: Float) {
        guard !instances.isEmpty else { return }
        let height = Self.f("MeshDroneHeight", 1.0)
        let lightGain = Self.f("MeshDroneLight", 1.9)
        let scale = height / localHeight
        let fwd = SIMD3<Float>(cos(camDir), 0, sin(camDir))
        let right = SIMD3<Float>(-sin(camDir), 0, cos(camDir))
        let up = SIMD3<Float>(0, 1, 0)
        let V = Self.view(eye, right, up, fwd)
        let P = Self.proj(plane: RenderConfig.cameraPlane, horizon: Float(RenderConfig.horizon),
                          W: Float(W), H: Float(H), near: 0.05, far: 64)

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
        enc.setFragmentTexture(albedo, index: 0)
        enc.setFragmentTexture(wallField, index: 1)
        for (i, vb) in mtk.vertexBuffers.enumerated() { enc.setVertexBuffer(vb.buffer, offset: vb.offset, index: i) }
        for inst in instances {
            let model = Self.T(inst.pos.x, 0, inst.pos.y) * Self.Ry(front0 - inst.dir) * Self.S(scale) * Self.Rx(-Float.pi / 2)
            let mvp = P * V * model
            var cam = Cam(model: model, mvp: mvp,
                          eye: SIMD4(eye, mapW), fwd: SIMD4(fwd, mapH), sector: SIMD4(inst.sector, 0),
                          anim: SIMD4(inst.gait, inst.move, inst.rear, inst.dissolve),
                          misc: SIMD4(localHeight, inst.seed, 0, 0),
                          tune: SIMD4(lightGain, max(0, min(1, inst.death)), max(0, min(1, inst.burn)), max(0, min(2, inst.ashed))))
            enc.setVertexBytes(&cam, length: MemoryLayout<Cam>.stride, index: 1)
            enc.setFragmentBytes(&cam, length: MemoryLayout<Cam>.stride, index: 1)
            for sm in mtk.submeshes {
                enc.drawIndexedPrimitives(type: sm.primitiveType, indexCount: sm.indexCount,
                                          indexType: sm.indexType, indexBuffer: sm.indexBuffer.buffer,
                                          indexBufferOffset: sm.indexBuffer.offset)
            }
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
