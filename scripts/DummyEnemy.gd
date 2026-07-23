extends CharacterBody2D

# ============================================================
# DummyEnemy.gd — Walking AI Enemy (Phase 5)
# ============================================================
# Upgraded from stationary punching bag to a real combat threat:
#   CHASE   → walks toward the player at move_speed
#   STUNNED → brief hit-pause from player hits (CHASE-only)
#   ATTACKING → wind-up orange tell → deal damage → recovery
#   DEAD    → white flash → queue_free
#
# Super-armor stub: hits during ATTACKING apply damage but don't
# interrupt the attack. Wire full stagger once Phase 5 enemy AI
# is more complex.
#
# Exported params allow per-instance tuning in the Godot editor.
# ============================================================

@export var max_hp: int           = 60
@export var move_speed: float     = 75.0      # px/s chase speed
@export var attack_damage: int    = 8         # damage dealt to player per swing
@export var attack_range: float   = 34.0      # center-to-center attack trigger (px)
@export var attack_cooldown: float = 1.5      # min seconds between attack cycles
@export var stun_duration: float  = 0.25      # hit-stun on CHASE hits (seconds)

# Run 120 — optional on-hit status the melee bite inflicts on the player. Set by
# DreamSpawner.apply_config from a roster "on_hit_burn" field (e.g. the Boardwalk
# Churro Chomper's sizzling bite). Empty = plain hit. Routed through the existing
# StatusComponent burn ticks — no new DoT system.
@export var on_hit_burn_stacks: int = 0       # 0 = no burn on bite
@export var on_hit_burn_duration: float = 3.0
# Run 122 — generic on-hit status hooks (poison / slow / stun). 0 = none. Set by
# DreamSpawner.apply_config; applied to the hero via StatusComponent.inflict_hero_status.
@export var on_hit_poison_stacks: int = 0
@export var on_hit_poison_duration: float = 4.0
@export var on_hit_slow_stacks: int = 0
@export var on_hit_stun_duration: float = 0.0
# Run 122 — bite knocks the hero back (e.g. Marshmallow Mauler). The hero's
# take_damage applies the knockback vector. Set by DreamSpawner.apply_config.
@export var on_hit_knockback: bool = false
const MELEE_KNOCKBACK: float = 0.9   # scalar length passed as the knockback vector
# Run 122 — Nacho-Slag Golem secondary: a periodic telegraphed AoE smash. When
# true, the rig plays its "smash" strip and a big red danger-circle warns before
# a ground-pound shockwave lands. Set by DreamSpawner.apply_config.
@export var secondary_smash: bool = false
const SMASH_COOLDOWN: float   = 5.5    # min seconds between smashes
const SMASH_WINDUP: float     = 0.85   # long, readable telegraph
const SMASH_RECOVERY: float   = 0.55
const SMASH_RADIUS: float     = 130.0  # AoE reach around the golem
const SMASH_RANGE: float      = 190.0  # start a smash when player within this band
var _smash_cd: float = 3.0
var _is_smashing: bool = false

var current_hp: int = 60

# --- State machine ---
enum State { CHASE, ATTACKING, STUNNED, DEAD }
var state: State = State.CHASE

# --- Attack sub-timers ---
# In ATTACKING: counts down wind-up, then recovery.
const ATTACK_WINDUP: float   = 0.28   # orange "tell" before damage (seconds)
const ATTACK_RECOVERY: float = 0.45   # freeze after hit before returning to CHASE

var _attack_timer: float  = 0.0   # shared countdown for wind-up / recovery / cooldown
var _stun_timer: float    = 0.0
var _is_winding_up: bool  = false  # true = in wind-up phase, false = in recovery phase

# --- Player reference ---
var _player: CharacterBody2D = null

# --- Visual flash ---
# After the stick-figure refactor (2026-05-27 Run 9), $Sprite is repurposed
# as a full-figure flash overlay sitting ON TOP of the body parts (under $Body).
# BASE_COLOR is transparent so the overlay is invisible when idle; HIT/ATTACK
# colors are opaque so they cover the entire stick figure when flashed.
const FLASH_DURATION: float = 0.12
const BASE_COLOR: Color    = Color(1.0,  1.0,  1.0,  0.0)   # transparent (idle)
const HIT_COLOR: Color     = Color(1.0,  0.18, 0.18, 1.0)   # red
const ATTACK_COLOR: Color  = Color(1.0,  0.65, 0.0,  0.85)  # orange (wind-up tell)
var _flash_timer: float    = 0.0
# Run 55 — flash now tints the Body silhouette (lerp toward colour) rather than
# painting the old opaque $Sprite square. Partial strength keeps the figure
# readable: a red glow, not a solid block. Base colours cached at _ready.
const FLASH_STRENGTH:  float = 0.6
const WINDUP_STRENGTH: float = 0.55
var _body_base: Dictionary = {}

# --- Knockback (from player attacks) ---
const KNOCKBACK_STRENGTH: float = 200.0   # initial impulse px/s
const KNOCKBACK_FRICTION: float = 10.0    # lerp factor — higher = stops faster
var _knockback_vel: Vector2 = Vector2.ZERO

# --- Damage numbers ---
var _dmg_num_scene: PackedScene = null

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
	# Status component — enemies can be Bashed / Vulnerable like the player.
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
	# Defer player lookup by one frame so the full scene tree is ready.
	call_deferred("_find_player")


func _find_player() -> void:
	# Phase 6: target the nearest player character (Shino or Bea).
	# Run 13: Bea-down stays visible (revive system) — skip downed bodies via
	# is_downed() instead of `not visible`. Both filters kept for safety.
	var players = get_tree().get_nodes_in_group("player")
	var best: CharacterBody2D = null
	var best_dist: float = INF
	for p in players:
		if not p is CharacterBody2D:
			continue
		if not p.visible:
			continue
		# Run 13 — don't target downed bodies (they're invulnerable, on the ground).
		if p.has_method("is_downed") and p.is_downed():
			continue
		var d: float = global_position.distance_to(p.global_position)
		if d < best_dist:
			best_dist = d
			best = p
	_player = best


# ---------------------------------------------------------------------------
# Physics / AI tick
# ---------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if state == State.DEAD:
		return

	# Knockback decays each frame regardless of state.
	_knockback_vel = _knockback_vel.lerp(Vector2.ZERO, KNOCKBACK_FRICTION * delta)

	# StatusComponent movement lock (Bash) — freeze AI ticks while stunned.
	# Knockback still decays so the enemy can settle naturally.
	if status and status.is_movement_locked():
		velocity = _knockback_vel
		move_and_slide()
		# Still tick visual flash countdown below.
	else:
		match state:
			State.CHASE:
				_tick_chase(delta)
			State.ATTACKING:
				_tick_attacking(delta)
			State.STUNNED:
				_tick_stunned(delta)

	# Drive animator based on resulting state.
	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_motion_speed(velocity.length())
		match state:
			State.CHASE:
				if velocity.length() > 6.0:
					body_anim.set_anim_state("walking")
				else:
					body_anim.set_anim_state("idle")
			State.ATTACKING:
				if _is_smashing:
					body_anim.set_anim_state("smash_windup" if _is_winding_up else "smash_hit")
				elif _is_winding_up:
					body_anim.set_anim_state("windup_y")
				else:
					body_anim.set_anim_state("swing_y")
			State.STUNNED:
				body_anim.set_anim_state("idle")

	# Flash visual countdown.
	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0:
			_end_flash()


func _tick_chase(delta: float) -> void:
	# Acquire or re-acquire player reference. Re-check if target went down
	# (Phase 6: invisible; Run 13: downed body — both retrigger retarget).
	if _player == null or not _player.visible or (_player.has_method("is_downed") and _player.is_downed()):
		_find_player()
		if _player == null:
			velocity = _knockback_vel
			move_and_slide()
			return

	var to_player: Vector2 = _player.global_position - global_position
	var dist: float        = to_player.length()

	# Cooldown ticks even while chasing.
	if _attack_timer > 0.0:
		_attack_timer -= delta
	if _smash_cd > 0.0:
		_smash_cd -= delta

	# Run 122 — Nacho secondary: a telegraphed AoE smash when the player is in the
	# mid band and the smash cooldown is ready (LOS-gated like the melee swing).
	if secondary_smash and _smash_cd <= 0.0 and dist <= SMASH_RANGE \
	and EnemyNav.has_line_of_sight(self, global_position, _player.global_position):
		_start_smash()
		velocity = _knockback_vel
		move_and_slide()
		return

	# Trigger attack if close enough, cooldown expired, AND we actually have a
	# clear line to the player (don't swing through a barrier — Run 90).
	if dist <= attack_range and _attack_timer <= 0.0 \
	and EnemyNav.has_line_of_sight(self, global_position, _player.global_position):
		_start_attack()
		velocity = _knockback_vel
		move_and_slide()
		return

	# Run 90 — barrier-aware steering instead of beelining into rocks/slats.
	# Run 17 — Chilled / Cracked Soil reduce MS via StatusComponent.
	var walk_dir: Vector2 = EnemyNav.move_dir(self, _player.global_position, delta) if dist > 1.0 else Vector2.ZERO
	var ms_mult: float = 1.0
	if status:
		ms_mult = status.get_move_speed_mult()
	velocity = walk_dir * move_speed * ms_mult + _knockback_vel
	move_and_slide()


func _tick_attacking(delta: float) -> void:
	# Enemy is planted (only knockback moves it) while executing the attack.
	# Run 17 — Wet/Drenched slow the wind-up & recovery tick proportionally.
	var as_mult: float = 1.0
	if status:
		as_mult = max(0.05, status.get_attack_speed_mult())
	_attack_timer -= delta * as_mult
	velocity = _knockback_vel
	move_and_slide()

	if _is_winding_up and _attack_timer <= 0.0:
		# Wind-up complete → deal damage now (AoE smash vs single bite).
		_is_winding_up = false
		if _is_smashing:
			_deal_smash_damage()
		else:
			_deal_melee_damage()
		_attack_timer = SMASH_RECOVERY if _is_smashing else ATTACK_RECOVERY
		# Return body to base colour if not currently flashing red.
		if _flash_timer <= 0.0:
			FX.clear_body_tint(_body_base)

	elif not _is_winding_up and _attack_timer <= 0.0:
		# Recovery complete → back to chasing with cooldown.
		state = State.CHASE
		_attack_timer = attack_cooldown
		if _is_smashing:
			_is_smashing = false
			_smash_cd = SMASH_COOLDOWN


func _tick_stunned(delta: float) -> void:
	_stun_timer -= delta
	velocity = _knockback_vel
	move_and_slide()
	if _stun_timer <= 0.0:
		state = State.CHASE


# ---------------------------------------------------------------------------
# Attack helpers
# ---------------------------------------------------------------------------

func _start_attack() -> void:
	state           = State.ATTACKING
	_is_winding_up  = true
	_attack_timer   = ATTACK_WINDUP
	# Show orange wind-up tell only if not already red from a player hit.
	if _flash_timer <= 0.0:
		FX.apply_body_tint(_body_base, ATTACK_COLOR, WINDUP_STRENGTH)
	# Run 27 — telegraph: red circle at player position shows the upcoming
	# melee hit zone for the full windup duration so the player can dodge.
	if _player != null:
		FX.spawn_danger_circle(
			_player.global_position,
			attack_range * 1.1,
			Color(1.0, 0.18, 0.08, 0.32),
			ATTACK_WINDUP)


# Run 122 — Nacho secondary smash: long telegraph, then an AoE shockwave centered
# on the golem (self-centered, not aimed at a point) so it punishes crowding it.
func _start_smash() -> void:
	state          = State.ATTACKING
	_is_smashing   = true
	_is_winding_up = true
	_attack_timer  = SMASH_WINDUP
	if _flash_timer <= 0.0:
		FX.apply_body_tint(_body_base, ATTACK_COLOR, WINDUP_STRENGTH)
	# Big red danger circle around the golem for the whole windup = dodge cue.
	FX.spawn_danger_circle(
		global_position,
		SMASH_RADIUS,
		Color(1.0, 0.16, 0.06, 0.30),
		SMASH_WINDUP)


func _deal_smash_damage() -> void:
	# Impact burst + AoE hit to any hero standing inside the ring.
	FX.spawn_burst_particles(global_position, Color(1.0, 0.55, 0.20, 0.9), 16)
	FX.screen_shake(6.0, 0.25)
	for h in get_tree().get_nodes_in_group("player"):
		if not (h is Node2D) or not h.visible:
			continue
		if h.has_method("is_downed") and h.is_downed():
			continue
		if (h as Node2D).global_position.distance_to(global_position) <= SMASH_RADIUS:
			if h.has_method("take_damage"):
				var kdir: Vector2 = ((h as Node2D).global_position - global_position).normalized()
				h.take_damage(attack_damage, kdir * 0.7)
				# Nacho is a burn tank — the shockwave carries its on-hit status too.
				StatusComponent.inflict_hero_status(h, self)
				if on_hit_burn_stacks > 0:
					var shs: StatusComponent = h.get_node_or_null("StatusComponent") as StatusComponent
					if shs:
						shs.apply("burning", on_hit_burn_duration, on_hit_burn_stacks)


func _deal_melee_damage() -> void:
	if _player == null:
		return
	# Run 17 — Slippery/Greased/Burning blind/Sparked/Bolted give the enemy a
	# miss chance via StatusComponent's aggregated get_miss_chance().
	if status:
		var miss: float = status.get_miss_chance()
		if miss > 0.0 and randf() < miss:
			# Visible whiff — small grey burst at the attempted hit point.
			FX.spawn_hit_particles(global_position, Color(0.85, 0.85, 0.85, 0.85), 4)
			return
	# Verify player is still within a generous forgiveness window.
	# (They may have dashed away during wind-up — that's intentional counterplay.)
	var dist: float = (_player.global_position - global_position).length()
	if dist > attack_range * 1.6:
		return
	# Run 23 — Frost Shield (Watermelon + Coconut duo): a Frozen/Chilled
	# attacker deals 15% reduced damage. Reduce on the outgoing side so
	# every receiver (Shino, Bea) gets the discount without touching their
	# take_damage signatures.
	var dmg_out: int = attack_damage
	if status and (status.has("chilled") or status.has("frozen")):
		var fs_red: float = float(RunState.get_frost_shield_reduction())
		if fs_red > 0.0:
			dmg_out = int(round(float(dmg_out) * (1.0 - fs_red)))
			if dmg_out < 1:
				dmg_out = 1
	if _player.has_method("take_damage"):
		# Run 122 — optional bite knockback (Marshmallow Mauler). Push the hero
		# away from the biter; take_damage reads the vector as an impulse.
		if on_hit_knockback:
			var kdir: Vector2 = (_player.global_position - global_position).normalized()
			_player.take_damage(dmg_out, kdir * MELEE_KNOCKBACK)
		else:
			_player.take_damage(dmg_out)
		# Run 120 — sizzling-bite Burn (Churro Chomper). Apply through the player's
		# own StatusComponent so it ticks via the existing burn DoT cadence. Only
		# fires on a bite that actually connected (past the range/miss guards).
		if on_hit_burn_stacks > 0:
			var pstatus: StatusComponent = _player.get_node_or_null("StatusComponent") as StatusComponent
			if pstatus:
				pstatus.apply("burning", on_hit_burn_duration, on_hit_burn_stacks)
			# Run 122 — poison / slow / stun on-hit hooks (generic).
			StatusComponent.inflict_hero_status(_player, self)
			return
		# Run 122 — poison / slow / stun on-hit hooks when there's no burn.
		StatusComponent.inflict_hero_status(_player, self)


# ---------------------------------------------------------------------------
# Receiving damage (called by Player.gd hitboxes, KiBlast, charges, etc.)
# ---------------------------------------------------------------------------

func take_damage(amount: int, knockback_dir: Vector2 = Vector2.ZERO) -> void:
	if state == State.DEAD:
		return

	# Vulnerable amp: +25% per stack via StatusComponent.
	var status_mult: float = 1.0
	if status:
		status_mult = status.get_damage_taken_mult()
	# Run 19 — consolidated target-status damage amps: Rising Tide + Blazing
	# Aura + Wet+Lightning synergy stacked multiplicatively via single helper.
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
	# Run 9 — procedural hit recoil.
	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_anim_state("hit_recoil")

	# Run 49 — knockback vector length acts as a strength scalar (clamped ≤1.0
	# so all existing normalized-vector callers are unchanged). Kunai passes a
	# short vector (0.25) → minimal flinch instead of a full shove.
	var _kb_scale: float = minf(knockback_dir.length(), 1.0)
	# Run 118 — Breakbar hosts (boss/miniboss) are FULLY immune to knockback.
	var _has_breakbar: bool = status != null and status.breakbar_enabled
	if knockback_dir.length() > 0.01:
		if _has_breakbar:
			if not status.is_breakbar_broken():
				status.contribute_breakbar_knockback()
		else:
			_knockback_vel = knockback_dir.normalized() * KNOCKBACK_STRENGTH * _kb_scale

	# CHASE → short stun (breaks pursuit briefly).
	# ATTACKING → super-armor stub: damage applies but attack is NOT interrupted.
	# This matches §8.2.0 note on charge super-armor; we give enemies similar to
	# give them a window of commitment. Revisit in Phase 6 tuning.
	# Run 49 — weak hits (scale < 0.5, e.g. kunai) don't break pursuit.
	if state == State.CHASE and _kb_scale >= 0.5 and not _has_breakbar:
		state       = State.STUNNED
		_stun_timer = stun_duration
		_is_winding_up = false   # cancel any overlap with attack logic

	if current_hp <= 0:
		_die()


# ---------------------------------------------------------------------------
# Visuals
# ---------------------------------------------------------------------------

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


# Run 55 — DoT damage path (poison/burn/bleed). Applies damage WITHOUT the red
# hit-flash so ongoing ticks don't strobe the enemy into a red blob; the status
# auras (purple bubbles / flame) carry the visual. StatusComponent prefers this
# method over take_damage when present.
func apply_status_dot_damage(amount: int, _src_id: String) -> void:
	if state == State.DEAD:
		return
	var dmg: int = max(1, amount)
	current_hp = max(0, current_hp - dmg)
	_refresh_hp_label()
	_spawn_damage_number(dmg)
	if current_hp <= 0:
		_die()

# Run 15 — Tier-3 AI revive helper hook. Returns true while the enemy is in
# its attack windup or actively striking.
func is_attack_imminent() -> bool:
	return _is_winding_up and state != State.DEAD


func _die() -> void:
	state = State.DEAD
	FX.apply_body_tint(_body_base, Color(1.0, 1.0, 1.0, 1.0), 0.85)
	set_physics_process(false)
	# Phase 7 — green burst on dummy death
	FX.spawn_burst_particles(global_position, Color(0.35, 0.85, 0.45, 1.0), 16)
	FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_TINY)
	FX.play_sound("enemy_die")
	# Run 131 — shared on-death boon hook (Juicebox, Wave Crash, Summer's End,
	# Rotten Core, Plague Layer). Inline blocks moved to RunState so every
	# enemy type fires them identically.
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
