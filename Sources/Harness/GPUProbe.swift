#if CITADEL_HARNESS
// Citadel — where the GPU frame actually goes (CITADEL_GPUPROBE).
//
// The frame-budget probe named `gpuWait` as the dominant remaining cost on the plant floors —
// 8–12 ms, against a 16.7 ms budget — and could not say why. It logs live play, where the light
// count and the combat that drives it rise together, so the correlation it showed was suggestive
// and nothing more. Asserting a cause from that would have been a guess dressed as a finding.
//
// This decomposes it by SUBTRACTION instead: render the same frame from the same camera with one
// term removed at a time and take the difference. Offline, headless, muted, deterministic.
//
// METHOD, and why it is not simply "time each variant in turn". The first cut of this probe did
// exactly that and produced garbage: the same baseline measured 7.05 ms and then 4.60 ms on
// consecutive runs, and a 32-light frame came out SLOWER than a 64-light one — impossible for a
// shrinking loop. Wall-clock around render() includes waitUntilCompleted, and the GPU is shared
// with the desktop, so a block of reps can sit entirely inside one burst of outside interference
// and the whole block reads high. Two changes fix it:
//
//   • INTERLEAVE. Every variant is measured once per round, round after round, so drift and
//     thermal effects spread across all of them instead of landing on whichever was measured
//     while the machine was busy.
//   • Take the MINIMUM, not the median. The fastest frame observed is the one least disturbed by
//     other work; a median still carries whatever interference was present for half the samples.
//
// The light sweep shares ONE world and ONE renderer, so switching variants costs nothing. The
// geometry variants need their own renderer each, because the level cache is keyed on the world
// and alternating them would force a 14-44 ms rebuild between every sample.
//
// What it can and cannot separate, stated plainly:
//   • the fragment shader's LIGHT LOOP — cleanly, by clamping the light list (debugLightCap)
//   • VERTEX load — cleanly, by stripping props and machinery and rebuilding the level
//   • the fire pass — cleanly, by adding burning creatures
// It cannot isolate the rock relief or the bloom chain without shader switches, so it does not
// claim to. What is left after the terms above is reported as an unattributed remainder rather
// than assigned to whatever seems likely.

import Foundation
import Metal
import simd

enum GPUProbe {

    static func run() {
        guard let device = MTLCreateSystemDefaultDevice(), let rr = RasterRenderer(device: device) else {
            print("GPUPROBE: no device/renderer"); return
        }
        let canvas = Canvas2D()

        /// One render, timed. Wall-clock spans the GPU wait, which is the cost under study.
        func one(_ r: RasterRenderer, _ w: World) -> Double {
            let a = ProcessInfo.processInfo.systemUptime
            _ = r.render(w, into: canvas)
            return (ProcessInfo.processInfo.systemUptime - a) * 1000
        }

        for lvl in [7, 8, 3] {
            /// Stand in the biggest open space looking down its longest axis — the worst case for
            /// fragment and vertex load alike, and the view a machine hall actually presents.
            func build() -> World {
                let w = World(level: lvl, colonyIndex: 0, seed: 3)
                w.monsters = []; w.colonists = []; w.particles = []
                let m = w.map
                func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
                var best = (len: 0, x: 0, y: 0, ang: Float(0))
                for y in 2..<(m.h - 2) { for x in 2..<(m.w - 2) where op(x, y) {
                    for (dx, dy, a) in [(1, 0, Float(0)), (0, 1, Float.pi / 2)] {
                        var n = 0
                        while n < 20 && op(x + dx * n, y + dy * n) { n += 1 }
                        if n > best.len { best = (n, x, y, a) }
                    }
                } }
                w.player.pos = SIMD2(Float(best.x) + 0.5, Float(best.y) + 0.5)
                w.player.dir = best.ang
                return w
            }

            let world = build()
            rr.debugLightCap = -1
            _ = one(rr, world)                                    // warm: level build + first dispatch
            let statics = rr.staticVertCount, mach = rr.machineVertCount

            // ── 1. the fragment shader's light loop ──
            // One world, one renderer, interleaved: only the loop count changes between samples, so
            // whatever this shows IS the light loop, with no combat confound and no rebuild between.
            let caps = [-1, 48, 32, 16, 8, 4, 0]                   // −1 = as shipped
            var bestOf = [Int: Double](); for c in caps { bestOf[c] = .greatestFiniteMagnitude }
            for _ in 0..<40 {
                for c in caps {
                    rr.debugLightCap = c
                    let t = one(rr, world)
                    bestOf[c] = min(bestOf[c]!, t)
                }
            }
            rr.debugLightCap = -1
            let baseline = bestOf[-1]!
            print(String(format: "\nGPUPROBE L%d — %dx%d · static %d verts (machinery %d)", lvl, RenderConfig.width, RenderConfig.viewHeight, statics, mach))
            print(String(format: "   lights as shipped                      %5.2f ms", baseline))
            for c in caps.dropFirst() {
                print(String(format: "   lights ≤ %-3d                           %5.2f ms  (%+.2f)", c, bestOf[c]!, bestOf[c]! - baseline))
            }

            // ── 2. vertex load ── own renderer per variant, so the level cache holds across rounds
            guard let rrNoMach = RasterRenderer(device: device), let rrNoProps = RasterRenderer(device: device) else { continue }
            let noMach = build(); noMach.props.removeAll { RasterRenderer.machineKind($0.kind) }
            let noProps = build(); noProps.props.removeAll(); noProps.drums.removeAll(); noProps.sockets.removeAll()
            _ = one(rrNoMach, noMach); _ = one(rrNoProps, noProps)
            var bMach = Double.greatestFiniteMagnitude, bProps = Double.greatestFiniteMagnitude, bBase = Double.greatestFiniteMagnitude
            for _ in 0..<40 {
                bBase = min(bBase, one(rr, world))
                bMach = min(bMach, one(rrNoMach, noMach))
                bProps = min(bProps, one(rrNoProps, noProps))
            }
            print(String(format: "   machinery stripped                     %5.2f ms  (%+.2f)", bMach, bMach - bBase))
            print(String(format: "   all props stripped                     %5.2f ms  (%+.2f)", bProps, bProps - bBase))

            // ── 3. the volumetric fire pass ── one more full-screen pass over the whole frame
            guard let rrFire = RasterRenderer(device: device) else { continue }
            let fire = build()
            for k in 0..<3 {
                var mon = Monster(kind: .alien, pos: fire.player.pos + SIMD2(Float(k) * 0.6 + 1.5, 0))
                guard !fire.map.blocksMovement(Int(mon.pos.x), Int(mon.pos.y)) else { continue }
                mon.state = .dead; mon.stateTime = World.droneDeathTime; mon.burn = 0.5   // a burning corpse = a pyre
                fire.monsters.append(mon)
            }
            let emitters = GPURaymarch.gatherFireEmitters(fire).count
            _ = one(rrFire, fire)
            var bFire = Double.greatestFiniteMagnitude
            for _ in 0..<40 { bFire = min(bFire, one(rrFire, fire)) }
            print(String(format: "   + %d fire emitters                      %5.2f ms  (%+.2f)", emitters, bFire, bFire - bBase))

            // ── 4. CREATURES ── the term the first version of this probe MISSED entirely, by clearing
            // world.monsters before measuring anything. Since the creature merge moved onto the GPU
            // their passes live inside the frame's own command buffer, so their cost lands squarely in
            // the `gpuWait` this probe exists to explain — and live play on these floors carries 26-37
            // monsters. Measuring the frame with an empty bestiary and calling the result an
            // explanation of gpuWait would have been worthless.
            guard let rrMon = RasterRenderer(device: device) else { continue }
            let withMon = build()
            var placed = 0
            for k in 0..<12 {
                let a = Float(k) * 0.7
                let p = withMon.player.pos + SIMD2(cos(a), sin(a)) * (2.0 + Float(k % 4) * 0.8)
                guard !withMon.map.blocksMovement(Int(p.x), Int(p.y)) else { continue }
                var mon = Monster(kind: .alien, pos: p)
                mon.awake = true; mon.hasSeen = true; mon.state = .chase
                withMon.monsters.append(mon); placed += 1
            }
            _ = one(rrMon, withMon)
            var bMon = Double.greatestFiniteMagnitude
            for _ in 0..<40 { bMon = min(bMon, one(rrMon, withMon)) }
            print(String(format: "   + %d drones in view                     %5.2f ms  (%+.2f)", placed, bMon, bMon - bBase))

            // Each figure is what it IS: the measured saving from removing that one thing. They are
            // NOT additive and are not presented as shares of a budget — strip the props and the wall
            // behind them shades instead, so the light loop then runs over different pixels.
            print(String(format: "   ── light loop %.2f ms · every prop %.2f ms · floor %.2f ms (bloom/tonemap/read-back + walls)",
                         baseline - bestOf[0]!, bBase - bProps, min(bestOf[0]!, bProps)))
        }
        print("\nGPUPROBE: done. Levels 7-8 are the plant floors; 3 is a furnished upper floor for contrast.")
    }
}
#endif
