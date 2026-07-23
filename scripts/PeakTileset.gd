extends RefCounted

# ============================================================
# PeakTileset.gd — Frostpeak self-contained tileset
# ============================================================
# Dedicated to the PEAKS biome only. Self-contained like CavernTileset —
# owns its own prop pools, make_props, and make_walls end-to-end (no longer
# routes through BiomeProps). Source art in Assets/Tilesets/Mountain_props/
# (individually named PNGs sliced from Bruno's mountain sheets).
#
# Ground is baked from Frost Peak Tileset.png (Run 92 — unchanged).
#
# What the ground baker produces for the PEAKS biome:
#   * a baked SNOWPACK floor — clean snow tiles (sheet cols 0-3), multiplied
#     into orientation variants so it never reads as a repeating grid.
#   * SNOWY TRAILS — the hand-authored packed-snow path tile (sheet col 1)
#     painted as connected orthogonal trodden routes that flow from the hero
#     ENTRY to the central CHAMBER and out to every GATE. Vertical runs use
#     the vertical trail tile; horizontal runs use it rotated 90°, so the
#     grooves always run ALONG the path — never random squares in the snow.
#   * FROZEN ICE on V_WATER cells (rivers / lakes / puddles) — the glacial
#     blue ice tiles (cols 4-5), ringed with a bright frosty rim at every
#     bank, with occasional shatter-crack detail inside larger sheets.
#
# Frozen ice is WALKABLE but SLIPPERY (see DreamLayout.ice_biome +
# IceField.gd + the hero ice-glide in Player/BeaAI). Unlike real water it can
# be crossed; the slip is the biome's "large" ice hazard (replaces the old
# Deep-Snow trap placeholder).
#
# Grid mapped off the sheet: terrain-variation block origin (844,46),
# pitch 141.1 px, 12px inset per crop so the sheet's white separator slivers
# never bleed into a baked tile (the "cut the white lines" pass).
#
# Import-agnostic load (ResourceLoader first, raw Image.load fallback) so it
# works the first run before Godot's import pass, exactly like BeachTileset.
# ============================================================

const SHEET_PATH: String = "res://Assets/Tilesets/Frost Peak Tileset.png"
const PROP_DIR: String = "res://Assets/Tilesets/Mountain_props/"

# --- Prop name pools (sliced PNGs in Mountain_props/) -------------------------
const TREE_NAMES: Array = ["mtree_1", "mtree_2", "mtree_3", "mtree_4",
	"mtree_5", "mtree_6", "mtree_7"]                              # snowy pines/oaks/dead trees
const TREE_BIG: Array = ["mtree_2", "mtree_4", "mtree_5", "mtree_6"]  # medium-big trees (frame/wall)
const TREE_SMALL: Array = ["mtree_1", "mtree_3", "mtree_7"]           # small/thin trees (fill)
const ROCK_NAMES: Array = ["mrock_1", "mrock_2", "mrock_3", "mrock_4"]  # rock barriers
# Stalagmites (point UP) — static obstacle barriers.
const SPIKE_NAMES: Array = ["mspike_2", "mspike_4", "mspike_6"]
# Stalactites (point DOWN) — falling-trap sprites, become obstacles after landing.
const STALACTITE_NAMES: Array = ["mspike_1", "mspike_3", "mspike_5"]
# Icicle accents: stalagmites (up) = obstacle decor, stalactites (down) = falling traps.
const ICICLE_NAMES: Array = ["micicle_2", "micicle_4"]             # stalagmite accents (obstacle)
const ICICLE_STALACTITE_NAMES: Array = ["micicle_1", "micicle_3",
	"micicle_5", "micicle_6"]                                      # stalactite accents (falling trap)
const CAVE_NAME: String = "mcave"                                  # cave mouth (gate marker)
# Small barriers (crystals/sacks/crates/logs/barrels on the floor).
const SMALL_BARRIER_NAMES: Array = ["mx_crystal", "mx_sack", "mx_crate",
	"mx_log", "mx_barrel"]
# Flat run-over decor — [name, height(world cells), weight].
const DECOR_TABLE: Array = [
	["mx_snowball", 0.56, 3], ["mx_snowpile", 0.62, 3],
	["mx_campfire", 0.58, 1], ["mx_shovel", 0.68, 2],
	["mx_pickaxe", 0.66, 2],
]

# --- Placement tuning (props) ------------------------------------------------
const EDGE_KEEPOUT: float = 56.0
const GATE_CLEAR: float = 104.0
const OBSTACLE_CELLS: float = 1.5      # tree/rock barrier height (world cells, upper bound)
const PROP_Z: int = -12
# Run 110: props NEVER drawn bigger than native. Flat source-px → world-px scale,
# capped at native resolution per prop. Lower = smaller/crisper.
const PROP_PX_SCALE: float = 0.46
const PROP_GAP: float = 14.0
const PROP_CLUSTER_GAP: float = 6.0

# --- Placement tuning (walls / border) ----------------------------------------
const FOREST_DEPTH: float = 300.0      # how far the outer forest band extends
const FOREST_STEP: float = 52.0        # grid step for outer forest density
const FRAME_STEP: float = 48.0         # tree spacing along the border frame
const FRAME_MARGIN: float = 14.0       # outward offset of frame tree feet from the border
const FRAME_H_MIN: float = 3.2         # frame tree min height (world cells)
const FRAME_H_MAX: float = 4.2         # frame tree max height (world cells)
const BORDER_BAND_CELLS: int = 3       # inner void band packed with trees
const GATE_LANE_HALF: float = 42.0     # half-width of the exit lane cleared through trees
const GATE_LANE_BACK: float = 32.0     # how far inside the arena the lane extends
const GATE_LANE_FLARE: float = 0.12    # lane widens outward (per px of outward distance)
const CAVE_CHANCE: float = 0.35        # probability a gate shows the cave mouth instead of spike pillars
const CAVE_HEIGHT_CELLS: float = 4.0   # how tall the cave mouth draws (exempt from native cap)
const CAVE_CLEAR_RADIUS: float = 96.0  # wall-rock exclusion radius around a cave gate (≈half cave width)
const PILLAR_GAP: float = 38.0         # spike pillars flanking distance from gate centre
const PILLAR_H_CELLS: float = 2.8      # spike pillar height (world cells)
const ICICLE_CHANCE: float = 0.12      # sparse icicle accents around the border

# --- Ground tile grid (terrain-variation block) ----------------------------
const GX0: float = 844.0
const GY0: float = 46.0
const PITCH: float = 141.1
const INSET: int = 12               # crop inside the tile → drops white seams
const CELL_PX: int = 64             # baked px per 32px world cell (2× supersample)
const WORLD_CELL: float = 32.0
const RIM_PX: int = 9               # frosty-rim width at ice borders (baked px)
const GROUND_Z: int = -34
const GROUND_PAD: int = 6             # floor tiles extend this many cells beyond the arena into wall area

const V_WATER: int = 2
const V_FLOOR: int = 1

# (col,row) of the tiles we sample.
const SNOW_CR: Array = [[0, 0], [2, 0], [2, 2], [3, 0], [0, 2], [3, 2]]   # clean snow
# Lake/river FILL — DARK + MEDIUM blue, streaky tiles ONLY. The pale ice (col
# 4-5 row 0) reads like snow, and the circular-bubble tiles look odd tiled, so
# both are excluded here.
const ICE_CR:  Array = [[5, 1], [4, 1], [4, 2]]
# The circular tile is used ONLY as a standalone single-cell ICE PUDDLE (an
# isolated frozen pool), never inside a larger sheet.
const PUDDLE_CR: Array = [7, 0]
const CRACK_CR: Array = [[4, 3], [5, 3]]                                  # shatter-crack accent
const PATH_CR: Array = [1, 2]       # vertical packed-snow trail (rotated for horizontal)
const CORNER_CR: Array = [1, 1]     # packed-snow trail BEND (base connects N+W; flipped for the rest)

# Bright frosty rim where ice meets snow.
const FROST: Color = Color(0.94, 0.975, 1.0)

static var _sheet_cache: Image = null
static var _sheet_tried: bool = false
static var _snow_cache: Array = []
static var _ice_cache: Array = []
static var _puddle_cache: Array = []
static var _crack_cache: Array = []
static var _path_v: Image = null
static var _path_h: Image = null
static var _corner: Dictionary = {}     # "NW"/"NE"/"SW"/"SE" → Image
static var _prop_cache: Dictionary = {}
static var _shadow_tex: ImageTexture = null

# Cave ground records which FLOOR cells it rendered as ice (vs rocky ground).
# DreamRoom reads this to build IceField from only the ice cells, so rocky
# patches stop the player's slide.  Reset each time make_ground_cave runs.
static var _cave_ice_cells: Dictionary = {}   # Vector2i → true


# ---------------------------------------------------------------------------
# Sheet loading (import-agnostic).
# ---------------------------------------------------------------------------
static func _load_png(path: String) -> Image:
	var out: Image = null
	if ResourceLoader.exists(path):
		var res: Resource = ResourceLoader.load(path)
		if res is Texture2D:
			out = (res as Texture2D).get_image()
	if out == null:
		var img := Image.new()
		if img.load(ProjectSettings.globalize_path(path)) == OK:
			out = img
	if out != null and out.get_format() != Image.FORMAT_RGBA8:
		out.convert(Image.FORMAT_RGBA8)
	if out == null:
		push_warning("[PeakTileset] Could not load %s." % path)
	return out


static func _prop_tex(name: String) -> ImageTexture:
	if _prop_cache.has(name):
		return _prop_cache[name]
	var img: Image = _load_png(PROP_DIR + name + ".png")
	var tex: ImageTexture = null
	if img != null:
		tex = ImageTexture.create_from_image(img)
	_prop_cache[name] = tex
	return tex


static func _sheet() -> Image:
	if not _sheet_tried:
		_sheet_tried = true
		_sheet_cache = _load_png(SHEET_PATH)
	return _sheet_cache


# ---------------------------------------------------------------------------
# Tile crop + variant builders.
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
	_strip_white(sub)
	return sub


# Replace near-white separator pixels with their nearest non-white neighbour.
static func _strip_white(img: Image) -> void:
	var w: int = img.get_width()
	var h: int = img.get_height()
	for y in range(h):
		for x in range(w):
			var c: Color = img.get_pixel(x, y)
			var mx: float = maxf(c.r, maxf(c.g, c.b))
			var mn: float = minf(c.r, minf(c.g, c.b))
			if mn > 0.83 and (mx - mn) < 0.08:
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
			if not (mn > 0.83 and (mx - mn) < 0.08):
				return c
	return Color(0.80, 0.88, 0.96)   # fallback frosty blue


# k=0 identity, 1 flipX, 2 flipY, 3 flipX+Y.
static func _orient(src: Image, k: int) -> Image:
	var out: Image = src.duplicate()
	if k == 1 or k == 3:
		out.flip_x()
	if k == 2 or k == 3:
		out.flip_y()
	return out


# Rotate 90° clockwise (vertical trail → horizontal trail).
static func _rot90(src: Image) -> Image:
	var w: int = src.get_width()
	var h: int = src.get_height()
	var out := Image.create(h, w, false, Image.FORMAT_RGBA8)
	for y in range(h):
		for x in range(w):
			out.set_pixel(h - 1 - y, x, src.get_pixel(x, y))
	return out


static func _lighten_img(src: Image, f: float) -> Image:
	var w: int = src.get_width()
	var h: int = src.get_height()
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in range(h):
		for x in range(w):
			out.set_pixel(x, y, src.get_pixel(x, y).lightened(f))
	return out


static func _snow_variants() -> Array:
	if not _snow_cache.is_empty():
		return _snow_cache
	var out: Array = []
	for cr in SNOW_CR:
		var base: Image = _crop(cr)
		for k in range(4):
			out.append(_orient(base, k))
	_snow_cache = out
	return out


static func _ice_variants() -> Array:
	if not _ice_cache.is_empty():
		return _ice_cache
	var out: Array = []
	for cr in ICE_CR:
		var base: Image = _crop(cr)
		for k in range(4):
			out.append(_orient(base, k))
	_ice_cache = out
	return out


static func _puddle_variants() -> Array:
	if not _puddle_cache.is_empty():
		return _puddle_cache
	var base: Image = _crop(PUDDLE_CR)
	for k in range(4):
		_puddle_cache.append(_orient(base, k))
	return _puddle_cache


static func _crack_variants() -> Array:
	if not _crack_cache.is_empty():
		return _crack_cache
	for cr in CRACK_CR:
		_crack_cache.append(_crop(cr))
	return _crack_cache


static func _build_path_tiles() -> void:
	if _path_v != null:
		return
	# Lighten slightly toward white so the trail reads as PACKED SNOW, not ice.
	_path_v = _lighten_img(_crop(PATH_CR), 0.12)
	_path_h = _rot90(_path_v)
	# Corner BEND. Base (CORNER_CR) connects the N and W edges; the blue curve
	# decoration sits on the inner side of that bend. We flip-swap so the curve
	# always faces the OUTER edge of each turn (diagonal opposite assignment).
	var nw: Image = _lighten_img(_crop(CORNER_CR), 0.12)
	_corner = {
		"NW": _orient(nw, 3),   # flip X+Y → curve on outer (SE) edge
		"NE": _orient(nw, 2),   # flip Y   → curve on outer (SW) edge
		"SW": _orient(nw, 1),   # flip X   → curve on outer (NE) edge
		"SE": nw,               # base     → curve on outer (NW) edge
	}


static func _hpick(arr: Array, ci: int, cj: int, salt: int) -> Image:
	var hh: int = abs(hash(Vector2i(ci * 73856093 + salt, cj * 19349663 + salt)))
	return arr[hh % arr.size()]


# ---------------------------------------------------------------------------
# Public API (matches what DreamTerrain calls).
# ---------------------------------------------------------------------------
static func available() -> bool:
	return _prop_tex("mtree_1") != null or _prop_tex("mrock_1") != null


static func ground_available() -> bool:
	return _sheet() != null


static func walls_available() -> bool:
	return _prop_tex("mtree_1") != null or _prop_tex("mspike_1") != null


# ===========================================================================
# PROPS — self-contained placement (trees, rocks, spikes, decor).
# ===========================================================================
static func make_props(half: Vector2, layout: RefCounted, seed_val: int,
		gate_positions: Array = []) -> Node2D:
	var root := Node2D.new()
	root.name = "PeakProps"
	root.z_index = PROP_Z
	root.y_sort_enabled = true
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 40503 + hash("peaks")
	var gw: int = layout.gw
	var gh: int = layout.gh
	var placed: Array = []                         # [{ c:Vector2, r:float }]
	var lim_x: float = half.x - EDGE_KEEPOUT
	var lim_y: float = half.y - EDGE_KEEPOUT

	# Path-edge cells = blocked (void) cells touching the floor, inside the border.
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

	# 1. TREE + ROCK FENCES lining the player paths (trees dominant, rocks fill gaps).
	for e in edge_cells:
		var wc1: Vector2 = e["pos"]
		if _near_any(wc1, gate_positions, GATE_CLEAR):
			continue
		if rng.randf() > 0.90:
			continue
		var nm: String
		if rng.randf() < 0.70:
			nm = _pick(TREE_NAMES, rng)
		elif rng.randf() < 0.65:
			nm = _pick(ROCK_NAMES, rng)
		else:
			nm = _pick(SPIKE_NAMES, rng)
		_try_obstacle(root, placed, nm, wc1,
			rng.randf_range(OBSTACLE_CELLS * 0.85, OBSTACLE_CELLS * 1.2), rng, true)

	# 2. A few obstacles in deeper interior void (not adjacent to floor).
	for cj2 in range(gh):
		for ci2 in range(gw):
			if layout.val(ci2, cj2) != 0 or _touches_floor(layout, ci2, cj2):
				continue
			if rng.randf() > 0.05:
				continue
			var wc2: Vector2 = layout.cell_to_world(Vector2i(ci2, cj2))
			if absf(wc2.x) > lim_x or absf(wc2.y) > lim_y:
				continue
			if _near_any(wc2, gate_positions, GATE_CLEAR):
				continue
			_try_obstacle(root, placed, _pick(TREE_NAMES, rng), wc2,
				rng.randf_range(OBSTACLE_CELLS * 0.7, OBSTACLE_CELLS), rng, true)

	# 3. Sparse big accents along path edges — clusters of trees or tall ice spikes.
	for e3 in edge_cells:
		if rng.randf() > 0.08:
			continue
		var wc3: Vector2 = e3["pos"]
		if _near_any(wc3, gate_positions, GATE_CLEAR):
			continue
		if rng.randf() < 0.7:
			_try_cluster(root, placed, wc3, rng, TREE_NAMES, true)
		else:
			_try_obstacle(root, placed, _pick(SPIKE_NAMES, rng), wc3,
				rng.randf_range(1.8, 2.2), rng, true)

	# 4. COVERAGE PASS — every collidable wall cell bordering floor wears a visible
	#    tree/rock, so an open-looking gap is never an invisible wall.
	for cj3 in range(gh):
		for ci3 in range(gw):
			if layout.val(ci3, cj3) != 0 or not _touches_floor(layout, ci3, cj3):
				continue
			var wcc: Vector2 = layout.cell_to_world(Vector2i(ci3, cj3))
			if absf(wcc.x) > lim_x or absf(wcc.y) > lim_y:
				continue
			var covered: bool = false
			for p in placed:
				if wcc.distance_to(p["c"]) <= float(p["r"]) + 10.0:
					covered = true
					break
			if not covered:
				_fit_rock(root, placed, _pick(TREE_SMALL + ROCK_NAMES, rng), wcc, rng)

	# 5. Free-standing small barriers (crystal, sack, crate, log, barrel) on open floor.
	_place_small_barriers(root, placed, layout, gate_positions, rng, gw, gh, lim_x, lim_y)

	# 6. Flat decor scattered on open floor (snowball, snowpile, campfire, etc).
	var pool: Array = _decor_weighted()
	if not pool.is_empty():
		var dcount: int = int(float(gw * gh) / 44.0)
		for _i in range(dcount):
			var ci4: int = rng.randi_range(1, gw - 2)
			var cj4: int = rng.randi_range(1, gh - 2)
			if layout.val(ci4, cj4) != 1:
				continue
			if not _open_floor(layout, ci4, cj4, 2):
				continue
			var dwc: Vector2 = layout.cell_to_world(Vector2i(ci4, cj4))
			if _near_any(dwc, gate_positions, GATE_CLEAR * 0.55):
				continue
			var pick: Array = pool[rng.randi() % pool.size()]
			_add_decor(root, String(pick[0]), dwc, float(pick[1]), rng)

	# 7. (Stalactite/icicle accents removed from outdoor winter arenas —
	#    reserved for future indoor cave-exit rooms as falling traps.)
	return root


# ===========================================================================
# WALLS — snowy tree-lined border with cave/spike gate markers.
# ===========================================================================
static func make_walls(half: Vector2, exit_dir: Vector2, gate_positions: Array,
		seed_val: int, layout: RefCounted = null,
		gate_exit_types: Array = []) -> Node2D:
	var root := Node2D.new()
	root.name = "PeakWalls"
	root.z_index = PROP_Z
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 2246822519 + 73

	# 1. OUTER FOREST — dense jittered grid over the E/W outside bands only.
	#    N/S borders are kept clear (mountain path ahead).
	var x0: float = -(half.x + FOREST_DEPTH)
	var x1: float =  (half.x + FOREST_DEPTH)
	var y0: float = -(half.y + FOREST_DEPTH)
	var y1: float =  (half.y + FOREST_DEPTH)
	var gx: float = x0
	while gx <= x1:
		var gy: float = y0
		while gy <= y1:
			# Trees only where x is beyond the arena's east/west edge (includes corners).
			if absf(gx) >= half.x:
				var jit := Vector2(rng.randf_range(-FOREST_STEP * 0.45, FOREST_STEP * 0.45),
					rng.randf_range(-FOREST_STEP * 0.45, FOREST_STEP * 0.45))
				var pos: Vector2 = Vector2(gx, gy) + jit
				if absf(pos.x) >= half.x \
						and not _in_gate_lane(pos, gate_positions, half):
					_forest_tree(root, pos, rng, false)
			gy += FOREST_STEP
		gx += FOREST_STEP

	# 2. INNER VOID BAND — pack the E/W non-walkable strip just inside the border
	#    with trees. N/S border band left clear (mountain path ahead).
	if layout != null:
		var gw2: int = layout.gw
		var gh2: int = layout.gh
		var b: int = BORDER_BAND_CELLS
		for cj in range(gh2):
			for ci in range(gw2):
				# Only E/W border bands (skip cells not in the east or west strip).
				if ci >= b and ci < gw2 - b:
					continue
				var v: int = layout.val(ci, cj)
				if v == 1 or v == 3 or v == 2:
					continue
				var wc: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
				if _in_gate_lane(wc, gate_positions, half):
					continue
				_forest_tree(root, wc + Vector2(rng.randf_range(-6.0, 6.0), 0.0), rng, true)

	# 3. FRAME — a continuous treeline hugging E/W borders only (N/S kept clear).
	var fx: float = half.x + FRAME_MARGIN
	var wy: float = -half.y
	while wy <= half.y:
		_frame_tree(root, Vector2(-fx, wy), gate_positions, half, rng)
		_frame_tree(root, Vector2( fx, wy), gate_positions, half, rng)
		wy += FRAME_STEP

	# 4. MOUNTAIN WALL on the NORTH border — placeholder rocky wall. Cave exits
	#    get the cave mouth; open-air exits get a snowy path gap through the wall.
	_build_mountain_wall(root, half, gate_positions, rng, gate_exit_types)

	# 5. SOUTH BORDER — snowy entry path (clear, no wall). Just frame the entry
	#    gap with a few scattered rocks.
	_build_south_entry(root, half, gate_positions, rng)

	return root


# ===========================================================================
# WALLS (CAVE) — icy cavern variant: rock walls all around, no trees.
# ===========================================================================
static func make_walls_cave(half: Vector2, exit_dir: Vector2, gate_positions: Array,
		seed_val: int, layout: RefCounted = null,
		gate_exit_types: Array = []) -> Node2D:
	var root := Node2D.new()
	root.name = "PeakWallsCave"
	root.z_index = PROP_Z
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 2246822519 + 73

	# CAVE WALLS: rock props lining all four borders (no trees).
	var margin: float = FRAME_MARGIN
	var step: float = FRAME_STEP * 0.85   # denser than tree frame

	# E/W walls: solid rock border.
	var fxc: float = half.x + margin
	var wyc: float = -half.y
	while wyc <= half.y:
		for side in [-1.0, 1.0]:
			var pos := Vector2(side * fxc, wyc) + Vector2(rng.randf_range(-6.0, 6.0), rng.randf_range(-6.0, 6.0))
			if not _in_gate_lane(pos, gate_positions, half):
				_cave_wall_rock(root, pos, rng)
		wyc += step

	# S border: rock wall (entry comes from south cave/path).
	var fyc: float = half.y + margin
	var wxc: float = -half.x
	while wxc <= half.x:
		var pos := Vector2(wxc, fyc) + Vector2(rng.randf_range(-6.0, 6.0), rng.randf_range(-4.0, 4.0))
		if not _in_gate_lane(pos, gate_positions, half):
			_cave_wall_rock(root, pos, rng)
		wxc += step

	# N border: mountain wall with cave exits.
	_build_mountain_wall(root, half, gate_positions, rng, gate_exit_types)

	# Inner void band: fill with rocks.
	if layout != null:
		var gw3: int = layout.gw
		var gh3: int = layout.gh
		var b: int = BORDER_BAND_CELLS
		for cj in range(gh3):
			for ci in range(gw3):
				if ci >= b and ci < gw3 - b and cj >= b and cj < gh3 - b:
					continue
				var v: int = layout.val(ci, cj)
				if v == 1 or v == 3 or v == 2:
					continue
				var wc: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
				if _in_gate_lane(wc, gate_positions, half):
					continue
				_cave_wall_rock(root, wc + Vector2(rng.randf_range(-6.0, 6.0), 0.0), rng)

	return root


# ---------------------------------------------------------------------------
# Wall placement helpers.
# ---------------------------------------------------------------------------

# A single forest-fill tree (size-varied, no shadow — cheap; many are placed).
static func _forest_tree(root: Node2D, pos: Vector2, rng: RandomNumberGenerator,
		overhead: bool) -> void:
	var roll: float = rng.randf()
	var nm: String
	var hc: float
	if roll < 0.55:
		nm = _pick(TREE_BIG, rng); hc = rng.randf_range(3.0, 3.8)
	elif roll < 0.85:
		nm = _pick(TREE_NAMES, rng); hc = rng.randf_range(2.4, 3.1)
	else:
		nm = _pick(TREE_SMALL, rng); hc = rng.randf_range(1.7, 2.4)
	var tex: ImageTexture = _prop_tex(nm)
	if tex == null:
		return
	hc = _cap_h(tex, hc)
	_add_prop_tex(root, tex, pos, hc, rng, int(WORLD_CELL * 0.08), false, overhead)


# One frame tree at a border position unless it sits in the gate doorway lane.
static func _frame_tree(root: Node2D, pos: Vector2, gate_positions: Array,
		half: Vector2, rng: RandomNumberGenerator) -> void:
	if _in_gate_lane(pos, gate_positions, half):
		return
	var jitter := Vector2(rng.randf_range(-8.0, 8.0), rng.randf_range(-6.0, 6.0))
	var nm: String = _pick(TREE_BIG, rng) if rng.randf() < 0.75 else _pick(TREE_NAMES, rng)
	var tex: ImageTexture = _prop_tex(nm)
	if tex == null:
		return
	var hc: float = _cap_h(tex, rng.randf_range(FRAME_H_MIN, FRAME_H_MAX))
	_add_prop_tex(root, tex, pos + jitter, hc, rng, int(WORLD_CELL * 0.08), false, true)


# Place the cave mouth (mcave) centered on a gate opening.
# The cave mouth is a FEATURE art piece — it is exempt from the native-cap
# (PROP_PX_SCALE) so it draws at CAVE_HEIGHT_CELLS regardless of source res.
static func _place_cave(root: Node2D, tex: ImageTexture, gate: Vector2,
		half: Vector2, rng: RandomNumberGenerator) -> void:
	var hc: float = CAVE_HEIGHT_CELLS   # full size, no _cap_h
	var outw: Vector2 = _gate_outward(gate, half)
	# Shift the cave outward from the gate so it sits ON the border wall.
	var off: Vector2 = outw * 14.0
	# Build the sprite directly so we can put it ABOVE the wall rocks.
	var th: float = float(tex.get_height())
	var tw: float = float(tex.get_width())
	var sc: float = (WORLD_CELL * hc) / th
	var draw_h: float = th * sc
	var feet: Vector2 = gate + off
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	spr.scale = Vector2(sc, sc)
	spr.position = feet - Vector2(0.0, draw_h * 0.5)
	spr.z_as_relative = false
	spr.z_index = RunState.BARRIER_OVERHANG_Z + 1   # above wall rocks
	root.add_child(spr)


# Place a pair of ice-spike pillars flanking a gate opening.
static func _place_spike_pillars(root: Node2D, gate: Vector2, half: Vector2,
		rng: RandomNumberGenerator) -> void:
	var outw: Vector2 = _gate_outward(gate, half)
	var perp := Vector2(-outw.y, outw.x)     # perpendicular to the exit direction
	var nm_l: String = _pick(SPIKE_NAMES, rng)
	var nm_r: String = _pick(SPIKE_NAMES, rng)
	for side in [-1.0, 1.0]:
		var nm: String = nm_l if side < 0.0 else nm_r
		var tex: ImageTexture = _prop_tex(nm)
		if tex == null:
			continue
		var hc: float = _cap_h(tex, PILLAR_H_CELLS)
		var pos: Vector2 = gate + perp * (side * PILLAR_GAP) + outw * 6.0
		_add_prop_tex(root, tex, pos, hc, rng, 0, false, true)


# An icicle accent (overhead, hanging from the "ceiling" around the border).
static func _add_icicle(root: Node2D, pos: Vector2, rng: RandomNumberGenerator) -> void:
	var nm: String = _pick(ICICLE_NAMES, rng)
	var tex: ImageTexture = _prop_tex(nm)
	if tex == null:
		return
	var hc: float = _cap_h(tex, rng.randf_range(1.2, 1.8))
	_add_prop_tex(root, tex, pos, hc, rng, 0, false, true)


# ---------------------------------------------------------------------------
# Mountain wall on the north border (placeholder rocky face). Cave-type exits
# get the cave mouth sprite; open-air exits get a snowy path gap. The wall is
# drawn as overlapping rock props along the top border.
# ---------------------------------------------------------------------------
const MOUNTAIN_WALL_STEP: float = 36.0   # rock spacing along the wall
const MOUNTAIN_WALL_H_MIN: float = 2.8
const MOUNTAIN_WALL_H_MAX: float = 3.8

static func _build_mountain_wall(root: Node2D, half: Vector2, gate_positions: Array,
		rng: RandomNumberGenerator, gate_exit_types: Array) -> void:
	# Collect cave-type gate positions — wall rocks need a wider clearance
	# around them so the cave mouth art is fully visible.
	var cave_gates: Array = []
	for i in range(gate_positions.size()):
		if i < gate_exit_types.size() and gate_exit_types[i] == "cave":
			cave_gates.append(gate_positions[i] as Vector2)
	var ny: float = -(half.y + FRAME_MARGIN)
	# Solid rock wall across the entire north border, skipping gate lanes
	# and giving extra clearance around cave-type exits.
	var wx: float = -(half.x + FOREST_DEPTH * 0.5)
	while wx <= half.x + FOREST_DEPTH * 0.5:
		var pos := Vector2(wx, ny) + Vector2(rng.randf_range(-8.0, 8.0), rng.randf_range(-6.0, 6.0))
		if not _in_gate_lane(pos, gate_positions, half) \
				and not _near_cave_gate(pos, cave_gates):
			var nm: String = _pick(ROCK_NAMES, rng)
			var tex: ImageTexture = _prop_tex(nm)
			if tex != null:
				var hc: float = _cap_h(tex, rng.randf_range(MOUNTAIN_WALL_H_MIN, MOUNTAIN_WALL_H_MAX))
				_add_prop_tex(root, tex, pos, hc, rng, int(WORLD_CELL * 0.08), false, true)
		wx += MOUNTAIN_WALL_STEP
	# Pack a second layer slightly behind for depth.
	wx = -(half.x + FOREST_DEPTH * 0.5) + MOUNTAIN_WALL_STEP * 0.5
	while wx <= half.x + FOREST_DEPTH * 0.5:
		var pos := Vector2(wx, ny - 18.0) + Vector2(rng.randf_range(-8.0, 8.0), rng.randf_range(-4.0, 4.0))
		if not _in_gate_lane(pos, gate_positions, half) \
				and not _near_cave_gate(pos, cave_gates):
			var nm: String = _pick(ROCK_NAMES, rng)
			var tex: ImageTexture = _prop_tex(nm)
			if tex != null:
				var hc: float = _cap_h(tex, rng.randf_range(MOUNTAIN_WALL_H_MIN + 0.4, MOUNTAIN_WALL_H_MAX + 0.6))
				_add_prop_tex(root, tex, pos, hc, rng, 0, false, true)
		wx += MOUNTAIN_WALL_STEP

	# Gate markers — driven by exit type when available.
	var cave_tex: ImageTexture = _prop_tex(CAVE_NAME)
	for i in range(gate_positions.size()):
		var gpv: Vector2 = gate_positions[i] as Vector2
		var etype: String = "cave" if i < gate_exit_types.size() and gate_exit_types[i] == "cave" else "open"
		if etype == "cave" and cave_tex != null:
			_place_cave(root, cave_tex, gpv, half, rng)
		elif etype == "open":
			# Open-air path: just spike pillars framing the gap (path continues through).
			_place_spike_pillars(root, gpv, half, rng)
		else:
			_place_spike_pillars(root, gpv, half, rng)


# South border entry — a few rocks framing the entry path, not a full wall.
static func _build_south_entry(root: Node2D, half: Vector2, gate_positions: Array,
		rng: RandomNumberGenerator) -> void:
	var sy: float = half.y + FRAME_MARGIN
	# Sparse rocks on either side of the south center (entry is roughly center-south).
	for side in [-1.0, 1.0]:
		var bx: float = side * half.x * 0.4
		for _i in range(3):
			var pos := Vector2(bx + rng.randf_range(-30.0, 30.0), sy + rng.randf_range(-10.0, 10.0))
			if not _in_gate_lane(pos, gate_positions, half):
				var nm: String = _pick(ROCK_NAMES, rng)
				var tex: ImageTexture = _prop_tex(nm)
				if tex != null:
					var hc: float = _cap_h(tex, rng.randf_range(1.8, 2.6))
					_add_prop_tex(root, tex, pos, hc, rng, int(WORLD_CELL * 0.08), false, true)


# A single cave-wall rock for the cave room border (replaces trees).
static func _cave_wall_rock(root: Node2D, pos: Vector2, rng: RandomNumberGenerator) -> void:
	var nm: String = _pick(ROCK_NAMES, rng) if rng.randf() < 0.7 else _pick(SPIKE_NAMES, rng)
	var tex: ImageTexture = _prop_tex(nm)
	if tex == null:
		return
	var hc: float = _cap_h(tex, rng.randf_range(2.2, 3.4))
	_add_prop_tex(root, tex, pos, hc, rng, int(WORLD_CELL * 0.08), false, true)


# True when pos lies in a gate's exit corridor (cleared through the trees).
static func _in_gate_lane(pos: Vector2, gates: Array, half: Vector2) -> bool:
	for g in gates:
		var gv: Vector2 = g as Vector2
		var outw: Vector2 = _gate_outward(gv, half)
		if outw == Vector2.ZERO:
			continue
		var rel: Vector2 = pos - gv
		var along: float = rel.dot(outw)
		if along < -GATE_LANE_BACK:
			continue
		var perp: float = absf(rel.x * outw.y - rel.y * outw.x)
		var w: float = GATE_LANE_HALF + maxf(0.0, along) * GATE_LANE_FLARE
		if perp <= w:
			return true
	return false


# Cardinal outward normal for a gate, snapped to whichever border it sits on.
static func _gate_outward(g: Vector2, half: Vector2) -> Vector2:
	var dx: float = half.x - absf(g.x)
	var dy: float = half.y - absf(g.y)
	if dx <= dy:
		return Vector2(signf(g.x), 0.0)
	return Vector2(0.0, signf(g.y))


# ---------------------------------------------------------------------------
# Prop placement helpers (same conventions as CavernTileset).
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


# True when pos is within the wider clearance zone around a cave-type gate.
# Wall rocks inside this radius are suppressed so the cave mouth art is visible.
static func _near_cave_gate(p: Vector2, cave_gates: Array) -> bool:
	for cg in cave_gates:
		if p.distance_to(cg as Vector2) < CAVE_CLEAR_RADIUS:
			return true
	return false


static func _touches_floor(layout: RefCounted, ci: int, cj: int) -> bool:
	for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
			Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]:
		var v: int = layout.val(ci + off.x, cj + off.y)
		if v == 1 or v == 3:
			return true
	return false


static func _open_floor(layout: RefCounted, ci: int, cj: int, r: int) -> bool:
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dy * dy > r * r + 1:
				continue
			var v: int = layout.val(ci + dx, cj + dy)
			if v != 1 and v != 3:
				return false
	return true


# Native height (world cells) at the flat px scale — the LARGEST a prop may draw.
static func _native_h(tex: ImageTexture) -> float:
	return float(tex.get_height()) * PROP_PX_SCALE / WORLD_CELL


# Cap requested height to native (never upscale past source resolution).
static func _cap_h(tex: ImageTexture, height_cells: float) -> float:
	return minf(height_cells, _native_h(tex))


# Place an obstacle (tree/rock/spike) at base unless its foot-circle overlaps an
# existing prop. Barriers ride overhead so a hero passes behind on collision.
static func _try_obstacle(root: Node2D, placed: Array, name: String, base: Vector2,
		height_cells: float, rng: RandomNumberGenerator, tall: bool,
		gap: float = PROP_GAP) -> bool:
	var tex: ImageTexture = _prop_tex(name)
	if tex == null:
		return false
	height_cells = _cap_h(tex, height_cells)
	var foot_frac: float = 0.30 if tall else 0.40
	var draw_w: float = float(tex.get_width()) * (WORLD_CELL * height_cells / float(tex.get_height()))
	var r: float = draw_w * foot_frac
	for p in placed:
		if base.distance_to(p["c"]) < r + p["r"] + gap:
			return false
	_add_prop_tex(root, tex, base, height_cells, rng, int(WORLD_CELL * 0.10), true, not tall)
	placed.append({ "c": base, "r": r })
	return true


# Drop 2-3 native-size props shoulder-to-shoulder as a formation.
static func _try_cluster(root: Node2D, placed: Array, base: Vector2,
		rng: RandomNumberGenerator, pool_arr: Array, tall: bool) -> bool:
	var n: int = rng.randi_range(2, 3)
	var spread: float = WORLD_CELL * 0.55
	var placed_any: bool = false
	if _try_obstacle(root, placed, _pick(pool_arr, rng), base, 99.0, rng, tall, PROP_CLUSTER_GAP):
		placed_any = true
	for i in range(1, n):
		var off := Vector2(rng.randf_range(-1.0, 1.0) * spread,
			rng.randf_range(-0.25, 0.30) * spread)
		if _try_obstacle(root, placed, _pick(pool_arr, rng), base + off, 99.0, rng, tall, PROP_CLUSTER_GAP):
			placed_any = true
	return placed_any


# Coverage-pass prop: a NATIVE-size prop on a bare collidable cell.
static func _fit_rock(root: Node2D, placed: Array, name: String, base: Vector2,
		rng: RandomNumberGenerator) -> bool:
	var tex: ImageTexture = _prop_tex(name)
	if tex == null:
		return false
	var h: float = _native_h(tex)
	var foot_frac: float = 0.36
	var avail: float = WORLD_CELL * 0.95
	for p in placed:
		avail = minf(avail, base.distance_to(p["c"]) - float(p["r"]) - PROP_CLUSTER_GAP)
	if avail < WORLD_CELL * 0.28:
		return false
	var draw_w: float = float(tex.get_width()) * (WORLD_CELL * h / float(tex.get_height()))
	var r: float = draw_w * foot_frac
	if r > avail:
		h *= avail / r
		r = avail
	_add_prop_tex(root, tex, base, h, rng, int(WORLD_CELL * 0.10), true, false)
	placed.append({ "c": base, "r": r })
	return true


# Free-standing small barriers on open floor with own dashable_barrier collider.
static func _place_small_barriers(root: Node2D, placed: Array, layout: RefCounted,
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
			if wc.length() < 132.0:
				continue
			if _near_any(wc, gate_positions, GATE_CLEAR + 40.0):
				continue
			if not _open_floor(layout, ci, cj, 2):
				continue
			cands.append(wc)
	if cands.is_empty():
		return
	_shuffle(cands, rng)
	var n_items: int = rng.randi_range(1, 4)
	var done: int = 0
	var idx: int = 0
	while idx < cands.size() and done < n_items:
		var nm: String = _pick(SMALL_BARRIER_NAMES, rng)
		if _try_barrier(root, placed, nm, cands[idx], rng.randf_range(1.0, 1.5), rng, 0.62, 0.55):
			done += 1
		idx += 1


# Floor barrier: draw flush + attach a dashable_barrier collider.
static func _try_barrier(root: Node2D, placed: Array, name: String, base: Vector2,
		height_cells: float, rng: RandomNumberGenerator, foot_w_frac: float,
		foot_h_frac: float) -> bool:
	var tex: ImageTexture = _prop_tex(name)
	if tex == null:
		return false
	height_cells = _cap_h(tex, height_cells)
	var draw_h: float = WORLD_CELL * height_cells
	var draw_w: float = float(tex.get_width()) * (draw_h / float(tex.get_height()))
	var r: float = draw_w * 0.55
	for p in placed:
		if base.distance_to(p["c"]) < r + p["r"] + PROP_GAP:
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


static func _decor_weighted() -> Array:
	var out: Array = []
	for e in DECOR_TABLE:
		for _w in range(int(e[2])):
			out.append([e[0], float(e[1])])
	return out


# Flat run-over decor (no collision, no overhead).
static func _add_decor(root: Node2D, name: String, base: Vector2, height_cells: float,
		rng: RandomNumberGenerator) -> void:
	var tex: ImageTexture = _prop_tex(name)
	if tex == null:
		return
	height_cells = _cap_h(tex, height_cells)
	var sc: float = (WORLD_CELL * height_cells) / float(tex.get_height())
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	spr.scale = Vector2(sc, sc)
	var draw_h: float = float(tex.get_height()) * sc
	spr.position = base + Vector2(float(rng.randi_range(-9, 9)), 0.0) - Vector2(0.0, draw_h * 0.5)
	root.add_child(spr)


# Feet-anchored prop + soft contact shadow. Interior props in a y_sort container
# get foot-anchored wrapping for depth sorting; border props keep fixed-z.
static func _add_prop_tex(root: Node2D, tex: ImageTexture, base: Vector2, height_cells: float,
		rng: RandomNumberGenerator, sink: int, with_shadow: bool, overhead: bool) -> void:
	var th: float = float(tex.get_height())
	var tw: float = float(tex.get_width())
	var sc: float = (WORLD_CELL * height_cells) / th
	var draw_h: float = th * sc
	var draw_w: float = tw * sc
	var feet: Vector2 = base + Vector2(0.0, float(sink))
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


# ---------------------------------------------------------------------------
# GROUND — baked snowpack + snowy trails + frozen ice.
# ---------------------------------------------------------------------------
static func make_ground(half: Vector2, layout: RefCounted, seed_val: int) -> Sprite2D:
	if _sheet() == null:
		return null
	var gw: int = layout.gw
	var gh: int = layout.gh
	var m: int = GROUND_PAD
	var wc: int = gw + 2 * m
	var hc: int = gh + 2 * m
	var img := Image.create(wc * CELL_PX, hc * CELL_PX, false, Image.FORMAT_RGBA8)
	var snow_t: Array = _snow_variants()
	var ice_t: Array = _ice_variants()
	var puddle_t: Array = _puddle_variants()
	var crack_t: Array = _crack_variants()
	var src_rect := Rect2i(0, 0, CELL_PX, CELL_PX)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 2654435761 + 17

	# 1. Base pass — snow everywhere (padded cells included so tiles extend
	# fully into and past the arena walls). Ice only inside the layout grid.
	for cj in range(-m, gh + m):
		for ci in range(-m, gw + m):
			var dst := Vector2i((ci + m) * CELL_PX, (cj + m) * CELL_PX)
			var tile: Image
			var inside: bool = ci >= 0 and ci < gw and cj >= 0 and cj < gh
			if inside and layout.val(ci, cj) == V_WATER:
				if not _is_ice(layout, ci - 1, cj) and not _is_ice(layout, ci + 1, cj) \
				and not _is_ice(layout, ci, cj - 1) and not _is_ice(layout, ci, cj + 1):
					tile = _hpick(puddle_t, ci, cj, 5)
				else:
					tile = _hpick(ice_t, ci, cj, 1)
			else:
				tile = _hpick(snow_t, ci, cj, 7)
			img.blit_rect(tile, src_rect, dst)

	# 2. Shatter-crack accent inside larger ice sheets (interior cells only).
	if not crack_t.is_empty():
		for cj in range(gh):
			for ci in range(gw):
				if layout.val(ci, cj) != V_WATER:
					continue
				if layout.val(ci - 1, cj) != V_WATER or layout.val(ci + 1, cj) != V_WATER \
				or layout.val(ci, cj - 1) != V_WATER or layout.val(ci, cj + 1) != V_WATER:
					continue
				if rng.randf() < 0.16:
					img.blit_rect(crack_t[rng.randi() % crack_t.size()], src_rect,
						Vector2i((ci + m) * CELL_PX, (cj + m) * CELL_PX))

	# 3. Snowy trails — connected packed-snow routes (entry → chamber → gates).
	# Offset the trail blits by the padding margin.
	_bake_trails(img, layout, seed_val, m)

	# 4. Frosty rim wherever ice meets snow.
	_bake_ice_rim(img, layout, gw, gh, m)

	var spr := Sprite2D.new()
	spr.name = "TerrainGround"
	spr.centered = false
	spr.position = Vector2(-half.x - m * WORLD_CELL, -half.y - m * WORLD_CELL)
	spr.scale = Vector2(WORLD_CELL / float(CELL_PX), WORLD_CELL / float(CELL_PX))
	spr.z_index = GROUND_Z
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	spr.texture = ImageTexture.create_from_image(img)
	return spr


# ---------------------------------------------------------------------------
# Snowy trails — orthogonal trodden routes that flow naturally.
# ---------------------------------------------------------------------------
# Builds the set of trail cells by stepping orthogonally (with run commitment,
# so legs are long & straight) from the hero entry to the central chamber and
# out to every gate, then blends the packed-snow trail tile over each cell —
# choosing a STRAIGHT, CORNER or junction piece from the cell's trail neighbours
# so bends curve smoothly instead of kinking at right angles.
static func _bake_trails(img: Image, layout: RefCounted, seed_val: int, pad: int = 0) -> void:
	_build_path_tiles()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 40503 + 91

	var pset: Dictionary = {}                       # Vector2i (FLOOR trail cell) → true
	var chamber: Vector2i = layout.chamber_cell
	_route(layout, pset, layout.entry_cell, chamber, rng)
	for gc in layout.gate_cells:
		_route(layout, pset, chamber, gc as Vector2i, rng)

	for key in pset:
		var c: Vector2i = key
		var trail: Image = _trail_tile(pset, c.x, c.y)
		_blend_tile(img, (c.x + pad) * CELL_PX, (c.y + pad) * CELL_PX, trail, 0.72)


# Pick the trail piece for a cell from which orthogonal neighbours are also
# trail: straight V/H, an L-corner (one N/S + one E/W), or a junction (3-4
# neighbours → the straight tile of its through-axis, which keeps the main line
# continuous while a branch meets it).
static func _trail_tile(pset: Dictionary, i: int, j: int) -> Image:
	var n: bool = pset.has(Vector2i(i, j - 1))
	var s: bool = pset.has(Vector2i(i, j + 1))
	var w: bool = pset.has(Vector2i(i - 1, j))
	var e: bool = pset.has(Vector2i(i + 1, j))
	var cnt: int = int(n) + int(s) + int(e) + int(w)
	if cnt >= 3:
		return _path_v if (n and s) else _path_h
	if cnt == 2:
		if n and s:
			return _path_v
		if e and w:
			return _path_h
		if n and w:
			return _corner["NW"]
		if n and e:
			return _corner["NE"]
		if s and w:
			return _corner["SW"]
		return _corner["SE"]
	return _path_v if (n or s) else _path_h


# Orthogonal staircase with run commitment → long straight legs that meet at
# right angles. Only records walkable FLOOR cells (barriers/ice break the trail
# naturally, which is fine — the route resumes on the far side).
static func _route(layout: RefCounted, pset: Dictionary, a: Vector2i, b: Vector2i,
		rng: RandomNumberGenerator) -> void:
	var x: int = a.x
	var y: int = a.y
	if layout.val(x, y) == V_FLOOR:
		pset[Vector2i(x, y)] = true
	var guard: int = 0
	while (x != b.x or y != b.y) and guard < 500:
		guard += 1
		var go_h: bool = x != b.x and (y == b.y or absi(b.x - x) >= absi(b.y - y))
		if go_h:
			var run: int = mini(absi(b.x - x), rng.randi_range(2, 5))
			var s: int = 1 if b.x > x else -1
			for _i in range(maxi(1, run)):
				x += s
				if layout.val(x, y) == V_FLOOR:
					pset[Vector2i(x, y)] = true
				if x == b.x:
					break
		else:
			var run2: int = mini(absi(b.y - y), rng.randi_range(2, 5))
			var s2: int = 1 if b.y > y else -1
			for _j in range(maxi(1, run2)):
				y += s2
				if layout.val(x, y) == V_FLOOR:
					pset[Vector2i(x, y)] = true
				if y == b.y:
					break


# Alpha-blend a tile over the destination region (src over base by `a`).
static func _blend_tile(img: Image, dx: int, dy: int, src: Image, a: float) -> void:
	var w: int = src.get_width()
	var h: int = src.get_height()
	for py in range(h):
		for px in range(w):
			var base: Color = img.get_pixel(dx + px, dy + py)
			img.set_pixel(dx + px, dy + py, base.lerp(src.get_pixel(px, py), a))


static func _is_ice(layout: RefCounted, ci: int, cj: int) -> bool:
	return layout.val(ci, cj) == V_WATER


# Bright frosty rim wherever an ice cell meets a non-ice neighbour.
static func _bake_ice_rim(img: Image, layout: RefCounted, gw: int, gh: int, pad: int = 0) -> void:
	for cj in range(gh):
		for ci in range(gw):
			if not _is_ice(layout, ci, cj):
				continue
			var n: bool = _is_ice(layout, ci, cj - 1)
			var s: bool = _is_ice(layout, ci, cj + 1)
			var w: bool = _is_ice(layout, ci - 1, cj)
			var e: bool = _is_ice(layout, ci + 1, cj)
			if n and s and w and e:
				continue
			var x0: int = (ci + pad) * CELL_PX
			var y0: int = (cj + pad) * CELL_PX
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
						var t: float = (1.0 - float(dmin) / float(RIM_PX)) * 0.70
						var c: Color = img.get_pixel(x0 + px, y0 + py)
						img.set_pixel(x0 + px, y0 + py, c.lerp(FROST, t))


# ===========================================================================
# CAVE GROUND — ice-dominant floor with rocky patches (no snowy trails).
# ===========================================================================
# Cave rooms invert the snow/ice ratio: floor cells are mostly ICE (blue tiles)
# with scattered rocky patches (darkened snow tiles tinted gray). No trail paths
# (we're inside a cave, not on a snowy path).

const CAVE_ROCK_COLOR: Color = Color(0.38, 0.36, 0.34)  # rocky floor tint
const CAVE_ICE_CHANCE: float = 0.62   # chance a floor cell is ice instead of rock

static func make_ground_cave(half: Vector2, layout: RefCounted, seed_val: int) -> Sprite2D:
	if _sheet() == null:
		return null
	_cave_ice_cells.clear()
	var gw: int = layout.gw
	var gh: int = layout.gh
	var m: int = GROUND_PAD
	var wc: int = gw + 2 * m
	var hc: int = gh + 2 * m
	var img := Image.create(wc * CELL_PX, hc * CELL_PX, false, Image.FORMAT_RGBA8)
	var ice_t: Array = _ice_variants()
	var snow_t: Array = _snow_variants()
	var crack_t: Array = _crack_variants()
	var src_rect := Rect2i(0, 0, CELL_PX, CELL_PX)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 2654435761 + 31

	# Base pass — mostly ice floor, with scattered rocky patches.
	# Padded cells extend the floor into/past the arena wall area.
	for cj in range(-m, gh + m):
		for ci in range(-m, gw + m):
			var dst := Vector2i((ci + m) * CELL_PX, (cj + m) * CELL_PX)
			var tile: Image
			var inside: bool = ci >= 0 and ci < gw and cj >= 0 and cj < gh
			if inside:
				if layout.val(ci, cj) == V_WATER:
					tile = _hpick(ice_t, ci, cj, 1)
				elif layout.val(ci, cj) == V_FLOOR:
					if rng.randf() < CAVE_ICE_CHANCE:
						tile = _hpick(ice_t, ci, cj, 3)
						_cave_ice_cells[Vector2i(ci, cj)] = true
					else:
						tile = _hpick(snow_t, ci, cj, 9).duplicate()
						_tint_tile(tile, CAVE_ROCK_COLOR, 0.55)
				else:
					tile = _hpick(snow_t, ci, cj, 7).duplicate()
					_tint_tile(tile, CAVE_ROCK_COLOR.darkened(0.3), 0.70)
			else:
				# Padding cells: dark rock (extends cave floor into wall area).
				tile = _hpick(snow_t, ci, cj, 7).duplicate()
				_tint_tile(tile, CAVE_ROCK_COLOR.darkened(0.3), 0.70)
			img.blit_rect(tile, src_rect, dst)

	# Shatter-cracks are MORE common in cave rooms (the ice is stressed).
	if not crack_t.is_empty():
		for cj in range(gh):
			for ci in range(gw):
				if layout.val(ci, cj) != V_FLOOR and layout.val(ci, cj) != V_WATER:
					continue
				if rng.randf() < 0.22:
					img.blit_rect(crack_t[rng.randi() % crack_t.size()], src_rect,
						Vector2i((ci + m) * CELL_PX, (cj + m) * CELL_PX))

	# Ice rim at boundaries.
	_bake_ice_rim(img, layout, gw, gh, m)

	var spr := Sprite2D.new()
	spr.name = "TerrainGround"
	spr.centered = false
	spr.position = Vector2(-half.x - m * WORLD_CELL, -half.y - m * WORLD_CELL)
	spr.scale = Vector2(WORLD_CELL / float(CELL_PX), WORLD_CELL / float(CELL_PX))
	spr.z_index = GROUND_Z
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	spr.texture = ImageTexture.create_from_image(img)
	return spr


# Tint a tile image toward a target color.
static func _tint_tile(tile: Image, col: Color, strength: float) -> void:
	var w: int = tile.get_width()
	var h: int = tile.get_height()
	for y in range(h):
		for x in range(w):
			var c: Color = tile.get_pixel(x, y)
			tile.set_pixel(x, y, c.lerp(col, strength))


# Horizontal runs of ONLY the floor cells that make_ground_cave rendered as ice.
# Same format as DreamLayout.floor_runs() / water_runs(): Array of { pos, size }.
# Call AFTER make_ground_cave (which populates _cave_ice_cells).
static func cave_ice_floor_runs(layout: RefCounted) -> Array:
	var runs: Array = []
	var gw2: int = layout.gw
	var gh2: int = layout.gh
	var half2: Vector2 = Vector2(float(gw2), float(gh2)) * WORLD_CELL * 0.5
	for y in range(gh2):
		var x: int = 0
		while x < gw2:
			if not _cave_ice_cells.has(Vector2i(x, y)):
				x += 1
				continue
			var start: int = x
			while x < gw2 and _cave_ice_cells.has(Vector2i(x, y)):
				x += 1
			var n: int = x - start
			runs.append({
				"pos": Vector2((float(start) + float(n) * 0.5) * WORLD_CELL - half2.x,
					(float(y) + 0.5) * WORLD_CELL - half2.y),
				"size": Vector2(float(n) * WORLD_CELL, WORLD_CELL),
			})
	return runs


# ===========================================================================
# CAVE PROPS — interior obstacles for cave rooms (rocks, spikes, crystals).
# No trees — trees are outdoor. Cave rooms use rocks/spikes/crystals only.
# ===========================================================================
static func make_props_cave(half: Vector2, layout: RefCounted, seed_val: int,
		gate_positions: Array = []) -> Node2D:
	var root := Node2D.new()
	root.name = "PeakPropsCave"
	root.z_index = PROP_Z
	root.y_sort_enabled = true
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 40503 + hash("cave_props")
	var gw: int = layout.gw
	var gh: int = layout.gh
	var placed: Array = []
	var lim_x: float = half.x - EDGE_KEEPOUT
	var lim_y: float = half.y - EDGE_KEEPOUT

	# Cave obstacle pools — rocks and ice spikes only (no trees).
	var cave_obstacle_pool: Array = ROCK_NAMES + SPIKE_NAMES

	# Path-edge cells = blocked cells touching the floor.
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

	# 1. Rock/spike fences along paths.
	for e in edge_cells:
		var wc1: Vector2 = e["pos"]
		if _near_any(wc1, gate_positions, GATE_CLEAR):
			continue
		if rng.randf() > 0.88:
			continue
		var nm: String = _pick(cave_obstacle_pool, rng)
		_try_obstacle(root, placed, nm, wc1,
			rng.randf_range(OBSTACLE_CELLS * 0.85, OBSTACLE_CELLS * 1.2), rng, true)

	# 2. Coverage pass — every collidable wall cell bordering floor wears a rock.
	for cj3 in range(gh):
		for ci3 in range(gw):
			if layout.val(ci3, cj3) != 0 or not _touches_floor(layout, ci3, cj3):
				continue
			var wcc: Vector2 = layout.cell_to_world(Vector2i(ci3, cj3))
			if absf(wcc.x) > lim_x or absf(wcc.y) > lim_y:
				continue
			var covered: bool = false
			for p in placed:
				if wcc.distance_to(p["c"]) <= float(p["r"]) + 10.0:
					covered = true
					break
			if not covered:
				_fit_rock(root, placed, _pick(ROCK_NAMES, rng), wcc, rng)

	# 3. Small barriers on open floor (crystals, crates, barrels).
	_place_small_barriers(root, placed, layout, gate_positions, rng, gw, gh, lim_x, lim_y)

	# 4. Flat decor — same as outdoor but sparser (cave is more barren).
	var pool: Array = _decor_weighted()
	if not pool.is_empty():
		var dcount: int = int(float(gw * gh) / 66.0)   # sparser than outdoor
		for _i in range(dcount):
			var ci4: int = rng.randi_range(1, gw - 2)
			var cj4: int = rng.randi_range(1, gh - 2)
			if layout.val(ci4, cj4) != 1:
				continue
			if not _open_floor(layout, ci4, cj4, 2):
				continue
			var dwc: Vector2 = layout.cell_to_world(Vector2i(ci4, cj4))
			if _near_any(dwc, gate_positions, GATE_CLEAR * 0.55):
				continue
			var pick: Array = pool[rng.randi() % pool.size()]
			_add_decor(root, String(pick[0]), dwc, float(pick[1]), rng)

	return root
