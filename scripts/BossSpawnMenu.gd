extends CanvasLayer

# ============================================================
# BossSpawnMenu.gd - Run 173 - the Enemy Dispenser's loadout screen
# ============================================================
# Bruno: "I'd like an 'enemy dispenser' like the boon ones, that we can pick
# monsters to spawn in a room, then GO and it will spawn us in the test area or
# biome with the relevant monsters we picked."
#
# So this is NOT a spawn-on-click picker any more. You browse the roster, ADD
# entries to a squad, and press GO; the arena then loads with exactly that
# squad standing in it. Same shape as the Boon Dispenser next to it: walk up,
# build a set, commit.
#
# LOADOUT RULES (RunState owns the numbers):
#   ONE big per session - a boss OR a mini-boss, never both
#   up to FIVE minions alongside it
#   a partial squad is fine; you do not have to fill the slots to start
# The 10 "slots" on screen are just how that reads (a big fills five, a minion
# one) - the two CAPS are the rule, not the arithmetic.
#
# WHY THIS IS ITS OWN NODE RATHER THAN CODE INSIDE THE ROOM:
#   1. The screen pauses the tree. A PAUSED node receives no _input callbacks,
#      so a handler living on the (pausable) room node would freeze itself the
#      instant it opened - unable to navigate, add, or even close. This
#      CanvasLayer sets PROCESS_MODE_ALWAYS so it keeps taking input while
#      everything behind it is frozen. Its children must NOT be re-parented
#      onto a pausable node.
#   2. World.gd already defines _input() (H / Start toggle the controls panel).
#      Owning input here leaves that handler intact.
# ============================================================

const DB = preload("res://scripts/DreamBiomes.gd")

var arena: Node = null          # the Training Room, set on creation

var _root: PanelContainer = null
var _rows_box: VBoxContainer = null
var _squad_box: VBoxContainer = null
var _title: Label = null
var _budget_label: Label = null
var _status: Label = null

var _is_open: bool = false
var _page: int = 0
var _row: int = 0
var _pages: Array = []          # [{id, display, rows:[{label, cfg, kind}]}]
var _row_labels: Array = []
var _squad: Array = []          # [{cfg, kind, label, biome}]

const ROW_NORMAL: Color = Color(0.86, 0.88, 0.92)
const ROW_MINI:   Color = Color(1.00, 0.75, 0.25)
const ROW_BOSS:   Color = Color(1.00, 0.45, 0.25)
const ROW_PICK:   Color = Color(0.25, 0.95, 0.65)
const ROW_NORIG:  Color = Color(0.62, 0.55, 0.60)
const ROW_LOCKED: Color = Color(0.45, 0.40, 0.44)


func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS   # load-bearing - see header
	_build_roster()
	_build_ui()
	visible = false


# ---------------------------------------------------------------------------
# Roster - every enemy, mini-boss and boss the game defines, one page per biome
# ---------------------------------------------------------------------------

func _build_roster() -> void:
	_pages.clear()
	for id in DB.BIOMES.keys():
		var biome: Dictionary = DB.BIOMES[id]
		var rows: Array = []

		var mb: Dictionary = biome.get("miniboss", {})
		if not mb.is_empty() and mb.has("name"):
			rows.append({"label": "* " + String(mb["name"]), "cfg": mb, "kind": "miniboss"})
		var bs: Dictionary = biome.get("boss", {})
		if not bs.is_empty() and bs.has("name"):
			rows.append({"label": "# " + String(bs["name"]), "cfg": bs, "kind": "boss"})

		for ecfg in biome.get("enemies", []):
			var e: Dictionary = ecfg
			if not e.has("name"):
				continue
			# Run 126 left un-rigged monsters dormant in the roster; they would
			# spawn as untextured stick figures. Mark rather than hide - a rig
			# gap is exactly what a test rig should surface.
			var rigged: bool = String(e.get("sprite_rig", "")) != ""
			rows.append({
				"label": "  " + String(e["name"]) + ("" if rigged else "   (no rig)"),
				"cfg": e, "kind": "enemy", "rigged": rigged,
			})

		if rows.is_empty():
			continue
		_pages.append({"id": String(id), "display": String(biome.get("display", id)), "rows": rows})

	var here: String = String(RunState.current_biome)
	for i in range(_pages.size()):
		if String((_pages[i] as Dictionary)["id"]) == here:
			_page = i
			break


# ---------------------------------------------------------------------------
# Loadout rules
# ---------------------------------------------------------------------------

func _spent() -> int:
	var total: int = 0
	for e in _squad:
		total += RunState.training_cost(String((e as Dictionary)["kind"]))
	return total


# Bosses and mini-bosses share ONE slot between them — they are both "bigs".
func _count_bigs() -> int:
	var n: int = 0
	for e in _squad:
		if RunState.training_is_big(String((e as Dictionary)["kind"])):
			n += 1
	return n


func _count_minions() -> int:
	var n: int = 0
	for e in _squad:
		if not RunState.training_is_big(String((e as Dictionary)["kind"])):
			n += 1
	return n


# "" when the row can be added; otherwise the reason it can't.
func _reject_reason(kind: String) -> String:
	if RunState.training_is_big(kind):
		if _count_bigs() >= RunState.TRAINING_MAX_BIGS:
			return "one boss OR mini-boss per session, not both"
	elif _count_minions() >= RunState.TRAINING_MAX_MINIONS:
		return "%d minions max" % RunState.TRAINING_MAX_MINIONS
	return ""


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	_root = PanelContainer.new()
	# Run 166 lock: hand-styled panels opt out of the UISkin walker.
	_root.set_meta("_uiskin_skip", true)
	_root.anchor_left = 0.5
	_root.anchor_top = 0.5
	_root.anchor_right = 0.5
	_root.anchor_bottom = 0.5
	_root.offset_left = -400.0
	_root.offset_top = -270.0
	_root.offset_right = 400.0
	_root.offset_bottom = 270.0

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.07, 0.10, 0.96)
	sb.border_color = Color(0.95, 0.55, 0.30, 1.0)
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(14)
	_root.add_theme_stylebox_override("panel", sb)
	add_child(_root)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	_root.add_child(col)

	_title = _mk_label(18, Color(1.0, 0.72, 0.38))
	col.add_child(_title)

	var help: Label = _mk_label(11, Color(0.62, 0.68, 0.78))
	help.text = "One boss OR mini-boss, plus up to 5 minions. Partial squads are fine.\nUp/Down pick   Left/Right biome   Enter/A ADD   Backspace undo   X clear\n[ ] tier   G or Start = GO   Esc/B close"
	col.add_child(help)

	# Two columns: the roster on the left, the loaded squad on the right.
	var split := HBoxContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_theme_constant_override("separation", 14)
	col.add_child(split)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_stretch_ratio = 1.6
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(scroll)

	_rows_box = VBoxContainer.new()
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_box.add_theme_constant_override("separation", 1)
	scroll.add_child(_rows_box)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_stretch_ratio = 1.0
	right.add_theme_constant_override("separation", 2)
	split.add_child(right)

	_budget_label = _mk_label(15, Color(1.0, 0.85, 0.45))
	right.add_child(_budget_label)

	var squad_scroll := ScrollContainer.new()
	squad_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(squad_scroll)

	_squad_box = VBoxContainer.new()
	_squad_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_squad_box.add_theme_constant_override("separation", 1)
	squad_scroll.add_child(_squad_box)

	_status = _mk_label(12, Color(0.55, 0.95, 0.70))
	col.add_child(_status)

	_rebuild_rows()
	_refresh_squad()


func _mk_label(size: int, col: Color) -> Label:
	var lb := Label.new()
	lb.set_meta("_uiskin_skip", true)
	lb.add_theme_font_size_override("font_size", size)
	lb.add_theme_color_override("font_color", col)
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return lb


func _rebuild_rows() -> void:
	for c in _rows_box.get_children():
		c.queue_free()
	_row_labels.clear()
	if _pages.is_empty():
		return

	var page: Dictionary = _pages[_page]
	_title.text = "ENEMY DISPENSER  -  %s   (biome %d/%d)" % [
		String(page["display"]), _page + 1, _pages.size()]

	for r in (page["rows"] as Array):
		var lb := Label.new()
		lb.set_meta("_uiskin_skip", true)
		lb.add_theme_font_size_override("font_size", 14)
		lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		lb.text = String((r as Dictionary)["label"])
		_rows_box.add_child(lb)
		_row_labels.append(lb)

	_row = clampi(_row, 0, maxi(0, _row_labels.size() - 1))
	_refresh_highlight()


func _refresh_highlight() -> void:
	if _pages.is_empty():
		return
	var rows: Array = _pages[_page]["rows"]
	for i in range(_row_labels.size()):
		var lb: Label = _row_labels[i]
		var row: Dictionary = rows[i]
		var kind: String = String(row["kind"])
		var cost: int = RunState.training_cost(kind)
		var suffix: String = "   [%d]" % cost
		if i == _row:
			lb.add_theme_color_override("font_color", ROW_PICK)
			lb.text = "> " + String(row["label"]).strip_edges() + suffix
			continue
		var col: Color = ROW_NORMAL
		if _reject_reason(kind) != "":
			col = ROW_LOCKED
		elif kind == "miniboss":
			col = ROW_MINI
		elif kind == "boss":
			col = ROW_BOSS
		elif not bool(row.get("rigged", true)):
			col = ROW_NORIG
		lb.add_theme_color_override("font_color", col)
		lb.text = String(row["label"]) + suffix


func _refresh_squad() -> void:
	for c in _squad_box.get_children():
		c.queue_free()
	var spent: int = _spent()
	_budget_label.text = "SQUAD   %d / %d slots\nbig %d/%d   minions %d/%d" % [
		spent, RunState.TRAINING_BUDGET,
		_count_bigs(), RunState.TRAINING_MAX_BIGS,
		_count_minions(), RunState.TRAINING_MAX_MINIONS]

	if _squad.is_empty():
		var empty: Label = _mk_label(12, Color(0.55, 0.55, 0.62))
		empty.text = "(empty — add something)"
		_squad_box.add_child(empty)
		return

	# Collapse duplicates so a squad of six wisps reads as one line.
	var seen: Array = []
	var counts: Dictionary = {}
	for e in _squad:
		var key: String = String((e as Dictionary)["label"]).strip_edges()
		if not counts.has(key):
			counts[key] = 0
			seen.append({"key": key, "kind": String((e as Dictionary)["kind"])})
		counts[key] += 1

	for entry in seen:
		var key: String = String(entry["key"])
		var lb := Label.new()
		lb.set_meta("_uiskin_skip", true)
		lb.add_theme_font_size_override("font_size", 13)
		lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		var n: int = int(counts[key])
		lb.text = ("%dx " % n if n > 1 else "") + key
		var kind: String = String(entry["kind"])
		var col: Color = ROW_NORMAL
		if kind == "miniboss":
			col = ROW_MINI
		elif kind == "boss":
			col = ROW_BOSS
		lb.add_theme_color_override("font_color", col)
		_squad_box.add_child(lb)


func _set_status(msg: String) -> void:
	if _status:
		_status.text = msg


# ---------------------------------------------------------------------------
# Input. Only ever consumes what it handles, so World.gd's own _input (H and
# Start toggle the controls panel) keeps working when the screen is closed.
# ---------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	var key: int = -1
	if event is InputEventKey and event.pressed and not (event as InputEventKey).echo:
		key = (event as InputEventKey).keycode

	if key == KEY_TAB \
	or (event is InputEventJoypadButton and event.pressed \
		and (event as InputEventJoypadButton).button_index == JOY_BUTTON_BACK):
		toggle()
		get_viewport().set_input_as_handled()
		return

	if not _is_open:
		# Out-of-screen conveniences, so the on-screen hint tells the truth.
		# H is deliberately NOT used — World.gd owns it.
		match key:
			KEY_K:
				arena.kill_all()
				get_viewport().set_input_as_handled()
			KEY_J:
				arena.heal_heroes()
				get_viewport().set_input_as_handled()
		return

	# Swallow pause/cancel so PauseManager can't stack its overlay on us.
	if event.is_action_pressed("ui_cancel"):
		toggle()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("pause"):
		_go()
		get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("ui_down"):
		_move_row(1)
	elif event.is_action_pressed("ui_up"):
		_move_row(-1)
	elif event.is_action_pressed("ui_right"):
		_move_page(1)
	elif event.is_action_pressed("ui_left"):
		_move_page(-1)
	elif event.is_action_pressed("ui_accept"):
		_add()
	else:
		match key:
			KEY_G:            _go()
			KEY_BACKSPACE:    _remove_last()
			KEY_X:            _clear()
			KEY_BRACKETLEFT:  _tier(-1)
			KEY_BRACKETRIGHT: _tier(1)
			_:                return
	get_viewport().set_input_as_handled()


func toggle() -> void:
	_is_open = not _is_open
	visible = _is_open
	get_tree().paused = _is_open
	if _is_open:
		_rebuild_rows()
		_refresh_squad()
		_set_status("Load a squad, then GO.")


func _move_row(step: int) -> void:
	if _row_labels.is_empty():
		return
	_row = wrapi(_row + step, 0, _row_labels.size())
	_refresh_highlight()


func _move_page(step: int) -> void:
	if _pages.is_empty():
		return
	_page = wrapi(_page + step, 0, _pages.size())
	_row = 0
	_rebuild_rows()


func _tier(step: int) -> void:
	arena.set_sandbox_tier(arena.sandbox_tier() + step)
	_set_status("Tier %d" % arena.sandbox_tier())


func _add() -> void:
	if _pages.is_empty() or _row_labels.is_empty():
		return
	var page: Dictionary = _pages[_page]
	var row: Dictionary = (page["rows"] as Array)[_row]
	var kind: String = String(row["kind"])
	var reason: String = _reject_reason(kind)
	if reason != "":
		_set_status("Can't add %s — %s" % [String(row["label"]).strip_edges(), reason])
		return
	_squad.append({
		"cfg": (row["cfg"] as Dictionary).duplicate(true),
		"kind": kind,
		"label": String(row["label"]).strip_edges(),
		"biome": String(page["id"]),
	})
	_refresh_squad()
	_refresh_highlight()
	_set_status("Added %s   (%d/%d slots)" % [
		String(row["label"]).strip_edges(), _spent(), RunState.TRAINING_BUDGET])


func _remove_last() -> void:
	if _squad.is_empty():
		_set_status("Squad is already empty.")
		return
	var gone: Dictionary = _squad.pop_back()
	_refresh_squad()
	_refresh_highlight()
	_set_status("Removed %s   (%d/%d slots)" % [
		String(gone["label"]), _spent(), RunState.TRAINING_BUDGET])


func _clear() -> void:
	_squad.clear()
	_refresh_squad()
	_refresh_highlight()
	_set_status("Squad cleared.")


# GO - hand the squad to the arena.
func _go() -> void:
	if _squad.is_empty():
		_set_status("Nothing loaded — add at least one monster.")
		return
	# The arena is the biome of the boss if there is one, else of the first pick.
	var biome: String = String((_squad[0] as Dictionary)["biome"])
	for e in _squad:
		var k: String = String((e as Dictionary)["kind"])
		if k == "boss" or k == "miniboss":
			biome = String((e as Dictionary)["biome"])
			break
	_is_open = false
	visible = false
	arena.launch_training_arena(_squad, biome)
