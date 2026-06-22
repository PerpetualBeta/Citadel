// Citadel — from-scratch code synthesiser (clean edition).
//
// No audio files. An AVAudioSourceNode is fed mono samples generated on the
// audio thread from a small voice pool. The priority here is CLEAN, punchy
// output with headroom — every voice runs at a modest level, there's no
// per-voice overdrive, and the master stage is a gentle soft-clip that only
// catches peaks, so nothing distorts. A single damped feedback-delay gives the
// music and ambience a sense of space (SFX stay dry and tight). Three gain
// buses — music (0), SFX (1), ambient (2).

import Foundation
import AVFoundation
import os

final class AudioEngine {
    static let sine = 0, square = 1, triangle = 2, saw = 3, noise = 4

    private let engine = AVAudioEngine()
    private var src: AVAudioSourceNode!
    private let sr: Float = 44100

    private struct Voice {
        var wave: Int
        var phase: Float = 0
        var freq: Float
        var slide: Float            // per-sample multiplier (pitch envelope)
        var amp: Float
        var attack: Int             // samples
        var total: Int             // total samples (attack + decay-to-zero)
        var left: Int
        var lp: Float               // one-pole low-pass coef (1 = bypass)
        var lpState: Float = 0
        var bus: Int                // 0 music, 1 sfx, 2 ambient
        var send: Float             // 0…1 into the space bus
        var rng: UInt64
        var seq: UInt64
    }

    private var voices: [Voice] = []
    private var seqCounter: UInt64 = 0
    private let maxVoices = 28
    private let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1); p.initialize(to: os_unfair_lock()); return p
    }()

    var musicGain: Float
    var sfxGain: Float
    var ambientGain: Float
    var muted = false

    // space: one damped feedback delay
    private var delay: [Float]
    private let delayLen: Int
    private var delayIdx = 0
    private var damp: Float = 0
    private let feedback: Float = 0.36
    private let wetMix: Float = 0.22

    enum MusicMode { case none, title, level }
    private var mode: MusicMode = .none
    private var seqTime: Float = 0
    private var seqStep = 0

    init() {
        musicGain = GameSettings.shared.musicVolume
        sfxGain = GameSettings.shared.sfxVolume
        ambientGain = GameSettings.shared.ambientVolume
        delayLen = Int(0.19 * 44100)
        delay = [Float](repeating: 0, count: delayLen)

        let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(sr), channels: 1)!
        src = AVAudioSourceNode { [weak self] _, _, frameCount, abl in
            guard let self = self else { return noErr }
            let out = UnsafeMutableAudioBufferListPointer(abl)[0].mData!.assumingMemoryBound(to: Float.self)
            self.render(out, Int(frameCount)); return noErr
        }
        engine.attach(src)
        engine.connect(src, to: engine.mainMixerNode, format: fmt)
        try? engine.start()
    }

    // ── audio thread ──────────────────────────────────────────────────────────
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
            // space (damped feedback delay)
            let echo = delay[delayIdx]
            damp += (echo - damp) * 0.42
            var fb = wetIn + damp * feedback
            if fb > 3 { fb = 3 } else if fb < -3 { fb = -3 }
            delay[delayIdx] = fb
            delayIdx += 1; if delayIdx >= delayLen { delayIdx = 0 }
            var o = dry + echo * wetMix
            o = tanhf(o * 0.8)            // gentle peak limiter; ~linear at normal levels
            out[i] = o
        }
        os_unfair_lock_unlock(lock)
    }

    // ── triggering ──────────────────────────────────────────────────────────
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

    // ── music sequencer ─────────────────────────────────────────────────────
    func startMusic(_ m: MusicMode) { mode = m; seqTime = 0; seqStep = 0 }
    func stopMusic() { mode = .none }

    func updateMusic(_ dt: Float) {
        if mode == .none { return }
        let stepDur: Float = mode == .title ? 0.14 : 0.40
        seqTime += dt
        var guardN = 0
        while seqTime >= stepDur && guardN < 8 { seqTime -= stepDur; playStep(seqStep); seqStep += 1; guardN += 1 }
    }

    // Dark E-phrygian. Bass drives; a soft lead floats above; synth drums.
    private static let bass = [40, 40, 47, 41, 40, 40, 45, 43, 40, 40, 48, 41, 40, 43, 45, 47]
    private static let lead = [-1, -1, 64, -1, 67, -1, 65, 64, -1, 64, -1, 67, -1, 71, 67, -1]

    private func playStep(_ step: Int) {
        if mode == .title {
            let b = AudioEngine.bass[step % AudioEngine.bass.count]
            add(AudioEngine.triangle, note(b - 12), note(b - 12), 0.13, 0.16, attack: 0.003, lp: 0.5, bus: 0, send: 0.12)
            if step % 4 == 0 { add(AudioEngine.sine, 110, 46, 0.16, 0.32, attack: 0.001, bus: 0) }          // kick
            if step % 4 == 2 { add(AudioEngine.noise, 1, 1, 0.10, 0.10, attack: 0.001, lp: 0.5, bus: 0) }   // snare
            if step % 2 == 1 { add(AudioEngine.noise, 1, 1, 0.03, 0.04, attack: 0.001, bus: 0) }            // hat
            let l = AudioEngine.lead[step % AudioEngine.lead.count]
            if l >= 0 { add(AudioEngine.square, note(l), note(l), 0.22, 0.08, attack: 0.006, lp: 0.35, bus: 0, send: 0.3) }
        } else {
            // sparse oppressive ambience
            if step % 4 == 0 { add(AudioEngine.triangle, note(26 + (seqStep / 4) % 4), note(26), 1.6, 0.09, attack: 0.5, lp: 0.25, bus: 2, send: 0.5) }
            if step % 16 == 9 { add(AudioEngine.noise, 380, 180, 0.7, 0.04, attack: 0.3, lp: 0.3, bus: 2, send: 0.6) }   // wind
            if step % 12 == 5 { add(AudioEngine.triangle, note(50 + (seqStep % 5)), note(48), 0.18, 0.05, attack: 0.01, lp: 0.6, bus: 2, send: 0.7) } // distant clank
        }
    }

    // ── layered SFX (clean, punchy) ───────────────────────────────────────────
    func weaponFire(_ w: WeaponKind) {
        switch w {
        case .rocket:
            add(AudioEngine.noise, 900, 300, 0.20, 0.14, lp: 0.5)   // whoosh
            add(AudioEngine.saw, 140, 80, 0.22, 0.16, lp: 0.6)
        case .plasma:
            add(AudioEngine.square, 820, 520, 0.07, 0.13, lp: 0.9); add(AudioEngine.sine, 1200, 900, 0.06, 0.06)
        case .flamethrower:
            add(AudioEngine.noise, 1, 1, 0.16, 0.09, lp: 0.32)     // breathy roar of the burn
            add(AudioEngine.saw, 95, 78, 0.13, 0.05, lp: 0.45)     // low gas hiss
        }
    }
    func enemyShot(_ k: MonsterKind) {     // vestigial — neither caste fires
        let f: Float = k == .queen ? 360 : 480
        add(AudioEngine.square, f, f * 0.6, 0.12, 0.11, lp: 0.7, send: 0.1)
    }
    func monsterPain(_ k: MonsterKind) {
        let f: Float = k == .queen ? 140 : 300        // a wet shriek; the Queen's is a subsonic bellow
        add(AudioEngine.saw, f, f * 0.7, 0.10, 0.11, lp: 0.5); add(AudioEngine.noise, 1, 1, 0.05, 0.06, lp: 0.4)
    }
    func monsterDeath(_ k: MonsterKind) {
        let f: Float = k == .queen ? 180 : 340
        add(AudioEngine.saw, f, 60, 0.45, 0.16, lp: 0.5, send: 0.2); add(AudioEngine.noise, 1, 1, 0.22, 0.12, lp: 0.3)
    }
    func monsterSight(_ k: MonsterKind) {
        let f: Float = k == .queen ? 84 : 240
        add(AudioEngine.saw, f, f * 0.8, 0.5, 0.12, attack: 0.04, lp: 0.4, send: 0.25)
    }
    func explosion() {
        add(AudioEngine.noise, 1, 1, 0.4, 0.22, lp: 0.3, send: 0.2); add(AudioEngine.sine, 110, 38, 0.5, 0.26)
        add(AudioEngine.noise, 1, 1, 0.05, 0.14)
    }
    func doorOpen() { add(AudioEngine.saw, 64, 96, 0.5, 0.10, attack: 0.05, lp: 0.3, send: 0.3) }
    func locked() { add(AudioEngine.square, 150, 150, 0.09, 0.13, lp: 0.6); add(AudioEngine.square, 110, 110, 0.12, 0.13, lp: 0.6) }
    func pickup() { add(AudioEngine.sine, 600, 1000, 0.10, 0.13, attack: 0.002, send: 0.1) }
    func secret() { for (i, n) in [60, 64, 67, 72].enumerated() { add(AudioEngine.triangle, note(n), note(n), 0.12, 0.11, attack: 0.003, lp: 0.7, send: 0.25); _ = i } }
    func exit() { for n in [55, 59, 62, 67] { add(AudioEngine.square, note(n), note(n), 0.18, 0.12, attack: 0.004, lp: 0.6, send: 0.3) } }
    func playerPain() { add(AudioEngine.saw, 300, 170, 0.13, 0.16, lp: 0.5); add(AudioEngine.noise, 1, 1, 0.05, 0.08, lp: 0.4) }
    func playerDeath() { add(AudioEngine.saw, 320, 55, 0.9, 0.22, lp: 0.4, send: 0.3); add(AudioEngine.noise, 1, 1, 0.3, 0.12, lp: 0.3) }
}
