extends RefCounted

# ============================================================
# JungleTileset.gd — Rotwood Jungle real-art pass
# ============================================================
# Self-contained jungle biome module (modelled after SwampTileset).
# Owns Assets/Tilesets/Jungle_props end-to-end: baked GROUND
# (BiomeGround for the procedural floor), hand-cut PROPS, and a
# jungle-TREE arena wall FRAME + dense outer forest. No longer
# routes through the shared BiomeProps engine.
#
# Source art (all clean PNGs sliced from Bruno's Jungle Assets sheet):
#   Jungle_props/jrock_1..10              — mossy rock obstacles
#   Jungle_props/jrubble_1..2             — stone rubble (coverage)
#   Jungle_props/jidol_1..2               — carved stone face + totem idol
#   Jungle_props/jtree_1..5               — trees
#       1=banyan(big), 2=round-bushy, 3=palm(small obstacle),
#       4=vine-draped(big), 5=medium-rounded
#   Jungle_props/jvine_1..3               — vine/branch accents
#   Jungle_props/jplant_1..5              — tropical plants (run-over decor)
#   Jungle_props/jmush_1..2               — mushrooms (run-over decor)
#   Jungle_props/jtwig_1                  — small roots/twigs (run-over decor)
#
# What this module produces for the JUNGLE biome:
#   make_ground — delegates to BiomeGround (procedural ramp floor).
#   make_props  — rock/idol/palm obstacles fencing the player paths (overhead
#       so a ninja passes BEHIND them, DASH flies over), sporadic big trees
#       as interior barriers for a maze-like feel, tall vine accents, a
#       coverage pass killing invisible-wall gaps, and flat plant/mushroom/
#       twig decor scattered on open floor.
#   make_walls  — a dense jungle-TREE frame ringing the arena (gate gaps
#       left open) backed by a filled outer forest of trees so the border
#       reads as thick jungle canopy, with clear hallway exit lanes.
# ============================================================

const GROUND = preload("res://scripts/BiomeGround.gd")

const PROP_DIR: String = "res://Assets/Tilesets/Jungle_props/"

# --- Prop name pools (sliced PNGs in Jungle_props/) --------------------------
const ROCK_NAMES: Array = ["jrock_1", "jrock_2", "jrock_3", "jrock_4",
	"jrock_5", "jrock_6", "jrock_7", "jrock_8", "jrock_9", "jrock_10"]
const RUBBLE_NAMES: Array = ["jrubble_1", "jrubble_2"]
const IDOL_NAMES: Array = ["jidol_1", "jidol_2"]
# Trees — all drawn at NATIVE resolution (never upscaled past source px).
# Big ones build the wall frame + sparse interior barriers; palm is a small obstacle.
const TREE_BIG: Array = ["jtree_1", "jtree_2", "jtree_4", "jtree_5"]
const TREE_MID: Array = ["jtree_2", "jtree_5"]
const PALM: String = "jtree_3"    # small palm — used as an obstacle alongside rocks
# Tall vine/branch accents (stand on the wall line like spikes).
const VINE_NAMES: Array = ["jvine_1", "jvine_2", "jvine_3"]
# Flat run-over decor — [name, height(world cells), weight].
const DECOR_TABLE: Array = [
	["jplant_1", 0.88, 3], ["jplant_2", 0.90, 2], ["jplant_3", 0.92, 2],
	["jplant_4", 0.90, 3], ["jplant_5", 0.85, 2],
	["jmush_1", 0.65, 3], ["jmush_2", 0.90, 1],
	["jtwig_1", 0.45, 3],
]

# --- Ground config (passed to BiomeGround) ------------------------------------
const CFG: Dictionary = {
	"biome_id":        "jungle",
	"dir":             "res://Assets/Tilesets/Jungle_props/",
	"prefix":          "j",
	"max_index":       80,
	"sheet":           "res://Assets/Tilesets/Jungle Tileset.png",
	"floor_rect":      [64, 64, 120, 120],
	"liquid_rect":     [1984, 192, 120, 120],
	"rim":             Color(0.88, 0.95, 0.97),
	"rim_light":       true,
}

# --- Placement tuning (props) ------------------------------------------------
const WORLD_CELL: float = 32.0
const GROUND_Z: int = -34
const PROP_Z: int = -12
const EDGE_KEEPOUT: float = 56.0
const GATE_CLEAR: float = 136.0
const OBSTACLE_CELLS: float = 1.35       # rock/idol fence height (world cells)
const ACCENT_CELLS: float = 2.4          # vine / small-tree accent height

# --- Placement tuning (tree wall frame + forest) ------------------------------
const FRAME_MARGIN: float = 12.0         # frame-tree feet sit just outside the floor edge
const FRAME_STEP: float = 48.0           # spacing along the border → dense overlapping canopy
const FRAME_H_MIN: float = 2.8
const FRAME_H_MAX: float = 3.8
const FOREST_BAND_MIN: float = 18.0
const FOREST_DEPTH: float = 300.0
const FOREST_STEP: float = 50.0          # grid pitch for the dense outer forest fill
const BORDER_BAND_CELLS: int = 4         # inner void band packed with trees

# --- Gate exit lane (clear corridor through the forest) -----------------------
const GATE_LANE_HALF: float = 56.0       # hallway half-width (~112px = wide clear corridor)
const GATE_LANE_FLARE: float = 0.10      # outward widening so the lane fans open
const GATE_LANE_BACK: float = 64.0       # clear zone extends further inside the border
const DIVIDER_TREES: int = 5             # forced trees planted between adjacent same-wall gates

static var _prop_cache: Dictionary = {}   # name → ImageTexture (or null if missing)
static var _shadow_tex: ImageTexture = null
static var _water_frames: SpriteFrames = null   # 8-frame animated water

# --- Water tile sheet (jwater_sheet.png: 8 × 128px horizontal strip) ----------
const WATER_SHEET: String = "res://Assets/Tilesets/Jungle_props/jwater_sheet.png"
const WATER_FRAME_COUNT: int = 8
const WATER_CELL_PX: int = 128             # each frame is 128×128
const WATER_FPS: float = 6.0               # smooth flowing speed
const WATER_GATE_CLEAR: float = 80.0       # keep gate mouths free of water tiles


# ---------------------------------------------------------------------------
# Prop loading (import-agnostic).
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


static func _prop_tex(pname: String) -> ImageTexture:
	if _prop_cache.has(pname):
		return _prop_cache[pname]
	var img: Image = _load_png(PROP_DIR + pname + ".png")
	var tex: ImageTexture = null
	if img != null:
		tex = ImageTexture.create_from_image(img)
	_prop_cache[pname] = tex
	return tex


# ---------------------------------------------------------------------------
# Public availability API.
# ---------------------------------------------------------------------------
static func available() -> bool:
	return _prop_tex("jrock_1") != null or _prop_tex("jtree_1") != null


static func ground_available() -> bool:
	return GROUND.available(CFG)


static func walls_available() -> bool:
	return _prop_tex("jtree_1") != null or _prop_tex("jtree_4") != null


# ===========================================================================
# GROUND — delegates to BiomeGround (procedural ramp floor).
# ===========================================================================
static func make_ground(half: Vector2, layout: RefCounted, seed_val: int) -> Sprite2D:
	return GROUND.make_ground(CFG, half, layout, seed_val)


# ===========================================================================
# LIQUID — animated water tiles on river (V_WATER) + trap pool cells.
# ===========================================================================
static func _init_water_frames() -> void:
	if _water_frames != null:
		return
	var img: Image = _load_png(WATER_SHEET)
	if img == null:
		return
	_water_frames = SpriteFrames.new()
	_water_frames.add_animation("water")
	_water_frames.set_animation_loop("water", true)
	_water_frames.set_animation_speed("water", WATER_FPS)
	var fw: int = WATER_CELL_PX
	for i in range(WATER_FRAME_COUNT):
		var rect := Rect2i(i * fw, 0, fw, fw)
		var frame_img := img.get_region(rect)
		_water_frames.add_frame("water", ImageTexture.create_from_image(frame_img))


static func make_liquid(half: Vector2, layout: RefCounted, seed_val: int,
		gate_positions: Array = []) -> Node2D:
	_init_water_frames()
	if _water_frames == null:
		return null
	var root := Node2D.new()
	root.name = "JungleLiquid"
	root.z_index = GROUND_Z + 1              # above floor, below props + heroes
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 2654435761 + 717
	var gw: int = layout.gw
	var gh: int = layout.gh

	# 1. Rivers — one animated water tile per V_WATER cell (skip gate mouths).
	for cj in range(gh):
		for ci in range(gw):
			if layout.val(ci, cj) != 2:
				continue
			var wpos: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
			if _water_blocked_by_gate(wpos, gate_positions, half):
				continue
			_water_tile(root, wpos, ci, cj, rng, false)

	# 2. Pools — fill trap pool circles with water tiles on floor cells.
	var traps: Array = layout.get("trap_spots")
	if traps != null:
		for t in traps:
			var ty: String = String((t as Dictionary).get("type", ""))
			if ty != "slow":
				continue   # only slow traps get a water pool in jungle
			var wp: Vector2 = (t as Dictionary).get("pos", Vector2.ZERO)
			var pr: float = float((t as Dictionary).get("pool_radius", 56.0))
			_fill_water_pool(root, layout, wp, pr, rng, gate_positions, half)
	return root


static func _water_blocked_by_gate(p: Vector2, gates: Array, half: Vector2) -> bool:
	return _in_gate_lane(p, gates, half) or _near_any(p, gates, WATER_GATE_CLEAR)


static func _water_tile(root: Node2D, world_pos: Vector2, ci: int, cj: int,
		rng: RandomNumberGenerator, allow_flip: bool) -> void:
	var a := AnimatedSprite2D.new()
	a.sprite_frames = _water_frames
	a.animation = "water"
	a.centered = true
	a.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	a.position = world_pos
	a.scale = Vector2(WORLD_CELL / float(WATER_CELL_PX), WORLD_CELL / float(WATER_CELL_PX))
	if allow_flip:
		var hsh: int = abs(hash(Vector2i(ci, cj)))
		a.flip_h = (hsh & 1) == 1
		a.flip_v = (hsh & 2) == 2
		a.frame = hsh % WATER_FRAME_COUNT
		a.speed_scale = rng.randf_range(0.85, 1.15)
	else:
		# Rivers: consistent flow direction, slight desync so tiles don't strobe.
		a.frame = (ci + cj * 3) % WATER_FRAME_COUNT
		a.speed_scale = rng.randf_range(0.95, 1.05)
	a.play("water")
	root.add_child(a)


static func _fill_water_pool(root: Node2D, layout: RefCounted, center: Vector2,
		radius: float, rng: RandomNumberGenerator, gate_positions: Array,
		half: Vector2) -> void:
	var cc: Vector2i = layout.world_to_cell(center)
	var span: int = int(ceil(radius / WORLD_CELL)) + 1
	for dj in range(-span, span + 1):
		for di in range(-span, span + 1):
			var ci: int = cc.x + di
			var cj: int = cc.y + dj
			var v: int = layout.val(ci, cj)
			if v != 1 and v != 3:
				continue
			var wpos: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
			if wpos.distance_to(center) > radius + WORLD_CELL * 0.35:
				continue
			if _water_blocked_by_gate(wpos, gate_positions, half):
				continue
			_water_tile(root, wpos, ci, cj, rng, true)


# ===========================================================================
# PROPS — rock/idol obstacles + vine accents + flat decor.
# ===========================================================================
static func make_props(half: Vector2, layout: RefCounted, seed_val: int,
		gate_positions: Array = []) -> Node2D:
	var root := Node2D.new()
	root.name = "JungleProps"
	root.z_index = PROP_Z
	root.y_sort_enabled = true
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 40503 + hash("jungle")
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

	# 1. BIG TREES first — placed before rocks so they claim their space and
	#    subsequent obstacles never spawn under the canopy.
	var interior_tree_budget: int = int(float(gw * gh) / 180.0) + rng.randi_range(1, 3)
	for _it in range(interior_tree_budget):
		var ci4: int = rng.randi_range(3, gw - 4)
		var cj4: int = rng.randi_range(3, gh - 4)
		if layout.val(ci4, cj4) != 1:
			continue
		var floor_n: int = 0
		for off in [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)]:
			if layout.val(ci4 + off.x, cj4 + off.y) == 1:
				floor_n += 1
		if floor_n < 2:
			continue
		var wc4: Vector2 = layout.cell_to_world(Vector2i(ci4, cj4))
		if _near_any(wc4, gate_positions, GATE_CLEAR * 1.2):
			continue
		var tname: String = _pick(TREE_BIG, rng)
		_try_big_tree(root, placed, tname, wc4, rng.randf_range(3.0, 3.8), rng)

	# 2. Rock/idol/palm FENCES lining the player paths (occasional natural breaks).
	for e in edge_cells:
		var wc1: Vector2 = e["pos"]
		if _near_any(wc1, gate_positions, GATE_CLEAR):
			continue
		if rng.randf() > 0.95:
			continue
		var pool: Array = ROCK_NAMES.duplicate()
		if rng.randf() < 0.08:
			pool = IDOL_NAMES
		elif rng.randf() < 0.15:
			_try_obstacle(root, placed, PALM, wc1,
				rng.randf_range(1.7, 2.4), rng, false)
			continue
		_try_obstacle(root, placed, _pick(pool, rng), wc1,
			rng.randf_range(OBSTACLE_CELLS * 0.85, OBSTACLE_CELLS * 1.2), rng, false)

	# 3. A few obstacles in the open interior void.
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

	# 4. Sparse tall accents (vines) along path edges.
	for e3 in edge_cells:
		if rng.randf() > 0.08:
			continue
		var wc3: Vector2 = e3["pos"]
		if _near_any(wc3, gate_positions, GATE_CLEAR):
			continue
		_try_obstacle(root, placed, _pick(VINE_NAMES, rng), wc3,
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

	# 6. Flat plant / mushroom / twig decor scattered on open floor (run-over).
	var pool: Array = _decor_weighted()
	if not pool.is_empty():
		var dcount: int = int(float(gw * gh) / 22.0)
		for _i in range(dcount):
			var ci3: int = rng.randi_range(1, gw - 2)
			var cj3: int = rng.randi_range(1, gh - 2)
			if layout.val(ci3, cj3) != 1:
				continue
			var dwc: Vector2 = layout.cell_to_world(Vector2i(ci3, cj3))
			if _near_any(dwc, gate_positions, GATE_CLEAR * 0.55):
				continue
			var dpick: Array = pool[rng.randi() % pool.size()]
			_add_decor(root, String(dpick[0]), dwc, float(dpick[1]), rng)
	return root


static func _decor_weighted() -> Array:
	var out: Array = []
	for e in DECOR_TABLE:
		for _w in range(int(e[2])):
			out.append([e[0], float(e[1])])
	return out


# ===========================================================================
# WALLS — jungle-tree arena frame + densely filled outer forest.
# ===========================================================================
# Everything outside the walkable floor is packed with trees so the surround
# reads as deep jungle canopy, EXCEPT each gate's exit hallway (a clear
# corridor the width of the gate, running straight out to the next arena).
static func make_walls(half: Vector2, exit_dir: Vector2, gate_positions: Array,
		seed_val: int, layout: RefCounted = null) -> Node2D:
	var root := Node2D.new()
	root.name = "JungleWalls"
	root.z_as_relative = false
	root.z_index = RunState.BARRIER_OVERHANG_Z
	root.y_sort_enabled = true
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 2246822519 + 83

	# 1. OUTER FOREST — a dense jittered grid over the whole outside band,
	#    drawn behind the frame. Skips only the gate exit hallway.
	var x0: float = -(half.x + FOREST_DEPTH)
	var x1: float =  (half.x + FOREST_DEPTH)
	var y0: float = -(half.y + FOREST_DEPTH)
	var y1: float =  (half.y + FOREST_DEPTH)
	var gx: float = x0
	while gx <= x1:
		var gy: float = y0
		while gy <= y1:
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
	#    trees so the wall band is a treeline, not a bald unpassable void.
	#    SKIP void cells that touch the floor — those are where make_props places
	#    rocks/obstacles, and double-placing a tree there causes tree-on-rock overlap.
	if layout != null:
		var gw: int = layout.gw
		var gh: int = layout.gh
		var b: int = BORDER_BAND_CELLS
		for cj in range(gh):
			for ci in range(gw):
				if ci >= b and ci < gw - b and cj >= b and cj < gh - b:
					continue
				var v: int = layout.val(ci, cj)
				if v == 1 or v == 3 or v == 2:
					continue
				# Skip void cells within 2 cells of any floor cell — big tree sprites
				# extend well beyond their placement cell, so a 1-cell gap still lets
				# canopy overlap into the playable arena.
				if _near_floor(layout, ci, cj, 2):
					continue
				var wc: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
				if _in_gate_lane(wc, gate_positions, half):
					continue
				_forest_tree(root, wc + Vector2(rng.randf_range(-6.0, 6.0), 0.0), rng, true)

	# 3. FRAME — a continuous treeline hugging each border.
	var fx: float = half.x + FRAME_MARGIN
	var fy: float = half.y + FRAME_MARGIN
	var x: float = -half.x
	while x <= half.x:
		_frame_tree(root, Vector2(x, -fy), gate_positions, half, rng)
		_frame_tree(root, Vector2(x,  fy), gate_positions, half, rng)
		x += FRAME_STEP
	var y: float = -half.y
	while y <= half.y:
		_frame_tree(root, Vector2(-fx, y), gate_positions, half, rng)
		_frame_tree(root, Vector2( fx, y), gate_positions, half, rng)
		y += FRAME_STEP

	# 4. DIVIDER TREES — when two gates share the same wall (e.g. two north exits),
	#    force-plant a dense tree column in the gap between them so each exit reads
	#    as a separate corridor, not one merged opening.
	_plant_gate_dividers(root, gate_positions, half, rng)
	return root


# A single forest-fill tree (size-varied, no shadow → cheap; many placed).
static func _forest_tree(root: Node2D, pos: Vector2, rng: RandomNumberGenerator,
		overhead: bool) -> void:
	var nm: String
	var hc: float
	if rng.randf() < 0.70:
		nm = _pick(TREE_BIG, rng); hc = rng.randf_range(3.0, 3.8)
	else:
		nm = _pick(TREE_MID, rng); hc = rng.randf_range(2.4, 3.1)
	_place_tree(root, nm, pos, hc, rng, overhead, false)


# One frame tree at a border position unless it sits in the gate doorway lane.
static func _frame_tree(root: Node2D, pos: Vector2, gate_positions: Array,
		half: Vector2, rng: RandomNumberGenerator) -> void:
	if _in_gate_lane(pos, gate_positions, half):
		return
	var jitter := Vector2(rng.randf_range(-8.0, 8.0), rng.randf_range(-6.0, 6.0))
	var nm: String = _pick(TREE_BIG, rng) if rng.randf() < 0.75 else _pick(TREE_MID, rng)
	_place_tree(root, nm, pos + jitter, rng.randf_range(FRAME_H_MIN, FRAME_H_MAX), rng, true)


# True when pos lies in a gate's exit corridor.
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


# Cardinal outward normal for a gate.
static func _gate_outward(g: Vector2, half: Vector2) -> Vector2:
	var dx: float = half.x - absf(g.x)
	var dy: float = half.y - absf(g.y)
	if dx <= dy:
		return Vector2(signf(g.x), 0.0)
	return Vector2(0.0, signf(g.y))


# ---------------------------------------------------------------------------
# Divider trees between adjacent same-wall gates.
# ---------------------------------------------------------------------------
# Groups gates by which wall they sit on (N/S/E/W), sorts them along the wall,
# then plants a short column of trees at the midpoint between each adjacent pair.
static func _plant_gate_dividers(root: Node2D, gates: Array, half: Vector2,
		rng: RandomNumberGenerator) -> void:
	if gates.size() < 2:
		return
	# Bucket gates by wall: "N", "S", "E", "W".
	var buckets: Dictionary = { "N": [], "S": [], "E": [], "W": [] }
	for g in gates:
		var gv: Vector2 = g as Vector2
		var dx: float = half.x - absf(gv.x)
		var dy: float = half.y - absf(gv.y)
		if dy <= dx:
			buckets["N" if gv.y < 0.0 else "S"].append(gv)
		else:
			buckets["W" if gv.x < 0.0 else "E"].append(gv)
	for wall in buckets:
		var wgates: Array = buckets[wall]
		if wgates.size() < 2:
			continue
		# Sort along the wall axis (X for N/S walls, Y for E/W walls).
		var horiz: bool = wall == "N" or wall == "S"
		if horiz:
			wgates.sort_custom(func(a, b): return a.x < b.x)
		else:
			wgates.sort_custom(func(a, b): return a.y < b.y)
		# Plant divider column between each adjacent pair.
		for i in range(wgates.size() - 1):
			var a: Vector2 = wgates[i]
			var b: Vector2 = wgates[i + 1]
			var mid: Vector2 = (a + b) * 0.5
			var outw: Vector2 = _gate_outward(mid, half)
			# Trees run perpendicular to the wall, from slightly inside the border
			# out into the forest, forming a visible wall of trees between the two exits.
			for t in range(DIVIDER_TREES):
				var frac: float = float(t) / float(DIVIDER_TREES - 1) if DIVIDER_TREES > 1 else 0.5
				var depth: float = lerpf(-GATE_LANE_BACK * 0.6, FOREST_DEPTH * 0.4, frac)
				var pos: Vector2 = mid + outw * depth
				pos += Vector2(rng.randf_range(-10.0, 10.0), rng.randf_range(-10.0, 10.0))
				_forest_tree(root, pos, rng, true)


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


# True when any floor cell is within `radius` cells (Chebyshev distance).
# Used to keep big forest-frame trees from visually encroaching into the arena.
static func _near_floor(layout: RefCounted, ci: int, cj: int, radius: int) -> bool:
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if dx == 0 and dy == 0:
				continue
			var v: int = layout.val(ci + dx, cj + dy)
			if v == 1 or v == 3:
				return true
	return false


# Place an obstacle at base unless its foot-circle overlaps an existing prop.
static func _try_obstacle(root: Node2D, placed: Array, pname: String, base: Vector2,
		height_cells: float, rng: RandomNumberGenerator, tall: bool) -> bool:
	var tex: ImageTexture = _prop_tex(pname)
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


# Big interior tree — uses a wide exclusion radius so nothing else spawns
# under the canopy.  Placed FIRST so rocks/vines defer to the tree.
static func _try_big_tree(root: Node2D, placed: Array, pname: String, base: Vector2,
		height_cells: float, rng: RandomNumberGenerator) -> bool:
	var tex: ImageTexture = _prop_tex(pname)
	if tex == null:
		return false
	var draw_h: float = WORLD_CELL * height_cells
	var draw_w: float = float(tex.get_width()) * (draw_h / float(tex.get_height()))
	# Visual canopy radius — wider than the normal foot-circle so rocks/vines
	# won't spawn underneath the tree sprite.
	var canopy_r: float = draw_w * 0.55
	for p in placed:
		if base.distance_to(p["c"]) < canopy_r + p["r"]:
			return false
	_add_prop_tex(root, tex, base, height_cells, rng, int(WORLD_CELL * 0.10), true, true)
	# Attach a dashable_barrier collider so the player can't walk through but
	# CAN dash through, matching all other biome interior barrier behaviour.
	var sink: float = float(int(WORLD_CELL * 0.10))
	var feet_y: float = base.y + sink
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.add_to_group("dashable_barrier")
	var cs := CollisionShape2D.new()
	var sh := RectangleShape2D.new()
	# Trunk-sized collision box anchored at the BASE of the tree so heroes
	# can't walk into the trunk from below.  Narrower than canopy.
	var trunk_h: float = maxf(12.0, draw_h * 0.22)
	sh.size = Vector2(maxf(10.0, draw_w * 0.30), trunk_h)
	cs.shape = sh
	cs.position = Vector2(base.x, feet_y - trunk_h * 0.5)
	body.add_child(cs)
	root.add_child(body)
	placed.append({ "c": base, "r": canopy_r, "tree": true })
	return true


# Coverage-pass rock: always places SOMETHING on a bare collidable cell.
static func _fit_rock(root: Node2D, placed: Array, pname: String, base: Vector2,
		rng: RandomNumberGenerator) -> bool:
	var tex: ImageTexture = _prop_tex(pname)
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


static func _place_tree(root: Node2D, pname: String, base: Vector2, height_cells: float,
		rng: RandomNumberGenerator, _overhead: bool, with_shadow: bool = true) -> void:
	var tex: ImageTexture = _prop_tex(pname)
	if tex == null:
		return
	var th: float = float(tex.get_height())
	var tw: float = float(tex.get_width())
	var sc: float = (WORLD_CELL * height_cells) / th
	var draw_h: float = th * sc
	var draw_w: float = tw * sc
	var sink: float = float(int(WORLD_CELL * 0.06))
	var feet: Vector2 = base + Vector2(0.0, sink)
	# Wrap in a Node2D at feet so parent y_sort orders trees by depth
	# (lower Y = farther, higher Y = closer/drawn on top).
	var wrap := Node2D.new()
	wrap.position = feet
	root.add_child(wrap)
	if with_shadow:
		var stex: ImageTexture = _shadow_texture()
		var sh := Sprite2D.new()
		sh.texture = stex
		sh.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		var sh_w: float = draw_w * 0.6
		var sh_h: float = maxf(6.0, sh_w * 0.4)
		sh.scale = Vector2(sh_w / float(stex.get_width()), sh_h / float(stex.get_height()))
		sh.position = Vector2.ZERO
		wrap.add_child(sh)
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	spr.scale = Vector2(sc, sc)
	spr.position = Vector2(0.0, -draw_h * 0.5)
	wrap.add_child(spr)


# Flat, run-over decor (no collision, no overhead).
static func _add_decor(root: Node2D, pname: String, base: Vector2, height_cells: float,
		rng: RandomNumberGenerator) -> void:
	var tex: ImageTexture = _prop_tex(pname)
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


# Feet-anchored prop + soft contact shadow. Barriers/accents ride overhead.
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
