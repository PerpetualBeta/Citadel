# Citadel — first-person retro shooter (a Doom tribute), set in the Strataris
# universe. The SECOND native game in the Jorvik suite (after Strataris).
#
# Built with swiftc + a runtime-compiled Metal blit shader; the world is a
# CPU raycaster (textured walls + floor/ceiling casting + billboarded sprites)
# rendered into a 320×200 framebuffer — Doom's native resolution — and upscaled
# nearest-neighbour, aspect-correct, for the period-correct pixelated look.
#
# Like Strataris, EVERYTHING is generated in code: no textures, no sprites,
# no audio files, no fonts, no models. The whole game is a few hundred KB.
#
# Release pipeline delegated to the shared `release.mk` from
# PerpetualBeta/jorvik-release.
#
# NAME NOTE: the product name lives in BUNDLE_NAME / PRODUCT_NAME / BUNDLE_ID
# below (+ the enclosing folder). Nothing in the Swift sources hard-codes it.

BUNDLE_NAME      := Citadel
BUNDLE_TYPE      := app
PRODUCT_NAME     := Citadel.app
BUNDLE_ID        := cc.jorviksoftware.Citadel
BUILD_SYSTEM     := swiftc

# MetalKit pulls in Metal; QuartzCore gives us CACurrentMediaTime for the
# frame clock; AVFoundation for the code synth; GameController for gamepads.
SWIFT_FRAMEWORKS := Cocoa Metal MetalKit QuartzCore AVFoundation GameController

SWIFT_SOURCES    := main.swift \
                    AppDelegate.swift \
                    GameView.swift \
                    Renderer.swift \
                    Canvas2D.swift \
                    Pixel.swift \
                    Font.swift \
                    TextImage.swift \
                    Rng.swift \
                    Textures.swift \
                    Sprites.swift \
                    Mesh3D.swift \
                    MonsterBake.swift \
                    GameMap.swift \
                    MapGen.swift \
                    Lighting.swift \
                    Raycaster.swift \
                    Player.swift \
                    Weapon.swift \
                    Monster.swift \
                    Item.swift \
                    Projectile.swift \
                    World.swift \
                    HUD.swift \
                    Codex.swift \
                    Automap.swift \
                    AudioEngine.swift \
                    InputState.swift \
                    Gamepad.swift \
                    GameSettings.swift \
                    FeatureFlags.swift \
                    HighScores.swift \
                    KeyboardSheet.swift \
                    ControllerSheet.swift \
                    OptionsSheet.swift \
                    SmokeTest.swift \
                    Captures.swift \
                    ArtPreview.swift \
                    CreatureLab.swift \
                    MaterialPreview.swift \
                    LightPreview.swift \
                    BeautyProof.swift \
                    GPURaymarch.swift

PACKAGE_TYPE     := zip
ALSO_SHIP_PKG    := true
EMBEDDED_FRAMEWORKS := Sparkle
# Hardened runtime must allow loading the embedded Sparkle framework + its
# helper apps (same convention as Strataris / SpaceMan / HawkEye / CopyLens).
ENTITLEMENTS     := Citadel.entitlements

include ../jorvik-release/release.mk
