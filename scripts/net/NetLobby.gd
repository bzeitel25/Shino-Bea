extends Control
# ============================================================
# NetLobby.gd — the LAN / Online lobby screen  (Run N+2a)
# ============================================================
# A self-contained Control that PlayerSetup drops in as an overlay after the
# player picks LAN or ONLINE. It owns its own input and its own focus, so none
# of PlayerSetup's delicate Run-161 per-device navigation had to be touched.
#
# Two flavours, one file:
#   LAN     — host broadcasts a beacon; the joiner picks a game from a live
#             list. Zero typing, no codes, no IP addresses.
#   ONLINE  — host gets a join code to paste to a friend; the joiner pastes it
#             back. Same handshake either way.
#
# Contract with PlayerSetup:
#   emits proceed()   — a friend is connected; continue to character select
#   emits cancelled() — player backed out; tear down and return to the mode step
#
# Built in code (PanelContainer > VBoxContainer, per the Run 158 convention) to
# match the rest of this project's UI, and never uses `anchors_preset =` in
# code (Run 137: that is a no-op — always set_anchors_and_offsets_preset()).
# ============================================================

const NetSecurity := preload("res://scripts/net/NetSecurity.gd")
const NetProtocol := preload("res://scripts/net/NetProtocol.gd")

signal proceed()
signal cancelled()

const COLOR_GOLD_BRIGHT: Color = Color(1.00, 0.88, 0.40, 1.0)
const COLOR_DIM:         Color = Color(0.62, 0.58, 0.72, 0.85)
const COLOR_GOOD:        Color = Color(0.45, 0.95, 0.55, 1.0)
const COLOR_BAD:         Color = Color(0.95, 0.45, 0.45, 1.0)
const COLOR_PANEL:       Color = Color(0.10, 0.09, 0.13, 0.96)
const COLOR_BORDER:      Color = Color(0.85, 0.70, 0.25, 1.0)

# Nav repeat, matched to PlayerSetup so the two screens feel the same.
const NAV_INITIAL_DELAY: float = 0.45
const NAV_REPEAT_RATE:   float = 0.14

enum Step { CHOOSE, HOSTING, BROWSING, CODE_ENTRY }

var lan_mode: bool = true

var _step: int = Step.CHOOSE
var _title: Label = null
var _subtitle: Label = null
var _status: Label = null
var _list_box: VBoxContainer = null
var _code_box: LineEdit = null
var _hint: Label = null

# Focusable rows for the current step: {label: String, action: Callable}
var _rows: Array = []
var _row_nodes: Array = []
var _focus: int = 0

var _nav_dir: int = 0
var _nav_hold: float = 0.0
var _nav_acc: float = 0.0

var _lobbies: Array = []
var _done: bool = false


func setup(p_lan: bool) -> void:
	lan_mode = p_lan


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	Net.state_changed.connect(_on_net_state)
	Net.session_failed.connect(_on_net_failed)
	Net.guest_joined.connect(_on_guest_joined)
	NetDiscovery.lobbies_changed.connect(_on_lobbies_changed)
	_show_step(Step.CHOOSE)


func _exit_tree() -> void:
	NetDiscovery.stop_advertising()
	NetDiscovery.stop_browsing()


# ============================================================
# Build
# ============================================================
func _build() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(720, 0)
	panel.offset_left = -360.0
	panel.offset_top = -230.0
	panel.offset_right = 360.0
	var sb := StyleBoxFlat.new()
	sb.bg_color = COLOR_PANEL
	sb.border_color = COLOR_BORDER
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(26)
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	panel.add_child(vb)

	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_color_override("font_color", COLOR_GOLD_BRIGHT)
	_title.add_theme_font_size_override("font_size", 34)
	vb.add_child(_title)

	_subtitle = Label.new()
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_subtitle.custom_minimum_size = Vector2(660, 0)
	_subtitle.add_theme_color_override("font_color", COLOR_DIM)
	_subtitle.add_theme_font_size_override("font_size", 16)
	vb.add_child(_subtitle)

	_code_box = LineEdit.new()
	_code_box.placeholder_text = "paste the join code here"
	_code_box.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_code_box.visible = false
	_code_box.add_theme_font_size_override("font_size", 18)
	vb.add_child(_code_box)

	_list_box = VBoxContainer.new()
	_list_box.add_theme_constant_override("separation", 6)
	vb.add_child(_list_box)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(660, 44)
	_status.add_theme_font_size_override("font_size", 15)
	vb.add_child(_status)

	_hint = Label.new()
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_color_override("font_color", Color(0.55, 0.52, 0.64, 0.8))
	_hint.add_theme_font_size_override("font_size", 13)
	vb.add_child(_hint)


# ============================================================
# Steps
# ============================================================
func _show_step(s: int) -> void:
	_step = s
	_focus = 0
	_rows.clear()
	_code_box.visible = false

	match s:
		Step.CHOOSE:
			_title.text = "LAN GAME" if lan_mode else "ONLINE GAME"
			if lan_mode:
				_subtitle.text = "Both PCs on the same wifi or router. No codes, no setup."
			else:
				_subtitle.text = "Playing with someone somewhere else. The host sends a join code."
			_rows = [
				{"label": "HOST A GAME", "action": Callable(self, "_do_host")},
				{"label": "JOIN A GAME", "action": Callable(self, "_do_join")},
			]
			_set_status("", COLOR_DIM)
			_hint.text = "↑/↓ choose      ENTER / A select      ESC back"

		Step.HOSTING:
			_title.text = "WAITING FOR YOUR FRIEND"
			if lan_mode:
				_subtitle.text = "Your game is visible to anyone on this network.\n" \
					+ "On the other PC: 2 PLAYERS → LAN → JOIN A GAME."
			else:
				_subtitle.text = "Send this code to your friend. They pick 2 PLAYERS → ONLINE → JOIN."
			_rows = [{"label": "CANCEL", "action": Callable(self, "_do_cancel")}]
			if not lan_mode:
				_rows.push_front({"label": "COPY JOIN CODE", "action": Callable(self, "_do_copy")})
			_hint.text = "ENTER / A select      ESC cancel"

		Step.BROWSING:
			_title.text = "GAMES ON YOUR NETWORK"
			_subtitle.text = "Looking for a host nearby…"
			_rebuild_lobby_rows()
			_hint.text = "↑/↓ choose      ENTER / A join      ESC back"

		Step.CODE_ENTRY:
			_title.text = "JOIN WITH A CODE"
			_subtitle.text = "Paste the code your friend sent you."
			_code_box.visible = true
			_code_box.grab_focus()
			_rows = [
				{"label": "PASTE FROM CLIPBOARD", "action": Callable(self, "_do_paste")},
				{"label": "JOIN", "action": Callable(self, "_do_join_code")},
				{"label": "BACK", "action": Callable(self, "_do_back_to_choose")},
			]
			_set_status("", COLOR_DIM)
			_hint.text = "↑/↓ choose      ENTER / A select      ESC back"

	_rebuild_rows()


func _rebuild_lobby_rows() -> void:
	_rows.clear()
	for lobby in _lobbies:
		var nm: String = str(lobby.get("name", "Unknown"))
		_rows.append({
			"label": nm,
			"action": Callable(self, "_do_join_lobby").bind(lobby),
		})
	_rows.append({"label": "BACK", "action": Callable(self, "_do_back_to_choose")})
	if _lobbies.is_empty():
		_set_status("No games found yet. Make sure the other PC has started hosting,\n"
			+ "and that Windows Firewall allowed the game through.", COLOR_DIM)
	else:
		_set_status("Found %d game%s." % [_lobbies.size(), "" if _lobbies.size() == 1 else "s"],
			COLOR_GOOD)


func _rebuild_rows() -> void:
	for n in _row_nodes:
		if is_instance_valid(n):
			n.queue_free()
	_row_nodes.clear()
	for i in range(_rows.size()):
		var b := Button.new()
		b.text = str(_rows[i]["label"])
		b.focus_mode = Control.FOCUS_NONE   # we drive highlight ourselves
		b.add_theme_font_size_override("font_size", 22)
		_style_button(b)
		var idx: int = i
		b.pressed.connect(func() -> void:
			_focus = idx
			_activate())
		_list_box.add_child(b)
		_row_nodes.append(b)
	_focus = clampi(_focus, 0, maxi(0, _rows.size() - 1))
	_refresh_highlight()


func _refresh_highlight() -> void:
	for i in range(_row_nodes.size()):
		var b: Button = _row_nodes[i]
		if not is_instance_valid(b):
			continue
		b.modulate = Color(1, 1, 1, 1) if i == _focus else Color(0.72, 0.70, 0.78, 1)
		b.add_theme_color_override("font_color",
			COLOR_GOLD_BRIGHT if i == _focus else Color(0.80, 0.78, 0.86))


func _set_status(text: String, col: Color) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", col)


# ============================================================
# Actions
# ============================================================
func _do_host() -> void:
	var res: Dictionary = Net.host_online(NetSecurity.Mode.DIRECT, NetProtocol.DEFAULT_PORT)
	if not bool(res.get("ok", false)):
		_set_status(str(res.get("error", "Could not start hosting.")), COLOR_BAD)
		return
	_show_step(Step.HOSTING)
	if lan_mode:
		NetDiscovery.advertise(NetDiscovery.default_lobby_name(), Net.ticket)
		_set_status("Visible on your network as:  %s" % NetDiscovery.default_lobby_name(), COLOR_GOOD)
	else:
		_set_status(Net.ticket, COLOR_GOOD)


func _do_join() -> void:
	if lan_mode:
		_lobbies = []
		NetDiscovery.start_browsing()
		_show_step(Step.BROWSING)
	else:
		_show_step(Step.CODE_ENTRY)


func _do_join_lobby(lobby: Dictionary) -> void:
	NetDiscovery.stop_browsing()
	_set_status("Connecting to %s…" % str(lobby.get("name", "host")), COLOR_DIM)
	var res: Dictionary = Net.join_online(str(lobby.get("ticket", "")))
	if not bool(res.get("ok", false)):
		_set_status(str(res.get("error", "Could not connect.")), COLOR_BAD)
		# Fall back to the list so they can try another game.
		NetDiscovery.start_browsing()
		_show_step(Step.BROWSING)


func _do_join_code() -> void:
	var res: Dictionary = Net.join_online(_code_box.text)
	if not bool(res.get("ok", false)):
		_set_status(str(res.get("error", "Could not connect.")), COLOR_BAD)
	else:
		_set_status("Connecting…", COLOR_DIM)


func _do_paste() -> void:
	_code_box.text = DisplayServer.clipboard_get().strip_edges()


func _do_copy() -> void:
	if not Net.ticket.is_empty():
		DisplayServer.clipboard_set(Net.ticket)
		_set_status("Copied. Paste it to your friend.\n%s" % Net.ticket, COLOR_GOOD)


func _do_back_to_choose() -> void:
	NetDiscovery.stop_browsing()
	Net.leave()
	_show_step(Step.CHOOSE)


func _do_cancel() -> void:
	NetDiscovery.stop_advertising()
	NetDiscovery.stop_browsing()
	Net.leave()
	_show_step(Step.CHOOSE)


# ============================================================
# Net signals
# ============================================================
func _on_guest_joined(_peer: int) -> void:
	_finish("Your friend is in. Starting character select…")


func _on_net_state(_s: int) -> void:
	# The joining side confirms via CONNECTED; the host confirms via guest_joined.
	if _done:
		return
	if Net.is_connected_pair() and not Net.is_host():
		_finish("Connected. Starting character select…")


func _on_net_failed(reason: String) -> void:
	if _done:
		return
	_set_status(reason, COLOR_BAD)
	if _step == Step.HOSTING:
		_show_step(Step.CHOOSE)


func _on_lobbies_changed(list: Array) -> void:
	_lobbies = list
	if _step == Step.BROWSING:
		var keep: int = _focus
		_rebuild_lobby_rows()
		_focus = clampi(keep, 0, maxi(0, _rows.size() - 1))
		_rebuild_rows()


func _finish(msg: String) -> void:
	if _done:
		return
	_done = true
	_set_status(msg, COLOR_GOOD)
	NetDiscovery.stop_advertising()
	NetDiscovery.stop_browsing()
	# Small beat so the player reads the confirmation before the screen changes.
	var t := get_tree().create_timer(0.9, true, false, true)
	t.timeout.connect(func() -> void: proceed.emit())


# ============================================================
# Input
# ============================================================
func _input(event: InputEvent) -> void:
	if _done:
		return
	# While typing a join code, let the text field have the keyboard.
	var typing: bool = _code_box.visible and _code_box.has_focus()

	if event.is_action_pressed("ui_cancel"):
		if _step == Step.CHOOSE:
			_do_cancel()
			cancelled.emit()
		else:
			_do_back_to_choose()
		get_viewport().set_input_as_handled()
		return

	if typing and event is InputEventKey:
		# ENTER in the code box = Join, everything else goes to the field.
		if event.pressed and event.keycode == KEY_ENTER:
			_do_join_code()
			get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("ui_accept"):
		_activate()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_up") or event.is_action_pressed("move_up") \
			or event.is_action_pressed("ui_down") or event.is_action_pressed("move_down"):
		get_viewport().set_input_as_handled()   # _process polls; swallow the edge


func _process(delta: float) -> void:
	if _done or _rows.is_empty():
		return
	var want: int = 0
	if Input.is_action_pressed("ui_up") or Input.is_action_pressed("move_up"):
		want = -1
	elif Input.is_action_pressed("ui_down") or Input.is_action_pressed("move_down"):
		want = 1
	# Do not steal the stick while the player is typing a code.
	if _code_box.visible and _code_box.has_focus():
		want = 0

	if want == 0:
		_nav_dir = 0; _nav_hold = 0.0; _nav_acc = 0.0
	elif want != _nav_dir:
		_nav_dir = want; _nav_hold = 0.0; _nav_acc = 0.0
		_step_focus(want)
	else:
		_nav_hold += delta
		if _nav_hold >= NAV_INITIAL_DELAY:
			_nav_acc += delta
			while _nav_acc >= NAV_REPEAT_RATE:
				_nav_acc -= NAV_REPEAT_RATE
				_step_focus(want)


func _step_focus(dir: int) -> void:
	if _rows.is_empty():
		return
	_focus = posmod(_focus + dir, _rows.size())
	_refresh_highlight()


func _activate() -> void:
	if _focus < 0 or _focus >= _rows.size():
		return
	var cb: Callable = _rows[_focus]["action"]
	if cb.is_valid():
		cb.call()


# ============================================================
# Styling — matches MainMenu / PlayerSetup / SaveFileSelect
# ============================================================
func _style_button(btn: Button) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.12, 0.17, 0.94)
	sb.border_color = Color(0.55, 0.45, 0.20, 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(10)
	btn.add_theme_stylebox_override("normal", sb)
	btn.add_theme_stylebox_override("hover", sb)
	btn.add_theme_stylebox_override("pressed", sb)
	btn.add_theme_stylebox_override("focus", sb)
