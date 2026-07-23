extends RefCounted

# ============================================================
# BiomeWalls.gd — Run 86 (2026-06-18) — default cliff-frame border
# ============================================================
# Lays the existing hand-authored Cliff Faces sheet as a clean 9-slice
# border ring around ANY biome's room, leaving a tidy opening at every
# gate. This is the shared DEFAULT wall for all star-arm biomes (jungle /
# swamp / caverns / peaks); the beach keeps its own richer version with
# totems + cave-mouth arches (BeachTileset.make_walls). Per-biome custom
# walls can replace this later.
#
# Pure decoration: collision + gate bodies stay on DreamRoom's hidden
# wall/gate rects. We only hide their brown ColorRect visuals and lay the
# cliff ring on top.
# ============================================================

const CLIFF_PATH: String = "res://Assets/Tilesets/Beach_props/Cliff Faces .png"
const CLIFF_TILE: float = 58.0           # world px per cliff tile
const CLIFF_SEAM: float = 1.5            # sub-pixel bleed so tiles touch (no hairline)
const PROP_Z: int = -12

# OPAQUE bounds of each tile on the 750x750 sheet (corners + 3 top/bottom
# edge variants + 2 left/right edge variants). Matches BeachTileset.
const CLIFF_CORNERS: Dictionary = {
	"corner_tl": [25, 95, 130, 137],
	"corner_tr": [598, 95, 128, 137],
	"corner_bl": [25, 518, 130, 137],
	"corner_br": [598, 518, 128, 137],
}
const CLIFF_TOP: Array    = [[166, 95, 136, 137], [306, 95, 140, 137], [449, 95, 136, 137]]
const CLIFF_BOTTOM: Array = [[166, 518, 136, 137], [306, 518, 140, 137], [449, 518, 136, 137]]
const CLIFF_LEFT: Array   = [[25, 237, 130, 136], [25, 376, 130, 138]]
const CLIFF_RIGHT: Array  = [[598, 237, 128, 136], [598, 376, 128, 138]]

static var _sheet: Image = null
static var _sheet_tried: bool = false
static var _tex_cache: Dictionary = {}


static func _load_png(path: String) -> Image:
	var out: Image = null
	if ResourceLoader.exists(path):
		var res: Resource = ResourceLoader.load(path)
		if res is Texture2D:
			out = (res as Texture2D).get_image()
	if out == null:
		var abs_path: String = ProjectSettings.globalize_path(path)
		if FileAccess.file_exists(abs_path):
			var img := Image.new()
			if img.load(abs_path) == OK:
				out = img
	if out != null and out.get_format() != Image.FORMAT_RGBA8:
		out.convert(Image.FORMAT_RGBA8)
	return out


static func _cliff_sheet() -> Image:
	if not _sheet_tried:
		_sheet_tried = true
		_sheet = _load_png(CLIFF_PATH)
	return _sheet


static func available() -> bool:
	return _cliff_sheet() != null


static func _cliff_tex(key: String, rect: Array) -> ImageTexture:
	if _tex_cache.has(key):
		return _tex_cache[key]
	var sub: Image = _cliff_sheet().get_region(Rect2i(rect[0], rect[1], rect[2], rect[3]))
	if sub.get_format() != Image.FORMAT_RGBA8:
		sub.convert(Image.FORMAT_RGBA8)
	var tex: ImageTexture = ImageTexture.create_from_image(sub)
	_tex_cache[key] = tex
	return tex


static func _cliff_pick(arr: Array, prefix: String, rng: RandomNumberGenerator) -> ImageTexture:
	var i: int = rng.randi() % arr.size()
	return _cliff_tex("%s%d" % [prefix, i], arr[i])


static func _add_cliff(root: Node2D, tex: ImageTexture, center: Vector2, w: float, h: float) -> void:
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.centered = true
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	spr.position = center
	spr.scale = Vector2((w + CLIFF_SEAM) / float(tex.get_width()), (h + CLIFF_SEAM) / float(tex.get_height()))
	root.add_child(spr)


# Lay the cliff ring. gate_positions are gate-center world coords (relative to
# the room center); each punches a clean opening in the matching wall run.
static func make_walls(half: Vector2, gate_positions: Array, seed_val: int) -> Node2D:
	var root := Node2D.new()
	root.name = "BiomeWalls"
	root.z_index = PROP_Z
	if _cliff_sheet() == null:
		return root
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 2246822519 + 53
	var t: float = CLIFF_TILE
	var ov: float = 12.0
	var cx: float = half.x - ov + t * 0.5
	var cy: float = half.y - ov + t * 0.5
	var gate_clear: float = t * 0.62

	# Four corners.
	_add_cliff(root, _cliff_tex("corner_tl", CLIFF_CORNERS["corner_tl"]), Vector2(-cx, -cy), t, t)
	_add_cliff(root, _cliff_tex("corner_tr", CLIFF_CORNERS["corner_tr"]), Vector2( cx, -cy), t, t)
	_add_cliff(root, _cliff_tex("corner_bl", CLIFF_CORNERS["corner_bl"]), Vector2(-cx,  cy), t, t)
	_add_cliff(root, _cliff_tex("corner_br", CLIFF_CORNERS["corner_br"]), Vector2( cx,  cy), t, t)

	var run_x0: float = -cx + t * 0.5
	var run_x1: float =  cx - t * 0.5
	var run_y0: float = -cy + t * 0.5
	var run_y1: float =  cy - t * 0.5

	var top_open: Array = []
	var bot_open: Array = []
	var left_open: Array = []
	var right_open: Array = []
	for gp in gate_positions:
		var g: Vector2 = gp
		if absf(g.x) > half.x:
			if g.x < 0.0:
				left_open.append([g.y, gate_clear])
			else:
				right_open.append([g.y, gate_clear])
		elif g.y < 0.0:
			top_open.append([g.x, gate_clear])
		else:
			bot_open.append([g.x, gate_clear])

	_tile_wall_axis(root, run_x0, run_x1, -cy, t, true, CLIFF_TOP, "top", top_open, rng)
	_tile_wall_axis(root, run_x0, run_x1,  cy, t, true, CLIFF_BOTTOM, "bot", bot_open, rng)
	_tile_wall_axis(root, run_y0, run_y1, -cx, t, false, CLIFF_LEFT, "lft", left_open, rng)
	_tile_wall_axis(root, run_y0, run_y1,  cx, t, false, CLIFF_RIGHT, "rgt", right_open, rng)
	return root


# Tile one wall run from a0..a1, leaving the given openings ([center, half_w])
# clear; each solid segment is filled with exact-fit tiles butting its ends.
static func _tile_wall_axis(root: Node2D, a0: float, a1: float, fixed: float, t: float,
		horizontal: bool, variants: Array, prefix: String, openings: Array,
		rng: RandomNumberGenerator) -> void:
	var cuts: Array = []
	for o in openings:
		cuts.append([o[0] - o[1], o[0] + o[1]])
	cuts.sort_custom(func(p, q): return p[0] < q[0])
	var seg_start: float = a0
	for c in cuts:
		var seg_end: float = minf(c[0], a1)
		_fit_run(root, seg_start, seg_end, fixed, t, horizontal, variants, prefix, rng)
		seg_start = maxf(seg_start, c[1])
	_fit_run(root, seg_start, a1, fixed, t, horizontal, variants, prefix, rng)


static func _fit_run(root: Node2D, a: float, b: float, fixed: float, t: float,
		horizontal: bool, variants: Array, prefix: String, rng: RandomNumberGenerator) -> void:
	var span: float = b - a
	if span < t * 0.5:
		return
	var n: int = max(1, int(round(span / t)))
	var tw: float = span / float(n)
	for k in range(n):
		var p: float = a + (float(k) + 0.5) * tw
		var center: Vector2 = Vector2(p, fixed) if horizontal else Vector2(fixed, p)
		var w: float = tw if horizontal else t
		var h: float = t if horizontal else tw
		_add_cliff(root, _cliff_pick(variants, prefix, rng), center, w, h)
