extends Control
# ============================================================
# PlayerSetup.gd — Run 73 — 1P / 2P mode + controller assignment
# ============================================================
# Shown after pressing START on the main menu, BEFORE the save-file select.
#
# Phase MODE   : pick "1 PLAYER" or "2 PLAYER".
#   1P → classic hot-swap build (RunState.two_player = false) → SaveFileSelect.
#   2P → goes to the ASSIGN phase.
#
# Phase ASSIGN : Shino framed on the left, Bea framed on the right. Each player
#   moves their own icon LEFT/RIGHT (their device's stick / d-pad, plus
#   A,D = P1 and ←,→ = P2 on the keyboard) to HOVER a ninja, then presses
#   A / ENTER to LOCK IN that ninja. Only one player may hold a given ninja:
#   if a ninja is already locked by the other player you may hover it but the
#   lock is refused. A locked player can't move until they un-lock (B / ESC).
#   Once BOTH are locked a big "PRESS START" appears and either player presses
#   Start (gamepad Start button / A / ENTER) to begin → SaveFileSelect with
#   RunState.two_player = true. Either may press B / ESC to un-lock first.
# ============================================================

const SAVE_SELECT_PATH: String = "res://scenes/SaveFileSelect.tscn"
const MAIN_MENU_PATH:   String = "res://scenes/MainMenu.tscn"

const COLOR_BG:          Color = Color(0.04, 0.03, 0.06, 1.0)
const COLOR_GOLD_BORDER: Color = Color(0.85, 0.70, 0.25, 1.0)
const COLOR_GOLD_BRIGHT: Color = Color(1.00, 0.88, 0.40, 1.0)
const COLOR_PANEL:       Color = Color(0.10, 0.09, 0.13, 0.96)
const COLOR_P1:          Color = Color(0.40, 0.70, 1.00, 1.0)   # Shino-blue-ish
const COLOR_P2:          Color = Color(1.00, 0.55, 0.95, 1.0)   # Bea-magenta-ish
const COLOR_READY:       Color = Color(0.45, 0.95, 0.55, 1.0)

# Assignment slots: 0 = Shino (left), 1 = none (center), 2 = Bea (right).
const SLOT_SHINO: int = 0
const SLOT_NONE:  int = 1
const SLOT_BEA:   int = 2

const ICON_SIZE: Vector2 = Vector2(70, 44)
var _col_x: Array = [290.0, 640.0, 990.0]   # x-center per slot
const P1_ROW_Y: float = 300.0
const P2_ROW_Y: float = 470.0

enum Phase { MODE, ASSIGN }
var _phase: int = Phase.MODE

# Mode-phase buttons
var _btn_1p: Button = null
var _btn_2p: Button = null
var _mode_focus: int = 0   # default highlight 1 PLAYER

# Assign-phase nodes
var _assign_root: Control = null
var _p1_icon: Control = null
var _p2_icon: Control = null
var _start_label: Label = null      # status line ("lock in", "blocked"…)
var _press_start_label: Label = null  # big "PRESS START" overlay
var _device_readout: Label = null   # Run 74 — shows which device drives P1/P2
var _shino_frame: Panel = null
var _bea_frame: Panel = null

var _p1_slot: int = SLOT_SHINO
var _p2_slot: int = SLOT_BEA
var _p1_locked: bool = false
var _p2_locked: bool = false
var _p1_device: int = -1
var _p2_device: int = -1

var _blocked_flash: float = 0.0   # >0 = show "ninja taken" warning briefly

var _starting: bool = false

# ── Stick nav gating ─────────────────────────────────────────
const NAV_INITIAL_DELAY: float = 1.5
const NAV_REPEAT_RATE:   float = 0.3
var _nav_held_dir: int   = 0
var _nav_hold_time: float = 0.0
var _nav_repeat_acc: float = 0.0


# ---------------------------------------------------------------------------
# Small drawn gamepad icon (placeholder art — Bruno can swap in a sprite later)
# ---------------------------------------------------------------------------
class PadIcon extends Control:
	var col: Color = Color(1, 1, 1, 1)
	func _draw() -> void:
		var w: float = size.x
		var h: float = size.y
		var r: float = h * 0.5
		# Rounded body = center rect + two end circles.
		draw_rect(Rect2(r, 0, w - 2.0 * r, h), col, true)
		draw_circle(Vector2(r, r), r, col)
		draw_circle(Vector2(w - r, r), r, col)
		var dk := Color(0.10, 0.10, 0.13, 1.0)
		# D-pad (left).
		draw_rect(Rect2(r - 3.0, h * 0.5 - 9.0, 6.0, 18.0), dk, true)
		draw_rect(Rect2(r - 9.0, h * 0.5 - 3.0, 18.0, 6.0), dk, true)
		# Face buttons (right).
		draw_circle(Vector2(w - r - 7.0, h * 0.5), 3.6, dk)
		draw_circle(Vector2(w - r + 7.0, h * 0.5), 3.6, dk)


func _ready() -> void:
	_build_background()
	_build_mode_phase()
	_build_assign_phase()
	_show_phase(Phase.MODE)
	# Run 74 — pick up controllers that connect (or that Steam hands over) AFTER
	# this screen has loaded, so device binding doesn't depend on enumeration
	# timing.
	if not Input.joy_connection_changed.is_connected(_on_joy_changed):
		Input.joy_connection_changed.connect(_on_joy_changed)


func _build_background() -> void:
	var bg := ColorRect.new()
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	bg.color = COLOR_BG
	add_child(bg)

	var title := Label.new()
	title.text = "PLAYERS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.anchor_right = 1.0
	title.offset_top = 48.0
	title.offset_bottom = 118.0
	title.add_theme_color_override("font_color", COLOR_GOLD_BRIGHT)
	title.add_theme_font_size_override("font_size", 46)
	add_child(title)


# ---------------------------------------------------------------------------
# MODE phase
# ---------------------------------------------------------------------------
func _build_mode_phase() -> void:
	var sub := Label.new()
	sub.name = "ModeSub"
	sub.text = "How many ninjas tonight?"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.anchor_right = 1.0
	sub.offset_top = 150.0
	sub.offset_bottom = 182.0
	sub.add_theme_color_override("font_color", Color(0.65, 0.60, 0.75, 0.85))
	sub.add_theme_font_size_override("font_size", 18)
	add_child(sub)

	_btn_1p = _make_mode_button("1  PLAYER", Vector2(640 - 340, 260))
	_btn_1p.pressed.connect(_on_one_player)
	_btn_2p = _make_mode_button("2  PLAYERS", Vector2(640 - 340, 360))
	_btn_2p.pressed.connect(_on_two_player)

	var hint := Label.new()
	hint.name = "ModeHint"
	hint.text = "↑/↓ choose   ENTER / A select   ESC back"
	hint.anchor_top = 1.0
	hint.anchor_right = 1.0
	hint.anchor_bottom = 1.0
	hint.offset_left = 16.0
	hint.offset_top = -32.0
	hint.offset_bottom = -10.0
	hint.add_theme_color_override("font_color", Color(0.60, 0.55, 0.70, 0.70))
	hint.add_theme_font_size_override("font_size", 13)
	add_child(hint)


func _make_mode_button(txt: String, pos: Vector2) -> Button:
	var b := Button.new()
	b.text = txt
	b.position = pos
	b.size = Vector2(680, 72)
	b.focus_mode = Control.FOCUS_ALL
	_style_button(b)
	b.add_theme_font_size_override("font_size", 30)
	add_child(b)
	return b


# ---------------------------------------------------------------------------
# ASSIGN phase
# ---------------------------------------------------------------------------
func _build_assign_phase() -> void:
	_assign_root = Control.new()
	_assign_root.anchor_right = 1.0
	_assign_root.anchor_bottom = 1.0
	_assign_root.visible = false
	add_child(_assign_root)

	var sub := Label.new()
	sub.text = "Hover a ninja, then press A to LOCK IN.   P1: A/D · P2: ← / →"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.anchor_right = 1.0
	sub.offset_top = 150.0
	sub.offset_bottom = 182.0
	sub.add_theme_color_override("font_color", Color(0.65, 0.60, 0.75, 0.85))
	sub.add_theme_font_size_override("font_size", 17)
	_assign_root.add_child(sub)

	# Run 74 — live device readout so you can SEE what Godot is reading. If this
	# says "0 controllers" while pads are plugged in, it's a Steam Input issue.
	_device_readout = Label.new()
	_device_readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_device_readout.anchor_right = 1.0
	_device_readout.offset_top = 188.0
	_device_readout.offset_bottom = 252.0
	_device_readout.add_theme_color_override("font_color", Color(0.55, 0.85, 0.95, 0.95))
	_device_readout.add_theme_font_size_override("font_size", 15)
	_assign_root.add_child(_device_readout)

	_shino_frame = _make_char_frame("SHINO", _col_x[SLOT_SHINO], COLOR_P1)
	_assign_root.add_child(_shino_frame)
	_make_portrait(_shino_frame, _load_shino_portrait())

	_bea_frame = _make_char_frame("BEA", _col_x[SLOT_BEA], COLOR_P2)
	_assign_root.add_child(_bea_frame)
	_make_portrait(_bea_frame, _load_bea_portrait())

	# P1 / P2 controller icons + labels.
	_p1_icon = _make_pad_icon(COLOR_P1)
	_assign_root.add_child(_p1_icon)
	_p2_icon = _make_pad_icon(COLOR_P2)
	_assign_root.add_child(_p2_icon)
	_add_pad_label("P1", _p1_icon, COLOR_P1)
	_add_pad_label("P2", _p2_icon, COLOR_P2)

	_start_label = Label.new()
	_start_label.text = ""
	_start_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_start_label.anchor_right = 1.0
	_start_label.offset_top = 600.0
	_start_label.offset_bottom = 640.0
	_start_label.add_theme_font_size_override("font_size", 24)
	_assign_root.add_child(_start_label)

	# Big "PRESS START" overlay — only visible once both ninjas are locked.
	_press_start_label = Label.new()
	_press_start_label.text = "PRESS  START"
	_press_start_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_press_start_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_press_start_label.anchor_right = 1.0
	_press_start_label.offset_top = 520.0
	_press_start_label.offset_bottom = 600.0
	_press_start_label.add_theme_color_override("font_color", COLOR_GOLD_BRIGHT)
	_press_start_label.add_theme_color_override("font_outline_color", Color(0.05, 0.04, 0.02, 1.0))
	_press_start_label.add_theme_constant_override("outline_size", 8)
	_press_start_label.add_theme_font_size_override("font_size", 64)
	_press_start_label.visible = false
	_assign_root.add_child(_press_start_label)

	var hint := Label.new()
	hint.text = "←/→ hover   A lock in   B un-lock   START begin   ESC back"
	hint.anchor_top = 1.0
	hint.anchor_right = 1.0
	hint.anchor_bottom = 1.0
	hint.offset_left = 16.0
	hint.offset_top = -32.0
	hint.offset_bottom = -10.0
	hint.add_theme_color_override("font_color", Color(0.60, 0.55, 0.70, 0.70))
	hint.add_theme_font_size_override("font_size", 13)
	_assign_root.add_child(hint)


func _make_char_frame(name_txt: String, cx: float, accent: Color) -> Panel:
	var p := Panel.new()
	var fw: float = 230.0
	var fh: float = 300.0
	p.position = Vector2(cx - fw * 0.5, 360.0 - fh * 0.5)
	p.size = Vector2(fw, fh)
	var sb := StyleBoxFlat.new()
	sb.bg_color = COLOR_PANEL
	for side in [SIDE_LEFT, SIDE_RIGHT, SIDE_TOP, SIDE_BOTTOM]:
		sb.set_border_width(side, 3)
	sb.border_color = accent
	sb.corner_radius_top_left = 10; sb.corner_radius_top_right = 10
	sb.corner_radius_bottom_left = 10; sb.corner_radius_bottom_right = 10
	p.add_theme_stylebox_override("panel", sb)

	var lbl := Label.new()
	lbl.text = name_txt
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.position = Vector2(0, fh - 42.0)
	lbl.size = Vector2(fw, 32.0)
	lbl.add_theme_color_override("font_color", accent)
	lbl.add_theme_font_size_override("font_size", 24)
	p.add_child(lbl)
	return p


func _make_portrait(frame: Panel, tex: Texture2D) -> void:
	if tex == null:
		return
	var tr := TextureRect.new()
	tr.texture = tex
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tr.position = Vector2(15, 18)
	tr.size = Vector2(frame.size.x - 30.0, frame.size.y - 70.0)
	frame.add_child(tr)


func _make_pad_icon(col: Color) -> Control:
	var icon := PadIcon.new()
	icon.col = col
	icon.size = ICON_SIZE
	icon.position = Vector2(_col_x[SLOT_NONE] - ICON_SIZE.x * 0.5, P1_ROW_Y)
	return icon


func _add_pad_label(txt: String, icon: Control, col: Color) -> void:
	var lbl := Label.new()
	lbl.name = "Tag"
	lbl.text = txt
	lbl.add_theme_color_override("font_color", col)
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.position = Vector2(ICON_SIZE.x * 0.5 - 12.0, -26.0)
	icon.add_child(lbl)


func _load_shino_portrait() -> Texture2D:
	var path := "res://Assets/Sprites/shino_walk_s.png"
	if not ResourceLoader.exists(path):
		return null
	var at := AtlasTexture.new()
	at.atlas = load(path)
	at.region = Rect2(0, 0, 96, 140)   # first idle frame
	return at


func _load_bea_portrait() -> Texture2D:
	var path := "res://Assets/Sprites/bea_static.png"
	if ResourceLoader.exists(path):
		return load(path)
	return null


# ---------------------------------------------------------------------------
# Phase switching
# ---------------------------------------------------------------------------
func _show_phase(p: int) -> void:
	_phase = p
	var mode_vis: bool = (p == Phase.MODE)
	_btn_1p.visible = mode_vis
	_btn_2p.visible = mode_vis
	get_node("ModeSub").visible = mode_vis
	get_node("ModeHint").visible = mode_vis
	_assign_root.visible = (p == Phase.ASSIGN)
	if mode_vis:
		_update_mode_focus()
	else:
		# Drop focus so the now-hidden mode buttons can't eat ui_accept.
		get_viewport().gui_release_focus()
		_rescan_devices(true)
		_p1_slot = SLOT_SHINO
		_p2_slot = SLOT_BEA
		_p1_locked = false
		_p2_locked = false
		_blocked_flash = 0.0
		_refresh_assign()


func _update_mode_focus() -> void:
	if _mode_focus == 0:
		_btn_1p.grab_focus()
	else:
		_btn_2p.grab_focus()


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------
func _input(event: InputEvent) -> void:
	if _phase == Phase.MODE:
		_input_mode(event)
	else:
		_input_assign(event)


func _input_mode(event: InputEvent) -> void:
	# Consume nav events — _process handles movement via polling.
	if event.is_action_pressed("ui_up") or event.is_action_pressed("move_up") \
	or event.is_action_pressed("ui_down") or event.is_action_pressed("move_down"):
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		if _btn_1p.has_focus():
			_on_one_player()
		else:
			_on_two_player()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel"):
		_back_to_menu()
		get_viewport().set_input_as_handled()


func _norm_device(event: InputEvent) -> int:
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		return event.device
	return -1   # keyboard / mouse


# ---------------------------------------------------------------------------
# Run 74 — robust device binding
# ---------------------------------------------------------------------------
# Re-derive P1/P2 devices from what Godot currently enumerates.
#   force = true  : entering the screen — take the defaults wholesale.
#   force = false : a controller (dis)connected mid-screen — only fill slots
#                   that are still keyboard, never steal a pad a player already
#                   claimed by pressing on it.
func _rescan_devices(force: bool) -> void:
	var devs: Dictionary = InputRouter.resolve_player_devices()
	var rp1: int = int(devs["p1"])
	var rp2: int = int(devs["p2"])
	if force:
		_p1_device = rp1
		_p2_device = rp2
	else:
		if _p1_device == -1 and rp1 != -1 and rp1 != _p2_device:
			_p1_device = rp1
		if (_p2_device == -1 or _p2_device == _p1_device) and rp2 != -1 and rp2 != _p1_device:
			_p2_device = rp2
	_update_device_readout()


# A real pad event arrived. Bind that pad to a player slot. Keyboard is kept as
# Player 1 whenever a human is using it, so the pad fills Player 2 first — this
# honors "keyboard = P1, controller = P2". With two pads, each distinct id ends
# up on its own slot (and on its own ninja).
func _claim_pad(dev: int) -> void:
	if dev < 0:
		return
	if dev == _p1_device or dev == _p2_device:
		return
	if _p2_device == -1 or _p2_device == _p1_device:
		_p2_device = dev
	elif _p1_device == -1:
		_p1_device = dev
	else:
		return
	_update_device_readout()


func _on_joy_changed(_device: int, _connected: bool) -> void:
	if _phase == Phase.ASSIGN:
		_rescan_devices(false)


func _update_device_readout() -> void:
	if _device_readout == null:
		return
	var line: String = InputRouter.pad_summary()
	line += "\nP1 → %s        P2 → %s" % [
		InputRouter.device_label(_p1_device), InputRouter.device_label(_p2_device)]
	if _p1_device == _p2_device:
		line += "\n⚠  Both players are on one device — connect a controller for Player 2."
	_device_readout.text = line


const JOY_BTN_START: int = 6   # gamepad Start button (matches "pause" action)

func _input_assign(event: InputEvent) -> void:
	var dev: int = _norm_device(event)

	# Run 74 — any input from a real pad binds that pad to a player slot, so the
	# device a person actually presses becomes theirs (and a pad Godot only just
	# started reporting still gets bound).
	if dev >= 0:
		_claim_pad(dev)

	# --- BOTH LOCKED : only START (begin) and B (un-lock) matter -------------
	if _p1_locked and _p2_locked:
		if _is_start_event(event):
			_confirm_assign()
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("ui_cancel"):
			var pc: int = _cancel_player(dev)
			if pc > 0:
				_unlock(pc)
			get_viewport().set_input_as_handled()
		return

	# --- HOVER MOVEMENT — P1 nav is polling-based in _process. Consume events.
	if event.is_action_pressed("move_left") or event.is_action_pressed("move_right"):
		get_viewport().set_input_as_handled()

	# P2 : its own device (only when distinct from P1's device).
	if _p2_device != _p1_device:
		if event.is_action_pressed("move_left") and dev == _p2_device:
			_move_icon(2, -1)
		elif event.is_action_pressed("move_right") and dev == _p2_device:
			_move_icon(2, 1)

	# Keyboard arrows always drive P2 (keyboard-only 2P testing: A/D=P1, ←/→=P2).
	if event.is_action_pressed("ui_left"):
		_move_icon(2, -1)
	elif event.is_action_pressed("ui_right"):
		_move_icon(2, 1)

	# --- LOCK IN (A / ENTER) -------------------------------------------------
	if event.is_action_pressed("ui_accept"):
		var pa: int = _accept_player(dev)
		if pa > 0:
			_try_lock(pa)
		get_viewport().set_input_as_handled()
	# --- UN-LOCK (B) or BACK (ESC, when nobody to un-lock) -------------------
	elif event.is_action_pressed("ui_cancel"):
		var pc: int = _cancel_player(dev)
		if pc > 0:
			_unlock(pc)
		else:
			_show_phase(Phase.MODE)
		get_viewport().set_input_as_handled()


func _is_start_event(event: InputEvent) -> bool:
	if event is InputEventJoypadButton and event.pressed \
			and event.button_index == JOY_BTN_START:
		return true
	# Keyboard / face-button fallback once both are locked.
	return event.is_action_pressed("ui_accept")


# Which player does this device map to? 0 = unknown / keyboard.
func _player_for_device(dev: int) -> int:
	if dev < 0:
		return 0
	if dev == _p1_device:
		return 1
	if _p2_device != _p1_device and dev == _p2_device:
		return 2
	return 0


# For a LOCK press: route by device; keyboard fallback = first un-locked player.
func _accept_player(dev: int) -> int:
	var p: int = _player_for_device(dev)
	if p != 0:
		return p
	if not _p1_locked:
		return 1
	if not _p2_locked:
		return 2
	return 0


# For an UN-LOCK press: route by device; keyboard fallback = last locked player.
func _cancel_player(dev: int) -> int:
	var p: int = _player_for_device(dev)
	if p != 0:
		return p
	if _p2_locked:
		return 2
	if _p1_locked:
		return 1
	return 0


func _move_icon(player: int, dir: int) -> void:
	# Locked players are pinned to their ninja until they un-lock.
	if player == 1:
		if _p1_locked:
			return
		_p1_slot = clampi(_p1_slot + dir, SLOT_SHINO, SLOT_BEA)
	else:
		if _p2_locked:
			return
		_p2_slot = clampi(_p2_slot + dir, SLOT_SHINO, SLOT_BEA)
	_refresh_assign()


func _try_lock(player: int) -> void:
	var slot: int = _p1_slot if player == 1 else _p2_slot
	var other_locked: bool = _p2_locked if player == 1 else _p1_locked
	var other_slot: int = _p2_slot if player == 1 else _p1_slot
	# Can't lock a ninja the other player has already claimed.
	if other_locked and other_slot == slot:
		_blocked_flash = 1.1
		_refresh_assign()
		return
	if player == 1:
		_p1_locked = true
	else:
		_p2_locked = true
	_refresh_assign()


func _unlock(player: int) -> void:
	if player == 1:
		_p1_locked = false
	else:
		_p2_locked = false
	_refresh_assign()


func _both_locked() -> bool:
	return _p1_locked and _p2_locked


func _refresh_assign() -> void:
	_press_start_label.visible = _both_locked()
	if _both_locked():
		_start_label.text = "B  un-lock"
		_start_label.add_theme_color_override("font_color", Color(0.65, 0.60, 0.75, 0.85))
	elif _blocked_flash > 0.0:
		_start_label.text = "That ninja is taken — pick the other one"
		_start_label.add_theme_color_override("font_color", Color(0.95, 0.45, 0.40, 1.0))
	else:
		var n_locked: int = int(_p1_locked) + int(_p2_locked)
		if n_locked == 1:
			_start_label.text = "Locked 1 / 2 — other player, lock in (A)"
			_start_label.add_theme_color_override("font_color", COLOR_READY)
		else:
			_start_label.text = "Hover a ninja and press A to lock in"
			_start_label.add_theme_color_override("font_color", Color(0.80, 0.75, 0.55, 0.95))
	_refresh_frame(_shino_frame, COLOR_P1, _slot_locked(SLOT_SHINO))
	_refresh_frame(_bea_frame, COLOR_P2, _slot_locked(SLOT_BEA))


# True if some player has locked the given ninja slot.
func _slot_locked(slot: int) -> bool:
	return (_p1_locked and _p1_slot == slot) or (_p2_locked and _p2_slot == slot)


func _refresh_frame(frame: Panel, accent: Color, is_locked: bool) -> void:
	if frame == null:
		return
	var sb := frame.get_theme_stylebox("panel") as StyleBoxFlat
	if sb == null:
		return
	var col: Color = COLOR_READY if is_locked else accent
	var w: int = 5 if is_locked else 3
	for side in [SIDE_LEFT, SIDE_RIGHT, SIDE_TOP, SIDE_BOTTOM]:
		sb.set_border_width(side, w)
	sb.border_color = col


func _process(delta: float) -> void:
	# ── Polling-based stick nav (immune to wobble) ───────────────
	var want: int = 0
	if _phase == Phase.MODE:
		if Input.is_action_pressed("ui_up") or Input.is_action_pressed("move_up"):
			want = -1
		elif Input.is_action_pressed("ui_down") or Input.is_action_pressed("move_down"):
			want = 1
	else:
		if Input.is_action_pressed("move_left") or Input.is_action_pressed("ui_left"):
			want = -1
		elif Input.is_action_pressed("move_right") or Input.is_action_pressed("ui_right"):
			want = 1

	if want == 0:
		_nav_held_dir = 0; _nav_hold_time = 0.0; _nav_repeat_acc = 0.0
	elif want != _nav_held_dir:
		_nav_held_dir = want; _nav_hold_time = 0.0; _nav_repeat_acc = 0.0
		if _phase == Phase.MODE:
			_mode_focus = 1 if want > 0 else 0
			_update_mode_focus()
		else:
			_move_icon(1, want)
	else:
		_nav_hold_time += delta
		if _nav_hold_time >= NAV_INITIAL_DELAY:
			_nav_repeat_acc += delta
			while _nav_repeat_acc >= NAV_REPEAT_RATE:
				_nav_repeat_acc -= NAV_REPEAT_RATE
				if _phase == Phase.MODE:
					_mode_focus = 1 if _nav_held_dir > 0 else 0
					_update_mode_focus()
				else:
					_move_icon(1, _nav_held_dir)

	if _phase != Phase.ASSIGN:
		return
	if _blocked_flash > 0.0:
		_blocked_flash -= delta
		if _blocked_flash <= 0.0:
			_refresh_assign()
	_animate_icon(_p1_icon, _p1_slot, P1_ROW_Y, _p1_locked, delta)
	_animate_icon(_p2_icon, _p2_slot, P2_ROW_Y, _p2_locked, delta)
	if _press_start_label.visible:
		# Gentle pulse on the PRESS START prompt.
		var t: float = 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.006)
		_press_start_label.modulate = Color(1, 1, 1, 0.55 + 0.45 * t)


func _animate_icon(icon: Control, slot: int, row_y: float, locked: bool, delta: float) -> void:
	if icon == null:
		return
	var target := Vector2(_col_x[slot] - ICON_SIZE.x * 0.5, row_y)
	icon.position = icon.position.lerp(target, clampf(14.0 * delta, 0.0, 1.0))
	icon.modulate = COLOR_READY if locked else Color(1, 1, 1, 1)


# ---------------------------------------------------------------------------
# Confirm / navigate
# ---------------------------------------------------------------------------
func _on_one_player() -> void:
	RunState.two_player = false
	RunState.shino_device = -1
	RunState.bea_device = -1
	_goto_save_select()


func _on_two_player() -> void:
	_show_phase(Phase.ASSIGN)


func _confirm_assign() -> void:
	# Run 74 — final binding from whatever Godot sees right now (a pad may have
	# come online since we entered this screen). Non-force: keeps any pad a
	# player actively claimed, fills only still-keyboard slots.
	_rescan_devices(false)
	# who controls Shino? whichever player's icon is on the Shino slot.
	var who_shino: String = "p1" if _p1_slot == SLOT_SHINO else "p2"
	RunState.setup_two_player(_p1_device, _p2_device, who_shino)
	print("[PlayerSetup] 2P start — Shino=%s(dev %d) Bea=dev %d" % [
		who_shino, RunState.shino_device, RunState.bea_device])
	_goto_save_select()


func _goto_save_select() -> void:
	if _starting:
		return
	_starting = true
	if get_node_or_null("/root/FX") and FX.has_method("fade_to_black"):
		FX.fade_to_black(0.30, 0.05, 1.0, Callable(self, "_do_save_select"))
	else:
		_do_save_select()


func _do_save_select() -> void:
	if not ResourceLoader.exists(SAVE_SELECT_PATH):
		push_error("[PlayerSetup] SaveFileSelect.tscn missing.")
		_starting = false
		return
	get_tree().change_scene_to_file(SAVE_SELECT_PATH)


func _back_to_menu() -> void:
	if get_node_or_null("/root/FX") and FX.has_method("fade_to_black"):
		FX.fade_to_black(0.20, 0.05, 1.0, func(): get_tree().change_scene_to_file(MAIN_MENU_PATH))
	else:
		get_tree().change_scene_to_file(MAIN_MENU_PATH)


# ---------------------------------------------------------------------------
# Button styling (matches MainMenu / SaveFileSelect palette)
# ---------------------------------------------------------------------------
func _style_button(btn: Button) -> void:
	var sb_normal := StyleBoxFlat.new()
	sb_normal.bg_color = Color(0.10, 0.09, 0.13, 0.94)
	for side in [SIDE_LEFT, SIDE_RIGHT, SIDE_TOP, SIDE_BOTTOM]:
		sb_normal.set_border_width(side, 2)
	sb_normal.border_color = COLOR_GOLD_BORDER
	sb_normal.corner_radius_top_left = 6; sb_normal.corner_radius_top_right = 6
	sb_normal.corner_radius_bottom_left = 6; sb_normal.corner_radius_bottom_right = 6
	sb_normal.content_margin_left = 22; sb_normal.content_margin_right = 22
	sb_normal.content_margin_top = 10; sb_normal.content_margin_bottom = 10

	var sb_focus := sb_normal.duplicate()
	sb_focus.border_color = COLOR_GOLD_BRIGHT
	for side in [SIDE_LEFT, SIDE_RIGHT, SIDE_TOP, SIDE_BOTTOM]:
		sb_focus.set_border_width(side, 3)
	sb_focus.bg_color = Color(0.16, 0.14, 0.18, 0.96)
	sb_focus.shadow_color = Color(COLOR_GOLD_BRIGHT.r, COLOR_GOLD_BRIGHT.g, COLOR_GOLD_BRIGHT.b, 0.45)
	sb_focus.shadow_size = 6

	btn.add_theme_stylebox_override("normal", sb_normal)
	btn.add_theme_stylebox_override("hover", sb_focus)
	btn.add_theme_stylebox_override("focus", sb_focus)
	btn.add_theme_stylebox_override("pressed", sb_focus)
	btn.add_theme_color_override("font_color", COLOR_GOLD_BORDER)
	btn.add_theme_color_override("font_hover_color", COLOR_GOLD_BRIGHT)
	btn.add_theme_color_override("font_focus_color", COLOR_GOLD_BRIGHT)
