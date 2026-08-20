extends Node
# ============================================================
# NetDebugPanel.gd — autoload singleton ("NetDebug")  ·  F9 overlay (Run N+1)
# ============================================================
# A developer console for the netcode spine, so Run N+1 is testable before any
# real menu exists. Press F9 anywhere in the game.
#
# This is scaffolding, not the shipping UI. The real flow (Run N+6) lives in the
# PlayerSetup lobby screen — see Online_Multiplayer_Spec.md §8.
#
# Built entirely in code as PanelContainer > VBoxContainer, per the Run 158
# popup convention. Never uses `anchors_preset =` in code (Run 137: that is a
# no-op) — always set_anchors_and_offsets_preset().
# ============================================================

const NetProtocol := preload("res://scripts/net/NetProtocol.gd")
const NetSecurity := preload("res://scripts/net/NetSecurity.gd")
const NetTransport := preload("res://scripts/net/NetTransport.gd")

const MAX_LOG_LINES: int = 14

var _layer: CanvasLayer = null
var _root: PanelContainer = null
var _status: RichTextLabel = null
var _ticket_box: LineEdit = null
var _join_box: LineEdit = null
var _log_label: RichTextLabel = null
var _host_btn: Button = null
var _join_btn: Button = null
var _leave_btn: Button = null
var _copy_btn: Button = null
var _port_box: LineEdit = null

var _lines: PackedStringArray = PackedStringArray()
var _built: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)
	Net.log_line.connect(_on_log)
	Net.state_changed.connect(func(_s: int) -> void: _refresh())


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode == KEY_F9:
		_toggle()
		get_viewport().set_input_as_handled()


func _toggle() -> void:
	if not _built:
		_build()
	_layer.visible = not _layer.visible
	set_process(_layer.visible)
	if _layer.visible:
		_refresh()


# ============================================================
# UI construction
# ============================================================
func _build() -> void:
	_built = true

	_layer = CanvasLayer.new()
	_layer.layer = 200
	_layer.visible = false
	add_child(_layer)

	_root = PanelContainer.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_root.position = Vector2(24, 24)
	_root.custom_minimum_size = Vector2(520, 0)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.09, 0.94)
	sb.border_color = Color(0.42, 0.68, 0.95, 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(14)
	_root.add_theme_stylebox_override("panel", sb)
	_layer.add_child(_root)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	_root.add_child(vb)

	var title := Label.new()
	title.text = "ONLINE CO-OP — dev panel (F9)"
	title.add_theme_color_override("font_color", Color(0.62, 0.82, 1.0))
	vb.add_child(title)

	_status = RichTextLabel.new()
	_status.bbcode_enabled = true
	_status.fit_content = true
	_status.custom_minimum_size = Vector2(0, 60)
	_status.scroll_active = false
	vb.add_child(_status)

	vb.add_child(_rule())

	# --- Host row ---
	var host_row := HBoxContainer.new()
	host_row.add_theme_constant_override("separation", 6)
	vb.add_child(host_row)

	_host_btn = Button.new()
	_host_btn.text = "Host (Direct / LAN)"
	_host_btn.pressed.connect(_on_host)
	host_row.add_child(_host_btn)

	var port_lbl := Label.new()
	port_lbl.text = "Port"
	host_row.add_child(port_lbl)

	_port_box = LineEdit.new()
	_port_box.text = str(NetProtocol.DEFAULT_PORT)
	_port_box.custom_minimum_size = Vector2(80, 0)
	host_row.add_child(_port_box)

	_leave_btn = Button.new()
	_leave_btn.text = "Leave"
	_leave_btn.pressed.connect(func() -> void: Net.leave(); _refresh())
	host_row.add_child(_leave_btn)

	# --- Ticket row ---
	var tick_row := HBoxContainer.new()
	tick_row.add_theme_constant_override("separation", 6)
	vb.add_child(tick_row)

	_ticket_box = LineEdit.new()
	_ticket_box.editable = false
	_ticket_box.placeholder_text = "join code appears here when hosting"
	_ticket_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tick_row.add_child(_ticket_box)

	_copy_btn = Button.new()
	_copy_btn.text = "Copy"
	_copy_btn.pressed.connect(func() -> void:
		if not Net.ticket.is_empty():
			DisplayServer.clipboard_set(Net.ticket)
			_on_log("Join code copied to clipboard."))
	tick_row.add_child(_copy_btn)

	vb.add_child(_rule())

	# --- Join row ---
	var join_row := HBoxContainer.new()
	join_row.add_theme_constant_override("separation", 6)
	vb.add_child(join_row)

	_join_box = LineEdit.new()
	_join_box.placeholder_text = "paste a join code (SB1-…)"
	_join_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_join_box.text_submitted.connect(func(_t: String) -> void: _on_join())
	join_row.add_child(_join_box)

	var paste_btn := Button.new()
	paste_btn.text = "Paste"
	paste_btn.pressed.connect(func() -> void: _join_box.text = DisplayServer.clipboard_get())
	join_row.add_child(paste_btn)

	_join_btn = Button.new()
	_join_btn.text = "Join"
	_join_btn.pressed.connect(_on_join)
	join_row.add_child(_join_btn)

	vb.add_child(_rule())

	_log_label = RichTextLabel.new()
	_log_label.bbcode_enabled = true
	_log_label.fit_content = true
	_log_label.custom_minimum_size = Vector2(0, 170)
	vb.add_child(_log_label)

	var hint := Label.new()
	hint.text = "Same PC: run a second copy of the exported game, not a second editor instance."
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.6, 0.62, 0.68))
	vb.add_child(hint)


func _rule() -> HSeparator:
	return HSeparator.new()


# ============================================================
# Actions
# ============================================================
func _on_host() -> void:
	var port: int = int(_port_box.text) if _port_box.text.is_valid_int() else NetProtocol.DEFAULT_PORT
	var res: Dictionary = Net.host_online(NetSecurity.Mode.DIRECT, port)
	if not bool(res.get("ok", false)):
		_on_log("✖ " + str(res.get("error", "")))
	_refresh()


func _on_join() -> void:
	var res: Dictionary = Net.join_online(_join_box.text)
	if not bool(res.get("ok", false)):
		_on_log("✖ " + str(res.get("error", "")))
	_refresh()


func _on_log(text: String) -> void:
	_lines.append(text)
	while _lines.size() > MAX_LOG_LINES:
		_lines.remove_at(0)
	if _log_label != null:
		_log_label.text = "\n".join(_lines)


func _process(_delta: float) -> void:
	_refresh()


func _refresh() -> void:
	if not _built or _status == null:
		return

	var role: String = "—"
	if Net.is_online():
		role = "HOST (Player 1 / Shino)" if Net.is_host() else "GUEST (Player 2 / Bea)"

	var ping: String = "—"
	if Net.rtt_ms >= 0:
		ping = "%d ms" % Net.rtt_ms

	var col: String = "#8fd18f"
	if Net.state == Net.State.FAILED:
		col = "#e08585"
	elif Net.state != Net.State.CONNECTED:
		col = "#e0c785"

	var fmt: String = "[color=%s]%s[/color]\nRole: %s     Ping: %s     Transport: %s" \
		+ "\nRelay addon (noray): %s"
	_status.text = fmt % [
		col, Net.state_name(), role, ping,
		NetTransport.mode_name(Net.mode),
		"installed" if NetTransport.has_noray() else "not installed — Direct/LAN only",
	]

	if _ticket_box != null and _ticket_box.text != Net.ticket:
		_ticket_box.text = Net.ticket

	var online: bool = Net.is_online()
	_host_btn.disabled = online
	_join_btn.disabled = online
	_leave_btn.disabled = not online
	_copy_btn.disabled = Net.ticket.is_empty()
