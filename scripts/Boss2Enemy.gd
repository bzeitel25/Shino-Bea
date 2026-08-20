extends CharacterBody2D

# ============================================================
# Boss2Enemy.gd — Triheaded Wyrm (Run 26f, 2026-06-02)
# ============================================================
# Temporary final boss for the 20-arena test runs Bruno is using to validate
# end-game builds. NOT the canonical final boss for the full game — designed
# to be obviously a "test boss" while still feeling threatening.
#
# 3-headed dragon (left / center / right) on a single shared HP pool. The
# heads are pure visual / attack-anchor children; damage is taken on the
# body collider. Player gets credit (chi, combo, kill heal) on body hits.
#
# Attack rotation (chosen at random from the eligible pool each cycle):
#   FIREBALL_SINGLE  — one head spits a slow homing-ish fireball at the
#                      player. Telegraphed by the chosen head pulsing orange.
#   FIREBALL_VOLLEY  — all 3 heads fire in 0.20s succession. Spread fan.
#   SLAM_HEAD        — the head NEAREST the player slams down a small AoE
#                      circle at the player's last-known position.
#   FLY_SLAM         — the whole boss flies up off-screen for ~1.4s, then
#                      crashes back down at the player's current position
#                      with a medium-radius AoE (avoidable by moving).
#
# Phase gating:
#   Phase 1 (HP > 60%):  FIREBALL_SINGLE, SLAM_HEAD
#   Phase 2 (30-60%):    + FIREBALL_VOLLEY
#   Phase 3 (HP ≤ 30%):  + FLY_SLAM, attack cooldown halved
#
# Movement: slow drift toward player when not attacking. Boss is heavy and
# doesn't get knocked far.
# ============================================================

@export var max_hp: int = 320
@export var move_speed: float = 45.0           # Phase 1 drift speed
@export var phase3_speed: float = 70.0         # Faster after 30% HP

const FIREBALL_DAMAGE: int = 18
const SLAM_HEAD_DAMAGE: int = 22
const FLY_SLAM_DAMAGE: int = 28

const SLAM_HEAD_RADIUS: float = 80.0           # AoE radius at slam point
const FLY_SLAM_RADIUS: float = 140.0           # Bigger but slower, dodgeable

const FIREBALL_SPEED: float = 240.0
const FIREBALL_RANGE: float = 720.0

const SLAM_HEAD_WINDUP: float = 0.85
const SLAM_HEAD_EXECUTE: float = 0.20
const SLAM_HEAD_RECOVERY: float = 0.80

const FLY_UP_DURATION: float = 0.6
const FLY_HOVER_DURATION: float = 0.8           # boss off-screen, picks landing
const FLY_LAND_TELEGRAPH: float = 1.00          # Run 26g — bumped 0.55 → 1.0 per Bruno's playtest ask: more reaction time on the dragon's fly-slam.
const FLY_RECOVERY: float = 1.0

const FIREBALL_WINDUP: float = 0.55
const FIREBALL_VOLLEY_INTERVAL: float = 0.20

const ATTACK_COOLDOWN_P1: float = 2.6
const ATTACK_COOLDOWN_P2: float = 2.1
const ATTACK_COOLDOWN_P3: float = 1.5

const PHASE2_HP_PCT: float = 0.60
const PHASE3_HP_PCT: float = 0.30

const FLASH_DURATION: float = 0.14
const HIT_COLOR: Color = Color(1.0, 0.20, 0.20, 1.0)
const TELL_COLOR: Color = Color(1.0, 0.10, 0.08, 0.95)  # danger red (Run 122)
const FLY_LAND_COLOR: Color = Color(0.95, 0.25, 0.30, 0.70)
const HEAD_COLOR_BASE: Color = Color(0.55, 0.15, 0.30, 1.0)
const HEAD_COLOR_PULSE: Color = Color(1.0, 0.45, 0.20, 1.0)

const KNOCKBACK_STRENGTH: float = 60.0
const KNOCKBACK_FRICTION: float = 8.0

const FIREBALL_SCENE_PATH: String = "res://scenes/EnemyProjectile.tscn"

enum State { IDLE, AIMING, EXECUTING, FLY_UP, FLY_HOVER, FLY_LAND, RECOVERY, DEAD }
enum AttackType { FIREBALL_SINGLE, FIREBALL_VOLLEY, SLAM_HEAD, FLY_SLAM }

var current_hp: int = 0
var state: int = State.IDLE
var phase: int = 1
var _attack_cooldown: float = 0.0
var _state_timer: float = 0.0
var _knockback_vel: Vector2 = Vector2.ZERO
var _current_attack: int = -1
var _flash_timer: float = 0.0
var _flash_target_color: Color = Color(1, 1, 1, 0.0)
var _fly_land_pos: Vector2 = Vector2.ZERO
var _fly_marker_alpha: float = 0.0
var _volley_remaining: int = 0
var _volley_timer: float = 0.0
var _slam_pos: Vector2 = Vector2.ZERO
var _active_head_idx: int = 0   # 0 = left, 1 = center, 2 = right

@onready var body_visual: ColorRect = $Body
@onready var head_left:   Polygon2D = $HeadLeft
@onready var head_center: Polygon2D = $HeadCenter
@onready var head_right:  Polygon2D = $HeadRight
@onready var name_label:  Label = $NameLabel
@onready var hp_label:    Label = $HPLabel

const HEAD_OFFSETS: Array = [Vector2(-44, -38), Vector2(0, -52), Vector2(44, -38)]

var _dmg_num_scene: PackedScene = null
var _fireball_scene: PackedScene = null

# --- StatusComponent (Run 117) — breakbar + debuff support ---
var status: StatusComponent = null


func _ready() -> void:
	add_to_group("enemy")
	add_to_group("boss")
	current_hp = max_hp
	_attack_cooldown = 1.6   # brief warmup before first attack
	# StatusComponent — required for breakbar + Vulnerable / debuffs.
	status = StatusComponent.new()
	status.name = "StatusComponent"
	add_child(status)
	status.host = self
	if ResourceLoader.exists("res://scenes/DamageNumber.tscn"):
		_dmg_num_scene = load("res://scenes/DamageNumber.tscn")
	if ResourceLoader.exists(FIREBALL_SCENE_PATH):
		_fireball_scene = load(FIREBALL_SCENE_PATH)
	_refresh_hp_label()
	if get_node_or_null("/root/FX") and FX.has_method("register_boss"):
		FX.register_boss(self)
	# Notify boss HP for any future HUD bar
	if get_node_or_null("/root/FX") and FX.has_method("notify_boss_hp"):
		FX.notify_boss_hp(current_hp, max_hp, "Triheaded Wyrm")


func _exit_tree() -> void:
	if get_node_or_null("/root/FX") and FX.has_method("unregister_boss"):
		FX.unregister_boss(self)


func _physics_process(delta: float) -> void:
	_tick_flash(delta)
	_tick_head_pulse(delta)
	if state == State.DEAD:
		return

	# Knockback friction
	if _knockback_vel.length() > 1.0:
		_knockback_vel = _knockback_vel.lerp(Vector2.ZERO, KNOCKBACK_FRICTION * delta)

	# Phase recalc on every tick (cheap)
	_recalc_phase()

	# Run 117 — Breakbar broken: freeze AI while movement-locked.
	if status and status.is_movement_locked():
		velocity = _knockback_vel
		move_and_slide()
		return

	match state:
		State.IDLE:
			_drift_toward_player(delta)
			_attack_cooldown -= delta
			if _attack_cooldown <= 0.0:
				_pick_next_attack()
		State.AIMING:
			velocity = _knockback_vel
			move_and_slide()
			_state_timer -= delta
			if _state_timer <= 0.0:
				_execute_chosen_attack()
		State.EXECUTING:
			velocity = _knockback_vel
			move_and_slide()
			_state_timer -= delta
			if _current_attack == AttackType.FIREBALL_VOLLEY:
				_volley_timer -= delta
				if _volley_timer <= 0.0 and _volley_remaining > 0:
					_fire_one_volley_shot()
			if _state_timer <= 0.0:
				_enter_recovery(SLAM_HEAD_RECOVERY if _current_attack == AttackType.SLAM_HEAD else FLY_RECOVERY * 0.4)
		State.FLY_UP:
			# Boss visually lifts off — fade out + scale shrink
			_state_timer -= delta
			var t: float = 1.0 - clamp(_state_timer / FLY_UP_DURATION, 0.0, 1.0)
			modulate.a = lerp(1.0, 0.0, t)
			scale = Vector2(1.0 - 0.20 * t, 1.0 - 0.20 * t)
			if _state_timer <= 0.0:
				modulate.a = 0.0
				_state_timer = FLY_HOVER_DURATION
				state = State.FLY_HOVER
				_pick_fly_land_pos()
		State.FLY_HOVER:
			_state_timer -= delta
			if _state_timer <= 0.0:
				_state_timer = FLY_LAND_TELEGRAPH
				state = State.FLY_LAND
				_fly_marker_alpha = 0.95
		State.FLY_LAND:
			# Pulse the landing telegraph
			_fly_marker_alpha = 0.5 + 0.5 * sin(float(Time.get_ticks_msec()) / 80.0)
			_state_timer -= delta
			if _state_timer <= 0.0:
				_resolve_fly_slam()
		State.RECOVERY:
			velocity = _knockback_vel
			move_and_slide()
			_state_timer -= delta
			if _state_timer <= 0.0:
				_return_to_idle()


# ---------------------------------------------------------------------------
# Drift + targeting
# ---------------------------------------------------------------------------
func _drift_toward_player(delta: float) -> void:
	var target: Node2D = _find_player()
	if target == null:
		velocity = _knockback_vel
		move_and_slide()
		return
	var to_target: Vector2 = target.global_position - global_position
	var dir: Vector2 = to_target.normalized() if to_target.length() > 0.01 else Vector2.ZERO
	var spd: float = phase3_speed if phase >= 3 else move_speed
	velocity = dir * spd + _knockback_vel
	move_and_slide()


func _find_player() -> Node2D:
	# Prefer Shino (non-bea player). Fall back to any "player" group member.
	for p in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(p):
			continue
		if p.is_in_group("bea"):
			continue
		if p.has_method("is_downed") and p.is_downed():
			continue
		return p
	# All bea or all downed — pick anyone alive
	for p in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(p) and not (p.has_method("is_downed") and p.is_downed()):
			return p
	return null


# ---------------------------------------------------------------------------
# Attack selection
# ---------------------------------------------------------------------------
func _pick_next_attack() -> void:
	var pool: Array = [AttackType.FIREBALL_SINGLE, AttackType.SLAM_HEAD]
	if phase >= 2:
		pool.append(AttackType.FIREBALL_VOLLEY)
	if phase >= 3:
		pool.append(AttackType.FLY_SLAM)
	_current_attack = pool[randi() % pool.size()]
	# Pick a head (random for fireball single; nearest for slam; doesn't matter for volley/fly)
	if _current_attack == AttackType.SLAM_HEAD:
		_active_head_idx = _nearest_head_to_player()
	else:
		_active_head_idx = randi() % 3

	state = State.AIMING
	match _current_attack:
		AttackType.FIREBALL_SINGLE: _state_timer = FIREBALL_WINDUP
		AttackType.FIREBALL_VOLLEY: _state_timer = FIREBALL_WINDUP
		AttackType.SLAM_HEAD:       _state_timer = SLAM_HEAD_WINDUP
		AttackType.FLY_SLAM:        _state_timer = 0.30   # short crouch before liftoff


func _nearest_head_to_player() -> int:
	var p: Node2D = _find_player()
	if p == null:
		return 1   # center as default
	var best_i: int = 1
	var best_d: float = INF
	for i in range(3):
		var hp_pos: Vector2 = global_position + HEAD_OFFSETS[i]
		var d: float = hp_pos.distance_to(p.global_position)
		if d < best_d:
			best_d = d
			best_i = i
	return best_i


func _execute_chosen_attack() -> void:
	state = State.EXECUTING
	match _current_attack:
		AttackType.FIREBALL_SINGLE:
			_fire_fireball_from_head(_active_head_idx)
			_state_timer = 0.40
		AttackType.FIREBALL_VOLLEY:
			_volley_remaining = 3
			_volley_timer = 0.0
			_state_timer = FIREBALL_VOLLEY_INTERVAL * 4.0
		AttackType.SLAM_HEAD:
			_resolve_slam_head()
			_state_timer = SLAM_HEAD_EXECUTE
		AttackType.FLY_SLAM:
			state = State.FLY_UP
			_state_timer = FLY_UP_DURATION


func _fire_one_volley_shot() -> void:
	if _volley_remaining <= 0:
		return
	# Cycle heads 0, 1, 2 for the volley
	var head_idx: int = (3 - _volley_remaining) % 3
	_fire_fireball_from_head(head_idx)
	_volley_remaining -= 1
	_volley_timer = FIREBALL_VOLLEY_INTERVAL


func _fire_fireball_from_head(head_idx: int) -> void:
	if _fireball_scene == null:
		Log.dbg("[Boss2] No EnemyProjectile.tscn — skipping fireball.")
		return
	var head_pos: Vector2 = global_position + HEAD_OFFSETS[head_idx]
	var target: Node2D = _find_player()
	var aim: Vector2 = Vector2.DOWN
	if target != null:
		aim = (target.global_position - head_pos).normalized()
	var proj = _fireball_scene.instantiate()
	var parent = get_parent()
	if parent:
		parent.add_child(proj)
		proj.global_position = head_pos
		if proj.has_method("launch"):
			proj.launch(aim, FIREBALL_SPEED, FIREBALL_DAMAGE)
		elif "direction" in proj and "speed" in proj:
			proj.direction = aim
			proj.speed = FIREBALL_SPEED
			if "damage" in proj:
				proj.damage = FIREBALL_DAMAGE
	# Pulse the firing head
	_pulse_head(head_idx)
	FX.spawn_hit_particles(head_pos, Color(1.0, 0.55, 0.15), 6)
	if FX.has_method("play_sound"):
		FX.play_sound("boss_fireball", 0.7)


func _resolve_slam_head() -> void:
	var target: Node2D = _find_player()
	if target == null:
		return
	_slam_pos = target.global_position
	# Particles + AoE damage check
	FX.spawn_burst_particles(_slam_pos, Color(0.95, 0.55, 0.20, 1.0), 14)
	if FX.has_method("screen_shake"):
		FX.screen_shake(FX.SHAKE_MEDIUM, FX.SHAKE_DUR_SHORT)
	if FX.has_method("play_sound"):
		FX.play_sound("boss_slam", 0.9)
	for p in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(p):
			continue
		if p.has_method("is_downed") and p.is_downed():
			continue
		var d: float = p.global_position.distance_to(_slam_pos)
		if d <= SLAM_HEAD_RADIUS and p.has_method("take_damage"):
			var dir: Vector2 = (p.global_position - _slam_pos).normalized() if (p.global_position - _slam_pos).length() > 0.01 else Vector2.RIGHT
			p.take_damage(SLAM_HEAD_DAMAGE, dir)


func _pick_fly_land_pos() -> void:
	var target: Node2D = _find_player()
	if target == null:
		_fly_land_pos = global_position
	else:
		_fly_land_pos = target.global_position
	# Move boss to landing position invisibly (will reappear on crash)
	global_position = _fly_land_pos


func _resolve_fly_slam() -> void:
	# Snap visible, slam particles, AoE check at _fly_land_pos
	modulate.a = 1.0
	scale = Vector2.ONE
	_fly_marker_alpha = 0.0
	if FX.has_method("screen_shake"):
		FX.screen_shake(FX.SHAKE_HEAVY, FX.SHAKE_DUR_MED)
	FX.spawn_burst_particles(_fly_land_pos, Color(0.95, 0.30, 0.20, 1.0), 24)
	if FX.has_method("play_sound"):
		FX.play_sound("boss_fly_slam", 1.0)
	for p in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(p):
			continue
		if p.has_method("is_downed") and p.is_downed():
			continue
		var d: float = p.global_position.distance_to(_fly_land_pos)
		if d <= FLY_SLAM_RADIUS and p.has_method("take_damage"):
			var dir: Vector2 = (p.global_position - _fly_land_pos).normalized() if (p.global_position - _fly_land_pos).length() > 0.01 else Vector2.RIGHT
			p.take_damage(FLY_SLAM_DAMAGE, dir)
	_enter_recovery(FLY_RECOVERY)


func _enter_recovery(dur: float) -> void:
	state = State.RECOVERY
	_state_timer = dur


func _return_to_idle() -> void:
	state = State.IDLE
	_current_attack = -1
	var phase_cd: float = ATTACK_COOLDOWN_P3 if phase >= 3 else (ATTACK_COOLDOWN_P2 if phase >= 2 else ATTACK_COOLDOWN_P1)
	_attack_cooldown = phase_cd + randf_range(-0.30, 0.30)


# ---------------------------------------------------------------------------
# Damage in / state
# ---------------------------------------------------------------------------
func take_damage(amount: int, knockback_dir: Vector2 = Vector2.ZERO) -> void:
	if state == State.DEAD:
		return
	# Run 117 — Vulnerable amp via StatusComponent.
	var status_mult: float = 1.0
	if status:
		status_mult = status.get_damage_taken_mult()
	status_mult *= RunState.get_target_status_damage_mult(status)
	var final_amount: int = max(1, int(round(amount * status_mult))) if amount > 0 else 0
	current_hp = max(0, current_hp - final_amount)
	_refresh_hp_label()
	if FX.has_method("notify_boss_hp"):
		FX.notify_boss_hp(current_hp, max_hp, "Triheaded Wyrm")
	_flash_timer = FLASH_DURATION
	_flash_target_color = HIT_COLOR
	_spawn_damage_number(final_amount)
	# Run 118 — Bosses are FULLY immune to knockback. Hits contribute to
	# breakbar but never push the boss. No displacement, ever.
	if knockback_dir.length() > 0.01 and status and status.breakbar_enabled:
		if not status.is_breakbar_broken():
			status.contribute_breakbar_knockback()
	if current_hp == 0:
		_die()


# Run 55 — DoT damage path (poison/burn/bleed): no hit-flash so sustained ticks
# don't keep the wyrm tinted red; the status auras carry the visual.
func apply_status_dot_damage(amount: int, _src_id: String) -> void:
	if state == State.DEAD:
		return
	var dmg: int = max(1, amount)
	current_hp = max(0, current_hp - dmg)
	_refresh_hp_label()
	if FX.has_method("notify_boss_hp"):
		FX.notify_boss_hp(current_hp, max_hp, "Triheaded Wyrm")
	_spawn_damage_number(dmg)
	if current_hp == 0:
		_die()


func is_alive() -> bool:
	return state != State.DEAD


# Run 117 — Breakbar handles CC interception in StatusComponent.apply.
func can_receive_status(_id: String) -> bool:
	return true


func is_downed() -> bool:
	# Bosses don't enter DOWNED state — they just die outright.
	return false


func _die() -> void:
	state = State.DEAD
	# Run 131 — shared on-death boon hook (Juicebox, Wave Crash, Summer's End,
	# Rotten Core, Plague Layer).
	RunState.process_enemy_death_boons(self)
	Log.dbg("[Boss2] Triheaded Wyrm defeated.")
	FX.spawn_burst_particles(global_position, Color(0.85, 0.30, 0.55), 32)
	if FX.has_method("screen_shake"):
		FX.screen_shake(FX.SHAKE_HEAVY, FX.SHAKE_DUR_MED)
	if FX.has_method("play_sound"):
		FX.play_sound("boss_death", 1.0)
	queue_free()


func _recalc_phase() -> void:
	var pct: float = float(current_hp) / float(max_hp)
	var new_phase: int = 1
	if pct <= PHASE3_HP_PCT:
		new_phase = 3
	elif pct <= PHASE2_HP_PCT:
		new_phase = 2
	if new_phase != phase:
		phase = new_phase
		if FX.has_method("notify_boss_phase"):
			FX.notify_boss_phase(phase, 3)
		Log.dbg("[Boss2] Entering phase %d (HP %d/%d, %.0f%%)." % [phase, current_hp, max_hp, pct * 100.0])


# ---------------------------------------------------------------------------
# Visuals
# ---------------------------------------------------------------------------
func _tick_flash(delta: float) -> void:
	if _flash_timer <= 0.0:
		if body_visual:
			body_visual.modulate = Color(1, 1, 1, 1)
		return
	_flash_timer -= delta
	var t: float = clamp(_flash_timer / FLASH_DURATION, 0.0, 1.0)
	if body_visual:
		body_visual.modulate = _flash_target_color.lerp(Color(1, 1, 1, 1), 1.0 - t)


func _tick_head_pulse(_delta: float) -> void:
	# Pulse the "active" head during AIMING / EXECUTING so the player can read
	# which head is the next threat.
	var t: float = float(Time.get_ticks_msec()) / 1000.0
	var pulse: float = sin(t * 9.0) * 0.5 + 0.5   # 0 → 1
	var active_color: Color = HEAD_COLOR_BASE.lerp(HEAD_COLOR_PULSE, pulse)
	var inactive: Color = HEAD_COLOR_BASE
	for i in range(3):
		var head: Polygon2D = _head_at(i)
		if head == null:
			continue
		if (state == State.AIMING or state == State.EXECUTING) and i == _active_head_idx:
			head.color = active_color
		else:
			head.color = inactive


func _pulse_head(idx: int) -> void:
	# Instant brighten + tiny scale ping on the firing head.
	var head: Polygon2D = _head_at(idx)
	if head == null:
		return
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(head, "scale", Vector2(1.30, 1.30), 0.10)
	tw.tween_property(head, "scale", Vector2.ONE, 0.18).set_delay(0.10)


func _head_at(idx: int) -> Polygon2D:
	match idx:
		0: return head_left
		1: return head_center
		2: return head_right
	return null


func _draw() -> void:
	# Fly-slam telegraph: red landing circle on the ground while in FLY_LAND.
	if _fly_marker_alpha > 0.001 and state == State.FLY_LAND:
		var local_pos: Vector2 = _fly_land_pos - global_position
		draw_circle(local_pos, FLY_SLAM_RADIUS, Color(FLY_LAND_COLOR.r, FLY_LAND_COLOR.g, FLY_LAND_COLOR.b, _fly_marker_alpha * 0.45))
		draw_arc(local_pos, FLY_SLAM_RADIUS, 0.0, TAU, 32, Color(1.0, 0.30, 0.30, _fly_marker_alpha), 3.0)


func _process(_delta: float) -> void:
	queue_redraw()   # so the FLY_LAND telegraph updates every frame


func _refresh_hp_label() -> void:
	if hp_label:
		hp_label.text = "%d / %d" % [current_hp, max_hp]


func _spawn_damage_number(amount: int) -> void:
	if _dmg_num_scene == null:
		return
	var dn = _dmg_num_scene.instantiate()
	get_parent().add_child(dn)
	dn.global_position = global_position + Vector2(randf_range(-20, 20), -56)
	if dn.has_method("show_damage"):
		dn.show_damage(amount)
