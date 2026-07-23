extends CharacterBody2D

# ============================================================
# FastScout.gd — fast melee scout enemy variant (Run 9)
# ============================================================
# Differentiates from DummyEnemy by being squishier, faster, and
# committing to attacks sooner. Texture in combat:
#   - DummyEnemy = tanky scrapper (60 HP, slow walk, telegraphed)
#   - FastScout  = glass ninja  (25 HP, fast walk, blink-attack)
#
# State machine mirrors DummyEnemy but with tightened timings.
# Same hit-flash, knockback, and damage-number pipeline so it
# integrates cleanly with the rest of the systems.
# ============================================================

@export var max_hp: int            = 25
@export var move_speed: float      = 135.0
@export var attack_damage: int     = 5
@export var attack_range: float    = 30.0
@export var attack_cooldown: float = 1.0
@export var stun_duration: float   = 0.18
# Run 122 — generic enemy→hero on-hit status hooks (poison / slow / stun).
# 0 = none. Set by DreamSpawner.apply_config; delivered on a connecting contact.
@export var on_hit_poison_stacks: int = 0
@export var on_hit_poison_duration: float = 4.0
@export var on_hit_slow_stacks: int = 0
@export var on_hit_stun_duration: float = 0.0

# Run 57 — "boom" variety. Set by DreamSpawner.apply_config when the enemy cfg
# has behavior:"boom". On reaching the player it lights a short fuse then
# self-destructs in an AoE instead of swiping. Players hate it (in a good way)
# — it forces you to delete the sprinter BEFORE it arrives. Killing it during
# the fuse defuses it, so it's fair: aggression is the counter.
@export var explode_on_reach: bool = false
@export var explode_radius: float  = 62.0
@export var explode_damage: int    = 14
# Run 57b (Bruno) — long, obvious fuse: it PLANTS in place, flashes red and
# fizzes for 1.5s so you can clearly read it and walk out of the blast.
const FUSE_TIME: float = 1.5
# Red blink cadence accelerates toward detonation (slow → frantic).
const FUSE_BLINK_SLOW: float = 0.24
const FUSE_BLINK_FAST: float = 0.06

var current_hp: int = 25

enum State { CHASE, ATTACKING, FUSE, STUNNED, DEAD }
var state: State = State.CHASE

const ATTACK_WINDUP: float   = 0.16   # much shorter than dummy's 0.28
const ATTACK_RECOVERY: float = 0.28

var _attack_timer: float  = 0.0
var _stun_timer: float    = 0.0
var _is_winding_up: bool  = false
# Run 57b — fuse blink state.
var _blink_timer: float   = 0.0
var _blink_on: bool       = false

var _player: CharacterBody2D = null

const FLASH_DURATION: float = 0.10
const BASE_COLOR: Color    = Color(1.0,  1.0,  1.0,  0.0)
const HIT_COLOR: Color     = Color(1.0,  0.18, 0.18, 1.0)
const ATTACK_COLOR: Color  = Color(1.0,  0.85, 0.0,  0.90)   # bright yellow tell
var _flash_timer: float    = 0.0
# Run 55 — flash tints the Body silhouette instead of the opaque $Sprite square.
const FLASH_STRENGTH:  float = 0.6
const WINDUP_STRENGTH: float = 0.55
var _body_base: Dictionary = {}

const KNOCKBACK_STRENGTH: float = 240.0
const KNOCKBACK_FRICTION: float = 12.0
var _knockback_vel: Vector2 = Vector2.ZERO

var _dmg_num_scene: PackedScene = null

# Status component (Bash, Vulnerable, etc.)
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
		sprite.color = BASE_COLOR   # keep the legacy overlay invisible
	_body_base = FX.cache_body_colors(body_anim)
	_refresh_hp_label()
	if ResourceLoader.exists("res://scenes/DamageNumber.tscn"):
		_dmg_num_scene = load("res://scenes/DamageNumber.tscn")
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
		var d: float = global_position.distance_to(p.global_position)
		if d < best_dist:
			best_dist = d
			best = p
	_player = best


func _physics_process(delta: float) -> void:
	if state == State.DEAD:
		return

	_knockback_vel = _knockback_vel.lerp(Vector2.ZERO, KNOCKBACK_FRICTION * delta)

	if status and status.is_movement_locked():
		velocity = _knockback_vel
		move_and_slide()
	else:
		match state:
			State.CHASE:
				_tick_chase(delta)
			State.ATTACKING:
				_tick_attacking(delta)
			State.FUSE:
				_tick_fuse(delta)
			State.STUNNED:
				_tick_stunned(delta)

	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0:
			_end_flash()

	# Drive animator.
	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_motion_speed(velocity.length())
		match state:
			State.CHASE:
				if velocity.length() > 6.0:
					body_anim.set_anim_state("walking")
				else:
					body_anim.set_anim_state("idle")
			State.ATTACKING:
				if _is_winding_up:
					body_anim.set_anim_state("windup_y")
				else:
					body_anim.set_anim_state("swing_y")
			State.FUSE:
				body_anim.set_anim_state("windup_y")
			State.STUNNED:
				body_anim.set_anim_state("idle")


func _tick_chase(delta: float) -> void:
	if _player == null or not _player.visible:
		_find_player()
		if _player == null:
			velocity = _knockback_vel
			move_and_slide()
			return

	var to_player: Vector2 = _player.global_position - global_position
	var dist: float        = to_player.length()

	if _attack_timer > 0.0:
		_attack_timer -= delta

	# Run 90 — a boom-scout still detonates on contact regardless of LOS (it's a
	# walking bomb), but a swiper won't slash through a barrier.
	var can_reach: bool = explode_on_reach \
		or EnemyNav.has_line_of_sight(self, global_position, _player.global_position)
	if dist <= attack_range and _attack_timer <= 0.0 and can_reach:
		if explode_on_reach:
			_start_fuse()
		else:
			_start_attack()
		velocity = _knockback_vel
		move_and_slide()
		return

	# Run 90 — barrier-aware steering instead of beelining.
	var walk_dir: Vector2 = EnemyNav.move_dir(self, _player.global_position, delta) if dist > 1.0 else Vector2.ZERO
	velocity = walk_dir * move_speed + _knockback_vel
	move_and_slide()


func _tick_attacking(delta: float) -> void:
	_attack_timer -= delta
	velocity = _knockback_vel
	move_and_slide()

	if _is_winding_up and _attack_timer <= 0.0:
		_is_winding_up = false
		_deal_melee_damage()
		_attack_timer = ATTACK_RECOVERY
		if _flash_timer <= 0.0:
			FX.clear_body_tint(_body_base)
	elif not _is_winding_up and _attack_timer <= 0.0:
		state = State.CHASE
		_attack_timer = attack_cooldown


func _tick_stunned(delta: float) -> void:
	_stun_timer -= delta
	velocity = _knockback_vel
	move_and_slide()
	if _stun_timer <= 0.0:
		state = State.CHASE


func _start_attack() -> void:
	state           = State.ATTACKING
	_is_winding_up  = true
	_attack_timer   = ATTACK_WINDUP
	if _flash_timer <= 0.0:
		FX.apply_body_tint(_body_base, ATTACK_COLOR, WINDUP_STRENGTH)
	# Run 27 — telegraph: short red circle at player position.
	# FastScout windup is only 0.16s so the circle is very brief —
	# teaches the player to react to the ATTACK_COLOR flash primarily.
	if _player != null:
		FX.spawn_danger_circle(
			_player.global_position,
			attack_range * 1.1,
			Color(1.0, 0.25, 0.08, 0.28),
			ATTACK_WINDUP)


# --- Run 57: BOOM fuse ----------------------------------------------------

func _start_fuse() -> void:
	state = State.FUSE
	_attack_timer = FUSE_TIME
	_is_winding_up = true
	# PLANT and arm: paint the blast radius at SELF so the player can step out,
	# then start the red blink + fizz. Holds position for the whole 1.5s.
	_blink_timer = FUSE_BLINK_SLOW
	_blink_on = true
	FX.apply_body_tint(_body_base, HIT_COLOR, 0.85)
	FX.spawn_danger_circle(
		global_position,
		explode_radius,
		Color(Telegraph.AOE_COLOR.r, Telegraph.AOE_COLOR.g, Telegraph.AOE_COLOR.b, 0.34),
		FUSE_TIME)
	FX.play_sound("scout_fuse")


func _tick_fuse(delta: float) -> void:
	# Stand still (only knockback nudges it) — it's committed, fizzing in place.
	velocity = _knockback_vel
	move_and_slide()

	_attack_timer -= delta

	# Blink red on/off, accelerating as detonation nears, with a fizz tick on
	# each flash so the bomb is unmistakable. (Won't override the brief white
	# hit-flash — that takes priority while _flash_timer is live.)
	_blink_timer -= delta
	if _blink_timer <= 0.0:
		var frac: float = clamp(_attack_timer / FUSE_TIME, 0.0, 1.0)
		_blink_timer = lerp(FUSE_BLINK_FAST, FUSE_BLINK_SLOW, frac)
		_blink_on = not _blink_on
		if _flash_timer <= 0.0:
			if _blink_on:
				FX.apply_body_tint(_body_base, HIT_COLOR, 0.9)
			else:
				FX.clear_body_tint(_body_base)
		FX.play_sound("scout_fuse_fizz", 0.5)

	if _attack_timer <= 0.0:
		_explode()


func _explode() -> void:
	# AoE pop centered on the bomber, then it dies delivering the blast.
	FX.spawn_burst_particles(global_position, Color(1.0, 0.55, 0.15, 1.0), 24)
	FX.screen_shake(FX.SHAKE_MEDIUM, FX.SHAKE_DUR_SHORT)
	FX.play_sound("scout_boom")
	for h in get_tree().get_nodes_in_group("player"):
		if not (h is Node2D) or not h.visible:
			continue
		if h.has_method("is_downed") and h.is_downed():
			continue
		if (h as Node2D).global_position.distance_to(global_position) <= explode_radius + 10.0:
			if h.has_method("take_damage"):
				var kdir: Vector2 = ((h as Node2D).global_position - global_position).normalized()
				h.take_damage(explode_damage, kdir * 0.6)
	current_hp = 0
	_die()


func _deal_melee_damage() -> void:
	if _player == null:
		return
	var dist: float = (_player.global_position - global_position).length()
	if dist > attack_range * 1.6:
		return
	# Run 23 — Frost Shield duo damage reduction on outgoing attack.
	var dmg_out: int = attack_damage
	if status and (status.has("chilled") or status.has("frozen")):
		var fs_red: float = float(RunState.get_frost_shield_reduction())
		if fs_red > 0.0:
			dmg_out = int(round(float(dmg_out) * (1.0 - fs_red)))
			if dmg_out < 1:
				dmg_out = 1
	if _player.has_method("take_damage"):
		_player.take_damage(dmg_out)
		# Run 122 — poison / slow / stun on-hit hooks (generic).
		StatusComponent.inflict_hero_status(_player, self)


func take_damage(amount: int, knockback_dir: Vector2 = Vector2.ZERO) -> void:
	if state == State.DEAD:
		return
	var status_mult: float = 1.0
	if status:
		status_mult = status.get_damage_taken_mult()
	# Run 19 — consolidated target-status damage amps (Rising Tide + Blazing
	# Aura + Wet+Lightning synergy).
	status_mult *= RunState.get_target_status_damage_mult(status)
	# Run 23 — Pepper+Potato "Spicy Landmine": Burning+Rooted enemies take +30% damage.
	if status and RunState.pepper_potato_active():
		if status.has("burning") and status.has("root"):
			status_mult *= (1.0 + RunState.get_pepper_potato_amp())
	# Run 24 — Potato+Watermelon "Mud Tide": Wet+Rooted enemies take +25% damage.
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

	# Run 49 — knockback vector length acts as a strength scalar (clamped ≤1.0
	# so all existing normalized-vector callers are unchanged). Kunai passes a
	# short vector (0.25) → minimal flinch instead of a full shove.
	var _kb_scale: float = minf(knockback_dir.length(), 1.0)
	# Run 118 — Breakbar hosts (boss/miniboss) FULLY immune to knockback.
	var _has_breakbar: bool = status != null and status.breakbar_enabled
	if knockback_dir.length() > 0.01:
		if _has_breakbar:
			if not status.is_breakbar_broken():
				status.contribute_breakbar_knockback()
		else:
			_knockback_vel = knockback_dir.normalized() * KNOCKBACK_STRENGTH * _kb_scale

	# Run 49 — weak hits (scale < 0.5, e.g. kunai) don't break pursuit:
	# enemies keep pushing toward Bea through her ranged spam.
	# Run 57 — a solid hit during the BOOM fuse DEFUSES it (kicks back to a brief
	# stun before it can re-arm). Killing it outright simply never explodes.
	# Run 150 (Bruno fix 10): ATTACKING removed from the interrupt list — plain
	# hits never rob a swing. CHASE stagger + FUSE defuse (deliberate bomb
	# counterplay) remain.
	if _kb_scale >= 0.5 and (state == State.CHASE or state == State.FUSE) and not _has_breakbar:
		state = State.STUNNED
		_stun_timer = stun_duration
		_is_winding_up = false

	if current_hp <= 0:
		_die()


func _start_flash() -> void:
	_flash_timer = FLASH_DURATION
	FX.apply_body_tint(_body_base, HIT_COLOR, FLASH_STRENGTH)


func _end_flash() -> void:
	if state == State.DEAD:
		return
	if state == State.ATTACKING and _is_winding_up:
		FX.apply_body_tint(_body_base, ATTACK_COLOR, WINDUP_STRENGTH)
	else:
		FX.clear_body_tint(_body_base)


# Run 55 — DoT damage path: damage without the red hit-flash (auras carry the
# visual). StatusComponent prefers this over take_damage when present.
func apply_status_dot_damage(amount: int, _src_id: String) -> void:
	if state == State.DEAD:
		return
	var dmg: int = max(1, amount)
	current_hp = max(0, current_hp - dmg)
	_refresh_hp_label()
	_spawn_damage_number(dmg)
	if current_hp <= 0:
		_die()


# Run 15 — Tier-3 AI revive helper hook.
func is_attack_imminent() -> bool:
	return state == State.ATTACKING and _is_winding_up


func _die() -> void:
	state = State.DEAD
	# Run 131 — shared on-death boon hook (Juicebox, Wave Crash, Summer's End,
	# Rotten Core, Plague Layer).
	RunState.process_enemy_death_boons(self)
	FX.apply_body_tint(_body_base, Color(1.0, 1.0, 1.0, 1.0), 0.85)
	set_physics_process(false)
	FX.spawn_burst_particles(global_position, Color(1.0, 0.85, 0.20, 1.0), 14)
	FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_TINY)
	FX.play_sound("enemy_die")
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
