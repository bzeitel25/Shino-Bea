extends Node2D

# ============================================================
# CarnivalGrounds.gd — Run 167 (2026-08-19) — the Dragon Fruit Carnival
# ============================================================
# The waking-world zone south of Seedy City's Town Square, built from
# Bruno's two carnival sheets (see CarnivalTileset.gd).
#
# GATE (Bruno, Run 167): the troupe only rolls in once the island is
# visibly on the mend — RunState.carnival_open() = the town has left
# Delapidated AND not one family is still Rotten. Until then the south
# arch in the Town Square stays bunted shut.
#
# DAY ONLY. At night the fair is dark and the arch is closed; the
# troupe's merchants set up their tables in front of it in the dream
# square instead (DreamHub.gd + ShopStand.gd).
#
# Layout, north to south:
#   * the DRAGON TORII you came through, flanked by stone dragons,
#     with the ticket booth beside it;
#   * a midway of dragon-scale pavement running down the middle and
#     branching east/west, lit by paper lanterns and strung bunting;
#   * BIG TOP west, STAGE east, CAROUSEL dead centre on a ring of
#     confetti-strewn ground;
#   * the games row (dartboard, hi-striker, wheel, duck pond, bottle
#     pyramid) west, the vendor stalls east;
#   * the troupe themselves — Pitaya barking by the stage, Madame Nova
#     reading the ball, Jangles clowning by the carousel and Tally
#     minding the gate. They wear whatever tier the island has earned.
# ============================================================

const DAY = preload("res://scripts/DayTerrain.gd")
const CT = preload("res://scripts/CarnivalTileset.gd")
const FOLK = preload("res://scripts/TownFolk.gd")

const TOWN_PATH: String = "res://scenes/TownSquare.tscn"

const HALF_W: float = 760.0
const HALF_H: float = 440.0

const GROUND_COLOR: Color     = Color(0.60, 0.54, 0.44)
const GROUND_ALT_COLOR: Color = Color(0.64, 0.58, 0.48)
const WALL_COLOR: Color       = Color(0.46, 0.34, 0.30)
const SKY_COLOR: Color        = Color(0.52, 0.70, 0.60)

# The dragon arch is tall, so the entrance sits a little INSIDE the north wall
# rather than flush against it — you walk up under the gate, not into a sliver
# of it poking over the fence.
const ENTRANCE: Vector2 = Vector2(0, -HALF_H + 120.0)

# Midway: [from, to] world-space segments the ground bake paves in dragon stone.
const MIDWAY: Array = [
	[Vector2(0, -400), Vector2(0, 300)],
	[Vector2(-560, -40), Vector2(560, -40)],
	[Vector2(-430, 160), Vector2(430, 160)],
]
# Confetti-strewn show floors: [centre, radius]
const SHOW_FLOORS: Array = [
	[Vector2(0, 60), 190.0],
	[Vector2(-420, -150), 165.0],
	[Vector2(430, -170), 150.0],
]

# [prop, drawn height, x, y, collide radius]  (0 = walk-through)
const PROPS: Array = [
	# --- entrance ---------------------------------------------------------
	["booth_tickets",          118.0, -352.0, -286.0, 30.0],
	["statue_dragon_pedestal",  80.0, -196.0, -300.0, 18.0],
	["statue_dragon_pedestal",  80.0,  196.0, -300.0, 18.0],
	["fence_tall_a",            52.0, -462.0, -308.0,  0.0],
	["fence_tall_b",            52.0,  462.0, -308.0,  0.0],
	# --- games row, west --------------------------------------------------
	["game_dartboard_stand",    96.0, -600.0,  100.0, 20.0],
	["game_wheel",             104.0, -450.0,   60.0, 22.0],
	["game_hi_striker",        112.0, -600.0,  250.0, 20.0],
	["game_duck_pond",          72.0, -430.0,  270.0, 26.0],
	["prize_bottle_pyramid",    72.0, -280.0,  260.0, 20.0],
	["crates_stack",            56.0, -300.0,   90.0, 18.0],
	# --- vendor row, east -------------------------------------------------
	["stall_dragonfruit",      124.0,  545.0,   80.0, 40.0],
	["stall_grill",            116.0,  560.0,  250.0, 38.0],
	["stall_awning",           120.0,  360.0,  290.0, 38.0],
	["table_red_cloth",         84.0,  300.0,  110.0, 30.0],
	["basket_dragonfruit",      54.0,  400.0,   70.0, 16.0],
	["baskets_stacked",         56.0,  455.0,  300.0, 16.0],
	["prize_chest_egg",         66.0,  225.0,  300.0, 20.0],
	# --- braziers + lanterns down the midway ------------------------------
	["brazier_stone",           74.0, -150.0,  -70.0, 20.0],
	["brazier_stone",           74.0,  150.0,  -70.0, 20.0],
	["lantern_paper_f1",        82.0,  -95.0, -178.0,  0.0],
	["lantern_paper_f2",        82.0,   95.0, -178.0,  0.0],
	["lantern_dragonfish",      92.0, -250.0,  -10.0,  0.0],
	["lantern_dragonfish",      92.0,  250.0,  -10.0,  0.0],
	["lantern_glow_a",          80.0, -560.0,  -10.0,  0.0],
	["lantern_glow_b",          80.0,  560.0,  -10.0,  0.0],
	# --- flora + dressing --------------------------------------------------
	["cactus_dragonfruit",      66.0, -680.0, -160.0, 14.0],
	["cactus_pink",             62.0,  690.0, -140.0, 14.0],
	["plant_bromeliad",         52.0, -690.0,  350.0, 12.0],
	["plant_sunflower",         52.0,  690.0,  360.0, 12.0],
	["topiary_ball",            68.0, -292.0, -206.0, 16.0],
	["topiary_ball",            68.0,  292.0, -206.0, 16.0],
	["hedge_flowers",           58.0,  -60.0,  355.0,  0.0],
	["hedge_flowers",           58.0,   60.0,  355.0,  0.0],
	["pond_lily",               46.0, -540.0,  370.0,  0.0],
	["flag_dragon_pole",        92.0, -206.0, -196.0,  0.0],
	["flag_dragon_pole",        92.0,  206.0, -196.0,  0.0],
	["mask_dragon_big",         60.0,  640.0, -300.0,  0.0],
	["statue_dragon_green",     78.0, -640.0,  -20.0, 20.0],
	["statue_gargoyle_a",       62.0,  640.0,  120.0, 16.0],
]

# Big structures get BOX blockers, not discs. [prop, height, x, y, block w, block h]
const STRUCTURES: Array = [
	["tent_bigtop",  208.0, -420.0, -110.0, 300.0, 84.0],
	["stage_wooden", 155.0,  430.0, -130.0, 226.0, 66.0],
	["carousel",     200.0,    0.0,   85.0, 140.0, 68.0],
	["tent_striped", 132.0, -150.0,  330.0, 160.0, 48.0],
	["forge_kiln",    98.0,  520.0, -318.0,  86.0, 42.0],
]

# The troupe. [member, x, y, face_left]
const TROUPE: Array = [
	["pitaya",  355.0, -60.0, false],   # barking the show outside the stage
	["nova",   -330.0,  30.0, true],    # reading the ball by the big top
	["jangles",  95.0, 175.0, true],    # clowning at the carousel
	["tally",  -258.0, -252.0, false],  # minding the gate by the ticket booth
]

# One line each, per healing tier — the troupe cheers up as the island does.
const TROUPE_LINES: Dictionary = {
	"pitaya": [
		"Step... right up. Or don't. Nobody has, in a while.",
		"STEP RIGHT UP! ...sorry. Voice isn't what it was.",
		"STEP RIGHT UP, ninjas! The show's back on!",
		"LADIES AND GENTLEMEN — the Dragon Fruit Carnival RIDES AGAIN!",
	],
	"nova": [
		"The ball's gone cloudy. Everything has.",
		"I see... something. That's more than last week.",
		"I see two ninjas, and a long night ahead. Come back after.",
		"I see the whole island, bright as a lantern. You did that.",
	],
	"jangles": [
		"...I forgot the punchline. I forgot there was one.",
		"Knock knock. ...I'll get there.",
		"Knock knock! Who's there? Two ninjas who owe me a laugh!",
		"HA! Watch this — no, watch THIS —",
	],
	"tally": [
		"No tickets. No show. Sorry.",
		"Tickets? We're... nearly ready. Nearly.",
		"Tickets! One for you, one for her. On the house.",
		"Welcome back! Everyone's asking after you two.",
	],
}

var _interactables: Array = []
var _busy: bool = false
var _hint_lbl: Label = null


func _ready() -> void:
	RunState.dream_world_mode = false
	MusicManager.play_area("carnival")
	y_sort_enabled = true

	DAY.make_backdrop(self, Vector2(HALF_W, HALF_H), SKY_COLOR)
	DAY.make_ground(self, Vector2(HALF_W, HALF_H), GROUND_COLOR, GROUND_ALT_COLOR, 16700)
	DAY.make_border_walls(self, Vector2(HALF_W, HALF_H), WALL_COLOR, true)
	CT.build_ground(self, Vector2(HALF_W, HALF_H), 16700, MIDWAY, SHOW_FLOORS)

	_build_entrance()
	_build_grounds()
	_build_troupe()
	_build_hint_label()
	_place_heroes()
	_setup_day_mode.call_deferred()

	FX.fade_from_black(0.5)

	const HINT = preload("res://scripts/HintPopup.gd")
	HINT.show_hint(self, "The Dragon Fruit Carnival",
		"The troupe is back in town  •  Talk to the performers  •  Head north through the arch to go home")


# ---------------------------------------------------------------------------
# Entrance — the dragon torii you came through, back to the Town Square
# ---------------------------------------------------------------------------
func _build_entrance() -> void:
	var host := Node2D.new()
	host.name = "Entrance"
	host.position = ENTRANCE
	add_child(host)

	# The fair's own arch IS the big hand-drawn dragon torii off the sheet —
	# no second gate stacked on top of it. Walk under it and press [E] to go
	# back up the road to the Town Square.
	var props := Node2D.new()
	props.name = "EntranceProps"
	props.y_sort_enabled = true
	add_child(props)
	CT.place(props, "gate_dragon_torii", 215.0, ENTRANCE, 0.0, false, false)
	CT.string_bunting(props, ENTRANCE + Vector2(-300, -108), ENTRANCE + Vector2(-104, -170))
	CT.string_bunting(props, ENTRANCE + Vector2(104, -170), ENTRANCE + Vector2(300, -108))

	var lbl := Label.new()
	lbl.text = "N — BACK TO SEEDY CITY"
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", Color(1.0, 0.86, 0.62))
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	lbl.add_theme_constant_override("outline_size", 3)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.position = Vector2(-120, 46)
	lbl.custom_minimum_size = Vector2(240, 0)
	host.add_child(lbl)

	_add_interactable(host, "town", "town", "Head back to town", Vector2(-84, 86))


# ---------------------------------------------------------------------------
# Grounds — structures first (they own the skyline), then the prop pass
# ---------------------------------------------------------------------------
func _build_grounds() -> void:
	var host := Node2D.new()
	host.name = "CarnivalProps"
	host.y_sort_enabled = true
	add_child(host)

	for rec in STRUCTURES:
		CT.place_wide(host, String(rec[0]), float(rec[1]),
			Vector2(float(rec[2]), float(rec[3])),
			Vector2(float(rec[4]), float(rec[5])))

	for rec in PROPS:
		CT.place(host, String(rec[0]), float(rec[1]),
			Vector2(float(rec[2]), float(rec[3])), float(rec[4]))

	# Bunting strung across the midway between the two flag poles.
	CT.string_bunting(host, Vector2(-206, -272), Vector2(0, -244))
	CT.string_bunting(host, Vector2(0, -244), Vector2(206, -272))


# ---------------------------------------------------------------------------
# The troupe
# ---------------------------------------------------------------------------
func _build_troupe() -> void:
	var host := Node2D.new()
	host.name = "Troupe"
	host.y_sort_enabled = true
	add_child(host)
	for rec in TROUPE:
		var member: String = String(rec[0])
		var pos := Vector2(float(rec[1]), float(rec[2]))
		FOLK.make(host, member, pos, bool(rec[3]), 1.15)
		var talk := Node2D.new()
		talk.name = "Talk_%s" % member
		talk.position = pos
		host.add_child(talk)
		_add_interactable(talk, "troupe", member, "Talk", Vector2(-70, 30))


func _troupe_line(member: String) -> String:
	var lines: Array = TROUPE_LINES.get(member, [])
	if lines.is_empty():
		return "..."
	return String(lines[clampi(RunState.dragonfruit_tier(), 0, lines.size() - 1)])


# ---------------------------------------------------------------------------
# Heroes
# ---------------------------------------------------------------------------
func _place_heroes() -> void:
	RunState.day_spawn_hint = ""
	var spawn: Vector2 = ENTRANCE + Vector2(0, 96)
	var pl := get_node_or_null("Player")
	if pl:
		(pl as Node2D).position = spawn + Vector2(-26, 0)
	var be := get_node_or_null("Bea")
	if be:
		(be as Node2D).position = spawn + Vector2(26, 0)


func _setup_day_mode() -> void:
	for p in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(p):
			continue
		if "dojo_mode" in p:
			p.dojo_mode = true
			p.dojo_wait_pos = ENTRANCE + Vector2(90 if p.is_in_group("bea") else -90, 150)


# ---------------------------------------------------------------------------
# Interactables — same proximity + [E] contract as both squares
# ---------------------------------------------------------------------------
func _add_interactable(host: Node2D, kind: String, id: String, action: String,
		prompt_off: Vector2 = Vector2(-80, 42)) -> void:
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
	InputGlyphs.bind_label(prompt, "[{interact}] %s" % action)
	prompt.add_theme_font_size_override("font_size", 14)
	prompt.add_theme_color_override("font_color", Color(1.0, 1.0, 0.7))
	prompt.add_theme_color_override("font_outline_color", Color(0.05, 0.05, 0.0))
	prompt.add_theme_constant_override("outline_size", 3)
	prompt.position = prompt_off
	prompt.visible = false
	prompt.z_as_relative = false
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
			"town":   _back_to_town()
			"troupe": _flash_hint(_troupe_line(String(entry.id)))
		return


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
	_hint_lbl.offset_left = -320.0
	_hint_lbl.offset_right = 320.0
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
	tw.tween_interval(3.0)
	tw.tween_callback(func() -> void:
		if is_instance_valid(_hint_lbl):
			_hint_lbl.text = "")


func _back_to_town() -> void:
	_busy = true
	RunState.day_spawn_hint = "from_carnival"
	FX.fade_to_black(0.4, 0.05, 1.0, Callable(self, "_goto_town"))


func _goto_town() -> void:
	get_tree().change_scene_to_file(TOWN_PATH)
