extends CharacterBody2D

# ============================================================
# LaserEnemy.gd — Run 57 (2026-06-13) — ZAP beam ranged enemy
# ============================================================
# A second ranged archetype that adds POSITIONAL pressure without
# bullet-hell density. Behaviour:
#
#   KITING  → keeps PREFERRED_RANGE, like the plinker shooter.
#   CHARGING→ once cooldown is up, in range AND it can grab a global
#             Telegraph slot, it LOCKS a beam line from itself through
#             the player's current spot and paints a 2.0s ground
#             corridor (consistent amber, floor still visible). The
#             line does NOT track the player after lock — you dodge by
#             stepping out of the painted zone.
#   ZAP     → at the end of the 2s the corridor flashes hot and an
#             INSTANT beam hits everything inside it. Hitbox == the
#             painted corridor exactly (same length + half-width), so
#             "out of the highlight" always means "safe".
#   STUNNED → a solid player hit CANCELS the charge (frees the zone,
#             returns the slot). Aggression is a valid answer to a
#             winding-up laser — rewards mowing in, not just dodging.
#
# Concurrency is capped by Telegraph (only a few big AoEs at once), and
# each laser's own long cooldown keeps zaps rare. This is the "some
# dodging, not a wall of lasers" enemy.
# ============================================================

@export var max_hp: int            = 46
@export var move_speed: float      = 70.0    # slow — it's an emplacement, not a chaser
@export var preferred_range: float = 300.0
@export var detect_radius: float   = 520.0
@export var shot_damage: int       = 14      # a clean hit stings — reward dodging
@export var stun_duration: float   = 0.35
# Run 122 — generic on-hit status hooks (poison / slow / stun) dealt by the zap.
# 0 = none. Set by DreamSpawner.apply_config (e.g. Licorice Lasher = stun).
@export var on_hit_poison_stacks: int = 0
@export var on_hit_poison_duration: float = 4.0
@export var on_hit_slow_stacks: int = 0
@export var on_hit_stun_duration: float = 0.0

var current_hp: int = 46

# --- Beam tuning ---
const CHARGE_TIME:     float = 2.0    # ground highlight lead — Bruno's reaction window
const BEAM_LENGTH:     float = 600.0
const BEAM_HALF_WIDTH: float = 26.0
const ZAP_FLASH:       float = 0.16   # how long the hot zap line lingers
const COOLDOWN_MIN:    float = 3.2    # sparse — never a strobing wall of beams
const COOLDOWN_MAX:    float = 5.0

enum State { IDLE, KITING, CHARGING, STUNNED, DEAD }
var state: State = State.IDLE

var _shot_cooldown: float = 0.0
var _charge_timer:  float = 0.0
var _stun_timer:    float = 0.0

# Locked beam geometry for the in-flight charge.
var _beam_origin: Vector2 = Vector2.ZERO
var _beam_dir:    Vector2 = Vector2.RIGHT
var _beam_poly:   Polygon2D = null
var _beam_len:    float = BEAM_LENGTH   # Run 90 — actual length after wall-clamp

var _player: CharacterBody2D = null

const KNOCKBACK_STRENGTH: float = 230.0
const KNOCKBACK_FRICTION: float = 9.0
var _knockback_vel: Vector2 = Vector2.ZERO

const FLASH_DURATION: float = 0.12
const BASE_COLOR:    Color = Color(1.0, 1.0, 1.0, 0.0)
const HIT_COLOR:     Color = Color(1.0, 0.18, 0.18, 1.0)
const CHARGE_COLOR:  Color = Color(1.0, 0.10, 0.10, 0.9)   # danger red — matches its ground zone (Run 122)
const FLASH_STRENGTH:  float = 0.6
const CHARGE_STRENGTH: float = 0.6
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
	_shot_cooldown = randf_range(COOLDOWN_MIN, COOLDOWN_MAX) * 0.6
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

	if _shot_cooldown > 0.0:
		_shot_cooldown -= delta

	if _player == null:
		_find_player()

	# Bash freezes it; a charge in progress is dropped cleanly.
	# Run 150 (Bruno fix 10): only hard CC drops the charge — soft hitstop
	# pauses the body without robbing the beam.
	if status and status.is_movement_locked():
		if state == State.CHARGING and status.is_hard_locked():
			_cancel_charge()
		velocity = _knockback_vel
		move_and_slide()
	else:
		match state:
			State.IDLE:
				_tick_idle()
			State.KITING:
				_tick_kiting(delta)
			State.CHARGING:
				_tick_charging(delta)
			State.STUNNED:
				_tick_stunned(delta)

	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_motion_speed(velocity.length())
		if state == State.CHARGING:
			body_anim.set_anim_state("windup_a")
		elif velocity.length() > 6.0:
			body_anim.set_anim_state("walking")
		else:
			body_anim.set_anim_state("idle")

	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0:
			_end_flash()


func _tick_idle() -> void:
	velocity = _knockback_vel
	move_and_slide()
	if _player and global_position.distance_to(_player.global_position) <= detect_radius:
		state = State.KITING


func _tick_kiting(delta: float) -> void:
	if _player == null:
		velocity = _knockback_vel
		move_and_slide()
		return

	var to_player: Vector2 = _player.global_position - global_position
	var dist: float = to_player.length()

	var dir: Vector2 = Vector2.ZERO
	if dist > preferred_range + 25.0:
		dir = to_player.normalized()
	elif dist < preferred_range - 35.0:
		dir = -to_player.normalized()
	velocity = dir * move_speed + _knockback_vel
	move_and_slide()

	# Begin a charge only if cooldown is up, in range, AND a global AoE slot is
	# free. If the cap is full it just keeps kiting and tries again — that's the
	# anti-bullet-hell gate.
	if _shot_cooldown <= 0.0 and dist <= detect_radius:
		if Telegraph.request_slot(self):
			_begin_charge()


func _begin_charge() -> void:
	state = State.CHARGING
	_charge_timer = CHARGE_TIME
	# Lock geometry NOW — the beam will NOT follow the player after this.
	_beam_origin = global_position
	_beam_dir = (_player.global_position - global_position)
	if _beam_dir.length() < 1.0:
		_beam_dir = Vector2.RIGHT
	_beam_dir = _beam_dir.normalized()
	# Run 90 — clamp the beam to the first barrier so the corridor never paints
	# (or zaps) through a wall. "Out of the highlight" stays a truthful promise.
	_beam_len = EnemyNav.corridor_distance(self, _beam_origin, _beam_dir, BEAM_LENGTH, BEAM_HALF_WIDTH)
	_beam_poly = Telegraph.make_beam_poly(
		get_tree().current_scene, _beam_origin, _beam_dir, _beam_len, BEAM_HALF_WIDTH)
	if _flash_timer <= 0.0:
		FX.apply_body_tint(_body_base, CHARGE_COLOR, CHARGE_STRENGTH)
	FX.play_sound("laser_charge")


func _tick_charging(delta: float) -> void:
	# Planted while charging (only knockback nudges it). Keep the origin pinned
	# to where it locked so the hitbox matches the painted zone exactly.
	velocity = _knockback_vel
	move_and_slide()

	# Pulse the zone edge brighter as the zap nears so imminence reads clearly.
	if is_instance_valid(_beam_poly):
		var t: float = 1.0 - clamp(_charge_timer / CHARGE_TIME, 0.0, 1.0)
		var a: float = lerp(Telegraph.FILL_ALPHA, Telegraph.FILL_ALPHA + 0.18, t)
		_beam_poly.color.a = a + 0.06 * sin(Time.get_ticks_msec() * 0.02)

	_charge_timer -= delta
	if _charge_timer <= 0.0:
		_fire_zap()


func _fire_zap() -> void:
	# Hot flash on the exact painted corridor, then deal damage to anyone inside.
	if is_instance_valid(_beam_poly):
		Telegraph.flash_fire(_beam_poly)
		get_tree().create_timer(ZAP_FLASH).timeout.connect(_free_poly.bind(_beam_poly))
		_beam_poly = null
	FX.screen_shake(FX.SHAKE_MEDIUM, FX.SHAKE_DUR_SHORT)
	FX.play_sound("laser_zap")
	FX.spawn_burst_particles(_beam_origin, Telegraph.FIRE_COLOR, 12)

	# Hitbox == painted corridor: project each hero onto the beam axis; if the
	# projection falls within [0, length] and lateral offset <= half-width, ZAP.
	for h in get_tree().get_nodes_in_group("player"):
		if not (h is Node2D) or not h.visible:
			continue
		if h.has_method("is_downed") and h.is_downed():
			continue
		var rel: Vector2 = (h as Node2D).global_position - _beam_origin
		var along: float = rel.dot(_beam_dir)
		if along < 0.0 or along > _beam_len:
			continue
		var lateral: float = absf(rel.dot(_beam_dir.orthogonal()))
		if lateral <= BEAM_HALF_WIDTH + 12.0:   # +12 forgiveness so grazes feel fair
			if h.has_method("take_damage"):
				# Run 150 — Frost Shield parity (Wiring_Gaps row): chilled/frozen
				# laser fires a 15% weaker beam, like every other enemy.
				var dmg_out: int = shot_damage
				if status and (status.has("chilled") or status.has("frozen")):
					var fs_red: float = float(RunState.get_frost_shield_reduction())
					if fs_red > 0.0:
						dmg_out = maxi(1, int(round(float(dmg_out) * (1.0 - fs_red))))
				h.take_damage(dmg_out, _beam_dir * 0.3)
				# Run 122 — poison / slow / stun on a clean zap.
				StatusComponent.inflict_hero_status(h, self)

	Telegraph.release_slot(self)
	if _flash_timer <= 0.0:
		FX.clear_body_tint(_body_base)
	_shot_cooldown = randf_range(COOLDOWN_MIN, COOLDOWN_MAX)
	state = State.KITING


# Free a telegraph poly after a delay timer fires (guards against early death).
func _free_poly(p: Node) -> void:
	if is_instance_valid(p):
		p.queue_free()


func _cancel_charge() -> void:
	if is_instance_valid(_beam_poly):
		_beam_poly.queue_free()
	_beam_poly = null
	Telegraph.release_slot(self)
	if _flash_timer <= 0.0:
		FX.clear_body_tint(_body_base)
	# Punish the interrupt a little: short cooldown before it can try again.
	_shot_cooldown = randf_range(COOLDOWN_MIN, COOLDOWN_MAX) * 0.5


func _tick_stunned(delta: float) -> void:
	_stun_timer -= delta
	velocity = _knockback_vel
	move_and_slide()
	if _stun_timer <= 0.0:
		state = State.KITING


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
	if knockback_dir.length() > 0.01:
		if _has_breakbar:
			if not status.is_breakbar_broken():
				status.contribute_breakbar_knockback()
		else:
			_knockback_vel = knockback_dir.normalized() * KNOCKBACK_STRENGTH * _kb_scale

	# Run 150 (Bruno fix 10): plain hits no longer interrupt the laser charge —
	# the beam always gets off (super-armor while charging). Only boon CC
	# (bash/frozen/root) cancels via the StatusComponent hard-lock path. Solid
	# hits still stagger it outside the charge.
	if not _has_breakbar and _kb_scale >= 0.5 \
	and state != State.CHARGING and state != State.STUNNED:
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
	return state == State.CHARGING


func _start_flash() -> void:
	_flash_timer = FLASH_DURATION
	FX.apply_body_tint(_body_base, HIT_COLOR, FLASH_STRENGTH)


func _end_flash() -> void:
	if state == State.DEAD:
		return
	if state == State.CHARGING:
		FX.apply_body_tint(_body_base, CHARGE_COLOR, CHARGE_STRENGTH)
	else:
		FX.clear_body_tint(_body_base)


func _die() -> void:
	state = State.DEAD
	# Drop the slot/zone if it dies mid-charge.
	if is_instance_valid(_beam_poly):
		_beam_poly.queue_free()
	_beam_poly = null
	Telegraph.release_slot(self)
	FX.apply_body_tint(_body_base, Color(1.0, 1.0, 1.0, 1.0), 0.85)
	set_physics_process(false)
	FX.spawn_burst_particles(global_position, Color(1.0, 0.55, 0.15, 1.0), 16)
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
