extends Node2D

# ============================================================
# DreamDojo.gd - Run 173 - the Training Room (dream Dojo)
# ============================================================
# Bruno: "I want the dream arena to be a dream parallel of our real world dojo
# - with that training mat in the middle - that can be our training room."
#
# So this is the Dojo, dreamed: the same building via DojoRoomBuild (same
# footprint, same walls, same training mat at (-240,-40,480,280)), dressed in
# the same Dojo_props, but with a cold moonlit void past the walls and the
# dream night tint over the whole world layer. NO SENSEI - he sleeps in the
# waking world; this room is yours.
#
# The Training Dummy stands ON the mat and the Boon Dispenser beside it, so a
# loadout can be built and swung in one place.
#
# Flow:
#   pick a regular enemy  -> it spawns here, in the room
#   pick a boss/miniboss  -> HOLO-ROOM: the walls fall away and the room
#                            becomes that boss's own biome chamber
#                            (BossTestArena.tscn), boss already in it
#   boss dies             -> back here
#   pause menu            -> "Return to Training Room" / "Return to Dojo"
#
# RunState.training_active is set here and cleared only by leaving for the real
# Dojo, so the pause menu knows a session is live.
# ============================================================

const ROOM = preload("res://scripts/DojoRoomBuild.gd")
const MENU = preload("res://scripts/BossSpawnMenu.gd")
const SPAWNER = preload("res://scripts/DreamSpawner.gd")
const DB = preload("res://scripts/DreamBiomes.gd")

const ARENA_SCENE: String = "res://scenes/BossTestArena.tscn"
const TRAINING_SCENE: String = "res://scenes/DreamDojo.tscn"
const DOJO_SCENE: String = "res://scenes/Dojo.tscn"

# A cold moonlit void past the walls instead of the waking dojo's soot black.
const DREAM_BACKDROP: Color = Color(0.055, 0.065, 0.115)

# The training mat, from DojoRoomBuild's contract: Rect2(-240, -40, 480, 280).
const MAT_CENTRE: Vector2 = Vector2(0.0, 100.0)

var _menu: CanvasLayer = null
var _tier_override: int = 0


func _ready() -> void:
	y_sort_enabled = true
	add_to_group("world")   # AI rally lookups expect a "world" node

	RunState.training_active = true
	RunState.training_squad = []
	if String(RunState.current_biome) == "" or DB.get_biome(String(RunState.current_biome)).is_empty():
		RunState.current_biome = "beach"

	ROOM.build(self, ROOM.DOJO_ART, ROOM.DOJO_FLOOR, ROOM.DOJO_WALL, DREAM_BACKDROP)
	_apply_dream_tint()
	_place_fixtures()
	_position_heroes()

	_menu = MENU.new()
	_menu.name = "BossSpawnMenu"
	_menu.set("arena", self)
	add_child(_menu)

	_build_summon_gong()

	_update_controls_label()
	MusicManager.play_area("dojo")   # it IS the dojo, dreamed
	FX.fade_from_black(0.35)
	Log.dbg("[DreamDojo] Training Room ready.")


# The dream world is night (Run 113): one CanvasModulate over the world layer.
# The HUD is on its own CanvasLayer and stays bright.
func _apply_dream_tint() -> void:
	if get_node_or_null("NightOverlay") != null:
		return
	var night := CanvasModulate.new()
	night.name = "NightOverlay"
	night.color = RunState.NIGHT_TINT
	add_child(night)


# Dummy ON the mat, dispenser beside it. Fixed coordinates are safe here (unlike
# the biome rooms): this room's floorplan is a constant, not procedural.
#
# INTENDED, DO NOT "FIX": the AI partner drifts over and works the dummy when
# she has nothing else to do. That falls out of the dummy being in the "enemy"
# group and the follower AI having no other target — Bruno saw it on the first
# playtest and wants it kept ("kinda cute tbh, let them keep doing that to
# train on the dummy if not doing anything else"). If follower targeting is
# ever reworked, keep the training dummy a valid idle target in this room.
func _place_fixtures() -> void:
	var dummy: Node2D = get_node_or_null("TrainingDummy")
	if dummy:
		dummy.position = MAT_CENTRE + Vector2(0.0, -70.0)
	var disp: Node2D = get_node_or_null("BoonDispenser")
	if disp:
		disp.position = Vector2(-200.0, -228.0)   # same nail as the real dojo


func _position_heroes() -> void:
	var shino: Node2D = get_node_or_null("Player")
	if shino:
		shino.position = MAT_CENTRE + Vector2(-50.0, 120.0)
	var bea: Node2D = get_node_or_null("Bea")
	if bea:
		bea.position = MAT_CENTRE + Vector2(50.0, 120.0)


func _update_controls_label() -> void:
	var hint: Label = get_node_or_null("DebugHUD/ControlsLabel")
	if hint:
		hint.text = "TRAINING ROOM  (Tier %d)\nStrike the SUMMONING GONG to pick an opponent  (or press TAB)\nK = clear    J = heal    H = hide this    Pause -> Return to Dojo to end." % _tier_override


# ---------------------------------------------------------------------------
# The Enemy Dispenser
# ---------------------------------------------------------------------------
# Bruno, first playtest: "I don't see a way to spawn bosses in the training
# room, just the boon dispenser and a dummy." The picker was hotkey-only, and
# the Boon Dispenser was found instantly because it is a THING you walk up to
# with a prompt over it.
#
# So the picker becomes its twin: an ENEMY DISPENSER on the opposite side of
# the north wall, same interaction (walk in, [E], build a set, commit). Boons
# on the west nail, monsters on the east. The TAB hotkey still works.
const GONG_POS: Vector2 = Vector2(200.0, -228.0)
const GONG_REACH: float = 76.0

var _gong_prompt: Label = null
var _gong_near: Array = []
var _player_at_gong: bool = false


func _build_summon_gong() -> void:
	var gong := Node2D.new()
	gong.name = "EnemyDispenser"
	gong.position = GONG_POS
	add_child(gong)

	ROOM.place_prop(gong, ROOM.DOJO_ART, "gong_alcove", Vector2.ZERO, 96.0)
	GlowLight.attach(gong, Vector2(0.0, -60.0), GlowLight.EMBER, 150.0, 0.66, 0.16)

	var label := Label.new()
	label.name = "NameLabel"
	label.text = "ENEMY DISPENSER"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 10)
	label.modulate = Color(1.0, 0.62, 0.40)
	label.position = Vector2(-60.0, 12.0)
	label.custom_minimum_size = Vector2(120.0, 16.0)
	label.size = Vector2(120.0, 16.0)
	gong.add_child(label)

	_gong_prompt = Label.new()
	_gong_prompt.name = "InteractPrompt"
	_gong_prompt.text = "[E]  Dispense monsters"
	_gong_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_gong_prompt.add_theme_font_size_override("font_size", 13)
	_gong_prompt.modulate = Color(1.0, 0.68, 0.45)
	_gong_prompt.position = Vector2(-90.0, -128.0)
	_gong_prompt.custom_minimum_size = Vector2(180.0, 20.0)
	_gong_prompt.size = Vector2(180.0, 20.0)
	_gong_prompt.visible = false
	gong.add_child(_gong_prompt)

	# Same interaction shape as the Boon Dispenser: an Area2D on the player
	# layer, a prompt while you stand in it, `interact` to trigger.
	var area := Area2D.new()
	area.name = "GongArea"
	area.collision_layer = 0
	area.collision_mask = 2
	var cs := CollisionShape2D.new()
	var shape := CircleShape2D.new()
	shape.radius = GONG_REACH
	cs.shape = shape
	area.add_child(cs)
	gong.add_child(area)
	area.body_entered.connect(_on_gong_entered)
	area.body_exited.connect(_on_gong_exited)

	# The gong is solid — you strike it, you don't walk through it.
	var solid := StaticBody2D.new()
	solid.collision_layer = 1
	solid.collision_mask = 0
	var scs := CollisionShape2D.new()
	var sshape := CircleShape2D.new()
	sshape.radius = 18.0
	scs.shape = sshape
	solid.add_child(scs)
	gong.add_child(solid)


func _on_gong_entered(b: Node) -> void:
	if not _gong_near.has(b):
		_gong_near.append(b)


func _on_gong_exited(b: Node) -> void:
	_gong_near.erase(b)


func _process(_delta: float) -> void:
	if _gong_prompt == null:
		return
	_player_at_gong = false
	for b in _gong_near:
		if is_instance_valid(b) and b.is_in_group("player") and (b as Node2D).visible:
			if b.has_method("is_downed") and b.is_downed():
				continue
			_player_at_gong = true
			break
	_gong_prompt.visible = _player_at_gong


# ---------------------------------------------------------------------------
# API used by BossSpawnMenu (same surface as BossTestArena's)
# ---------------------------------------------------------------------------

func sandbox_tier() -> int:
	return _tier_override


func set_sandbox_tier(t: int) -> void:
	_tier_override = clampi(t, 0, 5)
	_update_controls_label()


func alive_count() -> int:
	var n: int = 0
	for e in get_tree().get_nodes_in_group("enemy"):
		if is_instance_valid(e) and not e.is_in_group("immovable"):
			n += 1
	return n


# The dispenser hands the whole loaded squad over at once, and the arena is
# built around it. Nothing spawns in the Training Room itself any more - the
# room is the mat, the dummy and the two dispensers.
func launch_training_arena(squad: Array, biome: String) -> void:
	if squad.is_empty():
		return
	var use_biome: String = biome
	if use_biome == "" or use_biome == "cake" or DB.get_biome(use_biome).is_empty():
		use_biome = String(RunState.current_biome)
	RunState.training_active = true
	RunState.training_biome = use_biome
	RunState.training_squad = squad.duplicate(true)
	RunState.training_tier = _tier_override
	RunState.current_biome = use_biome
	RunState.biome_room = DB.ROOMS_PER_BIOME
	get_tree().paused = false
	Log.dbg("[DreamDojo] launching arena in '%s' with %d monsters." % [use_biome, squad.size()])
	get_tree().change_scene_to_file(ARENA_SCENE)


# Back to the Training Room, session still live (squad cleared, or the player
# chose to bail out of the bout).
static func return_to_training(tree: SceneTree) -> void:
	RunState.training_active = true
	RunState.training_squad = []
	tree.paused = false
	tree.change_scene_to_file(TRAINING_SCENE)


func kill_all() -> int:
	var n: int = 0
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or e.is_in_group("immovable"):
			continue
		e.queue_free()
		n += 1
	for a in get_tree().get_nodes_in_group("boss_add"):
		if is_instance_valid(a):
			a.queue_free()
	return n


func heal_heroes() -> void:
	for h in get_tree().get_nodes_in_group("player"):
		if h.has_method("heal_external") and h.has_method("get_effective_max_hp"):
			h.heal_external(int(h.get_effective_max_hp()))


# ---------------------------------------------------------------------------
# Leaving. Called by PauseManager's training exits.
# ---------------------------------------------------------------------------

static func return_to_dojo(tree: SceneTree) -> void:
	RunState.training_active = false
	RunState.training_biome = ""
	RunState.training_squad = []
	tree.paused = false
	tree.change_scene_to_file(DOJO_SCENE)


func _unhandled_input(event: InputEvent) -> void:
	# Walk up and open the dispenser.
	if _player_at_gong and event.is_action_pressed("interact") and not event.is_echo():
		if _menu != null:
			_menu.call("toggle")
			get_viewport().set_input_as_handled()
			return
	# H hides the debug panel, matching World.gd's arenas.
	if event is InputEventKey and event.pressed and (event as InputEventKey).physical_keycode == KEY_H:
		var hint: Label = get_node_or_null("DebugHUD/ControlsLabel")
		if hint:
			hint.visible = not hint.visible
