extends CanvasLayer

# ============================================================
# DialogBox.gd — Run 117 (2026-07-01) — family conversation UI
# ============================================================
# Sequential dialog box for daytime family chats. The tree PAUSES
# while it's open (same pattern as the Dojo bed choice menu) so
# heroes can't wander off mid-conversation.
#
#   var dlg := DialogBox.new_box(self)
#   dlg.open("Granny Idunn", ["line 1", "line 2"])
#   dlg.finished.connect(...)
#
# [E] / Enter / gamepad A advances; box frees itself when done.
# ============================================================

signal finished

var _lines: Array = []
var _idx: int = 0
var _cooldown: float = 0.0   # swallow the interact press that opened us

var _panel: ColorRect = null
var _name_lbl: Label = null
var _text_lbl: Label = null
var _more_lbl: Label = null


static func new_box(host: Node) -> CanvasLayer:
	var box: CanvasLayer = load("res://scripts/DialogBox.gd").new()
	box.layer = 70
	box.process_mode = Node.PROCESS_MODE_ALWAYS
	host.add_child(box)
	return box


func open(speaker: String, lines: Array) -> void:
	_lines = lines.duplicate()
	_idx = 0
	_cooldown = 0.18
	_build_ui(speaker)
	get_tree().paused = true
	_show_line()


func _build_ui(speaker: String) -> void:
	_panel = ColorRect.new()
	_panel.color = Color(0.07, 0.06, 0.10, 0.92)
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 1.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = -340.0
	_panel.offset_right = 340.0
	_panel.offset_top = -170.0
	_panel.offset_bottom = -36.0
	add_child(_panel)

	var border := ColorRect.new()
	border.color = Color(0.85, 0.72, 0.35, 0.9)
	border.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	border.offset_top = -2.0
	border.offset_bottom = 2.0
	border.offset_left = -2.0
	border.offset_right = 2.0
	border.show_behind_parent = true
	_panel.add_child(border)

	_name_lbl = Label.new()
	_name_lbl.add_theme_font_size_override("font_size", 17)
	_name_lbl.add_theme_color_override("font_color", Color(0.95, 0.85, 0.45))
	_name_lbl.position = Vector2(18, 10)
	_name_lbl.text = speaker
	_panel.add_child(_name_lbl)

	_text_lbl = Label.new()
	_text_lbl.add_theme_font_size_override("font_size", 15)
	_text_lbl.add_theme_color_override("font_color", Color(0.94, 0.93, 0.90))
	_text_lbl.position = Vector2(18, 40)
	_text_lbl.custom_minimum_size = Vector2(644, 0)
	_text_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel.add_child(_text_lbl)

	_more_lbl = Label.new()
	_more_lbl.add_theme_font_size_override("font_size", 12)
	_more_lbl.add_theme_color_override("font_color", Color(0.75, 0.75, 0.60))
	_more_lbl.anchor_left = 1.0
	_more_lbl.anchor_right = 1.0
	_more_lbl.anchor_top = 1.0
	_more_lbl.anchor_bottom = 1.0
	_more_lbl.offset_left = -110.0
	_more_lbl.offset_right = -12.0
	_more_lbl.offset_top = -26.0
	_more_lbl.offset_bottom = -8.0
	_panel.add_child(_more_lbl)


func _show_line() -> void:
	if _idx >= _lines.size():
		_close()
		return
	_text_lbl.text = String(_lines[_idx])
	_more_lbl.text = "[E] ▸" if _idx < _lines.size() - 1 else "[E] Close"


func _process(delta: float) -> void:
	if _cooldown > 0.0:
		_cooldown -= delta


func _unhandled_input(event: InputEvent) -> void:
	if _cooldown > 0.0:
		return
	var advance: bool = event.is_action_pressed("interact") or event.is_action_pressed("ui_accept")
	if not advance or event.is_echo():
		return
	get_viewport().set_input_as_handled()
	_cooldown = 0.12
	_idx += 1
	_show_line()


func _close() -> void:
	get_tree().paused = false
	emit_signal("finished")
	queue_free()
