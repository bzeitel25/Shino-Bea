#!/usr/bin/env python3
"""
sprite_forge.py -- Shino & Bea sprite keyer / slicer / wirer.

One tool that takes a raw generated art sheet (or a single sprite) and produces
game-ready frames + the Godot SpriteFrames resource that wires them in. Built to
beat the old per-sheet slicers on three fronts:

  1. KEYING. Two engines:
       chroma  (default, for gen-art on a FLAT key colour -- magenta, or cyan
               for grape) -- per-pixel colour-distance key with SOFT alpha and
               EDGE DECONTAMINATION (spill removal), so edges keep their shape
               instead of being eaten by a binary dilate. Because it is
               per-pixel it also clears key-coloured GAPS enclosed by the sprite
               (between an arm and the torso) that a border flood-fill leaves
               opaque.
       flood   (legacy parity, for props on a ruled catalogue page) -- border
               flood-fill + fringe erosion, binary alpha. Delegates to
               tools/sheet_clean.py when present (incl. its de-rule pass).
     Never keys grey: the flat magenta/cyan convention exists precisely so the
     key colour never appears in the art (project rule: don't colour-key greys).

  2. SLICING. --grid RxC, or --auto-grid (finds frame gutters from empty-alpha
     runs -- no hardcoded pixel coords), or --blobs (connected components for
     prop pages), or --single. Every frame is re-cropped to its own content
     bbox so a wobbly source grid can't leave sprites off-centre.

  3. PLACEMENT + WIRING. Frames are normalised into a uniform cell anchored by
     FOOT (bottom-centre -- matches the game's Y-sort-by-foot rule), centre, or
     top, so an animation never jitters. Then it writes:
       - individual frame PNGs and/or a packed strip/atlas PNG,
       - a Godot 4 SpriteFrames .tres (the "wirer") -- plain text, re-imported
         by the editor on focus, no plugin required,
       - a labelled _contact.png to eyeball the cut,
       - a manifest.json (the hook a batch driver / MCP server calls).

Never upscales content above native resolution (project lock). Depends only on
opencv-python + numpy, which the repo's other tools already use.

Examples
--------
  # Bea idle+walk gen-art on magenta, 1 row x 4 frames, foot-anchored, wired:
  python sprite_forge.py "Bea_walk_raw.png" --key-color magenta --auto-grid \
      --anchor foot --out Assets/Sprites/bea --tres bea --anim walk --fps 10 --atlas

  # A single hero pose, soft-keyed, just the clean PNG:
  python sprite_forge.py bea_pose.png --key-color magenta --single \
      --out Assets/Sprites/bea --emit frames

  # Legacy prop page (parity with the old slicer):
  python sprite_forge.py "Some_props.png" --key flood --blobs --out out/props
"""
import argparse
import json
import os
import sys

import cv2
import numpy as np

KEY_PRESETS_RGB = {
    "magenta": (255, 0, 255),
    "cyan": (0, 255, 255),
    "green": (0, 255, 0),
    "grey": (153, 153, 153),
}


# ---------------------------------------------------------------------------
# IO helpers  (internally everything is BGRA float-friendly uint8, cv2-native)
# ---------------------------------------------------------------------------
def load_bgra(path):
    im = cv2.imread(path, cv2.IMREAD_UNCHANGED)
    if im is None:
        raise IOError("cannot read image: %s" % path)
    if im.ndim == 2:
        im = cv2.cvtColor(im, cv2.COLOR_GRAY2BGRA)
    elif im.shape[2] == 3:
        im = cv2.cvtColor(im, cv2.COLOR_BGR2BGRA)
    return im


def save_bgra(path, bgra):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    cv2.imwrite(path, bgra)


def rgb_to_bgr(rgb):
    return np.array([rgb[2], rgb[1], rgb[0]], dtype=float)


def resolve_key_color(spec, bgra):
    """spec: preset name, 'R,G,B', or 'auto' (sample the dominant border colour)."""
    if spec == "auto":
        b = bgra[:, :, :3]
        border = np.concatenate([
            b[0], b[-1], b[:, 0], b[:, -1]]).reshape(-1, 3)
        vals, counts = np.unique(border, axis=0, return_counts=True)
        return vals[counts.argmax()].astype(float)  # already BGR
    if spec in KEY_PRESETS_RGB:
        return rgb_to_bgr(KEY_PRESETS_RGB[spec])
    if "," in spec:
        r, g, b = (int(v) for v in spec.split(","))
        return rgb_to_bgr((r, g, b))
    raise ValueError("unknown --key-color: %s" % spec)


# ---------------------------------------------------------------------------
# Keying
# ---------------------------------------------------------------------------
def key_chroma(bgra, key_bgr, t_lo, t_hi, binary=False, decontaminate=True):
    """Per-pixel chroma key with soft alpha + spill removal.

    alpha ramps 0->1 as colour distance to the key goes t_lo -> t_hi. Pixels in
    the transition band get the key colour's contribution unmultiplied out of
    their RGB so no coloured halo survives.
    """
    bgr = bgra[:, :, :3].astype(np.float32)
    dist = np.sqrt(((bgr - key_bgr.astype(np.float32)) ** 2).sum(axis=2))

    if binary:
        mid = 0.5 * (t_lo + t_hi)
        alpha = np.where(dist >= mid, 255.0, 0.0)
    else:
        alpha = np.clip((dist - t_lo) / max(t_hi - t_lo, 1e-6), 0.0, 1.0) * 255.0

    out = bgra.copy()
    # respect any real transparency already in the source
    if bgra.shape[2] == 4:
        alpha = np.minimum(alpha, bgra[:, :, 3].astype(np.float32))

    if decontaminate and not binary:
        a = (alpha / 255.0)[:, :, None]
        edge = (a[:, :, 0] > 0.0) & (a[:, :, 0] < 1.0)
        if edge.any():
            # F = (C - (1-a)*K) / a   (unmultiply the key spill)
            fg = np.where(a > 1e-3, (bgr - (1.0 - a) * key_bgr.astype(np.float32)) / np.maximum(a, 1e-3), bgr)
            fg = np.clip(fg, 0, 255)
            for c in range(3):
                ch = out[:, :, c].astype(np.float32)
                ch[edge] = fg[:, :, c][edge]
                out[:, :, c] = ch.astype(np.uint8)

    out[:, :, 3] = alpha.astype(np.uint8)
    return out


def key_flood(bgra, tol=18, fringe_tol=34, fringe_passes=2, derule=False):
    """Legacy border flood-fill key (binary alpha). Uses sheet_clean if available."""
    rgb = cv2.cvtColor(bgra, cv2.COLOR_BGRA2RGB)
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import sheet_clean  # noqa
        if derule:
            rgb = sheet_clean.derule(rgb)
        rgba = sheet_clean.key_sprite(rgb, tol=tol, fringe_tol=fringe_tol,
                                      fringe_passes=fringe_passes)
        if rgba is None:
            return None
        return cv2.cvtColor(rgba, cv2.COLOR_RGBA2BGRA)
    except ImportError:
        pass
    # standalone fallback: 8-connected border flood, binary alpha
    h, w = bgra.shape[:2]
    work = np.ascontiguousarray(bgra[:, :, :3])
    mask = np.zeros((h + 2, w + 2), np.uint8)
    flags = 8 | cv2.FLOODFILL_MASK_ONLY | cv2.FLOODFILL_FIXED_RANGE | (255 << 8)
    seeds = ([(x, 0) for x in range(w)] + [(x, h - 1) for x in range(w)] +
             [(0, y) for y in range(h)] + [(w - 1, y) for y in range(h)])
    for sx, sy in seeds:
        if mask[sy + 1, sx + 1]:
            continue
        cv2.floodFill(work, mask, (sx, sy), 0, (tol,) * 3, (tol,) * 3, flags)
    bg = mask[1:h + 1, 1:w + 1] > 0
    out = bgra.copy()
    out[:, :, 3] = np.where(bg, 0, 255).astype(np.uint8)
    return out


# ---------------------------------------------------------------------------
# Slicing
# ---------------------------------------------------------------------------
def _content_bbox(alpha, thresh=8):
    ys, xs = np.where(alpha > thresh)
    if len(xs) == 0:
        return None
    return xs.min(), ys.min(), xs.max() + 1, ys.max() + 1


def _spans(coverage, gap_min=1):
    """Return [start,end) spans of non-empty runs, ignoring gaps of key colour."""
    on = coverage > 0
    spans, s = [], None
    for i, v in enumerate(on):
        if v and s is None:
            s = i
        elif not v and s is not None:
            spans.append((s, i))
            s = None
    if s is not None:
        spans.append((s, len(on)))
    # merge spans separated by < gap_min empty px (anti-alias flicker)
    merged = []
    for sp in spans:
        if merged and sp[0] - merged[-1][1] < gap_min:
            merged[-1] = (merged[-1][0], sp[1])
        else:
            merged.append(list(sp))
    return [tuple(m) for m in merged]


def slice_auto_grid(keyed, min_frac=0.004, gap_min=2):
    """Find frames from empty-alpha gutters. Returns list of (x0,y0,x1,y1)."""
    a = keyed[:, :, 3]
    row_cov = (a > 8).sum(axis=1).astype(float)
    row_spans = _spans(row_cov, gap_min)
    frames = []
    for (ry0, ry1) in row_spans or [(0, a.shape[0])]:
        band = a[ry0:ry1]
        col_cov = (band > 8).sum(axis=0).astype(float)
        col_spans = _spans(col_cov, gap_min)
        for (cx0, cx1) in col_spans or [(0, a.shape[1])]:
            sub = keyed[ry0:ry1, cx0:cx1, 3]
            bb = _content_bbox(sub)
            if bb is None:
                continue
            x0, y0, x1, y1 = bb
            if (x1 - x0) * (y1 - y0) < min_frac * a.shape[0] * a.shape[1]:
                continue
            frames.append((cx0 + x0, ry0 + y0, cx0 + x1, ry0 + y1))
    return frames


def slice_grid(keyed, rows, cols):
    h, w = keyed.shape[:2]
    ch, cw = h / float(rows), w / float(cols)
    frames = []
    for r in range(rows):
        for c in range(cols):
            y0, y1 = int(round(r * ch)), int(round((r + 1) * ch))
            x0, x1 = int(round(c * cw)), int(round((c + 1) * cw))
            bb = _content_bbox(keyed[y0:y1, x0:x1, 3])
            if bb is None:
                continue
            bx0, by0, bx1, by1 = bb
            frames.append((x0 + bx0, y0 + by0, x0 + bx1, y0 + by1))
    return frames


def slice_blobs(keyed, min_area=900, merge=3):
    a = (keyed[:, :, 3] > 8).astype(np.uint8)
    a = cv2.morphologyEx(a, cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))
    grown = cv2.dilate(a, np.ones((merge * 2 + 1,) * 2, np.uint8))
    n, lab, stats, _ = cv2.connectedComponentsWithStats(grown, 8)
    boxes = []
    for i in range(1, n):
        x, y, w, h, _ = stats[i]
        if (a[y:y + h, x:x + w] * (lab[y:y + h, x:x + w] == i)).sum() < min_area:
            continue
        boxes.append((x, y, x + w, y + h))
    boxes.sort(key=lambda b: (b[1] // 90, b[0]))
    return boxes


# ---------------------------------------------------------------------------
# Placement / normalisation
# ---------------------------------------------------------------------------
def place(frame_bgra, cell_w, cell_h, anchor):
    """Composite a content crop into a uniform transparent cell by anchor."""
    fh, fw = frame_bgra.shape[:2]
    canvas = np.zeros((cell_h, cell_w, 4), np.uint8)
    x = (cell_w - fw) // 2
    if anchor == "foot":
        y = cell_h - fh
    elif anchor == "top":
        y = 0
    else:  # center
        y = (cell_h - fh) // 2
    x, y = max(x, 0), max(y, 0)
    fw, fh = min(fw, cell_w - x), min(fh, cell_h - y)
    canvas[y:y + fh, x:x + fw] = frame_bgra[:fh, :fw]
    return canvas


def normalize(keyed, boxes, anchor, pad, cell=None):
    crops = [keyed[y0:y1, x0:x1] for (x0, y0, x1, y1) in boxes]
    if cell:
        cw, ch = cell
    else:
        cw = max(c.shape[1] for c in crops) + 2 * pad
        ch = max(c.shape[0] for c in crops) + 2 * pad
    return [place(c, cw, ch, anchor) for c in crops], (cw, ch)


# ---------------------------------------------------------------------------
# Wiring  (Godot 4 SpriteFrames .tres, plain text)
# ---------------------------------------------------------------------------
def write_spriteframes_individual(path, frame_res_paths, anim, fps, loop):
    load_steps = len(frame_res_paths) + 1
    lines = ['[gd_resource type="SpriteFrames" load_steps=%d format=3]' % load_steps, ""]
    for i, rp in enumerate(frame_res_paths):
        lines.append('[ext_resource type="Texture2D" path="%s" id="%d"]' % (rp, i + 1))
    lines += ["", "[resource]", "animations = [{"]
    frames = ", ".join('{\n"duration": 1.0,\n"texture": ExtResource("%d")\n}' % (i + 1)
                       for i in range(len(frame_res_paths)))
    lines.append('"frames": [%s],' % frames)
    lines.append('"loop": %s,' % ("true" if loop else "false"))
    lines.append('"name": &"%s",' % anim)
    lines.append('"speed": %s' % float(fps))
    lines += ["}]", ""]
    _write(path, "\n".join(lines))


def write_spriteframes_atlas(path, sheet_res_path, regions, anim, fps, loop):
    """regions: list of (x,y,w,h) into a single packed sheet."""
    load_steps = len(regions) + 2
    lines = ['[gd_resource type="SpriteFrames" load_steps=%d format=3]' % load_steps, ""]
    lines.append('[ext_resource type="Texture2D" path="%s" id="1"]' % sheet_res_path)
    lines.append("")
    for i, (x, y, w, h) in enumerate(regions):
        lines.append('[sub_resource type="AtlasTexture" id="a%d"]' % i)
        lines.append('atlas = ExtResource("1")')
        lines.append('region = Rect2(%d, %d, %d, %d)' % (x, y, w, h))
        lines.append("")
    lines += ["[resource]", "animations = [{"]
    frames = ", ".join('{\n"duration": 1.0,\n"texture": SubResource("a%d")\n}' % i
                       for i in range(len(regions)))
    lines.append('"frames": [%s],' % frames)
    lines.append('"loop": %s,' % ("true" if loop else "false"))
    lines.append('"name": &"%s",' % anim)
    lines.append('"speed": %s' % float(fps))
    lines += ["}]", ""]
    _write(path, "\n".join(lines))


def _write(path, text):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def pack_strip(cells):
    """Lay uniform cells left-to-right. Returns (sheet_bgra, regions)."""
    cw, ch = cells[0].shape[1], cells[0].shape[0]
    sheet = np.zeros((ch, cw * len(cells), 4), np.uint8)
    regions = []
    for i, c in enumerate(cells):
        sheet[:, i * cw:(i + 1) * cw] = c
        regions.append((i * cw, 0, cw, ch))
    return sheet, regions


def contact_sheet(cells, path, cols=8, bg=64):
    n = len(cells)
    cols = min(cols, n) or 1
    rows = (n + cols - 1) // cols
    cw, ch = cells[0].shape[1], cells[0].shape[0]
    pad = 8
    sheet = np.full((rows * (ch + pad + 14), cols * (cw + pad), 3), bg, np.uint8)
    for i, c in enumerate(cells):
        r, k = divmod(i, cols)
        oy, ox = r * (ch + pad + 14) + pad, k * (cw + pad) + pad // 2
        a = c[:, :, 3:4].astype(float) / 255.0
        dst = sheet[oy:oy + ch, ox:ox + cw]
        sheet[oy:oy + ch, ox:ox + cw] = (dst * (1 - a) + c[:, :, :3] * a).astype(np.uint8)
        cv2.putText(sheet, str(i), (ox + 2, oy + ch + 11),
                    cv2.FONT_HERSHEY_PLAIN, 0.9, (120, 255, 255), 1)
    cv2.imwrite(path, sheet)


# ---------------------------------------------------------------------------
# res:// path helper
# ---------------------------------------------------------------------------
def res_path_for(file_path, res_prefix, out_dir):
    if res_prefix:
        return res_prefix.rstrip("/") + "/" + os.path.basename(file_path)
    # try to infer from an "Assets" segment in the path
    parts = os.path.abspath(file_path).replace("\\", "/").split("/")
    if "Assets" in parts:
        i = parts.index("Assets")
        return "res://" + "/".join(parts[i:])
    return "res://" + os.path.basename(file_path)


# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------
def forge(a):
    bgra = load_bgra(a.input)

    if a.key == "chroma":
        key_bgr = resolve_key_color(a.key_color, bgra)
        keyed = key_chroma(bgra, key_bgr, a.t_lo, a.t_hi,
                           binary=(a.alpha == "binary"), decontaminate=not a.no_decontaminate)
    elif a.key == "flood":
        keyed = key_flood(bgra, derule=a.derule)
        if keyed is None:
            raise SystemExit("flood key produced no sprite")
    else:  # none
        keyed = bgra if bgra.shape[2] == 4 else cv2.cvtColor(bgra, cv2.COLOR_BGR2BGRA)

    if a.single:
        bb = _content_bbox(keyed[:, :, 3])
        boxes = [bb] if bb else []
    elif a.grid:
        r, c = (int(v) for v in a.grid.lower().split("x"))
        boxes = slice_grid(keyed, r, c)
    elif a.blobs:
        boxes = slice_blobs(keyed)
    else:  # auto-grid (default for sheets)
        boxes = slice_auto_grid(keyed)
    if not boxes:
        raise SystemExit("no frames found -- check --key-color / slicing mode")

    cell = None
    if a.cell:
        cw, ch = (int(v) for v in a.cell.lower().split("x"))
        cell = (cw, ch)
    cells, (cw, ch) = normalize(keyed, boxes, a.anchor, a.pad, cell)

    os.makedirs(a.out, exist_ok=True)
    made = {"input": a.input, "frames": len(cells), "cell": [cw, ch],
            "anchor": a.anchor, "key": a.key, "outputs": []}

    frame_paths = []
    if a.emit in ("frames", "both"):
        for i, c in enumerate(cells):
            fp = os.path.join(a.out, "%s_%d.png" % (a.name or "frame", i))
            save_bgra(fp, c)
            frame_paths.append(fp)
            made["outputs"].append(fp)

    sheet_path, regions = None, None
    if a.emit in ("strip", "both") or a.atlas:
        sheet, regions = pack_strip(cells)
        sheet_path = os.path.join(a.out, "%s_sheet.png" % (a.name or "frames"))
        save_bgra(sheet_path, sheet)
        made["outputs"].append(sheet_path)

    if a.contact:
        cpath = os.path.join(a.out, "_contact.png")
        contact_sheet(cells, cpath)
        made["contact"] = cpath

    if a.tres:
        tres_path = os.path.join(a.out, a.tres + ".tres")
        if a.atlas:
            sp = res_path_for(sheet_path, a.res_prefix, a.out)
            write_spriteframes_atlas(tres_path, sp, regions, a.anim, a.fps, not a.no_loop)
        else:
            if not frame_paths:  # need individual frames for non-atlas .tres
                for i, c in enumerate(cells):
                    fp = os.path.join(a.out, "%s_%d.png" % (a.name or "frame", i))
                    save_bgra(fp, c)
                    frame_paths.append(fp)
            rps = [res_path_for(fp, a.res_prefix, a.out) for fp in frame_paths]
            write_spriteframes_individual(tres_path, rps, a.anim, a.fps, not a.no_loop)
        made["tres"] = tres_path

    if a.manifest:
        _write(os.path.join(a.out, "manifest.json"), json.dumps(made, indent=2))

    print("forged %d frame(s) @ %dx%d (anchor=%s) -> %s"
          % (len(cells), cw, ch, a.anchor, a.out))
    if a.tres:
        print("wired SpriteFrames: %s (anim=%s, fps=%s, atlas=%s)"
              % (made["tres"], a.anim, a.fps, a.atlas))
    return made


def build_parser():
    p = argparse.ArgumentParser(description="Shino & Bea sprite keyer/slicer/wirer")
    p.add_argument("input")
    p.add_argument("--out", default="out", help="output directory")
    p.add_argument("--name", default="", help="basename for emitted frames/sheet")
    # keying
    p.add_argument("--key", choices=["chroma", "flood", "none"], default="chroma")
    p.add_argument("--key-color", default="magenta",
                   help="preset (magenta|cyan|green|grey), 'R,G,B', or 'auto'")
    p.add_argument("--alpha", choices=["soft", "binary"], default="soft")
    p.add_argument("--t-lo", type=float, default=70.0, help="chroma dist -> fully keyed")
    p.add_argument("--t-hi", type=float, default=140.0, help="chroma dist -> fully opaque")
    p.add_argument("--no-decontaminate", action="store_true", help="skip spill removal")
    p.add_argument("--derule", action="store_true", help="flood mode: strip cell lattice first")
    # slicing
    p.add_argument("--single", action="store_true", help="whole image is one sprite")
    p.add_argument("--grid", help="explicit slice, e.g. 2x4 (RxC)")
    p.add_argument("--auto-grid", action="store_true", help="detect frames from gutters (default)")
    p.add_argument("--blobs", action="store_true", help="connected-component prop extraction")
    # placement
    p.add_argument("--anchor", choices=["foot", "center", "top"], default="foot")
    p.add_argument("--pad", type=int, default=2, help="transparent margin around content")
    p.add_argument("--cell", help="force uniform cell WxH, e.g. 128x128")
    # output / wiring
    p.add_argument("--emit", choices=["frames", "strip", "both"], default="frames")
    p.add_argument("--atlas", action="store_true", help="pack one sheet + AtlasTexture .tres")
    p.add_argument("--tres", help="write SpriteFrames .tres with this basename")
    p.add_argument("--anim", default="default", help=".tres animation name")
    p.add_argument("--fps", type=float, default=10.0, help=".tres animation speed")
    p.add_argument("--no-loop", action="store_true", help=".tres animation does not loop")
    p.add_argument("--res-prefix", default="",
                   help="res:// path for emitted textures (else inferred from Assets/)")
    p.add_argument("--contact", action="store_true", help="write _contact.png proof")
    p.add_argument("--manifest", action="store_true", help="write manifest.json")
    return p


def main():
    a = build_parser().parse_args()
    forge(a)


if __name__ == "__main__":
    main()
