// Citadel — audio engine (the asset switch).
//
// Citadel deliberately BREAKS the Jorvik no-assets rule (see the design notes):
// its atmosphere leans too hard on sound to synthesise convincingly. So this is
// a real FILE-BASED player — sampled SFX and looping ambient/music stems loaded
// from `Resources/Audio/` in the app bundle — wired through AVAudioEngine with
// three gain buses (music 0, sfx 1, ambient 2).
//
// THE SWITCH IS GRACEFUL. Every sound has a procedural fallback: the old
// from-scratch synth still lives at the bottom of this file, but it now only
// speaks when a sample is MISSING. Drop `plasma.wav` into Resources/Audio and
// the plasma rifle upgrades from synth blip to your sample automatically — no
// code change. With zero files present the game still sounds (the synth), so
// the build is always green and playable while the real assets are sourced.
// See Resources/Audio/README.txt for the drop-in manifest and docs/audio-sourcing.md.
//
// The level "soundtrack" is a REACTIVE ambient bed, not a melody: a stack of
// looping stems whose levels are crossfaded by a live threat signal, so the mix
// thickens as the swarm closes in. setTension() feeds it from the game each
// frame; updateMusic() does the crossfade. (With no bed stems present the same
// threat signal drives a synth fallback bed so the reactivity is still audible.)

import Foundation
import AVFoundation
import os

final class AudioEngine {
    // Synth waveform tags (fallback voices only).
    static let sine = 0, square = 1, triangle = 2, saw = 3, noise = 4

    // ── logical sounds (the asset manifest) ─────────────────────────────────
    // Each case maps to a base filename in Resources/Audio/. The loader accepts
    // <base>.<ext> and numbered variants <base>1..<base>4.<ext> (picked at
    // random) for ext in wav/caf/aiff/aif/m4a/mp3. `bed_*` / `music_title` loop.
    enum Sound: CaseIterable {
        case plasma, flamethrower, rocket
        case hiss                  // shared alien hiss pool: drone + Queen, sight + pain (random)
        case droneDeath, queenDeath
        case explosion, doorOpen, locked, pickup, secret, exit, playerPain, playerDeath
        case musicTitle, bedDrone, bedPulse, bedTension, bedSwarm

        var base: String {
            switch self {
            case .plasma: return "plasma"
            case .flamethrower: return "flamethrower"
            case .rocket: return "rocket"
            case .hiss: return "hiss"
            case .droneDeath: return "drone_death"
            case .queenDeath: return "queen_death"
            case .explosion: return "explosion"
            case .doorOpen: return "door_open"
            case .locked: return "locked"
            case .pickup: return "pickup"
            case .secret: return "secret"
            case .exit: return "exit"
            case .playerPain: return "player_pain"
            case .playerDeath: return "player_death"
            case .musicTitle: return "music_title"
            case .bedDrone: return "bed_drone"
            case .bedPulse: return "bed_pulse"
            case .bedTension: return "bed_tension"
            case .bedSwarm: return "bed_swarm"
            }
        }
        // bus: 0 music, 1 sfx, 2 ambient.
        var bus: Int {
            switch self {
            case .musicTitle: return 0
            case .bedDrone, .bedPulse, .bedTension, .bedSwarm: return 2
            default: return 1
            }
        }
        var loop: Bool { bus != 1 }
        // per-sound trim so one sample doesn't dwarf the rest (1 = unity).
        var gain: Float {
            switch self {
            case .explosion, .playerDeath, .rocket: return 1.0
            case .queenDeath: return 0.95
            case .plasma, .droneDeath, .exit: return 0.9
            case .flamethrower: return 0.55
            default: return 0.8
            }
        }
    }

    // ── engine graph ─────────────────────────────────────────────────────────
    private let engine = AVAudioEngine()
    private let canonical = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    private let musicMix = AVAudioMixerNode()
    private let sfxMix   = AVAudioMixerNode()
    private let ambMix   = AVAudioMixerNode()

    private var sfxPool: [AVAudioPlayerNode] = []      // round-robin one-shot voices
    private var sfxNext = 0
    private var loopNodes: [Sound: AVAudioPlayerNode] = [:]   // one node per looping stem
    private var bank: [Sound: [AVAudioPCMBuffer]] = [:]       // loaded samples (empty ⇒ fall back)

    // ── three gain buses (sliders write these) ────────────────────────────────
    var musicGain: Float   { didSet { applyGains() } }
    var sfxGain: Float     { didSet { applyGains() } }
    var ambientGain: Float { didSet { applyGains() } }
    var muted = false      { didSet { applyGains() } }

    // ── reactive bed: live threat signal from the game ─────────────────────────
    private var tThreat: Float = 0    // 0…1 nearest-drone proximity (pack-weighted)
    private var tQueen: Float = 0     // 0…1 Queen awake & near (dread)
    private var tHealth: Float = 1    // 0…1 player health fraction
    private var tCombat: Float = 0    // 0…1 recent weapon-fire / damage heat
    private var bedLevel: Float = 0   // smoothed master intensity (fast up, slow down)
    private var levelDepth = 1
    private var usingSampleBed = false
    // synth-fallback bed clocks (only used when no bed_* stems are bundled)
    private var padT: Float = 0, pulseT: Float = 0, clankT: Float = 0, dreadT: Float = 0, heartT: Float = 0

    enum MusicMode { case none, title, level }
    private var mode: MusicMode = .none

    init() {
        musicGain = GameSettings.shared.musicVolume
        sfxGain = GameSettings.shared.sfxVolume
        ambientGain = GameSettings.shared.ambientVolume

        // synth fallback source (mono) — the placeholder voice for any missing sample.
        delayLen = Int(0.19 * 44100)
        delay = [Float](repeating: 0, count: delayLen)
        let monoFmt = AVAudioFormat(standardFormatWithSampleRate: Double(sr), channels: 1)!
        synthSrc = AVAudioSourceNode { [weak self] _, _, frameCount, abl in
            guard let self = self else { return noErr }
            let out = UnsafeMutableAudioBufferListPointer(abl)[0].mData!.assumingMemoryBound(to: Float.self)
            self.render(out, Int(frameCount)); return noErr
        }

        // wire the graph: buses → main mixer; voices → their bus.
        let main = engine.mainMixerNode
        for n in [musicMix, sfxMix, ambMix] { engine.attach(n); engine.connect(n, to: main, format: canonical) }
        engine.attach(synthSrc); engine.connect(synthSrc, to: main, format: monoFmt)

        sfxPool = (0..<12).map { _ in AVAudioPlayerNode() }
        for n in sfxPool { engine.attach(n); engine.connect(n, to: sfxMix, format: canonical) }
        for s in Sound.allCases where s.loop {
            let n = AVAudioPlayerNode(); loopNodes[s] = n
            engine.attach(n); engine.connect(n, to: s.bus == 0 ? musicMix : ambMix, format: canonical)
        }

        loadBank()
        // CITADEL_MUTE (headless / CI / office): never start the engine, so no
        // output device is opened and nothing can make a sound — guaranteed silent,
        // not merely volume-0. Playback helpers all guard on engine.isRunning.
        if ProcessInfo.processInfo.environment["CITADEL_MUTE"] == nil {
            engine.prepare()
            try? engine.start()
        }
        applyGains()
        if engine.isRunning { for n in sfxPool { n.play() } }   // idle, ready to schedule
    }

    private func applyGains() {
        musicMix.outputVolume = muted ? 0 : musicGain
        sfxMix.outputVolume   = muted ? 0 : sfxGain
        ambMix.outputVolume   = muted ? 0 : ambientGain
    }

    // ── sample loading ─────────────────────────────────────────────────────────
    private static let exts = ["wav", "caf", "aiff", "aif", "m4a", "mp3", "ogg"]

    private func loadBank() {
        for s in Sound.allCases {
            var bufs: [AVAudioPCMBuffer] = []
            for cand in [s.base] + (1...16).map({ "\(s.base)\($0)" }) {   // base + up to 16 random variants
                if let b = findAndLoad(cand) { bufs.append(b) }
            }
            if !bufs.isEmpty { bank[s] = bufs }
        }
    }

    private func findAndLoad(_ name: String) -> AVAudioPCMBuffer? {
        for ext in AudioEngine.exts {
            if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Audio"),
               let buf = loadBuffer(url) { return buf }
        }
        return nil
    }

    /// Read a file and resample/convert it to the canonical bus format so every
    /// player node has a single connection format (mismatches crash AVAudioEngine).
    private func loadBuffer(_ url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let srcFmt = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: frames) else { return nil }
        guard (try? file.read(into: srcBuf)) != nil else { return nil }
        if srcFmt.isEqual(canonical) { return srcBuf }
        guard let conv = AVAudioConverter(from: srcFmt, to: canonical) else { return srcBuf }
        let outCap = AVAudioFrameCount(Double(frames) * canonical.sampleRate / srcFmt.sampleRate + 2048)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: canonical, frameCapacity: outCap) else { return srcBuf }
        var consumed = false
        var convErr: NSError?
        conv.convert(to: outBuf, error: &convErr) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true; status.pointee = .haveData; return srcBuf
        }
        return convErr == nil ? outBuf : srcBuf
    }

    /// True if at least the base drone layer is sampled (gates the reactive bed).
    private var hasSampleBeds: Bool { bank[.bedDrone] != nil }

    // ── playback helpers ───────────────────────────────────────────────────────
    private func playOneShot(_ bufs: [AVAudioPCMBuffer], gain: Float) {
        guard engine.isRunning, let buf = bufs.randomElement() else { return }
        let node = sfxPool[sfxNext]; sfxNext = (sfxNext + 1) % sfxPool.count
        node.volume = gain
        node.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
        if !node.isPlaying { node.play() }
    }

    @discardableResult
    private func startLoop(_ s: Sound, volume: Float) -> Bool {
        guard engine.isRunning, let node = loopNodes[s], let buf = bank[s]?.first else { return false }
        node.stop()
        node.volume = volume
        node.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
        node.play()
        return true
    }

    private func stopAllLoops() { for (_, n) in loopNodes { n.stop() } }
    private func setLoopVol(_ s: Sound, _ v: Float) { loopNodes[s]?.volume = max(0, v) }

    /// Play the sample for `s`, or run `fallback` (the synth) when it isn't bundled.
    private func play(_ s: Sound, _ fallback: () -> Void) {
        if engine.isRunning, let bufs = bank[s] { playOneShot(bufs, gain: s.gain) }
        else { fallback() }
    }

    // ── public SFX API (unchanged call sites; sample → else synth) ──────────────
    func weaponFire(_ w: WeaponKind) {
        switch w {
        case .plasma:       play(.plasma)       { self.synthWeaponFire(.plasma) }
        case .flamethrower: play(.flamethrower) { self.synthWeaponFire(.flamethrower) }
        case .rocket:       play(.rocket)       { self.synthWeaponFire(.rocket) }
        }
    }
    func enemyShot(_ k: MonsterKind) { synthEnemyShot(k) }   // vestigial — no caste fires
    func monsterPain(_ k: MonsterKind)  { play(.hiss) { self.synthMonsterPain(k) } }       // aliens hiss when hit
    func monsterDeath(_ k: MonsterKind) { play(k == .queen ? .queenDeath : .droneDeath) { self.synthMonsterDeath(k) } }
    func monsterSight(_ k: MonsterKind) { play(.hiss) { self.synthMonsterSight(k) } }       // aliens hiss when they notice you
    func explosion()   { play(.explosion)   { self.synthExplosion() } }
    func doorOpen()    { play(.doorOpen)    { self.synthDoorOpen() } }
    func locked()      { play(.locked)      { self.synthLocked() } }
    func pickup()      { play(.pickup)      { self.synthPickup() } }
    func secret()      { play(.secret)      { self.synthSecret() } }
    func exit()        { play(.exit)        { self.synthExit() } }
    func playerPain()  { play(.playerPain)  { self.synthPlayerPain() } }
    func playerDeath() { play(.playerDeath) { self.synthPlayerDeath() } }

    // ── reactive bed control ────────────────────────────────────────────────────

    /// Fed from the game each frame. threat/queen/health/combat are all 0…1.
    func setTension(threat: Float, queen: Float, health: Float, combat: Float) {
        tThreat = threat; tQueen = queen; tHealth = health; tCombat = combat
    }

    func startMusic(_ m: MusicMode, depth: Int = 1) {
        mode = m; levelDepth = depth
        stopAllLoops()
        seqTime = 0; seqStep = 0
        padT = 0; pulseT = 0; clankT = 0; dreadT = 0; heartT = 0
        usingSampleBed = false
        switch m {
        case .none: break
        case .title:
            _ = startLoop(.musicTitle, volume: 1)   // synth title sequencer runs if this is absent
        case .level:
            if hasSampleBeds {
                usingSampleBed = true
                bedLevel = 0
                for s in [Sound.bedDrone, .bedPulse, .bedTension, .bedSwarm] { _ = startLoop(s, volume: 0) }
            }
        }
    }
    func stopMusic() { mode = .none; stopAllLoops() }

    /// Called every frame. Crossfades the reactive bed (sample or synth) and ticks
    /// the synth title sequencer when no title stem is bundled.
    func updateMusic(_ dt: Float) {
        switch mode {
        case .none: return
        case .title:
            if bank[.musicTitle] == nil { synthTitleTick(dt) }
        case .level:
            updateBed(dt)
        }
    }

    private func updateBed(_ dt: Float) {
        // master intensity: the swarm drives it; the Queen and combat lift it.
        let target = max(tThreat, 0.85 * tQueen, 0.6 * tCombat)
        // danger swells fast (~0.35 s) and lingers (~2.6 s) — tension shouldn't snap off.
        let tau: Float = target > bedLevel ? 0.35 : 2.6
        bedLevel += (target - bedLevel) * (1 - expf(-dt / tau))
        let lowHealth = max(0, 1 - tHealth / 0.30)        // 0 above 30% health → 1 at death's door

        if usingSampleBed {
            setLoopVol(.bedDrone,   0.55 + 0.25 * bedLevel)              // ever-present room tone
            setLoopVol(.bedPulse,   smoothstep(0.05, 0.6, bedLevel))     // the throb that grows
            setLoopVol(.bedTension, smoothstep(0.40, 1.0, bedLevel))     // dissonance at high threat
            setLoopVol(.bedSwarm,   max(smoothstep(0.55, 1.0, bedLevel), tQueen))   // near-swarm / Queen layer
        } else {
            synthBed(dt, level: bedLevel, lowHealth: lowHealth)
        }
    }

    @inline(__always) private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t)
    }

    // ════════════════════════════════════════════════════════════════════════════
    //  SYNTH FALLBACK — the original from-scratch code synthesiser. Speaks only
    //  when a sample is missing. Slated for removal once the asset set is final.
    // ════════════════════════════════════════════════════════════════════════════

    private var synthSrc: AVAudioSourceNode!
    private let sr: Float = 44100

    private struct Voice {
        var wave: Int
        var phase: Float = 0
        var freq: Float
        var slide: Float
        var amp: Float
        var attack: Int
        var total: Int
        var left: Int
        var lp: Float
        var lpState: Float = 0
        var bus: Int
        var send: Float
        var rng: UInt64
        var seq: UInt64
    }
    private var voices: [Voice] = []
    private var seqCounter: UInt64 = 0
    private let maxVoices = 28
    private let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1); p.initialize(to: os_unfair_lock()); return p
    }()

    private var delay: [Float]
    private let delayLen: Int
    private var delayIdx = 0
    private var damp: Float = 0
    private let feedback: Float = 0.36
    private let wetMix: Float = 0.22

    private var seqTime: Float = 0
    private var seqStep = 0

    private func render(_ out: UnsafeMutablePointer<Float>, _ frames: Int) {
        let mGain = muted ? 0 : musicGain
        let sGain = muted ? 0 : sfxGain
        let aGain = muted ? 0 : ambientGain
        os_unfair_lock_lock(lock)
        for i in 0..<frames {
            var dry: Float = 0, wetIn: Float = 0
            var vi = 0
            while vi < voices.count {
                var v = voices[vi]
                if v.left <= 0 { voices.remove(at: vi); continue }
                let elapsed = v.total - v.left
                let env: Float = elapsed < v.attack
                    ? Float(elapsed) / Float(max(1, v.attack))
                    : Float(v.left) / Float(max(1, v.total - v.attack))
                var s: Float
                switch v.wave {
                case AudioEngine.square: s = v.phase < 0.5 ? 1 : -1
                case AudioEngine.triangle: s = 4 * abs(v.phase - 0.5) - 1
                case AudioEngine.saw: s = 2 * v.phase - 1
                case AudioEngine.noise:
                    v.rng = v.rng &* 1_664_525 &+ 1_013_904_223
                    s = Float(v.rng >> 9) / Float(1 << 23) - 1
                default: s = sinf(2 * .pi * v.phase)
                }
                if v.lp < 1 { v.lpState += (s - v.lpState) * v.lp; s = v.lpState }
                s *= env * v.amp
                let g = v.bus == 0 ? mGain : (v.bus == 2 ? aGain : sGain)
                let o = s * g
                dry += o
                if v.send > 0 { wetIn += o * v.send }
                v.phase += v.freq / sr
                if v.phase >= 1 { v.phase -= 1 }
                v.freq *= v.slide
                v.left -= 1
                voices[vi] = v
                vi += 1
            }
            let echo = delay[delayIdx]
            damp += (echo - damp) * 0.42
            var fb = wetIn + damp * feedback
            if fb > 3 { fb = 3 } else if fb < -3 { fb = -3 }
            delay[delayIdx] = fb
            delayIdx += 1; if delayIdx >= delayLen { delayIdx = 0 }
            var o = dry + echo * wetMix
            o = tanhf(o * 0.8)
            out[i] = o
        }
        os_unfair_lock_unlock(lock)
    }

    private func add(_ wave: Int, _ f0: Float, _ f1: Float, _ dur: Float, _ amp: Float,
                     attack: Float = 0.004, lp: Float = 1, bus: Int = 1, send: Float = 0) {
        let total = max(1, Int(dur * sr))
        let slide = total > 1 ? powf(max(1, f1) / max(1, f0), 1 / Float(total)) : 1
        seqCounter &+= 1
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D &+ UInt64(total) &+ UInt64(f0) &+ seqCounter &* 2_654_435_761
        if seed == 0 { seed = 1 }
        let v = Voice(wave: wave, freq: f0, slide: slide, amp: amp, attack: max(1, Int(attack * sr)),
                      total: total, left: total, lp: lp, bus: bus, send: send, rng: seed, seq: seqCounter)
        os_unfair_lock_lock(lock)
        if voices.count >= maxVoices {
            var oldest = 0; for j in 1..<voices.count where voices[j].seq < voices[oldest].seq { oldest = j }
            voices.remove(at: oldest)
        }
        voices.append(v)
        os_unfair_lock_unlock(lock)
    }

    /// Legacy shim kept for compatibility.
    func trigger(wave: Int, f0: Float, f1: Float? = nil, dur: Float, amp: Float,
                 attack: Float = 0.004, drive: Float = 1, bus: Int = 1) {
        add(wave, f0, f1 ?? f0, dur, amp, attack: attack, bus: bus)
    }

    private func note(_ m: Int) -> Float { 440 * powf(2, Float(m - 69) / 12) }

    // synth title sequencer (used only if no music_title stem is bundled)
    private static let bass = [40, 40, 47, 41, 40, 40, 45, 43, 40, 40, 48, 41, 40, 43, 45, 47]
    private static let lead = [-1, -1, 64, -1, 67, -1, 65, 64, -1, 64, -1, 67, -1, 71, 67, -1]

    private func synthTitleTick(_ dt: Float) {
        let stepDur: Float = 0.14
        seqTime += dt
        var guardN = 0
        while seqTime >= stepDur && guardN < 8 { seqTime -= stepDur; synthTitleStep(seqStep); seqStep += 1; guardN += 1 }
    }
    private func synthTitleStep(_ step: Int) {
        let b = AudioEngine.bass[step % AudioEngine.bass.count]
        add(AudioEngine.triangle, note(b - 12), note(b - 12), 0.13, 0.16, attack: 0.003, lp: 0.5, bus: 0, send: 0.12)
        if step % 4 == 0 { add(AudioEngine.sine, 110, 46, 0.16, 0.32, attack: 0.001, bus: 0) }
        if step % 4 == 2 { add(AudioEngine.noise, 1, 1, 0.10, 0.10, attack: 0.001, lp: 0.5, bus: 0) }
        if step % 2 == 1 { add(AudioEngine.noise, 1, 1, 0.03, 0.04, attack: 0.001, bus: 0) }
        let l = AudioEngine.lead[step % AudioEngine.lead.count]
        if l >= 0 { add(AudioEngine.square, note(l), note(l), 0.22, 0.08, attack: 0.006, lp: 0.35, bus: 0, send: 0.3) }
    }

    // synth REACTIVE bed (used only if no bed_* stems are bundled). Driven by the
    // same `level` (0…1) as the sample bed, so the swarm-thickening is audible now.
    private func synthBed(_ dt: Float, level: Float, lowHealth: Float) {
        padT -= dt
        if padT <= 0 {
            padT = 3.2
            let root = 26 + (levelDepth % 3)
            add(AudioEngine.triangle, note(root - 12), note(root - 12), 3.6, 0.075 + 0.03 * level, attack: 0.8, lp: 0.22, bus: 2, send: 0.5)
            add(AudioEngine.sine, note(root - 24), note(root - 24), 3.6, 0.05, attack: 1.0, lp: 0.20, bus: 2, send: 0.4)
        }
        pulseT -= dt
        if pulseT <= 0 {
            pulseT = 2.0 - 1.5 * level                       // ~2 s calm → ~0.5 s at peak
            add(AudioEngine.sine, note(33), note(28), 0.5, 0.05 + 0.20 * level, attack: 0.005, lp: 0.5, bus: 2, send: 0.2)
            if level > 0.5 { add(AudioEngine.noise, 1, 1, 0.04, 0.04 * level, attack: 0.001, lp: 0.5, bus: 2) }
        }
        clankT -= dt
        if clankT <= 0 {
            clankT = (5.0 - 3.6 * level) * Float.random(in: 0.7...1.3)   // sparse → frequent machine hits
            add(AudioEngine.noise, 1, 1, 0.12, 0.045 + 0.06 * level, attack: 0.002, lp: 0.28, bus: 2, send: 0.5)
            add(AudioEngine.square, note(40), note(38), 0.18, 0.035 + 0.05 * level, attack: 0.003, lp: 0.5, bus: 2, send: 0.4)
        }
        if level > 0.45 {
            dreadT -= dt
            if dreadT <= 0 {
                dreadT = 2.4
                let f = note(74)
                add(AudioEngine.triangle, f, f, 1.8, 0.02 + 0.02 * level, attack: 0.6, lp: 0.7, bus: 2, send: 0.7)
                add(AudioEngine.triangle, f * 1.06, f * 1.06, 1.8, 0.018, attack: 0.6, lp: 0.7, bus: 2, send: 0.7)  // a beating semitone
            }
        }
        if lowHealth > 0 {
            heartT -= dt
            if heartT <= 0 {
                heartT = 1.1 - 0.5 * lowHealth               // pulse quickens toward death
                add(AudioEngine.sine, 60, 42, 0.16, 0.10 * lowHealth, attack: 0.004, lp: 0.6, bus: 2)
            }
        }
    }

    // synth SFX (clean, punchy) — fallback voices for the corresponding samples.
    private func synthWeaponFire(_ w: WeaponKind) {
        switch w {
        case .rocket:
            add(AudioEngine.noise, 900, 300, 0.20, 0.14, lp: 0.5)
            add(AudioEngine.saw, 140, 80, 0.22, 0.16, lp: 0.6)
        case .plasma:
            add(AudioEngine.square, 820, 520, 0.07, 0.13, lp: 0.9); add(AudioEngine.sine, 1200, 900, 0.06, 0.06)
        case .flamethrower:
            add(AudioEngine.noise, 1, 1, 0.16, 0.09, lp: 0.32)
            add(AudioEngine.saw, 95, 78, 0.13, 0.05, lp: 0.45)
        }
    }
    private func synthEnemyShot(_ k: MonsterKind) {
        let f: Float = k == .queen ? 360 : 480
        add(AudioEngine.square, f, f * 0.6, 0.12, 0.11, lp: 0.7, send: 0.1)
    }
    private func synthMonsterPain(_ k: MonsterKind) {
        let f: Float = k == .queen ? 140 : 300
        add(AudioEngine.saw, f, f * 0.7, 0.10, 0.11, lp: 0.5); add(AudioEngine.noise, 1, 1, 0.05, 0.06, lp: 0.4)
    }
    private func synthMonsterDeath(_ k: MonsterKind) {
        let f: Float = k == .queen ? 180 : 340
        add(AudioEngine.saw, f, 60, 0.45, 0.16, lp: 0.5, send: 0.2); add(AudioEngine.noise, 1, 1, 0.22, 0.12, lp: 0.3)
    }
    private func synthMonsterSight(_ k: MonsterKind) {
        let f: Float = k == .queen ? 84 : 240
        add(AudioEngine.saw, f, f * 0.8, 0.5, 0.12, attack: 0.04, lp: 0.4, send: 0.25)
    }
    private func synthExplosion() {
        add(AudioEngine.noise, 1, 1, 0.4, 0.22, lp: 0.3, send: 0.2); add(AudioEngine.sine, 110, 38, 0.5, 0.26)
        add(AudioEngine.noise, 1, 1, 0.05, 0.14)
    }
    private func synthDoorOpen() { add(AudioEngine.saw, 64, 96, 0.5, 0.10, attack: 0.05, lp: 0.3, send: 0.3) }
    private func synthLocked() { add(AudioEngine.square, 150, 150, 0.09, 0.13, lp: 0.6); add(AudioEngine.square, 110, 110, 0.12, 0.13, lp: 0.6) }
    private func synthPickup() { add(AudioEngine.sine, 600, 1000, 0.10, 0.13, attack: 0.002, send: 0.1) }
    private func synthSecret() { for n in [60, 64, 67, 72] { add(AudioEngine.triangle, note(n), note(n), 0.12, 0.11, attack: 0.003, lp: 0.7, send: 0.25) } }
    private func synthExit() { for n in [55, 59, 62, 67] { add(AudioEngine.square, note(n), note(n), 0.18, 0.12, attack: 0.004, lp: 0.6, send: 0.3) } }
    private func synthPlayerPain() { add(AudioEngine.saw, 300, 170, 0.13, 0.16, lp: 0.5); add(AudioEngine.noise, 1, 1, 0.05, 0.08, lp: 0.4) }
    private func synthPlayerDeath() { add(AudioEngine.saw, 320, 55, 0.9, 0.22, lp: 0.4, send: 0.3); add(AudioEngine.noise, 1, 1, 0.3, 0.12, lp: 0.3) }
}
