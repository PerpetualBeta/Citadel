// Citadel — headless smoke test (CITADEL_SMOKE=1).
//
// Exercises the renderer-independent logic — procedural map generation +
// solvability, the game update loop (movement, AI, combat, scoring), the CPU
// raycaster + HUD draws, high-score persistence — and a best-effort GPU device
// check. Runs with no window; the GPU bit skips gracefully without Metal.

import Foundation
import Metal

enum SmokeTest {
    private static var failures = 0
    private static func check(_ cond: Bool, _ name: String) {
        print((cond ? "  ok   " : "  FAIL ") + name)
        if !cond { failures += 1 }
    }

    static func run() {
        print("Citadel smoke test")

        // 1. procedural generation across several depths / colonies
        var darkPockets = 0          // genuinely unlit walkable cells across the sweep
        for level in 1...6 {
            let g = MapGen.generate(level: level, colonyIndex: level - 1, seed: UInt64(level) &* 7919 &+ 13)
            let m = g.map
            let sx = Int(m.playerStart.x), sy = Int(m.playerStart.y)
            check(m.wall[m.idx(sx, sy)] == 0, "L\(level) player start is walkable")
            check(m.exitCell >= 0 && m.exitCell < m.wall.count, "L\(level) exit switch placed")
            check(!g.monsters.isEmpty, "L\(level) has monsters (\(g.monsters.count))")
            check(!g.items.isEmpty, "L\(level) has items (\(g.items.count))")
            // exit reachable from start (ignoring locks — MapGen already verifies keyed reachability)
            check(reachableIgnoringLocks(m), "L\(level) exit reachable from start")
            // count baked unlit floor — the headlamp's reason to exist
            for i in 0..<(m.w * m.h) where m.wall[i] == 0 && m.doors[i] == nil {
                let c = m.lightColor[i]
                if c.x * 0.299 + c.y * 0.587 + c.z * 0.114 < 0.10 { darkPockets += 1 }
            }
        }
        check(darkPockets > 0, "levels carry unlit pockets for the headlamp (\(darkPockets) dark cells)")

        // 2. game loop: run a world for a few seconds of simulated play
        let audio = AudioEngine()
        let input = InputState()
        let world = World(level: 2, colonyIndex: 0, seed: 4242)
        input.kb.forward = true
        input.kb.fire = true
        var frames = 0
        for _ in 0..<600 {           // ~10s at 60fps
            world.update(dt: 1.0 / 60, input: input, audio: audio)
            frames += 1
            if world.player.dead { break }
        }
        check(frames > 0, "world advanced \(frames) frames without crashing")
        check(world.score >= 0, "score is sane (\(world.score))")

        // force-kill a monster to exercise the death + scoring path
        if let i = world.monsters.firstIndex(where: { $0.alive }) {
            let before = world.killCount
            // big splash right on the monster
            world.projectiles.append(Projectile(pos: world.monsters[i].pos, vel: .zero,
                                                 kind: .rocket, damage: 999, fromPlayer: true, life: 0.01))
            world.update(dt: 0.05, input: InputState(), audio: audio)
            check(world.killCount >= before, "kill accounting ran")
            check(world.decals.contains { $0.w < 0 }, "kill stamps a blood decal at the site")
        }

        // 2b. flamethrower: standard issue, FINITE fuel, ignites + clears corpses
        let fw = World(level: 1, colonyIndex: 0, seed: 99)
        check(fw.player.has(.flamethrower), "flamethrower carried from the start")
        check(WeaponKind.flamethrower.def.ammo == .fuel, "flamethrower now runs on finite fuel")
        check(fw.player.ammoCount(.fuel) > 0, "marine starts with fuel (\(fw.player.ammoCount(.fuel)))")
        if let mi = fw.monsters.firstIndex(where: { $0.alive }) {
            let cpos = fw.monsters[mi].pos
            fw.projectiles.append(Projectile(pos: cpos, vel: .zero, kind: .rocket, damage: 999, fromPlayer: true, life: 0.01))
            for _ in 0..<40 { fw.update(dt: 1.0 / 60, input: InputState(), audio: audio) }   // die → corpse
            check(fw.monsters.contains { $0.state == .dead }, "killed monster leaves a corpse")
            fw.player.pos = cpos + SIMD2<Float>(0.9, 0)
            fw.player.dir = .pi                                     // face the corpse
            fw.player.current = .flamethrower
            let burn = InputState(); burn.kb.fire = true
            var ignited = false
            for _ in 0..<240 {
                fw.update(dt: 1.0 / 60, input: burn, audio: audio)
                if fw.monsters.contains(where: { $0.state == .dead && $0.burn > 0 }) { ignited = true }
                if fw.monsters.contains(where: { $0.state == .dead && $0.burn >= 1 }) { break }
            }
            check(ignited, "flamethrower ignites the corpse")
            check(fw.monsters.contains { $0.state == .dead && $0.burn >= 1 }, "corpse burns to charred remains")
            check(fw.decals.contains { $0.w > 0 }, "burned-out corpse stamps a scorch decal")
        }

        // 2d. rubble debris built at battle-damage sites (across several levels)
        var debrisPiles = 0
        for lvl in 1...6 {
            let w = World(level: lvl, colonyIndex: lvl - 1, seed: UInt64(lvl) &* 31 &+ 5)
            debrisPiles += w.debris.count
        }
        check(debrisPiles > 0, "rubble debris built at shattered fixtures (\(debrisPiles) piles)")

        // 2e. enemy AI: a clump of drones disperses (boid separation / anti-clump)
        let aw = World(level: 1, colonyIndex: 0, seed: 7)
        let cc = aw.player.pos + SIMD2<Float>(-3, 0)
        aw.monsters = (0..<5).map { k in
            var m = Monster(kind: .alien, pos: cc + SIMD2(Float(k) * 0.05, 0)); m.awake = true; m.state = .chase; return m
        }
        func minPairDist(_ ms: [Monster]) -> Float {
            var mn = Float.greatestFiniteMagnitude
            for a in 0..<ms.count { for b in (a + 1)..<ms.count { mn = min(mn, vlen(ms[a].pos - ms[b].pos)) } }
            return mn
        }
        let gap0 = minPairDist(aw.monsters)
        for _ in 0..<120 { aw.update(dt: 1.0 / 60, input: InputState(), audio: audio) }
        let gap1 = minPairDist(aw.monsters)
        check(gap1 > gap0 * 3, "clumped drones separate (min gap \(String(format: "%.2f", gap0)) → \(String(format: "%.2f", gap1)))")

        // 2f. a lone drone (last one alive) commits to the hunt and closes to melee
        let kw = World(level: 1, colonyIndex: 0, seed: 11)
        var dr = Monster(kind: .alien, pos: kw.player.pos + SIMD2<Float>(2.0, 0)); dr.awake = true; dr.state = .chase
        kw.monsters = [dr]
        let d0 = vlen(kw.monsters[0].pos - kw.player.pos)
        for _ in 0..<150 { kw.update(dt: 1.0 / 60, input: InputState(), audio: audio) }
        let d1 = vlen(kw.monsters[0].pos - kw.player.pos)
        check(d1 < d0 - 0.8, "a lone drone commits and closes in (\(String(format: "%.2f", d0)) → \(String(format: "%.2f", d1)))")

        // 2g. the Queen: only plasma wounds her, she must be killed AND burned, and
        // the exit stays locked until she is ash.
        let qw = World(level: 3, colonyIndex: 0, seed: 4242)
        if let qi0 = qw.monsters.firstIndex(where: { $0.kind == .queen }) {
            let qpos = qw.monsters[qi0].pos, h0 = qw.monsters[qi0].health
            check(!qw.queenDefeated, "a live Queen means the objective isn't met")
            // explosives wound her (they're heat) but can never land the kill
            qw.projectiles.append(Projectile(pos: qpos, vel: .zero, kind: .rocket, damage: 999, fromPlayer: true, life: 0.01))
            qw.update(dt: 0.05, input: InputState(), audio: audio)
            let q1 = qw.monsters.first { $0.kind == .queen }!
            check(q1.alive && q1.health < h0, "explosives wound the Queen (\(h0) → \(q1.health))")
            for _ in 0..<25 {                                      // a whole barrage still can't finish her
                guard let q = qw.monsters.first(where: { $0.kind == .queen }), q.alive else { break }
                qw.projectiles.append(Projectile(pos: q.pos, vel: .zero, kind: .rocket, damage: 999, fromPlayer: true, life: 0.01))
                qw.update(dt: 0.05, input: InputState(), audio: audio)
            }
            check(qw.monsters.contains { $0.kind == .queen && $0.alive }, "explosives alone cannot kill the Queen")
            // plasma puts her down
            for _ in 0..<40 {
                guard let q = qw.monsters.first(where: { $0.kind == .queen }), q.alive else { break }
                qw.projectiles.append(Projectile(pos: q.pos, vel: .zero, kind: .plasma, damage: 999, fromPlayer: true, life: 0.01))
                qw.update(dt: 0.05, input: InputState(), audio: audio)
            }
            check(qw.monsters.contains { $0.kind == .queen && !$0.alive }, "plasma puts the Queen down")
            check(!qw.queenDefeated, "a downed-but-unburned Queen is still not defeated")
            // torch the body → she's finished and the exit unlocks
            if let qd = qw.monsters.firstIndex(where: { $0.kind == .queen }) { qw.monsters[qd].burn = 0.06 }
            for _ in 0..<200 { qw.update(dt: 1.0 / 60, input: InputState(), audio: audio) }
            check(qw.queenDefeated, "a burned Queen meets the objective (exit unlocks)")
        } else { check(false, "level seeded a Queen") }

        // 2g2. the Queen (radius 0.72) must spawn with clearance — never wedged in
        // a wall. She gates the exit, so an unreachable Queen = an unwinnable level.
        var queenWedged = 0
        for lvl in 1...6 {
            let w = World(level: lvl, colonyIndex: lvl - 1, seed: UInt64(lvl) &* 71 &+ 3)
            guard let q = w.monsters.first(where: { $0.kind == .queen }) else { continue }
            let cx = Int(q.pos.x), cy = Int(q.pos.y)
            if w.map.blocksMovement(cx, cy) { queenWedged += 1; continue }    // standing in solid
            let nbrsOpen = [(cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1)]
                .reduce(0) { $0 + (w.map.blocksMovement($1.0, $1.1) ? 0 : 1) }
            if nbrsOpen < 3 { queenWedged += 1 }                              // boxed against walls
        }
        check(queenWedged == 0, "the Queen always spawns with clearance (\(queenWedged) wedged)")

        // 2h. resource props — fuel drums (refuel + shoot-to-detonate) and the
        // deployable proximity mine.
        var drumLevels = 0, drumOnItem = 0
        for lvl in 1...6 {
            let w = World(level: lvl, colonyIndex: lvl - 1, seed: UInt64(lvl) &* 53 &+ 9)
            if !w.drums.isEmpty { drumLevels += 1 }
            // a SOLID drum sitting on a pickup walls it off — must never happen
            for d in w.drums { for it in w.items where vlen(d.pos - it.pos) < 0.9 { drumOnItem += 1 } }
        }
        check(drumLevels == 6, "every level places fuel drums (\(drumLevels)/6)")
        check(drumOnItem == 0, "no fuel drum is stacked on a pickup (\(drumOnItem) overlaps)")

        // a shot drum ruptures in a fierce blast that clears nearby aliens
        let dw = World(level: 2, colonyIndex: 0, seed: 1234)
        dw.drums = [Drum(pos: dw.player.pos + SIMD2<Float>(3, 0), fuel: 150, health: 24)]
        var dz = Monster(kind: .alien, pos: dw.player.pos + SIMD2<Float>(3.4, 0)); dz.awake = true
        dw.monsters = [dz]
        dw.projectiles.append(Projectile(pos: dw.drums[0].pos, vel: .zero, kind: .rocket, damage: 90, fromPlayer: true, life: 0.01))
        for _ in 0..<8 { dw.update(dt: 1.0 / 60, input: InputState(), audio: audio) }
        check(dw.drums.isEmpty, "a shot fuel drum ruptures")
        check(dw.monsters.allSatisfy { !$0.alive }, "the drum blast kills aliens in radius")
        check(dw.decals.contains { $0.w > 0 }, "a drum rupture stamps a scorch decal")

        // standing at a drum pumps fuel into the flamethrower, draining the drum
        let rw = World(level: 1, colonyIndex: 0, seed: 77)
        rw.drums = [Drum(pos: rw.player.pos + SIMD2<Float>(0.7, 0), fuel: 150, health: 24)]
        rw.player.ammo[AmmoType.fuel.rawValue] = 10
        let fuel0 = rw.player.ammoCount(.fuel)
        for _ in 0..<60 { rw.update(dt: 1.0 / 60, input: InputState(), audio: audio) }
        check(rw.player.ammoCount(.fuel) > fuel0, "a drum refuels the flamethrower (\(fuel0) → \(rw.player.ammoCount(.fuel)))")
        check(rw.drums.first.map { $0.fuel < 150 } ?? true, "the drum's reserve drains as it refuels")

        // deploy a proximity mine, walk a drone onto it → it arms and detonates
        let mw = World(level: 1, colonyIndex: 0, seed: 88)
        mw.player.mines = 3
        let deploy = InputState(); deploy.kb.deployMine = true
        mw.update(dt: 1.0 / 60, input: deploy, audio: audio)        // edge press → drop one
        check(mw.deployedMines.count == 1 && mw.player.mines == 2, "deploying drops one mine and spends one")
        let minePos = mw.deployedMines[0].pos
        var ma = Monster(kind: .alien, pos: minePos + SIMD2<Float>(0.05, 0)); ma.awake = true
        mw.monsters = [ma]
        for _ in 0..<150 { mw.update(dt: 1.0 / 60, input: InputState(), audio: audio) }
        check(mw.deployedMines.isEmpty, "an armed mine detonates when an alien crosses it")
        check(mw.monsters.allSatisfy { !$0.alive }, "the mine blast kills the alien")

        // 2i. centre-split doors: the two panels part down the middle and the slit
        // is see-through. Same camera, same door — opening it must push the centre
        // column's depth PAST the door plane (the room behind shows through the gap).
        let zw = World(level: 2, colonyIndex: 1, seed: 24680)
        let zmap = zw.map
        func clearRunZ(_ dx: Int, _ dy: Int, _ ax: Int, _ ay: Int) -> Bool {
            for k in 1...3 where zmap.wallAt(dx + ax * k, dy + ay * k) != 0 || zmap.isDoorCell(dx + ax * k, dy + ay * k) { return false }
            return true
        }
        var sawDoor = false
        for di in zmap.doors.keys.sorted() {
            let dx = di % zmap.w, dy = di / zmap.w
            let ax: Int, ay: Int
            if clearRunZ(dx, dy, -1, 0) && clearRunZ(dx, dy, 1, 0) { ax = -1; ay = 0 }
            else if clearRunZ(dx, dy, 0, -1) && clearRunZ(dx, dy, 0, 1) { ax = 0; ay = -1 }
            else { continue }
            zw.player.pos = SIMD2(Float(dx + ax * 2) + 0.5, Float(dy + ay * 2) + 0.5)
            zw.player.dir = atan2(Float(-ay), Float(-ax))           // square on to the door
            let cx = RenderConfig.width / 2
            let cz = Canvas2D()
            zmap.doors[di]!.open = 0
            Raycaster().render(zw, into: cz)
            let zClosed = cz.zbuffer[cx]
            zmap.doors[di]!.open = 0.6
            Raycaster().render(zw, into: cz)
            let zOpen = cz.zbuffer[cx]
            check(zOpen > zClosed + 0.5, "a parted door reveals the room behind it (depth \(String(format: "%.1f", zClosed)) → \(String(format: "%.1f", zOpen)))")
            sawDoor = true
            break
        }
        check(sawDoor, "found a clean door to exercise the centre-split")

        // 3. CPU render path (no Metal needed)
        let canvas = Canvas2D()
        Raycaster().render(world, into: canvas)
        HUD().draw(world, into: canvas)
        var nonBlack = 0
        for i in 0..<(RenderConfig.width * RenderConfig.height) where (canvas.framebuffer[i] & 0x00FF_FFFF) != 0 { nonBlack += 1 }
        check(nonBlack > 5000, "raycaster + HUD drew a frame (\(nonBlack) lit pixels)")

        // front-end screens shouldn't crash
        FrontEnd.title(canvas, t: 1.0, hs: HighScores(fileURL: tmpURL()))
        FrontEnd.intel(canvas, t: 1.0)
        check(true, "front-end screens drew")

        // automap overlay (world ran above, so cells are visited → fog reveals)
        let visitedCells = world.map.visited.lazy.enumerated().filter { $0.element && world.map.wall[$0.offset] == 0 }.count
        canvas.clear()
        Automap.draw(world, into: canvas, t: 0.0)
        var mapLit = 0
        for i in 0..<(RenderConfig.width * RenderConfig.height) where (canvas.framebuffer[i] & 0x00FF_FFFF) != 0 { mapLit += 1 }
        check(visitedCells > 0, "automap has explored cells to reveal (\(visitedCells))")
        check(mapLit > 2000, "automap drew the level overview (\(mapLit) lit pixels)")

        // 4. high-score persistence round-trip
        let url = tmpURL()
        try? FileManager.default.removeItem(at: url)
        let hs1 = HighScores(fileURL: url)
        hs1.add(name: "MARINE 😀", score: 12345, depth: 4, colony: "VULCAN", stardate: "20260620::1200")
        hs1.add(name: "RIP", score: 500, depth: 1, colony: "DEMETER")
        let hs2 = HighScores(fileURL: url)
        check(hs2.entries.count == 2, "high scores persisted + reloaded")
        check(hs2.entries.first?.score == 12345, "high scores sorted descending")
        try? FileManager.default.removeItem(at: url)

        // 5. best-effort GPU device check
        if let dev = MTLCreateSystemDefaultDevice() {
            check(dev.makeCommandQueue() != nil, "Metal device + command queue available")
        } else {
            print("  skip  no Metal device (headless) — GPU path not exercised")
        }

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }

    private static func tmpURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("citadel-smoke-scores.json")
    }

    /// Flood fill from start treating any door as passable; confirms the exit
    /// switch has an adjacent reachable cell.
    private static func reachableIgnoringLocks(_ m: GameMap) -> Bool {
        let start = m.idx(Int(m.playerStart.x), Int(m.playerStart.y))
        var seen = [Bool](repeating: false, count: m.wall.count)
        var q = [start]; seen[start] = true; var qi = 0
        func passable(_ c: Int) -> Bool { m.wall[c] == 0 || m.doors[c] != nil }
        while qi < q.count {
            let cell = q[qi]; qi += 1
            let x = cell % m.w, y = cell / m.w
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                guard m.inBounds(nx, ny) else { continue }
                let n = m.idx(nx, ny)
                if !seen[n] && passable(n) { seen[n] = true; q.append(n) }
            }
        }
        let ex = m.exitCell % m.w, ey = m.exitCell / m.w
        for (nx, ny) in [(ex - 1, ey), (ex + 1, ey), (ex, ey - 1), (ex, ey + 1)] where m.inBounds(nx, ny) {
            if seen[m.idx(nx, ny)] { return true }
        }
        return false
    }
}
