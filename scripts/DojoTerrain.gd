extends RefCounted

# ============================================================
# DojoTerrain.gd — Run 144 (2026-07-15) — real-art dojo flooring
# ============================================================
# Replaces the Run 72 procedural planks/tatami with baked tiles cut
# from the Cake-Dojo master sheet (Assets/Tilesets/Dojo_props/floor/):
#
#   * plank_v_0..11    — dark vertical wood planks (main floor)
#   * tat_l_r{r}c{c}   — light cake-tatami, 4x4 nine-slice block
#                        (framed border + woven interior) — training mat
#   * tat_d_r{r}c{c}   — dark-framed tatami block — sleeping nooks
#
# Same contract as before: everything bakes into ONE Sprite2D
# ("DojoGround", z=-30), TEXEL=2, NEAREST filtering, deterministic.
# Tatami rects of ANY size work — the 4x4 block is nine-sliced:
# corner cells stay put, edge cells tile along the border, and the
# central 2x2 weave cells tile across the middle.
#
# Usage (Dojo.gd): unchanged —
#   const DT = preload("res://scripts/DojoTerrain.gd")
#   DT.build(self, [main_rect, shino_rect, bea_rect], [
#       {"rect": Rect2(...), "kind": "training"},
#       {"rect": Rect2(...), "kind": "tan"},
#   ], seed_val)
#
# floor_rects : Array[Rect2]  — walkable wooden-plank regions (world coords)
# tatami      : Array[Dict]   — {rect: Rect2, kind: "training"|"tan"}
# dir         : String        — Run 171: which floor/ folder to cut tiles from.
#               Defaults to the Dojo's. The Cake Dojo (summit duel) passes
#               CakeDojo_props/floor/ and gets chocolate planks + strawberry
#               tatami through this exact same baker. The image cache is keyed
#               by dir+name so the two sets can never bleed into each other.
# ============================================================

const TEXEL: int = 2
const CELL: float = 64.0          # world px per floor tile (32 img px)
const TILE: int = 32              # img px per tile
const FLOOR_DIR: String = "res://Assets/Tilesets/Dojo_props/floor/"
const PLANK_COUNT: int = 12
const WOOD: Color = Color(0.26, 0.17, 0.14)     # flat fallback if art missing
const STRAW: Color = Color(0.70, 0.62, 0.40)    # flat tatami fallback

static var _cache: Dictionary = {}   # name -> Image (missing cached as false)


# ---------------------------------------------------------------------------
# Asset loading — ResourceLoader when imported, Image.load fallback pre-import
# (same pattern as TownTileset._load_img).
# ---------------------------------------------------------------------------
static func _load_img(name: String, dir: String = FLOOR_DIR) -> Image:
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
	if img != null:
		img.convert(Image.FORMAT_RGBA8)
		if img.get_width() != TILE or img.get_height() != TILE:
			img.resize(TILE, TILE, Image.INTERPOLATE_NEAREST)
	else:
		push_warning("[DojoTerrain] Missing floor art: %s" % p)
	_cache[key] = img if img != null else false
	return img


# All 16 cells of one tatami nine-slice block ([] if any are missing).
static func _tat_tiles(prefix: String, dir: String = FLOOR_DIR) -> Array:
	var arr: Array = []
	for r in range(4):
		for c in range(4):
			var im: Image = _load_img("%s_r%dc%d" % [prefix, r, c], dir)
			if im == null:
				return []
			arr.append(im)
	return arr


# ---------------------------------------------------------------------------
# Public entry — bakes the ground Sprite2D under `parent`.
# ---------------------------------------------------------------------------
static func build(parent: Node2D, floor_rects: Array, tatami: Array, seed_val: int,
		dir: String = FLOOR_DIR) -> void:
	var old: Node = parent.get_node_or_null("DojoGround")
	if old:
		old.queue_free()

	# Bounding box over every region (floor + mats).
	var minx: float = INF
	var miny: float = INF
	var maxx: float = -INF
	var maxy: float = -INF
	for r in floor_rects:
		minx = min(minx, (r as Rect2).position.x)
		miny = min(miny, (r as Rect2).position.y)
		maxx = max(maxx, (r as Rect2).end.x)
		maxy = max(maxy, (r as Rect2).end.y)
	for m in tatami:
		var mr: Rect2 = m.rect
		minx = min(minx, mr.position.x); miny = min(miny, mr.position.y)
		maxx = max(maxx, mr.end.x);      maxy = max(maxy, mr.end.y)

	var w: int = int(ceil((maxx - minx) / float(TEXEL)))
	var h: int = int(ceil((maxy - miny) / float(TEXEL)))
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))   # everything outside the rooms stays transparent

	# Tile art (sliced from the Cake-Dojo master sheet).
	var planks: Array = []
	for i in range(PLANK_COUNT):
		var pim: Image = _load_img("plank_v_%d" % i, dir)
		if pim != null:
			planks.append(pim)
	var mats: Dictionary = {
		"training": _tat_tiles("tat_l", dir),
		"tan": _tat_tiles("tat_d", dir),
	}

	for y in range(h):
		for x in range(w):
			var wx: float = minx + (float(x) + 0.5) * float(TEXEL)
			var wy: float = miny + (float(y) + 0.5) * float(TEXEL)
			var p := Vector2(wx, wy)

			# Tatami first (mats sit on top of the plank floor).
			var painted: bool = false
			for m in tatami:
				if (m.rect as Rect2).has_point(p):
					var tiles: Array = mats.get(String(m.get("kind", "training")), [])
					if tiles.is_empty():
						img.set_pixel(x, y, STRAW)
					else:
						img.set_pixel(x, y, _tat_px(tiles, m.rect, wx, wy))
					painted = true
					break
			if painted:
				continue

			# Otherwise plank floor if inside any walkable region.
			for r in floor_rects:
				if (r as Rect2).has_point(p):
					img.set_pixel(x, y, _plank_px(planks, wx, wy))
					break

	var spr := Sprite2D.new()
	spr.name = "DojoGround"
	spr.z_index = -30
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.texture = ImageTexture.create_from_image(img)
	spr.scale = Vector2(TEXEL, TEXEL)
	spr.position = Vector2((minx + maxx) * 0.5, (miny + maxy) * 0.5)
	parent.add_child(spr)


# ---------------------------------------------------------------------------
# Wooden plank floor — hash-picked 64px tiles on the global world grid, so
# every room shares one seamless floor no matter how the rects overlap.
# ---------------------------------------------------------------------------
static func _plank_px(planks: Array, wx: float, wy: float) -> Color:
	if planks.is_empty():
		return WOOD
	var ci: int = int(floor(wx / CELL))
	var cj: int = int(floor(wy / CELL))
	var idx: int = abs(hash(Vector2i(ci * 73856093, cj * 19349663))) % planks.size()
	var sx: int = posmod(int(floor(wx / float(TEXEL))), TILE)
	var sy: int = posmod(int(floor(wy / float(TEXEL))), TILE)
	return (planks[idx] as Image).get_pixel(sx, sy)


# ---------------------------------------------------------------------------
# Tatami mats — nine-slice of a 4x4 tile block over an arbitrary rect.
# Bands hug the rect border at native tile size; the 2x2 interior cells
# tile across the middle (keeps the woven-panel alternation from the sheet).
# ---------------------------------------------------------------------------
static func _tat_px(tiles: Array, rect: Rect2, wx: float, wy: float) -> Color:
	var lx: int = int(floor((wx - rect.position.x) / float(TEXEL)))
	var ly: int = int(floor((wy - rect.position.y) / float(TEXEL)))
	var wpx: int = maxi(int(floor(rect.size.x / float(TEXEL))), 2)
	var hpx: int = maxi(int(floor(rect.size.y / float(TEXEL))), 2)
	lx = clampi(lx, 0, wpx - 1)
	ly = clampi(ly, 0, hpx - 1)

	# Mats smaller than the native 4x4 block: scale the WHOLE block to the
	# rect instead of nine-slicing (banding degenerates into a pinwheel of
	# corner cells at this size — a shrunk full mat keeps the framed look).
	var block_px: int = TILE * 4
	if wpx <= block_px or hpx <= block_px:
		var bx: int = clampi(int(float(lx) * float(block_px) / float(wpx)), 0, block_px - 1)
		var by: int = clampi(int(float(ly) * float(block_px) / float(hpx)), 0, block_px - 1)
		var bcol: int = floori(float(bx) / float(TILE))
		var brow: int = floori(float(by) / float(TILE))
		return (tiles[brow * 4 + bcol] as Image).get_pixel(bx % TILE, by % TILE)

	var col: int
	var sx: int
	if lx < TILE and lx <= wpx - 1 - lx:      # left frame band
		col = 0
		sx = mini(lx, TILE - 1)
	elif wpx - 1 - lx < TILE:                  # right frame band
		col = 3
		sx = TILE - 1 - mini(wpx - 1 - lx, TILE - 1)
	else:                                      # woven interior (2-tile pattern)
		var u: int = posmod(lx - TILE, TILE * 2)
		col = 1 if u < TILE else 2
		sx = u % TILE

	var row: int
	var sy: int
	if ly < TILE and ly <= hpx - 1 - ly:      # top frame band
		row = 0
		sy = mini(ly, TILE - 1)
	elif hpx - 1 - ly < TILE:                  # bottom frame band
		row = 3
		sy = TILE - 1 - mini(hpx - 1 - ly, TILE - 1)
	else:
		var v: int = posmod(ly - TILE, TILE * 2)
		row = 1 if v < TILE else 2
		sy = v % TILE

	return (tiles[row * 4 + col] as Image).get_pixel(sx, sy)
