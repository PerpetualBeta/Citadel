// Citadel — the occupying aliens, on the ground.
//
// The Strataris fleet has landed. Their crews and war-beasts now hold the
// colony citadels: swarming Grunts, ranged Troopers, hulking Brutes, drifting
// Floaters, and the Overlord that commands a citadel's core. Stats live in one
// table; the AI (wake / chase / attack / pain / die) is driven from World.

import Foundation
import simd

enum MonsterKind: Int, CaseIterable {
    // The colony holds one organism, in two castes: the DRONE — a scaled, slick
    // pack-hunter that kills by eating and by the toxin it sweats — and the QUEEN
    // that breeds them. Clear a level by killing her, then burning the body.
    case alien, queen
    var def: MonsterDef { MonsterTable.defs[rawValue] }
    var displayName: String {
        switch self {
        case .alien: return "DRONE"
        case .queen: return "QUEEN"
        }
    }
    var codexText: String {
        switch self {
        case .alien:
            return "SCALED, SLICK-SKINNED PACK HUNTER. CARRIES NO WEAPON — IT EATS, AND ITS SWEAT BURNS. SLOW, BUT IT THINKS, AND IT RARELY HUNTS ALONE — IT WANTS A PARTNER AT ITS FLANK. PLASMA, FIRE OR A ROCKET."
        case .queen:
            return "THE BROODMOTHER. SHE BIRTHS THE SWARM AND LOATHES THE LIGHT. ONLY PLASMA WILL WOUND HER — AND ONLY FIRE WILL KEEP HER DOWN. KILL HER, OR THE LEVEL NEVER ENDS."
        }
    }
}

struct MonsterDef {
    let maxHealth: Int
    let speed: Float          // cells / second
    let melee: Int            // contact damage
    let ranged: Bool
    let projectile: ProjectileKind
    let projDamage: Int
    let attackInterval: Float
    let points: Int
    let radius: Float
    let billboardH: Float     // sprite height as a fraction of a wall (1 = full)
    let painChance: Float
    let flying: Bool
    let sight: Float          // wake range, cells
}

enum MonsterTable {
    // billboardH is the on-screen sprite scale (1 = full wall height). Neither
    // caste carries a ranged weapon — they kill in melee (bite + toxic contact),
    // so `ranged` is false and the projectile fields are vestigial. Tune by eye.
    static let defs: [MonsterDef] = [
        // DRONE — slow, durable pack hunter. No ranged attack; closes and bites.
        MonsterDef(maxHealth: 55, speed: 1.55, melee: 12, ranged: false, projectile: .fireball, projDamage: 0,
                   attackInterval: 0.9, points: 100, radius: 0.40, billboardH: 1.05, painChance: 0.30, flying: false, sight: 24),
        // QUEEN — vast, ponderous, immensely tough (and only plasma even scratches
        // her). Lairs in the dark and breeds. The level objective.
        MonsterDef(maxHealth: 900, speed: 0.45, melee: 40, ranged: false, projectile: .fireball, projDamage: 0,
                   attackInterval: 1.6, points: 6000, radius: 1.1, billboardH: 2.2, painChance: 0.03, flying: false, sight: 32),
    ]
}

enum MState { case idle, chase, attack, pain, dying, dead }

struct Monster {
    var kind: MonsterKind
    var pos: SIMD2<Float>
    var health: Int
    var state: MState = .idle
    var stateTime: Float = 0
    var animTime: Float = 0
    var attackCD: Float = 0
    var awake = false
    var painFlash: Float = 0
    var dir: Float = 0            // facing (for future 8-rotation views)
    var burn: Float = 0          // corpse burn-away progress 0→1 (flamethrower)
    var ashed: Float = 0         // charred remains crumble to an ash pile 0→1 when trodden through
    var rearAmt: Float = 0       // DRONE mesh: eased 0→1 rear-up onto the hind legs when it strikes
    var deathSeed: Float = 0     // frozen 0…1 per-corpse seed → varies the death-collapse posture
    var gibbed = false           // obliterated by a blast — chunks fly, no corpse remains
    var smolder: Float = 0       // seconds of smoke/embers left after a corpse burns out
    var dissolving = false       // died on a toxic pool — the body sinks and dissolves
    var dissolveT: Float = 0     // dissolve progress (seconds)
    var lastSeen: SIMD2<Float> = .zero   // last known player position (hunt there when LOS breaks)
    var hasSeen = false                  // lastSeen is valid
    var revive: Float = 0                // QUEEN only: seconds until she regenerates unless her corpse is set alight
    var wallBias: Float = 0              // committed wall-follow slip side (±1) — anti corner-jitter
    var wallHold: Float = 0              // seconds left on that commitment
    var snarlCD: Float = 0               // QUEEN: cooldown between snarls/hisses at a nearby player

    init(kind: MonsterKind, pos: SIMD2<Float>) {
        self.kind = kind
        self.pos = pos
        self.health = kind.def.maxHealth
    }

    var alive: Bool { state != .dying && state != .dead }
    var def: MonsterDef { kind.def }
}
