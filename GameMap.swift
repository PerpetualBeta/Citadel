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

    var playerStart = SIMD2<Float>(1.5, 1.5)
    var playerDir: Float = 0
    var exitCell = -1           // wall cell carrying the exit switch

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

    func update(dt: Float, occupied: Set<Int>) {
        let speed: Float = 2.4
        for (i, var d) in doors {
            if d.opening {
                d.open = min(1, d.open + speed * dt)
                d.stay -= dt
                if d.stay <= 0 && !occupied.contains(i) {
                    d.opening = false       // begin closing
                }
            } else if d.open > 0 {
                if occupied.contains(i) { d.stay = 1 }   // hold open while blocked
                else { d.open = max(0, d.open - speed * dt) }
            }
            doors[i] = d
        }
    }
}
