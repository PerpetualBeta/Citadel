// Citadel — HUMANOID RIG: a small, reusable skeletal-skinning poser.
//
// The engine is otherwise rigless (creatures deform procedurally in the vertex
// shader). This is the one place we work a real skeleton — so a rigged humanoid
// USDZ can be POSED by name ("bend Spine01 forward, fold the knees, droop the
// head") and BAKED into a static mesh we then render through the ordinary path.
//
// Why bake on the CPU instead of skinning on the GPU every frame? The posed body
// never moves — re-running a joint palette per frame would spend GPU (and fan) on
// an identical result. We skin once at load; the result is plain geometry. The
// same rig + Pose could drive GPU skinning later if we ever want humanoids that
// actually move — the maths below is exactly what a skinning vertex shader does.
//
// THE MATHS (standard linear-blend skinning, USD SkelBindingAPI conventions):
//   • Each joint has a BIND transform (its world pose when the mesh was skinned)
//     and we precompute invBind = inverse(bind).
//   • A joint's LOCAL transform (relative to its parent) is recovered from the
//     binds: localBind[j] = inverse(bind[parent]) · bind[j]. Deriving it this way
//     (rather than trusting the separate rest array) GUARANTEES that with no pose
//     deltas the skin is the identity — the mesh renders exactly as authored.
//   • To POSE, we post-multiply a joint's local transform by a rotation delta and
//     re-accumulate down the hierarchy:
//        worldPose[j] = worldPose[parent] · localBind[j] · delta[j]
//   • The per-joint skin matrix is  skin[j] = worldPose[j] · invBind[j].
//   • A vertex is the weighted blend over its (≤4) influencing joints:
//        p' = Σ wᵢ · skin[jointᵢ] · p     (normals by the 3×3 part, renormalised)
//
// Local space is the mesh's own (Z-up for these Tripo exports): z = 0 at the feet.

import Foundation
import simd
import Metal
import MetalKit
import ModelIO

/// A pose = a set of joint rotations, addressed by the joint's leaf name (the last
/// path segment, e.g. "Spine01", "L_Thigh"). Order matters only in that all deltas
/// are applied in each joint's own local frame; the hierarchy walk composes them.
struct HumanoidPose {
    /// leaf joint name → local rotation to apply (in the joint's own frame).
    private(set) var deltas: [String: simd_quatf] = [:]

    /// Add a rotation of `angle` radians about `axis` (in the joint's local frame)
    /// to the named joint. Repeated calls to the same joint compose.
    mutating func rotate(_ joint: String, _ angle: Float, axis: SIMD3<Float>) {
        let q = simd_quatf(angle: angle, axis: simd_normalize(axis))
        deltas[joint] = (deltas[joint].map { $0 * q }) ?? q
    }

    /// Convenience: apply the same rotation to a list of joints (e.g. both twists).
    mutating func rotate(_ joints: [String], _ angle: Float, axis: SIMD3<Float>) {
        for j in joints { rotate(j, angle, axis: axis) }
    }

    static var identity: HumanoidPose { HumanoidPose() }

    /// The fuel-store survivor: someone who hid in a sealed room the swarm never
    /// cracked, and died there — seated, back to the wall, knees drawn up, head hung.
    /// Authored by joint name against the Tripo humanoid rig; axes/signs are tuned
    /// against headless previews (CITADEL_CORPSES).
    /// The fuel-store survivor, seated and slumped FORWARD (hid here and gave out).
    /// `seed` varies every joint a little so no two people sit the same — pass the
    /// model index so each of the seven has its own distinct collapse.
    /// Axes (Tripo rig, mesh Z-up): thigh +X = leg forward; SPINE/HEAD −X = fold
    /// FORWARD (+X leant them back — the bug); upper-arm ±Z drops the arms to the lap.
    static func survivor(seed: Float) -> HumanoidPose {
        func h(_ a: Float) -> Float { let v = sin(seed * a + a) * 43758.5453; return v - floor(v) }   // 0…1
        let h1 = h(12.99), h2 = h(78.23), h3 = h(37.71), h4 = h(5.31)
        var p = HumanoidPose()
        // seated: thighs forward toward horizontal, knees relaxed (both varied)
        p.rotate(["L_Thigh", "R_Thigh"], 1.20 + 0.25 * h1, axis: [1, 0, 0])
        p.rotate(["L_Calf", "R_Calf"], 0.35 + 0.45 * h2, axis: [1, 0, 0])
        // torso folds FORWARD over the knees; the head hangs. Depth varies per body.
        let slump = 0.34 + 0.34 * h3
        p.rotate("Spine01", -slump, axis: [1, 0, 0])
        p.rotate("Spine02", -slump * 0.7, axis: [1, 0, 0])
        p.rotate("NeckTwist01", -0.14, axis: [1, 0, 0])
        p.rotate("Head", -(0.28 + 0.28 * h1), axis: [1, 0, 0])
        // a small sideways lean + head-loll so some tip left, some right
        p.rotate("Spine01", (h2 - 0.5) * 0.5, axis: [0, 0, 1])
        p.rotate("Head", (h4 - 0.5) * 0.5, axis: [0, 0, 1])
        // arms fallen to the lap (mirrored), amount varies
        let arm = 0.95 + 0.35 * h4
        p.rotate("L_Upperarm", -arm, axis: [0, 0, 1])
        p.rotate("R_Upperarm", arm, axis: [0, 0, 1])
        return p
    }
}

enum HumanoidRig {

    /// Load a rigged USDZ, apply `pose`, and bake the skinned result into an MTKMesh
    /// ready for the colonist render pipeline (interleaved pos/nrm/uv, stride 32).
    /// Returns nil if the file has no skeleton or skin weights (caller falls back to
    /// the raw standing mesh). `standingHeight` is the UN-posed z-extent, so the
    /// caller scales every pose by the same factor (a seated body must not be scaled
    /// up to full standing height).
    static func bake(url: URL, pose: HumanoidPose, device: MTLDevice)
        -> (mesh: MTKMesh, standingHeight: Float, bbMin: SIMD3<Float>, bbMax: SIMD3<Float>)? {

        let asset = MDLAsset(url: url)
        guard let skel = asset.childObjects(of: MDLSkeleton.self).compactMap({ $0 as? MDLSkeleton }).first,
              let mdl = asset.childObjects(of: MDLMesh.self).compactMap({ $0 as? MDLMesh }).first
        else { return nil }

        let paths = skel.jointPaths
        let bind = skel.jointBindTransforms.float4x4Array          // WORLD bind, per joint
        guard paths.count == bind.count, !paths.isEmpty else { return nil }
        let n = paths.count

        // parent index per joint, from the path prefix ("A/B/C" → parent "A/B").
        var indexOfPath = [String: Int](minimumCapacity: n)
        for (i, p) in paths.enumerated() { indexOfPath[p] = i }
        var parent = [Int](repeating: -1, count: n)
        for (i, p) in paths.enumerated() {
            if let cut = p.lastIndex(of: "/") { parent[i] = indexOfPath[String(p[p.startIndex..<cut])] ?? -1 }
        }
        func leaf(_ p: String) -> String { p.lastIndex(of: "/").map { String(p[p.index(after: $0)...]) } ?? p }

        // localBind[j] = inverse(bind[parent]) · bind[j]  (identity-at-rest guarantee)
        var localBind = [simd_float4x4](repeating: matrix_identity_float4x4, count: n)
        var invBind = [simd_float4x4](repeating: matrix_identity_float4x4, count: n)
        for j in 0..<n {
            invBind[j] = simd_inverse(bind[j])
            localBind[j] = parent[j] >= 0 ? (simd_inverse(bind[parent[j]]) * bind[j]) : bind[j]
        }

        // worldPose[j] = worldPose[parent] · localBind[j] · delta[j]   (delta = pose)
        // Joints are listed parents-before-children in USD, so a single forward pass
        // composes correctly; we don't rely on that and could re-sort, but assert-free
        // here because the probe confirmed the ordering.
        var worldPose = [simd_float4x4](repeating: matrix_identity_float4x4, count: n)
        for j in 0..<n {
            var local = localBind[j]
            if let q = pose.deltas[leaf(paths[j])] { local = local * simd_float4x4(q) }
            worldPose[j] = parent[j] >= 0 ? (worldPose[parent[j]] * local) : local
        }

        // skin[j] = worldPose[j] · invBind[j]
        var skin = [simd_float4x4](repeating: matrix_identity_float4x4, count: n)
        for j in 0..<n { skin[j] = worldPose[j] * invBind[j] }

        // ── read source geometry: position, normal, uv, and the ≤4 skin influences ──
        mdl.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.4)
        let rd = MDLVertexDescriptor()
        rd.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        rd.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0)
        rd.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: 24, bufferIndex: 0)
        rd.attributes[3] = MDLVertexAttribute(name: MDLVertexAttributeJointIndices, format: .uShort4, offset: 32, bufferIndex: 0)
        rd.attributes[4] = MDLVertexAttribute(name: MDLVertexAttributeJointWeights, format: .float4, offset: 40, bufferIndex: 0)
        (rd.layouts[0] as? MDLVertexBufferLayout)?.stride = 56
        mdl.vertexDescriptor = rd

        let vcount = mdl.vertexCount
        let src = mdl.vertexBuffers[0].map().bytes
        let stride = 56

        // ── skin every vertex into a fresh interleaved pos/nrm/uv buffer (stride 32) ──
        var out = [Float](repeating: 0, count: vcount * 8)
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var stLo = lo, stHi = hi          // standing (un-posed) bounds, for the scale factor
        for v in 0..<vcount {
            let p = src + v * stride
            let pos = p.assumingMemoryBound(to: Float.self)
            let nrm = (p + 12).assumingMemoryBound(to: Float.self)
            let uv  = (p + 24).assumingMemoryBound(to: Float.self)
            let idx = (p + 32).assumingMemoryBound(to: UInt16.self)
            let wt  = (p + 40).assumingMemoryBound(to: Float.self)

            let P0 = SIMD4<Float>(pos[0], pos[1], pos[2], 1)
            let N0 = SIMD3<Float>(nrm[0], nrm[1], nrm[2])
            stLo = simd_min(stLo, SIMD3(pos[0], pos[1], pos[2]))
            stHi = simd_max(stHi, SIMD3(pos[0], pos[1], pos[2]))

            var wsum = wt[0] + wt[1] + wt[2] + wt[3]
            if wsum < 1e-5 { wsum = 1 }                // unweighted vertex → leave in place
            var P = SIMD4<Float>(repeating: 0)
            var N = SIMD3<Float>(repeating: 0)
            for k in 0..<4 {
                let w = wt[k] / wsum
                if w <= 0 { continue }
                let j = Int(idx[k])
                if j < 0 || j >= n { continue }
                let m = skin[j]
                P += w * (m * P0)
                let m3 = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                       SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                       SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
                N += w * (m3 * N0)
            }
            if simd_length(P) < 1e-6 { P = P0 }        // fully-unweighted safety
            let Nn = simd_length(N) > 1e-6 ? simd_normalize(N) : N0

            let o = v * 8
            out[o + 0] = P.x; out[o + 1] = P.y; out[o + 2] = P.z
            out[o + 3] = Nn.x; out[o + 4] = Nn.y; out[o + 5] = Nn.z
            out[o + 6] = uv[0]; out[o + 7] = uv[1]
            lo = simd_min(lo, SIMD3(P.x, P.y, P.z))
            hi = simd_max(hi, SIMD3(P.x, P.y, P.z))
        }

        // GROUND the posed body so its lowest point rests at z = 0 (the deck). A
        // seated/slumped pose leaves the lowest vertex well above the feet-origin, so
        // without this the body floats. (Local +Z is up for these meshes.)
        let dropZ = lo.z
        if abs(dropZ) > 1e-5 {
            for v in 0..<vcount { out[v * 8 + 2] -= dropZ }
            lo.z -= dropZ; hi.z -= dropZ
        }

        // ── gather the index buffer (all submeshes → one UInt32 run, one material) ──
        var indices = [UInt32]()
        for case let sm as MDLSubmesh in mdl.submeshes ?? [] {
            let ib = sm.indexBuffer.map().bytes
            switch sm.indexType {
            case .uInt16:
                let p = ib.assumingMemoryBound(to: UInt16.self)
                for i in 0..<sm.indexCount { indices.append(UInt32(p[i])) }
            case .uInt32:
                let p = ib.assumingMemoryBound(to: UInt32.self)
                for i in 0..<sm.indexCount { indices.append(p[i]) }
            default: continue
            }
        }
        guard !indices.isEmpty else { return nil }

        // ── build the posed MDLMesh (stride 32) → MTKMesh ──
        let allocator = MTKMeshBufferAllocator(device: device)
        let vData = out.withUnsafeBytes { Data($0) }
        let iData = indices.withUnsafeBytes { Data($0) }
        let vBuf = allocator.newBuffer(with: vData, type: .vertex)
        let iBuf = allocator.newBuffer(with: iData, type: .index)
        let submesh = MDLSubmesh(indexBuffer: iBuf, indexCount: indices.count,
                                 indexType: .uInt32, geometryType: .triangles, material: nil)
        let vdesc = MDLVertexDescriptor()
        vdesc.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        vdesc.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0)
        vdesc.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: 24, bufferIndex: 0)
        (vdesc.layouts[0] as? MDLVertexBufferLayout)?.stride = 32
        let posed = MDLMesh(vertexBuffer: vBuf, vertexCount: vcount, descriptor: vdesc, submeshes: [submesh])

        guard let mtk = try? MTKMesh(mesh: posed, device: device) else { return nil }
        let standingHeight = max(0.001, stHi.z - stLo.z)
        return (mtk, standingHeight, lo, hi)
    }
}
