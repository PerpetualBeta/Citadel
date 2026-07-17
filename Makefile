# Citadel — first-person retro shooter (a Doom tribute), set in the Strataris
# universe. The SECOND native game in the Jorvik suite (after Strataris).
#
# Built with swiftc + Metal. The shipping renderer is a GPU SDF raymarcher: a
# Metal compute kernel sphere-traces the level's distance field, floor/ceiling and
# native SDF creatures, grades the HDR result (bloom / ACES / teal-amber grade /
# vignette) and reads it back into a framebuffer; only billboard particles are
# composited over it on the CPU with per-pixel depth occlusion.
#
# Graphics are generated in code (no textures, sprites, fonts or models).
# AUDIO is the deliberate exception: Citadel ships real open-source sample
# assets (Resources/Audio/, see CREDITS.md + docs/audio-sourcing.md) — the
# atmosphere leans too hard on sound to synthesise. The from-scratch synth in
# AudioEngine.swift remains only as a per-event fallback for missing samples.
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

# Sources are grouped by seam under Sources/ (swiftc compiles them as one
# flat module, so the folders are pure organisation):
#   App      — process entry, window/view, frame loop, input, settings
#   Game     — simulation: world, mapgen, actors, weapons, progression
#   Render   — the GPU SDF raymarcher + canvas/texture/sprite machinery
#   UI       — visor HUD, front-end screens, automap, type
#   Audio    — the sample-bank engine (+ synth fallbacks)
#   Harness  — headless test/capture/proof tools (smoke, shots, labs)
SWIFT_SOURCES    := Sources/App/main.swift \
                    Sources/App/AppDelegate.swift \
                    Sources/App/GameView.swift \
                    Sources/App/Renderer.swift \
                    Sources/App/InputState.swift \
                    Sources/App/Gamepad.swift \
                    Sources/App/GameSettings.swift \
                    Sources/App/FeatureFlags.swift \
                    Sources/App/KeyboardSheet.swift \
                    Sources/App/ControllerSheet.swift \
                    Sources/App/OptionsSheet.swift \
                    Sources/Game/World.swift \
                    Sources/Game/MapGen.swift \
                    Sources/Game/GameMap.swift \
                    Sources/Game/Progression.swift \
                    Sources/Game/Player.swift \
                    Sources/Game/Weapon.swift \
                    Sources/Game/Monster.swift \
                    Sources/Game/Item.swift \
                    Sources/Game/Prop.swift \
                    Sources/Game/Projectile.swift \
                    Sources/Game/HighScores.swift \
                    Sources/Game/Rng.swift \
                    Sources/Render/GPURaymarch.swift \
                    Sources/Render/GPUWorldRenderer.swift \
                    Sources/Render/Canvas2D.swift \
                    Sources/Render/Pixel.swift \
                    Sources/Render/Textures.swift \
                    Sources/Render/Lighting.swift \
                    Sources/Render/WorldLight.swift \
                    Sources/Render/SpriteCompositor.swift \
                    Sources/Render/Sprites.swift \
                    Sources/Render/Mesh3D.swift \
                    Sources/Render/MonsterBake.swift \
                    Sources/Render/StaticFX.swift \
                    Sources/Render/Viewmodel.swift \
                    Sources/UI/HUD.swift \
                    Sources/UI/Codex.swift \
                    Sources/UI/TitleArt.swift \
                    Sources/UI/IntelPortraits.swift \
                    Sources/UI/Automap.swift \
                    Sources/UI/Font.swift \
                    Sources/UI/TextImage.swift \
                    Sources/Audio/AudioEngine.swift \
                    Sources/Harness/SmokeTest.swift \
                    Sources/Harness/AudioProbe.swift \
                    Sources/Harness/Captures.swift \
                    Sources/Harness/RoomShots.swift \
                    Sources/Harness/ArtPreview.swift \
                    Sources/Harness/CreatureLab.swift \
                    Sources/Harness/MaterialPreview.swift \
                    Sources/Harness/BeautyProof.swift

PACKAGE_TYPE     := zip
ALSO_SHIP_PKG    := true
EMBEDDED_FRAMEWORKS := Sparkle
# Entitlements are intentionally empty — Library Validation stays ON. The
# release pipeline (jorvik-release/helpers/sign-framework.sh) re-signs the
# embedded Sparkle framework + its XPC services / helpers with the Jorvik
# Developer ID (leaf-first), so all loaded code shares the app's Team ID and
# validates without com.apple.security.cs.disable-library-validation. See the
# comment in Citadel.entitlements for the pre-release signed-build check.
ENTITLEMENTS     := Citadel.entitlements

# Test/capture harness entry points (the CITADEL_* env dispatch in main.swift)
# compile into local / ad-hoc dev builds only; signed, notarised releases strip
# them, so a shipped Citadel ignores every CITADEL_* variable. See release.mk's
# DEV_ONLY_DEFINES / DEV_DEFINE_FLAGS (gated on the ad-hoc SIGN_ID "-").
DEV_ONLY_DEFINES := CITADEL_HARNESS

include ../jorvik-release/release.mk
