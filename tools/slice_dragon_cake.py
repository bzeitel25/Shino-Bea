#!/usr/bin/env python3
"""
slice_dragon_cake.py -- Run 171: cut Assets/Tilesets/DragonCake_props/

Source sheets (both catalogue pages -- see tools/sheet_clean.py):
    Dragon Cake Tileset.png           interior: floor auto-tile, candy flora,
                                      decorations, dragon assets, baker's kit
    Dragon Cake Exterior Tileset.png  traversal: cake terrain, climbing aids,
                                      hazards, background effects

Unlike the Cake-Dojo sheet there is no existing prop set to copy a cut list
from, so props are found by BLOBS rather than by cells: de-rule the page, mask
everything that is not the cell slate / page background, dilate so the pieces of
one prop (a lollipop and its stick, a scatter of jelly beans) merge into a
single component, then take each component's bounding box.  That is immune to
the panels' irregular cell pitches.

Blobs are emitted as `blob_<n>.png` plus `_contact.png` (a labelled contact
sheet); NAMES below then renames the ones the game actually uses.  Re-running is
idempotent -- the blob numbering is deterministic (sorted by panel, then row
band, then x).

Ground tiles are cut separately from the floor auto-tile panel's cell grid,
inset past the lattice, at 64px (2x supersample of a 32px world cell):
    icing_*    walkable vanilla-icing floor, gumdrops and sprinkles
    choc_*     devil's-food crumb -- the apron outside the arena
    crack_*    cracked chocolate -- the chasms (V_WATER cells)
    sponge_*   sponge-and-jam layer strips (accent band)
"""
import cv2
import json
import numpy as np
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sheet_clean import load_rgb, derule, key_sprite, save_rgba, save_rgb, panels

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TS = os.path.join(ROOT, "Assets", "Tilesets")
INNER = os.path.join(TS, "Dragon Cake Tileset.png")
OUTER = os.path.join(TS, "Dragon Cake Exterior Tileset.png")
OUT = os.path.join(TS, "DragonCake_props")

# ── floor auto-tile panel (interior sheet) ───────────────────────────────────
FLOOR_PANEL = (37, 85, 1349, 316)
FLOOR_TOP, FLOOR_BOT = 85, 401
# (prefix, x0_abs, x1_abs, cols, rows_used) -- rows_used excludes the row-3
# bottom-edge strips, which are cap tiles rather than fill.
FLOOR_SUBS = [
    ("choc", 38, 508, 6, 3),
    ("crack", 518, 820, 4, 3),
    ("icing", 829, 1073, 3, 3),
    ("sugar", 1081, 1384, 4, 3),
]
CELL_INSET = 9
CELL_PX = 64

MIN_BLOB = 900          # px of opaque art -- below this it is a speck, not a prop
MERGE = 3               # dilation radius that fuses the parts of one prop

# Blob -> shipped name. Read off tools' _contact.png once; anything not listed
# stays a blob_* file and is simply unused by the game.
NAMES = {
    # ── interior sheet: candy flora, decorations, dragon assets ──
    "in_0": "cgum_1", "in_1": "cgum_2", "in_2": "cgum_3",
    "in_5": "cstack_donuts", "in_6": "cstack_berry", "in_11": "cstack_berry2",
    "in_7": "clicorice_1", "in_8": "clicorice_2", "in_12": "clicorice_3",
    "in_9": "cbranch_1", "in_10": "cbranch_2", "in_18": "cvine_1",
    "in_13": "clolli_1", "in_22": "clolli_2",
    "in_14": "cjelly_1", "in_45": "cgems",
    "in_16": "clog_1", "in_17": "clog_2",
    "in_19": "cspike_1", "in_20": "cmarsh_1", "in_21": "cmint_1",
    "in_23": "cdonut_1", "in_24": "cdonut_2", "in_26": "cdonut_3", "in_27": "cdonut_4",
    "in_25": "cfruit_1", "in_28": "ctable_cakes",
    "in_29": "cbanner_dragon", "in_30": "cbanner_cake",
    "in_31": "cbanner_castle", "in_32": "cbanner_fruit",
    "in_35": "clamp_1", "in_47": "cegg_gold",
    "in_55": "ctorch_f0", "in_56": "ctorch_f1",
    "in_57": "cdrip_1", "in_58": "cdrip_2",
    # ── exterior sheet: traversal terrain, hazards, dragon relics ──
    "ex_11": "cbean_1", "ex_12": "cbean_2", "ex_13": "cbean_3",
    "ex_14": "cspike_2", "ex_15": "cspike_3", "ex_44": "cspike_6",
    "ex_45": "cspike_4", "ex_49": "cspike_5",
    "ex_16": "cdonut_5", "ex_17": "cdonut_6", "ex_18": "cdonut_7",
    "ex_25": "cdonut_8", "ex_40": "cdonut_9", "ex_41": "cdonut_10",
    "ex_57": "cdonut_11", "ex_58": "cdonut_12",
    "ex_19": "cberry_1", "ex_31": "cberry_2",
    "ex_20": "cgate_1", "ex_59": "cgate_2", "ex_21": "ctorii_1",
    "ex_22": "cgem_1", "ex_23": "cgem_2", "ex_24": "cgem_3",
    "ex_26": "cjelly_2", "ex_60": "cjelly_3", "ex_62": "cjelly_4",
    "ex_30": "cslice_1", "ex_37": "cslice_2", "ex_38": "cslice_3", "ex_54": "cslice_4",
    "ex_32": "chorn_1", "ex_33": "cskull_1", "ex_34": "cskull_2", "ex_35": "cstatue_1",
    "ex_36": "cpillar_1", "ex_39": "ccake_1", "ex_53": "ccake_2",
    "ex_50": "csplat_1", "ex_51": "csplat_2",
    "ex_52": "ccream_1", "ex_56": "ccream_2",
    "ex_61": "cwaffle_1",
    "ex_63": "ccloud_1", "ex_64": "ccloud_2", "ex_67": "ccloud_3",
    "ex_65": "csparkle",
}

def slice_ground(sheet, report):
    ch = (FLOOR_BOT - FLOOR_TOP) / 4.0
    for prefix, x0, x1, cols, rows in FLOOR_SUBS:
        cw = (x1 - x0) / float(cols)
        n = 0
        for r in range(rows):
            for c in range(cols):
                cx0 = int(round(x0 + c * cw)) + CELL_INSET
                cx1 = int(round(x0 + (c + 1) * cw)) - CELL_INSET
                cy0 = int(round(FLOOR_TOP + r * ch)) + CELL_INSET
                cy1 = int(round(FLOOR_TOP + (r + 1) * ch)) - CELL_INSET
                tile = cv2.resize(sheet[cy0:cy1, cx0:cx1], (CELL_PX, CELL_PX),
                                  interpolation=cv2.INTER_AREA)
                save_rgb(os.path.join(OUT, "ground", "%s_%d.png" % (prefix, n)), tile)
                n += 1
        report.append(("ground/%s_0..%d" % (prefix, n - 1), "%dx%d" % (CELL_PX, CELL_PX)))


def slice_blobs(sheet, rects, tag, start, report):
    """Cut every prop-shaped blob out of the given panels. Returns next index."""
    idx = start
    made = []
    for (px, py, pw, ph) in rects:
        sub = sheet[py:py + ph, px:px + pw]
        # Cell slate + page background are the two darkest flat tones on the page.
        med = np.median(sub.reshape(-1, 3), axis=0)
        fg = (np.abs(sub.astype(int) - med).max(2) > 26).astype(np.uint8)
        fg = cv2.morphologyEx(fg, cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))
        grown = cv2.dilate(fg, np.ones((MERGE * 2 + 1,) * 2, np.uint8))
        n, lab, stats, _ = cv2.connectedComponentsWithStats(grown, 8)
        boxes = []
        for i in range(1, n):
            x, y, w, h, area = stats[i]
            if (fg[y:y + h, x:x + w] * (lab[y:y + h, x:x + w] == i)).sum() < MIN_BLOB:
                continue
            if w > pw * 0.92 and h > ph * 0.92:
                continue                       # the whole panel = an auto-tile block
            boxes.append((x, y, w, h))
        boxes.sort(key=lambda b: (b[1] // 90, b[0]))
        for (x, y, w, h) in boxes:
            pad = 4
            x0 = max(px + x - pad, 0)
            y0 = max(py + y - pad, 0)
            crop = sheet[y0:min(py + y + h + pad, sheet.shape[0]),
                         x0:min(px + x + w + pad, sheet.shape[1])]
            rgba = key_sprite(crop)
            if rgba is None or rgba.shape[0] < 12 or rgba.shape[1] < 12:
                continue
            name = NAMES.get("%s_%d" % (tag, idx), "blob_%s_%d" % (tag, idx))
            save_rgba(os.path.join(OUT, name + ".png"), rgba)
            made.append((name, rgba.shape[1], rgba.shape[0]))
            idx += 1
    report.append(("%s blobs" % tag, str(len(made))))
    return idx, made


def contact(made, path, cols=10, cell=170):
    rows = (len(made) + cols - 1) // cols
    sheet = np.full((rows * (cell + 16), cols * cell, 3), 64, np.uint8)
    for i, (name, w, h) in enumerate(made):
        im = cv2.imread(os.path.join(OUT, name + ".png"), cv2.IMREAD_UNCHANGED)
        s = min((cell - 12) / im.shape[1], (cell - 12) / im.shape[0], 1.0)
        im = cv2.resize(im, (max(1, int(im.shape[1] * s)), max(1, int(im.shape[0] * s))))
        cy = (i // cols) * (cell + 16)
        cx = (i % cols) * cell
        oy = cy + (cell - im.shape[0]) // 2
        ox = cx + (cell - im.shape[1]) // 2
        a = im[:, :, 3:4].astype(float) / 255.0
        dst = sheet[oy:oy + im.shape[0], ox:ox + im.shape[1]]
        sheet[oy:oy + im.shape[0], ox:ox + im.shape[1]] = (
            dst * (1 - a) + im[:, :, :3] * a).astype(np.uint8)
        cv2.putText(sheet, name.replace("blob_", ""), (cx + 4, cy + cell + 12),
                    cv2.FONT_HERSHEY_PLAIN, 0.85, (255, 255, 120), 1)
    cv2.imwrite(path, sheet)


def main():
    os.makedirs(os.path.join(OUT, "ground"), exist_ok=True)
    report = []
    inner_raw = load_rgb(INNER)
    inner = derule(inner_raw, [r for r in panels(inner_raw) if r[:2] != FLOOR_PANEL[:2]])
    slice_ground(inner_raw, report)

    # Interior: candy flora + decorations + dragon assets + baker's kit
    # (everything except the two auto-tile panels along the top).
    inner_panels = [r for r in panels(inner_raw) if r[1] > 450]
    idx, made = slice_blobs(inner, inner_panels, "in", 0, report)

    outer_raw = load_rgb(OUTER)
    outer = derule(outer_raw, panels(outer_raw, 30000))
    outer_panels = panels(outer_raw, 30000)
    _, made2 = slice_blobs(outer, outer_panels, "ex", 0, report)

    contact(made + made2, os.path.join(OUT, "_contact.png"))
    json.dump([m[0] for m in made + made2],
              open(os.path.join(OUT, "_blobs.json"), "w"), indent=1)
    for n, v in report:
        print("%-26s %s" % (n, v))


if __name__ == "__main__":
    main()
