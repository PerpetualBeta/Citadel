Citadel — audio drop-in folder
==============================

Drop sample files here and the game plays them automatically. No code change.
The whole folder is copied into Citadel.app/Contents/Resources/Audio at build
time, and AudioEngine.swift loads it from the bundle on launch.

HOW IT WORKS
------------
- Every sound has a base filename (below). Drop  <base>.<ext>  to provide it.
- Variations: drop  <base>1.<ext> , <base>2.<ext> … up to <base>4 and the game
  picks one at random per trigger (great for footsteps, hits, weapon shots).
- Accepted extensions, in priority order: wav, caf, aiff, aif, m4a, mp3, ogg.
  Prefer WAV or CAF (uncompressed) for one-shots; m4a/mp3/ogg are fine for the
  long ambient/music loops. (macOS AVFoundation decodes Ogg Vorbis natively.)

- A CC0 STARTER SET (Kenney Sci-Fi Sounds, public domain) is bundled as the
  current placeholders — *.ogg files here. Replace any of them with your finals
  using the same base name. See ../../CREDITS.md.
- Any file is resampled to 44.1 kHz stereo on load, so source rate doesn't matter.
- A MISSING sample falls back to the built-in synth, so partial sets are fine —
  add sounds one at a time and hear each one upgrade.

ONE-SHOTS (bus: SFX)
--------------------
  plasma            plasma rifle shot
  flamethrower      flame burst (fired in short throttled bursts — keep it short)
  rocket            rocket launch (whoosh + ignition)
  drone_sight       a drone notices you (hiss / screech)
  drone_pain        drone hit
  drone_death       drone dies (wet, gurgling)
  queen_sight       the Queen registers you (low bellow)
  queen_pain        Queen wounded (subsonic roar)
  queen_death       Queen killed (huge death cry)
  explosion         rocket / drum / mine detonation
  door_open         heavy door / blast door sliding
  locked            locked door / denied (two short clunks)
  pickup            item / ammo pickup
  secret            secret found (small reveal sting)
  exit              level exit reached (short ascending sting)
  player_pain       marine takes a hit
  player_death      marine dies

REACTIVE AMBIENT BED (bus: AMBIENT) — these LOOP
------------------------------------------------
The level "soundtrack" is four looping stems crossfaded by live danger (the
swarm's proximity). Make them all the SAME length so they stay phase-locked,
and seamless-loopable. They layer on top of each other:

  bed_drone         always present — the room/plant tone (the floor of the mix)
  bed_pulse         fades in as drones approach — a slow throb that quickens
  bed_tension       high-threat dissonance — drones close / Queen stirring
  bed_swarm         peak layer — many drones near, or the Queen present

  (bed_drone is the trigger: if it's absent the whole sampled bed is skipped and
   the synth fallback bed runs instead. Provide at least bed_drone to switch over.)

TITLE MUSIC (bus: MUSIC) — loops
--------------------------------
  music_title       title-screen theme (dark industrial; loops)

LICENSING
---------
CC0 or CC-BY only (this repo is public, OSS). Record every CC-BY source in
../../CREDITS.md. CC0 needs no attribution but list it anyway as courtesy.
See ../../docs/audio-sourcing.md for recommended sources and search terms.
