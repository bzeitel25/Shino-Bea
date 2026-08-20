extends Node2D

# ============================================================
# BoonDispenser.gd — Dojo testing gadget (Run 39, 2026-06-10)
# ============================================================
# A vending-machine-style gadget on the north wall (a bit east
# of the Training Dummy). Talk to it ([E]) to open a two-stage
# picker:
#   Stage 0 — choose any boon FAMILY (all families listed)
#   Stage 1 — choose ANY boon from that family
# The boon is granted to whichever character the human is
# CURRENTLY controlling, so you can build test loadouts for
# Shino AND Bea and wail on the dummy.
#
# SANDBOX RULES:
#   - No family lock, no slot/prereq checks — this is a test rig.
#   - Granting any boon sets RunState.dojo_sandbox_used; Dojo's
#     _start_sleep() re-runs reset_run() so test builds never
#     carry into a real run.
#
# Controls (mirrors SenseiZ shop):
#   W/S or ↑↓ / d-pad  navigate
#   E / Enter / A      select (grant at stage 1 — stays open so
#                      you can stack multiple boons)
#   Y (attack_y)       remove selected boon from controlled ninja
#   X (attack_x)       same as Y (either button works)
#   Esc                back (stage 1 → families; families → close)
#
# Stage 0 has a "⟳ RESET ALL BOONS" row at top — selecting it
# calls reset_run() to wipe all boons for a clean slate.
#
# Scene tree expected (added to Dojo.tscn):
#   BoonDispenser (Node2D, this script)
#   ├ Body / Slot (ColorRects — placeholder art)
#   ├ NameLabel
#   ├ DispenserArea (Area2D) └ CollisionShape2D
#   └ InteractPrompt (Label)
# ============================================================

const COLOR_PANEL:    Color = Color(0.09, 0.08, 0.13, 0.98)
const COLOR_ACCENT:   Color = Color(0.35, 0.85, 0.65, 1.0)
const COLOR_DIM:      Color = Color(0.45, 0.50, 0.45, 1.0)
const COLOR_TEXT_DIM: Color = Color(0.72, 0.70, 0.66, 1.0)

var _bodies_near: Array = []
var _player_near: bool  = false
var _open:        bool  = false
var _stage:       int   = 0      # 0 = family list, 1 = boon list
var _sel_idx:     int   = 0
var _families:    Array = []     # family names present in BOON_POOL
var _cur_family:  String = ""
var _fam_boons:   Array = []     # boon ids of _cur_family

var _overlay:    CanvasLayer = null
var _row_nodes:  Array = []

# ── Stick nav gating ─────────────────────────────────────────
const NAV_INITIAL_DELAY: float = 1.5
const NAV_REPEAT_RATE:   float = 0.3
const NAV_COOLDOWN:      float = 0.18
var _nav_held_dir: int   = 0
var _nav_hold_time: float = 0.0
var _nav_repeat_acc: float = 0.0
var _nav_cooldown_t: float = 0.0
var _scroll:     ScrollContainer = null
var _header_lbl: Label = null
var _detail_lbl: Label = null
var _flash_lbl:  Label = null

@onready var interact_prompt: Label  = $InteractPrompt
@onready var dispenser_area:  Area2D = $DispenserArea


func _ready() -> void:
	# Run 39 — menu pauses the tree (full player freeze); keep processing so
	# the menu still receives input while paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	if interact_prompt:
		interact_prompt.visible = false
	if dispenser_area:
		dispenser_area.body_entered.connect(_on_area_entered)
		dispenser_area.body_exited.connect(_on_area_exited)
	# All families that actually have boons, in canonical FAM_COLOR order.
	# "Corrupt" is NOT a family (Bruno, Run 39): each real family owns exactly
	# one corrupt boon (corrupt_apple → Apple, etc.) and those list inside
	# their family. FAM_COLOR's "Corrupt" entry is tint-only — skip it.
	for fam in RunState.FAM_COLOR.keys():
		if String(fam) == "Corrupt":
			continue
		for id in RunState.BOON_POOL.keys():
			if String(RunState.BOON_POOL[id].get("family", "")) == String(fam):
				_families.append(String(fam))
				break


func _process(_delta: float) -> void:
	_refresh_player_near()
	# ── Polling-based stick nav (immune to wobble) ───────────────
	if _open:
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
				_move_sel(want); _nav_cooldown_t = NAV_COOLDOWN
		else:
			_nav_hold_time += _delta
			if _nav_hold_time >= NAV_INITIAL_DELAY:
				_nav_repeat_acc += _delta
				while _nav_repeat_acc >= NAV_REPEAT_RATE:
					_nav_repeat_acc -= NAV_REPEAT_RATE
					if _nav_cooldown_t <= 0.0:
						_move_sel(_nav_held_dir); _nav_cooldown_t = NAV_COOLDOWN


# Controlled-char-aware proximity (same pattern as SenseiZ, Run 38).
func _refresh_player_near() -> void:
	_player_near = false
	for b in _bodies_near:
		if not is_instance_valid(b):
			continue
		if "player_controlled" in b and bool(b.player_controlled):
			_player_near = true
			break
	if interact_prompt and not _open:
		interact_prompt.visible = _player_near


func _on_area_entered(body: Node) -> void:
	if not body.is_in_group("player"):
		return
	if not _bodies_near.has(body):
		_bodies_near.append(body)


func _on_area_exited(body: Node) -> void:
	_bodies_near.erase(body)


# Who is the human driving right now? ("shino" | "bea")
func _controlled_who() -> String:
	for p in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(p) and "player_controlled" in p and bool(p.player_controlled):
			return "bea" if p.is_in_group("bea") else "shino"
	return "shino"


func _unhandled_input(event: InputEvent) -> void:
	if _open:
		if event.is_action_pressed("ui_cancel") and not event.is_echo():
			if _stage == 1:
				_show_families()
			else:
				_close_ui()
			get_viewport().set_input_as_handled()
			return
		# Consume nav events — _process handles movement via polling.
		if event.is_action_pressed("move_up") or event.is_action_pressed("ui_up") \
		or event.is_action_pressed("move_down") or event.is_action_pressed("ui_down"):
			get_viewport().set_input_as_handled()
			return
		if (event.is_action_pressed("ui_accept") or event.is_action_pressed("attack_a") \
		or event.is_action_pressed("interact")) and not event.is_echo():
			_select_current()
			get_viewport().set_input_as_handled()
			return
		# Y / X — remove the highlighted boon from the controlled ninja.
		if _stage == 1 and not event.is_echo() \
		and (event.is_action_pressed("attack_y") or event.is_action_pressed("attack_x")):
			_remove_current()
			get_viewport().set_input_as_handled()
			return
	else:
		# Don't open on top of another pause-owning overlay (boon-inspect,
		# Sensei shop…).
		if _player_near and event.is_action_pressed("interact") and not event.is_echo() \
		and not get_tree().paused:
			_open_ui()
			get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# UI open / close
# ---------------------------------------------------------------------------

func _open_ui() -> void:
	_open = true
	get_tree().paused = true   # Run 39 — fully freeze both heroes while picking
	if interact_prompt:
		interact_prompt.visible = false

	_overlay = CanvasLayer.new()
	_overlay.layer = 50
	add_child(_overlay)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.70)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(bg)

	var panel_root := Control.new()
	panel_root.set_anchors_preset(Control.PRESET_CENTER)
	panel_root.custom_minimum_size = Vector2(720, 560)
	panel_root.position = Vector2(-360, -280)
	_overlay.add_child(panel_root)

	var panel_bg := StyleBoxFlat.new()
	panel_bg.bg_color = COLOR_PANEL
	panel_bg.border_width_left = 2;  panel_bg.border_width_right  = 2
	panel_bg.border_width_top  = 2;  panel_bg.border_width_bottom = 2
	panel_bg.border_color = COLOR_ACCENT
	panel_bg.corner_radius_top_left = 8;    panel_bg.corner_radius_top_right = 8
	panel_bg.corner_radius_bottom_left = 8; panel_bg.corner_radius_bottom_right = 8

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", panel_bg)
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel_root.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	_header_lbl = Label.new()
	_header_lbl.add_theme_color_override("font_color", COLOR_ACCENT)
	_header_lbl.add_theme_font_size_override("font_size", 20)
	_header_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_header_lbl)

	_flash_lbl = Label.new()
	_flash_lbl.add_theme_font_size_override("font_size", 13)
	_flash_lbl.add_theme_color_override("font_color", Color(0.95, 0.88, 0.45, 1.0))
	_flash_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_flash_lbl.text = " "
	vbox.add_child(_flash_lbl)

	vbox.add_child(HSeparator.new())

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_scroll)

	var rows_vbox := VBoxContainer.new()
	rows_vbox.name = "RowsVBox"
	rows_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows_vbox.add_theme_constant_override("separation", 4)
	_scroll.add_child(rows_vbox)

	vbox.add_child(HSeparator.new())

	_detail_lbl = Label.new()
	_detail_lbl.add_theme_font_size_override("font_size", 13)
	_detail_lbl.add_theme_color_override("font_color", COLOR_TEXT_DIM)
	_detail_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_lbl.custom_minimum_size = Vector2(0, 64)
	vbox.add_child(_detail_lbl)

	var footer := Label.new()
	footer.name = "FooterLabel"
	InputGlyphs.bind_label(footer, "{menu_nav}  Navigate     {accept}  Select     {attack_y} / {attack_x}  Remove boon     {cancel}  Back / Close")   # Run 158
	footer.add_theme_color_override("font_color", COLOR_DIM)
	footer.add_theme_font_size_override("font_size", 13)
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(footer)

	_show_families()


func _close_ui() -> void:
	_open = false
	get_tree().paused = false
	if _overlay:
		_overlay.queue_free()
		_overlay = null
	_row_nodes.clear()
	_scroll = null
	_header_lbl = null
	_detail_lbl = null
	_flash_lbl = null
	if _player_near and interact_prompt:
		interact_prompt.visible = true


# ---------------------------------------------------------------------------
# Stage building
# ---------------------------------------------------------------------------

func _rows_vbox() -> VBoxContainer:
	return _scroll.find_child("RowsVBox", true, false) as VBoxContainer


func _clear_rows() -> void:
	var vb := _rows_vbox()
	for ch in vb.get_children():
		ch.queue_free()
	_row_nodes.clear()


func _show_families() -> void:
	_stage = 0
	# +1 offset because row 0 is the Reset All row.
	_sel_idx = clampi(_families.find(_cur_family) + 1, 0, max(0, _families.size()))
	if _header_lbl:
		_header_lbl.text = "🥤  BOON DISPENSER  —  PICK A FAMILY"
	_clear_rows()
	var vb := _rows_vbox()
	# ── Reset All row ────────────────────────────────────────────
	var total_owned: int = RunState.shino_boon_set.size() + RunState.bea_boon_set.size()
	var reset_right: String = "%d boons active" % total_owned if total_owned > 0 else "no boons"
	var reset_row := _make_row("⟳  RESET ALL BOONS", Color(1.0, 0.45, 0.40, 1.0),
		reset_right, COLOR_TEXT_DIM)
	vb.add_child(reset_row)
	_row_nodes.append(reset_row)
	for fam in _families:
		var count: int = 0
		for id in RunState.BOON_POOL.keys():
			if String(RunState.BOON_POOL[id].get("family", "")) == fam:
				count += 1
		var fam_col: Color = RunState.FAM_COLOR.get(fam, COLOR_ACCENT)
		var row := _make_row(fam, fam_col, "%d boons" % count, COLOR_TEXT_DIM)
		vb.add_child(row)
		_row_nodes.append(row)
	_refresh_rows()


func _show_boons(fam: String) -> void:
	_stage = 1
	_cur_family = fam
	_sel_idx = 0
	_fam_boons.clear()
	for id in RunState.BOON_POOL.keys():
		if String(RunState.BOON_POOL[id].get("family", "")) == fam:
			_fam_boons.append(id)
	# Run 140 — sort boons by category: slot (Y/X/A/B/Charge/Ult/DD), passive,
	# legendary, corrupt. Within slot boons, order by slot type.
	_fam_boons.sort_custom(_boon_sort_cmp)
	if _header_lbl:
		_header_lbl.text = "🥤  %s BOONS  →  granting to %s" % [fam.to_upper(), _controlled_who().to_upper()]
	_clear_rows()
	var vb := _rows_vbox()
	var fam_col: Color = RunState.FAM_COLOR.get(fam, COLOR_ACCENT)
	for id in _fam_boons:
		var b: Dictionary = RunState.BOON_POOL[id]
		# Run 40 — rarity is rolled per-offer now; list shows the BASE tier
		# (common for everything except legendary/corrupt fixed tiers).
		var rarity: String = RunState.get_base_rarity(id)
		var right: String = String(RunState.RARITY_LABEL.get(rarity, rarity.to_upper()))
		var owned: String = _owned_marker(id)
		if owned != "":
			right += "   " + owned
		# Run 140 — prepend button pill icon for slot boons (Y/X/A/B/Ult).
		var display_name: String = String(b.get("name", id))
		var pill: String = _slot_pill(id)
		if pill != "":
			display_name = pill + "  " + display_name
		var row := _make_row(display_name, fam_col, right,
			RunState.RARITY_COLOR.get(rarity, COLOR_TEXT_DIM))
		vb.add_child(row)
		_row_nodes.append(row)
	_refresh_rows()


# Run 140 — Sort comparator for boon ordering inside a family.
# Order: 1) slot boons (Y→X→A→B→Charge→Ult→DD), 2) passives, 3) legendaries, 4) corrupts.
const _SLOT_ORDER: Dictionary = { "Y": 0, "X": 1, "A": 2, "B": 3, "Charge": 4, "Ult": 5 }

func _boon_sort_key(id: String) -> int:
	var b: Dictionary = RunState.BOON_POOL.get(id, {})
	var rarity: String = String(b.get("rarity", ""))
	if rarity == "corrupt":
		return 300        # category 4: corrupts last
	if rarity == "legendary":
		return 200        # category 3: legendaries
	# DD boons (family_dd: true) sort after Ult slot boons.
	if b.get("family_dd", false):
		return 6          # category 1, sub-order 6 (after Ult=5)
	var slot: String = String(b.get("boon_slot", ""))
	if slot != "" and slot in _SLOT_ORDER:
		return _SLOT_ORDER[slot]   # category 1: slot boons 0-5
	return 100            # category 2: passives

func _boon_sort_cmp(a: String, b: String) -> bool:
	return _boon_sort_key(a) < _boon_sort_key(b)


# Run 140 — Button pill label for slot boons. Returns e.g. "[Y]" or "" for non-slot.
const _PILL_SLOTS: Array = ["Y", "X", "A", "B", "Ult"]

func _slot_pill(boon_id: String) -> String:
	var b: Dictionary = RunState.BOON_POOL.get(boon_id, {})
	var slot: String = String(b.get("boon_slot", ""))
	if slot in _PILL_SLOTS:
		return "[%s]" % slot
	if b.get("family_dd", false):
		return "[DD]"
	if slot == "Charge":
		return "[Charge]"
	return ""


# "✓S x2  ✓B" style ownership marker for a boon id.
func _owned_marker(id: String) -> String:
	var parts: Array = []
	var s: int = int(RunState.shino_boon_set.get(id, 0))
	var b: int = int(RunState.bea_boon_set.get(id, 0))
	if s > 0:
		parts.append("✓S" + (" x%d" % s if s > 1 else ""))
	if b > 0:
		parts.append("✓B" + (" x%d" % b if b > 1 else ""))
	var lvl: int = RunState.get_boon_level(id)
	if lvl > 1:
		parts.append("Lv%d" % lvl)
	return "  ".join(parts)


func _make_row(left_text: String, left_col: Color, right_text: String, right_col: Color) -> PanelContainer:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.12, 0.17, 0.95)
	sb.border_width_left = 1;  sb.border_width_right  = 1
	sb.border_width_top  = 1;  sb.border_width_bottom = 1
	sb.border_color = COLOR_DIM
	sb.corner_radius_top_left = 4;    sb.corner_radius_top_right = 4
	sb.corner_radius_bottom_left = 4; sb.corner_radius_bottom_right = 4
	sb.content_margin_left = 12; sb.content_margin_right  = 12
	sb.content_margin_top  = 6;  sb.content_margin_bottom = 6

	var row := PanelContainer.new()
	row.add_theme_stylebox_override("panel", sb)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var hbox := HBoxContainer.new()
	row.add_child(hbox)

	var l := Label.new()
	l.name = "LeftLabel"
	l.text = left_text
	l.add_theme_font_size_override("font_size", 16)
	l.add_theme_color_override("font_color", left_col)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(l)

	var r := Label.new()
	r.name = "RightLabel"
	r.text = right_text
	r.add_theme_font_size_override("font_size", 13)
	r.add_theme_color_override("font_color", right_col)
	hbox.add_child(r)

	return row


func _move_sel(dir: int) -> void:
	if _row_nodes.is_empty():
		return
	_sel_idx = (_sel_idx + dir + _row_nodes.size()) % _row_nodes.size()
	_refresh_rows()


func _refresh_rows() -> void:
	for i in range(_row_nodes.size()):
		var row: PanelContainer = _row_nodes[i]
		if not is_instance_valid(row):
			continue
		var sb: StyleBoxFlat = row.get_theme_stylebox("panel").duplicate()
		if i == _sel_idx:
			sb.border_color = COLOR_ACCENT
			sb.bg_color = Color(0.18, 0.22, 0.20, 0.98)
			sb.border_width_left = 2;  sb.border_width_right  = 2
			sb.border_width_top  = 2;  sb.border_width_bottom = 2
		else:
			sb.border_color = COLOR_DIM
			sb.bg_color = Color(0.13, 0.12, 0.17, 0.95)
			sb.border_width_left = 1;  sb.border_width_right  = 1
			sb.border_width_top  = 1;  sb.border_width_bottom = 1
		row.add_theme_stylebox_override("panel", sb)
	# Keep the selection on screen.
	if _scroll and _sel_idx < _row_nodes.size() and is_instance_valid(_row_nodes[_sel_idx]):
		_scroll.ensure_control_visible(_row_nodes[_sel_idx])
	_refresh_detail()


func _refresh_detail() -> void:
	if _detail_lbl == null:
		return
	if _stage == 0:
		if _sel_idx == 0:
			_detail_lbl.text = "Wipe ALL boons from both Shino and Bea.\nStart fresh with a completely clean loadout."
		else:
			_detail_lbl.text = "Sandbox mode — grants ignore family locks and prereqs.\nTest boons are wiped when you sleep into a real run."
	elif _sel_idx < _fam_boons.size():
		var b: Dictionary = RunState.BOON_POOL.get(_fam_boons[_sel_idx], {})
		var pill: String = _slot_pill(_fam_boons[_sel_idx])
		var desc: String = String(b.get("desc", "")).replace("\n", " ")
		if pill != "":
			_detail_lbl.text = pill + "  " + desc
		else:
			_detail_lbl.text = desc
	else:
		_detail_lbl.text = ""


func _select_current() -> void:
	if _row_nodes.is_empty():
		return
	if _stage == 0:
		if _sel_idx == 0:
			# Row 0 = Reset All Boons
			_reset_all_boons()
		elif _sel_idx - 1 < _families.size():
			_show_boons(_families[_sel_idx - 1])
	else:
		if _sel_idx < _fam_boons.size():
			_grant(_fam_boons[_sel_idx])


# ---------------------------------------------------------------------------
# Granting — mirrors BoonOffer._pick() (apply + per-char ownership + DD map)
# ---------------------------------------------------------------------------

func _grant(boon_id: String) -> void:
	var who: String = _controlled_who()
	var b_data: Dictionary = RunState.BOON_POOL.get(boon_id, {})

	# Run 45 — non-stackable boons can only be held once per character
	# (sandbox skips family/prereq rules, NOT ownership rules).
	var own_set: Dictionary = RunState.shino_boon_set if who == "shino" else RunState.bea_boon_set
	if int(own_set.get(boon_id, 0)) > 0 and not bool(b_data.get("stackable", false)):
		if _flash_lbl:
			_flash_lbl.text = "%s already has %s." % [who.capitalize(), String(b_data.get("name", boon_id))]
		return

	# Run 40 — explicit base-rarity override so stale offer rolls from a
	# previous room can never leak into sandbox grants.
	RunState.apply_boon(boon_id, RunState.get_base_rarity(boon_id))
	RunState.add_boon_for(who, boon_id)

	# Run 45 — slot exclusivity (mirrors BoonOffer._pick): one boon per
	# Y/X/A/B/Charge/Ult slot per ninja; old slot boon is traded out.
	var traded_out: String = RunState.register_slot_pick(who, boon_id)

	# DD boons: grant the charge to the picker specifically.
	# Run 40 — sandbox grants are taken at base rarity (apply_boon recorded it).
	var rarity: String = RunState.get_boon_rarity(boon_id)
	match boon_id:
		"cider_mercy":    RunState.grant_dd_to_char(who, "apple_cider_mercy",        rarity)
		"iron_husk":      RunState.grant_dd_to_char(who, "coconut_iron_husk",        rarity)
		"green_vengeance":RunState.grant_dd_to_char(who, "broccoli_green_vengeance", rarity)
		"heart_shot":     RunState.grant_dd_to_char(who, "carrot_heart_shot",        rarity)
		"vintage_surge":  RunState.grant_dd_to_char(who, "grape_vintage_surge",      rarity)
		"tide_pool":      RunState.grant_dd_to_char(who, "watermelon_tide_pool",     rarity)
		"phoenix_pepper": RunState.grant_dd_to_char(who, "pepper_phoenix_pepper",    rarity)
		"stone_form":     RunState.grant_dd_to_char(who, "potato_stone_form",        rarity)
		"banana_splits":  RunState.grant_dd_to_char(who, "banana_banana_splits",     rarity)
		"death_bloom":    RunState.grant_dd_to_char(who, "onion_death_bloom",        rarity)

	# Re-apply stat modifiers on the receiving character only.
	_reapply_modifiers(who)

	RunState.dojo_sandbox_used = true

	# Refresh the HUD boon panels.
	_refresh_hud_boon_panel()

	if _flash_lbl:
		if traded_out != "":
			_flash_lbl.text = "Granted %s to %s! (traded out %s)" % [
				String(b_data.get("name", boon_id)), who.capitalize(),
				String(RunState.BOON_POOL.get(traded_out, {}).get("name", traded_out))]
		else:
			_flash_lbl.text = "Granted %s to %s!" % [String(b_data.get("name", boon_id)), who.capitalize()]
	Log.dbg("[BoonDispenser] Granted '%s' to %s (sandbox, traded_out='%s')" % [boon_id, who, traded_out])

	# Stay open and refresh ownership markers so builds can be stacked fast.
	_show_boons(_cur_family)
	_sel_idx = _fam_boons.find(boon_id)
	if _sel_idx < 0:
		_sel_idx = 0
	_refresh_rows()


# ---------------------------------------------------------------------------
# Removing boons (Y / X on a boon row at stage 1)
# ---------------------------------------------------------------------------

func _remove_current() -> void:
	if _sel_idx >= _fam_boons.size():
		return
	var boon_id: String = _fam_boons[_sel_idx]
	var who: String = _controlled_who()
	var own_set: Dictionary = RunState.shino_boon_set if who == "shino" else RunState.bea_boon_set
	if not (boon_id in own_set):
		if _flash_lbl:
			var bname: String = String(RunState.BOON_POOL.get(boon_id, {}).get("name", boon_id))
			_flash_lbl.text = "%s doesn't have %s." % [who.capitalize(), bname]
		return
	var bname: String = String(RunState.BOON_POOL.get(boon_id, {}).get("name", boon_id))
	RunState.remove_boon_from_char(who, boon_id)
	# Clear the slot registration so the slot is free again.
	var slot: String = RunState.get_slot_for_boon(boon_id)
	if slot != "":
		var slots: Dictionary = RunState.owned_slots_by_char.get(who, {})
		if String(slots.get(slot, "")) == boon_id:
			slots[slot] = ""
	# Re-apply stat modifiers on the affected character.
	_reapply_modifiers(who)
	# Refresh HUD.
	_refresh_hud_boon_panel()
	if _flash_lbl:
		_flash_lbl.text = "Removed %s from %s." % [bname, who.capitalize()]
	Log.dbg("[BoonDispenser] Removed '%s' from %s (sandbox)" % [boon_id, who])
	# Refresh the boon list to update ownership markers.
	var saved_idx: int = _sel_idx
	_show_boons(_cur_family)
	_sel_idx = clampi(saved_idx, 0, max(0, _row_nodes.size() - 1))
	_refresh_rows()


# ---------------------------------------------------------------------------
# Reset All Boons — full wipe (row 0 at stage 0)
# ---------------------------------------------------------------------------

func _reset_all_boons() -> void:
	var total: int = RunState.shino_boon_set.size() + RunState.bea_boon_set.size()
	if total == 0:
		if _flash_lbl:
			_flash_lbl.text = "No boons to reset."
		return
	RunState.reset_run()
	# Re-apply stat modifiers on both characters.
	_reapply_modifiers("shino")
	_reapply_modifiers("bea")
	# Refresh HUD.
	_refresh_hud_boon_panel()
	if _flash_lbl:
		_flash_lbl.text = "All %d boons wiped! Clean slate." % total
	Log.dbg("[BoonDispenser] Reset all boons (%d wiped)" % total)
	# Refresh the family list to update the count.
	_show_families()


# ---------------------------------------------------------------------------
# Helpers shared by remove / reset
# ---------------------------------------------------------------------------

func _reapply_modifiers(who: String) -> void:
	var grp: String = "bea" if who == "bea" else "player"
	for p in get_tree().get_nodes_in_group(grp):
		if who == "shino" and p.is_in_group("bea"):
			continue
		if p.has_method("apply_runstate_modifiers"):
			p.apply_runstate_modifiers()


func _refresh_hud_boon_panel() -> void:
	for h in get_tree().get_nodes_in_group("hud"):
		if h.has_method("refresh_boon_panel"):
			h.refresh_boon_panel()
			break
