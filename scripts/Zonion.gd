extends Node2D

# ============================================================
# Zonion.gd — Run 130 — Plague Layer (Onion Legendary) minion.
# ============================================================
# A friendly onion-zombie raised when a poisoned enemy dies.
# Walks toward the nearest living enemy, melee-pokes it (small
# damage + 1 Poison stack toward the player's current cap), and
# permanently dies after LIFETIME seconds. A Zonion's kill of a
# poisoned enemy raises another Zonion via the same death hook —
# the plague chains itself.
# Placeholder visual: layered green circles (art pass later).
# ============================================================

const LIFETIME: float = 10.0
const MOVE_SPEED: float = 88.0
const ATTACK_RANGE: float = 34.0
const ATTACK_CD: float = 0.8
const ATTACK_DMG: int = 3

var _life: float = LIFETIME
var _atk_cd: float = 0.0


func _ready() -> void:
	z_index = 2
	queue_redraw()


func _draw() -> void:
	# Placeholder onion-zombie: body + head rings, sickly green.
	draw_circle(Vector2(0, 2), 9.0, Color(0.55, 0.70, 0.30, 0.95))
	draw_circle(Vector2(0, -8), 6.0, Color(0.70, 0.82, 0.45, 0.95))
	draw_circle(Vector2(-2, -9), 1.4, Color(0.10, 0.12, 0.05))
	draw_circle(Vector2(2, -9), 1.4, Color(0.10, 0.12, 0.05))


func _process(delta: float) -> void:
	_life -= delta
	if _life <= 0.0:
		FX.spawn_hit_particles(global_position, Color(0.60, 0.75, 0.35, 0.8), 6)
		queue_free()
		return
	if _atk_cd > 0.0:
		_atk_cd -= delta
	# Fade out over the last 2 seconds.
	modulate.a = clampf(_life / 2.0, 0.35, 1.0)

	var best: Node2D = null
	var best_d: float = 99999.0
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or not (e is Node2D):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		var d: float = global_position.distance_to((e as Node2D).global_position)
		if d < best_d:
			best_d = d
			best = e
	if best == null:
		return
	if best_d > ATTACK_RANGE:
		global_position = global_position.move_toward(best.global_position, MOVE_SPEED * delta)
	elif _atk_cd <= 0.0:
		_atk_cd = ATTACK_CD
		if best.has_method("take_damage"):
			best.take_damage(ATTACK_DMG, (best.global_position - global_position).normalized() * 0.2)
		if best.has_node("StatusComponent"):
			best.get_node("StatusComponent").apply("poison", 4.0, 1)
		FX.spawn_hit_particles(best.global_position, Color(0.70, 0.85, 0.40, 0.9), 4)
