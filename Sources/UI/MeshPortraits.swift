// Citadel — dossier portrait cache for the textured-mesh creatures.
//
// The Field Intel codex shows the ACTUAL creatures the game renders — Tripo
// meshes (drone.usdz / queen.usdz), not the CreatureLab SDF sculpts (those are
// the fallback path when the mesh flags are off, via IntelPortraits). Each
// portrait is a static 3/4 hero bust rendered once at launch off the game's own
// MeshCreature instances (see GPUWorldRenderer.warmPortraits) and cached here,
// so the codex never blocks a frame on a Metal render.
//
// Keyed by MonsterKind: .alien → drone mesh, .queen → queen mesh. A kind is
// absent until warmed (or if its mesh flag is off / asset missing) — the codex
// then falls back to the SDF IntelPortraits plate.

import Foundation

enum MeshPortraits {
    struct Plate {
        let pixels: [UInt32]        // packed RGBA, transparent background
        let w, h: Int
        let footY: Int              // plate row of the creature's lowest point — the shadow line
    }

    // Per-kind hero-bust framing. Authored by eye (like IntelPortraits.yaw): a
    // small extra turn off the mesh's baked front so the face reads at a 3/4, and a
    // brightness gain so the bust sits well-lit on the dark card (the in-world
    // headlamp gain is tuned for a moving target in a dark room, not a still card).
    static func spin(_ kind: MonsterKind) -> Float { kind == .queen ? -0.35 : 0.55 }
    static func gain(_ kind: MonsterKind) -> Float { kind == .queen ? 2.2 : 2.3 }

    private static let lock = NSLock()
    private static var cache: [MonsterKind: Plate] = [:]

    static func store(_ kind: MonsterKind, _ plate: Plate) {
        guard plate.w > 0, plate.h > 0 else { return }
        lock.lock(); cache[kind] = plate; lock.unlock()
    }

    /// nil until warmed (or the mesh path is off) — the codex shows the SDF fallback.
    static func plate(_ kind: MonsterKind) -> Plate? {
        lock.lock(); defer { lock.unlock() }; return cache[kind]
    }

    static var ready: Bool { lock.lock(); defer { lock.unlock() }; return !cache.isEmpty }
}
