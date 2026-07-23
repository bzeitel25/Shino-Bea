extends Node2D

# ============================================================
# FamilyNPC.gd — Run 147 (2026-07-15) — family member (real art + fallback)
# ============================================================
# Members listed in NAME_TO_MEMBER render with the sliced Gemini strips
# (FamilySprites.gd DB, idle front + walk right, flip for left). Everyone
# else keeps the Run 117 stick-figure + fruit-head placeholder (colored by
# RunState.FAM_COLOR). Missing tiers (e.g. Broccoli Restored) fall back to
# the placeholder figure until the sheet lands.
#
#   setup(family, npc_name, is_elder)  — build the body
#   set_tier(t)                        — healing-tier visual state:
#       0 Rotten   — moldy tint, slumped
#       1 Wilted   — pale, upright
#       2 Ripe     — full family color, vibrant
#       3 Restored — HUMAN (skin-tone head) — needs real art eventually
#   enable_wander(rect)                — casual stroll inside rect
#                                        (elders never wander — they are
#                                        the fixed karma drop-off point)
# ============================================================

const WALK_SPEED: float = 30.0
const SKIN: Color = Color(0.94, 0.78, 0.62)

const FamilySprites := preload("res://Scripts/FamilySprites.gd")

# Display name (as passed to setup / used by FamilyLore) -> FamilySprites key.
# Members NOT listed here have no real art yet and keep the stick-figure path.
const NAME_TO_MEMBER := {
	# Apple
	"Granny Idunn": "idunn",
	"Cormac":       "cormac",
	"Blossom":      "blossom",
	"Pip":          "pip",
	# Coconut
	"Gnarls":       "gnarls",
	"Piña":         "pina",
	"Kai":          "kai",
	"Shelly":       "shelly",
	# Banana
	"Splitz":       "splitz",
	"Nanette":      "nanette",
	# Broccoli
	"Broc Lee":     "broclee",
	"Roman":        "roman",
	"Remy":         "remy",
	# Carrot
	"Fletch":       "fletch",
	"Scout":        "scout",
	# Grape
	"Nonna Vitti":  "vitti",
	"Welchie":      "welchie",
	"Mani":         "mani",
	# Watermelon
	"Auntie July":  "july",
	"Wally":        "wally",
	"Bobby":        "bobby",
	# Pepper
	"Flambeau":     "flambeau",
	"Rika":         "rika",
	"Niño":         "nino",
	# Potato
	"Russel":       "russel",
	"Tot":          "tot",
	"Wedge":        "wedge",
	# Onion
	"Alliam":       "alliam",
	"Lottie":       "lottie",
	"Pearl":        "pearl",
}

# Members whose idle is a PROFILE stance (no front-facing frames in the art):
# they keep facing their last walk direction when they stop instead of
# snapping to a front idle. Run 147: all members now have front-facing idle
# from the new Gemini sheets — list is empty for now.
const PROFILE_IDLE := []

var family: String = ""
var npc_name: String = ""
var is_elder: bool = false
var tier: int = 0

var _wander: bool = false
var _wander_rect: Rect2 = Rect2()
var _target: Vector2 = Vector2.ZERO
var _pause: float = 0.0

var _head: Polygon2D = null
var _figure: Node2D = null
var _base_scale: Vector2 = Vector2.ONE

# Real-art path (Run 142). When _member != "" the NPC is drawn with the
# sliced Gemini strips via an AnimatedSprite2D instead of the stick figure.
var _member: String = ""
var _sprite: AnimatedSprite2D = null
var _use_art: bool = false
var _cells: Dictionary = {}   # anim -> Vector2(cell_w, cell_h) for the current tier


func setup(fam: String, who: String, elder: bool) -> void:
	family = fam
	npc_name = who
	is_elder = elder
	_member = String((NAME_TO_MEMBER as Dictionary).get(who, ""))
	if _member != "" and FamilySprites.has_strip(_member, "idle", tier):
		_build_sprite()
	else:
		_member = ""            # no art — fall back to placeholder figure
		_build_figure()
	set_tier(tier)


func _fam_color() -> Color:
	return (RunState.FAM_COLOR as Dictionary).get(family, Color(0.7, 0.7, 0.7))


func _build_figure() -> void:
	_build_figure_only()

	var lbl := Label.new()
	lbl.name = "NameLabel"
	lbl.text = npc_name
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	lbl.add_theme_constant_override("outline_size", 3)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.position = Vector2(-45, 22)
	lbl.custom_minimum_size = Vector2(90, 0)
	add_child(lbl)


# Stick figure only (no label) — also used as the missing-tier fallback for
# art members (the art path already built its own NameLabel).
func _build_figure_only() -> void:
	_figure = Node2D.new()
	_figure.name = "Figure"
	add_child(_figure)

	var limb_col := Color(0.16, 0.15, 0.14)
	# Torso / arms / legs as chunky lines.
	for seg in [
		[Vector2(0, -17), Vector2(0, 5)],     # torso
		[Vector2(0, -12), Vector2(-9, -2)],   # left arm
		[Vector2(0, -12), Vector2(9, -2)],    # right arm
		[Vector2(0, 5),   Vector2(-7, 18)],   # left leg
		[Vector2(0, 5),   Vector2(7, 18)],    # right leg
	]:
		var l := Line2D.new()
		l.width = 3.5
		l.default_color = limb_col
		l.add_point(seg[0])
		l.add_point(seg[1])
		_figure.add_child(l)

	# Fruit/veg head — filled circle polygon.
	_head = Polygon2D.new()
	var pts := PackedVector2Array()
	for i in range(14):
		var a: float = TAU * float(i) / 14.0
		pts.append(Vector2(0, -27) + Vector2(cos(a), sin(a)) * 10.0)
	_head.polygon = pts
	_head.color = _fam_color()
	_figure.add_child(_head)

	# Simple face: two eyes.
	for ex in [-3.5, 3.5]:
		var eye := ColorRect.new()
		eye.offset_left = ex - 1.2
		eye.offset_right = ex + 1.2
		eye.offset_top = -29.5
		eye.offset_bottom = -27.0
		eye.color = Color(0.05, 0.05, 0.05)
		_figure.add_child(eye)

	if is_elder:
		_base_scale = Vector2(1.15, 1.15)
	_figure.scale = _base_scale


# ------------------------------------------------------------
# Real-art path — sliced Gemini strips via AnimatedSprite2D
# ------------------------------------------------------------
func _build_sprite() -> void:
	_use_art = true
	_sprite = AnimatedSprite2D.new()
	_sprite.name = "Sprite"
	_sprite.centered = false
	# Feet sit where the stick figure's feet were (y = +18); the per-tier
	# offset is finished in _rebuild_frames (cell sizes differ per tier).
	_sprite.position = Vector2(0, 18)
	add_child(_sprite)

	# NameLabel — identical geometry to the placeholder figure's.
	var lbl := Label.new()
	lbl.name = "NameLabel"
	lbl.text = npc_name
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	lbl.add_theme_constant_override("outline_size", 3)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.position = Vector2(-45, 22)
	lbl.custom_minimum_size = Vector2(90, 0)
	add_child(lbl)


# (Re)build the SpriteFrames for the current tier. Cell sizes change per
# tier, so the bottom-center offset is recomputed here every time.
func _rebuild_frames() -> void:
	if _sprite == null:
		return
	# Some families are missing tiers (e.g. Broccoli has no Restored sheet
	# yet) — fall back to the placeholder figure for that tier and come back
	# to the art when a tier with strips is set again.
	if not FamilySprites.has_strip(_member, "idle", tier):
		_sprite.visible = false
		if _figure == null:
			_build_figure_only()
		_figure.visible = true
		_apply_figure_tier()
		return
	_sprite.visible = true
	if _figure != null:
		_figure.visible = false
	var sf := SpriteFrames.new()
	sf.remove_animation("default")

	var anims: Array = ["idle"]           # idle always exists for art members
	if FamilySprites.has_strip(_member, "walk", tier):
		anims.append("walk")              # elders have idle only (never wander)

	_cells.clear()
	for anim in anims:
		var sname: String = FamilySprites.strip_name(_member, anim, tier)
		var rec: Array = (FamilySprites.DB as Dictionary)[sname]
		var frames: int = int(rec[0])
		var cw: int = int(rec[1])
		var ch: int = int(rec[2])
		var tex: Texture2D = load(FamilySprites.DIR + sname + ".png")
		sf.add_animation(anim)
		sf.set_animation_loop(anim, true)
		sf.set_animation_speed(anim, 8.0 if anim == "walk" else 5.0)
		for f in range(frames):
			var at := AtlasTexture.new()
			at.atlas = tex
			at.region = Rect2(f * cw, 0, cw, ch)
			sf.add_frame(anim, at)
		_cells[anim] = Vector2(float(cw), float(ch))

	_sprite.sprite_frames = sf

	# Scale from the member's RIPE idle content height so tier sag/growth
	# reads on screen (fallback to this tier's idle if ripe is missing).
	var ripe_name: String = FamilySprites.strip_name(_member, "idle", 2)
	var content_h: float
	if (FamilySprites.DB as Dictionary).has(ripe_name):
		content_h = float((FamilySprites.DB as Dictionary)[ripe_name][3])
	else:
		var cur: String = FamilySprites.strip_name(_member, "idle", tier)
		content_h = float((FamilySprites.DB as Dictionary)[cur][3])
	var target: float = float((FamilySprites.TARGET_H as Dictionary).get(_member, 56))
	var s: float = target / maxf(content_h, 1.0)
	_sprite.scale = Vector2(s, s)
	# Bottom-center align within the playing anim's cell (feet at sprite.position).
	if _sprite.animation != "walk" or not sf.has_animation("walk"):
		_sprite.play("idle")
	_apply_offset(String(_sprite.animation))


# Cell sizes differ between idle and walk strips — re-anchor bottom-center
# whenever the animation changes so the feet never slide.
func _apply_offset(anim: String) -> void:
	if _sprite == null or not _cells.has(anim):
		return
	var c: Vector2 = _cells[anim]
	_sprite.offset = Vector2(-c.x / 2.0, -c.y)


# Swap walk/idle for the strolling members (art path only).
func _set_moving(moving: bool, dx: float = 0.0) -> void:
	if not _use_art or _sprite == null or _sprite.sprite_frames == null:
		return
	var has_walk: bool = _sprite.sprite_frames.has_animation("walk")
	if moving and has_walk:
		_sprite.flip_h = dx < 0.0          # strips face RIGHT; flip when moving left
		if _sprite.animation != "walk":
			_sprite.play("walk")
			_apply_offset("walk")
	else:
		if not moving and not (_member in PROFILE_IDLE):
			_sprite.flip_h = false          # never flip the front-facing idle
		if _sprite.animation != "idle":
			_sprite.play("idle")
			_apply_offset("idle")


func set_tier(t: int) -> void:
	tier = clampi(t, 0, 3)
	if _use_art:
		# Real art already encodes each tier's state — no tint/rotation/scale.
		_rebuild_frames()
		return
	_apply_figure_tier()


# Placeholder-figure tier tinting (also the missing-tier fallback visual).
func _apply_figure_tier() -> void:
	if _figure == null or _head == null:
		return
	var fam_col: Color = _fam_color()
	match tier:
		0:   # Rotten — moldy, slumped.
			_head.color = fam_col.darkened(0.45).lerp(Color(0.35, 0.40, 0.28), 0.45)
			_figure.modulate = Color(0.62, 0.66, 0.58)
			_figure.rotation = 0.14
			_figure.scale = _base_scale * Vector2(1.0, 0.92)
		1:   # Wilted — pale but upright.
			_head.color = fam_col.lerp(Color(0.82, 0.82, 0.78), 0.45)
			_figure.modulate = Color(0.85, 0.85, 0.82)
			_figure.rotation = 0.05
			_figure.scale = _base_scale
		2:   # Ripe — full color.
			_head.color = fam_col
			_figure.modulate = Color(1, 1, 1)
			_figure.rotation = 0.0
			_figure.scale = _base_scale
		3:   # Restored — human again (placeholder skin tone; real art later).
			_head.color = SKIN
			_figure.modulate = Color(1, 1, 1)
			_figure.rotation = 0.0
			_figure.scale = _base_scale


func enable_wander(rect: Rect2) -> void:
	if is_elder:
		return   # design lock: the elder never leaves the drop-off spot
	if _use_art and not FamilySprites.has_strip(_member, "walk", 2):
		return   # no walk art at all (e.g. Roman mid-workout) — stays put, still talkable
	_wander = true
	_wander_rect = rect
	_target = position
	_pause = randf_range(0.5, 2.0)


# Freeze the stroll for a beat (e.g. while a hero is chatting with them).
func hold_still(sec: float) -> void:
	_pause = maxf(_pause, sec)


func _process(delta: float) -> void:
	if not _wander:
		return   # elders / un-enabled members hold their idle animation
	if _pause > 0.0:
		_pause -= delta
		_set_moving(false)
		return
	var to_go: Vector2 = _target - position
	if to_go.length() < 4.0:
		_target = Vector2(
			randf_range(_wander_rect.position.x, _wander_rect.end.x),
			randf_range(_wander_rect.position.y, _wander_rect.end.y))
		_pause = randf_range(1.5, 4.5)
		_set_moving(false)
		return
	position += to_go.normalized() * WALK_SPEED * delta
	_set_moving(true, to_go.x)
