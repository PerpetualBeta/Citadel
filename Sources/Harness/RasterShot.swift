#if CITADEL_HARNESS
// Citadel — the rasteriser's headless preview (CITADEL_RASTERSHOT=<dir>).
//
// Renders ~57 frames covering every environment feature the game has — corridors and halls, doors
// part-open, lamp pools and cast shadows, display walls, the fuel store inside and out, dormitories,
// ops centres, sick bays, canteens, washrooms, the plant floors and their machinery, creatures at
// walls, pickups, decals, steam grates — and writes them as PNGs. No window, no sound.
//
// It is how nearly every environment feature in this game got its look settled, and since 7fc6883 it
// is also the input to tools/shotcheck.py, which diffs the whole set against a committed baseline.
// That pairing is what let a renderer, a 1,700-line shader and 3,000 lines of code be deleted with
// positive evidence that no shipping pixel moved.
//
// Split out of RasterRenderer.swift, which it made up a THIRD of: over a thousand lines stripped from
// every signed build. Living under Sources/Harness makes that structural rather than a comment —
// release.mk omits CITADEL_HARNESS when SIGN_ID is a real identity, so none of this reaches a player.
//
// An extension, so it is unchanged at the call site: still RasterRenderer.shot(outDir:).

import Foundation
import Metal
import simd

extension RasterRenderer {
    static func shot(outDir: String?) {
        guard let device = MTLCreateSystemDefaultDevice(), let rr = RasterRenderer(device: device) else {
            print("RASTERSHOT: no device/renderer"); return
        }
        let base = outDir.map { ($0 as NSString).expandingTildeInPath } ?? ("~/Desktop" as NSString).expandingTildeInPath
        let dir = URL(fileURLWithPath: base, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let canvas = Canvas2D()
        for (n, seed) in [UInt64(3), 7, 12].enumerated() {
            let world = World(level: 1, colonyIndex: 0, seed: seed)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            // frame a prop: stand in a nearby open cell and look straight at it
            func aimAt(_ target: SIMD2<Float>) -> Bool {
                let tx = Int(target.x), ty = Int(target.y)
                for rad in [2, 3, 4, 5] {
                    for (dx, dy) in [(0, rad), (0, -rad), (rad, 0), (-rad, 0), (rad, rad), (-rad, -rad), (rad, -rad), (-rad, rad)] {
                        guard op(tx + dx, ty + dy) else { continue }
                        let cpos = SIMD2(Float(tx + dx) + 0.5, Float(ty + dy) + 0.5)
                        world.player.pos = cpos
                        world.player.dir = atan2f(target.y - cpos.y, target.x - cpos.x)
                        return true
                    }
                }
                return false
            }
            // seed 0 → a drum, 1 → a socket, 2 → furniture — each falls through if that type is absent
            let drum = world.drums.first.map { $0.pos }
            let sock = world.sockets.first.map { $0.pos }
            let furn = world.props.first(where: { $0.kind != .papers && $0.kind != .wallPipe }).map { $0.pos }
            let order: [SIMD2<Float>?] = [[drum, sock, furn], [sock, furn, drum], [furn, drum, sock]][n]
            var framed = false
            for target in order.compactMap({ $0 }) where aimAt(target) { framed = true; break }
            if !framed {   // no props in this seed → fall back to a long open vista
                let dirs: [(Int, Int, Float)] = [(1, 0, 0), (-1, 0, .pi), (0, 1, .pi / 2), (0, -1, -.pi / 2)]
                search: for cy in 2..<(m.h - 2) { for cx in 2..<(m.w - 2) where op(cx, cy) {
                    for (dx, dy, ang) in dirs {
                        var k = 1; while k < 8 && op(cx + dx * k, cy + dy * k) { k += 1 }
                        if k >= 6 { world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy) + 0.5); world.player.dir = ang; break search }
                    }
                } }
            }
            _ = rr.render(world, into: canvas)
            let name = "raster-L1-\(n).png"
            Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent(name))
            print("RASTERSHOT: wrote \(name) (seed \(seed))")
        }

        // dedicated soft-shadow check: a drum placed one cell off-centre under a ceiling lamp
        // (so the floor pool is lit AND the lamp is up-and-to-one-side → a long cast shadow),
        // camera low a few cells back looking at it — the cast shadow falls across the lit pool.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            search: for cy in 4..<(m.h - 4) { for cx in 4..<(m.w - 5) where cx % 4 == 2 && cy % 4 == 2 && op(cx, cy) {
                // need a lateral open run EAST of the lamp for a side-on camera, and the drum cell
                guard op(cx, cy + 1), op(cx + 1, cy + 1), op(cx + 2, cy + 1), op(cx + 3, cy + 1), op(cx + 4, cy + 1) else { continue }
                world.drums.append(Drum(pos: SIMD2(Float(cx) + 0.5, Float(cy + 1) + 0.5), fuel: 100, health: 30))  // 1 cell S of the lamp → shadow throws S
                world.player.pos = SIMD2(Float(cx + 4) + 0.5, Float(cy + 1) + 0.5)                                 // stand 4 cells E, at the drum's row
                world.player.dir = .pi                                                                            // face west, drum side-on → its floor shadow lies across the lit pool
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-shadow.png"))
                print("RASTERSHOT: wrote raster-shadow.png (drum under lamp, side-on)")
                break search
            } }
        }

        // corridor light-STABILITY check (matches Jonathan's view; headlamp off): look down a
        // long straight run from two positions 3 cells apart. The far lamp pools should be
        // present and IDENTICAL between the two — any pop/occlusion of a distant pool shows here.
        // THE CHARGE POINT, square on. A player-facing surface with no coverage until now — which is
        // exactly why three attempts to fix its indicator shipped unseen, and why the fourth was a
        // redesign. Built on floor 1 with props CLEARED: earlier attempts framed a plant floor, where
        // the machinery is baked into the STATIC mesh and cannot be cleared, so the panel was always
        // behind a compressor. The socket is placed by hand rather than taken from the generator,
        // because the first one on a floor is as often as not in a corner.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 7)
            let m = world.map
            func clear(_ x: Int, _ y: Int) -> Bool {
                m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil && !m.hazard[m.idx(x, y)]
            }
            var placed = false
            for yy in 2..<(m.h - 4) where !placed {
                for xx in 2..<(m.w - 2) where !placed {
                    // a wall to the NORTH, and four clear cells of run to the south to stand back in
                    // …and NOT against a display. This socket is hand-placed, so it bypasses the
                    // `socketBadBacking` rule generation obeys — and after an unrelated RNG shift it
                    // landed on a CRT bank, making the reference frame depict the exact configuration
                    // the game forbids ("no display should ever have a charge point mounted on it").
                    // Generation was never wrong; the frame was. Smoke asserts the real rule twice.
                    let backTex = m.wall[m.idx(xx, yy - 1)]
                    guard backTex != 0, m.doors[m.idx(xx, yy - 1)] == nil,
                          backTex != WallTex.computer.rawValue, backTex != WallTex.opsBoard.rawValue,
                          backTex != WallTex.glass.rawValue, backTex != WallTex.liftWall.rawValue,
                          clear(xx, yy), clear(xx, yy + 1), clear(xx, yy + 2), clear(xx, yy + 3),
                          clear(xx - 1, yy), clear(xx + 1, yy) else { continue }
                    world.props = []; world.drums = []; world.items = []
                    world.monsters = []; world.colonists = []; world.deployedMines = []
                    world.sockets = [Socket(pos: SIMD2(Float(xx) + 0.5, Float(yy) + 0.5),
                                            yaw: 0, charge: 260, maxCharge: 400)]   // wall to the NORTH → inward (0,1) → yawFor = 0
                    world.player.pos = SIMD2(Float(xx) + 0.5, Float(yy) + 2.9)
                    world.player.dir = -.pi / 2                      // face north, straight at the panel
                    _ = rr.render(world, into: canvas)
                    Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1,
                                      to: dir.appendingPathComponent("raster-socket.png"))
                    print("RASTERSHOT: wrote raster-socket.png (charge point hand-placed at \(xx),\(yy))")
                    placed = true
                }
            }
        }

        do {
            let world = World(level: 1, colonyIndex: 0, seed: 7)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            let dirs: [(Int, Int, Float)] = [(1, 0, 0), (-1, 0, .pi), (0, 1, .pi / 2), (0, -1, -.pi / 2)]
            outer: for cy in 2..<(m.h - 2) { for cx in 2..<(m.w - 2) where op(cx, cy) {
                for (dx, dy, ang) in dirs {
                    var k = 1; while k < 24 && op(cx + dx * k, cy + dy * k) { k += 1 }
                    if k >= 14 {   // a long straight run
                        for (n, step) in [0, 3].enumerated() {
                            world.player.pos = SIMD2(Float(cx + dx * step) + 0.5, Float(cy + dy * step) + 0.5)
                            world.player.dir = ang
                            _ = rr.render(world, into: canvas)
                            Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-corr-\(n).png"))
                        }
                        print("RASTERSHOT: wrote raster-corr-0/1.png (corridor, 2 positions 3 cells apart)")
                        break outer
                    }
                }
            } }
        }

        // GRATE-CELL check (the "hard dark quad on the floor" culprit was a lone grate/metal floor cell
        // meeting concrete at a razor grid line): DETERMINISTICALLY stamp a grate cell INSIDE a lamp pool
        // (so it is well lit by the overhead pool, headlamp off) and frame it from a few cells back. After
        // the buildMesh cross-cell material feathering it must read as a SOFT-EDGED darker iron patch that
        // fades into the concrete over ~0.5 m — NOT a razor-sharp grid-aligned quad. The map floor is
        // mutated BEFORE the first render() so the fresh mesh bakes the grate.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            search: for cy in 4..<(m.h - 4) { for cx in 4..<(m.w - 4) where cx % 4 == 2 && cy % 4 == 2 && op(cx, cy) {
                // a clear run EAST of the lamp to stand a grate 1 cell out (in the pool) + a camera 3 cells out
                guard op(cx + 1, cy), op(cx + 2, cy), op(cx + 3, cy), op(cx + 4, cy) else { continue }
                m.floor[m.idx(cx + 1, cy)] = FlatTex.grate.rawValue   // grate one cell E of the lamp → inside its lit pool
                world.player.pos = SIMD2(Float(cx + 4) + 0.5, Float(cy) + 0.5)
                world.player.dir = .pi                                // face W, back over the grate toward the lamp
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-grate.png"))
                print("RASTERSHOT: wrote raster-grate.png (grate in lamp pool at \(cx + 1),\(cy))")
                break search
            } }
        }

        // ITEMS check (M4): line a spread of pickup kinds across a lamp pool and frame them from a few
        // cells back — verify the hover, the slow spin, the emissive parts (cell rings / lamps) and the
        // PBR metal all read, and that each pickup is lit + grounded by the overhead pool like the props.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            let kinds: [ItemKind] = [.stim, .ammoCells, .weaponRocket]
            search: for cy in 4..<(m.h - 4) { for cx in 4..<(m.w - 4) where cx % 4 == 2 && cy % 4 == 2 && op(cx, cy) {
                guard op(cx - 1, cy), op(cx + 1, cy), op(cx, cy + 1), op(cx, cy + 2), op(cx, cy + 3) else { continue }
                world.items = [
                    Item(kind: kinds[0], pos: SIMD2(Float(cx - 1) + 0.5, Float(cy) + 0.5)),
                    Item(kind: kinds[1], pos: SIMD2(Float(cx)     + 0.5, Float(cy) + 0.5)),
                    Item(kind: kinds[2], pos: SIMD2(Float(cx + 1) + 0.5, Float(cy) + 0.5)),
                ]
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy + 3) + 0.5)
                world.player.dir = -.pi / 2                            // face N (−y), toward the row of pickups under the lamp
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-items.png"))
                print("RASTERSHOT: wrote raster-items.png (\(kinds.count) pickups in a lamp pool at \(cx),\(cy))")
                break search
            } }
        }

        // CREATURES check (M4): drop a DRONE + the QUEEN into a lamp-lit room and frame them — verify the
        // animated meshes composite over the raster world, are occluded by geometry via the perp-depth,
        // stand on the floor, face right, and are lit consistently with the room.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            // any open patch with two side-by-side creature cells + a 4-cell standback (creatures are
            // lit by the mesh shader's own camera fill, so no lamp is required to see them)
            search: for cy in 3..<(m.h - 6) { for cx in 3..<(m.w - 3) where op(cx, cy) {
                guard op(cx - 1, cy), op(cx + 1, cy), op(cx, cy + 1), op(cx, cy + 2),
                      op(cx, cy + 3), op(cx, cy + 4) else { continue }
                var drone = Monster(kind: .alien, pos: SIMD2(Float(cx - 1) + 0.5, Float(cy) + 0.5))
                drone.dir = .pi / 2; drone.state = .chase              // face S toward the camera, mid-stride
                let queen = Monster(kind: .queen, pos: SIMD2(Float(cx + 1) + 0.5, Float(cy) + 0.5))
                world.monsters = [drone, queen]
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy + 4) + 0.5)
                world.player.dir = -.pi / 2                            // face N toward the creatures
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-creatures.png"))
                print("RASTERSHOT: wrote raster-creatures.png (drone+queen at \(cx),\(cy))")
                break search
            } }
        }

        // WALL-CLIP check (M4 corner-merge fix + the close-up merge Jonathan flagged 2026-07-26): stand a
        // drone straddling a wall boundary (body centre ON the wall face) with the camera CLOSE and head-on,
        // so its INSIDE half must be discarded by the distance-field clip → a clean cut at the wall, not a
        // drone smeared into it. The close framing matches the in-game case (a drone right in the player's face).
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            func solid(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] != 0 && m.doors[m.idx(x, y)] == nil }
            search: for cy in 3..<(m.h - 3) { for cx in 4..<(m.w - 4)
                where op(cx, cy) && solid(cx - 1, cy) {                 // open cell with a SOLID west neighbour (wall face at x = cx)
                guard op(cx + 1, cy), op(cx + 2, cy), op(cx + 3, cy) else { continue }   // open run EAST for the camera to stand back
                var drone = Monster(kind: .alien, pos: SIMD2(Float(cx), Float(cy) + 0.5))   // centre ON the wall face → west half is inside the wall
                drone.dir = 0; drone.state = .chase
                world.monsters = [drone]; world.props = []; world.drums = []; world.items = []; world.sockets = []
                world.player.pos = SIMD2(Float(cx + 3) + 0.5, Float(cy) + 0.5)             // ~3 cells EAST, head-on
                world.player.dir = .pi                                                     // face WEST → drone big in frame, west wall right behind it
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-creature-clip.png"))
                print("RASTERSHOT: wrote raster-creature-clip.png (drone on wall face at \(cx),\(cy))")
                break search
            } }
        }

        // WALL-MERGE repro (Jonathan 2026-07-26): a drone whose body pokes LATERALLY into a SIDE wall,
        // framed like the in-game shot (wall running away on the right, creature extent lapping into it).
        // The clip should cut the drone at the side-wall face; a smear across the wall means it isn't.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            func solid(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] != 0 && m.doors[m.idx(x, y)] == nil }
            search: for cy in 4..<(m.h - 3) { for cx in 4..<(m.w - 4)
                where op(cx, cy) && solid(cx + 1, cy) && op(cx, cy - 1) {   // open cell, SOLID east neighbour (side wall at x = cx+1), open north
                guard op(cx, cy + 1), op(cx, cy + 2), op(cx, cy + 3) else { continue }
                var drone = Monster(kind: .alien, pos: SIMD2(Float(cx) + 0.85, Float(cy) + 0.5))   // pushed EAST → its right side laps into the side wall
                drone.dir = -.pi / 2; drone.state = .chase
                world.monsters = [drone]; world.props = []; world.drums = []; world.items = []; world.sockets = []
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy + 3) + 0.5)   // ~3 cells SOUTH, side wall recedes on the right
                world.player.dir = -.pi / 2                                       // face NORTH toward the drone
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-wallmerge.png"))
                print("RASTERSHOT: wrote raster-wallmerge.png (drone lapping a side wall at \(cx),\(cy))")
                break search
            } }
        }

        // SNOUT-INTO-WALL repro (Jonathan 2026-07-26): the drone FACES a wall so its long snout pokes
        // straight INTO it. The body push-out clears the lateral footprint but NOT the forward snout
        // reach, so this is the case still broken — the snout enters the wall and the backstop clip saws
        // it. Framed side-on so the snout crossing the wall face reads clearly. THE repro to fix.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            func solid(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] != 0 && m.doors[m.idx(x, y)] == nil }
            search: for cy in 4..<(m.h - 4) { for cx in 5..<(m.w - 4)
                where op(cx, cy) && solid(cx - 1, cy) {                       // open cell, SOLID west neighbour (wall face at x = cx)
                guard op(cx + 1, cy), op(cx + 2, cy), op(cx, cy + 1), op(cx + 1, cy + 1), op(cx + 1, cy + 2) else { continue }
                var drone = Monster(kind: .alien, pos: SIMD2(Float(cx) + 0.5, Float(cy) + 0.5))
                drone.dir = .pi; drone.state = .chase                        // face WEST → the snout drives into the west wall
                world.monsters = [drone]; world.props = []; world.drums = []; world.items = []; world.sockets = []
                world.player.pos = SIMD2(Float(cx + 2) + 0.5, Float(cy + 2) + 0.5)                        // SE of the drone
                world.player.dir = atan2(Float(cy) - Float(cy + 2), Float(cx) - Float(cx + 2))            // face NW toward drone + west wall
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-snoutmerge.png"))
                print("RASTERSHOT: wrote raster-snoutmerge.png (drone snout into west wall at \(cx),\(cy))")
                break search
            } }
        }

        // SNOUT-DEEP repro: a drone pressed HARD against a wall it faces dead-on, framed CLOSE and side-on
        // so the snout↔wall meeting fills the frame (the point-blank case Jonathan sees). Stress-tests the
        // conform at the deepest realistic penetration — the snout must mold onto the face, not spear through.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            func solid(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] != 0 && m.doors[m.idx(x, y)] == nil }
            search: for cy in 4..<(m.h - 4) { for cx in 5..<(m.w - 4)
                where op(cx, cy) && solid(cx - 1, cy) {                       // west wall face at x = cx
                guard op(cx, cy + 1), op(cx, cy + 2), op(cx + 1, cy), op(cx + 1, cy + 1), op(cx + 1, cy + 2) else { continue }
                var drone = Monster(kind: .alien, pos: SIMD2(Float(cx) + 0.1, Float(cy) + 0.5))   // jammed at the wall
                drone.dir = .pi; drone.rearAmt = 0; drone.state = .chase                          // face WEST dead-on, snout low + forward
                world.monsters = [drone]; world.props = []; world.drums = []; world.items = []; world.sockets = []
                world.player.pos = SIMD2(Float(cx) + 0.9, Float(cy + 2) + 0.4)                    // CLOSE, just south-east
                world.player.dir = atan2(Float(cy) + 0.3 - (Float(cy + 2) + 0.4), Float(cx) - 0.15 - (Float(cx) + 0.9))   // aim at the snout/wall corner
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-snoutdeep.png"))
                print("RASTERSHOT: wrote raster-snoutdeep.png (drone jammed at west wall at \(cx),\(cy))")
                break search
            } }
        }

        // POCKET repro (Jonathan 2026-07-26): a drone cornered in a 1-wide DEAD-END (walls N, E, W; open S)
        // facing the back wall. Push-out can only shove it SOUTH, so the long snout stays JAMMED inside the
        // north wall — the head-genuinely-inside case the open-room repros couldn't force. Camera behind, as
        // in-game. THE test that the planar clip culls the in-wall snout cleanly (flat cut, no distortion).
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            func solid(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] != 0 && m.doors[m.idx(x, y)] == nil }
            _ = solid   // (pocket is constructed below, not searched for)
            search: for cy in 6..<(m.h - 6) { for cx in 5..<(m.w - 5)
                where cx % 4 == 2 && cy % 4 == 2 && op(cx, cy) {
                guard op(cx, cy + 1), op(cx, cy + 2), op(cx, cy + 3) else { continue }               // open run to the south
                m.wall[m.idx(cx, cy - 1)] = WallTex.steelPanel.rawValue                               // CONSTRUCT a 1-wide dead-end:
                m.wall[m.idx(cx - 1, cy)] = WallTex.steelPanel.rawValue                               //   back (N) + sides (E, W)
                m.wall[m.idx(cx + 1, cy)] = WallTex.steelPanel.rawValue
                var drone = Monster(kind: .alien, pos: SIMD2(Float(cx) + 0.5, Float(cy) + 0.3))
                drone.dir = -.pi / 2; drone.rearAmt = 0; drone.state = .chase                         // face NORTH into the dead-end
                world.monsters = [drone]; world.props = []; world.drums = []; world.items = []; world.sockets = []
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy + 3) + 0.5)                        // BEHIND the drone
                world.player.dir = -.pi / 2
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-conformwarp.png"))
                print("RASTERSHOT: wrote raster-conformwarp.png (drone jammed in a pocket at \(cx),\(cy))")
                break search
            } }
        }

        // EFFECTS check (M5): spawn fire + spark + smoke particles and a plasma bolt in front of the
        // camera and confirm the CPU sprite compositor draws them over the lit world, depth-occluded.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            search: for cy in 3..<(m.h - 5) { for cx in 3..<(m.w - 3) where op(cx, cy) {
                guard op(cx, cy + 1), op(cx, cy + 2), op(cx, cy + 3) else { continue }
                let o = SIMD2<Float>(Float(cx) + 0.5, Float(cy) + 0.5)   // effect origin, 3 cells ahead of the camera
                for i in 0..<12 { let a = Float(i)                       // rising flame column (additive age-ramp)
                    world.particles.append(Particle(pos: o + SIMD2(sinf(a) * 0.12, cosf(a * 1.3) * 0.12), vel: .zero,
                        life: 0.6, maxLife: 0.8, color: 0, size: 1.5, height: 0.25 + a * 0.05, rise: 0.4, maxAlpha: 1, fire: true)) }
                for i in 0..<8 { let a = Float(i) * 0.8                  // sparks (additive coloured glints)
                    world.particles.append(Particle(pos: o, vel: SIMD2(cosf(a), sinf(a)) * 2, life: 0.4, maxLife: 0.5,
                        color: packRGBA(255, 200, 90), size: 1, height: 0.5, rise: 0, maxAlpha: 1, fire: true)) }
                for i in 0..<6 { let a = Float(i)                       // smoke wisps (soft alpha)
                    world.particles.append(Particle(pos: o + SIMD2(0, 0.08 * a), vel: .zero, life: 1.0, maxLife: 1.2,
                        color: packRGBA(64, 64, 70), size: 2.2, height: 0.9 + a * 0.1, rise: 0.3, maxAlpha: 0.5, fire: false)) }
                world.projectiles.append(Projectile(pos: o + SIMD2(0.5, 0), vel: SIMD2(0, -4), kind: .plasma, damage: 20, fromPlayer: true, life: 2))
                world.projectiles.append(Projectile(pos: o + SIMD2(-0.7, 0.2), vel: SIMD2(-7, 0), kind: .rocket, damage: 60, fromPlayer: true, life: 3))   // fast, sideways → verify the streak points along travel
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy + 3) + 0.5)
                world.player.dir = -.pi / 2
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-effects.png"))
                print("RASTERSHOT: wrote raster-effects.png (fire/spark/smoke + plasma bolt at \(cx),\(cy))")
                break search
            } }
        }

        // REAL SPILLED PAPERS — a GENERATED scatter, not a stamped one. The frame below stamps its own
        // decals to exercise the shader branches, which proves the blend and NOTHING about whether papers
        // ever reach a floor. They didn't, much: measured at 0.6 per floor with 27 of 48 floors bare, so
        // Jonathan descended two floors and met none. This frames whatever MapGen actually placed, and
        // fails loudly (no file, explicit line) if a seed sweep finds nothing at all to look at.
        do {
            var shot = false
            // Frame the DENSEST floor found, not the first: `papersPerDesk` clusters land around one
            // desk, and the question worth a picture is whether that reads as a records spill or as
            // a paper explosion. The worst case is the one to look at.
            let bySeed = [3, 7, 11, 19, 23].map { sd -> (Int, Int) in
                (World(level: 1, colonyIndex: 0, seed: UInt64(sd)).props.filter { $0.kind == .papers }.count, sd)
            }.sorted { $0.0 > $1.0 }
            seeds: for (_, sd) in bySeed {
                let world = World(level: 1, colonyIndex: 0, seed: UInt64(sd))
                let m = world.map
                func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
                for pr in world.props where pr.kind == .papers {
                    // stand back from the scatter and look at it, along whichever axis is open behind us
                    let px = Int(pr.pos.x), py = Int(pr.pos.y)
                    for (dx, dy, yaw) in [(0, 2, -Float.pi / 2), (0, -2, Float.pi / 2), (2, 0, Float.pi), (-2, 0, Float(0))] {
                        guard op(px + dx, py + dy), op(px + dx / 2, py + dy / 2) else { continue }
                        world.player.pos = SIMD2(Float(px + dx) + 0.5, Float(py + dy) + 0.5)
                        world.player.dir = yaw
                        _ = rr.render(world, into: canvas)
                        Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight,
                                          scale: 1, to: dir.appendingPathComponent("raster-papers.png"))
                        let n = world.props.filter { $0.kind == .papers }.count
                        print("RASTERSHOT: wrote raster-papers.png — \(n) generated paper props on seed \(sd), framed at \(px),\(py)")
                        shot = true
                        break seeds
                    }
                }
            }
            if !shot { print("RASTERSHOT: NO GENERATED PAPERS FOUND across 5 seeds — raster-papers.png NOT written") }
        }

        // DECALS check (M5): stamp blood / scorch / scattered-papers on the floor of a lamp-lit room and
        // frame them — confirm the floor fragment blends each type (dark wet pool / charred black / pale
        // sheets) with soft noise-eroded edges, lit by the pool, on the raster floor.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            search: for cy in 4..<(m.h - 4) { for cx in 4..<(m.w - 4) where cx % 4 == 2 && cy % 4 == 2 && op(cx, cy) {
                guard op(cx - 1, cy), op(cx + 1, cy), op(cx, cy + 1), op(cx, cy + 2), op(cx, cy + 3) else { continue }
                world.decals = [
                    SIMD4(Float(cx - 1) + 0.5, Float(cy) + 0.5, 0.6, -1.6),   // blood (w in −2…0)
                    SIMD4(Float(cx)     + 0.5, Float(cy) + 0.5, 0.7,  1.0),   // scorch (w 0…2)
                    SIMD4(Float(cx + 1) + 0.5, Float(cy) + 0.5, 0.6,  3.7),   // scattered papers (w>3)
                ]
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy + 3) + 0.5)
                world.player.dir = -.pi / 2
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-decals.png"))
                print("RASTERSHOT: wrote raster-decals.png (blood/scorch/papers at \(cx),\(cy))")
                // …and STANDING IN THE BLOOD, which is the frame that matters. The decal pass and the
                // floor-liquid pass both treat any UP-FACING fragment by its world XZ, and the held gun
                // is up-facing faces at the marine's own XZ — so a blood pool used to paint the whole
                // weapon red and a floor grate drew a grate on the barrel. Guarded here because it is
                // invisible in every other frame: you have to be STANDING on the decal to see it.
                world.player.pos = SIMD2(Float(cx - 1) + 0.5, Float(cy) + 0.5)
                world.player.dir = -.pi / 2
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-viewmodel-ondecal.png"))
                print("RASTERSHOT: wrote raster-viewmodel-ondecal.png (the gun standing IN the blood at \(cx - 1),\(cy))")
                break search
            } }
        }

        // BED check: force a .bunk prop into a lamp-lit room and frame it — verify the imported
        // Institutional Bed mesh loads, orients, scales, sits on the floor, and is lit like the world.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            search: for cy in 4..<(m.h - 4) { for cx in 4..<(m.w - 4) where cx % 4 == 2 && cy % 4 == 2 && op(cx, cy) {
                guard op(cx, cy + 1), op(cx, cy + 2), op(cx, cy + 3) else { continue }
                world.props = [Prop(kind: .bunk, pos: SIMD2(Float(cx) + 0.5, Float(cy) + 0.5), yaw: 0)]
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy + 3) + 0.5)
                world.player.dir = -.pi / 2
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-bed.png"))
                print("RASTERSHOT: wrote raster-bed.png (institutional bed at \(cx),\(cy))")
                break search
            } }
        }

        // VIEWMODEL check: stand in a lamp-lit room and frame each held weapon (plasma / flamethrower /
        // rocket) — verify the first-person gun tessellates from the shared Viewmodel shapes, anchors to the
        // eye, is lit by the room (glinting under the lamp) and blooms its emissive parts (cell / pilot / bead).
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            world.monsters = []; world.props = []; world.drums = []
            search: for cy in 4..<(m.h - 4) { for cx in 4..<(m.w - 4) where cx % 4 == 2 && cy % 4 == 2 && op(cx, cy) {
                guard op(cx, cy - 1), op(cx, cy - 2), op(cx, cy - 3) else { continue }
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy) + 0.5)
                world.player.dir = -.pi / 2                                  // look down −Z into the open room
                for w in WeaponKind.allCases {
                    world.player.current = w
                    _ = rr.render(world, into: canvas)
                    Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-viewmodel-\(w).png"))
                    print("RASTERSHOT: wrote raster-viewmodel-\(w).png (held weapon at \(cx),\(cy))")
                }
                break search
            } }
        }

        // FIRE check: the volumetric fire (raymarcher's fireEmission), run as a raster HDR pass + bloom.
        // Two representative shots at a normal viewing distance (~4 cells back, so the eye is OUTSIDE the
        // plume): a lone burning-corpse PYRE, and the FLAMETHROWER JET. Verify turbulence, blackbody colour,
        // absorbing smoke and the bloomed hot core — occluded by the world via perp-depth.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            world.colonists = []; world.props = []; world.drums = []
            let baseMons = world.monsters
            search: for cy in 8..<(m.h - 4) { for cx in 4..<(m.w - 4) where cx % 4 == 2 && cy % 4 == 2 && op(cx, cy) {
                guard op(cx, cy - 1), op(cx, cy - 2), op(cx, cy - 3), op(cx, cy - 4), op(cx, cy - 5) else { continue }
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy) + 0.5)
                world.player.dir = -.pi / 2                                  // look down −Z
                let fwd = SIMD2<Float>(cosf(world.player.dir), sinf(world.player.dir))
                // 1 · lone PYRE — a mid-burn DRONE corpse ~4 cells ahead, no jet (NOT the Queen — she burns huge)
                world.flameJet = World.FlameJet()
                let dr = baseMons.first(where: { $0.kind == .alien }) ?? baseMons.first
                if var corpse = dr {
                    corpse.pos = SIMD2(Float(cx) + 0.5, Float(cy - 4) + 0.5)
                    corpse.state = .dead; corpse.burn = 0.32; corpse.kind = .alien   // the DRONE caste (not the Queen — she burns huge)
                    world.monsters = [corpse]
                }
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-fire-pyre.png"))
                print("RASTERSHOT: wrote raster-fire-pyre.png (burning corpse ~4 cells ahead at \(cx),\(cy))")
                // 2 · FLAMETHROWER JET — no corpse, jet fired forward down the room
                world.monsters = []
                world.flameJet = World.FlameJet(t: 0.2, nozzle: world.player.pos + fwd * 0.35, dir: fwd, reach: 3.5)
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-fire-jet.png"))
                print("RASTERSHOT: wrote raster-fire-jet.png (flamethrower jet at \(cx),\(cy))")
                break search
            } }
        }

        // GIB TIERS — the two ways a drone is disposed of, one frame each. CleanDroneDeaths bursts a
        // drone on a PLASMA kill as well as a rocket one, at a third of the spectacle, because the
        // rocket blast spends 22 of `decalCap`'s 72 slots: affordable two or three times a floor, not
        // thirty. Before these frames shotcheck was BLIND to the whole change — the only existing frame
        // with a dead drone in it (raster-fire-pyre) is a FIRE death, which still leaves a corpse.
        //
        // THREE frames: one kill of each tier, plus a PACK.
        //
        // The singles are the sensitive baseline. A frame pinned at the particle cap and the decal cap
        // at once cannot detect a regression — nothing can move it, because nothing has room to move —
        // and at saturation the two tiers render identically, so a single kill at conversational range
        // is what shows the difference in count, spread and footprint.
        //
        // The PACK frame is the worst case, and it is a REAL one. `explode()` damages every monster
        // inside the blast in the same call, a rocket's splash is 2.0 cells, and drones pack to a
        // 0.8-cell gap — so one rocket into a group kills six at the same instant. (The smoke test
        // already asserts this for mines: trigger drone AND rim packmate die.) I first wrote that
        // frame off as a scenario play would not produce, which was simply wrong, and it was the
        // frame telling me something true: six simultaneous kills stamp 60 offal decals into a
        // 72-slot buffer, so the deck goes uniformly red and most of the gore is evicted on arrival.
        // That is PRE-EXISTING behaviour, not something the plasma tier introduced — but it is why
        // the plasma tier is scaled down, because clean deaths make the flood reachable far more often.
        //
        // (The budget numbers are asserted in the smoke test, where measuring belongs.)
        //
        // Audio is safe to construct here: CITADEL_RASTERSHOT is in main.swift's forced-mute list, so
        // the engine never opens an output device.
        do {
            let audio = AudioEngine()
            for (name, dmg) in [("plasma", DamageKind.plasma), ("rocket", DamageKind.explosive)] {
                let world = World(level: 1, colonyIndex: 0, seed: 3)
                let m = world.map
                func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
                world.colonists = []; world.props = []; world.drums = []
                let drone = world.monsters.first(where: { $0.kind == .alien })
                search: for cy in 8..<(m.h - 4) { for cx in 4..<(m.w - 4) where cx % 4 == 2 && cy % 4 == 2 && op(cx, cy) {
                    guard op(cx, cy - 1), op(cx, cy - 2), op(cx, cy - 3), op(cx, cy - 4) else { continue }
                    world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy) + 0.5)
                    world.player.dir = -.pi / 2                                  // look down −Z
                    guard var d = drone else { break search }
                    d.pos = SIMD2(Float(cx) + 0.5, Float(cy - 3) + 0.5)          // 3 cells ahead, centred
                    d.state = .chase; d.awake = true; d.burn = 0; d.gibbed = false
                    world.monsters = [d]
                    world.damageMonsterForTest(0, 999, audio: audio, kind: dmg)
                    // 5 frames: the chunks are still airborne and the decals are already down, so one
                    // frame carries both the spectacle and the footprint it leaves.
                    for _ in 0..<5 { world.update(dt: 1.0 / 60, input: InputState(), audio: audio) }
                    _ = rr.render(world, into: canvas)
                    Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1,
                                      to: dir.appendingPathComponent("raster-gib-\(name).png"))
                    print("RASTERSHOT: wrote raster-gib-\(name).png (burst \(world.monsters[0].gibbed), \(world.decals.filter { $0.w < -2 }.count) offal decals, \(world.particles.count) particles aloft)")
                    break search
                } }
            }
            // ── ONE ROCKET, SIX DRONES ── the simultaneous multi-kill, through the real splash path
            // rather than by hand: a live rocket detonated in the middle of a pack, so `explode()`
            // decides who dies exactly as it does in play.
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
            world.colonists = []; world.props = []; world.drums = []
            let drone = world.monsters.first(where: { $0.kind == .alien })
            search: for cy in 8..<(m.h - 4) { for cx in 4..<(m.w - 4) where cx % 4 == 2 && cy % 4 == 2 && op(cx, cy) {
                guard op(cx, cy - 1), op(cx, cy - 2), op(cx, cy - 3), op(cx, cy - 4) else { continue }
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy) + 0.5)
                world.player.dir = -.pi / 2
                guard var d = drone else { break search }
                world.monsters = []
                // packed at the AI's own separation floor (0.8 cells) inside the 2.0-cell splash
                let hub = SIMD2<Float>(Float(cx) + 0.5, Float(cy - 3) + 0.5)
                for k in 0..<6 {
                    let a = Float(k) * 1.047                                 // six around the hub
                    d.pos = hub + SIMD2(cosf(a), sinf(a)) * (k == 0 ? 0 : 0.8)
                    guard op(Int(d.pos.x), Int(d.pos.y)) else { continue }
                    d.state = .chase; d.awake = true; d.burn = 0; d.gibbed = false
                    world.monsters.append(d)
                }
                let packed = world.monsters.count
                world.projectiles.append(Projectile(pos: hub, vel: .zero, kind: .rocket, damage: 999, fromPlayer: true, life: 0.01))
                for _ in 0..<6 { world.update(dt: 1.0 / 60, input: InputState(), audio: audio) }
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1,
                                  to: dir.appendingPathComponent("raster-gib-pack.png"))
                print("RASTERSHOT: wrote raster-gib-pack.png (\(packed) packed, \(world.monsters.filter { $0.gibbed }.count) burst by ONE rocket, \(world.decals.filter { $0.w < -2 }.count) of 60 offal decals survived the 72-slot cap)")
                break search
            } }
        }

        // DISPLAY WALL check: paint a 3-wide amber CRT bank on a wall ahead and render it at THREE times —
        // verify the live animated monitors (scrolling log / oscilloscope / spectrum / dashboard) genuinely
        // MOVE frame-to-frame, glow and bloom, plus the surrounding walls now carry their baked art.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
            world.monsters = []; world.props = []; world.drums = []; world.colonists = []
            search: for cy in 5..<(m.h - 5) { for cx in 5..<(m.w - 5) where op(cx, cy) {
                guard m.inBounds(cx, cy - 1), m.wall[m.idx(cx, cy - 1)] != 0, m.doors[m.idx(cx, cy - 1)] == nil,
                      op(cx, cy + 1), op(cx, cy + 2) else { continue }
                for dx in -1...1 where m.inBounds(cx + dx, cy - 1) && m.wall[m.idx(cx + dx, cy - 1)] != 0
                                    && m.doors[m.idx(cx + dx, cy - 1)] == nil {
                    m.wall[m.idx(cx + dx, cy - 1)] = WallTex.computer.rawValue          // amber CRT bank
                }
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy + 2) + 0.5)
                world.player.dir = -.pi / 2                                            // face the bank (−Z)
                for (n, t) in [Float(0.0), 0.6, 1.4].enumerated() {
                    world.elapsed = t
                    _ = rr.render(world, into: canvas)
                    Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-display-\(n).png"))
                }
                print("RASTERSHOT: wrote raster-display-0/1/2.png (animated CRT bank at \(cx),\(cy))")
                break search
            } }
        }

        // DOOR check: paint a wall cell ahead as a door and frame it from a few cells back — a RED key door
        // part-open (textured leaves + centre-split gap), then a SECRET door closed (keeps its WALL id, so
        // its leaf textures as the surrounding wall → invisible until it parts).
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
            world.monsters = []; world.props = []; world.drums = []; world.colonists = []
            search: for cy in 5..<(m.h - 5) { for cx in 5..<(m.w - 5) where op(cx, cy) {
                // need a solid wall ahead (cy-1) with solid sides (slide-X) and clear standoff behind
                guard m.inBounds(cx, cy - 1), m.wall[m.idx(cx, cy - 1)] != 0, m.doors[m.idx(cx, cy - 1)] == nil,
                      m.wall[m.idx(cx - 1, cy - 1)] != 0, m.wall[m.idx(cx + 1, cy - 1)] != 0,
                      op(cx, cy + 1), op(cx, cy + 2), op(cx, cy + 3) else { continue }
                let dcell = m.idx(cx, cy - 1)
                let origWall = m.wall[dcell]
                m.wall[m.idx(cx, cy - 2)] = 0                                          // carve a cell behind so the door opens onto a gap
                m.wall[m.idx(cx, cy - 3)] = 0
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy + 2) + 0.5)
                world.player.dir = -.pi / 2
                // 1 · RED key door, part-open
                m.wall[dcell] = WallTex.doorRed.rawValue; m.doors[dcell] = DoorState(open: 0.35)
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-door-red.png"))
                // 2 · SECRET door, closed — keeps the wall id so its leaf reads as the surrounding wall
                m.wall[dcell] = origWall; m.doors[dcell] = DoorState(secret: true)   // open 0 = closed
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-door-secret.png"))
                print("RASTERSHOT: wrote raster-door-red.png + raster-door-secret.png (door at \(cx),\(cy-1))")
                break search
            } }
        }

        // TOXIC-POOL check (M6): flood a 5×5 patch of nukage floor cells in a cleared room, centred OFF the
        // overhead-lamp grid (cx%4==0,cy%4==0 — the point farthest from any lamp) so the lamp doesn't wash
        // the surface white and the pool's OWN green shows — verify the raster floor fragment gives it the
        // LIQUID surface: green self-glow that PULSES, churning ripples off the normal, glassy low roughness.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            func clear() { world.props = []; world.drums = []; world.deployedMines = []; world.sockets = []; world.items = [] }
            search: for cy in 6..<(m.h - 8) { for cx in 6..<(m.w - 6) where cx % 4 == 0 && cy % 4 == 0 && op(cx, cy) {
                guard op(cx, cy + 1), op(cx, cy + 2), op(cx, cy + 3), op(cx, cy + 4), op(cx, cy + 5), op(cx - 1, cy), op(cx + 1, cy) else { continue }
                clear()
                for py in (cy - 2)...(cy + 2) { for px in (cx - 2)...(cx + 2) where op(px, py) {
                    m.floor[m.idx(px, py)] = FlatTex.nukage.rawValue
                } }
                world.elapsed = 3.0                                                   // a non-zero phase so the ripples/glow are mid-animation
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy + 5) + 0.5)        // stand back so the pool is seen at a GRAZING angle (head-on + close, the bright headlamp washes the green out)
                world.player.dir = -.pi / 2
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-toxic.png"))
                print("RASTERSHOT: wrote raster-toxic.png (nukage pool at \(cx),\(cy))")
                break search
            } }
        }

        // STANDING-WATER check (M6): force a 9×9 rock floor in a cleared lamp-lit room — the shared puddle
        // field pools water across roughly half of it, so this frames the representative "water finds its
        // way down" look: dark cool glazed puddles with damp margins, on dry rock, all lit. (The floor-8
        // FLOOD path is the same fragment code with a global wet=0.85 instead of the pooled mask.)
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            search: for cy in 7..<(m.h - 8) { for cx in 7..<(m.w - 7) where cx % 4 == 2 && cy % 4 == 2 && op(cx, cy) {
                guard op(cx, cy + 1), op(cx, cy + 2), op(cx, cy + 3), op(cx, cy + 4), op(cx, cy + 5) else { continue }
                world.props = []; world.drums = []; world.deployedMines = []; world.sockets = []; world.items = []
                for py in (cy - 3)...(cy + 3) { for px in (cx - 3)...(cx + 3) where op(px, py) {
                    m.floor[m.idx(px, py)] = FlatTex.rock.rawValue
                } }
                world.elapsed = 3.0
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy + 5) + 0.5)
                world.player.dir = -.pi / 2
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-water.png"))
                print("RASTERSHOT: wrote raster-water.png (rock puddles at \(cx),\(cy))")
                break search
            } }
        }

        // STEAM check (M6): seat a floor grate and spawn a rising steam PLUME (staggered heights, so one
        // frame shows the column) — confirm the CPU sprite compositor draws the faint grey steam over the
        // lit world, dispersing as it climbs, out of a visible vent grate. (Steam = fire:false particles.)
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 }
            search: for cy in 5..<(m.h - 6) { for cx in 5..<(m.w - 5) where cx % 4 == 2 && cy % 4 == 2 && op(cx, cy) {
                guard op(cx, cy + 1), op(cx, cy + 2), op(cx, cy + 3), op(cx - 1, cy), op(cx + 1, cy),
                      op(cx - 1, cy + 1), op(cx + 1, cy + 1) else { continue }         // a genuinely open bay so the plume isn't lost against a near wall
                world.monsters = []; world.props = []; world.drums = []; world.items = []   // clear so the plume reads against the deck
                m.floor[m.idx(cx, cy)] = FlatTex.grate.rawValue                        // the vent's visible source
                let base = SIMD2<Float>(Float(cx) + 0.5, Float(cy) + 0.5)
                // GRATE first, with NO plume — the dense steam hides its own source, so verify the vent
                // itself reads as a slotted iron grate cut into the deck (not blank floor) in its own frame.
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy) + 3.6)   // stand back: floor <1 cell ahead falls below the frame edge
                world.player.dir = -.pi / 2
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-vent.png"))
                for k in 0..<50 {                                                      // a plume frozen mid-rise (dense so the compositor's output is unmistakable): height climbs, it spreads + thins
                    let t = Float(k) / 49.0, a = Float(k) * 0.7
                    world.particles.append(Particle(pos: base + SIMD2(sinf(a) * (0.10 + t * 0.30), cosf(a * 1.3) * (0.10 + t * 0.30)),
                        vel: .zero, life: 1.5, maxLife: 1.9, color: packRGBA(210, 214, 220),
                        size: 6 + t * 7, height: 0.05 + t * 0.85, rise: 0.5, maxAlpha: 0.5 * (1.0 - t * 0.4), fire: false))
                }
                world.player.pos = SIMD2(Float(cx) + 0.5, Float(cy + 2) + 0.5)
                world.player.dir = -.pi / 2
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-steam.png"))
                print("RASTERSHOT: wrote raster-steam.png (steam vent at \(cx),\(cy))")
                break search
            } }
        }

        // DOOR check (parity fix): find a door cell with an open through-side, stand 3 cells back facing
        // it and render it PART-OPEN — verify the sliding centre-split leaves now DRAW (they were never
        // emitted, so doors vanished though they operated: you saw straight through the doorway). The gap
        // between the two panels proves it's a door, not a wall.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
            // SORTED, not dictionary order. Swift randomises hash seeding per process, so iterating
            // m.doors directly framed a DIFFERENT door on every run — the shot could never be compared
            // against a baseline, and eyeballing it compared different subjects. Worse, this block
            // leaves its chosen door part-open on the shared map, so the arbitrary choice leaked into
            // later frames too (shotcheck caught raster-door, raster-tee and raster-industrial all
            // moving between identical runs).
            for i in m.doors.keys.sorted() {
                let cx = i % m.w, cy = i / m.w
                let slideX = (m.inBounds(cx - 1, cy) && m.wall[m.idx(cx - 1, cy)] != 0)
                          && (m.inBounds(cx + 1, cy) && m.wall[m.idx(cx + 1, cy)] != 0)
                let tx = slideX ? 0 : 1, ty = slideX ? 1 : 0                          // through-axis (open passage) direction
                var placed = false
                for sgn in [1, -1] where !placed {                                    // stand on whichever through-side is open
                    guard op(cx + tx * sgn, cy + ty * sgn), op(cx + tx * 3 * sgn, cy + ty * 3 * sgn) else { continue }
                    m.doors[i] = DoorState(open: 0.30)                               // part-open → the centre-split gap shows
                    world.player.pos = SIMD2(Float(cx + tx * 3 * sgn) + 0.5, Float(cy + ty * 3 * sgn) + 0.5)
                    world.player.dir = atan2(Float(-ty * sgn), Float(-tx * sgn))     // face the door
                    _ = rr.render(world, into: canvas)
                    Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-door.png"))
                    print("RASTERSHOT: wrote raster-door.png (\(slideX ? "X" : "Z")-slide door at \(cx),\(cy), part-open)")
                    placed = true
                }
                if placed { break }
            }
        }

        // ELEVATOR check (parity fix): frame the exit elevator — its front IS a door cell, so it vanished
        // with the rest. Stand 3 cells back on its open through-side, force it closed → verify the
        // machined-steel car front renders as a solid leaf (was an open gap into the shaft).
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
            let i = m.exitCell
            if i >= 0, m.doors[i] != nil {
                let cx = i % m.w, cy = i / m.w
                world.monsters = []; world.props = []; world.drums = []   // the Queen spawns AT the exit elevator — clear her so she doesn't fill the view
                let slideX = (m.inBounds(cx - 1, cy) && m.wall[m.idx(cx - 1, cy)] != 0)
                          && (m.inBounds(cx + 1, cy) && m.wall[m.idx(cx + 1, cy)] != 0)
                let tx = slideX ? 0 : 1, ty = slideX ? 1 : 0
                var placed = false
                for sgn in [-1, 1] where !placed {                                    // the room is on the open through-side of the shaft
                    let dist = op(cx + tx * 4 * sgn, cy + ty * 4 * sgn) ? 4
                             : (op(cx + tx * 3 * sgn, cy + ty * 3 * sgn) ? 3 : (op(cx + tx * 2 * sgn, cy + ty * 2 * sgn) ? 2 : 0))
                    guard dist > 0 else { continue }
                    world.player.pos = SIMD2(Float(cx + tx * dist * sgn) + 0.5, Float(cy + ty * dist * sgn) + 0.5)
                    world.player.dir = atan2(Float(-ty * sgn), Float(-tx * sgn))     // face the elevator
                    // CLOSED then OPEN — the pair PROVES the leaf: closed hides the car (grey steel front),
                    // open reveals the lit interior. Before the fix BOTH looked the same (open gap → no leaf).
                    m.doors[i] = DoorState()                                          // closed
                    _ = rr.render(world, into: canvas)
                    Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-elevator.png"))
                    m.doors[i] = DoorState(open: 1.0)                                 // fully parted
                    _ = rr.render(world, into: canvas)
                    Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-elevator-open.png"))
                    // LED CLOSE-UP — step to the car mouth (1 cell out) so the 7-segment floor indicator reads large
                    world.player.pos = SIMD2(Float(cx + tx * sgn) + 0.5, Float(cy + ty * sgn) + 0.5)
                    _ = rr.render(world, into: canvas)
                    Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-elevator-led.png"))
                    print("RASTERSHOT: wrote raster-elevator.png + raster-elevator-open.png + raster-elevator-led.png (exit elevator at \(cx),\(cy), dist \(dist), floor \(world.elevatorFloorDisplay))")
                    placed = true
                }
                if !placed { print("RASTERSHOT: elevator check skipped (no open standoff)") }
            } else {
                print("RASTERSHOT: elevator check skipped (no exit-cell door)")
            }
        }

        // SANITARY check — stand off a trough basin and look along the wash wall, so the pale tile, the mirrors
        // and the showers/cubicles on the neighbouring walls all read.
        for lvl in [3, 4] {
            let world = World(level: lvl, colonyIndex: 0, seed: 3)
            let m = world.map
            world.monsters = []; world.colonists = []
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
            var shot = false
            for pr in world.props where !shot && (pr.kind == .washTrough || pr.kind == .shower) {
                for (dx, dy) in [(0, 1), (0, -1), (1, 0), (-1, 0)] {
                    let sx = Int(pr.pos.x) + dx * 3, sy = Int(pr.pos.y) + dy * 3
                    guard op(sx, sy), op(Int(pr.pos.x) + dx, Int(pr.pos.y) + dy), op(Int(pr.pos.x) + dx * 2, Int(pr.pos.y) + dy * 2) else { continue }
                    world.player.pos = SIMD2(Float(sx) + 0.5, Float(sy) + 0.5)
                    world.player.dir = atan2(Float(-dy), Float(-dx))
                    _ = rr.render(world, into: canvas)
                    Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1,
                                      to: dir.appendingPathComponent("raster-sanitary-\(lvl).png"))
                    let tiles = (0..<(m.w * m.h)).filter { m.wall[$0] == WallTex.sanTile.rawValue }.count
                    let fits = world.props.filter { $0.kind == .washTrough || $0.kind == .shower || $0.kind == .cubicle }.count
                    print("RASTERSHOT: wrote raster-sanitary-\(lvl).png (\(tiles) tiled cells, \(fits) fittings)")
                    shot = true; break
                }
            }
            if !shot { print("RASTERSHOT: sanitary check skipped on level \(lvl)") }
        }

        // CANTEEN check — stand off the range and look down the galley line, so the subway tile, the stainless
        // fittings under the extraction hood and (where they share the room) the dining tables all read.
        for lvl in [3, 4] {
            let world = World(level: lvl, colonyIndex: 0, seed: 3)
            let m = world.map
            world.monsters = []; world.colonists = []
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
            var shot = false
            for pr in world.props where !shot && pr.kind == .range {
                for (dx, dy) in [(0, 1), (0, -1), (1, 0), (-1, 0)] {
                    let sx = Int(pr.pos.x) + dx * 3, sy = Int(pr.pos.y) + dy * 3
                    guard op(sx, sy), op(Int(pr.pos.x) + dx, Int(pr.pos.y) + dy), op(Int(pr.pos.x) + dx * 2, Int(pr.pos.y) + dy * 2) else { continue }
                    world.player.pos = SIMD2(Float(sx) + 0.5, Float(sy) + 0.5)
                    world.player.dir = atan2(Float(-dy), Float(-dx))     // look back at the galley
                    _ = rr.render(world, into: canvas)
                    Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1,
                                      to: dir.appendingPathComponent("raster-canteen-\(lvl).png"))
                    let tiles = (0..<(m.w * m.h)).filter { m.wall[$0] == WallTex.subwayTile.rawValue }.count
                    let tables = world.props.filter { $0.kind == .canteenTable }.count
                    print("RASTERSHOT: wrote raster-canteen-\(lvl).png (\(tiles) tiled cells, \(tables) tables)")
                    shot = true; break
                }
            }
            if !shot { print("RASTERSHOT: canteen check skipped on level \(lvl)") }
        }

        // MEDICAL CENTRE check — stand back from a bed that sits in a white-walled room and look across it, so
        // the sterile surfaces, the ward beds and the stainless fittings all read in one frame.
        for lvl in [1, 3] {
            let world = World(level: lvl, colonyIndex: 0, seed: 3)
            let m = world.map
            world.monsters = []; world.colonists = []
            func medNear(_ p: SIMD2<Float>) -> Bool {                       // a white wall within a cell or two
                let cx = Int(p.x), cy = Int(p.y)
                for oy in -2...2 { for ox in -2...2 {
                    let wx = cx + ox, wy = cy + oy
                    guard m.inBounds(wx, wy) else { continue }
                    if m.wall[m.idx(wx, wy)] == WallTex.medWall.rawValue { return true }
                } }
                return false
            }
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
            var shot = false
            for pr in world.props where !shot && pr.kind == .bunk && medNear(pr.pos) {
                for (dx, dy) in [(0, 1), (0, -1), (1, 0), (-1, 0)] {
                    let sx = Int(pr.pos.x) + dx * 3, sy = Int(pr.pos.y) + dy * 3
                    guard op(sx, sy), op(Int(pr.pos.x) + dx, Int(pr.pos.y) + dy), op(Int(pr.pos.x) + dx * 2, Int(pr.pos.y) + dy * 2) else { continue }
                    world.player.pos = SIMD2(Float(sx) + 0.5, Float(sy) + 0.5)
                    world.player.dir = atan2(Float(-dy), Float(-dx))        // look back at the bed
                    _ = rr.render(world, into: canvas)
                    Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1,
                                      to: dir.appendingPathComponent("raster-medical-\(lvl).png"))
                    let white = (0..<(m.w * m.h)).filter { m.wall[$0] == WallTex.medWall.rawValue }.count
                    let fittings = world.props.filter { $0.kind == .cabinet || $0.kind == .sink }.count
                    print("RASTERSHOT: wrote raster-medical-\(lvl).png (\(white) white-wall cells, \(fittings) stainless fittings)")
                    shot = true; break
                }
            }
            if !shot { print("RASTERSHOT: medical check skipped on level \(lvl)") }
        }

        // OPERATIONS CENTRE check — stand at the back of the room on the board's axis, looking down the ranks of
        // amber consoles at the full-colour big board: the one display in the colony that isn't amber phosphor.
        for lvl in [1, 3] {
            let world = World(level: lvl, colonyIndex: 0, seed: 3)
            let m = world.map
            world.monsters = []; world.colonists = []
            let board = (0..<(m.w * m.h)).filter { m.wall[$0] == WallTex.opsBoard.rawValue }
            guard !board.isEmpty else { print("RASTERSHOT: ops centre check skipped (no board on level \(lvl))"); continue }
            // the board's centre cell, and the room direction is whichever side of it is open
            let bc = board[board.count / 2], bx = bc % m.w, by = bc / m.w
            var rdx = 0, rdy = 0
            for (dx, dy) in [(0, 1), (0, -1), (1, 0), (-1, 0)]
                where m.inBounds(bx + dx, by + dy) && m.wall[m.idx(bx + dx, by + dy)] == 0 { rdx = dx; rdy = dy; break }
            guard rdx != 0 || rdy != 0 else { continue }
            var back = 1                                                       // walk out from the board while open
            while back < 5, m.inBounds(bx + rdx * (back + 1), by + rdy * (back + 1)),
                  m.wall[m.idx(bx + rdx * (back + 1), by + rdy * (back + 1))] == 0 { back += 1 }
            // …and never stand INSIDE a console: its own screen then fills the whole frame (which is exactly
            // how this check first misled me into thinking the board was blown out).
            while back > 1, world.props.contains(where: { $0.kind == .console &&
                  simd_length($0.pos - SIMD2(Float(bx + rdx * back) + 0.5, Float(by + rdy * back) + 0.5)) < 0.7 }) { back -= 1 }
            world.player.pos = SIMD2(Float(bx + rdx * back) + 0.5, Float(by + rdy * back) + 0.5)
            world.player.dir = atan2(Float(-rdy), Float(-rdx))                 // face the board
            _ = rr.render(world, into: canvas)
            Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1,
                              to: dir.appendingPathComponent("raster-ops-\(lvl).png"))
            let consoles = world.props.filter { $0.kind == .console }.count
            print("RASTERSHOT: wrote raster-ops-\(lvl).png (board \(board.count) cells at \(bx),\(by); \(consoles) consoles; stood \(back) back)")
        }

        // CORPSE/DRONE POSE-RESOLVE check — a NUMERIC assertion, not a picture: a body settling into a wall at a
        // corner is near-impossible to stage as a screenshot, but the invariant is exact. Drop a body deep inside
        // every kind of wall corner, over a sweep of facings, resolve it, then measure how far any capsule sample
        // still penetrates a solid. Every case must come out at ~0.
        do {
            let world = World(level: 1, colonyIndex: 0, seed: 3)
            let m = world.map
            let back: Float = -0.35, front: Float = 0.45, r: Float = 0.30      // representative drone capsule
            /// How far a circle of radius `rr` at `p` overlaps any blocking cell (0 = clear).
            func penetration(_ p: SIMD2<Float>, _ rr: Float) -> Float {
                var worst: Float = 0
                let cx = Int(p.x.rounded(.down)), cy = Int(p.y.rounded(.down))
                for oy in -1...1 { for ox in -1...1 {
                    let wx = cx + ox, wy = cy + oy
                    guard m.inBounds(wx, wy), m.wall[m.idx(wx, wy)] != 0 else { continue }
                    if let d = m.doors[m.idx(wx, wy)], d.open >= GameMap.passThreshold { continue }
                    if p.x > Float(wx), p.x < Float(wx + 1), p.y > Float(wy), p.y < Float(wy + 1) {
                        let dl = p.x - Float(wx), dr = Float(wx + 1) - p.x, db = p.y - Float(wy), dt = Float(wy + 1) - p.y
                        worst = max(worst, rr + min(min(dl, dr), min(db, dt))); continue      // strictly inside
                    }
                    let nx = min(max(p.x, Float(wx)), Float(wx + 1)), ny = min(max(p.y, Float(wy)), Float(wy + 1))
                    let dist = simd_length(p - SIMD2(nx, ny))
                    if dist < rr { worst = max(worst, rr - dist) }
                } }
                return worst
            }
            func capsuleWorst(_ pos: SIMD2<Float>, _ dir: SIMD2<Float>, _ taperMin: Float) -> Float {
                var worst: Float = 0
                for i in 0...5 {
                    let t = back + (front - back) * Float(i) / 5
                    let taper = t <= 0 ? 1.0 : max(taperMin, 1.0 - 0.6 * (t / max(1e-3, front)))
                    worst = max(worst, penetration(pos + dir * t, r * taper))
                }
                return worst
            }
            // The capsule is bigger than a cell, so total clearance is unachievable in a corridor. The invariant
            // that MUST hold is the TRUNK being clear — a buried trunk is the "body vanished into the wall" bug.
            // Extremity overlap is reported separately and only needs to stay modest.
            var cases = 0, trunkFail = 0
            var trunkBefore: Float = 0, trunkAfter: Float = 0, tipAfter: Float = 0
            for cy in 1..<(m.h - 1) { for cx in 1..<(m.w - 1) where m.wall[m.idx(cx, cy)] == 0 && m.doors[m.idx(cx, cy)] == nil {
                // an OPEN cell touching a wall CORNER — where a body realistically dies and settles
                var solidN = 0
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] where m.wall[m.idx(cx + dx, cy + dy)] != 0 { solidN += 1 }
                guard solidN >= 2 else { continue }                            // two walls meeting = a corner
                if (cx * 7 + cy * 13) % 11 != 0 { continue }                   // sample the map, don't grind all of it
                for k in 0..<8 {                                               // a sweep of facings
                    let ang = Float(k) / 8 * 2 * Float.pi
                    let dir = SIMD2<Float>(cosf(ang), sinf(ang))
                    // start shoved hard INTO the corner, as a death slide would leave it
                    let start = SIMD2<Float>(Float(cx) + 0.5, Float(cy) + 0.5) + dir * 0.45
                    cases += 1
                    trunkBefore = max(trunkBefore, penetration(start, r))
                    let fixed = MeshCreature.resolvePoseOutOfSolids(start, fwd: dir, r: r, back: back, front: front,
                                                                   map: m, props: world.propColliders, taperMin: 0.8)
                    let tp = penetration(fixed, r)
                    trunkAfter = max(trunkAfter, tp)
                    tipAfter = max(tipAfter, capsuleWorst(fixed, dir, 0.8))
                    if tp > 0.02 { trunkFail += 1 }
                }
            } }
            print(String(format: "RASTERSHOT: pose-resolve %d corner cases · TRUNK penetration before %.3f → after %.3f (%d buried) · worst extremity overlap %.3f",
                         cases, trunkBefore, trunkAfter, trunkFail, tipAfter))

            // ...and what a frame PAYS for it. The resolve used to run in the render pass over the
            // visible drones; it is the sim's now, so it covers every creature — and combat reads
            // the answer, which is the whole point (you hit what you see). That makes it CPU work
            // inside a 16.7 ms budget, so the cost is printed rather than assumed. A settled corpse
            // resolves ONCE and is free from then on, which is what makes a late, body-strewn floor
            // cheaper here than it was in the render pass.
            let pw = World(level: 3, colonyIndex: 2, seed: 11)
            _ = rr.render(pw, into: canvas)                       // installs the pose resolve
            for i in pw.monsters.indices where i % 2 == 0 { pw.monsters[i].state = .dead }
            pw.refreshDrawnPositions()                            // settle the fallen once, as a played floor would
            let live = pw.monsters.filter { $0.alive }.count, fallen = pw.monsters.count - live
            let passes = 200
            let t0 = Date()
            for _ in 0..<passes { pw.refreshDrawnPositions() }
            let ms = -t0.timeIntervalSinceNow / Double(passes) * 1000
            print(String(format: "RASTERSHOT: pose-resolve costs %.3f ms per pass (%d live + %d settled, %d prop colliders)",
                         ms, live, fallen, pw.propColliders.count))
        }

        // INDUSTRIAL FLOORS check (7–8): the working plant. Frame the longest clear run in a floor-7 level and
        // the widest room — verify raw ROCK walls with riveted IRON where a run was finished, rock deck, and
        // NO display banks / NO dormitory bunks (those belong to the upper floors).
        do {
            let world = World(level: 7, colonyIndex: 0, seed: 3)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
            world.monsters = []; world.colonists = []                     // clear so the architecture reads
            // longest clear axis-run → a corridor/hall view down its length
            var best = (len: 0, x: 0, y: 0, dx: 1, dy: 0)
            for y in 1..<(m.h - 1) { for x in 1..<(m.w - 1) where op(x, y) {
                for (dx, dy) in [(1, 0), (0, 1)] {
                    var n = 0
                    while op(x + dx * n, y + dy * n) { n += 1 }
                    if n > best.len { best = (n, x, y, dx, dy) }
                }
            } }
            if best.len >= 5 {
                world.player.pos = SIMD2(Float(best.x) + 0.5 + Float(best.dx) * 0.6, Float(best.y) + 0.5 + Float(best.dy) * 0.6)
                world.player.dir = atan2(Float(best.dy), Float(best.dx))
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-industrial.png"))
                let banks = (0..<(m.w * m.h)).filter { m.wall[$0] == WallTex.computer.rawValue }.count
                let bunks = world.props.filter { $0.kind == .bunk }.count
                let rock = (0..<(m.w * m.h)).filter { m.wall[$0] == WallTex.stone.rawValue }.count
                let iron = (0..<(m.w * m.h)).filter { m.wall[$0] == WallTex.ironPlate.rawValue }.count
                print("RASTERSHOT: wrote raster-industrial.png (floor 7, run \(best.len) at \(best.x),\(best.y); rock \(rock), iron \(iron), display-bank cells \(banks), bunks \(bunks); static \(rr.totalVertCount) verts, per-frame props \(rr.dynVertCount)/\(rr.dynCapacity))")
            } else { print("RASTERSHOT: industrial check skipped (no long run)") }
            // PIPEWORK — frame a placed FITTING (valve or gauge) head-on: stand a couple of cells off the wall
            // it hangs on, looking at it, so the copper run, its flanges and the fitting all read.
            for f in m.pipeFittings.prefix(24) {
                let fx = Int(f.x), fz = Int(f.y)
                let n2 = SIMD2<Float>(cosf(f.z), sinf(f.z))               // wall outward normal (into the room)
                let sx = f.x + n2.x * 2.1, sz = f.y + n2.y * 2.1
                guard op(Int(sx), Int(sz)), op(Int(f.x + n2.x), Int(f.y + n2.y)) else { continue }
                world.player.pos = SIMD2(sx, sz)
                world.player.dir = atan2(-n2.y, -n2.x)                    // face back at the wall
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-pipework.png"))
                let routedCells = (0..<(m.w * m.h)).filter { m.wall[$0] == 0 && m.pipe[$0] > 0.5 }.count
                print("RASTERSHOT: wrote raster-pipework.png (\(f.w < 0.5 ? "valve" : "gauge") at \(fx),\(fz); \(m.pipeFittings.count) fittings, \(routedCells) routed cells, \(rr.pipeVertCount) pipe verts of \(rr.totalVertCount) total)")
                break
            }
            // PIPE RUN TERMINUS — where a wall-hugging run reaches the end of its wall and stops. Nothing
            // in this set covered one, which is how an open bore at that end survived a baseline and two
            // reports: the run's tube was uncapped, and looking along its axis you saw straight down it.
            // Found from the routing mask (a routed cell whose neighbour along the run is unrouted) and
            // framed from along the run, which is the only angle the bore is visible from.
            var endShot = false
            for yy in 2..<(m.h - 2) where !endShot {
                for xx in 2..<(m.w - 2) where !endShot {
                    guard op(xx, yy), m.pipe[m.idx(xx, yy)] > 0.5 else { continue }
                    for (ax, ay) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nx = xx + ax, ny = yy + ay
                        guard m.inBounds(nx, ny), !(op(nx, ny) && m.pipe[m.idx(nx, ny)] > 0.5) else { continue }
                        // stand back ALONG the run, on the far side, as far as the floor stays open
                        var stand = SIMD2<Float>(Float(xx) + 0.5, Float(yy) + 0.5)
                        var got = false
                        for d in stride(from: Float(1.5), through: 3.5, by: 0.5) {
                            let p = SIMD2<Float>(Float(xx) + 0.5 - Float(ax) * d, Float(yy) + 0.5 - Float(ay) * d)
                            guard op(Int(p.x), Int(p.y)) else { break }
                            stand = p; got = true
                        }
                        guard got else { continue }
                        world.player.pos = stand
                        world.player.dir = atan2(Float(ay), Float(ax))
                        _ = rr.render(world, into: canvas)
                        Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-pipe-end.png"))
                        print("RASTERSHOT: wrote raster-pipe-end.png (run ends at \(xx),\(yy), viewed along \(ax),\(ay))")
                        endShot = true
                        break
                    }
                }
            }
            // TEE + RISER close-up — find the START of a tall stretch along a wall (the renderer feeds the high
            // main there with a single riser off a tee) and stand off it, so the junction bodies read.
            var teeShot = false
            for yy in 1..<(m.h - 1) where !teeShot {
                for xx in 1..<(m.w - 1) where !teeShot {
                    let i = m.idx(xx, yy)
                    guard m.wall[i] == 0, m.pipe[i] > 0.5, m.ceilY[i] > 1.5 else { continue }
                    guard m.inBounds(xx, yy - 1), m.wall[m.idx(xx, yy - 1)] != 0, m.doors[m.idx(xx, yy - 1)] == nil else { continue }
                    let prevI = m.idx(xx - 1, yy)                                      // wall to the N → run travels along X
                    guard !(m.wall[prevI] == 0 && m.pipe[prevI] > 0.5 && m.ceilY[prevI] > 1.5) else { continue }  // a stretch START
                    guard op(xx, yy + 1), op(xx, yy + 2) else { continue }
                    world.player.pos = SIMD2(Float(xx) + 0.85, Float(yy) + 2.3)
                    world.player.dir = -.pi / 2                                        // face the wall the run hugs
                    _ = rr.render(world, into: canvas)
                    Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-tee.png"))
                    print("RASTERSHOT: wrote raster-tee.png (riser + tee at the tall stretch starting \(xx),\(yy))")
                    teeShot = true
                }
            }
            // DOUBLE-HEIGHT HALL — stand in a normal-height cell looking into a tall one, so the storey change
            // and the soffit that closes the step both read in one frame.
            var shot = false
            for yy in 1..<(m.h - 1) where !shot {
                for xx in 1..<(m.w - 1) where !shot && op(xx, yy) && m.ceilY[m.idx(xx, yy)] < 1.5 {
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let tx = xx + dx, ty = yy + dy
                        guard op(tx, ty), m.ceilY[m.idx(tx, ty)] > 1.5 else { continue }        // a tall cell next door
                        guard op(tx + dx * 3, ty + dy * 3) else { continue }                    // and depth beyond it to see
                        world.player.pos = SIMD2(Float(xx) + 0.5, Float(yy) + 0.5)
                        world.player.dir = atan2(Float(dy), Float(dx))
                        _ = rr.render(world, into: canvas)
                        Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-tallhall.png"))
                        let tall = (0..<(m.w * m.h)).filter { m.ceilY[$0] > 1.5 }.count
                        print("RASTERSHOT: wrote raster-tallhall.png (from \(xx),\(yy) into the hall at \(tx),\(ty); \(tall) tall cells)")
                        shot = true; break
                    }
                }
            }
            // BULKHEAD on the plant wall — mirror buildPlantLamps' rule (open cell on the 5/1 grid backing onto
            // solid wall) and stand off it, so the fixture that lights these floors is verified in place.
            outer: for y in 1..<(m.h - 1) where y % 4 == 1 {
                for x in 1..<(m.w - 1) where x % 4 == 1 && op(x, y) {
                    for (dx, dy) in [(0, -1), (0, 1), (-1, 0), (1, 0)] {
                        let wx = x + dx, wy = y + dy
                        guard m.inBounds(wx, wy), m.wall[m.idx(wx, wy)] != 0, m.doors[m.idx(wx, wy)] == nil else { continue }
                        guard op(x - dx * 2, y - dy * 2), op(x - dx * 3, y - dy * 3) else { continue }   // room to stand back and face it
                        // nothing in the sight line — a structural column in the way hides the fixture entirely
                        let sight = (0...2).map { SIMD2<Float>(Float(x - dx * $0) + 0.5, Float(y - dy * $0) + 0.5) }
                        if world.props.contains(where: { pr in sight.contains { simd_length(pr.pos - $0) < 0.75 } }) { continue }
                        world.player.pos = SIMD2(Float(x - dx * 3) + 0.5, Float(y - dy * 3) + 0.5)
                        world.player.dir = atan2(Float(dy), Float(dx))
                        _ = rr.render(world, into: canvas)
                        Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-plantlamp.png"))
                        print("RASTERSHOT: wrote raster-plantlamp.png (bulkhead on the wall at \(wx),\(wy))")
                        break outer
                    }
                }
            }
        }

        // MACHINE HALL check (7–8): the imported plant machinery in place. One view standing well back from
        // the hall's centrepiece so its full height reads against the double-height roof steel, and one down
        // a wall where the compressors and switchgear are ranked. Machinery is STATIC level geometry, so what
        // these frames show is baked into the level mesh, not rebuilt per frame.
        for lvl in [7, 8] {
            let world = World(level: lvl, colonyIndex: 0, seed: 3)
            let m = world.map
            world.monsters = []; world.colonists = []                    // clear so the architecture reads
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
            /// Stand back from `t` and look at it. Maximising distance is the wrong objective — it parks
            /// the camera in whichever side passage reaches furthest and fills half the frame with the
            /// rock beside it. So cap the range at a distance that still shows the whole machine, and
            /// insist the standpoint has open floor to BOTH sides: that is what distinguishes standing
            /// in the hall from standing in a corridor leading out of it.
            func frame(_ t: SIMD2<Float>, _ tag: String) {
                var best = (d: Float(0), pos: SIMD2<Float>(0, 0))
                for a in stride(from: Float(0), to: 6.2831, by: 0.26) {
                    let dir = SIMD2<Float>(cos(a), sin(a)), side = SIMD2<Float>(-dir.y, dir.x)
                    var k: Float = 1.8
                    while k <= 5.2 {
                        let q = t + dir * k
                        if !op(Int(q.x), Int(q.y)) { break }
                        let lf = q + side, rt = q - side
                        if k > best.d, op(Int(lf.x), Int(lf.y)), op(Int(rt.x), Int(rt.y)) { best = (k, q) }
                        k += 0.4
                    }
                }
                guard best.d >= 2.0 else { print("RASTERSHOT: \(tag) — no standpoint"); return }
                world.player.pos = best.pos
                world.player.dir = atan2f(t.y - best.pos.y, t.x - best.pos.x)
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1,
                                  to: dir.appendingPathComponent("\(tag).png"))
                print("RASTERSHOT: wrote \(tag).png (from \(best.pos), \(String(format: "%.1f", best.d)) back)")
            }
            if let hero = world.props.first(where: { $0.kind == .machineFilter || $0.kind == .machineColumn }) {
                frame(hero.pos, "raster-machinehall-L\(lvl)")
            } else {
                print("RASTERSHOT: L\(lvl) has no centrepiece machine")
            }
            if let comp = world.props.first(where: { $0.kind == .machineCompressor }) {
                frame(comp.pos, "raster-machinewall-L\(lvl)")
            }
            // COST OF THE MACHINERY, measured rather than assumed. It is static geometry, so it costs
            // no CPU rebuild — but it is ~296k vertices added to a ~550k static mesh, drawn in full
            // every frame including the shadow passes, and that lands squarely on the GPU time that the
            // frame log already showed as the dominant remaining cost on these floors. A/B by stripping
            // the machine props and rebuilding the level, from the same camera.
            func medianMS(_ w: World) -> Double {
                var ms: [Double] = []
                for _ in 0..<12 { let t = ProcessInfo.processInfo.systemUptime; _ = rr.render(w, into: canvas); ms.append((ProcessInfo.processInfo.systemUptime - t) * 1000) }
                ms.sort(); return ms[ms.count / 2]
            }
            let withMach = medianMS(world)
            let bare = World(level: lvl, colonyIndex: 0, seed: 3)
            bare.monsters = []; bare.colonists = []
            bare.props.removeAll { RasterRenderer.machineKind($0.kind) }   // machineSpec is private; machineKind is the internal predicate
            bare.player.pos = world.player.pos; bare.player.dir = world.player.dir
            let without = medianMS(bare)
            print(String(format: "RASTERSHOT: L%d machinery frame cost — %.2fms with, %.2fms without (+%.2fms, %+.0f%%)",
                         lvl, withMach, without, withMach - without, (withMach / max(without, 1e-6) - 1) * 100))
        }

        // FUEL STORE check: the 2×2 hazard-doored fuel chamber — how it reads from OUTSIDE (the hazard-striped
        // door set in the room wall = the "fuel store" sign), framed THROUGH the open doorway, and from INSIDE
        // (a tight lit chamber packed with red/blue oil drums, the marine's only refuel).
        do {
            // A run seed that seats one of THE SEVEN on this floor, so the store frames show her —
            // she is the whole reason the store is sealed, and a store shot without her tells half
            // the story. Searched, not hard-coded: the cast is a function of the seed, and a magic
            // number here would quietly stop showing her the day the deal changes.
            var runSeed: UInt64 = 1
            while runSeed < 4096, Progression.survivor(building: 0, level: 1, runSeed: runSeed) == nil { runSeed += 1 }
            var done = false
            for seed in [UInt64(3), 7, 12, 21, 33, 44, 58, 71] where !done {
                let world = World(level: 1, colonyIndex: 0, seed: seed, runSeed: runSeed)
                let m = world.map
                guard !m.fuelStore.isEmpty else { continue }
                var doorI = -1
                for i in m.doors.keys.sorted() where m.wall[i] == WallTex.doorHazard.rawValue { doorI = i; break }   // sorted: dictionary order is per-process random
                guard doorI >= 0 else { continue }
                let dcx = doorI % m.w, dcy = doorI / m.w
                var outX = 0, outY = 0                                             // door → chamber direction
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)]
                    where m.inBounds(dcx + dx, dcy + dy) && m.fuelStore.contains(m.idx(dcx + dx, dcy + dy)) { outX = dx; outY = dy; break }
                guard outX != 0 || outY != 0 else { continue }
                let face = atan2(Float(outY), Float(outX))                         // look from the room toward the chamber
                func openRoom(_ k: Int) -> Bool { let x = dcx - outX * k, y = dcy - outY * k
                    return m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
                let perpX = outY, perpY = outX                                     // 2-wide axis (matches MapGen)
                // OUTSIDE — hazard door CLOSED, facing it from 1 cell back (the door fills the frame). The
                // warning lamps flash amber; freeze elapsed at a BRIGHT phase, then a DIM phase, to show the blink.
                m.doors[doorI] = DoorState()
                let backOut = openRoom(2) ? 2 : 1                                   // 2 cells reads the door set in the wall (1 overexposes at point-blank)
                world.player.pos = SIMD2(Float(dcx - outX * backOut) + 0.5, Float(dcy - outY * backOut) + 0.5)
                world.player.dir = face
                world.elapsed = 0.462                                              // sin(elapsed·3.4) ≈ 1 → lamps lit
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-fuelstore-out.png"))
                world.elapsed = 0.924                                              // sin ≈ 0 → lamps dim (the OFF beat)
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-fuelstore-out-dim.png"))
                // THROUGH THE DOORWAY — from the front room cell, door OPEN: the drum stack framed by the hazard jamb
                world.elapsed = 0.462
                m.doors[doorI] = DoorState(open: 1.0)
                world.player.pos = SIMD2(Float(dcx - outX) + 0.5, Float(dcy - outY) + 0.5)
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-fuelstore-open.png"))
                // INSIDE — stand in the drum-free throat cell and aim at the CENTROID of the store's drums, so the
                // packed 2×2 stack of red/blue barrels fills the frame (the wide FOV from the doorway read as a room).
                let storeDrums = world.drums.filter { m.fuelStore.contains(m.idx(Int($0.pos.x), Int($0.pos.y))) }
                let throat = SIMD2<Float>(Float(dcx + outX) + 0.5, Float(dcy + outY) + 0.5)
                let centroid = storeDrums.isEmpty ? throat + SIMD2(Float(outX), Float(outY))
                    : storeDrums.reduce(SIMD2<Float>(0, 0), { $0 + $1.pos }) / Float(storeDrums.count)
                world.player.pos = throat
                world.player.dir = atan2(centroid.y - throat.y, centroid.x - throat.x)
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-fuelstore-in.png"))
                // BULKHEAD — from the throat, aim at the +perp side-wall fixture (concrete wall + caged lamp + a drum)
                let bh = SIMD2<Float>(Float(dcx) + 0.5 + Float(outX) * 1.5 + Float(perpX) * 1.5,
                                      Float(dcy) + 0.5 + Float(outY) * 1.5 + Float(perpY) * 1.5)
                world.player.dir = atan2(bh.y - throat.y, bh.x - throat.x)
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-fuelstore-bulkhead.png"))
                let who = world.colonists.first.map { Colonist.modelNames[$0.variant] } ?? "nobody"
                print("RASTERSHOT: wrote raster-fuelstore-{out,out-dim,open,in,bulkhead}.png (seed \(seed), door \(dcx),\(dcy), chamber+(\(outX),\(outY)), \(m.fuelStore.count) cells, \(storeDrums.count) drums, survivor: \(who) [runSeed \(runSeed)])")
                done = true
            }
            if !done { print("RASTERSHOT: fuel store check skipped (none carved)") }
        }

        // DORMITORY check: generate levels until one has a dorm (a bunk cluster), then frame the hall
        // from one end looking down it — verify the locker-bunk wall rows, centre rows, riveted columns,
        // flush/perpendicular bunks, plain walls, and the clear central aisle a body can walk.
        do {
            var done = false
            for seed in [UInt64(3), 7, 12, 21, 33, 44, 58] where !done {
                let world = World(level: 1, colonyIndex: 0, seed: seed)
                let m = world.map
                let bunks = world.props.filter { $0.kind == .bunk }
                guard bunks.count >= 8 else { continue }
                var lo = bunks[0].pos, hi = bunks[0].pos
                for b in bunks { lo = simd_min(lo, b.pos); hi = simd_max(hi, b.pos) }
                let alongX = (hi.x - lo.x) >= (hi.y - lo.y)
                func openAt(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
                let colCells = Set(world.props.filter { $0.kind == .column }.map { m.idx(Int($0.pos.x), Int($0.pos.y)) })
                var opens: [SIMD2<Float>] = []
                for y in (Int(lo.y) - 4)...(Int(hi.y) + 4) { for x in (Int(lo.x) - 4)...(Int(hi.x) + 4) where openAt(x, y) && !colCells.contains(m.idx(x, y)) {
                    opens.append(SIMD2(Float(x) + 0.5, Float(y) + 0.5))
                } }
                guard !opens.isEmpty else { continue }
                // stand INSIDE the hall near one end, offset into a side aisle (off the centre line so a
                // column isn't point-blank), looking down the long axis — sees the rows receding + columns.
                let mid: Float = alongX ? (lo.y + hi.y) * 0.5 : (lo.x + hi.x) * 0.5
                let aisleOff: Float = (alongX ? (hi.y - lo.y) : (hi.x - lo.x)) * 0.32
                let stand = alongX ? SIMD2(lo.x + 0.5, mid - aisleOff) : SIMD2(mid - aisleOff, lo.y + 0.5)
                let far   = alongX ? SIMD2(hi.x + 1, mid) : SIMD2(mid, hi.y + 1)
                let cam = opens.min(by: { simd_distance($0, stand) < simd_distance($1, stand) })!
                world.monsters = []                 // a dorm can be the Queen's lair — clear it so nothing blocks the view
                world.player.pos = cam
                world.player.dir = atan2(far.y - cam.y, far.x - cam.x)
                _ = rr.render(world, into: canvas)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1, to: dir.appendingPathComponent("raster-dorm.png"))
                print("RASTERSHOT: wrote raster-dorm.png (dormitory, seed \(seed), \(bunks.count) bunks)")
                done = true
            }
            if !done { print("RASTERSHOT: dorm check found no dormitory in the sampled seeds") }
        }

        // ── THE POWER SAG ── a distant fault drags the whole grid down for ~1.7 s: lamps, lit panels and
        // display walls droop together. It was live under the raymarcher and went dark with the pivot —
        // the sim kept computing a dropout every 25-60 s that nothing drew. Two frames, same camera, so
        // shotcheck holds the wiring: an effect nothing renders is invisible to every other check here.
        do {
            let world = World(level: 3, colonyIndex: 2, seed: 8)
            let m = world.map
            func op(_ x: Int, _ y: Int) -> Bool { m.inBounds(x, y) && m.wall[m.idx(x, y)] == 0 && m.doors[m.idx(x, y)] == nil }
            search: for y in 2..<(m.h - 2) { for x in 2..<(m.w - 2) where op(x, y) {
                var run = 0
                while op(x + run, y) { run += 1 }
                guard run >= 6 else { continue }
                world.player.pos = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
                world.player.dir = 0
                for (name, dim) in [("lit", Float(0)), ("sag", Float(0.72))] {
                    world.powerDim = dim
                    _ = rr.render(world, into: canvas)
                    Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.viewHeight, scale: 1,
                                      to: dir.appendingPathComponent("raster-power-\(name).png"))
                }
                print("RASTERSHOT: wrote raster-power-{lit,sag}.png (the distant-fault brownout at \(x),\(y))")
                break search
            } }
        }

        // ── THE ENDING ── one frame per beat, into the same directory, so shotcheck guards the
        // ceremony alongside everything else. This matters more here than anywhere: the ending is
        // reached exactly once, by clearing every floor of every citadel, so it is the one screen
        // no play-test will ever visit and the only one that could break and stay broken. The
        // sample times are chosen to catch each thing that could silently stop working: a citation
        // block mid-hold, the medal framing, and the window framing after two dissolves.
        if EndingArt.available {
            // `citation-fade` samples a block PART WAY OUT (a ≈ 0.28), which every other frame here
            // misses: the three below all sit at full opacity mid-hold, so the fade itself — the only
            // place the text's transparency is exercised — had no coverage at all. That is where the
            // citation used to darken toward black instead of thinning out, and over a pale plate it
            // was most legible at its faintest. A frame at full opacity cannot see that.
            for (name, at) in [("citation", Float(3.0)),
                               ("citation-fade", EndingArt.blockTime - 0.25),
                               ("medal", EndingArt.citationTime + 2.0),
                               ("window", EndingArt.citationTime + 10.0)] {
                FrontEnd.ending(canvas, t: at)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.height,
                                  scale: 1, to: dir.appendingPathComponent("ending-\(name).png"))
            }
            // …and the CODA, the very last thing the game shows. Guarded here for the same reason,
            // doubly so: it has no plate behind it, so a change to the wordmark treatment or the
            // canvas text path could empty the frame with nothing else to reveal it.
            FrontEnd.coda(canvas, t: FrontEnd.codaIn + 1)
            Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.height,
                              scale: 1, to: dir.appendingPathComponent("ending-coda.png"))
            // …and the VICTORY TALLY, where the ending lands. It carries the score a completed run
            // is recorded on, and it had no coverage of any kind until it became the ending's
            // destination — the one screen whose breaking would cost a player something real.
            let tw = World(level: Progression.totalFloors, colonyIndex: 5, seed: 77)
            FrontEnd.gameOver(canvas, world: tw, input: InputState(), qualifies: false, t: 0.1, victory: true)
            Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.height,
                              scale: 1, to: dir.appendingPathComponent("ending-tally.png"))
            // …and CITADEL SECURED, which had no coverage of any kind and carries the one line that
            // says where the run goes next. BOTH branches, because `destinationName` forks on the last
            // floor: mid-run it names the next citadel's planet, and after the sixth there is no
            // seventh — it names ARC CITY, where the ceremony above is held. The final-floor frame is
            // seen once per completed run, so it is the rarer of the two and the one that matters.
            // Rendered OVER THE WORLD, because that is what it is — an overlay on the floor you just
            // cleared, not a full-screen card. Drawing it onto whatever the previous capture left in the
            // canvas put the victory tally behind it and made the reference frame a lie.
            for (name, lvl, ci) in [("secured-mid", 8, 0), ("secured-final", Progression.totalFloors, 5)] {
                let sw = World(level: lvl, colonyIndex: ci, seed: 77)
                _ = rr.render(sw, into: canvas)
                FrontEnd.securedReport(canvas, world: sw, t: 0.1)
                Captures.writePNG(canvas.framebuffer, w: RenderConfig.width, h: RenderConfig.height,
                                  scale: 1, to: dir.appendingPathComponent("ending-\(name).png"))
            }
            print("RASTERSHOT: wrote 4 ending frames + the coda, the tally and both secured cards (ceremony runs \(String(format: "%.1f", EndingArt.duration))s)")
        } else {
            print("RASTERSHOT: no ending plate — ceremony frames skipped")
        }
    }
}
#endif
