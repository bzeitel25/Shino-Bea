extends RefCounted

# ============================================================
# ShopStand.gd — Run 167 (2026-08-19) — the Dream-Hub merchants
# ============================================================
# Replaces the flat coloured booth + emoji that stood in for the
# between-biome shops. Every stand is now a real little shop:
#
#   * a CARNIVAL vendor table (Assets/Tilesets/Carnival_props) —
#     the stands sit just north of the south carnival torii, so
#     they're dressed as the fair spilling into the square;
#   * the GOODS on the table are the proper boon icons, PEDESTAL AND
#     ALL (Assets/Sprites/Families/Boons/Boon_*.png) — Run 167b,
#     Bruno: "keep the fruits and items on their pedestals, just make
#     them smaller to fit on the table. No cutting the top part off
#     the pedestal — it makes it look weird";
#   * ONE shopkeeper for the whole row — Tally, the hooded Dragon
#     Fruit boy, stands behind the counters (Run 167b). DreamHub
#     places him at TownBuild.SHOP_KEEPER_POS; a stand does not build
#     a keeper of its own;
#   * a paper lantern with a real GlowLight, so the row of shops is
#     what lights the south end of the night square;
#   * a hanging sign board with the name + price, and a SOLD OUT
#     state that greys the goods and kills the [E] prompt.
#
# The stand is one y-sorted Node2D, and the row's keeper stands north
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
const STAND_ART: Dictionary = {
	"juice":       ["table_plain_long",  "Boon_Juice",       "roof_teal_wide", Color(0.30, 0.80, 0.95)],
	"pie":         ["table_counter",     "Boon_Pie",         "roof_red_wide",  Color(0.95, 0.75, 0.25)],
	"dragonfruit": ["table_plain_small", "Boon_DragonFruit", "roof_red_wide",  Color(0.95, 0.35, 0.55)],
	"boon":        ["table_plain_long",  "prize_chest_egg",  "roof_teal_wide", Color(0.75, 0.40, 0.95)],
	"spark":       ["table_plain_small", "Boon_DragonSoul",  "roof_red_wide",  Color(1.00, 0.85, 0.30)],
}

# Run 167b (Bruno): "make sure only the one dragonfruit boy is by the 3 fruit
# stands." Tally — the hooded boy — is the whole shop staff. The rest of the
# troupe (Pitaya, Madame Nova, Jangles) stay at the Carnival where they belong.
const KEEPER: String = "tally"
const KEEPER_SCALE: float = 1.30   # he reads a touch larger than a villager

# Run 167b: "you can make the shop stalls a bit smaller too, they take up a lot
# of space." Every number below came down; the goods keep their pedestal and
# are sized to SIT on the counter rather than being cropped to fit it.
const TABLE_H: float = 54.0      # drawn table height (world px)
const GOODS_H: float = 54.0      # drawn goods height — pedestal INCLUDED
const CANOPY_H: float = 40.0     # drawn stall-canopy height


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
# Build one stand. Returns a dict of the parts DreamHub needs to grey out when
# the stand sells out: {root, goods, sign, accent, title, desc}
# ---------------------------------------------------------------------------
static func build(host: Node2D, shop_id: String, pos: Vector2, title: String,
		desc: String, face_left: bool) -> Dictionary:
	var art: Array = STAND_ART.get(shop_id,
		["table_plain_long", "item_juice", "roof_red_wide", Color.WHITE])
	var accent: Color = art[3]

	var stand := Node2D.new()
	stand.name = "Shop_%s" % shop_id
	stand.position = pos
	stand.y_sort_enabled = true
	host.add_child(stand)

	# --- the counter --------------------------------------------------------
	var table: Node2D = CT.place(stand, String(art[0]), TABLE_H, Vector2.ZERO, 0.0)
	var table_w: float = 140.0
	if table != null:
		var ts := table.get_node_or_null("Sprite") as Sprite2D
		if ts != null and ts.texture != null:
			table_w = float(ts.texture.get_width())
	# Solid counter so the heroes can't walk through the shop.
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = pos + Vector2(0, -15.0)
	var cs := CollisionShape2D.new()
	var box := RectangleShape2D.new()
	box.size = Vector2(maxf(56.0, table_w * 0.86), 28.0)
	cs.shape = box
	body.add_child(cs)
	host.add_child(body)

	# --- canopy over the stall ----------------------------------------------
	var canopy: ImageTexture = CT.tex(String(art[2]), CANOPY_H)
	if canopy != null:
		var cspr := Sprite2D.new()
		cspr.name = "Canopy"
		cspr.texture = canopy
		cspr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		# A shade has to OVERHANG the counter it shades, or it reads as a
		# second piece of furniture floating in the air. Target ~1.25x the
		# table width, never above native res (Run 110 lock).
		var cs2: float = clampf(table_w * 1.25 / maxf(float(canopy.get_width()), 1.0), 0.55, 1.0)
		cspr.scale = Vector2(cs2, cs2)
		cspr.position = Vector2(0, -TABLE_H - 62.0)
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
		# Bottom-anchored on the table top (~74% up the table sprite), so the
		# PEDESTAL sits on the counter and nothing is cropped (Run 167b).
		goods.offset = Vector2(0, -float(gtex.get_height()) * 0.5)
		goods.position = Vector2(0, -TABLE_H * 0.74)
		goods.z_as_relative = true
		goods.z_index = 1
		table.add_child(goods)
		# A soft warm pool so the goods read at night without repainting the art.
		GlowLight.attach(table, Vector2(0, -TABLE_H * 0.9), accent, 66.0, 0.50, 0.10)

	# --- lantern on a pole beside the stall ---------------------------------
	CT.place(stand, "lantern_paper_f1", 60.0,
		Vector2((table_w * 0.5 + 20.0) * (-1.0 if face_left else 1.0), -4.0), 0.0)

	# --- hanging sign -------------------------------------------------------
	var sign := Label.new()
	sign.name = "Sign"
	sign.text = "%s\n%s" % [title, desc]
	sign.add_theme_font_size_override("font_size", 12)
	sign.add_theme_color_override("font_color", accent)
	sign.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.92))
	sign.add_theme_constant_override("outline_size", 4)
	sign.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sign.position = Vector2(-80, -168)
	sign.custom_minimum_size = Vector2(160, 0)
	sign.z_as_relative = false
	sign.z_index = 12
	stand.add_child(sign)

	return {"root": stand, "goods": goods, "sign": sign,
		"accent": accent, "title": title, "desc": desc}


# Sold out for this visit: goods go dark, the sign says so.
static func set_sold(parts: Dictionary, sold: bool) -> void:
	if parts.is_empty():
		return
	var goods := parts.get("goods") as Sprite2D
	if goods != null:
		goods.modulate = Color(0.32, 0.32, 0.36, 0.85) if sold else Color(1, 1, 1, 1)
	var sign := parts.get("sign") as Label
	if sign != null:
		var title: String = String(parts.get("title", ""))
		if sold:
			sign.text = "%s\nSOLD OUT" % title
			sign.add_theme_color_override("font_color", Color(0.58, 0.58, 0.62))
		else:
			sign.text = "%s\n%s" % [title, String(parts.get("desc", ""))]
			sign.add_theme_color_override("font_color", parts.get("accent", Color.WHITE))
