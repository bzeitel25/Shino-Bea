extends RefCounted

# ============================================================
# TownTileset.gd — Run 153 (2026-07-18) — real-art Town Square
# ============================================================
# Bakes the waking-world Town Square from the three hand-spliced
# town sheets (Assets/Tilesets/Town_props/<tier>/), swapping the
# whole visual set by RunState.town_visual_tier():
#   0 = delap    — Delapidated (new-save default)
#   1 = healing  — Sensei lore tier 3+ (families on the mend)
#   2 = perfect  — all Restored + Sensei max + full ending beaten
#
# Same filenames exist in every tier folder, so ONE placement
# layout serves all three tiers — only the art decays/blooms.
# NOTE: perfect/ art is half the pixel scale of delap/healing;
# everything here scales by TARGET WORLD SIZE, never fixed factors
# (Run 110 rule: props never above native res — world sizes below
# stay under native px for all three tiers).
#
# What it provides (TownSquare.gd calls these):
#   build_ground(parent, half, tier, seed)  — baked cobble/grass/path
#   build_props(parent, half, tier, keepouts) — placed + collided props
#   facade_strip(parent, half, tier)        — building fronts on the N wall
# ============================================================

const TIER_DIRS: Array = [
	"res://Assets/Tilesets/Town_props/delap/",
	"res://Assets/Tilesets/Town_props/healing/",
	"res://Assets/Tilesets/Town_props/perfect/",
]

# Run 149 — ground bakes at NATIVE res on 32px world cells, matching the
# biome tilesets (BeachTileset.WORLD_CELL = 32). The old 64px cells at
# half-res read as stretched, clunky tiles — Bruno wants the beach look.
const TEXEL: int = 1          # ground texels = world px (native 32px art, no upscale)
const CELL: float = 32.0      # world px per ground tile — same as the other biomes

static var _cache: Dictionary = {}   # "tier|name" -> Image (null cached as false)


# ---------------------------------------------------------------------------
# Asset loading — ResourceLoader when imported, Image.load fallback pre-import.
# ---------------------------------------------------------------------------
const DOJO_DIR: String = "res://Assets/Tilesets/Dojo_props/"

static func _load_img(tier: int, name: String) -> Image:
	var key: String = "%d|%s" % [tier, name]
	if _cache.has(key):
		var c = _cache[key]
		return c if c is Image else null
	# "dojo:<name>" entries pull from the Dojo prop set (tier-independent) —
	# used to dress the central Dojo landmark with matching art.
	var p: String
	if name.begins_with("dojo:"):
		p = DOJO_DIR + name.substr(5) + ".png"
	else:
		p = TIER_DIRS[clampi(tier, 0, 2)] + name + ".png"
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
	if img != null:
		img.convert(Image.FORMAT_RGBA8)
	else:
		push_warning("[TownTileset] Missing art: %s" % p)
	_cache[key] = img if img != null else false
	return img


static func _tex(tier: int, name: String) -> ImageTexture:
	var img: Image = _load_img(tier, name)
	return ImageTexture.create_from_image(img) if img != null else null


# Run 150 — HD-art props are pre-shrunk on the CPU (Lanczos) to their DRAWN
# height, so sprites render 1:1 with no NEAREST minification crunch. This is
# what makes the biomes look clean (they LINEAR-downscale); Lanczos at bake
# time is sharper still. Run 110 lock: never upscale above native res.
static var _tex_cache: Dictionary = {}   # "tier|name|h" -> ImageTexture

static func _tex_sized(tier: int, name: String, target_h: float) -> ImageTexture:
	var img: Image = _load_img(tier, name)
	if img == null:
		return null
	var s: float = minf(target_h / float(img.get_height()), 1.0)
	var w: int = maxi(1, int(round(float(img.get_width()) * s)))
	var h: int = maxi(1, int(round(float(img.get_height()) * s)))
	var key: String = "%d|%s|%d" % [tier, name, h]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var t := Image.new()
	t.copy_from(img)
	if h < t.get_height():
		t.fix_alpha_edges()   # bleed edge RGB so Lanczos doesn't ring dark halos
		t.resize(w, h, Image.INTERPOLATE_LANCZOS)
	var tex := ImageTexture.create_from_image(t)
	_tex_cache[key] = tex
	return tex


# Deterministic hash pick.
static func _hpick(arr: Array, ci: int, cj: int, salt: int):
	var h: int = abs(hash(Vector2i(ci * 73856093 + salt, cj * 19349663 + salt)))
	return arr[h % arr.size()]


# ---------------------------------------------------------------------------
# GROUND — one baked Sprite2D (Run 144 rework): clean pavement plaza from the
# City Streets auto-tile block (pave_a..d + sparing crack/weed accents +
# manhole), grass corner parks, and a FLOWING dirt-path network — a worn
# ring road around the central Dojo, a south spine to the Carnival arch,
# and a spoke to every biome gate. Paths are baked as organic ribbons
# (dirt core → dark crumb edge → sand fringe dithered into the pavement),
# matching the sheet's own path styling instead of scattering path tiles.
# ---------------------------------------------------------------------------
static func build_ground(parent: Node2D, half: Vector2, tier: int, seed_val: int) -> void:
	var old: Node = parent.get_node_or_null("TownGround")
	if old:
		old.queue_free()

	var tile_px: int = int(CELL) / TEXEL   # 32 img px per cell

	# --- Tile pools: clean cobblestone vs weedy/overgrown ---
	# Clean: pave_a (the crisp brick tile) + ground_cobble_a/b (the two larger
	# cobble sheets resized to cell size — they add subtle texture variety so
	# the clean plaza doesn't read as one repeating stamp).
	var clean_base: Array = []
	for n in ["pave_a", "ground_cobble_a", "ground_cobble_b"]:
		var im: Image = _load_img(tier, n)
		if im:
			var t: Image = _sized(im, tile_px)
			clean_base.append(t)
			var fl := Image.new()
			fl.copy_from(t)
			fl.flip_x()
			clean_base.append(fl)
	# Weedy / overgrown cobblestone: pave_b, c, d — moss and weeds between
	# the bricks, clustered where neglect naturally accumulates.
	var weedy_base: Array = []
	for n in ["pave_b", "pave_c", "pave_d"]:
		var im: Image = _load_img(tier, n)
		if im:
			var t: Image = _sized(im, tile_px)
			weedy_base.append(t)
			var fl := Image.new()
			fl.copy_from(t)
			fl.flip_x()
			weedy_base.append(fl)
	# Fallback: if one pool is empty, share the other.
	if clean_base.is_empty() and weedy_base.is_empty():
		return   # tier art not sliced yet — caller keeps its flat fallback
	if clean_base.is_empty():
		clean_base = weedy_base
	if weedy_base.is_empty():
		weedy_base = clean_base

	var accents: Array = []
	for n in ["pave_crack_a", "pave_crack_b", "pave_crack_c", "pave_weed_a", "pave_weed_b"]:
		var im2: Image = _load_img(tier, n)
		if im2:
			accents.append(_sized(im2, tile_px))
	var grass: Image = _sized(_load_img(tier, "ground_grass"), tile_px)
	var manhole: Image = _sized(_load_img(tier, "pave_manhole"), tile_px)
	var dirt: Image = _sized(_load_img(tier, "ground_dirt"), tile_px)
	var sand: Image = _sized(_load_img(tier, "ground_sand"), tile_px)

	var cols: int = int(ceil(half.x * 2.0 / CELL))
	var rows: int = int(ceil(half.y * 2.0 / CELL))
	var img := Image.create(cols * tile_px, rows * tile_px, false, Image.FORMAT_RGBA8)

	# Grass corner parks (in cells) — one per corner, 6x4 cells.
	var park_w: int = 6
	var park_h: int = 4
	var parks: Array = [
		Rect2i(2, 2, park_w, park_h),
		Rect2i(cols - 2 - park_w, 2, park_w, park_h),
		Rect2i(2, rows - 2 - park_h, park_w, park_h),
		Rect2i(cols - 2 - park_w, rows - 2 - park_h, park_w, park_h),
	]

	var segs: Array = _path_segments(half)

	# Gate keepouts — park / park-edge cells near a torii gate stay stone
	# pavement (Run 150 fix 14).
	var gate_kos: Array = _gate_positions(half)
	var gate_park_keepout: float = 165.0

	# Dojo entrance sand courtyard — an elliptical patch of sand right in
	# front of the building entrance (zen-garden approach). The dirt path
	# system bakes OVER this, so where the ring road or south spine crosses
	# the sand the path overwrites cleanly — the sand only shows between paths.
	# Dojo south face ≈ RING_CENTER.y + 132.5 (half of body height 265).
	var dojo_sand_center := Vector2(0.0, RING_CENTER.y + 172.5)
	var dojo_sand_rx: float = 58.0
	var dojo_sand_ry: float = 44.0

	# Manholes — two fixed street details, kept off the paths and parks.
	var manhole_cells: Array = []
	if manhole != null:
		for cand in [Vector2i(8, 12), Vector2i(cols - 8, 5), Vector2i(10, rows - 8), Vector2i(cols - 8, rows - 12)]:
			if manhole_cells.size() >= 2:
				break
			var wc := Vector2((float(cand.x) + 0.5) * CELL - half.x, (float(cand.y) + 0.5) * CELL - half.y)
			var in_park: bool = false
			for pr in parks:
				if (pr as Rect2i).has_point(cand):
					in_park = true
					break
			if not in_park and _min_seg_dist(wc, segs) > 70.0:
				manhole_cells.append(cand)

	# --- Zone-based tile placement ---
	# Zones create a cohesive gradient across the plaza:
	#   grass parks → scattered flowers / weedy transition → weedy perimeter
	#   → mostly-clean central plaza.
	# The Dojo entrance gets its own sand courtyard patch. Crack/weed accents
	# concentrate where neglect accumulates (edges, near parks) rather than
	# being sprinkled uniformly.
	for cj in range(rows):
		for ci in range(cols):
			var cell_wc := Vector2((float(ci) + 0.5) * CELL - half.x,
				(float(cj) + 0.5) * CELL - half.y)
			var cell_pt := Vector2i(ci, cj)
			var h_val: int = abs(hash(Vector2i(ci * 71 + seed_val, cj * 503)))

			var src: Image
			var accent_pct: int = 5   # default accent chance for the main plaza

			# Gate keepout check (shared by park + park-edge zones).
			var near_gate: bool = false
			for gk in gate_kos:
				if cell_wc.distance_to(gk as Vector2) < gate_park_keepout:
					near_gate = true
					break

			var in_park: bool = false
			for pr in parks:
				if (pr as Rect2i).has_point(cell_pt):
					in_park = true
					break

			if in_park and grass != null and not near_gate:
				# --- PARK: flower-grass ---
				src = grass
				accent_pct = 0
			elif _is_near_park(ci, cj, parks, 2) and not near_gate:
				# --- PARK EDGE: nature spilling onto cobble ---
				# Flowers bleed out of the parks, weedy cobble transitions to clean.
				var roll: int = h_val % 100
				if grass != null and roll < 18:
					src = grass
				elif roll < 68:
					src = _hpick(weedy_base, ci, cj, seed_val)
				else:
					src = _hpick(clean_base, ci, cj, seed_val)
				accent_pct = 10
			elif sand != null and _in_dojo_sand(cell_wc, dojo_sand_center, dojo_sand_rx, dojo_sand_ry):
				# --- DOJO COURTYARD: sand approach ---
				src = sand
				accent_pct = 0
			elif _near_edge(ci, cj, cols, rows, 3):
				# --- PERIMETER: neglected outer ring ---
				if h_val % 100 < 55:
					src = _hpick(weedy_base, ci, cj, seed_val)
				else:
					src = _hpick(clean_base, ci, cj, seed_val)
				accent_pct = 14
			else:
				# --- MAIN PLAZA: mostly clean cobble, some weeds ---
				if h_val % 100 < 65:
					src = _hpick(clean_base, ci, cj, seed_val)
				else:
					src = _hpick(weedy_base, ci, cj, seed_val)

			# Accent overlay (heavy cracks / thick weeds).
			if accent_pct > 0 and not accents.is_empty():
				if abs(hash(Vector2i(ci * 31337 + seed_val, cj * 771))) % 100 < accent_pct:
					src = _hpick(accents, ci, cj, seed_val + 9)

			if manhole_cells.has(cell_pt):
				src = manhole

			img.blit_rect(src, Rect2i(0, 0, tile_px, tile_px),
				Vector2i(ci * tile_px, cj * tile_px))

	# Worn dirt roads over the pavement — baked last so they flow freely.
	if dirt != null and sand != null:
		_bake_paths(img, half, segs, dirt, sand)

	# Crop the bake to the EXACT arena size (Run 152).
	var want_w: int = int(round(half.x * 2.0)) / TEXEL
	var want_h: int = int(round(half.y * 2.0)) / TEXEL
	if img.get_width() != want_w or img.get_height() != want_h:
		img = img.get_region(Rect2i(0, 0,
			mini(want_w, img.get_width()), mini(want_h, img.get_height())))

	var spr := Sprite2D.new()
	spr.name = "TownGround"
	spr.z_index = -30
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.texture = ImageTexture.create_from_image(img)
	spr.scale = Vector2(TEXEL, TEXEL)
	spr.position = Vector2(0, 0)
	parent.add_child(spr)


# Copy + resize to the bake cell size (null passes through).
# Run 150: LANCZOS when shrinking (NEAREST decimation made the ground noisy);
# NEAREST only when enlarging (keeps pixel edges, though tiles never upscale).
static func _sized(im: Image, tile_px: int) -> Image:
	if im == null:
		return null
	var t := Image.new()
	t.copy_from(im)
	if t.get_width() != tile_px or t.get_height() != tile_px:
		var interp: int = Image.INTERPOLATE_LANCZOS if t.get_width() > tile_px else Image.INTERPOLATE_NEAREST
		t.resize(tile_px, tile_px, interp)
	return t


# --- Zone helpers for build_ground -------------------------------------------

# True when (ci, cj) is within `margin` cells of any park rect but NOT inside it.
static func _is_near_park(ci: int, cj: int, parks: Array, margin: int) -> bool:
	var pt := Vector2i(ci, cj)
	for pr in parks:
		var r: Rect2i = pr as Rect2i
		if r.has_point(pt):
			continue   # inside the park itself — not an edge cell
		var expanded := Rect2i(r.position.x - margin, r.position.y - margin,
			r.size.x + margin * 2, r.size.y + margin * 2)
		if expanded.has_point(pt):
			return true
	return false


# True when the cell is within `margin` cells of the arena edge.
static func _near_edge(ci: int, cj: int, cols: int, rows: int, margin: int) -> bool:
	return ci < margin or ci >= cols - margin or cj < margin or cj >= rows - margin


# True when world-coordinate `wc` falls inside the Dojo sand courtyard ellipse,
# with a slight sin-wobble for organic edges.
static func _in_dojo_sand(wc: Vector2, center: Vector2, rx: float, ry: float) -> bool:
	var dx: float = (wc.x - center.x) / rx
	var dy: float = (wc.y - center.y) / ry
	var wob: float = sin(wc.x * 0.05 + wc.y * 0.03) * 0.12
	return dx * dx + dy * dy + wob <= 1.0


# ---------------------------------------------------------------------------
# Path network — world-space segments: ring road around the Dojo landmark,
# south spine to the Carnival arch, spokes to the five biome gates
# (positions mirror DreamBiomes.HUB_GATE_POS / TownSquare's day gates).
# ---------------------------------------------------------------------------
const RING_CENTER: Vector2 = Vector2(0, -60)   # TownSquare.DOJO_CENTER
# Run 153: oval ring widened to wrap the enlarged Dojo (430×265 body).
# East-west hugs the garden edge, north-south tucks behind the building
# at the top and meets the entrance sand at the bottom.
const RING_RX: float = 350.0    # east-west radius (outside zen garden ~215px half-w)
const RING_RY: float = 215.0    # north-south radius (tighter — path goes "behind" dojo)

# Sample a point on the oval at angle a.
static func _ring_pt(a: float) -> Vector2:
	return RING_CENTER + Vector2(cos(a) * RING_RX, sin(a) * RING_RY)

# Run 150 (Bruno fix 13): the five gate positions come straight from
# DreamBiomes.HUB_GATE_POS, clamped exactly like TownSquare clamps the gate
# nodes (±10px margin). The old hardcoded copies (±550 / -400) had drifted from
# the real gates (±580 / -390), so every path spoke stopped 10-30px short of
# its torii — the "awkwardly positioned" gates. This also feeds the gate
# keepouts that stop the corner parks from flowering under a torii (fix 14).
static func _gate_positions(half: Vector2) -> Array:
	var out: Array = []
	var db = load("res://scripts/DreamBiomes.gd")
	for biome_id in db.BIOME_ORDER:
		var raw: Vector2 = db.HUB_GATE_POS[biome_id]
		out.append(Vector2(
			clampf(raw.x, -half.x + 10.0, half.x - 10.0),
			clampf(raw.y, -half.y + 10.0, half.y - 10.0)))
	return out

static func _path_segments(half: Vector2) -> Array:
	var segs: Array = []
	var n: int = 28   # more segments for a smooth oval
	for i in range(n):
		var a0: float = TAU * float(i) / float(n)
		var a1: float = TAU * float(i + 1) / float(n)
		segs.append([_ring_pt(a0), _ring_pt(a1)])
	# South spine: dojo doorstep → carnival arch.
	segs.append([Vector2(0, RING_CENTER.y + RING_RY), Vector2(0, half.y + 8)])
	# Gate spokes — Run 152b: back to a single DIAGONAL spoke per gate (Bruno:
	# the angled walk toward each entrance feels natural; the elbow+vertical
	# approach felt like walking past the gate and doubling back). The spoke
	# now ends EXACTLY at the torii base center — no overshoot. The old +26px
	# diagonal overshoot (pre-152) plus the 10px bake drift is what pushed the
	# path ends off-center; with the crop fix the rounded dirt end now sits
	# dead under the archway, portal right above it.
	for gp in _gate_positions(half):
		var g: Vector2 = gp as Vector2
		var a: float = atan2(g.y - RING_CENTER.y, g.x - RING_CENTER.x)
		segs.append([_ring_pt(a), g])
	return segs


static func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var t: float = clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return p.distance_to(a + ab * t)


static func _min_seg_dist(p: Vector2, segs: Array) -> float:
	var d: float = INF
	for s in segs:
		d = minf(d, _seg_dist(p, s[0], s[1]))
	return d


# Ribbon profile (distances in world px, wobbled for an organic edge):
#   d < w        → dirt core
#   d < w + 3    → dark crumb rim (the sheet's path-edge crumbs)
#   d < w + 11   → sand shoulder
#   d < w + 14   → sand dithered into the surrounding pavement
static func _bake_paths(img: Image, half: Vector2, segs: Array, dirt: Image, sand: Image) -> void:
	var w_img: int = img.get_width()
	var h_img: int = img.get_height()
	var crumb := Color8(160, 123, 92)
	var crumb_dark := Color8(122, 90, 66)
	var block: int = 16   # coarse-skip block (img px)
	for by in range(0, h_img, block):
		for bx in range(0, w_img, block):
			var wc := Vector2(float(bx + block / 2) * float(TEXEL) - half.x,
				float(by + block / 2) * float(TEXEL) - half.y)
			# block half-diagonal (world px) + max band width + wobble margin
			if _min_seg_dist(wc, segs) > 23.0 + 37.0 + 8.0:
				continue
			for y in range(by, mini(by + block, h_img)):
				for x in range(bx, mini(bx + block, w_img)):
					var wp := Vector2(float(x) * float(TEXEL) + 1.0 - half.x,
						float(y) * float(TEXEL) + 1.0 - half.y)
					var d: float = _min_seg_dist(wp, segs)
					var wob: float = sin(wp.x * 0.041 + wp.y * 0.023) * 4.0 \
						+ sin(wp.y * 0.067 - wp.x * 0.017) * 3.0
					var w_dirt: float = 16.0 + wob
					if d < w_dirt:
						img.set_pixel(x, y, dirt.get_pixel(posmod(x, 32), posmod(y, 32)))
					elif d < w_dirt + 3.0:
						img.set_pixel(x, y, crumb_dark if (x + y * 3) % 5 == 0 else crumb)
					elif d < w_dirt + 11.0:
						img.set_pixel(x, y, sand.get_pixel(posmod(x, 32), posmod(y, 32)))
					elif d < w_dirt + 14.0:
						var frac: float = (w_dirt + 14.0 - d) / 3.0
						if abs(hash(Vector2i(x, y))) % 16 < int(frac * 16.0):
							img.set_pixel(x, y, sand.get_pixel(posmod(x, 32), posmod(y, 32)))


# ---------------------------------------------------------------------------
# FACADE STRIP — building fronts lining the outside of the NORTH wall, facing
# into the square (the "town beyond the plaza"). Drawn behind heroes.
# ---------------------------------------------------------------------------
static func facade_strip(parent: Node2D, half: Vector2, tier: int) -> void:
	var host := Node2D.new()
	host.name = "FacadeStrip"
	host.z_index = -8
	parent.add_child(host)

	# Dark backdrop band so delap window-holes read as shadowed interiors.
	# Run 152 — clamped to the arena width: the strip ends where the area ends.
	var back := ColorRect.new()
	back.offset_left = -half.x
	back.offset_right = half.x
	back.offset_top = -half.y - 190.0
	back.offset_bottom = -half.y + 18.0
	back.color = Color(0.10, 0.09, 0.11)
	back.z_index = -1
	host.add_child(back)

	# Run 148: facades re-cut as whole buildings; facade_awning is the striped
	# awning shop (new). Rotation keeps repeats non-adjacent along the strip.
	# Run 149: the strip is built OUTWARD from x=0 in both directions so the
	# north-gate wall section is always dead center between two buildings —
	# no more off-center gap. The [-GATE_GAP_HALF, +GATE_GAP_HALF] span gets
	# a stone wall piece with a gate-shaped hole punched through it.
	var order: Array = ["facade_a", "facade_shop", "facade_b", "facade_awning", "facade_a", "facade_shop", "facade_awning", "facade_b"]
	var target_h: float = 180.0
	var foot_y: float = -half.y + 14.0
	# Run 152 — the strip ends WHERE THE ARENA ENDS: the runs stop at ±half.x
	# and the last building on each side is CROPPED flush to the edge instead
	# of spilling past it (old runs marched to ±(half.x + 40)).
	# Right run — placed by LEFT edge, marching east.
	var i: int = 0
	var x: float = GATE_GAP_HALF
	while x < half.x - 8.0 and i < 12:
		# Run 150: pre-shrunk to the strip height — renders 1:1, no crunch.
		var tex: ImageTexture = _tex_sized(tier, order[i % order.size()], target_h)
		i += 1
		if tex == null:
			x += 200.0
			continue
		var w: float = float(tex.get_width())
		if x + w > half.x:
			var keep: int = int(half.x - x)
			if keep < 12:
				break
			tex = ImageTexture.create_from_image(
				tex.get_image().get_region(Rect2i(0, 0, keep, tex.get_height())))
			w = float(keep)
		var spr := Sprite2D.new()
		spr.texture = tex
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		spr.centered = false
		# Feet planted on the wall top edge (anchor by DRAWN height so
		# half-scale perfect-tier art doesn't float above the wall line).
		spr.position = Vector2(x, foot_y - float(tex.get_height()))
		host.add_child(spr)
		x += w - 6.0
	# Left run — placed by RIGHT edge, marching west. Starts one step into
	# the rotation so the two buildings flanking the gate differ.
	i = 1
	x = -GATE_GAP_HALF
	while x > -half.x + 8.0 and i < 13:
		var tex2: ImageTexture = _tex_sized(tier, order[i % order.size()], target_h)
		i += 1
		if tex2 == null:
			x -= 200.0
			continue
		var w2: float = float(tex2.get_width())
		if x - w2 < -half.x:
			var keep2: int = int(x + half.x)
			if keep2 < 12:
				break
			# Keep the RIGHT side of the art — the left edge is what spills.
			tex2 = ImageTexture.create_from_image(
				tex2.get_image().get_region(
					Rect2i(tex2.get_width() - keep2, 0, keep2, tex2.get_height())))
			w2 = float(keep2)
		var spr2 := Sprite2D.new()
		spr2.texture = tex2
		spr2.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		spr2.centered = false
		spr2.position = Vector2(x - w2, foot_y - float(tex2.get_height()))
		host.add_child(spr2)
		x -= w2 - 6.0

	_gate_wall(host, tier, target_h, foot_y)


# Run 149 — the gate-wall section: a stone wall filling the centered gap in
# the facade strip, with an arched gate hole cut through it so the north
# gate reads as a REAL opening in the wall (the torii frame stands in front,
# the dark passage shows through, and the dirt path runs into it).
const GATE_GAP_HALF: float = 80.0     # facade-free span each side of x=0
const GATE_HOLE_HALF_W: float = 46.0  # opening half-width — matches the torii posts' inner edge
const GATE_HOLE_H: float = 122.0      # total opening height incl. the arch (world px)

static func _gate_wall(host: Node2D, tier: int, target_h: float, foot_y: float) -> void:
	# Run 150: build from the PRE-SHRUNK facade so the wall matches the strip
	# (1:1 render, hole geometry in world px, s stays 1 at draw time).
	var tex0: ImageTexture = _tex_sized(tier, "facade_b", target_h)
	if tex0 == null:
		return
	var src: Image = tex0.get_image()
	var s: float = 1.0
	var w_img: int = src.get_width()
	var h_img: int = src.get_height()
	var need_w: int = int(ceil(GATE_GAP_HALF * 2.0 / s))
	# Fill the span, wrapping the source horizontally if it's narrower.
	var img := Image.create(need_w, h_img, false, Image.FORMAT_RGBA8)
	var xoff: int = 0
	while xoff < need_w:
		var cw: int = mini(w_img, need_w - xoff)
		img.blit_rect(src, Rect2i(0, 0, cw, h_img), Vector2i(xoff, 0))
		xoff += cw
	# Punch the opening: rectangle up from the foot, rounded arch on top,
	# with a darkened stone rim so the cut reads as built, not pasted.
	var hole_hw: float = GATE_HOLE_HALF_W / s
	var hole_h: int = int(GATE_HOLE_H / s)
	var rect_top: int = h_img - (hole_h - int(hole_hw))   # arch starts above this row
	var passage := Color(0.07, 0.06, 0.09)
	var floor_col := Color(0.42, 0.32, 0.22)              # dirt path running through
	var cx: float = float(need_w) * 0.5
	for y in range(maxi(h_img - hole_h, 0), h_img):
		for px in range(need_w):
			var dx: float = float(px) + 0.5 - cx
			var d: float
			if y >= rect_top:
				d = absf(dx)
			else:
				var dy: float = float(rect_top) - (float(y) + 0.5)
				d = sqrt(dx * dx + dy * dy)
			if d <= hole_hw:
				var c: Color = passage
				if y > h_img - 8:   # path continues under the arch
					c = passage.lerp(floor_col, float(y - (h_img - 8)) / 8.0)
				img.set_pixel(px, y, c)
			elif d <= hole_hw + 3.0:
				img.set_pixel(px, y, img.get_pixel(px, y).darkened(0.35))
	var spr := Sprite2D.new()
	spr.texture = ImageTexture.create_from_image(img)
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.scale = Vector2(s, s)
	spr.centered = false
	spr.position = Vector2(-float(need_w) * s * 0.5, foot_y - float(h_img) * s)
	host.add_child(spr)


# ---------------------------------------------------------------------------
# PROPS — placed set dressing with collision on the chunky pieces.
# keepouts: Array of {pos: Vector2, r: float} circles props must clear
# (gates, dojo door, dojo body corners).
# ---------------------------------------------------------------------------
const PLACEMENTS: Array = [
	# [name, world_h, x, y, collide_r (0 = walk-through)]
	# Run 153 — all props pushed outward for the enlarged Dojo + wider ring
	# road. RULE: nothing in the center area (Dojo only), nothing on ANY
	# path (ring road, south spine, gate spokes). Props go in the empty
	# wedges between paths, off to the sides.
	#
	# Fountain — plaza focal point, west side between SW and NW spokes.
	["fountain",   112.0, -420.0,  -60.0, 34.0],
	# Lamps — ring around the plaza, outside the ring road.
	["lamp_a",      64.0, -280.0, -290.0,  6.0],
	["lamp_b",      60.0,  280.0, -290.0,  6.0],
	["lamp_a",      64.0,  280.0,  200.0,  6.0],
	["lamp_b",      60.0, -280.0,  200.0,  6.0],
	["lamp_a",      64.0, -520.0,  -40.0,  6.0],
	["lamp_a",      64.0,  520.0,  -40.0,  6.0],
	# Market corner — east side, between SE spoke and east wall.
	["stall_a",    104.0,  555.0,  -60.0, 40.0],
	["stall_b",    104.0,  565.0,   40.0, 40.0],
	["cart",        76.0,  460.0,   80.0, 28.0],
	["barrel_a",    40.0,  510.0,   95.0, 12.0],
	["crate_a",     40.0,  535.0,  105.0, 12.0],
	["barrel_a",    40.0,  480.0,  105.0, 12.0],
	# Benches — beside the south spine, outside the ring road.
	["bench_a",     44.0, -160.0,  240.0, 14.0],
	["bench_b",     44.0,  160.0,  240.0, 14.0],
	["bench_a",     44.0, -360.0,  180.0, 14.0],
	# Green corners — trees on the grass parks.
	["tree_a",      96.0, -430.0, -300.0, 12.0],
	["tree_b",     104.0,  430.0, -305.0, 12.0],
	["tree_a",      96.0, -435.0,  255.0, 12.0],
	["tree_b",     104.0,  435.0,  250.0, 12.0],
	# Planters + flowerbeds along the south wall.
	["planter_a",   52.0, -300.0,  330.0,  10.0],
	["flowerbed",   40.0, -220.0,  345.0,  14.0],
	["planter_b",   56.0,  300.0,  332.0,  10.0],
	["flowerbed",   40.0,  220.0,  345.0,  14.0],
	# Fence runs framing the north grass parks.
	["fence_a",     36.0, -380.0, -262.0,  0.0],
	["fence_b",     36.0,  380.0, -262.0,  0.0],
	# Hanging awning shade near the market.
	["awning_hang", 56.0,  400.0, -260.0,  0.0],
	# Dojo landmark dressing — stone lanterns flank the south approach
	# outside the ring road; bonsai sit in the side wedges.
	["dojo:lantern_stone_a", 54.0,  -70.0, 260.0,  8.0],
	["dojo:lantern_stone_b", 54.0,   70.0, 260.0,  8.0],
	["dojo:bonsai_c",        58.0, -380.0, -140.0, 10.0],
	["dojo:bonsai_e",        58.0,  380.0, -140.0, 10.0],
]

# Tier flavor extras (same coordinate space).
const TIER_EXTRAS: Dictionary = {
	0: [   # Delapidated — rubble in the side wedges between paths.
		["extra_rubble", 48.0, -240.0, -290.0, 16.0],
		["extra_rubble", 44.0,  340.0,  180.0, 14.0],
		["extra_rubble", 40.0, -430.0,   50.0, 14.0],
		["extra_rubble", 44.0,  200.0, -310.0, 14.0],
	],
	1: [   # Healing — repairs underway, side wedges only.
		["extra_wheelbarrow", 56.0, -240.0, -290.0, 18.0],
		["extra_planks",      44.0,  340.0,  180.0,  0.0],
		["extra_toolbox",     30.0, -430.0,   50.0,  0.0],
	],
	2: [   # Perfect — bougainvillea blooms on the walls.
		["extra_bloomtree", 64.0, -500.0, -330.0, 0.0],
		["extra_bloomtree", 64.0,  500.0, -330.0, 0.0],
	],
}


static func build_props(parent: Node2D, half: Vector2, tier: int, keepouts: Array) -> void:
	# Foot-anchored wraps inside a y-sorted container (Y-sort depth rule:
	# heroes + interior props share z=0 and sort by foot Y). TownSquare's
	# _ready() enables y_sort_enabled on itself, so this container inherits
	# the same global sort space as the heroes.
	var host := Node2D.new()
	host.name = "TownProps"
	host.y_sort_enabled = true
	parent.add_child(host)

	var all: Array = []
	all.append_array(PLACEMENTS)
	all.append_array(TIER_EXTRAS.get(tier, []))

	# Run 149 — the dirt roads stay CLEAR (Bruno's rule: props may frame the
	# paths, never stand ON them). Guard against future placements too.
	var segs: Array = _path_segments(half)

	for rec in all:
		var name: String = rec[0]
		var wh: float = rec[1]
		var pos := Vector2(rec[2], rec[3])
		var col_r: float = rec[4]

		var blocked: bool = false
		for k in keepouts:
			if pos.distance_to(k.pos) < float(k.r):
				blocked = true
				break
		if blocked:
			continue
		# Path clearance: skip anything whose base would touch the dirt/crumb
		# band (16+wobble core + 3 crumb ≈ 26, plus half the collision base).
		if _min_seg_dist(pos, segs) < 26.0 + col_r * 0.5:
			push_warning("[TownTileset] '%s' at %s sits on a path — skipped." % [name, pos])
			continue

		# Run 150: texture arrives pre-shrunk to the drawn size (Lanczos) —
		# sprite renders 1:1, no runtime minification. Run 110 cap inside.
		var tex: ImageTexture = _tex_sized(tier, name, wh)
		if tex == null:
			continue
		wh = float(tex.get_height())
		var wrap := Node2D.new()
		wrap.position = pos              # feet
		wrap.z_as_relative = false
		wrap.z_index = 0
		var sh := Sprite2D.new()
		sh.texture = _shadow_texture()
		sh.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		var draw_w: float = float(tex.get_width())
		var sh_w: float = draw_w * 0.6
		var sh_h: float = maxf(6.0, sh_w * 0.4)
		sh.scale = Vector2(sh_w / float(sh.texture.get_width()), sh_h / float(sh.texture.get_height()))
		wrap.add_child(sh)
		var spr := Sprite2D.new()
		spr.texture = tex
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		spr.position = Vector2(0, -wh * 0.5)
		wrap.add_child(spr)
		host.add_child(wrap)

		if col_r > 0.0:
			var body := StaticBody2D.new()
			body.collision_layer = 1
			body.collision_mask = 0
			body.position = pos
			var cs := CollisionShape2D.new()
			var shape := CircleShape2D.new()
			shape.radius = col_r
			cs.shape = shape
			body.add_child(cs)
			host.add_child(body)


static var _shadow_cache: ImageTexture = null

# Soft radial contact-shadow blob (same trick as the biome tilesets).
static func _shadow_texture() -> ImageTexture:
	if _shadow_cache != null:
		return _shadow_cache
	var n: int = 32
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in range(n):
		for x in range(n):
			var d: float = Vector2(float(x) - 15.5, float(y) - 15.5).length() / 15.5
			var a: float = clampf(1.0 - d, 0.0, 1.0) * 0.28
			img.set_pixel(x, y, Color(0, 0, 0, a))
	_shadow_cache = ImageTexture.create_from_image(img)
	return _shadow_cache
