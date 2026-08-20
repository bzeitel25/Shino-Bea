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
# Run 167 — the square (terrain, walls, facades, Dojo, gates, arch, props,
# townsfolk) is built by the SHARED builder so the waking-world square and the
# dream square can never drift apart. Anything visual belongs in TownBuild.gd.
const TB = preload("res://scripts/TownBuild.gd")

const DOJO_PATH: String = "res://scenes/Dojo.tscn"
const DAY_ROOM_PATH: String = "res://scenes/DayBiomeRoom.tscn"
const CARNIVAL_PATH: String = "res://scenes/CarnivalGrounds.tscn"

# Geometry lives on TownBuild — these aliases keep the old call sites readable.
const HALF_W: float = TB.HALF_W
const HALF_H: float = TB.HALF_H
const DOJO_BODY_SIZE: Vector2 = TB.DOJO_BODY_SIZE
const DOJO_CENTER: Vector2 = TB.DOJO_CENTER

var _interactables: Array = []   # [{zone, kind, id, prompt, in_range}]
var _busy: bool = false

var _hint_lbl: Label = null


func _ready() -> void:
	RunState.dream_world_mode = false
	MusicManager.play_area("town_day")   # daytime waking-world Town Square music

	# Run 143 — global foot-Y sorting so heroes weave between the placed props
	# (same rule as DreamRoom / DayBiomeRoom).
	y_sort_enabled = true

	var tier: int = RunState.town_visual_tier()
	Log.dbg("[TownSquare] Town visual tier: %d (0=delap 1=healing 2=perfect)." % tier)

	TB.build_terrain(self, tier, false)
	_build_dojo_landmark()
	_build_biome_gates()
	_build_carnival_exit()
	TB.build_props(self, tier, TB.prop_keepouts(), false)
	TB.build_townsfolk(self)   # Run 167b: parked until generic townsfolk art lands
	_build_hint_label()

	_place_heroes()
	_setup_day_mode.call_deferred()

	FX.fade_from_black(0.5)

	# Run 146 — framed beginner tooltip.
	const HINT = preload("res://scripts/HintPopup.gd")
	HINT.show_hint(self, "Town Square — Starfruit Island",
		"Talk to the townsfolk  •  Walk through a gate to visit a biome  •  Enter the Dojo to sleep")


# ---------------------------------------------------------------------------
# Heroes — spawn placement + relaxed dojo-style AI for the companion
# ---------------------------------------------------------------------------

func _place_heroes() -> void:
	var hint: String = RunState.day_spawn_hint
	RunState.day_spawn_hint = ""
	var spawn: Vector2 = TB.doorstep()   # front sand outside the Dojo entrance
	if hint == "from_carnival":
		# Walked back up the carnival road — arrive at the south arch.
		spawn = TB.CARNIVAL_POS + Vector2(0, -86)
	elif hint.begins_with("from_biome_"):
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
	# Run 167 — geometry, collision, walk-behind sorting and the sign all live
	# in TownBuild (the dream square builds the identical building). All this
	# scene adds is the door interactable that walks you inside.
	var door_host: Node2D = TB.build_dojo_landmark(self, "THE DOJO")
	_add_interactable(door_host, "dojo", "dojo", "Enter the Dojo")


# ---------------------------------------------------------------------------
# Build — biome gates (physical, compass-matched to the night hub)
# ---------------------------------------------------------------------------

func _build_biome_gates() -> void:
	for biome_id in DB.BIOME_ORDER:
		var biome: Dictionary = DB.get_biome(biome_id)
		# Run 167 — shared builder: same anchor, same torii, same label rules
		# the dream square uses. Only the text differs (families, not tiers).
		var gate: Node2D = TB.build_gate(self, String(biome_id), true, "DayGate")
		var fams: Array = RunState.FAMILY_HOMES.get(biome_id, [])
		TB.add_gate_label(gate, "%s \u2014 %s\n%s Families" % [
				String(biome["direction"]), String(biome["display"]),
				" & ".join(PackedStringArray(fams))],
			Color(1, 1, 1))
		_add_interactable(gate, "biome", String(biome_id), "Walk to %s" % String(biome["display"]))


# ---------------------------------------------------------------------------
# Build — carnival road (S). Run 167: no longer permanently sealed. The Dragon
# Fruit troupe rolls in once the island is visibly on the mend —
# RunState.carnival_open() = town out of Delapidated AND no family still
# Rotten — and from then on the arch walks you to the Carnival Grounds.
# ---------------------------------------------------------------------------
func _build_carnival_exit() -> void:
	var open_now: bool = RunState.carnival_open()
	var blurb: String = "The Dragon Fruit troupe is in town!" if open_now \
		else "The Dragon Fruit troupe & the rest of town"
	var arch: Node2D = TB.build_carnival_arch(self,
		"S \u2014 CARNIVAL ROAD\n%s" % blurb, Color(0.95, 0.65, 0.75), open_now)
	_add_interactable(arch, "carnival", "carnival",
		"Enter the Carnival" if open_now else "Peek down the road")


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
	InputGlyphs.bind_label(prompt, "[{interact}] %s" % action)   # Run 158 — live device glyph
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
			"carnival": _enter_carnival()
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
	Log.dbg("[TownSquare] Day visit → %s." % biome_id)
	FX.fade_to_black(0.4, 0.05, 1.0, Callable(self, "_goto_day_room"))


func _goto_day_room() -> void:
	get_tree().change_scene_to_file(DAY_ROOM_PATH)


func _enter_carnival() -> void:
	if not RunState.carnival_open():
		_flash_hint("Bunting's still up — the troupe won't come while the families are rotten.")
		return
	_busy = true
	RunState.day_spawn_hint = "from_town"
	Log.dbg("[TownSquare] Day visit → carnival grounds.")
	FX.fade_to_black(0.4, 0.05, 1.0, Callable(self, "_goto_carnival"))


func _goto_carnival() -> void:
	get_tree().change_scene_to_file(CARNIVAL_PATH)
