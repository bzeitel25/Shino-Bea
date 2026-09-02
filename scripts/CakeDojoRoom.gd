extends RefCounted

# ============================================================
# CakeDojoRoom.gd — Run 171 (2026-09-02) — the Cake Dojo
# ============================================================
# The summit of the Dragon Cake Fortress is not a generic boss box:
# it is Shino & Bea's OWN DOJO, rebuilt in sugar. Same footprint,
# same walls, same doorways, same scroll on the same nail — every
# constant below is copied from Dojo.gd on purpose, and the only
# thing that changes is which folder the art comes out of:
#
#     Dojo_props/      →  CakeDojo_props/
#
# so chocolate planks replace the pine floor, strawberry tatami the
# straw mats, icing-scale panels the plaster, blossom bonsai the
# pines, and the tokonoma alcove behind Sensei becomes a candy-torii
# shrine — with Shadow Sensei Z sitting in it exactly where the real
# Sensei Z sits back home. That mirror IS the fight's staging.
#
# Usage (ShadowSenseiArena.gd):
#     const ROOM = preload("res://scripts/CakeDojoRoom.gd")
#     ROOM.build(self)
#
# Everything is parented under `host`; nothing is assumed about the
# host beyond it being a Node2D, so the room can be dropped into any
# scene. Geometry contract shared with Dojo.gd:
#     main hall  x[-480,480] y[-280,280]
#     Shino's    x[ 180,480] y[-560,-280]   door: north wall x[320,400]
#     Bea's      x[ 480,760] y[-280,   0]   door: east  wall y[-220,-140]
# ============================================================

const DT = preload("res://scripts/DojoTerrain.gd")
const WS = preload("res://scripts/WoodScaffolding.gd")
const WA = preload("res://scripts/DojoWallArt.gd")

const ART_DIR: String = "res://Assets/Tilesets/CakeDojo_props/"
const FLOOR_DIR: String = ART_DIR + "floor/"
const WALL_DIR: String = ART_DIR + "wall/"

# ── Room footprints (interior, world coords) — IDENTICAL to Dojo.gd ──
const MAIN_RECT: Rect2 = Rect2(-480, -280, 960, 560)
const SHINO_RECT: Rect2 = Rect2(180, -560, 300, 280)
const BEA_RECT: Rect2 = Rect2(480, -280, 280, 280)
const WALL_T: float = 32.0
const TERRAIN_SEED: int = 4242          # same seed ⇒ same plank layout as home

# Deep berry-dark "outside" instead of the dojo's soot black: past these walls
# is open sky over the fortress, not another room.
const BACKDROP: Color = Color(0.09, 0.05, 0.10)

static var _art_cache: Dictionary = {}


# ---------------------------------------------------------------------------
# Public entry
# ---------------------------------------------------------------------------
static func build(host: Node2D) -> void:
	_build_backdrop(host)
	DT.build(host, [MAIN_RECT, SHINO_RECT, BEA_RECT], [
		{"rect": Rect2(-240, -40, 480, 280), "kind": "training"},  # central training mat
		{"rect": Rect2(255, -520, 170, 150), "kind": "tan"},        # Shino's nook
		{"rect": Rect2(555, -205, 170, 150), "kind": "tan"},        # Bea's nook
	], TERRAIN_SEED, FLOOR_DIR)
	_build_walls(host)
	_build_wall_faces(host)
	_build_decor(host)


static func _build_backdrop(host: Node2D) -> void:
	var bg := ColorRect.new()
	bg.name = "Backdrop"
	bg.z_index = -50
	bg.color = BACKDROP
	bg.offset_left = -760.0
	bg.offset_top = -760.0
	bg.offset_right = 1020.0
	bg.offset_bottom = 520.0
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host.add_child(bg)


# ---------------------------------------------------------------------------
# Walls — segment list copied from Dojo._build_walls(), doorway gaps included.
# ---------------------------------------------------------------------------
static func _build_walls(host: Node2D) -> void:
	var walls := Node2D.new()
	walls.name = "Walls"
	host.add_child(walls)
	var segs: Array = [
		# Main hall — north wall split around Shino's doorway.
		[Vector2(-80, -280), Vector2(800, WALL_T)],   # x[-480,320]
		[Vector2(440, -280), Vector2(80, WALL_T)],    # x[400,480]
		# Main hall — south + west.
		[Vector2(0, 280),    Vector2(960, WALL_T)],
		[Vector2(-480, 0),   Vector2(WALL_T, 560)],
		# Main hall — east wall split around Bea's doorway.
		[Vector2(480, -250), Vector2(WALL_T, 60)],    # y[-280,-220]
		[Vector2(480, 70),   Vector2(WALL_T, 420)],   # y[-140,280]
		# Shino's north room — west / north / east.
		[Vector2(180, -420), Vector2(WALL_T, 280)],
		[Vector2(330, -560), Vector2(332, WALL_T)],
		[Vector2(480, -420), Vector2(WALL_T, 280)],
		# Bea's east room — north / east / south.
		[Vector2(620, -280), Vector2(280, WALL_T)],
		[Vector2(760, -140), Vector2(WALL_T, 280)],
		[Vector2(620, 0),    Vector2(280, WALL_T)],
	]
	for s in segs:
		_make_wall(walls, s[0], s[1])

	# Scaffolding joints at the wall junctions (Run 162 anchoring rules).
	WS.place_corner(walls, Vector2(-480, -280), "tl", -6)
	WS.place_corner(walls, Vector2(-480,  280), "bl", -6)
	WS.place_corner(walls, Vector2( 480,  280), "br", -6)
	WS.place_corner(walls, Vector2( 180, -560), "tl", -6)
	WS.place_corner(walls, Vector2( 480, -560), "tr", -6)
	WS.place_corner(walls, Vector2( 760, -280), "tr", -6)
	WS.place_corner(walls, Vector2( 760,    0), "br", -6)
	WS.place_cross(walls, Vector2( 480, -280), -6)
	WS.place_tee(walls, Vector2( 180, -280), "up", -6)


static func _make_wall(parent: Node, pos: Vector2, size: Vector2) -> void:
	var w := StaticBody2D.new()
	w.position = pos
	w.collision_layer = 1
	w.collision_mask = 0
	var cs := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = size
	cs.shape = shape
	w.add_child(cs)
	var vis_root := Node2D.new()
	w.add_child(vis_root)
	WS.dress_wall(vis_root, size, -6)
	parent.add_child(w)


static func _build_wall_faces(host: Node2D) -> void:
	var faces := Node2D.new()
	faces.name = "WallFaces"
	faces.z_index = -12
	host.add_child(faces)
	# Main hall north wall — candy-torii shrine alcove dead centre (x=0), which
	# is exactly where Shadow Sensei Z is waiting.
	WA.bake_run(faces, -480.0, 180.0, -280.0, "wall_alcove", 0.0, WALL_DIR)
	# The two bedroom north walls — sugar-glass arched windows.
	WA.bake_run(faces, 180.0, 480.0, -560.0, "wall_arch", 330.0, WALL_DIR)
	WA.bake_run(faces, 480.0, 760.0, -280.0, "wall_arch", 620.0, WALL_DIR)


# ---------------------------------------------------------------------------
# Decor — same nails, same shelves, cake versions of the same props.
# (Placements lifted from Dojo._build_decor(); the fixtures they were composed
# around — dummy at (-340,-180), dispenser at (-200,-228), Sensei at (0,-190) —
# have summit equivalents in the same spots.)
# ---------------------------------------------------------------------------
static func _build_decor(host: Node2D) -> void:
	var deco := Node2D.new()
	deco.name = "Decor"
	host.add_child(deco)

	# ── Main hall, north wall hangings (west → east), on the wall FACE ──
	_deco(deco, "scroll_kanji_a", Vector2(-420, -300), 64.0)
	_hang_paper_lantern(deco, Vector2(-310, -336), 56.0)
	_deco(deco, "scroll_dragon", Vector2(-140, -292), 112.0)   # place of honour by the shrine
	_deco(deco, "scroll_kanji_b", Vector2(100, -300), 64.0)
	_hang_paper_lantern(deco, Vector2(155, -336), 56.0)
	_deco(deco, "rack_katana_a", Vector2(255, -240), 58.0)

	# ── Main hall, west wall ──
	_deco(deco, "lantern_stone_a", Vector2(-445, -130), 52.0)
	GlowLight.attach(deco, Vector2(-445, -168), GlowLight.WARM_STONE, 118.0, 0.50, 0.12)
	_deco(deco, "bamboo_a", Vector2(-445, -40), 86.0)
	_deco(deco, "bamboo_c", Vector2(-445, 60), 78.0)

	# ── Main hall, east wall (around Bea's doorway gap y[-220,-140]) ──
	_deco(deco, "banner_map", Vector2(450, -70), 62.0)
	_deco(deco, "lantern_stone_c", Vector2(447, 110), 52.0)
	GlowLight.attach(deco, Vector2(447, 72), GlowLight.WARM_STONE, 118.0, 0.50, 0.12)
	_deco(deco, "bamboo_cut_a", Vector2(450, 215), 66.0)

	# ── SW tea corner ──
	_deco(deco, "table_low_b", Vector2(-360, 195), 46.0)
	_deco_collide(deco, Vector2(-360, 190), 16.0)
	_deco(deco, "cushion_b", Vector2(-425, 200), 20.0, -25)
	_deco(deco, "cushion_c", Vector2(-298, 200), 20.0, -25)
	_deco(deco, "go_board", Vector2(-362, 248), 32.0, -25)

	# ── SE zen garden corner (gumdrop stones raked in icing sugar) ──
	_deco(deco, "zen_sand_a", Vector2(390, 212), 88.0, -25)
	_deco(deco, "lantern_stone_d", Vector2(448, 180), 54.0)
	GlowLight.attach(deco, Vector2(448, 141), GlowLight.WARM_STONE, 118.0, 0.50, 0.12)
	_deco(deco, "bonsai_f", Vector2(336, 228), 56.0)

	# ── Hall floor accents ──
	_deco(deco, "brazier", Vector2(-262, 62), 50.0)
	GlowLight.attach(deco, Vector2(-262, 26), GlowLight.EMBER, 180.0, 0.88, 0.20)
	_deco_collide(deco, Vector2(-262, 58), 13.0)
	_deco(deco, "rug_red", Vector2(0, 236), 42.0, -25)        # threshold mat
	_deco(deco, "trap_door", Vector2(285, -246), 44.0, -25)   # ninja secret, NE corner

	# ── Shino's room (north) ──
	_deco(deco, "scroll_kanji_c", Vector2(225, -568), 64.0)
	_deco(deco, "scroll_kanji_e", Vector2(430, -568), 64.0)
	_deco(deco, "rack_stand", Vector2(448, -482), 72.0)
	_deco(deco, "bedroll_a", Vector2(340, -432), 64.0, -25)
	_deco(deco, "lantern_stone_b", Vector2(212, -372), 50.0)
	GlowLight.attach(deco, Vector2(212, -409), GlowLight.WARM_STONE, 118.0, 0.50, 0.12)
	_deco(deco, "bonsai_d", Vector2(215, -318), 52.0)

	# ── Bea's room (east) ──
	_deco(deco, "scroll_kanji_d", Vector2(543, -288), 62.0)
	_deco(deco, "scroll_kanji_f", Vector2(700, -288), 62.0)
	_deco(deco, "rug_green", Vector2(640, -118), 58.0, -26)
	_deco(deco, "bedroll_a", Vector2(640, -122), 60.0, -25)
	_deco(deco, "table_low_c", Vector2(560, -42), 42.0)
	_deco(deco, "cushion_a", Vector2(514, -26), 20.0, -25)
	_deco(deco, "bonsai_b", Vector2(735, -42), 56.0)


# ---------------------------------------------------------------------------
# CakeDojo_props loader + placement helpers (mirrors Dojo.gd's)
# ---------------------------------------------------------------------------
static func _art_tex(name: String) -> ImageTexture:
	if _art_cache.has(name):
		var c = _art_cache[name]
		return c if c is ImageTexture else null
	var p: String = ART_DIR + name + ".png"
	var img: Image = null
	if ResourceLoader.exists(p):
		var r: Resource = ResourceLoader.load(p)
		if r is Texture2D:
			img = (r as Texture2D).get_image()
	if img == null:
		var abs_path: String = ProjectSettings.globalize_path(p)
		if FileAccess.file_exists(abs_path):
			var im := Image.new()
			if im.load(abs_path) == OK:
				img = im
	if img == null:
		push_warning("[CakeDojoRoom] Missing decor art: %s" % p)
		_art_cache[name] = false
		return null
	img.convert(Image.FORMAT_RGBA8)
	var tex: ImageTexture = ImageTexture.create_from_image(img)
	_art_cache[name] = tex
	return tex


# Foot-anchored decor sprite. z=-1 keeps standing props under the heroes;
# z=-25/-26 for flat floor pieces (rugs, mats).
static func _deco(parent: Node, name: String, foot: Vector2, world_h: float,
		z: int = -1) -> Sprite2D:
	var tex: ImageTexture = _art_tex(name)
	if tex == null:
		return null
	var s: float = world_h / float(tex.get_height())
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.scale = Vector2(s, s)
	spr.position = foot + Vector2(0, -world_h * 0.5)
	spr.z_index = z
	parent.add_child(spr)
	return spr


static func _deco_collide(parent: Node, pos: Vector2, r: float) -> void:
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = pos
	var cs := CollisionShape2D.new()
	var shape := CircleShape2D.new()
	shape.radius = r
	cs.shape = shape
	body.add_child(cs)
	parent.add_child(body)


# Run 163 LOCK: the lantern SPRITE IS STATIC — the flicker is a real
# PointLight2D breathing its energy, never a two-frame texture swap. The light
# is parented to `parent`, NOT to the sprite, because decor sprites carry a
# scale and a light under one would silently inherit it.
static func _hang_paper_lantern(parent: Node, foot: Vector2, world_h: float) -> void:
	var spr: Sprite2D = _deco(parent, "lantern_paper_f0", foot, world_h)
	if spr == null:
		return
	GlowLight.attach(parent, foot + Vector2(0.0, -world_h * 0.52),
		GlowLight.WARM_PAPER, 158.0, 0.76, 0.16)
