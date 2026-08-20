extends RefCounted

# ============================================================
# TownBuild.gd — Run 167 (2026-08-19) — ONE Seedy City square
# ============================================================
# Bruno, Run 167: "make the night town look exactly like the day
# town, and when the town upgrades the night town should equally
# reflect it."
#
# So the square is now built from a SINGLE source. Both
# TownSquare.gd (waking world) and DreamHub.gd (dream world) call
# the builders below with the same tier, the same geometry and the
# same art; the ONLY differences allowed are:
#
#   * `night` = true adds a CanvasModulate night tint over the
#     layer-0 world canvas (RunState.NIGHT_TINT — same overlay the
#     biomes use, Run 113) and cranks the street-lamp GlowLights.
#   * each scene wires its OWN interactables (day: dojo door,
#     family visits; night: biome runs, merchants, cake portal).
#
# LOCK (Run 167): anything that changes how the square LOOKS goes
# in here, never in one of the two scene scripts. If you find
# yourself editing a wall / prop / gate / building in TownSquare.gd
# or DreamHub.gd, it belongs in this file instead — otherwise the
# two squares drift apart again.
#
# Tier art comes from RunState.town_visual_tier() (Run 143):
#   0 Delapidated · 1 Healing (sensei lore 3+) · 2 Perfect
# and sensei lore is itself computed from how many families the
# player has healed — so healing the town updates BOTH squares.
# ============================================================

const DB = preload("res://scripts/DreamBiomes.gd")
const DAY = preload("res://scripts/DayTerrain.gd")
const TT = preload("res://scripts/TownTileset.gd")
const TORII = preload("res://scripts/ToriiGate.gd")
const FOLK = preload("res://scripts/TownFolk.gd")

# --- Arena -------------------------------------------------------------------
const HALF_W: float = 710.0
const HALF_H: float = 400.0

static func half() -> Vector2:
	return Vector2(HALF_W, HALF_H)

# --- Flat fallback palette (only shows if the tier art is missing) -----------
const PLAZA_COLOR: Color     = Color(0.62, 0.56, 0.48)   # warm daylight cobbles
const PLAZA_ALT_COLOR: Color = Color(0.67, 0.61, 0.52)
const WALL_COLOR: Color      = Color(0.48, 0.40, 0.30)
const SKY_COLOR: Color       = Color(0.55, 0.72, 0.62)   # sunny green beyond the walls

# --- Central Dojo landmark ---------------------------------------------------
const DOJO_BODY_SIZE: Vector2 = Vector2(430, 265)   # visual/keepout footprint
const DOJO_CENTER: Vector2 = Vector2(0, -60)
const DOJO_ENTRANCE_W: float = 70.0      # walkable front hallway width
const DOJO_ENTRANCE_D: float = 80.0      # hallway depth (south face inward)
# Collision sits inside the rock ring, not at the full sprite edge.
const DOJO_COL_W: float = 330.0
const DOJO_COL_NORTH_INSET: float = 30.0

const DOJO_SPRITE_PATH := "res://Assets/Sprites/Families/Family Houses/Dojo_Building.png"
const DOJO_SPRITE_W: float = 2816.0
const DOJO_SPRITE_H: float = 1536.0
const DOJO_SCALE: float = 0.205
const DOJO_SPRITE_Y: float = -38.0

# Where the heroes stand when they arrive on the Dojo doorstep.
static func doorstep() -> Vector2:
	return DOJO_CENTER + Vector2(0, DOJO_BODY_SIZE.y * 0.5 + 56.0)

# South carnival road. Day: the way to the Carnival Grounds, sealed with
# bunting until RunState.carnival_open(). Night: the same arch, shut — the
# Dragon Fruit troupe's merchants set up their tables in front of it instead.
const CARNIVAL_POS: Vector2 = Vector2(0, HALF_H - 46.0)

# ---------------------------------------------------------------------------
# NIGHT SHOP ROW (Run 167, Bruno: "keep the carnival torii to the south, add
# the shop tables just north of it — watch out for overlap, make sure the
# tables and items are fully visible").
#
# Slot 0 is the one Tally always mans, so it sits closest to the arch on the
# west side. Every slot was clearance-checked against:
#   * the baked dirt paths (ring road / south spine / gate spokes) — all >140px
#   * the carnival arch keepout (r 140) — all >150px
#   * every day-square prop — anything closer than SHOP_KEEPOUT_R is simply
#     skipped in the night build (see shop_keepouts()), which is why the row
#     doesn't fight the benches and planters that live down there in daylight.
# ---------------------------------------------------------------------------
const SHOP_SLOTS: Array = [
	Vector2(-175.0, 318.0),
	Vector2( 175.0, 318.0),
	Vector2(-345.0, 300.0),
	Vector2( 345.0, 300.0),
]
const SHOP_KEEPOUT_R: float = 88.0

# Run 167b (Bruno): ONE Dragon Fruit boy minds the whole row, not one keeper
# per stall. He stands BEHIND the counters (smaller y = further back in the
# y-sort) in the GAP between slot 0 and slot 2. Do not centre him on x=0 — the
# carnival torii sprite spans x +-90 up to y 354 and swallows him whole.
const SHOP_KEEPER_POS: Vector2 = Vector2(-262.0, 294.0)


# Props the night square must NOT place, because a merchant is standing there.
static func shop_keepouts(count: int) -> Array:
	var ko: Array = []
	for i in range(mini(count, SHOP_SLOTS.size())):
		ko.append({"pos": SHOP_SLOTS[i], "r": SHOP_KEEPOUT_R})
	return ko


# ---------------------------------------------------------------------------
# Sky — daylight mood tracks the healing tier; night is the same graded
# progression pushed to dusk-blue (the CanvasModulate darkens it further).
# ---------------------------------------------------------------------------
static func sky_for_tier(tier: int, night: bool = false) -> Color:
	if night:
		match tier:
			2:  return Color(0.34, 0.40, 0.62)   # Perfect — clear starry blue
			1:  return Color(0.30, 0.34, 0.54)   # Healing
			_:  return Color(0.24, 0.26, 0.40)   # Delapidated — murky overcast
	match tier:
		2:  return Color(0.58, 0.78, 0.66)   # Perfect — vivid summer green
		1:  return SKY_COLOR                  # Healing — the original sunny green
		_:  return Color(0.46, 0.54, 0.50)   # Delapidated — washed-out overcast


# ---------------------------------------------------------------------------
# Keepouts — circles the placed props must clear: every gate mouth, the
# carnival arch, the Dojo landmark + its doorstep, and the hero spawn strip.
# ---------------------------------------------------------------------------
static func prop_keepouts() -> Array:
	var ko: Array = [
		{"pos": DOJO_CENTER, "r": 310.0},
		{"pos": DOJO_CENTER + Vector2(0, DOJO_BODY_SIZE.y * 0.5 + 40.0), "r": 130.0},
		{"pos": Vector2(0, HALF_H - 46.0), "r": 140.0},
	]
	for biome_id in DB.BIOME_ORDER:
		ko.append({"pos": gate_pos(String(biome_id)), "r": 135.0})
	return ko


# Gate anchor, clamped exactly the way both squares clamp their gate nodes.
static func gate_pos(biome_id: String) -> Vector2:
	var raw: Vector2 = DB.HUB_GATE_POS.get(biome_id, Vector2.ZERO)
	return Vector2(
		clampf(raw.x, -HALF_W + 10.0, HALF_W - 10.0),
		clampf(raw.y, -HALF_H + 10.0, HALF_H - 10.0))


# ---------------------------------------------------------------------------
# TERRAIN — backdrop, flat fallback floor, border walls, baked tier ground and
# the building fronts north of the wall. Identical call order in both squares.
# ---------------------------------------------------------------------------
static func build_terrain(host: Node2D, tier: int, night: bool = false) -> void:
	var h: Vector2 = half()
	DAY.make_backdrop(host, h, sky_for_tier(tier, night))
	if night:
		_scatter_stars(host, h)
	DAY.make_ground(host, h, PLAZA_COLOR, PLAZA_ALT_COLOR, 11700)
	DAY.make_border_walls(host, h, WALL_COLOR, true)
	# Real-art overlays (baked over the flat fallback; fallback stays if art missing).
	TT.build_ground(host, h, tier, 11700)
	TT.facade_strip(host, h, tier)


# Night only: a faint star field on the out-of-bounds backdrop, so the strip of
# sky past the walls reads as night rather than as flat paint. Drawn BELOW the
# plaza (z -55), so it only ever shows outside the square.
static func _scatter_stars(host: Node2D, h: Vector2) -> void:
	var w: int = int(h.x * 2.0 + 800.0) / 4
	var ht: int = int(h.y * 2.0 + 800.0) / 4
	var img := Image.create(w, ht, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7770
	for i in range(460):
		var x: int = rng.randi_range(0, w - 1)
		var y: int = rng.randi_range(0, ht - 1)
		var a: float = rng.randf_range(0.20, 0.85)
		img.set_pixel(x, y, Color(1.0, 0.98, 0.9, a))
	var spr := Sprite2D.new()
	spr.name = "NightStars"
	spr.texture = ImageTexture.create_from_image(img)
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.scale = Vector2(4, 4)
	spr.z_index = -55
	host.add_child(spr)


# ---------------------------------------------------------------------------
# NIGHT OVERLAY — Run 113's single CanvasModulate over the layer-0 world
# canvas. HUD / menus live on CanvasLayers and stay bright, untouched.
# ---------------------------------------------------------------------------
static func apply_night_overlay(host: Node2D) -> void:
	if host.get_node_or_null("NightOverlay") != null:
		return
	var night := CanvasModulate.new()
	night.name = "NightOverlay"
	night.color = RunState.NIGHT_TINT
	host.add_child(night)


# ---------------------------------------------------------------------------
# DOJO LANDMARK — the building at the centre of the square. Run 153 geometry,
# moved here verbatim so the dream square gets the exact same silhouette,
# collision and walk-behind sorting. Returns the door host Node2D (already
# added to `host`) so the caller can hang its own interactable on it.
# ---------------------------------------------------------------------------
static func build_dojo_landmark(host: Node2D, sign_text: String = "THE DOJO") -> Node2D:
	var dojo := Node2D.new()
	dojo.name = "DojoLandmark"
	dojo.position = DOJO_CENTER
	dojo.y_sort_enabled = true   # children join the global y-sort pool
	host.add_child(dojo)

	var half_w: float = DOJO_BODY_SIZE.x * 0.5   # visual half-width (keepouts)
	var half_h: float = DOJO_BODY_SIZE.y * 0.5
	var ent_hw: float = DOJO_ENTRANCE_W * 0.5
	var south_face_y: float = half_h
	var col_hw: float = DOJO_COL_W * 0.5
	var col_north: float = -half_h + DOJO_COL_NORTH_INSET

	# --- Collision: three body pieces + door barrier -------------------------
	var main_body := StaticBody2D.new()
	main_body.collision_layer = 1
	main_body.collision_mask = 0
	var main_cs := CollisionShape2D.new()
	var main_shape := RectangleShape2D.new()
	var main_top: float = col_north
	var main_bot: float = south_face_y - DOJO_ENTRANCE_D
	var main_h: float = main_bot - main_top
	main_shape.size = Vector2(DOJO_COL_W, main_h)
	main_cs.shape = main_shape
	main_cs.position.y = main_top + main_h * 0.5
	main_body.add_child(main_cs)
	dojo.add_child(main_body)

	var side_w: float = col_hw - ent_hw
	for sgn in [-1.0, 1.0]:
		var wall := StaticBody2D.new()
		wall.collision_layer = 1
		wall.collision_mask = 0
		var w_cs := CollisionShape2D.new()
		var w_shape := RectangleShape2D.new()
		w_shape.size = Vector2(side_w, DOJO_ENTRANCE_D)
		w_cs.shape = w_shape
		w_cs.position = Vector2(sgn * (ent_hw + side_w * 0.5), south_face_y - DOJO_ENTRANCE_D * 0.5)
		wall.add_child(w_cs)
		dojo.add_child(wall)

	# Door barrier — blocks the player AT the door inside the hallway.
	var door_bar := StaticBody2D.new()
	door_bar.collision_layer = 1
	door_bar.collision_mask = 0
	var db_cs := CollisionShape2D.new()
	var db_shape := RectangleShape2D.new()
	db_shape.size = Vector2(DOJO_ENTRANCE_W, 10.0)
	db_cs.shape = db_shape
	db_cs.position = Vector2(0, south_face_y - DOJO_ENTRANCE_D)
	door_bar.add_child(db_cs)
	dojo.add_child(door_bar)

	# --- Sprite: y-sort anchored at the DOOR line ----------------------------
	var door_sort_y: float = south_face_y - DOJO_ENTRANCE_D
	var sprite_wrap := Node2D.new()
	sprite_wrap.name = "DojoSpriteWrap"
	sprite_wrap.position.y = door_sort_y
	sprite_wrap.z_as_relative = false
	sprite_wrap.z_index = 0
	dojo.add_child(sprite_wrap)

	if ResourceLoader.exists(DOJO_SPRITE_PATH):
		var tex: Texture2D = load(DOJO_SPRITE_PATH)
		var spr := Sprite2D.new()
		spr.texture = tex
		spr.scale = Vector2(DOJO_SCALE, DOJO_SCALE)
		spr.position.y = DOJO_SPRITE_Y - door_sort_y
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		sprite_wrap.add_child(spr)
	else:
		var fb_foot_off: float = south_face_y - door_sort_y
		var walls := ColorRect.new()
		walls.offset_left = -half_w
		walls.offset_top = -DOJO_BODY_SIZE.y + fb_foot_off
		walls.offset_right = half_w
		walls.offset_bottom = fb_foot_off
		walls.color = Color(0.42, 0.30, 0.20)
		sprite_wrap.add_child(walls)
		var roof := Polygon2D.new()
		roof.polygon = PackedVector2Array([
			Vector2(-half_w * 1.24, -DOJO_BODY_SIZE.y + fb_foot_off + 14),
			Vector2(0, -DOJO_BODY_SIZE.y + fb_foot_off - 64),
			Vector2(half_w * 1.24, -DOJO_BODY_SIZE.y + fb_foot_off + 14),
		])
		roof.color = Color(0.30, 0.18, 0.14)
		sprite_wrap.add_child(roof)
		var door := ColorRect.new()
		door.offset_left = -ent_hw
		door.offset_top = 0
		door.offset_right = ent_hw
		door.offset_bottom = fb_foot_off
		door.color = Color(0.16, 0.11, 0.08)
		sprite_wrap.add_child(door)

	# Sign label above the roof peak.
	var sprite_h_world: float = DOJO_SPRITE_H * DOJO_SCALE
	var roof_peak_y: float = DOJO_SPRITE_Y - sprite_h_world * 0.5
	var sign_lbl := Label.new()
	sign_lbl.text = sign_text
	sign_lbl.add_theme_font_size_override("font_size", 16)
	sign_lbl.add_theme_color_override("font_color", Color(0.95, 0.88, 0.65))
	sign_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	sign_lbl.add_theme_constant_override("outline_size", 3)
	sign_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sign_lbl.position = Vector2(-80, roof_peak_y - door_sort_y - 22)
	sign_lbl.custom_minimum_size = Vector2(160, 0)
	sign_lbl.z_index = 4
	sprite_wrap.add_child(sign_lbl)

	# Door host — inside the entrance hallway near the door.
	var door_host := Node2D.new()
	door_host.name = "DojoDoor"
	door_host.position = DOJO_CENTER + Vector2(0, south_face_y - DOJO_ENTRANCE_D * 0.5)
	host.add_child(door_host)
	return door_host


# ---------------------------------------------------------------------------
# GATES — one torii per biome at the shared compass anchors. The caller owns
# the label text and the interactable; the geometry lives here.
# ---------------------------------------------------------------------------
static func build_gate(host: Node2D, biome_id: String, with_portal: bool,
		node_prefix: String = "Gate") -> Node2D:
	var gate := Node2D.new()
	gate.name = "%s_%s" % [node_prefix, biome_id]
	gate.position = gate_pos(biome_id)
	host.add_child(gate)
	gate.add_child(TORII.build(biome_id, with_portal))
	return gate


# Label placement that pushes inward from whichever wall the gate sits on.
static func add_gate_label(gate: Node2D, text: String, color: Color) -> Label:
	var lbl := Label.new()
	lbl.name = "GateLabel"
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	lbl.add_theme_constant_override("outline_size", 3)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var pos: Vector2 = gate.position
	var off := Vector2(-100, -150)
	if pos.y < -HALF_H + 60.0:        # north wall — label below
		off = Vector2(-100, 50)
	elif pos.x > HALF_W - 60.0:       # east wall — label to the left
		off = Vector2(-240, -36)
	elif pos.x < -HALF_W + 60.0:      # west wall — label to the right
		off = Vector2(40, -36)
	lbl.position = off
	lbl.custom_minimum_size = Vector2(200, 0)
	gate.add_child(lbl)
	return lbl


# ---------------------------------------------------------------------------
# CARNIVAL ARCH — the south road out of the square (Dragon Fruit troupe + the
# rest of town). Sealed in both worlds until the Carnival build.
# ---------------------------------------------------------------------------
# Run 167b (Bruno): "make sure the Carnival Torii at night also has no portal
# or shows blocked if you try to enter that one." A swirling portal means a way
# through, so it is drawn ONLY when the road is actually walkable — the arch
# stands empty otherwise, in both worlds.
static func build_carnival_arch(host: Node2D, label_text: String, color: Color,
		open: bool = false) -> Node2D:
	var arch := Node2D.new()
	arch.name = "CarnivalArch"
	arch.position = CARNIVAL_POS
	host.add_child(arch)
	arch.add_child(TORII.build("carnival", open))

	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	lbl.add_theme_constant_override("outline_size", 3)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.position = Vector2(-120, -150)
	lbl.custom_minimum_size = Vector2(240, 0)
	arch.add_child(lbl)
	return arch


# ---------------------------------------------------------------------------
# PROPS — the tier prop set. `night` cranks the lamp GlowLights (TownTileset
# authors them at daylight strength).
# ---------------------------------------------------------------------------
static func build_props(host: Node2D, tier: int, keepouts: Array, night: bool = false) -> void:
	TT.build_props(host, half(), tier, keepouts, night)


# ---------------------------------------------------------------------------
# TOWNSFOLK — PARKED (Run 167b, Bruno): "I'd like characters removed from the
# day and night town... let's keep the guardian fruit/veg family members at
# their respective homes and biomes for now. I'll make some more generic
# townsfolk to go there."
#
# The placement layout below is kept because it is still the right layout —
# six figures, same spots, in BOTH squares, each drawn at their family's live
# healing tier. When the generic townsfolk art lands, swap the member keys and
# flip PLACE_VILLAGERS back to true; nothing else needs to change.
#
# [member, x, y, face_left]
# ---------------------------------------------------------------------------
const PLACE_VILLAGERS: bool = false
const VILLAGERS: Array = [
	["broccoli_r4", -330.0, -330.0, false],   # lifter, training under the west lamp
	["carrot_r2",    320.0, -325.0, true],    # archer, leaning by the east lamp
	["potato_r4",   -360.0,  300.0, false],   # miner, resting near the planters
	["banana_r4",    260.0,  315.0, true],    # medic, doing the rounds
	["grape_r4",    -620.0,  100.0, false],   # guard, watching the west alley
	["carrot_r4",    430.0,  -10.0, true],    # spotter, glassing the market
]


static func build_townsfolk(host: Node2D) -> void:
	if not PLACE_VILLAGERS:
		return
	var folk := Node2D.new()
	folk.name = "Townsfolk"
	folk.y_sort_enabled = true
	host.add_child(folk)
	for rec in VILLAGERS:
		FOLK.make(folk, String(rec[0]), Vector2(float(rec[1]), float(rec[2])), bool(rec[3]))
