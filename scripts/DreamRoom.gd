extends "res://scripts/World.gd"

# ============================================================
# DreamRoom.gd — Run 43 (2026-06-10) — Dream World biome room
# ============================================================
# ONE scene (DreamRoom.tscn) serves every room of every biome —
# geometry, palette, enemies, and exits are driven by
# RunState.current_biome + RunState.biome_room + DreamBiomes.gd.
#
# Extends World.gd and reuses its entire wave → boon → physical-
# door pipeline. What this subclass changes:
#   * _ready()  — builds floor/walls/gates procedurally BEFORE
#     super._ready() discovers them. Rooms NARROW toward the star
#     tip and exits sit on the wall matching the biome's compass
#     direction (Beach=SE wall, Frostpeak=N wall, Cake=climb N).
#   * Exit rolls — RunState.roll_dream_room_exits() (mini-boss at
#     room 4, boss at room 8, 1-3 doors per choice room, coins only
#     in Pie/DragonFruit reward rooms).
#   * Rewards — Juice auto-drops after rooms 3 and 6 (just before
#     the big fights). Mini-boss (room 4) drops no extras. The
#     room-8 boss = BIOME CLEANSED + the biome's single Dragon Soul.
#   * Routing — rooms chain back into DreamRoom.tscn; room 8
#     returns to the Town Square (DreamHub.tscn); cake room 5
#     continues to the summit (ShadowSenseiArena.tscn).
#
# The spawner node in DreamRoom.tscn is DreamSpawner.gd (named
# "EnemySpawner" so World.gd's $EnemySpawner hookup still works).
# ============================================================

const DB = preload("res://scripts/DreamBiomes.gd")
const DT = preload("res://scripts/DreamTerrain.gd")
const DL = preload("res://scripts/DreamLayout.gd")
const TZ = preload("res://scripts/TrapZone.gd")
const IF = preload("res://scripts/IceField.gd")     # Frostpeak slippery ice
const PT = preload("res://scripts/PeakTileset.gd")  # cave ice-cell data
const BW = preload("res://scripts/BiomeWalls.gd")   # default cliff-frame border
const SB = preload("res://scripts/SealedBarrier.gd")  # rubble plug for closed exits
const ST = preload("res://scripts/StalactiteTrap.gd") # Frostpeak cave falling stalactites

# Run 51 — organic layout (winding paths, cliffs, rivers, traps).
# DreamSpawner reads this via get_parent().get("dream_layout").
var dream_layout: RefCounted = null

const DREAM_ROOM_PATH: String  = "res://scenes/DreamRoom.tscn"
const DREAM_HUB_PATH: String   = "res://scenes/DreamHub.tscn"
const SUMMIT_PATH: String      = "res://scenes/ShadowSenseiArena.tscn"

var _coin_room: bool = false
# Run 109 — door plan is rolled ONCE at room entry (not at wave clear) so closed
# exits can show their rubble barrier immediately; the reveal reuses the plan.
var _planned_previews: Array = []
var _planned_open: Array = []
var _door_plan_done: bool = false
var _biome_id: String = ""
var _room: int = 1
var _half: Vector2 = Vector2(480, 352)
# Frostpeak exit-type system: each gate slot (left/center/right) is "cave" or "open".
# Rolled at door-plan time; the chosen gate's type persists to RunState.peak_room_type.
var _gate_exit_types: Array = []   # ["open"/"cave"] per gate slot, indexed by _gates order


func _ready() -> void:
	# Y-sort the room so heroes and interior props depth-sort by foot position
	# (south = in front, north = behind) for a natural top-down 3D feel.
	y_sort_enabled = true

	_biome_id = RunState.current_biome
	_room     = RunState.biome_room
	if _biome_id == "" or DB.get_biome(_biome_id).is_empty():
		push_error("[DreamRoom] No biome set — defaulting to beach room 1.")
		_biome_id = "beach"
		RunState.current_biome = "beach"
		RunState.biome_room = 1
		_room = 1

	var biome: Dictionary = DB.get_biome(_biome_id)
	_half = DB.room_half_extents(_room, _biome_id)

	# Biome music — shuffled playlist for this biome. Keeps playing seamlessly
	# room-to-room (MusicManager ignores the call if this biome is already on).
	MusicManager.play_biome(_biome_id)

	var total_rooms: int = DB.CAKE_ROOMS if _biome_id == "cake" else DB.ROOMS_PER_BIOME
	arena_name = "%s — Room %d/%d" % [String(biome["display"]), _room, total_rooms]
	is_final_in_loop = false
	next_scene_path = _route_next_scene()

	# Pending-reward bookkeeping BEFORE the wave starts:
	#   miniboss/boss doors → discard (the fight itself is the reward gate;
	#     the post-fight boon re-rolls a family like an Arena-1 room).
	#   coins door → flag the room; wave clear spawns a CoinPickup instead
	#     of a boon.
	if RunState.has_pending_reward():
		var ptype: String = String(RunState.peek_pending_reward().get("type", ""))
		if ptype == "miniboss" or ptype == "boss":
			RunState.consume_pending_reward()
		elif ptype == "coins":
			RunState.consume_pending_reward()
			_coin_room = true

	_build_room_geometry(biome)
	_position_heroes()
	super._ready()
	_plan_doors()
	_update_controls_label()

	# Run 146 — combat tip on the first room of each biome.
	if _room == 1:
		const HINT = preload("res://scripts/HintPopup.gd")
		HINT.show_combat_hint(self, "Combat",
			"Tap Y for combos  •  Hold Y to charge  •  X for heavy attacks  •  Q+Q swaps ninja  •  Clear the wave to unlock the exits")

	_apply_night_overlay()
	_apply_snow_overlay()
	_apply_vine_overlay()


# ---------------------------------------------------------------------------
# Run 113 — Night fell over the Dream World. A single CanvasModulate tints the
# whole world canvas (terrain, props, heroes, enemies) a cool moonlit blue;
# the HUD lives on its own CanvasLayer so it stays bright/unaffected. This is a
# pure OVERLAY — it changes nothing about the generated world and is trivially
# removable: delete this node / this function. Tune RunState.NIGHT_TINT to taste
# (lower = darker, more blue = cooler moonlight). World-space reward pickups and
# door/exit labels opt OUT via RunState.apply_night_exemption() so they stay bright.
# ---------------------------------------------------------------------------
func _apply_night_overlay() -> void:
	if get_node_or_null("NightOverlay") != null:
		return
	var night := CanvasModulate.new()
	night.name = "NightOverlay"
	night.color = RunState.NIGHT_TINT
	add_child(night)


# ---------------------------------------------------------------------------
# Run 116 — Frostpeak snowfall. SnowOverlay.gd spawns CPUParticles2D flakes
# in world-space (Node2D, layer 0) so they don't drift with the camera and
# get tinted by the NightOverlay automatically. Intensity ramps with room depth.
# ---------------------------------------------------------------------------
func _apply_snow_overlay() -> void:
	if _biome_id != "peaks":
		return
	if get_node_or_null("SnowOverlay") != null:
		return
	var SnowOverlayScript: GDScript = load("res://scripts/SnowOverlay.gd")
	var snow: Node2D = SnowOverlayScript.new()
	snow.name = "SnowOverlay"
	var total_rooms: int = DB.ROOMS_PER_BIOME
	# Room 1 → 0.25, Room 8 → 1.0.  Quadratic ease so the blizzard
	# really kicks in during the last couple of rooms.
	var progress: float = clampf(float(_room - 1) / float(max(1, total_rooms - 1)), 0.0, 1.0)
	var intensity: float = 0.25 + 0.75 * progress * progress
	snow.set_intensity(intensity)
	add_child(snow)


# ---------------------------------------------------------------------------
# Jungle vine overlay — semi-transparent vine fronds hanging into the camera
# frame at the corners / top edge, giving the feeling of peering through a
# canopy. Lives on CanvasLayer 2 (above world, below HUD).
# ---------------------------------------------------------------------------
func _apply_vine_overlay() -> void:
	if _biome_id != "jungle":
		return
	if get_node_or_null("JungleVineOverlay") != null:
		return
	var vine_layer: CanvasLayer = load("res://scripts/JungleVineOverlay.gd").new()
	add_child(vine_layer)


func _route_next_scene() -> String:
	if _biome_id == "cake":
		return SUMMIT_PATH if _room >= DB.CAKE_ROOMS else DREAM_ROOM_PATH
	return DREAM_HUB_PATH if _room >= DB.ROOMS_PER_BIOME else DREAM_ROOM_PATH


# ---------------------------------------------------------------------------
# Procedural geometry — floor, 4 walls, 3 gates on the exit-direction wall.
# Follows the Run 33 runtime-gate pattern: walls stay solid behind gates;
# exits commit from the DoorTrigger zone via [E].
# ---------------------------------------------------------------------------

func _build_room_geometry(biome: Dictionary) -> void:
	# Run 44: procedural pixel terrain + ocean replace the flat ColorRects.
	# (Flat rects kept in-scene, hidden, as a fallback contract.)
	var floor_rect: ColorRect = get_node_or_null("Floor")
	if floor_rect:
		floor_rect.visible = false
	var floor_alt: ColorRect = get_node_or_null("FloorAlt")
	if floor_alt:
		floor_alt.visible = false

	# Terrain seed is stable per biome+room — the island doesn't reshuffle.
	var total_rooms: int = DB.CAKE_ROOMS if _biome_id == "cake" else DB.ROOMS_PER_BIOME
	var progress: float = clamp(float(_room - 1) / float(max(1, total_rooms - 1)), 0.0, 1.0)
	var style: String = "void" if _biome_id == "cake" else "ocean"
	var seed_val: int = hash(_biome_id) * 31 + _room

	# Run 51: gate slots FIRST so the layout can carve corridors to them.
	var dir: Vector2 = biome["exit_dir"]
	var wx: float = _half.x + 16.0   # wall centerlines sit 16px past the floor edge
	var wy: float = _half.y + 16.0
	var slots: Array = _gate_slots(dir, wx, wy)
	var gate_ws: Array = []
	for slot in slots:
		gate_ws.append(slot.pos)

	dream_layout = DL.new()
	# Trap budget scales with run progress (1-indexed): the first biome you take
	# is tier 1, the cake finale is tier 6. Matches the displayed "(Tier N)"
	# panel (which is 0-indexed) + 1; cake is the T6 Cake Dragon arena.
	var trap_tier: int = 6 if _biome_id == "cake" else RunState.biomes_cleared_count() + 1
	dream_layout.generate(_half, dir, seed_val, _room, biome, gate_ws, trap_tier, _biome_id)
	# Run 52: star-arm ocean — land runs along the travel axis (back toward
	# town, ahead toward the tip); the boss room caps the tip with open sea.
	var tip_room: bool = (_biome_id == "cake" and _room >= DB.CAKE_ROOMS) \
		or (_biome_id != "cake" and _room >= DB.ROOMS_PER_BIOME)
	DT.build(self, _biome_id, biome, _half, seed_val, progress, style,
		dream_layout, dir, tip_room, gate_ws)

	var walls: Node2D = get_node_or_null("Walls")
	if walls == null:
		walls = Node2D.new()
		walls.name = "Walls"
		add_child(walls)

	var wall_col: Color = biome["wall"]
	# Walls are built as SEGMENTS that leave a clean opening at every gate, so a
	# character can step OUT through an opened gate into the door pocket (built on
	# open in World._spawn_depth_wall). The gate body itself seals the opening
	# until the room is cleared.
	var top_gaps: Array = []
	var bot_gaps: Array = []
	var left_gaps: Array = []
	var right_gaps: Array = []
	for gslot in slots:
		var sp: Vector2 = gslot.pos
		if absf(gslot.inward.y) > absf(gslot.inward.x):
			if sp.y < 0.0:
				top_gaps.append(sp.x)
			else:
				bot_gaps.append(sp.x)
		else:
			if sp.x < 0.0:
				left_gaps.append(sp.y)
			else:
				right_gaps.append(sp.y)
	_make_wall_gapped(walls, "WallTop",    true,  -wy, _half.x + 32.0, 32.0, wall_col, top_gaps)
	_make_wall_gapped(walls, "WallBottom", true,   wy, _half.x + 32.0, 32.0, wall_col, bot_gaps)
	_make_wall_gapped(walls, "WallLeft",   false, -wx, _half.y + 32.0, 32.0, wall_col, left_gaps)
	_make_wall_gapped(walls, "WallRight",  false,  wx, _half.y + 32.0, 32.0, wall_col, right_gaps)

	for i in range(slots.size()):
		var slot: Dictionary = slots[i]
		walls.add_child(_build_dream_gate("Gate%s" % char(65 + i), slot.pos, slot.inward))

	# Run 75/86: real-art walls replace the flat brown wall/gate rects (collision +
	# DoorTriggers stay; only the ColorRect visuals are hidden). The beach uses its
	# own richer cliff frame (totems + cave-mouth arches); every other biome gets the
	# shared cliff-face frame as the DEFAULT border (BiomeWalls) until a biome-
	# specific wall is authored. Hub/cake keep the brown border.
	var gate_ws2: Array = []
	for slot2 in slots:
		gate_ws2.append(slot2.pos)
	var real_walls: Node2D = null
	if _biome_id == "beach" and DT.beach_walls_available():
		real_walls = DT.make_beach_walls(_half, dir, gate_ws2, seed_val)
	elif _biome_id == "swamp" and DT.swamp_walls_available():
		real_walls = DT.make_swamp_walls(_half, dir, gate_ws2, seed_val, dream_layout)
	elif _biome_id == "caverns" and DT.caverns_walls_available():
		real_walls = DT.make_caverns_walls(_half, dir, gate_ws2, seed_val, dream_layout)
	elif _biome_id == "peaks" and DT.peaks_walls_available():
		# Roll exit types NOW so the wall builder can place cave mouths at the
		# correct gate slots. _plan_doors runs later (after _discover_gates) and
		# will skip re-rolling since _gate_exit_types is already populated.
		if _gate_exit_types.is_empty():
			_roll_peak_exit_types_early(slots.size())
		var is_cave: bool = RunState.peak_room_type == "cave" and _room > 1
		real_walls = DT.make_peaks_walls(_half, dir, gate_ws2, seed_val, dream_layout, is_cave, _gate_exit_types)
	elif _biome_id == "jungle" and DT.jungle_walls_available():
		real_walls = DT.make_jungle_walls(_half, dir, gate_ws2, seed_val, dream_layout)
	elif _biome_id in ["jungle", "swamp", "caverns", "peaks"] and BW.available():
		real_walls = BW.make_walls(_half, gate_ws2, seed_val)
	if real_walls != null:
		for ch in walls.get_children():
			var vis: CanvasItem = ch.get_node_or_null("Visual")
			if vis:
				vis.visible = false
		add_child(real_walls)

	_build_layout_collision()
	_spawn_traps(biome)


# One StaticBody2D holding merged rect shapes for every blocked cell
# (barriers + water). Bridges and floor stay open. The body joins the
# "dashable_barrier" group so the ninja DASH can phase through these INNER
# barriers (the outer wall ring is a separate body → still solid).
func _build_layout_collision() -> void:
	if dream_layout == null:
		return
	# VOID barriers — dashable inner walls (ninja DASH phases them).
	var body := StaticBody2D.new()
	body.name = "LayoutColliders"
	body.collision_layer = 1
	body.collision_mask = 0
	body.add_to_group("dashable_barrier")
	for run in dream_layout.void_runs():
		var cs := CollisionShape2D.new()
		var sh := RectangleShape2D.new()
		sh.size = run.size
		cs.shape = sh
		cs.position = run.pos
		body.add_child(cs)
	add_child(body)
	# FROSTPEAK: frozen ice is WALKABLE — no water collider at all. Instead an
	# IceField flags heroes standing on it so they slide (slippery momentum).
	# Cave rooms: only ice-rendered floor cells are slippery — rocky patches stop sliding.
	if _biome_id == "peaks":
		var ice_runs: Array = dream_layout.water_runs()
		var is_cave_room: bool = RunState.peak_room_type == "cave" and _room > 1
		if is_cave_room:
			# Cave rooms: only ice-rendered floor cells, not all floor.
			ice_runs = ice_runs + PT.cave_ice_floor_runs(dream_layout)
		if not ice_runs.is_empty():
			var ice: Area2D = IF.new()
			ice.setup(ice_runs)
			add_child(ice)
	elif _biome_id == "caverns":
		# CAVERNS: lava rivers are CROSSABLE — no blocking collider. A single burn hazard
		# spans the river cells so walking across costs HP (like the magma pools); DASHING
		# over does no damage (Run 100, Bruno).
		var lava_runs: Array = dream_layout.water_runs()
		if not lava_runs.is_empty():
			var lava: Area2D = TZ.new()
			lava.trap_type = "burn"
			lava.trap_name = "Lava River"
			lava.rect_runs = lava_runs
			add_child(lava)
	else:
		# WATER (rivers) — its OWN body on the World layer so heroes/enemies are
		# still blocked from walking across, but tagged "water_collider" so ranged
		# shots and charged ranged attacks fly OVER it instead of dying on contact.
		# Also "dashable_barrier" so the ninja DASH phases across rivers like the
		# inner rock barriers (you can dash over water, just not walk across it).
		var water := StaticBody2D.new()
		water.name = "WaterColliders"
		water.collision_layer = 1
		water.collision_mask = 0
		water.add_to_group("water_collider")
		water.add_to_group("dashable_barrier")
		for run in dream_layout.water_runs():
			var cs := CollisionShape2D.new()
			var sh := RectangleShape2D.new()
			sh.size = run.size
			cs.shape = sh
			cs.position = run.pos
			water.add_child(cs)
		add_child(water)
	# No generic slab fill: every biome renders its barriers as natural prop art
	# from its sprite sheet (like the beach), so the brown rock-slab placeholder
	# is gone. Biomes still being art-pass'd lean on their tileset's prop coverage.


func _spawn_traps(biome: Dictionary) -> void:
	if dream_layout == null:
		return
	for t in dream_layout.trap_spots:
		var z: Area2D = TZ.new()
		z.trap_type = t.type
		z.visual = t.visual
		z.trap_name = t.name
		z.accent = biome.get("accent", Color.WHITE)
		z.floor_col = biome.get("floor", Color(0.3, 0.3, 0.3))
		# Swamp/caverns lay their hazard pool down as an animated tile layer (poison
		# pools / molten lava), so the zone draws no sprite and sizes its collision to
		# the pool radius the liquid tiles fill (shared pool_radius).
		if _biome_id == "swamp" or _biome_id == "caverns":
			z.draw_sprite = false
			z.radius = float(t.get("pool_radius", 56.0))
			z.pool_wob = t.get("pool_wob", [])   # blob outline → curve-matched collision
		add_child(z)
		z.position = t.pos
	if not dream_layout.trap_spots.is_empty():
		print("[DreamRoom] %d traps placed." % dream_layout.trap_spots.size())
	# Frostpeak cave rooms: falling stalactite traps on open floor.
	if _biome_id == "peaks" and RunState.peak_room_type == "cave" and _room > 1:
		_spawn_stalactite_traps()


# ---------------------------------------------------------------------------
# Stalactite traps for Frostpeak cave rooms. 4-6 dark shadow spots on open
# floor; fixed count so smaller (later) rooms feel denser.
# ---------------------------------------------------------------------------
const STALACTITE_COUNT: int = 5
const STALACTITE_MIN_DIST: float = 80.0    # min spacing between trap shadows
const STALACTITE_GATE_CLEAR: float = 96.0  # keep traps away from gates
const STALACTITE_CENTER_CLEAR: float = 100.0  # keep traps away from spawn center

func _spawn_stalactite_traps() -> void:
	if dream_layout == null:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("stalactite") * 31 + _room
	var gw: int = dream_layout.gw
	var gh: int = dream_layout.gh
	var gate_ws: Array = []
	for g in _gates:
		if g.node != null:
			gate_ws.append((g.node as Node2D).position)
	# Gather candidate open floor cells.
	var cands: Array = []
	for cj in range(gh):
		for ci in range(gw):
			if dream_layout.val(ci, cj) != 1:
				continue
			var wc: Vector2 = dream_layout.cell_to_world(Vector2i(ci, cj))
			if wc.length() < STALACTITE_CENTER_CLEAR:
				continue
			if absf(wc.x) > _half.x - 48.0 or absf(wc.y) > _half.y - 48.0:
				continue
			var near_gate: bool = false
			for gp in gate_ws:
				if wc.distance_to(gp) < STALACTITE_GATE_CLEAR:
					near_gate = true
					break
			if near_gate:
				continue
			# Check open floor (no walls in immediate vicinity).
			var blocked: bool = false
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if dream_layout.val(ci + dx, cj + dy) == 0:
						blocked = true
						break
				if blocked:
					break
			if not blocked:
				cands.append(wc)
	# Shuffle and pick with minimum spacing.
	for i in range(cands.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp = cands[i]
		cands[i] = cands[j]
		cands[j] = tmp
	var placed: Array = []
	for wc2 in cands:
		if placed.size() >= STALACTITE_COUNT:
			break
		var too_close: bool = false
		for p in placed:
			if (wc2 as Vector2).distance_to(p as Vector2) < STALACTITE_MIN_DIST:
				too_close = true
				break
		if too_close:
			continue
		var trap: Area2D = ST.new()
		add_child(trap)
		trap.position = wc2
		placed.append(wc2)
	if not placed.is_empty():
		print("[DreamRoom] %d stalactite traps placed in cave room." % placed.size())


# 3 gate slots distributed to "read" as travel toward the star tip.
# Pure-N (peaks/cake): 3 gates across the TOP wall. Diagonals: 2 gates on
# the horizontal-component wall (offset toward the x side) + 1 on the
# vertical-component side wall.
func _gate_slots(dir: Vector2, wx: float, wy: float) -> Array:
	var slots: Array = []
	if dir.x == 0.0:
		var y: float = -wy if dir.y < 0.0 else wy
		var inward: Vector2 = Vector2(0, 1) if dir.y < 0.0 else Vector2(0, -1)
		for off in [-_half.x * 0.70, 0.0, _half.x * 0.70]:
			slots.append({"pos": Vector2(off, y), "inward": inward})
		return slots
	# Diagonal: horizontal wall = top (dir.y<0) or bottom (dir.y>0).
	var hy: float = -wy if dir.y < 0.0 else wy
	var h_inward: Vector2 = Vector2(0, 1) if dir.y < 0.0 else Vector2(0, -1)
	var xs: float = 1.0 if dir.x > 0.0 else -1.0
	slots.append({"pos": Vector2(xs * _half.x * 0.30, hy), "inward": h_inward})
	slots.append({"pos": Vector2(xs * _half.x * 0.68, hy), "inward": h_inward})
	# Side wall gate (right for E component, left for W), biased toward exit corner.
	var sx: float = wx if dir.x > 0.0 else -wx
	var s_inward: Vector2 = Vector2(-1, 0) if dir.x > 0.0 else Vector2(1, 0)
	var sy: float = (-1.0 if dir.y < 0.0 else 1.0) * _half.y * 0.45
	slots.append({"pos": Vector2(sx, sy), "inward": s_inward})
	return slots


func _make_wall(parent: Node, wall_name: String, pos: Vector2, size: Vector2, col: Color) -> void:
	var w := StaticBody2D.new()
	w.name = wall_name
	w.position = pos
	w.collision_layer = 1
	w.collision_mask = 0
	# Run 110 — the true ARENA BOUNDARY. Bea's Meteor leap clears every interior
	# barrier but must stop here, so the outer wall ring carries "leap_blocker".
	w.add_to_group("leap_blocker")
	var vis := ColorRect.new()
	vis.name = "Visual"
	vis.offset_left = -size.x * 0.5
	vis.offset_top = -size.y * 0.5
	vis.offset_right = size.x * 0.5
	vis.offset_bottom = size.y * 0.5
	vis.color = col
	w.add_child(vis)
	var shape := RectangleShape2D.new()
	shape.size = size
	var cs := CollisionShape2D.new()
	cs.name = "CollisionShape2D"
	cs.shape = shape
	w.add_child(cs)
	parent.add_child(w)


# Lay a wall run as solid SEGMENTS, punching a GATE_OPEN_HALF*2 opening centered on
# each gate so an opened gate is actually walkable. `fixed` is the cross-axis coord;
# `span_half` is half the run length (matches the old full-wall extent).
const GATE_OPEN_HALF: float = 32.0

func _make_wall_gapped(parent: Node, base_name: String, horizontal: bool, fixed: float,
		span_half: float, thick: float, col: Color, gap_centers: Array) -> void:
	var cuts: Array = []
	for c in gap_centers:
		cuts.append([c - GATE_OPEN_HALF, c + GATE_OPEN_HALF])
	cuts.sort_custom(func(p, q): return p[0] < q[0])
	var seg_start: float = -span_half
	var idx: int = 0
	for cut in cuts:
		var seg_end: float = min(cut[0], span_half)
		if seg_end - seg_start > 1.0:
			_add_wall_segment(parent, "%s%d" % [base_name, idx], horizontal, fixed, seg_start, seg_end, thick, col)
			idx += 1
		seg_start = max(seg_start, cut[1])
	if span_half - seg_start > 1.0:
		_add_wall_segment(parent, "%s%d" % [base_name, idx], horizontal, fixed, seg_start, span_half, thick, col)


func _add_wall_segment(parent: Node, seg_name: String, horizontal: bool, fixed: float,
		a: float, b: float, thick: float, col: Color) -> void:
	var center: float = (a + b) * 0.5
	var length: float = b - a
	var pos: Vector2 = Vector2(center, fixed) if horizontal else Vector2(fixed, center)
	var size: Vector2 = Vector2(length, thick) if horizontal else Vector2(thick, length)
	_make_wall(parent, seg_name, pos, size, col)


# Gate body matching World.gd's expected structure (Visual / CollisionShape2D /
# DoorTrigger). `inward` points INTO the arena so the trigger zone is reachable.
func _build_dream_gate(gate_name: String, pos: Vector2, inward: Vector2) -> StaticBody2D:
	var horizontal: bool = abs(inward.y) > abs(inward.x)   # gate on a top/bottom wall
	var gate := StaticBody2D.new()
	gate.name = gate_name
	gate.position = pos
	gate.collision_layer = 1
	gate.collision_mask = 0
	gate.add_to_group("leap_blocker")   # Run 110 — arena boundary; the leap can't pass a gate either

	var vis := ColorRect.new()
	vis.name = "Visual"
	var gw: float = 64.0 if horizontal else 32.0
	var gh: float = 32.0 if horizontal else 64.0
	vis.offset_left = -gw * 0.5
	vis.offset_top = -gh * 0.5
	vis.offset_right = gw * 0.5
	vis.offset_bottom = gh * 0.5
	vis.color = GATE_CLOSED_COLOR
	gate.add_child(vis)

	var col := CollisionShape2D.new()
	col.name = "CollisionShape2D"
	var shape := RectangleShape2D.new()
	shape.size = Vector2(gw, gh)
	col.shape = shape
	gate.add_child(col)

	var trigger := Area2D.new()
	trigger.name = "DoorTrigger"
	# Straddle the opening, reaching OUT into the door pocket so [E] fires whether
	# the hero is at the inner threshold or stepped into the doorway.
	trigger.position = -inward * 18.0
	trigger.collision_layer = 0
	trigger.collision_mask = 2
	var tcol := CollisionShape2D.new()
	tcol.name = "CollisionShape2D"
	var tshape := RectangleShape2D.new()
	tshape.size = Vector2(72, 104) if horizontal else Vector2(104, 72)
	tcol.shape = tshape
	trigger.add_child(tcol)
	gate.add_child(trigger)
	return gate


# ---------------------------------------------------------------------------
# Sealed-exit barriers (Run 109). A door that rolled CLOSED keeps its invisible
# gate collision, which used to read as an arbitrary invisible wall — the gap
# looked walkable but wasn't. We now plug the opening with a clearly-solid
# barrier so a blocked exit looks DELIBERATELY blocked (cave-in / rubble), per
# biome. This is a PLACEHOLDER tinted rubble pile for now; swap the branch in
# _make_biome_barrier() with authored art (caverns → mine cart / rock-slide,
# peaks → snow drift, swamp → fallen logs, …) as it's drawn — signature stays.
# ---------------------------------------------------------------------------
const _BARRIER_PALETTE := {
	"caverns":  {"base": Color(0.20, 0.17, 0.18), "hi": Color(0.36, 0.29, 0.28), "accent": Color(0.92, 0.42, 0.16)},
	"beach":    {"base": Color(0.46, 0.41, 0.34), "hi": Color(0.66, 0.60, 0.50), "accent": Color(0.80, 0.74, 0.60)},
	"swamp":    {"base": Color(0.21, 0.26, 0.18), "hi": Color(0.35, 0.42, 0.27), "accent": Color(0.50, 0.58, 0.32)},
	"jungle":   {"base": Color(0.28, 0.25, 0.20), "hi": Color(0.45, 0.41, 0.31), "accent": Color(0.55, 0.62, 0.30)},
	"peaks":    {"base": Color(0.55, 0.60, 0.66), "hi": Color(0.86, 0.91, 0.97), "accent": Color(0.95, 0.97, 1.00)},
	"cake":     {"base": Color(0.60, 0.42, 0.55), "hi": Color(0.82, 0.62, 0.74), "accent": Color(0.96, 0.86, 0.55)},
	"_default": {"base": Color(0.34, 0.32, 0.30), "hi": Color(0.52, 0.49, 0.46), "accent": Color(0.66, 0.62, 0.58)},
}

const BARRIER_RECESS: float = 12.0   # push the rubble back INTO the gate opening
const BARRIER_DEPTH: float  = 38.0   # pile thickness across the opening
const BARRIER_SPAN_PAD: float = 14.0 # rubble overshoot past the 64px opening


func _seal_gate(g: Dictionary) -> void:
	super._seal_gate(g)
	_place_sealed_barrier(g)


func _place_sealed_barrier(g: Dictionary) -> void:
	var gate: Node2D = g.get("node") as Node2D
	if gate == null:
		return
	if gate.get_node_or_null("SealedBarrier") != null:
		return
	# OUTWARD = away from arena centre (toward/into the wall opening), inferred
	# from the gate's offset. The rubble is recessed along outward so the heroes
	# can step INTO the doorway lip before meeting the pile (concave "goal" feel).
	var gp: Vector2 = gate.position
	var outward: Vector2
	if absf(gp.y) >= absf(gp.x):
		outward = Vector2(0.0, signf(gp.y) if gp.y != 0.0 else -1.0)
	else:
		outward = Vector2(signf(gp.x), 0.0)
	var barrier: Node2D = _make_biome_barrier(outward, String(gate.name))
	barrier.name = "SealedBarrier"
	barrier.z_as_relative = false
	# Pile centre Y relative to the gate line — drives the per-frame z flip so the
	# pile only occludes a hero who is BEHIND it (deeper in the gate), never one
	# approaching from the open side.
	barrier.set("occ_offset_y", outward.y * (BARRIER_RECESS + BARRIER_DEPTH * 0.5))
	gate.add_child(barrier)


# Per-biome sealed-exit barrier. PLACEHOLDER: a tinted rubble pile sized to plug
# the gate opening. Replace branches with authored props as art lands; the
# (outward, key) signature is the only contract callers rely on.
func _make_biome_barrier(outward: Vector2, key: String) -> Node2D:
	var span: float = GATE_OPEN_HALF * 2.0 + BARRIER_SPAN_PAD   # along the wall
	var pal: Dictionary = _BARRIER_PALETTE.get(_biome_id, _BARRIER_PALETTE["_default"])
	return _make_rubble_barrier(span, BARRIER_DEPTH, outward, pal, key)


func _make_rubble_barrier(span: float, depth: float, outward: Vector2, pal: Dictionary, key: String) -> Node2D:
	var root: Node2D = SB.new()
	# Local frame: +X runs ALONG the wall, +Y runs OUTWARD (into the opening).
	# Rotate so local +Y aligns with the world outward direction.
	root.rotation = outward.angle() - PI * 0.5
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%s|%d|%s" % [key, _room, _biome_id])
	var base: Color = pal["base"]
	var hi: Color = pal["hi"]
	var accent: Color = pal["accent"]
	var n: int = 7
	for i in range(n):
		var t: float = float(i) / float(n - 1)
		var x: float = lerp(-span * 0.5 + 8.0, span * 0.5 - 8.0, t)
		var y: float = BARRIER_RECESS + ((-depth * 0.16) if (i % 2 == 0) else (depth * 0.18))
		x += rng.randf_range(-4.0, 4.0)
		y += rng.randf_range(-3.0, 3.0)
		_add_boulder(root, Vector2(x, y), rng.randf_range(11.0, 17.0), base, hi, rng)
	# Center capping boulders for fullness (no gaps to see through).
	for _j in range(3):
		var cx: float = rng.randf_range(-span * 0.34, span * 0.34)
		var cy: float = BARRIER_RECESS + rng.randf_range(-depth * 0.06, depth * 0.06)
		_add_boulder(root, Vector2(cx, cy), rng.randf_range(9.0, 13.0), base.lerp(hi, 0.15), hi, rng)
	# Sparse biome accent flecks (embers / moss / snow-cap).
	for _k in range(2):
		var fa := Polygon2D.new()
		fa.polygon = _circle_pts(rng.randf_range(2.5, 4.0), 8)
		fa.position = Vector2(rng.randf_range(-span * 0.3, span * 0.3), BARRIER_RECESS + rng.randf_range(-depth * 0.2, depth * 0.2))
		fa.color = Color(accent.r, accent.g, accent.b, 0.85)
		root.add_child(fa)
	return root


func _add_boulder(parent: Node2D, pos: Vector2, r: float, base: Color, hi: Color, rng: RandomNumberGenerator) -> void:
	var sh := Polygon2D.new()                       # soft drop-shadow / outline
	sh.polygon = _circle_pts(r + 2.0, 14)
	sh.position = pos + Vector2(0, 2)
	sh.color = Color(0, 0, 0, 0.35)
	parent.add_child(sh)
	var body := Polygon2D.new()
	body.polygon = _circle_pts(r, 14, rng)          # lumpy edge
	body.position = pos
	body.color = base
	parent.add_child(body)
	var hl := Polygon2D.new()                        # top-left highlight
	hl.polygon = _circle_pts(r * 0.55, 12)
	hl.position = pos + Vector2(-r * 0.28, -r * 0.30)
	hl.color = hi
	parent.add_child(hl)


func _circle_pts(r: float, n: int, rng: RandomNumberGenerator = null) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(n):
		var a: float = TAU * float(i) / float(n)
		var rr: float = r if rng == null else r * rng.randf_range(0.86, 1.06)
		pts.append(Vector2(cos(a) * rr, sin(a) * rr))
	return pts


# Heroes enter from the side OPPOSITE the exit direction — at the layout's
# carved entry cove when one exists.
func _position_heroes() -> void:
	var biome: Dictionary = DB.get_biome(_biome_id)
	var dir: Vector2 = (biome["exit_dir"] as Vector2)
	var entry: Vector2 = -dir.normalized() * Vector2(_half.x * 0.55, _half.y * 0.55)
	if dir == Vector2.ZERO:
		entry = Vector2(0, _half.y * 0.55)
	if dream_layout != null:
		entry = dream_layout.entry_world()
	var player: Node2D = get_node_or_null("Player")
	if player:
		player.position = entry
	var bea: Node2D = get_node_or_null("Bea")
	if bea:
		bea.position = entry + Vector2(36, 0)


func _update_controls_label() -> void:
	var hint: Label = get_node_or_null("DebugHUD/ControlsLabel")
	if hint:
		var tier: int = 5 if _biome_id == "cake" else RunState.biomes_cleared_count()
		hint.text = "%s  (Tier %d)\nClear the wave → collect the reward → exit toward the star tip.\nPress H to hide this panel." % [arena_name, tier]


# ---------------------------------------------------------------------------
# Overrides — exit rolls / rewards / routing
# ---------------------------------------------------------------------------

# Compute the door identities for this room. Pure (RNG only) — rolled ONCE at
# room entry and stored, so the entry-time "blocked exit" preview and the
# post-clear reveal agree.
func _roll_door_previews() -> Array:
	if _biome_id == "cake":
		if _room >= DB.CAKE_ROOMS:
			return [{"type": "summit", "family": "", "rarity": "", "label": "⛩️ THE SUMMIT"}]
		var previews: Array = RunState.roll_dream_room_exits(_room + 1, _biome_id)
		# The cake climb has no mini-boss/boss rooms — re-roll forced doors flat.
		for i in range(previews.size()):
			var t: String = String(previews[i].get("type", ""))
			if t == "miniboss" or t == "boss":
				previews[i] = {"type": "boon", "family": RunState.DOOR_FAMILIES[randi() % RunState.DOOR_FAMILIES.size()], "rarity": "", "label": ""}
		return previews
	elif _room >= DB.ROOMS_PER_BIOME:
		return [{"type": "hub", "family": "", "rarity": "", "label": "🏮 TOWN SQUARE"}]
	return RunState.roll_dream_room_exits(_room + 1, _biome_id)


# Run 109 — decide which gates will open at entry and immediately plug the rest
# with rubble. Players can now count unlockable exits before clearing the wave:
# clear opening = will unlock, rubble = blocked (not a "locked, eventually opens").
func _plan_doors() -> void:
	if _door_plan_done or _gates.is_empty():
		return
	_planned_previews = _roll_door_previews()
	var open_count: int = min(_planned_previews.size(), _gates.size())
	var indices: Array = range(_gates.size())
	indices.shuffle()
	_planned_open = indices.slice(0, open_count)
	_planned_open.sort()
	_door_plan_done = true
	# Frostpeak: roll exit types (cave vs open) for each gate slot.
	if _biome_id == "peaks":
		_roll_peak_exit_types()
	for i in range(_gates.size()):
		if _planned_open.has(i):
			continue
		var g: Dictionary = _gates[i]
		_place_sealed_barrier(g)
		# Drop the "🔒 LOCKED" tag on blocked gates — they don't unlock, so they
		# shouldn't read like a door that eventually opens.
		if g.node:
			var lk: Node = g.node.get_node_or_null("LockedIndicator")
			if lk:
				lk.queue_free()


# ---------------------------------------------------------------------------
# Frostpeak exit-type rolling. 3 gate slots (left=0, center=1, right=2).
# Always a 2+1 split: 2 of one type and 1 of the other.
# Configurations:  2 open + 1 cave  |  1 open + 2 cave
# Center is usually cave but can be open (variety).
# ---------------------------------------------------------------------------
const _PEAK_EXIT_CONFIGS: Array = [
	["open",  "cave", "open"],     # center cave, sides open
	["cave",  "cave", "open"],     # left+center cave, right open
	["open",  "cave", "cave"],     # center+right cave, left open
	["cave",  "open", "cave"],     # sides cave, center open
]

# Early roll used by _build_room_geometry (before gates are discovered).
# Uses the known slot count instead of _gates.size(). Same deterministic
# seed so the result is identical to calling _roll_peak_exit_types later.
func _roll_peak_exit_types_early(slot_count: int) -> void:
	_gate_exit_types.clear()
	if slot_count < 3:
		for _i in range(slot_count):
			_gate_exit_types.append("open")
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("peak_exit") * 31 + _room + hash(_biome_id)
	var config: Array = _PEAK_EXIT_CONFIGS[rng.randi() % _PEAK_EXIT_CONFIGS.size()]
	for et in config:
		_gate_exit_types.append(String(et))
	print("[DreamRoom] Peaks exit types (early): %s" % [_gate_exit_types])


func _roll_peak_exit_types() -> void:
	# Already rolled in _build_room_geometry — don't re-roll (same seed would
	# produce the same result, but skipping avoids the redundant work).
	if not _gate_exit_types.is_empty():
		return
	_gate_exit_types.clear()
	if _gates.size() < 3:
		for _i in range(_gates.size()):
			_gate_exit_types.append("open")
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("peak_exit") * 31 + _room + hash(_biome_id)
	var config: Array = _PEAK_EXIT_CONFIGS[rng.randi() % _PEAK_EXIT_CONFIGS.size()]
	for et in config:
		_gate_exit_types.append(String(et))
	print("[DreamRoom] Peaks exit types: %s" % [_gate_exit_types])


# Override gate commit to save the chosen exit type for the next room.
func _commit_gate_transition(g: Dictionary) -> void:
	# Determine which gate index was committed and store its exit type.
	if _biome_id == "peaks" and not _gate_exit_types.is_empty():
		for i in range(_gates.size()):
			if _gates[i].name == g.name:
				if i < _gate_exit_types.size():
					RunState.peak_room_type = _gate_exit_types[i]
				break
	super._commit_gate_transition(g)


func _assign_door_previews_and_open() -> void:
	if _gates.is_empty():
		return
	if not _door_plan_done:
		_plan_doors()
	var p: int = 0
	for i in range(_gates.size()):
		var g: Dictionary = _gates[i]
		if _planned_open.has(i):
			g.preview = _planned_previews[p].duplicate()
			# Attach exit type for peaks gates.
			if _biome_id == "peaks" and i < _gate_exit_types.size():
				g.preview["exit_type"] = _gate_exit_types[i]
			p += 1
			_apply_preview_label(g, g.preview)
			_open_gate(g)
		else:
			_seal_gate(g)
		_gates[i] = g
	print("[DreamRoom] %d/%d doors opened: %s" % [_planned_open.size(), _gates.size(), _summarize_gate_previews()])


func _apply_preview_label(g: Dictionary, preview: Dictionary) -> void:
	var ptype: String = String(preview.get("type", ""))
	if ptype in ["miniboss", "coins", "hub", "summit"]:
		_apply_simple_label(g, preview, ptype)
		return
	super._apply_preview_label(g, preview)


func _apply_simple_label(g: Dictionary, preview: Dictionary, ptype: String) -> void:
	if g.label == null:
		return
	var line1: String = String(preview.get("label", "?"))
	var line2: String = ""
	var border: Color = Color(0.85, 0.85, 0.85)
	match ptype:
		"miniboss":
			line2 = "a mighty foe bars the way"
			border = Color(1.0, 0.75, 0.25)
		"coins":
			line2 = "+%d-%d coins" % [RunState.COIN_DOOR_GRANT_MIN, RunState.COIN_DOOR_GRANT_MAX]
			border = Color(1.0, 0.85, 0.30)
		"hub":
			line2 = "shops + next biome"
			border = Color(0.40, 0.90, 0.55)
		"summit":
			line2 = "Shadow Sensei Z awaits"
			border = Color(0.85, 0.25, 0.85)
	var inner: Label = g.label.get_node_or_null("Text") as Label
	if inner == null and g.label is Label:
		inner = g.label
	if inner:
		inner.text = "%s\n%s" % [line1, line2]
	if g.label is PanelContainer:
		var sb: StyleBoxFlat = g.label.get_theme_stylebox("panel") as StyleBoxFlat
		if sb:
			var sb_copy: StyleBoxFlat = sb.duplicate() as StyleBoxFlat
			sb_copy.border_color = border
			g.label.add_theme_stylebox_override("panel", sb_copy)
	g.label.visible = true


# Coin rooms swap the boon pickup for a CoinPickup. Everything else uses
# the standard World.gd boon flow.
func _present_boon_offer() -> void:
	if _coin_room:
		if get_tree().current_scene.has_node("CoinPickup"):
			return
		var pickup := CoinPickup.new()
		pickup.name = "CoinPickup"
		get_tree().current_scene.add_child(pickup)
		pickup.global_position = Vector2(0, -60)
		pickup.coins_collected.connect(func(_amt: int): _after_boon_picked(""))
		print("[DreamRoom] Coin room — CoinPickup spawned.")
		return

	# Run 150 (Bruno fix 8): juice rooms drop ONLY the juice, boss rooms drop
	# ONLY the Dragon Soul — never a boon / pie / dragonfruit on top. Spawn a
	# direct-collect item pickup (BoonPickup in item mode, no offer overlay);
	# the actual grant happens in _after_boon_picked's existing room branches.
	var _drop_boss: bool = _biome_id != "cake" and _room >= DB.ROOMS_PER_BIOME
	var _drop_juice: bool = _biome_id != "cake" and (_room in DB.JUICE_ROOMS)
	if _drop_boss or _drop_juice:
		if get_tree().current_scene.has_node("BoonPickup"):
			return
		# Consume any pending door reward so "boss"/"apple_juice" (or a stale
		# family) can't leak into the NEXT room's boon offer.
		RunState.consume_pending_reward()
		var item := BoonPickup.new()
		item.name = "BoonPickup"
		item.setup("__dragon_soul__" if _drop_boss else "__juice__")
		get_tree().current_scene.add_child(item)
		item.global_position = Vector2(0, -60)
		item.boon_collected.connect(_after_boon_picked)
		print("[DreamRoom] Item-only drop (%s) — room %d." % ["dragon_soul" if _drop_boss else "juice", _room])
		return

	super._present_boon_offer()


# Dream reward cadence (Run 45): Juice after rooms 3 & 6 (just before the
# big fights). Mini-boss (room 4) drops nothing extra — the fight gates
# progress. Boss (room 8) = cleansed + the biome's SINGLE Dragon Soul.
func _after_boon_picked(_boon_id: String) -> void:
	_boon_picked_this_arena = true
	_boon_collected = true
	_refresh_boons_label()

	var is_boss_room: bool = _biome_id != "cake" and _room >= DB.ROOMS_PER_BIOME
	var is_mini_room: bool = _biome_id != "cake" and _room == DB.MINIBOSS_ROOM
	var is_juice_room: bool = _biome_id != "cake" and (_room in DB.JUICE_ROOMS)

	if is_boss_room:
		RunState.dragon_souls += 1
		RunState.biomes_cleared[_biome_id] = true
		var biome: Dictionary = DB.get_biome(_biome_id)
		if cleared_label:
			cleared_label.text = "✦ %s CLEANSED! ✦\n🐉 +1 Dragon Soul (%d total)\nReturn to the Town Square!" % [
				String(biome["display"]).to_upper(), RunState.dragon_souls]
		# Run 142 — Sensei lore tier now driven by island_healing_score()
		# (weighted sum of all family tiers). Advances when enough families
		# have healed, not per-biome-cleared.
		RunState.update_sensei_lore_from_healing()
		var cleared_count: int = RunState.biomes_cleared_count()
		RunState.nights_completed += 1
		print("[DreamRoom] %s boss down — biome cleansed (%d/5). +1 spark." % [_biome_id, cleared_count])
	elif is_mini_room:
		if cleared_label:
			cleared_label.text = "★ MINI-BOSS DOWN ★\nChoose a door to continue!"
		print("[DreamRoom] Mini-boss down.")
	elif is_juice_room:
		var healed_j: int = RunState.grant_apple_juice(get_tree())
		if cleared_label:
			cleared_label.text = "✦ REWARD ACQUIRED ✦\n🧃 JUICE (+%d HP)\nChoose a door to continue!" % healed_j
		print("[DreamRoom] Room %d juice drop — +%d HP." % [_room, healed_j])
	else:
		if cleared_label:
			cleared_label.text = "✦ REWARD ACQUIRED ✦\nChoose a door to continue!"

	if next_scene_path != "":
		_assign_door_previews_and_open()
	else:
		for g in _gates:
			_open_gate(g)


# Advance/clear the biome counters as the chosen exit commits.
func _execute_transition() -> void:
	if _pending_next_scene == DREAM_ROOM_PATH:
		RunState.biome_room += 1
	elif _pending_next_scene == DREAM_HUB_PATH:
		RunState.current_biome = ""
		RunState.biome_room = 1
	# SUMMIT_PATH: leave biome state as-is (ShadowSenseiArena reads "cake").
	super._execute_transition()
