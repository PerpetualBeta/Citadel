// Citadel — the CPU world-lighting model (shared).
//
// The "dread" distance falloff, the baked per-cell sector-light sampling, the
// transient dynamic lights (muzzle flash + projectiles in flight), and the
// auto-ramping helmet headlamp. Extracted from the raycaster so the sprite
// compositor (which shades the billboards the GPU kernel doesn't draw) can use
// the same model. The GPU kernel does its own lighting; this is CPU-side only.

import Foundation
import simd

enum WorldLight {
    // Distance term (the "dread" falloff). Surfaces near the marine are lit;
    // everything beyond falls off exponentially into near-black.
    static let ambient: Float = 0.05
    static let glow: Float = 1.28
    static let falloff: Float = 0.16

    /// Colored sector lighting on (the game) vs the old monochrome path (the
    /// before/after preview flips this).
    static var colored = true

    /// Bilinearly interpolate the per-cell light field so pools read as light
    /// with soft gradients rather than hard per-cell seams. (Preview flips it.)
    static var smoothLight = true

    // ── auto-headlamp ───────────────────────────────────────────────────────────
    // The marine's helmet lamp: a soft forward cone (+ a small feet-spill) whose
    // intensity auto-ramps with the baked light the marine stands in — near-full
    // in unlit pockets, eased down in lit rooms. A cool LED white.
    static let lampColor = SIMD3<Float>(0.78, 0.85, 1.00)
    static let lampReach: Float = 8.5      // cells the beam carries before it dies
    static let lampNear: Float = 1.8       // radius of the omnidirectional feet-spill
    static let lampPeak: Float = 0.95      // contribution at the bright core (× gain)
    static let lampGainFloor: Float = 0.16 // the lamp never goes fully dark
    static let lampCosInner: Float = 0.88  // full brightness within ~28°
    static let lampCosOuter: Float = 0.40  // faded to nothing by ~66°
    static let lampLitRef: Float = 0.62    // baked luma at/above which the lamp idles
    static let lampDarkRef: Float = 0.12   // baked luma at/below which the lamp is full

    /// Clamp-to-edge fetch of the baked cell light colour.
    @inline(__always) static func lc(_ map: GameMap, _ i: Int, _ j: Int) -> SIMD3<Float> {
        let x = min(max(i, 0), map.w - 1), y = min(max(j, 0), map.h - 1)
        return map.lightColor[map.idx(x, y)]
    }

    /// Bilinear light colour at a continuous world point (cell centres sit at
    /// integer+0.5, so the sample grid is shifted half a cell).
    @inline(__always) static func lightAt(_ map: GameMap, _ wx: Float, _ wy: Float) -> SIMD3<Float> {
        let gx = wx - 0.5, gy = wy - 0.5
        let x0 = Int(floor(gx)), y0 = Int(floor(gy))
        let tx = gx - Float(x0), ty = gy - Float(y0)
        let top = lc(map, x0, y0) + (lc(map, x0 + 1, y0) - lc(map, x0, y0)) * tx
        let bot = lc(map, x0, y0 + 1) + (lc(map, x0 + 1, y0 + 1) - lc(map, x0, y0 + 1)) * tx
        return top + (bot - top) * ty
    }

    // ── dynamic lights (muzzle flash + projectiles) ─────────────────────────────
    // Added on top of the baked field, each with its own quadratic distance
    // falloff (no occlusion — they're transient and read fine without).
    struct DynLight { let x, y, cr, cg, cb, r2inv, inten: Float }

    static func gatherLights(_ world: World) -> [DynLight] {
        var out: [DynLight] = []
        let p = world.player
        if p.muzzle > 0 {                                   // a bright warm flash at the barrel
            let mz = min(1, p.muzzle / 0.07)
            out.append(DynLight(x: p.pos.x, y: p.pos.y, cr: 1.0, cg: 0.86, cb: 0.55, r2inv: 1 / (6.5 * 6.5), inten: 1.7 * mz))
        }
        for pr in world.projectiles {                       // each bolt/ball glows on its surroundings
            let c: (Float, Float, Float), rad: Float, it: Float
            switch pr.kind {
            case .plasma:   c = (0.50, 0.85, 1.00); rad = 3.6; it = 1.0
            case .rocket:   c = (1.00, 0.70, 0.40); rad = 3.0; it = 0.8
            case .bolt:     c = (1.00, 0.85, 0.40); rad = 3.0; it = 0.9
            case .fireball: c = (1.00, 0.45, 0.18); rad = 4.0; it = 1.2
            case .bfgBall:  c = (0.50, 1.00, 0.45); rad = 5.5; it = 1.6
            }
            out.append(DynLight(x: pr.pos.x, y: pr.pos.y, cr: c.0, cg: c.1, cb: c.2, r2inv: 1 / (rad * rad), inten: it))
        }
        return out
    }

    /// Summed dynamic-light contribution at a world point (added to the baked light).
    @inline(__always) static func dynAt(_ lights: [DynLight], _ wx: Float, _ wy: Float) -> (Float, Float, Float) {
        var r: Float = 0, g: Float = 0, b: Float = 0
        for L in lights {
            let dx = L.x - wx, dy = L.y - wy
            let f = 1 - (dx * dx + dy * dy) * L.r2inv
            if f > 0 { let w = L.inten * f * f; r += L.cr * w; g += L.cg * w; b += L.cb * w }
        }
        return (r, g, b)
    }

    /// A forward beam, premultiplied by its auto-gain, ready to sample per point.
    struct Headlamp {
        let x, y, dx, dy: Float    // origin + unit facing
        let reach, nearReach: Float
        let cosInner, cosOuter: Float
        let cr, cg, cb: Float      // beam colour × gain
    }

    /// Build the headlamp for this frame: gain ramps with how dark the cell the
    /// marine stands in actually is, so the beam is invisible in bright rooms and
    /// does the seeing in the unlit ones.
    static func makeHeadlamp(_ world: World, _ dirX: Float, _ dirY: Float) -> Headlamp {
        let p = world.player
        let amb = lightAt(world.map, p.pos.x, p.pos.y)
        let luma = amb.x * 0.299 + amb.y * 0.587 + amb.z * 0.114
        let darkness = max(0, min(1, (lampLitRef - luma) / (lampLitRef - lampDarkRef)))
        let gain = lampGainFloor + (1 - lampGainFloor) * darkness
        let c = lampColor * (lampPeak * gain)
        return Headlamp(x: p.pos.x, y: p.pos.y, dx: dirX, dy: dirY,
                        reach: lampReach, nearReach: lampNear,
                        cosInner: lampCosInner, cosOuter: lampCosOuter,
                        cr: c.x, cg: c.y, cb: c.z)
    }

    /// Headlamp contribution (additive RGB) at a world point: a soft forward cone
    /// with quadratic distance falloff, plus a small omnidirectional feet-spill so
    /// the marine's immediate surroundings aren't pitch black off-axis.
    @inline(__always) static func hlAt(_ hl: Headlamp, _ wx: Float, _ wy: Float) -> (Float, Float, Float) {
        let dx = wx - hl.x, dy = wy - hl.y
        let d2 = dx * dx + dy * dy
        if d2 >= hl.reach * hl.reach { return (0, 0, 0) }
        let d = d2.squareRoot()
        let inv = d > 1e-4 ? 1 / d : 0
        let cosA = (dx * inv) * hl.dx + (dy * inv) * hl.dy
        var cone: Float = 0
        if cosA > hl.cosOuter {
            let s = min(1, (cosA - hl.cosOuter) / (hl.cosInner - hl.cosOuter))
            cone = s * s * (3 - 2 * s)                 // smoothstep — soft cone edge
        }
        let distF = 1 - d / hl.reach
        let near = d < hl.nearReach ? (1 - d / hl.nearReach) : 0
        let w = cone * distF * distF + 0.4 * near * near
        return (hl.cr * w, hl.cg * w, hl.cb * w)
    }

    /// The scalar distance-diminishing term for a thing at depth `d`.
    @inline(__always) static func brightness(_ d: Float, _ flick: Float) -> Float {
        max(0.05, ambient + glow * expf(-d * falloff) * flick)
    }
}
