extends Node
# ============================================================
# SaveManager.gd — autoload singleton "SaveManager"
# ============================================================
# Manages 3 named save-file slots stored in user://saves/.
# Each slot is a JSON file containing:
#   meta: { name, save_date, arenas_cleared, loops_completed, boons_count }
#   run:  { ...RunState.to_save_dict() }
#
# Public API:
#   get_slot_info(slot)         → Dictionary with meta, or {} if empty
#   is_slot_empty(slot)         → bool
#   create_new_slot(slot, name) → write blank meta, clear run data
#   save_active_slot()          → persist current RunState into active_slot
#   load_slot(slot)             → restore RunState from file, set active_slot
#   delete_slot(slot)           → remove file
#   copy_slot(from, to)         → duplicate file
#   active_slot                 → int (-1 = none active)
# ============================================================

const SAVE_DIR: String = "user://saves/"
const SLOT_COUNT: int  = 3

var active_slot: int = -1


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)


# ---------------------------------------------------------------------------
# Slot file path
# ---------------------------------------------------------------------------
func _slot_path(slot: int) -> String:
	return SAVE_DIR + "slot_%d.json" % slot


# ---------------------------------------------------------------------------
# Query
# ---------------------------------------------------------------------------
func is_slot_empty(slot: int) -> bool:
	return not FileAccess.file_exists(_slot_path(slot))


func get_slot_info(slot: int) -> Dictionary:
	if is_slot_empty(slot):
		return {}
	var file := FileAccess.open(_slot_path(slot), FileAccess.READ)
	if not file:
		return {}
	var text := file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed.get("meta", {})


# ---------------------------------------------------------------------------
# Create new slot (blank run, just name + date)
# ---------------------------------------------------------------------------
func create_new_slot(slot: int, save_name: String) -> void:
	var data := {
		"meta": {
			"name": save_name,
			"save_date": Time.get_date_string_from_system(),
			"arenas_cleared": 0,
			"loops_completed": 0,
			"boons_count": 0,
			"dragon_souls": 0,
		},
		"run": {}
	}
	_write_slot(slot, data)
	active_slot = slot
	# Reset RunState for a brand-new file: full wipe including meta currency.
	var rs := get_node_or_null("/root/RunState")
	if rs:
		if rs.has_method("reset_run"):
			rs.reset_run()
		# New file → no accumulated sparks or sensei upgrades.
		if "dragon_souls" in rs:
			rs.dragon_souls = 0
		for field in ["sensei_damage_pct", "sensei_dr_pct", "sensei_extra_dash",
				"sensei_extra_dd", "sensei_chi_regen", "sensei_hp_pct",
				"sensei_crit_pct", "sensei_speed_pct", "sensei_rarity_ranks",
				"sensei_legendary_ranks", "sensei_duo_ranks",
				"sensei_pocket_ranks", "sensei_haggle_ranks", "sensei_reroll_ranks",
				"sensei_revive_ranks", "sensei_boss_dmg_pct"]:
			if field in rs:
				rs.set(field, 0 if typeof(rs.get(field)) == TYPE_INT else 0.0)
		# New file picks up the current menu-default AI tier from Settings.
		var settings := get_node_or_null("/root/Settings")
		if settings and "ai_helper_tier" in settings:
			var menu_tier: int = clampi(int(settings.ai_helper_tier), 1, 5)
			if rs.has_method("set_ai_helper_tier"):
				rs.set_ai_helper_tier(menu_tier)
			elif "ai_helper_tier" in rs:
				rs.ai_helper_tier = menu_tier


# ---------------------------------------------------------------------------
# Save current RunState into active_slot
# ---------------------------------------------------------------------------
func save_active_slot() -> void:
	if active_slot < 0:
		return
	var rs := get_node_or_null("/root/RunState")
	if not rs or not rs.has_method("to_save_dict"):
		return
	var run_dict: Dictionary = rs.to_save_dict()
	var meta := {
		"name": _get_slot_name(active_slot),
		"save_date": Time.get_date_string_from_system(),
		"arenas_cleared": rs.arenas_cleared,
		"loops_completed": rs.loops_completed,
		"boons_count": rs.boons_taken.size(),
		"dragon_souls": rs.dragon_souls,
	}
	_write_slot(active_slot, {"meta": meta, "run": run_dict})
	print("[SaveManager] Saved slot %d (%s) — arena %d" % [active_slot, meta["name"], rs.arenas_cleared])


# ---------------------------------------------------------------------------
# Load a slot into RunState
# ---------------------------------------------------------------------------
func load_slot(slot: int) -> bool:
	if is_slot_empty(slot):
		push_warning("[SaveManager] Tried to load empty slot %d." % slot)
		return false
	var file := FileAccess.open(_slot_path(slot), FileAccess.READ)
	if not file:
		return false
	var text := file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[SaveManager] Could not parse slot %d." % slot)
		return false
	active_slot = slot
	var rs := get_node_or_null("/root/RunState")
	if rs and rs.has_method("load_from_dict"):
		var run_data: Dictionary = parsed.get("run", {})
		rs.load_from_dict(run_data)
	# Sync Settings to the save file's AI tier (not the global config default).
	var settings := get_node_or_null("/root/Settings")
	if settings and settings.has_method("sync_ai_tier_from_runstate"):
		settings.sync_ai_tier_from_runstate()
	print("[SaveManager] Loaded slot %d." % slot)
	return true


# ---------------------------------------------------------------------------
# Delete a slot
# ---------------------------------------------------------------------------
func delete_slot(slot: int) -> void:
	var path := _slot_path(slot)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	if active_slot == slot:
		active_slot = -1
	print("[SaveManager] Deleted slot %d." % slot)


# ---------------------------------------------------------------------------
# Copy slot from → to
# ---------------------------------------------------------------------------
func copy_slot(from_slot: int, to_slot: int) -> void:
	if is_slot_empty(from_slot):
		push_warning("[SaveManager] copy_slot: source slot %d is empty." % from_slot)
		return
	var src := _slot_path(from_slot)
	var dst := _slot_path(to_slot)
	# Read source, patch meta name so the copy is clearly labeled.
	var file := FileAccess.open(src, FileAccess.READ)
	if not file:
		return
	var text := file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) == TYPE_DICTIONARY:
		var meta: Dictionary = parsed.get("meta", {}).duplicate()
		meta["name"] = meta.get("name", "Save") + " (copy)"
		meta["save_date"] = Time.get_date_string_from_system()
		parsed["meta"] = meta
		var out := FileAccess.open(dst, FileAccess.WRITE)
		if out:
			out.store_string(JSON.stringify(parsed, "\t"))
			out.close()
	print("[SaveManager] Copied slot %d → slot %d." % [from_slot, to_slot])


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
func _get_slot_name(slot: int) -> String:
	var info := get_slot_info(slot)
	return info.get("name", "Save %d" % (slot + 1))


func _write_slot(slot: int, data: Dictionary) -> void:
	var file := FileAccess.open(_slot_path(slot), FileAccess.WRITE)
	if not file:
		push_error("[SaveManager] Could not write slot %d." % slot)
		return
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
