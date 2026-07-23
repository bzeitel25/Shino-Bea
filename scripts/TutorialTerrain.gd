extends RefCounted

# ============================================================
# TutorialTerrain.gd — Run 141 — Tutorial dream-street terrain
# ============================================================
# Procedural terrain for the 5-room tutorial intro. Each room is
# a wide horizontal hallway (representing a shadowy dream-version
# of the island's town streets). The player moves west → east.
#
# Visual style: dark, misty, dream-purple palette — same starry
# sky backdrop as the void rooms but with a cobblestone-ish
# ground in muted blues/purples.
#
# Usage:
#   TutorialTerrain.build(parent_node, half_extents, room_number)
# ============================================================

const TEXEL: int = 2
const GROUND_Z: int = -35
const STARRY_Z: int = -50

# Tutorial rooms are wider than tall — horizontal hallway.
# Returns half-extents for each tutorial room.
static func room_half(room: int) -> Vector2:
	match room:
		1: return Vector2(400, 200)     # small movement sandbox
		2: return Vector2(480, 240)     # combat training room
		3: return Vector2(420, 220)     # meet Bea room
		4: return Vector2(520, 260)     # free practice room
		5: return Vector2(480, 280)     # miniboss arena
		_: return Vector2(460, 240)


static func build(parent: Node2D, half: Vector2, room: int) -> void:
	# Clean up any previous terrain layers
	for n in ["TutorialGround", "TutorialVoid"]:
		var old: Node = parent.get_node_or_null(n)
		if old:
			old.queue_free()

	# Dark void backdrop (deep purple-black, behind the ground)
	var void_layer := ColorRect.new()
	void_layer.name = "TutorialVoid"
	void_layer.z_index = STARRY_Z
	var margin: float = 400.0
	void_layer.position = Vector2(-half.x - margin, -half.y - margin)
	void_layer.size = Vector2((half.x + margin) * 2, (half.y + margin) * 2)
	void_layer.color = Color(0.03, 0.02, 0.06, 1.0)
	parent.add_child(void_layer)

	# Ground image — procedural pixel-art cobblestone road
	var gw: int = int(half.x * 2) / TEXEL
	var gh: int = int(half.y * 2) / TEXEL
	var img := Image.create(gw, gh, false, Image.FORMAT_RGBA8)

	var rng := RandomNumberGenerator.new()
	rng.seed = 141000 + room

	# Palette — dark dream cobblestone
	var base_a := Color(0.14, 0.11, 0.20)    # dark purple-grey
	var base_b := Color(0.18, 0.14, 0.24)    # slightly lighter
	var seam := Color(0.08, 0.06, 0.12)      # dark mortar lines
	var highlight := Color(0.22, 0.18, 0.30) # occasional lighter stone

	# Fill with dithered stone pattern
	for y in range(gh):
		for x in range(gw):
			# Seam grid at every 8 texels (16px rhythm), offset every other row
			var tile_x: int = x / 8
			var tile_y: int = y / 8
			var in_seam: bool = (x % 8 == 0) or (y % 8 == 0)
			# Offset every other row like real cobblestone
			var offset_x: int = x + (4 if tile_y % 2 == 1 else 0)
			in_seam = in_seam or (offset_x % 8 == 0)

			if in_seam:
				img.set_pixel(x, y, seam)
			else:
				# Ordered dithering between base_a and base_b
				var bayer: float = _bayer4(x, y)
				var noise_val: float = rng.randf()
				rng.seed = rng.seed  # don't actually advance
				# Use a stable hash-based noise for determinism
				var hash_val: float = fmod(float((x * 7919 + y * 6271 + room * 3571) % 997) / 997.0, 1.0)
				var col: Color
				if hash_val > 0.88:
					col = highlight
				elif bayer + hash_val * 0.3 > 0.55:
					col = base_b
				else:
					col = base_a
				img.set_pixel(x, y, col)

	# Edge vignette — darken near the border
	var vignette_band: int = mini(gw, gh) / 5
	for y in range(gh):
		for x in range(gw):
			var dx: float = minf(float(x), float(gw - 1 - x)) / float(vignette_band)
			var dy: float = minf(float(y), float(gh - 1 - y)) / float(vignette_band)
			var d: float = clampf(minf(dx, dy), 0.0, 1.0)
			if d < 1.0:
				var c := img.get_pixel(x, y)
				var fade: float = d * d  # quadratic falloff
				img.set_pixel(x, y, c.lerp(Color(0.03, 0.02, 0.06), 1.0 - fade))

	var tex := ImageTexture.create_from_image(img)
	tex.set_meta("filter", false)
	var ground := Sprite2D.new()
	ground.name = "TutorialGround"
	ground.texture = tex
	ground.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	ground.scale = Vector2(TEXEL, TEXEL)
	ground.z_index = GROUND_Z
	parent.add_child(ground)

	# Mist / fog particles at the edges (subtle environmental flair)
	_add_mist(parent, half, room)


static func _bayer4(x: int, y: int) -> float:
	const M: Array = [
		[0.0,   0.5,   0.125, 0.625],
		[0.75,  0.25,  0.875, 0.375],
		[0.1875, 0.6875, 0.0625, 0.5625],
		[0.9375, 0.4375, 0.8125, 0.3125],
	]
	return M[y % 4][x % 4]


static func _add_mist(parent: Node2D, half: Vector2, _room: int) -> void:
	# Simple animated mist using GPUParticles2D
	var mist := GPUParticles2D.new()
	mist.name = "TutorialMist"
	mist.z_index = -30
	mist.amount = 20
	mist.lifetime = 6.0
	mist.preprocess = 3.0
	mist.emitting = true

	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	mat.emission_box_extents = Vector3(half.x, half.y, 0)
	mat.direction = Vector3(1.0, -0.2, 0)
	mat.spread = 25.0
	mat.initial_velocity_min = 8.0
	mat.initial_velocity_max = 18.0
	mat.gravity = Vector3.ZERO
	mat.scale_min = 3.0
	mat.scale_max = 6.0
	mat.color = Color(0.15, 0.12, 0.25, 0.12)
	mist.process_material = mat

	parent.add_child(mist)
