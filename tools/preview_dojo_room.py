#!/usr/bin/env python3
"""
preview_dojo_room.py -- Run 171: offline render of a dojo-shaped room.

There is no Godot on the build box, so this is how the Cake Dojo gets eyes on
it before it ships.  It re-implements, in Python and from the SAME constants,
what Dojo.gd / CakeDojoRoom.gd do at runtime:

  * DojoTerrain's floor bake  -- hash-picked plank tiles on the world grid plus
    nine-sliced tatami over the mat rects
  * DojoWallArt's north-wall runs -- feature section centred on its landmark,
    the rest filled from FILL_SEQ
  * the decor pass -- every _deco() call, foot-anchored and height-scaled

  python3 tools/preview_dojo_room.py cake   -> CakeDojo_props
  python3 tools/preview_dojo_room.py dojo   -> Dojo_props (regression check:
                                               should match the shipped hub)
"""
import os
import sys

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SETS = {"cake": "CakeDojo_props", "dojo": "Dojo_props"}

MAIN = (-480, -280, 960, 560)
SHINO = (180, -560, 300, 280)
BEA = (480, -280, 280, 280)
MATS = [((-240, -40, 480, 280), "tat_l"), ((255, -520, 170, 150), "tat_d"),
        ((555, -205, 170, 150), "tat_d")]
CELL = 64.0
TILE = 32
FACE_H = 155
FILL_SEQ = ["wall_shoji_a", "wall_shoji_b", "wall_plain_a", "wall_post",
            "wall_plain_b", "wall_shoji_a", "wall_plain_c"]
WALL_RUNS = [(-480, 180, -280, "wall_alcove", 0), (180, 480, -560, "wall_arch", 330),
             (480, 760, -280, "wall_arch", 620)]
WALL_T = 32
WALL_SEGS = [(-80, -280, 800, WALL_T), (440, -280, 80, WALL_T), (0, 280, 960, WALL_T),
             (-480, 0, WALL_T, 560), (480, -250, WALL_T, 60), (480, 70, WALL_T, 420),
             (180, -420, WALL_T, 280), (330, -560, 332, WALL_T), (480, -420, WALL_T, 280),
             (620, -280, 280, WALL_T), (760, -140, WALL_T, 280), (620, 0, 280, WALL_T)]
DECOR = [
    ("scroll_kanji_a", -420, -300, 64), ("lantern_paper_f0", -310, -336, 56),
    ("scroll_dragon", -140, -292, 112), ("scroll_kanji_b", 100, -300, 64),
    ("lantern_paper_f0", 155, -336, 56), ("rack_katana_a", 255, -240, 58),
    ("lantern_stone_a", -445, -130, 52), ("bamboo_a", -445, -40, 86),
    ("bamboo_c", -445, 60, 78), ("banner_map", 450, -70, 62),
    ("lantern_stone_c", 447, 110, 52), ("bamboo_cut_a", 450, 215, 66),
    ("table_low_b", -360, 195, 46), ("cushion_b", -425, 200, 20),
    ("cushion_c", -298, 200, 20), ("go_board", -362, 248, 32),
    ("zen_sand_a", 390, 212, 88), ("lantern_stone_d", 448, 180, 54),
    ("bonsai_f", 336, 228, 56), ("brazier", -262, 62, 50), ("rug_red", 0, 236, 42),
    ("trap_door", 285, -246, 44), ("scroll_kanji_c", 225, -568, 64),
    ("scroll_kanji_e", 430, -568, 64), ("rack_stand", 448, -482, 72),
    ("bedroll_a", 340, -432, 64), ("lantern_stone_b", 212, -372, 50),
    ("bonsai_d", 215, -318, 52), ("scroll_kanji_d", 543, -288, 62),
    ("scroll_kanji_f", 700, -288, 62), ("rug_green", 640, -118, 58),
    ("bedroll_a", 640, -122, 60), ("table_low_c", 560, -42, 42),
    ("cushion_a", 514, -26, 20), ("bonsai_b", 735, -42, 56),
]
VIEW = (-780, -780, 1820, 1340)      # x, y, w, h in world px


def load(d, name):
    p = os.path.join(d, name + ".png")
    return Image.open(p).convert("RGBA") if os.path.exists(p) else None


def gd_hash(ci, cj, n):
    """Stand-in for Godot's hash(Vector2i) -- any stable spread will do here."""
    h = (ci * 73856093) ^ (cj * 19349663)
    h = (h ^ (h >> 13)) * 1274126177 & 0xFFFFFFFF
    return (h ^ (h >> 16)) % n


def bake_floor(pdir, canvas, ox, oy):
    fdir = os.path.join(pdir, "floor")
    planks = [np.array(load(fdir, "plank_v_%d" % i)) for i in range(12)]
    planks = [p for p in planks if p is not None]
    mats = {}
    for key in ("tat_l", "tat_d"):
        block = [np.array(load(fdir, "%s_r%dc%d" % (key, r, c)))
                 for r in range(4) for c in range(4)]
        mats[key] = block if all(b is not None for b in block) else None

    def plank_px(wx, wy):
        idx = gd_hash(int(np.floor(wx / CELL)), int(np.floor(wy / CELL)), len(planks))
        return planks[idx][int(wy) % TILE, int(wx) % TILE]

    def tat_px(tiles, rect, wx, wy):
        lx, ly = int(wx - rect[0]), int(wy - rect[1])
        wpx, hpx = int(rect[2]), int(rect[3])
        block = TILE * 4
        if wpx <= block or hpx <= block:
            bx = min(int(lx * block / wpx), block - 1)
            by = min(int(ly * block / hpx), block - 1)
            return tiles[(by // TILE) * 4 + bx // TILE][by % TILE, bx % TILE]
        if lx < TILE and lx <= wpx - 1 - lx:
            col, sx = 0, min(lx, TILE - 1)
        elif wpx - 1 - lx < TILE:
            col, sx = 3, TILE - 1 - min(wpx - 1 - lx, TILE - 1)
        else:
            u = (lx - TILE) % (TILE * 2)
            col, sx = (1 if u < TILE else 2), u % TILE
        if ly < TILE and ly <= hpx - 1 - ly:
            row, sy = 0, min(ly, TILE - 1)
        elif hpx - 1 - ly < TILE:
            row, sy = 3, TILE - 1 - min(hpx - 1 - ly, TILE - 1)
        else:
            v = (ly - TILE) % (TILE * 2)
            row, sy = (1 if v < TILE else 2), v % TILE
        return tiles[row * 4 + col][sy, sx]

    arr = np.array(canvas)
    for (rx, ry, rw, rh) in (MAIN, SHINO, BEA):
        for wy in range(ry, ry + rh):
            for wx in range(rx, rx + rw):
                px = None
                for mr, kind in MATS:
                    if mr[0] <= wx < mr[0] + mr[2] and mr[1] <= wy < mr[1] + mr[3]:
                        px = tat_px(mats[kind], mr, wx, wy) if mats[kind] else None
                        break
                if px is None:
                    px = plank_px(wx, wy)
                arr[wy - oy, wx - ox] = px
    return Image.fromarray(arr)


def bake_wall_faces(pdir, canvas, ox, oy):
    wdir = os.path.join(pdir, "wall")
    for (x0, x1, base_y, feature, fcx) in WALL_RUNS:
        w = x1 - x0
        strip = Image.new("RGBA", (w, FACE_H), (0, 0, 0, 0))
        feat = load(wdir, feature)
        fx0 = fx1 = -1
        if feat:
            bbox = feat.split()[3].getbbox()
            feat = feat.crop((bbox[0], 0, bbox[2], FACE_H))
            fx0 = max(0, min(int(fcx - x0) - feat.width // 2, max(w - feat.width, 0)))
            fx1 = min(fx0 + feat.width, w)
            strip.paste(feat.crop((0, 0, fx1 - fx0, FACE_H)), (fx0, 0))
        cur, idx = 0, 0
        while cur < w:
            if fx0 >= 0 and fx0 <= cur < fx1:
                cur = fx1
                continue
            s = load(wdir, FILL_SEQ[idx % len(FILL_SEQ)])
            idx += 1
            limit = fx0 if (fx0 >= 0 and cur < fx0) else w
            if limit - cur < s.width:
                s = load(wdir, "wall_plain_b")
            take = min(s.width, limit - cur)
            if take <= 0:
                cur = limit
                continue
            strip.paste(s.crop((0, 0, take, FACE_H)), (cur, 0))
            cur += take
        canvas.alpha_composite(strip, (x0 - ox, base_y - FACE_H - oy))


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "cake"
    pdir = os.path.join(ROOT, "Assets", "Tilesets", SETS[which])
    ox, oy, vw, vh = VIEW
    canvas = Image.new("RGBA", (vw, vh), (18, 12, 20, 255))
    canvas = bake_floor(pdir, canvas, ox, oy)
    bake_wall_faces(pdir, canvas, ox, oy)
    d = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    for (cx, cy, cw, ch) in WALL_SEGS:                       # wall collision slabs
        d.paste((74, 48, 32, 255), (int(cx - cw / 2 - ox), int(cy - ch / 2 - oy),
                                    int(cx + cw / 2 - ox), int(cy + ch / 2 - oy)))
    canvas.alpha_composite(d)
    for name, fx, fy, h in DECOR:
        im = load(pdir, name)
        if im is None:
            print("MISSING", name)
            continue
        s = h / im.height
        im = im.resize((max(1, int(im.width * s)), h), Image.LANCZOS)
        canvas.alpha_composite(im, (int(fx - im.width / 2 - ox), int(fy - h - oy)))
    out = os.path.expanduser("~/mnt/Shino & Bea/_tmp_preview/room_%s.png" % which)
    canvas.convert("RGB").save(out)
    print("wrote", out)


if __name__ == "__main__":
    main()
