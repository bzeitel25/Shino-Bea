extends Node2D

# ============================================================
# BossArena.gd — Run 23 (2026-06-01)
# ============================================================
# Final-room controller after the 10-wave TestArena. Spawns the
# Shadow Commander boss on _ready, polls the "enemy" group for
# clearance, then briefly celebrates and fades into RunComplete.
#
# Deliberately small — no boon offer here (final boss + win screen
# is the meaningful cap). A future iteration can add a "trophy boon"
# between boss death and run complete if desired.
# ============================================================

const BOSS_SCENE_PATH: String = "res://scenes/Boss.tscn"
const RUN_COMPLETE_PATH: String = "res://scenes/RunComplete.tscn"
# Run 26f — Shadow Commander now chains into the second 10-arena run (11-20)
# instead of ending the run. The Triheaded Wyrm at Arena 20+1 is the temporary
# final boss for build-testing playthroughs.
const NEXT_RUN_SCENE_PATH: String = "res://scenes/Arena11.tscn"
const POLL_INTERVAL: float = 0.30
const VICTORY_HOLD: float = 2.2   # seconds we hold the victory banner before fading

@onready var enemies_root: Node2D = $Enemies
@onready var banner_label: Label  = $DebugHUD/BannerLabel
@onready var hint_label:   Label  = $DebugHUD/HintLabel

var _boss_alive: bool = false
var _poll_timer: float = 0.0
var _victory_started: bool = false


func _ready() -> void:
	Log.dbg("[BossArena] _ready — spawning Shadow Commander.")
	if get_node_or_null("/root/FX") and FX.has_method("fade_from_black"):
		FX.fade_from_black(0.45)
	call_deferred("_spawn_boss")


func _process(delta: float) -> void:
	if not _boss_alive or _victory_started:
		return
	_poll_timer -= delta
	if _poll_timer <= 0.0:
		_poll_timer = POLL_INTERVAL
		_check_boss_dead()


func _spawn_boss() -> void:
	if not ResourceLoader.exists(BOSS_SCENE_PATH):
		push_error("[BossArena] Boss.tscn missing — cannot spawn.")
		return
	var boss_scene: PackedScene = load(BOSS_SCENE_PATH)
	var boss: Node = boss_scene.instantiate()
	enemies_root.add_child(boss)
	if boss is Node2D:
		boss.global_position = Vector2(0, -60)
	_boss_alive = true
	_poll_timer = POLL_INTERVAL
	if banner_label:
		banner_label.text = "★ BOSS — SHADOW COMMANDER ★"
		banner_label.visible = true


func _check_boss_dead() -> void:
	var living: Array = get_tree().get_nodes_in_group("enemy")
	if living.is_empty():
		_boss_alive = false
		_on_boss_killed()


func _on_boss_killed() -> void:
	if _victory_started:
		return
	_victory_started = true
	# Run 43 — no spark in training mode (Dream World mini-bosses/bosses drop them).
	Log.dbg("[BossArena] Boss defeated. Chaining to Arena 11.")
	if banner_label:
		banner_label.text = "✦ BOSS DOWN ✦"
		banner_label.modulate = Color(1.0, 0.92, 0.40, 1.0)
	if hint_label:
		hint_label.text = "The path opens — Arena 11 awaits..."
	# Brief celebratory pause, then fade into the next arena.
	await get_tree().create_timer(VICTORY_HOLD).timeout
	if get_node_or_null("/root/FX") and FX.has_method("fade_to_black"):
		FX.fade_to_black(0.65, 0.20, 1.0, Callable(self, "_execute_complete_transition"))
	else:
		_execute_complete_transition()


func _execute_complete_transition() -> void:
	# Run 26f — chain to Arena 11 to start the second 10-arena leg. If that
	# scene is missing (e.g. dev playthrough), fall back to RunComplete so the
	# run still ends cleanly rather than soft-locking.
	if ResourceLoader.exists(NEXT_RUN_SCENE_PATH):
		get_tree().change_scene_to_file(NEXT_RUN_SCENE_PATH)
	else:
		get_tree().change_scene_to_file(RUN_COMPLETE_PATH)
