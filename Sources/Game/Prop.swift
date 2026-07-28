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
    case papers      // records spilled across the deck in the panic — a flat scatter of sheets (decorative, no collider)
    case tapeDeck    // control-room reel-to-reel recorder — "THE SIGNAL" archive; USE (face it) to play the recording
    case column      // riveted-steel structural column, floor-to-ceiling — holds up the roof of the big dorm halls (free-standing, SOLID)
    case console     // operations-centre operator console — amber screen, keyboard, task lamp; ranked in rows facing the big board
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

// A FALLEN COLONIST — one of the ARC workers the swarm overran, left where they
// died. Not a monster and not SDF furniture: a real human mesh (see CREDITS)
// rasterised into the lair and TOPPLED into a corpse procedurally (the engine is
// rigless), so `seed` freezes a per-body pose and `yaw` the direction it fell.
// No collider — the marine steps over the dead. `burn`/`ashed` let a torched body
// char and crumble like a creature. Placed by MapGen, stored on the World, drawn
// by MeshCreature.compositeColonists. Doubles as both spawn record and live state.
struct Colonist {
    var pos: SIMD2<Float>
    var yaw: Float
    var seed: Float           // 0…1 → per-body pose variation
    var variant: Int          // index into Colonist.modelNames (-1 = unassigned; World assigns a session-unique model)
    var burn: Float = 0        // 0…1 scorched
    var ashed: Float = 0       // 0…2 crumbled → trodden flat

    /// The seven rigged human meshes (see CREDITS). A survivor is assigned ONE of
    /// these per placement; the World roster guarantees no two are seen in a session.
    static let modelNames = ["colonist_director", "colonist_woman", "colonist_worker",
                             "colonist_marine", "colonist_civ_a", "colonist_civ_b", "colonist_man"]
    static var modelCount: Int { modelNames.count }
}
