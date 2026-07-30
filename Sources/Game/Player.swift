// Citadel — the marine.
//
// Position/orientation, the vitals (health + armour), the arsenal and ammo
// pools, held keys, and the transient view state (weapon bob, muzzle flash,
// hurt/pickup screen flashes, the HUD face look direction). World mutates it;
// HUD and the renderer read it.

import Foundation
import simd

struct Player {
    var pos: SIMD2<Float>
    var dir: Float

    // Vitals caps are static so data-driven UI (the intel codex) can quote them
    // without holding a Player — one source of truth, no copies to drift.
    var health = Player.maxHealth
    static let maxHealth = 100
    var armor = 0
    static let maxArmor = 200

    var weapons: [Bool]
    var ammo: [Int]
    var keys: Set<KeyColor> = []

    var current: WeaponKind = .plasma
    var fireCD: Float = 0

    var mines = 0                // proximity explosives carried (deploy with the mine key)
    static let maxMines = 8
    /// THE ISSUE LOAD — what she is handed for the retake, as distinct from the carry CAP she may
    /// scavenge up to. Named because the gun's own charge gauge measures against it: a gauge scaled to
    /// the 400-cell cap would read one segment of three from the very first frame of a new game, which
    /// tells the player she is nearly dry when she is fully equipped. The issue load is the honest
    /// frame of reference — "a full load" is what you started with, not what you could theoretically hoard.
    static let issueCells = 120
    static let issueFuel = 120

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
        ammo[AmmoType.cells.rawValue] = Player.issueCells
        ammo[AmmoType.fuel.rawValue] = Player.issueFuel
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
