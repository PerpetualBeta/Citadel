#!/usr/bin/env python3
"""
Visual regression check for the RASTERSHOT frames.

WHY THIS EXISTS. The shot harness renders ~50 frames covering every environment feature in the
game, and until now nothing compared them run to run — so a look regression was only ever caught
by somebody happening to open the right PNG. In one session that cost us twice over: a silently
dropped material id disabled an entire surface treatment (and the second attempt at the same
treatment appeared to do nothing, because it genuinely did nothing), and a materials change
washed four machines out to near-white. Both were found by luck.

WHAT IT DOES. Renders the shots, then compares each frame against a committed baseline and
reports what moved and by how much. It is a CHANGE DETECTOR, not a pass/fail gate: almost every
change it flags will be one you meant. The point is that you see the ones you did not.

    tools/shotcheck.py --update          # accept the current renders as the baseline
    tools/shotcheck.py                   # compare against it, exit 1 if anything moved
    tools/shotcheck.py --threshold 0.5   # ignore frames that moved less than 0.5% of pixels

The baseline is a small JSON of per-frame statistics, not the images — a few hundred bytes per
frame instead of a megabyte, so it can live in the repo without bloating history. It stores mean
luminance, a coarse 8x6 luminance grid, and a pixel count, which between them catch the failure
modes that actually happen: something vanished, something appeared, something changed brightness,
something moved. A cryptographic hash would be useless here — it flags every frame on any change
and tells you nothing about which or how much.
"""

import argparse
import json
import pathlib
import subprocess
import sys
import tempfile

# 32x20 over a 1280x800 frame → 40x40 px per cell. The first cut used 8x6, and it FAILED the test
# that matters: halving the machine rust — a change I could see plainly side by side — moved no cell
# past the threshold, because 160x133-pixel cells average a localised change into nothing. A
# regression detector that misses the regressions it was built for is worse than none, since it
# grants false confidence. 40x40 cells are small enough that a prop-sized change lands hard in
# several of them, and 640 cells per frame still keeps the baseline near 200 KB for all 57 shots.
GRID_W, GRID_H = 24, 15


def stats(path):
    """A coarse RGB grid and the frame's dimensions.
    
    RGB, not luminance. The first version compared brightness only, and that is blind to exactly
    the regressions that happen most: rust going grey, a screen losing its amber, blankets losing
    their blue. Halving the machine rust — obvious side by side — barely moved luminance at all.
    Three channels cost 3x the baseline and catch a whole class the single channel cannot see.
    """
    from PIL import Image
    im = Image.open(path).convert("RGB")
    w, h = im.size
    small = im.resize((GRID_W, GRID_H), Image.BOX)          # BOX = plain area average
    grid = [b / 255.0 for b in small.tobytes()]              # R,G,B interleaved per cell
    return {"w": w, "h": h, "mean": round(sum(grid) / len(grid), 5),
            "grid": [round(g, 3) for g in grid]}


def compare(base, cur):
    """How far apart two frames are: peak and mean per-channel cell shift, 0-1."""
    if base["w"] != cur["w"] or base["h"] != cur["h"]:
        return None, None                                    # resolution changed — not comparable
    d = [abs(a - b) for a, b in zip(base["grid"], cur["grid"])]
    return max(d), sum(d) / len(d)


# The baseline is the SHIPPING look, so the optics knobs are pinned off rather than
# inherited. This harness reads UserDefaults, so without this a developer who had set
# `LensFlare` or `DepthOfField` on their machine got 52 "changed" frames that were
# nothing but their own knobs — and, far worse, a real regression could hide among
# them. Passed as arguments, which take precedence over the preferences domain.
#
# If either effect ever ships ON by default, change the value here to match and
# regenerate the baseline; the point is that this file states what the baseline means
# instead of depending on whoever runs it.
#
# The SWITCHES are what actually gate the effects (Settings ▸ LENS EFFECTS, stored as
# `lensDoF` / `lensAnamorphic`); the two float keys only tune strength once a switch is
# on. Both are pinned, because pinning the strengths alone would stop working the moment
# someone enabled an effect in the game's own settings — which is now a normal thing for
# a player, and a developer, to do.
OPTICS_OFF = [
    "-lensDoF", "0", "-lensAnamorphic", "0",
    "-LensFlare", "0", "-DepthOfField", "0",
]


def render(outdir, app):
    """Run the shot harness into `outdir`."""
    env = {"CITADEL_RASTERSHOT": str(outdir), "PATH": "/usr/bin:/bin"}
    r = subprocess.run([str(app), *OPTICS_OFF], env=env, capture_output=True, text=True, timeout=900)
    if r.returncode != 0:
        print(r.stdout[-2000:], file=sys.stderr)
        sys.exit(f"shotcheck: harness exited {r.returncode}")
    return sum(1 for _ in pathlib.Path(outdir).glob("*.png"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--update", action="store_true", help="accept the current renders as the baseline")
    ap.add_argument("--threshold", type=float, default=0.012,
                    help="ignore peak cell shifts below this (luminance 0-1; ~3/255 over a 40x40 px cell)")
    ap.add_argument("--app", default=".build/Citadel.app/Contents/MacOS/Citadel")
    ap.add_argument("--baseline", default="tools/shot-baseline.json")
    # The quarantine is EMPTY, and should stay that way. raster-tee and raster-industrial lived here
    # because they came out one of two ways from the same seed; the cause was a room's walls being
    # ranked by slot count alone, over a dictionary whose key order Swift randomises per process, so
    # tied walls (opposite walls of a rectangle, i.e. most rooms) swapped between runs and the
    # furniture — then the pipe routing that follows it — moved. Fixed at source in MapGen with a
    # total ordering; both frames have been byte-identical across repeated runs since. Quarantining a
    # frame hides regressions in it, so add one here only to triage, never as a resting place.
    ap.add_argument("--flaky", default="",
                    help="frames known to differ between identical runs; reported separately, never failed on")
    a = ap.parse_args()

    app = pathlib.Path(a.app)
    if not app.exists():
        sys.exit(f"shotcheck: no app at {app} — run `gmake build` first")

    with tempfile.TemporaryDirectory() as td:
        n = render(td, app.resolve())
        cur = {p.name: stats(p) for p in sorted(pathlib.Path(td).glob("*.png"))}
    print(f"shotcheck: rendered {n} frames")

    bpath = pathlib.Path(a.baseline)
    if a.update:
        bpath.write_text(json.dumps(cur, indent=1, sort_keys=True) + "\n")
        print(f"shotcheck: baseline written — {len(cur)} frames → {bpath}")
        return 0

    if not bpath.exists():
        sys.exit(f"shotcheck: no baseline at {bpath} — create one with --update")
    base = json.loads(bpath.read_text())

    # Two frames still differ between identical runs, flipping between exactly two states with the
    # same magnitude every time — so it is a binary choice somewhere, not numerical noise. Level
    # GENERATION is not the cause: it is seeded throughout, and the one Set iterated during it only
    # applies an order-independent max(). Listing them keeps the tool usable now instead of crying
    # wolf on every run; the cause is still outstanding, and they are NOT silently ignored — they
    # print under their own heading so nobody mistakes this for a clean sheet.
    flaky = {f.strip() for f in a.flaky.split(",") if f.strip()}
    added = sorted(set(cur) - set(base))
    gone = sorted(set(base) - set(cur))
    moved = []
    for name in sorted(set(base) & set(cur)):
        peak, mean = compare(base[name], cur[name])
        if peak is None:
            moved.append((name, float("inf"), 0.0, "RESOLUTION CHANGED"))
        elif peak > a.threshold:
            moved.append((name, peak, mean, ""))
    unstable = [m for m in moved if m[0] in flaky]
    moved = [m for m in moved if m[0] not in flaky]

    for name in added:
        print(f"  NEW      {name}")
    for name in gone:
        print(f"  MISSING  {name}   ← a frame the harness used to produce")
    for name, peak, mean, note in moved:
        print(f"  CHANGED  {name:38s} peak {peak:.4f}  mean {mean:.4f}  {note}")

    for name, peak, mean, _ in unstable:
        print(f"  (flaky)  {name:38s} peak {peak:.4f}  mean {mean:.4f}   ← known unstable, cause outstanding")
    if not (added or gone or moved):
        print(f"shotcheck: no visual change against the baseline"
              + (f" ({len(unstable)} known-flaky frame(s) moved)." if unstable else "."))
        return 0
    print(f"\nshotcheck: {len(moved)} changed, {len(added)} new, {len(gone)} missing.")
    print("Review the ones you did not intend, then `tools/shotcheck.py --update` to accept.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
