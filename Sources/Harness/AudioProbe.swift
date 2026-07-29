// Citadel — headless audio probe (CITADEL_AUDIOPROBE=1).
//
// The whole AVAudioEngine graph runs in OFFLINE manual-rendering mode (see
// AudioEngine.init), so nothing reaches the speakers: the probe schedules real
// sounds through the real paths and MEASURES what actually comes out. Built to
// settle "I can't hear X" reports with numbers instead of theories.

import Foundation

enum AudioProbe {
    static func run() {
        let audio = AudioEngine()
        func report(_ label: String, _ rms: Float) {
            let db = rms > 0 ? 20 * log10(rms) : -120
            print(String(format: "  %-46s rms %.4f  (%5.1f dB)", (label as NSString).utf8String!, rms, db))
        }

        print("AudioProbe — offline render, real graph, real bank")

        // ── the SYNTHESISED machinery loop ──
        // This one cannot be auditioned in office mode, so it is asserted rather than listened to.
        // Three things have to hold: it carries signal at a sane level, it MEETS ITSELF at the loop
        // seam (a discontinuity there clicks once every two seconds — miserable to chase later), and
        // its energy sits on the motor partials it was built from rather than smeared into hiss.
        if let hum = audio.machineHumBuffer, let d = hum.floatChannelData?[0] {
            let n = Int(hum.frameLength), sr = Float(hum.format.sampleRate)
            func rms(_ from: Int, _ count: Int) -> Float {
                var a: Float = 0
                for i in from..<min(n, from + count) { a += d[i] * d[i] }
                return (a / Float(max(1, count))).squareRoot()
            }
            /// Magnitude at `f` by direct correlation — a whole DFT is overkill for four bins.
            func mag(_ f: Float) -> Float {
                var re: Float = 0, im: Float = 0
                for i in 0..<n {
                    let p = 2 * Float.pi * f * Float(i) / sr
                    re += d[i] * cos(p); im += d[i] * sin(p)
                }
                return (re * re + im * im).squareRoot() / Float(n) * 2
            }
            print(String(format: "  machine hum: %.2f s, %d frames @ %.0f Hz", Float(n) / sr, n, sr))
            report("machine hum, whole buffer", rms(0, n))
            // Seam: compare the 50 ms either side of the wrap. A clean loop has matched energy across
            // it and no step between the last sample and the first.
            let w = Int(0.05 * sr)
            let head = rms(0, w), tail = rms(n - w, w)
            let step = abs(d[n - 1] - d[0])
            print(String(format: "  seam: head rms %.4f · tail rms %.4f (ratio %.2f) · sample step %.5f  → %@",
                         head, tail, tail / max(head, 1e-6), step,
                         (abs(tail / max(head, 1e-6) - 1) < 0.35 && step < 0.02) ? "SEAMLESS" : "REVIEW"))
            // Spectrum: the motor partials must dominate the gaps between them.
            let m50 = mag(50), m100 = mag(100), m150 = mag(150), m200 = mag(200)
            let off = (mag(73) + mag(127) + mag(311)) / 3                     // off-harmonic reference
            print(String(format: "  partials: 50Hz %.4f · 100Hz %.4f · 150Hz %.4f · 200Hz %.4f · off-harmonic %.4f (×%.1f)  → %@",
                         m50, m100, m150, m200, off, m50 / max(off, 1e-6),
                         (m50 > m100 && m100 > m150 && m50 > off * 4) ? "MOTOR" : "REVIEW"))
        } else {
            print("  machine hum: ABSENT — synthesis failed or a sample overrode it")
        }
        report("silence (baseline)", audio.renderOfflineRMS(seconds: 0.5))

        // 1. the synth path: a teleport-style noise bed voice
        audio.trigger(wave: AudioEngine.noise, f0: 1, dur: 1.8, amp: 0.55, attack: 0.35)
        report("synth noise bed voice (amp 0.55)", audio.renderOfflineRMS(seconds: 1.5))

        // 2. the sampled Queen death wail, alone
        audio.monsterDeath(.queen)
        report("queen_death sample, alone", audio.renderOfflineRMS(seconds: 1.0))

        // 3. the wail with combat spam over it — a queen kill is ALWAYS mid-fire.
        //    If the one-shot pool recycles the wail's node, the RMS collapses.
        audio.monsterDeath(.queen)
        _ = audio.renderOfflineRMS(seconds: 0.3)
        for _ in 0..<14 { audio.weaponFire(.plasma) }        // > pool size in one burst
        report("queen_death + 14 plasma shots (cut test)", audio.renderOfflineRMS(seconds: 0.5))
        report("…the following second (wail should persist)", audio.renderOfflineRMS(seconds: 1.0))

        // 4. the queen_fall slam
        audio.queenFall()
        report("queen_fall sample", audio.renderOfflineRMS(seconds: 1.0))

        // 5. the teleport static bed: loop on, swell, off — dead silence after
        audio.staticBed(0.3)
        report("static bed at charge level (0.3)", audio.renderOfflineRMS(seconds: 0.5))
        audio.staticBed(1.0)
        report("static bed at full hold (1.0)", audio.renderOfflineRMS(seconds: 0.5))
        audio.staticBed(0)
        report("static bed off (must be ~silence)", audio.renderOfflineRMS(seconds: 0.5))

        // 6. MUTE invariant: with master mute on, EVERY path must render pure
        //    silence — no leak through the buses or synth. This caught the "clicks
        //    and pops while muted" bug: zeroing the group buses alone left player
        //    nodes wired straight to a bus leaking ~-24 dB of transient; muting the
        //    mainMixerNode fixed it. Each line below must report -120 dB.
        audio.muted = true
        _ = audio.renderOfflineRMS(seconds: 0.4)                 // let live tails die
        report("MUTED baseline (must be ~silence)", audio.renderOfflineRMS(seconds: 0.5))
        audio.trigger(wave: AudioEngine.noise, f0: 1, dur: 1.0, amp: 0.55, attack: 0.2)
        report("MUTED + synth trigger", audio.renderOfflineRMS(seconds: 0.6))
        func mutedOne(_ label: String, _ fire: () -> Void) {
            fire(); report("MUTED + " + label, audio.renderOfflineRMS(seconds: 0.6))
        }
        mutedOne("weaponFire plasma")   { for _ in 0..<4 { audio.weaponFire(.plasma) } }
        mutedOne("monsterDeath queen")  { audio.monsterDeath(.queen) }
        mutedOne("queenFall")           { audio.queenFall() }
        mutedOne("queenSnarl")          { audio.queenSnarl() }
        mutedOne("wade")                { audio.wade(0.6, foot: 0) }
        mutedOne("drip")                { audio.drip(volume: 0.6, pan: 0) }
        mutedOne("distantFault")        { audio.distantFault() }
        mutedOne("staticBed 1.0")       { audio.staticBed(1.0) }; audio.staticBed(0)
        mutedOne("faultCrackle")        { audio.faultCrackle(1.0) }
        mutedOne("elevatorMove")        { audio.elevatorMove(true) }; audio.elevatorMove(false)
    }
}
