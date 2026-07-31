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

        // ── COLD START: the proximity loops must work on the FIRST level of a session ──
        // Written to reproduce "no machine noise on floors 7 and 8" and it does NOT: it passes with or
        // without the warm-up, on the game's own timeline. So it did not find that fault — but it is a
        // real invariant worth keeping, and its failure to fire is itself the useful result. It rules
        // out the whole class of "the volume never reaches a cold node", which is where I was looking.
        // A player node ignores the volume set on it until it has rendered a buffer once, and both
        // proximity hums are started at 0 and raised by World every frame. Cold, they render at zero
        // for ever — the plant machinery and the electrical fault were silent on every floor of a whole
        // session because of it. This runs on its OWN AudioEngine, started exactly once, because the
        // rest of this probe restarts the level audio for every measurement and that alone was enough
        // to hide the fault: warmed by an earlier cycle, the volumes worked.
        do {
            let cold = AudioEngine()
            cold.startMusic(.level, depth: Progression.industrialFirstFloor, farSignalGain: 0)
            // THE GAME'S TIMELINE, which is the whole point: the loops start at volume 0 and the marine
            // spends seconds walking before she is near a machine, so the node renders a great many
            // buffers at zero BEFORE the volume is raised. Raising it first — as the rest of this probe
            // does — is a different test, and it passes either way.
            _ = cold.renderOfflineRMS(seconds: 2.0)              // …walk about for a bit, hum at zero
            cold.machineHum(1)                                   // now stand at a compressor
            cold.faultHum(1)                                     // …and beside a shorting panel
            _ = cold.renderOfflineRMS(seconds: 0.5)
            let heard = cold.renderOfflineRMS(seconds: 1.0)
            let silent = cold.renderOfflineRMS(seconds: 0.0001) * 0 + 0.0008   // the floor a silent bus sits at
            print("  \(heard > silent ? "PASS  " : "REVIEW")  the proximity hums work from a COLD start — "
                  + String(format: "rms %.4f (silence would be under %.4f)", heard, silent))
        }

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

        // 6. THE AMBIENT MIX. Every brief for these levels is RELATIVE — the far Signal
        //    "barely audible" on the first deep floor, "detectable but not dominant" on the
        //    second (beside a compressor the MACHINE has to read over it), "clearly audible
        //    without overpowering" on the last; the short-circuit sequence "not too loud".
        //    None of that can be checked against a gain constant, because a stem's output
        //    level is its node volume TIMES the intrinsic RMS of the sample, and the samples
        //    differ by more than the trims do. So each level is measured out of the real
        //    graph and reported as a RATIO to the room tone that is always under it.
        //    Each element is measured ALONE, which is what an offline graph is for: a ratio of
        //    isolated levels answers "can I hear X over Y" without one masking the other's
        //    measurement. `stopMusic` + a settling render between elements keeps them isolated.
        let deckFloors = Progression.deckFloors
        var bed: Float = 0
        print("  reactive bed: " + (audio.sampleBedsLoaded ? "SAMPLED stems" : "SYNTH fallback"))
        /// Hold a level's audio for `sweep` seconds and return its mean and loudest-second RMS,
        /// TICKING `updateMusic` at 60 Hz throughout — exactly as the frame loop does. Ticking is
        /// not optional: the synth bed re-enqueues its voices every tick, so a sweep that only
        /// renders measures a decaying tail rather than the bed. A lead-in is discarded first, so
        /// what's reported is steady state and not the fade-in.
        func settle(_ sweep: Float, _ setUp: () -> Void) -> (mean: Float, peak: Float) {
            audio.stopMusic()
            _ = audio.renderOfflineRMS(seconds: 0.3)           // previous element's tail dies
            setUp()
            let dt: Float = 1.0 / 60
            func second() -> Float {                           // one ticked second
                var acc = 0.0, n = 0
                for _ in 0..<60 {
                    audio.updateMusic(dt)
                    let r = audio.renderOfflineRMS(seconds: Double(dt))
                    acc += Double(r) * Double(r); n += 1
                }
                return Float((acc / Double(max(1, n))).squareRoot())
            }
            _ = second()                                       // lead-in: the bed eases up from silence
            var sum: Float = 0, peak: Float = 0, n = 0
            while Float(n) < sweep { let r = second(); sum += r * r; peak = max(peak, r); n += 1 }
            return ((sum / Float(max(1, n))).squareRoot(), peak)
        }
        func vsBed(_ r: Float) -> Float { r > 0 && bed > 0 ? 20 * log10(r / bed) : -120 }
        func calm() { audio.setTension(threat: 0, queen: 0, health: 1, combat: 0) }

        // (a) the room tone — the ever-present layer everything else is heard over.
        bed = settle(3) {
            audio.startMusic(.level, depth: deckFloors, farSignalGain: 0); calm()
        }.mean
        report("ambient bed, calm — THE REFERENCE", bed)

        // (b) the plant hum at max proximity, over that bed — the loudest sustained ambience in
        //     the game, and the one Jonathan named: on floor 7 this must read OVER the Signal.
        let plant = settle(3) {
            audio.startMusic(.level, depth: deckFloors, farSignalGain: 0); calm()
            audio.machineHum(1)                               // stood right at a compressor
        }.mean
        report(String(format: "+ plant hum, beside a compressor   %+.1f dB", vsBed(plant)), plant)

        // (b2) THE PLANT HEARD THROUGH THE DECK, on the floors above it. The level is what
        //      `World.driveMachineHum` feeds in — a halving per floor of separation — and the point
        //      is that it should be nothing on the surface and something you notice by the deep
        //      workings, without ever rivalling the room tone it sits under.
        //      The whole ramp lives in about two decibels, because the plant's OWN between-halls
        //      level is its ceiling and that measures only ~+2 dB over the room tone. Reported per
        //      floor next to that ceiling, so a future change to either is visibly a change to both.
        var plantBetweenHalls: Float = 0
        let plantFloorLevel = World(level: 7, colonyIndex: 0, seed: 1).machineHumFloorForTest
        let deckEnd = World(level: 1, colonyIndex: 0, seed: 1).machineHumThroughDeckForTest
        for (label, level) in [("floor 1 (the surface)", Float(0)),
                               ("floor 3", deckEnd * 0.4),
                               ("floor 6 (deep workings)", deckEnd * 5 / 6),
                               ("floor 7 BETWEEN HALLS — must beat the Signal", plantFloorLevel),
                               ("floor 7 beside a machine", 1.0)] {
            let r = settle(2) {
                audio.startMusic(.level, depth: 6, farSignalGain: 0); calm()
                audio.machineHum(level)
            }.mean
            report("+ plant through the deck, " + label.padding(toLength: 36, withPad: " ", startingAt: 0)
                   + String(format: "%+.1f dB", vsBed(r)), r)
            if level == plantFloorLevel { plantBetweenHalls = r }
        }

        // (c) THE FAR SIGNAL, floor by floor, swept across its WHOLE loop — it breathes, swells
        //     and bursts, so the mean and the loudest second are both reported: "barely audible"
        //     is a claim about the mean, "does not overpower" is a claim about the peak.
        let loop = audio.loopSeconds(.signalFar)
        print(String(format: "  far Signal loop: %.1f s — swept whole", loop))
        var sig: [(floor: Int, mean: Float, swell: Float)] = []
        for f in (deckFloors + 1)...Progression.floorsPerBuilding {
            let ramp = Progression.farSignalRamp(f)
            let s = settle(loop) {
                audio.startMusic(.level, depth: f, farSignalGain: ramp); calm()
            }
            sig.append((f, s.mean, s.peak))
            report(String(format: "+ far Signal, floor %d/%d (ramp %.2f)  %+.1f dB · swell %+.1f dB",
                          f, Progression.floorsPerBuilding, ramp, vsBed(s.mean), vsBed(s.peak)), s.mean)
        }

        // THE PLANT MUST BE HEARD ON THE PLANT FLOORS. Jonathan's brief was that machinery reads over
        // the Signal there; the plant's between-halls level was 6 dB UNDER the floor-8 Signal and the
        // machinery seemed to have gone silent. Asserted against the Signal's SWELL, not its mean,
        // because a bed that only wins on average still disappears every time the transmission surges.
        if let deep = sig.first(where: { $0.floor == Progression.industrialFirstFloor }) {
            let ok = vsBed(plantBetweenHalls) > vsBed(deep.swell)
            print("  \(ok ? "PASS  " : "REVIEW")  the plant is heard over the Signal on its own floors — "
                  + String(format: "plant %+.1f dB vs floor %d Signal swell %+.1f dB",
                           vsBed(plantBetweenHalls), deep.floor, vsBed(deep.swell)))
        }

        // (d) the ONE-SHOTS, each fired over the same calm bed and measured across its onset —
        //     the short-circuit sequence at the panel (the worst case the player can stand in,
        //     since `faultCommitLevel` only ever VOICES a shower close and in sight), and a
        //     plasma shot as the ceiling: nothing ambient may come near a weapon.
        /// Fire a one-shot over the live bed and return the RMS of the following `seconds`.
        func over(_ seconds: Float, _ fire: () -> Void) -> Float {
            fire()
            var acc = 0.0, n = 0
            let dt: Float = 1.0 / 60
            for _ in 0..<Int(seconds / dt) {
                audio.updateMusic(dt)
                let r = audio.renderOfflineRMS(seconds: Double(dt))
                acc += Double(r) * Double(r); n += 1
            }
            return Float((acc / Double(max(1, n))).squareRoot())
        }
        //     Measured with the bed STOPPED. A one-shot is brief and the graph has reverb, so a
        //     transient laid over a running bed does not scale cleanly with its own trim and the
        //     before/after of a trim change cannot be read off it. Isolated, the number is exactly
        //     the trim times the sample, which is the claim being checked; the bed sits ~17 dB
        //     below all of these anyway, so it moves the ear far less than it moves the maths.
        audio.stopMusic()
        /// Render forward until the graph is genuinely quiet, so the next measurement starts from
        /// silence. Not "render two seconds and assume it finished": `renderOfflineRMS` gives up
        /// early if the engine returns anything but success, and a 2 s sample that has not
        /// actually finished lands its remainder inside the NEXT window, where it reads as level.
        /// SUSTAINED quiet, not the first quiet slice. A spark sample is two seconds of
        /// intermittent cracks, so it has gaps mid-buffer that read as silence — stopping at the
        /// first one leaves the rest of the sample to land inside the NEXT measurement, where it
        /// reads as level and makes a trim look like it did nothing. Four consecutive quiet
        /// quarter-seconds is longer than any gap inside these samples.
        func drain(_ what: String) {
            var t = 0.0, quiet = 0
            while t < 12 {
                quiet = audio.renderOfflineRMS(seconds: 0.25) < 1e-4 ? quiet + 1 : 0
                if quiet >= 4 { return }
                t += 0.25
            }
            print("  drain: \(what) never went quiet in 12 s — the next reading may include it")
        }
        func alone(_ seconds: Double, _ fire: () -> Void) -> Float {
            fire(); return audio.renderOfflineRMS(seconds: seconds)
        }
        drain("the bed")
        let bz = alone(0.4) { audio.faultBuzz(1) }             // the buzz is 0.32 s
        report(String(format: "fault BUZZ at the panel            %+.1f dB vs bed", vsBed(bz)), bz)
        drain("the buzz")
        let ck = alone(0.4) { audio.faultCrackle(1) }          // its onset — what the ear judges
        report(String(format: "fault CRACKLE onset                %+.1f dB vs bed", vsBed(ck)), ck)
        drain("the crackle")
        // …and the SAME crackle at fractions of its distance attenuation. World scales these
        // one-shots by proximity, so the path has to be LINEAR in level — if it is not, every
        // fault in the game arrives at the wrong distance, and a trim in the table does nothing
        // that can be heard. Both were true before the spark voices got their own nodes.
        let raw = audio.sampleStats(.faultCrackle)
        print(String(format: "  fault_crackle.wav itself: %.2f s · rms %.4f · peak %.3f",
                     raw.seconds, raw.rms, raw.peak))
        // Same shower, fired repeatedly: every one must come out identical. They did not — the
        // first firing on each voice ignored its level and arrived at the sample's own, so the
        // opening sparks of a run were the loudest in it. Cheap to check, invisible without a probe.
        var reps: [Float] = []
        for _ in 0..<5 {
            audio.faultCrackle(1)
            reps.append(audio.renderOfflineStats(seconds: 0.4).rms)
            drain("the crackle")
        }
        if let lo = reps.min(), let hi = reps.max(), hi > 0 {
            print("  \(hi - lo < hi * 0.01 ? "PASS  " : "REVIEW")  every shower fires at the same level — "
                  + String(format: "5 firings spread %.4f…%.4f", lo, hi))
        }
        var att: [Float] = []
        for v in [Float(1.0), 0.5, 0.25] {
            let pre = audio.renderOfflineStats(seconds: 0.2)     // the graph BEFORE firing
            audio.faultCrackle(v)
            let s = audio.renderOfflineStats(seconds: 0.4)
            att.append(s.rms)
            print(String(format: "  crackle at attenuation %.2f: rms %.4f (×%.2f of full) · peak %.3f%@%@",
                         v, s.rms, att[0] > 0 ? s.rms / att[0] : 0, s.peak,
                         pre.rms > 1e-4 ? String(format: "  ⚠︎ graph not silent before firing (%.4f)", pre.rms) : "",
                         s.clipped > 0 ? "  ⚠︎ \(s.clipped) CLIPPED" : ""))
            drain("the crackle")
        }
        if att.count == 3, att[0] > 0 {
            let ok = abs(att[1] / att[0] - 0.5) < 0.03 && abs(att[2] / att[0] - 0.25) < 0.03
            print("  \(ok ? "PASS  " : "REVIEW")  a fault's level tracks its distance — "
                  + String(format: "×%.2f and ×%.2f (want ×0.50 and ×0.25)", att[1] / att[0], att[2] / att[0]))
        }
        let pl = alone(0.4) { audio.weaponFire(.plasma) }
        report(String(format: "one plasma shot — THE CEILING      %+.1f dB vs bed", vsBed(pl)), pl)
        drain("the plasma shot")                               // silence before the mute tests

        // (e) THE BRIEF, ASSERTED. The levels above were set to a brief stated in relative
        //     terms, so they are checked in relative terms: the trim that satisfies it is one
        //     number in `Sound.gain`, and a number is only as good as the check under it. The
        //     margins are the point — a swell that merely TIES the reference does not read
        //     under it, so each comparison demands daylight, not a dead heat.
        let clear: Float = 3          // dB of daylight a reference needs over the Signal's swell
        let audible: Float = 5        // dB over room tone before "clearly audible" is earned
        let barely: Float = 3         // …and the most "barely audible" may sit over it
        func verdict(_ claim: String, _ ok: Bool, _ detail: String) {
            print("  \(ok ? "PASS  " : "REVIEW")  \(claim) — \(detail)")
        }
        if let first = sig.first, let last = sig.last, sig.count >= 2 {
            let plantDB = vsBed(plant), ceilDB = vsBed(pl)
            verdict("floor \(first.floor): barely audible", vsBed(first.mean) <= barely,
                    String(format: "%+.1f dB over room tone (limit %+.0f)", vsBed(first.mean), barely))
            // The floor below the bottom is a PLANT floor: standing at a compressor, the machine
            // has to read over the transmission — Jonathan's words, so his test.
            let mid = sig[sig.count - 2]
            verdict("floor \(mid.floor): machinery reads OVER the Signal",
                    vsBed(mid.swell) <= plantDB - clear,
                    String(format: "swell %+.1f vs plant hum %+.1f (needs %.0f dB clear)",
                           vsBed(mid.swell), plantDB, clear))
            verdict("floor \(last.floor): clearly audible", vsBed(last.mean) >= audible,
                    String(format: "%+.1f dB over room tone (needs %+.0f)", vsBed(last.mean), audible))
            verdict("floor \(last.floor): does not overpower a weapon",
                    vsBed(last.swell) <= ceilDB - clear,
                    String(format: "swell %+.1f vs plasma %+.1f (needs %.0f dB clear)",
                           vsBed(last.swell), ceilDB, clear))
        }

        // 7. MUTE invariant: with master mute on, EVERY path must render pure
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
