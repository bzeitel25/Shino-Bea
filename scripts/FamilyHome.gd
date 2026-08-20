extends Node2D

# ============================================================
# FamilyHome.gd — Run 147 (2026-07-15) — inside a family's hut
# ============================================================
# The karma DROP-OFF point. One scene serves all ten families —
# reads RunState.day_visit_family. The family ELDER stands at the
# hearth (they NEVER leave — fixed drop-off, Bruno's design lock)
# and talking to them:
#
#   1. plays a rotating DAILY line for their current healing tier
#   2. if karma is banked → DEPOSIT reaction + (maybe) TIER-UP moment
#      + one new STORY layer  — all silently, no numbers shown ever
#   3. otherwise → a NO-KARMA line
#
# ALL dialogue text lives in FamilyLore.gd — add lines there.
# ============================================================

const DAY = preload("res://scripts/DayTerrain.gd")
const FL = preload("res://scripts/FamilyLore.gd")
const NPC = preload("res://scripts/FamilyNPC.gd")
const DialogBoxScript = preload("res://scripts/DialogBox.gd")

const DAY_ROOM_PATH: String = "res://scenes/DayBiomeRoom.tscn"

const HALF_W: float = 320.0
const HALF_H: float = 230.0

# Extra household members who stay INSIDE the home near the elder (data-driven,
# keyed by the capitalized family key FamilyLore uses). They stand still — no
# wander — and chat like the outdoor wanderers do (FamilyLore.member_line).
# Run 147: families with an adult co-resident (spouse, sibling) get them
# placed inside the home off to the side. Children/wanderers stay outside.
const HOME_MEMBERS := {
	"Apple":      ["Cormac"],        # Granny Idunn's adult son
	"Coconut":    ["Piña"],          # Gnarls's wife
}

var _family: String = ""
var _elder: Node2D = null
var _interactables: Array = []
var _busy: bool = false


func _ready() -> void:
	RunState.dream_world_mode = false
	_family = RunState.day_visit_family
	if _family == "":
		push_error("[FamilyHome] No day_visit_family set — defaulting to Apple.")
		_family = "Apple"

	var fam_col: Color = (RunState.FAM_COLOR as Dictionary).get(_family, Color(0.6, 0.6, 0.6))

	# Cozy interior: warm plank floor, family-tinted walls.
	DAY.make_backdrop(self, Vector2(HALF_W, HALF_H), Color(0.10, 0.08, 0.07))
	DAY.make_ground(self, Vector2(HALF_W, HALF_H),
		Color(0.52, 0.38, 0.24), Color(0.56, 0.42, 0.27), 11702 + _family.hash() % 1000)
	DAY.make_border_walls(self, Vector2(HALF_W, HALF_H), fam_col.darkened(0.55))

	_build_decor(fam_col)
	_build_elder()
	_build_home_members()
	_build_exit()
	_build_title()

	_place_heroes()
	_setup_day_mode.call_deferred()

	FX.fade_from_black(0.4)


func _build_title() -> void:
	# Run 146 — replaced floating CanvasLayer label with framed HintPopup.
	const HINT = preload("res://scripts/HintPopup.gd")
	var tier_str: String = FL.tier_name(RunState.get_family_tier(_family))
	HINT.show_hint(self, "The %s Family Home" % _family,
		"%s  •  Talk to the family to learn their story  •  Press {interact} to interact" % tier_str)


func _build_decor(fam_col: Color) -> void:
	# Rug in the middle.
	var rug := ColorRect.new()
	rug.offset_left = -90
	rug.offset_top = -50
	rug.offset_right = 90
	rug.offset_bottom = 60
	rug.color = fam_col.darkened(0.35)
	rug.z_index = -30
	add_child(rug)
	var rug_border := ColorRect.new()
	rug_border.offset_left = -98
	rug_border.offset_top = -58
	rug_border.offset_right = 98
	rug_border.offset_bottom = 68
	rug_border.color = fam_col.darkened(0.50)
	rug_border.z_index = -31
	add_child(rug_border)

	# Hearth on the north wall behind the elder.
	var hearth := ColorRect.new()
	hearth.offset_left = -46
	hearth.offset_top = -HALF_H - 6
	hearth.offset_right = 46
	hearth.offset_bottom = -HALF_H + 52
	hearth.color = Color(0.30, 0.26, 0.24)
	hearth.z_index = -20
	add_child(hearth)
	var fire := ColorRect.new()
	fire.offset_left = -20
	fire.offset_top = -HALF_H + 18
	fire.offset_right = 20
	fire.offset_bottom = -HALF_H + 48
	fire.color = Color(0.95, 0.55, 0.18)
	fire.z_index = -19
	add_child(fire)

	# A table with a fruit bowl (of course).
	var table := ColorRect.new()
	table.offset_left = HALF_W - 170
	table.offset_top = -40
	table.offset_right = HALF_W - 90
	table.offset_bottom = 8
	table.color = Color(0.42, 0.30, 0.19)
	table.z_index = -20
	add_child(table)
	var bowl := ColorRect.new()
	bowl.offset_left = HALF_W - 150
	bowl.offset_top = -34
	bowl.offset_right = HALF_W - 110
	bowl.offset_bottom = -18
	bowl.color = fam_col
	bowl.z_index = -19
	add_child(bowl)


func _build_elder() -> void:
	_elder = NPC.new()
	# Stand at the CENTER of the interior — horizontally centered and at the
	# vertical middle of the room — so the karma drop-off is easy to find on
	# every daytime visit. (Elder plays "idle" automatically — never wanders.)
	_elder.position = Vector2(0, 0)
	add_child(_elder)
	_elder.setup(_family, FL.elder_name(_family), true)
	_elder.set_tier(RunState.get_family_tier(_family))

	var host := Node2D.new()
	host.position = _elder.position + Vector2(0, 30)
	add_child(host)
	_add_interactable(host, "elder", _family, "Talk to %s" % FL.elder_name(_family))


# ---------------------------------------------------------------------------
# Home members — extra household members who idle INSIDE near the elder
# (data-driven via HOME_MEMBERS). No wander; they chat like outdoor wanderers.
# ---------------------------------------------------------------------------

func _build_home_members() -> void:
	var names: Array = HOME_MEMBERS.get(_family, [])
	var tier: int = RunState.get_family_tier(_family)
	for i in range(names.size()):
		var who: String = String(names[i])
		var member: Node2D = NPC.new()
		# Beside the elder (who stays at center) but clearly separate — a small
		# +y so y-sort/overlap reads. Spread if a family ever lists more than one.
		member.position = Vector2(76.0 + 96.0 * float(i), 14.0)
		add_child(member)
		member.setup(_family, who, false)
		member.set_tier(tier)
		# Talkable: zone rides on the member node (matches DayBiomeRoom walkers),
		# so hold_still + follow work the same way — but they never wander here.
		_add_interactable(member, "member", _family + "|" + who, "Talk to %s" % who)


func _build_exit() -> void:
	var door := Node2D.new()
	door.name = "ExitDoor"
	door.position = Vector2(0, HALF_H - 30)
	add_child(door)
	var slab := ColorRect.new()
	slab.offset_left = -18
	slab.offset_top = -10
	slab.offset_right = 18
	slab.offset_bottom = 42
	slab.color = Color(0.18, 0.12, 0.09)
	door.add_child(slab)
	var lbl := Label.new()
	lbl.text = "Door"
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	lbl.add_theme_constant_override("outline_size", 3)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.position = Vector2(-30, 46)
	lbl.custom_minimum_size = Vector2(60, 0)
	door.add_child(lbl)
	_add_interactable(door, "exit", "exit", "Step outside")


func _place_heroes() -> void:
	var spawn: Vector2 = Vector2(0, HALF_H - 90)
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
			p.dojo_wait_pos = Vector2(120 if p.is_in_group("bea") else -120, 40)


# ---------------------------------------------------------------------------
# The elder chat — daily line, karma deposit, story layer (see FamilyLore.gd)
# ---------------------------------------------------------------------------

func _talk_to_elder() -> void:
	_busy = true
	var fam: String = _family
	var tier_before: int = RunState.get_family_tier(fam)
	var hero_name: String = _controlled_hero_name()
	var visit: int = int(RunState.family_visits.get(fam, 0))

	var lines: Array = []
	lines.append(FL.daily_line(fam, tier_before, visit, hero_name))

	var result: Dictionary = RunState.deposit_karma(fam)
	if int(result.deposited) > 0:
		lines.append(FL.reaction_line(fam, tier_before, "deposit", hero_name))
		if bool(result.tier_up):
			lines.append(FL.reaction_line(fam, int(result.new_tier), "tier_up", hero_name))
		# One new story layer per deposit, in order (Townsfolk §2.1).
		var layer: int = int(RunState.family_story_layer.get(fam, 0))
		lines.append(FL.story_line(fam, tier_before, layer, hero_name))
		RunState.family_story_layer[fam] = layer + 1
	else:
		lines.append(FL.reaction_line(fam, tier_before, "no_karma", hero_name))

	RunState.family_visits[fam] = visit + 1

	# Persist immediately — a deposit is meta progress.
	var sm: Node = get_node_or_null("/root/SaveManager")
	if sm and sm.has_method("save_active_slot") and sm.active_slot >= 0:
		sm.save_active_slot()

	var dlg: CanvasLayer = DialogBoxScript.new_box(self)
	dlg.finished.connect(_on_dialog_done.bind(bool(result.tier_up)))
	dlg.open(FL.elder_name(fam), lines)


func _on_dialog_done(tier_up: bool) -> void:
	_busy = false
	if tier_up and _elder != null:
		# The healing moment — visible sprite state change + a little flourish.
		_elder.set_tier(RunState.get_family_tier(_family))
		FX.spawn_burst_particles(_elder.global_position, Color(1.0, 0.9, 0.5), 18)
		FX.play_sound("boon_pickup", 1.1)


func _controlled_hero_name() -> String:
	for p in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(p) and p.get("player_controlled") == true:
			return "Bea" if p.is_in_group("bea") else "Shino"
	return "Shino"


# ---------------------------------------------------------------------------
# Home-member chat — rotating daily-style line from a non-elder member indoors
# (see FamilyLore.member_line). No karma changes hands here; the elder is still
# the only drop-off. Mirrors DayBiomeRoom._talk_to_member.
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

	# Hold the member in place while we talk (they stand still anyway indoors).
	var member: Node = (entry.get("zone") as Node)
	if member != null:
		member = member.get_parent()
	if member != null and member.has_method("hold_still"):
		member.hold_still(4.0)

	_busy = true
	var dlg: CanvasLayer = DialogBoxScript.new_box(self)
	dlg.finished.connect(func() -> void: _busy = false)
	dlg.open(who, [line])


# ---------------------------------------------------------------------------
# Interactables (DreamHub pattern)
# ---------------------------------------------------------------------------

func _add_interactable(host: Node2D, kind: String, id: String, action: String) -> void:
	var zone := Area2D.new()
	zone.collision_layer = 0
	zone.collision_mask = 2
	var shape := CircleShape2D.new()
	shape.radius = 56.0
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
	prompt.position = Vector2(-80, -84)
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
			"elder":  _talk_to_elder()
			"member": _talk_to_member(String(entry.id), entry)
			"exit":   _step_outside()
		get_viewport().set_input_as_handled()
		return


func _step_outside() -> void:
	_busy = true
	RunState.day_spawn_hint = "from_home"
	# Keep day_visit_family set — DayBiomeRoom uses it to spawn us at this hut.
	FX.fade_to_black(0.35, 0.05, 1.0, Callable(self, "_goto_day_room"))


func _goto_day_room() -> void:
	get_tree().change_scene_to_file(DAY_ROOM_PATH)
