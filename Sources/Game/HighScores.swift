// Citadel — persistent high-score table.
//
// Top scores saved to ~/Library/Application Support/Citadel/highscores.json.
// Names are free-form (up to 32 characters, any Unicode incl. emoji) and the
// table survives across sessions.

import Foundation

struct HighScoreEntry: Codable {
    var name: String
    var score: Int
    var depth: Int              // deepest level reached — the mark of progress
    var colony: String          // the colony being retaken at run's end
    var stardate: String?       // "yyyymmdd::hhmm" — optional so older saves still decode
}

final class HighScores {
    private(set) var entries: [HighScoreEntry] = []
    let maxEntries = 10
    private let url: URL

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Citadel", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("highscores.json")
        load()
    }

    /// Explicit-path init (used by the smoke test against a temp file).
    init(fileURL: URL) {
        url = fileURL
        load()
    }

    /// Would this score make the table? While the table has empty slots, ANY
    /// run claims one (arcade-style) — so early games always get to enter a
    /// name; once full, you must beat the lowest entry.
    func qualifies(_ score: Int) -> Bool {
        return entries.count < maxEntries || score > (entries.last?.score ?? 0)
    }

    /// Insert, keep sorted descending and trimmed, persist. Returns the new
    /// entry's rank index (or -1).
    @discardableResult
    func add(name: String, score: Int, depth: Int, colony: String, stardate: String? = nil) -> Int {
        let trimmed = String(name.prefix(32))
        let entry = HighScoreEntry(name: trimmed, score: score, depth: depth, colony: colony, stardate: stardate)
        entries.append(entry)
        entries.sort { $0.score > $1.score }
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        save()
        return entries.firstIndex { $0.name == trimmed && $0.score == score && $0.depth == depth } ?? -1
    }

    /// Wipe the table and remove the saved file (Reset High Scores).
    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: url)
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([HighScoreEntry].self, from: data) else { return }
        entries = Array(decoded
            .map { HighScoreEntry(name: String($0.name.prefix(32)), score: $0.score,
                                  depth: $0.depth, colony: $0.colony, stardate: $0.stardate) }
            .sorted { $0.score > $1.score }
            .prefix(maxEntries))   // a hand-edited file can hold any number of rows; keep only the top table
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
