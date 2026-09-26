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
var _controls_panel: Control = null

# ---------------------------------------------------------------------------
# Phase 3b — automatic pause triggers
# ---------------------------------------------------------------------------
# Why a subtitle line: when the game pauses ITSELF the player needs to know
# why, otherwise a controller-disconnect pause reads as a freeze/crash.
var _pause_reason: String = ""

## Godot emits APPLICATION_FOCUS_OUT during a fullscreen mode change as well as
## on a real alt-tab. Without this cooldown, every F11 press would pop the pause
## menu. Settings.display_changed stamps the clock; focus-out events inside the
## window are ignored.
const FULLSCREEN_COOLDOWN_MS: int = 600
var _display_change_ms: int = -100000

## Ignore focus-out during the first moments of the process — some window
## managers hand out a spurious focus-out while the window is still being
## created, which would pause the game before the player ever sees it.
const BOOT_GRACE_MS: int = 1500


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	# Fullscreen toggles come through Settings (menu, F11 and Alt+Enter all
	# funnel into it), so one connection covers every source.
	var s: Node = get_node_or_null("/root/Settings")
	if s != null and s.has_signal("display_changed"):
		if not s.display_changed.is_connected(_on_display_changed):
			s.display_changed.connect(_on_display_changed)

	if not Input.joy_connection_changed.is_connected(_on_joy_connection_changed):
		Input.joy_connection_changed.connect(_on_joy_connection_changed)


func _on_display_changed(_is_fullscreen: bool) -> void:
	_display_change_ms = Time.get_ticks_msec()


# ---------------------------------------------------------------------------
# Phase 3b — pause when the window loses focus
# ---------------------------------------------------------------------------
# Alt-tab, a Discord call or clicking a second monitor used to leave the game
# running — and taking damage — in the background.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_auto_pause("Window lost focus")


## Shared entry point for every self-initiated pause. Every guard here matters:
## without them the overlay stacks on top of boon offers, fires during
## fullscreen transitions, or opens on the main menu.
func _auto_pause(reason: String) -> void:
	var now: int = Time.get_ticks_msec()
	if now < BOOT_GRACE_MS:
		return
	if now - _display_change_ms < FULLSCREEN_COOLDOWN_MS:
		return
	if not _is_pausable_scene():
		return
	if is_open():
		return
	# Covers BOTH our own overlay and anything else that paused the tree
	# (boon offers, cutscenes) — never stack a second pause on top.
	if get_tree().paused:
		return
	_pause_reason = reason
	_open()


# ---------------------------------------------------------------------------
# Phase 3b — pause when a controller in use disconnects
# ---------------------------------------------------------------------------
func _on_joy_connection_changed(device: int, connected: bool) -> void:
	if connected:
		return
	if not _device_was_in_use(device):
		return
	_auto_pause("Controller disconnected — reconnect to continue")


## True when the vanished pad was actually driving a player.
##
## Two cases: in 2P the device ids are recorded on RunState, so we can match
## exactly. In 1P nothing records "the player is on pad 0", so we infer it —
## if the last input came from a gamepad and no pads remain connected, the
## player has definitely just lost their controller.
func _device_was_in_use(device: int) -> bool:
	var rs: Node = get_node_or_null("/root/RunState")
	if rs != null:
		if "shino_device" in rs and int(rs.shino_device) == device:
			return true
		if "bea_device" in rs and int(rs.bea_device) == device:
			return true
	var glyphs: Node = get_node_or_null("/root/InputGlyphs")
	if glyphs != null and "gamepad" in glyphs and bool(glyphs.gamepad):
		if Input.get_connected_joypads().is_empty():
			return true
	return false


func _unhandled_input(event: InputEvent) -> void:
	# Start (pause) toggles the menu. B / Esc (ui_cancel) only ever BACKS OUT —
	# it closes the menu or a sub-panel but never opens it, because ui_cancel is
	# also bound to B (dash) and must stay inert during normal gameplay.
	var is_pause: bool = event.is_action_pressed("pause")
	var is_cancel: bool = event.is_action_pressed("ui_cancel")
	if not is_pause and not is_cancel:
		return
	# If the settings sub-panel is open, back out of it (Esc is normally consumed
	# by SettingsMenu; this covers gamepad Start / B).
	if is_instance_valid(_settings_menu):
		_settings_menu.queue_free()
		get_viewport().set_input_as_handled()
		return
	# Same for the controls sheet — back out one level, don't unpause the game.
	if is_instance_valid(_controls_panel):
		_close_controls()
		get_viewport().set_input_as_handled()
		return
	if is_open():
		_resume()
		get_viewport().set_input_as_handled()
		return
	# Menu is closed: only Start opens it. A stray B during gameplay falls
	# through untouched so it can still act as dash.
	if is_pause and _is_pausable_scene():
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
	# Phase 2a — UI audio. Safe no-op if the SFX autoload or the asset is absent.
	FX.play_sound("menu_open")

	_layer = CanvasLayer.new()
	_layer.layer = 100
	_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().root.add_child(_layer)
	# Run 164c — apply the "Ink & Washi" skin to everything built below.
	UISkin.skin_tree_deferred(_layer)

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

	# Phase 3b — why did this open? Blank for a manual Esc; filled in when the
	# game paused itself, so a disconnect never looks like a freeze.
	if _pause_reason != "":
		var reason_lbl := Label.new()
		reason_lbl.text = _pause_reason
		reason_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		reason_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		reason_lbl.custom_minimum_size = Vector2(320, 0)
		reason_lbl.add_theme_color_override("font_color", Color(1.0, 0.72, 0.35, 1.0))
		reason_lbl.add_theme_font_size_override("font_size", 15)
		box.add_child(reason_lbl)

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
	var controls_btn := _make_button("CONTROLS", _open_controls)
	var settings_btn := _make_button("SETTINGS", _open_settings)
	var abandon_btn := _make_button("ABANDON RUN", _abandon_run)
	var exit_btn := _make_button("SAVE & EXIT", _save_and_exit)
	box.add_child(controls_btn)
	box.add_child(settings_btn)

	# Run 173 — Training Room session exits. Only present while a session is
	# live, and "Return to Training Room" only while a holo-room bout is
	# actually running (in the Training Room itself it would be a no-op).
	var nav_buttons: Array = [_resume_btn, controls_btn, settings_btn]
	if RunState.training_active:
		if not RunState.training_squad.is_empty():
			var back_btn := _make_button("RETURN TO TRAINING ROOM", _return_to_training)
			box.add_child(back_btn)
			nav_buttons.append(back_btn)
		var end_btn := _make_button("RETURN TO DOJO", _end_training)
		box.add_child(end_btn)
		nav_buttons.append(end_btn)

	box.add_child(abandon_btn)
	box.add_child(exit_btn)
	nav_buttons.append(abandon_btn)
	nav_buttons.append(exit_btn)

	# Left stick / WASD navigation to match the D-pad (which already works via the
	# built-in focus chain). B / Esc is left to _unhandled_input so it can also
	# back out of the Controls / Settings sub-panels.
	var nav: Node = load("res://scripts/MenuFocusNav.gd").new()
	nav.process_mode = Node.PROCESS_MODE_ALWAYS
	_layer.add_child(nav)
	nav.buttons = nav_buttons

	_resume_btn.grab_focus()


# Run 173 — bail out of the current holo-room bout; the training session stays
# live and we land back on the mat.
# Run 173 — Training Room session exits live on DreamDojo so the scene paths
# and the RunState flag clearing have exactly one owner.
const DREAM_DOJO = preload("res://scripts/DreamDojo.gd")


func _return_to_training() -> void:
	FX.play_sound("menu_close")
	_teardown_overlay()
	DREAM_DOJO.return_to_training(get_tree())


# Run 173 — end the whole training session and wake up in the real Dojo.
func _end_training() -> void:
	FX.play_sound("menu_close")
	_teardown_overlay()
	DREAM_DOJO.return_to_dojo(get_tree())


# Tear the pause overlay down without unpausing — the caller is about to change
# scene, and handing a paused tree to a new scene freezes it on arrival.
func _teardown_overlay() -> void:
	if is_instance_valid(_settings_menu):
		_settings_menu.queue_free()
		_settings_menu = null
	if is_instance_valid(_controls_panel):
		_controls_panel.queue_free()
	_controls_panel = null
	if is_instance_valid(_layer):
		_layer.queue_free()
	_layer = null
	_panel = null
	_pause_reason = ""


func _resume() -> void:
	# Phase 2a — UI audio. Safe no-op if the SFX autoload or the asset is absent.
	FX.play_sound("menu_close")
	if is_instance_valid(_settings_menu):
		_settings_menu.queue_free()
		_settings_menu = null
	if is_instance_valid(_controls_panel):
		_controls_panel.queue_free()
	_controls_panel = null
	if is_instance_valid(_layer):
		_layer.queue_free()
	_layer = null
	_panel = null
	# Phase 3b — clear the auto-pause reason so a later manual Esc doesn't
	# still show "Controller disconnected".
	_pause_reason = ""
	get_tree().paused = false


# ---------------------------------------------------------------------------
# Phase 4 — Abandon Run
# ---------------------------------------------------------------------------
# Gives up the current run and wakes back at the Dojo. Routes through the SAME
# canonical sequence as dying (RunState.finalize_defeat) so karma still banks,
# lifetime stats still record the attempt, and the slot still saves — a player
# who abandons should not be able to dodge the bookkeeping that a death applies.
#
# Confirm-gated: this destroys a run in progress.
func _abandon_run() -> void:
	ConfirmPopup.request(_panel, "ABANDON RUN?",
		"You'll wake at the Dojo. Boons from this run are lost, "
		+ "but Dragon Souls, karma and Sensei upgrades are kept.",
		"ABANDON", Callable(self, "_do_abandon_run"), true)


func _do_abandon_run() -> void:
	var rs: Node = get_node_or_null("/root/RunState")
	if rs != null and rs.has_method("finalize_defeat"):
		rs.finalize_defeat()
	# Tear the overlay down and unpause BEFORE the scene change — swapping
	# scenes on a paused tree leaves the Dojo frozen with no way to unpause.
	_resume()
	get_tree().change_scene_to_file("res://scenes/Dojo.tscn")


# ---------------------------------------------------------------------------
# Phase 3d — Controls sheet
# ---------------------------------------------------------------------------
# Previously the control list existed ONLY on the main menu, so a player who
# forgot a button mid-run had to quit out to read it.
#
# Every row is an InputGlyphs template rather than hardcoded key text. That
# means the sheet re-renders itself when the player switches between keyboard
# and pad (Run 158), and — importantly — it will pick up Phase 5's rebinding
# automatically instead of quietly lying about which key does what.
const CONTROL_ROWS: Array = [
	["Move",              "{move}"],
	["Aim (twin-stick)",  "{aim}"],
	["Light attack",      "{attack_y}"],
	["Heavy attack",      "{attack_x}"],
	["Special",           "{attack_a}"],
	["Charge (hold)",     "{charge}"],
	["Dash",              "{dash}"],
	["Ultimate",          "{ult}"],
	["Swap ninja",        "{swap}"],
	["Interact",          "{interact}"],
	["Inspect boons",     "{reroll}"],
	["Pause",             "{pause}"],
]


func _open_controls() -> void:
	if is_instance_valid(_controls_panel) or not is_instance_valid(_layer):
		return
	FX.play_sound("menu_open")
	if _panel:
		_panel.visible = false   # hide the pause buttons behind the sheet

	var root := Control.new()
	root.anchor_right = 1.0
	root.anchor_bottom = 1.0
	root.process_mode = Node.PROCESS_MODE_ALWAYS
	_layer.add_child(root)
	_controls_panel = root

	var dim := ColorRect.new()
	dim.anchor_right = 1.0
	dim.anchor_bottom = 1.0
	dim.color = Color(0.0, 0.0, 0.0, 0.72)
	root.add_child(dim)

	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -250.0
	panel.offset_top = -220.0
	panel.offset_right = 250.0
	panel.offset_bottom = 220.0
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.07, 0.11, 0.98)
	sb.border_color = COLOR_GOLD_DIM
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(22)
	panel.add_theme_stylebox_override("panel", sb)
	root.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "CONTROLS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", COLOR_GOLD)
	title.add_theme_font_size_override("font_size", 30)
	vbox.add_child(title)

	var glyphs: Node = get_node_or_null("/root/InputGlyphs")
	for row in CONTROL_ROWS:
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 12)
		vbox.add_child(line)

		var name_lbl := Label.new()
		name_lbl.text = String(row[0])
		name_lbl.custom_minimum_size = Vector2(210, 0)
		name_lbl.add_theme_color_override("font_color", Color(0.88, 0.88, 0.93, 1.0))
		name_lbl.add_theme_font_size_override("font_size", 16)
		line.add_child(name_lbl)

		var key_lbl := RichTextLabel.new()
		key_lbl.bbcode_enabled = true
		key_lbl.fit_content = true
		key_lbl.scroll_active = false
		key_lbl.custom_minimum_size = Vector2(230, 22)
		line.add_child(key_lbl)
		# bind_rich re-renders this label forever, including on device change.
		if glyphs != null and glyphs.has_method("bind_rich"):
			glyphs.bind_rich(key_lbl, String(row[1]))
		else:
			key_lbl.text = String(row[1])

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 6)
	vbox.add_child(spacer)

	var back := _make_button("BACK", _close_controls)
	vbox.add_child(back)
	back.grab_focus()


func _close_controls() -> void:
	FX.play_sound("menu_close")
	if is_instance_valid(_controls_panel):
		_controls_panel.queue_free()
	_controls_panel = null
	if _panel:
		_panel.visible = true
	if is_instance_valid(_resume_btn):
		_resume_btn.grab_focus()


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
