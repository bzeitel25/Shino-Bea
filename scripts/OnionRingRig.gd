extends Node2D

# ============================================================
# OnionRingRig.gd — Run 119 (2026-07-02) — Onion-Ring Rollick sprite rig
# ============================================================
# A drop-in animation rig for the beach CHARGER enemy. It exposes the
# SAME public API the host (ChargerEnemy.gd) already calls on its $Body:
#
#     set_anim_state(s: String)     # "idle"/"walking"/"windup_y"/"swing_y"/
#                                    # "hit_recoil"/"death" (+ others, ignored)
#     set_motion_speed(speed)       # host velocity magnitude → spin rate
#
# ...but instead of animating stick-figure parts, it drives a single
# AnimatedSprite2D built at runtime from Bruno's processed sprite strips:
#
#     onion_idle.png   (4 frames)  — idle wobble
#     onion_roll.png   (6 frames)  — rolling cycle
#     onion_charge.png (4 frames)  — charging roll w/ motion-trail
#     onion_hit.png    (2 frames)  — grimacing flinch
#     onion_death.png  (2 frames)  — topple / fall flat
#
# QUALITY BEHAVIOUR (what the host's state names map to here):
#   idle      → "idle" anim, gentle fps; rotation eased back to upright.
#   walking   → SINGLE clean wheel frame + PROCEDURAL ROTATION. The sprite is
#               spun continuously with angular velocity matched to the actual
#               ground speed (physically-correct rolling: angle_delta =
#               distance / wheel_radius). Sign from travel direction. No frame
#               cycling — the near-identical roll frames would shimmer.
#   windup_y  → the charger's AIM telegraph. Rock BACK against the charge
#               direction with a slight squash (rear-up tell), face upright,
#               with a slow reverse rock like a wheel loading backward.
#   swing_y   → the charger's CHARGE. Same procedural rotation but faster
#               (CHARGE_SPIN_MULT) plus GHOST AFTERIMAGES streaming behind.
#   hit_recoil→ brief flinch frames (does not fire mid-charge — host only
#               sends hit_recoil, and the charger has super-armour so a real
#               charge keeps swing_y; matches existing behaviour).
#   death     → topple frames, rotation reset to 0 so the art reads correctly.
#
# ROTATION / PIVOT: the AnimatedSprite2D is centered=true, so its origin is the
# frame centre. For the roll sheet the wheel's visual centre coincides with the
# frame centre (bbox centre cx182/cy172 vs frame centre 182/171.5), so spinning
# the node about its own origin pivots on the hub with NO vertical bounce.
#
# The host's separate "Sprite" ColorRect flash overlay still drives the
# hit/aim tint, so we do NOT need to recolour frames here.
# ============================================================

const SHEETS := {
	"idle":   {"path": "res://Assets/Sprites/onion_idle.png",   "frames": 4},
	"roll":   {"path": "res://Assets/Sprites/onion_roll.png",   "frames": 6},
	"charge": {"path": "res://Assets/Sprites/onion_charge.png", "frames": 4},
	"hit":    {"path": "res://Assets/Sprites/onion_hit.png",    "frames": 2},
	"death":  {"path": "res://Assets/Sprites/onion_death.png",  "frames": 2},
}

# Native frames are ~330-360px tall (charge strip is wider for its trail).
# We only ever DOWNSCALE (project rule): 0.19 puts the wheel at ~65px tall,
# roughly hero height / a touch bigger for a bruiser. The roster entry keeps
# node scale 1.0 so this is the final on-screen size.
const SPRITE_SCALE: float = 0.19

# --- Animation tuning -------------------------------------------------------
const IDLE_FPS: float    = 5.0
const HIT_FPS: float     = 9.0
const DEATH_FPS: float   = 6.0
# (roll/charge no longer cycle frames — they use procedural rotation — but the
# animations still exist so we can hold a single crisp frame.)

# --- Procedural rolling -----------------------------------------------------
# Held roll frame: pick one that is BOTH symmetric AND circular. Frame 2 read
# as an oval — its content bbox is 348x325 (~7% wider than tall). Frame 3 is a
# near-perfect circle (bbox 324x326, ratio 0.994) and still very symmetric, so
# the tire looks round instead of stretched.
const ROLL_HOLD_FRAME: int = 3
# Wheel radius in SOURCE px (roll bbox ~325px tall → radius ~162). After
# SPRITE_SCALE the on-screen radius is WHEEL_RADIUS_SRC * SPRITE_SCALE.
const WHEEL_RADIUS_SRC: float = 162.0
# Base spin punch for ordinary movement. Physically-correct rolling reads too
# slow at this size, so we spin the tire a bit faster than 1:1 for a lively
# medium roll that still tracks the ground speed.
const ROLL_SPIN_MULT: float = 2.4
# Extra spin punch while charging so the dash reads dramatic (stacks on ROLL_SPIN_MULT).
const CHARGE_SPIN_MULT: float = 1.8
# Cap angular velocity (rad/s) so a physics spike can't strobe the wheel.
const MAX_SPIN_RATE: float = 42.0
# How fast rotation eases back to upright when idle/windup (rad/s of approach).
const ROT_EASE_RATE: float = 12.0     # ~0.2s settle via exponential approach
# Slow backward rock while winding up (rad/s magnitude), like a wheel loading up.
const WINDUP_ROCK_RATE: float = 1.4

# --- Ghost afterimages (charge speed-lines) ---------------------------------
const GHOST_INTERVAL: float = 0.06
const GHOST_LIFETIME: float = 0.25
const GHOST_ALPHA: float = 0.45
const GHOST_Z: int = -1               # behind the live wheel

# Windup rear-up tell.
const WINDUP_BACK_PX: float = 7.0     # nudge backward against charge dir
const WINDUP_SQUASH: Vector2 = Vector2(1.10, 0.90)   # slight squash
const WINDUP_EASE: float = 0.14

var _anim: AnimatedSprite2D = null
var _state: String = "idle"
var _motion_speed: float = 0.0
var _facing_sign: float = 1.0    # +1 rolling right, -1 rolling left
var _base_pos: Vector2 = Vector2.ZERO
var _base_scale: Vector2 = Vector2.ONE
var _pose_tween: Tween = null
var _built: bool = false
var _wheel_radius_px: float = 30.0   # world-px radius (set in _build)
var _spin: float = 0.0               # current sprite rotation (radians)
var _ghost_timer: float = 0.0


func _ready() -> void:
	_build()


func _build() -> void:
	if _built:
		return
	# Bail gracefully if the PNGs haven't been imported yet (fall back to the
	# stick figure that ships in the scene — the host tints it).
	for key in SHEETS.keys():
		if not ResourceLoader.exists(SHEETS[key]["path"]):
			push_warning("[OnionRingRig] %s not imported yet — open the Godot editor once to import the onion_*.png strips." % SHEETS[key]["path"])
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
		# roll/charge are held on a single frame (procedural rotation drives the
		# spin), so no loop; death holds on its last topple frame too.
		sf.set_animation_loop(key, key == "idle" or key == "hit")
		match key:
			"idle":   sf.set_animation_speed(key, IDLE_FPS)
			"roll":   sf.set_animation_speed(key, 1.0)   # unused (held frame)
			"charge": sf.set_animation_speed(key, 1.0)   # unused (held frame)
			"hit":    sf.set_animation_speed(key, HIT_FPS)
			"death":  sf.set_animation_speed(key, DEATH_FPS)
		for i in range(count):
			var at := AtlasTexture.new()
			at.atlas = tex
			at.region = Rect2(i * fw, 0, fw, fh)
			sf.add_frame(key, at)

	_anim = AnimatedSprite2D.new()
	_anim.name = "OnionSprite"
	_anim.sprite_frames = sf
	_anim.animation = "idle"
	_anim.centered = true
	_anim.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_anim.scale = Vector2(SPRITE_SCALE, SPRITE_SCALE)
	# Frames are bottom-anchored (ground contact at frame bottom). Nudge up so
	# the wheel grounds near the enemy origin instead of centering on it.
	var ref_h: float = float(load(SHEETS["roll"]["path"]).get_height())
	_anim.position = Vector2(0, -(ref_h * SPRITE_SCALE) * 0.5 + 2.0)
	_base_pos = _anim.position
	_base_scale = _anim.scale
	# On-screen wheel radius = source radius * downscale. Drives rolling math.
	_wheel_radius_px = maxf(4.0, WHEEL_RADIUS_SRC * SPRITE_SCALE)
	add_child(_anim)
	_anim.play("idle")

	# Hide the placeholder stick-figure parts that ship in the scene; the
	# AnimatedSprite2D is the body now. (The host's "Sprite" flash overlay is a
	# sibling ColorRect, untouched.)
	for child in get_children():
		if child is CanvasItem and child != _anim:
			(child as CanvasItem).visible = false

	_built = true


# ---------------------------------------------------------------------------
# Public API (mirrors BodyAnimator so the host doesn't care which rig it got)
# ---------------------------------------------------------------------------
func set_motion_speed(speed: float) -> void:
	_motion_speed = speed


func set_anim_state(s: String) -> void:
	if not _built or _anim == null:
		return
	# Track heading for flip: host drives velocity, we read the sign lazily via
	# the parent's velocity when moving so the wheel rolls the correct way.
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
			# Hold one crisp full-circle frame; rotation does the rolling.
			_play("roll")
			_anim.pause()
			_anim.frame = ROLL_HOLD_FRAME
		"windup_y", "windup_x", "windup_a":
			# Charger AIM telegraph — rear back against the charge direction.
			_play("idle")
			_do_windup()
		"swing_y", "swing_x", "swing_a":
			# Charger CHARGE — SAME single wheel frame as walking, just a faster
			# spin + ghost afterimages streaming behind. (No triple-ring charge art.)
			_kill_pose_tween()
			_reset_transform()
			_play("roll")
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
		# Rolling: angular speed tracks ground speed / radius, scaled up so the
		# tire visibly spins at a lively medium pace; faster again while charging.
		var spin_rate: float = (_motion_speed / _wheel_radius_px) * ROLL_SPIN_MULT
		if charging:
			spin_rate *= CHARGE_SPIN_MULT
		spin_rate = clampf(spin_rate, 0.0, MAX_SPIN_RATE)
		# Sign from travel direction: moving right (+) rolls clockwise (+angle).
		_spin += _facing_sign * spin_rate * delta
		_anim.rotation = _spin
		if charging:
			_ghost_timer -= delta
			if _ghost_timer <= 0.0:
				_ghost_timer = GHOST_INTERVAL
				_spawn_ghost()
	elif _state.begins_with("windup"):
		# Slow backward rock, like a wheel loading up against the charge dir.
		# _facing_sign points the intended charge direction; rock opposite it,
		# clamped so it can't wind all the way round.
		_spin += -_facing_sign * WINDUP_ROCK_RATE * delta
		_spin = clampf(_spin, -0.5, 0.5)
		_anim.rotation = _spin
	elif _state == "idle" or _state == "hit_recoil":
		# Ease rotation back to upright (shortest path) over ~0.2s.
		_ease_rotation_to_zero(delta)


func _ease_rotation_to_zero(delta: float) -> void:
	# Normalize accumulated spin into [-PI, PI] so we settle the SHORT way round
	# and _spin stays bounded (it grows unboundedly while rolling).
	_spin = wrapf(_spin, -PI, PI)
	var step: float = -_spin * clampf(ROT_EASE_RATE * delta, 0.0, 1.0)
	_spin += step
	if absf(_spin) < 0.01:
		_spin = 0.0
	_anim.rotation = _spin


func _spawn_ghost() -> void:
	# Parent ghosts to the WORLD (enemy's parent), not the enemy — a child of the
	# enemy would ride along with the dash and never trail behind.
	var host := get_parent()
	if host == null:
		return
	var parent := host.get_parent()
	if parent == null:
		return
	var g := Sprite2D.new()
	g.texture = _anim.sprite_frames.get_frame_texture("roll", _anim.frame)
	g.centered = true
	g.flip_h = _anim.flip_h
	g.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	g.z_index = GHOST_Z
	g.z_as_relative = false
	g.modulate = Color(1, 1, 1, GHOST_ALPHA)
	parent.add_child(g)
	# Match the live wheel's on-screen transform. Set GLOBAL props AFTER adding
	# to the tree so they resolve against this parent (host may be scaled).
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
	# While ROLLING/CHARGING direction lives entirely in the rotation SIGN, so
	# keep flip_h off (flipping would mirror the perceived spin direction).
	if _state == "walking" or _state == "swing_y" or _state == "swing_x" or _state == "swing_a":
		_anim.flip_h = false
	else:
		# Non-rolling states: face the travel direction as the art expects.
		_anim.flip_h = _facing_sign < 0.0


func _do_windup() -> void:
	_kill_pose_tween()
	_anim.speed_scale = 1.0
	# Rear back opposite the charge direction (facing_sign points travel dir).
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
