extends CharacterBody2D

# ============================================================
# BossEnemy.gd — Shadow Commander (Boss enemy stub, Run 14)
# ============================================================
# 3-phase boss fight with escalating attack patterns:
#
#   Phase 1 (HP > 60%): CHASE + SLAM
#   Phase 2 (HP 30–60%): + CHARGE (telegraphed dash)
#   Phase 3 (HP ≤ 30%): + SHOCKWAVE (radial ring AoE) + speed boost
#
# Attack patterns:
#   SLAM       — 0.8s orange windup → 96px radius AoE stomp at current pos
#   CHARGE     — 0.9s red windup → fast dash across arena, narrow hitbox
#   SHOCKWAVE  — 1.1s magenta windup → expanding ring of damage radiating out
#
# Super armor: during EXECUTING sub-state, hits deal damage but don't interrupt.
# All attacks telegraph clearly per §2.1 Design Philosophy (kid-friendly).
#
# Targeting: compatible with Run 13 revive system — is_downed() always false
# (bosses don't enter DOWNED state; they just die). Enemies skip downed players.
# ============================================================

@export var max_hp: int = 400
@export var move_speed: float = 60.0          # Phase 1 chase speed (px/s)
@export var phase2_speed: float = 80.0        # Phase 2
@export var phase3_speed: float = 110.0       # Phase 3 enrage

# --- Attack damage values ---
const SLAM_DAMAGE: int      = 18
const CHARGE_DAMAGE: int    = 22
const SHOCKWAVE_DAMAGE: int = 14

# --- Attack radii / ranges ---
const SLAM_RADIUS: float    = 96.0    # AoE radius at stomp point
const CHARGE_WIDTH: float   = 36.0   # Half-width of charge hitbox (narrow corridor)
const SHOCKWAVE_EXPAND_SPEED: float = 220.0  # Ring expansion px/s
const SHOCKWAVE_MAX_RADIUS: float   = 380.0  # Ring dies after this radius

# --- Attack timing ---
const SLAM_WINDUP: float      = 0.80
const SLAM_EXECUTE: float     = 0.20
const SLAM_RECOVERY: float    = 0.90

const CHARGE_WINDUP: float    = 0.90
const CHARGE_EXECUTE_SPEED: float = 520.0   # px/s during charge
const CHARGE_RECOVERY: float  = 0.55

const SHOCKWAVE_WINDUP: float   = 1.10
const SHOCKWAVE_LINGER: float   = 0.30      # brief pause after shockwave fires
const SHOCKWAVE_RECOVERY: float = 1.20

# --- Attack cooldowns (phase-dependent) ---
const ATTACK_COOLDOWN_P1: float = 2.8
const ATTACK_COOLDOWN_P2: float = 2.0
const ATTACK_COOLDOWN_P3: float = 1.5

# --- Phase thresholds ---
const PHASE2_HP_PCT: float = 0.60
const PHASE3_HP_PCT: float = 0.30

# --- Visual flash ---
const FLASH_DURATION: float = 0.14
const BASE_COLOR: Color       = Color(1.0,  1.0,  1.0,  0.0)
const HIT_COLOR: Color        = Color(1.0,  0.18, 0.18, 0.5)   # Run 55 — half-alpha red glow (boss stays visible)
const SLAM_TELL_COLOR: Color  = Color(1.0,  0.60, 0.0,  0.85)   # orange
const CHARGE_TELL_COLOR: Color= Color(1.0,  0.15, 0.15, 0.90)   # red
const SHOCKWAVE_TELL_COLOR: Color = Color(0.85, 0.0, 0.95, 0.88) # magenta

# --- Knockback — Run 118: bosses are FULLY immune, kept at zero ---
const KNOCKBACK_STRENGTH: float = 0.0
const KNOCKBACK_FRICTION: float = 8.0
var _knockback_vel: Vector2 = Vector2.ZERO

# --- State machine ---
enum State {
	IDLE,
	CHASE,
	WINDUP,
	EXECUTING,
	RECOVERY,
	DEAD
}
enum AttackType { SLAM, CHARGE, SHOCKWAVE }

var state: State = State.IDLE
var current_phase: int = 1
var current_hp: int
var _attack_timer: float = 0.0
var _attack_cooldown_timer: float = 1.0  # initial delay before first attack
var _pending_attack: AttackType = AttackType.SLAM
var _is_super_armored: bool = false      # true during EXECUTING — hits land but no stagger
var _flash_timer: float = 0.0

# --- Charge state ---
var _charge_dir: Vector2 = Vector2.ZERO
var _charge_speed: float = 0.0
var _charge_hit_set: Dictionary = {}     # de-dupe enemies hit during charge

# --- Shockwave state ---
var _shockwave_active: bool = false
var _shockwave_radius: float = 0.0
var _shockwave_hit_set: Dictionary = {}  # enemies can only be hit once per shockwave

# --- Slam state ---
var _slam_pos: Vector2 = Vector2.ZERO   # position when slam fires (boss may drift slightly)

# --- Damage numbers ---
var _dmg_num_scene: PackedScene = null

# --- Player reference ---
var _player: CharacterBody2D = null

# --- Visual AoE indicator (ColorRect circle proxy — polygon) ---
var _aoe_indicator: Polygon2D = null    # shown during windup to telegraph AoE

# --- StatusComponent (Run 15) — boss carries one so Vulnerable (Shell Breaker)
# can stack on it. Bash is vetoed via can_receive_status (bosses ignore stun).
var status: StatusComponent = null

# --- Nodes ---
@onready var sprite: ColorRect = $Sprite       # full-body flash overlay
@onready var hp_label: Label   = $HPLabel
@onready var name_label: Label = $NameLabel
@onready var body: ColorRect   = $Body         # main visible body rect


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	current_hp = max_hp
	add_to_group("enemy")
	add_to_group("boss")   # Run 15 — HUD boss bar listens for this group
	if sprite:
		sprite.color = BASE_COLOR
	_refresh_hp_label()
	# StatusComponent — required for Coconut Shell Breaker (Vulnerable) and
	# any future de-buff to land on the boss. Bash gets vetoed below via
	# can_receive_status to express the boss's stun-immune super-armor identity.
	status = StatusComponent.new()
	status.name = "StatusComponent"
	add_child(status)
	status.host = self
	if ResourceLoader.exists("res://scenes/DamageNumber.tscn"):
		_dmg_num_scene = load("res://scenes/DamageNumber.tscn")
	# Run 15 — register with FX bus so HUD shows dedicated boss bar.
	if Engine.has_singleton("FX") or has_node("/root/FX"):
		var fx := get_node_or_null("/root/FX")
		if fx and fx.has_method("register_boss"):
			fx.register_boss(self)
			fx.notify_boss_hp(current_hp, max_hp, _display_name())
			fx.notify_boss_phase(current_phase, 3)
	call_deferred("_find_player")


# Display name for HUD bar (strips the phase suffix if name_label has been mutated).
func _display_name() -> String:
	if name_label and not name_label.text.is_empty():
		return name_label.text.replace(" ★★", "").replace(" ★", "")
	return "Shadow Commander"


func _find_player() -> void:
	# Target nearest non-downed player (Run 13 revive-system compatible).
	var players := get_tree().get_nodes_in_group("player")
	var best: CharacterBody2D = null
	var best_dist: float = INF
	for p in players:
		if not p.visible:
			continue
		if p.has_method("is_downed") and p.is_downed():
			continue
		var d: float = global_position.distance_to(p.global_position)
		if d < best_dist:
			best_dist = d
			best = p
	# Also check bea group
	for b in get_tree().get_nodes_in_group("bea"):
		if not b.visible:
			continue
		if b.has_method("is_downed") and b.is_downed():
			continue
		var d: float = global_position.distance_to(b.global_position)
		if d < best_dist:
			best_dist = d
			best = b
	_player = best
	state = State.CHASE


func _physics_process(delta: float) -> void:
	if state == State.DEAD:
		return

	_tick_flash(delta)
	_tick_knockback(delta)
	_tick_shockwave_ring(delta)
	_update_phase()

	# Run 117 — Breakbar broken: freeze AI while movement-locked.
	if status and status.is_movement_locked():
		velocity = _knockback_vel
		move_and_slide()
		return

	match state:
		State.CHASE:
			_tick_chase(delta)
		State.WINDUP:
			_tick_windup(delta)
		State.EXECUTING:
			_tick_executing(delta)
		State.RECOVERY:
			_tick_recovery(delta)


# ---------------------------------------------------------------------------
# Phase management
# ---------------------------------------------------------------------------

func _update_phase() -> void:
	var hp_pct: float = float(current_hp) / float(max_hp)
	var new_phase: int = 1
	if hp_pct <= PHASE3_HP_PCT:
		new_phase = 3
	elif hp_pct <= PHASE2_HP_PCT:
		new_phase = 2

	if new_phase != current_phase:
		current_phase = new_phase
		_on_phase_change(new_phase)


func _on_phase_change(phase: int) -> void:
	Log.dbg("[Boss] Entering Phase %d!" % phase)
	# Run 15 — phase change broadcast (HUD bar may recolor per phase)
	var fx_p := get_node_or_null("/root/FX")
	if fx_p and fx_p.has_method("notify_boss_phase"):
		fx_p.notify_boss_phase(phase, 3)
	# Visual flash to telegraph phase change
	_trigger_flash(SLAM_TELL_COLOR if phase == 2 else SHOCKWAVE_TELL_COLOR, 0.35)
	if phase == 2:
		name_label.text = "Shadow Commander ★"
		name_label.modulate = Color(1.0, 0.5, 0.0)
		if body:
			body.color = Color(0.45, 0.12, 0.55, 1.0)   # darker purple — Phase 2
	elif phase == 3:
		name_label.text = "Shadow Commander ★★"
		name_label.modulate = Color(1.0, 0.15, 0.15)
		if body:
			body.color = Color(0.65, 0.04, 0.04, 1.0)   # blood red — Phase 3 enrage
	# Reset cooldown so the new phase attack comes faster
	_attack_cooldown_timer = 0.3


# ---------------------------------------------------------------------------
# Chase state
# ---------------------------------------------------------------------------

func _tick_chase(delta: float) -> void:
	# Retarget to nearest non-downed player periodically
	if randf() < 0.01:  # ~1% per frame ≈ retarget roughly every 1.7s
		_find_player()
	if _player == null:
		_find_player()
		return

	var dir: Vector2 = ((_player.global_position) - global_position).normalized()
	var speed: float = move_speed
	if current_phase == 2:
		speed = phase2_speed
	elif current_phase == 3:
		speed = phase3_speed
	# Run 17 — Chilled stacks still slow the boss (only the cap-state Frozen
	# is vetoed via can_receive_status). Cracked Soil and any future MS-debuff
	# also flow through the aggregate.
	if status:
		speed *= status.get_move_speed_mult()

	velocity = dir * speed + _knockback_vel
	move_and_slide()

	# Attack cooldown ticks down during chase
	_attack_cooldown_timer -= delta
	if _attack_cooldown_timer <= 0.0:
		_pick_and_start_windup()


# ---------------------------------------------------------------------------
# Attack selection
# ---------------------------------------------------------------------------

func _pick_and_start_windup() -> void:
	# Choose attack based on phase capabilities
	var options: Array = [AttackType.SLAM]
	if current_phase >= 2:
		options.append(AttackType.CHARGE)
	if current_phase >= 3:
		options.append(AttackType.SHOCKWAVE)

	_pending_attack = options[randi() % options.size()]
	state = State.WINDUP
	_attack_timer = _windup_for(_pending_attack)
	_show_aoe_indicator(_pending_attack)
	_trigger_flash(_tell_color_for(_pending_attack), _attack_timer)
	Log.dbg("[Boss] Starting windup: %s (phase %d)" % [AttackType.keys()[_pending_attack], current_phase])


func _windup_for(a: AttackType) -> float:
	match a:
		AttackType.SLAM: return SLAM_WINDUP
		AttackType.CHARGE: return CHARGE_WINDUP
		AttackType.SHOCKWAVE: return SHOCKWAVE_WINDUP
	return 0.8


func _tell_color_for(a: AttackType) -> Color:
	match a:
		AttackType.SLAM: return SLAM_TELL_COLOR
		AttackType.CHARGE: return CHARGE_TELL_COLOR
		AttackType.SHOCKWAVE: return SHOCKWAVE_TELL_COLOR
	return SLAM_TELL_COLOR


# ---------------------------------------------------------------------------
# Windup
# ---------------------------------------------------------------------------

func _tick_windup(delta: float) -> void:
	# Boss slows during windup (committed — can't be canceled by player hits
	# but IS still moveable by knockback slightly)
	velocity = _knockback_vel * 0.25
	move_and_slide()

	_attack_timer -= delta
	if _attack_timer <= 0.0:
		_hide_aoe_indicator()
		_execute_attack()


# ---------------------------------------------------------------------------
# Execute
# ---------------------------------------------------------------------------

func _execute_attack() -> void:
	state = State.EXECUTING
	_is_super_armored = true  # hits land but no stagger during execution

	match _pending_attack:
		AttackType.SLAM:
			_attack_timer = SLAM_EXECUTE
			_slam_pos = global_position
			# Deal immediate AoE damage
			_do_slam()

		AttackType.CHARGE:
			if _player != null:
				_charge_dir = ((_player.global_position) - global_position).normalized()
			else:
				_charge_dir = Vector2.RIGHT
			_charge_speed = CHARGE_EXECUTE_SPEED
			_attack_timer = 0.50   # max charge duration; stops early on wall
			_charge_hit_set.clear()

		AttackType.SHOCKWAVE:
			_attack_timer = SHOCKWAVE_LINGER
			_shockwave_active = true
			_shockwave_radius = 0.0
			_shockwave_hit_set.clear()


func _tick_executing(delta: float) -> void:
	match _pending_attack:
		AttackType.SLAM:
			_attack_timer -= delta
			velocity = _knockback_vel * 0.1
			move_and_slide()
			if _attack_timer <= 0.0:
				state = State.RECOVERY
				_attack_timer = SLAM_RECOVERY
				_is_super_armored = false

		AttackType.CHARGE:
			velocity = _charge_dir * _charge_speed + _knockback_vel
			var collision := move_and_slide()
			# Deal damage to all players in the narrow corridor
			_do_charge_hit()
			_attack_timer -= delta
			# Stop on wall collision or timer
			var hit_wall: bool = (get_slide_collision_count() > 0)
			if hit_wall or _attack_timer <= 0.0:
				state = State.RECOVERY
				_attack_timer = CHARGE_RECOVERY
				_is_super_armored = false
				_charge_speed = 0.0

		AttackType.SHOCKWAVE:
			velocity = _knockback_vel * 0.1
			move_and_slide()
			_attack_timer -= delta
			if _attack_timer <= 0.0:
				state = State.RECOVERY
				_attack_timer = SHOCKWAVE_RECOVERY
				_is_super_armored = false
				# shockwave ring continues expanding via _tick_shockwave_ring


# ---------------------------------------------------------------------------
# Recovery
# ---------------------------------------------------------------------------

func _tick_recovery(delta: float) -> void:
	velocity = _knockback_vel * 0.5
	move_and_slide()
	_attack_timer -= delta
	if _attack_timer <= 0.0:
		state = State.CHASE
		var cd: float = ATTACK_COOLDOWN_P1
		if current_phase == 2:
			cd = ATTACK_COOLDOWN_P2
		elif current_phase == 3:
			cd = ATTACK_COOLDOWN_P3
		_attack_cooldown_timer = cd


# ---------------------------------------------------------------------------
# Slam attack
# ---------------------------------------------------------------------------

# Run 23 — Frost Shield (Watermelon + Coconut duo): chilled/frozen attacker
# deals 15% less damage. Applied on outgoing side here so receiver
# take_damage signatures don't need to change.
func _frost_shield_adjust(base_dmg: int) -> int:
	if not status:
		return base_dmg
	if not (status.has("chilled") or status.has("frozen")):
		return base_dmg
	var fs_red: float = float(RunState.get_frost_shield_reduction())
	if fs_red <= 0.0:
		return base_dmg
	var out: int = int(round(float(base_dmg) * (1.0 - fs_red)))
	return max(1, out)


func _do_slam() -> void:
	# Damage all player-group characters within SLAM_RADIUS
	var targets: Array = []
	targets.append_array(get_tree().get_nodes_in_group("player"))
	targets.append_array(get_tree().get_nodes_in_group("bea"))
	var slam_out: int = _frost_shield_adjust(SLAM_DAMAGE)
	for t in targets:
		if not t.visible:
			continue
		if t.has_method("is_downed") and t.is_downed():
			continue
		if global_position.distance_to(t.global_position) <= SLAM_RADIUS:
			if t.has_method("take_damage"):
				t.take_damage(slam_out)
	# Visual: heavy screen shake
	if has_node("/root/FX"):
		get_node("/root/FX").screen_shake(10.0, 0.30)
	_spawn_slam_particles()
	Log.dbg("[Boss] SLAM fired at %s — %dpx radius" % [str(_slam_pos), SLAM_RADIUS])


# ---------------------------------------------------------------------------
# Charge attack hit
# ---------------------------------------------------------------------------

func _do_charge_hit() -> void:
	# Narrow corridor perpendicular to charge direction
	var targets: Array = []
	targets.append_array(get_tree().get_nodes_in_group("player"))
	targets.append_array(get_tree().get_nodes_in_group("bea"))
	for t in targets:
		if not t.visible:
			continue
		if t.has_method("is_downed") and t.is_downed():
			continue
		if t in _charge_hit_set:
			continue
		# Project target onto charge perpendicular
		var to_target: Vector2 = t.global_position - global_position
		var perp: Vector2 = _charge_dir.orthogonal()
		var side_dist: float = abs(to_target.dot(perp))
		var fwd_dist: float = to_target.dot(_charge_dir)
		if side_dist <= CHARGE_WIDTH and fwd_dist >= -24.0 and fwd_dist <= 48.0:
			_charge_hit_set[t] = true
			if t.has_method("take_damage"):
				t.take_damage(_frost_shield_adjust(CHARGE_DAMAGE))


# ---------------------------------------------------------------------------
# Shockwave ring (ticks every frame while active)
# ---------------------------------------------------------------------------

func _tick_shockwave_ring(delta: float) -> void:
	if not _shockwave_active:
		return
	_shockwave_radius += SHOCKWAVE_EXPAND_SPEED * delta
	# Damage players the ring passes through (thin ring = 28px band)
	var ring_inner: float = max(0.0, _shockwave_radius - 28.0)
	var ring_outer: float = _shockwave_radius
	var targets: Array = []
	targets.append_array(get_tree().get_nodes_in_group("player"))
	targets.append_array(get_tree().get_nodes_in_group("bea"))
	for t in targets:
		if not t.visible:
			continue
		if t.has_method("is_downed") and t.is_downed():
			continue
		if t in _shockwave_hit_set:
			continue
		var dist: float = global_position.distance_to(t.global_position)
		if dist >= ring_inner and dist <= ring_outer:
			_shockwave_hit_set[t] = true
			if t.has_method("take_damage"):
				t.take_damage(_frost_shield_adjust(SHOCKWAVE_DAMAGE))
	if _shockwave_radius >= SHOCKWAVE_MAX_RADIUS:
		_shockwave_active = false
		_shockwave_radius = 0.0


# ---------------------------------------------------------------------------
# Take damage (called by player attack hitboxes)
# ---------------------------------------------------------------------------

func take_damage(amount: int, source_pos: Vector2 = Vector2.ZERO) -> void:
	if state == State.DEAD:
		return

	# Vulnerable (Shell Breaker) — amp incoming damage by StatusComponent stacks.
	# get_damage_taken_mult returns 1.0 when no amps active, so the math is a no-op
	# in the common case.
	var status_mult: float = 1.0
	if status:
		status_mult = status.get_damage_taken_mult()
	# Run 19 — consolidated target-status damage amps (Rising Tide + Blazing
	# Aura + Wet+Lightning synergy) — also affects the boss (boss vetoes only
	# stun-side statuses via can_receive_status; damage-amp statuses pass).
	status_mult *= RunState.get_target_status_damage_mult(status)
	# Run 23 — Pepper+Potato "Spicy Landmine": Burning+Rooted enemies take +30% damage.
	if status and RunState.pepper_potato_active():
		if status.has("burning") and status.has("root"):
			status_mult *= (1.0 + RunState.get_pepper_potato_amp())
	# Run 24 — Potato+Watermelon "Mud Tide": Wet+Rooted enemies take +25% damage.
	if status and RunState.potato_watermelon_active():
		if (status.is_wet() or status.is_frostbitten()) and status.has("root"):
			status_mult *= (1.0 + RunState.get_potato_watermelon_amp())
	var final_amount: int = int(round(amount * status_mult))
	if final_amount < 1 and amount > 0:
		final_amount = 1

	current_hp = max(0, current_hp - final_amount)
	_refresh_hp_label()
	_trigger_flash(HIT_COLOR, FLASH_DURATION)
	_spawn_damage_number(final_amount)
	# Run 15 — broadcast HP to HUD's dedicated boss bar.
	var fx_dmg := get_node_or_null("/root/FX")
	if fx_dmg and fx_dmg.has_method("notify_boss_hp"):
		fx_dmg.notify_boss_hp(current_hp, max_hp, _display_name())

	# Run 118 — Bosses are FULLY immune to knockback. Hits contribute to
	# breakbar but never push the boss. No displacement, ever.
	if source_pos != Vector2.ZERO and status and status.breakbar_enabled:
		if not status.is_breakbar_broken():
			status.contribute_breakbar_knockback()

	if current_hp <= 0:
		_die()


# Run 55 — DoT damage path (poison/burn/bleed): no red flash, so sustained
# ticks don't keep the boss tinted red; the status auras carry the visual.
func apply_status_dot_damage(amount: int, _src_id: String) -> void:
	if state == State.DEAD:
		return
	var dmg: int = max(1, amount)
	current_hp = max(0, current_hp - dmg)
	_refresh_hp_label()
	_spawn_damage_number(dmg)
	var fx_dmg := get_node_or_null("/root/FX")
	if fx_dmg and fx_dmg.has_method("notify_boss_hp"):
		fx_dmg.notify_boss_hp(current_hp, max_hp, _display_name())
	if current_hp <= 0:
		_die()


func _exit_tree() -> void:
	# Defensive — if the boss is freed mid-fight (e.g. scene change), ensure
	# the HUD bar hides instead of getting stuck.
	var fx_e := get_node_or_null("/root/FX")
	if fx_e and fx_e.has_method("unregister_boss"):
		fx_e.unregister_boss(self)


# Run 15 — Tier-3 AI revive helper hook. Boss windup AND executing both
# count as "attack imminent" because the windup-into-execution arc is the
# danger window for someone standing still channeling.
func is_attack_imminent() -> bool:
	return state == State.WINDUP or state == State.EXECUTING


# Run 117 — Breakbar replaces the old hard CC veto. StatusComponent now
# handles CC interception via the breakbar system. can_receive_status only
# blocks statuses that should NEVER land even when the bar is broken.
# All CC (bash/frozen/root/stagger) is routed through breakbar contribution
# in StatusComponent.apply, not blocked here.
func can_receive_status(_id: String) -> bool:
	return true


func is_downed() -> bool:
	# Bosses never enter DOWNED state (no revive mechanic for them).
	# Returns false always so player targeting/revive code treats boss
	# as always "alive" until DEAD.
	return false


# ---------------------------------------------------------------------------
# Death
# ---------------------------------------------------------------------------

func _die() -> void:
	state = State.DEAD
	# Run 131 — shared on-death boon hook (Juicebox, Wave Crash, Summer's End,
	# Rotten Core, Plague Layer).
	RunState.process_enemy_death_boons(self)
	_shockwave_active = false
	_hide_aoe_indicator()
	# Run 15 — unregister from FX bus so HUD hides the boss bar.
	var fx_d := get_node_or_null("/root/FX")
	if fx_d and fx_d.has_method("unregister_boss"):
		fx_d.unregister_boss(self)
	# White death flash
	if sprite:
		sprite.color = Color(1.0, 1.0, 1.0, 1.0)
	if body:
		body.color = Color(1.0, 1.0, 1.0, 1.0)
	if has_node("/root/FX"):
		get_node("/root/FX").screen_shake(14.0, 0.45)
	_spawn_death_particles()
	Log.dbg("[Boss] DEFEATED! Final HP: %d / %d" % [current_hp, max_hp])
	# Brief pause before freeing so the death flash reads
	get_tree().create_timer(0.45).timeout.connect(func(): queue_free())


# ---------------------------------------------------------------------------
# Knockback tick
# ---------------------------------------------------------------------------

func _tick_knockback(delta: float) -> void:
	_knockback_vel = _knockback_vel.lerp(Vector2.ZERO, KNOCKBACK_FRICTION * delta)


# ---------------------------------------------------------------------------
# Flash
# ---------------------------------------------------------------------------

func _trigger_flash(color: Color, duration: float) -> void:
	if sprite:
		sprite.color = color
	_flash_timer = duration


func _tick_flash(delta: float) -> void:
	if _flash_timer <= 0.0:
		return
	_flash_timer -= delta
	if _flash_timer <= 0.0 and sprite:
		sprite.color = BASE_COLOR


# ---------------------------------------------------------------------------
# AoE indicator (simple Polygon2D circle drawn during windup)
# ---------------------------------------------------------------------------

func _show_aoe_indicator(attack: AttackType) -> void:
	_hide_aoe_indicator()
	match attack:
		AttackType.SLAM:
			_aoe_indicator = _make_circle_indicator(SLAM_RADIUS, Color(1.0, 0.08, 0.06, 0.22))
			# Run 27 — supplemental FX telegraph (brighter, fades over windup)
			FX.spawn_danger_circle(
				global_position,
				SLAM_RADIUS,
				Color(1.0, 0.08, 0.06, 0.38),
				SLAM_WINDUP)
		AttackType.SHOCKWAVE:
			# Shockwave: ring preview — outer radius is the max reach
			_aoe_indicator = _make_circle_indicator(SHOCKWAVE_MAX_RADIUS * 0.5, Color(0.85, 0.0, 0.95, 0.15))
			# Run 27 — supplemental FX telegraph
			FX.spawn_danger_circle(
				global_position,
				SHOCKWAVE_MAX_RADIUS,
				Color(0.80, 0.0, 1.0, 0.28),
				SHOCKWAVE_WINDUP)
		AttackType.CHARGE:
			# Charge: a long rectangle in the aimed direction
			_aoe_indicator = _make_charge_indicator()
			# Run 27 — supplemental FX beam telegraph along charge corridor
			if _player != null:
				var ch_dir: Vector2 = (_player.global_position - global_position).normalized()
				FX.spawn_danger_beam(
					global_position,
					ch_dir,
					700.0,
					float(CHARGE_WIDTH),
					Color(1.0, 0.10, 0.10, 0.30),
					CHARGE_WINDUP)


func _hide_aoe_indicator() -> void:
	if _aoe_indicator != null and is_instance_valid(_aoe_indicator):
		_aoe_indicator.queue_free()
	_aoe_indicator = null


func _make_circle_indicator(radius: float, color: Color) -> Polygon2D:
	var poly := Polygon2D.new()
	poly.color = color
	var pts: PackedVector2Array = PackedVector2Array()
	var steps: int = 24
	for i in steps:
		var ang: float = TAU * i / steps
		pts.append(Vector2(cos(ang) * radius, sin(ang) * radius))
	poly.polygon = pts
	add_child(poly)
	return poly


func _make_charge_indicator() -> Polygon2D:
	if _player == null:
		return null
	var dir: Vector2 = ((_player.global_position) - global_position).normalized()
	var perp: Vector2 = dir.orthogonal()
	var length: float = 600.0  # full arena width approximation
	var poly := Polygon2D.new()
	poly.color = Color(1.0, 0.15, 0.15, 0.18)
	var pts := PackedVector2Array()
	pts.append(-perp * CHARGE_WIDTH)
	pts.append( perp * CHARGE_WIDTH)
	pts.append( perp * CHARGE_WIDTH + dir * length)
	pts.append(-perp * CHARGE_WIDTH + dir * length)
	poly.polygon = pts
	add_child(poly)
	return poly


# ---------------------------------------------------------------------------
# Particles & damage numbers (placeholder using FX autoload)
# ---------------------------------------------------------------------------

func _spawn_slam_particles() -> void:
	if not has_node("/root/FX"):
		return
	# Run 26c — FX.gd exposes spawn_hit_particles(pos, color, count, parent),
	# not spawn_particles(pos, count, color). Fix the call name + arg order so
	# the boss slam doesn't crash the boss arena on first slam.
	FX.spawn_hit_particles(global_position, Color(1.0, 0.55, 0.0), 20)


func _spawn_death_particles() -> void:
	if not has_node("/root/FX"):
		return
	# Same fix — see _spawn_slam_particles above.
	FX.spawn_burst_particles(global_position, Color(0.55, 0.0, 0.65), 32)


func _spawn_damage_number(amount: int) -> void:
	if _dmg_num_scene == null:
		return
	var dn = _dmg_num_scene.instantiate()
	get_parent().add_child(dn)
	dn.global_position = global_position + Vector2(randf_range(-14, 14), -40)
	if dn.has_method("show_damage"):
		dn.show_damage(amount)


# ---------------------------------------------------------------------------
# HP label refresh
# ---------------------------------------------------------------------------

func _refresh_hp_label() -> void:
	if hp_label:
		hp_label.text = "%d / %d" % [current_hp, max_hp]
