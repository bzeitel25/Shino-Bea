extends RefCounted

# ============================================================
# BiomeGround.gd — Run 85 (2026-06-18) — shared real-art ground baker
# ============================================================
# Neutral engine shared by the per-biome tileset modules. Bakes a
# high-res ground image from a biome's OWN sheet: a clean floor-fill
# tile on FLOOR/VOID/BRIDGE cells and the biome's liquid tile (water /
# lava / ice) on river cells (val == 2), with a soft rim at every liquid
# border. It is NOT the beach module and reads no beach art — each biome
# passes its own sheet + tile rects.
#
# cfg keys used here:
#   sheet (res:// PNG), floor_rect [x,y,w,h], liquid_rect [x,y,w,h],
#   rim (Color — foam/crust tint at liquid edges),
#   rim_light (bool — true lightens toward rim [water], false darkens [lava]).
# ============================================================

const CELL_PX: int = 64           # baked px per 32px world cell
const WORLD_CELL: float = 32.0
const RIM_PX: int = 10            # liquid-edge rim width (baked px)
const GROUND_Z: int = -34

static var _sheet_cache: Dictionary = {}   # path → Image
static var _tile_cache: Dictionary = {}    # key → resized Image


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


static func _sheet(path: String) -> Image:
	if not _sheet_cache.has(path):
		_sheet_cache[path] = _load_png(path)
	return _sheet_cache[path]


static func available(cfg: Dictionary) -> bool:
	return _sheet(cfg["sheet"]) != null


# Crop a rect from the sheet, resize to CELL_PX, cache. opt darken for variety.
static func _tile(cfg: Dictionary, key: String, rect: Array, darken: float) -> Image:
	var ck: String = cfg["sheet"] + key
	if _tile_cache.has(ck):
		return _tile_cache[ck]
	var sheet: Image = _sheet(cfg["sheet"])
	var sub: Image = sheet.get_region(Rect2i(rect[0], rect[1], rect[2], rect[3]))
	sub.resize(CELL_PX, CELL_PX, Image.INTERPOLATE_LANCZOS)
	if sub.get_format() != Image.FORMAT_RGBA8:
		sub.convert(Image.FORMAT_RGBA8)
	if darken > 0.0:
		for y in range(CELL_PX):
			for x in range(CELL_PX):
				var c: Color = sub.get_pixel(x, y)
				c.r *= (1.0 - darken); c.g *= (1.0 - darken); c.b *= (1.0 - darken)
				sub.set_pixel(x, y, c)
	_tile_cache[ck] = sub
	return sub


static func _floor_variants(cfg: Dictionary) -> Array:
	return [
		_tile(cfg, "f0", cfg["floor_rect"], 0.0),
		_tile(cfg, "f1", cfg["floor_rect"], 0.04),
		_tile(cfg, "f2", cfg["floor_rect"], 0.08),
	]


static func _hpick(arr: Array, ci: int, cj: int) -> Image:
	var h: int = abs(hash(Vector2i(ci * 73856093, cj * 19349663)))
	return arr[h % arr.size()]


static func _is_liquid(layout: RefCounted, ci: int, cj: int) -> bool:
	return layout.val(ci, cj) == 2


static func make_ground(cfg: Dictionary, half: Vector2, layout: RefCounted,
		seed_val: int) -> Sprite2D:
	if _sheet(cfg["sheet"]) == null:
		return null
	var gw: int = layout.gw
	var gh: int = layout.gh
	var img := Image.create(gw * CELL_PX, gh * CELL_PX, false, Image.FORMAT_RGBA8)
	var floor_t: Array = _floor_variants(cfg)
	var liquid_t: Image = _tile(cfg, "liq", cfg["liquid_rect"], 0.0)
	var src_rect := Rect2i(0, 0, CELL_PX, CELL_PX)

	for cj in range(gh):
		for ci in range(gw):
			var dst := Vector2i(ci * CELL_PX, cj * CELL_PX)
			var tile: Image = liquid_t if _is_liquid(layout, ci, cj) else _hpick(floor_t, ci, cj)
			img.blit_rect(tile, src_rect, dst)

	_bake_rim(img, layout, gw, gh, cfg)

	var spr := Sprite2D.new()
	spr.name = "TerrainGround"
	spr.centered = false
	spr.position = Vector2(-half.x, -half.y)
	spr.scale = Vector2(WORLD_CELL / float(CELL_PX), WORLD_CELL / float(CELL_PX))
	spr.z_index = GROUND_Z
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	spr.texture = ImageTexture.create_from_image(img)
	return spr


# Soft rim at every liquid border (foam for water, dark crust for lava).
static func _bake_rim(img: Image, layout: RefCounted, gw: int, gh: int, cfg: Dictionary) -> void:
	var rim: Color = cfg["rim"]
	var light: bool = cfg["rim_light"]
	for cj in range(gh):
		for ci in range(gw):
			if not _is_liquid(layout, ci, cj):
				continue
			var n: bool = _is_liquid(layout, ci, cj - 1)
			var s: bool = _is_liquid(layout, ci, cj + 1)
			var w: bool = _is_liquid(layout, ci - 1, cj)
			var e: bool = _is_liquid(layout, ci + 1, cj)
			if n and s and w and e:
				continue
			var x0: int = ci * CELL_PX
			var y0: int = cj * CELL_PX
			for py in range(CELL_PX):
				for px in range(CELL_PX):
					var dmin: int = 9999
					if not n:
						dmin = min(dmin, py)
					if not s:
						dmin = min(dmin, CELL_PX - 1 - py)
					if not w:
						dmin = min(dmin, px)
					if not e:
						dmin = min(dmin, CELL_PX - 1 - px)
					if dmin < RIM_PX:
						var t: float = (1.0 - float(dmin) / float(RIM_PX)) * (0.85 if light else 0.6)
						var c: Color = img.get_pixel(x0 + px, y0 + py)
						img.set_pixel(x0 + px, y0 + py, c.lerp(rim, t))
