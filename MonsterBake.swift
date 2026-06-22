// Citadel — organic-creature sprite bake (SHIPPING path).
//
// Turns the CreatureLab SDF roster into the 8-angle animation sprite sets the
// raycaster billboards — the same MonsterSprites contract the old mesh bake
// produced, but the fleshy raymarched look (Option C) instead of flat-shaded
// primitives. renderShapes() already emits straight-alpha RGBA (transparent
// background, inked silhouette), so each tile drops straight into a Sprite.
//
// Death frames are baked with the LIVE framing (not the lab's expanded death
// frame): the corpse heap then sits where the creature stood and the floor
// naturally clips the spreading blood pool into a flat puddle.
//
// Raymarching is far heavier than the old rasteriser, so the ~40 tiles per kind
// are rendered across all cores. Still zero asset files — generated at launch.

import Foundation

enum MonsterBake {
    static let tileW = 128, tileH = 176, angles = 8
    // Corpses collapse into a heap that spreads WIDER than the standing creature,
    // so death frames bake into a wider canvas. World-units-per-pixel is viewH/h
    // (independent of width), so the extra columns are just transparent margin —
    // the corpse renders at the same scale/position, but its silhouette can never
    // reach the tile edge, so it's never clipped into a hard straight line.
    static let deathTileW = 200

    /// Gameplay kind → its organic design. (Kept names are the gameplay roles;
    /// the creatures are the visual identities — see MonsterKind.displayName.)
    static func cdef(_ k: MonsterKind) -> CreatureLab.CDef {
        switch k {
        // bespoke biomechanical (Giger / Alien) forms — see CreatureLab.drone/queen.
        case .alien: return CreatureLab.drone()
        case .queen: return CreatureLab.queen()
        }
    }

    static func sprites(_ k: MonsterKind) -> MonsterSprites {
        let def = cdef(k)
        // 5 frames × 8 angles. frame: 0 walkA · 1 walkB · 2 attack · 3 collapsing · 4 final heap.
        let total = 5 * angles
        var tiles = [[UInt32]](repeating: [], count: total)
        tiles.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: total) { idx in
                let frame = idx / angles, angle = idx % angles
                buf[idx] = render(def, frame: frame, yaw: Float(angle) / Float(angles) * 2 * .pi)
            }
        }
        func wOf(_ f: Int) -> Int { f >= 3 ? deathTileW : tileW }   // death frames are wider
        func row(_ f: Int) -> [Sprite] { (0..<angles).map { Sprite(w: wOf(f), h: tileH, pixels: tiles[f * angles + $0]) } }
        return MonsterSprites(walk: [row(0), row(1)], attack: row(2), death: [row(3), row(4)])
    }

    private static func render(_ def: CreatureLab.CDef, frame: Int, yaw: Float) -> [UInt32] {
        let w = frame >= 3 ? deathTileW : tileW
        func live(_ shapes: [CreatureLab.Shape], ink: UInt8 = 255) -> [UInt32] {
            CreatureLab.renderShapes(shapes, viewH: def.viewH, groundY: def.groundY, yaw: yaw, w: w, h: tileH, inkAlpha: ink)
        }
        switch frame {
        case 0:  return live(def.build(0.25, 0))                                          // walkA — one leg forward
        case 1:  return live(def.build(0.75, 0))                                          // walkB — other leg forward
        case 2:  return live(def.build(0.25, 1))                                          // attack — reaching / lunging
        // corpses get a soft, semi-transparent edge (not a hard ink sticker line)
        case 3:  return live(CreatureLab.deadShapes(def.build(0, 0), d: 0.4, gib: false), ink: 150) // collapsing
        default: return live(CreatureLab.deadShapes(def.build(0, 0), d: 1.0, gib: false), ink: 150) // final bleeding heap
        }
    }
}
