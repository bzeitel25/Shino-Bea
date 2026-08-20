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

# Run 162 — corner anchoring. The corner brackets are L-shaped pieces whose
# JOINT sits in one texture corner and whose arms run out toward the opposite
# edges. Sampling the arm a few px in from the far edge (past the diagonal
# brace and any crop taper) tells us exactly where the rail tiles line up
# inside the piece. EDGE_INSET is that sample distance.
const EDGE_INSET: int = 8

static var _tex_cache: Dictionary = {}      # name -> ImageTexture (null cached as false)
static var _anchor_cache: Dictionary = {}   # corner name -> Vector2 anchor (world px)


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


# ===========================================================================
# JOINT PIECES — corners, tees, crosses.
# ===========================================================================
# Every joint piece (scaff_corner_*, scaff_cross_*) is built from the SAME
# beams as the rails: its arms are literally scaff_h_tile / scaff_v_tile,
# clipped on the inner side. Verified by cross-correlating the joint art
# against the rail art — the plank grain and black outlines match exactly at
# one offset.
#
# So a joint lines up with its walls iff we anchor it by ARM, not by texture
# centre: find the arm's outer edge inside the texture, add half a rail
# thickness, and that point is the wall centreline dress_wall drew on.
#
# Run 162 fix: place_corner used to drop the sprite's geometric CENTRE on the
# junction, which shoved the joint ~11px diagonally outward — the brackets
# floated off the ends of the beams instead of continuing them.
# ---------------------------------------------------------------------------

# Sample-line spec: >= 0 → index from the top/left edge,
#                   <  0 → index from the bottom/right edge (-1 = last line).
const _SPEC_FAR: int = -1 - EDGE_INSET


# _arm_bounds — scan one row and one column of a joint texture and return the
# arm bands as Vector4i(v_min, h_min, v_max, h_max) in native texture pixels:
#   v_min/v_max — x range of the VERTICAL arm   (v_min = scaff_v_tile x=0)
#   h_min/h_max — y range of the HORIZONTAL arm (h_min = scaff_h_tile y=0)
# Returns all -1 when the art can't be read.
static func _arm_bounds(img: Image, v_row_spec: int, h_col_spec: int) -> Vector4i:
	var miss := Vector4i(-1, -1, -1, -1)
	var w: int = img.get_width()
	var h: int = img.get_height()
	if w < 32 or h < 32:
		return miss
	var v_row: int = clampi(v_row_spec if v_row_spec >= 0 else h + v_row_spec, 0, h - 1)
	var h_col: int = clampi(h_col_spec if h_col_spec >= 0 else w + h_col_spec, 0, w - 1)

	var v_min: int = -1
	var v_max: int = -1
	for x in range(w):
		if img.get_pixel(x, v_row).a > 0.03:
			if v_min < 0:
				v_min = x
			v_max = x
	var h_min: int = -1
	var h_max: int = -1
	for y in range(h):
		if img.get_pixel(h_col, y).a > 0.03:
			if h_min < 0:
				h_min = y
			h_max = y
	if v_min < 0 or h_min < 0:
		return miss
	return Vector4i(v_min, h_min, v_max, h_max)


# _joint_bounds — cached _arm_bounds for a named part.
static func _joint_bounds(pname: String, v_row_spec: int, h_col_spec: int) -> Vector4i:
	if _anchor_cache.has(pname):
		return _anchor_cache[pname]
	var out := Vector4i(-1, -1, -1, -1)
	var tex: ImageTexture = _tex(pname)
	if tex != null:
		var img: Image = tex.get_image()
		if img != null:
			if img.is_compressed():
				img.decompress()
			out = _arm_bounds(img, v_row_spec, h_col_spec)
	_anchor_cache[pname] = out
	return out


# _joint_anchor — offset (world px) from a joint sprite's TOP-LEFT corner to
# the wall-centreline intersection it must sit on.
static func _joint_anchor(pname: String, v_row_spec: int, h_col_spec: int) -> Vector2:
	var b: Vector4i = _joint_bounds(pname, v_row_spec, h_col_spec)
	var tex: ImageTexture = _tex(pname)
	if b.x < 0 or tex == null:
		# Fallback: geometric centre of the piece.
		if tex == null:
			return Vector2.ZERO
		return Vector2(float(tex.get_width()), float(tex.get_height())) * 0.5 * SCALE
	var htex: ImageTexture = _tex("scaff_h_tile")
	var vtex: ImageTexture = _tex("scaff_v_tile")
	var v_thick: float = float(vtex.get_width()) if vtex != null else 108.0
	var h_thick: float = float(htex.get_height()) if htex != null else 109.0
	# The rail tiles carry their own transparent margin; the joint's arm band we
	# just measured is the INKED edge, so subtract that margin to get back to the
	# tile's true origin. (Keeps the maths right if the parts are ever re-cut.)
	var v_pad: float = float(_tile_pad("scaff_v_tile", false))
	var h_pad: float = float(_tile_pad("scaff_h_tile", true))
	# dress_wall draws each rail CENTRED on the wall line, so the joint's arms
	# must be centred there too: tile origin + half a rail thickness.
	return Vector2(
		float(b.x) - v_pad + v_thick * 0.5,
		float(b.y) - h_pad + h_thick * 0.5) * SCALE


# _tile_pad — transparent margin on the OUTER edge of a rail tile, in native px.
# horizontal=true measures rows (top margin), false measures cols (left margin).
static func _tile_pad(pname: String, horizontal: bool) -> int:
	var key: String = pname + ("_padh" if horizontal else "_padv")
	if _anchor_cache.has(key):
		return int(_anchor_cache[key])
	var pad: int = 0
	var tex: ImageTexture = _tex(pname)
	if tex != null:
		var img: Image = tex.get_image()
		if img != null:
			if img.is_compressed():
				img.decompress()
			var mid_main: int = int(float(img.get_width() if horizontal else img.get_height()) * 0.5)
			var span: int = img.get_height() if horizontal else img.get_width()
			for k in range(span):
				var alpha: float = img.get_pixel(mid_main, k).a if horizontal else img.get_pixel(k, mid_main).a
				if alpha > 0.03:
					pad = k
					break
	_anchor_cache[key] = pad
	return pad


static func _add_joint(parent: Node2D, pos: Vector2, tex: Texture2D, anchor: Vector2, z: int) -> void:
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.scale = Vector2(SCALE, SCALE)
	spr.centered = false
	spr.z_index = z
	spr.position = pos - anchor
	parent.add_child(spr)


# ---------------------------------------------------------------------------
# place_corner — L-joint bracket. corner: "tl", "tr", "bl", "br", naming the
# quadrant the JOINT sits in ("tl" = walls run right + down from pos).
# pos is the INTERSECTION OF THE TWO WALL CENTRELINES.
# ---------------------------------------------------------------------------
static func place_corner(parent: Node2D, pos: Vector2, corner: String, z: int, _unused := 0.0) -> void:
	var pname: String = "scaff_corner_%s" % corner
	var tex: ImageTexture = _tex(pname)
	if tex == null:
		return
	# Sample each arm near its FAR end, past the diagonal brace:
	#   "t*" → vertical arm runs DOWN  → sample near the bottom edge
	#   "b*" → vertical arm runs UP    → sample near the top edge
	#   "*l" → horizontal arm runs RIGHT → sample near the right edge
	#   "*r" → horizontal arm runs LEFT  → sample near the left edge
	var v_spec: int = _SPEC_FAR if corner.begins_with("t") else EDGE_INSET
	var h_spec: int = _SPEC_FAR if corner.ends_with("l") else EDGE_INSET
	_add_joint(parent, pos, tex, _joint_anchor(pname, v_spec, h_spec), z)


# ---------------------------------------------------------------------------
# place_cross — 4-way junction (both walls run straight through pos).
# ---------------------------------------------------------------------------
const CROSS_PART: String = "scaff_cross_a"

static func place_cross(parent: Node2D, pos: Vector2, z: int, _unused := 0.0) -> void:
	var tex: ImageTexture = _tex(CROSS_PART)
	if tex == null:
		return
	_add_joint(parent, pos, tex, _joint_anchor(CROSS_PART, EDGE_INSET, EDGE_INSET), z)


# ---------------------------------------------------------------------------
# place_tee — 3-way junction, built by cropping the unused arm off the cross
# piece so the surviving arms stay pixel-identical to the rails.
# stem: the direction the BRANCH wall runs — "up", "down", "left", "right".
# ---------------------------------------------------------------------------
static func place_tee(parent: Node2D, pos: Vector2, stem: String, z: int, _unused := 0.0) -> void:
	var src: ImageTexture = _tex(CROSS_PART)
	if src == null:
		return
	var bounds: Vector4i = _joint_bounds(CROSS_PART, EDGE_INSET, EDGE_INSET)
	var anchor: Vector2 = _joint_anchor(CROSS_PART, EDGE_INSET, EDGE_INSET)
	if bounds.x < 0:
		_add_joint(parent, pos, src, anchor, z)
		return

	var cache_key: String = "%s_tee_%s" % [CROSS_PART, stem]
	var tex: ImageTexture = null
	if _tex_cache.has(cache_key) and _tex_cache[cache_key] is ImageTexture:
		tex = _tex_cache[cache_key]
	else:
		var img: Image = src.get_image()
		if img == null:
			return
		if img.is_compressed():
			img.decompress()
		var w: int = img.get_width()
		var h: int = img.get_height()
		# Trim the arm OPPOSITE the stem, cutting flush with the joint block.
		var rect := Rect2i(0, 0, w, h)
		match stem:
			"up":    rect = Rect2i(0, 0, w, bounds.w + 1)                 # drop the down arm
			"down":  rect = Rect2i(0, bounds.y, w, h - bounds.y)          # drop the up arm
			"left":  rect = Rect2i(0, 0, bounds.z + 1, h)                 # drop the right arm
			"right": rect = Rect2i(bounds.x, 0, w - bounds.x, h)          # drop the left arm
		tex = ImageTexture.create_from_image(img.get_region(rect))
		_tex_cache[cache_key] = tex
		# Cropping from the top/left moves the sprite origin — shift the anchor.
		_anchor_cache[cache_key] = anchor - Vector2(float(rect.position.x), float(rect.position.y)) * SCALE

	var use_anchor: Vector2 = anchor
	if _anchor_cache.has(cache_key) and _anchor_cache[cache_key] is Vector2:
		use_anchor = _anchor_cache[cache_key]
	_add_joint(parent, pos, tex, use_anchor, z)
