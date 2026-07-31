// Citadel — weapons.
//
// Three weapons, and only three: the kinetic sidearms (fists, pistol, shotgun,
// chaingun) were useless against the colony's organisms — their hide shrugs off
// bullets — so they were left behind. What kills here is energy, fire and
// explosives: the PLASMA RIFLE, the FLAMETHROWER and the ROCKET LAUNCHER. Stats
// live in one table so balancing is one place. Viewmodels are in Sprites.swift.

import Foundation

enum AmmoType: Int, CaseIterable {
    case none, cells, rockets, fuel
    var capacity: Int {
        switch self {
        case .none: return 0
        case .cells: return 400      // plasma rifle — energy cells
        case .rockets: return 16     // rocket launcher — a shell is heavy; you carry what fits on the rig
        case .fuel: return 300       // flamethrower — pressurised fuel
        }
    }
    var label: String {
        switch self {
        case .none: return ""
        case .cells: return "CELL"
        case .rockets: return "RCKT"
        case .fuel: return "FUEL"
        }
    }
}

enum WeaponKind: Int, CaseIterable {
    // Digit order: 1 plasma · 2 flamethrower · 3 rocket. Plasma is the workhorse
    // (and the only thing that kills the Queen); the flamethrower is standard
    // issue (and the only thing that finishes a corpse for good); the rocket
    // launcher is the heavy explosive, found in the field.
    case plasma, flamethrower, rocket
    var def: WeaponDef { Weapon.defs[rawValue] }
}

struct WeaponDef {
    let name: String
    let ammo: AmmoType
    let damage: Int          // per pellet / per hit
    let pellets: Int
    let spread: Float        // radians, half-cone
    let interval: Float      // seconds between shots
    let hitscan: Bool
    let projectile: ProjectileKind?
    let ammoPerShot: Int
    let range: Float         // hitscan reach, cells
}

enum Weapon {
    static let defs: [WeaponDef] = [
        // PLASMA — fast energy bolts; the answer to the Queen and the surest kill
        // on a charging alien.
        WeaponDef(name: "PLASMA",   ammo: .cells,   damage: 20, pellets: 1, spread: 0.03, interval: 0.10, hitscan: false, projectile: .plasma, ammoPerShot: 1, range: 40),
        // FLAMETHROWER — standard issue, but NOT infinitely fuelled. A short
        // forward cone of fire (spread = half-angle, range = reach), ticking fast
        // for a continuous stream. Fire is the aliens' great enemy, and the only
        // thing that burns a corpse — or the Queen — away for good. World handles
        // the cone; the .fuel cost is spent through the normal ammo path.
        WeaponDef(name: "FLAMER",   ammo: .fuel,    damage: 5,  pellets: 1, spread: 0.42, interval: 0.06, hitscan: false, projectile: nil,     ammoPerShot: 1, range: 3.4),
        // ROCKET — heavy splash. Clears a packed corridor and detonates fuel drums
        // from across the room.
        WeaponDef(name: "ROCKET",   ammo: .rockets, damage: 90, pellets: 1, spread: 0.0,  interval: 0.90, hitscan: false, projectile: .rocket, ammoPerShot: 1, range: 40),
    ]
    static func def(_ k: WeaponKind) -> WeaponDef { defs[k.rawValue] }
}
