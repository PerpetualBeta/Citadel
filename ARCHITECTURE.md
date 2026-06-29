# Citadel — Architecture

The world is drawn by a real-time **GPU signed-distance-field raymarcher**. A
Metal compute kernel (`GPURaymarch.swift`) sphere-traces, per pixel, a scene
distance field that is the level architecture — walls/floors/ceilings built into
a distance-field texture, with wall-baked pipework and steelwork — `min`'d with
**native SDF creatures and objects** (the drones and the Queen, fuel drums,
recharge panels, deployed mines). Surface normals come from the field gradient;
the scene is lit by the level's fixtures plus the marine's headlamp, ambient-
occluded and colour-graded into an HDR view that's tonemapped to a view texture.
`GPUWorldRenderer.swift` owns the per-level GPU resources (the distance-field +
light + material-id textures, the creature/object packing) and the per-frame
cull and dispatch. Only **particles** remain 2-D billboards, composited by
`SpriteCompositor.swift`.

The HUD and front-end screens are drawn into a software 2-D canvas
(`Canvas2D.swift` — primitives plus cached Core Text labels), composited over the
raymarched view, then blit-upscaled nearest-neighbour, aspect-correct and
letterboxed, to the drawable (`Renderer.swift`).

Everything **visual** is generated in code — architecture, materials and
creatures are all maths; levels come from a seeded generator whose solvability is
verified. The one deliberate exception is **audio**: a small curated set of
CC0 / CC-BY samples plus a reactive ambient bed (`AudioEngine.swift`), with a
from-scratch synthesiser kept only as a fallback for any missing sample.

## Source map

| File | Role |
|------|------|
| `main.swift` | Entry point; `CITADEL_SMOKE` / `CITADEL_SHOTS` / other harnesses / GUI launch |
| `AppDelegate.swift` | Maximised window, menu bar, About, Sparkle focus-guard, input wiring |
| `GameView.swift` | `MTKView` subclass; keyboard capture + rebinding, mouse-look, name entry |
| `Renderer.swift` | Game-state machine, frame loop, compositing + Metal present/blit |
| `GPURaymarch.swift` | The Metal SDF raymarch kernel + scene/creature/object field builders |
| `GPUWorldRenderer.swift` | Per-level GPU resources, per-frame culling + dispatch |
| `SpriteCompositor.swift` | Remaining 2-D billboards (particles) over the GPU view |
| `Lighting.swift` / `WorldLight.swift` | Fixture point-lights + per-cell light/colour fields |
| `Canvas2D.swift` | Software 2-D canvas (primitives + Core Text labels) for HUD / menus |
| `Pixel.swift` | Packed-RGBA helpers (pack / shade / mix) |
| `Textures.swift` | Procedural tileable wall & flat materials (fed to the GPU as arrays) |
| `CreatureLab.swift` / `MonsterBake.swift` / `Mesh3D.swift` | SDF creature authoring + bake |
| `Sprites.swift` | Weapon viewmodels + the enemy-intel creature render |
| `Prop.swift` | Furniture / fixture kinds (set-dressing, solid colliders) |
| `GameMap.swift` | The cell grid: doors (sliding + locked), flats, light, hazard, pipe routing |
| `MapGen.swift` | Procedural level generation + keyed-BFS solvability verification |
| `World.swift` | The live world: movement, firing, combat, AI, pickups, level flow |
| `Player.swift` | Position / vitals / arsenal / ammo / keys + view feedback state |
| `Monster.swift` | The two castes (DRONE, QUEEN), stat table, instance + AI states |
| `Weapon.swift` | Weapon definitions (plasma / flamethrower / rocket; ammo, spread, rate) |
| `Projectile.swift` | Projectile kinds (speed, splash) + instance |
| `Item.swift` | Pickup kinds + floor instance |
| `HUD.swift` | Weapon viewmodel, flashes, message ticker, status bar + objective compass |
| `Automap.swift` | Full-screen automap overlay |
| `Codex.swift` | Front-end screens (title, briefing, intel, cleared, teleport, game over, scores, pause) |
| `AudioEngine.swift` | Sampled SFX + reactive ambient bed (CC0/CC-BY), synth fallback |
| `InputState.swift` | Effective input (keyboard OR'd with gamepad) + mouse turn |
| `Gamepad.swift` | Controller polling + rebindable action map |
| `GameSettings.swift` | UserDefaults-backed settings (volumes, sensitivity, binds) |
| `FeatureFlags.swift` | Hidden `defaults write` cheats / test flags |
| `HighScores.swift` | Persistent high-score table (name / score / depth / colony) |
| `Progression.swift` | Campaign structure — planets, floors, flooding, material tiers |
| `Font.swift` / `TextImage.swift` | Bitmap font / Core Text rasteriser (mono + proportional, any Unicode) |
| `Rng.swift` | Deterministic SplitMix64 RNG |
| `KeyboardSheet.swift` / `ControllerSheet.swift` / `OptionsSheet.swift` | Config sheets |
| `SmokeTest.swift` | Headless logic / render / persistence checks |
| `Captures.swift` / `RoomShots.swift` | Headless screenshot + furnished-room capture harnesses |
| `generate_icon.swift` | Build-time app-icon generator (not compiled in) |

## The raymarcher, briefly

Each pixel sphere-traces `sceneSDF = gridSDF min creatureField`. `gridSDF`
reconstructs the level from a distance-field texture (bilinearly sampled, so
walls/floors/ceilings come back as smooth surfaces) and folds in the wall-baked
pipework via a routing mask carried in the field's second channel; sliding doors
are thin panels in the same field. `creatureField` evaluates the packed SDF
shapes of the nearby drones, the Queen, and the solid objects, each tagged with a
**material id** (creature · pickup · projectile · furniture · drum · socket ·
mine) that selects its shading. Normals come from the field gradient; lighting is
the level's fixture point-lights plus the headlamp, with cheap AO and contact
shadows, accumulated in HDR and tonemapped. Solid furniture and drums also carry
lightweight CPU collider boxes so the player and the swarm can't walk through
them — pure CPU, no cost to the render.
