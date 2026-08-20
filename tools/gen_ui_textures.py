#!/usr/bin/env python3
"""
Shino & Bea — "Ink & Washi" UI kit texture generator.

Authoring resolution is 1x; everything is displayed at TEXEL 2 (2x nearest).
This is the reference implementation — the GDScript UISkin.gd port draws the
exact same pixels with Godot's Image API.
"""
import os, math
from PIL import Image, ImageDraw, ImageFont

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Assets", "UI")
os.makedirs(OUT, exist_ok=True)

# ── Palette ──────────────────────────────────────────────────────────────────
P = {
    "ink0":   (13, 11, 10),
    "ink1":   (28, 23, 20),
    "ink2":   (46, 38, 34),
    "washiD": (138, 115, 80),
    "washiM": (194, 169, 126),
    "washiF": (215, 197, 152),
    "washiL": (227, 210, 168),
    "washiH": (244, 233, 205),
    "woodD":  (58, 36, 22),
    "woodM":  (107, 68, 35),
    "woodL":  (148, 100, 58),
    "brassD": (138, 106, 34),
    "brassM": (201, 161, 62),
    "brassL": (240, 212, 122),
    "sealD":  (125, 26, 21),
    "sealM":  (200, 53, 43),
    "sealL":  (232, 87, 74),
    "goldD":  (168, 118, 42),
    "goldM":  (224, 170, 60),
    "goldL":  (255, 217, 122),
}

def C(name, a=255):
    r, g, b = P[name]
    return (r, g, b, a)

def img(w, h, fill=(0, 0, 0, 0)):
    return Image.new("RGBA", (w, h), fill)

def save(im, name):
    im.save(os.path.join(OUT, name))
    return name

# Deterministic hash noise (portable to GDScript)
def hnoise(x, y, seed=0):
    n = (x * 374761393 + y * 668265263 + seed * 1442695040888963407) & 0xFFFFFFFF
    n = (n ^ (n >> 13)) * 1274126177 & 0xFFFFFFFF
    return ((n ^ (n >> 16)) & 0xFFFF) / 65535.0


# ── 1. Washi paper field (tileable) ──────────────────────────────────────────
def paper_px(x, y, seed=7):
    """Two-step dithered washi with sparse fibre flecks."""
    n = hnoise(x, y, seed)
    if n > 0.9962:
        return C("washiH")     # rare bright fibre
    if n > 0.9920:
        return C("washiF")     # barely-there tone break
    return C("washiL")


def gen_paper_tile(size=32):
    im = img(size, size)
    px = im.load()
    for y in range(size):
        for x in range(size):
            px[x, y] = paper_px(x, y)
    return save(im, "paper_tile.png")


# ── 2. Scroll panel — 9-slice, margin 12 ─────────────────────────────────────
def gen_panel(name="panel_washi.png", size=48, m=12, keyline=True):
    im = img(size, size)
    px = im.load()
    for y in range(size):
        for x in range(size):
            px[x, y] = paper_px(x, y)
    d = ImageDraw.Draw(im)
    # outer ink border
    d.rectangle([0, 0, size - 1, size - 1], outline=C("ink0"))
    # inner bevel: light top/left, dark bottom/right
    d.line([(1, 1), (size - 2, 1)], fill=C("washiH"))
    d.line([(1, 1), (1, size - 2)], fill=C("washiH"))
    d.line([(1, size - 2), (size - 2, size - 2)], fill=C("washiD"))
    d.line([(size - 2, 1), (size - 2, size - 2)], fill=C("washiD"))
    # paper mount keyline (the classic scroll inner frame)
    if keyline:
        d.rectangle([4, 4, size - 5, size - 5], outline=C("washiD"))
        d.point([(4, 4), (size - 5, 4), (4, size - 5), (size - 5, size - 5)], fill=C("ink2"))
    # corner ink reinforcement
    for (cx, cy) in [(0, 0), (size - 1, 0), (0, size - 1), (size - 1, size - 1)]:
        sx = 1 if cx == 0 else -1
        sy = 1 if cy == 0 else -1
        for i in range(3):
            px[cx + sx * i, cy] = C("ink0")
            px[cx, cy + sy * i] = C("ink0")
    return save(im, name)


# ── 3. Scroll rods (hanging-scroll top & bottom bars) ────────────────────────
def gen_rod(name="rod.png", w=16, flip=False):
    h = 9
    im = img(w, h)
    px = im.load()
    rows = ["ink0", "woodL", "woodL", "woodM", "woodM", "woodM", "woodD", "woodD", "ink0"]
    for y in range(h):
        for x in range(w):
            px[x, y] = C(rows[y])
    # grain
    for x in range(w):
        if (x * 7 + 3) % 11 < 2:
            for y in (2, 3, 4):
                px[x, y] = C("woodM")
        if (x * 5) % 13 == 0:
            px[x, 5] = C("woodD")
    if flip:
        im = im.transpose(Image.FLIP_TOP_BOTTOM)
    return save(im, name)


def gen_rod_cap(name="rod_cap.png"):
    """Brass finial for the ends of a scroll rod (left version; mirror for right)."""
    w, h = 7, 13
    im = img(w, h)
    d = ImageDraw.Draw(im)
    d.rectangle([0, 2, w - 1, h - 3], fill=C("brassM"), outline=C("ink0"))
    d.line([(1, 3), (w - 2, 3)], fill=C("brassL"))
    d.line([(1, h - 4), (w - 2, h - 4)], fill=C("brassD"))
    d.rectangle([2, 0, w - 3, h - 1], fill=C("brassD"), outline=C("ink0"))
    d.line([(3, 1), (3, h - 2)], fill=C("brassM"))
    return save(im, name)


# ── 4. Ema plaque button — 9-slice, margin 10/10/8/8 ─────────────────────────
def _wood_px(x, y, base, dark, seed=3):
    n = hnoise(x, y, seed)
    if n > 0.90:
        return dark
    if n < 0.08:
        return base
    return base


def gen_plaque(name, tint=(0, 0, 0), state="idle", w=34, h=26):
    im = img(w, h)
    px = im.load()
    if state == "disabled":
        base, lite, dark = (78, 70, 62, 255), (104, 95, 84, 255), (52, 46, 41, 255)
    elif state == "focus":
        base, lite, dark = (128, 84, 44, 255), (176, 122, 70, 255), (72, 45, 26, 255)
    elif state == "press":
        base, lite, dark = (86, 54, 27, 255), (112, 72, 38, 255), (48, 29, 16, 255)
    else:
        base, lite, dark = C("woodM"), C("woodL"), C("woodD")
    for y in range(h):
        for x in range(w):
            px[x, y] = base
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, w - 1, h - 1], outline=C("ink0"))
    hi, lo = (lite, dark) if state != "press" else (dark, lite)
    d.line([(1, 1), (w - 2, 1)], fill=hi)
    d.line([(1, 1), (1, h - 2)], fill=hi)
    d.line([(1, h - 2), (w - 2, h - 2)], fill=lo)
    d.line([(w - 2, 1), (w - 2, h - 2)], fill=lo)
    # Wood grain: two long, low-contrast dashes. Anything denser reads as dirt
    # once the plaque is drawn at 2x.
    grain = (
        int(round(base[0] * 0.90)), int(round(base[1] * 0.90)),
        int(round(base[2] * 0.90)), 255,
    )
    for y in (7, h - 8):
        run = 0
        for x in range(4, w - 4):
            run = (run + 1) % 13
            if run < 8:
                px[x, y] = grain
    if state == "focus":
        d.rectangle([3, 3, w - 4, h - 4], outline=C("goldM"))
        for (cx, cy) in [(3, 3), (w - 4, 3), (3, h - 4), (w - 4, h - 4)]:
            px[cx, cy] = C("goldL")
        # brass rivets
        for (cx, cy) in [(6, 6), (w - 7, 6), (6, h - 7), (w - 7, h - 7)]:
            px[cx, cy] = C("brassL")
            px[cx + 1, cy] = C("brassD")
            px[cx, cy + 1] = C("brassD")
    return save(im, name)


# ── 5. Meter frame — 9-slice, margin 6/6/5/5 ─────────────────────────────────
def gen_bar_frame(name="bar_frame.png", w=22, h=13):
    im = img(w, h)
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, w - 1, h - 1], fill=C("woodM"), outline=C("ink0"))
    d.line([(1, 1), (w - 2, 1)], fill=C("woodL"))
    d.line([(1, 1), (1, h - 2)], fill=C("woodL"))
    d.line([(1, h - 2), (w - 2, h - 2)], fill=C("woodD"))
    d.line([(w - 2, 1), (w - 2, h - 2)], fill=C("woodD"))
    # recessed channel
    d.rectangle([3, 3, w - 4, h - 4], fill=C("ink1"), outline=C("ink0"))
    d.line([(4, 4), (w - 5, 4)], fill=(0, 0, 0, 255))
    return save(im, name)


def gen_bar_fill(name, lo, mid, hi, w=8, h=8):
    """Tileable fill: bright top scanline, dithered body, dark base."""
    im = img(w, h)
    px = im.load()
    for y in range(h):
        for x in range(w):
            if y == 0:
                c = hi
            elif y == 1:
                c = mid if (x % 2) else hi
            elif y >= h - 2:
                c = lo
            elif y == h - 3:
                c = lo if ((x + y) % 3 == 0) else mid
            else:
                c = hi if ((x * 3 + y * 5) % 11 == 0) else mid
            px[x, y] = c
    return save(im, name)


# ── 6. Hanko seal (selection marker) ─────────────────────────────────────────
def _load_font(path, size):
    return ImageFont.truetype(path, size)


def gen_seal(name, glyph="忍", size=26, weathered=False):
    im = img(size, size)
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, size - 1, size - 1], fill=C("sealM"), outline=C("sealD"))
    d.line([(1, 1), (size - 2, 1)], fill=C("sealL"))
    d.line([(1, 1), (1, size - 2)], fill=C("sealL"))
    # knock the glyph out in paper colour
    f = _load_font("/tmp/uikit/fonts/DotGothic16-JP.ttf", size - 6)
    tmp = Image.new("L", (size, size), 0)
    td = ImageDraw.Draw(tmp)
    bbox = td.textbbox((0, 0), glyph, font=f)
    tx = (size - (bbox[2] - bbox[0])) // 2 - bbox[0]
    ty = (size - (bbox[3] - bbox[1])) // 2 - bbox[1]
    td.text((tx, ty), glyph, font=f, fill=255)
    mask = tmp.point(lambda v: 255 if v > 110 else 0)
    im.paste(C("washiH"), (0, 0), mask)
    # Deliberately NOT weathered: speckled holes read as dirt on the button, not
    # as an aged stamp, once the seal is only ~34 px on screen.
    d.rectangle([0, 0, size - 1, size - 1], outline=C("sealD"))
    return save(im, name)


# ── 7. Ofuda talisman card — 9-slice, margin 14/14/20/16 ─────────────────────
def gen_ofuda(name="ofuda.png", w=52, h=72):
    im = img(w, h)
    px = im.load()
    for y in range(h):
        for x in range(w):
            px[x, y] = paper_px(x, y, seed=11)
    d = ImageDraw.Draw(im)
    # pointed top (classic ofuda shape) — carve the shoulders
    SH = 7
    for y in range(SH):
        cut = SH - y
        for x in range(cut):
            px[x, y] = (0, 0, 0, 0)
            px[w - 1 - x, y] = (0, 0, 0, 0)
        px[cut, y] = C("ink0")
        px[w - 1 - cut, y] = C("ink0")
    for x in range(SH, w - SH):
        px[x, 0] = C("ink0")
    for y in range(SH, h):
        px[0, y] = C("ink0")
        px[w - 1, y] = C("ink0")
    for x in range(w):
        px[x, h - 1] = C("ink0")
    # torn bottom deckle
    for x in range(w):
        if hnoise(x, 0, 33) > 0.6:
            px[x, h - 1] = (0, 0, 0, 0)
            px[x, h - 2] = C("ink0")
    return save(im, name)


# ── 8. Brush divider ─────────────────────────────────────────────────────────
def gen_divider(name="divider.png", w=256, h=9):
    im = img(w, h)
    px = im.load()
    mid = (h - 1) / 2.0
    for x in range(w):
        t = x / (w - 1)
        # Flat-topped taper: full weight across the middle 70%, pointed ends.
        ramp = min(1.0, min(t, 1.0 - t) / 0.15)
        half = 0.4 + 3.1 * (ramp ** 0.85)
        for y in range(h):
            dy = abs(y - mid)
            if dy <= half:
                px[x, y] = C("ink2") if dy > half - 0.75 else C("ink0")
    return save(im, name)


# ── 9. Torii silhouette (menu backdrop) ──────────────────────────────────────
def gen_torii(name="torii.png", w=120, h=96):
    im = img(w, h)
    d = ImageDraw.Draw(im)
    ink = (13, 11, 10, 255)
    d.polygon([(2, 8), (w - 3, 8), (w - 9, 14), (8, 14)], fill=ink)   # kasagi (curved top)
    d.rectangle([10, 16, w - 11, 21], fill=ink)                       # shimaki
    d.rectangle([18, 34, w - 19, 40], fill=ink)                       # nuki
    d.rectangle([20, 21, 30, h - 1], fill=ink)                        # left pillar
    d.rectangle([w - 31, 21, w - 21, h - 1], fill=ink)                # right pillar
    d.rectangle([w // 2 - 3, 21, w // 2 + 2, 34], fill=ink)           # gakuzuka
    return save(im, name)


# ── 10. Ink splat + paper noise overlay ──────────────────────────────────────
def gen_splat(name="ink_splat.png", size=40):
    im = img(size, size)
    px = im.load()
    cx = cy = size / 2.0
    for y in range(size):
        for x in range(size):
            dx, dy = x - cx, y - cy
            ang = math.atan2(dy, dx)
            r = math.hypot(dx, dy)
            wob = 1.0 + 0.34 * math.sin(ang * 3.0 + 1.1) + 0.20 * math.sin(ang * 7.0)
            if r < (size * 0.30) * wob:
                px[x, y] = C("ink0", 235)
            elif r < (size * 0.30) * wob + 1.6 and hnoise(x, y, 44) > 0.55:
                px[x, y] = C("ink0", 150)
    # flung droplets
    for i in range(9):
        a = hnoise(i, 1, 51) * math.tau
        rr = size * (0.34 + hnoise(i, 2, 52) * 0.16)
        dx, dy = int(cx + math.cos(a) * rr), int(cy + math.sin(a) * rr)
        s = 1 if hnoise(i, 3, 53) < 0.6 else 2
        for oy in range(s):
            for ox in range(s):
                if 0 <= dx + ox < size and 0 <= dy + oy < size:
                    px[dx + ox, dy + oy] = C("ink0", 210)
    return save(im, name)


def gen_noise(name="noise_overlay.png", size=32):
    im = img(size, size)
    px = im.load()
    for y in range(size):
        for x in range(size):
            n = hnoise(x, y, 77)
            if n > 0.955:
                px[x, y] = (255, 246, 220, 26)
            elif n < 0.035:
                px[x, y] = (0, 0, 0, 30)
    return save(im, name)


# ── 11. Shuriken combo gauge ring ────────────────────────────────────────────
def gen_shuriken(name="shuriken.png", size=24):
    im = img(size, size)
    px = im.load()
    c = (size - 1) / 2.0
    for y in range(size):
        for x in range(size):
            dx, dy = x - c, y - c
            r = math.hypot(dx, dy)
            a = math.atan2(dy, dx)
            blade = abs(math.sin(a * 2.0))
            lim = c * (0.20 + 0.80 * (blade ** 3.0))
            if r <= lim:
                px[x, y] = C("ink1") if r > lim - 1.3 else (168, 176, 186, 255)
    d = ImageDraw.Draw(im)
    d.ellipse([int(c) - 2, int(c) - 2, int(c) + 2, int(c) + 2], fill=(0, 0, 0, 0), outline=C("ink0"))
    return save(im, name)


if __name__ == "__main__":
    made = []
    made.append(gen_paper_tile())
    made.append(gen_panel())
    made.append(gen_panel("panel_plain.png", keyline=False))
    made.append(gen_rod())
    made.append(gen_rod("rod_bottom.png", flip=True))
    made.append(gen_rod_cap())
    for st in ("idle", "focus", "press", "disabled"):
        made.append(gen_plaque(f"plaque_{st}.png", state=st))
    made.append(gen_bar_frame())
    fills = {
        "hp":   ((109, 20, 20), (192, 42, 38), (240, 90, 72)),
        "chi":  ((18, 58, 107), (46, 127, 208), (122, 210, 255)),
        "beahp": ((74, 26, 107), (160, 63, 208), (223, 160, 255)),
        "beachi": ((14, 74, 72), (47, 176, 164), (127, 240, 224)),
        "gold": ((168, 118, 42), (224, 170, 60), (255, 217, 122)),
        "boss": ((92, 14, 46), (186, 36, 92), (240, 96, 150)),
        "break": ((120, 96, 18), (214, 178, 46), (255, 232, 132)),
    }
    for k, (lo, mid, hi) in fills.items():
        made.append(gen_bar_fill(f"fill_{k}.png", lo + (255,), mid + (255,), hi + (255,)))
    # 6 hanko. Each glyph is a real kanji chosen for its dictionary meaning, and
    # every one is verified present in DotGothic16's japanese subset — a missing
    # glyph would render as tofu, which is the whole "random symbols" failure mode.
    #   忍 nin   shinobi / endure        → focus marker            ( 7 strokes)
    #   刃 ha    blade / edge            → boss tag                ( 3 strokes)
    #   伝 den   legend (of 伝説)         → legendary boon stamp    ( 6 strokes)
    #   華 ka    flower / splendour      → Bea                     (10 strokes)
    #   将 shou  commander / general     → spare, LARGE sizes only (10 strokes)
    #   道 dou   the way / path          → spare, Sensei/mastery   (12 strokes)
    #
    # Stroke count is a hard constraint, not trivia: a seal drawn at 26 px can
    # only carry ~7 strokes before the pixel grid fuses them. 将 and 華 already
    # mush at that size — keep them for 52 px placements.
    for g, n in [("忍", "seal_nin"), ("将", "seal_shou"), ("伝", "seal_den"),
                 ("華", "seal_ka"), ("刃", "seal_ha"), ("道", "seal_do")]:
        made.append(gen_seal(f"{n}.png", g))
    made.append(gen_ofuda())
    made.append(gen_divider())
    made.append(gen_torii())
    made.append(gen_splat())
    made.append(gen_noise())
    made.append(gen_shuriken())
    print(len(made), "textures →", OUT)
    for m in made:
        print("  ", m)
