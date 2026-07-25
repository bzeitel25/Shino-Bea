class_name BoonEffects
extends RefCounted
# ===========================================================================
# BoonEffects — Phase-2 (P2-B3) extraction of RunState's per-boon EFFECT-GETTER
# logic. All functions are `static` and stateless: mutable run state stays on the
# `RunState` autoload and is reached here via `RunState.<member>`; pure-data consts
# live on `BoonDB` and are reached via `BoonDB.<CONST>`. RunState keeps a one-line
# delegating wrapper (identical name/signature) for every function moved here, so
# the frozen facade (1,591 external `RunState.*` refs) keeps resolving verbatim.
#
# MECHANISM (RunState_Map §4): a moved body's calls to OTHER RunState functions
# (moved or not) go through `RunState.<fn>()` — the facade round-trip — so no
# call-ordering hazard exists within this module.
#
# DANGER-LIST INVARIANTS PRESERVED EXACTLY (RunState_Map §5): every per-hero
# `who`-keyed branch (picker-only self-buffs, taker-only corrupts, shino/bea
# boon-set gating) is copied byte-for-byte — none collapsed to a global flag.
# ===========================================================================


# ---------------------------------------------------------------------------
# Crit roll (Keen Eye / Sharpened Tip / Bullseye / Hawkeye / Heavy-Crit &
# Headshot duos / Chaos-Carrot + Poison-Apple corrupts — all taker/per-hero gated).
# ---------------------------------------------------------------------------
static func roll_crit_mult(attack_type: String = "", who: String = "shino") -> float:
	RunState.last_crit_result = false
	RunState._set_crit_tier(0)   # Run 127 — reset display tier for this hit

	# Chaos Carrot (corrupt): 50% flat crit, but crit damage = 1.0 (no bonus).
	# Run 139 — taker only.
	if RunState.char_has("corrupt_carrot", who):
		RunState.finisher_crit_chance_bonus = 0.0
		if randf() < 0.50:
			RunState.last_crit_result = true
			RunState._set_crit_tier(1)
			return 1.0
		return 1.0

	var hawk_lvl: float = RunState.get_boon_level_mult("hawkeye") if RunState.hawkeye_taken else 1.0
	var effective_crit_dmg: float = RunState.crit_damage_bonus * hawk_lvl

	var type_chance_add: float = 0.0
	match attack_type:
		"primary":
			if RunState.keen_eye_taken:
				type_chance_add    += 0.15
				effective_crit_dmg += 0.10
		"heavy":
			if RunState.sharpened_tip_taken:
				type_chance_add    += 0.25
				effective_crit_dmg += 0.20
		"ranged":
			if RunState.bullseye_taken:
				type_chance_add    += 0.20
				effective_crit_dmg += 0.30

	# Run 27 — Heavy Crit duo (Broccoli+Carrot): all charge attacks guaranteed crit.
	if attack_type == "charge" and RunState.is_duo_active("broccoli_carrot"):
		RunState.force_next_crit = true

	# Run 27b — Headshot duo (Carrot+Potato): Ingrained → +25% crit chance/damage.
	var _ingr: bool = RunState.shino_ingrained if who == "shino" else RunState.bea_ingrained
	if _ingr and RunState.is_duo_active("carrot_potato"):
		type_chance_add    += 0.25
		effective_crit_dmg += 0.25

	# Run 139 — Poison Apple: converted max-HP → flat crit chance AND crit damage (taker).
	var _pa_crit: float = RunState.get_poison_apple_conversion_pct(who)
	if _pa_crit > 0.0:
		type_chance_add    += _pa_crit
		effective_crit_dmg += _pa_crit

	# 1. Forced-crit gate (Opening Strike, Golden Carrot finisher).
	if RunState.force_next_crit:
		RunState.force_next_crit = false
		RunState.last_crit_result = true
		RunState._set_crit_tier(2)   # guaranteed crit = Mega-Crit (RED)
		return 1.5 + effective_crit_dmg

	# 2. Chance-based crit.
	var effective_chance: float = RunState.crit_chance + RunState.finisher_crit_chance_bonus + RunState.sensei_crit_pct + type_chance_add \
		+ RunState.get_burning_aim_crit_chance_bonus()   # Run 27 — Burning Aim arm 2
	RunState.finisher_crit_chance_bonus = 0.0   # consume bonus after each roll
	if effective_chance > 0.0 and randf() < effective_chance:
		RunState.last_crit_result = true
		RunState._set_crit_tier(1)   # rolled crit (ORANGE)
		return 1.5 + effective_crit_dmg

	return 1.0


# ---------------------------------------------------------------------------
# Grape family helpers (Combo Counter scaling).
# ---------------------------------------------------------------------------
static func get_combo_master_mult(combo_count: int, who: String = "shino") -> float:
	var s: Dictionary = RunState.shino_boon_set if who == "shino" else RunState.bea_boon_set
	if not ("combo_master" in s):
		return 1.0
	return 1.0 + 0.01 * float(combo_count) * RunState.get_boon_effect_mult("combo_master")

static func get_noble_rot_mult(combo_count: int, is_finisher: bool, who: String = "shino") -> float:
	var s: Dictionary = RunState.shino_boon_set if who == "shino" else RunState.bea_boon_set
	if not ("noble_rot" in s) or not is_finisher:
		return 1.0
	return 1.0 + 0.01 * float(combo_count) * RunState.get_boon_effect_mult("noble_rot")


# Apple Full Bloom — Y-only +15% when hp_frac >= 0.80.
static func get_full_bloom_mult(hp_frac: float, is_primary: bool = false, who: String = "shino") -> float:
	var s: Dictionary = RunState.shino_boon_set if who == "shino" else RunState.bea_boon_set
	if not ("full_bloom_apple" in s or "full_bloom" in s) or not is_primary:
		return 1.0
	if hp_frac < 0.80:
		return 1.0
	return 1.0 + 0.15 * RunState.get_boon_effect_mult("full_bloom_apple")


# Apple Ripened Core + Heart of the Orchard — HP-fraction-driven.
static func get_apple_hp_tier_mult(hp_frac: float, who: String = "shino") -> float:
	var s: Dictionary = RunState.shino_boon_set if who == "shino" else RunState.bea_boon_set
	# Run 139 — taker only: Poison Apple corrupt pins the taker's tier to full HP.
	var _pa: bool = "corrupt_apple" in s
	if _pa:
		hp_frac = 1.0
	var mult: float = 1.0
	if "ripened_core" in s or _pa:
		if hp_frac >= 1.0 - 0.001:
			mult *= 1.30
		elif hp_frac >= 0.80:
			mult *= 1.20
		elif hp_frac >= 0.50:
			mult *= 1.10
	if "heart_of_the_orchard" in s:
		if hp_frac >= 1.0 - 0.001:
			mult *= 3.0
		elif hp_frac >= 0.80:
			mult *= 2.0
	return mult


# Broccoli Heavy Stalk — Y-only +15%.
static func get_heavy_stalk_mult(is_primary: bool = false, who: String = "shino") -> float:
	var s: Dictionary = RunState.shino_boon_set if who == "shino" else RunState.bea_boon_set
	if not ("heavy_stalk" in s) or not is_primary:
		return 1.0
	return 1.0 + 0.15 * RunState.get_boon_effect_mult("heavy_stalk")


# Run 127 — status-slot baseline damage bonus (Y/X/A/Charge slot boons).
static func get_status_slot_dmg_mult(who: String, slot: String) -> float:
	if slot == "":
		return 1.0
	var s: Dictionary = RunState.shino_boon_set if who == "shino" else RunState.bea_boon_set
	for id in BoonDB.STATUS_SLOT_DMG_BOONS.keys():
		if BoonDB.STATUS_SLOT_DMG_BOONS[id] == slot and (id in s):
			var base: float = float(BoonDB.STATUS_SLOT_DMG_BONUS.get(slot, 0.0))
			return 1.0 + base * RunState.get_boon_effect_mult(id)
	return 1.0


# Run 128 — Smash Zone (Broccoli Legendary): +10% melee dmg per meter closer, cap +50%.
static func get_smash_zone_mult(who: String, dist_px: float) -> float:
	var s: Dictionary = RunState.shino_boon_set if who == "shino" else RunState.bea_boon_set
	if not ("smash_zone" in s):
		return 1.0
	var m: float = dist_px / BoonDB.SMASH_ZONE_PX_PER_M
	return 1.0 + clampf((5.0 - m) * 0.10, 0.0, 0.50)


# Run 128 — Drupe Guard (Coconut Legendary): 1.5s invuln on damage, per-hero ICD.
static func try_drupe_guard(who: String) -> float:
	var s: Dictionary = RunState.shino_boon_set if who == "shino" else RunState.bea_boon_set
	if not ("drupe_guard" in s):
		return 0.0
	var now: int = Time.get_ticks_msec()
	if now < int(RunState._drupe_ready_msec.get(who, 0)):
		return 0.0
	var cd: float = maxf(4.0, 10.0 - 2.0 * float(RunState.get_boon_level("drupe_guard") - 1))
	RunState._drupe_ready_msec[who] = now + int(cd * 1000.0)
	return 1.5


# Run 128 — Shocking Return (Banana passive): 20% chance when hit.
static func roll_shocking_return(who: String) -> bool:
	var s: Dictionary = RunState.shino_boon_set if who == "shino" else RunState.bea_boon_set
	if not ("shocking_return" in s):
		return false
	return randf() < 0.20


# Broccoli Stalk of Might — +5% damage per Broccoli boon owned.
static func get_stalk_of_might_mult() -> float:
	if not RunState.boons_taken.has("stalk_of_might"):
		return 1.0
	return 1.0 + 0.05 * float(RunState.broccoli_boons_taken)


# Broccoli Green Rage — always-on tiered rage.
static func get_green_rage_mult(hp_frac: float, who: String = "shino") -> float:
	# Run 139 — taker only: Burnout corrupt locks the taker's rage at max.
	if RunState.char_has("corrupt_broccoli", who):
		hp_frac = 0.0
	var s: Dictionary = RunState.shino_boon_set if who == "shino" else RunState.bea_boon_set
	if not ("green_rage" in s):
		return 1.0
	var eff_mult: float = RunState.get_boon_effect_mult("green_rage")
	if hp_frac <= 0.25:
		return 1.0 + 0.50 * eff_mult
	if hp_frac <= 0.50:
		return 1.0 + 0.30 * eff_mult
	return 1.0

static func get_green_rage_dr(hp_frac: float, who: String = "shino") -> float:
	var s: Dictionary = RunState.shino_boon_set if who == "shino" else RunState.bea_boon_set
	if not ("green_rage" in s):
		return 1.0
	if hp_frac <= 0.25:
		return 0.75
	return 1.0


# Broccoli Crushing Blow — +50% to enemies <30% HP.
static func get_crushing_blow_mult(target_hp_frac: float) -> float:
	if not RunState.crushing_blow_taken:
		return 1.0
	if target_hp_frac >= 0.30:
		return 1.0
	return 1.5


# Broccoli Bash the Big Ones — +25% to elites/bosses.
static func get_bash_big_ones_mult(is_elite_or_boss: bool) -> float:
	if not RunState.bash_big_ones_taken or not is_elite_or_boss:
		return 1.0
	return 1.25


# Broccoli Combat Fury — tier-driven on-hit ramp (per-owner; Burnout saturates taker).
static func get_combat_fury_mult(current_tier: int, who: String = "shino") -> float:
	var _cf: bool = RunState.char_has("combat_fury", who)
	# Run 139 — taker only.
	if RunState.char_has("corrupt_broccoli", who) and _cf:
		current_tier = BoonDB.COMBAT_FURY_MAX_TIERS
	if not _cf or current_tier <= 0:
		return 1.0
	var t: int = clamp(current_tier, 0, BoonDB.COMBAT_FURY_MAX_TIERS)
	return 1.0 + (RunState.combat_fury_pct_per_tier * float(t))


# Sweet Dreams — heal 5% max HP on room clear, per-character (picker-only).
static func get_sweet_dreams_heal_pct(who: String = "shino") -> float:
	var s: Dictionary = RunState.shino_boon_set if who == "shino" else RunState.bea_boon_set
	return 0.05 if "sweet_dreams" in s else 0.0


# Apple Granny's Recipe heal amp.
static func get_heal_amp() -> float:
	return RunState.heal_amp_mult


# Apple Pie consumable — flat +10% max HP per pie.
static func get_apple_pie_max_hp_pct() -> float:
	return BoonDB.APPLE_PIE_HP_PER_STACK * float(RunState.apple_pie_stacks)


# ---------------------------------------------------------------------------
# Elemental synergies.
# ---------------------------------------------------------------------------
static func is_synergy_active(synergy_id: String) -> bool:
	if not BoonDB.SYNERGY_DEFS.has(synergy_id):
		return false
	var s: Dictionary = BoonDB.SYNERGY_DEFS[synergy_id]
	for fam in s.get("required_any", []):
		if not RunState._has_any_boon_from_family(String(fam)):
			return false
	var mode_req: String = String(s.get("mode_required", ""))
	if mode_req == "water" and RunState.melon_gelato_mode:
		return false
	if mode_req == "gelato" and not RunState.melon_gelato_mode:
		return false
	return true


static func get_active_synergies() -> Array:
	var out: Array = []
	for id in BoonDB.SYNERGY_DEFS.keys():
		if RunState.is_synergy_active(id):
			out.append(id)
	return out


static func get_active_synergies_summary() -> String:
	var ids: Array = RunState.get_active_synergies()
	if ids.is_empty():
		return ""
	var names: Array = []
	for id in ids:
		var d: Dictionary = BoonDB.SYNERGY_DEFS.get(id, {})
		names.append(d.get("name", id))
	return "Synergy: " + ", ".join(names)


# Wet + Lightning synergy — +5% per Soaked stack on lightning hits (cap +25%).
static func get_wet_lightning_target_mult(target_status: Variant) -> float:
	if not RunState.is_synergy_active("wet_lightning"):
		return 1.0
	if target_status == null:
		return 1.0
	var stacks: int = 0
	if target_status.has("wet"):
		stacks = max(stacks, target_status.get_stacks("wet"))
	if target_status.has("drenched"):
		stacks = max(stacks, 5)
	if stacks <= 0:
		return 1.0
	return 1.0 + 0.05 * float(min(stacks, 5))


# Consolidated target-status damage amps (synergy-only, enemy-side).
static func get_target_status_damage_mult(target_status: Variant) -> float:
	if target_status == null:
		return 1.0
	var mult: float = 1.0
	if RunState.is_synergy_active("wet_lightning"):
		var has_lightning: bool = target_status.has("sparked") \
			or target_status.has("bolted") or target_status.has("shocked")
		if has_lightning:
			mult *= RunState.get_wet_lightning_target_mult(target_status)
	if RunState.is_synergy_active("shatter") and target_status.is_frostbitten() \
	and target_status.has("cracked_soil"):
		mult *= 1.10
	if RunState.is_synergy_active("brittle_toxin") and target_status.is_frostbitten() \
	and target_status.has("poison"):
		mult *= 1.15
	if RunState.is_synergy_active("plasma_strike") and target_status.is_burning():
		var _has_l2: bool = target_status.has("sparked") \
			or target_status.has("bolted") or target_status.has("shocked")
		if _has_l2:
			mult *= 1.15
	return mult


# ---------------------------------------------------------------------------
# Duo active-effect getters.
# ---------------------------------------------------------------------------
static func is_duo_active(duo_id: String) -> bool:
	return BoonDB.DUO_DEFS.has(duo_id) and RunState.duos_taken.has(duo_id)


static func get_active_duos() -> Array:
	var out: Array = []
	for id in BoonDB.DUO_DEFS.keys():
		if RunState.is_duo_active(id):
			out.append(id)
	return out


static func get_active_duos_summary() -> String:
	var ids: Array = RunState.get_active_duos()
	if ids.is_empty():
		return ""
	var names: Array = []
	for id in ids:
		var d: Dictionary = BoonDB.DUO_DEFS.get(id, {})
		names.append(d.get("name", id))
	return "Duo: " + ", ".join(names)


# Iron Core (Apple + Broccoli).
static func get_iron_core_count() -> int:
	if not RunState.is_duo_active("iron_core"):
		return 0
	return RunState.apple_boons_taken + RunState.broccoli_boons_taken
static func get_iron_core_hp_mult() -> float:
	return 1.0 + BoonDB.IRON_CORE_PER_BOON_PCT * float(RunState.get_iron_core_count())
static func get_iron_core_damage_mult() -> float:
	return 1.0 + BoonDB.IRON_CORE_PER_BOON_PCT * float(RunState.get_iron_core_count())


# Aimed Guard (Carrot + Coconut).
static func aimed_guard_active() -> bool:
	return RunState.is_duo_active("aimed_guard")


# Shell Cluster (Coconut + Grape).
static func shell_cluster_active() -> bool:
	return RunState.is_duo_active("shell_cluster")


# Vital Harvest (Apple + Carrot).
static func vital_harvest_active() -> bool:
	return RunState.is_duo_active("vital_harvest")
static func get_vital_harvest_heal_pct() -> float:
	return BoonDB.VITAL_HARVEST_HEAL_PCT if RunState.vital_harvest_active() else 0.0


# Shock Ignition (Pepper + Grape).
static func shock_ignition_active() -> bool:
	return RunState.is_duo_active("shock_ignition")
static func get_shock_ignition_burn_bonus() -> float:
	return BoonDB.SHOCK_IGNITION_BURN_CHANCE_BONUS if RunState.shock_ignition_active() else 0.0


# Root & Rot (Potato + Onion).
static func root_and_rot_active() -> bool:
	return RunState.is_duo_active("root_and_rot")
static func get_root_and_rot_amp() -> float:
	return BoonDB.ROOT_AND_ROT_POISON_AMP if RunState.root_and_rot_active() else 0.0


# Bruise Peel (Banana + Broccoli).
static func bruise_peel_active() -> bool:
	return RunState.is_duo_active("bruise_peel")
static func get_bruise_peel_stagger_dur() -> float:
	return BoonDB.BRUISE_PEEL_STAGGER_DUR if RunState.bruise_peel_active() else 0.0


# Frost Shield (Watermelon + Coconut).
static func frost_shield_active() -> bool:
	return RunState.is_duo_active("frost_shield")
static func get_frost_shield_reduction() -> float:
	return BoonDB.FROST_SHIELD_DAMAGE_REDUCTION if RunState.frost_shield_active() else 0.0


# Pepper + Potato — Spicy Landmine.
static func pepper_potato_active() -> bool:
	return RunState.is_duo_active("pepper_potato")
static func get_pepper_potato_amp() -> float:
	return BoonDB.PEPPER_POTATO_DAMAGE_AMP if RunState.pepper_potato_active() else 0.0


# Apple + Watermelon — Spring Tide.
static func apple_watermelon_active() -> bool:
	return RunState.is_duo_active("apple_watermelon")


# Onion + Grape — Toxic Combo.
static func onion_grape_active() -> bool:
	return RunState.is_duo_active("onion_grape")
static func get_onion_grape_poison_burst() -> int:
	return BoonDB.ONION_GRAPE_POISON_BURST_STACKS if RunState.onion_grape_active() else 0


# Banana + Pepper — Slip & Burn.
static func banana_pepper_active() -> bool:
	return RunState.is_duo_active("banana_pepper")
static func get_banana_pepper_ignite_chance() -> float:
	return BoonDB.BANANA_PEPPER_IGNITE_CHANCE if RunState.banana_pepper_active() else 0.0


# Carrot + Watermelon — Refreshing Aim.
static func carrot_watermelon_active() -> bool:
	return RunState.is_duo_active("carrot_watermelon")
static func get_carrot_watermelon_ranged_crit_heal_pct() -> float:
	return BoonDB.CARROT_WATERMELON_RANGED_CRIT_HEAL_PCT if RunState.carrot_watermelon_active() else 0.0


# Broccoli + Onion — Stinging Greens.
static func broccoli_onion_active() -> bool:
	return RunState.is_duo_active("broccoli_onion")
static func get_broccoli_onion_finisher_poison() -> int:
	return BoonDB.BROCCOLI_ONION_FINISHER_POISON_STACKS if RunState.broccoli_onion_active() else 0


# ---------------------------------------------------------------------------
# Legendaries.
# ---------------------------------------------------------------------------
static func adamantium_active() -> bool:
	return RunState.adamantium_husk_taken


# Hulk Smash (Broccoli L2).
static func get_hulk_smash_radius(combo_count: int) -> float:
	if not RunState.hulk_smash_taken:
		return 0.0
	return BoonDB.HULK_SMASH_BASE_RADIUS + BoonDB.HULK_SMASH_PER_COMBO_RADIUS * float(combo_count)
static func get_hulk_smash_damage(combo_count: int) -> int:
	if not RunState.hulk_smash_taken:
		return 0
	return BoonDB.HULK_SMASH_BASE_DAMAGE + int(BoonDB.HULK_SMASH_PER_COMBO_DAMAGE * float(combo_count))
static func get_hulk_smash_charge_mult() -> float:
	return BoonDB.HULK_SMASH_CHARGE_DMG_MULT if RunState.hulk_smash_taken else 1.0
static func get_hulk_smash_windup_mult() -> float:
	return BoonDB.HULK_SMASH_WINDUP_MULT if RunState.hulk_smash_taken else 1.0
# Big Broccoli — +50% AoE on all charge attacks.
static func get_big_broccoli_aoe_mult() -> float:
	return 1.5 if RunState.big_broccoli_taken else 1.0


# Run 131 — Fury Release (Broccoli Charge): +40% charge hitbox/AoE for the owner.
static func get_fury_release_area_mult(who: String) -> float:
	return (1.0 + BoonDB.FURY_RELEASE_AREA_BONUS) if RunState.char_has("fury_release", who) else 1.0


# Juicebox of Youth — kill-heal removed (regen via pickup spawn).
static func get_juicebox_kill_heal_pct() -> float:
	return 0.0


# ---------------------------------------------------------------------------
# Granny's Recipe / Cold Waters heal multiplier (per-owner; taker-only corrupt).
# ---------------------------------------------------------------------------
static func get_heal_mult(who: String = "") -> float:
	var m: float = 1.0
	if RunState._pick_has("grannys_recipe", who):
		m *= 1.30
	# Run 139 — taker only.
	if RunState._pick_has("corrupt_watermelon", who):
		m *= 0.50
	return m


# Chip-Proof — cap single hit at 15% max HP (picker-only).
static func chip_proof_cap(amount: int, max_hp: int, who: String = "shino") -> int:
	if not RunState.char_has("chip_proof", who) or max_hp <= 0:
		return amount
	var cap_val: int = max(1, int(ceil(float(max_hp) * 0.15)))
	return min(amount, cap_val)


# Seeded Shot — ranged bonus = 1% current HP (picker-only).
static func seeded_shot_bonus_dmg(current_hp: int, who: String = "shino") -> int:
	var s: Dictionary = RunState.shino_boon_set if who == "shino" else RunState.bea_boon_set
	if "seeded_shot" not in s:
		return 0
	return max(1, int(round(float(current_hp) * 0.01)))


# Heavy Harvest — X/heavy up to +25% at full HP (picker-only).
static func get_heavy_harvest_mult(hp_frac: float, who: String = "shino") -> float:
	var s: Dictionary = RunState.shino_boon_set if who == "shino" else RunState.bea_boon_set
	if "heavy_harvest" not in s:
		return 1.0
	return 1.0 + clampf(hp_frac, 0.0, 1.0) * 0.25


# Sweet Harvest — Charge +20% above 75% HP (picker-only).
static func get_sweet_harvest_mult(hp_frac: float, who: String = "shino") -> float:
	var s: Dictionary = RunState.shino_boon_set if who == "shino" else RunState.bea_boon_set
	if "sweet_harvest" not in s:
		return 1.0
	if hp_frac >= 0.75:
		return 1.20
	return 1.0


# Tide Master — ult cost -20%, refund 25% (picker-only).
static func tide_master_ult_cost_mult(who: String = "") -> float:
	if not RunState._pick_has("tide_master", who):
		return 1.0
	return 0.80

static func tide_master_refund(base_cost: int, who: String = "") -> int:
	if not RunState._pick_has("tide_master", who):
		return 0
	return max(1, int(round(float(base_cost) * 0.25)))


# Cluster Mastery / Cluster Cascade read-only getters.
static func get_cluster_mastery_double_chance(combo: int) -> float:
	if not RunState.cluster_mastery_taken:
		return 0.0
	return minf(0.30, float(combo) * 0.01)

static func get_cluster_cascade_mult(is_y_finisher: bool) -> float:
	if not RunState.cluster_cascade_taken:
		return 1.0
	if is_y_finisher and RunState._cluster_cascade_x_primed > 0.0:
		return 1.50
	if not is_y_finisher and RunState._cluster_cascade_y_primed > 0.0:
		return 1.25
	return 1.0


# Overripe — Poison max stacks.
static func get_overripe_poison_max() -> int:
	if not RunState.overripe_taken:
		return 5
	var lvl: int = RunState.get_boon_level("overripe")
	return min(10, 5 + 1 + lvl)


# ---------------------------------------------------------------------------
# Spineback — 30% retaliation earth-spike on damage taken (picker-only).
# ---------------------------------------------------------------------------
static func spineback_retaliate(incoming_dmg: int, who: String = "shino") -> int:
	if not RunState.char_has("spineback", who) or incoming_dmg <= 0:
		return 0
	if randf() >= 0.30:
		return 0
	return max(1, int(round(float(incoming_dmg) * 0.50)))


# Sniper's Focus — streak-crit bonus getter (per-hero window).
static func get_sniper_focus_mult(who: String = "shino") -> float:
	if not RunState.sniper_focus_taken or float(RunState.sniper_focus_bonus_timer.get(who, 0.0)) <= 0.0:
		return 1.0
	return 1.0 + BoonDB.SNIPER_FOCUS_BONUS_DMG


# Slip Stream (Banana Legendary).
static func slip_stream_active() -> bool:
	return RunState.slip_stream_taken


# Grape + Banana — Shocking Slip.
static func grape_banana_active() -> bool:
	return RunState.is_duo_active("grape_banana")
static func get_grape_banana_crit_bonus() -> float:
	return BoonDB.GRAPE_BANANA_CRIT_BONUS if RunState.grape_banana_active() else 0.0


# Apple + Pepper — Baked Apple duo.
static func apple_pepper_active() -> bool:
	return RunState.is_duo_active("apple_pepper")


# Potato + Watermelon — Mud Tide.
static func potato_watermelon_active() -> bool:
	return RunState.is_duo_active("potato_watermelon")
static func get_potato_watermelon_amp() -> float:
	return BoonDB.POTATO_WATERMELON_AMP if RunState.potato_watermelon_active() else 0.0


# Coconut + Broccoli — Ironwood.
static func coconut_broccoli_active() -> bool:
	return RunState.is_duo_active("coconut_broccoli")
static func get_coconut_broccoli_dmg_mult(overshield_count: int) -> float:
	if not RunState.coconut_broccoli_active() or overshield_count <= 0:
		return 1.0
	return 1.0 + BoonDB.COCONUT_BROCCOLI_SHIELD_DMG_BONUS


# Burning Aim arm-2 (arena burn-stack scaling; stacks cached by RunState._process).
static func get_burning_aim_crit_chance_bonus() -> float:
	if not RunState.burning_aim_active():
		return 0.0
	return BoonDB.BURNING_AIM_PCT_PER_STACK * float(RunState._burning_aim_arena_stacks)

static func get_burning_aim_attack_speed_bonus() -> float:
	if not RunState.burning_aim_active():
		return 0.0
	return BoonDB.BURNING_AIM_PCT_PER_STACK * float(RunState._burning_aim_arena_stacks)


# Carrot + Onion — Toxic Aim.
static func carrot_onion_active() -> bool:
	return RunState.is_duo_active("carrot_onion")
static func get_carrot_onion_crit_bonus() -> float:
	return BoonDB.CARROT_ONION_POISON_CRIT_BONUS if RunState.carrot_onion_active() else 0.0


# Apple + Grape — Bunch Bloom.
static func bunch_bloom_active() -> bool:
	return RunState.is_duo_active("apple_grape")
static func get_bunch_bloom_finisher_heal(combo_count: int) -> int:
	if not RunState.bunch_bloom_active():
		return 0
	return 2 if combo_count >= 30 else 1


# Carrot + Grape — Master Stroke.
static func master_stroke_active() -> bool:
	return RunState.is_duo_active("carrot_grape")


# Carrot + Pepper — Burning Aim.
static func burning_aim_active() -> bool:
	return RunState.is_duo_active("carrot_pepper")
static func get_burning_aim_bonus(burn_stack_count: int) -> float:
	if not RunState.burning_aim_active() or burn_stack_count <= 0:
		return 0.0
	return BoonDB.BURNING_AIM_PER_STACK_BONUS * float(burn_stack_count)


# Broccoli + Pepper — Firebrand.
static func firebrand_active() -> bool:
	return RunState.is_duo_active("broccoli_pepper")


# Broccoli + Watermelon — Splash Smash.
static func splash_smash_active() -> bool:
	return RunState.is_duo_active("broccoli_watermelon")


# Grape + Watermelon — Cluster Splash.
static func cluster_splash_active() -> bool:
	return RunState.is_duo_active("grape_watermelon")
static func should_cluster_splash_trigger(is_finisher: bool, combo_count: int) -> bool:
	if not RunState.cluster_splash_active():
		return false
	return is_finisher or combo_count >= 30


# Grape + Potato — Stomp Combo.
static func stomp_combo_active() -> bool:
	return RunState.is_duo_active("grape_potato")
static func get_stomp_combo_line_length(combo_count: int) -> float:
	if not RunState.stomp_combo_active():
		return 0.0
	return 192.0 if combo_count >= 30 else 96.0


# Broccoli + Potato — Earthshaker.
static func earthshaker_active() -> bool:
	return RunState.is_duo_active("broccoli_potato")


# ===========================================================================
# Rarity / level query getters (P2-B5a — the deferred stateful-getter batch).
# Read boon STATE (boon_rarities / boon_levels / current_offer_rarities /
# sensei_rarity_ranks) via RunState.; rarity tables via BoonDB.; the RunState-native
# Economy const SENSEI_RARITY_BONUS_PER_RANK via RunState. Intra-cluster calls route
# through the RunState facade (delegate → static), so no ordering dependency.
# ===========================================================================

# Run 41 — Sensei Z "Dragon's Fortune": each rank pushes every upgrade chance +5%.
static func get_rarity_chance_bonus() -> float:
	return RunState.SENSEI_RARITY_BONUS_PER_RANK * float(RunState.sensei_rarity_ranks)


# One rarity roll: base epic 10% / rare 20% / uncommon 30% / common 40%, each shifted
# up by the Dragon's Fortune bonus.
static func roll_rarity() -> String:
	var bonus: float = RunState.get_rarity_chance_bonus()
	var c_epic: float = BoonDB.RARITY_CHANCE_EPIC + bonus
	var c_rare: float = BoonDB.RARITY_CHANCE_RARE + bonus
	var c_unc:  float = BoonDB.RARITY_CHANCE_UNCOMMON + bonus
	var r: float = randf()
	if r < c_epic:
		return "epic"
	if r < c_epic + c_rare:
		return "rare"
	if r < c_epic + c_rare + c_unc:
		return "uncommon"
	return "common"


# Roll the on-card rarity for one offer slot (fixed tiers pass through).
static func roll_offer_rarity_for(boon_id: String) -> String:
	var base: String = RunState.get_base_rarity(boon_id)
	if base != "common":
		return base
	return RunState.roll_rarity()


# Rarity shown on the current offer card for this boon.
static func get_offer_rarity(boon_id: String) -> String:
	return String(RunState.current_offer_rarities.get(boon_id, RunState.get_base_rarity(boon_id)))


# Rarity the boon was TAKEN at (falls back to base for legacy saves).
static func get_boon_rarity(boon_id: String) -> String:
	return String(RunState.boon_rarities.get(boon_id, RunState.get_base_rarity(boon_id)))


static func get_boon_rarity_mult(boon_id: String) -> float:
	return float(BoonDB.RARITY_EFFECT_MULT.get(RunState.get_boon_rarity(boon_id), 1.0))


# Combined effect-bonus multiplier: rarity x Dragon Fruit levels.
# Callers scale the BONUS portion: 1.0 + base_bonus * get_boon_effect_mult(id).
static func get_boon_effect_mult(boon_id: String) -> float:
	return RunState.get_boon_rarity_mult(boon_id) * RunState.get_boon_level_mult(boon_id)


# Run 40 — Dragon Fruit level (1 = base, no bonus).
static func get_boon_level(boon_id: String) -> int:
	return int(RunState.boon_levels.get(boon_id, 1))


# Per-level bonus scales with the boon's ROLLED rarity (common +10% … epic +20%).
static func get_boon_level_mult(boon_id: String) -> float:
	var lvl: int = RunState.get_boon_level(boon_id)
	var per_level: float = float(BoonDB.RARITY_LEVEL_BONUS.get(RunState.get_boon_rarity(boon_id), 0.10))
	return 1.0 + per_level * float(max(0, lvl - 1))
