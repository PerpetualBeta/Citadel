// Citadel — projectiles (rockets, plasma, enemy bolts and fireballs).
//
// Hitscan weapons resolve instantly; everything else flies as a Projectile
// that the World steps each frame, tests against walls and actors, and (for
// rockets / BFG) detonates with splash damage.

import Foundation
import simd

enum ProjectileKind: Int, CaseIterable {
    case plasma, rocket, bolt, fireball, bfgBall
    var speed: Float {
        switch self {
        case .plasma: return 20
        case .rocket: return 13
        case .bolt: return 15
        case .fireball: return 9
        case .bfgBall: return 11
        }
    }
    /// Splash radius in cells (0 = direct hit only).
    var splash: Float {
        switch self {
        case .rocket: return 2.0
        case .bfgBall: return 3.2
        default: return 0
        }
    }
    var lifetime: Float { 4.0 }
}

struct Projectile {
    var pos: SIMD2<Float>
    var vel: SIMD2<Float>
    var kind: ProjectileKind
    var damage: Int
    var fromPlayer: Bool
    var life: Float
}
