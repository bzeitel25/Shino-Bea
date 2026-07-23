extends CanvasLayer
# ============================================================
# DoorChoice.gd — Hades-style two-door preview overlay (Run 26, 2026-06-02)
# ============================================================
# Spawned by World.gd AFTER the player picks a boon and (where applicable)
# Apple Juice resolves. Reads the upcoming-room preview pair from
# RunState.roll_door_pair() and shows two big cards labeled with the reward
# that the NEXT room will commit to.
#
# Player clicks (or focuses + accepts) a door → DoorChoice:
#   1. RunState.commit_door_choice(chosen_preview)  — locks the reward
#   2. emits door_picked(chosen_index, preview_dict)
#   3. World.gd handles the signal: stores the next_scene_path, fades to
#      black, then change_scene_to_file.
#
# Visual style mirrors BoonOffer.gd: dimmed backdrop, two large cards
# stacked horizontally, large preview text. Family color = card border;
# rarity color = title accent. Boss rooms get a flame-red "★ BOSS" card;
# Apple Juice rooms get a cyan "🧃 APPLE JUICE" card.
#
# Pause behavior — like BoonOffer, this overlay pauses the tree and
# uses PROCESS_MODE_ALWAYS so its own scripts keep ticking.
# ============================================================

signal door_picked(door_index: int, preview: Dictionary)

const CARD_WIDTH:   float = 320.0
const CARD_HEIGHT:  float = 380.0
const CARD_SPACING: float = 60.0
const TITLE_TEXT:    String = "✦ CHOOSE A DOOR ✦"
const SUBTITLE_TEXT: String = "(Preview of the NEXT room's reward)"

# Run 26 — Bruno's spec: two physical door previews. Player picks one,
# the chosen reward locks into RunState.pending_reward (via commit_door_choice),
# and the next arena's BoonOffer honors it on wave-clear.

var _previews: Array = []     # Array[Dictionary] length 2 from roll_door_pair
var _picked: bool = false
var _next_arena_number: int = -1   # used for the roll_door_pair() call; passed in via setup()
var _card_buttons: Array = []      # Array[Button] — focusable for keyboard/gamepad

# ── Stick nav gating ─────────────────────────────────────────
const NAV_INITIAL_DELAY: float = 1.5
const NAV_REPEAT_RATE:   float = 0.3
const NAV_COOLDOWN:      float = 0.18
var _nav_held_dir: int   = 0
var _nav_cooldown_t: float = 0.0
var _nav_hold_time: float = 0.0
var _nav_repeat_acc: float = 0.0


func setup(next_arena_number: int) -> void:
	# Called immediately after instantiation, before _ready, by World.gd.
	_next_arena_number = next_arena_number


func _ready() -> void:
	layer = 110   # above BoonOffer (100) and HUD (5/10) just in case
	# Defensive default: roll for arena 1 if World forgot to call setup().
	if _next_arena_number <= 0:
		_next_arena_number = max(1, RunState.arenas_cleared + 1)
	_previews = RunState.roll_door_pair(_next_arena_number)
	_build_overlay()
	get_tree().paused = true
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Grab focus on the first card so keyboard/gamepad players can pick immediately.
	if _card_buttons.size() > 0:
		_card_buttons[0].grab_focus()


# Run 39 — WASD card navigation (polling-based, immune to stick wobble).
func _process(delta: float) -> void:
	if _card_buttons.is_empty():
		return
	if _nav_cooldown_t > 0.0:
		_nav_cooldown_t -= delta
	var want: int = 0
	if Input.is_action_pressed("move_left") or Input.is_action_pressed("move_up"):
		want = -1
	elif Input.is_action_pressed("move_right") or Input.is_action_pressed("move_down"):
		want = 1

	if want == 0:
		_nav_held_dir = 0; _nav_hold_time = 0.0; _nav_repeat_acc = 0.0
		return
	if want != _nav_held_dir:
		_nav_held_dir = want; _nav_hold_time = 0.0; _nav_repeat_acc = 0.0
		if _nav_cooldown_t <= 0.0:
			_cycle_card_focus(want); _nav_cooldown_t = NAV_COOLDOWN
		return
	_nav_hold_time += delta
	if _nav_hold_time >= NAV_INITIAL_DELAY:
		_nav_repeat_acc += delta
		while _nav_repeat_acc >= NAV_REPEAT_RATE:
			_nav_repeat_acc -= NAV_REPEAT_RATE
			if _nav_cooldown_t <= 0.0:
				_cycle_card_focus(_nav_held_dir); _nav_cooldown_t = NAV_COOLDOWN


func _input(event: InputEvent) -> void:
	if _card_buttons.is_empty():
		return
	# Consume nav events — _process handles movement via polling.
	if event.is_action_pressed("move_left") or event.is_action_pressed("move_up") \
	or event.is_action_pressed("move_right") or event.is_action_pressed("move_down"):
		get_viewport().set_input_as_handled()


func _cycle_card_focus(dir: int) -> void:
	var cur: int = 0
	for i in range(_card_buttons.size()):
		if (_card_buttons[i] as Button).has_focus():
			cur = i
			break
	(_card_buttons[(cur + dir + _card_buttons.size()) % _card_buttons.size()] as Button).grab_focus()


func _build_overlay() -> void:
	# Dim full-screen backdrop (click-blocker for outside-card area).
	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.72)
	backdrop.anchor_right = 1.0
	backdrop.anchor_bottom = 1.0
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	backdrop.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(backdrop)

	# Title.
	var title := Label.new()
	title.text = TITLE_TEXT
	title.add_theme_font_size_override("font_size", 38)
	title.add_theme_color_override("font_color", Color(1.0, 0.88, 0.40))
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	title.add_theme_constant_override("shadow_offset_x", 2)
	title.add_theme_constant_override("shadow_offset_y", 2)
	title.anchor_left = 0.0
	title.anchor_right = 1.0
	title.anchor_top = 0.0
	title.offset_top = 70.0
	title.offset_bottom = 118.0
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(title)

	# Subtitle hint.
	var sub := Label.new()
	sub.text = SUBTITLE_TEXT
	sub.add_theme_font_size_override("font_size", 18)
	sub.add_theme_color_override("font_color", Color(0.85, 0.85, 0.92))
	sub.anchor_left = 0.0
	sub.anchor_right = 1.0
	sub.anchor_top = 0.0
	sub.offset_top = 120.0
	sub.offset_bottom = 150.0
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(sub)

	# Two cards centered horizontally.
	var viewport_w: float = float(get_viewport().get_visible_rect().size.x)
	var total_w: float = (CARD_WIDTH * 2.0) + CARD_SPACING
	var start_x: float = (viewport_w - total_w) * 0.5
	var card_y: float = 200.0
	for i in range(_previews.size()):
		var preview: Dictionary = _previews[i]
		var card_btn: Button = _make_card_button(preview, i)
		card_btn.offset_left   = start_x + float(i) * (CARD_WIDTH + CARD_SPACING)
		card_btn.offset_top    = card_y
		card_btn.offset_right  = card_btn.offset_left + CARD_WIDTH
		card_btn.offset_bottom = card_y + CARD_HEIGHT
		card_btn.process_mode = Node.PROCESS_MODE_ALWAYS
		card_btn.pressed.connect(_on_card_pressed.bind(i))
		add_child(card_btn)
		_card_buttons.append(card_btn)

	# Bottom hint.
	var hint := Label.new()
	hint.text = "←/→ navigate    ENTER / A to pick"
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", Color(0.70, 0.66, 0.78, 0.85))
	hint.anchor_left = 0.0
	hint.anchor_right = 1.0
	hint.anchor_top = 1.0
	hint.anchor_bottom = 1.0
	hint.offset_top = -50.0
	hint.offset_bottom = -22.0
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(hint)


# ---------------------------------------------------------------------------
# Card builder — one Button-with-child-Labels per door preview.
# Color-codes by family + rarity to mirror BoonOffer's visual language.
# ---------------------------------------------------------------------------
func _make_card_button(preview: Dictionary, idx: int) -> Button:
	var btn := Button.new()
	btn.text = ""
	btn.focus_mode = Control.FOCUS_ALL
	# Custom stylebox — colored border by family, dark fill, big.
	var family: String = String(preview.get("family", "")).capitalize()
	var family_color: Color = RunState.get_family_color(family) if family != "" else Color(0.6, 0.6, 0.6)
	var rarity: String = String(preview.get("rarity", "common"))
	var rarity_color: Color = RunState.get_rarity_color(rarity)
	var ptype: String = String(preview.get("type", "boon"))
	# Special-case overrides for non-boon types.
	if ptype == "boss":
		family_color = Color(0.95, 0.30, 0.20)
		rarity_color = Color(1.00, 0.55, 0.15)
	elif ptype == "apple_juice":
		family_color = Color(0.30, 0.80, 0.95)
		rarity_color = Color(0.60, 0.95, 1.00)
	elif ptype == "apple_pie":
		family_color = Color(0.85, 0.45, 0.30)
		rarity_color = Color(1.00, 0.78, 0.30)
	elif ptype == "legendary":
		rarity_color = Color(1.00, 0.85, 0.20)

	var sb_normal := StyleBoxFlat.new()
	sb_normal.bg_color = Color(0.08, 0.06, 0.12, 0.96)
	sb_normal.border_color = family_color
	sb_normal.border_width_left   = 4
	sb_normal.border_width_right  = 4
	sb_normal.border_width_top    = 4
	sb_normal.border_width_bottom = 4
	sb_normal.corner_radius_top_left = 10
	sb_normal.corner_radius_top_right = 10
	sb_normal.corner_radius_bottom_left = 10
	sb_normal.corner_radius_bottom_right = 10

	var sb_hover := sb_normal.duplicate()
	sb_hover.border_width_left = 6
	sb_hover.border_width_right = 6
	sb_hover.border_width_top = 6
	sb_hover.border_width_bottom = 6
	sb_hover.bg_color = Color(0.14, 0.10, 0.18, 1.0)

	var sb_focus := sb_hover.duplicate()
	sb_focus.shadow_color = Color(rarity_color.r, rarity_color.g, rarity_color.b, 0.55)
	sb_focus.shadow_size = 10

	var sb_pressed := sb_hover.duplicate()
	sb_pressed.bg_color = Color(0.22, 0.18, 0.10, 1.0)

	btn.add_theme_stylebox_override("normal",  sb_normal)
	btn.add_theme_stylebox_override("hover",   sb_hover)
	btn.add_theme_stylebox_override("focus",   sb_focus)
	btn.add_theme_stylebox_override("pressed", sb_pressed)

	# Inner labels — laid out on top of the button. Buttons can host children
	# as decorations; we add Labels for the door header, family banner, etc.

	# Door header (DOOR 1 / DOOR 2).
	var header := Label.new()
	header.text = "DOOR %d" % (idx + 1)
	header.add_theme_font_size_override("font_size", 22)
	header.add_theme_color_override("font_color", Color(0.95, 0.92, 0.78))
	header.anchor_left = 0.0
	header.anchor_right = 1.0
	header.offset_top = 16.0
	header.offset_bottom = 50.0
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.process_mode = Node.PROCESS_MODE_ALWAYS
	btn.add_child(header)

	# Family banner (only meaningful for "boon" + "legendary").
	if family != "" and ptype != "boss" and ptype != "apple_juice" and ptype != "apple_pie":
		var fam_label := Label.new()
		fam_label.text = family.to_upper()
		fam_label.add_theme_font_size_override("font_size", 18)
		fam_label.add_theme_color_override("font_color", family_color)
		fam_label.anchor_left = 0.0
		fam_label.anchor_right = 1.0
		fam_label.offset_top = 64.0
		fam_label.offset_bottom = 92.0
		fam_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		fam_label.process_mode = Node.PROCESS_MODE_ALWAYS
		btn.add_child(fam_label)

	# Rarity chip (only for "boon" + "legendary").
	if ptype == "boon" or ptype == "legendary":
		var rarity_label := Label.new()
		rarity_label.text = RunState.RARITY_LABEL.get(rarity, rarity.to_upper())
		rarity_label.add_theme_font_size_override("font_size", 14)
		rarity_label.add_theme_color_override("font_color", rarity_color)
		rarity_label.anchor_left = 0.0
		rarity_label.anchor_right = 1.0
		rarity_label.offset_top = 96.0
		rarity_label.offset_bottom = 118.0
		rarity_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		rarity_label.process_mode = Node.PROCESS_MODE_ALWAYS
		btn.add_child(rarity_label)

	# Main preview body — the big text block.
	var body := Label.new()
	body.text = String(preview.get("label", "?"))
	body.add_theme_font_size_override("font_size", 22)
	body.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
	body.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	body.add_theme_constant_override("shadow_offset_x", 1)
	body.add_theme_constant_override("shadow_offset_y", 1)
	body.anchor_left = 0.0
	body.anchor_right = 1.0
	body.offset_left = 14.0
	body.offset_right = -14.0
	body.offset_top = 140.0
	body.offset_bottom = 300.0
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.process_mode = Node.PROCESS_MODE_ALWAYS
	btn.add_child(body)

	# Footer hint.
	var footer := Label.new()
	footer.text = "Click to enter"
	footer.add_theme_font_size_override("font_size", 13)
	footer.add_theme_color_override("font_color", Color(0.78, 0.74, 0.85, 0.85))
	footer.anchor_left = 0.0
	footer.anchor_right = 1.0
	footer.offset_top = 332.0
	footer.offset_bottom = 360.0
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer.process_mode = Node.PROCESS_MODE_ALWAYS
	btn.add_child(footer)

	return btn


# ---------------------------------------------------------------------------
# Card press handler — commit the chosen preview into RunState, then
# notify World.gd so it can begin the next-arena transition.
# ---------------------------------------------------------------------------
func _on_card_pressed(idx: int) -> void:
	if _picked:
		return
	_picked = true
	var chosen: Dictionary = _previews[idx] if idx < _previews.size() else {}
	# Commit the chosen reward into RunState so next-room BoonOffer can honor it.
	RunState.commit_door_choice(chosen)
	print("[DoorChoice] Door %d picked — %s" % [idx + 1, chosen.get("label", "(unlabeled)")])
	emit_signal("door_picked", idx, chosen)
	# Briefly fade ourselves out so the world isn't stuck behind the modal
	# during the scene transition that World.gd kicks off.
	get_tree().paused = false
	queue_free()
