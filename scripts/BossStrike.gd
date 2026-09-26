extends Node2D

# ============================================================
# BossStrike.gd - Run 176 - one telegraphed ground impact
# ============================================================
# The building block for every "read the floor and get out" attack the bosses
# throw: lobbed scoops, travelling shockwaves, donut rings, geysers erupting
# one after another under your feet, the landing marker of a leap.
#
# Life cycle: RED telegraph that FILLS as the hit approaches (the fill is the
# timer - locked rule: enemy telegraphs are always red) -> impact (damage,
# knockback, statuses, burst) -> free. Nothing else.
#
# Why a node instead of a SceneTreeTimer on the boss: a staggered pattern has
# impacts landing up to ~2s after the boss decided on them. As a node in the
# "enemy_attack" group, UltFreeze freezes it with every other enemy attack
# during an ultimate (Run 168 contract), and it cancels itself if its boss
# dies so nothing hits you after the fight is won.
#
# `visual_only` markers (leap landing zones) never deal damage themselves -
# the boss that owns them moves them while it tracks the hero and resolves
# the landing itself; `release()` fades them out.
# ============================================================

var radius: float = 80.0
var inner_radius: float = 0.0          # > 0 = donut: the centre is SAFE
var delay: float = 0.8                 # seconds until impact
var visual_only: bool = false

# Resolved damage payload (the boss computes these up front).
var damage: int = 10
var knockback: float = 0.0
var stun: float = 0.0
var poison_stacks: int = 0
var poison_duration: float = 4.0
var burn_stacks: int = 0
var burn_duration: float = 3.0
var frost_stacks: int = 0

var burst_color: Color = Color(1.0, 0.55, 0.20, 0.9)
var shake: float = 4.0

# Optional lingering pool left behind by the impact (BossHazard config dict).
var leave_hazard: Dictionary = {}

var owner_boss: Node = null

const FILL: Color = Color(1.0, 0.16, 0.06, 0.26)
const EDGE: Color = Color(1.0, 0.25, 0.12, 0.90)
const LOCK: Color = Color(1.0, 0.08, 0.04, 0.42)
const HazardGD = preload("res://scripts/BossHazard.gd")

var _age: float = 0.0
var _locked: bool = false            # markers: flips to the "locked" look
var _fading: float = -1.0


func _ready() -> void:
	add_to_group("enemy_attack")
	z_index = -1
	queue_redraw()


# Markers: the owner calls this once the landing spot is final.
func lock() -> void:
	_locked = true
	queue_redraw()


# Markers: the owner calls this on touchdown.
func release() -> void:
	_fading = 0.18


func _process(delta: float) -> void:
	if _fading >= 0.0:
		_fading -= delta
		modulate.a = clampf(_fading / 0.18, 0.0, 1.0)
		if _fading <= 0.0:
			queue_free()
		return

	# A strike whose boss is already dead never lands.
	if owner_boss != null and not is_instance_valid(owner_boss):
		queue_free()
		return

	_age += delta
	queue_redraw()
	if visual_only:
		return
	if _age >= delay:
		_impact()
		queue_free()


func _impact() -> void:
	FX.spawn_explosion_ring(global_position, radius, Color(1.0, 0.45, 0.2, 0.45), 0.24)
	FX.spawn_burst_particles(global_position, burst_color, 10 if radius < 90.0 else 16)
	if shake > 0.0:
		FX.screen_shake(shake, 0.18)

	for h in get_tree().get_nodes_in_group("player"):
		if not (h is Node2D) or not (h as Node2D).visible:
			continue
		if h.has_method("is_downed") and h.is_downed():
			continue
		var d: float = (h as Node2D).global_position.distance_to(global_position)
		if d > radius or d < inner_radius:
			continue
		if not h.has_method("take_damage"):
			continue
		if knockback > 0.0:
			var kdir: Vector2 = ((h as Node2D).global_position - global_position)
			if kdir.length() < 0.01:
				kdir = Vector2.DOWN
			h.take_damage(damage, kdir.normalized() * knockback)
		else:
			h.take_damage(damage)
		var hs: Node = h.get_node_or_null("StatusComponent")
		if hs and hs.has_method("apply"):
			if stun > 0.0:
				hs.apply("bash", stun, 1)
			if poison_stacks > 0:
				hs.apply("poison", poison_duration, poison_stacks)
			if burn_stacks > 0:
				hs.apply("burning", burn_duration, burn_stacks)
		if frost_stacks > 0 and h.has_method("add_frost_stack"):
			h.add_frost_stack(frost_stacks)

	if not leave_hazard.is_empty():
		var parent: Node = get_parent()
		if parent != null:
			var hz: Node2D = Node2D.new()
			hz.set_script(HazardGD)
			for k in leave_hazard.keys():
				hz.set(k, leave_hazard[k])
			hz.set("warmup", 0.0)        # the strike WAS the telegraph
			parent.add_child(hz)
			hz.global_position = global_position


func _draw() -> void:
	var t: float = 1.0 if visual_only else clampf(_age / maxf(0.01, delay), 0.0, 1.0)
	var fill: Color = LOCK if _locked else FILL
	if inner_radius > 0.0:
		# Donut: paint the ring band only, so the safe centre reads as safe.
		var mid: float = (radius + inner_radius) * 0.5
		draw_arc(Vector2.ZERO, mid, 0.0, TAU, 56, fill, radius - inner_radius, true)
		draw_arc(Vector2.ZERO, inner_radius, 0.0, TAU, 48, EDGE, 2.0, true)
	else:
		draw_circle(Vector2.ZERO, radius, fill)
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 48, EDGE, 2.0, true)
	if not visual_only:
		# The closing ring IS the timer: it shrinks onto the edge as impact nears.
		var r: float = lerpf(radius * 0.18, radius, t)
		if inner_radius > 0.0:
			r = lerpf(inner_radius, radius, t)
		draw_arc(Vector2.ZERO, r, 0.0, TAU, 40, Color(1.0, 0.85, 0.75, 0.70), 2.0, true)
	elif _locked:
		# Locked landing marker: a crosshair so "it's coming HERE" is unmistakable.
		var a: float = radius * 0.35
		draw_line(Vector2(-a, 0), Vector2(a, 0), EDGE, 2.0)
		draw_line(Vector2(0, -a), Vector2(0, a), EDGE, 2.0)
