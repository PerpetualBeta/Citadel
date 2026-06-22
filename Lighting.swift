// Citadel — colored sector lighting bake.
//
// The raycaster shades every surface by a per-cell light *colour* (GameMap.
// lightColor). This file fills that field once, at level-generation time, so
// the runtime cost is just a grid lookup. The model is deliberately physical
// rather than hand-painted, in keeping with the "no magic numbers" rule:
//
//   • a per-DEPTH ambient tint — the colour the dark settles to at this depth
//     (cool worklight near the surface → amber grime in the workings → a cold
//     red-black in the depths). It scales by the structural brightness MapGen
//     already wrote per cell, so rooms stay navigable and corridors stay dim.
//   • EMITTERS read straight off the fixtures the generator placed — lit wall
//     panels, computer banks, backlit glass, the exit switch, coloured key
//     doors, and glowing hazard pools. Each throws its own colour outward with
//     distance falloff and line-of-sight occlusion, so light POOLS in the room
//     that holds the source and spills only through real openings.
//
// Nothing here is authored per-level: place a green computer bank and the room
// around it goes green, for free, on every generated map.

import Foundation
import simd

enum Lighting {

    // ── per-depth ambient fill ────────────────────────────────────────────────
    // The colour (and rough level) the unlit world settles to. Mirrors the depth
    // bands in MapGen.theme so lighting and materials shift together.
    static func ambient(level: Int) -> SIMD3<Float> {
        // The settling dark is now genuinely DARK — the level reads as
        // intimidating and the headlamp does the seeing. Emitters (panels,
        // computers, the exit switch, hazard pools) are unchanged, so lit
        // fixtures still pool bright and serve as navigational landmarks.
        switch level {
        case 1...2:  return SIMD3(0.25, 0.28, 0.36)   // surface facility — cool worklight, dimmed
        case 3...4:  return SIMD3(0.27, 0.22, 0.16)   // industrial workings — amber sodium grime
        case 5...6:  return SIMD3(0.17, 0.18, 0.24)   // deep workings — cold, failing steel-light
        default:     return SIMD3(0.18, 0.10, 0.09)   // the depths — near black, red-black
        }
    }

    // ── emissive surface description ──────────────────────────────────────────
    private struct Source {
        let color: SIMD3<Float>   // light colour (unit-ish; power scales it)
        let reach: Float          // cells the light carries before it dies
        let power: Float          // peak gain at the source
    }

    /// Light cast by a solid WALL fixture, or nil if that wall isn't a source.
    private static func wallSource(_ tex: WallTex) -> Source? {
        switch tex {
        case .litPanel:   return Source(color: SIMD3(1.00, 0.95, 0.80), reach: 8.0, power: 1.05)
        case .computer:   return Source(color: SIMD3(0.40, 1.00, 0.78), reach: 7.0, power: 0.95)
        case .glass:      return Source(color: SIMD3(0.52, 0.86, 1.00), reach: 7.5, power: 0.90)
        case .exitSwitch: return Source(color: SIMD3(0.45, 1.00, 0.55), reach: 9.0, power: 1.15)  // beckons toward the exit
        case .doorRed:    return Source(color: SIMD3(1.00, 0.32, 0.28), reach: 5.5, power: 0.72)
        case .doorBlue:   return Source(color: SIMD3(0.40, 0.55, 1.00), reach: 5.5, power: 0.72)
        case .doorYellow: return Source(color: SIMD3(1.00, 0.85, 0.32), reach: 5.5, power: 0.72)
        default:          return nil
        }
    }

    /// Light cast UP from a glowing FLOOR pool, or nil for an inert flat.
    private static func floorSource(_ tex: FlatTex) -> Source? {
        switch tex {
        case .nukage: return Source(color: SIMD3(0.50, 1.00, 0.45), reach: 5.5, power: 0.78)
        case .blood:  return Source(color: SIMD3(1.00, 0.30, 0.25), reach: 5.0, power: 0.68)
        default:      return nil
        }
    }

    private static let maxChannel: Float = 1.55   // allow a little >1 for bloomy highlights
    private static let wallFaceGain: Float = 0.92  // light a wall catches from the open cell facing it
    private static let selfGlow: Float = 1.0       // an emitter wall shows its own colour

    // ── the bake ───────────────────────────────────────────────────────────────
    static func bake(_ map: GameMap, level: Int) {
        let amb = ambient(level: level)
        let w = map.w, h = map.h

        // 1. ambient fill, modulated by the structural brightness MapGen wrote.
        for i in 0..<(w * h) { map.lightColor[i] = amb * map.light[i] }

        // 2. gather emitters off the placed fixtures.
        struct Emit { let x, y: Int; let s: Source }
        var emitters: [Emit] = []
        for y in 0..<h { for x in 0..<w {
            let i = map.idx(x, y)
            if map.wall[i] != 0 {
                if let tex = WallTex(rawValue: map.wall[i]), let s = wallSource(tex) {
                    emitters.append(Emit(x: x, y: y, s: s))
                }
            } else if let flat = FlatTex(rawValue: map.floor[i]), let s = floorSource(flat) {
                emitters.append(Emit(x: x, y: y, s: s))
            }
        }}

        // 3. cast each emitter into the OPEN cells it can see, with falloff.
        for e in emitters {
            let r = Int(e.s.reach.rounded(.up))
            let ex = Float(e.x) + 0.5, ey = Float(e.y) + 0.5
            for ty in max(0, e.y - r)...min(h - 1, e.y + r) {
                for tx in max(0, e.x - r)...min(w - 1, e.x + r) {
                    let ti = map.idx(tx, ty)
                    if map.wall[ti] != 0 { continue }                 // walls lit in pass 4
                    let dx = Float(tx) + 0.5 - ex, dy = Float(ty) + 0.5 - ey
                    let d = (dx * dx + dy * dy).squareRoot()
                    if d > e.s.reach { continue }
                    if !visible(map, e.x, e.y, tx, ty) { continue }
                    // light-like falloff: an inverse-square bright core, windowed
                    // smoothly to zero at `reach` (no hard pool edge).
                    let dn = d / e.s.reach
                    let core = 1 / (1 + 7 * dn * dn)
                    let window = 1 - dn * dn
                    map.lightColor[ti] += e.s.color * (e.s.power * core * window)
                }
            }
        }

        // 4. light the wall FACES from the brightest open cell touching them,
        //    then let emitter walls show their own colour (the panel glows).
        for y in 0..<h { for x in 0..<w {
            let i = map.idx(x, y)
            guard map.wall[i] != 0 else { continue }
            var best = amb * map.light[i]            // a wall is at least its ambient
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                guard map.inBounds(nx, ny), map.wall[map.idx(nx, ny)] == 0 else { continue }
                best = simd_max(best, map.lightColor[map.idx(nx, ny)] * wallFaceGain)
            }
            if let tex = WallTex(rawValue: map.wall[i]), let s = wallSource(tex) {
                best = simd_max(best, s.color * (s.power * selfGlow))
            }
            map.lightColor[i] = best
        }}

        // 5. clamp so highlights stay sane.
        for i in 0..<(w * h) { map.lightColor[i] = simd_min(map.lightColor[i], SIMD3(repeating: maxChannel)) }
    }

    /// Grid line-of-sight between two cell centres — blocked by any solid cell
    /// strictly between the endpoints (so light won't pass through a wall, but
    /// the emitter's own wall cell and the lit cell never block themselves).
    private static func visible(_ map: GameMap, _ ax: Int, _ ay: Int, _ bx: Int, _ by: Int) -> Bool {
        let steps = max(abs(bx - ax), abs(by - ay)) * 2
        if steps <= 1 { return true }
        let fax = Float(ax) + 0.5, fay = Float(ay) + 0.5
        let fdx = Float(bx - ax), fdy = Float(by - ay)
        for s in 1..<steps {
            let t = Float(s) / Float(steps)
            let cx = Int(fax + fdx * t), cy = Int(fay + fdy * t)
            if (cx == ax && cy == ay) || (cx == bx && cy == by) { continue }
            if !map.inBounds(cx, cy) || map.wall[map.idx(cx, cy)] != 0 { return false }
        }
        return true
    }
}
