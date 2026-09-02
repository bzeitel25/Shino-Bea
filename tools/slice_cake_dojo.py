#!/usr/bin/env python3
"""
slice_cake_dojo.py -- Run 171: cut Assets/Tilesets/CakeDojo_props/

The Cake-Dojo sheet is a 1:1 re-skin of the Dojo sheet: same 2816x1536 page,
same eight panels (verified to +-2px), same prop in every cell -- only the
palette changes (chocolate planks, strawberry-icing walls, blossom bonsai,
sugar-glass lanterns).  So instead of re-inventing a cut list we LOCATE each
existing Dojo_props sprite inside `Dojo Tileset.png` by masked template match
(scores come back 0.99-1.00) and cut the SAME rect out of the cake sheet.

Result: CakeDojo_props/ carries the exact same filenames as Dojo_props/, which
is what lets CakeDojo.gd be a straight palette-swap of Dojo.gd's decor pass.

  props        border flood-keyed, binary alpha, bbox-cropped (a small margin
               is added first so a cake prop whose silhouette is a few px wider
               than its dojo twin is not clipped)
  OPAQUE_TILES cut at the exact dojo rect with no keying (floors/rugs/screens)
  floor/       plank_v_0..11, plank_h_0..5, sponge_0..5 and the tat_l / tat_d
               4x4 nine-slice blocks, cut from the auto-tile panel cell grid
  wall/        155px-tall wall faces (native 310 halved 2:1) -- same contract
               as Dojo_props/wall, so Dojo.gd's WALL_FACE_H still applies
"""
import cv2
import glob
import json
import numpy as np
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sheet_clean import load_rgb, derule, key_sprite, save_rgba, save_rgb, panels

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TS = os.path.join(ROOT, "Assets", "Tilesets")
DOJO_SHEET = os.path.join(TS, "Dojo Tileset.png")
CAKE_SHEET = os.path.join(TS, "Cake-Dojo Tileset.png")
SRC_PROPS = os.path.join(TS, "Dojo_props")
OUT = os.path.join(TS, "CakeDojo_props")

MARGIN = 10          # breathing room around the dojo rect before keying

# Props that are OPAQUE tiles in Dojo_props -- cut 1:1, never keyed.
OPAQUE = set("""floor_wood tatami_a tatami_b zen_sand_a zen_sand_b rug_green rug_navy
rug_red trap_door gong_alcove shoji_panel shoji_door_arch""".split())

# ---------------------------------------------------------------- panel geometry
# Both sheets report these panels; the cake sheet lands within 2px of the dojo's.
FLOOR_PANEL = (36, 86, 1350, 315)
WALL_PANEL = (1431, 86, 1348, 315)
# Floor sub-panels (absolute x ranges), split on the page-bg gutters.
SUB_PLANK = (36, 512)      # 6 cols x 4 rows: chocolate planks + a sponge row
SUB_TAT_L = (517, 821)     # 4x4 light strawberry tatami
SUB_TAT_D = (1080, 1386)   # 4x4 dark-framed tatami
PANEL_TOP, PANEL_BOT = 86, 401
CELL_INSET = 6             # crop inside the cell so the lattice can never leak in
TILE = 32

# Wall faces: y=88 h=310 native (= 155 after the 2:1 halve), x/width per part.
# shoji/arch/alcove x come from matching Dojo_props/wall against the dojo sheet;
# the three "plain" slices are picked inside the icing-wall run, clear of beams.
WALL_PARTS = [
    ("wall_shoji_a", 1444, 70),
    ("wall_shoji_b", 1514, 70),
    ("wall_plain_a", 1875, 74),
    ("wall_plain_b", 1948, 74),
    ("wall_plain_c", 2244, 74),
    ("wall_post", 2508, 30),
    ("wall_arch", 2338, 144),
    ("wall_alcove", 2554, 234),
]
WALL_Y, WALL_H = 88, 310


def locate_props():
    """(name -> rect) for every Dojo_props sprite, found in the dojo sheet."""
    sheet = cv2.imread(DOJO_SHEET, cv2.IMREAD_UNCHANGED)[:, :, :3].astype(np.float32)
    rects = {}
    for f in sorted(glob.glob(os.path.join(SRC_PROPS, "*.png"))):
        name = os.path.splitext(os.path.basename(f))[0]
        if name.startswith("_"):
            continue
        p = cv2.imread(f, cv2.IMREAD_UNCHANGED)
        if p is None or p.shape[0] > sheet.shape[0] or p.shape[1] > sheet.shape[1]:
            continue          # Dojo_Floor_Clean / Training_Dummy are hand art, not cuts
        h, w = p.shape[:2]
        alpha = p[:, :, 3] if p.shape[2] == 4 else np.full((h, w), 255, np.uint8)
        mask = (alpha > 200).astype(np.float32)
        if mask.sum() < 50:
            continue
        t = p[:, :, :3].astype(np.float32)
        r = cv2.matchTemplate(sheet, t, cv2.TM_CCORR_NORMED,
                              mask=cv2.merge([mask, mask, mask]))
        r = np.nan_to_num(r, nan=0, posinf=0, neginf=0)
        _, score, _, loc = cv2.minMaxLoc(r)
        err = float((np.abs(sheet[loc[1]:loc[1] + h, loc[0]:loc[0] + w] - t).mean(2)
                     * mask).sum() / mask.sum())
        rects[name] = dict(x=int(loc[0]), y=int(loc[1]), w=w, h=h,
                           score=round(float(score), 4), err=round(err, 2))
    return rects


def cut_props(cake, rects, report):
    H, W = cake.shape[:2]
    for name, r in sorted(rects.items()):
        if name in OPAQUE:
            crop = cake[r["y"]:r["y"] + r["h"], r["x"]:r["x"] + r["w"]]
            rgba = np.dstack([crop, np.full(crop.shape[:2], 255, np.uint8)])
        else:
            x0 = max(r["x"] - MARGIN, 0)
            y0 = max(r["y"] - MARGIN, 0)
            x1 = min(r["x"] + r["w"] + MARGIN, W)
            y1 = min(r["y"] + r["h"] + MARGIN, H)
            rgba = key_sprite(cake[y0:y1, x0:x1])
            if rgba is None:
                report.append((name, "keyed to nothing"))
                continue
        save_rgba(os.path.join(OUT, name + ".png"), rgba)
        report.append((name, "%dx%d" % (rgba.shape[1], rgba.shape[0])))


def _cells(x0, x1, cols, rows=4):
    """Cell interior rects for a uniformly divided auto-tile sub-panel."""
    cw = (x1 - x0) / float(cols)
    ch = (PANEL_BOT - PANEL_TOP) / float(rows)
    out = []
    for rr in range(rows):
        for cc in range(cols):
            cx0 = int(round(x0 + cc * cw)) + CELL_INSET
            cx1 = int(round(x0 + (cc + 1) * cw)) - CELL_INSET
            cy0 = int(round(PANEL_TOP + rr * ch)) + CELL_INSET
            cy1 = int(round(PANEL_TOP + (rr + 1) * ch)) - CELL_INSET
            out.append((rr, cc, cx0, cy0, cx1, cy1))
    return out


def _tile(cake, rect):
    _, _, x0, y0, x1, y1 = rect
    return cv2.resize(cake[y0:y1, x0:x1], (TILE, TILE), interpolation=cv2.INTER_AREA)


def cut_floor(cake, report):
    d = os.path.join(OUT, "floor")
    os.makedirs(d, exist_ok=True)
    v = h = s = 0
    for rect in _cells(*SUB_PLANK, cols=6):
        rr, cc = rect[0], rect[1]
        tile = _tile(cake, rect)
        if rr == 3:
            name, s = "sponge_%d" % s, s + 1
        elif cc < 4:
            name, v = "plank_v_%d" % v, v + 1
        else:
            name, h = "plank_h_%d" % h, h + 1
        save_rgb(os.path.join(d, name + ".png"), tile)
    for prefix, span in (("tat_l", SUB_TAT_L), ("tat_d", SUB_TAT_D)):
        for rect in _cells(*span, cols=4):
            save_rgb(os.path.join(d, "%s_r%dc%d.png" % (prefix, rect[0], rect[1])),
                     _tile(cake, rect))
    report.append(("floor/", "%d plank_v, %d plank_h, %d sponge, 2x16 tatami" % (v, h, s)))


def cut_wall(cake, report):
    d = os.path.join(OUT, "wall")
    os.makedirs(d, exist_ok=True)
    for name, x, w in WALL_PARTS:
        strip = cake[WALL_Y:WALL_Y + WALL_H, x:x + w]
        half = cv2.resize(strip, (w // 2, WALL_H // 2), interpolation=cv2.INTER_AREA)
        save_rgb(os.path.join(d, name + ".png"), half)
        report.append(("wall/" + name, "%dx%d" % (half.shape[1], half.shape[0])))


def main():
    os.makedirs(OUT, exist_ok=True)
    rects = locate_props()
    cake_raw = load_rgb(CAKE_SHEET)
    # The auto-tile panel is left RULED on purpose: its tiles are cut from the
    # cell INTERIORS (CELL_INSET), so the lattice never makes it into a tile,
    # and the strawberry tatami carries thin blue weave stripes a few px inside
    # each cell line that a de-rule pass would happily mistake for lattice.
    keep = [r for r in panels(cake_raw) if r[:2] != FLOOR_PANEL[:2]]
    cake = derule(cake_raw, keep)
    report = []
    cut_props(cake, rects, report)
    cut_floor(cake, report)
    cut_wall(cake, report)
    json.dump(rects, open(os.path.join(OUT, "_rects.json"), "w"), indent=1)
    for n, v in report:
        print("%-24s %s" % (n, v))
    print("total files:", len(report))


if __name__ == "__main__":
    main()
