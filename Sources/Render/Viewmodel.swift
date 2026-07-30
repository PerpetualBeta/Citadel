// Citadel — the marine's first-person weapons as raymarched SDF viewmodels.
//
// The old baked-sprite guns floated OVER the fully-lit world and could never
// sit in it. Here each weapon is built from GShape primitives in GUN-LOCAL
// space (x right · y up · z forward), packed per frame into the kernel's
// shape buffer, and marched as an overlay (see GPURaymarch.vmField): the
// weapon takes the world's sector fill, ceiling-lamp pools, dynamic lights
// and specular — it darkens in dark rooms, glints under lamps, and catches
// its own muzzle flash.
//
// Materials tie into the world's fiction: gunmetal and dark steel, COPPER
// fittings (the citadel's pipework), red enamel accents (the stopcock
// valves), and emissive elements per weapon — plasma's cyan core, the
// flamethrower's amber pilot flame, the rocket's red aim bead.

import simd

enum Viewmodel {
    typealias GShape = GPURaymarch.GShape

    // ── palette (0…1, matching the item/prop shapes) ──────────────────────────
    static let gunmetal  = SIMD3<Float>(0.44, 0.47, 0.52)
    static let darkSteel = SIMD3<Float>(0.24, 0.25, 0.29)
    static let nearBlack = SIMD3<Float>(0.05, 0.05, 0.06)
    static let copper    = SIMD3<Float>(0.62, 0.36, 0.26)   // the pipework's copper
    static let redEnamel = SIMD3<Float>(0.55, 0.10, 0.08)   // the valve enamel
    static let brassDark = SIMD3<Float>(0.34, 0.28, 0.16)
    static let rubber    = SIMD3<Float>(0.08, 0.08, 0.09)
    static let plasmaCyan = SIMD3<Float>(0.30, 0.95, 1.10)
    static let pilotAmber = SIMD3<Float>(1.00, 0.55, 0.15)
    static let flashWhite = SIMD3<Float>(0.70, 1.00, 1.10)
    static let flashOrange = SIMD3<Float>(1.00, 0.62, 0.25)
    static let gunBlack  = SIMD3<Float>(0.09, 0.09, 0.10)   // matte parkerised black — the plasma rifle body
    static let armyGreen = SIMD3<Float>(0.20, 0.27, 0.15)   // olive drab — the rocket launcher tube
    static let steelGrey = SIMD3<Float>(0.30, 0.31, 0.34)   // dark blued steel — the flamethrower body

    // ── primitive builders (gun-local space; encodings in GPURaymarch.vmShapeDist) ──
    private static func box(_ c: SIMD3<Float>, _ h: SIMD3<Float>, _ round: Float,
                            _ col: SIMD3<Float>, k: Float = 0.006) -> GShape {
        GShape(a: SIMD4(c.x, c.y, c.z, round), b: SIMD4(h.x, h.y, h.z, -2), col: SIMD4(col.x, col.y, col.z, k))
    }
    private static func zcyl(_ c: SIMD3<Float>, r: Float, half: Float, edge: Float = 0.006,
                             _ col: SIMD3<Float>, em: Float = 0, k: Float = 0.006) -> GShape {
        GShape(a: SIMD4(c.x, c.y, c.z, r), b: SIMD4(edge, half, em, -4), col: SIMD4(col.x, col.y, col.z, k))
    }
    private static func ycyl(_ c: SIMD3<Float>, r: Float, half: Float, edge: Float = 0.006,
                             _ col: SIMD3<Float>, em: Float = 0, k: Float = 0.006) -> GShape {
        GShape(a: SIMD4(c.x, c.y, c.z, r), b: SIMD4(edge, half, em, -3), col: SIMD4(col.x, col.y, col.z, k))
    }
    private static func sph(_ c: SIMD3<Float>, r: Float, _ col: SIMD3<Float>, k: Float = 0.006) -> GShape {
        GShape(a: SIMD4(c.x, c.y, c.z, r), b: SIMD4(0, 0, 0, -1), col: SIMD4(col.x, col.y, col.z, k))
    }
    private static func glow(_ c: SIMD3<Float>, r: Float, _ col: SIMD3<Float>, em: Float, k: Float = 0.008) -> GShape {
        GShape(a: SIMD4(c.x, c.y, c.z, r), b: SIMD4(em, 0, 0, -5), col: SIMD4(col.x, col.y, col.z, k))
    }
    private static func cone(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ r1: Float, _ r2: Float,
                             _ col: SIMD3<Float>, k: Float = 0.006) -> GShape {
        GShape(a: SIMD4(a.x, a.y, a.z, r1), b: SIMD4(b.x, b.y, b.z, r2), col: SIMD4(col.x, col.y, col.z, k))
    }

    // ── PLASMA CASTER ── the workhorse: gunmetal receiver, copper induction
    // coils around the barrel shroud, and the cyan energy cell glowing on the
    // left flank (the side the marine sees). fire = recoil-normalised 0…1,
    // flash = muzzle-flash 0…1.
    /// `charge` 0…1 = cells in reserve against the ISSUE LOAD (`Player.issueCells`), not the carry cap —
    /// see that constant for why. `time` drives the low-charge pulse.
    static func plasma(fire: Float, flash: Float, charge: Float = 1, time: Float = 0) -> [GShape] {
        var s: [GShape] = []
        s.append(box(SIMD3(0, 0, -0.04), SIMD3(0.052, 0.048, 0.15), 0.014, gunBlack))          // receiver
        // The spine rail is in the BODY's parkerised black, not darkSteel. It is the topmost face of
        // the gun and it runs the whole length of it, so at 0.24 albedo against a 0.09 body it read as
        // a long pale strip exactly where a reflection would sit — and that is what it was taken for,
        // twice. Chasing it through the lighting was wrong three times over: the baked-field specular,
        // the field ambient and the two eye-anchored terms together account for about a quarter of that
        // strip's brightness, and this one number for the rest. An integral rail in the same finish as
        // the receiver is also what a real parkerised rifle looks like; it reads by its edge, not by
        // being a lighter colour.
        s.append(box(SIMD3(0, 0.058, -0.02), SIMD3(0.020, 0.010, 0.17), 0.006, gunBlack))      // top spine rail
        s.append(zcyl(SIMD3(0, 0.006, 0.17), r: 0.042, half: 0.10, edge: 0.008, gunBlack))     // barrel shroud
        for z in [Float(0.10), 0.15, 0.20] {                                                   // induction coils
            s.append(zcyl(SIMD3(0, 0.006, z), r: 0.050, half: 0.008, edge: 0.004, copper))
        }
        s.append(zcyl(SIMD3(0, 0.006, 0.285), r: 0.046, half: 0.014, edge: 0.005, gunBlack))   // muzzle collar
        s.append(zcyl(SIMD3(0, 0.006, 0.30), r: 0.020, half: 0.045, edge: 0.004, nearBlack))   // inner barrel
        s.append(ycyl(SIMD3(-0.055, 0.01, -0.02), r: 0.020, half: 0.035, edge: 0.004, darkSteel))   // cell housing
        s.append(glow(SIMD3(-0.070, 0.012, -0.02), r: 0.016, plasmaCyan, em: 2.4))             // the energy cell window
        // ── CHARGE STATUS LEDs ── three of them, and they now MEAN it: a segment per third of the
        // cell reserve, filling from the rear of the rail forward. They were hardcoded all-on at a
        // fixed brightness, so a gauge labelled "charge status" reported the same full charge whether
        // you were carrying 400 cells or 4 — an instrument that lies is worse than no instrument.
        //
        // Diegetic on purpose: the visor already prints CELLS as a number, and this is the gun saying
        // the same thing in the corner of your eye, so a glance down the sights is enough. A spent
        // segment goes DARK rather than dim-cyan — a dark LED reads as off at a glance, where a dim
        // one just reads as a dirty lens. The last live segment PULSES once you are into the final
        // third, which is the one moment the number is worth looking up for.
        let lit = charge <= 0 ? 0 : max(1, Int((charge * 3).rounded(.up)))       // any charge at all lights one
        let pulse = 0.5 + 0.5 * sinf(time * 6.0)                                // ~1 Hz, the cadence of a warning lamp
        for (k, z) in [Float(-0.10), -0.04, 0.02].enumerated() {
            if k < lit {
                // the LAST live segment pulses once she is into the final third — the one moment the
                // number on the visor is worth looking up for
                let warn = (k == lit - 1) && charge <= 1.0 / 3.0
                s.append(glow(SIMD3(0.012, 0.066, z), r: 0.007, plasmaCyan, em: warn ? 0.7 + 1.6 * pulse : 1.8))
            } else {
                s.append(sph(SIMD3(0.012, 0.066, z), r: 0.006, nearBlack))       // spent: a dead lens, not a dim one
            }
        }
        s.append(box(SIMD3(0, -0.10, -0.13), SIMD3(0.026, 0.065, 0.030), 0.010, darkSteel))    // grip
        s.append(box(SIMD3(0, -0.01, -0.21), SIMD3(0.036, 0.042, 0.045), 0.012, gunBlack))     // stock block
        s.append(cone(SIMD3(0, -0.045, 0.02), SIMD3(0, -0.020, 0.20), 0.018, 0.012, darkSteel)) // under-barrel strut
        if flash > 0 {
            s.append(glow(SIMD3(0, 0.006, 0.345 + 0.015 * flash), r: 0.014 + 0.012 * flash, flashWhite, em: 2.6 * flash))
        }
        _ = fire
        return s
    }

    // ── FLAMETHROWER ── standard issue: brass body, red-enamel fuel tank slung
    // under the left, rubber feed hose, and the amber pilot flame always
    // burning at the nozzle (it grows when the trigger is down).
    static func flamethrower(fire: Float, flash: Float, time: Float) -> [GShape] {
        var s: [GShape] = []
        s.append(zcyl(SIMD3(0, 0, 0.0), r: 0.055, half: 0.16, edge: 0.010, steelGrey))          // body tube
        s.append(zcyl(SIMD3(0, 0, -0.06), r: 0.058, half: 0.008, edge: 0.004, copper))          // jacket bands
        s.append(zcyl(SIMD3(0, 0, 0.08), r: 0.058, half: 0.008, edge: 0.004, copper))
        s.append(ycyl(SIMD3(-0.02, -0.105, -0.06), r: 0.048, half: 0.065, edge: 0.010, redEnamel))  // fuel tank
        s.append(sph(SIMD3(-0.02, -0.035, -0.06), r: 0.020, darkSteel))                         // tank cap
        s.append(cone(SIMD3(-0.055, -0.08, -0.10), SIMD3(-0.02, -0.005, -0.155), 0.011, 0.011, rubber, k: 0.02))   // feed hose
        s.append(cone(SIMD3(0, 0.004, 0.16), SIMD3(0, 0.004, 0.31), 0.020, 0.014, darkSteel))   // nozzle pipe
        s.append(cone(SIMD3(0, 0.004, 0.31), SIMD3(0, 0.004, 0.355), 0.014, 0.030, steelGrey))  // nozzle bell
        s.append(zcyl(SIMD3(0, 0.004, 0.352), r: 0.032, half: 0.006, edge: 0.003, copper))      // pilot ring
        s.append(box(SIMD3(0, 0.078, 0.0), SIMD3(0.012, 0.010, 0.060), 0.005, darkSteel))       // carry handle
        s.append(box(SIMD3(0, 0.062, -0.05), SIMD3(0.010, 0.014, 0.010), 0.004, darkSteel))
        s.append(box(SIMD3(0, 0.062, 0.05), SIMD3(0.010, 0.014, 0.010), 0.004, darkSteel))
        s.append(box(SIMD3(0, -0.095, -0.14), SIMD3(0.024, 0.055, 0.028), 0.010, darkSteel))    // grip
        // the pilot flame: never out, flickering, roaring wider under fire
        let flick = 0.85 + 0.15 * sinf(time * 23) * sinf(time * 7.7 + 1.3)
        let roar = 1 + 1.6 * max(fire, flash)
        s.append(glow(SIMD3(0, 0.030, 0.365), r: 0.011 * (1 + 0.6 * max(fire, flash)), pilotAmber, em: 2.2 * flick * roar))
        return s
    }

    // ── ROCKET LAUNCHER ── the found heavy: one fat dark tube, a red safety
    // band, the loaded warhead peeking from the muzzle, and a red aim bead on
    // the sight rail.
    static func rocket(fire: Float, flash: Float) -> [GShape] {
        var s: [GShape] = []
        s.append(zcyl(SIMD3(0, 0.01, 0.03), r: 0.058, half: 0.23, edge: 0.010, armyGreen))      // main tube
        s.append(zcyl(SIMD3(0, 0.01, 0.265), r: 0.048, half: 0.012, edge: 0.004, nearBlack))    // muzzle counterbore
        s.append(cone(SIMD3(0, 0.01, 0.26), SIMD3(0, 0.01, 0.315), 0.030, 0.004, redEnamel))    // the loaded warhead
        s.append(zcyl(SIMD3(0, 0.01, 0.20), r: 0.062, half: 0.010, edge: 0.004, redEnamel))     // safety band
        s.append(zcyl(SIMD3(0, 0.01, -0.12), r: 0.061, half: 0.008, edge: 0.004, copper))       // copper joint ring
        s.append(cone(SIMD3(0, 0.01, -0.20), SIMD3(0, 0.01, -0.26), 0.052, 0.066, nearBlack))   // rear exhaust flare
        s.append(box(SIMD3(0, 0.082, 0.05), SIMD3(0.012, 0.008, 0.090), 0.005, armyGreen))      // sight rail
        s.append(box(SIMD3(0, 0.098, 0.115), SIMD3(0.006, 0.010, 0.006), 0.003, darkSteel))     // sight post
        s.append(glow(SIMD3(0, 0.114, 0.115), r: 0.005, SIMD3(1.0, 0.20, 0.12), em: 1.6))       // aim bead
        s.append(box(SIMD3(0, -0.085, 0.02), SIMD3(0.026, 0.058, 0.030), 0.010, darkSteel))     // grip
        s.append(box(SIMD3(0, -0.02, -0.235), SIMD3(0.030, 0.055, 0.020), 0.010, armyGreen))    // shoulder rest
        if flash > 0 {
            s.append(glow(SIMD3(0, 0.01, 0.34 + 0.02 * flash), r: 0.020 + 0.018 * flash, flashOrange, em: 2.4 * flash))
        }
        _ = fire
        return s
    }

    // ── per-frame packing ── builds the held weapon in gun-local space, then
    // moves the whole gun by bob / recoil / switch-lower INSIDE that space
    // (the anchor stays fixed relative to the eye, like a held weapon does).
    // Returns the shapes plus a conservative local bounding sphere for the
    // kernel's ray gate.
    static let anchorFwd: Float = 0.50     // gun anchor, metres ahead of the eye…
    static let anchorRight: Float = 0.0    // …dead-centre, Doom-style (the marine shoots from the shoulder line)…
    static let anchorDown: Float = 0.25    // …and below the eye line

    static func pack(player p: Player, time: Float) -> (shapes: [GShape], boundC: SIMD3<Float>, boundR: Float) {
        let def = p.current.def
        let fireN = def.interval > 0 ? p.fireAnim / min(0.2, def.interval * 0.6) : 0
        let flashN = p.muzzle / 0.07
        var shapes: [GShape]
        switch p.current {
        case .plasma:
            let charge = min(1, Float(p.ammo[AmmoType.cells.rawValue]) / Float(Player.issueCells))
            shapes = plasma(fire: fireN, flash: flashN, charge: charge, time: time)
        case .flamethrower: shapes = flamethrower(fire: fireN, flash: flashN, time: time)
        case .rocket:       shapes = rocket(fire: fireN, flash: flashN)
        }
        // held-weapon motion, all in gun-local units: walk bob sways right/up,
        // recoil kicks the gun back along its own barrel, a switch drops it
        let bobX = sinf(p.bobPhase) * 0.010 * p.bob
        let bobY = -abs(sinf(p.bobPhase * 2)) * 0.008 * p.bob
        let lower = -(p.switchAnim / 0.18) * 0.20
        let kick = -0.035 * fireN
        let dm = SIMD3<Float>(bobX, bobY + lower, kick)
        var boundC = SIMD3<Float>(0, 0, 0)
        for i in shapes.indices {
            shapes[i].a.x += dm.x; shapes[i].a.y += dm.y; shapes[i].a.z += dm.z
            if shapes[i].b.w >= 0 {                       // cones carry a second endpoint
                shapes[i].b.x += dm.x; shapes[i].b.y += dm.y; shapes[i].b.z += dm.z
            }
            boundC += SIMD3(shapes[i].a.x, shapes[i].a.y, shapes[i].a.z)
        }
        boundC /= Float(shapes.count)
        var boundR: Float = 0
        for sh in shapes {
            let c = SIMD3(sh.a.x, sh.a.y, sh.a.z)
            let d = simd_length(c - boundC)
            switch sh.b.w {
            case ..<(-4.5): boundR = max(boundR, d + sh.a.w)                                    // glow sphere
            case ..<(-2.5): boundR = max(boundR, d + sqrtf(sh.a.w * sh.a.w + sh.b.y * sh.b.y))  // cylinders
            case ..<(-1.5): boundR = max(boundR, d + simd_length(SIMD3(sh.b.x, sh.b.y, sh.b.z)) + sh.a.w)   // box
            case ..<0:      boundR = max(boundR, d + sh.a.w)                                    // sphere
            default:                                                                            // cone: both ends
                boundR = max(boundR, d + sh.a.w)
                boundR = max(boundR, simd_length(SIMD3(sh.b.x, sh.b.y, sh.b.z) - boundC) + sh.b.w)
            }
        }
        return (shapes, boundC, boundR + 0.02)
    }
}
