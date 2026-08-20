class_name StatsState
extends RefCounted
# ============================================================
# StatsState.gd — run + lifetime statistics  (Phase 4a)
# ============================================================
# Plain data/logic module, NOT an autoload — same pattern as DayState.gd and
# EconomyState.gd from the Phase-2 RunState decomposition. RunState owns the
# two dictionaries; this file owns the rules for reading and writing them.
#
# WHY THIS EXISTS
# ---------------
# Before Phase 4 the entire statistics layer was two ints on RunState
# (arenas_cleared, loops_completed). There was no run timer, no kill count, no
# record of past runs, and no way for the death screen to say anything
# interesting. Roguelites live on this data — it is what makes run N+1 feel
# like it means something.
#
# TWO SCOPES, AND THE DIFFERENCE MATTERS
# --------------------------------------
#   run_stats       cleared by RunState.reset_run() at the start of every run
#   lifetime_stats  SURVIVES reset_run(), exactly like dragon_souls
#
# ⚠ lifetime_stats MUST be added to reset_run()'s explicit exemption list
#   (RunState.gd, next to the dragon_souls comment). If it is ever reset by
#   accident, every record and the boons-seen set are silently wiped and there
#   is no way to recover them from the save file.
#
# Both dictionaries go through to_save_dict() / load_from_dict(), and both
# tolerate missing keys so saves written before Phase 4 load cleanly.
# ============================================================

# ---------------------------------------------------------------------------
# Schemas — single source of truth for defaults.
# ---------------------------------------------------------------------------
# Every reader goes through these, so adding a stat later means adding one line
# here and nothing else: old saves simply pick up the default.

const RUN_DEFAULTS: Dictionary = {
	"started_ms":          0,     # Time.get_ticks_msec() at run start
	"elapsed_ms":          0,     # frozen at run end so the death screen can show it
	"enemies_killed":      0,
	"damage_dealt":        0,
	"damage_taken":        0,
	"times_downed":        0,     # knocked down but revived — not a run loss
	"rooms_cleared":       0,
	"coins_earned":        0,
	"bosses_killed":       0,
	"biomes_visited":      [],    # Array[String]
	"boon_ids":            [],    # Array[String], in pick order
	"cause_of_death":      "",    # display label, set by the fatal blow
	"killed_by":           "",    # which hero fell last ("shino"/"bea")
}

const LIFETIME_DEFAULTS: Dictionary = {
	"total_runs":          0,
	"total_wins":          0,
	"total_defeats":       0,
	"total_playtime_ms":   0,
	"enemies_killed_ever": 0,
	"bosses_killed_ever":  0,
	"best_arenas":         0,     # deepest run
	"best_time_ms":        0,     # fastest WIN (0 = no win yet)
	"most_boons":          0,
	"boons_seen":          {},    # boon_id -> true (drives the Phase 7 codex)
	"tutorial_completed_ever": false,   # lets Phase 7 offer a tutorial skip
}


# ---------------------------------------------------------------------------
# Construction / normalisation
# ---------------------------------------------------------------------------
## Returns a fresh run_stats dict. Called by reset_run() and at run start.
static func new_run_stats() -> Dictionary:
	return RUN_DEFAULTS.duplicate(true)


static func new_lifetime_stats() -> Dictionary:
	return LIFETIME_DEFAULTS.duplicate(true)


## Fills in any key a save file predates. Called on load so the rest of the
## module can index freely without a .get() guard on every access.
static func normalise(d: Dictionary, defaults: Dictionary) -> Dictionary:
	var out: Dictionary = d.duplicate(true) if d != null else {}
	for k in defaults.keys():
		if not out.has(k):
			var v = defaults[k]
			out[k] = v.duplicate(true) if (v is Dictionary or v is Array) else v
	return out


# ---------------------------------------------------------------------------
# Run lifecycle
# ---------------------------------------------------------------------------
## Stamps the clock. Safe to call more than once — only the first sticks, so a
## mid-run scene reload can't restart the timer.
static func begin_run(run_stats: Dictionary) -> void:
	if int(run_stats.get("started_ms", 0)) <= 0:
		run_stats["started_ms"] = Time.get_ticks_msec()


## Freezes the elapsed time. Must be called BEFORE reset_run() wipes run_stats,
## so the death/win screen can still read it.
static func end_run(run_stats: Dictionary) -> void:
	run_stats["elapsed_ms"] = elapsed_ms(run_stats)


static func elapsed_ms(run_stats: Dictionary) -> int:
	var frozen: int = int(run_stats.get("elapsed_ms", 0))
	if frozen > 0:
		return frozen
	var started: int = int(run_stats.get("started_ms", 0))
	if started <= 0:
		return 0
	return maxi(0, Time.get_ticks_msec() - started)


## Rolls a finished run into the lifetime records. `won` separates a Sensei Z
## victory from a defeat; best_time_ms only tracks WINS (a fast death is not a
## record worth keeping).
static func bank_run(run_stats: Dictionary, lifetime: Dictionary, won: bool) -> void:
	var ms: int = elapsed_ms(run_stats)
	lifetime["total_runs"] = int(lifetime.get("total_runs", 0)) + 1
	lifetime["total_playtime_ms"] = int(lifetime.get("total_playtime_ms", 0)) + ms
	lifetime["enemies_killed_ever"] = int(lifetime.get("enemies_killed_ever", 0)) \
		+ int(run_stats.get("enemies_killed", 0))
	lifetime["bosses_killed_ever"] = int(lifetime.get("bosses_killed_ever", 0)) \
		+ int(run_stats.get("bosses_killed", 0))

	if won:
		lifetime["total_wins"] = int(lifetime.get("total_wins", 0)) + 1
		var best_t: int = int(lifetime.get("best_time_ms", 0))
		if ms > 0 and (best_t <= 0 or ms < best_t):
			lifetime["best_time_ms"] = ms
	else:
		lifetime["total_defeats"] = int(lifetime.get("total_defeats", 0)) + 1

	var rooms: int = int(run_stats.get("rooms_cleared", 0))
	if rooms > int(lifetime.get("best_arenas", 0)):
		lifetime["best_arenas"] = rooms

	var boons: int = (run_stats.get("boon_ids", []) as Array).size()
	if boons > int(lifetime.get("most_boons", 0)):
		lifetime["most_boons"] = boons


# ---------------------------------------------------------------------------
# Event recorders — called from existing hooks, one line each.
# ---------------------------------------------------------------------------
static func note_kill(run_stats: Dictionary, is_boss: bool = false) -> void:
	run_stats["enemies_killed"] = int(run_stats.get("enemies_killed", 0)) + 1
	if is_boss:
		run_stats["bosses_killed"] = int(run_stats.get("bosses_killed", 0)) + 1


static func note_damage_dealt(run_stats: Dictionary, amount: int) -> void:
	if amount > 0:
		run_stats["damage_dealt"] = int(run_stats.get("damage_dealt", 0)) + amount


static func note_damage_taken(run_stats: Dictionary, amount: int) -> void:
	if amount > 0:
		run_stats["damage_taken"] = int(run_stats.get("damage_taken", 0)) + amount


static func note_downed(run_stats: Dictionary) -> void:
	run_stats["times_downed"] = int(run_stats.get("times_downed", 0)) + 1


static func note_room_cleared(run_stats: Dictionary) -> void:
	run_stats["rooms_cleared"] = int(run_stats.get("rooms_cleared", 0)) + 1


static func note_coins(run_stats: Dictionary, amount: int) -> void:
	if amount > 0:
		run_stats["coins_earned"] = int(run_stats.get("coins_earned", 0)) + amount


static func note_biome(run_stats: Dictionary, biome: String) -> void:
	if biome == "":
		return
	var list: Array = run_stats.get("biomes_visited", [])
	if not list.has(biome):
		list.append(biome)
		run_stats["biomes_visited"] = list


## Records a boon in BOTH scopes: the run list (for the end-of-run recap) and
## the lifetime seen-set (for the Phase 7 codex).
static func note_boon(run_stats: Dictionary, lifetime: Dictionary, boon_id: String) -> void:
	if boon_id == "":
		return
	var list: Array = run_stats.get("boon_ids", [])
	list.append(boon_id)
	run_stats["boon_ids"] = list
	var seen: Dictionary = lifetime.get("boons_seen", {})
	seen[boon_id] = true
	lifetime["boons_seen"] = seen


## The fatal blow. `source` is whatever take_damage() was handed — an enemy
## name or a hazard tag — and `who` is the hero that fell.
static func note_death_cause(run_stats: Dictionary, source: String, who: String) -> void:
	run_stats["cause_of_death"] = source
	run_stats["killed_by"] = who


# ---------------------------------------------------------------------------
# Formatting helpers — used by the death screen, win screen and Phase 7 UI.
# ---------------------------------------------------------------------------
## "12:34" or "1:02:03" for long runs.
static func format_duration(ms: int) -> String:
	var total: int = int(maxi(0, ms) / 1000.0)
	var h: int = total / 3600
	var m: int = (total % 3600) / 60
	var sec: int = total % 60
	if h > 0:
		return "%d:%02d:%02d" % [h, m, sec]
	return "%d:%02d" % [m, sec]


## Turns a raw damage source into something a player can read. take_damage()
## sources are terse tags ("enemy", "lava", "poison") or node names.
static func pretty_cause(source: String) -> String:
	if source == "" or source == "enemy":
		return "an enemy"
	const NICE: Dictionary = {
		"lava":     "the lava",
		"poison":   "poison",
		"trap":     "a trap",
		"burn":     "burning",
		"bleed":    "bleeding",
		"spikes":   "spikes",
		"boss":     "a boss",
		"projectile": "a projectile",
	}
	if NICE.has(source):
		return String(NICE[source])
	# Node names arrive as "SlimeEnemy" / "PopcornPopper" — space out the camel
	# case so it reads as English rather than as a class name.
	var spaced: String = ""
	for i in range(source.length()):
		var ch: String = source[i]
		if i > 0 and ch == ch.to_upper() and ch != ch.to_lower():
			spaced += " "
		spaced += ch
	return spaced.strip_edges()
