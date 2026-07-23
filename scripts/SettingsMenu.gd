extends Control
# ============================================================
# SettingsMenu.gd — reusable options panel  (Run 54)
# ============================================================
# A self-contained settings overlay built entirely in code so it can be
# dropped into the main menu AND the in-game pause menu with no duplication.
#
# Usage:
#   var menu = preload("res://scenes/SettingsMenu.tscn").instantiate()
#   add_child(menu)
#   menu.closed.connect(...)   # fired on Back / Esc
#
# Reads + writes the Settings autoload; every control applies live and the
# Settings autoload persists each change to disk.
# ============================================================

signal closed

const COLOR_GOLD: Color = Color(0.96, 0.82, 0.32, 1.0)
const COLOR_GOLD_DIM: Color = Color(0.70, 0.62, 0.35, 1.0)
const COLOR_TEXT: Color = Color(0.90, 0.90, 0.94, 1.0)
const COLOR_PANEL: Color = Color(0.08, 0.07, 0.11, 0.98)

var _settings: Node = null
var _first_control: Control = null
var _back_btn: Button = null
var _scroll: ScrollContainer = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # usable while the game is paused
	_settings = get_node_or_null("/root/Settings")

	# Fill the screen.
	anchor_right = 1.0
	anchor_bottom = 1.0
	mouse_filter = Control.MOUSE_FILTER_STOP

	# Dim backdrop.
	var dim := ColorRect.new()
	dim.anchor_right = 1.0
	dim.anchor_bottom = 1.0
	dim.color = Color(0.0, 0.0, 0.0, 0.72)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	# Centered panel. Vertical anchors fill the screen (minus a margin) so the
	# panel never runs off the bottom on shorter viewports; its inner content
	# scrolls instead. Width stays fixed and centered.
	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_top = 0.0
	panel.anchor_right = 0.5
	panel.anchor_bottom = 1.0
	panel.offset_left = -320.0
	panel.offset_top = 28.0
	panel.offset_right = 320.0
	panel.offset_bottom = -28.0
	var sb := StyleBoxFlat.new()
	sb.bg_color = COLOR_PANEL
	sb.border_color = COLOR_GOLD_DIM
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(26)
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)

	# Scrollable body — the content list is taller than the panel, so wrap it
	# in a ScrollContainer. Focus following (see _follow_focus) keeps the
	# selected control in view, so controller users never need to scroll by hand.
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.follow_focus = true
	panel.add_child(_scroll)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(vbox)

	# Title.
	var title := Label.new()
	title.text = "SETTINGS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", COLOR_GOLD)
	title.add_theme_font_size_override("font_size", 34)
	vbox.add_child(title)

	vbox.add_child(_section_label("AUDIO"))
	_add_slider(vbox, "Master Volume", _settings.master_volume if _settings else 1.0,
		0.0, 1.0, 0.05, "set_master_volume", true)
	_add_slider(vbox, "Music Volume", _settings.music_volume if _settings else 1.0,
		0.0, 1.0, 0.05, "set_music_volume", true)
	_add_slider(vbox, "SFX Volume", _settings.sfx_volume if _settings else 1.0,
		0.0, 1.0, 0.05, "set_sfx_volume", true)
	_add_check(vbox, "Pause Music When Paused",
		_settings.pause_music_with_game if _settings else false,
		"set_pause_music_with_game")

	vbox.add_child(_section_label("VIDEO"))
	_add_check(vbox, "Fullscreen",
		_settings.fullscreen if _settings else false,
		"set_fullscreen")
	_add_slider(vbox, "Brightness", _settings.brightness if _settings else 1.0,
		0.5, 1.5, 0.05, "set_brightness", false)

	vbox.add_child(_section_label("FEEL"))
	_add_check(vbox, "Screen Shake", _settings.shake_enabled if _settings else true,
		"set_shake_enabled")
	_add_slider(vbox, "Shake Intensity", _settings.shake_intensity if _settings else 1.0,
		0.0, 1.5, 0.05, "set_shake_intensity", false)

	vbox.add_child(_section_label("HUD"))
	_add_check(vbox, "Show Nameplates", _settings.nameplates_enabled if _settings else true,
		"set_nameplates_enabled")

	vbox.add_child(_section_label("GAMEPLAY"))
	_add_check(vbox, "Safety Confirmations", _settings.safety_confirmations if _settings else true,
		"set_safety_confirmations")
	_add_check(vbox, "Beginner Tips", _settings.beginner_tips if _settings else true,
		"set_beginner_tips")
	_add_check(vbox, "Combat Tips", _settings.combat_tips if _settings else true,
		"set_combat_tips")

	# Run 61 — AI Helper Tier section: 5-card row (Spectator → Beast Mode).
	# Mid-run swaps allowed; RunState tracks the per-run high-water mark
	# for the RunComplete accolade ("Highest Tier Used: ...").
	vbox.add_child(_section_label("AI HELPER TIER"))
	_add_ai_tier_row(vbox)

	# Spacer + Back button.
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 8)
	vbox.add_child(spacer)

	_back_btn = Button.new()
	_back_btn.text = "BACK"
	_back_btn.custom_minimum_size = Vector2(0, 44)
	_style_button(_back_btn)
	_back_btn.pressed.connect(_on_back)
	vbox.add_child(_back_btn)
	_register_focus(_back_btn)

	# Focus the first control for keyboard / gamepad users.
	if _first_control:
		_first_control.grab_focus()
	else:
		_back_btn.grab_focus()


func _input(event: InputEvent) -> void:
	# Esc / gamepad B closes the panel.
	if event.is_action_pressed("ui_cancel"):
		_on_back()
		get_viewport().set_input_as_handled()


func _on_back() -> void:
	emit_signal("closed")
	queue_free()


# When a control receives focus (keyboard/gamepad navigation), scroll the
# body just enough to bring it fully into view. Selection drives scrolling,
# so there's no manual scrolling needed on a controller.
func _follow_focus(ctrl: Control) -> void:
	if _scroll != null and is_instance_valid(_scroll) and is_instance_valid(ctrl):
		_scroll.ensure_control_visible(ctrl)


func _register_focus(ctrl: Control) -> void:
	ctrl.focus_entered.connect(_follow_focus.bind(ctrl))


# ---------------------------------------------------------------------------
# Row builders
# ---------------------------------------------------------------------------
func _section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", COLOR_GOLD_DIM)
	l.add_theme_font_size_override("font_size", 15)
	return l


func _add_slider(parent: Node, label_text: String, value: float,
		min_v: float, max_v: float, step: float, setter: String,
		as_percent: bool) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.custom_minimum_size = Vector2(540, 30)

	var name_lbl := Label.new()
	name_lbl.text = label_text
	name_lbl.custom_minimum_size = Vector2(180, 0)
	name_lbl.add_theme_color_override("font_color", COLOR_TEXT)
	name_lbl.add_theme_font_size_override("font_size", 17)
	row.add_child(name_lbl)

	var slider := HSlider.new()
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step = step
	slider.value = value
	slider.custom_minimum_size = Vector2(280, 24)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slider)

	var val_lbl := Label.new()
	val_lbl.custom_minimum_size = Vector2(56, 0)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val_lbl.add_theme_color_override("font_color", COLOR_GOLD)
	val_lbl.add_theme_font_size_override("font_size", 16)
	val_lbl.text = _fmt(value, as_percent)
	row.add_child(val_lbl)

	slider.value_changed.connect(func(v: float) -> void:
		val_lbl.text = _fmt(v, as_percent)
		if _settings and _settings.has_method(setter):
			_settings.call(setter, v)
	)

	parent.add_child(row)
	_register_focus(slider)
	if _first_control == null:
		_first_control = slider


func _add_check(parent: Node, label_text: String, value: bool, setter: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.custom_minimum_size = Vector2(540, 30)

	var name_lbl := Label.new()
	name_lbl.text = label_text
	name_lbl.custom_minimum_size = Vector2(180, 0)
	name_lbl.add_theme_color_override("font_color", COLOR_TEXT)
	name_lbl.add_theme_font_size_override("font_size", 17)
	row.add_child(name_lbl)

	var check := CheckButton.new()
	check.button_pressed = value
	check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	check.toggled.connect(func(on: bool) -> void:
		if _settings and _settings.has_method(setter):
			_settings.call(setter, on)
	)
	row.add_child(check)

	parent.add_child(row)
	_register_focus(check)
	if _first_control == null:
		_first_control = check


func _fmt(v: float, as_percent: bool) -> String:
	if as_percent:
		return "%d%%" % int(round(v * 100.0))
	return "%d%%" % int(round(v * 100.0))


# ---------------------------------------------------------------------------
# Button styling (matches the main-menu gold look).
# ---------------------------------------------------------------------------
func _style_button(btn: Button) -> void:
	var sb_normal := StyleBoxFlat.new()
	sb_normal.bg_color = Color(0.10, 0.09, 0.13, 0.94)
	sb_normal.set_border_width_all(2)
	sb_normal.border_color = COLOR_GOLD_DIM
	sb_normal.set_corner_radius_all(6)
	sb_normal.set_content_margin_all(10)
	var sb_hover := sb_normal.duplicate()
	sb_hover.border_color = COLOR_GOLD
	sb_hover.bg_color = Color(0.16, 0.14, 0.18, 0.96)
	var sb_focus := sb_hover.duplicate()
	sb_focus.shadow_color = Color(COLOR_GOLD.r, COLOR_GOLD.g, COLOR_GOLD.b, 0.45)
	sb_focus.shadow_size = 6
	btn.add_theme_stylebox_override("normal", sb_normal)
	btn.add_theme_stylebox_override("hover", sb_hover)
	btn.add_theme_stylebox_override("focus", sb_focus)
	btn.add_theme_stylebox_override("pressed", sb_hover)
	btn.add_theme_color_override("font_color", COLOR_GOLD)
	btn.add_theme_color_override("font_hover_color", COLOR_GOLD)
	btn.add_theme_color_override("font_focus_color", COLOR_GOLD)
	btn.add_theme_font_size_override("font_size", 22)


# ---------------------------------------------------------------------------
# Run 61 — AI Helper Tier picker. 5 cards laid out in a row, each card
# tinted by tier (cool→warm gradient). Click a card to switch tiers live.
# Description text below the row updates to the selected tier's blurb.
# ---------------------------------------------------------------------------
var _tier_cards: Array = []          # holds the 5 PanelContainers
var _tier_desc_label: Label = null

const TIER_COLORS: Array = [
	Color(0.50, 0.55, 0.70, 1.0),    # Tier 1 — cool slate (Spectator)
	Color(0.45, 0.70, 0.65, 1.0),    # Tier 2 — teal       (Sidekick)
	Color(0.96, 0.82, 0.32, 1.0),    # Tier 3 — gold       (Balanced) — default
	Color(0.95, 0.55, 0.25, 1.0),    # Tier 4 — orange     (Bruiser)
	Color(0.92, 0.30, 0.35, 1.0),    # Tier 5 — crimson    (Beast Mode)
]


func _add_ai_tier_row(parent: Node) -> void:
	var rs: Node = get_node_or_null("/root/RunState")
	var current_tier: int = 3
	if _settings and "ai_helper_tier" in _settings:
		current_tier = int(_settings.ai_helper_tier)
	elif rs and "ai_helper_tier" in rs:
		current_tier = int(rs.ai_helper_tier)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.custom_minimum_size = Vector2(560, 70)
	parent.add_child(row)

	_tier_cards.clear()
	for t in range(1, 6):
		var card := _make_tier_card(t, t == current_tier)
		row.add_child(card)
		_register_focus(card)
		_tier_cards.append(card)

	# Description line under the row.
	_tier_desc_label = Label.new()
	_tier_desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tier_desc_label.custom_minimum_size = Vector2(560, 32)
	_tier_desc_label.add_theme_color_override("font_color", COLOR_TEXT)
	_tier_desc_label.add_theme_font_size_override("font_size", 14)
	parent.add_child(_tier_desc_label)
	_update_tier_desc(current_tier)


func _make_tier_card(tier: int, selected: bool) -> Control:
	# Run 61b — card IS a Button (not Panel + overlay). Buttons receive clicks
	# reliably inside HBoxContainer; the prior Panel+child-Button approach
	# could have its child layered behind the parent's input region.
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(108, 70)
	btn.text = ""   # we draw our own labels as children
	btn.toggle_mode = false
	btn.focus_mode = Control.FOCUS_ALL
	var spec: Dictionary = {}
	var rs2: Node = get_node_or_null("/root/RunState")
	if rs2 and rs2.has_method("get_ai_tier_spec"):
		spec = rs2.get_ai_tier_spec(tier)
	btn.tooltip_text = "%s — %s" % [str(spec.get("name", "")), str(spec.get("desc", ""))]
	# Run 62 — call out the Beast Mode immortality guard on the tier-5 card.
	if tier == 5 and rs2 and rs2.has_method("beastmode_tooltip"):
		btn.tooltip_text += "\n\n" + str(rs2.beastmode_tooltip())

	_style_tier_button(btn, tier, selected)
	btn.pressed.connect(func() -> void: _on_tier_picked(tier))

	# Labels as children — laid out via a VBox stretched to the button rect.
	var col_box := VBoxContainer.new()
	col_box.anchor_right = 1.0
	col_box.anchor_bottom = 1.0
	col_box.offset_left = 4.0
	col_box.offset_right = -4.0
	col_box.offset_top = 4.0
	col_box.offset_bottom = -4.0
	col_box.alignment = BoxContainer.ALIGNMENT_CENTER
	col_box.mouse_filter = Control.MOUSE_FILTER_IGNORE   # let clicks pass to the Button
	btn.add_child(col_box)

	var col: Color = TIER_COLORS[tier - 1]
	var num := Label.new()
	num.text = "T%d" % tier
	num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	num.mouse_filter = Control.MOUSE_FILTER_IGNORE
	num.add_theme_color_override("font_color", col)
	num.add_theme_font_size_override("font_size", 22)
	col_box.add_child(num)

	var name_lbl := Label.new()
	name_lbl.text = str(spec.get("name", ""))
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_lbl.add_theme_color_override("font_color", COLOR_TEXT)
	name_lbl.add_theme_font_size_override("font_size", 11)
	col_box.add_child(name_lbl)

	return btn


func _style_tier_button(btn: Button, tier: int, selected: bool) -> void:
	var col: Color = TIER_COLORS[tier - 1]
	for state_name in ["normal", "hover", "focus", "pressed", "disabled"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.10, 0.09, 0.13, 0.94)
		sb.border_color = col if selected else col.darkened(0.45)
		var bw: int = 3 if selected else 2
		if state_name == "hover" or state_name == "focus":
			bw += 1
			sb.bg_color = Color(0.16, 0.14, 0.18, 0.96)
		sb.set_border_width_all(bw)
		sb.set_corner_radius_all(8)
		sb.set_content_margin_all(6)
		if selected:
			sb.shadow_color = Color(col.r, col.g, col.b, 0.50)
			sb.shadow_size = 6
		btn.add_theme_stylebox_override(state_name, sb)


func _on_tier_picked(tier: int) -> void:
	print("[SettingsMenu] Tier picked: %d" % tier)
	if _settings and _settings.has_method("set_ai_helper_tier"):
		_settings.set_ai_helper_tier(tier)
	else:
		var rs: Node = get_node_or_null("/root/RunState")
		if rs and rs.has_method("set_ai_helper_tier"):
			rs.set_ai_helper_tier(tier)
	# Re-style cards to reflect the new selection (cards are Buttons now).
	for i in range(_tier_cards.size()):
		var c: Button = _tier_cards[i]
		if not is_instance_valid(c):
			continue
		_style_tier_button(c, i + 1, (i + 1) == tier)
	_update_tier_desc(tier)


func _update_tier_desc(tier: int) -> void:
	if _tier_desc_label == null:
		return
	var rs: Node = get_node_or_null("/root/RunState")
	var spec: Dictionary = {}
	if rs and rs.has_method("get_ai_tier_spec"):
		spec = rs.get_ai_tier_spec(tier)
	var label: String = str(spec.get("label", ""))
	var name_s: String = str(spec.get("name", ""))
	var desc: String = str(spec.get("desc", ""))
	_tier_desc_label.text = "Tier %d — %s (%s): %s" % [tier, label, name_s, desc]
	# Run 62 — append the immortality-guard note when Beast Mode is selected.
	if tier == 5 and rs and rs.has_method("beastmode_tooltip"):
		_tier_desc_label.text += "  " + str(rs.beastmode_tooltip())
