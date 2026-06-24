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
    var pos: SIMD2<Float>     // cell-centre footing on the floor
    var yaw: Float            // facing — local +Z points this way in world space
    var length: Float = 1     // wallPipe only: run length along the wall (world units)
}
