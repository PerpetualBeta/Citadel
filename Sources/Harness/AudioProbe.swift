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
    }
}
