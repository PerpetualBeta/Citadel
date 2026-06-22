// Citadel — procedural wall & flat textures.
//
// Zero asset files: every surface is generated from maths at launch into
// tileable 256×256 packed-RGBA tiles. The fiction is a remote off-world
// industrial colony, abandoned to the dark and descended into — so the
// material set is IRON, STEEL, GLASS, PIPEWORK and STONE, not brick. The look
// is built from STRUCTURE + MATERIAL DEPTH: bevelled riveted plate, brushed
// steel, working strip-lights, reinforced glass, pipe banks with valves, raw
// hewn rock, and rock with steel infrastructure clinging on. A layer of
// grime / oxidation / wear noise rides over every multi-tone material ramp —
// never flat fills. Walls are sampled by column in the raycaster; flats by the
// per-row floor/ceiling caster. Feature sizes are expressed against `size`, so
// the tile resolution is a single knob.

import Foundation

struct Texture {
    let size: Int
    let mask: Int
    let pixels: [UInt32]
    init(size: Int, pixels: [UInt32]) { self.size = size; self.mask = size - 1; self.pixels = pixels }
    @inline(__always) func at(_ tx: Int, _ ty: Int) -> UInt32 { pixels[(ty & mask) * size + (tx & mask)] }
}

enum WallTex: Int, CaseIterable {
    case none = 0
    case ironPlate, brushedSteel, steelPanel, litPanel, ribbedSteel, pipework, glass, stone, stoneSteel, computer, hazard
    case doorPanel, doorRed, doorBlue, doorYellow, exitSwitch
}
enum FlatTex: Int, CaseIterable {
    case concrete = 0, metalFloor, grate, nukage, ceilTech, ceilDark, ceilStone, rock, blood
}

final class Textures {
    static let shared = Textures(relief: true)
    let size = 256
    let reliefOn: Bool
    private(set) var walls: [Texture] = []
    private(set) var flats: [Texture] = []

    func wall(_ id: Int) -> Texture { walls[min(max(id, 0), walls.count - 1)] }
    func flat(_ id: Int) -> Texture { flats[min(max(id, 0), flats.count - 1)] }

    // `relief: false` builds the raw, un-embossed set — only the material
    // preview's before/after uses it; the game always builds the relief set.
    init(relief: Bool) {
        self.reliefOn = relief
        walls = WallTex.allCases.map { build(wall: $0) }
        flats = FlatTex.allCases.map { build(flat: $0) }
    }

    // ── noise (tileable) ──────────────────────────────────────────────────────
    @inline(__always) private func hash(_ x: Int, _ y: Int, _ s: Int) -> Float {
        var h = UInt32(bitPattern: Int32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263 &+ s &* 1_274_126_177))
        h = (h ^ (h >> 13)) &* 1_274_126_177; h = h ^ (h >> 16)
        return Float(h & 0xFFFF) / 65535.0
    }
    private func vnoise(_ x: Float, _ y: Float, _ p: Int, _ s: Int) -> Float {
        let xi = Int(floor(x)), yi = Int(floor(y)); let xf = x - Float(xi), yf = y - Float(yi)
        func smp(_ ax: Int, _ ay: Int) -> Float { hash((ax % p + p) % p, (ay % p + p) % p, s) }
        let u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf)
        let a = smp(xi, yi), b = smp(xi + 1, yi), c = smp(xi, yi + 1), d = smp(xi + 1, yi + 1)
        return (a * (1 - u) + b * u) * (1 - v) + (c * (1 - u) + d * u) * v
    }
    private func fbm(_ x: Float, _ y: Float, _ p: Int, _ s: Int, _ oct: Int = 3) -> Float {
        var sum: Float = 0, amp: Float = 0.5, fr = 1, per = p
        for o in 0..<oct { sum += amp * vnoise(x * Float(fr), y * Float(fr), per, s + o * 97); amp *= 0.5; fr *= 2; per *= 2 }
        return sum
    }

    @inline(__always) private func rgb(_ r: Int, _ g: Int, _ b: Int) -> UInt32 { packRGBA(r, g, b) }

    // ── wall builders ─────────────────────────────────────────────────────────
    private func build(wall tex: WallTex) -> Texture {
        let s = size
        var px = [UInt32](repeating: 0xFF00_0000, count: s * s)
        func set(_ x: Int, _ y: Int, _ c: UInt32) { px[(y & (s - 1)) * s + (x & (s - 1))] = c }
        func get(_ x: Int, _ y: Int) -> UInt32 { px[(y & (s - 1)) * s + (x & (s - 1))] }

        // a bevelled, grimy recessed-panel field over a base colour
        func panels(cell: Int, base: (Int, Int, Int), seed: Int, rivets: Bool, tintB: Int = 8) {
            let rv = cell / 12
            for y in 0..<s { for x in 0..<s {
                let cx = x % cell, cy = y % cell
                var o = Int((fbm(Float(x) / 28, Float(y) / 28, 16, seed) - 0.5) * 22)        // grime
                if vnoise(Float(x) / 10, Float(y) / 10, 32, seed + 5) > 0.86 { o -= 26 }      // stains
                if cx < 1 || cy < 1 { o -= 46 }                                              // groove
                else if cx < 3 || cy < 3 { o += 40 }                                         // inner highlight (top-left)
                else if cx >= cell - 2 || cy >= cell - 2 { o -= 30 }                         // inner shadow (bottom-right)
                set(x, y, rgb(base.0 + o, base.1 + o, base.2 + o + tintB))
                if rivets && (cx == rv || cx == cell - rv) && (cy == rv || cy == cell - rv) {
                    set(x, y, rgb(base.0 + 56, base.1 + 56, base.2 + 60)); set(x + 1, y + 1, rgb(base.0 - 30, base.1 - 30, base.2 - 26))
                }
            }}
        }

        switch tex {
        case .none:
            for i in 0..<px.count { px[i] = rgb(46, 48, 58) }

        case .ironPlate:
            // riveted oxidised iron — the industrial workhorse wall
            panels(cell: 128, base: (104, 92, 84), seed: 21, rivets: true, tintB: -4)
            for y in 0..<s { for x in 0..<s {
                var c = get(x, y)
                // downward rust streaks bleeding from the rivet courses
                let col = hash(x / 2, 0, 71)
                let streak = vnoise(Float(x) / 6, Float(y) / 40, 64, 73)
                if col > 0.7 && streak > 0.45 {
                    let amt = min(0.55, (streak - 0.45) * (col - 0.7) * 3.4)
                    c = mixRGBA(c, rgb(128, 66, 34), amt)                                     // rust orange
                }
                // broad oxidation mottle
                let ox = fbm(Float(x) / 30, Float(y) / 30, 16, 77)
                if ox > 0.62 { c = mixRGBA(c, rgb(120, 78, 50), (ox - 0.62) * 1.4) }
                set(x, y, c)
            }}

        case .brushedSteel:
            // cleaner brushed / welded steel — the facility's good rooms
            let cell = 128
            for y in 0..<s { for x in 0..<s {
                let grad = 1 - Float(y) / Float(s) * 0.16
                var o = Int((hash(x, y / 4, 41) - 0.5) * 22 + sin(Float(y) * 0.9) * 4)         // horizontal brushed grain
                let cx = x % cell, cy = y % cell
                if cx == 0 || cy == 0 { o -= 40 } else if cx == 1 || cy == 1 { o += 26 }       // panel weld seam
                var r = Int(Float(150 + o) * grad), g = Int(Float(156 + o) * grad), b = Int(Float(170 + o) * grad)
                if cx == 1 && (y % 10 < 6) { r += 20; g += 20; b += 18 }                       // weld bead
                set(x, y, rgb(r, g, b))
                if cx == cell / 2 && cy == cell / 2 { set(x, y, rgb(112, 118, 132)) }          // bolt
            }}

        case .steelPanel:
            // recessed bevelled steel bulkhead with a vent
            panels(cell: 128, base: (96, 100, 114), seed: 11, rivets: true)
            for y in 0..<s where (y % 128) >= 80 && (y % 128) <= 112 && (y % 8) < 3 {
                for x in 0..<s where (x % 128) >= 24 && (x % 128) <= 104 { set(x, y, rgb(40, 42, 50)) }
            }

        case .litPanel:
            // steel bulkhead with a cold working strip-light
            panels(cell: 128, base: (84, 90, 104), seed: 13, rivets: true)
            for y in 0..<s { for x in 0..<s {
                let cx = x % 128, cy = y % 128
                if cx >= 56 && cx <= 71 && cy >= 20 && cy <= 108 {                             // strip light
                    let g = 150 + Int(fbm(Float(x) / 8, Float(y) / 16, 16, 3) * 90)
                    set(x, y, rgb(70, g, 168))
                } else if cx >= 48 && cx <= 79 && cy >= 16 && cy <= 112 {                      // bloom
                    set(x, y, mixRGBA(get(x, y), rgb(50, 120, 168), 0.25))
                }
            }}

        case .ribbedSteel:
            // cylindrical ribbed conduit metal with seams + bolts
            for y in 0..<s { for x in 0..<s {
                let rib = sin(Float(x % 32) / 32 * 6.2832)
                var o = Int(rib * 44) + Int((fbm(Float(x) / 16, Float(y) / 20, 16, 5) - 0.5) * 16)
                if y % 64 == 0 { o -= 52 } else if y % 64 == 1 { o += 26 }                     // horizontal seams
                set(x, y, rgb(104 + o, 108 + o, 120 + o))
                if (x % 32 == 16) && (y % 64 == 32) { set(x, y, rgb(160, 164, 176)) }          // bolts
            }}

        case .pipework:
            // a bank of vertical pipes with flanges and a valve wheel
            for i in 0..<px.count { px[i] = rgb(38, 40, 48) }                                  // dark recess behind
            let gap = s / 4, pipeW = 44
            for p in 0..<4 {
                let cxp = gap / 2 + p * gap
                let tone = 96 + Int(hash(p, 0, 5) * 30)
                for y in 0..<s { for dx in -pipeW / 2...pipeW / 2 {
                    let x = cxp + dx
                    let t = Float(dx) / Float(pipeW / 2)
                    let sh = 1 - t * t * 0.7                                                    // cylinder shading
                    var o = Int((fbm(Float(x) / 16, Float(y) / 20, 16, 9) - 0.5) * 12)
                    if y % 64 < 6 { o -= 30 } else if y % 64 == 6 { o += 24 }                   // flange bands
                    set(x, y, rgb(Int(Float(tone + o) * sh), Int(Float(tone + 4 + o) * sh), Int(Float(tone + 14 + o) * sh)))
                }}
                if p == 1 {                                                                    // a valve wheel
                    let vy = s / 2, rr = 28
                    for a in stride(from: Float(0), to: Float(6.2832), by: 0.03) {
                        set(cxp + Int(cos(a) * Float(rr)), vy + Int(sin(a) * Float(rr)), rgb(156, 124, 60))
                    }
                    for r in -rr...rr { set(cxp + r, vy, rgb(156, 124, 60)); set(cxp, vy + r, rgb(156, 124, 60)) }
                }
            }

        case .glass:
            // reinforced observation glass set in a steel mullion frame
            let frame = 14
            for y in 0..<s { for x in 0..<s {
                if x < frame || x > s - 1 - frame || y < frame || y > s - 1 - frame || abs(x - s / 2) < 4 || abs(y - s / 2) < 4 {
                    let o = (abs(x - s / 2) < 4 || abs(y - s / 2) < 4) ? -10 : 0
                    set(x, y, rgb(120 + o, 126 + o, 138 + o))                                   // frame + mullions
                } else {
                    let grad = Float(y) / Float(s)
                    let refl = max(0, sin((Float(x) + Float(y)) * 0.06)) * 30                   // diagonal reflection
                    let r = 26 + Int(grad * 20) + Int(refl * 0.4)
                    var g = 60 + Int(grad * 50) + Int(refl)
                    var b = 72 + Int(grad * 60) + Int(refl)
                    let glow = vnoise(Float(x) / 30, Float(y) / 30, 16, 31)
                    if glow > 0.6 { g += Int((glow - 0.6) * 120); b += Int((glow - 0.6) * 90) } // faint internal glow
                    set(x, y, rgb(r, g, b))
                }
            }}
            var ck = s / 3                                                                     // a hairline crack
            for y in frame..<(s - frame) { ck += Int((hash(y, 0, 13) - 0.5) * 3); set(ck, y, rgb(184, 202, 212)); set(ck + 1, y, rgb(90, 110, 122)) }

        case .stone:
            // raw hewn underground rock with strata, fissures and mineral flecks
            for y in 0..<s { for x in 0..<s {
                let n = fbm(Float(x) / 24, Float(y) / 24, 16, 51, 5)
                let strata = sin(Float(y) * 0.05 + n * 4)
                var o = Int((n - 0.5) * 70) + Int(strata * 14)
                if vnoise(Float(x) / 10 + n * 4, Float(y) / 14, 32, 53) > 0.74 { o -= 60 }      // fissures
                var r = 96 + o, g = 86 + o, b = 76 + o
                if vnoise(Float(x) / 3, Float(y) / 3, 64, 57) > 0.93 { r += 30; g += 28; b += 20 } // mineral flecks
                set(x, y, rgb(r, g, b))
            }}

        case .stoneSteel:
            // rock with steel I-beam struts bolted in — infrastructure clinging on
            for y in 0..<s { for x in 0..<s {
                let n = fbm(Float(x) / 24, Float(y) / 24, 16, 51, 5)
                var o = Int((n - 0.5) * 64)
                if vnoise(Float(x) / 10 + n * 4, Float(y) / 14, 32, 53) > 0.76 { o -= 50 }
                set(x, y, rgb(86 + o, 80 + o, 74 + o))
            }}
            for sx in [s / 4, s * 3 / 4] {                                                     // vertical struts
                for y in 0..<s { for dx in -10...10 {
                    let x = sx + dx, t = Float(dx) / 10
                    let sh = 1 - t * t * 0.5
                    var o = Int((fbm(Float(x) / 12, Float(y) / 16, 16, 61) - 0.5) * 12)
                    if abs(dx) >= 9 { o -= 30 }
                    let v = Int(Float(120 + o) * sh)
                    set(x, y, rgb(v, v + 4, v + 12))
                    if y % 48 < 4 { set(x, y, rgb(70, 72, 82)) }                                // bolt bands
                }}
                for y in stride(from: 24, to: s, by: 48) { set(sx - 7, y, rgb(172, 174, 184)); set(sx + 7, y, rgb(172, 174, 184)) }
            }
            for x in 0..<s { for dy in -6...6 {                                                 // horizontal band
                let y = s / 2 + dy
                let v = 110 + Int((fbm(Float(x) / 12, Float(y) / 8, 16, 63) - 0.5) * 16)
                set(x, y, rgb(v, v + 4, v + 12))
            }}

        case .computer:
            for y in 0..<s { for x in 0..<s {
                var r = 22, g = 26, b = 36
                let cx = x % 64, cy = y % 48
                if cx >= 6 && cx <= 56 && cy >= 6 && cy <= 32 {                                 // screen blocks
                    if hash(x / 64, y / 48, 3) > 0.3 {
                        let lit = hash(x / 16, y / 6, 9)
                        r = 14; g = 96 + Int(lit * 120); b = 120 + Int(lit * 60)                // cold blue terminals
                        if y % 6 < 2 { g -= 30 }                                                // scanlines
                    } else { r = 30; g = 34; b = 46 }
                }
                if cx == 0 || cy == 0 { r = 10; g = 12; b = 16 }                                // bezels
                if cx == 60 { r = 60; g = 62; b = 72 }                                          // cable rail
                set(x, y, rgb(r, g, b))
            }}

        case .hazard:
            for y in 0..<s { for x in 0..<s {
                let stripe = ((x + y) / 36) % 2 == 0
                let wear = fbm(Float(x) / 20, Float(y) / 20, 16, 14)
                if stripe { set(x, y, rgb(210 + Int(wear * 30), 176 + Int(wear * 30), 34)) }
                else { set(x, y, rgb(26 + Int(wear * 16), 26 + Int(wear * 16), 30)) }
                if vnoise(Float(x) / 10, Float(y) / 10, 32, 2) > 0.9 { set(x, y, rgb(40, 40, 44)) } // chips
            }}

        case .doorPanel: doorBase(&px, s, band: nil, light: rgb(120, 132, 150))
        case .doorRed: doorBase(&px, s, band: (214, 56, 48), light: rgb(220, 90, 80))
        case .doorBlue: doorBase(&px, s, band: (66, 110, 226), light: rgb(110, 150, 255))
        case .doorYellow: doorBase(&px, s, band: (226, 196, 56), light: rgb(255, 230, 120))

        case .exitSwitch:
            panels(cell: 128, base: (80, 84, 96), seed: 9, rivets: true)
            let a = s / 4, bX = s * 3 / 4, t = s / 5, bY = s * 4 / 5
            for y in (t - 6)..<(bY + 6) { for x in (a - 6)..<(bX + 6) { set(x, y, rgb(20, 22, 28)) } }   // recess
            for y in t..<bY { for x in a..<bX {
                let on = 60 + Int(fbm(Float(x) / 8, Float(y) / 8, 16, 1) * 50)
                set(x, y, rgb(28, 170 + on / 3, 90))
            }}
            for c in 0..<3 { for d in 0..<36 {                                                 // down chevrons
                set(a + 40 + d, t + 28 + c * 36 + d / 2, rgb(220, 255, 220))
                set(bX - 40 - d, t + 28 + c * 36 + d / 2, rgb(220, 255, 220))
            }}
        }
        if reliefOn { applyRelief(&px, s, reliefStrength(wall: tex)) }
        return Texture(size: s, pixels: px)
    }

    // ── directional relief (top-lit emboss baked from luminance) ────────────────

    /// Bake a top-left directional relief from the texture's own luminance, so
    /// seams, rivets, fissures, ribs and strata read as carved 3-D and catch the
    /// light. Flat regions (zero gradient) are untouched — only structure shades.
    /// Tileable: neighbour sampling wraps, like everything else here.
    private func applyRelief(_ px: inout [UInt32], _ s: Int, _ strength: Float) {
        if strength <= 0 { return }
        var h = [Float](repeating: 0, count: s * s)
        for i in 0..<(s * s) {
            let c = px[i]
            h[i] = Float(c & 0xFF) * 0.299 + Float((c >> 8) & 0xFF) * 0.587 + Float((c >> 16) & 0xFF) * 0.114
        }
        @inline(__always) func H(_ x: Int, _ y: Int) -> Float { h[(y & (s - 1)) * s + (x & (s - 1))] }
        for y in 0..<s { for x in 0..<s {
            // slope toward a top-left light: height rising up/left → lit, else shaded
            let e = ((H(x - 1, y) - H(x + 1, y)) + (H(x, y - 1) - H(x, y + 1))) / 510
            let f = max(0.45, min(1.7, 1 + strength * e))
            let i = y * s + x, c = px[i]
            px[i] = packRGBA(Int(Float(c & 0xFF) * f), Int(Float((c >> 8) & 0xFF) * f),
                             Int(Float((c >> 16) & 0xFF) * f), Int((c >> 24) & 0xFF))
        }}
    }

    private func reliefStrength(wall tex: WallTex) -> Float {
        switch tex {
        case .stone: return 1.7              // hewn rock — the carved hero surface
        case .stoneSteel: return 1.4
        case .ribbedSteel: return 1.2
        case .ironPlate: return 1.1
        case .steelPanel: return 1.0
        case .pipework: return 1.0
        case .doorPanel, .doorRed, .doorBlue, .doorYellow: return 0.9
        case .exitSwitch: return 0.8
        case .brushedSteel, .litPanel: return 0.7
        case .hazard: return 0.6
        case .computer: return 0.5           // just the bezels
        case .glass: return 0.25             // just the frame / mullions
        case .none: return 0
        }
    }
    private func reliefStrength(flat tex: FlatTex) -> Float {
        switch tex {
        case .rock: return 1.4
        case .ceilStone: return 1.2
        case .metalFloor: return 0.9
        case .concrete: return 0.8
        case .ceilTech: return 0.6
        case .grate: return 0.5
        case .ceilDark: return 0.4
        case .nukage, .blood: return 0       // liquids — they shimmer in the raycaster
        }
    }

    /// A heavy blast door: bevelled frame, central seam, hydraulic struts,
    /// key band, status light. `band` tints the central key stripe.
    private func doorBase(_ px: inout [UInt32], _ s: Int, band: (Int, Int, Int)?, light: UInt32) {
        func set(_ x: Int, _ y: Int, _ c: UInt32) { px[(y & (s - 1)) * s + (x & (s - 1))] = c }
        let frame = 16
        for y in 0..<s { for x in 0..<s {
            var o = Int((fbm(Float(x) / 28, Float(y) / 36, 16, 7) - 0.5) * 16)
            if x < frame || x > s - 1 - frame || y < frame || y > s - 1 - frame { o -= 44 }     // frame groove
            if x == frame || y == frame { o += 30 }
            let seam = abs(x - s / 2)
            if seam < 3 { o -= 60 } else if seam < 9 { o += 16 }                                // central seam + bevel
            if y % 64 == 32 { o -= 16 }                                                         // detail bands
            set(x, y, rgb(106 + o, 110 + o, 122 + o))
        }}
        for y in stride(from: 40, to: s - 40, by: 1) {                                          // hydraulic struts
            set(36, y, rgb(60, 62, 72)); set(38, y, rgb(120, 124, 136)); set(40, y, rgb(40, 42, 50))
            set(s - 40, y, rgb(60, 62, 72)); set(s - 42, y, rgb(120, 124, 136)); set(s - 38, y, rgb(40, 42, 50))
        }
        if let band = band {
            for y in (s * 42 / 100)..<(s * 60 / 100) { for x in 48..<(s - 48) where abs(x - s / 2) > 9 {
                if ((x + y) / 20) % 2 == 0 { set(x, y, rgb(band.0, band.1, band.2)) }
                else { set(x, y, rgb(band.0 / 3, band.1 / 3, band.2 / 3)) }
            }}
            for j in -6...6 { for i in -6...6 where i * i + j * j <= 36 { set(s / 2 + i, 52 + j, light) } } // status light
        }
    }

    // ── flat builders ─────────────────────────────────────────────────────────
    private func build(flat tex: FlatTex) -> Texture {
        let s = size
        var px = [UInt32](repeating: 0xFF00_0000, count: s * s)
        func set(_ x: Int, _ y: Int, _ c: UInt32) { px[y * s + x] = c }
        for y in 0..<s { for x in 0..<s {
            switch tex {
            case .concrete:
                var o = Int((fbm(Float(x) / 32, Float(y) / 32, 16, 1) - 0.5) * 34)
                if vnoise(Float(x) / 6, Float(y) / 6, 64, 4) > 0.9 { o -= 30 }          // aggregate flecks
                if x % 128 == 0 || y % 128 == 0 { o -= 24 }                            // expansion joints
                set(x, y, rgb(96 + o, 96 + o, 100 + o))
            case .metalFloor:
                let cx = x % 64, cy = y % 64
                var o = Int((fbm(Float(x) / 16, Float(y) / 16, 16, 2) - 0.5) * 18)
                if cx == 0 || cy == 0 { o -= 34 } else if cx == 1 || cy == 1 { o += 18 }
                if ((x + y) % 32 < 5) || ((x - y + 512) % 32 < 5) { o += 14 }           // diamond tread
                set(x, y, rgb(92 + o, 94 + o, 102 + o))
                if cx == 32 && cy == 32 { set(x, y, rgb(150, 152, 160)) }               // rivet
            case .grate:
                let cx = x % 32, cy = y % 32                                            // steel walkway grating
                if cx < 6 || cy < 6 {
                    var o = Int((fbm(Float(x) / 12, Float(y) / 12, 16, 22) - 0.5) * 14)
                    if cx == 0 || cy == 0 { o += 16 }                                  // bar top highlight
                    set(x, y, rgb(86 + o, 90 + o, 100 + o))
                } else {
                    let d = 18 + Int(fbm(Float(x) / 8, Float(y) / 8, 16, 23) * 14)      // dark void below
                    set(x, y, rgb(d, d, d + 4))
                }
            case .nukage:
                let t = fbm(Float(x) / 36, Float(y) / 36, 16, 3, 5)
                let blob = vnoise(Float(x) / 16, Float(y) / 16, 16, 7)
                var g = 168 + Int(t * 80), r = 40 + Int(t * 30), b = 44 + Int(t * 24)
                if blob > 0.7 { g += 56; r += 24 }                                      // glowing pools
                if vnoise(Float(x) / 8, Float(y) / 8, 32, 9) > 0.92 { g += 40; r += 30 } // bubbles
                set(x, y, rgb(r, g, b))
            case .ceilTech:
                let cx = x % 128, cy = y % 128
                var o = Int((fbm(Float(x) / 32, Float(y) / 32, 16, 6) - 0.5) * 16)
                if cx == 0 || cy == 0 { o -= 22 }
                set(x, y, rgb(52 + o, 52 + o, 56 + o))
                if cx >= 52 && cx <= 76 && cy >= 52 && cy <= 76 {                       // light fixture
                    let g = 150 + Int(fbm(Float(x) / 6, Float(y) / 6, 16, 2) * 80)
                    set(x, y, rgb(g, g, g - 20))
                }
            case .ceilDark:
                let o = Int(fbm(Float(x) / 36, Float(y) / 36, 16, 8) * 20)
                set(x, y, rgb(28 + o, 28 + o, 32 + o))
                if y % 128 == 40 && x % 8 < 3 { set(x, y, rgb(44, 44, 50)) }            // pipe run
            case .ceilStone:
                let n = fbm(Float(x) / 28, Float(y) / 28, 16, 41, 5)
                let o = Int((n - 0.5) * 50)
                var r = 48 + o, g = 44 + o, b = 40 + o
                if vnoise(Float(x) / 12, Float(y) / 16, 32, 43) > 0.76 { r -= 24; g -= 22; b -= 20 } // cracks
                set(x, y, rgb(r, g, b))
            case .rock:
                let n = fbm(Float(x) / 24, Float(y) / 24, 16, 16, 5)
                let strata = sin(Float(y) * 0.06 + n * 5)
                let o = Int(n * 48) + Int(strata * 12)
                set(x, y, rgb(74 + o, 66 + o, 56 + o))
            case .blood:
                let t = fbm(Float(x) / 24, Float(y) / 24, 16, 19, 5)
                let clot = vnoise(Float(x) / 16, Float(y) / 16, 16, 4)
                var r = 96 + Int(t * 84), g = 18 + Int(t * 24), b = 20 + Int(t * 18)
                if clot > 0.7 { r -= 36; g -= 8 }
                set(x, y, rgb(r, g, b))
            }
        }}
        if reliefOn { applyRelief(&px, s, reliefStrength(flat: tex)) }
        return Texture(size: s, pixels: px)
    }
}
