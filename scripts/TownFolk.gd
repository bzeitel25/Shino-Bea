extends RefCounted

# ============================================================
# TownFolk.gd — Run 167 (2026-08-19) — ambient villager sprites
# ============================================================
# A tiny, dependency-light way to stand a REAL family sprite in the
# world as set dressing (or behind a shop counter). FamilyNPC.gd is
# the full NPC (name plate, wandering, dialogue hooks); this is the
# decor-weight version:
#
#   * one static idle frame, foot-anchored, no label, no collision
#   * drawn at the family's CURRENT healing tier, so every villager
#     in both squares visibly heals as the player deposits karma
#   * lives in a y-sorted host, so heroes weave in front / behind
#
# Run 167 wires up the ten family sprites that were sliced back in
# Run 149 and never placed in a scene (the `*_r2` / `*_r4` members),
# plus the Dragon Fruit placeholder. See FamilySprites.gd.
# ============================================================

const FamilySprites := preload("res://scripts/FamilySprites.gd")

# lowercase sprite-family key -> RunState / BoonDB family key.
const FAM_KEY: Dictionary = {
	"apple": "Apple", "coconut": "Coconut", "broccoli": "Broccoli",
	"carrot": "Carrot", "grape": "Grape", "watermelon": "Watermelon",
	"pepper": "Pepper", "potato": "Potato", "banana": "Banana",
	"onion": "Onion",
}


# Healing tier (0-3) the given sprite member should be drawn at.
# Dragon Fruit sits outside the karma loop (Family_Roster §4.11), so its tier
# is derived from the island as a whole — RunState.dragonfruit_tier().
static func member_tier(member: String) -> int:
	var fam: String = String((FamilySprites.MEMBER_FAMILY as Dictionary).get(member, ""))
	if fam == "":
		return 2
	if fam == "dragonfruit":
		return clampi(int(RunState.dragonfruit_tier()), 0, 3)
	var key: String = String(FAM_KEY.get(fam, ""))
	if key == "":
		return 2
	return clampi(int(RunState.get_family_tier(key)), 0, 3)


# Load the idle texture for a member at a tier, walking DOWN the tiers if that
# exact one is missing (art lands tier by tier). Returns null when the member
# has no art at all — callers fall back to a placeholder.
static func idle_texture(member: String, tier: int) -> Texture2D:
	for t in [tier, 2, 1, 0, 3]:
		var sname: String = FamilySprites.strip_name(member, "idle", t)
		if sname == "" or not (FamilySprites.DB as Dictionary).has(sname):
			continue
		var p: String = FamilySprites.DIR + sname + ".png"
		if ResourceLoader.exists(p):
			var r: Resource = ResourceLoader.load(p)
			if r is Texture2D:
				return r as Texture2D
		# Pre-import fallback (a brand-new PNG Godot has not scanned yet).
		var abs_path: String = ProjectSettings.globalize_path(p)
		if FileAccess.file_exists(abs_path):
			var im := Image.new()
			if im.load(abs_path) == OK:
				im.convert(Image.FORMAT_RGBA8)
				return ImageTexture.create_from_image(im)
	return null


# Stand a villager at `pos` (world space, FEET on the point) inside `host`.
# `host` should be y-sorted; the returned wrapper carries the sprite so callers
# can nudge/flip it. `height_mult` scales the member's canonical on-screen size
# (used to push a shopkeeper slightly back behind their counter).
# NOTE: the family sheets bake their own contact shadow, so `with_shadow`
# defaults OFF — turning it on would double up.
static func make(host: Node2D, member: String, pos: Vector2,
		face_left: bool = false, height_mult: float = 1.0,
		with_shadow: bool = false) -> Node2D:
	if host == null:
		return null
	var tier: int = member_tier(member)
	var tex: Texture2D = idle_texture(member, tier)

	var wrap := Node2D.new()
	wrap.name = "Folk_%s" % member
	wrap.position = pos
	wrap.z_as_relative = false
	wrap.z_index = 0
	host.add_child(wrap)

	if tex == null:
		push_warning("[TownFolk] No idle art for '%s' — skipped." % member)
		return wrap

	var target_h: float = float((FamilySprites.TARGET_H as Dictionary).get(member, 56)) * height_mult
	var s: float = minf(target_h / maxf(float(tex.get_height()), 1.0), 1.0)

	if with_shadow:
		var sh := Sprite2D.new()
		sh.texture = _shadow_texture()
		sh.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		var sw: float = float(tex.get_width()) * s * 0.55
		var shh: float = maxf(5.0, sw * 0.38)
		sh.scale = Vector2(sw / float(sh.texture.get_width()), shh / float(sh.texture.get_height()))
		wrap.add_child(sh)

	var spr := Sprite2D.new()
	spr.name = "Sprite"
	spr.texture = tex
	spr.texture_filter = Settings.HD_SPRITE_FILTER
	spr.centered = false
	spr.scale = Vector2(s, s)
	spr.flip_h = face_left
	# Bottom-centre anchor: feet land exactly on `pos`.
	spr.offset = Vector2(-float(tex.get_width()) * 0.5, -float(tex.get_height()))
	wrap.add_child(spr)
	return wrap


static var _shadow_cache: ImageTexture = null

static func _shadow_texture() -> ImageTexture:
	if _shadow_cache != null:
		return _shadow_cache
	var n: int = 32
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in range(n):
		for x in range(n):
			var d: float = Vector2(float(x) - 15.5, float(y) - 15.5).length() / 15.5
			var a: float = clampf(1.0 - d, 0.0, 1.0) * 0.26
			img.set_pixel(x, y, Color(0, 0, 0, a))
	_shadow_cache = ImageTexture.create_from_image(img)
	return _shadow_cache
