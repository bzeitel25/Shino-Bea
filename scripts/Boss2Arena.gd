extends Node2D

# ============================================================
# Boss2Arena.gd — Triheaded Wyrm arena (Run 26f)
# ============================================================
# Mirror of BossArena.gd but spawns Boss2 (3-headed dragon) and goes
# straight to RunComplete on victory. This is the temporary final boss
# for the 20-arena test runs.
# ============================================================

const BOSS2_SCENE_PATH:  String = "res://scenes/Boss2.tscn"
const RUN_COMPLETE_PATH: String = "res://scenes/RunComplete.tscn"
const POLL_INTERVAL:     float = 0.30
const VICTORY_HOLD:      float = 2.4

@onready var enemies_root: Node2D = $Enemies
@onready var banner_label: Label  = $DebugHUD/BannerLabel
@onready var hint_label:   Label  = $DebugHUD/HintLabel

var _boss_alive: bool = false
var _poll_timer: float = 0.0
var _victory_started: bool = false


func _ready() -> void:
	Log.dbg("[Boss2Arena] _ready — spawning Triheaded Wyrm.")
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
	if not ResourceLoader.exists(BOSS2_SCENE_PATH):
		push_error("[Boss2Arena] Boss2.tscn missing — cannot spawn.")
		return
	var boss_scene: PackedScene = load(BOSS2_SCENE_PATH)
	var boss: Node = boss_scene.instantiate()
	enemies_root.add_child(boss)
	if boss is Node2D:
		boss.global_position = Vector2(0, -100)
	_boss_alive = true
	_poll_timer = POLL_INTERVAL
	if banner_label:
		banner_label.text = "🐉 BOSS — TRIHEADED WYRM 🐉"
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
	Log.dbg("[Boss2Arena] Triheaded Wyrm defeated — transitioning to RunComplete.")
	if banner_label:
		banner_label.text = "✦ VICTORY ✦"
		banner_label.modulate = Color(1.0, 0.92, 0.40, 1.0)
	if hint_label:
		hint_label.text = "Run complete..."
	await get_tree().create_timer(VICTORY_HOLD).timeout
	if get_node_or_null("/root/FX") and FX.has_method("fade_to_black"):
		FX.fade_to_black(0.65, 0.20, 1.0, Callable(self, "_execute_complete_transition"))
	else:
		_execute_complete_transition()


func _execute_complete_transition() -> void:
	get_tree().change_scene_to_file(RUN_COMPLETE_PATH)
