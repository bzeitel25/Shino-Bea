extends RefCounted

# ============================================================
# TownArt.gd — Run 169 (2026-08-20) — hand-authored Town Square
# ============================================================
# Bruno, Run 169: "I see a bunch of little grey lines still scattered around
# the town tiles and path ... make the town look like one piece rather than a
# quilt that was stitched together." Then, with the art in hand: "I added the 4
# full town tiers, I think it looks better like this rather than stitched."
#
# So the square is no longer assembled from 32px tiles at all. Each healing
# tier is ONE hand-authored 2496x1724 image covering the whole scene: the
# plaza stone, the road network, the raked-sand centre, the shopfronts along
# the north, the fence on all four sides and the water beyond it — day and
# night versions of each. This file places that image; TownBuild decides when.
#
# WHAT WAS ACTUALLY WRONG (do not go back to the tile bake):
#   * the grey lines were sprite-sheet grid ruling that survived the Run 144
#     crops — full-height blue-grey columns in pave_b (76-78), pave_c (74),
#     pave_d (72-74), pave_crack_a (12-14), pave_crack_c (0-2), pave_weed_a (0),
#     pave_weed_b (0-1, 78-80) and healing/ground_cobble_a (77-78). Stamped
#     every 32px they read as thin grey lines everywhere.
#   * the quilt was the 32px stamp LATTICE itself. Those tiles are not
#     seamless, so every cell boundary showed. Cleaning the tiles cannot fix
#     that — only not stamping a lattice can.
# `tools/clean_town_tiles.py` repairs the tiles anyway, because
# TownTileset.build_ground is still the fallback when a tier has no art, and
# because the same tiles feed the placed props.
#
# ---------------------------------------------------------------------------
# GEOMETRY — the one thing that must never drift
# ---------------------------------------------------------------------------
# The images are 2496x1724, but only the fenced PLAYABLE INTERIOR maps onto the
# arena. Measured off the art (fence posts left and right, the plaza edge under
# the shopfronts, the top rail of the south fence):
#
#       interior = x [58, 2438]  (2380 px)   y [330, 1590]  (1260 px)
#
# All eight images were checked against each other by edge cross-correlation
# and align at ZERO offset, so this one rect serves every tier.
#
# That interior is stretched onto the arena, which is what puts the five
# painted road spokes under the five torii, the south spine under the carnival
# arch and the painted fence on the collision walls. The rest of the image
# (shopfronts above, water below and to the sides) deliberately spills OUTSIDE
# the arena — it replaces TownTileset.facade_strip and the Wood_Scaffolding
# wall art.
#
# The interior aspect (1.889) is not quite the arena aspect (1.775), so the
# scale is very slightly anisotropic (~6% on Y). At this size that is
# invisible; matching it exactly would mean moving TownBuild.HALF_W, which
# would drag the gate clamps, the shop row and every prop coordinate with it.
# ⚠ Nothing here needs editing if HALF_W / HALF_H change — the mapping is
# recomputed from `half` every call. It is the INTERIOR constants that are art
# facts, and they only change if the art changes.
#
# ⚠ Open Godot once after adding tier art so the .jpg is imported; `Image.load`
# is only a pre-import fallback and does not work in an exported build.
# ============================================================

const ART_DIR: String = "res://Assets/Tilesets/"

const SRC_W: float = 2496.0
const SRC_H: float = 1724.0
const INT_X: float = 58.0
const INT_Y: float = 330.0
const INT_W: float = 2380.0
const INT_H: float = 1260.0

# Art tier -> {night art, day art}. Tier order matches DayState.town_visual_tier():
#   0 Delapidated · 1 Under Construction · 2 Healing · 3 Fully Healed
# A blank entry means that variant is not drawn yet; the other one is used with
# a stand-in grade (see DAY_LIFT / NIGHT_FALLBACK_TINT) and the stand-in
# disappears by itself the moment a real file is named here.
const TIER_ART: Array = [
	{"night": "Town_Square_Delapidated_Full",       "day": "Town_Square_Delapidated_Full_Day"},
	{"night": "Town_Square_Underconstruction_Full", "day": "Town_Square_Underconstruction_Full_Day"},
	{"night": "Town_Square_Healing_Full",           "day": "Town_Square_Healing_Full_Day"},
	{"night": "Town_Square_Healed_Full_Night",      "day": "Town_Square_Healed_Full_Day"},
]

const EXTS: Array = [".jpg", ".png", ".jpeg", ".webp"]

# [TUNE] Stand-in grades for a tier that is missing one of its two variants.
const DAY_LIFT: Color = Color(1.62, 1.58, 1.42)
const NIGHT_FALLBACK_TINT: Color = Color(0.52, 0.58, 0.80)

# How much of RunState.NIGHT_TINT the CanvasModulate should still apply when the
# art is ALREADY night-graded. It cannot be zero: the heroes, the torii, the
# shop stands and the placed props all need grading or they float on top of the
# night picture looking like daylight cut-outs. The art itself is spared by
# multiplying the sprite by the reciprocal (see build()), the same cancel-back
# trick RunState documents next to NIGHT_TINT.
# [TUNE] 0 = art-only lighting, 1 = full night tint over everything.
const NIGHT_ART_TINT_MIX: float = 0.55

const GROUND_Z: int = -30

static var _tex_cache: Dictionary = {}      # "tier|night|w|h" -> ImageTexture
static var _corner_cache: Dictionary = {}   # "tier|night"     -> Color


# ---------------------------------------------------------------------------
# Resolution — which file backs (tier, night)?
# ---------------------------------------------------------------------------
static func _resolve(name: String) -> String:
	if name.is_empty():
		return ""
	for e in EXTS:
		var p: String = ART_DIR + name + String(e)
		if ResourceLoader.exists(p):
			return p
		if FileAccess.file_exists(ProjectSettings.globalize_path(p)):
			return p
	return ""


# {"path", "lift": night art shown by day, "dim": day art shown at night}
static func _pick(art_tier: int, night: bool) -> Dictionary:
	var miss: Dictionary = {"path": "", "lift": false, "dim": false}
	if TIER_ART.is_empty():
		return miss
	var e: Dictionary = TIER_ART[clampi(art_tier, 0, TIER_ART.size() - 1)]
	var day_p: String = _resolve(String(e.get("day", "")))
	var night_p: String = _resolve(String(e.get("night", "")))
	if night:
		if not night_p.is_empty():
			return {"path": night_p, "lift": false, "dim": false}
		return {"path": day_p, "lift": false, "dim": not day_p.is_empty()}
	if not day_p.is_empty():
		return {"path": day_p, "lift": false, "dim": false}
	return {"path": night_p, "lift": not night_p.is_empty(), "dim": false}


# True when hand-authored art exists for this tier — the caller uses this to
# decide whether to fall back to the old tile bake.
static func has_art(art_tier: int, night: bool) -> bool:
	return not String(_pick(art_tier, night)["path"]).is_empty()


# True when what is on screen is already night-graded art.
static func is_night_baked(art_tier: int, night: bool) -> bool:
	if not night:
		return false
	var p: Dictionary = _pick(art_tier, night)
	return not String(p["path"]).is_empty() and not bool(p["dim"])


# The colour the night CanvasModulate should use. Full strength when the square
# is built the old way; softened when the art already carries the night.
static func overlay_tint(art_tier: int, night: bool) -> Color:
	if not is_night_baked(art_tier, night):
		return RunState.NIGHT_TINT
	return Color(1, 1, 1).lerp(RunState.NIGHT_TINT, NIGHT_ART_TINT_MIX)


# ---------------------------------------------------------------------------
# Loading — ResourceLoader when imported, Image.load as a pre-import fallback
# (the same two-step TownTileset._load_img uses).
# ---------------------------------------------------------------------------
static func _load_image(path: String) -> Image:
	if path.is_empty():
		return null
	var img: Image = null
	if ResourceLoader.exists(path):
		var r: Resource = ResourceLoader.load(path)
		if r is Texture2D:
			img = (r as Texture2D).get_image()
	if img == null:
		var abs_path: String = ProjectSettings.globalize_path(path)
		if FileAccess.file_exists(abs_path):
			var im := Image.new()
			if im.load(abs_path) == OK:
				img = im
	if img != null:
		img.convert(Image.FORMAT_RGBA8)
	return img


# The colour of the world beyond the painted water — sampled from the image's
# own top-left corner, so each tier's out-of-bounds fill matches its own sky
# without a hand-kept table going stale every time the art is redrawn.
static func backdrop_color(art_tier: int, night: bool, fallback: Color) -> Color:
	var key: String = "%d|%d" % [art_tier, int(night)]
	if _corner_cache.has(key):
		return _corner_cache[key]
	var pick: Dictionary = _pick(art_tier, night)
	var img: Image = _load_image(String(pick["path"]))
	var c: Color = fallback
	if img != null and img.get_width() > 12 and img.get_height() > 12:
		var acc := Color(0, 0, 0)
		var n: int = 0
		for y in range(2, 10):
			for x in range(2, 10):
				acc += img.get_pixel(x, y)
				n += 1
		c = Color(acc.r / n, acc.g / n, acc.b / n)
		if bool(pick["lift"]):
			c = Color(minf(c.r * DAY_LIFT.r, 1.0), minf(c.g * DAY_LIFT.g, 1.0),
				minf(c.b * DAY_LIFT.b, 1.0))
		elif bool(pick["dim"]):
			c = c * NIGHT_FALLBACK_TINT
	_corner_cache[key] = c
	return c


# ---------------------------------------------------------------------------
# BUILD — one Sprite2D covering the whole square. Returns false when the tier
# has no art, and the caller then runs TownTileset.build_ground + facade_strip.
#
# Run 150 rule: HD art is pre-shrunk on the CPU with Lanczos to its DRAWN size
# so it renders 1:1 with no NEAREST minification crunch. At ~0.6x that is the
# difference between crisp stone and mush, and it also averages out most of the
# JPEG ringing in the source. Cached per (tier, night, size), so re-entering
# the square — or crossing between the day square and the dream square — costs
# nothing after the first bake.
# ---------------------------------------------------------------------------
static func build(parent: Node2D, half: Vector2, art_tier: int, night: bool) -> bool:
	var old: Node = parent.get_node_or_null("TownArt")
	if old:
		old.queue_free()

	var pick: Dictionary = _pick(art_tier, night)
	var path: String = String(pick["path"])
	if path.is_empty():
		return false

	var sx: float = (half.x * 2.0) / INT_W
	var sy: float = (half.y * 2.0) / INT_H
	var tw: int = maxi(1, int(round(SRC_W * sx)))
	var th: int = maxi(1, int(round(SRC_H * sy)))

	var key: String = "%d|%d|%d|%d" % [art_tier, int(night), tw, th]
	var tex: ImageTexture = _tex_cache.get(key, null)
	if tex == null:
		var img: Image = _load_image(path)
		if img == null:
			push_warning("[TownArt] Could not load %s" % path)
			return false
		if img.get_width() != tw or img.get_height() != th:
			var interp: int = Image.INTERPOLATE_LANCZOS if img.get_width() > tw else Image.INTERPOLATE_NEAREST
			img.resize(tw, th, interp)
		tex = ImageTexture.create_from_image(img)
		_tex_cache[key] = tex

	var spr := Sprite2D.new()
	spr.name = "TownArt"
	spr.texture = tex
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.z_index = GROUND_Z
	spr.z_as_relative = false
	# Line the INTERIOR's centre up with world origin. Sprite2D draws centred on
	# its texture, and the interior is NOT centred in the image (a tall band of
	# shopfronts above, only a sliver of water below) — this offset is what
	# stops the whole square sitting ~60px too low.
	spr.position = Vector2(
		float(tw) * 0.5 - (INT_X + INT_W * 0.5) * sx,
		float(th) * 0.5 - (INT_Y + INT_H * 0.5) * sy)

	if bool(pick["lift"]):
		spr.modulate = DAY_LIFT
	elif bool(pick["dim"]):
		spr.modulate = NIGHT_FALLBACK_TINT
	elif night:
		# Night-graded art under a softened CanvasModulate: multiply by the
		# reciprocal so the painting renders at exactly the brightness it was
		# drawn at, while everything else in the scene still takes the tint.
		var t: Color = overlay_tint(art_tier, night)
		spr.modulate = Color(1.0 / maxf(t.r, 0.01), 1.0 / maxf(t.g, 0.01), 1.0 / maxf(t.b, 0.01))

	parent.add_child(spr)
	return true


# ---------------------------------------------------------------------------
# PAINTED PROPS — collision, and keepouts for the placed props
#
# Bruno, Run 169: "for the assets already painted in - yes add collision boxes
# around those, keep those as is. We can find other areas to fill with our
# existing props too" / "avoid overlapping any props with other props or with
# the already-painted on town props."
#
# So every solid thing painted into the plaza gets a StaticBody here, AND is
# handed to TownTileset.build_props as a keepout so the placed props go
# somewhere else. One table per tier, because the tiers really do differ:
# Delapidated is a bare plaza (nothing painted — the placed props have the run
# of it), Under Construction has building materials, and the two healed tiers
# fill the edges with bonsai, chests, racks and a walled garden.
#
# [TUNE] world-space centre + size, read off the 100px world grid overlaid on
# each tier's DAY art (the night art aligns to it at zero offset). Anything
# painted ABOVE y = -400 is on the shopfront band, outside the arena, and is
# deliberately not listed.
# ---------------------------------------------------------------------------
const PAINTED_SOLIDS: Dictionary = {
	# 0 Delapidated — bare plaza, nothing painted inside the fence.
	0: [],
	# 1 Under Construction — building materials.
	1: [
		[Vector2(-380.0, -376.0), Vector2(100.0, 48.0)],   # cut stone blocks
		[Vector2(-152.0, -362.0), Vector2(78.0, 72.0)],    # tool bucket + rake
		[Vector2(28.0, -368.0), Vector2(108.0, 52.0)],     # hay bales
		[Vector2(575.0, -330.0), Vector2(152.0, 44.0)],    # bench under the scaffold
		[Vector2(672.0, -300.0), Vector2(86.0, 66.0)],     # wheelbarrow + rope
		[Vector2(655.0, 140.0), Vector2(114.0, 158.0)],    # gravel + sand + trough
		[Vector2(585.0, 315.0), Vector2(152.0, 62.0)],     # wheelbarrow + basket
	],
	# 2 Healing — the town is furnishing itself.
	2: [
		[Vector2(-160.0, -356.0), Vector2(102.0, 72.0)],   # tool bucket + basket
		[Vector2(35.0, -360.0), Vector2(112.0, 68.0)],     # covered cart
		[Vector2(575.0, -316.0), Vector2(170.0, 46.0)],    # stacked lumber
		[Vector2(712.0, -356.0), Vector2(56.0, 64.0)],     # potted palm
		[Vector2(690.0, -242.0), Vector2(106.0, 106.0)],   # chest + rope coils
		[Vector2(-682.0, -112.0), Vector2(64.0, 166.0)],   # tall west planter
		[Vector2(-680.0, 300.0), Vector2(106.0, 132.0)],   # west bonsai pots
		[Vector2(-535.0, 320.0), Vector2(130.0, 62.0)],    # bonsai pair
		[Vector2(-300.0, 320.0), Vector2(96.0, 58.0)],     # notice board
		[Vector2(-140.0, 322.0), Vector2(66.0, 56.0)],     # bonsai
		[Vector2(140.0, 322.0), Vector2(66.0, 56.0)],      # bonsai
		[Vector2(265.0, 318.0), Vector2(110.0, 62.0)],     # weapon rack
		[Vector2(410.0, 326.0), Vector2(116.0, 76.0)],     # chest
		[Vector2(630.0, 190.0), Vector2(162.0, 222.0)],    # brick enclosure
	],
	# 3 Fully Healed — same footprints, finished objects.
	3: [
		[Vector2(-160.0, -358.0), Vector2(102.0, 74.0)],   # tool bucket + basket
		[Vector2(35.0, -368.0), Vector2(122.0, 66.0)],     # gift boxes
		[Vector2(575.0, -318.0), Vector2(172.0, 46.0)],    # stacked lumber
		[Vector2(712.0, -358.0), Vector2(56.0, 64.0)],     # potted palm
		[Vector2(685.0, -256.0), Vector2(96.0, 68.0)],     # treasure chest
		[Vector2(-686.0, -110.0), Vector2(64.0, 166.0)],   # tall west planter
		[Vector2(-678.0, 296.0), Vector2(108.0, 132.0)],   # west bonsai pots
		[Vector2(-285.0, 318.0), Vector2(96.0, 58.0)],     # notice board
		[Vector2(-130.0, 324.0), Vector2(66.0, 56.0)],     # bonsai
		[Vector2(138.0, 324.0), Vector2(66.0, 56.0)],      # bonsai
		[Vector2(298.0, 320.0), Vector2(110.0, 62.0)],     # weapon rack
		[Vector2(435.0, 306.0), Vector2(118.0, 82.0)],     # treasure chest
		[Vector2(632.0, 192.0), Vector2(160.0, 224.0)],    # walled zen garden
	],
}


static func solids_for(art_tier: int) -> Array:
	return PAINTED_SOLIDS.get(clampi(art_tier, 0, 3), [])


static func build_collision(parent: Node2D, art_tier: int) -> void:
	var recs: Array = solids_for(art_tier)
	if recs.is_empty():
		return
	var host := Node2D.new()
	host.name = "TownArtSolids"
	parent.add_child(host)
	for rec in recs:
		var body := StaticBody2D.new()
		body.collision_layer = 1
		body.collision_mask = 0
		body.position = rec[0] as Vector2
		var cs := CollisionShape2D.new()
		var shape := RectangleShape2D.new()
		shape.size = rec[1] as Vector2
		cs.shape = shape
		body.add_child(cs)
		host.add_child(body)


# Keepouts for TownTileset.build_props, as RECTS. Circles were tried first and
# were wrong in both directions: the half-diagonal of a 172x46 lumber stack is
# 89px, which blanks a whole corner of the plaza, while a circle small enough
# not to do that lets a prop clip the stack's ends.
#
# ⚠ The key is "box", NOT "size". Dictionary already has a built-in size()
# method, so `k.size` inside build_props would resolve to that Callable instead
# of the entry — a silent wrong answer, not an error.
static func prop_keepouts(art_tier: int) -> Array:
	var out: Array = []
	for rec in solids_for(art_tier):
		out.append({"pos": rec[0] as Vector2, "box": rec[1] as Vector2})
	return out


# ---------------------------------------------------------------------------
# ROAD STENCIL — where the painted roads actually are.
#
# Run 149's rule ("props may frame the paths, never stand ON them") used to be
# enforced against TownTileset._path_segments: a ring ellipse plus one spoke per
# gate. The painting's roads are not that shape — the ring is wider on the west,
# the spokes are far flatter than 45 degrees, and both spines run down x = -41
# instead of x = 0 — so the model guard was simultaneously waving props onto
# roads and rejecting clear ground.
#
# tools/bake_town_roadmask.py extracts the road surface from the art by colour
# and writes _road_mask.png, a quarter-scale stencil covering exactly the arena
# with its origin at (-HALF_W, -HALF_H). Re-run it if the square is repainted.
# ---------------------------------------------------------------------------
const ROAD_MASK_PATH: String = "res://Assets/Tilesets/Town_props/_road_mask.png"
const ROAD_MASK_SCALE: float = 4.0   # world px per stencil px

static var _road_img: Image = null
static var _road_checked: bool = false


static func _road_mask() -> Image:
	if not _road_checked:
		_road_checked = true
		_road_img = _load_image(ROAD_MASK_PATH)
		if _road_img == null:
			push_warning("[TownArt] No road stencil at %s — prop placement falls back to the path model." % ROAD_MASK_PATH)
	return _road_img


static func has_road_mask() -> bool:
	return _road_mask() != null


# True when world-space `p` is on (or within `pad` of) a painted road, the
# raked-sand centre or the walled garden's sand.
static func on_road(p: Vector2, pad: float = 0.0) -> bool:
	var img: Image = _road_mask()
	if img == null:
		return false
	var w: int = img.get_width()
	var h: int = img.get_height()
	# The stencil spans the arena, so its half-extent in world px is implied by
	# its own size — no need to know HALF_W/HALF_H here.
	var hx: float = float(w) * ROAD_MASK_SCALE * 0.5
	var hy: float = float(h) * ROAD_MASK_SCALE * 0.5
	var steps: int = maxi(0, int(ceil(pad / ROAD_MASK_SCALE)))
	var cx: int = int((p.x + hx) / ROAD_MASK_SCALE)
	var cy: int = int((p.y + hy) / ROAD_MASK_SCALE)
	for dy in range(-steps, steps + 1):
		for dx in range(-steps, steps + 1):
			var x: int = cx + dx
			var y: int = cy + dy
			if x < 0 or y < 0 or x >= w or y >= h:
				continue
			if img.get_pixel(x, y).r > 0.5:
				return true
	return false


# ---------------------------------------------------------------------------
# NIGHT LANTERNS — the shopfront lanterns are painted lit, but paint does not
# cast light. A rail of GlowLights along the north colonnade spills warm light
# onto the top of the plaza so the night square reads as LIT rather than as a
# dim picture. Run 163 lock still holds: the glow lives in the light, never in
# the sprite — nothing here touches the art.
#
# [TUNE] x positions follow the painted lantern spacing; y sits on the
# shopfront band just above the plaza edge.
# ---------------------------------------------------------------------------
const LANTERN_XS: Array = [-680.0, -540.0, -400.0, -250.0, -110.0, 60.0, 200.0, 360.0, 520.0, 660.0]
const LANTERN_Y: float = -422.0
const LANTERN_RADIUS: float = 200.0
const LANTERN_ENERGY: float = 1.15


static func build_lanterns(parent: Node2D, night: bool) -> void:
	if not night:
		return
	var host := Node2D.new()
	host.name = "TownArtLanterns"
	parent.add_child(host)
	for x in LANTERN_XS:
		GlowLight.attach(host, Vector2(float(x), LANTERN_Y),
			GlowLight.WARM_PAPER, LANTERN_RADIUS, LANTERN_ENERGY, 0.12)
