#!/usr/bin/env python3
"""
sheet_clean.py -- Run 171 shared helper for slicing the cake tilesets.

Every master sheet in Assets/Tilesets is a *catalogue page*: art panels laid out
on a dark page background, each panel ruled into cells by a flat blue-grey
lattice (~3px, RGB ~ (118,126,145)).  Two things have to happen before a sprite
can be cut out of one:

  1. DE-RULE.  The lattice is OPAQUE -- painted over the art, not blended -- so
     it cannot be un-mixed, it has to be removed and filled.  We find it the
     safe way: per panel, a column (or row) is ruling only when a LARGE FRACTION
     of that whole column matches the lattice colour.  A blue stripe inside one
     tatami tile can never pass that test; a real 315px-tall grid line always
     does.  Ruled columns/rows are filled by linear interpolation between the
     nearest clean neighbours -- 3px out of a ~78px cell, invisible once the
     tile is scaled down.

  2. KEY.  Props are cut with a border flood-fill (fixed-range, 8-connected,
     seeded from every pixel of the crop border) so the page background and the
     cell slate go transparent while same-coloured pixels INSIDE the sprite are
     kept.  Two dilate passes then eat the anti-aliased fringe, leaving binary
     alpha like the rest of the project's prop sets.
"""
import cv2
import numpy as np
from collections import Counter

RULING = np.array([118, 126, 145])      # RGB of the lattice
RULE_TOL = 30                            # max per-channel distance to call it lattice
RULE_FRAC = 0.35                         # share of a column/row that must match
RULE_MAX_W = 8                           # a "line" is never thicker than this


def load_rgb(path):
    im = cv2.imread(path, cv2.IMREAD_UNCHANGED)
    if im is None:
        raise IOError(path)
    return im[:, :, :3][:, :, ::-1].copy()          # BGR -> RGB


def page_bg(rgb):
    corners = np.concatenate([rgb[0:8, 0:8].reshape(-1, 3), rgb[0:8, -8:].reshape(-1, 3)])
    return np.array(Counter(map(tuple, corners)).most_common(1)[0][0], dtype=int)


def panels(rgb, min_area=40000):
    """Bounding boxes of the big art panels (everything that is not page bg)."""
    bg = page_bg(rgb)
    d = np.abs(rgb.astype(int) - bg).sum(2)
    fg = (d > 26).astype(np.uint8)
    n, lab, stats, _ = cv2.connectedComponentsWithStats(fg, 8)
    out = [(int(s[0]), int(s[1]), int(s[2]), int(s[3])) for s in stats[1:] if s[4] > min_area]
    out.sort(key=lambda r: (r[1] // 100, r[0]))
    return out


def _line_groups(frac):
    idx = np.where(frac > RULE_FRAC)[0]
    groups, cur = [], []
    for i in idx:
        if cur and i - cur[-1] <= 1:
            cur.append(i)
        else:
            if cur:
                groups.append(cur)
            cur = [i]
    if cur:
        groups.append(cur)
    return [g for g in groups if len(g) <= RULE_MAX_W]


def _fill_runs(sub, groups, axis):
    """Linear-interpolate every ruled run from its nearest clean neighbours.

    Each group is grown by one pixel on both sides first: the lattice is
    anti-aliased, so its outermost texel usually falls just under RULE_FRAC and
    would otherwise survive as a ghost line.
    """
    n = sub.shape[1] if axis == 1 else sub.shape[0]
    line = (lambda i: sub[:, i]) if axis == 1 else (lambda i: sub[i])
    for g in groups:
        lo = max(g[0] - 1, 0)
        hi = min(g[-1] + 1, n - 1)
        a, b = lo - 1, hi + 1
        if a < 0 and b > n - 1:
            continue
        left = line(b).astype(float) if a < 0 else line(a).astype(float)
        right = line(a).astype(float) if b > n - 1 else line(b).astype(float)
        a = max(a, 0)
        b = min(b, n - 1)
        span = float(b - a)
        for k, i in enumerate(range(lo, hi + 1), start=1):
            t = k / span if span > 0 else 0.5
            v = np.rint(left * (1.0 - t) + right * t).astype(np.uint8)
            if axis == 1:
                sub[:, i] = v
            else:
                sub[i] = v


def derule(rgb, rects=None, passes=2):
    """Return a copy of `rgb` with the cell lattice removed inside every panel.

    Two passes: filling the vertical lines changes the horizontal statistics
    (and vice versa), so a single sweep leaves stubs where the two cross.
    """
    out = rgb.copy()
    for (x, y, w, h) in (rects if rects is not None else panels(rgb)):
        sub = out[y:y + h, x:x + w]
        for _ in range(passes):
            for axis in (1, 0):
                m = np.abs(sub.astype(int) - RULING).max(2) < RULE_TOL
                _fill_runs(sub, _line_groups(m.mean(0 if axis == 1 else 1)), axis=axis)
        out[y:y + h, x:x + w] = sub
    return out


def key_sprite(crop_rgb, tol=18, fringe_tol=34, fringe_passes=2):
    """Border flood-key -> RGBA with binary alpha, cropped to the sprite bbox."""
    h, w = crop_rgb.shape[:2]
    bgr = np.ascontiguousarray(crop_rgb[:, :, ::-1])
    mask = np.zeros((h + 2, w + 2), np.uint8)
    flags = 8 | cv2.FLOODFILL_MASK_ONLY | cv2.FLOODFILL_FIXED_RANGE | (255 << 8)
    seeds = ([(x, 0) for x in range(w)] + [(x, h - 1) for x in range(w)] +
             [(0, y) for y in range(h)] + [(w - 1, y) for y in range(h)])
    for (sx, sy) in seeds:
        if mask[sy + 1, sx + 1]:
            continue
        cv2.floodFill(bgr, mask, (sx, sy), 0, (tol,) * 3, (tol,) * 3, flags)
    bg = mask[1:h + 1, 1:w + 1] > 0

    if fringe_passes and bg.any():
        base = np.median(crop_rgb[bg].reshape(-1, 3).astype(int), axis=0)
        near = np.abs(crop_rgb.astype(int) - base).max(2) < fringe_tol
        for _ in range(fringe_passes):
            grown = cv2.dilate(bg.astype(np.uint8), np.ones((3, 3), np.uint8)) > 0
            bg = bg | (grown & near)

    rgba = np.dstack([crop_rgb, np.where(bg, 0, 255).astype(np.uint8)])
    ys, xs = np.where(rgba[:, :, 3] > 0)
    if len(xs) == 0:
        return None
    return rgba[ys.min():ys.max() + 1, xs.min():xs.max() + 1]


def save_rgba(path, rgba):
    cv2.imwrite(path, np.dstack([rgba[:, :, 2], rgba[:, :, 1], rgba[:, :, 0], rgba[:, :, 3]]))


def save_rgb(path, rgb):
    cv2.imwrite(path, np.ascontiguousarray(rgb[:, :, ::-1]))
