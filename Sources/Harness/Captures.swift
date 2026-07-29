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
        for k in 0..<24 {
            let ang = world.player.dir + Float(k) * (.pi * 2 / 24)
            if clearAhead(ang, 2.7) {
                world.player.dir = ang
                let dv = SIMD2<Float>(cos(ang), sin(ang))
                world.drums.append(Drum(pos: world.player.pos + dv * 2.3, fuel: 150, health: 24))
                break
            }
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

        // atmosphere — drop the marine into the darkest cell of the level, facing
        // the Queen's lair, so the auto-headlamp does the seeing. Showcases the
        // dark pass; explicit filename so the 03–09 doc references don't shift.
        var darkI = -1; var darkL = Float.greatestFiniteMagnitude
        let dm = world.map
        for i in 0..<(dm.w * dm.h) where dm.wall[i] == 0 && dm.doors[i] == nil {
            let c = dm.lightColor[i]; let l = c.x * 0.299 + c.y * 0.587 + c.z * 0.114
            if l < darkL { darkL = l; darkI = i }
        }
        if darkI >= 0 {
            world.player.pos = SIMD2(Float(darkI % dm.w) + 0.5, Float(darkI / dm.w) + 0.5)
            if let q = world.monsters.first(where: { $0.kind == .queen }) {
                world.player.dir = atan2(q.pos.y - world.player.pos.y, q.pos.x - world.player.pos.x)
            }
        }
        world.player.muzzle = 0
        let dark = Canvas2D()
        draw3D(world, into: dark)
        HUD().draw(world, into: dark)
        writePNG(dark.framebuffer, w: RenderConfig.width, h: RenderConfig.height, scale: scale,
                 to: dir.appendingPathComponent("10-atmosphere.png"))
        print("  wrote 10-atmosphere.png")

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
        let cleared = Canvas2D()
        draw3D(world, into: cleared)
        HUD().draw(world, into: cleared)
        FrontEnd.descendReport(cleared, world: world, t: 1.0)   // the diegetic panel shown inside the exit car
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
        writePNG(wsheet.framebuffer, w: wsheet.width, h: wsheet.height, scale: 1, to: dir.appendingPathComponent("07-weapons.png"))
        print("  wrote 07-weapons.png")

        // item contact sheet
        let icols = 4, irows = (ItemKind.allCases.count + icols - 1) / icols
        let ispr = ItemKind.allCases.map { Sprites.shared.item($0) }
        let icw = (ispr.map { max($0.w, $0.h) }.max() ?? 1) + 24   // square cells, sized to sprites
        let isheet = Canvas2D(width: icols * icw, height: irows * icw)
        isheet.clear(packRGBA(26, 26, 32))
        for (i, _) in ItemKind.allCases.enumerated() {
            let spr = ispr[i]
            let gx = (i % icols) * icw, gy = (i / icols) * icw
            isheet.strokeRect(gx + 1, gy + 1, icw - 2, icw - 2, packRGBA(56, 58, 70))
            isheet.blitBitmap(spr.pixels, spr.w, spr.h, gx + (icw - spr.w) / 2, gy + (icw - spr.h) / 2)
        }
        writePNG(isheet.framebuffer, w: icols * icw, h: irows * icw, scale: 2, to: dir.appendingPathComponent("08-items.png"))
        print("  wrote 08-items.png")

        // (the creatures' dossier busts are the mesh portraits shown in the codex —
        //  see the Field Intel pages below; there is no SDF monster contact sheet.)

        // prop contact sheet — the fuel drum + proximity mine
        let pspr = PropKind.allCases.map { Sprites.shared.prop($0) }
        let pcw = (pspr.map { $0.w }.max() ?? 1) + 24
        let ph = (pspr.map { $0.h }.max() ?? 1) + 28
        let psheet = Canvas2D(width: PropKind.allCases.count * pcw, height: ph)
        psheet.clear(packRGBA(22, 22, 28))
        for (i, k) in PropKind.allCases.enumerated() {
            let spr = pspr[i]
            let gx = i * pcw
            psheet.strokeRect(gx + 1, 1, pcw - 2, ph - 2, packRGBA(56, 58, 70))
            psheet.blitBitmap(spr.pixels, spr.w, spr.h, gx + (pcw - spr.w) / 2, ph - spr.h - 8)
            let name: String
            switch k {
            case .fuelDrum: name = "FUEL DRUM"
            case .proxMine: name = "PROX MINE"
            case .socket:   name = "RECHARGE"
            }
            psheet.label(name, gx + 6, ph - 16, size: 12, color: packRGBA(236, 200, 150), weight: .bold)
        }
        writePNG(psheet.framebuffer, w: PropKind.allCases.count * pcw, h: ph, scale: 2, to: dir.appendingPathComponent("11-props.png"))
        print("  wrote 11-props.png")

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
