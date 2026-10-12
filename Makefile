# Citadel — first-person retro shooter (a Doom tribute), set in the Strataris
# universe. The SECOND native game in the Jorvik suite (after Strataris).
#
# Built with swiftc + Metal. The renderer is a forward RASTERISER: real triangle
# geometry with PBR shading, shadow-mapped ceiling lamps, an HDR pipeline (bloom /
# ACES / vignette) and the animated creature meshes drawn straight into the frame.
# Particles are GPU billboards. Nothing composites on the CPU any more — the frame
# makes ONE GPU->CPU transfer, the finished image.
#
# It replaced a GPU SDF raymarcher on 2026-07-29; the shape library that path
# defined lives on in Sources/Render/GPURaymarch.swift, which the rasteriser uses
# for all its prop geometry.
#
# Graphics are generated in code, with deliberate exceptions: the creature meshes
# (Resources/*.usdz), the title/Hall hero plates, and AUDIO — Citadel ships real
# open-source sample assets (Resources/Audio/, see CREDITS.md + docs/audio-
# sourcing.md), the atmosphere leaning too hard on sound to synthesise. The
# from-scratch synth in AudioEngine.swift remains a per-event fallback.
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

# APPLE SILICON ONLY — the one Jorvik target that is not universal, and deliberately so.
# Citadel is a real-time Metal renderer tuned to a 16.7 ms frame budget, and every measurement
# behind that tuning (the frame-cost probe, the 68-frame shot baseline, the smoke suite) was taken
# on Apple silicon. The x86_64 slice would have shipped never having been executed on the hardware
# it targets, and its failure mode is bad: shaders compile at first dispatch, so a construct an
# Intel/AMD Metal compiler rejects fails at RUNTIME, `RasterRenderer.init?` returns nil, and the
# player gets a permanently black world rather than a refusal to launch. An honest requirement
# beats an untested slice. Must be set BEFORE the include below; see release.mk's ARCH_LIST.
ARCH_LIST        := arm64

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
                    Sources/JorvikKit/JorvikAboutView.swift \
                    Sources/JorvikKit/JorvikWindowHelper.swift \
                    Sources/JorvikKit/JorvikLocalization.swift \
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
                    Sources/Game/EasterEggs.swift \
                    Sources/Game/SpaceInvaders.swift \
                    Sources/Game/Item.swift \
                    Sources/Game/Prop.swift \
                    Sources/Game/Projectile.swift \
                    Sources/Game/HighScores.swift \
                    Sources/Game/SaveGame.swift \
                    Sources/Game/Rng.swift \
                    Sources/Render/GPURaymarch.swift \
                    Sources/Render/RasterRenderer.swift \
                    Sources/Render/RasterShaders.swift \
                    Sources/Render/MeshEmit.swift \
                    Sources/Render/LevelMeshBuilder.swift \
                    Sources/Render/Canvas2D.swift \
                    Sources/Render/Pixel.swift \
                    Sources/Render/Textures.swift \
                    Sources/Render/Lighting.swift \
                    Sources/Render/WorldLight.swift \
                    Sources/Render/SpriteCompositor.swift \
                    Sources/Render/Sprites.swift \
                    Sources/Render/Mesh3D.swift \
                    Sources/Render/ItemIcons.swift \
                    Sources/Render/MeshCreature.swift \
                    Sources/Render/HumanoidRig.swift \
                    Sources/Render/StaticFX.swift \
                    Sources/Render/Viewmodel.swift \
                    Sources/UI/HUD.swift \
                    Sources/UI/Codex.swift \
                    Sources/UI/TitleArt.swift \
                    Sources/UI/CinematicPlate.swift \
                    Sources/UI/HallArt.swift \
                    Sources/UI/EndingArt.swift \
                    Sources/UI/MeshPortraits.swift \
                    Sources/UI/Terminal.swift \
                    Sources/UI/Automap.swift \
                    Sources/UI/Automap3D.swift \
                    Sources/UI/Font.swift \
                    Sources/UI/TextImage.swift \
                    Sources/Audio/AudioEngine.swift \
                    Sources/Harness/SmokeTest.swift \
                    Sources/Harness/AudioProbe.swift \
                    Sources/Harness/Captures.swift \
                    Sources/Harness/RoomShots.swift \
                    Sources/Harness/MaterialPreview.swift \
                    Sources/Harness/QueenMeshTest.swift \
                    Sources/Harness/RigProbe.swift \
                    Sources/Harness/ProofRoom.swift \
                    Sources/Harness/RasterShot.swift \
                    Sources/Harness/CreatureMergeProbe.swift \
                    Sources/Harness/SettleProbe.swift \
                    Sources/Harness/GPUProbe.swift

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

# ── SHIPPING-CONFIGURATION COMPILE CHECK ──────────────────────────────────────
# `gmake build` compiles the DEV configuration: ad-hoc SIGN_ID "-" keeps
# CITADEL_HARNESS defined, so the whole test/capture surface comes along. A signed
# release strips it — a genuinely different program, and for months it was one
# nobody had ever compiled. The first attempt at 1.0.0 failed at the compiler on
# three separate harness-only symbols reachable from shipping code, after a full
# build-sign-notarise round trip had already been paid for.
#
# This target compiles that configuration in seconds and needs NO credentials: the
# define is gated purely on SIGN_ID being the ad-hoc "-", so any other value is
# enough to strip it. Outputs go to their own directory so a shipcheck never
# leaves a harness-less binary in .build for the smoke suite to trip over.
#
# Run it before every release, and after touching anything under Sources/Harness.
.PHONY: shipcheck
shipcheck:
	@$(MAKE) --no-print-directory build \
	    SIGN_ID="shipcheck-not-a-real-identity" \
	    OUT_DIR="$(CURDIR)/.build-shipcheck"
	@echo "✅ shipcheck: the SHIPPING configuration compiles (CITADEL_HARNESS undefined)"
