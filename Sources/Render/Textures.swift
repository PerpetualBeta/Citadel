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
    case doorPanel, doorRed, doorBlue, doorYellow, exitSwitch, doorHazard, elevatorSealed
    case liftWall            // elevator-car lining — a machined steel box (no relief/grime; see MapGen.steelBoxCar)
    case concrete            // bare cast concrete — fireproof stores (fuel chamber); smooth grey, no steel relief
    case opsBoard            // operations-centre BIG BOARD — the one full-colour (RGB) display in the complex
    case medWall             // MEDICAL CENTRE — white painted concrete: clean, sterile, almost no grime
    case subwayTile          // CANTEEN/GALLEY — white ceramic subway tiles in offset bond, grey grout
}
enum FlatTex: Int, CaseIterable {
    case concrete = 0, metalFloor, grate, nukage, ceilTech, ceilDark, ceilStone, rock, blood, teleportPad
    case ceilWhite           // MEDICAL CENTRE ceiling — white painted panels with a recessed light run
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
            // a bank of vertical pipes with flanges, stamped with the owner's mark
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
            }
            // the ARC seal stencilled across the bank — the corporation marks its
            // plant (the old circle-and-cross doodle read as nothing; this is the
            // same seal the title screen and visor carry, sprayed in stencil gold)
            stampArcSeal(&px, s, cx: s / 2, cy: s / 2, r: 34, color: rgb(156, 124, 60))

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
            // A bank of amber CRT terminals — the same ARC phosphor ramp as the
            // title screen (Codex.amber/amberHi/amberDim), replacing the old teal
            // hash-blocks. 64×64 monitor cells tile the 256px texture 4×4 with no
            // partial row (the old 64×48 grid sliced a monitor at every wrap).
            // Each live screen bakes one of three content modes — boot log, data
            // table, scope trace — and the kernel adds the life on top: emission,
            // flicker, busted units and a rolling CRT refresh bar.
            let dim = (110, 86, 38), std = (240, 196, 96), hi = (255, 233, 176)
            func phos(_ c: (Int, Int, Int), _ k: Float) -> UInt32 {
                rgb(Int(Float(c.0) * k), Int(Float(c.1) * k), Int(Float(c.2) * k))
            }
            for my in 0..<4 { for mx in 0..<4 {
                let x0 = mx * 64, y0 = my * 64, m = my * 4 + mx
                // case body, panel seams, cable duct down the right edge
                for cy in 0..<64 { for cx in 0..<64 {
                    var r = 22, g = 26, b = 36
                    if cx == 0 || cy == 0 { r = 10; g = 12; b = 16 }
                    else if cx >= 61 { r = 34; g = 38; b = 48 }
                    if cx == 61 { r = 52; g = 55; b = 66 }
                    let wear = Int((hash(x0 + cx, y0 + cy, 21) - 0.5) * 10)
                    set(x0 + cx, y0 + cy, rgb(r + wear, g + wear, b + wear))
                }}
                // vent slots + a status-LED row under the screen
                for cy in stride(from: 54, through: 58, by: 2) { for cx in 8...36 {
                    set(x0 + cx, y0 + cy, rgb(12, 14, 20))
                }}
                for l in 0..<3 {
                    let on = l == Int(hash(mx, my, 31) * 3)
                    let c = on ? phos(std, 1.0) : rgb(40, 36, 30)
                    set(x0 + 44 + l * 5, y0 + 60, c); set(x0 + 45 + l * 5, y0 + 60, c)
                }
                // screen glass
                for cy in 6...49 { for cx in 6...57 {
                    let v = Int(hash(x0 + cx, y0 + cy, 5) * 4)
                    set(x0 + cx, y0 + cy, rgb(13 + v, 10 + v, 7))
                }}
                if hash(mx, my, 3) > 0.85 {                     // dead unit: dark glass, one faint diagonal sheen
                    for cy in 6...49 { let cx = 20 + (cy - 6); if cx <= 57 { set(x0 + cx, y0 + cy, rgb(24, 22, 20)) } }
                    continue
                }
                let bright = 0.72 + 0.38 * hash(mx, my, 11)     // per-unit tube age
                // one 2px-high "word" of phosphor glyphs
                func word(_ x: Int, _ y: Int, _ len: Int, _ c: (Int, Int, Int), _ k: Float) {
                    for dx in 0..<len where x + dx <= 56 { for dy in 0..<2 {
                        set(x0 + x + dx, y0 + y + dy, phos(c, k))
                    }}
                }
                switch Int(hash(mx, my, 7) * 3) {
                case 0:                                         // BOOT LOG — ragged indented lines, dim history, rare bright alerts
                    var y = 8, r = 0
                    while y <= 46 {
                        let head = r == 0
                        let alert = !head && hash(m, r, 41) > 0.90
                        let tone = head || alert ? hi : (hash(m, r, 43) > 0.45 ? std : dim)
                        let k = head || alert ? bright : bright * (0.8 + 0.2 * hash(m, r, 47))
                        var x = 8 + (head ? 0 : Int(hash(m, r, 53) * 3) * 4)
                        while x < 50 {
                            let len = 3 + Int(hash(m, r &* 7 &+ x, 59) * 7)
                            word(x, y, min(len, 54 - x), tone, k)
                            x += len + 2 + Int(hash(m, r &* 13 &+ x, 61) * 3)
                        }
                        if head { for cx in 8...56 { set(x0 + cx, y0 + y + 3, phos(dim, bright)) }; y += 2 }
                        y += 4; r += 1
                    }
                case 1:                                         // DATA TABLE — labels, right-aligned values, a scrollbar thumb
                    var y = 8, r = 0
                    while y <= 44 {
                        let head = r == 0
                        word(8, y, 6 + Int(hash(m, r, 67) * 8), head ? hi : (hash(m, r, 71) > 0.3 ? std : dim), bright)
                        let vlen = 3 + Int(hash(m, r, 73) * 6)
                        word(50 - vlen, y, vlen, head ? hi : std, bright * 0.95)
                        if head { for cx in 8...54 { set(x0 + cx, y0 + y + 3, phos(dim, bright)) } }
                        y += 5; r += 1
                    }
                    for cy in 8...46 { set(x0 + 56, y0 + cy, rgb(36, 32, 24)) }
                    let th = 8 + Int(hash(mx, my, 79) * 26)
                    for cy in th...(th + 7) { set(x0 + 56, y0 + cy, phos(std, bright)) }
                default:                                        // SCOPE — grid dots + a jagged live trace, peaks flaring
                    for cy in stride(from: 8, through: 48, by: 8) { for cx in stride(from: 8, through: 56, by: 8) {
                        set(x0 + cx, y0 + cy, rgb(46, 37, 18))
                    }}
                    let amp = 6 + hash(mx, my, 83) * 8, ph = hash(mx, my, 89) * 6.28
                    for cx in 6...57 {
                        let t = Float(cx - 6)
                        let sine = sinf(t * 0.30 + ph)
                        let jag = (fbm(t / 6, Float(m) * 3.7, 16, 91) - 0.5) * 7
                        let fy = 27 + Int(sine * amp + jag)
                        let tone = abs(sine) > 0.92 ? hi : std
                        for dy in 0...1 { set(x0 + cx, y0 + min(max(fy + dy, 7), 48), phos(tone, bright)) }
                    }
                    word(8, 44, 8, dim, bright); word(20, 44, 5, std, bright)   // status row
                }
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
        case .doorRed: doorBase(&px, s, band: (214, 56, 48), light: rgb(236, 58, 40))       // status lamp: a clear RED (was a washed pink dot)
        case .doorBlue: doorBase(&px, s, band: (66, 110, 226), light: rgb(110, 150, 255))
        case .doorYellow: doorBase(&px, s, band: (226, 196, 56), light: rgb(255, 230, 120))

        case .doorHazard:
            // the FUEL STORE door — real door leaves (frame groove, centre seam,
            // hydraulic struts, all from doorBase) under worn diagonal hazard
            // striping, replacing the flat hazard WALL plate it used to borrow
            // (which had no door structure at all). Stripes kept dim so they
            // don't trip the kernel's emissive mask; the red lamps glow faintly.
            doorBase(&px, s, band: nil, light: 0)
            let fr = 20
            for y in fr..<(s - fr) { for x in fr..<(s - fr) {
                if abs(x - s / 2) < 12 { continue }                                // centre seam + bevel stays clear
                if (x >= 32 && x <= 44) || (x >= s - 46 && x <= s - 34) { continue }   // struts stay proud
                guard ((x + y) / 24) % 2 == 0 else { continue }                    // the diagonals
                let wear = fbm(Float(x) / 18, Float(y) / 18, 16, 33)
                if wear > 0.62 { continue }                                        // paint chipped through to steel
                let o = Int((wear - 0.3) * 40)
                set(x, y, rgb(128 + o, 106 + o, 28))
            }}
            for leaf in 0..<2 {                                                    // AMBER warning lamp per leaf (flash added live in the raster door pass)
                let cx = leaf == 0 ? s / 4 : s * 3 / 4
                for j in -6...6 { for i in -6...6 where i * i + j * j <= 36 {
                    set(cx + i, 48 + j, i * i + j * j > 22 ? rgb(58, 40, 12) : rgb(150, 96, 20))   // dark bezel + dim amber lens (its lit state is the live overlay)
                }}
            }

        case .exitSwitch:
            // the DESCENDER — green go-lamps + down-chevrons (shared leaf bones
            // in elevatorLeaves; the arrival car below reads visibly different)
            elevatorLeaves(set, s, sealed: false)

        case .elevatorSealed:
            // the ARRIVAL car — red standby pips + crossed SEALED bars: this
            // lift only came DOWN; the shaft above is closed. Distinct at a
            // glance from the descender that leaves the floor.
            elevatorLeaves(set, s, sealed: true)

        case .liftWall:
            // lift-car lining: machined brushed steel, deliberately near-
            // featureless — a car is a STEEL BOX, not a bulkhead and not the
            // surrounding geology. The kernel skips relief + grime on it (as it
            // does the door slabs), so what's baked here is all it ever shows:
            // faint horizontal brushing, a kick plate, a slim top trim shadow.
            for y in 0..<s { for x in 0..<s {
                let brush = (vnoise(Float(x) / 96, Float(y) / 2, 32, 71) - 0.5) * 14
                var v = 140 + Int(brush)
                if y >= s - s / 8 { v -= 26 }                   // kick plate along the base
                if y < s / 24 { v -= 14 }                       // top trim shadow
                set(x, y, rgb(v, v + 3, v + 8))
            }}

        case .opsBoard:
            // The operations centre's BIG BOARD: a wall of large screens in a bezelled frame. Only the dark
            // glass and its mullions are baked — the picture itself is drawn live per-fragment (mining, shipping,
            // launches, orbital track) in the raster shader, because a plot board that doesn't move is a poster.
            // Deliberately near-BLACK so unlit board reads black and the colour content owns all the contrast.
            for y in 0..<s { for x in 0..<s {
                let n = fbm(Float(x) / 40, Float(y) / 40, 16, 91, 3)
                var v = 12 + Int((n - 0.5) * 8)
                let cw = s / 2, ch = s / 2                                   // a 2×2 grid of big panels
                let cx = x % cw, cy = y % ch
                if cx < 5 || cy < 5 || cx >= cw - 5 || cy >= ch - 5 { v += 26 }        // brushed mullion
                if cx < 2 || cy < 2 { v -= 6 }                                        // groove inside the bezel
                set(x, y, rgb(v, v + 1, v + 4))
            }}

        case .subwayTile:
            // CANTEEN: white ceramic SUBWAY tiles. The offset (running-bond) courses are what sell it — a
            // straight grid reads as bathroom lino, whereas the half-tile stagger reads as real tiling. Each
            // tile gets a bevelled edge that catches the light, a little glaze variation so the wall isn't a
            // flat fill, and grey grout between. Wipe-clean, which is the point in a galley.
            let th = s / 8                     // tile height → 8 courses per tile
            let tw = s / 4                     // tile width  → 4 tiles per course (2:1, as subway tile is)
            let grout = 3
            for y in 0..<s { for x in 0..<s {
                let course = y / th
                let xs = (course % 2 == 0) ? x : x + tw / 2        // every other course offset by half a tile
                let cx = ((xs % s) + s) % s % tw, cy = y % th
                if cx < grout || cy < grout {
                    let g = 132 + Int((fbm(Float(x) / 12, Float(y) / 12, 16, 151) - 0.5) * 18)
                    set(x, y, rgb(g, g, g - 2))                    // grey grout, slightly grubby
                    continue
                }
                // glazed face: soft per-tile tone variation + a bevel highlight/shadow at the edges
                let tileID = hash(xs / tw, course, 157)
                var v = 224 + Int((tileID - 0.5) * 14)
                v += Int((fbm(Float(x) / 9, Float(y) / 9, 16, 163) - 0.5) * 8)          // glaze mottle
                if cx < grout + 3 || cy < grout + 3 { v += 16 }                          // bevel catches light
                if cx >= tw - 3 || cy >= th - 3 { v -= 18 }                              // bevel in shadow
                if y > s - s / 8 { v -= 12 }                                             // grubbier near the floor
                set(x, y, rgb(v, v, v - 4))
            }}

        case .medWall:
            // MEDICAL: concrete painted white and kept that way. Deliberately the CLEANEST surface in the
            // colony — only the faintest roller mottle, a scuff skirting where trolleys have clipped it, and a
            // wipe-down dado line. Grime here would undo the whole point of the room.
            for y in 0..<s { for x in 0..<s {
                let n = fbm(Float(x) / 46, Float(y) / 46, 16, 131, 3)
                var v = 206 + Int((n - 0.5) * 12)                         // near-white, softly uneven paint
                if y > s - s / 7 { v -= 26 }                              // scuffed skirting
                if abs(y - s * 5 / 8) < 2 { v -= 16 }                     // wipe-down dado rail
                let cw = s / 2
                if x % cw < 2 { v -= 10 }                                 // shallow panel joint
                set(x, y, rgb(v, v, v - 3))
            }}

        case .concrete:
            // bare cast concrete — a fireproof store: smooth neutral grey with faint cloudy
            // mottling, a coarse grid of form-tie dimples, and thin vertical damp-stains. No
            // steel, no panelisation, near-zero relief — reads as poured, not built.
            for y in 0..<s { for x in 0..<s {
                let n = fbm(Float(x) / 30, Float(y) / 30, 16, 71, 4)
                var o = Int((n - 0.5) * 26)
                let stain = vnoise(Float(x) / 9, Float(y) / 60, 32, 73)          // faint vertical damp streaks
                if stain > 0.72 { o -= Int((stain - 0.72) * 90) }
                let v = 150 + o
                set(x, y, rgb(v, v - 2, v - 6))
            }}
            let step = max(24, s / 4)
            for gy in stride(from: step / 2, to: s, by: step) {
                for gx in stride(from: step / 2, to: s, by: step) {
                    for j in -2...2 { for i in -2...2 where i * i + j * j <= 4 {
                        let x = gx + i, y = gy + j
                        guard x >= 0, x < s, y >= 0, y < s else { continue }
                        let d = i * i + j * j                                    // recessed tie hole (darker at centre)
                        set(x, y, rgb(104 + d * 6, 102 + d * 6, 98 + d * 6))
                    }}
                }
            }
        }
        if reliefOn { applyRelief(&px, s, reliefStrength(wall: tex)) }
        return Texture(size: s, pixels: px)
    }

    /// Shared freight-elevator leaves: dark brushed steel, frame groove, kick
    /// plate, hazard-striped meeting edges, vents — with per-role furniture:
    /// the descender gets green go-lamps + down-chevrons; the sealed arrival
    /// car gets red standby pips + crossed bars.
    private func elevatorLeaves(_ set: (Int, Int, UInt32) -> Void, _ s: Int, sealed: Bool) {
        for y in 0..<s { for x in 0..<s {
            let grain = Int((fbm(Float(x) / 5, Float(y) / 46, 16, 9) - 0.5) * 14)
            var r = 70 + grain, g = 73 + grain, b = 82 + grain
            if x < 10 || x > s - 11 || y < 10 || y > s - 11 { r -= 34; g -= 34; b -= 34 }
            if x == 10 || y == 10 { r += 22; g += 22; b += 22 }
            if y > s - 34 { r -= 18; g -= 18; b -= 16 }
            let seam = abs(x - s / 2)
            if seam < 2 { r = 12; g = 13; b = 16 }
            else if seam < 12 {
                if ((y + seam) / 12) % 2 == 0 { r = 128; g = 106; b = 28 }
                else { r = 26; g = 26; b = 30 }
            }
            set(x, y, rgb(r, g, b))
        }}
        for leaf in 0..<2 {
            let cx = leaf == 0 ? s / 4 : s * 3 / 4
            if sealed {
                for d in -26...26 { for th in 0..<4 {                       // crossed SEALED bars
                    set(cx + d, s / 2 + d + th, rgb(96, 34, 30))
                    set(cx + d, s / 2 - d + th, rgb(96, 34, 30))
                }}
            } else {
                for c in 0..<2 { for d in 0..<18 { for th in 0..<3 {        // etched DOWN chevrons
                    let y = s / 2 + c * 26 + d / 2 + th
                    set(cx - 18 + d, y, rgb(38, 96, 56)); set(cx + 18 - d, y, rgb(38, 96, 56))
                }}}
            }
            for j in -7...7 { for i in -7...7 where i * i + j * j <= 49 {   // status lamp
                let edge = i * i + j * j > 30
                if sealed { set(cx + i, s / 6 + j, edge ? rgb(52, 20, 18) : rgb(190, 54, 40)) }
                else { set(cx + i, s / 6 + j, edge ? rgb(30, 70, 40) : rgb(96, 235, 128)) }
            }}
            for row in 0..<3 { for x in (cx - 22)...(cx + 22) where x % 3 != 0 {   // vents
                set(x, s - 48 + row * 5, rgb(30, 31, 36))
            }}
        }
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
        case .doorPanel, .doorRed, .doorBlue, .doorYellow, .doorHazard: return 0.9
        case .elevatorSealed: return 0.8
        case .exitSwitch: return 0.8
        case .brushedSteel, .litPanel: return 0.7
        case .hazard: return 0.6
        case .computer: return 0.5           // just the bezels
        case .liftWall: return 0.3           // barely-there brushing — a machined box
        case .concrete: return 0.25          // poured concrete — near-flat, only the tie dimples catch
        case .opsBoard: return 0.4           // just the bezels between the board's panels
        case .medWall: return 0.2            // painted flat — only the skirting and dado catch
        case .subwayTile: return 0.55        // the grout lines and tile bevels should read as real relief
        case .glass: return 0.25             // just the frame / mullions
        case .none: return 0
        }
    }
    /// The ARC corporate seal as a painted stencil — broken outer ring, inner
    /// dome, "ARC" beneath: the same mark FrontEnd.arcSeal draws for the title
    /// and visor, baked here into wall pixels wherever the corporation's plant
    /// runs. Semi-transparent, so it reads as sprayed over the metal.
    private func stampArcSeal(_ px: inout [UInt32], _ s: Int, cx: Int, cy: Int, r: Int, color: UInt32) {
        func put(_ x: Int, _ y: Int, _ a: Float) {
            guard x >= 0, x < s, y >= 0, y < s else { return }
            px[y * s + x] = mixRGBA(px[y * s + x], color, a)
        }
        let R = Float(r), top: Float = 4.712389            // gap at the top of the ring
        let steps = r * 10
        for k in 0..<steps {
            let ang = Float(k) / Float(steps) * 6.2831853
            var d = abs(ang - top); if d > 3.14159 { d = 6.2831853 - d }
            if d < 0.5 { continue }
            for w in 0..<2 {
                put(cx + Int(cosf(ang) * (R - Float(w))), cy + Int(sinf(ang) * (R - Float(w))), 0.8)
            }
        }
        let ir = R * 0.52                                  // inner dome (upper arc)
        for k in 0...steps {
            let ang = 3.14159 + Float(k) / Float(steps) * 3.14159
            for w in 0..<2 {
                put(cx + Int(cosf(ang) * (ir - Float(w))), cy + Int(sinf(ang) * (ir - Float(w)) - R * 0.04), 0.8)
            }
        }
        let scale = 2                                      // "ARC", the game's own pixel font
        px.withUnsafeMutableBufferPointer { buf in
            Font.draw("ARC", into: buf.baseAddress!, w: s, h: s,
                      x: cx - Font.width("ARC", scale: scale) / 2, y: cy + Int(R * 0.06),
                      scale: scale, color: color, shadow: nil, alpha: 0.85)
        }
    }

    private func reliefStrength(flat tex: FlatTex) -> Float {
        switch tex {
        case .rock: return 1.4
        case .ceilStone: return 1.2
        case .metalFloor: return 0.9
        case .concrete: return 0.8
        case .ceilTech: return 0.6
        case .ceilWhite: return 0.35
        case .grate: return 0.5
        case .ceilDark: return 0.4
        case .teleportPad: return 0.35       // machined plate — the rings do the talking
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
            case .ceilWhite:
                let cx = x % 128, cy = y % 128
                var o = Int((fbm(Float(x) / 34, Float(y) / 34, 16, 137) - 0.5) * 10)
                if cx < 2 || cy < 2 { o -= 20 }                                          // panel grid joint
                set(x, y, rgb(198 + o, 200 + o, 198 + o))
                if cy >= 46 && cy <= 82 {                                                // recessed light run
                    let g = 224 + Int(fbm(Float(x) / 7, Float(y) / 7, 16, 139) * 26)
                    set(x, y, rgb(g, g, g - 6))
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
            case .teleportPad:
                // the planet-jump pad: dark machined plate under concentric
                // emitter rings that glow teleport-cold, a bright focus disc at
                // centre. One cell = one tile, so the pattern is authored to the
                // full tile: rings at fixed radii from the tile centre.
                let fx = Float(x) - Float(s) / 2 + 0.5, fy = Float(y) - Float(s) / 2 + 0.5
                let rr = (fx * fx + fy * fy).squareRoot() / (Float(s) / 2)   // 0 centre … 1 tile edge
                var o = Int((fbm(Float(x) / 22, Float(y) / 22, 16, 51) - 0.5) * 12)
                var rc = 34 + o, gc = 38 + o, bc = 44 + o                    // base plate
                let ring = min(abs(rr - 0.82), min(abs(rr - 0.58), abs(rr - 0.34)))
                if ring < 0.035 {                                            // emitter rings
                    let core = 1 - ring / 0.035
                    rc = 60 + Int(core * 90); gc = 130 + Int(core * 95); bc = 160 + Int(core * 95)
                }
                if rr < 0.12 {                                               // the focus disc
                    let core = 1 - rr / 0.12
                    rc = 90 + Int(core * 70); gc = 170 + Int(core * 60); bc = 200 + Int(core * 55)
                }
                if rr > 0.94 { o -= 26; rc = 34 + o; gc = 38 + o; bc = 44 + o } // seated rim groove
                set(x, y, rgb(rc, gc, bc))
            }
        }}
        if reliefOn { applyRelief(&px, s, reliefStrength(flat: tex)) }
        return Texture(size: s, pixels: px)
    }
}
