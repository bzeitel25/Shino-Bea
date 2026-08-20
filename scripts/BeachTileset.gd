extends RefCounted

# ============================================================
# BeachTileset.gd — Run 75 (2026-06-17) — real-art beach biome
# ============================================================
# First hand-authored tileset wired into the procedural generator.
# Source sheet: res://Assets/Tilesets/Beach Tileset.png (HD pixel art,
# NOT an upscale — so it is sampled at native res and the baked ground
# is rendered large, then the Sprite2D scales it down to world size).
#
# What this module produces for the BEACH biome only (DreamTerrain
# branches to it; every other biome keeps the procedural ramp path):
#   * a high-res baked GROUND image — sand on FLOOR/VOID cells, animated-
#     water tile on V_WATER cells, foam ring at every water border, and
#     scattered flat decor (shells / starfish / seaweed) on open floor.
#   * a Y-stable PROPS node — blocked (V_VOID) cells become natural ROCK
#     BARRIERS (rock clusters), with sparse palm accents. A ring of rocks
#     is also scattered just OUTSIDE the arena so the surround reads as a
#     water / rock / sand shore (the animated ocean shader supplies the
#     sea + sand skirt; see DreamTerrain.tune_ocean_for_beach()).
#
# Tile coordinates were mapped off the sheet's 140.5px grid (sand block
# origin 846,46) and its labelled prop bands. Props are alpha-keyed at
# load (flood-fill the gutter colour, keep the largest blob, strip the
# white separator slivers) and cached.
#
# Runtime image load uses ResourceLoader when the PNG has been imported,
# else Image.load() on the globalized path — so it works the first time
# even before the editor import pass.
# ============================================================

const SHEET_PATH: String = "res://Assets/Tilesets/Beach Tileset.png"
const SHEET2_PATH: String = "res://Assets/Tilesets/Beach and Island Tileset 2.png"
const GUTTER: Color = Color(0.3098, 0.3216, 0.3451)   # sheet bg (79,82,88) between tiles
const CELL_PX: int = 64                          # baked px per 32px world cell
const WORLD_CELL: float = 32.0
const FOAM_PX: int = 10                           # foam ring width (baked px)
const APRON_CELLS: int = 5                        # darker-sand shore baked beyond the arena

# Sand grid: 8x4 tiles, pitch 140.5, origin (846,46). 7px inset drops seams.
const SAND_X0: float = 846.0
const SAND_Y0: float = 46.0
const SAND_PITCH: float = 140.5
const SAND_INSET: int = 7

# (col,row) of sand tiles used as walkable / blocked floor + sparse variants.
const FLOOR_CR: Array = [[0, 1], [1, 1], [2, 1], [3, 0], [4, 2], [1, 3]]
const PEBBLE_CR: Array = [[5, 0], [6, 0]]
const WATER_RECT: Array = [54, 1132, 128, 128]    # animated-water frame 0 (x,y,w,h)

# Prop source rects (x, y, w, h) on the sheet. Rocks + palms now come from the
# hand-authored Beach_props PNGs (override path), so only the flat shore decor is
# still sliced from the main sheet here.
const PROP_RECTS: Dictionary = {
	"shell":    [2112, 702, 96, 96],
	"starfish": [2522, 697, 111, 101],
	"seaweed":  [2647, 697, 123, 133],
}
# Run 81: the new hand-authored "Beach Rocks" sheet, sliced into 8 distinct
# clusters (Beach_props/brock_1..8.png — picked up via the override path, so no
# sheet rects are needed). Palms = the new Palm Trees sheet, sliced into
# Beach_props/bpalm_1..5.png (small → large). The old rock_a/b/d + palm_* assets
# were retired; nothing references them anymore.
const ROCK_NAMES: Array = ["brock_1", "brock_2", "brock_3", "brock_4",
	"brock_5", "brock_6", "brock_7", "brock_8"]
const PALM_NAMES: Array = ["bpalm_1", "bpalm_2", "bpalm_3", "bpalm_4", "bpalm_5"]
const DECOR_NAMES: Array = ["shell", "starfish", "seaweed", "seaweed"]

# Run 88: the hand-sliced "Beach Extras" sheet (Beach_props/bx_*.png), loaded as
# override props (no sheet rect). LOG / ANCHOR / BOAT are floor BARRIERS — each
# gets its own "dashable_barrier" collision body, so the ninja DASH phases them
# like the inner rock barriers, but walking is blocked. Anchor + boat are placed
# VERY sparingly. Everything else is flat, run-over GROUND decor (no collision),
# baked into the ground image alongside the original shell/starfish/seaweed.
const LOG_NAMES: Array = ["bx_log_sticks", "bx_log_stack", "bx_log_round", "bx_log_birch"]
const ANCHOR_NAME: String = "bx_anchor"
const BOAT_NAME: String = "bx_boat"
# [name, height (world cells), weight] — flat decor sampled into the baked ground.
const DECOR_TABLE: Array = [
	["shell", 0.70, 2], ["starfish", 0.70, 2], ["seaweed", 1.05, 2],
	["bx_scallop", 0.55, 1], ["bx_shell_pink", 0.42, 1], ["bx_shell_pink2", 0.42, 1],
	["bx_coral_blue", 0.50, 1], ["bx_coral_rock", 0.85, 1],
	["bx_star_red", 0.78, 1], ["bx_star_orange", 0.58, 1], ["bx_star_small", 0.46, 1],
	["bx_pebbles", 0.68, 2], ["bx_grass_blade", 0.95, 1], ["bx_grass_clump", 0.92, 2],
	["bx_kelp", 1.10, 1], ["bx_bones", 0.78, 1], ["bx_seaweed_rock", 0.95, 1],
]

# Placement keep-outs (Run 81). Props never overlap each other, a doorway, or the
# Cliff Faces border frame: each placed prop records a foot-circle that later props
# must clear, interior props stay CLIFF_KEEPOUT inside the arena edge, and the
# outside shore ring starts beyond the wall's outer face.
const CLIFF_KEEPOUT: float = 64.0    # ≈ one cliff tile; clears the border frame
const GATE_CLEAR: float = 104.0      # doorway / exit keep-out radius
const SHORE_BAND_MIN: float = 54.0   # shore ring starts past the cliff outer face

# Sheet 2 (cliffs & caves) — arena border walls + cave-mouth doors.
const PROP2_RECTS: Dictionary = {
	"cave":     [2200, 60, 260, 248],
	"rockwall": [1438, 838, 128, 168],
	"rubble":   [1716, 892, 132, 118],
}
const WALL_NAMES: Array = ["rockwall", "rubble", "brock_6", "brock_8"]

# Cliff Faces sheet (Run 80) — a hand-authored arena-border FRAME that replaces
# the scattered rock-cluster walls. It's a 5x4 grid of ~140px tiles on a
# transparent background: four corners, three top / three bottom edge variants,
# and two left / two right edge variants. We lay them as a continuous 9-slice
# ring so the arena edge reads as a clean wall. Rects below are the OPAQUE
# bounds of each tile (bottom row mirrors the top — the sheet is 750x750 and
# vertically symmetric, 95px margins top & bottom).
const CLIFF_PATH: String = "res://Assets/Tilesets/Beach_props/Cliff Faces .png"
const CLIFF_TILE: float = 58.0                  # world px per cliff tile (smaller = finer wall, crisper HD art)
const CLIFF_SEAM: float = 1.5                   # sub-pixel bleed so tiles touch with no sand hairline
const CAVE_CHANCE: float = 0.3                  # how often a south gate gets a cave ARCH instead of totems (totems are the norm)
const CAVE_HEIGHT_TILES: float = 2.7            # cave height in CLIFF_TILE units (bigger → overlaps wall, more visible)
const CAVE_RISE_TILES: float = -0.15            # vertical nudge of the cave center off the wall row
const CAVE_OPEN_FRAC: float = 0.27              # wall gap = this × cave_w: just clears the arch HOLE, so the
                                                # rest of the (bigger) cave overlaps in FRONT of the wall
const CAVE_OPEN_OFFSET_FRAC: float = 0.038      # cave.png arch hole is right-of-center; shift left to center it
# Run 82: the cave arch's overhead lintel (top band of the art) is REDRAWN over
# the heroes so a ninja standing in the doorway passes UNDER the arch instead of
# floating on top of it. The base cave still draws behind (PROP_Z); only this top
# band is lifted above the hero/enemy bodies (which sit at z 0).
const CAVE_OVERHANG_FRAC: float = 0.74          # fraction of the cave height (from the top) drawn OVER heroes.
                                                # Reaches past the gate row so a hero standing IN the doorway pocket
                                                # (Run 84) is occluded by the arch ring/legs; the doorway HOLE is
                                                # transparent in the art so the hero still shows THROUGH it (under the arch).
# Cave arch occludes heroes at the SAME global barrier depth (RunState.BARRIER_OVERHANG_Z):
# above hero body (z 2), below combat FX (z 4+) / nameplates (z 20). Used at the two
# z assignments below (base arch sprite + overhead lintel).

# Exit totems (Run 83) — hand-authored stone markers that flank every gate as a
# PAIR, standing on the cliff wall on either side of the opening. The front-facing
# totem (totem_s) marks SOUTH/north gates, flanked E&W; the column totem (totem_e)
# marks EAST/west gates, flanked N&S. A south gate that rolls a cave arch
# (CAVE_CHANCE) shows the arch INSTEAD of its totems.
const TOTEM_H_CELLS: float = 2.5                # totem height in world cells
const TOTEM_GATE_GAP: float = 58.0             # gate-center → totem-center; clears the opening
const TOTEM_GATE_GAP_S: float = 26.0           # extra push for the SOUTH totem of an E/W gate (its base sits lower, so nudge it clear of the opening)
const CLIFF_CORNERS: Dictionary = {
	"corner_tl": [25, 95, 130, 137],
	"corner_tr": [598, 95, 128, 137],
	"corner_bl": [25, 518, 130, 137],
	"corner_br": [598, 518, 128, 137],
}
const CLIFF_TOP: Array    = [[166, 95, 136, 137], [306, 95, 140, 137], [449, 95, 136, 137]]
const CLIFF_BOTTOM: Array = [[166, 518, 136, 137], [306, 518, 140, 137], [449, 518, 136, 137]]
const CLIFF_LEFT: Array   = [[25, 237, 130, 136], [25, 376, 130, 138]]
const CLIFF_RIGHT: Array  = [[598, 237, 128, 136], [598, 376, 128, 138]]

# Sampled sheet palette → feeds the ocean shader so sea + skirt match.
const C_SAND:  Color = Color(0.989, 0.927, 0.793)
const C_SHORE: Color = Color(0.411, 0.746, 0.724)
const C_LIGHT: Color = Color(0.173, 0.492, 0.682)
const C_MID:   Color = Color(0.145, 0.353, 0.583)
const C_DEEP:  Color = Color(0.075, 0.205, 0.40)
const C_FOAM:  Color = Color(0.91, 0.96, 0.98)

# Z bands: ground sits at DreamTerrain's -35; props ride just above the
# ground but below the heroes (z 0) — barrier cells are unwalkable anyway.
const GROUND_Z: int = -34
const PROP_Z: int = -12
# Palm layering: the trunk's very BASE keeps PROP_Z (heroes + rocks may cover it),
# but everything above it (trunk + fronds) is lifted to PALM_CANOPY_Z so the canopy
# always draws OVER rock barriers (rocks sit at absolute z 0). Kept below the cliff
# wall frame (BARRIER_OVERHANG_Z = 3) so distant coast palms stay behind the border.
const PALM_BASE_FRAC: float = 0.22   # bottom slice of the art treated as "the base"
const PALM_CANOPY_Z: int = 1
# Barrier rocks/logs draw ABOVE the hero body sprites so a ninja walking into a
# barrier is occluded by it (reads as standing BEHIND the rock) instead of floating
# on top of its tip; a DASH lifts the hero over it. This is the GLOBAL rule — the z
# value lives on the RunState autoload (RunState.BARRIER_OVERHANG_Z) so every biome
# shares it. Only BARRIER props get this — decor scatter / palms stay at PROP_Z.

static var _sheet_cache: Image = null
static var _sheet_tried: bool = false
static var _sheet2_cache: Image = null
static var _sheet2_tried: bool = false
static var _cliff_cache: Image = null
static var _cliff_tried: bool = false
static var _cliff_tex_cache: Dictionary = {}   # key → sliced cliff ImageTexture
static var _tile_cache: Dictionary = {}     # key → resized Image (ground tiles)
static var _prop_cache: Dictionary = {}     # name → ImageTexture (keyed prop)
static var _shadow_tex: ImageTexture = null  # soft ellipse cast under props


# ---------------------------------------------------------------------------
# Sheet loading (import-agnostic) + availability probe.
# ---------------------------------------------------------------------------
static func available() -> bool:
	return _sheet() != null


# Walls need the cliff frame (preferred) OR the old sheet-2 rock pieces
# (fallback); ground/props only need the first sheet.
static func available_walls() -> bool:
	return _sheet() != null and (_cliff_sheet() != null or _sheet2() != null)


static func _cliff_sheet() -> Image:
	if not _cliff_tried:
		_cliff_tried = true
		_cliff_cache = _load_png(CLIFF_PATH)
	return _cliff_cache


static func _load_png(path: String) -> Image:
	var out: Image = null
	# Preferred: the imported texture (export-safe once the editor imports it).
	if ResourceLoader.exists(path):
		var res: Resource = ResourceLoader.load(path)
		if res is Texture2D:
			out = (res as Texture2D).get_image()
	# Fallback: read the raw PNG directly (works before the import pass).
	if out == null:
		var img := Image.new()
		if img.load(ProjectSettings.globalize_path(path)) == OK:
			out = img
	if out != null:
		out.convert(Image.FORMAT_RGBA8)
	else:
		push_warning("[BeachTileset] Could not load %s." % path)
	return out


static func _sheet() -> Image:
	if not _sheet_tried:
		_sheet_tried = true
		_sheet_cache = _load_png(SHEET_PATH)
	return _sheet_cache


static func _sheet2() -> Image:
	if not _sheet2_tried:
		_sheet2_tried = true
		_sheet2_cache = _load_png(SHEET2_PATH)
	return _sheet2_cache


# ---------------------------------------------------------------------------
# Ground tile helpers (cropped + resized to CELL_PX, cached).
# ---------------------------------------------------------------------------
static func _sand_rect(c: int, r: int) -> Rect2i:
	var x: int = int(SAND_X0 + float(c) * SAND_PITCH + float(SAND_INSET))
	var y: int = int(SAND_Y0 + float(r) * SAND_PITCH + float(SAND_INSET))
	var s: int = int(SAND_PITCH) - SAND_INSET * 2
	return Rect2i(x, y, s, s)


static func _ground_tile(key: String, rect: Rect2i) -> Image:
	if _tile_cache.has(key):
		return _tile_cache[key]
	var sub: Image = _sheet().get_region(rect)
	sub.resize(CELL_PX, CELL_PX, Image.INTERPOLATE_LANCZOS)
	if sub.get_format() != Image.FORMAT_RGBA8:
		sub.convert(Image.FORMAT_RGBA8)
	_tile_cache[key] = sub
	return sub


static func _floor_tiles() -> Array:
	var out: Array = []
	for cr in FLOOR_CR:
		out.append(_ground_tile("f%d_%d" % [cr[0], cr[1]], _sand_rect(cr[0], cr[1])))
	return out


static func _pebble_tiles() -> Array:
	var out: Array = []
	for cr in PEBBLE_CR:
		out.append(_ground_tile("p%d_%d" % [cr[0], cr[1]], _sand_rect(cr[0], cr[1])))
	return out


static func _water_tile() -> Image:
	return _ground_tile("water", Rect2i(WATER_RECT[0], WATER_RECT[1], WATER_RECT[2], WATER_RECT[3]))


# Deterministic tile pick so the island never reshuffles between visits.
static func _hpick(arr: Array, ci: int, cj: int, salt: int) -> Image:
	var h: int = abs(hash(Vector2i(ci * 73856093 + salt, cj * 19349663 + salt)))
	return arr[h % arr.size()]


# ---------------------------------------------------------------------------
# Prop loading — alpha-key the gutter, keep largest blob, strip white seams.
# ---------------------------------------------------------------------------
const PROP_OVERRIDE_DIR: String = "res://Assets/Tilesets/Beach_props/"

# A hand-cleaned PNG in Beach_props/<name>.png wins over slicing from the sheet,
# so manual touch-ups to a prop take effect without code changes. Returns null
# (quietly) when there's no override file.
static func _prop_override(name: String) -> Image:
	var p: String = PROP_OVERRIDE_DIR + name + ".png"
	if ResourceLoader.exists(p):
		var r: Resource = ResourceLoader.load(p)
		if r is Texture2D:
			var im: Image = (r as Texture2D).get_image()
			im.convert(Image.FORMAT_RGBA8)
			return im
	var abs_path: String = ProjectSettings.globalize_path(p)
	if FileAccess.file_exists(abs_path):
		var img := Image.new()
		if img.load(abs_path) == OK:
			img.convert(Image.FORMAT_RGBA8)
			return img
	return null


static func _prop_tex(name: String) -> ImageTexture:
	if _prop_cache.has(name):
		return _prop_cache[name]
	# Hand-cleaned override (Beach_props/<name>.png) takes priority over slicing.
	var ov: Image = _prop_override(name)
	if ov != null:
		var otex: ImageTexture = ImageTexture.create_from_image(ov)
		_prop_cache[name] = otex
		return otex
	# Rocks/palms (brock_*/bpalm_*) live ONLY as override PNGs — they have no sheet
	# rect. If the override didn't load, bail safely (callers skip a null prop)
	# rather than indexing a missing rect and crashing the whole room build.
	if not PROP_RECTS.has(name) and not PROP2_RECTS.has(name):
		push_warning("[BeachTileset] No art for prop '%s' (override missing)." % name)
		return null
	# Sheet 2 props (cave / rockwall / rubble) vs sheet 1 (palms / rocks / decor).
	var on_s2: bool = PROP2_RECTS.has(name)
	var r: Array = PROP2_RECTS[name] if on_s2 else PROP_RECTS[name]
	var sheet: Image = _sheet2() if on_s2 else _sheet()
	var src: Image = sheet.get_region(Rect2i(r[0], r[1], r[2], r[3]))
	if src.get_format() != Image.FORMAT_RGBA8:
		src.convert(Image.FORMAT_RGBA8)
	# Trees + flat decor have white separator slivers to strip; trees also carry
	# a baked cast shadow we replace with a clean runtime ellipse. Rocky pieces
	# are grey (their highlights look white-ish) so they skip the white strip.
	var is_palm: bool = name.begins_with("palm")
	var is_cave: bool = name == "cave"
	var is_rocky: bool = name.begins_with("rock") or name == "rubble" or is_cave
	var keyed: Image = _key_prop(src, not is_rocky, is_palm, is_cave)
	var tex: ImageTexture = ImageTexture.create_from_image(keyed)
	_prop_cache[name] = tex
	return tex


# Alpha-key a prop crop: drop the gutter colour everywhere (including pockets
# enclosed by foliage), optionally strip near-white separator lines and the
# baked cool cast shadow, then keep the largest blob and trim.
static func _key_prop(src: Image, strip_white: bool, strip_shadow: bool, strip_mouth: bool = false) -> Image:
	var w: int = src.get_width()
	var h: int = src.get_height()
	var removed: PackedByteArray = PackedByteArray()
	removed.resize(w * h)
	var shadow_y: int = int(0.56 * float(h))
	for y in range(h):
		for x in range(w):
			var c: Color = src.get_pixel(x, y)
			var rr: float = c.r * 255.0
			var gg: float = c.g * 255.0
			var bb: float = c.b * 255.0
			var mx: float = maxf(rr, maxf(gg, bb))
			var mn: float = minf(rr, minf(gg, bb))
			var rm: bool = false
			if absf(rr - 79.0) + absf(gg - 82.0) + absf(bb - 88.0) < 55.0:
				rm = true                                    # gutter background
			elif strip_white and mn > 188.0 and (mx - mn) < 24.0:
				rm = true                                    # near-white separator line
			elif strip_shadow and y > shadow_y and mx < 112.0 and bb + 4.0 >= rr and gg <= maxf(rr, bb) + 3.0:
				rm = true                                    # cool/dark baked cast shadow
			if rm:
				removed[y * w + x] = 1
	# Keep only the largest surviving blob (drops stray label glyphs / specks).
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
	# 3. Cave → stone ARCH. Clear the big ENCLOSED dark interior so the path
	#    shows through, but never touch dark pixels on the silhouette edge
	#    (adjacent to the exterior) — that keeps the rock outline solid and
	#    avoids eating the stone (no "sand-behind-the-rock" holes).
	var mouth: PackedByteArray = PackedByteArray()
	mouth.resize(w * h)
	if strip_mouth:
		# Mark stone pixels that touch the exterior (8-neighbour outside the blob).
		var edge_adj: PackedByteArray = PackedByteArray()
		edge_adj.resize(w * h)
		for y in range(h):
			for x in range(w):
				if label[y * w + x] == best_id:
					continue                              # only flag exterior cells' neighbours
				for eo in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
						Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]:
					var ex: int = x + eo.x
					var ey: int = y + eo.y
					if ex >= 0 and ey >= 0 and ex < w and ey < h:
						edge_adj[ey * w + ex] = 1
		var dlabel: PackedInt32Array = PackedInt32Array()
		dlabel.resize(w * h)
		var d_best: int = 0
		var d_n: int = 0
		var d_cur: int = 0
		for y in range(h):
			for x in range(w):
				var di: int = y * w + x
				if label[di] != best_id or dlabel[di] != 0 or edge_adj[di] == 1:
					continue
				var dc: Color = src.get_pixel(x, y)
				if maxf(dc.r, maxf(dc.g, dc.b)) >= 0.306:    # dark interior only
					continue
				d_cur += 1
				var dn: int = 0
				var ds: Array = [Vector2i(x, y)]
				dlabel[di] = d_cur
				while not ds.is_empty():
					var dq: Vector2i = ds.pop_back()
					dn += 1
					for doff in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
						var dx2: int = dq.x + doff.x
						var dy2: int = dq.y + doff.y
						if dx2 < 0 or dy2 < 0 or dx2 >= w or dy2 >= h:
							continue
						var d2: int = dy2 * w + dx2
						if label[d2] != best_id or dlabel[d2] != 0 or edge_adj[d2] == 1:
							continue
						var c2: Color = src.get_pixel(dx2, dy2)
						if maxf(c2.r, maxf(c2.g, c2.b)) >= 0.306:
							continue
						dlabel[d2] = d_cur
						ds.append(Vector2i(dx2, dy2))
				if dn > d_n:
					d_n = dn
					d_best = d_cur
		if d_best > 0:
			for i3 in range(w * h):
				if dlabel[i3] == d_best:
					mouth[i3] = 1
	# 4. Write alpha: transparent unless part of the kept blob (and not the mouth).
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in range(h):
		for x in range(w):
			var col: Color = src.get_pixel(x, y)
			var idx: int = y * w + x
			if label[idx] != best_id or mouth[idx] == 1:
				col.a = 0.0
			out.set_pixel(x, y, col)
	return out


# ---------------------------------------------------------------------------
# GROUND — baked sand/water image with foam + flat decor.
# ---------------------------------------------------------------------------
static func make_ground(half: Vector2, layout: RefCounted, seed_val: int,
		exit_dir: Vector2 = Vector2.ZERO) -> Sprite2D:
	var gw: int = layout.gw
	var gh: int = layout.gh
	var m: int = APRON_CELLS
	var off: int = m * CELL_PX
	var img := Image.create((gw + 2 * m) * CELL_PX, (gh + 2 * m) * CELL_PX, false, Image.FORMAT_RGBA8)
	var floor_t: Array = _floor_tiles()
	var pebble_t: Array = _pebble_tiles()
	var dark_t: Array = _dark_tiles()
	var water_t: Image = _water_tile()
	var src_rect := Rect2i(0, 0, CELL_PX, CELL_PX)

	# Star-arm shore: the darker-sand apron only continues the land FORE/AFT
	# (along the travel axis); the two flanks are left transparent so the
	# animated ocean shader's sea shows through — matching the island shape.
	var has_axis: bool = exit_dir != Vector2.ZERO
	var axis: Vector2 = exit_dir.normalized() if has_axis else Vector2.ZERO
	var perp: Vector2 = Vector2(-axis.y, axis.x)
	var strip_half: float = absf(perp.x) * half.x + absf(perp.y) * half.y

	for cj in range(-m, gh + m):
		for ci in range(-m, gw + m):
			var dst := Vector2i((ci + m) * CELL_PX, (cj + m) * CELL_PX)
			var inside: bool = ci >= 0 and ci < gw and cj >= 0 and cj < gh
			var tile: Image
			if inside:
				var v: int = layout.val(ci, cj)
				if v == 2:                               # V_WATER
					tile = water_t
				else:                                    # FLOOR / VOID / BRIDGE → sand
					var h: int = abs(hash(Vector2i(ci, cj)))
					tile = (_hpick(pebble_t, ci, cj, 5) if h % 6 == 0 else _hpick(floor_t, ci, cj, 1))
			else:
				# Apron cell: land (darker sand) only within the travel strip.
				if has_axis:
					var c := Vector2((float(ci) + 0.5) * WORLD_CELL - half.x,
						(float(cj) + 0.5) * WORLD_CELL - half.y)
					if absf(c.dot(perp)) > strip_half + WORLD_CELL:
						continue                          # flank → leave transparent (sea)
				tile = _hpick(dark_t, ci, cj, 9)
			img.blit_rect(tile, src_rect, dst)

	_bake_foam(img, layout, gw, gh, off)
	_bake_decor(img, layout, gw, gh, seed_val, off)

	var off_world: float = float(m) * WORLD_CELL
	var spr := Sprite2D.new()
	spr.name = "TerrainGround"
	spr.centered = false
	spr.position = Vector2(-half.x - off_world, -half.y - off_world)
	spr.scale = Vector2(WORLD_CELL / float(CELL_PX), WORLD_CELL / float(CELL_PX))
	spr.z_index = GROUND_Z
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR     # HD art — linear downscale
	spr.texture = ImageTexture.create_from_image(img)
	return spr


static func _dark_tiles() -> Array:
	if _tile_cache.has("__dark0"):
		var out0: Array = []
		for i in range(FLOOR_CR.size()):
			out0.append(_tile_cache["__dark%d" % i])
		return out0
	var out: Array = []
	var i2: int = 0
	for t in _floor_tiles():
		var d: Image = _darken_tile(t)
		_tile_cache["__dark%d" % i2] = d
		out.append(d)
		i2 += 1
	return out


static func _darken_tile(src: Image) -> Image:
	var w: int = src.get_width()
	var h: int = src.get_height()
	var d := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in range(h):
		for x in range(w):
			var c: Color = src.get_pixel(x, y)
			# Slightly cooler + darker so the outer shore reads as distinct.
			c.r *= 0.78
			c.g *= 0.80
			c.b *= 0.86
			d.set_pixel(x, y, c)
	return d


static func _is_water(layout: RefCounted, ci: int, cj: int) -> bool:
	return layout.val(ci, cj) == 2


static func _bake_foam(img: Image, layout: RefCounted, gw: int, gh: int, off: int) -> void:
	for cj in range(gh):
		for ci in range(gw):
			if not _is_water(layout, ci, cj):
				continue
			var n: bool = _is_water(layout, ci, cj - 1)
			var s: bool = _is_water(layout, ci, cj + 1)
			var w: bool = _is_water(layout, ci - 1, cj)
			var e: bool = _is_water(layout, ci + 1, cj)
			if n and s and w and e:
				continue                                  # interior water — skip
			var x0: int = off + ci * CELL_PX
			var y0: int = off + cj * CELL_PX
			for py in range(CELL_PX):
				for px in range(CELL_PX):
					var d: int = 9999
					if not n:
						d = min(d, py)
					if not s:
						d = min(d, CELL_PX - 1 - py)
					if not w:
						d = min(d, px)
					if not e:
						d = min(d, CELL_PX - 1 - px)
					if d < FOAM_PX:
						var t: float = (1.0 - float(d) / float(FOAM_PX)) * 0.85
						var c: Color = img.get_pixel(x0 + px, y0 + py)
						img.set_pixel(x0 + px, y0 + py, c.lerp(C_FOAM, t))


# Weighted [name, height_cells] list expanded from DECOR_TABLE (built once).
static func _decor_weighted() -> Array:
	var out: Array = []
	for e in DECOR_TABLE:
		for _w in range(int(e[2])):
			out.append([e[0], float(e[1])])
	return out


static func _bake_decor(img: Image, layout: RefCounted, gw: int, gh: int, seed_val: int, off: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 2654435761 + 17
	var pool: Array = _decor_weighted()
	var count: int = int(float(gw * gh) / 22.0)   # sparse flat decor — light clutter
	for _i in range(count):
		var ci: int = rng.randi_range(1, gw - 2)
		var cj: int = rng.randi_range(1, gh - 2)
		if layout.val(ci, cj) != 1:                       # open floor only
			continue
		var pick: Array = pool[rng.randi() % pool.size()]
		var name: String = pick[0]
		var tex: ImageTexture = _prop_tex(name)
		if tex == null:
			continue                                      # missing override → skip safely
		var rs: Image = tex.get_image()        # fresh copy each call — safe to mutate
		var target_h: int = int(CELL_PX * float(pick[1]))
		var sc: float = float(target_h) / float(rs.get_height())
		var dw: int = max(1, int(rs.get_width() * sc))
		var dh: int = max(1, int(rs.get_height() * sc))
		rs.resize(dw, dh, Image.INTERPOLATE_LANCZOS)
		var wx: int = off + ci * CELL_PX + CELL_PX / 2 + rng.randi_range(-12, 12) - dw / 2
		var wy: int = off + cj * CELL_PX + CELL_PX / 2 + int(CELL_PX * 0.2) - dh
		img.blend_rect(rs, Rect2i(0, 0, dw, dh), Vector2i(wx, wy))


# ---------------------------------------------------------------------------
# PROPS — rock barriers on blocked cells + palm accents + an outside shore
# ring of rocks. Returned as one Node2D the caller adds under the room.
# ---------------------------------------------------------------------------
static func make_props(half: Vector2, layout: RefCounted, seed_val: int,
		gate_positions: Array = []) -> Node2D:
	var root := Node2D.new()
	root.name = "BeachProps"
	root.z_index = PROP_Z
	root.y_sort_enabled = true
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 40503 + 91
	var gw: int = layout.gw
	var gh: int = layout.gh

	# Overlap-free placement (Run 81): every prop records a foot-circle in `placed`
	# and later props must clear ALL earlier ones — so no two items overlap. Interior
	# props also stay clear of doorways (GATE_CLEAR) and the Cliff Faces frame
	# (CLIFF_KEEPOUT inside the arena edge). The outside shore ring sits beyond the
	# wall's outer face. Result: rocks fence the player paths, a few sit naturally
	# about the open void, palms accent sparsely, and a shore ring frames the coast.
	var placed: Array = []                        # [{ "c": Vector2, "r": float }, ...]
	var lim_x: float = half.x - CLIFF_KEEPOUT
	var lim_y: float = half.y - CLIFF_KEEPOUT

	# 0. Floor BARRIERS first (so the rock fences below avoid them): logs sparingly,
	#    anchor + boat very sparingly. Each carries its own dashable_barrier collider.
	_place_barriers(root, placed, layout, gate_positions, rng, gw, gh, lim_x, lim_y)

	# Path-edge cells = blocked cells that touch the walkable floor, kept inside the
	# cliff frame. Visited in a deterministic shuffled order so the fences read as
	# natural lines rather than a raster sweep (identical every visit via the seed).
	var edge_cells: Array = []
	for cj in range(gh):
		for ci in range(gw):
			if layout.val(ci, cj) != 0 or not _touches_floor(layout, ci, cj):
				continue
			var wc: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
			if absf(wc.x) > lim_x or absf(wc.y) > lim_y:
				continue                          # under the cliff border frame
			edge_cells.append(wc)
	_shuffle(edge_cells, rng)

	# 1. Rock FENCES lining the player paths — varied rocks, close together, with
	#    occasional natural breaks. Overlap test keeps them abutting, never stacked.
	for wc in edge_cells:
		if _near_any(wc, gate_positions, GATE_CLEAR):
			continue
		if rng.randf() > 0.96:                         # near-full rock fence (no slab fill now)
			continue
		_try_rock(root, placed, ROCK_NAMES[rng.randi() % ROCK_NAMES.size()],
			wc, rng.randf_range(1.0, 1.4), rng)

	# 2. A few rocks "placed about" the open interior void (not on a path edge).
	for cj in range(gh):
		for ci in range(gw):
			if layout.val(ci, cj) != 0 or _touches_floor(layout, ci, cj):
				continue
			if rng.randf() > 0.05:
				continue
			var wc2: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
			if absf(wc2.x) > lim_x or absf(wc2.y) > lim_y:
				continue
			if _near_any(wc2, gate_positions, GATE_CLEAR):
				continue
			_try_rock(root, placed, ROCK_NAMES[rng.randi() % ROCK_NAMES.size()],
				wc2, rng.randf_range(0.9, 1.25), rng)

	# 3. Sparse palm accents along the path edges (need clear ground around them).
	for wc3 in edge_cells:
		if rng.randf() > 0.07:
			continue
		if _near_any(wc3, gate_positions, GATE_CLEAR):
			continue
		_try_palm(root, placed, PALM_NAMES[rng.randi() % PALM_NAMES.size()],
			wc3, rng.randf_range(2.1, 2.6), rng)

	# 3.5 COVERAGE PASS (Run 89) — GUARANTEE every collidable barrier cell that
	#     borders walkable floor wears a visible rock. Collision is generated for
	#     EVERY V_VOID cell (DreamLayout.void_runs → full-cell rects), but the
	#     fences above can leave a cell bare (overlap reject / random break / gate
	#     keep-out), which reads as an empty sandy GAP you still can't walk through.
	#     Here we sweep those edge cells and FORCE a rock onto any one not already
	#     covered by a placed prop — so an empty-looking gap is always passable and
	#     anything unpassable is always clearly walled by art. (Cells under the
	#     cliff border frame are skipped — that band is covered by the frame art.)
	for cj in range(gh):
		for ci in range(gw):
			if layout.val(ci, cj) != 0 or not _touches_floor(layout, ci, cj):
				continue
			var wcc: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
			if absf(wcc.x) > lim_x or absf(wcc.y) > lim_y:
				continue                          # under the cliff border frame
			var covered: bool = false
			for p in placed:
				# p["r"] is the foot radius; the art extends ~half a draw-width past
				# it, so add slack to count a cell already hidden under nearby rock.
				if wcc.distance_to(p["c"]) <= float(p["r"]) + 10.0:
					covered = true
					break
			if covered:
				continue
			_fit_rock(root, placed, ROCK_NAMES[rng.randi() % ROCK_NAMES.size()], wcc, rng)

	# 4. Outside shore ring — rocks + a few palms beyond the cliff wall so the
	#    surround reads as a water / rock / sand coast. Still overlap-checked.
	var ring: float = 112.0
	var ring_rocks: int = int((half.x + half.y) / 46.0)
	for _i in range(ring_rocks):
		var pos: Vector2 = _ring_point(half, SHORE_BAND_MIN, SHORE_BAND_MIN + ring, rng)
		if _near_any(pos, gate_positions, GATE_CLEAR):
			continue                              # keep the gate exit lanes clear
		_try_rock(root, placed, ROCK_NAMES[rng.randi() % ROCK_NAMES.size()],
			pos, rng.randf_range(0.8, 1.35), rng)
	for _j in range(max(2, ring_rocks / 5)):
		var pos2: Vector2 = _ring_point(half, SHORE_BAND_MIN, SHORE_BAND_MIN + ring, rng)
		if _near_any(pos2, gate_positions, GATE_CLEAR):
			continue
		_try_palm(root, placed, PALM_NAMES[rng.randi() % PALM_NAMES.size()],
			pos2, rng.randf_range(2.0, 2.6), rng)
	return root


# Run 88 — scatter LOG / ANCHOR / BOAT barriers on open floor. Logs come in a
# small handful; anchor + boat appear only occasionally (very sparingly). Each
# placed barrier records a foot-circle in `placed` so rocks/palms avoid it.
static func _place_barriers(root: Node2D, placed: Array, layout: RefCounted,
		gate_positions: Array, rng: RandomNumberGenerator, gw: int, gh: int,
		lim_x: float, lim_y: float) -> void:
	# Open interior floor cells, clear of gates, the border frame, and the central
	# spawn chamber (origin). Shuffled so picks read as natural scatter.
	var cands: Array = []
	for cj in range(gh):
		for ci in range(gw):
			if layout.val(ci, cj) != 1:
				continue
			var wc: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
			if absf(wc.x) > lim_x - 24.0 or absf(wc.y) > lim_y - 24.0:
				continue
			if wc.length() < 132.0:                       # keep the spawn chamber clear
				continue
			if _near_any(wc, gate_positions, GATE_CLEAR + 40.0):
				continue
			cands.append(wc)
	if cands.is_empty():
		return
	_shuffle(cands, rng)
	var idx: int = 0
	# Logs — sparingly: a few low, wide barriers (varied pieces, random heights).
	var n_logs: int = rng.randi_range(1, 3)
	var done_logs: int = 0
	while idx < cands.size() and done_logs < n_logs:
		var lname: String = LOG_NAMES[rng.randi() % LOG_NAMES.size()]
		if _try_barrier(root, placed, lname, cands[idx], rng.randf_range(1.3, 1.7), rng, 0.80, 0.60):
			done_logs += 1
		idx += 1
	# Anchor — very sparingly (≈1 in 5 rooms, max one).
	if rng.randf() < 0.22:
		while idx < cands.size():
			if _try_barrier(root, placed, ANCHOR_NAME, cands[idx], rng.randf_range(1.9, 2.3), rng, 0.50, 0.70):
				idx += 1
				break
			idx += 1
	# Boat — very sparingly (≈1 in 6 rooms, max one).
	if rng.randf() < 0.16:
		while idx < cands.size():
			if _try_barrier(root, placed, BOAT_NAME, cands[idx], rng.randf_range(2.3, 2.7), rng, 0.86, 0.55):
				idx += 1
				break
			idx += 1


# Place one barrier prop: draw the sprite (seated, no jitter) and attach a
# dashable_barrier StaticBody2D rectangle over its visible mass. Returns false
# (placing nothing) if its foot-circle would overlap an already-placed prop.
static func _try_barrier(root: Node2D, placed: Array, name: String, base: Vector2,
		height_cells: float, rng: RandomNumberGenerator, foot_w_frac: float,
		foot_h_frac: float) -> bool:
	var tex: ImageTexture = _prop_tex(name)
	if tex == null:
		return false
	var draw_h: float = WORLD_CELL * height_cells
	var draw_w: float = float(tex.get_width()) * (draw_h / float(tex.get_height()))
	# Run 96: wider keep-apart so a long log/boat never lies across an adjacent prop.
	var r: float = draw_w * 0.55
	for p in placed:
		if base.distance_to(p["c"]) < r + p["r"]:
			return false                              # would overlap an existing prop
	# Draw flush (sink 0.08) with no jitter so the collider lines up with the art.
	var sink: int = int(WORLD_CELL * 0.08)
	_add_prop_tex(root, tex, base, height_cells, rng, sink, true, false, false, true)
	# Collider rectangle, centered on the sprite's visible mass (feet → up half a
	# draw_h), sized to a fraction of the art so feathered edges stay passable.
	var feet_y: float = base.y + float(sink)
	var center_y: float = feet_y - draw_h * 0.5
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.add_to_group("dashable_barrier")
	var cs := CollisionShape2D.new()
	var sh := RectangleShape2D.new()
	sh.size = Vector2(maxf(8.0, draw_w * foot_w_frac), maxf(8.0, draw_h * foot_h_frac))
	cs.shape = sh
	cs.position = Vector2(base.x, center_y)
	body.add_child(cs)
	root.add_child(body)
	placed.append({ "c": base, "r": r })
	return true


# Deterministic in-place Fisher–Yates shuffle (seeded rng → stable per room).
static func _shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


# Try to place a rock / palm at `base`. Returns false (placing nothing) if its
# foot-circle would overlap any prop already in `placed`. Rocks use a wide foot so
# fences abut without stacking; palms use a narrow trunk foot so they stand clear
# while canopies may still feather naturally over a neighbour.
static func _try_rock(root: Node2D, placed: Array, name: String, base: Vector2,
		height_cells: float, rng: RandomNumberGenerator, force: bool = false) -> bool:
	# Rocks are barriers → overhead=true so the hero passes BEHIND them on contact.
	# Run 96: wider foot (0.33→0.40) so fences sit close but never cover each other.
	return _try_prop(root, placed, name, base, height_cells, rng, 0.40, false, force, true)


static func _try_palm(root: Node2D, placed: Array, name: String, base: Vector2,
		height_cells: float, rng: RandomNumberGenerator) -> bool:
	# Palms keep PROP_Z (overhead defaults false) — heroes walk in front of the trunk.
	# Run 96: slightly wider trunk foot (0.24→0.30) so palms don't overlap neighbours.
	return _try_prop(root, placed, name, base, height_cells, rng, 0.30, true)


# `force` skips the overlap test — used by the coverage pass so a barrier cell
# ALWAYS gets a visible rock even if a neighbour's foot-circle would reject it.
static func _try_prop(root: Node2D, placed: Array, name: String, base: Vector2,
		height_cells: float, rng: RandomNumberGenerator, foot_frac: float,
		is_palm: bool, force: bool = false, overhead: bool = false) -> bool:
	var tex: ImageTexture = _prop_tex(name)
	if tex == null:
		return false
	var draw_w: float = float(tex.get_width()) * (WORLD_CELL * height_cells / float(tex.get_height()))
	var r: float = draw_w * foot_frac
	if not force:
		for p in placed:
			if base.distance_to(p["c"]) < r + p["r"]:
				return false                      # would overlap an existing prop
	# Rocks: the pixel art already bakes its OWN ground shadow, so we DON'T add
	# the runtime ellipse (the double shadow made rocks look lifted/floating) and
	# we seat them nearly flush on the cell. Palms keep the runtime ellipse — their
	# baked shadow is stripped during keying.
	var sink: int = int(WORLD_CELL * (0.30 if is_palm else 0.08))
	# Jitter disabled so the recorded foot-circle matches the drawn position exactly.
	# Palms split their canopy above rocks (palm_split); rocks draw as one sprite.
	_add_prop_tex(root, tex, base, height_cells, rng, sink, is_palm, false, false, overhead, is_palm)
	placed.append({ "c": base, "r": r })
	return true


# Coverage-pass placement (Run 89): drop a rock on a bare collidable cell, SIZED
# so its foot-circle just abuts the nearest neighbour rather than stacking on it.
# It always places SOMETHING (an unpassable cell must show art) — when the gap is
# tight it shrinks to a small rock, which reads as a natural close-packed pile and
# leaves at most a tiny visually-clear seam (far better than an open-looking gap
# that hits an invisible wall). foot_frac matches _try_rock (0.33).
static func _fit_rock(root: Node2D, placed: Array, name: String, base: Vector2,
		rng: RandomNumberGenerator) -> bool:
	var tex: ImageTexture = _prop_tex(name)
	if tex == null:
		return false
	var foot_frac: float = 0.33
	var pref_r: float = foot_frac * WORLD_CELL * 1.2     # natural full-size foot radius
	# Free radius here before we'd bite into a neighbour's foot-circle.
	var gap: float = pref_r
	for p in placed:
		gap = minf(gap, base.distance_to(p["c"]) - float(p["r"]))
	var want_r: float = clampf(gap, foot_frac * WORLD_CELL * 0.5, pref_r)   # floor ≈ small rock
	# height_cells that yields foot radius == want_r for this sprite's aspect.
	var aspect: float = float(tex.get_width()) / float(tex.get_height())
	var h: float = want_r / (foot_frac * WORLD_CELL * maxf(0.4, aspect))
	h = clampf(h, 0.45, 1.3)
	# Coverage-pass rocks sit on collidable barrier cells → overhead=true.
	return _try_prop(root, placed, name, base, h, rng, foot_frac, false, true, true)


# ---------------------------------------------------------------------------
# WALLS — ring the arena border. Run 80 prefers the hand-authored Cliff Faces
# frame (a clean 9-slice wall); if that sheet is missing it falls back to the
# Run 76 rock-cluster border. Collision stays on DreamRoom's hidden wall/gate
# bodies either way — this is pure decoration.
# ---------------------------------------------------------------------------
static func make_walls(half: Vector2, exit_dir: Vector2, gate_positions: Array,
		seed_val: int) -> Node2D:
	if _cliff_sheet() != null:
		return _make_cliff_walls(half, exit_dir, gate_positions, seed_val)
	return _make_rock_walls(half, exit_dir, gate_positions, seed_val)


# ---------------------------------------------------------------------------
# CLIFF FRAME — lay the Cliff Faces tiles as a continuous border: a corner at
# each arena corner, edge tiles tiled evenly between them, and a clean opening
# left at every gate. Every tile is drawn as a CLIFF_TILE square so the ring is
# a uniform thickness with no seams; the inner face hugs the floor edge.
# ---------------------------------------------------------------------------
static func _make_cliff_walls(half: Vector2, exit_dir: Vector2, gate_positions: Array,
		seed_val: int) -> Node2D:
	var root := Node2D.new()
	root.name = "BeachWalls"
	root.z_index = PROP_Z
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 2246822519 + 53
	var t: float = CLIFF_TILE
	var ov: float = 12.0                         # overlap so inner face hugs the floor
	var cx: float = half.x - ov + t * 0.5        # corner-center offset from arena center
	var cy: float = half.y - ov + t * 0.5
	var gate_clear: float = t * 0.62             # leave a tidy opening at each gate

	# Decide cave-mouth exits UP FRONT so the bottom wall can leave a clean gap
	# sized + centered to each cave. Caves only sit on SOUTH (bottom) gates, and
	# only sometimes; the arena keeps a plain gap at the other gates.
	var cave_tex: ImageTexture = _prop_tex("cave")
	var cave_h: float = t * CAVE_HEIGHT_TILES
	var cave_w: float = 0.0
	if cave_tex != null:
		cave_w = cave_h * float(cave_tex.get_width()) / float(cave_tex.get_height())
	var cave_xs: Array = []                      # gate x-positions that get a cave
	for gp in gate_positions:
		var gpv: Vector2 = gp
		var is_south: bool = gpv.y > 0.0 and absf(gpv.y) > half.y and absf(gpv.x) <= half.x
		if is_south and cave_tex != null and rng.randf() < CAVE_CHANCE:
			cave_xs.append(gpv.x)

	# Four corners (square).
	_add_cliff(root, _cliff_tex("corner_tl", CLIFF_CORNERS["corner_tl"]), Vector2(-cx, -cy), t, t)
	_add_cliff(root, _cliff_tex("corner_tr", CLIFF_CORNERS["corner_tr"]), Vector2( cx, -cy), t, t)
	# South corners overhead too (they sit on the southern border).
	_add_cliff(root, _cliff_tex("corner_bl", CLIFF_CORNERS["corner_bl"]), Vector2(-cx,  cy), t, t, true)
	_add_cliff(root, _cliff_tex("corner_br", CLIFF_CORNERS["corner_br"]), Vector2( cx,  cy), t, t, true)

	# Wall runs span BETWEEN the corner inner edges. Each gate punches an OPENING
	# (centered on the gate); the wall is then tiled as exact-fit segments between
	# those openings, so it butts precisely against each opening on BOTH sides —
	# no lopsided sand gap. Cave openings are sized to the cave so its legs tuck
	# over the wall ends and nothing shows through the arch.
	var run_x0: float = -cx + t * 0.5
	var run_x1: float =  cx - t * 0.5
	var run_y0: float = -cy + t * 0.5
	var run_y1: float =  cy - t * 0.5
	var cave_open: float = maxf(gate_clear, cave_w * CAVE_OPEN_FRAC)

	var top_open: Array = []
	var bot_open: Array = []
	var left_open: Array = []
	var right_open: Array = []
	for gp2 in gate_positions:
		var g: Vector2 = gp2
		if absf(g.x) > half.x:                              # side wall (east/west)
			if g.x < 0.0:
				left_open.append([g.y, gate_clear])
			else:
				right_open.append([g.y, gate_clear])
		elif g.y < 0.0:                                     # top wall
			top_open.append([g.x, gate_clear])
		else:                                               # bottom wall
			var oh: float = cave_open if cave_xs.has(g.x) else gate_clear
			bot_open.append([g.x, oh])

	_tile_wall_axis(root, run_x0, run_x1, -cy, t, true, CLIFF_TOP, "top", top_open, rng)
	# Bottom (south) wall is overhead → lightly covers a hero hugging the south border.
	_tile_wall_axis(root, run_x0, run_x1,  cy, t, true, CLIFF_BOTTOM, "bot", bot_open, rng, true)
	_tile_wall_axis(root, run_y0, run_y1, -cx, t, false, CLIFF_LEFT, "lft", left_open, rng)
	_tile_wall_axis(root, run_y0, run_y1,  cx, t, false, CLIFF_RIGHT, "rgt", right_open, rng)

	# Exit totems: a flanking PAIR stands on the wall beside every gate opening.
	#   • south/north gate (horizontal wall) → totem_s on the W and E sides
	#   • east/west gate (vertical wall)      → totem_e on the N and S sides
	# A south gate that became a cave arch (cave_xs) is skipped — the arch is its
	# marker instead. Drawn after the wall tiles so they read as standing on top.
	var totem_s_tex: ImageTexture = _optional_tex("totem_s")
	var totem_e_tex: ImageTexture = _optional_tex("totem_e")
	for gpt in gate_positions:
		var gt: Vector2 = gpt
		if absf(gt.x) > half.x:                              # vertical wall (E / W)
			if totem_e_tex == null:
				continue
			var wxx: float = cx if gt.x > 0.0 else -cx
			_add_prop_tex(root, totem_e_tex, Vector2(wxx, gt.y - TOTEM_GATE_GAP),
				TOTEM_H_CELLS, rng, 0, false, false, false, true)
			_add_prop_tex(root, totem_e_tex, Vector2(wxx, gt.y + TOTEM_GATE_GAP + TOTEM_GATE_GAP_S),
				TOTEM_H_CELLS, rng, 0, false, false, false, true)
		else:                                               # horizontal wall (S / N)
			if gt.y > 0.0 and cave_xs.has(gt.x):
				continue                                     # cave arch replaces totems here
			if totem_s_tex == null:
				continue
			var wyy: float = cy if gt.y > 0.0 else -cy
			_add_prop_tex(root, totem_s_tex, Vector2(gt.x - TOTEM_GATE_GAP, wyy),
				TOTEM_H_CELLS, rng, 0, false, false, false, true)
			_add_prop_tex(root, totem_s_tex, Vector2(gt.x + TOTEM_GATE_GAP, wyy),
				TOTEM_H_CELLS, rng, 0, false, false, false, true)

	# Cave mouths drawn LAST so they sit over the wall ends, centered on the gate.
	for cxx in cave_xs:
		var spr := Sprite2D.new()
		spr.texture = cave_tex
		spr.centered = true
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		spr.scale = Vector2(cave_w / float(cave_tex.get_width()), cave_h / float(cave_tex.get_height()))
		# Shift left a touch so the arch HOLE (right-of-center in the art) lands on
		# the gate, not just the bounding box.
		spr.position = Vector2(cxx - cave_w * CAVE_OPEN_OFFSET_FRAC, cy + t * CAVE_RISE_TILES)
		# Draw the ENTIRE arch above the hero/enemy bodies (z 0) so anyone running
		# into the exit passes UNDER it. The doorway HOLE is transparent in the art,
		# so heroes still show THROUGH the opening; the surrounding stone occludes
		# them. Brief "buried under the rock" while entering the exit is acceptable.
		spr.z_as_relative = false
		spr.z_index = RunState.BARRIER_OVERHANG_Z
		root.add_child(spr)

		# Overhead lintel: redraw the TOP band of the same art ABOVE the heroes so a
		# ninja in the doorway is occluded by the arch (walks UNDER it). The base
		# above already draws behind everything at PROP_Z.
		var ctw: float = float(cave_tex.get_width())
		var cth: float = float(cave_tex.get_height())
		var band_px: float = cth * CAVE_OVERHANG_FRAC
		var lintel := Sprite2D.new()
		lintel.texture = cave_tex
		lintel.centered = true
		lintel.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		lintel.region_enabled = true
		lintel.region_rect = Rect2(0.0, 0.0, ctw, band_px)
		lintel.scale = spr.scale
		# A region Sprite2D centers on its REGION; align this band's top with the
		# base cave's top edge so it overlays pixel-for-pixel.
		lintel.position = Vector2(spr.position.x,
			spr.position.y - cave_h * 0.5 + band_px * spr.scale.y * 0.5)
		lintel.z_as_relative = false                 # ignore the root's PROP_Z; use absolute z
		lintel.z_index = RunState.BARRIER_OVERHANG_Z
		root.add_child(lintel)
	return root


# Tile one wall run from `a0`..`a1` (along x if `horizontal`, else y) at the
# fixed cross-coord `fixed`, leaving the given OPENINGS ([center, half_width])
# clear. Each solid segment between openings is filled with exact-fit tiles that
# butt its ends precisely. Tile thickness across the wall is `t`.
static func _tile_wall_axis(root: Node2D, a0: float, a1: float, fixed: float, t: float,
		horizontal: bool, variants: Array, prefix: String, openings: Array,
		rng: RandomNumberGenerator, overhead: bool = false) -> void:
	var cuts: Array = []
	for o in openings:
		cuts.append([o[0] - o[1], o[0] + o[1]])
	cuts.sort_custom(func(p, q): return p[0] < q[0])
	var seg_start: float = a0
	for c in cuts:
		var seg_end: float = minf(c[0], a1)
		_fit_run(root, seg_start, seg_end, fixed, t, horizontal, variants, prefix, rng, overhead)
		seg_start = maxf(seg_start, c[1])
	_fit_run(root, seg_start, a1, fixed, t, horizontal, variants, prefix, rng, overhead)


# Fill [a, b] along the run axis with N equal tiles that exactly butt the ends.
static func _fit_run(root: Node2D, a: float, b: float, fixed: float, t: float,
		horizontal: bool, variants: Array, prefix: String, rng: RandomNumberGenerator,
		overhead: bool = false) -> void:
	var span: float = b - a
	if span < t * 0.5:
		return                                              # too small for a tile
	var n: int = max(1, int(round(span / t)))
	var tw: float = span / float(n)
	for k in range(n):
		var p: float = a + (float(k) + 0.5) * tw
		var center: Vector2 = Vector2(p, fixed) if horizontal else Vector2(fixed, p)
		var w: float = tw if horizontal else t
		var h: float = t if horizontal else tw
		_add_cliff(root, _cliff_pick(variants, prefix, rng), center, w, h, overhead)


# Slice a cliff tile (transparent-bg sheet → no keying needed) and cache it.
static func _cliff_tex(key: String, rect: Array) -> ImageTexture:
	if _cliff_tex_cache.has(key):
		return _cliff_tex_cache[key]
	var sub: Image = _cliff_sheet().get_region(Rect2i(rect[0], rect[1], rect[2], rect[3]))
	if sub.get_format() != Image.FORMAT_RGBA8:
		sub.convert(Image.FORMAT_RGBA8)
	var tex: ImageTexture = ImageTexture.create_from_image(sub)
	_cliff_tex_cache[key] = tex
	return tex


# Pick one of an edge's variants (deterministic per call via rng), cached.
static func _cliff_pick(arr: Array, prefix: String, rng: RandomNumberGenerator) -> ImageTexture:
	var i: int = rng.randi() % arr.size()
	return _cliff_tex("%s%d" % [prefix, i], arr[i])


# Draw a cliff tile centered at `center`, scaled to `w`×`h` world px. A tiny
# seam bleed makes neighbours overlap sub-pixel so no sand hairline shows.
static func _add_cliff(root: Node2D, tex: ImageTexture, center: Vector2, w: float, h: float,
		overhead: bool = false) -> void:
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.centered = true
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	spr.position = center
	spr.scale = Vector2((w + CLIFF_SEAM) / float(tex.get_width()), (h + CLIFF_SEAM) / float(tex.get_height()))
	# South (bottom) cliff wall + corners draw above the hero so a ninja hugging the
	# southern border is lightly covered by the wall lip (we CAN be "behind" the south
	# wall from a top-down view). North/E/W walls stay at PROP_Z. Global rule on RunState.
	if overhead:
		spr.z_as_relative = false
		spr.z_index = RunState.BARRIER_OVERHANG_Z
	root.add_child(spr)


# ---------------------------------------------------------------------------
# Fallback rock-cluster border (Run 76) — used only if the Cliff Faces sheet
# can't load. Drops cave-mouth arches / rock pillars at the gates.
# ---------------------------------------------------------------------------
static func _make_rock_walls(half: Vector2, exit_dir: Vector2, gate_positions: Array,
		seed_val: int) -> Node2D:
	var root := Node2D.new()
	root.name = "BeachWalls"
	root.z_index = PROP_Z
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 2246822519 + 53
	var edge: float = 10.0
	var step: float = 26.0         # dense + overlapping → a CLOSED rock barrier
	var clear: float = 86.0        # tidy opening only at the gates (for the arch)

	# Top + bottom runs (extend past the corners so they're filled). A second
	# slightly inset rock on each step gives the wall thickness and kills gaps.
	var x: float = -half.x - 16.0
	while x <= half.x + 16.0:
		for sy in [-1.0, 1.0]:
			var pos := Vector2(x, sy * (half.y + edge))
			if not _near_any(pos, gate_positions, clear):
				_add_prop_world(root, WALL_NAMES[rng.randi() % WALL_NAMES.size()],
					pos, rng.randf_range(1.05, 1.45), rng, int(WORLD_CELL * 0.15))
				if rng.randf() < 0.6:
					_add_prop_world(root, WALL_NAMES[rng.randi() % WALL_NAMES.size()],
						pos + Vector2(0.0, sy * -16.0), rng.randf_range(0.9, 1.2), rng, int(WORLD_CELL * 0.1))
		x += step
	# Left + right runs.
	var y: float = -half.y - 16.0
	while y <= half.y + 16.0:
		for sx in [-1.0, 1.0]:
			var pos2 := Vector2(sx * (half.x + edge), y)
			if not _near_any(pos2, gate_positions, clear):
				_add_prop_world(root, WALL_NAMES[rng.randi() % WALL_NAMES.size()],
					pos2, rng.randf_range(1.05, 1.45), rng, int(WORLD_CELL * 0.15))
				if rng.randf() < 0.6:
					_add_prop_world(root, WALL_NAMES[rng.randi() % WALL_NAMES.size()],
						pos2 + Vector2(sx * -16.0, 0.0), rng.randf_range(0.9, 1.2), rng, int(WORLD_CELL * 0.1))
		y += step
	# Doorways:
	#   • Side walls (east/west): a clear opening flanked by two TALL ROCK
	#     PILLARS — no arch (rotating the front-drawn arch reads as "lying down";
	#     the boon/exit label already signals the exit).
	#   • Top/bottom walls: an open gap, with an arch OCCASIONALLY for flair.
	var totem: ImageTexture = _optional_tex("totem")    # drop-in flair (Beach_props/totem.png)
	for gp in gate_positions:
		var g: Vector2 = gp
		if absf(g.x) > half.x:                       # side wall (east/west)
			if totem != null and rng.randf() < 0.5:  # occasional totem flair
				_add_prop_tex(root, totem, g + Vector2(0.0, -50.0), 2.4, rng, int(WORLD_CELL * 0.1), true, false, false)
				_add_prop_tex(root, totem, g + Vector2(0.0, 50.0), 2.4, rng, int(WORLD_CELL * 0.1), true, false, false)
			else:                                     # else twin tall rock pillars
				_add_pillar(root, g + Vector2(0.0, -50.0), rng)
				_add_pillar(root, g + Vector2(0.0, 50.0), rng)
		elif rng.randf() < 0.45:                     # bottom/top → sometimes an arch
			_add_prop_tex(root, _cave_tex("up"), g, 3.0, rng, 0, false, false, false)
	return root


# Returns a hand-placed override texture (Beach_props/<name>.png) or null — used
# for optional flair props that have no sheet rect (e.g. a purpose-cut totem).
static func _optional_tex(name: String) -> ImageTexture:
	if _prop_cache.has(name):
		return _prop_cache[name]
	var ov: Image = _prop_override(name)
	if ov == null:
		return null
	var tex: ImageTexture = ImageTexture.create_from_image(ov)
	_prop_cache[name] = tex
	return tex


# A "tall rock pillar" built by stacking rock pieces (feet-anchored, no jitter
# so they stay aligned). Shadow only under the base rock.
static func _add_pillar(root: Node2D, base: Vector2, rng: RandomNumberGenerator) -> void:
	var heights: Array = [1.5, 1.25, 1.0]
	var rises: Array = [0.0, 26.0, 48.0]
	for i in range(heights.size()):
		var tex: ImageTexture = _prop_tex(ROCK_NAMES[rng.randi() % ROCK_NAMES.size()])
		_add_prop_tex(root, tex, base - Vector2(0.0, rises[i]), heights[i], rng,
			int(WORLD_CELL * 0.1), i == 0, false, false)


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


# A point in the shore band [b0, b1] outside the arena rectangle. b0 starts past
# the cliff wall's outer face so shore props never overlap the border frame.
static func _ring_point(half: Vector2, b0: float, b1: float, rng: RandomNumberGenerator) -> Vector2:
	var side: int = rng.randi() % 4
	var band: float = rng.randf_range(b0, b1)
	match side:
		0:  return Vector2(rng.randf_range(-half.x - b1, half.x + b1), -half.y - band)
		1:  return Vector2(rng.randf_range(-half.x - b1, half.x + b1),  half.y + band)
		2:  return Vector2(-half.x - band, rng.randf_range(-half.y - b1, half.y + b1))
		_:  return Vector2( half.x + band, rng.randf_range(-half.y - b1, half.y + b1))


static func _add_prop(root: Node2D, name: String, base: Vector2, height_cells: float,
		rng: RandomNumberGenerator, sink: int) -> void:
	_add_prop_world(root, name, base, height_cells, rng, sink)


# Soft elliptical contact shadow (replaces the sheet's baked square shadows).
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


static func _add_prop_world(root: Node2D, name: String, base: Vector2, height_cells: float,
		rng: RandomNumberGenerator, sink: int, with_shadow: bool = true) -> void:
	_add_prop_tex(root, _prop_tex(name), base, height_cells, rng, sink, with_shadow)


# Rotate a keyed prop image 90° (cw=true → clockwise) for side-wall arches.
static func _rotate90(src: Image, cw: bool) -> Image:
	var w: int = src.get_width()
	var h: int = src.get_height()
	var dst := Image.create(h, w, false, Image.FORMAT_RGBA8)
	for y in range(h):
		for x in range(w):
			var c: Color = src.get_pixel(x, y)
			if cw:
				dst.set_pixel(h - 1 - y, x, c)
			else:
				dst.set_pixel(y, w - 1 - x, c)
	return dst


# Oriented stone-arch texture so the opening faces INTO the arena per wall.
# orient: "up" (top/bottom walls), "left" (east wall), "right" (west wall).
static func _cave_tex(orient: String) -> ImageTexture:
	var key: String = "cave_" + orient
	if _prop_cache.has(key):
		return _prop_cache[key]
	var base: Image = _prop_tex("cave").get_image()
	var img: Image = base
	if orient == "left":
		img = _rotate90(base, true)
	elif orient == "right":
		img = _rotate90(base, false)
	var tex: ImageTexture = ImageTexture.create_from_image(img)
	_prop_cache[key] = tex
	return tex


static func _add_prop_tex(root: Node2D, tex: ImageTexture, base: Vector2, height_cells: float,
		rng: RandomNumberGenerator, sink: int, with_shadow: bool = true,
		anchor_center: bool = false, jitter: bool = true, overhead: bool = false,
		palm_split: bool = false) -> void:
	var th: float = float(tex.get_height())
	var tw: float = float(tex.get_width())
	var target_h: float = WORLD_CELL * height_cells
	var sc: float = target_h / th
	var draw_h: float = th * sc
	var draw_w: float = tw * sc
	var jx: int = rng.randi_range(-10, 10) if (jitter and not anchor_center) else 0
	var feet: Vector2 = base + Vector2(float(jx), float(sink))   # contact point

	# Palms: draw as TWO region sprites so the canopy clears the rocks. The bottom
	# slice (the trunk's very base) keeps PROP_Z and may be occluded by a rock/hero;
	# everything above it is lifted to PALM_CANOPY_Z (absolute) so the fronds and
	# trunk always draw OVER rock barriers, per the design rule.
	if palm_split:
		var top_y: float = feet.y - draw_h
		if with_shadow:
			var psh := Sprite2D.new()
			var pstex: ImageTexture = _shadow_texture()
			psh.texture = pstex
			psh.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
			var psh_w: float = draw_w * 0.62
			var psh_h: float = maxf(6.0, psh_w * 0.42)
			psh.scale = Vector2(psh_w / float(pstex.get_width()), psh_h / float(pstex.get_height()))
			psh.position = feet
			root.add_child(psh)
		var bf: float = PALM_BASE_FRAC
		# Base band — bottom slice of the art, left at PROP_Z (root's z band).
		var base_spr := Sprite2D.new()
		base_spr.texture = tex
		base_spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		base_spr.region_enabled = true
		base_spr.region_rect = Rect2(0.0, th * (1.0 - bf), tw, th * bf)
		base_spr.scale = Vector2(sc, sc)
		base_spr.position = Vector2(feet.x, feet.y - draw_h * bf * 0.5)
		root.add_child(base_spr)
		# Canopy + trunk — everything above the base, lifted over the rocks.
		var can_spr := Sprite2D.new()
		can_spr.texture = tex
		can_spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		can_spr.region_enabled = true
		can_spr.region_rect = Rect2(0.0, 0.0, tw, th * (1.0 - bf))
		can_spr.scale = Vector2(sc, sc)
		can_spr.position = Vector2(feet.x, top_y + draw_h * (1.0 - bf) * 0.5)
		can_spr.z_as_relative = false
		can_spr.z_index = PALM_CANOPY_Z
		root.add_child(can_spr)
		return

	var ysort: bool = overhead and root.y_sort_enabled

	if ysort:
		var wrap := Node2D.new()
		wrap.position = feet
		wrap.z_as_relative = false
		wrap.z_index = 0
		if with_shadow:
			var sh := Sprite2D.new()
			var stex: ImageTexture = _shadow_texture()
			sh.texture = stex
			sh.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
			var sh_w: float = draw_w * 0.62
			var sh_h: float = maxf(6.0, sh_w * 0.42)
			sh.scale = Vector2(sh_w / float(stex.get_width()), sh_h / float(stex.get_height()))
			wrap.add_child(sh)
		var spr := Sprite2D.new()
		spr.texture = tex
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		spr.scale = Vector2(sc, sc)
		spr.position = Vector2(-float(jx), -draw_h * 0.5) if not anchor_center else (base - feet)
		wrap.add_child(spr)
		root.add_child(wrap)
	else:
		if with_shadow:
			var sh := Sprite2D.new()
			var stex: ImageTexture = _shadow_texture()
			sh.texture = stex
			sh.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
			var sh_w: float = draw_w * 0.62
			var sh_h: float = maxf(6.0, sh_w * 0.42)
			sh.scale = Vector2(sh_w / float(stex.get_width()), sh_h / float(stex.get_height()))
			sh.position = feet
			root.add_child(sh)
		var spr := Sprite2D.new()
		spr.texture = tex
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		spr.scale = Vector2(sc, sc)
		spr.position = base if anchor_center else feet - Vector2(0.0, draw_h * 0.5)
		if overhead:
			spr.z_as_relative = false
			spr.z_index = RunState.BARRIER_OVERHANG_Z
		root.add_child(spr)
