#if CITADEL_HARNESS
// Citadel — RIG PROBE (CITADEL_RIGPROBE). Dev-only R&D.
//
// Before building the humanoid poser we must know exactly what ModelIO exposes
// from a rigged Tripo USDZ: the skeleton (joint paths + rest/bind transforms),
// the per-mesh bind component (geometry-bind + the joint ordering the vertex
// indices refer to), and the per-vertex skin weights/indices. This prints all of
// it for one mesh so the real loader is written against verified facts, not guesses.

import Foundation
import simd
import ModelIO

enum RigProbe {
    static func run(path: String?) {
        let url = path.map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.url(forResource: "colonist_woman", withExtension: "usdz")
        guard let url else { print("RigProbe: no mesh URL"); return }
        print("RigProbe: \(url.lastPathComponent)")

        let asset = MDLAsset(url: url)
        asset.loadTextures()

        // ── skeleton (MDLSkeleton is an MDLObject, so it lives in the asset tree) ──
        let skels = asset.childObjects(of: MDLSkeleton.self).compactMap { $0 as? MDLSkeleton }
        print("── skeletons found: \(skels.count)")
        if let sk = skels.first {
            let rest = sk.jointRestTransforms.float4x4Array
            let bind = sk.jointBindTransforms.float4x4Array
            print("   jointPaths: \(sk.jointPaths.count)")
            print("   restTransforms: \(rest.count)  bindTransforms: \(bind.count)")
            // rest is LOCAL (per-parent), bind is WORLD (accumulated) if this holds:
            // for a deep joint, |bind.translation| ≫ |rest.translation|.
            func t(_ m: simd_float4x4) -> SIMD3<Float> { SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z) }
            for i in [0, min(5, rest.count - 1), min(25, rest.count - 1), rest.count - 1] where i >= 0 {
                let rt = i < rest.count ? t(rest[i]) : .zero
                let bt = i < bind.count ? t(bind[i]) : .zero
                print(String(format: "   [%2d] %@\n        rest|t|=%.3f (%.2f,%.2f,%.2f)  bind|t|=%.3f (%.2f,%.2f,%.2f)",
                             i, sk.jointPaths[i],
                             simd_length(rt), rt.x, rt.y, rt.z,
                             simd_length(bt), bt.x, bt.y, bt.z))
            }
        }

        // ── the mesh + its bind component ──
        guard let mesh = asset.childObjects(of: MDLMesh.self).compactMap({ $0 as? MDLMesh }).first else {
            print("RigProbe: no MDLMesh"); return
        }
        print("── mesh: vertexCount=\(mesh.vertexCount)")

        // (The MDLAnimationBindComponent has no clean Swift accessor — it needs an ObjC
        // Protocol. We instead rely on the MDLSkeleton above + the per-vertex weights
        // below, and confirm the index→joint mapping straight from the USD source.)

        // ── per-vertex skin weights/indices via the vertex descriptor ──
        let vd = MDLVertexDescriptor()
        var off = 0
        vd.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: off, bufferIndex: 0); off += 12
        vd.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeJointIndices, format: .uShort4, offset: off, bufferIndex: 0); off += 8
        vd.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeJointWeights, format: .float4, offset: off, bufferIndex: 0); off += 16
        (vd.layouts[0] as? MDLVertexBufferLayout)?.stride = off
        mesh.vertexDescriptor = vd

        let vb = mesh.vertexBuffers[0]
        let map = vb.map()
        let stride = off
        let base = map.bytes
        func dumpVertex(_ i: Int) {
            let p = base + i * stride
            let pos = p.assumingMemoryBound(to: Float.self)
            let idx = (p + 12).assumingMemoryBound(to: UInt16.self)
            let w = (p + 20).assumingMemoryBound(to: Float.self)
            print(String(format: "   v%d pos(%.2f,%.2f,%.2f) idx[%d,%d,%d,%d] w[%.2f,%.2f,%.2f,%.2f] Σ%.2f",
                         i, pos[0], pos[1], pos[2], idx[0], idx[1], idx[2], idx[3],
                         w[0], w[1], w[2], w[3], w[0] + w[1] + w[2] + w[3]))
        }
        print("── sample skinned vertices (top-4 of the 7 influences, as ModelIO packs them):")
        for i in [0, mesh.vertexCount / 3, mesh.vertexCount / 2, mesh.vertexCount - 1] where i >= 0 && i < mesh.vertexCount {
            dumpVertex(i)
        }
        print("RigProbe: done")
    }
}
#endif
