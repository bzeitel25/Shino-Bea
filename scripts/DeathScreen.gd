class_name DeathScreen
extends CanvasLayer
# ============================================================
# DeathScreen.gd — end-of-run defeat screen  (Phase 4c)
# ============================================================
# ⚠ The `class_name` above is REQUIRED, not decoration. Shino.gd calls
# `DeathScreen.show_for(self)`; without a class_name that identifier does not
# exist globally and the script fails to parse with
#     Identifier "DeathScreen" not declared in the current scope.
# which took the game down on save load. (Fixed 2026-08-01 — gdcheck now has a
# check for exactly this: a used `Foo.` where Foo.gd exists but declares no
# class_name and is not an autoload.)
# ============================================================
# Replaces the old inline _show_death_recap() in Shino.gd, which drew a single
# Label for 1.4 seconds and then force-loaded the Dojo. The player could not
# read it at their own pace, could not see what killed them, could not see the
# build they had spent 40 minutes assembling, and could not quit from it.
#
# The death screen is the most-viewed screen in any roguelite. This one waits
# for input and shows the run.
#
# ── BUILT IN CODE, NOT A .tscn ──────────────────────────────
# Matches the Run 158 convention used by HintPopup / PauseManager / the Phase 3
# controls sheet: PanelContainer > VBoxContainer, no anchors_preset assignment
# (Run 137: that is a no-op in code — use set_anchors_and_offsets_preset()).
#
# ── LIFECYCLE ───────────────────────────────────────────────
# Shino._handle_death() fades to black, then calls show_death_screen(). Nothing
# is finalised until the player chooses:
#
#     RETURN TO DOJO  -> RunState.finalize_defeat() -> Dojo.tscn
#     QUIT TO MENU    -> RunState.finalize_defeat() -> MainMenu.tscn
#
# finalize_defeat() is the single canonical defeat sequence (karma, stats, save,
# reset) shared with the pause menu's ABANDON RUN — see RunState.finalize_defeat.
# ============================================================

const DOJO_PATH: String      = "res://scenes/Dojo.tscn"
const MAIN_MENU_PATH: String = "res://scenes/MainMenu.tscn"

const COLOR_BLOOD: Color     = Color(0.92, 0.32, 0.28, 1.0)
const COLOR_GOLD: Color      = Color(0.96, 0.82, 0.32, 1.0)
const COLOR_GOLD_DIM: Color  = Color(0.70, 0.62, 0.35, 1.0)
const COLOR_TEXT: Color      = Color(0.88, 0.88, 0.93, 1.0)
const COLOR_TEXT_DIM: Color  = Color(0.62, 0.62, 0.70, 1.0)
const COLOR_PANEL: Color     = Color(0.07, 0.05, 0.08, 0.98)

var _acting: bool = false   # guards double-activation while a scene change runs


## Entry point. Builds and shows the screen over whatever is on screen.
static func show_for(host: Node) -> void:
	if host == null or not host.is_inside_tree():
		return
	# Direct construction now that the class is globally named — no path string
	# to drift if the file is ever moved.
	var screen := DeathScreen.new()
	host.get_tree().root.add_child(screen)


func _init() -> void:
	layer = 90                      # above HUD (10), below pause (100)
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	# Run 164c — apply the "Ink & Washi" skin to everything built below.
	UISkin.skin_tree_deferred(self)
	# The run may have paused the tree on its way down; this screen must work
	# regardless, and the game underneath should stay frozen.
	get_tree().paused = true
	FX.play_sound("run_lose")
	_build()


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------
func _build() -> void:
	var rs: Node = get_node_or_null("/root/RunState")
	var stats: Dictionary = {}
	var lifetime: Dictionary = {}
	if rs != null:
		if "run_stats" in rs:
			stats = rs.run_stats
		if "lifetime_stats" in rs:
			lifetime = rs.lifetime_stats

	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(root)

	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.88)
	root.add_child(dim)

	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -300.0
	panel.offset_top = -250.0
	panel.offset_right = 300.0
	panel.offset_bottom = 250.0
	var sb := StyleBoxFlat.new()
	sb.bg_color = COLOR_PANEL
	sb.border_color = COLOR_BLOOD
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(24)
	panel.add_theme_stylebox_override("panel", sb)
	root.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	# --- Title ---
	var title := Label.new()
	title.text = "✦  THE DREAM ENDS  ✦"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", COLOR_BLOOD)
	title.add_theme_font_size_override("font_size", 34)
	vbox.add_child(title)

	# --- Cause of death: the single most-wanted piece of information ---
	var cause_src: String = String(stats.get("cause_of_death", ""))
	var fallen: String = String(stats.get("killed_by", ""))
	var cause := Label.new()
	cause.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cause.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cause.custom_minimum_size = Vector2(520, 0)
	cause.add_theme_color_override("font_color", COLOR_TEXT)
	cause.add_theme_font_size_override("font_size", 17)
	var who: String = "Bea" if fallen == "bea" else "Shino"
	if cause_src == "":
		cause.text = "The ninjas fell together."
	else:
		cause.text = "%s fell to %s." % [who, StatsState.pretty_cause(cause_src)]
	vbox.add_child(cause)

	vbox.add_child(_divider())

	# --- Run figures, two columns ---
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 6)
	vbox.add_child(grid)

	var elapsed: int = StatsState.elapsed_ms(stats) if not stats.is_empty() else 0
	_stat(grid, "Time",           StatsState.format_duration(elapsed))
	_stat(grid, "Rooms cleared",  str(stats.get("rooms_cleared", 0)))
	_stat(grid, "Enemies felled", str(stats.get("enemies_killed", 0)))
	_stat(grid, "Bosses",         str(stats.get("bosses_killed", 0)))
	_stat(grid, "Damage dealt",   str(stats.get("damage_dealt", 0)))
	_stat(grid, "Damage taken",   str(stats.get("damage_taken", 0)))
	_stat(grid, "Coins",          str(stats.get("coins_earned", 0)))
	_stat(grid, "Times downed",   str(stats.get("times_downed", 0)))

	# --- Personal best comparison — the "one more run" hook ---
	var best: int = int(lifetime.get("best_arenas", 0))
	var rooms: int = int(stats.get("rooms_cleared", 0))
	var record := Label.new()
	record.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	record.add_theme_font_size_override("font_size", 14)
	if rooms > 0 and rooms >= best:
		record.text = "★  NEW BEST RUN  ★"
		record.add_theme_color_override("font_color", COLOR_GOLD)
	else:
		record.text = "Best run so far: %d rooms" % best
		record.add_theme_color_override("font_color", COLOR_TEXT_DIM)
	vbox.add_child(record)

	vbox.add_child(_divider())

	# --- The build you were running ---
	var boon_ids: Array = stats.get("boon_ids", [])
	var boons_title := Label.new()
	boons_title.text = "BOONS (%d)" % boon_ids.size()
	boons_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	boons_title.add_theme_color_override("font_color", COLOR_GOLD_DIM)
	boons_title.add_theme_font_size_override("font_size", 14)
	vbox.add_child(boons_title)

	var boons := RichTextLabel.new()
	boons.bbcode_enabled = true
	boons.fit_content = true
	boons.scroll_active = false
	boons.custom_minimum_size = Vector2(520, 44)
	boons.text = _boon_list_bbcode(boon_ids)
	vbox.add_child(boons)

	# --- Actions ---
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 8)
	vbox.add_child(spacer)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 16)
	vbox.add_child(row)

	var dojo_btn := _make_button("RETURN TO DOJO", COLOR_GOLD)
	var menu_btn := _make_button("QUIT TO MENU", COLOR_GOLD_DIM)
	row.add_child(dojo_btn)
	row.add_child(menu_btn)
	dojo_btn.pressed.connect(_on_return_to_dojo)
	menu_btn.pressed.connect(_on_quit_to_menu)
	dojo_btn.grab_focus()


## Boon ids rendered with their family colours, so the build reads at a glance.
func _boon_list_bbcode(ids: Array) -> String:
	if ids.is_empty():
		return "[center][color=#7a7a86]No boons taken.[/color][/center]"
	var parts: PackedStringArray = []
	for id in ids:
		var sid := String(id)
		var entry: Dictionary = BoonDB.BOON_POOL.get(sid, {})
		var nm: String = String(entry.get("name", sid))
		var col: Color = entry.get("color", COLOR_TEXT)
		parts.append("[color=#%s]%s[/color]" % [col.to_html(false), nm])
	return "[center]" + "   ·   ".join(parts) + "[/center]"


func _stat(grid: GridContainer, label_text: String, value: String) -> void:
	var l := Label.new()
	l.text = label_text
	l.custom_minimum_size = Vector2(140, 0)
	l.add_theme_color_override("font_color", COLOR_TEXT_DIM)
	l.add_theme_font_size_override("font_size", 14)
	grid.add_child(l)

	var v := Label.new()
	v.text = value
	v.custom_minimum_size = Vector2(90, 0)
	v.add_theme_color_override("font_color", COLOR_TEXT)
	v.add_theme_font_size_override("font_size", 16)
	grid.add_child(v)


func _divider() -> Control:
	var line := ColorRect.new()
	line.color = Color(1.0, 1.0, 1.0, 0.10)
	line.custom_minimum_size = Vector2(0, 1)
	return line


func _make_button(text: String, accent: Color) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(190, 44)
	btn.focus_mode = Control.FOCUS_ALL
	btn.process_mode = Node.PROCESS_MODE_ALWAYS

	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.12, 0.10, 0.14, 1.0)
	normal.border_color = accent
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(6)
	btn.add_theme_stylebox_override("normal", normal)

	var focused := StyleBoxFlat.new()
	focused.bg_color = Color(0.22, 0.17, 0.10, 1.0)
	focused.border_color = accent
	focused.set_border_width_all(3)
	focused.set_corner_radius_all(6)
	btn.add_theme_stylebox_override("focus", focused)
	btn.add_theme_stylebox_override("hover", focused)

	btn.add_theme_color_override("font_color", accent)
	btn.add_theme_color_override("font_focus_color", Color(1, 1, 1, 1))
	btn.add_theme_font_size_override("font_size", 19)
	return btn


# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
func _on_return_to_dojo() -> void:
	_finish(DOJO_PATH)


func _on_quit_to_menu() -> void:
	_finish(MAIN_MENU_PATH)


## Runs the canonical defeat sequence, then leaves. Unpausing before the scene
## change matters — change_scene_to_file on a paused tree leaves the next scene
## frozen with no way to unpause it.
func _finish(scene_path: String) -> void:
	if _acting:
		return
	_acting = true

	var rs: Node = get_node_or_null("/root/RunState")
	if rs != null and rs.has_method("finalize_defeat"):
		rs.finalize_defeat()

	get_tree().paused = false
	if not ResourceLoader.exists(scene_path):
		push_error("[DeathScreen] Missing scene: %s" % scene_path)
		_acting = false
		return
	get_tree().change_scene_to_file(scene_path)
	queue_free()
