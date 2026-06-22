# Citadel — Architecture

The world is a textured **raycaster** (`Raycaster.swift`) drawn into a 320×200
packed-RGBA software framebuffer (`Canvas2D.swift`): per-row floor/ceiling
texture casting, per-column DDA walls with distance + sector-light shading and
slide-up doors, then billboarded, depth-sorted sprites tested against a
per-column wall z-buffer. The HUD and the front-end screens composite on top of
the same framebuffer. A runtime-compiled Metal blit shader (`Renderer.swift`)
uploads the framebuffer to a texture and upscales it nearest-neighbour,
aspect-correct and letterboxed, to the drawable — 320×200 is Doom's native mode,
so the chunky pixels are period-correct.

Everything is generated in code: textures and sprites from maths, audio from a
synthesiser, levels from a seeded generator whose solvability is verified.

## Source map

| File | Role |
|------|------|
| `main.swift` | Entry point; `CITADEL_SMOKE` / `CITADEL_SHOTS` harness / GUI launch |
| `AppDelegate.swift` | Maximised window, menu bar, About, Sparkle focus-guard, input wiring |
| `GameView.swift` | `MTKView` subclass; keyboard capture + rebinding, mouse-look, name entry |
| `Renderer.swift` | Game-state machine, frame loop, Metal present + blit shader |
| `Canvas2D.swift` | 320×200 packed-RGBA framebuffer + primitives + per-column z-buffer |
| `Pixel.swift` | Packed-RGBA helpers (pack / shade / mix) |
| `Raycaster.swift` | DDA walls, floor/ceiling casting, billboarded sprites + particles |
| `Textures.swift` | Procedural tileable wall & flat textures |
| `Sprites.swift` | Procedural monsters, items, weapon viewmodels, projectiles, HUD face |
| `GameMap.swift` | The cell grid, doors (slide-up + locked), flats, light, hazard |
| `MapGen.swift` | Procedural level generation + keyed-BFS solvability verification |
| `World.swift` | The live world: movement, firing, combat, AI, pickups, level flow |
| `Player.swift` | Position/vitals/arsenal/ammo/keys + view feedback state |
| `Monster.swift` | Enemy kinds, stat table, instance + AI states |
| `Weapon.swift` | Weapon definitions (hitscan / projectile, ammo, spread, rate) |
| `Projectile.swift` | Projectile kinds (speed, splash) + instance |
| `Item.swift` | Pickup kinds + floor instance |
| `HUD.swift` | Weapon viewmodel, screen flashes, message ticker, status bar + face |
| `Codex.swift` | Front-end screens (title, briefing, intel, cleared, game over, scores, pause) |
| `AudioEngine.swift` | Code synthesiser (music / SFX / ambient buses) + sequencer |
| `InputState.swift` | Effective input (keyboard OR'd with gamepad) + mouse turn |
| `Gamepad.swift` | Controller polling + rebindable action map |
| `GameSettings.swift` | UserDefaults-backed settings (volumes, sensitivity, binds) |
| `FeatureFlags.swift` | Hidden `defaults write` cheats / test flags |
| `HighScores.swift` | Persistent high-score table (name / score / depth / colony) |
| `Font.swift` / `TextImage.swift` | 5×7 bitmap font / Core Text rasteriser (unicode names) |
| `Rng.swift` | Deterministic SplitMix64 RNG |
| `KeyboardSheet.swift` / `ControllerSheet.swift` / `OptionsSheet.swift` | Config sheets |
| `SmokeTest.swift` | Headless logic / render / persistence checks |
| `Captures.swift` | Headless screenshot harness + the PNG writer |
| `generate_icon.swift` | Build-time app-icon generator (not compiled in) |

## The raycaster, briefly

For each screen column a ray is marched through the grid (DDA). Closed/partly
open doors are hit like walls but drawn sliding up (the top `open` fraction is
skipped, revealing the ceiling behind); a fully-open door is transparent and the
ray passes through. Floors and ceilings are cast per row — one perpendicular
distance per row, stepped horizontally across the screen — and textured from the
cell under each screen pixel. The per-column wall distance is stored in a
z-buffer so billboarded sprites (monsters, items, projectiles, particles), drawn
far-to-near, occlude correctly behind geometry.
