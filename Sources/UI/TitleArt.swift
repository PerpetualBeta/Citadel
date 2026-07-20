// Citadel — animated title-screen backdrop.
//
// The Giger-xenomorph hero plate (amber rim-lit on black), given cinematic life
// by CinematicPlate: a slow push-in that settles into the hero framing over ~5s,
// then holds, under a continuous projector flicker + film grain + scratches.
// Citadel's ONE title image asset — everything else is generated in code (audio
// is the other deliberate exception; see CREDITS.md).

import Cocoa

enum TitleArt {
    private static let plate: CinematicPlate? = CinematicPlate(resource: "title_bg")
    static var available: Bool { plate != nil }

    static func draw(_ c: Canvas2D, t: Float) {
        guard let plate = plate else { c.fillRect(0, 0, RenderConfig.width, RenderConfig.height, packRGBA(6, 5, 4)); return }
        // full plate → tighter hero over 5s, centred in the slack, then fixed.
        plate.draw(c, t: t, restX: 0.5, restY: 0.5, settleT: 5.0, zoomStart: 1.06, zoomRest: 0.94)
    }
}
