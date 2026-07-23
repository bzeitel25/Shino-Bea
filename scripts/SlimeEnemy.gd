extends CharacterBody2D

# ============================================================
# SlimeEnemy.gd — Run 57 (2026-06-13) — leaping jelly slime
# ============================================================
# The elemental jellies used to be plain melee walkers. Now they
# bounce: a squishy hop-chase, then a telegraphed LEAP.
#
#   CHASE  → slow hop toward the player, body squashing on each bob.
#   WINDUP → squashes down low and paints a landing-zone circle
#            (consistent amber) at a LOCKED spot near the player.
#            ~0.8s lead so the player can step off the splat.
#   LEAP   → stretches tall and arcs to the locked spot (does NOT
#            re-home mid-air — dodge by leaving the circle).
#   LAND   → splat: AoE damage inside the painted circle, squish
#            impact, dust, tiny shake.
#   RECOVER→ brief flattened pause (a window to punish it).
#
# The leap is a big dodge-AoE so it goes through the global Telegraph
# cap — only a few jellies splat at once. When the cap is full it just
# keeps hopping closer and waits its turn. Slimes are also scaled DOWN
# in DreamBiomes (they read as bouncy snacks, not boulders).
# ============================================================

@export var max_hp: int           = 70
@export var move_speed: float     = 55.0    # slow hop drift
@export var attack_damage: int    = 9
@export var stun_duration: float  = 0.25
# Run 122 — generic on-hit status hooks (poison / slow / stun). Applied to any
# hero caught in the landing splat. 0 = none. Set by DreamSpawner.apply_config.
@export var on_hit_poison_stacks: int = 0
@export var on_hit_poison_duration: float = 4.0
@export var on_hit_slow_stacks: int = 0
@export var on_hit_stun_duration: float = 0.0

var current_hp: int = 70

enum State { CHASE, WINDUP, LEAP, LAND, RECOVER, STUNNED, ELEMENT, DEAD }
var state: State = State.CHASE

# --- Leap tuning ---
const LEAP_TRIGGER_RANGE: float = 250.0  # start a leap when player within this
const LEAP_MIN_RANGE:     float = 40.0   # don't bother leaping if right on top
const LEAP_MAX_DIST:      float = 240.0  # furthest it will hurl itself
const WINDUP_TIME:        float = 0.80   # squash + landing-zone lead
const LEAP_TIME:          float = 0.42   # airtime
const LAND_RADIUS:        float = 64.0   # splat AoE == painted circle
const RECOVER_TIME:       float = 0.40
const COOLDOWN_MIN:       float = 1.6
const COOLDOWN_MAX:       float = 2.8
const HOP_HEIGHT:         float = 46.0   # visual arc peak

# Run 124 — close-range ELEMENTAL breath. Only fires when the host body is a
# MonsterRig that has an "element" strip (the hand-drawn jellies); procedural
# stick-slimes just leap. A short telegraphed forward burst when a hero is right
# on top of the jelly (too close to bother leaping).
const ELEMENT_RANGE:      float = 80.0   # a hero must be at least this close
# Run 135 — the breath got a real ground telegraph (painted cone) + a longer
# windup so a hero can dash out, and a longer active so the burst frames read.
const ELEMENT_WINDUP:     float = 0.70   # swell / inhale + painted-cone dodge window
const ELEMENT_ACTIVE:     float = 0.60   # burst + follow-through + settle
const ELEMENT_HIT_RANGE:  float = 108.0  # forward reach of the burst
const ELEMENT_CONE_DOT:   float = 0.5    # frontal-cone dot gate (== 60° half-angle)
const ELEMENT_CONE_DEG:   float = 60.0   # painted cone half-angle — keep matching the dot gate
const ELEMENT_CD_MIN:     float = 2.4
const ELEMENT_CD_MAX:     float = 3.8

var _cooldown:    float = 0.0
var _phase_timer: float = 0.0
var _stun_timer:  float = 0.0
# Run 124 — elemental breath state.
var _elem_cd:     float = 0.0
var _elem_fired:  bool = false
var _elem_dir:    Vector2 = Vector2.RIGHT
var _use_rig:     bool = false   # host body is a MonsterRig (hand-drawn jelly)

var _leap_from:   Vector2 = Vector2.ZERO
var _leap_to:     Vector2 = Vector2.ZERO
var _land_poly:   Polygon2D = null
var _elem_poly:   Polygon2D = null   # Run 135 — painted breath cone
var _did_splat:   bool = false

var _player: CharacterBody2D = null

const KNOCKBACK_STRENGTH: float = 180.0
const KNOCKBACK_FRICTION: float = 10.0
var _knockback_vel: Vector2 = Vector2.ZERO

const FLASH_DURATION: float = 0.12
const BASE_COLOR:    Color = Color(1.0, 1.0, 1.0, 0.0)
const HIT_COLOR:     Color = Color(1.0, 0.18, 0.18, 1.0)
const WINDUP_COLOR:  Color = Color(1.0, 0.10, 0.10, 0.85)  # danger red (Run 122)
const FLASH_STRENGTH:  float = 0.6
const WINDUP_STRENGTH: float = 0.5
var _flash_timer: float = 0.0
var _body_base: Dictionary = {}

# Pristine body transform so squash/stretch always restores cleanly.
var _body_node: Node2D = null
var _body_scale0: Vector2 = Vector2.ONE
var _body_pos0:   Vector2 = Vector2.ZERO

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
	if body_anim is Node2D:
		_body_node = body_anim as Node2D
		_body_scale0 = _body_node.scale
		_body_pos0 = _body_node.position
	# Run 124 — a MonsterRig exposes set_config(); when present we let its
	# hand-drawn leap/element frames carry the animation and suppress the
	# procedural squash/stretch (keeping only the arc-hop position offset).
	_use_rig = body_anim != null and body_anim.has_method("set_config")
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
	if _elem_cd > 0.0:
		_elem_cd -= delta

	if _player == null:
		_find_player()

	if status and status.is_movement_locked():
		# Bash mid-air still resolves the leap visually but cancels a windup.
		# Run 150 (Bruno fix 10): only HARD CC (bash/frozen/root from boons)
		# cancels — the soft base-attack "hitstop" pauses the body without
		# robbing the attack.
		if status.is_hard_locked():
			if state == State.WINDUP:
				_cancel_leap()
			elif state == State.ELEMENT:
				_cancel_element()
		velocity = _knockback_vel
		move_and_slide()
	else:
		match state:
			State.CHASE:
				_tick_chase(delta)
			State.WINDUP:
				_tick_windup(delta)
			State.LEAP:
				_tick_leap(delta)
			State.LAND:
				_tick_land(delta)
			State.RECOVER:
				_tick_recover(delta)
			State.STUNNED:
				_tick_stunned(delta)
			State.ELEMENT:
				_tick_element(delta)

	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0:
			_end_flash()


func _tick_chase(delta: float) -> void:
	if _player == null or not _player.visible or (_player.has_method("is_downed") and _player.is_downed()):
		_find_player()
		if _player == null:
			velocity = _knockback_vel
			move_and_slide()
			return

	var to_player: Vector2 = _player.global_position - global_position
	var dist: float = to_player.length()

	# Run 90 — jellies are jumpers: if a barrier blocks the line to the player,
	# LEAP OVER it (the leap lerps the body across, ignoring collision). This is
	# how a hopping enemy gets past a rock wall a walker would have to round.
	var blocked: bool = not EnemyNav.has_line_of_sight(self, global_position, _player.global_position)

	# Run 124 — point-blank ELEMENTAL breath (rig jellies only). If a hero is
	# right on top of us and the breath is off cooldown, vent instead of leaping.
	if _use_rig and dist <= ELEMENT_RANGE and _elem_cd <= 0.0:
		_begin_element(to_player)
		velocity = _knockback_vel
		move_and_slide()
		return

	# Try to start a leap: off cooldown, a global AoE slot free, not point-blank,
	# and either the player is in normal leap range OR a barrier is in the way and
	# the player is close enough to clear in one hop.
	var want_leap: bool = dist >= LEAP_MIN_RANGE and _cooldown <= 0.0 \
		and (dist <= LEAP_TRIGGER_RANGE or (blocked and dist <= LEAP_MAX_DIST + 30.0))
	if want_leap:
		if Telegraph.request_slot(self):
			_begin_windup()
			velocity = _knockback_vel
			move_and_slide()
			return

	# Otherwise hop-drift closer. Run 90 — steer around barriers while grounded
	# (the leap handles getting over them). A little springy bob sells the jelly.
	var ms_mult: float = 1.0
	if status:
		ms_mult = status.get_move_speed_mult()
	var walk_dir: Vector2 = EnemyNav.move_dir(self, _player.global_position, delta) if dist > 1.0 else Vector2.ZERO
	velocity = walk_dir * move_speed * ms_mult + _knockback_vel
	move_and_slide()
	_hop_bob()
	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_motion_speed(velocity.length())
		body_anim.set_anim_state("walking" if velocity.length() > 6.0 else "idle")


func _begin_windup() -> void:
	state = State.WINDUP
	_phase_timer = WINDUP_TIME
	_did_splat = false
	# Lock the landing spot near the player, clamped to a max hurl distance.
	var target: Vector2 = _player.global_position
	var off: Vector2 = target - global_position
	if off.length() > LEAP_MAX_DIST:
		target = global_position + off.normalized() * LEAP_MAX_DIST
	_leap_from = global_position
	_leap_to = target
	_land_poly = Telegraph.make_circle_poly(get_tree().current_scene, _leap_to, LAND_RADIUS)
	if _flash_timer <= 0.0:
		FX.apply_body_tint(_body_base, WINDUP_COLOR, WINDUP_STRENGTH)
	_rig("leap_windup")
	FX.play_sound("slime_windup")


func _tick_windup(delta: float) -> void:
	velocity = _knockback_vel
	move_and_slide()
	_phase_timer -= delta
	# Squash DOWN, anticipation. (1 → flattened) over the windup.
	var t: float = 1.0 - clamp(_phase_timer / WINDUP_TIME, 0.0, 1.0)
	_apply_squash(lerp(1.0, 1.35, t), lerp(1.0, 0.7, t), 0.0)
	if _phase_timer <= 0.0:
		_launch_leap()


func _launch_leap() -> void:
	state = State.LEAP
	_phase_timer = LEAP_TIME
	# Stretch tall as it springs.
	_apply_squash(0.8, 1.3, 0.0)
	_rig("leap_air")
	FX.play_sound("slime_leap")


func _tick_leap(delta: float) -> void:
	_phase_timer -= delta
	var t: float = 1.0 - clamp(_phase_timer / LEAP_TIME, 0.0, 1.0)
	# Move the body along the ground path; do NOT re-home (locked at windup).
	global_position = _leap_from.lerp(_leap_to, t)
	velocity = Vector2.ZERO
	# Parabolic visual hop on the Body node (peak at mid-flight).
	var arc: float = sin(PI * t) * HOP_HEIGHT
	if _body_node:
		_body_node.position = _body_pos0 + Vector2(0, -arc)
		if not _use_rig:
			# Stretch in air, easing back toward neutral near the apex.
			var s: float = lerp(0.85, 1.0, sin(PI * t))
			_body_node.scale = Vector2(_body_scale0.x * s, _body_scale0.y * (2.0 - s) * 0.92)
	if _phase_timer <= 0.0:
		_do_land()


func _do_land() -> void:
	state = State.LAND
	_phase_timer = 0.12
	global_position = _leap_to
	if _body_node:
		_body_node.position = _body_pos0
	# Hard splat squash.
	_apply_squash(1.5, 0.55, 0.0)
	_rig("leap_land")
	# Clear the telegraph the instant the splat lands.
	if is_instance_valid(_land_poly):
		Telegraph.flash_fire(_land_poly)
		get_tree().create_timer(0.12).timeout.connect(_free_poly.bind(_land_poly))
		_land_poly = null
	FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_TINY)
	FX.spawn_burst_particles(global_position + Vector2(0, 6), Color(1.0, 0.55, 0.15, 0.9), 14)
	# AoE damage == painted circle.
	if not _did_splat:
		_did_splat = true
		for h in get_tree().get_nodes_in_group("player"):
			if not (h is Node2D) or not h.visible:
				continue
			if h.has_method("is_downed") and h.is_downed():
				continue
			if (h as Node2D).global_position.distance_to(_leap_to) <= LAND_RADIUS + 10.0:
				if h.has_method("take_damage"):
					var kdir: Vector2 = ((h as Node2D).global_position - _leap_to).normalized()
					h.take_damage(_frost_shielded_damage(attack_damage), kdir * 0.4)
					# Run 122 — poison / slow / stun on the landing splat.
					StatusComponent.inflict_hero_status(h, self)
	Telegraph.release_slot(self)
	if _flash_timer <= 0.0:
		FX.clear_body_tint(_body_base)


func _tick_land(delta: float) -> void:
	velocity = _knockback_vel
	move_and_slide()
	_phase_timer -= delta
	if _phase_timer <= 0.0:
		state = State.RECOVER
		_phase_timer = RECOVER_TIME


func _tick_recover(delta: float) -> void:
	velocity = _knockback_vel
	move_and_slide()
	_phase_timer -= delta
	# Ease the squash back to neutral over the recovery — a clear punish window.
	var t: float = 1.0 - clamp(_phase_timer / RECOVER_TIME, 0.0, 1.0)
	_apply_squash(lerp(1.5, 1.0, t), lerp(0.55, 1.0, t), 0.0)
	if _phase_timer <= 0.0:
		_reset_body()
		state = State.CHASE
		_cooldown = randf_range(COOLDOWN_MIN, COOLDOWN_MAX)


func _tick_stunned(delta: float) -> void:
	_stun_timer -= delta
	velocity = _knockback_vel
	move_and_slide()
	if _stun_timer <= 0.0:
		state = State.CHASE


# Free a telegraph poly after a delay timer fires (guards against early death).
func _free_poly(p: Node) -> void:
	if is_instance_valid(p):
		p.queue_free()


func _cancel_leap() -> void:
	if is_instance_valid(_land_poly):
		_land_poly.queue_free()
	_land_poly = null
	Telegraph.release_slot(self)
	_reset_body()
	if _flash_timer <= 0.0:
		FX.clear_body_tint(_body_base)
	_cooldown = randf_range(COOLDOWN_MIN, COOLDOWN_MAX) * 0.5


# ---------------------------------------------------------------------------
# Run 124 — close-range elemental breath (rig jellies) + rig anim helper
# ---------------------------------------------------------------------------

# Drive a MonsterRig animation state (no-op on the stick-figure fallback, which
# just ignores unknown states).
func _rig(s: String) -> void:
	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_anim_state(s)


func _begin_element(to_player: Vector2) -> void:
	state = State.ELEMENT
	_phase_timer = ELEMENT_WINDUP
	_elem_fired = false
	_elem_dir = to_player.normalized() if to_player.length() > 0.01 else Vector2.RIGHT
	if body_anim and body_anim.has_method("face_towards"):
		body_anim.face_towards(_elem_dir.x)
	# Run 135 — paint the breath cone for the whole windup (the dodge window).
	if is_instance_valid(_elem_poly):
		_elem_poly.queue_free()
	_elem_poly = Telegraph.make_cone_poly(get_tree().current_scene,
		global_position, _elem_dir, ELEMENT_HIT_RANGE, ELEMENT_CONE_DEG)
	_rig("element_windup")
	if _flash_timer <= 0.0:
		FX.apply_body_tint(_body_base, WINDUP_COLOR, WINDUP_STRENGTH)
	FX.play_sound("slime_windup")


func _tick_element(delta: float) -> void:
	velocity = _knockback_vel
	move_and_slide()
	if body_anim and body_anim.has_method("face_towards"):
		body_anim.face_towards(_elem_dir.x)
	_phase_timer -= delta
	if not _elem_fired:
		if _phase_timer <= 0.0:
			_elem_fired = true
			_phase_timer = ELEMENT_ACTIVE
			_rig("element_hit")
			_do_element_hit()
			# Flash the cone hot the instant the breath lands, then clear it.
			if is_instance_valid(_elem_poly):
				Telegraph.flash_fire(_elem_poly)
				get_tree().create_timer(0.12).timeout.connect(_free_poly.bind(_elem_poly))
				_elem_poly = null
	else:
		if _phase_timer <= 0.0:
			if _flash_timer <= 0.0:
				FX.clear_body_tint(_body_base)
			state = State.CHASE
			_elem_cd = randf_range(ELEMENT_CD_MIN, ELEMENT_CD_MAX)
			_cooldown = maxf(_cooldown, 0.5)


# The breath damage: a short forward cone in front of the jelly.
func _do_element_hit() -> void:
	var origin: Vector2 = global_position
	FX.spawn_burst_particles(origin + _elem_dir * 40.0 + Vector2(0, -4),
		Color(0.8, 0.9, 1.0, 0.9), 12)
	for h in get_tree().get_nodes_in_group("player"):
		if not (h is Node2D) or not h.visible:
			continue
		if h.has_method("is_downed") and h.is_downed():
			continue
		var off: Vector2 = (h as Node2D).global_position - origin
		var d: float = off.length()
		if d > ELEMENT_HIT_RANGE:
			continue
		# Frontal cone: must match the painted telegraph (ELEMENT_CONE_DEG).
		if d > 8.0 and _elem_dir.dot(off / d) < ELEMENT_CONE_DOT:
			continue
		if h.has_method("take_damage"):
			h.take_damage(_frost_shielded_damage(attack_damage), _elem_dir * 0.3)
			StatusComponent.inflict_hero_status(h, self)


# Run 150 — Frost Shield parity (Wiring_Gaps row): a chilled/frozen jelly
# hits 15% weaker (splat + breath), like every other enemy script.
func _frost_shielded_damage(base_dmg: int) -> int:
	if status and (status.has("chilled") or status.has("frozen")):
		var fs_red: float = float(RunState.get_frost_shield_reduction())
		if fs_red > 0.0:
			return maxi(1, int(round(float(base_dmg) * (1.0 - fs_red))))
	return base_dmg


func _cancel_element() -> void:
	if is_instance_valid(_elem_poly):
		_elem_poly.queue_free()
	_elem_poly = null
	if _flash_timer <= 0.0:
		FX.clear_body_tint(_body_base)
	_elem_cd = randf_range(ELEMENT_CD_MIN, ELEMENT_CD_MAX) * 0.5
	state = State.STUNNED
	_stun_timer = stun_duration


# ---------------------------------------------------------------------------
# Squash / stretch helpers
# ---------------------------------------------------------------------------

func _apply_squash(sx: float, sy: float, _unused: float) -> void:
	# Run 124 — rig jellies animate squash via hand-drawn frames; skip the
	# procedural scale so the two don't fight.
	if _use_rig:
		return
	if _body_node:
		_body_node.scale = Vector2(_body_scale0.x * sx, _body_scale0.y * sy)


func _reset_body() -> void:
	if _body_node:
		_body_node.scale = _body_scale0
		_body_node.position = _body_pos0


# Tiny vertical squish-bob while hop-drifting, sold off a time sine.
func _hop_bob() -> void:
	if _body_node == null or _use_rig:
		return
	var b: float = sin(Time.get_ticks_msec() * 0.012)
	_body_node.scale = Vector2(_body_scale0.x * (1.0 + 0.06 * b), _body_scale0.y * (1.0 - 0.06 * b))


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

	var _kb_scale: float = minf(knockback_dir.length(), 1.0)
	# Run 118 — Breakbar hosts (boss/miniboss) FULLY immune to knockback.
	var _has_breakbar: bool = status != null and status.breakbar_enabled
	if knockback_dir.length() > 0.01:
		if _has_breakbar:
			if not status.is_breakbar_broken():
				status.contribute_breakbar_knockback()
		else:
			_knockback_vel = knockback_dir.normalized() * KNOCKBACK_STRENGTH * _kb_scale

	# Run 150 (Bruno fix 10): plain hits NEVER pop a windup any more — enemies
	# always get their attack off. Only boon CC (bash/frozen/root/knockup)
	# cancels, via the StatusComponent hard-lock path. Solid hits still stagger
	# a CHASING slime (movement flinch, not an attack interrupt).
	if _kb_scale >= 0.5 and not _has_breakbar and state == State.CHASE:
		state = State.STUNNED
		_stun_timer = stun_duration

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
	return state == State.WINDUP or state == State.LEAP or state == State.ELEMENT


func _start_flash() -> void:
	_flash_timer = FLASH_DURATION
	FX.apply_body_tint(_body_base, HIT_COLOR, FLASH_STRENGTH)


func _end_flash() -> void:
	if state == State.DEAD:
		return
	if state == State.WINDUP:
		FX.apply_body_tint(_body_base, WINDUP_COLOR, WINDUP_STRENGTH)
	else:
		FX.clear_body_tint(_body_base)


func _die() -> void:
	state = State.DEAD
	if is_instance_valid(_land_poly):
		_land_poly.queue_free()
	_land_poly = null
	if is_instance_valid(_elem_poly):
		_elem_poly.queue_free()
	_elem_poly = null
	Telegraph.release_slot(self)
	_reset_body()
	FX.apply_body_tint(_body_base, Color(1.0, 1.0, 1.0, 1.0), 0.85)
	set_physics_process(false)
	FX.spawn_burst_particles(global_position, Color(0.6, 0.9, 0.7, 1.0), 16)
	FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_TINY)
	FX.play_sound("enemy_die")
	# Run 131 — shared on-death boon hook (Juicebox, Wave Crash, Summer's End,
	# Rotten Core, Plague Layer — replaces the inline Juicebox loop).
	RunState.process_enemy_death_boons(self)
	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_anim_state("death")
	await get_tree().create_timer(0.40).timeout
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
