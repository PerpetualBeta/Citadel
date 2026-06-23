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
    /// 8 floors per building; clearing all 8 hyperspaces to the next of 6 planets,
    /// then it repeats forever. Depth fiction (lighting tier + flooding) is keyed to
    /// the floor WITHIN the building, so every building descends surface→depths and
    /// resets on arrival at the next planet.
    static let floorsPerBuilding = 8
    static func floorInBuilding(_ level: Int) -> Int { ((max(1, level) - 1) % floorsPerBuilding) + 1 }

    static func ambient(level: Int) -> SIMD3<Float> {
        // The settling dark is now genuinely DARK — the level reads as
        // intimidating and the headlamp does the seeing. Emitters (panels,
        // computers, the exit switch, hazard pools) are unchanged, so lit
        // fixtures still pool bright and serve as navigational landmarks.
        switch floorInBuilding(level) {        // 1-2 surface · 3-4 workings · 5-6 deep · 7-8 depths
        case 1...2:  return SIMD3(0.25, 0.28, 0.36)   // surface facility — cool worklight, dimmed
        case 3...4:  return SIMD3(0.27, 0.22, 0.16)   // industrial workings — amber sodium grime
        case 5...6:  return SIMD3(0.17, 0.18, 0.24)   // deep workings — cold, failing steel-light
        default:     return SIMD3(0.18, 0.10, 0.09)   // the depths — near black, red-black
        }
    }

    /// How flooded the floor is at this depth: 0 = dry industrial deck, 1 = standing
    /// water. An installation floor isn't a mirror — only the bottom of a building
    /// floods (drainage has failed that far down), so reflections are reserved for
    /// the lowest floors. Keyed to floor-within-building, like `ambient`. (Liquid
    /// pools — nukage, blood — stay locally reflective at any depth; in-shader.)
    static func floodLevel(level: Int) -> Float {
        switch floorInBuilding(level) {
        case 8:  return 0.85                          // the lowest floor — drainage gone, standing water
        case 7:  return 0.30                          // nearing the bottom — water creeping in
        default: return 0.0                           // dry industrial deck
        }
    }

    // ── emitters as DRAMATIC point lights (the GPU directional-key model) ───────
    // The bake (below) lays a soft, occlusion-correct COLOUR FILL into the field.
    // That fill alone reads flat — a uniform per-cell tint with no direction, so
    // PBR materials can't catch it. So we ALSO surface each fixture as a real
    // shaded point light: a warm key off a strip-light, a teal wash off a computer
    // bank, a green beacon at the exit, coloured spill from the key doors and the
    // hazard pools. These rake the walls at an angle, throw the specular glints and
    // relief shadows the materials were built for, and pool light into open rooms
    // the flat fill just washed grey. Positions/colours come straight off the same
    // placed fixtures the bake reads — nothing authored per level.
    struct PointLight {
        var pos: SIMD3<Float>      // world (cell units in x/z, room-height in y)
        var color: SIMD3<Float>    // unit-ish colour
        var intensity: Float       // peak gain (kernel f·f falloff)
        var radius: Float          // world reach
        var shadow: Bool           // only the bright keys cast (cost)
    }

    private struct LSpec { let color: SIMD3<Float>; let intensity: Float; let radius: Float; let shadow: Bool }
    private static func lightSpec(wall tex: WallTex) -> LSpec? {
        switch tex {
        case .litPanel:   return LSpec(color: SIMD3(1.00, 0.92, 0.78), intensity: 2.0, radius: 6.5, shadow: true)   // warm key
        case .computer:   return LSpec(color: SIMD3(0.40, 1.00, 0.78), intensity: 1.3, radius: 5.5, shadow: false)  // teal wash
        case .glass:      return LSpec(color: SIMD3(0.52, 0.86, 1.00), intensity: 1.1, radius: 5.5, shadow: false)  // backlit cyan
        case .exitSwitch: return LSpec(color: SIMD3(0.45, 1.00, 0.55), intensity: 1.4, radius: 6.0, shadow: true)   // green beacon (leads to the exit)
        case .doorRed:    return LSpec(color: SIMD3(1.00, 0.32, 0.28), intensity: 1.3, radius: 4.5, shadow: false)
        case .doorBlue:   return LSpec(color: SIMD3(0.40, 0.55, 1.00), intensity: 1.3, radius: 4.5, shadow: false)
        case .doorYellow: return LSpec(color: SIMD3(1.00, 0.85, 0.32), intensity: 1.3, radius: 4.5, shadow: false)
        default:          return nil
        }
    }
    private static func lightSpec(floor tex: FlatTex) -> LSpec? {
        switch tex {
        case .nukage: return LSpec(color: SIMD3(0.50, 1.00, 0.45), intensity: 1.3, radius: 4.5, shadow: false)  // green uplight
        case .blood:  return LSpec(color: SIMD3(1.00, 0.30, 0.25), intensity: 0.9, radius: 3.5, shadow: false)
        default:      return nil
        }
    }

    /// Every fixture in the map, surfaced as a shaded point light. Wall fixtures
    /// are nudged off the wall into the open cell they face (so they light the room,
    /// not the inside of their own bulkhead); floor pools light upward. The caller
    /// culls these to the camera and budgets the shadow-casters.
    static func pointLights(_ map: GameMap) -> [PointLight] {
        var out: [PointLight] = []
        let w = map.w, h = map.h
        let wallY: Float = 0.6, floorY: Float = 0.16   // room is 0…1 tall (kernel ceilH = 1)
        // A run of identical fixtures (a 10-cell strip light, a computer bank) is ONE
        // light source, not ten stacked on top of each other — so cluster adjacent
        // same-fixture cells into a single light per ~3-cell block. Without this a
        // strip wall floods its room with 10× its intended colour.
        let cluster = 3
        var seen = Set<Int>()
        func claim(_ x: Int, _ y: Int, _ kind: Int) -> Bool {
            seen.insert(((x / cluster) &* 4096 + (y / cluster)) &* 64 + kind).inserted
        }
        for y in 0..<h { for x in 0..<w {
            let i = map.idx(x, y)
            if map.wall[i] != 0 {
                guard let tex = WallTex(rawValue: map.wall[i]), let sp = lightSpec(wall: tex) else { continue }
                var ox: Float = 0, oz: Float = 0, opens = 0
                for (nx, ny, dx, dz) in [(x - 1, y, -1, 0), (x + 1, y, 1, 0), (x, y - 1, 0, -1), (x, y + 1, 0, 1)] {
                    if map.inBounds(nx, ny) && map.wall[map.idx(nx, ny)] == 0 { ox += Float(dx); oz += Float(dz); opens += 1 }
                }
                if opens == 0 { continue }                                   // embedded in solid — would light nothing
                if !claim(x, y, map.wall[i]) { continue }                    // already a light for this fixture nearby
                let n = simd_normalize(SIMD2<Float>(ox, oz))
                let pos = SIMD3<Float>(Float(x) + 0.5 + n.x * 0.45, wallY, Float(y) + 0.5 + n.y * 0.45)
                out.append(PointLight(pos: pos, color: sp.color, intensity: sp.intensity, radius: sp.radius, shadow: sp.shadow))
            } else if let flat = FlatTex(rawValue: map.floor[i]), let sp = lightSpec(floor: flat) {
                if !claim(x, y, 100 + map.floor[i]) { continue }
                out.append(PointLight(pos: SIMD3(Float(x) + 0.5, floorY, Float(y) + 0.5), color: sp.color, intensity: sp.intensity, radius: sp.radius, shadow: false))
            }
        }}
        return out
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
