// Citadel — the campaign structure.
//
// The retake is a descent. Each colony PLANET is a citadel of `floorsPerBuilding`
// floors; you clear them one at a time (kill + burn each floor's Queen, find the
// exit, descend). Clear the last floor and the citadel is secured — you TELEPORT
// to the next of the six planets, a fresh citadel that descends surface→depths
// all over again. After the sixth planet it loops; only the floors get deeper,
// because difficulty scales with the absolute floor `level`, which never resets.
//
// `level` is the absolute floor counter (1, 2, 3, …). Everything the player sees
// about *where* they are — planet, floor-within-citadel, material tier, flooding —
// derives from it here, so there is one source of truth for the structure.

enum Progression {
    static let floorsPerBuilding = 8
    static let planets = ["DEMETER", "TANTALUS", "BOREAS", "PANDORA", "VULCAN", "VESPER"]

    /// 0-based citadel index — increments every `floorsPerBuilding` floors.
    static func building(_ level: Int) -> Int { (max(1, level) - 1) / floorsPerBuilding }
    /// 1…floorsPerBuilding — the floor WITHIN the current citadel (resets each building).
    static func floorInBuilding(_ level: Int) -> Int { ((max(1, level) - 1) % floorsPerBuilding) + 1 }
    /// Which of the six planets this floor sits on (cycles after the sixth).
    static func planetIndex(_ level: Int) -> Int { building(level) % planets.count }
    static func planetName(_ level: Int) -> String { planets[planetIndex(level)] }
    /// True on the last floor of a citadel — clearing it teleports to the next planet.
    static func isLastFloor(_ level: Int) -> Bool { floorInBuilding(level) == floorsPerBuilding }

    /// Every floor of every citadel — the run's end, and the only way to see the ending. Derived, so
    /// adding a planet or a floor moves the finish line without anybody remembering to update a 48.
    static var totalFloors: Int { floorsPerBuilding * planets.count }

    /// True once this floor was the LAST one: there is no next building to rotate into.
    static func isFinalFloor(_ level: Int) -> Bool { level >= totalFloors }
}
