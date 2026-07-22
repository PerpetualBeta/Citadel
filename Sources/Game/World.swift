// Citadel — the live game world.
//
// Owns the map, the player, monsters, items, projectiles and particles, and
// advances all of them each frame from the merged input. Movement uses
// axis-separated wall sliding; weapons are hitscan or projectile; monsters
// wake on sight/noise then chase and attack; rockets/BFG deal splash. The
// renderer reads this; it never reaches back in.

import Foundation
import simd

@inline(__always) func vlen(_ v: SIMD2<Float>) -> Float { (v.x * v.x + v.y * v.y).squareRoot() }

/// How a hit was delivered. The Queen's hide turns everything but plasma — fire
/// and explosives only enrage her (though fire is what finishes her corpse).
enum DamageKind { case plasma, fire, explosive, generic }

struct Particle {
    var pos: SIMD2<Float>
    var vel: SIMD2<Float>
    var life: Float
    var maxLife: Float
    var color: UInt32
    var size: Float
    var height: Float = 0.42     // draw height as a fraction of the wall column (0 = floor, ↑ rises)
    var rise: Float = 0          // height gained per second (steam drifts up)
    var maxAlpha: Float = 1      // opacity cap (steam is faint)
    var fire = false             // additive + age-ramped (white→orange→red→smoke) for flame
}

/// A fixed point where pressurised steam vents from the plant's pipework (or a
/// wall grille). Jets out into the room, then rises. Hisses intermittently.
struct SteamVent {
    var pos: SIMD2<Float>
    var dir: SIMD2<Float>        // jet direction (away from the wall)
    var phase: Float             // desync the hiss between vents
}

/// A pressurised fuel drum: a solid prop that refuels the flamethrower when the
/// marine stands at it, and ruptures in a fierce blast when shot (or caught in
/// another explosion). A drained drum is a weaker bomb than a full one.
struct Drum {
    var pos: SIMD2<Float>
    var fuel: Int                // flamethrower fuel reserve left to pump out
    var health: Int              // damage it soaks before rupturing
    var hitFlash: Float = 0      // brief flash when struck
}

/// A deployed proximity mine. Arms after a short delay (so you don't blow your
/// own boots off), then detonates when any live alien crosses it — or when an
/// explosion sets it off (chained through `triggered`).
struct Mine {
    var pos: SIMD2<Float>
    var arm: Float               // arming countdown; <= 0 ⇒ live
    var blink: Float = 0         // LED pulse accumulator (renderer reads it)
    var triggered = false        // set by a nearby blast → detonates next tick
}

/// A fixed plasma recharge station. Stand at it to top up the rifle's energy
/// cells from its finite reserve — a couple per level so running the rifle dry
/// against the plasma-only Queen can't softlock the run. Indestructible.
struct Socket {
    var pos: SIMD2<Float>        // the open cell the marine stands in to plug in
    var yaw: Float = 0           // facing — the panel mounts on the wall behind, facing into the room
    var charge: Int              // energy cells left to dispense
    var maxCharge: Int = 1       // full reserve (drives the wall panel's capacity readout)
    var regenAcc: Float = 0      // fractional self-recharge accumulator (powered infrastructure tops itself back up)
    var pulse: Float = 0         // glow pulse accumulator (renderer reads it)
    var depleted = false         // ran dry: the panel goes RED and won't dispense until it
                                 // has rebuilt a tenth of its reserve (~12 s at the regen rate)
}

final class World {
    let map: GameMap
    var player: Player
    var monsters: [Monster] = []
    var items: [Item] = []
    var projectiles: [Projectile] = []
    var particles: [Particle] = []

    /// The live flamethrower jet, stashed by `flameTick` for the renderer (the GPU
    /// volumetric flame + its firelight). `t` counts down each frame so the stream
    /// reads continuous across the 0.06 s fire ticks and tails off a beat after the
    /// trigger releases; nozzle/dir/reach mirror the exact mechanics so flame and
    /// damage share one source of truth.
    struct FlameJet { var t: Float = 0; var nozzle = SIMD2<Float>(); var dir = SIMD2<Float>(); var reach: Float = 0 }
    var flameJet = FlameJet()

    /// Short-lived explosion FIREBALLS (drum ruptures, rockets) rendered by the GPU
    /// puff-fire (gatherFireEmitters): each expands fast then fades to sooty smoke
    /// over `life`. `size` = final fireball radius; `soot` biases it toward black.
    struct Fireball { var pos: SIMD2<Float>; var age: Float = 0; var life: Float; var size: Float; var soot: Float }
    var fireballs: [Fireball] = []

    /// Set by handleUse when the marine activates a computer-desk terminal. The
    /// Renderer consumes it (clears it) to zoom into the terminal and show an
    /// easter egg, suspending play while it's read.
    var terminalUsePending = false

    var score = 0
    let level: Int
    let colonyIndex: Int
    let colonyName: String
    var elapsed: Float = 0
    var combatHeat: Float = 0      // 0…1 recent weapon-fire / damage; feeds the reactive audio bed, decays each frame

    var killCount = 0
    /// Every alien this floor has EVER held — the initial population plus each
    /// drone the Queen births (breedQueen bumps it). killCount == monsterTotal
    /// therefore means every alien that ever existed here is dead: with the
    /// Queen burned (no more spawning), the HUD counter is a true clear-meter.
    private(set) var monsterTotal: Int
    var secretsFound = 0
    let secretTotal: Int

    var levelComplete = false
    var messages: [(text: String, time: Float)] = []

    // ── the exit elevator ── the ride replaces the old instant teleport: call
    // the car (doors part), step in, the doors close in front of you, the car
    // drops with a rumble and a judder, THEN the level completes.
    enum ElevatorPhase { case idle, boarding, awaitFire, closing, descending }
    var elevatorPhase: ElevatorPhase = .idle
    private var prevElevFire = false   // FIRE edge-latch for the descend/jump prompts
    private var entryOpenSounded = false, entryShutSounded = false
    private var elevatorT: Float = 0
    /// Nominal ride length. The ride doubles as the LOADING screen — the next
    /// floor generates on a background queue while the car drops — so a held
    /// ride (holdRide) extends past this until the floor below is ready.
    static let rideTime: Float = 2.6
    var holdRide = false              // renderer: true while the next floor is still generating
    private var rideRumbleT: Float = 0 // re-arms the winch rumble on an extended ride
    var rideShake: Float = 0          // 0…1 envelope, read by the renderer's camera
    var impactShake: Float = 0        // 0…1 heavy-landing jolt (the Queen's topple), read by the renderer's camera

    /// The Queen dies as a staged EVENT — rear → convulse → topple → crash;
    /// these map her normalised death timeline to seconds. Drones just crumple.
    static let queenDeathTime: Float = 2.8
    static let droneDeathTime: Float = 0.45
    /// Fraction of the Queen's death timeline at which her mass hits the deck —
    /// the floor-shake / thud and the mesh crash are keyed to this.
    static let queenImpactT: Float = 0.78

    // ── the teleporter ── the LAST floor of a citadel has no deeper floor to
    // ride to: its exit is a pad. Step on (Queen dead + burned), FIRE commits,
    // the charge ramps teleportT 0→1 — the renderer dissolves the visor feed to
    // static against it — and at full charge the level completes.
    enum TeleportPhase { case idle, await, charging }
    var teleportPhase: TeleportPhase = .idle
    var teleportT: Float = 0                     // 0…1 charge = static coverage
    static let teleportChargeTime: Float = 2.2
    let isTeleportFloor: Bool                    // exits by pad, not lift
    let arrivalByTeleport: Bool                  // floor 1 of a later citadel — you materialised here
    private var padHintCD: Float = 0
    /// The receiver pad's dying glow after a teleport arrival (renderer light).
    var arrivalGlow: Float { arrivalByTeleport ? max(0, 1 - elapsed / 6) : 0 }

    private var rng: Rng
    private var hazardTimer: Float = 0
    private var monsterHazardTimer: Float = 0
    var blasts: [(pos: SIMD2<Float>, t: Float, col: SIMD3<Float>)] = []   // impact flashes (renderer light), coloured per cause
    private var steamTimer: Float = 0
    private var sparkTimer: Float = 0
    private var faultAmbTimer: Float = 12        // countdown to the next distant electric-shock (damaged-building ambience)
    private var faultFlickerT: Float = 0         // remaining lights-flicker time after a fault fires
    private static let faultFlickerDur: Float = 1.7
    var powerDim: Float = 0                      // 0 normally; 0…~0.65 as the lights sag/flicker with a fault (renderer reads it → dbg.z). Settable so a capture harness can stage a fault.
    // electrical-fault audio: a shower CHARGES (buzz) then EMITs (sparks + crackle) a beat later
    private var sparkCharge: [(site: Int, t: Float)] = []
    private let faultHumRange: Float = 2.6       // metres — proximity hum inaudible beyond this (per spec: only within 2–3 m)
    private let faultSparkRange: Float = 8.0     // metres — buzz/crackle distance falloff
    private let faultChargeLead: Float = 0.20    // seconds the buzz leads the sparks
    private var faultHumLevel: Float = 0         // smoothed hum level — eased toward target so it swells/fades, never snaps on
    private let faultHumSmooth: Float = 0.30     // hum fade time-constant (s)
    // ── the Queen ──
    private var queenBreedCD: Float = 60         // seconds to her next spawn
    private var queenHintCD: Float = 0           // throttle for the "plasma only" hint
    private var droneVoxCD: Float = 1.2           // throttle for the drone vocal director (one voice at a time: near hiss vs far echo)
    // Plasma auto-aim: the locked alien's world position this frame (nil = no lock).
    // The HUD slides + greens the reticle onto it; handleFire flies the bolt at it.
    // Plasma ONLY — the flamethrower (cone) and rocket (splash) don't assist.
    private(set) var plasmaLockPos: SIMD2<Float>? = nil
    private var plasmaLockIndex = -1              // the locked monster's index (stable; monsters are append-only) — the bolt homes to and damages THIS one
    private let plasmaAimArc: Float = 0.14        // ~8° half-angle assist cone around the reticle
    private let plasmaAimRange: Float = 40        // cells; matches the plasma's projectile reach
    private let queenBreedInterval: Float = 60   // she births a drone about once a minute
    private let queenReviveWindow: Float = 8     // a downed Queen has this long to be burned before she rises
    private let queenDroneCap = 14               // most simultaneous live drones she'll grow the brood to
    var steamVents: [SteamVent] = []   // pipework/grille vents (built per level)
    var sparkSites: [SteamVent] = []   // busted-fixture spark/smoke emitters (built per level)
    // ── ground water (the deep rock floors) ──
    // The level's water table: a per-level offset into the shared CPU/GPU puddle
    // noise field (Lighting.puddle ↔ the kernel's puddleField), so no two floors
    // pool alike. The renderer reads it into the kernel's env.xy.
    let waterOff: SIMD2<Float>
    private var dripSites: [SteamVent] = []   // ceiling-drip points over the pools (phase = next-plink countdown)
    // ── resource props ──
    var drums: [Drum] = []             // fuel drums (refuel + shootable bombs)
    var deployedMines: [Mine] = []     // proximity mines the marine has dropped
    var sockets: [Socket] = []         // fixed plasma recharge stations (anti-softlock)
    var props: [Prop] = []             // furniture/fixtures (set-dressing; SOLID — see propColliders)
    // Solid-collision boxes for the furniture, built once at level load (oriented to
    // each piece, flush-matched to where it renders). Static — pure-CPU, no per-frame
    // rebuild and nothing on the GPU, so collision never touches the thermal budget.
    private struct PropBox { let c: SIMD2<Float>; let hw, hd, boundR: Float; let tangent, inward: SIMD2<Float> }
    private var propColliders: [PropBox] = []

    // resource-prop tuning — one table so balancing lives in one place
    private let drumFuel = 150               // flamethrower fuel a full drum holds
    private let drumHealth = 24              // damage a drum soaks before it ruptures
    private let drumBlastRadius: Float = 2.7 // a full drum's blast reach (scaled by fuel left)
    private let drumBlastDamage = 115        // a full drum's centre damage (scaled by fuel left)
    private let drumRefuelRate: Float = 80   // fuel/sec pumped while you stand at a drum
    private let drumRefuelRange: Float = 0.55
    private let mineArmTime: Float = 0.9     // delay before a dropped mine goes live
    private let mineTriggerRange: Float = 0.7
    private let minePickupRange: Float = 0.8 // USE this close to your own mine to defuse + reclaim it (slightly > trigger range, so it's easy to grab)
    private let mineBlastRadius: Float = 3.2 // the meanest bang the marine carries — outreaches a full drum
    private let mineBlastDamage = 130        // shapes self-splash + falloff; INSIDE the ring lethality is absolute (explode lethal:)
    // a socket holds ~3 Queen-kills of plasma (derived from her HP ÷ plasma damage)
    // — enough to recover a dry rifle and still finish her, without trivialising the
    // cell economy. Dispenses fast while you stand in it.
    private let socketCharge = MonsterKind.queen.def.maxHealth / WeaponKind.plasma.def.damage * 3
    private let socketRechargeRate: Float = 80   // cells/sec dispensed while standing in a socket
    // the panel is wired to the grid: its reserve trickles back up to full on its own,
    // so draining every socket is never a permanent softlock — a full reserve recovers
    // in ~2 minutes (derived, not magic). Far slower than it dispenses.
    private var socketRegenRate: Float { Float(socketCharge) / 120 }
    private let socketRange: Float = 0.8
    private let doorHeardRange: Float = 8   // cells — a door slide carries about this far (the near-audio range), so you hear the door you came through seal behind you, not distant ones
    private var prevDeploy = false           // edge-track the mine-deploy button
    private var refueling = false            // edge-track standing at a drum (for the message)
    private var recharging = false           // edge-track standing in a socket (for the message)
    private var minesHintGiven = false       // show the "press G" hint once, on first mines

    // ── runtime battle-damage decal channel (world-space, stamped by events) ──
    // each = (x, z, radius, w): w > 0 scorch (char), w < 0 blood (dark pool).
    var decals: [SIMD4<Float>] = []
    var debris: [(pos: SIMD2<Float>, seed: UInt32)] = []   // static rubble piles at damage sites

    // edge-tracking for discrete actions
    private var prevUse = false
    private var prevNext = false
    private var prevPrev = false

    // player motion (for monsters leading their shots)
    private var lastPlayerPos: SIMD2<Float> = .zero
    private var playerVel: SIMD2<Float> = .zero
    private var stepDist: Float = 0     // ground covered since the last footfall (drives the splash cadence)
    private var stepFoot = 0            // alternates L/R

    /// A tiny hand-built world that is NOTHING but a lift car in its shaft —
    /// what the player rides down (renderer-driven, never update()d) while the
    /// real level generates on a background queue. Same steel box, same closed
    /// leaves, same cabin lamp as a real car, so the cut into the arrival car
    /// of the generated floor is seamless.
    static func liftRideShaft() -> World {
        let m = GameMap(w: 5, h: 5)
        for i in 0..<(m.w * m.h) { m.wall[i] = WallTex.liftWall.rawValue }
        let car = m.idx(2, 2), landing = m.idx(2, 1)
        m.wall[car] = WallTex.elevatorSealed.rawValue
        m.doors[car] = DoorState()                     // shut — the leaves you stare at
        m.floor[car] = FlatTex.metalFloor.rawValue
        m.ceil[car] = FlatTex.ceilTech.rawValue
        m.light[car] = 0.85
        m.lightColor[car] = SIMD3(0.95, 0.88, 0.72)    // the warm cabin stamp every car gets
        m.wall[landing] = 0                            // dark landing beyond the closed leaves
        m.floor[landing] = FlatTex.metalFloor.rawValue
        m.ceil[landing] = FlatTex.ceilDark.rawValue
        m.light[landing] = 0.05
        m.lightColor[landing] = SIMD3(0.05, 0.05, 0.06)
        m.exitCell = car                               // the swaying cabin lamp keys off this
        m.playerStart = SIMD2(2.5, 2.5)
        m.playerDir = atan2(Float(landing / m.w - car / m.w), Float(landing % m.w - car % m.w))
        let w = World(rideShaft: m)
        w.elevatorPhase = .descending                  // shaft lights sweep, lamp sways
        return w
    }

    private init(rideShaft map: GameMap) {
        self.level = 0
        self.colonyIndex = 0
        self.map = map
        self.colonyName = ""
        self.secretTotal = 0
        self.monsterTotal = 0
        self.rng = Rng(seed: 1)
        self.waterOff = .zero
        self.isTeleportFloor = false
        self.arrivalByTeleport = false
        self.player = Player(at: map.playerStart, dir: map.playerDir)
        self.lastPlayerPos = map.playerStart
    }

    init(level: Int, colonyIndex: Int, seed: UInt64) {
        self.level = level
        self.colonyIndex = colonyIndex
        self.isTeleportFloor = Progression.isLastFloor(level)
        self.arrivalByTeleport = Progression.floorInBuilding(level) == 1 && level > 1
        let gen = MapGen.generate(level: level, colonyIndex: colonyIndex, seed: seed)
        self.map = gen.map
        self.colonyName = gen.colonyName
        self.secretTotal = gen.secretCount
        self.rng = Rng(seed: seed ^ 0xABCD_1234)
        // the water table gets its own stream so drawing it never shifts the
        // level's other rolls (item bobs, vent phases, …)
        var wrng = Rng(seed: seed ^ 0x57A7_E12D)
        self.waterOff = SIMD2(wrng.f(0, 256), wrng.f(0, 256))
        self.player = Player(at: gen.map.playerStart, dir: gen.map.playerDir)
        self.lastPlayerPos = gen.map.playerStart
        // the arrival car's doors part as the level fades in — the marine steps
        // OUT of the elevator he rode down in (they auto-close behind him)
        if map.entryCell >= 0, map.doors[map.entryCell] != nil {
            map.doors[map.entryCell]!.opening = true
            map.doors[map.entryCell]!.stay = 4
        }
        for s in gen.monsters { monsters.append(Monster(kind: s.kind, pos: s.pos)) }
        for s in gen.items { items.append(Item(kind: s.kind, pos: s.pos, bob: rng.f(0, 6.28))) }
        for d in gen.drums { drums.append(Drum(pos: d, fuel: drumFuel, health: drumHealth)) }
        for s in gen.sockets { sockets.append(Socket(pos: s.pos, yaw: s.yaw, charge: socketCharge, maxCharge: socketCharge)) }
        self.props = gen.props
        // furniture solid-collision boxes — each piece's authored footprint, oriented
        // by its yaw and flush-matched to where it renders against the wall
        for pr in gen.props where pr.kind != .wallPipe {
            let (hw, hd) = GPURaymarch.furnitureFootprint(pr.kind)
            let inward = SIMD2<Float>(-sin(pr.yaw), cos(pr.yaw))
            let tangent = SIMD2<Float>(cos(pr.yaw), sin(pr.yaw))
            let center = pr.againstWall ? pr.pos - inward * (0.46 - hd) : pr.pos
            propColliders.append(PropBox(c: center, hw: hw, hd: hd, boundR: (hw * hw + hd * hd).squareRoot(), tangent: tangent, inward: inward))
        }
        self.monsterTotal = monsters.count
        // Every drum must be REFUELLABLE: the pump triggers within
        // drumRefuelRange of the drum's rim, and the player's own bulk keeps
        // her ~0.68 from its centre — so a standable point must exist inside
        // that ring. MapGen can't check this (the furniture's oriented solid
        // boxes are built HERE), so a drum boxed in by dorm beds would sit
        // tantalisingly out of reach. Validate against the live colliders and
        // relocate any failure to the nearest clear floor.
        relocateUnreachableDrums()
        buildSteamVents()
        buildSparkSites()
        buildDebris()
        buildDripSites()
        if FeatureFlags.allWeapons { grantAllWeapons() }
        message("RETAKE \(colonyName) — FLOOR \(Progression.floorInBuilding(level))")
    }

    private func grantAllWeapons() {
        for w in WeaponKind.allCases { player.weapons[w.rawValue] = true }
        player.ammo[AmmoType.cells.rawValue] = 400
        player.ammo[AmmoType.rockets.rawValue] = 50
        player.ammo[AmmoType.fuel.rawValue] = 300
        player.mines = Player.maxMines
    }

    func message(_ s: String) {
        messages.append((s, 3.0))
        if messages.count > 4 { messages.removeFirst(messages.count - 4) }
    }

    // ── main update ──────────────────────────────────────────────────────────

    func update(dt: Float, input: InputState, audio: AudioEngine) {
        elapsed += dt
        combatHeat = max(0, combatHeat - dt * 0.7)        // combat tension cools over ~1.5 s
        impactShake = max(0, impactShake - dt * 1.8)      // the landing jolt rings down over ~0.55 s
        for i in messages.indices { messages[i].time -= dt }
        messages.removeAll { $0.time <= 0 }

        if player.dead {
            updateProjectiles(dt: dt, audio: audio)
            updateParticles(dt: dt)
            updateMonsters(dt: dt, audio: audio)
            return
        }

        // committed to the teleport beam: the field holds her — no walking off a
        // half-charged pad, no rummaging in the kit. (The swarm can still bite.)
        let lockedInBeam = teleportPhase == .charging
        if lockedInBeam {
            player.bob = max(0, player.bob - dt * 4)
        } else {
            handleWeaponSwitch(input: input)
            turn(dt: dt, input: input)
            let posBefore = player.pos
            move(dt: dt, input: input)
            // a footfall each STRIDE of ground covered (not a fixed bob cadence), so the
            // splash rate tracks the actual pace — quicker when you run, in any direction.
            // Stride lengthens a little with speed so a sprint reads urgent, not frantic.
            let moved = vlen(player.pos - posBefore)
            let stride: Float = max(0.62, 0.52 + 0.06 * (moved / max(dt, 1e-4)))
            stepDist += moved
            if stepDist >= stride {
                let water = waterDepth(at: player.pos)                // the flooded floor 8, or a floor-7 puddle underfoot
                while stepDist >= stride {                            // splash only where water actually stands
                    stepDist -= stride
                    stepFoot ^= 1
                    if water > 0.02 { audio.wade(water, foot: stepFoot) }   // alternate left/right, louder the deeper the water
                }
            }
            handleUse(input: input, audio: audio)
            handleMineDeploy(input: input, audio: audio)
        }
        // smoothed player velocity for monster lead-aim (clamped to a sane top speed)
        var pv = (player.pos - lastPlayerPos) / max(dt, 1e-4)
        if vlen(pv) > 6 { pv = pv / vlen(pv) * 6 }
        playerVel = playerVel * 0.6 + pv * 0.4
        lastPlayerPos = player.pos
        acquirePlasmaTarget()                 // plasma auto-aim lock for this frame (drives the reticle + bolt direction)
        handleFire(dt: dt, input: input, audio: audio)

        // player timers
        player.fireCD = max(0, player.fireCD - dt)
        player.muzzle = max(0, player.muzzle - dt)
        flameJet.t = max(0, flameJet.t - dt)
        for k in fireballs.indices { fireballs[k].age += dt }
        fireballs.removeAll { $0.age >= $0.life }
        player.fireAnim = max(0, player.fireAnim - dt)
        player.switchAnim = max(0, player.switchAnim - dt)
        player.hurtFlash = max(0, player.hurtFlash - dt * 2)
        player.pickupFlash = max(0, player.pickupFlash - dt * 2)
        player.facePain = max(0, player.facePain - dt)
        if player.berserk > 0 { player.berserk = max(0, player.berserk - dt) }
        queenHintCD = max(0, queenHintCD - dt)

        // the ARRIVAL car's leaves sound as they part on spawn and seal behind him
        if map.entryCell >= 0, let ed = map.doors[map.entryCell] {
            if !entryOpenSounded && ed.open > 0.02 { entryOpenSounded = true; audio.elevatorDoor(open: true) }
            if entryOpenSounded && !entryShutSounded && !ed.opening && ed.open < GameMap.passThreshold * 0.6 {
                entryShutSounded = true; audio.elevatorDoor(open: false)
            }
        }
        // doors (held open while something stands in them)
        var occupied = Set<Int>()
        // count EVERY cell the player's collision radius touches, so a door never
        // auto-closes (and traps you) while you're straddling its threshold.
        let pr: Float = 0.34
        for ox in [-pr, pr] { for oy in [-pr, pr] {
            let cxx = Int(player.pos.x + ox), cyy = Int(player.pos.y + oy)
            if map.inBounds(cxx, cyy) { occupied.insert(map.idx(cxx, cyy)) }
        }}
        for m in monsters where m.alive { occupied.insert(map.idx(Int(m.pos.x), Int(m.pos.y))) }
        // an unburned corpse in the threshold jams the door — it can't close on a
        // body (until fire has consumed it), matching the canStand corpse blocking
        for m in monsters where m.state == .dead && m.burn < 0.85 { occupied.insert(map.idx(Int(m.pos.x), Int(m.pos.y))) }
        // the elevator shuts WITH the marine inside, so his cell is exempt from the
        // door hold-open rule — but ONLY once he's clear of the closing plane. While
        // he straddles the doorway the cell stays occupied so the leaves re-open on
        // him (IR sensor) instead of trapping him and descending.
        if elevatorPhase == .descending || (elevatorPhase == .closing && exitDoorClear()) {
            occupied.remove(map.exitCell)
        }
        for ci in map.update(dt: dt, occupied: occupied) where ci != map.exitCell && ci != map.entryCell {
            let dc = SIMD2(Float(ci % map.w) + 0.5, Float(ci / map.w) + 0.5)      // door cell centre
            if vlen(dc - player.pos) < doorHeardRange { audio.doorClose() }        // the door you came through seals audibly behind you
        }
        updateElevator(dt: dt, input: input, audio: audio)
        updateTeleporter(dt: dt, input: input, audio: audio)

        updateMonsters(dt: dt, audio: audio)
        droneProwl(dt: dt, audio: audio)
        breedQueen(dt: dt, audio: audio)
        updateProjectiles(dt: dt, audio: audio)
        updateMines(dt: dt, audio: audio)
        updateDrums(dt: dt, audio: audio)
        updateParticles(dt: dt)
        pickups(audio: audio)
        refuelAtDrums(dt: dt, audio: audio)
        rechargeAtSockets(dt: dt, audio: audio)
        hazardTick(dt: dt, audio: audio)
        // the corpse-fire bed rides the nearest pyre: full roar beside a mid-burn
        // blaze, silent once everything is ash (smolder whispers)
        var burnIntensity: Float = 0
        for m in monsters where m.state == .dead && m.burn > 0 && m.burn < 1 {
            let flare = powf(sinf(m.burn * .pi), 0.6)
            burnIntensity = max(burnIntensity, flare * max(0, 1 - vlen(m.pos - player.pos) / 9))
        }
        audio.burning(burnIntensity)                 // smoldering ash is SILENT — smoke, not fire
        // charred remains crumble to an ash pile when trodden through (marine or a
        // live alien). Only once fully burnt (burn ≥ 0.85, i.e. already passable).
        // ashed 0→1: corpse crumbles to a mound (tread anywhere in her footprint).
        // ashed 1→2: tread ON the mound and it flattens out to a dust smear.
        for i in monsters.indices where monsters[i].state == .dead && monsters[i].burn >= 0.85 && monsters[i].ashed < 2 {
            let cp = monsters[i].pos
            // stage 1 (corpse → mound) triggers as you APPROACH, not just when you're
            // on top of it — so a charred corpse crumbles to dust before you walk into
            // it and it swallows the weapon. stage 2 (flatten) needs a tread ON the mound.
            let rad: Float = monsters[i].ashed < 1 ? monsters[i].def.radius * 1.7 : 0.45
            var trodden = vlen(player.pos - cp) < rad
            if !trodden {
                for j in monsters.indices where j != i && monsters[j].alive && vlen(monsters[j].pos - cp) < rad { trodden = true; break }
            }
            // a door closing on a burnt corpse collapses it to dust too — the same as
            // treading through it — so the leaves never shut on a standing body that
            // then pokes through the closed door.
            var byDoor = false
            if !trodden, map.inBounds(Int(cp.x), Int(cp.y)),
               let d = map.doors[map.idx(Int(cp.x), Int(cp.y))], d.open < GameMap.passThreshold {
                trodden = true; byDoor = true
            }
            if trodden { monsters[i].ashed = min(2, monsters[i].ashed + dt / (byDoor ? 0.22 : 0.4)) }   // door crush is quicker than a footstep
        }
        for bi in blasts.indices { blasts[bi].t -= dt }
        blasts.removeAll { $0.t <= 0 }
        emitSteam(dt: dt)
        emitQueenDrips(dt: dt)
        emitWaterDrips(dt: dt, audio: audio)
        emitSparks(dt: dt, audio: audio)
        faultAmbTimer -= dt
        if faultAmbTimer <= 0 { audio.distantFault(); faultAmbTimer = rng.f(25, 60); faultFlickerT = World.faultFlickerDur }   // occasional far-off crack — and the lights answer it
        if faultFlickerT > 0 {
            faultFlickerT -= dt
            let env = max(0, faultFlickerT / World.faultFlickerDur)                 // 1 → 0, easing the flicker back to full brightness
            let f = 0.5 + 0.5 * sinf(elapsed * 52), g = 0.5 + 0.5 * sinf(elapsed * 33 + 1.3)
            powerDim = env * (0.22 + 0.6 * f * g)                                   // a deep, ragged sag + fast stutter, like a failing circuit
        } else { powerDim = 0 }
        // inBounds guard: the NoClip cheat can walk the marine off the grid — a raw
        // idx() would then index out of the visited array and crash.
        if map.inBounds(Int(player.pos.x), Int(player.pos.y)) {
            map.visited[map.idx(Int(player.pos.x), Int(player.pos.y))] = true
        }
    }

    // ── movement ───────────────────────────────────────────────────────────

    private func turn(dt: Float, input: InputState) {
        let base: Float = 2.7 * GameSettings.shared.turnSpeed
        let fineFrac: Float = 0.30            // controller d-pad fine-aim: a slow precision yaw (~30% of base) — perceptible but far gentler than the stick, hand-tuned like `base`
        var d: Float = 0
        if input.turnLeft { d -= base }
        if input.turnRight { d += base }
        d += input.lookX * base
        d += input.fineAim * base * fineFrac  // d-pad left/right: slow precision yaw for targeting
        player.dir += d * dt                  // turn-right rotates toward the camera plane's +right
        player.dir += input.takeMouseTurn()   // mouse-right turns right
        // keep faceDir for the HUD
        if input.turnLeft || input.lookX < -0.3 { player.faceDir = 0 }
        else if input.turnRight || input.lookX > 0.3 { player.faceDir = 2 }
        else { player.faceDir = 1 }
    }

    private func move(dt: Float, input: InputState) {
        var fwd: Float = 0, strafe: Float = 0
        if input.forward { fwd += 1 }
        if input.back { fwd -= 1 }
        if input.strafeLeft { strafe -= 1 }
        if input.strafeRight { strafe += 1 }
        fwd += input.moveY
        strafe += input.moveX
        fwd = max(-1, min(1, fwd)); strafe = max(-1, min(1, strafe))
        if fwd == 0 && strafe == 0 { player.bob = max(0, player.bob - dt * 4); return }

        let autorun = GameSettings.shared.autorun
        let running = input.run != autorun
        let speed: Float = running ? 5.6 : 3.3
        let dx = cos(player.dir), dy = sin(player.dir)
        // strafe-right = the camera plane's +right direction (-sin, cos)
        let rx = -dy, ry = dx
        var vx = (dx * fwd + rx * strafe) * speed
        var vy = (dy * fwd + ry * strafe) * speed
        let mag = (vx * vx + vy * vy).squareRoot()
        if mag > speed { vx = vx / mag * speed; vy = vy / mag * speed }

        let noClip = FeatureFlags.noClip
        let nx = player.pos.x + vx * dt
        if noClip || canStand(nx, player.pos.y) { player.pos.x = nx }
        let ny = player.pos.y + vy * dt
        if noClip || canStand(player.pos.x, ny) { player.pos.y = ny }

        player.bobPhase += dt * (running ? 11 : 8)
        player.bob = min(1, player.bob + dt * 5)
    }

    private func canStand(_ x: Float, _ y: Float) -> Bool {
        let r: Float = 0.26
        let xs = [x - r, x + r], ys = [y - r, y + r]
        for ox in xs { for oy in ys {
            if map.blocksMovement(Int(floor(ox)), Int(floor(oy))) { return false }
        }}
        // alien corpses are solid until burned away — but a corpse the marine is
        // already standing in never traps him (fresh melee kill underfoot)
        for m in monsters where m.state == .dead && m.burn < 0.85 {
            let rr = m.def.radius * 0.85 + r
            let cdx = m.pos.x - player.pos.x, cdy = m.pos.y - player.pos.y
            if cdx * cdx + cdy * cdy < rr * rr { continue }       // already inside it → don't block
            let dx = m.pos.x - x, dy = m.pos.y - y
            if dx * dx + dy * dy < rr * rr { return false }
        }
        // furniture + drums are solid objects, not projections — you walk up to them
        if blockedBySolidProp(x, y, r) { return false }
        return true
    }

    /// True if a circle (centre x,y, radius r) overlaps any SOLID prop — a furniture
    /// box (static, oriented) or a live fuel drum (dynamic circle). Shared by player
    /// and monster movement so NEITHER walks through furniture. Pure CPU: a handful of
    /// cheap tests per move (bounding-circle rejected first), nothing on the GPU.
    func blockedBySolidProp(_ x: Float, _ y: Float, _ r: Float) -> Bool {
        for b in propColliders {
            let relx = x - b.c.x, rely = y - b.c.y
            let br = b.boundR + r
            if relx * relx + rely * rely > br * br { continue }              // quick reject (far)
            let dW = relx * b.tangent.x + rely * b.tangent.y                 // into the box's frame
            let dD = relx * b.inward.x + rely * b.inward.y
            let cw = max(-b.hw, min(b.hw, dW)), cd = max(-b.hd, min(b.hd, dD))   // closest point on the box
            let ox = relx - (b.tangent.x * cw + b.inward.x * cd)
            let oy = rely - (b.tangent.y * cw + b.inward.y * cd)
            if ox * ox + oy * oy < r * r { return true }                     // circle overlaps the box
        }
        for d in drums where d.health > 0 {                                  // drums are solid too
            let rr: Float = 0.42 + r
            let dx = d.pos.x - x, dy = d.pos.y - y
            if dx * dx + dy * dy < rr * rr { return true }
        }
        return false
    }

    private func handleUse(input: InputState, audio: AudioEngine) {
        let pressed = input.use && !prevUse
        prevUse = input.use
        guard pressed else { return }
        // Recover a deployed mine you're standing near: defuse it and take it
        // back to redeploy elsewhere. Works on ARMED mines — that's the point —
        // and it's safe (updateMines only ever triggers on monsters, never the
        // marine, so you never set off your own mine walking up to it).
        if let mi = nearestOwnMineIndex(within: minePickupRange) {
            if player.mines >= Player.maxMines {
                message("MINES FULL"); audio.locked()
            } else {
                let mpos = deployedMines[mi].pos
                deployedMines.remove(at: mi)
                player.mines += 1
                message("MINE RECOVERED")
                audio.pickup()
                spawnParticles(at: mpos, n: 4, color: packRGBA(180, 184, 196), spread: 1.0, life: 0.2)
            }
            return
        }
        // a computer-desk terminal within reach → read it (easter eggs). The Renderer
        // zooms into the terminal and suspends play; nothing else happens this press.
        if nearDeskTerminal(within: 1.5) { terminalUsePending = true; return }
        // probe a couple of points ahead
        let dx = cos(player.dir), dy = sin(player.dir)
        for reach: Float in [0.7, 1.2, 1.7] {
            let cx = Int(player.pos.x + dx * reach), cy = Int(player.pos.y + dy * reach)
            guard map.inBounds(cx, cy) else { continue }
            let i = map.idx(cx, cy)
            if i == map.exitCell {
                if isTeleportFloor && map.wall[i] == 0 {
                    // the pad has no controls to press — it reads the body on it
                    if !queenDefeated {
                        message("THE QUEEN STILL LIVES — SHE MUST DIE, THEN BURN")
                        audio.locked()
                    } else {
                        message("STAND ON THE PAD — FIRE TO JUMP")
                    }
                    return
                }
                beginElevator(audio: audio); return
            }
            if map.doors[i] != nil {
                if i == map.entryCell {                       // the car he arrived in — dead controls
                    message("THE SHAFT ABOVE IS SEALED")
                    audio.locked()
                    return
                }
                if map.doors[i]!.secret && map.doors[i]!.open == 0 {
                    secretsFound += 1
                    message("A SECRET IS REVEALED!")
                    audio.secret()
                    map.doors[i]!.secret = false   // count once
                }
                if let lock = map.tryOpenDoor(cx, cy, keys: player.keys) {
                    message("YOU NEED THE \(lock.name) KEY")
                    audio.locked()
                } else {
                    audio.doorOpen()
                }
                return
            }
            if map.wall[i] == WallTex.exitSwitch.rawValue {
                beginElevator(audio: audio); return
            }
        }
    }

    /// True if the marine is stood beside a computer-desk terminal (its easter egg
    /// is within reach). Desks are set against a wall, so a modest radius reads as
    /// "at the workstation" without catching a passer-by.
    private func nearDeskTerminal(within r: Float) -> Bool {
        for p in props where p.kind == .desk {
            let dx = p.pos.x - player.pos.x, dy = p.pos.y - player.pos.y
            if dx * dx + dy * dy < r * r { return true }
        }
        return false
    }

    /// Drop a proximity mine at the marine's feet (edge-triggered). It arms after
    /// a short delay, then any alien that crosses it sets it off.
    private func handleMineDeploy(input: InputState, audio: AudioEngine) {
        let pressed = input.deployMine && !prevDeploy
        prevDeploy = input.deployMine
        guard pressed else { return }
        guard player.mines > 0 else { message("NO MINES LEFT"); audio.locked(); return }
        let dx = cos(player.dir), dy = sin(player.dir)
        let ahead = SIMD2<Float>(player.pos.x + dx * 0.45, player.pos.y + dy * 0.45)
        let drop = canStand(ahead.x, ahead.y) ? ahead : player.pos   // never inside a wall
        player.mines -= 1
        deployedMines.append(Mine(pos: drop, arm: mineArmTime))
        message("MINE ARMED")
        audio.pickup()
        spawnParticles(at: drop, n: 4, color: packRGBA(180, 184, 196), spread: 1.2, life: 0.2)
    }

    /// The nearest deployed mine within `r` of the marine (for USE-to-recover), or nil.
    private func nearestOwnMineIndex(within r: Float) -> Int? {
        var best: Int? = nil, bestD = r
        for (i, m) in deployedMines.enumerated() {
            let d = vlen(m.pos - player.pos)
            if d <= bestD { bestD = d; best = i }
        }
        return best
    }

    /// The level objective: no Queen remains that isn't a fully-burned corpse —
    /// she must be killed (plasma) AND torched (fire). Every level seeds one.
    var queenDefeated: Bool {
        !monsters.contains { $0.kind == .queen && !($0.state == .dead && $0.burn >= 1) }
    }

    /// USE on the exit: gate on the Queen, then call the car. (Maps whose exit
    /// has no door — the legacy fallback placement — keep the instant exit.)
    private func beginElevator(audio: AudioEngine) {
        guard !levelComplete else { return }
        if !queenDefeated {
            message("THE QUEEN STILL LIVES — SHE MUST DIE, THEN BURN")
            audio.locked()
            return
        }
        if isTeleportFloor {
            // legacy fallback only (a map whose pad found no site keeps a switch
            // wall): USE engages the jump directly. Pad maps never route here.
            if teleportPhase == .idle { engageTeleport(audio: audio) }
            return
        }
        guard map.doors[map.exitCell] != nil else { completeLevel(audio: audio); return }
        guard elevatorPhase == .idle else { return }
        map.doors[map.exitCell]!.opening = true
        map.doors[map.exitCell]!.stay = 6
        elevatorPhase = .boarding
        message("ELEVATOR OPEN — STEP INSIDE")
        audio.elevatorDoor(open: true)
    }

    /// True when the marine is safely INSIDE the exit car, clear of the door's
    /// closing plane, so the leaves can shut without catching him. Mirrors the door
    /// geometry the renderer uses (GPURaymarch `doorSlidesAlongX` / `elevatorPlane`):
    /// the plane sits toward the open (corridor) edge; the rest of the cell is car.
    /// He must be past the closing slab (half-thickness 0.14) by a body radius (0.26).
    private func exitDoorClear() -> Bool {
        guard map.exitCell >= 0,
              map.idx(Int(player.pos.x), Int(player.pos.y)) == map.exitCell else { return false }
        let cx = map.exitCell % map.w, cy = map.exitCell / map.w
        let slideX = map.inBounds(cx - 1, cy) && map.wall[map.idx(cx - 1, cy)] != 0 &&
                     map.inBounds(cx + 1, cy) && map.wall[map.idx(cx + 1, cy)] != 0
        let (nx, ny) = slideX ? (cx, cy - 1) : (cx - 1, cy)
        let (px, py) = slideX ? (cx, cy + 1) : (cx + 1, cy)
        let lowOpen  = map.inBounds(nx, ny) && map.wall[map.idx(nx, ny)] == 0
        let highOpen = map.inBounds(px, py) && map.wall[map.idx(px, py)] == 0
        let plane: Float = (lowOpen == highOpen) ? 0.5 : (lowOpen ? 0.20 : 0.80)
        let thruFrac = slideX ? (player.pos.y - Float(cy)) : (player.pos.x - Float(cx))
        return abs(thruFrac - plane) > 0.40
    }

    /// The ride state machine: boarding (doors parted, waiting for the marine)
    /// → awaitFire (he's in the car; the floor report overlays the view until
    /// FIRE commits) → closing (the leaves shut in front of him) → descending
    /// (rumble + judder) → the level completes. Stepping out at any point before
    /// the doors have shut re-opens them; the ride only commits once they have.
    private func updateElevator(dt: Float, input: InputState, audio: AudioEngine) {
        guard elevatorPhase != .idle, let d = map.doors[map.exitCell] else { return }
        let clear = exitDoorClear()                          // fully aboard AND clear of the door's closing plane
        let fireEdge = input.fire && !prevElevFire
        prevElevFire = input.fire
        switch elevatorPhase {
        case .idle:
            break
        case .boarding:
            map.doors[map.exitCell]!.stay = max(d.stay, 2)   // never slam mid-boarding
            if clear && d.open >= GameMap.passThreshold {
                elevatorPhase = .awaitFire
                prevElevFire = true                          // require a FRESH press — a held trigger doesn't commit
            }
        case .awaitFire:
            map.doors[map.exitCell]!.stay = max(d.stay, 2)
            if !clear { elevatorPhase = .boarding }          // stepped out / straddling the doors — report hides
            else if fireEdge {
                elevatorPhase = .closing
                map.doors[map.exitCell]!.opening = false
                map.doors[map.exitCell]!.stay = 0
                audio.elevatorDoor(open: false)
            }
        case .closing:
            if !clear {                                       // stepped out or blocking the doors — reopen
                map.doors[map.exitCell]!.opening = true
                map.doors[map.exitCell]!.stay = 3
                elevatorPhase = .boarding
                audio.elevatorDoor(open: true)
            } else if d.open <= 0.02 {
                elevatorPhase = .descending
                elevatorT = 0
                rideRumbleT = World.rideTime - 0.2
                message("DESCENDING…")
                audio.elevatorMove(true)
                // the winch takes up + the car drops: a long low rumble under a
                // sub-bass fall — synthesised, so no asset is needed for a one-off
                audio.trigger(wave: AudioEngine.noise, f0: 1, dur: World.rideTime, amp: 0.30, attack: 0.25)
                audio.trigger(wave: AudioEngine.sine, f0: 52, f1: 30, dur: World.rideTime, amp: 0.42, attack: 0.15)
            }
        case .descending:
            elevatorT += dt
            // The ride is also the LOADING screen: while the next floor is still
            // generating (holdRide), the car keeps dropping — clamp just before
            // the ease-out so the judder holds, and re-arm the rumble under it.
            if holdRide {
                elevatorT = min(elevatorT, World.rideTime - 0.5)
                rideRumbleT -= dt
                if rideRumbleT <= 0 {
                    rideRumbleT = 2.2
                    audio.trigger(wave: AudioEngine.noise, f0: 1, dur: 2.4, amp: 0.20, attack: 0.5)
                    audio.trigger(wave: AudioEngine.sine, f0: 44, f1: 36, dur: 2.4, amp: 0.26, attack: 0.4)
                }
            }
            // ramp the judder in, hold, ease out just before arrival
            let up = min(1, elevatorT * 2.5)
            let down = min(1, max(0, (World.rideTime - elevatorT) / 0.5))
            rideShake = up * down
            if elevatorT >= World.rideTime {
                rideShake = 0
                elevatorPhase = .idle
                audio.elevatorMove(false)                     // the winch stops WITH the car
                completeLevel(audio: audio)
            }
        }
    }

    /// The teleporter pad state machine (last floor of a citadel): step onto the
    /// pad (Queen gate applies) → the SECURED report overlays the view until a
    /// FRESH fire press commits → the charge ramps and the renderer dissolves
    /// the feed to static → full charge completes the level mid-static.
    private func updateTeleporter(dt: Float, input: InputState, audio: AudioEngine) {
        guard isTeleportFloor, !levelComplete, map.exitCell >= 0, map.wall[map.exitCell] == 0 else { return }
        padHintCD = max(0, padHintCD - dt)
        let onPad = map.idx(Int(player.pos.x), Int(player.pos.y)) == map.exitCell
        let fireEdge = input.fire && !prevElevFire
        prevElevFire = input.fire
        switch teleportPhase {
        case .idle:
            if onPad {
                if !queenDefeated {
                    if padHintCD <= 0 {
                        padHintCD = 3
                        message("THE QUEEN STILL LIVES — SHE MUST DIE, THEN BURN")
                        audio.locked()
                    }
                } else {
                    teleportPhase = .await
                    prevElevFire = true                  // require a FRESH press — a held trigger doesn't jump
                }
            }
        case .await:
            if !onPad { teleportPhase = .idle }          // stepped off — report hides
            else if fireEdge { engageTeleport(audio: audio) }
        case .charging:
            teleportT = min(1, teleportT + dt / World.teleportChargeTime)
            // (the growing static crackle is the renderer's looping noise bed,
            //  volume-driven from teleportT — one authority, no burst voices)
            if teleportT >= 1 { completeLevel(audio: audio) }
        }
    }

    private func engageTeleport(audio: AudioEngine) {
        guard teleportPhase != .charging else { return }
        teleportPhase = .charging
        message("TELEPORT ENGAGED")
        // spin-up: a rising carrier — the growing static crackle rides over it
        audio.trigger(wave: AudioEngine.sine, f0: 140, f1: 1300, dur: World.teleportChargeTime, amp: 0.26, attack: 0.5)
    }

    private func completeLevel(audio: AudioEngine) {
        if levelComplete { return }
        if !queenDefeated {
            message("THE QUEEN STILL LIVES — SHE MUST DIE, THEN BURN")
            audio.locked()
            return
        }
        levelComplete = true
        score += 200 + killCount * 5
        if secretsFound > 0 { score += secretsFound * 100 }
        audio.exit()
    }

    // ── weapons / firing ─────────────────────────────────────────────────────

    private func handleWeaponSwitch(input: InputState) {
        if input.weaponDigit > 0 {
            let idx = input.weaponDigit - 1
            if idx < WeaponKind.allCases.count {
                let w = WeaponKind.allCases[idx]
                if player.has(w) && w != player.current { switchTo(w) }
            }
            input.weaponDigit = 0
        }
        let next = input.weaponNext, prev = input.weaponPrev
        if next && !prevNext { cycleWeapon(1) }
        if prev && !prevPrev { cycleWeapon(-1) }
        prevNext = next; prevPrev = prev
    }

    private func cycleWeapon(_ dir: Int) {
        let n = WeaponKind.allCases.count
        var i = player.current.rawValue
        for _ in 0..<n {
            i = (i + dir + n) % n
            if player.weapons[i] { switchTo(WeaponKind.allCases[i]); return }
        }
    }

    private func switchTo(_ w: WeaponKind) {
        player.current = w
        player.switchAnim = 0.18
        player.fireCD = max(player.fireCD, 0.12)
    }

    /// Plasma auto-target: the nearest live, visible alien within a small arc of
    /// the aim. Recomputed each frame before firing, so the reticle lock, the bolt
    /// direction and what actually takes damage all agree. Plasma only.
    private func acquirePlasmaTarget() {
        plasmaLockPos = nil
        plasmaLockIndex = -1
        guard player.current == .plasma, !player.dead else { return }
        let ahead = SIMD2<Float>(cos(player.dir), sin(player.dir))
        let cosArc = cos(plasmaAimArc)
        var bestD = Float.greatestFiniteMagnitude
        var best = -1
        for i in monsters.indices where monsters[i].alive {
            let rel = monsters[i].pos - player.pos
            let d = vlen(rel)
            if d < 0.0001 || d > plasmaAimRange { continue }
            let nd = rel / d
            if nd.x * ahead.x + nd.y * ahead.y < cosArc { continue }   // outside the assist cone
            if !lineOfSight(player.pos, monsters[i].pos) { continue }   // never lock through a wall
            if d < bestD { bestD = d; best = i }
        }
        if best >= 0 { plasmaLockPos = monsters[best].pos; plasmaLockIndex = best }
    }

    private func handleFire(dt: Float, input: InputState, audio: AudioEngine) {
        // Committed to the elevator (or standing on a live pad): FIRE belongs to
        // the descend/jump prompt, not the trigger — the marine doesn't discharge
        // plasma inside the car or the beam.
        let riding = elevatorPhase == .awaitFire || elevatorPhase == .closing || elevatorPhase == .descending
            || teleportPhase == .await || teleportPhase == .charging
        // The flamethrower roars as one continuous loop while the trigger's held and
        // there's fuel — drive it here every frame (edge-detected) so it tracks the
        // trigger, rather than stuttering as randomly-retriggered one-shots.
        let fdef = player.current.def
        let flaming = !riding && input.fire && player.current == .flamethrower && !player.dead
            && (fdef.ammo == .none || player.ammo[fdef.ammo.rawValue] >= fdef.ammoPerShot)
        audio.flame(flaming)
        guard !riding, input.fire, player.fireCD <= 0 else { return }
        let def = player.current.def
        if def.ammo != .none && player.ammo[def.ammo.rawValue] < def.ammoPerShot {
            autoSwitchIfEmpty()
            return
        }
        player.fireCD = def.interval
        combatHeat = min(1, combatHeat + 0.22)            // each shot stokes the reactive bed
        player.muzzle = 0.07
        player.fireAnim = min(0.2, def.interval * 0.6)
        if def.ammo != .none { player.ammo[def.ammo.rawValue] -= def.ammoPerShot }
        wakeNearby(player.pos, radius: 8)

        if def.hitscan {
            for _ in 0..<def.pellets {
                let a = player.dir + rng.f(-def.spread, def.spread)
                hitscan(angle: a, damage: def.damage, range: def.range, audio: audio)
            }
            audio.weaponFire(player.current)
        } else if player.current == .flamethrower {
            flameTick(def, audio: audio)
        } else if let pk = def.projectile {
            // Plasma flies at the auto-locked alien so the bolt visibly strikes what
            // it damages; other projectiles (rocket) fire straight down the aim.
            var ang = player.dir
            var lockIdx = -1
            if player.current == .plasma, let t = plasmaLockPos {
                ang = atan2(t.y - player.pos.y, t.x - player.pos.x)
                lockIdx = plasmaLockIndex               // the bolt strikes THIS alien, not a bigger one nearby
            }
            let dx = cos(ang), dy = sin(ang)
            let origin = SIMD2<Float>(player.pos.x + dx * 0.4, player.pos.y + dy * 0.4)
            projectiles.append(Projectile(pos: origin, vel: SIMD2(dx, dy) * pk.speed,
                                          kind: pk, damage: def.damage, fromPlayer: true, life: pk.lifetime, targetIndex: lockIdx))
            audio.weaponFire(player.current)
        }
    }

    /// The flamethrower: a short forward cone of fire. Each tick it scorches every
    /// live monster inside the cone and IGNITES any alien corpse it touches (which
    /// then burns away on its own). Sprays a stream of flame particles.
    private func flameTick(_ def: WeaponDef, audio: AudioEngine) {
        let dir = SIMD2<Float>(cos(player.dir), sin(player.dir))
        let cosHalf = cos(def.spread)
        for i in monsters.indices {
            let rel = monsters[i].pos - player.pos
            let d = vlen(rel)
            if d > def.range || d < 0.0001 { continue }
            let nd = rel / d
            if nd.x * dir.x + nd.y * dir.y < cosHalf { continue }   // outside the cone
            guard lineOfSight(player.pos, monsters[i].pos) else { continue }   // fire doesn't cook through walls
            if monsters[i].alive { damageMonster(i, def.damage, audio: audio, kind: .fire) }
            else if monsters[i].state == .dead && !monsters[i].gibbed && !monsters[i].dissolving { monsters[i].burn = max(monsters[i].burn, 0.06) }   // light it up (and commits a downed Queen to ash)
            else if monsters[i].state == .dying && monsters[i].kind == .queen { monsters[i].burn = max(monsters[i].burn, 0.06) }   // flames during her topple PRIME the pyre — it catches as she lands
        }
        // playing the flame over a drum cooks it off — torch one across the room
        for di in drums.indices where drums[di].health > 0 {
            let rel = drums[di].pos - player.pos
            let d = vlen(rel)
            if d > def.range || d < 0.0001 { continue }
            let nd = rel / d
            if nd.x * dir.x + nd.y * dir.y < cosHalf { continue }
            damageDrum(di, def.damage, audio: audio)
        }
        // ── the JET ── a PRESSURISED stream of burning fuel: every droplet is
        // born AT THE NOZZLE with real velocity down the aim — ignited as it
        // leaves (the age ramp runs white-hot → orange → deep red → smoke while
        // each droplet flies), drooping slightly as burning fuel does. The
        // stream is clipped by the first wall, where the fuel SPLASHES into
        // licking flame instead of passing through.
        // the jet is born at the SDF viewmodel's nozzle — offset to the marine's
        // right like the held gun, so the stream connects to the weapon on screen
        let nozzle = player.pos + dir * 0.35 + SIMD2(-dir.y, dir.x) * Viewmodel.anchorRight
        var wallD = def.range
        var probe = nozzle, travelled: Float = 0
        while travelled < def.range {
            probe += dir * 0.15; travelled += 0.15
            if map.blocksMovement(Int(probe.x), Int(probe.y)) { wallD = travelled; break }
        }
        // Hand the live jet to the renderer: the GPU draws the flame BODY as a
        // volumetric tongue straight down this aim (flameJet.t persists past the
        // 0.06 s ticks so the stream reads continuous and tails off naturally).
        flameJet = FlameJet(t: 0.10, nozzle: nozzle, dir: dir, reach: wallD)
        let gpuFlame = FeatureFlags.gpuFire
        // the soft additive flame ORBS — the old CPU flame body. This was the
        // compositor's heaviest additive load (close-range O(r²) blends — the
        // fan-spinner); retire it entirely when the GPU renders the jet. Kept
        // behind the flag purely to A/B against the new path.
        if !gpuFlame {
            for _ in 0..<9 {
                let a = player.dir + rng.f(-def.spread * 0.35, def.spread * 0.35)
                let fdir = SIMD2<Float>(cos(a), sin(a))
                let speed = rng.f(8.5, 12.0)
                let life = min((wallD - 0.1) / speed, rng.f(0.30, 0.46))
                particles.append(Particle(pos: nozzle + SIMD2(rng.f(-0.04, 0.04), rng.f(-0.04, 0.04)),
                                          vel: fdir * speed,
                                          life: life, maxLife: 0.46, color: 0,
                                          size: rng.f(5, 10), height: 0.32 + rng.f(-0.03, 0.03),
                                          rise: rng.f(-0.22, 0.06),
                                          maxAlpha: 0.55, fire: true))
            }
        }
        particles.append(Particle(pos: nozzle, vel: dir * rng.f(2, 4) + SIMD2(rng.f(-0.5, 0.5), rng.f(-0.5, 0.5)),
                                  life: rng.f(0.05, 0.12), maxLife: 0.12, color: packRGBA(255, 240, 190),
                                  size: 1.5, height: 0.32, rise: 0, maxAlpha: 1, fire: true))   // nozzle ignition glint (spark)
        // burning embers flung down the stream — sharp sparks (color ≠ 0), cheap,
        // texturing the GPU flame body with flying detail it can't produce
        if gpuFlame {
            for _ in 0..<2 {
                let a = player.dir + rng.f(-def.spread * 0.55, def.spread * 0.55)
                let fdir = SIMD2<Float>(cos(a), sin(a))
                let speed = rng.f(7, 11)
                let life = min((wallD - 0.1) / speed, rng.f(0.16, 0.32))
                particles.append(Particle(pos: nozzle, vel: fdir * speed,
                                          life: life, maxLife: 0.32, color: packRGBA(255, 196, 96),
                                          size: 1.3, height: 0.32, rise: rng.f(-0.1, 0.12),
                                          maxAlpha: 1, fire: true))
            }
        }
        if wallD < def.range {   // fuel splashing and climbing the wall it hits
            let hit = nozzle + dir * (wallD - 0.2)
            // GPU path: a couple of bright embers bouncing off the wall (sparks);
            // legacy path: the old soft splash orbs.
            if gpuFlame {
                for _ in 0..<2 {
                    particles.append(Particle(pos: hit + SIMD2(rng.f(-0.1, 0.1), rng.f(-0.1, 0.1)),
                                              vel: SIMD2(rng.f(-1.1, 1.1), rng.f(-1.1, 1.1)) - dir * rng.f(0.3, 0.9),
                                              life: rng.f(0.2, 0.42), maxLife: 0.42, color: packRGBA(255, 170, 80),
                                              size: 1.3, height: rng.f(0.15, 0.5), rise: rng.f(0.6, 1.3),
                                              maxAlpha: 1, fire: true))
                }
            } else {
                for _ in 0..<3 {
                    particles.append(Particle(pos: hit + SIMD2(rng.f(-0.15, 0.15), rng.f(-0.15, 0.15)),
                                              vel: SIMD2(rng.f(-0.9, 0.9), rng.f(-0.9, 0.9)) - dir * rng.f(0.4, 1.2),
                                              life: rng.f(0.25, 0.5), maxLife: 0.5, color: 0,
                                              size: rng.f(8, 13), height: rng.f(0.1, 0.5), rise: rng.f(0.5, 1.1),
                                              maxAlpha: 0.5, fire: true))
                }
            }
        }
        if particles.count > 700 { particles.removeFirst(particles.count - 700) }
    }

    private func autoSwitchIfEmpty() {
        // out of ammo → fall back to the best weapon that can fire
        let order: [WeaponKind] = [.plasma, .rocket, .flamethrower]
        for w in order where player.has(w) {
            let d = w.def
            if d.ammo == .none || player.ammo[d.ammo.rawValue] >= d.ammoPerShot { switchTo(w); return }
        }
    }

    private func hitscan(angle: Float, damage: Int, range: Float, audio: AudioEngine) {
        let dir = SIMD2<Float>(cos(angle), sin(angle))
        let wallDist = rayWallDistance(from: player.pos, dir: dir, maxDist: range)
        // nearest monster along the ray, before the wall
        var bestT = min(range, wallDist)
        var hitIndex = -1
        for (i, m) in monsters.enumerated() where m.alive {
            let rel = m.pos - player.pos
            let t = rel.x * dir.x + rel.y * dir.y            // distance along ray
            if t <= 0 || t > bestT { continue }
            let perp = abs(rel.x * dir.y - rel.y * dir.x)    // perpendicular distance
            if perp <= m.def.radius + 0.12 { bestT = t; hitIndex = i }
        }
        if hitIndex >= 0 {
            let hp = player.pos + dir * bestT
            spawnParticles(at: hp, n: 6, color: packRGBA(200, 30, 30), spread: 2.5, life: 0.35)
            damageMonster(hitIndex, damage, audio: audio)
        } else if wallDist < range {
            let hp = player.pos + dir * wallDist
            spawnParticles(at: hp, n: 4, color: packRGBA(220, 200, 140), spread: 1.8, life: 0.2)
        }
    }

    /// DDA the ray to the first wall; returns the perpendicular-free travel distance.
    private func rayWallDistance(from p: SIMD2<Float>, dir: SIMD2<Float>, maxDist: Float) -> Float {
        var mapX = Int(p.x), mapY = Int(p.y)
        let deltaX = dir.x == 0 ? 1e30 : abs(1 / dir.x)
        let deltaY = dir.y == 0 ? 1e30 : abs(1 / dir.y)
        var stepX = 0, stepY = 0
        var sideX: Float = 0, sideY: Float = 0
        if dir.x < 0 { stepX = -1; sideX = (p.x - Float(mapX)) * deltaX }
        else { stepX = 1; sideX = (Float(mapX) + 1 - p.x) * deltaX }
        if dir.y < 0 { stepY = -1; sideY = (p.y - Float(mapY)) * deltaY }
        else { stepY = 1; sideY = (Float(mapY) + 1 - p.y) * deltaY }
        var dist: Float = 0
        for _ in 0..<256 {
            if sideX < sideY { sideX += deltaX; mapX += stepX; dist = sideX - deltaX }
            else { sideY += deltaY; mapY += stepY; dist = sideY - deltaY }
            if dist > maxDist { return maxDist }
            if map.blocksSight(mapX, mapY) { return max(0, dist) }
        }
        return maxDist
    }

    private func lineOfSight(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Bool {
        let d = b - a
        let dist = vlen(d)
        if dist < 0.01 { return true }
        let step = SIMD2(d.x / dist, d.y / dist) * 0.18
        var p = a
        var travelled: Float = 0
        while travelled < dist {
            if map.blocksSight(Int(p.x), Int(p.y)) { return false }
            p += step; travelled += 0.18
        }
        return true
    }

    /// Smoke-test hook: deliver a typed hit without a projectile round-trip.
    func damageMonsterForTest(_ i: Int, _ amt: Int, audio: AudioEngine, kind: DamageKind) {
        damageMonster(i, amt, audio: audio, kind: kind)
    }

    private func damageMonster(_ i: Int, _ amt: Int, audio: AudioEngine, kind: DamageKind = .generic) {
        var m = monsters[i]
        if !m.alive { return }
        if m.kind == .queen {
            // any blow against the brood-mother rouses her whole brood to defend her
            for j in monsters.indices where monsters[j].kind == .alien && monsters[j].alive {
                monsters[j].awake = true; monsters[j].hasSeen = true; monsters[j].lastSeen = player.pos
            }
        }
        // explosives and fire DO hurt the Queen — they're heat — and they rock her
        // visibly, but they can never land the killing blow: her health floors at 1
        // until plasma finishes her. (Fire also finishes her CORPSE — see flameTick.)
        if m.kind == .queen && kind != .plasma {
            m.health = max(1, m.health - max(1, amt / 2))
            m.awake = true
            m.painFlash = 0.12
            if rng.chance(0.5) { m.state = .pain; m.stateTime = 0.2 }        // staggered by the blast
            audio.monsterPain(m.kind)
            monsters[i] = m
            if queenHintCD <= 0 { message("ONLY PLASMA WILL KILL THE QUEEN"); queenHintCD = 4 }
            return
        }
        m.health -= amt
        m.awake = true
        m.painFlash = 0.12
        if m.health <= 0 {
            m.state = .dying; m.stateTime = 0
            m.deathSeed = rng.f(0, 1)          // frozen now → a stable, varied death posture
            score += m.def.points
            killCount += 1
            spawnParticles(at: m.pos, n: 14, color: packRGBA(200, 20, 20), spread: 3.2, life: 0.5)
            if m.kind != .queen {                                          // the Queen's pool spreads when she LANDS
                addDecal(m.pos, radius: m.def.radius * 1.7 + 0.28, w: -0.85)   // blood pool at the kill site
            }
            // (the Queen's death WAIL is the sampled queen_death pool — a real
            //  recorded beast scream, long enough to ride the rear-and-convulse —
            //  played by audio.monsterDeath below like any other kill)
            audio.monsterDeath(m.kind)
            if kind == .explosive && m.kind == .alien {
                // OBLITERATED — the blast tears the drone apart: the death pose is
                // the gib burst (chunks flying), blood sheets out, entrails splatter
                // the room as persistent organic debris + satellite splats — and
                // there is no corpse left to burn; the way is already clear.
                m.gibbed = true
                m.burn = 1
                spawnParticles(at: m.pos, n: 150, color: packRGBA(160, 18, 16), spread: 7.5, life: 0.85)
                spawnParticles(at: m.pos, n: 70, color: packRGBA(96, 12, 12), spread: 5.0, life: 1.2)
                spawnParticles(at: m.pos, n: 44, color: packRGBA(200, 40, 30), spread: 8.5, life: 0.6)   // a brighter arterial spray
                for _ in 0..<22 {                              // heavier chunks arcing out
                    let a = rng.f(0, 6.2832), sp = rng.f(1.5, 5.5)
                    particles.append(Particle(pos: m.pos, vel: SIMD2(cos(a) * sp, sin(a) * sp),
                                              life: rng.f(0.5, 1.0), maxLife: 1.0, color: packRGBA(120, 16, 14),
                                              size: rng.f(3.5, 7.5), height: rng.f(0.2, 0.6), rise: rng.f(-0.9, -0.3),
                                              maxAlpha: 1))
                }
                for _ in 0..<12 {
                    let a = rng.f(0, 6.2832), r = rng.f(0.4, 2.4)
                    addDecal(m.pos + SIMD2(cos(a) * r, sin(a) * r), radius: rng.f(0.3, 0.75), w: -0.7)
                }
                // entrails as OFFAL DECALS (w < -2): chunky strewn-meat masks on
                // the deck — flat, so they read right at any scale (solids for
                // gore rendered as glossy furniture)
                addDecal(m.pos, radius: rng.f(0.7, 1.1), w: -2.85)
                for _ in 0..<9 {
                    let a = rng.f(0, 6.2832), r = rng.f(0.35, 1.7)
                    addDecal(m.pos + SIMD2(cos(a) * r, sin(a) * r), radius: rng.f(0.3, 0.6), w: -rng.f(2.5, 2.9))
                }
            } else if !m.gibbed && map.hazard[map.idx(Int(m.pos.x), Int(m.pos.y))] {
                // it died IN the acid: the pool takes the body — it sinks and
                // dissolves (no floating corpse, nothing to burn)
                m.dissolving = true
            } else if kind == .fire {
                // torched alive: the drone drops and IGNITES where it stands — it
                // burns straight down to char without a second flamethrower pass
                m.burn = max(m.burn, 0.06)
            }
            if m.kind == .queen { m.revive = queenReviveWindow }   // the BURN message lands with her impact
        } else {
            if rng.chance(m.def.painChance) { m.state = .pain; m.stateTime = 0.2 }
            audio.monsterPain(m.kind)
        }
        monsters[i] = m
    }

    private func wakeNearby(_ p: SIMD2<Float>, radius: Float) {
        for i in monsters.indices where !monsters[i].awake && monsters[i].alive {
            if vlen(monsters[i].pos - p) < radius { monsters[i].awake = true }
        }
    }

    /// The Queen breeds: about once a minute she births a fresh drone beside her,
    /// up to a live-brood cap. Thinning her drones only buys time — the swarm
    /// refills until she herself is dead and burned. (No breeding once she's down.)
    /// Drone vocal director — keeps the swarm AUDIBLE without the wall of noise that
    /// per-drone chatter made. ONE voice at a time, well spaced, in two registers:
    ///   • a CLEAR hiss when the nearest awake drone is close (it's on you), and
    ///   • a rare MUFFLED, echoing hiss when the nearest is far off (unseen, down the
    ///     dark) — a deliberate creep cue to keep you on edge.
    /// Attacks have their own hiss (monsterAttack); this is presence, not contact.
    private func droneProwl(dt: Float, audio: AudioEngine) {
        guard !player.dead else { return }
        var nd = Float.greatestFiniteMagnitude
        for m in monsters where m.kind == .alien && m.alive && m.awake {
            let d = vlen(m.pos - player.pos); if d < nd { nd = d }
        }
        let hearRange: Float = 22                                  // beyond this even an echo doesn't carry
        guard nd < hearRange else { droneVoxCD = max(droneVoxCD, 1.0); return }
        droneVoxCD -= dt
        if droneVoxCD > 0 { return }
        let nearRange: Float = 7                                   // within this they're upon you
        if nd < nearRange {
            audio.droneVox(distant: false); droneVoxCD = rng.f(2.4, 4.6)   // present, but not constant
        } else {
            audio.droneVox(distant: true);  droneVoxCD = rng.f(5.0, 9.5)   // a far, muffled cry now and then
        }
    }

    private func breedQueen(dt: Float, audio: AudioEngine) {
        guard let qi = monsters.firstIndex(where: { $0.kind == .queen && $0.alive }) else { return }
        queenBreedCD -= dt
        if queenBreedCD > 0 { return }
        queenBreedCD = queenBreedInterval
        let liveDrones = monsters.reduce(0) { $0 + (($1.kind == .alien && $1.alive) ? 1 : 0) }
        if liveDrones >= queenDroneCap { return }                 // brood already at capacity
        let q = monsters[qi]
        for _ in 0..<8 {                                          // find a walkable spot beside her
            let a = rng.f(0, 6.2832)
            let p = q.pos + SIMD2(cos(a), sin(a)) * (q.def.radius + 0.6)
            if canStand(p.x, p.y) {
                var d = Monster(kind: .alien, pos: p)
                d.awake = true; d.state = .chase; d.hasSeen = q.hasSeen; d.lastSeen = q.lastSeen
                monsters.append(d)
                monsterTotal += 1               // the HUD clear-meter counts births too
                spawnParticles(at: p, n: 10, color: packRGBA(150, 90, 60), spread: 2, life: 0.4)
                // No toast — a birth shouldn't announce itself across the level. The
                // wet birth-cry only carries if you're in the same room as her (she's
                // in line of sight); otherwise it happens silently, off in the dark.
                if lineOfSight(q.pos, player.pos) { audio.monsterSight(.alien) }
                return
            }
        }
    }

    // ── monsters ───────────────────────────────────────────────────────────

    private func updateMonsters(dt: Float, audio: AudioEngine) {
        let fast: Float = FeatureFlags.fastMonsters ? 1.6 : 1
        for i in monsters.indices {
            var m = monsters[i]
            // the walk cycle advances with DISTANCE COVERED (steerMove adds it), so
            // feet stop sliding and the stride matches travel; this is just a slow
            // idle breathe. The rooted Queen keeps full-rate animation — her idle
            // writhe IS her menace.
            m.animTime += dt * (m.kind == .queen ? 1.0 : 0.15)
            // ease the drone's rear-up: it rises onto its hind legs to strike, then drops back
            m.rearAmt += ((m.state == .attack ? 1 : 0) - m.rearAmt) * min(1, dt * 9)
            m.painFlash = max(0, m.painFlash - dt)
            if m.state == .dead {
                // ash & carcasses RESTING in a toxic pool are eaten by it too — not
                // only those that died in it. Big carcasses straddle several cells, so
                // test the whole FOOTPRINT (centre + a ring at the body radius), not
                // just the centre — one lying half in a pool still gets dissolved.
                if !m.dissolving && !m.gibbed {
                    // dissolve only when the corpse's BODY is genuinely OVER the acid —
                    // its footprint sampled at the collision radius (no padding, cardinals
                    // only) — never merely NEAR a pool. A drone thus needs its own cell (or
                    // a body-width overlap) to be hazard; a big carcass counts once its
                    // bulk laps into the pool.
                    let r = m.def.radius
                    let pts: [(Float, Float)] = [(0, 0), (r, 0), (-r, 0), (0, r), (0, -r)]
                    var inAcid = false
                    for (ox, oy) in pts {
                        let cx = Int(m.pos.x + ox), cy = Int(m.pos.y + oy)
                        if map.inBounds(cx, cy), map.hazard[map.idx(cx, cy)] { inAcid = true; break }
                    }
                    if inAcid { m.dissolving = true }
                }
                if m.dissolving {                                    // the pool eats the body
                    m.dissolveT += dt
                    if m.dissolveT >= 1.8 { m.burn = 1 }             // gone — nothing blocks, nothing to burn
                    else if rng.chance(0.5) {                        // caustic boil around the sinking corpse
                        particles.append(Particle(pos: m.pos + SIMD2(rng.f(-0.3, 0.3), rng.f(-0.3, 0.3)),
                                                  vel: SIMD2(rng.f(-0.05, 0.05), rng.f(-0.05, 0.05)),
                                                  life: rng.f(0.3, 0.7), maxLife: 0.7, color: packRGBA(120, 220, 90),
                                                  size: rng.f(2, 5), height: rng.f(0.0, 0.1), rise: rng.f(0.2, 0.5),
                                                  maxAlpha: 0.7))
                    }
                    monsters[i] = m; continue
                }
                if m.burn > 0 && m.burn < 1 {                       // a corpse set alight — the PYRE
                    // bigger mass burns LONGER: a drone is consumed in ~3.3 s, the
                    // Queen takes ~4.5 s of ferocious blaze before she's ash
                    let nb = min(1, m.burn + dt * (m.kind == .queen ? 0.22 : 0.30))
                    // the ash bed goes down EARLY, under cover of the blaze, so when
                    // the flames thin the remains are simply already there — there is
                    // never a visible corpse→ash swap
                    if m.burn < 0.5 && nb >= 0.5 {
                        addDecal(m.pos, radius: m.def.radius * 2.0 + 0.34, w: 0.95)   // scorch
                        addDecal(m.pos, radius: m.def.radius * 1.5 + 0.26, w: 2.9)    // smoldering ash + embers
                    }
                    if nb >= 1 {
                        m.smolder = 10
                        if m.kind == .queen { message("THE QUEEN IS ASHES — THE WAY IS OPEN") }
                    }
                    m.burn = nb
                    // emission follows a BELL over the burn: it catches, RAGES at the
                    // midpoint (a fireball that swallows the body while it burns away),
                    // then thins into smoke and embers over the revealed ash
                    // a WIDE peak (pow < 1 flattens the bell) + a guaranteed dense
                    // core right over the body through the whole consumption window,
                    // so the burn-away is never visible through a thin flame
                    let flare = powf(sinf(m.burn * .pi), 0.6)
                    let rad = m.def.radius
                    // the soft flame ORBS — the CPU pyre body. Retired when the GPU
                    // renders the pyre as a rising volumetric column (see
                    // gatherFireEmitters); the smoke + embers below stay on the CPU
                    // (they composite over/in-front-of the mesh corpse, which the
                    // kernel-drawn column cannot). Kept behind the flag to A/B.
                    if !FeatureFlags.gpuFire {
                        var nFire = Int(flare * 5); if rng.chance(0.4 + flare) { nFire += 1 }
                        for _ in 0..<nFire {
                            let jit = SIMD2<Float>(rng.f(-rad, rad), rng.f(-rad, rad)) * 0.9
                            particles.append(Particle(pos: m.pos + jit, vel: SIMD2(rng.f(-0.15, 0.15), rng.f(-0.15, 0.15)),
                                                      life: rng.f(0.3, 0.7), maxLife: 0.7, color: 0,
                                                      size: rng.f(10, 15 + 14 * flare), height: rng.f(0.02, 0.3 + 0.5 * flare),
                                                      rise: rng.f(0.5, 1.2), maxAlpha: 0.85, fire: true))
                        }
                        if m.burn > 0.3 && m.burn < 0.95 {
                            for _ in 0..<2 {
                                let jit = SIMD2<Float>(rng.f(-rad, rad), rng.f(-rad, rad)) * 0.4
                                particles.append(Particle(pos: m.pos + jit, vel: SIMD2(rng.f(-0.1, 0.1), rng.f(-0.1, 0.1)),
                                                          life: rng.f(0.35, 0.7), maxLife: 0.7, color: 0,
                                                          size: rng.f(14, 26), height: rng.f(0.05, 0.55),
                                                          rise: rng.f(0.4, 1.0), maxAlpha: 0.9, fire: true))
                            }
                        }
                    }
                    // a couple of extra embers when the GPU body carries the flame,
                    // so the near-body region reads live in front of the mesh corpse
                    if FeatureFlags.gpuFire && rng.chance(0.35 * (0.4 + flare)) {
                        particles.append(Particle(pos: m.pos + SIMD2(rng.f(-rad, rad), rng.f(-rad, rad)) * 0.6,
                                                  vel: SIMD2(rng.f(-0.4, 0.4), rng.f(-0.4, 0.4)),
                                                  life: rng.f(0.25, 0.6), maxLife: 0.6, color: packRGBA(255, 190, 90),
                                                  size: 1.4, height: rng.f(0.05, 0.45), rise: rng.f(0.9, 1.8), maxAlpha: 1, fire: true))
                    }
                    if rng.chance(0.25 + 0.5 * max(0, m.burn - 0.5)) {   // smoke thickens as the fire dies
                        particles.append(Particle(pos: m.pos + SIMD2(rng.f(-0.32, 0.32), rng.f(-0.32, 0.32)),
                                                  vel: SIMD2(rng.f(-0.08, 0.08), rng.f(-0.08, 0.08)),
                                                  life: rng.f(0.7, 1.3), maxLife: 1.3, color: packRGBA(70, 64, 60),
                                                  size: rng.f(11, 20), height: rng.f(0.25, 0.7), rise: rng.f(0.7, 1.3), maxAlpha: 0.4))
                    }
                    if rng.chance(0.12) {                        // embers popping off
                        particles.append(Particle(pos: m.pos + SIMD2(rng.f(-0.25, 0.25), rng.f(-0.25, 0.25)),
                                                  vel: SIMD2(rng.f(-0.4, 0.4), rng.f(-0.4, 0.4)),
                                                  life: rng.f(0.2, 0.5), maxLife: 0.5, color: packRGBA(255, 180, 80),
                                                  size: 1.4, height: rng.f(0.05, 0.4), rise: rng.f(0.8, 1.6), maxAlpha: 1, fire: true))
                    }
                    if particles.count > 700 { particles.removeFirst(particles.count - 700) }
                }
                if m.burn >= 1 && m.smolder > 0 {              // the ash smolders on
                    m.smolder = max(0, m.smolder - dt)
                    let inten = m.smolder / 10
                    if rng.chance(0.22 * inten) {
                        particles.append(Particle(pos: m.pos + SIMD2(rng.f(-0.3, 0.3), rng.f(-0.3, 0.3)),
                                                  vel: SIMD2(rng.f(-0.05, 0.05), rng.f(-0.05, 0.05)),
                                                  life: rng.f(0.9, 1.6), maxLife: 1.6, color: packRGBA(64, 60, 58),
                                                  size: rng.f(8, 14), height: rng.f(0.04, 0.2), rise: rng.f(0.5, 0.9),
                                                  maxAlpha: 0.3 * inten))
                    }
                    if rng.chance(0.05 * inten) {
                        particles.append(Particle(pos: m.pos + SIMD2(rng.f(-0.25, 0.25), rng.f(-0.25, 0.25)),
                                                  vel: SIMD2(rng.f(-0.3, 0.3), rng.f(-0.3, 0.3)),
                                                  life: rng.f(0.2, 0.45), maxLife: 0.45, color: packRGBA(255, 170, 70),
                                                  size: 1.3, height: rng.f(0.02, 0.15), rise: rng.f(0.6, 1.2),
                                                  maxAlpha: 1, fire: true))
                    }
                }
                // a downed Queen who hasn't been set alight claws her way back up
                if m.kind == .queen && m.burn <= 0 {
                    m.revive -= dt
                    if m.revive <= 0 {
                        m.state = .chase; m.health = m.def.maxHealth; m.awake = true; m.stateTime = 0
                        spawnParticles(at: m.pos, n: 16, color: packRGBA(120, 200, 90), spread: 2.5, life: 0.5)
                        message("THE QUEEN RISES — BURN HER THIS TIME!")
                        audio.monsterSight(.queen)
                    }
                }
                monsters[i] = m; continue
            }
            if m.state == .dying {
                let prev = m.stateTime
                m.stateTime += dt
                if m.kind == .queen {
                    // the moment the toppling brood-mother CRASHES to the deck:
                    // the floor jumps, dust sheets out, the pool spreads under her
                    let impact = World.queenDeathTime * World.queenImpactT
                    if prev < impact && m.stateTime >= impact {
                        impactShake = 1
                        audio.queenFall()                // a real recorded slam, not a synth pop
                        addDecal(m.pos, radius: m.def.radius * 1.7 + 0.28, w: -0.85)
                        for _ in 0..<26 {                    // dust billowing off the deck
                            let a = rng.f(0, 6.2832), r = rng.f(0.5, m.def.radius * 1.6)
                            particles.append(Particle(pos: m.pos + SIMD2(cos(a) * r, sin(a) * r),
                                                      vel: SIMD2(cos(a) * rng.f(0.3, 0.9), sin(a) * rng.f(0.3, 0.9)),
                                                      life: rng.f(0.6, 1.1), maxLife: 1.1, color: packRGBA(96, 88, 78),
                                                      size: rng.f(9, 16), height: rng.f(0.05, 0.3), rise: rng.f(0.4, 0.9),
                                                      maxAlpha: 0.45))
                        }
                        message("THE QUEEN IS DOWN — BURN THE BODY, NOW!")
                    }
                }
                if m.stateTime > (m.kind == .queen ? World.queenDeathTime : World.droneDeathTime) { m.state = .dead }
                monsters[i] = m; continue
            }
            let toP = player.pos - m.pos
            let dist = vlen(toP)
            let canSee = !player.dead && lineOfSight(m.pos, player.pos)
            if canSee { m.lastSeen = player.pos; m.hasSeen = true }   // remember where you saw them
            if !m.awake {
                if canSee && dist < m.def.sight {
                    m.awake = true
                    if m.kind == .queen { audio.queenSnarl() } else { audio.monsterSight(m.kind) }
                }
                monsters[i] = m; continue
            }
            if player.dead { monsters[i] = m; continue }
            m.attackCD = max(0, m.attackCD - dt)
            m.dir = atan2(toP.y, toP.x)

            if m.state == .pain {
                m.stateTime -= dt
                if m.stateTime <= 0 { m.state = .chase }
                monsters[i] = m; continue
            }

            let meleeRange = m.def.radius + 1.0        // reach for a lunge from the standoff distance (the attack stays visible)
            // melee on contact
            if dist <= meleeRange && m.attackCD <= 0 {
                damagePlayer(m.def.melee, audio: audio)
                if m.kind == .alien { audio.monsterAttack(.alien) }   // a hiss/snap as the drone strikes
                m.attackCD = m.def.attackInterval
                m.state = .attack; m.stateTime = 0.25
                monsters[i] = m; continue
            }
            // ranged: shoot only with a clear line, leading the player's motion
            if m.def.ranged && canSee && dist > meleeRange && dist < m.def.sight
                && m.attackCD <= 0 && rng.chance(0.5) {
                fireMonsterShot(&m, audio: audio)
                m.attackCD = m.def.attackInterval
                m.state = .attack; m.stateTime = 0.3
                monsters[i] = m; continue
            }
            // hold the brief attack pose, then resume manoeuvring
            if m.state == .attack && m.stateTime > 0 { m.stateTime -= dt; monsters[i] = m; continue }

            // ── manoeuvre ── drones are slow but relentless: they pursue, hunt
            // the last-seen spot when sight breaks, fan the approach and spread
            // off one another. No sprint — the dread is that they never stop.
            m.state = .chase
            if m.kind == .queen {
                // rooted brood-mother — she never advances; she lashes out when you're
                // in reach (her tentacles), and snarls ONLY when she has line of sight
                // to you (a random snarl from her pool, on a randomised cadence),
                // rousing her brood to defend her
                if canSee && dist < 8 {
                    m.snarlCD -= dt
                    if m.snarlCD <= 0 {
                        audio.queenSnarl(); m.snarlCD = rng.f(3.0, 5.5)
                        for j in monsters.indices where monsters[j].kind == .alien && monsters[j].alive && vlen(monsters[j].pos - m.pos) < 16 {
                            monsters[j].awake = true; monsters[j].hasSeen = true; monsters[j].lastSeen = player.pos
                        }
                    }
                }
            } else {
                let standoff = m.def.radius + 0.8
                if dist > standoff {
                    let desired = steerDir(m, index: i, canSee: canSee)
                    steerMove(&m, desired: desired, dt: dt, fast: fast, speedScale: 1)
                } else {
                    // hold at a readable distance and circle, so the lunge reads from a
                    // visible standoff instead of being pressed into the camera
                    let toP2 = player.pos - m.pos
                    let strafe = SIMD2(-toP2.y, toP2.x) * flankSign(i)
                    steerMove(&m, desired: strafe, dt: dt, fast: fast, speedScale: 0.4)
                }
            }
            monsters[i] = m
        }
    }

    /// Blended steering: pursue the player (or hunt the last-known spot once line
    /// of sight breaks), fan the approach sideways so they don't conga-line, then
    /// push off nearby allies so the pack spreads into a pincer.
    private func steerDir(_ m: Monster, index i: Int, canSee: Bool) -> SIMD2<Float> {
        let target = canSee ? player.pos : (m.hasSeen ? m.lastSeen : player.pos)
        var toT = target - m.pos
        var d = vlen(toT)
        if d < 0.001 { toT = SIMD2(cos(m.dir), sin(m.dir)); d = 1 }
        var dir = toT / d
        let side = SIMD2(-dir.y, dir.x) * flankSign(i)
        dir = simd_normalize(dir + side * 0.3 * min(1, d / 6))    // fan to spread the approach; fades to a straight lunge up close
        // drones prefer to pair up — but only as a soft drift while still approaching
        // from range AND a comrade is nearer than the prey. A lone drone, or any drone
        // once the player is close, commits to the hunt: pure predators, never hesitant.
        if m.kind == .alien {
            var nearest = -1; var nd = Float.greatestFiniteMagnitude; var liveDrones = 0
            for j in monsters.indices where j != i {
                let o = monsters[j]
                if o.kind != .alien || !o.alive { continue }
                liveDrones += 1
                let dl = vlen(o.pos - m.pos)
                if dl < nd { nd = dl; nearest = j }
            }
            let paired = nd < 4.0                                 // a comrade within a few cells
            // regroup only while well away from the prey AND a comrade is nearer than
            // it is — never turn away from a close target to chase a distant ally
            if !paired, liveDrones > 0, nearest >= 0, d > 8, nd < d {
                let toAlly = monsters[nearest].pos - m.pos
                let al = vlen(toAlly)
                if al > 0.001 { dir = simd_normalize(dir * 0.6 + (toAlly / al) * 0.6) }   // gentle regroup — keeps pursuing
            }
        }
        let out = dir + separation(i, m.pos, m.def.radius) * 1.5
        let l = vlen(out)
        return l > 0.001 ? out / l : SIMD2(cos(m.dir), sin(m.dir))
    }

    /// Repulsion from nearby awake allies (stronger the closer) — the anti-clump.
    private func separation(_ i: Int, _ pos: SIMD2<Float>, _ r: Float) -> SIMD2<Float> {
        var push = SIMD2<Float>.zero
        for j in monsters.indices where j != i {
            let o = monsters[j]
            if !o.awake || !o.alive { continue }
            let off = pos - o.pos
            let dl = vlen(off)
            let want = r + o.def.radius + 0.3
            if dl < want && dl > 0.001 { push += (off / dl) * ((want - dl) / want) }
        }
        return push
    }

    private func flankSign(_ i: Int) -> Float { (i & 1) == 0 ? 1 : -1 }

    /// Fire a monster projectile that leads the player's motion, with a small
    /// random spread (tighter for the Overlord) so shots feel aimed, not perfect.
    private func fireMonsterShot(_ m: inout Monster, audio: AudioEngine) {
        let pk = m.def.projectile
        let toP = player.pos - m.pos
        let tof = vlen(toP) / max(pk.speed, 0.1)                  // time of flight to the target
        let lead = player.pos + playerVel * tof - m.pos          // aim where they'll be
        let spread: Float = 0.12
        let ang = atan2(lead.y, lead.x) + rng.f(-spread, spread)
        let dirV = SIMD2(cos(ang), sin(ang))
        let origin = m.pos + dirV * (m.def.radius + 0.3)
        projectiles.append(Projectile(pos: origin, vel: dirV * pk.speed,
                                      kind: pk, damage: m.def.projDamage, fromPlayer: false, life: pk.lifetime))
        audio.enemyShot(m.kind)
    }

    /// Move along a desired direction with axis-separated wall sliding, plus a
    /// wall-follow fallback (slip 90° round a corner when blocked head-on) and
    /// door-opening — so they navigate the layout rather than grind into walls.
    private func steerMove(_ m: inout Monster, desired: SIMD2<Float>, dt: Float, fast: Float, speedScale: Float) {
        let dl = vlen(desired)
        if dl < 0.001 { return }
        let strideFrom = m.pos                       // walk cycle advances with ground actually covered
        defer { m.animTime += vlen(m.pos - strideFrom) * 1.8 }
        let dir = desired / dl
        let speed = m.def.speed * fast * speedScale * dt
        let r = m.def.radius
        m.wallHold = max(0, m.wallHold - dt)        // tick down the corner-follow commitment
        func free(_ x: Float, _ y: Float) -> Bool {
            if blockedBySolidProp(x, y, r) { return false }                  // furniture/drums are solid for aliens too
            if m.def.flying { return !map.blocksMovement(Int(x), Int(y)) }   // flyers ignore hazard, not walls
            // the pools burn THEM too: a drone treats acid as a wall and routes
            // around it — unless it's already standing in one (it must climb out)
            if map.inBounds(Int(x), Int(y)), map.hazard[map.idx(Int(x), Int(y))],
               !map.hazard[map.idx(Int(m.pos.x), Int(m.pos.y))] { return false }
            return !map.blocksMovement(Int(x - r), Int(y - r)) && !map.blocksMovement(Int(x + r), Int(y + r))
                && !map.blocksMovement(Int(x - r), Int(y + r)) && !map.blocksMovement(Int(x + r), Int(y - r))
        }
        var moved = false
        let nx = m.pos.x + dir.x * speed, ny = m.pos.y + dir.y * speed
        if free(nx, m.pos.y) { m.pos.x = nx; moved = true }
        if free(m.pos.x, ny) { m.pos.y = ny; moved = true }
        if !moved {
            // Wall-follow round a corner — but COMMIT to one slip side for a short
            // window instead of re-deciding every frame. Re-deciding let "which way
            // is clear" flip frame to frame, so the monster vibrated in place
            // ("skittish at corners"); committing makes it round the corner cleanly.
            let order: [Float] = m.wallHold > 0 ? [m.wallBias, -m.wallBias] : [1, -1]
            for s in order {
                let t = SIMD2(-dir.y * s, dir.x * s)
                let tx = m.pos.x + t.x * speed, ty = m.pos.y + t.y * speed
                var slipped = false
                if free(tx, m.pos.y) { m.pos.x = tx; slipped = true }
                if free(m.pos.x, ty) { m.pos.y = ty; slipped = true }
                if slipped { m.wallBias = s; m.wallHold = 0.5; moved = true; break }   // commit to the side that worked
            }
            let ax = Int(m.pos.x + dir.x * 0.8), ay = Int(m.pos.y + dir.y * 0.8)
            if map.isDoorCell(ax, ay), map.idx(ax, ay) != map.exitCell, map.idx(ax, ay) != map.entryCell,
               let dr = map.doors[map.idx(ax, ay)], dr.locked == nil {
                map.tryOpenDoor(ax, ay, keys: [])
            }
        }
    }

    // ── projectiles ──────────────────────────────────────────────────────────

    private func updateProjectiles(dt: Float, audio: AudioEngine) {
        var i = 0
        while i < projectiles.count {
            var p = projectiles[i]
            p.life -= dt
            var detonate = false
            // substep to avoid tunnelling
            let steps = max(1, Int((vlen(p.vel) * dt) / 0.2) + 1)
            let sub = dt / Float(steps)
            for _ in 0..<steps {
                p.pos += p.vel * sub
                if map.blocksMovement(Int(p.pos.x), Int(p.pos.y)) { detonate = true; break }
                // a drum in the way ruptures (a direct non-splash hit chips it; a
                // rocket's splash finishes it through explode()'s chain)
                var drumHit = false
                for di in drums.indices where drums[di].health > 0 {
                    if vlen(drums[di].pos - p.pos) < 0.5 {
                        if p.kind.splash == 0 { damageDrum(di, max(8, p.damage), audio: audio) }
                        drumHit = true; break
                    }
                }
                if drumHit { detonate = true; break }
                if p.fromPlayer {
                    var hit = -1
                    if p.targetIndex >= 0, p.targetIndex < monsters.count, monsters[p.targetIndex].alive {
                        // LOCKED bolt: it strikes only the reticle's target and passes
                        // by everything else — so a targeted drone is hit even with the
                        // Queen (radius 1.1 vs 0.4) right beside it. Lands once reached.
                        let t = p.targetIndex
                        if vlen(monsters[t].pos - p.pos) < monsters[t].def.radius + 0.18 { hit = t }
                    } else {
                        // unlocked (rocket, or plasma with no lock): the NEAREST monster
                        // centre in range — not merely the first in array order, which
                        // let the Queen's huge radius poach a bolt meant for a drone
                        var bd = Float.greatestFiniteMagnitude
                        for (mi, m) in monsters.enumerated() where m.alive {
                            let dc = vlen(m.pos - p.pos)
                            if dc < m.def.radius + 0.18, dc < bd { bd = dc; hit = mi }
                        }
                    }
                    if hit >= 0 {
                        if p.kind.splash == 0 { damageMonster(hit, p.damage, audio: audio, kind: p.kind == .plasma ? .plasma : .generic) }
                        detonate = true; break
                    }
                } else {
                    if vlen(player.pos - p.pos) < 0.32 {
                        if p.kind.splash == 0 { damagePlayer(p.damage, audio: audio) }
                        detonate = true; break
                    }
                }
            }
            if detonate || p.life <= 0 {
                if p.kind.splash > 0 { explode(at: p.pos, radius: p.kind.splash, damage: p.damage, fromPlayer: p.fromPlayer, audio: audio) }
                else {
                    // the bolt's death is its PAYOFF: a fat flash of its own
                    // colour + a brief light splashed on whatever it struck.
                    // At close range the bolt itself lives two frames — the
                    // impact bloom is what the eye actually reads.
                    spawnParticles(at: p.pos, n: 14, color: projColor(p.kind), spread: 3.5, life: 0.3)
                    particles.append(Particle(pos: p.pos, vel: .zero, life: 0.14, maxLife: 0.14,
                                              color: projColor(p.kind), size: 26, height: 0.5,
                                              rise: 0, maxAlpha: 0.9, fire: true))
                    blasts.append((p.pos, 0.16, p.kind == .plasma ? SIMD3(0.35, 0.85, 1.15) : SIMD3(1.0, 0.7, 0.3)))
                }
                projectiles.remove(at: i)
            } else {
                projectiles[i] = p; i += 1
            }
        }
    }

    private func explode(at pos: SIMD2<Float>, radius: Float, damage: Int, fromPlayer: Bool,
                         lethal: Bool = false, sooty: Bool = false, audio: AudioEngine) {
        // every part of the show scales with the blast's reach (1 = a rocket's
        // splash): particle count, throw speed, fireball size, light intensity
        let k = radius / 2.0
        spawnParticles(at: pos, n: Int(24 * k), color: packRGBA(255, 150, 60), spread: 4.5 * k, life: 0.5)
        // a real DETONATION: a fireball that blooms and rises, a smoke plume that
        // outlives it, and a flash of light thrown across the room (gatherDynLights)
        blasts.append((pos, 0.3, SIMD3(1.0, 0.62, 0.28) * k))
        // the GPU puff-fire renders the fireball (expands fast → sooty smoke); a fuel
        // drum burns sootier. Legacy soft-orb fireball kept only for the GPUFire A/B.
        if FeatureFlags.gpuFire {
            fireballs.append(Fireball(pos: pos, life: sooty ? 0.75 : 0.55, size: radius * 0.55, soot: sooty ? 1.0 : 0.55))
        } else {
            for _ in 0..<Int(14 * k) {
                let a = rng.f(0, 6.2832), sp = rng.f(0.8, 3.0) * k
                particles.append(Particle(pos: pos + SIMD2(rng.f(-0.25, 0.25), rng.f(-0.25, 0.25)),
                                          vel: SIMD2(cos(a) * sp, sin(a) * sp),
                                          life: rng.f(0.25, 0.55), maxLife: 0.55, color: 0,
                                          size: rng.f(12, 26) * (0.7 + 0.3 * k), height: rng.f(0.1, 0.6), rise: rng.f(0.4, 1.1),
                                          maxAlpha: 0.9, fire: true))
            }
        }
        for _ in 0..<Int(8 * k) {
            particles.append(Particle(pos: pos + SIMD2(rng.f(-0.3, 0.3), rng.f(-0.3, 0.3)),
                                      vel: SIMD2(rng.f(-0.2, 0.2), rng.f(-0.2, 0.2)),
                                      life: rng.f(1.0, 1.8), maxLife: 1.8, color: packRGBA(58, 54, 52),
                                      size: rng.f(14, 24) * (0.7 + 0.3 * k), height: rng.f(0.2, 0.7), rise: rng.f(0.8, 1.4),
                                      maxAlpha: 0.45))
        }
        if particles.count > 700 { particles.removeFirst(particles.count - 700) }
        // the concussion kicks the camera — hard at the epicentre, a ripple
        // across the room (same jolt channel as the Queen's landing)
        let dpc = vlen(player.pos - pos)
        impactShake = max(impactShake, min(1, max(0, 1 - dpc / (radius * 2.2)) * (0.35 + 0.45 * k)))
        audio.explosion()
        for i in monsters.indices where monsters[i].alive {
            let d = vlen(monsters[i].pos - pos)
            if d < radius {
                var dmg = Int(Float(damage) * (1 - d / radius))
                // ordnance is absolute: nothing caught inside the ring survives.
                // (Routed through damageMonster, so the Queen's plasma-only
                // floor still holds — she is rocked, not killed.)
                if lethal { dmg = max(dmg, 1000) }
                if dmg > 0 { damageMonster(i, dmg, audio: audio, kind: .explosive) }
            }
        }
        let dp = vlen(player.pos - pos)
        if dp < radius {
            let dmg = Int(Float(damage) * (1 - dp / radius) * 0.6)   // self-splash is reduced
            if dmg > 0 { damagePlayer(dmg, audio: audio) }
        }
        // chain reactions — drums rupture and mines cook off when the blast reaches
        // them. Both resolve on the NEXT tick (flag, don't recurse), so a row of
        // drums cascades cleanly without re-entrant explode() calls.
        for di in drums.indices where drums[di].health > 0 {
            if vlen(drums[di].pos - pos) < radius + 0.4 { drums[di].health = 0 }
        }
        for mi in deployedMines.indices where deployedMines[mi].arm <= 0.3 {
            if vlen(deployedMines[mi].pos - pos) < radius + 0.3 { deployedMines[mi].triggered = true }
        }
    }

    // ── resource props: fuel drums & deployed mines ──────────────────────────

    /// Hurt a drum; the rupture itself resolves in `updateDrums` next tick so the
    /// blast can chain through neighbouring drums without recursion.
    private func damageDrum(_ i: Int, _ amt: Int, audio: AudioEngine) {
        guard i >= 0 && i < drums.count, drums[i].health > 0 else { return }
        drums[i].health -= amt
        drums[i].hitFlash = 1
        if drums[i].health > 0 {
            spawnParticles(at: drums[i].pos, n: 3, color: packRGBA(222, 180, 120), spread: 1.4, life: 0.18)
        }
    }

    private func updateDrums(dt: Float, audio: AudioEngine) {
        var i = 0
        while i < drums.count {
            drums[i].hitFlash = max(0, drums[i].hitFlash - dt * 3)
            if drums[i].health <= 0 {
                ruptureDrum(drums[i], audio: audio)
                drums.remove(at: i)
            } else { i += 1 }
        }
    }

    /// A fierce fuel blast — bigger and fierier than a rocket, scaled by how much
    /// fuel was left in the drum (a drained drum is a feeble bomb). Cremates any
    /// corpse in reach, so a drum can finish a downed Queen.
    private func ruptureDrum(_ d: Drum, audio: AudioEngine) {
        let frac = Float(d.fuel) / Float(max(1, drumFuel))
        let radius = drumBlastRadius * (0.7 + 0.3 * frac)
        let dmg = Int(Float(drumBlastDamage) * (0.6 + 0.4 * frac))
        explode(at: d.pos, radius: radius, damage: dmg, fromPlayer: true, sooty: true, audio: audio)
        addDecal(d.pos, radius: radius * 0.8, w: 0.95)
        if !FeatureFlags.gpuFire {                                 // legacy soft-orb gout (GPU path uses the puff fireball)
            for _ in 0..<22 {
                let a = rng.f(0, 6.2832), s = rng.f(1.5, 5.5)
                particles.append(Particle(pos: d.pos, vel: SIMD2(cos(a) * s, sin(a) * s),
                                          life: rng.f(0.4, 0.95), maxLife: 0.95, color: 0,
                                          size: rng.f(11, 22), height: rng.f(0.1, 0.65), rise: rng.f(0.5, 1.3),
                                          maxAlpha: 0.9, fire: true))
            }
        }
        for j in monsters.indices where monsters[j].state == .dead {
            if vlen(monsters[j].pos - d.pos) < radius { monsters[j].burn = max(monsters[j].burn, 0.1) }
        }
    }

    private func updateMines(dt: Float, audio: AudioEngine) {
        var i = 0
        while i < deployedMines.count {
            deployedMines[i].arm -= dt
            deployedMines[i].blink += dt
            var fire = deployedMines[i].triggered
            if !fire && deployedMines[i].arm <= 0 {                 // a live mine an alien has crossed
                for m in monsters where m.alive {
                    if vlen(m.pos - deployedMines[i].pos) < mineTriggerRange + m.def.radius { fire = true; break }
                }
            }
            if fire {
                let mpos = deployedMines[i].pos
                explode(at: mpos, radius: mineBlastRadius, damage: mineBlastDamage,
                        fromPlayer: true, lethal: true, audio: audio)
                addDecal(mpos, radius: mineBlastRadius * 0.7, w: 0.95)   // a scorched ring where it sat
                for _ in 0..<26 {                        // shrapnel-fire: a low, fast, vicious ring
                    let a = rng.f(0, 6.2832), s = rng.f(2.5, 7.0)
                    particles.append(Particle(pos: mpos, vel: SIMD2(cos(a) * s, sin(a) * s),
                                              life: rng.f(0.3, 0.7), maxLife: 0.7, color: 0,
                                              size: rng.f(10, 20), height: rng.f(0.05, 0.35), rise: rng.f(0.2, 0.7),
                                              maxAlpha: 0.95, fire: true))
                }
                deployedMines.remove(at: i)
            } else { i += 1 }
        }
    }

    /// Stand at a drum (with room in the tank, fuel in the drum) → it pumps fuel
    /// into the flamethrower, draining the drum. A drained drum still ruptures.
    /// True if a player-sized body can stand somewhere inside the drum's
    /// refuel ring AND walk to that spot: the ring point alone is not enough —
    /// furniture can enclose a standable pocket no path reaches (a drum boxed
    /// in by bunks read as "inaccessible fuel" in playtest), so the whole
    /// approach LANE out to open floor must be standable too.
    /// A genuinely-open floor cell: walkable, all four orthogonal neighbours
    /// walkable, and clear of furniture — real room floor, not a nook.
    private func openFloorCell(_ cx: Int, _ cy: Int) -> Bool {
        guard map.inBounds(cx, cy), map.wall[map.idx(cx, cy)] == 0, !map.hazard[map.idx(cx, cy)] else { return false }
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            guard map.inBounds(cx + dx, cy + dy), map.wall[map.idx(cx + dx, cy + dy)] == 0 else { return false }
        }
        return !blockedBySolidProp(Float(cx) + 0.5, Float(cy) + 0.5, 0.26)
    }

    /// Can the marine actually walk up to this drum and refuel? True only if a
    /// stand point within refuel range connects, over continuously-standable
    /// floor, to the open room. The old check sampled a radial lane at coarse
    /// 0.35 steps and false-positived — a diagonal slipped BETWEEN two bed
    /// colliders at the sample points while the real path stayed blocked, so a
    /// boxed-in drum read as reachable and never got relocated. The fix: march from
    /// just outside the drum (0.72 — clear of its own solid collider, inside the
    /// 0.97 refuel reach) and only accept open floor found PAST the corner pocket
    /// (step >= 0.95). A walkable pocket right beside the drum — e.g. between two
    /// beds at right angles — no longer counts, so the lane must clear the pinch
    /// (where `canStand` breaks) before it can reach genuinely-open floor.
    func drumReachable(_ pos: SIMD2<Float>) -> Bool {
        for k in 0..<24 {
            let a = Float(k) / 24 * 2 * .pi
            let dir = SIMD2<Float>(cos(a), sin(a))
            var step: Float = 0.72
            while step <= 2.4 {
                let p = pos + dir * step
                if !canStand(p.x, p.y) { break }                                     // lane pinched/walled — try another heading
                if step >= 0.95 && openFloorCell(Int(p.x), Int(p.y)) { return true } // open floor reached past the corner, lane clear the whole way
                step += 0.18
            }
        }
        return false
    }

    private func relocateUnreachableDrums() {
        // Fuel-STORE drums are exempt: the chamber is an intentional stack —
        // you pump what you can reach from the doorway and shoot the rest.
        // Relocating them one by one emptied whole stores into nearby rooms.
        var unplaceable: [Int] = []
        for i in drums.indices
        where !map.fuelStore.contains(map.idx(Int(drums[i].pos.x), Int(drums[i].pos.y)))
              && !drumReachable(drums[i].pos) {
            let home = drums[i].pos
            var best: SIMD2<Float>?
            var bestD = Float.greatestFiniteMagnitude
            let cx0 = Int(home.x), cy0 = Int(home.y)
            for dy in -5...5 { for dx in -5...5 where !(dx == 0 && dy == 0) {
                let cx = cx0 + dx, cy = cy0 + dy
                guard map.inBounds(cx, cy) else { continue }
                let ci = map.idx(cx, cy)
                guard map.wall[ci] == 0, map.doors[ci] == nil, !map.hazard[ci] else { continue }
                let c = SIMD2<Float>(Float(cx) + 0.5, Float(cy) + 0.5)
                // never in or beside a doorway, and only on open room floor
                // (≥3 open orthogonal neighbours): a solid drum parked in a
                // chokepoint walls off everything behind it
                var openN = 0, doorAdj = false
                for (dx2, dy2) in [(1, 0), (-1, 0), (0, 1), (0, -1)] where map.inBounds(cx + dx2, cy + dy2) {
                    let ni = map.idx(cx + dx2, cy + dy2)
                    if map.doors[ni] != nil { doorAdj = true }
                    if map.wall[ni] == 0 { openN += 1 }
                }
                guard !doorAdj, openN >= 3 else { continue }
                // the drum's own footprint must clear walls, furniture and other drums
                let rr: Float = 0.47
                var clear = true
                for ox in [-rr, rr] { for oy in [-rr, rr] where map.blocksMovement(Int((c.x + ox).rounded(.down)), Int((c.y + oy).rounded(.down))) { clear = false } }
                if !clear || blockedBySolidProp(c.x, c.y, rr) { continue }
                if items.contains(where: { vlen($0.pos - c) < 0.9 }) { continue }   // never park a solid drum on a pickup (it would swallow/wall it off)
                guard drumReachable(c) else { continue }
                let d = vlen(c - home)
                if d < bestD { bestD = d; best = c }
            } }
            if let b = best { drums[i].pos = b } else { unplaceable.append(i) }
        }
        // A drum with nowhere reachable to go (a room packed with bunks) is pure
        // frustration — visible, promising fuel, never usable. Drop it rather
        // than leave it teasing. Rare; remove high-index-first to keep indices valid.
        for i in unplaceable.sorted(by: >) { drums.remove(at: i) }
    }

    private func refuelAtDrums(dt: Float, audio: AudioEngine) {
        var didRefuel = false
        let fi = AmmoType.fuel.rawValue, cap = AmmoType.fuel.capacity
        if player.ammo[fi] < cap {
            for i in drums.indices where drums[i].fuel > 0 {
                if vlen(drums[i].pos - player.pos) < drumRefuelRange + 0.42 {
                    let take = min(max(1, Int(drumRefuelRate * dt)), min(cap - player.ammo[fi], drums[i].fuel))
                    if take > 0 {
                        player.ammo[fi] += take; drums[i].fuel -= take
                        didRefuel = true
                    }
                    break                                           // one drum at a time
                }
            }
        }
        if didRefuel && !refueling { message("REFUELLING FROM THE DRUM"); audio.pickup(); player.pickupFlash = max(player.pickupFlash, 0.18) }   // one blink on plug-in, NOT a per-frame lift — a sustained flash made the whole screen visibly "dim" the instant the reserve ran dry
        refueling = didRefuel
    }

    /// Stand in a recharge socket → it pumps energy cells into the plasma rifle (up
    /// to its cap) from the socket's reserve, the cell glow pulsing as it works. The
    /// reserve is wired to the grid and trickles back up on its own, so a drained
    /// socket isn't dead — wait and it recovers. The marine's lifeline when the cells
    /// run out against a plasma-only Queen.
    private func rechargeAtSockets(dt: Float, audio: AudioEngine) {
        var didCharge = false
        var standingAtDry = false
        let ci = AmmoType.cells.rawValue, cap = AmmoType.cells.capacity
        for i in sockets.indices {
            sockets[i].pulse += dt
            // powered infrastructure: the reserve trickles back up to full on its own
            // (so a fully-drained grid recovers if the marine waits / fights elsewhere)
            if sockets[i].charge < sockets[i].maxCharge {
                sockets[i].regenAcc += socketRegenRate * dt
                if sockets[i].regenAcc >= 1 {
                    let add = Int(sockets[i].regenAcc)
                    sockets[i].charge = min(sockets[i].maxCharge, sockets[i].charge + add)
                    sockets[i].regenAcc -= Float(add)
                }
            }
            // a drained panel goes RED and holds — camping it doesn't sip the
            // trickle as it lands (that spammed the charging message + sound
            // every second). It re-arms once a TENTH of the reserve has been
            // rebuilt: ~12 s at the regen rate, a dose worth plugging into.
            if sockets[i].depleted {
                if sockets[i].charge >= max(1, sockets[i].maxCharge / 10) {
                    sockets[i].depleted = false
                } else {
                    if vlen(sockets[i].pos - player.pos) < socketRange && player.ammo[ci] < cap { standingAtDry = true }
                    continue
                }
            }
            if didCharge || sockets[i].charge <= 0 || player.ammo[ci] >= cap { continue }
            if vlen(sockets[i].pos - player.pos) < socketRange {
                let take = min(max(1, Int(socketRechargeRate * dt)), min(cap - player.ammo[ci], sockets[i].charge))
                if take > 0 {
                    player.ammo[ci] += take; sockets[i].charge -= take
                    didCharge = true
                    if sockets[i].charge <= 0 {
                        sockets[i].depleted = true
                        message("SOCKET DRAINED — RECHARGING")
                        audio.locked()
                    }
                }
            }
        }
        if didCharge && !recharging { message("RECHARGING PLASMA CELLS"); audio.pickup(); player.pickupFlash = max(player.pickupFlash, 0.18) }   // flash once on plug-in (see refuelAtDrums — sustained lift caused the drain "dim")
        recharging = didCharge || standingAtDry     // standing at a dry panel isn't a fresh plug-in
    }

    private func projColor(_ k: ProjectileKind) -> UInt32 {
        switch k {
        case .plasma: return packRGBA(120, 230, 255)
        case .rocket: return packRGBA(255, 150, 60)
        case .bolt: return packRGBA(255, 210, 90)
        case .fireball: return packRGBA(255, 120, 50)
        case .bfgBall: return packRGBA(120, 255, 150)
        }
    }

    // ── particles ──────────────────────────────────────────────────────────

    private func spawnParticles(at pos: SIMD2<Float>, n: Int, color: UInt32, spread: Float, life: Float) {
        for _ in 0..<n {
            let a = rng.f(0, 6.2832)
            let s = rng.f(0.3, spread)
            particles.append(Particle(pos: pos, vel: SIMD2(cos(a) * s, sin(a) * s),
                                      life: life * rng.f(0.6, 1), maxLife: life,
                                      color: color, size: rng.f(0.6, 1.6)))
        }
        if particles.count > 400 { particles.removeFirst(particles.count - 400) }
    }

    /// Moisture beading and dripping off the LIVE Queen — only when the player is
    /// close enough to read it. Cold wet droplets spawn at jaw/belly height and
    /// fall to the floor (Particle.rise < 0), so up close she visibly drips.
    private var queenDripCD: Float = 0
    private func emitQueenDrips(dt: Float) {
        queenDripCD -= dt
        if queenDripCD > 0 { return }
        guard let q = monsters.first(where: { $0.kind == .queen && $0.alive }) else { queenDripCD = 0.4; return }
        if vlen(q.pos - player.pos) > 6 { queenDripCD = 0.4; return }      // only bother up close
        queenDripCD = rng.f(0.1, 0.26)
        let jit = SIMD2<Float>(rng.f(-0.3, 0.3), rng.f(-0.3, 0.3))
        particles.append(Particle(pos: q.pos + jit, vel: SIMD2(rng.f(-0.02, 0.02), rng.f(-0.02, 0.02)),
                                  life: rng.f(0.55, 0.95), maxLife: 0.95,
                                  color: packRGBA(150, 172, 184), size: rng.f(0.5, 0.9),
                                  height: rng.f(0.5, 0.92), rise: -rng.f(1.1, 1.7), maxAlpha: 0.8))
        if particles.count > 400 { particles.removeFirst(particles.count - 400) }
    }

    private func updateParticles(dt: Float) {
        var i = 0
        while i < particles.count {
            particles[i].life -= dt
            if particles[i].life <= 0 { particles.remove(at: i); continue }
            particles[i].pos += particles[i].vel * dt
            particles[i].vel *= (1 - dt * 3)
            particles[i].height += particles[i].rise * dt
            i += 1
        }
    }

    // ── pickups & hazards ──────────────────────────────────────────────────

    private func pickups(audio: AudioEngine) {
        for i in items.indices where !items[i].taken {
            if vlen(player.pos - items[i].pos) < 0.5 {
                if applyPickup(items[i].kind, audio: audio) {
                    items[i].taken = true
                    message(items[i].kind.pickupMessage)
                    audio.pickup()
                }
            }
        }
    }

    private func applyPickup(_ k: ItemKind, audio: AudioEngine) -> Bool {
        switch k {
        case .stim:
            if player.health >= Player.maxHealth { return false }
            player.health = min(Player.maxHealth, player.health + ItemKind.stimHeal); player.pickupFlash = 0.5; return true
        case .medkit:
            if player.health >= Player.maxHealth { return false }
            player.health = min(Player.maxHealth, player.health + ItemKind.medkitHeal); player.pickupFlash = 0.6; return true
        case .armor:
            if player.armor >= ItemKind.armorRepairCap { return false }
            player.armor = min(ItemKind.armorRepairCap, player.armor + ItemKind.armorRepair); return true
        case .megaArmor:
            player.armor = Player.maxArmor; player.pickupFlash = 0.8; return true
        case .ammoCells: return player.giveAmmo(.cells, ItemKind.cellsPerPickup)
        case .ammoRockets: return player.giveAmmo(.rockets, ItemKind.rocketsPerPickup)
        case .ammoFuel: return player.giveAmmo(.fuel, ItemKind.fuelPerPickup)
        case .mineCrate:
            if player.mines >= Player.maxMines { return false }
            player.mines = min(Player.maxMines, player.mines + ItemKind.minesPerCrate)
            if !minesHintGiven { minesHintGiven = true; message("PRESS [G] TO DEPLOY A MINE") }
            return true
        case .weaponRocket: player.giveWeapon(.rocket); player.giveAmmo(.rockets, ItemKind.rocketsPerPickup); switchTo(.rocket); return true
        case .keyRed: player.keys.insert(.red); return true
        case .keyBlue: player.keys.insert(.blue); return true
        case .keyYellow: player.keys.insert(.yellow); return true
        }
    }

    private func hazardTick(dt: Float, audio: AudioEngine) {
        hazardTimer -= dt
        // inBounds guard: NoClip can put the marine outside the grid (see update()).
        let onHazard = map.inBounds(Int(player.pos.x), Int(player.pos.y))
            && map.hazard[map.idx(Int(player.pos.x), Int(player.pos.y))]
        if onHazard && hazardTimer <= 0 {
            hazardTimer = 0.45
            damagePlayer(5, audio: audio, armorBypass: true)
        }
        // the pools are as caustic to the swarm as to the marine
        monsterHazardTimer -= dt
        if monsterHazardTimer <= 0 {
            monsterHazardTimer = 0.45
            for i in monsters.indices where monsters[i].alive {
                if map.hazard[map.idx(Int(monsters[i].pos.x), Int(monsters[i].pos.y))] {
                    damageMonster(i, 5, audio: audio, kind: .generic)
                }
            }
        }
    }

    /// Find the steam vents for this level: every open cell facing a pipework
    /// wall is a vent. If the level runs light on pipework (the clean surface
    /// facility), top up from generic wall grilles so it still hisses.
    private func buildSteamVents() {
        func vent(_ x: Int, _ y: Int, _ dx: Int, _ dy: Int) -> SteamVent {
            SteamVent(pos: SIMD2(Float(x) + 0.5 + Float(dx) * 0.34, Float(y) + 0.5 + Float(dy) * 0.34),
                      dir: SIMD2(-Float(dx), -Float(dy)), phase: rng.f(0, 6.2832))
        }
        var generic: [(Int, Int, Int, Int)] = []
        for y in 0..<map.h { for x in 0..<map.w {
            if map.wall[map.idx(x, y)] != 0 { continue }
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let wx = x + dx, wy = y + dy
                guard map.inBounds(wx, wy) else { continue }
                let wid = map.wall[map.idx(wx, wy)]
                if wid == 0 { continue }
                if wid == WallTex.pipework.rawValue { steamVents.append(vent(x, y, dx, dy)) }
                else if generic.count < 240 { generic.append((x, y, dx, dy)) }
            }
        }}
        let target = 8
        while steamVents.count < target && !generic.isEmpty {
            let (x, y, dx, dy) = generic.remove(at: rng.i(0, generic.count - 1))
            steamVents.append(vent(x, y, dx, dy))
        }
        if steamVents.count > 40 {                                  // keep it believable, spread evenly
            let stride = steamVents.count / 40 + 1
            steamVents = steamVents.enumerated().filter { $0.offset % stride == 0 }.map { $0.element }
        }
        // give every vent a VISIBLE source: a floor grate it hisses up out of
        for v in steamVents {
            let gx = Int(v.pos.x), gy = Int(v.pos.y), gi = map.idx(gx, gy)
            if map.inBounds(gx, gy) && map.wall[gi] == 0 && !map.hazard[gi] {
                map.floor[gi] = FlatTex.grate.rawValue
            }
        }
    }

    /// Standing-water depth under a world position: the drowned lowest floor's
    /// global flood, or a puddle on the rock floors above it (water finds its way
    /// down — floor 7 pools, floor 8 drowns). 0 on dry deck. The puddle field is
    /// the same one the kernel draws, so you splash exactly where you see water.
    func waterDepth(at p: SIMD2<Float>) -> Float {
        let flood = Lighting.floodLevel(level: level)
        if flood > 0 { return flood }
        let cx = Int(p.x), cy = Int(p.y)
        guard map.inBounds(cx, cy), map.floor[map.idx(cx, cy)] == FlatTex.rock.rawValue else { return 0 }
        // a full puddle stands about half as deep as the drowned floor below —
        // ankle water, not the flood
        return Lighting.puddle(at: p + waterOff) * Lighting.floodLevel(level: level + 1) * 0.5
    }

    /// Ceiling-drip points for the deep rock floors, seated where the shared
    /// puddle field actually pools — every plink lands on water the renderer
    /// draws. `phase` is repurposed as the countdown to that site's next drip.
    private func buildDripSites() {
        var candidates: [SIMD2<Float>] = []
        for y in 0..<map.h { for x in 0..<map.w {
            let i = map.idx(x, y)
            guard map.wall[i] == 0, !map.hazard[i], map.doors[i] == nil,
                  map.floor[i] == FlatTex.rock.rawValue else { continue }
            let c = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
            if Lighting.puddle(at: c + waterOff) > 0.55 { candidates.append(c) }   // well inside a pool
        }}
        // spread them out: greedy min-distance pick so the plinks come from all
        // over the level, not one clustered corner
        let minGap: Float = 6, cap = 16
        while dripSites.count < cap && !candidates.isEmpty {
            let c = candidates.remove(at: rng.i(0, candidates.count - 1))
            if dripSites.allSatisfy({ vlen($0.pos - c) >= minGap }) {
                dripSites.append(SteamVent(pos: c, dir: .zero, phase: rng.f(0.5, 8)))
            }
        }
    }

    /// The deep floors drip: an intermittent plink from each site, panned to
    /// where it sits and louder the closer — the cavern keeps reminding you the
    /// rock above is wet. A fleck of spray marks the nearby ones.
    private func emitWaterDrips(dt: Float, audio: AudioEngine) {
        guard !dripSites.isEmpty else { return }
        let reach: Float = 16
        for i in dripSites.indices {
            dripSites[i].phase -= dt
            if dripSites[i].phase > 0 { continue }
            dripSites[i].phase = rng.f(2, 9)                     // its next plink
            let d = dripSites[i].pos - player.pos
            let dist = vlen(d)
            guard dist < reach else { continue }
            // the light-falloff shape (bright core, windowed to zero at reach)
            let dn = dist / reach
            let vol = (1 - dn * dn) / (1 + 5 * dn * dn)
            // pan by where it sits across the camera plane (right = (-sin, cos))
            let right = SIMD2(-sin(player.dir), cos(player.dir))
            let pan = dist > 0.001 ? (d.x * right.x + d.y * right.y) / dist : 0
            audio.drip(volume: vol, pan: pan * 0.8)
            if dist < 10 {                                       // visible plink: a fleck of spray off the pool
                particles.append(Particle(pos: dripSites[i].pos + SIMD2(rng.f(-0.1, 0.1), rng.f(-0.1, 0.1)),
                                          vel: .zero, life: 0.25, maxLife: 0.25,
                                          color: packRGBA(190, 210, 224), size: 3,
                                          height: 0.03, rise: 0.3, maxAlpha: 0.5))
            }
        }
    }

    /// Deterministic ~⅓ "shattered fixture" test — IDENTICAL uint maths to the
    /// kernel's `fixtureBusted`, so sparks fly from the very panels that render dead.
    private func fixtureBusted(_ x: Int, _ y: Int) -> Bool {
        var h = UInt32(truncatingIfNeeded: x) &* 374761393 &+ UInt32(truncatingIfNeeded: y) &* 668265263
        h = (h ^ (h >> 13)) &* 1274126177
        h = h ^ (h >> 16)
        return h % 100 < 32
    }

    /// Spark/smoke emitters at every shattered lit-panel / computer — on the wall
    /// face, spitting out into the room.
    private func buildSparkSites() {
        for y in 0..<map.h { for x in 0..<map.w {
            let wid = map.wall[map.idx(x, y)]
            guard wid == WallTex.litPanel.rawValue || wid == WallTex.computer.rawValue, fixtureBusted(x, y) else { continue }
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let ox = x + dx, oy = y + dy
                guard map.inBounds(ox, oy), map.wall[map.idx(ox, oy)] == 0 else { continue }
                sparkSites.append(SteamVent(pos: SIMD2(Float(x) + 0.5 + Float(dx) * 0.45, Float(y) + 0.5 + Float(dy) * 0.45),
                                            dir: SIMD2(Float(dx), Float(dy)), phase: rng.f(0, 6.2832)))
                break
            }
        }}
        if sparkSites.count > 60 {                                  // cap, spread evenly
            let stride = sparkSites.count / 60 + 1
            sparkSites = sparkSites.enumerated().filter { $0.offset % stride == 0 }.map { $0.element }
        }
    }

    /// Record a located damage mark (blood w<0 / scorch w>0). Capped so the GPU
    /// decal loop stays bounded; the oldest marks fall off first.
    private func addDecal(_ pos: SIMD2<Float>, radius: Float, w: Float) {
        decals.append(SIMD4(pos.x, pos.y, radius, w))
        if decals.count > 64 { decals.removeFirst(decals.count - 64) }
    }

    /// Rubble piles on the floor in front of each shattered fixture — physical
    /// debris from the same panels the kernel renders busted and the sparks fly
    /// from, so the wreckage is coherent across all three.
    private func buildDebris() {
        for y in 0..<map.h { for x in 0..<map.w {
            let wid = map.wall[map.idx(x, y)]
            guard wid == WallTex.litPanel.rawValue || wid == WallTex.computer.rawValue, fixtureBusted(x, y) else { continue }
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let ox = x + dx, oy = y + dy
                guard map.inBounds(ox, oy), map.wall[map.idx(ox, oy)] == 0, !map.hazard[map.idx(ox, oy)] else { continue }
                let pos = SIMD2<Float>(Float(x) + 0.5 + Float(dx) * 0.34, Float(y) + 0.5 + Float(dy) * 0.34)
                var s = UInt32(truncatingIfNeeded: x) &* 2654435761 &+ UInt32(truncatingIfNeeded: y) &* 40503
                s ^= s >> 15
                debris.append((pos, s | 1))
                break
            }
        }}
        if debris.count > 48 {                                      // cap, spread evenly
            let stride = debris.count / 48 + 1
            debris = debris.enumerated().filter { $0.offset % stride == 0 }.map { $0.element }
        }
    }

    /// Sparks spitting from shattered fixtures near the player (bursty), with the
    /// odd curl of smoke off a dead panel. Audio: a close proximity HUM (louder the
    /// nearer you stand, silent past ~2.6 m), and per shower a BUZZ just before, then
    /// the sparks + a CRACKLE as they emit.
    private func emitSparks(dt: Float, audio: AudioEngine) {
        // ── every frame: proximity hum from the nearest VISIBLE fault. LOS-gated
        // (a fault behind a wall stays quiet), on a smoothstep distance curve, and
        // EASED toward the target so it swells with the approach + fades as you
        // leave — no sudden cut-in when a fault first comes into view ──
        var target: Float = 0
        for v in sparkSites {
            let d = vlen(v.pos - player.pos)
            if d > faultHumRange { continue }
            if !lineOfSight(player.pos, v.pos) { continue }
            let t = 1 - d / faultHumRange
            target = max(target, t * t * (3 - 2 * t))       // smoothstep: gentlest at the edge, loudest alongside
        }
        faultHumLevel += (target - faultHumLevel) * min(1, dt / faultHumSmooth)
        audio.faultHum(faultHumLevel)
        // ── every frame: resolve charging showers → emit sparks + crackle ──
        var k = 0
        while k < sparkCharge.count {
            sparkCharge[k].t -= dt
            if sparkCharge[k].t <= 0 {
                let v = sparkSites[sparkCharge[k].site]
                emitSparkShower(v)                                  // the sparks fly…
                audio.faultCrackle(faultAudible(v.pos))             // …and crackle as they do (LOS-gated)
                sparkCharge.remove(at: k)
            } else { k += 1 }
        }
        // ── throttled: roll each nearby fault for a new shower ──
        sparkTimer -= dt
        if sparkTimer > 0 { return }
        sparkTimer = 0.07
        let pr: Float = 11
        for (i, v) in sparkSites.enumerated() {
            if abs(v.pos.x - player.pos.x) > pr || abs(v.pos.y - player.pos.y) > pr { continue }
            // A faulty panel/light doesn't trickle constantly — it sits dark, then
            // every few seconds throws a SHOWER. Charge it now (BUZZ), fire a beat
            // later (sparks + CRACKLE) — unless it's already charging.
            if rng.f(0, 1) < 0.045 && !sparkCharge.contains(where: { $0.site == i }) {
                audio.faultBuzz(faultAudible(v.pos))                // buzz only when the fault is in sight
                sparkCharge.append((site: i, t: faultChargeLead))
            }
            if rng.f(0, 1) < 0.02 {                                 // occasional smoke wisp off a dead panel
                particles.append(Particle(pos: v.pos, vel: v.dir * 0.1, life: rng.f(0.9, 1.5), maxLife: 1.5,
                                          color: packRGBA(58, 56, 60), size: rng.f(8, 13), height: 0.62,
                                          rise: rng.f(0.4, 0.8), maxAlpha: 0.28))
            }
        }
    }

    /// Distance attenuation for a fault's spark audio (buzz/crackle): 1 at the
    /// panel, fading to 0 by `faultSparkRange`.
    private func faultVol(_ pos: SIMD2<Float>) -> Float {
        max(0, 1 - vlen(pos - player.pos) / faultSparkRange)
    }

    /// As `faultVol`, but silent unless the fault is in the player's line of sight —
    /// no crackle heard through a wall.
    private func faultAudible(_ pos: SIMD2<Float>) -> Float {
        let v = faultVol(pos)
        return v > 0 && lineOfSight(player.pos, pos) ? v : 0
    }

    /// The visible spark shower — a big, unmistakable burst of glints from a fault.
    private func emitSparkShower(_ v: SteamVent) {
        for _ in 0..<rng.i(20, 35) {
            particles.append(Particle(pos: v.pos + SIMD2(rng.f(-0.06, 0.06), rng.f(-0.06, 0.06)),
                                      vel: v.dir * rng.f(0.6, 2.8) + SIMD2(rng.f(-1.6, 1.6), rng.f(-1.6, 1.6)),
                                      life: rng.f(0.25, 0.75), maxLife: 0.75, color: packRGBA(255, 246, 214),
                                      size: rng.f(0.9, 2.0), height: rng.f(0.40, 0.82), rise: rng.f(-3.0, -0.5),
                                      maxAlpha: 1.0, fire: true))        // sharp, energetic glints spraying out
        }
    }

    /// Steam: wisps off nearby liquid pools + jets from the plant's pipework vents.
    private func emitSteam(dt: Float) {
        steamTimer -= dt
        if steamTimer > 0 { return }
        steamTimer = 0.09
        let cxp = Int(player.pos.x), cyp = Int(player.pos.y), R = 9
        var made = 0
        for _ in 0..<8 {
            let cx = cxp + rng.i(-R, R), cy = cyp + rng.i(-R, R)
            if !map.inBounds(cx, cy) { continue }
            let i = map.idx(cx, cy)
            if !map.hazard[i] { continue }
            let nuke = map.floor[i] == FlatTex.nukage.rawValue
            let col = nuke ? packRGBA(168, 228, 172) : packRGBA(154, 124, 122)
            particles.append(Particle(pos: SIMD2(Float(cx) + rng.f(0.2, 0.8), Float(cy) + rng.f(0.2, 0.8)),
                                      vel: SIMD2(rng.f(-0.08, 0.08), rng.f(-0.08, 0.08)),
                                      life: rng.f(1.3, 2.2), maxLife: 2.2, color: col, size: rng.f(5, 9),
                                      height: 0.05, rise: rng.f(0.4, 0.75), maxAlpha: 0.34))
            made += 1
            if made >= 3 { break }
        }
        // pressurised vents — jet out of the pipework near the player, then rise
        let pr = Float(R)
        var vmade = 0
        for v in steamVents {
            if vmade >= 6 { break }
            if abs(v.pos.x - player.pos.x) > pr || abs(v.pos.y - player.pos.y) > pr { continue }
            if sinf(elapsed * 1.4 + v.phase) < 0.1 { continue }     // intermittent hiss (mostly on)
            let base = SIMD2(Float(Int(v.pos.x)) + 0.5, Float(Int(v.pos.y)) + 0.5)   // the grate centre
            particles.append(Particle(pos: base + SIMD2(rng.f(-0.18, 0.18), rng.f(-0.18, 0.18)),
                                      vel: v.dir * rng.f(0.05, 0.16) + SIMD2(rng.f(-0.06, 0.06), rng.f(-0.06, 0.06)),
                                      life: rng.f(1.1, 1.9), maxLife: 1.9, color: packRGBA(202, 206, 212),
                                      size: rng.f(6, 11), height: rng.f(0.05, 0.35), rise: rng.f(0.7, 1.15), maxAlpha: 0.4))
            vmade += 1
        }
        if particles.count > 400 { particles.removeFirst(particles.count - 400) }
    }

    func damagePlayer(_ amt: Int, audio: AudioEngine, armorBypass: Bool = false) {
        if FeatureFlags.godMode || player.dead { return }
        var dmg = amt
        if !armorBypass && player.armor > 0 {
            let absorbed = min(player.armor, amt / 3)
            player.armor -= absorbed
            dmg = amt - absorbed
        }
        player.health -= dmg
        combatHeat = 1                                    // a hit spikes the music to full
        player.hurtFlash = 1
        player.facePain = 0.5
        if player.health <= 0 {
            player.health = 0
            player.dead = true
            audio.playerDeath()
        } else {
            audio.playerPain()
        }
    }

    /// The live signal that drives the reactive ambient bed (all 0…1). The swarm's
    /// proximity is the main lever — the mix thickens as drones close in — while
    /// the Queen radiates dread from further out and recent combat lifts it briefly.
    func audioCue() -> (threat: Float, queen: Float, health: Float, combat: Float) {
        var threat: Float = 0, queen: Float = 0, pressing = 0
        for m in monsters where m.alive && m.awake {
            let d = vlen(m.pos - player.pos)
            if m.kind == .queen {
                queen = max(queen, max(0, 1 - d / 18))            // her dread reaches far
            } else {
                let prox = max(0, 1 - d / 10)
                threat = max(threat, prox)
                if prox > 0.05 { pressing += 1 }
            }
        }
        threat = min(1, threat + 0.10 * Float(max(0, pressing - 1)))   // a pack presses harder than one
        let health = Float(max(0, player.health)) / Float(Player.maxHealth)
        return (threat, queen, health, min(1, combatHeat))
    }
}
