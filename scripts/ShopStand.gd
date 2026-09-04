extends RefCounted

# ============================================================
# ShopStand.gd — Run 170 (2026-08-21) — the Dream-Hub merchants
# ============================================================
# Run 167 turned the flat coloured booths into real carnival vendor
# tables. Run 170 is Bruno's cleanup pass on them:
#
#   * THE GREY LINES ARE GONE. They were never a shader or a crop
#     offset — the two wide roof PNGs (roof_teal_wide, roof_red_wide)
#     were sliced out of the promo sheet with the sheet's own RULING
#     still attached: a horizontal grey rail across the top plus two
#     or three vertical grey droppers ruled straight down through the
#     tiles. Same story under the tables: table_*.png each carried an
#     OPAQUE dark-slate slab (the sheet background) behind the legs,
#     which is what read as a grubby grey box under every counter.
#     Both were repaired in the PNGs themselves, so the carnival
#     grounds get the fix for free. See Changelog Run 170 for the
#     exact columns.
#
#   * THE CANOPY STANDS ON POSTS. A pair of vertical scaffolding bars
#     rises from the counter's outer corners to the underside of the
#     roof, so the canopy is carried rather than hovering. The posts
#     are generated wood (no new art file), drawn BEFORE the table in
#     the y-sorted host so the counter overlaps their feet.
#
#   * NO MORE FLOATING TEXT. The name/effect/price used to be a Label
#     hanging in mid-air 168px above the stall, which crossed over
#     everything behind it. It is now a real WOODEN PRICE BOARD
#     mounted across the front of the counter, with the item on the
#     top line and the cost burnt in underneath. It sits IN the
#     y-sort (no forced z_index), so a hero walking in front of the
#     stall correctly occludes it.
#
#   * SMALLER, ROOMIER (Run 172 took another ~15% off the whole
#     silhouette — see the geometry block). Stands are sized by WIDTH now (TABLE_W), not
#     height, so every stall in the row comes out the same width no
#     matter which table art it uses — the old height-driven sizing
#     made table_counter 20% wider than table_plain_long. The goods
#     came down from 54px to 34px, and TownBuild.SHOP_SLOTS spread
#     out to match.
#
# The stand is one y-sorted Node2D and the row's keeper stands north
# of it, so the counters always draw over him — a shop, not a floating
# vendor.
# ============================================================

const CT = preload("res://scripts/CarnivalTileset.gd")

const ITEM_DIR: String = "res://Assets/Sprites/Families/Boons/"

# shop id -> [table art, goods icon, canopy art, accent colour]
# Deliberately PLAIN tables: the stall art with goods already painted on it
# (stall_dragonfruit, stall_grill) fights the boon icon for the eye, and the
# icon is the thing the player is buying. The canopy is what makes it read as
# a fairground stall rather than a bench.
# Run 170: table_plain_small is out of the rotation — it is 125px wide against
# the others' 287-327, so width-matching it made a tall skinny podium. The row
# alternates the long table and the panelled counter instead.
const STAND_ART: Dictionary = {
	"juice":       ["table_plain_long", "Boon_Juice",       "roof_teal_wide", Color(0.30, 0.80, 0.95)],
	"pie":         ["table_counter",    "Boon_Pie",         "roof_red_wide",  Color(0.95, 0.75, 0.25)],
	"dragonfruit": ["table_plain_long", "Boon_DragonFruit", "roof_red_wide",  Color(0.95, 0.35, 0.55)],
	"boon":        ["table_counter",    "prize_chest_egg",  "roof_teal_wide", Color(0.75, 0.40, 0.95)],
	"spark":       ["table_plain_long", "Boon_DragonSoul",  "roof_red_wide",  Color(1.00, 0.85, 0.30)],
}

# Run 167b (Bruno): "make sure only the one dragonfruit boy is by the 3 fruit
# stands." Tally — the hooded boy — is the whole shop staff. The rest of the
# troupe (Pitaya, Madame Nova, Jangles) stay at the Carnival where they belong.
const KEEPER: String = "tally"
const KEEPER_SCALE: float = 1.30   # he reads a touch larger than a villager

# --- geometry (world px) ----------------------------------------------------
# Run 170 (Bruno): "make them all a bit smaller, more spaced out." Sizing is
# WIDTH-driven so the row is even; the drawn height falls out of each table's
# own aspect ratio.
# ⚠ Run 172 (Bruno: "make the stalls a bit smaller, a bit closer together").
# Everything below came down ~15% together, because they are one silhouette:
# shrinking TABLE_W alone would have left a 104px sign board hanging off the
# ends of a 78px counter and a canopy floating 74px up on stubby posts. The
# board's width is the real floor — "MYSTERY BOON" at font 10 measures ~66px,
# so 88 (80 of clear face) is as narrow as the row's longest title will go.
# TownBuild.SHOP_SLOTS is tuned to THESE numbers; re-derive the row's pitch if
# any of them move.
const TABLE_W: float = 74.0      # drawn counter width — every stall matches
const GOODS_H: float = 30.0      # drawn goods height — pedestal INCLUDED
const TOP_FACE: float = 0.72     # goods sit here, as a fraction of table height
const POST_TOP: float = 66.0     # how high the scaffolding bars reach
const POST_W: float = 5.0
const CANOPY_MUL: float = 1.22   # canopy overhangs the counter by ~10px a side
const LANTERN_H: float = 48.0    # the paper lantern beside each stall
const LANTERN_GAP: float = 17.0  # ...and its clearance off the counter edge
const SIGN_W: float = 88.0
const SIGN_H: float = 40.0
const SIGN_DROP: float = 14.0    # how far the board hangs below the counter foot

# --- price board palette ----------------------------------------------------
const BOARD_WOOD: Color   = Color(0.723, 0.549, 0.377)
const BOARD_WOOD_D: Color = Color(0.639, 0.463, 0.310)
const BOARD_FRAME: Color  = Color(0.271, 0.169, 0.110)
const BOARD_LIP: Color    = Color(0.855, 0.706, 0.518)
const INK: Color          = Color(0.196, 0.129, 0.086)
const INK_PRICE: Color    = Color(0.416, 0.196, 0.055)
const POST_WOOD: Color    = Color(0.545, 0.384, 0.263)

static var _gen_cache: Dictionary = {}   # generated-texture cache


static func _item_texture(name: String) -> Texture2D:
	# Carnival props live in the prop library; boon goods in the Boons folder,
	# used WHOLE — pedestal, name plate and all (Run 167b).
	if not name.begins_with("Boon_"):
		return CT.tex(name, GOODS_H)
	var p: String = ITEM_DIR + name + ".png"
	if ResourceLoader.exists(p):
		var r: Resource = ResourceLoader.load(p)
		if r is Texture2D:
			return r as Texture2D
	var abs_path: String = ProjectSettings.globalize_path(p)
	if FileAccess.file_exists(abs_path):
		var im := Image.new()
		if im.load(abs_path) == OK:
			im.convert(Image.FORMAT_RGBA8)
			return ImageTexture.create_from_image(im)
	push_warning("[ShopStand] Missing goods art: %s" % p)
	return null


# ---------------------------------------------------------------------------
# Generated wood — a scaffolding post and a price board. Both are painted in
# code rather than shipped as PNGs: they are flat carpentry, they have to match
# TABLE_W exactly, and a generated texture needs no Godot import step.
# ---------------------------------------------------------------------------
static func _post_texture(h: int) -> ImageTexture:
	var key: String = "post|%d" % h
	if _gen_cache.has(key):
		return _gen_cache[key]
	var w: int = int(POST_W)
	var im := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in range(h):
		# a slow vertical grain so a 5px bar doesn't read as a flat rectangle
		var g: float = 1.0 + 0.05 * sin(float(y) * 0.7)
		for x in range(w):
			var c: Color = POST_WOOD * g
			if x == 0:
				c = POST_WOOD.darkened(0.42)          # left edge, in shade
			elif x == 1:
				c = POST_WOOD.lightened(0.20) * g     # lit face
			elif x == w - 1:
				c = POST_WOOD.darkened(0.30)
			c.a = 1.0
			im.set_pixel(x, y, c)
		if y % 17 == 12:                              # knot / plank tick
			im.set_pixel(2, y, POST_WOOD.darkened(0.30))
	var t := ImageTexture.create_from_image(im)
	_gen_cache[key] = t
	return t


static func _board_texture(accent: Color) -> ImageTexture:
	var key: String = "board|%s" % accent.to_html(false)
	if _gen_cache.has(key):
		return _gen_cache[key]
	var w: int = int(SIGN_W)
	var h: int = int(SIGN_H)
	var im := Image.create(w, h, false, Image.FORMAT_RGBA8)
	im.fill(Color(0, 0, 0, 0))
	for y in range(h):
		for x in range(w):
			var c: Color = BOARD_WOOD if (y % 13) < 11 else BOARD_WOOD_D
			im.set_pixel(x, y, c)
	# frame: 1px dark border, 1px lit lip inside the top/left
	for x in range(w):
		im.set_pixel(x, 0, BOARD_FRAME)
		im.set_pixel(x, h - 1, BOARD_FRAME)
		im.set_pixel(x, 1, BOARD_LIP if x > 0 and x < w - 1 else BOARD_FRAME)
		im.set_pixel(x, h - 2, BOARD_WOOD_D.darkened(0.25))
	for y in range(h):
		im.set_pixel(0, y, BOARD_FRAME)
		im.set_pixel(w - 1, y, BOARD_FRAME)
		if y > 1 and y < h - 2:
			im.set_pixel(1, y, BOARD_LIP)
			im.set_pixel(w - 2, y, BOARD_WOOD_D.darkened(0.25))
	# a 2px stripe of the stall's colour along the head of the board, so the
	# sign is visibly part of THIS stall and not a generic notice
	var stripe: Color = accent.darkened(0.25)
	stripe.a = 1.0
	for x in range(2, w - 2):
		im.set_pixel(x, 2, stripe)
		im.set_pixel(x, 3, stripe.darkened(0.22))
	# four nail heads
	for p in [Vector2i(3, 5), Vector2i(w - 4, 5), Vector2i(3, h - 5), Vector2i(w - 4, h - 5)]:
		im.set_pixel(p.x, p.y, BOARD_FRAME)
		im.set_pixel(p.x, p.y - 1, BOARD_LIP)
	var t := ImageTexture.create_from_image(im)
	_gen_cache[key] = t
	return t


static func _label(parent: Node2D, txt: String, size: int, col: Color,
		y: float, w: float) -> Label:
	var l := Label.new()
	l.text = txt
	if UISkin.font_world != null:
		l.add_theme_font_override("font", UISkin.font_world)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.65))
	l.add_theme_constant_override("outline_size", 2)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	l.position = Vector2(-w * 0.5, y)
	l.size = Vector2(w, float(size) + 5.0)
	return l


# ---------------------------------------------------------------------------
# Build one stand. Returns a dict of the parts DreamHub needs to grey out when
# the stand sells out: {root, goods, board, l_title, l_desc, l_price,
#                       accent, title, desc, cost}
# ---------------------------------------------------------------------------
static func build(host: Node2D, shop_id: String, pos: Vector2, title: String,
		desc: String, cost: int, face_left: bool) -> Dictionary:
	var art: Array = STAND_ART.get(shop_id,
		["table_plain_long", "item_juice", "roof_red_wide", Color.WHITE])
	var accent: Color = art[3]

	var stand := Node2D.new()
	stand.name = "Shop_%s" % shop_id
	stand.position = pos
	stand.y_sort_enabled = true
	host.add_child(stand)

	# --- the counter, sized by WIDTH ---------------------------------------
	# CT.place takes a drawn HEIGHT, so convert through the art's own aspect.
	var table_h: float = 48.0
	var src: Image = CT.img(String(art[0]))
	if src != null and src.get_width() > 0:
		table_h = TABLE_W * float(src.get_height()) / float(src.get_width())

	# --- scaffolding posts, BEFORE the table so the counter overlaps them ---
	# Two vertical bars from the ground to the underside of the canopy. Without
	# these the roof reads as a second piece of furniture floating in the air
	# (Bruno, Run 170).
	var post_h: int = int(round(POST_TOP - 4.0))
	var post_tex: ImageTexture = _post_texture(post_h)
	for s in [-1.0, 1.0]:
		var post := Sprite2D.new()
		post.name = "Post_%s" % ("L" if s < 0.0 else "R")
		post.texture = post_tex
		post.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		post.position = Vector2(s * (TABLE_W * 0.5 - 1.0), -4.0 - float(post_h) * 0.5)
		stand.add_child(post)

	var table: Node2D = CT.place(stand, String(art[0]), table_h, Vector2.ZERO, 0.0)
	var table_w: float = TABLE_W
	if table != null:
		var ts := table.get_node_or_null("Sprite") as Sprite2D
		if ts != null and ts.texture != null:
			table_w = float(ts.texture.get_width())
	# Solid counter so the heroes can't walk through the shop.
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = pos + Vector2(0, -14.0)
	var cs := CollisionShape2D.new()
	var box := RectangleShape2D.new()
	box.size = Vector2(maxf(56.0, table_w * 0.90), 26.0)
	cs.shape = box
	body.add_child(cs)
	host.add_child(body)

	# --- canopy, resting on the posts --------------------------------------
	var csrc: Image = CT.img(String(art[2]))
	if csrc != null and csrc.get_width() > 0:
		var cw: float = table_w * CANOPY_MUL
		var ch: float = cw * float(csrc.get_height()) / float(csrc.get_width())
		var canopy: ImageTexture = CT.tex(String(art[2]), ch)
		if canopy != null:
			var cspr := Sprite2D.new()
			cspr.name = "Canopy"
			cspr.texture = canopy
			cspr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			# bottom edge lands exactly on the top of the posts
			cspr.position = Vector2(0, -POST_TOP - float(canopy.get_height()) * 0.5)
			cspr.z_as_relative = false
			cspr.z_index = 2
			stand.add_child(cspr)

	# --- the goods, standing ON the counter ---------------------------------
	var goods: Sprite2D = null
	var gtex: Texture2D = _item_texture(String(art[1]))
	if gtex != null and table != null:
		goods = Sprite2D.new()
		goods.name = "Goods"
		goods.texture = gtex
		goods.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		var gs: float = minf(GOODS_H / float(gtex.get_height()), 1.0)
		goods.scale = Vector2(gs, gs)
		# Bottom-anchored on the table top, so the PEDESTAL sits on the counter
		# and nothing is cropped (Run 167b).
		goods.offset = Vector2(0, -float(gtex.get_height()) * 0.5)
		goods.position = Vector2(0, -table_h * TOP_FACE)
		goods.z_as_relative = true
		goods.z_index = 1
		table.add_child(goods)
		# A soft warm pool so the goods read at night without repainting the art.
		GlowLight.attach(table, Vector2(0, -table_h * 0.9), accent, 60.0, 0.50, 0.10)

	# --- lantern on a pole beside the stall ---------------------------------
	# It always hangs on the ROAD side of the stall (face_left is set from the
	# slot's x), so the row's lanterns light the street between the two sides
	# rather than the empty stone behind it.
	CT.place(stand, "lantern_paper_f1", LANTERN_H,
		Vector2((table_w * 0.5 + LANTERN_GAP) * (-1.0 if face_left else 1.0), -4.0), 0.0)

	# --- the wooden price board, across the front of the counter ------------
	# Run 170 (Bruno): "a proper wooden sign at the front/bottom of each table
	# with the item and cost written on it, rather than just floating text
	# hovering over everything." No forced z_index — the board rides the
	# y-sort at y +SIGN_DROP, so it draws over its own counter and UNDER a hero
	# standing in front of the stall. That drop is also what keeps the counter
	# top and the goods visible above the board instead of buried behind it.
	var sign_root := Node2D.new()
	sign_root.name = "PriceBoard"
	sign_root.position = Vector2(0, SIGN_DROP)
	stand.add_child(sign_root)

	var board := Sprite2D.new()
	board.name = "Board"
	board.texture = _board_texture(accent)
	board.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	board.position = Vector2(0, -SIGN_H * 0.5)
	sign_root.add_child(board)

	# three lines, laid out against the board's 40px face: name (10), effect (8),
	# price (10). Run 172: the board narrowed to 88, leaving 80px of clear face.
	# The two widest strings are "MYSTERY BOON" (font 10, ~66px) and "Level up a
	# boon" (font 8, ~66px) — both still clear, no wrapping, no clipping.
	var l_title: Label = _label(sign_root, title, 10, accent.darkened(0.62), -SIGN_H + 4.0, SIGN_W - 8.0)
	var l_desc: Label  = _label(sign_root, desc, 8, INK, -SIGN_H + 16.0, SIGN_W - 8.0)
	var l_price: Label = _label(sign_root, "%dc" % cost, 10, INK_PRICE, -SIGN_H + 27.0, SIGN_W - 8.0)

	return {"root": stand, "goods": goods, "board": board,
		"l_title": l_title, "l_desc": l_desc, "l_price": l_price,
		"accent": accent, "title": title, "desc": desc, "cost": cost}


# Sold out for this visit: goods go dark, the board says so.
static func set_sold(parts: Dictionary, sold: bool) -> void:
	if parts.is_empty():
		return
	var goods := parts.get("goods") as Sprite2D
	if goods != null:
		goods.modulate = Color(0.32, 0.32, 0.36, 0.85) if sold else Color(1, 1, 1, 1)
	var board := parts.get("board") as Sprite2D
	if board != null:
		board.modulate = Color(0.62, 0.60, 0.62, 1.0) if sold else Color(1, 1, 1, 1)
	var accent: Color = parts.get("accent", Color.WHITE)
	var l_title := parts.get("l_title") as Label
	if l_title != null:
		l_title.add_theme_color_override("font_color",
			Color(0.34, 0.32, 0.34) if sold else accent.darkened(0.62))
	var l_desc := parts.get("l_desc") as Label
	if l_desc != null:
		l_desc.text = "sold out" if sold else String(parts.get("desc", ""))
		l_desc.add_theme_color_override("font_color",
			Color(0.36, 0.34, 0.36) if sold else INK)
	var l_price := parts.get("l_price") as Label
	if l_price != null:
		l_price.text = "—" if sold else "%dc" % int(parts.get("cost", 0))
		l_price.add_theme_color_override("font_color",
			Color(0.36, 0.34, 0.36) if sold else INK_PRICE)
