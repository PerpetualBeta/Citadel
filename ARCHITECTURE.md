# Citadel — Architecture

The world is drawn by a real-time **Metal rasteriser**. `LevelMeshBuilder.swift` turns
each generated floor into vertex buffers **once at load** — walls, floors, ceilings,
double-height rooms and their closing soffits, the wall-routed pipework and steelwork,
and the solid objects (fuel drums, recharge panels, deployed mines, floor pickups,
furniture, machinery) — and `RasterRenderer.swift` + `RasterShaders.swift` draw it:
procedural materials shaded in the fragment stage, lit by the level's own fixtures plus
the marine's headlamp, accumulated in **HDR with bloom** and tonemapped into a low-res
view.

**An SDF raymarcher drew the world until 2026-07.** A Metal compute kernel sphere-traced
a distance field, and it was retired once the raster path both looked better and cost
less: the 1,700-line kernel and its `GPUWorldRenderer` were deleted, and there is now
exactly one renderer with no toggle and no fallback. `GPURaymarch.swift` survives under a
misleading name as the home of shared types the kernel used to own (light structs,
furniture footprints, fire emitters).

The **creatures are 3-D meshes** (`MeshCreature.swift` — the DRONE, the QUEEN and the
colonists, USDZ geometry with baked base-colour maps, posed by `HumanoidRig.swift` where
they are rigged). They join the caller's command buffer and draw against a **shared depth
buffer**, so creature-vs-creature ordering falls out of the z-test exactly rather than out
of the order groups happened to be merged in. **Fire and particles run on the GPU** too;
`SpriteCompositor.swift` remains for the few CPU billboards.

The HUD and front-end screens are drawn into a software 2-D canvas (`Canvas2D.swift` —
primitives plus cached Core Text labels), composited over the world view, then
blit-upscaled nearest-neighbour, aspect-correct and letterboxed, to the drawable
(`Renderer.swift`).

Almost everything **visual** is generated in code — architecture and materials are all
maths, and levels come from a seeded generator whose solvability is verified. **Four**
deliberate exceptions earn their place, and they are the only asset files in the bundle:
the creature and colonist **meshes with their baked base-colour maps** (organic anatomy
reads better sculpted than generated — so this codebase does ship textures, and copy must
not claim otherwise); **three cinematic hero plates** (`CinematicPlate.swift`); **five
imported prop models, geometry only** — re-materialled in code, so the shapes are borrowed
and the surfaces are ours; and **audio** — a curated set of CC0 / CC-BY samples plus a
reactive ambient bed (`AudioEngine.swift`), with a from-scratch synthesiser kept only as a
fallback for a missing sample. See [CREDITS.md](CREDITS.md).

## Source map

| File | Role |
|------|------|
| **App** | |
| `main.swift` | Entry point; the `CITADEL_*` harness dispatch (all force-muted) or GUI launch |
| `AppDelegate.swift` | Maximised window, menu bar (incl. Save/Load ⌘S/⌘O), About, Sparkle focus-guard |
| `GameView.swift` | `MTKView` subclass; keyboard capture + rebinding, mouse-look, name entry |
| `Renderer.swift` | Game-state machine, frame loop, faded transitions, compositing + present/blit |
| `InputState.swift` / `Gamepad.swift` | Effective input (keyboard OR'd with gamepad); controller polling + action map |
| `GameSettings.swift` / `FeatureFlags.swift` | UserDefaults settings; hidden `defaults write` cheats + strip switches |
| `KeyboardSheet.swift` / `ControllerSheet.swift` / `OptionsSheet.swift` | Config sheets |
| **Game** | |
| `MapGen.swift` | Procedural generation + keyed-BFS solvability, room types, the survivor cast |
| `GameMap.swift` | The cell grid: doors, flats, light, hazard, pipe routing, ceiling height, room-effect cells |
| `World.swift` | The live world: movement, firing, combat, AI, pickups, room effects, level flow |
| `Player.swift` / `Monster.swift` | Vitals / arsenal / keys; the two castes + AI states + drawn position |
| `Weapon.swift` / `Projectile.swift` / `Item.swift` / `Prop.swift` | Weapon, projectile, pickup and furniture tables |
| `Progression.swift` | Campaign structure — 6 citadels × 8 floors, material tiers, the survivor deal |
| `SaveGame.swift` | Ten named save slots; the checkpoint model (a seed, not a world) |
| `HighScores.swift` | Persistent Hall of the Fallen (name / score / depth / colony) |
| `EasterEggs.swift` / `SpaceInvaders.swift` | Terminal documents; the playable CRT mini-game |
| `Rng.swift` | Deterministic SplitMix64 RNG |
| **Render** | |
| `RasterRenderer.swift` | **The renderer:** pipelines, per-level resources, the frame |
| `RasterShaders.swift` | Its Metal shader sources (surface shading, HDR, bloom, grade) |
| `LevelMeshBuilder.swift` / `MeshEmit.swift` | Floor → vertex buffers at load; the geometry emitters |
| `MeshCreature.swift` / `HumanoidRig.swift` | Mesh creatures (drone, queen, colonists); rig posing + bake |
| `Viewmodel.swift` / `Sprites.swift` / `Mesh3D.swift` | Held-weapon models; procedural shape/primitive builders |
| `Textures.swift` | Procedural tileable wall + flat materials |
| `Lighting.swift` / `WorldLight.swift` | Fixture point-lights; per-cell light/colour fields + headlamp |
| `SpriteCompositor.swift` | The remaining CPU billboards over the GPU view |
| `Canvas2D.swift` / `Pixel.swift` | Software 2-D canvas (primitives + Core Text); packed-RGBA helpers |
| `ItemIcons.swift` / `StaticFX.swift` | Pickup icons; the teleport static dissolve |
| `GPURaymarch.swift` | **Misnamed survivor:** shared types the retired SDF kernel used to own |
| **UI** | |
| `Codex.swift` | Front-end screens (title, briefing, intel, teleport, coda, tally, scores, pause) |
| `HUD.swift` | Visor HUD — motion tracker + objective caret, vitals / weapon pods, message ticker |
| `TitleArt.swift` / `HallArt.swift` / `EndingArt.swift` | The three hero-plate screens and their motion |
| `CinematicPlate.swift` | The shared plate engine: Ken-Burns push, bulb flicker, grain, scratches |
| `Automap.swift` / `Automap3D.swift` | Full-screen automap; free-orbit 3-D render of the explored level |
| `MeshPortraits.swift` | FIELD INTEL dossier portraits, rendered from the creature meshes |
| `Terminal.swift` | The amber-CRT terminal frame |
| `Font.swift` / `TextImage.swift` | Bitmap font / Core Text rasteriser (mono + proportional, any Unicode) |
| **Audio** | |
| `AudioEngine.swift` | Sampled SFX, looping stems, reactive bed, the ceremony's crowd; synth fallback |
| **Harness** (headless, never in a signed build) | |
| `SmokeTest.swift` | The suite: generation, solvability, combat, saves, determinism fingerprint |
| `RasterShot.swift` | ~65 frames covering every environment feature — the shotcheck input |
| `Captures.swift` / `RoomShots.swift` / `MaterialPreview.swift` / `ProofRoom.swift` | Screenshot + room / material / proof captures |
| `AudioProbe.swift` | Offline audio-graph render; per-path RMS + the mix asserted as ratios |
| `SettleProbe.swift` | Sweeps the mesh-settle solver's inputs; asserts a drawn body never teleports |
| `GPUProbe.swift` / `CreatureMergeProbe.swift` / `QueenMeshTest.swift` / `RigProbe.swift` | Frame-cost and mesh/rig probes |
| `generate_icon.swift` | Build-time app-icon generator (not compiled in) |

## The renderer, briefly

**At load,** `LevelMeshBuilder` walks the cell grid and emits one vertex array per pass:
the shell (walls / floors / ceilings, with soffits closing the step where a double-height
room meets a normal-height neighbour), the wall-routed pipework and its fittings, and the
solid objects. Materials are **procedural** — `Textures.swift` builds tileable wall and
flat materials, and the fragment stage adds the per-surface weathering (rust, oil film,
settled dust, grime, seepage). Static geometry is baked once per floor, not re-tessellated
per frame; only genuinely dynamic props go through the per-frame buffer.

**Per frame,** the shell and props are drawn into an HDR target, lit by the level's fixture
point-lights plus the headlamp, with the environment term weighted by the reflection
vector so a floor's light cannot land on the top of a barrel. Bloom is extracted and
composited, the result tonemapped and graded, and the creatures, fire and particles are
drawn into the same buffer against the shared depth. Read-backs are down to one.

**Bloom is separated by ORIGIN, not by brightness.** The held weapon shares the screen with
the room behind it, so a single blurred glow layer either lets the floor's light wash over
the gun or forbids the gun's own emitters from glowing at all. The bright pass therefore
writes the *viewmodel's share* of each bright pixel into the alpha channel; the blur carries
that share along with the colour, and the composite reconstructs it to allow the gun's own
bloom everywhere while still blocking the world's over the gun. Same passes, same textures —
the origin rides in a channel that was already there.

**Solid furniture, drums and machinery carry lightweight CPU collider boxes** so neither
the player nor the swarm walks through them — pure CPU, no cost to the render. Creature
meshes are far larger than a collision radius, so before drawing, each creature's whole
mesh is settled clear of walls and furniture; that settled position is the **sim's**
(`Monster.drawnPos`), and every aim and hit test uses it, because the body you can see has
to be the body you can hit.

**That settling is stored as an OFFSET, and rate-limited.** The solver behind it is not
continuous — it is iterative on a fixed budget, it picks the strongest violation each round
(an argmax, which flips when two samples tie), and a door's open fraction crossing its pass
threshold flips a boolean it chooses a push direction from. Measured with
`CITADEL_SETTLEPROBE`: half a degree of turn could move the drawn body 0.37 m, and a door
opening beside a waiting drone moved it 0.39 m in the single frame the threshold was crossed
— a drone *appearing* in a doorway rather than walking into one. Making the solver continuous
case by case is whack-a-mole; capping how fast the correction may travel is not, and it covers
the next such flip too. The cap is the creature's **own speed**, because a body drawn moving
faster than it could move has stopped reading as movement. Keeping the correction as an offset
rather than an absolute position is what lets it ride along with the walk, so only the
correction is ever a frame behind and never the body itself.

A cap bounds how far the correction moves but not how often it *reverses*, and the solver's
facing input used to swing as fast as the marine could move, so it answered by alternating
between competing solutions — a shimmer rather than a slide. So the correction also **holds once
it is within one frame's travel** of the answer. That band needs no constant of its own: it is the slew limit, on the grounds that a
target closer than one frame cannot be reached in less than a frame, so chasing it yields a
twitch and a twitch back. It also makes the approach strictly monotonic — slew toward, stop on
arrival, never overshoot — so oscillation has no mechanism left. The body then sits up to ~2.6 cm
from the solver's answer, against a ~39 cm footprint radius, which cannot lap the mesh back into
a wall. `CITADEL_SETTLEPROBE` walks a player past a waiting drone and counts direction
reversals; the pass condition is none.

**Facing is rate-limited at the source as well.** A creature's `dir` was assigned straight to the
bearing of the marine, so its whole mesh yawed as fast as he could move — a long snout swinging
between frames, which reads as a twitch at the neck rather than a head turn, and which fed the
settle solver an input that could jump. It now turns at `MonsterDef.turnRate`, **derived** from
the creature's own speed and radius on the rule that a body reorients in about the time it takes
to cover its own length: 349°/s for a drone, 37°/s for the Queen, who is meant to be
out-manoeuvrable. Nothing about the hunt changes, and the smoke suite pins why — a drone's rate
still exceeds the angular rate a *sprinting* marine subtends at biting range, and neither caste's
attacks depend on facing (melee is distance plus a clear line).

## Audio levels

**Two sounds carry information in their loudness,** so for them a level is data rather than
taste: a spark shower's volume is how far away its panel is, and the far Signal's is how deep
into a citadel you have gone. Both were wrong, in ways only a measurement could show.
`AVAudioPlayerNode.volume` is not dependable here — a node ignores the volume set on it for the
**first** buffer it ever renders, and through the shared one-shot pool a quarter of a fault's
distance attenuation still came out at 96% of full level *at an identical peak*. Every fault in
the game therefore arrived at the same loudness whatever its distance, and three separate
commits that "quietened the electrical fault" by trimming the gain table changed nothing that
could be heard. The spark voices now multiply their level into **their own scratch copy of the
sample** and leave node volume at 1 for ever, so the level is arithmetic this codebase owns. The
far Signal's trim was declared in the table and then never applied, which let the bleed play at
**full scale** on the bottom floor of every citadel; it is applied where the depth ramp is.

`AudioProbe.swift` (`CITADEL_AUDIOPROBE=1`) renders the real graph offline and asserts the mix in
**relative** terms — the calm room tone as the reference, the plant hum and a weapon shot as the
two ceilings — because every level in it was specified as a comparison and not as a number. It
also sweeps a fault's attenuation and fires the same shower repeatedly, which is what caught both
faults above. Change a trim, re-run it.

## The descent is a gradient

The plant floors at the bottom of each citadel are the payoff — raw rock, machine halls twice a
storey, standing water, bulkhead light. The risk with a payoff is announcing it: for a while
several of its ingredients switched on in **one step** at floor 7, so a citadel read as two
places rather than one you descend through. Three of them now ramp toward it instead, and each
ramp ends exactly where the plant's own value begins so the two can never disagree:

- **Headroom.** Every room on the plant floors stands twice a storey. Above them the share of
  raised rooms ramps — one chamber on the surface, most of them by the deep workings — biggest
  rooms first, since a big room is what wants the height. Only room interiors rise, so a doorway
  keeps its own height and a door still fills its frame; the soffit closing the step is most of
  what the height is *for*.
- **The plant heard through the deck.** `driveMachineHum` fades the compressors in linearly from
  silence at the surface to the plant's own between-halls level as you arrive at it — the same
  shape `Progression.farSignalRamp` gives THE SIGNAL, so the two things bleeding up from below
  rise together. The whole ramp lives in about two decibels: standing between halls on a plant
  floor measures only ~+2 dB over the calm room tone, and that ceiling is deliberately the
  endpoint, because a floor *above* the plant must never sound noisier than the plant.
- **Failed light runs.** A strip light that has died is simply not placed — the cell takes the
  theme's plain wall — so it casts no light and emits nothing, because both the point-light pass
  and the shader's self-illumination key off the wall id. This corrects a real inconsistency: a
  "busted" fixture used to spark while still glowing and still lighting the room. Only the
  **surface facility** has strip lights (`theme()` puts `.litPanel` in the 1–2 palette and nothing
  below), so only it can lose them — the descent already works by taking the lighting away, and
  this sharpens its top end rather than duplicating its bottom.

Each of the three is asserted in the smoke suite as a **trend across floors**, not as a value on
any one floor, because a single floor's room count is a roll of the dice.

## Determinism

A floor is a pure function of its seed, and that is load-bearing in three places: the shot
harness pins layouts, the smoke suite sweeps hundreds of floors, and a **save stores a seed
rather than a world**. Swift seeds its hashing **per process**, so any decision that rides
the iteration order of a `Set` or `Dictionary` silently differs run to run — which really
happened, and put two shot frames in quarantine for days. Order every such iteration
explicitly, and keep the total ordering *total*: sorting on a key that ties leaves the
tie-break to the arriving order. `CITADEL_SMOKE` prints a per-field generation fingerprint
(`GENHASH`) for comparing across processes.
