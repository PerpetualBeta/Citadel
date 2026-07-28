// Citadel — procedural level generator.
//
// Rooms + 1-wide corridors form a connected layout; doors (some locked behind
// coloured keys), hazard pools, hidden secret closets and an exit switch are
// layered on. Solvability is *verified*, not assumed: a keyed BFS confirms the
// exit is reachable given where the keys sit, and the generator retries with a
// fresh sub-seed until it passes (final fallback strips locks). So every level
// is beatable.

import Foundation
import simd

struct MonsterSpawn { let kind: MonsterKind; let pos: SIMD2<Float> }
struct ItemSpawn { let kind: ItemKind; let pos: SIMD2<Float> }

struct GeneratedLevel {
    let map: GameMap
    let monsters: [MonsterSpawn]
    let items: [ItemSpawn]
    let drums: [SIMD2<Float>]      // fuel-drum props (refuel + shootable bombs)
    let sockets: [(pos: SIMD2<Float>, yaw: Float)]   // wall-mounted plasma recharge panels (pos = the cell you stand in; yaw faces the room)
    let props: [Prop]              // decorative furniture/fixtures (set-dressing, no collision)
    let colonists: [Colonist]      // fallen ARC workers (human corpse meshes, no collision)
    let colonyName: String
    let secretCount: Int
}

enum MapGen {
    struct Theme {
        let walls: [WallTex]
        let floor: FlatTex
        let ceil: FlatTex
        let hazardFloor: FlatTex
    }

    // The descent IS the art direction. A colony is a working facility up top,
    // raw rock below — so the material set shifts with DEPTH, not colony.
    //   surface  → clean steel, glass, working strip-lights (a functioning plant)
    //   workings → grimier iron + pipework + hazard markings
    //   deep     → stone wins back the dark; steel infrastructure just clings on
    // (ARC terminal banks aren't a theme wall — placeTerminalBanks stamps them
    // into the office rooms on every floor.)
    static func theme(_ ci: Int, level: Int) -> Theme {
        _ = ci
        switch Progression.floorInBuilding(level) {   // material tier resets each citadel
        case 1...2:   // surface facility — clean, lit, working
            return Theme(walls: [.brushedSteel, .steelPanel, .litPanel],
                         floor: .metalFloor, ceil: .ceilTech, hazardFloor: .nukage)
        case 3...4:   // industrial workings — iron, pipes, grime
            return Theme(walls: [.ironPlate, .pipework, .brushedSteel],
                         floor: .grate, ceil: .ceilTech, hazardFloor: .nukage)
        case 5...6:   // deep workings — stone starts to intrude
            return Theme(walls: [.ironPlate, .stoneSteel, .pipework],
                         floor: .concrete, ceil: .ceilDark, hazardFloor: .nukage)
        default:      // floors 7–8: the WORKING INDUSTRIAL HEART of the citadel. Dark, damp, greasy,
                      // noisy. Blasted out of hard rock and never finished: most walls are still raw
                      // rock, and where a run WAS finished it is riveted iron panel. No display banks
                      // and no dormitories down here (see isDormitory / placeTerminalBanks) — the
                      // light comes from bulkhead fixtures, not ceiling strips.
            return Theme(walls: [.stone, .ironPlate, .stone],
                         floor: .rock, ceil: .ceilStone, hazardFloor: .nukage)
        }
    }

    private struct Room { let x, y, w, h: Int; var cx: Int { x + w / 2 }; var cy: Int { y + h / 2 } }

    // ── DORMITORIES ── large chambers become dedicated sleeping halls: bunk+locker rows
    // down the long walls, centre rows when wide, riveted-steel columns, plain concrete,
    // and nothing else (no pickups / drums / fixtures / elevators). Beds appear ONLY here.
    // Tunables (no blind magic numbers — placement derives from these):
    static let dormMinDim = 6            // both dims ≥ this → a dormitory
    static let dormSingleRowMinInterior = 3   // interior depth (span−2) ≥ this → one centre row
    static let dormDoubleRowMinInterior = 6   // ≥ this → two centre rows, head-to-head
    static let dormColumnStride = 4      // riveted-steel columns every N cells along a big hall
    /// True while generating the citadel's WORKING FLOORS (7–8): the industrial plant. Nobody sleeps and
    /// nobody monitors down here, so dormitories and CRT display banks are both suppressed. Set once at the
    /// top of attemptGen (generation is sequential), like `fuelStoreCells`.
    private static var industrialFloor = false
    // ── OPERATIONS CENTRE ── one per floor on 1–6: the room from which the colony ran its mining, shipping,
    // launches/landings and orbital work. Pure scenery — ranks of amber operator consoles facing a big board
    // that is the ONE full-colour display in the complex. No bunks, no lockers, no fuel drums; power points and
    // pickups are fine. Chosen once per level and consulted by the furnishing passes, like `fuelStoreCells`.
    private static var opsRoomIndex = -1
    private static var opsBoardSide = (0, 0)      // room interior → the wall carrying the board
    static let opsMinDim = 4                      // both dims ≥ this, so at least one ranked row + an aisle fits
    private static func isOpsCentre(_ ri: Int) -> Bool { ri == opsRoomIndex }
    /// Read-only view of the chosen ops room, for the ASCII layout dump.
    static var debugOpsRoom: Int { opsRoomIndex }
    /// Any damaging floor inside the room (the ops-centre pick needs this at attemptGen scope, where
    /// populate's own local `roomHasHazard` isn't in view).
    private static func roomHasHazardCells(_ map: GameMap, _ r: Room) -> Bool {
        for yy in r.y..<(r.y + r.h) { for xx in r.x..<(r.x + r.w) where map.hazard[map.idx(xx, yy)] { return true } }
        return false
    }
    /// A room is a DORMITORY iff it's large enough and is neither the start room (arrival
    /// elevator) nor the exit room (exit elevator/teleporter) — so no elevator ever sits in a
    /// dorm. The Queen may still lair in one. `roomCount-1` is the exit room (see attemptGen).
    /// NEVER on the industrial floors — those are working plant, not living quarters.
    private static func isDormitory(_ r: Room, _ ri: Int, _ roomCount: Int) -> Bool {
        !industrialFloor && min(r.w, r.h) >= dormMinDim && ri != 0 && ri != roomCount - 1
    }

    static func generate(level: Int, colonyIndex: Int, seed: UInt64) -> GeneratedLevel {
        for attempt in 0..<16 {
            if let g = attemptGen(level: level, colonyIndex: colonyIndex,
                                  seed: seed &+ UInt64(attempt) &* 0x100, allowLocks: true) {
                return g
            }
        }
        // Guaranteed-solvable fallback: no locked doors. attemptGen fails only on
        // placement/connectivity LUCK (never a structural impossibility for a valid
        // level), and for any real level the map is big enough that a no-locks layout
        // lands on the first try — so sweep a generous bounded set of seeds rather
        // than force-unwrap a single retry (the old `!` was the one crash trap in
        // generation). 256 independent placement failures sits far below hardware-
        // fault probability; emergencyChamber() is the final, can't-fail net.
        for k in 0..<256 {
            if let g = attemptGen(level: level, colonyIndex: colonyIndex,
                                  seed: seed &+ 0x9E3779B97F4A7C15 &* UInt64(k + 1), allowLocks: false) {
                return g
            }
        }
        return emergencyChamber(level: level, colonyIndex: colonyIndex)
    }

    /// The absolute last resort — statistically unreachable (see generate). A single
    /// open chamber that is ALWAYS valid and solvable: the marine at the west end, the
    /// Queen and the exit elevator at the east. No procedural placement, so it can
    /// never fail to build — the point being that generation has no crash path at all.
    private static func emergencyChamber(level: Int, colonyIndex: Int) -> GeneratedLevel {
        let th = theme(colonyIndex, level: level)
        let size = min(58, 40 + level * 2)            // mirror attemptGen's sizing
        let map = GameMap(w: size, h: size)
        for y in 1..<(size - 1) { for x in 1..<(size - 1) {
            let i = map.idx(x, y)
            map.wall[i] = 0; map.floor[i] = th.floor.rawValue; map.ceil[i] = th.ceil.rawValue
        } }
        let ey = size / 2
        map.playerStart = SIMD2<Float>(2.5, Float(ey) + 0.5)
        map.playerDir = 0
        let exit = map.idx(size - 1, ey)              // exit elevator sits IN the east wall
        map.wall[exit] = WallTex.elevatorSealed.rawValue
        map.doors[exit] = DoorState()
        map.exitCell = exit
        let queen = MonsterSpawn(kind: .queen, pos: SIMD2<Float>(Float(size) - 2.5, Float(ey) + 0.5))
        return GeneratedLevel(map: map, monsters: [queen], items: [], drums: [],
                              sockets: [], props: [], colonists: [],
                              colonyName: Progression.planets[colonyIndex % Progression.planets.count],
                              secretCount: 0)
    }

    private static func attemptGen(level: Int, colonyIndex: Int, seed: UInt64, allowLocks: Bool) -> GeneratedLevel? {
        var rng = Rng(seed: seed)
        industrialFloor = Progression.floorInBuilding(level) >= 7   // 7–8: the working plant (no dorms, no display banks)
        let th = theme(colonyIndex, level: level)
        let size = min(58, 40 + level * 2)
        let map = GameMap(w: size, h: size)

        @inline(__always) func open(_ x: Int, _ y: Int, floor: FlatTex, ceil: FlatTex, light: Float) {
            let i = map.idx(x, y)
            map.wall[i] = 0; map.floor[i] = floor.rawValue; map.ceil[i] = ceil.rawValue; map.light[i] = light
        }

        // ── place rooms ──
        var rooms: [Room] = []
        let target = min(12, 6 + level)
        var tries = 0
        while rooms.count < target && tries < 300 {
            tries += 1
            // hewn out of the bedrock — chambers, not aircraft hangars. The start room
            // (rooms[0]) stays a modest chamber (it carries the arrival elevator, never a
            // dorm); other rooms roll a DORM HALL ~40% of the time — big enough for bunk rows
            // down the long walls plus a centre aisle (and, when wide, columns + double rows).
            let rw: Int, rh: Int
            if rooms.isEmpty {
                rw = rng.i(4, 6); rh = rng.i(4, 6)
            } else if rng.chance(0.4) {
                let hi = min(11, size - 6)
                rw = rng.i(8, max(8, hi)); rh = rng.i(8, max(8, hi))
            } else {
                rw = rng.i(4, rng.chance(0.3) ? 7 : 6); rh = rng.i(4, rng.chance(0.3) ? 7 : 6)
            }
            let rx = rng.i(2, size - rw - 2), ry = rng.i(2, size - rh - 2)
            let cand = Room(x: rx, y: ry, w: rw, h: rh)
            // reject overlap (with 1-cell margin)
            var ok = true
            for r in rooms {
                if rx - 1 < r.x + r.w && rx + rw + 1 > r.x && ry - 1 < r.y + r.h && ry + rh + 1 > r.y { ok = false; break }
            }
            if ok { rooms.append(cand) }
        }
        if rooms.count < 3 { return nil }

        // carve rooms. Some rooms lose their worklights entirely — pockets of
        // true dark the headlamp has to cut. Never the start room (the marine
        // needs to get his bearings); commoner the deeper you descend. We don't
        // decide the Queen's lair here — she'll later claim whichever room ends
        // up darkest (see populate); we just make sure the dark exists.
        let darkChance = min(0.40, 0.12 + 0.05 * Float(level))
        var anyDark = false
        for (ri, r) in rooms.enumerated() {
            let darkRoom = ri != 0 && rng.chance(darkChance)
            if darkRoom { anyDark = true }
            let lightV = darkRoom ? (0.12 + rng.f(0, 0.07)) : (0.74 + rng.f(0, 0.24))
            let floorT = ri == 0 ? th.floor : (rng.chance(0.18) ? th.hazardFloor : th.floor)
            _ = floorT  // per-cell decided below
            for yy in r.y..<(r.y + r.h) {
                for xx in r.x..<(r.x + r.w) {
                    open(xx, yy, floor: th.floor, ceil: th.ceil, light: lightV)
                }
            }
        }
        // guarantee at least one unlit room — the Queen needs a dark lair, and the
        // headlamp needs a reason. If nothing rolled dark, douse a random non-start room.
        if !anyDark && rooms.count > 1 {
            let r = rooms[rng.i(1, rooms.count - 1)]
            let lightV = 0.12 + rng.f(0, 0.07)
            for yy in r.y..<(r.y + r.h) {
                for xx in r.x..<(r.x + r.w) {
                    let i = map.idx(xx, yy); if map.wall[i] == 0 { map.light[i] = lightV }
                }
            }
        }

        // ── corridors: chain connect (every corridor is a bridge → clean gating) ──
        var corridorCells: [[Int]] = []
        for i in 1..<rooms.count {
            let a = rooms[i - 1], b = rooms[i]
            var cells: [Int] = []
            let y = a.cy
            for x in stride(from: min(a.cx, b.cx), through: max(a.cx, b.cx), by: 1) {
                if map.wall[map.idx(x, y)] != 0 { open(x, y, floor: th.floor, ceil: th.ceil, light: 0.55) }
                cells.append(map.idx(x, y))
            }
            let x = b.cx
            for yy in stride(from: min(a.cy, b.cy), through: max(a.cy, b.cy), by: 1) {
                if map.wall[map.idx(x, yy)] != 0 { open(x, yy, floor: th.floor, ceil: th.ceil, light: 0.55) }
                cells.append(map.idx(x, yy))
            }
            corridorCells.append(cells)
        }

        // ── wall texturing: pick a per-room wall texture by tinting border cells ──
        // (walls stay as their solid id; we vary which WallTex by region for variety)
        retexWalls(map, rooms: rooms, rng: &rng, theme: th)

        // ── DOUBLE-HEIGHT MACHINE HALLS ── on the plant floors the ROOMS are plant halls: they stand twice a
        //    storey so the machinery has headroom, while the corridors feeding them stay a normal height. Only
        //    room interiors are raised (a doorway keeps its own height so a door still fills its frame), and the
        //    renderer closes the step with a soffit where a tall cell meets a short neighbour.
        if industrialFloor {
            for r in rooms {
                for yy in r.y..<(r.y + r.h) { for xx in r.x..<(r.x + r.w) {
                    let i = map.idx(xx, yy)
                    guard map.wall[i] == 0, map.doors[i] == nil else { continue }
                    map.ceilY[i] = GameMap.tallCeiling
                } }
            }
        }

        // ── player start ──
        let start = rooms[0]
        map.playerStart = SIMD2<Float>(Float(start.cx) + 0.5, Float(start.cy) + 0.5)
        map.playerDir = rng.f(0, 2 * .pi)
        let startCell = map.idx(start.cx, start.cy)

        // ── ARRIVAL ── the marine rode DOWN to get here, so he starts inside a
        // car on the start room's edge, facing out, its doors parting (World
        // opens them on spawn). Same rules as the exit car: open front, solid
        // back. EXCEPT the first floor of a later citadel: he MATERIALISED
        // there — an open teleporter-receiver alcove, no car, no doors.
        // If no side qualifies the level just starts in the room.
        if let site = elevatorSite(map, room: start) {
            let i = site.cell
            let wx = i % map.w, wy = i / map.w
            if Progression.floorInBuilding(level) == 1 && level > 1 {
                teleporterPad(map, cell: i)
            } else {
                map.wall[i] = WallTex.elevatorSealed.rawValue
                map.doors[i] = DoorState()
                steelBoxCar(map, cell: i)
            }
            map.entryCell = i
            map.playerStart = SIMD2<Float>(Float(wx) + 0.5, Float(wy) + 0.5)
            map.playerDir = atan2(Float(site.front.1 - wy), Float(site.front.0 - wx))
        }

        // Never spawn nose-first into steel — "she should face the doors", not the
        // elevator wall. The car path above already aims her at its open front; but a
        // car-less start room keeps the random fallback dir, which can point straight
        // at a wall. If the cell she looks at is solid, turn to the open cardinal with
        // the longest clear run so she faces out into the level.
        func openRun(_ dx: Int, _ dy: Int) -> Int {
            var n = 0, x = Int(map.playerStart.x) + dx, y = Int(map.playerStart.y) + dy
            while map.inBounds(x, y) && map.wall[map.idx(x, y)] == 0 { n += 1; x += dx; y += dy }
            return n
        }
        let lookX = Int(map.playerStart.x) + Int(cos(map.playerDir).rounded())
        let lookY = Int(map.playerStart.y) + Int(sin(map.playerDir).rounded())
        if !(map.inBounds(lookX, lookY) && map.wall[map.idx(lookX, lookY)] == 0) {
            let cardinals: [(Int, Int, Float)] = [(1, 0, 0), (0, 1, .pi / 2), (-1, 0, .pi), (0, -1, -.pi / 2)]
            var best = map.playerDir, bestRun = -1
            for (dx, dy, ang) in cardinals where openRun(dx, dy) > bestRun {
                bestRun = openRun(dx, dy); best = ang
            }
            map.playerDir = best
        }

        // ── exit in the last room: the colony elevator — or, on the citadel's
        //    LAST floor, the planet-jump TELEPORTER (there is nothing deeper
        //    to ride to) ──
        let exitRoom = rooms[rooms.count - 1]
        let exitCell = Progression.isLastFloor(level)
            ? placeTeleporter(map, room: exitRoom)
            : placeExitSwitch(map, room: exitRoom)
        map.exitCell = exitCell

        // ── doors ──
        var lockedDoors: [Int: KeyColor] = [:]
        var keyCells: [KeyColor: Int] = [:]
        // unlocked flavour doors at a few corridor mouths
        for ci in corridorCells.indices {
            if rng.chance(0.5), let cell = sealedCell(in: corridorCells[ci], map: map), doorClear(map, cell) {
                map.doors[cell] = DoorState()
                map.wall[cell] = WallTex.doorPanel.rawValue
            }
        }
        // locked doors gating the path to the exit
        if allowLocks && level >= 2 && corridorCells.count >= 3 {
            let lockCount = level >= 4 ? 2 : 1
            var usedColors: [KeyColor] = []
            for n in 0..<lockCount {
                // pick a corridor near the far end (high index) so it gates progress
                let gIdx = corridorCells.count - 1 - n
                if gIdx < 1 { break }
                guard let cell = sealedCell(in: corridorCells[gIdx], map: map), doorClear(map, cell) else { continue }
                let color = KeyColor.allCases[n % KeyColor.allCases.count]
                if usedColors.contains(color) { continue }
                usedColors.append(color)
                map.doors[cell] = DoorState(locked: color)
                map.wall[cell] = color.doorTex.rawValue
                lockedDoors[cell] = color
                // place the key in a room on the near side (index < gIdx room) — prefer a
                // NON-dorm room (no pickups in dorms), but fall back to any if that's all there is
                // (solvability outranks the dorm-cleanliness rule).
                let nearCands = (0..<gIdx).filter { !isDormitory(rooms[$0], $0, rooms.count) }
                let keyRoomIdx = nearCands.isEmpty ? rng.i(0, gIdx - 1) : nearCands[rng.i(0, nearCands.count - 1)]
                let kr = rooms[keyRoomIdx]
                let kc = map.idx(kr.x + rng.i(1, max(1, kr.w - 2)), kr.y + rng.i(1, max(1, kr.h - 2)))
                keyCells[color] = kc
            }
        }

        // ── hazard pools ── never in a dormitory (a sleeping hall isn't a chem sump); the
        // pool would also demote the room out of dorm-hood, leaving a bare utility box.
        for (ri, r) in rooms.enumerated().dropFirst() where rng.chance(0.3) && !isDormitory(r, ri, rooms.count) {
            let hw = max(2, r.w - 4), hh = max(2, r.h - 4)
            let hx = r.x + 2, hy = r.y + 2
            for yy in hy..<min(hy + hh, r.y + r.h - 1) {
                for xx in hx..<min(hx + hw, r.x + r.w - 1) {
                    let i = map.idx(xx, yy)
                    if map.wall[i] == 0 { map.hazard[i] = true; map.floor[i] = th.hazardFloor.rawValue; map.light[i] = 0.8 }
                }
            }
        }

        // ── secret closet with loot (hidden door textured like the wall) ──
        var secretCount = 0
        if let (doorCell, lootCell) = carveSecret(map, rooms: rooms, rng: &rng, theme: th) {
            map.doors[doorCell] = DoorState(secret: true)
            secretCount = 1
            // loot placed below in item pass via secretLoot
            secretLootCell = lootCell
        } else { secretLootCell = nil }

        // ── fuel-storage chamber: a small chamber stacked with drums, reached
        //    through a hazard-striped door (the colony kept its volatile fuel walled
        //    off). A dead-end side room, so it never affects start→exit solvability. ──
        fuelStoreCells = carveFuelStore(map, rooms: rooms, rng: &rng, theme: th)
        map.fuelStore = Set(fuelStoreCells.map { map.idx(Int($0.x), Int($0.y)) })

        // ── verify solvability (keyed BFS) ──
        if allowLocks && !lockedDoors.isEmpty {
            if !solvable(map: map, start: startCell, exitCell: exitCell, keyCells: keyCells, lockedDoors: lockedDoors) {
                return nil
            }
        }

        // ── ARC terminal banks in the office-to-be rooms (before the bake, so
        //    their amber wash lights the room) ──
        placeTerminalBanks(map, rooms: rooms, rng: &rng)

        // ── OPERATIONS CENTRE (floors 1–6) ── pick the room and paint its big board. Runs AFTER retexWalls so
        //    the board survives the per-room wall pass. The board takes the room's longest UNBROKEN wall (no
        //    doorway in it, nothing already special like a terminal bank) so the picture is never cut in half.
        opsRoomIndex = -1; opsBoardSide = (0, 0)
        if !industrialFloor {
            // Score the longest CONTIGUOUS clear stretch on each side, not the whole side: insisting a side be
            // unbroken end to end left some floors with no ops centre at all, and a board occupying part of a
            // wall is how a real control room looks anyway. Board width then varies floor to floor for free.
            var best = (score: 0, ri: -1, side: (0, 0), from: 0, len: 0)
            for (ri, r) in rooms.enumerated() where ri != 0 && ri != rooms.count - 1 {
                guard min(r.w, r.h) >= opsMinDim, !roomHasHazardCells(map, r) else { continue }
                for (dx, dy) in [(0, -1), (0, 1), (-1, 0), (1, 0)] {
                    let horiz = (dy != 0)
                    let n = horiz ? r.w : r.h
                    var runFrom = 0, runLen = 0, bestFrom = 0, bestLen = 0
                    for t in 0..<n {
                        let fx = horiz ? r.x + t : (dx > 0 ? r.x + r.w - 1 : r.x)
                        let fy = horiz ? (dy > 0 ? r.y + r.h - 1 : r.y) : r.y + t
                        let wx = fx + dx, wy = fy + dy
                        var ok = map.inBounds(wx, wy) && map.inBounds(fx, fy)
                        if ok {
                            let wi = map.idx(wx, wy), fi = map.idx(fx, fy)
                            // solid wall behind, no doorway in it, and open floor in front to stand on
                            ok = map.wall[wi] != 0 && map.doors[wi] == nil && map.wall[fi] == 0 && map.doors[fi] == nil
                                 && map.wall[wi] != WallTex.computer.rawValue      // a CRT bank wall isn't the big board
                        }
                        if ok { if runLen == 0 { runFrom = t }; runLen += 1
                                if runLen > bestLen { bestLen = runLen; bestFrom = runFrom } }
                        else { runLen = 0 }
                    }
                    guard bestLen >= 3 else { continue }
                    let score = bestLen * 10 + r.w * r.h                 // widest board first, then the roomiest
                    if score > best.score { best = (score, ri, (dx, dy), bestFrom, bestLen) }
                }
            }
            if best.ri >= 0 {
                opsRoomIndex = best.ri; opsBoardSide = best.side
                let r = rooms[best.ri], (dx, dy) = best.side, horiz = (dy != 0)
                for t in best.from..<(best.from + best.len) {
                    let fx = horiz ? r.x + t : (dx > 0 ? r.x + r.w - 1 : r.x)
                    let fy = horiz ? (dy > 0 ? r.y + r.h - 1 : r.y) : r.y + t
                    map.wall[map.idx(fx + dx, fy + dy)] = WallTex.opsBoard.rawValue
                }
            }
        }

        // ── colored sector lighting (baked once; raycaster just samples it) ──
        Lighting.bake(map, level: level)
        // The elevator cars are LIT interiors: the bake can't reach inside a door
        // cell (and the kernel's ceiling-lamp grid skips non-open cells), so stamp
        // a warm cabin level directly — the dynamic cabin lamp rides on top.
        // Teleporter pads get a COLD standby stamp instead: the transit machinery
        // is powered, and its light is alien to the colony's warm phosphor.
        for c in [map.exitCell, map.entryCell] where c >= 0 {
            if map.floor[c] == FlatTex.teleportPad.rawValue {
                map.lightColor[c] = SIMD3(0.72, 0.92, 1.0)
                map.light[c] = 0.9
            } else {
                map.lightColor[c] = SIMD3(0.95, 0.88, 0.72)
                map.light[c] = 0.85
            }
        }

        // THE SIGNAL deck: 1 (max 2) per BUILDING, only within floors 1–5. Decided
        // BUILDING-STABLY so a single building doesn't over- or under-shoot: the run
        // seed is recoverable (the per-floor seed is baseSeed + level; see Renderer),
        // so a per-building RNG picks which of floors 1–5 host the deck, and every
        // floor of that building agrees.
        var signalDeckFloor = false
        if Progression.floorInBuilding(level) <= 5 {
            let runSeed = seed &- UInt64(level)
            var brng = Rng(seed: runSeed ^ (UInt64(Progression.building(level)) &* 0x9E37_79B9_7F4A_7C15) ^ 0x5165_DEC0)
            let count = brng.chance(0.45) ? 2 : 1
            var floors = Set<Int>()
            while floors.count < count { floors.insert(brng.i(1, 5)) }
            signalDeckFloor = floors.contains(Progression.floorInBuilding(level))
        }

        // ── spawns ──
        let (monsters, items, drums, sockets, props, colonists) = populate(map: map, rooms: rooms, level: level, theme: th,
                                                keyCells: keyCells, exitRoomIndex: rooms.count - 1, signalDeck: signalDeckFloor, rng: &rng)

        return GeneratedLevel(map: map, monsters: monsters, items: items, drums: drums, sockets: sockets, props: props,
                              colonists: colonists,
                              colonyName: Progression.planets[colonyIndex % Progression.planets.count], secretCount: secretCount)
    }

    // a per-attempt scratch (single-threaded generation)
    private static var secretLootCell: Int? = nil
    private static var fuelStoreCells: [SIMD2<Float>] = []   // interior cells of the carved fuel store (drums stack here)

    // ── helpers ───────────────────────────────────────────────────────────────

    private static func retexWalls(_ map: GameMap, rooms: [Room], rng: inout Rng, theme: Theme) {
        // Give each wall cell a texture from the theme based on which room it
        // borders (cheap: nearest room centre). Keeps a world visually cohesive.
        // DORMITORY walls are the exception: plain concrete only — no lit panels / pipe
        // runs (theme.walls can include .litPanel / .pipework). Any wall cell bordering a
        // dorm interior is forced to the theme's PLAIN base wall (walls[0]).
        var dormBorder = [Bool](repeating: false, count: map.w * map.h)
        for (ri, r) in rooms.enumerated() where isDormitory(r, ri, rooms.count) {
            for yy in (r.y - 1)...(r.y + r.h) { for xx in (r.x - 1)...(r.x + r.w) where map.inBounds(xx, yy) {
                dormBorder[map.idx(xx, yy)] = true
            } }
        }
        for y in 0..<map.h { for x in 0..<map.w {
            let i = map.idx(x, y)
            if map.wall[i] == 0 || map.doors[i] != nil { continue }
            // pick by a stable hash so neighbouring walls mostly match
            let pick = (x / 6 + y / 6) % theme.walls.count
            map.wall[i] = dormBorder[i] ? theme.walls[0].rawValue : theme.walls[pick].rawValue
        }}
        _ = rng
    }

    // ── ARC terminal banks ── every room that will furnish as an OFFICE (the
    // same small-room predicate `populate` uses) gets a short run of amber CRT
    // wall on one side: the workstation bank its desk sits under. This is a pure
    // RETEXTURE — the wall stays solid, so reachability/solvability are untouched
    // — and it runs before Lighting.bake so each bank's amber wash is baked into
    // the sector light like any other fixture. (The busted-fixture spark system
    // in World already covers computer walls.)
    private static func placeTerminalBanks(_ map: GameMap, rooms: [Room], rng: inout Rng) {
        if industrialFloor { return }        // no display/CRT walls on the working plant floors (7–8)
        for r in rooms {
            var hazard = false
            for yy in r.y..<(r.y + r.h) { for xx in r.x..<(r.x + r.w) where map.hazard[map.idx(xx, yy)] { hazard = true } }
            guard r.w * r.h <= 20, !(r.w >= 5 && r.h >= 5 && !hazard) else { continue }   // mirrors populate's office split
            // four candidate sides: (wall cell, cell in front of it, run direction)
            var sides: [(w: (Int, Int), f: (Int, Int), d: (Int, Int), len: Int)] = [
                ((r.x + r.w / 2, r.y - 1),   (r.x + r.w / 2, r.y),           (1, 0), r.w),
                ((r.x + r.w / 2, r.y + r.h), (r.x + r.w / 2, r.y + r.h - 1), (1, 0), r.w),
                ((r.x - 1, r.y + r.h / 2),   (r.x, r.y + r.h / 2),           (0, 1), r.h),
                ((r.x + r.w, r.y + r.h / 2), (r.x + r.w - 1, r.y + r.h / 2), (0, 1), r.h),
            ]
            let rot = rng.i(0, 3)                        // vary which side hosts the bank
            sides = Array(sides[rot...] + sides[..<rot])
            for side in sides {
                let run = min(3, side.len), half = run / 2
                var cells: [Int] = [], ok = true
                for k in -half...(run - half - 1) {
                    let wx = side.w.0 + side.d.0 * k, wy = side.w.1 + side.d.1 * k
                    let fx = side.f.0 + side.d.0 * k, fy = side.f.1 + side.d.1 * k
                    guard map.inBounds(wx, wy), map.inBounds(fx, fy) else { ok = false; break }
                    let wi = map.idx(wx, wy), fi = map.idx(fx, fy)
                    // only plain structural wall converts (never a door, the exit
                    // switch, the fuel store's hazard plating, or another bank),
                    // the room cell in front must be open so the bank shows — and
                    // never the walls of an elevator car: a lift lined with ARC
                    // terminals reads absurd from inside
                    guard map.wall[wi] >= WallTex.ironPlate.rawValue, map.wall[wi] <= WallTex.stoneSteel.rawValue,
                          map.doors[wi] == nil, map.wall[fi] == 0, map.doors[fi] == nil,
                          !nearElevator(map, wx, wy) else { ok = false; break }
                    cells.append(wi)
                }
                guard ok, !cells.isEmpty else { continue }
                for i in cells { map.wall[i] = WallTex.computer.rawValue }
                break
            }
        }
    }

    private static func placeExitSwitch(_ map: GameMap, room: Room) -> Int {
        // the exit is the colony ELEVATOR: a real centre-split door whose plane
        // sits at the room face (buildDistanceField offsets it), so the cell
        // behind the leaves is the car — which must be a fully sealed box
        if let site = elevatorSite(map, room: room) {
            map.wall[site.cell] = WallTex.exitSwitch.rawValue
            map.doors[site.cell] = DoorState()
            steelBoxCar(map, cell: site.cell)
            return site.cell
        }
        // fallback: any wall adjacent to an open cell in the room
        let i = map.idx(room.x, room.y - 1)
        if map.inBounds(room.x, room.y - 1) { map.wall[i] = WallTex.exitSwitch.rawValue; return i }
        return map.idx(room.x, room.y)
    }

    /// The planet-jump TELEPORTER: sited like an elevator (solid back + jambs,
    /// open front) but the cell itself is an OPEN pad you walk onto — no door,
    /// no car. Cased in the same lift steel so it reads as installed transit
    /// machinery, with its own emissive-ringed pad flat underfoot.
    private static func placeTeleporter(_ map: GameMap, room: Room) -> Int {
        if let site = elevatorSite(map, room: room) {
            teleporterPad(map, cell: site.cell)
            return site.cell
        }
        // fallback: the legacy switch wall — USE engages the jump directly
        let i = map.idx(room.x, room.y - 1)
        if map.inBounds(room.x, room.y - 1) { map.wall[i] = WallTex.exitSwitch.rawValue; return i }
        return map.idx(room.x, room.y)
    }

    /// Convert a sited cell into an open teleporter pad: steel casing all round
    /// (the same shaft-liner treatment as a lift car), pad flat, tech ceiling.
    private static func teleporterPad(_ map: GameMap, cell: Int) {
        map.wall[cell] = 0
        map.doors[cell] = nil
        steelBoxCar(map, cell: cell)
        map.floor[cell] = FlatTex.teleportPad.rawValue
        map.ceil[cell] = FlatTex.ceilTech.rawValue
    }

    /// Scan a room's border for a cell that can host an ELEVATOR. The car must
    /// be a CLOSED BOX: an open room cell in front (the doorway), and solid,
    /// door-free back, side-jamb AND back-corner cells. The corners matter as
    /// much as the faces: a ring open at a diagonal leaves two wall cells
    /// touching at a single point, and the rounded SDF opens a floor-to-ceiling
    /// slit through that point — "the back corner of the elevator is missing".
    /// Wall-run midpoints are preferred (a centred door reads best).
    private static func elevatorSite(_ map: GameMap, room: Room) -> (cell: Int, front: (Int, Int))? {
        var sides: [((Int, Int), (Int, Int))] = []   // (wall cell, front cell)
        for x in room.x..<(room.x + room.w) {
            sides.append(((x, room.y - 1), (x, room.y)))
            sides.append(((x, room.y + room.h), (x, room.y + room.h - 1)))
        }
        for y in room.y..<(room.y + room.h) {
            sides.append(((room.x - 1, y), (room.x, y)))
            sides.append(((room.x + room.w, y), (room.x + room.w - 1, y)))
        }
        let sorted = sides.sorted(by: {
            abs($0.0.0 - room.cx) + abs($0.0.1 - room.cy) < abs($1.0.0 - room.cx) + abs($1.0.1 - room.cy)
        })
        // Two passes: first demand a FLUSH face — the cells either side of the
        // front cell open too, so the car sits in a proper room wall. A car
        // whose approach is a 1-wide notch reads as an inexplicable wall gap
        // with the sealed doors glimpsed down a slit. Fall back to any legal
        // site only if the room offers no flush face at all.
        for requireFlush in [true, false] {
            for (w, f) in sorted {
                let (wx, wy) = w, (fx, fy) = f
                guard map.inBounds(wx, wy), map.inBounds(fx, fy) else { continue }
                let wi = map.idx(wx, wy)
                guard map.wall[wi] != 0, map.doors[wi] == nil,
                      map.wall[map.idx(fx, fy)] == 0, map.doors[map.idx(fx, fy)] == nil else { continue }
                let dx = fx - wx, dy = fy - wy
                var boxOK = true
                for (bx, by) in [(wx - dx, wy - dy), (wx + dy, wy + dx), (wx - dy, wy - dx),      // back + both jambs
                                 (wx - dx + dy, wy - dy + dx), (wx - dx - dy, wy - dy - dx)] {    // + both back corners
                    guard map.inBounds(bx, by), map.wall[map.idx(bx, by)] != 0,
                          map.doors[map.idx(bx, by)] == nil else { boxOK = false; break }
                }
                guard boxOK, doorClear(map, wi) else { continue }
                if requireFlush {
                    var flush = true
                    for s in [-1, 1] {                       // the front cell's perpendicular neighbours
                        let px = fx + s * dy, py = fy + s * dx
                        guard map.inBounds(px, py), map.wall[map.idx(px, py)] == 0 else { flush = false; break }
                    }
                    guard flush else { continue }
                }
                return (wi, f)
            }
        }
        return nil
    }

    /// A lift car is a MACHINE bolted into the shaft, never a continuation of
    /// the surrounding geology: line ALL EIGHT cells around the cab with the
    /// dedicated liftWall steel (the SDF rounds corners, so even the diagonal
    /// cells show as slivers inside the box) and give the cab a metal deck +
    /// tech ceiling — on every floor, whatever the theme. (Where a box cell's
    /// far face shows in a rock corridor, the steel reads as the shaft casing.)
    private static func steelBoxCar(_ map: GameMap, cell: Int) {
        let wx = cell % map.w, wy = cell / map.w
        for dy in -1...1 { for dx in -1...1 {
            if dx == 0 && dy == 0 { continue }
            guard map.inBounds(wx + dx, wy + dy) else { continue }
            let bi = map.idx(wx + dx, wy + dy)
            if map.wall[bi] != 0 && map.doors[bi] == nil { map.wall[bi] = WallTex.liftWall.rawValue }
        }}
        map.floor[cell] = FlatTex.metalFloor.rawValue
        map.ceil[cell] = FlatTex.ceilTech.rawValue
    }

    /// True within one cell (Chebyshev) of either elevator car. NOTHING may carve
    /// or open there — a secret closet or fuel chamber that touches the car
    /// punches a hidden room into what must stay a sealed box.
    private static func nearElevator(_ map: GameMap, _ x: Int, _ y: Int) -> Bool {
        for cell in [map.entryCell, map.exitCell] where cell >= 0 {
            if abs(x - cell % map.w) <= 1 && abs(y - cell / map.w) <= 1 { return true }
        }
        return false
    }

    /// No door may sit in a cell 4-adjacent to another door: the leaves slide
    /// INTO the jambs, so side-by-side doors are mechanically impossible (there
    /// is no wall for either leaf to retract into) — and they read absurd.
    private static func doorClear(_ map: GameMap, _ cell: Int) -> Bool {
        let x = cell % map.w, y = cell / map.w
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            if map.inBounds(x + dx, y + dy), map.doors[map.idx(x + dx, y + dy)] != nil { return false }
        }
        return true
    }

    /// First corridor cell with walls on both perpendicular sides (so a door seals it).
    private static func sealedCell(in cells: [Int], map: GameMap) -> Int? {
        for c in cells {
            let x = c % map.w, y = c / map.w
            if map.wall[c] != 0 || map.doors[c] != nil { continue }
            let horizWalls = map.wallAt(x - 1, y) != 0 && map.wallAt(x + 1, y) != 0
            let vertWalls = map.wallAt(x, y - 1) != 0 && map.wallAt(x, y + 1) != 0
            // sealed across one axis AND open along the other (a real doorway)
            if horizWalls && map.wallAt(x, y - 1) == 0 && map.wallAt(x, y + 1) == 0 { return c }
            if vertWalls && map.wallAt(x - 1, y) == 0 && map.wallAt(x + 1, y) == 0 { return c }
        }
        return nil
    }

    private static func carveSecret(_ map: GameMap, rooms: [Room], rng: inout Rng, theme: Theme) -> (Int, Int)? {
        // dig a 2-cell closet behind a wall of a random non-start, NON-dorm room
        // (dorms carry no hidden rooms — their walls are plain sleeping-hall concrete)
        for _ in 0..<20 {
            let ri = rng.i(1, rooms.count - 1)
            if isDormitory(rooms[ri], ri, rooms.count) { continue }
            let r = rooms[ri]
            // try the right wall
            let dx = r.x + r.w, dy = r.y + r.h / 2
            if dx + 1 >= map.w - 1 { continue }
            let doorCell = map.idx(dx, dy)
            let closet = map.idx(dx + 1, dy)
            if map.wall[map.idx(dx - 1, dy)] != 0 { continue }   // need open room cell in front
            if map.wall[doorCell] == 0 || map.wall[closet] == 0 { continue }
            // ALL validation happens BEFORE the carve (a rejected carve must leave
            // no hole): never beside another door, never touching an elevator car
            if !doorClear(map, doorCell) { continue }
            if nearElevator(map, dx, dy) || nearElevator(map, dx + 1, dy) { continue }
            // the closet must be SEALED on every side but its hidden door —
            // DIAGONALS included: the SDF rounds wall corners, so an open cell
            // kissing a corner reads as a see-through slit, and a closet carved
            // beside a corridor has no back wall at all. Doors count as leaks
            // (one could slide open straight into the closet).
            var sealed = true
            for oy in -1...1 { for ox in -1...1 where !(ox == 0 && oy == 0) {
                let nx = dx + 1 + ox, ny = dy + oy
                guard map.inBounds(nx, ny) else { sealed = false; continue }
                let ni = map.idx(nx, ny)
                if ni == doorCell { continue }
                if map.wall[ni] == 0 || map.doors[ni] != nil { sealed = false }
            } }
            if !sealed { continue }
            // doorCell stays SOLID with its existing wall texture (hidden); only
            // the closet behind is hollowed. The secret DoorState is added by the
            // caller, so USE reveals it and it slides up like the wall it mimics.
            map.floor[doorCell] = theme.floor.rawValue; map.ceil[doorCell] = theme.ceil.rawValue; map.light[doorCell] = 0.5
            map.wall[closet] = 0; map.floor[closet] = theme.floor.rawValue; map.ceil[closet] = theme.ceil.rawValue; map.light[closet] = 0.45
            return (doorCell, closet)
        }
        return nil
    }

    /// Dig a 2×2 fuel-storage chamber behind a wall of a random non-start room,
    /// reached through a hazard-striped (but openable) door. Returns the interior
    /// floor cells for drum stacking ([] if no spot was found — drums then scatter).
    private static func carveFuelStore(_ map: GameMap, rooms: [Room], rng: inout Rng, theme: Theme) -> [SIMD2<Float>] {
        // Dig a 2×2 fuel-storage chamber off ANY wall of a non-start room, reached
        // through a hazard-striped (openable) door. Tries all four walls across many
        // rooms so a store reliably appears every level, and lights it well so the
        // stacked drums READ. Returns the interior cells ([] only if truly no spot).
        for _ in 0..<60 {
            let r = rooms[rng.i(1, rooms.count - 1)]
            let outward: (Int, Int), door: (Int, Int)
            switch rng.i(0, 3) {
            case 0:  outward = (1, 0);  door = (r.x + r.w,     r.y + r.h / 2)   // right wall
            case 1:  outward = (-1, 0); door = (r.x - 1,       r.y + r.h / 2)   // left wall
            case 2:  outward = (0, 1);  door = (r.x + r.w / 2, r.y + r.h)       // bottom wall
            default: outward = (0, -1); door = (r.x + r.w / 2, r.y - 1)         // top wall
            }
            let perp = (outward.1, outward.0)                                   // the 2-wide stack axis
            let front = (door.0 - outward.0, door.1 - outward.1)               // room-side cell in front of the door
            guard map.inBounds(front.0, front.1), map.wall[map.idx(front.0, front.1)] == 0,
                  map.doors[map.idx(front.0, front.1)] == nil,
                  map.inBounds(door.0, door.1), map.wall[map.idx(door.0, door.1)] != 0,
                  map.doors[map.idx(door.0, door.1)] == nil else { continue }
            // the 2×2 chamber beyond the door (1–2 cells out, 2 wide along the wall)
            var chamber: [(Int, Int)] = []
            var ok = true
            for d in 1...2 { for w in 0...1 {
                let cx = door.0 + outward.0 * d + perp.0 * w
                let cy = door.1 + outward.1 * d + perp.1 * w
                if cx < 1 || cy < 1 || cx >= map.w - 1 || cy >= map.h - 1 || map.wall[map.idx(cx, cy)] == 0 { ok = false }
                if nearElevator(map, cx, cy) { ok = false }        // never dig into a car's box
                chamber.append((cx, cy))
            } }
            if !ok || nearElevator(map, door.0, door.1) { continue }
            let dCell = map.idx(door.0, door.1)
            // the door must sit IN a wall — solid on both flanks — never a free-standing
            // hazard pillar in the open
            let fa = (door.0 + perp.0, door.1 + perp.1), fb = (door.0 - perp.0, door.1 - perp.1)
            guard map.inBounds(fa.0, fa.1), map.wall[map.idx(fa.0, fa.1)] != 0,
                  map.inBounds(fb.0, fb.1), map.wall[map.idx(fb.0, fb.1)] != 0 else { continue }
            // the chamber must be SEALED — its only opening is the door, so it can't
            // leak into an adjacent corridor / room. Checked over the FULL eight-cell
            // neighbourhood: the SDF rounds wall corners, so a cell open DIAGONALLY
            // off a chamber corner pinches that corner into a see-through slit. And
            // doors count as leaks — a corridor door against the chamber slides open
            // into it.
            let chamberSet = Set(chamber.map { map.idx($0.0, $0.1) })
            var sealed = true
            seal: for (cx, cy) in chamber {
                for oy in -1...1 { for ox in -1...1 where !(ox == 0 && oy == 0) {
                    let nx = cx + ox, ny = cy + oy
                    guard map.inBounds(nx, ny) else { sealed = false; break seal }
                    let ni = map.idx(nx, ny)
                    if ni == dCell || chamberSet.contains(ni) { continue }
                    if map.wall[ni] == 0 || map.doors[ni] != nil { sealed = false; break seal }
                } }
            }
            if !sealed || !doorClear(map, dCell) { continue }
            map.floor[dCell] = FlatTex.concrete.rawValue; map.ceil[dCell] = FlatTex.ceilStone.rawValue; map.light[dCell] = 0.42
            map.wall[dCell] = WallTex.doorHazard.rawValue                      // hazard-striped DOOR leaves — the "fuel store" sign
            map.doors[dCell] = DoorState()
            var cells: [SIMD2<Float>] = []
            for (cx, cy) in chamber {
                let i = map.idx(cx, cy)
                // BARE CONCRETE throughout — a fireproof store, not a steel/lit-panel room; dim baked ambient
                // (0.16) so the wall-mounted BULKHEAD lights do the lighting (no overhead), added in the render.
                map.wall[i] = 0; map.floor[i] = FlatTex.concrete.rawValue; map.ceil[i] = FlatTex.ceilStone.rawValue; map.light[i] = 0.16
                cells.append(SIMD2(Float(cx) + 0.5, Float(cy) + 0.5))
            }
            // line the chamber's own bounding walls with concrete (retexWalls ran earlier and left lit
            // panels / lockers on them); the full 8-neighbourhood, since the SDF rounds diagonal corners.
            for (cx, cy) in chamber {
                for oy in -1...1 { for ox in -1...1 where !(ox == 0 && oy == 0) {
                    let nx = cx + ox, ny = cy + oy
                    guard map.inBounds(nx, ny) else { continue }
                    let ni = map.idx(nx, ny)
                    if ni != dCell, map.wall[ni] != 0, map.doors[ni] == nil { map.wall[ni] = WallTex.concrete.rawValue }
                }}
            }
            return cells
        }
        return []
    }

    // ── keyed BFS solvability ───────────────────────────────────────────────

    private static func solvable(map: GameMap, start: Int, exitCell: Int,
                                 keyCells: [KeyColor: Int], lockedDoors: [Int: KeyColor]) -> Bool {
        let exitNeighbours = neighbours(of: exitCell, map: map)
        var keyAt: [Int: Int] = [:]   // cell -> key bit
        for (color, cell) in keyCells { keyAt[cell] = 1 << color.rawValue }

        func passable(_ cell: Int, _ mask: Int) -> Bool {
            if map.wall[cell] == 0 { return true }
            if let lock = lockedDoors[cell] { return (mask & (1 << lock.rawValue)) != 0 }
            if map.doors[cell] != nil { return true }   // unlocked door
            return false
        }

        var seen = Set<Int>()   // state = cell * 8 + mask
        var queue = [(start, keyAt[start] ?? 0)]
        seen.insert(start * 8 + (keyAt[start] ?? 0))
        var qi = 0
        while qi < queue.count {
            let (cell, mask) = queue[qi]; qi += 1
            if exitNeighbours.contains(cell) { return true }
            for nb in neighbours(of: cell, map: map) where passable(nb, mask) {
                let newMask = mask | (keyAt[nb] ?? 0)
                let state = nb * 8 + newMask
                if !seen.contains(state) { seen.insert(state); queue.append((nb, newMask)) }
            }
        }
        return false
    }

    private static func neighbours(of cell: Int, map: GameMap) -> [Int] {
        let x = cell % map.w, y = cell / map.w
        var out: [Int] = []
        if x > 0 { out.append(cell - 1) }
        if x < map.w - 1 { out.append(cell + 1) }
        if y > 0 { out.append(cell - map.w) }
        if y < map.h - 1 { out.append(cell + map.w) }
        return out
    }

    // ── spawn population ──────────────────────────────────────────────────────

    private static func populate(map: GameMap, rooms: [Room], level: Int, theme: Theme,
                                 keyCells: [KeyColor: Int], exitRoomIndex: Int, signalDeck: Bool, rng: inout Rng)
        -> ([MonsterSpawn], [ItemSpawn], [SIMD2<Float>], [(pos: SIMD2<Float>, yaw: Float)], [Prop], [Colonist]) {
        var monsters: [MonsterSpawn] = []
        var items: [ItemSpawn] = []
        var drums: [SIMD2<Float>] = []
        var sockets: [(pos: SIMD2<Float>, yaw: Float)] = []
        var props: [Prop] = []
        let colonists: [Colonist] = []       // room-scatter removed; fuel-store survivors are placed separately (TODO)
        // dormitories are dedicated sleeping halls: NO pickups, NO fuel drums, NO recharge sockets — just
        // the bunks/lockers/columns furnished above. Gate every scatter pass by this per-room flag.
        let dormRoom = rooms.indices.map { isDormitory(rooms[$0], $0, rooms.count) }

        func center(_ cell: Int) -> SIMD2<Float> { SIMD2(Float(cell % map.w) + 0.5, Float(cell / map.w) + 0.5) }
        func randCell(in r: Room) -> Int? {
            for _ in 0..<12 {
                let x = r.x + rng.i(1, max(1, r.w - 2)), y = r.y + rng.i(1, max(1, r.h - 2))
                let i = map.idx(x, y)
                if map.wall[i] == 0 && map.doors[i] == nil && !map.hazard[i] { return i }
            }
            return nil
        }
        // shared occupancy — every placed occupant's centre, so nothing spawns
        // stacked on anything else (the player start is seeded in).
        var placed: [SIMD2<Float>] = [map.playerStart]
        func spot(in r: Room, gap: Float = 1.15) -> SIMD2<Float>? {
            for _ in 0..<16 {
                guard let c = randCell(in: r) else { return nil }
                let p = center(c)
                if placed.contains(where: { vlen($0 - p) < gap }) { continue }
                placed.append(p); return p
            }
            return nil
        }
        @discardableResult func note(_ p: SIMD2<Float>) -> SIMD2<Float> { placed.append(p); return p }
        // a clearance-aware cell for a LARGE occupant (the Queen — radius ~1.1):
        // the most-open interior cell of the room, scored by its 3×3 walkable
        // neighbourhood, so she never spawns wedged into a wall (which would put
        // the exit-gating boss permanently out of reach).
        func openCell(in r: Room) -> Int? {
            guard r.w >= 3, r.h >= 3 else { return nil }
            var best = -1, bestScore = -1
            for yy in (r.y + 1)..<(r.y + r.h - 1) { for xx in (r.x + 1)..<(r.x + r.w - 1) {
                let i = map.idx(xx, yy)
                if map.wall[i] != 0 || map.doors[i] != nil || map.hazard[i] { continue }
                var open = 0
                for oy in -1...1 { for ox in -1...1 where map.inBounds(xx + ox, yy + oy) {
                    let n = map.idx(xx + ox, yy + oy)
                    if map.wall[n] == 0 && map.doors[n] == nil { open += 1 }
                } }
                if open > bestScore { bestScore = open; best = i }
            } }
            return best >= 0 ? best : nil
        }
        // the Queen lairs in the DARKEST room — not by rule the exit room, but
        // wherever the gloom is deepest on this level (she loathes the light, so
        // she'll have found the blackest space). Mean baked luminance picks it.
        func roomGloom(_ r: Room) -> Float {
            var sum: Float = 0, n = 0
            for yy in r.y..<(r.y + r.h) { for xx in r.x..<(r.x + r.w) {
                let i = map.idx(xx, yy); if map.wall[i] != 0 { continue }
                let c = map.lightColor[i]
                sum += c.x * 0.299 + c.y * 0.587 + c.z * 0.114; n += 1
            }}
            return n > 0 ? sum / Float(n) : .greatestFiniteMagnitude
        }
        var queenRoomIdx = exitRoomIndex, queenGloom = Float.greatestFiniteMagnitude
        for ri in 1..<rooms.count {
            let g = roomGloom(rooms[ri])
            if g < queenGloom { queenGloom = g; queenRoomIdx = ri }
        }

        // keys — the one pickup solvability hangs off, so a key is NEVER dropped;
        // but the lock pass rolls key cells independently, and on a two-lock
        // floor both cards could land stacked on one cell. If the chosen cell is
        // occupied, nudge within the SAME room (any cell there is still on the
        // near side of its lock, which is all solvability needs).
        for (color, cell) in keyCells {
            var p = center(cell)
            if placed.contains(where: { vlen($0 - p) < 0.9 }) {
                let cx = cell % map.w, cy = cell / map.w
                if let r = rooms.first(where: { cx >= $0.x && cx < $0.x + $0.w && cy >= $0.y && cy < $0.y + $0.h }) {
                    for _ in 0..<24 {
                        guard let c2 = randCell(in: r) else { break }
                        let q = center(c2)
                        if !placed.contains(where: { vlen($0 - q) < 0.9 }) { p = q; break }
                    }
                }
            }
            items.append(ItemSpawn(kind: color.item, pos: note(p)))
        }
        // secret loot
        if let s = secretLootCell { items.append(ItemSpawn(kind: rng.chance(0.5) ? .megaArmor : .weaponRocket, pos: note(center(s)))) }

        // Fuel is no longer a floor pickup — the oil drums ARE the fuel source now
        // (refuel by standing at one), so the "fuel pod" duplication is gone. The
        // early-fuel guarantee is a drum seeded into rooms[1] in the drum pass below.

        for (ri, r) in rooms.enumerated() {
            let isStart = ri == 0

            // monsters
            if !isStart {
                // exactly one Queen per level, in the darkest room — the objective
                // that gates the exit, wherever in the citadel she's holed up
                if ri == queenRoomIdx {
                    let qc = openCell(in: r) ?? randCell(in: r) ?? map.idx(r.cx, r.cy)
                    monsters.append(MonsterSpawn(kind: .queen, pos: note(center(qc))))
                }
                let count = rng.i(1, 2 + level / 2)
                for _ in 0..<count {
                    guard let p = spot(in: r) else { continue }
                    monsters.append(MonsterSpawn(kind: .alien, pos: p))
                }
            }

            // items — NEVER in a dormitory (dedicated sleeping halls hold no pickups)
            if !dormRoom[ri] {
                let lootRolls = rng.i(1, 3)
                for _ in 0..<lootRolls {
                    guard let p = spot(in: r) else { continue }
                    items.append(ItemSpawn(kind: pickItem(level: level, rng: &rng), pos: p))
                }
            }
        }

        // pick a random NON-dorm room in [lo, hi] for the deeper caches (no pickups in dorms)
        func nonDormRoom(_ lo: Int, _ hi: Int) -> Room? {
            guard lo <= hi else { return nil }
            let cands = (lo...hi).filter { !dormRoom[$0] }
            return cands.isEmpty ? nil : rooms[cands[rng.i(0, cands.count - 1)]]
        }
        // deeper field drops, rare: a crate of mines, then the rocket launcher,
        // then a cell cache to stock up for the Queen
        if level >= 1, rooms.count > 2, let dr = nonDormRoom(2, rooms.count - 1), let p = spot(in: dr) {
            items.append(ItemSpawn(kind: .mineCrate, pos: p))
        }
        if level >= 2, rooms.count > 3, let dr = nonDormRoom(2, rooms.count - 1), let p = spot(in: dr), rng.chance(0.7) {
            items.append(ItemSpawn(kind: .weaponRocket, pos: p))
        }
        if level >= 3, rooms.count > 3, let dr = nonDormRoom(2, rooms.count - 1), let p = spot(in: dr), rng.chance(0.7) {
            items.append(ItemSpawn(kind: .ammoCells, pos: p))
        }

        // fuel drums — the colony's volatile stores, and the marine's ONLY refuel
        // source now (the flamethrower is finite). Their HOME is the clearly-marked
        // (hazard-doored) fuel-storage chamber, stacked full; a couple more sit in
        // room CORNERS as opportunistic combat barrels (shoot to detonate).
        if rooms.count > 1 {
            func cornerCells(_ r: Room) -> [SIMD2<Float>] {
                var out: [SIMD2<Float>] = []
                for (x, y) in [(r.x, r.y), (r.x + r.w - 1, r.y), (r.x, r.y + r.h - 1), (r.x + r.w - 1, r.y + r.h - 1)] {
                    let i = map.idx(x, y)
                    if map.wall[i] == 0 && map.doors[i] == nil && !map.hazard[i] { out.append(center(i)) }
                }
                return out
            }
            func freeOf(_ p: SIMD2<Float>, _ gap: Float) -> Bool { !placed.contains { vlen($0 - p) < gap } }
            // a drum is SOLID, so it must never land in a doorway throat — keep barrels
            // off any cell adjacent to a door (the fuel store's own entry is handled by
            // dropping the cell straight inside its hazard door, below).
            func clearOfDoors(_ p: SIMD2<Float>) -> Bool {
                let cx = Int(p.x), cy = Int(p.y)
                for dy in -1...1 { for dx in -1...1 where map.inBounds(cx + dx, cy + dy) {
                    if map.doors[map.idx(cx + dx, cy + dy)] != nil { return false }
                } }
                return true
            }
            // 1. stack the fuel-storage chamber — the primary, clearly-marked cache.
            //    SKIP the first cell (straight inside the hazard door): drums are SOLID,
            //    and a barrel in the doorway would wall the whole store off.
            for c in fuelStoreCells.dropFirst() where freeOf(c, 0.85) { drums.append(c); placed.append(c) }
            // 2. a couple of opportunistic corner barrels out in the level
            for _ in 0..<rng.i(1, 2) {
                for attempt in 0..<40 {
                    let ri = rng.i(1, rooms.count - 1)
                    if dormRoom[ri] { continue }               // no fuel drums in dormitories
                    if isOpsCentre(ri) { continue }           // nor in the operations centre — volatile fuel has no place at the consoles
                    let r = rooms[ri]
                    var p: SIMD2<Float>? = nil
                    if attempt < 28 {                              // prefer free corners
                        let corners = cornerCells(r).filter { freeOf($0, 1.05) && clearOfDoors($0) }
                        if !corners.isEmpty { p = corners[rng.i(0, corners.count - 1)] }
                    } else if let c = randCell(in: r) {            // then any clear cell
                        let q = center(c)
                        if freeOf(q, 1.05) && clearOfDoors(q) { p = q }
                    }
                    if let p = p { drums.append(p); placed.append(p); break }
                }
            }
            // 3. belt-and-braces: every level MUST carry fuel — if both passes were
            //    starved (no store carved + crowded rooms), scan exhaustively
            if drums.isEmpty {
                outer: for r in rooms.dropFirst() {
                    for yy in (r.y + 1)..<(r.y + r.h - 1) { for xx in (r.x + 1)..<(r.x + r.w - 1) {
                        let i = map.idx(xx, yy)
                        if map.wall[i] != 0 || map.doors[i] != nil || map.hazard[i] { continue }
                        let p = center(i)
                        if freeOf(p, 0.95) && clearOfDoors(p) { drums.append(p); placed.append(p); break outer }
                    } }
                }
            }
        }
        // recharge sockets are WALL-MOUNTED panels now — placed against a free wall
        // in the furnish pass below (they need a wall behind them), not free-standing.

        // ── furnish the rooms ── the citadels were working colonies until the swarm
        // came; the rooms should look lived-in, not like empty test boxes. Furniture
        // is SOLID (see World.propColliders) and PROTRUDES into the room, so it must be
        // placed flush against real walls and clear of every opening (nearOpening),
        // never walling the marine in: large dorms get rows of bunks
        // (never the ones with toxic pools), small offices get a desk + terminal +
        // chair, and every room gets steel lockers and pipe runs for the industrial
        // read of the beauty shot.
        let exitX = map.exitCell % map.w, exitY = map.exitCell / map.w
        // room membership for every cell (−1 = corridor / void) — shared by furniture
        // placement and pipe routing so both agree on what counts as an "opening".
        var roomOf = [Int](repeating: -1, count: map.w * map.h)
        for (ri, r) in rooms.enumerated() {
            for yy in r.y..<(r.y + r.h) { for xx in r.x..<(r.x + r.w) { roomOf[map.idx(xx, yy)] = ri } }
        }
        // a cell the player must be able to pass through: a door (any kind) or the exit.
        func isOpeningCell(_ i: Int) -> Bool {
            map.doors[i] != nil || map.wall[i] == WallTex.exitSwitch.rawValue
        }
        func solidWall(_ x: Int, _ y: Int) -> Bool {
            !map.inBounds(x, y) || (map.wall[map.idx(x, y)] != 0 && map.doors[map.idx(x, y)] == nil)
        }
        // A wall slot is unusable if any neighbour (incl. diagonals) is an OPENING — a
        // door, or an open cell belonging to a different room / corridor (a room-mouth).
        // Furniture is SOLID now, and bunks/desks PROTRUDE ~1 cell into the room, so a
        // piece placed beside an opening would jut across the throat and wall the marine
        // in. A one-cell margin from every opening guarantees the passage stays clear.
        func nearOpening(_ x: Int, _ y: Int, _ ri: Int) -> Bool {
            for dy in -2...2 { for dx in -2...2 where !(dx == 0 && dy == 0) {
                guard map.inBounds(x + dx, y + dy) else { continue }
                let ni = map.idx(x + dx, y + dy)
                let cheb = max(abs(dx), abs(dy))
                if isOpeningCell(ni) { return true }                                   // 2-cell margin from any door / the exit (a bunk protrudes ~1 cell)
                if cheb == 1 && map.wall[ni] == 0 && roomOf[ni] != ri { return true }   // 1-cell margin from a room-mouth
            } }
            return false
        }
        func freeCell(_ p: SIMD2<Float>, _ gap: Float) -> Bool { !placed.contains { vlen($0 - p) < gap } }
        // yaw such that a prop's local +Z (its FRONT) points along `inward` (see GPURaymarch)
        func yawFor(_ inward: SIMD2<Float>) -> Float { atan2(-inward.x, inward.y) }
        // interior edge cells that sit flush against a real wall, with their inward facing
        struct Slot { let pos: SIMD2<Float>; let inward: SIMD2<Float>; let x, y: Int }
        func wallSlots(_ r: Room, _ ri: Int) -> [Slot] {
            var out: [Slot] = []
            func consider(_ x: Int, _ y: Int, _ inward: SIMD2<Float>) {
                guard map.inBounds(x, y), map.wall[map.idx(x, y)] == 0,
                      map.doors[map.idx(x, y)] == nil, !map.hazard[map.idx(x, y)] else { return }
                if nearOpening(x, y, ri) { return }                            // not beside any door or room-mouth
                if abs(x - exitX) + abs(y - exitY) <= 1 { return }              // keep the exit switch reachable
                if !solidWall(x - Int(inward.x), y - Int(inward.y)) { return }  // real wall behind (not a corridor mouth)
                out.append(Slot(pos: SIMD2(Float(x) + 0.5, Float(y) + 0.5), inward: inward, x: x, y: y))
            }
            for x in r.x..<(r.x + r.w) { consider(x, r.y, SIMD2(0, 1)) }                 // top wall (faces +y)
            for x in r.x..<(r.x + r.w) { consider(x, r.y + r.h - 1, SIMD2(0, -1)) }      // bottom wall
            for y in r.y..<(r.y + r.h) { consider(r.x, y, SIMD2(1, 0)) }                 // left wall
            for y in r.y..<(r.y + r.h) { consider(r.x + r.w - 1, y, SIMD2(-1, 0)) }      // right wall
            return out
        }
        // A wall-mounted recharge socket must back onto PLAIN structural wall —
        // never over a surface FEATURE (the amber ARC display banks, backlit glass,
        // or the fuel-store hazard plating), where a bolted-on panel reads as a
        // mistake. These are all feature-only textures — never a theme's base wall —
        // so rejecting them can't starve placement (litPanel/pipework stay valid).
        let socketBadBacking: Set<Int> = [WallTex.computer.rawValue, WallTex.glass.rawValue, WallTex.hazard.rawValue]
        func featureBacked(_ s: Slot) -> Bool {
            let bx = s.x - Int(s.inward.x), by = s.y - Int(s.inward.y)
            return map.inBounds(bx, by) && socketBadBacking.contains(map.wall[map.idx(bx, by)])
        }
        func roomHasHazard(_ r: Room) -> Bool {
            for yy in r.y..<(r.y + r.h) { for xx in r.x..<(r.x + r.w) where map.hazard[map.idx(xx, yy)] { return true } }
            return false
        }
        // A CONTROL/OPS room is one whose bounding wall carries a CRT terminal bank
        // (placeTerminalBanks converted a wall run to WallTex.computer) — that's where
        // THE SIGNAL archive deck belongs.
        func roomHasBank(_ r: Room) -> Bool {
            for x in r.x..<(r.x + r.w) {
                if map.inBounds(x, r.y - 1),   map.wall[map.idx(x, r.y - 1)]   == WallTex.computer.rawValue { return true }
                if map.inBounds(x, r.y + r.h), map.wall[map.idx(x, r.y + r.h)] == WallTex.computer.rawValue { return true }
            }
            for y in r.y..<(r.y + r.h) {
                if map.inBounds(r.x - 1, y),    map.wall[map.idx(r.x - 1, y)]    == WallTex.computer.rawValue { return true }
                if map.inBounds(r.x + r.w, y),  map.wall[map.idx(r.x + r.w, y)]  == WallTex.computer.rawValue { return true }
            }
            return false
        }
        @discardableResult
        func placeProp(_ kind: FurnitureKind, _ slot: Slot, faceInward: Bool = true, gap: Float = 0.85) -> Bool {
            guard freeCell(slot.pos, gap) else { return false }
            props.append(Prop(kind: kind, pos: slot.pos, yaw: yawFor(faceInward ? slot.inward : -slot.inward)))
            placed.append(slot.pos)
            return true
        }
        // ── DORMITORY furnishing ── a dedicated sleeping HALL: Locker-Bunk-Locker-Bunk rows down the two
        // LONG walls (bunks perpendicular, pillow flush to the wall — `againstWall` + flushToWall seat the
        // frame, no extrusion), centre row(s) when wide (one; or two head-to-head with lockers back-to-back),
        // riveted-steel columns holding the roof of the big halls, and clear aisles (bunks are ~0.84 long so
        // they never leave their edge cell → the rows between them are walkable). Beds appear ONLY here.
        @discardableResult
        func placeDorm(_ kind: FurnitureKind, _ u: Int, _ v: Int, _ inward: SIMD2<Float>, against: Bool, gap: Float,
                       horizontal: Bool, _ r: Room, _ ri: Int) -> Bool {
            let x = horizontal ? r.x + u : r.x + v
            let y = horizontal ? r.y + v : r.y + u
            guard map.inBounds(x, y), map.wall[map.idx(x, y)] == 0, map.doors[map.idx(x, y)] == nil,
                  !map.hazard[map.idx(x, y)], !nearOpening(x, y, ri) else { return false }
            let p = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
            guard freeCell(p, gap) else { return false }
            props.append(Prop(kind: kind, pos: p, yaw: yawFor(inward), againstWall: against))
            placed.append(p)
            return true
        }
        // ── STRUCTURAL COLUMNS ── ANY large hall (dormitory OR open room) needs riveted-steel posts
        // to carry the ceiling; a vast unsupported span reads as unreal. An even grid, inset one cell
        // from the walls and centred, dodging doorways, the elevator cars, hazard cells and —
        // deliberately — the overhead lamp cells (a pillar under a light fitting reads as a mistake,
        // and the raster lamp grid is the single source of truth for where those sit). Run BEFORE
        // furniture so beds/desks lay out around the posts.
        func placeColumnAt(_ x0: Int, _ y: Int, _ ri: Int) {
            let ls = RasterRenderer.lampGridStride, lp = RasterRenderer.lampGridPhase
            func underLamp(_ cx: Int) -> Bool { cx % ls == lp && y % ls == lp }
            func ok(_ cx: Int) -> Bool {
                map.inBounds(cx, y) && map.wall[map.idx(cx, y)] == 0 && map.doors[map.idx(cx, y)] == nil
                    && !map.hazard[map.idx(cx, y)] && !nearOpening(cx, y, ri) && !MapGen.nearElevator(map, cx, y)
                    && freeCell(SIMD2(Float(cx) + 0.5, Float(y) + 0.5), 0.9)
            }
            // prefer the grid cell; if it lands under a lamp, step one cell aside — never place under a fitting
            let candidates = underLamp(x0) ? [x0 + 1, x0 - 1] : [x0, x0 + 1, x0 - 1]
            guard let x = candidates.first(where: { ok($0) && !underLamp($0) }) else { return }
            let p = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
            props.append(Prop(kind: .column, pos: p, yaw: 0, againstWall: false))
            placed.append(p)
        }
        func placeColumns(_ r: Room, _ ri: Int) {
            let step = MapGen.dormColumnStride
            func line(_ lo: Int, _ len: Int) -> [Int] {              // grid coords, ≥1-cell inset from walls, centred
                let a = lo + 1, b = lo + len - 2
                if b < a { return [] }
                if b - a < step { return [(a + b) / 2] }             // one central post
                let n = (b - a) / step
                let start = a + (b - a - n * step) / 2
                return (0...n).map { start + $0 * step }
            }
            let xs = line(r.x, r.w), ys = line(r.y, r.h)
            for gy in ys { for gx in xs { placeColumnAt(gx, gy, ri) } }
        }
        func furnishDormitory(_ r: Room, _ ri: Int) {
            let horizontal = r.w >= r.h
            let T = horizontal ? r.w : r.h          // length along the long walls
            let P = horizontal ? r.h : r.w          // perpendicular span (wall to wall)
            func into(_ s: Int) -> SIMD2<Float> { horizontal ? SIMD2(0, Float(s)) : SIMD2(Float(s), 0) }
            let bunkGap: Float = 1.0, lockGap: Float = 0.85
            let interior = P - 2                     // rows strictly between the two wall rows
            func rowKind(_ u: Int) -> FurnitureKind { u % 2 == 0 ? .locker : .bunk }
            func gapFor(_ k: FurnitureKind) -> Float { k == .bunk ? bunkGap : lockGap }
            // (columns are placed by placeColumns() in the room loop, before this runs, so the rows skip them)
            // wall rows — pillow at the wall (inward points INTO the room, so the mesh's −Z pillow faces out)
            for (wallV, sign) in [(0, 1), (P - 1, -1)] {
                for u in 0..<T { let k = rowKind(u); placeDorm(k, u, wallV, into(sign), against: true, gap: gapFor(k), horizontal: horizontal, r, ri) }
            }
            // centre rows
            if interior >= MapGen.dormDoubleRowMinInterior {
                let cvA = P / 2 - 1, cvB = P / 2                                 // adjacent rows straddling the centre
                for u in 0..<T { let k = rowKind(u)
                    placeDorm(k, u, cvA, into(-1), against: false, gap: gapFor(k), horizontal: horizontal, r, ri)   // heads toward +v (centre)
                    placeDorm(k, u, cvB, into(1),  against: false, gap: gapFor(k), horizontal: horizontal, r, ri)   // heads toward −v (centre) → head-to-head, lockers back-to-back
                }
            } else if interior >= MapGen.dormSingleRowMinInterior {
                let cv = P / 2
                for u in 0..<T { let k = rowKind(u); placeDorm(k, u, cv, into(1), against: false, gap: gapFor(k), horizontal: horizontal, r, ri) }
            }
        }
        for (ri, r) in rooms.enumerated() {
            let area = r.w * r.h
            let hazard = roomHasHazard(r)
            // structural support for ANY large hall — dorm, open room, or a large start/exit chamber
            if min(r.w, r.h) >= MapGen.dormMinDim { placeColumns(r, ri) }
            // ── OPERATIONS CENTRE ── ranks of operator consoles facing the big board, and NOTHING else: no
            //    bunks, no lockers, no drums (handled by taking this branch before any of those paths run).
            //    Rows run parallel to the board with a walkable aisle between each, and every row is broken by
            //    a gangway so the player can always cross the room — it is scenery, never a barricade.
            if isOpsCentre(ri) && !hazard {
                let (bdx, bdy) = opsBoardSide
                let horiz = (bdy != 0)                                   // board on a N/S wall → rows run along X
                let faceDir = SIMD2<Float>(-Float(bdx), -Float(bdy))     // board → room: the console's +Z (operator side)
                let rowsAvail = horiz ? r.h : r.w
                let alongN = horiz ? r.w : r.h
                // A crossing gangway is only worth reserving when the row is long enough to be a barricade —
                // in a narrow room the skip could delete the only console the row can hold.
                let gangway = (alongN - 2) >= 4 ? alongN / 2 : -1
                // depth 1 is the board's own front row (kept clear so the board is readable), then rows every 2
                var depth = 2
                while depth <= max(2, rowsAvail - 2) {
                    for t in 1..<max(2, alongN - 1) where t != gangway {
                        // walk from the board inward by `depth`
                        let xx = horiz ? r.x + t : (bdx > 0 ? r.x + r.w - 1 - depth : r.x + depth)
                        let yy = horiz ? (bdy > 0 ? r.y + r.h - 1 - depth : r.y + depth) : r.y + t
                        guard map.inBounds(xx, yy), map.wall[map.idx(xx, yy)] == 0, map.doors[map.idx(xx, yy)] == nil,
                              !map.hazard[map.idx(xx, yy)], !nearOpening(xx, yy, ri) else { continue }
                        let p = SIMD2<Float>(Float(xx) + 0.5, Float(yy) + 0.5)
                        guard freeCell(p, 0.85) else { continue }
                        props.append(Prop(kind: .console, pos: p, yaw: yawFor(faceDir)))
                        placed.append(p)
                    }
                    depth += 2                                           // console row, then an aisle
                }
                continue
            }
            // ── DORMITORY: large, hazard-free, not the start/exit room → a dedicated sleeping hall ──
            if isDormitory(r, ri, rooms.count) && !hazard {
                furnishDormitory(r, ri)
                continue
            }
            let slots = wallSlots(r, ri)
            // ── floor furniture against the walls (NON-dorm rooms — never get beds) ──
            if !slots.isEmpty {
                var used = 0
                if area <= 20 {
                    // OFFICE: a desk + powered terminal, a chair tucked in front, a
                    // locker. The desk prefers the slot backed by the room's terminal
                    // bank (placeTerminalBanks), so the workstation sits under its CRTs.
                    let bankBacked: (Slot) -> Bool = { s in
                        let bx = s.x - Int(s.inward.x), by = s.y - Int(s.inward.y)
                        return map.inBounds(bx, by) && map.wall[map.idx(bx, by)] == WallTex.computer.rawValue
                    }
                    if let desk = slots.first(where: { bankBacked($0) && freeCell($0.pos, 0.85) })
                                ?? slots.first(where: { freeCell($0.pos, 0.85) }) {
                        placeProp(.desk, desk)
                        // the chair sits just in front of the (now wall-flush) desk, facing it
                        let chairP = desk.pos + desk.inward * 0.62
                        let cx = Int(chairP.x), cy = Int(chairP.y)
                        if map.inBounds(cx, cy), map.wall[map.idx(cx, cy)] == 0, map.doors[map.idx(cx, cy)] == nil,
                           !map.hazard[map.idx(cx, cy)], freeCell(chairP, 0.5) {
                            props.append(Prop(kind: .chair, pos: chairP, yaw: yawFor(-desk.inward), againstWall: false))
                            placed.append(chairP)
                        }
                        // records spilled across the deck in the panic — a scatter of
                        // sheets on the floor out in front of the workstation
                        if FeatureFlags.scatteredPapers, rng.chance(0.5) {
                            let tangent = SIMD2<Float>(desk.inward.y, -desk.inward.x)
                            let pp = desk.pos + desk.inward * rng.f(0.9, 1.35) + tangent * rng.f(-0.4, 0.4)
                            let px = Int(pp.x), py = Int(pp.y)
                            if map.inBounds(px, py), map.wall[map.idx(px, py)] == 0, map.doors[map.idx(px, py)] == nil,
                               !map.hazard[map.idx(px, py)], freeCell(pp, 0.4) {
                                props.append(Prop(kind: .papers, pos: pp, yaw: rng.f(0, 6.2831853), againstWall: false))
                                placed.append(pp)
                            }
                        }
                        for s in slots where !featureBacked(s) && placeProp(.locker, s) { break }   // a locker must never cover a display/CRT bank
                    }
                } else {
                    // utility: a couple of lockers and (space permitting) a desk
                    for s in slots {
                        if used >= 2 { break }
                        if !featureBacked(s), placeProp(.locker, s) { used += 1 }                    // never in front of a display panel
                    }
                    if !hazard { for s in slots where placeProp(.desk, s) { break } }
                }
            }
        }

        // ── THE SIGNAL archive ── a reel-to-reel deck in the control/ops room (the one
        // with the CRT terminal bank), on a wall clear of the bank + the room's other
        // furniture. RARE: 1 (max 2) per BUILDING, and only within floors 1–5 (by 6+
        // the player knows the sound). The building-stable choice is `signalDeck`,
        // decided in attemptGen; here we just honour it where a control room fits it.
        if signalDeck {
            var deckPlaced = false
            for (ri, r) in rooms.enumerated() where !deckPlaced && roomHasBank(r) {
                for s in wallSlots(r, ri) where !featureBacked(s) {
                    if placeProp(.tapeDeck, s, gap: 1.0) { deckPlaced = true; break }
                }
            }
        }

        // ── recharge sockets ── WALL-MOUNTED plasma panels (a couple per level), on a
        // free wall slot clear of furniture, spread out, facing the room. The marine
        // stands in the slot cell to plug in (pos); the panel mounts on the wall behind
        // (yaw). Anti-softlock for the plasma-only Queen.
        if rooms.count > 1 {
            var nSock = 0
            for (ri, r) in rooms.enumerated().dropFirst() where nSock < 2 && !dormRoom[ri] {   // no wall panels in a plain-concrete dorm
                for s in wallSlots(r, ri) where freeCell(s.pos, 1.0) && !featureBacked(s) && !sockets.contains(where: { vlen($0.pos - s.pos) < 3 }) {
                    sockets.append((pos: s.pos, yaw: yawFor(s.inward))); placed.append(s.pos); nSock += 1; break
                }
            }
            if sockets.isEmpty {                                 // belt-and-braces: every level must carry one
                outer: for (ri, r) in rooms.enumerated().dropFirst() {
                    for s in wallSlots(r, ri) where freeCell(s.pos, 0.6) && !featureBacked(s) {
                        sockets.append((pos: s.pos, yaw: yawFor(s.inward))); placed.append(s.pos); break outer
                    }
                }
            }
            if sockets.isEmpty {                                 // last resort: guarantee one even if only feature walls remain
                outer2: for (ri, r) in rooms.enumerated().dropFirst() {
                    for s in wallSlots(r, ri) where freeCell(s.pos, 0.6) {
                        sockets.append((pos: s.pos, yaw: yawFor(s.inward))); placed.append(s.pos); break outer2
                    }
                }
            }
        }

        // ── fallen colonists ── the room-scatter is SUPERSEDED: the swarm consumed the
        // dead (absence IS the story — an emptied, lived-in colony), so there are no
        // scattered bodies. The only humans are the rare fuel-store SURVIVORS (0–2 per
        // BUILDING, seated corpses in the sealed fuel stores, each a session-unique
        // person). That placement + the no-repeat roster is wired separately — TODO.

        // ── pipe routing ── bake which open cells carry a wall pipe. Pipes run along
        // the walls of SELECTED rooms only (≈60%, for variation), and are kept clear
        // of every OPENING (door / corridor mouth), every wall-prop and the exit — so
        // a pipe NEVER crosses a doorway or runs through a locker. The kernel ramps it
        // down INTO the wall (a drilled-hole termination) wherever the mask hits 0.
        var propBlock = Set<Int>()                 // a wall prop + the cells around it block the run
        for pr in props {
            let px = Int(pr.pos.x), py = Int(pr.pos.y)
            for (ox, oy) in [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1)] where map.inBounds(px + ox, py + oy) {
                propBlock.insert(map.idx(px + ox, py + oy))
            }
        }
        // The plant floors are a working services deck — route EVERY room, not six in ten.
        for (ri, r) in rooms.enumerated() where industrialFloor || rng.chance(0.6) {
            for yy in r.y..<(r.y + r.h) { for xx in r.x..<(r.x + r.w) {
                let i = map.idx(xx, yy)
                if map.wall[i] != 0 || map.doors[i] != nil || map.hazard[i] { continue }   // open floor only
                if propBlock.contains(i) { continue }                                       // not behind/through a prop
                if abs(xx - exitX) + abs(yy - exitY) <= 2 { continue }                      // keep well clear of the exit switch
                var clear = true                                                            // and clear of every opening
                for dy in -2...2 { for dx in -2...2 where !(dx == 0 && dy == 0) {
                    let nx = xx + dx, ny = yy + dy
                    guard map.inBounds(nx, ny) else { continue }
                    let ni = map.idx(nx, ny)
                    if isOpeningCell(ni) { clear = false }                                  // a 2-cell buffer round any door / the exit
                    else if max(abs(dx), abs(dy)) == 1 && map.wall[ni] == 0 && roomOf[ni] != ri { clear = false }  // 1 cell off a room-mouth
                    else if max(abs(dx), abs(dy)) == 1 && map.wall[ni] == WallTex.computer.rawValue { clear = false }  // a pipe never flows ACROSS a terminal bank
                } }
                // never in front of the operations BIG BOARD — services are not plumbed across the plot
                // displays. Done here, in the shared routing mask, so BOTH renderers respect it.
                for (ox, oy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] where map.inBounds(xx + ox, yy + oy) {
                    if map.wall[map.idx(xx + ox, yy + oy)] == WallTex.opsBoard.rawValue { clear = false }
                }
                if clear { map.pipe[i] = 1 }
            } }
        }
        // extend the mask one cell INTO the solid wall behind each piped edge cell, so
        // the baked field reads "pipe" right at the wall face (not half-dived along it)
        var ext = map.pipe
        for y in 0..<map.h { for x in 0..<map.w {
            let i = map.idx(x, y)
            guard map.wall[i] != 0, map.doors[i] == nil else { continue }                   // solid, non-door
            var byOpening = false                                                           // never let the pipe-in-wall touch a door / the exit
            for dy in -1...1 { for dx in -1...1 where !(dx == 0 && dy == 0) {
                guard map.inBounds(x + dx, y + dy) else { continue }
                if isOpeningCell(map.idx(x + dx, y + dy)) { byOpening = true }
            } }
            if byOpening { continue }
            for (ox, oy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] where map.inBounds(x + ox, y + oy) {
                if map.pipe[map.idx(x + ox, y + oy)] >= 0.5 { ext[i] = 1; break }
            }
        } }
        map.pipe = ext
        // No DIAGONAL-ONLY adjacency may survive in the mask: the kernel's
        // bilinear upsample holds ~0.5 along such a kiss's whole diagonal
        // instead of ramping, and the pipe-terminus geometry (bend + flange
        // collars) smears along that plateau into floating phantom hardware
        // (the 2026-07-06 "what is this?" lozenge). Clear the weaker member
        // (fewer orthogonal routed neighbours) until diagonally clean.
        var kissGuard = 0
        var kissed = true
        while kissed && kissGuard < 8 {
            kissed = false; kissGuard += 1
            for y in 0..<(map.h - 1) { for x in 0..<(map.w - 1) {
                for (dx, dy) in [(1, 1), (1, -1)] {
                    let ny = y + dy
                    guard ny >= 0, ny < map.h else { continue }
                    let a = map.idx(x, y), b = map.idx(x + dx, ny)
                    guard map.pipe[a] >= 0.5, map.pipe[b] >= 0.5 else { continue }
                    guard map.pipe[map.idx(x + dx, y)] < 0.5, map.pipe[map.idx(x, ny)] < 0.5 else { continue }
                    func orthoRouted(_ cx: Int, _ cy: Int) -> Int {
                        var n = 0
                        for (ox, oy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] where map.inBounds(cx + ox, cy + oy) {
                            if map.pipe[map.idx(cx + ox, cy + oy)] >= 0.5 { n += 1 }
                        }
                        return n
                    }
                    map.pipe[orthoRouted(x, y) <= orthoRouted(x + dx, ny) ? a : b] = 0
                    kissed = true
                }
            } }
        }

        // ── pipe FITTINGS ── placed HERE, on the CPU, with a true wall frame
        // (anchor on the wall face + outward normal) — never derived in the
        // kernel from x+z hashes, which sheared on two wall orientations,
        // sliced on every routing-mask ramp, and doubled up on one run. Sites
        // sit mid-run on full-mask straight faces only, and are rationed like
        // real plant: a room's pipework is ONE circuit, so at most ONE
        // shut-off valve per room, at most one gauge, on different sides.
        var fits: [SIMD4<Float>] = []
        for r in rooms {
            // gather candidate anchors per side: contiguous piped face runs
            var sideRuns: [[(SIMD2<Float>, SIMD2<Float>)]] = []
            func gather(_ cells: [(Int, Int)], wallOff: (Int, Int), anchor: (Int, Int) -> SIMD2<Float>, normal: SIMD2<Float>) {
                var run: [(SIMD2<Float>, SIMD2<Float>)] = []
                func flush() {
                    if run.count >= 4 { sideRuns.append(Array(run[1...(run.count - 2)])) }   // interior cells only
                    run.removeAll()
                }
                for (cx, cy) in cells {
                    let wx = cx + wallOff.0, wy = cy + wallOff.1
                    let ok = map.inBounds(cx, cy) && map.inBounds(wx, wy)
                        && map.wall[map.idx(cx, cy)] == 0 && map.pipe[map.idx(cx, cy)] >= 0.5
                        && map.wall[map.idx(wx, wy)] != 0 && map.doors[map.idx(wx, wy)] == nil
                        && map.pipe[map.idx(wx, wy)] >= 0.5                     // ext mask reaches the face → no ramp here
                    if ok { run.append((anchor(cx, cy), normal)) } else { flush() }
                }
                flush()
            }
            gather((r.x..<(r.x + r.w)).map { ($0, r.y) }, wallOff: (0, -1),
                   anchor: { SIMD2(Float($0) + 0.5, Float($1)) }, normal: SIMD2(0, 1))
            gather((r.x..<(r.x + r.w)).map { ($0, r.y + r.h - 1) }, wallOff: (0, 1),
                   anchor: { SIMD2(Float($0) + 0.5, Float($1 + 1)) }, normal: SIMD2(0, -1))
            gather((r.y..<(r.y + r.h)).map { (r.x, $0) }, wallOff: (-1, 0),
                   anchor: { SIMD2(Float($0), Float($1) + 0.5) }, normal: SIMD2(1, 0))
            gather((r.y..<(r.y + r.h)).map { (r.x + r.w - 1, $0) }, wallOff: (1, 0),
                   anchor: { SIMD2(Float($0 + 1), Float($1) + 0.5) }, normal: SIMD2(-1, 0))
            guard !sideRuns.isEmpty else { continue }
            // Shut-offs and instruments. Upstairs a circuit carries at most one of each; on the PLANT floors the
            // runs are studded with them — this is where the colony's services were actually operated.
            let wantValves = industrialFloor ? rng.i(1, 3) : (rng.chance(0.55) ? 1 : 0)
            let wantGauges = industrialFloor ? rng.i(1, 2) : (rng.chance(0.45) ? 1 : 0)
            for _ in 0..<wantValves {
                guard !sideRuns.isEmpty else { break }
                let side = rng.i(0, sideRuns.count - 1)
                let (a, n) = sideRuns[side][rng.i(0, sideRuns[side].count - 1)]
                fits.append(SIMD4(a.x, a.y, atan2(n.y, n.x), 0))
                sideRuns.remove(at: side)                                       // one shut-off per side
            }
            for _ in 0..<wantGauges {
                guard !sideRuns.isEmpty else { break }
                let side = rng.i(0, sideRuns.count - 1)
                let (a, n) = sideRuns[side][rng.i(0, sideRuns[side].count - 1)]
                fits.append(SIMD4(a.x, a.y, atan2(n.y, n.x), 1))
                sideRuns.remove(at: side)
            }
        }
        map.pipeFittings = fits

        return (monsters, items, drums, sockets, props, colonists)
    }

    private static func pickItem(level: Int, rng: inout Rng) -> ItemKind {
        // No fuel here — fuel is the oil drums' job now (refuel at one), so the loot
        // table redistributes the old fuel share to the plasma/health staples.
        let roll = rng.f()
        if roll < 0.20 { return .stim }
        if roll < 0.40 { return .medkit }
        if roll < 0.66 { return .ammoCells }                     // plasma fodder — the staple
        if roll < 0.80 { return .mineCrate }                     // proximity explosives
        if roll < 0.90 { return level >= 2 ? .ammoRockets : .ammoCells }
        if roll < 0.97 { return .armor }
        return .megaArmor
    }
}
