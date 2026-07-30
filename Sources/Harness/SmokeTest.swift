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
        // 1…8, not 1…6: the plant floors have their own room mix (machine halls, no dorms, no display
        // banks) and were the two this suite could not see. That blind spot is what let a mess hall
        // leak onto floor 8 unnoticed, and it is where the machinery — the largest solid object in the
        // game — now stands, so the reachability checks below need to run there most of all.
        for level in 1...8 {
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
            // …and reachable with the FURNITURE in the way. The check above walks the map, which knows
            // nothing about props — so a machine hall's 2.8-cell centrepiece, or a rank of compressors
            // narrowing a route, could wall the level off and this suite would still pass. Walk it at
            // half-cell resolution against the real collider set instead. Matters most on the plant
            // floors, where the machinery is the biggest solid object in the game.
            let pw = propWalk(level: level)
            check(walkableWithProps(pw), "L\(level) exit still reachable past the furniture")
            // …and so must every KEYCARD be. One flood answers both questions, so this costs nothing.
            let dry = unreachableKeys(pw)
            check(dry.isEmpty, "L\(level) every keycard is collectable past the furniture"
                             + (dry.isEmpty ? "" : " — STRANDED: \(dry.map { "\($0)" }.joined(separator: ", "))"))
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
            // The DEEPEST floor of a citadel has no down-lift: clearing it teleports to the next planet,
            // so its exit is an open receiver alcove with no car and no doors (see MapGen's teleporterPad).
            // Assert the right thing for each rather than skipping — a skipped case tests nothing.
            if Progression.isLastFloor(level) {
                check(m.floor[m.exitCell] == FlatTex.teleportPad.rawValue, "L\(level) exit is a teleporter pad (deepest floor)")
            } else {
                check(m.doors[m.exitCell] != nil, "L\(level) exit is an elevator (real door)")
            }
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

        // …and a WIDE sweep for stranded keycards, because this fault is probabilistic: it needs a
        // locked floor whose key room happens to furnish over the rolled cell, so one seed per depth
        // would miss it for weeks. Levels 2/4/6/8 span one-lock, two-lock and the plant floors.
        // The "cards seen" tally is not padding: without it, a change that stopped placing keys
        // altogether would turn every assertion above into a vacuous pass.
        // The seeds are the ones the GAME actually visits: Renderer derives each floor's seed as
        // `baseSeed + level * 1000` from a random per-run baseSeed, so sweeping arbitrary seeds would
        // explore a different space than play does. Levels 2–8 span one-lock, two-lock and the plant
        // floors. The "cards seen" tally is not padding: without it, a change that stopped placing
        // keys would turn every assertion here into a vacuous pass.
        var unwinnable: [String] = []
        var cardsSeen = 0, floorsSwept = 0, floorsCulled = 0, propsCulled = 0
        for base in stride(from: UInt64(1), through: 40, by: 1).map({ $0 &* 2_654_435_761 &+ 7 }) {
            for lv in 2...8 {
                let seed = base &+ UInt64(lv) &* 1000
                let ci = Progression.planetIndex(lv)
                let pw = propWalk(level: lv, colonyIndex: ci, seed: seed)
                let keyKinds = Set(KeyColor.allCases.map { $0.item })
                cardsSeen += pw.world.items.filter { keyKinds.contains($0.kind) }.count
                floorsSwept += 1
                // How often does the chokepoint cull actually act, and how much does it take? It is
                // meant to be a rescue for a rare bad roll, not routine redecorating — if this ever
                // starts reporting most floors, the fix has become the problem.
                let lostProps = MapGen.generate(level: lv, colonyIndex: ci, seed: seed).props.count
                              - pw.world.props.count
                if lostProps > 0 { floorsCulled += 1; propsCulled += lostProps }
                for d in keyDiagnosis(pw) { unwinnable.append("L\(lv)/base\(base) \(d)") }
                let win = winnable(level: lv, colonyIndex: ci, seed: seed)
                if !win.ok {
                    unwinnable.append("L\(lv)/base\(base) UNWINNABLE — \(win.why) || "
                                      + blockageReport(level: lv, colonyIndex: ci, seed: seed))
                }
            }
        }
        // ── the ending's TRAP, written down so it cannot be walked into twice ──
        // The final floor is also the last floor of its citadel, so it leaves by TELEPORTER, not by
        // lift. The teleport route installs the next world directly and never calls nextLevel() — so
        // an ending gated inside the lift branch gates the one route that can never reach it, and
        // finishing the game rolls quietly back to Demeter instead. Which is exactly what happened.
        // The gate must sit BEFORE the exit-type fork, where both routes still converge.
        let last = Progression.totalFloors
        check(Progression.isFinalFloor(last), "floor \(last) is the final floor")
        check(!Progression.isFinalFloor(last - 1), "floor \(last - 1) is not the final floor")
        check(Progression.isLastFloor(last),
              "the final floor exits by TELEPORTER — so the ending gate cannot live in the lift branch")
        check(Progression.totalFloors == Progression.floorsPerBuilding * Progression.planets.count,
              "the finish line is derived (\(Progression.planets.count) citadels × \(Progression.floorsPerBuilding) floors = \(last))")

        check(cardsSeen > 0, "the keycard sweep actually saw keycards (\(cardsSeen) across \(floorsSwept) floors)")
        check(floorsCulled * 20 <= floorsSwept,
              "the chokepoint cull stays a rescue, not routine (\(floorsCulled)/\(floorsSwept) floors, \(propsCulled) props)")
        check(unwinnable.isEmpty,
              "every floor winnable with locks AND furniture together (\(floorsSwept) floors)"
              + (unwinnable.isEmpty ? "" : " — \(unwinnable.count) BAD: \(unwinnable.prefix(6).joined(separator: " · "))"))

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
        // ── GENERATION DETERMINISM ── a fixed seed must build a byte-identical floor, in EVERY
        // process. Swift seeds its hashing per process, so ANY decision that rides the iteration
        // order of a Set or a Dictionary silently comes out differently run to run — and that is
        // precisely what made two shot frames flip: a room's walls were ranked by slot count alone
        // over a dictionary's keys, so tied walls (opposite walls of a rectangle — most rooms)
        // swapped, the furniture moved with them, and the pipe routing followed the furniture.
        //
        // Two guards, because they catch different faults:
        //   • the CHECK below regenerates the same seed after other floors have been built, which
        //     catches MapGen's `static var` room sets leaking from one floor into the next.
        //   • the printed GENHASH is for comparing across separate RUNS of this suite — equal
        //     within one process proves nothing about hash-order faults. One field per column, so
        //     a failure names the field that moved instead of being chased through the pictures.
        do {
            func fnv(_ vs: [Int]) -> UInt64 {
                var h: UInt64 = 0xcbf29ce484222325
                for v in vs { h = (h ^ UInt64(bitPattern: Int64(v))) &* 0x100000001b3 }
                return h
            }
            func q(_ vs: [Float]) -> [Int] { vs.map { Int(($0 * 1024).rounded()) } }
            func fields(_ g: GeneratedLevel) -> [(String, UInt64)] {
                let m = g.map
                return [("wall", fnv(m.wall)), ("pipe", fnv(q(m.pipe))), ("ceilY", fnv(q(m.ceilY))),
                        ("light", fnv(q(m.light))), ("hazard", fnv(m.hazard.map { $0 ? 1 : 0 })),
                        ("doors", fnv(m.doors.keys.sorted())),
                        ("props", fnv(g.props.flatMap { [$0.kind.rawValue] + q([$0.pos.x, $0.pos.y, $0.yaw]) })),
                        ("items", fnv(g.items.flatMap { [$0.kind.rawValue] + q([$0.pos.x, $0.pos.y]) })),
                        ("mobs", fnv(g.monsters.flatMap { [$0.kind.rawValue] + q([$0.pos.x, $0.pos.y]) })),
                        ("drums", fnv(q(g.drums.flatMap { [$0.x, $0.y] }))),
                        ("sockets", fnv(q(g.sockets.flatMap { [$0.pos.x, $0.pos.y] }))),
                        ("fittings", fnv(q(m.pipeFittings.flatMap { [$0.x, $0.y, $0.z, $0.w] })))]
            }
            let cases: [(Int, Int, UInt64)] = [(1, 0, 3), (3, 2, 11), (7, 0, 3), (8, 5, 99)]
            var first: [String: [(String, UInt64)]] = [:]
            for (lvl, ci, sd) in cases {
                let f = fields(MapGen.generate(level: lvl, colonyIndex: ci, seed: sd))
                first["\(lvl)/\(ci)/\(sd)"] = f
                print("GENHASH L\(lvl)/\(ci)/\(sd) " + f.map { "\($0.0)=\(String($0.1 % 100_000_000, radix: 36))" }.joined(separator: " "))
            }
            // …now build them all AGAIN, in the same order, after every other floor has been through
            // the generator. Anything held in a `static var` between calls shows up here.
            var drifted: [String] = []
            for (lvl, ci, sd) in cases {
                let key = "\(lvl)/\(ci)/\(sd)"
                let f = fields(MapGen.generate(level: lvl, colonyIndex: ci, seed: sd))
                for (i, entry) in f.enumerated() where entry.1 != first[key]?[i].1 { drifted.append("\(key):\(entry.0)") }
            }
            check(drifted.isEmpty, drifted.isEmpty
                  ? "a seed rebuilds the identical floor after other floors have been generated (\(cases.count) floors, \(fields(MapGen.generate(level: 1, colonyIndex: 0, seed: 3)).count) fields each)"
                  : "generation drifted on regeneration: \(drifted.joined(separator: ", "))")
        }

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
        }

        // 2b. flamethrower: standard issue, FINITE fuel, ignites + clears corpses
        let fw = World(level: 1, colonyIndex: 0, seed: 99)
        check(fw.player.has(.flamethrower), "flamethrower carried from the start")
        check(WeaponKind.flamethrower.def.ammo == .fuel, "flamethrower now runs on finite fuel")
        check(fw.player.ammoCount(.fuel) > 0, "marine starts with fuel (\(fw.player.ammoCount(.fuel)))")
        // A DRONE specifically: `first(where: alive)` took whatever the generator happened to put at
        // index 0, which is the QUEEN — and queenDeathTime is 2.8 s, so the 40-frame wait below could
        // never see her reach `.dead`. The whole passage is written around a drone corpse (0.45 s to
        // fall, then burnable), so name the caste rather than trust the array order.
        // CleanDroneDeaths forced OFF for this passage. It is on by default and a plasma kill then
        // gibs the drone, which would leave nothing to cremate and make every corpse check below
        // vacuously true — the same trap the plasma choice below was written to avoid. Both
        // mechanisms ship while the flag exists, so both are tested; the key is restored after.
        let hadClean = UserDefaults.standard.object(forKey: "CleanDroneDeaths")
        UserDefaults.standard.set(false, forKey: "CleanDroneDeaths")
        if let mi = fw.monsters.firstIndex(where: { $0.alive && $0.kind == .alien }) {
            let cpos = fw.monsters[mi].pos
            // Plasma, deliberately — DamageKind.explosive GIBS a drone and leaves nothing to burn,
            // which would make every corpse check below vacuously true.
            fw.projectiles.append(Projectile(pos: cpos, vel: .zero, kind: .plasma, damage: 999, fromPlayer: true, life: 0.01))
            for _ in 0..<40 { fw.update(dt: 1.0 / 60, input: InputState(), audio: audio) }   // die → corpse
            check(fw.monsters.contains { $0.state == .dead && !$0.gibbed }, "killed monster leaves a corpse")
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
            check(fw.monsters.contains { $0.state == .dead || $0.state == .dying }, "flag OFF: the drone still collapses to a corpse")
        }
        if let h = hadClean { UserDefaults.standard.set(h, forKey: "CleanDroneDeaths") }
        else { UserDefaults.standard.removeObject(forKey: "CleanDroneDeaths") }

        // ── CLEAN DRONE DEATHS ── the drone that leaves nothing. Asserted BOTH WAYS: the block above
        // proves the collapse still happens with the flag off, this one proves plasma disposes of the
        // body with it on. One direction alone would not distinguish "the flag works" from "the flag
        // is ignored and drones never crumpled anyway".
        do {
            UserDefaults.standard.removeObject(forKey: "CleanDroneDeaths")      // default = ON
            check(FeatureFlags.cleanDroneDeaths, "CleanDroneDeaths defaults ON")
            /// Kill the first drone with `weapon` and report what was left of it.
            func killDrone(_ weapon: ProjectileKind) -> (gibbed: Bool, burn: Float, corpses: Int, offal: Int)? {
                let w = World(level: 1, colonyIndex: 0, seed: 99)
                guard let mi = w.monsters.firstIndex(where: { $0.alive && $0.kind == .alien }) else { return nil }
                w.projectiles.append(Projectile(pos: w.monsters[mi].pos, vel: .zero, kind: weapon,
                                                damage: 999, fromPlayer: true, life: 0.01))
                for _ in 0..<40 { w.update(dt: 1.0 / 60, input: InputState(), audio: audio) }
                return (w.monsters[mi].gibbed, w.monsters[mi].burn,
                        w.monsters.filter { $0.state == .dead && !$0.gibbed }.count,
                        w.decals.filter { $0.w < -2 }.count)
            }
            if let plasma = killDrone(.plasma), let rocket = killDrone(.rocket) {
                check(plasma.gibbed, "flag ON: a plasma kill bursts the drone (no posture change)")
                // burn ≥ 0.85 is the EXACT condition the corpse collider (World.free) and the
                // door-occupancy set both test, so this one number is why a burst drone can never
                // block a corridor or jam a door on you.
                check(plasma.burn >= 1, "flag ON: nothing left to cremate — burn \(String(format: "%.2f", plasma.burn))")
                check(plasma.corpses == 0, "flag ON: a plasma kill leaves no corpse anywhere (\(plasma.corpses))")
                check(rocket.gibbed, "a rocket kill still bursts the drone")
                // THE BUDGET CLAIM, asserted rather than trusted. decalCap is 72 and the rocket
                // blast spends 22 of them; plasma is the workhorse at ~30 kills a floor, so if it
                // ever spent the same the buffer would recycle nine times over and every kill but
                // the last two would have its gore evicted. Offal (w < −2) is the discriminator:
                // the blast strews 10, the bolt leaves 1.
                check(plasma.offal < rocket.offal,
                      "a plasma burst is decal-cheap beside the blast (offal \(plasma.offal) vs \(rocket.offal))")
            }
            // THE PLASMA BURST DOES NOT SPLASH. Each drone takes three direct hits and bursts ALONE —
            // the gore is cosmetic, not a detonation. Asserted because the tempting implementation is
            // to reuse `explode()` for the effect, which would silently turn a packed group into a
            // chain reaction: a large balance change arriving as a rendering convenience. A rocket
            // into the same pack SHOULD take the group, and does (splash 2.0 cells), so the two are
            // measured against each other here rather than in isolation.
            let pw = World(level: 1, colonyIndex: 0, seed: 3)
            if let base = pw.monsters.first(where: { $0.kind == .alien }) {
                var d = base
                let hub = pw.monsters[0].pos
                pw.monsters = []
                for k in 0..<6 {                                  // packed at the AI's own separation floor
                    let a = Float(k) * 1.047
                    d.pos = hub + SIMD2(cosf(a), sinf(a)) * (k == 0 ? 0 : 0.8)
                    guard !pw.map.blocksMovement(Int(d.pos.x), Int(d.pos.y)) else { continue }
                    d.state = .chase; d.awake = true; d.burn = 0; d.gibbed = false
                    pw.monsters.append(d)
                }
                if pw.monsters.count >= 4 {
                    let packed = pw.monsters.count
                    pw.damageMonsterForTest(0, 999, audio: audio, kind: .plasma)
                    let burst = pw.monsters.filter { $0.gibbed }.count
                    check(burst == 1, "a plasma kill bursts ONE drone in a pack of \(packed), not the pack (\(burst))")
                    check(pw.monsters.filter { $0.alive }.count == packed - 1,
                          "the other \(packed - 1) drones in the pack are untouched")
                    // the contrast: one rocket in the same pack SHOULD take the group
                    let rw = World(level: 1, colonyIndex: 0, seed: 3)
                    rw.monsters = pw.monsters.map { var m = $0; m.gibbed = false; m.burn = 0; m.health = base.health; m.state = .chase; return m }
                    rw.projectiles.append(Projectile(pos: hub, vel: .zero, kind: .rocket, damage: 999, fromPlayer: true, life: 0.01))
                    rw.update(dt: 1.0 / 60, input: InputState(), audio: audio)
                    check(rw.monsters.filter { $0.gibbed }.count > 1,
                          "one rocket in the same pack takes the group (\(rw.monsters.filter { $0.gibbed }.count) of \(packed))")
                }
            }
        }
        // ── YOU HIT WHAT YOU SEE ────────────────────────────────────────────────────────────────
        //
        // A creature's mesh is far larger than its 0.4-cell collision radius, so the body is DRAWN
        // settled clear of walls and furniture — up to a footprint-radius off its logical `pos`.
        // That offset was render-only while combat still tested `pos`, and the two disagreed: you
        // aimed at the drone you could SEE and the shot went through empty air beside the one the
        // sim held. Plasma was worse still, because its lock needs line-of-sight and `pos` can be
        // INSIDE a wall — the very case the resolve exists to hide — so the test failed outright
        // and a drone in plain view got no reticle at all.
        //
        // These install a STUB resolve rather than a real mesh (the smoke suite is headless, and a
        // real resolve only bites near a wall). The plumbing is what has to hold, and the offset is
        // deliberately larger than any real resolve so the drawn and logical positions cannot be
        // confused by a test that only just passes.
        do {
            let slack = MonsterKind.alien.def.radius + World.hitscanPerpSlack   // how far a pellet may miss by
            let offset = slack * 2                                             // clear of it, so a hit names ONE position
            // an open cell with a clear straight run to stand a drone in
            func aimStand(_ w: World) -> (eye: SIMD2<Float>, at: SIMD2<Float>, ahead: SIMD2<Float>)? {
                let m = w.map
                func open(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && !m.blocksSight(x, y) }
                for y in 1..<(m.h - 1) { for x in 1..<(m.w - 1) where open(x, y) {
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        var n = 1
                        while open(x + dx * n, y + dy * n) { n += 1 }
                        guard n >= 4 else { continue }
                        let eye = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                        let ahead = SIMD2<Float>(Float(dx), Float(dy))
                        // Close enough that the offset falls OUTSIDE the assist cone: past
                        // offset/tan(arc) the cone is wide enough to swallow both positions and the
                        // test could no longer tell which one the lock had used.
                        return (eye, eye + ahead * (offset / tanf(World.plasmaAimArc) * 0.5), ahead)
                    }
                } }
                return nil
            }
            // (a) the reticle, and the shot, follow the DRAWN body
            let w = World(level: 1, colonyIndex: 0, seed: 909)
            if let g = aimStand(w) {
                let lateral = SIMD2<Float>(-g.ahead.y, g.ahead.x)
                var drone = w.monsters.first(where: { $0.kind == .alien }) ?? Monster(kind: .alien, pos: g.at)
                drone.pos = g.at; drone.state = .idle; drone.health = drone.def.maxHealth
                w.monsters = [drone]
                w.meshPoseResolve = { _, pos, _, _, _, _ in pos + lateral * offset }
                w.refreshDrawnPositions()
                let drawn = w.monsters[0].drawnPos
                check(vlen(drawn - (g.at + lateral * offset)) < 0.001,
                      String(format: "the sim publishes the DRAWN position (%.2f,%.2f vs logical %.2f,%.2f)",
                             drawn.x, drawn.y, g.at.x, g.at.y))

                w.player.pos = g.eye; w.player.current = .plasma
                w.player.dir = atan2(drawn.y - g.eye.y, drawn.x - g.eye.x)      // aim at the body ON SCREEN
                w.acquirePlasmaTargetForTest()
                let lock = w.plasmaLockPos
                check(lock != nil && vlen(lock! - drawn) < 0.001,
                      "aiming at the drawn body LOCKS it, and locks onto where it is drawn")

                w.player.dir = atan2(g.at.y - g.eye.y, g.at.x - g.eye.x)        // aim at the logical centre
                w.acquirePlasmaTargetForTest()
                check(w.plasmaLockPos == nil,
                      "aiming at the invisible logical centre does NOT lock — the assist follows the mesh")

                let hitDrawn = w.hitscanForTest(angle: atan2(drawn.y - g.eye.y, drawn.x - g.eye.x),
                                                range: 20, audio: audio)
                let hitLogical = w.hitscanForTest(angle: atan2(g.at.y - g.eye.y, g.at.x - g.eye.x),
                                                  range: 20, audio: audio)
                check(hitDrawn == 0 && hitLogical < 0,
                      "pellets land on the drawn body and pass by the logical one (\(hitDrawn) / \(hitLogical))")
            }
            // (b) THE REPORTED BUG: a drone whose logical centre is buried in a wall. The resolve
            // exists to eject the mesh into the open, so the player sees it plainly — and until the
            // sim owned that position, the lock's sight line ran to a point inside the wall and
            // failed, which is why aiming straight at a drone sometimes gave no reticle at all.
            for resolved in [true, false] {
                let bw = World(level: 1, colonyIndex: 0, seed: 909)
                guard let g = aimStand(bw) else { break }
                let m = bw.map
                // a solid cell beside the run, for the drone's centre to sit inside
                let cell = SIMD2<Int>(Int(g.at.x), Int(g.at.y))
                var buried: SIMD2<Float>? = nil
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let bx = cell.x + dx, by = cell.y + dy
                    if m.inBounds(bx, by), m.blocksSight(bx, by) { buried = SIMD2(Float(bx) + 0.5, Float(by) + 0.5); break }
                }
                guard let inWall = buried else { break }
                var drone = bw.monsters.first(where: { $0.kind == .alien }) ?? Monster(kind: .alien, pos: inWall)
                drone.pos = inWall; drone.state = .idle; drone.health = drone.def.maxHealth
                bw.monsters = [drone]
                // resolved: the mesh is settled out into the open cell, as a real resolve would.
                // unresolved: no hook at all — drawnPos stays equal to pos, which is the old behaviour.
                if resolved { bw.meshPoseResolve = { _, _, _, _, _, _ in g.at } }
                bw.refreshDrawnPositions()
                bw.player.pos = g.eye; bw.player.current = .plasma
                bw.player.dir = atan2(g.at.y - g.eye.y, g.at.x - g.eye.x)
                bw.acquirePlasmaTargetForTest()
                check((bw.plasmaLockPos != nil) == resolved,
                      resolved ? "a drone whose centre is INSIDE a wall still locks, because the mesh you see is in the open"
                               : "...and with no resolve it does not — the sight line ends in the wall (the bug, reproduced)")
            }
            // (c) a settled CORPSE resolves ONCE and stays. It never moves again and its resolve
            // ignores doors, so re-resolving it can only make a body twitch across the room; a LIVE
            // drone must keep tracking, because it walks and doors swing shut beside it.
            let cw = World(level: 1, colonyIndex: 0, seed: 909)
            if let g = aimStand(cw) {
                var live = cw.monsters.first(where: { $0.kind == .alien }) ?? Monster(kind: .alien, pos: g.at)
                live.pos = g.at; live.state = .idle
                var dead = live; dead.state = .dead
                cw.monsters = [live, dead]
                var nudge: Float = 1
                cw.meshPoseResolve = { _, pos, _, _, _, _ in pos + SIMD2(nudge, 0) }
                cw.refreshDrawnPositions()
                let settled = cw.monsters[1].drawnPos
                nudge = 5                                    // the resolve now answers differently
                cw.refreshDrawnPositions()
                check(vlen(cw.monsters[1].drawnPos - settled) < 0.001,
                      "a settled corpse is resolved once and stays put")
                check(vlen(cw.monsters[0].drawnPos - settled) > 0.001,
                      "a live drone keeps re-resolving as it moves")
            }
        }

        // ── PLANT MACHINERY HUM ── the compressors' proximity bed on floors 7–8. Asserted rather than
        // listened to: it has to be SILENT where there is no machinery, and it has to SWELL as you
        // close on a machine, which is the whole point of a positional bed over an ambient one.
        do {
            let quiet = World(level: 1, colonyIndex: 0, seed: 4242)
            for _ in 0..<40 { quiet.update(dt: 1.0 / 60, input: InputState(), audio: audio) }
            check(quiet.machineSiteCountForTest == 0 && quiet.machineHumLevelForTest == 0,
                  "no machinery hum on the upper floors (level 1)")

            let plant = World(level: 7, colonyIndex: 0, seed: 4242)
            for _ in 0..<40 { plant.update(dt: 1.0 / 60, input: InputState(), audio: audio) }
            check(plant.machineSiteCountForTest > 0, "plant floor has machinery to hear (\(plant.machineSiteCountForTest) sites)")
            if let m = plant.props.first(where: { $0.kind == .machineCompressor }) {
                // settle FAR from every machine, then settle right beside one — the level must rise.
                func settle(at p: SIMD2<Float>) -> Float {
                    plant.player.pos = p
                    for _ in 0..<180 { plant.update(dt: 1.0 / 60, input: InputState(), audio: audio) }
                    return plant.machineHumLevelForTest
                }
                var far = m.pos, best: Float = 0
                for c in plant.props where !plant.map.blocksMovement(Int(c.pos.x), Int(c.pos.y)) {
                    let d = plant.props.filter { $0.kind == .machineCompressor }.map { vlen($0.pos - c.pos) }.min() ?? 0
                    if d > best { best = d; far = c.pos }
                }
                let away = settle(at: far), near = settle(at: m.pos)
                check(near > away, "machinery hum swells with approach (\(String(format: "%.2f → %.2f", away, near)))")
                check(away > 0, "a plant floor is never wholly silent (floor bed \(String(format: "%.2f", away)))")
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
        let gpu = MTLCreateSystemDefaultDevice().flatMap { RasterRenderer(device: $0) }
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

        // ── THE CEREMONY'S CROWD ── the mix cannot be listened to from here, so its shape is
        // asserted instead. The load-bearing one is the FIRST: the citation is read, not heard,
        // and a cheer landing under it would take the words with it. That is also the reason the
        // crowd is cut into segments at all rather than played as one continuous take.
        do {
            let cite = EndingArt.citationTime
            var loudestUnderText: Float = 0, lastCheer: Float = 0, lastChant: Float = 0
            var minBed = Float.greatestFiniteMagnitude
            var t: Float = 0
            while t < EndingArt.duration {
                let c = EndingArt.crowd(at: t)
                if t < cite - EndingArt.dissolve { loudestUnderText = max(loudestUnderText, max(c.cheer, c.chant)) }
                lastCheer = c.cheer; lastChant = c.chant
                minBed = min(minBed, c.bed)
                t += 1.0 / 30
            }
            check(loudestUnderText == 0, "no cheer fires under the citation — the words have to read")
            check(minBed > 0, "the hall is never silent inside the ceremony (quietest bed \(String(format: "%.2f", minBed)))")
            check(EndingArt.crowd(at: 0).bed == EndingArt.crowdQuiet, "the hall opens quiet, at the bed's floor")
            // each swell peaks on the cut it belongs to, and the medal outranks the raised hands
            let medal = EndingArt.crowd(at: cite + 1.0), hands = EndingArt.crowd(at: cite + 5.0)
            check(medal.cheer > 0.9, "the cheer is at full on the medal (\(String(format: "%.2f", medal.cheer)))")
            check(medal.bed > EndingArt.crowdQuiet, "the bed has lifted for the release")
            check(hands.chant > 0.9, "the chant is at full on the raised hands (\(String(format: "%.2f", hands.chant)))")
            check(lastCheer == 0 && lastChant == 0, "both swells have released before the ceremony ends")
            // The hall must still be there when the fade to black starts, so the fade is what takes
            // it out. Zeroing at `duration` instead would cut a packed auditorium off mid-breath one
            // frame before the picture began to go.
            let tail = EndingArt.crowd(at: EndingArt.duration + 5)
            check(tail.bed > 0 && abs(tail.bed - EndingArt.crowd(at: EndingArt.duration - 0.01).bed) < 0.001,
                  "the hall is HELD through the run to black for the fade to carry out (\(String(format: "%.2f", tail.bed)))")
            // a swell that outlasted its stem would wrap and audibly restart the crowd mid-cheer
            check(EndingArt.swellHolds.allSatisfy { $0 <= EndingArt.crowdSwellSeconds },
                  "no swell outlasts its \(EndingArt.crowdSwellSeconds)s stem (holds \(EndingArt.swellHolds))")
        }

        // ── THE CODA ── the last card, and the last thing the game ever shows. It is reached only
        // by finishing all 48 floors, so nobody will stumble over a fault in it; assert it instead.
        do {
            func ink(_ t: Float) -> Int {
                canvas.clear()
                FrontEnd.coda(canvas, t: t)
                return (0..<(RenderConfig.width * RenderConfig.height))
                    .lazy.filter { (canvas.framebuffer[$0] & 0x00FF_FFFF) != 0 }.count
            }
            let black = ink(0), arriving = ink(FrontEnd.codaIn * 0.4), arrived = ink(FrontEnd.codaIn + 1)
            check(black == 0, "the coda opens on pure black (\(black) lit px)")
            check(arrived > 400, "the line is there once it has risen (\(arrived) lit px)")
            check(arriving > 0 && arriving < arrived, "it FADES up rather than switching on (\(arriving) → \(arrived))")
            // "nothing else on the screen" is a design instruction, so it is enforced rather than
            // trusted: the card carries the sentence and no prompt, no seal, no score.
            canvas.clear()
            FrontEnd.coda(canvas, t: FrontEnd.codaIn + 1)
            var top = RenderConfig.height, bot = 0, left = RenderConfig.width, right = 0
            for y in 0..<RenderConfig.height { for x in 0..<RenderConfig.width
                where (canvas.framebuffer[y * RenderConfig.width + x] & 0x00FF_FFFF) != 0 {
                top = min(top, y); bot = max(bot, y); left = min(left, x); right = max(right, x)
            } }
            check(bot - top < RenderConfig.height / 4,
                  "everything on the card sits in ONE band — one line, nothing else (\(bot - top) px tall)")
            check(left > 0 && right < RenderConfig.width - 1,
                  "the line is sized to the frame and never touches an edge (x \(left)…\(right) of \(RenderConfig.width))")
        }

        // ── THE TALLY, BOTH WAYS ── the score screen had no coverage at all, and it is where BOTH
        // endings now land: 48 floors is the highest-scoring run the game has, so a victory that
        // failed to reach this screen would cost a player the one place in the Hall they had
        // actually earned. The victory variant in particular was unreachable for a while, which is
        // exactly how a screen rots unnoticed.
        do {
            let tw = World(level: Progression.totalFloors, colonyIndex: 5, seed: 77)
            let ti = InputState()
            for (victory, name) in [(false, "death"), (true, "victory")] {
                canvas.clear()
                FrontEnd.gameOver(canvas, world: tw, input: ti, qualifies: true, t: 0.1, victory: victory)
                let lit = (0..<(RenderConfig.width * RenderConfig.height))
                    .lazy.filter { (canvas.framebuffer[$0] & 0x00FF_FFFF) != 0 }.count
                check(lit > 100_000, "the \(name) tally draws (\(lit) lit px)")
                // The heading MUST NOT touch a frame edge. "CLUSTER RETAKEN" did exactly that —
                // clipped at both sides — and stayed that way because nothing ever drew it. The
                // backdrop is a gradient, so measure the heading's own band rather than the frame.
                let band = uiS(40)..<uiS(150)
                var left = RenderConfig.width, right = 0
                for y in band { for x in 0..<RenderConfig.width {
                    let p = canvas.framebuffer[y * RenderConfig.width + x]
                    let lum = Int(p & 0xFF) + Int((p >> 8) & 0xFF) + Int((p >> 16) & 0xFF)
                    if lum > 300 { left = min(left, x); right = max(right, x) }     // the heading, not the gradient
                } }
                check(left > 0 && right < RenderConfig.width - 1,
                      "the \(name) heading is fitted to the frame, never clipped (x \(left)…\(right) of \(RenderConfig.width))")
            }
            // the run that reaches the ending is the one that must qualify — assert the wiring the
            // tally depends on, since a score of 0 would silently skip name entry
            check(tw.level == Progression.totalFloors, "a finished run reports all \(Progression.totalFloors) floors")
        }

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

    /// One furniture-aware flood of a level, then answerable at any world position.
    ///
    /// `reachableIgnoringLocks` walks the map, which knows nothing about furniture — so it would pass a
    /// level whose only route was blocked by a machine. This builds the real World (which derives
    /// `propColliders` from the authored geometry) and floods a HALF-CELL grid, rejecting any node the
    /// player's own radius could not occupy. Half-cell because a 1-wide corridor with a prop pushed
    /// into it can still be passable down one side, and a whole-cell test would call that solid.
    ///
    /// Locked doors count as OPEN, which makes this a one-directional test — "can the marine physically
    /// get there at all" — and therefore free of false alarms: whatever it rejects is unreachable however
    /// the locks are ordered. Lock ORDERING is `MapGen.solvable()`'s business, not this flood's.
    private struct PropWalk {
        let world: World
        let step: Float
        let nx: Int, ny: Int
        let seen: Set<Int>

        /// Is any part of map cell (cx, cy) reachable? A whole cell spans a 2×2 block of half-cell
        /// nodes, and a route can arrive at any of them — testing only the centre one invents blockages.
        func reachedCell(_ cx: Int, _ cy: Int) -> Bool {
            guard cx >= 0, cy >= 0 else { return false }
            for sy in 0...1 { for sx in 0...1 {
                let jx = cx * 2 + sx, jy = cy * 2 + sy
                if jx < nx, jy < ny, seen.contains(jy * nx + jx) { return true }
            } }
            return false
        }

        /// Could the marine stand somewhere that puts `p` within `within` of her centre?
        /// Node centres sit on a half-cell lattice, so allow half a step of quantisation slack —
        /// generous by design, because a test that cries wolf gets ignored.
        func canReach(_ p: SIMD2<Float>, within: Float) -> Bool {
            let reach = within + step * 0.5
            let span = Int((reach / step).rounded(.up))
            let ix = Int(p.x / step), iy = Int(p.y / step)
            for oy in -span...span { for ox in -span...span {
                let jx = ix + ox, jy = iy + oy
                guard jx >= 0, jy >= 0, jx < nx, jy < ny else { continue }
                let c = SIMD2((Float(jx) + 0.5) * step, (Float(jy) + 0.5) * step)
                if vlen(c - p) <= reach, seen.contains(jy * nx + jx) { return true }
            } }
            return false
        }
    }

    private static func propWalk(level: Int, colonyIndex: Int? = nil, seed: UInt64? = nil) -> PropWalk {
        let w = World(level: level, colonyIndex: colonyIndex ?? (level - 1),
                      seed: seed ?? (UInt64(level) &* 7919 &+ 13))
        let m = w.map
        let r: Float = 0.28                                  // a shade under the player's own radius
        let step: Float = 0.5
        let nx = Int(Float(m.w) / step), ny = Int(Float(m.h) / step)
        func free(_ ix: Int, _ iy: Int) -> Bool {
            let px = (Float(ix) + 0.5) * step, py = (Float(iy) + 0.5) * step
            let cx = Int(px), cy = Int(py)
            guard m.inBounds(cx, cy), m.wall[m.idx(cx, cy)] == 0 || m.doors[m.idx(cx, cy)] != nil else { return false }
            return !w.blockedBySolidProp(px, py, r)
        }
        let start = Int(m.playerStart.y / step) * nx + Int(m.playerStart.x / step)
        var seen = Set<Int>([start])
        var q = [start], qi = 0
        while qi < q.count {
            let cur = q[qi]; qi += 1
            let ix = cur % nx, iy = cur / nx
            for (jx, jy) in [(ix - 1, iy), (ix + 1, iy), (ix, iy - 1), (ix, iy + 1)] {
                guard jx >= 0, jy >= 0, jx < nx, jy < ny else { continue }
                let n = jy * nx + jx
                if !seen.contains(n), free(jx, jy) { seen.insert(n); q.append(n) }
            }
        }
        return PropWalk(world: w, step: step, nx: nx, ny: ny, seen: seen)
    }

    /// Can the marine actually WALK from the arrival car to the exit, with every solid prop in place?
    private static func walkableWithProps(_ pw: PropWalk) -> Bool {
        let m = pw.world.map
        // the exit switch counts as reached if any node on its cell — or a neighbouring one — is in
        let ex = m.exitCell % m.w, ey = m.exitCell / m.w
        for (ox, oy) in [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1)] {
            if pw.reachedCell(ex + ox, ey + oy) { return true }
        }
        return false
    }

    /// The COMPLETE winnability test: a keyed flood over the FURNITURE-AWARE grid.
    ///
    /// The two checks that came before it each see half the problem, and a floor can be unwinnable
    /// while passing both:
    ///   • `MapGen.solvable()` reasons about lock ORDER, but over the bare map grid — blind to a route
    ///     a machine blocks.
    ///   • `propWalk` sees furniture, but treats every lock as open — blind to a card sealed behind
    ///     the very door it opens.
    /// Put a keycard where furniture blocks its only approach and both pass: the mask never gets set,
    /// so the locked door never opens, so the exit is unreachable. State is (half-cell node, key mask)
    /// — the product `solvable()` already walks, moved onto the finer prop-aware grid.
    private static func winnable(level: Int, colonyIndex: Int, seed: UInt64,
                                 ignoreProps: Bool = false) -> (ok: Bool, why: String) {
        let w = World(level: level, colonyIndex: colonyIndex, seed: seed)
        let m = w.map
        let r: Float = 0.28, step: Float = 0.5
        let nx = Int(Float(m.w) / step), ny = Int(Float(m.h) / step)
        let keyKinds = Set(KeyColor.allCases.map { $0.item })
        let keys = w.items.filter { keyKinds.contains($0.kind) }
        let pickR = Float(0.5) + step * 0.5              // World.pickups distance + lattice slack

        /// Cell-level passability for a node, given the keys held.
        func free(_ ix: Int, _ iy: Int, _ mask: Int) -> Bool {
            let px = (Float(ix) + 0.5) * step, py = (Float(iy) + 0.5) * step
            let cx = Int(px), cy = Int(py)
            guard m.inBounds(cx, cy) else { return false }
            let ci = m.idx(cx, cy)
            if m.wall[ci] != 0 {
                guard let d = m.doors[ci] else { return false }
                if let lock = d.locked, (mask & (1 << lock.rawValue)) == 0 { return false }
            }
            return ignoreProps || !w.blockedBySolidProp(px, py, r)
        }
        func maskAt(_ ix: Int, _ iy: Int, _ mask: Int) -> Int {
            let p = SIMD2((Float(ix) + 0.5) * step, (Float(iy) + 0.5) * step)
            var out = mask
            for k in keys where vlen(k.pos - p) <= pickR {
                if let kc = KeyColor.allCases.first(where: { $0.item == k.kind }) { out |= 1 << kc.rawValue }
            }
            return out
        }

        let sx = Int(m.playerStart.x / step), sy = Int(m.playerStart.y / step)
        let start = sy * nx + sx
        var seen = Set<Int>()
        var q = [(start, maskAt(sx, sy, 0))]
        seen.insert(start * 8 + q[0].1)
        var qi = 0
        let ex = m.exitCell % m.w, ey = m.exitCell / m.w
        // A whole map cell covers FOUR half-cell nodes (2×2), so register all of them per cell. Taking
        // only the node under the cell CENTRE reads a route that arrives via the other half as blocked —
        // which is exactly the false alarm this line originally produced.
        var exitNodes = Set<Int>()
        for (ox, oy) in [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1)] {
            let cx = ex + ox, cy = ey + oy
            guard cx >= 0, cy >= 0 else { continue }
            for sy in 0...1 { for sx in 0...1 {
                let jx = cx * 2 + sx, jy = cy * 2 + sy
                if jx < nx, jy < ny { exitNodes.insert(jy * nx + jx) }
            } }
        }
        while qi < q.count {
            let (cur, mask) = q[qi]; qi += 1
            if exitNodes.contains(cur) { return (true, "") }
            let ix = cur % nx, iy = cur / nx
            for (jx, jy) in [(ix - 1, iy), (ix + 1, iy), (ix, iy - 1), (ix, iy + 1)] {
                guard jx >= 0, jy >= 0, jx < nx, jy < ny, free(jx, jy, mask) else { continue }
                let n = jy * nx + jx
                let nm = maskAt(jx, jy, mask)
                if !seen.contains(n * 8 + nm) { seen.insert(n * 8 + nm); q.append((n, nm)) }
            }
        }
        // Characterise the failure so a hit is diagnosable rather than just red.
        let got = q.reduce(0) { $0 | $1.1 }
        let missed = keys.filter { k in
            guard let kc = KeyColor.allCases.first(where: { $0.item == k.kind }) else { return false }
            return (got & (1 << kc.rawValue)) == 0
        }
        if !missed.isEmpty {
            return (false, "could not collect \(missed.map { "\($0.kind)" }.joined(separator: "/"))")
        }
        // Cards all in hand and still no exit → something physical is in the way. Name what: the exit
        // cell, and every solid prop close enough to be sitting in its approach.
        let near = w.props.filter { vlen($0.pos - SIMD2(Float(ex) + 0.5, Float(ey) + 0.5)) < 3.0 }
            .sorted { vlen($0.pos - SIMD2(Float(ex) + 0.5, Float(ey) + 0.5))
                    < vlen($1.pos - SIMD2(Float(ex) + 0.5, Float(ey) + 0.5)) }.prefix(6)
            .map { "\($0.kind)@\(String(format: "%.2f", vlen($0.pos - SIMD2(Float(ex) + 0.5, Float(ey) + 0.5))))" }
        // Which FAMILY of fault is this? Re-run the identical flood with furniture collision off. If the
        // exit opens up, some prop mid-route is the wall; if it stays shut, the fault is in the map or
        // lock topology and no amount of moving furniture will help. One bit, and it decides the fix.
        let blame = ignoreProps ? "map/lock topology (furniture is not the cause)"
                  : (winnable(level: level, colonyIndex: colonyIndex, seed: seed, ignoreProps: true).ok
                     ? "FURNITURE blocks the route" : "map/lock topology — furniture is NOT the cause")
        return (false, "exit at (\(ex),\(ey)) unreachable with all \(keys.count) card(s) in hand — \(blame)"
                     + (near.isEmpty ? "; no props within 3 cells of the exit" : "; props at exit: " + near.joined(separator: ", ")))
    }

    /// Exactly WHAT is walling a floor off. Floods twice — with solids and without — diffs the two,
    /// and reports the frontier where the lost region meets the reachable one, naming every prop and
    /// drum standing at it. `blockedBySolidProp` counts drums as well as furniture, so "furniture
    /// blocks the route" is not by itself enough to know what to move.
    private static func blockageReport(level: Int, colonyIndex: Int, seed: UInt64) -> String {
        let w = World(level: level, colonyIndex: colonyIndex, seed: seed)
        let m = w.map
        let r: Float = 0.28, step: Float = 0.5
        let nx = Int(Float(m.w) / step), ny = Int(Float(m.h) / step)
        func flood(_ solids: Bool) -> Set<Int> {
            func free(_ ix: Int, _ iy: Int) -> Bool {
                let px = (Float(ix) + 0.5) * step, py = (Float(iy) + 0.5) * step
                let cx = Int(px), cy = Int(py)
                guard m.inBounds(cx, cy) else { return false }
                let ci = m.idx(cx, cy)
                if m.wall[ci] != 0, m.doors[ci] == nil { return false }
                return !solids || !w.blockedBySolidProp(px, py, r)
            }
            let s = Int(m.playerStart.y / step) * nx + Int(m.playerStart.x / step)
            var seen = Set<Int>([s]), q = [s], qi = 0
            while qi < q.count {
                let cur = q[qi]; qi += 1
                let ix = cur % nx, iy = cur / nx
                for (jx, jy) in [(ix - 1, iy), (ix + 1, iy), (ix, iy - 1), (ix, iy + 1)] {
                    guard jx >= 0, jy >= 0, jx < nx, jy < ny else { continue }
                    let n = jy * nx + jx
                    if !seen.contains(n), free(jx, jy) { seen.insert(n); q.append(n) }
                }
            }
            return seen
        }
        let withS = flood(true), bare = flood(false)
        let lost = bare.subtracting(withS)
        // Did World's chokepoint cull actually fire? Compare the props that survived against what
        // MapGen emitted: equal counts mean the cull declined to act, which is a different bug from
        // the cull acting and not being enough.
        let generated = MapGen.generate(level: level, colonyIndex: colonyIndex, seed: seed).props.count
        var lines = ["lost \(lost.count) half-cell nodes to solids",
                     "props \(generated) generated → \(w.props.count) live (cull \(generated == w.props.count ? "DID NOT FIRE" : "removed \(generated - w.props.count)"))"]
        var shown = 0
        for n in lost.sorted() where shown < 4 {
            let ix = n % nx, iy = n / nx
            let onFrontier = [(ix - 1, iy), (ix + 1, iy), (ix, iy - 1), (ix, iy + 1)].contains {
                $0.0 >= 0 && $0.1 >= 0 && $0.0 < nx && $0.1 < ny && withS.contains($0.1 * nx + $0.0)
            }
            guard onFrontier else { continue }
            shown += 1
            let p = SIMD2<Float>((Float(ix) + 0.5) * step, (Float(iy) + 0.5) * step)
            let np = w.props.filter { vlen($0.pos - p) < 1.6 }
                .map { "\($0.kind)@\(String(format: "%.2f", vlen($0.pos - p)))" }
            let nd = w.drums.filter { vlen($0.pos - p) < 1.6 }
                .map { "DRUM@\(String(format: "%.2f", vlen($0.pos - p)))" }
            let what = (np + nd).isEmpty ? "nothing within 1.6 — a wall-adjacent pinch"
                                         : (np + nd).joined(separator: ", ")
            lines.append("frontier (\(String(format: "%.2f", p.x)),\(String(format: "%.2f", p.y))): \(what)")
        }
        return lines.joined(separator: " | ")
    }

    /// WHY a card is unreachable. A red assertion that names the obstruction is worth ten that only
    /// say "no": the whole point of catching this in a sweep rather than in play is that the sweep can
    /// hand you the mechanism instead of a seed to go and stare at.
    private static func keyDiagnosis(_ pw: PropWalk) -> [String] {
        let m = pw.world.map
        let keyKinds = Set(KeyColor.allCases.map { $0.item })
        var out: [String] = []
        for k in pw.world.items where keyKinds.contains(k.kind) && !pw.canReach(k.pos, within: 0.5) {
            let cx = Int(k.pos.x), cy = Int(k.pos.y)
            let ci = m.idx(cx, cy)
            var notes = ["cell (\(cx),\(cy))"]
            notes.append(m.wall[ci] != 0 ? "IN A WALL (tex \(m.wall[ci]))" : "on floor")
            if m.doors[ci] != nil { notes.append("on a DOOR cell") }
            if m.hazard[ci] { notes.append("in HAZARD") }
            if pw.world.blockedBySolidProp(k.pos.x, k.pos.y, 0.28) { notes.append("INSIDE a solid prop") }
            let near = pw.world.props.filter { vlen($0.pos - k.pos) < 2.0 }
                .sorted { vlen($0.pos - k.pos) < vlen($1.pos - k.pos) }.prefix(4)
                .map { "\($0.kind)@\(String(format: "%.2f", vlen($0.pos - k.pos)))" }
            if !near.isEmpty { notes.append("nearest props: " + near.joined(separator: ", ")) }
            out.append("\(k.kind) — " + notes.joined(separator: "; "))
        }
        return out
    }

    /// Every KEYCARD must be physically collectable. An unreachable card is an unwinnable floor —
    /// the same severity as an unreachable exit — and nothing tested for it, because the two checks
    /// that look adjacent each miss it from opposite sides: `MapGen.solvable()` reasons over the map
    /// GRID and knows nothing about furniture, while the flood above is furniture-aware but only ever
    /// asked about the EXIT. A card inside a canteen range or walled in by a bank of lockers satisfied
    /// both. `within: 0.5` is the real pickup distance (see World.pickups), not a guess.
    private static func unreachableKeys(_ pw: PropWalk) -> [ItemKind] {
        let keyKinds = Set(KeyColor.allCases.map { $0.item })
        return pw.world.items.filter { keyKinds.contains($0.kind) && !pw.canReach($0.pos, within: 0.5) }
                             .map { $0.kind }
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
