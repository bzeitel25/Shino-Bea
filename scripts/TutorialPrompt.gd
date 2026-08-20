extends CanvasLayer
class_name TutorialPrompt

# ============================================================
# TutorialPrompt.gd — on-screen tutorial popup
# Run 141 original • Run 158 REBUILT (auto-sizing + live glyphs)
# ============================================================
# WHAT CHANGED IN RUN 158 (Bruno: "some tutorial popups have text that
# overlaps other text — make the windows big enough per room, no overlap"):
#
#   THE BUG. The old layout was hand-positioned pixels inside a FIXED
#   640x200 ColorRect:
#       title  at y=14,  height 36
#       body   at y=58,  height 80
#       hint   at y=142, height 30
#       dismiss at y=172
#   Every label had fit_content = true, so each one GREW to fit its text —
#   but the label BELOW it stayed pinned at its hardcoded y. Any body longer
#   than ~4 lines simply drew straight through the hint and the dismiss line,
#   and anything past 200px spilled out the bottom of the panel entirely.
#   Room 4's "Controls Refresher" (6 lines) and the boon popup (9 lines) were
#   the worst offenders — exactly the ones Bruno saw.
#
#   THE FIX. Everything is now a PanelContainer > VBoxContainer. Godot clamps
#   a Control's size up to its combined minimum size, so the panel GROWS to
#   whatever its contents need and the VBox guarantees each row starts below
#   the previous one. Overlap is now structurally impossible — there are no
#   hardcoded y positions left. Modal prompts are centre-anchored and grow in
#   both directions, so a long one can never run off the top or bottom.
#
# ── Live input glyphs (Run 158) ──────────────────────────────
# Copy is written with {tokens}, never hardcoded keys:
#
#   TP.show_prompt(self, "Dash", "Press {dash} to dodge!", "{dash} — Dash")
#
# InputGlyphs renders {dash} as "Space" on keyboard and "B" on a pad, and
# re-renders EVERY live prompt the instant the player switches device.
#
# ── Usage ────────────────────────────────────────────────────
#   var tp := TutorialPrompt.show_prompt(self, "Movement",
#       "Use {move} to move around.", "{move} — Move")
#   tp.finished.connect(func(): print("dismissed"))
#
#   var tp := TutorialPrompt.show_objective(self, "Defeat the enemy!",
#       "{attack_y} — Punch combo")
#   tp.update_objective("Enemies defeated: 1/1")
#   tp.dismiss()
# ============================================================

signal finished

# ── Layout constants (single place to retune every popup) ────
const MODAL_WIDTH: float      = 660.0
const OBJECTIVE_WIDTH: float  = 620.0
const OBJECTIVE_TOP: float    = 14.0
const PAD_H: float            = 22.0   # panel inner margin, left/right
const PAD_V: float            = 16.0   # panel inner margin, top/bottom
const ROW_GAP: int            = 10     # vertical gap between rows

const FONT_TITLE: int     = 22
const FONT_BODY: int      = 16
const FONT_HINT: int      = 17
const FONT_DISMISS: int   = 13
const FONT_OBJ_TITLE: int = 18
const FONT_OBJ_HINT: int  = 14

const COL_TITLE: Color   = Color(1.00, 0.88, 0.35)
const COL_BODY: Color    = Color(0.94, 0.93, 0.90)
const COL_HINT: Color    = Color(0.60, 0.85, 1.00)
const COL_DISMISS: Color = Color(0.68, 0.65, 0.58)
const COL_BORDER: Color  = Color(0.85, 0.72, 0.35, 0.95)
const COL_PANEL_BG: Color      = Color(0.05, 0.04, 0.10, 0.94)
const COL_PANEL_BG_OBJ: Color  = Color(0.05, 0.04, 0.10, 0.82)

var _panel: PanelContainer = null
var _vbox: VBoxContainer = null
var _title_lbl: RichTextLabel = null
var _body_lbl: RichTextLabel = null
var _hint_lbl: RichTextLabel = null
var _dismiss_lbl: RichTextLabel = null

var _dismissable: bool = true
var _cooldown: float = 0.4   # swallow inputs briefly after appearing
var _dismissed: bool = false


# ── Legacy static badge helpers ──────────────────────────────
# Kept so any straggler call site still compiles. NEW COPY SHOULD USE {tokens}
# instead — a literal badge cannot follow the player's device.

## Keyboard key badge — dark blue bg, light blue text
static func kb(key: String) -> String:
	return "[bgcolor=#2a2a48][color=#b0d0ff] %s [/color][/bgcolor]" % key

## Gamepad button badge — dark green bg, green text
static func pad(btn: String) -> String:
	return "[bgcolor=#1a3a1a][color=#7ce87c] %s [/color][/bgcolor]" % btn

## Legacy "show both devices" helper. Run 158: we no longer show both at once —
## returns whichever half matches the live device. Prefer {tokens}.
static func keys(keyboard: String, gamepad: String) -> String:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree != null:
		var ig: Node = tree.root.get_node_or_null("InputGlyphs")
		if ig != null and bool(ig.get("gamepad")):
			return pad(gamepad)
	return kb(keyboard)

## Section label — dimmer, smaller
static func label_text(txt: String) -> String:
	return "[color=#888888]%s[/color]" % txt


# ── Entry points ─────────────────────────────────────────────

static func show_prompt(host: Node, title: String, body: String, hint: String = "", dismissable: bool = true) -> CanvasLayer:
	var tp: CanvasLayer = load("res://scripts/TutorialPrompt.gd").new()
	tp.layer = 65
	tp.process_mode = Node.PROCESS_MODE_ALWAYS
	tp._dismissable = dismissable
	host.add_child(tp)
	tp._build_ui(title, body, hint, dismissable)
	if dismissable:
		tp._pause_tree()
	return tp


static func show_objective(host: Node, title: String, hint: String = "") -> CanvasLayer:
	var tp: CanvasLayer = load("res://scripts/TutorialPrompt.gd").new()
	tp.layer = 65
	tp.process_mode = Node.PROCESS_MODE_ALWAYS
	tp._dismissable = false
	host.add_child(tp)
	tp._build_objective_ui(title, hint)
	return tp


func _pause_tree() -> void:
	get_tree().paused = true


# ── Shared builders ──────────────────────────────────────────

func _make_panel(width: float, bg: Color, centered: bool) -> PanelContainer:
	var p := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = COL_BORDER
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.content_margin_left = PAD_H
	style.content_margin_right = PAD_H
	style.content_margin_top = PAD_V
	style.content_margin_bottom = PAD_V
	p.add_theme_stylebox_override("panel", style)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE

	p.anchor_left = 0.5
	p.anchor_right = 0.5
	p.offset_left = -width * 0.5
	p.offset_right = width * 0.5
	if centered:
		# Modal: pinned to screen centre, growing equally up and down. However
		# tall the copy gets, it stays on screen — no clipping, no overflow.
		p.anchor_top = 0.5
		p.anchor_bottom = 0.5
		p.grow_vertical = Control.GROW_DIRECTION_BOTH
	else:
		# Objective strip: pinned near the top, growing downward only.
		p.anchor_top = 0.0
		p.anchor_bottom = 0.0
		p.offset_top = OBJECTIVE_TOP
		p.grow_vertical = Control.GROW_DIRECTION_END
	p.grow_horizontal = Control.GROW_DIRECTION_BOTH
	p.modulate.a = 0.0
	return p


## Every text row goes through here, so no row can ever be built without
## autowrap + fit_content — the two properties that make overlap impossible.
func _make_row(template: String, font_size: int, col: Color, centered: bool) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true          # grow to fit — the VBox absorbs the growth
	r.scroll_active = false
	r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.add_theme_font_size_override("normal_font_size", font_size)
	r.add_theme_font_size_override("bold_font_size", font_size)
	r.add_theme_color_override("default_color", col)
	var txt: String = ("[center]%s[/center]" % template) if centered else template
	# bind_rich renders the {tokens} now AND re-renders on every device switch.
	InputGlyphs.bind_rich(r, txt)
	return r


func _build_ui(title: String, body: String, hint: String, dismissable: bool) -> void:
	# Run 164c — apply the "Ink & Washi" skin to everything built below.
	UISkin.skin_tree_deferred(self)
	_panel = _make_panel(MODAL_WIDTH, COL_PANEL_BG, true)
	add_child(_panel)

	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", ROW_GAP)
	_panel.add_child(_vbox)

	if title != "":
		_title_lbl = _make_row(title, FONT_TITLE, COL_TITLE, true)
		_vbox.add_child(_title_lbl)

	if body != "":
		_body_lbl = _make_row(body, FONT_BODY, COL_BODY, false)
		_vbox.add_child(_body_lbl)

	if hint != "":
		_hint_lbl = _make_row(hint, FONT_HINT, COL_HINT, true)
		_vbox.add_child(_hint_lbl)

	if dismissable:
		_dismiss_lbl = _make_row("Press {interact} to continue", FONT_DISMISS, COL_DISMISS, true)
		_vbox.add_child(_dismiss_lbl)

	var tw := create_tween()
	tw.tween_property(_panel, "modulate:a", 1.0, 0.3)


func _build_objective_ui(title: String, hint: String) -> void:
	# Run 164c — apply the "Ink & Washi" skin to everything built below.
	UISkin.skin_tree_deferred(self)
	_panel = _make_panel(OBJECTIVE_WIDTH, COL_PANEL_BG_OBJ, false)
	add_child(_panel)

	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 4)
	_panel.add_child(_vbox)

	_title_lbl = _make_row(title, FONT_OBJ_TITLE, COL_TITLE, true)
	_vbox.add_child(_title_lbl)

	if hint != "":
		_hint_lbl = _make_row(hint, FONT_OBJ_HINT, COL_HINT, true)
		_vbox.add_child(_hint_lbl)

	var tw := create_tween()
	tw.tween_property(_panel, "modulate:a", 1.0, 0.25)


# ── Live updates ─────────────────────────────────────────────

func update_title(new_title: String) -> void:
	if _title_lbl and is_instance_valid(_title_lbl):
		InputGlyphs.update_binding(_title_lbl, "[center]%s[/center]" % new_title)


## Documented in the header since Run 141 but never actually implemented —
## objective trackers ("Enemies defeated: 1/3") route here.
func update_objective(new_text: String) -> void:
	update_title(new_text)


func update_hint(new_hint: String) -> void:
	if _hint_lbl and is_instance_valid(_hint_lbl):
		InputGlyphs.update_binding(_hint_lbl, "[center]%s[/center]" % new_hint)
	elif _vbox and is_instance_valid(_vbox):
		_hint_lbl = _make_row(new_hint, FONT_OBJ_HINT, COL_HINT, true)
		_vbox.add_child(_hint_lbl)


func dismiss() -> void:
	if _dismissed:
		return
	_dismissed = true
	if _panel and is_instance_valid(_panel):
		var tw := create_tween()
		tw.tween_property(_panel, "modulate:a", 0.0, 0.2)
		tw.tween_callback(_finish_dismiss)
	else:
		_finish_dismiss()


func _finish_dismiss() -> void:
	if get_tree() != null and get_tree().paused and _dismissable:
		get_tree().paused = false
	finished.emit()
	queue_free()


func _process(delta: float) -> void:
	if _dismissed:
		return
	if _cooldown > 0.0:
		_cooldown -= delta
		return
	if not _dismissable:
		return
	if Input.is_action_just_pressed("interact") or Input.is_action_just_pressed("ui_accept") \
	or Input.is_action_just_pressed("ui_cancel"):
		dismiss()
