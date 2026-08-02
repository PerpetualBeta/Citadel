// Citadel — headless screenshot harness (CITADEL_SHOTS[=dir]).
//
// Drives the real CPU draw path with no window and writes upscaled PNGs for the
// product page / README. Also exposes the PNG writer used by the in-game
// screenshot key.

import Foundation
import AppKit
import Metal

enum Captures {
    static func run(outDir: String?) {
        let dir = URL(fileURLWithPath: outDir ?? FileManager.default.currentDirectoryPath
                        .appending("/docs/screenshots"))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scale = ProcessInfo.processInfo.environment["CITADEL_SHOT_SCALE"].flatMap { Int($0) } ?? 4
        var n = 0
        func save(_ c: Canvas2D, _ label: String) {
            n += 1
            let name = String(format: "%02d-%@.png", n, label)
            writePNG(c.framebuffer, w: RenderConfig.width, h: RenderConfig.height, scale: scale,
                     to: dir.appendingPathComponent(name))
            print("  wrote \(name)")
        }

        let hs = HighScores()
        let audio = AudioEngine()
        audio.muted = true                        // harnesses are SILENT — they get run in offices
        // render the 3-D view through the GPU renderer (every Mac has a Metal device)
        let gpu = MTLCreateSystemDefaultDevice().flatMap { RasterRenderer(device: $0) }
        func draw3D(_ w: World, into c: Canvas2D) { _ = gpu?.render(w, into: c) }

        // title
        let title = Canvas2D(); FrontEnd.title(title, t: 0.2, hs: hs); save(title, "title")

        // gameplay — build a world, fight a little, draw
        let world = World(level: 3, colonyIndex: 4, seed: 90210)
        let input = InputState(); input.kb.forward = true; input.kb.fire = true
        for _ in 0..<90 { world.update(dt: 1.0 / 60, input: input, audio: audio); if world.player.dead { break } }
        // showcase the plasma rifle mid-fire for the marketing shot
        world.player.giveWeapon(.plasma); world.player.giveAmmo(.cells, 40)
        world.player.current = .plasma; world.player.fireAnim = 0.15; world.player.muzzle = 0.06
        // face the marine down the clearest sightline and stand a fuel drum in it,
        // so the marketing shot showcases a world prop (never buried in a wall)
        let dm0 = world.map
        func clearAhead(_ ang: Float, _ dist: Float) -> Bool {
            let dv = SIMD2<Float>(cos(ang), sin(ang)); var t: Float = 0.4
            while t <= dist {
                let cx = Int(world.player.pos.x + dv.x * t), cy = Int(world.player.pos.y + dv.y * t)
                if !dm0.inBounds(cx, cy) || dm0.wall[dm0.idx(cx, cy)] != 0 { return false }
                t += 0.3
            }
            return true
        }
        // …AND SOMETHING TO SHOOT AT. The shot the README leads its gameplay row with was a fuel drum
        // alone in an empty corridor — an honest picture of the renderer and a poor picture of the
        // GAME. A drone put down the same sightline gives the frame the thing it is about. Placed
        // rather than waited for: a marketing frame that depends on the AI wandering into view is one
        // that silently becomes empty the day generation shifts.
        //
        // The reach DEGRADES rather than failing. Asking for a single fixed 4.4-cell sightline found
        // no angle at all on this seed, so nothing was placed and the marine was left facing a wall —
        // a staging requirement that can fail closed will eventually produce a blank marketing shot
        // with nobody watching. Longest first, and the drone stands wherever the winning reach allows.
        for reach in [Float(4.4), 3.4, 2.7] {
            guard let ang = (0..<24).lazy
                    .map({ world.player.dir + Float($0) * (.pi * 2 / 24) })
                    .first(where: { clearAhead($0, reach) }) else { continue }
            world.player.dir = ang
            let dv = SIMD2<Float>(cos(ang), sin(ang))
            world.drums.append(Drum(pos: world.player.pos + dv * (reach * 0.52), fuel: 150, health: 24))
            if let di = world.monsters.firstIndex(where: { $0.kind == .alien }) {
                world.monsters[di].pos = world.player.pos + dv * (reach * 0.88)
                world.monsters[di].dir = ang + .pi          // facing the marine
                world.monsters[di].state = .chase
            }
            break
        }
        let game = Canvas2D()
        draw3D(world, into: game)
        HUD().draw(world, into: game)
        save(game, "combat")

        // fire — the build's money shot: the flamethrower's fat gout down the aim,
        // a drone caught in the stream and burning. Reuses the combat world (its
        // sightline is already validated clear); staged directly so it's
        // deterministic. Explicit filename so the 03–09 doc numbering doesn't shift.
        world.drums.removeAll()                                   // clear the plasma-shot's drum
        world.player.giveWeapon(.flamethrower); world.player.giveAmmo(.fuel, 200)
        world.player.current = .flamethrower
        world.player.fireAnim = 0.12; world.player.muzzle = 0.06
        let fdir = SIMD2<Float>(cos(world.player.dir), sin(world.player.dir))
        // a drone in the stream, mid-pyre (0 < burn < 1 → a live, flaring fire)
        if let di = world.monsters.firstIndex(where: { $0.kind == .alien }) {
            world.monsters[di].pos = world.player.pos + fdir * 2.4
            world.monsters[di].state = .dead
            world.monsters[di].burn = 0.4
        }
        // the live jet down the aim, clipped at the first wall (as World.fire does)
        let fnozzle = world.player.pos + fdir * 0.35 + SIMD2(-fdir.y, fdir.x) * Viewmodel.anchorRight
        var freach: Float = 6, fprobe = fnozzle, ftrav: Float = 0
        while ftrav < 6 { fprobe += fdir * 0.15; ftrav += 0.15
            if world.map.blocksMovement(Int(fprobe.x), Int(fprobe.y)) { freach = ftrav; break } }
        world.flameJet = World.FlameJet(t: 0.10, nozzle: fnozzle, dir: fdir, reach: freach)
        let fire = Canvas2D()
        draw3D(world, into: fire)
        HUD().draw(world, into: fire)
        writePNG(fire.framebuffer, w: RenderConfig.width, h: RenderConfig.height, scale: scale,
                 to: dir.appendingPathComponent("13-fire.png"))
        print("  wrote 13-fire.png")

        // atmosphere — THE PLANT FLOORS (7–8) ARE LIT BY WALL BULKHEADS, not by the ceiling grid the
        // surface floors use, and a long straight corridor lined with them is the clearest statement
        // the game makes about its lighting: warm amber pools falling away into the dark, every one
        // thrown by a fixture you can see. The old shot dropped the marine into the darkest cell of a
        // SURFACE floor facing the Queen's lair — where the auto-ramping helmet lamp compensates, so
        // the frame came back looking like an ordinary lit corridor. Technically honest, and a poor
        // advertisement for the one thing it existed to show.
        // Swept across BOTH plant floors and several seeds, because one floor's corridors are not
        // guaranteed to carry fixtures: the depths lose most of their lamps by design, and a single
        // hard-coded seed produced first a black rock tunnel and then a built corridor with no lamp
        // on it at all. The sweep picks the best corridor that actually exists rather than hoping.
        var aw = World(level: 7, colonyIndex: 0, seed: 5150)
        var runBest = (lamps: 0, len: 0, sx: 0, sy: 0, dx: 1, dy: 0)
        for lvl in [7, 8] {
            for sd in [5150, 7, 31, 404, 1234, 90210] {
                let w = World(level: lvl, colonyIndex: 0, seed: UInt64(sd))
                let m = w.map
                func openA(_ x: Int, _ y: Int) -> Bool {
                    m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil
                }
                // The flanks must be BUILT wall, not blasted rock: the fixtures are bolted to the
                // built sections, and the depths deliberately lose most of their lamps.
                let rock: Set<Int> = [WallTex.stone.rawValue, WallTex.stoneSteel.rawValue]
                func builtWall(_ x: Int, _ y: Int) -> Bool {
                    guard m.inBounds(x, y) else { return false }
                    let t = m.wall[m.idx(x, y)]
                    return t != 0 && !rock.contains(t)
                }
                let sites = LevelMeshBuilder.plantLampSites(m).map { $0.pos }
                for (dx, dy) in [(1, 0), (0, 1)] {
                    let px = dy, py = dx
                    for y in 1..<(m.h - 1) {
                        for x in 1..<(m.w - 1) {
                            var n = 0
                            while openA(x + dx * n, y + dy * n),
                                  builtWall(x + dx * n + px, y + dy * n + py),
                                  builtWall(x + dx * n - px, y + dy * n - py) { n += 1 }
                            guard n >= 4 else { continue }
                            let lit = sites.filter { pt in
                                let t = Float(dx) * (pt.x - Float(x)) + Float(dy) * (pt.y - Float(y))
                                let off = abs(Float(px) * (pt.x - Float(x) - 0.5) + Float(py) * (pt.y - Float(y) - 0.5))
                                return t >= -0.5 && t <= Float(n) + 1.5 && off < 2.2
                            }.count
                            if (lit, n) > (runBest.lamps, runBest.len) {
                                runBest = (lit, n, x, y, dx, dy); aw = w
                            }
                        }
                    }
                }
            }
        }
        if runBest.len >= 4 {
            aw.player.pos = SIMD2(Float(runBest.sx) + 0.5, Float(runBest.sy) + 0.5)
            aw.player.dir = atan2(Float(runBest.dy), Float(runBest.dx))
        }
        aw.player.giveWeapon(.plasma); aw.player.current = .plasma
        aw.player.muzzle = 0; aw.player.fireAnim = 0
        let dark = Canvas2D()
        draw3D(aw, into: dark)
        HUD().draw(aw, into: dark)
        writePNG(dark.framebuffer, w: RenderConfig.width, h: RenderConfig.height, scale: scale,
                 to: dir.appendingPathComponent("16-atmosphere.png"))
        print("  wrote 16-atmosphere.png (floor \(Progression.floorInBuilding(aw.level)), "
              + "\(runBest.len)-cell corridor, \(runBest.lamps) bulkheads)")

        // door — part a sliding door halfway and frame it head-on from a couple
        // cells back, so the centre-split (two panels retracting to the jambs, the
        // room showing through the slit) reads unmistakably. Pick a door with a
        // clear run of open floor on BOTH sides — no second door in the sightline.
        let dworld = World(level: 2, colonyIndex: 1, seed: 24680)
        let dmap = dworld.map
        func clearRun(_ dx: Int, _ dy: Int, _ ax: Int, _ ay: Int) -> Bool {
            for k in 1...3 {
                let x = dx + ax * k, y = dy + ay * k
                if dmap.wallAt(x, y) != 0 || dmap.isDoorCell(x, y) { return false }
            }
            return true
        }
        for di in dmap.doors.keys.sorted() {
            let dx = di % dmap.w, dy = di / dmap.w
            // passage axis = the one whose two sides are both clear (no adjacent door)
            let ax: Int, ay: Int
            if clearRun(dx, dy, -1, 0) && clearRun(dx, dy, 1, 0) { ax = -1; ay = 0 }
            else if clearRun(dx, dy, 0, -1) && clearRun(dx, dy, 0, 1) { ax = 0; ay = -1 }
            else { continue }
            dmap.doors[di]!.open = 0.35                      // caught mid-part
            dworld.player.pos = SIMD2(Float(dx + ax * 2) + 0.5, Float(dy + ay * 2) + 0.5)
            dworld.player.dir = atan2(Float(-ay), Float(-ax))    // face the door
            dworld.player.muzzle = 0
            break
        }
        let door = Canvas2D()
        draw3D(dworld, into: door)
        HUD().draw(dworld, into: door)
        writePNG(door.framebuffer, w: RenderConfig.width, h: RenderConfig.height, scale: scale,
                 to: dir.appendingPathComponent("12-door.png"))
        print("  wrote 12-door.png")

        // intel (every page of the codex) + briefing + the in-car floor report + high scores
        gpu?.renderPortraits()                    // the mesh dossier busts the codex shows
        ItemIcons.ensureRendered()               // the SDF pickup icons (match in-world geometry)
        for page in 0..<FrontEnd.intelPages {
            let intel = Canvas2D(); FrontEnd.intel(intel, t: 5.0, page: page); save(intel, "intel-\(page + 1)")
        }
        let brief = Canvas2D(); FrontEnd.briefing(brief, t: 0.5); save(brief, "briefing")
        // FLOOR CLEARED, with a tally it actually EARNED. This card used to be drawn over the same
        // lightly-simulated world as the combat shot, so it advertised a cleared floor with 0/20
        // kills, 0/1 secrets and a score of zero — a screenshot that reads as a bug report. The tally
        // is not faked in: drones are walked in front of the marine and genuinely shot, so `World`
        // does the damage, the deaths and the scoring by its own rules and the numbers on the card
        // are ones the sim produced. A marketing frame may be staged; it may not lie.
        // …in its OWN world. Reusing the combat world meant inheriting three shots' worth of staging:
        // a drone forced to `.dead` for the fire frame (which bypasses `damageMonster`, so the HUD's
        // live-state count and the card's `killCount` legitimately disagreed), a spent flamethrower,
        // and a camera parked in the darkest cell for the atmosphere frame. A summary card wants a
        // clean floor behind it.
        let cw = World(level: 3, colonyIndex: 4, seed: 90210)
        cw.player.giveWeapon(.plasma); cw.player.current = .plasma
        let killInput = InputState(); killInput.kb.fire = true
        for _ in 0..<9 {
            guard let di = cw.monsters.firstIndex(where: { $0.alive && $0.kind == .alien }) else { break }
            let dv = SIMD2<Float>(cos(cw.player.dir), sin(cw.player.dir))
            cw.monsters[di].pos = cw.player.pos + dv * 2.6
            cw.player.giveAmmo(.cells, 40)
            var frames = 0
            while cw.monsters[di].alive && frames < 400 {
                cw.player.health = Player.maxHealth             // the marine is not the subject here
                cw.update(dt: 1.0 / 60, input: killInput, audio: audio)
                frames += 1
            }
        }
        cw.player.health = Player.maxHealth
        cw.player.muzzle = 0; cw.player.fireAnim = 0
        let cleared = Canvas2D()
        draw3D(cw, into: cleared)
        HUD().draw(cw, into: cleared)
        FrontEnd.descendReport(cleared, world: cw, t: 1.0)      // the diegetic panel shown inside the exit car
        save(cleared, "cleared")
        let scores = Canvas2D(); FrontEnd.highScores(scores, hs: hs, t: 0.5); save(scores, "highscores")

        // weapon contact sheet — the three SDF viewmodels rendered IN-WORLD:
        // each weapon held (idle) in the same scene, full frame, so the sheet
        // documents the real first-person look — lighting, materials and all
        world.player.fireAnim = 0; world.player.muzzle = 0
        world.player.giveWeapon(.flamethrower); world.player.giveWeapon(.rocket)
        for k in 0..<24 {                        // face the clearest sightline again
            let ang = world.player.dir + Float(k) * (.pi * 2 / 24)
            if clearAhead(ang, 3.2) { world.player.dir = ang; break }
        }
        let wW = RenderConfig.width, wH = RenderConfig.height
        let wsheet = Canvas2D(width: WeaponKind.allCases.count * wW, height: wH)
        for (i, k) in WeaponKind.allCases.enumerated() {
            world.player.current = k
            let frame = Canvas2D()
            draw3D(world, into: frame)
            for y in 0..<wH {
                memcpy(wsheet.framebuffer + (y * wsheet.width + i * wW), frame.framebuffer + y * wW,
                       wW * MemoryLayout<UInt32>.stride)
            }
            wsheet.label(k.def.name, i * wW + 24, 20, size: 28, color: packRGBA(236, 202, 96), weight: .bold)
        }
        writePNG(wsheet.framebuffer, w: wsheet.width, h: wsheet.height, scale: 1, to: dir.appendingPathComponent("14-weapons.png"))
        print("  wrote 14-weapons.png")

        // The pickup-icon and world-hardware CONTACT SHEETS used to be written here (15-items,
        // 11-props). Both drew from `Sprites` — the billboard-era icon art — and Jonathan pulled them
        // from the README because they no longer match the game: the rasteriser draws drums, mines,
        // sockets and pickups as real geometry, so a sheet of the old sprites documents something
        // that is not on screen any more. `Sprites` itself stays (the codex still falls back to it),
        // but a reference sheet that shows the wrong thing is worse than no sheet at all.

        print("Citadel: wrote \(n) screenshots to \(dir.path)")
    }

    /// Upscale the framebuffer `scale`× nearest-neighbour and write a PNG.
    static func writePNG(_ fb: UnsafeMutablePointer<UInt32>, w: Int, h: Int, scale: Int, to url: URL) {
        guard let native = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32),
              let dst = native.bitmapData else { return }
        memcpy(dst, fb, w * h * 4)
        let uw = w * scale, uh = h * scale
        guard let big = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: uw, pixelsHigh: uh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: uw * 4, bitsPerPixel: 32),
              let ctx = NSGraphicsContext(bitmapImageRep: big) else { return }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .none
        native.draw(in: NSRect(x: 0, y: 0, width: uw, height: uh), from: .zero,
                    operation: .copy, fraction: 1, respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.none.rawValue])
        guard let png = big.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}

// Citadel — animated computer-display preview (CITADEL_DISPLAYVID[=dir]).
//
// Finds a computer-bank wall, stands facing it, and renders a time-sequence of
// frames (the screens animate off `world.elapsed`, the shader's `time`) as PNGs
// for ffmpeg to stitch into a silent preview video — a headless, muted "sneak
// peek" with no game window.
enum DisplayVid {
    // `fault` stages an electrical fault mid-clip (the lights sag + the screens
    // stutter, then recover) so the fault-stutter behaviour can be captured.
    static func run(outDir: String?, fault: Bool = false) {
        let dir = URL(fileURLWithPath: outDir ?? NSHomeDirectory() + "/Desktop/Citadel-DisplayVid")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let device = MTLCreateSystemDefaultDevice(), let gpu = RasterRenderer(device: device) else {
            print("Citadel: no Metal device for display video"); return
        }
        let W = RenderConfig.width, H = RenderConfig.viewHeight

        // Find a level/seed with a computer bank + a clear standing spot facing it,
        // BACKED OFF so the whole bank frames and the headlamp doesn't blow it out.
        // Levels 1–4 render lit without ticking (the "5+ black" harness quirk).
        var chosen: (world: World, pos: SIMD2<Float>, dir: Float)?
        search: for lvl in 1...4 { for seed in UInt64(1)...12 {
            let world = World(level: lvl, colonyIndex: 0, seed: seed)
            func openReach(_ c: SIMD2<Float>) -> Bool {
                let x = Int(c.x), y = Int(c.y)
                return world.map.inBounds(x, y) && !world.map.blocksMovement(x, y)
            }
            for y in 0..<world.map.h { for x in 0..<world.map.w {
                if world.map.wall[world.map.idx(x, y)] != WallTex.computer.rawValue { continue }
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    guard world.map.inBounds(x + dx, y + dy),
                          world.map.wall[world.map.idx(x + dx, y + dy)] == 0 else { continue }
                    let target = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)   // the bank on the wall
                    let baseAng = atan2(Float(dy), Float(dx))                    // room-ward normal
                    for back in [Float(3.2), 2.7, 2.2, 1.7] {
                        for aoff in [Float(0), 0.30, -0.30] {                    // straight back, then a little angle
                            let cam = target + SIMD2(cos(baseAng + aoff), sin(baseAng + aoff)) * back
                            if openReach(cam) && openReach((cam + target) * 0.5) {   // cam + the path to it are clear
                                chosen = (world, cam, atan2(target.y - cam.y, target.x - cam.x))
                                break search
                            }
                        }
                    }
                }
            }}
        }}
        guard let c = chosen else { print("Citadel: no computer-bank wall found (levels 1–4, 12 seeds)"); return }

        let world = c.world
        world.monsters = []; world.items = []; world.props = []   // clean product shot — no actors/pickups/furniture in frame
        world.drums = []; world.sockets = []
        world.player.pos = c.pos; world.player.dir = c.dir; world.player.muzzle = 0
        world.player.dead = true                              // suppress the held weapon (render gates the viewmodel on this, nothing else here)
        let canvas = Canvas2D()
        let fps = 30, secs = 6, frames = fps * secs
        for f in 0..<frames {
            world.elapsed = Float(f) / Float(fps)             // advance the shader's `time` — the displays animate
            if fault {                                        // stage a fault at t≈2s: lights sag + screens stutter, then recover by ~4.4s
                let fe = world.elapsed - 2.0
                var dim: Float = 0
                if fe > 0, fe < 2.4 {
                    let env = fe < 0.18 ? fe / 0.18 : max(0, 1 - (fe - 0.18) / 2.2)   // fast onset, slow decay
                    dim = min(0.72, env * (0.55 + 0.45 * abs(sinf(fe * 34) * sinf(fe * 11 + 1.3))))  // erratic flicker on top
                }
                world.powerDim = dim
            }
            _ = gpu.render(world, into: canvas)
            Captures.writePNG(canvas.framebuffer, w: W, h: H, scale: 1,
                              to: dir.appendingPathComponent(String(format: "frame-%04d.png", f)))
        }
        print("Citadel: wrote \(frames) frames (\(secs)s @ \(fps)fps) to \(dir.path)")
    }
}
