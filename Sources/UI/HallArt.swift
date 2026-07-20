// Citadel — Hall of the Fallen backdrop.
//
// Mirrors the title screen: the gold-and-black drone concept plate given the same
// cinematic life (CinematicPlate — push/flicker/grain/scratches). The art is
// composed with the creature on the right and its dark negative space on the left,
// so the score table lives in that left space (see Codex.highScores).

import Cocoa

enum HallArt {
    private static let plate: CinematicPlate? = CinematicPlate(resource: "highscore_bg")
    static var available: Bool { plate != nil }

    static func draw(_ c: Canvas2D, t: Float) {
        guard let plate = plate else { c.fillRect(0, 0, RenderConfig.width, RenderConfig.height, packRGBA(6, 5, 4)); return }
        // a gentle, slow push so the beast reads as a live scene, centred so its dark
        // left flank stays clear for the scoreboard.
        plate.draw(c, t: t, restX: 0.5, restY: 0.5, settleT: 7.0, zoomStart: 1.05, zoomRest: 0.98)
    }
}
