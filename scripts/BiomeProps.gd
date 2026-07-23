extends RefCounted

# ============================================================
# BiomeProps.gd — Run 84 (2026-06-18) — shared real-art prop engine
# ============================================================
# Neutral placement/keying engine shared by the per-biome tileset
# modules (JungleTileset / SwampTileset / CavernTileset / PeakTileset).
# It is NOT the beach module and never reads beach art — each biome
# passes its OWN config (folder + prefix + tuning) so every biome owns
# a dedicated, independently-tunable version.
#
# What a biome module gets from make_props(cfg, ...):
#   * its hand-cut props (Assets/Tilesets/<Biome>_props/<pfx>_prop_NN.png)
#     alpha-keyed at load (grey sheet gutter dropped, largest blob kept,
#     stray label/specks removed) and cached.
#   * obstacle props (the big ones) fence the player paths on blocked
#     cells that touch the floor, a few scatter through the open void,
#     tall props accent sparsely, and a ring frames the room outside the
#     wall — all overlap-free and deterministic (seeded per room).
#   * small props scatter as flat decor on open floor.
# Collision still lives on DreamRoom's hidden wall/gate bodies; these are
# pure decoration that read as obstacles lining the pathways.
#
# cfg keys (all required unless noted):
#   biome_id, dir (res:// folder), prefix, max_index,
#   obstacle_min_px (source height that counts as a big obstacle),
#   obstacle_cells (world-cell height for fenced obstacles),
#   accent_cells (world-cell height for tall accents),
#   decor_cells (world-cell height for flat decor),
#   fence_chance, scatter_chance, accent_chance, ring (band width).
# ============================================================

const WORLD_CELL: float = 32.0
const PROP_Z: int = -12
const GUTTER: Color = Color(0.298, 0.302, 0.322)   # sheet bg (76,77,82) between tiles
const GATE_CLEAR: float = 104.0
const EDGE_KEEPOUT: float = 56.0
const SHORE_BAND_MIN: float = 40.0

# name → { tex, w, h }  (keyed prop texture + keyed source size), cached per dir.
static var _cache: Dictionary = {}
static var _dims_cache: Dictionary = {}   # key → Vector2i raw crop size (cheap probe)
static var _list_cache: Dictionary = {}
static var _shadow_tex: ImageTexture = null


# ---------------------------------------------------------------------------
# Loading + alpha-keying.
# ---------------------------------------------------------------------------
static func _load_png(path: String) -> Image:
	var out: Image = null
	if ResourceLoader.exists(path):
		var res: Resource = ResourceLoader.load(path)
		if res is Texture2D:
			out = (res as Texture2D).get_image()
	if out == null:
		var abs_path: String = ProjectSettings.globalize_path(path)
		if FileAccess.file_exists(abs_path):
			var img := Image.new()
			if img.load(abs_path) == OK:
				out = img
	if out != null and out.get_format() != Image.FORMAT_RGBA8:
		out.convert(Image.FORMAT_RGBA8)
	return out


# Drop the grey sheet gutter everywhere, keep only the largest surviving blob
# (removes label glyphs / specks), then trim to that blob's bounds.
static func _key_prop(src: Image) -> Image:
	var w: int = src.get_width()
	var h: int = src.get_height()
	var removed: PackedByteArray = PackedByteArray()
	removed.resize(w * h)
	for y in range(h):
		for x in range(w):
			var c: Color = src.get_pixel(x, y)
			var rr: float = c.r * 255.0
			var gg: float = c.g * 255.0
			var bb: float = c.b * 255.0
			# grey gutter (76,77,82) with tolerance; covers the cell-border lines too.
			# Kept tight so dark prop pixels survive (only the flat grey bg + grid go).
			if absf(rr - 76.0) + absf(gg - 77.0) + absf(bb - 82.0) < 46.0:
				removed[y * w + x] = 1
	# Largest 8-connected blob of surviving pixels.
	var label: PackedInt32Array = PackedInt32Array()
	label.resize(w * h)
	var best_id: int = 0
	var best_n: int = 0
	var cur: int = 0
	for y in range(h):
		for x in range(w):
			var i0: int = y * w + x
			if removed[i0] == 1 or label[i0] != 0:
				continue
			cur += 1
			var n: int = 0
			var st: Array = [Vector2i(x, y)]
			label[i0] = cur
			while not st.is_empty():
				var q: Vector2i = st.pop_back()
				n += 1
				for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
						Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]:
					var nx: int = q.x + off.x
					var ny: int = q.y + off.y
					if nx < 0 or ny < 0 or nx >= w or ny >= h:
						continue
					var ni: int = ny * w + nx
					if removed[ni] == 1 or label[ni] != 0:
						continue
					label[ni] = cur
					st.append(Vector2i(nx, ny))
			if n > best_n:
				best_n = n
				best_id = cur
	# Bounds of the kept blob.
	var minx: int = w
	var miny: int = h
	var maxx: int = -1
	var maxy: int = -1
	for y in range(h):
		for x in range(w):
			if label[y * w + x] == best_id:
				minx = min(minx, x); miny = min(miny, y)
				maxx = max(maxx, x); maxy = max(maxy, y)
	if maxx < minx:
		return Image.create(1, 1, false, Image.FORMAT_RGBA8)
	var ow: int = maxx - minx + 1
	var oh: int = maxy - miny + 1
	var out := Image.create(ow, oh, false, Image.FORMAT_RGBA8)
	for y in range(oh):
		for x in range(ow):
			var sx: int = minx + x
			var sy: int = miny + y
			var col: Color = src.get_pixel(sx, sy)
			if label[sy * w + sx] != best_id:
				col.a = 0.0
			out.set_pixel(x, y, col)
	return out


# Cheap raw-size probe (no keying) for pool categorization.
static func _dims(dir: String, name: String) -> Vector2i:
	var key: String = dir + name
	if _dims_cache.has(key):
		return _dims_cache[key]
	var src: Image = _load_png(dir + name + ".png")
	var d: Vector2i = Vector2i.ZERO if src == null else Vector2i(src.get_width(), src.get_height())
	_dims_cache[key] = d
	return d


# Returns the keyed prop record { tex, w, h } or null.
static func _prop(dir: String, name: String) -> Dictionary:
	var key: String = dir + name
	if _cache.has(key):
		return _cache[key]
	var src: Image = _load_png(dir + name + ".png")
	if src == null:
		_cache[key] = {}
		return {}
	var keyed: Image = _key_prop(src)
	var rec: Dictionary = {
		"tex": ImageTexture.create_from_image(keyed),
		"w": keyed.get_width(),
		"h": keyed.get_height(),
	}
	_cache[key] = rec
	return rec


# Build (once per dir) the obstacle + decor name pools by probing prop files and
# splitting on keyed source height.
static func _pools(cfg: Dictionary) -> Dictionary:
	var dir: String = cfg["dir"]
	if _list_cache.has(dir):
		return _list_cache[dir]
	var obstacles: Array = []
	var talls: Array = []
	var decor: Array = []
	for i in range(1, int(cfg["max_index"]) + 1):
		var name: String = "%s_prop_%02d" % [cfg["prefix"], i]
		var dim: Vector2i = _dims(dir, name)
		if dim == Vector2i.ZERO:
			continue
		var hh: int = dim.y
		var ww: int = dim.x
		if hh >= int(cfg["obstacle_min_px"]):
			obstacles.append(name)
			if hh >= int(float(ww) * 1.4):     # noticeably taller than wide → accent
				talls.append(name)
		else:
			decor.append(name)
	if obstacles.is_empty():
		obstacles = decor.duplicate()
	if talls.is_empty():
		talls = obstacles.duplicate()
	var out: Dictionary = {"obstacles": obstacles, "talls": talls, "decor": decor}
	_list_cache[dir] = out
	return out


static func available(cfg: Dictionary) -> bool:
	var p: Dictionary = _pools(cfg)
	return not (p["obstacles"] as Array).is_empty()


# ---------------------------------------------------------------------------
# Placement.
# ---------------------------------------------------------------------------
static func make_props(cfg: Dictionary, half: Vector2, layout: RefCounted,
		seed_val: int, gate_positions: Array = []) -> Node2D:
	var root := Node2D.new()
	root.name = "BiomeProps"
	root.z_index = PROP_Z
	root.y_sort_enabled = true
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 40503 + hash(cfg["biome_id"])
	var gw: int = layout.gw
	var gh: int = layout.gh
	var pools: Dictionary = _pools(cfg)
	var obstacles: Array = pools["obstacles"]
	var talls: Array = pools["talls"]
	var decor: Array = pools["decor"]
	var placed: Array = []                         # [{ c, r }]
	var lim_x: float = half.x - EDGE_KEEPOUT
	var lim_y: float = half.y - EDGE_KEEPOUT

	# Path-edge blocked cells (touch the floor) — the fence line, shuffled so the
	# barriers read as natural lines rather than a raster sweep.
	var edge_cells: Array = []
	for cj in range(gh):
		for ci in range(gw):
			if layout.val(ci, cj) != 0 or not _touches_floor(layout, ci, cj):
				continue
			var wc: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
			if absf(wc.x) > lim_x or absf(wc.y) > lim_y:
				continue
			edge_cells.append(wc)
	_shuffle(edge_cells, rng)

	# 1. Obstacle fences lining the player paths.
	for wc in edge_cells:
		if _near_any(wc, gate_positions, GATE_CLEAR):
			continue
		if rng.randf() > float(cfg["fence_chance"]):
			continue
		_try(root, placed, cfg, _pick(obstacles, rng), wc,
			rng.randf_range(cfg["obstacle_cells"] * 0.85, cfg["obstacle_cells"] * 1.2), rng, 0.40, true)

	# 2. A few obstacles about the open interior void.
	for cj in range(gh):
		for ci in range(gw):
			if layout.val(ci, cj) != 0 or _touches_floor(layout, ci, cj):
				continue
			if rng.randf() > float(cfg["scatter_chance"]):
				continue
			var wc2: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
			if absf(wc2.x) > lim_x or absf(wc2.y) > lim_y:
				continue
			if _near_any(wc2, gate_positions, GATE_CLEAR):
				continue
			_try(root, placed, cfg, _pick(obstacles, rng), wc2,
				rng.randf_range(cfg["obstacle_cells"] * 0.75, cfg["obstacle_cells"]), rng, 0.40, true)

	# 3. Sparse tall accents (trees / crystals / stalagmites) along path edges.
	for wc3 in edge_cells:
		if rng.randf() > float(cfg["accent_chance"]):
			continue
		if _near_any(wc3, gate_positions, GATE_CLEAR):
			continue
		_try(root, placed, cfg, _pick(talls, rng), wc3,
			rng.randf_range(cfg["accent_cells"] * 0.85, cfg["accent_cells"] * 1.15), rng, 0.30, true)

	# 4. Flat decor scattered on open floor.
	if not decor.is_empty():
		var dcount: int = int(float(gw * gh) / 30.0)
		for _i in range(dcount):
			var ci2: int = rng.randi_range(1, gw - 2)
			var cj2: int = rng.randi_range(1, gh - 2)
			if layout.val(ci2, cj2) != 1:
				continue
			var dwc: Vector2 = layout.cell_to_world(Vector2i(ci2, cj2))
			if _near_any(dwc, gate_positions, GATE_CLEAR * 0.6):
				continue
			_try(root, placed, cfg, _pick(decor, rng), dwc,
				rng.randf_range(cfg["decor_cells"] * 0.8, cfg["decor_cells"] * 1.1), rng, 0.2)

	# 5. Outside ring framing the room beyond the wall.
	var ring: float = float(cfg["ring"])
	var ring_n: int = int((half.x + half.y) / 50.0)
	for _j in range(ring_n):
		var pos: Vector2 = _ring_point(half, SHORE_BAND_MIN, SHORE_BAND_MIN + ring, rng)
		if _near_any(pos, gate_positions, GATE_CLEAR):
			continue
		_try(root, placed, cfg, _pick(obstacles, rng), pos,
			rng.randf_range(cfg["obstacle_cells"] * 0.8, cfg["obstacle_cells"] * 1.15), rng, 0.38)
	return root


static func _pick(arr: Array, rng: RandomNumberGenerator) -> String:
	return arr[rng.randi() % arr.size()]


# Place a prop at base unless its foot-circle overlaps an existing prop.
static func _try(root: Node2D, placed: Array, cfg: Dictionary, name: String,
		base: Vector2, height_cells: float, rng: RandomNumberGenerator, foot_frac: float,
		overhead: bool = false) -> bool:
	var rec: Dictionary = _prop(cfg["dir"], name)
	if rec.is_empty():
		return false
	var tex: ImageTexture = rec["tex"]
	var draw_w: float = float(rec["w"]) * (WORLD_CELL * height_cells / float(rec["h"]))
	var r: float = draw_w * foot_frac
	for p in placed:
		if base.distance_to(p["c"]) < r + p["r"]:
			return false
	_add_prop(root, tex, base, height_cells, int(WORLD_CELL * 0.28), overhead)
	placed.append({ "c": base, "r": r })
	return true


static func _add_prop(root: Node2D, tex: ImageTexture, base: Vector2,
		height_cells: float, sink: int, overhead: bool = false) -> void:
	var th: float = float(tex.get_height())
	var tw: float = float(tex.get_width())
	var sc: float = (WORLD_CELL * height_cells) / th
	var draw_h: float = th * sc
	var feet: Vector2 = base + Vector2(0.0, float(sink))
	var ysort: bool = overhead and root.y_sort_enabled
	if ysort:
		var wrap := Node2D.new()
		wrap.position = feet
		wrap.z_as_relative = false
		wrap.z_index = 0
		var sh := Sprite2D.new()
		var stex: ImageTexture = _shadow_texture()
		sh.texture = stex
		sh.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		var sh_w: float = tw * sc * 0.6
		var sh_h: float = maxf(6.0, sh_w * 0.4)
		sh.scale = Vector2(sh_w / float(stex.get_width()), sh_h / float(stex.get_height()))
		wrap.add_child(sh)
		var spr := Sprite2D.new()
		spr.texture = tex
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		spr.scale = Vector2(sc, sc)
		spr.position = Vector2(0.0, -draw_h * 0.5)
		wrap.add_child(spr)
		root.add_child(wrap)
	else:
		var sh := Sprite2D.new()
		var stex: ImageTexture = _shadow_texture()
		sh.texture = stex
		sh.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		var sh_w: float = tw * sc * 0.6
		var sh_h: float = maxf(6.0, sh_w * 0.4)
		sh.scale = Vector2(sh_w / float(stex.get_width()), sh_h / float(stex.get_height()))
		sh.position = feet
		root.add_child(sh)
		var spr := Sprite2D.new()
		spr.texture = tex
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		spr.scale = Vector2(sc, sc)
		spr.position = feet - Vector2(0.0, draw_h * 0.5)
		if overhead:
			spr.z_as_relative = false
			spr.z_index = RunState.BARRIER_OVERHANG_Z
		root.add_child(spr)


static func _shadow_texture() -> ImageTexture:
	if _shadow_tex != null:
		return _shadow_tex
	var w: int = 128
	var h: int = 64
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in range(h):
		for x in range(w):
			var nx: float = (float(x) - float(w) * 0.5) / (float(w) * 0.5)
			var ny: float = (float(y) - float(h) * 0.5) / (float(h) * 0.5)
			var d: float = nx * nx + ny * ny
			var a: float = clampf(1.0 - d, 0.0, 1.0)
			a = pow(a, 1.3) * 0.42
			img.set_pixel(x, y, Color(0.08, 0.086, 0.11, a))
	_shadow_tex = ImageTexture.create_from_image(img)
	return _shadow_tex


static func _shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


static func _near_any(p: Vector2, pts: Array, r: float) -> bool:
	for q in pts:
		if p.distance_to(q as Vector2) < r:
			return true
	return false


static func _touches_floor(layout: RefCounted, ci: int, cj: int) -> bool:
	for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
			Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]:
		var v: int = layout.val(ci + off.x, cj + off.y)
		if v == 1 or v == 3:
			return true
	return false


static func _ring_point(half: Vector2, b0: float, b1: float, rng: RandomNumberGenerator) -> Vector2:
	var side: int = rng.randi() % 4
	var band: float = rng.randf_range(b0, b1)
	match side:
		0:  return Vector2(rng.randf_range(-half.x - b1, half.x + b1), -half.y - band)
		1:  return Vector2(rng.randf_range(-half.x - b1, half.x + b1),  half.y + band)
		2:  return Vector2(-half.x - band, rng.randf_range(-half.y - b1, half.y + b1))
		_:  return Vector2( half.x + band, rng.randf_range(-half.y - b1, half.y + b1))
