extends Area2D

# ============================================================
# SpinningCraneKick.gd — Shino X-charge release (§8.2.1)
# ============================================================
# In-place 360° AoE radial hitbox. Damages all enemies that
# enter the 80px radius circle during the scene's lifetime.
# Uses body_entered signal (not get_overlapping_bodies poll)
# so hits resolve correctly even when spawned mid-physics-step.
#
# Fix: previous call_deferred("_resolve_hits") + get_overlapping_bodies()
# fired before PhysicsServer2D had a chance to populate overlaps for the
# newly-spawned Area2D, resulting in 0 hits. body_entered fires as
# physics actually detects each overlap, guaranteed per Godot's order.
# ============================================================

# Run 48 — reworked per Bruno: not an expanding ring, but Shino's leg as a
# single fast blade doing a double spin in place (Bea's Y-charge fan, single-
# blade edition). Zero mobility → big reward: heavy damage (never a one-shot,
# capped at 70% of target max HP), strong outward knockback, and a 0.5s stun
# once the pushback settles. Area clear: dash into a pack, vacate the space.
@export var damage: int = 26        # Run 48 — was 18; big close-range payoff
@export var radius: float = 90.0    # Run 48 — was 120; tad larger than kick reach (68px)
@export var lifetime: float = 0.45  # double spin window — very fast swirl

const SPIN_COUNT: float = 2.0           # full rotations across lifetime
const KNOCKBACK_OUT: float = 430.0      # outward shove (enemy base impulse is 200)
const STUN_TOTAL: float = 0.85          # ≈0.35s pushback travel + 0.5s standing stun
const DMG_MAX_HP_CAP: float = 0.70      # never one-shot: cap at 70% of target max HP

var _age: float = 0.0
var _pivot: Node2D = null
var _hit_targets: Dictionary = {}   # de-dupe (instance id → true)
var _player_ref: Node = null
var _scaled_dmg: int = 0


func _ready() -> void:
	# Big Broccoli: scale radius by 1.5×. Must update BOTH the physics CircleShape2D
	# (lives in the .tscn — hardcoded 120px) AND the visual ring variable.
	# Run 131 — Fury Release also widens the charge AoE (Shino's charge move).
	var bb_mult: float = RunState.get_big_broccoli_aoe_mult() * RunState.get_fury_release_area_mult("shino")
	radius *= bb_mult
	var cshape: CollisionShape2D = get_node_or_null("CollisionShape2D")
	if cshape and cshape.shape is CircleShape2D:
		cshape.shape.radius = radius   # sync physics shape to the (possibly scaled) radius

	# Collision layers mirror the scene file (layer 8 = PlayerHitbox, mask 4 = Enemy).
	collision_layer = 8
	collision_mask = 4
	monitoring = true
	monitorable = false

	# Cache player ref + pre-scale damage once so every hit uses the same roll.
	# Run 131 — this is SHINO's charge move; route through the Shino node (in the
	# "player" group but NOT "bea"), not players[0] which can be Bea in 2P. Tag
	# the scale as "charge" so Fury Release's +60% charge damage applies.
	for cand in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(cand) and cand.has_method("_scale_damage") and not cand.is_in_group("bea"):
			_player_ref = cand
			break
	if _player_ref and _player_ref.has_method("_scale_damage"):
		_scaled_dmg = _player_ref._scale_damage(damage, true, false, null, "charge")
	else:
		_scaled_dmg = max(1, int(round(damage * RunState.get_char_damage_mult("shino") * RunState.roll_crit_mult())))   # Run 139 — crane kick is Shino-only

	# Connect signal — fires as PhysicsServer actually resolves each overlap.
	body_entered.connect(_on_body_entered)

	# Also schedule a one-physics-frame-deferred sweep to catch enemies that
	# were ALREADY overlapping at spawn (body_entered doesn't fire for pre-existing
	# overlaps; only new entries). This gives physics exactly one step to settle.
	call_deferred("_sweep_existing_overlaps")

	# Run 48 — build the spinning leg "blade": a crescent at the kick radius,
	# parented to a pivot that _process whips around SPIN_COUNT full turns.
	# A fainter trailing ghost blade sells the swirl/afterimage.
	_pivot = Node2D.new()
	_pivot.z_index = 8
	add_child(_pivot)
	var blade := Polygon2D.new()
	var pts := PackedVector2Array()
	var seg: int = 10
	var half: float = deg_to_rad(34.0)
	for i in range(seg + 1):
		var a: float = lerp(-half, half, float(i) / float(seg))
		pts.append(Vector2(cos(a), sin(a)) * radius)
	for i in range(seg + 1):
		var a2: float = lerp(half, -half, float(i) / float(seg))
		var center_t: float = 1.0 - absf(a2) / half
		pts.append(Vector2(cos(a2), sin(a2)) * (radius * (1.0 - 0.30 * center_t)))
	blade.polygon = pts
	blade.color = Color(0.55, 0.92, 1.0, 0.85)
	_pivot.add_child(blade)
	var ghost: Polygon2D = blade.duplicate()
	ghost.rotation = -0.5   # trails behind the leading blade
	ghost.color = Color(0.55, 0.92, 1.0, 0.30)
	_pivot.add_child(ghost)
	# Run 49b (Bruno) — two leg bars opposite each other, running from Shino out
	# to the AoE perimeter. Shows the impact fills the WHOLE circle, not just
	# the outer edge (Bea's lunge-tornado look, two-blade "legs" edition).
	for leg_i in range(2):
		var leg := Polygon2D.new()
		var hw: float = 6.0   # leg bar half-width
		leg.polygon = PackedVector2Array([
			Vector2(6.0, -hw),
			Vector2(radius * 0.97, -hw * 1.6),   # slight flare at the foot
			Vector2(radius * 0.97, hw * 1.6),
			Vector2(6.0, hw),
		])
		leg.color = Color(0.65, 0.95, 1.0, 0.55)
		leg.rotation = PI * float(leg_i)   # 0 and 180° — opposite legs
		_pivot.add_child(leg)
		# Faint trailing ghost per leg to sell the swirl.
		var leg_ghost: Polygon2D = leg.duplicate()
		leg_ghost.rotation = leg.rotation - 0.45
		leg_ghost.color = Color(0.65, 0.95, 1.0, 0.20)
		_pivot.add_child(leg_ghost)


func _sweep_existing_overlaps() -> void:
	# Catches enemies already inside the radius when the scene spawned.
	for body in get_overlapping_bodies():
		_on_body_entered(body)


func _on_body_entered(body: Node) -> void:
	if body == null or not is_instance_valid(body):
		return
	var id: int = body.get_instance_id()
	if _hit_targets.has(id):
		return
	if not body.is_in_group("enemy") or not body.has_method("take_damage"):
		return
	_hit_targets[id] = true

	# Radial knockback — push outward from kick centre.
	var dir: Vector2 = body.global_position - global_position
	if dir.length() < 0.01:
		dir = Vector2.RIGHT
	dir = dir.normalized()

	# Run 48 — never a one-shot: cap the hit at DMG_MAX_HP_CAP of max HP.
	var dmg: int = _scaled_dmg
	var t_max: int = int(body.get("max_hp")) if "max_hp" in body else 0
	if t_max > 0:
		dmg = mini(dmg, maxi(1, int(float(t_max) * DMG_MAX_HP_CAP)))

	var was_alive: bool = (not body.has_method("is_alive")) or body.is_alive()
	body.set_meta("last_damager", "shino")   # Run 134 — killer attribution (fix 5)
	body.take_damage(dmg, dir)

	# Run 48 — area-clear feel: heavy outward shove (override the base 200
	# impulse from take_damage), then a stun. Bash is applied immediately but
	# enemies still travel on knockback while Bashed (Enemy/DummyEnemy keep
	# decaying _knockback_vel under movement lock), so it plays as: pushed out
	# ~0.35s → stands stunned ~0.5s.
	# Run 150 (Bruno fix 9): breakbar hosts (boss/miniboss) are never shoved —
	# the crane kick's bash below still chips their breakbar via the intercept.
	var _sc: Node = body.get_node("StatusComponent") if body.has_node("StatusComponent") else null
	var _bb_up: bool = _sc != null and _sc.breakbar_enabled and not _sc.is_breakbar_broken()
	if "_knockback_vel" in body and not _bb_up:
		body._knockback_vel = dir * KNOCKBACK_OUT
	if _sc != null:
		_sc.apply("bash", STUN_TOTAL, 1)

	# Notify player for chi/combo book-keeping + charge-kill healing.
	if _player_ref and is_instance_valid(_player_ref):
		if _player_ref.has_method("_on_charge_hits_dealt"):
			_player_ref._on_charge_hits_dealt(_scaled_dmg, 1)
		if was_alive and body.has_method("is_alive") and not body.is_alive():
			if _player_ref.has_method("_apply_charge_kill_heal"):
				_player_ref._apply_charge_kill_heal()

	# Feel — small burst per hit.
	if get_node_or_null("/root/FX") != null:
		FX.spawn_hit_particles(body.global_position, Color(0.60, 0.92, 1.0, 1.0), 6)


func _process(delta: float) -> void:
	_age += delta
	var t: float = clamp(_age / lifetime, 0.0, 1.0)
	# Run 48 — whip the blade around SPIN_COUNT full turns, fading out over
	# the last third of the spin.
	if _pivot:
		_pivot.rotation = TAU * SPIN_COUNT * t
		_pivot.modulate.a = clamp((1.0 - t) / 0.35, 0.0, 1.0)
	if _age >= lifetime:
		queue_free()
