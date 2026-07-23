extends Node2D

# ============================================================
# JawbreakerRig.gd — Run 150 (2026-07-16) — Jawbreaker Juggernaut rolling rig
# ============================================================
# A drop-in animation rig for the lava/caverns CHARGER enemy. Exposes the
# SAME public API the host (ChargerEnemy.gd) already calls on its $Body:
#
#     set_anim_state(s: String)     # "idle"/"walking"/"windup_y"/"swing_y"/
#                                    # "hit_recoil"/"death" (+ others, ignored)
#     set_motion_speed(speed)       # host velocity magnitude → spin rate
#
# Uses the jawbreaker sprite strips and drives PROCEDURAL ROTATION so the
# jawbreaker rolls like a ball when moving, matching the OnionRingRig approach:
#
#     jawbreaker_idle.png   (4 frames)  — idle wobble
#     jawbreaker_walk.png   (4 frames)  — rolling cycle (held frame + rotation)
#     jawbreaker_attack.png (6 frames)  — charge impact art
#     jawbreaker_hit.png    (2 frames)  — flinch
#     jawbreaker_death.png  (3 frames)  — shatter / crumble
#
# QUALITY BEHAVIOUR:
#   idle      → "idle" anim, gentle fps; rotation eased back to upright.
#   walking   → SINGLE held walk frame + PROCEDURAL ROTATION. Angular velocity
#               matched to ground speed (distance / radius). Full ball roll.
#   windup_y  → charger AIM telegraph. Rock BACK against charge direction with
#               a slight squash (rear-up tell).
#   swing_y   → charger CHARGE. Same procedural rotation but much faster
#               (CHARGE_SPIN_MULT) plus GHOST AFTERIMAGES streaming behind.
#   hit_recoil→ brief flinch frames.
#   death     → shatter frames, rotation reset to 0.
# ============================================================

const SHEETS := {
	"idle":   {"path": "res://Assets/Sprites/jawbreaker_idle.png",   "frames": 4},
	"walk":   {"path": "res://Assets/Sprites/jawbreaker_walk.png",   "frames": 4},
	"attack": {"path": "res://Assets/Sprites/jawbreaker_attack.png", "frames": 6},
	"hit":    {"path": "res://Assets/Sprites/jawbreaker_hit.png",    "frames": 2},
	"death":  {"path": "res://Assets/Sprites/jawbreaker_death.png",  "frames": 3},
}

# cellH 339, scale 0.206 from MonsterRig config → ~70px tall on screen.
const SPRITE_SCALE: float = 0.206

# --- Animation tuning -------------------------------------------------------
const IDLE_FPS: float    = 5.0
const HIT_FPS: float     = 9.0
const DEATH_FPS: float   = 7.0

# --- Procedural rolling -----------------------------------------------------
# Pick a walk frame that looks round/symmetric for the held rolling frame.
const ROLL_HOLD_FRAME: int = 1
# Wheel radius in SOURCE px (cellH 339 → radius ~170). After SPRITE_SCALE the
# on-screen radius is WHEEL_RADIUS_SRC * SPRITE_SCALE.
const WHEEL_RADIUS_SRC: float = 170.0
# Base spin multiplier — physically-correct rolling reads too slow at this
# size, so we spin a bit faster for a lively medium roll.
const ROLL_SPIN_MULT: float = 2.4
# Extra spin multiplier while charging — stacks on ROLL_SPIN_MULT for a
# dramatic fast spin during the dash.
const CHARGE_SPIN_MULT: float = 2.0
# Cap angular velocity (rad/s) so physics spikes can't strobe the ball.
const MAX_SPIN_RATE: float = 48.0
# How fast rotation eases back to upright when idle/windup (rad/s approach).
const ROT_EASE_RATE: float = 12.0
# Slow backward rock while winding up (rad/s), like a ball loading backward.
const WINDUP_ROCK_RATE: float = 1.4

# --- Ghost afterimages (charge speed-lines) ---------------------------------
const GHOST_INTERVAL: float = 0.055
const GHOST_LIFETIME: float = 0.22
const GHOST_ALPHA: float = 0.40
const GHOST_Z: int = -1

# Windup rear-up tell.
const WINDUP_BACK_PX: float = 7.0
const WINDUP_SQUASH: Vector2 = Vector2(1.10, 0.90)
const WINDUP_EASE: float = 0.14

var _anim: AnimatedSprite2D = null
var _state: String = "idle"
var _motion_speed: float = 0.0
var _facing_sign: float = 1.0
var _base_pos: Vector2 = Vector2.ZERO
var _base_scale: Vector2 = Vector2.ONE
var _pose_tween: Tween = null
var _built: bool = false
var _wheel_radius_px: float = 35.0
var _spin: float = 0.0
var _ghost_timer: float = 0.0


func _ready() -> void:
	_build()


func _build() -> void:
	if _built:
		return
	for key in SHEETS.keys():
		if not ResourceLoader.exists(SHEETS[key]["path"]):
			push_warning("[JawbreakerRig] %s not imported yet — open the Godot editor once to import the jawbreaker_*.png strips." % SHEETS[key]["path"])
			return

	var sf := SpriteFrames.new()
	sf.remove_animation("default")
	for key in SHEETS.keys():
		var info: Dictionary = SHEETS[key]
		var tex: Texture2D = load(info["path"])
		if tex == null:
			return
		var count: int = int(info["frames"])
		var fw: int = int(tex.get_width() / count)
		var fh: int = tex.get_height()
		sf.add_animation(key)
		# walk/attack are held on a single frame (procedural rotation drives the
		# spin); death holds on its last frame too.
		sf.set_animation_loop(key, key == "idle" or key == "hit")
		match key:
			"idle":   sf.set_animation_speed(key, IDLE_FPS)
			"walk":   sf.set_animation_speed(key, 1.0)    # unused (held frame)
			"attack": sf.set_animation_speed(key, 1.0)    # unused (held frame)
			"hit":    sf.set_animation_speed(key, HIT_FPS)
			"death":  sf.set_animation_speed(key, DEATH_FPS)
		for i in range(count):
			var at := AtlasTexture.new()
			at.atlas = tex
			at.region = Rect2(i * fw, 0, fw, fh)
			sf.add_frame(key, at)

	_anim = AnimatedSprite2D.new()
	_anim.name = "JawbreakerSprite"
	_anim.sprite_frames = sf
	_anim.animation = "idle"
	_anim.centered = true
	_anim.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_anim.scale = Vector2(SPRITE_SCALE, SPRITE_SCALE)
	# Ground the ball near the enemy origin.
	var ref_h: float = float(load(SHEETS["walk"]["path"]).get_height())
	_anim.position = Vector2(0, -(ref_h * SPRITE_SCALE) * 0.5 + 2.0)
	_base_pos = _anim.position
	_base_scale = _anim.scale
	_wheel_radius_px = maxf(4.0, WHEEL_RADIUS_SRC * SPRITE_SCALE)
	add_child(_anim)
	_anim.play("idle")

	# Hide the placeholder stick-figure parts.
	for child in get_children():
		if child is CanvasItem and child != _anim:
			(child as CanvasItem).visible = false

	_built = true


# ---------------------------------------------------------------------------
# Public API (mirrors BodyAnimator / OnionRingRig)
# ---------------------------------------------------------------------------
func set_motion_speed(speed: float) -> void:
	_motion_speed = speed


func set_anim_state(s: String) -> void:
	if not _built or _anim == null:
		return
	_update_facing()

	if s == _state:
		return
	_state = s

	match s:
		"idle":
			_kill_pose_tween()
			_reset_transform()
			_play("idle")
		"walking":
			_kill_pose_tween()
			_reset_transform()
			# Hold one crisp frame; rotation does the rolling.
			_play("walk")
			_anim.pause()
			_anim.frame = ROLL_HOLD_FRAME
		"windup_y", "windup_x", "windup_a":
			# Charger AIM telegraph — rear back against the charge direction.
			_play("idle")
			_do_windup()
		"swing_y", "swing_x", "swing_a":
			# Charger CHARGE — held walk frame, fast spin + ghost afterimages.
			_kill_pose_tween()
			_reset_transform()
			_play("walk")
			_anim.pause()
			_anim.frame = ROLL_HOLD_FRAME
			_ghost_timer = 0.0
		"hit_recoil":
			_kill_pose_tween()
			_reset_transform()
			_play("hit")
		"death":
			_kill_pose_tween()
			_spin = 0.0
			if _anim:
				_anim.rotation = 0.0
			_play("death")
		_:
			pass


func _process(delta: float) -> void:
	if not _built or _anim == null:
		return
	_update_facing()
	var rolling: bool = _state == "walking"
	var charging: bool = _state == "swing_y" or _state == "swing_x" or _state == "swing_a"

	if rolling or charging:
		var spin_rate: float = (_motion_speed / _wheel_radius_px) * ROLL_SPIN_MULT
		if charging:
			spin_rate *= CHARGE_SPIN_MULT
		spin_rate = clampf(spin_rate, 0.0, MAX_SPIN_RATE)
		_spin += _facing_sign * spin_rate * delta
		_anim.rotation = _spin
		if charging:
			_ghost_timer -= delta
			if _ghost_timer <= 0.0:
				_ghost_timer = GHOST_INTERVAL
				_spawn_ghost()
	elif _state.begins_with("windup"):
		_spin += -_facing_sign * WINDUP_ROCK_RATE * delta
		_spin = clampf(_spin, -0.5, 0.5)
		_anim.rotation = _spin
	elif _state == "idle" or _state == "hit_recoil":
		_ease_rotation_to_zero(delta)


func _ease_rotation_to_zero(delta: float) -> void:
	_spin = wrapf(_spin, -PI, PI)
	var step: float = -_spin * clampf(ROT_EASE_RATE * delta, 0.0, 1.0)
	_spin += step
	if absf(_spin) < 0.01:
		_spin = 0.0
	_anim.rotation = _spin


func _spawn_ghost() -> void:
	var host := get_parent()
	if host == null:
		return
	var parent := host.get_parent()
	if parent == null:
		return
	var g := Sprite2D.new()
	g.texture = _anim.sprite_frames.get_frame_texture("walk", _anim.frame)
	g.centered = true
	g.flip_h = _anim.flip_h
	g.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	g.z_index = GHOST_Z
	g.z_as_relative = false
	g.modulate = Color(1, 1, 1, GHOST_ALPHA)
	parent.add_child(g)
	g.global_position = _anim.global_position
	g.global_rotation = _anim.global_rotation
	g.global_scale = _anim.global_scale
	var tw := g.create_tween()
	tw.tween_property(g, "modulate:a", 0.0, GHOST_LIFETIME)
	tw.tween_callback(g.queue_free)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
func _play(anim_name: String) -> void:
	if _anim.animation != anim_name:
		_anim.play(anim_name)


func _update_facing() -> void:
	var host := get_parent()
	if host and host is CharacterBody2D:
		var vx: float = (host as CharacterBody2D).velocity.x
		if absf(vx) > 4.0:
			_facing_sign = 1.0 if vx >= 0.0 else -1.0
	# While rolling/charging, rotation sign drives direction — keep flip_h off.
	if _state == "walking" or _state == "swing_y" or _state == "swing_x" or _state == "swing_a":
		_anim.flip_h = false
	else:
		_anim.flip_h = _facing_sign < 0.0


func _do_windup() -> void:
	_kill_pose_tween()
	_anim.speed_scale = 1.0
	var back: Vector2 = _base_pos + Vector2(-_facing_sign * WINDUP_BACK_PX, -2.0)
	var squash: Vector2 = Vector2(_base_scale.x * WINDUP_SQUASH.x, _base_scale.y * WINDUP_SQUASH.y)
	_pose_tween = create_tween()
	_pose_tween.set_parallel(true)
	_pose_tween.tween_property(_anim, "position", back, WINDUP_EASE)
	_pose_tween.tween_property(_anim, "scale", squash, WINDUP_EASE)


func _reset_transform() -> void:
	if _anim == null:
		return
	_anim.position = _base_pos
	_anim.scale = _base_scale


func _kill_pose_tween() -> void:
	if _pose_tween and _pose_tween.is_valid():
		_pose_tween.kill()
	_pose_tween = null
