extends Control

# ============================================================
# RunComplete.gd — Run 23 (2026-06-01)
# ============================================================
# Shown after the boss dies in BossArena.tscn. Displays a
# congratulatory banner, a quick run summary (boons + apple
# pies + apple juices used), and a "RETURN TO MAIN MENU" button.
#
# Button is keyboard/gamepad/mouse navigable (it auto-grabs focus
# on _ready so the user can immediately press Enter / A).
# ============================================================

const DOJO_PATH: String = "res://scenes/Dojo.tscn"

const COLOR_GOLD_BORDER: Color = Color(0.85, 0.70, 0.25, 1.0)
const COLOR_GOLD_BRIGHT: Color = Color(1.00, 0.88, 0.40, 1.0)

@onready var summary_label: Label  = $SummaryLabel
@onready var return_btn:    Button = $ReturnButton

var _returning: bool = false
var _finalized: bool = false


func _ready() -> void:
	# Fade-in for the win screen.
	if get_node_or_null("/root/FX") and FX.has_method("fade_from_black"):
		FX.fade_from_black(0.5)

	return_btn.pressed.connect(_on_return_pressed)
	return_btn.text = "Return to Dojo"
	return_btn.grab_focus()
	_style_button(return_btn)
	_populate_summary()
	# Run 70 — persist the WON state the instant this screen shows (see below).
	_finalize_run()


func _populate_summary() -> void:
	if summary_label == null:
		return
	var rs := get_node_or_null("/root/RunState")
	var boon_count: int = 0
	var pie_count: int = 0
	var juice_count: int = 0
	var arenas: int = 0
	if rs:
		if "boons_taken" in rs:
			boon_count = rs.boons_taken.size()
		if "apple_pie_stacks" in rs:
			pie_count = rs.apple_pie_stacks
		if "apple_juice_consumed_count" in rs:
			juice_count = rs.apple_juice_consumed_count
		if "arenas_cleared" in rs:
			arenas = rs.arenas_cleared

	# Run 61 — AI Helper Tier high-water mark + SOLO SAVANT accolade.
	var tier_line: String = ""
	var accolade: String = ""
	if rs and "highest_ai_tier_used_this_run" in rs:
		var hi: int = int(rs.highest_ai_tier_used_this_run)
		var spec: Dictionary = {}
		if rs.has_method("get_ai_tier_spec"):
			spec = rs.get_ai_tier_spec(hi)
		tier_line = "\nHighest AI Helper Tier Used: Tier %d (%s)" % [hi, str(spec.get("name", ""))]
		if rs.has_method("is_solo_savant_run") and rs.is_solo_savant_run():
			# Plain text — summary_label is a Label (no BBCode); the bordered
			# divider lines + uppercase make the accolade pop on its own.
			accolade = "\n\n--- SOLO SAVANT ---\nNo-help run — Tier 1 the whole way."

	# Phase 4 — the win screen used to print counts only ("Boons taken: 12")
	# and never said WHICH twelve, so the build you spent the run assembling
	# vanished without a look at it. Time and kills come from run_stats.
	var time_line: String = ""
	var kill_line: String = ""
	var boon_line: String = ""
	if rs and "run_stats" in rs:
		var st: Dictionary = rs.run_stats
		time_line = "   |   Time: %s" % StatsState.format_duration(StatsState.elapsed_ms(st))
		kill_line = "   |   Enemies felled: %d" % int(st.get("enemies_killed", 0))
		var ids: Array = st.get("boon_ids", [])
		if not ids.is_empty():
			var names: PackedStringArray = []
			for id in ids:
				var entry: Dictionary = BoonDB.BOON_POOL.get(String(id), {})
				names.append(String(entry.get("name", String(id))))
			boon_line = "\n\nYour build:  " + "  ·  ".join(names)

	summary_label.text = "Arenas cleared: %d   |   Boons taken: %d   |   Apple Pies used: %d   |   Apple Juices used: %d%s%s\n\nDragon Souls earned: %d%s%s%s" % [
		arenas, boon_count, pie_count, juice_count,
		time_line, kill_line,
		(rs.dragon_souls if rs and "dragon_souls" in rs else 0),
		tier_line, accolade, boon_line,
	]


# Run 70 — Persist the WON, run-over state the moment this screen appears.
# Bug it fixes: previously the slot was last saved by ShadowSenseiArena WITH
# resume_scene_path still pointing at the Sensei duel, and RunComplete only
# re-saved when "Return to Dojo" was pressed. So closing the game on THIS screen
# left a save that resumed back into the Sensei fight on relaunch — which also
# re-awarded the victory Dragon Soul every time (infinite-spark exploit).
#
# Now: clear the resume path and reset_run() (meta currency such as
# dragon_souls is preserved by reset_run — only the in-run state is wiped),
# then write the slot. _populate_summary() already ran above and baked its
# numbers into the label text, so resetting here doesn't blank the on-screen
# stats. After this, closing the game and relaunching loads a clean, run-over
# save that boots straight to the Dojo with no re-fight and no extra spark.
func _finalize_run() -> void:
	if _finalized:
		return
	_finalized = true
	var rs := get_node_or_null("/root/RunState")
	if rs:
		# Run 117 — bank hidden karma from this run's boons BEFORE reset_run()
		# wipes boons_taken (the save below persists it).
		if rs.has_method("bank_run_karma"):
			rs.bank_run_karma()
		# Phase 4 — freeze the timer and roll this run into the lifetime records
		# as a WIN. Must also happen before reset_run() clears run_stats.
		# _populate_summary() has already read its numbers, so this is safe here.
		StatsState.end_run(rs.run_stats)
		StatsState.bank_run(rs.run_stats, rs.lifetime_stats, true)
		if "resume_scene_path" in rs:
			rs.resume_scene_path = ""
		if rs.has_method("reset_run"):
			rs.reset_run()
	var sm: Node = get_node_or_null("/root/SaveManager")
	if sm and sm.has_method("save_active_slot") and sm.active_slot >= 0:
		sm.save_active_slot()
		Log.dbg("[RunComplete] Run finalized + saved (resume cleared, run reset, sparks kept).")


func _process(_delta: float) -> void:
	# Pulse the focused button gold-bright.
	if return_btn.has_focus():
		return_btn.add_theme_color_override("font_color", COLOR_GOLD_BRIGHT)
	else:
		return_btn.add_theme_color_override("font_color", COLOR_GOLD_BORDER)


func _on_return_pressed() -> void:
	if _returning:
		return
	_returning = true
	Log.dbg("[RunComplete] Returning to Dojo.")
	if get_node_or_null("/root/FX") and FX.has_method("fade_to_black"):
		FX.fade_to_black(0.4, 0.05, 1.0, Callable(self, "_do_return"))
	else:
		_do_return()


func _do_return() -> void:
	# Run 70 — _finalize_run() already cleared the resume path, reset the run,
	# and saved when this screen opened, so the slot is already in its clean
	# run-over state here. Call it once more defensively (idempotent via the
	# _finalized guard / repeated reset is a no-op) in case finalize was skipped,
	# then head to the Dojo.
	_finalize_run()
	get_tree().change_scene_to_file(DOJO_PATH)


func _style_button(btn: Button) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.09, 0.13, 0.95)
	sb.border_width_left = 3
	sb.border_width_right = 3
	sb.border_width_top = 3
	sb.border_width_bottom = 3
	sb.border_color = COLOR_GOLD_BORDER
	sb.corner_radius_top_left = 6
	sb.corner_radius_top_right = 6
	sb.corner_radius_bottom_left = 6
	sb.corner_radius_bottom_right = 6
	sb.content_margin_left = 24
	sb.content_margin_right = 24
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	var sb_hover := sb.duplicate()
	sb_hover.border_color = COLOR_GOLD_BRIGHT
	sb_hover.border_width_left = 4
	sb_hover.border_width_right = 4
	sb_hover.border_width_top = 4
	sb_hover.border_width_bottom = 4
	var sb_focus := sb_hover.duplicate()
	sb_focus.shadow_color = Color(COLOR_GOLD_BRIGHT.r, COLOR_GOLD_BRIGHT.g, COLOR_GOLD_BRIGHT.b, 0.45)
	sb_focus.shadow_size = 7
	btn.add_theme_stylebox_override("normal",  sb)
	btn.add_theme_stylebox_override("hover",   sb_hover)
	btn.add_theme_stylebox_override("focus",   sb_focus)
	btn.add_theme_stylebox_override("pressed", sb_hover)
	btn.add_theme_color_override("font_color", COLOR_GOLD_BORDER)
	btn.add_theme_color_override("font_hover_color", COLOR_GOLD_BRIGHT)
	btn.add_theme_color_override("font_focus_color", COLOR_GOLD_BRIGHT)
	btn.add_theme_font_size_override("font_size", 26)
