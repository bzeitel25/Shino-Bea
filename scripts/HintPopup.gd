extends CanvasLayer

# ============================================================
# HintPopup.gd — Run 146 (2026-07-15) — framed beginner tooltips
# ============================================================
# Replaces the old floating background labels (e.g. the Dojo header
# text) with a proper framed pop-up in the corner of the screen:
#
#   * Non-blocking — the game keeps running underneath.
#   * Close with Start / Minus / Esc (the input is consumed, so the
#     pause menu does NOT open on the same press — the buttons go
#     back to their normal function once the popup is gone).
#   * Gated by Settings.beginner_tips (toggle in the Settings menu).
#   * Auto-fades after AUTO_HIDE_SECS as a safety net.
#
# Usage from any scene:
#   const HINT = preload("res://scripts/HintPopup.gd")
#   HINT.show_hint(self, "Dojo — Shino & Bea's Home",
#       "Sleep in your room to enter the dream • Q+Q swaps hero")
# ============================================================

const AUTO_HIDE_SECS: float = 14.0
const COLOR_GOLD: Color = Color(0.90, 0.78, 0.42)
const COLOR_BODY: Color = Color(0.82, 0.80, 0.74)
const COLOR_DIM:  Color = Color(0.55, 0.53, 0.48)

var _panel: PanelContainer = null
var _closing: bool = false


static func show_hint(host: Node, title_text: String, body_text: String) -> void:
	if not is_instance_valid(host):
		return
	var settings: Node = host.get_node_or_null("/root/Settings")
	if settings != null and "beginner_tips" in settings and not bool(settings.beginner_tips):
		return
	_spawn(host, title_text, body_text)


## Combat-tip variant — gated by Settings.combat_tips instead of beginner_tips.
## Covers swap-hero, attack controls, and combat-flow reminders.
static func show_combat_hint(host: Node, title_text: String, body_text: String) -> void:
	if not is_instance_valid(host):
		return
	var settings: Node = host.get_node_or_null("/root/Settings")
	if settings != null and "combat_tips" in settings and not bool(settings.combat_tips):
		return
	_spawn(host, title_text, body_text)


static func _spawn(host: Node, title_text: String, body_text: String) -> void:
	# Dismiss any existing HintPopup so two don't stack.
	var old: Node = host.get_node_or_null("HintPopup")
	if old != null and old.has_method("_dismiss"):
		old._dismiss()
	var pop = load("res://scripts/HintPopup.gd").new()
	pop.name = "HintPopup"
	pop._build(title_text, body_text)
	host.add_child(pop)


func _build(title_text: String, body_text: String) -> void:
	layer = 40

	_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.08, 0.07, 0.92)
	style.border_color = COLOR_GOLD.darkened(0.25)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.content_margin_left = 14.0
	style.content_margin_right = 14.0
	style.content_margin_top = 10.0
	style.content_margin_bottom = 10.0
	_panel.add_theme_stylebox_override("panel", style)
	# Top-center strip, out of the way of both heroes' HUD corners.
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.offset_left = -260.0
	_panel.offset_right = 260.0
	_panel.offset_top = 14.0
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	_panel.add_child(vbox)

	var title := Label.new()
	title.text = title_text
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", COLOR_GOLD)
	title.add_theme_font_size_override("font_size", 17)
	vbox.add_child(title)

	var body := Label.new()
	body.text = body_text
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_color_override("font_color", COLOR_BODY)
	body.add_theme_font_size_override("font_size", 14)
	vbox.add_child(body)

	var footer := Label.new()
	footer.text = "Start / − to close   •   toggle tips in Settings"
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer.add_theme_color_override("font_color", COLOR_DIM)
	footer.add_theme_font_size_override("font_size", 11)
	vbox.add_child(footer)

	# Gentle entrance — tween + auto-hide timer deferred to _ready
	# because _build runs before the node is in the tree.
	_panel.modulate.a = 0.0


func _ready() -> void:
	var tw: Tween = create_tween()
	tw.tween_property(_panel, "modulate:a", 1.0, 0.35)
	var t := get_tree().create_timer(AUTO_HIDE_SECS)
	t.timeout.connect(_dismiss)


func _input(event: InputEvent) -> void:
	if _closing:
		return
	var close: bool = event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel")
	# Minus / Back / Select on the pad.
	if not close and event is InputEventJoypadButton:
		var jb := event as InputEventJoypadButton
		close = jb.pressed and jb.button_index == JOY_BUTTON_BACK
	if close:
		get_viewport().set_input_as_handled()
		_dismiss()


func _dismiss() -> void:
	if _closing or not is_instance_valid(_panel):
		return
	_closing = true
	var tw: Tween = create_tween()
	tw.tween_property(_panel, "modulate:a", 0.0, 0.3)
	tw.tween_callback(queue_free)
