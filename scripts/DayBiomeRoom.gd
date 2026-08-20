extends Node2D

# ============================================================
# DayBiomeRoom.gd — Run 118 (2026-07-01) — daytime biome visit
# ============================================================
# ONE scene serves all five biomes (the DreamRoom pattern) — reads
# RunState.day_visit_biome and builds the biome's REAL terrain via
# the night pipeline (DreamLayout + DreamTerrain + the biome's own
# tileset), opened up for daytime (see _build_biome_terrain). Each biome day-room holds TWO family cottages
# (RunState.FAMILY_HOMES); family members wander outside, the
# ELDER stays inside as the fixed karma drop-off (enter the hut
# via its door → FamilyHome.tscn).
#
# DAY ONLY: no enemies, no traps, no night overlay. The night
# version of each biome stays the pure combat arena chain — the
# cottages exist ONLY here (design lock).
# ============================================================

const DB = preload("res://scripts/DreamBiomes.gd")
const DAY = preload("res://scripts/DayTerrain.gd")
const FL = preload("res://scripts/FamilyLore.gd")
const NPC = preload("res://scripts/FamilyNPC.gd")
# Run 118: day rooms wear the SAME real-art tilesets as the night arenas.
const DT = preload("res://scripts/DreamTerrain.gd")
const DL = preload("res://scripts/DreamLayout.gd")
const IF = preload("res://scripts/IceField.gd")     # Frostpeak slippery ice
const BW = preload("res://scripts/BiomeWalls.gd")   # fallback cliff-frame border
const DialogBoxScript = preload("res://scripts/DialogBox.gd")   # wanderer chats
# Run 151 — hand-drawn torii gate sprites + swirling portal effects.
const TORII = preload("res://scripts/ToriiGate.gd")

const TOWN_PATH: String = "res://scenes/TownSquare.tscn"
const HOME_PATH: String = "res://scenes/FamilyHome.tscn"

const HALF_W: float = 620.0
const HALF_H: float = 440.0

const COTTAGE_SIZE: Vector2 = Vector2(150, 110)

# --- Family house sprites (Run 150) ------------------------------------------
# Each family has a hand-drawn house PNG in the Family Houses folder.
# All houses scale to a visual footprint of ~210×150 (slightly larger than the
# old procedural COTTAGE_SIZE box). Per-house tuning: scale, collision size,
# and sprite Y-offset (so the door/base sits at the interact zone).
#
# Layout: { path, scale, col_size, sprite_y }
#   path     — res:// texture path
#   scale    — uniform scale so the sprite is ~210px wide on screen
#   col_size — collision rect covering the solid wall section (not roof/stilts)
#   sprite_y — vertical offset so the base/door aligns with the interact zone
const _HOUSE_FOLDER := "res://Assets/Sprites/Families/Family Houses/"
const HOUSE_DB: Dictionary = {
	"Apple":      {"w": 2298, "h": 1693, "scale": 0.115, "col": Vector2(210, 105), "sy": -26.0},
	"Banana":     {"w": 2669, "h": 1536, "scale": 0.100, "col": Vector2(210, 100), "sy": -20.0},
	"Broccoli":   {"w": 2358, "h": 1728, "scale": 0.112, "col": Vector2(210, 105), "sy": -26.0},
	"Carrot":     {"w": 2355, "h": 1728, "scale": 0.112, "col": Vector2(210, 105), "sy": -26.0},
	"Coconut":    {"w": 2237, "h": 1728, "scale": 0.118, "col": Vector2(210, 100), "sy": -24.0},
	"Grape":      {"w": 2709, "h": 1460, "scale": 0.100, "col": Vector2(218, 100), "sy": -18.0},
	"Onion":      {"w": 2263, "h": 1728, "scale": 0.115, "col": Vector2(208, 105), "sy": -26.0},
	"Pepper":     {"w": 2293, "h": 1728, "scale": 0.115, "col": Vector2(208, 105), "sy": -26.0},
	"Potato":     {"w": 2765, "h": 1535, "scale": 0.098, "col": Vector2(214, 100), "sy": -18.0},
	"Watermelon": {"w": 2445, "h": 1533, "scale": 0.108, "col": Vector2(210, 100), "sy": -18.0},
}

var _biome_id: String = ""
var _biome: Dictionary = {}
var _interactables: Array = []
var _busy: bool = false
var _layout: RefCounted = null   # DreamLayout, opened up for daytime


func _ready() -> void:
	RunState.dream_world_mode = false
	_biome_id = RunState.day_visit_biome
	if _biome_id == "" or not DB.BIOMES.has(_biome_id):
		push_error("[DayBiomeRoom] No day_visit_biome set — returning to Town Square.")
		_biome_id = "beach"
	_biome = DB.get_biome(_biome_id)

	MusicManager.play_area(_biome_id)

	# Run 118: real biome terrain — the SAME tilesets/props/star-island shape
	# as the night arenas (sand+sea, mire, jungle floor, snow, cavern lava),
	# just RELATIVELY OPEN (lattice stripped to natural obstacles) and safe
	# (no traps, no enemies, no night overlay).
	y_sort_enabled = true
	_build_biome_terrain()

	_build_title()
	_build_return_gate()
	_build_cottages()

	_place_heroes()
	_setup_day_mode.call_deferred()

	FX.fade_from_black(0.5)


func _build_title() -> void:
	# Run 146 — replaced floating CanvasLayer label with framed HintPopup.
	const HINT = preload("res://scripts/HintPopup.gd")
	var fams: Array = RunState.FAMILY_HOMES.get(_biome_id, [])
	var fam_str: String = " & ".join(PackedStringArray(fams))
	HINT.show_hint(self, "%s — Daytime" % String(_biome["display"]),
		"Home of the %s Families  •  Visit their cottages to chat  •  Walk to the gate to return" % fam_str)


# ---------------------------------------------------------------------------
# Run 118 — real biome terrain (the night pipeline, daytime-tuned)
# ---------------------------------------------------------------------------
# Same DreamLayout → DreamTerrain → *Tileset chain as DreamRoom, so the day
# version of each biome uses the exact art its night arenas use. Differences:
#   * layout.make_day_open() strips the barrier lattice to scattered natural
#     obstacles, drops hazard pools, and clears the cottage yards + gate.
#   * The starry night-space backdrop swaps for a bright day-sky fill.
#   * No TrapZones spawn; caverns lava rivers BLOCK instead of burning
#     (nothing hurts in the day, and harmlessly wading lava would read wrong).
#   * Mountain day is always the outdoor snowfield (never the cave rooms).

func _build_biome_terrain() -> void:
	var half := Vector2(HALF_W, HALF_H)
	var seed_val: int = hash(_biome_id) * 31 + 900   # stable per biome, own family
	var exit_dir: Vector2 = (_biome["exit_dir"] as Vector2)
	if exit_dir == Vector2.ZERO:
		exit_dir = Vector2(0, 1)
	var toward_town: Vector2 = (-exit_dir).normalized()
	var gate_ws: Array = [_wall_gate_pos(toward_town)]

	_layout = DL.new()
	_layout.generate(half, toward_town, seed_val, 2, _biome, gate_ws, 1, _biome_id)
	var clear_spots: Array = [_town_side_pos()]
	for pos in _cottage_positions():
		clear_spots.append(pos)
		clear_spots.append((pos as Vector2) + Vector2(0, COTTAGE_SIZE.y * 0.5 + 110))   # yard (bigger houses)
	_layout.make_day_open(clear_spots)

	# Same terrain baker as the night arenas — mid-arm island, never the tip.
	# Day mountain is always the outdoor snowfield; shield the build from any
	# leftover night cave state, then restore it.
	var prev_peak: String = RunState.peak_room_type
	RunState.peak_room_type = "open"
	DT.build(self, _biome_id, _biome, half, seed_val, 0.35, "ocean",
		_layout, toward_town, false, gate_ws)
	RunState.peak_room_type = prev_peak

	# Daytime sky: swap the night-space backdrop for a bright fill the ocean's
	# faded outer edges blend into.
	var starry: Node = get_node_or_null("StarryBackdrop")
	if starry != null:
		starry.queue_free()
	DAY.make_backdrop(self, half + Vector2(DT.OCEAN_MARGIN, DT.OCEAN_MARGIN), _day_sky_color())

	# Solid outer boundary; the flat visuals hide when a real wall frame loads.
	DAY.make_border_walls(self, half, (_biome["wall"] as Color))
	var real_walls: Node2D = null
	if _biome_id == "beach" and DT.beach_walls_available():
		real_walls = DT.make_beach_walls(half, toward_town, gate_ws, seed_val)
	elif _biome_id == "swamp" and DT.swamp_walls_available():
		real_walls = DT.make_swamp_walls(half, toward_town, gate_ws, seed_val, _layout)
	elif _biome_id == "caverns" and DT.caverns_walls_available():
		real_walls = DT.make_caverns_walls(half, toward_town, gate_ws, seed_val, _layout)
	elif _biome_id == "peaks" and DT.peaks_walls_available():
		real_walls = DT.make_peaks_walls(half, toward_town, gate_ws, seed_val, _layout, false, ["open"])
	elif _biome_id == "jungle" and DT.jungle_walls_available():
		real_walls = DT.make_jungle_walls(half, toward_town, gate_ws, seed_val, _layout)
	elif BW.available():
		real_walls = BW.make_walls(half, gate_ws, seed_val)
	if real_walls != null:
		var day_walls: Node = get_node_or_null("DayWalls")
		if day_walls != null:
			for w in day_walls.get_children():
				for ch in w.get_children():
					if ch is ColorRect:
						(ch as CanvasItem).visible = false
		add_child(real_walls)

	_build_layout_collision()
	_apply_day_atmosphere()


# Gate opening projected onto the town-side wall, aligned with the return-gate
# structure (so the wall art frames a path out toward town).
func _wall_gate_pos(toward_town: Vector2) -> Vector2:
	var p: Vector2 = _town_side_pos()
	if absf(toward_town.y) >= absf(toward_town.x):
		return Vector2(p.x, signf(toward_town.y) * (HALF_H + 16.0))
	return Vector2(signf(toward_town.x) * (HALF_W + 16.0), p.y)


# Bright day haze past the sea — biome-tinted; caves keep a dark molten dusk.
func _day_sky_color() -> Color:
	if _biome_id == "caverns":
		return Color(0.16, 0.09, 0.09)
	return Color(0.55, 0.75, 0.92).lerp((_biome["accent"] as Color), 0.12)


# Collision for the layout — the DreamRoom recipe, minus every hazard:
#   * interior obstacle cells → solid, dash-phaseable ("dashable_barrier")
#   * Frostpeak frozen water  → walkable + slippery (IceField, like night)
#   * every other river (murk / jungle water / LAVA) → blocking water collider
func _build_layout_collision() -> void:
	if _layout == null:
		return
	var runs: Array = _layout.void_runs()
	if not runs.is_empty():
		var body := StaticBody2D.new()
		body.name = "LayoutColliders"
		body.collision_layer = 1
		body.collision_mask = 0
		body.add_to_group("dashable_barrier")
		for run in runs:
			var cs := CollisionShape2D.new()
			var sh := RectangleShape2D.new()
			sh.size = run.size
			cs.shape = sh
			cs.position = run.pos
			body.add_child(cs)
		add_child(body)
	var wruns: Array = _layout.water_runs()
	if wruns.is_empty():
		return
	if _biome_id == "peaks":
		var ice: Area2D = IF.new()
		ice.setup(wruns)
		add_child(ice)
		return
	var water := StaticBody2D.new()
	water.name = "WaterColliders"
	water.collision_layer = 1
	water.collision_mask = 0
	water.add_to_group("water_collider")
	water.add_to_group("dashable_barrier")
	for run2 in wruns:
		var cs2 := CollisionShape2D.new()
		var sh2 := RectangleShape2D.new()
		sh2.size = run2.size
		cs2.shape = sh2
		cs2.position = run2.pos
		water.add_child(cs2)
	add_child(water)


# Light daytime atmosphere — matches the night arenas' character without the
# night tint: gentle snowfall on the mountain, canopy vines in the jungle.
func _apply_day_atmosphere() -> void:
	if _biome_id == "peaks":
		var snow: Node2D = load("res://scripts/SnowOverlay.gd").new()
		snow.name = "SnowOverlay"
		snow.set_intensity(0.22)
		add_child(snow)
	elif _biome_id == "jungle":
		var vines: CanvasLayer = load("res://scripts/JungleVineOverlay.gd").new()
		vines.name = "JungleVineOverlay"
		add_child(vines)


# ---------------------------------------------------------------------------
# Return gate — on the side FACING town (inverse of the biome's exit_dir)
# ---------------------------------------------------------------------------

func _town_side_pos() -> Vector2:
	var dir: Vector2 = (_biome["exit_dir"] as Vector2)
	var toward_town: Vector2 = (-dir).normalized() if dir != Vector2.ZERO else Vector2(0, 1)
	return Vector2(toward_town.x * (HALF_W - 90), toward_town.y * (HALF_H - 80))


func _build_return_gate() -> void:
	var gate := Node2D.new()
	gate.name = "ReturnGate"
	gate.position = _town_side_pos()
	add_child(gate)

	# Run 151 — hand-drawn torii sprite (same biome variant) + portal.
	var torii := TORII.build(_biome_id, true)
	gate.add_child(torii)

	var lbl := Label.new()
	lbl.text = "Back to Town Square"
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	lbl.add_theme_constant_override("outline_size", 3)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.position = Vector2(-100, -140)
	lbl.custom_minimum_size = Vector2(200, 0)
	gate.add_child(lbl)

	_add_interactable(gate, "town", "town", "Return to Town Square")


# ---------------------------------------------------------------------------
# Cottages — one per resident family, wanderers outside, elder inside
# ---------------------------------------------------------------------------

# Two cottages on the side AWAY from the return gate, spread apart. Shared by
# _build_cottages AND the terrain pass (which force-clears these yards).
func _cottage_positions() -> Array:
	var away: Vector2 = -_town_side_pos().normalized()
	# Run 150: pulled inward so bigger house sprites + yards stay on-screen.
	var base: Vector2 = away * Vector2(HALF_W - 310, HALF_H - 290)
	var spread: Vector2 = Vector2(-away.y, away.x).normalized() * 250.0
	if spread == Vector2.ZERO:
		spread = Vector2(250, 0)
	var a: Vector2 = base - spread
	var b: Vector2 = base + spread
	# Clamp so cottages + their yard (≈120px south of pos) stay inside the arena.
	var x_lim: float = HALF_W - 180.0
	var y_lim: float = HALF_H - 200.0   # generous north margin for yard below house
	a.x = clampf(a.x, -x_lim, x_lim)
	a.y = clampf(a.y, -HALF_H + 140.0, y_lim)
	b.x = clampf(b.x, -x_lim, x_lim)
	b.y = clampf(b.y, -HALF_H + 140.0, y_lim)
	return [a, b]


func _build_cottages() -> void:
	var fams: Array = RunState.FAMILY_HOMES.get(_biome_id, [])
	var spots: Array = _cottage_positions()
	for i in range(fams.size()):
		var fam: String = String(fams[i])
		_build_cottage(fam, spots[i % spots.size()] as Vector2)


func _build_cottage(fam: String, pos: Vector2) -> void:
	var house_path: String = _HOUSE_FOLDER + fam + "_House.png"
	if HOUSE_DB.has(fam) and ResourceLoader.exists(house_path):
		_build_sprite_cottage(fam, pos, house_path)
		return
	_build_procedural_cottage(fam, pos)


# ---------------------------------------------------------------------------
# Sprite-based cottage — all families with house art (Run 150)
# ---------------------------------------------------------------------------

func _build_sprite_cottage(fam: String, pos: Vector2, house_path: String) -> void:
	var fam_col: Color = (RunState.FAM_COLOR as Dictionary).get(fam, Color(0.6, 0.6, 0.6))
	var info: Dictionary = HOUSE_DB[fam]
	var sc: float = float(info["scale"])
	var col_size: Vector2 = info["col"] as Vector2
	var sprite_y: float = float(info["sy"])
	var src_h: float = float(info["h"])

	var hut := Node2D.new()
	hut.name = "Cottage_%s" % fam
	hut.position = pos
	add_child(hut)

	# Collision — covers the solid wall section only.
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var cs := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = col_size
	cs.shape = shape
	cs.position = Vector2(0, sprite_y + 4.0)
	body.add_child(cs)
	hut.add_child(body)

	# House sprite.
	var tex: Texture2D = load(house_path)
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.scale = Vector2(sc, sc)
	spr.position.y = sprite_y
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.z_index = -2
	hut.add_child(spr)

	# Plaque — sits above the roof peak.
	var roof_peak_y: float = sprite_y - (src_h * sc * 0.5)
	var plaque := Label.new()
	plaque.text = "The %s Family" % fam
	plaque.add_theme_font_size_override("font_size", 12)
	plaque.add_theme_color_override("font_color", fam_col.lightened(0.30))
	plaque.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	plaque.add_theme_constant_override("outline_size", 3)
	plaque.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	plaque.position = Vector2(-80, roof_peak_y - 20)
	plaque.custom_minimum_size = Vector2(160, 0)
	plaque.z_index = 4
	hut.add_child(plaque)

	# Door interact zone — at the base of the house (sand/ground level).
	var base_bottom_y: float = sprite_y + (src_h * sc * 0.5)
	var door_host := Node2D.new()
	door_host.position = pos + Vector2(0, base_bottom_y + 14)
	add_child(door_host)
	_add_interactable(door_host, "home", fam, "Visit the %s family" % fam)

	# Family members — spread in the yard below the house.
	# Run 150 (Bruno fix 12): pushed further from the door (was +50) so their
	# 60px interact zones no longer overlap the door zone.
	var tier: int = RunState.get_family_tier(fam)
	var names: Array = FL.wanderer_names(fam)
	var yard_y: float = base_bottom_y + 96
	for i in range(names.size()):
		var walker: Node2D = NPC.new()
		var x_off: float = -90.0 + 180.0 * float(i) / maxf(float(names.size() - 1), 1.0) if names.size() > 1 else 0.0
		walker.position = pos + Vector2(x_off, yard_y)
		add_child(walker)
		walker.setup(fam, String(names[i]), false)
		walker.set_tier(tier)
		_add_interactable(walker, "member", fam + "|" + String(names[i]),
			"Talk to %s" % String(names[i]))


# ---------------------------------------------------------------------------
# Procedural cottage — all other families (unchanged from Run 147)
# ---------------------------------------------------------------------------

func _build_procedural_cottage(fam: String, pos: Vector2) -> void:
	var fam_col: Color = (RunState.FAM_COLOR as Dictionary).get(fam, Color(0.6, 0.6, 0.6))
	var hut := Node2D.new()
	hut.name = "Cottage_%s" % fam
	hut.position = pos
	add_child(hut)

	# Solid body.
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var cs := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = COTTAGE_SIZE
	cs.shape = shape
	body.add_child(cs)
	hut.add_child(body)

	# Walls (biome-toned) + family-colored roof + door.
	var walls := ColorRect.new()
	walls.offset_left = -COTTAGE_SIZE.x * 0.5
	walls.offset_top = -COTTAGE_SIZE.y * 0.5
	walls.offset_right = COTTAGE_SIZE.x * 0.5
	walls.offset_bottom = COTTAGE_SIZE.y * 0.5
	walls.color = (_biome["wall"] as Color).lightened(0.22)
	walls.z_index = -2
	hut.add_child(walls)

	var roof := Polygon2D.new()
	roof.polygon = PackedVector2Array([
		Vector2(-COTTAGE_SIZE.x * 0.60, -COTTAGE_SIZE.y * 0.5 + 10),
		Vector2(0, -COTTAGE_SIZE.y * 0.5 - 46),
		Vector2(COTTAGE_SIZE.x * 0.60, -COTTAGE_SIZE.y * 0.5 + 10),
	])
	roof.color = fam_col.darkened(0.25)
	roof.z_index = 3
	hut.add_child(roof)

	var door := ColorRect.new()
	door.offset_left = -13
	door.offset_top = COTTAGE_SIZE.y * 0.5 - 38
	door.offset_right = 13
	door.offset_bottom = COTTAGE_SIZE.y * 0.5
	door.color = Color(0.18, 0.12, 0.09)
	door.z_index = -1
	hut.add_child(door)

	var plaque := Label.new()
	plaque.text = "The %s Family" % fam
	plaque.add_theme_font_size_override("font_size", 12)
	plaque.add_theme_color_override("font_color", fam_col.lightened(0.30))
	plaque.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	plaque.add_theme_constant_override("outline_size", 3)
	plaque.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	plaque.position = Vector2(-80, -COTTAGE_SIZE.y * 0.5 - 74)
	plaque.custom_minimum_size = Vector2(160, 0)
	plaque.z_index = 4
	hut.add_child(plaque)

	# Door interact zone just outside the south face.
	var door_host := Node2D.new()
	door_host.position = pos + Vector2(0, COTTAGE_SIZE.y * 0.5 + 24)
	add_child(door_host)
	_add_interactable(door_host, "home", fam, "Visit the %s family" % fam)

	# Family members in the yard (the elder stays inside).
	# Run 147: static placement — no wandering for now (better walk frames later).
	# Children/siblings stand outside the cottage, spread evenly.
	var tier: int = RunState.get_family_tier(fam)
	var names: Array = FL.wanderer_names(fam)
	for i in range(names.size()):
		var walker: Node2D = NPC.new()
		# Spread children in front of the cottage door.
		# Run 150 (Bruno fix 12): pushed further out (+60 → +104) so their
		# interact zones no longer swallow the door zone.
		var x_off: float = -60.0 + 120.0 * float(i) / maxf(float(names.size() - 1), 1.0) if names.size() > 1 else 0.0
		walker.position = pos + Vector2(x_off, COTTAGE_SIZE.y * 0.5 + 104)
		add_child(walker)
		walker.setup(fam, String(names[i]), false)
		walker.set_tier(tier)
		# Static — no enable_wander call. Still talkable.
		_add_interactable(walker, "member", fam + "|" + String(names[i]),
			"Talk to %s" % String(names[i]))


# ---------------------------------------------------------------------------
# Heroes
# ---------------------------------------------------------------------------

func _place_heroes() -> void:
	var hint: String = RunState.day_spawn_hint
	RunState.day_spawn_hint = ""
	var spawn: Vector2 = _town_side_pos() + _town_side_pos().normalized() * -70.0
	if hint == "from_home" and RunState.day_visit_family != "":
		var hut := get_node_or_null("Cottage_%s" % RunState.day_visit_family)
		if hut != null:
			var exit_y: float = COTTAGE_SIZE.y * 0.5 + 52
			if HOUSE_DB.has(RunState.day_visit_family):
				var info: Dictionary = HOUSE_DB[RunState.day_visit_family]
				exit_y = float(info["sy"]) + (float(info["h"]) * float(info["scale"]) * 0.5) + 52
			spawn = (hut as Node2D).position + Vector2(0, exit_y)
	RunState.day_visit_family = ""
	var pl := get_node_or_null("Player")
	if pl:
		pl.position = spawn + Vector2(-26, 0)
	var be := get_node_or_null("Bea")
	if be:
		be.position = spawn + Vector2(26, 0)


func _setup_day_mode() -> void:
	for p in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(p):
			continue
		if "dojo_mode" in p:
			p.dojo_mode = true
			p.dojo_wait_pos = Vector2(70 if p.is_in_group("bea") else -70, 0)


# ---------------------------------------------------------------------------
# Interactables (DreamHub pattern)
# ---------------------------------------------------------------------------

func _add_interactable(host: Node2D, kind: String, id: String, action: String) -> void:
	var zone := Area2D.new()
	zone.collision_layer = 0
	zone.collision_mask = 2
	var shape := CircleShape2D.new()
	shape.radius = 60.0
	var cs := CollisionShape2D.new()
	cs.shape = shape
	zone.add_child(cs)
	host.add_child(zone)

	var prompt := Label.new()
	InputGlyphs.bind_label(prompt, "[{interact}] %s" % action)   # Run 158 — live device glyph
	prompt.add_theme_font_size_override("font_size", 14)
	prompt.add_theme_color_override("font_color", Color(1.0, 1.0, 0.7))
	prompt.add_theme_color_override("font_outline_color", Color(0.05, 0.05, 0.0))
	prompt.add_theme_constant_override("outline_size", 3)
	prompt.position = Vector2(-80, -56)
	prompt.visible = false
	prompt.z_index = 20
	host.add_child(prompt)

	var entry: Dictionary = {"zone": zone, "kind": kind, "id": id, "prompt": prompt, "in_range": false}
	zone.body_entered.connect(func(body: Node) -> void:
		if _is_active_player(body):
			entry.in_range = true
			prompt.visible = true)
	zone.body_exited.connect(func(body: Node) -> void:
		if _is_active_player(body):
			entry.in_range = false
			prompt.visible = false)
	_interactables.append(entry)


func _is_active_player(body: Node) -> bool:
	if body.is_in_group("player") and not body.is_in_group("bea"):
		return true
	if body.is_in_group("bea") and body.get("player_controlled") == true:
		return true
	return false


func _unhandled_input(event: InputEvent) -> void:
	if _busy:
		return
	if not event.is_action_pressed("interact") or event.is_echo():
		return
	# Run 150 (Bruno fix 12): pick the NEAREST in-range interactable instead of
	# the first-registered one. Door zones register before family members, so
	# standing next to an NPC that overlapped the door radius used to walk you
	# into the house instead of starting the chat.
	var hero: Node2D = _controlled_hero_node()
	var best: Dictionary = {}
	var best_d: float = INF
	for entry in _interactables:
		if not bool(entry.in_range):
			continue
		var zone: Node = entry.get("zone")
		var d: float = 0.0
		if hero != null and zone is Node2D:
			d = hero.global_position.distance_to((zone as Node2D).global_position)
		if d < best_d:
			best_d = d
			best = entry
	if best.is_empty():
		return
	match String(best.kind):
		"town": _return_to_town()
		"home": _enter_home(String(best.id))
		"member": _talk_to_member(String(best.id), best)


# ---------------------------------------------------------------------------
# Transitions
# ---------------------------------------------------------------------------

func _return_to_town() -> void:
	_busy = true
	RunState.day_spawn_hint = "from_biome_%s" % _biome_id
	FX.fade_to_black(0.4, 0.05, 1.0, Callable(self, "_goto_town"))


func _goto_town() -> void:
	get_tree().change_scene_to_file(TOWN_PATH)


func _enter_home(fam: String) -> void:
	_busy = true
	RunState.day_visit_family = fam
	Log.dbg("[DayBiomeRoom] Entering the %s family home." % fam)
	FX.fade_to_black(0.35, 0.05, 1.0, Callable(self, "_goto_home"))


func _goto_home() -> void:
	get_tree().change_scene_to_file(HOME_PATH)


# ---------------------------------------------------------------------------
# Wanderer chat — a rotating daily-style line from the non-elder member
# (see FamilyLore.member_line). No karma changes hands here; the elder inside
# the hut is still the only karma drop-off. The walker pauses while we talk.
# ---------------------------------------------------------------------------

func _talk_to_member(id: String, entry: Dictionary) -> void:
	var bits: PackedStringArray = id.split("|")
	if bits.size() < 2:
		return
	var fam: String = bits[0]
	var who: String = bits[1]
	var tier: int = RunState.get_family_tier(fam)
	var hero_name: String = _controlled_hero_name()
	var visit: int = int(RunState.member_visits.get(id, 0))

	var line: String = FL.member_line(fam, who, tier, visit, hero_name)
	RunState.member_visits[id] = visit + 1

	# Stop the walker mid-stroll so they hold their spot through the chat.
	var walker: Node = (entry.get("zone") as Node)
	if walker != null:
		walker = walker.get_parent()
	if walker != null and walker.has_method("hold_still"):
		walker.hold_still(4.0)

	_busy = true
	var dlg: CanvasLayer = DialogBoxScript.new_box(self)
	dlg.finished.connect(func() -> void: _busy = false)
	dlg.open(who, [line])


# Run 150 — the hero node currently under player control (for nearest-pick).
func _controlled_hero_node() -> Node2D:
	for p in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(p) and p.get("player_controlled") == true and p is Node2D:
			return p as Node2D
	for p in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(p) and p is Node2D:
			return p as Node2D
	return null


func _controlled_hero_name() -> String:
	for p in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(p) and p.get("player_controlled") == true:
			return "Bea" if p.is_in_group("bea") else "Shino"
	return "Shino"
