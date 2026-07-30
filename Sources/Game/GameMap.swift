// Citadel — the level grid.
//
// A cell grid: each cell is either empty (walkable) or a wall (a WallTex id).
// Doors are wall cells with an entry in `doors` that animates open/closed; the
// raycaster parts them down the middle. Floor/ceiling flats and a per-cell light give
// the raycaster what it needs. MapGen fills all of this in; World drives it.

import Foundation
import simd

enum KeyColor: Int, CaseIterable {
    case red, blue, yellow
    var doorTex: WallTex { self == .red ? .doorRed : self == .blue ? .doorBlue : .doorYellow }
    var item: ItemKind { self == .red ? .keyRed : self == .blue ? .keyBlue : .keyYellow }
    var name: String { self == .red ? "RED" : self == .blue ? "BLUE" : "YELLOW" }
}

struct DoorState {
    var open: Float = 0          // 0 closed … 1 fully open (panels part to the jambs)
    var opening = false
    var stay: Float = 0          // seconds left open before auto-close
    var locked: KeyColor? = nil
    var secret = false           // a hidden door textured like the wall
}

final class GameMap {
    let w: Int
    let h: Int
    var wall: [Int]              // WallTex id; 0 = empty/walkable
    var floor: [Int]            // FlatTex id
    var ceil: [Int]             // FlatTex id
    var light: [Float]          // per-cell base brightness 0…1 (legacy/scalar path)
    var lightColor: [SIMD3<Float>]  // per-cell RGB incident light — colored sector lighting (Lighting.bake)
    var hazard: [Bool]          // damaging floor
    var doors: [Int: DoorState] = [:]
    var visited: [Bool]         // for the automap / reveal
    var pipe: [Float]           // baked pipe-routing mask: 1 = a wall pipe runs along this open cell, 0 = none (dives into the wall toward 0)
    /// Per-cell ceiling height in world units. 1 is the standard storey; the plant floors' ROOMS stand at
    /// `tallCeiling` so a machine hall towers over the corridors feeding it. Corridors and doorways stay at 1,
    /// and the renderer closes the step between a tall cell and a short neighbour with a soffit.
    var ceilY: [Float]
    static let tallCeiling: Float = 2.0
    var fuelStore: Set<Int> = []   // interior cells of the fuel-storage chamber: its drums are an INTENTIONAL stack (exempt from reachability relocation)

    /// Wall cells carrying a mounted light FIXTURE. Baked at generation so the furnishing passes can
    /// keep a locker off them — a wardrobe parked in front of a lamp hides the one thing lighting the
    /// room, and until this existed the renderer and MapGen chose that wall independently.
    var wallLamp: Set<Int> = []

    // ── rooms that act on the marine while she stands in them ────────────────────────────────
    // Baked as CELL SETS rather than looked up through room indices at runtime, because the room
    // bookkeeping is per-generation scratch that the NEXT floor overwrites — a live lookup would
    // read another floor's rooms. Neither effect is announced: the health number moving is the
    // whole tell, and a colony that explains itself is a colony with a tutorial in it.
    var medBay: Set<Int> = []      // open cells of a sick bay — dwell here and wounds slowly close
    var toxicRoom: Set<Int> = []   // open cells of any room holding a nukage pool — dwell here and it works on you
    var pipeFittings: [SIMD4<Float>] = []   // CPU-placed pipe fittings: (x, z, outward-normal angle, kind 0 valve · 1 gauge)

    var playerStart = SIMD2<Float>(1.5, 1.5)
    var playerDir: Float = 0
    var exitCell = -1           // wall cell carrying the exit elevator
    var entryCell = -1          // wall cell carrying the ARRIVAL elevator (the car you step out of)

    /// Door open threshold above which it no longer blocks movement or sight.
    static let passThreshold: Float = 0.82

    init(w: Int, h: Int) {
        self.w = w; self.h = h
        let n = w * h
        wall = [Int](repeating: WallTex.steelPanel.rawValue, count: n)   // start solid
        floor = [Int](repeating: FlatTex.concrete.rawValue, count: n)
        ceil = [Int](repeating: FlatTex.ceilTech.rawValue, count: n)
        light = [Float](repeating: 0.8, count: n)
        lightColor = [SIMD3<Float>](repeating: SIMD3(0.8, 0.8, 0.8), count: n)
        hazard = [Bool](repeating: false, count: n)
        visited = [Bool](repeating: false, count: n)
        pipe = [Float](repeating: 0, count: n)
        ceilY = [Float](repeating: 1, count: n)
    }

    @inline(__always) func idx(_ x: Int, _ y: Int) -> Int { y * w + x }
    @inline(__always) func inBounds(_ x: Int, _ y: Int) -> Bool { x >= 0 && x < w && y >= 0 && y < h }

    @inline(__always) func wallAt(_ x: Int, _ y: Int) -> Int {
        if !inBounds(x, y) { return WallTex.steelPanel.rawValue }   // out of bounds = solid
        return wall[idx(x, y)]
    }

    @inline(__always) func isDoorCell(_ x: Int, _ y: Int) -> Bool {
        inBounds(x, y) && doors[idx(x, y)] != nil
    }

    /// Door open fraction for a cell (1 if not a door).
    @inline(__always) func doorOpen(_ x: Int, _ y: Int) -> Float {
        if !inBounds(x, y) { return 0 }
        return doors[idx(x, y)]?.open ?? 1
    }

    /// Blocks the player/monster from entering this cell.
    @inline(__always) func blocksMovement(_ x: Int, _ y: Int) -> Bool {
        if !inBounds(x, y) { return true }
        let i = idx(x, y)
        if wall[i] == 0 { return false }
        if let d = doors[i] { return d.open < GameMap.passThreshold }
        return true
    }

    /// Blocks a sight/ray. Same as movement except fully-open doors are see-through.
    @inline(__always) func blocksSight(_ x: Int, _ y: Int) -> Bool {
        blocksMovement(x, y)
    }

    // ── Door animation ───────────────────────────────────────────────────────

    /// Try to open the door at a cell (player/monster use). Returns the lock
    /// colour if it's locked and `keys` doesn't satisfy it; nil on success/no-door.
    @discardableResult
    func tryOpenDoor(_ x: Int, _ y: Int, keys: Set<KeyColor>) -> KeyColor? {
        guard inBounds(x, y), var d = doors[idx(x, y)] else { return nil }
        if let lock = d.locked, !keys.contains(lock) { return lock }
        d.opening = true
        d.stay = 5
        doors[idx(x, y)] = d
        return nil
    }

    /// Advances every door's open/close animation. Returns the cells whose doors
    /// BEGAN auto-closing this tick, so World can sound them (World decides
    /// audibility by distance and skips the elevator's own doors).
    func update(dt: Float, occupied: Set<Int>) -> [Int] {
        let speed: Float = 2.4
        var beganClosing: [Int] = []
        for (i, var d) in doors {
            if d.opening {
                d.open = min(1, d.open + speed * dt)
                d.stay -= dt
                if d.stay <= 0 && !occupied.contains(i) {
                    d.opening = false       // begin closing
                    beganClosing.append(i)
                }
            } else if d.open > 0 {
                // Someone's in the doorway (IR sensor). Don't merely freeze a
                // half-shut door: actively RE-OPEN it — a frozen partial door
                // reads as open (part < passThreshold) yet blocks shots and steps,
                // trapping the marine. Mirrors the elevator's step-back reopen.
                if occupied.contains(i) { d.opening = true; d.stay = max(d.stay, 1) }
                else { d.open = max(0, d.open - speed * dt) }
            }
            doors[i] = d
        }
        return beganClosing
    }
}
