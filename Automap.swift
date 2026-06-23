// Citadel — full-screen automap.
//
// A frozen, top-down overview of the current level drawn over the dimmed 3-D
// view (Tab, or the bound pad button, toggles it; Esc also closes). Fog-of-war:
// only walls bordering cells the marine has actually walked through are drawn —
// GameMap.visited is stamped per step in World.update. North is up; the player
// arrow points the way the camera faces. Keys still on the floor and the level
// exit are flagged once their cell has been seen, so it doubles as a nav aid.
//
// Walls between grid cells are always axis-aligned, so they paint as crisp 2-px
// fills rather than Bresenham lines; only the player arrow is diagonal.

import Foundation
import Metal

enum Automap {
    static let W = RenderConfig.width
    static let H = RenderConfig.height

    private static let amber = packRGBA(240, 196, 96)
    private static let ink = packRGBA(206, 210, 220)
    private static let dim = packRGBA(150, 154, 168)
    private static let wallCol = packRGBA(120, 150, 196)   // explored steelwork
    private static let floorCol = packRGBA(40, 52, 70)     // explored floor wash
    private static let doorCol = packRGBA(232, 196, 96)    // unlocked door
    private static let player = packRGBA(120, 240, 150)
    private static let exitCol = packRGBA(96, 226, 120)

    static func draw(_ world: World, into c: Canvas2D, t: Float) {
        let map = world.map

        // dim the live view to a near-black plate so the lines read cleanly
        c.fillRectBlend(0, 0, W, H, packRGBA(6, 8, 14), 0.84)

        // fit the whole grid (square cells) into the area between header & footer
        let top = uiS(72), bottom = uiS(46), side = uiS(40)
        let availW = W - 2 * side, availH = H - top - bottom
        let s = min(Float(availW) / Float(map.w), Float(availH) / Float(map.h))
        let ox = Float(side) + (Float(availW) - s * Float(map.w)) / 2
        let oy = Float(top) + (Float(availH) - s * Float(map.h)) / 2
        func sxF(_ wx: Float) -> Float { ox + wx * s }
        func syF(_ wy: Float) -> Float { oy + wy * s }
        func SX(_ wx: Float) -> Int { Int(sxF(wx).rounded()) }
        func SY(_ wy: Float) -> Int { Int(syF(wy).rounded()) }

        func isSolid(_ x: Int, _ y: Int) -> Bool { !map.inBounds(x, y) || map.wall[map.idx(x, y)] != 0 }
        func edgeColor(_ x: Int, _ y: Int) -> UInt32 {
            guard map.inBounds(x, y), let d = map.doors[map.idx(x, y)] else { return wallCol }
            if let lock = d.locked { return keyTint(lock) }
            return doorCol
        }

        // explored floor wash + the walls that border explored floor (fog-of-war)
        var explored = 0, totalFloor = 0
        let th = max(1, uiS(2))
        for y in 0..<map.h {
            for x in 0..<map.w {
                let i = map.idx(x, y)
                if map.wall[i] == 0 { totalFloor += 1 }
                guard map.visited[i], map.wall[i] == 0 else { continue }
                explored += 1
                let x0 = SX(Float(x)), x1 = SX(Float(x + 1)), y0 = SY(Float(y)), y1 = SY(Float(y + 1))
                c.fillRectBlend(x0, y0, x1 - x0, y1 - y0, floorCol, 0.55)
                if isSolid(x + 1, y) { c.fillRect(x1 - th / 2, y0, th, y1 - y0, edgeColor(x + 1, y)) }   // east
                if isSolid(x - 1, y) { c.fillRect(x0 - th / 2, y0, th, y1 - y0, edgeColor(x - 1, y)) }   // west
                if isSolid(x, y + 1) { c.fillRect(x0, y1 - th / 2, x1 - x0, th, edgeColor(x, y + 1)) }   // south
                if isSolid(x, y - 1) { c.fillRect(x0, y0 - th / 2, x1 - x0, th, edgeColor(x, y - 1)) }   // north
            }
        }

        // the exit switch, once its cell has been glimpsed from an explored neighbour
        if map.inBounds(map.exitCell % map.w, map.exitCell / map.w), map.exitCell >= 0 {
            let ex = map.exitCell % map.w, ey = map.exitCell / map.w
            let seen = [(1, 0), (-1, 0), (0, 1), (0, -1)].contains {
                map.inBounds(ex + $0.0, ey + $0.1) && map.visited[map.idx(ex + $0.0, ey + $0.1)]
            }
            if seen {
                let cx = SX(Float(ex) + 0.5), cy = SY(Float(ey) + 0.5)
                marker(c, cx, cy, uiS(6), exitCol)
                c.labelCentered2("EXIT", cx - uiS(20), uiS(40), cy - uiS(24), size: uiSf(13), color: exitCol, weight: .bold)
            }
        }

        // keys still on the floor (navigation-critical), once their cell is seen
        for it in world.items where !it.taken {
            guard let kc = keyColorOf(it.kind) else { continue }
            let cx = Int(it.pos.x), cy = Int(it.pos.y)
            guard map.inBounds(cx, cy), map.visited[map.idx(cx, cy)] else { continue }
            marker(c, SX(it.pos.x), SY(it.pos.y), uiS(5), keyTint(kc))
        }

        // player arrow — points the way the camera faces
        drawArrow(c, sxF(world.player.pos.x), syF(world.player.pos.y), world.player.dir, s * 0.62)

        // header + footer
        c.labelCentered("AUTOMAP", uiS(16), size: uiSf(30), color: amber, weight: .heavy)
        c.labelCentered("\(world.colonyName) · FLOOR \(Progression.floorInBuilding(world.level))", uiS(50), size: uiSf(16), color: dim, weight: .semibold)
        let pct = totalFloor > 0 ? Int((Float(explored) / Float(totalFloor) * 100).rounded()) : 0
        c.labelRight("EXPLORED \(pct)%", W - side, uiS(22), size: uiSf(15), color: dim, weight: .medium)
        keyLegend(c, world.player.keys, side, uiS(22))
        if Int(t * 2) % 2 == 0 {
            c.labelCentered("TAB OR ESC  ·  CLOSE", H - uiS(30), size: uiSf(18), color: ink, weight: .semibold)
        }
    }

    // ── helpers ────────────────────────────────────────────────────────────

    private static func keyColorOf(_ k: ItemKind) -> KeyColor? {
        switch k {
        case .keyRed: return .red
        case .keyBlue: return .blue
        case .keyYellow: return .yellow
        default: return nil
        }
    }
    private static func keyTint(_ k: KeyColor) -> UInt32 {
        switch k {
        case .red: return packRGBA(226, 60, 56)
        case .blue: return packRGBA(84, 124, 236)
        case .yellow: return packRGBA(234, 204, 60)
        }
    }

    /// Filled square pip with a white outline (keys / exit).
    private static func marker(_ c: Canvas2D, _ cx: Int, _ cy: Int, _ half: Int, _ col: UInt32) {
        c.fillRect(cx - half, cy - half, half * 2, half * 2, col)
        c.strokeRect(cx - half, cy - half, half * 2, half * 2, packRGBA(255, 255, 255))
    }

    /// A solid triangular marine arrow, drawn a touch thick for legibility.
    private static func drawArrow(_ c: Canvas2D, _ px: Float, _ py: Float, _ dir: Float, _ r: Float) {
        let tip = (px + cosf(dir) * r, py + sinf(dir) * r)
        let lf = (px + cosf(dir + 2.45) * r, py + sinf(dir + 2.45) * r)
        let rt = (px + cosf(dir - 2.45) * r, py + sinf(dir - 2.45) * r)
        let tail = (px - cosf(dir) * r * 0.35, py - sinf(dir) * r * 0.35)
        for off in [(0, 0), (1, 0), (0, 1)] {   // 2-px stroke
            let dx = off.0, dy = off.1
            c.line(Int(tip.0) + dx, Int(tip.1) + dy, Int(lf.0) + dx, Int(lf.1) + dy, player)
            c.line(Int(tip.0) + dx, Int(tip.1) + dy, Int(rt.0) + dx, Int(rt.1) + dy, player)
            c.line(Int(lf.0) + dx, Int(lf.1) + dy, Int(tail.0) + dx, Int(tail.1) + dy, player)
            c.line(Int(rt.0) + dx, Int(rt.1) + dy, Int(tail.0) + dx, Int(tail.1) + dy, player)
        }
    }

    /// Held-key pips, top-left, matching the status-bar order.
    private static func keyLegend(_ c: Canvas2D, _ held: Set<KeyColor>, _ x: Int, _ y: Int) {
        var kx = x
        for kc in [KeyColor.red, .blue, .yellow] {
            let col = keyTint(kc)
            c.fillRect(kx, y, uiS(12), uiS(15), held.contains(kc) ? col : shade(col, 0.20))
            if held.contains(kc) { c.strokeRect(kx, y, uiS(12), uiS(15), packRGBA(255, 255, 255)) }
            kx += uiS(16)
        }
    }

    // ── headless dev proof (CITADEL_AUTOMAP) ─────────────────────────────────
    // Renders the automap over the real CPU draw path at two reveal levels, so
    // the transform / fog-of-war / markers can be eyeballed without a window.
    static func run(outDir: String?) {
        let dir = URL(fileURLWithPath: outDir ?? NSHomeDirectory() + "/Desktop/Citadel-Automap")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let gpu = MTLCreateSystemDefaultDevice().flatMap { GPUWorldRenderer(device: $0) }
        for (name, frac) in [("full", 1.0), ("partial", 0.45)] {
            let world = World(level: 3, colonyIndex: 2, seed: 4242)
            revealFraction(world.map, frac)
            let canvas = Canvas2D()
            _ = gpu?.render(world, into: canvas)
            draw(world, into: canvas, t: 0.0)
            Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.height,
                              scale: 1, to: dir.appendingPathComponent("automap-\(name).png"))
            print("  wrote automap-\(name).png")
        }
        print("Citadel: automap proofs written to \(dir.path)")
    }

    /// Flood-fill `visited` from the player start over walkable floor up to a
    /// fraction of the reachable area — mimics partial exploration.
    private static func revealFraction(_ m: GameMap, _ frac: Double) {
        let start = m.idx(Int(m.playerStart.x), Int(m.playerStart.y))
        let totalFloor = m.wall.filter { $0 == 0 }.count
        let target = max(1, Int(Double(totalFloor) * frac))
        var q = [start]; var qi = 0; var count = 1
        m.visited[start] = true
        while qi < q.count && count < target {
            let cell = q[qi]; qi += 1
            let x = cell % m.w, y = cell / m.w
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                guard m.inBounds(nx, ny) else { continue }
                let n = m.idx(nx, ny)
                if !m.visited[n] && m.wall[n] == 0 {
                    m.visited[n] = true; q.append(n); count += 1
                    if count >= target { break }
                }
            }
        }
    }
}
