extends RefCounted

# ============================================================
# WoodScaffolding.gd — Run 154 (2026-07-18) — real-art wood border
# ============================================================
# Replaces the placeholder ColorRect timber rails in DayTerrain
# (town border) and Dojo (interior walls) with tiled sprites cut
# from the Wood_Scaffolding sheet (Assets/Tilesets/).
#
# ALL pieces render at NATIVE pixel size (1:1 with world pixels).
# No Lanczos resampling, no fractional scaling — clean pixel art.
#
# Pieces pre-cropped + teal-keyed in Wood_Scaffolding_parts/:
#   scaff_h_tile       — 256×109 tileable horizontal double-rail
#   scaff_v_tile       — 108×256 tileable vertical double-rail
#   scaff_h_short      — 109×108 short horizontal plank (crossbar on V walls)
#   scaff_v_short      — 108×120 short vertical plank  (post on H walls)
#   scaff_corner_tl/tr/bl/br — corner brackets (~286×296)
# ============================================================

const PARTS_DIR: String = "res://Assets/Tilesets/Wood_Scaffolding_parts/"
# Scale factor: old beam was 14px, native rail art is 109px → 14/109 ≈ 0.128.
# Using 0.15 for slightly more visible detail.
const SCALE: float = 0.15

static var _tex_cache: Dictionary = {}   # name -> ImageTexture (null cached as false)


# ---------------------------------------------------------------------------
# Asset loading — native textures, no resampling.
# ---------------------------------------------------------------------------
static func _tex(pname: String) -> ImageTexture:
	if _tex_cache.has(pname):
		var c = _tex_cache[pname]
		return c if c is ImageTexture else null
	var p: String = PARTS_DIR + pname + ".png"
	var tex: ImageTexture = null
	if ResourceLoader.exists(p):
		var r: Resource = ResourceLoader.load(p)
		if r is Texture2D:
			tex = r as ImageTexture
			if tex == null:
				# CompressedTexture — convert to ImageTexture for region crops.
				tex = ImageTexture.create_from_image((r as Texture2D).get_image())
	if tex == null:
		var abs_path: String = ProjectSettings.globalize_path(p)
		if FileAccess.file_exists(abs_path):
			var im := Image.new()
			if im.load(abs_path) == OK:
				im.convert(Image.FORMAT_RGBA8)
				tex = ImageTexture.create_from_image(im)
	if tex == null:
		push_warning("[WoodScaffolding] Missing art: %s" % p)
	_tex_cache[pname] = tex if tex != null else false
	return tex


# ---------------------------------------------------------------------------
# dress_wall — tile scaffolding sprites along a wall run.
#
# vis_root : Node2D child of the body where visuals go.
# size     : collision rect size (determines orientation + run length).
# z        : z_index for ALL visuals (no z+1 — prevents bleed under facades).
# ---------------------------------------------------------------------------
static func dress_wall(vis_root: Node2D, size: Vector2, z: int, _unused := 0.0) -> void:
	var horizontal: bool = size.x >= size.y
	var run: float = size.x if horizontal else size.y

	# --- Tile the main rail run -----------------------------------------------
	# Scale art to match the old ~14px beam thickness. Native h_tile is 109px
	# tall, so SCALE = 14/109 ≈ 0.128. Rendered with NEAREST for crisp pixels.
	var tile_tex: ImageTexture = _tex("scaff_h_tile") if horizontal else _tex("scaff_v_tile")
	if tile_tex == null:
		return

	var tile_w: float = float(tile_tex.get_width())
	var tile_h: float = float(tile_tex.get_height())
	var tile_main: float = (tile_w if horizontal else tile_h) * SCALE
	var tile_cross: float = (tile_h if horizontal else tile_w) * SCALE

	var n: int = int(ceil(run / tile_main))
	var start: float = -run * 0.5

	for i in range(n):
		var off: float = start + float(i) * tile_main
		var remaining: float = run - float(i) * tile_main
		var clip: bool = remaining < tile_main and i == n - 1
		var tex_to_use: ImageTexture = tile_tex

		if clip and remaining > 4.0:
			var src: Image = tile_tex.get_image()
			if horizontal:
				tex_to_use = ImageTexture.create_from_image(
					src.get_region(Rect2i(0, 0, mini(int(remaining / SCALE), src.get_width()), src.get_height())))
			else:
				tex_to_use = ImageTexture.create_from_image(
					src.get_region(Rect2i(0, 0, src.get_width(), mini(int(remaining / SCALE), src.get_height()))))
		elif clip:
			continue

		var spr := Sprite2D.new()
		spr.texture = tex_to_use
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		spr.scale = Vector2(SCALE, SCALE)
		spr.centered = false
		spr.z_index = z
		if horizontal:
			spr.position = Vector2(off, -tile_cross * 0.5)
		else:
			spr.position = Vector2(-tile_cross * 0.5, off)
		vis_root.add_child(spr)

	# --- Crossbar joints at regular intervals ---------------------------------
	var joint_tex: ImageTexture
	if horizontal:
		joint_tex = _tex("scaff_v_short")
	else:
		joint_tex = _tex("scaff_h_short")

	if joint_tex != null:
		var spacing: float = 180.0
		var steps: int = maxi(int(run / spacing), 1)
		for i in range(steps + 1):
			var t: float = start + run * float(i) / float(steps)
			var jspr := Sprite2D.new()
			jspr.texture = joint_tex
			jspr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			jspr.scale = Vector2(SCALE, SCALE)
			jspr.z_index = z
			if horizontal:
				jspr.position = Vector2(t, 0)
			else:
				jspr.position = Vector2(0, t)
			vis_root.add_child(jspr)


# ---------------------------------------------------------------------------
# place_corner — corner bracket sprite at a wall intersection.
# corner: "tl", "tr", "bl", "br"
# ---------------------------------------------------------------------------
static func place_corner(parent: Node2D, pos: Vector2, corner: String, z: int, _unused := 0.0) -> void:
	var tex: ImageTexture = _tex("scaff_corner_%s" % corner)
	if tex == null:
		return
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.scale = Vector2(SCALE, SCALE)
	spr.z_index = z
	# At SCALE the corner art is ~43×44 px. Its arms extend outward from the
	# joint. Position the CENTER of the scaled sprite on pos so the arms
	# overlap directly with the adjacent rail sprites.
	spr.position = pos
	parent.add_child(spr)
