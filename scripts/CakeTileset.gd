extends RefCounted

# ============================================================
# CakeTileset.gd — Run 171 (2026-09-02) — Dragon Cake Fortress
# ============================================================
# Real-art ground, props and border for the CAKE biome: the five
# ascension rooms you climb after the five star-arm biomes are
# cleansed, ending at the Shadow Sensei duel (CakeDojoRoom.gd).
#
# Until now the climb ran on DreamTerrain's procedural ramp
# renderer with sprinkle motifs — placeholder art. This module is
# the biome's own, cut by tools/slice_dragon_cake.py from
#   Assets/Tilesets/Dragon Cake Tileset.png           (interior)
#   Assets/Tilesets/Dragon Cake Exterior Tileset.png  (traversal)
# into Assets/Tilesets/DragonCake_props/.
#
# READING THE ROOM (the contract the art has to hold up):
#   floor  V_FLOOR/V_BRIDGE → vanilla ICING with gumdrops + sprinkles.
#          Bright, flat, obviously walkable.
#   chasm  V_WATER          → CRACKED CHOCOLATE. Blocked by DreamRoom's
#          water collider, so it has to read as "there is no cake here".
#   apron  outside the arena → devil's-food CRUMB. The fortress is one
#          enormous cake; the room you fight in is a slice of its icing.
#   void   V_VOID inside    → candy obstacles from make_props().
#
# Same static API as the other biome modules (SwampTileset et al.), so
# DreamTerrain/DreamRoom call it exactly the same way:
#   available() / ground_available() / walls_available()
#   make_ground(half, layout, seed)
#   make_props(half, layout, seed, gate_positions)
#   make_walls(half, exit_dir, gate_positions, seed, layout)
# ============================================================

const PROP_DIR: String = "res://Assets/Tilesets/DragonCake_props/"
const GROUND_DIR: String = PROP_DIR + "ground/"

const CELL_PX: int = 64             # baked px per 32px world cell (2× supersample)
const WORLD_CELL: float = 32.0
const GROUND_Z: int = -34
const PROP_Z: int = -12
const APRON_CELLS: int = 10         # devil's-food crumb baked beyond the arena

# Ground tile pools (files in ground/). Rows 0-2 of each auto-tile sub-panel;
# row 3 is a bottom-edge cap strip and is deliberately not cut.
# The walkable floor. Weighted on purpose: the SPRINKLE cells are quiet enough
# to read enemies and projectiles against, the GUMDROP cells are loud, so only
# two of them are in the pool (~20% of cells) as garnish. Cutting the pool the
# other way round gives a polka-dot carpet you cannot fight on.
const FLOOR_TILES: Array = ["sugar_8", "sugar_10", "sugar_5", "sugar_2",
	"sugar_7", "sugar_4", "sugar_0", "sugar_9", "icing_0", "icing_1"]
# Devil's-food crumb — the apron outside the arena. Rows 0-2 cols 0-3 of the
# auto-tile block; the cols 4-5 cells are sponge-and-jam layer strips, not fill.
const CHOC_TILES: Array = ["choc_0", "choc_1", "choc_2", "choc_3",
	"choc_6", "choc_7", "choc_8", "choc_9", "choc_12", "choc_13", "choc_14", "choc_15"]
const CRACK_TILES: Array = ["crack_0", "crack_1", "crack_2", "crack_3",
	"crack_4", "crack_5", "crack_6", "crack_7"]

# ── Prop rosters ────────────────────────────────────────────────────────────
# Chunky floor obstacles (get a dashable_barrier collider via _try_obstacle).
const OBSTACLE_NAMES: Array = ["clog_1", "clog_2", "cdonut_9", "cdonut_10",
	"cdonut_8", "ccake_1", "cslice_3", "cwaffle_1", "cmint_1", "cmarsh_1",
	"cgum_3", "cstack_donuts", "cstack_berry"]
# Tall accents along path edges — spires, vines, statues.
const ACCENT_NAMES: Array = ["cspike_1", "cspike_2", "cspike_3", "cspike_5",
	"cvine_1", "cbranch_1", "clolli_1", "clolli_2", "clicorice_1", "clicorice_3",
	"cstatue_1", "cskull_1", "cpillar_1"]
# Small filler for the coverage pass (never leave an invisible wall bare).
const RUBBLE_NAMES: Array = ["cgum_1", "cgum_2", "cbean_1", "cbean_2", "cbean_3",
	"cgem_1", "cgem_2", "cgem_3", "cjelly_2", "ccream_2", "cdonut_3", "cdonut_7"]
# Flat run-over decor scattered on open icing: [name, height_cells, weight].
const DECOR_TABLE: Array = [
	["cjelly_1", 0.55, 3], ["cjelly_3", 0.55, 3], ["cgems", 0.60, 2],
	["csplat_1", 0.70, 3], ["csplat_2", 0.70, 3], ["ccream_1", 0.60, 2],
	["cbean_1", 0.40, 2], ["cbean_2", 0.40, 2], ["cbean_3", 0.40, 2],
	["cdonut_5", 0.55, 2], ["cdonut_6", 0.55, 2], ["csparkle", 0.45, 1],
]
# The border "treeline": towering cake architecture instead of trunks.
const FRAME_BIG: Array = ["ccake_1", "ccake_2", "cpillar_1", "cslice_3", "cslice_1"]
const FRAME_MID: Array = ["cdonut_9", "cdonut_10", "cstack_donuts", "cstack_berry",
	"cslice_2", "cslice_4", "cberry_1"]
const FRAME_SMALL: Array = ["cspike_5", "cspike_4", "cmarsh_1", "cmint_1", "cberry_2"]

# ── Placement tuning (mirrors SwampTileset's, which is the tuned reference) ──
const EDGE_KEEPOUT: float = 56.0
const GATE_CLEAR: float = 104.0
const OBSTACLE_CELLS: float = 1.35
const ACCENT_CELLS: float = 2.4
const FRAME_MARGIN: float = 12.0
const FRAME_STEP: float = 54.0
const FRAME_H_MIN: float = 2.6
const FRAME_H_MAX: float = 3.5
const FIELD_DEPTH: float = 300.0
const FIELD_STEP: float = 56.0
const BORDER_BAND_CELLS: int = 4
const GATE_LANE_HALF: float = 40.0
const GATE_LANE_FLARE: float = 0.07
const GATE_LANE_BACK: float = 40.0

static var _prop_cache: Dictionary = {}     # name → ImageTexture (null when missing)
static var _ground_cache: Dictionary = {}   # name → Image
static var _shadow_tex: ImageTexture = null


# ---------------------------------------------------------------------------
# Loading (import-agnostic: works from the .import cache OR straight off disk,
# so freshly-sliced art shows up before Godot has re-imported the folder).
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


static func _prop_tex(name: String) -> ImageTexture:
	if _prop_cache.has(name):
		return _prop_cache[name]
	var img: Image = _load_png(PROP_DIR + name + ".png")
	var tex: ImageTexture = null
	if img != null:
		tex = ImageTexture.create_from_image(img)
	_prop_cache[name] = tex
	return tex


static func _ground_img(name: String) -> Image:
	if _ground_cache.has(name):
		var c = _ground_cache[name]
		return c if c is Image else null
	var img: Image = _load_png(GROUND_DIR + name + ".png")
	if img != null and (img.get_width() != CELL_PX or img.get_height() != CELL_PX):
		img.resize(CELL_PX, CELL_PX, Image.INTERPOLATE_LANCZOS)
	_ground_cache[name] = img if img != null else false
	return img


static func _tiles(names: Array) -> Array:
	var out: Array = []
	for n in names:
		var im: Image = _ground_img(String(n))
		if im != null:
			out.append(im)
	return out


static func _hpick(arr: Array, ci: int, cj: int, salt: int) -> Image:
	var hh: int = abs(hash(Vector2i(ci * 73856093 + salt, cj * 19349663 + salt)))
	return arr[hh % arr.size()]


# ---------------------------------------------------------------------------
# Availability (what DreamTerrain / DreamRoom probe before using this module).
# ---------------------------------------------------------------------------
static func available() -> bool:
	return _prop_tex("clog_1") != null or _prop_tex("cdonut_9") != null


static func ground_available() -> bool:
	return _ground_img("sugar_0") != null


static func walls_available() -> bool:
	return _prop_tex("ccake_1") != null or _prop_tex("cpillar_1") != null


# ===========================================================================
# GROUND — icing floor, chocolate chasms, devil's-food crumb apron.
# ===========================================================================
static func make_ground(half: Vector2, layout: RefCounted, seed_val: int) -> Sprite2D:
	var floor_t: Array = _tiles(FLOOR_TILES)
	var crack_t: Array = _tiles(CRACK_TILES)
	var choc_t: Array = _tiles(CHOC_TILES)
	if floor_t.is_empty() or choc_t.is_empty():
		return null
	if crack_t.is_empty():
		crack_t = choc_t
	var gw: int = layout.gw
	var gh: int = layout.gh
	var m: int = APRON_CELLS
	var img := Image.create((gw + 2 * m) * CELL_PX, (gh + 2 * m) * CELL_PX,
		false, Image.FORMAT_RGBA8)
	var src_rect := Rect2i(0, 0, CELL_PX, CELL_PX)
	for cj in range(-m, gh + m):
		for ci in range(-m, gw + m):
			var inside: bool = ci >= 0 and ci < gw and cj >= 0 and cj < gh
			var tile: Image
			if not inside:
				tile = _hpick(choc_t, ci, cj, 11)          # the cake beyond the slice
			elif layout.val(ci, cj) == 2:
				tile = _hpick(crack_t, ci, cj, 3)          # chocolate chasm
			else:
				tile = _hpick(floor_t, ci, cj, 7)          # icing floor
			img.blit_rect(tile, src_rect, Vector2i((ci + m) * CELL_PX, (cj + m) * CELL_PX))

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


# ===========================================================================
# PROPS — candy obstacles on the blocked cells, flat sweets on the open floor.
# Same five-pass shape as SwampTileset.make_props, including the COVERAGE pass
# (LOCK: a collidable cell must never look like open floor).
# ===========================================================================
static func make_props(half: Vector2, layout: RefCounted, seed_val: int,
		gate_positions: Array = []) -> Node2D:
	var root := Node2D.new()
	root.name = "CakeProps"
	root.z_index = PROP_Z
	root.y_sort_enabled = true
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 40503 + hash("cake")
	var gw: int = layout.gw
	var gh: int = layout.gh
	var placed: Array = []
	var lim_x: float = half.x - EDGE_KEEPOUT
	var lim_y: float = half.y - EDGE_KEEPOUT

	# Path-edge cells = blocked cells that touch walkable floor.
	var edge_cells: Array = []
	for cj in range(gh):
		for ci in range(gw):
			if layout.val(ci, cj) != 0 or not _touches_floor(layout, ci, cj):
				continue
			var wc: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
			if absf(wc.x) > lim_x or absf(wc.y) > lim_y:
				continue
			edge_cells.append(wc)
	_shuffle(edge_cells, rng)

	# 1. Confectionery fences lining the paths (with occasional natural breaks).
	for wc1 in edge_cells:
		if _near_any(wc1, gate_positions, GATE_CLEAR):
			continue
		if rng.randf() > 0.95:
			continue
		_try_obstacle(root, placed, _pick(OBSTACLE_NAMES, rng), wc1,
			rng.randf_range(OBSTACLE_CELLS * 0.85, OBSTACLE_CELLS * 1.2), rng, false)

	# 2. A few obstacles about the deep interior void.
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
			_try_obstacle(root, placed, _pick(OBSTACLE_NAMES, rng), wc2,
				rng.randf_range(OBSTACLE_CELLS * 0.7, OBSTACLE_CELLS), rng, false)

	# 3. Sparse tall accents — sugar-crystal spires, licorice vines, dragon relics.
	for wc3 in edge_cells:
		if rng.randf() > 0.08:
			continue
		if _near_any(wc3, gate_positions, GATE_CLEAR):
			continue
		_try_obstacle(root, placed, _pick(ACCENT_NAMES, rng), wc3,
			rng.randf_range(ACCENT_CELLS * 0.85, ACCENT_CELLS * 1.15), rng, true)

	# 4. COVERAGE — every collidable cell bordering floor wears something visible.
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
				_fit_prop(root, placed, _pick(RUBBLE_NAMES, rng), wcc, rng)

	# 5. Flat run-over sweets scattered on the open icing.
	var pool: Array = _decor_weighted()
	if not pool.is_empty():
		var dcount: int = int(float(gw * gh) / 24.0)
		for _i in range(dcount):
			var ci4: int = rng.randi_range(1, maxi(1, gw - 2))
			var cj4: int = rng.randi_range(1, maxi(1, gh - 2))
			if layout.val(ci4, cj4) != 1:
				continue
			var dwc: Vector2 = layout.cell_to_world(Vector2i(ci4, cj4))
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


# ===========================================================================
# WALLS — the fortress skyline. Instead of a treeline the border is stacked
# cake architecture: layer cakes, melting pillars, giant donuts, sugar spires.
# ===========================================================================
static func make_walls(half: Vector2, _exit_dir: Vector2, gate_positions: Array,
		seed_val: int, layout: RefCounted = null) -> Node2D:
	var root := Node2D.new()
	root.name = "CakeWalls"
	root.z_index = PROP_Z
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 2246822519 + 71

	# 1. OUTER FIELD — a jittered grid of cake architecture over the whole band
	#    outside the arena, so the horizon is fortress, never bald void.
	var lo := Vector2(-(half.x + FIELD_DEPTH), -(half.y + FIELD_DEPTH))
	var hi := Vector2(half.x + FIELD_DEPTH, half.y + FIELD_DEPTH)
	var gx: float = lo.x
	while gx <= hi.x:
		var gy: float = lo.y
		while gy <= hi.y:
			if absf(gx) >= half.x or absf(gy) >= half.y:
				var pos := Vector2(gx, gy) + Vector2(
					rng.randf_range(-FIELD_STEP * 0.45, FIELD_STEP * 0.45),
					rng.randf_range(-FIELD_STEP * 0.45, FIELD_STEP * 0.45))
				if (absf(pos.x) >= half.x or absf(pos.y) >= half.y) \
						and not _in_gate_lane(pos, gate_positions, half):
					_field_piece(root, pos, rng, false)
			gy += FIELD_STEP
		gx += FIELD_STEP

	# 2. INNER VOID BAND — pack the unwalkable strip just inside the border, but
	#    SKIP cells that touch floor: those belong to make_props, and stacking
	#    both there produces prop-on-prop overlap.
	if layout != null:
		var gw: int = layout.gw
		var gh: int = layout.gh
		var b: int = BORDER_BAND_CELLS
		for cj in range(gh):
			for ci in range(gw):
				if ci >= b and ci < gw - b and cj >= b and cj < gh - b:
					continue
				var v: int = layout.val(ci, cj)
				if v == 1 or v == 2 or v == 3:
					continue
				if _touches_floor(layout, ci, cj):
					continue
				var wc: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
				if _in_gate_lane(wc, gate_positions, half):
					continue
				_field_piece(root, wc + Vector2(rng.randf_range(-6.0, 6.0), 0.0), rng, true)

	# 3. FRAME — a continuous run of tall cake hugging each border; only the gate
	#    hallway is left clear.
	var fx: float = half.x + FRAME_MARGIN
	var fy: float = half.y + FRAME_MARGIN
	var x: float = -half.x
	while x <= half.x:
		_frame_piece(root, Vector2(x, -fy), gate_positions, half, rng)
		_frame_piece(root, Vector2(x,  fy), gate_positions, half, rng)
		x += FRAME_STEP
	var y: float = -half.y
	while y <= half.y:
		_frame_piece(root, Vector2(-fx, y), gate_positions, half, rng)
		_frame_piece(root, Vector2( fx, y), gate_positions, half, rng)
		y += FRAME_STEP
	return root


static func _field_piece(root: Node2D, pos: Vector2, rng: RandomNumberGenerator,
		overhead: bool) -> void:
	var roll: float = rng.randf()
	var nm: String
	var hc: float
	if roll < 0.50:
		nm = _pick(FRAME_BIG, rng); hc = rng.randf_range(2.9, 3.7)
	elif roll < 0.82:
		nm = _pick(FRAME_MID, rng); hc = rng.randf_range(2.3, 3.0)
	else:
		nm = _pick(FRAME_SMALL, rng); hc = rng.randf_range(1.7, 2.4)
	var tex: ImageTexture = _prop_tex(nm)
	if tex == null:
		return
	_add_prop_tex(root, tex, pos, hc, rng, int(WORLD_CELL * 0.06), false, overhead)


static func _frame_piece(root: Node2D, pos: Vector2, gate_positions: Array,
		half: Vector2, rng: RandomNumberGenerator) -> void:
	if _in_gate_lane(pos, gate_positions, half):
		return
	var jitter := Vector2(rng.randf_range(-8.0, 8.0), rng.randf_range(-6.0, 6.0))
	var nm: String = _pick(FRAME_BIG, rng) if rng.randf() < 0.7 else _pick(FRAME_MID, rng)
	var tex: ImageTexture = _prop_tex(nm)
	if tex == null:
		return
	_add_prop_tex(root, tex, pos + jitter, rng.randf_range(FRAME_H_MIN, FRAME_H_MAX),
		rng, int(WORLD_CELL * 0.06), false, true)


# True when pos lies in a gate's exit corridor: a narrow doorway at the border
# that flares as it runs outward, carving a clean path through the skyline.
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
		if perp <= GATE_LANE_HALF + maxf(0.0, along) * GATE_LANE_FLARE:
			return true
	return false


static func _gate_outward(g: Vector2, half: Vector2) -> Vector2:
	var dx: float = half.x - absf(g.x)
	var dy: float = half.y - absf(g.y)
	if dx <= dy:
		return Vector2(signf(g.x), 0.0)
	return Vector2(0.0, signf(g.y))


# ---------------------------------------------------------------------------
# Placement helpers (same contracts as the other biome modules).
# ---------------------------------------------------------------------------
static func _pick(arr: Array, rng: RandomNumberGenerator) -> String:
	return String(arr[rng.randi() % arr.size()])


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


static func _try_obstacle(root: Node2D, placed: Array, name: String, base: Vector2,
		height_cells: float, rng: RandomNumberGenerator, tall: bool) -> bool:
	var tex: ImageTexture = _prop_tex(name)
	if tex == null:
		return false
	var foot_frac: float = 0.30 if tall else 0.40
	var draw_w: float = float(tex.get_width()) * (WORLD_CELL * height_cells / float(tex.get_height()))
	var r: float = draw_w * foot_frac
	for p in placed:
		if base.distance_to(p["c"]) < r + p["r"]:
			return false
	_add_prop_tex(root, tex, base, height_cells, rng, int(WORLD_CELL * 0.10), true, not tall)
	placed.append({ "c": base, "r": r })
	return true


# Coverage pass: always places SOMETHING on a bare collidable cell, shrunk to
# fit the free gap so it abuts its neighbours rather than stacking on them.
static func _fit_prop(root: Node2D, placed: Array, name: String, base: Vector2,
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


# Feet-anchored prop + soft contact shadow. Overhead props ride the global
# RunState.BARRIER_OVERHANG_Z so a hero colliding with one passes BEHIND it.
static func _add_prop_tex(root: Node2D, tex: ImageTexture, base: Vector2,
		height_cells: float, rng: RandomNumberGenerator, sink: int,
		with_shadow: bool, overhead: bool) -> void:
	var th: float = float(tex.get_height())
	var sc: float = (WORLD_CELL * height_cells) / th
	var draw_h: float = th * sc
	var draw_w: float = float(tex.get_width()) * sc
	var feet: Vector2 = base + Vector2(0.0, float(sink))
	if overhead and root.y_sort_enabled:
		var wrap := Node2D.new()
		wrap.position = feet
		wrap.z_as_relative = false
		wrap.z_index = 0
		if with_shadow:
			wrap.add_child(_shadow_sprite(draw_w))
		var spr := Sprite2D.new()
		spr.texture = tex
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		spr.scale = Vector2(sc, sc)
		spr.position = Vector2(0.0, -draw_h * 0.5)
		wrap.add_child(spr)
		root.add_child(wrap)
		return
	if with_shadow:
		var sh: Sprite2D = _shadow_sprite(draw_w)
		sh.position = feet
		root.add_child(sh)
	var spr2 := Sprite2D.new()
	spr2.texture = tex
	spr2.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	spr2.scale = Vector2(sc, sc)
	spr2.position = feet - Vector2(0.0, draw_h * 0.5)
	if overhead:
		spr2.z_as_relative = false
		spr2.z_index = RunState.BARRIER_OVERHANG_Z
	root.add_child(spr2)


static func _shadow_sprite(draw_w: float) -> Sprite2D:
	var sh := Sprite2D.new()
	var stex: ImageTexture = _shadow_texture()
	sh.texture = stex
	sh.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var sh_w: float = draw_w * 0.6
	var sh_h: float = maxf(6.0, sh_w * 0.4)
	sh.scale = Vector2(sh_w / float(stex.get_width()), sh_h / float(stex.get_height()))
	return sh


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
			var a: float = clampf(1.0 - (nx * nx + ny * ny), 0.0, 1.0)
			img.set_pixel(x, y, Color(0.08, 0.086, 0.11, pow(a, 1.3) * 0.42))
	_shadow_tex = ImageTexture.create_from_image(img)
	return _shadow_tex
