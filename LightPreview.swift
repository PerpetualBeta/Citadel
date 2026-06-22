// Citadel — colored-lighting before/after proof (CITADEL_LIGHT[=dir]).
//
// NOT shipping code. Generates real levels, finds vantage points that face the
// fixtures that emit light, and renders each one twice through the actual
// raycaster — once with the old flat sector light, once with the new colored
// light field — composited side by side so the atmosphere gain is judged from
// real pixels, not argument.

import Foundation
import AppKit
import simd

enum LightPreview {

    static func run(outDir: String?) {
        let base = outDir ?? (NSHomeDirectory() + "/Desktop")
        let dir = URL(fileURLWithPath: base).appendingPathComponent("Citadel-Lighting")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // depth bands that exercise the three ambient palettes + different emitters.
        let scenes: [(level: Int, ci: Int, seed: UInt64, tag: String)] = [
            (1, 1, 0x1107, "SURFACE FACILITY"),
            (3, 4, 90210,  "INDUSTRIAL WORKINGS"),
            (7, 0, 0x4242, "THE DEPTHS"),
        ]

        var n = 0
        for sc in scenes {
            let world = World(level: sc.level, colonyIndex: sc.ci, seed: sc.seed)
            // a corridor first (the user's case — side-wall banding shows here),
            // then emitter-facing room views.
            let vantages = Array((corridorVantages(world.map, 2) + pickVantages(world.map, count: 2)).prefix(3))
            for (vi, v) in vantages.enumerated() {
                world.player.pos = v.pos
                world.player.dir = v.dir

                Raycaster.colored = true
                Raycaster.smoothLight = false
                let before = Canvas2D(); Raycaster().render(world, into: before)
                Raycaster.smoothLight = true
                let after = Canvas2D(); Raycaster().render(world, into: after)

                let sheet = compose(before: before, after: after,
                                    title: "\(sc.tag)   ·   DEPTH \(sc.level)   ·   view \(vi + 1)")
                n += 1
                let name = String(format: "%02d-%@-%d.png", n, slug(sc.tag), vi + 1)
                Captures.writePNG(sheet.framebuffer, w: sheet.width, h: sheet.height, scale: 2,
                                  to: dir.appendingPathComponent(name))
                print("  wrote \(name)")
            }
        }
        corpseProof(dir, index: n + 1)
        steamProof(dir, index: n + 2)
        dynLightProof(dir, index: n + 3)
        worldAAProof(dir, index: n + 5)
        closeCorpse(dir, index: n + 6)
        Raycaster.colored = true; Raycaster.smoothLight = true; Raycaster.worldAA = true
        print("Citadel: lighting comparison written to \(dir.path)")
    }

    // ── vantage selection ──────────────────────────────────────────────────────
    private struct Vantage { let pos: SIMD2<Float>; let dir: Float }

    /// Find open cells that face an emitter at a flattering distance.
    private static func pickVantages(_ map: GameMap, count: Int) -> [Vantage] {
        let emitters = emitterCells(map)
        var out: [Vantage] = []
        let dirs8: [(Int, Int)] = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, 1), (1, -1), (-1, -1)]

        for (ex, ey) in emitters {
            var placed = false
            for dist in [4, 5, 3, 6] where !placed {
                for (dx, dy) in dirs8 where !placed {
                    let sx = ex + dx * dist, sy = ey + dy * dist
                    guard map.inBounds(sx, sy), map.wall[map.idx(sx, sy)] == 0 else { continue }
                    guard los(map, sx, sy, ex, ey) else { continue }
                    // not too close to a vantage we already kept
                    let pos = SIMD2<Float>(Float(sx) + 0.5, Float(sy) + 0.5)
                    if out.contains(where: { simd_distance($0.pos, pos) < 5 }) { continue }
                    let dir = atan2(Float(ey) + 0.5 - pos.y, Float(ex) + 0.5 - pos.x)
                    out.append(Vantage(pos: pos, dir: dir))
                    placed = true
                }
            }
            if out.count >= count { break }
        }
        if out.isEmpty {   // fallback: spawn point, spawn facing
            out.append(Vantage(pos: map.playerStart, dir: map.playerDir))
        }
        return out
    }

    /// Stand in 1-wide corridors looking down their length — where wall cells
    /// step in brightness, so the smoothing shows.
    private static func corridorVantages(_ map: GameMap, _ count: Int) -> [Vantage] {
        var out: [Vantage] = []
        func runLen(_ x: Int, _ y: Int, _ dx: Int, _ dy: Int) -> Int {
            var n = 0, cx = x + dx, cy = y + dy
            while map.inBounds(cx, cy) && map.wall[map.idx(cx, cy)] == 0 { n += 1; cx += dx; cy += dy }
            return n
        }
        for y in 1..<(map.h - 1) { for x in 1..<(map.w - 1) {
            if map.wall[map.idx(x, y)] != 0 { continue }
            let wL = map.wall[map.idx(x - 1, y)] != 0, wR = map.wall[map.idx(x + 1, y)] != 0
            let wU = map.wall[map.idx(x, y - 1)] != 0, wD = map.wall[map.idx(x, y + 1)] != 0
            let pos = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
            var dir: Float? = nil
            if wU && wD && !wL && !wR, max(runLen(x, y, 1, 0), runLen(x, y, -1, 0)) >= 4 {
                dir = runLen(x, y, 1, 0) >= runLen(x, y, -1, 0) ? 0 : .pi
            } else if wL && wR && !wU && !wD, max(runLen(x, y, 0, 1), runLen(x, y, 0, -1)) >= 4 {
                dir = runLen(x, y, 0, 1) >= runLen(x, y, 0, -1) ? .pi / 2 : -.pi / 2
            }
            guard let d = dir else { continue }
            if out.contains(where: { simd_distance($0.pos, pos) < 6 }) { continue }
            out.append(Vantage(pos: pos, dir: d))
            if out.count >= count { return out }
        }}
        return out
    }

    private static func emitterCells(_ map: GameMap) -> [(Int, Int)] {
        let litWalls: Set<Int> = [WallTex.litPanel, .computer, .glass, .exitSwitch,
                                  .doorRed, .doorBlue, .doorYellow].map { $0.rawValue }.reduce(into: Set<Int>()) { $0.insert($1) }
        let litFloors: Set<Int> = [FlatTex.nukage, .blood].map { $0.rawValue }.reduce(into: Set<Int>()) { $0.insert($1) }
        var cells: [(Int, Int)] = []
        for y in 0..<map.h { for x in 0..<map.w {
            let i = map.idx(x, y)
            if map.wall[i] != 0 { if litWalls.contains(map.wall[i]) { cells.append((x, y)) } }
            else if litFloors.contains(map.floor[i]) { cells.append((x, y)) }
        }}
        return cells
    }

    private static func los(_ map: GameMap, _ ax: Int, _ ay: Int, _ bx: Int, _ by: Int) -> Bool {
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

    // ── side-by-side composite ──────────────────────────────────────────────────
    private static func compose(before: Canvas2D, after: Canvas2D, title: String,
                                leftLabel: String = "BEFORE — blocky per-cell light",
                                rightLabel: String = "AFTER — smooth interpolated light") -> Canvas2D {
        let viewH = RenderConfig.viewHeight          // the 3-D viewport (top rows)
        let viewW = RenderConfig.width
        let margin = 12, gap = 16, top = 42, capH = 26
        let W = margin + viewW + gap + viewW + margin
        let H = top + viewH + capH
        let c = Canvas2D(width: W, height: H)
        c.clear(packRGBA(14, 14, 18))
        c.label(title, margin, 12, size: 22, color: packRGBA(240, 200, 110), weight: .heavy)

        copyView(before, into: c, dx: margin, dy: top, h: viewH)
        copyView(after, into: c, dx: margin + viewW + gap, dy: top, h: viewH)
        c.strokeRect(margin - 1, top - 1, viewW + 2, viewH + 2, packRGBA(60, 62, 74))
        c.strokeRect(margin + viewW + gap - 1, top - 1, viewW + 2, viewH + 2, packRGBA(60, 62, 74))

        c.label(leftLabel, margin + 6, top + viewH + 4, size: 16,
                color: packRGBA(150, 154, 168), weight: .bold)
        c.label(rightLabel, margin + viewW + gap + 6, top + viewH + 4, size: 16,
                color: packRGBA(150, 220, 160), weight: .bold)
        return c
    }

    /// Copy the top `h` rows (the 3-D view) of a render into the sheet.
    private static func copyView(_ src: Canvas2D, into dst: Canvas2D, dx: Int, dy: Int, h: Int) {
        let w = src.width
        for y in 0..<h {
            let srow = y * w, drow = (dy + y) * dst.width + dx
            for x in 0..<w { dst.framebuffer[drow + x] = src.framebuffer[srow + x] }
        }
    }

    // ── corpse-in-toxic-pool proof ──────────────────────────────────────────────
    private static func corpseProof(_ dir: URL, index: Int) {
        let world = World(level: 3, colonyIndex: 4, seed: 90210)   // workings — reliable nukage
        let map = world.map
        func center(_ x: Int, _ y: Int) -> SIMD2<Float> { SIMD2(Float(x) + 0.5, Float(y) + 0.5) }

        // a nukage cell next to a dry open-floor cell — so one corpse melts, one doesn't.
        var pair: (Int, Int, Int, Int)? = nil
        search: for y in 1..<(map.h - 1) { for x in 1..<(map.w - 1) {
            guard map.wall[map.idx(x, y)] == 0, map.floor[map.idx(x, y)] == FlatTex.nukage.rawValue else { continue }
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let fx = x + dx, fy = y + dy
                if map.inBounds(fx, fy), map.wall[map.idx(fx, fy)] == 0,
                   map.floor[map.idx(fx, fy)] != FlatTex.nukage.rawValue { pair = (x, y, fx, fy); break search }
            }
        }}
        guard let (nx, ny, fx, fy) = pair else { print("  (no nukage/floor pair for corpse proof)"); return }

        var melt = Monster(kind: .alien, pos: center(nx, ny)); melt.state = .dead; melt.stateTime = 6; melt.health = 0
        var dry = Monster(kind: .alien, pos: center(fx, fy)); dry.state = .dead; dry.stateTime = 6; dry.health = 0
        world.monsters = [melt, dry]

        let mid = (center(nx, ny) + center(fx, fy)) * 0.5
        var v: Vantage? = nil
        outer: for dist in [2, 3, 4] {
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, 1), (1, -1), (-1, -1)] {
                let sx = nx + dx * dist, sy = ny + dy * dist
                guard map.inBounds(sx, sy), map.wall[map.idx(sx, sy)] == 0, los(map, sx, sy, nx, ny) else { continue }
                let pos = SIMD2<Float>(Float(sx) + 0.5, Float(sy) + 0.5)
                v = Vantage(pos: pos, dir: atan2(mid.y - pos.y, mid.x - pos.x)); break outer
            }
        }
        guard let van = v else { print("  (no corpse vantage)"); return }
        world.player.pos = van.pos; world.player.dir = van.dir

        Raycaster.colored = true; Raycaster.smoothLight = true
        let view = Canvas2D(); Raycaster().render(world, into: view)
        saveOne(view, dir: dir, name: String(format: "%02d-corpse-dissolve.png", index),
                title: "CORPSE IN TOXIC WASTE — dissolves into the pool",
                caption: "one corpse eaten away by the nukage · the other intact on dry floor")
    }

    // ── steam-vent proof ─────────────────────────────────────────────────────────
    private static func steamProof(_ dir: URL, index: Int) {
        let world = World(level: 3, colonyIndex: 4, seed: 90210)    // workings — abundant pipework vents
        world.monsters.removeAll()                                   // a clean shot of the steam
        let map = world.map
        guard let vent = world.steamVents.first else { print("  (no steam vents)"); return }
        let vx = Int(vent.pos.x), vy = Int(vent.pos.y)
        var van: Vantage? = nil
        outer: for dist in [4, 3, 5] {
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let sx = vx + dx * dist, sy = vy + dy * dist
                guard map.inBounds(sx, sy), map.wall[map.idx(sx, sy)] == 0, los(map, sx, sy, vx, vy) else { continue }
                let pos = SIMD2<Float>(Float(sx) + 0.5, Float(sy) + 0.5)
                van = Vantage(pos: pos, dir: atan2(vent.pos.y - pos.y, vent.pos.x - pos.x)); break outer
            }
        }
        let v = van ?? Vantage(pos: map.playerStart, dir: map.playerDir)
        world.player.pos = v.pos; world.player.dir = v.dir
        let input = InputState(); let audio = AudioEngine()
        for _ in 0..<110 { world.update(dt: 1.0 / 60, input: input, audio: audio) }   // let the steam build up
        world.player.pos = v.pos; world.player.dir = v.dir
        Raycaster.colored = true; Raycaster.smoothLight = true
        let view = Canvas2D(); Raycaster().render(world, into: view)
        saveOne(view, dir: dir, name: String(format: "%02d-steam-vents.png", index),
                title: "STEAM — venting from the facility pipework",
                caption: "pressurised vents hiss and jet into the corridors")
    }

    // ── dynamic-light proof (muzzle flash + projectile glow) ─────────────────────
    private static func dynLightProof(_ dir: URL, index: Int) {
        let world = World(level: 7, colonyIndex: 0, seed: 0x4242)   // dark depths — the flash pops
        world.monsters.removeAll()
        let map = world.map
        let van = corridorVantages(map, 1).first ?? pickVantages(map, count: 1).first
            ?? Vantage(pos: map.playerStart, dir: map.playerDir)
        world.player.pos = van.pos; world.player.dir = van.dir
        let fwd = SIMD2<Float>(cos(van.dir), sin(van.dir))
        // a brute a few cells ahead so the flash catches an enemy
        for d: Float in [3, 4, 2] {
            let a = van.pos + fwd * d, ax = Int(a.x), ay = Int(a.y)
            if map.inBounds(ax, ay), map.wall[map.idx(ax, ay)] == 0 {
                world.monsters = [Monster(kind: .alien, pos: SIMD2(Float(ax) + 0.5, Float(ay) + 0.5))]; break
            }
        }
        Raycaster.colored = true; Raycaster.smoothLight = true
        world.player.muzzle = 0
        let before = Canvas2D(); Raycaster().render(world, into: before)
        world.player.muzzle = 0.07
        let after = Canvas2D(); Raycaster().render(world, into: after)
        let sheet = compose(before: before, after: after, title: "MUZZLE FLASH — firing lights the walls & enemies",
                            leftLabel: "no flash", rightLabel: "firing — dynamic muzzle light")
        Captures.writePNG(sheet.framebuffer, w: sheet.width, h: sheet.height, scale: 2,
                          to: dir.appendingPathComponent(String(format: "%02d-muzzle-flash.png", index)))
        print("  wrote \(String(format: "%02d-muzzle-flash.png", index))")

        // a fireball glowing in the dark corridor
        world.player.muzzle = 0
        world.monsters.removeAll()
        world.projectiles = [Projectile(pos: van.pos + fwd * 3.5, vel: fwd * 6, kind: .fireball,
                                        damage: 0, fromPlayer: true, life: 5)]
        let pv = Canvas2D(); Raycaster().render(world, into: pv)
        saveOne(pv, dir: dir, name: String(format: "%02d-projectile-glow.png", index + 1),
                title: "PROJECTILE GLOW — a fireball lights the corridor as it flies",
                caption: "the bolt throws orange light onto the walls and floor around it")
    }

    // ── world edge-AA before/after (also catches objects + creatures) ────────────
    private static func worldAAProof(_ dir: URL, index: Int) {
        let world = World(level: 1, colonyIndex: 1, seed: 0x1107)   // bright facility — panels + tile floor show edges
        let map = world.map
        let van = corridorVantages(map, 1).first ?? pickVantages(map, count: 1).first
            ?? Vantage(pos: map.playerStart, dir: map.playerDir)
        world.player.pos = van.pos; world.player.dir = van.dir
        let fwd = SIMD2<Float>(cos(van.dir), sin(van.dir))
        // guarantee an object + a creature in frame so the AA shows on both
        world.monsters.removeAll(); world.items.removeAll()
        for (d, drop) in [(4, 0), (3, 1), (5, 0)] {
            let a = van.pos + fwd * Float(d), ax = Int(a.x), ay = Int(a.y)
            guard map.inBounds(ax, ay), map.wall[map.idx(ax, ay)] == 0 else { continue }
            let c = SIMD2<Float>(Float(ax) + 0.5, Float(ay) + 0.5)
            if drop == 0 { world.monsters = [Monster(kind: .alien, pos: c)] }
            else { world.items = [Item(kind: .medkit, pos: c, bob: 0)] }
        }
        Raycaster.colored = true; Raycaster.smoothLight = true
        Raycaster.worldAA = false
        let before = Canvas2D(); Raycaster().render(world, into: before)
        Raycaster.worldAA = true
        let after = Canvas2D(); Raycaster().render(world, into: after)
        let sheet = compose(before: before, after: after, title: "WORLD ANTI-ALIASING — walls, floor & objects",
                            leftLabel: "no AA — chunky edges", rightLabel: "edge-AA — softened")
        Captures.writePNG(sheet.framebuffer, w: sheet.width, h: sheet.height, scale: 2,
                          to: dir.appendingPathComponent(String(format: "%02d-world-aa.png", index)))
        print("  wrote \(String(format: "%02d-world-aa.png", index))")
    }

    // ── close corpse on dry floor (reproduce the "straight edge" report) ─────────
    private static func closeCorpse(_ dir: URL, index: Int) {
        let world = World(level: 1, colonyIndex: 1, seed: 0x1107)   // facility — metal tile floor
        let map = world.map
        let van = pickVantages(map, count: 1).first ?? Vantage(pos: map.playerStart, dir: map.playerDir)
        let fwd = SIMD2<Float>(cos(van.dir), sin(van.dir))
        var cpos = van.pos + fwd * 2.5
        for d: Float in [2.5, 2, 3, 3.5] {
            let a = van.pos + fwd * d, ax = Int(a.x), ay = Int(a.y)
            if map.inBounds(ax, ay), map.wall[map.idx(ax, ay)] == 0 { cpos = SIMD2(Float(ax) + 0.5, Float(ay) + 0.5); break }
        }
        var corpse = Monster(kind: .alien, pos: cpos)
        corpse.state = .dead; corpse.stateTime = 6; corpse.health = 0
        world.monsters = [corpse]; world.items.removeAll()
        world.player.pos = cpos - fwd * 1.7
        world.player.dir = van.dir
        Raycaster.colored = true; Raycaster.smoothLight = true; Raycaster.worldAA = true
        let v = Canvas2D(); Raycaster().render(world, into: v)
        saveOne(v, dir: dir, name: String(format: "%02d-close-corpse.png", index),
                title: "CLOSE CORPSE (dry floor) — checking the floor-contact edge",
                caption: "standing over a dead brute, as in the report")
    }

    /// Single-panel sheet: a titled, captioned 3-D view.
    private static func saveOne(_ view: Canvas2D, dir: URL, name: String, title: String, caption: String) {
        let viewH = RenderConfig.viewHeight, viewW = RenderConfig.width
        let margin = 12, top = 42, capH = 28
        let c = Canvas2D(width: margin * 2 + viewW, height: top + viewH + capH)
        c.clear(packRGBA(14, 14, 18))
        c.label(title, margin, 12, size: 22, color: packRGBA(240, 200, 110), weight: .heavy)
        copyView(view, into: c, dx: margin, dy: top, h: viewH)
        c.strokeRect(margin - 1, top - 1, viewW + 2, viewH + 2, packRGBA(60, 62, 74))
        c.label(caption, margin + 4, top + viewH + 5, size: 15, color: packRGBA(150, 200, 160), weight: .bold)
        Captures.writePNG(c.framebuffer, w: c.width, h: c.height, scale: 2, to: dir.appendingPathComponent(name))
        print("  wrote \(name)")
    }

    private static func slug(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: " ", with: "-")
    }
}
