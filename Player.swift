// Citadel — the marine.
//
// Position/orientation, the vitals (health + armour), the arsenal and ammo
// pools, held keys, and the transient view state (weapon bob, muzzle flash,
// hurt/pickup screen flashes, the HUD face look direction). World mutates it;
// HUD and Raycaster read it.

import Foundation
import simd

struct Player {
    var pos: SIMD2<Float>
    var dir: Float

    var health = 100
    let maxHealth = 100
    var armor = 0
    let maxArmor = 200

    var weapons: [Bool]
    var ammo: [Int]
    var keys: Set<KeyColor> = []

    var current: WeaponKind = .plasma
    var fireCD: Float = 0

    var mines = 0                // proximity explosives carried (deploy with the mine key)
    let maxMines = 8

    // view / feedback state
    var bobPhase: Float = 0
    var bob: Float = 0
    var muzzle: Float = 0        // muzzle-flash timer
    var fireAnim: Float = 0      // viewmodel "fire" frame timer
    var switchAnim: Float = 0    // weapon raise/lower
    var berserk: Float = 0       // seconds of berserk left
    var hurtFlash: Float = 0
    var pickupFlash: Float = 0
    var faceDir: Int = 1         // 0 left, 1 centre, 2 right
    var facePain: Float = 0
    var dead = false

    init(at pos: SIMD2<Float>, dir: Float) {
        self.pos = pos
        self.dir = dir
        weapons = Array(repeating: false, count: WeaponKind.allCases.count)
        weapons[WeaponKind.plasma.rawValue] = true         // issued for the retake
        weapons[WeaponKind.flamethrower.rawValue] = true   // standard issue, never leaves the kit
        ammo = Array(repeating: 0, count: AmmoType.allCases.count)
        ammo[AmmoType.cells.rawValue] = 120
        ammo[AmmoType.fuel.rawValue] = 120
    }

    func has(_ w: WeaponKind) -> Bool { weapons[w.rawValue] }
    func ammoCount(_ t: AmmoType) -> Int { ammo[t.rawValue] }

    var healthBracket: Int {
        if health <= 0 { return 0 }
        if health < 25 { return 1 }
        if health < 50 { return 2 }
        if health < 75 { return 3 }
        return 4
    }

    /// True if the current weapon can fire right now (has ammo).
    func currentHasAmmo() -> Bool {
        let def = current.def
        if def.ammo == .none { return true }
        return ammo[def.ammo.rawValue] >= def.ammoPerShot
    }

    @discardableResult
    mutating func giveWeapon(_ w: WeaponKind) -> Bool {
        let isNew = !weapons[w.rawValue]
        weapons[w.rawValue] = true
        return isNew
    }

    /// Give ammo; returns false if already at capacity (so the pickup is wasted).
    @discardableResult
    mutating func giveAmmo(_ t: AmmoType, _ n: Int) -> Bool {
        if t == .none { return false }
        let cap = t.capacity
        if ammo[t.rawValue] >= cap { return false }
        ammo[t.rawValue] = min(cap, ammo[t.rawValue] + n)
        return true
    }
}
