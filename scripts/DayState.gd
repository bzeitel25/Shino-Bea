class_name DayState
extends RefCounted

# DayState — Phase-2 (P2-B4) extraction of RunState's DAY/KARMA logic:
# karma banking/deposit, family healing tiers, town visual tier, and the
# sensei-lore-from-healing computation. Mutable run state STAYS on the RunState
# autoload (reached via RunState.<member>); pure-data consts live on BoonDB
# (reached via BoonDB.<CONST>). RunState keeps a one-line delegating wrapper for
# every function here, so the frozen facade (Wiring §1: 1,591 external refs) is
# unchanged.
#
# DANGER PRESERVED (RunState_Map §5):
#  - bank_run_karma runs in the karma-BEFORE-reset_run hook. The RunState
#    delegate fires at the exact same external call sites
#    (RunComplete._finalize_run, Shino._reload_arena1) in the same order — no
#    call-graph restructuring here.
#  - town_visual_tier logic is byte-identical to Run 143:
#    0 = delapidated · 1 = sensei_lore_tier >= 3 · 2 = sensei_lore_tier >= 6
#    AND full_ending_beaten.
# Intra-module calls route back through RunState.<fn>() (facade round-trip, per
# §4), so no ordering dependency between the moved functions.


# Run 143 — TOWN VISUAL TIER (cosmetic waking-world town tileset selector).
static func town_visual_tier() -> int:
	if RunState.full_ending_beaten and RunState.sensei_lore_tier >= 6:
		return 2
	if RunState.sensei_lore_tier >= 3:
		return 1
	return 0


# ---------------------------------------------------------------------------
# Run 167 — CARNIVAL GATE (Bruno's spec, 2026-08-19)
# The Dragon Fruit troupe only rolls into town once the island is visibly on
# the mend. Two conditions, both required:
#   1. the town itself has left Delapidated  (town_visual_tier() >= 1), and
#   2. NOT ONE family is still Rotten        (every family tier >= 1).
# Ripe-across-the-board was too steep; this lands around "several families at
# Wilted or better", which is where the town art flips anyway.
# [TUNE] CARNIVAL_MIN_FAMILY_TIER is the knob if it opens too early / too late.
#
# ⚠ Run 167b: RunState.carnival_open() / .dragonfruit_tier() delegate here, so
# these two MUST exist. Godot caches `class_name` scripts, so if you add a new
# static to this file while the editor is open you will get
# `Static function "..." not found in base "DayState"` until the project is
# reloaded (Project → Reload Current Project). It is not a code error.
# ---------------------------------------------------------------------------
const CARNIVAL_MIN_FAMILY_TIER: int = 1

static func carnival_open() -> bool:
	if RunState.town_visual_tier() < 1:
		return false
	for fam in BoonDB.FAMILIES:
		if RunState.get_family_tier(String(fam)) < CARNIVAL_MIN_FAMILY_TIER:
			return false
	return true


# How far along the Dragon Fruit troupe's own healing reads. They sit OUTSIDE
# the karma loop (Family_Roster §4.11: no boons, no karma track), so their art
# tier is derived from the island instead of deposited karma:
#   0 Rotten   — carnival still shut
#   1 Unripe   — carnival just opened
#   2 Ripe     — every family Ripe or better
#   3 Restored — every family Restored
# [TUNE] Bruno: swap this for a real karma track whenever Dragon Fruit gets one.
static func dragonfruit_tier() -> int:
	if not RunState.carnival_open():
		return 0
	var lowest: int = 3
	for fam in BoonDB.FAMILIES:
		lowest = mini(lowest, RunState.get_family_tier(String(fam)))
	if lowest >= 3:
		return 3
	if lowest >= 2:
		return 2
	return 1


# Call ONCE at the end of a run (win OR defeat), BEFORE reset_run() wipes
# boons_taken. Both call sites: RunComplete._finalize_run() and
# Shino._reload_arena1(). Corrupt boons bank nothing.
static func bank_run_karma() -> void:
	if RunState._karma_banked_this_run:
		return
	RunState._karma_banked_this_run = true
	var gained: Dictionary = {}
	for id in RunState.boons_taken:
		var fam: String = String(BoonDB.BOON_POOL.get(id, {}).get("family", ""))
		if fam == "" or fam == "Corrupt":
			continue
		gained[fam] = int(gained.get(fam, 0)) + 1
	for fam in gained.keys():
		var cur: int = int(RunState.karma_banked.get(fam, 0))
		var cap: int = RunState.karma_needed_for_tier(RunState.get_family_tier(fam))
		RunState.karma_banked[fam] = mini(cur + int(gained[fam]), cap)
	if not gained.is_empty():
		Log.dbg("[RunState] Karma banked (hidden): %s" % str(gained))


static func get_family_tier(fam: String) -> int:
	return clampi(int(RunState.family_tier.get(fam, 0)), 0, RunState.FAMILY_TIER_MAX)


static func has_banked_karma(fam: String) -> bool:
	return int(RunState.karma_banked.get(fam, 0)) > 0


# Deposit ALL banked karma for a family (the elder chat). Returns
# {"deposited": int, "tier_up": bool, "new_tier": int} for the dialog layer.
# One tier advance max per deposit, no progress carry-over past a tier-up
# (Townsfolk §2.1). At Restored, karma is still absorbed as goodwill.
static func deposit_karma(fam: String) -> Dictionary:
	var amt: int = int(RunState.karma_banked.get(fam, 0))
	var out: Dictionary = {"deposited": amt, "tier_up": false, "new_tier": RunState.get_family_tier(fam)}
	if amt <= 0:
		return out
	RunState.karma_banked[fam] = 0
	var tier: int = RunState.get_family_tier(fam)
	if tier >= RunState.FAMILY_TIER_MAX:
		return out
	var needed: int = RunState.karma_needed_for_tier(tier)
	var prog: int = int(RunState.karma_progress.get(fam, 0)) + amt
	if prog >= needed:
		tier += 1
		prog = 0
		RunState.family_tier[fam] = tier
		out["tier_up"] = true
		out["new_tier"] = tier
		Log.dbg("[RunState] The %s family healed to %d." % [fam, tier])
	RunState.karma_progress[fam] = prog
	# Run 142 — re-evaluate Sensei's lore tier whenever karma is deposited
	RunState.update_sensei_lore_from_healing()
	return out


# Island healing score — drives Sensei Z's progressive dialogue. Each family's
# current tier contributes weighted points; partial karma progress within a tier
# adds a fractional point. 10 families × 4 pts max = 40 total.
static func island_healing_score() -> float:
	var total: float = 0.0
	for fam in BoonDB.FAMILIES:
		var t: int = RunState.get_family_tier(fam)
		total += float(BoonDB._HEALING_TIER_WEIGHT[t])
		# Add fractional credit for progress toward the NEXT tier
		if t < RunState.FAMILY_TIER_MAX:
			var prog: int = int(RunState.karma_progress.get(fam, 0))
			var needed: int = RunState.karma_needed_for_tier(t)
			total += float(prog) / float(needed) * 0.5  # up to 0.5 bonus
	return total


static func compute_sensei_lore_tier() -> int:
	if RunState.sensei_lore_tier < 1:
		return 0  # haven't even done the town visit yet
	var score: float = RunState.island_healing_score()
	var best: int = 1  # minimum = tier 1 (post-town-visit)
	for i in range(2, BoonDB.SENSEI_LORE_THRESHOLDS.size()):
		if score >= float(BoonDB.SENSEI_LORE_THRESHOLDS[i]):
			best = i
	return best


# Call after any karma deposit or tier-up to see if Sensei has new dialogue.
static func update_sensei_lore_from_healing() -> void:
	var computed: int = RunState.compute_sensei_lore_tier()
	if computed > RunState.sensei_lore_tier:
		RunState.sensei_lore_tier = computed
		Log.dbg("[RunState] Sensei lore tier advanced to %d (healing score: %.1f)" % [computed, RunState.island_healing_score()])
