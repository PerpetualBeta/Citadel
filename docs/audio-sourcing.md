# Citadel — audio sourcing guide

The plan (locked): bundle CC0/CC-BY samples in `Resources/Audio/`, the engine
plays them, the synth is only a fallback. This doc lists where to find good
open-source audio and what to search for, sound by sound. Drop finals into
`Resources/Audio/` using the base filenames from its `README.txt`, and log every
CC-BY asset in `../CREDITS.md`.

## Where to look (licence-safe)

- **Kenney** — <https://kenney.nl/assets?q=audio> — **CC0**, game-ready, dry,
  consistent. Packs: *Sci-Fi Sounds*, *Impact Sounds*, *Interface Sounds*,
  *Digital Audio*. Best first stop for SFX; no attribution required.
- **Freesound** — <https://freesound.org> — huge; **filter licence to "Creative
  Commons 0"** (or CC-BY and credit). Account needed to download. Best for
  organic / monster / industrial-ambience source material.
- **OpenGameArt** — <https://opengameart.org> — filter to CC0. Mixed quality;
  check each asset's licence individually (the site hosts CC0, CC-BY, GPL…).
- **Sonniss GDC Game Audio Bundle** — <https://sonniss.com/gameaudiogdc> —
  royalty-free, usable in commercial/free projects; huge raw library, great for
  the ambient beds. (Big downloads.)
- Avoid CC-BY-SA (forces share-alike on the whole bundle), CC-BY-NC (no free
  public release), and GPL audio.

## Per-sound shopping list

Weapons (dry, punchy, short):
- `plasma` — "plasma", "energy weapon", "laser zap", "sci-fi gun". Want a tight
  electric *crack* with a short tail, not a long pew.
- `flamethrower` — "fire whoosh", "flame burst", "gas ignite". Keep it SHORT —
  it's retriggered in throttled bursts while firing.
- `rocket` — "rocket launch", "missile whoosh" + an ignition transient.

Drone (the xenomorph; wet, organic, vicious):
- `drone_sight` — "monster screech", "creature hiss", "alien snarl".
- `drone_pain` — "creature hurt", "wet impact", "flesh hit".
- `drone_death` — "monster death", "gurgle", "wet splatter".

Queen (vast, subsonic, terrifying — pitch normal roars DOWN if needed):
- `queen_sight` — "monster roar low", "beast bellow".
- `queen_pain` — "huge creature roar", "kaiju hurt".
- `queen_death` — "monster death roar", "kaiju death" (long, big).

World / feedback:
- `explosion` — "explosion", "blast", "debris" (one solid boom).
- `door_open` — "blast door", "heavy metal slide", "hydraulic door".
- `locked` — "denied", "locked door clunk", "buzzer" (short, two clunks read well).
- `pickup` — "item pickup", "powerup", "blip" (short, positive).
- `secret` — "secret found", "reveal", "chime" (small sting).
- `exit` — "level complete", "objective", short ascending sting.
- `player_pain` — "male grunt hurt", "pain" (the marine).
- `player_death` — "death", "long male groan / fall".

## Reactive ambient bed (the centrepiece)

Four **seamless loops, all the same length**, that crossfade by swarm proximity
(see README.txt). Dark industrial — iron, steel, pipework, distant machinery.
- `bed_drone` — low room tone / plant hum. Almost no movement. Always audible.
- `bed_pulse` — a slow rhythmic throb / heartbeat of the colony machinery.
- `bed_tension` — uneasy: detuned metal resonances, faint dissonant pad.
- `bed_swarm` — peak dread: skittering, chittering, denser percussion, low brass.

Search: "dark ambient drone", "industrial loop", "horror pad", "sci-fi engine
room", "machinery rumble". Freesound CC0 + Sonniss are strongest here. If sourcing
four matched stems is hard, ship `bed_drone` first (the engine fades the others in
only as you provide them; missing layers are just silent).

## Title theme

- `music_title` — dark industrial, loopable, brooding (not melodic chiptune).
  Search "dark industrial loop", "sci-fi horror theme" on CC0/CC-BY sources.

## Acceptance check

- One-shots: short, dry, no long reverb tail (the engine adds space).
- Levels reasonably matched (the per-sound `gain` in AudioEngine.swift trims, but
  start from samples of similar loudness).
- Beds: seamless loop (no click at the wrap), same length, low-mid focused so the
  SFX cut through.
- Log every CC-BY asset in `CREDITS.md` before committing.
