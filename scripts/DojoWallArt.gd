extends RefCounted

# ============================================================
# DojoWallArt.gd — Run 171 (2026-09-02) — shared wall-face baker
# ============================================================
# Lifted verbatim out of Dojo.gd so the Cake Dojo (the Shadow Sensei
# summit duel) can bake ITS north walls through the exact same code
# path — only the art folder changes. One implementation means the
# two rooms can never drift apart, which is the whole point of the
# cake room being a parallel of the dojo.
#
# A "run" is one stretch of north wall: a FEATURE section (the
# tokonoma alcove behind Sensei, an arched window over a bedroom)
# centred on its landmark, with the remainder filled by shoji
# screens / plaster panels / the odd structural post. The finished
# strip bakes into a single Sprite2D that rises INTO the void above
# the room's top edge, so it never covers walkable floor.
#
#   WA.bake_run(host, x0, x1, base_y, "wall_alcove", 0.0, DIR)
#
# ── Run 163b LOCK (kept from Dojo.gd) ────────────────────────
# Never trust wall art to be flush to its own bounds. wall_alcove.png
# is 117px wide but its art stops at x=111; blitting the padded width
# and resuming the fill past it punched a black slit clean through the
# north wall. Feature art is therefore trimmed to its opaque column
# span before placement, and the finished bake gets its top/bottom
# padding clamped shut by _seal_edges().
# ============================================================

const DIR_DOJO: String = "res://Assets/Tilesets/Dojo_props/wall/"
const DIR_CAKE: String = "res://Assets/Tilesets/CakeDojo_props/wall/"
const FACE_H: int = 155   # native 310px strip halved 2:1

# Fill sequence used between/around the feature section.
const FILL_SEQ: Array = ["wall_shoji_a", "wall_shoji_b", "wall_plain_a", "wall_post",
	"wall_plain_b", "wall_shoji_a", "wall_plain_c"]

const EDGE_SCAN: int = 6

static var _cache: Dictionary = {}   # dir+name -> Image (missing cached as false)


static func wall_img(name: String, dir: String = DIR_DOJO) -> Image:
	var key: String = dir + name
	if _cache.has(key):
		var c = _cache[key]
		return c if c is Image else null
	var p: String = dir + name + ".png"
	var img: Image = null
	if ResourceLoader.exists(p):
		var r: Resource = ResourceLoader.load(p)
		if r is Texture2D:
			img = (r as Texture2D).get_image()
	if img == null:
		var abs_path: String = ProjectSettings.globalize_path(p)
		if FileAccess.file_exists(abs_path):
			var im := Image.new()
			if im.load(abs_path) == OK:
				img = im
	if img == null:
		push_warning("[DojoWallArt] Missing wall art: %s" % p)
		_cache[key] = false
		return null
	img.convert(Image.FORMAT_RGBA8)
	_cache[key] = img
	return img


static func bake_run(host: Node2D, x0: float, x1: float, base_y: float,
		feature: String, feature_cx: float, dir: String = DIR_DOJO) -> void:
	var w: int = int(round(x1 - x0))
	if w <= 0:
		return
	var img := Image.create(w, FACE_H, false, Image.FORMAT_RGBA8)

	# Feature section first, centred on its landmark (clamped into the run).
	var fx0: int = -1
	var fx1: int = -1
	var feat: Image = wall_img(feature, dir)
	if feat != null:
		feat = _trim_empty_columns(feat)
		fx0 = clampi(int(feature_cx - x0) - feat.get_width() / 2, 0, maxi(w - feat.get_width(), 0))
		fx1 = mini(fx0 + feat.get_width(), w)
		img.blit_rect(feat, Rect2i(0, 0, fx1 - fx0, FACE_H), Vector2i(fx0, 0))

	var idx: int = 0
	var cur: int = 0
	var guard: int = 0
	while cur < w and guard < 96:
		guard += 1
		if fx0 >= 0 and cur >= fx0 and cur < fx1:
			cur = fx1
			continue
		var s_img: Image = wall_img(FILL_SEQ[idx % FILL_SEQ.size()], dir)
		idx += 1
		if s_img == null:
			return
		var limit: int = w
		if fx0 >= 0 and cur < fx0:
			limit = fx0
		if limit - cur < s_img.get_width():
			# Crop with plaster, never through the middle of a shoji panel.
			var plain: Image = wall_img("wall_plain_b", dir)
			if plain != null:
				s_img = plain
		var take: int = mini(s_img.get_width(), limit - cur)
		if take <= 0:
			cur = limit
			continue
		img.blit_rect(s_img, Rect2i(0, 0, take, FACE_H), Vector2i(cur, 0))
		cur += take

	_seal_edges(img)

	var spr := Sprite2D.new()
	spr.texture = ImageTexture.create_from_image(img)
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.centered = false
	spr.position = Vector2(x0, base_y - float(FACE_H))
	host.add_child(spr)


# Drop fully-transparent columns from both edges (interior holes are art, and
# are left alone). Returns the source untouched when there's nothing to trim.
static func _trim_empty_columns(src: Image) -> Image:
	var w: int = src.get_width()
	var h: int = src.get_height()
	var lo: int = 0
	while lo < w and _column_empty(src, lo, h):
		lo += 1
	if lo >= w:
		return src            # entirely blank — let the caller deal with it
	var hi: int = w - 1
	while hi > lo and _column_empty(src, hi, h):
		hi -= 1
	if lo == 0 and hi == w - 1:
		return src
	var out := Image.create(hi - lo + 1, h, false, Image.FORMAT_RGBA8)
	out.blit_rect(src, Rect2i(lo, 0, hi - lo + 1, h), Vector2i(0, 0))
	return out


static func _column_empty(src: Image, x: int, h: int) -> bool:
	for y in range(h):
		if src.get_pixel(x, y).a > 0.02:
			return false
	return true


# Every wall tile carries 1–2 transparent rows of splice padding at its top and
# bottom edge. Unsealed those become hairlines of void along the wall's edges.
# Extend each column's outermost OPAQUE pixel outward to close them. Only the
# edge bands are scanned, so the alcove's interior transparency is never touched.
static func _seal_edges(img: Image) -> void:
	var w: int = img.get_width()
	var h: int = img.get_height()
	var scan: int = mini(EDGE_SCAN, h / 2)
	for x in range(w):
		var top: int = 0
		while top < scan and img.get_pixel(x, top).a < 0.75:
			top += 1
		if top > 0 and top < scan:
			var fill_top: Color = img.get_pixel(x, top)
			for y in range(top):
				img.set_pixel(x, y, fill_top)
		var bot: int = h - 1
		while bot > h - 1 - scan and img.get_pixel(x, bot).a < 0.75:
			bot -= 1
		if bot < h - 1 and bot > h - 1 - scan:
			var fill_bot: Color = img.get_pixel(x, bot)
			for y in range(bot + 1, h):
				img.set_pixel(x, y, fill_bot)
