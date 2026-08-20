extends Control
# ============================================================
# SaveFileSelect.gd — Save slot selection screen
# ============================================================
# Shown after pressing START from the main menu.
# Three slot panels; select one to start / continue a run.
# Empty slot → name prompt → new run.
# Occupied slot → load + start immediately.
# Bottom row: [Delete] [Copy To ▸] [← Back]
#
# Navigation: Up/Down (or D-pad), Enter/A = confirm, Esc/B = back.
# ============================================================

const DOJO_PATH: String = "res://scenes/Dojo.tscn"
const TUTORIAL_PATH: String = "res://scenes/TutorialRoom.tscn"

# ── Colors (match MainMenu palette) ──────────────────────────
const COLOR_BG:          Color = Color(0.04, 0.03, 0.06, 1.0)
const COLOR_GOLD_BORDER: Color = Color(0.85, 0.70, 0.25, 1.0)
const COLOR_GOLD_BRIGHT: Color = Color(1.00, 0.88, 0.40, 1.0)
const COLOR_GOLD_DIM:    Color = Color(0.55, 0.45, 0.18, 1.0)
const COLOR_PANEL:       Color = Color(0.10, 0.09, 0.13, 0.96)
const COLOR_EMPTY:       Color = Color(0.40, 0.38, 0.48, 1.0)
const COLOR_SPARK:       Color = Color(0.55, 0.80, 1.00, 1.0)

# ── UI nodes (built in _ready) ────────────────────────────────
var _slot_btns:    Array = []   # 3 Button nodes
var _action_btns:  Array = []   # [Delete, Copy, Back]
var _focused_idx:  int   = 0    # 0-2 = slots, 3 = Delete, 4 = Copy, 5 = Back
var _focus_nodes:  Array = []   # flat list of all focusable nodes

# Name dialog nodes
var _name_dialog:    Control  = null
var _name_edit:      LineEdit = null
var _name_confirm:   Button   = null
var _name_cancel:    Button   = null
var _pending_slot:   int      = -1   # slot waiting for a name
# Run 150 (Bruno fix 2): grace window so the keypress that opened the dialog
# can't also confirm it (Enter was double-firing → name prompt skipped).
var _name_dialog_opened_at: int = 0

# Copy submenu
var _copy_panel:      Control  = null
var _copy_slot_btns:  Array    = []
var _copy_cancel_btn: Button   = null

var _starting: bool = false

# ── Stick nav gating (same pattern as MenuFocusNav) ──────────
const NAV_INITIAL_DELAY: float = 1.5
const NAV_REPEAT_RATE:   float = 0.3
const NAV_COOLDOWN:      float = 0.18
var _nav_held_dir: int   = 0
var _nav_hold_time: float = 0.0
var _nav_repeat_acc: float = 0.0
var _nav_cooldown_t: float = 0.0


func _ready() -> void:
	# Run 164c — apply the "Ink & Washi" skin to everything built below.
	UISkin.skin_tree_deferred(self)
	_build_ui()
	_refresh_slots()
	_update_focus()


# ===========================================================================
# UI construction
# ===========================================================================

func _build_ui() -> void:
	# Dark background.
	var bg := ColorRect.new()
	bg.anchor_right  = 1.0
	bg.anchor_bottom = 1.0
	bg.color = COLOR_BG
	add_child(bg)

	# Title.
	var title := Label.new()
	title.text = "SELECT SAVE FILE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.anchor_right  = 1.0
	title.offset_top    = 60.0
	title.offset_bottom = 130.0
	title.add_theme_color_override("font_color", COLOR_GOLD_BRIGHT)
	title.add_theme_font_size_override("font_size", 48)
	add_child(title)

	# Subtitle.
	var sub := Label.new()
	sub.text = "choose a save to begin your run"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.anchor_right  = 1.0
	sub.offset_top    = 130.0
	sub.offset_bottom = 162.0
	sub.add_theme_color_override("font_color", Color(0.65, 0.60, 0.75, 0.80))
	sub.add_theme_font_size_override("font_size", 18)
	add_child(sub)

	# Slot panels — 3 tall buttons centered.
	var slot_start_y: float = 185.0
	var slot_h:       float = 110.0
	var slot_gap:     float = 16.0
	var slot_w:       float = 640.0
	var slot_x:       float = (1280.0 - slot_w) / 2.0

	for i in range(3):
		var y := slot_start_y + i * (slot_h + slot_gap)
		var btn := Button.new()
		btn.position = Vector2(slot_x, y)
		btn.size     = Vector2(slot_w, slot_h)
		btn.text     = ""   # text painted via Label children below
		btn.focus_mode = Control.FOCUS_ALL
		btn.pressed.connect(_on_slot_pressed.bind(i))
		_apply_slot_style(btn, false)
		add_child(btn)
		_slot_btns.append(btn)
		_focus_nodes.append(btn)

	# Action bar — Delete | Copy | Back.
	var bar_y: float = slot_start_y + 3 * (slot_h + slot_gap) + 10.0
	var bar_labels := ["Delete Save", "Copy Save To…", "← Back"]
	var bar_w: float = 200.0
	var bar_gap: float = 24.0
	var total_bar: float = 3 * bar_w + 2 * bar_gap
	var bar_x0: float = (1280.0 - total_bar) / 2.0

	for i in range(3):
		var btn := Button.new()
		btn.position = Vector2(bar_x0 + i * (bar_w + bar_gap), bar_y)
		btn.size     = Vector2(bar_w, 52.0)
		btn.text     = bar_labels[i]
		btn.focus_mode = Control.FOCUS_ALL
		match i:
			0: btn.pressed.connect(_on_delete_pressed)
			1: btn.pressed.connect(_on_copy_pressed)
			2: btn.pressed.connect(_on_back_pressed)
		_apply_action_style(btn)
		add_child(btn)
		_action_btns.append(btn)
		_focus_nodes.append(btn)

	# Hint row.
	var hint := Label.new()
	hint.text = "↑/↓ / W,S navigate   ENTER select   ESC back"
	hint.anchor_top    = 1.0
	hint.anchor_right  = 1.0
	hint.anchor_bottom = 1.0
	hint.offset_left   = 16.0
	hint.offset_top    = -30.0
	hint.offset_bottom = -8.0
	hint.add_theme_color_override("font_color", Color(0.60, 0.55, 0.70, 0.70))
	hint.add_theme_font_size_override("font_size", 13)
	add_child(hint)

	# Name dialog (hidden until needed).
	_build_name_dialog()
	# Copy submenu (hidden until needed).
	_build_copy_panel()


func _build_name_dialog() -> void:
	# Run 164c — apply the "Ink & Washi" skin to everything built below.
	UISkin.skin_tree_deferred(self)
	_name_dialog = Control.new()
	_name_dialog.anchor_right  = 1.0
	_name_dialog.anchor_bottom = 1.0
	_name_dialog.visible = false
	add_child(_name_dialog)

	var dim := ColorRect.new()
	dim.anchor_right  = 1.0
	dim.anchor_bottom = 1.0
	dim.color = Color(0, 0, 0, 0.72)
	_name_dialog.add_child(dim)

	var panel := Panel.new()
	panel.position = Vector2(390, 300)
	panel.size     = Vector2(500, 220)
	var sb := StyleBoxFlat.new()
	sb.bg_color    = Color(0.10, 0.09, 0.14, 0.98)
	sb.border_color = COLOR_GOLD_BORDER
	for side in [SIDE_LEFT, SIDE_RIGHT, SIDE_TOP, SIDE_BOTTOM]:
		sb.set_border_width(side, 2)
	sb.corner_radius_top_left = 8; sb.corner_radius_top_right = 8
	sb.corner_radius_bottom_left = 8; sb.corner_radius_bottom_right = 8
	panel.add_theme_stylebox_override("panel", sb)
	_name_dialog.add_child(panel)

	var lbl := Label.new()
	lbl.text = "Name this save file:"
	lbl.position    = Vector2(24, 24)
	lbl.size        = Vector2(452, 36)
	lbl.add_theme_color_override("font_color", COLOR_GOLD_BRIGHT)
	lbl.add_theme_font_size_override("font_size", 22)
	panel.add_child(lbl)

	_name_edit = LineEdit.new()
	_name_edit.position        = Vector2(24, 76)
	_name_edit.size            = Vector2(452, 48)
	_name_edit.placeholder_text = "Enter name…"
	_name_edit.max_length       = 24
	_name_edit.add_theme_font_size_override("font_size", 22)
	_name_edit.text_submitted.connect(_on_name_submitted)
	panel.add_child(_name_edit)

	_name_confirm = Button.new()
	_name_confirm.text     = "START"
	_name_confirm.position = Vector2(24, 148)
	_name_confirm.size     = Vector2(200, 48)
	_name_confirm.pressed.connect(_on_name_confirm_pressed)
	_apply_action_style(_name_confirm)
	panel.add_child(_name_confirm)

	_name_cancel = Button.new()
	_name_cancel.text     = "Cancel"
	_name_cancel.position = Vector2(276, 148)
	_name_cancel.size     = Vector2(200, 48)
	_name_cancel.pressed.connect(_on_name_cancel_pressed)
	_apply_action_style(_name_cancel)
	panel.add_child(_name_cancel)


func _build_copy_panel() -> void:
	# Run 164c — apply the "Ink & Washi" skin to everything built below.
	UISkin.skin_tree_deferred(self)
	_copy_panel = Control.new()
	_copy_panel.anchor_right  = 1.0
	_copy_panel.anchor_bottom = 1.0
	_copy_panel.visible = false
	add_child(_copy_panel)

	var dim := ColorRect.new()
	dim.anchor_right  = 1.0
	dim.anchor_bottom = 1.0
	dim.color = Color(0, 0, 0, 0.72)
	_copy_panel.add_child(dim)

	var panel := Panel.new()
	panel.position = Vector2(440, 330)
	panel.size     = Vector2(400, 220)
	var sb := StyleBoxFlat.new()
	sb.bg_color    = Color(0.10, 0.09, 0.14, 0.98)
	sb.border_color = COLOR_GOLD_BORDER
	for side in [SIDE_LEFT, SIDE_RIGHT, SIDE_TOP, SIDE_BOTTOM]:
		sb.set_border_width(side, 2)
	sb.corner_radius_top_left = 8; sb.corner_radius_top_right = 8
	sb.corner_radius_bottom_left = 8; sb.corner_radius_bottom_right = 8
	panel.add_theme_stylebox_override("panel", sb)
	_copy_panel.add_child(panel)

	var lbl := Label.new()
	lbl.text = "Copy to which slot?"
	lbl.position = Vector2(20, 16)
	lbl.size     = Vector2(360, 36)
	lbl.add_theme_color_override("font_color", COLOR_GOLD_BRIGHT)
	lbl.add_theme_font_size_override("font_size", 20)
	panel.add_child(lbl)

	for i in range(3):
		var btn := Button.new()
		btn.text     = "Slot %d" % (i + 1)
		btn.position = Vector2(20, 60 + i * 44)
		btn.size     = Vector2(360, 38)
		btn.pressed.connect(_on_copy_target_pressed.bind(i))
		_apply_action_style(btn)
		panel.add_child(btn)
		_copy_slot_btns.append(btn)

	var cancel := Button.new()
	cancel.text     = "Cancel"
	cancel.position = Vector2(20, 60 + 3 * 44)
	cancel.size     = Vector2(360, 38)
	cancel.pressed.connect(func(): _copy_panel.visible = false)
	_apply_action_style(cancel)
	panel.add_child(cancel)
	_copy_cancel_btn = cancel


# ===========================================================================
# Slot text refresh
# ===========================================================================

func _refresh_slots() -> void:
	for i in range(3):
		_refresh_slot_label(i)


func _refresh_slot_label(slot: int) -> void:
	var btn := _slot_btns[slot] as Button
	# Remove any previous label children.
	for c in btn.get_children():
		if c is Label:
			c.queue_free()

	var info := SaveManager.get_slot_info(slot)
	if info.is_empty():
		_add_slot_label(btn, "SLOT %d — EMPTY" % (slot + 1), 22, COLOR_EMPTY, Vector2(24, 20))
		_add_slot_label(btn, "Press to start a new run", 16, Color(0.55, 0.52, 0.60, 0.80), Vector2(24, 58))
	else:
		var name_str: String = info.get("name", "Save %d" % (slot + 1))
		var date_str: String = info.get("save_date", "")
		var arenas:   int    = info.get("arenas_cleared", 0)
		var loops:    int    = info.get("loops_completed", 0)
		var boons:    int    = info.get("boons_count",    0)
		var sparks:   int    = info.get("dragon_souls",  0)
		var header := "SLOT %d — %s" % [(slot + 1), name_str.to_upper()]
		_add_slot_label(btn, header, 22, COLOR_GOLD_BRIGHT, Vector2(24, 14))
		var stats := "Arena %d  •  Loop %d  •  %d boons" % [arenas, loops + 1, boons]
		if sparks > 0:
			stats += "  •  ✦ %d sparks" % sparks
		_add_slot_label(btn, stats, 16, Color(0.80, 0.78, 0.85, 1.0), Vector2(24, 52))
		_add_slot_label(btn, "Last saved: %s" % date_str, 12, Color(0.50, 0.48, 0.58, 0.70), Vector2(24, 80))


func _add_slot_label(parent: Control, text: String, size: int, color: Color, pos: Vector2) -> void:
	var lbl := Label.new()
	lbl.text     = text
	lbl.position = pos
	lbl.size     = Vector2(parent.size.x - 48, 40)
	lbl.add_theme_font_size_override("font_size", size)
	lbl.add_theme_color_override("font_color", color)
	parent.add_child(lbl)


# ===========================================================================
# Input
# ===========================================================================

func _process(delta: float) -> void:
	if _name_dialog.visible:
		_nav_held_dir = 0
		return
	# Phase 1-3 sweep: this screen polls Input directly, so an open confirm
	# dialog (Delete Save) would otherwise keep moving the slot cursor behind it.
	if ConfirmPopup.is_open():
		_nav_held_dir = 0
		return
	if _nav_cooldown_t > 0.0:
		_nav_cooldown_t -= delta
	# Poll Input singleton — immune to stick wobble.
	var want: int = 0
	if Input.is_action_pressed("ui_up") or Input.is_action_pressed("move_up"):
		want = -1
	elif Input.is_action_pressed("ui_down") or Input.is_action_pressed("move_down"):
		want = 1

	if want == 0:
		_nav_held_dir = 0; _nav_hold_time = 0.0; _nav_repeat_acc = 0.0
		return
	if want != _nav_held_dir:
		_nav_held_dir = want; _nav_hold_time = 0.0; _nav_repeat_acc = 0.0
		if _nav_cooldown_t <= 0.0:
			if _copy_panel.visible:
				_shift_copy_focus(want)
			else:
				_focused_idx = clampi(_focused_idx + want, 0, _focus_nodes.size() - 1)
				_update_focus()
			_nav_cooldown_t = NAV_COOLDOWN
		return
	_nav_hold_time += delta
	if _nav_hold_time >= NAV_INITIAL_DELAY:
		_nav_repeat_acc += delta
		while _nav_repeat_acc >= NAV_REPEAT_RATE:
			_nav_repeat_acc -= NAV_REPEAT_RATE
			if _nav_cooldown_t <= 0.0:
				if _copy_panel.visible:
					_shift_copy_focus(_nav_held_dir)
				else:
					_focused_idx = clampi(_focused_idx + _nav_held_dir, 0, _focus_nodes.size() - 1)
				_nav_cooldown_t = NAV_COOLDOWN
				_update_focus()


func _input(event: InputEvent) -> void:
	# Phase 1-3 sweep — the dialog owns all input while it is up.
	if ConfirmPopup.is_open():
		return
	if _name_dialog.visible:
		if event.is_action_pressed("ui_cancel"):
			_on_name_cancel_pressed()
		return

	if _copy_panel.visible:
		if event.is_action_pressed("ui_cancel"):
			_copy_panel.visible = false
		# Consume nav events — _process handles movement.
		elif event.is_action_pressed("ui_up") or event.is_action_pressed("move_up") \
		or event.is_action_pressed("ui_down") or event.is_action_pressed("move_down"):
			pass   # consumed below
		return

	# Consume nav events — _process handles movement via polling.
	if event.is_action_pressed("ui_up") or event.is_action_pressed("move_up") \
	or event.is_action_pressed("ui_down") or event.is_action_pressed("move_down"):
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		# Run 150 (Bruno fix 2): consume the accept BEFORE emitting pressed.
		# Otherwise the same Enter keypress propagates on to the GUI layer,
		# lands on the name dialog's just-focused LineEdit, and instantly
		# submits an empty name — skipping the name prompt entirely.
		get_viewport().set_input_as_handled()
		var focused: Node = _focus_nodes[_focused_idx]
		if focused is Button:
			(focused as Button).emit_signal("pressed")
	elif event.is_action_pressed("ui_cancel"):
		_on_back_pressed()


# Run 39 — move focus through the copy submenu (3 slot buttons + Cancel),
# skipping disabled targets (the source slot).
func _shift_copy_focus(dir: int) -> void:
	var nodes: Array = _copy_slot_btns.duplicate()
	if _copy_cancel_btn:
		nodes.append(_copy_cancel_btn)
	if nodes.is_empty():
		return
	var cur: int = 0
	for i in range(nodes.size()):
		if (nodes[i] as Button).has_focus():
			cur = i
			break
	for _step in range(nodes.size()):
		cur = (cur + dir + nodes.size()) % nodes.size()
		var btn := nodes[cur] as Button
		if not btn.disabled:
			btn.grab_focus()
			return


func _update_focus() -> void:
	for i in range(_focus_nodes.size()):
		var node: Node = _focus_nodes[i]
		if not node is Button:
			continue
		var btn := node as Button
		if i == _focused_idx:
			btn.grab_focus()
			var is_slot := i < 3
			_apply_slot_style(btn, true) if is_slot else _apply_action_style_focused(btn)
		else:
			var is_slot := i < 3
			_apply_slot_style(btn, false) if is_slot else _apply_action_style(btn)


# ===========================================================================
# Slot actions
# ===========================================================================

func _on_slot_pressed(slot: int) -> void:
	if _starting:
		return
	_focused_idx = slot
	if SaveManager.is_slot_empty(slot):
		# Open name dialog.
		_pending_slot = slot
		_name_edit.text = ""
		_name_dialog.visible = true
		# Run 150 (Bruno fix 2): record open time + defer the focus grab so the
		# keypress that opened the dialog can never reach the LineEdit.
		_name_dialog_opened_at = Time.get_ticks_msec()
		_name_edit.call_deferred("grab_focus")
	else:
		_start_run_from_slot(slot)


func _start_run_from_slot(slot: int) -> void:
	_starting = true
	SaveManager.load_slot(slot)
	if get_node_or_null("/root/FX") and FX.has_method("fade_to_black"):
		FX.fade_to_black(0.30, 0.05, 1.0, Callable(self, "_do_scene_change"))
	else:
		_do_scene_change()


func _do_scene_change() -> void:
	# If a saved run has a recorded resume scene (set at each gate exit), skip the
	# Dojo and go directly to the next arena the player was heading into.
	var rs: Node = get_node_or_null("/root/RunState")
	var resume_path: String = ""
	if rs and rs.get("resume_scene_path") != null:
		resume_path = String(rs.resume_scene_path)
	if resume_path != "" and ResourceLoader.exists(resume_path):
		Log.dbg("[SaveFileSelect] Resuming saved run at: %s" % resume_path)
		get_tree().change_scene_to_file(resume_path)
		return
	# New game or legacy save with no resume path.
	# If the tutorial hasn't been completed yet, route there first.
	var _rs: Node = get_node_or_null("/root/RunState")
	if _rs and not _rs.tutorial_completed:
		if ResourceLoader.exists(TUTORIAL_PATH):
			Log.dbg("[SaveFileSelect] New game — starting tutorial.")
			get_tree().change_scene_to_file(TUTORIAL_PATH)
			return
		push_warning("[SaveFileSelect] TutorialRoom.tscn not found — falling through to Dojo.")
	if not ResourceLoader.exists(DOJO_PATH):
		push_error("[SaveFileSelect] Dojo.tscn not found.")
		_starting = false
		return
	get_tree().change_scene_to_file(DOJO_PATH)


# ===========================================================================
# Name dialog
# ===========================================================================

func _on_name_submitted(text: String) -> void:
	_on_name_confirm_pressed()


func _on_name_confirm_pressed() -> void:
	# Run 150 (Bruno fix 2): ignore a confirm arriving within 150 ms of the
	# dialog opening — that's the slot-select press leaking through, not the
	# player confirming a name.
	if Time.get_ticks_msec() - _name_dialog_opened_at < 150:
		return
	var name_str := _name_edit.text.strip_edges()
	if name_str.is_empty():
		name_str = "Slot %d" % (_pending_slot + 1)
	_name_dialog.visible = false
	SaveManager.create_new_slot(_pending_slot, name_str)
	_start_run_from_slot(_pending_slot)


func _on_name_cancel_pressed() -> void:
	_name_dialog.visible = false
	_update_focus()


# ===========================================================================
# Delete / Copy / Back
# ===========================================================================

func _on_delete_pressed() -> void:
	var slot := _focused_idx if _focused_idx < 3 else 0
	if SaveManager.is_slot_empty(slot):
		return
	# Phase 3c — deleting a save was a single unprotected button press.
	# Name the file in the prompt so there is no doubt which one goes.
	var info: Dictionary = SaveManager.get_slot_info(slot)
	var save_name: String = String(info.get("name", "Slot %d" % (slot + 1)))
	ConfirmPopup.request(self, "DELETE SAVE?",
		"\"%s\" will be permanently erased.\nThis cannot be undone." % save_name,
		"DELETE", Callable(self, "_do_delete_slot").bind(slot), true)


func _do_delete_slot(slot: int) -> void:
	SaveManager.delete_slot(slot)
	_refresh_slot_label(slot)
	_update_focus()


func _on_copy_pressed() -> void:
	var slot := _focused_idx if _focused_idx < 3 else 0
	if SaveManager.is_slot_empty(slot):
		return
	# Update copy target button labels.
	for i in range(3):
		var info := SaveManager.get_slot_info(i)
		var label_text := "Slot %d" % (i + 1)
		if info.is_empty():
			label_text += " (empty)"
		else:
			label_text += " — %s" % info.get("name", "?")
		_copy_slot_btns[i].text = label_text
		_copy_slot_btns[i].disabled = (i == slot)
	_copy_panel.visible = true
	if not _copy_slot_btns.is_empty():
		_copy_slot_btns[0].grab_focus()


func _on_copy_target_pressed(to_slot: int) -> void:
	var from_slot := _focused_idx if _focused_idx < 3 else 0
	SaveManager.copy_slot(from_slot, to_slot)
	_copy_panel.visible = false
	_refresh_slot_label(to_slot)


func _on_back_pressed() -> void:
	if get_node_or_null("/root/FX") and FX.has_method("fade_to_black"):
		FX.fade_to_black(0.20, 0.05, 1.0, func(): get_tree().change_scene_to_file("res://scenes/MainMenu.tscn"))
	else:
		get_tree().change_scene_to_file("res://scenes/MainMenu.tscn")


# ===========================================================================
# Style helpers
# ===========================================================================

# Run 166 (Bruno fix) — these three helpers used to paint the pre-164 dark-gold
# StyleBoxFlats. But _update_focus() re-runs them on EVERY cursor move, so the
# first thing a Down press did was overwrite the "Ink & Washi" plaques that
# skin_tree_deferred() had just applied — the menu snapped back to the old look.
# They now delegate to the shared UISkin plaque skin, so re-applying them on
# focus changes keeps the updated look instead of fighting it. Focus itself is
# carried by Godot's own "focus" plaque stylebox: the selected node already
# calls grab_focus() in _update_focus(), so we don't hand-swap styleboxes here.

func _apply_slot_style(btn: Button, _focused: bool) -> void:
	# Wide save-slot plaque. No seal — a centre-left 忍 stamp would float in the
	# empty gutter beside a 640 px panel (this is why skin_tree skips seals on
	# non-vertical-menu buttons too). The idle→focus plaque swap is the cue.
	UISkin.skin_button(btn, "", UISkin.SIZE_ROW)


func _apply_action_style(btn: Button) -> void:
	UISkin.skin_button(btn, "", UISkin.SIZE_ROW)


func _apply_action_style_focused(btn: Button) -> void:
	# Focus visual comes from Godot's focus plaque (the caller grabs focus first);
	# the skin is identical to the idle state so nothing to add.
	UISkin.skin_button(btn, "", UISkin.SIZE_ROW)
