// Citadel — the terminal arcade easter egg: a faithful clone of the 1978 classic,
// rendered entirely in amber inside the computer-desk CRT (Terminal.swift). It is
// ONE entry in the easter-egg pool; USEing a desk can zoom into it just like the
// text logs, and — like the rest — it's seen once per session.
//
// Controls are the marine's own: LEFT / RIGHT move the cannon, FIRE shoots (one
// shot on screen at a time, edge-triggered as on the original), USE steps back out.
// Three lives. A marching 5×11 formation that drops and speeds up as it thins,
// four erodable shields, dropping bombs, and a bonus saucer. It keeps its OWN
// persistent high-score table — three-letter initials, arcade style — which wipes
// together with the main game's Hall of the Fallen (see OptionsSheet.resetScores).
//
// The whole simulation runs in a fixed virtual playfield (VW × VH) and is scaled,
// letterboxed, into whatever glass rect the CRT gives us — so it is resolution-
// independent and deterministic (a seeded RNG drives bombs / the saucer), which
// also lets the headless CITADEL_TERMSHOT harness capture reproducible frames.

import Foundation
import CoreGraphics

// ── persistent arcade high scores ────────────────────────────────────────────
// A sibling of HighScores, stored beside it. Three-char initials + score only.
struct ArcadeEntry: Codable { var name: String; var score: Int }

final class ArcadeScores {
    static let shared = ArcadeScores()

    private(set) var entries: [ArcadeEntry] = []
    let maxEntries = 8
    private let url: URL

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Citadel", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("invaders-highscores.json")
        load()
    }

    /// A run must beat the lowest listed score — or claim a free slot while the
    /// table is not yet full. Zero never qualifies.
    func qualifies(_ score: Int) -> Bool {
        guard score > 0 else { return false }
        return entries.count < maxEntries || score > (entries.last?.score ?? 0)
    }

    @discardableResult
    func add(name: String, score: Int) -> Int {
        let trimmed = String(name.prefix(3))
        entries.append(ArcadeEntry(name: trimmed, score: score))
        entries.sort { $0.score > $1.score }
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        save()
        return entries.firstIndex { $0.name == trimmed && $0.score == score } ?? -1
    }

    /// Wipe the arcade table (called alongside HighScores.clear on Reset).
    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: url)
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ArcadeEntry].self, from: data) else { return }
        entries = decoded
            .map { ArcadeEntry(name: String($0.name.prefix(3)), score: $0.score) }
            .sorted { $0.score > $1.score }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: url) }
    }
}

// ── the game ─────────────────────────────────────────────────────────────────
final class SpaceInvaders {
    // Fixed virtual playfield. Portrait-ish 4:3 like the cabinet; letterboxed into
    // the (landscape) CRT glass, which reads exactly like an arcade board on a desk.
    private let VW: Float = 256, VH: Float = 200

    // Design data (the classic layout — named, not buried).
    private let cols = 11, rows = 5, startLives = 3
    private let rowPoints = [30, 20, 20, 10, 10]     // top row worth most, bottom least
    private let rowType   = [0, 1, 1, 2, 2]          // 0 squid · 1 crab · 2 octopus
    private let cellW: Float = 16, cellH: Float = 12 // formation cell (invader ~12 vu)
    private let margin: Float = 10
    private let topBar: Float = 18                   // score strip height
    private let saucerValues = [50, 100, 150, 300]

    // Layout, derived once from the constants above.
    private var pfTop: Float { topBar + 6 }
    private var groundY: Float { VH - 12 }
    private var cannonW: Float { 15 }
    private var cannonH: Float { 9 }
    private var cannonY: Float { groundY - cannonH - 2 }
    private var bunkerTop: Float { cannonY - 34 }
    private var formLeftMin: Float { margin }
    private var formLeftMax: Float { VW - margin - Float(cols) * cellW }

    enum Phase { case ready, playing, playerHit, cleared, over, enterInitials, scoreboard }
    private(set) var phase: Phase = .ready

    // formation
    private var alive = [Bool]()
    private var aliveCount = 0
    private var formX: Float = 0, formY: Float = 0
    private var marchDir: Float = 1
    private var stepTimer: Float = 0
    private var animFrame = 0
    private var wave = 0

    // player
    private var cannonX: Float = 0
    private var score = 0, lives = 0
    private var shotActive = false
    private var shotX: Float = 0, shotY: Float = 0

    // bombs
    private struct Bomb { var x: Float; var y: Float; var frame: Int }
    private var bombs = [Bomb]()
    private var bombTimer: Float = 0

    // saucer
    private var ufoActive = false
    private var ufoX: Float = 0, ufoDir: Float = 1, ufoValue = 0
    private var ufoTimer: Float = 0
    private var ufoScoreShow: Float = 0     // >0 → briefly show the awarded value

    // shields (four erodable bunkers), each a BW×BH occupancy grid
    private let shieldCols = 11, shieldRows = 8
    private let shieldCount = 4
    private var shields = [[Bool]]()        // one flat [Bool] per shield
    private var shieldW: Float = 0, shieldH: Float = 0
    private var shieldY: Float = 0

    // phase timers / fx
    private var phaseT: Float = 0
    private var blinkT: Float = 0

    // initials entry
    private let charset = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ ")
    private var initials = [0, 0, 0]
    private var initSlot = 0
    private var newRank = -1

    // input edges
    private var pLeft = false, pRight = false, pFire = false

    // audio — the synth arcade bleeps (nil in the headless harness). Set each
    // update so the internal event handlers can voice without threading it through.
    private var audio: AudioEngine?
    private var marchNote = 0          // 0…3 cycling — the four-note descending march
    private var ufoWarbleT: Float = 0  // periodic saucer warble timer

    // seeded RNG (deterministic → reproducible harness frames)
    private var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
    private func rand() -> Float {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return Float(rng >> 40) / Float(1 << 24)          // 0…1
    }
    private func randInt(_ n: Int) -> Int { n <= 0 ? 0 : Int(rand() * Float(n)) % n }

    // ── lifecycle ────────────────────────────────────────────────────────────
    /// Start a brand-new game (fresh lives/score/shields). Called when the pool
    /// picks the mini-game on terminal entry.
    func reset() {
        score = 0
        lives = startLives
        wave = 0
        // arcade scale: a bunker is ~2 large-invader widths (22px of a 224px field)
        // and ~2 invader-heights tall — deliberately narrower than the gaps between.
        shieldW = cellW * 1.4
        shieldH = shieldW * 0.72
        shieldY = bunkerTop
        buildShields()
        startWave()
        phase = .ready
        phaseT = 0
        pLeft = false; pRight = false; pFire = false
    }

    private func startWave() {
        alive = Array(repeating: true, count: cols * rows)
        aliveCount = cols * rows
        // each wave the formation starts a step lower — the squeeze tightens
        formX = (formLeftMin + formLeftMax) / 2
        formY = pfTop + 8 + Float(min(wave, 6)) * cellH * 0.5
        marchDir = 1
        stepTimer = 0
        animFrame = 0
        cannonX = VW / 2
        shotActive = false
        bombs.removeAll()
        bombTimer = 0.6
        ufoActive = false
        ufoTimer = 12
        phase = .ready
        phaseT = 0
    }

    private func buildShields() {
        shields = (0..<shieldCount).map { _ in shieldSilhouette() }
    }

    /// Carve the classic bunker outline into a fresh occupancy grid.
    private func shieldSilhouette() -> [Bool] {
        let pat = [
            "..#######..",
            ".#########.",
            "###########",
            "###########",
            "###########",
            "####...####",
            "###.....###",
            "##.......##",
        ]
        var g = [Bool](repeating: false, count: shieldCols * shieldRows)
        for (r, row) in pat.enumerated() {
            for (c, ch) in row.enumerated() where c < shieldCols && r < shieldRows {
                g[r * shieldCols + c] = (ch == "#")
            }
        }
        return g
    }

    // ── update ─────────────────────────────────────────────────────────────
    func update(dt: Float, left: Bool, right: Bool, fire: Bool, audio: AudioEngine? = nil) {
        self.audio = audio
        blinkT += dt
        let leftE = left && !pLeft, rightE = right && !pRight, fireE = fire && !pFire
        defer { pLeft = left; pRight = right; pFire = fire }
        phaseT += dt

        switch phase {
        case .ready:
            if phaseT > 0.9 { phase = .playing; phaseT = 0 }
        case .playing:
            tickPlaying(dt, left: left, right: right, fireE: fireE)
        case .playerHit:
            if phaseT > 1.1 {
                lives -= 1
                if lives <= 0 { phase = .over; phaseT = 0 }
                else { respawn() }
            }
        case .cleared:
            if phaseT > 1.2 { wave += 1; startWave() }
        case .over:
            if phaseT > 1.8 {
                if ArcadeScores.shared.qualifies(score) {
                    initials = [0, 0, 0]; initSlot = 0; phase = .enterInitials
                } else { phase = .scoreboard }
                phaseT = 0
            }
        case .enterInitials:
            tickInitials(leftE: leftE, rightE: rightE, fireE: fireE)
        case .scoreboard:
            break   // waits for USE (handled by the terminal) to step back out
        }
    }

    private func respawn() {
        cannonX = VW / 2
        shotActive = false
        bombs.removeAll()
        phase = .ready
        phaseT = 0
    }

    private func tickPlaying(_ dt: Float, left: Bool, right: Bool, fireE: Bool) {
        // cannon
        let cannonSpeed: Float = VW * 0.62
        if left  { cannonX -= cannonSpeed * dt }
        if right { cannonX += cannonSpeed * dt }
        cannonX = max(margin + cannonW / 2, min(VW - margin - cannonW / 2, cannonX))

        // fire (edge, one shot on screen)
        if fireE && !shotActive {
            shotActive = true
            shotX = cannonX
            shotY = cannonY
            audio?.arcadeShoot()
        }
        advanceShot(dt)

        // formation march
        stepTimer -= dt
        if stepTimer <= 0 { marchStep() }

        // bombs
        advanceBombs(dt)
        bombTimer -= dt
        if bombTimer <= 0 { dropBomb(); bombTimer = bombInterval() }

        // saucer
        advanceUFO(dt)
    }

    // formation extents (min/max alive col, max alive row) — cheap 55-cell scan
    private func extents() -> (minC: Int, maxC: Int, maxR: Int) {
        var minC = cols, maxC = -1, maxR = -1
        for r in 0..<rows {
            for c in 0..<cols where alive[r * cols + c] {
                if c < minC { minC = c }
                if c > maxC { maxC = c }
                if r > maxR { maxR = r }
            }
        }
        return (minC, maxC, maxR)
    }

    private func marchStep() {
        let (minC, maxC, maxR) = extents()
        guard maxC >= 0 else { return }
        let stepX = cellW * 0.22
        let leftEdge  = formX + Float(minC) * cellW
        let rightEdge = formX + Float(maxC + 1) * cellW
        let wantDrop = (marchDir > 0 && rightEdge + stepX > VW - margin)
                    || (marchDir < 0 && leftEdge  - stepX < margin)
        if wantDrop {
            formY += cellH * 0.6
            marchDir = -marchDir
            // landed on the shields / cannon line → the colony is lost
            let bottom = formY + Float(maxR + 1) * cellH
            if bottom >= cannonY { phase = .over; phaseT = 0; return }
        } else {
            formX += marchDir * stepX
        }
        animFrame ^= 1
        marchNote = (marchNote + 1) & 3
        audio?.arcadeMarch(marchNote)                 // four-note march; tempo = the step rate below
        // faster as the swarm thins (and each wave)
        let slow: Float = 0.55, fast: Float = 0.06
        let frac = Float(aliveCount) / Float(cols * rows)
        stepTimer = max(fast, (fast + (slow - fast) * frac) - Float(wave) * 0.02)
    }

    // step a projectile in sub-steps so it can't tunnel through a cell
    private func advanceShot(_ dt: Float) {
        guard shotActive else { return }
        let speed: Float = VH * 2.4
        var remaining = speed * dt
        let sub = cellH * 0.45
        while remaining > 0 && shotActive {
            let d = min(sub, remaining); remaining -= d
            shotY -= d
            if shotY < pfTop - 2 { shotActive = false; break }
            if ufoActive && shotY < pfTop + 8 && abs(shotX - ufoX) < 10 {
                score += ufoValue; ufoScoreShow = 1.2; ufoActive = false; shotActive = false
                audio?.arcadeUFOHit(); break
            }
            if hitInvaderAt(shotX, shotY) { shotActive = false; break }
            if shieldHit(shotX, shotY) { shotActive = false; break }
            // a rising shot can knock out a falling bomb
            if let bi = bombIndexAt(shotX, shotY) { bombs.remove(at: bi); shotActive = false; break }
        }
    }

    private func hitInvaderAt(_ x: Float, _ y: Float) -> Bool {
        let c = Int((x - formX) / cellW), r = Int((y - formY) / cellH)
        guard c >= 0, c < cols, r >= 0, r < rows else { return false }
        let idx = r * cols + c
        guard alive[idx] else { return false }
        // generous cell hitbox (inset a touch)
        alive[idx] = false
        aliveCount -= 1
        score += rowPoints[r]
        audio?.arcadeInvaderKilled()
        if aliveCount <= 0 { phase = .cleared; phaseT = 0 }
        return true
    }

    private func advanceBombs(_ dt: Float) {
        let speed: Float = VH * 0.9
        let sub = cellH * 0.45
        var i = 0
        while i < bombs.count {
            var remaining = speed * dt
            var removed = false
            bombs[i].frame = (Int(blinkT * 12) & 3)
            while remaining > 0 {
                let d = min(sub, remaining); remaining -= d
                bombs[i].y += d
                if bombs[i].y >= groundY { removed = true; break }
                if shieldHit(bombs[i].x, bombs[i].y) { removed = true; break }
                if phase == .playing && abs(bombs[i].x - cannonX) < cannonW / 2 && bombs[i].y >= cannonY {
                    phase = .playerHit; phaseT = 0
                    audio?.arcadePlayerHit()
                    removed = true; break
                }
            }
            if removed { bombs.remove(at: i) } else { i += 1 }
        }
    }

    private func bombIndexAt(_ x: Float, _ y: Float) -> Int? {
        for (i, b) in bombs.enumerated() where abs(b.x - x) < 4 && abs(b.y - y) < 5 { return i }
        return nil
    }

    private func bombInterval() -> Float {
        // more bombs, more often, as the game deepens (floored so it stays fair)
        let base = max(0.55, 1.7 - Float(wave) * 0.12)
        return base * (0.5 + rand())
    }

    private func dropBomb() {
        let maxBombs = min(3, 1 + wave / 2)
        guard bombs.count < maxBombs, aliveCount > 0 else { return }
        // pick a random column that still has invaders; drop from its lowest one
        var col = randInt(cols)
        for _ in 0..<cols {
            if (0..<rows).contains(where: { alive[$0 * cols + col] }) { break }
            col = (col + 1) % cols
        }
        var lowR = -1
        for r in 0..<rows where alive[r * cols + col] { lowR = r }
        guard lowR >= 0 else { return }
        let x = formX + Float(col) * cellW + cellW / 2
        let y = formY + Float(lowR + 1) * cellH
        bombs.append(Bomb(x: x, y: y, frame: 0))
    }

    private func advanceUFO(_ dt: Float) {
        if ufoScoreShow > 0 { ufoScoreShow -= dt }
        if ufoActive {
            ufoX += ufoDir * VW * 0.16 * dt
            ufoWarbleT -= dt
            if ufoWarbleT <= 0 { audio?.arcadeUFO(); ufoWarbleT = 0.18 }   // the saucer's telltale warble
            if ufoX < margin - 12 || ufoX > VW - margin + 12 { ufoActive = false; ufoTimer = 10 + rand() * 12 }
            return
        }
        ufoTimer -= dt
        if ufoTimer <= 0 && aliveCount > 3 {
            ufoActive = true
            ufoDir = rand() < 0.5 ? 1 : -1
            ufoX = ufoDir > 0 ? margin - 10 : VW - margin + 10
            ufoValue = saucerValues[randInt(saucerValues.count)]
        }
    }

    // shield collision + erosion. Returns true if the point was absorbed.
    private func shieldHit(_ x: Float, _ y: Float) -> Bool {
        guard y >= shieldY && y < shieldY + shieldH else { return false }
        let gap = (VW - 2 * margin - Float(shieldCount) * shieldW) / Float(shieldCount + 1)
        for s in 0..<shieldCount {
            let sx = margin + gap + Float(s) * (shieldW + gap)
            guard x >= sx && x < sx + shieldW else { continue }
            let cw = shieldW / Float(shieldCols), ch = shieldH / Float(shieldRows)
            let cc = Int((x - sx) / cw), cr = Int((y - shieldY) / ch)
            guard cc >= 0, cc < shieldCols, cr >= 0, cr < shieldRows else { return false }
            if shields[s][cr * shieldCols + cc] {
                // chip out the hit cell and a scatter of neighbours
                for dr in -1...1 {
                    for dc in -1...1 {
                        let nr = cr + dr, nc = cc + dc
                        guard nr >= 0, nr < shieldRows, nc >= 0, nc < shieldCols else { continue }
                        if (dr == 0 && dc == 0) || rand() < 0.55 {
                            shields[s][nr * shieldCols + nc] = false
                        }
                    }
                }
                return true
            }
            return false     // passed through an already-eroded gap
        }
        return false
    }

    private func tickInitials(leftE: Bool, rightE: Bool, fireE: Bool) {
        let n = charset.count
        if leftE  { initials[initSlot] = (initials[initSlot] + n - 1) % n }
        if rightE { initials[initSlot] = (initials[initSlot] + 1) % n }
        if fireE {
            initSlot += 1
            if initSlot >= 3 {
                let name = String(initials.map { charset[$0] }).trimmingCharacters(in: .whitespaces)
                newRank = ArcadeScores.shared.add(name: name.isEmpty ? "AAA" : name, score: score)
                phase = .scoreboard
                phaseT = 0
            }
        }
    }

    /// True once the run is finished and the board is showing — the terminal may
    /// keep it up until the player USEs to leave (nothing else to do here).
    var isFinished: Bool { phase == .scoreboard }
}

// ── sprites (1 char = 1 virtual dot; '.' is empty) ───────────────────────────
private let sprSquid = [[
    "...##...", "..####..", ".######.", "##.##.##",
    "########", ".#.##.#.", "#.#..#.#", ".#....#.",
], [
    "...##...", "..####..", ".######.", "##.##.##",
    "########", "..#..#..", ".#.##.#.", "#.#..#.#",
]]
private let sprCrab = [[
    "..#.....#..", "...#...#...", "..#######..", ".##.###.##.",
    "###########", "#.#######.#", "#.#.....#.#", "...##.##...",
], [
    "..#.....#..", "#..#...#..#", "#.#######.#", "###.###.###",
    "###########", ".#########.", "..#.....#..", ".#.......#.",
]]
private let sprOcto = [[
    "....####....", ".##########.", "############", "###.####.###",
    "############", "...##..##...", "..##.##.##..", "##........##",
], [
    "....####....", ".##########.", "############", "###.####.###",
    "############", "..###..###..", ".##..##..##.", "..##....##..",
]]
private let sprCannon = [
    ".......#.......", ".......#.......", "......###......", "......###......",
    ".#############.", "###############", "###############", "###############",
]
private let sprBoom = [
    "..#..#...#..#..", "#..#..#.#..#..#", ".#..#..#..#..#.", "..#.#.###.#.#..",
    "#..#.#####.#..#", ".#..#.###.#..#.", "#..#..#.#..#..#", ".#.#..#.#..#.#.",
]
private let sprSaucer = [
    "....########....", "..############..", ".##############.", "################",
    ".##.##.##.##.##.", "...##......##...", "..#..........#..",
]

extension SpaceInvaders {
    /// Paint the whole board, amber, into the CRT glass rect (letterboxed). `a`
    /// is the content fade-in (0→1 over the last of the zoom).
    func draw(_ c: Canvas2D, _ x0: Int, _ y0: Int, _ sw: Int, _ sh: Int, a: Float, t: Float) {
        let sc = min(Float(sw) / VW, Float(sh) / VH)
        let ox = Float(x0) + (Float(sw) - VW * sc) / 2
        let oy = Float(y0) + (Float(sh) - VH * sc) / 2
        let dot = max(1, Int(sc + 0.5))
        let amber   = Terminal.tint(Terminal.amber, a)
        let amberHi = Terminal.tint(Terminal.amberHi, a)
        let amberDim = Terminal.tint(Terminal.amberDim, a)
        let blinkOn = (Int(blinkT * 2) & 1) == 0

        func GX(_ v: Float) -> Int { Int(ox + v * sc) }
        func GY(_ v: Float) -> Int { Int(oy + v * sc) }
        func GS(_ v: Float) -> Int { max(1, Int(v * sc + 0.5)) }
        func fsz(_ vu: Float) -> CGFloat { CGFloat(max(uiS(7), Int(vu * sc))) }
        func sprite(_ pat: [String], _ cx: Float, _ cy: Float, _ color: UInt32) {
            let h = pat.count, w = pat.first?.count ?? 0
            for (r, row) in pat.enumerated() {
                for (i, ch) in row.enumerated() where ch != "." {
                    let px = Int(ox + (cx - Float(w) / 2 + Float(i)) * sc)
                    let py = Int(oy + (cy - Float(h) / 2 + Float(r)) * sc)
                    c.fillRect(px, py, dot, dot, color)
                }
            }
        }

        // ── score strip ──
        let best = max(score, ArcadeScores.shared.entries.first?.score ?? 0)
        c.label("SCORE", GX(margin), GY(3), size: fsz(6), color: amberDim, weight: .semibold, shadow: false, mono: true)
        c.label(String(format: "%06d", score), GX(margin), GY(9.5), size: fsz(7), color: amberHi, weight: .bold, shadow: false, mono: true)
        c.labelRight("HI-SCORE", GX(VW - margin), GY(3), size: fsz(6), color: amberDim, weight: .semibold, shadow: false, mono: true)
        c.labelRight(String(format: "%06d", best), GX(VW - margin), GY(9.5), size: fsz(7), color: amber, weight: .bold, shadow: false, mono: true)

        // ── formation ──
        if alive.count == cols * rows {
            for r in 0..<rows {
                let pat: [String]
                switch rowType[r] { case 0: pat = sprSquid[animFrame]; case 1: pat = sprCrab[animFrame]; default: pat = sprOcto[animFrame] }
                for cc in 0..<cols where alive[r * cols + cc] {
                    sprite(pat, formX + Float(cc) * cellW + cellW / 2, formY + Float(r) * cellH + cellH / 2, amber)
                }
            }
        }

        // ── saucer ──
        if ufoActive { sprite(sprSaucer, ufoX, pfTop + 4, amberHi) }
        if ufoScoreShow > 0 {
            c.labelCentered2("\(ufoValue)", GX(ufoX - 12), GS(24), GY(pfTop + 2), size: fsz(7), color: amberHi, weight: .bold, shadow: false, mono: true)
        }

        // ── shields ──
        let gap = (VW - 2 * margin - Float(shieldCount) * shieldW) / Float(shieldCount + 1)
        let cw = shieldW / Float(shieldCols), ch = shieldH / Float(shieldRows)
        if shields.count == shieldCount {
            for s in 0..<shieldCount {
                let sx = margin + gap + Float(s) * (shieldW + gap)
                for cr in 0..<shieldRows {
                    for cc in 0..<shieldCols where shields[s][cr * shieldCols + cc] {
                        c.fillRect(GX(sx + Float(cc) * cw), GY(shieldY + Float(cr) * ch), GS(cw) + 1, GS(ch) + 1, amber)
                    }
                }
            }
        }

        // ── bombs ──
        for b in bombs {
            let zig = Float((b.frame & 1) == 0 ? -1 : 1) * 1.2
            c.fillRect(GX(b.x + zig) - dot / 2, GY(b.y), dot, GS(5), amber)
        }

        // ── cannon / player shot ──
        if phase == .playerHit {
            sprite(sprBoom, cannonX, cannonY + cannonH / 2, amberHi)
        } else if phase == .playing || phase == .ready || phase == .cleared {
            sprite(sprCannon, cannonX, cannonY + cannonH / 2, amber)
        }
        if shotActive { c.fillRect(GX(shotX) - dot / 2, GY(shotY), dot, GS(6), amberHi) }

        // ── ground line + reserve lives + wave ──
        c.fillRect(GX(margin), GY(groundY), GS(VW - 2 * margin), max(1, dot), amberDim)
        c.label("\(max(0, lives))", GX(margin), GY(groundY + 2), size: fsz(7), color: amberHi, weight: .bold, shadow: false, mono: true)
        for i in 0..<max(0, lives - 1) {
            sprite(sprCannon, margin + 12 + Float(i) * 12, groundY + 6, amberDim)
        }
        c.labelRight("WAVE \(wave + 1)", GX(VW - margin), GY(groundY + 2), size: fsz(6), color: amberDim, weight: .semibold, shadow: false, mono: true)

        // ── phase overlays ──
        switch phase {
        case .ready:
            c.labelCentered2("PLAYER 1", x0, sw, GY(VH * 0.42), size: fsz(11), color: amberHi, weight: .bold, shadow: false, mono: true)
            if blinkOn { c.labelCentered2("GET READY", x0, sw, GY(VH * 0.52), size: fsz(8), color: amber, weight: .semibold, shadow: false, mono: true) }
        case .over:
            c.labelCentered2("GAME OVER", x0, sw, GY(VH * 0.46), size: fsz(13), color: amberHi, weight: .bold, shadow: false, mono: true)
        case .enterInitials:
            c.fillRectBlend(x0, y0, sw, sh, packRGBA(0, 0, 0), 0.72 * a)
            c.labelCentered2("NEW HIGH SCORE", x0, sw, GY(VH * 0.24), size: fsz(11), color: amberHi, weight: .bold, shadow: false, mono: true)
            c.labelCentered2(String(format: "SCORE  %06d", score), x0, sw, GY(VH * 0.34), size: fsz(8), color: amber, weight: .semibold, shadow: false, mono: true)
            drawInitials(c, cx: x0 + sw / 2, y: GY(VH * 0.50), sz: fsz(20), amber: amber, amberHi: amberHi, blinkOn: blinkOn)
            c.labelCentered2("[LEFT] [RIGHT] SELECT   [FIRE] ENTER", x0, sw, GY(VH * 0.66), size: fsz(6.5), color: amberDim, weight: .semibold, shadow: false, mono: true)
        case .scoreboard:
            c.fillRectBlend(x0, y0, sw, sh, packRGBA(0, 0, 0), 0.78 * a)
            c.labelCentered2("HIGH SCORES", x0, sw, GY(14), size: fsz(12), color: amberHi, weight: .bold, shadow: false, mono: true)
            let list = ArcadeScores.shared.entries
            var ly = GY(40)
            let lineH = GS(15)
            for (i, e) in list.enumerated() {
                let hot = (i == newRank && blinkOn)
                let col = hot ? amberHi : (i == newRank ? amberDim : amber)
                let rank = String(format: "%2d", i + 1)
                let nm = (e.name.isEmpty ? "---" : e.name).padding(toLength: 3, withPad: " ", startingAt: 0)
                let line = "\(rank).  \(nm)   " + String(format: "%06d", e.score)
                c.labelCentered2(line, x0, sw, ly, size: fsz(8), color: col, weight: hot ? .bold : .regular, shadow: false, mono: true)
                ly += lineH
            }
            if list.isEmpty {
                c.labelCentered2("NO SCORES YET", x0, sw, GY(VH * 0.5), size: fsz(8), color: amberDim, weight: .semibold, shadow: false, mono: true)
            }
        default:
            break
        }
    }

    private func drawInitials(_ c: Canvas2D, cx: Int, y: Int, sz: CGFloat, amber: UInt32, amberHi: UInt32, blinkOn: Bool) {
        let gap = Int(sz * 0.95)
        let x0 = cx - gap
        for s in 0..<3 {
            let ch = String(charset[initials[s]])
            let sx = x0 + s * gap
            let cur = (s == initSlot)
            let col = cur ? (blinkOn ? amberHi : amber) : amberHi
            c.labelCentered2(ch == " " ? "_" : ch, sx - gap / 2, gap, y, size: sz, color: col, weight: .bold, shadow: false, mono: true)
            if cur { c.fillRect(sx - gap / 4, y + Int(sz) + uiS(2), gap / 2, uiS(2), amberHi) }
        }
    }
}


// ── harness-only staging (stripped from signed/notarised builds) ─────────────
// Poses the mini-game in specific states for the CITADEL_TERMSHOT preview. These
// touch private state directly (same-file access) and never write to disk.
#if CITADEL_HARNESS
extension ArcadeScores {
    /// Seed the in-memory table for a preview WITHOUT persisting (leaves the
    /// user's real invaders-highscores.json untouched).
    func harnessSeed(_ e: [ArcadeEntry]) { entries = e }
}

extension SpaceInvaders {
    /// A lively in-progress frame: a part-descended, thinned swarm, a shot in
    /// flight, bombs falling, a saucer overhead and a chipped shield.
    func harnessMidPlay() {
        reset()
        phase = .playing; phaseT = 1
        formY += cellH * 2
        for _ in 0..<14 { let i = randInt(cols * rows); if alive[i] { alive[i] = false; aliveCount -= 1; score += rowPoints[i / cols] } }
        animFrame = 1
        cannonX = VW * 0.40
        shotActive = true; shotX = VW * 0.55; shotY = VH * 0.50
        bombs = [Bomb(x: VW * 0.30, y: VH * 0.56, frame: 0), Bomb(x: VW * 0.63, y: VH * 0.42, frame: 2)]
        ufoActive = true; ufoX = VW * 0.50; ufoValue = 150
        _ = shieldHit(margin + shieldW * 1.15, shieldY + shieldH * 0.30)
        _ = shieldHit(margin + shieldW * 1.30, shieldY + shieldH * 0.50)
    }

    func harnessInitials(score s: Int) {
        reset(); score = s; phase = .enterInitials
        initials = [9, 14, 13]   // "JON"
        initSlot = 2
        newRank = -1
    }

    func harnessScoreboard() { reset(); phase = .scoreboard; newRank = 1 }
}
#endif
