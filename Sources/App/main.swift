// Citadel — entry point.
//
// Three launch paths:
//   • CITADEL_SMOKE=1   → headless smoke test (map solvability, AI/combat/
//     scoring/persistence, the framebuffer draws, a best-effort GPU render),
//     then exit. Runs from a shell / CI with no window.
//   • CITADEL_SHOTS[=dir] → render the doc/marketing screenshots headlessly via
//     the real draw path, then exit.
//   • otherwise → bring up the Cocoa app and the Metal-backed game window.

import Cocoa
import Metal
import QuartzCore

// ── Test / capture harness — dev builds only ──────────────────────────────────
// The entire CITADEL_* env-var dispatch below is compiled ONLY into local / ad-hoc
// builds: release.mk defines CITADEL_HARNESS when SIGN_ID is the ad-hoc "-", and
// omits it for a signed, notarised release. So a shipped Citadel ignores every
// CITADEL_* variable and goes straight to the game window. The harness TYPES stay
// compiled (Captures is load-bearing for the renderer); only these entry points
// are gated out of release.
#if CITADEL_HARNESS

// EVERY harness run is hard-muted before the first AudioEngine can exist:
// CITADEL_MUTE stops the engine from ever opening the output device, so a
// harness is PHYSICALLY incapable of sound — volume-0 approaches proved
// fragile (a forgotten node, an init race, a device-open pop all leak).
// CITADEL_AUDIOPROBE is exempt by construction: it renders offline.
for key in ["CITADEL_SMOKE", "CITADEL_FITSHOT", "CITADEL_LOADPROBE", "CITADEL_TIMING",
            "CITADEL_SHOTS", "CITADEL_MATERIALS",
            "CITADEL_AUTOMAP", "CITADEL_ROOMS", "CITADEL_DISPLAYVID",
            "CITADEL_TITLESHOT", "CITADEL_CLUSTERSHOT", "CITADEL_QUEENMOCK", "CITADEL_QUEENMESH",
            "CITADEL_MESHVERIFY", "CITADEL_DRONEMESH", "CITADEL_COLONISTMESH", "CITADEL_CORPSES", "CITADEL_DECKCHECK", "CITADEL_TERMSHOT", "CITADEL_PROOFROOM", "CITADEL_RASTERSHOT"]
    where ProcessInfo.processInfo.environment[key] != nil {
    setenv("CITADEL_MUTE", "1", 1)
    break
}

if ProcessInfo.processInfo.environment["CITADEL_SMOKE"] != nil {
    SmokeTest.run()
    exit(0)
}

// CITADEL_AUDIOPROBE=1 → offline-render the real audio graph and print RMS
// measurements for the paths under suspicion. Silent; diagnostic only.
if ProcessInfo.processInfo.environment["CITADEL_AUDIOPROBE"] != nil {
    AudioProbe.run()
    exit(0)
}

// CITADEL_FITSHOT=1 → render close-ups of the first placed valve + gauge
// (three view angles each) to ~/Desktop/citadel-fittings.png. Diagnostic.
if ProcessInfo.processInfo.environment["CITADEL_FITSHOT"] != nil {
    let gpu = GPUWorldRenderer(device: MTLCreateSystemDefaultDevice()!)!
    var frames: [[UInt32]] = []
    outer: for seed in 1...12 {
        let w = World(level: 3, colonyIndex: 0, seed: UInt64(seed) &* 331 &+ 7)
        for kind: Float in [0, 1] {
            guard let f = w.map.pipeFittings.first(where: { $0.w == kind }) else { continue outer }
            let n2 = SIMD2<Float>(cos(f.z), sin(f.z))
            for ang: Float in [0, 0.7, -0.9] {                    // straight-on + two obliques
                let ca = cos(ang), sa = sin(ang)
                let vdir = SIMD2<Float>(-(n2.x * ca - n2.y * sa), -(n2.x * sa + n2.y * ca))
                w.player.pos = SIMD2(f.x, f.y) - vdir * 1.35
                w.player.dir = atan2(vdir.y, vdir.x)
                let c = Canvas2D()
                _ = gpu.render(w, into: c)
                frames.append(Array(UnsafeBufferPointer(start: c.framebuffer, count: RenderConfig.width * RenderConfig.height)))
            }
        }
        if frames.count >= 6 { break }
    }
    let W2 = RenderConfig.width, H2 = RenderConfig.height
    let sheet = Canvas2D(width: W2 * 3, height: H2 * (frames.count + 2) / 3)
    for (i, fr) in frames.enumerated() {
        fr.withUnsafeBufferPointer { src in
            for y in 0..<H2 {
                memcpy(sheet.framebuffer + ((i / 3 * H2 + y) * sheet.width + (i % 3) * W2),
                       src.baseAddress! + y * W2, W2 * MemoryLayout<UInt32>.stride)
            }
        }
    }
    Captures.writePNG(sheet.framebuffer, w: sheet.width, h: sheet.height, scale: 1,
                      to: URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/citadel-fittings.png"))
    print("wrote ~/Desktop/citadel-fittings.png (\(frames.count) views)")

    // The static shots above can't catch the view-DEPENDENT failure mode (a
    // non-conservative distance cull let march rays overstep the fitting, so
    // it flickered with camera movement). Sweep a dolly/arc across one valve
    // and demand the red handwheel is present from EVERY viewpoint.
    var worstRatio: Float = 1
    sweep: for seed in 1...12 {
        let w = World(level: 3, colonyIndex: 0, seed: UInt64(seed) &* 331 &+ 7)
        guard let f = w.map.pipeFittings.first(where: { $0.w == 0 }) else { continue }
        let n2 = SIMD2<Float>(cos(f.z), sin(f.z))
        let target = SIMD2<Float>(f.x, f.y) + n2 * 0.15
        // Two fine passes at walking-step (~2 cm) camera increments: a head-on
        // dolly and a lateral strafe. The wheel's pixel count must vary
        // SMOOTHLY; adjacent-frame collapses are the flicker.
        var counts: [[Float]] = [[], []]
        for pass in 0..<2 {
            for k in 0..<56 {
                let t = Float(k) / 55
                let ang: Float = pass == 0 ? 0.35 : -0.8 + 1.6 * t
                let dist: Float = pass == 0 ? 2.4 - 1.2 * t : 1.8
                let ca = cos(ang), sa = sin(ang)
                let vdir = -SIMD2<Float>(n2.x * ca - n2.y * sa, n2.x * sa + n2.y * ca)
                let eye = target - vdir * dist
                let clear = (0...Int(dist * 10)).allSatisfy { i in
                    let q = eye + vdir * (Float(i) * 0.1)
                    return !w.map.blocksSight(Int(q.x), Int(q.y))
                }
                if !clear { counts[pass].append(-1); continue }   // occluded by level geometry: not a flicker sample
                w.player.pos = eye
                w.player.dir = atan2(vdir.y, vdir.x)
                // Footprint = pixels that change when the fittings are removed.
                // (A raw red-pixel count drowns in the scene's other reds.)
                let c = Canvas2D(), c0 = Canvas2D()
                _ = gpu.render(w, into: c)
                let saved = w.map.pipeFittings
                w.map.pipeFittings = []
                _ = gpu.render(w, into: c0)
                w.map.pipeFittings = saved
                var foot = 0
                for i in 0..<(RenderConfig.width * RenderConfig.height) {
                    let a = c.framebuffer[i], b = c0.framebuffer[i]
                    if abs(redOf(a) - redOf(b)) + abs(greenOf(a) - greenOf(b)) + abs(blueOf(a) - blueOf(b)) > 24 { foot += 1 }
                }
                counts[pass].append(Float(foot))
            }
        }
        for pass in 0..<2 {
            let vals = counts[pass]
            var line = pass == 0 ? "dolly : " : "strafe: "
            for v in vals { line += v < 0 ? "  ·" : String(format: " %.0f", v) }
            print(line)
            for k in 1..<vals.count where vals[k] >= 0 && vals[k - 1] >= 0 {
                let lo = min(vals[k], vals[k - 1]), hi = max(vals[k], vals[k - 1])
                if hi > 40 { worstRatio = min(worstRatio, hi == 0 ? 1 : lo / hi) }
            }
        }
        break sweep
    }
    print(String(format: "worst adjacent-frame retention %.2f — %@", worstRatio,
                 worstRatio > 0.65 ? "PASS (smooth)" : "FAIL (flicker)"))
    exit(0)
}

// CITADEL_LOADPROBE=1 → time the real render path under increasing combat
// load (drones / projectiles / blast lights / fire particles). Median ms per
// scenario; render = GPU dispatch + readback + sprite composite. Diagnostic:
// finds which term scales when things on screen slow the frame down.
if ProcessInfo.processInfo.environment["CITADEL_LOADPROBE"] != nil {
    let gpu = GPUWorldRenderer(device: MTLCreateSystemDefaultDevice()!)!
    gpu.prewarm()
    let audio = AudioEngine()
    audio.muted = true
    func scenario(_ name: String, monsters nm: Int, projectiles np: Int, blasts nb: Int, particles npart: Int, tickAI: Bool) {
        let w = World(level: 3, colonyIndex: 0, seed: 4242)
        let p0 = w.player.pos, dir = w.player.dir
        let f = SIMD2<Float>(cos(dir), sin(dir)), r = SIMD2<Float>(-sin(dir), cos(dir))
        func openSpot(_ d: Float, _ lat: Float) -> SIMD2<Float> {   // walkable cell ahead of the eye
            var q = p0 + f * d + r * lat
            var dd = d
            while w.map.blocksMovement(Int(q.x), Int(q.y)) && dd > 1.0 { dd -= 0.4; q = p0 + f * dd + r * lat * (dd / d) }
            return q
        }
        w.monsters.removeAll()
        for i in 0..<nm {
            var m = Monster(kind: .alien, pos: openSpot(1.6 + Float(i % 4) * 0.8, Float(i / 4) * 1.0 - 1.0))
            m.awake = true; m.hasSeen = true; m.lastSeen = p0
            w.monsters.append(m)
        }
        for i in 0..<np {
            let q = openSpot(1.2 + Float(i % 8) * 0.5, Float(i / 8) * 0.8 - 0.8)
            w.projectiles.append(Projectile(pos: q, vel: f * 9, kind: .plasma, damage: 13, fromPlayer: true, life: 4))
        }
        for i in 0..<nb {
            w.blasts.append((openSpot(1.5 + Float(i % 6) * 0.6, Float(i / 6) * 0.9 - 0.9), 0.3, SIMD3(1.0, 0.62, 0.28)))
        }
        for i in 0..<npart {
            let q = openSpot(1.0 + Float(i % 10) * 0.35, (Float(i % 7) - 3) * 0.4)
            w.particles.append(Particle(pos: q, vel: .zero, life: 30, maxLife: 30, color: 0,
                                        size: Float(12 + i % 20), height: 0.3, rise: 0, maxAlpha: 0.9, fire: true))
        }
        let c = Canvas2D()
        var rms: [Double] = [], ums: [Double] = []
        for _ in 0..<40 {
            if tickAI {
                let t0 = CACurrentMediaTime()
                w.update(dt: 1.0 / 60, input: InputState(), audio: audio)
                ums.append((CACurrentMediaTime() - t0) * 1000)
            }
            let t1 = CACurrentMediaTime()
            _ = gpu.render(w, into: c)
            rms.append((CACurrentMediaTime() - t1) * 1000)
        }
        rms.sort(); ums.sort()
        let umed = ums.isEmpty ? 0 : ums[ums.count / 2]
        // split the cost: the same frame re-rendered with particles stripped
        let savedP = w.particles
        w.particles = []
        var rms2: [Double] = []
        for _ in 0..<12 {
            let t2 = CACurrentMediaTime()
            _ = gpu.render(w, into: c)
            rms2.append((CACurrentMediaTime() - t2) * 1000)
        }
        w.particles = savedP
        rms2.sort()
        print(String(format: "  %-44s render %6.2f ms   sans-particles %6.2f ms   update %6.2f ms   (particles alive %d)",
                     (name as NSString).utf8String!, rms[rms.count / 2], rms2[rms2.count / 2], umed, savedP.count))
    }
    print("Citadel load probe (render = dispatch + readback + composite; 40-frame medians)")
    scenario("baseline (empty view)", monsters: 0, projectiles: 0, blasts: 0, particles: 0, tickAI: false)
    scenario("+8 drones", monsters: 8, projectiles: 0, blasts: 0, particles: 0, tickAI: false)
    scenario("+16 plasma bolts", monsters: 0, projectiles: 16, blasts: 0, particles: 0, tickAI: false)
    scenario("+16 blast lights", monsters: 0, projectiles: 0, blasts: 16, particles: 0, tickAI: false)
    scenario("+300 fire particles", monsters: 0, projectiles: 0, blasts: 0, particles: 300, tickAI: false)
    scenario("combat: 8 drones + 16 bolts + 16 blasts + 300p", monsters: 8, projectiles: 16, blasts: 16, particles: 300, tickAI: true)
    // the real killer suspect: a melee pack AT the camera (bounds cover the screen)
    // `ring: true` places drones at collision-legal separation (the pack shape the
    // game can actually reach — World's collision keeps centres ≥ 2×radius apart);
    // `ring: false` interpenetrates them at half that spacing, a physically
    // unreachable pile-up kept as the pathological reference.
    func melee(_ name: String, _ n: Int, ring: Bool) {
        let w = World(level: 3, colonyIndex: 0, seed: 4242)
        let p0 = w.player.pos, dir = w.player.dir
        let f = SIMD2<Float>(cos(dir), sin(dir)), r = SIMD2<Float>(-sin(dir), cos(dir))
        w.monsters.removeAll()
        for i in 0..<n {
            let pos: SIMD2<Float>
            if ring {
                // rank 1: three across the front arc at bite range; rank 2 behind
                let th: Float = i < 3 ? Float(i - 1) * 0.9 : (Float(i - 3) - Float(n - 4) / 2) * 0.6
                let dist: Float = i < 3 ? 0.8 : 1.55
                let radial: SIMD2<Float> = f * cos(th) + r * sin(th)
                pos = p0 + radial * dist
            } else {
                let fwd: Float = 0.55 + 0.25 * Float(i % 3)
                let lat: Float = (Float(i % 5) - 2) * 0.35
                pos = p0 + f * fwd + r * lat
            }
            var m = Monster(kind: .alien, pos: pos)
            m.awake = true
            w.monsters.append(m)
        }
        let c = Canvas2D()
        var rms: [Double] = []
        for _ in 0..<40 {
            let t1 = CACurrentMediaTime()
            _ = gpu.render(w, into: c)
            rms.append((CACurrentMediaTime() - t1) * 1000)
        }
        rms.sort()
        print(String(format: "  %-44s render %6.2f ms", (name as NSString).utf8String!, rms[rms.count / 2]))
    }
    melee("1 drone at bite range", 1, ring: true)
    melee("3-drone front rank (physical max at face)", 3, ring: true)
    melee("8-drone pack, collision-legal two ranks", 8, ring: true)
    melee("8 drones interpenetrating (unreachable)", 8, ring: false)
    // Guard: creatures must be VISIBLE at range, not just cheap to skip. The
    // per-ray cull is a pure optimisation — a wrong bound test silently culls
    // distant monsters from every ray and they vanish until melee, which a
    // time-based probe reads as a WIN. Diff the frame with/without a drone
    // down a clear sightline and demand a footprint at every distance.
    do {
        // Sightline candidates come from the MAP, not the spawn: the spawn sits
        // inside the lift car — rendered SDF steel the cell walk can't see, so a
        // walk from there reports "clear" while the camera stares at a wall.
        // Straight runs of open cells are scanned level-wide; a candidate can
        // still be occluded (furniture, lift steel), so ANY fully-visible run
        // passes — the disease (a bad ray cull) kills every candidate at once.
        let w = World(level: 3, colonyIndex: 0, seed: 4242)
        var candidates: [(eye: SIMD2<Float>, f: SIMD2<Float>, run: Float)] = []
        for y in 1..<(w.map.h - 1) {
            for x in 1..<(w.map.w - 1) where !w.map.blocksMovement(x, y) {
                for (dx, dy) in [(1, 0), (0, 1)] {
                    guard w.map.blocksMovement(x - dx, y - dy) else { continue }   // run STARTS here
                    var run = 0
                    while !w.map.blocksMovement(x + dx * (run + 1), y + dy * (run + 1)) { run += 1 }
                    if run >= 7 {
                        candidates.append((SIMD2(Float(x) + 0.5, Float(y) + 0.5),
                                           SIMD2(Float(dx), Float(dy)), Float(run)))
                    }
                }
            }
        }
        candidates.sort { $0.run > $1.run }
        let c = Canvas2D(), c0 = Canvas2D()
        var passed = false
        for cand in candidates.prefix(8) {
            w.player.pos = cand.eye
            w.player.dir = atan2(cand.f.y, cand.f.x)
            var allOK = true
            var strip: [[UInt32]] = []
            var line = String(format: "  run %2.0f cells @(%3.0f,%3.0f):", cand.run, cand.eye.x, cand.eye.y)
            for d: Float in [1.5, 3, 5, 6.5] where d < cand.run - 0.5 {
                w.monsters.removeAll()
                var m = Monster(kind: .alien, pos: cand.eye + cand.f * d)
                m.awake = true
                w.monsters.append(m)
                _ = gpu.render(w, into: c)
                w.monsters.removeAll()
                _ = gpu.render(w, into: c0)
                var foot = 0
                for i in 0..<(RenderConfig.width * RenderConfig.height) {
                    let a = c.framebuffer[i], b = c0.framebuffer[i]
                    if abs(redOf(a) - redOf(b)) + abs(greenOf(a) - greenOf(b)) + abs(blueOf(a) - blueOf(b)) > 24 { foot += 1 }
                }
                line += String(format: "  %.1fm→%dpx", d, foot)
                if foot <= 30 { allOK = false }
                strip.append(Array(UnsafeBufferPointer(start: c.framebuffer, count: RenderConfig.width * RenderConfig.height)))
            }
            print(line + (allOK ? "  ← drone visible at every distance" : "  (occluded or missing)"))
            if allOK {
                passed = true
                // Small-object steadiness: the march's creature t-window is a
                // fraction of a metre for a mine or medkit — a wall-driven step
                // taken just outside it can leap the window entirely and the
                // object vanishes for that ray (view-dependent flicker the
                // drone checks above can't see: a drone's window is ~4× wider).
                // Dolly at 2 cm steps and demand the diff footprint holds.
                w.monsters.removeAll()
                w.items.append(Item(kind: .medkit, pos: cand.eye + cand.f * 4.0))
                w.deployedMines.append(Mine(pos: cand.eye + cand.f * 3.0 + SIMD2(-cand.f.y, cand.f.x) * 0.45, arm: 0))
                var feet: [Float] = []
                var worstInv = 0, worstCal = 0
                // neighbourhood-tolerant asymmetric diff (a-pixels vs b's 3×3)
                func ndiff(_ ca: Canvas2D, _ cb: Canvas2D) -> Int {
                    var bad = 0
                    let W3 = RenderConfig.width, H3 = RenderConfig.height
                    for i in 0..<(W3 * H3) {
                        let a = ca.framebuffer[i], b = cb.framebuffer[i]
                        guard abs(redOf(a) - redOf(b)) + abs(greenOf(a) - greenOf(b)) + abs(blueOf(a) - blueOf(b)) > 24 else { continue }
                        let px = i % W3, py = i / W3
                        var matched = false
                        search: for oy in -1...1 {
                            for ox in -1...1 where !(ox == 0 && oy == 0) {
                                let nx = px + ox, ny = py + oy
                                guard nx >= 0, nx < W3, ny >= 0, ny < H3 else { continue }
                                let nb = cb.framebuffer[ny * W3 + nx]
                                if abs(redOf(a) - redOf(nb)) + abs(greenOf(a) - greenOf(nb)) + abs(blueOf(a) - blueOf(nb)) <= 24 { matched = true; break search }
                            }
                        }
                        if !matched { bad += 1 }
                    }
                    return bad
                }
                for k in 0..<56 {
                    w.player.pos = cand.eye + cand.f * (Float(k) * 0.02)
                    let savedI = w.items; let savedM = w.deployedMines
                    _ = gpu.render(w, into: c)
                    // ground truth: the identical frame with the mask forced
                    // fully on — the mask is a pure optimisation, so any pixel
                    // that moves more than march-epsilon shading noise is a
                    // mask/window bug (this is what catches silhouette-band
                    // dropout that a gross footprint count can't see)
                    gpu.disableCreatureMask = true
                    _ = gpu.render(w, into: c0)
                    gpu.disableCreatureMask = false
                    let inv = ndiff(c, c0)
                    if inv > worstInv {
                        // where do the diverging pixels live? masked frame with
                        // every offender painted magenta — band vs speckle is
                        // the whole diagnosis
                        let mark = Canvas2D()
                        for i in 0..<(RenderConfig.width * RenderConfig.height) {
                            let a = c.framebuffer[i], b = c0.framebuffer[i]
                            let bad = abs(redOf(a) - redOf(b)) + abs(greenOf(a) - greenOf(b)) + abs(blueOf(a) - blueOf(b)) > 24
                            mark.framebuffer[i] = bad ? packRGBA(255, 0, 255, 255) : a
                        }
                        Captures.writePNG(mark.framebuffer, w: RenderConfig.width, h: RenderConfig.height, scale: 1,
                                          to: URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/citadel-mask-diff.png"))
                    }
                    worstInv = max(worstInv, inv)
                    w.items.removeAll(); w.deployedMines.removeAll()
                    _ = gpu.render(w, into: c0)
                    w.items = savedI; w.deployedMines = savedM
                    var foot = 0
                    for i in 0..<(RenderConfig.width * RenderConfig.height) {
                        let a = c.framebuffer[i], b = c0.framebuffer[i]
                        if abs(redOf(a) - redOf(b)) + abs(greenOf(a) - greenOf(b)) + abs(blueOf(a) - blueOf(b)) > 24 { foot += 1 }
                    }
                    feet.append(Float(foot))
                    // calibration: same pose with the window clamp DISABLED must
                    // trip the detector — otherwise the instrument is blind and
                    // the PASS above means nothing (clobbers c/c0: keep last)
                    gpu.disableWindowClamp = true
                    _ = gpu.render(w, into: c)
                    gpu.disableWindowClamp = false
                    gpu.disableCreatureMask = true
                    _ = gpu.render(w, into: c0)
                    gpu.disableCreatureMask = false
                    worstCal = max(worstCal, ndiff(c, c0))
                }
                var worst: Float = 1
                for k in 1..<feet.count {
                    let lo = min(feet[k], feet[k - 1]), hi = max(feet[k], feet[k - 1])
                    if hi > 40 { worst = min(worst, lo / hi) }
                }
                let minFoot = feet.min() ?? 0
                print(String(format: "  medkit+mine dolly: footprint %.0f…%.0f px, worst adjacent retention %.2f — %@",
                             minFoot, feet.max() ?? 0, worst,
                             worst > 0.6 && minFoot > 100 ? "PASS (steady)" : "FAIL (flicker)"))
                // Thresholds are CALIBRATED, not guessed: convergence jitter at
                // depth cliffs (wall corners over far geometry — bistable for
                // any two valid marches) measures ~150 px; the window-leap
                // disease measures ~1250. 300/600 splits them with ≥2× margin
                // on each side; the calibration render re-proves the split
                // every run.
                let invOK = worstInv <= 300, calOK = worstCal > 600
                print("  mask-off invariant: worst frame diff \(worstInv) px — \(invOK ? "PASS (mask is loss-free)" : "FAIL (mask eats geometry)")")
                print("  instrument calibration (clamp disabled on purpose): worst \(worstCal) px — \(calOK ? "detector sees the disease" : "DETECTOR IS BLIND — the PASS above is meaningless")")
                w.items.removeAll(); w.deployedMines.removeAll()
                w.player.pos = cand.eye
                let W2 = RenderConfig.width, H2 = RenderConfig.height
                let sheet = Canvas2D(width: W2 * strip.count, height: H2)
                for (i, fr) in strip.enumerated() {
                    fr.withUnsafeBufferPointer { src in
                        for y in 0..<H2 {
                            memcpy(sheet.framebuffer + (y * sheet.width + i * W2), src.baseAddress! + y * W2, W2 * MemoryLayout<UInt32>.stride)
                        }
                    }
                }
                Captures.writePNG(sheet.framebuffer, w: sheet.width, h: sheet.height, scale: 1,
                                  to: URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/citadel-range.png"))
                break
            }
        }
        print(passed ? "  visibility sweep PASS (strip → ~/Desktop/citadel-range.png)"
                     : "  visibility sweep FAIL — the drone is invisible at range on every candidate sightline")
    }
    exit(0)
}

// CITADEL_TIMING=1 → print where the fire-press → first-gameplay-frame time
// actually goes (ride world, first GPU frame, level generation, sprite bake),
// then exit. Diagnostic only.
if ProcessInfo.processInfo.environment["CITADEL_TIMING"] != nil {
    func timed(_ label: String, _ body: () -> Void) {
        let t0 = CACurrentMediaTime()
        body()
        print(String(format: "  %-46s %6.0f ms", (label as NSString).utf8String!, (CACurrentMediaTime() - t0) * 1000))
    }
    print("Citadel timing")
    var gpu: GPUWorldRenderer!
    timed("GPUWorldRenderer init (kernel compile)") { gpu = GPUWorldRenderer(device: MTLCreateSystemDefaultDevice()!) }
    timed("prewarm (procedural texture bake + upload)") { gpu.prewarm() }
    var ride: World!
    timed("liftRideShaft (the ride world)") { ride = World.liftRideShaft() }
    let c = Canvas2D()
    timed("first ride frame (prepare + dispatch + readback)") { _ = gpu.render(ride, into: c) }
    timed("second ride frame (steady state)") { _ = gpu.render(ride, into: c) }
    var w1: World!
    timed("World(level:1) generation (the hidden build)") { w1 = World(level: 1, colonyIndex: 0, seed: 12345) }
    timed("first real-world frame (SDF field + textures)") { _ = gpu.render(w1, into: c) }
    timed("Sprites.shared bake (first access)") { _ = Sprites.shared.item(.medkit) }
    timed("first HUD draw") { HUD().draw(w1, into: c) }
    exit(0)
}

if let dir = ProcessInfo.processInfo.environment["CITADEL_SHOTS"] {
    Captures.run(outDir: dir)
    exit(0)
}

if ProcessInfo.processInfo.environment["CITADEL_MATERIALS"] != nil {
    MaterialPreview.run()
    exit(0)
}

// CITADEL_QUEENMOCK[=src.png] → mock the QUEEN as a flux-art billboard in the
// live lair render (env + real WorldLight), to judge the billboard direction.
if let v = ProcessInfo.processInfo.environment["CITADEL_QUEENMOCK"] {
    QueenMock.run(src: (v.isEmpty || v == "1") ? nil : v, outDir: nil)
    exit(0)
}

// CITADEL_QUEENMESH[=mesh.usdz] → rasterise the 3D queen mesh into the live lair
// (matched pinhole + perp-depth composite + per-pixel lighting), to judge 3D.
if let v = ProcessInfo.processInfo.environment["CITADEL_QUEENMESH"] {
    QueenMeshTest.run(meshPath: (v.isEmpty || v == "1") ? nil : v, outDir: nil)
    exit(0)
}

// CITADEL_MESHVERIFY → drive the REAL live renderer with a queen in view + dump
// one frame, to verify the in-game mesh-Queen wire-in headlessly.
if ProcessInfo.processInfo.environment["CITADEL_MESHVERIFY"] != nil {
    QueenMeshTest.verifyLive(outDir: nil)
    exit(0)
}

// CITADEL_DRONEMESH → look-test the DRONE mesh in the lair (4 facings), like QUEENMESH.
if ProcessInfo.processInfo.environment["CITADEL_DRONEMESH"] != nil {
    let m = Bundle.main.url(forResource: "drone", withExtension: "usdz")?.path
    let t = Bundle.main.url(forResource: "drone_basecolor", withExtension: "jpg")?.path
    QueenMeshTest.run(meshPath: m, texPath: t, height: 1.4, tag: "drone-lair", outDir: nil)
    exit(0)
}

// CITADEL_COLONISTMESH[=mesh.usdz] → load-test a fallen-colonist mesh in the lair
// (4 facings), like DRONEMESH. Tex via CITADEL_COLONISTTEX, out via CITADEL_COLONISTOUT.
// Confirms an updated/rigged mesh LOADS (bind-pose geometry) and shows its pose.
if let v = ProcessInfo.processInfo.environment["CITADEL_COLONISTMESH"] {
    let env = ProcessInfo.processInfo.environment
    let m = (v.isEmpty || v == "1") ? Bundle.main.url(forResource: "colonist_woman", withExtension: "usdz")?.path : v
    let t = env["CITADEL_COLONISTTEX"] ?? Bundle.main.url(forResource: "colonist_woman_basecolor", withExtension: "jpg")?.path
    QueenMeshTest.run(meshPath: m, texPath: t, height: 1.75, tag: "colonist", outDir: env["CITADEL_COLONISTOUT"])
    exit(0)
}

// CITADEL_CORPSES → drive the live renderer at each fallen colonist in a generated
// level (procedural-topple pose check). Out via CITADEL_COLONISTOUT.
if ProcessInfo.processInfo.environment["CITADEL_CORPSES"] != nil {
    QueenMeshTest.verifyColonists(outDir: ProcessInfo.processInfo.environment["CITADEL_COLONISTOUT"])
    exit(0)
}

// CITADEL_RIGPROBE[=mesh.usdz] → print the skeleton + skin-weight data ModelIO
// exposes from a rigged USDZ (groundwork for the humanoid poser).
if let v = ProcessInfo.processInfo.environment["CITADEL_RIGPROBE"] {
    RigProbe.run(path: (v.isEmpty || v == "1") ? nil : v)
    exit(0)
}

if let v = ProcessInfo.processInfo.environment["CITADEL_AUTOMAP"] {
    Automap.run(outDir: v.isEmpty || v == "1" ? nil : v)
    exit(0)
}

if let v = ProcessInfo.processInfo.environment["CITADEL_ROOMS"] {
    RoomShots.run(outDir: v.isEmpty || v == "1" ? nil : v)
    exit(0)
}

if let v = ProcessInfo.processInfo.environment["CITADEL_PROOFROOM"] {
    ProofRoom.run(outDir: v.isEmpty || v == "1" ? nil : v)
    exit(0)
}

if let v = ProcessInfo.processInfo.environment["CITADEL_RASTERSHOT"] {
    RasterRenderer.shot(outDir: v.isEmpty || v == "1" ? nil : v)
    exit(0)
}

// CITADEL_DORMDEBUG → dump a few generated levels as ASCII (walls #, doors +, floor ·,
// bunk B, locker L, column I, desk d, chair c, tape T, papers p, pipe =) to eyeball the
// dormitory layout algorithm (row alternation, centre rows, columns, clear aisles). No GUI.
if ProcessInfo.processInfo.environment["CITADEL_DORMDEBUG"] != nil {
    for lvl in [1, 2, 3, 4] {
        let g = MapGen.generate(level: lvl, colonyIndex: 0, seed: UInt64(lvl &* 2654435761 &+ 12345))
        let m = g.map
        var grid = [[Character]](repeating: [Character](repeating: " ", count: m.w), count: m.h)
        for y in 0..<m.h { for x in 0..<m.w {
            let i = m.idx(x, y)
            grid[y][x] = m.wall[i] != 0 ? (m.doors[i] != nil ? "+" : "#") : "·"
        } }
        for pr in g.props {
            let x = Int(pr.pos.x), y = Int(pr.pos.y)
            guard x >= 0, y >= 0, y < m.h, x < m.w else { continue }
            switch pr.kind {
            case .bunk: grid[y][x] = "B"; case .locker: grid[y][x] = "L"; case .column: grid[y][x] = "I"
            case .desk: grid[y][x] = "d"; case .chair: grid[y][x] = "c"; case .tapeDeck: grid[y][x] = "T"
            case .papers: grid[y][x] = "p"; case .wallPipe: grid[y][x] = "="
            case .console: grid[y][x] = "O"
            case .cabinet: grid[y][x] = "n"; case .sink: grid[y][x] = "s"
            case .range: grid[y][x] = "R"; case .canteenTable: grid[y][x] = "t"
            }
        }
        let boardCells = (0..<(m.w * m.h)).filter { m.wall[$0] == WallTex.opsBoard.rawValue }.count
        let medCells = (0..<(m.w * m.h)).filter { m.wall[$0] == WallTex.medWall.rawValue }.count
        let beds = g.props.filter { $0.kind == .bunk }.count
        let stainless = g.props.filter { $0.kind == .cabinet || $0.kind == .sink }.count
        let tiles = (0..<(m.w * m.h)).filter { m.wall[$0] == WallTex.subwayTile.rawValue }.count
        let tables = g.props.filter { $0.kind == .canteenTable }.count
        let ranges = g.props.filter { $0.kind == .range }.count
        let consoles = g.props.filter { $0.kind == .console }.count
        print("=== LEVEL \(lvl)  \(m.w)x\(m.h)  props=\(g.props.count) items=\(g.items.count) drums=\(g.drums.count) opsRoom=\(MapGen.debugOpsRoom) board=\(boardCells) consoles=\(consoles) medWalls=\(medCells) beds=\(beds) stainless=\(stainless) tiles=\(tiles) tables=\(tables) range=\(ranges) ===")
        for row in grid { print(String(row)) }
        print("")
    }
    exit(0)
}

if let v = ProcessInfo.processInfo.environment["CITADEL_DISPLAYVID"] {
    let fault = v.hasPrefix("fault")                          // "fault" or "fault:<dir>" stages an electrical fault mid-clip
    let path = v.hasPrefix("fault:") ? String(v.dropFirst(6))
             : (v.isEmpty || v == "1" || v == "fault" ? nil : v)
    DisplayVid.run(outDir: path, fault: fault)
    exit(0)
}

// CITADEL_TITLESHOT[=path] → render the title screen to a PNG (default ~/Desktop),
// then exit. A no-window way to preview the front-end art without launching.
if let v = ProcessInfo.processInfo.environment["CITADEL_TITLESHOT"] {
    let out = (v.isEmpty || v == "1") ? NSHomeDirectory() + "/Desktop/citadel-title.png" : v
    let c = Canvas2D()
    FrontEnd.title(c, t: 3.0, hs: HighScores(), pad: false)
    Captures.writePNG(c.framebuffer, w: RenderConfig.width, h: RenderConfig.height, scale: 1,
                      to: URL(fileURLWithPath: out))
    print("Citadel: wrote title screenshot to \(out)")
    exit(0)
}

// CITADEL_DECKCHECK → print how many SIGNAL decks each floor gets (verify the
// rarity: 1–2 per building, floors 1–5 only, none on 6–8).
if ProcessInfo.processInfo.environment["CITADEL_DECKCHECK"] != nil {
    for base in [UInt64(1000), 2000, 3000] {
        var deckLine = "base \(base) decks:", paperLine = "base \(base) papers:"
        for level in 1...8 {
            let w = World(level: level, colonyIndex: Progression.planetIndex(level), seed: base &+ UInt64(level))
            deckLine += " L\(level)=\(w.props.filter { $0.kind == .tapeDeck }.count)"
            let pProps = w.props.filter { $0.kind == .papers }.count
            let pDecals = w.decals.filter { $0.w > 3.0 }.count       // papers render as w>3 decals (buildAftermath)
            paperLine += " L\(level)=\(pProps)prop/\(pDecals)decal"
        }
        print(deckLine); print(paperLine)
    }
    exit(0)
}

// CITADEL_CLUSTERSHOT[=path] → render the loop-payoff (cluster-fallen) card over
// teleport static to a PNG, so the end-of-cluster beat can be judged without
// playing to floor 48. VESPER (the sixth citadel) → the roll-back to DEMETER.
if let v = ProcessInfo.processInfo.environment["CITADEL_CLUSTERSHOT"] {
    let out = (v.isEmpty || v == "1") ? NSHomeDirectory() + "/Desktop/citadel-cluster.png" : v
    let world = World(level: 48, colonyIndex: 5, seed: 4848)
    let c = Canvas2D()
    StaticFX.fill(c, t: 2.0)
    FrontEnd.clusterCard(c, world: world, t: 2.0)
    Captures.writePNG(c.framebuffer, w: RenderConfig.width, h: RenderConfig.height, scale: 1,
                      to: URL(fileURLWithPath: out))
    print("Citadel: wrote cluster card to \(out)")
    exit(0)
}

// CITADEL_TERMSHOT[=dir] → render each terminal easter egg + the guru meditation
// to PNGs (default ~/Desktop), then exit. Previews the amber CRT without playing.
if let v = ProcessInfo.processInfo.environment["CITADEL_TERMSHOT"] {
    let dir = (v.isEmpty || v == "1") ? NSHomeDirectory() + "/Desktop" : v
    func write(_ c: Canvas2D, _ name: String) {
        Captures.writePNG(c.framebuffer, w: RenderConfig.width, h: RenderConfig.height, scale: 1,
                          to: URL(fileURLWithPath: dir + "/\(name).png"))
    }
    func shot(_ egg: TerminalEgg?, _ name: String, page: Int = 0, _ t: Float) {
        let c = Canvas2D()
        c.fillRect(0, 0, c.width, c.height, packRGBA(34, 38, 44))   // stand-in room behind the terminal
        Terminal.draw(c, egg: egg, page: page, scale: 1, t: t)
        write(c, name)
    }
    // the text eggs (page 1) + guru (skip the mini-game — it draws itself, below)
    for (i, egg) in TerminalEgg.all.enumerated() where egg.kind != .miniGame { shot(egg, "term-\(i)", 0.3) }
    shot(nil, "term-guru", 0.0)
    // a later Director's Log page — shows the ◀ PAGE n / N ▶ paging footer
    shot(TerminalEgg.all[0], "term-log-p2", page: 2, 0.3)
    // the arcade mini-game — three staged states, in the same CRT
    ArcadeScores.shared.harnessSeed([
        ArcadeEntry(name: "ARC", score: 4820), ArcadeEntry(name: "JON", score: 3260),
        ArcadeEntry(name: "CPL", score: 2140), ArcadeEntry(name: "MUM", score: 1780),
        ArcadeEntry(name: "DAD", score: 990),
    ])
    func shotGame(_ name: String, _ t: Float, _ setup: (SpaceInvaders) -> Void) {
        let c = Canvas2D()
        c.fillRect(0, 0, c.width, c.height, packRGBA(34, 38, 44))
        let g = SpaceInvaders(); setup(g)
        let f = Terminal.frame(c, scale: 1, t: t, guru: false)
        g.draw(c, f.x0, f.y0, f.sw, f.sh, a: 1, t: t)
        write(c, name)
    }
    shotGame("inv-play", 0.2) { $0.harnessMidPlay() }
    shotGame("inv-initials", 0.2) { $0.harnessInitials(score: 3260) }
    shotGame("inv-scores", 0.2) { $0.harnessScoreboard() }
    print("Citadel: wrote terminal shots + guru + 3 arcade frames to \(dir)")
    exit(0)
}

#endif  // CITADEL_HARNESS

// Single-instance guard. Two live copies each sphere-trace the scene and contend
// for the GPU + the per-frame readback — enough stacked instances will drag the
// whole machine to a beachball (a real hazard during rapid dev relaunches). If
// another Citadel is already running, hand focus to it and bow out. Headless
// modes (smoke / captures) have already exited above, so this only gates the GUI.
if let bundleID = Bundle.main.bundleIdentifier {
    let mine = NSRunningApplication.current.processIdentifier
    let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .first { $0.processIdentifier != mine }
    if let other {
        other.activate()
        exit(0)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
