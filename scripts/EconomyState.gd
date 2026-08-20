class_name EconomyState
extends RefCounted

# EconomyState — Phase-2 (P2-B4b) extraction of RunState's ECONOMY logic:
# the run-coin purse, Haggler's-Tongue shop pricing, Sibling-Bond revive
# multiplier, Dragon-Chi regen rate, the end-of-reset_run permanent Sensei-upgrade
# application, and the Apple-Juice team heal. Mutable run/meta state STAYS on the
# RunState autoload (reached via RunState.<member>); pure-data consts live on
# BoonDB (reached via BoonDB.<CONST>) EXCEPT SENSEI_CHI_PER_RANK_PER_SEC, which
# stays a RunState-native Economy const (B1 kept it) → RunState.SENSEI_CHI_PER_RANK_PER_SEC.
# RunState keeps a one-line delegating wrapper for every function here, so the
# frozen facade (Wiring §1: 1,591 external refs) is unchanged.
#
# DANGER PRESERVED (RunState_Map §4/§5):
#  - _apply_sensei_upgrades runs at the END of reset_run(); the RunState delegate
#    fires at the exact same call site, so persistent-bonus application (after the
#    run-state wipe) keeps its order.
#  - grant_apple_juice(tree) reaches the scene tree ONLY via the PASSED `tree` arg
#    (never `self`): walks the "player"/"bea" groups, calls each hero's
#    heal_external, and fires RunState.baked_apple_duo_ignite — byte-identical.
# Intra-/cross-module calls route back through RunState.<fn>() (facade round-trip,
# per §4), so no ordering dependency between the moved functions.


static func add_coins(amount: int) -> void:
	RunState.run_coins = max(0, RunState.run_coins + amount)
	# Phase 4 — track earnings only (negative amounts are spends, not income).
	StatsState.note_coins(RunState.run_stats, amount)
	# Nudge HUDs that show a coin counter.
	if Engine.get_main_loop() is SceneTree:
		for h in (Engine.get_main_loop() as SceneTree).get_nodes_in_group("hud"):
			if h.has_method("refresh_coin_counter"):
				h.refresh_coin_counter()


# Run 46 — Dragon Chi: 1 Chi per 5 seconds per rank → 0.2 Chi/sec per rank.
static func get_sensei_chi_regen_rate() -> float:
	return float(RunState.sensei_chi_regen) * RunState.SENSEI_CHI_PER_RANK_PER_SEC


# Haggler's Tongue — discounted shop price (floors at 1 coin).
static func get_shop_price(base: int) -> int:
	return max(1, int(round(float(base) * (1.0 - 0.05 * float(RunState.sensei_haggle_ranks)))))


# Sibling Bond — revive fill-rate multiplier (circle AND channel).
static func get_sensei_revive_mult() -> float:
	return 1.0 + 0.15 * float(RunState.sensei_revive_ranks)


# Called at the end of reset_run(). Applies persistent Sensei Z bonuses to the
# freshly-reset run state.
static func _apply_sensei_upgrades() -> void:
	if RunState.sensei_extra_dd > 0:
		RunState.shino_dd_charges += RunState.sensei_extra_dd
		RunState.bea_dd_charges   += RunState.sensei_extra_dd
	if RunState.sensei_dr_pct > 0.0:
		RunState.damage_taken_mult *= max(0.0, 1.0 - RunState.sensei_dr_pct)
	# Run 46 — Swift Wings now actually applies: fold into the shared move-speed
	# multiplier (covers walk, dash and charge moves for both heroes).
	if RunState.sensei_speed_pct > 0.0:
		RunState.move_speed_mult *= (1.0 + RunState.sensei_speed_pct)
	# Run 46 — Deep Pockets: head-start coin purse.
	if RunState.sensei_pocket_ranks > 0:
		RunState.run_coins += RunState.sensei_pocket_ranks * 25
	# Run 46 — Fated Reroll: refill run-scoped reroll charges.
	RunState.rerolls_left = RunState.sensei_reroll_ranks


# Centralized team heal — heal both Shino + Bea by APPLE_JUICE_HEAL_PCT of their
# respective max HP. Returns total HP restored. Safe-no-op for downed heroes and
# missing scene refs; fires the Baked-Apple duo ignite off each healed hero.
static func grant_apple_juice(tree: SceneTree) -> int:
	RunState.apple_juice_consumed_count += 1
	var total: int = 0
	if tree == null:
		return total
	# Players in the "player" group includes Shino + Bea; iterate distinct nodes.
	var seen: Dictionary = {}
	for grp in ["player", "bea"]:
		for p in tree.get_nodes_in_group(grp):
			if p == null or not is_instance_valid(p):
				continue
			if seen.has(p):
				continue
			seen[p] = true
			var max_hp: int = 100
			if p.has_method("get_effective_max_hp"):
				max_hp = p.get_effective_max_hp()
			elif "max_hp" in p:
				max_hp = p.max_hp
			var heal: int = max(1, int(round(float(max_hp) * BoonDB.APPLE_JUICE_HEAL_PCT)))
			if p.has_method("heal_external"):
				p.heal_external(heal)
				total += heal
				# Run 27 — Baked Apple duo: 50% heal > 10% threshold → ignite
				# the nearest enemy within 200px of the healed hero.
				if p is Node2D:
					RunState.baked_apple_duo_ignite(tree, p.global_position)
	Log.dbg("[RunState] Apple Juice consumed — %d total HP restored across heroes (consumed_count=%d)" % [
		total, RunState.apple_juice_consumed_count,
	])
	return total
