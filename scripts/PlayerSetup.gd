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

# Run N+2a — 2 PLAYERS now asks HOW the two players are connected before it
# asks WHO they are:
#   MODE     1 player / 2 players
#   NETMODE  local co-op (same screen) / LAN / online       [2P only]
#   LOBBY    host or join, via NetLobby.gd                  [LAN + online only]
#   ASSIGN   the two controller icons picking ninjas        (unchanged)
enum Phase { MODE, NETMODE, LOBBY, ASSIGN }
var _phase: int = Phase.MODE

# Mode-phase buttons
var _btn_1p: Button = null
var _btn_2p: Button = null
var _mode_focus: int = 0   # default highlight 1 PLAYER

# --- NETMODE phase (Run N+2a) ---------------------------------------
const NET_LOBBY_SCRIPT: String = "res://scripts/net/NetLobby.gd"
var _netmode_root: Control = null
var _netmode_btns: Array = []      # [local, lan, online]
var _netmode_focus: int = 0
var _lobby: Control = null         # live NetLobby instance while in Phase.LOBBY

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
const NAV_DEADZONE:      float = 0.5
# MODE phase uses one shared (any-device) cursor.
var _nav_held_dir: int   = 0
var _nav_hold_time: float = 0.0
var _nav_repeat_acc: float = 0.0
# Run 161 — ASSIGN phase: one INDEPENDENT nav state per player, index 0 = P1,
# 1 = P2. Each is fed by that player's device ONLY, so one controller can never
# drive both icons.
var _pnav_dir: Array = [0, 0]
var _pnav_hold: Array = [0.0, 0.0]
var _pnav_acc:  Array = [0.0, 0.0]


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
	# Run 164c — apply the "Ink & Washi" skin to everything built below.
	UISkin.skin_tree_deferred(self)
	_build_background()
	_build_mode_phase()
	_build_netmode_phase()
	_build_assign_phase()
	# Leaving this screen for any reason drops any half-made connection, so a
	# player who backs out of a lobby never leaves a socket open behind them.
	tree_exiting.connect(func() -> void:
		if _phase != Phase.ASSIGN and Net.is_online() and not Net.is_connected_pair():
			Net.leave())
	_show_phase(Phase.MODE)
	# Run 74 — pick up controllers that connect (or that Steam hands over) AFTER
	# this screen has loaded, so device binding doesn't depend on enumeration
	# timing.
	if not Input.joy_connection_changed.is_connected(_on_joy_changed):
		Input.joy_connection_changed.connect(_on_joy_changed)
	# Run N+2b — the guest's character-select screen is driven by the host.
	Net.menu_message.connect(_on_menu_message)
	Net.guest_left.connect(_on_partner_left)
	Net.session_failed.connect(func(_r: String) -> void: _on_partner_left("lost"))


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
	# Run 164c — each phase rebuilds its own children; re-skin them.
	UISkin.skin_tree_deferred(self)
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
# NETMODE phase (Run N+2a) — how are the two players connected?
# ---------------------------------------------------------------------------
func _build_netmode_phase() -> void:
	# Run 164c — each phase rebuilds its own children; re-skin them.
	UISkin.skin_tree_deferred(self)
	_netmode_root = Control.new()
	_netmode_root.anchor_right = 1.0
	_netmode_root.anchor_bottom = 1.0
	_netmode_root.visible = false
	add_child(_netmode_root)

	var sub := Label.new()
	sub.text = "How are you two playing?"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.anchor_right = 1.0
	sub.offset_top = 150.0
	sub.offset_bottom = 182.0
	sub.add_theme_color_override("font_color", Color(0.65, 0.60, 0.75, 0.85))
	sub.add_theme_font_size_override("font_size", 18)
	_netmode_root.add_child(sub)

	_netmode_btns = [
		_make_netmode_button("LOCAL CO-OP", "Two controllers. One screen. One PC.", 236.0),
		_make_netmode_button("LAN", "Two PCs on the same wifi or router. No codes.", 336.0),
		_make_netmode_button("ONLINE", "Two PCs anywhere. The host sends a join code.", 436.0),
	]
	_netmode_btns[0].pressed.connect(_on_local_coop)
	_netmode_btns[1].pressed.connect(_on_lan)
	_netmode_btns[2].pressed.connect(_on_online)

	var hint := Label.new()
	hint.text = "↑/↓ choose   ENTER / A select   ESC back"
	hint.anchor_top = 1.0
	hint.anchor_right = 1.0
	hint.anchor_bottom = 1.0
	hint.offset_left = 16.0
	hint.offset_top = -32.0
	hint.offset_bottom = -10.0
	hint.add_theme_color_override("font_color", Color(0.60, 0.55, 0.70, 0.70))
	hint.add_theme_font_size_override("font_size", 13)
	_netmode_root.add_child(hint)


func _make_netmode_button(txt: String, blurb: String, y: float) -> Button:
	var b := Button.new()
	b.text = txt
	b.position = Vector2(640 - 340, y)
	b.size = Vector2(680, 60)
	b.focus_mode = Control.FOCUS_NONE   # highlight is driven by _netmode_focus
	_style_button(b)
	b.add_theme_font_size_override("font_size", 27)
	_netmode_root.add_child(b)

	var sub := Label.new()
	sub.text = blurb
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.position = Vector2(640 - 340, y + 60.0)
	sub.size = Vector2(680, 22)
	sub.add_theme_color_override("font_color", Color(0.58, 0.55, 0.66, 0.85))
	sub.add_theme_font_size_override("font_size", 14)
	_netmode_root.add_child(sub)
	return b


func _refresh_netmode_focus() -> void:
	for i in range(_netmode_btns.size()):
		var b: Button = _netmode_btns[i]
		if not is_instance_valid(b):
			continue
		b.add_theme_color_override("font_color",
			COLOR_GOLD_BRIGHT if i == _netmode_focus else Color(0.80, 0.78, 0.86))
		b.modulate = Color(1, 1, 1, 1) if i == _netmode_focus else Color(0.78, 0.76, 0.84, 1)


# ---------------------------------------------------------------------------
# ASSIGN phase
# ---------------------------------------------------------------------------
func _build_assign_phase() -> void:
	# Run 164c — each phase rebuilds its own children; re-skin them.
	UISkin.skin_tree_deferred(self)
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
	_netmode_root.visible = (p == Phase.NETMODE)
	_assign_root.visible = (p == Phase.ASSIGN)
	if mode_vis:
		_update_mode_focus()
	else:
		# Drop focus so the now-hidden mode buttons can't eat ui_accept.
		get_viewport().gui_release_focus()
		if p == Phase.NETMODE:
			_netmode_focus = 0
			_refresh_netmode_focus()
			# Clear the shared nav latch so a stick still held from the mode
			# screen does not immediately slide the highlight on arrival.
			_nav_held_dir = 0; _nav_hold_time = 0.0; _nav_repeat_acc = 0.0
			return
		if p == Phase.LOBBY:
			return
		_init_assign_devices()
		# Both icons begin on the centre (no-ninja) slot — neither player is
		# pre-assigned, so either may pick Shino or Bea. (Bruno 2026-08-18)
		_p1_slot = SLOT_NONE
		_p2_slot = SLOT_NONE
		_p1_locked = false
		_p2_locked = false
		_blocked_flash = 0.0
		# Run 161 — clear per-player nav so a stick still held from the mode
		# screen doesn't immediately slide an icon on arrival.
		_pnav_dir = [0, 0]; _pnav_hold = [0.0, 0.0]; _pnav_acc = [0.0, 0.0]
		_nav_held_dir = 0; _nav_hold_time = 0.0; _nav_repeat_acc = 0.0
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
	elif _phase == Phase.NETMODE:
		_input_netmode(event)
	elif _phase == Phase.LOBBY:
		pass   # NetLobby owns its own input while it is up
	else:
		_input_assign(event)


func _input_netmode(event: InputEvent) -> void:
	if event.is_action_pressed("ui_up") or event.is_action_pressed("move_up") \
	or event.is_action_pressed("ui_down") or event.is_action_pressed("move_down"):
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		if _netmode_focus >= 0 and _netmode_focus < _netmode_btns.size():
			(_netmode_btns[_netmode_focus] as Button).pressed.emit()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel"):
		_show_phase(Phase.MODE)
		get_viewport().set_input_as_handled()


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


# True when a joypad event represents real intent (a button going down, or a
# stick pushed past the nav deadzone) rather than idle drift. Used to decide
# whether a pad may claim a player slot — see _claim_pad.
func _pad_event_is_active(event: InputEvent) -> bool:
	if event is InputEventJoypadButton:
		return event.pressed
	if event is InputEventJoypadMotion:
		return absf(event.axis_value) >= NAV_DEADZONE
	return false


# ---------------------------------------------------------------------------
# Run 74 — robust device binding
# ---------------------------------------------------------------------------
# Re-derive P1/P2 devices from what Godot currently enumerates.
#   force = true  : entering the screen — take the defaults wholesale.
#   force = false : a controller (dis)connected mid-screen — only fill slots
#                   that are still keyboard, never steal a pad a player already
#                   claimed by pressing on it.
# Run 165 (Bruno 2026-08-18) — LOCAL co-op now uses PRESS-TO-JOIN binding.
# The old path pre-bound P1/P2 from Input.get_connected_joypads() ORDER, which
# was fragile: phantom / multi-interface pads and mid-screen connect ordering
# could leave a real second controller bound to nothing ("P2 not detected"),
# and which physical pad was P1 vs P2 depended on device-id order, not on the
# player. Now nothing is pre-bound: the first distinct device to actually move
# a stick or press a button claims Player 1 (top icon), the next distinct
# device claims Player 2 (bottom icon). Keyboard stays a valid slot throughout,
# so keyboard-only and keyboard+1-pad play still work with zero setup.
#
# ONLINE is unchanged: the host still needs device 900 wired to P2 and the
# guest's screen is a pure mirror, so both keep the deterministic rescan.
func _init_assign_devices() -> void:
	if _online_host() or _online_guest():
		_rescan_devices(true)
		return
	# Local co-op: default both slots to the keyboard (A/D drives the top icon,
	# ← / → drives the bottom one) and let real controllers claim slots on press.
	_p1_device = InputRouter.KEYBOARD_DEVICE
	_p2_device = InputRouter.KEYBOARD_DEVICE
	_update_device_readout()


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

	# Run N+2b — online: Player 2 is not a pad on this PC, they are on the other
	# end of the wire. Their input arrives as InputRouter device 900. This runs
	# AFTER the local scan on purpose, so a controller plugged into the host's
	# machine can never be re-bound over the remote player's slot.
	if _online_host():
		_p2_device = InputRouter.NET_DEVICE_REMOTE
		# Only one human is at this keyboard, so P1 keeps it outright.
		if _p1_device == InputRouter.NET_DEVICE_REMOTE:
			_p1_device = -1
	_update_device_readout()


# True when this machine is the host of a live online session. The guest's
# copy of this screen is a mirror and never decides anything.
func _online_host() -> bool:
	return Net.is_connected_pair() and Net.is_host()


func _online_guest() -> bool:
	return Net.is_connected_pair() and not Net.is_host()


# A real pad event arrived. Bind that pad to a player slot. Keyboard is kept as
# Player 1 whenever a human is using it, so the pad fills Player 2 first — this
# honors "keyboard = P1, controller = P2". With two pads, each distinct id ends
# up on its own slot (and on its own ninja).
func _claim_pad(dev: int) -> void:
	if dev < 0:
		return
	if dev == _p1_device or dev == _p2_device:
		return
	# Run 165 — press-to-join: first distinct real pad → Player 1 (top icon),
	# next distinct pad → Player 2 (bottom icon). A slot still on the keyboard
	# (-1) counts as free for a pad to take; keyboard players keep whichever slot
	# no pad has claimed. (Online host keeps P2 = device 900, so a second local
	# pad there can never steal the remote player's slot.)
	if _p1_device < 0:
		_p1_device = dev
	elif _p2_device < 0 or _p2_device == _p1_device:
		_p2_device = dev
	else:
		return
	_update_device_readout()


func _on_joy_changed(_device: int, _connected: bool) -> void:
	if _phase != Phase.ASSIGN:
		return
	# Online keeps the deterministic rescan (host must hold device 900 on P2).
	# Local co-op binds on press, so a pad that connects mid-screen just refreshes
	# the readout and waits for its player to move it — see _claim_pad.
	if _online_host() or _online_guest():
		_rescan_devices(false)
	else:
		_update_device_readout()


# Run N+2b — the other player dropped while we were still setting up. Rather
# than sit on a half-live screen, fall back to the connection step so they can
# reconnect (or so this player can switch to local co-op).
func _on_partner_left(_reason: String) -> void:
	if _phase != Phase.ASSIGN and _phase != Phase.LOBBY:
		return
	InputRouter.clear_remote()
	var hold := get_node_or_null("GuestHold")
	if hold != null:
		hold.queue_free()
	_last_sent_assign = []
	_close_lobby()
	_show_phase(Phase.NETMODE)


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
	# Run N+2b — the guest decides nothing here, and must NOT consume the event:
	# InputRouter is an autoload, so it sees input AFTER the current scene does.
	# Calling set_input_as_handled() on this screen would stop the guest's own
	# button presses from ever reaching InputRouter, and NetInput would have
	# nothing to send. Return early, touch nothing, swallow nothing.
	if _online_guest():
		return

	var dev: int = _norm_device(event)

	# Run 74 / 165 — a real pad claims a player slot the moment its player acts.
	# Gate on a MEANINGFUL action (a button going down, or a stick pushed past the
	# nav deadzone) so idle stick drift never silently binds an untouched pad to a
	# slot before its player has actually picked it up.
	if dev >= 0 and _pad_event_is_active(event):
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

	# --- HOVER MOVEMENT ------------------------------------------------------
	# Run 161 — movement is handled ENTIRELY by per-device polling in _process().
	# Events are only consumed here so the focus system / mode buttons don't also
	# react. Do NOT move icons from events: action events are device-merged for
	# the keyboard and it is far too easy to end up moving both icons at once.
	if event.is_action_pressed("move_left") or event.is_action_pressed("move_right") \
	or event.is_action_pressed("ui_left") or event.is_action_pressed("ui_right"):
		get_viewport().set_input_as_handled()

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
	# Run 165 — the centre slot is "no ninja chosen yet". Pressing A there does
	# nothing; the player must hover Shino (left) or Bea (right) first. The status
	# line already reads "Hover a ninja and press A to lock in".
	if slot == SLOT_NONE:
		return
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


# ---------------------------------------------------------------------------
# Run N+2b — networked character select
# ---------------------------------------------------------------------------
# PARITY LOCK (Online_Multiplayer_Spec.md §0.5): this screen behaves the same
# online as it does locally. Both icons are live, each player moves their own,
# A locks in, B un-locks, START begins. The only difference is that Player 2's
# stick arrives over the wire instead of over USB.
#
# The remote player produces no InputEvents, so their buttons are polled here
# from InputRouter device 900 rather than handled in _input_assign.
func _tick_remote_buttons() -> void:
	var dev: int = InputRouter.NET_DEVICE_REMOTE
	if InputRouter.just_pressed(dev, "ui_accept"):
		if _both_locked():
			_confirm_assign()      # either player may start, same as local 2P
		else:
			_try_lock(2)
	elif InputRouter.just_pressed(dev, "ui_cancel"):
		if _p2_locked:
			_unlock(2)


# Push the authoritative screen state to the guest, but only when it actually
# changes — this runs every frame and the channel is reliable.
var _last_sent_assign: Array = []

func _broadcast_assign() -> void:
	var snap: Array = [_p1_slot, _p2_slot, _p1_locked, _p2_locked, _blocked_flash > 0.0]
	if snap == _last_sent_assign:
		return
	_last_sent_assign = snap
	Net.send_menu("assign", {
		"p1s": _p1_slot, "p2s": _p2_slot,
		"p1l": _p1_locked, "p2l": _p2_locked,
		"blk": _blocked_flash > 0.0,
	})


# Guest side. The host is authoritative, but "authoritative" is not "trusted":
# every value is range-checked before it touches the UI.
func _on_menu_message(kind: String, data: Dictionary) -> void:
	match kind:
		"assign":
			if _phase != Phase.ASSIGN:
				return
			_p1_slot = clampi(int(data.get("p1s", SLOT_SHINO)), SLOT_SHINO, SLOT_BEA)
			_p2_slot = clampi(int(data.get("p2s", SLOT_BEA)), SLOT_SHINO, SLOT_BEA)
			_p1_locked = bool(data.get("p1l", false))
			_p2_locked = bool(data.get("p2l", false))
			_blocked_flash = 1.1 if bool(data.get("blk", false)) else 0.0
			_refresh_assign()
		"assign_done":
			_show_guest_hold()


# After both ninjas are locked, the host picks the save file — the run lives in
# THEIR file and the guest is Player 2 inside it (spec §7 decision #10). There
# is nothing for the guest to choose, so they get told what is happening rather
# than being dropped on a dead screen.
func _show_guest_hold() -> void:
	if get_node_or_null("GuestHold") != null:
		return
	var panel := ColorRect.new()
	panel.name = "GuestHold"
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.color = Color(0.04, 0.03, 0.06, 0.88)
	add_child(panel)

	var label := Label.new()
	label.text = "Ninjas locked in.\n\nWaiting for the host to choose a save file…"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.anchor_right = 1.0
	label.anchor_bottom = 1.0
	label.add_theme_color_override("font_color", COLOR_GOLD_BRIGHT)
	label.add_theme_font_size_override("font_size", 26)
	panel.add_child(label)


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


# ---------------------------------------------------------------------------
# Run 161 — per-player horizontal nav read, device-scoped.
# A player is driven by their OWN device and nothing else:
#   dev >= 0 : that pad's left stick X + that pad's d-pad, read with the
#              per-device Input.get_joy_* calls (never the merged actions).
#   dev == -1: the keyboard, split by physical key so two people can share it —
#              A/D = Player 1, ← / → = Player 2. Physical keys are used (not the
#              ui_left/move_left actions) because those actions ALSO carry
#              joypad d-pad bindings, which is exactly how one controller ended
#              up moving both icons.
# ---------------------------------------------------------------------------
func _nav_dir_for(player: int) -> int:
	var dev: int = _p1_device if player == 1 else _p2_device
	# Degenerate case: both slots resolved to the same pad (shouldn't happen, but
	# never let one pad drive two icons) — the pad drives P1 only.
	if player == 2 and dev >= 0 and dev == _p1_device:
		dev = -1
	# Run N+2b — the online partner. Their stick was pushed in over the wire, so
	# it is read from the stored vector rather than polled from hardware. Same
	# deadzone, same feel, same code path from here down.
	if dev == InputRouter.NET_DEVICE_REMOTE:
		var rx: float = InputRouter.move_vector(dev).x
		if rx <= -NAV_DEADZONE:
			return -1
		if rx >= NAV_DEADZONE:
			return 1
		return 0
	if dev >= 0:
		var ax: float = Input.get_joy_axis(dev, JOY_AXIS_LEFT_X)
		if ax <= -NAV_DEADZONE or Input.is_joy_button_pressed(dev, JOY_BUTTON_DPAD_LEFT):
			return -1
		if ax >= NAV_DEADZONE or Input.is_joy_button_pressed(dev, JOY_BUTTON_DPAD_RIGHT):
			return 1
		return 0
	# Keyboard slot.
	if player == 1:
		if Input.is_physical_key_pressed(KEY_A):
			return -1
		if Input.is_physical_key_pressed(KEY_D):
			return 1
	else:
		if Input.is_physical_key_pressed(KEY_LEFT):
			return -1
		if Input.is_physical_key_pressed(KEY_RIGHT):
			return 1
	return 0


# Edge + hold-repeat gating for one player's hover cursor.
func _tick_player_nav(player: int, delta: float) -> void:
	var i: int = player - 1
	var want: int = _nav_dir_for(player)
	if want == 0:
		_pnav_dir[i] = 0; _pnav_hold[i] = 0.0; _pnav_acc[i] = 0.0
		return
	if want != int(_pnav_dir[i]):
		_pnav_dir[i] = want; _pnav_hold[i] = 0.0; _pnav_acc[i] = 0.0
		_move_icon(player, want)
		return
	_pnav_hold[i] = float(_pnav_hold[i]) + delta
	if float(_pnav_hold[i]) < NAV_INITIAL_DELAY:
		return
	_pnav_acc[i] = float(_pnav_acc[i]) + delta
	while float(_pnav_acc[i]) >= NAV_REPEAT_RATE:
		_pnav_acc[i] = float(_pnav_acc[i]) - NAV_REPEAT_RATE
		_move_icon(player, want)


func _process(delta: float) -> void:
	# ── MODE phase: shared cursor, any device may drive it ───────
	if _phase == Phase.MODE:
		var want: int = 0
		if Input.is_action_pressed("ui_up") or Input.is_action_pressed("move_up"):
			want = -1
		elif Input.is_action_pressed("ui_down") or Input.is_action_pressed("move_down"):
			want = 1
		if want == 0:
			_nav_held_dir = 0; _nav_hold_time = 0.0; _nav_repeat_acc = 0.0
		elif want != _nav_held_dir:
			_nav_held_dir = want; _nav_hold_time = 0.0; _nav_repeat_acc = 0.0
			_mode_focus = 1 if want > 0 else 0
			_update_mode_focus()
		else:
			_nav_hold_time += delta
			if _nav_hold_time >= NAV_INITIAL_DELAY:
				_nav_repeat_acc += delta
				while _nav_repeat_acc >= NAV_REPEAT_RATE:
					_nav_repeat_acc -= NAV_REPEAT_RATE
					_mode_focus = 1 if _nav_held_dir > 0 else 0
					_update_mode_focus()
		return

	# ── NETMODE phase: same shared cursor, three rows ────────────
	if _phase == Phase.NETMODE:
		var nwant: int = 0
		if Input.is_action_pressed("ui_up") or Input.is_action_pressed("move_up"):
			nwant = -1
		elif Input.is_action_pressed("ui_down") or Input.is_action_pressed("move_down"):
			nwant = 1
		if nwant == 0:
			_nav_held_dir = 0; _nav_hold_time = 0.0; _nav_repeat_acc = 0.0
		elif nwant != _nav_held_dir:
			_nav_held_dir = nwant; _nav_hold_time = 0.0; _nav_repeat_acc = 0.0
			_netmode_focus = posmod(_netmode_focus + nwant, _netmode_btns.size())
			_refresh_netmode_focus()
		else:
			_nav_hold_time += delta
			if _nav_hold_time >= NAV_INITIAL_DELAY:
				_nav_repeat_acc += delta
				while _nav_repeat_acc >= NAV_REPEAT_RATE:
					_nav_repeat_acc -= NAV_REPEAT_RATE
					_netmode_focus = posmod(_netmode_focus + _nav_held_dir, _netmode_btns.size())
					_refresh_netmode_focus()
		return

	if _phase != Phase.ASSIGN:
		return

	# ── ASSIGN phase: each player polls their own device only ────
	# Run N+2b — the guest's copy is a pure mirror. It renders whatever the host
	# sends and decides nothing, which is the same host-authoritative rule the
	# rest of the game follows. Its player still moves their own icon: their
	# stick goes out through NetInput, the host moves P2, and the result comes
	# straight back as an "assign" menu message.
	# Decision layer — skipped entirely on the guest. The animation below still
	# runs for them, so their screen moves and pulses exactly like the host's.
	if not _online_guest():
		_tick_player_nav(1, delta)
		_tick_player_nav(2, delta)
		if _online_host():
			_tick_remote_buttons()
			_broadcast_assign()
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
	_show_phase(Phase.NETMODE)


# --- NETMODE choices (Run N+2a) --------------------------------------------
func _on_local_coop() -> void:
	# Exactly the behaviour that existed before online was added.
	Net.leave()
	_show_phase(Phase.ASSIGN)


func _on_lan() -> void:
	_open_lobby(true)


func _on_online() -> void:
	_open_lobby(false)


func _open_lobby(lan: bool) -> void:
	if _lobby != null and is_instance_valid(_lobby):
		_lobby.queue_free()
	var script: Script = load(NET_LOBBY_SCRIPT)
	if script == null:
		push_error("[PlayerSetup] %s missing — falling back to local co-op." % NET_LOBBY_SCRIPT)
		_on_local_coop()
		return
	_lobby = Control.new()
	_lobby.set_script(script)
	_lobby.call("setup", lan)
	_lobby.connect("proceed", Callable(self, "_on_lobby_proceed"))
	_lobby.connect("cancelled", Callable(self, "_on_lobby_cancelled"))
	add_child(_lobby)
	_show_phase(Phase.LOBBY)


func _on_lobby_proceed() -> void:
	_close_lobby()
	# PARITY LOCK (Online_Multiplayer_Spec.md §0.5): character select is the
	# same screen with the same rules online as it is locally. Until the input
	# pipe lands (Run N+3) only the host's two icons are live, so the host
	# drives this screen and the guest waits — see §12 of the spec.
	_show_phase(Phase.ASSIGN)


func _on_lobby_cancelled() -> void:
	_close_lobby()
	_show_phase(Phase.NETMODE)


func _close_lobby() -> void:
	if _lobby != null and is_instance_valid(_lobby):
		_lobby.queue_free()
	_lobby = null


func _confirm_assign() -> void:
	# The guest never reaches this — the host confirms for both (spec §7 #10).
	if _online_guest():
		return
	# Run 165 — local co-op already bound each slot to the device its player used
	# during selection (press-to-join), so do NOT rescan here: a stray idle pad
	# must never be bound over a player who picked with the keyboard. Online still
	# rescans so a host pad that came online late is honoured (P2 stays device 900).
	if _online_host():
		_rescan_devices(false)
	# who controls Shino? whichever player's icon is on the Shino slot.
	var who_shino: String = "p1" if _p1_slot == SLOT_SHINO else "p2"
	RunState.setup_two_player(_p1_device, _p2_device, who_shino)
	if _online_host():
		# Tell the guest their pick landed before this screen goes away.
		Net.send_menu("assign_done", {})
	Log.dbg("[PlayerSetup] 2P start — Shino=%s(dev %d) Bea=dev %d" % [
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
