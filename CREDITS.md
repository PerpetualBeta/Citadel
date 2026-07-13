# Citadel — credits

Citadel's code, graphics, and game design are original work. Its **audio** is the
deliberate exception to the Jorvik "everything generated in code" rule: Citadel
ships real sampled sound effects, ambient beds, and a title theme, because the
atmosphere leans too hard on sound to synthesise convincingly.

All audio assets are **CC0** (public domain), **CC-BY** (attribution), or under the **Pixabay Content License** (royalty-free, no attribution required). This file
records every asset, its source, author, and licence. CC0 requires no attribution
but is listed here as a courtesy and for provenance.

## Audio

**Full sound set in place** — assets below are **CC0 1.0 / public domain** (bar one Pixabay-licensed ambience, noted in the table)
(<https://creativecommons.org/publicdomain/zero/1.0/>), so no attribution is
required; sources are credited here as a courtesy and for provenance. They're
placeholders that prove the pipeline and set the tone — swap any for a final using
the same base filename.

**Sources:** Kenney — *Sci-Fi Sounds*, *Interface Sounds*, *Impact Sounds*
(<https://www.kenney.nl>, CC0) · SRG774 — *Dark Sci-Fi Audio Pack*
(<https://opengameart.org/content/dark-sci-fi-audio-pack>, CC0) · *Derelict* from the
*CC0 - Dark Music* collection (<https://opengameart.org/content/cc0-dark-music>, CC0) ·
HaelDB — *Male Grunt/Yelling sounds* (<https://opengameart.org/content/male-gruntyelling-sounds>, CC0) ·
rubberduck — *80 CC0 creature SFX* #1 & #2 (<https://opengameart.org/content/80-cc0-creature-sfx>, CC0) ·
rubberduck — *40 CC0 water splash / slime SFX* (<https://opengameart.org/content/40-cc0-water-splash-slime-sfx>, CC0) ·
Ogrebane — *Monster Sound Effects 2* (<https://opengameart.org/content/monster-sound-effects-2>, CC0).

| File(s) | Sound | Source | Original |
|---------|-------|--------|----------|
| plasma, plasma1, plasma2 | plasma rifle | Kenney Sci-Fi Sounds | laserSmall_000–002 |
| rocket | rocket launch | Kenney Sci-Fi Sounds | laserLarge_000 |
| flamethrower, flamethrower1 | flame burst | Kenney Sci-Fi Sounds | thrusterFire_000/002 |
| explosion, explosion1, explosion2 | explosion | Kenney Sci-Fi Sounds | explosionCrunch_000/002, lowFrequency_explosion_000 |
| door_open | door slide | Kenney Sci-Fi Sounds | doorOpen_000 |
| hiss (×9, random — drone sight + drone/Queen pain) | alien hiss | rubberduck 80 CC0 creature SFX | spit_01/02, breath, alien_01–06 |
| queen_snarl1–9 (×9, random — pitched DOWN & varied per-utterance in-engine) | Queen snarl — broodmother roar (plays only with line of sight) | rubberduck 80 CC0 creature SFX | roar_02/03, monster_01/03/04/06/07, troll_01/02 |
| drone_death (×13, random) | drone death — raspy gasp | Ogrebane Monster SFX 2 | monster-1, 5–11, 13–17 |
| queen_death, queen_death1 (×2, random) | Queen death — the long wail of a dying giant beast (two slices of one recording) | bevibeldesign — *Dragon Death* (<https://freesound.org/s/366096/>, CC0) | Dragon Death |
| queen_fall | Queen impact — the toppled brood-mother slams the deck | DasWaff — *Giant step* (<https://freesound.org/s/721601/>, CC0) | Giant step |
| pickup, pickup1 | item / ammo pickup | Kenney Interface Sounds | confirmation_001/002 |
| secret | secret found | Kenney Interface Sounds | glass_001 |
| exit | level exit reached | Kenney Interface Sounds | bong_001 |
| locked | locked door / denied | Kenney Interface Sounds | error_004 |
| player_pain (×11, random) | marine hurt by an alien | HaelDB Male Grunt/Yelling | assorted male yells |
| player_death | marine death cry | HaelDB Male Grunt/Yelling | yell10 |
| wade, wade1 (L/R, alternating) | wading splash — the flooded floor 8 + floor-7 puddles | rubberduck 40 CC0 water splash/slime SFX | splash_12 / splash_14 |
| drip, drip1–drip5 (random, pitch-varied per plink in-engine) | ceiling water plinking into the deep floors' pools (panned per site) | freesound.org, all CC0: beskhu #273870, qubodup #792927, florianreichelt #683102, Ev-Dawg #337525, arseniiv #257349 (two plinks sliced) | trimmed + peak-normalised |
| fault | distant electric-shock — the occasional far-off crack of a shorting circuit (damaged-building ambience; pitch/level tweaked + reverb-drenched in-engine so it reads as far off) | freesound_community — *Electric shock*, via Pixabay (<https://pixabay.com/users/freesound_community-46691455/>, Pixabay Content License) | Electric shock #33018 |
| elevator_move | freight elevator descent — low winch hum (loops, stops with the car) | Kenney Sci-Fi Sounds | spaceEngineLow_000 |
| elevator_door, elevator_shut | elevator leaves part / seal | Kenney Sci-Fi Sounds | doorOpen_002 / doorClose_002 |
| bed_drone | ambient bed: room tone (always on) | SRG774 Dark Sci-Fi Audio Pack | sector |
| bed_pulse | ambient bed: slow machinery throb (grows with threat) | SRG774 Dark Sci-Fi Audio Pack | pulse |
| bed_tension | ambient bed: eerie floating dissonance (high threat) | SRG774 Dark Sci-Fi Audio Pack | airy |
| bed_swarm | ambient bed: peak layer (swarm near / Queen present) | SRG774 Dark Sci-Fi Audio Pack | urgent |
| music_title | title-screen theme (seamless loop) | OpenGameArt CC0 - Dark Music | Derelict |

The reactive bed is the full **four-layer** design (drone / pulse / tension / swarm,
crossfaded by live threat). All four stems and the title theme are **loop-conditioned**
from the originals — leading/trailing silence and authored fade-outs trimmed, then the
tail equal-power-crossfaded into the head at an envelope-matched splice point — so each
wraps seamlessly under the engine's whole-buffer looping (the pack author's own note says
the raw tracks expect an engine-side crossfade, which Citadel deliberately doesn't do).
Shipped as AAC (.m4a): unlike bare MP3, CoreAudio decodes it gapless to the exact frame
count. Method + script: `docs/audio-sourcing.md` / `docs/condition-loop.py`.

_Every sound above is now a real CC0 sample; the synth in AudioEngine.swift is only a safety
fallback for a missing file. Drones HISS; the Queen SNARLS — a CC0 creature roar pitched
DOWN and randomly varied (pitch + tempo) in-engine, so she reads enormous and never repeats,
and only when she has line of sight to you — and she dies with a squeal. The drone dies with
a raspy gasp; the marine grunts and dies in a real voice._

### How to fill this in
- **CC0**: source URL + author (if known). No obligation, but list it.
- **CC-BY**: source URL + author + the exact attribution string the licence asks
  for. This is **required** — the licence is void without it.
- Avoid CC-BY-SA / CC-BY-NC / GPL audio: SA forces share-alike on the bundle, NC
  forbids the (free, but publicly distributed) release, GPL is awkward for assets.

See `docs/audio-sourcing.md` for recommended CC0/CC-BY sources and per-sound
search terms.
