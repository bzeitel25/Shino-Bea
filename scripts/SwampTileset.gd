extends RefCounted

# ============================================================
# SwampTileset.gd — Run 93 (2026-06-20) — Pickle Mire real-art pass
# ============================================================
# Dedicated to the SWAMP biome only. Owns Assets/Tilesets/Swamp_props
# end-to-end now: baked mire GROUND (incl. an outer apron of swamp floor
# with bubbling purple pools/rivers), hand-cut PROPS, and a swamp-TREE
# arena wall FRAME + outer forest. No longer routes through the shared
# BiomeProps engine — every swamp placement decision lives here so the
# biome can be tuned and locked down independently (Beach is the model).
#
# Source art (all clean PNGs on a transparent background — sliced 1:1 from
# Bruno's three sheets, no keying needed):
#   Swamp_props/srock_1..7, sspike_1..4, srubble_1   — rock obstacles
#   Swamp_props/slog_1..3                            — log obstacles
#   Swamp_props/stree_1..5                           — trees (frame + accents)
#   Swamp_props/schomp_1..3                          — carnivorous "Chompin"
#       plants (red flytrap / purple worm / pitcher-mouth). Obstacle+trap
#       HYBRID: stand in the wall line, BITE for contact damage (TrapZone
#       "chomp"). Placed sparingly, replacing a rock/log on the wall.
#   Swamp_props/smush_1..8, sflower_1..4, ssprout_1..4, spod_1
#       — run-over GROUND decor (mushrooms / flowers / sprouts / closed bulb).
#
# What this module produces for the SWAMP biome (DreamTerrain branches to it;
# DreamRoom branches to make_walls):
#   make_ground — baked mire floor + poison rivers (V_WATER) + bubbling
#       poison pools at traps, PLUS an outer apron of swamp floor seeded with
#       extra bubbling pools / liquid streaks so the surround reads as bog.
#   make_props  — rock/log obstacles fencing the player paths (overhead so a
#       ninja passes BEHIND them, DASH flies over), a few free-standing log
#       barriers with their own dashable_barrier colliders, sparse chompers
#       on the wall line (bite trap), tall spike/tree accents, a coverage
#       pass killing invisible-wall gaps, and flat mushroom/flower decor.
#   make_walls  — a clean swamp-TREE frame ringing the arena (gate gaps left
#       open) backed by a filled outer forest of trees so the border reads
#       as a proper swamp wood/bog.
#
# Ground tile grid mapped off Swamp Tileset.png (unchanged from Run 86).
# Import-agnostic load (ResourceLoader first, raw Image.load fallback) so it
# works the first run before Godot's import pass.
# ============================================================

const SHEET_PATH: String = "res://Assets/Tilesets/Swamp Tileset.png"
const PROP_DIR: String = "res://Assets/Tilesets/Swamp_props/"
const TRAP = preload("res://scripts/TrapZone.gd")

# --- Prop name pools (sliced PNGs in Swamp_props/) --------------------------
const ROCK_NAMES: Array = ["srock_1", "srock_2", "srock_3", "srock_4",
	"srock_5", "srock_6", "srock_7"]
const SPIKE_NAMES: Array = ["sspike_1", "sspike_2", "sspike_3", "sspike_4"]
const RUBBLE_NAMES: Array = ["srubble_1"]
const LOG_NAMES: Array = ["slog_1", "slog_2", "slog_3"]
const CHOMP_NAMES: Array = ["schomp_1", "schomp_2", "schomp_3"]
# Trees: stree_1 sapling → stree_5 big willow. Big ones build the wall frame;
# the small two also sprinkle the outer forest + the odd interior accent.
const TREE_BIG: Array = ["stree_3", "stree_4", "stree_5"]
const TREE_MID: Array = ["stree_2", "stree_3", "stree_4"]
const TREE_SMALL: Array = ["stree_1", "stree_2"]
# Flat run-over decor — [name, height(world cells), weight].
const DECOR_TABLE: Array = [
	["smush_1", 0.78, 3], ["smush_2", 0.92, 2], ["smush_3", 0.80, 3],
	["smush_4", 0.90, 2], ["smush_5", 0.86, 2], ["smush_6", 0.80, 3],
	["smush_7", 0.82, 2], ["smush_8", 0.80, 3],
	["sflower_1", 0.85, 2], ["sflower_2", 0.82, 2], ["sflower_3", 0.88, 1],
	["sflower_4", 0.88, 1], ["ssprout_1", 0.70, 2], ["ssprout_2", 0.58, 2],
	["ssprout_3", 0.44, 2], ["ssprout_4", 0.46, 2], ["spod_1", 0.95, 1],
]

# --- Ground tile grid (terrain-variation block) ----------------------------
const GX0: float = 848.0            # col-0 CONTENT start (just past the ~2px grid line)
const GY0: float = 48.0             # row-0 content start
const PITCH: float = 140.6          # true grid pitch (was 137.6 — drifted into the gridlines by col 4-5)
const INSET: int = 4                # crop inside the content → fully clears the 2-3px white grid line
const CELL_PX: int = 64             # baked px per 32px world cell (2× supersample)
const WORLD_CELL: float = 32.0
const RIM_PX: int = 9               # froth-rim width at liquid borders (baked px)
const GROUND_Z: int = -34
const PROP_Z: int = -12
const APRON_CELLS: int = 10         # swamp-floor apron baked beyond the arena (deep bog under the forest)

# (col,row) of the tiles we sample.
const FLOOR_CR: Array = [[0, 0], [1, 0], [0, 1], [1, 1]]
const RIVER_CR: Array = [[2, 3], [3, 3]]                   # dark purple swamp water
const POOL_CR:  Array = [[4, 0], [5, 1], [5, 0], [4, 1]]   # glowing bubbling poison

const FROTH: Color = Color(0.74, 0.88, 0.46)
const WATER_RIM: Color = Color(0.60, 0.54, 0.74)

# --- Placement tuning (props) ----------------------------------------------
const EDGE_KEEPOUT: float = 56.0
const GATE_CLEAR: float = 104.0
const OBSTACLE_CELLS: float = 1.35       # rock/log fence height (world cells)
const ACCENT_CELLS: float = 2.4          # spike / small-tree accent height

# --- Placement tuning (tree wall frame + forest) ---------------------------
const FRAME_MARGIN: float = 12.0         # frame-tree feet sit just outside the floor edge
const FRAME_STEP: float = 50.0           # spacing along the border → denser overlapping canopy wall
const FRAME_H_MIN: float = 2.7
const FRAME_H_MAX: float = 3.6
const FOREST_BAND_MIN: float = 18.0      # outer forest starts right behind the frame
const FOREST_DEPTH: float = 300.0        # roughly matches the bog-floor apron so trees stand on mire
const FOREST_STEP: float = 52.0          # grid pitch for the dense outer forest fill (canopies overlap heavily)
const BORDER_BAND_CELLS: int = 4         # inner void band (cells off the floor edge) packed with trees

# --- Gate exit lane (replaces the old wide circular keepout) ----------------
# A clear corridor the width of the exit gate, running from just inside the
# border straight OUT through the forest — the "hallway" the heroes run down to
# reach the next arena. Everything else outside the floor is packed with trees.
const GATE_LANE_HALF: float = 40.0       # hallway half-width (~80px ≈ the 64px gate gap + margin)
const GATE_LANE_FLARE: float = 0.07      # very slight outward widening so the path reads as receding
const GATE_LANE_BACK: float = 40.0       # keep the mouth of the hallway clear a bit inside the border
# Poison must never sit in or right beside the exit — keep it off the doorway.
const POISON_GATE_CLEAR: float = 104.0

static var _sheet_cache: Image = null
static var _sheet_tried: bool = false
static var _floor_cache: Array = []
static var _river_cache: Array = []
static var _pool_cache: Array = []
static var _prop_cache: Dictionary = {}   # name → ImageTexture (or null if missing)
static var _shadow_tex: ImageTexture = null
static var _bubble_frames: SpriteFrames = null   # 4-frame bubbling-poison animation
static var _river_frames: SpriteFrames = null    # 2-frame flowing-river animation


# ---------------------------------------------------------------------------
# Sheet + prop loading (import-agnostic).
# ---------------------------------------------------------------------------
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


static func _sheet() -> Image:
	if not _sheet_tried:
		_sheet_tried = true
		_sheet_cache = _load_png(SHEET_PATH)
		if _sheet_cache == null:
			push_warning("[SwampTileset] Could not load %s." % SHEET_PATH)
	return _sheet_cache


# A sliced prop PNG (already transparent — no keying). Cached; null when missing.
static func _prop_tex(name: String) -> ImageTexture:
	if _prop_cache.has(name):
		return _prop_cache[name]
	var img: Image = _load_png(PROP_DIR + name + ".png")
	var tex: ImageTexture = null
	if img != null:
		tex = ImageTexture.create_from_image(img)
	_prop_cache[name] = tex
	return tex


# ---------------------------------------------------------------------------
# Ground tile crop + variant builders.
# ---------------------------------------------------------------------------
static func _crop(cr: Array) -> Image:
	var sheet: Image = _sheet()
	var x: int = int(GX0 + float(cr[0]) * PITCH) + INSET
	var y: int = int(GY0 + float(cr[1]) * PITCH) + INSET
	var s: int = int(PITCH) - INSET * 2
	var sub: Image = sheet.get_region(Rect2i(x, y, s, s))
	sub.resize(CELL_PX, CELL_PX, Image.INTERPOLATE_LANCZOS)
	if sub.get_format() != Image.FORMAT_RGBA8:
		sub.convert(Image.FORMAT_RGBA8)
	# Grid lines are now cropped out by the corrected GX0/GY0/PITCH/INSET, so we
	# no longer run _strip_white here — that preserves the bright bubble highlights
	# in the poison tiles (which it would otherwise erase as "white").
	return sub


static func _strip_white(img: Image) -> void:
	var w: int = img.get_width()
	var h: int = img.get_height()
	for y in range(h):
		for x in range(w):
			var c: Color = img.get_pixel(x, y)
			var mx: float = maxf(c.r, maxf(c.g, c.b))
			var mn: float = minf(c.r, minf(c.g, c.b))
			if mn > 0.80 and (mx - mn) < 0.10:
				img.set_pixel(x, y, _nearest_nonwhite(img, x, y, w, h))


static func _nearest_nonwhite(img: Image, x: int, y: int, w: int, h: int) -> Color:
	for rad in range(1, 5):
		for off in [Vector2i(-rad, 0), Vector2i(rad, 0), Vector2i(0, -rad), Vector2i(0, rad),
				Vector2i(-rad, -rad), Vector2i(rad, rad), Vector2i(-rad, rad), Vector2i(rad, -rad)]:
			var nx: int = x + off.x
			var ny: int = y + off.y
			if nx < 0 or ny < 0 or nx >= w or ny >= h:
				continue
			var c: Color = img.get_pixel(nx, ny)
			var mx: float = maxf(c.r, maxf(c.g, c.b))
			var mn: float = minf(c.r, minf(c.g, c.b))
			if not (mn > 0.80 and (mx - mn) < 0.10):
				return c
	return Color(0.45, 0.30, 0.52)


static func _orient(src: Image, k: int) -> Image:
	var out: Image = src.duplicate()
	if k == 1 or k == 3:
		out.flip_x()
	if k == 2 or k == 3:
		out.flip_y()
	return out


static func _floor_variants() -> Array:
	if not _floor_cache.is_empty():
		return _floor_cache
	var out: Array = []
	for cr in FLOOR_CR:
		var base: Image = _crop(cr)
		for k in range(4):
			out.append(_orient(base, k))
	_floor_cache = out
	return out


static func _river_variants() -> Array:
	if not _river_cache.is_empty():
		return _river_cache
	var out: Array = []
	for cr in RIVER_CR:
		var base: Image = _crop(cr)
		for k in range(4):
			out.append(_orient(base, k))
	_river_cache = out
	return out


static func _pool_tiles() -> Array:
	if not _pool_cache.is_empty():
		return _pool_cache
	var out: Array = []
	for cr in POOL_CR:
		out.append(_crop(cr))
	_pool_cache = out
	return out


static func _hpick(arr: Array, ci: int, cj: int, salt: int) -> Image:
	var hh: int = abs(hash(Vector2i(ci * 73856093 + salt, cj * 19349663 + salt)))
	return arr[hh % arr.size()]


# ---------------------------------------------------------------------------
# Public availability API (matches what DreamTerrain / DreamRoom call).
# ---------------------------------------------------------------------------
static func available() -> bool:
	return _prop_tex("srock_1") != null or _prop_tex("slog_1") != null


static func ground_available() -> bool:
	return _sheet() != null


static func walls_available() -> bool:
	return _prop_tex("stree_4") != null or _prop_tex("stree_3") != null


# ===========================================================================
# GROUND — baked mire floor + poison rivers + bubbling pools + OUTER APRON.
# ===========================================================================
static func make_ground(half: Vector2, layout: RefCounted, seed_val: int) -> Sprite2D:
	if _sheet() == null:
		return null
	var gw: int = layout.gw
	var gh: int = layout.gh
	var m: int = APRON_CELLS
	var off: int = m * CELL_PX
	var img := Image.create((gw + 2 * m) * CELL_PX, (gh + 2 * m) * CELL_PX, false, Image.FORMAT_RGBA8)
	var floor_t: Array = _floor_variants()
	var river_t: Array = _river_variants()
	var src_rect := Rect2i(0, 0, CELL_PX, CELL_PX)

	for cj in range(-m, gh + m):
		for ci in range(-m, gw + m):
			var dst := Vector2i((ci + m) * CELL_PX, (cj + m) * CELL_PX)
			var tile: Image
			var inside: bool = ci >= 0 and ci < gw and cj >= 0 and cj < gh
			if inside and layout.val(ci, cj) == 2:           # V_WATER → poison river
				tile = _hpick(river_t, ci, cj, 1)
			else:                                            # floor / void / bridge / apron
				tile = _hpick(floor_t, ci, cj, 7)
			img.blit_rect(tile, src_rect, dst)

	# Run 94: poison liquid is NO LONGER baked into the ground as organic blobs
	# with froth rims (that produced the unnatural glowy puddle borders that cut
	# mid-tile). Rivers + bubbling pools are now clean grid-aligned ANIMATED tiles
	# laid down by make_liquid(). The ground here is pure mire mud (+ a static
	# river tile under V_WATER cells as a fallback). _bake_pools / _bake_river_rim
	# / _bake_apron_liquid / _draw_pool are kept below but intentionally unused.

	var off_world: float = float(m) * WORLD_CELL
	var spr := Sprite2D.new()
	spr.name = "TerrainGround"
	spr.centered = false
	spr.position = Vector2(-half.x - off_world, -half.y - off_world)
	spr.scale = Vector2(WORLD_CELL / float(CELL_PX), WORLD_CELL / float(CELL_PX))
	spr.z_index = GROUND_Z
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	spr.texture = ImageTexture.create_from_image(img)
	return spr


static func _is_river(layout: RefCounted, ci: int, cj: int) -> bool:
	return layout.val(ci, cj) == 2


# Bright froth rim wherever a river cell meets a non-river neighbour.
static func _bake_river_rim(img: Image, layout: RefCounted, gw: int, gh: int, off: int) -> void:
	for cj in range(gh):
		for ci in range(gw):
			if not _is_river(layout, ci, cj):
				continue
			var n: bool = _is_river(layout, ci, cj - 1)
			var s: bool = _is_river(layout, ci, cj + 1)
			var w: bool = _is_river(layout, ci - 1, cj)
			var e: bool = _is_river(layout, ci + 1, cj)
			if n and s and w and e:
				continue
			var x0: int = off + ci * CELL_PX
			var y0: int = off + cj * CELL_PX
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
						var t: float = (1.0 - float(dmin) / float(RIM_PX)) * 0.65
						var c: Color = img.get_pixel(x0 + px, y0 + py)
						img.set_pixel(x0 + px, y0 + py, c.lerp(WATER_RIM, t))


# Bubbling poison POOLS — one organic blob under every poison/slow trap, lined
# up with the TrapZone collision via the shared pool_wob harmonics.
static func _bake_pools(img: Image, half: Vector2, layout: RefCounted, seed_val: int, off: int) -> void:
	var pools: Array = _pool_tiles()
	if pools.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 2654435761 + 71
	var scale: float = float(CELL_PX) / WORLD_CELL
	var traps: Array = layout.get("trap_spots")
	if traps == null:
		return
	for t in traps:
		var ty: String = String((t as Dictionary).get("type", ""))
		if ty != "poison" and ty != "slow":
			continue
		var wp: Vector2 = (t as Dictionary).get("pos", Vector2.ZERO)
		var px: float = (wp.x + half.x) * scale + float(off)
		var py: float = (wp.y + half.y) * scale + float(off)
		var pr: float = float((t as Dictionary).get("pool_radius", 56.0))
		var r_cells: float = pr / WORLD_CELL
		var wob: Array = (t as Dictionary).get("pool_wob", [])
		_draw_pool(img, px, py, r_cells, wob, pools, rng)


# Outer apron liquid (Run 93): scatter bubbling purple pools + a couple of
# meandering liquid streaks in the apron band ONLY (outside the arena rect) so
# the swamp surround reads as a bog of pools and channels, not flat mud.
static func _bake_apron_liquid(img: Image, gw: int, gh: int, m: int, off: int, seed_val: int) -> void:
	var pools: Array = _pool_tiles()
	if pools.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 40503 + 211
	var iw: int = img.get_width()
	var ih: int = img.get_height()
	var in_x0: int = off + CELL_PX                       # arena rect (+1 cell margin)
	var in_y0: int = off + CELL_PX
	var in_x1: int = off + (gw - 1) * CELL_PX
	var in_y1: int = off + (gh - 1) * CELL_PX
	var pad: int = CELL_PX                                # keep pools off the frame seam

	# Scattered pools.
	var n_pools: int = int(float(gw + gh) * 0.55)
	var tries: int = 0
	var made: int = 0
	while made < n_pools and tries < n_pools * 6:
		tries += 1
		var px: int = rng.randi_range(pad, iw - pad)
		var py: int = rng.randi_range(pad, ih - pad)
		if px > in_x0 and px < in_x1 and py > in_y0 and py < in_y1:
			continue                                     # inside the arena → skip
		var r_cells: float = rng.randf_range(1.1, 3.0)
		_draw_pool(img, float(px), float(py), r_cells, [], pools, rng)
		made += 1

	# A few liquid streaks (river-ish channels) hugging the apron.
	for _s in range(rng.randi_range(2, 4)):
		var edge: int = rng.randi() % 4
		var sx: float
		var sy: float
		var dir: Vector2
		match edge:
			0:  sx = rng.randf_range(pad, iw - pad); sy = float(off) * 0.5; dir = Vector2(rng.randf_range(-0.4, 0.4), 1.0)
			1:  sx = rng.randf_range(pad, iw - pad); sy = float(ih) - float(off) * 0.5; dir = Vector2(rng.randf_range(-0.4, 0.4), -1.0)
			2:  sx = float(off) * 0.5; sy = rng.randf_range(pad, ih - pad); dir = Vector2(1.0, rng.randf_range(-0.4, 0.4))
			_:  sx = float(iw) - float(off) * 0.5; sy = rng.randf_range(pad, ih - pad); dir = Vector2(-1.0, rng.randf_range(-0.4, 0.4))
		dir = dir.normalized()
		var steps: int = rng.randi_range(5, 9)
		for k in range(steps):
			if sx > in_x0 and sx < in_x1 and sy > in_y0 and sy < in_y1:
				break                                    # don't run a channel into the arena
			_draw_pool(img, sx, sy, rng.randf_range(1.0, 1.7), [], pools, rng)
			dir = dir.rotated(rng.randf_range(-0.5, 0.5)).normalized()
			sx += dir.x * float(CELL_PX) * 0.9
			sy += dir.y * float(CELL_PX) * 0.9
			sx = clampf(sx, float(pad), float(iw - pad))
			sy = clampf(sy, float(pad), float(ih - pad))


# A single organic poison pool: noise-warped radius, bubbling fill, froth rim.
static func _draw_pool(img: Image, cx: float, cy: float, r_cells: float,
		wob_p: Array, pools: Array, rng: RandomNumberGenerator) -> void:
	var src: Image = pools[rng.randi() % pools.size()]
	var sw: int = src.get_width()
	var sh: int = src.get_height()
	var R: float = r_cells * float(CELL_PX)
	var a1: float = float(wob_p[0]) if wob_p.size() >= 6 else rng.randf_range(0.12, 0.26)
	var a2: float = float(wob_p[1]) if wob_p.size() >= 6 else rng.randf_range(0.06, 0.16)
	var a3: float = float(wob_p[2]) if wob_p.size() >= 6 else rng.randf_range(0.04, 0.10)
	var p1: float = float(wob_p[3]) if wob_p.size() >= 6 else rng.randf_range(0.0, TAU)
	var p2: float = float(wob_p[4]) if wob_p.size() >= 6 else rng.randf_range(0.0, TAU)
	var p3: float = float(wob_p[5]) if wob_p.size() >= 6 else rng.randf_range(0.0, TAU)
	var rim: float = float(RIM_PX)
	var w: int = img.get_width()
	var h: int = img.get_height()
	var x0: int = int(floor(cx - R - rim))
	var x1: int = int(ceil(cx + R + rim))
	var y0: int = int(floor(cy - R - rim))
	var y1: int = int(ceil(cy + R + rim))
	for py in range(maxi(0, y0), mini(h, y1)):
		for px in range(maxi(0, x0), mini(w, x1)):
			var dx: float = float(px) - cx
			var dy: float = float(py) - cy
			var dist: float = sqrt(dx * dx + dy * dy)
			var ang: float = atan2(dy, dx)
			var wob: float = 1.0 + a1 * sin(3.0 * ang + p1) + a2 * sin(5.0 * ang + p2) + a3 * sin(7.0 * ang + p3)
			var edge: float = R * wob
			if dist > edge + rim:
				continue
			if dist <= edge - rim:
				img.set_pixel(px, py, src.get_pixel(px % sw, py % sh))
			else:
				var t: float = clampf((edge + rim - dist) / (2.0 * rim), 0.0, 1.0) * 0.9
				var base: Color = src.get_pixel(px % sw, py % sh) if dist <= edge else img.get_pixel(px, py)
				img.set_pixel(px, py, base.lerp(FROTH, t))


# ===========================================================================
# LIQUID — animated bubbling-poison + flowing-river TILES (Run 94).
# ===========================================================================
# Replaces the old organic-blob baking. Every poison surface is now a full,
# grid-aligned 32px square tile that ANIMATES:
#   • bubbling poison = the 4 bubble tiles (POOL_CR) cycled as one animation,
#     laid in clusters over the floor around poison/slow traps + apron bog.
#   • poison river    = the 2 river tiles (RIVER_CR) cycled, one per V_WATER cell.
# No froth rims, no mid-tile blob edges — clean square tiles, LttP-style.
static func _liquid_frames() -> void:
	if _bubble_frames != null:
		return
	_bubble_frames = SpriteFrames.new()
	_bubble_frames.add_animation("bub")
	_bubble_frames.set_animation_loop("bub", true)
	_bubble_frames.set_animation_speed("bub", 2.5)   # slower = thicker/viscous fade, less strobe
	for cr in POOL_CR:
		_bubble_frames.add_frame("bub", ImageTexture.create_from_image(_crop(cr)))
	_river_frames = SpriteFrames.new()
	_river_frames.add_animation("riv")
	_river_frames.set_animation_loop("riv", true)
	_river_frames.set_animation_speed("riv", 2.5)
	for cr in RIVER_CR:
		_river_frames.add_frame("riv", ImageTexture.create_from_image(_crop(cr)))


static func make_liquid(half: Vector2, layout: RefCounted, seed_val: int,
		gate_positions: Array = []) -> Node2D:
	if _sheet() == null:
		return null
	_liquid_frames()
	var root := Node2D.new()
	root.name = "SwampLiquid"
	root.z_index = GROUND_Z + 1                # above the mud floor, below props + heroes
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 2654435761 + 919
	var gw: int = layout.gw
	var gh: int = layout.gh

	# 1. Poison RIVERS — one animated river tile on every V_WATER cell (but never
	#    in/right beside a gate, so an exit path never has poison in the way).
	for cj in range(gh):
		for ci in range(gw):
			if layout.val(ci, cj) != 2:
				continue
			var rwp: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
			if _poison_blocked_by_gate(rwp, gate_positions, half):
				continue
			_liquid_tile(root, _river_frames, "riv", rwp, ci, cj, rng, false)

	# 2. Poison POOLS — a cluster of bubbling tiles over the floor inside each
	#    poison/slow trap's pool circle (matches the TrapZone pool_radius).
	var traps: Array = layout.get("trap_spots")
	if traps != null:
		for t in traps:
			var ty: String = String((t as Dictionary).get("type", ""))
			if ty != "poison" and ty != "slow":
				continue
			var wp: Vector2 = (t as Dictionary).get("pos", Vector2.ZERO)
			var pr: float = float((t as Dictionary).get("pool_radius", 56.0))
			_fill_pool(root, layout, wp, pr, rng, gate_positions, half)

	# 3. APRON bog — scattered bubble clusters + a few short river streaks in the
	#    swamp-floor apron OUTSIDE the arena rect, so the surround reads as bog.
	_scatter_apron(root, layout, gw, gh, rng, gate_positions, half)
	return root


# Poison is suppressed both inside the gate hallway lane AND within a small
# radius of the gate mouth, so an exit path is never blocked by poison.
static func _poison_blocked_by_gate(p: Vector2, gates: Array, half: Vector2) -> bool:
	return _in_gate_lane(p, gates, half) or _near_any(p, gates, POISON_GATE_CLEAR)


# One animated liquid tile, cell-centred + scaled to a 32px world cell. Bubble
# tiles flip + desync per cell so a cluster reads organic; river tiles stay
# unflipped and in-sync so their streaks flow as one continuous current.
static func _liquid_tile(root: Node2D, frames: SpriteFrames, anim: String,
		world_pos: Vector2, ci: int, cj: int, rng: RandomNumberGenerator,
		allow_flip: bool) -> void:
	var a := AnimatedSprite2D.new()
	a.sprite_frames = frames
	a.animation = anim
	a.centered = true
	a.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	a.position = world_pos
	a.scale = Vector2(WORLD_CELL / float(CELL_PX), WORLD_CELL / float(CELL_PX))
	if allow_flip:
		var hsh: int = abs(hash(Vector2i(ci, cj)))
		a.flip_h = (hsh & 1) == 1
		a.flip_v = (hsh & 2) == 2
		a.frame = hsh % frames.get_frame_count(anim)
		a.speed_scale = rng.randf_range(0.85, 1.15)
	else:
		a.frame = 0
		a.speed_scale = 1.0
	a.play(anim)
	root.add_child(a)


# Fill the floor/bridge cells inside a trap's pool circle with bubbling tiles.
static func _fill_pool(root: Node2D, layout: RefCounted, center: Vector2,
		radius: float, rng: RandomNumberGenerator, gate_positions: Array,
		half: Vector2) -> void:
	var cc: Vector2i = layout.world_to_cell(center)
	var span: int = int(ceil(radius / WORLD_CELL)) + 1
	for dj in range(-span, span + 1):
		for di in range(-span, span + 1):
			var ci: int = cc.x + di
			var cj: int = cc.y + dj
			var v: int = layout.val(ci, cj)
			if v != 1 and v != 3:                  # floor / bridge only
				continue
			var wpos: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
			if wpos.distance_to(center) > radius + WORLD_CELL * 0.35:
				continue
			if _poison_blocked_by_gate(wpos, gate_positions, half):
				continue                           # keep the exit path poison-free
			_liquid_tile(root, _bubble_frames, "bub", wpos, ci, cj, rng, true)


# Apron liquid: scattered bubble clusters + a couple of short river streaks in
# the swamp-floor apron OUTSIDE the arena rect (never inside the playable arena,
# never in a gate's exit hallway).
static func _scatter_apron(root: Node2D, layout: RefCounted, gw: int, gh: int,
		rng: RandomNumberGenerator, gate_positions: Array, half: Vector2) -> void:
	var m: int = APRON_CELLS
	# Thick mire: a lot more bubbling poison across the whole apron band.
	var want: int = int(float(gw + gh) * 1.5)
	var made: int = 0
	var tries: int = 0
	while made < want and tries < want * 8:
		tries += 1
		var ci: int = rng.randi_range(-m, gw + m - 1)
		var cj: int = rng.randi_range(-m, gh + m - 1)
		if ci >= 0 and ci < gw and cj >= 0 and cj < gh:
			continue                               # inside the arena → skip
		if _poison_blocked_by_gate(layout.cell_to_world(Vector2i(ci, cj)), gate_positions, half):
			continue                               # keep the exit hallway poison-free
		if rng.randf() < 0.62:                      # bigger blobby cluster
			for off in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1),
					Vector2i(2, 0), Vector2i(0, 2), Vector2i(2, 1), Vector2i(1, 2)]:
				if rng.randf() < 0.72:
					var c: Vector2i = Vector2i(ci + off.x, cj + off.y)
					if c.x >= 0 and c.x < gw and c.y >= 0 and c.y < gh:
						continue                   # don't bleed a cluster into the arena
					var cwp: Vector2 = layout.cell_to_world(c)
					if _poison_blocked_by_gate(cwp, gate_positions, half):
						continue
					_liquid_tile(root, _bubble_frames, "bub", cwp, c.x, c.y, rng, true)
		else:
			_liquid_tile(root, _bubble_frames, "bub",
				layout.cell_to_world(Vector2i(ci, cj)), ci, cj, rng, true)
		made += 1
	# Several long liquid streaks snaking through the apron (river tiles).
	for _s in range(rng.randi_range(4, 7)):
		var horiz: bool = rng.randf() < 0.5
		var length: int = rng.randi_range(5, 11)
		var sci: int = rng.randi_range(-m, gw + m - 1)
		var scj: int = rng.randi_range(-m, gh + m - 1)
		for k in range(length):
			var ci2: int = sci + (k if horiz else 0)
			var cj2: int = scj + (0 if horiz else k)
			if ci2 >= 0 and ci2 < gw and cj2 >= 0 and cj2 < gh:
				continue
			var swp: Vector2 = layout.cell_to_world(Vector2i(ci2, cj2))
			if _poison_blocked_by_gate(swp, gate_positions, half):
				continue
			_liquid_tile(root, _river_frames, "riv", swp, ci2, cj2, rng, false)


# ===========================================================================
# PROPS — rock/log obstacles + chomper traps + accents + flat decor.
# ===========================================================================
static func make_props(half: Vector2, layout: RefCounted, seed_val: int,
		gate_positions: Array = []) -> Node2D:
	var root := Node2D.new()
	root.name = "SwampProps"
	root.z_index = PROP_Z
	root.y_sort_enabled = true
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 40503 + hash("swamp")
	var gw: int = layout.gw
	var gh: int = layout.gh
	var placed: Array = []                         # [{ c:Vector2, r:float }]
	var lim_x: float = half.x - EDGE_KEEPOUT
	var lim_y: float = half.y - EDGE_KEEPOUT

	# 0. Free-standing LOG barriers on open floor (own dashable_barrier collider).
	_place_log_barriers(root, placed, layout, gate_positions, rng, gw, gh, lim_x, lim_y)

	# Path-edge cells = blocked (void) cells touching the floor, inside the border.
	# Stored with cell coords so chompers can face the adjacent floor.
	var edge_cells: Array = []
	for cj in range(gh):
		for ci in range(gw):
			if layout.val(ci, cj) != 0 or not _touches_floor(layout, ci, cj):
				continue
			var wc: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
			if absf(wc.x) > lim_x or absf(wc.y) > lim_y:
				continue
			edge_cells.append({ "pos": wc, "cell": Vector2i(ci, cj) })
	_shuffle(edge_cells, rng)

	# 1. CHOMPERS first (sparingly) — they take a spot on the wall line; the rock
	#    fences below then avoid them, so a chomper "replaces" a rock/log there.
	_place_chompers(root, placed, layout, gate_positions, rng, edge_cells)

	# 2. Rock/log FENCES lining the player paths (occasional natural breaks).
	for e in edge_cells:
		var wc1: Vector2 = e["pos"]
		if _near_any(wc1, gate_positions, GATE_CLEAR):
			continue
		if rng.randf() > 0.95:
			continue
		_try_obstacle(root, placed, _pick(ROCK_NAMES + LOG_NAMES, rng), wc1,
			rng.randf_range(OBSTACLE_CELLS * 0.85, OBSTACLE_CELLS * 1.2), rng, false)

	# 3. A few obstacles about the open interior void.
	for cj in range(gh):
		for ci in range(gw):
			if layout.val(ci, cj) != 0 or _touches_floor(layout, ci, cj):
				continue
			if rng.randf() > 0.05:
				continue
			var wc2: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
			if absf(wc2.x) > lim_x or absf(wc2.y) > lim_y:
				continue
			if _near_any(wc2, gate_positions, GATE_CLEAR):
				continue
			_try_obstacle(root, placed, _pick(ROCK_NAMES, rng), wc2,
				rng.randf_range(OBSTACLE_CELLS * 0.7, OBSTACLE_CELLS), rng, false)

	# 4. Sparse tall accents (spike rocks + the odd small tree) along path edges.
	for e3 in edge_cells:
		if rng.randf() > 0.08:
			continue
		var wc3: Vector2 = e3["pos"]
		if _near_any(wc3, gate_positions, GATE_CLEAR):
			continue
		var nm: String = _pick(SPIKE_NAMES, rng) if rng.randf() < 0.7 else _pick(TREE_SMALL, rng)
		_try_obstacle(root, placed, nm, wc3,
			rng.randf_range(ACCENT_CELLS * 0.85, ACCENT_CELLS * 1.15), rng, true)

	# 5. COVERAGE PASS — guarantee every collidable wall cell bordering floor wears
	#    a visible rock, so an open-looking gap is never an invisible wall.
	for cj2 in range(gh):
		for ci2 in range(gw):
			if layout.val(ci2, cj2) != 0 or not _touches_floor(layout, ci2, cj2):
				continue
			var wcc: Vector2 = layout.cell_to_world(Vector2i(ci2, cj2))
			if absf(wcc.x) > lim_x or absf(wcc.y) > lim_y:
				continue
			var covered: bool = false
			for p in placed:
				if wcc.distance_to(p["c"]) <= float(p["r"]) + 10.0:
					covered = true
					break
			if not covered:
				_fit_rock(root, placed, _pick(ROCK_NAMES + RUBBLE_NAMES, rng), wcc, rng)

	# 6. Flat mushroom / flower / sprout decor scattered on open floor (run-over).
	var pool: Array = _decor_weighted()
	if not pool.is_empty():
		var dcount: int = int(float(gw * gh) / 24.0)
		for _i in range(dcount):
			var ci3: int = rng.randi_range(1, gw - 2)
			var cj3: int = rng.randi_range(1, gh - 2)
			if layout.val(ci3, cj3) != 1:
				continue
			var dwc: Vector2 = layout.cell_to_world(Vector2i(ci3, cj3))
			if _near_any(dwc, gate_positions, GATE_CLEAR * 0.55):
				continue
			var pick: Array = pool[rng.randi() % pool.size()]
			_add_decor(root, String(pick[0]), dwc, float(pick[1]), rng)
	return root


static func _decor_weighted() -> Array:
	var out: Array = []
	for e in DECOR_TABLE:
		for _w in range(int(e[2])):
			out.append([e[0], float(e[1])])
	return out


# Free-standing log barriers on open floor — each with its own dashable_barrier
# collider (ninja DASH phases them; walking is blocked). Placed sparingly.
static func _place_log_barriers(root: Node2D, placed: Array, layout: RefCounted,
		gate_positions: Array, rng: RandomNumberGenerator, gw: int, gh: int,
		lim_x: float, lim_y: float) -> void:
	var cands: Array = []
	for cj in range(gh):
		for ci in range(gw):
			if layout.val(ci, cj) != 1:
				continue
			var wc: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
			if absf(wc.x) > lim_x - 24.0 or absf(wc.y) > lim_y - 24.0:
				continue
			if wc.length() < 132.0:                       # keep the spawn chamber clear
				continue
			if _near_any(wc, gate_positions, GATE_CLEAR + 40.0):
				continue
			cands.append(wc)
	if cands.is_empty():
		return
	_shuffle(cands, rng)
	var idx: int = 0
	var n_logs: int = rng.randi_range(2, 4)
	var done: int = 0
	while idx < cands.size() and done < n_logs:
		var lname: String = _pick(LOG_NAMES, rng)
		if _try_barrier(root, placed, lname, cands[idx], rng.randf_range(1.25, 1.6), rng, 0.80, 0.58):
			done += 1
		idx += 1


# Sparse carnivorous CHOMPIN plants — obstacle+trap hybrid sitting on the wall
# line. The plant sprite stands as an overhead barrier; a TrapZone "chomp" area
# pokes into the adjacent floor so a hero who touches the mouth takes a bite.
static func _place_chompers(root: Node2D, placed: Array, layout: RefCounted,
		gate_positions: Array, rng: RandomNumberGenerator, edge_cells: Array) -> void:
	var want: int = rng.randi_range(1, 3)
	var done: int = 0
	for e in edge_cells:
		if done >= want:
			break
		var wc: Vector2 = e["pos"]
		if _near_any(wc, gate_positions, GATE_CLEAR + 20.0):
			continue
		var fdir: Vector2 = _floor_dir(layout, e["cell"])
		if fdir == Vector2.ZERO:
			continue
		var nm: String = _pick(CHOMP_NAMES, rng)
		var tex: ImageTexture = _prop_tex(nm)
		if tex == null:
			continue
		var hcells: float = rng.randf_range(1.7, 2.1)
		var draw_w: float = float(tex.get_width()) * (WORLD_CELL * hcells / float(tex.get_height()))
		# Run 96: bigger reserved circle so nothing (esp. wide logs) lands on the plant.
		var r: float = draw_w * 0.50
		var clash: bool = false
		for p in placed:
			if wc.distance_to(p["c"]) < r + p["r"]:
				clash = true
				break
		if clash:
			continue
		# Plant body — overhead barrier (hero passes behind it on the wall).
		_add_prop_tex(root, tex, wc, hcells, rng, int(WORLD_CELL * 0.10), true, true)
		# Bite zone — a small hazard poking into the floor in front of the mouth.
		var z = TRAP.new()
		z.trap_type = "chomp"
		z.trap_name = "Chompin Plant"
		z.draw_sprite = false
		z.radius = 26.0
		z.position = wc + fdir * 22.0 + Vector2(0.0, -WORLD_CELL * hcells * 0.32)
		root.add_child(z)
		placed.append({ "c": wc, "r": r })
		done += 1


# Average direction from a wall cell toward its adjacent walkable floor cells.
static func _floor_dir(layout: RefCounted, cell: Vector2i) -> Vector2:
	var acc := Vector2.ZERO
	for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var v: int = layout.val(cell.x + off.x, cell.y + off.y)
		if v == 1 or v == 3:
			acc += Vector2(off)
	return acc.normalized() if acc != Vector2.ZERO else Vector2.ZERO


# ===========================================================================
# WALLS — swamp-tree arena frame + densely filled outer forest + inner void band.
# ===========================================================================
# Everything outside the walkable floor is packed with trees so the surround
# reads as deep swamp wood, EXCEPT each gate's exit hallway (a clear corridor the
# width of the gate, running straight out to the next arena). The inner void band
# just inside the border is filled too (needs the layout) so the non-walkable
# strip beside a gate is treed rather than left as a bald unpassable patch.
static func make_walls(half: Vector2, exit_dir: Vector2, gate_positions: Array,
		seed_val: int, layout: RefCounted = null) -> Node2D:
	var root := Node2D.new()
	root.name = "SwampWalls"
	root.z_index = PROP_Z
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 2246822519 + 67

	# 1. OUTER FOREST — a dense jittered GRID over the whole outside band (no bald
	#    gaps), drawn behind the frame. Skips only the gate exit hallway.
	var x0: float = -(half.x + FOREST_DEPTH)
	var x1: float =  (half.x + FOREST_DEPTH)
	var y0: float = -(half.y + FOREST_DEPTH)
	var y1: float =  (half.y + FOREST_DEPTH)
	var gx: float = x0
	while gx <= x1:
		var gy: float = y0
		while gy <= y1:
			# Only the ring band outside the floor rect (interior is handled below).
			if absf(gx) >= half.x or absf(gy) >= half.y:
				var jit := Vector2(rng.randf_range(-FOREST_STEP * 0.45, FOREST_STEP * 0.45),
					rng.randf_range(-FOREST_STEP * 0.45, FOREST_STEP * 0.45))
				var pos: Vector2 = Vector2(gx, gy) + jit
				if (absf(pos.x) >= half.x or absf(pos.y) >= half.y) \
						and not _in_gate_lane(pos, gate_positions, half):
					_forest_tree(root, pos, rng, false)
			gy += FOREST_STEP
		gx += FOREST_STEP

	# 2. INNER VOID BAND — pack the non-walkable strip just inside the border with
	#    trees so the wall band (and the patch beside a gate) is a treeline, not a
	#    bald unpassable void. Floor/bridge cells (the path) stay clear.
	#    SKIP void cells that touch the floor — those are where make_props places
	#    rocks/obstacles, and double-placing a tree there causes tree-on-rock overlap.
	if layout != null:
		var gw: int = layout.gw
		var gh: int = layout.gh
		var b: int = BORDER_BAND_CELLS
		for cj in range(gh):
			for ci in range(gw):
				if ci >= b and ci < gw - b and cj >= b and cj < gh - b:
					continue                             # deep interior → make_props' job
				var v: int = layout.val(ci, cj)
				if v == 1 or v == 3 or v == 2:           # keep floor/bridge + visible rivers clear
					continue
				if _touches_floor(layout, ci, cj):
					continue                             # rock/obstacle zone — make_props owns these
				var wc: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
				if _in_gate_lane(wc, gate_positions, half):
					continue                             # keep the hallway mouth open
				_forest_tree(root, wc + Vector2(rng.randf_range(-6.0, 6.0), 0.0), rng, true)

	# 3. FRAME — a continuous treeline hugging each border, running all the way to
	#    the border line; only the gate hallway is left clear.
	var fx: float = half.x + FRAME_MARGIN
	var fy: float = half.y + FRAME_MARGIN
	# Top + bottom runs (feet on the border line, canopy overhead → hero behind).
	var x: float = -half.x
	while x <= half.x:
		_frame_tree(root, Vector2(x, -fy), gate_positions, half, rng)
		_frame_tree(root, Vector2(x,  fy), gate_positions, half, rng)
		x += FRAME_STEP
	# Left + right runs.
	var y: float = -half.y
	while y <= half.y:
		_frame_tree(root, Vector2(-fx, y), gate_positions, half, rng)
		_frame_tree(root, Vector2( fx, y), gate_positions, half, rng)
		y += FRAME_STEP
	return root


# A single forest-fill tree (size-varied, no shadow → cheap; many are placed).
# overhead=true makes a hero passing it slip BEHIND the canopy.
static func _forest_tree(root: Node2D, pos: Vector2, rng: RandomNumberGenerator,
		overhead: bool) -> void:
	var roll: float = rng.randf()
	var nm: String
	var hc: float
	if roll < 0.55:
		nm = _pick(TREE_BIG, rng); hc = rng.randf_range(3.0, 3.8)
	elif roll < 0.85:
		nm = _pick(TREE_MID, rng); hc = rng.randf_range(2.4, 3.1)
	else:
		nm = _pick(TREE_SMALL, rng); hc = rng.randf_range(1.7, 2.4)
	_place_tree(root, nm, pos, hc, rng, overhead, false)


# One frame tree at a border position unless it sits in the gate doorway lane.
static func _frame_tree(root: Node2D, pos: Vector2, gate_positions: Array,
		half: Vector2, rng: RandomNumberGenerator) -> void:
	if _in_gate_lane(pos, gate_positions, half):
		return
	var jitter := Vector2(rng.randf_range(-8.0, 8.0), rng.randf_range(-6.0, 6.0))
	var nm: String = _pick(TREE_BIG, rng) if rng.randf() < 0.75 else _pick(TREE_MID, rng)
	_place_tree(root, nm, pos + jitter, rng.randf_range(FRAME_H_MIN, FRAME_H_MAX), rng, true)


# True when pos lies in a gate's exit corridor: a narrow doorway at the border
# that flares wider as it runs OUTWARD through the forest, carving a clean path /
# clearing out through the trees. Replaces the old wide circular gate keepout.
static func _in_gate_lane(pos: Vector2, gates: Array, half: Vector2) -> bool:
	for g in gates:
		var gv: Vector2 = g as Vector2
		var outw: Vector2 = _gate_outward(gv, half)
		if outw == Vector2.ZERO:
			continue
		var rel: Vector2 = pos - gv
		var along: float = rel.dot(outw)               # + = outward past the gate
		if along < -GATE_LANE_BACK:
			continue                                   # well inside the arena → not the lane
		var perp: float = absf(rel.x * outw.y - rel.y * outw.x)
		var w: float = GATE_LANE_HALF + maxf(0.0, along) * GATE_LANE_FLARE
		if perp <= w:
			return true
	return false


# Cardinal outward normal for a gate, snapped to whichever border it sits on.
static func _gate_outward(g: Vector2, half: Vector2) -> Vector2:
	var dx: float = half.x - absf(g.x)                 # distance to the L/R border
	var dy: float = half.y - absf(g.y)                 # distance to the T/B border
	if dx <= dy:
		return Vector2(signf(g.x), 0.0)
	return Vector2(0.0, signf(g.y))


# ---------------------------------------------------------------------------
# Placement helpers.
# ---------------------------------------------------------------------------
static func _pick(arr: Array, rng: RandomNumberGenerator) -> String:
	return arr[rng.randi() % arr.size()]


static func _shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


static func _near_any(p: Vector2, pts: Array, r: float) -> bool:
	for q in pts:
		if p.distance_to(q as Vector2) < r:
			return true
	return false


static func _touches_floor(layout: RefCounted, ci: int, cj: int) -> bool:
	for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
			Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]:
		var v: int = layout.val(ci + off.x, cj + off.y)
		if v == 1 or v == 3:
			return true
	return false


static func _ring_point(half: Vector2, b0: float, b1: float, rng: RandomNumberGenerator) -> Vector2:
	var side: int = rng.randi() % 4
	var band: float = rng.randf_range(b0, b1)
	match side:
		0:  return Vector2(rng.randf_range(-half.x - b1, half.x + b1), -half.y - band)
		1:  return Vector2(rng.randf_range(-half.x - b1, half.x + b1),  half.y + band)
		2:  return Vector2(-half.x - band, rng.randf_range(-half.y - b1, half.y + b1))
		_:  return Vector2( half.x + band, rng.randf_range(-half.y - b1, half.y + b1))


# Place an obstacle (rock/log/spike/small-tree) at base unless its foot-circle
# overlaps an existing prop. Obstacles ride overhead so a hero passes behind.
static func _try_obstacle(root: Node2D, placed: Array, name: String, base: Vector2,
		height_cells: float, rng: RandomNumberGenerator, tall: bool) -> bool:
	var tex: ImageTexture = _prop_tex(name)
	if tex == null:
		return false
	# Run 96: wider keep-apart circles so neighbouring props sit close but never
	# fully cover one another (wide logs / tall accents extend well past the old foot).
	var foot_frac: float = 0.30 if tall else 0.40
	var draw_w: float = float(tex.get_width()) * (WORLD_CELL * height_cells / float(tex.get_height()))
	var r: float = draw_w * foot_frac
	for p in placed:
		if base.distance_to(p["c"]) < r + p["r"]:
			return false
	_add_prop_tex(root, tex, base, height_cells, rng, int(WORLD_CELL * 0.10), true, not tall)
	placed.append({ "c": base, "r": r })
	return true


# Coverage-pass rock: always places SOMETHING on a bare collidable cell, shrunk
# to fit the free gap so it abuts neighbours rather than stacking.
static func _fit_rock(root: Node2D, placed: Array, name: String, base: Vector2,
		rng: RandomNumberGenerator) -> bool:
	var tex: ImageTexture = _prop_tex(name)
	if tex == null:
		return false
	var foot_frac: float = 0.33
	var pref_r: float = foot_frac * WORLD_CELL * 1.2
	var gap: float = pref_r
	for p in placed:
		gap = minf(gap, base.distance_to(p["c"]) - float(p["r"]))
	var want_r: float = clampf(gap, foot_frac * WORLD_CELL * 0.5, pref_r)
	var aspect: float = float(tex.get_width()) / float(tex.get_height())
	var h: float = want_r / (foot_frac * WORLD_CELL * maxf(0.4, aspect))
	h = clampf(h, 0.45, 1.3)
	_add_prop_tex(root, tex, base, h, rng, int(WORLD_CELL * 0.10), true, false)
	placed.append({ "c": base, "r": want_r })
	return true


# Floor barrier (log): draw flush + attach a dashable_barrier rectangle collider.
static func _try_barrier(root: Node2D, placed: Array, name: String, base: Vector2,
		height_cells: float, rng: RandomNumberGenerator, foot_w_frac: float,
		foot_h_frac: float) -> bool:
	var tex: ImageTexture = _prop_tex(name)
	if tex == null:
		return false
	var draw_h: float = WORLD_CELL * height_cells
	var draw_w: float = float(tex.get_width()) * (draw_h / float(tex.get_height()))
	# Run 96: wider keep-apart so a long log never lies across an adjacent prop.
	var r: float = draw_w * 0.55
	for p in placed:
		if base.distance_to(p["c"]) < r + p["r"]:
			return false
	var sink: int = int(WORLD_CELL * 0.08)
	_add_prop_tex(root, tex, base, height_cells, rng, sink, true, true)
	var feet_y: float = base.y + float(sink)
	var center_y: float = feet_y - draw_h * 0.5
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.add_to_group("dashable_barrier")
	var cs := CollisionShape2D.new()
	var sh := RectangleShape2D.new()
	sh.size = Vector2(maxf(8.0, draw_w * foot_w_frac), maxf(8.0, draw_h * foot_h_frac))
	cs.shape = sh
	cs.position = Vector2(base.x, center_y)
	body.add_child(cs)
	root.add_child(body)
	placed.append({ "c": base, "r": r })
	return true


static func _place_tree(root: Node2D, name: String, base: Vector2, height_cells: float,
		rng: RandomNumberGenerator, overhead: bool, with_shadow: bool = true) -> void:
	var tex: ImageTexture = _prop_tex(name)
	if tex == null:
		return
	_add_prop_tex(root, tex, base, height_cells, rng, int(WORLD_CELL * 0.06), with_shadow, overhead)


# Flat, run-over decor (no collision, no overhead) — sits above ground, below heroes.
static func _add_decor(root: Node2D, name: String, base: Vector2, height_cells: float,
		rng: RandomNumberGenerator) -> void:
	var tex: ImageTexture = _prop_tex(name)
	if tex == null:
		return
	var sc: float = (WORLD_CELL * height_cells) / float(tex.get_height())
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	spr.scale = Vector2(sc, sc)
	var draw_h: float = float(tex.get_height()) * sc
	spr.position = base + Vector2(float(rng.randi_range(-9, 9)), 0.0) - Vector2(0.0, draw_h * 0.5)
	root.add_child(spr)


# Feet-anchored prop + soft contact shadow. Barriers/accents ride overhead so a
# hero colliding with one passes BEHIND it (global RunState.BARRIER_OVERHANG_Z).
static func _add_prop_tex(root: Node2D, tex: ImageTexture, base: Vector2, height_cells: float,
		rng: RandomNumberGenerator, sink: int, with_shadow: bool, overhead: bool) -> void:
	var th: float = float(tex.get_height())
	var tw: float = float(tex.get_width())
	var sc: float = (WORLD_CELL * height_cells) / th
	var draw_h: float = th * sc
	var draw_w: float = tw * sc
	var feet: Vector2 = base + Vector2(0.0, float(sink))
	# Interior props in a y_sort_enabled container get foot-anchored wrapping so
	# heroes appear in front/behind based on relative Y. Border/wall props (root
	# without y_sort) keep the old fixed-z behaviour (always on top of heroes).
	var ysort: bool = overhead and root.y_sort_enabled
	if ysort:
		var wrap := Node2D.new()
		wrap.position = feet
		wrap.z_as_relative = false
		wrap.z_index = 0
		if with_shadow:
			var sh := Sprite2D.new()
			var stex: ImageTexture = _shadow_texture()
			sh.texture = stex
			sh.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
			var sh_w: float = draw_w * 0.6
			var sh_h: float = maxf(6.0, sh_w * 0.4)
			sh.scale = Vector2(sh_w / float(stex.get_width()), sh_h / float(stex.get_height()))
			wrap.add_child(sh)
		var spr := Sprite2D.new()
		spr.texture = tex
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		spr.scale = Vector2(sc, sc)
		spr.position = Vector2(0.0, -draw_h * 0.5)
		wrap.add_child(spr)
		root.add_child(wrap)
	else:
		if with_shadow:
			var sh := Sprite2D.new()
			var stex: ImageTexture = _shadow_texture()
			sh.texture = stex
			sh.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
			var sh_w: float = draw_w * 0.6
			var sh_h: float = maxf(6.0, sh_w * 0.4)
			sh.scale = Vector2(sh_w / float(stex.get_width()), sh_h / float(stex.get_height()))
			sh.position = feet
			root.add_child(sh)
		var spr := Sprite2D.new()
		spr.texture = tex
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		spr.scale = Vector2(sc, sc)
		spr.position = feet - Vector2(0.0, draw_h * 0.5)
		if overhead:
			spr.z_as_relative = false
			spr.z_index = RunState.BARRIER_OVERHANG_Z
		root.add_child(spr)


static func _shadow_texture() -> ImageTexture:
	if _shadow_tex != null:
		return _shadow_tex
	var w: int = 128
	var h: int = 64
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in range(h):
		for x in range(w):
			var nx: float = (float(x) - float(w) * 0.5) / (float(w) * 0.5)
			var ny: float = (float(y) - float(h) * 0.5) / (float(h) * 0.5)
			var d: float = nx * nx + ny * ny
			var a: float = clampf(1.0 - d, 0.0, 1.0)
			a = pow(a, 1.3) * 0.42
			img.set_pixel(x, y, Color(0.08, 0.086, 0.11, a))
	_shadow_tex = ImageTexture.create_from_image(img)
	return _shadow_tex
