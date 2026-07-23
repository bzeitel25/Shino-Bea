extends CanvasLayer
class_name TutorialPrompt

# ============================================================
# TutorialPrompt.gd — on-screen tutorial popup (Run 141)
# ============================================================
# Reusable UI for showing tutorial instructions during the intro
# dream sequence. Supports:
#   - Title + body text (auto-wrapped)
#   - Optional control-hint icons (keyboard/gamepad labels)
#   - Fade in / out with tween
#   - Objective tracker line (e.g. "Defeat enemies: 1/3")
#   - Dismissable by pressing Interact (E / RB) or ui_accept (Enter / A)
#
# Usage:
#   var tp := TutorialPrompt.show_prompt(self, "Movement",
#       "Use WASD or Left Stick to move around.",
#       "[WASD / Left Stick]")
#   tp.finished.connect(func(): print("dismissed"))
#
# Or for non-dismissable objective prompts:
#   var tp := TutorialPrompt.show_objective(self, "Defeat the enemy!",
#       "[Y] to punch combo")
#   tp.update_objective("Enemies defeated: 1/1")
#   tp.dismiss()
# ============================================================

signal finished

var _panel: ColorRect = null
var _title_lbl: RichTextLabel = null
var _body_lbl: RichTextLabel = null
var _hint_lbl: RichTextLabel = null
var _objective_lbl: Label = null
var _dismiss_lbl: RichTextLabel = null

var _dismissable: bool = true
var _cooldown: float = 0.4   # swallow inputs briefly after appearing
var _dismissed: bool = false


# ── Button badge helpers (BBCode) ────────────────────────────
# Use these in hint/body strings to render styled key/button badges.

## Keyboard key badge — dark blue bg, light blue text
static func kb(key: String) -> String:
	return "[bgcolor=#2a2a48][color=#b0d0ff] %s [/color][/bgcolor]" % key

## Gamepad button badge — dark green bg, green text
static func pad(btn: String) -> String:
	return "[bgcolor=#1a3a1a][color=#7ce87c] %s [/color][/bgcolor]" % btn

## Combined keyboard + gamepad badge:  [Space]  [B]
static func keys(keyboard: String, gamepad: String) -> String:
	return kb(keyboard) + "  " + pad(gamepad)

## Section label — dimmer, smaller
static func label_text(txt: String) -> String:
	return "[color=#888888]%s[/color]" % txt


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


func _build_ui(title: String, body: String, hint: String, dismissable: bool) -> void:
	# Semi-transparent backdrop panel, centered upper portion of screen
	_panel = ColorRect.new()
	_panel.color = Color(0.05, 0.04, 0.10, 0.88)
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 0.0
	_panel.anchor_bottom = 0.0
	_panel.offset_left = -320.0
	_panel.offset_right = 320.0
	_panel.offset_top = 60.0
	_panel.offset_bottom = 260.0
	_panel.modulate.a = 0.0
	add_child(_panel)

	# Gold border
	var border := ColorRect.new()
	border.color = Color(0.85, 0.72, 0.35, 0.9)
	border.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	border.offset_top = -2.0
	border.offset_bottom = 2.0
	border.offset_left = -2.0
	border.offset_right = 2.0
	border.show_behind_parent = true
	_panel.add_child(border)

	# Title (RichTextLabel so BBCode key badges render)
	_title_lbl = RichTextLabel.new()
	_title_lbl.bbcode_enabled = true
	_title_lbl.fit_content = true
	_title_lbl.scroll_active = false
	_title_lbl.add_theme_font_size_override("normal_font_size", 22)
	_title_lbl.add_theme_color_override("default_color", Color(1.0, 0.88, 0.35))
	_title_lbl.position = Vector2(20, 14)
	_title_lbl.size = Vector2(600, 36)
	_title_lbl.text = "[center]" + title + "[/center]"
	_panel.add_child(_title_lbl)

	# Body text (RichTextLabel for BBCode button badges)
	_body_lbl = RichTextLabel.new()
	_body_lbl.bbcode_enabled = true
	_body_lbl.fit_content = true
	_body_lbl.scroll_active = false
	_body_lbl.add_theme_font_size_override("normal_font_size", 15)
	_body_lbl.add_theme_color_override("default_color", Color(0.94, 0.93, 0.90))
	_body_lbl.position = Vector2(24, 58)
	_body_lbl.size = Vector2(592, 80)
	_body_lbl.text = body
	_panel.add_child(_body_lbl)

	# Control hint (RichTextLabel for BBCode badges)
	if hint != "":
		_hint_lbl = RichTextLabel.new()
		_hint_lbl.bbcode_enabled = true
		_hint_lbl.fit_content = true
		_hint_lbl.scroll_active = false
		_hint_lbl.add_theme_font_size_override("normal_font_size", 17)
		_hint_lbl.add_theme_color_override("default_color", Color(0.6, 0.85, 1.0))
		_hint_lbl.position = Vector2(20, 142)
		_hint_lbl.size = Vector2(600, 30)
		_hint_lbl.text = hint
		_panel.add_child(_hint_lbl)

	# Dismiss instruction (RichTextLabel for BBCode badges)
	if dismissable:
		_dismiss_lbl = RichTextLabel.new()
		_dismiss_lbl.bbcode_enabled = true
		_dismiss_lbl.fit_content = true
		_dismiss_lbl.scroll_active = false
		_dismiss_lbl.add_theme_font_size_override("normal_font_size", 13)
		_dismiss_lbl.add_theme_color_override("default_color", Color(0.65, 0.62, 0.55))
		_dismiss_lbl.position = Vector2(20, 172)
		_dismiss_lbl.size = Vector2(600, 30)
		_dismiss_lbl.text = "[center]Press " + TutorialPrompt.kb("E") + "  " + TutorialPrompt.pad("RB") + " to continue[/center]"
		_panel.add_child(_dismiss_lbl)

	# Fade in
	var tw := create_tween()
	tw.tween_property(_panel, "modulate:a", 1.0, 0.3)


func _build_objective_ui(title: String, hint: String) -> void:
	# Smaller strip at top of screen for persistent objectives
	_panel = ColorRect.new()
	_panel.color = Color(0.05, 0.04, 0.10, 0.78)
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 0.0
	_panel.anchor_bottom = 0.0
	_panel.offset_left = -280.0
	_panel.offset_right = 280.0
	_panel.offset_top = 14.0
	_panel.offset_bottom = 80.0
	_panel.modulate.a = 0.0
	add_child(_panel)

	_title_lbl = RichTextLabel.new()
	_title_lbl.bbcode_enabled = true
	_title_lbl.fit_content = true
	_title_lbl.scroll_active = false
	_title_lbl.add_theme_font_size_override("normal_font_size", 17)
	_title_lbl.add_theme_color_override("default_color", Color(1.0, 0.88, 0.35))
	_title_lbl.position = Vector2(10, 8)
	_title_lbl.size = Vector2(540, 26)
	_title_lbl.text = "[center]" + title + "[/center]"
	_panel.add_child(_title_lbl)

	if hint != "":
		_hint_lbl = RichTextLabel.new()
		_hint_lbl.bbcode_enabled = true
		_hint_lbl.fit_content = true
		_hint_lbl.scroll_active = false
		_hint_lbl.add_theme_font_size_override("normal_font_size", 14)
		_hint_lbl.add_theme_color_override("default_color", Color(0.6, 0.85, 1.0))
		_hint_lbl.position = Vector2(10, 34)
		_hint_lbl.size = Vector2(540, 22)
		_hint_lbl.text = hint
		_panel.add_child(_hint_lbl)

	var tw := create_tween()
	tw.tween_property(_panel, "modulate:a", 1.0, 0.25)


func update_title(new_title: String) -> void:
	if _title_lbl:
		_title_lbl.text = "[center]" + new_title + "[/center]"


func update_hint(new_hint: String) -> void:
	if _hint_lbl:
		_hint_lbl.text = new_hint
	elif _panel:
		_hint_lbl = RichTextLabel.new()
		_hint_lbl.bbcode_enabled = true
		_hint_lbl.fit_content = true
		_hint_lbl.scroll_active = false
		_hint_lbl.add_theme_font_size_override("normal_font_size", 14)
		_hint_lbl.add_theme_color_override("default_color", Color(0.6, 0.85, 1.0))
		_hint_lbl.position = Vector2(10, 34)
		_hint_lbl.size = Vector2(540, 22)
		_hint_lbl.text = new_hint
		_panel.add_child(_hint_lbl)


func dismiss() -> void:
	if _dismissed:
		return
	_dismissed = true
	if _panel:
		var tw := create_tween()
		tw.tween_property(_panel, "modulate:a", 0.0, 0.2)
		tw.tween_callback(func():
			if get_tree().paused and _dismissable:
				get_tree().paused = false
			finished.emit()
			queue_free()
		)
	else:
		if get_tree().paused and _dismissable:
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
	# Check for dismiss input
	if Input.is_action_just_pressed("interact") or Input.is_action_just_pressed("ui_accept"):
		dismiss()
