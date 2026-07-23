extends RefCounted

# ============================================================
# EnemySpriteGen.gd — Run 50 (2026-06-11) — procedural junk-food monsters v2
# ============================================================
# Generates a unique pixel-art monster sprite for every Dream World
# enemy AT RUNTIME — no art assets, no addons. Seeded by the enemy's
# name, so each roster entry is deterministic but distinct.
#
# Run 50 quality pass (CrossCode-inspired):
#   • Canvas 26 → 32 texels (more silhouette + face detail).
#   • Real 2-axis lighting (top-left key light): 5-band hue-shifted
#     ramp — shadows pull cool, highlights pull warm — with Bayer
#     dithering at every band boundary instead of flat fills.
#   • Smoothed silhouettes (jitter pass + neighbor averaging — no
#     more ragged single-texel stairsteps).
#   • Soft elliptical contact shadow under every monster.
#   • NEW species: "slime" — translucent jelly dome with a visible
#     nucleus, glossy specular, gel rim, and per-element garnish
#     (fire/earth/water/electric/poison/plant/ice). Driven by cfg
#     fields  "species": "slime"  and  "element": <name>.
#
# Integration unchanged (DreamSpawner.apply_config):
#   EnemySpriteGen.apply_to(enemy_root, body_node, cfg)
# ============================================================

const CANVAS: int = 32
const DRAW_SCALE: float = 2.0
static var _cache: Dictionary = {}    # name(+rank) → ImageTexture

# 4×4 Bayer matrix for ordered dithering at shading band boundaries.
const BAYER: Array = [
	[0, 8, 2, 10],
	[12, 4, 14, 6],
	[3, 11, 1, 9],
	[15, 7, 13, 5],
]

# Element identities for the jelly slime family.
const ELEMENTS: Dictionary = {
	"fire":     {"col": Color(1.00, 0.45, 0.15), "hi": Color(1.00, 0.85, 0.30)},
	"earth":    {"col": Color(0.62, 0.45, 0.25), "hi": Color(0.82, 0.68, 0.45)},
	"water":    {"col": Color(0.30, 0.62, 0.95), "hi": Color(0.70, 0.90, 1.00)},
	"electric": {"col": Color(1.00, 0.88, 0.25), "hi": Color(1.00, 1.00, 0.75)},
	"poison":   {"col": Color(0.62, 0.30, 0.75), "hi": Color(0.55, 0.90, 0.40)},
	"plant":    {"col": Color(0.40, 0.78, 0.35), "hi": Color(0.75, 0.95, 0.50)},
	"ice":      {"col": Color(0.70, 0.90, 1.00), "hi": Color(0.95, 1.00, 1.00)},
}


# ---------------------------------------------------------------------------
# Public — returns true when the generated sprite replaced the stick figure.
# ---------------------------------------------------------------------------
static func apply_to(root: Node, body: Node, cfg: Dictionary) -> bool:
	if body == null:
		return false
	var tex: ImageTexture = texture_for(cfg)
	if tex == null:
		return false

	# Hide every stick-figure part; keep Torso alive (transparent) as the
	# animation anchor so walk-bob and idle-breathe still move the monster.
	var torso: ColorRect = body.get_node_or_null("Torso") as ColorRect
	for child in body.get_children():
		if child is CanvasItem and child != torso:
			(child as CanvasItem).visible = false
	var anchor: Node = body
	var spr := Sprite2D.new()
	spr.name = "MonsterSprite"
	spr.texture = tex
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.scale = Vector2(DRAW_SCALE, DRAW_SCALE)
	if torso:
		torso.color = Color(0, 0, 0, 0)
		spr.position = -torso.position    # re-center on the Body origin
		anchor = torso
	spr.position += Vector2(0, 1)
	anchor.add_child(spr)

	# Cover the new body with the flash overlay (hit/windup/death tells).
	var overlay: ColorRect = root.get_node_or_null("Sprite") as ColorRect
	if overlay:
		var half: float = CANVAS * DRAW_SCALE * 0.5 + 2.0
		overlay.offset_left = -half
		overlay.offset_top = -half
		overlay.offset_right = half
		overlay.offset_bottom = half
	return true


static func texture_for(cfg: Dictionary) -> ImageTexture:
	var key: String = String(cfg.get("name", "Junk Shadow"))
	if cfg.get("is_boss", false):
		key += "#boss"
	elif cfg.get("is_miniboss", false):
		key += "#mini"
	if _cache.has(key):
		return _cache[key]
	var tex: ImageTexture = _generate(cfg)
	_cache[key] = tex
	return tex


# ---------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------
static func _generate(cfg: Dictionary) -> ImageTexture:
	if String(cfg.get("species", "")) == "slime":
		return _generate_slime(cfg)

	var rng := RandomNumberGenerator.new()
	rng.seed = hash(String(cfg.get("name", "Junk Shadow")))
	var arch: String = String(cfg.get("arch", "melee"))
	# Run 57 — new gameplay archetypes reuse existing silhouettes for now:
	# the laser caster looks like a lanky ranged figure; the charger is a big
	# melee blob (it's scaled up via cfg). Keeps placeholder art coherent until
	# Bruno feeds bespoke sprites.
	match arch:
		"laser":
			arch = "ranged"
		"charger":
			arch = "melee"
	var tint: Color = cfg.get("tint", Color(0.8, 0.5, 0.4))

	# Hue-shifted 5-band ramp: shadows cool, highlights warm.
	var base: Color = tint
	var shade: Color = _hue_shift(tint, -0.045).darkened(0.28)
	var shade2: Color = _hue_shift(tint, -0.085).darkened(0.50)
	var hi: Color = _hue_shift(tint, 0.03).lightened(0.22)
	var hi2: Color = _hue_shift(tint, 0.06).lightened(0.45)
	var outline: Color = _hue_shift(tint, -0.10).darkened(0.68)
	var garnish: Color = Color.from_hsv(fposmod(tint.h + 0.5, 1.0), 0.65, 0.95)

	var img := Image.create(CANVAS, CANVAS, false, Image.FORMAT_RGBA8)

	# --- 1. Silhouette (mirrored half-widths, jittered then smoothed) ------
	var top: int
	var bottom: int
	match arch:
		"ranged":
			top = 3
			bottom = 27
		"scout":
			top = 10
			bottom = 23
		_:
			top = 6
			bottom = 26
	var rows: int = bottom - top + 1
	var widths: Array = []
	var jitter: int = 0
	for i in range(rows):
		var f: float = float(i) / float(max(1, rows - 1))
		var hw: float
		match arch:
			"ranged":
				hw = lerp(4.0, 10.0, f)                      # narrow → flared base
			"scout":
				hw = 8.5 * sin(PI * clamp(f * 0.85 + 0.1, 0.05, 0.95))   # squat oval
			_:
				hw = 11.0 * sin(PI * clamp(f * 0.9 + 0.06, 0.05, 0.95))  # chunky blob
		jitter = clamp(jitter + rng.randi_range(-1, 1), -2, 2)
		widths.append(clamp(int(round(hw)) + jitter, 2, 13))
	# Neighbor-average smoothing — kills ragged stairsteps, keeps character.
	var smoothed: Array = widths.duplicate()
	for i in range(1, rows - 1):
		smoothed[i] = int(round((float(widths[i - 1]) + 2.0 * float(widths[i]) + float(widths[i + 1])) / 4.0))
	widths = smoothed

	# --- 2. Fill with 2-axis key lighting (light from top-left) ------------
	var cx: int = CANVAS / 2
	for i in range(rows):
		var y: int = top + i
		var wdt: int = widths[i]
		var v: float = float(i) / float(max(1, rows - 1))
		for x in range(cx - wdt, cx + wdt + 1):
			var u: float = float(x - (cx - wdt)) / float(max(1, 2 * wdt))
			var dth: float = (float(BAYER[y % 4][x % 4]) / 16.0 - 0.5) * 0.14
			var light: float = (1.0 - u) * 0.62 + (1.0 - v) * 0.38 + dth
			var col: Color
			if light > 0.82:
				col = hi2
			elif light > 0.62:
				col = hi
			elif light > 0.34:
				col = base
			elif light > 0.20:
				col = shade
			else:
				col = shade2
			# Rim accents: hard shade on the dark edge, sparkle on the lit edge.
			if x >= cx + wdt - 1:
				col = shade2
			elif x <= cx - wdt + 1 and v < 0.45:
				col = hi2
			elif rng.randf() < 0.05:
				col = shade            # dither grain
			img.set_pixel(x, y, col)

	# Scout wings — pale side fins at mid-height.
	if arch == "scout":
		var wi: int = rows / 3
		var wy: int = top + wi
		for k in range(3):
			var wlen: int = 4 - k
			for dx in range(widths[wi] + 1, widths[wi] + 1 + wlen):
				if cx - dx >= 0:
					img.set_pixel(cx - dx, wy + k, hi)
				if cx + dx < CANVAS:
					img.set_pixel(cx + dx, wy + k, hi)

	# --- 3. Junk-food garnish (2 seeded picks) ------------------------------
	var picks: Array = ["stripes", "sprinkles", "drips", "bite", "cherry", "horns"]
	for _g in range(2):
		var g: String = picks[rng.randi() % picks.size()]
		picks.erase(g)
		match g:
			"stripes":
				for i in range(rows):
					if (i / 2) % 2 == 1:
						var y2: int = top + i
						for x2 in range(cx - widths[i] + 1, cx + widths[i]):
							if img.get_pixel(x2, y2).a > 0.0:
								img.set_pixel(x2, y2, shade.lerp(base, 0.35))
			"sprinkles":
				for _s in range(rng.randi_range(8, 13)):
					var ri: int = rng.randi_range(0, rows - 1)
					var sy: int = top + ri
					var sx: int = cx + rng.randi_range(-widths[ri] + 1, widths[ri] - 1)
					img.set_pixel(sx, sy, garnish)
			"drips":
				for _d2 in range(rng.randi_range(2, 4)):
					var di: int = rows - 1
					var dx2: int = cx + rng.randi_range(-widths[di] + 2, widths[di] - 2)
					var dlen: int = rng.randi_range(1, 3)
					for dy in range(1, dlen + 1):
						if bottom + dy < CANVAS:
							img.set_pixel(dx2, bottom + dy, shade)
			"bite":
				var bi: int = rng.randi_range(0, rows / 3)
				var by: int = top + bi
				var bx: int = cx + widths[bi] - 1
				for dy2 in range(-1, 2):
					for dx3 in range(-1, 2):
						var px: int = bx + dx3
						var py: int = by + dy2
						if px >= 0 and px < CANVAS and py >= 0 and py < CANVAS:
							img.set_pixel(px, py, Color(0, 0, 0, 0))
			"cherry":
				if top - 3 >= 0:
					img.set_pixel(cx, top - 3, Color(0.55, 0.30, 0.12))
					for cyy in range(2):
						for cxx in range(2):
							img.set_pixel(cx + cxx, top - 2 + cyy, Color(0.85, 0.15, 0.20))
					img.set_pixel(cx, top - 2, Color(0.98, 0.55, 0.55))   # cherry shine
			"horns":
				var hx: int = widths[0]
				for hh in range(3):
					if top - 1 - hh >= 0:
						img.set_pixel(cx - hx + 1 + hh, top - 1 - hh, shade)
						img.set_pixel(cx + hx - 1 - hh, top - 1 - hh, shade)

	# Boss / mini-boss crown.
	if cfg.get("is_boss", false) or cfg.get("is_miniboss", false):
		_draw_crown(img, cx, top)

	# --- 4. Face -------------------------------------------------------------
	var eye_i: int = max(1, rows / 3)
	var ey: int = top + eye_i
	var espread: int = max(2, int(widths[eye_i] * 0.45))
	for side in [-1, 1]:
		var ex: int = cx + side * espread
		for dy3 in range(2):
			for dx4 in range(2):
				img.set_pixel(ex + dx4, ey + dy3, Color.WHITE)
		img.set_pixel(ex + (1 if side > 0 else 0), ey + 1, Color(0.08, 0.08, 0.10))
		# Angry brow — slants inward-down.
		img.set_pixel(ex, ey - 1, outline)
		img.set_pixel(ex + 1, ey - 1, outline)
		img.set_pixel(ex + (0 if side > 0 else 1), ey - 2, outline)
	var my: int = ey + 5
	match arch:
		"ranged":
			img.set_pixel(cx, my, outline)        # "o" spitter mouth
			img.set_pixel(cx - 1, my, outline)
			img.set_pixel(cx + 1, my, outline)
			img.set_pixel(cx, my + 1, outline)
			img.set_pixel(cx, my - 1, outline)
		"scout":
			img.set_pixel(cx, my, outline)        # tiny beak
			img.set_pixel(cx + 1, my, outline)
		_:
			for zx in range(cx - 4, cx + 5):      # jagged grin
				img.set_pixel(zx, my + (zx % 2), outline)

	_outline_pass(img, outline)
	_contact_shadow(img, cx, bottom, widths[rows - 1])
	return ImageTexture.create_from_image(img)


# ---------------------------------------------------------------------------
# Slime species — translucent elemental jelly dome.
# ---------------------------------------------------------------------------
static func _generate_slime(cfg: Dictionary) -> ImageTexture:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(String(cfg.get("name", "Jelly")))
	var element: String = String(cfg.get("element", "water"))
	var edata: Dictionary = ELEMENTS.get(element, ELEMENTS["water"])
	var tint: Color = cfg.get("tint", edata["col"])
	var ecol: Color = edata["col"]
	var ehi: Color = edata["hi"]

	var base: Color = tint
	var shade: Color = _hue_shift(tint, -0.05).darkened(0.26)
	var hi: Color = _hue_shift(tint, 0.04).lightened(0.30)
	var outline: Color = _hue_shift(tint, -0.09).darkened(0.60)
	outline.a = 0.85

	var img := Image.create(CANVAS, CANVAS, false, Image.FORMAT_RGBA8)
	var cx: int = CANVAS / 2
	var top: int = 11
	var bottom: int = 27
	var rows: int = bottom - top + 1

	# Dome silhouette: fast bulge, flat squishy bottom, slight seeded wobble.
	var widths: Array = []
	for i in range(rows):
		var f: float = float(i) / float(max(1, rows - 1))
		var hw: float = 12.0 * sqrt(sin(clamp(f, 0.04, 1.0) * PI * 0.55))
		if i >= rows - 2:
			hw += 0.8                                  # squish flare at the floor
		widths.append(clamp(int(round(hw + rng.randf_range(-0.4, 0.4))), 2, 13))

	# --- Translucent gel body ------------------------------------------------
	for i in range(rows):
		var y: int = top + i
		var wdt: int = widths[i]
		var v: float = float(i) / float(max(1, rows - 1))
		for x in range(cx - wdt, cx + wdt + 1):
			var u: float = float(x - (cx - wdt)) / float(max(1, 2 * wdt))
			var dth: float = (float(BAYER[y % 4][x % 4]) / 16.0 - 0.5) * 0.14
			var light: float = (1.0 - u) * 0.55 + (1.0 - v) * 0.45 + dth
			var col: Color = base
			if light > 0.72:
				col = hi
			elif light < 0.30:
				col = shade
			# Gel rim — brighter refraction ring just inside the edge.
			if x >= cx + wdt - 1 or x <= cx - wdt + 1:
				col = hi.lerp(ehi, 0.35)
			col.a = 0.72 if v > 0.78 else 0.60          # denser goo at the floor
			img.set_pixel(x, y, col)

	# --- Nucleus — opaque little core floating in the gel --------------------
	var ny: int = bottom - 5
	var ncol: Color = ecol.darkened(0.25)
	for dy in range(-2, 3):
		for dx in range(-3, 4):
			if abs(dx) + abs(dy) * 2 <= 4:
				var c: Color = ncol if (dx + dy) % 2 == 0 else ecol
				c.a = 1.0
				img.set_pixel(cx + dx, ny + dy, c)
	img.set_pixel(cx - 1, ny - 1, ehi)                  # nucleus glint

	# --- Element garnish ------------------------------------------------------
	_slime_element_fx(img, rng, element, ecol, ehi, cx, top, bottom, widths)

	# --- Glossy specular (full alpha — reads as a wet surface) ----------------
	var gx: int = cx - 6
	var gy: int = top + 3
	for k in range(3):
		img.set_pixel(gx + k, gy + (k / 2), Color(1, 1, 1, 0.92))
	img.set_pixel(gx + 1, gy + 2, Color(1, 1, 1, 0.78))

	# --- Cute face (full alpha) ------------------------------------------------
	var ey: int = top + rows / 2 - 1
	for side in [-1, 1]:
		var ex: int = cx + side * 4
		img.set_pixel(ex, ey, Color(0.10, 0.08, 0.14))
		img.set_pixel(ex, ey + 1, Color(0.10, 0.08, 0.14))
		img.set_pixel(ex, ey - 1, Color(1, 1, 1, 0.85))   # eye shine
	for mx in range(cx - 1, cx + 2):                    # tiny content smile
		img.set_pixel(mx, ey + 3, Color(0.10, 0.08, 0.14, 0.9))

	if cfg.get("is_boss", false) or cfg.get("is_miniboss", false):
		_draw_crown(img, cx, top)

	_outline_pass(img, outline)
	_contact_shadow(img, cx, bottom, widths[rows - 1])
	return ImageTexture.create_from_image(img)


static func _slime_element_fx(img: Image, rng: RandomNumberGenerator,
		element: String, ecol: Color, ehi: Color, cx: int,
		top: int, bottom: int, widths: Array) -> void:
	var rows: int = widths.size()
	match element:
		"fire":
			# Rising flame wisps inside the gel + a flame tuft on top.
			for w in range(3):
				var fx: int = cx + rng.randi_range(-5, 5)
				var fy: int = bottom - 3
				var flen: int = rng.randi_range(4, 6)
				for k in range(flen):
					var c: Color = ecol if k < flen / 2 else ehi
					c.a = 0.95
					img.set_pixel(fx + (k % 2) * (1 if w % 2 == 0 else -1), fy - k, c)
			img.set_pixel(cx, top - 1, ecol)
			img.set_pixel(cx, top - 2, ehi)
			img.set_pixel(cx + 1, top - 1, ehi)
		"earth":
			# Embedded pebbles with a lit corner.
			for _p in range(4):
				var ri: int = rng.randi_range(rows / 3, rows - 3)
				var px: int = cx + rng.randi_range(-widths[ri] + 3, widths[ri] - 4)
				var py: int = top + ri
				for dy in range(2):
					for dx in range(2):
						img.set_pixel(px + dx, py + dy, ecol.darkened(0.30))
				img.set_pixel(px, py, ehi.darkened(0.10))
		"water":
			# Drifting bubbles + a drip off the brow.
			for _b in range(3):
				var ri2: int = rng.randi_range(2, rows - 4)
				var bx: int = cx + rng.randi_range(-widths[ri2] + 3, widths[ri2] - 3)
				var by: int = top + ri2
				var bc: Color = ehi
				bc.a = 0.85
				img.set_pixel(bx, by - 1, bc)
				img.set_pixel(bx - 1, by, bc)
				img.set_pixel(bx + 1, by, bc)
				img.set_pixel(bx, by + 1, bc)
			img.set_pixel(cx + 7, top + 4, ecol)
			img.set_pixel(cx + 7, top + 5, ehi)
		"electric":
			# Zigzag bolt across the body + stray sparks.
			var zy: int = top + rows / 2
			var zx: int = cx - 6
			var dir: int = -1
			while zx <= cx + 6:
				var c2: Color = ecol
				c2.a = 1.0
				img.set_pixel(zx, zy, c2)
				img.set_pixel(zx, zy + 1, ehi)
				zx += 1
				if zx % 3 == 0:
					dir *= -1
				zy += dir
			img.set_pixel(cx - 9, top + 3, ehi)
			img.set_pixel(cx + 9, bottom - 8, ehi)
		"poison":
			# Sickly bubbles + ooze drips pooling below.
			var pcol: Color = Color(0.55, 0.90, 0.40)
			for _b2 in range(4):
				var ri3: int = rng.randi_range(2, rows - 4)
				var bx2: int = cx + rng.randi_range(-widths[ri3] + 3, widths[ri3] - 3)
				var c3: Color = pcol if rng.randf() < 0.6 else ecol
				c3.a = 0.9
				img.set_pixel(bx2, top + ri3, c3)
				img.set_pixel(bx2 + 1, top + ri3, c3.darkened(0.2))
			for _d in range(2):
				var dx5: int = cx + rng.randi_range(-6, 6)
				for dy5 in range(1, rng.randi_range(2, 4)):
					if bottom + dy5 < CANVAS:
						img.set_pixel(dx5, bottom + dy5, pcol.darkened(0.15))
		"plant":
			# Sprout on top + seeds suspended in the gel.
			var stem: Color = Color(0.25, 0.55, 0.22)
			if top - 3 >= 0:
				img.set_pixel(cx, top - 1, stem)
				img.set_pixel(cx, top - 2, stem)
				img.set_pixel(cx - 1, top - 3, ecol)
				img.set_pixel(cx - 2, top - 2, ecol)
				img.set_pixel(cx + 1, top - 3, ehi)
				img.set_pixel(cx + 2, top - 2, ehi)
			for _s2 in range(3):
				var ri4: int = rng.randi_range(rows / 2, rows - 3)
				var sx2: int = cx + rng.randi_range(-widths[ri4] + 3, widths[ri4] - 3)
				img.set_pixel(sx2, top + ri4, Color(0.20, 0.14, 0.08))
		"ice":
			# Crystal shard suspended mid-gel + frost flecks.
			var sy2: int = top + rows / 2
			for dy6 in range(-3, 4):
				var span: int = 2 - abs(dy6) / 2
				for dx6 in range(-span, span + 1):
					var c4: Color = ecol if dx6 < 0 else ehi
					c4.a = 0.95
					img.set_pixel(cx + dx6, sy2 + dy6, c4)
			img.set_pixel(cx, sy2 - 2, Color(1, 1, 1, 0.95))
			for _f in range(4):
				var ri5: int = rng.randi_range(2, rows - 3)
				var fx2: int = cx + rng.randi_range(-widths[ri5] + 2, widths[ri5] - 2)
				img.set_pixel(fx2, top + ri5, Color(1, 1, 1, 0.7))


# ---------------------------------------------------------------------------
# Shared finishing passes
# ---------------------------------------------------------------------------
static func _draw_crown(img: Image, cx: int, top: int) -> void:
	var gold := Color(0.95, 0.80, 0.25)
	var gold_hi := Color(1.00, 0.92, 0.55)
	var crown_y: int = top - 3
	if crown_y < 1:
		return
	for x in range(cx - 4, cx + 5):
		img.set_pixel(x, crown_y + 2, gold)
	for x in [cx - 4, cx, cx + 4]:
		img.set_pixel(x, crown_y + 1, gold)
		img.set_pixel(x, crown_y, gold_hi)
	img.set_pixel(cx - 2, crown_y + 1, Color(0.85, 0.20, 0.30))   # jewel
	img.set_pixel(cx + 2, crown_y + 1, Color(0.25, 0.45, 0.90))   # jewel


static func _outline_pass(img: Image, outline: Color) -> void:
	var src: Image = img.duplicate()
	for y in range(CANVAS):
		for x in range(CANVAS):
			if src.get_pixel(x, y).a > 0.4:
				continue
			var edge: bool = false
			for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx: int = x + off.x
				var ny: int = y + off.y
				if nx >= 0 and nx < CANVAS and ny >= 0 and ny < CANVAS:
					if src.get_pixel(nx, ny).a > 0.4:
						edge = true
						break
			if edge:
				img.set_pixel(x, y, outline)


# Soft elliptical ground shadow — drawn last so the outline pass never
# traces it. Grounds the monster on the terrain like a real sprite sheet.
static func _contact_shadow(img: Image, cx: int, bottom: int, base_hw: int) -> void:
	var sw: int = base_hw + 2
	for dy in range(2):
		var y: int = bottom + 2 + dy
		if y >= CANVAS:
			continue
		var row_w: int = sw - dy * 2
		for x in range(cx - row_w, cx + row_w + 1):
			if x < 0 or x >= CANVAS:
				continue
			if img.get_pixel(x, y).a < 0.1:
				img.set_pixel(x, y, Color(0.0, 0.0, 0.05, 0.28 - float(dy) * 0.10))


static func _hue_shift(c: Color, amt: float) -> Color:
	return Color.from_hsv(fposmod(c.h + amt, 1.0), c.s, c.v, c.a)
