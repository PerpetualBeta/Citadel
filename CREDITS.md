# Citadel — credits

Citadel's code, graphics, and game design are original work. Its **audio** is the
deliberate exception to the Jorvik "everything generated in code" rule: Citadel
ships real sampled sound effects, ambient beds, and a title theme, because the
atmosphere leans too hard on sound to synthesise convincingly.

All audio assets are **CC0** (public domain) or **CC-BY** (attribution). This file
records every asset, its source, author, and licence. CC0 requires no attribution
but is listed here as a courtesy and for provenance.

## Audio

**Complete CC0 sound set in place** — all assets below are **CC0 1.0 / public domain**
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
Ogrebane — *Monster Sound Effects 2* (<https://opengameart.org/content/monster-sound-effects-2>, CC0).

| File(s) | Sound | Source | Original |
|---------|-------|--------|----------|
| plasma, plasma1, plasma2 | plasma rifle | Kenney Sci-Fi Sounds | laserSmall_000–002 |
| rocket | rocket launch | Kenney Sci-Fi Sounds | laserLarge_000 |
| flamethrower, flamethrower1 | flame burst | Kenney Sci-Fi Sounds | thrusterFire_000/002 |
| explosion, explosion1, explosion2 | explosion | Kenney Sci-Fi Sounds | explosionCrunch_000/002, lowFrequency_explosion_000 |
| door_open | door slide | Kenney Sci-Fi Sounds | doorOpen_000 |
| hiss (×9, random — drone + Queen, sight & pain) | alien hiss | rubberduck 80 CC0 creature SFX | spit_01/02, breath, alien_01–06 |
| drone_death (×13, random) | drone death — raspy gasp | Ogrebane Monster SFX 2 | monster-1, 5–11, 13–17 |
| queen_death (×3, random) | Queen death — frightful squeal | rubberduck 80 CC0 creature SFX #2 | alien_07/08/09 |
| pickup, pickup1 | item / ammo pickup | Kenney Interface Sounds | confirmation_001/002 |
| secret | secret found | Kenney Interface Sounds | glass_001 |
| exit | level exit reached | Kenney Interface Sounds | bong_001 |
| locked | locked door / denied | Kenney Interface Sounds | error_004 |
| player_pain (×11, random) | marine hurt by an alien | HaelDB Male Grunt/Yelling | assorted male yells |
| player_death | marine death cry | HaelDB Male Grunt/Yelling | yell10 |
| bed_drone | ambient bed: room tone (always on) | SRG774 Dark Sci-Fi Audio Pack | sector |
| bed_swarm | ambient bed: tension layer (fades in as the swarm nears) | SRG774 Dark Sci-Fi Audio Pack | urgent |
| music_title | title-screen theme (loops; click-free, fades to a breath each cycle) | OpenGameArt CC0 - Dark Music | Derelict |

The reactive bed currently has **two layers** (drone + swarm crossfaded by threat);
`bed_pulse` / `bed_tension` are unfilled, so those layers are silent for now.

_Every sound above is now a real CC0 sample; the synth in AudioEngine.swift is only a safety
fallback for a missing file. Aliens HISS (no roar); the Queen dies with a squeal, the drone
with a raspy gasp; the marine grunts and dies in a real voice._

### How to fill this in
- **CC0**: source URL + author (if known). No obligation, but list it.
- **CC-BY**: source URL + author + the exact attribution string the licence asks
  for. This is **required** — the licence is void without it.
- Avoid CC-BY-SA / CC-BY-NC / GPL audio: SA forces share-alike on the bundle, NC
  forbids the (free, but publicly distributed) release, GPL is awkward for assets.

See `docs/audio-sourcing.md` for recommended CC0/CC-BY sources and per-sound
search terms.
