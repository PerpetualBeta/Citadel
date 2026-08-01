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

    /// Where the transit beam is taking the marine after clearing floor `level`. Normally the next
    /// citadel's planet — but `planetIndex` CYCLES, so past the sixth it read "destination DEMETER"
    /// and the end of the run looked like the start of another lap. There is no seventh citadel: the
    /// last jump is out, to ARC CITY, which is where the ceremony is held. ARC's transit has been
    /// carrying her the whole way ("ARC TRANSIT // DESCENDING") and this is the first time it says
    /// where to. Derived from `isFinalFloor`, so it stays right if a planet or a floor is ever added.
    static func destinationName(after level: Int) -> String {
        isFinalFloor(level) ? "ARC CITY" : planetName(level + 1)
    }
    /// True on the last floor of a citadel — clearing it teleports to the next planet.
    static func isLastFloor(_ level: Int) -> Bool { floorInBuilding(level) == floorsPerBuilding }

    /// Every floor of every citadel — the run's end, and the only way to see the ending. Derived, so
    /// adding a planet or a floor moves the finish line without anybody remembering to update a 48.
    static var totalFloors: Int { floorsPerBuilding * planets.count }

    /// True once this floor was the LAST one: there is no next building to rotate into.
    static func isFinalFloor(_ level: Int) -> Bool { level >= totalFloors }

    // ── THE DEPTHS ───────────────────────────────────────────────────────────────────────────
    // The bottom floors of every citadel are the DEPTHS — blasted rock rather than built
    // colony, and the floors where THE SIGNAL bleeds through with no source you can walk to.
    // ONE boundary with two consequences, which is why it lives here rather than at either
    // site: the reel-to-reel deck that teaches you the sound only appears ABOVE it (a floor
    // cannot introduce a sound its own air already carries), and the sourceless bleed only
    // exists BELOW it. Both used to hardcode the boundary, from opposite ends.

    /// How many floors at the bottom of each citadel are the depths.
    static let deepFloors = 3
    /// How many floors at the bottom are the WORKING PLANT — blasted rock, machine halls, no
    /// dormitories and no display banks, because nobody sleeps or monitors down there.
    static let plantFloors = 2
    /// The first plant floor. Several things ramp TOWARD it from the surface — headroom, failed
    /// light fixtures, the plant hum heard through the deck — so they need it by name rather than
    /// each counting to 7 on their own.
    static var industrialFirstFloor: Int { floorsPerBuilding - plantFloors + 1 }
    /// 1…`deckFloors` — the floors above the depths, the only ones a SIGNAL deck can sit on.
    static var deckFloors: Int { floorsPerBuilding - deepFloors }

    /// THE FAR SIGNAL's depth ramp, 0…1 — the SHAPE of the fade, not its level (`AudioEngine`
    /// owns the trim). Silent above the depths, then linear: a third of the way up on the first
    /// deep floor, full at the bottom, so reaching the deepest floor is the payoff.
    static func farSignalRamp(_ level: Int) -> Float {
        max(0, min(1, Float(floorInBuilding(level) - deckFloors) / Float(deepFloors)))
    }

    // ── THE SEVEN ────────────────────────────────────────────────────────────────────────────
    //
    // The only humans left alive-ish in the cluster, and there are exactly seven of them: seven
    // rigged people, one pool for the WHOLE run, distributed across the six buildings with no
    // repeat. A building gets none, one, or two. When the seven are spent that is everyone the
    // player will ever find — which is the point. They are not set-dressing that scales with the
    // level count; they are seven individuals, and meeting the same face twice would say the
    // opposite of what their absence says.
    //
    // Derived from the RUN seed rather than carried in session state, deliberately. A floor rebuilt
    // — or a save restored — recomputes the same seven people in the same places, so nothing about
    // them has to be serialised, and a floor generator needs no memory of the floors before it.
    struct Survivor { let variant: Int; let floorInBuilding: Int }

    /// The run's whole cast, indexed by building. Empty arrays are buildings that hold nobody.
    static func survivors(runSeed: UInt64) -> [[Survivor]] {
        let people = Colonist.modelCount
        // A distinct stream from level generation: mixed with a constant so the cast cannot
        // correlate with a floor's layout (same seed, unrelated decisions).
        var rng = Rng(seed: runSeed ^ 0x5AFE_C0DE_D00D_5EED)
        var pool = Array(0..<people)                                  // the seven, then shuffled
        for i in stride(from: pool.count - 1, to: 0, by: -1) { pool.swapAt(i, rng.i(0, i)) }
        // TWO slots per building, shuffled, first `people` taken — which is exactly the spec: no
        // building can hold more than two, and with 12 slots for 7 people some buildings hold none.
        var slots = (0..<planets.count).flatMap { [$0, $0] }
        for i in stride(from: slots.count - 1, to: 0, by: -1) { slots.swapAt(i, rng.i(0, i)) }

        var out = [[Survivor]](repeating: [], count: planets.count)
        for (n, b) in slots.prefix(people).enumerated() {
            // distinct floors within a building — two people who sealed themselves in different
            // stores on the same floor would read as a crowd, and there are no crowds left
            var floor = rng.i(1, floorsPerBuilding)
            var guard0 = 0
            while out[b].contains(where: { $0.floorInBuilding == floor }), guard0 < floorsPerBuilding {
                floor = floor % floorsPerBuilding + 1; guard0 += 1
            }
            out[b].append(Survivor(variant: pool[n], floorInBuilding: floor))
        }
        return out
    }

    /// The one person sealed into this floor's fuel store, if this floor has one.
    static func survivor(building: Int, level: Int, runSeed: UInt64) -> Survivor? {
        guard building >= 0, building < planets.count else { return nil }
        let f = floorInBuilding(level)
        return survivors(runSeed: runSeed)[building].first { $0.floorInBuilding == f }
    }
}
