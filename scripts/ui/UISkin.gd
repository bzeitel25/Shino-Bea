extends Node

# ============================================================
# UISkin.gd — Run 164 "Ink & Washi" UI skin
# ============================================================
# One place that owns the look of every menu, meter and panel in
# the game. Autoload it FIRST (before FX/Settings) so any scene
# that boots already has the theme applied to the root Window.
#
# Design language (see UI_Style_Guide.md):
#   · aged washi paper carries INFORMATION
#   · wooden ema plaques carry ACTIONS
#   · cinnabar hanko seals mark FOCUS and DANGER
#   · everything has a 1 px sumi-ink outline so it survives on
#     any biome background
#
# All art lives in res://Assets/UI/ and was authored at 1x, then
# exported at 2x (TEXEL 2, matching the sprite/tileset rule from
# Run 50). That means 9-slice margins here are DOUBLE the numbers
# in the style guide — the constants below already account for it.
#
# Nothing in this file reaches into gameplay. It only builds
# resources and decorates Control nodes.
# ============================================================

const UI_DIR:   String = "res://Assets/UI/"
const FONT_DIR: String = "res://Assets/Fonts/"

# ── Palette ─────────────────────────────────────────────────
const INK0:    Color = Color(0.05098, 0.04314, 0.03922)   # 0d0b0a — outlines
const INK1:    Color = Color(0.10980, 0.09020, 0.07843)   # 1c1714 — recesses
const INK2:    Color = Color(0.18039, 0.14902, 0.13333)   # 2e2622 — body text on paper
const WASHI_D: Color = Color(0.54118, 0.45098, 0.31373)   # 8a7350 — paper shade / dim text
const WASHI_M: Color = Color(0.76078, 0.66275, 0.49412)   # c2a97e
const WASHI_L: Color = Color(0.89020, 0.82353, 0.65882)   # e3d2a8 — default UI text on dark
const WASHI_H: Color = Color(0.95686, 0.91373, 0.80392)   # f4e9cd — bright text
const PAPER_DIM: Color = Color(0.41961, 0.35294, 0.23529)  # 6b5a3c — secondary text ON paper
const WOOD_D:  Color = Color(0.22745, 0.14118, 0.08627)   # 3a2416
const WOOD_M:  Color = Color(0.41961, 0.26667, 0.13725)   # 6b4423
const WOOD_L:  Color = Color(0.58039, 0.39216, 0.22745)   # 94643a
const BRASS:   Color = Color(0.78824, 0.63137, 0.24314)   # c9a13e
const SEAL:    Color = Color(0.78431, 0.20784, 0.16863)   # c8352b — hanko / danger

# ── Hero title colours (Run 164c) ───────────────────────────
# The game title is ONE colour per sibling — their Gi — over a plain dark ink
# shadow. Cinnabar is reserved for the seal from here on.
const SHINO_BLUE:   Color = Color(0.15686, 0.24706, 0.72157)   # 2840b8 — Shino's Gi
const BEA_PINK:     Color = Color(0.90980, 0.27451, 0.60784)   # e8469b — Bea's Gi
# Their accent hues. Available, but NOT used on the title — see style_hero_title.
const SHINO_ORANGE: Color = Color(0.94118, 0.47843, 0.11765)   # f07a1e — his sash
const BEA_TEAL:     Color = Color(0.18431, 0.69020, 0.64314)   # 2fb0a4 — her sash / Chi
const GOLD_M:  Color = Color(0.87843, 0.66667, 0.23529)   # e0aa3c
const GOLD_L:  Color = Color(1.00000, 0.85098, 0.47843)   # ffd97a — focus text

# Hero identity colours (unchanged hues — only the frames changed).
const SHINO_COL: Color = Color(0.87843, 0.66667, 0.23529)
const BEA_COL:   Color = Color(0.78431, 0.62745, 1.00000)

# ── 9-slice margins, already doubled for the 2x art ─────────
const PANEL_MARGIN:  int = 24   # panel_washi / panel_plain (12 @1x)
const PLAQUE_SIDE:   int = 20   # plaque_* left/right      (10 @1x)
const PLAQUE_TOP:    int = 20
const PLAQUE_BOTTOM: int = 16   #                          ( 8 @1x)
const METER_SIDE:    int = 12   # bar_frame left/right     ( 6 @1x)
const METER_TOP:     int = 12
const METER_BOTTOM:  int = 10   #                          ( 5 @1x)
const OFUDA_SIDE:    int = 28   # ofuda left/right         (14 @1x)
const OFUDA_TOP:     int = 28
const OFUDA_BOTTOM:  int = 36   #                          (18 @1x)

const ROD_HEIGHT: int = 18      # rod.png is 32x18 at 2x

# ── Type scale (multiples of each face's native pixel grid) ─
const SIZE_MICRO: int = 16      # Silkscreen caps — HP / CHI / COMBO
const SIZE_BODY:  int = 16      # DotGothic16 — descriptions, menu rows, numerals
const SIZE_ROW:   int = 24      # DotGothic16 — button labels, list rows
const SIZE_MENU:  int = 32      # DotGothic16 — big vertical menu plaques
const SIZE_HEAD:  int = 24      # Press Start 2P — section heads   (8 px grid)
const SIZE_TITLE: int = 32      # Press Start 2P — screen titles   (8 px grid)
const SIZE_HERO:  int = 40      # Press Start 2P — the game title  (8 px grid)

var font_body:    Font = null   # DotGothic16 — has real pixel kana/kanji
var font_micro:   Font = null   # Silkscreen   — tiny all-caps labels
var font_display: Font = null   # Press Start 2P — titles and headings ONLY

var theme: Theme = null

var _tex_cache: Dictionary = {}
var _ready_ok: bool = false


func _ready() -> void:
	_load_fonts()
	theme = build_theme()
	_ready_ok = true
	# Apply to the root Window so every scene inherits it, including
	# scenes instanced before this autoload finishes (Godot re-propagates
	# theme changes down the whole tree).
	var root: Window = get_tree().root
	if root:
		root.theme = theme


# ------------------------------------------------------------
# Assets
# ------------------------------------------------------------

func tex(name: String) -> Texture2D:
	# name is a bare file name, e.g. "panel_washi.png"
	if _tex_cache.has(name):
		return _tex_cache[name]
	var path: String = UI_DIR + name
	if not ResourceLoader.exists(path):
		push_warning("[UISkin] missing texture %s" % path)
		_tex_cache[name] = null
		return null
	var t: Texture2D = load(path) as Texture2D
	_tex_cache[name] = t
	return t


func _load_fonts() -> void:
	font_body    = _load_font("DotGothic16-Regular.woff2")
	font_micro   = _load_font("Silkscreen-Bold.woff2")
	font_display = _load_font("PressStart2P.woff2")
	# Fall back to whatever exists so a missing file never hard-fails a boot.
	if font_body == null:
		font_body = ThemeDB.fallback_font
	if font_micro == null:
		font_micro = font_body
	if font_display == null:
		font_display = font_body


func _load_font(file_name: String) -> Font:
	var path: String = FONT_DIR + file_name
	if not ResourceLoader.exists(path):
		push_warning("[UISkin] missing font %s" % path)
		return null
	var f: Font = load(path) as Font
	var ff: FontFile = f as FontFile
	if ff != null:
		# Pixel fonts must never be smoothed — this is the whole point.
		ff.antialiasing = TextServer.FONT_ANTIALIASING_NONE
		ff.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
		ff.hinting = TextServer.HINTING_NONE
		ff.force_autohinter = false
	return f


# ------------------------------------------------------------
# StyleBox factories
# ------------------------------------------------------------

func _nine(texture_name: String, ml: int, mt: int, mr: int, mb: int) -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	sb.texture = tex(texture_name)
	sb.texture_margin_left = ml
	sb.texture_margin_top = mt
	sb.texture_margin_right = mr
	sb.texture_margin_bottom = mb
	# Tile (don't stretch) the edges so the paper grain and wood grain keep
	# a constant pixel size no matter how big the panel gets.
	sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	sb.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	return sb


func panel_box(keyline: bool = true) -> StyleBoxTexture:
	var file_name: String = "panel_washi.png" if keyline else "panel_plain.png"
	var sb := _nine(file_name, PANEL_MARGIN, PANEL_MARGIN, PANEL_MARGIN, PANEL_MARGIN)
	sb.content_margin_left = 18.0
	sb.content_margin_right = 18.0
	sb.content_margin_top = 14.0
	sb.content_margin_bottom = 14.0
	return sb


func plaque_box(state: String = "idle") -> StyleBoxTexture:
	var sb := _nine("plaque_%s.png" % state, PLAQUE_SIDE, PLAQUE_TOP, PLAQUE_SIDE, PLAQUE_BOTTOM)
	sb.content_margin_left = 18.0
	sb.content_margin_right = 18.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	return sb


func meter_box() -> StyleBoxTexture:
	return _nine("bar_frame.png", METER_SIDE, METER_TOP, METER_SIDE, METER_BOTTOM)


func ofuda_box() -> StyleBoxTexture:
	var sb := _nine("ofuda.png", OFUDA_SIDE, OFUDA_TOP, OFUDA_SIDE, OFUDA_BOTTOM)
	sb.content_margin_left = 12.0
	sb.content_margin_right = 12.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 10.0
	return sb


func fill_tex(kind: String) -> Texture2D:
	# kind: hp | chi | beahp | beachi | gold | boss | break
	return tex("fill_%s.png" % kind)


## Hanko stamps. Every glyph is a real kanji picked for its dictionary meaning
## and verified present in DotGothic16's japanese subset (a missing glyph would
## render as tofu — the actual "random symbols" failure mode).
##
##   nin  忍  shinobi / endure       focus marker           ( 7 strokes)
##   ha   刃  blade / edge           boss tag               ( 3 strokes)
##   den  伝  legend, from 伝説       legendary boon         ( 6 strokes)
##   ka   華  flower / splendour     Bea                    (10 strokes)
##   shou 将  commander / general    spare — 52 px only     (10 strokes)
##   do   道  the way / path         spare — Sensei/mastery (12 strokes)
##
## ⚠ STROKE COUNT IS A SIZE CONSTRAINT. A seal drawn at 26 px carries about
## seven strokes before the pixel grid fuses them; 将 and 華 already mush there.
## ⚠ DRAW SEALS AT 52 OR 26 PX ONLY. The texture is 52 px (26 authored @2x), so
## any other size is a fractional scale and the pixel grid goes soft.
func seal_tex(kind: String = "nin") -> Texture2D:
	return tex("seal_%s.png" % kind)


# ------------------------------------------------------------
# Theme
# ------------------------------------------------------------

func build_theme() -> Theme:
	var th := Theme.new()
	th.default_font = font_body
	th.default_font_size = SIZE_BODY

	# ── Button = ema plaque ──────────────────────────────────
	var normal := plaque_box("idle")
	var focus := plaque_box("focus")
	var pressed := plaque_box("press")
	var disabled := plaque_box("disabled")
	var hover := plaque_box("focus")
	hover.modulate_color = Color(1.06, 1.04, 1.0, 1.0)

	for btn_type in ["Button", "MenuButton", "OptionButton", "LinkButton", "CheckBox", "CheckButton"]:
		th.set_stylebox("normal", btn_type, normal)
		th.set_stylebox("hover", btn_type, hover)
		th.set_stylebox("pressed", btn_type, pressed)
		th.set_stylebox("disabled", btn_type, disabled)
		th.set_stylebox("focus", btn_type, focus)
		th.set_font("font", btn_type, font_body)
		th.set_font_size("font_size", btn_type, SIZE_ROW)
		th.set_color("font_color", btn_type, WASHI_H)
		th.set_color("font_hover_color", btn_type, GOLD_L)
		th.set_color("font_focus_color", btn_type, GOLD_L)
		th.set_color("font_pressed_color", btn_type, GOLD_L)
		th.set_color("font_disabled_color", btn_type, Color(0.60, 0.57, 0.52))
		th.set_color("font_outline_color", btn_type, INK0)
		th.set_constant("outline_size", btn_type, 4)

	# ── Panels = washi ───────────────────────────────────────
	th.set_stylebox("panel", "Panel", panel_box(true))
	th.set_stylebox("panel", "PanelContainer", panel_box(true))
	th.set_stylebox("panel", "PopupPanel", panel_box(true))
	th.set_stylebox("panel", "TooltipPanel", panel_box(false))
	th.set_color("font_color", "TooltipLabel", INK2)
	th.set_font("font", "TooltipLabel", font_body)
	th.set_font_size("font_size", "TooltipLabel", SIZE_BODY)

	# ── Labels ───────────────────────────────────────────────
	th.set_font("font", "Label", font_body)
	th.set_font_size("font_size", "Label", SIZE_BODY)
	th.set_color("font_color", "Label", WASHI_L)
	th.set_color("font_outline_color", "Label", INK0)
	th.set_constant("outline_size", "Label", 0)

	th.set_font("font", "RichTextLabel", font_body)
	th.set_font_size("normal_font_size", "RichTextLabel", SIZE_BODY)
	th.set_color("default_color", "RichTextLabel", WASHI_L)

	# ── ProgressBar = framed meter ───────────────────────────
	var pb_bg := meter_box()
	var pb_fill := StyleBoxTexture.new()
	pb_fill.texture = fill_tex("gold")
	pb_fill.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	pb_fill.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	th.set_stylebox("background", "ProgressBar", pb_bg)
	th.set_stylebox("fill", "ProgressBar", pb_fill)
	th.set_font("font", "ProgressBar", font_micro)
	th.set_font_size("font_size", "ProgressBar", SIZE_MICRO)
	th.set_color("font_color", "ProgressBar", WASHI_H)

	# ── Sliders ──────────────────────────────────────────────
	th.set_stylebox("slider", "HSlider", meter_box())
	th.set_stylebox("grabber_area", "HSlider", pb_fill)
	th.set_stylebox("grabber_area_highlight", "HSlider", pb_fill)

	# ── Line edit / text ─────────────────────────────────────
	th.set_font("font", "LineEdit", font_body)
	th.set_font_size("font_size", "LineEdit", SIZE_BODY)
	th.set_color("font_color", "LineEdit", INK2)
	th.set_stylebox("normal", "LineEdit", panel_box(false))

	return th


# ------------------------------------------------------------
# Decorators — call these on existing nodes
# ------------------------------------------------------------

## Give a Button the plaque skin plus a cinnabar seal that slides in on focus.
## `seal_kind` of "" skips the seal (use for inline / secondary buttons).
## `px` of 0 means "pick it from context": 32 in a vertical menu list, 24 inline.
func skin_button(btn: Button, seal_kind: String = "nin", px: int = 0) -> void:
	if btn == null:
		return
	btn.add_theme_stylebox_override("normal", plaque_box("idle"))
	btn.add_theme_stylebox_override("hover", plaque_box("focus"))
	btn.add_theme_stylebox_override("pressed", plaque_box("press"))
	btn.add_theme_stylebox_override("disabled", plaque_box("disabled"))
	btn.add_theme_stylebox_override("focus", plaque_box("focus"))
	btn.add_theme_font_override("font", font_body)
	if not btn.has_theme_font_size_override("font_size"):
		var wanted: int = px
		if wanted <= 0:
			wanted = SIZE_MENU if btn.get_parent() is VBoxContainer else SIZE_ROW
		btn.add_theme_font_size_override("font_size", wanted)

	# Respect a deliberate colour — ConfirmPopup tints its danger button, the
	# boon cards tint by rarity. Only fill in the default when none was set.
	if not btn.has_theme_color_override("font_color"):
		btn.add_theme_color_override("font_color", WASHI_H)
	var text_col: Color = btn.get_theme_color("font_color")

	# ── FAUX BOLD, and no ink outline ────────────────────────────────────
	# DotGothic16 has no bold weight and its stems are 1-2 px. The old 4 px ink
	# outline was therefore THICKER than the letters themselves: it filled every
	# counter and welded the glyphs into one dark slab — that is what made the
	# menu hard to read, not the colour or the size.
	#
	# Outlining in the TEXT's own colour instead fattens each stroke by 1 px a
	# side, which is a real weight increase and keeps the letters separate. The
	# plaque underneath is dark wood, so no dark outline is needed for contrast.
	btn.add_theme_color_override("font_outline_color", text_col)
	btn.add_theme_constant_override("outline_size", 1)

	# Focus is already carried by the plaque swap, the gold rim and the seal —
	# three cues. Recolouring the text as well would break the faux-bold, since
	# Godot has only ONE font_outline_color for every state.
	btn.add_theme_color_override("font_focus_color", text_col)
	btn.add_theme_color_override("font_hover_color", text_col)
	btn.add_theme_color_override("font_pressed_color", text_col)

	if seal_kind == "" or btn.has_node("FocusSeal"):
		return
	var mark := TextureRect.new()
	mark.name = "FocusSeal"
	mark.texture = seal_tex(seal_kind)
	# 52 px = the texture's native size. 34 was a 0.65x scale of a 52 px pixel-art
	# stamp, which softened every stroke — see the note on seal_tex().
	mark.custom_minimum_size = Vector2(52, 52)
	mark.size = Vector2(52, 52)
	mark.stretch_mode = TextureRect.STRETCH_KEEP
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mark.visible = false
	mark.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	mark.position = Vector2(-68, -26)
	btn.add_child(mark)
	btn.focus_entered.connect(func() -> void: _seal_show(mark, true))
	btn.focus_exited.connect(func() -> void: _seal_show(mark, false))
	btn.mouse_entered.connect(func() -> void: btn.grab_focus())
	if btn.has_focus():
		_seal_show(mark, true)


func _seal_show(mark: TextureRect, on: bool) -> void:
	if not is_instance_valid(mark):
		return
	mark.visible = on
	if not on:
		return
	# Slide + fade, NOT a scale tween: scaling pixel art through fractional
	# values makes the stamp shimmer mid-animation.
	var rest_x: float = -68.0
	mark.position.x = rest_x - 10.0
	mark.modulate.a = 0.0
	var tw: Tween = mark.create_tween().set_parallel(true)
	tw.tween_property(mark, "position:x", rest_x, 0.10).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(mark, "modulate:a", 1.0, 0.08)


## Wrap `inner` in a hanging scroll: wooden rod, washi panel, wooden rod.
## Returns the outer VBoxContainer — parent that where the scroll should sit.
func make_scroll(inner: Control, panel_min_height: float = 0.0) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.name = "Scroll"
	col.add_theme_constant_override("separation", 0)

	col.add_child(_make_rod(false))

	var body := PanelContainer.new()
	body.name = "ScrollBody"
	body.add_theme_stylebox_override("panel", panel_box(true))
	if panel_min_height > 0.0:
		body.custom_minimum_size = Vector2(0, panel_min_height)
	body.add_child(inner)
	col.add_child(body)

	col.add_child(_make_rod(true))
	return col


func _make_rod(bottom: bool) -> Control:
	var holder := Control.new()
	holder.name = "RodBottom" if bottom else "RodTop"
	holder.custom_minimum_size = Vector2(0, ROD_HEIGHT)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var bar := TextureRect.new()
	bar.texture = tex("rod_bottom.png" if bottom else "rod.png")
	bar.stretch_mode = TextureRect.STRETCH_TILE
	bar.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(bar)

	for side in [-1, 1]:
		var knob := TextureRect.new()
		knob.texture = tex("rod_cap.png")
		knob.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		knob.custom_minimum_size = Vector2(14, 26)
		knob.size = Vector2(14, 26)
		knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if side < 0:
			knob.set_anchors_preset(Control.PRESET_CENTER_LEFT)
			knob.position = Vector2(-9, -13 + ROD_HEIGHT * 0.5)
		else:
			knob.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
			knob.position = Vector2(-5, -13 + ROD_HEIGHT * 0.5)
			knob.scale = Vector2(-1, 1)
			knob.pivot_offset = Vector2(7, 13)
		holder.add_child(knob)
	return holder


## Retrofit an existing ColorRect-pair meter (the HUD's original construction)
## with the wooden frame + pixel gloss, WITHOUT changing node types — so all the
## existing tween/size/colour logic in HUD.gd keeps working untouched.
##
##   bg   — the track ColorRect (kept, dimmed; gains a wooden frame behind it)
##   fill — the ColorRect HUD.gd resizes and recolours (gains a gloss overlay)
##
## The overlay is deliberately COLOURLESS: a 1 px bright top scanline, a sparse
## dither body and two dark base rows, all in alpha. That way the boss bar can
## still swap its fill colour per phase and the break bar can still flash red —
## the shading rides on top of whatever colour the ColorRect is showing.
func frame_meter(bg: ColorRect, fill: ColorRect) -> void:
	if bg == null or not is_instance_valid(bg):
		return
	if bg.has_node("MeterFrame"):
		return

	# The recess is drawn by the frame texture now — keep a touch of the old
	# tint underneath so an empty bar still reads as "this hero's bar".
	bg.color = Color(bg.color.r, bg.color.g, bg.color.b, 0.55)

	var frame := NinePatchRect.new()
	frame.name = "MeterFrame"
	frame.texture = tex("bar_frame.png")
	frame.patch_margin_left = METER_SIDE
	frame.patch_margin_top = METER_TOP
	frame.patch_margin_right = METER_SIDE
	frame.patch_margin_bottom = METER_BOTTOM
	frame.axis_stretch_horizontal = NinePatchRect.AXIS_STRETCH_MODE_TILE
	frame.axis_stretch_vertical = NinePatchRect.AXIS_STRETCH_MODE_TILE
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.show_behind_parent = true
	# Grow outward so the frame surrounds the track instead of eating it.
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.offset_left = -float(METER_SIDE)
	frame.offset_top = -float(METER_TOP)
	frame.offset_right = float(METER_SIDE)
	frame.offset_bottom = float(METER_BOTTOM)
	bg.add_child(frame)
	bg.move_child(frame, 0)

	if fill == null or not is_instance_valid(fill):
		return
	if fill.has_node("MeterGloss"):
		return
	# ColorRect can't carry a texture, so a tiled TextureRect rides on top of it
	# and inherits its size automatically via full-rect anchors.
	var gloss := TextureRect.new()
	gloss.name = "MeterGloss"
	gloss.texture = tex("fill_gloss.png")
	gloss.stretch_mode = TextureRect.STRETCH_TILE
	gloss.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gloss.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	gloss.clip_contents = true
	fill.add_child(gloss)


## One-call retrofit for MainMenu.tscn (and any scene built the same way):
## paints the scroll body, sets the three type faces and hangs the vertical
## inscriptions down the mounting margins.
func skin_main_menu(root: Control) -> void:
	if root == null or not is_instance_valid(root):
		return

	var body: PanelContainer = root.get_node_or_null("ScrollFrame/ScrollBody") as PanelContainer
	if body != null:
		var sb := panel_box(true)
		sb.content_margin_left = 46.0
		sb.content_margin_right = 46.0
		sb.content_margin_top = 30.0
		sb.content_margin_bottom = 26.0
		body.add_theme_stylebox_override("panel", sb)

	# ── Hero title: one name, one colour ─────────────────────
	# "SHINO" in his deep-blue Gi, "BEA" in her pink one, both over a plain dark
	# ink shadow. An earlier pass gave each name a contrasting accent shadow
	# (orange / teal) plus a brass ampersand — four hues across eleven characters
	# read as clutter, so it is two colours and one shadow now.
	const TITLE_ROOT: String = "ScrollFrame/ScrollBody/Content/TitleRow/"
	style_hero_title(root.get_node_or_null(TITLE_ROOT + "TitleShino") as Label, SHINO_BLUE)
	style_hero_title(root.get_node_or_null(TITLE_ROOT + "TitleBea") as Label, BEA_PINK)
	# Ampersand: sumi ink, and NO shadow. Ink over ink is one heavy blob.
	style_hero_title(root.get_node_or_null(TITLE_ROOT + "TitleAmp") as Label,
			INK2, INK1, SIZE_HERO, 0)
	# Legacy single-label title (pre-164c scenes) — keep it working.
	var title: Label = root.get_node_or_null("ScrollFrame/ScrollBody/Content/TitleLabel") as Label
	if title != null:
		style_hero_title(title, SHINO_BLUE)

	style_paper_label(root.get_node_or_null("ScrollFrame/ScrollBody/Content/SubtitleLabel") as Label,
			SIZE_BODY, PAPER_DIM)
	style_paper_label(root.get_node_or_null("ScrollFrame/ScrollBody/Content/HintLabel") as Label,
			SIZE_BODY, PAPER_DIM)

	var divider: TextureRect = root.get_node_or_null("ScrollFrame/ScrollBody/Content/Divider") as TextureRect
	if divider != null:
		divider.modulate = Color(1, 1, 1, 0.9)

	var version: Label = root.get_node_or_null("VersionLabel") as Label
	if version != null:
		version.add_theme_font_override("font", font_micro)
		version.add_theme_font_size_override("font_size", SIZE_MICRO)
		version.add_theme_color_override("font_color", Color(0.36, 0.34, 0.28))

	# Controls overlay: washi sheet, cinnabar heading, ink body.
	var sheet: Panel = root.get_node_or_null("ControlsOverlay/Panel") as Panel
	if sheet != null:
		sheet.add_theme_stylebox_override("panel", panel_box(true))
		add_rods_to(sheet)
	var overlay_title: Label = root.get_node_or_null("ControlsOverlay/Panel/OverlayTitle") as Label
	if overlay_title != null:
		overlay_title.add_theme_font_override("font", font_display)
		overlay_title.add_theme_font_size_override("font_size", SIZE_HEAD)
		overlay_title.add_theme_color_override("font_color", SEAL)
	var controls_body: Label = root.get_node_or_null("ControlsOverlay/Panel/ControlsBody") as Label
	# A touch larger than plain body text and with breathing room between rows —
	# the key-binding list is the one block on this sheet people actually read.
	style_paper_label(controls_body, 18, INK1)
	if controls_body != null:
		controls_body.add_theme_constant_override("line_spacing", 4)

	_hang_inscription(root, "InscriptionLeft", "忍\nノ\n道", Vector2(-338, -226), SEAL, 0.85)
	_hang_inscription(root, "InscriptionRight", "影\nヲ\n継\nグ\n者", Vector2(314, -206), PAPER_DIM, 0.9)

	# Everything handled above is now off-limits to the generic walker; let it
	# pick up anything else in the scene (the hint row, future nodes, etc).
	for handled in ["ScrollFrame/ScrollBody", "ScrollFrame/ScrollBody/Content/SubtitleLabel",
			"ScrollFrame/ScrollBody/Content/HintLabel", "VersionLabel",
			"ControlsOverlay/Panel", "ControlsOverlay/Panel/OverlayTitle",
			"ControlsOverlay/Panel/ControlsBody"]:
		var node: Node = root.get_node_or_null(handled)
		if node != null:
			node.set_meta(_SKIN_META, true)
	skin_tree(root)


func _hang_inscription(root: Control, node_name: String, glyphs: String,
		offset: Vector2, col: Color, alpha: float) -> void:
	if root.has_node(node_name):
		return
	var lab := Label.new()
	lab.name = node_name
	lab.text = glyphs
	lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lab.add_theme_font_override("font", font_body)
	lab.add_theme_font_size_override("font_size", SIZE_ROW)
	lab.add_theme_color_override("font_color", col)
	lab.add_theme_constant_override("line_spacing", 6)
	lab.modulate.a = alpha
	lab.set_anchors_preset(Control.PRESET_CENTER)
	lab.position = offset
	root.add_child(lab)


## One-call retrofit for HUD.tscn. Frames every meter, restyles the labels and
## drops a hanko seal next to each hero's nameplate. Safe to call twice.
func skin_hud(hud: CanvasLayer) -> void:
	if hud == null or not is_instance_valid(hud):
		return
	var meters: Array = [
		["HPSection/HPBarBG", "HPSection/HPBarBG/HPBarFill"],
		["ChiSection/ChiBarBG", "ChiSection/ChiBarBG/ChiBarFill"],
		["ComboSection/ComboBarBG", "ComboSection/ComboBarBG/ComboBarFill"],
		["BeaHPSection/BeaHPBarBG", "BeaHPSection/BeaHPBarBG/BeaHPBarFill"],
		["BeaChiSection/BeaChiBarBG", "BeaChiSection/BeaChiBarBG/BeaChiBarFill"],
		["BossBarSection/BossBarBG", "BossBarSection/BossBarBG/BossBarFill"],
	]
	for pair in meters:
		var bg: ColorRect = hud.get_node_or_null(pair[0]) as ColorRect
		var fl: ColorRect = hud.get_node_or_null(pair[1]) as ColorRect
		frame_meter(bg, fl)

	# Micro-caps for the little bar captions; display face for the numbers.
	for caption_path in ["HPSection/HPLabel", "ChiSection/ChiLabel",
			"ComboSection/ComboBarLabel", "BeaHPSection/BeaHPLabel",
			"BeaChiSection/BeaChiLabel"]:
		var cap: Label = hud.get_node_or_null(caption_path) as Label
		if cap == null:
			continue
		cap.add_theme_font_override("font", font_micro)
		cap.add_theme_font_size_override("font_size", SIZE_MICRO)
		cap.add_theme_color_override("font_outline_color", INK0)
		cap.add_theme_constant_override("outline_size", 4)

	for value_path in ["HPSection/HPValueLabel", "ChiSection/ChiValueLabel",
			"BeaHPSection/BeaHPValueLabel", "BeaChiSection/BeaChiValueLabel",
			"ComboSection/ComboCountLabel", "BossBarSection/BossValueLabel"]:
		style_value_label(hud.get_node_or_null(value_path) as Label, WASHI_H, SIZE_BODY)

	var boss_name: Label = hud.get_node_or_null("BossBarSection/BossNameLabel") as Label
	if boss_name != null:
		boss_name.add_theme_font_override("font", font_body)
		boss_name.add_theme_font_size_override("font_size", SIZE_ROW)
		boss_name.add_theme_color_override("font_color", WASHI_H)
		boss_name.add_theme_color_override("font_outline_color", INK0)
		boss_name.add_theme_constant_override("outline_size", 4)
		if not boss_name.has_node("BossSeal"):
			var stamp := TextureRect.new()
			stamp.name = "BossSeal"
			# 刃 "blade" — only 3 strokes, so it stays legible at 26 px. 26 is an
			# exact half of the 52 px texture, so the pixel grid survives.
			stamp.texture = seal_tex("ha")
			stamp.custom_minimum_size = Vector2(26, 26)
			stamp.size = Vector2(26, 26)
			stamp.position = Vector2(-34, -1)
			stamp.stretch_mode = TextureRect.STRETCH_SCALE
			stamp.mouse_filter = Control.MOUSE_FILTER_IGNORE
			boss_name.add_child(stamp)


# ------------------------------------------------------------
# skin_tree — the whole-screen retrofit
# ------------------------------------------------------------
# Every menu in this project builds its UI in code (SettingsMenu.tscn is 338
# bytes), so there are no scene files to restyle. Instead each screen calls
#
#     UISkin.skin_tree(self)
#
# once, deferred, at the end of its build step. This walks the subtree and:
#
#   · Buttons        → ema plaque in all four states (+ 忍 seal in vertical menus)
#   · Panels         → washi sheet
#   · Labels         → correct face, size snapped to the pixel grid, and the
#                      right colour for whatever they sit ON
#   · ProgressBars   → wooden meter frame
#
# It is deliberately CONSERVATIVE about colour: a Label that already carries a
# `font_color` override keeps it. That protects every deliberate colour in the
# game — boon rarity tints, hero identity colours, damage numbers, the karma
# meter — while still fixing the ones that were left on the engine default.
#
# Call it on a SCREEN ROOT, never on the world. It is idempotent.

const _SKIN_META: String = "_uiskin_done"


func skin_tree(root: Node, seal_menu_buttons: bool = true) -> void:
	if root == null or not is_instance_valid(root):
		return
	_skin_walk(root, root, seal_menu_buttons)


## Same thing, but next idle frame — use this when the caller is still building
## children (almost always the case in a `_ready`).
func skin_tree_deferred(root: Node, seal_menu_buttons: bool = true) -> void:
	if root == null or not is_instance_valid(root):
		return
	call_deferred("skin_tree", root, seal_menu_buttons)


func _skin_walk(node: Node, root: Node, seal_menu_buttons: bool) -> void:
	if node == null:
		return
	if node.has_meta("_uiskin_skip"):
		return
	if node is Control and not node.has_meta(_SKIN_META):
		node.set_meta(_SKIN_META, true)
		_skin_one(node as Control, root, seal_menu_buttons)
	for child in node.get_children():
		_skin_walk(child, root, seal_menu_buttons)


func _skin_one(ctl: Control, root: Node, seal_menu_buttons: bool) -> void:
	# ── Buttons ──────────────────────────────────────────────
	if ctl is Button:
		# Seal only vertical menu lists — in a horizontal row the marker would
		# land on top of the neighbouring button.
		# A vertical list is a menu: bigger type and a focus seal. A button in a
		# row is inline chrome: normal type, and no seal (it would land on the
		# neighbour).
		var in_menu: bool = ctl.get_parent() is VBoxContainer
		var wants_seal: bool = seal_menu_buttons and in_menu
		skin_button(ctl as Button, "nin" if wants_seal else "",
				SIZE_MENU if in_menu else SIZE_ROW)
		return
	if ctl is BaseButton:
		# CheckBox / CheckButton / TextureButton — font + colours only.
		ctl.add_theme_font_override("font", font_body)
		ctl.add_theme_color_override("font_color", WASHI_H)
		ctl.add_theme_color_override("font_focus_color", GOLD_L)
		return

	# ── Panels become washi ──────────────────────────────────
	if ctl is PanelContainer or ctl is Panel:
		ctl.add_theme_stylebox_override("panel", panel_box(true))
		return

	# ── Meters ───────────────────────────────────────────────
	if ctl is ProgressBar:
		ctl.add_theme_stylebox_override("background", meter_box())
		var pb_fill := StyleBoxTexture.new()
		pb_fill.texture = fill_tex("gold")
		pb_fill.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
		pb_fill.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
		ctl.add_theme_stylebox_override("fill", pb_fill)
		return

	# ── Text ─────────────────────────────────────────────────
	if ctl is Label:
		_skin_label(ctl as Label, root)
		return
	if ctl is RichTextLabel:
		var rtl := ctl as RichTextLabel
		rtl.add_theme_font_override("normal_font", font_body)
		var rtl_paper: bool = _sits_on_paper(rtl, root)
		if rtl.has_theme_color_override("default_color"):
			if rtl_paper:
				rtl.add_theme_color_override("default_color",
						paper_safe_color(rtl.get_theme_color("default_color")))
		else:
			rtl.add_theme_color_override("default_color", INK2 if rtl_paper else WASHI_L)
		return


func _skin_label(lab: Label, root: Node) -> void:
	# Micro all-caps captions keep Silkscreen; everything else is DotGothic16.
	var txt: String = lab.text
	var is_micro: bool = txt.length() <= 6 and txt == txt.to_upper() and txt.strip_edges() != ""
	lab.add_theme_font_override("font", font_micro if is_micro else font_body)
	# Sizes are LEFT ALONE on purpose. Snapping them to the 8 px grid would be
	# crisper, but every one of these screens sized its own boxes around the old
	# metrics — bumping 12 to 16 overflows the HUD boon rail. Crispness is a
	# per-screen tuning job, not something a blind walker should do.

	var on_paper: bool = _sits_on_paper(lab, root)
	if lab.has_theme_color_override("font_color"):
		# A deliberate colour is respected — EXCEPT when it is unreadable on the
		# washi it now sits on. Every popup in this game was coloured for the old
		# dark panels, so pale cream and pale gold headings survived the reskin
		# and became invisible. Light-on-paper is never intent; it is a leftover.
		if on_paper:
			lab.add_theme_color_override("font_color",
					paper_safe_color(lab.get_theme_color("font_color")))
			lab.add_theme_constant_override("outline_size", 0)
		return
	if on_paper:
		lab.add_theme_color_override("font_color", INK2)
		lab.add_theme_constant_override("outline_size", 0)
	else:
		lab.add_theme_color_override("font_color", WASHI_L)
		lab.add_theme_color_override("font_outline_color", INK0)
		lab.add_theme_constant_override("outline_size", 4)


## Force a colour to be readable on washi while keeping its hue.
##
## Anything already at 3:1 contrast against the paper is left exactly alone — that
## is a deliberate dark or saturated colour and it stays. A near-neutral pale tone
## (the old cream body text) collapses to plain sumi ink. A pale but SATURATED
## tone (the old gold headings) keeps its hue and sinks its value, so a gold
## heading becomes a deep amber rather than losing its identity to flat black.
func paper_safe_color(col: Color) -> Color:
	if contrast_ratio(col, WASHI_L) >= 3.0:
		return col
	if col.s < 0.20:
		return Color(INK2.r, INK2.g, INK2.b, col.a)
	# Saturated pales (the old gold headings) keep their hue and sink their value.
	# A single fixed step is not enough for yellows — yellow is intrinsically
	# bright, so #e6c76b at v=0.34 still only reaches 2.7:1. Walk the value down
	# until it actually clears the bar. Runs once per label at load.
	var out := Color.from_hsv(col.h, minf(1.0, col.s + 0.22), 0.34, col.a)
	var guard: int = 0
	while contrast_ratio(out, WASHI_L) < 3.0 and guard < 10:
		out = Color.from_hsv(col.h, out.s, maxf(0.12, out.v - 0.03), col.a)
		guard += 1
	return out


## WCAG-style ratio. Uses Color.get_luminance(), which is close enough for a
## legibility threshold on flat pixel text.
func contrast_ratio(a: Color, b: Color) -> float:
	var la: float = a.get_luminance() + 0.05
	var lb: float = b.get_luminance() + 0.05
	return maxf(la, lb) / minf(la, lb)


## True when the label has a washi panel between it and the screen root — i.e.
## it is written ON paper and therefore has to be dark ink, not cream.
func _sits_on_paper(ctl: Control, root: Node) -> bool:
	var walker: Node = ctl.get_parent()
	while walker != null and walker != root:
		if walker is PanelContainer or walker is Panel:
			return true
		walker = walker.get_parent()
	return false


## Pixel fonts only stay crisp on their own grid (8 px for Silkscreen and Press
## Start 2P, 16 for DotGothic16). Use this when you are sizing a NEW label and
## you control the box around it — never to retrofit an existing layout.
func snap_size(px: int) -> int:
	return maxi(8, int(round(float(px) / 8.0)) * 8)


## Hang wooden scroll rods above and below an absolutely-positioned Panel, so a
## plain dialog reads as a hanging scroll. Do NOT use on a PanelContainer — its
## layout would stretch the rods over the content.
func add_rods_to(panel: Control) -> void:
	if panel == null or not is_instance_valid(panel):
		return
	if panel is PanelContainer:
		# NOTE: never write a bare `name()` in a string here — gdcheck parses it
		# as a real call site and reports a bogus arity error.
		push_warning("[UISkin] scroll rods skipped: a PanelContainer lays them out as content.")
		return
	if panel.has_node("RodTop"):
		return
	for bottom in [false, true]:
		var rod := TextureRect.new()
		rod.name = "RodBottom" if bottom else "RodTop"
		rod.texture = tex("rod_bottom.png" if bottom else "rod.png")
		rod.stretch_mode = TextureRect.STRETCH_TILE
		rod.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rod.set_meta("_uiskin_skip", true)
		rod.anchor_left = 0.0
		rod.anchor_right = 1.0
		if bottom:
			rod.anchor_top = 1.0
			rod.anchor_bottom = 1.0
			rod.offset_top = 0.0
			rod.offset_bottom = float(ROD_HEIGHT)
		else:
			rod.anchor_top = 0.0
			rod.anchor_bottom = 0.0
			rod.offset_top = -float(ROD_HEIGHT)
			rod.offset_bottom = 0.0
		rod.offset_left = -4.0
		rod.offset_right = 4.0
		panel.add_child(rod)


## Hero title: glyph in the character's Gi colour over a plain dark ink shadow.
## Cinnabar is reserved for the seal — the title carries the siblings' palette.
## Pass shadow_px = 0 to drop the shadow entirely (the ampersand needs that; an
## ink glyph over an ink shadow just reads as one heavy blob).
func style_hero_title(lab: Label, glyph: Color, shade: Color = INK1,
		px: int = SIZE_HERO, shadow_px: int = 5) -> void:
	if lab == null:
		return
	lab.add_theme_font_override("font", font_display)
	lab.add_theme_font_size_override("font_size", px)
	lab.add_theme_color_override("font_color", glyph)
	lab.add_theme_color_override("font_outline_color", INK0)
	lab.add_theme_constant_override("outline_size", 4)
	lab.add_theme_color_override("font_shadow_color", shade)
	lab.add_theme_constant_override("shadow_offset_x", shadow_px)
	lab.add_theme_constant_override("shadow_offset_y", shadow_px)
	lab.add_theme_constant_override("shadow_outline_size", 0)
	# Hands off — the walker must not second-guess an explicitly styled label.
	lab.set_meta(_SKIN_META, true)


## Small washi tag (counters, nameplates). Returns a PanelContainer you fill.
func make_tag(text: String = "", value_color: Color = INK2) -> PanelContainer:
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", panel_box(false))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	if text != "":
		var cap := Label.new()
		cap.name = "Caption"
		cap.text = text
		cap.add_theme_font_override("font", font_micro)
		cap.add_theme_font_size_override("font_size", SIZE_MICRO)
		cap.add_theme_color_override("font_color", WASHI_D)
		row.add_child(cap)
	var val := Label.new()
	val.name = "Value"
	val.add_theme_font_override("font", font_display)
	val.add_theme_font_size_override("font_size", SIZE_ROW)
	val.add_theme_color_override("font_color", value_color)
	row.add_child(val)
	return box


## A brush-stroke horizontal rule.
func make_divider(width: float = 320.0) -> TextureRect:
	var line := TextureRect.new()
	line.name = "Divider"
	line.texture = tex("divider.png")
	line.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	line.custom_minimum_size = Vector2(width, 18)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line


## Micro-caps label (HP / CHI / COMBO / BREAK).
func make_micro_label(text: String, col: Color = WASHI_H) -> Label:
	var lab := Label.new()
	lab.text = text
	lab.add_theme_font_override("font", font_micro)
	lab.add_theme_font_size_override("font_size", SIZE_MICRO)
	lab.add_theme_color_override("font_color", col)
	lab.add_theme_color_override("font_outline_color", INK0)
	lab.add_theme_constant_override("outline_size", 4)
	return lab


## Numerals, ink-outlined so they read on any background.
## Deliberately DotGothic16, not the display face — Press Start 2P is a fixed
## 1 em grid, so "100 / 100" would be 144 px wide and blow out the HUD.
func style_value_label(lab: Label, col: Color = WASHI_H, px: int = SIZE_BODY) -> void:
	if lab == null:
		return
	lab.add_theme_font_override("font", font_body)
	lab.add_theme_font_size_override("font_size", px)
	lab.add_theme_color_override("font_color", col)
	lab.add_theme_color_override("font_outline_color", INK0)
	lab.add_theme_constant_override("outline_size", 4)
	lab.set_meta(_SKIN_META, true)


## Dark text for content sitting ON paper.
func style_paper_label(lab: Label, px: int = SIZE_BODY, col: Color = INK2) -> void:
	if lab == null:
		return
	lab.add_theme_font_override("font", font_body)
	lab.add_theme_font_size_override("font_size", px)
	lab.add_theme_color_override("font_color", col)
	lab.add_theme_constant_override("outline_size", 0)
	lab.set_meta(_SKIN_META, true)


## Tiling washi/noise wash for a full-screen backdrop.
func make_paper_wash(alpha: float = 0.35) -> TextureRect:
	var wash := TextureRect.new()
	wash.name = "PaperWash"
	wash.texture = tex("noise_overlay.png")
	wash.stretch_mode = TextureRect.STRETCH_TILE
	wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wash.modulate.a = alpha
	wash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return wash
