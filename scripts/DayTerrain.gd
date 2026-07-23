extends RefCounted

# ============================================================
# DayTerrain.gd — Run 154 (2026-07-18) — waking-world day ground
# ============================================================
# Lightweight daytime floor/wall baker shared by TownSquare,
# DayBiomeRoom and FamilyHome. Deliberately SEPARATE from the
# night pipeline (DreamTerrain bakes starry skies + oceans that
# read as dream-night; the waking world just needs a clean, bright
# floor). Placeholder-grade by design — real day art swaps in the
# same way the biome tilesets replaced the early flat rects.
#
#   make_ground(parent, half, col_a, col_b, seed)  → baked checker floor
#   make_backdrop(parent, half, color)             → warm out-of-bounds fill
#   make_border_walls(parent, half, color)         → 4 solid StaticBody walls
#   make_wall(parent, pos, size, color)            → one solid wall segment
# ============================================================

const TILE: float = 48.0

# Run 154 — real Wood_Scaffolding art for border walls (native pixel size).
const WS = preload("res://scripts/WoodScaffolding.gd")


static func make_backdrop(parent: Node2D, half: Vector2, color: Color) -> void:
	var bg := ColorRect.new()
	bg.name = "DayBackdrop"
	bg.z_index = -60
	bg.color = color
	bg.offset_left = -half.x - 400.0
	bg.offset_top = -half.y - 400.0
	bg.offset_right = half.x + 400.0
	bg.offset_bottom = half.y + 400.0
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(bg)


static func make_ground(parent: Node2D, half: Vector2, col_a: Color, col_b: Color, seed_val: int) -> void:
	# One baked low-res image scaled up with NEAREST — crisp tile squares,
	# a single Sprite2D instead of hundreds of ColorRects.
	var cols: int = int(ceil(half.x * 2.0 / TILE))
	var rows: int = int(ceil(half.y * 2.0 / TILE))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	var img := Image.create(cols, rows, false, Image.FORMAT_RGB8)
	for y in range(rows):
		for x in range(cols):
			var base: Color = col_a if ((x + y) % 2 == 0) else col_b
			# Anti-grid: random subtle lightness flips so it doesn't read as a chessboard.
			if rng.randf() < 0.22:
				base = base.lightened(rng.randf_range(0.02, 0.06))
			elif rng.randf() < 0.22:
				base = base.darkened(rng.randf_range(0.02, 0.06))
			img.set_pixel(x, y, base)
	var tex := ImageTexture.create_from_image(img)
	var spr := Sprite2D.new()
	spr.name = "DayGround"
	spr.texture = tex
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.scale = Vector2(TILE, TILE)
	spr.z_index = -40
	parent.add_child(spr)


# Run 152b — rails now DRAW centered ON the arena edge (16px inward from
# each body center) so the visible beam sits flush against the pavement /
# building fronts, killing the green gap Bruno flagged. Collision is
# unchanged: the StaticBody stays outside with its inner face still at ±half.
static func make_border_walls(parent: Node2D, half: Vector2, color: Color, use_scaffolding: bool = false) -> void:
	var walls := Node2D.new()
	walls.name = "DayWalls"
	parent.add_child(walls)
	make_wall(walls, Vector2(0, -half.y - 16), Vector2(half.x * 2 + 64, 32), color, Vector2(0, 16), use_scaffolding)
	make_wall(walls, Vector2(0, half.y + 16), Vector2(half.x * 2 + 64, 32), color, Vector2(0, -16), use_scaffolding)
	make_wall(walls, Vector2(-half.x - 16, 0), Vector2(32, half.y * 2 + 64), color, Vector2(16, 0), use_scaffolding)
	make_wall(walls, Vector2(half.x + 16, 0), Vector2(32, half.y * 2 + 64), color, Vector2(-16, 0), use_scaffolding)
	if use_scaffolding:
		WS.place_corner(walls, Vector2(-half.x, -half.y), "tl", -9)
		WS.place_corner(walls, Vector2( half.x, -half.y), "tr", -9)
		WS.place_corner(walls, Vector2(-half.x,  half.y), "bl", -9)
		WS.place_corner(walls, Vector2( half.x,  half.y), "br", -9)


static func make_wall(parent: Node, pos: Vector2, size: Vector2, color: Color, vis_offset: Vector2 = Vector2.ZERO, use_scaffolding: bool = false) -> StaticBody2D:
	var w := StaticBody2D.new()
	w.position = pos
	w.collision_layer = 1
	w.collision_mask = 0
	var vis_root := Node2D.new()
	vis_root.position = vis_offset
	w.add_child(vis_root)
	if use_scaffolding:
		WS.dress_wall(vis_root, size, -9)
	else:
		# Plain ColorRect beam (biome rooms, family homes).
		var cr := ColorRect.new()
		cr.color = color
		cr.z_index = -9
		cr.offset_left = -size.x * 0.5
		cr.offset_top = -size.y * 0.5
		cr.offset_right = size.x * 0.5
		cr.offset_bottom = size.y * 0.5
		cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vis_root.add_child(cr)
	var cs := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = size
	cs.shape = shape
	w.add_child(cs)
	parent.add_child(w)
	return w
