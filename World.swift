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
}

final class World {
    let map: GameMap
    var player: Player
    var monsters: [Monster] = []
    var items: [Item] = []
    var projectiles: [Projectile] = []
    var particles: [Particle] = []

    var score = 0
    let level: Int
    let colonyIndex: Int
    let colonyName: String
    var elapsed: Float = 0
    var combatHeat: Float = 0      // 0…1 recent weapon-fire / damage; feeds the reactive audio bed, decays each frame

    var killCount = 0
    let monsterTotal: Int
    var secretsFound = 0
    let secretTotal: Int

    var levelComplete = false
    var messages: [(text: String, time: Float)] = []

    private var rng: Rng
    private var hazardTimer: Float = 0
    private var steamTimer: Float = 0
    private var sparkTimer: Float = 0
    // ── the Queen ──
    private var queenBreedCD: Float = 60         // seconds to her next spawn
    private var queenHintCD: Float = 0           // throttle for the "plasma only" hint
    private var droneVoxCD: Float = 1.2           // throttle for the drone vocal director (one voice at a time: near hiss vs far echo)
    private let queenBreedInterval: Float = 60   // she births a drone about once a minute
    private let queenReviveWindow: Float = 8     // a downed Queen has this long to be burned before she rises
    private let queenDroneCap = 14               // most simultaneous live drones she'll grow the brood to
    var steamVents: [SteamVent] = []   // pipework/grille vents (built per level)
    var sparkSites: [SteamVent] = []   // busted-fixture spark/smoke emitters (built per level)
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
    private let mineBlastRadius: Float = 2.4
    private let mineBlastDamage = 85
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

    init(level: Int, colonyIndex: Int, seed: UInt64) {
        self.level = level
        self.colonyIndex = colonyIndex
        let gen = MapGen.generate(level: level, colonyIndex: colonyIndex, seed: seed)
        self.map = gen.map
        self.colonyName = gen.colonyName
        self.secretTotal = gen.secretCount
        self.rng = Rng(seed: seed ^ 0xABCD_1234)
        self.player = Player(at: gen.map.playerStart, dir: gen.map.playerDir)
        self.lastPlayerPos = gen.map.playerStart
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
        buildSteamVents()
        buildSparkSites()
        buildDebris()
        if FeatureFlags.allWeapons { grantAllWeapons() }
        message("RETAKE \(colonyName) — FLOOR \(Progression.floorInBuilding(level))")
    }

    private func grantAllWeapons() {
        for w in WeaponKind.allCases { player.weapons[w.rawValue] = true }
        player.ammo[AmmoType.cells.rawValue] = 400
        player.ammo[AmmoType.rockets.rawValue] = 50
        player.ammo[AmmoType.fuel.rawValue] = 300
        player.mines = player.maxMines
    }

    func message(_ s: String) {
        messages.append((s, 3.0))
        if messages.count > 4 { messages.removeFirst(messages.count - 4) }
    }

    // ── main update ──────────────────────────────────────────────────────────

    func update(dt: Float, input: InputState, audio: AudioEngine) {
        elapsed += dt
        combatHeat = max(0, combatHeat - dt * 0.7)        // combat tension cools over ~1.5 s
        for i in messages.indices { messages[i].time -= dt }
        messages.removeAll { $0.time <= 0 }

        if player.dead {
            updateProjectiles(dt: dt, audio: audio)
            updateParticles(dt: dt)
            updateMonsters(dt: dt, audio: audio)
            return
        }

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
            let flood = Lighting.floodLevel(level: level)
            while stepDist >= stride {                            // on the flooded lower floors (7 & 8) it splashes
                stepDist -= stride
                stepFoot ^= 1
                if flood > 0 { audio.wade(flood, foot: stepFoot) }   // alternate left/right, louder the deeper the water
            }
        }
        // smoothed player velocity for monster lead-aim (clamped to a sane top speed)
        var pv = (player.pos - lastPlayerPos) / max(dt, 1e-4)
        if vlen(pv) > 6 { pv = pv / vlen(pv) * 6 }
        playerVel = playerVel * 0.6 + pv * 0.4
        lastPlayerPos = player.pos
        handleUse(input: input, audio: audio)
        handleMineDeploy(input: input, audio: audio)
        handleFire(dt: dt, input: input, audio: audio)

        // player timers
        player.fireCD = max(0, player.fireCD - dt)
        player.muzzle = max(0, player.muzzle - dt)
        player.fireAnim = max(0, player.fireAnim - dt)
        player.switchAnim = max(0, player.switchAnim - dt)
        player.hurtFlash = max(0, player.hurtFlash - dt * 2)
        player.pickupFlash = max(0, player.pickupFlash - dt * 2)
        player.facePain = max(0, player.facePain - dt)
        if player.berserk > 0 { player.berserk = max(0, player.berserk - dt) }
        queenHintCD = max(0, queenHintCD - dt)

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
        map.update(dt: dt, occupied: occupied)

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
        emitSteam(dt: dt)
        emitQueenDrips(dt: dt)
        emitSparks(dt: dt)
        map.visited[map.idx(Int(player.pos.x), Int(player.pos.y))] = true
    }

    // ── movement ───────────────────────────────────────────────────────────

    private func turn(dt: Float, input: InputState) {
        let base: Float = 2.7 * GameSettings.shared.turnSpeed
        var d: Float = 0
        if input.turnLeft { d -= base }
        if input.turnRight { d += base }
        d += input.lookX * base
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
        // probe a couple of points ahead
        let dx = cos(player.dir), dy = sin(player.dir)
        for reach: Float in [0.7, 1.2, 1.7] {
            let cx = Int(player.pos.x + dx * reach), cy = Int(player.pos.y + dy * reach)
            guard map.inBounds(cx, cy) else { continue }
            let i = map.idx(cx, cy)
            if i == map.exitCell {
                completeLevel(audio: audio); return
            }
            if map.doors[i] != nil {
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
                completeLevel(audio: audio); return
            }
        }
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

    /// The level objective: no Queen remains that isn't a fully-burned corpse —
    /// she must be killed (plasma) AND torched (fire). Every level seeds one.
    var queenDefeated: Bool {
        !monsters.contains { $0.kind == .queen && !($0.state == .dead && $0.burn >= 1) }
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

    private func handleFire(dt: Float, input: InputState, audio: AudioEngine) {
        // The flamethrower roars as one continuous loop while the trigger's held and
        // there's fuel — drive it here every frame (edge-detected) so it tracks the
        // trigger, rather than stuttering as randomly-retriggered one-shots.
        let fdef = player.current.def
        let flaming = input.fire && player.current == .flamethrower && !player.dead
            && (fdef.ammo == .none || player.ammo[fdef.ammo.rawValue] >= fdef.ammoPerShot)
        audio.flame(flaming)
        guard input.fire, player.fireCD <= 0 else { return }
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
            let dx = cos(player.dir), dy = sin(player.dir)
            let origin = SIMD2<Float>(player.pos.x + dx * 0.4, player.pos.y + dy * 0.4)
            projectiles.append(Projectile(pos: origin, vel: SIMD2(dx, dy) * pk.speed,
                                          kind: pk, damage: def.damage, fromPlayer: true, life: pk.lifetime))
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
            if monsters[i].alive { damageMonster(i, def.damage, audio: audio, kind: .fire) }
            else if monsters[i].state == .dead { monsters[i].burn = max(monsters[i].burn, 0.06) }   // light it up (and commits a downed Queen to ash)
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
        // a coherent JET of flame — overlapping fire particles seeded along the WHOLE
        // aim, from the nozzle out to the cone's reach: tight + white-hot at the
        // nozzle, broadening and cooling downrange. Re-seeded densely every tick so it
        // reads as one continuous stream, not the scattered puffs it threw before.
        for _ in 0..<18 {
            let t = rng.f(0, 1)                                     // fraction along the jet (0 nozzle … 1 tip)
            let widen = def.spread * (0.15 + 0.85 * t)             // narrow at the nozzle, opening downrange
            let a = player.dir + rng.f(-widen, widen)
            let fdir = SIMD2<Float>(cos(a), sin(a))
            let dist = 0.3 + t * (def.range - 0.3)
            let jit: Float = 0.03 + 0.06 * t
            let o = player.pos + fdir * dist + SIMD2(rng.f(-jit, jit), rng.f(-jit, jit))
            particles.append(Particle(pos: o,
                                      vel: fdir * (5.0 - 3.0 * t),                  // fast at the nozzle, easing downrange
                                      life: rng.f(0.10, 0.22), maxLife: 0.22, color: 0,
                                      size: 6 + 16 * t, height: 0.30 + 0.34 * t, rise: 0.3 + 0.5 * t,
                                      maxAlpha: 0.9, fire: true))
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
            score += m.def.points
            killCount += 1
            spawnParticles(at: m.pos, n: 14, color: packRGBA(200, 20, 20), spread: 3.2, life: 0.5)
            addDecal(m.pos, radius: m.def.radius * 1.7 + 0.28, w: -0.85)   // blood pool at the kill site
            audio.monsterDeath(m.kind)
            if m.kind == .queen { m.revive = queenReviveWindow; message("THE QUEEN IS DOWN — BURN THE BODY, NOW!") }
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
            m.animTime += dt
            m.painFlash = max(0, m.painFlash - dt)
            if m.state == .dead {
                if m.burn > 0 && m.burn < 1 {                       // a corpse set alight, burning down
                    let nb = min(1, m.burn + dt * 0.5)
                    if nb >= 1 {
                        addDecal(m.pos, radius: m.def.radius * 2.0 + 0.34, w: 0.95)   // scorch where it burned out
                        if m.kind == .queen { message("THE QUEEN IS ASHES — THE WAY IS OPEN") }
                    }
                    m.burn = nb
                    if rng.chance(0.7) {
                        let jit = SIMD2<Float>(rng.f(-0.32, 0.32), rng.f(-0.32, 0.32))
                        if rng.f(0, 1) < 0.4 {                       // dark smoke curling up
                            particles.append(Particle(pos: m.pos + jit, vel: SIMD2(rng.f(-0.08, 0.08), rng.f(-0.08, 0.08)),
                                                      life: rng.f(0.7, 1.2), maxLife: 1.2, color: packRGBA(70, 64, 60),
                                                      size: rng.f(11, 19), height: rng.f(0.25, 0.7), rise: rng.f(0.7, 1.3), maxAlpha: 0.4))
                        } else {                                     // flame licking off the corpse
                            particles.append(Particle(pos: m.pos + jit, vel: SIMD2(rng.f(-0.1, 0.1), rng.f(-0.1, 0.1)),
                                                      life: rng.f(0.35, 0.75), maxLife: 0.75, color: 0,
                                                      size: rng.f(9, 15), height: rng.f(0.05, 0.45), rise: rng.f(0.6, 1.1),
                                                      maxAlpha: 0.8, fire: true))
                        }
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
                m.stateTime += dt
                if m.stateTime > 0.45 { m.state = .dead }
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
        let dir = desired / dl
        let speed = m.def.speed * fast * speedScale * dt
        let r = m.def.radius
        m.wallHold = max(0, m.wallHold - dt)        // tick down the corner-follow commitment
        func free(_ x: Float, _ y: Float) -> Bool {
            if blockedBySolidProp(x, y, r) { return false }                  // furniture/drums are solid for aliens too
            if m.def.flying { return !map.blocksMovement(Int(x), Int(y)) }   // flyers ignore hazard, not walls
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
            if map.isDoorCell(ax, ay), let dr = map.doors[map.idx(ax, ay)], dr.locked == nil {
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
                    for (mi, m) in monsters.enumerated() where m.alive {
                        if vlen(m.pos - p.pos) < m.def.radius + 0.18 { hit = mi; break }
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
                else { spawnParticles(at: p.pos, n: 5, color: projColor(p.kind), spread: 2, life: 0.25) }
                projectiles.remove(at: i)
            } else {
                projectiles[i] = p; i += 1
            }
        }
    }

    private func explode(at pos: SIMD2<Float>, radius: Float, damage: Int, fromPlayer: Bool, audio: AudioEngine) {
        spawnParticles(at: pos, n: 24, color: packRGBA(255, 150, 60), spread: 4.5, life: 0.5)
        audio.explosion()
        for i in monsters.indices where monsters[i].alive {
            let d = vlen(monsters[i].pos - pos)
            if d < radius {
                let dmg = Int(Float(damage) * (1 - d / radius))
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
        explode(at: d.pos, radius: radius, damage: dmg, fromPlayer: true, audio: audio)
        addDecal(d.pos, radius: radius * 0.8, w: 0.95)
        for _ in 0..<22 {                                          // a gout of flame
            let a = rng.f(0, 6.2832), s = rng.f(1.5, 5.5)
            particles.append(Particle(pos: d.pos, vel: SIMD2(cos(a) * s, sin(a) * s),
                                      life: rng.f(0.4, 0.95), maxLife: 0.95, color: 0,
                                      size: rng.f(11, 22), height: rng.f(0.1, 0.65), rise: rng.f(0.5, 1.3),
                                      maxAlpha: 0.9, fire: true))
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
                explode(at: deployedMines[i].pos, radius: mineBlastRadius, damage: mineBlastDamage,
                        fromPlayer: true, audio: audio)
                deployedMines.remove(at: i)
            } else { i += 1 }
        }
    }

    /// Stand at a drum (with room in the tank, fuel in the drum) → it pumps fuel
    /// into the flamethrower, draining the drum. A drained drum still ruptures.
    private func refuelAtDrums(dt: Float, audio: AudioEngine) {
        var didRefuel = false
        let fi = AmmoType.fuel.rawValue, cap = AmmoType.fuel.capacity
        if player.ammo[fi] < cap {
            for i in drums.indices where drums[i].fuel > 0 {
                if vlen(drums[i].pos - player.pos) < drumRefuelRange + 0.42 {
                    let take = min(max(1, Int(drumRefuelRate * dt)), min(cap - player.ammo[fi], drums[i].fuel))
                    if take > 0 {
                        player.ammo[fi] += take; drums[i].fuel -= take
                        player.pickupFlash = max(player.pickupFlash, 0.18)
                        didRefuel = true
                    }
                    break                                           // one drum at a time
                }
            }
        }
        if didRefuel && !refueling { message("REFUELLING FROM THE DRUM"); audio.pickup() }
        refueling = didRefuel
    }

    /// Stand in a recharge socket → it pumps energy cells into the plasma rifle (up
    /// to its cap) from the socket's reserve, the cell glow pulsing as it works. The
    /// reserve is wired to the grid and trickles back up on its own, so a drained
    /// socket isn't dead — wait and it recovers. The marine's lifeline when the cells
    /// run out against a plasma-only Queen.
    private func rechargeAtSockets(dt: Float, audio: AudioEngine) {
        var didCharge = false
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
            if didCharge || sockets[i].charge <= 0 || player.ammo[ci] >= cap { continue }
            if vlen(sockets[i].pos - player.pos) < socketRange {
                let take = min(max(1, Int(socketRechargeRate * dt)), min(cap - player.ammo[ci], sockets[i].charge))
                if take > 0 {
                    player.ammo[ci] += take; sockets[i].charge -= take
                    player.pickupFlash = max(player.pickupFlash, 0.18)
                    didCharge = true
                }
            }
        }
        if didCharge && !recharging { message("RECHARGING PLASMA CELLS"); audio.pickup() }
        recharging = didCharge
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
            if player.health >= player.maxHealth { return false }
            player.health = min(player.maxHealth, player.health + 10); player.pickupFlash = 0.5; return true
        case .medkit:
            if player.health >= player.maxHealth { return false }
            player.health = min(player.maxHealth, player.health + 25); player.pickupFlash = 0.6; return true
        case .armor:
            if player.armor >= 100 { return false }
            player.armor = min(100, player.armor + 40); return true
        case .megaArmor:
            player.armor = player.maxArmor; player.pickupFlash = 0.8; return true
        case .ammoCells: return player.giveAmmo(.cells, 40)
        case .ammoRockets: return player.giveAmmo(.rockets, 5)
        case .ammoFuel: return player.giveAmmo(.fuel, 100)
        case .mineCrate:
            if player.mines >= player.maxMines { return false }
            player.mines = min(player.maxMines, player.mines + 3)
            if !minesHintGiven { minesHintGiven = true; message("PRESS  G  TO  DEPLOY  A  MINE") }
            return true
        case .weaponRocket: player.giveWeapon(.rocket); player.giveAmmo(.rockets, 5); switchTo(.rocket); return true
        case .keyRed: player.keys.insert(.red); return true
        case .keyBlue: player.keys.insert(.blue); return true
        case .keyYellow: player.keys.insert(.yellow); return true
        }
    }

    private func hazardTick(dt: Float, audio: AudioEngine) {
        hazardTimer -= dt
        let onHazard = map.hazard[map.idx(Int(player.pos.x), Int(player.pos.y))]
        if onHazard && hazardTimer <= 0 {
            hazardTimer = 0.45
            damagePlayer(5, audio: audio, armorBypass: true)
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
    /// odd curl of smoke off a dead panel.
    private func emitSparks(dt: Float) {
        sparkTimer -= dt
        if sparkTimer > 0 { return }
        sparkTimer = 0.07
        let pr: Float = 11
        var made = 0
        for v in sparkSites {
            if made >= 5 { break }
            if abs(v.pos.x - player.pos.x) > pr || abs(v.pos.y - player.pos.y) > pr { continue }
            if rng.f(0, 1) > 0.5 { continue }                       // bursty, not constant
            for _ in 0..<rng.i(1, 3) {
                particles.append(Particle(pos: v.pos + SIMD2(rng.f(-0.05, 0.05), rng.f(-0.05, 0.05)),
                                          vel: v.dir * rng.f(0.4, 1.2) + SIMD2(rng.f(-0.7, 0.7), rng.f(-0.7, 0.7)),
                                          life: rng.f(0.12, 0.3), maxLife: 0.3, color: packRGBA(255, 238, 185),
                                          size: rng.f(1.5, 3.2), height: rng.f(0.45, 0.72), rise: rng.f(-1.8, -0.5),
                                          maxAlpha: 0.95, fire: true))      // additive coloured glint, falls
            }
            if rng.f(0, 1) < 0.12 {                                 // occasional smoke wisp
                particles.append(Particle(pos: v.pos, vel: v.dir * 0.1, life: rng.f(0.9, 1.5), maxLife: 1.5,
                                          color: packRGBA(58, 56, 60), size: rng.f(8, 13), height: 0.62,
                                          rise: rng.f(0.4, 0.8), maxAlpha: 0.28))
            }
            made += 1
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
        let health = Float(max(0, player.health)) / Float(player.maxHealth)
        return (threat, queen, health, min(1, combatHeat))
    }
}
