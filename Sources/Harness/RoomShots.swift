// Citadel — furnished-room capture (CITADEL_ROOMS[=dir]).
//
// A dev harness for judging the room set-dressing: for a few levels it finds the
// densest cluster of furniture, drops the camera at the far side of that room and
// looks back across it, then renders the live GPU view (no HUD, no weapon) so the
// bunks / desks / lockers / pipe runs can be eyeballed in situ.

import Foundation
import AppKit
import Metal
import QuartzCore
import simd

enum RoomShots {
    static func run(outDir: String?) {
        let dir = URL(fileURLWithPath: outDir ?? NSHomeDirectory() + "/Desktop/Citadel-Rooms")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let device = MTLCreateSystemDefaultDevice(), let gpu = GPUWorldRenderer(device: device) else {
            print("Citadel: no Metal device for room shots"); return
        }
        let W = RenderConfig.width, H = RenderConfig.viewHeight
        var n = 0

        // ── furniture lineup — one of each kind, side by side in a bright room, for
        //    a clean read of every piece's geometry (the in-situ shots below judge
        //    placement; this judges the models themselves)
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 1)
            world.props = []
            let kinds = FurnitureKind.allCases
            let base = world.player.pos
            for (k, kind) in kinds.enumerated() {
                let lateral = (Float(k) - Float(kinds.count - 1) / 2) * 1.3
                world.props.append(Prop(kind: kind, pos: base + SIMD2(4.5, lateral), yaw: .pi / 2))  // front faces −x (camera)
            }
            world.player.dir = 0; world.player.muzzle = 0
            let canvas = Canvas2D()
            _ = gpu.render(world, into: canvas)
            n += 1
            Captures.writePNG(canvas.framebuffer, w: W, h: H, scale: 1, to: dir.appendingPathComponent("00-lineup.png"))
            print("  wrote 00-lineup.png — \(kinds.count) furniture kinds")
        }

        // ── drum cluster — aim at the densest fuel-drum cluster (the fuel-storage
        //    chamber stacks several) so the SDF barrels that replaced the old sprite
        //    get a clean look, across a couple of seeds for red/blue variety
        for (si, seed) in [UInt64(3), UInt64(9)].enumerated() {
            // drop ONE barrel on the start cell (guaranteed open + room-central, clear
            // line of sight) and stand back to frame it — the cleanest model check
            let world = World(level: 1, colonyIndex: 0, seed: seed)
            world.monsters = []; world.props = []; world.sockets = []
            // the marine now STARTS inside the arrival car — stage in the room
            let fwd0 = SIMD2<Float>(cos(world.player.dir), sin(world.player.dir))
            world.player.pos += fwd0 * 1.6
            let target = world.player.pos + fwd0 * 1.2
            world.drums = [Drum(pos: target, fuel: 150, health: 24)]
            func openLit(_ c: SIMD2<Float>) -> Bool {
                let x = Int(c.x), y = Int(c.y)
                guard world.map.inBounds(x, y), !world.map.blocksMovement(x, y) else { return false }
                let col = world.map.lightColor[world.map.idx(x, y)]
                return col.x * 0.299 + col.y * 0.587 + col.z * 0.114 > 0.3
            }
            var cam = target, found = false
            for back in [Float(2.3), 1.9, 1.5] where !found {
                for a in stride(from: Float(0), to: 6.28, by: 0.25) where !found {
                    let c = target + SIMD2(cos(a), sin(a)) * back
                    if openLit(c) { cam = c; found = true }
                }
            }
            world.player.pos = cam
            world.player.dir = atan2(target.y - cam.y, target.x - cam.x)
            world.player.muzzle = 0
            let canvas = Canvas2D()
            _ = gpu.render(world, into: canvas)
            n += 1
            let name = String(format: "00b-drums-%d.png", si)
            Captures.writePNG(canvas.framebuffer, w: W, h: H, scale: 1, to: dir.appendingPathComponent(name))
            print("  wrote \(name) — single barrel on the start cell")
        }

        // wall-pipe view — find a routed (piped) wall in a lit room, across seeds,
        // and frame it obliquely so the pipework reads
        var pipeShots = 0
        for seed in stride(from: UInt64(1), through: UInt64(60), by: 1) where pipeShots < 2 {
            let world = World(level: 1, colonyIndex: 0, seed: seed)
            world.monsters = []; world.drums = []; world.sockets = []
            let m = world.map
            func lum(_ i: Int) -> Float { let c = m.lightColor[i]; return c.x * 0.299 + c.y * 0.587 + c.z * 0.114 }
            var target: SIMD2<Float>? = nil
            for y in 0..<m.h { for x in 0..<m.w {
                let i = m.idx(x, y)
                if m.pipe[i] > 0.5 && m.wall[i] == 0 && m.doors[i] == nil && lum(i) > 0.6 { target = SIMD2(Float(x) + 0.5, Float(y) + 0.5) }
            } }
            guard let tgt = target else { continue }
            func openLit(_ c: SIMD2<Float>) -> Bool {
                let x = Int(c.x), y = Int(c.y)
                return m.inBounds(x, y) && !m.blocksMovement(x, y) && lum(m.idx(x, y)) > 0.35
            }
            var cam = tgt, ok = false
            for back in [Float(3.0), 2.4, 1.8] where !ok {
                for a in stride(from: Float(0), to: 6.28, by: 0.25) where !ok {
                    let c = tgt + SIMD2(cos(a), sin(a)) * back
                    if openLit(c) { cam = c; ok = true }
                }
            }
            guard ok else { continue }
            world.player.pos = cam
            world.player.dir = atan2(tgt.y - cam.y, tgt.x - cam.x)
            world.player.muzzle = 0
            let canvas = Canvas2D()
            _ = gpu.render(world, into: canvas)
            n += 1
            let name = String(format: "00c-pipes-%d.png", pipeShots)
            Captures.writePNG(canvas.framebuffer, w: W, h: H, scale: 1, to: dir.appendingPathComponent(name))
            print("  wrote \(name) — piped wall (seed \(seed))")
            pipeShots += 1
        }

        // flamethrower view — fire a few ticks (jet particles land in world space),
        // then render first-person + an oblique side view so the STREAM reads
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 4)
            world.monsters = []; world.drums = []; world.sockets = []; world.props = []
            world.player.current = .flamethrower
            world.player.ammo[AmmoType.fuel.rawValue] = 300
            world.player.pos += SIMD2<Float>(cos(world.player.dir), sin(world.player.dir)) * 1.6   // step out of the car
            let sp = world.player.pos
            let dirs = [SIMD2<Float>(1, 0), SIMD2<Float>(-1, 0), SIMD2<Float>(0, 1), SIMD2<Float>(0, -1)]
            var aim = dirs[0], bestClear: Float = 0
            for d in dirs { var t: Float = 0.5; while t < 6 && !world.map.blocksMovement(Int(sp.x + d.x * t), Int(sp.y + d.y * t)) { t += 0.25 }; if t > bestClear { bestClear = t; aim = d } }
            world.player.dir = atan2(aim.y, aim.x)
            let input = InputState(); input.kb.fire = true
            let audio = AudioEngine()
            audio.muted = true                        // harnesses are SILENT — they get run in offices
            for _ in 0..<8 { world.update(dt: 0.06, input: input, audio: audio) }   // build the jet
            func openLit(_ c: SIMD2<Float>) -> Bool {
                let x = Int(c.x), y = Int(c.y)
                guard world.map.inBounds(x, y), !world.map.blocksMovement(x, y) else { return false }
                let col = world.map.lightColor[world.map.idx(x, y)]; return col.x * 0.299 + col.y * 0.587 + col.z * 0.114 > 0.35
            }
            // first-person — what the player sees
            world.player.pos = sp; world.player.dir = atan2(aim.y, aim.x); world.player.muzzle = 0
            var canvas = Canvas2D(); _ = gpu.render(world, into: canvas); n += 1
            Captures.writePNG(canvas.framebuffer, w: W, h: H, scale: 1, to: dir.appendingPathComponent("00e-flame-fp.png"))
            // oblique — camera beside the jet so the stream length reads
            let perp = SIMD2<Float>(-aim.y, aim.x)
            var cam = sp - aim * 0.6 + perp * 1.8
            if !openLit(cam) { cam = sp - aim * 0.6 - perp * 1.8 }
            if openLit(cam) {
                let look = sp + aim * 1.7
                world.player.pos = cam; world.player.dir = atan2(look.y - cam.y, look.x - cam.x); world.player.muzzle = 0
                canvas = Canvas2D(); _ = gpu.render(world, into: canvas); n += 1
                Captures.writePNG(canvas.framebuffer, w: W, h: H, scale: 1, to: dir.appendingPathComponent("00e-flame-side.png"))
            }
            print("  wrote 00e-flame-fp/side.png — flamethrower jet")
        }

        // recharge-socket view — verify it's a flush WALL PANEL (not a floor unit):
        // stand in the room facing the wall it's mounted on
        for seed in stride(from: UInt64(1), through: UInt64(60), by: 1) {
            let world = World(level: 1, colonyIndex: 0, seed: seed)
            world.monsters = []; world.drums = []; world.props = []
            guard let sk = world.sockets.first else { continue }
            let m = world.map
            func openLit(_ c: SIMD2<Float>) -> Bool {
                let x = Int(c.x), y = Int(c.y)
                guard m.inBounds(x, y), !m.blocksMovement(x, y) else { return false }
                let col = m.lightColor[m.idx(x, y)]; return col.x * 0.299 + col.y * 0.587 + col.z * 0.114 > 0.4
            }
            guard openLit(sk.pos) else { continue }
            let inward = SIMD2<Float>(-sin(sk.yaw), cos(sk.yaw))   // panel faces this way; camera stands on this side
            var cam = sk.pos, ok = false
            for back in [Float(2.2), 1.8, 1.4] where !ok {
                let c = sk.pos + inward * back
                if openLit(c) { cam = c; ok = true }
            }
            guard ok else { continue }
            world.player.pos = cam
            world.player.dir = atan2(sk.pos.y - cam.y, sk.pos.x - cam.x)
            world.player.muzzle = 0
            let canvas = Canvas2D()
            _ = gpu.render(world, into: canvas)
            n += 1
            Captures.writePNG(canvas.framebuffer, w: W, h: H, scale: 1, to: dir.appendingPathComponent("00f-socket.png"))
            print("  wrote 00f-socket.png — wall recharge panel (seed \(seed))")
            break
        }

        // Scattered-papers view — records spilled flat on the deck near an office desk.
        // Stand a short way off and look at them so the floor fills the lower frame.
        for seed in stride(from: UInt64(1), through: UInt64(160), by: 1) {
            let world = World(level: 2, colonyIndex: 0, seed: seed)
            world.monsters = []; world.drums = []; world.sockets = []
            guard let pp = world.props.first(where: { $0.kind == .papers }) else { continue }
            let m = world.map
            func openLit(_ c: SIMD2<Float>) -> Bool {
                let x = Int(c.x), y = Int(c.y)
                guard m.inBounds(x, y), !m.blocksMovement(x, y) else { return false }
                let col = m.lightColor[m.idx(x, y)]; return col.x * 0.299 + col.y * 0.587 + col.z * 0.114 > 0.3
            }
            var cam = pp.pos, ok = false
            for r: Float in [1.8, 1.6, 2.0, 1.4] where !ok {   // a lit standpoint that still frames the flat decal ahead of the gun
                for a in stride(from: Float(0), to: 6.28, by: 0.4) {
                    let c = pp.pos + SIMD2<Float>(cos(a), sin(a)) * r
                    if openLit(c) { cam = c; ok = true; break }
                }
            }
            guard ok else { continue }
            world.player.pos = cam
            world.player.dir = atan2(pp.pos.y - cam.y, pp.pos.x - cam.x) + 0.42   // aim off to a side so the flat decal clears the gun
            world.player.muzzle = 0
            let canvas = Canvas2D()
            _ = gpu.render(world, into: canvas)
            n += 1
            Captures.writePNG(canvas.framebuffer, w: W, h: H, scale: 1, to: dir.appendingPathComponent("00m-papers.png"))
            print("  wrote 00m-papers.png — scattered papers near a desk (seed \(seed))")
            break
        }

        // reel-to-reel deck — find a MapGen-PLACED one (in a control/ops room) and
        // stand in front of it: verifies placement AND shows it in real context.
        // Model shot: inject a deck against a wall in a BRIGHT room and stand in front.
        // (MapGen placement into control/ops rooms is verified separately — populate()
        // logs a deck for every floor that has a terminal-bank room with space.)
        outerDeck: for seed in stride(from: UInt64(1), through: UInt64(120), by: 1) {
            let world = World(level: 1, colonyIndex: 0, seed: seed)
            world.monsters = []; world.drums = []; world.sockets = []; world.decals = []
            let m = world.map
            func openLit(_ x: Int, _ y: Int) -> Bool {
                guard m.inBounds(x, y), !m.blocksMovement(x, y) else { return false }
                let c = m.lightColor[m.idx(x, y)]; return c.x * 0.299 + c.y * 0.587 + c.z * 0.114 > 0.45
            }
            for y in 1..<(m.h - 1) { for x in 1..<(m.w - 1) where openLit(x, y) {
                for (dx, dy) in [(0, 1), (0, -1), (1, 0), (-1, 0)] {
                    guard m.blocksMovement(x - dx, y - dy), openLit(x + dx, y + dy), openLit(x + 2 * dx, y + 2 * dy) else { continue }
                    let pos = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                    world.props = [Prop(kind: .tapeDeck, pos: pos, yaw: atan2(-Float(dx), Float(dy)), againstWall: true)]
                    let cam = pos + SIMD2<Float>(Float(dx), Float(dy)) * 1.35
                    world.player.pos = cam; world.player.dir = atan2(pos.y - cam.y, pos.x - cam.x); world.player.muzzle = 0
                    let canvas = Canvas2D(); _ = gpu.render(world, into: canvas); n += 1
                    Captures.writePNG(canvas.framebuffer, w: W, h: H, scale: 1, to: dir.appendingPathComponent("00n-tapedeck.png"))
                    print("  wrote 00n-tapedeck.png — reel-to-reel deck model (seed \(seed))")
                    break outerDeck
                }
            }}
        }

        // terminal-bank view — verify the amber CRT wall: the monitor grid, baked
        // telemetry and the rolling refresh bar. Every office room gets a bank
        // (MapGen.placeTerminalBanks), so scan for one with standing room in
        // front (two open lit cells, so the bank fills the frame naturally).
        outer: for seed in stride(from: UInt64(1), through: UInt64(60), by: 1) {
            let world = World(level: 1, colonyIndex: 0, seed: seed)
            world.monsters = []; world.drums = []; world.props = []
            let m = world.map
            func openLit(_ x: Int, _ y: Int) -> Bool {
                guard m.inBounds(x, y), !m.blocksMovement(x, y) else { return false }
                let col = m.lightColor[m.idx(x, y)]
                return col.x * 0.299 + col.y * 0.587 + col.z * 0.114 > 0.4
            }
            for y in 1..<(m.h - 1) { for x in 1..<(m.w - 1) {
                guard m.wall[m.idx(x, y)] == WallTex.computer.rawValue else { continue }
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    guard openLit(x + dx, y + dy), openLit(x + 2 * dx, y + 2 * dy) else { continue }
                    let face = SIMD2<Float>(Float(x) + 0.5 + Float(dx) * 0.5, Float(y) + 0.5 + Float(dy) * 0.5)
                    let cam = SIMD2<Float>(Float(x) + 0.5 + Float(dx) * 2.2, Float(y) + 0.5 + Float(dy) * 2.2)
                    world.player.pos = cam
                    world.player.dir = atan2(face.y - cam.y, face.x - cam.x)
                    world.player.muzzle = 0
                    let canvas = Canvas2D()
                    _ = gpu.render(world, into: canvas)
                    n += 1
                    Captures.writePNG(canvas.framebuffer, w: W, h: H, scale: 1, to: dir.appendingPathComponent("00i-terminals.png"))
                    print("  wrote 00i-terminals.png — amber terminal bank (seed \(seed))")
                    break outer
                }
            }}
        }

        // exit-elevator view — the centre-split leaves closed, then parted: the
        // door plane sits at the room face and the leaf-anchored UVs must carry
        // each half's artwork (lamp, chevron, hazard edge) WITH its leaf.
        elev: for seed in stride(from: UInt64(1), through: UInt64(40), by: 1) {
            let world = World(level: 1, colonyIndex: 0, seed: seed)
            world.monsters = []; world.drums = []; world.props = []
            let m = world.map
            guard m.doors[m.exitCell] != nil else { continue }
            let ex = m.exitCell % m.w, ey = m.exitCell / m.w
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                guard m.inBounds(ex + dx, ey + dy), !m.blocksMovement(ex + dx, ey + dy),
                      m.inBounds(ex + 2 * dx, ey + 2 * dy), !m.blocksMovement(ex + 2 * dx, ey + 2 * dy) else { continue }
                let face = SIMD2<Float>(Float(ex) + 0.5, Float(ey) + 0.5)
                let cam = SIMD2<Float>(Float(ex) + 0.5 + Float(dx) * 2.2, Float(ey) + 0.5 + Float(dy) * 2.2)
                world.player.pos = cam
                world.player.dir = atan2(face.y - cam.y, face.x - cam.x)
                world.player.muzzle = 0
                for (oi, open) in [Float(0), GameMap.passThreshold].enumerated() {
                    world.map.doors[world.map.exitCell]!.open = open
                    let canvas = Canvas2D()
                    _ = gpu.render(world, into: canvas)
                    n += 1
                    let name = oi == 0 ? "00j-elevator-closed.png" : "00j-elevator-open.png"
                    Captures.writePNG(canvas.framebuffer, w: W, h: H, scale: 1, to: dir.appendingPathComponent(name))
                }
                let back = (ex - dx, ey - dy)
                print("  wrote 00j-elevator-closed/open.png — exit elevator (seed \(seed), "
                    + "wall id \(m.wall[m.exitCell]), back id \(m.inBounds(back.0, back.1) ? m.wall[m.idx(back.0, back.1)] : -1))")
                break elev
            }
        }

        // gib-remains view — the entrails a rocket kill leaves: gut ropes + small
        // torn gobbets pressed low to the deck, NOT furniture-scale slabs
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 1)
            world.monsters = []; world.drums = []; world.props = []
            let fwd = SIMD2<Float>(cos(world.player.dir), sin(world.player.dir))
            world.player.pos += fwd * 1.6                         // step out of the arrival car
            let side = SIMD2<Float>(-fwd.y, fwd.x)
            for off in [SIMD2<Float>(1.2, -0.4), SIMD2<Float>(1.8, 0.35)] {
                let gp = world.player.pos + fwd * off.x + side * off.y
                world.decals.append(SIMD4(gp.x, gp.y, 0.7, -2.85))
                world.decals.append(SIMD4(gp.x + 0.4, gp.y - 0.3, 0.4, -2.6))
                world.decals.append(SIMD4(gp.x - 0.2, gp.y + 0.4, 0.5, -0.8))
            }
            // …and a burned-out corpse's smoldering ash patch beside them
            let ap = world.player.pos + fwd * 2.6 + side * 0.5
            world.decals.append(SIMD4(ap.x, ap.y, 0.9, 2.9))
            world.decals.append(SIMD4(ap.x, ap.y, 1.1, 0.95))
            let canvas = Canvas2D()
            _ = gpu.render(world, into: canvas)
            n += 1
            Captures.writePNG(canvas.framebuffer, w: W, h: H, scale: 1, to: dir.appendingPathComponent("00k-gore.png"))
            print("  wrote 00k-gore.png — gib remains (gut ropes + gobbets)")
        }

        // pickup view — pickups should SIT IN THE WORLD (room/headlamp-lit, faint rim),
        // not floodlit floating beacons. A medkit + cells + a key in a lit room.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 4)
            world.monsters = []; world.drums = []; world.sockets = []; world.props = []
            let sp = world.player.pos
            let dirs = [SIMD2<Float>(1, 0), SIMD2<Float>(-1, 0), SIMD2<Float>(0, 1), SIMD2<Float>(0, -1)]
            var aim = dirs[0], bestClear: Float = 0
            for d in dirs { var t: Float = 0.5; while t < 6 && !world.map.blocksMovement(Int(sp.x + d.x * t), Int(sp.y + d.y * t)) { t += 0.25 }; if t > bestClear { bestClear = t; aim = d } }
            let perp = SIMD2<Float>(-aim.y, aim.x)
            world.items = [Item(kind: .medkit, pos: sp + aim * 1.6 - perp * 0.5),
                           Item(kind: .ammoCells, pos: sp + aim * 1.6),
                           Item(kind: .keyRed, pos: sp + aim * 1.6 + perp * 0.5)]
            world.player.dir = atan2(aim.y, aim.x); world.player.muzzle = 0
            let canvas = Canvas2D()
            _ = gpu.render(world, into: canvas)
            n += 1
            Captures.writePNG(canvas.framebuffer, w: W, h: H, scale: 1, to: dir.appendingPathComponent("00h-pickups.png"))
            print("  wrote 00h-pickups.png — medkit / cells / key")
        }

        // deployed-mine view — a small LOW floor disc (steps over it) with a red LED
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 4)
            world.monsters = []; world.drums = []; world.sockets = []; world.props = []
            let sp = world.player.pos
            let dirs = [SIMD2<Float>(1, 0), SIMD2<Float>(-1, 0), SIMD2<Float>(0, 1), SIMD2<Float>(0, -1)]
            var aim = dirs[0], bestClear: Float = 0
            for d in dirs { var t: Float = 0.5; while t < 6 && !world.map.blocksMovement(Int(sp.x + d.x * t), Int(sp.y + d.y * t)) { t += 0.25 }; if t > bestClear { bestClear = t; aim = d } }
            world.deployedMines = [Mine(pos: sp + aim * 1.5, arm: 0)]
            world.player.pos = sp + aim * 0.4               // stand back a touch, look at it on the floor
            world.player.dir = atan2(aim.y, aim.x)
            world.player.muzzle = 0
            let canvas = Canvas2D()
            _ = gpu.render(world, into: canvas)
            n += 1
            Captures.writePNG(canvas.framebuffer, w: W, h: H, scale: 1, to: dir.appendingPathComponent("00g-mine.png"))
            print("  wrote 00g-mine.png — deployed mine on the floor")
        }

        // door view — verify the door is a THIN sliding panel (not a moving wall
        // block): frame a door from the room side, render it closed then part-open
        for seed in stride(from: UInt64(1), through: UInt64(60), by: 1) {
            let world = World(level: 1, colonyIndex: 0, seed: seed)   // level 1: bright start area
            world.monsters = []; world.drums = []; world.sockets = []; world.props = []
            let m = world.map
            func litOpen(_ x: Int, _ y: Int) -> Bool {
                guard m.inBounds(x, y), m.wall[m.idx(x, y)] == 0, m.doors[m.idx(x, y)] == nil else { return false }
                let c = m.lightColor[m.idx(x, y)]; return c.x * 0.299 + c.y * 0.587 + c.z * 0.114 > 0.4
            }
            var doorCell = -1
            var camP = SIMD2<Float>(0, 0)
            for (dc, _) in m.doors {
                let dx = dc % m.w, dy = dc / m.w
                for (ox, oy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    guard litOpen(dx + ox, dy + oy) else { continue }    // lit open cell in front of the door
                    var cx = dx + ox, cy = dy + oy, steps = 1            // walk back through lit open cells only
                    while steps < 3 && litOpen(dx + ox * (steps + 1), dy + oy * (steps + 1)) { cx = dx + ox * (steps + 1); cy = dy + oy * (steps + 1); steps += 1 }
                    doorCell = dc; camP = SIMD2(Float(cx) + 0.5, Float(cy) + 0.5); break
                }
                if doorCell >= 0 { break }
            }
            guard doorCell >= 0 else { continue }
            let doorP = SIMD2(Float(doorCell % m.w) + 0.5, Float(doorCell / m.w) + 0.5)
            world.player.pos = camP
            world.player.dir = atan2(doorP.y - camP.y, doorP.x - camP.x)
            world.player.muzzle = 0
            for (oi, op) in [Float(0.0), 0.45].enumerated() {
                m.doors[doorCell]?.open = op
                let canvas = Canvas2D()
                _ = gpu.render(world, into: canvas)
                n += 1
                let name = oi == 0 ? "00d-door-closed.png" : "00d-door-open.png"
                Captures.writePNG(canvas.framebuffer, w: W, h: H, scale: 1, to: dir.appendingPathComponent(name))
                print("  wrote \(name) — door (seed \(seed), open \(op))")
            }
            break
        }

        // fuel-store + pipe-routing report. The pipe guarantee is hard: NO piped open
        // cell may sit next to a door (else a pipe crosses an opening) or on a prop.
        for level in 1...8 {
            let world = World(level: level, colonyIndex: (level - 1) % 6, seed: UInt64(level) &* 2654435761 &+ 11)
            let m = world.map
            var maxCluster = 0
            for d in world.drums { var c = 0; for q in world.drums where vlen(q.pos - d.pos) < 2.4 { c += 1 }; maxCluster = max(maxCluster, c) }
            let propCells = Set(world.props.map { m.idx(Int($0.pos.x), Int($0.pos.y)) })
            var pipedCells = 0, pipeNearDoor = 0, pipeOnProp = 0
            for i in 0..<(m.w * m.h) where m.pipe[i] > 0.5 && m.wall[i] == 0 {
                pipedCells += 1
                let x = i % m.w, y = i / m.w
                for oy in -1...1 { for ox in -1...1 where m.inBounds(x + ox, y + oy) {
                    if m.doors[m.idx(x + ox, y + oy)] != nil { pipeNearDoor += 1 }
                } }
                if propCells.contains(i) { pipeOnProp += 1 }
            }
            let store = maxCluster >= 3 ? "store✓" : "      "
            print("  L\(level): drums \(world.drums.count) cluster \(maxCluster) \(store) · piped \(pipedCells) cells · near-door \(pipeNearDoor) · on-prop \(pipeOnProp)")
        }

        for level in [1, 2, 3, 5, 7, 8] {
            let world = World(level: level, colonyIndex: level - 1, seed: UInt64(level) &* 2654435761 &+ 11)
            let props = world.props
            if props.isEmpty { continue }
            var taken: [SIMD2<Float>] = []
            for _ in 0..<2 {
                // pick the densest still-untaken cluster, aiming at FLOOR furniture
                // (not a high wall-pipe, which a horizontal camera can't frame)
                var bestI = -1, bestC = -1
                for (i, p) in props.enumerated() {
                    if p.kind == .wallPipe { continue }
                    if taken.contains(where: { vlen($0 - p.pos) < 6 }) { continue }
                    var c = 0
                    for q in props where vlen(q.pos - p.pos) < 4 { c += 1 }
                    if c > bestC { bestC = c; bestI = i }
                }
                guard bestI >= 0 else { break }
                let target = props[bestI]
                taken.append(target.pos)
                // inward = the prop's facing (local +Z); stand back into the room along
                // it (farthest open cell within ~3 cells) and look at the furnished wall
                let inward = SIMD2<Float>(-sin(target.yaw), cos(target.yaw))
                var cam = target.pos + inward * 1.6
                var t: Float = 1.6
                while t <= 2.6 {                                    // stay close so the headlamp lights it in the dark
                    let c = target.pos + inward * t
                    if world.map.blocksMovement(Int(c.x), Int(c.y)) { break }
                    cam = c; t += 0.3
                }
                if world.map.blocksMovement(Int(cam.x), Int(cam.y)) { continue }   // never shoot from inside a wall
                world.player.pos = cam
                world.player.dir = atan2(target.pos.y - cam.y, target.pos.x - cam.x)
                world.player.muzzle = 0
                let canvas = Canvas2D()
                func medianMS() -> Double {
                    _ = gpu.render(world, into: canvas)             // warmup
                    var times: [Double] = []
                    for _ in 0..<60 {
                        let t0 = CACurrentMediaTime()
                        _ = gpu.render(world, into: canvas)
                        times.append((CACurrentMediaTime() - t0) * 1000.0)
                    }
                    times.sort(); return times[times.count / 2]
                }
                let allProps = world.props
                let medAll = medianMS()                             // with everything
                world.props = allProps.filter { $0.kind != .wallPipe }
                let medNoPipe = medianMS()                          // furniture only (pipes removed)
                world.props = []
                let medBare = medianMS()                            // no props at all
                world.props = allProps
                _ = gpu.render(world, into: canvas)                 // restore the shot
                n += 1
                let name = String(format: "room-L%d-%02d.png", level, n)
                Captures.writePNG(canvas.framebuffer, w: W, h: H, scale: 1, to: dir.appendingPathComponent(name))
                let pipeCount = allProps.filter { $0.kind == .wallPipe }.count
                print(String(format: "  %@ — %d props (%d pipes) · all %.1fms · no-pipe %.1fms · bare %.1fms",
                             name, allProps.count, pipeCount, medAll, medNoPipe, medBare))
            }
        }
        print("Citadel: wrote \(n) room shots to \(dir.path)")
    }
}
