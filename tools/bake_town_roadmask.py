#!/usr/bin/env python3
"""
bake_town_roadmask.py — Run 169 (2026-08-20)
============================================
Bakes  Assets/Tilesets/Town_props/_road_mask.png  — a 1/4-scale stencil of the
Town Square's painted roads, raked-sand centre and walled garden.

Why it exists
-------------
Run 149 gave the placed props a hard rule: "props may frame the paths, never
stand ON them", enforced by TownTileset._min_seg_dist against a code-authored
list of path segments (ring ellipse + spokes). Run 169 replaced the baked
ground with hand-painted squares, and those painted roads are NOT the code's
ellipse — the ring is wider on the west, the spokes are flatter than 45 deg,
and both spines run down x = -41 rather than x = 0. Left alone, the guard
would wave props onto the road and reject clear ground.

Rather than hand-maintain a second set of segment constants that drift the
moment the art is redrawn, the rule now reads the ART. This tool extracts the
road surface by colour (the roads are the only bright warm tan in the image),
unions all four tiers so one stencil serves every one of them, and writes it at
quarter resolution — 4 world px per stencil pixel is far finer than the prop
clearances it feeds.

The stencil covers exactly the ARENA (TownBuild.HALF_W/HALF_H), origin at the
top-left corner (-HALF_W, -HALF_H), so TownArt.on_road() is a plain lookup.

Usage
-----
    python3 tools/bake_town_roadmask.py
"""
from __future__ import annotations

import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

# Mirrors TownArt.gd — see the geometry note there.
SRC_W, SRC_H = 2496, 1724
INT_X, INT_Y, INT_W, INT_H = 58, 330, 2380, 1260
HALF_X, HALF_Y = 710.0, 400.0
DOWNSCALE = 4                     # world px per stencil px

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
TILESETS = os.path.join(ROOT, "Assets", "Tilesets")
OUT = os.path.join(TILESETS, "Town_props", "_road_mask.png")

# ONE source, deliberately. Every tier paints the roads in the same place
# (all eight images cross-correlate at zero offset), and the Fully Healed day
# art is the only one where the road tan separates cleanly from the plaza in
# every tier's palette — Under Construction's stone is nearly the same hue as
# its roads, and Delapidated's roads are a desaturated grey the colour test
# cannot see at all. Unioning them all smeared the stencil instead of
# sharpening it, so the cleanest source wins and the rest inherit it.
SOURCES = ["Town_Square_Healed_Full_Day.jpg"]


def road_of(path: str) -> np.ndarray | None:
    """Bright warm tan = road surface, raked sand centre and the zen garden's
    sand. Absolute thresholds, tuned on the Fully Healed day art."""
    if not os.path.exists(path):
        return None
    a = np.asarray(Image.open(path).convert("RGB")).astype(float)
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    m = (r > 185) & (g > 150) & (b < 178) & (r - b > 35) & (g - b > 16)
    m = ndimage.binary_opening(m, np.ones((7, 7)))
    m = ndimage.binary_closing(m, np.ones((21, 21)))
    m = ndimage.binary_dilation(m, np.ones((9, 9)))   # a hair of shoulder
    return m


def main() -> int:
    acc = None
    used = 0
    for name in SOURCES:
        m = road_of(os.path.join(TILESETS, name))
        if m is None:
            print(f"  skip (missing) {name}")
            continue
        cover = m[INT_Y:INT_Y + INT_H, INT_X:INT_X + INT_W].mean()
        if cover < 0.04 or cover > 0.60:
            # a tier whose palette defeats the threshold contributes nothing
            # rather than smearing the union
            print(f"  skip (coverage {cover:.2%}) {name}")
            continue
        acc = m if acc is None else (acc | m)
        used += 1
        print(f"  + {name}  (road coverage {cover:.1%})")
    if acc is None:
        print("no usable source art"); return 1

    inner = acc[INT_Y:INT_Y + INT_H, INT_X:INT_X + INT_W]
    w = int(HALF_X * 2 / DOWNSCALE)
    h = int(HALF_Y * 2 / DOWNSCALE)
    small = np.asarray(
        Image.fromarray((inner * 255).astype(np.uint8)).resize((w, h), Image.BOX)
    ) > 96
    Image.fromarray((small * 255).astype(np.uint8), "L").save(OUT)
    print(f"wrote {OUT}  {w}x{h}  ({used} tiers unioned, {small.mean():.1%} road)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
