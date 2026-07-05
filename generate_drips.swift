#!/usr/bin/env swift

import AVFoundation

// Generates the water-drip sample set (drip.wav + drip1…drip5.wav) into
// Resources/Audio/ — the plinks of ceiling water hitting the pools on the deep
// rock floors (7 & 8). AudioEngine plays them panned per drip site, pitch-varied
// per plink, through the wet-chamber reverb (see AudioEngine.drip).
//
// These are generated IN-HOUSE (public-domain by construction), in the same
// spirit as the synth fallbacks: good enough to ship, and any file can be
// hand-replaced later with a curated CC0 recording under the same name.
//
// The model is the physics of a real drip — and deliberately NOT a clean synth
// tone (a pure sine chirp reads electronic, not wet):
//   • the strike is a short band-passed noise "tk";
//   • the "plink" is the air bubble the drop pulls under, ringing at its
//     Minnaert resonance — RISING as the bubble shrinks — but with a random-walk
//     pitch wobble, an amplitude tremble, and a quiet inharmonic partial, the
//     imperfections that make it read as water;
//   • a low-passed noise spatter decays underneath (the micro-splash);
//   • some drops pull a SECOND, quieter bubble a beat later (the "bloip");
//   • the sum is gently saturated and low-passed so nothing is clinical.
//
// Run:  swift generate_drips.swift   (emits into Resources/Audio/; release.mk
// `build` copies Resources into the bundle).

let sr: Float = 44100
let dur: Float = 0.34
let frames = Int(sr * dur)

// (f0 Hz, chirp ratio, decay τ s, tick amp, spatter amp, second bubble?)
let variants: [(Float, Float, Float, Float, Float, Bool)] = [
    (900, 1.55, 0.060, 0.24, 0.10, false),
    (1150, 1.70, 0.050, 0.18, 0.08, false),
    (760, 1.45, 0.075, 0.28, 0.12, true),
    (1320, 1.80, 0.042, 0.16, 0.07, false),
    (990, 1.62, 0.055, 0.22, 0.10, true),
    (860, 1.38, 0.068, 0.30, 0.13, false),
]

// deterministic noise (SplitMix64, as Rng.swift), ±1
struct Mix { var s: UInt64
    mutating func f() -> Float {
        s = s &+ 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Float((z ^ (z >> 31)) >> 40) / Float(1 << 24) * 2 - 1
    }
}

let outDir = URL(fileURLWithPath: "Resources/Audio", isDirectory: true)

/// One bubble ring into `samples`: Minnaert rise + random-walk wobble +
/// amplitude tremble + a faint inharmonic partial. The imperfections are the
/// point — a perfect exponential sine reads as a synthesizer.
func ring(_ samples: inout [Float], rng: inout Mix,
          start: Int, f0: Float, ratio: Float, tau: Float, amp: Float) {
    let life = 3 * tau
    var phase: Float = 0, phase2: Float = 0
    var wobble: Float = 0, trem: Float = 0
    for i in start..<samples.count {
        let t = Float(i - start) / sr
        wobble = wobble * 0.995 + rng.f() * 0.004          // random-walk pitch drift
        trem += (rng.f() - trem) * 0.003                    // slow amplitude tremble
        let f = f0 * pow(ratio, t / life) * (1 + wobble)
        phase += 2 * .pi * f / sr
        phase2 += 2 * .pi * f * 2.31 / sr                   // inharmonic upper partial
        let attack = min(1, t / 0.0015)
        let env = attack * exp(-t / tau) * (1 + 0.25 * trem)
        samples[i] += (sin(phase) + 0.16 * sin(phase2) * exp(-t / (tau * 0.5))) * amp * env
    }
}

for (vi, (f0, ratio, tau, tickAmp, splashAmp, double)) in variants.enumerated() {
    var samples = [Float](repeating: 0, count: frames)
    var rng = Mix(s: UInt64(vi) &* 0x2545_F491_4F6C_DD1D &+ 1)

    // impact "tk": a few ms of band-passed noise as the drop strikes
    var lpTick: Float = 0, prevTick: Float = 0
    for i in 0..<Int(sr * 0.005) {
        let t = Float(i) / sr
        lpTick += (rng.f() - lpTick) * 0.45
        let band = lpTick - prevTick; prevTick = lpTick     // difference kills the lows → "tk", not "thud"
        samples[i] += band * tickAmp * 3.0 * exp(-t / 0.0022)
    }

    // spatter: low-passed noise dying under the ring (the micro-splash)
    var lpSpat: Float = 0
    let spatStart = Int(sr * 0.004)
    for i in spatStart..<Int(sr * 0.10) {
        let t = Float(i - spatStart) / sr
        lpSpat += (rng.f() - lpSpat) * 0.18
        samples[i] += lpSpat * splashAmp * exp(-t / 0.028)
    }

    // the bubble ring (pinches off ~12 ms in), and for some drops a second,
    // quieter bubble a beat later — the "bloip" real drips do
    ring(&samples, rng: &rng, start: Int(sr * 0.012), f0: f0, ratio: ratio, tau: tau, amp: 0.8)
    if double {
        ring(&samples, rng: &rng, start: Int(sr * (0.012 + 0.055)),
             f0: f0 * 1.31, ratio: ratio, tau: tau * 0.7, amp: 0.34)
    }

    // low tap: the pool surface's soft thump under everything
    var phaseT: Float = 0
    for i in 0..<Int(sr * 0.05) {
        let t = Float(i) / sr
        let f = 220 - t / 0.05 * 55
        phaseT += 2 * .pi * f / sr
        samples[i] += sin(phaseT) * 0.12 * exp(-t / 0.02)
    }

    // gentle saturation for body, then a lowpass to take the clinical edge off
    var lpOut: Float = 0
    let k = 1 - exp(-2 * Float.pi * 7000 / sr)              // one-pole ~7 kHz
    for i in samples.indices {
        let sat = tanh(samples[i] * 1.4)
        lpOut += (sat - lpOut) * k
        samples[i] = lpOut
    }

    // normalise to a comfortable one-shot peak
    let peak = samples.map(abs).max() ?? 1
    if peak > 0 { for i in samples.indices { samples[i] *= 0.75 / peak } }

    let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(sr), channels: 1)!
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
    buf.frameLength = AVAudioFrameCount(frames)
    samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: frames) }

    let name = vi == 0 ? "drip.wav" : "drip\(vi).wav"
    let url = outDir.appendingPathComponent(name)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: Double(sr),
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try! AVAudioFile(forWriting: url, settings: settings)
    try! file.write(from: buf)
    print("wrote \(url.path)")
}
