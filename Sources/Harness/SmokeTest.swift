// Citadel — headless smoke test (CITADEL_SMOKE=1).
//
// Exercises the renderer-independent logic — procedural map generation +
// solvability, the game update loop (movement, AI, combat, scoring), the CPU
// raycaster + HUD draws, high-score persistence — and a best-effort GPU device
// check. Runs with no window; the GPU bit skips gracefully without Metal.

import Foundation
import Metal
import simd

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
            let si = m.idx(sx, sy)
            check(m.wall[si] == 0 || (si == m.entryCell && m.doors[si] != nil),
                  "L\(level) player start is walkable (or the arrival car)")
            check(m.exitCell >= 0 && m.exitCell < m.wall.count, "L\(level) exit switch placed")
            check(!g.monsters.isEmpty, "L\(level) has monsters (\(g.monsters.count))")
            check(!g.items.isEmpty, "L\(level) has items (\(g.items.count))")
            // exit reachable from start (ignoring locks — MapGen already verifies keyed reachability)
            check(reachableIgnoringLocks(m), "L\(level) exit reachable from start")
            // side-by-side doors are mechanically impossible (leaves slide into
            // the jambs — adjacent doors have nowhere to go); the generator must
            // never produce them. And the exit must be a real elevator door.
            var adjacentDoors = 0
            for (di, _) in m.doors {
                let dx0 = di % m.w, dy0 = di / m.w
                for (ddx, ddy) in [(1, 0), (0, 1)] where m.inBounds(dx0 + ddx, dy0 + ddy) {
                    if m.doors[m.idx(dx0 + ddx, dy0 + ddy)] != nil { adjacentDoors += 1 }
                }
            }
            check(adjacentDoors == 0, "L\(level) no side-by-side doors")
            check(m.doors[m.exitCell] != nil, "L\(level) exit is an elevator (real door)")
            check(m.entryCell >= 0 && m.doors[m.entryCell] != nil, "L\(level) arrival elevator placed")
            // each car must be a sealed box: exactly ONE open neighbour (the
            // doorway) — an open jamb or back exposes the shaft interior
            var sealedCars = true
            for cell in [m.entryCell, m.exitCell] where cell >= 0 && m.doors[cell] != nil {
                let cx0 = cell % m.w, cy0 = cell / m.w
                var openN = 0
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] where m.inBounds(cx0 + dx, cy0 + dy) {
                    let ni = m.idx(cx0 + dx, cy0 + dy)
                    if m.wall[ni] == 0 || m.doors[ni] != nil { openN += 1 }
                }
                if openN != 1 { sealedCars = false }
            }
            check(sealedCars, "L\(level) elevator cars are sealed boxes")
            // …and their interiors are plain steel: no terminal bank (or other
            // fixture) may ever be stamped into a car's back or jamb walls
            var plainCars = true
            for cell in [m.entryCell, m.exitCell] where cell >= 0 && m.doors[cell] != nil {
                let cx0 = cell % m.w, cy0 = cell / m.w
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] where m.inBounds(cx0 + dx, cy0 + dy) {
                    if m.wall[m.idx(cx0 + dx, cy0 + dy)] == WallTex.computer.rawValue { plainCars = false }
                }
            }
            check(plainCars, "L\(level) no terminal banks inside the elevator cars")
            // a routed wall pipe must never run across a terminal bank's face
            var pipedBanks = 0
            for y in 0..<m.h { for x in 0..<m.w where m.pipe[m.idx(x, y)] >= 0.5 && m.wall[m.idx(x, y)] == 0 {
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] where m.inBounds(x + dx, y + dy) {
                    if m.wall[m.idx(x + dx, y + dy)] == WallTex.computer.rawValue { pipedBanks += 1 }
                }
            }}
            check(pipedBanks == 0, "L\(level) no pipework across terminal banks")
            // count baked unlit floor — the headlamp's reason to exist
            for i in 0..<(m.w * m.h) where m.wall[i] == 0 && m.doors[i] == nil {
                let c = m.lightColor[i]
                if c.x * 0.299 + c.y * 0.587 + c.z * 0.114 < 0.10 { darkPockets += 1 }
            }
        }
        check(darkPockets > 0, "levels carry unlit pockets for the headlamp (\(darkPockets) dark cells)")

        // the sealed-box invariant must hold across MANY seeds — later carving
        // (secret closets, fuel stores) once punched hidden rooms into a car
        var boxViolations = 0
        for sd in UInt64(1)...40 {
            let g2 = MapGen.generate(level: 3, colonyIndex: 0, seed: sd &* 733 &+ 7)
            let mm = g2.map
            for cell in [mm.entryCell, mm.exitCell] where cell >= 0 && mm.doors[cell] != nil {
                let bx = cell % mm.w, by = cell / mm.w
                var openN = 0
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] where mm.inBounds(bx + dx, by + dy) {
                    let ni = mm.idx(bx + dx, by + dy)
                    if mm.wall[ni] == 0 || mm.doors[ni] != nil { openN += 1 }
                }
                if openN != 1 { boxViolations += 1 }
            }
        }
        check(boxViolations == 0, "elevator boxes stay sealed across a 40-seed sweep (\(boxViolations) violated)")

        // carved side-chambers (secret closets + fuel stores) must be SEALED
        // boxes: every pocket cell's full 8-neighbourhood is solid apart from
        // its own door. An open orthogonal is a missing back wall; an open
        // DIAGONAL is a see-through corner slit (the SDF rounds wall corners).
        var pocketLeaks = 0, closetsSeen = 0, storesSeen = 0
        for sd in UInt64(1)...30 {
            for lv in [2, 5, 7] {
                let gp = MapGen.generate(level: lv, colonyIndex: Int(sd % 6), seed: sd &* 9241 &+ UInt64(lv))
                let mp = gp.map
                for (di, d) in mp.doors where d.secret || mp.wall[di] == WallTex.doorHazard.rawValue {
                    if d.secret { closetsSeen += 1 } else { storesSeen += 1 }
                    // the pocket = the door's SMALL open side (flood ≤ 6 cells; the
                    // room side floods big and is discarded)
                    let dx0 = di % mp.w, dy0 = di / mp.w
                    var regions: [Set<Int>] = []
                    for (ox, oy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        guard mp.inBounds(dx0 + ox, dy0 + oy), mp.wall[mp.idx(dx0 + ox, dy0 + oy)] == 0 else { continue }
                        var seen: Set<Int> = [mp.idx(dx0 + ox, dy0 + oy)]
                        var q = Array(seen), qi = 0, capped = false
                        while qi < q.count {
                            if seen.count > 6 { capped = true; break }
                            let c = q[qi]; qi += 1
                            let cx = c % mp.w, cy = c / mp.w
                            for (ax, ay) in [(1, 0), (-1, 0), (0, 1), (0, -1)] where mp.inBounds(cx + ax, cy + ay) {
                                let mi = mp.idx(cx + ax, cy + ay)
                                if mi == di || seen.contains(mi) || mp.wall[mi] != 0 { continue }
                                seen.insert(mi); q.append(mi)
                            }
                        }
                        if !capped { regions.append(seen) }
                    }
                    guard let pocket = regions.min(by: { $0.count < $1.count }) else { continue }
                    for c in pocket {
                        let cx = c % mp.w, cy = c / mp.w
                        for oy in -1...1 { for ox in -1...1 where !(ox == 0 && oy == 0) {
                            guard mp.inBounds(cx + ox, cy + oy) else { pocketLeaks += 1; continue }
                            let ni = mp.idx(cx + ox, cy + oy)
                            if ni == di || pocket.contains(ni) { continue }
                            if mp.wall[ni] == 0 || mp.doors[ni] != nil { pocketLeaks += 1 }
                        } }
                    }
                }
            }
        }
        check(pocketLeaks == 0, "carved pockets are sealed across a 90-map sweep (\(pocketLeaks) leaks)")
        check(closetsSeen > 0 && storesSeen > 0,
              "the stricter seals still place chambers (\(closetsSeen) closets, \(storesSeen) stores)")

        // no two pickups may spawn STACKED (interpenetrating SDF props read as
        // one broken object) — the keycards were the blind spot: rolled
        // independently, two locks could put both cards on one cell
        var stackedItems = 0
        for sd in UInt64(1)...15 {
            for lv in [4, 6] {
                let gi = MapGen.generate(level: lv, colonyIndex: Int(sd % 6), seed: sd &* 6367 &+ UInt64(lv))
                for i in 0..<gi.items.count {
                    for j in (i + 1)..<gi.items.count where vlen(gi.items[i].pos - gi.items[j].pos) < 0.85 {
                        stackedItems += 1
                    }
                }
            }
        }
        check(stackedItems == 0, "no stacked pickups across a 30-map sweep (\(stackedItems) pairs)")

        // the pipe-routing mask must be DIAGONALLY CLEAN: a diagonal-only
        // adjacency makes the kernel's bilinear upsample plateau at mid-values,
        // and the pipe-terminus geometry smears along it as floating hardware
        var pipeKisses = 0
        for sd in UInt64(1)...20 {
            let gk = MapGen.generate(level: Int(sd % 8) + 1, colonyIndex: Int(sd % 6), seed: sd &* 2917 &+ 5)
            let mk = gk.map
            for y in 0..<(mk.h - 1) { for x in 0..<(mk.w - 1) {
                for (dx, dy) in [(1, 1), (1, -1)] {
                    let ny = y + dy
                    guard ny >= 0, ny < mk.h else { continue }
                    if mk.pipe[mk.idx(x, y)] >= 0.5, mk.pipe[mk.idx(x + dx, ny)] >= 0.5,
                       mk.pipe[mk.idx(x + dx, y)] < 0.5, mk.pipe[mk.idx(x, ny)] < 0.5 { pipeKisses += 1 }
                }
            } }
        }
        check(pipeKisses == 0, "pipe routing is diagonally clean across a 20-map sweep (\(pipeKisses) kisses)")

        // every fuel drum must be REFUELLABLE — a standable point inside its
        // trigger ring (a drum boxed in by dorm-bed colliders is fuel the
        // player can see and never have; World relocates those at load)
        var dryDrums = 0, drumsChecked = 0
        for sd in UInt64(1)...20 {
            for lv in [3, 5, 7] {
                let wd = World(level: lv, colonyIndex: Int(sd % 6), seed: sd &* 5077 &+ UInt64(lv))
                for d in wd.drums {
                    // fuel-STORE drums are an intentional stack (pump the front,
                    // shoot the rest) — reachability applies to room drums only
                    if wd.map.fuelStore.contains(wd.map.idx(Int(d.pos.x), Int(d.pos.y))) { continue }
                    drumsChecked += 1
                    if !wd.drumReachable(d.pos) { dryDrums += 1 }
                }
            }
        }
        // Survivors must ALL be reachable: World relocates a boxed-in drum, and
        // drops any it can't place reachably (better gone than teasing).
        check(dryDrums == 0, "all \(drumsChecked) drums across a 60-map sweep are reachable (\(dryDrums) boxed in)")

        // the citadel's LAST floor exits by TELEPORTER — an open pad (no door),
        // wearing the pad flat — and the first floor of the NEXT citadel receives
        // by pad too: the marine materialised there, so no arrival car either
        let g8 = MapGen.generate(level: 8, colonyIndex: 0, seed: 8080)
        let m8 = g8.map
        check(m8.exitCell >= 0 && m8.wall[m8.exitCell] == 0 && m8.doors[m8.exitCell] == nil,
              "L8 exit is an open teleporter pad (no door)")
        check(m8.floor[m8.exitCell] == FlatTex.teleportPad.rawValue, "L8 pad wears the teleport flat")
        check(m8.entryCell >= 0 && m8.doors[m8.entryCell] != nil, "L8 arrival is still a lift car")
        let g9 = MapGen.generate(level: 9, colonyIndex: 1, seed: 9090)
        let m9 = g9.map
        check(m9.entryCell >= 0 && m9.wall[m9.entryCell] == 0 && m9.doors[m9.entryCell] == nil,
              "L9 arrival is an open receiver pad (teleported in)")
        check(m9.floor[m9.entryCell] == FlatTex.teleportPad.rawValue, "L9 receiver wears the teleport flat")
        check(m9.exitCell >= 0 && m9.doors[m9.exitCell] != nil, "L9 exit is an elevator again")

        // the title-descent ride: the hand-built shaft world is a lit, sealed
        // car with its leaves shut — what the player watches while floor 1 builds
        let ride = World.liftRideShaft()
        check(ride.map.doors[ride.map.exitCell] != nil && ride.elevatorPhase == .descending,
              "lift-ride shaft world assembles (shut leaves, lamp keyed)")
        // the visor redesign: the 3-D view owns the whole framebuffer
        check(RenderConfig.viewHeight == RenderConfig.height, "the 3-D view fills the visor (no status bar)")

        // the teleport flow end-to-end: a defeated Queen + a body on the pad arms
        // the report; a FRESH fire press charges; full charge completes the level
        let tAudio = AudioEngine()
        tAudio.muted = true                       // harnesses are SILENT — they get run in offices
        let tInput = InputState()
        let w8t = World(level: 8, colonyIndex: 0, seed: 8080)
        for i in w8t.monsters.indices where w8t.monsters[i].kind == .queen {
            w8t.monsters[i].state = .dead
            w8t.monsters[i].burn = 1
        }
        let px = w8t.map.exitCell % w8t.map.w, py = w8t.map.exitCell / w8t.map.w
        w8t.player.pos = SIMD2(Float(px) + 0.5, Float(py) + 0.5)
        tInput.kb.fire = true                               // held from before boarding —
        w8t.update(dt: 1.0 / 60, input: tInput, audio: tAudio)
        check(w8t.teleportPhase == .await, "standing the pad arms the jump report")
        w8t.update(dt: 1.0 / 60, input: tInput, audio: tAudio)
        check(w8t.teleportPhase == .await, "…and a held trigger does NOT jump")
        tInput.kb.fire = false
        w8t.update(dt: 1.0 / 60, input: tInput, audio: tAudio)
        tInput.kb.fire = true                               // the fresh press commits
        w8t.update(dt: 1.0 / 60, input: tInput, audio: tAudio)
        check(w8t.teleportPhase == .charging, "a fresh fire press engages the teleport")
        tInput.kb.fire = false
        for _ in 0..<Int(World.teleportChargeTime * 60) + 30 {
            w8t.update(dt: 1.0 / 60, input: tInput, audio: tAudio)
        }
        check(w8t.teleportT >= 1 && w8t.levelComplete, "full charge completes the citadel")

        // a drained recharge socket latches DEPLETED (panel goes red) and must
        // NOT dispense the self-recharge trickle to a camper — it re-arms only
        // once a tenth of the reserve has been rebuilt (~12 s at the regen rate)
        let wS = World(level: 2, colonyIndex: 0, seed: 777)
        if let si = wS.sockets.indices.first {
            let sIn = InputState()
            wS.player.pos = wS.sockets[si].pos
            wS.player.ammo[AmmoType.cells.rawValue] = 0
            wS.sockets[si].charge = 5                              // nearly dry
            for _ in 0..<30 { wS.update(dt: 1.0 / 60, input: sIn, audio: tAudio) }
            check(wS.sockets[si].depleted, "a drained socket latches DEPLETED")
            let cellsAfterDrain = wS.player.ammo[AmmoType.cells.rawValue]
            for _ in 0..<120 { wS.update(dt: 1.0 / 60, input: sIn, audio: tAudio) }
            check(wS.player.ammo[AmmoType.cells.rawValue] == cellsAfterDrain,
                  "a depleted socket doesn't dispense its trickle to a camper")
        } else {
            check(false, "level 2 placed no recharge socket to test")
        }

        // 2. game loop: run a world for a few seconds of simulated play
        let audio = AudioEngine()
        audio.muted = true                        // harnesses are SILENT — they get run in offices

        // 2a0. the shipped sample set is complete: every logical sound decoded at
        // least one file from Resources/Audio. The synth fallback makes a missing
        // or broken asset inaudible as a failure, so assert it here instead.
        let missing = Set(AudioEngine.Sound.allCases).subtracting(audio.sampledSounds)
        check(missing.isEmpty,
              missing.isEmpty ? "audio bank complete (all \(AudioEngine.Sound.allCases.count) sounds sampled)"
                              : "audio bank missing: \(missing.map(\.base).sorted().joined(separator: ", "))")
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

        // 2a2. integrity: an awake monster must NEVER end a tick standing inside a
        // solid cell — they navigate the layout, never clip through a wall or a
        // closed door. Wake every monster on a spread of depths, aim them all at the
        // marine, sweep his facing so the pack converges from every side / corner,
        // and assert no centre ever lands in solid for the whole chase.
        var clipTicks = 0, clipWorst = ""
        for lvl in [1, 3, 5, 7, 8] {
            let w = World(level: lvl, colonyIndex: 0, seed: UInt64(lvl) &* 131 &+ 17)
            for k in w.monsters.indices {
                w.monsters[k].awake = true; w.monsters[k].state = .chase
                w.monsters[k].hasSeen = true; w.monsters[k].lastSeen = w.player.pos
            }
            let patrol = InputState(); patrol.kb.forward = true
            for f in 0..<900 {
                w.player.dir = Float(f) * 0.02              // sweep so they approach from all bearings
                w.update(dt: 1.0 / 60, input: patrol, audio: audio)
                for m in w.monsters where m.alive {
                    if w.map.blocksMovement(Int(m.pos.x), Int(m.pos.y)) {
                        clipTicks += 1
                        if clipWorst.isEmpty { clipWorst = "L\(lvl) \(m.kind) @(\(String(format: "%.2f", m.pos.x)),\(String(format: "%.2f", m.pos.y)))" }
                    }
                }
            }
        }
        check(clipTicks == 0, "no awake monster ever stands inside a wall (\(clipTicks) clip-ticks\(clipWorst.isEmpty ? "" : ", first: \(clipWorst)"))")

        // force-kill a monster to exercise the death + scoring path (a DRONE — the
        // Queen only takes the kill from plasma+fire, so a rocket would merely wound her)
        if let i = world.monsters.firstIndex(where: { $0.alive && $0.kind == .alien }) {
            let before = world.killCount
            // big splash right on the monster
            world.projectiles.append(Projectile(pos: world.monsters[i].pos, vel: .zero,
                                                 kind: .rocket, damage: 999, fromPlayer: true, life: 0.01))
            world.update(dt: 0.05, input: InputState(), audio: audio)
            check(world.killCount >= before, "kill accounting ran")
            check(world.decals.contains { $0.w < 0 }, "kill stamps a blood decal at the site")
            // the explosive kill OBLITERATES the drone: gibbed, nothing to burn,
            // never blocks the way, and the burst leaves organic debris behind
            check(world.monsters[i].gibbed && world.monsters[i].burn >= 1, "rocket kill gibs the drone (no corpse to burn)")
            check(world.decals.contains { $0.w < -2 }, "gibbing splatters offal decals")
            for _ in 0..<40 { world.update(dt: 1.0 / 60, input: InputState(), audio: audio) }
            check(GPURaymarch.poseShapes(world.monsters[i]).isEmpty, "a gibbed drone leaves no rendered corpse")
        }

        // 2b. flamethrower: standard issue, FINITE fuel, ignites + clears corpses
        let fw = World(level: 1, colonyIndex: 0, seed: 99)
        check(fw.player.has(.flamethrower), "flamethrower carried from the start")
        check(WeaponKind.flamethrower.def.ammo == .fuel, "flamethrower now runs on finite fuel")
        check(fw.player.ammoCount(.fuel) > 0, "marine starts with fuel (\(fw.player.ammoCount(.fuel)))")
        if let mi = fw.monsters.firstIndex(where: { $0.alive }) {
            let cpos = fw.monsters[mi].pos
            // plasma kill — an explosive kill now GIBS the drone and leaves no corpse
            fw.projectiles.append(Projectile(pos: cpos, vel: .zero, kind: .plasma, damage: 999, fromPlayer: true, life: 0.01))
            for _ in 0..<40 { fw.update(dt: 1.0 / 60, input: InputState(), audio: audio) }   // die → corpse
            check(fw.monsters.contains { $0.state == .dead }, "killed monster leaves a corpse")
            fw.player.pos = cpos + SIMD2<Float>(0.9, 0)
            fw.player.dir = .pi                                     // face the corpse
            fw.player.current = .flamethrower
            let burn = InputState(); burn.kb.fire = true
            var ignited = false
            for _ in 0..<420 {
                fw.update(dt: 1.0 / 60, input: burn, audio: audio)
                if fw.monsters.contains(where: { $0.state == .dead && $0.burn > 0 }) { ignited = true }
                if fw.monsters.contains(where: { $0.state == .dead && $0.burn >= 1 }) { break }
            }
            check(ignited, "flamethrower ignites the corpse")
            check(fw.monsters.contains { $0.state == .dead && $0.burn >= 1 }, "corpse burns to charred remains")
            check(fw.decals.contains { $0.w > 0 && $0.w <= 1 }, "burned-out corpse stamps a scorch decal")
            check(fw.decals.contains { $0.w > 2 }, "burned-out corpse stamps smoldering ash")
            if let bi = fw.monsters.firstIndex(where: { $0.state == .dead && $0.burn >= 1 }) {
                check(GPURaymarch.poseShapes(fw.monsters[bi]).isEmpty, "a burned-out corpse renders no solid remains")
            }
        }
        // a drone KILLED BY FIRE ignites where it drops — no second pass needed
        let iw = World(level: 1, colonyIndex: 0, seed: 137)
        if let fi = iw.monsters.firstIndex(where: { $0.alive && $0.kind == .alien }) {
            while iw.monsters[fi].alive { iw.damageMonsterForTest(fi, 60, audio: audio, kind: .fire) }
            for _ in 0..<40 { iw.update(dt: 1.0 / 60, input: InputState(), audio: audio) }   // dying → dead
            check(iw.monsters[fi].state == .dead && iw.monsters[fi].burn > 0,
                  "a flame kill self-ignites the corpse (burn \(String(format: "%.2f", iw.monsters[fi].burn)))")
        }

        // 2d. rubble debris built at battle-damage sites (across several levels)
        var debrisPiles = 0
        for lvl in 1...6 {
            let w = World(level: lvl, colonyIndex: lvl - 1, seed: UInt64(lvl) &* 31 &+ 5)
            debrisPiles += w.debris.count
        }
        check(debrisPiles > 0, "rubble debris built at shattered fixtures (\(debrisPiles) piles)")

        // 2e. enemy AI: a clump of drones disperses (boid separation / anti-clump).
        // Spawn the clump on open floor IN FRONT of the marine — he starts inside
        // the arrival car now, so a fixed westward offset can land in bedrock.
        // The clump needs ROOM to disperse into: find the nearest 3x3 clearing of
        // open cells (a single open cell against a wall pins the boids together).
        let aw = World(level: 1, colonyIndex: 0, seed: 7)
        var cc = aw.player.pos
        search: for r in 1..<12 { for dy in -r...r { for dx in -r...r {
            let x = Int(aw.player.pos.x) + dx, y = Int(aw.player.pos.y) + dy
            var clear = true
            for ny in -1...1 { for nx in -1...1 where !(aw.map.inBounds(x + nx, y + ny) && !aw.map.blocksMovement(x + nx, y + ny)) {
                clear = false
            }}
            if clear { cc = SIMD2(Float(x) + 0.5, Float(y) + 0.5); break search }
        }}}
        aw.player.pos = cc + SIMD2<Float>(-1.1, 0)   // marine + clump together in the clearing (as before the arrival-car start)
        cc += SIMD2<Float>(1.1, 0)
        aw.monsters = (0..<5).map { k in
            var m = Monster(kind: .alien, pos: cc + SIMD2(Float(k) * 0.05, 0)); m.awake = true; m.state = .chase; return m
        }
        func minPairDist(_ ms: [Monster]) -> Float {
            var mn = Float.greatestFiniteMagnitude
            for a in 0..<ms.count { for b in (a + 1)..<ms.count { mn = min(mn, vlen(ms[a].pos - ms[b].pos)) } }
            return mn
        }
        let gap0 = minPairDist(aw.monsters)
        for _ in 0..<180 { aw.update(dt: 1.0 / 60, input: InputState(), audio: audio) }
        let gap1 = minPairDist(aw.monsters)
        check(gap1 > gap0 * 3, "clumped drones separate (min gap \(String(format: "%.2f", gap0)) → \(String(format: "%.2f", gap1)))")

        // 2f. a lone drone (last one alive) commits to the hunt and closes to melee
        let kw = World(level: 1, colonyIndex: 0, seed: 11)
        // drop the drone into an open, furniture-free cell with a clear lane to the
        // marine (~2–3 cells off) — the test is "a lone drone commits", not "a drone
        // wedged inside a desk", so it must start somewhere it can actually move.
        var spawn = kw.player.pos + SIMD2<Float>(2.0, 0)
        for off in [SIMD2<Float>(2, 0), SIMD2(-2, 0), SIMD2(0, 2), SIMD2(0, -2),
                    SIMD2(2.5, 0), SIMD2(-2.5, 0), SIMD2(0, 2.5), SIMD2(0, -2.5), SIMD2(3, 0), SIMD2(-3, 0)] {
            let p = kw.player.pos + off, mid = kw.player.pos + off * 0.5
            if !kw.map.blocksMovement(Int(p.x), Int(p.y)) && !kw.blockedBySolidProp(p.x, p.y, 0.5)
               && !kw.map.blocksMovement(Int(mid.x), Int(mid.y)) && !kw.blockedBySolidProp(mid.x, mid.y, 0.5) {
                spawn = p; break
            }
        }
        var dr = Monster(kind: .alien, pos: spawn); dr.awake = true; dr.state = .chase
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
            // her death is an EVENT: she topples for queenDeathTime, the deck
            // jolt + the BURN message fire as she lands, and only then is she a corpse
            check(qw.monsters.contains { $0.kind == .queen && $0.state == .dying }, "the Queen's death plays out (dying state holds)")
            var joltSeen = false
            for _ in 0..<Int(World.queenDeathTime * 60) + 30 {
                qw.update(dt: 1.0 / 60, input: InputState(), audio: audio)
                if qw.impactShake > 0.9 { joltSeen = true }
            }
            check(joltSeen, "the toppling Queen jolts the deck as she lands")
            check(qw.monsters.contains { $0.kind == .queen && $0.state == .dead }, "the landed Queen is a corpse")
            check(!qw.queenDefeated, "a downed-but-unburned Queen is still not defeated")
            // torch the body → she burns down on her own and the exit unlocks. The
            // Queen is a great mass (~4.5 s to full ash at her burn rate), so loop
            // until she's defeated rather than assume a fixed frame count.
            if let qd = qw.monsters.firstIndex(where: { $0.kind == .queen }) { qw.monsters[qd].burn = 0.06 }
            for _ in 0..<360 {   // up to 6 s — ample for the Queen's slower, more ferocious burn
                qw.update(dt: 1.0 / 60, input: InputState(), audio: audio)
                if qw.queenDefeated { break }
            }
            check(qw.queenDefeated, "a burned Queen meets the objective (exit unlocks)")
        } else { check(false, "level seeded a Queen") }

        // 2g1b. plasma aim-assist targeting: a drone-LOCKED bolt overlapping the
        // Queen's far larger hitbox (radius 1.1 vs 0.4) must strike the DRONE it's
        // bound to — never be poached by the Queen. Tested at the collision layer (a
        // bolt tagged to the drone's index), so it's deterministic and doesn't hinge
        // on the lock/AI dynamics of a live chase.
        do {
            let tw = World(level: 1, colonyIndex: 0, seed: 20260721)
            let fwd = SIMD2<Float>(cos(tw.player.dir), sin(tw.player.dir))
            let side = SIMD2<Float>(-fwd.y, fwd.x)
            let c = tw.player.pos + fwd * 1.8
            let queen = Monster(kind: .queen, pos: c)
            var drone = Monster(kind: .alien, pos: c + side * 0.35)           // INSIDE the Queen's radius
            drone.health = 100000
            tw.monsters = [queen, drone]                                      // Queen at index 0 (old code struck her first)
            let qh0 = tw.monsters[0].health, dh0 = tw.monsters[1].health
            // a plasma bolt bound to the drone (index 1), sitting on the overlap so it
            // resolves at once — no player fire, so this is the only projectile in play
            tw.projectiles.append(Projectile(pos: c + side * 0.35, vel: fwd * 0.5, kind: .plasma,
                                             damage: 60, fromPlayer: true, life: 1.0, targetIndex: 1))
            for _ in 0..<3 { tw.update(dt: 1.0 / 60, input: InputState(), audio: audio) }
            check(tw.monsters[1].health < dh0, "a drone-locked plasma bolt strikes the drone")
            check(tw.monsters[0].health == qh0, "…and NOT the Queen whose hitbox it overlaps (q \(qh0)->\(tw.monsters[0].health), d \(dh0)->\(tw.monsters[1].health))")
        }

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

        // 2g2b. transit boxes are SEALED: entry/exit cars and teleporter pads
        // must have back, jambs AND back corners solid. A ring open at a
        // diagonal leaves two walls kissing at a single point, and the rounded
        // SDF opens a floor-to-ceiling slit there ("the back corner of the
        // elevator is missing"). Fallback exit switches (no car) are exempt.
        var ringBreaches = 0, ringChecked = 0
        for lvl in [1, 3, 8] {
            for sd in 0..<10 {
                let w = World(level: lvl, colonyIndex: (lvl - 1) % 6, seed: UInt64(sd) &* 977 &+ UInt64(lvl))
                for cell in [w.map.entryCell, w.map.exitCell] where cell >= 0 {
                    let isCar = w.map.doors[cell] != nil
                    let isPad = w.map.floor[cell] == FlatTex.teleportPad.rawValue
                    guard isCar || isPad else { continue }           // fallback switch: no box to seal
                    let ex = cell % w.map.w, ey = cell / w.map.w
                    var opens: [(Int, Int)] = []
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)]
                    where w.map.inBounds(ex + dx, ey + dy) && w.map.wall[w.map.idx(ex + dx, ey + dy)] == 0 {
                        opens.append((dx, dy))
                    }
                    ringChecked += 1
                    guard opens.count == 1 else { ringBreaches += 1; continue }
                    let (dx, dy) = opens[0]
                    for (bx, by) in [(ex - dx, ey - dy), (ex + dy, ey + dx), (ex - dy, ey - dx),
                                     (ex - dx + dy, ey - dy + dx), (ex - dx - dy, ey - dy - dx)] {
                        if !w.map.inBounds(bx, by) || w.map.wall[w.map.idx(bx, by)] == 0 { ringBreaches += 1; break }
                    }
                }
            }
        }
        check(ringBreaches == 0, "transit boxes are sealed — no diagonal slits (\(ringChecked) checked)")

        // 2g3. the Queen's death choreography must LAND on the corpse pose (the
        // burn/revive pipeline takes over with no visible pop), and a creature's
        // world scale + floor plant must be pose-invariant — deriving them from
        // the current pose made the dying Queen inflate like a balloon.
        var qm = Monster(kind: .queen, pos: SIMD2(4, 4))
        qm.state = .dying; qm.stateTime = World.queenDeathTime
        let endPose = GPURaymarch.poseShapes(qm)
        qm.state = .dead
        let corpsePose = GPURaymarch.poseShapes(qm)
        check(endPose.count == corpsePose.count
              && zip(endPose, corpsePose).allSatisfy { e, c in
                  let d = e.a - c.a
                  return d.x * d.x + d.y * d.y + d.z * d.z < 1e-6 && abs(e.r1 - c.r1) < 1e-3
              },
              "the Queen's death lands exactly on the corpse pose")
        let qAlive = Monster(kind: .queen, pos: SIMD2(4, 4))
        var qMid = qAlive; qMid.state = .dying; qMid.stateTime = World.queenDeathTime * 0.7
        let (poseInv, _) = GPURaymarch.packCreatures([qAlive, qMid])
        check(poseInv.count == 2 && abs(poseInv[0].a.w - poseInv[1].a.w) < 1e-6 && abs(poseInv[0].c.x - poseInv[1].c.x) < 1e-6,
              "creature scale and floor plant are pose-invariant (no death balloon)")

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

        // every level places a couple of plasma recharge sockets (the anti-softlock)
        var socketLevels = 0
        for lv in 1...6 {
            let w = World(level: lv, colonyIndex: lv - 1, seed: UInt64(lv) &* 33 &+ 9)
            if !w.sockets.isEmpty { socketLevels += 1 }
        }
        check(socketLevels == 6, "every level places recharge sockets (\(socketLevels)/6)")
        // a wall-mounted socket must back onto PLAIN structural wall — never a surface
        // FEATURE (an amber ARC display bank, backlit glass, or hazard plating): a
        // recharge panel bolted over a screen reads as a placement bug.
        var socketOnFeature = 0, socketsChecked = 0
        let badBacking: Set<Int> = [WallTex.computer.rawValue, WallTex.glass.rawValue, WallTex.hazard.rawValue]
        for lv in 1...8 {
            for s in 0..<6 {
                let w = World(level: lv, colonyIndex: (lv - 1) % 6, seed: UInt64(lv) &* 131 &+ UInt64(s) &* 17 &+ 5)
                for sk in w.sockets {
                    socketsChecked += 1
                    let ix = Int((-sin(sk.yaw)).rounded()), iy = Int(cos(sk.yaw).rounded())   // inward (room-facing) axis
                    let bx = Int(floor(sk.pos.x)) - ix, by = Int(floor(sk.pos.y)) - iy         // the wall cell behind
                    if w.map.inBounds(bx, by), badBacking.contains(w.map.wall[w.map.idx(bx, by)]) { socketOnFeature += 1 }
                }
            }
        }
        check(socketOnFeature == 0, "no recharge socket backs onto a display/glass/hazard wall (\(socketOnFeature)/\(socketsChecked))")
        // standing in a socket pumps cells into a dry plasma rifle, draining the socket
        let cw = World(level: 1, colonyIndex: 0, seed: 1234)
        cw.sockets = [Socket(pos: cw.player.pos, charge: 135)]
        cw.player.ammo[AmmoType.cells.rawValue] = 0
        for _ in 0..<60 { cw.update(dt: 1.0 / 60, input: InputState(), audio: audio) }
        check(cw.player.ammoCount(.cells) > 0, "a socket recharges the dry plasma rifle (0 → \(cw.player.ammoCount(.cells)))")
        check(cw.sockets.first.map { $0.charge < 135 } ?? true, "the socket's reserve drains as it recharges")

        // a drained socket trickles its OWN reserve back up (powered infrastructure —
        // depleting every socket is never a permanent softlock). Socket far from the
        // marine so nothing dispenses; just let it sit.
        let sw2 = World(level: 1, colonyIndex: 0, seed: 1234)
        sw2.sockets = [Socket(pos: sw2.player.pos + SIMD2<Float>(30, 30), charge: 0, maxCharge: 600)]
        for _ in 0..<300 { sw2.update(dt: 1.0 / 60, input: InputState(), audio: audio) }   // ~5s idle
        check((sw2.sockets.first?.charge ?? 0) > 0, "a drained socket recharges its own reserve over time (0 → \(sw2.sockets.first?.charge ?? 0))")

        // 2h3. rooms are furnished — decorative set-dressing (bunks / desks + powered
        // terminals / lockers / pipe runs) so a recently-active colony doesn't read as
        // empty boxes. Props carry NO collision, but must still place sensibly: never
        // on the marine's start, on a pickup, in a doorway, or footed inside a wall.
        var propLevels = 0, propOnStart = 0, propOnItem = 0, propInWall = 0, propInDoor = 0
        // furniture is SOLID and PROTRUDES into the room, so it must never jut across a
        // doorway throat or a 1-wide corridor — that would wall the marine in. We test
        // the actual collision footprint (not just the centre cell) at every such cell.
        var doorThroatBlocked = 0, corridorBlocked = 0, pipeByOpening = 0
        let pRad: Float = 0.34
        for lvl in 1...8 {
            let w = World(level: lvl, colonyIndex: lvl - 1, seed: UInt64(lvl) &* 97 &+ 3)
            if !w.props.isEmpty { propLevels += 1 }
            for pr in w.props {
                if vlen(pr.pos - w.player.pos) < 0.6 { propOnStart += 1 }
                for it in w.items where vlen(pr.pos - it.pos) < 0.6 { propOnItem += 1 }
                let cx = Int(pr.pos.x), cy = Int(pr.pos.y)
                if w.map.blocksMovement(cx, cy) { propInWall += 1 }                 // centre on open floor
                if w.map.isDoorCell(cx, cy) { propInDoor += 1 }                     // never blocking a doorway
            }
            func solid(_ x: Int, _ y: Int) -> Bool { !w.map.inBounds(x, y) || w.map.blocksMovement(x, y) }
            for cy in 0..<w.map.h { for cx in 0..<w.map.w {
                if w.map.isDoorCell(cx, cy) {
                    for (ox, oy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] where !solid(cx + ox, cy + oy) {
                        if w.blockedBySolidProp(Float(cx + ox) + 0.5, Float(cy + oy) + 0.5, pRad) { doorThroatBlocked += 1 }
                    }
                } else if !solid(cx, cy) {
                    let ns = solid(cx, cy - 1) && solid(cx, cy + 1)
                    let ew = solid(cx - 1, cy) && solid(cx + 1, cy)
                    if ns != ew, w.blockedBySolidProp(Float(cx) + 0.5, Float(cy) + 0.5, pRad) { corridorBlocked += 1 }   // a 1-wide passage
                }
            } }
            // wall-baked pipes must never reach a door / the exit (they ramp into the
            // wall before any opening) — guards the "pipe across the elevator door" bug.
            for i in 0..<(w.map.w * w.map.h) where w.map.pipe[i] >= 0.5 {
                let px = i % w.map.w, py = i / w.map.w
                for dy in -1...1 { for dx in -1...1 where w.map.inBounds(px + dx, py + dy) {
                    let ni = w.map.idx(px + dx, py + dy)
                    if w.map.doors[ni] != nil || w.map.wall[ni] == WallTex.exitSwitch.rawValue { pipeByOpening += 1 }
                } }
            }
        }
        check(propLevels >= 6, "rooms are furnished with set-dressing (\(propLevels)/8 levels)")
        check(propOnStart == 0, "no prop spawns on the marine's start (\(propOnStart))")
        check(propOnItem == 0, "no prop spawns on a pickup (\(propOnItem))")
        check(propInWall == 0, "every prop foots on open floor, never inside a wall (\(propInWall))")
        check(propInDoor == 0, "no prop sits in a doorway (\(propInDoor))")
        check(doorThroatBlocked == 0, "no solid furniture juts across a doorway throat (\(doorThroatBlocked))")
        check(corridorBlocked == 0, "no solid furniture blocks a 1-wide corridor (\(corridorBlocked))")
        check(pipeByOpening == 0, "no wall pipe reaches a door or the exit (\(pipeByOpening))")

        // furniture is SOLID — drive the marine straight at a bunk: he must advance
        // toward it then be STOPPED on the room side (never walk through to the wall).
        // along = distance from the bunk centre along its facing (start 1.3 → stopped).
        var furnitureTested = false
        for seed in stride(from: UInt64(1), through: UInt64(120), by: 1) where !furnitureTested {
            let fw3 = World(level: 1, colonyIndex: 0, seed: seed)
            guard let bunk = fw3.props.first(where: { $0.kind == .bunk && $0.againstWall }) else { continue }
            let inward = SIMD2<Float>(-sin(bunk.yaw), cos(bunk.yaw))
            let start = bunk.pos + inward * 1.3
            // a clear, standable start with an open straight approach to the bunk
            guard !fw3.map.blocksMovement(Int(start.x), Int(start.y)),
                  !fw3.props.contains(where: { vlen($0.pos - start) < 0.8 }),
                  !fw3.map.blocksMovement(Int(bunk.pos.x + inward.x * 0.8), Int(bunk.pos.y + inward.y * 0.8)) else { continue }
            fw3.player.pos = start
            fw3.player.dir = atan2(-inward.y, -inward.x)                 // face the bunk
            let push = InputState(); push.kb.forward = true
            for _ in 0..<120 { fw3.update(dt: 1.0 / 60, input: push, audio: audio) }   // walk hard into it
            let along = (fw3.player.pos.x - bunk.pos.x) * inward.x + (fw3.player.pos.y - bunk.pos.y) * inward.y
            if along < 1.0 {                                            // only count it if he actually advanced
                check(along > 0.2, "the marine is stopped by a bunk, can't walk through (along \(String(format: "%.2f", along)))")
                furnitureTested = true
            }
        }
        check(furnitureTested, "exercised furniture collision against a bunk")

        // building / floor / planet progression — the campaign structure
        check(Progression.floorInBuilding(1) == 1 && Progression.floorInBuilding(8) == 8, "floors run 1…8 within a citadel")
        check(Progression.floorInBuilding(9) == 1, "floor 9 resets to floor 1 of the next citadel")
        check(Progression.planetIndex(1) == 0 && Progression.planetIndex(8) == 0, "all 8 floors of citadel 1 share one planet")
        check(Progression.planetIndex(9) == 1, "clearing floor 8 advances to the next planet")
        check(Progression.planetIndex(Progression.floorsPerBuilding * 6 + 1) == 0, "the six planets cycle (planet 7 == planet 1)")
        check(Progression.isLastFloor(8) && !Progression.isLastFloor(7), "floor 8 is the teleport floor")
        // each citadel resets surface→depths — lighting AND materials, in step
        check(Lighting.ambient(level: 1).z > Lighting.ambient(level: 8).z, "a citadel descends bright→dark")
        check(Lighting.ambient(level: 9) == Lighting.ambient(level: 1), "the next citadel's floor 1 is back at the surface tier")
        check(MapGen.theme(0, level: 9).floor == MapGen.theme(0, level: 1).floor, "materials reset surface→depths each citadel")
        check(MapGen.theme(0, level: 8).floor != MapGen.theme(0, level: 1).floor, "the lowest floor's materials differ from the surface")

        // deploy a proximity mine, walk a drone onto it → it arms and detonates.
        // A mine is ordnance: EVERYTHING inside the ring dies — the drone that
        // trips it AND a packmate right out at the blast's rim (where falloff
        // damage alone would never kill) — while the Queen is rocked but holds
        // on her plasma-only floor.
        let mw = World(level: 1, colonyIndex: 0, seed: 88)
        mw.player.mines = 3
        mw.player.health = 500                    // ride out the self-splash + a queen swipe
        let deploy = InputState(); deploy.kb.deployMine = true
        mw.update(dt: 1.0 / 60, input: deploy, audio: audio)        // edge press → drop one
        check(mw.deployedMines.count == 1 && mw.player.mines == 2, "deploying drops one mine and spends one")
        let minePos = mw.deployedMines[0].pos
        var ma = Monster(kind: .alien, pos: minePos + SIMD2<Float>(0.95, 0)); ma.awake = true
        let mb = Monster(kind: .alien, pos: minePos + SIMD2<Float>(0, 2.9))   // asleep at the rim
        var mq = Monster(kind: .queen, pos: minePos - SIMD2<Float>(1.5, 0)); mq.awake = true
        mw.monsters = [ma, mb, mq]
        for _ in 0..<150 { mw.update(dt: 1.0 / 60, input: InputState(), audio: audio) }
        check(mw.deployedMines.isEmpty, "an armed mine detonates when an alien crosses it")
        check(!mw.monsters[0].alive && !mw.monsters[1].alive, "nothing inside the mine's ring survives — trigger drone AND rim packmate die")
        check(mw.monsters[2].alive && mw.monsters[2].health < 900, "the Queen is rocked by a mine but her plasma-only floor holds")

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
            SpriteCompositor().overlayThings(zw, into: cz)       // fills the z-buffer via the centre-split DDA
            let zClosed = cz.zbuffer[cx]
            zmap.doors[di]!.open = 0.6
            SpriteCompositor().overlayThings(zw, into: cz)
            let zOpen = cz.zbuffer[cx]
            check(zOpen > zClosed + 0.5, "a parted door reveals the room behind it (depth \(String(format: "%.1f", zClosed)) → \(String(format: "%.1f", zOpen)))")
            sawDoor = true
            break
        }
        check(sawDoor, "found a clean door to exercise the centre-split")

        // 3. world render path — the GPU SDF renderer
        let canvas = Canvas2D()
        let gpu = MTLCreateSystemDefaultDevice().flatMap { GPUWorldRenderer(device: $0) }
        _ = gpu?.render(world, into: canvas)
        HUD().draw(world, into: canvas)
        var nonBlack = 0
        for i in 0..<(RenderConfig.width * RenderConfig.height) where (canvas.framebuffer[i] & 0x00FF_FFFF) != 0 { nonBlack += 1 }
        check(nonBlack > 5000, "world render + HUD drew a frame (\(nonBlack) lit pixels)")

        // 3b. the SDF weapon viewmodels: every weapon packs shapes, the local
        // bound contains them all, and the EYE sits outside the bound (a bound
        // that swallows the camera would defeat the kernel's ray gate and
        // march the gun for every pixel on screen)
        for k in WeaponKind.allCases {
            var vp = world.player
            vp.current = k; vp.fireAnim = 0.1; vp.muzzle = 0.05
            let vm = Viewmodel.pack(player: vp, time: 1.23)
            check(!vm.shapes.isEmpty, "\(k.def.name) viewmodel packs shapes (\(vm.shapes.count))")
            var inside = true
            for sh in vm.shapes {
                let c = SIMD3(sh.a.x, sh.a.y, sh.a.z)
                if simd_length(c - vm.boundC) > vm.boundR { inside = false }
            }
            check(inside, "\(k.def.name) viewmodel bound contains its shapes (r \(String(format: "%.2f", vm.boundR)))")
            let eyeLocal = SIMD3<Float>(-Viewmodel.anchorRight, Viewmodel.anchorDown, -Viewmodel.anchorFwd)
            check(simd_length(eyeLocal - vm.boundC) > vm.boundR, "\(k.def.name) viewmodel bound excludes the eye")
        }

        // front-end screens shouldn't crash
        FrontEnd.title(canvas, t: 1.0, hs: HighScores(fileURL: tmpURL()))
        ItemIcons.ensureRendered()
        for k in ItemKind.allCases {
            guard let s = ItemIcons.cached(k) else { check(false, "\(k) SDF icon rendered"); continue }
            let ink = s.pixels.lazy.filter { $0 >> 24 > 128 }.count
            check(ink > 24, "\(k) SDF icon has a body (\(s.w)×\(s.h), \(ink) px)")
        }
        for page in 0..<FrontEnd.intelPages { FrontEnd.intel(canvas, t: 1.0, page: page) }
        check(true, "front-end screens drew (all \(FrontEnd.intelPages) intel pages)")

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
