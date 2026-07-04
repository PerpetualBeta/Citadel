# Citadel

A first-person shooter for macOS — a *Doom* tribute set in the **Strataris**
universe. You held the skies over the colony cluster for as long as you could.
You didn't hold them long enough. The swarm landed, and the citadels of Demeter,
Tantalus, Boreas, Pandora, Vulcan and Vesper are occupied. Now you go in on foot
— clear each citadel floor by floor, put down the brood-queen that holds it, and
descend.

![Citadel title screen](docs/screenshots/01-title.png)

**The second *native* game in the Jorvik suite**, and the ground war of the
saga that opened with [Strataris](https://jorviksoftware.cc) — that was the air
war; this is the retake on foot.

## Rendered in code, in real time

Citadel ships **no textures, no sprites, no 3-D models and no level files**. The
world and everything in it is a real-time **GPU signed-distance-field
raymarcher** (a Metal compute kernel): the iron-and-steel architecture, the
wall-baked pipework and steelwork, the fuel drums and recharge panels, and the
**biomechanical aliens themselves** are all true 3-D SDF geometry, lit and
colour-graded on the GPU. The HUD and front-end screens are drawn into a
software 2-D canvas and composited on top, then upscaled aspect-correct and
letterboxed.

The one deliberate exception is **audio**. Citadel's atmosphere leans too hard on
sound to synthesise convincingly, so it ships a small, curated set of **CC0 /
CC-BY** samples — weapon fire, the aliens' voices, and a reactive ambient bed
that thickens as the swarm closes in — all credited in [CREDITS.md](CREDITS.md).
(A from-scratch synthesiser remains in the binary as a fallback for any missing
sample.)

Levels are **procedurally generated** and **verified solvable** with a keyed
flood-fill, so every floor is beatable: rooms and corridors, doors and
coloured-key locks, hidden secrets, hazard-walled fuel stores, and an exit you
have to earn.

## The game

You carry a **plasma rifle** and a **flamethrower** at all times, and find a
**rocket launcher** in the field. Ammo is finite — energy cells, pressurised
fuel and proximity mines — so every floor is a resource problem as much as a
fight.

- **The brood.** Two castes hunt you:
  - **DRONE** — a fast, grey-green melee pack-hunter. It comes in numbers and
    kills up close.
  - **QUEEN** — the rooted brood-mother that holds each floor. She births fresh
    drones, she loathes the light, and she gates the exit. **Only plasma wounds
    her — and only fire keeps her down:** put her down with the plasma rifle,
    then **burn the corpse with the flamethrower**, or she revives and the floor
    never ends.
- **Descend.** Each of the six planets is a citadel of **eight floors**; clear a
  floor (kill and burn its Queen), then call the **freight elevator** — the
  leaves part, you step into the car, and it rides you down to the next.
  Clear the eighth and you **teleport** to the next planet — a fresh citadel that
  runs bright at the surface and dead-dark in the depths, the **lowest floors
  flooded** so you wade. It loops after the sixth planet; only the floors get
  deeper, and difficulty scales with how far down you are.
- **Tools of the trade.** Shoot a **fuel drum** to rupture it into a bomb, or
  stand by one to refill the flamethrower. Plug into a wall-mounted **recharge
  socket** to top up plasma cells — the sockets slowly refill their own reserve,
  so you're never permanently starved. Drop a **proximity mine** for the swarm
  to wander onto.
- **The HUD.** A status bar with ammo, health, an **objective compass** that
  points to the living Queen and swings to the exit once she's ash, armour and
  your arsenal — plus always-on **cells / fuel / mines** gauges, so the survival
  maths is legible at a glance.
- **The front end.** A boot-up terminal title screen, a mission **briefing**, an
  **enemy intel** codex, and a persistent **Hall of the Fallen** high-score table
  — name, score, depth and colony, across sessions.

## Screenshots

| | |
|---|---|
| ![Combat](docs/screenshots/02-combat.png) | ![Enemy intel](docs/screenshots/03-intel.png) |
| Plasma up in the steel corridors. | The enemy intel codex — meet the Queen. |
| ![Mission briefing](docs/screenshots/04-briefing.png) | ![High scores](docs/screenshots/06-highscores.png) |
| The occupation, in brief. | The Hall of the Fallen. |

## Run it

```sh
gmake build                 # universal .app via the shared jorvik-release pipeline
open .build/Citadel.app     # descend
```

### Controls

| | |
|---|---|
| **W A S D** | move / strafe |
| **← / →** · **Mouse** | turn / look |
| **Shift** | run (hold) |
| **Space** | fire |
| **E** | use / open door / hit switch |
| **G** | deploy a proximity mine |
| **1 2 3** · **[ ]** | select / cycle weapon |
| **Tab** | automap |
| **P** · **M** | pause · mute |
| **B** / **I** | briefing / enemy intel (from the title) |
| **K** / **C** | keyboard / controller setup |
| **⌘,** | settings (volumes, sensitivity, reset scores) |
| **Esc** · **⌘Q** | back · quit |

Every gameplay key is **reconfigurable** from the Keyboard sheet (**K**); the
bindings above are the defaults. A connected controller (Xbox / DualShock / any
Extended Gamepad) is detected automatically — left stick moves, right stick
turns, triggers and bumpers fire and switch weapons — and is **rebindable** from
the controller sheet (**C**). Keyboard always works alongside.

### Hidden feature flags

Off by default; opt in per machine with `defaults write` (read live):

```sh
defaults write cc.jorviksoftware.Citadel Godmode       -bool true   # no damage
defaults write cc.jorviksoftware.Citadel AllWeapons    -bool true   # full arsenal + ammo at spawn
defaults write cc.jorviksoftware.Citadel NoClip        -bool true   # walk through walls
defaults write cc.jorviksoftware.Citadel FastMonsters  -bool true   # nightmare speed
defaults write cc.jorviksoftware.Citadel RevealMap     -bool true   # automap fully revealed
defaults write cc.jorviksoftware.Citadel ScreenshotKey -bool true   # F saves a 4× PNG to the Desktop
defaults write cc.jorviksoftware.Citadel FixedSeed     -int 1234    # pin the level seed for testing
```

### Headless harnesses

```sh
# generator + solvability, the update loop (movement, AI, combat, scoring),
# a GPU frame + HUD draw, and high-score persistence — exits non-zero on failure:
CITADEL_SMOKE=1 ./.build/Citadel.app/Contents/MacOS/Citadel

# render the documentation screenshots into docs/screenshots:
CITADEL_SHOTS=docs/screenshots ./.build/Citadel.app/Contents/MacOS/Citadel
```

## Architecture

A real-time GPU signed-distance-field raymarcher (a Metal compute kernel) draws
the world — the level architecture as a distance field `min`'d with native SDF
creatures, lit and graded on the GPU — while the HUD and front-end screens
composite over it in a software 2-D canvas, blit-upscaled nearest-neighbour. See
**[ARCHITECTURE.md](ARCHITECTURE.md)** for the rendering pipeline and a per-file
source map.

## Support

If you enjoy Citadel, you can [**buy me a coffee**](https://jorviksoftware.cc/donate) ☕ — it keeps the Jorvik lights on.

## License

Code released into the public domain under [The Unlicense](LICENSE) — do whatever
you like with it. The bundled audio is **CC0 / CC-BY**, with sources and the
required attributions listed in [CREDITS.md](CREDITS.md).

---

*A Jorvik Software game.*
