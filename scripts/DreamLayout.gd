extends RefCounted

# ============================================================
# DreamLayout.gd — Run 87 (2026-06-18) — open-arena barrier layouts
# ============================================================
# REWRITE of the Run 51 carve-from-void model, which produced narrow,
# hallway-like rooms with lots of dead collision. New philosophy
# (Hades-style): the arena is MOSTLY OPEN FLOOR, and we drop INTERIOR
# BARRIER walls with staggered openings to carve winding, zig-zagging,
# INTERCONNECTED routes through it.
#   * Start all-floor → place barrier "slats" on a broken lattice. Each
#     slat leaves 1-3 gaps, staggered against its neighbours so you weave
#     (zig-zag) and can loop back — multiple routes, no single corridor.
#   * A few short stub walls add small dead-end pockets / alcoves (cover).
#   * Scattered single-cell boulders give extra cover in the open.
#   * Optional river (biome chance) with explicit plank bridges.
#   * Central CHAMBER + hero ENTRY + every GATE are force-cleared so the
#     boon/boss drop at the room origin and the doorways are always open.
#   * Connectivity is GUARANTEED: entry reaches the chamber and every
#     gate; any sizable sealed region gets a tunnel punched to it (small
#     pockets stay sealed — the ninja DASH phases through inner barriers).
#
# Every blocked cell here is an INTERIOR barrier (the arena's outer bound
# is DreamRoom's wall ring), so the dash can phase through ALL of them
# without letting a hero leave the arena.
#
# Grid: 32px cells. Cell values (UNCHANGED — external contract):
#   V_VOID   barrier (blocked; rendered as a clear rock wall, dashable)
#   V_FLOOR  walkable ground
#   V_WATER  river (blocked)
#   V_BRIDGE walkable planks over water
#
# Deterministic per seed. Consumers (API unchanged):
#   DreamRoom.gd / DreamTerrain.gd / *Tileset.gd / DreamSpawner.gd
# ============================================================

const CELL: float = 32.0
const V_VOID: int = 0
const V_FLOOR: int = 1
const V_WATER: int = 2
const V_BRIDGE: int = 3

# Barrier tuning.
const BARRIER_LINE_CHANCE: float = 0.54   # odds a lattice line becomes a wall slat (Run 96: fewer walls → less chaotic)
const GAP_W: int = 3                       # opening width in cells (96px — Run 96: wider, comfier corridors)
const ORPHAN_MIN: int = 5                  # sealed floor regions >= this get reconnected

# Trap open-space tuning (Run 96). A trap only spawns where a clear walkable disc
# of at least TRAP_OPEN_MIN cells radius exists; the measured radius (capped at
# TRAP_OPEN_MAX) sizes the poison pool so it always fits the open floor.
const TRAP_OPEN_MIN: int = 2               # min clear radius (cells) around a trap → ~5-wide pocket
const TRAP_OPEN_MAX: int = 3               # cap when measuring (pool maxes out by here)

var gw: int = 0
var gh: int = 0
var half: Vector2 = Vector2.ZERO
var cells: PackedByteArray = PackedByteArray()
var path_set: Dictionary = {}          # legacy (unused) — kept for API stability
var entry_cell: Vector2i = Vector2i.ZERO
var chamber_cell: Vector2i = Vector2i.ZERO
var trap_spots: Array = []             # {pos, type, visual, name, pool_radius, pool_wob}
var rock_spots: Array = []             # Vector2i cells — boulders inside the walk space
var gate_cells: Array = []             # Vector2i cells at each gate (keep-clear)
# Run 92: FROSTPEAK ice biome. When true, V_WATER cells are FROZEN ICE —
# walkable (no bridges) but slippery (IceField + hero ice-glide). Rivers AND
# scattered lakes/puddles are carved as ice. Off for every other biome (their
# water stays an impassable river with plank bridges).
var ice_biome: bool = false
var _rng := RandomNumberGenerator.new()


func generate(p_half: Vector2, exit_dir: Vector2, seed_val: int, room: int,
		biome: Dictionary, gate_positions: Array, tier: int = 1,
		biome_id: String = "") -> void:
	half = p_half
	ice_biome = (biome_id == "peaks")
	_rng.seed = seed_val
	gw = max(10, int(round(half.x * 2.0 / CELL)))
	gh = max(8, int(round(half.y * 2.0 / CELL)))
	cells = PackedByteArray()
	cells.resize(gw * gh)
	path_set.clear()
	trap_spots.clear()
	rock_spots.clear()
	gate_cells.clear()

	# 0. Start fully OPEN — most of the arena is usable floor.
	for i in range(gw * gh):
		cells[i] = V_FLOOR

	chamber_cell = _clamp_cell(Vector2i(gw / 2, gh / 2), 1)
	entry_cell = _edge_cell(-exit_dir)
	for gp in gate_positions:
		gate_cells.append(_clamp_cell(world_to_cell(gp), 0))

	# 1. Interior barrier slats — the winding, interconnected route maker.
	_build_barriers()

	# 1b. Open PLAZAS — clear a handful of rooms so the route reads hallway → open
	# space → hallway instead of one uniform lattice (Run 99: cleaner, less chaotic).
	_carve_plazas()

	# 2. Water. FROSTPEAK: frozen rivers + scattered ice lakes/puddles (walkable
	# but slippery, no bridges). Every other biome: an impassable river with
	# plank bridges, gated on the biome's river_chance.
	if ice_biome:
		if _rng.randf() < 0.70 and room < 8:
			_carve_river(exit_dir, gate_positions)
		if room != 4 and room < 8:
			_carve_ice_lakes()
			_scatter_ice_puddles()
	elif _rng.randf() < float(biome.get("river_chance", 0.0)) and room < 8:
		_carve_river(exit_dir, gate_positions)

	# 3. Short stub walls → small dead-end pockets / alcoves for cover.
	_add_stub_pockets()

	# 4. Scattered single-cell boulders (cover in the open; dashable).
	_scatter_boulders()

	# 5. Force-clear the chamber, hero entry, and every gate doorway.
	var chamber_r: int = 5 if (room == 4 or room >= 8) else 4
	_clear_disc(chamber_cell, chamber_r)
	_clear_disc(entry_cell, 3)
	for gc in gate_cells:
		_clear_disc(gc as Vector2i, 3)

	# 6. Guarantee navigation: entry → chamber → every gate, plus reconnect
	# any sizable sealed region (small pockets stay sealed for the dash).
	_ensure_connectivity()

	# 7. Traps — scattered across OPEN pockets, spread far apart. Count scales
	# with run TIER (1-indexed; cake finale = tier 6).
	_place_traps(biome, tier)


# ---------------------------------------------------------------------------
# Run 118 — DAYTIME pass (DayBiomeRoom). The waking-world biome visits reuse
# this layout + the night tilesets so the day and night versions of a biome
# match visually, but day rooms are RELATIVELY OPEN: the barrier lattice and
# stub pockets are stripped down to scattered natural obstacles (lone rocks +
# small 2-3 cell stands the tilesets dress as trees/crystals/boulders), hazard
# pools are dropped (day is safe — no TrapZones spawn), water/ice stays, and
# the cottage yards + return-gate approach are force-cleared. Call AFTER
# generate().
# ---------------------------------------------------------------------------
func make_day_open(clear_spots: Array = [], clear_r: int = 5) -> void:
	# 1. Strip the combat lattice: every interior barrier goes back to floor
	# except the lone scatter boulders (they already sit in open pockets).
	var keep: Dictionary = {}
	for kc in rock_spots:
		keep[kc as Vector2i] = true
	for cj in range(gh):
		for ci in range(gw):
			var c0 := Vector2i(ci, cj)
			if _val_c(c0) == V_VOID and not keep.has(c0):
				_set_c(c0, V_FLOOR)

	# 2. Day rooms are safe by design — no hazard pools. This also stops the
	# swamp/caverns liquid bakers from laying poison/lava POOLS on the open
	# floor; their RIVERS still render from the V_WATER cells.
	trap_spots.clear()

	# 3. Scatter a few extra natural obstacle stands so the open field doesn't
	# read empty. Guarded like the night boulders: only in a genuinely open
	# radius-2 disc, spaced apart, away from doorways/chamber and the clear
	# spots — they can never pinch a path.
	var want: int = clampi(gw * gh / 90, 6, 12)
	var placed: Array = rock_spots.duplicate()
	var tries: int = 0
	while placed.size() < want and tries < 220:
		tries += 1
		var c := Vector2i(_rng.randi_range(3, gw - 4), _rng.randi_range(3, gh - 4))
		if _val_c(c) != V_FLOOR or _too_close_to_key(c, 4) or _open_radius(c, 2) < 2:
			continue
		var ok: bool = true
		for p in placed:
			if Vector2(c - (p as Vector2i)).length() < 6.0:
				ok = false
				break
		if ok:
			for sp in clear_spots:
				if Vector2(c - world_to_cell(sp as Vector2)).length() < float(clear_r + 3):
					ok = false
					break
		if not ok:
			continue
		placed.append(c)
		_set_c(c, V_VOID)
		rock_spots.append(c)
		# ~half become small 2-3 cell stands (tree clumps / rock formations).
		if _rng.randf() < 0.55:
			var offs: Array = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
			for _k in range(_rng.randi_range(1, 2)):
				var cn: Vector2i = c + (offs[_rng.randi() % offs.size()] as Vector2i)
				if _in_grid(cn) and _val_c(cn) == V_FLOOR and not _too_close_to_key(cn, 4):
					_set_c(cn, V_VOID)

	# 4. Force-clear the cottage yards + return-gate approach.
	for sp2 in clear_spots:
		_clear_disc(_clamp_cell(world_to_cell(sp2 as Vector2), 1), clear_r)

	# 5. Prune rock_spots a clear disc flattened (consumers draw boulder art
	# from this list — it must only name cells that are still blocked).
	var still: Array = []
	for rc in rock_spots:
		if _val_c(rc as Vector2i) == V_VOID:
			still.append(rc)
	rock_spots = still


# ---------------------------------------------------------------------------
# Barrier construction
# ---------------------------------------------------------------------------

# Broken lattice of wall "slats". Vertical + horizontal lines on a jittered
# grid; each kept line is a partial run with staggered gaps so adjacent lines'
# openings don't align — you weave through, loop around, and double back.
func _build_barriers() -> void:
	var block: int = _rng.randi_range(5, 6)
	var x: int = block
	while x < gw - 3:
		if _rng.randf() < BARRIER_LINE_CHANCE:
			_barrier_line(true, x)
		x += block + _rng.randi_range(-1, 1)
	var y: int = block
	while y < gh - 3:
		if _rng.randf() < BARRIER_LINE_CHANCE:
			_barrier_line(false, y)
		y += block + _rng.randi_range(-1, 1)


# A few open PLAZAS — clear rooms the corridors open into, so the route reads as
# hallway → open space → hallway instead of one uniform lattice. The central chamber
# is already a plaza; these add a handful more, spaced apart and kept off the doorways.
# Carved AFTER the slats so they punch clean rooms through the barrier lattice; the
# connectivity pass later guarantees every plaza is reachable.
func _carve_plazas() -> void:
	var n: int = clampi(int(gw * gh / 230), 1, 3)
	var centers: Array = [chamber_cell]
	var tries: int = 0
	while centers.size() < n + 1 and tries < 60:
		tries += 1
		var c0 := Vector2i(_rng.randi_range(4, gw - 5), _rng.randi_range(4, gh - 5))
		if _too_close_to_key(c0, 5):
			continue
		var ok: bool = true
		for p in centers:
			if Vector2(c0 - (p as Vector2i)).length() < 7.0:
				ok = false
				break
		if not ok:
			continue
		centers.append(c0)
		_clear_disc(c0, _rng.randi_range(2, 3))


# One wall slat along a lattice line. `vertical` → line runs N/S at column
# `pos`; else runs E/W at row `pos`. The run may be partial (leaves open
# space), wanders ±1 for an organic edge, and is punctured by GAP_W openings.
func _barrier_line(vertical: bool, pos: int) -> void:
	var span_hi: int = (gh - 3) if vertical else (gw - 3)
	var span_lo: int = 2
	var a: int = span_lo
	var b: int = span_hi
	if _rng.randf() < 0.40 and span_hi - span_lo > 6:
		var seg: int = _rng.randi_range(5, span_hi - span_lo)
		a = _rng.randi_range(span_lo, max(span_lo, span_hi - seg))
		b = min(span_hi, a + seg)

	var run_len: int = b - a
	# Run 99: fewer openings → each slat reads as a clean wall with a clear doorway,
	# not a dashed line. Connectivity pass still guarantees the room is navigable.
	var gaps: int = clampi(int(run_len / 8), 1, 2)
	var gap_centers: Array = []
	for _gi in range(gaps):
		gap_centers.append(_rng.randi_range(a + 1, max(a + 1, b - 1)))

	var cross_limit: int = (gw - 2) if vertical else (gh - 2)
	var cross: int = pos
	for t in range(a, b + 1):
		# Run 99: much less wander (0.18 → 0.05) so walls are clean straight lines —
		# corridors read clearly. A rare single-cell jog keeps it from feeling tiled.
		if _rng.randf() < 0.05:
			cross = clampi(cross + _rng.randi_range(-1, 1), 1, cross_limit)
		var in_gap: bool = false
		for c in gap_centers:
			if t >= int(c) and t < int(c) + GAP_W:
				in_gap = true
				break
		if in_gap:
			continue
		var cell: Vector2i = Vector2i(cross, t) if vertical else Vector2i(t, cross)
		_set_c(cell, V_VOID)


# Short stub walls jutting off into the open → little alcoves / dead-end
# pockets. The connectivity pass never seals these (they keep an opening),
# it only reconnects fully-walled-off regions.
func _add_stub_pockets() -> void:
	var n: int = clampi(int(gw * gh / 240), 0, 2)   # Run 99: fewer dead-end stubs → less clutter
	for _i in range(n):
		var cx: int = _rng.randi_range(4, gw - 5)
		var cy: int = _rng.randi_range(4, gh - 5)
		var c0 := Vector2i(cx, cy)
		if _too_close_to_key(c0, 4):
			continue
		var vertical: bool = _rng.randf() < 0.5
		var seg: int = _rng.randi_range(3, 5)
		for t in range(seg):
			_set_c(c0 + (Vector2i(0, t) if vertical else Vector2i(t, 0)), V_VOID)
		# 60%: add a short perpendicular cap → an L / C-shaped cul-de-sac.
		if _rng.randf() < 0.6:
			var corner: Vector2i = c0 + (Vector2i(0, seg - 1) if vertical else Vector2i(seg - 1, 0))
			for t2 in range(1, 3):
				_set_c(corner + (Vector2i(t2, 0) if vertical else Vector2i(0, t2)), V_VOID)


# Lone boulders for cover — Run 99: only in GENUINELY OPEN spots (a clear disc of
# radius 2, i.e. a ~5-wide pocket), never in or beside a corridor, and fewer of them.
func _scatter_boulders() -> void:
	var tries: int = gw * gh / 80       # Run 99: fewer lone boulders → cleaner open floor
	for _i in range(tries):
		var c := Vector2i(_rng.randi_range(2, gw - 3), _rng.randi_range(2, gh - 3))
		if _val_c(c) != V_FLOOR or _too_close_to_key(c, 3):
			continue
		# Require an open disc of radius 2 around it so a boulder only sits in a plaza /
		# open pocket — it can never pinch a hallway.
		if _open_radius(c, 2) < 2:
			continue
		_set_c(c, V_VOID)
		rock_spots.append(c)


# ---------------------------------------------------------------------------
# River (optional) + bridges
# ---------------------------------------------------------------------------

func _carve_river(exit_dir: Vector2, gate_positions: Array) -> void:
	var keep_dry: Array = [entry_cell, chamber_cell]
	for gp in gate_positions:
		keep_dry.append(_clamp_cell(world_to_cell(gp), 0))
	var horizontal: bool = abs(exit_dir.y) >= abs(exit_dir.x)   # river spans E/W
	if horizontal:
		var y: float = float(_rng.randi_range(gh / 4, gh * 3 / 4))
		for x in range(gw):
			y = clampf(y + _rng.randf_range(-0.6, 0.6), 2.0, float(gh - 3))
			for dy in range(0, 2):
				_river_cell(Vector2i(x, int(y) + dy), keep_dry)
	else:
		var x2: float = float(_rng.randi_range(gw / 4, gw * 3 / 4))
		for y2 in range(gh):
			x2 = clampf(x2 + _rng.randf_range(-0.6, 0.6), 2.0, float(gw - 3))
			for dx in range(0, 2):
				_river_cell(Vector2i(int(x2) + dx, y2), keep_dry)
	# Frozen ice rivers are walkable — no plank bridges needed.
	if not ice_biome:
		_add_river_bridges(horizontal)


# FROSTPEAK only — scatter a few frozen lakes / large puddles across the open
# floor. They're blobs of V_WATER (= walkable ice), kept clear of the entry,
# chamber and gate doorways so spawns/exits never land mid-lake.
func _carve_ice_lakes() -> void:
	var n: int = _rng.randi_range(2, 4)
	var placed: Array = []
	var tries: int = 0
	while placed.size() < n and tries < 40:
		tries += 1
		var cx: int = _rng.randi_range(3, gw - 4)
		var cy: int = _rng.randi_range(3, gh - 4)
		var c0 := Vector2i(cx, cy)
		if _too_close_to_key(c0, 4):
			continue
		var ok: bool = true
		for p in placed:
			if Vector2(c0 - (p as Vector2i)).length() < 6.0:
				ok = false
				break
		if not ok:
			continue
		placed.append(c0)
		var rx: float = _rng.randf_range(2.0, 3.4)
		var ry: float = rx * _rng.randf_range(0.7, 1.1)
		var wob: float = _rng.randf_range(0.0, TAU)
		var rmax: int = int(ceil(maxf(rx, ry))) + 1
		for dy in range(-rmax, rmax + 1):
			for dx in range(-rmax, rmax + 1):
				var ang: float = atan2(float(dy), float(dx))
				var edge: float = 1.0 + 0.18 * sin(3.0 * ang + wob)
				var dd: float = pow(float(dx) / (rx * edge), 2.0) + pow(float(dy) / (ry * edge), 2.0)
				if dd > 1.0:
					continue
				var c := c0 + Vector2i(dx, dy)
				if _too_close_to_key(c, 3):
					continue
				if _val_c(c) == V_FLOOR:
					_set_c(c, V_WATER)


# FROSTPEAK only — a few LONE single-cell frozen puddles (sparingly). Each is an
# isolated V_WATER cell (no water neighbour) so the baker renders it with the
# circular puddle tile; still walkable + slippery like the lakes.
func _scatter_ice_puddles() -> void:
	var n: int = _rng.randi_range(1, 3)
	var placed: int = 0
	var tries: int = 0
	while placed < n and tries < 50:
		tries += 1
		var c := Vector2i(_rng.randi_range(2, gw - 3), _rng.randi_range(2, gh - 3))
		if _val_c(c) != V_FLOOR or _too_close_to_key(c, 3):
			continue
		# Must be fully surrounded by non-water so it stays a lone puddle.
		var clean: bool = true
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if _val_c(c + Vector2i(dx, dy)) == V_WATER:
					clean = false
					break
			if not clean:
				break
		if not clean:
			continue
		_set_c(c, V_WATER)
		placed += 1


func _river_cell(c: Vector2i, keep_dry: Array) -> void:
	if not _in_grid(c):
		return
	for k in keep_dry:
		if Vector2(c - (k as Vector2i)).length() < 3.0:
			return
	_set_c(c, V_WATER)


# Lay 2-3 plank crossings, spread along the river, each GAP_W cells wide.
func _add_river_bridges(horizontal: bool) -> void:
	var axis_len: int = gw if horizontal else gh
	var n: int = _rng.randi_range(2, 3)
	var bands: Array = []
	for i in range(n):
		var frac: float = float(i + 1) / float(n + 1)
		bands.append(clampi(int(frac * float(axis_len)) + _rng.randi_range(-2, 2), 3, axis_len - 4))
	for cj in range(gh):
		for ci in range(gw):
			if _val_c(Vector2i(ci, cj)) != V_WATER:
				continue
			var ac: int = ci if horizontal else cj
			for bc in bands:
				if ac >= int(bc) and ac < int(bc) + GAP_W:
					_set_c(Vector2i(ci, cj), V_BRIDGE)
					break


# ---------------------------------------------------------------------------
# Protection + connectivity
# ---------------------------------------------------------------------------

func _clear_disc(c: Vector2i, r: int) -> void:
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dy * dy <= r * r + 1:
				_set_c(c + Vector2i(dx, dy), V_FLOOR)


func _too_close_to_key(c: Vector2i, d: int) -> bool:
	if Vector2(c - chamber_cell).length() < float(d) or Vector2(c - entry_cell).length() < float(d):
		return true
	for gc in gate_cells:
		if Vector2(c - (gc as Vector2i)).length() < float(d):
			return true
	return false


# Entry must reach the chamber and every gate; sizable sealed regions get a
# tunnel punched to the chamber. Small pockets stay sealed (dash-only).
func _ensure_connectivity() -> void:
	if not _flood(entry_cell).has(chamber_cell):
		_carve_tunnel(entry_cell, chamber_cell)
	for gc in gate_cells:
		if not _flood(entry_cell).has(gc as Vector2i):
			_carve_tunnel(gc as Vector2i, chamber_cell)

	var reach: Dictionary = _flood(entry_cell)
	var visited: Dictionary = {}
	for cj in range(gh):
		for ci in range(gw):
			var c := Vector2i(ci, cj)
			if not _walkable_c(c) or reach.has(c) or visited.has(c):
				continue
			var region: Array = _region_of(c, visited)
			if region.size() >= ORPHAN_MIN:
				_carve_tunnel(region[region.size() / 2] as Vector2i, chamber_cell)


# Flood fill of walkable cells from `start`. Returns a Dictionary set.
func _flood(start: Vector2i) -> Dictionary:
	var seen: Dictionary = {}
	if not _walkable_c(start):
		# Nudge to the nearest walkable cell so the fill has a seed.
		start = _nearest_walkable(start)
		if not _walkable_c(start):
			return seen
	var st: Array = [start]
	seen[start] = true
	while not st.is_empty():
		var q: Vector2i = st.pop_back()
		for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = q + off
			if _in_grid(n) and not seen.has(n) and _walkable_c(n):
				seen[n] = true
				st.append(n)
	return seen


func _region_of(start: Vector2i, visited: Dictionary) -> Array:
	var out: Array = []
	var st: Array = [start]
	visited[start] = true
	while not st.is_empty():
		var q: Vector2i = st.pop_back()
		out.append(q)
		for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = q + off
			if _in_grid(n) and not visited.has(n) and _walkable_c(n):
				visited[n] = true
				st.append(n)
	return out


func _nearest_walkable(c: Vector2i) -> Vector2i:
	for r in range(1, max(gw, gh)):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if abs(dx) != r and abs(dy) != r:
					continue
				var n: Vector2i = c + Vector2i(dx, dy)
				if _in_grid(n) and _walkable_c(n):
					return n
	return c


# Carve a 2-wide floor tunnel from a → b (used only to fix connectivity).
func _carve_tunnel(a: Vector2i, b: Vector2i) -> void:
	var cur := Vector2(a)
	var target := Vector2(b)
	var guard: int = gw * gh
	while cur.distance_to(target) > 1.0 and guard > 0:
		guard -= 1
		cur += (target - cur).normalized()
		var cc := Vector2i(int(round(cur.x)), int(round(cur.y)))
		if not _walkable_c(cc):
			_set_c(cc, V_FLOOR)
		var side := cc + Vector2i(1, 0)
		if _in_grid(side) and not _walkable_c(side):
			_set_c(side, V_FLOOR)


# ---------------------------------------------------------------------------
# Traps (carried over from Run 51 — scattered, well-spread)
# ---------------------------------------------------------------------------

func _place_traps(biome: Dictionary, tier: int) -> void:
	var tdefs: Array = biome.get("traps", [])
	if tdefs.is_empty():
		return
	var want: int
	if tier <= 2:
		want = _rng.randi_range(1, 2)
	elif tier <= 4:
		want = _rng.randi_range(2, 3)
	else:
		want = _rng.randi_range(3, 5)

	# Candidates: open FLOOR sitting in a GENUINELY OPEN pocket. Run 96: a trap
	# must have a clear walkable disc of radius >= TRAP_OPEN_MIN around it (not just
	# its 8 neighbours) so a poison pool is never boxed into a tiny space hemmed by
	# walls one cell out. The measured open radius is carried along so the pool can
	# be SIZED to fit — bigger pools in open arenas, smaller poison in tight spots.
	var cands: Array = []
	for cy in range(1, gh - 1):
		for cx in range(1, gw - 1):
			var c2 := Vector2i(cx, cy)
			if _val_c(c2) != V_FLOOR:
				continue
			var orad: int = _open_radius(c2, TRAP_OPEN_MAX)
			if orad < TRAP_OPEN_MIN:
				continue
			if Vector2(c2 - entry_cell).length() < 5.0:
				continue
			if Vector2(c2 - chamber_cell).length() < 4.0:
				continue
			var near_gate: bool = false
			for gc2 in gate_cells:
				if Vector2(c2 - (gc2 as Vector2i)).length() < 5.0:
					near_gate = true
					break
			if near_gate:
				continue
			cands.append({"pos": cell_to_world(c2), "open": orad})

	var min_space: float = maxf(170.0, minf(half.x, half.y) * 0.5)
	var floor_space: float = 150.0
	while trap_spots.size() < want and not cands.is_empty():
		if trap_spots.is_empty():
			var fi: int = _rng.randi() % cands.size()
			_commit_trap(cands[fi].pos, tdefs, int(cands[fi].open))
			cands.remove_at(fi)
			continue
		var eligible: Array = []
		for idx in range(cands.size()):
			var wp0: Vector2 = cands[idx].pos
			var ok: bool = true
			for t in trap_spots:
				if (t.pos as Vector2).distance_to(wp0) < min_space:
					ok = false
					break
			if ok:
				eligible.append(idx)
		if eligible.is_empty():
			if min_space <= floor_space:
				break
			min_space = maxf(floor_space, min_space * 0.8)
			continue
		var pick: int = eligible[_rng.randi() % eligible.size()]
		_commit_trap(cands[pick].pos, tdefs, int(cands[pick].open))
		cands.remove_at(pick)


# Largest radius r (1..max_r, cells) for which every cell in the disc around c is
# walkable. 0 means even the immediate ring is blocked. Used to gate + size traps.
func _open_radius(c: Vector2i, max_r: int) -> int:
	var best: int = 0
	for r in range(1, max_r + 1):
		var all_open: bool = true
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if dx * dx + dy * dy > r * r + 1:
					continue
				if not _walkable_c(c + Vector2i(dx, dy)):
					all_open = false
					break
			if not all_open:
				break
		if not all_open:
			break
		best = r
	return best


func _commit_trap(wp: Vector2, tdefs: Array, open_cells: int = 2) -> void:
	var td: Dictionary = tdefs[_rng.randi() % tdefs.size()]
	# Size the pool to fit the measured open disc: keep it inside the clear floor
	# (smaller in tight pockets, full-size in open arenas) so it never overlaps walls.
	var max_pr: float = (float(open_cells) - 0.35) * CELL
	var pool_r: float = clampf(_rng.randf_range(48.0, 64.0), 40.0, max_pr)
	trap_spots.append({"pos": wp, "type": String(td.get("type", "slow")),
		"visual": String(td.get("visual", "brine")), "name": String(td.get("name", "Trap")),
		"pool_radius": pool_r,
		"pool_wob": [
			_rng.randf_range(0.12, 0.26), _rng.randf_range(0.06, 0.16),
			_rng.randf_range(0.04, 0.10), _rng.randf_range(0.0, TAU),
			_rng.randf_range(0.0, TAU), _rng.randf_range(0.0, TAU)]})


# ---------------------------------------------------------------------------
# Queries (for DreamRoom / DreamTerrain / *Tileset / DreamSpawner) — UNCHANGED
# ---------------------------------------------------------------------------

func val(x: int, y: int) -> int:
	if x < 0 or x >= gw or y < 0 or y >= gh:
		return V_VOID
	return cells[y * gw + x]


func cell_to_world(c: Vector2i) -> Vector2:
	return Vector2((float(c.x) + 0.5) * CELL - half.x, (float(c.y) + 0.5) * CELL - half.y)


func world_to_cell(p: Vector2) -> Vector2i:
	return Vector2i(int(floor((p.x + half.x) / CELL)), int(floor((p.y + half.y) / CELL)))


func entry_world() -> Vector2:
	return cell_to_world(entry_cell)


func chamber_world() -> Vector2:
	return cell_to_world(chamber_cell)


func is_walkable_world(p: Vector2) -> bool:
	return _walkable_c(world_to_cell(p))


func random_walkable(min_dist: float) -> Vector2:
	for _i in range(90):
		var c := Vector2i(_rng.randi_range(1, gw - 2), _rng.randi_range(1, gh - 2))
		if not _walkable_c(c):
			continue
		if Vector2(c - entry_cell).length() * CELL < min_dist:
			continue
		return cell_to_world(c) + Vector2(_rng.randf_range(-8, 8), _rng.randf_range(-8, 8))
	return chamber_world()


# Horizontal runs of ANY blocked cell (void + water) merged into collision rects.
func blocked_runs() -> Array:
	var runs: Array = []
	for y in range(gh):
		var x: int = 0
		while x < gw:
			if _walkable_c(Vector2i(x, y)):
				x += 1
				continue
			var start: int = x
			while x < gw and not _walkable_c(Vector2i(x, y)):
				x += 1
			var n: int = x - start
			runs.append({
				"pos": Vector2((float(start) + float(n) * 0.5) * CELL - half.x, (float(y) + 0.5) * CELL - half.y),
				"size": Vector2(float(n) * CELL, CELL),
			})
	return runs


# Horizontal runs of ONLY V_WATER cells — used to build a SEPARATE collision
# body tagged "water_collider" so ranged shots can fly over rivers while heroes
# and enemies are still blocked from walking across.
func water_runs() -> Array:
	var runs: Array = []
	for y in range(gh):
		var x: int = 0
		while x < gw:
			if _val_c(Vector2i(x, y)) != V_WATER:
				x += 1
				continue
			var start: int = x
			while x < gw and _val_c(Vector2i(x, y)) == V_WATER:
				x += 1
			var n: int = x - start
			runs.append({
				"pos": Vector2((float(start) + float(n) * 0.5) * CELL - half.x, (float(y) + 0.5) * CELL - half.y),
				"size": Vector2(float(n) * CELL, CELL),
			})
	return runs


# Horizontal runs of V_FLOOR walkable cells (for Frostpeak cave rooms where
# the entire floor is slippery ice, not just the river/lake cells).
func floor_runs() -> Array:
	var runs: Array = []
	for y in range(gh):
		var x: int = 0
		while x < gw:
			var v: int = _val_c(Vector2i(x, y))
			if v != V_FLOOR and v != V_BRIDGE:
				x += 1
				continue
			var start: int = x
			while x < gw:
				var v2: int = _val_c(Vector2i(x, y))
				if v2 != V_FLOOR and v2 != V_BRIDGE:
					break
				x += 1
			var n: int = x - start
			runs.append({
				"pos": Vector2((float(start) + float(n) * 0.5) * CELL - half.x, (float(y) + 0.5) * CELL - half.y),
				"size": Vector2(float(n) * CELL, CELL),
			})
	return runs


# Horizontal runs of ONLY V_VOID barrier cells (for the rock-wall visuals —
# water already draws itself in the ground baker).
func void_runs() -> Array:
	var runs: Array = []
	for y in range(gh):
		var x: int = 0
		while x < gw:
			if _val_c(Vector2i(x, y)) != V_VOID:
				x += 1
				continue
			var start: int = x
			while x < gw and _val_c(Vector2i(x, y)) == V_VOID:
				x += 1
			var n: int = x - start
			runs.append({
				"pos": Vector2((float(start) + float(n) * 0.5) * CELL - half.x, (float(y) + 0.5) * CELL - half.y),
				"size": Vector2(float(n) * CELL, CELL),
			})
	return runs


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

func _val_c(c: Vector2i) -> int:
	return val(c.x, c.y)


func _set_c(c: Vector2i, v: int) -> void:
	if _in_grid(c):
		cells[c.y * gw + c.x] = v


func _walkable_c(c: Vector2i) -> bool:
	var v: int = _val_c(c)
	# FROSTPEAK: frozen ice (V_WATER) is walkable (slippery, not blocking), so it
	# counts for connectivity, spawning and collision-run exclusion.
	return v == V_FLOOR or v == V_BRIDGE or (ice_biome and v == V_WATER)


func _in_grid(c: Vector2i) -> bool:
	return c.x >= 0 and c.x < gw and c.y >= 0 and c.y < gh


func _clamp_cell(c: Vector2i, margin: int) -> Vector2i:
	return Vector2i(clamp(c.x, margin, gw - 1 - margin), clamp(c.y, margin, gh - 1 - margin))


func _edge_cell(dir: Vector2) -> Vector2i:
	var d: Vector2 = dir.normalized() if dir.length() > 0.01 else Vector2(0, 1)
	return _clamp_cell(Vector2i(
		gw / 2 + int(round(d.x * float(gw / 2 - 2))),
		gh / 2 + int(round(d.y * float(gh / 2 - 2)))), 2)
