// Citadel — input state.
//
// Two independent sources — keyboard (`kb`, set by the view on key events) and
// gamepad (`gp`, refreshed each frame by Gamepad.poll). The game reads the
// effective flags, which are the OR of the two, so either device works and
// neither clobbers the other on release. Mouse turn is a per-frame delta the
// view accumulates and the renderer drains.

import Foundation

final class InputState {
    struct Controls {
        var forward = false, back = false
        var strafeLeft = false, strafeRight = false
        var turnLeft = false, turnRight = false
        var run = false
        var fire = false
        var use = false
        var deployMine = false // drop a proximity mine at the marine's feet
        var weaponNext = false, weaponPrev = false
        var pause = false, restart = false, mute = false
        var map = false        // automap toggle (Tab / bindable pad button)
        var cancel = false     // Esc — close/return
        var briefing = false   // open the mission briefing from the title
        var intel = false      // open the enemy intel codex from the title
        var screenshot = false // feature flag: F (or gamepad) grabs a screenshot
    }

    var kb = Controls()      // keyboard source (view writes)
    var gp = Controls()      // gamepad source (Gamepad.poll writes)

    // Effective inputs read by the game.
    var forward: Bool     { kb.forward || gp.forward }
    var back: Bool        { kb.back || gp.back }
    var strafeLeft: Bool  { kb.strafeLeft || gp.strafeLeft }
    var strafeRight: Bool { kb.strafeRight || gp.strafeRight }
    var turnLeft: Bool    { kb.turnLeft || gp.turnLeft }
    var turnRight: Bool   { kb.turnRight || gp.turnRight }
    var run: Bool         { kb.run || gp.run }
    // Fire is latched on game start: the button/trigger used to START the game is
    // almost always still held on the first gameplay frame, which would otherwise
    // loose a shot the instant you spawn (you'd HEAR a weapon before you're even in
    // the room). While armed, fire reads false until it's physically released once.
    var fireArmRequired = false
    var fire: Bool {
        let raw = kb.fire || gp.fire
        if fireArmRequired { if !raw { fireArmRequired = false }; return false }
        return raw
    }
    var use: Bool         { kb.use || gp.use }
    var deployMine: Bool  { kb.deployMine || gp.deployMine }
    var weaponNext: Bool  { kb.weaponNext || gp.weaponNext }
    var weaponPrev: Bool  { kb.weaponPrev || gp.weaponPrev }
    var pause: Bool       { kb.pause || gp.pause }
    var restart: Bool     { kb.restart || gp.restart }
    var mute: Bool        { kb.mute || gp.mute }
    var map: Bool         { kb.map || gp.map }
    var esc: Bool         { kb.cancel || gp.cancel }
    var briefing: Bool    { kb.briefing || gp.briefing }
    var intel: Bool       { kb.intel || gp.intel }
    var screenshot: Bool  { kb.screenshot || gp.screenshot }

    // Analog movement from the gamepad left stick (-1…1). Keyboard sets the
    // discrete flags above; the renderer takes whichever magnitude is larger.
    var moveX: Float = 0    // strafe axis (gamepad)
    var moveY: Float = 0    // forward axis (gamepad)
    var lookX: Float = 0    // right-stick turn axis (gamepad)

    // Weapon digit select (keyboard 1–7); 0 = none. Edge-consumed by renderer.
    var weaponDigit = 0

    // Mouse turn — accumulated by the view, drained each frame by the renderer.
    var mouseTurn: Float = 0

    // High-score name entry (keyboard only).
    var nameEntryActive = false
    var nameBuffer = ""
    var nameCommitted = false

    /// Clear held movement/fire flags so a fresh game never starts mid-move or
    /// auto-firing because a key/stick was held through death/restart.
    func resetControls() {
        kb = Controls()
        gp = Controls()
        moveX = 0; moveY = 0; lookX = 0
        weaponDigit = 0
        mouseTurn = 0
        fireArmRequired = true   // require a fresh trigger pull before the first shot
    }

    /// Drain the accumulated mouse turn (returns it and resets to zero).
    func takeMouseTurn() -> Float {
        let t = mouseTurn
        mouseTurn = 0
        return t
    }
}
