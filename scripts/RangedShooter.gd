extends CharacterBody2D
# ============================================================
# RangedShooter.gd — Phase 5+ enemy variant (Cyan Crystal)
# ============================================================
# Behavior:
#   IDLE_AT_RANGE → if player within DETECT_RADIUS, picks up the chase.
#   KITING        → maintains PREFERRED_RANGE from player by walking
#                   AWAY when too close and INTO range when too far.
#                   While in range, every SHOT_INTERVAL fires a projectile
#                   at the player's *current* position (no leading).
#   STUNNED       → brief hit-stun from player hits, breaks aim.
#   DEAD          → white flash → queue_free.
#
# Uses the same scripts/KiBlast.tscn projectile as Shino but the projectile
# is re-tinted on spawn and aimed back at the player; collision layer/mask
# are swapped so it hurts the player, not enemies.
#
# Adds to "enemy" group (same as DummyEnemy) so wave_cleared logic and
# Ult AoE still treat it as a wave member.
# ============================================================

@export var max_hp: int                = 35     # weaker than DummyEnemy melee variant
@export var move_speed: float          = 95.0   # slightly faster — needs to reposition
@export var preferred_range: float     = 220.0  # ideal distance to keep from player
@export var detect_radius: float       = 420.0  # acquire-target distance
@export var shot_interval: float       = 1.6    # seconds between shots
@export var shot_damage: int           = 10
@export var shot_speed: float          = 280.0  # slower than Shino's 600 (more dodgeable)
@export var stun_duration: float       = 0.30
# Run 122 — generic on-hit status hooks. The projectile carries these and applies
# them when it strikes the hero (poison / slow / stun). 0 = none. Set by
# DreamSpawner.apply_config from the roster's on_hit_* fields.
@export var on_hit_poison_stacks: int = 0
@export var on_hit_poison_duration: float = 4.0
@export var on_hit_slow_stacks: int = 0
@export var on_hit_stun_duration: float = 0.0
# Run 140 — optional custom projectile sprite (e.g. chocofrog dart).
var projectile_sprite_path: String = ""

var current_hp: int = 35

# --- State machine ---
enum State { IDLE, KITING, STUNNED, DEAD }
var state: State = State.IDLE

# --- Timers ---
var _shot_cooldown: float = 0.0
var _stun_timer:    float = 0.0
var _windup_timer:  float = 0.0
var _is_winding_up: bool  = false
# When > 0, the idle/walk/windup auto-drive below is suppressed so a just-set
# pose (e.g. a fire/attack snap) stays on screen instead of being overwritten
# next frame. Subclasses (PelicanShooter) set this after triggering an attack.
var _anim_lock_timer: float = 0.0

# --- Telegraph window: enemy flashes magenta for SHOT_WINDUP before firing ---
const SHOT_WINDUP: float = 0.45

# --- Player ref ---
var _player: CharacterBody2D = null

# --- Knockback (from player attacks) ---
const KNOCKBACK_STRENGTH: float = 240.0
const KNOCKBACK_FRICTION: float = 9.0
var _knockback_vel: Vector2 = Vector2.ZERO

# --- Visual flash ---
# After the stick-figure refactor (2026-05-27 Run 9), $Sprite is repurposed as
# a full-figure flash overlay; the visible cyan body now lives under $Body/*.
# BASE_COLOR is transparent (idle); HIT/WINDUP cover the whole figure when set.
const FLASH_DURATION: float = 0.12
const BASE_COLOR:    Color = Color(1.0,  1.0,  1.0,  0.0)   # transparent (idle)
const HIT_COLOR:     Color = Color(1.0,  0.18, 0.18, 1.0)
const WINDUP_COLOR:  Color = Color(0.95, 0.30, 0.95, 0.90)  # magenta — incoming shot tell
var _flash_timer: float = 0.0
# Run 55 — flash tints the Body silhouette instead of the opaque $Sprite square.
const FLASH_STRENGTH:  float = 0.6
const WINDUP_STRENGTH: float = 0.55
var _body_base: Dictionary = {}

# --- Damage numbers ---
var _dmg_num_scene: PackedScene = null
var _projectile_scene: PackedScene = null

# --- Status component (Bash, Vulnerable, etc. — Run 9) ---
var status: StatusComponent = null

# --- Nodes ---
@onready var sprite: ColorRect = $Sprite
@onready var hp_label: Label   = $HPLabel
@onready var name_label: Label = $NameLabel
@onready var body_anim: Node   = get_node_or_null("Body")   # BodyAnimator (Run 9)


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	current_hp = max_hp
	add_to_group("enemy")
	# Status component — shooters can be Bashed mid-windup too.
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
	if ResourceLoader.exists("res://scenes/EnemyProjectile.tscn"):
		_projectile_scene = load("res://scenes/EnemyProjectile.tscn")
	# Initial cooldown so the first shot doesn't fire instantly.
	_shot_cooldown = shot_interval * 0.6
	call_deferred("_find_player")


func _find_player() -> void:
	# Phase 6 + Run 13: target nearest visible NON-downed player (Shino or Bea).
	# Downed bodies are invulnerable and shouldn't be valid targets.
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


# ---------------------------------------------------------------------------
# Physics tick
# ---------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if state == State.DEAD:
		return

	_knockback_vel = _knockback_vel.lerp(Vector2.ZERO, KNOCKBACK_FRICTION * delta)

	if _shot_cooldown > 0.0:
		_shot_cooldown -= delta

	if _player == null:
		_find_player()

	# Bash interrupts wind-up and freezes the shooter in place.
	# Run 150 (Bruno fix 10): only hard CC cancels the wind-up — soft hitstop
	# pauses the body without robbing the shot.
	if status and status.is_movement_locked():
		if status.is_hard_locked():
			_is_winding_up = false
			_windup_timer = 0.0
		velocity = _knockback_vel
		move_and_slide()
	else:
		match state:
			State.IDLE:
				_tick_idle()
			State.KITING:
				_tick_kiting(delta)
			State.STUNNED:
				_tick_stunned(delta)

	# Drive animator based on resulting state.
	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_motion_speed(velocity.length())
		if _anim_lock_timer > 0.0:
			_anim_lock_timer -= delta   # hold the current pose (e.g. a fire snap)
		elif _is_winding_up:
			body_anim.set_anim_state("windup_a")   # arms drawn back to charge a shot
			# Run 150 — face the target while aiming so the telegraph reads correctly
			# (velocity may be ~0 during the windup hold, so MonsterRig's velocity-
			# based facing wouldn't flip us). Ranged enemies must visually aim at the
			# player for the shot to look intentional.
			if _player and body_anim.has_method("face_towards"):
				var aim_dx: float = _player.global_position.x - global_position.x
				body_anim.face_towards(aim_dx)
		elif velocity.length() > 6.0:
			body_anim.set_anim_state("walking")
		else:
			body_anim.set_anim_state("idle")

	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0:
			_end_flash()


func _tick_idle() -> void:
	# Just sit until player enters detect radius.
	velocity = _knockback_vel
	move_and_slide()
	if _player == null:
		return
	if global_position.distance_to(_player.global_position) <= detect_radius:
		state = State.KITING


func _tick_kiting(delta: float) -> void:
	if _player == null:
		velocity = _knockback_vel
		move_and_slide()
		return

	var to_player: Vector2 = _player.global_position - global_position
	var dist: float = to_player.length()

	# Walk to maintain preferred range. Run 90 — route around barriers instead of
	# beelining: close in via EnemyNav toward the player; back away via EnemyNav
	# toward a point directly away from them.
	var dir: Vector2 = Vector2.ZERO
	if dist > preferred_range + 20.0:
		dir = EnemyNav.move_dir(self, _player.global_position, delta)        # too far → close in
	elif dist < preferred_range - 30.0:
		var retreat: Vector2 = global_position - to_player.normalized() * 140.0
		dir = EnemyNav.move_dir(self, retreat, delta)                        # too close → back away
	# else: strafe-stationary in dead-zone (~50px buffer for snappy lock-in)

	velocity = dir * move_speed + _knockback_vel
	move_and_slide()

	# Shot windup → fire flow
	if _is_winding_up:
		_windup_timer -= delta
		if _windup_timer <= 0.0:
			_is_winding_up = false
			_fire_shot()
			_shot_cooldown = _next_interval()
		return

	# Begin a windup if cooldown is up AND player is in range
	if _shot_cooldown <= 0.0 and dist <= detect_radius:
		_is_winding_up = true
		_windup_timer = SHOT_WINDUP
		if _flash_timer <= 0.0:
			FX.apply_body_tint(_body_base, WINDUP_COLOR, WINDUP_STRENGTH)
		# Run 57 — the magenta GROUND BEAM telegraph was removed: it read as a
		# distracting laser and these plinkers aren't a dodge-AoE threat. The
		# slow magenta projectile is the tell now (plus the brief body wind-up
		# flash) — the player reads the shot and side-steps. Cadence is
		# randomised via _next_interval() so volleys feel organic, never a
		# metronomic bullet-hell wall.


func _tick_stunned(delta: float) -> void:
	_stun_timer -= delta
	velocity = _knockback_vel
	move_and_slide()
	if _stun_timer <= 0.0:
		state = State.KITING


# ---------------------------------------------------------------------------
# Firing
# ---------------------------------------------------------------------------

# Run 57 — randomised cadence so a cluster of shooters doesn't fire in lockstep.
# Spread around shot_interval (±~40%) keeps volleys dodgeable and organic.
func _next_interval() -> float:
	return shot_interval * randf_range(0.70, 1.45)


func _fire_shot() -> void:
	if _player == null or _projectile_scene == null:
		return
	var dir: Vector2 = (_player.global_position - global_position)
	if dir.length() < 1.0:
		return
	dir = dir.normalized()
	var proj = _projectile_scene.instantiate()
	var parent = get_parent()
	if parent == null:
		return
	# Run 140 — custom projectile sprite (e.g. chocofrog dart).
	# Run 150 — set BEFORE add_child so _ready() sees the path and swaps the sprite.
	if projectile_sprite_path != "":
		proj.set("custom_texture_path", projectile_sprite_path)
	parent.add_child(proj)
	proj.global_position = global_position + dir * 18.0
	# Run 23 — Frost Shield duo: chilled/frozen attacker fires weaker projectiles.
	var dmg_out: int = shot_damage
	if status and (status.has("chilled") or status.has("frozen")):
		var fs_red: float = float(RunState.get_frost_shield_reduction())
		if fs_red > 0.0:
			dmg_out = int(round(float(dmg_out) * (1.0 - fs_red)))
			if dmg_out < 1:
				dmg_out = 1
	if proj.has_method("launch"):
		proj.launch(dir, shot_speed, dmg_out)
	# Run 122 — hand the on-hit status payload to the projectile so it can inflict
	# poison / slow / stun on the hero it strikes (no-op fields = plain shot).
	proj.set("on_hit_poison_stacks", on_hit_poison_stacks)
	proj.set("on_hit_poison_duration", on_hit_poison_duration)
	proj.set("on_hit_slow_stacks", on_hit_slow_stacks)
	proj.set("on_hit_stun_duration", on_hit_stun_duration)
	# Run 150 — smoke puff at the muzzle when the shot launches (dart blowgun,
	# mustard cannon, etc.). Brownish-grey burst reads as "something just fired".
	FX.spawn_burst_particles(global_position + dir * 18.0, Color(0.45, 0.38, 0.30, 0.85), 8)
	# Reset body from windup magenta back to base cyan
	if _flash_timer <= 0.0:
		FX.clear_body_tint(_body_base)
	# Run 9 — fire pose: arms thrust forward as the projectile spawns.
	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_anim_state("swing_a")
		# Run 150 — face the target on the fire frame too, so the blow/spit
		# pose visually matches the shot direction.
		if _player and body_anim.has_method("face_towards"):
			body_anim.face_towards(dir.x)


# ---------------------------------------------------------------------------
# Damage
# ---------------------------------------------------------------------------

func take_damage(amount: int, knockback_dir: Vector2 = Vector2.ZERO) -> void:
	if state == State.DEAD:
		return
	# Vulnerable amp via StatusComponent.
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
	# Run 9 — hit recoil animation.
	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_anim_state("hit_recoil")
	# Run 49 — knockback vector length acts as a strength scalar (clamped ≤1.0;
	# normalized-vector callers unchanged). Kunai passes 0.25 → minimal flinch.
	var _kb_scale: float = minf(knockback_dir.length(), 1.0)
	# Run 118 — Breakbar hosts (boss/miniboss) FULLY immune to knockback.
	var _has_breakbar: bool = status != null and status.breakbar_enabled
	if knockback_dir.length() > 0.01:
		if _has_breakbar:
			if not status.is_breakbar_broken():
				status.contribute_breakbar_knockback()
		else:
			_knockback_vel = knockback_dir.normalized() * KNOCKBACK_STRENGTH * _kb_scale
	# Run 150 (Bruno fix 10): plain hits no longer cancel the wind-up — the
	# shooter always gets its shot off (super-armor while aiming). Only boon CC
	# (bash/frozen/root) cancels via the StatusComponent hard-lock path. Solid
	# hits still stagger it when it's NOT lining up a shot.
	if _kb_scale >= 0.5 and not _is_winding_up \
	and state != State.STUNNED and state != State.DEAD and not _has_breakbar:
		state = State.STUNNED
		_stun_timer = stun_duration
	if current_hp <= 0:
		_die()


# ---------------------------------------------------------------------------
# Visuals / lifecycle
# ---------------------------------------------------------------------------

func _start_flash() -> void:
	_flash_timer = FLASH_DURATION
	FX.apply_body_tint(_body_base, HIT_COLOR, FLASH_STRENGTH)


func _end_flash() -> void:
	if state == State.DEAD:
		return
	if _is_winding_up:
		FX.apply_body_tint(_body_base, WINDUP_COLOR, WINDUP_STRENGTH)
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
	return _is_winding_up and state != State.DEAD


func _die() -> void:
	state = State.DEAD
	FX.apply_body_tint(_body_base, Color(1.0, 1.0, 1.0, 1.0), 0.85)
	set_physics_process(false)
	# Phase 7 — cyan burst on shooter death
	FX.spawn_burst_particles(global_position, Color(0.30, 0.75, 0.95, 1.0), 16)
	FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_TINY)
	FX.play_sound("enemy_die")
	# Run 131 — shared on-death boon hook (Juicebox, Wave Crash, Summer's End,
	# Rotten Core, Plague Layer — replaces the inline Juicebox loops).
	RunState.process_enemy_death_boons(self)
	# Run 9 — body tip-over animation. Wait for it to play before freeing.
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
