extends Node2D

# ============================================================
# BossHazard.gd - Run 173 - timed damaging ground field
# ============================================================
# Spawned by BossBrain's "hazard" move kind (fry-oil geysers, brine bogs,
# ember pools, ...). Deliberately NOT TrapZone.gd: TrapZone is a permanent
# room fixture baked at layout time with its own visual vocabulary, while a
# boss hazard is transient, self-owned and must clean itself up when the
# fight ends.
#
# Life cycle: RED warning ring (warmup) -> live pool that ticks damage +
# a status onto any hero standing in it (duration) -> fade out -> free.
# The warmup is the dodge window, so it is always drawn RED (locked rule)
# regardless of what colour the live pool is.
# ============================================================

var radius: float = 70.0
var duration: float = 4.0
var warmup: float = 0.55
var tick_interval: float = 0.6
var tick_damage: int = 6
var pool_color: Color = Color(1.0, 0.55, 0.12, 0.34)

# Status payload applied on every tick. "" = damage only.
var status_id: String = ""          # "burning" | "poison" | "bash"
var status_stacks: int = 1
var status_duration: float = 3.0
var frost_stacks: int = 0           # heroes expose add_frost_stack()

const WARN_COLOR: Color = Color(1.0, 0.16, 0.06, 0.30)
const FADE_TIME: float = 0.45

var _age: float = 0.0
var _tick_t: float = 0.0
var _alpha: float = 1.0


func _ready() -> void:
	# Run 176 — freeze with every other enemy attack during an ultimate
	# (UltFreeze's "enemy_attack" contract, Run 168).
	add_to_group("enemy_attack")
	# Under the fighters, over the floor - same band the trap pools use.
	z_index = -1
	_tick_t = tick_interval
	queue_redraw()


func _process(delta: float) -> void:
	_age += delta

	if _age < warmup:
		queue_redraw()
		return

	var live_age: float = _age - warmup
	if live_age >= duration:
		# Fade out, then free.
		var over: float = live_age - duration
		_alpha = clampf(1.0 - over / FADE_TIME, 0.0, 1.0)
		queue_redraw()
		if _alpha <= 0.0:
			queue_free()
		return

	_tick_t -= delta
	if _tick_t <= 0.0:
		_tick_t = tick_interval
		_apply_tick()
	queue_redraw()


func _apply_tick() -> void:
	for h in get_tree().get_nodes_in_group("player"):
		if not (h is Node2D) or not (h as Node2D).visible:
			continue
		if h.has_method("is_downed") and h.is_downed():
			continue
		if (h as Node2D).global_position.distance_to(global_position) > radius:
			continue
		if tick_damage > 0 and h.has_method("take_damage"):
			h.take_damage(tick_damage)
		if status_id != "":
			var hs: Node = h.get_node_or_null("StatusComponent")
			if hs and hs.has_method("apply"):
				hs.apply(status_id, status_duration, status_stacks)
		if frost_stacks > 0 and h.has_method("add_frost_stack"):
			h.add_frost_stack(frost_stacks)


func _draw() -> void:
	if _age < warmup:
		# Telegraph: RED ring that fills as the pool arms itself.
		var t: float = clampf(_age / maxf(0.01, warmup), 0.0, 1.0)
		draw_circle(Vector2.ZERO, radius, WARN_COLOR)
		draw_arc(Vector2.ZERO, radius * (0.25 + 0.75 * t), 0.0, TAU, 40,
			Color(1.0, 0.25, 0.15, 0.85), 2.0, true)
		return

	var col: Color = pool_color
	col.a *= _alpha
	draw_circle(Vector2.ZERO, radius, col)
	var rim: Color = Color(col.r, col.g, col.b, minf(1.0, col.a * 2.1))
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 44, rim, 2.0, true)
