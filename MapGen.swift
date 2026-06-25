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
    let sockets: [SIMD2<Float>]    // plasma recharge stations (top up cells; anti-softlock)
    let props: [Prop]              // decorative furniture/fixtures (set-dressing, no collision)
    let colonyName: String
    let secretCount: Int
}

enum MapGen {
    struct Theme {
        let walls: [WallTex]
        let accent: WallTex
        let floor: FlatTex
        let ceil: FlatTex
        let hazardFloor: FlatTex
    }

    // The descent IS the art direction. A colony is a working facility up top,
    // raw rock below — so the material set shifts with DEPTH, not colony:
    //   surface  → clean steel, glass, working strip-lights (a functioning plant)
    //   workings → grimier iron + pipework + hazard markings
    //   deep     → stone wins back the dark; steel infrastructure just clings on
    // `ci` (colony) nudges the accent so adjacent colonies still feel distinct.
    static func theme(_ ci: Int, level: Int) -> Theme {
        let accents: [WallTex] = [.computer, .glass, .hazard, .litPanel]
        let acc = accents[ci % accents.count]
        switch Progression.floorInBuilding(level) {   // material tier resets each citadel
        case 1...2:   // surface facility — clean, lit, working
            return Theme(walls: [.brushedSteel, .steelPanel, .litPanel], accent: acc,
                         floor: .metalFloor, ceil: .ceilTech, hazardFloor: .nukage)
        case 3...4:   // industrial workings — iron, pipes, grime
            return Theme(walls: [.ironPlate, .pipework, .brushedSteel], accent: .hazard,
                         floor: .grate, ceil: .ceilTech, hazardFloor: .nukage)
        case 5...6:   // deep workings — stone starts to intrude
            return Theme(walls: [.ironPlate, .stoneSteel, .pipework], accent: .glass,
                         floor: .concrete, ceil: .ceilDark, hazardFloor: .nukage)
        default:      // the depths — rock dominant, infrastructure failing
            return Theme(walls: [.stone, .stoneSteel, .ironPlate], accent: .pipework,
                         floor: .rock, ceil: .ceilStone, hazardFloor: .blood)
        }
    }

    private struct Room { let x, y, w, h: Int; var cx: Int { x + w / 2 }; var cy: Int { y + h / 2 } }

    static func generate(level: Int, colonyIndex: Int, seed: UInt64) -> GeneratedLevel {
        for attempt in 0..<16 {
            if let g = attemptGen(level: level, colonyIndex: colonyIndex,
                                  seed: seed &+ UInt64(attempt) &* 0x100, allowLocks: true) {
                return g
            }
        }
        // Guaranteed-solvable fallback: no locked doors.
        return attemptGen(level: level, colonyIndex: colonyIndex, seed: seed, allowLocks: false)
            ?? attemptGen(level: level, colonyIndex: colonyIndex, seed: seed &+ 999, allowLocks: false)!
    }

    private static func attemptGen(level: Int, colonyIndex: Int, seed: UInt64, allowLocks: Bool) -> GeneratedLevel? {
        var rng = Rng(seed: seed)
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
            // hewn out of the bedrock — chambers, not aircraft hangars. A few run a
            // little longer (rng skews small), but nothing cavernous.
            let rw = rng.i(4, rng.chance(0.3) ? 7 : 6), rh = rng.i(4, rng.chance(0.3) ? 7 : 6)
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

        // ── player start ──
        let start = rooms[0]
        map.playerStart = SIMD2<Float>(Float(start.cx) + 0.5, Float(start.cy) + 0.5)
        map.playerDir = rng.f(0, 2 * .pi)
        let startCell = map.idx(start.cx, start.cy)

        // ── exit switch in the last room ──
        let exitRoom = rooms[rooms.count - 1]
        let exitCell = placeExitSwitch(map, room: exitRoom)
        map.exitCell = exitCell

        // ── doors ──
        var lockedDoors: [Int: KeyColor] = [:]
        var keyCells: [KeyColor: Int] = [:]
        // unlocked flavour doors at a few corridor mouths
        for ci in corridorCells.indices {
            if rng.chance(0.5), let cell = sealedCell(in: corridorCells[ci], map: map) {
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
                guard let cell = sealedCell(in: corridorCells[gIdx], map: map) else { continue }
                let color = KeyColor.allCases[n % KeyColor.allCases.count]
                if usedColors.contains(color) { continue }
                usedColors.append(color)
                map.doors[cell] = DoorState(locked: color)
                map.wall[cell] = color.doorTex.rawValue
                lockedDoors[cell] = color
                // place the key in a room on the near side (index < gIdx room)
                let keyRoomIdx = rng.i(0, gIdx - 1)
                let kr = rooms[keyRoomIdx]
                let kc = map.idx(kr.x + rng.i(1, max(1, kr.w - 2)), kr.y + rng.i(1, max(1, kr.h - 2)))
                keyCells[color] = kc
            }
        }

        // ── hazard pools ──
        for r in rooms.dropFirst() where rng.chance(0.3) {
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

        // ── verify solvability (keyed BFS) ──
        if allowLocks && !lockedDoors.isEmpty {
            if !solvable(map: map, start: startCell, exitCell: exitCell, keyCells: keyCells, lockedDoors: lockedDoors) {
                return nil
            }
        }

        // ── colored sector lighting (baked once; raycaster just samples it) ──
        Lighting.bake(map, level: level)

        // ── spawns ──
        let (monsters, items, drums, sockets, props) = populate(map: map, rooms: rooms, level: level, theme: th,
                                                keyCells: keyCells, exitRoomIndex: rooms.count - 1, rng: &rng)

        return GeneratedLevel(map: map, monsters: monsters, items: items, drums: drums, sockets: sockets, props: props,
                              colonyName: Progression.planets[colonyIndex % Progression.planets.count], secretCount: secretCount)
    }

    // a per-attempt scratch (single-threaded generation)
    private static var secretLootCell: Int? = nil
    private static var fuelStoreCells: [SIMD2<Float>] = []   // interior cells of the carved fuel store (drums stack here)

    // ── helpers ───────────────────────────────────────────────────────────────

    private static func retexWalls(_ map: GameMap, rooms: [Room], rng: inout Rng, theme: Theme) {
        // Give each wall cell a texture from the theme based on which room it
        // borders (cheap: nearest room centre). Keeps a world visually cohesive.
        for y in 0..<map.h { for x in 0..<map.w {
            let i = map.idx(x, y)
            if map.wall[i] == 0 || map.doors[i] != nil { continue }
            // pick by a stable hash so neighbouring walls mostly match
            let pick = (x / 6 + y / 6) % theme.walls.count
            map.wall[i] = theme.walls[pick].rawValue
        }}
        _ = rng
    }

    private static func placeExitSwitch(_ map: GameMap, room: Room) -> Int {
        // a wall cell on the room's edge, with a walkable cell in front
        let candidates: [(Int, Int)] = [
            (room.x + room.w / 2, room.y - 1),      // top wall
            (room.x + room.w / 2, room.y + room.h),  // bottom wall
            (room.x - 1, room.y + room.h / 2),
            (room.x + room.w, room.y + room.h / 2),
        ]
        for (wx, wy) in candidates {
            guard map.inBounds(wx, wy) else { continue }
            let front: (Int, Int) = wy < room.y ? (wx, wy + 1) : wy >= room.y + room.h ? (wx, wy - 1)
                : wx < room.x ? (wx + 1, wy) : (wx - 1, wy)
            if map.inBounds(front.0, front.1) && map.wall[map.idx(front.0, front.1)] == 0 {
                let i = map.idx(wx, wy)
                map.wall[i] = WallTex.exitSwitch.rawValue
                return i
            }
        }
        // fallback: any wall adjacent to an open cell in the room
        let i = map.idx(room.x, room.y - 1)
        if map.inBounds(room.x, room.y - 1) { map.wall[i] = WallTex.exitSwitch.rawValue; return i }
        return map.idx(room.x, room.y)
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
        // dig a 2-cell closet behind a wall of a random non-start room
        for _ in 0..<20 {
            let r = rooms[rng.i(1, rooms.count - 1)]
            // try the right wall
            let dx = r.x + r.w, dy = r.y + r.h / 2
            if dx + 1 >= map.w - 1 { continue }
            let doorCell = map.idx(dx, dy)
            let closet = map.idx(dx + 1, dy)
            if map.wall[map.idx(dx - 1, dy)] != 0 { continue }   // need open room cell in front
            if map.wall[doorCell] == 0 || map.wall[closet] == 0 { continue }
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
                chamber.append((cx, cy))
            } }
            if !ok { continue }
            let dCell = map.idx(door.0, door.1)
            map.floor[dCell] = theme.floor.rawValue; map.ceil[dCell] = theme.ceil.rawValue; map.light[dCell] = 0.6
            map.wall[dCell] = WallTex.hazard.rawValue                          // yellow-black hazard door — the "fuel store" sign
            map.doors[dCell] = DoorState()
            var cells: [SIMD2<Float>] = []
            for (cx, cy) in chamber {
                let i = map.idx(cx, cy)
                map.wall[i] = 0; map.floor[i] = theme.floor.rawValue; map.ceil[i] = theme.ceil.rawValue; map.light[i] = 0.6
                cells.append(SIMD2(Float(cx) + 0.5, Float(cy) + 0.5))
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
                                 keyCells: [KeyColor: Int], exitRoomIndex: Int, rng: inout Rng)
        -> ([MonsterSpawn], [ItemSpawn], [SIMD2<Float>], [SIMD2<Float>], [Prop]) {
        var monsters: [MonsterSpawn] = []
        var items: [ItemSpawn] = []
        var drums: [SIMD2<Float>] = []
        var sockets: [SIMD2<Float>] = []
        var props: [Prop] = []

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

        // keys
        for (color, cell) in keyCells { items.append(ItemSpawn(kind: color.item, pos: note(center(cell)))) }
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

            // items
            let lootRolls = rng.i(1, 3)
            for _ in 0..<lootRolls {
                guard let p = spot(in: r) else { continue }
                items.append(ItemSpawn(kind: pickItem(level: level, rng: &rng), pos: p))
            }
        }

        // deeper field drops, rare: a crate of mines, then the rocket launcher,
        // then a cell cache to stock up for the Queen
        if level >= 1, rooms.count > 2, let p = spot(in: rooms[rng.i(2, rooms.count - 1)]) {
            items.append(ItemSpawn(kind: .mineCrate, pos: p))
        }
        if level >= 2, rooms.count > 3, let p = spot(in: rooms[rng.i(2, rooms.count - 1)]), rng.chance(0.7) {
            items.append(ItemSpawn(kind: .weaponRocket, pos: p))
        }
        if level >= 3, rooms.count > 3, let p = spot(in: rooms[rng.i(2, rooms.count - 1)]), rng.chance(0.7) {
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
            // 1. stack the fuel-storage chamber — the primary, clearly-marked cache
            for c in fuelStoreCells where freeOf(c, 0.85) { drums.append(c); placed.append(c) }
            // 2. a couple of opportunistic corner barrels out in the level
            for _ in 0..<rng.i(1, 2) {
                for attempt in 0..<40 {
                    let r = rooms[rng.i(1, rooms.count - 1)]
                    var p: SIMD2<Float>? = nil
                    if attempt < 28 {                              // prefer free corners
                        let corners = cornerCells(r).filter { freeOf($0, 1.05) }
                        if !corners.isEmpty { p = corners[rng.i(0, corners.count - 1)] }
                    } else if let c = randCell(in: r) {            // then any clear cell
                        let q = center(c)
                        if freeOf(q, 1.05) { p = q }
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
                        if freeOf(p, 0.95) { drums.append(p); placed.append(p); break outer }
                    } }
                }
            }
        }
        // recharge sockets — a couple of fixed plasma-cell stations per level so a
        // marine who runs the rifle dry against the (plasma-only) Queen can top up
        // and isn't softlocked. Spread out, clear of drums / pickups / the spawn.
        if rooms.count > 1 {
            for _ in 0..<2 {                                     // "not many, just a couple"
                for _ in 0..<40 {
                    let r = rooms[rng.i(1, rooms.count - 1)]
                    guard let c = randCell(in: r) else { continue }
                    let p = center(c)
                    if sockets.contains(where: { vlen($0 - p) < 2.2 }) { continue }      // keep them apart (relaxed for small maps)
                    if placed.contains(where: { vlen($0 - p) < 1.0 }) { continue }       // clear of every other spawn
                    sockets.append(p); placed.append(p)
                    break
                }
            }
        }

        // ── furnish the rooms ── the citadels were working colonies until the swarm
        // came; the rooms should look lived-in, not like empty test boxes. Furniture
        // is purely decorative (no collision — the fight stays clean), placed flush
        // against the walls so room centres stay open: large dorms get rows of bunks
        // (never the ones with toxic pools), small offices get a desk + terminal +
        // chair, and every room gets steel lockers and pipe runs for the industrial
        // read of the beauty shot.
        let exitX = map.exitCell % map.w, exitY = map.exitCell / map.w
        func solidWall(_ x: Int, _ y: Int) -> Bool {
            !map.inBounds(x, y) || (map.wall[map.idx(x, y)] != 0 && map.doors[map.idx(x, y)] == nil)
        }
        func nearDoor(_ x: Int, _ y: Int) -> Bool {
            for (ox, oy) in [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1)] where map.inBounds(x + ox, y + oy) {
                if map.doors[map.idx(x + ox, y + oy)] != nil { return true }
            }
            return false
        }
        func freeCell(_ p: SIMD2<Float>, _ gap: Float) -> Bool { !placed.contains { vlen($0 - p) < gap } }
        // yaw such that a prop's local +Z (its FRONT) points along `inward` (see GPURaymarch)
        func yawFor(_ inward: SIMD2<Float>) -> Float { atan2(-inward.x, inward.y) }
        // interior edge cells that sit flush against a real wall, with their inward facing
        struct Slot { let pos: SIMD2<Float>; let inward: SIMD2<Float>; let x, y: Int }
        func wallSlots(_ r: Room) -> [Slot] {
            var out: [Slot] = []
            func consider(_ x: Int, _ y: Int, _ inward: SIMD2<Float>) {
                guard map.inBounds(x, y), map.wall[map.idx(x, y)] == 0,
                      map.doors[map.idx(x, y)] == nil, !map.hazard[map.idx(x, y)] else { return }
                if nearDoor(x, y) { return }
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
        func roomHasHazard(_ r: Room) -> Bool {
            for yy in r.y..<(r.y + r.h) { for xx in r.x..<(r.x + r.w) where map.hazard[map.idx(xx, yy)] { return true } }
            return false
        }
        @discardableResult
        func placeProp(_ kind: FurnitureKind, _ slot: Slot, faceInward: Bool = true, gap: Float = 0.85) -> Bool {
            guard freeCell(slot.pos, gap) else { return false }
            props.append(Prop(kind: kind, pos: slot.pos, yaw: yawFor(faceInward ? slot.inward : -slot.inward)))
            placed.append(slot.pos)
            return true
        }
        for r in rooms {
            let slots = wallSlots(r)
            let area = r.w * r.h
            let hazard = roomHasHazard(r)
            // ── floor furniture against the walls ──
            if !slots.isEmpty {
                var used = 0
                if r.w >= 5 && r.h >= 5 && !hazard {
                    // BARRACKS: bunks down the walls, each PAIRED with a locker beside
                    // it — no bed without its locker (a real bunkroom rule).
                    var i = 0
                    while i < slots.count && used < 4 {
                        if placeProp(.bunk, slots[i], gap: 1.0) {
                            used += 1
                            if i + 1 < slots.count { placeProp(.locker, slots[i + 1]) }   // the bunk's mate
                            i += 2
                        }
                        i += 1
                    }
                } else if area <= 20 {
                    // OFFICE: a desk + powered terminal, a chair tucked in front, a locker
                    if let desk = slots.first(where: { freeCell($0.pos, 0.85) }) {
                        placeProp(.desk, desk)
                        // the chair sits just in front of the (now wall-flush) desk, facing it
                        let chairP = desk.pos + desk.inward * 0.62
                        let cx = Int(chairP.x), cy = Int(chairP.y)
                        if map.inBounds(cx, cy), map.wall[map.idx(cx, cy)] == 0, map.doors[map.idx(cx, cy)] == nil,
                           !map.hazard[map.idx(cx, cy)], freeCell(chairP, 0.5) {
                            props.append(Prop(kind: .chair, pos: chairP, yaw: yawFor(-desk.inward), againstWall: false))
                            placed.append(chairP)
                        }
                        for s in slots where placeProp(.locker, s) { break }
                    }
                } else {
                    // utility: a couple of lockers and (space permitting) a desk
                    for s in slots {
                        if used >= 2 { break }
                        if placeProp(.locker, s) { used += 1 }
                    }
                    if !hazard { for s in slots where placeProp(.desk, s) { break } }
                }
            }
            // NOTE: free-standing SDF pipe runs are deferred. As props they cost the
            // GPU dearly (a long run's bounding sphere is evaluated across most of a
            // room's rays) AND they read poorly. The objects rework will reintroduce
            // pipework/steelwork BAKED INTO THE WALL geometry (part of the grid SDF,
            // so effectively free) rather than as separate per-step instances.
        }

        return (monsters, items, drums, sockets, props)
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
