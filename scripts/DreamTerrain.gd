extends RefCounted

# ============================================================
# DreamTerrain.gd — Run 44 (2026-06-10) — procedural pixel terrain
# ============================================================
# Runtime-generated 32px-tile pixel-art terrain + animated ocean
# backdrop for every Dream World zone. No addons — built on Godot's
# native FastNoiseLite + NoiseTexture2D. All textures are generated
# with nearest-neighbor filtering so they read as crisp pixel art.
#
# Layers added to the scene (negative z so everything draws on top):
#   "OceanLayer"    z=-40  ColorRect + shader — animated pixel water
#                          (or dream-void for hub/cake), coast wobble,
#                          surf foam, whitecaps, sand skirt ring.
#   "TerrainGround" z=-35  Sprite2D — generated ground: noise-dithered
#                          tile tones, 32px tile seams, biome motif
#                          stamps (shells, vines, crystals, sprinkles…),
#                          edge vignette toward the wall color.
#
# Usage (DreamRoom / DreamHub):
#   const DT = preload("res://scripts/DreamTerrain.gd")
#   DT.build(self, biome_id, biome, half_extents, seed, progress, style)
#
#   style = "ocean" → tide-blue sea (star-arm biomes; the island!)
#   style = "void"  → drifting dream-night clouds + twinkle stars
#                     (Town Square hub + cake fortress climb)
#   progress 0..1   → how far down the star arm: the sea hugs the
#                     room tighter as rooms narrow toward the tip.
#
# Deterministic: same biome+room seed → same terrain every visit.
# When real art lands, swap _ground_texture() for a TileMapLayer —
# the layer names and z-order are the contract.
# ============================================================

# Run 75: real hand-authored beach art. Beach branches to the tileset path;
# every other biome keeps the procedural ramp renderer below untouched.
const BT = preload("res://scripts/BeachTileset.gd")

# Run 84: each star-arm biome has its OWN dedicated real-art prop module
# (not shared with or derived from the beach). Keyed by biome_id.
const BIOME_TILESETS: Dictionary = {
	"jungle":  preload("res://scripts/JungleTileset.gd"),
	"swamp":   preload("res://scripts/SwampTileset.gd"),
	"caverns": preload("res://scripts/CavernTileset.gd"),
	"peaks":   preload("res://scripts/PeakTileset.gd"),
	# Run 171: the cake ascension finale gets its own real art too — icing floor,
	# chocolate chasms, candy obstacles and a skyline of stacked cake.
	"cake":    preload("res://scripts/CakeTileset.gd"),
}

const STARRY_DIR: String = "res://Assets/Tilesets/Starry/"
const STARRY_COUNT: int = 9       # starry_1.png .. starry_9.png
const STARRY_Z: int = -50         # behind everything including the ocean
const STARRY_FPS: float = 0.15    # slow dreamy cross-fade cycle (~6.6s per frame)

const TEXEL: int = 2              # Run 50: 1 texel = 2 screen px (was 4) — 4× detail density
const TILE: int = 16              # 16 texels = 32px rhythm (motif spacing only — no seams!)
const OCEAN_PX: float = 4.0       # ocean keeps the chunkier texel so waves stay readable
const OCEAN_MARGIN: float = 560.0 # ocean extends this far past the land

# 4×4 Bayer matrix — ordered dithering between palette ramp steps.
# This is THE CrossCode/SNES trick: no hard banding, no smooth gradients,
# just crunchy interleaved texels at every tone boundary.
const BAYER: Array = [
	[0, 8, 2, 10],
	[12, 4, 14, 6],
	[3, 11, 1, 9],
	[15, 7, 13, 5],
]

const WATER_SHADER: String = """
shader_type canvas_item;
uniform vec2 rect_size = vec2(2000.0, 1600.0);
uniform vec2 island_half = vec2(680.0, 550.0);
uniform float px_size = 4.0;
uniform float void_mode = 0.0;
// Run 52 — star-arm mode: land is a STRIP along the travel axis (the arm
// of the star island). Ocean flanks both sides; the arm runs back toward
// the town center and ahead toward the tip. tip_cap closes the land just
// past the boss room so the player finally sees open sea at the tip.
uniform vec2 axis = vec2(0.0, 0.0);     // zero ⇒ legacy rect island (hub)
uniform float strip_half = 600.0;
uniform float tip_cap = 99999.0;
uniform float back_cap = 99999.0;
uniform vec4 col_skirt : source_color = vec4(0.72, 0.62, 0.42, 1.0);
uniform vec4 col_wet   : source_color = vec4(0.52, 0.45, 0.32, 1.0);
uniform vec4 col_foam  : source_color = vec4(0.92, 0.96, 1.00, 1.0);
uniform vec4 col_light : source_color = vec4(0.24, 0.52, 0.78, 1.0);
uniform vec4 col_mid   : source_color = vec4(0.13, 0.34, 0.58, 1.0);
uniform vec4 col_deep  : source_color = vec4(0.07, 0.20, 0.40, 1.0);
uniform sampler2D noise_tex : repeat_enable, filter_nearest;

void fragment() {
	// Pixel-quantized coordinates — everything below snaps to the texel grid.
	vec2 p = floor(UV * rect_size / px_size) * px_size;
	vec2 c = p - rect_size * 0.5;
	float d;
	if (length(axis) > 0.5) {
		vec2 perp = vec2(-axis.y, axis.x);
		float along = dot(c, axis);
		float across = abs(dot(c, perp));
		d = across - strip_half;                   // sea on both flanks
		d = max(d, along - tip_cap);               // tip coast (boss room)
		d = max(d, -along - back_cap);
	} else {
		vec2 q = abs(c) - island_half;
		d = max(q.x, q.y);                         // legacy rect island
	}

	float n  = texture(noise_tex, p / 380.0 + vec2( TIME * 0.020, TIME * 0.012)).r;
	float n2 = texture(noise_tex, p / 240.0 + vec2(-TIME * 0.016, TIME * 0.010)).r;
	float coast = texture(noise_tex, p / 300.0).r; // static — wobbles the coastline
	float dd = d + (coast - 0.5) * 36.0;
	float wave = sin(TIME * 1.6 + coast * 12.0) * 4.0;

	vec4 col;
	if (void_mode > 0.5) {
		// Dream-night void: drifting cloud bands + twinkling stars.
		if (dd <= 0.0) {
			col = col_skirt;
			if (n2 > 0.86) { col = col_wet; }
		} else {
			float w = n * 0.65 + n2 * 0.35;
			col = (w < 0.45) ? col_deep : ((w < 0.62) ? col_mid : col_light);
			float tw = texture(noise_tex, p / 97.0).r;
			if (tw > 0.965 && sin(TIME * 2.0 + tw * 40.0) > 0.0) { col = col_foam; }
			if (dd < 26.0) { col = mix(col_wet, col, 0.45); }
		}
	} else {
		if (dd <= 0.0) {
			col = col_skirt;                        // sandy ring around the room
			if (n2 > 0.88) { col = col_wet; }       // pebble dither
		} else if (dd < 10.0) {
			col = col_wet;                          // waterline-wet sand
		} else if (dd < 17.0 + wave + n * 6.0) {
			col = col_foam;                         // animated surf line
		} else {
			float w = n * 0.6 + n2 * 0.4;
			float band = dd + w * 60.0;
			col = (band < 90.0) ? col_light : ((band < 200.0) ? col_mid : col_deep);
			if (w > 0.86) { col = col_light; }      // sparkle crests
			if (w > 0.93) { col = col_foam; }       // whitecaps
		}
	}
	// Run 116: fade to transparent at outer edges so starry backdrop peeks through.
	vec2 edge = abs(p - rect_size * 0.5) / (rect_size * 0.5);
	float edge_d = max(edge.x, edge.y);
	float fade_alpha = 1.0 - smoothstep(0.82, 1.0, edge_d);
	col.a = fade_alpha;
	COLOR = col;
}
"""

# Pixel motif stamps scattered on the ground. Chars:
#   a = biome accent   d = floor darkened   l = floor lightened
#   k = wall-dark line  w = near-white       . = skip
const MOTIFS: Dictionary = {
	"beach": [
		["..a..", "a.a.a", ".aaa.", "a.a.a", "..a.."],                  # starfish
		[".lll.", "l.d.l", "l.dd.", ".l.l.", "..l.."],                  # shell swirl
		["dd...", "..ddd", "dd...", "..ddd"],                           # dune ripples
	],
	"jungle": [
		["..a..", ".aaa.", "aaaaa", ".aka.", "..k.."],                  # canopy leaf
		["k....", ".k.a.", "..k..", ".a.k.", "....k"],                  # vine squiggle
		["..w..", ".waw.", "..w..", "..k.."],                           # jungle bloom
	],
	"swamp": [
		[".a...", "...a.", ".a.a.", "...a."],                           # bog bubbles
		["..k..", "..k..", ".aka.", "..k..", "..k.."],                  # reed stalk
		[".ddd.", "ddddd", ".ddd."],                                    # murk puddle
	],
	"caverns": [
		# Run 52: defined stalagmites — glint tip, lit left facet, shaded
		# right, shadow at the base (no more blocky upside-down Ts).
		["...w...", "...h...", "..hha..", "..haa..", ".hhaak.", ".haaak.", ".d...d."],   # tall stalagmite
		[".w...w.", ".h...h.", "hha.hak", "haa.aak", ".d...d."],                          # twin spikes
		["k......", ".kh....", "..khk..", "....hk.", ".....k."],                          # glowing fissure
	],
	"peaks": [
		["...w...", "...w...", "..wha..", "..wha..", ".wwhaa.", ".d...d."],               # ice spike
		[".wwww..", "wwwwww.", "..wwww."],                                                # snow drift
		["..w..", ".w.w.", "w.h.w", ".w.w.", "..w.."],                                    # sparkle
	],
	"cake": [
		[".a...", "...w.", ".a.a.", "..w.."],                           # sprinkles
		["..d..", ".ddd.", ".dkd.", ".ddd."],                           # choco chip
		[".ww..", "w..w.", ".w.w.", "..w.."],                           # frosting swirl
	],
	"hub": [
		["k....", ".kk..", "...k.", "....k"],                           # cobble crack
		[".a...", ".aa..", "..a.."],                                    # lantern glow
		[".ddd.", "d.d.d", ".ddd."],                                    # worn cobble
	],
}


# ---------------------------------------------------------------------------
# Public entry — builds ocean + ground layers under `parent`.
# ---------------------------------------------------------------------------
static func build(parent: Node2D, biome_id: String, biome: Dictionary,
		half: Vector2, seed_val: int, progress: float = 0.0,
		style: String = "ocean", layout: RefCounted = null,
		exit_dir: Vector2 = Vector2.ZERO, tip: bool = false,
		gate_positions: Array = []) -> void:
	for n in ["StarryBackdrop", "OceanLayer", "TerrainGround", "BeachProps"]:
		var old: Node = parent.get_node_or_null(n)
		if old:
			old.queue_free()

	# Run 116: animated starry sky behind everything — "looking past the edge of
	# the planet". Sits below the ocean/lava/void layer so it peeks through at the
	# extreme edges where the arena meets open space.
	var starry: Node2D = _make_starry_backdrop(half, seed_val)
	if starry != null:
		parent.add_child(starry)

	# Land shrinks toward the star tip — the sea closes in room by room.
	var skirt: float = lerp(200.0, 70.0, clamp(progress, 0.0, 1.0))
	var land_half: Vector2 = half + Vector2(skirt, skirt)
	var ocean_half: Vector2 = land_half + Vector2(OCEAN_MARGIN, OCEAN_MARGIN)

	var ocean: ColorRect = _make_ocean(biome, land_half, ocean_half, seed_val, style, exit_dir, tip)
	parent.add_child(ocean)

	# Run 75: beach uses the real tileset (sand/water tiles + rock-barrier and
	# palm props). Falls back to the procedural ramp if the sheet won't load.
	if biome_id == "beach" and layout != null and BT.available():
		_tune_ocean_for_beach(ocean)
		parent.add_child(BT.make_ground(half, layout, seed_val, exit_dir))
		parent.add_child(BT.make_props(half, layout, seed_val, gate_positions))
		return

	# Run 84: dedicated real-art props per biome. The procedural ground stays
	# (skipping its baked stand-in props) and the biome's own module overlays the
	# hand-cut trees / rocks / crystals as obstacles lining the pathways.
	var ts: Variant = BIOME_TILESETS.get(biome_id, null)
	var real_props: bool = ts != null and layout != null and ts.available()
	# Real-art baked ground (floor + river liquid) when the biome's sheet loads;
	# otherwise keep the procedural ramp renderer.
	var real_ground: Sprite2D = null
	if ts != null and layout != null and ts.ground_available():
		if biome_id == "caverns":
			# Caverns bake a LAVA MOAT island — the ground needs gate slots so it can
			# carve ground causeways across the lake at each exit. Also retint the
			# backdrop to a dark molten lake so the moat reads as endless lava.
			real_ground = ts.make_ground(half, layout, seed_val, gate_positions)
			_tune_ocean_for_caverns(ocean)
		elif biome_id == "peaks":
			_tune_ocean_for_peaks(ocean)
			if RunState.peak_room_type == "cave" and RunState.biome_room > 1:
				real_ground = ts.make_ground_cave(half, layout, seed_val)
			else:
				real_ground = ts.make_ground(half, layout, seed_val)
		else:
			real_ground = ts.make_ground(half, layout, seed_val)
	if biome_id == "jungle":
		_tune_ocean_for_jungle(ocean)
	if real_ground != null:
		parent.add_child(real_ground)
	else:
		parent.add_child(_make_ground(biome_id, biome, half, seed_val, layout, real_props))
	# Run 94: swamp overlays an animated LIQUID layer (clean square bubbling-poison
	# pools + flowing-river tiles) on top of its baked mire ground.
	if biome_id in ["swamp", "caverns", "jungle"] and ts != null and layout != null:
		var liquid: Node2D = ts.make_liquid(half, layout, seed_val, gate_positions)
		if liquid != null:
			parent.add_child(liquid)
		# Caverns (Run 101, Bruno): the island border is now just ground tiles meeting the
		# lava lake, with a baked glowy molten rim painted into make_ground where they meet.
		# The Lava Island rock frame + shoreline-tile river banks were dropped — they weren't
		# working; rivers read as plain animated lava like everything else again.
	if real_props:
		if biome_id == "peaks" and RunState.peak_room_type == "cave" and RunState.biome_room > 1:
			parent.add_child(ts.make_props_cave(half, layout, seed_val, gate_positions))
		else:
			parent.add_child(ts.make_props(half, layout, seed_val, gate_positions))


# Beach arena walls/caves live on sheet 2 — DreamRoom calls these passthroughs
# so it only needs to depend on DreamTerrain.
static func beach_walls_available() -> bool:
	return BT.available_walls()


static func make_beach_walls(half: Vector2, exit_dir: Vector2, gate_positions: Array,
		seed_val: int) -> Node2D:
	return BT.make_walls(half, exit_dir, gate_positions, seed_val)


# Jungle arena border = a jungle-TREE frame + dense outer forest.
static func jungle_walls_available() -> bool:
	var ts: Variant = BIOME_TILESETS.get("jungle", null)
	return ts != null and ts.walls_available()


static func make_jungle_walls(half: Vector2, exit_dir: Vector2, gate_positions: Array,
		seed_val: int, layout: RefCounted = null) -> Node2D:
	return BIOME_TILESETS["jungle"].make_walls(half, exit_dir, gate_positions, seed_val, layout)


# Cake fortress border = a skyline of stacked cake architecture.
static func cake_walls_available() -> bool:
	var ts: Variant = BIOME_TILESETS.get("cake", null)
	return ts != null and ts.walls_available()


static func make_cake_walls(half: Vector2, exit_dir: Vector2, gate_positions: Array,
		seed_val: int, layout: RefCounted = null) -> Node2D:
	return BIOME_TILESETS["cake"].make_walls(half, exit_dir, gate_positions, seed_val, layout)


# Swamp arena border = a swamp-TREE frame + outer forest (its own wall art,
# like the beach cliff frame). DreamRoom branches to these passthroughs.
static func swamp_walls_available() -> bool:
	var ts: Variant = BIOME_TILESETS.get("swamp", null)
	return ts != null and ts.walls_available()


static func make_swamp_walls(half: Vector2, exit_dir: Vector2, gate_positions: Array,
		seed_val: int, layout: RefCounted = null) -> Node2D:
	return BIOME_TILESETS["swamp"].make_walls(half, exit_dir, gate_positions, seed_val, layout)


# Caverns arena border = a stalagmite/stalactite teeth CAGE (its own wall art,
# like the swamp tree frame). DreamRoom branches to these passthroughs.
static func caverns_walls_available() -> bool:
	var ts: Variant = BIOME_TILESETS.get("caverns", null)
	return ts != null and ts.walls_available()


static func make_caverns_walls(half: Vector2, exit_dir: Vector2, gate_positions: Array,
		seed_val: int, layout: RefCounted = null) -> Node2D:
	return BIOME_TILESETS["caverns"].make_walls(half, exit_dir, gate_positions, seed_val, layout)


# Peaks arena border = a snowy tree-lined forest frame with cave/spike gate markers.
static func peaks_walls_available() -> bool:
	var ts: Variant = BIOME_TILESETS.get("peaks", null)
	return ts != null and ts.walls_available()


static func make_peaks_walls(half: Vector2, exit_dir: Vector2, gate_positions: Array,
		seed_val: int, layout: RefCounted = null, is_cave: bool = false,
		gate_exit_types: Array = []) -> Node2D:
	if is_cave:
		return BIOME_TILESETS["peaks"].make_walls_cave(half, exit_dir, gate_positions, seed_val, layout, gate_exit_types)
	return BIOME_TILESETS["peaks"].make_walls(half, exit_dir, gate_positions, seed_val, layout, gate_exit_types)


# Retint the animated ocean shader to the Beach Tileset's water palette so the
# sea + sand skirt around the tiled island read as one coast.
static func _tune_ocean_for_beach(ocean: ColorRect) -> void:
	var mat: ShaderMaterial = ocean.material as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("void_mode", 0.0)
	mat.set_shader_parameter("col_skirt", BT.C_SAND)
	mat.set_shader_parameter("col_wet", BT.C_SAND.darkened(0.20))
	mat.set_shader_parameter("col_foam", BT.C_FOAM)
	mat.set_shader_parameter("col_light", BT.C_SHORE)
	mat.set_shader_parameter("col_mid", BT.C_MID)
	mat.set_shader_parameter("col_deep", BT.C_DEEP)


# Retint the backdrop so the world beyond the cavern's lava moat reads as an endless
# dark molten lake (ember crackle on the "surf" line) instead of blue sea.
static func _tune_ocean_for_caverns(ocean: ColorRect) -> void:
	var mat: ShaderMaterial = ocean.material as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("void_mode", 0.0)
	mat.set_shader_parameter("col_skirt", Color(0.16, 0.10, 0.10))   # charred rock ring
	mat.set_shader_parameter("col_wet", Color(0.10, 0.06, 0.07))
	mat.set_shader_parameter("col_foam", Color(0.98, 0.45, 0.10))    # ember crackle line
	mat.set_shader_parameter("col_light", Color(0.55, 0.10, 0.03))   # molten glow
	mat.set_shader_parameter("col_mid", Color(0.22, 0.05, 0.04))
	mat.set_shader_parameter("col_deep", Color(0.07, 0.03, 0.04))    # near-black depths


# Retint the backdrop so the frostpeak apron reads as snowy/icy terrain,
# not a warm beach.  Snow white → icy blue → dark frost.
static func _tune_ocean_for_peaks(ocean: ColorRect) -> void:
	var mat: ShaderMaterial = ocean.material as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("void_mode", 0.0)
	mat.set_shader_parameter("col_skirt", Color(0.82, 0.86, 0.92))   # snowy ground ring
	mat.set_shader_parameter("col_wet", Color(0.62, 0.68, 0.78))     # frozen slush
	mat.set_shader_parameter("col_foam", Color(0.94, 0.97, 1.00))    # frost foam
	mat.set_shader_parameter("col_light", Color(0.38, 0.52, 0.68))   # icy shimmer
	mat.set_shader_parameter("col_mid", Color(0.18, 0.28, 0.42))     # deep frost
	mat.set_shader_parameter("col_deep", Color(0.08, 0.12, 0.22))    # near-black frozen depths


# Retint the backdrop so the jungle surround reads as dense dark jungle floor
# instead of blue ocean. Earthy greens + muted foam so it blends with the arena.
static func _tune_ocean_for_jungle(ocean: ColorRect) -> void:
	var mat: ShaderMaterial = ocean.material as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("void_mode", 0.0)
	mat.set_shader_parameter("col_skirt", Color(0.18, 0.28, 0.10))   # dark mossy ground ring
	mat.set_shader_parameter("col_wet", Color(0.14, 0.22, 0.08))     # damp earth
	mat.set_shader_parameter("col_foam", Color(0.24, 0.36, 0.14))    # vine-line highlight
	mat.set_shader_parameter("col_light", Color(0.16, 0.26, 0.10))   # dim jungle floor
	mat.set_shader_parameter("col_mid", Color(0.10, 0.16, 0.06))     # deep undergrowth
	mat.set_shader_parameter("col_deep", Color(0.05, 0.08, 0.03))    # near-black canopy shadow


# ---------------------------------------------------------------------------
# Starry backdrop — animated deep-space sky behind everything.
# ---------------------------------------------------------------------------
# Loads the 9 sliced panels from Starry/starry_1..9.png, builds a
# SpriteFrames animation that cycles slowly, and tiles the panel large
# enough to cover the full ocean extent. The ocean shader draws OVER this
# so the stars only peek through at the outermost edges.
static func _make_starry_backdrop(half: Vector2, seed_val: int) -> Node2D:
	# Load all available panels.
	var frames: Array = []   # Array[Texture2D]
	for i in range(1, STARRY_COUNT + 1):
		var path: String = STARRY_DIR + "starry_" + str(i) + ".png"
		var tex: Texture2D = null
		if ResourceLoader.exists(path):
			tex = ResourceLoader.load(path) as Texture2D
		if tex == null:
			# Fallback: raw image load (pre-import).
			var img := Image.new()
			if img.load(path.replace("res://", "")) == OK or img.load(ProjectSettings.globalize_path(path)) == OK:
				tex = ImageTexture.create_from_image(img)
		if tex != null:
			frames.append(tex)
	if frames.is_empty():
		return null

	# Build SpriteFrames with all panels as a looping animation.
	var sf := SpriteFrames.new()
	sf.remove_animation("default")
	sf.add_animation("stars")
	sf.set_animation_loop("stars", true)
	sf.set_animation_speed("stars", STARRY_FPS)
	for tex in frames:
		sf.add_frame("stars", tex)

	# Size the backdrop to cover well beyond the ocean margin.
	var cover: Vector2 = half + Vector2(OCEAN_MARGIN + 200.0, OCEAN_MARGIN + 200.0)
	var panel_w: float = (frames[0] as Texture2D).get_width()
	var panel_h: float = (frames[0] as Texture2D).get_height()
	var sx: float = (cover.x * 2.0) / panel_w
	var sy: float = (cover.y * 2.0) / panel_h
	var sc: float = max(sx, sy)   # uniform scale, covers both axes

	var spr := AnimatedSprite2D.new()
	spr.name = "StarryBackdrop"
	spr.sprite_frames = sf
	spr.animation = "stars"
	spr.z_index = STARRY_Z
	spr.scale = Vector2(sc, sc)
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	spr.play("stars")

	# Seed-based starting frame so each room gets a different sky.
	spr.frame = seed_val % frames.size()

	return spr


# ---------------------------------------------------------------------------
# Ocean / dream-void backdrop (animated shader on a ColorRect)
# ---------------------------------------------------------------------------
static func _make_ocean(biome: Dictionary, land_half: Vector2,
		ocean_half: Vector2, seed_val: int, style: String,
		exit_dir: Vector2 = Vector2.ZERO, tip: bool = false) -> ColorRect:
	var rect := ColorRect.new()
	rect.name = "OceanLayer"
	rect.z_index = -40
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.offset_left = -ocean_half.x
	rect.offset_top = -ocean_half.y
	rect.offset_right = ocean_half.x
	rect.offset_bottom = ocean_half.y

	var fnl := FastNoiseLite.new()
	fnl.seed = seed_val
	fnl.frequency = 0.012
	fnl.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	var ntex := NoiseTexture2D.new()
	ntex.noise = fnl
	ntex.seamless = true
	ntex.width = 256
	ntex.height = 256

	var shader := Shader.new()
	shader.code = WATER_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("rect_size", ocean_half * 2.0)
	mat.set_shader_parameter("island_half", land_half)
	mat.set_shader_parameter("px_size", OCEAN_PX)
	mat.set_shader_parameter("noise_tex", ntex)
	# Star-arm strip: travel axis gets land both ways; flanks get sea.
	if exit_dir != Vector2.ZERO:
		var axis: Vector2 = exit_dir.normalized()
		var perp := Vector2(-axis.y, axis.x)
		var strip_half: float = abs(perp.x) * land_half.x + abs(perp.y) * land_half.y
		var tip_cap: float = 99999.0
		if tip:
			tip_cap = abs(axis.x) * land_half.x + abs(axis.y) * land_half.y
		mat.set_shader_parameter("axis", axis)
		mat.set_shader_parameter("strip_half", strip_half)
		mat.set_shader_parameter("tip_cap", tip_cap)

	var floor_col: Color = biome.get("floor", Color(0.3, 0.3, 0.3))
	if style == "void":
		mat.set_shader_parameter("void_mode", 1.0)
		mat.set_shader_parameter("col_skirt", floor_col.darkened(0.45))
		mat.set_shader_parameter("col_wet", floor_col.darkened(0.62))
		mat.set_shader_parameter("col_foam", Color(0.88, 0.83, 0.97))
		mat.set_shader_parameter("col_light", Color(0.21, 0.16, 0.35))
		mat.set_shader_parameter("col_mid", Color(0.13, 0.10, 0.22))
		mat.set_shader_parameter("col_deep", Color(0.07, 0.05, 0.12))
	else:
		var accent: Color = biome.get("accent", Color(0.3, 0.7, 0.9))
		var sand: Color = floor_col.lerp(Color(0.80, 0.72, 0.50), 0.55)
		mat.set_shader_parameter("void_mode", 0.0)
		mat.set_shader_parameter("col_skirt", sand)
		mat.set_shader_parameter("col_wet", sand.darkened(0.28))
		mat.set_shader_parameter("col_foam", Color(0.92, 0.96, 1.00))
		mat.set_shader_parameter("col_light", Color(0.24, 0.52, 0.78).lerp(accent, 0.18))
		mat.set_shader_parameter("col_mid", Color(0.13, 0.34, 0.58).lerp(accent, 0.10))
		mat.set_shader_parameter("col_deep", Color(0.07, 0.20, 0.40))
	rect.material = mat
	return rect


# ---------------------------------------------------------------------------
# Ground — generated pixel image (noise tones + tile seams + motifs)
# ---------------------------------------------------------------------------
static func _make_ground(biome_id: String, biome: Dictionary, half: Vector2,
		seed_val: int, layout: RefCounted = null, skip_baked_props: bool = false) -> Sprite2D:
	var spr := Sprite2D.new()
	spr.name = "TerrainGround"
	spr.z_index = -35
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.scale = Vector2(TEXEL, TEXEL)
	spr.texture = _ground_texture(biome_id, biome, half, seed_val, layout, skip_baked_props)
	return spr


# Run 50 pipeline — CrossCode-style ground:
#   1. 6-step hue-shifted palette ramp (shadows cool toward wall, lights warm)
#   2. macro + detail noise → continuous tone, Bayer-dithered onto the ramp
#   3. fine grain speckle (pushes lone texels up/down the ramp)
#   4. organic noise-wobbled edge lip (replaces straight vignette; NO grid seams)
#   5. scattered tufts / stipple strokes / accent flecks (hand-placed feel)
#   6. biome motif stamps at 1×/2× with drop shadows
# Run 51: mask-aware renderer. With a DreamLayout, blocked cells render as
# RAISED terrain (cliff tops) with vertical cliff FACES where they meet the
# floor to the south — the CrossCode height read. Rivers get water + foam +
# plank bridges. Without a layout (hub), falls back to the open-field look.
const CELL_TEXELS: int = 16    # 32px cell / TEXEL(2)

static func _ground_texture(biome_id: String, biome: Dictionary, half: Vector2,
		seed_val: int, layout: RefCounted = null, skip_baked_props: bool = false) -> ImageTexture:
	var w: int = int(ceil(half.x * 2.0 / float(TEXEL)))
	var h: int = int(ceil(half.y * 2.0 / float(TEXEL)))
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)

	var wallc: Color = biome.get("wall", (biome.get("floor", Color(0.3, 0.3, 0.3)) as Color).darkened(0.4))
	# Run 52: two DEFINED materials per biome (sand+grass, rock+emberglass…)
	# instead of one generic noise ramp — patches read as actual stuff.
	var mats: Array = _materials(biome_id, biome)
	# Raised-surface ramp (cliff tops / dense overgrowth).
	var wramp: Array = [wallc.darkened(0.30), wallc.darkened(0.14), wallc, wallc.lightened(0.12)]
	var face: Color = wallc.darkened(0.05).lerp(Color(0.32, 0.26, 0.22), 0.25)   # cliff face
	# River palette per biome (lava in the caverns, chocolate on the cake!).
	var rc: Color
	match biome_id:
		"swamp":   rc = Color(0.23, 0.34, 0.22)
		"caverns": rc = Color(0.80, 0.32, 0.08)
		"peaks":   rc = Color(0.55, 0.75, 0.95)
		"cake":    rc = Color(0.38, 0.24, 0.14)
		_:         rc = Color(0.22, 0.45, 0.70)
	var plank: Color = Color(0.48, 0.34, 0.20)

	# Noise octaves generated in C++ via FastNoiseLite.get_image() — fast
	# even at texel=2. Detail features enlarged (0.035) — less grainy.
	var macro_img: Image = _noise_image(seed_val, 0.012, w, h, FastNoiseLite.TYPE_SIMPLEX_SMOOTH)
	var detail_img: Image = _noise_image(seed_val * 3 + 1, 0.035, w, h, FastNoiseLite.TYPE_VALUE_CUBIC)
	var grain_img: Image = _noise_image(seed_val * 7 + 2, 0.45, w, h, FastNoiseLite.TYPE_VALUE)
	var edge_img: Image = _noise_image(seed_val * 11 + 3, 0.08, w, h, FastNoiseLite.TYPE_SIMPLEX_SMOOTH)

	var outline: Color = wallc.darkened(0.35)
	for y in range(h):
		for x in range(w):
			var m: float = macro_img.get_pixel(x, y).r           # material zones
			var t: float = m * 0.30 + detail_img.get_pixel(x, y).r * 0.70   # tone
			var dth: float = (float(BAYER[y % 4][x % 4]) / 16.0 - 0.5) * 0.7
			var g: float = grain_img.get_pixel(x, y).r
			var col: Color

			if layout == null:
				# Open-field fallback (hub): floor everywhere + wobbled rim.
				col = _material_tone(mats, m, t, dth, g, x, y, grain_img)
				var edge: int = min(min(x, w - 1 - x), min(y, h - 1 - y))
				var band: float = 3.0 + edge_img.get_pixel(x, y).r * 7.0
				if edge < 2:
					col = outline
				elif float(edge) < band and (band - float(edge)) / band + dth * 0.6 > 0.42:
					col = col.lerp(wallc, 0.62)
				img.set_pixel(x, y, col)
				continue

			# --- Mask-aware path -------------------------------------------
			var ci: int = x / CELL_TEXELS
			var cj: int = y / CELL_TEXELS
			var lx: int = x % CELL_TEXELS
			var ly: int = y % CELL_TEXELS
			var v: int = layout.val(ci, cj)
			var vn: int = layout.val(ci, cj - 1)
			var vs: int = layout.val(ci, cj + 1)
			var vw: int = layout.val(ci - 1, cj)
			var ve: int = layout.val(ci + 1, cj)

			if v == 2:                                     # V_WATER
				var wt: float = t + dth * 0.4
				col = rc.darkened(0.25) if wt < 0.40 else (rc if wt < 0.72 else rc.lightened(0.18))
				if g > 0.975:
					col = rc.lightened(0.45)               # sparkle
				# Foam ring against any non-water neighbor.
				if (vn != 2 and ly < 2) or (vs != 2 and ly > 13) \
				or (vw != 2 and lx < 2) or (ve != 2 and lx > 13):
					col = rc.lightened(0.55).lerp(Color(0.95, 0.97, 1.0), 0.4)
				img.set_pixel(x, y, col)
				continue

			if v == 3:                                     # V_BRIDGE — planks
				col = plank if (ly % 4 != 0) else plank.darkened(0.30)
				if g > 0.93:
					col = plank.lightened(0.12)            # wood grain flecks
				if (vn == 2 and ly == 0) or (vs == 2 and ly == 15) \
				or (vw == 2 and lx == 0) or (ve == 2 and lx == 15):
					col = plank.darkened(0.45)             # rail edge
				img.set_pixel(x, y, col)
				continue

			if v == 0:                                     # V_VOID — raised top
				var wt2: float = macro_img.get_pixel(x, y).r * 0.5 + detail_img.get_pixel(x, y).r * 0.5
				var wi: int = clamp(int(wt2 * 4.0 + dth), 0, 3)
				col = wramp[wi]
				if g > 0.965:
					col = col.darkened(0.35)               # cracks / leaf shadow
				var s_open: bool = (vs == 1 or vs == 3)
				if s_open and ly >= 13:
					col = col.lightened(0.30 if ly == 15 else 0.16)   # sunlit lip
				if (vn == 1 or vn == 3) and ly <= 1:
					col = col.darkened(0.22)               # back edge
				if (vw == 1 or vw == 3) and lx <= 1:
					col = col.darkened(0.15)
				if (ve == 1 or ve == 3) and lx >= 14:
					col = col.lightened(0.10)
				img.set_pixel(x, y, col)
				continue

			# V_FLOOR — walkable ground.
			col = _material_tone(mats, m, t, dth, g, x, y, grain_img)
			var n_raised: bool = (vn == 0)
			if n_raised and ly < 6:
				# Vertical cliff FACE spilling down from the raised cell above —
				# this is what sells the height.
				var streak: float = grain_img.get_pixel(x - (x % 3), y).r
				col = face.darkened(0.10 + streak * 0.18)
				if ly == 5:
					col = face.darkened(0.50)              # crevice line
				elif ly == 0:
					col = face.lightened(0.10)
			elif n_raised and ly < 9:
				col = col.darkened(lerp(0.30, 0.10, float(ly - 6) / 3.0))   # AO under cliff
			elif vn == 2 and ly < 2:
				col = col.darkened(0.18)                   # bank above water
			if vs == 0 and ly >= 14:
				col = col.darkened(0.12 if ly == 14 else 0.22)
			if vw == 0 and lx < 3:
				col = col.darkened(0.28 - 0.09 * float(lx))
			if ve == 0 and lx >= 13:
				col = col.darkened(0.06 * float(lx - 12))
			if (vw == 2 and lx < 2) or (ve == 2 and lx > 13):
				col = col.lightened(0.14)                  # wet sandy bank
			img.set_pixel(x, y, col)

	_scatter_tufts(img, biome, seed_val, layout)
	_stamp_motifs(img, biome_id, biome, seed_val, layout)
	if layout != null and not skip_baked_props:
		_bake_props(img, biome_id, biome, seed_val, layout)
	return ImageTexture.create_from_image(img)


# ---------------------------------------------------------------------------
# Props — biome trees ringing the cliffs + boulders in the walk space.
# Baked into the ground texture (blocked cells already collide, so no
# separate bodies needed for the ring; boulders collide via the layout).
# ---------------------------------------------------------------------------
static func _bake_props(img: Image, biome_id: String, biome: Dictionary,
		seed_val: int, layout: RefCounted) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 31337 + 11
	var kind: String = String(biome.get("tree", "canopy"))
	var accent: Color = biome.get("accent", Color(0.5, 0.7, 0.4))
	var wallc: Color = biome.get("wall", Color(0.3, 0.3, 0.3))

	# Boulders inside the walk space (real obstacles from the layout).
	for c in layout.rock_spots:
		_draw_boulder(img, (c as Vector2i).x * CELL_TEXELS + 8, (c as Vector2i).y * CELL_TEXELS + 8, wallc, rng)

	# Tree ring: raised cells that touch the floor get foliage (skips ~5/6).
	var used: Dictionary = {}
	for cj in range(layout.gh):
		for ci in range(layout.gw):
			if layout.val(ci, cj) != 0:
				continue
			var touches: bool = false
			for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nv: int = layout.val(ci + off.x, cj + off.y)
				if nv == 1 or nv == 3:
					touches = true
					break
			var chance: float = 0.18 if touches else 0.05
			if rng.randf() > chance:
				continue
			if used.has(Vector2i(ci, cj - 1)) or used.has(Vector2i(ci - 1, cj)):
				continue                   # breathing room between canopies
			used[Vector2i(ci, cj)] = true
			_draw_tree(img, kind, ci * CELL_TEXELS + 8, cj * CELL_TEXELS + 6, accent, wallc, rng)


static func _px(img: Image, x: int, y: int, c: Color) -> void:
	if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
		img.set_pixel(x, y, c)


static func _darken_px(img: Image, x: int, y: int, amt: float) -> void:
	if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
		img.set_pixel(x, y, img.get_pixel(x, y).darkened(amt))


static func _draw_boulder(img: Image, cx: int, cy: int, wallc: Color,
		rng: RandomNumberGenerator) -> void:
	var rock: Color = wallc.lerp(Color(0.52, 0.52, 0.55), 0.45)
	var rx: int = rng.randi_range(5, 6)
	var ry: int = rx - 1
	for dy in range(-ry, ry + 1):
		for dx in range(-rx, rx + 1):
			var d: float = pow(float(dx) / float(rx), 2) + pow(float(dy) / float(ry), 2)
			if d > 1.0:
				continue
			var col: Color = rock
			if dx - dy < -3:
				col = rock.lightened(0.22)             # top-left light
			elif dx - dy > 3 or dy >= ry - 1:
				col = rock.darkened(0.28)              # bottom-right shade
			if d > 0.82:
				col = rock.darkened(0.45)              # outline
			if rng.randf() < 0.05:
				col = col.darkened(0.18)               # pock marks
			_px(img, cx + dx, cy + dy, col)
	for dx in range(-rx, rx + 1):                      # contact shadow
		_darken_px(img, cx + dx, cy + ry + 1, 0.25)


static func _draw_tree(img: Image, kind: String, cx: int, cy: int,
		accent: Color, wallc: Color, rng: RandomNumberGenerator) -> void:
	var trunk: Color = Color(0.34, 0.23, 0.13)
	match kind:
		"palm":
			for k in range(8):                         # curved trunk
				_px(img, cx + k / 3, cy + 6 - k, trunk)
				_px(img, cx + k / 3 + 1, cy + 6 - k, trunk.darkened(0.2))
			var topx: int = cx + 2
			var topy: int = cy - 2
			for ang in [-2.6, -1.9, -1.2, -0.5, 0.2]:  # splayed fronds
				var fc: Color = Color(0.30, 0.62, 0.25) if rng.randf() < 0.5 else Color(0.40, 0.72, 0.30)
				for k2 in range(6):
					var fx: int = topx + int(round(cos(ang) * float(k2)))
					var fy: int = topy + int(round(sin(ang) * float(k2) * 0.6))
					_px(img, fx, fy, fc)
					if k2 > 2:
						_px(img, fx, fy + 1, fc.darkened(0.25))
			_px(img, topx, topy + 1, Color(0.45, 0.30, 0.15))   # coconuts
			_px(img, topx + 1, topy + 2, Color(0.45, 0.30, 0.15))
		"pine":
			var dgreen: Color = Color(0.13, 0.32, 0.18)
			var lgreen: Color = Color(0.20, 0.44, 0.24)
			var tier_w: Array = [7, 5, 3]
			for tier in range(3):
				var ty: int = cy + 3 - tier * 4
				var tw: int = tier_w[tier]
				for row in range(4):
					var rw: int = tw - row * 2
					if rw < 0:
						continue
					for dx in range(-rw, rw + 1):
						var col: Color = lgreen if dx < -rw / 2 else dgreen
						if tier == 2 and row >= 2:
							col = Color(0.90, 0.94, 1.0)       # snow cap
						_px(img, cx + dx, ty - row, col)
			_px(img, cx, cy + 4, trunk)
			_px(img, cx, cy + 5, trunk)
			for dx2 in range(-3, 4):
				_darken_px(img, cx + dx2, cy + 6, 0.22)
		"crystal":
			# Run 52: clean tapered stalagmites on a rocky base mound.
			var rock2: Color = wallc.lerp(Color(0.45, 0.42, 0.48), 0.4)
			for dx5 in range(-6, 7):                   # base mound
				_px(img, cx + dx5, cy + 4, rock2.darkened(0.15))
				if abs(dx5) < 5:
					_px(img, cx + dx5, cy + 3, rock2)
			for dx6 in range(-6, 7):                   # contact shadow
				_darken_px(img, cx + dx6, cy + 5, 0.25)
			for s in range(3):
				var sx: int = cx + [-4, 1, 4][s]
				var hgt: int = [8, 12, 6][s]
				var bw: float = [2.0, 3.0, 1.5][s]
				var sy: int = cy + 3
				for k3 in range(hgt):
					var f3: float = 1.0 - float(k3) / float(hgt)   # linear taper → spike
					var sw2: int = int(round(bw * f3))
					for dx3 in range(-sw2, sw2 + 1):
						var col2: Color
						if dx3 < 0:
							col2 = accent.lightened(0.35)          # lit left facet
						elif dx3 == sw2:
							col2 = accent.darkened(0.35)           # shaded right edge
						else:
							col2 = accent
						_px(img, sx + dx3, sy - k3, col2)
				_px(img, sx, sy - hgt, Color(1, 1, 1))             # glint tip
		"gnarl":
			_blob_canopy(img, cx, cy - 2, 6, Color(0.22, 0.34, 0.16), Color(0.30, 0.44, 0.20), rng)
			_px(img, cx - 1, cy + 4, trunk)
			_px(img, cx, cy + 4, trunk.darkened(0.15))
			_px(img, cx, cy + 5, trunk)
			for m in range(3):                         # hanging moss
				var mx: int = cx + rng.randi_range(-5, 5)
				for k4 in range(rng.randi_range(2, 4)):
					_px(img, mx, cy + 1 + k4, Color(0.38, 0.52, 0.28))
		"candy":
			var pink: Color = Color(0.95, 0.55, 0.75)
			for dy7 in range(-5, 2):
				for dx7 in range(-5, 6):
					var d2: float = pow(float(dx7) / 5.5, 2) + pow(float(dy7 + 2) / 4.0, 2)
					if d2 > 1.0:
						continue
					var col3: Color = pink if dx7 + dy7 > -3 else pink.lightened(0.25)
					if d2 > 0.8:
						col3 = pink.darkened(0.30)
					_px(img, cx + dx7, cy + dy7, col3)
			for _s2 in range(5):                       # sugar speckles
				_px(img, cx + rng.randi_range(-4, 4), cy + rng.randi_range(-4, 0), Color(1, 1, 1))
			for dx8 in range(-4, 5):
				_darken_px(img, cx + dx8, cy + 2, 0.22)
		_:
			_blob_canopy(img, cx, cy, 8, Color(0.16, 0.36, 0.14), Color(0.26, 0.50, 0.20), rng)


static func _blob_canopy(img: Image, cx: int, cy: int, r: int,
		dark: Color, lite: Color, rng: RandomNumberGenerator) -> void:
	for dx in range(-r, r + 1):                        # canopy ground shadow
		_darken_px(img, cx + dx, cy + r - 1, 0.20)
		_darken_px(img, cx + dx, cy + r, 0.28)
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var d: float = (float(dx * dx + dy * dy)) / float(r * r)
			if d > 1.0:
				continue
			var col: Color = lite if (dx - dy < -2 or (dx + dy * 2) % 4 == 0) else dark
			if d > 0.78:
				col = dark.darkened(0.35)              # rim
			if rng.randf() < 0.04:
				col = lite.lightened(0.25)             # leaf glints
			_px(img, cx + dx, cy + dy - 2, col)


# ---------------------------------------------------------------------------
# Run 52 — biome MATERIALS. Macro noise splits the floor into a primary
# material and secondary patches, each with its own 4-step ramp and a
# signature pixel pattern (sand ripples, grass blades, earth cracks, rock
# fissures…). Patches get a dark trim + inner highlight so they read as
# clearly-outlined "stuff" instead of tone noise — the CrossCode look.
# ---------------------------------------------------------------------------
const MAT_SPLIT: float = 0.57

static func _materials(biome_id: String, biome: Dictionary) -> Array:
	var base: Color = biome.get("floor", Color(0.3, 0.3, 0.3))
	var alt: Color = biome.get("floor_alt", base.lightened(0.08))
	var wallc: Color = biome.get("wall", base.darkened(0.4))
	match biome_id:
		"beach":
			return [_mat(base, wallc, "sand"), _mat(Color(0.42, 0.58, 0.28), wallc, "grass")]
		"jungle":
			return [_mat(base, wallc, "grass"), _mat(Color(0.32, 0.24, 0.14), wallc, "earth")]
		"swamp":
			return [_mat(base, wallc, "muck"), _mat(Color(0.32, 0.44, 0.20), wallc, "moss")]
		"caverns":
			return [_mat(base, wallc, "rock"), _mat(alt.lerp(Color(0.55, 0.32, 0.68), 0.45), wallc, "glass")]
		"peaks":
			return [_mat(base, wallc, "snow"), _mat(Color(0.64, 0.82, 0.96), wallc, "ice")]
		"cake":
			return [_mat(base, wallc, "sponge"), _mat(Color(0.92, 0.72, 0.80), wallc, "frosting")]
		_:
			return [_mat(base, wallc, "earth"), _mat(alt, wallc, "grass")]


static func _mat(c: Color, wallc: Color, kind: String) -> Dictionary:
	return {"kind": kind, "ramp": [
		c.darkened(0.22).lerp(wallc, 0.18),
		c.darkened(0.10),
		c,
		c.lightened(0.12).lerp(Color(1.0, 0.97, 0.85), 0.06),
	]}


static func _material_tone(mats: Array, m: float, t: float, dth: float, g: float,
		x: int, y: int, grain_img: Image) -> Color:
	var sec: bool = m > MAT_SPLIT
	var mat: Dictionary = mats[1] if sec else mats[0]
	var ramp: Array = mat["ramp"]
	var idx: int = clamp(int(t * 4.0 + dth), 0, 3)
	var col: Color = ramp[idx]
	match String(mat["kind"]):
		"sand":
			# Wind ripples — long curving dark lines with a lit crest.
			var ph: int = int(float(y) + t * 9.0 + sin(float(x) * 0.11) * 2.6)
			if ph % 8 == 0:
				col = col.darkened(0.16)
			elif ph % 8 == 1:
				col = col.lightened(0.10)
		"grass":
			# 2-texel blades: dark stem, lit tip above it.
			if g > 0.90:
				col = ramp[0]
			elif y + 1 < grain_img.get_height() and grain_img.get_pixel(x, y + 1).r > 0.90:
				col = (ramp[3] as Color).lightened(0.08)
		"earth":
			if abs(t - 0.50) < 0.016:
				col = (ramp[0] as Color).darkened(0.18)     # dry cracks
			elif g > 0.965:
				col = ramp[3]                                # pebbles
		"muck":
			if int(float(y) + t * 6.0) % 9 == 0:
				col = col.lightened(0.10)                    # wet sheen bands
			if g > 0.975:
				col = col.lightened(0.22)                    # bog bubble
		"moss":
			if g > 0.92:
				col = ramp[0]
			elif g < 0.05:
				col = ramp[3]
		"rock":
			if abs(t - 0.52) < 0.014:
				col = (ramp[0] as Color).darkened(0.25)      # fissures
			elif g > 0.985:
				col = Color(0.95, 0.90, 1.00)                # ember-glass glint
		"glass":
			if (x - y) % 11 == 0:
				col = col.lightened(0.14)                    # facet shimmer
			if g > 0.97:
				col = Color(1, 1, 1)
		"snow":
			if g > 0.97:
				col = Color(1, 1, 1)                         # sparkle
			elif g < 0.04:
				col = ramp[1]
		"ice":
			if (x + y * 2) % 9 == 0:
				col = col.lightened(0.16)                    # pressure streaks
			if g > 0.975:
				col = Color(0.98, 1.00, 1.00)
		"sponge":
			if g > 0.93:
				col = (ramp[0] as Color).darkened(0.10)      # crumb pores
		"frosting":
			if sin(float(x) * 0.30 + float(y) * 0.55 + t * 6.0) > 0.92:
				col = col.lightened(0.18)                    # piped swirls
	# Patch trim — dark outline + inner highlight makes patches read as
	# deliberate, hand-placed shapes.
	var band: float = abs(m - MAT_SPLIT)
	if band < 0.012:
		col = (mats[1]["ramp"][0] as Color).darkened(0.30)
	elif band < 0.026 and sec:
		col = (mats[1]["ramp"][3] as Color).lightened(0.10)
	return col


static func _noise_image(seed_val: int, freq: float, w: int, h: int, type: int) -> Image:
	var fnl := FastNoiseLite.new()
	fnl.seed = seed_val
	fnl.frequency = freq
	fnl.noise_type = type
	return fnl.get_image(w, h)


# 6-step palette ramp with hue shifting — shadows pull toward the (cool)
# wall color, highlights pull toward warm cream. The single biggest "pro
# pixel art" tell vs. plain darken/lighten of one hue.
static func _ramp(biome: Dictionary) -> Array:
	var base: Color = biome.get("floor", Color(0.3, 0.3, 0.3))
	var alt: Color = biome.get("floor_alt", base.lightened(0.08))
	var wallc: Color = biome.get("wall", base.darkened(0.4))
	return [
		base.darkened(0.26).lerp(wallc, 0.30),
		base.darkened(0.12).lerp(wallc, 0.12),
		base,
		base.lerp(alt, 0.6),
		alt.lightened(0.05),
		alt.lightened(0.14).lerp(Color(1.0, 0.97, 0.85), 0.10),
	]


# Scattered micro-detail: grass tufts, stipple strokes, accent flecks.
# This is what makes Stardew ground feel hand-touched instead of tiled.
static func _scatter_tufts(img: Image, biome: Dictionary, seed_val: int,
		layout: RefCounted = null) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 104729 + 7
	var w: int = img.get_width()
	var h: int = img.get_height()
	var base: Color = biome.get("floor", Color(0.3, 0.3, 0.3))
	var accent: Color = biome.get("accent", Color(0.8, 0.8, 0.3))
	var dark: Color = base.darkened(0.34)
	var mid: Color = base.darkened(0.18)
	var lite: Color = base.lightened(0.22)
	var count: int = int(float(w * h) / 420.0)
	for _i in range(count):
		var x: int = rng.randi_range(4, w - 6)
		var y: int = rng.randi_range(4, h - 6)
		if layout != null and layout.val(x / CELL_TEXELS, y / CELL_TEXELS) != 1:
			continue                       # ground detail only on open floor
		var roll: float = rng.randf()
		if roll < 0.45:
			# Tuft — dark V with a light tip.
			img.set_pixel(x, y, dark)
			img.set_pixel(x + 1, y - 1, dark)
			img.set_pixel(x - 1, y - 1, dark)
			img.set_pixel(x, y - 1, lite)
		elif roll < 0.80:
			# Stipple stroke (worn ground / scratch).
			var len2: int = rng.randi_range(2, 4)
			for k in range(len2):
				img.set_pixel(x + k, y, dark if k % 2 == 0 else mid)
		else:
			# Accent fleck — tiny flower / shell / crystal glint.
			img.set_pixel(x, y, accent.lightened(0.2))
			img.set_pixel(x + 1, y, accent.darkened(0.15))
			img.set_pixel(x, y + 1, accent.darkened(0.30))


static func _stamp_motifs(img: Image, biome_id: String, biome: Dictionary,
		seed_val: int, layout: RefCounted = null) -> void:
	var motifs: Array = MOTIFS.get(biome_id, MOTIFS["hub"])
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 7919 + 13

	var base: Color = biome.get("floor", Color(0.3, 0.3, 0.3))
	var accent_c: Color = biome.get("accent", Color(0.8, 0.8, 0.3))
	var palette: Dictionary = {
		"a": accent_c,
		"h": accent_c.lightened(0.35),     # lit facet / glow
		"d": base.darkened(0.30),
		"l": base.lightened(0.25),
		"k": (biome.get("wall", base.darkened(0.4)) as Color).darkened(0.25),
		"w": Color(0.93, 0.93, 0.90),
	}

	var w: int = img.get_width()
	var h: int = img.get_height()
	var shadow: Color = base.darkened(0.38)
	var count: int = int(float(w * h) / 520.0) + 6
	for _i in range(count):
		var m: Array = motifs[rng.randi() % motifs.size()]
		var mw: int = (m[0] as String).length()
		var mh: int = m.size()
		# 60% feature-size (2× texels, with drop shadow), 40% small debris (1×).
		var sc: int = 2 if rng.randf() < 0.6 else 1
		var ox: int = rng.randi_range(8, max(8, w - mw * sc - 9))
		var oy: int = rng.randi_range(8, max(8, h - mh * sc - 9))
		if layout != null and layout.val(ox / CELL_TEXELS, oy / CELL_TEXELS) != 1:
			continue                       # motifs only decorate open floor
		if sc == 2:
			# Drop shadow pass first — grounds the prop on the floor.
			for ry in range(mh):
				var srow: String = m[ry]
				for rx in range(srow.length()):
					if srow[rx] == ".":
						continue
					for sy in range(2):
						for sx in range(2):
							var px: int = ox + rx * 2 + sx + 1
							var py: int = oy + ry * 2 + sy + 1
							if px < w and py < h:
								img.set_pixel(px, py, shadow)
		for ry in range(mh):
			var row: String = m[ry]
			for rx in range(row.length()):
				var ch: String = row[rx]
				if ch == "." or not palette.has(ch):
					continue
				for sy in range(sc):
					for sx in range(sc):
						var px: int = ox + rx * sc + sx
						var py: int = oy + ry * sc + sy
						if px < w and py < h:
							img.set_pixel(px, py, palette[ch])
