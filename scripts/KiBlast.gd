extends Area2D

# ============================================================
# KiBlast.gd — Shino's ranged Ki Blast (A attack)
# ============================================================
# Standard mode (Run 30): straight-line shot that DETONATES on first enemy
# hit — direct target takes full damage, then a small-medium AoE explosion
# (EXPLOSION_RADIUS) splashes EXPLOSION_DMG_PCT damage to nearby enemies.
# Ki blast goes boom. Distinct from Bea's Kunai (fast piercing line).
#
# Bananarang mode (Banana A-slot boon, RunState.bananarang_taken):
#   • Outward trip  — pierces every enemy, applies Slippery (or Sparked in GL).
#   • At max_range  — reverses back toward shooter.
#   • Return trip   — pierces every enemy, applies Greased (or Bolted in GL).
#   • Despawns when it returns close to the shooter or travels max_range back.
#
# Hit-cooldown system: same enemy can only be hit once per 0.25s to avoid
# frame-rate-dependent multi-hits, while still letting the same enemy receive
# both the outward (slippery) and return (greased) applications.
# ============================================================

@export var speed: float = 600.0
@export var damage: int = 8
@export var max_range: float = 480.0   # outward range in bananarang mode

# Run 58 — bananarang range trade-off (Bruno): the boomerang went out AND back
# at full straight-shot range, which felt too strong. Shorten the outward leg so
# it reads as a real boomerang — less reach, but still hits twice (out + return).
const BANANARANG_RANGE_MULT: float = 0.65   # −35% outward range

# Run 30 — impact explosion (standard mode only; bananarang pierces instead).
const EXPLOSION_RADIUS: float = 56.0    # Run 47 — was 80; −30% (too good vs clumps)
const EXPLOSION_DMG_PCT: float = 0.6    # splash = 60% of the blast's damage
# ---------------------------------------------------------------------------
# Run 162 — INNATE ranged pushback REMOVED (Bruno 2026-08-01)
# ---------------------------------------------------------------------------
# Ranged A is deliberately spammy and fast, and full-strength knockback on
# every shot perma-walled enemies away from the ninjas. Per the Run 49
# "knockback vector LENGTH is a strength scalar" convention, a zero vector
# means damage with no push at all. Speed and damage are untouched.
#
# BOON-GRANTED pushback is unaffected and still uses a real vector:
#   * Kunai.heavy_knockback  (Stone Throw)
#   * Seed Spit              (Watermelon A splash)
const INNATE_KNOCKBACK: Vector2 = Vector2.ZERO

const PIERCE_EXPLOSION_SCALE: float = 0.5   # Run 58 — Slugshot per-pierce burst: −50% radius & splash

var direction: Vector2 = Vector2.DOWN
var _traveled: float = 0.0

# Run 58 — Slugshot (Broccoli A): the blast pierces every enemy in a line instead
# of stopping on the first. Each pierced enemy still gets a reduced AoE burst
# (PIERCE_EXPLOSION_SCALE); it flies until max_range or a wall. Set by the
# spawner via set("_pierce_all", true).
var _pierce_all: bool = false
var _pierce_hit_set: Dictionary = {}   # one hit per enemy while piercing

# Run 59 — Grape Shot (Grape A): on standard-mode enemy impact, this blast
# spawns 2 smaller blasts in a fan at 40% damage. _is_grape_split = true means
# this blast is ITSELF a sub-shot and may not split again (no infinite cascade).
var _is_grape_split: bool = false
# Run 130 — Cluster Theory (Grape Legendary): split generation depth.
# 0 = original shot, 1 = first-level split, 2 = second-level (never splits).
var _split_depth: int = 0

# ── Bananarang state ──────────────────────────────────────────────────────────
var _is_bananarang: bool = false
var _bananarang_phase: int = 0   # 0 = outward, 1 = returning
var _shooter: Node = null        # back-reference for homing return
var _greased_lightning: bool = false

# Per-enemy hit cooldown so we don't multi-hit in one frame but can re-hit on return.
var _hit_cooldowns: Dictionary = {}

# Visual node refs
@onready var _sprite: ColorRect    = $Sprite
@onready var _glow_core: ColorRect = $GlowCore


func _ready() -> void:
	body_entered.connect(_on_body_entered)


# ── Launch API ────────────────────────────────────────────────────────────────
func launch(dir: Vector2, spd: float, dmg: int) -> void:
	direction = dir.normalized()
	speed = spd
	damage = dmg
	rotation = direction.angle() - PI * 0.5


func launch_bananarang(dir: Vector2, spd: float, dmg: int, shooter: Node, gl_mode: bool) -> void:
	launch(dir, spd, dmg)
	_is_bananarang = true
	_shooter = shooter
	_greased_lightning = gl_mode
	max_range *= BANANARANG_RANGE_MULT   # Run 58 — shorter boomerang reach
	_set_phase_visuals(0)


# ── Physics tick ──────────────────────────────────────────────────────────────
func _physics_process(delta: float) -> void:
	# Tick per-enemy hit cooldowns.
	for key in _hit_cooldowns.keys():
		_hit_cooldowns[key] -= delta
		if _hit_cooldowns[key] <= 0.0:
			_hit_cooldowns.erase(key)

	if _is_bananarang:
		_tick_bananarang(delta)
		return

	# ── Standard straight-line shot ──
	var move: Vector2 = direction * speed * delta
	position += move
	_traveled += move.length()
	if _traveled >= max_range:
		queue_free()


func _tick_bananarang(delta: float) -> void:
	var move: Vector2 = direction * speed * delta
	position += move
	_traveled += move.length()

	# Check overlapping bodies each frame (pierce mode).
	for body in get_overlapping_bodies():
		if not body.is_in_group("enemy"):
			continue
		if body in _hit_cooldowns:
			continue
		_hit_cooldowns[body] = 0.25   # 250ms before same enemy can be hit again
		_handle_bananarang_hit(body)

	if _bananarang_phase == 0:
		# Outward: reverse when we've reached max_range.
		if _traveled >= max_range:
			_begin_return()
	else:
		# Return: home toward shooter (or origin) until we're close or traveled back.
		var target_pos: Vector2 = _shooter.global_position \
			if is_instance_valid(_shooter) else global_position
		if global_position.distance_to(target_pos) < 18.0 or _traveled >= max_range * 1.1:
			queue_free()
			return
		# Steer gently back toward the shooter so it follows movement.
		var to_target: Vector2 = (target_pos - global_position).normalized()
		direction = direction.lerp(to_target, 0.08).normalized()
		rotation = direction.angle() - PI * 0.5


func _begin_return() -> void:
	_bananarang_phase = 1
	direction = -direction
	rotation = direction.angle() - PI * 0.5
	_traveled = 0.0
	_hit_cooldowns.clear()   # reset so outward-hit enemies can receive the return status
	_set_phase_visuals(1)
	FX.spawn_hit_particles(global_position,
		Color(0.30, 0.55, 1.0, 0.9) if not _greased_lightning else Color(0.30, 0.80, 1.0, 0.9), 5)


# ── Hit handling ──────────────────────────────────────────────────────────────
func _on_body_entered(body: Node) -> void:
	if body.is_in_group("water_collider"):
		return   # rivers are walked-around, not shot-through: fly over the water.
	if not body.is_in_group("enemy"):
		# Run 58 — anything else this projectile can collide with is a wall,
		# obstacle, or arena edge (collision_mask now includes World layer 1).
		# Ranged shots no longer pass through solids.
		_on_hit_wall()
		return
	if _is_bananarang:
		return   # handled in _tick_bananarang via get_overlapping_bodies
	# Run 58 — Slugshot pierce mode: hit each enemy once and detonate a SMALLER,
	# WEAKER burst on it (still a ki blast), then keep flying through the line.
	if _pierce_all:
		if _pierce_hit_set.has(body):
			return
		_pierce_hit_set[body] = true
		body.set_meta("last_damager", "shino")   # Run 134 — killer attribution (fix 5)
		FX.hit_rumble("shino")
		if body.has_method("take_damage"):
			body.take_damage(_effective_hit_damage(body), INNATE_KNOCKBACK)
		_route_through_player(body, damage)
		_explode(body, PIERCE_EXPLOSION_SCALE)
		FX.play_sound("ki_blast_hit", 0.55)
		return
	# Standard shot: damage + detonate + despawn.
	body.set_meta("last_damager", "shino")   # Run 134 — killer attribution (fix 5)
	FX.hit_rumble("shino")
	if body.has_method("take_damage"):
		body.take_damage(_effective_hit_damage(body), INNATE_KNOCKBACK)
	_route_through_player(body, damage)
	_explode(body)
	_spawn_impact()
	# Run 59 — Grape Shot: spawn sub-shots in a forward fan at 40% damage.
	# Only the ORIGINAL blast splits; sub-shots are flagged and skip this.
	# Run 130 — Cluster Theory (Grape Legendary): EVERY projectile splits on
	# impact, and first-level splits split ONE more time (depth 2 max).
	# Run 156 — per-hero gate. KiBlast is SHINO's projectile (same rule as
	# grape_shot/long_shot below); Kunai got this fix in Run 133 and this site
	# was missed, so Bea's Cluster Theory was splitting Shino's blasts.
	if RunState.shino_has("cluster_theory"):
		if _split_depth < 2:
			_spawn_grape_splits(global_position)
	elif not _is_grape_split and RunState.shino_has("grape_shot"):
		_spawn_grape_splits(global_position)
	queue_free()


# Run 27/27f — shared per-hit damage: Long Shot distance scaling + Toxic Aim
# (Carrot+Onion) bonus crit roll vs Poisoned targets.
func _effective_hit_damage(body: Node) -> int:
	var dmg: int = damage
	if RunState.shino_has("long_shot"):
		dmg = int(round(float(dmg) * (1.0 + minf(0.25, _traveled * 0.001))))
	if body.has_node("StatusComponent") and body.get_node("StatusComponent").has("poison"):
		if randf() < RunState.get_carrot_onion_crit_bonus():
			dmg = int(round(float(dmg) * 1.5))
			FX.spawn_hit_particles(global_position, Color(0.95, 0.55, 0.15, 1.0), 6)
	return dmg


# Run 58 — wall / obstacle / arena-edge impact.
func _on_hit_wall() -> void:
	if _is_bananarang:
		# Boomerang bounces off the world: turn around early on the way out,
		# give up if a wall is struck on the return leg.
		if _bananarang_phase == 0:
			_begin_return()
		else:
			queue_free()
		return
	# Standard shot detonates against the surface (no direct target) and leaves
	# a faint scorch where it hit.
	_explode(null)
	_spawn_impact()
	queue_free()


# Run 30 — impact detonation: splash EXPLOSION_DMG_PCT damage to every other
# enemy within EXPLOSION_RADIUS of the impact point. Splash hits count as
# ranged hits (family statuses + on-hit procs route through Shino).
# Run 58 — `power` scales both the AoE radius and the splash damage. Slugshot's
# piercing blast detonates a SMALLER, WEAKER burst on every enemy it passes
# through (PIERCE_EXPLOSION_SCALE) so it still feels like a ki blast without
# wiping a whole cluster. Standard single-detonation uses power = 1.0.
func _explode(direct_target: Node, power: float = 1.0) -> void:
	var radius: float = EXPLOSION_RADIUS * power
	var splash: int = max(1, int(round(float(damage) * EXPLOSION_DMG_PCT * power)))
	for e in get_tree().get_nodes_in_group("enemy"):
		if e == direct_target or not is_instance_valid(e) or not (e is Node2D):
			continue
		if e.global_position.distance_to(global_position) > radius:
			continue
		if e.has_method("take_damage"):
			var dir_to: Vector2 = (e.global_position - global_position).normalized()
			e.set_meta("last_damager", "shino")   # Run 134 — killer attribution (fix 5)
			FX.hit_rumble("shino")
			# Run 162 — the innate detonation pushes no one either.
			e.take_damage(splash, INNATE_KNOCKBACK)
			_route_through_player(e, splash)
	# Boom visuals — expanding lime-green ring + burst + tiny shake (scaled by power).
	FX.spawn_explosion_ring(global_position, radius,
		Color(0.55, 1.0, 0.65, 0.45), 0.22)
	FX.spawn_burst_particles(global_position, Color(0.65, 1.0, 0.70, 1.0), max(4, int(round(10 * power))))
	if power >= 1.0:
		FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_TINY)


func _handle_bananarang_hit(enemy: Node) -> void:
	if not enemy.has_method("take_damage"):
		return

	enemy.set_meta("last_damager", "shino")   # Run 134 — killer attribution (fix 5)
	FX.hit_rumble("shino")
	enemy.take_damage(damage, direction)
	_route_through_player(enemy, damage)

	# Apply the phase-appropriate banana status.
	var ts: Variant = enemy.get("status") if enemy.has_method("get") else null
	if ts != null and ts.has_method("apply"):
		if _bananarang_phase == 0:
			# Outward: lighter/CC-leading status
			var out_id: String = "sparked" if _greased_lightning else "slippery"
			ts.apply(out_id, 3.0, 1)
			FX.spawn_hit_particles(enemy.global_position,
				Color(0.85, 0.90, 0.25, 1.0) if not _greased_lightning else Color(0.50, 0.90, 0.30, 1.0), 5)
		else:
			# Return: heavier status
			var ret_id: String = "bolted" if _greased_lightning else "greased"
			ts.apply(ret_id, 5.0, 1)
			FX.spawn_hit_particles(enemy.global_position,
				Color(0.25, 0.55, 1.0, 1.0) if not _greased_lightning else Color(0.30, 0.80, 1.0, 1.0), 5)
	else:
		FX.spawn_hit_particles(enemy.global_position, Color(0.45, 0.95, 1.0, 1.0), 4)

	FX.play_sound("ki_blast_hit", 0.55)


func _route_through_player(body: Node, dmg: int) -> void:
	# Run 131 — KiBlast is SHINO's projectile (grape_shot/long_shot use shino_has).
	# Route on-hit effects to the Shino node specifically, not players[0]: in 2P
	# both heroes are in the "player" group, so index 0 could be Bea (who lacks
	# _apply_family_statuses_on_hit, silently dropping Shino's ranged procs).
	# The Shino node is the one in "player" that is NOT in "bea".
	var p: Node = null
	for cand in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(cand) and cand.has_method("_apply_family_statuses_on_hit") \
		and not cand.is_in_group("bea"):
			p = cand
			break
	if p == null:
		return
	p._apply_family_statuses_on_hit(body, false, false, true, false, false)
	if p.has_method("_on_hit_connected"):
		p._on_hit_connected(dmg)


# ── Visuals ───────────────────────────────────────────────────────────────────
func _set_phase_visuals(phase: int) -> void:
	if _sprite == null:
		return
	if phase == 0:
		# Outward: yellow-banana (default GL = electric green)
		_sprite.color    = Color(0.95, 0.85, 0.15, 1.0) if not _greased_lightning \
		                 else Color(0.45, 0.95, 0.30, 1.0)
		_glow_core.color = Color(1.0,  0.97, 0.60, 1.0) if not _greased_lightning \
		                 else Color(0.80, 1.0,  0.50, 1.0)
	else:
		# Return: cool blue-greased (GL = electric cyan)
		_sprite.color    = Color(0.20, 0.50, 1.0,  1.0) if not _greased_lightning \
		                 else Color(0.20, 0.80, 1.0,  1.0)
		_glow_core.color = Color(0.65, 0.82, 1.0,  1.0) if not _greased_lightning \
		                 else Color(0.55, 0.95, 1.0,  1.0)


func _spawn_impact() -> void:
	FX.spawn_hit_particles(global_position, Color(0.45, 0.95, 1.0, 1.0), 6)
	# Run 58 — leave a faint scorch where the blast hit the surface (fades ~3s).
	FX.spawn_scorch_decal(global_position)
	FX.play_sound("ki_blast_hit", 0.7)


# Run 59 — Grape Shot split spawner. Two smaller blasts in a forward fan at
# 40% damage. Each sub-shot is flagged _is_grape_split = true so it cannot
# trigger another split on its own impact (one-level only — Cluster Theory
# legendary handles the recursive multi-level case separately).
func _spawn_grape_splits(at_pos: Vector2) -> void:
	var scene: PackedScene = load("res://scenes/KiBlast.tscn") as PackedScene
	if scene == null:
		return
	var parent: Node = get_parent()
	if parent == null:
		return
	var sub_dmg: int = max(1, int(round(float(damage) * RunState.GRAPE_SPLIT_DMG_MULT)))
	var half_fan: float = deg_to_rad(RunState.GRAPE_SPLIT_FAN_DEG)
	var count: int = RunState.GRAPE_SPLIT_COUNT
	for i in count:
		# Symmetric distribution across [-half_fan, +half_fan].
		# count=1 → t=0 (straight); count=2 → t=-1,+1; count=3 → t=-1,0,+1; etc.
		var t: float = 0.0
		if count > 1:
			t = (float(i) / float(count - 1)) * 2.0 - 1.0
		var sub_dir: Vector2 = direction.rotated(t * half_fan)
		var sub: Node2D = scene.instantiate()
		parent.add_child(sub)
		sub.global_position = at_pos + sub_dir * 10.0
		sub.scale = Vector2.ONE * RunState.GRAPE_SPLIT_SCALE
		# Purple-grape tint so splits read distinctly.
		sub.modulate = Color(0.85, 0.55, 1.0, 1.0)
		if sub.has_method("set"):
			sub.set("_is_grape_split", true)
			sub.set("_split_depth", _split_depth + 1)   # Run 130 — Cluster Theory recursion
		if sub.has_method("launch"):
			sub.launch(sub_dir, speed * 0.92, sub_dmg)
	FX.spawn_hit_particles(at_pos, Color(0.85, 0.55, 1.0, 1.0), 6)
