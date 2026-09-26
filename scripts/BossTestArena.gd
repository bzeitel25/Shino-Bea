extends "res://scripts/DreamRoom.gd"

# ============================================================
# BossTestArena.gd - Run 173 - the TRAINING ARENA
# ============================================================
# The Training Room (DreamDojo.tscn) is where a session lives. Loading the
# Enemy Dispenser there and pressing GO hands the squad to
# RunState.training_squad and loads THIS scene: the relevant biome chamber with
# exactly that squad standing in it. Clear the squad and it dissolves back to
# the Training Room. The pause menu can bail out of a bout early, or end the
# whole session back at the real Dojo.
#
# EXTENDS DreamRoom on purpose. The sandbox is the REAL room - same procedural
# terrain, same DreamLayout walkability, same heroes, camera, HUD, night
# overlay, same boss-chamber dimensions. A hand-rolled flat test box would let
# a boss behave differently here than in a live run, which is the one thing a
# tuning rig must never do. Spawns go through DreamSpawner's own static
# scene_for_config() + apply_config() for exactly the same reason.
#
# What this subclass changes:
#   * the room is pinned to the BOSS ROOM of the biome (the wide chamber)
#   * the spawner's autospawn is off, so the room starts empty
#   * the door pipeline is neutered - no previews rolled, so _plan_doors()
#     seals every gate and a stray gate touch can't yank you into a real run
#   * a BossSpawnMenu child owns the picker UI and all sandbox hotkeys
#
# Input deliberately lives in BossSpawnMenu, NOT here: World.gd already defines
# _input() (H / Start toggle the controls panel) and overriding it would delete
# that silently. See that file's header for the pause/input interaction.
#
# CONTROLS
#   TAB or Back(Select)  open / close the spawn menu
#   Up/Down pick row     Left/Right switch biome page
#   Enter / A spawn 1    X spawn 3
#   [ / ] tier down/up   R rebuild the room in the shown biome
#   K kill all           J heal both heroes      Esc / B close
# ============================================================

const SPAWNER = preload("res://scripts/DreamSpawner.gd")
const MENU    = preload("res://scripts/BossSpawnMenu.gd")

const DOJO = preload("res://scripts/DreamDojo.gd")

var _sandbox_biome: String = "beach"
var _tier_override: int = 0
var _menu: CanvasLayer = null

# The squad this bout is about. Held so the bout can end when the field is
# clear. Empty when the scene is opened outside a training session.
var _bout_foes: Array = []
var _bout_live: bool = false
var _bout_over: bool = false


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	# Pin to the boss room BEFORE super._ready() reads RunState, so we build the
	# wide end-of-arm chamber rather than a mid-biome room.
	var want: String = String(RunState.current_biome)
	if want == "" or want == "cake" or DB.get_biome(want).is_empty():
		want = "beach"
	_sandbox_biome = want
	RunState.current_biome = _sandbox_biome
	RunState.biome_room = DB.ROOMS_PER_BIOME

	super._ready()

	_menu = MENU.new()
	_menu.name = "BossSpawnMenu"
	# set() rather than a direct write: `_menu` is CanvasLayer-typed and `arena`
	# is a script property, matching how the rest of the codebase writes across
	# script boundaries (DreamSpawner.apply_config, MonsterRig `_cfg_id`, ...).
	_menu.set("arena", self)
	add_child(_menu)

	_begin_bout()
	_update_controls_label()
	Log.dbg("[BossTestArena] holo-room ready in '%s'." % _sandbox_biome)


# Spawn the squad the Enemy Dispenser was loaded with.
func _begin_bout() -> void:
	var squad: Array = RunState.training_squad
	if squad.is_empty():
		return
	_tier_override = int(RunState.training_tier)
	_bout_foes.clear()
	for entry in squad:
		var e: Dictionary = entry
		var node: Node = _spawn_actor(e.get("cfg", {}), String(e.get("kind", "enemy")))
		if node != null:
			_bout_foes.append(node)
	if _bout_foes.is_empty():
		push_warning("[BossTestArena] squad spawned nothing.")
		return
	_bout_live = true
	Log.dbg("[BossTestArena] bout: %d monsters." % _bout_foes.size())


# The bout ends when every squad member is gone. Polling beats hooking _die():
# BossBrain's death is a coroutine that frees itself after its animation, and
# every kill path (damage, ult, kill-all) funnels into the node going away.
# Boss-summoned adds are deliberately NOT counted - clearing the boss ends it.
func _process(_delta: float) -> void:
	if _bout_over or not _bout_live:
		return
	for f in _bout_foes:
		if is_instance_valid(f):
			return
	_bout_over = true
	_finish_bout()


func _finish_bout() -> void:
	var label: Label = get_node_or_null("DebugHUD/WaveClearedLabel")
	if label:
		label.text = "SQUAD CLEARED"
		label.visible = true
	Log.dbg("[BossTestArena] squad cleared - back to the Training Room.")
	await get_tree().create_timer(1.6).timeout
	if is_inside_tree():
		DOJO.return_to_training(get_tree())


# No previews rolled => _plan_doors() seals every gate. The door pipeline is
# dead weight here and an accidental gate touch would leave the sandbox.
func _roll_door_previews() -> Array:
	return []


func _update_controls_label() -> void:
	var hint: Label = get_node_or_null("DebugHUD/ControlsLabel")
	if hint:
		hint.text = "TRAINING ARENA - %s  (Tier %d)\nTAB / Back = enemy dispenser    K = clear    J = heal    H = hide this\nClear the squad, or Pause -> Return to Training Room." % [
			String(DB.get_biome(_sandbox_biome).get("display", _sandbox_biome)), _tier_override]


# Nearest walkable point to `want`, spiralling outward. The terrain is
# procedural, so nothing may assume a given coordinate is floor.
func walkable_near(want: Vector2) -> Vector2:
	if dream_layout == null or not dream_layout.has_method("is_walkable_world"):
		return want
	if dream_layout.is_walkable_world(want):
		return want
	for radius in [40.0, 80.0, 130.0, 190.0, 260.0, 340.0]:
		for _i in range(10):
			var ang: float = randf() * TAU
			var p: Vector2 = want + Vector2(cos(ang), sin(ang)) * radius
			if dream_layout.is_walkable_world(p):
				return p
	if dream_layout.has_method("random_walkable"):
		return dream_layout.random_walkable(120.0)
	return want


# ---------------------------------------------------------------------------
# Public API used by BossSpawnMenu
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


# Spawn `count` of a roster entry. Returns how many actually landed.
# The arena hosts the same dispenser screen, so a new squad can be loaded
# without walking back to the Training Room first. GO re-enters through the
# Training Room's own launcher rather than a second copy of the handoff.
func launch_training_arena(squad: Array, biome: String) -> void:
	if squad.is_empty():
		return
	var use_biome: String = biome
	if use_biome == "" or use_biome == "cake" or DB.get_biome(use_biome).is_empty():
		use_biome = _sandbox_biome
	RunState.training_active = true
	RunState.training_biome = use_biome
	RunState.training_squad = squad.duplicate(true)
	RunState.training_tier = _tier_override
	RunState.current_biome = use_biome
	RunState.biome_room = DB.ROOMS_PER_BIOME
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/BossTestArena.tscn")


# Instantiate + place one roster entry, returning the node so a bout can watch
# it. Same routing + same config application the live spawner uses, so a boss
# can never be hosted or tuned differently in the sandbox.
func _spawn_actor(cfg_in: Dictionary, kind: String) -> Node:
	var cfg: Dictionary = cfg_in.duplicate(true)
	if kind == "boss":
		cfg["is_boss"] = true
	elif kind == "miniboss":
		cfg["is_miniboss"] = true

	var scene_path: String = SPAWNER.scene_for_config(cfg)
	if not ResourceLoader.exists(scene_path):
		push_warning("[BossTestArena] missing scene %s" % scene_path)
		return null

	var e: Node = (load(scene_path) as PackedScene).instantiate()
	SPAWNER.apply_config(e, cfg, _tier_override)
	e.add_to_group("sandbox_spawn")
	# The live spawner parents enemies to the room node; BossBrain walks up from
	# its parent to find dream_layout and parents projectiles/hazards there.
	add_child(e)
	if e is Node2D:
		(e as Node2D).global_position = _spawn_point(cfg)
	return e


# Bosses land further out so you can watch them approach and read their
# movement mode; regular enemies drop closer.
func _spawn_point(cfg: Dictionary) -> Vector2:
	var is_big: bool = cfg.get("is_boss", false) or cfg.get("is_miniboss", false)
	var from: Vector2 = Vector2.ZERO
	var hero: Node2D = get_node_or_null("Player")
	if hero:
		from = hero.global_position
	var want: float = 380.0 if is_big else 240.0
	var ang: float = randf() * TAU
	return walkable_near(from + Vector2(cos(ang), sin(ang)) * want)


# Clear the field. queue_free rather than take_damage on purpose: this is a
# RESET, so the on-death boon cascade (Juicebox, Wave Crash, Rotten Core...)
# must NOT fire and pollute the loadout being tested.
func kill_all() -> int:
	var n: int = 0
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e):
			continue
		if e.is_in_group("immovable"):
			continue        # never despawn the training dummy
		e.queue_free()
		n += 1
	for a in get_tree().get_nodes_in_group("boss_add"):
		if is_instance_valid(a):
			a.queue_free()
	# Drop the HUD boss bar with them.
	var fx: Node = get_node_or_null("/root/FX")
	if fx != null and fx.has_method("unregister_boss") and fx.get("current_boss") != null:
		fx.unregister_boss(fx.get("current_boss"))
	Log.dbg("[BossTestArena] cleared %d enemies." % n)
	return n


func heal_heroes() -> void:
	for h in get_tree().get_nodes_in_group("player"):
		if h.has_method("heal_external") and h.has_method("get_effective_max_hp"):
			h.heal_external(int(h.get_effective_max_hp()))


