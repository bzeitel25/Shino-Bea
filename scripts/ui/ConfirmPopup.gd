class_name ConfirmPopup
extends RefCounted
# ============================================================
# ConfirmPopup.gd — shared "are you sure?" dialog  (Phase 3c)
# ============================================================
# One confirmation dialog for the whole game. Built in code (no .tscn), on its
# own CanvasLayer, PROCESS_MODE_ALWAYS — so it works from the main menu, from
# a paused game, and from the pause overlay alike.
#
# ── USAGE ───────────────────────────────────────────────────
#   ConfirmPopup.request(self, "QUIT GAME?",
#       "Any unsaved progress in the current room will be lost.",
#       "QUIT", Callable(self, "_do_quit"))
#
# The last argument is only invoked when the player confirms. Cancel simply
# closes and hands focus back.
#
# ── RESPECTS THE EXISTING SETTING ───────────────────────────
# Settings.safety_confirmations already existed (Settings.gd:51) but was only
# consulted for boon rerolls. When it is OFF, request() skips the dialog and
# fires the callback immediately — so the setting now means what it says
# across the whole game.
#
# ── WHY RefCounted + static ─────────────────────────────────
# There is no state worth keeping between prompts. request() builds the
# overlay, wires the two buttons, and everything frees itself on close, so
# there is nothing to leak and nothing to reset.
# ============================================================

# ---------------------------------------------------------------------------
# Modal tracking  (added during the Phase 1-3 sweep)
# ---------------------------------------------------------------------------
# Several menus (MainMenu, SaveFileSelect) do NOT rely on Godot's focus system
# alone — they poll Input.is_action_pressed() in _process and handle raw joypad
# events in _input, because Steam Input can present a pad on an unexpected
# device slot. Those handlers only knew about their own sub-panels, so a popup
# opened on top of them was navigable straight through: gamepad A would fire
# the button BEHIND the dialog.
#
# Any menu that polls input directly must therefore check is_open() and bail.
# Focus-driven menus (SettingsMenu, PauseManager) need no change.
#
# Liveness is derived from the layer node rather than a counter, so it is
# self-healing: if the overlay is freed by a scene change or anything else, the
# reference goes invalid and is_open() reports false automatically. A counter
# would have leaked "permanently open" and soft-locked the menus.
static var _active_layer: CanvasLayer = null


## True while a confirmation dialog is on screen.
static func is_open() -> bool:
	return is_instance_valid(_active_layer)


const COLOR_GOLD: Color      = Color(0.96, 0.82, 0.32, 1.0)
const COLOR_GOLD_DIM: Color  = Color(0.70, 0.62, 0.35, 1.0)
const COLOR_TEXT: Color      = Color(0.90, 0.90, 0.94, 1.0)
const COLOR_DANGER: Color    = Color(1.00, 0.45, 0.35, 1.0)
const COLOR_PANEL: Color     = Color(0.08, 0.07, 0.11, 0.98)


## Ask for confirmation. `on_confirm` runs only if the player agrees.
##
## `host` is any Node in the tree — it is used to reach the SceneTree, and the
## overlay is parented to the tree root so it survives the host being hidden.
## `danger` tints the confirm button red for destructive actions.
static func request(host: Node, title: String, body: String,
		confirm_text: String, on_confirm: Callable,
		danger: bool = false) -> void:
	if host == null or not host.is_inside_tree():
		# Nothing to attach to — fail safe by doing nothing rather than
		# performing a destructive action with no way to cancel it.
		push_warning("[ConfirmPopup] host not in tree; request ignored.")
		return

	# Honour the existing global setting.
	var settings: Node = host.get_node_or_null("/root/Settings")
	if settings != null and "safety_confirmations" in settings \
			and not bool(settings.safety_confirmations):
		if on_confirm.is_valid():
			on_confirm.call()
		return

	# Never stack two dialogs — a second request while one is open is almost
	# always an input leak from the menu underneath.
	if is_open():
		return

	var tree: SceneTree = host.get_tree()
	var layer := CanvasLayer.new()
	layer.layer = 120        # above the pause overlay (100), below brightness (128)
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	tree.root.add_child(layer)
	# Run 164c — apply the "Ink & Washi" skin to everything built below.
	UISkin.skin_tree_deferred(layer)
	_active_layer = layer

	var root := Control.new()
	root.anchor_right = 1.0
	root.anchor_bottom = 1.0
	root.process_mode = Node.PROCESS_MODE_ALWAYS
	layer.add_child(root)

	var dim := ColorRect.new()
	dim.anchor_right = 1.0
	dim.anchor_bottom = 1.0
	dim.color = Color(0.0, 0.0, 0.0, 0.78)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)

	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -240.0
	panel.offset_top = -110.0
	panel.offset_right = 240.0
	panel.offset_bottom = 110.0
	var sb := StyleBoxFlat.new()
	sb.bg_color = COLOR_PANEL
	sb.border_color = COLOR_DANGER if danger else COLOR_GOLD_DIM
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(22)
	panel.add_theme_stylebox_override("panel", sb)
	root.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)

	var title_lbl := Label.new()
	title_lbl.text = title
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_lbl.add_theme_color_override("font_color",
		COLOR_DANGER if danger else COLOR_GOLD)
	title_lbl.add_theme_font_size_override("font_size", 28)
	vbox.add_child(title_lbl)

	if body != "":
		var body_lbl := Label.new()
		body_lbl.text = body
		body_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		body_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body_lbl.custom_minimum_size = Vector2(420, 0)
		body_lbl.add_theme_color_override("font_color", COLOR_TEXT)
		body_lbl.add_theme_font_size_override("font_size", 15)
		vbox.add_child(body_lbl)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 16)
	vbox.add_child(row)

	var cancel_btn := _make_button("CANCEL", COLOR_GOLD_DIM)
	var confirm_btn := _make_button(confirm_text, COLOR_DANGER if danger else COLOR_GOLD)
	row.add_child(cancel_btn)
	row.add_child(confirm_btn)

	# Both paths tear the overlay down; only confirm runs the callback.
	#
	# Lambdas rather than `_dismiss.bind(...)` on purpose: taking a REFERENCE to
	# a static function from inside another static function is not reliable in
	# GDScript (calling one is fine; referencing one as a Callable is not).
	# Lambdas capture `layer` and `on_confirm` by value, which is exactly what
	# is needed here and works in every Godot 4 build.
	var do_cancel := func() -> void:
		_active_layer = null
		# Distinct back cue — SFX's global button hook plays ui_confirm for every
		# button, so backing out gets its own sound layered on top of it.
		var sfx: Node = host.get_node_or_null("/root/SFX")
		if sfx != null:
			sfx.play("ui_back")
		if is_instance_valid(layer):
			layer.queue_free()
	cancel_btn.pressed.connect(do_cancel)
	confirm_btn.pressed.connect(func() -> void:
		# Clear the modal flag BEFORE running the callback — the callback may
		# change scene or open another dialog, and it must not see a stale
		# "already open" state.
		_active_layer = null
		if is_instance_valid(layer):
			layer.queue_free()
		if on_confirm.is_valid():
			on_confirm.call()
	)

	# Left stick / WASD navigation between the two buttons, plus B / Esc to back
	# out — the same contract every other menu uses. (D-pad + arrows already move
	# between the two buttons via Godot's built-in focus chain.)
	var nav: Node = load("res://scripts/MenuFocusNav.gd").new()
	nav.process_mode = Node.PROCESS_MODE_ALWAYS
	layer.add_child(nav)
	nav.buttons = [cancel_btn, confirm_btn]
	nav.on_cancel = do_cancel

	# CANCEL takes focus — the safe option should be the default for a
	# destructive prompt, so a reflexive A-press never destroys anything.
	cancel_btn.grab_focus()


static func _make_button(text: String, accent: Color) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(150, 42)
	btn.focus_mode = Control.FOCUS_ALL
	btn.process_mode = Node.PROCESS_MODE_ALWAYS

	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.12, 0.11, 0.16, 1.0)
	normal.border_color = accent
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(6)
	btn.add_theme_stylebox_override("normal", normal)

	var focused := StyleBoxFlat.new()
	focused.bg_color = Color(0.20, 0.17, 0.10, 1.0)
	focused.border_color = accent
	focused.set_border_width_all(3)
	focused.set_corner_radius_all(6)
	btn.add_theme_stylebox_override("focus", focused)
	btn.add_theme_stylebox_override("hover", focused)

	btn.add_theme_color_override("font_color", accent)
	btn.add_theme_color_override("font_focus_color", Color(1, 1, 1, 1))
	btn.add_theme_font_size_override("font_size", 20)
	return btn
