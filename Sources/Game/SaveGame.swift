// Citadel — manual saves, ten named slots.
//
// A save is a CHECKPOINT, not a moment. Saving records the state the marine ARRIVED on this floor
// with — vitals, arsenal, score — and restoring puts her back in the descent to it. She never
// resumes half way through a fought room, and that is a design choice rather than a shortcut:
//
//   • It is what makes a save 300 bytes instead of a world dump. The floor is REGENERATED from the
//     run seed, so nothing about the map, the swarm, the corpses, the spent shells or the blood on
//     the deck is stored at all. Every one of those would otherwise have to be Codable, and would
//     have to STAY Codable through every future change to them.
//   • It cannot rot. A save holds no geometry, so a generation change cannot make an old save load
//     a broken floor — the worst it can do is build that floor differently, which is a floor, not
//     a corruption.
//   • The cost is bounded and legible: at most the current floor. On a 48-floor run that is the
//     right trade, and it matches what the checkpoint already IS internally — the state that
//     crosses a lift ride is exactly the state worth writing down.
//
// Keys are deliberately absent: a keycard belongs to the floor that locked its doors, and it is
// dropped at every descent. Restoring one would hand the marine a card for a floor she is about to
// see generated fresh.

import Foundation

struct SaveSlot: Codable {
    var name: String                 // the player's own label for the slot
    var stardate: String             // when it was written — the slot list's subtitle
    var runSeed: UInt64              // the RUN: rebuilds every floor, and casts the seven survivors
    var level: Int
    var colonyName: String           // quoted in the slot list so a save reads as a place, not a number
    var score: Int
    // ── the carry: exactly what crosses a floor boundary (see Renderer.applyCarry) ──
    var health: Int
    var armor: Int
    var mines: Int
    var current: Int                 // WeaponKind rawValue
    var weapons: [Bool]
    var ammo: [Int]

    /// One line for the menu's slot list.
    var summary: String {
        "\(name) — FLOOR \(level), \(colonyName) · \(score) pts · \(stardate)"
    }
}

final class SaveGames {
    static let slotCount = 10

    /// Ten fixed slots, nil where empty. Fixed rather than a growing list so the player picks a
    /// PLACE to write, the way a save menu has always worked, and overwriting is explicit.
    private(set) var slots: [SaveSlot?] = Array(repeating: nil, count: SaveGames.slotCount)
    private let url: URL

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Citadel", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("saves.json")
        load()
    }

    /// Explicit-path init, for the smoke test against a temp file.
    init(fileURL: URL) {
        url = fileURL
        load()
    }

    var isEmpty: Bool { slots.allSatisfy { $0 == nil } }
    var used: [(index: Int, slot: SaveSlot)] { slots.enumerated().compactMap { i, s in s.map { (i, $0) } } }

    @discardableResult
    func write(_ slot: SaveSlot, to index: Int) -> Bool {
        guard index >= 0, index < SaveGames.slotCount else { return false }
        slots[index] = slot
        save()
        return true
    }

    func erase(_ index: Int) {
        guard index >= 0, index < SaveGames.slotCount else { return }
        slots[index] = nil
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([SaveSlot?].self, from: data) else { return }
        // Tolerate a file written by a build with a different slot count rather than discarding
        // someone's saves over an off-by-one.
        var s = Array(decoded.prefix(SaveGames.slotCount))
        while s.count < SaveGames.slotCount { s.append(nil) }
        slots = s
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(slots) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
