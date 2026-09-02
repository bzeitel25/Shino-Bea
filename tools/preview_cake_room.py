#!/usr/bin/env python3
"""
preview_cake_room.py -- Run 171: offline look at a Dragon Cake climb room.

No Godot on the build box, so this fakes a DreamLayout (icing floor, a chocolate
chasm, void bands) and runs the same tile pick + prop placement rules
CakeTileset.gd uses, from the same art, so the biome can be eyeballed before it
ships. Not a simulator -- a sanity check that the tiles seam, the palette reads,
and the border skyline is the right scale.
"""
import os
import random

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
D = os.path.join(ROOT, "Assets", "Tilesets", "DragonCake_props")
CELL = 32
GW, GH = 44, 32

ICING = ["sugar_8", "sugar_10", "sugar_5", "sugar_2", "sugar_7", "sugar_4",
         "sugar_0", "sugar_9", "icing_0", "icing_1"]
CHOC = ["choc_%d" % i for i in (0, 1, 2, 3, 6, 7, 8, 9, 12, 13, 14, 15)]
CRACK = ["crack_%d" % i for i in range(8)]
OBST = ["clog_1", "clog_2", "cdonut_9", "cdonut_10", "cdonut_8", "ccake_1",
        "cslice_3", "cwaffle_1", "cmint_1", "cmarsh_1", "cgum_3", "cstack_donuts"]
ACCENT = ["cspike_1", "cspike_2", "cspike_5", "cvine_1", "clolli_1", "cstatue_1",
          "cskull_1", "cpillar_1"]
DECOR = ["cjelly_1", "cjelly_3", "cgems", "csplat_1", "csplat_2", "ccream_1", "csparkle"]
FRAME_BIG = ["ccake_1", "ccake_2", "cpillar_1", "cslice_3", "cslice_1"]
FRAME_MID = ["cdonut_9", "cstack_donuts", "cstack_berry", "cslice_2", "cberry_1"]


def g(name):
    return np.array(Image.open(os.path.join(D, "ground", name + ".png")).convert("RGB").resize((CELL, CELL), Image.LANCZOS))


def p(name):
    return Image.open(os.path.join(D, name + ".png")).convert("RGBA")


def main():
    rnd = random.Random(9)
    icing, choc, crack = [g(n) for n in ICING], [g(n) for n in CHOC], [g(n) for n in CRACK]
    APRON = 8
    W, H = (GW + 2 * APRON) * CELL, (GH + 2 * APRON) * CELL
    arr = np.zeros((H, W, 3), np.uint8)
    val = [[1] * GW for _ in range(GH)]
    for j in range(GH):                       # a chocolate chasm across the room
        for i in range(GW):
            if 13 <= i <= 15 and 4 <= j <= GH - 10:
                val[j][i] = 2
            elif (j in (6, 7) and 20 <= i <= 34) or (i in (28, 29) and 12 <= j <= 24):
                val[j][i] = 0                 # void barrier bands
    for j in range(-APRON, GH + APRON):
        for i in range(-APRON, GW + APRON):
            inside = 0 <= i < GW and 0 <= j < GH
            pool = icing if inside and val[j][i] != 2 else (crack if inside else choc)
            t = pool[abs(hash((i * 73856093, j * 19349663))) % len(pool)]
            arr[(j + APRON) * CELL:(j + APRON + 1) * CELL,
                (i + APRON) * CELL:(i + APRON + 1) * CELL] = t
    canvas = Image.fromarray(arr).convert("RGBA")

    def put(name, wx, wy, cells, jitter=0):
        im = p(name)
        h = int(CELL * cells)
        s = h / im.height
        im = im.resize((max(1, int(im.width * s)), h), Image.LANCZOS)
        canvas.alpha_composite(im, (int(wx - im.width / 2) + jitter, int(wy - h)))

    def w(i, j):
        return ((i + APRON) * CELL + CELL // 2, (j + APRON) * CELL + CELL)

    def touches_floor(i, j):
        for di, dj in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)):
            a, b = i + di, j + dj
            if 0 <= a < GW and 0 <= b < GH and val[b][a] in (1, 3):
                return True
        return False

    for j in range(GH):                       # obstacles on every blocked edge cell
        for i in range(GW):
            if val[j][i] != 0 or not touches_floor(i, j):
                continue
            x, y = w(i, j)
            if rnd.random() < 0.16:
                put(rnd.choice(ACCENT), x, y, rnd.uniform(2.0, 2.7))
            else:
                put(rnd.choice(OBST), x, y, rnd.uniform(1.15, 1.6))
    for _ in range(70):                       # flat sweets on the icing
        i, j = rnd.randrange(GW), rnd.randrange(GH)
        if val[j][i] != 1:
            continue
        x, y = w(i, j)
        put(rnd.choice(DECOR), x, y, rnd.uniform(0.45, 0.7), rnd.randint(-9, 9))
    step = 54 / 32.0                          # FRAME_STEP in cells
    xs = [i * step for i in range(int(GW / step) + 1)]
    for fx in xs:                             # the cake skyline hugging the border
        for fy in (-0.6, GH - 0.4):
            x, y = w(fx, fy)
            put(rnd.choice(FRAME_BIG if rnd.random() < 0.7 else FRAME_MID), x, y,
                rnd.uniform(2.6, 3.5), rnd.randint(-8, 8))
    for fy in [j * step for j in range(int(GH / step) + 1)]:
        for fx in (-0.6, GW - 0.4):
            x, y = w(fx, fy)
            put(rnd.choice(FRAME_BIG if rnd.random() < 0.7 else FRAME_MID), x, y,
                rnd.uniform(2.6, 3.5), rnd.randint(-8, 8))
    out = os.path.expanduser("~/mnt/Shino & Bea/_tmp_preview/cake_climb_room.png")
    canvas.convert("RGB").save(out)
    print("wrote", out)


if __name__ == "__main__":
    main()
