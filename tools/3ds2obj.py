#!/usr/bin/env python3
"""
3DS → OBJ for Citadel's imported props, with decimation.

WHY THIS EXISTS. The machinery for floors 7–8 arrives as ArchiCAD/3ds Max exports:
`.3ds` and `.gsm`, occasionally `.obj`. ModelIO (which loads the USDZ creatures) reads
neither `.3ds` nor `.gsm`, and the source meshes are 44k–145k triangles — against a house
scale of 1.2k (bed.obj) to 3.5k (bulkhead.usdz), and a 300k-VERTEX budget for every prop
in view combined. One undecimated machine would eat the whole frame's budget.

So rather than a binary blob dropped into Resources with no provenance, the conversion is
a script: given the same input it produces the same output, and the numbers below are
auditable. Run it again when a mesh is re-sourced.

WHAT IT EMITS. Positions and triangles only — `v` and `f`. That is deliberately all the
game's loader consumes (see RasterRenderer.loadBed): normals are computed per-face at
load, so the flat facets read as fabricated metal, and materials are assigned in code from
geometry rather than from the file. Nothing else in the source is worth carrying.

COORDINATES are left exactly as 3ds Max wrote them (Z-up). The loader rotates to the
game's Y-up with (x, z, −y), the same line bed.obj already relies on — converting here
would silently double-apply it.

DECIMATION is vertex clustering: quantise to a grid, keep for each occupied cell the
vertex NEAREST its centroid (not the average — averaging rounds off the flat panels and
hard edges that make machinery read as machined), remap the triangles, drop any that
collapse. Chosen over edge-collapse because a 36× reduction destroys fine detail either
way, and what has to survive is the silhouette and bulk of a machine seen across a dark
plant room. Grid resolution is binary-searched to land on the triangle target.

    tools/3ds2obj.py <in.3ds|in.obj> <out.obj> [--tris N] [--name NAME]
"""

import argparse
import pathlib
import struct
import sys

# ── 3DS chunk ids we care about ──────────────────────────────────────────────
MAIN, EDIT, OBJECT, MESH = 0x4D4D, 0x3D3D, 0x4000, 0x4100
VERTS, FACES = 0x4110, 0x4120


def read_3ds(data: bytes):
    """Every triangle in the file, in world space, as (positions, triangles).

    3DS stores mesh vertices already in world coordinates; the per-object local axis
    (chunk 0x4160) describes local→world and is NOT applied here. Applying it is the
    classic 3DS-importer bug — it double-transforms — and it is irrelevant to us anyway
    because the prop gets recentred on its own bounds at load.
    """
    pos: list[tuple[float, float, float]] = []
    tris: list[tuple[int, int, int]] = []

    def walk(start: int, end: int):
        base = len(pos)          # vertex indices in FACES are per-object
        p = start
        while p + 6 <= end:
            cid, clen = struct.unpack_from("<HI", data, p)
            if clen < 6 or p + clen > end:
                break            # malformed tail — take what we have
            body = p + 6
            if cid in (MAIN, EDIT, MESH):
                walk(body, p + clen)
            elif cid == OBJECT:
                z = data.index(b"\0", body)          # NUL-terminated object name
                walk(z + 1, p + clen)
            elif cid == VERTS:
                n = struct.unpack_from("<H", data, body)[0]
                base = len(pos)
                for i in range(n):
                    pos.append(struct.unpack_from("<3f", data, body + 2 + i * 12))
            elif cid == FACES:
                n = struct.unpack_from("<H", data, body)[0]
                for i in range(n):
                    a, b, c, _flags = struct.unpack_from("<4H", data, body + 2 + i * 8)
                    tris.append((base + a, base + b, base + c))
            p += clen

    walk(0, len(data))
    return pos, tris


def read_obj(text: str):
    """Positions + triangles from an OBJ, fan-triangulating any n-gons."""
    pos: list[tuple[float, float, float]] = []
    tris: list[tuple[int, int, int]] = []
    for line in text.splitlines():
        f = line.split()
        if not f:
            continue
        if f[0] == "v" and len(f) >= 4:
            pos.append((float(f[1]), float(f[2]), float(f[3])))
        elif f[0] == "f" and len(f) >= 4:
            idx = []
            for tok in f[1:]:
                v = int(tok.split("/")[0])
                idx.append(v - 1 if v > 0 else len(pos) + v)   # OBJ allows negative refs
            for k in range(1, len(idx) - 1):
                tris.append((idx[0], idx[k], idx[k + 1]))
    return pos, tris


def cluster(pos, tris, res):
    """One decimation pass at grid resolution `res` cells along the longest axis."""
    lo = [min(p[i] for p in pos) for i in range(3)]
    hi = [max(p[i] for p in pos) for i in range(3)]
    span = max(hi[i] - lo[i] for i in range(3)) or 1.0
    cell = span / res

    # group vertices by cell, tracking the running centroid
    buckets: dict[tuple[int, int, int], list[int]] = {}
    for vi, p in enumerate(pos):
        key = (int((p[0] - lo[0]) / cell), int((p[1] - lo[1]) / cell), int((p[2] - lo[2]) / cell))
        buckets.setdefault(key, []).append(vi)

    # representative = the member NEAREST the cell centroid, so the kept point lies ON the
    # original surface. Averaging instead rounds off exactly the flat panels and hard
    # corners that make a machine look machined.
    remap: dict[int, int] = {}
    out_pos: list[tuple[float, float, float]] = []
    for members in buckets.values():
        n = len(members)
        cx = sum(pos[m][0] for m in members) / n
        cy = sum(pos[m][1] for m in members) / n
        cz = sum(pos[m][2] for m in members) / n
        best, bestd = members[0], None
        for m in members:
            p = pos[m]
            d = (p[0] - cx) ** 2 + (p[1] - cy) ** 2 + (p[2] - cz) ** 2
            if bestd is None or d < bestd:
                best, bestd = m, d
        new = len(out_pos)
        out_pos.append(pos[best])
        for m in members:
            remap[m] = new

    seen = set()
    out_tris = []
    for a, b, c in tris:
        ra, rb, rc = remap[a], remap[b], remap[c]
        if ra == rb or rb == rc or ra == rc:
            continue                                    # collapsed to an edge or a point
        key = tuple(sorted((ra, rb, rc)))
        if key in seen:
            continue                                    # duplicate facet after welding
        seen.add(key)
        out_tris.append((ra, rb, rc))
    return out_pos, out_tris


def decimate(pos, tris, target):
    """Binary-search the grid resolution that lands nearest `target` triangles."""
    if len(tris) <= target:
        return pos, tris
    lo, hi = 4, 512
    best = None
    for _ in range(12):
        mid = (lo + hi) // 2
        p2, t2 = cluster(pos, tris, mid)
        if best is None or abs(len(t2) - target) < abs(len(best[1]) - target):
            best = (p2, t2)
        if len(t2) > target:
            hi = mid - 1
        else:
            lo = mid + 1
        if lo > hi:
            break
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--tris", type=int, default=3500, help="triangle target (house scale: bed 1208, bulkhead 3508)")
    ap.add_argument("--name", default=None, help="comment written into the OBJ header")
    a = ap.parse_args()

    src = pathlib.Path(a.src)
    raw = src.read_bytes()
    if src.suffix.lower() == ".obj":
        pos, tris = read_obj(raw.decode("latin-1"))
    else:
        pos, tris = read_3ds(raw)
    if not pos or not tris:
        sys.exit(f"{src.name}: no geometry found")

    n0, t0 = len(pos), len(tris)
    pos, tris = decimate(pos, tris, a.tris)

    lo = [min(p[i] for p in pos) for i in range(3)]
    hi = [max(p[i] for p in pos) for i in range(3)]
    dims = [hi[i] - lo[i] for i in range(3)]

    out = [f"# {a.name or src.stem} — converted by tools/3ds2obj.py from {src.name}",
           f"# source {n0} verts / {t0} tris → {len(pos)} verts / {len(tris)} tris",
           f"# bounds (source units, Z-up as exported): {dims[0]:.1f} x {dims[1]:.1f} x {dims[2]:.1f}",
           "# positions + triangles only: the loader computes flat normals and assigns materials in code"]
    out += [f"v {p[0]:.5f} {p[1]:.5f} {p[2]:.5f}" for p in pos]
    out += [f"f {t[0] + 1} {t[1] + 1} {t[2] + 1}" for t in tris]
    pathlib.Path(a.dst).write_text("\n".join(out) + "\n")

    print(f"{src.name:34s} {t0:7d} → {len(tris):5d} tris  ({len(pos):5d} verts)  "
          f"bounds {dims[0]:7.1f} x {dims[1]:7.1f} x {dims[2]:7.1f}  → {pathlib.Path(a.dst).name}")


if __name__ == "__main__":
    main()
