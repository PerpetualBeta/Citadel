// Citadel — intel dossier portrait plates.
//
// Static FRONT + LEFT-PROFILE plates of the two castes, raymarched from the
// same CreatureLab SDFs the game bakes its sprites from — the dossier shows
// the organism itself, not a re-drawing of it. The old codex reused the
// in-game walk tiles, whose framing is authored for billboards (viewH/groundY
// tuned by eye), so tall features clipped against the tile edge and the
// 8-angle turntable juddered. These plates fix both: no animation, and the
// framing is DERIVED, never authored.
//
// Framing: every round-cone lies inside the hull of its two endpoint spheres,
// and a smooth-min union can fatten the surface by at most k/4 beyond the raw
// volumes — so bounds computed from endpoints + radii + k/4 are conservative.
// Horizontal reach is measured as radius-from-the-y-axis, which a yaw spin
// cannot change, so one window is exact for every view angle. Nothing can
// crop (SmokeTest proves it by scanning the plate borders for ink).
//
// The four plates render once on a background queue at launch (warm()); the
// codex draws a DECRYPTING placeholder in the unlikely event someone reaches
// it first. Harnesses call ensureRendered() for determinism.

import Foundation
import simd

enum IntelPortraits {
    struct Plate {
        let pixels: [UInt32]
        let w, h: Int
        let footY: Int          // plate row of the creature's lowest point — the shadow line
    }
    enum View: Int, CaseIterable { case front, profile }

    /// The roster sheet's presentation angles (CreatureLab.run): a touch of
    /// turn so the front reads as a body, and the full left-hand-side profile.
    private static func yaw(_ v: View) -> Float { v == .front ? 0.15 : 1.55 }
    /// The roster's dossier stance — mid-stride, jaws shut.
    private static let stancePh: Float = 0.12

    static let plateH = uiS(180)

    // ── once-rendered plates, published for non-blocking reads ──────────────
    private static let lock = NSLock()
    private static var published: [Plate]?

    private static let rendered: [Plate] = {          // static let ⇒ dispatch_once
        var out = [Plate?](repeating: nil, count: MonsterKind.allCases.count * View.allCases.count)
        out.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: buf.count) { i in
                buf[i] = render(MonsterKind(rawValue: i / View.allCases.count)!,
                                View(rawValue: i % View.allCases.count)!)
            }
        }
        return out.map { $0! }
    }()

    /// Kick the plates off in the background (called at launch) — the codex
    /// itself never blocks a frame on them.
    static func warm() {
        DispatchQueue.global(qos: .utility).async { ensureRendered() }
    }

    /// Block until the plates exist — harnesses want them deterministically.
    static func ensureRendered() {
        let r = rendered
        lock.lock(); published = r; lock.unlock()
    }

    /// nil until warm() lands — the codex shows the decrypting placeholder.
    static func plate(_ kind: MonsterKind, _ view: View) -> Plate? {
        lock.lock(); defer { lock.unlock() }
        return published?[kind.rawValue * View.allCases.count + view.rawValue]
    }

    // ── one plate: derive the window, march, trim the dead air ──────────────
    private static func render(_ kind: MonsterKind, _ view: View) -> Plate {
        let def = MonsterBake.cdef(kind)
        let shapes = def.build(stancePh, 0)
        var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        var axisR: Float = 0, maxK: Float = 0
        for s in shapes {
            minY = min(minY, s.a.y - s.r1, s.b.y - s.r2)
            maxY = max(maxY, s.a.y + s.r1, s.b.y + s.r2)
            axisR = max(axisR, simd_length(SIMD2(s.a.x, s.a.z)) + s.r1,
                               simd_length(SIMD2(s.b.x, s.b.z)) + s.r2)
            maxK = max(maxK, s.k)
        }
        // pad: the ≤k/4 smin inflation, plus a whisker of air so the silhouette's
        // AA feather never kisses the frame
        let pad = maxK / 4 + (maxY - minY) * 0.03
        let viewH = (maxY - minY) + pad * 2
        let groundY = minY - pad
        let worldW = (axisR + pad) * 2
        let h = plateH
        let w = max(1, Int((Float(h) * worldW / viewH).rounded()))
        let px = CreatureLab.renderShapes(shapes, viewH: viewH, groundY: groundY,
                                          yaw: yaw(view), w: w, h: h)
        // Trim fully-transparent side columns: the axis-radius bound is exact for
        // the WORST yaw, so the front view carries wide empty margins the page
        // layout shouldn't have to centre around. Trimming empty air is not
        // cropping — a feather margin keeps the AA edge intact.
        var lo = w, hi = -1
        for j in 0..<h {
            let row = j * w
            for i in 0..<w where px[row + i] >> 24 != 0 { lo = min(lo, i); hi = max(hi, i) }
        }
        let feather = 3                       // px — beyond renderShapes' ~1.5 px AA band
        lo = max(0, lo - feather); hi = min(w - 1, hi + feather)
        if hi < lo { lo = 0; hi = w - 1 }     // blank plate (can't happen; belt-and-braces)
        let tw = hi - lo + 1
        var trimmed = [UInt32](repeating: 0, count: tw * h)
        for j in 0..<h { for i in 0..<tw { trimmed[j * tw + i] = px[j * w + lo + i] } }
        let footY = Int(Float(h) * (1 - pad / viewH))
        return Plate(pixels: trimmed, w: tw, h: h, footY: footY)
    }
}
