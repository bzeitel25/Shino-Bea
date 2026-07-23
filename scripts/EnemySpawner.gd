extends Node2D

# ============================================================
# EnemySpawner.gd — Wave-based enemy spawn controller (Phase 5)
# ============================================================
# Spawns a wave of enemies distributed around the arena center,
# then monitors the "enemy" group until all are dead.
#
# Usage:
#   - Add as a child of World.
#   - Set enemy_scene to DummyEnemy.tscn (or any enemy scene).
#   - Connect wave_cleared signal in World.gd to open a gate,
#     advance to the next arena, etc.
#
# Arena coords (Phase 1 layout):
#   Playable floor: x ∈ [-464, +464], y ∈ [-336, +336]
#   (walls are at ±496 / ±368, 32px thick, so inner edge ±480/±352,
#    minus 16px enemy half-body = safe spawn area ±464/±336)
# ============================================================

signal wave_cleared

@export var enemy_scene: PackedScene          # Primary enemy (e.g., DummyEnemy.tscn)
@export var spawn_count: int = 4              # Total enemies per wave
@export var min_spawn_dist: float = 120.0     # Min distance from arena center (avoid spawning on player)
@export var max_spawn_dist: float = 240.0     # Max distance from arena center

# Optional secondary enemy variant — if set, the spawner mixes it in.
@export var secondary_scene: PackedScene = null
@export var secondary_count: int = 0          # How many of the secondary enemy to spawn (in addition to primary)

# Optional tertiary enemy variant — for mixing in a third enemy type (e.g., FastScout
# alongside melee dummies + ranged shooters). Run 9 addition.
@export var tertiary_scene: PackedScene = null
@export var tertiary_count: int = 0

# How often (seconds) we poll the enemy group for wave completion.
# Polling is cheap; using tree_exited signals would require bookkeeping
# per-instance and is error-prone during multi-kill frames (e.g., Ult).
const POLL_INTERVAL: float = 0.25
var _poll_timer: float = 0.0

var _wave_active: bool = false
var _spawned_count: int = 0


func _ready() -> void:
	# Spawn one frame after _ready so World.gd has time to connect signals.
	call_deferred("_spawn_wave")


func _process(delta: float) -> void:
	if not _wave_active:
		return
	_poll_timer -= delta
	if _poll_timer <= 0.0:
		_poll_timer = POLL_INTERVAL
		_check_wave_cleared()


# ---------------------------------------------------------------------------
# Wave spawning
# ---------------------------------------------------------------------------

func _spawn_wave() -> void:
	if enemy_scene == null:
		push_warning("[EnemySpawner] enemy_scene is null — nothing to spawn.")
		return

	# Total to spawn = primary + secondary + tertiary (if any are set)
	var sec_n: int = secondary_count if secondary_scene != null else 0
	var ter_n: int = tertiary_count  if tertiary_scene  != null else 0
	var total_count: int = spawn_count + sec_n + ter_n
	_spawned_count = total_count
	_wave_active   = true
	_poll_timer    = POLL_INTERVAL

	for i in total_count:
		# Choose which scene to use based on index:
		#   [0, spawn_count)              → primary
		#   [spawn_count, +sec_n)         → secondary
		#   [spawn_count + sec_n, +ter_n) → tertiary
		var scene_to_use: PackedScene = enemy_scene
		if i >= spawn_count + sec_n and tertiary_scene != null:
			scene_to_use = tertiary_scene
		elif i >= spawn_count and secondary_scene != null:
			scene_to_use = secondary_scene
		var e: Node = scene_to_use.instantiate()
		get_parent().add_child(e)

		var base_angle: float   = (TAU / total_count) * i
		var jitter_angle: float = randf_range(-0.4, 0.4)
		var angle: float        = base_angle + jitter_angle
		var dist: float         = randf_range(min_spawn_dist, max_spawn_dist)

		# Shooters (secondary) prefer outer ring. Scouts (tertiary) inner ring
		# so they get into player's face fast.
		if i >= spawn_count + sec_n and tertiary_scene != null:
			dist = min(dist, min_spawn_dist + 40.0)
		elif i >= spawn_count and secondary_scene != null:
			dist = max(dist, (min_spawn_dist + max_spawn_dist) * 0.5 + 30.0)

		var pos: Vector2 = Vector2(cos(angle) * dist, sin(angle) * dist)
		pos.x = clamp(pos.x, -440.0, 440.0)
		pos.y = clamp(pos.y, -310.0, 310.0)
		e.global_position = pos

	var suffix: String = " (%d primary" % spawn_count
	if sec_n > 0:
		suffix += " + %d secondary" % sec_n
	if ter_n > 0:
		suffix += " + %d tertiary" % ter_n
	suffix += ")"
	print("[EnemySpawner] Wave started — %d enemies spawned.%s" % [total_count, suffix])


# ---------------------------------------------------------------------------
# Wave completion check
# ---------------------------------------------------------------------------

func _check_wave_cleared() -> void:
	var living_enemies: Array = get_tree().get_nodes_in_group("enemy")
	if living_enemies.is_empty():
		_wave_active = false
		print("[EnemySpawner] Wave cleared!")
		emit_signal("wave_cleared")
