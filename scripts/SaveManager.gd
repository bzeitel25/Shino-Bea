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

## Bumped when the save dictionary's shape changes in a way readers must know
## about. Written into every slot from Phase 3 onward; files written before
## this existed simply report 0 and are still loaded normally.
const SCHEMA_VERSION: int = 1

var active_slot: int = -1


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)


# ---------------------------------------------------------------------------
# Slot file paths
# ---------------------------------------------------------------------------
func _slot_path(slot: int) -> String:
	return SAVE_DIR + "slot_%d.json" % slot


## Previous good copy, rotated in on every successful write.
func _backup_path(slot: int) -> String:
	return SAVE_DIR + "slot_%d.bak" % slot


## Scratch file the new save is fully written and verified in before it is
## allowed to replace the real one.
func _temp_path(slot: int) -> String:
	return SAVE_DIR + "slot_%d.tmp" % slot


# ---------------------------------------------------------------------------
# Query
# ---------------------------------------------------------------------------
## A slot counts as occupied if EITHER the live file or its backup exists —
## otherwise a slot whose live file was corrupted would look empty and the
## player could overwrite a save that is still recoverable.
func is_slot_empty(slot: int) -> bool:
	return not FileAccess.file_exists(_slot_path(slot)) \
		and not FileAccess.file_exists(_backup_path(slot))


func get_slot_info(slot: int) -> Dictionary:
	if is_slot_empty(slot):
		return {}
	var parsed: Dictionary = _read_slot_dict(slot)
	if parsed.is_empty():
		return {}
	return parsed.get("meta", {})


# ---------------------------------------------------------------------------
# Create new slot (blank run, just name + date)
# ---------------------------------------------------------------------------
func create_new_slot(slot: int, save_name: String) -> void:
	# A brand-new file must not inherit a previous save's backup — otherwise a
	# later corruption would "recover" into the wrong player's run.
	_quiet_remove(_backup_path(slot))
	_quiet_remove(_temp_path(slot))
	var data := {
		"schema_version": SCHEMA_VERSION,
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
		# New file → restart the story from the top: replay the intro tutorial
		# dream. tutorial_completed / tutorial_room are PERSISTENT story fields that
		# reset_run() deliberately preserves (so run-loops within a save keep the
		# tutorial done), so a brand-new file must clear them explicitly here — else
		# the singleton's stale value from a previously-loaded save leaks in and
		# SaveFileSelect routes straight to the Dojo, skipping the tutorial.
		if "tutorial_completed" in rs:
			rs.tutorial_completed = false
		if "tutorial_room" in rs:
			rs.tutorial_room = 1
		# Also clear any stale resume target so the new file can't resume into a
		# previous save's arena/Dojo ahead of the tutorial check.
		if "resume_scene_path" in rs:
			rs.resume_scene_path = ""
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
	var ok: bool = _write_slot(active_slot,
		{"schema_version": SCHEMA_VERSION, "meta": meta, "run": run_dict})
	if ok:
		Log.dbg("[SaveManager] Saved slot %d (%s) — arena %d"
			% [active_slot, meta["name"], rs.arenas_cleared])
	else:
		push_error("[SaveManager] SAVE FAILED for slot %d — previous save preserved."
			% active_slot)


# ---------------------------------------------------------------------------
# Load a slot into RunState
# ---------------------------------------------------------------------------
func load_slot(slot: int) -> bool:
	if is_slot_empty(slot):
		push_warning("[SaveManager] Tried to load empty slot %d." % slot)
		return false
	# Reads the live file, transparently falling back to .bak if it is corrupt.
	var parsed: Dictionary = _read_slot_dict(slot)
	if parsed.is_empty():
		push_error("[SaveManager] Slot %d is unreadable and has no usable backup." % slot)
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
	Log.dbg("[SaveManager] Loaded slot %d." % slot)
	return true


# ---------------------------------------------------------------------------
# Delete a slot
# ---------------------------------------------------------------------------
func delete_slot(slot: int) -> void:
	# Remove every artefact of the slot — leaving .bak behind would make the
	# slot report as occupied again on the next is_slot_empty() check.
	_quiet_remove(_slot_path(slot))
	_quiet_remove(_backup_path(slot))
	_quiet_remove(_temp_path(slot))
	if active_slot == slot:
		active_slot = -1
	Log.dbg("[SaveManager] Deleted slot %d." % slot)


# ---------------------------------------------------------------------------
# Copy slot from → to
# ---------------------------------------------------------------------------
func copy_slot(from_slot: int, to_slot: int) -> void:
	if is_slot_empty(from_slot):
		push_warning("[SaveManager] copy_slot: source slot %d is empty." % from_slot)
		return
	# Read source through the resilient reader (so copying a slot whose live
	# file went bad still works from its backup), then write the copy through
	# the atomic writer rather than a raw FileAccess.WRITE.
	var parsed: Dictionary = _read_slot_dict(from_slot)
	if parsed.is_empty():
		push_error("[SaveManager] copy_slot: source slot %d is unreadable." % from_slot)
		return
	var meta: Dictionary = parsed.get("meta", {}).duplicate()
	meta["name"] = meta.get("name", "Save") + " (copy)"
	meta["save_date"] = Time.get_date_string_from_system()
	parsed["meta"] = meta
	parsed["schema_version"] = SCHEMA_VERSION
	if _write_slot(to_slot, parsed):
		Log.dbg("[SaveManager] Copied slot %d → slot %d." % [from_slot, to_slot])
	else:
		push_error("[SaveManager] copy_slot: could not write slot %d." % to_slot)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
func _get_slot_name(slot: int) -> String:
	var info := get_slot_info(slot)
	return info.get("name", "Save %d" % (slot + 1))


# ---------------------------------------------------------------------------
# ATOMIC SLOT WRITE  (Phase 3a)
# ---------------------------------------------------------------------------
# The old implementation opened the real slot file with FileAccess.WRITE and
# streamed JSON straight into it. A crash, power cut or OneDrive sync collision
# part-way through left a truncated file, load_slot() failed to parse it, and
# that slot's entire meta-progression — dragon souls, sensei upgrades, karma,
# family restoration, tutorial state — was gone with no way back.
#
# Now: write to .tmp, prove it parses, rotate the old file to .bak, then swap
# .tmp into place. The real slot file is only ever replaced by a whole, valid
# file, and the previous good save survives as .bak for one generation.
#
# Failure at any step leaves the existing save untouched.
#
# Returns true on success so callers can react; existing callers ignore it,
# which is fine.
func _write_slot(slot: int, data: Dictionary) -> bool:
	var real_path: String = _slot_path(slot)
	var tmp_path: String  = _temp_path(slot)
	var bak_path: String  = _backup_path(slot)
	var payload: String   = JSON.stringify(data, "\t")

	# --- 1. Write the scratch file ---
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		push_error("[SaveManager] Could not open temp file for slot %d (err %d)."
			% [slot, FileAccess.get_open_error()])
		return false
	file.store_string(payload)
	file.flush()
	file.close()

	# --- 2. Verify it round-trips before it is allowed near the real save ---
	if not _file_parses(tmp_path):
		push_error("[SaveManager] Slot %d temp file failed verification — "
			% slot + "existing save left untouched.")
		_quiet_remove(tmp_path)
		return false

	# --- 3. Rotate the current save to .bak ---
	if FileAccess.file_exists(real_path):
		_quiet_remove(bak_path)
		var rot_err: int = DirAccess.rename_absolute(real_path, bak_path)
		if rot_err != OK:
			# Non-fatal: we just lose the backup generation, not the new save.
			push_warning("[SaveManager] Could not rotate slot %d to .bak (err %d)."
				% [slot, rot_err])

	# --- 4. Swap the verified temp into place ---
	var err: int = DirAccess.rename_absolute(tmp_path, real_path)
	if err != OK:
		push_error("[SaveManager] Could not commit slot %d (err %d)." % [slot, err])
		# Put the old save back so the player is not left with nothing.
		if not FileAccess.file_exists(real_path) and FileAccess.file_exists(bak_path):
			DirAccess.rename_absolute(bak_path, real_path)
		_quiet_remove(tmp_path)
		return false

	return true


## True when `path` exists and contains a parseable JSON dictionary.
func _file_parses(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var text := f.get_as_text()
	f.close()
	if text.strip_edges() == "":
		return false
	return typeof(JSON.parse_string(text)) == TYPE_DICTIONARY


func _quiet_remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


# ---------------------------------------------------------------------------
# Resilient read — real file first, .bak if the real one is unreadable.
# ---------------------------------------------------------------------------
## Returns the parsed slot dictionary, or {} if neither copy is usable.
func _read_slot_dict(slot: int) -> Dictionary:
	var real_path: String = _slot_path(slot)
	if _file_parses(real_path):
		var f := FileAccess.open(real_path, FileAccess.READ)
		if f != null:
			var text := f.get_as_text()
			f.close()
			var parsed = JSON.parse_string(text)
			if typeof(parsed) == TYPE_DICTIONARY:
				return parsed

	# Real file is missing or corrupt — fall back to the previous good write.
	var bak_path: String = _backup_path(slot)
	if _file_parses(bak_path):
		push_warning("[SaveManager] Slot %d unreadable — recovered from backup." % slot)
		var bf := FileAccess.open(bak_path, FileAccess.READ)
		if bf != null:
			var btext := bf.get_as_text()
			bf.close()
			var bparsed = JSON.parse_string(btext)
			if typeof(bparsed) == TYPE_DICTIONARY:
				# Promote the backup so the next boot reads it directly.
				var copy := FileAccess.open(real_path, FileAccess.WRITE)
				if copy != null:
					copy.store_string(btext)
					copy.flush()
					copy.close()
				return bparsed

	return {}
