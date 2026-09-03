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
const ART = preload("res://scripts/TownArt.gd")
const TORII = preload("res://scripts/ToriiGate.gd")
const FOLK = preload("res://scripts/TownFolk.gd")

# ---------------------------------------------------------------------------
# Run 169 — the square is now ONE hand-authored painting per tier (TownArt.gd)
# instead of a bake made of 32px tiles. Everything downstream of build_terrain
# has to know which of the two it got, because the painting already contains
# the ground, the shopfronts and the fence, and is already night-graded.
#
# ⚠ CONTRACT: build_terrain() is the FIRST call in both squares' build order
# (TownSquare._ready and DreamHub._build_square), so it is the one place that
# can latch this for the calls that follow. If you ever reorder those, these
# two statics go stale and the square will double-darken and double up props.
# ---------------------------------------------------------------------------
static var _art_active: bool = false
static var _art_tier: int = 0
static var _art_night: bool = false


# Which Town_props/<dir> the PLACED props come from, given a 4-tier art tier.
# The prop folders are still the Run 143 set of three, so Under Construction
# borrows the delapidated props and Fully Healed takes the perfect ones.
static func prop_tier(art_tier: int) -> int:
	match clampi(art_tier, 0, 3):
		3: return 2
		2: return 1
		_: return 0

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
#
# ⚠ Run 169b (Bruno): "make sure the Dojo directly aligns with the ring in the
# centre... it's fine to just put the dojo directly over it to cover the
# existing ring." There are TWO raked-sand rings, and that is the whole problem:
# Dojo_Building.png carries its own stone-rimmed ring baked into the sprite, and
# Bruno kept a matching ring painted into all eight town images. They were not
# concentric, so the square showed a double rim on the west and south.
#
# The fix is placement only — the scale stays at DOJO_SCALE 0.205, which Bruno
# picked over three larger candidates. Measured off the art (the painted sand
# blob plus its rock rim, consistent across Under Construction / Healing /
# Fully Healed): the PAINTED ring centres on world (-40, -45). The SPRITE's ring
# centres on texture px (1408, 1055) — 287px below the texture centre, which is
# 287 * 0.205 = 58.8 world px below wherever the sprite is drawn. So:
#
#     DOJO_CENTER.y + DOJO_SPRITE_Y + 58.8  =  -45     ->  DOJO_CENTER.y = -66
#     DOJO_CENTER.x                          =  -40
#
# ⚠ If DOJO_SCALE or DOJO_SPRITE_Y ever change, redo that line or the two rings
# drift apart again. Everything else follows DOJO_CENTER on its own — collision,
# the door host, doorstep(), the prop keepouts and the gauntlet spawn ellipse.
const DOJO_CENTER: Vector2 = Vector2(-40, -66)
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
#
# ⚠ Run 169 moved it twice over. x is -41, not 0: the painted south spine runs
# down to the bridge on world x -41 (measured off the art at y = 340/360/380:
# -39.4 / -42.1 / -43.7), so an arch on x = 0 stood with one foot off the road
# — the same reason the peaks torii moved (DreamBiomes.HUB_GATE_POS).
#
# ⚠ Run 172 PUSHED IT 42px FURTHER SOUTH, to y 334 (Bruno: "move the carnival
# gate further south so the shop stalls can line up either side of the path").
# Run 169 had stopped at 292 believing the arch's west post would land on the
# painted bonsai — but that was read off PAINTED_SOLIDS, whose west-bonsai box
# is wrong. Re-measured straight off Town_Square_Healed_Full_Night.jpg (crop
# world x[-420,220] y[180,400], interior mapping in TownArt): the bonsai's
# painted extent is world x[-196,-143] y[283,375], NOT the x[-163,-97] the
# solids table claims. The arch's 180x157 box spans x[-131,+49], so it clears
# the bonsai by 12px whatever its y, and at y 334 it still leaves ~54px of road
# running on to the fence line (painted rail at y ~388) behind it.
# The gain: the arch now sits a clear 84px SOUTH of the shop row (y 250), so
# the row frames the road instead of standing shoulder-to-shoulder with the
# gate, and every slot clears the r140 arch keepout by 25px+.
# ⚠ PAINTED_SOLIDS[2]/[3]'s west-bonsai entry is still the old box — an
# invisible wall ~46px east of the real shrub. Left alone here because it is a
# collision fact for every tier and wants its own re-measure pass.
const CARNIVAL_POS: Vector2 = Vector2(-41.0, HALF_H - 66.0)

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
#
# ⚠ Run 169 MOVED THE WHOLE ROW NORTH, from y ~300-318 to y 250. The painted
# square fills its south fence line with bonsai, a notice board, a weapon rack
# and a chest at y 306-326 (TownArt.PAINTED_SOLIDS), and all four old slots
# landed within 40-65px of one of them. y 250 is open stone in every tier: west
# of it the SW road spoke has already swung out past x -520, east of it the SE
# spoke is still out past x +480, and the south spine is a narrow ribbon on
# x -41 that every slot clears by 190px+. Re-check against TownArt if the art
# is ever redrawn.
#
# ⚠ Run 170 SPREAD THE ROW OUT (Bruno: "the table area seems a bit cluttered,
# make them a bit smaller and more spaced out"). Stalls are ~105px wide at the
# canopy, so the old 135-150px gaps left barely 30px of air between neighbours
# and every stand's sign ran into the next one's. Every gap is 190px now, which
# is 85px of clear stone between canopies, and the row still fits the openings:
#   * the south spine is a narrow ribbon on x -41 — the old slot 0 (x -210)
#     cleared it by only 169px, under the 190px rule the comment above claims.
#     Slot 0 moved out to -250 so all four honour it.
#   * the west end stays inside the SW road spoke (x -520) and the east end
#     inside the SE spoke (x +480).
#   * the keeper (SHOP_KEEPER_POS, x -285) still stands in the gap between
#     slot 0 and slot 2, which is exactly where the row leaves a hole.
# Re-check against TownArt if the painted square is ever redrawn.
# ⚠ Run 172 RE-CENTRED THE ROW ON THE ROAD (Bruno: "the vendor stall on the
# left overlaps the swamp gate — make the stalls a bit smaller, a bit closer
# together, and align them either side of the path"). Two faults were live:
#   * slot 2 (x -440) sat INSIDE the swamp torii. That gate is at (-520,245)
#     and its sprite box is x[-610,-430]; its right foot's painted pixels reach
#     x -445. A 112px canopy at -440 spans x[-496,-384] — a 50px overlap, which
#     is the "stall on top of the gate" in Bruno's screenshot. Slot 3 (x 365)
#     had the same fault against the beach torii (box x[350,530]) with 60px.
#   * the row was strung across the whole plaza from -440 to +365, so it read
#     as four unrelated tables rather than a market lining a street.
# The row is now SYMMETRIC ABOUT THE ROAD, which runs on x -41 (painted dirt
# measured at x[-59,-8] through this band), two stalls a side at +-170 and
# +-320 from there. Stands came down to TABLE_W 74 (canopy 90, +-45; the
# road-side lantern tops out 63px from centre) so the tighter pitch still
# leaves air EVERYWHERE. The row is squeezed between three fixed things, and
# every one of them was the binding constraint at some point — check all three
# before touching a number:
#   * INBOARD, the carnival arch. Its sprite box is x[-131,+49] and it rises to
#     y 177, straight through the stall band, so the inner pair cannot simply
#     hug the road: at +-145 their lanterns crossed the arch's posts. +-170
#     leaves 17px between each inner lantern and the arch.
#   * OUTBOARD, the biome torii. The swamp gate (-520,245) box is x[-610,-430]
#     — its right foot's painted pixels reach x -445, which is what slot 2 at
#     the old x -440 was standing inside (a 50px overlap: Bruno's screenshot).
#     The beach gate (440,225) box x[350,530] had the same fault against the
#     old slot 3 at +365. Now the west end (-406) clears by 24px and the east
#     end (+324) by 26px. THIS caps the row's total width.
#   * BETWEEN NEIGHBOURS, 150px of pitch a side = 42px of clear stone from one
#     stall's canopy to the next one's lantern.
#   * y stays 250: still open stone in every tier, still north of the painted
#     south-fence furniture at y 283+ (see PAINTED_SOLIDS), and now a clean
#     84px north of the carnival arch.
# Re-check against TownArt and DreamBiomes.HUB_GATE_POS if either is redrawn.
const SHOP_SLOTS: Array = [
	Vector2(-211.0, 250.0),
	Vector2( 129.0, 250.0),
	Vector2(-361.0, 250.0),
	Vector2( 279.0, 250.0),
]
const SHOP_KEEPOUT_R: float = 88.0

# Run 167b (Bruno): ONE Dragon Fruit boy minds the whole row, not one keeper
# per stall. He stands BEHIND the counters (smaller y = further back in the
# y-sort) in the GAP between slot 0 and slot 2. Do not centre him on x=0 — the
# carnival torii sprite spans x +-90 up to y 354 and swallows him whole.
# Run 169: follows the row north — still BEHIND the counters (smaller y sorts
# further back) and still in the gap between slot 0 and slot 2, and now well
# clear of the carnival torii, which spans x -131..+49 up to y 354.
# Run 172: the row tightened, so the hole he stands in moved with it — the gap
# between slot 2 (-361) and slot 0 (-211) now centres on -286.
const SHOP_KEEPER_POS: Vector2 = Vector2(-286.0, 196.0)


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
# Run 169: only reached when a tier has NO painting — TownArt samples the
# painting's own corner for the out-of-bounds fill so the water/sky beyond the
# fence always matches. Four tiers now.
static func sky_for_tier(tier: int, night: bool = false) -> Color:
	if night:
		match clampi(tier, 0, 3):
			3:  return Color(0.34, 0.40, 0.62)   # Fully Healed — clear starry blue
			2:  return Color(0.30, 0.34, 0.54)   # Healing
			1:  return Color(0.27, 0.30, 0.47)   # Under Construction
			_:  return Color(0.24, 0.26, 0.40)   # Delapidated — murky overcast
	match clampi(tier, 0, 3):
		3:  return Color(0.58, 0.78, 0.66)   # Fully Healed — vivid summer green
		2:  return SKY_COLOR                  # Healing — the original sunny green
		1:  return Color(0.52, 0.66, 0.58)   # Under Construction
		_:  return Color(0.46, 0.54, 0.50)   # Delapidated — washed-out overcast


# ---------------------------------------------------------------------------
# Keepouts — circles the placed props must clear: every gate mouth, the
# carnival arch, the Dojo landmark + its doorstep, and the hero spawn strip.
# ---------------------------------------------------------------------------
static func prop_keepouts() -> Array:
	var ko: Array = [
		{"pos": DOJO_CENTER, "r": 310.0},
		{"pos": DOJO_CENTER + Vector2(0, DOJO_BODY_SIZE.y * 0.5 + 40.0), "r": 130.0},
		{"pos": CARNIVAL_POS, "r": 140.0},
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
	_art_tier = tier
	_art_night = night
	_art_active = false

	# --- Run 169 path: one painted square -----------------------------------
	# The painting supplies the ground, the roads, the shopfronts AND the fence,
	# so the flat fallback floor, the Wood_Scaffolding wall art and the facade
	# strip are all skipped. The walls still exist — as collision only.
	if ART.build(host, h, tier, night):
		_art_active = true
		DAY.make_backdrop(host, h, ART.backdrop_color(tier, night, sky_for_tier(tier, night)))
		if night:
			_scatter_stars(host, h)
		_invisible_border_walls(host, h)
		ART.build_collision(host, tier)
		ART.build_lanterns(host, night)
		return

	# --- Pre-169 path: bake the square out of tiles --------------------------
	# Kept whole. It is what runs for a tier whose painting is missing, and it
	# is the only reason tools/clean_town_tiles.py still matters.
	var pt: int = prop_tier(tier)
	DAY.make_backdrop(host, h, sky_for_tier(tier, night))
	if night:
		_scatter_stars(host, h)
	DAY.make_ground(host, h, PLAZA_COLOR, PLAZA_ALT_COLOR, 11700)
	DAY.make_border_walls(host, h, WALL_COLOR, true)
	# Real-art overlays (baked over the flat fallback; fallback stays if art missing).
	TT.build_ground(host, h, pt, 11700)
	TT.facade_strip(host, h, pt)


# Collision-only border. The painted fence IS the wall art, so these four
# bodies are the same geometry DayTerrain.make_border_walls builds, minus the
# beams — a transparent ColorRect draws nothing at all.
static func _invisible_border_walls(host: Node2D, h: Vector2) -> void:
	var walls := Node2D.new()
	walls.name = "DayWalls"
	host.add_child(walls)
	var clear := Color(0, 0, 0, 0)
	DAY.make_wall(walls, Vector2(0, -h.y - 16), Vector2(h.x * 2 + 64, 32), clear)
	DAY.make_wall(walls, Vector2(0, h.y + 16), Vector2(h.x * 2 + 64, 32), clear)
	DAY.make_wall(walls, Vector2(-h.x - 16, 0), Vector2(32, h.y * 2 + 64), clear)
	DAY.make_wall(walls, Vector2(h.x + 16, 0), Vector2(32, h.y * 2 + 64), clear)


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
# Run 169: when the square is a night-GRADED painting, the tint is softened and
# the painting multiplies itself by the reciprocal (TownArt.build), so the art
# lands at its authored brightness while the heroes, torii, shop stands and
# placed props still get graded into the scene. Without the softening the night
# art would be darkened twice and go to mud.
static func apply_night_overlay(host: Node2D) -> void:
	if host.get_node_or_null("NightOverlay") != null:
		return
	var night := CanvasModulate.new()
	night.name = "NightOverlay"
	night.color = ART.overlay_tint(_art_tier, _art_night) if _art_active else RunState.NIGHT_TINT
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
	# Run 174 (Bruno): the zone name used to sit at lintel height (y -150) with
	# the default z_index, so the gate sprite (z 1) and portal (z 2) drew right
	# over it — every label was hidden behind its own torii. Drop it to just
	# under the posts' feet (the node origin IS the gate's foot) and lift its
	# z_index above the gate so it can never be occluded, whatever wall it sits
	# on. Move it back ABOVE the gate here if the under-posts read is cramped.
	lbl.position = Vector2(-100, 14)
	lbl.z_index = 5
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
	# Run 174 (Bruno): drop the arch label under the posts and lift it above the
	# dragon sprite (z 1) / portal (z 2) so it stops printing through the dragon.
	lbl.position = Vector2(-120, 14)
	lbl.z_index = 5
	lbl.custom_minimum_size = Vector2(240, 0)
	arch.add_child(lbl)
	return arch


# ---------------------------------------------------------------------------
# PROPS — the tier prop set. `night` cranks the lamp GlowLights (TownTileset
# authors them at daylight strength).
# ---------------------------------------------------------------------------
# Run 169 (Bruno): "avoid overlapping any props with other props or with the
# already-painted on town props ... we can find other areas to fill with our
# existing props too." So the placed props keep running on top of the painting;
# every solid thing painted into the plaza is handed in as a keepout, and the
# placement list simply skips the slots that would collide.
static func build_props(host: Node2D, tier: int, keepouts: Array, night: bool = false) -> void:
	var ko: Array = keepouts.duplicate()
	if _art_active:
		ko.append_array(ART.prop_keepouts(tier))
	TT.build_props(host, half(), prop_tier(tier), ko, night)


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
