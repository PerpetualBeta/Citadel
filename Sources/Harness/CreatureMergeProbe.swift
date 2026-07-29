#if CITADEL_HARNESS
// Citadel — creature-merge A/B probe (CITADEL_CREATUREPROBE).
//
// The mesh creatures used to reach the frame the slow way: render each group to an
// offscreen sheet, flush the command queue, copy colour AND perp-depth back to the CPU
// (two full 1280×800 transfers), then merge a million pixels by hand. Per group. The
// frame log caught it — `creatures` was the worst stage in 30 of 58 missed frames, at up
// to 11.3 ms — and because the cost stepped with what happened to be in view, sweeping
// the mouse round changed it frame to frame, which is what "jerky when I rotate" was.
//
// They now rasterise straight into the tonemapped frame inside the frame's own command
// buffer. That is a rewrite of how they composite, so "it still looks right" is not good
// enough: this probe renders the SAME world state through both paths and DIFFS the
// pixels. Identical output is the pass condition; the timing split is the payoff.
//
// Run: CITADEL_CREATUREPROBE[=outdir] (writes creature-merge-{gpu,cpu,diff}.png)

import Foundation
import Metal
import QuartzCore
import simd

enum CreatureMergeProbe {

    static func run(outDir: String?) {
        guard let device = MTLCreateSystemDefaultDevice() else { print("PROBE: no Metal device"); return }
        let base = outDir.map { ($0 as NSString).expandingTildeInPath } ?? ("~/Desktop" as NSString).expandingTildeInPath
        let dir = URL(fileURLWithPath: base, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Both renderers read `creatureReadback` once, at init — so build one either side of the
        // flag and restore whatever the user had set.
        let saved = UserDefaults.standard.object(forKey: "creatureReadback")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "creatureReadback") }
            else { UserDefaults.standard.removeObject(forKey: "creatureReadback") }
        }
        UserDefaults.standard.set(false, forKey: "creatureReadback")
        guard let gpuRR = RasterRenderer(device: device) else { print("PROBE: renderer init failed"); return }
        UserDefaults.standard.set(true, forKey: "creatureReadback")
        guard let cpuRR = RasterRenderer(device: device) else { print("PROBE: renderer init failed"); return }

        var worstDiff = 0, rounding = 0, material = 0
        for scene in scenes() {
            let (name, make) = scene
            // Two worlds built from the same seed + the same forced creature layout: the renderers
            // must not share one, because the drone pose-resolve caches nothing but the queen's
            // head easing does, and a shared world would let the first render bias the second.
            let wa = make(), wb = make()
            let ca = Canvas2D(), cb = Canvas2D()

            _ = gpuRR.render(wa, into: ca)                     // warm: first dispatch pays shader compile
            _ = cpuRR.render(wb, into: cb)
            let tGPU = median(8) { _ = gpuRR.render(wa, into: ca) }
            let tCPU = median(8) { _ = cpuRR.render(wb, into: cb) }

            // COVERAGE — the whole comparison is vacuous if nothing was drawn: an empty scene
            // diffs to zero exactly as a faithful merge does. So render the same frame with the
            // creatures taken out and diff THAT: the pixel count is how much of the frame they
            // actually occupy, and a zero here invalidates the result above rather than passing it.
            let bare = make(); bare.monsters.removeAll(); bare.particles.removeAll()
            let cbare = Canvas2D()
            _ = gpuRR.render(bare, into: cbare)
            let cover = diff(ca, cbare)
            let eGPU = energy(ca, over: cbare), eCPU = energy(cb, over: cbare)

            let d = diff(ca, cb)
            worstDiff = max(worstDiff, d.maxDelta)
            material += d.where_.count                       // Δ>1: a real disagreement, worth explaining
            rounding += d.pixels - d.where_.count            // Δ1: 8-bit quantisation, invisible
            print(String(format: "%-16@ gpu %5.2fms cpu %5.2fms ×%.1f  cover %6d px (%5.2f%%)  →  diff %6d px, mean Δ%5.2f, max Δ%3d  energy %.3f",
                         name as NSString, tGPU, tCPU, tCPU / max(tGPU, 1e-6),
                         cover.pixels, Double(cover.pixels) / Double(RenderConfig.width * RenderConfig.viewHeight) * 100,
                         d.pixels, d.meanDelta, d.maxDelta, eCPU == 0 ? 0 : eGPU / eCPU))
            if cover.pixels == 0 { print("   ⚠︎ NOTHING DREW — this scene proves nothing; fix the placement.") }
            // Any mismatch bigger than 8-bit rounding gets named, with the background pixel that fed
            // the fire wash — the one part of the merge that reads what is already in the frame, and so
            // the only place the two paths can legitimately disagree.
            if d.maxDelta > 1 { dump(d, gpu: ca, cpu: cb, bare: cbare, limit: 6) }

            if d.pixels > 0 {
                let tag = name.replacingOccurrences(of: " ", with: "-")
                Captures.writePNG(ca.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1,
                                  to: dir.appendingPathComponent("creature-merge-gpu-\(tag).png"))
                Captures.writePNG(cb.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1,
                                  to: dir.appendingPathComponent("creature-merge-cpu-\(tag).png"))
                var heat = d.map
                heat.withUnsafeMutableBufferPointer {
                    Captures.writePNG($0.baseAddress!, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1,
                                      to: dir.appendingPathComponent("creature-merge-diff-\(tag).png"))
                }
            }
        }
        // ±1 is 8-bit quantisation and never visible: the CPU merge rounds the creature colour to
        // 8 bits when it writes the offscreen sheet and rounds AGAIN when it blends, where the GPU
        // path blends at float precision and rounds once. Anything BIGGER than that is a real
        // disagreement and must be understood before it is accepted.
        print(String(format: "PROBE: %@ — %d px differ by ±1 (8-bit rounding), %d px materially (worst Δ%d)",
                     material == 0 ? "PASS" : "REVIEW", rounding, material, worstDiff))
    }

    // ── scenes ────────────────────────────────────────────────────────────────
    // Each forces creatures into the player's view: a drone pack (overlapping, so
    // creature-vs-creature ordering is exercised), a burning drone (the fire wash — the one
    // part of the merge that reads the destination pixel), a drone nosed up to a wall (the
    // world-occlusion test), and a queen with drones in front of her (cross-group ordering).
    private typealias Scene = (String, () -> World)

    private static func scenes() -> [Scene] {
        // "queen alone" vs "queen + drones" is the controlled pair: the only difference is whether a
        // second creature GROUP shares the frame, which is the one place the two paths arbitrate
        // differently (a shared depth buffer vs a per-group perp compare).
        [("drone pack",     { build(drones: 6, burn: false, queen: false) }),
         ("queen alone",    { build(drones: 0, burn: false, queen: true) }),
         ("queen + drones", { build(drones: 4, burn: false, queen: true) }),
         ("pyre + drone",   { build(drones: 2, burn: true,  queen: false) }),
         // The particle stack does NOT diff to zero — the GPU pass evaluates the falloff analytically
         // where the CPU splat read a 257-entry LUT, and drops the row/column dither that hid the CPU's
         // stride optimisation. So judge it on ENERGY: total luminance laid down, which is what says the
         // blend maths is right even when the two spread it over slightly different pixels.
         //
         // LIGHT vs HEAVY is the controlled pair, and the reason both are here. The CPU splat shrank
         // EVERY radius once a frame's estimated blend load ran over budget (`particleScale`) — pure
         // load-shedding for a Swift pixel loop, but it means a busy frame's CPU output is a DEGRADED
         // reference, not the authored look. Light stays under that threshold, so energy must land at
         // ~1.0 and proves the maths. Heavy crosses it, so the GPU reads brighter by design.
         ("particles light", { build(drones: 0, burn: false, queen: false, particleLoad: 1) }),
         ("particles heavy", { build(drones: 0, burn: false, queen: false, particleLoad: 2) })]
    }

    private static func build(drones: Int, burn: Bool, queen: Bool, particleLoad: Int = 0) -> World {
        let w = World(level: 3, colonyIndex: 0, seed: 4242)
        // The player starts in the arrival lift with the doors shut, so anything placed relative to
        // that pose is behind a steel wall. Stand her at the head of the longest clear run on the
        // level instead: an open sightline is the whole point of a creature scene.
        openVista(w)
        let p0 = w.player.pos, dir = w.player.dir
        let f = SIMD2<Float>(cos(dir), sin(dir)), r = SIMD2<Float>(-sin(dir), cos(dir))
        // a walkable cell `d` ahead and `lat` to the side — walked back toward the eye until open,
        // so a creature is never seeded inside the geometry (which would make the scene meaningless)
        func openSpot(_ d: Float, _ lat: Float) -> SIMD2<Float> {
            var dd = d, q = p0 + f * d + r * lat
            while w.map.blocksMovement(Int(q.x), Int(q.y)) && dd > 1.0 { dd -= 0.4; q = p0 + f * dd + r * lat * (dd / d) }
            return q
        }
        w.monsters.removeAll()
        for i in 0..<drones {
            // `burn`: the FAR body is a half-consumed corpse, which is what gatherFireEmitters turns
            // into a pyre (state == .dead && 0 < burn < 1 — a fully-burnt body has stopped flaming);
            // the near one stands live in front of it, so the frame has a creature against fire, which
            // is the only thing that exercises the merge's fire wash.
            let far = burn && i == 0
            var m = Monster(kind: .alien, pos: openSpot(far ? 4.6 : 1.6 + Float(i % 3) * 1.1,
                                                       burn ? 0 : Float(i / 3) * 0.9 - 0.9))
            m.awake = true; m.hasSeen = true; m.lastSeen = p0
            m.dir = dir + .pi                              // facing the player
            m.animTime = Float(i) * 0.37                   // desynced gait → distinct silhouettes
            if far { m.state = .dead; m.stateTime = World.droneDeathTime; m.burn = 0.5 }
            else if !burn && i == drones - 1 { m.state = .dead; m.stateTime = World.droneDeathTime }   // a corpse on the deck
            w.monsters.append(m)
        }
        if queen {
            var q = Monster(kind: .queen, pos: openSpot(4.4, 0))
            q.awake = true; q.hasSeen = true; q.lastSeen = p0
            w.monsters.append(q)
        }
        w.particles.removeAll()                             // isolate the creature merge from the sprite compositor
        if particleLoad > 0 {
            // All three species. LIGHT places them far and small so the CPU's estimated blend load stays
            // under its budget; HEAVY is a pyre at arm's length, which is what crosses it.
            let heavy = particleLoad > 1
            let near: Float = heavy ? 2.0 : 5.0             // distance drives the projected radius
            let fSize: Float = heavy ? 8 : 4, sSize: Float = 3, mSize: Float = heavy ? 10 : 4
            let nF = heavy ? 30 : 10, nS = heavy ? 20 : 6, nM = heavy ? 25 : 8
            for i in 0..<nF {                               // flame: additive, age-ramped (colour 0)
                let q = openSpot(near + Float(i % 5) * 0.5, Float(i / 5) * 0.4 - 1.0)
                w.particles.append(Particle(pos: q, vel: .zero, life: Float(30 - i % 24), maxLife: 30, color: 0,
                                            size: fSize, height: 0.30 + Float(i % 4) * 0.06, rise: 0, maxAlpha: 0.9, fire: true))
            }
            for i in 0..<nS {                               // spark: sharp glint + upward streak
                let q = openSpot(near - 0.2 + Float(i % 4) * 0.6, Float(i / 4) * 0.5 - 1.0)
                w.particles.append(Particle(pos: q, vel: .zero, life: Float(20 - i % 16), maxLife: 20,
                                            color: packRGBA(255, 214, 140), size: sSize,
                                            height: 0.35 + Float(i % 5) * 0.05, rise: 0, maxAlpha: 1.0, fire: true))
            }
            for i in 0..<nM {                               // smoke: soft, alpha-blended, faint
                let q = openSpot(near + 0.4 + Float(i % 5) * 0.55, Float(i / 5) * 0.45 - 1.1)
                w.particles.append(Particle(pos: q, vel: .zero, life: Float(40 - i % 30), maxLife: 40,
                                            color: packRGBA(96, 92, 88), size: mSize,
                                            height: 0.42 + Float(i % 4) * 0.07, rise: 0, maxAlpha: 0.55, fire: false))
            }
        }
        return w
    }

    /// Stand the player at the head of the longest clear run on the level, looking down it.
    private static func openVista(_ w: World) {
        let m = w.map
        func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
        let dirs: [(Int, Int, Float)] = [(1, 0, 0), (-1, 0, .pi), (0, 1, .pi / 2), (0, -1, -.pi / 2)]
        var best = 0
        for cy in 2..<(m.h - 2) { for cx in 2..<(m.w - 2) where op(cx, cy) {
            for (dx, dy, ang) in dirs {
                var k = 1
                while k < 14 && op(cx + dx * k, cy + dy * k) { k += 1 }
                if k > best { best = k; w.player.pos = SIMD2(Float(cx) + 0.5, Float(cy) + 0.5); w.player.dir = ang }
            }
        } }
    }

    // ── measurement ───────────────────────────────────────────────────────────
    private static func median(_ n: Int, _ body: () -> Void) -> Double {
        var ms: [Double] = []
        for _ in 0..<n { let t = CACurrentMediaTime(); body(); ms.append((CACurrentMediaTime() - t) * 1000) }
        ms.sort(); return ms[ms.count / 2]
    }

    private struct Diff { var pixels = 0; var maxDelta = 0; var meanDelta = 0.0; var map: [UInt32] = []; var where_: [Int] = [] }

    /// Total luminance `img` lays down over `base`. For layers that blend rather than replace — the
    /// particle stack — this is the meaningful comparison: a ratio near 1.0 says the two paths deposit
    /// the same light, even where they distribute it across slightly different pixels.
    private static func energy(_ img: Canvas2D, over base: Canvas2D) -> Double {
        var sum = 0.0
        for i in 0..<(RenderConfig.width * RenderConfig.viewHeight) {
            let a = img.framebuffer[i], b = base.framebuffer[i]
            func lum(_ c: UInt32) -> Double {
                0.299 * Double(c & 0xFF) + 0.587 * Double((c >> 8) & 0xFF) + 0.114 * Double((c >> 16) & 0xFF)
            }
            sum += lum(a) - lum(b)
        }
        return sum
    }

    /// Name the first few mismatching pixels: where they are, what each path produced, and what the
    /// frame held there BEFORE any creature drew. Three numbers beat a squint at a screenshot.
    private static func dump(_ d: Diff, gpu: Canvas2D, cpu: Canvas2D, bare: Canvas2D, limit: Int) {
        func rgb(_ c: UInt32) -> String {
            String(format: "%3d,%3d,%3d", c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF)
        }
        for i in d.where_.prefix(limit) {
            let x = i % RenderConfig.width, y = i / RenderConfig.width
            // the wash strength the CPU path would have computed from ITS background (the frame with
            // earlier creature groups already merged in) — the term the GPU path takes from colSnap
            let b = cpu.framebuffer[i]
            let r = Float(b & 0xFF) / 255, g = Float((b >> 8) & 0xFF) / 255, bl = Float((b >> 16) & 0xFF) / 255
            let fire = max(0, min(1, ((r - bl) - 0.40) / 0.30)) * max(0, min(1, (max(r, g) - 0.5) / 0.4))
            print(String(format: "     (%4d,%4d)  gpu[%@]  cpu[%@]  pre-creature[%@]  cpu-bg fireness %.2f",
                         x, y, rgb(gpu.framebuffer[i]) as NSString, rgb(cpu.framebuffer[i]) as NSString,
                         rgb(bare.framebuffer[i]) as NSString, fire))
        }
    }

    /// Per-channel absolute difference. The diff map paints any mismatch, scaled so a Δ1 rounding
    /// wobble is still visible — a blank diff PNG would be indistinguishable from a bug that wrote
    /// nothing at all, so it is only written when there IS a mismatch.
    private static func diff(_ a: Canvas2D, _ b: Canvas2D) -> Diff {
        let n = RenderConfig.width * RenderConfig.viewHeight
        var d = Diff(); d.map = [UInt32](repeating: 0xFF00_0000, count: n)
        var sum = 0
        for i in 0..<n {
            let x = a.framebuffer[i], y = b.framebuffer[i]
            if x == y { continue }
            var worst = 0
            for sh in [0, 8, 16] { worst = max(worst, abs(Int((x >> sh) & 0xFF) - Int((y >> sh) & 0xFF))) }
            if worst == 0 { continue }                       // alpha-only difference: not visible
            d.pixels += 1; sum += worst; d.maxDelta = max(d.maxDelta, worst)
            if worst > 1 { d.where_.append(i) }
            let heat = UInt32(min(255, 40 + worst * 8))
            d.map[i] = 0xFF00_0000 | heat                    // red = mismatch, brighter = bigger
        }
        d.meanDelta = d.pixels == 0 ? 0 : Double(sum) / Double(d.pixels)
        return d
    }
}
#endif
