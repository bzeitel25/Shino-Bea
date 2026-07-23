extends CanvasLayer

# ============================================================
# JungleVineOverlay.gd — foreground vine fronds hanging into frame
# ============================================================
# Semi-transparent vine sprites positioned at the corners / edges of
# the viewport, drawn ABOVE the world (layer 2) but below HUD (10).
# Gives the feeling of peering through a jungle canopy overhead.
# Each vine has a slow idle sway (sin-based rotation wobble) so they
# feel alive without being distracting.
#
# Spawned by DreamRoom for the jungle biome; auto-removed on room exit.
# ============================================================

const VINE_DIR: String = "res://Assets/Tilesets/Jungle_props/"
const VINE_NAMES: Array = ["jvine_1", "jvine_3"]

# How transparent the vines are (0 = invisible, 1 = opaque).
const VINE_ALPHA: float = 0.22
# Scale range (screen-relative — vines are big art, scale them down).
const VINE_SCALE_MIN: float = 0.18
const VINE_SCALE_MAX: float = 0.28
# Sway amplitude (radians) and speed.
const SWAY_AMP: float = 0.018
const SWAY_SPEED_MIN: float = 0.4
const SWAY_SPEED_MAX: float = 0.7

# Night tint: if dream_world_mode is on, darken the vines to match
# the NightOverlay so they don't glow brighter than the world beneath.
const NIGHT_MODULATE: Color = Color(0.55, 0.61, 0.80)

var _vines: Array = []   # [{ spr: Sprite2D, phase: float, speed: float }]
var _time: float = 0.0

static var _tex_cache: Dictionary = {}


func _ready() -> void:
	name = "JungleVineOverlay"
	layer = 2                    # above world (0), below HUD (10)
	_build()


func _process(delta: float) -> void:
	_time += delta
	for v in _vines:
		var spr: Sprite2D = v["spr"]
		spr.rotation = sin(_time * float(v["speed"]) + float(v["phase"])) * SWAY_AMP


func _build() -> void:
	var vp: Vector2 = Vector2(
		ProjectSettings.get_setting("display/window/size/viewport_width", 1280),
		ProjectSettings.get_setting("display/window/size/viewport_height", 720))
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("jungle_vines") + int(Time.get_ticks_msec()) % 9973

	# Tint for night overlay match.
	var tint: Color = Color.WHITE
	if RunState.dream_world_mode:
		tint = NIGHT_MODULATE

	# Corner placements: each corner gets 1-2 vine fronds hanging in from
	# the edge/corner, anchored off-screen so only the tips dangle into view.
	var corners: Array = [
		# [anchor_pos, rotation, flip_h]
		# Top-left
		{"pos": Vector2(0, 0), "rot": 0.0, "flip": false},
		# Top-right
		{"pos": Vector2(vp.x, 0), "rot": 0.0, "flip": true},
		# Bottom-left
		{"pos": Vector2(0, vp.y), "rot": PI, "flip": true},
		# Bottom-right
		{"pos": Vector2(vp.x, vp.y), "rot": PI, "flip": false},
	]

	for ci in range(corners.size()):
		var corner: Dictionary = corners[ci]
		var n_fronds: int = rng.randi_range(1, 2)
		for fi in range(n_fronds):
			var tex: Texture2D = _load_vine(rng)
			if tex == null:
				continue
			var spr := Sprite2D.new()
			spr.texture = tex
			spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR

			var sc: float = rng.randf_range(VINE_SCALE_MIN, VINE_SCALE_MAX)
			spr.scale = Vector2(sc, sc)
			if corner["flip"]:
				spr.scale.x = -sc

			# Offset from the corner so the vine hangs INTO the frame.
			# The anchor is at the top of the vine (pivot near the top edge)
			# so it dangles downward naturally.
			spr.offset = Vector2(0, float(tex.get_height()) * 0.35)

			var jitter := Vector2(
				rng.randf_range(-60.0, 60.0),
				rng.randf_range(-30.0, 30.0))
			spr.position = corner["pos"] as Vector2 + jitter
			spr.rotation = float(corner["rot"]) + rng.randf_range(-0.15, 0.15)

			spr.modulate = Color(tint.r, tint.g, tint.b, VINE_ALPHA)
			spr.z_index = 0

			add_child(spr)
			_vines.append({
				"spr": spr,
				"phase": rng.randf_range(0.0, TAU),
				"speed": rng.randf_range(SWAY_SPEED_MIN, SWAY_SPEED_MAX),
			})

	# A couple of edge vines along the top (mid-screen) for extra canopy feel.
	for _i in range(rng.randi_range(1, 2)):
		var tex2: Texture2D = _load_vine(rng)
		if tex2 == null:
			continue
		var spr2 := Sprite2D.new()
		spr2.texture = tex2
		spr2.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		var sc2: float = rng.randf_range(VINE_SCALE_MIN * 0.8, VINE_SCALE_MAX * 0.8)
		spr2.scale = Vector2(sc2 * (1.0 if rng.randf() < 0.5 else -1.0), sc2)
		spr2.offset = Vector2(0, float(tex2.get_height()) * 0.35)
		spr2.position = Vector2(rng.randf_range(vp.x * 0.25, vp.x * 0.75), rng.randf_range(-20, 15))
		spr2.rotation = rng.randf_range(-0.12, 0.12)
		spr2.modulate = Color(tint.r, tint.g, tint.b, VINE_ALPHA * 0.65)
		add_child(spr2)
		_vines.append({
			"spr": spr2,
			"phase": rng.randf_range(0.0, TAU),
			"speed": rng.randf_range(SWAY_SPEED_MIN, SWAY_SPEED_MAX),
		})


func _load_vine(rng: RandomNumberGenerator) -> Texture2D:
	var nm: String = VINE_NAMES[rng.randi() % VINE_NAMES.size()]
	if _tex_cache.has(nm):
		return _tex_cache[nm]
	var tex: Texture2D = null
	var path: String = VINE_DIR + nm + ".png"
	if ResourceLoader.exists(path):
		tex = ResourceLoader.load(path) as Texture2D
	if tex == null:
		var abs_path: String = ProjectSettings.globalize_path(path)
		if FileAccess.file_exists(abs_path):
			var img := Image.new()
			if img.load(abs_path) == OK:
				if img.get_format() != Image.FORMAT_RGBA8:
					img.convert(Image.FORMAT_RGBA8)
				tex = ImageTexture.create_from_image(img)
	_tex_cache[nm] = tex
	return tex
