"""Strip sprite-sheet grid ruling from the town ground tiles.

The Delapidated / Healing town sheets were ruled with a grey-BLUE grid drawn
OVER the art (Run 144).  Several ground crops kept a 1-3px slice of that
ruling; stamped every 32px it reads as the "thin grey lines everywhere".

Guards (same shape as the Run 163c Dojo pass):
  * PALETTE   - the town pavement palette is neutral-to-warm (B - R <= ~6).
                A ruling pixel is grey-BLUE: B - R >= 14.
  * SCOPE     - only whole columns/rows carrying a proven RUN of ruling
                pixels (>= 50% of the line) are touched.
  * REPAIR    - each ruled line is rebuilt by interpolating the nearest CLEAN
                columns/rows either side, so the stone pattern carries through
                instead of being flattened to an average colour.
Dimensions are preserved exactly.
"""
from PIL import Image
import numpy as np, os, sys

def ruling_mask(a):
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    return (b - r >= 14) & (b >= 100) & (b <= 175) & (r >= 70) & (r <= 140)

def repair_axis(rgb, bad, axis):
    """bad = bool array of indices along `axis` that are ruled. Rebuild them by
    interpolating the nearest clean lines on either side."""
    n = rgb.shape[1] if axis == 1 else rgb.shape[0]
    good = np.where(~bad)[0]
    if good.size == 0:
        return rgb
    out = rgb.copy()
    for i in np.where(bad)[0]:
        lo = good[good < i]
        hi = good[good > i]
        if lo.size and hi.size:
            l, h = lo[-1], hi[0]
            t = (i - l) / float(h - l)
            a_line = rgb[:, l] if axis == 1 else rgb[l, :]
            b_line = rgb[:, h] if axis == 1 else rgb[h, :]
            new = a_line * (1.0 - t) + b_line * t
        else:
            k = (lo[-1] if lo.size else hi[0])
            new = rgb[:, k] if axis == 1 else rgb[k, :]
        if axis == 1:
            out[:, i] = new
        else:
            out[i, :] = new
    return out

def _flag(m, thresh, edge_thresh, edge=3):
    """Whole-line flags. A line anywhere in the tile needs `thresh` coverage;
    a line in the outer `edge` band only needs `edge_thresh`, because a crop
    that clipped the ruling keeps a partial slice of it right at the border."""
    def one(frac):
        n = frac.size
        bad = frac > thresh
        for i in list(range(min(edge, n))) + list(range(max(0, n - edge), n)):
            if frac[i] > edge_thresh:
                bad[i] = True
        # DILATE (Run 163c lesson): a 2-3px ruling leaves residue on the lines
        # FLANKING the one the scan locks onto. Absorb a neighbour that is
        # itself dirty, or a clean donor drags the residue back in.
        for _ in range(3):
            grow = bad.copy()
            for i in range(n):
                if bad[i]:
                    for j in (i - 1, i + 1):
                        if 0 <= j < n and frac[j] > edge_thresh:
                            grow[j] = True
            if (grow == bad).all():
                break
            bad = grow
        return bad
    return one(m.mean(0)), one(m.mean(1))

def clean(path, thresh=0.5, edge_thresh=0.12, verbose=True):
    im = Image.open(path).convert("RGBA")
    a = np.asarray(im).astype(float)
    rgb, al = a[..., :3].copy(), a[..., 3]
    m = ruling_mask(rgb)
    H, W = m.shape
    bad_c, bad_r = _flag(m, thresh, edge_thresh)
    if not bad_c.any() and not bad_r.any():
        if verbose: print(f"  {os.path.basename(path):20s} clean")
        return None
    if bad_c.all() or bad_r.all():
        raise RuntimeError("every line flagged - detector is wrong for " + path)
    rgb = repair_axis(rgb, bad_c, 1)
    rgb = repair_axis(rgb, bad_r, 0)
    # second round: repairing an edge line from a one-sided donor can drag a
    # little ruling along with it (Run 163d taught this - iterate).
    for _ in range(3):
        m1 = ruling_mask(rgb)
        c1, r1 = _flag(m1, thresh, edge_thresh)
        if not c1.any() and not r1.any():
            break
        rgb = repair_axis(rgb, c1 & ~bad_c if (c1 & ~bad_c).any() else c1, 1)
        rgb = repair_axis(rgb, r1 & ~bad_r if (r1 & ~bad_r).any() else r1, 0)
        bad_c, bad_r = bad_c | c1, bad_r | r1
    # mop-up: isolated ruling pixels left over in short runs
    m2 = ruling_mask(rgb)
    if m2.any():
        ys, xs = np.where(m2)
        for y, x in zip(ys, xs):
            xa, xb = max(0, x - 2), min(W, x + 3)
            win = rgb[y, xa:xb]
            keep = ~ruling_mask(win)
            if keep.any():
                rgb[y, x] = win[keep].mean(0)
    out = np.dstack([np.clip(rgb, 0, 255), al]).astype(np.uint8)
    if verbose:
        print(f"  {os.path.basename(path):20s} repaired cols={list(np.where(bad_c)[0])} "
              f"rows={list(np.where(bad_r)[0])} residual={int(ruling_mask(out[...,:3].astype(float)).sum())}px")
    return Image.fromarray(out, "RGBA")

if __name__ == "__main__":
    BASE = "/mnt/user-data/uploads/Shino & Bea/ShinoAndBea_Godot/Assets/Tilesets/Town_props"
    OUT = "/home/claude/town/out"
    for tier in ["delap", "healing", "perfect"]:
        d = os.path.join(BASE, tier)
        if not os.path.isdir(d):
            continue
        print(tier)
        os.makedirs(os.path.join(OUT, tier), exist_ok=True)
        for f in sorted(os.listdir(d)):
            if not f.endswith(".png"):
                continue
            if not (f.startswith("pave") or f.startswith("ground")):
                continue
            r = clean(os.path.join(d, f))
            if r is not None:
                r.save(os.path.join(OUT, tier, f))
