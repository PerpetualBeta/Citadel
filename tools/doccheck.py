#!/usr/bin/env python3
"""
Consistency check for README.md, ARCHITECTURE.md and CREDITS.md against the actual repo.

WHY THIS EXISTS. Approaching release, these three documents are promises: CREDITS is a
LICENCE document (an uncredited CC-BY asset makes the licence void), ARCHITECTURE is the
map a contributor navigates by, and the README is what a stranger judges the project on.
All three had drifted badly and none of the drift was subtle — every single fault below was
mechanically detectable, and every one survived because nobody was checking mechanically:

  • README and ARCHITECTURE both described a GPU SDF raymarcher as the renderer, months
    after the kernel was DELETED. ARCHITECTURE closed with a section explaining how it
    worked and listed a file that no longer existed.
  • ARCHITECTURE's source map was missing twenty-odd files, including the renderer that
    actually ships.
  • CREDITS documented two colonist meshes while seven shipped; the third hero plate and
    THE SIGNAL's two synthesised stems were absent entirely; a mesh was listed with no
    provenance at all.
  • The README declared three asset exceptions against four real ones, and claimed "no
    textures" while nine meshes shipped with baked base-colour maps.

    tools/doccheck.py            # audit; exit 1 on any finding
    tools/doccheck.py --quiet    # only print findings

It is a PROMISE-KEEPER, not a style checker: it asserts that every file the product ships
is accounted for, and that no document points at something that no longer exists. It cannot
tell you the prose is well written or that a description is true — only that the inventory
is complete and the references resolve. Read the prose too.
"""

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Flags deliberately left out of the README, with the reason. An entry here is a RECORDED
# decision; a flag in neither this dict nor the README is an oversight, which is the point.
DELIBERATELY_UNDOCUMENTED = {
    "FallenColonists": "naming it spoils a discovery — the README must not describe what it strips",
    "Updater": "an override on a default the BUILD decides (on when shipped, off when local) — "
               "documenting it would advertise a switch whose useful setting is already the default",
}

# Assets whose absence from CREDITS is intentional (none so far — keep it that way).
CREDITS_EXEMPT: set[str] = set()


def read(name: str) -> str:
    p = ROOT / name
    if not p.exists():
        sys.exit(f"doccheck: {name} is missing")
    return p.read_text()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    readme, arch, credits = read("README.md"), read("ARCHITECTURE.md"), read("CREDITS.md")
    findings: list[str] = []
    checks = 0

    # 1. CREDITS accounts for every shipped asset. It is a licence document: a gap here is
    #    not untidiness, it is an asset distributed with no recorded provenance.
    assets = sorted(
        p for p in (ROOT / "Resources").rglob("*")
        if p.is_file() and p.suffix.lower() in {".usdz", ".obj", ".png", ".jpg", ".wav", ".m4a", ".ogg"}
    )
    for p in assets:
        checks += 1
        # audio ships as numbered variant families (hiss1..hiss16) — credit the family
        stem = re.sub(r"\d+$", "", p.stem) or p.stem
        # …and a `_basecolor` map is its mesh's own texture, so crediting the mesh covers it
        # (the CREDITS row for the meshes says "each .usdz + _basecolor.jpg" for that reason)
        names = {stem, p.stem, re.sub(r"_basecolor$", "", p.stem)}
        if names & CREDITS_EXEMPT:
            continue
        if not any(n in credits for n in names):
            findings.append(f"CREDITS: no provenance recorded for {p.relative_to(ROOT)}")

    # 2. ARCHITECTURE's source map covers every source file. A contributor navigates by it,
    #    so a missing entry is a file nobody knows is load-bearing.
    for p in sorted((ROOT / "Sources").rglob("*.swift")):
        checks += 1
        if f"`{p.name}`" not in arch:
            findings.append(f"ARCHITECTURE: {p.name} is not in the source map")

    # 3. No document points at a Swift file that no longer exists. This is the exact shape of
    #    the GPUWorldRenderer.swift fault: a deleted file still described as current.
    live = {p.name for p in (ROOT / "Sources").rglob("*.swift")} | {"generate_icon.swift"}
    for doc, text in (("README.md", readme), ("ARCHITECTURE.md", arch), ("CREDITS.md", credits)):
        for named in sorted(set(re.findall(r"`([A-Za-z0-9_]+\.swift)`", text))):
            checks += 1
            if named not in live:
                findings.append(f"{doc}: references `{named}`, which does not exist")

    # 4. Every feature flag is either documented or recorded as deliberately not.
    flags = sorted(set(re.findall(r'forKey:\s*"([A-Za-z]+)"', read("Sources/App/FeatureFlags.swift"))))
    for f in flags:
        checks += 1
        if f not in readme and f not in DELIBERATELY_UNDOCUMENTED:
            findings.append(f"README: feature flag {f} is undocumented (add it, or record why not in doccheck.py)")
    for f in DELIBERATELY_UNDOCUMENTED:
        checks += 1
        if f not in flags:
            findings.append(f"doccheck.py: {f} is recorded as deliberately undocumented but no longer exists")

    # 5. The asset-exception COUNT the docs quote must match the categories that exist. Both
    #    documents undercounted for weeks, which is how "no textures" survived nine textures.
    for doc, text in (("README.md", readme), ("ARCHITECTURE.md", arch)):
        checks += 1
        if not re.search(r"\bFour\b|\bfour\b", text.split("## Source map")[0].split("## The game")[0]):
            findings.append(f"{doc}: the asset-exception count near the top no longer reads 'four' — recount it")

    if findings:
        print(f"doccheck: {len(findings)} finding(s) across {checks} checks\n")
        for f in findings:
            print(f"  {f}")
        print("\nThese are promises to a reader (and, for CREDITS, a licence obligation).")
        return 1
    if not args.quiet:
        print(f"doccheck: {checks} checks — README, ARCHITECTURE and CREDITS all consistent with the repo")
    return 0


if __name__ == "__main__":
    sys.exit(main())
