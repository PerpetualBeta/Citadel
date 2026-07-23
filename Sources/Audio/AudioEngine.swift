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
    // <base>.<ext> and numbered variants <base>1..<base>16.<ext> (picked at
    // random) for ext in wav/caf/aiff/aif/m4a/mp3/ogg. `bed_*` / `music_title` loop.
    enum Sound: CaseIterable {
        case plasma, flamethrower, rocket
        case hiss                  // shared alien hiss pool: drone + Queen pain (random)
        case queenSnarl            // QUEEN ONLY: her signature snarl pool (sight/LOS), random variant
        case droneDeath, queenDeath
        case queenFall             // QUEEN ONLY: the toppled brood-mother slams the deck
        case explosion, doorOpen, locked, pickup, secret, exit, playerPain, playerDeath, wade
        case drip                  // ceiling water onto the deep floors' pools (panned per-site, see drip(volume:pan:))
        case fault                 // distant electric-shock ambience — occasional crack of a shorting circuit (see distantFault)
        case musicTitle, bedDrone, bedPulse, bedTension, bedSwarm
        case elevatorMove, elevatorDoor, elevatorShut
        case faultHum, faultBuzz, faultCrackle   // electrical-fault: proximity hum LOOP, pre-spark buzz, spark crackle

        var base: String {
            switch self {
            case .plasma: return "plasma"
            case .flamethrower: return "flamethrower"
            case .rocket: return "rocket"
            case .hiss: return "hiss"
            case .queenSnarl: return "queen_snarl"
            case .droneDeath: return "drone_death"
            case .queenDeath: return "queen_death"
            case .queenFall: return "queen_fall"
            case .explosion: return "explosion"
            case .doorOpen: return "door_open"
            case .locked: return "locked"
            case .pickup: return "pickup"
            case .secret: return "secret"
            case .exit: return "exit"
            case .playerPain: return "player_pain"
            case .playerDeath: return "player_death"
            case .wade: return "wade"
            case .drip: return "drip"
            case .fault: return "fault"
            case .musicTitle: return "music_title"
            case .bedDrone: return "bed_drone"
            case .bedPulse: return "bed_pulse"
            case .bedTension: return "bed_tension"
            case .bedSwarm: return "bed_swarm"
            case .elevatorMove: return "elevator_move"
            case .elevatorDoor: return "elevator_door"
            case .elevatorShut: return "elevator_shut"
            case .faultHum: return "fault_hum"
            case .faultBuzz: return "fault_buzz"
            case .faultCrackle: return "fault_crackle"
            }
        }
        // bus: 0 music, 1 sfx, 2 ambient.
        var bus: Int {
            switch self {
            case .musicTitle: return 0
            case .bedDrone, .bedPulse, .bedTension, .bedSwarm, .drip, .fault, .faultHum, .faultBuzz, .faultCrackle: return 2
            default: return 1
            }
        }
        // the looping stems (title theme + reactive bed layers); drips are
        // ambient-bus ONE-SHOTS, so loop is spelled out rather than bus-derived
        var loop: Bool {
            switch self {
            case .musicTitle, .bedDrone, .bedPulse, .bedTension, .bedSwarm, .faultHum: return true
            default: return false
            }
        }
        // per-sound trim so one sample doesn't dwarf the rest (1 = unity).
        var gain: Float {
            switch self {
            case .explosion, .playerDeath, .rocket, .queenFall: return 1.0
            case .queenDeath, .queenSnarl: return 0.95
            case .plasma, .droneDeath, .exit: return 0.9
            case .flamethrower: return 0.55
            case .elevatorMove: return 0.45
            case .elevatorDoor, .elevatorShut: return 0.85
            case .wade: return 0.5
            case .drip: return 0.55
            case .fault: return 0.7
            case .faultHum: return 0.34       // quietened relative to the ambient bed
            case .faultBuzz: return 0.24      // pre-spark buzz — kept low; only fires when close
            case .faultCrackle: return 0.32   // the spark itself
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
    private let flameNode = AVAudioPlayerNode()               // the flamethrower's continuous roar (SFX bus)
    private var flameOn = false
    private let elevatorNode = AVAudioPlayerNode()            // the winch hum — loops during the ride, stops on arrival
    private var elevatorOn = false
    private let burnNode = AVAudioPlayerNode()                // corpse-fire crackle bed — volume rides the nearest pyre
    private var burnOn = false
    private let queenSnarlNode = AVAudioPlayerNode()          // dedicated Queen-snarl voice → pitch shifter
    private let queenPitch = AVAudioUnitTimePitch()           // pitches her snarls DOWN + varies them, per utterance
    private let queenDeathNode = AVAudioPlayerNode()          // dedicated Queen DEATH-WAIL voice — its own node so nothing in the pool can steal the cry
    private let stingNode = AVAudioPlayerNode()               // dedicated Queen deck-slam voice
    private let faultNode = AVAudioPlayerNode()               // distant electric-shock ambience → varispeed → lowpass → reverb → ambient bus
    private let faultVari = AVAudioUnitVarispeed()            // per-hit pitch/pace tweak so the crack never repeats
    private let faultEQ = AVAudioUnitEQ(numberOfBands: 1)     // lowpass — "heard through steel"
    private let faultReverb = AVAudioUnitReverb()             // echo down the corridors → distance
    private let staticNode = AVAudioPlayerNode()              // the teleport static: a seamless noise loop, volume-driven per frame
    private var staticBuf: AVAudioPCMBuffer?
    private var staticOn = false
    // Queen-snarl pitch manipulation — she's a VAST broodmother, so each snarl is
    // pitched down and randomly varied in pitch AND tempo, turning a handful of CC0
    // samples into an endless, never-identical set. Tune to taste:
    //   100 cents = 1 semitone · rate < 1 = slower / more ponderous.
    private let queenSnarlPitchBase: Float   = -600          // base drop: -6 semitones (sheer size)
    private let queenSnarlPitchJitter: Float = 450           // ± per-snarl pitch variation (cents) — wide, so no two snarls match
    private let queenSnarlRateBase: Float    = 0.92          // base tempo: a touch slower than life
    private let queenSnarlRateJitter: Float  = 0.14          // ± per-snarl tempo variation
    // distant-drone voice — a muffled, echoing hiss for the far / unseen swarm (creep
    // factor). Its own chain so it can be low-passed + reverbed without touching the
    // dry SFX: node → low-pass EQ → reverb → SFX bus.
    private let distantNode = AVAudioPlayerNode()
    private let distantEQ = AVAudioUnitEQ(numberOfBands: 1)
    private let distantReverb = AVAudioUnitReverb()
    // water-drip chain — a small voice pool so each plink can be PANNED to its
    // site and overlapping drips don't cut each other off, each through its own
    // varispeed (random per-plink pitch: no two drips land alike), all sharing
    // one wet-chamber reverb: node → varispeed → dripMix (pan) → reverb → ambient.
    private let dripNodes = (0..<3).map { _ in AVAudioPlayerNode() }
    private let dripVaris = (0..<3).map { _ in AVAudioUnitVarispeed() }
    private let dripMix = AVAudioMixerNode()
    private let dripReverb = AVAudioUnitReverb()
    private var dripNext = 0
    // wade chain — one voice per foot through a varispeed, so every splash gets
    // its own random pitch + level: a gait through water, not a looped sample.
    private let wadeNodes = (0..<2).map { _ in AVAudioPlayerNode() }
    private let wadeVaris = (0..<2).map { _ in AVAudioUnitVarispeed() }
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
    private var bedStartup: Float = 0   // 0→1 ease-in at level start so the beds don't snap on from silence (arrival thump)
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
        // Diagnostic: silence ONLY the synth-on-main path, independent of the three
        // buses, to corner the floor-1 arrival thump — the buses ride mutedBuses,
        // but the synth bypasses them, so muteBuses can't isolate it. Read once
        // (relaunch to apply) so the real-time callback never touches UserDefaults.
        //   defaults write cc.jorviksoftware.Citadel muteSynth -bool YES
        let muteSynthFlag = UserDefaults.standard.bool(forKey: "muteSynth")
        synthSrc = AVAudioSourceNode { [weak self] _, _, frameCount, abl in
            guard let self = self else { return noErr }
            let out = UnsafeMutableAudioBufferListPointer(abl)[0].mData!.assumingMemoryBound(to: Float.self)
            // The synth rides the MAIN mixer (not the three group buses), so
            // `muted` can't gate it there — it must silence itself, or muted
            // harness runs still speak through every sample-less sound.
            if self.muted || muteSynthFlag { out.update(repeating: 0, count: Int(frameCount)); return noErr }
            self.render(out, Int(frameCount)); return noErr
        }

        // wire the graph: buses → main mixer; voices → their bus.
        let main = engine.mainMixerNode
        for n in [musicMix, sfxMix, ambMix] { engine.attach(n); engine.connect(n, to: main, format: canonical) }
        engine.attach(synthSrc); engine.connect(synthSrc, to: main, format: monoFmt)

        sfxPool = (0..<12).map { _ in AVAudioPlayerNode() }
        for n in sfxPool { engine.attach(n); engine.connect(n, to: sfxMix, format: canonical) }
        engine.attach(flameNode); engine.connect(flameNode, to: sfxMix, format: canonical)
        engine.attach(elevatorNode); engine.connect(elevatorNode, to: sfxMix, format: canonical)
        engine.attach(burnNode); engine.connect(burnNode, to: sfxMix, format: canonical)
        // the Queen's snarl runs through a time-pitch unit so it can be dropped and
        // varied per utterance (she's a giant): node → pitch → SFX bus.
        engine.attach(queenSnarlNode); engine.attach(queenPitch)
        engine.connect(queenSnarlNode, to: queenPitch, format: canonical)
        engine.connect(queenPitch, to: sfxMix, format: canonical)
        engine.attach(queenDeathNode); engine.connect(queenDeathNode, to: sfxMix, format: canonical)
        engine.attach(stingNode); engine.connect(stingNode, to: sfxMix, format: canonical)
        // the static bed: 2 s of generated white noise (deterministic), looped
        engine.attach(staticNode); engine.connect(staticNode, to: sfxMix, format: canonical)
        if let buf = AVAudioPCMBuffer(pcmFormat: canonical, frameCapacity: AVAudioFrameCount(2 * 44100)) {
            buf.frameLength = AVAudioFrameCount(2 * 44100)
            var noiseSeed: UInt64 = 0x9E37_79B9_7F4A_7C15
            for i in 0..<Int(buf.frameLength) {
                noiseSeed ^= noiseSeed << 13; noiseSeed ^= noiseSeed >> 7; noiseSeed ^= noiseSeed << 17
                let v = (Float(noiseSeed & 0xFFFFFF) / Float(0xFFFFFF) * 2 - 1) * 0.5
                buf.floatChannelData![0][i] = v
                buf.floatChannelData![1][i] = v
            }
            staticBuf = buf
        }
        // distant-drone chain: muffled (low-pass) + echoing (reverb) — the unseen swarm.
        distantEQ.bands[0].filterType = .lowPass
        distantEQ.bands[0].frequency = 760                  // roll off the highs → "heard through steel"
        distantEQ.bands[0].bypass = false
        distantReverb.loadFactoryPreset(.largeHall)
        distantReverb.wetDryMix = 72                        // mostly wet → it echoes off down the corridors
        engine.attach(distantNode); engine.attach(distantEQ); engine.attach(distantReverb)
        engine.connect(distantNode, to: distantEQ, format: canonical)
        engine.connect(distantEQ, to: distantReverb, format: canonical)
        engine.connect(distantReverb, to: sfxMix, format: canonical)
        // distant electric-shock chain: the occasional crack of a shorting circuit
        // somewhere in the damaged citadel — the same "through steel + echo" as the
        // drone, pitch-tweaked per hit, on the ambient bus (see distantFault).
        faultEQ.bands[0].filterType = .lowPass
        faultEQ.bands[0].frequency = 900
        faultEQ.bands[0].bypass = false
        faultReverb.loadFactoryPreset(.largeHall)
        faultReverb.wetDryMix = 82                          // mostly wet → far off
        engine.attach(faultNode); engine.attach(faultVari); engine.attach(faultEQ); engine.attach(faultReverb)
        engine.connect(faultNode, to: faultVari, format: canonical)
        engine.connect(faultVari, to: faultEQ, format: canonical)
        engine.connect(faultEQ, to: faultReverb, format: canonical)
        engine.connect(faultReverb, to: ambMix, format: canonical)
        // drip chain: the plinks echo off wet stone — a room-scale wash, drier
        // and tighter than the distant-vox hall so nearby drips still snap
        dripReverb.loadFactoryPreset(.largeRoom)
        dripReverb.wetDryMix = 46
        engine.attach(dripMix); engine.attach(dripReverb)
        engine.connect(dripMix, to: dripReverb, format: canonical)
        engine.connect(dripReverb, to: ambMix, format: canonical)
        for (n, v) in zip(dripNodes, dripVaris) {
            engine.attach(n); engine.attach(v)
            engine.connect(n, to: v, format: canonical)
            engine.connect(v, to: dripMix, format: canonical)
        }
        // wade chain: a voice per foot, pitch-varied per splash
        for (n, v) in zip(wadeNodes, wadeVaris) {
            engine.attach(n); engine.attach(v)
            engine.connect(n, to: v, format: canonical)
            engine.connect(v, to: sfxMix, format: canonical)
        }
        for s in Sound.allCases where s.loop {
            let n = AVAudioPlayerNode(); loopNodes[s] = n
            engine.attach(n); engine.connect(n, to: s.bus == 0 ? musicMix : ambMix, format: canonical)
        }

        loadBank()
        // CITADEL_MUTE (headless / CI / office): never start the engine, so no
        // output device is opened and nothing can make a sound — guaranteed silent,
        // not merely volume-0. Playback helpers all guard on engine.isRunning.
        // CITADEL_AUDIOPROBE: run the whole graph in OFFLINE manual-rendering
        // mode — silent, deterministic, and measurable (AudioProbe pumps it).
        if ProcessInfo.processInfo.environment["CITADEL_AUDIOPROBE"] != nil {
            try? engine.enableManualRenderingMode(.offline, format: canonical, maximumFrameCount: 4096)
            engine.prepare()
            try? engine.start()
        } else if ProcessInfo.processInfo.environment["CITADEL_MUTE"] == nil {
            engine.prepare()
            try? engine.start()
        }
        applyGains()
        if engine.isRunning { for n in sfxPool { n.play() }; queenSnarlNode.play(); queenDeathNode.play(); stingNode.play(); faultNode.play(); distantNode.play(); for n in dripNodes + wadeNodes { n.play() } }   // idle, ready to schedule
        // Warm-up: a player node that's playing but has never rendered a buffer leaves
        // the SFX output path cold, so the DAC pops on the very first real sound (heard
        // as crackle on level 1's opening sounds; by level 2 it's warm). Push half a
        // second of pure silence through the SFX bus now so the path is primed before
        // anything audible plays.
        if engine.isRunning, let warm = AVAudioPCMBuffer(pcmFormat: canonical, frameCapacity: 22050) {
            warm.frameLength = 22050                          // 0.5 s
            if let data = warm.floatChannelData {
                for c in 0..<Int(canonical.channelCount) { memset(data[c], 0, Int(warm.frameLength) * MemoryLayout<Float>.size) }   // zeros = silence
            }
            sfxPool[0].scheduleBuffer(warm, at: nil, completionHandler: nil)
            // Same cold-path pop on the AMBIENT bus (ambMix): the reactive beds are
            // its first signal, on level 1, so their nodes have never rendered and
            // the DAC pops on arrival (by level 2 they're warm — hence "only the
            // first level"). Prime each bed node with the same silence now.
            for s in [Sound.bedDrone, .bedPulse, .bedTension, .bedSwarm] {
                if let n = loopNodes[s] { n.play(); n.scheduleBuffer(warm, at: nil, completionHandler: nil) }
            }
        }
    }

    /// AudioProbe support: pump the offline engine `seconds` forward and return
    /// the RMS of the rendered output (0 when not in manual-rendering mode).
    func renderOfflineRMS(seconds: Double) -> Float {
        guard engine.manualRenderingMode == .offline else { return 0 }
        let frames = AVAudioFrameCount(44100 * seconds)
        guard let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096) else { return 0 }
        var acc: Double = 0, n = 0
        var left = frames
        while left > 0 {
            let chunk = min(4096, left)
            guard (try? engine.renderOffline(chunk, to: buf)) == .success else { break }
            let ch = Int(buf.format.channelCount)
            for c in 0..<ch {
                let d = buf.floatChannelData![c]
                for i in 0..<Int(buf.frameLength) { acc += Double(d[i] * d[i]); n += 1 }
            }
            left -= chunk
        }
        return n > 0 ? Float((acc / Double(n)).squareRoot()) : 0
    }

    private func applyGains() {
        let mb = mutedBuses, allB = mb.contains("all")
        musicMix.outputVolume = (muted || allB || mb.contains("music")) ? 0 : musicGain
        sfxMix.outputVolume   = (muted || allB || mb.contains("sfx"))   ? 0 : sfxGain
        ambMix.outputVolume   = (muted || allB || mb.contains("amb"))   ? 0 : ambientGain
        // Master mute (the "m" key) is decisive HERE, at the final mixer stage.
        // Zeroing the three group buses alone leaked audible transients — a player
        // node wired straight to a bus mixer isn't fully silenced by that bus's
        // outputVolume=0 (a two-stage-mixer quirk; measured ~-24 dB of leak on
        // plasma/elevator/static, heard as the residual "clicks and pops"). The
        // mainMixerNode's outputVolume catches everything downstream, so nothing
        // reaches the DAC. It ramps smoothly too, so the mute/unmute itself is
        // click-free. The per-bus zeroing above stays for selective `muteBuses`.
        engine.mainMixerNode.outputVolume = (muted || allB) ? 0 : 1
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

    /// Every logical sound that decoded at least one sample file. The smoke test
    /// asserts this covers ALL cases — a missing or undecodable asset would
    /// otherwise hide behind the synth fallback indefinitely.
    var sampledSounds: Set<Sound> { Set(bank.keys) }

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
        alog("startLoop \(s) vol=\(String(format: "%.2f", volume))")
        if isMuted(s) { return false }
        node.stop()
        node.volume = volume
        node.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
        node.play()
        return true
    }

    private func stopAllLoops() { alog("stopAllLoops"); for (_, n) in loopNodes { n.stop() }; flameNode.stop(); flameOn = false; elevatorNode.stop(); elevatorOn = false; burnNode.stop(); burnOn = false }
    private func setLoopVol(_ s: Sound, _ v: Float) { let nv = max(0, v); if let n = loopNodes[s] { if abs(nv - n.volume) > 0.12 { alog("volJump \(s) \(String(format: "%.2f", n.volume))->\(String(format: "%.2f", nv))") }; n.volume = nv } }

    // ── elimination harness: silence buses or named sounds to corner a mystery pop ──
    //   defaults write cc.jorviksoftware.Citadel muteBuses  "amb"                (amb | sfx | music | all)
    //   defaults write cc.jorviksoftware.Citadel muteSounds "elevatorShut bedDrone"   (Sound-case names, as in audio.log; or "all")
    //   relaunch to apply. muteBuses zeroes the whole bus gain, so it catches even an untriggered glitch.
    private var mutedBuses: Set<String> {
        Set((UserDefaults.standard.string(forKey: "muteBuses") ?? "")
            .lowercased().split(whereSeparator: { ", ".contains($0) }).map(String.init))
    }
    private var mutedSounds: Set<String> {
        Set((UserDefaults.standard.string(forKey: "muteSounds") ?? "")
            .split(whereSeparator: { ", ".contains($0) }).map(String.init))
    }
    private func isMuted(_ s: Sound) -> Bool {
        let m = mutedSounds
        return m.contains("all") || m.contains("\(s)") || m.contains(s.base)
    }

    /// Diagnostic timeline, off unless `defaults write cc.jorviksoftware.Citadel
    /// audioLog -bool YES` — appends to ~/Library/Logs/Citadel/audio.log with a
    /// systemUptime stamp. For chasing the floor-1 first-sound pops; makes no sound.
    private func alog(_ msg: String) {
        guard UserDefaults.standard.bool(forKey: "audioLog") else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Citadel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("audio.log")
        let line = Data(String(format: "%.3f  %@\n", ProcessInfo.processInfo.systemUptime, msg).utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: url) }
    }

    /// The flamethrower's continuous roar: a looped 5-second stem on the SFX bus that
    /// tracks the trigger, instead of randomly-retriggered one-shots (which desynced
    /// from the steady beam). Edge-detected, so it's cheap to call every frame.
    func flame(_ on: Bool) {
        guard on != flameOn else { return }
        flameOn = on
        guard engine.isRunning else { return }
        if on, let buf = bank[.flamethrower]?.first {
            flameNode.stop()
            flameNode.volume = Sound.flamethrower.gain
            flameNode.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
            flameNode.play()
        } else {
            flameNode.stop()
        }
    }

    /// Play the sample for `s`, or run `fallback` (the synth) when it isn't bundled.
    private func play(_ s: Sound, _ fallback: () -> Void) {
        alog("play \(s)")
        if isMuted(s) { return }
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

    /// A wade/splash as the player steps through standing water — louder the
    /// deeper. Plays a curated sample if one's bundled, else a synth splash
    /// (filtered noise) as a stopgap until a CC0 sample is hand-picked.
    func wade(_ depth: Float, foot: Int) {
        alog("wade foot=\(foot) depth=\(String(format: "%.2f", depth))")
        if isMuted(.wade) { return }
        let v = 0.5 + 0.5 * min(1, max(0, depth))
        // alternate L/R: foot 0 → wade.*, foot 1 → wade1.* — two slightly different
        // splashes so the gait reads as real footfalls — and jitter each step's
        // pitch and level so no two footfalls land identically.
        if engine.isRunning, let bufs = bank[.wade], !bufs.isEmpty {
            let f = foot % wadeNodes.count
            wadeVaris[f].rate = Float.random(in: 0.86...1.16)
            wadeNodes[f].volume = Sound.wade.gain * v * Float.random(in: 0.8...1.05)
            wadeNodes[f].scheduleBuffer(bufs[foot % bufs.count], at: nil, options: .interrupts, completionHandler: nil)
            if !wadeNodes[f].isPlaying { wadeNodes[f].play() }
        } else {
            synthWade(v, foot: foot)
        }
    }
    /// A single ceiling drip into a pool, `pan` −1 (hard left) … +1 (hard right),
    /// `volume` 0…1 from the caller's distance falloff — the deep floors' water
    /// ambience (World.emitWaterDrips). Sample if bundled (drip*.wav), else the
    /// synth plink.
    func drip(volume: Float, pan: Float) {
        alog("drip vol=\(String(format: "%.2f", volume))")
        if isMuted(.drip) { return }
        let v = Sound.drip.gain * max(0, min(1, volume))
        if engine.isRunning, let bufs = bank[.drip], let buf = bufs.randomElement() {
            let i = dripNext; dripNext = (dripNext + 1) % dripNodes.count
            dripVaris[i].rate = Float.random(in: 0.85...1.3)   // every plink lands at its own pitch
            dripNodes[i].volume = v
            dripNodes[i].pan = max(-1, min(1, pan))
            dripNodes[i].scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
            if !dripNodes[i].isPlaying { dripNodes[i].play() }
        } else {
            synthDrip(v)
        }
    }
    func enemyShot(_ k: MonsterKind) { synthEnemyShot(k) }   // vestigial — no caste fires
    func monsterPain(_ k: MonsterKind)  { play(.hiss) { self.synthMonsterPain(k) } }       // aliens hiss when hit
    /// A kill cry. The Queen's 3-second death WAIL rides its OWN dedicated node so
    /// nothing in the one-shot pool can steal it. (The old "intermittent silent
    /// death" was a stale, truncated `queen_death` variant lingering in the build
    /// bundle — a bad sample, not this code; the build now prunes stale Resources.)
    func monsterDeath(_ k: MonsterKind) {
        guard k == .queen, engine.isRunning, let buf = bank[.queenDeath]?.randomElement() else {
            play(k == .queen ? .queenDeath : .droneDeath) { self.synthMonsterDeath(k) }
            return
        }
        queenDeathNode.volume = Sound.queenDeath.gain
        queenDeathNode.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
        if !queenDeathNode.isPlaying { queenDeathNode.play() }
    }

    /// The toppled Queen SLAMS the deck on its own dedicated node; the layered
    /// synth thump remains as the missing-sample fallback.
    func queenFall() {
        if engine.isRunning, let buf = bank[.queenFall]?.randomElement() {
            stingNode.volume = Sound.queenFall.gain
            stingNode.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
            if !stingNode.isPlaying { stingNode.play() }
            return
        }
        trigger(wave: AudioEngine.sine, f0: 130, f1: 45, dur: 0.35, amp: 0.50, attack: 0.004)
        trigger(wave: AudioEngine.sine, f0: 60, f1: 24, dur: 1.1, amp: 0.60, attack: 0.012)
        trigger(wave: AudioEngine.noise, f0: 1, dur: 0.45, amp: 0.40, attack: 0.005, lp: 0.32)
    }

    /// A distant electric-shock — the occasional crack of a shorting circuit
    /// somewhere in the damaged citadel. Pitch and level are tweaked at random each
    /// hit and it's drenched in the through-steel reverb, so it always reads as
    /// far-off ambience. Fired on an irregular timer by World; pure atmosphere.
    func distantFault() {
        guard engine.isRunning, let buf = bank[.fault]?.randomElement() else { return }
        if isMuted(.fault) { return }
        faultVari.rate = Float.random(in: 0.82...1.18)
        faultNode.volume = Sound.fault.gain * Float.random(in: 0.45...0.85)
        faultNode.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
        if !faultNode.isPlaying { faultNode.play() }
    }

    /// The teleport's static bed: a seamless white-noise LOOP on its own node,
    /// volume-driven per frame by the renderer (0 = silent). A generated
    /// buffer through the sample path — synth voices proved too fragile a bed.
    func staticBed(_ level: Float) {
        let v = max(0, min(1, level))
        if v <= 0.001 {
            if staticOn { staticNode.stop(); staticOn = false }
            return
        }
        staticNode.volume = 0.62 * v
        if !staticOn, engine.isRunning, let buf = staticBuf {
            staticNode.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
            staticNode.play()
            staticOn = true
        }
    }
    func monsterSight(_ k: MonsterKind) { play(.hiss) { self.synthMonsterSight(k) } }       // aliens hiss when they notice you
    func monsterAttack(_ k: MonsterKind) { play(.hiss) { self.synthMonsterSight(k) } }       // a sharp hiss as a drone lunges in to strike
    /// A drone vocalisation from the shared hiss pool. `distant` routes it through the
    /// muffled + echoing chain at reduced level — the far, unseen swarm you can HEAR
    /// but not see (a deliberate creep cue); the caller keeps it rare.
    func droneVox(distant: Bool) {
        guard distant else { play(.hiss) { self.synthMonsterSight(.alien) }; return }
        guard engine.isRunning, let buf = bank[.hiss]?.randomElement() else { return }
        distantNode.volume = Sound.hiss.gain * 0.45
        distantNode.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
        if !distantNode.isPlaying { distantNode.play() }
    }
    /// The Queen's snarl: a RANDOM sample from her pool, pitched DOWN with random
    /// per-utterance variation (pitch + tempo) so a few samples never repeat and she
    /// reads ENORMOUS. Falls back to the synth growl when no queen_snarl* is bundled.
    func queenSnarl() {
        guard engine.isRunning, let buf = bank[.queenSnarl]?.randomElement() else { synthQueenSnarl(); return }
        queenPitch.pitch = queenSnarlPitchBase + Float.random(in: -queenSnarlPitchJitter...queenSnarlPitchJitter)
        queenPitch.rate  = max(0.5, queenSnarlRateBase + Float.random(in: -queenSnarlRateJitter...queenSnarlRateJitter))
        queenSnarlNode.volume = Sound.queenSnarl.gain
        queenSnarlNode.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
        if !queenSnarlNode.isPlaying { queenSnarlNode.play() }
    }
    func explosion()   { play(.explosion)   { self.synthExplosion() } }
    /// The freight elevator: heavy hydraulic leaves + the winch's low hum on
    /// descent (a LOOP on its own node so it stops the instant the car does;
    /// the synth sub-bass rumble plays beneath it).
    func elevatorDoor(open: Bool) { play(open ? .elevatorDoor : .elevatorShut) { self.synthDoorOpen() } }
    /// The corpse-fire bed IS the flamethrower's roar, boosted — one fire, one
    /// voice: the same thruster loop the weapon plays, but driven louder by the
    /// nearest pyre so a burning body RAGES (the weapon itself sits at 0.55).
    func burning(_ intensity: Float) {
        let on = intensity > 0.01
        if on != burnOn {
            burnOn = on
            if on, engine.isRunning, let buf = bank[.flamethrower]?.first {
                burnNode.stop()
                burnNode.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
                burnNode.play()
            } else {
                burnNode.stop()
            }
        }
        // purely proportional — the roar diminishes exactly as the fire loses
        // its ferocity (the intensity bell falls to 0 at burn-out; a floor here
        // made the sound drone past the flames and then cut off hard)
        if on { burnNode.volume = min(1, intensity * 1.15) }
    }

    func elevatorMove(_ on: Bool) {
        guard on != elevatorOn else { return }
        elevatorOn = on
        alog("elevatorMove \(on)")
        if on && isMuted(.elevatorMove) { return }
        guard engine.isRunning else { return }
        if on, let buf = bank[.elevatorMove]?.first {
            elevatorNode.stop()
            elevatorNode.volume = Sound.elevatorMove.gain
            elevatorNode.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
            elevatorNode.play()
        } else {
            elevatorNode.stop()
        }
        // The car stopped → its descent rumble stops with it. Fast-release any
        // lingering synth voice so the sub-bass can't ring on into the new floor
        // (the floor-1 arrival thump).
        if !on { quenchSynth() }
    }
    func doorOpen()    { play(.doorOpen)    { self.synthDoorOpen() } }
    func doorClose()   { play(.doorOpen)    { self.synthDoorOpen() } }   // a sliding door sounds much the same shutting — reuse the slide (no separate shut sample yet)
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

    // ── electrical-fault audio (World drives the volumes by proximity) ──────────
    /// Continuous proximity hum on the looped fault_hum stem — World passes `vol`
    /// 0…1 each frame from the nearest fault's distance (silent past ~2.6 m).
    func faultHum(_ vol: Float) { setLoopVol(.faultHum, max(0, min(1, vol)) * Sound.faultHum.gain) }

    /// The buzz just before a spark shower — distance-attenuated one-shot.
    func faultBuzz(_ vol: Float) { playFaultOneShot(.faultBuzz, vol) }
    /// The crackle as the sparks emit — distance-attenuated one-shot.
    func faultCrackle(_ vol: Float) { playFaultOneShot(.faultCrackle, vol) }

    private func playFaultOneShot(_ s: Sound, _ vol: Float) {
        alog("play \(s) vol=\(String(format: "%.2f", vol))")
        guard vol > 0.02, !isMuted(s), engine.isRunning, let bufs = bank[s] else { return }
        playOneShot(bufs, gain: s.gain * min(1, vol))
    }

    // ── arcade mini-game (the Space Invaders easter egg) — pure synth bleeps, no
    //    samples; keeps the terminal toy self-contained and true to the era ──
    func arcadeShoot() { trigger(wave: AudioEngine.square, f0: 820, f1: 1500, dur: 0.08, amp: 0.18, attack: 0.001) }
    /// A crunchy two-voice splat: a bright noise CRACK then a fast exponential
    /// pitch-drop CRUNCH. No reverb send and no third "thud" voice — so a cluster
    /// of rapid kills stays clean and cheap instead of smearing into mud and
    /// starving the voice pool. Enqueued as ONE batch (a single lock, not four).
    func arcadeInvaderKilled() {
        addBatch([
            makeVoice(AudioEngine.noise,   1,   1, 0.035, 0.28, attack: 0.0004, lp: 0.85),   // crack
            makeVoice(AudioEngine.square, 620,  90, 0.085, 0.16, attack: 0.001),             // pitch-drop crunch
        ])
    }
    /// The classic four-note descending march — call once per formation step with a
    /// cycling index; the tempo is set by how often the caller steps (it speeds up
    /// with the swarm, exactly like the original).
    func arcadeMarch(_ step: Int) {
        let notes: [Float] = [174, 155, 138, 130]
        trigger(wave: AudioEngine.square, f0: notes[((step % 4) + 4) % 4], dur: 0.10, amp: 0.15, attack: 0.002)
    }
    /// The player's death: a darker, weightier blast then a triangle wail sweeping
    /// down into sub-bass — the "oomph" is the sweep's destination (46 Hz), not a
    /// separate boom voice. Two voices, no reverb send, so repeated deaths can't
    /// accumulate a tail in the echo line. Enqueued as one batch.
    func arcadePlayerHit() {
        addBatch([
            makeVoice(AudioEngine.noise,    1,   1, 0.16, 0.30, attack: 0.001, lp: 0.55),    // blast
            makeVoice(AudioEngine.triangle, 300, 46, 0.30, 0.20, attack: 0.002),            // wail → sub
        ])
    }
    func arcadeUFO() { trigger(wave: AudioEngine.square, f0: 1250, f1: 1050, dur: 0.11, amp: 0.09) }   // warble tick
    func arcadeUFOHit() {
        trigger(wave: AudioEngine.square, f0: 700, f1: 1500, dur: 0.10, amp: 0.18)
        trigger(wave: AudioEngine.square, f0: 1100, f1: 1900, dur: 0.14, amp: 0.16, attack: 0.05)
    }

    func startMusic(_ m: MusicMode, depth: Int = 1) {
        alog("startMusic \(m) depth=\(depth)")
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
                bedLevel = 0; bedStartup = 0
                for s in [Sound.bedDrone, .bedPulse, .bedTension, .bedSwarm] { _ = startLoop(s, volume: 0) }
            }
            _ = startLoop(.faultHum, volume: 0)     // electrical-fault proximity hum; World drives its volume each frame
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
        bedStartup = min(1, bedStartup + dt / 0.4)        // ease the whole bed in from silence — no volume snap on arrival
        // master intensity: the swarm drives it; the Queen and combat lift it.
        let target = max(tThreat, 0.85 * tQueen, 0.6 * tCombat)
        // danger swells fast (~0.35 s) and lingers (~2.6 s) — tension shouldn't snap off.
        let tau: Float = target > bedLevel ? 0.35 : 2.6
        bedLevel += (target - bedLevel) * (1 - expf(-dt / tau))
        let lowHealth = max(0, 1 - tHealth / 0.30)        // 0 above 30% health → 1 at death's door

        if usingSampleBed {
            setLoopVol(.bedDrone,   bedStartup * (0.55 + 0.25 * bedLevel))            // ever-present room tone
            setLoopVol(.bedPulse,   bedStartup * smoothstep(0.05, 0.6, bedLevel))     // the throb that grows
            setLoopVol(.bedTension, bedStartup * smoothstep(0.40, 1.0, bedLevel))     // dissonance at high threat
            setLoopVol(.bedSwarm,   bedStartup * max(smoothstep(0.55, 1.0, bedLevel), tQueen))   // near-swarm / Queen layer
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
                if v.left <= 0 { voices[vi] = voices[voices.count - 1]; voices.removeLast(); continue }   // O(1) swap-remove (the mix is order-free)
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
                    // top 24 bits (the LCG's good bits) → [0,2) → [-1,1). The old
                    // `>> 9 / 2^23` spanned to ~4.3e9, slamming the master tanh to +1
                    // every sample — that hard-clip was the arcade "distortion".
                    s = Float(v.rng >> 40) / Float(1 << 23) - 1
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

    /// Build a voice (the total/slide/seed maths) WITHOUT taking the lock, so a
    /// caller can prepare a whole cluster and commit it in one critical section.
    private func makeVoice(_ wave: Int, _ f0: Float, _ f1: Float, _ dur: Float, _ amp: Float,
                           attack: Float = 0.004, lp: Float = 1, bus: Int = 1, send: Float = 0) -> Voice {
        let total = max(1, Int(dur * sr))
        let slide = total > 1 ? powf(max(1, f1) / max(1, f0), 1 / Float(total)) : 1
        seqCounter &+= 1
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D &+ UInt64(total) &+ UInt64(f0) &+ seqCounter &* 2_654_435_761
        if seed == 0 { seed = 1 }
        return Voice(wave: wave, freq: f0, slide: slide, amp: amp, attack: max(1, Int(attack * sr)),
                     total: total, left: total, lp: lp, bus: bus, send: send, rng: seed, seq: seqCounter)
    }

    /// Evict the LEAST AUDIBLE live voice — the one nearest to finishing or quietest
    /// right now — tie-broken by age. Was oldest-by-seq, which chopped off a just-
    /// triggered explosion the instant the pool filled (the "sounds cut each other
    /// off" in the arcade). Caller must hold `lock`.
    private func evictLocked() {
        guard !voices.isEmpty else { return }
        var worst = 0, worstE = Float.greatestFiniteMagnitude
        for j in voices.indices {
            let v = voices[j]
            let elapsed = v.total - v.left
            let env: Float = elapsed < v.attack
                ? Float(elapsed) / Float(max(1, v.attack))
                : Float(v.left) / Float(max(1, v.total - v.attack))
            let e = v.amp * env
            if e < worstE { worstE = e; worst = j }
        }
        voices.remove(at: worst)
    }

    private func enqueueLocked(_ v: Voice) {
        if voices.count >= maxVoices { evictLocked() }
        voices.append(v)
    }

    private func add(_ wave: Int, _ f0: Float, _ f1: Float, _ dur: Float, _ amp: Float,
                     attack: Float = 0.004, lp: Float = 1, bus: Int = 1, send: Float = 0) {
        let v = makeVoice(wave, f0, f1, dur, amp, attack: attack, lp: lp, bus: bus, send: send)
        os_unfair_lock_lock(lock); enqueueLocked(v); os_unfair_lock_unlock(lock)
    }

    /// Commit a whole cluster of voices under ONE lock — an explosion is a single
    /// critical section, not four or five. Cuts the game thread's contention with
    /// the real-time render callback (which holds the same lock for a full buffer)
    /// to once per event: that per-layer lock thrash was the frame-stall.
    private func addBatch(_ vs: [Voice]) {
        os_unfair_lock_lock(lock)
        for v in vs { enqueueLocked(v) }
        os_unfair_lock_unlock(lock)
    }

    /// Legacy shim kept for compatibility.
    func trigger(wave: Int, f0: Float, f1: Float? = nil, dur: Float, amp: Float,
                 attack: Float = 0.004, drive: Float = 1, bus: Int = 1, lp: Float = 1) {
        add(wave, f0, f1 ?? f0, dur, amp, attack: attack, lp: lp, bus: bus)
    }

    /// Fast-release every live synth voice so a lingering tone can't outlast the
    /// event that owns it. Each voice is recast into a short linear decay that
    /// STARTS at its current envelope level (env = left/(total−attack); with
    /// attack 0 and total = r/curEnv, left = r ⇒ env = curEnv), so the quench
    /// introduces no amplitude jump — it never clicks. This is the floor-1
    /// arrival thump: the lift's descent sub-bass (Renderer's ride rumble,
    /// dur 2.4 s) kept ringing ~2 s past the car stopping, into dead silence.
    /// The rumble is part of the car, so it stops WITH the car (elevatorMove
    /// false) — later floors mask the tail, floor 1's silence exposed it.
    func quenchSynth(release: Float = 0.08) {
        let r = max(1, Int(release * sr))
        os_unfair_lock_lock(lock)
        for i in voices.indices {
            var v = voices[i]
            let elapsed = v.total - v.left
            let curEnv: Float = elapsed < v.attack
                ? Float(elapsed) / Float(max(1, v.attack))
                : Float(v.left) / Float(max(1, v.total - v.attack))
            if curEnv <= 0.0002 { v.left = 0; voices[i] = v; continue }   // already silent → let render cull it
            if v.left <= r { continue }                                   // already ending within the release window → leave it
            v.attack = 0
            v.total = max(r + 1, Int(Float(r) / curEnv))
            v.left = r
            voices[i] = v
        }
        os_unfair_lock_unlock(lock)
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
    /// The Queen's snarl fallback (used only until queen_snarl* samples are dropped
    /// in): a deep, layered broodmother growl — sub rumble + wet mid rasp + a bite.
    private func synthQueenSnarl() {
        add(AudioEngine.saw,    70, 50, 0.60, 0.17, attack: 0.02,  lp: 0.32, send: 0.30)   // throaty growl, sliding down
        add(AudioEngine.sine,   46, 31, 0.60, 0.13, attack: 0.02,  lp: 0.50)               // sub-bass body (size)
        add(AudioEngine.noise,   1,  1, 0.32, 0.10, attack: 0.01,  lp: 0.30, send: 0.20)   // wet rasp
        add(AudioEngine.square, 130, 80, 0.10, 0.06, attack: 0.002, lp: 0.50)              // snapping bite at the front
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
    private func synthWade(_ v: Float, foot: Int) {
        let lp: Float = foot == 0 ? 0.30 : 0.40                                          // L/R read slightly different
        add(AudioEngine.noise, 1, 1, 0.16, 0.11 * v, attack: 0.006, lp: lp)             // the heavy plosh
        add(AudioEngine.noise, 1, 1, 0.08, 0.07 * v, attack: 0.001, lp: 0.55 + Float(foot) * 0.1)  // top splash
    }

    /// Synth plink stopgap for a missing drip sample: the bubble-resonance chirp
    /// of a real water drip — a rising sine that dies fast over a soft low tap —
    /// on the ambient bus, sent wet into the synth's echo for the cavern.
    private func synthDrip(_ v: Float) {
        let f0 = Float.random(in: 750...1500)
        add(AudioEngine.sine, f0, f0 * 1.6, 0.09, 0.30 * v, attack: 0.002, bus: 2, send: 0.5)   // the rising plink
        add(AudioEngine.sine, 240, 170, 0.05, 0.12 * v, attack: 0.001, bus: 2, send: 0.3)       // the low tap under it
    }
}
