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
