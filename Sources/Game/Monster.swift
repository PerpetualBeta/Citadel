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

    /// How fast this creature may swing its facing, radians/second — DERIVED, not tuned, so it
    /// cannot drift out of step with the body it belongs to. The rule: a creature reorients in
    /// about the time it takes to cover its own length, so a long slow body turns like one.
    ///
    /// Facing used to be assigned straight to the bearing of the player, which meant the whole
    /// mesh yawed as fast as the marine could move — a drone's long snout swinging between frames,
    /// which reads as a twitch at the neck rather than a head turn. It also fed a jumping facing
    /// into the mesh settle solver, and that solver is not continuous in `dir` (see
    /// `Monster.drawnPos`), so the twitch came with a lurch.
    ///
    /// It works out at 349°/s for a drone — which still tracks a SPRINTING marine circling at
    /// bite range, so nothing about closing and biting changes — and 37°/s for the Queen, who is
    /// meant to be vast and ponderous and who you are supposed to be able to out-manoeuvre.
    /// Neither caste's attacks depend on facing: melee is distance plus a clear line.
    var turnRate: Float { .pi * speed / (2 * radius) }
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

    // ── where the body is DRAWN, and therefore where it can be HIT ────────────
    //
    // The mesh is far larger than the 0.4-cell collision radius, so a creature standing
    // legitimately close to a wall has its BULK lapping into it. Before drawing, the whole
    // mesh is settled clear of walls and furniture (MeshCreature's pose resolve) — which
    // means the body on screen sits up to a footprint-radius off `pos`.
    //
    // That offset was render-only while combat still tested `pos`, and the two disagreed:
    // you aimed at the drone you could SEE and the shot went through empty air beside the
    // one the sim held. Worse for plasma, whose lock needs line-of-sight to the target — and
    // `pos` sits hard against the wall face the mesh was pushed off, so the ray grazes it and
    // the lock is refused (and for a body that slid, or had a door shut on it, `pos` is inside
    // the wall outright). No reticle at all on a drone in plain view.
    //
    // So the resolve is the SIM's now, published here, and every aim and hit test reads it.
    // Movement and AI keep using `pos`: the resolve is deliberately unsatisfiable in a
    // one-cell corridor, and must never be allowed to gate a step.
    //
    // What is stored is the OFFSET from `pos`, not an absolute position, and that is deliberate.
    // An absolute answer goes stale the instant the AI moves the body — it names somewhere the
    // creature has already left — so it needed a cache key and a fallback to `pos` when the key
    // missed, and the fallback itself was a jump. An offset cannot go stale: it rides along with
    // the walk, so only the CORRECTION is ever a frame behind, never the body.
    //
    // The offset is also RATE-LIMITED, because the solver it comes from is not continuous. It is
    // iterative on a fixed budget, it picks the strongest violation each round (an argmax, which
    // flips when two samples tie), and a door's `open` fraction crossing `passThreshold` flips a
    // boolean it chooses a push direction from. Measured with `CITADEL_SETTLEPROBE`: half a degree
    // of turn could move the drawn body 0.37 m, and a door opening beside a waiting drone moved it
    // 0.39 m in the single frame the threshold was crossed — a body appearing in the doorway rather
    // than walking into it, which is exactly what it looked like. Fixing the solver's continuity
    // case by case is whack-a-mole; capping how fast the correction may travel is not, and it also
    // covers whatever the next such flip turns out to be.
    //
    // The cap is the creature's OWN speed: a body may never be drawn moving faster than it could
    // actually move, because past that it stops reading as movement at all. So a correction that
    // used to teleport now slides in about a quarter of a second, and every aim and hit test still
    // reads exactly the position on screen.
    var drawnPos: SIMD2<Float> { pos + drawnOffset }
    private var drawnOffset = SIMD2<Float>(0, 0)   // the settle correction, eased toward the solver's answer
    private var drawnEverSettled = false           // …snap on the first resolve; slide from then on
    private var drawnAsCorpse = false              // a corpse settles once and then holds, however the world moves

    init(kind: MonsterKind, pos: SIMD2<Float>) {
        self.kind = kind
        self.pos = pos
        self.health = kind.def.maxHealth
    }

    var alive: Bool { state != .dying && state != .dead }
    var def: MonsterDef { kind.def }

    /// 0…1 through the death collapse — the shape the renderer slumps and topples the mesh by.
    /// Lives here so the sim's pose resolve and the draw call cannot fall out of step over it.
    var deathProgress: Float {
        switch state {
        case .dead: return 1
        case .dying:
            guard kind == .queen else { return min(1, stateTime / World.droneDeathTime) }
            let f = min(1, (stateTime / World.queenDeathTime) / World.queenImpactT)
            return f * f                              // eased — she accelerates into the floor
        default: return 0
        }
    }

    /// 0…1 sinking into a toxic pool.
    var dissolveProgress: Float { dissolving ? min(1, dissolveT / World.dissolveTime) : 0 }

    /// The mesh has collapsed far enough that the sprawled-corpse capsule fits it better than a
    /// live drone's slim snout taper.
    var corpsePose: Bool { deathProgress >= 0.5 || dissolveProgress >= 0.5 }

    /// Re-resolve where this body is drawn, and travel `dt` seconds toward that answer.
    ///
    /// `dt` of 0 re-asks the question without moving, which is what a render-time refresh wants:
    /// the answer is brought up to date but the slide is the tick's business, so refreshing twice
    /// in a frame cannot advance it twice.
    ///
    /// A CORPSE resolves and then HOLDS: it never moves again, and its resolve ignores doors, so
    /// re-resolving it could only twitch a settled body across the room. It holds once it has
    /// arrived, though — not the instant it dies — otherwise the collapse would freeze the body
    /// mid-slide, at whatever the live capsule's answer had been.
    mutating func refreshDrawn(dt: Float,
                              _ resolve: (_ pos: SIMD2<Float>, _ dir: Float, _ corpse: Bool) -> SIMD2<Float>) {
        let corpse = corpsePose
        if corpse, drawnAsCorpse { return }                     // already settled as a corpse
        let target = resolve(pos, dir, corpse) - pos
        guard drawnEverSettled else {                           // first sight of this body — no history to slide from
            drawnOffset = target
            drawnEverSettled = true
            drawnAsCorpse = corpse
            return
        }
        let step = target - drawnOffset, gap = simd_length(step)
        let reach = def.speed * max(0, dt)          // how far this body may be drawn moving this frame
        if gap > reach {
            if reach > 0 { drawnOffset += step * (reach / gap) }
        } else {
            // WITHIN one frame's travel of the answer — so hold, rather than close the last
            // fraction. This is the hysteresis, and the band is the slew limit itself: a target
            // this close cannot be chased in less than a frame, so chasing it produces a twitch
            // and then a twitch back, which is the shimmer rather than a correction. Holding also
            // makes the approach strictly monotonic — the body slews toward the answer, stops on
            // arrival, and can never overshoot, so it has no way to oscillate at all.
            //
            // The cost is that the body sits up to one frame's travel from the solver's answer:
            // ~2.6 cm, against a footprint radius of ~39 cm. It cannot lap the mesh back into a
            // wall, which is the whole reason the settle exists.
            if corpse { drawnAsCorpse = true }      // ...and a corpse that has arrived holds for good
        }
    }
}
