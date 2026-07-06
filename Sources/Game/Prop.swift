// Citadel — environmental props (furniture & fixtures).
//
// The citadels were working colonies until the swarm took them — so the rooms
// were lived in: barracks bunks, office desks with still-lit terminals, steel
// lockers, and the pipework/strutwork that runs every industrial wall. These are
// purely decorative SDF set-dressing (no gameplay collision — the marine and the
// brood pass through them), placed by MapGen against the walls so the room
// centres stay clear for the fight. Geometry is authored in GPURaymarch
// (furnitureShapes) and packed into the same GShape field as creatures/items.

import Foundation
import simd

enum FurnitureKind: Int, CaseIterable {
    case bunk        // barracks bed — frame + mattress + pillow (large open rooms)
    case desk        // office desk + still-powered terminal (small rooms)
    case chair       // office chair (sits with a desk)
    case locker      // tall steel storage locker (lines walls)
    case wallPipe    // a run of pipes + bracket bolted to a wall (everywhere)
}

struct Prop {
    var kind: FurnitureKind
    var pos: SIMD2<Float>     // footing on the floor (cell-centre for wall pieces; sub-cell for a chair tucked to a desk)
    var yaw: Float            // facing — local +Z points this way in world space
    var length: Float = 1     // wallPipe only: run length along the wall (world units)
    // Wall pieces are shoved back so their rear face sits flush against the wall
    // (a bunk/desk/locker stood ~⅓ of a cell — "approx 1m" — off the wall before).
    // A chair is free-standing in front of its desk, so it keeps its placed position.
    var againstWall: Bool = true
}
