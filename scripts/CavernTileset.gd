extends RefCounted

# ============================================================
# CavernTileset.gd — Run 97 (2026-06-21) — Emberglass Caverns real-art pass
# ============================================================
# Dedicated to the CAVERNS biome only. Owns Assets/Tilesets/Cave_props end-to-
# end now (sliced 1:1 from Bruno's three sheets) PLUS the floor + lava tiles from
# the Crystal Lava Caves Tileset. No longer routes through the shared BiomeProps
# engine — every cavern placement decision lives here (Swamp/Beach are the model).
#
# Source art:
#   Cave_props/ctite_1..7   — STALACTITES (hang from the ceiling, tip points DOWN)
#   Cave_props/cmite_1..9   — STALAGMITES (rise from the floor,   tip points UP)
#       Both build the arena-wall "cage": a teeth ring of stalactites along the
#       top, stalagmites along the bottom, and side teeth rotated to point inward.
#   Cave_props/ccrys_1..12  — CAVE CRYSTAL clusters → the random INNER barriers.
#   Cave_props/cerock_1..5  — ember/lava rock spires & piles → extra barriers.
#   Cave_props/cspike_1..2  — small hanging spike clusters → sparse overhead accents.
#   Cave_props/cbloom_1..3, cember_1, clavapit_1, cgems_1, cpick_1..3,
#       cshovel_1..2, ccart_1 — flat run-over DECOR (crystal blooms, coal, gem
#       piles, mining tools, a rare ore cart landmark).
#
# Floor + lava (Crystal Lava Caves Tileset.png, 140px grid):
#   make_ground — baked volcanic-cobble floor (3 plain variants + flips) with a
#       static lava river tile under V_WATER cells, PLUS an outer apron of cave
#       floor so the teeth-cage rim is rooted in rock, not open void.
#   make_liquid — animated LAVA: flowing river tiles on V_WATER cells, bubbling
#       lava pools clustered inside each "burn" (Magma Fissure) trap, plus a few
#       apron lava streaks. Same treatment the swamp's poison got (Run 94).
#   make_props  — crystal/ember-rock inner barriers fencing the player paths
#       (overhead so a ninja passes BEHIND them, DASH flies over), a coverage pass
#       killing invisible-wall gaps, sparse overhead spike accents, and flat
#       crystal/gem/mining decor on the open floor.
#   make_walls  — the stalagmite/stalactite teeth CAGE ringing the arena (gate
#       gaps left open so the exit reads as a path deeper into the caves).
#
# Import-agnostic load (ResourceLoader first, raw Image.load fallback) so it works
# the first run before Godot's import pass.
# ============================================================

const SHEET_PATH: String = "res://Assets/Tilesets/Crystal Lava Caves Tileset.png"
const PROP_DIR: String = "res://Assets/Tilesets/Cave_props/"
const TRAP = preload("res://scripts/TrapZone.gd")

# --- Prop name pools (sliced PNGs in Cave_props/) ---------------------------
const TITE_NAMES: Array = ["ctite_1", "ctite_2", "ctite_3", "ctite_4",
	"ctite_5", "ctite_6", "ctite_7"]                              # stalactites (tip DOWN)
const MITE_NAMES: Array = ["cmite_1", "cmite_2", "cmite_3", "cmite_4",
	"cmite_5", "cmite_6", "cmite_7", "cmite_8", "cmite_9"]        # stalagmites (tip UP)
const CRYSTAL_NAMES: Array = ["ccrys_1", "ccrys_2", "ccrys_3", "ccrys_4",
	"ccrys_5", "ccrys_6", "ccrys_7", "ccrys_8", "ccrys_9", "ccrys_10",
	"ccrys_11", "ccrys_12"]                                       # inner barriers
const CRYSTAL_SMALL: Array = ["ccrys_5", "ccrys_8", "ccrys_9", "ccrys_10",
	"ccrys_11", "ccrys_12"]                                       # the shorter clusters
const EROCK_NAMES: Array = ["cerock_1", "cerock_2", "cerock_3", "cerock_4",
	"cerock_5"]                                                   # ember/lava rock barriers
const SPIKE_NAMES: Array = ["cspike_1", "cspike_2"]              # small hanging spikes
const CART_NAME: String = "ccart_1"
# Flat run-over decor — [name, height(world cells), weight].
const DECOR_TABLE: Array = [
	["cbloom_1", 0.86, 2], ["cbloom_2", 0.90, 2], ["cbloom_3", 0.86, 2],
	["cember_1", 0.62, 3], ["clavapit_1", 0.95, 1], ["cgems_1", 0.42, 3],
	["cpick_1", 0.80, 1], ["cpick_2", 0.80, 1], ["cpick_3", 0.80, 1],
	["cshovel_1", 0.78, 1], ["cshovel_2", 0.70, 1],
]

# --- Ground / lava tile rects (Crystal Lava Caves Tileset.png) --------------
# Top-left of the CONTENT square inside each 140px grid cell (insets clear the
# ~2px separator lines), all cropped at SIZE px then supersampled to CELL_PX.
const TILE_SIZE: int = 104
const FLOOR_XY: Array = [[64, 64], [204, 64], [344, 64]]                 # plain volcanic cobble
# Run 100 — use the FULL spread of solid bubbling-lava body tiles from the sheet's lava
# auto-tile (Bruno: "we're not utilizing all of the lava tiles"). 9 clean variants → far
# less obvious tiling across the moat lake. (The 2418-column tiles are skipped: they carry
# the bright lava-fall crust seam on their right edge and would smear it across the lake.)
const POOL_XY:  Array = [[2136, 204], [2277, 204], [2559, 204],
	[2136, 344], [2277, 344], [2559, 344],
	[2136, 484], [2277, 484], [2559, 484]]                              # bubbling lava body
# Body tiles with bubbles in DIFFERENT spots — cross-dissolved into the surface
# animation so bubbles rise/fade smoothly instead of hard-cutting between frames.
# Run 100 polish (Bruno): keyframes are now the FULL set of clean bubble tiles from the
# lava auto-tile region — every one has a COMPLETE, unclipped bubble, with the bubble in a
# different spot so the surface reads as lively/varied. Bubbles drift center → left → up →
# down → bottom across the loop. Deliberately EXCLUDED: [2136,204]/[2559,204] (bubble
# clipped at bottom/top edge) and [1855,344] (bubble clipped at top-left corner).
const LAVA_ANIM_XY: Array = [
	[2277, 344],   # big ring, center
	[2136, 484],   # big ring, center-left
	[1855, 484],   # ring, upper-left
	[1996, 204],   # ring, bottom-left
	[1715, 484],   # ring, bottom-right + small top
	[1715, 344],   # small bubble, center
]
const RIVER_XY: Array = [[2136, 344], [2277, 344]]                      # flow base (now scrolled)

const CELL_PX: int = 64               # baked px per 32px world cell (2× supersample)
const WORLD_CELL: float = 32.0
const GROUND_Z: int = -34
const PROP_Z: int = -12
const APRON_CELLS: int = 5             # legacy apron (still used by a couple helpers)

# --- LAVA MOAT (Run 98) — the arena is an ISLAND of ground ringed by a lava lake.
# The apron beyond the arena bakes as molten lava; a glowing shoreline rim is drawn
# wherever ground meets lava (all four edges, corners, river banks, causeway sides);
# each gate keeps a GROUND CAUSEWAY crossing the moat so only the exits are passable.
const MOAT_CELLS: int = 6              # lava-lake ring baked beyond the arena (dark molten backdrop beyond)
const CAUSEWAY_HALF: float = 46.0      # half-width of the ground bridge crossing the moat at a gate
# Lava animation tuning (Run 100).
const LAVA_ANIM_FPS: float = 7.0
const LAVA_BLEND_STEPS: int = 4        # cross-dissolve frames between each bubble keyframe
const RIVER_ANIM_FPS: float = 8.0
const RIVER_FRAMES: int = 8
const LAVA_LIFT: float = 0.16          # gentle shadow lift so dark frames don't flash dark

# --- Placement tuning (props) ----------------------------------------------
const EDGE_KEEPOUT: float = 56.0
const GATE_CLEAR: float = 104.0
const OBSTACLE_CELLS: float = 1.5      # crystal / ember-rock fence height (world cells)
const ACCENT_CELLS: float = 1.8        # tall crystal / spike accent height (was 2.1 — read blown-up)
# Run 99 (Bruno): keep barrier props from crowding/overlapping and from being upscaled.
# PROP_GAP is extra clear distance enforced between every pair of prop foot-circles, so
# nothing overlaps.
#
# Run 110 (Bruno): props must NEVER be blown up past their native resolution. Earlier the
# crystals were scaled to a fixed TARGET world height (OBSTACLE/ACCENT_CELLS) regardless of
# how big the source art was — so a small-art crystal got magnified on screen (chunky,
# overpixelated) while a big-art one stayed crisp: same asset, two sizes. Now every barrier
# prop draws at ONE flat source-px → world-px scale (PROP_PX_SCALE), so each asset keeps its
# original size/resolution everywhere it lands and is never stretched up. The TARGET heights
# below are treated as an UPPER bound only (a prop may draw smaller, never bigger than flat).
# To fill a wide gap we drop 2-3 native-size props in a tight cluster instead of one big one.
const PROP_GAP: float = 14.0
# World pixels drawn per source pixel. Keep ≤ ~1/camera-zoom so 1 source px ≈ 1 screen px and
# nothing reads magnified. Lower = smaller/crisper props; raise to make every prop bigger.
const PROP_PX_SCALE: float = 0.46
const PROP_CLUSTER_GAP: float = 6.0    # spacing between props placed together (snug, not overlapped)

# --- Placement tuning (teeth cage) -----------------------------------------
# The cage reproduces the source sheet itself: an INWARD-pointing stalactite row
# interlocked with an OUTWARD-pointing stalagmite row (offset half a step) = the
# barrier band, applied to ALL FOUR walls (the side bands are the same band rotated
# 90°). Sizes preserved via a flat source-px → world-px scale so big pieces stay big.
const CAGE_K: float = 0.50             # scale for all cage teeth
const BAND_H: float = 100.0            # band depth into the arena (stalactite row + stalagmite row)
const CAGE_STEP: float = 74.0          # tooth spacing along a wall (spaced out, the half-step row fills the gaps)
const TOOTH_GATE_HALF: float = 46.0    # clear half-width of a gate doorway (no teeth)
const LAVA_GATE_CLEAR: float = 104.0   # keep lava off the exit doorway
const LAVA_BAND_W: float = 64.0        # E/W lava-river wall width (2 tiles) into the arena

static var _sheet_cache: Image = null
static var _sheet_tried: bool = false
static var _floor_cache: Array = []
static var _river_cache: Array = []
static var _lava_cache: Array = []
static var _prop_cache: Dictionary = {}
static var _shadow_tex: ImageTexture = null
static var _pool_frames: SpriteFrames = null
static var _river_frames: SpriteFrames = null


# ---------------------------------------------------------------------------
# Sheet + prop loading (import-agnostic).
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


static func _sheet() -> Image:
	if not _sheet_tried:
		_sheet_tried = true
		_sheet_cache = _load_png(SHEET_PATH)
		if _sheet_cache == null:
			push_warning("[CavernTileset] Could not load %s." % SHEET_PATH)
	return _sheet_cache


static func _prop_tex(name: String) -> ImageTexture:
	if _prop_cache.has(name):
		return _prop_cache[name]
	var img: Image = _load_png(PROP_DIR + name + ".png")
	var tex: ImageTexture = null
	if img != null:
		tex = ImageTexture.create_from_image(img)
	_prop_cache[name] = tex
	return tex


# ---------------------------------------------------------------------------
# Ground tile crop + variant builders.
# ---------------------------------------------------------------------------
static func _crop_xy(xy: Array) -> Image:
	var sheet: Image = _sheet()
	var sub: Image = sheet.get_region(Rect2i(int(xy[0]), int(xy[1]), TILE_SIZE, TILE_SIZE))
	sub.resize(CELL_PX, CELL_PX, Image.INTERPOLATE_LANCZOS)
	if sub.get_format() != Image.FORMAT_RGBA8:
		sub.convert(Image.FORMAT_RGBA8)
	return sub


# --- Lava animation image helpers (Run 100) --------------------------------
# Gentle shadow lift: darker pixels get raised toward orange a touch, bright lava is left
# alone. Pulls the dark body tiles up close to the bright ones so the animation no longer
# "flashes" dark between frames (Bruno: lighten the darker frames just a tiny bit).
static func _lift_lava(img: Image) -> Image:
	var out: Image = img.duplicate()
	var w: int = out.get_width()
	var h: int = out.get_height()
	for y in range(h):
		for x in range(w):
			var c: Color = out.get_pixel(x, y)
			var v: float = maxf(c.r, maxf(c.g, c.b))
			var lift: float = 1.0 + LAVA_LIFT * (1.0 - v)        # darker → lifted more
			out.set_pixel(x, y, Color(minf(1.0, c.r * lift),
				minf(1.0, c.g * lift), minf(1.0, c.b * lift), c.a))
	return out


# Per-pixel cross-dissolve a → b at t in [0,1]. Used to morph between bubble keyframes.
static func _blend_img(a: Image, b: Image, t: float) -> Image:
	if t <= 0.0:
		return a.duplicate()
	var out: Image = a.duplicate()
	var w: int = out.get_width()
	var h: int = out.get_height()
	for y in range(h):
		for x in range(w):
			out.set_pixel(x, y, a.get_pixel(x, y).lerp(b.get_pixel(x, y), t))
	return out


# Vertical wrap-scroll a tile down by `off` px (cheap blit, no per-pixel loop). Scrolling
# a single bright lava strip reads as smooth downward flow for the river cells.
static func _scroll_img(base: Image, off: int) -> Image:
	var w: int = base.get_width()
	var h: int = base.get_height()
	var out: Image = Image.create(w, h, false, Image.FORMAT_RGBA8)
	off = posmod(off, h)
	if off == 0:
		out.blit_rect(base, Rect2i(0, 0, w, h), Vector2i(0, 0))
		return out
	out.blit_rect(base, Rect2i(0, 0, w, h - off), Vector2i(0, off))   # main body slides down
	out.blit_rect(base, Rect2i(0, h - off, w, off), Vector2i(0, 0))   # wrap the tail to the top
	return out


static func _orient(src: Image, k: int) -> Image:
	var out: Image = src.duplicate()
	if k == 1 or k == 3:
		out.flip_x()
	if k == 2 or k == 3:
		out.flip_y()
	return out


static func _floor_variants() -> Array:
	if not _floor_cache.is_empty():
		return _floor_cache
	var out: Array = []
	for xy in FLOOR_XY:
		var base: Image = _crop_floor(xy)
		for k in range(4):
			out.append(_orient(base, k))
	_floor_cache = out
	return out


# Floor crop INSET past the cell border before resizing. The sheet's cobble cells carry
# a lighter edge column that, tiled, showed up as grey vertical seams across the ground
# (Bruno, Run 98/99). TWO defenses now: (1) a wider inset so we sample well clear of the
# cell's light border, and (2) an OVERSHOOT resize + centre-crop so the LANCZOS edge
# ringing (the real cause of the leftover seams) lands in the trimmed margin, not at the
# tile boundary. Result: every floor tile's edge is interior pixels → tiles butt clean.
const FLOOR_INSET: int = 14
const FLOOR_EDGE_TRIM: int = 4    # px trimmed off each side after the overshoot resize

static func _crop_floor(xy: Array) -> Image:
	var sheet: Image = _sheet()
	var rect := Rect2i(int(xy[0]) + FLOOR_INSET, int(xy[1]) + FLOOR_INSET,
		TILE_SIZE - 2 * FLOOR_INSET, TILE_SIZE - 2 * FLOOR_INSET)
	var sub: Image = sheet.get_region(rect)
	# Resize a touch larger than the cell, then crop the centre back to CELL_PX so the
	# filter's edge ringing is discarded and adjacent tiles meet on smooth interior pixels.
	sub.resize(CELL_PX + 2 * FLOOR_EDGE_TRIM, CELL_PX + 2 * FLOOR_EDGE_TRIM,
		Image.INTERPOLATE_LANCZOS)
	sub = sub.get_region(Rect2i(FLOOR_EDGE_TRIM, FLOOR_EDGE_TRIM, CELL_PX, CELL_PX))
	if sub.get_format() != Image.FORMAT_RGBA8:
		sub.convert(Image.FORMAT_RGBA8)
	return sub


static func _river_variants() -> Array:
	if not _river_cache.is_empty():
		return _river_cache
	var out: Array = []
	for xy in RIVER_XY:
		out.append(_crop_xy(xy))
	_river_cache = out
	return out


# Solid bubbling-lava tiles (+ flips) — the moat lake fill.
static func _lava_variants() -> Array:
	if not _lava_cache.is_empty():
		return _lava_cache
	var out: Array = []
	for xy in POOL_XY:
		var base: Image = _crop_xy(xy)
		for k in range(4):
			out.append(_orient(base, k))
	_lava_cache = out
	return out


static func _hpick(arr: Array, ci: int, cj: int, salt: int) -> Image:
	var hh: int = abs(hash(Vector2i(ci * 73856093 + salt, cj * 19349663 + salt)))
	return arr[hh % arr.size()]


# ---------------------------------------------------------------------------
# Public availability API (matches what DreamTerrain / DreamRoom call).
# ---------------------------------------------------------------------------
static func available() -> bool:
	return _prop_tex("ccrys_1") != null or _prop_tex("cerock_1") != null


static func ground_available() -> bool:
	return _sheet() != null


static func walls_available() -> bool:
	return _prop_tex("ctite_1") != null or _prop_tex("cmite_1") != null


# ===========================================================================
# GROUND — the arena ISLAND of volcanic floor, ringed by a baked LAVA MOAT with a
# glowing molten shoreline. Ground causeways cross the moat at each gate.
# ===========================================================================
# type map: 0 = void/barrier (floor tile under props), 1 = walkable ground, 2 = lava.
static func make_ground(half: Vector2, layout: RefCounted, seed_val: int,
		gate_positions: Array = []) -> Sprite2D:
	if _sheet() == null:
		return null
	var gw: int = layout.gw
	var gh: int = layout.gh
	var m: int = MOAT_CELLS
	var wc: int = gw + 2 * m
	var hc: int = gh + 2 * m
	var img := Image.create(wc * CELL_PX, hc * CELL_PX, false, Image.FORMAT_RGBA8)
	var floor_t: Array = _floor_variants()
	var river_t: Array = _river_variants()
	var lava_t: Array = _lava_variants()
	var src_rect := Rect2i(0, 0, CELL_PX, CELL_PX)
	var tmap := PackedByteArray()
	tmap.resize(wc * hc)

	for cj in range(-m, gh + m):
		for ci in range(-m, gw + m):
			var dst := Vector2i((ci + m) * CELL_PX, (cj + m) * CELL_PX)
			var tile: Image
			var typ: int
			var inside: bool = ci >= 0 and ci < gw and cj >= 0 and cj < gh
			if inside:
				var v: int = layout.val(ci, cj)
				if v == 2:                                    # V_WATER → lava river
					typ = 2
					tile = _hpick(river_t, ci, cj, 1)
				elif v == 1 or v == 3:                        # floor / bridge
					typ = 1
					tile = _hpick(floor_t, ci, cj, 7)
				else:                                         # V_VOID barrier (props cover it)
					typ = 0
					tile = _hpick(floor_t, ci, cj, 7)
			else:                                             # APRON — lava lake or a gate causeway
				if _in_causeway(layout.cell_to_world(Vector2i(ci, cj)), gate_positions, half):
					typ = 1
					tile = _hpick(floor_t, ci, cj, 7)
				else:
					typ = 2
					tile = _hpick(lava_t, ci, cj, 3)
			img.blit_rect(tile, src_rect, dst)
			tmap[(cj + m) * wc + (ci + m)] = typ

	# GLOWY MOLTEN RIM — a soft orange halo baked around the WHOLE lava silhouette (moat coast,
	# river banks, AND Magma Fissure pool banks). Glow sources = lava cells (tmap==2) plus the
	# pool-trap cells (baked as floor, but drawn as lava by make_liquid). The glow is smoothed so
	# its outer edge is a soft rounded halo, never a per-tile square crop (Bruno, Run 108).
	var sources := PackedByteArray()
	sources.resize(wc * hc)
	for i in range(tmap.size()):
		sources[i] = 1 if tmap[i] == 2 else 0
	var glow_traps: Variant = layout.get("trap_spots")
	if glow_traps != null:
		for t in glow_traps:
			if String((t as Dictionary).get("type", "")) != "burn":
				continue
			var twp: Vector2 = (t as Dictionary).get("pos", Vector2.ZERO)
			var tpr: float = float((t as Dictionary).get("pool_radius", 56.0))
			_mark_pool_sources(sources, wc, hc, m, layout, twp, tpr, gate_positions, half)
	_paint_coast_glow(img, sources, wc, hc)

	var off_world: float = float(m) * WORLD_CELL
	var spr := Sprite2D.new()
	spr.name = "TerrainGround"
	spr.centered = false
	spr.position = Vector2(-half.x - off_world, -half.y - off_world)
	spr.scale = Vector2(WORLD_CELL / float(CELL_PX), WORLD_CELL / float(CELL_PX))
	spr.z_index = GROUND_Z
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	spr.texture = ImageTexture.create_from_image(img)
	return spr


# Bake a molten halo into the ground around the whole lava silhouette. Run 108b (Bruno):
# the glow now reaches a UNIFORM distance everywhere — flat edges, convex outer corners, and
# the lava-trap rim all get the same length. Per floor pixel we take the distance to the
# nearest lava-source tile (radial at convex corners, so they reach as far as flat edges),
# combined with a SMOOTH-MIN so concave inner corners blend into a rounded outer edge instead
# of the old jaggy right-angle notch. sources[cj*wc+ci] = 1 for lava (moat/river/pool) cells.
const GLOW_COL: Color = Color(1.0, 0.52, 0.13)         # molten orange
const GLOW_STRENGTH: float = 0.95                       # peak blend right at the lava edge
const GLOW_DEPTH: float = 26.0                          # px the glow reaches from the lava (uniform all round)
const GLOW_SMIN_K: float = 20.0                         # smooth-min radius — rounds concave corners
const NEIGHBORS8: Array = [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1),
	Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]

static func _paint_coast_glow(img: Image, sources: PackedByteArray, wc: int, hc: int) -> void:
	for cj in range(hc):
		for ci in range(wc):
			if sources[cj * wc + ci] == 1:             # source cells are covered by lava tiles
				continue
			# Image-space rects of the neighbouring lava cells (≤8); empty → no glow here.
			var boxes: Array = []
			for off in NEIGHBORS8:
				var nci: int = ci + off.x
				var ncj: int = cj + off.y
				if nci < 0 or nci >= wc or ncj < 0 or ncj >= hc:
					continue
				if sources[ncj * wc + nci] == 1:
					boxes.append(Rect2(float(nci * CELL_PX), float(ncj * CELL_PX),
						float(CELL_PX), float(CELL_PX)))
			if boxes.is_empty():
				continue
			var ox: int = ci * CELL_PX
			var oy: int = cj * CELL_PX
			for py in range(CELL_PX):
				var fy: float = float(oy + py) + 0.5
				for px in range(CELL_PX):
					var fx: float = float(ox + px) + 0.5
					var d: float = 1.0e9
					for b in boxes:
						var rb: Rect2 = b
						var ddx: float = maxf(maxf(rb.position.x - fx, fx - rb.end.x), 0.0)
						var ddy: float = maxf(maxf(rb.position.y - fy, fy - rb.end.y), 0.0)
						var bd: float = sqrt(ddx * ddx + ddy * ddy)
						if d > 1.0e8:
							d = bd
						else:                              # smooth-min: round where two banks meet
							var hh: float = clampf(0.5 + 0.5 * (d - bd) / GLOW_SMIN_K, 0.0, 1.0)
							d = (d * (1.0 - hh) + bd * hh) - GLOW_SMIN_K * hh * (1.0 - hh)
					if d >= GLOW_DEPTH:
						continue
					var t: float = clampf(1.0 - d / GLOW_DEPTH, 0.0, 1.0)
					var a: float = t * GLOW_STRENGTH
					if a <= 0.004:
						continue
					var base: Color = img.get_pixel(ox + px, oy + py)
					img.set_pixel(ox + px, oy + py, base.lerp(GLOW_COL, a))


# Mark the cells of one Magma Fissure pool as glow sources (same membership _fill_pool uses),
# mapped into the moat-extended tmap index space (arena cell + m).
static func _mark_pool_sources(sources: PackedByteArray, wc: int, hc: int, m: int,
		layout: RefCounted, center: Vector2, radius: float, gates: Array, half: Vector2) -> void:
	var cc: Vector2i = layout.world_to_cell(center)
	var span: int = int(ceil(radius / WORLD_CELL)) + 1
	for dj in range(-span, span + 1):
		for di in range(-span, span + 1):
			var ci: int = cc.x + di
			var cj: int = cc.y + dj
			var v: int = layout.val(ci, cj)
			if v != 1 and v != 3:
				continue
			var wpos: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
			if wpos.distance_to(center) > radius + WORLD_CELL * 0.35:
				continue
			if _lava_blocked_by_gate(wpos, gates, half):
				continue
			var ti: int = ci + m
			var tj: int = cj + m
			if ti >= 0 and ti < wc and tj >= 0 and tj < hc:
				sources[tj * wc + ti] = 1


# A cell is part of a gate's GROUND CAUSEWAY when it sits in the gate's outward lane
# (along the exit direction, within CAUSEWAY_HALF of the lane centre).
static func _in_causeway(wp: Vector2, gates: Array, half: Vector2) -> bool:
	for g in gates:
		var gv: Vector2 = g as Vector2
		var outw: Vector2 = _gate_outward(gv, half)
		if outw == Vector2.ZERO:
			continue
		var rel: Vector2 = wp - gv
		var along: float = rel.dot(outw)
		if along < -52.0:                                     # well inside the arena — not the bridge
			continue
		var perp: float = absf(rel.x * outw.y - rel.y * outw.x)
		if perp <= CAUSEWAY_HALF:
			return true
	return false


# ===========================================================================
# SHORE — the land/lava coast built from the sheet's REAL shoreline tile (Bruno, Run 100):
# a rock→golden-crust→lava edge piece, flipped/rotated per side, plus 45°-rotated copies on
# the corner cells, so the whole island border is authored pixel art. Static for now (sits
# above the animated lava). Applies to the moat coast AND interior river/pool banks.
# ===========================================================================
# c6r1 of the sheet's lava auto-tile — rock strip (north) → bright crust → lava body (south),
# insets drop the grey grid separators. This single tile orients to every edge and corner.
const SHORE_EDGE_RECT: Array = [1692, 194, 132, 136]   # x, y, w, h
const SHORE_Z: int = -20                                # above lava (GROUND_Z+1..+2), below props (PROP_Z)

static var _shore_tex: ImageTexture = null


static func _shore_edge() -> ImageTexture:
	if _shore_tex != null:
		return _shore_tex
	var sheet: Image = _sheet()
	if sheet == null:
		return null
	var sub: Image = sheet.get_region(Rect2i(SHORE_EDGE_RECT[0], SHORE_EDGE_RECT[1],
		SHORE_EDGE_RECT[2], SHORE_EDGE_RECT[3]))
	sub.resize(CELL_PX, CELL_PX, Image.INTERPOLATE_LANCZOS)
	if sub.get_format() != Image.FORMAT_RGBA8:
		sub.convert(Image.FORMAT_RGBA8)
	_shore_tex = ImageTexture.create_from_image(sub)
	return _shore_tex


static func shore_available() -> bool:
	return _shore_edge() != null


# INTERIOR lava (a V_WATER river/pool cell inside the arena). The outer arena perimeter is
# framed by make_island_frame() instead, so the shore tile is reserved for river banks here.
static func _shore_lava(layout: RefCounted, ci: int, cj: int) -> bool:
	return ci >= 0 and ci < layout.gw and cj >= 0 and cj < layout.gh and layout.val(ci, cj) == 2


# INTERIOR land = any non-lava cell inside the arena (floor / bridge / void-barrier).
static func _shore_land(layout: RefCounted, ci: int, cj: int) -> bool:
	return ci >= 0 and ci < layout.gw and cj >= 0 and cj < layout.gh and layout.val(ci, cj) != 2


# Place oriented shoreline tiles on interior river/pool banks. The native tile reads "land to
# the NORTH"; rotation_degrees points its rock/crust side at the land (E=90, S=180, W=270).
# Corner cells (land only on a diagonal) get the tile rotated 45° toward that corner.
static func make_shore(half: Vector2, layout: RefCounted, seed_val: int,
		gate_positions: Array = []) -> Node2D:
	var tex: ImageTexture = _shore_edge()
	if tex == null:
		return null
	var root := Node2D.new()
	root.name = "CavernShore"
	root.z_index = SHORE_Z
	var gw: int = layout.gw
	var gh: int = layout.gh
	var sc: float = WORLD_CELL / float(CELL_PX)
	for cj in range(gh):
		for ci in range(gw):
			if not _shore_lava(layout, ci, cj):
				continue
			var ln: bool = _shore_land(layout, ci, cj - 1)   # land north
			var ls: bool = _shore_land(layout, ci, cj + 1)   # land south
			var le: bool = _shore_land(layout, ci + 1, cj)   # land east
			var lw: bool = _shore_land(layout, ci - 1, cj)   # land west
			var pos: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
			var any_ortho: bool = false
			if ln:
				_shore_tile(root, tex, pos, 0.0, sc)
				any_ortho = true
			if le:
				_shore_tile(root, tex, pos, 90.0, sc)
				any_ortho = true
			if ls:
				_shore_tile(root, tex, pos, 180.0, sc)
				any_ortho = true
			if lw:
				_shore_tile(root, tex, pos, 270.0, sc)
				any_ortho = true
			if any_ortho:
				continue
			# Corner cell — land only on a diagonal. Rotate the edge 45° to face that corner.
			if _shore_land(layout, ci + 1, cj - 1):
				_shore_tile(root, tex, pos, 45.0, sc)            # land NE
			if _shore_land(layout, ci + 1, cj + 1):
				_shore_tile(root, tex, pos, 135.0, sc)           # land SE
			if _shore_land(layout, ci - 1, cj + 1):
				_shore_tile(root, tex, pos, 225.0, sc)           # land SW
			if _shore_land(layout, ci - 1, cj - 1):
				_shore_tile(root, tex, pos, 315.0, sc)           # land NW
	return root


static func _shore_tile(root: Node2D, tex: ImageTexture, pos: Vector2, deg: float,
		sc: float) -> void:
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.centered = true
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	spr.position = pos
	spr.rotation_degrees = deg
	spr.scale = Vector2(sc, sc)
	root.add_child(spr)


# ===========================================================================
# ISLAND FRAME — Run 100 (Bruno): frame the whole arena like a floating island on lava,
# using his dedicated "Lava Island.png" 4×4 frame (corners + two alternating edge pieces
# per side). The arena is the island; the frame rings its rectangular perimeter (gate lanes
# left open). Grid separators are cropped via ISLAND_INSET; the inner crystals are ignored.
# ===========================================================================
const ISLAND_SHEET: String = "res://Assets/Tilesets/Lava Island.png"
const ISLAND_XE: Array = [2, 47, 91, 135, 179]      # 4×4 cell x-borders
const ISLAND_YE: Array = [2, 47, 91, 135, 179]      # 4×4 cell y-borders
const ISLAND_INSET: int = 3                          # drop the grey grid separators
const ISLAND_SUPERSAMPLE: int = 4                    # smooth-upscale each crop so magnified frame reads less pixelated
const FRAME_PX: float = 40.0                         # world size of one frame tile (smaller + finer, Bruno; tunable)
# Each edge tile is drawn slightly oversized so neighbours OVERLAP (shingle) — the brighter
# crust of the later tile covers the small per-tile border mismatch, so the coast reads as one
# continuous organic line instead of stepping at every seam (Bruno: "not jaggedy, flows better").
const FRAME_OVERLAP_FRAC: float = 0.30

static var _island_sheet: Image = null
static var _island_tried: bool = false
static var _island_cache: Dictionary = {}


static func _island_img() -> Image:
	if not _island_tried:
		_island_tried = true
		_island_sheet = _load_png(ISLAND_SHEET)
		if _island_sheet == null:
			push_warning("[CavernTileset] Could not load %s." % ISLAND_SHEET)
	return _island_sheet


# Crop frame cell (col c, row r) of the island sheet, separators trimmed.
static func _island_tex(c: int, r: int) -> ImageTexture:
	var key: int = c * 10 + r
	if _island_cache.has(key):
		return _island_cache[key]
	var sheet: Image = _island_img()
	var tex: ImageTexture = null
	if sheet != null:
		var rect := Rect2i(int(ISLAND_XE[c]) + ISLAND_INSET, int(ISLAND_YE[r]) + ISLAND_INSET,
			int(ISLAND_XE[c + 1]) - int(ISLAND_XE[c]) - 2 * ISLAND_INSET,
			int(ISLAND_YE[r + 1]) - int(ISLAND_YE[r]) - 2 * ISLAND_INSET)
		var sub: Image = sheet.get_region(rect)
		# Smooth-upscale so the magnified frame edge reads as a soft coast, not chunky pixels.
		sub.resize(rect.size.x * ISLAND_SUPERSAMPLE, rect.size.y * ISLAND_SUPERSAMPLE,
			Image.INTERPOLATE_CUBIC)
		if sub.get_format() != Image.FORMAT_RGBA8:
			sub.convert(Image.FORMAT_RGBA8)
		tex = ImageTexture.create_from_image(sub)
	_island_cache[key] = tex
	return tex


static func island_frame_available() -> bool:
	return _island_img() != null


# Ring the arena perimeter with the island frame. Corner tiles at the four corners; each side
# fills with its two edge pieces alternating (re-used along the long walls). Tiles straddle the
# ±half boundary so ground faces inward (over the arena floor) and lava faces out (over the moat).
static func make_island_frame(half: Vector2, layout: RefCounted, seed_val: int,
		gate_positions: Array = []) -> Node2D:
	if _island_img() == null:
		return null
	var root := Node2D.new()
	root.name = "CavernIslandFrame"
	root.z_index = SHORE_Z
	var f: float = FRAME_PX
	var ov: float = f * FRAME_OVERLAP_FRAC                     # shingle overlap (hides seams)
	# Corners first, so the edge tiles drawn after overlap onto them and bridge the seam.
	_frame_sprite(root, _island_tex(0, 0), Vector2(-half.x, -half.y), f, f)   # NW
	_frame_sprite(root, _island_tex(3, 0), Vector2(half.x, -half.y), f, f)    # NE
	_frame_sprite(root, _island_tex(0, 3), Vector2(-half.x, half.y), f, f)    # SW
	_frame_sprite(root, _island_tex(3, 3), Vector2(half.x, half.y), f, f)     # SE
	# Top / bottom edges (span between the corners' inner edges, alternating two pieces).
	var n_top: Array = [_island_tex(1, 0), _island_tex(2, 0)]
	var n_bot: Array = [_island_tex(1, 3), _island_tex(2, 3)]
	var avail_x: float = 2.0 * half.x - f
	var nx: int = maxi(1, int(round(avail_x / f)))
	var ew: float = avail_x / float(nx)
	for i in range(nx):
		var cx: float = -half.x + f * 0.5 + ew * (float(i) + 0.5)
		if not _frame_gap(Vector2(cx, -half.y), gate_positions, half):
			_frame_sprite(root, n_top[i % 2], Vector2(cx, -half.y), ew + ov, f)
		if not _frame_gap(Vector2(cx, half.y), gate_positions, half):
			_frame_sprite(root, n_bot[i % 2], Vector2(cx, half.y), ew + ov, f)
	# Left / right edges.
	var w_left: Array = [_island_tex(0, 1), _island_tex(0, 2)]
	var e_right: Array = [_island_tex(3, 1), _island_tex(3, 2)]
	var avail_y: float = 2.0 * half.y - f
	var ny: int = maxi(1, int(round(avail_y / f)))
	var eh: float = avail_y / float(ny)
	for j in range(ny):
		var cy: float = -half.y + f * 0.5 + eh * (float(j) + 0.5)
		if not _frame_gap(Vector2(-half.x, cy), gate_positions, half):
			_frame_sprite(root, w_left[j % 2], Vector2(-half.x, cy), f, eh + ov)
		if not _frame_gap(Vector2(half.x, cy), gate_positions, half):
			_frame_sprite(root, e_right[j % 2], Vector2(half.x, cy), f, eh + ov)
	return root


# True where the frame should OPEN — a gate's outward doorway lane — so the exit causeway
# crosses the lava unobstructed.
static func _frame_gap(pos: Vector2, gates: Array, half: Vector2) -> bool:
	return _in_gate_lane(pos, gates, half) or _near_any(pos, gates, LAVA_GATE_CLEAR)


static func _frame_sprite(root: Node2D, tex: ImageTexture, pos: Vector2, w: float,
		h: float) -> void:
	if tex == null:
		return
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.centered = true
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	spr.position = pos
	spr.scale = Vector2(w / float(tex.get_width()), h / float(tex.get_height()))
	root.add_child(spr)


# ===========================================================================
# LIQUID — animated bubbling-lava + flowing-river TILES (mirrors swamp Run 94).
# ===========================================================================
static func _liquid_frames() -> void:
	if _pool_frames != null:
		return
	# --- Bubbling SURFACE — cross-dissolve brightness-lifted bubble keyframes. The old
	# code hard-cut between 4 differently-lit body tiles, which read as a dark "flash"
	# (Bruno). Now every keyframe is shadow-lifted to match, and LAVA_BLEND_STEPS morph
	# frames are inserted between each pair so the bubbles rise and fade smoothly.
	var keys: Array = []
	for xy in LAVA_ANIM_XY:
		keys.append(_lift_lava(_crop_xy(xy)))
	_pool_frames = SpriteFrames.new()
	_pool_frames.add_animation("lava")
	_pool_frames.set_animation_loop("lava", true)
	_pool_frames.set_animation_speed("lava", LAVA_ANIM_FPS)
	var k: int = keys.size()
	for i in range(k):
		var fa: Image = keys[i]
		var fb: Image = keys[(i + 1) % k]
		for s in range(LAVA_BLEND_STEPS):
			var t: float = float(s) / float(LAVA_BLEND_STEPS)
			_pool_frames.add_frame("lava", ImageTexture.create_from_image(_blend_img(fa, fb, t)))
	# --- Flowing RIVER — vertical wrap-scroll of one bright lava strip = continuous
	# downward flow with no flicker (replaces the 2-tile swap that stuttered).
	var base: Image = _lift_lava(_crop_xy(RIVER_XY[0]))
	_river_frames = SpriteFrames.new()
	_river_frames.add_animation("flow")
	_river_frames.set_animation_loop("flow", true)
	_river_frames.set_animation_speed("flow", RIVER_ANIM_FPS)
	for f in range(RIVER_FRAMES):
		var off: int = int(round(float(f) / float(RIVER_FRAMES) * float(CELL_PX)))
		_river_frames.add_frame("flow", ImageTexture.create_from_image(_scroll_img(base, off)))


static func make_liquid(half: Vector2, layout: RefCounted, seed_val: int,
		gate_positions: Array = []) -> Node2D:
	if _sheet() == null:
		return null
	_liquid_frames()
	var root := Node2D.new()
	root.name = "CavernLava"
	root.z_index = GROUND_Z + 1                # above the rock floor, below props + heroes
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 2654435761 + 613
	var gw: int = layout.gw
	var gh: int = layout.gh

	# 1 + 3. Lava RIVERS (V_WATER cells) AND the MOAT LAKE (full apron) in one pass, with
	# rounded corners — convex points shaved to arcs, concave nooks filled with lava fillets,
	# so the lake/river boundary reads as a clean rounded edge instead of stair-step notches
	# (Bruno, Run 103). Gates + causeways stay clear.
	_lava_grid(root, layout, gw, gh, rng, gate_positions, half)

	# 2. Lava POOLS — bubbling tiles filling each Magma Fissure (burn) trap circle.
	var traps: Array = layout.get("trap_spots")
	if traps != null:
		for t in traps:
			if String((t as Dictionary).get("type", "")) != "burn":
				continue
			var wp: Vector2 = (t as Dictionary).get("pos", Vector2.ZERO)
			var pr: float = float((t as Dictionary).get("pool_radius", 56.0))
			_fill_pool(root, layout, wp, pr, rng, gate_positions, half)

	return root


# Animated lava over the WHOLE moat apron — every baked lava cell gets a bubbling tile on top
# so there are no static lava patches anywhere the player can see (Bruno, Run 101).
static func _animate_moat_coast(root: Node2D, layout: RefCounted, gw: int, gh: int,
		rng: RandomNumberGenerator, gate_positions: Array, half: Vector2) -> void:
	var ring: int = MOAT_CELLS                                 # cover the full baked apron, edge to edge
	for cj in range(-ring, gh + ring):
		for ci in range(-ring, gw + ring):
			if ci >= 0 and ci < gw and cj >= 0 and cj < gh:
				continue                                      # inside the arena → handled above
			var wp: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
			if _in_causeway(wp, gate_positions, half):
				continue
			if _lava_blocked_by_gate(wp, gate_positions, half):
				continue
			_liquid_tile(root, _pool_frames, "lava", wp, ci, cj, rng, true)


static func _lava_blocked_by_gate(p: Vector2, gates: Array, half: Vector2) -> bool:
	return _in_gate_lane(p, gates, half) or _near_any(p, gates, LAVA_GATE_CLEAR)


static func _liquid_tile(root: Node2D, frames: SpriteFrames, anim: String,
		world_pos: Vector2, ci: int, cj: int, rng: RandomNumberGenerator,
		allow_flip: bool, mat: ShaderMaterial = null) -> void:
	var a := AnimatedSprite2D.new()
	a.sprite_frames = frames
	a.animation = anim
	a.centered = true
	a.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	a.position = world_pos
	a.scale = Vector2(WORLD_CELL / float(CELL_PX), WORLD_CELL / float(CELL_PX))
	if allow_flip:
		var hsh: int = abs(hash(Vector2i(ci, cj)))
		a.flip_h = (hsh & 1) == 1
		a.flip_v = (hsh & 2) == 2
		a.frame = hsh % frames.get_frame_count(anim)
		a.speed_scale = rng.randf_range(0.85, 1.15)
	else:
		a.frame = 0
		a.speed_scale = 1.0
	# Corner-rounding material (boundary tiles only). Flip is forced OFF for these so the
	# shader's UV-space corners line up with world-space corners; a hashed start frame keeps
	# some variety even without the flip.
	if mat != null:
		a.material = mat
		a.flip_h = false
		a.flip_v = false
		a.frame = abs(hash(Vector2i(ci, cj))) % frames.get_frame_count(anim)
	a.play(anim)
	root.add_child(a)


# ===========================================================================
# CORNER ROUNDING (Bruno, Run 103) — kill the hard 90° notches where the lava
# lake / rivers meet the rock floor. Lava is drawn as opaque square cells, so a
# stair-stepped boundary shows sharp convex points and concave "dips". This pass
# rounds them: on each boundary lava cell it SHAVES the convex outer corner into
# a quarter-arc, and into each concave nook (a non-lava cell wrapped by lava on
# two adjacent sides) it drops a lava FILLET that fills the inner corner with a
# matching arc. Pure per-tile shader work — straight edges are untouched.
# ===========================================================================
const CORNER_RADIUS: float = 0.5       # arc radius in UV (half a cell)
const CORNER_AA: float = 0.045         # antialias band in UV
const CORNER_GLOW_W: float = 0.22      # UV width of the hot rim on convex floor patches
# Shows ONLY the per-corner "outside-arc sliver". glow=0 → plain (lava fillet for concave
# nooks); glow=1 → floor patch with a molten rim near the arc (cuts convex lava corners round).
const CORNER_SHADER_CODE: String = "shader_type canvas_item;\n" + \
	"uniform float radius = 0.5;\n" + \
	"uniform float aa = 0.045;\n" + \
	"uniform float glow = 0.0;\n" + \
	"uniform float glow_w = 0.22;\n" + \
	"uniform vec4 glow_col = vec4(1.0, 0.52, 0.13, 0.9);\n" + \
	"uniform vec4 corners = vec4(0.0);\n" + \
	"vec2 sliver(vec2 uv, vec2 cp, float r, float a, float gw) {\n" + \
	"	bool inbox = (cp.x < 0.5 ? uv.x < r : uv.x > 1.0 - r) && (cp.y < 0.5 ? uv.y < r : uv.y > 1.0 - r);\n" + \
	"	if (!inbox) return vec2(0.0);\n" + \
	"	vec2 ctr = vec2(cp.x < 0.5 ? r : 1.0 - r, cp.y < 0.5 ? r : 1.0 - r);\n" + \
	"	float d = distance(uv, ctr);\n" + \
	"	float cov = smoothstep(r - a, r + a, d);\n" + \
	"	float g = (1.0 - clamp((d - r) / gw, 0.0, 1.0)) * cov;\n" + \
	"	return vec2(cov, g);\n" + \
	"}\n" + \
	"void fragment() {\n" + \
	"	vec4 t = texture(TEXTURE, UV);\n" + \
	"	vec2 a0 = corners.x > 0.5 ? sliver(UV, vec2(0.0, 0.0), radius, aa, glow_w) : vec2(0.0);\n" + \
	"	vec2 a1 = corners.y > 0.5 ? sliver(UV, vec2(1.0, 0.0), radius, aa, glow_w) : vec2(0.0);\n" + \
	"	vec2 a2 = corners.z > 0.5 ? sliver(UV, vec2(0.0, 1.0), radius, aa, glow_w) : vec2(0.0);\n" + \
	"	vec2 a3 = corners.w > 0.5 ? sliver(UV, vec2(1.0, 1.0), radius, aa, glow_w) : vec2(0.0);\n" + \
	"	float s = max(max(a0.x, a1.x), max(a2.x, a3.x));\n" + \
	"	float g = max(max(a0.y, a1.y), max(a2.y, a3.y));\n" + \
	"	vec3 rgb = (glow > 0.5) ? mix(t.rgb, glow_col.rgb, g * glow_col.a) : t.rgb;\n" + \
	"	COLOR = vec4(rgb, t.a * s);\n" + \
	"}\n"
static var _corner_shader: Shader = null
static var _corner_mats: Dictionary = {}
static var _floor_tex_cache: Array = []

static func _corner_mat(corners: Vector4, glow: bool) -> ShaderMaterial:
	var key: int = (1 if corners.x > 0.5 else 0) + (2 if corners.y > 0.5 else 0) \
		+ (4 if corners.z > 0.5 else 0) + (8 if corners.w > 0.5 else 0) + (16 if glow else 0)
	if _corner_mats.has(key):
		return _corner_mats[key]
	if _corner_shader == null:
		_corner_shader = Shader.new()
		_corner_shader.code = CORNER_SHADER_CODE
	var m := ShaderMaterial.new()
	m.shader = _corner_shader
	m.set_shader_parameter("radius", CORNER_RADIUS)
	m.set_shader_parameter("aa", CORNER_AA)
	m.set_shader_parameter("glow_w", CORNER_GLOW_W)
	m.set_shader_parameter("glow_col", GLOW_COL)
	m.set_shader_parameter("corners", corners)
	m.set_shader_parameter("glow", 1.0 if glow else 0.0)
	_corner_mats[key] = m
	return m


# Floor cobble variants as ImageTextures (for the convex corner patches).
static func _floor_tex_variants() -> Array:
	if not _floor_tex_cache.is_empty():
		return _floor_tex_cache
	var out: Array = []
	for im in _floor_variants():
		out.append(ImageTexture.create_from_image(im))
	_floor_tex_cache = out
	return out


# Cut a convex lava corner round: overlay a floor patch (with a molten rim) on the lava
# cell's outer corner, ABOVE the animated lava, so the square tip reads as a rounded edge.
static func _corner_floor_patch(root: Node2D, wp: Vector2, ci: int, cj: int,
		corners: Vector4) -> void:
	var texs: Array = _floor_tex_variants()
	if texs.is_empty():
		return
	var spr := Sprite2D.new()
	spr.texture = texs[abs(hash(Vector2i(ci, cj))) % texs.size()]
	spr.centered = true
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	spr.position = wp
	spr.scale = Vector2(WORLD_CELL / float(CELL_PX), WORLD_CELL / float(CELL_PX))
	spr.z_index = 1                                    # +1 over the sibling lava tiles
	spr.material = _corner_mat(corners, true)
	root.add_child(spr)


# Is cell (ci, cj) a lava tile? Mirrors the placement rules: V_WATER rivers inside
# the arena, the lava lake everywhere in the apron, minus gate mouths + causeways.
# Cells far outside the baked region read as lava so the off-screen apron edge is
# never shaved or filleted.
static func _is_lava_cell(layout: RefCounted, ci: int, cj: int, gw: int, gh: int,
		gates: Array, half: Vector2) -> bool:
	if ci >= 0 and ci < gw and cj >= 0 and cj < gh:
		if layout.val(ci, cj) != 2:
			return false
		return not _lava_blocked_by_gate(layout.cell_to_world(Vector2i(ci, cj)), gates, half)
	var wp: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
	if _in_causeway(wp, gates, half):
		return false
	if _lava_blocked_by_gate(wp, gates, half):
		return false
	return true


# Placement of every grid lava tile (rivers + moat lake). Run 108 (Bruno): tiles are PLAIN
# SQUARES — no corner rounding, no floor patches, no fillets. Every lava tile stays a square;
# the smooth molten rim around the whole lava silhouette is baked separately by _paint_coast_glow.
static func _lava_grid(root: Node2D, layout: RefCounted, gw: int, gh: int,
		rng: RandomNumberGenerator, gates: Array, half: Vector2) -> void:
	var ring: int = MOAT_CELLS
	for cj in range(-ring, gh + ring):
		for ci in range(-ring, gw + ring):
			if not _is_lava_cell(layout, ci, cj, gw, gh, gates, half):
				continue
			var wp: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
			_liquid_tile(root, _pool_frames, "lava", wp, ci, cj, rng, true)


static func _fill_pool(root: Node2D, layout: RefCounted, center: Vector2,
		radius: float, rng: RandomNumberGenerator, gate_positions: Array,
		half: Vector2) -> void:
	# Run 108 (Bruno): PLAIN SQUARE lava tiles only — no corner rounding, no bank-glow sprites.
	# The smooth molten rim around the pool is baked once by _paint_coast_glow (pool cells are
	# registered as glow sources in make_ground), so the whole lava silhouette glows uniformly.
	var cc: Vector2i = layout.world_to_cell(center)
	var span: int = int(ceil(radius / WORLD_CELL)) + 1
	for dj in range(-span, span + 1):
		for di in range(-span, span + 1):
			var ci: int = cc.x + di
			var cj: int = cc.y + dj
			var v: int = layout.val(ci, cj)
			if v != 1 and v != 3:                  # floor / bridge only
				continue
			var wpos: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
			if wpos.distance_to(center) > radius + WORLD_CELL * 0.35:
				continue
			if _lava_blocked_by_gate(wpos, gate_positions, half):
				continue
			_liquid_tile(root, _pool_frames, "lava", wpos, ci, cj, rng, true)


static func _scatter_apron(root: Node2D, layout: RefCounted, gw: int, gh: int,
		rng: RandomNumberGenerator, gate_positions: Array, half: Vector2) -> void:
	var m: int = APRON_CELLS
	# Sparse cave bog of lava: scattered blobs across the apron band.
	var want: int = int(float(gw + gh) * 0.45)
	var made: int = 0
	var tries: int = 0
	while made < want and tries < want * 8:
		tries += 1
		var ci: int = rng.randi_range(-m, gw + m - 1)
		var cj: int = rng.randi_range(-m, gh + m - 1)
		if ci >= 0 and ci < gw and cj >= 0 and cj < gh:
			continue                               # inside the arena → skip
		var wp: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
		if _lava_blocked_by_gate(wp, gate_positions, half):
			continue
		if rng.randf() < 0.5:                       # blobby cluster
			for off in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
				if rng.randf() < 0.7:
					var c: Vector2i = Vector2i(ci + off.x, cj + off.y)
					if c.x >= 0 and c.x < gw and c.y >= 0 and c.y < gh:
						continue
					var cwp: Vector2 = layout.cell_to_world(c)
					if _lava_blocked_by_gate(cwp, gate_positions, half):
						continue
					_liquid_tile(root, _pool_frames, "lava", cwp, c.x, c.y, rng, true)
		else:
			_liquid_tile(root, _pool_frames, "lava", wp, ci, cj, rng, true)
		made += 1
	# A couple of lava streaks snaking through the apron (river tiles).
	for _s in range(rng.randi_range(2, 4)):
		var horiz: bool = rng.randf() < 0.5
		var length: int = rng.randi_range(4, 9)
		var sci: int = rng.randi_range(-m, gw + m - 1)
		var scj: int = rng.randi_range(-m, gh + m - 1)
		for k in range(length):
			var ci2: int = sci + (k if horiz else 0)
			var cj2: int = scj + (0 if horiz else k)
			if ci2 >= 0 and ci2 < gw and cj2 >= 0 and cj2 < gh:
				continue
			var swp: Vector2 = layout.cell_to_world(Vector2i(ci2, cj2))
			if _lava_blocked_by_gate(swp, gate_positions, half):
				continue
			_liquid_tile(root, _river_frames, "flow", swp, ci2, cj2, rng, false)


# ===========================================================================
# PROPS — crystal / ember-rock inner barriers + coverage + accents + decor.
# ===========================================================================
static func make_props(half: Vector2, layout: RefCounted, seed_val: int,
		gate_positions: Array = []) -> Node2D:
	var root := Node2D.new()
	root.name = "CavernProps"
	root.z_index = PROP_Z
	root.y_sort_enabled = true
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 40503 + hash("caverns")
	var gw: int = layout.gw
	var gh: int = layout.gh
	var placed: Array = []                         # [{ c:Vector2, r:float }]
	var lim_x: float = half.x - EDGE_KEEPOUT
	var lim_y: float = half.y - EDGE_KEEPOUT

	# 0. Free-standing ember-rock barriers on open floor (own dashable_barrier collider).
	_place_rock_barriers(root, placed, layout, gate_positions, rng, gw, gh, lim_x, lim_y)

	# Path-edge cells = blocked (void) cells touching the floor, inside the border.
	var edge_cells: Array = []
	for cj in range(gh):
		for ci in range(gw):
			if layout.val(ci, cj) != 0 or not _touches_floor(layout, ci, cj):
				continue
			var wc: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
			if absf(wc.x) > lim_x or absf(wc.y) > lim_y:
				continue
			edge_cells.append({ "pos": wc, "cell": Vector2i(ci, cj) })
	_shuffle(edge_cells, rng)

	# 1. CRYSTAL / ember-rock FENCES lining the player paths (occasional breaks).
	for e in edge_cells:
		var wc1: Vector2 = e["pos"]
		if _near_any(wc1, gate_positions, GATE_CLEAR):
			continue
		if rng.randf() > 0.92:
			continue
		var nm: String = _pick(CRYSTAL_NAMES, rng) if rng.randf() < 0.66 else _pick(EROCK_NAMES, rng)
		_try_obstacle(root, placed, nm, wc1,
			rng.randf_range(OBSTACLE_CELLS * 0.85, OBSTACLE_CELLS * 1.2), rng, false)

	# 2. A few obstacles about the open interior void.
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
			_try_obstacle(root, placed, _pick(CRYSTAL_NAMES, rng), wc2,
				rng.randf_range(OBSTACLE_CELLS * 0.7, OBSTACLE_CELLS), rng, false)

	# 3. Sparse "big" accents along path edges. Run 110: a big crystal formation is now a
	#    CLUSTER of 2-3 native crystals shoulder-to-shoulder (never one asset blown up); the
	#    occasional hanging spike stays a single overhead piece.
	for e3 in edge_cells:
		if rng.randf() > 0.08:
			continue
		var wc3: Vector2 = e3["pos"]
		if _near_any(wc3, gate_positions, GATE_CLEAR):
			continue
		if rng.randf() < 0.7:
			_try_cluster(root, placed, wc3, rng, CRYSTAL_NAMES, true)
		else:
			_try_obstacle(root, placed, _pick(SPIKE_NAMES, rng), wc3,
				rng.randf_range(ACCENT_CELLS * 0.85, ACCENT_CELLS * 1.15), rng, true)

	# 4. COVERAGE PASS — every collidable wall cell bordering floor wears a visible
	#    crystal/rock, so an open-looking gap is never an invisible wall.
	for cj2 in range(gh):
		for ci2 in range(gw):
			if layout.val(ci2, cj2) != 0 or not _touches_floor(layout, ci2, cj2):
				continue
			var wcc: Vector2 = layout.cell_to_world(Vector2i(ci2, cj2))
			if absf(wcc.x) > lim_x or absf(wcc.y) > lim_y:
				continue
			var covered: bool = false
			for p in placed:
				if wcc.distance_to(p["c"]) <= float(p["r"]) + 10.0:
					covered = true
					break
			if not covered:
				_fit_rock(root, placed, _pick(CRYSTAL_SMALL + EROCK_NAMES, rng), wcc, rng)

	# 5. A rare ore-cart landmark on open floor.
	if rng.randf() < 0.35:
		_place_cart(root, placed, layout, gate_positions, rng, gw, gh, lim_x, lim_y)

	# 6. Flat crystal-bloom / gem / mining decor scattered on open floor (run-over).
	var pool: Array = _decor_weighted()
	if not pool.is_empty():
		var dcount: int = int(float(gw * gh) / 44.0)     # Run 99: less scattered decor
		for _i in range(dcount):
			var ci3: int = rng.randi_range(1, gw - 2)
			var cj3: int = rng.randi_range(1, gh - 2)
			if layout.val(ci3, cj3) != 1:
				continue
			if not _open_floor(layout, ci3, cj3, 2):     # Run 99: decorate open rooms, keep hallways clean
				continue
			var dwc: Vector2 = layout.cell_to_world(Vector2i(ci3, cj3))
			if _near_any(dwc, gate_positions, GATE_CLEAR * 0.55):
				continue
			var pick: Array = pool[rng.randi() % pool.size()]
			_add_decor(root, String(pick[0]), dwc, float(pick[1]), rng)
	return root


static func _decor_weighted() -> Array:
	var out: Array = []
	for e in DECOR_TABLE:
		for _w in range(int(e[2])):
			out.append([e[0], float(e[1])])
	return out


# Free-standing ember-rock barriers on open floor — each with its own
# dashable_barrier collider (ninja DASH phases them). Placed sparingly.
static func _place_rock_barriers(root: Node2D, placed: Array, layout: RefCounted,
		gate_positions: Array, rng: RandomNumberGenerator, gw: int, gh: int,
		lim_x: float, lim_y: float) -> void:
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
			if not _open_floor(layout, ci, cj, 2):        # Run 99: open pockets only — never choke a hallway
				continue
			cands.append(wc)
	if cands.is_empty():
		return
	_shuffle(cands, rng)
	var idx: int = 0
	var n_rocks: int = rng.randi_range(1, 3)             # Run 99: a touch fewer free-standing rocks
	var done: int = 0
	while idx < cands.size() and done < n_rocks:
		var nm: String = _pick(EROCK_NAMES, rng)
		if _try_barrier(root, placed, nm, cands[idx], rng.randf_range(1.4, 1.9), rng, 0.62, 0.55):
			done += 1
		idx += 1


# One rare ore-cart on open floor (no collision — a flat landmark with a shadow).
static func _place_cart(root: Node2D, placed: Array, layout: RefCounted,
		gate_positions: Array, rng: RandomNumberGenerator, gw: int, gh: int,
		lim_x: float, lim_y: float) -> void:
	var tex: ImageTexture = _prop_tex(CART_NAME)
	if tex == null:
		return
	for _try in range(40):
		var ci: int = rng.randi_range(2, gw - 3)
		var cj: int = rng.randi_range(2, gh - 3)
		if layout.val(ci, cj) != 1:
			continue
		var wc: Vector2 = layout.cell_to_world(Vector2i(ci, cj))
		if absf(wc.x) > lim_x or absf(wc.y) > lim_y or wc.length() < 150.0:
			continue
		if _near_any(wc, gate_positions, GATE_CLEAR):
			continue
		var clash: bool = false
		for p in placed:
			if wc.distance_to(p["c"]) < 40.0 + p["r"]:
				clash = true
				break
		if clash:
			continue
		_add_decor(root, CART_NAME, wc, 1.5, rng)
		placed.append({ "c": wc, "r": 30.0 })
		return


# ===========================================================================
# WALLS — Run 98: the border is now a LAVA MOAT (the arena is an island), baked into
# make_ground (lava lake + molten shoreline rim) and animated by make_liquid. The old
# stalactite/stalagmite teeth cage is retired. This returns an empty marker node so
# DreamRoom still hides the brown placeholder wall rects; the real solid border is the
# gapped collision wall DreamRoom builds at the arena edge (gaps = the gate causeways).
static func make_walls(half: Vector2, exit_dir: Vector2, gate_positions: Array,
		seed_val: int, layout: RefCounted = null) -> Node2D:
	var root := Node2D.new()
	root.name = "CavernWalls"
	root.z_index = PROP_Z
	return root


# Horizontal border band: a HANGING stalactite row (base at band_top, tip down) and
# a STANDING stalagmite row (feet at band_bottom, tip up), offset half a step so the
# two interlock. Natural orientation — nothing rotated.
static func _h_band(root: Node2D, band_top: float, band_bottom: float, gates: Array,
		half: Vector2, rng: RandomNumberGenerator) -> void:
	var x: float = -half.x
	while x <= half.x:
		_h_place(root, x, band_top, true, gates, half, rng)
		x += CAGE_STEP + rng.randf_range(-5.0, 5.0)
	x = -half.x + CAGE_STEP * 0.5
	while x <= half.x:
		_h_place(root, x, band_bottom, false, gates, half, rng)
		x += CAGE_STEP + rng.randf_range(-5.0, 5.0)


static func _h_place(root: Node2D, x: float, edge_y: float, hang: bool, gates: Array,
		half: Vector2, rng: RandomNumberGenerator) -> void:
	var pos := Vector2(x, edge_y)
	if _in_gate_lane(pos, gates, half) or _near_gate_mouth(pos, gates, TOOTH_GATE_HALF):
		return
	var nm: String = _pick(TITE_NAMES, rng) if hang else _pick(MITE_NAMES, rng)
	var tex: ImageTexture = _prop_tex(nm)
	if tex == null:
		return
	var dh: float = float(tex.get_height()) * CAGE_K
	var cy: float = (edge_y + dh * 0.5 - 6.0) if hang else (edge_y - dh * 0.5)
	_blit_cage(root, tex, CAGE_K, Vector2(x + rng.randf_range(-4.0, 4.0), cy), 0.0, Color.WHITE, false)


# Vertical border "wall" = a LAVA RIVER. A couple of columns of animated lava tiles
# run the full wall height (border inward LAVA_BAND_W), backed by a SOLID collision
# strip so the molten river is an impassable border. The side gate keeps a gap in
# both the tiles and the collision so the exit stays reachable. `ix` points INWARD.
static func _v_lava_wall(root: Node2D, border_x: float, ix: float, gates: Array,
		half: Vector2, rng: RandomNumberGenerator) -> void:
	var cols: int = int(ceil(LAVA_BAND_W / WORLD_CELL))
	var y: float = -half.y + WORLD_CELL * 0.5
	while y <= half.y:
		for c in range(cols):
			var x: float = border_x + ix * (WORLD_CELL * (float(c) + 0.5))
			var pos := Vector2(x, y)
			if _in_gate_lane(pos, gates, half) or _near_gate_mouth(pos, gates, LAVA_GATE_CLEAR):
				continue
			_v_lava_tile(root, pos, rng)
		y += WORLD_CELL
	_v_lava_collision(root, border_x, ix, gates, half)


# One animated lava tile (flowing-river frames), sitting on the floor below heroes.
static func _v_lava_tile(root: Node2D, world_pos: Vector2, rng: RandomNumberGenerator) -> void:
	var a := AnimatedSprite2D.new()
	a.sprite_frames = _river_frames
	a.animation = "flow"
	a.centered = true
	a.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	a.position = world_pos
	a.scale = Vector2(WORLD_CELL / float(CELL_PX), WORLD_CELL / float(CELL_PX))
	var hsh: int = abs(hash(Vector2i(int(world_pos.x), int(world_pos.y))))
	a.flip_h = (hsh & 1) == 1
	a.flip_v = (hsh & 2) == 2
	a.frame = hsh % maxi(1, _river_frames.get_frame_count("flow"))
	a.speed_scale = rng.randf_range(0.85, 1.15)
	a.z_as_relative = false
	a.z_index = GROUND_Z + 2                 # above floor + ground-lava, below props/heroes
	a.play("flow")
	root.add_child(a)


# Solid border collision over the lava band, with a gap at the side gate on this wall.
static func _v_lava_collision(root: Node2D, border_x: float, ix: float, gates: Array,
		half: Vector2) -> void:
	var body := StaticBody2D.new()
	body.name = "LavaWall"
	body.collision_layer = 1
	body.collision_mask = 0
	var cx: float = border_x + ix * (LAVA_BAND_W * 0.5)
	# Gaps = side gates whose outward direction points toward THIS border.
	var cuts: Array = []
	for g in gates:
		var gv: Vector2 = g as Vector2
		var outw: Vector2 = _gate_outward(gv, half)
		if absf(outw.x) >= absf(outw.y) and signf(outw.x) == -signf(ix):
			cuts.append([gv.y - (TOOTH_GATE_HALF + 18.0), gv.y + (TOOTH_GATE_HALF + 18.0)])
	cuts.sort_custom(func(p, q): return p[0] < q[0])
	var seg_start: float = -half.y
	for cut in cuts:
		var seg_end: float = minf(cut[0], half.y)
		if seg_end - seg_start > 1.0:
			_add_lava_seg(body, cx, seg_start, seg_end)
		seg_start = maxf(seg_start, cut[1])
	if half.y - seg_start > 1.0:
		_add_lava_seg(body, cx, seg_start, half.y)
	root.add_child(body)


static func _add_lava_seg(body: StaticBody2D, cx: float, a: float, b: float) -> void:
	var cs := CollisionShape2D.new()
	var sh := RectangleShape2D.new()
	sh.size = Vector2(LAVA_BAND_W, b - a)
	cs.shape = sh
	cs.position = Vector2(cx, (a + b) * 0.5)
	body.add_child(cs)


# Draw one cage tooth centred at `center`, optionally rotated. `shadow` adds a soft
# contact shadow at the feet (for the standing stalagmite row).
static func _blit_cage(root: Node2D, tex: ImageTexture, sc: float, center: Vector2,
		rot: float, mod: Color, shadow: bool) -> void:
	var draw_h: float = float(tex.get_height()) * sc
	var draw_w: float = float(tex.get_width()) * sc
	if shadow:
		var sh := Sprite2D.new()
		var stex: ImageTexture = _shadow_texture()
		sh.texture = stex
		sh.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		var sw: float = draw_w * 0.5
		var shh: float = maxf(5.0, sw * 0.4)
		sh.scale = Vector2(sw / float(stex.get_width()), shh / float(stex.get_height()))
		sh.position = Vector2(center.x, center.y + draw_h * 0.5)
		sh.z_as_relative = false
		sh.z_index = RunState.BARRIER_OVERHANG_Z - 1
		root.add_child(sh)
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	spr.scale = Vector2(sc, sc)
	spr.position = center
	spr.rotation = rot
	spr.modulate = mod
	spr.z_as_relative = false
	spr.z_index = RunState.BARRIER_OVERHANG_Z
	root.add_child(spr)


# True when pos lies near a gate's outward doorway lane (the exit corridor).
static func _in_gate_lane(pos: Vector2, gates: Array, half: Vector2) -> bool:
	for g in gates:
		var gv: Vector2 = g as Vector2
		var outw: Vector2 = _gate_outward(gv, half)
		if outw == Vector2.ZERO:
			continue
		var rel: Vector2 = pos - gv
		var along: float = rel.dot(outw)
		if along < -TOOTH_GATE_HALF:
			continue
		var perp: float = absf(rel.x * outw.y - rel.y * outw.x)
		if perp <= TOOTH_GATE_HALF + maxf(0.0, along) * 0.1:
			return true
	return false


static func _near_gate_mouth(pos: Vector2, gates: Array, r: float) -> bool:
	return _near_any(pos, gates, r)


static func _gate_outward(g: Vector2, half: Vector2) -> Vector2:
	var dx: float = half.x - absf(g.x)
	var dy: float = half.y - absf(g.y)
	if dx <= dy:
		return Vector2(signf(g.x), 0.0)
	return Vector2(0.0, signf(g.y))


# ---------------------------------------------------------------------------
# Placement helpers (shared with the swamp module's conventions).
# ---------------------------------------------------------------------------
static func _pick(arr: Array, rng: RandomNumberGenerator) -> String:
	return arr[rng.randi() % arr.size()]


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


# True when the whole disc of radius `r` cells around (ci,cj) is walkable floor — i.e.
# this sits in an OPEN pocket, not a narrow corridor. Used to keep random scatter
# (free-standing rocks, flat decor) out of the hallways (Bruno, Run 99).
static func _open_floor(layout: RefCounted, ci: int, cj: int, r: int) -> bool:
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dy * dy > r * r + 1:
				continue
			var v: int = layout.val(ci + dx, cj + dy)
			if v != 1 and v != 3:
				return false
	return true


# The prop's height (world cells) when drawn at the flat native scale — i.e. its original
# resolution, each source pixel = PROP_PX_SCALE world px. This is the LARGEST a prop is ever
# allowed to draw (Run 110, Bruno: never blow a prop up past its native size).
static func _native_h(tex: ImageTexture) -> float:
	return float(tex.get_height()) * PROP_PX_SCALE / WORLD_CELL


# Cap a requested prop height (world cells) at the flat native scale so the sprite is never
# drawn bigger than its source art — stops small crystals being magnified/pixelated. A
# request smaller than native is honoured (downscale = still crisp, adds size variety).
static func _cap_h(tex: ImageTexture, height_cells: float) -> float:
	return minf(height_cells, _native_h(tex))


# Place an obstacle (crystal/rock/spike) at base unless its foot-circle (plus a `gap`
# clearance) overlaps an existing prop. Obstacles ride overhead so a hero passes behind
# on collision. Height is capped to NATIVE size (Run 110) so nothing is upscaled/pixelated;
# `gap` defaults to PROP_GAP but cluster members pass the tighter PROP_CLUSTER_GAP.
static func _try_obstacle(root: Node2D, placed: Array, name: String, base: Vector2,
		height_cells: float, rng: RandomNumberGenerator, tall: bool,
		gap: float = PROP_GAP) -> bool:
	var tex: ImageTexture = _prop_tex(name)
	if tex == null:
		return false
	height_cells = _cap_h(tex, height_cells)
	var foot_frac: float = 0.30 if tall else 0.40
	var draw_w: float = float(tex.get_width()) * (WORLD_CELL * height_cells / float(tex.get_height()))
	var r: float = draw_w * foot_frac
	for p in placed:
		if base.distance_to(p["c"]) < r + p["r"] + gap:
			return false
	_add_prop_tex(root, tex, base, height_cells, rng, int(WORLD_CELL * 0.10), true, not tall)
	placed.append({ "c": base, "r": r })
	return true


# Run 110 (Bruno): to cover ground or read as a BIG formation, drop 2-3 native-size props
# shoulder-to-shoulder instead of blowing one asset up. Members sit snug (PROP_CLUSTER_GAP)
# with small lateral/back offsets; each still draws at its own native resolution.
static func _try_cluster(root: Node2D, placed: Array, base: Vector2,
		rng: RandomNumberGenerator, pool: Array, tall: bool) -> bool:
	var n: int = rng.randi_range(2, 3)
	var spread: float = WORLD_CELL * 0.55
	var placed_any: bool = false
	# centre first, then flanks offset sideways (+ slight depth so they don't perfectly tile).
	if _try_obstacle(root, placed, _pick(pool, rng), base, 99.0, rng, tall, PROP_CLUSTER_GAP):
		placed_any = true
	for i in range(1, n):
		var off := Vector2(rng.randf_range(-1.0, 1.0) * spread,
			rng.randf_range(-0.25, 0.30) * spread)
		if _try_obstacle(root, placed, _pick(pool, rng), base + off, 99.0, rng, tall, PROP_CLUSTER_GAP):
			placed_any = true
	return placed_any


# Coverage-pass prop: places a NATIVE-size prop on a bare collidable cell, shrunk DOWN only
# if a neighbour is close (never blown up). If the cell sits in open space with room to
# spare, a second small crystal is tucked alongside so the cell still reads as filled.
static func _fit_rock(root: Node2D, placed: Array, name: String, base: Vector2,
		rng: RandomNumberGenerator) -> bool:
	var tex: ImageTexture = _prop_tex(name)
	if tex == null:
		return false
	var h: float = _native_h(tex)                       # original resolution, never larger
	var foot_frac: float = 0.36
	var avail: float = WORLD_CELL * 0.95
	for p in placed:
		avail = minf(avail, base.distance_to(p["c"]) - float(p["r"]) - PROP_CLUSTER_GAP)
	if avail < WORLD_CELL * 0.28:
		return false                                    # already abutted by a neighbour — leave it
	var draw_w: float = float(tex.get_width()) * (WORLD_CELL * h / float(tex.get_height()))
	var r: float = draw_w * foot_frac
	if r > avail:                                       # native wider than the gap → shrink to fit
		h *= avail / r
		r = avail
	_add_prop_tex(root, tex, base, h, rng, int(WORLD_CELL * 0.10), true, false)
	placed.append({ "c": base, "r": r })
	return true


# Floor barrier (ember rock): draw flush + attach a dashable_barrier collider.
static func _try_barrier(root: Node2D, placed: Array, name: String, base: Vector2,
		height_cells: float, rng: RandomNumberGenerator, foot_w_frac: float,
		foot_h_frac: float) -> bool:
	var tex: ImageTexture = _prop_tex(name)
	if tex == null:
		return false
	height_cells = _cap_h(tex, height_cells)
	var draw_h: float = WORLD_CELL * height_cells
	var draw_w: float = float(tex.get_width()) * (draw_h / float(tex.get_height()))
	var r: float = draw_w * 0.55
	for p in placed:
		if base.distance_to(p["c"]) < r + p["r"] + PROP_GAP:
			return false
	var sink: int = int(WORLD_CELL * 0.08)
	_add_prop_tex(root, tex, base, height_cells, rng, sink, true, true)
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


# Flat, run-over decor (no collision, no overhead) — sits above ground, below heroes.
static func _add_decor(root: Node2D, name: String, base: Vector2, height_cells: float,
		rng: RandomNumberGenerator) -> void:
	var tex: ImageTexture = _prop_tex(name)
	if tex == null:
		return
	height_cells = _cap_h(tex, height_cells)
	var sc: float = (WORLD_CELL * height_cells) / float(tex.get_height())
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	spr.scale = Vector2(sc, sc)
	var draw_h: float = float(tex.get_height()) * sc
	spr.position = base + Vector2(float(rng.randi_range(-9, 9)), 0.0) - Vector2(0.0, draw_h * 0.5)
	root.add_child(spr)


# Feet-anchored prop + soft contact shadow. Interior props in a y_sort container
# get foot-anchored wrapping for depth sorting; border props keep fixed-z.
static func _add_prop_tex(root: Node2D, tex: ImageTexture, base: Vector2, height_cells: float,
		rng: RandomNumberGenerator, sink: int, with_shadow: bool, overhead: bool) -> void:
	var th: float = float(tex.get_height())
	var tw: float = float(tex.get_width())
	var sc: float = (WORLD_CELL * height_cells) / th
	var draw_h: float = th * sc
	var draw_w: float = tw * sc
	var feet: Vector2 = base + Vector2(0.0, float(sink))
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
			var sh_w: float = draw_w * 0.6
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
		if with_shadow:
			var sh := Sprite2D.new()
			var stex: ImageTexture = _shadow_texture()
			sh.texture = stex
			sh.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
			var sh_w: float = draw_w * 0.6
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
