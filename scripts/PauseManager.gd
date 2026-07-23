extends Node
# ============================================================
# PauseManager.gd — autoload singleton "PauseManager"  (Run 54)
# ============================================================
# Global in-game pause. Pressing the "pause" action (Esc / gamepad Start)
# during gameplay freezes the tree and shows a pause menu:
#   RESUME        — unpause and close
#   SETTINGS      — open the shared SettingsMenu (same panel as the main menu)
#   SAVE & EXIT   — persist the active save slot, then return to the title.
#                   (On reload the run resumes at the start of the current room.)
#
# Pause is suppressed on menu-type scenes (MainMenu, SaveFileSelect) where a
# pause overlay makes no sense.
#
# The menu lives on its own CanvasLayer with PROCESS_MODE_ALWAYS so its
# buttons keep working while the rest of the tree is paused.
# ============================================================

const SETTINGS_SCENE: String = "res://scenes/SettingsMenu.tscn"
const MAIN_MENU_SCENE: String = "res://scenes/MainMenu.tscn"

# Scene file basenames where pausing is disabled.
const NON_PAUSABLE: Array[String] = ["MainMenu", "SaveFileSelect"]

const COLOR_GOLD: Color = Color(0.96, 0.82, 0.32, 1.0)
const COLOR_GOLD_DIM: Color = Color(0.70, 0.62, 0.35, 1.0)

var _layer: CanvasLayer = null
var _panel: Control = null          # holds the pause buttons (hidden while settings open)
var _settings_menu: Control = null
var _resume_btn: Button = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("pause"):
		return
	# If the settings sub-panel is open, a pause press backs out of it
	# (Esc is normally consumed by SettingsMenu; this covers gamepad Start).
	if is_instance_valid(_settings_menu):
		_settings_menu.queue_free()
		return
	if is_open():
		_resume()
	elif _is_pausable_scene():
		_open()
	get_viewport().set_input_as_handled()


func is_open() -> bool:
	return is_instance_valid(_layer)


func _is_pausable_scene() -> bool:
	var scene := get_tree().current_scene
	if scene == null:
		return false
	var path: String = scene.scene_file_path
	if path == "":
		return true
	var base: String = path.get_file().get_basename()
	return not NON_PAUSABLE.has(base)


# ---------------------------------------------------------------------------
# Open / resume
# ---------------------------------------------------------------------------
func _open() -> void:
	get_tree().paused = true

	_layer = CanvasLayer.new()
	_layer.layer = 100
	_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().root.add_child(_layer)

	# Root control fills the screen + dim backdrop.
	_panel = Control.new()
	_panel.anchor_right = 1.0
	_panel.anchor_bottom = 1.0
	_panel.process_mode = Node.PROCESS_MODE_ALWAYS
	_layer.add_child(_panel)

	var dim := ColorRect.new()
	dim.anchor_right = 1.0
	dim.anchor_bottom = 1.0
	dim.color = Color(0.0, 0.0, 0.0, 0.6)
	_panel.add_child(dim)

	var box := VBoxContainer.new()
	box.anchor_left = 0.5
	box.anchor_top = 0.5
	box.anchor_right = 0.5
	box.anchor_bottom = 0.5
	box.offset_left = -160.0
	box.offset_top = -150.0
	box.offset_right = 160.0
	box.offset_bottom = 150.0
	box.add_theme_constant_override("separation", 16)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	_panel.add_child(box)

	var title := Label.new()
	title.text = "PAUSED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", COLOR_GOLD)
	title.add_theme_font_size_override("font_size", 44)
	box.add_child(title)

	# Run 61 — AI Helper Tier indicator: small line showing current tier and
	# the run high-water mark. Updates whenever the player Esc's into the menu.
	var ai_lbl := Label.new()
	ai_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ai_lbl.add_theme_color_override("font_color", COLOR_GOLD_DIM)
	ai_lbl.add_theme_font_size_override("font_size", 14)
	var rs: Node = get_node_or_null("/root/RunState")
	if rs and "ai_helper_tier" in rs:
		var t: int = int(rs.ai_helper_tier)
		var hi: int = int(rs.highest_ai_tier_used_this_run) if "highest_ai_tier_used_this_run" in rs else t
		var spec_now: Dictionary = rs.get_ai_tier_spec(t) if rs.has_method("get_ai_tier_spec") else {}
		var spec_hi: Dictionary  = rs.get_ai_tier_spec(hi) if rs.has_method("get_ai_tier_spec") else {}
		ai_lbl.text = "AI Helper — Tier %d (%s)    |    Run high-water: Tier %d (%s)" % [
			t, str(spec_now.get("name", "")), hi, str(spec_hi.get("name", "")),
		]
	else:
		ai_lbl.text = ""
	box.add_child(ai_lbl)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 10)
	box.add_child(spacer)

	_resume_btn = _make_button("RESUME", _resume)
	box.add_child(_resume_btn)
	box.add_child(_make_button("SETTINGS", _open_settings))
	box.add_child(_make_button("SAVE & EXIT", _save_and_exit))

	_resume_btn.grab_focus()


func _resume() -> void:
	if is_instance_valid(_settings_menu):
		_settings_menu.queue_free()
		_settings_menu = null
	if is_instance_valid(_layer):
		_layer.queue_free()
	_layer = null
	_panel = null
	get_tree().paused = false


# ---------------------------------------------------------------------------
# Settings sub-panel
# ---------------------------------------------------------------------------
func _open_settings() -> void:
	if not ResourceLoader.exists(SETTINGS_SCENE):
		push_error("[PauseManager] SettingsMenu scene missing.")
		return
	if _panel:
		_panel.visible = false   # hide pause buttons behind the settings panel
	_settings_menu = load(SETTINGS_SCENE).instantiate()
	_layer.add_child(_settings_menu)
	if _settings_menu.has_signal("closed"):
		_settings_menu.closed.connect(_on_settings_closed)
	# Also catch a queue_free that didn't go through the closed signal.
	_settings_menu.tree_exited.connect(_on_settings_tree_exited)


func _on_settings_closed() -> void:
	_settings_menu = null
	if is_instance_valid(_panel):
		_panel.visible = true
		if _resume_btn:
			_resume_btn.grab_focus()


func _on_settings_tree_exited() -> void:
	# Safety net: if the panel left the tree without emitting closed, restore.
	_settings_menu = null
	if is_instance_valid(_panel):
		_panel.visible = true
		if is_instance_valid(_resume_btn):
			_resume_btn.grab_focus()


# ---------------------------------------------------------------------------
# Save & exit
# ---------------------------------------------------------------------------
func _save_and_exit() -> void:
	var sm := get_node_or_null("/root/SaveManager")
	if sm and sm.has_method("save_active_slot"):
		sm.save_active_slot()
	# Always unpause before changing scenes.
	get_tree().paused = false
	if is_instance_valid(_layer):
		_layer.queue_free()
	_layer = null
	_panel = null
	_settings_menu = null
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


# ---------------------------------------------------------------------------
# Button factory (gold look matching the main menu).
# ---------------------------------------------------------------------------
func _make_button(text: String, cb: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(320, 56)
	btn.process_mode = Node.PROCESS_MODE_ALWAYS
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
	btn.add_theme_font_size_override("font_size", 24)
	btn.pressed.connect(cb)
	return btn
