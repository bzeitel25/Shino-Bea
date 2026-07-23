extends Node2D

# ============================================================
# TownSquare.gd — Run 153 (2026-07-18) — waking-world Town Square
# ============================================================
# The daytime heart of Seedy City. The DOJO sits at the CENTER as
# a landmark building (Bruno's spec — not an exit direction); five
# PHYSICAL biome gates ring the outer walls at the same compass
# points the night hub uses (DreamBiomes.HUB_GATE_POS), and the
# SOUTH exit is the Carnival road (Dragon Fruit family + the rest
# of town) — sealed with festive bunting until the Carnival build.
#
# Daytime = deposit karma with the fruit/veg families in their
# biome day-rooms. No enemies, no night overlay, no sleep here —
# beds stay in the Dojo.
# ============================================================

const DB = preload("res://scripts/DreamBiomes.gd")
const DAY = preload("res://scripts/DayTerrain.gd")
# Run 143 — real-art town tileset, tier-swapped by healing progress
# (delapidated → healing → perfect; see RunState.town_visual_tier()).
const TT = preload("res://scripts/TownTileset.gd")
# Run 151 — hand-drawn torii gate sprites + swirling portal effects.
const TORII = preload("res://scripts/ToriiGate.gd")

const DOJO_PATH: String = "res://scenes/Dojo.tscn"
const DAY_ROOM_PATH: String = "res://scenes/DayBiomeRoom.tscn"

const HALF_W: float = 710.0
const HALF_H: float = 400.0

const PLAZA_COLOR: Color     = Color(0.62, 0.56, 0.48)   # warm daylight cobbles
const PLAZA_ALT_COLOR: Color = Color(0.67, 0.61, 0.52)
const WALL_COLOR: Color      = Color(0.48, 0.40, 0.30)
const SKY_COLOR: Color       = Color(0.55, 0.72, 0.62)   # sunny green beyond the walls

const DOJO_BODY_SIZE: Vector2 = Vector2(430, 265)   # visual/keepout footprint
const DOJO_CENTER: Vector2 = Vector2(0, -60)
const DOJO_ENTRANCE_W: float = 70.0      # walkable front hallway width
const DOJO_ENTRANCE_D: float = 80.0      # hallway depth (south face inward)
# Collision sits inside the rock ring, not at the full sprite edge.
# Players walk right up to the stones, then stop.
const _DOJO_COL_W: float = 330.0         # collision width (inside rock ring ~±165)
const _DOJO_COL_NORTH_INSET: float = 30.0  # let players walk a bit closer behind

# --- Dojo building sprite (Run 153) ------------------------------------------
const _DOJO_SPRITE_PATH := "res://Assets/Sprites/Families/Family Houses/Dojo_Building.png"
const _DOJO_SPRITE_W: float = 2816.0
const _DOJO_SPRITE_H: float = 1536.0
const _DOJO_SCALE: float = 0.205         # 2816*0.205 ≈ 577 wide — large town centerpiece
const _DOJO_SPRITE_Y: float = -38.0      # nudge up so zen garden base meets the doorstep

var _interactables: Array = []   # [{zone, kind, id, prompt, in_range}]
var _busy: bool = false

var _hint_lbl: Label = null


func _ready() -> void:
	RunState.dream_world_mode = false
	MusicManager.play_area("town")

	# Run 143 — global foot-Y sorting so heroes weave between the placed props
	# (same rule as DreamRoom / DayBiomeRoom).
	y_sort_enabled = true

	var tier: int = RunState.town_visual_tier()
	print("[TownSquare] Town visual tier: %d (0=delap 1=healing 2=perfect)." % tier)

	DAY.make_backdrop(self, Vector2(HALF_W, HALF_H), _sky_for_tier(tier))
	DAY.make_ground(self, Vector2(HALF_W, HALF_H), PLAZA_COLOR, PLAZA_ALT_COLOR, 11700)
	DAY.make_border_walls(self, Vector2(HALF_W, HALF_H), WALL_COLOR, true)
	# Real-art overlays (baked over the flat fallback; fallback stays if art missing).
	TT.build_ground(self, Vector2(HALF_W, HALF_H), tier, 11700)
	TT.facade_strip(self, Vector2(HALF_W, HALF_H), tier)

	_build_dojo_landmark()
	_build_biome_gates()
	_build_carnival_exit()
	TT.build_props(self, Vector2(HALF_W, HALF_H), tier, _prop_keepouts())
	_build_hint_label()

	_place_heroes()
	_setup_day_mode.call_deferred()

	FX.fade_from_black(0.5)

	# Run 146 — framed beginner tooltip.
	const HINT = preload("res://scripts/HintPopup.gd")
	HINT.show_hint(self, "Town Square — Starfruit Island",
		"Talk to the townsfolk  •  Walk through a gate to visit a biome  •  Enter the Dojo to sleep")


# Run 143 — daylight mood tracks the town's healing tier.
func _sky_for_tier(tier: int) -> Color:
	match tier:
		2:  return Color(0.58, 0.78, 0.66)   # Perfect — vivid summer green
		1:  return SKY_COLOR                  # Healing — the original sunny green
		_:  return Color(0.46, 0.54, 0.50)   # Delapidated — washed-out overcast


# Run 143 — circles the placed props must keep clear: every gate mouth, the
# carnival arch, the Dojo landmark + its doorstep, and the hero spawn strip.
func _prop_keepouts() -> Array:
	var ko: Array = [
		{"pos": DOJO_CENTER, "r": 310.0},
		{"pos": DOJO_CENTER + Vector2(0, DOJO_BODY_SIZE.y * 0.5 + 40), "r": 130.0},
		{"pos": Vector2(0, HALF_H - 46), "r": 140.0},
	]
	for biome_id in DB.BIOME_ORDER:
		var raw: Vector2 = DB.HUB_GATE_POS[biome_id]
		ko.append({"pos": Vector2(
			clamp(raw.x, -HALF_W + 10, HALF_W - 10),
			clamp(raw.y, -HALF_H + 10, HALF_H - 10)), "r": 135.0})
	return ko


# ---------------------------------------------------------------------------
# Heroes — spawn placement + relaxed dojo-style AI for the companion
# ---------------------------------------------------------------------------

func _place_heroes() -> void:
	var hint: String = RunState.day_spawn_hint
	RunState.day_spawn_hint = ""
	var spawn: Vector2 = DOJO_CENTER + Vector2(0, DOJO_BODY_SIZE.y * 0.5 + 56)  # front sand outside entrance
	if hint.begins_with("from_biome_"):
		var biome_id: String = hint.trim_prefix("from_biome_")
		if DB.HUB_GATE_POS.has(biome_id):
			var gp: Vector2 = DB.HUB_GATE_POS[biome_id]
			spawn = Vector2(
				clamp(gp.x, -HALF_W + 40, HALF_W - 40),
				clamp(gp.y, -HALF_H + 40, HALF_H - 40))
			spawn += spawn.normalized() * -70.0   # step inward off the gate
	var pl := get_node_or_null("Player")
	if pl:
		pl.position = spawn + Vector2(-26, 0)
	var be := get_node_or_null("Bea")
	if be:
		be.position = spawn + Vector2(26, 0)


func _setup_day_mode() -> void:
	# Same relaxed behavior as the Dojo: the uncontrolled hero idles at a
	# spot instead of combat-following. Swap (Q+Q / LB) works as usual.
	for p in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(p):
			continue
		if "dojo_mode" in p:
			p.dojo_mode = true
			p.dojo_wait_pos = DOJO_CENTER + Vector2(100 if p.is_in_group("bea") else -100, 220)


# ---------------------------------------------------------------------------
# Build — central Dojo landmark
# ---------------------------------------------------------------------------

func _build_dojo_landmark() -> void:
	# Run 153 — enlarged Dojo with walkable entrance hallway + proper y-sort
	# depth: walking BEHIND (north of) the building renders the hero behind
	# the roof; walking in FRONT (south, on the sand) renders them in front.
	# The sprite lives in a y-sorted wrapper anchored at the building's
	# south foot line so the global y-sort (TownSquare.y_sort_enabled)
	# handles the overlap automatically — same rule as every other prop.

	var dojo := Node2D.new()
	dojo.name = "DojoLandmark"
	dojo.position = DOJO_CENTER
	dojo.y_sort_enabled = true   # children join the global y-sort pool
	add_child(dojo)

	var half_w: float = DOJO_BODY_SIZE.x * 0.5   # visual half-width (keepouts)
	var half_h: float = DOJO_BODY_SIZE.y * 0.5
	var ent_hw: float = DOJO_ENTRANCE_W * 0.5
	var south_face_y: float = half_h
	# Collision fits inside the rock ring — narrower than the sprite.
	var col_hw: float = _DOJO_COL_W * 0.5
	var col_north: float = -half_h + _DOJO_COL_NORTH_INSET  # north edge pulled in

	# --- Collision: three body pieces + door barrier -------------------------
	# Main body — covers the building above the entrance, sized to the rock
	# ring so players can walk right up to the stones on east/west/north.
	var main_body := StaticBody2D.new()
	main_body.collision_layer = 1
	main_body.collision_mask = 0
	var main_cs := CollisionShape2D.new()
	var main_shape := RectangleShape2D.new()
	var main_top: float = col_north
	var main_bot: float = south_face_y - DOJO_ENTRANCE_D
	var main_h: float = main_bot - main_top
	main_shape.size = Vector2(_DOJO_COL_W, main_h)
	main_cs.shape = main_shape
	main_cs.position.y = main_top + main_h * 0.5
	main_body.add_child(main_cs)
	dojo.add_child(main_body)

	# Left wall of entrance hallway.
	var left_wall := StaticBody2D.new()
	left_wall.collision_layer = 1
	left_wall.collision_mask = 0
	var lw_cs := CollisionShape2D.new()
	var lw_shape := RectangleShape2D.new()
	var side_w: float = col_hw - ent_hw
	lw_shape.size = Vector2(side_w, DOJO_ENTRANCE_D)
	lw_cs.shape = lw_shape
	lw_cs.position = Vector2(-ent_hw - side_w * 0.5, south_face_y - DOJO_ENTRANCE_D * 0.5)
	left_wall.add_child(lw_cs)
	dojo.add_child(left_wall)

	# Right wall of entrance hallway.
	var right_wall := StaticBody2D.new()
	right_wall.collision_layer = 1
	right_wall.collision_mask = 0
	var rw_cs := CollisionShape2D.new()
	var rw_shape := RectangleShape2D.new()
	rw_shape.size = Vector2(side_w, DOJO_ENTRANCE_D)
	rw_cs.shape = rw_shape
	rw_cs.position = Vector2(ent_hw + side_w * 0.5, south_face_y - DOJO_ENTRANCE_D * 0.5)
	right_wall.add_child(rw_cs)
	dojo.add_child(right_wall)

	# Door barrier — blocks player AT the door inside the hallway.
	var door_bar := StaticBody2D.new()
	door_bar.collision_layer = 1
	door_bar.collision_mask = 0
	var db_cs := CollisionShape2D.new()
	var db_shape := RectangleShape2D.new()
	db_shape.size = Vector2(DOJO_ENTRANCE_W, 10.0)
	db_cs.shape = db_shape
	db_cs.position = Vector2(0, south_face_y - DOJO_ENTRANCE_D)
	door_bar.add_child(db_cs)
	dojo.add_child(door_bar)

	# --- Sprite: y-sort anchored at the DOOR line ----------------------------
	# The wrapper sits at the back of the entrance hallway (the door).
	# Heroes in the hallway or on the sand (south of the door) render IN
	# FRONT; heroes walking behind the building (north of the door) render
	# BEHIND the roof. This is the correct anchor because the hallway is
	# walkable — anchoring at the south face would put hallway-walkers
	# behind the sprite.
	var door_sort_y: float = south_face_y - DOJO_ENTRANCE_D
	var sprite_wrap := Node2D.new()
	sprite_wrap.name = "DojoSpriteWrap"
	sprite_wrap.position.y = door_sort_y
	sprite_wrap.z_as_relative = false
	sprite_wrap.z_index = 0
	dojo.add_child(sprite_wrap)

	if ResourceLoader.exists(_DOJO_SPRITE_PATH):
		var tex: Texture2D = load(_DOJO_SPRITE_PATH)
		var spr := Sprite2D.new()
		spr.texture = tex
		spr.scale = Vector2(_DOJO_SCALE, _DOJO_SCALE)
		# Position the sprite so its visual bottom sits correctly. The wrapper
		# is at the door line (south_face - entrance_depth), so offset the
		# sprite relative to that anchor.
		spr.position.y = _DOJO_SPRITE_Y - door_sort_y
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		sprite_wrap.add_child(spr)
	else:
		# Fallback positioned relative to door_sort_y anchor.
		var fb_foot_off: float = south_face_y - door_sort_y   # entrance depth below anchor
		var walls := ColorRect.new()
		walls.offset_left = -half_w
		walls.offset_top = -DOJO_BODY_SIZE.y + fb_foot_off
		walls.offset_right = half_w
		walls.offset_bottom = fb_foot_off
		walls.color = Color(0.42, 0.30, 0.20)
		sprite_wrap.add_child(walls)
		var roof := Polygon2D.new()
		roof.polygon = PackedVector2Array([
			Vector2(-half_w * 1.24, -DOJO_BODY_SIZE.y + fb_foot_off + 14),
			Vector2(0, -DOJO_BODY_SIZE.y + fb_foot_off - 64),
			Vector2(half_w * 1.24, -DOJO_BODY_SIZE.y + fb_foot_off + 14),
		])
		roof.color = Color(0.30, 0.18, 0.14)
		sprite_wrap.add_child(roof)
		var door := ColorRect.new()
		door.offset_left = -ent_hw
		door.offset_top = 0
		door.offset_right = ent_hw
		door.offset_bottom = fb_foot_off
		door.color = Color(0.16, 0.11, 0.08)
		sprite_wrap.add_child(door)

	# Sign label above the roof peak.
	var sprite_h_world: float = _DOJO_SPRITE_H * _DOJO_SCALE
	var roof_peak_y: float = _DOJO_SPRITE_Y - sprite_h_world * 0.5
	var sign_lbl := Label.new()
	sign_lbl.text = "THE DOJO"
	sign_lbl.add_theme_font_size_override("font_size", 16)
	sign_lbl.add_theme_color_override("font_color", Color(0.95, 0.88, 0.65))
	sign_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	sign_lbl.add_theme_constant_override("outline_size", 3)
	sign_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sign_lbl.position = Vector2(-60, roof_peak_y - door_sort_y - 22)
	sign_lbl.custom_minimum_size = Vector2(120, 0)
	sign_lbl.z_index = 4
	sprite_wrap.add_child(sign_lbl)

	# Door interact zone — inside the entrance hallway near the door.
	# The player walks up the sand, into the hallway, and presses interact.
	var door_host := Node2D.new()
	door_host.position = DOJO_CENTER + Vector2(0, south_face_y - DOJO_ENTRANCE_D * 0.5)
	add_child(door_host)
	_add_interactable(door_host, "dojo", "dojo", "Enter the Dojo")


# ---------------------------------------------------------------------------
# Build — biome gates (physical, compass-matched to the night hub)
# ---------------------------------------------------------------------------

func _build_biome_gates() -> void:
	for biome_id in DB.BIOME_ORDER:
		var biome: Dictionary = DB.get_biome(biome_id)
		var raw: Vector2 = DB.HUB_GATE_POS[biome_id]
		# Position flush against the perimeter wall (small margin for label room).
		var pos := Vector2(
			clamp(raw.x, -HALF_W + 10, HALF_W - 10),
			clamp(raw.y, -HALF_H + 10, HALF_H - 10))

		var gate := Node2D.new()
		gate.name = "DayGate_%s" % biome_id
		gate.position = pos
		add_child(gate)

		# Run 151 — hand-drawn torii sprite + swirling portal.
		var torii := TORII.build(biome_id, true)
		gate.add_child(torii)

		var fams: Array = RunState.FAMILY_HOMES.get(biome_id, [])
		var fam_txt: String = " & ".join(PackedStringArray(fams))
		var name_label := Label.new()
		name_label.text = "%s — %s\n%s Families" % [
			String(biome["direction"]), String(biome["display"]), fam_txt]
		name_label.add_theme_font_size_override("font_size", 13)
		name_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		name_label.add_theme_constant_override("outline_size", 3)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		# Label offset based on gate position — push inward from the wall.
		# Larger gates need the label further out to clear the torii.
		var lbl_off := Vector2(-100, -150)
		if pos.y < -HALF_H + 60:       # north wall — label below
			lbl_off = Vector2(-100, 50)
		elif pos.x > HALF_W - 60:      # east wall — label to the left
			lbl_off = Vector2(-240, -36)
		elif pos.x < -HALF_W + 60:     # west wall — label to the right
			lbl_off = Vector2(40, -36)
		name_label.position = lbl_off
		name_label.custom_minimum_size = Vector2(200, 0)
		gate.add_child(name_label)

		_add_interactable(gate, "biome", biome_id, "Walk to %s" % String(biome["display"]))



# ---------------------------------------------------------------------------
# Build — carnival exit (S) — sealed until the Carnival grounds build
# ---------------------------------------------------------------------------

func _build_carnival_exit() -> void:
	var arch := Node2D.new()
	arch.name = "CarnivalArch"
	arch.position = Vector2(0, HALF_H - 46)
	add_child(arch)

	# Run 151 — hand-drawn carnival torii + portal.
	var torii := TORII.build("carnival", true)
	arch.add_child(torii)

	var lbl := Label.new()
	lbl.text = "S — CARNIVAL ROAD\nThe Dragon Fruit troupe & the rest of town"
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", Color(0.95, 0.65, 0.75))
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	lbl.add_theme_constant_override("outline_size", 3)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.position = Vector2(-120, -150)
	lbl.custom_minimum_size = Vector2(240, 0)
	arch.add_child(lbl)

	_add_interactable(arch, "carnival", "carnival", "Peek down the road")


func _build_hint_label() -> void:
	var canvas := CanvasLayer.new()
	canvas.layer = 30
	add_child(canvas)
	_hint_lbl = Label.new()
	_hint_lbl.add_theme_font_size_override("font_size", 15)
	_hint_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.6))
	_hint_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_hint_lbl.add_theme_constant_override("outline_size", 4)
	_hint_lbl.anchor_left = 0.5
	_hint_lbl.anchor_right = 0.5
	_hint_lbl.offset_left = -260.0
	_hint_lbl.offset_right = 260.0
	_hint_lbl.offset_top = 46.0
	_hint_lbl.offset_bottom = 72.0
	_hint_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_lbl.text = ""
	canvas.add_child(_hint_lbl)


func _flash_hint(msg: String) -> void:
	if _hint_lbl == null:
		return
	_hint_lbl.text = msg
	var tw: Tween = create_tween()
	tw.tween_interval(2.4)
	tw.tween_callback(func() -> void:
		if is_instance_valid(_hint_lbl):
			_hint_lbl.text = "")


# ---------------------------------------------------------------------------
# Interactables — proximity + [E] (DreamHub pattern)
# ---------------------------------------------------------------------------

func _add_interactable(host: Node2D, kind: String, id: String, action: String) -> void:
	var zone := Area2D.new()
	zone.collision_layer = 0
	zone.collision_mask = 2
	var shape := CircleShape2D.new()
	shape.radius = 64.0
	var cs := CollisionShape2D.new()
	cs.shape = shape
	zone.add_child(cs)
	host.add_child(zone)

	var prompt := Label.new()
	prompt.text = "[E] %s" % action
	prompt.add_theme_font_size_override("font_size", 14)
	prompt.add_theme_color_override("font_color", Color(1.0, 1.0, 0.7))
	prompt.add_theme_color_override("font_outline_color", Color(0.05, 0.05, 0.0))
	prompt.add_theme_constant_override("outline_size", 3)
	prompt.position = Vector2(-80, 42)   # below the gate, always inside the arena
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
	for entry in _interactables:
		if not bool(entry.in_range):
			continue
		match String(entry.kind):
			"dojo":     _enter_dojo()
			"biome":    _walk_to_biome(String(entry.id))
			"carnival": _flash_hint("Bunting's up — the carnival isn't in town yet. Soon!")
		return


# ---------------------------------------------------------------------------
# Transitions
# ---------------------------------------------------------------------------

func _enter_dojo() -> void:
	_busy = true
	RunState.day_spawn_hint = "from_town"
	FX.fade_to_black(0.4, 0.05, 1.0, Callable(self, "_goto_dojo"))


func _goto_dojo() -> void:
	get_tree().change_scene_to_file(DOJO_PATH)


func _walk_to_biome(biome_id: String) -> void:
	_busy = true
	RunState.day_visit_biome = biome_id
	RunState.day_spawn_hint = "from_town"
	print("[TownSquare] Day visit → %s." % biome_id)
	FX.fade_to_black(0.4, 0.05, 1.0, Callable(self, "_goto_day_room"))


func _goto_day_room() -> void:
	get_tree().change_scene_to_file(DAY_ROOM_PATH)
