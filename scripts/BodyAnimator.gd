class_name BodyAnimator
extends Node2D
# ============================================================
# BodyAnimator.gd — procedural stick-figure animation rig
# ============================================================
# Attach to the $Body Node2D of any entity (Player, Bea, DummyEnemy,
# RangedShooter, FastScout). It locates the standard part children
# (Head, Torso, ArmL, ArmR, LegL, LegR) and animates them via sine
# offsets + light tweens — no AnimationPlayer needed.
#
# Host script calls:
#   body.set_anim_state("idle" | "walking" | "windup_y" | "windup_x"
#                        | "windup_a" | "swing_y" | "swing_x"
#                        | "swing_a" | "hit_recoil" | "death")
#   body.set_motion_speed(speed_value)   # used to scale walk cadence
#
# State semantics:
#   "idle"        — subtle torso bob 1-2px
#   "walking"     — limbs swing opposite-phase + body bob
#   "windup_y"    — arms cocked back (Punch Flurry pose)
#   "windup_x"    — one leg raised (Crane Kick pose)
#   "windup_a"    — both arms drawn back to hip (Kamehameha pose)
#   "swing_y"     — arm thrust forward (tap-combo)
#   "swing_x"     — arms sweep wide (tap-combo)
#   "swing_a"     — arms thrust forward (Kamehameha fire)
#   "hit_recoil"  — brief lean-back + arms splay
#   "death"       — body tips over (rotate ~90°) + fade
#
# Lightweight: per-frame work is two sin() calls + maybe one tween.
# ============================================================

# --- Body part refs (resolved in _ready) ---
# Typed as Node so we can hold either Node2D or Control (ColorRect) children.
# All parts in our placeholder rigs are ColorRect — `.position` works the same
# on both, which is all we touch here.
var head: Node = null
var torso: Node = null
var arm_l: Node = null
var arm_r: Node = null
var leg_l: Node = null
var leg_r: Node = null
var facing_marker: Node = null
var head_outline: Node = null
var hair_detail: Node = null   # Bea-only
var staff: Node = null         # RangedShooter-only
var staff_tip: Node = null     # RangedShooter-only

# --- Original positions/rotations captured at _ready, used as base offsets ---
var _base_pos: Dictionary = {}     # part_node -> Vector2 (original position)
var _base_rot: Dictionary = {}     # part_node -> float

# --- State ---
var _state: String = "idle"
var _walk_phase: float = 0.0       # advances when walking
var _idle_phase: float = 0.0       # advances always (idle bob)
var _motion_speed: float = 0.0     # tracks host velocity magnitude

# --- Tweens for one-shot poses ---
var _pose_tween: Tween = null
var _death_tween: Tween = null

# --- Pose lock: prevents host's per-frame walking/idle calls from
# clobbering a one-shot pose (swing/hit_recoil) before its tween completes.
# Death is locked forever (entity is being freed anyway).
var _pose_lock_timer: float = 0.0

# --- Tunables ---
const WALK_CADENCE: float       = 9.0    # rad/s — controls swing rate
const WALK_LIMB_AMPLITUDE: float = 3.0   # px swing amplitude on legs/arms
const WALK_BODY_BOB_AMP: float  = 1.5    # px torso/head bob amplitude
const IDLE_BOB_RATE: float      = 2.4    # rad/s slow idle breathing
const IDLE_BOB_AMP: float       = 1.0    # px subtle idle bob
const SWING_DURATION: float     = 0.18   # arm-thrust tween length
const RECOIL_DURATION: float    = 0.18   # hit-recoil tween length


func _ready() -> void:
	_resolve_parts()
	_capture_base_transforms()
	set_process(true)


func _resolve_parts() -> void:
	head          = get_node_or_null("Head")
	torso         = get_node_or_null("Torso")
	arm_l         = get_node_or_null("ArmL")
	arm_r         = get_node_or_null("ArmR")
	leg_l         = get_node_or_null("LegL")
	leg_r         = get_node_or_null("LegR")
	facing_marker = get_node_or_null("FacingMarker")
	head_outline  = get_node_or_null("HeadOutline")
	hair_detail   = get_node_or_null("HairDetail")
	staff         = get_node_or_null("Staff")
	staff_tip     = get_node_or_null("StaffTip")


func _capture_base_transforms() -> void:
	# Note: ColorRect children store layout via offset_*; we treat their
	# transform .position (Node2D-style) as zero relative to that layout.
	# When we add walk/swing offsets we set .position, which is rendered on
	# top of the offset_* layout — clean separation.
	for part in [head, torso, arm_l, arm_r, leg_l, leg_r, facing_marker,
				 head_outline, hair_detail, staff, staff_tip]:
		if part != null:
			_base_pos[part] = part.position
			_base_rot[part] = part.rotation


# -------------------------------------------------------
# Public API
# -------------------------------------------------------
func set_anim_state(s: String) -> void:
	# Revive recovery: if currently in death state, any transition out MUST
	# clear the death visual (fade + tip-over) before the lock check runs.
	# Without this, _pose_lock_timer=999 blocks "idle" calls from revive_from_partner()
	# and the ninja body stays invisible and rotated on the floor.
	if _state == "death":
		if _death_tween and _death_tween.is_valid():
			_death_tween.kill()
		_death_tween = null
		_pose_lock_timer = 0.0
		self.rotation = 0.0
		self.modulate.a = 1.0
		# Snap all parts back to base immediately (no tween — instant on revive).
		for part in [head, torso, arm_l, arm_r, leg_l, leg_r,
		             head_outline, hair_detail, facing_marker]:
			if part != null:
				part.position = _base_pos.get(part, Vector2.ZERO)
				part.rotation  = _base_rot.get(part, 0.0)

	# Pose lock: while a one-shot pose tween is playing, ignore attempts to
	# revert to walking/idle (host calls these from per-frame velocity check).
	if _pose_lock_timer > 0.0 and (s == "walking" or s == "idle"):
		return
	if s == _state:
		return
	_state = s
	# Reset any per-state continuous offsets when leaving walking
	if s != "walking":
		_walk_phase = 0.0
	# Trigger one-shot tween poses on state-entry
	match s:
		"swing_y":
			_pose_lock_timer = SWING_DURATION
			_play_swing_pose("y")
		"swing_x":
			_pose_lock_timer = SWING_DURATION
			_play_swing_pose("x")
		"swing_a":
			_pose_lock_timer = SWING_DURATION
			_play_swing_pose("a")
		"hit_recoil":
			_pose_lock_timer = RECOIL_DURATION
			_play_hit_recoil()
		"death":
			_pose_lock_timer = 999.0   # locked indefinitely
			_play_death()
		"windup_y":
			_set_static_pose("windup_y")
		"windup_x":
			_set_static_pose("windup_x")
		"windup_a":
			_set_static_pose("windup_a")
		"idle":
			_reset_static_pose()
		"walking":
			_reset_static_pose()


func set_motion_speed(speed: float) -> void:
	_motion_speed = speed


# -------------------------------------------------------
# Per-frame procedural animation
# -------------------------------------------------------
func _process(delta: float) -> void:
	_idle_phase += delta * IDLE_BOB_RATE
	if _pose_lock_timer > 0.0:
		_pose_lock_timer -= delta
	if _state == "walking":
		# Cadence scales with motion speed so faster movement → faster swing.
		var rate: float = WALK_CADENCE * clamp(_motion_speed / 220.0, 0.6, 1.6)
		_walk_phase += delta * rate
		_apply_walk_offsets()
	elif _state == "idle":
		_apply_idle_offsets()
	# Other states (windup_*, swing_*, hit_recoil, death) are tween-driven or
	# static — no per-frame work needed.


func _apply_walk_offsets() -> void:
	# Legs alternate phase: LegL = +sin, LegR = -sin.
	# Arms swing OPPOSITE to legs for natural gait.
	var s: float = sin(_walk_phase)
	var amp: float = WALK_LIMB_AMPLITUDE
	if leg_l:
		leg_l.position = _base_pos[leg_l] + Vector2(0.0,  s * amp)
	if leg_r:
		leg_r.position = _base_pos[leg_r] + Vector2(0.0, -s * amp)
	if arm_l:
		arm_l.position = _base_pos[arm_l] + Vector2(0.0, -s * amp * 0.7)
	if arm_r:
		arm_r.position = _base_pos[arm_r] + Vector2(0.0,  s * amp * 0.7)
	# Torso + head bob at 2× cadence (each step bobs body) and lower amplitude.
	var bob: float = abs(sin(_walk_phase * 0.5)) * WALK_BODY_BOB_AMP
	if torso:
		torso.position = _base_pos[torso] + Vector2(0.0, -bob)
	if head:
		head.position = _base_pos[head] + Vector2(0.0, -bob)
	if head_outline:
		head_outline.position = _base_pos[head_outline] + Vector2(0.0, -bob)
	if hair_detail:
		hair_detail.position = _base_pos[hair_detail] + Vector2(0.0, -bob)


func _apply_idle_offsets() -> void:
	# Subtle breathing — head/torso rise and fall slightly.
	var b: float = sin(_idle_phase) * IDLE_BOB_AMP
	if torso:
		torso.position = _base_pos[torso] + Vector2(0.0, b * 0.4)
	if head:
		head.position = _base_pos[head] + Vector2(0.0, b)
	if head_outline:
		head_outline.position = _base_pos[head_outline] + Vector2(0.0, b)
	if hair_detail:
		hair_detail.position = _base_pos[hair_detail] + Vector2(0.0, b)
	# Reset limbs to base when idle.
	for p in [leg_l, leg_r, arm_l, arm_r]:
		if p != null:
			p.position = _base_pos[p]


# -------------------------------------------------------
# Pose tweens
# -------------------------------------------------------
func _kill_pose_tween() -> void:
	if _pose_tween and _pose_tween.is_valid():
		_pose_tween.kill()
	_pose_tween = null


func _reset_static_pose() -> void:
	# Bring all parts back to base after a windup/recoil pose.
	_kill_pose_tween()
	_pose_tween = create_tween()
	_pose_tween.set_parallel(true)
	for part in [head, torso, arm_l, arm_r, leg_l, leg_r, head_outline, hair_detail]:
		if part != null:
			_pose_tween.tween_property(part, "position", _base_pos[part], 0.08)
			_pose_tween.tween_property(part, "rotation", _base_rot[part], 0.08)


func _set_static_pose(pose: String) -> void:
	# Snap into a held pose for the duration of the wind-up.
	# Player/Bea call set_anim_state("idle") after release to clean up.
	_kill_pose_tween()
	_pose_tween = create_tween()
	_pose_tween.set_parallel(true)
	match pose:
		"windup_y":
			# Punch Flurry: arms cocked back (positive y offset = down/back in
			# screen-space, but we just want a visible "wound up" look).
			if arm_l:
				_pose_tween.tween_property(arm_l, "position", _base_pos[arm_l] + Vector2(-1, 3), 0.12)
			if arm_r:
				_pose_tween.tween_property(arm_r, "position", _base_pos[arm_r] + Vector2(1, 3), 0.12)
			if torso:
				_pose_tween.tween_property(torso, "position", _base_pos[torso] + Vector2(0, 1), 0.12)
		"windup_x":
			# Crane Kick: one leg raised, arms out.
			if leg_l:
				_pose_tween.tween_property(leg_l, "position", _base_pos[leg_l] + Vector2(-2, -5), 0.14)
			if arm_l:
				_pose_tween.tween_property(arm_l, "position", _base_pos[arm_l] + Vector2(-3, -1), 0.12)
			if arm_r:
				_pose_tween.tween_property(arm_r, "position", _base_pos[arm_r] + Vector2(3, -1), 0.12)
		"windup_a":
			# Kamehameha: arms drawn back to hip.
			if arm_l:
				_pose_tween.tween_property(arm_l, "position", _base_pos[arm_l] + Vector2(3, 2), 0.18)
			if arm_r:
				_pose_tween.tween_property(arm_r, "position", _base_pos[arm_r] + Vector2(-3, 2), 0.18)
			if torso:
				_pose_tween.tween_property(torso, "position", _base_pos[torso] + Vector2(0, 1), 0.12)


func _play_swing_pose(kind: String) -> void:
	# Brief arm-thrust forward, then auto-return to base.
	_kill_pose_tween()
	_pose_tween = create_tween()
	_pose_tween.set_parallel(true)
	match kind:
		"y":
			# Single dominant arm thrust (right arm forward visually = up in offset terms).
			if arm_r:
				_pose_tween.tween_property(arm_r, "position", _base_pos[arm_r] + Vector2(2, -3), SWING_DURATION * 0.5)
				_pose_tween.chain().tween_property(arm_r, "position", _base_pos[arm_r], SWING_DURATION * 0.5)
		"x":
			# Both arms sweep outward.
			if arm_l:
				_pose_tween.tween_property(arm_l, "position", _base_pos[arm_l] + Vector2(-4, 0), SWING_DURATION * 0.5)
				_pose_tween.chain().tween_property(arm_l, "position", _base_pos[arm_l], SWING_DURATION * 0.5)
			if arm_r:
				var t2: Tween = create_tween()
				t2.tween_property(arm_r, "position", _base_pos[arm_r] + Vector2(4, 0), SWING_DURATION * 0.5)
				t2.tween_property(arm_r, "position", _base_pos[arm_r], SWING_DURATION * 0.5)
		"a":
			# Kamehameha-thrust: both arms forward (visually upward — north of body).
			if arm_l:
				_pose_tween.tween_property(arm_l, "position", _base_pos[arm_l] + Vector2(-1, -4), SWING_DURATION * 0.4)
				_pose_tween.chain().tween_property(arm_l, "position", _base_pos[arm_l], SWING_DURATION * 0.6)
			if arm_r:
				var t3: Tween = create_tween()
				t3.tween_property(arm_r, "position", _base_pos[arm_r] + Vector2(1, -4), SWING_DURATION * 0.4)
				t3.tween_property(arm_r, "position", _base_pos[arm_r], SWING_DURATION * 0.6)


func _play_hit_recoil() -> void:
	# Brief lean back: torso/head shift, arms splay.
	_kill_pose_tween()
	_pose_tween = create_tween()
	_pose_tween.set_parallel(true)
	if torso:
		_pose_tween.tween_property(torso, "position", _base_pos[torso] + Vector2(0, 2), RECOIL_DURATION * 0.5)
		_pose_tween.chain().tween_property(torso, "position", _base_pos[torso], RECOIL_DURATION * 0.5)
	if head:
		var t_h: Tween = create_tween()
		t_h.tween_property(head, "position", _base_pos[head] + Vector2(0, 2), RECOIL_DURATION * 0.5)
		t_h.tween_property(head, "position", _base_pos[head], RECOIL_DURATION * 0.5)
	if arm_l:
		var t_al: Tween = create_tween()
		t_al.tween_property(arm_l, "position", _base_pos[arm_l] + Vector2(-3, 0), RECOIL_DURATION * 0.4)
		t_al.tween_property(arm_l, "position", _base_pos[arm_l], RECOIL_DURATION * 0.6)
	if arm_r:
		var t_ar: Tween = create_tween()
		t_ar.tween_property(arm_r, "position", _base_pos[arm_r] + Vector2(3, 0), RECOIL_DURATION * 0.4)
		t_ar.tween_property(arm_r, "position", _base_pos[arm_r], RECOIL_DURATION * 0.6)


func _play_death() -> void:
	# Body tips over (rotate ~90°) and fades to transparent.
	if _death_tween and _death_tween.is_valid():
		_death_tween.kill()
	_death_tween = create_tween()
	_death_tween.set_parallel(true)
	_death_tween.tween_property(self, "rotation", PI * 0.5, 0.45)
	_death_tween.tween_property(self, "modulate:a", 0.0, 0.55)
