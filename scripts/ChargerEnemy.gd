extends CharacterBody2D

# ============================================================
# ChargerEnemy.gd — Run 57 (2026-06-13) — aiming charger / bruiser
# ============================================================
# Big, slow, telegraphed. The "respect my lane" enemy.
#
#   APPROACH → lumbers slowly toward the player.
#   AIM      → when in range + off cooldown + a global Telegraph slot
#              is free, it LOCKS a direction toward the player's current
#              spot and paints a long, wide charge corridor (consistent
#              amber). Long ~1.3s wind-up. It does NOT re-aim once the
#              lane is shown — it commits to that line. Step off the lane
#              to be safe.
#   CHARGE   → barrels down the locked lane at medium speed to the far
#              end, heavy contact hit + knockback to anyone it bowls
#              through (once each). Super-armored — you can't stagger it
#              mid-rush, but it's wide open afterward.
#   RECOVER  → planted, winded — the punish window.
#
# Charges count against the global big-AoE cap (Telegraph), so you never
# get a stampede of simultaneous lane attacks.
# ============================================================

@export var max_hp: int           = 200
@export var move_speed: float     = 52.0     # slow lumber
@export var charge_damage: int    = 16
@export var stun_duration: float  = 0.30
# Run 122 — generic on-hit status hooks (poison / slow / stun). The charge impact
# already knocks the hero back via take_damage's knockback vector; these add a
# status on top. 0 = none. Set by DreamSpawner.apply_config.
@export var on_hit_poison_stacks: int = 0
@export var on_hit_poison_duration: float = 4.0
@export var on_hit_slow_stacks: int = 0
@export var on_hit_stun_duration: float = 0.0
# Run 122 — burn on impact (e.g. Jawbreaker Juggernaut = stun + burn).
@export var on_hit_burn_stacks: int = 0
@export var on_hit_burn_duration: float = 3.0
# Death explosion — when enabled (e.g. Expired-Egg Bloater), dying triggers a
# telegraphed AoE blast that damages + applies a status to nearby heroes.
@export var death_explosion: bool = false
@export var death_explosion_radius: float = 80.0
@export var death_explosion_delay: float = 1.5
@export var death_explosion_dmg_mult: float = 1.25
@export var death_explosion_status: String = ""       # "poison" or "burning"
@export var death_explosion_status_duration: float = 3.0
@export var death_explosion_status_stacks: int = 1

var current_hp: int = 200

enum State { APPROACH, AIM, CHARGE, RECOVER, STUNNED, DEAD }
var state: State = State.APPROACH

# --- Charge tuning ---
const AIM_RANGE:      float = 380.0  # start aiming when player within this
const AIM_TIME:       float = 1.30   # long, readable wind-up
const CHARGE_SPEED:   float = 330.0  # medium rush
const CHARGE_DIST:    float = 360.0  # lane length (max — clamped to walls at aim time)
const MIN_CHARGE_DIST: float = 90.0  # Run 90 — don't bother charging into a wall this close
const LANE_HALF_W:    float = 36.0   # corridor half-width (it's a big fella)
const HIT_RADIUS:     float = 40.0   # contact reach during the rush
const RECOVER_TIME:   float = 0.65
const COOLDOWN_MIN:   float = 2.4
const COOLDOWN_MAX:   float = 3.8

var _cooldown:    float = 0.0
var _phase_timer: float = 0.0
var _stun_timer:  float = 0.0

var _charge_dir:    Vector2 = Vector2.RIGHT
var _charge_origin: Vector2 = Vector2.ZERO
var _charge_travelled: float = 0.0
var _lane_len:      float = CHARGE_DIST   # Run 90 — actual lane length after wall-clamp
var _lane_poly:  Polygon2D = null
var _hit_set:    Dictionary = {}   # instance_id -> true, heroes already bowled this charge

var _player: CharacterBody2D = null

const KNOCKBACK_STRENGTH: float = 160.0
const KNOCKBACK_FRICTION: float = 8.0
var _knockback_vel: Vector2 = Vector2.ZERO

const FLASH_DURATION: float = 0.12
const BASE_COLOR:   Color = Color(1.0, 1.0, 1.0, 0.0)
const HIT_COLOR:    Color = Color(1.0, 0.18, 0.18, 1.0)
const AIM_COLOR:    Color = Color(1.0, 0.10, 0.10, 0.85)  # danger red (Run 122)
const FLASH_STRENGTH: float = 0.6
const AIM_STRENGTH:   float = 0.5
var _flash_timer: float = 0.0
var _body_base: Dictionary = {}

var _dmg_num_scene: PackedScene = null
var status: StatusComponent = null

@onready var sprite: ColorRect = $Sprite
@onready var hp_label: Label   = $HPLabel
@onready var name_label: Label = $NameLabel
@onready var body_anim: Node   = get_node_or_null("Body")


func _ready() -> void:
	current_hp = max_hp
	add_to_group("enemy")
	status = StatusComponent.new()
	status.name = "StatusComponent"
	add_child(status)
	status.host = self
	if sprite:
		sprite.color = BASE_COLOR
	_body_base = FX.cache_body_colors(body_anim)
	_refresh_hp_label()
	if ResourceLoader.exists("res://scenes/DamageNumber.tscn"):
		_dmg_num_scene = load("res://scenes/DamageNumber.tscn")
	_cooldown = randf_range(COOLDOWN_MIN, COOLDOWN_MAX) * 0.5
	call_deferred("_find_player")


func _find_player() -> void:
	var players = get_tree().get_nodes_in_group("player")
	var best: CharacterBody2D = null
	var best_dist: float = INF
	for p in players:
		if not p is CharacterBody2D:
			continue
		if not p.visible:
			continue
		if p.has_method("is_downed") and p.is_downed():
			continue
		var d: float = global_position.distance_to(p.global_position)
		if d < best_dist:
			best_dist = d
			best = p
	_player = best


func _physics_process(delta: float) -> void:
	if state == State.DEAD:
		return

	_knockback_vel = _knockback_vel.lerp(Vector2.ZERO, KNOCKBACK_FRICTION * delta)

	if _cooldown > 0.0:
		_cooldown -= delta

	if _player == null:
		_find_player()

	if status and status.is_movement_locked():
		# Run 150 (Bruno fix 10): only hard CC cancels the aim — the soft
		# base-attack "hitstop" pauses without robbing the charge.
		if state == State.AIM and status.is_hard_locked():
			_cancel_aim()
		velocity = _knockback_vel
		move_and_slide()
	else:
		match state:
			State.APPROACH:
				_tick_approach(delta)
			State.AIM:
				_tick_aim(delta)
			State.CHARGE:
				_tick_charge(delta)
			State.RECOVER:
				_tick_recover(delta)
			State.STUNNED:
				_tick_stunned(delta)

	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_motion_speed(velocity.length())
		match state:
			State.AIM:
				body_anim.set_anim_state("windup_y")
			State.CHARGE:
				body_anim.set_anim_state("swing_y")
			_:
				body_anim.set_anim_state("walking" if velocity.length() > 6.0 else "idle")

	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0:
			_end_flash()


func _tick_approach(delta: float) -> void:
	if _player == null or not _player.visible or (_player.has_method("is_downed") and _player.is_downed()):
		_find_player()
		if _player == null:
			velocity = _knockback_vel
			move_and_slide()
			return

	var to_player: Vector2 = _player.global_position - global_position
	var dist: float = to_player.length()

	if dist <= AIM_RANGE and _cooldown <= 0.0:
		if Telegraph.request_slot(self):
			if _begin_aim():
				velocity = _knockback_vel
				move_and_slide()
				return
			# Run 90 — a wall is right in front; don't charge into it. Drop the
			# slot, take a short breather, and keep maneuvering around instead.
			Telegraph.release_slot(self)
			_cooldown = randf_range(COOLDOWN_MIN, COOLDOWN_MAX) * 0.5

	var ms_mult: float = 1.0
	if status:
		ms_mult = status.get_move_speed_mult()
	# Run 90 — lumber AROUND barriers toward the player instead of beelining.
	var walk_dir: Vector2 = EnemyNav.move_dir(self, _player.global_position, delta) if dist > 1.0 else Vector2.ZERO
	velocity = walk_dir * move_speed * ms_mult + _knockback_vel
	move_and_slide()


# Returns true if the aim/charge committed, false if a wall is too close to bother.
func _begin_aim() -> bool:
	# Lock direction toward the player's CURRENT spot — no re-homing after this.
	var dir: Vector2 = (_player.global_position - global_position)
	if dir.length() < 1.0:
		dir = Vector2.RIGHT
	dir = dir.normalized()
	var origin: Vector2 = global_position
	# Run 90 — clamp the lane to the first barrier so the amber corridor never
	# paints (or bowls) through a rock. The charge will stop at the wall too.
	_lane_len = EnemyNav.corridor_distance(self, origin, dir, CHARGE_DIST, LANE_HALF_W)
	if _lane_len < MIN_CHARGE_DIST:
		return false
	state = State.AIM
	_phase_timer = AIM_TIME
	_charge_dir = dir
	_charge_origin = origin
	_lane_poly = Telegraph.make_beam_poly(
		get_tree().current_scene, _charge_origin, _charge_dir, _lane_len, LANE_HALF_W)
	if _flash_timer <= 0.0:
		FX.apply_body_tint(_body_base, AIM_COLOR, AIM_STRENGTH)
	FX.play_sound("charger_aim")
	return true


func _tick_aim(delta: float) -> void:
	# Planted while aiming (only knockback nudges). Keep the lane pinned to the
	# locked origin so the telegraph stays truthful.
	velocity = _knockback_vel
	move_and_slide()
	if is_instance_valid(_lane_poly):
		var t: float = 1.0 - clamp(_phase_timer / AIM_TIME, 0.0, 1.0)
		_lane_poly.color.a = lerp(Telegraph.FILL_ALPHA, Telegraph.FILL_ALPHA + 0.16, t) \
			+ 0.05 * sin(Time.get_ticks_msec() * 0.018)
	_phase_timer -= delta
	if _phase_timer <= 0.0:
		_launch_charge()


func _launch_charge() -> void:
	state = State.CHARGE
	_charge_travelled = 0.0
	_hit_set.clear()
	if is_instance_valid(_lane_poly):
		Telegraph.flash_fire(_lane_poly)
	FX.play_sound("charger_go")
	FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_TINY)


func _tick_charge(delta: float) -> void:
	var step: Vector2 = _charge_dir * CHARGE_SPEED
	velocity = step + _knockback_vel
	var before: Vector2 = global_position
	move_and_slide()
	_charge_travelled += global_position.distance_to(before)

	# Bowl through heroes in contact reach (once each).
	for h in get_tree().get_nodes_in_group("player"):
		if not (h is Node2D) or not h.visible:
			continue
		if h.has_method("is_downed") and h.is_downed():
			continue
		var hid: int = h.get_instance_id()
		if _hit_set.has(hid):
			continue
		if (h as Node2D).global_position.distance_to(global_position) <= HIT_RADIUS:
			_hit_set[hid] = true
			if h.has_method("take_damage"):
				# Run 150 — Frost Shield parity (Wiring_Gaps row): a chilled /
				# frozen bruiser hits 15% weaker, like every other enemy.
				var dmg_out: int = charge_damage
				if status and (status.has("chilled") or status.has("frozen")):
					var fs_red: float = float(RunState.get_frost_shield_reduction())
					if fs_red > 0.0:
						dmg_out = maxi(1, int(round(float(dmg_out) * (1.0 - fs_red))))
				h.take_damage(dmg_out, _charge_dir * 0.8)
				# Run 122 — poison / slow / stun on impact (knockback is inherent).
				StatusComponent.inflict_hero_status(h, self)
				if on_hit_burn_stacks > 0:
					var chs: StatusComponent = h.get_node_or_null("StatusComponent") as StatusComponent
					if chs:
						chs.apply("burning", on_hit_burn_duration, on_hit_burn_stacks)

	# End when the (wall-clamped) lane is spent OR a wall stopped it.
	var blocked: bool = get_slide_collision_count() > 0 and velocity.length() < CHARGE_SPEED * 0.4
	if _charge_travelled >= _lane_len or blocked:
		_end_charge()


func _end_charge() -> void:
	if is_instance_valid(_lane_poly):
		_lane_poly.queue_free()
	_lane_poly = null
	Telegraph.release_slot(self)
	if _flash_timer <= 0.0:
		FX.clear_body_tint(_body_base)
	FX.spawn_burst_particles(global_position, Color(0.85, 0.55, 0.3, 0.9), 12)
	state = State.RECOVER
	_phase_timer = RECOVER_TIME


func _cancel_aim() -> void:
	if is_instance_valid(_lane_poly):
		_lane_poly.queue_free()
	_lane_poly = null
	Telegraph.release_slot(self)
	if _flash_timer <= 0.0:
		FX.clear_body_tint(_body_base)
	_cooldown = randf_range(COOLDOWN_MIN, COOLDOWN_MAX) * 0.5


func _tick_recover(delta: float) -> void:
	velocity = _knockback_vel
	move_and_slide()
	_phase_timer -= delta
	if _phase_timer <= 0.0:
		state = State.APPROACH
		_cooldown = randf_range(COOLDOWN_MIN, COOLDOWN_MAX)


func _tick_stunned(delta: float) -> void:
	_stun_timer -= delta
	velocity = _knockback_vel
	move_and_slide()
	if _stun_timer <= 0.0:
		state = State.APPROACH


# ---------------------------------------------------------------------------
# Damage
# ---------------------------------------------------------------------------

func take_damage(amount: int, knockback_dir: Vector2 = Vector2.ZERO) -> void:
	if state == State.DEAD:
		return
	var status_mult: float = 1.0
	if status:
		status_mult = status.get_damage_taken_mult()
	status_mult *= RunState.get_target_status_damage_mult(status)
	if status and RunState.pepper_potato_active():
		if status.has("burning") and status.has("root"):
			status_mult *= (1.0 + RunState.get_pepper_potato_amp())
	if status and RunState.potato_watermelon_active():
		if (status.is_wet() or status.is_frostbitten()) and status.has("root"):
			status_mult *= (1.0 + RunState.get_potato_watermelon_amp())
	var adjusted: int = max(1, int(round(amount * status_mult)))
	current_hp = max(0, current_hp - adjusted)
	_refresh_hp_label()
	_start_flash()
	_spawn_damage_number(adjusted)
	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_anim_state("hit_recoil")

	var _kb_scale: float = minf(knockback_dir.length(), 1.0)
	# Run 118 — Breakbar hosts (boss/miniboss) FULLY immune to knockback.
	var _has_breakbar: bool = status != null and status.breakbar_enabled
	# Heavy bruiser — only a fraction of incoming knockback, and only while not
	# charging (it has super-armor mid-rush).
	if knockback_dir.length() > 0.01 and state != State.CHARGE:
		if _has_breakbar:
			if not status.is_breakbar_broken():
				status.contribute_breakbar_knockback()
		else:
			_knockback_vel = knockback_dir.normalized() * KNOCKBACK_STRENGTH * _kb_scale

	# Run 150 (Bruno fix 10): plain hits no longer interrupt the AIM wind-up —
	# the bruiser always gets its rush off. Only boon CC (bash/frozen/root)
	# cancels, via the StatusComponent hard-lock path.

	if current_hp <= 0:
		_die()


func apply_status_dot_damage(amount: int, _src_id: String) -> void:
	if state == State.DEAD:
		return
	var dmg: int = max(1, amount)
	current_hp = max(0, current_hp - dmg)
	_refresh_hp_label()
	_spawn_damage_number(dmg)
	if current_hp <= 0:
		_die()


func is_attack_imminent() -> bool:
	return state == State.AIM or state == State.CHARGE


func _start_flash() -> void:
	_flash_timer = FLASH_DURATION
	FX.apply_body_tint(_body_base, HIT_COLOR, FLASH_STRENGTH)


func _end_flash() -> void:
	if state == State.DEAD:
		return
	if state == State.AIM:
		FX.apply_body_tint(_body_base, AIM_COLOR, AIM_STRENGTH)
	else:
		FX.clear_body_tint(_body_base)


func _die() -> void:
	state = State.DEAD
	if is_instance_valid(_lane_poly):
		_lane_poly.queue_free()
	_lane_poly = null
	Telegraph.release_slot(self)
	FX.apply_body_tint(_body_base, Color(1.0, 1.0, 1.0, 1.0), 0.85)
	set_physics_process(false)
	FX.spawn_burst_particles(global_position, Color(0.85, 0.5, 0.3, 1.0), 20)
	FX.screen_shake(FX.SHAKE_MEDIUM, FX.SHAKE_DUR_SHORT)
	FX.play_sound("enemy_die")
	# Run 131 — shared on-death boon hook (Juicebox, Wave Crash, Summer's End,
	# Rotten Core, Plague Layer — replaces the inline Juicebox loop).
	RunState.process_enemy_death_boons(self)
	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_anim_state("death")
	if death_explosion:
		_death_explosion_sequence()
	else:
		await get_tree().create_timer(0.40).timeout
		queue_free()


# ── Death explosion (Expired-Egg Bloater) ─────────────────────────────────
# 1.5s flashing RED circle → AoE blast that damages + applies a status.
func _death_explosion_sequence() -> void:
	var boom_pos: Vector2 = global_position
	FX.spawn_flashing_danger_circle(boom_pos, death_explosion_radius, death_explosion_delay)
	var tree := get_tree()
	await tree.create_timer(death_explosion_delay).timeout
	# BOOM — particles + shake.
	FX.spawn_burst_particles(boom_pos, Color(0.72, 0.68, 0.30, 1.0), 22)
	FX.screen_shake(FX.SHAKE_MEDIUM, FX.SHAKE_DUR_SHORT)
	# AoE hit — damage + status to any hero still inside (downed heroes untouched).
	var dmg: int = maxi(1, int(round(float(charge_damage) * death_explosion_dmg_mult)))
	for h in tree.get_nodes_in_group("player"):
		if not (h is Node2D):
			continue
		if h.has_method("is_downed") and h.is_downed():
			continue
		if (h as Node2D).global_position.distance_to(boom_pos) > death_explosion_radius:
			continue
		if h.has_method("take_damage"):
			var kdir: Vector2 = ((h as Node2D).global_position - boom_pos).normalized()
			h.take_damage(dmg, kdir)
		if death_explosion_status != "" and death_explosion_status_stacks > 0:
			var hs: Node = h.get_node_or_null("StatusComponent")
			if hs and hs.has_method("apply"):
				hs.apply(death_explosion_status, death_explosion_status_duration,
						death_explosion_status_stacks)
	queue_free()


func _refresh_hp_label() -> void:
	if hp_label:
		hp_label.text = "%d / %d" % [current_hp, max_hp]


func is_alive() -> bool:
	return state != State.DEAD and current_hp > 0


func _spawn_damage_number(amount: int) -> void:
	if _dmg_num_scene == null:
		return
	var dn = _dmg_num_scene.instantiate()
	var parent = get_parent()
	if parent == null:
		return
	parent.add_child(dn)
	if dn.has_method("setup"):
		dn.setup(amount, global_position)
