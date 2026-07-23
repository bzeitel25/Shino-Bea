extends Node2D

# ============================================================
# SnowOverlay.gd — Frostpeak snowfall particle overlay
# ============================================================
# Spawns as a child of DreamRoom when the biome is "peaks".
# A full-screen snowfall effect using CPUParticles2D with Bruno's
# hand-drawn snowflake textures (Snow Flakes.png → mflake_*.png).
#
# Intensity ramps with room depth:
#   Room 1-2  →  light dusting   (0.10–0.25)
#   Room 3-4  →  moderate snow   (0.35–0.50)
#   Room 5-6  →  heavy snow      (0.60–0.75)
#   Room 7-8  →  blizzard        (0.85–1.00)
#
# set_intensity(t) controls: emission count, fall speed, wind
# strength, flake opacity, and a subtle white fog tint at high
# intensities (blizzard whiteout).
#
# Lives in WORLD SPACE (Node2D child of DreamRoom, layer 0) so:
#   - Particles don't move with the player/camera (local_coords=false)
#   - NightOverlay CanvasModulate automatically tints the snow
# Emitters reposition to the camera each frame so flakes always
# spawn over the visible area; already-spawned flakes stay put.
#
# Each size tier (big / medium / small) runs its own emitter so
# large flakes drift slowly while small flakes blow faster, and
# each tier picks from its own texture pool for variety.
# ============================================================

const FLAKE_DIR: String = "res://Assets/Tilesets/Mountain_props/"

# Texture pools by size tier.
const BIG_NAMES: Array = ["mflake_big_1", "mflake_big_2", "mflake_big_3"]
const MED_NAMES: Array = ["mflake_med_1", "mflake_med_2", "mflake_med_3", "mflake_med_4"]
const SM_NAMES:  Array = ["mflake_sm_1", "mflake_sm_2", "mflake_sm_3", "mflake_sm_4"]

# Tier config: [name_pool, base_amount, scale_min, scale_max, speed_min, speed_max, weight_in_blend]
const TIERS: Array = [
	# Big flakes — fewer, drift slowly, close to camera (larger).
	{ "pool": "big", "base_amount": 14,  "scale": [0.30, 0.50], "speed": [18.0, 36.0] },
	# Medium flakes — moderate count, mid-speed.
	{ "pool": "med", "base_amount": 28,  "scale": [0.20, 0.35], "speed": [28.0, 52.0] },
	# Small flakes — many, blow faster, distant (tiny).
	{ "pool": "sm",  "base_amount": 40,  "scale": [0.10, 0.22], "speed": [38.0, 68.0] },
]

# World-space emission rect (padded well past the camera's visible area so
# flakes are already drifting when they scroll into view).
const EMIT_HALF_W: float = 560.0      # half-width of emission band
const EMIT_HEIGHT: float = 100.0      # spawn strip above visible top
const FALL_EXTENT: float = 620.0      # how far below spawn before recycle

# Wind (horizontal drift). Blizzard cranks this up.
const WIND_BASE: float = 8.0
const WIND_BLIZZARD: float = 55.0
const WIND_GUST_AMP: float = 18.0     # sinusoidal gust added on top

# Whiteout fog at high intensity (subtle additive white veil).
const FOG_MAX_ALPHA: float = 0.10

var _intensity: float = 0.0
var _emitters: Array = []              # [CPUParticles2D, ...]
var _fog: ColorRect = null             # blizzard fog (CanvasLayer child)
var _fog_layer: CanvasLayer = null     # dedicated CanvasLayer for the fog rect
var _camera: Camera2D = null
var _time: float = 0.0

static var _tex_cache: Dictionary = {}


static func _load_tex(name: String) -> Texture2D:
	if _tex_cache.has(name):
		return _tex_cache[name]
	var tex: Texture2D = null
	var path: String = FLAKE_DIR + name + ".png"
	if ResourceLoader.exists(path):
		var res: Resource = ResourceLoader.load(path)
		if res is Texture2D:
			tex = res
	if tex == null:
		var img := Image.new()
		var abs_path: String = ProjectSettings.globalize_path(path)
		if img.load(abs_path) == OK:
			if img.get_format() != Image.FORMAT_RGBA8:
				img.convert(Image.FORMAT_RGBA8)
			tex = ImageTexture.create_from_image(img)
	_tex_cache[name] = tex
	return tex


func _ready() -> void:
	# We're a plain Node2D in world-space (child of DreamRoom, layer 0).
	# The NightOverlay CanvasModulate on layer 0 automatically tints us,
	# so snow looks night-time with zero extra work.
	z_index = 20   # draw above terrain/props, below HUD

	# Build one CPUParticles2D per size tier.
	for tier in TIERS:
		var pool_names: Array
		match tier["pool"]:
			"big": pool_names = BIG_NAMES
			"med": pool_names = MED_NAMES
			_:     pool_names = SM_NAMES

		# Pick a random texture from the pool for this emitter.
		var tex: Texture2D = null
		for nm in pool_names:
			tex = _load_tex(nm)
			if tex != null:
				break
		if tex == null:
			continue

		var p := CPUParticles2D.new()
		p.name = "Snow_" + String(tier["pool"])
		p.texture = tex
		p.emitting = true
		p.one_shot = false
		p.explosiveness = 0.0
		p.randomness = 1.0
		p.lifetime = FALL_EXTENT / (float(tier["speed"][0] + tier["speed"][1]) * 0.5)
		p.amount = int(tier["base_amount"])
		p.fixed_fps = 0                  # use frame delta
		p.local_coords = false           # particles stay in WORLD space (don't move with camera)

		# Emission shape — wide horizontal band above the screen.
		p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
		p.emission_rect_extents = Vector2(EMIT_HALF_W, 4.0)

		# Motion — downward gravity + slight spread.
		p.direction = Vector2(0.0, 1.0)
		p.spread = 12.0
		p.initial_velocity_min = float(tier["speed"][0])
		p.initial_velocity_max = float(tier["speed"][1])
		p.gravity = Vector2(WIND_BASE, 6.0)    # gentle rightward wind + slight downward pull

		# Scale variation.
		p.scale_amount_min = float(tier["scale"][0])
		p.scale_amount_max = float(tier["scale"][1])

		# Gentle spin for organic drift.
		p.angular_velocity_min = -15.0
		p.angular_velocity_max = 15.0

		# Fade in at birth, fade out at death via color_ramp gradient.
		var ramp := Gradient.new()
		ramp.offsets = PackedFloat32Array([0.0, 0.08, 0.85, 1.0])
		ramp.colors = PackedColorArray([
			Color(1, 1, 1, 0),
			Color(1, 1, 1, 1),
			Color(1, 1, 1, 1),
			Color(1, 1, 1, 0),
		])
		p.color_ramp = ramp

		# Position at world origin; _process will reposition to camera each frame.
		p.position = Vector2.ZERO
		add_child(p)
		_emitters.append(p)

	# Subtle whiteout fog at blizzard intensities — needs its own CanvasLayer
	# (screen-space rect that covers the viewport). Sits under the NightOverlay
	# conceptually but is a separate screen-covering layer.
	_fog_layer = CanvasLayer.new()
	_fog_layer.name = "SnowFogLayer"
	_fog_layer.layer = 1               # above world, below HUD
	_fog_layer.follow_viewport_enabled = false
	add_child(_fog_layer)
	_fog = ColorRect.new()
	_fog.name = "BlizzardFog"
	_fog.color = Color(0.90, 0.93, 0.97, 0.0)
	_fog.size = Vector2(1280, 720)
	_fog.position = Vector2.ZERO
	_fog.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fog_layer.add_child(_fog)

	# Apply initial intensity.
	_apply_intensity()


func _process(delta: float) -> void:
	_time += delta

	# Move the emission origin to the camera so new flakes always spawn over
	# the visible area.  Because local_coords=false, already-spawned particles
	# stay at their world positions — they do NOT drift when the camera moves.
	if _camera == null:
		_camera = get_viewport().get_camera_2d()
	if _camera != null:
		var cam_pos: Vector2 = _camera.global_position
		for p in _emitters:
			p.global_position = Vector2(cam_pos.x, cam_pos.y - FALL_EXTENT * 0.5)

	# Sinusoidal wind gust.
	var gust: float = sin(_time * 0.7) * WIND_GUST_AMP * _intensity
	var wind_x: float = lerpf(WIND_BASE, WIND_BLIZZARD, _intensity) + gust
	for p in _emitters:
		(p as CPUParticles2D).gravity = Vector2(wind_x, 6.0 + 4.0 * _intensity)


## Set snowfall intensity: 0.0 = no snow, 1.0 = blizzard.
func set_intensity(t: float) -> void:
	_intensity = clampf(t, 0.0, 1.0)
	_apply_intensity()


func _apply_intensity() -> void:
	var t: float = _intensity
	for i in range(_emitters.size()):
		if i >= TIERS.size():
			break
		var p: CPUParticles2D = _emitters[i]
		var tier: Dictionary = TIERS[i]
		# Scale particle count with intensity.  Floor of 0.25 so even the lightest
		# snowfall has enough flakes to read as natural (not a single drifting dot).
		p.amount = maxi(3, int(float(tier["base_amount"]) * clampf(t * 1.4, 0.25, 1.0)))
		# Boost speed at high intensity (blizzard drives flakes faster).
		var speed_mult: float = 1.0 + t * 0.6
		p.initial_velocity_min = float(tier["speed"][0]) * speed_mult
		p.initial_velocity_max = float(tier["speed"][1]) * speed_mult
		# Recalculate lifetime to match new speed.
		var avg_speed: float = (p.initial_velocity_min + p.initial_velocity_max) * 0.5
		p.lifetime = FALL_EXTENT / maxf(avg_speed, 1.0)
		# Opacity — light snow is more transparent.
		p.color = Color(1.0, 1.0, 1.0, clampf(t * 1.5 + 0.3, 0.3, 1.0))
		p.emitting = t > 0.01

	# Blizzard fog.
	if _fog != null:
		var fog_a: float = clampf((t - 0.7) / 0.3, 0.0, 1.0) * FOG_MAX_ALPHA
		_fog.color.a = fog_a
