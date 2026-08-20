extends Control

# ============================================================
# MainMenu.gd — Run 23 (2026-06-01)
# ============================================================
# Title-card menu that boots first when the user presses F5.
# Three actions:
#   START    — change_scene_to_file("res://scenes/Arena1.tscn")
#   CONTROLS — toggle a controls-overlay panel showing key bindings
#   QUIT     — get_tree().quit()
#
# Navigation works with mouse, keyboard (Up/Down/Enter), and gamepad
# (D-pad / left stick / A button). The currently-focused button glows
# gold-yellow; non-focused buttons stay dim gold. The controls overlay
# can be dismissed with Esc or the gamepad B button.
#
# Per Bruno's request: visuals are intentionally simple (system font,
# colored rects). Polish later — playability is the bar today.
# ============================================================

const ARENA1_PATH: String  = "res://scenes/Dojo.tscn"   # Run 29: START → Dojo intro, not Arena1 directly
# Run 73 — START now leads to PlayerSetup (1P/2P + controller assignment),
# which then forwards to SaveFileSelect.
const SAVE_SELECT_PATH: String = "res://scenes/PlayerSetup.tscn"

const COLOR_GOLD_BORDER:  Color = Color(0.85, 0.70, 0.25, 1.0)
const COLOR_GOLD_BRIGHT:  Color = Color(1.00, 0.88, 0.40, 1.0)
const COLOR_GOLD_DIM:     Color = Color(0.55, 0.45, 0.18, 1.0)
const COLOR_BG_TOP:       Color = Color(0.06, 0.05, 0.09, 1.0)
const COLOR_BG_BOT:       Color = Color(0.02, 0.02, 0.04, 1.0)
const COLOR_PANEL:        Color = Color(0.08, 0.07, 0.10, 0.96)

const SETTINGS_SCENE: String = "res://scenes/SettingsMenu.tscn"

# Run 164 — the buttons now hang inside the scroll, so the paths are deeper
# than the old flat CenterStack. Node NAMES are deliberately unchanged.
const STACK_PATH: String = "ScrollFrame/ScrollBody/Content/CenterStack"

@onready var start_btn:    Button     = $ScrollFrame/ScrollBody/Content/CenterStack/StartButton
@onready var controls_btn: Button     = $ScrollFrame/ScrollBody/Content/CenterStack/ControlsButton
@onready var quit_btn:     Button     = $ScrollFrame/ScrollBody/Content/CenterStack/QuitButton
@onready var overlay:      Control    = $ControlsOverlay
@onready var overlay_close_btn: Button = $ControlsOverlay/Panel/CloseButton

# Settings button — created in code and inserted above QUIT so we don't need a
# scene edit. Opens the shared SettingsMenu panel.
var settings_btn: Button = null
var _settings_menu: Control = null

var _starting: bool = false
var _splash_hold: bool = true   # Run 136 — hold splash image before revealing menu

# How long the boot splash lingers before the main menu appears.
const SPLASH_HOLD_SECONDS: float = 3.0

# ── Stick nav gating: first press instant, 1.5 s hold → slow repeat ──
const NAV_INITIAL_DELAY: float = 1.5
const NAV_REPEAT_RATE:   float = 0.3
const NAV_COOLDOWN:      float = 0.18
var _nav_held_dir: int   = 0
var _nav_hold_time: float = 0.0
var _nav_repeat_acc: float = 0.0
var _nav_cooldown_t: float = 0.0
# Legacy edge-latch kept for raw JoypadMotion path (see _nav_dir).
var _stick_nav_latched: bool = false
const STICK_NAV_PRESS: float = 0.6
const STICK_NAV_RELEASE: float = 0.3


func _ready() -> void:
	# Reset any previous run-state on title return — so a fresh Start gives
	# a clean run rather than carrying boons / loops from a prior playthrough.
	if Engine.has_singleton("RunState") or get_node_or_null("/root/RunState"):
		var rs := get_node_or_null("/root/RunState")
		if rs and rs.has_method("reset_run"):
			rs.reset_run()
		# Run 73 — always return to single-player at the title. The PlayerSetup
		# screen re-enables 2P per session. (two_player is intentionally not in
		# reset_run since that also fires mid-run.)
		if rs:
			rs.two_player = false
			rs.shino_device = -1
			rs.bea_device = -1

	# Run 164 — paint the scroll before anything else so the first frame the
	# player sees is already skinned (UISkin is an autoload; it is always up).
	UISkin.skin_main_menu(self)

	# Create the SETTINGS button and slot it between CONTROLS and QUIT.
	settings_btn = Button.new()
	settings_btn.text = "SETTINGS"
	settings_btn.custom_minimum_size = Vector2(0, 62)
	var stack: Control = get_node(STACK_PATH)
	stack.add_child(settings_btn)
	stack.move_child(settings_btn, quit_btn.get_index())   # place just above QUIT

	# Hook button signals.
	start_btn.pressed.connect(_on_start_pressed)
	controls_btn.pressed.connect(_on_controls_pressed)
	settings_btn.pressed.connect(_on_settings_pressed)
	quit_btn.pressed.connect(_on_quit_pressed)
	overlay_close_btn.pressed.connect(_on_overlay_close_pressed)

	# Visual setup — apply gold-border style to each button.
	_style_button(start_btn)
	_style_button(controls_btn)
	_style_button(settings_btn)
	_style_button(quit_btn)
	_style_button(overlay_close_btn)

	# Hide overlay initially.
	overlay.visible = false

	# Run 137 — show the boot splash image for a few seconds before revealing menu.
	# Godot's own boot splash vanishes the moment the first scene loads, so we
	# recreate it here. IMPORTANT: the splash lives on its own CanvasLayer —
	# if it were a child of this Control, `modulate.a = 0.0` below would hide
	# it too (child alpha multiplies with the parent's), leaving 3 s of grey
	# clear-color. That was the Run 136 grey-screen bug.
	modulate.a = 0.0
	_splash_hold = true
	var splash_layer := CanvasLayer.new()
	splash_layer.layer = 90
	add_child(splash_layer)
	var splash_wrap := Control.new()
	splash_wrap.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	splash_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	splash_layer.add_child(splash_wrap)
	var splash_bg := ColorRect.new()
	splash_bg.color = Color(0, 0, 0)   # letterbox bars match the boot splash bg
	splash_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	splash_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	splash_wrap.add_child(splash_bg)
	var splash_img := TextureRect.new()
	splash_img.texture = load("res://Assets/Loading Screens/Shino and Bea Capsule Image.png")
	splash_img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	splash_img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	splash_img.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	splash_img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	splash_wrap.add_child(splash_img)
	# Wait up to SPLASH_HOLD_SECONDS — any button/key press skips early.
	var elapsed: float = 0.0
	while elapsed < SPLASH_HOLD_SECONDS and _splash_hold:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
	_splash_hold = false
	# Fade out splash, fade in menu simultaneously (CanvasLayer itself has no
	# modulate, so tween the wrapper Control instead).
	var splash_tw: Tween = create_tween().set_parallel(true)
	splash_tw.tween_property(splash_wrap, "modulate:a", 0.0, 0.5)
	splash_tw.tween_property(self, "modulate:a", 1.0, 0.6)
	await splash_tw.finished
	splash_layer.queue_free()

	# Initial focus on Start so gamepad / keyboard users can immediately confirm.
	start_btn.grab_focus()

	# Title / intro music (shuffled if you drop more into Assets/Music/Menu/).
	MusicManager.play_area("menu")

	# Focus highlight tween — driven each frame via _process.
	# (Could use focus_entered signals; per-frame is simpler & always-in-sync.)


func _process(_delta: float) -> void:
	if _splash_hold:
		return
	# ── Polling-based stick nav (immune to wobble) ───────────────
	# ConfirmPopup.is_open() added in the Phase 1-3 sweep: this poll would
	# otherwise keep cycling focus behind an open dialog.
	if not is_instance_valid(_settings_menu) and not overlay.visible \
			and not ConfirmPopup.is_open():
		if _nav_cooldown_t > 0.0:
			_nav_cooldown_t -= _delta
		var want: int = 0
		if Input.is_action_pressed("move_up") or Input.is_action_pressed("ui_up"):
			want = -1
		elif Input.is_action_pressed("move_down") or Input.is_action_pressed("ui_down"):
			want = 1

		if want == 0:
			_nav_held_dir = 0; _nav_hold_time = 0.0; _nav_repeat_acc = 0.0
		elif want != _nav_held_dir:
			_nav_held_dir = want; _nav_hold_time = 0.0; _nav_repeat_acc = 0.0
			if _nav_cooldown_t <= 0.0:
				_cycle_focus(want); _nav_cooldown_t = NAV_COOLDOWN
		else:
			_nav_hold_time += _delta
			if _nav_hold_time >= NAV_INITIAL_DELAY:
				_nav_repeat_acc += _delta
				while _nav_repeat_acc >= NAV_REPEAT_RATE:
					_nav_repeat_acc -= NAV_REPEAT_RATE
					if _nav_cooldown_t <= 0.0:
						_cycle_focus(_nav_held_dir); _nav_cooldown_t = NAV_COOLDOWN

	# Run 164 — focus feedback is now the plaque swap + the sliding hanko seal
	# (see UISkin.skin_button). The old per-frame font-colour override fought
	# the theme, so it is gone; nothing to do here each frame.


func _input(event: InputEvent) -> void:
	if _splash_hold:
		# Any key/button press skips the splash hold early.
		if event is InputEventKey or event is InputEventJoypadButton or event is InputEventMouseButton:
			if event.is_pressed():
				_splash_hold = false
				get_viewport().set_input_as_handled()
		return
	# Settings panel handles its own input (incl. Esc to close) — don't let the
	# title menu cycle focus behind it.
	if is_instance_valid(_settings_menu):
		return
	# Same for a confirmation dialog. This menu reads raw joypad events rather
	# than relying on focus (see the Run 75 note below), so without this guard
	# gamepad A would activate the button BEHIND the quit prompt.
	if ConfirmPopup.is_open():
		return

	# --------------------------------------------------------------------
	# Run 75 — fully device-agnostic controller support.
	# We don't trust Godot's built-in ui_* joypad defaults here: depending on
	# the engine build and on Steam Input (which can present a single pad on a
	# non-zero device slot, "P2"), those defaults don't always reach every
	# device. So the title menu reads raw joypad events itself and ignores the
	# device id entirely — ANY connected pad in ANY slot drives the menu, and
	# it coexists with the keyboard. We consume events we act on so Godot's own
	# ui_accept/ui_up handling can't fire a second time.
	# --------------------------------------------------------------------

	# Esc / gamepad B closes overlay if open.
	if overlay.visible:
		if event.is_action_pressed("ui_cancel"):
			_close_overlay()
			get_viewport().set_input_as_handled()
		elif _is_joy_button(event, JOY_BUTTON_B):
			_close_overlay()
			get_viewport().set_input_as_handled()
		return

	# ---- Confirm: gamepad A (any device). Enter/Space stay on native ui_accept.
	if _is_joy_button(event, JOY_BUTTON_A):
		_activate_focused()
		get_viewport().set_input_as_handled()
		return

	# ---- Navigation up/down — consume events; _process polls & moves.
	var dir: int = _nav_dir(event)
	if dir != 0:
		get_viewport().set_input_as_handled()


# True for a fresh press of the given gamepad button on ANY device.
func _is_joy_button(event: InputEvent, button: int) -> bool:
	return event is InputEventJoypadButton and event.pressed and event.button_index == button


# Returns -1 (up), +1 (down), or 0 — combining keyboard, gamepad D-pad, and the
# analog left stick (edge-latched), from any device.
func _nav_dir(event: InputEvent) -> int:
	# Keyboard W/S + arrow keys.
	if event is InputEventKey:
		if event.is_action_pressed("move_up") or event.is_action_pressed("ui_up"):
			return -1
		if event.is_action_pressed("move_down") or event.is_action_pressed("ui_down"):
			return 1
		return 0

	# Gamepad D-pad (device-agnostic).
	if event is InputEventJoypadButton and event.pressed:
		if event.button_index == JOY_BUTTON_DPAD_UP:
			return -1
		if event.button_index == JOY_BUTTON_DPAD_DOWN:
			return 1
		return 0

	# Analog left stick, vertical axis — edge-latched so one push = one step.
	if event is InputEventJoypadMotion and event.axis == JOY_AXIS_LEFT_Y:
		var v: float = event.axis_value
		if absf(v) < STICK_NAV_RELEASE:
			_stick_nav_latched = false
		elif not _stick_nav_latched and absf(v) >= STICK_NAV_PRESS:
			_stick_nav_latched = true
			return 1 if v > 0.0 else -1
	return 0


# Press whichever menu button currently holds focus (mirrors native ui_accept).
func _activate_focused() -> void:
	var f: Control = get_viewport().gui_get_focus_owner()
	if f is BaseButton:
		(f as BaseButton).pressed.emit()


func _cycle_focus(dir: int) -> void:
	var btns: Array = [start_btn, controls_btn, settings_btn, quit_btn]
	var cur: int = 0
	for i in range(btns.size()):
		if (btns[i] as Button).has_focus():
			cur = i
			break
	(btns[(cur + dir + btns.size()) % btns.size()] as Button).grab_focus()


func _on_start_pressed() -> void:
	if _starting:
		return
	_starting = true
	Log.dbg("[MainMenu] START pressed — loading Save Select.")
	if get_node_or_null("/root/FX") and FX.has_method("fade_to_black"):
		FX.fade_to_black(0.30, 0.05, 1.0, Callable(self, "_do_start_scene_change"))
	else:
		_do_start_scene_change()


func _do_start_scene_change() -> void:
	if not ResourceLoader.exists(SAVE_SELECT_PATH):
		push_error("[MainMenu] FATAL — %s not found." % SAVE_SELECT_PATH)
		_starting = false
		return
	var err: int = get_tree().change_scene_to_file(SAVE_SELECT_PATH)
	if err != OK:
		push_error("[MainMenu] change_scene_to_file failed for SaveFileSelect (err=%d)." % err)
		_starting = false


func _on_controls_pressed() -> void:
	_open_overlay()


func _on_settings_pressed() -> void:
	if is_instance_valid(_settings_menu):
		return
	if not ResourceLoader.exists(SETTINGS_SCENE):
		push_error("[MainMenu] SettingsMenu scene missing.")
		return
	_settings_menu = load(SETTINGS_SCENE).instantiate()
	add_child(_settings_menu)
	if _settings_menu.has_signal("closed"):
		_settings_menu.closed.connect(_on_settings_menu_closed)


func _on_settings_menu_closed() -> void:
	_settings_menu = null
	settings_btn.grab_focus()


func _on_quit_pressed() -> void:
	# Phase 3c — confirm first. Skipped automatically when the player has
	# turned Settings > Safety Confirmations off.
	ConfirmPopup.request(self, "QUIT GAME?",
		"Your progress is saved at the Dojo and at each gate.",
		"QUIT", Callable(self, "_do_quit"), true)


func _do_quit() -> void:
	Log.dbg("[MainMenu] QUIT confirmed — closing game.")
	get_tree().quit()


# ---------------------------------------------------------------------------
# Controls overlay
# ---------------------------------------------------------------------------

func _open_overlay() -> void:
	overlay.visible = true
	# The 忍ノ道 / 影ヲ継グ者 inscriptions hang from the screen root (added by
	# UISkin.skin_main_menu), so they render ON TOP of the controls sheet and
	# print red kanji straight over the key-binding text. Hide them while the
	# overlay is up; restore on close.
	_set_inscriptions_visible(false)
	overlay_close_btn.grab_focus()


func _close_overlay() -> void:
	overlay.visible = false
	_set_inscriptions_visible(true)
	controls_btn.grab_focus()


func _set_inscriptions_visible(v: bool) -> void:
	for n in ["InscriptionLeft", "InscriptionRight"]:
		var lab: Control = get_node_or_null(n) as Control
		if lab != null:
			lab.visible = v


func _on_overlay_close_pressed() -> void:
	_close_overlay()


# ---------------------------------------------------------------------------
# Button styling helper
# ---------------------------------------------------------------------------

func _style_button(btn: Button) -> void:
	# Run 164 — one source of truth. UISkin gives the button the ema-plaque
	# 9-slice in all four states, the DotGothic16 face, ink-outlined text and a
	# cinnabar 忍 seal that snaps in beside it on focus.
	UISkin.skin_button(btn, "nin" if btn != overlay_close_btn else "")


# Superseded by UISkin.skin_button — kept only as a reference for what the
# pre-Run-164 menu looked like. Nothing calls it.
func _style_button_legacy(btn: Button) -> void:
	# Gold-bordered button with dark fill. Hover + focus push the border brighter.
	var sb_normal := StyleBoxFlat.new()
	sb_normal.bg_color = Color(0.10, 0.09, 0.13, 0.94)
	sb_normal.border_width_left = 2
	sb_normal.border_width_right = 2
	sb_normal.border_width_top = 2
	sb_normal.border_width_bottom = 2
	sb_normal.border_color = COLOR_GOLD_BORDER
	sb_normal.corner_radius_top_left = 6
	sb_normal.corner_radius_top_right = 6
	sb_normal.corner_radius_bottom_left = 6
	sb_normal.corner_radius_bottom_right = 6
	sb_normal.content_margin_left = 22
	sb_normal.content_margin_right = 22
	sb_normal.content_margin_top = 10
	sb_normal.content_margin_bottom = 10

	var sb_hover := sb_normal.duplicate()
	sb_hover.border_color = COLOR_GOLD_BRIGHT
	sb_hover.border_width_left = 3
	sb_hover.border_width_right = 3
	sb_hover.border_width_top = 3
	sb_hover.border_width_bottom = 3
	sb_hover.bg_color = Color(0.16, 0.14, 0.18, 0.96)

	var sb_focus := sb_hover.duplicate()
	sb_focus.shadow_color = Color(COLOR_GOLD_BRIGHT.r, COLOR_GOLD_BRIGHT.g, COLOR_GOLD_BRIGHT.b, 0.45)
	sb_focus.shadow_size = 6

	var sb_pressed := sb_hover.duplicate()
	sb_pressed.bg_color = Color(0.22, 0.20, 0.10, 1.0)

	btn.add_theme_stylebox_override("normal",  sb_normal)
	btn.add_theme_stylebox_override("hover",   sb_hover)
	btn.add_theme_stylebox_override("focus",   sb_focus)
	btn.add_theme_stylebox_override("pressed", sb_pressed)
	btn.add_theme_color_override("font_color", COLOR_GOLD_BORDER)
	btn.add_theme_color_override("font_hover_color", COLOR_GOLD_BRIGHT)
	btn.add_theme_color_override("font_focus_color", COLOR_GOLD_BRIGHT)
	btn.add_theme_font_size_override("font_size", 28)
