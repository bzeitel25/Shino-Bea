extends Area2D

# ============================================================
# Kunai.gd — Bea's ranged Kunai throw
# ============================================================
# Standard mode (Run 30): very fast straight-line throw that pierces through
# EVERY enemy it hits — each enemy is damaged once (de-duped via _hit_set) and
# the blade keeps flying until max_range. Distinct from Shino's Ki Blast,
# which detonates on first impact (AoE boom). Kunai = fast piercing line.
#
# Bananarang mode (Banana A-slot boon):
#   • Outward — pierces every enemy, applies Slippery/Sparked.
#   • Reverses at max_range, homes back to Bea.
#   • Return  — pierces every enemy, applies Greased/Bolted.
#   Shares the same architecture as KiBlast bananarang.
# ============================================================

@export var speed: float = 1150.0      # Run 30 — much faster flight than the old 720
@export var damage: int = 9            # Run 30 — bumped from 7
@export var max_range: float = 480.0   # outward range (bananarang mode)

# Pierce config. N > 0 = despawn after N hits. 0 = pierce ALL enemies in a line.
# Run 58 (Bruno): the kunai now STOPS on first impact by default (was pierce-all)
# — Bea's ranged identity is the on-hit Bleed, mirroring Shino's blast detonating
# on first hit (his identity is the AoE). Pierce is now strictly a BOON: Slugshot
# (Broccoli) sets this to 0 (pierce all), Stone Throw (Potato) to 2 (pierce one).
# BALANCE TOGGLE: boons override at spawn time via `k.pierce_limit = X`
# — keep all pierce behavior routed through this one variable.
@export var pierce_limit: int = 1

# Run 49 — minimal-stagger knockback (Bruno): kunai spam was perma-walling
# enemies. The hit vector's LENGTH is now a knockback-strength scalar (enemies
# clamp it to ≤1.0, so every existing normalized-vector caller is unchanged).
# 0.25 = small stagger flinch; enemies keep pushing toward Bea.
const KNOCKBACK_SCALE: float = 0.25
## Run 162 — innate ranged pushback is OFF. Kept KNOCKBACK_SCALE above as the
## historical value so the old feel is one edit away if it's ever wanted back.
const INNATE_KNOCKBACK_SCALE: float = 0.0

# Run 58 — Stone Throw (Potato A) makes the kunai a heavy rock: full-strength
# knockback (scalar 1.0, the in-system max) instead of the light 0.25 flinch, so
# spamming really shoves the closest mob back. Set by the spawner.
@export var heavy_knockback: bool = false

# Run 58 — bananarang range trade-off (Bruno): shorten the outward leg so the
# kunai-rang reads as a real boomerang — less reach, but still hits twice.
const BANANARANG_RANGE_MULT: float = 0.65   # −35% outward range

# Run 58 — kunai sticks where it lands. On hitting a wall / obstacle / arena edge
# the blade embeds in the surface and lingers, fading over STICK_LIFETIME; it also
# leaves a brief embedded blade in enemies it pierces. Bea wields sharp steel, so
# all her blade hits (kunai + melee) apply a light Bleed — see BeaAI.
const STICK_LIFETIME: float = 3.0
var _stuck: bool = false

# Run 30b — shuriken mode: swaps the kunai blade visuals for a spinning
# 4-point star. Set via make_shuriken() before launch.
const SHURIKEN_SPIN_SPEED: float = 18.0   # rad/s visual spin
var _is_shuriken: bool = false
var _shuriken_tint: Color = Color(1.0, 0.85, 0.35, 1.0)

var direction: Vector2 = Vector2.DOWN
var _traveled: float = 0.0
var _pierced_count: int = 0
var _hit_set: Dictionary = {}   # one hit per enemy per throw (pierce de-dupe)

# Run 59 — Grape Shot (Grape A): on first enemy impact, fan out 2 smaller
# kunais at 40% damage. Splits are flagged so they cannot re-split (one level).
var _is_grape_split: bool = false
# Run 130 — Cluster Theory (Grape Legendary): split generation depth
# (0 = original, 1 = first split, 2 = final — never splits again).
var _split_depth: int = 0

# ── Bananarang state ──────────────────────────────────────────────────────────
var _is_bananarang: bool = false
var _bananarang_phase: int = 0   # 0 = outward, 1 = returning
var _shooter: Node = null
var _greased_lightning: bool = false
var _hit_cooldowns: Dictionary = {}   # per-enemy cooldown so return leg re-hits

@onready var sprite: ColorRect = $Sprite


func _ready() -> void:
	body_entered.connect(_on_body_entered)


# ── Launch API ────────────────────────────────────────────────────────────────
func launch(dir: Vector2, spd: float, dmg: int) -> void:
	direction = dir.normalized()
	speed = spd
	damage = dmg
	rotation = direction.angle() - PI / 2.0
	# Combat-SFX pass: airy "shwip" on throw (impact stays kunai_hit on landing).
	FX.play_sound("kunai_throw", 0.6)


# Run 30b — convert this kunai into a shuriken: hide the blade ColorRects and
# build a simple 4-point star (gold) + dark hub. Placeholder geometry until
# art arrives, but it reads as a throwing star instead of a line.
func make_shuriken(tint: Color = Color(1.0, 0.85, 0.35, 1.0)) -> void:
	_is_shuriken = true
	_shuriken_tint = tint
	for blade_part in ["Sprite", "Tip", "Hilt"]:
		if has_node(blade_part):
			get_node(blade_part).visible = false
	var star := Polygon2D.new()
	var pts := PackedVector2Array()
	for i in 8:
		var ang: float = TAU * float(i) / 8.0
		var r: float = 7.5 if i % 2 == 0 else 2.6   # alternate point / notch
		pts.append(Vector2(cos(ang), sin(ang)) * r)
	star.polygon = pts
	star.color = tint
	add_child(star)
	# Dark center hub so the star silhouette pops.
	var hub := Polygon2D.new()
	var hub_pts := PackedVector2Array()
	for i in 6:
		var hang: float = TAU * float(i) / 6.0
		hub_pts.append(Vector2(cos(hang), sin(hang)) * 2.0)
	hub.polygon = hub_pts
	hub.color = Color(0.20, 0.18, 0.12, 1.0)
	add_child(hub)


func launch_bananarang(dir: Vector2, spd: float, dmg: int, shooter: Node, gl_mode: bool) -> void:
	launch(dir, spd, dmg)
	_is_bananarang = true
	_shooter = shooter
	_greased_lightning = gl_mode
	max_range *= BANANARANG_RANGE_MULT   # Run 58 — shorter boomerang reach
	_set_phase_visuals(0)


# ── Physics tick ──────────────────────────────────────────────────────────────
func _physics_process(delta: float) -> void:
	if _stuck:
		return   # Run 58 — embedded in a surface; just waiting out its fade.
	# Tick per-enemy hit cooldowns (bananarang mode only).
	if _is_bananarang:
		for key in _hit_cooldowns.keys():
			_hit_cooldowns[key] -= delta
			if _hit_cooldowns[key] <= 0.0:
				_hit_cooldowns.erase(key)
		_tick_bananarang(delta)
		return

	# Standard straight-line kunai.
	var move: Vector2 = direction * speed * delta
	position += move
	_traveled += move.length()
	if _is_shuriken:
		rotation += SHURIKEN_SPIN_SPEED * delta   # spin the star as it flies
	if _traveled >= max_range:
		queue_free()


func _tick_bananarang(delta: float) -> void:
	var move: Vector2 = direction * speed * delta
	position += move
	_traveled += move.length()

	# Pierce-hit all overlapping enemies this frame.
	for body in get_overlapping_bodies():
		if not body.is_in_group("enemy"):
			continue
		if body in _hit_cooldowns:
			continue
		_hit_cooldowns[body] = 0.25
		_handle_bananarang_hit(body)

	if _bananarang_phase == 0:
		if _traveled >= max_range:
			_begin_return()
	else:
		var target_pos: Vector2 = _shooter.global_position \
			if is_instance_valid(_shooter) else global_position
		if global_position.distance_to(target_pos) < 18.0 or _traveled >= max_range * 1.1:
			queue_free()
			return
		# Gentle homing toward Bea's current position.
		var to_target: Vector2 = (target_pos - global_position).normalized()
		direction = direction.lerp(to_target, 0.08).normalized()
		rotation = direction.angle() - PI / 2.0


func _begin_return() -> void:
	_bananarang_phase = 1
	direction = -direction
	rotation = direction.angle() - PI / 2.0
	_traveled = 0.0
	_hit_cooldowns.clear()
	_set_phase_visuals(1)
	FX.spawn_hit_particles(global_position,
		Color(0.30, 0.55, 1.0, 0.9) if not _greased_lightning \
		else Color(0.30, 0.80, 1.0, 0.9), 5)


# ── Hit handling ──────────────────────────────────────────────────────────────
func _on_body_entered(body: Node) -> void:
	if body.is_in_group("water_collider"):
		return   # rivers are walked-around, not shot-through: fly over the water.
	if not body.is_in_group("enemy"):
		# Run 58 — wall / obstacle / arena edge (collision_mask now includes
		# World layer 1). The blade no longer passes through solids.
		_on_hit_wall()
		return
	if _is_bananarang:
		return   # handled per-frame in _tick_bananarang
	if _hit_set.has(body):
		return
	_hit_set[body] = true
	# Run 133 — Bea on-kill hook: capture liveness + poison state BEFORE the hit
	# so the routing loop below can fire _bea_on_enemy_killed on a KO.
	var _wa: bool = (not body.has_method("is_alive")) or body.is_alive()
	var _wp: bool = body.has_node("StatusComponent") and body.get_node("StatusComponent").has("poison")
	if body.has_method("take_damage"):
		# Run 27 — Toxic Aim duo (Carrot+Onion): ranged hits vs Poisoned
		# targets get a +10% bonus crit roll at impact (1.5× damage).
		var dmg: int = damage
		# Run 27f — Long Shot (Carrot passive): ranged damage scales with
		# distance traveled — +1% per ~10px, capped at +25%.
		if RunState.bea_has("long_shot"):
			dmg = int(round(float(dmg) * (1.0 + minf(0.25, _traveled * 0.001))))
		if body.has_node("StatusComponent") and body.get_node("StatusComponent").has("poison"):
			if randf() < RunState.get_carrot_onion_crit_bonus():
				dmg = int(round(float(dmg) * 1.5))
				FX.spawn_hit_particles(global_position, Color(0.95, 0.55, 0.15, 1.0), 6)
		# Run 49 — scaled-down knockback vector: length acts as strength scalar.
		# Run 58 — Stone Throw boon throws full-strength (1.0) heavy knockback.
		# Run 162 — INNATE ranged pushback REMOVED (Bruno 2026-08-01). Kunai spam
		# is meant to be fast; even the light 0.25 flinch added up to a wall when
		# thrown at rate. A 0 scalar = damage, no push (Run 49 length-as-strength
		# convention). Stone Throw's heavy knockback is a BOON and still applies.
		var kb_scale: float = 1.0 if heavy_knockback else INNATE_KNOCKBACK_SCALE
		# Run 134 — killer attribution for the universal on-death hook (fix 5).
		body.set_meta("last_damager", "bea")
		FX.hit_rumble("bea")
		body.take_damage(dmg, direction * kb_scale)
	# Run 27f — Bea parity: route ranged-hit callbacks through Bea so her
	# family statuses + Static Charge + on-hit procs fire (mirror of
	# KiBlast._route_through_player).
	# Run 58 — also drive the HUD combo counter. The standard kunai previously
	# applied family statuses but never called _on_hit_connected, so basic
	# (non-charged) throws didn't advance Bea's combo. Charged/bananarang hits
	# already routed through it — this brings the basic throw to parity.
	for _bea in get_tree().get_nodes_in_group("bea"):
		if _bea.has_method("_bea_apply_family_statuses_on_hit"):
			_bea._bea_apply_family_statuses_on_hit(body, false, false, true, false, false)
		if _bea.has_method("_on_hit_connected"):
			_bea._on_hit_connected(damage)
		# Run 134 — Bea on-kill hook now fires from Enemy._die() →
		# process_enemy_death_boons, routed via the "last_damager" meta set above.
		# The old attacker-side call is removed to avoid a double-proc.
		break
	FX.spawn_hit_particles(global_position, Color(0.90, 0.90, 1.0, 1.0), 5)
	# Run 58 — leave a brief embedded blade in the pierced enemy (fades ~3s).
	_spawn_embedded_blade(body)
	FX.play_sound("kunai_hit", 0.6)
	# Run 30b — pierce gate: pierce_limit 0 = fly until max_range (kunai);
	# N > 0 = despawn after N hits (shuriken use 1).
	_pierced_count += 1
	# Run 59 — Grape Shot: split on first enemy impact (one level only). Fires
	# regardless of pierce_limit so the split also benefits Slugshot (pierce-all)
	# builds — the first impact still seeds two sub-shots.
	# Run 130 — Cluster Theory (Grape Legendary): every kunai splits on first
	# impact; first-level splits split ONE more time (depth 2 max).
	if RunState.bea_has("cluster_theory"):   # Run 133 — Kunai is Bea-only; per-hero gate (was team_has)
		if _split_depth < 2 and _pierced_count == 1:
			_spawn_grape_splits(global_position)
	elif not _is_grape_split and _pierced_count == 1 and RunState.bea_has("grape_shot"):
		_spawn_grape_splits(global_position)
	if pierce_limit > 0 and _pierced_count >= pierce_limit:
		queue_free()


# Run 58 — wall / obstacle / arena-edge impact.
func _on_hit_wall() -> void:
	if _stuck:
		return
	if _is_bananarang:
		# Boomerang bounces off the world: turn around early on the way out,
		# give up if a wall is struck on the return leg.
		if _bananarang_phase == 0:
			_begin_return()
		else:
			queue_free()
		return
	_stick_to_surface()


# Embed the blade in the surface it hit: stop moving, stop colliding, then fade
# the whole kunai out over STICK_LIFETIME before freeing.
func _stick_to_surface() -> void:
	if _stuck:
		return
	_stuck = true
	set_deferred("monitoring", false)   # no more hit detection while embedded
	FX.spawn_hit_particles(global_position, Color(0.85, 0.88, 0.95, 1.0), 4)
	FX.play_sound("kunai_hit", 0.4)
	var tw: Tween = create_tween()
	tw.tween_interval(STICK_LIFETIME * 0.45)
	tw.tween_property(self, "modulate:a", 0.0, STICK_LIFETIME * 0.55)
	tw.tween_callback(queue_free)


# Cosmetic embedded blade left in a pierced enemy. Parented to the enemy so it
# travels with them, fades over STICK_LIFETIME. Subtle — one thin blade sliver.
func _spawn_embedded_blade(enemy: Node) -> void:
	if not is_instance_valid(enemy) or not (enemy is Node2D):
		return
	# Run 30b — a shuriken leaves a stuck throwing star, not a kunai blade.
	if _is_shuriken:
		_spawn_embedded_shuriken(enemy)
		return
	var blade := Polygon2D.new()
	blade.polygon = PackedVector2Array([
		Vector2(-1.5, -6.0), Vector2(0.0, -8.0), Vector2(1.5, -6.0),
		Vector2(1.5, 4.0), Vector2(-1.5, 4.0)])
	blade.color = Color(0.82, 0.85, 0.92, 0.9)
	blade.rotation = direction.angle() - PI / 2.0
	blade.position = Vector2(randf_range(-5.0, 5.0), randf_range(-5.0, 5.0))
	blade.z_index = 6
	(enemy as Node2D).add_child(blade)
	var tw: Tween = blade.create_tween()
	tw.tween_interval(STICK_LIFETIME * 0.45)
	tw.tween_property(blade, "modulate:a", 0.0, STICK_LIFETIME * 0.55)
	tw.tween_callback(blade.queue_free)


# Cosmetic embedded shuriken left in a pierced enemy — mirrors the flying-star
# geometry from make_shuriken() so a stuck shuriken still reads as a star, not a
# kunai. Parented to the enemy, fades over STICK_LIFETIME.
func _spawn_embedded_shuriken(enemy: Node) -> void:
	var holder := Node2D.new()
	holder.position = Vector2(randf_range(-5.0, 5.0), randf_range(-5.0, 5.0))
	holder.rotation = randf_range(0.0, TAU)   # frozen mid-spin
	holder.z_index = 6
	var star := Polygon2D.new()
	var pts := PackedVector2Array()
	for i in 8:
		var ang: float = TAU * float(i) / 8.0
		var r: float = 7.5 if i % 2 == 0 else 2.6
		pts.append(Vector2(cos(ang), sin(ang)) * r)
	star.polygon = pts
	star.color = _shuriken_tint
	holder.add_child(star)
	var hub := Polygon2D.new()
	var hub_pts := PackedVector2Array()
	for i in 6:
		var hang: float = TAU * float(i) / 6.0
		hub_pts.append(Vector2(cos(hang), sin(hang)) * 2.0)
	hub.polygon = hub_pts
	hub.color = Color(0.20, 0.18, 0.12, 1.0)
	holder.add_child(hub)
	(enemy as Node2D).add_child(holder)
	var tw: Tween = holder.create_tween()
	tw.tween_interval(STICK_LIFETIME * 0.45)
	tw.tween_property(holder, "modulate:a", 0.0, STICK_LIFETIME * 0.55)
	tw.tween_callback(holder.queue_free)


func _handle_bananarang_hit(enemy: Node) -> void:
	if not enemy.has_method("take_damage"):
		return
	enemy.set_meta("last_damager", "bea")   # Run 134 — killer attribution (fix 5)
	FX.hit_rumble("bea")
	enemy.take_damage(damage, direction)

	# Phase-appropriate banana status.
	var ts: Variant = enemy.get("status") if enemy.has_method("get") else null
	if ts != null and ts.has_method("apply"):
		# Run 58 — the kunai-rang is still a sharp blade: apply Bea's universal
		# Bleed on top of the phase status (both legs). Mirrors BeaAI's
		# BEA_BLADE_BLEED_DUR / _STACKS so the boomerang stays consistent.
		ts.apply("bleed", 4.0, 1)
		if _bananarang_phase == 0:
			var out_id: String = "sparked" if _greased_lightning else "slippery"
			ts.apply(out_id, 3.0, 1)
			FX.spawn_hit_particles(enemy.global_position,
				Color(0.85, 0.90, 0.25, 1.0) if not _greased_lightning \
				else Color(0.50, 0.90, 0.30, 1.0), 5)
		else:
			var ret_id: String = "bolted" if _greased_lightning else "greased"
			ts.apply(ret_id, 5.0, 1)
			FX.spawn_hit_particles(enemy.global_position,
				Color(0.25, 0.55, 1.0, 1.0) if not _greased_lightning \
				else Color(0.30, 0.80, 1.0, 1.0), 5)
	else:
		FX.spawn_hit_particles(enemy.global_position, Color(0.90, 0.90, 1.0, 1.0), 4)

	# Route through Bea's hit pipeline for chi + combo.
	var beas: Array = get_tree().get_nodes_in_group("bea")
	if beas.size() > 0:
		var b: Node = beas[0]
		if b.has_method("_on_hit_connected"):
			b._on_hit_connected(damage)

	FX.play_sound("kunai_hit", 0.55)


# Run 59 — Grape Shot split spawner (mirror of KiBlast._spawn_grape_splits).
# N smaller kunais in a forward fan at 40% damage. Sub-shots are flagged
# _is_grape_split so they cannot trigger their own split — one level only.
# Run 60: 3 sub-shots distributed symmetrically across [-fan, +fan].
func _spawn_grape_splits(at_pos: Vector2) -> void:
	var scene: PackedScene = load("res://scenes/Kunai.tscn") as PackedScene
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
		var t: float = 0.0
		if count > 1:
			t = (float(i) / float(count - 1)) * 2.0 - 1.0
		var sub_dir: Vector2 = direction.rotated(t * half_fan)
		var sub: Node2D = scene.instantiate()
		parent.add_child(sub)
		sub.global_position = at_pos + sub_dir * 10.0
		sub.scale = Vector2.ONE * RunState.GRAPE_SPLIT_SCALE
		sub.modulate = Color(0.85, 0.55, 1.0, 1.0)
		if sub.has_method("set"):
			sub.set("_is_grape_split", true)
			sub.set("_split_depth", _split_depth + 1)   # Run 130 — Cluster Theory recursion
			# Splits should still die on first enemy (no pierce cascade).
			sub.set("pierce_limit", 1)
		if sub.has_method("launch"):
			sub.launch(sub_dir, speed * 0.92, sub_dmg)
	FX.spawn_hit_particles(at_pos, Color(0.85, 0.55, 1.0, 1.0), 6)


# ── Visuals ───────────────────────────────────────────────────────────────────
func _set_phase_visuals(phase: int) -> void:
	if sprite == null:
		return
	if phase == 0:
		sprite.color = Color(0.95, 0.85, 0.15, 1.0) if not _greased_lightning \
		             else Color(0.45, 0.95, 0.30, 1.0)
	else:
		sprite.color = Color(0.20, 0.50, 1.0, 1.0) if not _greased_lightning \
		             else Color(0.20, 0.80, 1.0, 1.0)
