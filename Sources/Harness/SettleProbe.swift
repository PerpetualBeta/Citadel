#if CITADEL_HARNESS
// Citadel — mesh-settle CONTINUITY probe (CITADEL_SETTLEPROBE).
//
// `Monster.drawnPos` is not where a drone is; it is where its whole MESH fits, solved every frame
// by `MeshCreature.resolvePoseOutOfSolids` pushing the body off walls and furniture. The player
// sees that solution and aims at it. So the solution being CORRECT is not enough — it also has to
// be CONTINUOUS, because a jump in it is a body teleporting, and no amount of correct-per-frame
// makes that acceptable.
//
// Nothing about the solver guarantees continuity. It is iterative with a fixed budget, it takes
// the STRONGEST violation each round (an argmax, which flips when two samples tie), and it is
// re-seeded from the logical position every frame rather than warm-started from its own last
// answer. It is also DOOR-SENSITIVE for a live creature (`doorsBlock: !corpse`) — and a door's
// `open` fraction crossing `passThreshold` flips a boolean the push direction is chosen from.
// That last one is a known hazard: corpses were exempted from it precisely so "opening one cannot
// shove a settled body across the room", and live drones were left in it.
//
// This probe sweeps the three inputs the solver actually has — the body's facing, its position,
// and the door beside it — FINELY, and reports the largest jump the output takes for the smallest
// step of input. Run: CITADEL_SETTLEPROBE

import Foundation
import Metal
import simd

enum SettleProbe {

    /// A doorway with open floor on both sides, plus the open cell beside it on the approach —
    /// where a drone lies in wait. This is the geometry the report is about.
    private static func findDoorway(_ map: GameMap) -> (door: SIMD2<Int>, through: SIMD2<Float>,
                                                        approach: SIMD2<Float>, beside: SIMD2<Float>)? {
        for y in 1..<(map.h - 1) {
            for x in 1..<(map.w - 1) where map.doors[map.idx(x, y)] != nil {
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let ax = x + dx, ay = y + dy, bx = x - dx, by = y - dy
                    guard map.inBounds(ax, ay), map.inBounds(bx, by),
                          !map.blocksMovement(ax, ay), !map.blocksMovement(bx, by) else { continue }
                    for (sx, sy) in [(dy, dx), (-dy, -dx)] {
                        let cx = ax + sx, cy = ay + sy
                        guard map.inBounds(cx, cy), !map.blocksMovement(cx, cy) else { continue }
                        return (SIMD2(x, y),
                                SIMD2(Float(bx) + 0.5, Float(by) + 0.5),      // far side, through the door
                                SIMD2(Float(ax) + 0.5, Float(ay) + 0.5),      // near side, in front of it
                                SIMD2(Float(cx) + 0.5, Float(cy) + 0.5))      // hugging the wall beside it
                    }
                }
            }
        }
        return nil
    }

    static func run() {
        guard let device = MTLCreateSystemDefaultDevice() else { print("SETTLEPROBE: no Metal device"); return }
        guard let drone = MeshCreature(device: device, kind: .drone) else {
            print("SETTLEPROBE: the drone mesh did not load — nothing to settle"); return
        }
        // A body may not be drawn moving further in one frame than the creature could actually
        // run. Past that it is a teleport, however correct the destination.
        let budget = MonsterKind.alien.def.speed * (1.0 / 60)
        print("SettleProbe — is the DRAWN position continuous in the solver's own inputs?")
        print(String(format: "  budget: a drone at full speed covers %.3f m in one frame", budget))

        var worst: [String: Float] = [:]
        var levels = 0
        for seed in [UInt64(909), 4242, 77_777, 31_337, 5150, 1234] {
            let w = World(level: 1, colonyIndex: 0, seed: seed)
            guard let g = findDoorway(w.map) else { continue }
            levels += 1
            let boxes = w.propColliders
            /// Settle with the doorway at a given open fraction — the door animates, so this is a
            /// live input to the solver, not a constant.
            func settle(_ p: SIMD2<Float>, _ d: Float, doorOpen: Float) -> SIMD2<Float> {
                // GameMap is a reference type, so this animates the level's OWN door — which is
                // what the game does too. Each sweep sets it explicitly, so none inherits another's.
                let m = w.map, di = m.idx(g.door.x, g.door.y)
                if var door = m.doors[di] { door.open = doorOpen; m.doors[di] = door }
                return drone.drawnDronePosition(pos: p, dir: d, corpse: false, map: m, props: boxes)
            }
            func track(_ what: String, _ jump: Float) { worst[what] = max(worst[what] ?? 0, jump) }

            for (where_, at) in [("hugging the wall beside it", g.beside), ("in the doorway itself", g.approach)] {
                // (1) THE DOOR OPENS while the drone waits. Nothing about the drone changes — only
                //     the door — so every millimetre of output movement here is pure artefact.
                let faceIn = atan2(g.through.y - at.y, g.through.x - at.x)
                var prev = settle(at, faceIn, doorOpen: 0)
                var maxDoor: Float = 0, atDoor: Float = 0
                for i in 1...400 {
                    let o = Float(i) / 400
                    let s = settle(at, faceIn, doorOpen: o)
                    let j = simd_length(s - prev)
                    if j > maxDoor { maxDoor = j; atDoor = o }
                    prev = s
                }
                print("  seed \(seed)  door opens, drone " + where_.padding(toLength: 27, withPad: " ", startingAt: 0)
                      + String(format: "worst jump %.3f m at open=%.2f", maxDoor, atDoor))
                track("a door opening beside a drone", maxDoor)

                // (2) TURN IN PLACE, 0.5° per step — far finer than a drone turns between frames,
                //     and a hunting drone turns to track the player every single frame.
                prev = settle(at, 0, doorOpen: 1)
                var maxDir: Float = 0, atDir: Float = 0
                for i in 1...720 {
                    let d = Float(i) / 720 * 2 * .pi
                    let s = settle(at, d, doorOpen: 1)
                    let j = simd_length(s - prev)
                    if j > maxDir { maxDir = j; atDir = d * 180 / .pi }
                    prev = s
                }
                print("  seed \(seed)  turning,    drone " + where_.padding(toLength: 27, withPad: " ", startingAt: 0)
                      + String(format: "worst jump %.3f m at %.0f°", maxDir, atDir))
                track("a drone turning to track you", maxDir)
            }
            var prev = SIMD2<Float>(0, 0)

            // (3) WALK from beside the door, through the OPEN doorway, 5 mm at a time, facing the
            //     way it is going — and only through cells a drone could really stand in.
            let path = [g.beside, g.approach, g.through]
            for leg in 0..<(path.count - 1) {
                let from = path[leg], to = path[leg + 1]
                let face = atan2(to.y - from.y, to.x - from.x)
                let n = max(1, Int(simd_length(to - from) / 0.005))
                let stride = simd_length(to - from) / Float(n)
                prev = settle(from, face, doorOpen: 1)
                var maxWalk: Float = 0, atWalk: Float = 0
                for i in 1...n {
                    let p = from + (to - from) * (Float(i) / Float(n))
                    guard !w.map.blocksMovement(Int(p.x), Int(p.y)) else { continue }
                    let s = settle(p, face, doorOpen: 1)
                    let j = simd_length(s - prev) - stride          // net of the step the body really took
                    if j > maxWalk { maxWalk = j; atWalk = Float(i) / Float(n) }
                    prev = s
                }
                print(String(format: "  seed %6d  walking leg %d of the doorway:            worst jump %.3f m at %.0f%%",
                             seed, leg + 1, maxWalk, atWalk * 100))
                track("walking through a doorway", maxWalk)
            }
        }
        guard levels > 0 else { print("  no doorway found in any probed level"); return }
        print("  — the SOLVER's own answer, jump per smallest input step —")
        for (what, w) in worst.sorted(by: { $0.value > $1.value }) {
            print("    " + what.padding(toLength: 34, withPad: " ", startingAt: 0)
                  + String(format: "worst %.3f m  (%.0f× a frame's travel)", w, w / budget))
        }

        // The solver is a pure function of geometry and it is NOT continuous — the figures above are
        // what it does, and chasing each flip would be endless. What must hold is what the PLAYER
        // sees, which is `Monster.drawnPos`: the correction is rate-limited there, so however far
        // the solver's answer jumps, the body travels. Drive a real drone through the worst input
        // sweep above, one frame at a time, and measure what the body actually does.
        print("  — what the BODY does, frame by frame, through the same sweeps —")
        var bodyWorst: Float = 0
        for seed in [UInt64(909), 77_777] {
            let w = World(level: 1, colonyIndex: 0, seed: seed)
            guard let g = findDoorway(w.map) else { continue }
            w.meshPoseResolve = { kind, pos, dir, corpse, map, props in
                kind == .alien ? drone.drawnDronePosition(pos: pos, dir: dir, corpse: corpse, map: map, props: props) : pos
            }
            var m = Monster(kind: .alien, pos: g.beside)
            m.state = .idle
            w.monsters = [m]
            let frame: Float = 1.0 / 60
            var prevOffset: SIMD2<Float>? = nil
            var maxBody: Float = 0, atWhat = ""
            /// One frame: place the body, animate the door, settle, and measure how far the settle
            /// CORRECTION moved. The correction is the artefact — the body's own walk is not, and
            /// measuring the offset rather than the position separates the two exactly.
            func step(_ p: SIMD2<Float>, _ dir: Float, _ open: Float, _ label: String) {
                w.monsters[0].pos = p
                w.monsters[0].dir = dir
                w.map.doors[w.map.idx(g.door.x, g.door.y)]?.open = open
                w.refreshDrawnPositions(dt: frame)
                let off = w.monsters[0].drawnPos - p
                if let q = prevOffset {
                    let travelled = simd_length(off - q)
                    if travelled > maxBody { maxBody = travelled; atWhat = label }
                }
                prevOffset = off
            }
            // turn on the spot beside the door, then let the door open, then walk through
            for i in 0...720 { step(g.beside, Float(i) / 720 * 2 * .pi, 0, "turning beside the door") }
            for i in 0...400 { step(g.approach, 0, Float(i) / 400, "the door opening") }
            for i in 0...400 {
                let t = Float(i) / 400
                step(g.approach + (g.through - g.approach) * t,
                     atan2(g.through.y - g.approach.y, g.through.x - g.approach.x), 1, "walking through")
            }
            print("    seed \(seed)  worst frame-to-frame body travel "
                  + String(format: "%.4f m", maxBody) + "  (\(atWhat))")
            bodyWorst = max(bodyWorst, maxBody)
        }
        print("  \(bodyWorst <= budget + 1e-4 ? "PASS  " : "REVIEW")  the body never outruns itself — "
              + String(format: "worst %.4f m in a frame vs %.4f m budget", bodyWorst, budget))

        // A rate limit bounds how FAR the correction moves per frame; it does nothing about it
        // moving back and forth. A drone's facing is set straight to the bearing of the player
        // (no turn rate), so as you move the solver's facing input swings, and it answers by
        // alternating between two competing solutions — a shimmer, not a slide. Measure the
        // REVERSALS: how often the correction changes direction, and how wide the swing is,
        // while a player walks past a waiting drone. That is what sets the hysteresis band, and
        // the band has to stay well under a footprint radius or the mesh laps back into the wall.
        print("  — the SHIMMER: a player walking past a waiting drone —")
        var worstSwing: Float = 0, worstRate: Float = 0
        for seed in [UInt64(909), 77_777] {
            let w = World(level: 1, colonyIndex: 0, seed: seed)
            guard let g = findDoorway(w.map) else { continue }
            w.meshPoseResolve = { kind, pos, dir, corpse, map, props in
                kind == .alien ? drone.drawnDronePosition(pos: pos, dir: dir, corpse: corpse, map: map, props: props) : pos
            }
            var m = Monster(kind: .alien, pos: g.beside)
            m.state = .idle
            w.monsters = [m]
            let frame: Float = 1.0 / 60
            // the player crosses the doorway at a walk; the drone stares at them the whole way
            let a = g.through + (g.through - g.approach) * 2, b = g.approach + (g.approach - g.beside) * 2
            let secs: Float = 3, steps = Int(secs / frame)
            var prevOff: SIMD2<Float>? = nil, prevStep = SIMD2<Float>(0, 0)
            var reversals = 0, swing: Float = 0
            for i in 0...steps {
                let t = Float(i) / Float(steps)
                let eye = a + (b - a) * t
                w.player.pos = eye
                w.monsters[0].dir = atan2(eye.y - g.beside.y, eye.x - g.beside.x)   // as World does: straight at them
                w.refreshDrawnPositions(dt: frame)
                let off = w.monsters[0].drawnPos - g.beside
                if let p = prevOff {
                    let stepV = off - p
                    if simd_length(stepV) > 1e-5, simd_length(prevStep) > 1e-5,
                       simd_dot(simd_normalize(stepV), simd_normalize(prevStep)) < -0.5 {
                        reversals += 1
                        swing = max(swing, simd_length(stepV))
                    }
                    prevStep = stepV
                }
                prevOff = off
            }
            let rate = Float(reversals) / secs
            print(String(format: "    seed %6d  %d reversals in %.0f s (%.0f/s) · widest swing %.4f m",
                         Int(seed), reversals, secs, rate, swing))
            worstSwing = max(worstSwing, swing); worstRate = max(worstRate, rate)
        }
        let foot = drone.footprintRadius(height: 0.90)     // the default MeshDroneHeight
        print(String(format: "    a drone's footprint radius is %.3f m — the band must stay well inside it", foot))
        print("  \(worstRate <= 2 ? "PASS  " : "REVIEW")  the body does not shimmer — "
              + String(format: "%.0f direction reversals/s, widest %.4f m (%.0f%% of a footprint)",
                       worstRate, worstSwing, worstSwing / foot * 100))
    }
}
#endif
