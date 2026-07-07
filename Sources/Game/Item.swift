// Citadel — pickups.
//
// Health, armour repairs, the three energy/fire/explosive ammos, proximity-mine
// crates, the rocket launcher and coloured keycards. The pickup effect itself
// lives on World (it mutates the player); this file is the kind enum + the floor
// instance. Sprites are generated in Sprites.swift.

import Foundation
import simd

enum ItemKind: Int, CaseIterable {
    case stim, medkit, armor, megaArmor
    case ammoCells, ammoRockets, ammoFuel, mineCrate
    case weaponRocket
    case keyRed, keyBlue, keyYellow

    var pickupMessage: String {
        switch self {
        case .stim: return "STIMPACK"
        case .medkit: return "MEDKIT"
        case .armor: return "ARMOUR REPAIR"
        case .megaArmor: return "FULL ARMOUR!"
        case .ammoCells: return "ENERGY CELL"
        case .ammoRockets: return "ROCKETS"
        case .ammoFuel: return "FUEL"
        case .mineCrate: return "PROXIMITY MINES"
        case .weaponRocket: return "GOT THE ROCKET LAUNCHER!"
        case .keyRed: return "PICKED UP THE RED KEY"
        case .keyBlue: return "PICKED UP THE BLUE KEY"
        case .keyYellow: return "PICKED UP THE YELLOW KEY"
        }
    }

    // Pickup magnitudes — the one table both World.applyPickup (the effect) and
    // the intel codex (the printed promise) read, so the dossier can never
    // drift from what the floor actually gives.
    static let stimHeal = 10
    static let medkitHeal = 25
    static let armorRepair = 40          // green plate: patches the suit…
    static let armorRepairCap = 100      // …but only up to a half-worn suit
    static let cellsPerPickup = 40
    static let rocketsPerPickup = 5
    static let fuelPerPickup = 100
    static let minesPerCrate = 3

    /// Items that should not be removed unless they actually help the player
    /// (e.g. don't vacuum up health you don't need). World decides; this hints.
    var alwaysTaken: Bool {
        switch self {
        case .weaponRocket, .mineCrate, .keyRed, .keyBlue, .keyYellow, .megaArmor: return true
        default: return false
        }
    }
}

struct Item {
    var kind: ItemKind
    var pos: SIMD2<Float>
    var taken = false
    var bob: Float = 0
}
