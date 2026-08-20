extends RefCounted

# ============================================================
# CarnivalTileset.gd — Run 167 (2026-08-19) — Dragon Fruit Carnival
# ============================================================
# Loader + placement helpers for the carnival art Bruno dropped in
# (`Assets/Tilesets/DragonFruit_Carnival/*.jpg`, two promo sheets).
# The sheets were sliced offline into a flat prop library at
#
#     res://Assets/Tilesets/Carnival_props/<name>.png
#
# 98 pieces: 5 seamless 32px ground tiles, the dragon torii, the big
# top, the stage, the ticket booth, six kinds of vendor stall/table,
# the fair games (dartboard, wheel, hi-striker, duck pond, bottle
# pyramid), prizes, paper lanterns, banners/bunting, statues, masks,
# fences and the exotic flora.
#
# Conventions copied from TownTileset.gd on purpose, so the two
# tilesets behave identically:
#   * props are pre-shrunk on the CPU (Lanczos) to their DRAWN height
#     and render 1:1 — never upscaled above native res (Run 110 lock)
#   * every prop is FOOT-ANCHORED inside a y-sorted host, so heroes
#     weave in front of and behind them (y-sort depth rule)
#   * glow lives in a GlowLight, never painted into the PNG (Run 163)
# ============================================================

const DIR: String = "res://Assets/Tilesets/Carnival_props/"
const CELL: float = 32.0     # world px per ground tile — same as every biome

static var _img_cache: Dictionary = {}    # name -> Image (misses cached as false)
static var _tex_cache: Dictionary = {}    # "name|h" -> ImageTexture


# ---------------------------------------------------------------------------
# Asset loading — ResourceLoader when imported, Image.load before Godot has
# scanned the new PNGs (same two-step TownTileset uses).
# ---------------------------------------------------------------------------
static func img(name: String) -> Image:
	if _img_cache.has(name):
		var c = _img_cache[name]
		return c if c is Image else null
	var p: String = DIR + name + ".png"
	var out: Image = null
	if ResourceLoader.exists(p):
		var r: Resource = ResourceLoader.load(p)
		if r is Texture2D:
			out = (r as Texture2D).get_image()
	if out == null:
		var abs_path: String = ProjectSettings.globalize_path(p)
		if FileAccess.file_exists(abs_path):
			var im := Image.new()
			if im.load(abs_path) == OK:
				out = im
	if out != null:
		out.convert(Image.FORMAT_RGBA8)
	else:
		push_warning("[CarnivalTileset] Missing art: %s" % p)
	_img_cache[name] = out if out != null else false
	return out


static func has(name: String) -> bool:
	return img(name) != null


# Texture pre-shrunk to `target_h` drawn height (never enlarged).
static func tex(name: String, target_h: float) -> ImageTexture:
	var src: Image = img(name)
	if src == null:
		return null
	var s: float = minf(target_h / float(src.get_height()), 1.0)
	var w: int = maxi(1, int(round(float(src.get_width()) * s)))
	var h: int = maxi(1, int(round(float(src.get_height()) * s)))
	var key: String = "%s|%d" % [name, h]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var t := Image.new()
	t.copy_from(src)
	if h < t.get_height():
		t.fix_alpha_edges()      # bleed edge RGB so Lanczos can't ring dark halos
		t.resize(w, h, Image.INTERPOLATE_LANCZOS)
	var out := ImageTexture.create_from_image(t)
	_tex_cache[key] = out
	return out


# ---------------------------------------------------------------------------
# GROUND — one baked Sprite2D for the whole zone. Dragon-scale pavement down
# the midway, sand at the edges, a confetti-strewn ring under the big top.
# Same crop-from-origin rule as TownTileset (Run 152 lock): the bake is cut to
# EXACTLY 2*half before it becomes a sprite, or every baked feature drifts.
# ---------------------------------------------------------------------------
static func build_ground(parent: Node2D, half: Vector2, seed_val: int,
		midway_segs: Array, confetti_rings: Array) -> void:
	var old: Node = parent.get_node_or_null("CarnivalGround")
	if old:
		old.queue_free()

	var tile_px: int = int(CELL)
	var pave: Image = _sized(img("ground_dragon_stone"), tile_px)
	var sand: Image = _sized(img("ground_sand"), tile_px)
	var confetti: Image = _sized(img("ground_confetti"), tile_px)
	var cobble: Image = _sized(img("ground_cobble"), tile_px)
	if pave == null and sand == null:
		return                      # art missing — caller keeps its flat floor
	if sand == null: sand = pave
	if pave == null: pave = sand
	if confetti == null: confetti = sand
	if cobble == null: cobble = pave

	var cols: int = int(ceil(half.x * 2.0 / CELL))
	var rows: int = int(ceil(half.y * 2.0 / CELL))
	var img_out := Image.create(cols * tile_px, rows * tile_px, false, Image.FORMAT_RGBA8)

	for cj in range(rows):
		for ci in range(cols):
			var wc := Vector2((float(ci) + 0.5) * CELL - half.x,
				(float(cj) + 0.5) * CELL - half.y)
			var h_val: int = abs(hash(Vector2i(ci * 71 + seed_val, cj * 503)))
			var src: Image = sand
			if _near_any_seg(wc, midway_segs, 78.0):
				src = pave                                   # the midway itself
			elif _in_any_ring(wc, confetti_rings):
				src = confetti                               # show floors
			elif h_val % 100 < 12:
				src = cobble                                 # worn patches
			img_out.blit_rect(src, Rect2i(0, 0, tile_px, tile_px),
				Vector2i(ci * tile_px, cj * tile_px))

	var want_w: int = int(round(half.x * 2.0))
	var want_h: int = int(round(half.y * 2.0))
	if img_out.get_width() != want_w or img_out.get_height() != want_h:
		img_out = img_out.get_region(Rect2i(0, 0,
			mini(want_w, img_out.get_width()), mini(want_h, img_out.get_height())))

	var spr := Sprite2D.new()
	spr.name = "CarnivalGround"
	spr.z_index = -30
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.texture = ImageTexture.create_from_image(img_out)
	parent.add_child(spr)


static func _sized(im: Image, tile_px: int) -> Image:
	if im == null:
		return null
	var t := Image.new()
	t.copy_from(im)
	if t.get_width() != tile_px or t.get_height() != tile_px:
		var interp: int = Image.INTERPOLATE_LANCZOS if t.get_width() > tile_px else Image.INTERPOLATE_NEAREST
		t.resize(tile_px, tile_px, interp)
	return t


static func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	if ab.length_squared() < 0.001:
		return p.distance_to(a)
	var t: float = clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return p.distance_to(a + ab * t)


static func _near_any_seg(p: Vector2, segs: Array, w: float) -> bool:
	for s in segs:
		if _seg_dist(p, s[0], s[1]) < w:
			return true
	return false


static func _in_any_ring(p: Vector2, rings: Array) -> bool:
	for r in rings:
		if p.distance_to(r[0]) < float(r[1]):
			return true
	return false


# ---------------------------------------------------------------------------
# PROPS — foot-anchored, y-sorted, optional collision circle, optional light.
# `recs` entries: [name, drawn_height, x, y, collide_r]
# ---------------------------------------------------------------------------
# Props that carry their own light source. [colour, radius, energy, breath,
# height fraction of the prop the light sits at]
static var LIGHT_EMITTERS: Dictionary = {
	"lantern_paper_f0":   [GlowLight.WARM_PAPER, 150.0, 0.95, 0.16, 0.80],
	"lantern_paper_f1":   [GlowLight.WARM_PAPER, 155.0, 1.00, 0.16, 0.80],
	"lantern_paper_f2":   [GlowLight.WARM_PAPER, 150.0, 0.95, 0.16, 0.80],
	"lantern_glow_a":     [GlowLight.WARM_PAPER, 140.0, 0.90, 0.15, 0.78],
	"lantern_glow_b":     [GlowLight.WARM_PAPER, 140.0, 0.90, 0.15, 0.78],
	"lantern_dragonfish": [GlowLight.EMBER,      165.0, 1.05, 0.18, 0.78],
	"brazier_stone":      [GlowLight.EMBER,      190.0, 1.30, 0.22, 0.70],
	"forge_kiln":         [GlowLight.EMBER,      165.0, 1.10, 0.20, 0.35],
	"booth_tickets":      [GlowLight.WARM_PAPER, 175.0, 0.70, 0.10, 0.45],
	"carousel":           [GlowLight.WARM_PAPER, 260.0, 0.85, 0.12, 0.55],
}


static func place(host: Node2D, name: String, world_h: float, pos: Vector2,
		collide_r: float = 0.0, flip: bool = false, light: bool = true) -> Node2D:
	var t: ImageTexture = tex(name, world_h)
	if t == null:
		return null
	var wh: float = float(t.get_height())
	var wrap := Node2D.new()
	wrap.name = "P_%s" % name
	wrap.position = pos            # FEET
	wrap.z_as_relative = false
	wrap.z_index = 0

	var sh := Sprite2D.new()
	sh.texture = _shadow_texture()
	sh.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var draw_w: float = float(t.get_width())
	var sw: float = draw_w * 0.55
	var shh: float = maxf(6.0, sw * 0.34)
	sh.scale = Vector2(sw / float(sh.texture.get_width()), shh / float(sh.texture.get_height()))
	wrap.add_child(sh)

	var spr := Sprite2D.new()
	spr.name = "Sprite"
	spr.texture = t
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.flip_h = flip
	spr.position = Vector2(0, -wh * 0.5)
	wrap.add_child(spr)
	host.add_child(wrap)

	if light and LIGHT_EMITTERS.has(name):
		var em: Array = LIGHT_EMITTERS[name]
		GlowLight.attach(host, pos + Vector2(0.0, -wh * float(em[4])),
			em[0], float(em[1]), float(em[2]), float(em[3]))

	if collide_r > 0.0:
		var body := StaticBody2D.new()
		body.collision_layer = 1
		body.collision_mask = 0
		body.position = pos
		var cs := CollisionShape2D.new()
		var shape := CircleShape2D.new()
		shape.radius = collide_r
		cs.shape = shape
		body.add_child(cs)
		host.add_child(body)
	return wrap


# A wide prop (a tent, the stage, a stall) needs a BOX blocker, not a disc.
static func place_wide(host: Node2D, name: String, world_h: float, pos: Vector2,
		block: Vector2, flip: bool = false) -> Node2D:
	var wrap: Node2D = place(host, name, world_h, pos, 0.0, flip)
	if wrap == null:
		return null
	if block.x > 0.0 and block.y > 0.0:
		var body := StaticBody2D.new()
		body.collision_layer = 1
		body.collision_mask = 0
		body.position = pos + Vector2(0, -block.y * 0.5)
		var cs := CollisionShape2D.new()
		var shape := RectangleShape2D.new()
		shape.size = block
		cs.shape = shape
		body.add_child(cs)
		host.add_child(body)
	return wrap


# Bunting strung between two points — repeats a banner piece along the line.
static func string_bunting(host: Node2D, a: Vector2, b: Vector2, name: String = "bunting_a",
		h: float = 34.0) -> void:
	var t: ImageTexture = tex(name, h)
	if t == null:
		return
	var step: float = maxf(24.0, float(t.get_width()) - 4.0)
	var d: float = a.distance_to(b)
	var n: int = int(d / step)
	if n <= 0:
		return
	var dir: Vector2 = (b - a) / float(n)
	for i in range(n + 1):
		var spr := Sprite2D.new()
		spr.texture = t
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		spr.position = a + dir * float(i)
		spr.z_as_relative = false
		spr.z_index = 3
		host.add_child(spr)


static var _shadow_cache: ImageTexture = null

static func _shadow_texture() -> ImageTexture:
	if _shadow_cache != null:
		return _shadow_cache
	var n: int = 32
	var im := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in range(n):
		for x in range(n):
			var d: float = Vector2(float(x) - 15.5, float(y) - 15.5).length() / 15.5
			var a: float = clampf(1.0 - d, 0.0, 1.0) * 0.28
			im.set_pixel(x, y, Color(0, 0, 0, a))
	_shadow_cache = ImageTexture.create_from_image(im)
	return _shadow_cache
