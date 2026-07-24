extends Node
# ============================================================
# RunState.gd — autoload singleton (registered as "RunState")
# ============================================================
# Persists the run-scoped state across scene transitions:
#   - active boons taken (per family)
#   - derived stat modifiers consumed by Player.gd & enemies
#   - persistent HP / Chi carry across arena transitions
#   - run progress counters (arenas cleared, loops completed)
#
# All Player.gd reads here on _ready() to apply boons.
# All boons funnel through `apply_boon(boon_id)` which both records
# the pick and updates the derived modifier values.
#
# Run 16 (2026-05-30) — RECONCILIATION pass against canonical
# Combat_Boons.md (+ tails v028/v028b). Major changes:
#   - Apple Orchard Bloom DECOUPLED from stackable HP — now a single
#     rarity-tied flat HP boon. Apple Pie (consumable, separate system)
#     is the centaur-heart-equivalent stackable max-HP source. Apple Pie
#     consumable lives in `apple_pie_stacks` for now (no pickup yet).
#   - Heavy Stalk + Full Bloom gated to PRIMARY (Y) attacks only via
#     a new is_primary flag threaded through _scale_damage.
#   - Junk passives removed: quickfoot, crit_eye, chi_channeling —
#     replaced with canonical Carrot (Hawkeye, Golden Carrot, Critical
#     Mass) + Watermelon (Hydration, Rising Tide, Tidal Refresh, Tide
#     Master) entries.
#   - Legacy tough_shell removed (canonical Tough Hide is the only entry).
#   - Added full canonical rosters for Pepper, Potato, Banana, Onion
#     (4–6 highest-impact passives each per the build-log brief).
#   - Added rarity field on every boon (Common/Uncommon/Rare/Epic/Legendary).
#   - Added Apple Granny's Recipe (+30% heal amp) + Apple Hour (heal-events
#     extend timed buffs +1s).
#   - Added the remaining 5 family DDs as boons: Iron Husk (Coconut),
#     Green Vengeance (Broccoli), Heart Shot (Carrot), Tide Pool
#     (Watermelon), Vintage Surge (Grape), Phoenix Pepper, Stone Form,
#     Banana Splits, Death Bloom (Onion).
# ============================================================

# ── GLOBAL depth / z-index rules (ALL biomes) ────────────────────────────────
# Single source of truth for hero-vs-prop draw order. The room's root Node2D has
# y_sort_enabled=true, so heroes and INTERIOR props at the same z_index are drawn
# by foot-Y (lower Y = farther = behind, higher Y = closer = in front). This gives
# a natural top-down 3D feel — heroes walk IN FRONT of obstacles when south of them
# and BEHIND them when north.
#
# Ordering:
#   z=0 (hero sprites + interior prop wraps) → y-sorted together by foot Y
#   BARRIER_OVERHANG_Z (3)                   → wall/border props, always on top
#   HERO_DASH_Z (4)                          → dashing hero flies over everything
#   combat FX (4+) < nameplates (20)
#
# Interior obstacle sprites sit inside a foot-anchored Node2D wrapper at
# z=0 (absolute) so y_sort places them in the same pool as hero sprites.
# Hero sprites use z=0 (relative to CharacterBody2D at z=0) during normal
# play, and HERO_DASH_Z when dashing.  Wall/border props stay at
# BARRIER_OVERHANG_Z (always drawn over heroes regardless of position).
# HERO_BODY_Z is retained for legacy references / SealedBarrier split.
const HERO_BODY_Z: int = 2
const BARRIER_OVERHANG_Z: int = 3
const HERO_DASH_Z: int = 4

# ── Phase-2 B1 facade: pure-data tables live on BoonDB; RunState re-exports
# each moved const under its original name so all RunState.<CONST> refs resolve.
const BoonDBClass = preload("res://scripts/BoonDB.gd")

# ── Per-character boon ownership ─────────────────────────────────────────────
# Each boon room has two phases: Phase 0 = Shino picks, Phase 1 = Bea picks.
# Boon effects must only apply to the ninja who personally took the boon.
# Maps boon_id → pick count (some boons are stackable).
var shino_boon_set: Dictionary = {}
var bea_boon_set:   Dictionary = {}

# Run 39 — true once the Dojo Boon Dispenser has granted any sandbox boon this
# visit. Dojo._start_sleep() checks it and re-runs reset_run() so test builds
# never leak into a real run.
var dojo_sandbox_used: bool = false

func shino_has(id: String) -> bool:   return id in shino_boon_set
func bea_has(id: String)   -> bool:   return id in bea_boon_set
# Run 130 — either hero owns it (team-wide effects: statuses are shared).
func team_has(id: String)  -> bool:   return (id in shino_boon_set) or (id in bea_boon_set)

# Run 27g — True only if `who` ("shino"|"bea") owns a boon (or active duo) that
# actually uses the Ingrained standing-still mechanic. Used to gate the HUD
# "Ingrained" readout so it never shows without a relevant Potato boon.
const _INGRAINED_BOONS: Array = ["heavy_stance", "tremor_walk", "mountain_king"]
const _INGRAINED_DUOS:  Array = ["apple_potato", "carrot_potato", "coconut_potato"]
func hero_uses_ingrained(who: String) -> bool:
	for id in _INGRAINED_BOONS:
		if char_has(id, who):
			return true
	for d_id in _INGRAINED_DUOS:
		if is_duo_active(d_id):
			return true
	return false

# Run 27b — Ingrained (standing-still 2s+) state, updated per-frame by
# Player.gd / BeaAI.gd. Read by roll_crit_mult (Headshot duo) and future
# Ingrained-gated effects.
# Run 27g — Single source of truth for the "stand in place" (Ingrained) timer.
# Any skill with a standing-still requirement gates on this same threshold, so
# changing it here re-tunes Heavy Stance, Mountain King, Tremor Walk, Deep Roots,
# Bunker, Headshot, and the HUD readout together.
const INGRAINED_THRESHOLD: float = 1.5

# Run 112 — Single source of truth for charge timing, shared by BOTH heroes so
# Shino and Bea charge identically for every skill (Y/X/A). Player.gd and
# BeaAI.gd read these instead of declaring their own copies; change here once.
#   CHARGE_DETECT — button-hold threshold to commit from tap → charge.
#   CHARGE_WINDUP — time from commit → fully CHARGED.
const CHARGE_DETECT: float = 0.15
const CHARGE_WINDUP: float = 0.47

var shino_ingrained: bool = false
var bea_ingrained: bool = false

# Run 60 — centralized combo counters (single source of truth, replaces
# scattered per-character reads). Player.gd + BeaAI.gd write through to these
# mirrors on every combo-state change so external systems (boon helpers, duo
# triggers) can query without holding a node reference. The per-character
# `combo_count` fields on Player.gd / BeaAI.gd remain the live state for the
# hot path and the HUD; these mirrors track them.
var combo_shino: int = 0
var combo_bea:   int = 0

func get_combo(who: String) -> int:
	return combo_shino if who == "shino" else combo_bea

func set_combo(who: String, n: int) -> void:
	if who == "shino":
		combo_shino = n
	else:
		combo_bea = n

func char_has(id: String, who: String) -> bool:
	return shino_has(id) if who == "shino" else bea_has(id)

# Run 58 — A-slot ranged boons (Slugshot / Stone Throw). Both apply to whichever
# hero owns the family, on both ranged weapons (Kunai + Ki Blast).
const STONE_THROW_SPACING: float = 46.0   # px gap between the two stones in a line

# Damage multiplier on ranged hits. Slugshot = +50%. Stone Throw gets NO flat
# bonus — its second projectile IS the damage increase (avoids double-dipping).
func get_ranged_damage_mult(who: String) -> float:
	return 1.5 if char_has("slugshot", who) else 1.0

# How many projectiles a single ranged attack fires. Stone Throw = 2 (in a line,
# spaced), each stopping on impact with heavy knockback — "two mobs, one stone."
func ranged_shot_count(who: String) -> int:
	return 2 if char_has("stone_throw", who) else 1

# Run 59 — Grape Shot (Grape A): ranged attacks split on impact into 1 main +
# N smaller shots at 40% damage in a forward fan. Per-character flag; queried by
# KiBlast (shino) and Kunai (bea) on impact. Splits are flagged _is_grape_split
# and never re-split (prevents cluster cascades — Cluster Theory legendary does
# the recursive split path separately).
# Run 60: bumped split count 2 → 3 (cluster identity) and fan ±25° → ±30° so all
# three sub-shots read distinctly. Fan is now the FULL half-spread (sub-shots
# evenly distributed across the [-fan, +fan] arc).
const GRAPE_SPLIT_COUNT: int = 3              # 3 sub-shots per split (was 2)
const GRAPE_SPLIT_DMG_MULT: float = 0.40      # 40% of original damage
const GRAPE_SPLIT_FAN_DEG: float = 30.0       # ± fan half-angle from impact direction (was 25)
const GRAPE_SPLIT_SCALE: float = 0.65         # smaller visual

# Run 139 — picker hint for apply_boon arms that need the taker's identity
# (e.g. Poison Apple's Golden Apple DD). BoonOffer sets this before apply_boon;
# defaults to "shino" for legacy single-player apply paths.
var pending_picker: String = "shino"

func add_boon_for(who: String, id: String) -> void:
	if who == "shino":
		shino_boon_set[id] = shino_boon_set.get(id, 0) + 1
	else:
		bea_boon_set[id]   = bea_boon_set.get(id, 0) + 1


# Run 139 — Poison Apple identity (Bruno's spec): the taker's HP is permalocked
# at 50, so every max-HP % gain they'd receive converts into the same flat %
# added to ALL other stats instead (damage, crit chance, crit damage, defense,
# move speed, attack speed, Chi gain). Sources: Orchard Bloom (per-char picks),
# apple pies (shared), Sensei Vital Core, Iron Core duo HP arm. Candy Apple's
# flat temp HP keeps its own overshield identity (simply clamped by the lock).
func get_poison_apple_conversion_pct(who: String) -> float:
	if not char_has("corrupt_apple", who):
		return 0.0
	var pct: float = get_orchard_bloom_pct_for(who) + get_apple_pie_max_hp_pct() + sensei_hp_pct
	pct += maxf(0.0, get_iron_core_hp_mult() - 1.0)
	return maxf(0.0, pct)


# Run 44 — Slot trade-out: remove a boon from one ninja's build (the slot it
# occupied was taken over by a replacement pick).
func remove_boon_from_char(who: String, id: String) -> void:
	var s: Dictionary = shino_boon_set if who == "shino" else bea_boon_set
	if not (id in s):
		return
	s.erase(id)
	# Remove ONE instance from the global taken list (re-offerability).
	var idx: int = boons_taken.find(id)
	if idx != -1:
		boons_taken.remove_at(idx)
	# Family investment counter follows the trade (legendary/duo prereqs).
	match String(BOON_POOL.get(id, {}).get("family", "")):
		"Apple":      apple_boons_taken      = max(0, apple_boons_taken - 1)
		"Coconut":    coconut_boons_taken    = max(0, coconut_boons_taken - 1)
		"Broccoli":   broccoli_boons_taken   = max(0, broccoli_boons_taken - 1)
		"Carrot":     carrot_boons_taken     = max(0, carrot_boons_taken - 1)
		"Grape":      grape_boons_taken      = max(0, grape_boons_taken - 1)
		"Watermelon": watermelon_boons_taken = max(0, watermelon_boons_taken - 1)
		"Pepper":     pepper_boons_taken     = max(0, pepper_boons_taken - 1)
		"Potato":     potato_boons_taken     = max(0, potato_boons_taken - 1)
		"Banana":     banana_boons_taken     = max(0, banana_boons_taken - 1)
		"Onion":      onion_boons_taken      = max(0, onion_boons_taken - 1)
	# If NEITHER ninja owns it anymore, clear the legacy global flag (slot
	# boons follow the "<id>_taken" naming convention) + apply-time numerics.
	var other: Dictionary = bea_boon_set if who == "shino" else shino_boon_set
	if not (id in other):
		var flag: String = id + "_taken"
		if flag in self:
			set(flag, false)
		match id:
			"full_bloom_apple":
				full_bloom_taken = false
			"coconut_bash":
				bash_on_hit_chance = 0.0
				bash_bonus_damage  = 0
			"shell_breaker":
				shell_breaker_chance = 0.0
			"overshield_dash":
				overshield_grant_on_dash = 0
				# Run 150b — zero the per-hero grant for any hero no longer owning it.
				for _osw in ["shino", "bea"]:
					if not char_has("overshield_dash", _osw) and not char_has("adamantium_husk", _osw):
						overshield_grant_on_dash_by[_osw] = 0
		boon_rarities.erase(id)
		boon_levels.erase(id)


# Run 44 — One boon per slot per ninja (Bruno's spec: X/Y/A/Dash/Charge/Ult).
# Registers a slot pick for `who`; if that slot was occupied by a DIFFERENT
# boon, the old one is traded out and the new one gets +1 level as the
# trade-off compensation. Returns the replaced boon id ("" if none).
func register_slot_pick(who: String, boon_id: String) -> String:
	var slot: String = get_slot_for_boon(boon_id)
	if slot == "":
		return ""
	var slots: Dictionary = owned_slots_by_char.get(who, {})
	var old_id: String = String(slots.get(slot, ""))
	slots[slot] = boon_id
	if old_id == "" or old_id == boon_id:
		return ""
	remove_boon_from_char(who, old_id)
	boon_levels[boon_id] = get_boon_level(boon_id) + 1
	print("[RunState] %s slot %s traded: %s → %s (starts at L%d)" % [
		who.capitalize(), slot, old_id, boon_id, get_boon_level(boon_id)])
	return old_id

# Count boons belonging to a character from a given family.
func char_family_count(who: String, family: String) -> int:
	var s: Dictionary = shino_boon_set if who == "shino" else bea_boon_set
	var n: int = 0
	for id in s.keys():
		if BOON_POOL.get(id, {}).get("family", "") == family:
			n += s[id]
	return n

# ── Per-character computed multipliers ───────────────────────────────────────
# These replace global damage_mult / attack_speed_mult / move_speed_mult for
# combat calculations. Called by Player.gd ("shino") and BeaAI.gd ("bea").
func get_char_damage_mult(who: String) -> float:
	var s: Dictionary = shino_boon_set if who == "shino" else bea_boon_set
	var m: float = 1.0
	if "brute_force"    in s: m *= (1.0 + BRUTE_FORCE_DMG_BONUS)
	var char_dd: int = shino_dd_charges if who == "shino" else bea_dd_charges
	if "green_vengeance" in s and char_dd > 0: m *= 1.10  # passive while this ninja holds DD
	# Stalk of Might: +5% per broccoli boon this character owns.
	m *= get_stalk_of_might_mult_for(who)
	# Run 139 — corrupt damage arms are TAKER ONLY (moved off global damage_mult).
	if "corrupt_coconut"  in s: m *= 1.50   # Cracked Shell +50% dealt
	if "corrupt_broccoli" in s: m *= 2.0    # Burnout +100% dealt
	# Run 139 — Poison Apple: converted max-HP gains land here as flat % damage.
	m *= (1.0 + get_poison_apple_conversion_pct(who))
	return m * damage_mult   # damage_mult covers global modifiers (boons that affect both)

func get_char_attack_speed_mult(who: String) -> float:
	var s: Dictionary = shino_boon_set if who == "shino" else bea_boon_set
	var m: float = 1.0
	if "heavy_stalk" in s: m *= 1.10
	if "tailwind"    in s: m *= (1.0 + tailwind_pct)
	m *= (1.0 + get_burning_aim_attack_speed_bonus())   # Run 27 — Burning Aim arm 2
	m *= (1.0 + get_poison_apple_conversion_pct(who))   # Run 139 — Poison Apple conversion
	return m

func get_char_move_speed_mult(who: String) -> float:
	var s: Dictionary = shino_boon_set if who == "shino" else bea_boon_set
	var m: float = 1.0
	if "zip_dash" in s: m *= 1.15
	if "tailwind" in s: m *= (1.0 + tailwind_pct)
	if "corrupt_potato" in s: m *= 1.20   # Run 139 — Uprooted +20% MS, taker only
	m *= (1.0 + get_poison_apple_conversion_pct(who))   # Run 139 — Poison Apple conversion
	return m * move_speed_mult   # move_speed_mult covers shared modifiers

func get_stalk_of_might_mult_for(who: String) -> float:
	var count: int = char_family_count(who, "Broccoli")
	if count == 0: return 1.0
	return 1.0 + count * 0.05   # +5% per Broccoli boon this character owns

# ── Per-character HP bonus (Orchard Bloom) ────────────────────────────────────
# Each pick of orchard_bloom grants +20% max HP to the picking ninja only.
func get_orchard_bloom_pct_for(who: String) -> float:
	var s: Dictionary = shino_boon_set if who == "shino" else bea_boon_set
	return float(s.get("orchard_bloom", 0)) * 0.20

# ── Per-character damage-taken multiplier ─────────────────────────────────────
# Computes the combined DR for one ninja from their owned defensive boons.
# Replaces reading RunState.damage_taken_mult directly in take_damage().
func get_damage_taken_mult_for(who: String) -> float:
	var s: Dictionary = shino_boon_set if who == "shino" else bea_boon_set
	var m: float = 1.0
	# Run 44 — Tough Hide is single-pick now (stackable was an old-GDD leftover
	# that let it be taken twice). DR scales with rolled rarity + Dragon Fruit
	# levels instead: -15% base, x effect mult, clamped to -60% max.
	if s.get("tough_hide", 0) > 0:
		m *= max(0.40, 1.0 - 0.15 * get_boon_effect_mult("tough_hide"))
	if "starch_armor" in s:
		m *= 0.90
	if "corrupt_coconut" in s:
		# Cracked Shell: -40% damage taken (internal armor) per Combat_Boons §6.3.
		m *= 0.60
	# Global DR from Sensei Z still applies to both characters.
	if sensei_dr_pct > 0.0:
		m *= max(0.0, 1.0 - sensei_dr_pct)
	# Run 139 — Poison Apple: converted max-HP gains land here as defense
	# (damage-taken reduction), capped at -75% so stacked pies can't hit
	# full immunity — the 1-damage-per-hit rule is the corrupt's real armor.
	var _pa_conv: float = get_poison_apple_conversion_pct(who)
	if _pa_conv > 0.0:
		m *= maxf(0.25, 1.0 - _pa_conv)
	return m

# Run 27 — family-color attack glow (Bruno's spec): attack/impact FX take the
# family color of the slot boon the character owns for that attack slot
# ("Y","X","A","B","Charge"). Transparent = no slot boon owned; caller keeps
# its base color. Checks the newer boon_slot field first, then the
# BOON_ATTACK_SLOT exact-slot tag (covers older entries like full_bloom_apple).
func get_attack_tint(who: String, slot: String) -> Color:
	var s: Dictionary = shino_boon_set if who == "shino" else bea_boon_set
	for k in s.keys():
		var b: Dictionary = BOON_POOL.get(k, {})
		if String(b.get("boon_slot", "")) == slot \
		or String(BOON_ATTACK_SLOT.get(k, "")) == slot:
			return FAM_COLOR.get(String(b.get("family", "")), Color(0, 0, 0, 0))
	return Color(0, 0, 0, 0)

# ── Per-character Dragon Fruit candidates ─────────────────────────────────────
# Returns boon IDs owned by `who` that can be upgraded (Dragon Fruit pick).
func get_dragon_fruit_candidates_for(count: int, who: String) -> Array:
	var s: Dictionary = shino_boon_set if who == "shino" else bea_boon_set
	if s.is_empty():
		return []
	var candidates: Array = s.keys()
	candidates.sort_custom(func(a, b): return get_boon_level(a) < get_boon_level(b))
	candidates.shuffle()
	return candidates.slice(0, min(count, candidates.size()))

# ── Per-character Fall Harvest heal ──────────────────────────────────────────
# Returns the heal-per-charge-kill pct for the given ninja (0.0 if no boon).
func get_fall_harvest_heal_pct_for(who: String) -> float:
	var s: Dictionary = shino_boon_set if who == "shino" else bea_boon_set
	if "fall_harvest" not in s:
		return 0.0
	return charge_kill_heal_pct if charge_kill_heal_pct > 0.0 else 0.01

# ── Stat modifiers (read by Player.gd / enemies via getters) ─────────────────
var max_hp_bonus_pct:     float = 0.0
var apple_pie_stacks:     int   = 0
var damage_mult:          float = 1.0   # global — only mutated by boons that truly affect both
var damage_taken_mult:    float = 1.0
var move_speed_mult:      float = 1.0   # global baseline; per-char computed via get_char_move_speed_mult
var attack_speed_mult:    float = 1.0   # global baseline; per-char computed via get_char_attack_speed_mult
var max_chi_bonus:        int   = 0     # flat bonus to Chi cap
var charge_kill_heal_pct: float = 0.0   # % of max HP healed on charge-attack kill (Fall Harvest)
var melee_lifesteal_pct:  float = 0.0   # % of melee damage dealt healed back (legacy field — reserved for future melee lifesteal boons)
# Run 26d — Baked Apple reworked from global lifesteal to finisher-triggered HoT.
# Was: 10% lifesteal on every melee hit (free heal to max). Now: combo finisher
# (Y4 / X3) starts a 5s 1-HP/sec HoT. Total max heal per proc = 5 HP. Stacking
# multiple finishers in 5s refreshes the timer (no stacking pile of HoTs).
var baked_apple_taken: bool = false
const BAKED_APPLE_HOT_DURATION: float = 5.0
const BAKED_APPLE_HOT_HP_PER_SEC: float = 1.0
var crit_chance:          float = 0.0   # global crit chance (Carrot family — was Crit Eye placeholder, now drives Hawkeye/Golden Carrot/etc.)
var crit_damage_bonus:    float = 0.0   # additive bonus on top of the 1.5× base crit (Hawkeye +25%)
var heal_amp_mult:        float = 1.0   # multiplicative amp on ALL incoming heals (Apple Granny's Recipe — +30%)

# =============================================================
# SLOT BOON FLAGS — one per family slot (Y/X/A/B/Charge).
# All added in the slot-boon pass to cover every family.
# =============================================================

# --- Apple slot boons ---
var heavy_harvest_taken:   bool = false   # X: secondary attacks scale +25% at full HP
var seeded_shot_taken:     bool = false   # A: ranged +1% max HP bonus damage
var evergreen_step_taken:  bool = false   # B: heal 1% max HP on first hit post-dash (6s CD)
var sweet_harvest_taken:   bool = false   # Charge: +20% dmg at 75%+ HP + heal 1% max HP on hit (8s CD)
var _evergreen_step_cd:    float = 0.0    # runtime CD (not persisted)
var _sweet_harvest_cd:     float = 0.0    # runtime CD

# --- Coconut slot boons ---
var coconut_volley_taken:  bool = false   # A: ranged 30% chance Mini-Bash + bonus dmg
var coco_slam_taken:       bool = false   # Charge: charge ends in ministun + Vulnerable 3s

# --- Broccoli slot boons ---
var brute_force_taken:     bool = false   # X: +35% dmg + small AoE shockwave on hit
var slugshot_taken:        bool = false   # A: ranged +50% dmg + pierce
var bull_rush_taken:       bool = false   # B: dash deals contact damage to enemies crossed
var fury_release_taken:    bool = false   # Charge: +60% charge dmg + wider hit area
const FURY_RELEASE_DMG_BONUS = BoonDBClass.FURY_RELEASE_DMG_BONUS
const FURY_RELEASE_AREA_BONUS = BoonDBClass.FURY_RELEASE_AREA_BONUS
const BRUTE_FORCE_DMG_BONUS = BoonDBClass.BRUTE_FORCE_DMG_BONUS
const BRUTE_FORCE_SHOCKWAVE_RADIUS = BoonDBClass.BRUTE_FORCE_SHOCKWAVE_RADIUS

# --- Carrot slot boons ---
var keen_eye_taken:        bool = false   # Y: +15% crit chance, +10% crit dmg on Y hits
var sharpened_tip_taken:   bool = false   # X: +25% crit chance, +20% crit dmg on X hits
var bullseye_taken:        bool = false   # A: +20% crit chance, +30% crit dmg on A hits
var flanking_strike_taken: bool = false   # B: guaranteed crit within 1s of dash
var _flanking_window:      float = 0.0    # runtime timer (not persisted)
const KEEN_EYE_CRIT_CHANCE = BoonDBClass.KEEN_EYE_CRIT_CHANCE
const KEEN_EYE_CRIT_DMG = BoonDBClass.KEEN_EYE_CRIT_DMG
const SHARPENED_TIP_CRIT_CHANCE = BoonDBClass.SHARPENED_TIP_CRIT_CHANCE
const SHARPENED_TIP_CRIT_DMG = BoonDBClass.SHARPENED_TIP_CRIT_DMG
const BULLSEYE_CRIT_CHANCE = BoonDBClass.BULLSEYE_CRIT_CHANCE
const BULLSEYE_CRIT_DMG = BoonDBClass.BULLSEYE_CRIT_DMG

# --- Grape slot boons ---
var cluster_strike_taken:  bool = false   # Y: finisher +60% dmg + Vinewrap 2s
var overhead_crush_taken:  bool = false   # X: finisher bonus dmg + Vinewrap 2s
var grape_shot_taken:      bool = false   # A: ranged splits 1+2 (40% dmg each)
var vine_lash_taken:       bool = false   # B: dash-then-attack within 0.5s → 3 bonus vines
# Run 150b — Vine Lash wired (Bruno): pure bonus damage, no pull/root.
const VINE_LASH_WINDOW = BoonDBClass.VINE_LASH_WINDOW
const VINE_LASH_COUNT = BoonDBClass.VINE_LASH_COUNT
const VINE_LASH_DAMAGE = BoonDBClass.VINE_LASH_DAMAGE
const VINE_LASH_RANGE = BoonDBClass.VINE_LASH_RANGE
const VINE_LASH_CONE_DEG = BoonDBClass.VINE_LASH_CONE_DEG
var bunch_burst_taken:     bool = false   # Charge: hits 2 extra times at 50%
const CLUSTER_STRIKE_BONUS = BoonDBClass.CLUSTER_STRIKE_BONUS
const BUNCH_BURST_HITS = BoonDBClass.BUNCH_BURST_HITS
const BUNCH_BURST_DMG_PCT = BoonDBClass.BUNCH_BURST_DMG_PCT

# --- Watermelon slot boons (B + Charge — Y/X/A already added) ---
var hydro_slide_taken:     bool = false   # B: puddle at dash landing (Soaked/sec)
var flood_charge_taken:    bool = false   # Charge: hits apply 3 Soaked + slow

# --- Pepper slot boons (A/B/Charge — Y/X already added) ---
var fireball_taken:        bool = false   # A: ranged explodes, small AoE Burn
var fire_trail_taken:      bool = false   # B: dash leaves 2s flame line
var inferno_charge_taken:  bool = false   # Charge: scorched patch at charge hit site

# --- Potato slot boons ---
var spud_stomp_taken:      bool = false   # Y: +15% earth dmg + finisher Ground Pound
var rock_smash_taken:      bool = false   # X: +30% earth dmg + 1 Cracked Soil/hit
var stone_throw_taken:     bool = false   # A: ranged fires 2 in a line, no pierce, heavy knockback
var tuber_burrow_taken:    bool = false   # B: hold to burrow (invuln + rise attack)
var quake_charge_taken:    bool = false   # Charge: ring quake + spikes + knockdown + Cracked Soil
const SPUD_STOMP_EARTH_BONUS = BoonDBClass.SPUD_STOMP_EARTH_BONUS
const ROCK_SMASH_EARTH_BONUS = BoonDBClass.ROCK_SMASH_EARTH_BONUS
const STONE_THROW_DMG_BONUS = BoonDBClass.STONE_THROW_DMG_BONUS
const QUAKE_CHARGE_RADIUS = BoonDBClass.QUAKE_CHARGE_RADIUS

# --- Banana slot boons ---
var peel_slap_taken:       bool = false   # Y: applies Slippery (or Sparked in GL)
var voltaic_strike_taken:  bool = false   # X: applies Greased (or Bolted in GL)
var bananarang_taken:      bool = false   # A: boomerang — Slippery out, Greased return
var zip_dash_taken:        bool = false   # B: +20% dash dist + 15% MS
var storm_charge_taken:    bool = false   # Charge: knockdown wind (default) or chain-3 (GL)

# --- Onion slot boons (Y/X already as pungent_jab/tear_strike in Wet/Burn system — now explicit) ---
var pungent_jab_taken:     bool = false   # Y: 1 Poison/hit on Y attacks
var tear_strike_taken:     bool = false   # X: +30% dmg + 2 Poison/hit on X attacks
var stink_bomb_taken:      bool = false   # A: ranged → gas cloud on impact
var gas_bookends_taken:    bool = false   # B: clouds at dash start + end
var reek_charge_taken:     bool = false   # Charge: 360° gas burst + cloud

# --- Apple Full Bloom (slot Y boon — Combat_Boons §8.1) ---
# Spec: +15% damage to PRIMARY attacks while at >=80% HP. SINGLE pick
# (slot boon, not stackable). Run 16: rewrote from stackable count to bool.
var full_bloom_taken: bool = false

# --- Broccoli Heavy Stalk (slot Y boon — Combat_Boons §8.3) ---
# Spec: +15% damage AND +10% attack speed to PRIMARY attacks. SINGLE pick.
# Run 16: pulled out of damage_mult/attack_speed_mult globals.
var heavy_stalk_taken: bool = false

# --- Coconut Bash (slot Y boon — Combat_Boons §8.2) ---
# Spec: 20% base chance, stuns 1s + bonus damage. Stackable conceptually
# only in that picking another Y-slot upgrade refreshes — for now single.
var bash_on_hit_chance:   float = 0.0
var bash_bonus_damage:    int   = 0

# --- Coconut Shell Breaker (slot X — Combat_Boons §8.2) ---
# Spec: X attacks 30% chance → Vulnerable (+25% dmg taken / 5s).
var shell_breaker_chance:   float = 0.0
const SHELL_BREAKER_VULN_DUR = BoonDBClass.SHELL_BREAKER_VULN_DUR

# --- Coconut Overshield + caps (Combat_Boons §8.2) ---
var overshield_grant_on_dash: int = 0   # LEGACY global (kept for save-compat; reads now per-hero)
var overshield_max:           int = 0   # LEGACY global cap (kept for save-compat; reads now per-hero)
var stockpile_taken:          bool = false
# Run 150b (Bruno ruling) — Hardshell Roll / Stockpile / Adamantium Husk are
# holder-only: one ninja's pick no longer raises BOTH ninjas' dash-grant/cap.
var overshield_grant_on_dash_by: Dictionary = {"shino": 0, "bea": 0}
var overshield_max_by:           Dictionary = {"shino": 0, "bea": 0}
func get_overshield_grant_on_dash(who: String) -> int:
	return int(overshield_grant_on_dash_by.get(who, 0))
func get_overshield_max(who: String) -> int:
	return int(overshield_max_by.get(who, 0))
var nutshell_taken:           bool = false
const NUTSHELL_RADIUS = BoonDBClass.NUTSHELL_RADIUS
const NUTSHELL_BASH_DURATION = BoonDBClass.NUTSHELL_BASH_DURATION
# Run 44 — Shellburst (doc §8.2 p5): flat damage on overshell break, by the
# taken rarity of the boon (id stays "nutshell" for save/wiring compat).
const SHELLBURST_DMG_BY_RARITY = BoonDBClass.SHELLBURST_DMG_BY_RARITY
func get_shellburst_damage() -> int:
	var base: int = int(SHELLBURST_DMG_BY_RARITY.get(get_boon_rarity("nutshell"), 5))
	# Dragon Fruit levels scale the damage portion further.
	return int(round(float(base) * get_boon_level_mult("nutshell")))
var hard_landing_taken:       bool = false
var tough_hide_taken_count:   int = 0
# Run 16 — new Coconut passives:
var chip_proof_taken:         bool = false
var tough_cookie_taken:       bool = false
var battle_shell_taken:       bool = false   # Ult-grant overshells covered separately; this is the KO/X-finisher generator
const BATTLE_SHELL_DURATION = BoonDBClass.BATTLE_SHELL_DURATION

# --- Apple flags (Combat_Boons §8.1) ---
var ripened_core_taken:     bool = false
var heart_of_orchard_taken: bool = false
var sweet_dreams_taken:     bool = false
var grannys_recipe_taken:   bool = false   # +30% heal amp (multiplicative)
var apple_hour_taken:       bool = false   # heal events extend timed buffs +1s (ICD 3s)

# --- Broccoli (Combat_Boons §8.3) ---
# Green Rage = always-on tiered rage (<50% +30% dmg; <25% +50% dmg + 25% DR — replaces, not stacks)
var green_rage_taken:       bool = false
# Combat Fury = consecutive hit ramp; tier driven by rarity (5 tiers; per-tier % rarity-scaled).
var combat_fury_taken:      bool = false
var combat_fury_pct_per_tier: float = 0.0   # set from rarity on pick
const COMBAT_FURY_MAX_TIERS = BoonDBClass.COMBAT_FURY_MAX_TIERS
const COMBAT_FURY_DECAY_SEC = BoonDBClass.COMBAT_FURY_DECAY_SEC
var iron_will_taken:        bool = false   # one CC defy every 10s
var crushing_blow_taken:    bool = false   # +50% dmg to enemies <30% HP
var bash_big_ones_taken:    bool = false   # +25% dmg to elites/bosses
var big_broccoli_taken:     bool = false   # +50% melee arc / +0.5m reach / +50% projectile size

# --- Carrot (Combat_Boons §8.4) — canonical replacements for quickfoot/crit_eye ---
var hawkeye_taken:          bool = false   # +25% base crit damage
var golden_carrot_taken:    bool = false   # combo finisher (final Y or X) is guaranteed crit (updated from every-5th-hit)
var golden_carrot_streak:   int  = 0       # no longer used for 5th-hit tracking; kept for reset_run compatibility
var critical_mass_taken:    bool = false   # crits → +15% MS/+15% AS for 4s, stacks 3
var opening_strike_taken:   bool = false   # first hit on full-HP enemy is guaranteed crit
var finishers_aim_taken:    bool = false   # Carrot Charge slot: +50% crit chance on combo finishers (v028)
# Run 16: Critical Mass live state lives on Player nodes; RunState exposes the rule only.
const CRITICAL_MASS_DURATION = BoonDBClass.CRITICAL_MASS_DURATION
const CRITICAL_MASS_PER_STACK_PCT = BoonDBClass.CRITICAL_MASS_PER_STACK_PCT
const CRITICAL_MASS_MAX_STACKS = BoonDBClass.CRITICAL_MASS_MAX_STACKS

# --- Grape (Combat_Boons §8.5) ---
var combo_master_taken: bool = false
var noble_rot_taken:    bool = false
var bunch_bonus_taken:  bool = false
var cluster_mastery_taken: bool = false   # double-hit + Chi-refund-on-kill, scales with combo
var cluster_cascade_taken: bool = false   # cross-finisher amp window

# --- Watermelon (Combat_Boons §8.7) — canonical replacement for chi_channeling ---
var rising_tide_taken:  bool = false      # Wet/Frostbitten enemies take +15% from all sources
var hydration_taken:    bool = false      # +0.5 Chi/sec base, +1.5/sec at 8s sustained combat
var tidal_refresh_taken: bool = false     # +2 Chi on Wet/Chilled apply (1/tgt/3s ICD)
var tide_master_taken:  bool = false      # Ult cost -20% + refund 25% on fire
var melon_gelato_mode:  bool = false      # Gelato toggle (mode switch)
# Slot boon flags (enable per-attack Wet/Burn application at specific hit types)
var hydro_jab_taken:    bool = false      # Watermelon Y: +1 Soaked on Y hits
var heavy_tide_taken:   bool = false      # Watermelon X: +2 Soaked on X hits
var bubble_shot_taken:  bool = false      # Watermelon A: +2 Soaked on A hits
var spicy_jab_taken:    bool = false      # Pepper Y: +1 Burn on Y hits
var searing_strike_taken: bool = false    # Pepper X: +2 Burn + 40% fire dmg on X hits
var fire_damage_mult:      float = 1.0    # composite fire/burn damage multiplier
var lightning_damage_mult: float = 1.0    # composite lightning damage multiplier

# --- Pepper (Combat_Boons §8.6) ---
var slow_cook_taken:    bool = false      # Burn duration +50%
var blazing_aura_taken: bool = false      # burning enemies +10% dmg taken
var pyromania_taken:    bool = false      # consecutive-hit Burn ramp
var hot_footed_taken:   bool = false      # +30% MS for 3s after dash
var combust_taken:      bool = false      # 5 Burn stacks → explosion
const HOT_FOOTED_DURATION = BoonDBClass.HOT_FOOTED_DURATION
const HOT_FOOTED_SPEED_BONUS = BoonDBClass.HOT_FOOTED_SPEED_BONUS

# --- Potato (Combat_Boons §8.8) ---
var starch_armor_taken: bool = false      # -10% dmg taken + KB immunity
var spineback_taken:    bool = false      # 30% on damage-taken → counter spike + 50% mitigation
var heavy_stance_taken: bool = false      # Ingrained → +15% dmg + stagger immunity
var tremor_walk_taken:  bool = false      # passive Cracked Soil layering
const SPINEBACK_PROC_CHANCE = BoonDBClass.SPINEBACK_PROC_CHANCE
const SPINEBACK_MITIGATION = BoonDBClass.SPINEBACK_MITIGATION

# --- Banana (Combat_Boons §8.9) ---
var tailwind_taken:     bool = false
var tailwind_pct:       float = 0.0       # rarity-scaled baseline (5–10%), Pom +0..3
var peel_out_taken:     bool = false      # on dodge: +30% MS / +30% AS for 5s
var extra_banana_taken: bool = false      # +1 dash charge
var greased_lightning_mode: bool = false  # Banana mode toggle

# --- Onion (Combat_Boons §8.10) ---
var layered_defense_taken: bool = false   # 3m aura passively poisons nearby
var rotten_core_taken:     bool = false   # poisoned enemies → stink cloud on death
var chronic_reek_taken:    bool = false   # +50% Poison duration, +20% Poison dmg
var fermented_strength_taken: bool = false # +5% dmg per Poison stack on target
var overripe_taken:        bool = false   # Poison cap 5 → 7 (Pom can push to 10)
var poison_max_stacks_bonus: int = 0      # added to base 5 cap by Overripe

# --- Legendaries (Run 19) — gold-tier finishers per family ---
# Heart of the Orchard is already wired above (heart_of_orchard_taken).
var juicebox_of_youth_taken: bool = false   # Apple Legendary: kill heals +5% max HP
var adamantium_husk_taken:   bool = false   # Coconut Legendary: overshields permanent, break grants Nutshell + 2s i-frames
var hulk_smash_taken:        bool = false   # Broccoli Legendary: combo finishers cause shockwave (radius scales w/ combo)
# --- Run 23 Legendaries ---
var tidal_tsunami_taken:     bool = false   # Watermelon Legendary: +1 Wet/Chilled stack per hit tier
var inferno_crown_taken:     bool = false   # Pepper Legendary: +40% damage to burning enemies
var eagle_eye_taken:         bool = false   # Carrot Legendary: +25% crit chance, +25% crit damage bonus
var sniper_focus_taken:      bool = false   # Carrot Legendary 2: every 3rd crit → 2s +50% crit dmg
# Run 134 — PER-HERO streak + window (was one shared global). Keyed by "shino"/"bea"
# so Shino's crit streak never advances Bea's bonus and vice versa. Transient (not
# saved) — the streak/window rebuild live each fight.
var sniper_focus_crit_streak: Dictionary = {"shino": 0, "bea": 0}    # consecutive crit counter per hero
var sniper_focus_bonus_timer: Dictionary = {"shino": 0.0, "bea": 0.0} # +50% window countdown per hero
var slip_stream_taken:       bool = false   # Banana Legendary: dash-through-enemy → Grease field + extended i-frames
var voltaic_engine_taken:    bool = false   # Banana Legendary: Greased Lightning permanent + +1 chain jump

# --- Corrupt Boons (Run 19) — identity-flip mega-boons ---
# Distinct UI surfacing in BoonOffer (magenta/purple-black). Always carry a
# downside in addition to upside — the player accepts a trade.

# ── Per-character Death Defiance (rework) ────────────────────────────────────
# Each ninja carries at most 1 DD from boons (+ future Dragon Mirror permanent).
# When the team wipes, the last-fallen ninja's DD is consumed first; if they
# have none, fall back to the partner's DD. One consumed DD revives both ninjas.
const DD_PER_CHAR_BOON_CAP: int = 1
var shino_dd_charges: int = 0
var bea_dd_charges:   int = 0
var shino_dd_payloads: Array = []
var bea_dd_payloads:   Array = []
var _last_downed_char: String = ""   # "shino" | "bea" — set when a ninja falls

# Run 65 — manual "come revive me" recall. Set true when a downed, player-
# controlled ninja taps swap (Q+Q) while the AI is at tier 5 (where the swap is
# otherwise locked). The standing AI partner reads this to FORCE a channel-rez
# even when it would normally hesitate (low HP / enemies nearby). Auto-cleared
# by the standing partner's _tick_revive_attempt once nobody is downed.
var revive_recall_active: bool = false

# Legacy aliases kept so older references compile without mass-search.
var dd_charges_remaining: int:
	get: return shino_dd_charges + bea_dd_charges
var dd_payloads: Array:
	get: return shino_dd_payloads + bea_dd_payloads
var family_dd_taken: bool = false  # still gates 1-DD-boon-per-char-per-run

# Called by Player.gd / BeaAI.gd when a ninja enters the DOWNED state.
func notify_downed(char_name: String) -> void:
	_last_downed_char = char_name

# Grant a DD charge to a specific character (called from BoonOffer at pick-time).
func grant_dd_to_char(char_name: String, payload_id: String, rarity: String) -> void:
	if char_name == "shino":
		if shino_dd_charges < DD_PER_CHAR_BOON_CAP:
			shino_dd_charges += 1
			shino_dd_payloads.append({"payload": payload_id, "rarity": rarity})
	else:
		if bea_dd_charges < DD_PER_CHAR_BOON_CAP:
			bea_dd_charges += 1
			bea_dd_payloads.append({"payload": payload_id, "rarity": rarity})

func _char_has_dd(char_name: String) -> bool:
	return (shino_dd_charges > 0) if char_name == "shino" else (bea_dd_charges > 0)

func _consume_dd_for_char(char_name: String) -> Dictionary:
	var pool: Array = shino_dd_payloads if char_name == "shino" else bea_dd_payloads
	if pool.is_empty():
		return {"consumed": false, "payloads": []}
	if char_name == "shino": shino_dd_charges -= 1
	else:                    bea_dd_charges   -= 1
	var refill: float = 0.50
	var built: Array  = []
	for entry in pool:
		var p: String  = entry.get("payload", "")
		var r: String  = entry.get("rarity",  "common")
		var hot_pct: float = 0.0
		var hot_dur: float = 0.0
		if p == "apple_cider_mercy":
			match r:
				"common":    hot_pct = 0.03; hot_dur = 5.0
				"uncommon":  hot_pct = 0.035; hot_dur = 5.0
				"rare":      hot_pct = 0.04; hot_dur = 5.5
				"epic":      hot_pct = 0.045; hot_dur = 5.5
				"legendary": hot_pct = 0.05; hot_dur = 6.0
				_:           hot_pct = 0.03; hot_dur = 5.0
		built.append({"payload": p, "rarity": r, "hot_pct_per_sec": hot_pct, "hot_duration": hot_dur})
	if char_name == "shino": shino_dd_payloads.clear()
	else:                    bea_dd_payloads.clear()
	return {"consumed": true, "refill_pct": refill, "payloads": built}

const DD_CHARGE_HARD_CAP: int = 2   # kept for any remaining legacy references

# --- Run-meta counters ---
var arenas_cleared:        int = 0
var loops_completed:       int = 0
var broccoli_boons_taken:  int = 0      # for Stalk of Might stacking effect
var apple_boons_taken:     int = 0      # for Iron Core duo (Apple+Broccoli) later
var coconut_boons_taken:   int = 0
var carrot_boons_taken:    int = 0
var grape_boons_taken:     int = 0
var watermelon_boons_taken: int = 0
var pepper_boons_taken:    int = 0
var potato_boons_taken:    int = 0
var banana_boons_taken:    int = 0
var onion_boons_taken:     int = 0
var corrupt_boons_taken:   int = 0      # Run 19 — corrupt picks counter
var corrupt_accepted:      bool = false  # one-per-run cap: no more corrupts after first accept
# Identity-flip corrupt flags (GDD §6.3)
var corrupt_apple_taken:      bool = false   # Poison Apple
var corrupt_coconut_taken:    bool = false   # Cracked Shell
var corrupt_broccoli_taken:   bool = false   # Burnout
var corrupt_carrot_taken:     bool = false   # Chaos Carrot
var corrupt_grape_taken:      bool = false   # One Big Grape
var corrupt_pepper_taken:     bool = false   # Solar Flare
var corrupt_watermelon_taken: bool = false   # Cold Waters
var corrupt_potato_taken:     bool = false   # Uprooted
var corrupt_banana_taken:     bool = false   # Thunderstruck
var corrupt_onion_taken:      bool = false   # Fermented Wrath
# Corrupt Watermelon mode flags (both active simultaneously)
var watermelon_surge_active:  bool = false
var watermelon_tide_active:   bool = false

# --- Carry-over state ---
var carry_hp:  int = -1
var carry_chi: int = -1
var bea_carry_hp:  int = -1
var bea_carry_chi: int = -1
# Run 30 — persist which character the human was controlling when they exited.
# -1 = not set (default Shino), 0 = Shino, 1 = Bea.
var carry_player_controlled_char: int = -1

# ============================================================
# Run 73 — LOCAL 2-PLAYER CO-OP
# ============================================================
# Chosen on the PlayerSetup screen before save select. When two_player is true,
# BOTH ninjas are human-controlled simultaneously, each reading ONLY its own
# device (see InputRouter). When false the game behaves exactly as the classic
# single-player hot-swap build.
#
# NOTE: deliberately NOT cleared in reset_run() — reset_run also fires mid-run
# (Dojo sandbox, RunComplete) and must not silently drop the player out of 2P.
# MainMenu._ready() clears it back to single-player at the title instead.
var two_player: bool = false
# Device id controlling each ninja. -1 = keyboard, >=0 = joypad id.
# Only meaningful while two_player == true. A character swap exchanges these two.
var shino_device: int = -1   # -1 = keyboard
var bea_device:   int = -1

# Configure a fresh 2P session. who_controls_shino = "p1" or "p2".
func setup_two_player(p1_device: int, p2_device: int, who_controls_shino: String) -> void:
	two_player = true
	if who_controls_shino == "p1":
		shino_device = p1_device
		bea_device   = p2_device
	else:
		shino_device = p2_device
		bea_device   = p1_device

# Swap which device drives which ninja (the two players trade characters).
func swap_two_player_devices() -> void:
	var tmp: int = shino_device
	shino_device = bea_device
	bea_device   = tmp
# Resume routing — set to the next_scene_path just before each autosave so
# loading a slot resumes at the correct arena (not the Dojo intro).
# Empty string = no save yet (new game → go through Dojo normally).
var resume_scene_path: String = ""

# ── Tutorial & story progression (persistent — survive reset_run) ────────────
# tutorial_completed is set to true once the player finishes the 5-room intro
# dream sequence. New save files start with false and route to the tutorial
# instead of the Dojo. Once true, the game skips straight to the Dojo on load.
var tutorial_completed: bool = false
# sensei_lore_tier tracks how much of the story Sensei Z has revealed.
# Incremented after each night run clears a biome boss, unlocking new
# dialogue lines when the player talks to Sensei in the Dojo.
# 0 = initial (post-tutorial), 1+ = after clearing biomes.
var sensei_lore_tier: int = 0
# nights_completed tracks total night runs finished (win or lose), used to
# gate some progressive Sensei dialogue and family hints.
var nights_completed: int = 0
# tutorial_room tracks which of the 5 tutorial rooms the player is in.
# Only relevant during the initial tutorial; reset after tutorial_completed.
var tutorial_room: int = 1

# ============================================================
# AI Helper Tier — 5-TIER SPEC (Run 61, 2026-06-13)
# ============================================================
# Replaces the old 3-tier scaffold. Five canonical tiers, with the
# AI partner's combat aggression rising monotonically. Universal
# behaviors (follow at natural distance, trap avoidance, gate
# rallying, take damage normally, downable + reviveable) apply to
# every tier; only OFFENSIVE behaviors differ.
#
# Tier 1 — No Help (Spectator):  never attacks
# Tier 2 — Low Help  (Sidekick): rare ranged (~1 per 3-4s); ultra-rare charges
# Tier 3 — Helpful   (Balanced): default ranged, occasional melee, rare charges
# Tier 4 — Aggressive(Bruiser):  prefers melee, ranged as filler
# Tier 5 — Heroic    (Beast):    full kit, aggressive charges, hard target prio
#
# Default tier: 3 (Helpful). Persisted via Settings autoload, NOT
# the per-slot save (so the player's accessibility choice survives
# across save files).
# ============================================================
var ai_helper_tier: int = 3

# Run 61 — high-water mark: highest tier the partner was set to during
# the active run. Updates on swap-up, never decreases until reset_run().
# Used by RunComplete to display "Highest AI Helper Tier Used" and to
# award the SOLO SAVANT accolade when tier 1 holds the entire run.
var highest_ai_tier_used_this_run: int = 3

# Per-tier behavior table — read by BeaAI / Shino-AI heuristics.
# All distances in pixels, intervals in seconds, chances in [0..1].
# Tunable in one place; flagged values are the proposed starting
# numbers for Bruno's playtest pass.
const AI_TIER_TABLE = BoonDBClass.AI_TIER_TABLE

# Constants used by revive logic + safety probes.
const AI_CHANNEL_SAFE_RANGE = BoonDBClass.AI_CHANNEL_SAFE_RANGE
const AI_CHANNEL_HP_T2 = BoonDBClass.AI_CHANNEL_HP_T2
const AI_CHANNEL_HP_T3 = BoonDBClass.AI_CHANNEL_HP_T3
const AI_DASH_CANCEL_RANGE = BoonDBClass.AI_DASH_CANCEL_RANGE
const AI_CHARGE_SAFE_RANGE = BoonDBClass.AI_CHARGE_SAFE_RANGE
const AI_HAZARD_AVOID_RADIUS = BoonDBClass.AI_HAZARD_AVOID_RADIUS

# ============================================================
# Run 62 — Beast Mode (Tier 5) HP-floor guardrail.
# ============================================================
# At tier 5 the AI partner is "story-mode safe": it keeps fighting and
# takes damage normally, but its HP can never be reduced below this
# fraction of max. Hits still register (knockback, hitstop, chi gain) —
# only the net HP loss stops at the floor, so the AI never enters the
# DOWNED state and the player never has to scramble to revive it. Heals
# lift it back up normally, so its bar visibly rises and falls over a run.
#
# The floor follows CONTROL, not the character: it applies to whichever
# ninja is currently the AI (NOT player-controlled). Swap roles and the
# now-player-controlled ninja takes/floors damage normally again, while
# the ninja that just became the tier-5 AI gains the floor.
#
# Tuning: flip to 0.50 to playtest the gentler floor. Single source of
# truth — HUD guard visual + settings tooltip both read this constant.
const BEASTMODE_HP_FLOOR: float = 0.25

# True when a ninja should currently be damage-floored: it is the AI
# partner (not player-controlled) AND the helper tier is the max (5).
func is_beastmode_floored(is_player_controlled: bool) -> bool:
	return (not is_player_controlled) and ai_helper_tier == 5

# Minimum HP a floored ninja may be reduced to (0 when not floored, so
# normal characters keep the usual 0 = downable floor). Rounds UP so the
# guard never reads as below the advertised percentage.
func beastmode_hp_floor_value(is_player_controlled: bool, max_hp: int) -> int:
	if is_beastmode_floored(is_player_controlled):
		return int(ceil(float(max_hp) * BEASTMODE_HP_FLOOR))
	return 0

# One-line note surfaced in the tier-5 settings tooltip / description.
func beastmode_tooltip() -> String:
	return "AI helper cannot die at this tier — damage stops at %d%% HP (it keeps fighting and revives you)." % int(round(BEASTMODE_HP_FLOOR * 100.0))


# ---------------------------------------------------------------------------
# Tier setter — used by SettingsMenu / runtime swaps. Tracks the run
# high-water mark so RunComplete can show "Highest tier used: N".
# ---------------------------------------------------------------------------
func set_ai_helper_tier(t: int) -> void:
	t = clampi(t, 1, 5)
	var prev: int = ai_helper_tier
	ai_helper_tier = t
	if t > highest_ai_tier_used_this_run:
		highest_ai_tier_used_this_run = t
	# Run 61b — debug print so Bruno can confirm tier changes hit RunState.
	print("[RunState] AI Helper Tier: %d → %d (high-water: %d)" % [prev, t, highest_ai_tier_used_this_run])


func get_ai_tier_spec(t: int = -1) -> Dictionary:
	if t < 0:
		t = ai_helper_tier
	t = clampi(t, 1, 5)
	return AI_TIER_TABLE.get(t, AI_TIER_TABLE[3])


# Tier-1-only completion = SOLO SAVANT accolade on RunComplete.
func is_solo_savant_run() -> bool:
	return highest_ai_tier_used_this_run == 1

# --- Boons taken (list of boon IDs) ---
var boons_taken: Array = []
var current_offer: Array = []
var pending_reward: Dictionary = {}   # committed door pick; consumed by next BoonOffer

# Run 150 (Bruno fix 11) — GLOBAL ULT FREEZE. While one hero's ultimate
# cinematic runs, the other hero is fully frozen (no input / AI / attacks).
# The frozen partner may ONLY press their ult button, which sets
# double_ult_queued — the hook for the upcoming double-ult feature (GDD).
var ult_freeze_caster: String = ""    # "" = none, else "shino" / "bea"
var double_ult_queued: bool = false

# --- Slot ownership + replacement levels ---
# Tracks which Y/X/A/B/Charge slot is currently owned per family (boon ID or "").
# When a new family's slot boon is taken and the player already had a different family
# in that slot, the new boon starts at level 2 (free +1 per GDD slot-replacement rule).
var owned_slots: Dictionary = {
	"Y": "", "X": "", "A": "", "B": "", "Charge": "", "Ult": ""
}
# Run 44 — PER-CHARACTER slot ownership (Bruno's spec): each ninja can hold
# exactly ONE boon per slot (Y / X / A / B=Dash / Charge / Ult). Taking a
# different boon for an occupied slot TRADES OUT the old one (its effects are
# removed from that ninja); the replacement arrives at +1 level and was
# offered at +1 rarity (see _roll_offer_rarities). The legacy global
# owned_slots above stays as a record for attack-tint fallbacks/UI.
var owned_slots_by_char: Dictionary = {
	"shino": { "Y": "", "X": "", "A": "", "B": "", "Charge": "", "Ult": "" },
	"bea":   { "Y": "", "X": "", "A": "", "B": "", "Charge": "", "Ult": "" },
}

# Resolve a boon's slot from its explicit boon_slot field ONLY. (Do NOT fall
# back to BOON_ATTACK_SLOT — that map tags passives like static_charge "A" or
# heatwave "Y" for attack-tint purposes; treating those as slot boons would
# wrongly evict real slot picks.)
func get_slot_for_boon(boon_id: String) -> String:
	return BoonDBClass.get_slot_for_boon(boon_id)

# Boon levels (boon_id -> int, default 1). Level 2 = one free Pom applied.
var boon_levels: Dictionary = {}

# Run 26f — Bruno's follow-up: Legendary boons gated by family commitment.
# Player needs ≥3 boons of that family before a Legendary of that family
# can appear in an offer. Combined with the per-roll low-chance roll below,
# Legendaries become a build payoff rather than early-room RNG.
const LEGENDARY_FAMILY_PREREQ: int = 3
# Per-room chance a slot in the offer GETS to even attempt a Legendary roll.
# When 0, no Legendaries surface in normal rolls (door-pick can still force).
# Run 40 — Bruno: 5% (was 10%) once prereqs are met.
# Run 42 — base chances; Sensei Z can raise each by +2%/rank (5 ranks → 15% max).
# Corrupt chance is intentionally NOT Sensei-upgradable (stays family-investment-based).
const LEGENDARY_OFFER_CHANCE_PER_ROOM: float = 0.05
const DUO_OFFER_CHANCE_PER_ROOM:       float = 0.05
const SENSEI_SPECIAL_BONUS_PER_RANK:   float = 0.02

func get_legendary_offer_chance() -> float:
	return LEGENDARY_OFFER_CHANCE_PER_ROOM + SENSEI_SPECIAL_BONUS_PER_RANK * float(sensei_legendary_ranks)

func get_duo_offer_chance() -> float:
	return DUO_OFFER_CHANCE_PER_ROOM + SENSEI_SPECIAL_BONUS_PER_RANK * float(sensei_duo_ranks)

# Run 26f — Attack-slot tagging. Boons explicitly tied to the Y/X/A buttons
# get a string here; all other "attack-affecting" boons are flagged generically
# as "ALL" so the offer guarantee (≥1 attack boon per family room) has enough
# candidates. Tagging is OPTIMISTIC — when in doubt, lean ALL so the player
# always gets the choice. Untagged boons are treated as utility.
const BOON_ATTACK_SLOT = BoonDBClass.BOON_ATTACK_SLOT

func is_attack_boon(boon_id: String) -> bool:
	return BoonDBClass.is_attack_boon(boon_id)

# ============================================================
# Run 44 — EFFECT-PREREQ GATING (Bruno's spec, this session):
# "Any boon that requires an effect to happen, or improves on an effect,
# only appears if you have at least 1 boon that APPLIES the effect."
# Tighter than prereq_family — previously any Pepper boon (even Hot-Footed,
# which burns nothing) unlocked Combust/Slow Cook/Blazing Aura.
# Pool entries opt in via "requires_effect": "<tag>". Ownership is checked
# TEAM-WIDE (statuses applied by either ninja feed the other's scalers —
# Rising Tide amps damage from all sources, Combust detonates anyone's Burn).
# Enforced strictly: the relaxed family-room fill does NOT bypass it.
# ============================================================
const EFFECT_APPLIERS = BoonDBClass.EFFECT_APPLIERS

# Run 136 (Bruno's spec): gating is PER-NINJA when the picker is known.
# Bea's Hardshell Roll must NOT unlock Shellburst on SHINO's offer — each
# ninja needs their OWN applier before that ninja sees effect-scalers.
# who == "" falls back to team-wide (legacy roll_offer / duo checks).
func _has_effect_applier(effect: String, who: String = "") -> bool:
	for id in EFFECT_APPLIERS.get(effect, []):
		if who == "shino":
			if id in shino_boon_set:
				return true
		elif who == "bea":
			if id in bea_boon_set:
				return true
		elif boons_taken.has(id) or id in shino_boon_set or id in bea_boon_set:
			return true
	return false

# --- Family colors (centralized) --- [moved to BoonDB, Phase-2 B1]
const FAM_COLOR = BoonDBClass.FAM_COLOR

# Rarity color/label + rarity roll tables — moved to BoonDB (Phase-2 B1)
const RARITY_COLOR = BoonDBClass.RARITY_COLOR
const RARITY_LABEL = BoonDBClass.RARITY_LABEL

# ============================================================
# Run 40 — ROLLED RARITY (Hades-style), Bruno's spec 2026-06-10.
# Rarity is no longer a fixed identity on the BOON_POOL entry.
# Every boon that isn't Legendary or Corrupt is COMMON by base;
# each time it appears on an offer card it rolls a rarity:
#   epic 10%  /  rare 20%  /  uncommon 30%  /  common 40%
# (single roll against cumulative weights — tweak the three
# constants below; they must sum to <= 1.0).
# The rolled rarity is locked in when the boon is taken and
# scales the boon's effect via RARITY_EFFECT_MULT.
# The legacy "rarity" field on BOON_POOL entries is now ONLY
# meaningful for "legendary" / "corrupt" — any other value is
# ignored (treated as common base). Numbers tuning pass later.
# ============================================================
const RARITY_CHANCE_EPIC = BoonDBClass.RARITY_CHANCE_EPIC
const RARITY_CHANCE_RARE = BoonDBClass.RARITY_CHANCE_RARE
const RARITY_CHANCE_UNCOMMON = BoonDBClass.RARITY_CHANCE_UNCOMMON

# Effect-bonus multiplier per rarity. Scales the BONUS portion of a
# boon's effect (e.g. +15% damage at common → +30% at epic), never the
# whole multiplier. Legendary/corrupt are fixed-tier: no rarity scaling.
const RARITY_EFFECT_MULT = BoonDBClass.RARITY_EFFECT_MULT

# Dragon Fruit per-level effect bonus, by the boon's rolled rarity.
# Rarer boons gain more per level (Hades Pom feel). Level 1 = base.
const RARITY_LEVEL_BONUS = BoonDBClass.RARITY_LEVEL_BONUS

# Rolled rarity for the CURRENT offer (boon_id -> rarity). Family-locked
# offers never repeat an id, so keying by id is safe. Rewritten on every
# roll_offer / roll_family_offer.
var current_offer_rarities: Dictionary = {}
# Rarity locked in when a boon was taken (boon_id -> rarity). Drives all
# effect scaling + HUD display. Persisted in save files.
var boon_rarities: Dictionary = {}


# Base rarity: legendary/corrupt/duo keep their fixed tier; everything else
# (including legacy "uncommon"/"rare" pool entries) is common.
func get_base_rarity(boon_id: String) -> String:
	return BoonDBClass.get_base_rarity(boon_id)


# Run 41 — Sensei Z "Dragon's Fortune": each rank pushes EVERY upgrade
# chance up by +5% (so rank 5 = epic 35% / rare 45% / uncommon 55%-capped).
# Higher tiers eat the roll space from the bottom up: at max rank common
# disappears entirely and uncommon shrinks to the leftover 20%.
const SENSEI_RARITY_BONUS_PER_RANK: float = 0.05

func get_rarity_chance_bonus() -> float:
	return SENSEI_RARITY_BONUS_PER_RANK * float(sensei_rarity_ranks)


# One rarity roll: base epic 10% / rare 20% / uncommon 30% / common 40%,
# each chance shifted up by the Dragon's Fortune bonus.
func roll_rarity() -> String:
	var bonus: float = get_rarity_chance_bonus()
	var c_epic: float = RARITY_CHANCE_EPIC + bonus
	var c_rare: float = RARITY_CHANCE_RARE + bonus
	var c_unc:  float = RARITY_CHANCE_UNCOMMON + bonus
	var r: float = randf()
	if r < c_epic:
		return "epic"
	if r < c_epic + c_rare:
		return "rare"
	if r < c_epic + c_rare + c_unc:
		return "uncommon"
	return "common"


# Roll the on-card rarity for one offer slot (fixed tiers pass through).
func roll_offer_rarity_for(boon_id: String) -> String:
	var base: String = get_base_rarity(boon_id)
	if base != "common":
		return base
	return roll_rarity()


# Rarity shown on the current offer card for this boon.
func get_offer_rarity(boon_id: String) -> String:
	return String(current_offer_rarities.get(boon_id, get_base_rarity(boon_id)))


# Rarity the boon was TAKEN at (falls back to base for legacy saves).
func get_boon_rarity(boon_id: String) -> String:
	return String(boon_rarities.get(boon_id, get_base_rarity(boon_id)))


func get_boon_rarity_mult(boon_id: String) -> float:
	return float(RARITY_EFFECT_MULT.get(get_boon_rarity(boon_id), 1.0))


# Combined effect-bonus multiplier: rarity x Dragon Fruit levels.
# Callers scale the BONUS portion: 1.0 + base_bonus * get_boon_effect_mult(id).
func get_boon_effect_mult(boon_id: String) -> float:
	return get_boon_rarity_mult(boon_id) * get_boon_level_mult(boon_id)


# Run 44 — slot trade-up: rarity ladder bump (fixed tiers never bump).
const _RARITY_LADDER = BoonDBClass._RARITY_LADDER
func bump_rarity(r: String) -> String:
	return BoonDBClass.bump_rarity(r)


# True if taking `boon_id` would replace a DIFFERENT boon in `who`'s slot.
func is_slot_replacement_for(who: String, boon_id: String) -> bool:
	var slot: String = get_slot_for_boon(boon_id)
	if slot == "" or who == "":
		return false
	var cur: String = String(owned_slots_by_char.get(who, {}).get(slot, ""))
	return cur != "" and cur != boon_id


# Fill current_offer_rarities for a finalized picked array.
# Run 44 — pass the picker: slot-replacement cards are found at +1 rarity
# (Hades-style trade incentive, Bruno's spec).
func _roll_offer_rarities(picked: Array, who: String = "") -> void:
	current_offer_rarities.clear()
	for id in picked:
		current_offer_rarities[id] = roll_offer_rarity_for(id)
		if is_slot_replacement_for(who, String(id)):
			current_offer_rarities[id] = bump_rarity(String(current_offer_rarities[id]))
			print("[RunState] Slot trade-up: %s offered at +1 rarity (%s)" % [id, current_offer_rarities[id]])
		if current_offer_rarities[id] != get_base_rarity(id):
			print("[RunState] Offer rarity roll: %s → %s" % [id, current_offer_rarities[id]])

# ============================================================
# BOON_POOL — Run 16 reconciliation. Each entry:
#   family, name, desc, color, rarity, stackable, family_dd (opt)
# All colors pulled from FAM_COLOR; cards render rarity border separately.
# ============================================================
const BOON_POOL = BoonDBClass.BOON_POOL


# ============================================================
# ELEMENTAL SYNERGY DEFS (Run 19) — automatic cross-status reactions
# (Combat_Boons §11/§8.11). NOT duo boons — separate system.
#
# Synergies activate automatically when boons from two families coexist
# in a build. Trigger on enemy STATUS combinations (Wet+Lightning, Burn+Wet
# Steam Burst, Burn+Frozen Thaw Burst, etc.). Never consume stacks
# (additive-only design rule per spec).
#
# This run wires 3 representative synergies as template:
#   • wet_lightning  — Watermelon × Banana   (water mode)
#   • steam_burst    — Pepper × Watermelon   (water mode)
#   • thaw_burst     — Pepper × Watermelon   (gelato mode)
#
# Each entry:
#   name             — display name
#   desc             — short tooltip
#   required_any     — Array of family names with >=1 boon owned each
#   mode_required    — optional: "water" or "gelato" (Watermelon mode gate)
#   color            — surfacing color (UI indicator chip)
# ============================================================
const SYNERGY_DEFS = BoonDBClass.SYNERGY_DEFS

# ============================================================
# DUO_DEFS (Run 19) — family-pairing boon synergies (Combat_Boons §5).
# Trigger when ANY boon from BOTH families is owned. 45 entries spec'd
# total; this run wires 3 as template:
#
#   • iron_core    — Apple + Broccoli     (the canonical user example)
#   • aimed_guard  — Carrot + Coconut     (crit → overshield, 2s ICD)
#   • shell_cluster — Coconut + Grape     (overshield mirror-share)
#
# Each entry:
#   name           — display name (per spec)
#   desc           — spec-literal tooltip
#   required_any   — Array of family names with >=1 boon owned each
#   color          — UI surfacing color (mixed of family colors)
# ============================================================
const DUO_DEFS = BoonDBClass.DUO_DEFS


# ---------------------------------------------------------------------------
# Lifecycle helpers
# ---------------------------------------------------------------------------

func reset_run() -> void:
	shino_boon_set.clear()
	bea_boon_set.clear()
	# Run 60 — combo mirrors zero out at run start.
	combo_shino          = 0
	combo_bea            = 0
	# Run 61 — high-water tier mark resets to the current Settings-chosen tier
	# (the floor for the new run); subsequent mid-run swap-ups bump it.
	highest_ai_tier_used_this_run = ai_helper_tier
	dojo_sandbox_used    = false   # Run 39 — dispenser sandbox flag
	_karma_banked_this_run = false # Run 117 — next run can bank karma again
	max_hp_bonus_pct     = 0.0
	apple_pie_stacks     = 0
	apple_juice_consumed_count = 0
	# dragon_souls intentionally NOT reset here — it's meta currency (like
	# sensei_* fields) that persists across runs. Reset it only in
	# create_new_slot() for brand-new files.
	damage_mult          = 1.0
	damage_taken_mult    = 1.0
	move_speed_mult      = 1.0
	attack_speed_mult    = 1.0
	max_chi_bonus        = 0
	charge_kill_heal_pct = 0.0
	melee_lifesteal_pct  = 0.0
	baked_apple_taken    = false   # Run 26d — Baked Apple finisher-HoT flag
	crit_chance          = 0.0
	crit_damage_bonus    = 0.0
	heal_amp_mult        = 1.0
	full_bloom_taken     = false
	heavy_stalk_taken    = false
	bash_on_hit_chance   = 0.0
	bash_bonus_damage    = 0
	shell_breaker_chance = 0.0
	overshield_grant_on_dash = 0
	overshield_max       = 0
	overshield_grant_on_dash_by = {"shino": 0, "bea": 0}   # Run 150b
	overshield_max_by           = {"shino": 0, "bea": 0}   # Run 150b
	stockpile_taken      = false
	nutshell_taken       = false
	hard_landing_taken   = false
	tough_hide_taken_count = 0
	chip_proof_taken     = false
	tough_cookie_taken   = false
	battle_shell_taken   = false
	combo_master_taken   = false
	noble_rot_taken      = false
	bunch_bonus_taken    = false
	cluster_mastery_taken = false
	cluster_cascade_taken = false
	ripened_core_taken     = false
	heart_of_orchard_taken = false
	sweet_dreams_taken     = false
	grannys_recipe_taken   = false
	apple_hour_taken       = false
	green_rage_taken     = false
	combat_fury_taken    = false
	combat_fury_pct_per_tier = 0.0
	iron_will_taken      = false
	crushing_blow_taken  = false
	bash_big_ones_taken  = false
	big_broccoli_taken   = false
	hawkeye_taken        = false
	golden_carrot_taken  = false
	golden_carrot_streak = 0
	critical_mass_taken  = false
	opening_strike_taken = false
	finishers_aim_taken  = false
	keen_eye_taken        = false
	sharpened_tip_taken   = false
	bullseye_taken        = false
	flanking_strike_taken = false
	_flanking_window      = 0.0
	force_next_crit             = false
	finisher_crit_chance_bonus  = 0.0
	# Apple slots
	heavy_harvest_taken   = false
	seeded_shot_taken     = false
	evergreen_step_taken  = false
	sweet_harvest_taken   = false
	# Coconut slots
	coconut_volley_taken  = false
	coco_slam_taken       = false
	# Broccoli slots
	brute_force_taken     = false
	slugshot_taken        = false
	bull_rush_taken       = false
	fury_release_taken    = false
	# Grape slots
	cluster_strike_taken  = false
	overhead_crush_taken  = false
	grape_shot_taken      = false
	vine_lash_taken       = false
	bunch_burst_taken     = false
	# Watermelon slots (B + Charge)
	hydro_slide_taken     = false
	flood_charge_taken    = false
	# Pepper slots (A/B/Charge)
	fireball_taken        = false
	fire_trail_taken      = false
	inferno_charge_taken  = false
	# Potato slots
	spud_stomp_taken      = false
	rock_smash_taken      = false
	stone_throw_taken     = false
	tuber_burrow_taken    = false
	quake_charge_taken    = false
	# Banana slots
	peel_slap_taken       = false
	voltaic_strike_taken  = false
	bananarang_taken      = false
	zip_dash_taken        = false
	storm_charge_taken    = false
	# Onion slots
	pungent_jab_taken     = false
	tear_strike_taken     = false
	stink_bomb_taken      = false
	gas_bookends_taken    = false
	reek_charge_taken     = false
	rising_tide_taken    = false
	hydration_taken      = false
	tidal_refresh_taken  = false
	tide_master_taken    = false
	melon_gelato_mode    = false
	hydro_jab_taken      = false
	heavy_tide_taken     = false
	bubble_shot_taken    = false
	spicy_jab_taken      = false
	searing_strike_taken    = false
	fire_damage_mult        = 1.0
	lightning_damage_mult   = 1.0
	slow_cook_taken      = false
	blazing_aura_taken   = false
	pyromania_taken      = false
	hot_footed_taken     = false
	combust_taken        = false
	starch_armor_taken   = false
	spineback_taken      = false
	heavy_stance_taken   = false
	tremor_walk_taken    = false
	tailwind_taken       = false
	tailwind_pct         = 0.0
	peel_out_taken       = false
	extra_banana_taken   = false
	greased_lightning_mode = false
	layered_defense_taken = false
	rotten_core_taken    = false
	chronic_reek_taken   = false
	fermented_strength_taken = false
	overripe_taken       = false
	poison_max_stacks_bonus = 0
	# Run 19 — Legendaries + Corrupts.
	juicebox_of_youth_taken = false
	adamantium_husk_taken   = false
	tidal_tsunami_taken     = false
	inferno_crown_taken     = false
	eagle_eye_taken         = false
	sniper_focus_taken          = false
	sniper_focus_crit_streak    = {"shino": 0, "bea": 0}
	sniper_focus_bonus_timer    = {"shino": 0.0, "bea": 0.0}
	slip_stream_taken           = false
	voltaic_engine_taken    = false
	hulk_smash_taken        = false
	corrupt_boons_taken     = 0
	corrupt_accepted        = false
	corrupt_apple_taken      = false
	corrupt_coconut_taken    = false
	corrupt_broccoli_taken   = false
	corrupt_carrot_taken     = false
	corrupt_grape_taken      = false
	corrupt_pepper_taken     = false
	corrupt_watermelon_taken = false
	watermelon_surge_active  = false
	watermelon_tide_active   = false
	corrupt_potato_taken     = false
	corrupt_banana_taken     = false
	corrupt_onion_taken      = false
	shino_dd_charges = 0;  shino_dd_payloads.clear()
	bea_dd_charges   = 0;  bea_dd_payloads.clear()
	_last_downed_char = ""
	family_dd_taken   = false
	arenas_cleared       = 0
	loops_completed      = 0
	broccoli_boons_taken = 0
	apple_boons_taken    = 0
	coconut_boons_taken  = 0
	carrot_boons_taken   = 0
	grape_boons_taken    = 0
	watermelon_boons_taken = 0
	pepper_boons_taken   = 0
	potato_boons_taken   = 0
	banana_boons_taken   = 0
	onion_boons_taken    = 0
	carry_hp             = -1
	carry_chi            = -1
	bea_carry_hp         = -1
	bea_carry_chi        = -1
	carry_player_controlled_char = -1
	resume_scene_path    = ""
	boons_taken.clear()
	current_offer.clear()
	pending_reward = {}
	ult_freeze_caster = ""      # Run 150 — never let a stale ult freeze leak
	double_ult_queued = false
	owned_slots = { "Y": "", "X": "", "A": "", "B": "", "Charge": "", "Ult": "" }
	owned_slots_by_char = {
		"shino": { "Y": "", "X": "", "A": "", "B": "", "Charge": "", "Ult": "" },
		"bea":   { "Y": "", "X": "", "A": "", "B": "", "Charge": "", "Ult": "" },
	}   # Run 44 — per-character slot exclusivity
	boon_levels.clear()
	boon_rarities.clear()            # Run 40 — rolled rarities
	current_offer_rarities.clear()
	duos_taken.clear()               # Run 41 — duos are picked cards now
	# Run 43 — Dream World state.
	dream_world_mode = false
	current_biome    = ""
	biome_room       = 1
	peak_room_type   = "open"
	for _bk in biomes_cleared.keys():
		biomes_cleared[_bk] = false
	gauntlet_cleared = false
	run_coins        = 0
	shop_spark_bought = false   # Run 45 — shop spark re-rollable each run
	rerolls_left     = 0        # Run 46 — refilled by _apply_sensei_upgrades
	# Apply Sensei Z permanent upgrades as run-start bonuses (DD charges, DR, etc.)
	_apply_sensei_upgrades()
	print("[RunState] Run reset.")


# ---------------------------------------------------------------------------
# Offer generation — picks 3 random boons.
# ---------------------------------------------------------------------------
func roll_offer() -> Array:
	var available: Array = []
	for id in BOON_POOL.keys():
		var b: Dictionary = BOON_POOL[id]
		if not _is_boon_eligible(id, b):
			continue
		available.append(id)
	available.shuffle()
	current_offer = available.slice(0, min(3, available.size()))
	_roll_offer_rarities(current_offer)   # Run 40 — per-card rarity roll
	return current_offer


# Run 26c — Per-family eligibility check, factored out so roll_offer and the
# new family-locked roller (roll_family_offer) share it. Returns true if the
# boon ID can be offered right now:
#   - not already taken (for non-stackable boons)
#   - not a family DD when the player already has one
#   - prereq_family count (if defined on the entry) is satisfied
func _is_boon_eligible(id: String, b: Dictionary, who: String = "") -> bool:
	# Corrupt boons are never eligible through the normal pool — they're injected
	# by _maybe_inject_corrupt() with probability gating after the offer is built.
	if String(b.get("rarity", "")) == "corrupt":
		return false
	# Run 26f — Legendary prereq (Bruno's follow-up): Legendaries only appear
	# after the player has taken ≥3 boons from that family. Without this gate,
	# Legendaries can drop in the first room before the family identity exists,
	# which makes them feel like loot rather than build payoff.
	if String(b.get("rarity", "")) == "legendary":
		var leg_fam: String = String(b.get("family", ""))
		# Run 136 — the PICKER's own family count gates their legendary.
		if _family_count_for(leg_fam, who) < LEGENDARY_FAMILY_PREREQ:
			return false
	# Per-character boon individuality (Run 29+): if a picker is known, check
	# THAT character's set. This lets Bea pick boons Shino already took.
	# Fall back to global boons_taken when no picker is specified.
	if not b.get("stackable", false):
		if who == "shino":
			if id in shino_boon_set:
				return false
		elif who == "bea":
			if id in bea_boon_set:
				return false
		elif boons_taken.has(id):
			return false
	if family_dd_taken and b.get("family_dd", false):
		return false
	# Prereq gating (Run 26c, Bruno's "Pepper scalers / mode switches require
	# at least one same-family boon first" rule). Look up `prereq_family` on
	# the entry; if set, require >=1 boon of that family already taken.
	var prereq_fam: String = String(b.get("prereq_family", ""))
	if prereq_fam != "":
		var fam_count: int = _family_count_for(prereq_fam, who)   # Run 136 — per-picker
		if fam_count < 1:
			return false
	# Run 44 — effect-prereq (Bruno): boons that scale/improve an effect need
	# a live APPLIER of that effect in the team build first. Strict — no
	# relaxed-pass bypass (see roll_family_offer pass 2).
	var req_eff: String = String(b.get("requires_effect", ""))
	if req_eff != "" and not _has_effect_applier(req_eff, who):   # Run 136 — per-picker
		return false
	return true


func _get_family_count(fam_name: String) -> int:
	match fam_name:
		"Apple":      return apple_boons_taken
		"Coconut":    return coconut_boons_taken
		"Broccoli":   return broccoli_boons_taken
		"Carrot":     return carrot_boons_taken
		"Grape":      return grape_boons_taken
		"Watermelon": return watermelon_boons_taken
		"Pepper":     return pepper_boons_taken
		"Potato":     return potato_boons_taken
		"Banana":     return banana_boons_taken
		"Onion":      return onion_boons_taken
		"Corrupt":    return corrupt_boons_taken
	return 0


# Run 136 — per-ninja family count when the picker is known (offer gating:
# legendary prereq, prereq_family, corrupt chance). Team-wide when who == "".
func _family_count_for(fam_name: String, who: String = "") -> int:
	if who == "shino" or who == "bea":
		return char_family_count(who, fam_name)
	return _get_family_count(fam_name)


# Run 26c / 26d — Family-locked offer roll for the Hades "this is a Grape room"
# UX. Filters BOON_POOL to entries whose family matches `family_cap` (a
# capitalized family name like "Pepper").
#
# Run 26d: STRICT family lock. Bruno saw wrong-family boons leaking into
# rooms whose locked family couldn't field 3 entries (e.g. a Pepper room
# with 0 Pepper boons taken has only 2 unprereqed Pepper picks). The old
# fallback to other_pool leaked Apple/Grape/etc. into Pepper rooms. New
# behavior: if family supplies <3, RELAX the prereq filter to fill from
# the SAME family before ever touching other families. If still <3, return
# whatever the family can field (1 or 2 cards is fine — Hades-style).
#
# Returns the offer Array (mirrors roll_offer's contract). Also writes
# current_offer so BoonOffer can read it back.
func roll_family_offer(family_cap: String, who: String = "") -> Array:
	var family_pool: Array = []
	# Pass 1 — fully eligible boons in this family (passes prereqs).
	# `who` ("shino" | "bea") filters non-stackables against THAT character's
	# boon set so each ninja can independently pick boons the other already owns.
	for id in BOON_POOL.keys():
		var b: Dictionary = BOON_POOL[id]
		if String(b.get("family", "")) != family_cap:
			continue
		if not _is_boon_eligible(id, b, who):
			continue
		family_pool.append(id)
	family_pool.shuffle()
	var picked: Array = family_pool.slice(0, min(3, family_pool.size()))
	# Pass 2 — if we need more, relax the prereq check (still same family).
	# This handles the chicken-and-egg case: very first Pepper room has 0
	# Pepper boons, so prereq-gated scalers can't offer; without this fill,
	# the player gets only 1-2 cards and may never seed the family. Picking
	# a prereq-gated boon as the seed is still valid — its effect activates
	# immediately on apply_boon and pepper_boons_taken goes 0→1.
	if picked.size() < 3:
		var relaxed_pool: Array = []
		for id in BOON_POOL.keys():
			var b: Dictionary = BOON_POOL[id]
			if String(b.get("family", "")) != family_cap:
				continue
			# Skip what we already grabbed and the truly-unpickable filters
			# (already-taken non-stackables per-character, locked DD).
			if picked.has(id):
				continue
			if not b.get("stackable", false):
				if who == "shino" and id in shino_boon_set:
					continue
				elif who == "bea" and id in bea_boon_set:
					continue
				elif who == "" and boons_taken.has(id):
					continue
			if family_dd_taken and b.get("family_dd", false):
				continue
			# Legendaries still respect the 3-family prereq even on the relaxed
			# fallback pass — they're not a "seed" entry.
			if String(b.get("rarity", "")) == "legendary":
				if _family_count_for(family_cap, who) < LEGENDARY_FAMILY_PREREQ:
					continue
			# Corrupt boons are never seed entries — _maybe_inject_corrupt handles
			# them with proper probability gating after the pool is built.
			if String(b.get("rarity", "")) == "corrupt":
				continue
			# Run 44 — effect-prereq is STRICT: the relaxed family fill may skip
			# the family-count prereq (seeding), but never offers an effect-scaler
			# with zero appliers of that effect in the build.
			var relax_eff: String = String(b.get("requires_effect", ""))
			if relax_eff != "" and not _has_effect_applier(relax_eff, who):   # Run 136
				continue
			relaxed_pool.append(id)
		relaxed_pool.shuffle()
		while picked.size() < 3 and not relaxed_pool.is_empty():
			picked.append(relaxed_pool.pop_front())

	# Run 26f — Attack-slot guarantee. Ensure ≥1 picked boon is "attack-affecting"
	# (Y / X / A or ALL slot tag) so the player always has a path to enhance
	# their kit. Skips silently if the family genuinely has no attack candidates
	# eligible right now — fewer-card offers are acceptable.
	_ensure_attack_slot_in_offer(picked, family_cap, who)

	# Run 41 — Special (Legendary OR Duo) low-chance gate: one 5% roll per
	# room across all eligible specials for this family. Most rolls fail and
	# nothing changes.
	_maybe_inject_special(picked, family_cap, who)
	_maybe_inject_corrupt(picked, family_cap, who)

	# Final pool size may still be <3 if the family is genuinely exhausted
	# (every entry taken). That's fine — show fewer cards rather than leak.
	# Run 40 — roll each card's rarity LAST (after legendary/corrupt swaps)
	# so fixed-tier injections pass through and normal cards get the
	# common→uncommon→rare→epic roll. Run 44 — `who` enables the slot
	# trade-up +1 rarity bump.
	_roll_offer_rarities(picked, who)
	current_offer = picked
	return current_offer


# Run 26f — Ensure at least one attack-slot boon is in the picked offer. If
# none are attack-affecting AND the family has at least one attack candidate
# we haven't picked, swap the LAST picked card (so we preserve earlier picks
# in their original randomized order) for an attack candidate.
func _ensure_attack_slot_in_offer(picked: Array, family_cap: String, who: String = "") -> void:
	if picked.is_empty():
		return
	# Priority 1: ensure a slot boon (Y/X/A/B/Charge) appears — these are the
	# effect-applying boons the player needs as entry points. Without them,
	# scalers like Rising Tide or Blazing Aura offer nothing useful.
	var has_slot_boon: bool = false
	for id in picked:
		var b: Dictionary = BOON_POOL.get(id, {})
		if String(b.get("boon_slot", "")) != "":
			has_slot_boon = true
			break
	if not has_slot_boon:
		# Try to inject a slot boon into the last card slot.
		var slot_pool: Array = []
		for id in BOON_POOL.keys():
			if picked.has(id):
				continue
			var b: Dictionary = BOON_POOL[id]
			if String(b.get("family", "")) != family_cap:
				continue
			if String(b.get("boon_slot", "")) == "":
				continue
			if not _is_boon_eligible(id, b, who):
				continue
			slot_pool.append(id)
		if not slot_pool.is_empty():
			slot_pool.shuffle()
			picked[picked.size() - 1] = slot_pool[0]
			return   # slot injected; attack-boon check below becomes redundant

	# Priority 2 (fallback): ensure at least one "attack-affecting" boon.
	var has_attack: bool = false
	for id in picked:
		if is_attack_boon(id):
			has_attack = true
			break
	if has_attack:
		return
	var attack_pool: Array = []
	for id in BOON_POOL.keys():
		if not BOON_ATTACK_SLOT.has(id):
			continue
		if picked.has(id):
			continue
		var b: Dictionary = BOON_POOL[id]
		if String(b.get("family", "")) != family_cap:
			continue
		if not _is_boon_eligible(id, b, who):
			continue
		attack_pool.append(id)
	if attack_pool.is_empty():
		return
	attack_pool.shuffle()
	picked[picked.size() - 1] = attack_pool[0]


# Run 26f — Low-chance Legendary injection per room. Only fires when the player
# Returns the id of an eligible untaken Legendary for the given family,
# or "" if none is available. Used by _maybe_inject_special.
func pick_legendary_for_family(family_name: String, who: String = "") -> String:
	var candidates: Array = []
	for id in BOON_POOL.keys():
		var b: Dictionary = BOON_POOL[id]
		if String(b.get("rarity", "")) != "legendary":
			continue
		if String(b.get("family", "")) != family_name:
			continue
		# Run 136 — per-picker taken check (each ninja can own their copy).
		if not b.get("stackable", false):
			if who == "shino":
				if id in shino_boon_set:
					continue
			elif who == "bea":
				if id in bea_boon_set:
					continue
			elif boons_taken.has(id):
				continue
		# Run 44 — effect-prereq applies to Legendaries too (Inferno Crown
		# without a single Burn applier is a dead card). Run 136 — per-picker.
		var leg_eff: String = String(b.get("requires_effect", ""))
		if leg_eff != "" and not _has_effect_applier(leg_eff, who):
			continue
		candidates.append(id)
	if candidates.is_empty():
		return ""
	return candidates[randi() % candidates.size()]


# has the family commitment AND the room's family has an eligible candidate.
# Run 41 (Bruno): ONE 5% roll per room covers Legendary OR Duo — if it hits,
# pick randomly among all eligible specials for this family:
#   • Legendaries — family count ≥ LEGENDARY_FAMILY_PREREQ (3), untaken.
#   • Duos — pairing involves this family, ≥2 boons from EACH family,
#     effect prereq met (is_duo_offerable), untaken.
# Duo entries go into the offer as "duo:<duo_id>" (DUO_OFFER_PREFIX).
func _maybe_inject_special(picked: Array, family_cap: String, who: String = "") -> void:
	if picked.is_empty():
		return
	# Skip if a special is already in the offer (door-forced legendary, etc.)
	for id in picked:
		if String(id).begins_with(DUO_OFFER_PREFIX):
			return
		if String(BOON_POOL.get(id, {}).get("rarity", "")) == "legendary":
			return
	# Run 42 — Legendary and Duo roll INDEPENDENTLY (each chance is separately
	# Sensei-upgradable: Legend Seeker / Twin Spirits, +2%/rank, 5%→15%).
	# Rolls only happen when a candidate actually exists. If both hit, 50/50.
	var leg_candidate: String = ""
	if _family_count_for(family_cap, who) >= LEGENDARY_FAMILY_PREREQ:   # Run 136 — per-picker
		var leg_id: String = pick_legendary_for_family(family_cap, who)
		if leg_id != "" and not picked.has(leg_id):
			leg_candidate = leg_id
	var duo_candidates: Array = []
	for duo_id in get_offerable_duos_for_family(family_cap, who):   # Run 139 — per-picker
		duo_candidates.append(DUO_OFFER_PREFIX + String(duo_id))

	var leg_hit: bool = leg_candidate != "" and randf() < get_legendary_offer_chance()
	var duo_hit: bool = not duo_candidates.is_empty() and randf() < get_duo_offer_chance()
	var special: String = ""
	if leg_hit and duo_hit:
		special = leg_candidate if randf() < 0.5 else String(duo_candidates[randi() % duo_candidates.size()])
	elif leg_hit:
		special = leg_candidate
	elif duo_hit:
		special = String(duo_candidates[randi() % duo_candidates.size()])
	if special == "":
		return
	# Replace the LAST picked card. Same rationale as _ensure_attack_slot_in_offer.
	picked[picked.size() - 1] = special
	print("[RunState] Special injected into %s room offer: %s" % [family_cap, special])


# Corrupt boon injection — called after _maybe_inject_special in roll_family_offer.
# GDD §6.1: 5% per family boon owned, one-per-run hard cap once any corrupt is accepted.
# Only the specific corrupt for this family can appear (one corrupt per family).
func _maybe_inject_corrupt(picked: Array, family_cap: String, who: String = "") -> void:
	if picked.is_empty():
		return
	# Hard cap: once ANY corrupt has been accepted this run, no more corrupt offers.
	if corrupt_accepted:
		return
	# Need ≥1 boon of this family to even see a corrupt. Run 136 — the PICKER's count.
	var fam_count: int = _family_count_for(family_cap, who)
	if fam_count < 1:
		return
	# Skip if a corrupt is already in the offer.
	for id in picked:
		if BOON_POOL.get(id, {}).get("rarity", "") == "corrupt":
			return
	# Run 41 — don't stomp a just-injected special (legendary/duo) in the
	# last slot; corrupt simply doesn't appear this room.
	var last_id: String = String(picked[picked.size() - 1])
	if last_id.begins_with(DUO_OFFER_PREFIX) \
	or String(BOON_POOL.get(last_id, {}).get("rarity", "")) == "legendary":
		return
	# Roll: 5% per boon owned in this family (cap ~25% at 5 boons).
	var chance: float = min(0.25, fam_count * 0.05)
	if randf() >= chance:
		return
	# Find the corrupt for this family.
	var corrupt_id: String = _pick_corrupt_for_family(family_cap)
	if corrupt_id == "" or picked.has(corrupt_id):
		return
	# Replace the last picked card.
	picked[picked.size() - 1] = corrupt_id
	print("[RunState] Corrupt injected into %s room offer: %s" % [family_cap, corrupt_id])


func _pick_corrupt_for_family(fam_name: String) -> String:
	for id in BOON_POOL.keys():
		var b: Dictionary = BOON_POOL[id]
		if b.get("rarity", "") != "corrupt":
			continue
		if b.get("family", "") != fam_name:
			continue
		if not b.get("stackable", false) and boons_taken.has(id):
			continue
		return id
	return ""


# ---------------------------------------------------------------------------
# Apply a chosen boon.
# ---------------------------------------------------------------------------
func apply_boon(boon_id: String, rarity_override: String = "") -> void:
	if not BOON_POOL.has(boon_id):
		push_warning("[RunState] Unknown boon: %s" % boon_id)
		return
	boons_taken.append(boon_id)
	var b: Dictionary = BOON_POOL[boon_id]
	# Run 40 — rarity comes from the OFFER ROLL (current_offer_rarities), not
	# the pool entry. Explicit override wins (Dojo dispenser, debug grants);
	# fixed tiers (legendary/corrupt) pass through get_base_rarity.
	var rarity: String = rarity_override
	if rarity == "":
		rarity = String(current_offer_rarities.get(boon_id, get_base_rarity(boon_id)))
	boon_rarities[boon_id] = rarity
	# Rarity effect-bonus multiplier for apply-time numerics below.
	var rmult: float = float(RARITY_EFFECT_MULT.get(rarity, 1.0))
	print("[RunState] Boon taken: %s [%s] — %s" % [b.get("name", boon_id), rarity, b.get("desc", "")])

	match boon_id:
		# --- Apple ---
		# --- Apple slot boons ---
		"heavy_harvest":
			heavy_harvest_taken = true
		"seeded_shot":
			seeded_shot_taken = true
		"evergreen_step":
			evergreen_step_taken = true
		"sweet_harvest":
			sweet_harvest_taken = true
		"orchard_bloom":
			max_hp_bonus_pct += 0.20 * rmult   # Run 40 — rarity-scaled
		"full_bloom_apple", "full_bloom":
			full_bloom_taken = true
		"ripened_core":
			ripened_core_taken = true
		"sweet_dreams":
			sweet_dreams_taken = true
		"grannys_recipe":
			grannys_recipe_taken = true
			heal_amp_mult *= (1.0 + 0.30 * rmult)   # Run 40 — rarity-scaled
		"apple_hour":
			apple_hour_taken = true   # Run 150b — RETIRED (def removed); arm kept for old saves
		"fall_harvest":
			charge_kill_heal_pct = max(charge_kill_heal_pct, 0.01 * rmult)   # Run 40
		"baked_apple":
			# Run 26d — Reworked from global 10% lifesteal to a finisher-only HoT
			# (5s of 1 HP/sec). Player.gd's finisher branch triggers it; the per-
			# frame tick lives on Player.gd / BeaAI.gd respectively.
			baked_apple_taken = true
		"cider_mercy":
			# Per-character grant: BoonOffer calls grant_dd_to_char(picker, …) after apply_boon.
			# The apply_boon call just records the pool ID so grant_dd knows what payload to use.
			family_dd_taken = true
		"heart_of_the_orchard":
			heart_of_orchard_taken = true
		# --- Coconut slot boons ---
		"coconut_volley":
			coconut_volley_taken = true
		"coco_slam":
			coco_slam_taken = true
		# --- Coconut passives ---
		"tough_hide":
			damage_taken_mult *= (1.0 - 0.15 * rmult)   # Run 40 — rarity-scaled DR
			tough_hide_taken_count += 1
		"coconut_bash":
			bash_on_hit_chance = max(bash_on_hit_chance, min(1.0, 0.20 * rmult))   # Run 40
			bash_bonus_damage  = max(bash_bonus_damage, int(round(3.0 * rmult)))
		"shell_breaker":
			shell_breaker_chance = max(shell_breaker_chance, min(1.0, 0.30 * rmult))   # Run 40
		"overshield_dash":
			var grant: int = 1
			match rarity:
				"rare":      grant = 2
				"epic":      grant = 3
				"legendary": grant = 3
				_:           grant = 1
			overshield_grant_on_dash = max(overshield_grant_on_dash, grant)
			overshield_max = max(overshield_max, grant)
			# Run 150b — holder-only mirror.
			overshield_grant_on_dash_by[pending_picker] = max(int(overshield_grant_on_dash_by.get(pending_picker, 0)), grant)
			overshield_max_by[pending_picker] = max(int(overshield_max_by.get(pending_picker, 0)), grant)
		"nutshell":
			nutshell_taken = true
		"hard_landing":
			hard_landing_taken = true
		"chip_proof":
			chip_proof_taken = true
		"tough_cookie":
			tough_cookie_taken = true
		"battle_shell":
			battle_shell_taken = true
		"stockpile":
			stockpile_taken = true
			overshield_max += 1
			# Run 150b — holder-only mirror.
			overshield_max_by[pending_picker] = int(overshield_max_by.get(pending_picker, 0)) + 1
		"iron_husk":
			# Per-character grant via BoonOffer (grant_dd_to_char called after apply_boon).
			family_dd_taken = true
		# --- Broccoli slot boons ---
		"brute_force":
			brute_force_taken = true
		"slugshot":
			slugshot_taken = true
		"bull_rush":
			bull_rush_taken = true
		"fury_release":
			fury_release_taken = true
		# --- Broccoli passives ---
		"heavy_stalk":
			heavy_stalk_taken = true
			# attack_speed_mult now computed per-character via get_char_attack_speed_mult()
		"stalk_of_might":
			# broccoli_boons_taken counter incremented in tail block; recompute Stalk ramp via getter
			pass
		"green_rage":
			green_rage_taken = true
		"combat_fury":
			combat_fury_taken = true
			match rarity:
				"common":    combat_fury_pct_per_tier = 0.05
				"uncommon":  combat_fury_pct_per_tier = 0.06
				"rare":      combat_fury_pct_per_tier = 0.07
				"epic":      combat_fury_pct_per_tier = 0.08
				"legendary": combat_fury_pct_per_tier = 0.10
				_:           combat_fury_pct_per_tier = 0.05
		"iron_will":
			iron_will_taken = true
		"crushing_blow":
			crushing_blow_taken = true
		"bash_big_ones":
			bash_big_ones_taken = true
		"big_broccoli":
			big_broccoli_taken = true
		"green_vengeance":
			dd_charges_remaining = min(DD_CHARGE_HARD_CAP, dd_charges_remaining + 1)
			dd_payloads.append({"payload": "broccoli_green_vengeance", "rarity": rarity})
			family_dd_taken = true
		# --- Carrot ---
		# --- Carrot slot boons ---
		"keen_eye":
			keen_eye_taken = true
			crit_chance        = min(1.0, crit_chance + KEEN_EYE_CRIT_CHANCE * rmult)   # Run 40
			crit_damage_bonus += KEEN_EYE_CRIT_DMG * rmult
		"sharpened_tip":
			sharpened_tip_taken = true
			crit_chance        = min(1.0, crit_chance + SHARPENED_TIP_CRIT_CHANCE * rmult)
			crit_damage_bonus += SHARPENED_TIP_CRIT_DMG * rmult
		"bullseye":
			bullseye_taken = true
			crit_chance        = min(1.0, crit_chance + BULLSEYE_CRIT_CHANCE * rmult)
			crit_damage_bonus += BULLSEYE_CRIT_DMG * rmult
		"flanking_strike":
			flanking_strike_taken = true
		"hawkeye":
			hawkeye_taken = true
			crit_damage_bonus += 0.25 * rmult   # Run 40 — rarity-scaled
		"golden_carrot":
			golden_carrot_taken = true
			golden_carrot_streak = 0
		"critical_mass":
			critical_mass_taken = true
		"opening_strike":
			opening_strike_taken = true
		"finishers_aim":
			finishers_aim_taken = true
		"heart_shot":
			dd_charges_remaining = min(DD_CHARGE_HARD_CAP, dd_charges_remaining + 1)
			dd_payloads.append({"payload": "carrot_heart_shot", "rarity": rarity})
			family_dd_taken = true
		# --- Grape slot boons ---
		"cluster_strike":
			cluster_strike_taken = true
		"overhead_crush":
			overhead_crush_taken = true
		"grape_shot":
			grape_shot_taken = true
		"vine_lash":
			vine_lash_taken = true
		"bunch_burst":
			bunch_burst_taken = true
		# --- Grape passives ---
		"combo_master":
			combo_master_taken = true
		"noble_rot":
			noble_rot_taken = true
		"bunch_bonus":
			bunch_bonus_taken = true
		"cluster_mastery":
			cluster_mastery_taken = true
		"cluster_cascade":
			cluster_cascade_taken = true
		"vintage_surge":
			dd_charges_remaining = min(DD_CHARGE_HARD_CAP, dd_charges_remaining + 1)
			dd_payloads.append({"payload": "grape_vintage_surge", "rarity": rarity})
			family_dd_taken = true
		# --- Watermelon slot boons (B + Charge) ---
		"hydro_slide":
			hydro_slide_taken = true
		"flood_charge":
			flood_charge_taken = true
		# --- Watermelon passives ---
		"hydro_jab":
			hydro_jab_taken = true
		"heavy_tide":
			heavy_tide_taken = true
		"bubble_shot":
			bubble_shot_taken = true
		"rising_tide":
			rising_tide_taken = true
		"hydration":
			hydration_taken = true
		"tidal_refresh":
			tidal_refresh_taken = true
		"tide_master":
			tide_master_taken = true
		"melon_gelato":
			melon_gelato_mode = true
		"tide_pool":
			dd_charges_remaining = min(DD_CHARGE_HARD_CAP, dd_charges_remaining + 1)
			dd_payloads.append({"payload": "watermelon_tide_pool", "rarity": rarity})
			family_dd_taken = true
		# --- Pepper slot boons (A/B/Charge) ---
		"fireball":
			fireball_taken = true
		"fire_trail":
			fire_trail_taken = true
		"inferno_charge":
			inferno_charge_taken = true
		# --- Pepper sources + passives ---
		"spicy_jab":
			spicy_jab_taken = true
		"searing_strike":
			searing_strike_taken = true
		"slow_cook":
			slow_cook_taken = true
		"blazing_aura":
			blazing_aura_taken = true
		"pyromania":
			pyromania_taken = true
		"hot_footed":
			hot_footed_taken = true
		"combust":
			combust_taken = true
		"phoenix_pepper":
			dd_charges_remaining = min(DD_CHARGE_HARD_CAP, dd_charges_remaining + 1)
			dd_payloads.append({"payload": "pepper_phoenix", "rarity": rarity})
			family_dd_taken = true
		# --- Potato slot boons ---
		"spud_stomp":
			spud_stomp_taken = true
		"rock_smash":
			rock_smash_taken = true
		"stone_throw":
			stone_throw_taken = true
		"tuber_burrow":
			tuber_burrow_taken = true
		"quake_charge":
			quake_charge_taken = true
		# --- Potato passives ---
		"starch_armor":
			starch_armor_taken = true
			damage_taken_mult *= (1.0 - 0.10 * rmult)   # Run 40 — rarity-scaled DR
		"spineback":
			spineback_taken = true
		"heavy_stance":
			heavy_stance_taken = true
		"tremor_walk":
			tremor_walk_taken = true
		"stone_form":
			dd_charges_remaining = min(DD_CHARGE_HARD_CAP, dd_charges_remaining + 1)
			dd_payloads.append({"payload": "potato_stone_form", "rarity": rarity})
			family_dd_taken = true
		# --- Banana slot boons ---
		"peel_slap":
			peel_slap_taken = true
		"voltaic_strike":
			voltaic_strike_taken = true
		"bananarang":
			bananarang_taken = true
		"zip_dash":
			zip_dash_taken = true
			# MS bonus now computed per-character via get_char_move_speed_mult()
		"storm_charge":
			storm_charge_taken = true
		# --- Banana passives ---
		"tailwind":
			tailwind_taken = true
			var tw_pct: float = 0.05
			match rarity:
				"common":    tw_pct = 0.05
				"uncommon":  tw_pct = 0.06
				"rare":      tw_pct = 0.07
				"epic":      tw_pct = 0.08
				"legendary": tw_pct = 0.10
			tailwind_pct = max(tailwind_pct, tw_pct)
			# Tailwind MS/AS now computed per-character via get_char_move/attack_speed_mult()
		"peel_out":
			peel_out_taken = true
		"extra_banana":
			extra_banana_taken = true
		"greased_lightning":
			greased_lightning_mode = true
		"banana_splits":
			dd_charges_remaining = min(DD_CHARGE_HARD_CAP, dd_charges_remaining + 1)
			dd_payloads.append({"payload": "banana_splits", "rarity": rarity})
			family_dd_taken = true
		# --- Onion slot boons ---
		"pungent_jab":
			pungent_jab_taken = true
		"tear_strike":
			tear_strike_taken = true
		"stink_bomb":
			stink_bomb_taken = true
		"gas_bookends":
			gas_bookends_taken = true
		"reek_charge":
			reek_charge_taken = true
		# --- Onion passives ---
		"layered_defense":
			layered_defense_taken = true
		"rotten_core":
			rotten_core_taken = true
		"chronic_reek":
			chronic_reek_taken = true
		"fermented_strength":
			fermented_strength_taken = true
		"overripe":
			overripe_taken = true
			poison_max_stacks_bonus += int(round(2.0 * rmult))   # Run 40 — +2/+3/+3/+4 by rarity
		"death_bloom":
			dd_charges_remaining = min(DD_CHARGE_HARD_CAP, dd_charges_remaining + 1)
			dd_payloads.append({"payload": "onion_death_bloom", "rarity": rarity})
			family_dd_taken = true
		# --- Legendaries (Run 19) ---
		"juicebox_of_youth":
			juicebox_of_youth_taken = true
		"adamantium_husk":
			adamantium_husk_taken = true
			# Treat as 1 implicit Hardshell Roll grant if none owned yet.
			overshield_grant_on_dash = max(overshield_grant_on_dash, 1)
			overshield_max = max(overshield_max, 2)
			# Run 150b — holder-only mirror.
			overshield_grant_on_dash_by[pending_picker] = max(int(overshield_grant_on_dash_by.get(pending_picker, 0)), 1)
			overshield_max_by[pending_picker] = max(int(overshield_max_by.get(pending_picker, 0)), 2)
		"hulk_smash":
			hulk_smash_taken = true
		# --- Run 23 Legendaries ---
		"tidal_tsunami":
			tidal_tsunami_taken = true
		"inferno_crown":
			inferno_crown_taken = true
		"eagle_eye":
			eagle_eye_taken = true
			# Mirror Hawkeye's pattern: +25% crit chance + +25% crit damage bonus.
			crit_chance        = min(1.0, crit_chance + 0.25)
			crit_damage_bonus += 0.25
		"sniper_focus":
			# Run 24 — 2nd Carrot Legendary. Passive streak tracking in roll_crit_mult.
			sniper_focus_taken = true
		"slip_stream":
			# Run 24 — Banana Legendary. Dash-through-enemy effect wired in Player dash path.
			slip_stream_taken = true
		"voltaic_engine":
			voltaic_engine_taken = true
			# Force Greased Lightning mode on permanently.
			greased_lightning_mode = true
		# ── IDENTITY-FLIP CORRUPT BOONS (GDD §6.3) ──────────────────────────
		"corrupt_apple":
			corrupt_apple_taken = true
			# Poison Apple: glass-HP mode. Cap applied in get_effective_max_hp().
			# All incoming hits floored to 1 in Player._process_damage().
			# Healing blocked via Player._try_heal_hp() guard.
			# Ripened Core always-on handled in _scale_damage() apple branch.
			# Max-HP gains → all-stat conversion: get_poison_apple_conversion_pct().
			# Run 139 — Golden Apple DD: TAKER ONLY (was both heroes).
			if pending_picker == "bea":
				bea_dd_charges += 1
			else:
				shino_dd_charges += 1

		"corrupt_coconut":
			corrupt_coconut_taken = true
			# Overshield disabled: guard in Player._update_overshield().
			# Run 139 — +50% dealt / -40% taken are TAKER ONLY now, applied
			# per-set in get_char_damage_mult() / get_damage_taken_mult_for()
			# (the old global damage_mult/damage_taken_mult mutations leaked
			# the buff to the other ninja; damage_taken_mult was dead anyway).
			# Melee shockwave on every hit: wired in Player/BeaAI hit callbacks.

		"corrupt_broccoli":
			corrupt_broccoli_taken = true
			# All fury/stalking/green_rage ramps locked at max immediately.
			# Run 139 — +100% damage is TAKER ONLY now, applied per-set in
			# get_char_damage_mult() (old global damage_mult leaked to both).
			# 50% CC resistance + landed CC halved: TODO in Player._apply_cc().
			# Dash distance halved: TODO flag read by Player._dash_distance_mult().

		"corrupt_carrot":
			corrupt_carrot_taken = true
			# Crit damage disabled + 50% flat crit chance override.
			# Applied in roll_crit_mult() — if corrupt_carrot_taken, crit = 1.0 dmg,
			# and effective_chance becomes max(effective_chance, 0.50).
			# Random debuff/buff on crit: TODO in Player._on_crit_callback().

		"corrupt_grape":
			corrupt_grape_taken = true
			# Combo counter clamped to 15 (Player._process / BeaAI._bump_combo).
			# Run 131 — every Y/X swing is pinned to its finisher step:
			#   Player._perform_attack_swing() forces combo_step = Y/X_COMBO_HITS.
			#   BeaAI._tap_katana()/_tap_naginata() force the spin-finisher step.
			# Finisher damage force-scaled in Player/_bea _scale_damage (is_finisher).
			# +50% finisher AoE radius: Player._activate_melee_hitbox box *1.5;
			#   BeaAI._tap_katana katana reach *1.5.

		"corrupt_pepper":
			corrupt_pepper_taken = true
			# Burn stacks disabled; TODO: Player clears StatusComponent burn on _ready when corrupt_pepper_taken.
			# +100% fire damage.
			fire_damage_mult *= 2.0
			# Instant explosion on every hit + chain-react: TODO in hit callback.

		"corrupt_watermelon":
			corrupt_watermelon_taken = true
			# Both watermelon modes always active simultaneously.
			watermelon_surge_active = true
			watermelon_tide_active  = true
			# -50% Chi gain: applied in earn_chi() multiplier.
			# -50% HP regen: applied in tick regen functions.
			# Per-CC'd-enemy bonus: TODO in combat frame check.

		"corrupt_potato":
			corrupt_potato_taken = true
			# Run 139 — +20% move speed is TAKER ONLY now, applied per-set in
			# get_char_move_speed_mult() (old global move_speed_mult leaked).
			# +2 dash charges (read by Player._get_max_dash_charges via
			# corrupt_potato_taken — NOT Death-Defiance charges; previous code
			# wrongly granted +2 DD revives here).
			# CC chain removed, dash-through knockup: TODO in Player._on_dash().

		"corrupt_banana":
			corrupt_banana_taken = true
			# Blink dash replaces dodge: TODO in Player._on_dodge_input().
			# Thunderbolt at blink endpoints: TODO in Player._blink_land().
			# +75% lightning damage.
			lightning_damage_mult *= 1.75
			# Y chains to 3 enemies: TODO in BeaAI / Player Y-finisher.
			# 3m shock aura: TODO — spawned node in Player._ready().

		"corrupt_onion":
			corrupt_onion_taken = true
			# Attack poison disabled (flag read by on-hit poison applier).
			# 5m stink aura rapid-stack Poison → Disgust: TODO aura node.
			# Death Bloom aura on revive: TODO in Player._on_revive().

		# ── END IDENTITY-FLIP CORRUPTS ──────────────────────────────────────

	# --- Slot registration (record only) ---
	# Run 44 — the +1-level-on-replacement logic moved to register_slot_pick()
	# (per-character; called by BoonOffer with the actual picker). The global
	# owned_slots map stays as a record for UI/tint fallbacks. Keying levels
	# off this GLOBAL map was wrong with two ninjas: Bea taking her first
	# Y-slot boon looked like a "replacement" of Shino's Y boon.
	var boon_slot_id: String = get_slot_for_boon(boon_id)
	if boon_slot_id != "":
		if not boon_levels.has(boon_id):
			boon_levels[boon_id] = 1
		owned_slots[boon_slot_id] = boon_id

	# Per-family counters (after match so every pick increments correctly)
	var fam: String = b.get("family", "")
	match fam:
		"Apple":      apple_boons_taken += 1
		"Coconut":    coconut_boons_taken += 1
		"Broccoli":   broccoli_boons_taken += 1
		"Carrot":     carrot_boons_taken += 1
		"Grape":      grape_boons_taken += 1
		"Watermelon": watermelon_boons_taken += 1
		"Pepper":     pepper_boons_taken += 1
		"Potato":     potato_boons_taken += 1
		"Banana":     banana_boons_taken += 1
		"Onion":      onion_boons_taken += 1
		# Corrupt counts separately (Run 19) so duo/corrupt UI summaries can read it.
		"Corrupt":    corrupt_boons_taken += 1

	# One-per-run cap: flag that no more corrupts should be offered.
	if rarity == "corrupt":
		corrupt_accepted = true

	current_offer.clear()


# ---------------------------------------------------------------------------
# Per-scene transition: cache HP/Chi so the new Player can hydrate.
# ---------------------------------------------------------------------------
func cache_player_carry(hp: int, chi: int) -> void:
	carry_hp  = hp
	carry_chi = int(float(chi) * 0.5)   # exactly half of current Chi carries to the next room

func cache_bea_carry(hp: int, chi: int) -> void:
	bea_carry_hp  = hp
	bea_carry_chi = int(float(chi) * 0.5)   # same half-carry rule for both ninjas

# Shino-only wipe. BeaAI hydrates AFTER Player (deferred _ready), so Player's
# consume must not clear Bea's carry — that was the bug that reset Bea's Chi
# every room. Bea clears her own fields via clear_bea_carry().
func clear_carry() -> void:
	carry_hp      = -1
	carry_chi     = -1
	# NOTE: carry_player_controlled_char is intentionally NOT cleared here.
	# Player._apply_carry_state() runs first (synchronous) and reads this value,
	# then Bea's _ready() (deferred) reads and clears it. Clearing it here would
	# wipe it before Bea gets to read it, breaking the inter-arena swap persist.

func clear_bea_carry() -> void:
	bea_carry_hp  = -1
	bea_carry_chi = -1


# ---------------------------------------------------------------------------
# Dragon Fruit (Pom) level helpers.
# Each Dragon Fruit applied to a boon increments boon_levels[boon_id].
# Level 1 = base (no bonus). Per-level bonus scales with the boon's ROLLED
# rarity (Run 40): common +10% / uncommon +12% / rare +15% / epic +20%.
# ---------------------------------------------------------------------------
func get_boon_level(boon_id: String) -> int:
	return int(boon_levels.get(boon_id, 1))


func get_boon_level_mult(boon_id: String) -> float:
	var lvl: int = get_boon_level(boon_id)
	var per_level: float = float(RARITY_LEVEL_BONUS.get(get_boon_rarity(boon_id), 0.10))
	return 1.0 + per_level * float(max(0, lvl - 1))


func apply_dragon_fruit_to_boon(boon_id: String, levels_up: int = 1) -> void:
	if not BOON_POOL.has(boon_id):
		return
	var current: int = int(boon_levels.get(boon_id, 1))
	boon_levels[boon_id] = current + levels_up
	print("[RunState] Dragon Fruit (+%d): %s → level %d (now +%.0f%% effect, %s rarity)" % [
		levels_up, boon_id, current + levels_up, (get_boon_level_mult(boon_id) - 1.0) * 100.0,
		get_boon_rarity(boon_id)])


# Pick up to `count` random owned boons to offer as Dragon Fruit upgrade targets.
# Prioritises boons with lower current levels (so the player can spread upgrades).
# Returns an Array of boon IDs.
func get_dragon_fruit_candidates(count: int = 3) -> Array:
	if boons_taken.is_empty():
		return []
	# Deduplicate (boons_taken may have the same id multiple times for stackable).
	var seen: Dictionary = {}
	for id in boons_taken:
		seen[id] = true
	var candidates: Array = seen.keys()
	# Sort: lower-level boons first so the upgrade choice is meaningful.
	candidates.sort_custom(func(a, b): return get_boon_level(a) < get_boon_level(b))
	candidates.shuffle()   # randomise within the same level tier
	return candidates.slice(0, min(count, candidates.size()))


# ---------------------------------------------------------------------------
# Convenience: roll a crit. Returns 1.0 normally, otherwise (1.5 + Hawkeye amp).
# Run 20 — also records `last_crit_result` so post-hit code (e.g. Aimed Guard
# duo overshield grant) can react to whether the hit actually crit.
#
# Wired boon overrides (evaluated in priority order):
#   1. force_next_crit — set by Player when Opening Strike condition passes
#      (first hit on a full-HP enemy). Cleared after one roll.
#   2. Golden Carrot — guaranteed crit every 5th hit. Streak tracked here so
#      any attack path (melee, ranged, charge) counts equally.
#   3. Chance roll — crit_chance (Eagle Eye, future boons).
# ---------------------------------------------------------------------------
var last_crit_result: bool = false
# Run 127 — crit display tier for damage numbers (Bruno: crits must visibly
# pay off). 0 = normal, 1 = crit (orange, larger), 2 = Mega-Crit (red, bigger:
# any forced/guaranteed crit — Golden Carrot, Opening Strike, Flanking Strike,
# Drawn Bow, Heavy Crit duo). Frame-stamped so multi-target AoE hits from one
# roll all display, while later DoT ticks don't inherit the tint.
var last_crit_tier: int = 0
var _last_crit_frame: int = -1

func get_display_crit_tier() -> int:
	if Engine.get_process_frames() == _last_crit_frame:
		return last_crit_tier
	return 0

func _set_crit_tier(tier: int) -> void:
	last_crit_tier = tier
	_last_crit_frame = Engine.get_process_frames()
# force_next_crit — set externally before calling roll_crit_mult() to guarantee
# the next crit roll succeeds. Cleared immediately on roll. Used by:
#   - Opening Strike: first hit on a full-HP enemy
#   - Golden Carrot: combo finisher (final Y or final X hit)
#   - Finisher's Aim: gives +50% crit chance on combo finishers (chance roll, not force)
var force_next_crit: bool = false
# finisher_crit_chance_bonus — additive crit chance added on combo finisher hits.
# Finisher's Aim Charge boon applies +50% here; Player sets it before roll on finishers.
var finisher_crit_chance_bonus: float = 0.0   # applied per-roll, not persistent

# attack_type: "primary", "heavy", "ranged", or "" (unspecified = no per-type bonus).
# Keen Eye (+15%/+10% on primary), Sharpened Tip (+25%/+20% on heavy),
# Bullseye (+20%/+30% on ranged).
func roll_crit_mult(attack_type: String = "", who: String = "shino") -> float:
	return BoonEffects.roll_crit_mult(attack_type, who)


# ---------------------------------------------------------------------------
# Grape family helpers (Combo Counter scaling).
# ---------------------------------------------------------------------------
func get_combo_master_mult(combo_count: int, who: String = "shino") -> float:
	return BoonEffects.get_combo_master_mult(combo_count, who)

func get_noble_rot_mult(combo_count: int, is_finisher: bool, who: String = "shino") -> float:
	return BoonEffects.get_noble_rot_mult(combo_count, is_finisher, who)


# ---------------------------------------------------------------------------
# Apple Full Bloom — Y-only +15% when hp_frac >= 0.80. Run 16: Y-gated.
# Callers MUST pass is_primary=true ONLY for primary (Y) attack damage.
# ---------------------------------------------------------------------------
func get_full_bloom_mult(hp_frac: float, is_primary: bool = false, who: String = "shino") -> float:
	return BoonEffects.get_full_bloom_mult(hp_frac, is_primary, who)


# ---------------------------------------------------------------------------
# Apple Ripened Core + Heart of the Orchard — global, HP-fraction-driven.
# ---------------------------------------------------------------------------
func get_apple_hp_tier_mult(hp_frac: float, who: String = "shino") -> float:
	return BoonEffects.get_apple_hp_tier_mult(hp_frac, who)


# ---------------------------------------------------------------------------
# Broccoli Heavy Stalk — Y-only +15% (Run 16: pulled out of damage_mult).
# Spec §8.3: Y slot — "+15% damage AND +10% atk speed to primary attacks".
# ---------------------------------------------------------------------------
func get_heavy_stalk_mult(is_primary: bool = false, who: String = "shino") -> float:
	return BoonEffects.get_heavy_stalk_mult(is_primary, who)


# ---------------------------------------------------------------------------
# Run 127 — STATUS-SLOT BASELINE DAMAGE (Bruno's Hades-parity spec):
# slot boons that only apply a non-damaging status (Wet/Chilled, Slippery/
# Greased/Sparked default hazards) also grant a baseline damage bonus on that
# slot's attacks, scaling with rarity x Dragon Fruit level like every other
# numeric boon. Burn/Poison slots are excluded (their status IS damage).
# Caller passes the attack slot ("Y"/"X"/"A"/"Charge"); B stays pure utility.
# ---------------------------------------------------------------------------
const STATUS_SLOT_DMG_BONUS = BoonDBClass.STATUS_SLOT_DMG_BONUS
const STATUS_SLOT_DMG_BOONS = BoonDBClass.STATUS_SLOT_DMG_BOONS

func get_status_slot_dmg_mult(who: String, slot: String) -> float:
	return BoonEffects.get_status_slot_dmg_mult(who, slot)


# ---------------------------------------------------------------------------
# Run 128 — Smash Zone (Broccoli Legendary): melee +10% damage per meter
# closer to the target, capped +50% at point-blank (<=0.5m), 0% at 5m+.
# 1 meter = 48 px (tile size). Callers pass melee hits only.
# ---------------------------------------------------------------------------
const SMASH_ZONE_PX_PER_M = BoonDBClass.SMASH_ZONE_PX_PER_M
func get_smash_zone_mult(who: String, dist_px: float) -> float:
	return BoonEffects.get_smash_zone_mult(who, dist_px)


# ---------------------------------------------------------------------------
# Run 128 — Drupe Guard (Coconut Legendary): taking damage triggers a 1.5s
# invulnerability shield; 10s internal CD, -2s per Dragon Fruit level
# (floor 4s per doc). Returns the invuln duration on proc, 0.0 otherwise.
# ---------------------------------------------------------------------------
var _drupe_ready_msec: Dictionary = {"shino": 0, "bea": 0}
func try_drupe_guard(who: String) -> float:
	return BoonEffects.try_drupe_guard(who)


# ---------------------------------------------------------------------------
# Run 128 — Shocking Return (Banana passive, doc §8.9 #2): 20% chance when
# hit — default mode: knock down the attacker 1s; Greased Lightning mode:
# small zap damage + ~0.3s ministun instead. Caller applies the CC.
# ---------------------------------------------------------------------------
func roll_shocking_return(who: String) -> bool:
	return BoonEffects.roll_shocking_return(who)


# ---------------------------------------------------------------------------
# Broccoli Stalk of Might — +5% damage per Broccoli boon owned.
# ---------------------------------------------------------------------------
func get_stalk_of_might_mult() -> float:
	return BoonEffects.get_stalk_of_might_mult()


# ---------------------------------------------------------------------------
# Broccoli Green Rage — always-on tiered rage (replaces, doesn't stack).
# ---------------------------------------------------------------------------
func get_green_rage_mult(hp_frac: float, who: String = "shino") -> float:
	return BoonEffects.get_green_rage_mult(hp_frac, who)

func get_green_rage_dr(hp_frac: float, who: String = "shino") -> float:
	return BoonEffects.get_green_rage_dr(hp_frac, who)


# ---------------------------------------------------------------------------
# Broccoli Crushing Blow — +50% damage to enemies <30% HP.
# Caller passes target_hp_frac.
# ---------------------------------------------------------------------------
func get_crushing_blow_mult(target_hp_frac: float) -> float:
	return BoonEffects.get_crushing_blow_mult(target_hp_frac)


# ---------------------------------------------------------------------------
# Broccoli Bash the Big Ones — +25% to elites/bosses.
# Caller passes is_elite_or_boss bool.
# ---------------------------------------------------------------------------
func get_bash_big_ones_mult(is_elite_or_boss: bool) -> float:
	return BoonEffects.get_bash_big_ones_mult(is_elite_or_boss)


# ---------------------------------------------------------------------------
# Broccoli Combat Fury — tier-driven on-hit ramp. Caller maintains the live
# `current_tier` per-player (0..5) and asks for the mult.
# ---------------------------------------------------------------------------
func get_combat_fury_mult(current_tier: int, who: String = "shino") -> float:
	return BoonEffects.get_combat_fury_mult(current_tier, who)


# ---------------------------------------------------------------------------
# Sweet Dreams — heal 5% max HP on room clear, per-character.
# ---------------------------------------------------------------------------
func get_sweet_dreams_heal_pct(who: String = "shino") -> float:
	return BoonEffects.get_sweet_dreams_heal_pct(who)


# ---------------------------------------------------------------------------
# Apple Granny's Recipe heal amp — multiplicative on top of every heal.
# Player.gd's heal paths should multiply incoming heal amounts by this.
# ---------------------------------------------------------------------------
func get_heal_amp() -> float:
	return BoonEffects.get_heal_amp()


# ---------------------------------------------------------------------------
# Apple Pie consumable (Hades centaur-heart-equivalent) — flat +10% per pie.
# Run 17: bumped 5% → 10% per Bruno's tuning brief. No stack cap initially
# (Centaur Hearts don't cap in Hades).
# Apple Pie is offered as a *consumable card* in the BoonOffer overlay at a
# ~12% per-cycle chance (see BoonOffer.gd:APPLE_PIE_OFFER_CHANCE). It does NOT
# live in BOON_POOL — it's a separate offer-replacement track.
# ---------------------------------------------------------------------------
const APPLE_PIE_HP_PER_STACK = BoonDBClass.APPLE_PIE_HP_PER_STACK
func get_apple_pie_max_hp_pct() -> float:
	return BoonEffects.get_apple_pie_max_hp_pct()


# Helper for BoonOffer — adds one apple pie stack and broadcasts to players
# so their HP bar can heal/widen by the pickup amount immediately.
func grant_apple_pie() -> void:
	apple_pie_stacks += 1
	print("[RunState] Apple Pie consumed — stacks now %d (+%.0f%% max HP)" % [
		apple_pie_stacks, get_apple_pie_max_hp_pct() * 100.0,
	])


# ---------------------------------------------------------------------------
# Apple Juice consumable (Run 23, 2026-06-01) — one-shot 50% current-HP heal
# for BOTH heroes. Auto-dropped on TestArena waves 5 and 10.
# Distinct from Apple Pie (Pie = permanent +max-HP stack).
# No persistent state — applied on grant, no carry to next run.
# ---------------------------------------------------------------------------
const APPLE_JUICE_HEAL_PCT = BoonDBClass.APPLE_JUICE_HEAL_PCT
var apple_juice_consumed_count: int = 0   # cumulative count this run (for HUD/stats)

# ── Dragon Souls ─────────────────────────────────────────────────────────────
# Run 43 — Dream World economy: sparks NO LONGER drop in Dream Arena (training).
# Dream World: biome mini-boss (room 5) drops 1, biome boss (room 10) drops 2,
# Shadow Sensei Z victory drops 3. Spent at Sensei Z in the Dojo as before.
var dragon_souls: int = 0

# ============================================================
# Run 117 — DAYTIME WORLD: Karma & Family Healing
# ============================================================
# Townsfolk_Directory.md §1/§2 (LOCKED loop): every boon taken in a
# night run silently banks 1 KARMA with its family. Karma is inert
# until DEPOSITED by talking to the family's ELDER in their biome
# day-room home. Deposits advance the healing ladder:
#   0 Rotten → 1 Wilted → 2 Ripe → 3 Restored
# HARD UI RULE: karma numbers are NEVER shown to the player.

const FAMILIES = BoonDBClass.FAMILIES

# Which two families live in each biome's daytime room (Daytime_World_Spec.md §2).
const FAMILY_HOMES = BoonDBClass.FAMILY_HOMES

# [TUNE] Cumulative boon-karma thresholds to reach each healing tier.
# Tier 0→1 = 10 boons, 1→2 = 15 more (25 total), 2→3 = 25 more (50 total).
# Incremental per tier: 10, 15, 25.  ~50-80 runs to 100% all 10 families.
const KARMA_THRESHOLDS = BoonDBClass.KARMA_THRESHOLDS
const FAMILY_TIER_MAX: int = 3

# Incremental karma needed to advance FROM the given tier to the next.
static func karma_needed_for_tier(current_tier: int) -> int:
	if current_tier < 0 or current_tier >= FAMILY_TIER_MAX:
		return 999
	var cumul: int = KARMA_THRESHOLDS[current_tier]
	var prev:  int = KARMA_THRESHOLDS[current_tier - 1] if current_tier > 0 else 0
	return cumul - prev

# Persistent (saved) — all keyed by family name.
var karma_banked: Dictionary = {}        # undeposited karma (capped at tier's incremental need)
var karma_progress: Dictionary = {}      # deposited progress toward the next tier
var family_tier: Dictionary = {}         # 0..3 healing tier
var family_story_layer: Dictionary = {}  # next story-layer line index (FamilyLore pools)
var family_visits: Dictionary = {}       # total elder chats (drives daily-line rotation)
var member_visits: Dictionary = {}       # per-wanderer chats (drives member-line rotation), keyed "Fam|Name"

# ---------------------------------------------------------------------------
# Run 143 — TOWN VISUAL TIER: which town tileset the waking-world Town Square
# uses. Purely cosmetic; derived from healing progress + the ending flag.
#   0 = Delapidated — every new save starts here (sensei_lore_tier resets to 0)
#   1 = Healing     — Sensei's lore dialogue reaches tier 3 (healing score >= 8)
#   2 = Perfect     — all 10 families Restored (Sensei lore tier 6 = max) AND
#                     the full ending has been beaten at least once.
# ---------------------------------------------------------------------------
var full_ending_beaten: bool = false   # persistent — set on Shadow Sensei Z victory

func town_visual_tier() -> int:
	return DayState.town_visual_tier()   # P2-B4a: body → scripts/DayState.gd

# Transient (NOT saved) — day-world routing + run guard.
var _karma_banked_this_run: bool = false
var day_visit_biome: String = ""   # biome id for DayBiomeRoom
var day_visit_family: String = ""  # family for FamilyHome interior
var day_spawn_hint: String = ""    # "from_town" / "from_home" / "from_biome_<id>"


# Call ONCE at the end of a run (win OR defeat), BEFORE reset_run() wipes
# boons_taken. Both call sites: RunComplete._finalize_run() and
# Player._reload_arena1(). Corrupt boons bank nothing.
func bank_run_karma() -> void:
	DayState.bank_run_karma()   # P2-B4a: body → scripts/DayState.gd


func get_family_tier(fam: String) -> int:
	return DayState.get_family_tier(fam)   # P2-B4a: body → scripts/DayState.gd


func has_banked_karma(fam: String) -> bool:
	return DayState.has_banked_karma(fam)   # P2-B4a: body → scripts/DayState.gd


# Deposit ALL banked karma for a family (the elder chat). Returns
# {"deposited": int, "tier_up": bool, "new_tier": int} for the dialog layer.
# One tier advance max per deposit, no progress carry-over past a tier-up
# (Townsfolk §2.1). At Restored, karma is still absorbed as goodwill.
func deposit_karma(fam: String) -> Dictionary:
	return DayState.deposit_karma(fam)   # P2-B4a: body → scripts/DayState.gd


# ---------------------------------------------------------------------------
# Island healing score — drives Sensei Z's progressive dialogue.
# Each family's current tier contributes weighted points:
#   Tier 0 (Rotten)   = 0 pts     Tier 1 (Wilted)   = 1 pt
#   Tier 2 (Ripe)     = 2 pts     Tier 3 (Restored) = 4 pts
# 10 families × 4 pts max = 40 total.  Partial karma progress within a
# tier adds a fractional point so the score rises between tier-ups too.
# ---------------------------------------------------------------------------
const _HEALING_TIER_WEIGHT = BoonDBClass._HEALING_TIER_WEIGHT

func island_healing_score() -> float:
	return DayState.island_healing_score()   # P2-B4a: body → scripts/DayState.gd


# Sensei lore tier thresholds keyed off island_healing_score().
# Tier 1 = post-tutorial town visit (set in Dojo cutscene, not score-based).
# Tiers 2-5+ are score-driven:
#   Tier 2: score >= 2   (a few families at Wilted, first real progress)
#   Tier 3: score >= 8   (several families healing, ~3-4 at Wilted+)
#   Tier 4: score >= 18  (majority recovering, some at Ripe)
#   Tier 5: score >= 30  (nearly all families deep into healing)
#   Tier 6: score >= 40  (all 10 families fully Restored — finale unlock)
const SENSEI_LORE_THRESHOLDS = BoonDBClass.SENSEI_LORE_THRESHOLDS

func compute_sensei_lore_tier() -> int:
	return DayState.compute_sensei_lore_tier()   # P2-B4a: body → scripts/DayState.gd


# Call after any karma deposit or tier-up to see if Sensei has new dialogue.
func update_sensei_lore_from_healing() -> void:
	DayState.update_sensei_lore_from_healing()   # P2-B4a: body → scripts/DayState.gd


# ============================================================
# Run 43 — DREAM WORLD (the real adventure; GDD §7)
# ============================================================
# dream_world_mode: true while running the Dream World loop (DreamHub /
# DreamRoom / finale). False = legacy Dream Arena training chain.
var dream_world_mode: bool = false

# --- Run 113: Dream-World NIGHT -------------------------------------------
# Single source of truth for the night tint. A CanvasModulate using NIGHT_TINT
# is added over the layer-0 world canvas in DreamRoom + DreamHub (cool moonlit
# multiply). It tints terrain/props/heroes/enemies but NOT anything on a
# CanvasLayer (HUD, boon panels, menus, fades — all already bright).
#
# A few WORLD-SPACE items must stay full-bright (reward pickups, door/exit
# reward labels). apply_night_exemption() pre-multiplies the exact inverse of
# NIGHT_TINT onto those nodes so the CanvasModulate cancels back to 1.0. Gated
# on dream_world_mode so the same pickups in non-night scenes aren't blown out.
const NIGHT_TINT: Color = Color(0.55, 0.61, 0.80)   # lightened — was 0.42/0.48/0.70

func night_exempt_modulate() -> Color:
	return Color(1.0 / NIGHT_TINT.r, 1.0 / NIGHT_TINT.g, 1.0 / NIGHT_TINT.b, 1.0)

func apply_night_exemption(node: CanvasItem) -> void:
	if dream_world_mode and is_instance_valid(node):
		node.modulate = night_exempt_modulate()
# Biome currently being run: "" (in hub) | "beach" | "jungle" | "swamp"
#                            | "caverns" | "peaks" | "cake" (finale climb)
var current_biome: String = ""
# 1-indexed room within the current biome (1..10; cake climb 1..5).
var biome_room: int = 1
# Frostpeak exit-type system: "open" = outdoor snowy arena, "cave" = icy cavern.
# Set when committing a door choice; read by the next DreamRoom to pick its visual variant.
var peak_room_type: String = "open"
# Which biomes' bosses have been cleansed this run.
var biomes_cleared: Dictionary = {
	"beach": false, "jungle": false, "swamp": false, "caverns": false, "peaks": false,
}
# Town-Square Defense (5-wave gauntlet) cleared → Cake Portal open.
var gauntlet_cleared: bool = false
# In-run shop currency (coins). Earned from coin doors / wave drips / gauntlet.
var run_coins: int = 0
# Run 45 — the Town-Square shop may rarely offer a Dragon Soul (300c). Once
# bought it never restocks again this run (can keep APPEARING until bought).
var shop_spark_bought: bool = false

const COIN_DOOR_GRANT_MIN: int = 50
const COIN_DOOR_GRANT_MAX: int = 100
const COIN_WAVE_DRIP_MIN:  int = 3
const COIN_WAVE_DRIP_MAX:  int = 8

# Run 45 — Dream exit cadence (Bruno's rebalance after the first full clear):
#   * 40% of choice rooms = BOON room. 60% = REWARD room (Pie / DragonFruit /
#     Coins). Coin doors ONLY appear in reward rooms.
#   * Exit count is 1-3 (weights below) — sometimes you get what you get.
const DREAM_BOON_ROOM_CHANCE: float = 0.40
const DREAM_ONE_EXIT_CHANCE:  float = 0.20   # 20% → 1 exit
const DREAM_TWO_EXIT_CHANCE:  float = 0.50   # 50% → 2 exits (remaining 30% → 3)

func all_biomes_cleared() -> bool:
	for k in biomes_cleared.keys():
		if not bool(biomes_cleared[k]):
			return false
	return true

func biomes_cleared_count() -> int:
	var n: int = 0
	for k in biomes_cleared.keys():
		if bool(biomes_cleared[k]):
			n += 1
	return n

func add_coins(amount: int) -> void:
	run_coins = max(0, run_coins + amount)
	# Nudge HUDs that show a coin counter.
	if Engine.get_main_loop() is SceneTree:
		for h in (Engine.get_main_loop() as SceneTree).get_nodes_in_group("hud"):
			if h.has_method("refresh_coin_counter"):
				h.refresh_coin_counter()

# Dream-room exit roll (Run 45 cadence) — keyed to biome_room:
#   next room 4 (DreamBiomes.MINIBOSS_ROOM)  → forced MINI-BOSS door
#   next room 8 (DreamBiomes.ROOMS_PER_BIOME) → forced BOSS door
#   otherwise: 40% boon room / 60% reward room (Pie / DragonFruit / Coins),
#   each showing 1-3 doors. Coins only ever appear in reward rooms.
#   Reward rooms are gated until BOTH ninjas own >=1 boon (DF needs a target);
#   before that, every choice room is a boon room.
func roll_dream_room_exits(next_room: int, biome: String) -> Array:
	if next_room >= 8:    # keep in sync with DreamBiomes.ROOMS_PER_BIOME
		return [{"type": "boss", "family": "", "rarity": "", "label": "👑 BIOME BOSS"}]
	if next_room == 4:    # keep in sync with DreamBiomes.MINIBOSS_ROOM
		return [{"type": "miniboss", "family": "", "rarity": "", "label": "★ MINI-BOSS"}]
	var count: int = _roll_dream_exit_count()
	var df_valid: bool = not shino_boon_set.is_empty() and not bea_boon_set.is_empty()
	if df_valid and randf() >= DREAM_BOON_ROOM_CHANCE:
		# REWARD room — draw `count` distinct doors from Pie / DragonFruit / Coins.
		var pool: Array = [
			_make_pie_preview(),
			_make_dragonfruit_preview(),
			{"type": "coins", "family": "", "rarity": "", "label": "💰 COINS"},
		]
		pool.shuffle()
		return pool.slice(0, min(count, pool.size()))
	# BOON room — 1-3 distinct-family boon doors.
	var exits: Array = []
	var used_families: Array = []
	for _i in range(count):
		var door: Dictionary = _roll_boon_door(used_families)
		var door_fam: String = String(door.get("family", ""))
		if door_fam != "":
			used_families.append(door_fam)
		exits.append(door)
	return exits


# 1-3 doors per choice room: 20% → 1, 50% → 2, 30% → 3.
func _roll_dream_exit_count() -> int:
	var r: float = randf()
	if r < DREAM_ONE_EXIT_CHANCE:
		return 1
	if r < DREAM_ONE_EXIT_CHANCE + DREAM_TWO_EXIT_CHANCE:
		return 2
	return 3

# ---- Sensei Z permanent upgrades (persist across runs, survive reset_run) ----
# Run 46 rebalance — 5%/tier × 5 tiers (crit 2%/tier), escalating 1-5 costs.
var sensei_damage_pct:  float = 0.0   # +5% base dmg per tier; max 5 → +25%
var sensei_dr_pct:      float = 0.0   # -5% damage taken per tier; max 5 → -25%
var sensei_extra_dash:  int   = 0     # +1 dash charge both heroes; max 3 (costs 1/3/5)
var sensei_extra_dd:    int   = 0     # +1 DD charge per ninja; max 1 (costs 3)
var sensei_chi_regen:   int   = 0     # Run 46 — Dragon Chi reworked: ranks of
									  # passive Chi regen, +1 Chi per 5s per rank;
									  # max 5 (+1 Chi/s). Rate via get_sensei_chi_regen_rate().
var sensei_hp_pct:      float = 0.0   # +5% max HP per tier; max 5 → +25%
var sensei_crit_pct:    float = 0.0   # +2% crit chance per tier; max 5 → +10%
var sensei_speed_pct:   float = 0.0   # +5% move speed per tier; max 5 → +25%

# Run 46 — Dragon Chi: 1 Chi per 5 seconds per rank → 0.2 Chi/sec per rank.
const SENSEI_CHI_PER_RANK_PER_SEC: float = 0.2

func get_sensei_chi_regen_rate() -> float:
	return float(sensei_chi_regen) * SENSEI_CHI_PER_RANK_PER_SEC
# Run 46 — five new training nodes.
var sensei_pocket_ranks: int  = 0     # Deep Pockets: +25 starting coins/rank; max 5
var sensei_haggle_ranks: int  = 0     # Haggler's Tongue: -5% shop prices/rank; max 5
var sensei_reroll_ranks: int  = 0     # Fated Reroll: +1 boon-offer reroll per run/rank; max 3 (costs 3/4/5)
var sensei_revive_ranks: int  = 0     # Sibling Bond: +15% revive fill speed/rank; max 3 (costs 1/3/5)
var sensei_boss_dmg_pct: float = 0.0  # Boss Hunter: +5%/tier dmg vs boss/miniboss/elite; max 5 → +25%

# Run 46 — run-scoped reroll charges (refilled from sensei_reroll_ranks each run).
var rerolls_left: int = 0

# Haggler's Tongue — discounted shop price (floors at 1 coin).
func get_shop_price(base: int) -> int:
	return max(1, int(round(float(base) * (1.0 - 0.05 * float(sensei_haggle_ranks)))))

# Sibling Bond — revive fill-rate multiplier (circle AND channel).
func get_sensei_revive_mult() -> float:
	return 1.0 + 0.15 * float(sensei_revive_ranks)

var sensei_rarity_ranks: int  = 0     # Run 41 — Dragon's Fortune: +5% per rank to
									  # EACH rarity-upgrade chance (unc/rare/epic);
									  # max 5 ranks (+25% each). Costs 1/2/3/4/5 sparks.
var sensei_legendary_ranks: int = 0   # Run 42 — Legend Seeker: +2%/rank Legendary
									  # room chance (5% base → 15% max). Costs 1-5.
var sensei_duo_ranks:       int = 0   # Run 42 — Twin Spirits: +2%/rank Duo room
									  # chance (5% base → 15% max). Costs 1-5.

# Centralized broadcast — call from TestArena (or a future pickup item) to
# heal both Shino + Bea by 50% of their respective max HP. Returns total heal.
# Safe-no-op for downed characters and missing scene refs.
func _apply_sensei_upgrades() -> void:
	# Called at the end of reset_run(). Applies persistent Sensei Z bonuses
	# to the freshly-reset run state.
	if sensei_extra_dd > 0:
		shino_dd_charges += sensei_extra_dd
		bea_dd_charges   += sensei_extra_dd
	if sensei_dr_pct > 0.0:
		damage_taken_mult *= max(0.0, 1.0 - sensei_dr_pct)
	# Run 46 — Swift Wings now actually applies: fold into the shared move-speed
	# multiplier (covers walk, dash and charge moves for both heroes).
	if sensei_speed_pct > 0.0:
		move_speed_mult *= (1.0 + sensei_speed_pct)
	# Run 46 — Deep Pockets: head-start coin purse.
	if sensei_pocket_ranks > 0:
		run_coins += sensei_pocket_ranks * 25
	# Run 46 — Fated Reroll: refill run-scoped reroll charges.
	rerolls_left = sensei_reroll_ranks


func grant_apple_juice(tree: SceneTree) -> int:
	apple_juice_consumed_count += 1
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
			var heal: int = max(1, int(round(float(max_hp) * APPLE_JUICE_HEAL_PCT)))
			if p.has_method("heal_external"):
				p.heal_external(heal)
				total += heal
				# Run 27 — Baked Apple duo: 50% heal > 10% threshold → ignite
				# the nearest enemy within 200px of the healed hero.
				if p is Node2D:
					baked_apple_duo_ignite(tree, p.global_position)
	print("[RunState] Apple Juice consumed — %d total HP restored across heroes (consumed_count=%d)" % [
		total, apple_juice_consumed_count,
	])
	return total


# ---------------------------------------------------------------------------
# Death-Defiance consumption (Run 13 team-wide trigger).
# ---------------------------------------------------------------------------
func consume_dd_charge() -> Dictionary:
	if dd_charges_remaining <= 0:
		return {"consumed": false, "payloads": []}
	dd_charges_remaining -= 1
	var refill: float = 0.50
	var built: Array = []
	for entry in dd_payloads:
		var ed: Dictionary = entry
		var p: String = ed.get("payload", "")
		var r: String = ed.get("rarity",  "common")
		var hot_pct: float = 0.0
		var hot_dur: float = 0.0
		if p == "apple_cider_mercy":
			match r:
				"common":    hot_pct = 0.03; hot_dur = 5.0
				"uncommon":  hot_pct = 0.035; hot_dur = 5.0
				"rare":      hot_pct = 0.04; hot_dur = 5.5
				"epic":      hot_pct = 0.045; hot_dur = 5.5
				"legendary": hot_pct = 0.05; hot_dur = 6.0
				_:           hot_pct = 0.03; hot_dur = 5.0
		built.append({
			"payload":         p,
			"rarity":          r,
			"hot_pct_per_sec": hot_pct,
			"hot_duration":    hot_dur,
		})
	return {
		"consumed":   true,
		"refill_pct": refill,
		"payloads":   built,
	}


func has_dd_charge() -> bool:
	return dd_charges_remaining > 0


# ---------------------------------------------------------------------------
# resolve_team_down — central team-down handler (Run 13).
# ---------------------------------------------------------------------------
func resolve_team_down(team: Array) -> void:
	# Guard: if either ninja already recovered, do nothing.
	for n in team:
		if is_instance_valid(n) and n.has_method("is_downed") and not n.is_downed():
			return

	# Priority: last-fallen ninja's DD first, then partner's.
	var primary   := _last_downed_char
	var secondary := "bea" if primary == "shino" else "shino"

	var dd_source := ""
	if _char_has_dd(primary):   dd_source = primary
	elif _char_has_dd(secondary): dd_source = secondary

	if dd_source != "":
		var result: Dictionary = _consume_dd_for_char(dd_source)
		if not result.get("consumed", false):
			_trigger_team_game_over(team)
			return
		var refill_pct: float = float(result.get("refill_pct", 0.50))
		var payloads: Array   = result.get("payloads", [])
		print("[RunState] DD consumed from %s — reviving %d ninja(s) at %.0f%% HP." % [
			dd_source, team.size(), refill_pct * 100.0])
		for n in team:
			if is_instance_valid(n) and n.has_method("revive_from_dd"):
				n.revive_from_dd(refill_pct, payloads)
	else:
		_trigger_team_game_over(team)


func _trigger_team_game_over(team: Array) -> void:
	for n in team:
		if not is_instance_valid(n):
			continue
		if n.is_in_group("player") and not n.is_in_group("bea"):
			if n.has_method("trigger_team_game_over"):
				n.trigger_team_game_over()
			return
	for n in team:
		if is_instance_valid(n) and n.has_method("trigger_team_game_over"):
			n.trigger_team_game_over()
			return


# ============================================================
# DUO / SYNERGY / LEGENDARY / CORRUPT helpers (Run 19)
# ============================================================
# Duo Boons = family-pairing boons (DUO_DEFS) — Iron Core, Aimed Guard, etc.
# Elemental Synergies = cross-status reactions (SYNERGY_DEFS) — Wet+Lightning,
#   Steam Burst, Thaw Burst. Two SEPARATE systems.

# --- Elemental Synergies ---

func _has_any_boon_from_family(fam_name: String) -> bool:
	# Read the live per-family counter to avoid O(n) scans over boons_taken.
	match fam_name:
		"Apple":      return apple_boons_taken > 0
		"Coconut":    return coconut_boons_taken > 0
		"Broccoli":   return broccoli_boons_taken > 0
		"Carrot":     return carrot_boons_taken > 0
		"Grape":      return grape_boons_taken > 0
		"Watermelon": return watermelon_boons_taken > 0
		"Pepper":     return pepper_boons_taken > 0
		"Potato":     return potato_boons_taken > 0
		"Banana":     return banana_boons_taken > 0
		"Onion":      return onion_boons_taken > 0
	return false


# Returns true if a synergy's family + mode requirements are met.
func is_synergy_active(synergy_id: String) -> bool:
	return BoonEffects.is_synergy_active(synergy_id)


func get_active_synergies() -> Array:
	return BoonEffects.get_active_synergies()


# Compact "Synergy: Steam Burst, Wet+Lightning" string for UI.
func get_active_synergies_summary() -> String:
	return BoonEffects.get_active_synergies_summary()


# Wet + Lightning synergy damage amp — +5% per Soaked stack on lightning hits.
# Reads target StatusComponent. Per spec §11 #1: max +25% at 5 Soaked / Drenched.
func get_wet_lightning_target_mult(target_status: Variant) -> float:
	return BoonEffects.get_wet_lightning_target_mult(target_status)


# Consolidated target-status damage amps reading the target's status.
# Rising Tide + Blazing Aura + Wet+Lightning (for chain-lightning ticks) all
# stacked multiplicatively. Enemies use this in take_damage. The lightning
# amp is keyed on whether the attacker is a chain-arc damage tick — but
# because the enemy can't tell "who" sourced the damage, we apply it whenever
# the target is Sparked/Bolted/Shocked AND Wet. This is a reasonable proxy.
func get_target_status_damage_mult(target_status: Variant) -> float:
	return BoonEffects.get_target_status_damage_mult(target_status)


# --- Family-pairing Duo Boons (Combat_Boons §5) ---

# Run 41 (Bruno, 2026-06-10): duos are PICKED BOON CARDS, Hades-style — they
# do NOT auto-activate anymore. The 2-per-family count is the OFFER gate:
# a duo card can only APPEAR once the team owns ≥2 boons from EACH family in
# the pairing (plus the effect prereq below). Taking the card activates it.
const DUO_FAMILY_PREREQ: int = 2

# Offer-array prefix for duo cards (duos live in DUO_DEFS, not BOON_POOL).
const DUO_OFFER_PREFIX: String = "duo:"

# Duos the player has actually PICKED this run (duo_id -> true). Persisted.
var duos_taken: Dictionary = {}


func is_duo_active(duo_id: String) -> bool:
	return BoonEffects.is_duo_active(duo_id)


# Can this duo be OFFERED right now? ≥2 boons from each family + not taken
# + effect prereq (no Burn-scaling duo before the build can apply Burn, etc.)
# Run 139 (Bruno): duos are two-FAMILY payoffs — the PICKER's own 2+2 family
# counts and effect sources gate the offer, same rule as every other tier.
func is_duo_offerable(duo_id: String, who: String = "") -> bool:
	if not DUO_DEFS.has(duo_id) or duos_taken.has(duo_id):
		return false
	var d: Dictionary = DUO_DEFS[duo_id]
	for fam in d.get("required_any", []):
		if _family_count_for(String(fam), who) < DUO_FAMILY_PREREQ:
			return false
	return _duo_effect_prereq_met(duo_id, who)


# Run 139 — picker-scoped ownership check for duo prereqs. who == "" falls
# back to team-wide (legacy behavior for callers without a picker).
func _pick_has(id: String, who: String) -> bool:
	if who == "shino":
		return id in shino_boon_set
	if who == "bea":
		return id in bea_boon_set
	return team_has(id)


# Effect-relevance gate (Bruno's Run 41 spec): a duo that scales off a
# mechanic the build can't produce yet must not appear. Most duos key off
# things the 2+2 family requirement already guarantees (slips, soaks, burns,
# poisons ride on nearly every boon of their family) — those default true.
# Listed cases below are mechanics that are NOT implied by family counts.
# EXPAND here as new gated duos get wired.
func _duo_effect_prereq_met(duo_id: String, who: String = "") -> bool:
	match duo_id:
		# Overshield-dependent duos: need an actual overshield SOURCE.
		# (aimed_guard NOT listed — it generates its own overshields on crit.)
		"shell_cluster", "coconut_broccoli", "banana_coconut", "coconut_pepper", "apple_coconut":
			return _has_overshield_source(who)
		# Onion-cloud-dependent duos: need a stink-cloud/zone source.
		"coconut_onion", "onion_pepper":
			return _pick_has("stink_bomb", who) or _pick_has("gas_bookends", who) \
				or _pick_has("reek_charge", who) or _pick_has("chronic_reek", who)
		# Sparked/Bolted (lightning) duos: need Greased Lightning or a bolt source.
		"grape_banana", "banana_watermelon":
			return _pick_has("greased_lightning", who) or _pick_has("voltaic_strike", who) \
				or _pick_has("storm_charge", who) or _pick_has("corrupt_banana", who) \
				or voltaic_engine_taken
	return true


func _has_overshield_source(who: String = "") -> bool:
	# Run 139 — per-picker: the picker must own an overshell generator (or cap
	# extender) themselves. "" falls back to the legacy global-state check.
	if who == "shino" or who == "bea":
		return _has_effect_applier("overshell", who) \
			or _pick_has("stockpile", who) or _pick_has("adamantium_husk", who)
	return overshield_grant_on_dash > 0 or overshield_max > 0 \
		or stockpile_taken or battle_shell_taken or adamantium_husk_taken


# Duo ids offerable in a `family_cap` room (the duo must INVOLVE the room's
# family — Hades rule: the room's god brings the duo to the table).
func get_offerable_duos_for_family(family_cap: String, who: String = "") -> Array:
	var out: Array = []
	for id in DUO_DEFS.keys():
		var fams: Array = DUO_DEFS[id].get("required_any", [])
		if not (family_cap in fams):
			continue
		if is_duo_offerable(id, who):
			out.append(id)
	return out


# Take a duo card. Mirrors apply_boon's bookkeeping but duos live outside
# BOON_POOL: no family counters, no slots, no rarity roll (fixed "duo" tier),
# benefits both ninjas (duo effects are team passives).
func take_duo(duo_id: String) -> void:
	if not DUO_DEFS.has(duo_id):
		push_warning("[RunState] Unknown duo: %s" % duo_id)
		return
	duos_taken[duo_id] = true
	print("[RunState] DUO taken: %s — %s" % [
		DUO_DEFS[duo_id].get("name", duo_id), DUO_DEFS[duo_id].get("desc", "")])
	current_offer.clear()


func get_active_duos() -> Array:
	return BoonEffects.get_active_duos()


# "Duo: Iron Core, Shell Cluster" UI summary.
func get_active_duos_summary() -> String:
	return BoonEffects.get_active_duos_summary()


# Iron Core (Apple + Broccoli) — each owned boon from either tree grants
# +5% max HP AND +5% damage dealt. Stacks multiplicatively across boons.
const IRON_CORE_PER_BOON_PCT = BoonDBClass.IRON_CORE_PER_BOON_PCT
func get_iron_core_count() -> int:
	return BoonEffects.get_iron_core_count()
func get_iron_core_hp_mult() -> float:
	return BoonEffects.get_iron_core_hp_mult()
func get_iron_core_damage_mult() -> float:
	return BoonEffects.get_iron_core_damage_mult()


# Aimed Guard (Carrot + Coconut) — Player.gd queries on crit, observes 2s ICD.
const AIMED_GUARD_OVERSHIELD_DUR = BoonDBClass.AIMED_GUARD_OVERSHIELD_DUR
const AIMED_GUARD_ICD = BoonDBClass.AIMED_GUARD_ICD
func aimed_guard_active() -> bool:
	return BoonEffects.aimed_guard_active()


# Shell Cluster (Coconut + Grape) — mirror-share overshield grants between
# Shino + Bea. Implemented in the overshield-grant call site (Player.gd /
# BeaAI.gd already share an in-script grant helper); this getter just gates.
func shell_cluster_active() -> bool:
	return BoonEffects.shell_cluster_active()


# ---- Run 22 Duo getters ----

# Vital Harvest (Apple + Carrot) — crits heal both heroes for 3% max HP.
# Caller is the crit roll site; each hero calls get_vital_harvest_heal_pct()
# and applies it to their own max HP.
const VITAL_HARVEST_HEAL_PCT = BoonDBClass.VITAL_HARVEST_HEAL_PCT
func vital_harvest_active() -> bool:
	return BoonEffects.vital_harvest_active()
func get_vital_harvest_heal_pct() -> float:
	return BoonEffects.get_vital_harvest_heal_pct()


# Shock Ignition (Pepper + Grape) — Shocked enemies: +25% ignite chance on next
# Pepper-family hit. Implemented as a flat chance boost queried by
# _apply_family_statuses_on_hit when applying burning to a shocked target.
const SHOCK_IGNITION_BURN_CHANCE_BONUS = BoonDBClass.SHOCK_IGNITION_BURN_CHANCE_BONUS
func shock_ignition_active() -> bool:
	return BoonEffects.shock_ignition_active()
func get_shock_ignition_burn_bonus() -> float:
	return BoonEffects.get_shock_ignition_burn_bonus()


# Root & Rot (Potato + Onion) — Rooted enemies take +20% Poison damage.
# Queried by enemy take_damage when poison-DoT ticks and the target is Rooted.
const ROOT_AND_ROT_POISON_AMP = BoonDBClass.ROOT_AND_ROT_POISON_AMP
func root_and_rot_active() -> bool:
	return BoonEffects.root_and_rot_active()
func get_root_and_rot_amp() -> float:
	return BoonEffects.get_root_and_rot_amp()


# Bruise Peel (Banana + Broccoli) — slipping enemy hit → 1.5s Stagger.
# Queried at melee hit site: if target has "slippery" status → apply stagger.
const BRUISE_PEEL_STAGGER_DUR = BoonDBClass.BRUISE_PEEL_STAGGER_DUR
func bruise_peel_active() -> bool:
	return BoonEffects.bruise_peel_active()
func get_bruise_peel_stagger_dur() -> float:
	return BoonEffects.get_bruise_peel_stagger_dur()


# Frost Shield (Watermelon + Coconut) — frozen/chilled attacker deals 15% less
# damage. Queried in Player + BeaAI take_damage when attacker has ice status.
const FROST_SHIELD_DAMAGE_REDUCTION = BoonDBClass.FROST_SHIELD_DAMAGE_REDUCTION
func frost_shield_active() -> bool:
	return BoonEffects.frost_shield_active()
func get_frost_shield_reduction() -> float:
	return BoonEffects.get_frost_shield_reduction()


# Run 23 — 6 new duo getters -----------------------------------------------

# Pepper + Potato — Spicy Landmine: Burning+Rooted enemies take +30% damage.
# Queried in enemy take_damage when target has both "burning" and "root" statuses.
const PEPPER_POTATO_DAMAGE_AMP = BoonDBClass.PEPPER_POTATO_DAMAGE_AMP
func pepper_potato_active() -> bool:
	return BoonEffects.pepper_potato_active()
func get_pepper_potato_amp() -> float:
	return BoonEffects.get_pepper_potato_amp()

# Apple + Watermelon — Orchard Rain: heals cleanse 1 stack of Bleed or Poison.
# Queried at the apply_runstate_modifiers heal path and any direct heal.
# Run 150b — Spring Tide duo (Apple+Watermelon). Orchard Rain retired.
const SPRING_TIDE_RADIUS = BoonDBClass.SPRING_TIDE_RADIUS
const SPRING_TIDE_DURATION = BoonDBClass.SPRING_TIDE_DURATION
const SPRING_TIDE_REGEN_HP = BoonDBClass.SPRING_TIDE_REGEN_HP
func apple_watermelon_active() -> bool:
	return BoonEffects.apple_watermelon_active()

# Onion + Grape — Toxic Combo: finisher hits on Poisoned enemies trigger a Poison burst.
# Queried at melee finisher hit sites when target has "poison" status.
const ONION_GRAPE_POISON_BURST_STACKS = BoonDBClass.ONION_GRAPE_POISON_BURST_STACKS
func onion_grape_active() -> bool:
	return BoonEffects.onion_grape_active()
func get_onion_grape_poison_burst() -> int:
	return BoonEffects.get_onion_grape_poison_burst()

# Banana + Pepper — Slip & Burn: slipping enemies have +40% ignite chance on next hit.
# Queried alongside existing slippery checks in _apply_family_statuses_on_hit.
const BANANA_PEPPER_IGNITE_CHANCE = BoonDBClass.BANANA_PEPPER_IGNITE_CHANCE
func banana_pepper_active() -> bool:
	return BoonEffects.banana_pepper_active()
func get_banana_pepper_ignite_chance() -> float:
	return BoonEffects.get_banana_pepper_ignite_chance()

# Carrot + Watermelon — Refreshing Aim: ranged crits heal crit hero 4% max HP.
# Queried in Player._on_ki_blast_crit (and Bea shuriken hit site when crit).
const CARROT_WATERMELON_RANGED_CRIT_HEAL_PCT = BoonDBClass.CARROT_WATERMELON_RANGED_CRIT_HEAL_PCT
func carrot_watermelon_active() -> bool:
	return BoonEffects.carrot_watermelon_active()
func get_carrot_watermelon_ranged_crit_heal_pct() -> float:
	return BoonEffects.get_carrot_watermelon_ranged_crit_heal_pct()

# Broccoli + Onion — Stinging Greens: Y heavy finishers apply 1 Poison stack.
# Queried at finisher call-site in Player._on_melee_hitbox_body_entered and
# BeaAI._tap_katana after the finisher damage resolves.
const BROCCOLI_ONION_FINISHER_POISON_STACKS = BoonDBClass.BROCCOLI_ONION_FINISHER_POISON_STACKS
func broccoli_onion_active() -> bool:
	return BoonEffects.broccoli_onion_active()
func get_broccoli_onion_finisher_poison() -> int:
	return BoonEffects.get_broccoli_onion_finisher_poison()

# ---------------------------------------------------------------------------


# Run 19 — Legendary Adamantium Husk: overshields persist forever (no
# decay) AND grant Nutshell-style burst + 2s i-frames on break. Player
# reads this at overshield-tick + overshield-break.
func adamantium_active() -> bool:
	return BoonEffects.adamantium_active()


# Hulk Smash (Broccoli L2) — GDD spec (reworked):
#   +100% charge damage, doubled AoE, super-armor during windup+release,
#   pierce-through, 50% faster windup.
# The finisher-shockwave behaviour remains for legacy Player.gd calls but is
# now secondary; the charge-attack amplification is the primary effect.
const HULK_SMASH_CHARGE_DMG_MULT = BoonDBClass.HULK_SMASH_CHARGE_DMG_MULT
const HULK_SMASH_AOE_MULT = BoonDBClass.HULK_SMASH_AOE_MULT
const HULK_SMASH_WINDUP_MULT = BoonDBClass.HULK_SMASH_WINDUP_MULT
# Legacy shockwave constants kept for finisher use.
const HULK_SMASH_BASE_RADIUS = BoonDBClass.HULK_SMASH_BASE_RADIUS
const HULK_SMASH_PER_COMBO_RADIUS = BoonDBClass.HULK_SMASH_PER_COMBO_RADIUS
const HULK_SMASH_BASE_DAMAGE = BoonDBClass.HULK_SMASH_BASE_DAMAGE
const HULK_SMASH_PER_COMBO_DAMAGE = BoonDBClass.HULK_SMASH_PER_COMBO_DAMAGE
func get_hulk_smash_radius(combo_count: int) -> float:
	return BoonEffects.get_hulk_smash_radius(combo_count)
func get_hulk_smash_damage(combo_count: int) -> int:
	return BoonEffects.get_hulk_smash_damage(combo_count)
func get_hulk_smash_charge_mult() -> float:
	return BoonEffects.get_hulk_smash_charge_mult()
func get_hulk_smash_windup_mult() -> float:
	return BoonEffects.get_hulk_smash_windup_mult()
# Big Broccoli — +50% AoE radius / hitbox size on all charge attacks.
func get_big_broccoli_aoe_mult() -> float:
	return BoonEffects.get_big_broccoli_aoe_mult()

# Run 131 — Fury Release (Broccoli Charge): +40% charge hitbox/AoE size for the
# owning hero (per-ninja). The +60% charge damage is applied in each hero's
# _scale_damage charge branch (also gated on ownership).
func get_fury_release_area_mult(who: String) -> float:
	return BoonEffects.get_fury_release_area_mult(who)


# Juicebox of Youth reworked (GDD spec): spawns a pickup every 10s, both heroes
# regen on collect. Kill-heal is removed. This function kept as a stub so
# existing call sites at _apply_charge_kill_heal don't error.
func get_juicebox_kill_heal_pct() -> float:
	return BoonEffects.get_juicebox_kill_heal_pct()


# ---------------------------------------------------------------------------
# Granny's Recipe — +30% to all healing. Stackable with everything.
# ---------------------------------------------------------------------------
func get_heal_mult(who: String = "") -> float:
	return BoonEffects.get_heal_mult(who)

# ---------------------------------------------------------------------------
# Chip-Proof — no single hit may remove more than 15% of max HP.
# Returns the capped hit amount (call from Player/Bea take_damage).
# ---------------------------------------------------------------------------
func chip_proof_cap(amount: int, max_hp: int, who: String = "shino") -> int:
	return BoonEffects.chip_proof_cap(amount, max_hp, who)

# ---------------------------------------------------------------------------
# Seeded Shot — ranged bonus = 1% current HP (flat extra, not a mult).
# ---------------------------------------------------------------------------
func seeded_shot_bonus_dmg(current_hp: int, who: String = "shino") -> int:
	return BoonEffects.seeded_shot_bonus_dmg(current_hp, who)

# ---------------------------------------------------------------------------
# Heavy Harvest — X/heavy attacks gain up to +25% dmg at full HP (linear scale).
# Per-character: only the ninja who picked this boon benefits.
# ---------------------------------------------------------------------------
func get_heavy_harvest_mult(hp_frac: float, who: String = "shino") -> float:
	return BoonEffects.get_heavy_harvest_mult(hp_frac, who)

# ---------------------------------------------------------------------------
# Sweet Harvest — Charge attacks: +20% dmg when above 75% HP.
# Per-character: only the ninja who picked this boon benefits.
# ---------------------------------------------------------------------------
func get_sweet_harvest_mult(hp_frac: float, who: String = "shino") -> float:
	return BoonEffects.get_sweet_harvest_mult(hp_frac, who)

# ---------------------------------------------------------------------------
# Tide Master — Ult cost -20%. Refund 25% of base chi cost on cast.
# ---------------------------------------------------------------------------
# Run 150b (Bruno ruling) — per-picker: only the ninja holding Tide Master
# gets the discount/refund. `who == ""` keeps legacy team-wide behavior for
# any unattributed caller.
func tide_master_ult_cost_mult(who: String = "") -> float:
	return BoonEffects.tide_master_ult_cost_mult(who)

func tide_master_refund(base_cost: int, who: String = "") -> int:
	return BoonEffects.tide_master_refund(base_cost, who)


# ---------------------------------------------------------------------------
# Cluster Mastery — each combo point = 1% chance to double-strike (cap 30%).
# Cluster Cascade — Y finisher primes X for +25% 4s; X finisher primes Y for +50% 4s.
# ---------------------------------------------------------------------------
var _cluster_cascade_y_primed: float = 0.0   # timer; X-next gets +25%
var _cluster_cascade_x_primed: float = 0.0   # timer; Y-next gets +50%

func get_cluster_mastery_double_chance(combo: int) -> float:
	return BoonEffects.get_cluster_mastery_double_chance(combo)

func tick_cluster_cascade(delta: float) -> void:
	if _cluster_cascade_y_primed > 0.0:
		_cluster_cascade_y_primed = max(0.0, _cluster_cascade_y_primed - delta)
	if _cluster_cascade_x_primed > 0.0:
		_cluster_cascade_x_primed = max(0.0, _cluster_cascade_x_primed - delta)

func notify_cluster_cascade_finisher(is_y_finisher: bool) -> void:
	if not cluster_cascade_taken:
		return
	if is_y_finisher:
		_cluster_cascade_y_primed = 4.0   # prime X for 4s
	else:
		_cluster_cascade_x_primed = 4.0   # prime Y for 4s

func get_cluster_cascade_mult(is_y_finisher: bool) -> float:
	return BoonEffects.get_cluster_cascade_mult(is_y_finisher)

# ---------------------------------------------------------------------------
# Overripe — Poison max stacks: base 5 → 7 (each boon level adds 1, cap 10).
# ---------------------------------------------------------------------------
func get_overripe_poison_max() -> int:
	return BoonEffects.get_overripe_poison_max()

# ---------------------------------------------------------------------------
# Rotten Core — callback: poisoned enemy just died → burst stink cloud.
# Returns true if the burst should spawn (caller spawns visual + applies status).
# ---------------------------------------------------------------------------
# ============================================================
# Run 131 — SHARED ENEMY-DEATH BOON HOOK (Bruno's spec: on-death boons fire
# for EVERY enemy type). Call from each enemy's _die() before the corpse
# frees. Covers: Juicebox kill credit, Wave Crash / Brain Freeze, Summer's/
# Winter's End death detonation, Rotten Core, Plague Layer Zonion raising.
# ============================================================
func process_enemy_death_boons(enemy: Node2D) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	var pos: Vector2 = enemy.global_position
	var st: Variant = enemy.get("status") if enemy.has_method("get") else null
	if st == null and enemy.has_node("StatusComponent"):
		st = enemy.get_node("StatusComponent")
	# Run 134 — KILLER ATTRIBUTION (fix 5). Every enemy stamps "last_damager"
	# ("shino"/"bea") on its final damaging hit (melee/ranged/charge/ult/proc; DoT
	# persists the last direct damager). On-kill/on-death boons proc ONLY for the
	# hero who landed the kill — Shino's kill never fires Bea's boon and vice versa.
	# "" (unattributed: traps/environment) fires nothing. This is the single source
	# of kill detection; the old attacker-side hooks were removed to avoid double-proc.
	var killer: String = ""
	if enemy.has_meta("last_damager"):
		killer = str(enemy.get_meta("last_damager"))
	var was_poisoned: bool = st != null and st.has_method("has") and st.has("poison")
	var was_wet: bool = st != null and st.has_method("is_wet") and st.is_wet()
	var was_frost: bool = st != null and st.has_method("is_frostbitten") and st.is_frostbitten()
	# 1. Juicebox of Youth — kill-heal was reworked to a pickup-spawn regen, so
	# juicebox_kill_credit() is a no-op today; broadcast kept harmless for API.
	for p in tree.get_nodes_in_group("player"):
		if p.has_method("juicebox_kill_credit"):
			p.juicebox_kill_credit()
	for b in tree.get_nodes_in_group("bea"):
		if b.has_method("juicebox_kill_credit"):
			b.juicebox_kill_credit()
	# 2. Battle Shell (KO overshield) + Rotten Core (poisoned-death stink cloud):
	# killer-attributed per-hero on-kill boons. The hero handler self-gates on its
	# own shino_has/bea_has + (for Rotten Core) the poisoned-victim check, and does
	# the burst/zone. Routing to the killer replaces both the old attacker-side call
	# AND the old team-wide Rotten Core block below (which leaked across heroes).
	_route_killer_on_kill(killer, pos, was_poisoned)
	# 3. Wave Crash / Brain Freeze — Wet/Frostbitten victim bursts. Killer must OWN it.
	if (was_wet or was_frost) and _killer_has(killer, "wave_crash"):
		var wc_id: String = "chilled" if was_frost else "wet"
		var wc_col: Color = Color(0.55, 0.85, 0.95, 0.9) if was_frost else Color(0.30, 0.70, 0.95, 0.9)
		FX.spawn_burst_particles(pos, wc_col, 14)
		for e in tree.get_nodes_in_group("enemy"):
			if e == enemy or not is_instance_valid(e) or not (e is Node2D):
				continue
			if e.has_method("is_alive") and not e.is_alive():
				continue
			if e.global_position.distance_to(pos) <= 110.0:
				if e.has_method("take_damage"):
					e.take_damage(4, (e.global_position - pos).normalized() * 30.0)
				if e.has_node("StatusComponent"):
					e.get_node("StatusComponent").apply(wc_id, 4.0, 1)
	# 4. Summer's / Winter's End — smaller death detonation (stack only). Killer-owned.
	if (was_wet or was_frost) and _killer_has(killer, "summers_end"):
		var se_id: String = "chilled" if was_frost else "wet"
		for e in tree.get_nodes_in_group("enemy"):
			if e == enemy or not is_instance_valid(e) or not (e is Node2D):
				continue
			if e.has_method("is_alive") and not e.is_alive():
				continue
			if e.global_position.distance_to(pos) <= 110.0 and e.has_node("StatusComponent"):
				e.get_node("StatusComponent").apply(se_id, 4.0, 1)
		FX.spawn_burst_particles(pos, Color(0.40, 0.80, 0.95, 0.85), 10)
	# 5. Plague Layer — poisoned enemies rise as friendly Zonions (10s). Killer-owned.
	if was_poisoned and _killer_has(killer, "plague_layer"):
		var z_script: Script = load("res://scripts/Zonion.gd")
		if z_script != null:
			var zn := Node2D.new()
			zn.set_script(z_script)
			var z_parent: Node = enemy.get_parent()
			if z_parent == null:
				z_parent = tree.current_scene
			if z_parent != null:
				z_parent.add_child(zn)
				zn.global_position = pos
				FX.spawn_burst_particles(pos, Color(0.55, 0.75, 0.30, 0.95), 12)


# Run 134 — does the KILLER hero own `boon`? Used to gate on-death boons to the
# ninja that landed the kill (fix 5). "" (unattributed death) owns nothing.
func _killer_has(killer: String, boon: String) -> bool:
	if killer == "shino":
		return shino_has(boon)
	if killer == "bea":
		return bea_has(boon)
	return false


# Run 134 — route the per-hero on-kill handlers (Battle Shell, Rotten Core) to the
# hero that landed the killing blow, and NEVER the other hero (fix 5). The hero's
# own handler self-gates on shino_has/bea_has, so a killer who doesn't own the boon
# simply no-ops. Called once per enemy death from process_enemy_death_boons.
func _route_killer_on_kill(killer: String, pos: Vector2, was_poisoned: bool) -> void:
	var tree: SceneTree = get_tree()
	if tree == null or killer == "":
		return
	if killer == "shino":
		for p in tree.get_nodes_in_group("player"):
			if is_instance_valid(p) and not p.is_in_group("bea") and p.has_method("_on_enemy_killed"):
				p.set("_last_killed_enemy_pos", pos)
				p.set("_last_killed_enemy_was_poisoned", was_poisoned)
				p._on_enemy_killed()
				break
	elif killer == "bea":
		for b in tree.get_nodes_in_group("bea"):
			if is_instance_valid(b) and b.has_method("_bea_on_enemy_killed"):
				b._bea_on_enemy_killed(pos, was_poisoned)
				break


func rotten_core_on_enemy_death(was_poisoned: bool) -> bool:
	return rotten_core_taken and was_poisoned

# ---------------------------------------------------------------------------
# Spineback — 30% on any damage taken: retaliation earth spike toward attacker.
# Returns flat damage for the spike (0 = no proc).
# ---------------------------------------------------------------------------
func spineback_retaliate(incoming_dmg: int, who: String = "shino") -> int:
	return BoonEffects.spineback_retaliate(incoming_dmg, who)


# Run 134 — Drawn Bow idle thresholds (single source of truth, read by both
# heroes' damage funnels + Bea's kunai). UNCHARGED attacks arm the guaranteed
# crit after 1.5s of not attacking; CHARGED attacks (any hero, melee or ranged
# charge) require 3s idle — anti-cheese so charging while waiting can't cash a
# free huge crit at 1.5s. Timer resets on ANY attack (melee/ranged/charge).
const DRAWN_BOW_IDLE = BoonDBClass.DRAWN_BOW_IDLE
const DRAWN_BOW_IDLE_CHARGED = BoonDBClass.DRAWN_BOW_IDLE_CHARGED

# Run 24 — Sniper's Focus (Carrot Legendary 2): streak-crit bonus.
# `roll_crit_mult` should call `tick_sniper_focus(was_crit)` each hit to maintain streak.
# Separate from roll_crit_mult to keep that function pure.
const SNIPER_FOCUS_STREAK_TRIGGER = BoonDBClass.SNIPER_FOCUS_STREAK_TRIGGER
const SNIPER_FOCUS_BONUS_WINDOW = BoonDBClass.SNIPER_FOCUS_BONUS_WINDOW
const SNIPER_FOCUS_BONUS_DMG = BoonDBClass.SNIPER_FOCUS_BONUS_DMG
# Run 134 — per-hero (`who` = "shino"/"bea"). Each hero maintains its own crit
# streak + bonus window so one ninja's crits never advance the other's buff.
func tick_sniper_focus(was_crit: bool, who: String = "shino", delta: float = 0.0) -> void:
	if not sniper_focus_taken:
		return
	if not sniper_focus_crit_streak.has(who):
		sniper_focus_crit_streak[who] = 0
		sniper_focus_bonus_timer[who] = 0.0
	if delta > 0.0 and float(sniper_focus_bonus_timer[who]) > 0.0:
		sniper_focus_bonus_timer[who] = max(0.0, float(sniper_focus_bonus_timer[who]) - delta)
	if was_crit:
		sniper_focus_crit_streak[who] = int(sniper_focus_crit_streak[who]) + 1
		if int(sniper_focus_crit_streak[who]) >= SNIPER_FOCUS_STREAK_TRIGGER:
			sniper_focus_bonus_timer[who] = SNIPER_FOCUS_BONUS_WINDOW
			sniper_focus_crit_streak[who] = 0
	else:
		sniper_focus_crit_streak[who] = 0
func get_sniper_focus_mult(who: String = "shino") -> float:
	return BoonEffects.get_sniper_focus_mult(who)


# Run 24 — Slip Stream (Banana Legendary): dash through an enemy → leaves a
# 3s Grease field + extends i-frame window. Player.gd _perform_dash reads
# this flag and triggers the grease field spawn when an enemy is intersected.
func slip_stream_active() -> bool:
	return BoonEffects.slip_stream_active()
const SLIP_STREAM_IFRAMES_BONUS = BoonDBClass.SLIP_STREAM_IFRAMES_BONUS


# Run 24 — 5 new Duo getters ---------------------------------------------------

# Grape + Banana — Shocking Slip: Sparked/Bolted enemies give +20% crit chance on that hit.
# Queried BEFORE roll_crit_mult for the hit in _apply_family_statuses_on_hit when target is
# sparked/bolted and Greased Lightning is on.
const GRAPE_BANANA_CRIT_BONUS = BoonDBClass.GRAPE_BANANA_CRIT_BONUS
func grape_banana_active() -> bool:
	return BoonEffects.grape_banana_active()
func get_grape_banana_crit_bonus() -> float:
	return BoonEffects.get_grape_banana_crit_bonus()

# Apple + Pepper — Baked Apple: large heal events ignite nearest enemy.
# Queried at heal-apply sites when heal amount > 10% max HP.
func apple_pepper_active() -> bool:
	return BoonEffects.apple_pepper_active()
const BAKED_APPLE_HEAL_THRESHOLD_PCT = BoonDBClass.BAKED_APPLE_HEAL_THRESHOLD_PCT
const BAKED_APPLE_BURN_STACKS = BoonDBClass.BAKED_APPLE_BURN_STACKS

# Potato + Watermelon — Mud Tide: Wet+Rooted enemies take +25% damage.
# Queried in all 4 enemy take_damage paths (same location as pepper_potato).
const POTATO_WATERMELON_AMP = BoonDBClass.POTATO_WATERMELON_AMP
func potato_watermelon_active() -> bool:
	return BoonEffects.potato_watermelon_active()
func get_potato_watermelon_amp() -> float:
	return BoonEffects.get_potato_watermelon_amp()

# Coconut + Broccoli — Ironwood: while overshield active, +10% damage.
# Queried in _scale_damage / _bea_scale_damage when overshield count > 0.
const COCONUT_BROCCOLI_SHIELD_DMG_BONUS = BoonDBClass.COCONUT_BROCCOLI_SHIELD_DMG_BONUS
func coconut_broccoli_active() -> bool:
	return BoonEffects.coconut_broccoli_active()
func get_coconut_broccoli_dmg_mult(overshield_count: int) -> float:
	return BoonEffects.get_coconut_broccoli_dmg_mult(overshield_count)


# Run 27 — Burning Aim duo (Carrot + Pepper), both arms now wired.
# Arm 1: crits apply 2 Burn stacks (hooked at melee crit-landed sites in
# Player.gd / BeaAI.gd). Arm 2: +1% attack speed AND +1% crit chance per Burn
# stack on any arena enemy (uncapped per spec). Arena stacks cached on a 0.5s
# scan to stay cheap.
var _burning_aim_arena_stacks: int = 0
var _burning_aim_scan_timer: float = 0.0
const BURNING_AIM_STACKS_PER_CRIT = BoonDBClass.BURNING_AIM_STACKS_PER_CRIT
const BURNING_AIM_PCT_PER_STACK = BoonDBClass.BURNING_AIM_PCT_PER_STACK

func _process(delta: float) -> void:
	# Run 134 — decay each hero's Sniper's Focus +50% window (per-hero, fix 3).
	# Runs unconditionally BEFORE the burning-aim early-out so the window actually
	# expires (the old shared timer relied on a delta arg callers never passed).
	if sniper_focus_taken:
		for _sf_who in sniper_focus_bonus_timer.keys():
			if float(sniper_focus_bonus_timer[_sf_who]) > 0.0:
				sniper_focus_bonus_timer[_sf_who] = max(0.0, float(sniper_focus_bonus_timer[_sf_who]) - delta)
	if not burning_aim_active():
		_burning_aim_arena_stacks = 0
		return
	_burning_aim_scan_timer -= delta
	if _burning_aim_scan_timer > 0.0:
		return
	_burning_aim_scan_timer = 0.5
	var n: int = 0
	var tree: SceneTree = get_tree()
	if tree != null:
		for e in tree.get_nodes_in_group("enemy"):
			if is_instance_valid(e) and e.has_node("StatusComponent"):
				var st = e.get_node("StatusComponent")
				if st.has("burning"):
					n += st.get_stacks("burning")
	_burning_aim_arena_stacks = n

func get_burning_aim_crit_chance_bonus() -> float:
	return BoonEffects.get_burning_aim_crit_chance_bonus()

func get_burning_aim_attack_speed_bonus() -> float:
	return BoonEffects.get_burning_aim_attack_speed_bonus()


# Run 27 — Baked Apple duo (Apple + Pepper): heal events > 10% max HP ignite
# the nearest enemy within 200px of the healed hero (2 Burn stacks).
func baked_apple_duo_ignite(tree: SceneTree, pos: Vector2) -> void:
	if not apple_pepper_active() or tree == null:
		return
	var best: Node2D = null
	var best_d: float = 200.0
	for e in tree.get_nodes_in_group("enemy"):
		if e is Node2D and is_instance_valid(e):
			if e.has_method("is_alive") and not e.is_alive():
				continue
			var d: float = e.global_position.distance_to(pos)
			if d <= best_d:
				best = e
				best_d = d
	if best != null and best.has_node("StatusComponent"):
		best.get_node("StatusComponent").apply("burning", 3.0, BAKED_APPLE_BURN_STACKS)

# Carrot + Onion — Toxic Aim: ranged hits against Poisoned enemies get +10% crit chance.
# Queried at Ki Blast / shuriken fire sites if target has "poison" status.
const CARROT_ONION_POISON_CRIT_BONUS = BoonDBClass.CARROT_ONION_POISON_CRIT_BONUS
func carrot_onion_active() -> bool:
	return BoonEffects.carrot_onion_active()
func get_carrot_onion_crit_bonus() -> float:
	return BoonEffects.get_carrot_onion_crit_bonus()


# ---- Run 28 Duo getters — priority active-effect pairs ----

# Apple + Grape — Bunch Bloom: every combo finisher refunds 1 HP (2 at combo 30).
func bunch_bloom_active() -> bool:
	return BoonEffects.bunch_bloom_active()
func get_bunch_bloom_finisher_heal(combo_count: int) -> int:
	return BoonEffects.get_bunch_bloom_finisher_heal(combo_count)

# Carrot + Grape — Master Stroke: combo finishers are guaranteed crits.
# Caller sets RunState.force_next_crit = true before the finisher damage roll.
func master_stroke_active() -> bool:
	return BoonEffects.master_stroke_active()

# Carrot + Pepper — Burning Aim:
#   Arm 1 — crits apply 2 Burn stacks (wired at crit call site).
#   Arm 2 — per Burn stack on any arena enemy: +1% AS and +1% crit chance.
#   burn_count queried per-frame from all enemies (caller caches the count).
const BURNING_AIM_PER_STACK_BONUS = BoonDBClass.BURNING_AIM_PER_STACK_BONUS
func burning_aim_active() -> bool:
	return BoonEffects.burning_aim_active()
func get_burning_aim_bonus(burn_stack_count: int) -> float:
	return BoonEffects.get_burning_aim_bonus(burn_stack_count)

# Broccoli + Pepper — Firebrand: X (heavy) hits apply 2 Burn stacks for 3s.
func firebrand_active() -> bool:
	return BoonEffects.firebrand_active()

# Broccoli + Watermelon — Splash Smash: X / X-charge applies +3 Soaked (or Chilled in Gelato).
func splash_smash_active() -> bool:
	return BoonEffects.splash_smash_active()

# Grape + Watermelon — Cluster Splash: melee finishers burst 2m AoE Soaked/Chilled + +3 combo.
# At combo 30: every Y/X hit triggers the burst.
const CLUSTER_SPLASH_RADIUS = BoonDBClass.CLUSTER_SPLASH_RADIUS
const CLUSTER_SPLASH_STACKS = BoonDBClass.CLUSTER_SPLASH_STACKS
const CLUSTER_SPLASH_COMBO_BONUS = BoonDBClass.CLUSTER_SPLASH_COMBO_BONUS
func cluster_splash_active() -> bool:
	return BoonEffects.cluster_splash_active()
func should_cluster_splash_trigger(is_finisher: bool, combo_count: int) -> bool:
	return BoonEffects.should_cluster_splash_trigger(is_finisher, combo_count)

# Grape + Potato — Stomp Combo: Y finisher → cracked-earth short line; X finisher →
# earthspike short line. At combo 30: both extend to long lines.
func stomp_combo_active() -> bool:
	return BoonEffects.stomp_combo_active()
func get_stomp_combo_line_length(combo_count: int) -> float:
	return BoonEffects.get_stomp_combo_line_length(combo_count)

# Broccoli + Potato — Earthshaker: X finisher / X-charge launches enemies + 3 Cracked Soil.
func earthshaker_active() -> bool:
	return BoonEffects.earthshaker_active()

# ---------------------------------------------------------------------------


# ============================================================
# Elemental Synergy tuning constants (Run 19)
# ============================================================
# Steam Burst (§11 #2 — Pepper × Watermelon water): +15% on the hit + 2m
# steam puff. Implemented as flat follow-up dmg + brief blind (slippery proxy).
const STEAM_BURST_FLAT_DMG = BoonDBClass.STEAM_BURST_FLAT_DMG
const STEAM_BURST_PUFF_RADIUS = BoonDBClass.STEAM_BURST_PUFF_RADIUS
const STEAM_BURST_BLIND_DUR = BoonDBClass.STEAM_BURST_BLIND_DUR

# Thaw Burst (§11 #4 — Pepper × Watermelon Gelato): +15% on the hit. No thaw.
const THAW_BURST_FLAT_DMG = BoonDBClass.THAW_BURST_FLAT_DMG


# ============================================================
# Door Preview / Locked-reward system (Run 24, 2026-06-01)
# ============================================================
# Hades-style door choice: when the player clears a room and picks a boon,
# a DoorChoice overlay shows TWO previews of what the NEXT room's reward
# will be. The player picks a door, the chosen reward is committed, and
# that reward gets dropped (offered) when the next room is cleared.
#
# Categories:
#   "boon"        — show family + rarity tag; resolved into a random boon
#                   of that family/rarity when the next-room offer rolls.
#   "apple_pie"   — Apple Pie consumable card.
#   "apple_juice" — Auto-heal both characters on clear (room 5 + 10 auto).
#   "legendary"   — A Legendary-tier boon (any family).
#   "boss"        — Next room is the boss arena (no shop).
#
# Storage shape (Dictionary):
#   { "type": "boon"|"apple_pie"|"apple_juice"|"legendary"|"boss",
#     "family": "apple"|"coconut"|... (only for "boon"|"legendary"),
#     "rarity": "common"|"uncommon"|"rare"|"epic"|"legendary" (only for "boon"),
#     "label":  human-readable preview string }
#
# Empty dict = no lock (BoonOffer rolls a normal 3-card offer).
#
# Run 27c — the legacy `pending_room_reward` var was REMOVED. It duplicated
# `pending_reward` (the one BoonOffer actually reads via has/peek/consume) and
# silently swallowed writes from World/TestArena, causing the door-says-Coconut
# / room-offers-Grape mismatch. ALWAYS use commit_door_choice() to lock a
# reward; never store it anywhere else.

const DOOR_FAMILIES = BoonDBClass.DOOR_FAMILIES
const DOOR_RARITIES = BoonDBClass.DOOR_RARITIES
# Run 33 (2026-06-09) — ROOM-LEVEL exit cadence (replaces Run 32 per-door rolls).
# Bruno's spec:
#   * Every choice room offers 2 or 3 exits — never 1.
#   * 60% of rooms = BOON room. Exit count: 60% → 2 exits, 40% → 3 exits.
#     Each exit is a DIFFERENT family (no Grape+Grape pairs). Legendary
#     doors can appear within the boon budget (8% per door, prereq-gated).
#   * 40% of rooms = UPGRADE room. Exactly 2 exits: one Pie (+Max HP),
#     one DragonFruit (level up a boon). The taken exit IS the pick.
#   * Forced rooms (Juice 5/10/15/20, Boss 11/21) return a single exit.
#   * Upgrade rooms can't roll until BOTH ninjas own ≥1 boon — a DragonFruit
#     exit with nothing to upgrade silently skipped the pick (Run 32 bug).
const UPGRADE_ROOM_CHANCE = BoonDBClass.UPGRADE_ROOM_CHANCE
const THREE_EXIT_CHANCE = BoonDBClass.THREE_EXIT_CHANCE
const DOOR_LEGENDARY_CHANCE = BoonDBClass.DOOR_LEGENDARY_CHANCE

# Family display colors mirror FAM_COLOR but exposed for DoorChoice UI.
func get_family_color(family: String) -> Color:
	return BoonDBClass.get_family_color(family)

func get_rarity_color(rarity: String) -> Color:
	return BoonDBClass.get_rarity_color(rarity)


# --- Preview builders (single source of truth for the labels) -------------
func _make_pie_preview() -> Dictionary:
	return {"type": "apple_pie", "family": "", "rarity": "", "label": "🥧 PIE EXIT\n+Max HP"}

func _make_dragonfruit_preview() -> Dictionary:
	# 15% chance for the rare +2 Dragon Fruit (fiery variant).
	if randf() < 0.15:
		return {"type": "dragon_fruit_rare", "family": "", "rarity": "", "label": "🔥 DRAGONFRUIT\n+2 Levels to a Boon!"}
	return {"type": "dragon_fruit", "family": "", "rarity": "", "label": "🐉 DRAGONFRUIT\nLevel Up a Boon"}


# Roll ONE boon-room door, excluding families already used by sibling doors
# so no two exits from the same room ever show the same fruit/veg.
func _roll_boon_door(exclude_families: Array) -> Dictionary:
	# Legendary roll — only families where the run has >=3 boons qualify.
	# Without this gate the door label says LEGENDARY but no legendary can
	# actually be delivered inside (the injection prereq check would fail).
	if randf() < DOOR_LEGENDARY_CHANCE:
		var leg_eligible: Array = DOOR_FAMILIES.filter(func(f): \
			return not exclude_families.has(f) and _get_family_count(f) >= LEGENDARY_FAMILY_PREREQ)
		if not leg_eligible.is_empty():
			var leg_fam: String = leg_eligible[randi() % leg_eligible.size()]
			return {"type": "legendary", "family": leg_fam, "rarity": "legendary", "label": "LEGENDARY\n%s" % leg_fam.to_upper()}
		# No family qualifies yet — fall through to a regular boon door.
	var avail_fam: Array = DOOR_FAMILIES.filter(func(f): return not exclude_families.has(f))
	var fam: String = avail_fam[randi() % avail_fam.size()] if not avail_fam.is_empty() else ""
	return {"type": "boon", "family": fam, "rarity": "", "label": fam.to_upper()}


# Run 33 — roll ALL exits for the room AHEAD in one pass. `next_arena_number`
# is the 1-indexed number of the room the player will enter through the doors.
# Returns Array[Dictionary] of previews:
#   - Boss (11/21) and Juice (5/10/15/20) rooms → single forced exit.
#   - 40% → UPGRADE room: [Pie, DragonFruit] in random order (gated until
#     both ninjas own at least one boon — DF needs something to level).
#   - 60% → BOON room: 2 exits (60%) or 3 exits (40%), distinct families.
func roll_room_exits(next_arena_number: int) -> Array:
	# Forced single-exit rooms.
	if next_arena_number >= 21:
		return [{"type": "boss", "family": "", "rarity": "", "label": "🐉 BOSS — TRIHEADED WYRM"}]
	if next_arena_number == 11:
		return [{"type": "boss", "family": "", "rarity": "", "label": "★ BOSS — SHADOW COMMANDER"}]
	if next_arena_number == 5 or next_arena_number == 10 \
			or next_arena_number == 15 or next_arena_number == 20:
		return [{"type": "apple_juice", "family": "apple", "rarity": "", "label": "🧃 JUICE\n(heals both heroes)"}]

	# Upgrade room — exactly 2 exits: Pie + DragonFruit (random side).
	# Gated until both ninjas own >=1 boon so the DF pick is never empty.
	var df_valid: bool = not shino_boon_set.is_empty() and not bea_boon_set.is_empty()
	if df_valid and randf() < UPGRADE_ROOM_CHANCE:
		var pair: Array = [_make_pie_preview(), _make_dragonfruit_preview()]
		pair.shuffle()
		return pair

	# Boon room — 2 or 3 distinct-family exits.
	var count: int = 3 if randf() < THREE_EXIT_CHANCE else 2
	var exits: Array = []
	var used_families: Array = []
	for _i in range(count):
		var door: Dictionary = _roll_boon_door(used_families)
		var door_fam: String = String(door.get("family", ""))
		if door_fam != "":
			used_families.append(door_fam)
		exits.append(door)
	return exits


# ---------------------------------------------------------------------------
# Pending reward API
# ---------------------------------------------------------------------------
# Legacy wrapper — DoorChoice.gd (deprecated overlay) expects exactly 2
# previews. World.gd uses roll_room_exits() directly (Run 33).
func roll_door_pair(next_arena_number: int) -> Array:
	var exits: Array = roll_room_exits(next_arena_number)
	if exits.size() >= 2:
		return exits.slice(0, 2)
	return [exits[0], exits[0].duplicate()]


# Store the player's chosen door reward so the next room's BoonOffer can read it.
func commit_door_choice(preview: Dictionary) -> void:
	pending_reward = preview.duplicate()


func has_pending_reward() -> bool:
	return not pending_reward.is_empty()


func peek_pending_reward() -> Dictionary:
	return pending_reward


func consume_pending_reward() -> Dictionary:
	var out: Dictionary = pending_reward.duplicate()
	pending_reward = {}
	return out


# ===========================================================================
# SAVE / LOAD SERIALIZATION  (used by SaveManager)
# ===========================================================================

func to_save_dict() -> Dictionary:
	return {
		# Boon ownership
		"shino_boon_set":  shino_boon_set.duplicate(),
		"bea_boon_set":    bea_boon_set.duplicate(),
		"boons_taken":     boons_taken.duplicate(),
		"owned_slots":     owned_slots.duplicate(),
		"owned_slots_by_char": owned_slots_by_char.duplicate(true),   # Run 44
		"boon_levels":     boon_levels.duplicate(),
		"boon_rarities":   boon_rarities.duplicate(),   # Run 40 — rolled rarities
		"duos_taken":      duos_taken.duplicate(),      # Run 41 — picked duo cards
		"pending_reward":  pending_reward.duplicate(),
		# Numeric modifiers
		"max_hp_bonus_pct":     max_hp_bonus_pct,
		"apple_pie_stacks":     apple_pie_stacks,
		"apple_juice_consumed_count": apple_juice_consumed_count,
		"damage_mult":          damage_mult,
		"damage_taken_mult":    damage_taken_mult,
		"move_speed_mult":      move_speed_mult,
		"attack_speed_mult":    attack_speed_mult,
		"max_chi_bonus":        max_chi_bonus,
		"charge_kill_heal_pct": charge_kill_heal_pct,
		"melee_lifesteal_pct":  melee_lifesteal_pct,
		"crit_chance":          crit_chance,
		"crit_damage_bonus":    crit_damage_bonus,
		"heal_amp_mult":        heal_amp_mult,
		"dragon_souls":        dragon_souls,
		# Run 117 — Daytime world: karma & family healing (persistent meta)
		"karma_banked":         karma_banked.duplicate(),
		"karma_progress":       karma_progress.duplicate(),
		"family_tier":          family_tier.duplicate(),
		"family_story_layer":   family_story_layer.duplicate(),
		"family_visits":        family_visits.duplicate(),
		"member_visits":        member_visits.duplicate(),
		"full_ending_beaten":   full_ending_beaten,   # Run 143 — Perfect-Town gate
		# Run 43 — Dream World
		"dream_world_mode":     dream_world_mode,
		"current_biome":        current_biome,
		"biome_room":           biome_room,
		"peak_room_type":       peak_room_type,
		"biomes_cleared":       biomes_cleared.duplicate(),
		"gauntlet_cleared":     gauntlet_cleared,
		"run_coins":            run_coins,
		"shop_spark_bought":    shop_spark_bought,
		"sensei_damage_pct":    sensei_damage_pct,
		"sensei_dr_pct":        sensei_dr_pct,
		"sensei_extra_dash":    sensei_extra_dash,
		"sensei_extra_dd":      sensei_extra_dd,
		"sensei_chi_regen":     sensei_chi_regen,
		"sensei_pocket_ranks":  sensei_pocket_ranks,
		"sensei_haggle_ranks":  sensei_haggle_ranks,
		"sensei_reroll_ranks":  sensei_reroll_ranks,
		"sensei_revive_ranks":  sensei_revive_ranks,
		"sensei_boss_dmg_pct":  sensei_boss_dmg_pct,
		"rerolls_left":         rerolls_left,
		"sensei_hp_pct":        sensei_hp_pct,
		"sensei_crit_pct":      sensei_crit_pct,
		"sensei_speed_pct":     sensei_speed_pct,
		"sensei_rarity_ranks":  sensei_rarity_ranks,   # Run 41 — Dragon's Fortune
		"sensei_legendary_ranks": sensei_legendary_ranks,   # Run 42 — Legend Seeker
		"sensei_duo_ranks":       sensei_duo_ranks,         # Run 42 — Twin Spirits
		# Family boon counters
		"broccoli_boons_taken":   broccoli_boons_taken,
		"apple_boons_taken":      apple_boons_taken,
		"coconut_boons_taken":    coconut_boons_taken,
		"carrot_boons_taken":     carrot_boons_taken,
		"grape_boons_taken":      grape_boons_taken,
		"watermelon_boons_taken": watermelon_boons_taken,
		"pepper_boons_taken":     pepper_boons_taken,
		"potato_boons_taken":     potato_boons_taken,
		"banana_boons_taken":     banana_boons_taken,
		"onion_boons_taken":      onion_boons_taken,
		"corrupt_boons_taken":    corrupt_boons_taken,
		"corrupt_accepted":       corrupt_accepted,
		"corrupt_apple_taken":      corrupt_apple_taken,
		"corrupt_coconut_taken":    corrupt_coconut_taken,
		"corrupt_broccoli_taken":   corrupt_broccoli_taken,
		"corrupt_carrot_taken":     corrupt_carrot_taken,
		"corrupt_grape_taken":      corrupt_grape_taken,
		"corrupt_pepper_taken":     corrupt_pepper_taken,
		"corrupt_watermelon_taken": corrupt_watermelon_taken,
		"watermelon_surge_active":  watermelon_surge_active,
		"watermelon_tide_active":   watermelon_tide_active,
		"corrupt_potato_taken":     corrupt_potato_taken,
		"corrupt_banana_taken":     corrupt_banana_taken,
		"corrupt_onion_taken":      corrupt_onion_taken,
		# Run-meta
		"arenas_cleared":    arenas_cleared,
		"loops_completed":   loops_completed,
		"ai_helper_tier":    ai_helper_tier,
		"highest_ai_tier_used_this_run": highest_ai_tier_used_this_run,
		# Carry state
		"carry_hp":   carry_hp,
		"carry_chi":  carry_chi,
		"bea_carry_hp":   bea_carry_hp,
		"bea_carry_chi":  bea_carry_chi,
		"carry_player_controlled_char": carry_player_controlled_char,
		"resume_scene_path": resume_scene_path,
		# Tutorial & story progression
		"tutorial_completed":  tutorial_completed,
		"sensei_lore_tier":    sensei_lore_tier,
		"nights_completed":    nights_completed,
		# DD
		"shino_dd_charges":  shino_dd_charges,
		"bea_dd_charges":    bea_dd_charges,
		"shino_dd_payloads": shino_dd_payloads.duplicate(true),
		"bea_dd_payloads":   bea_dd_payloads.duplicate(true),
		"family_dd_taken":   family_dd_taken,
		# Apple
		"baked_apple_taken":       baked_apple_taken,
		"full_bloom_taken":        full_bloom_taken,
		"ripened_core_taken":      ripened_core_taken,
		"heart_of_orchard_taken":  heart_of_orchard_taken,
		"sweet_dreams_taken":      sweet_dreams_taken,
		"grannys_recipe_taken":    grannys_recipe_taken,
		"apple_hour_taken":        apple_hour_taken,
		"juicebox_of_youth_taken": juicebox_of_youth_taken,
		"heavy_harvest_taken":     heavy_harvest_taken,
		"seeded_shot_taken":       seeded_shot_taken,
		"evergreen_step_taken":    evergreen_step_taken,
		"sweet_harvest_taken":     sweet_harvest_taken,
		# Coconut
		"heavy_stalk_taken":       heavy_stalk_taken,
		"bash_on_hit_chance":      bash_on_hit_chance,
		"bash_bonus_damage":       bash_bonus_damage,
		"shell_breaker_chance":    shell_breaker_chance,
		"overshield_grant_on_dash": overshield_grant_on_dash,
		"overshield_max":          overshield_max,
		"overshield_grant_on_dash_by": overshield_grant_on_dash_by.duplicate(),   # Run 150b
		"overshield_max_by":           overshield_max_by.duplicate(),             # Run 150b
		"stockpile_taken":         stockpile_taken,
		"nutshell_taken":          nutshell_taken,
		"hard_landing_taken":      hard_landing_taken,
		"tough_hide_taken_count":  tough_hide_taken_count,
		"chip_proof_taken":        chip_proof_taken,
		"tough_cookie_taken":      tough_cookie_taken,
		"battle_shell_taken":      battle_shell_taken,
		"coconut_volley_taken":    coconut_volley_taken,
		"coco_slam_taken":         coco_slam_taken,
		"adamantium_husk_taken":   adamantium_husk_taken,
		# Broccoli
		"green_rage_taken":        green_rage_taken,
		"combat_fury_taken":       combat_fury_taken,
		"combat_fury_pct_per_tier": combat_fury_pct_per_tier,
		"iron_will_taken":         iron_will_taken,
		"crushing_blow_taken":     crushing_blow_taken,
		"bash_big_ones_taken":     bash_big_ones_taken,
		"big_broccoli_taken":      big_broccoli_taken,
		"brute_force_taken":       brute_force_taken,
		"slugshot_taken":          slugshot_taken,
		"bull_rush_taken":         bull_rush_taken,
		"fury_release_taken":      fury_release_taken,
		"hulk_smash_taken":        hulk_smash_taken,
		# Carrot
		"hawkeye_taken":           hawkeye_taken,
		"golden_carrot_taken":     golden_carrot_taken,
		"critical_mass_taken":     critical_mass_taken,
		"opening_strike_taken":    opening_strike_taken,
		"finishers_aim_taken":     finishers_aim_taken,
		"keen_eye_taken":          keen_eye_taken,
		"sharpened_tip_taken":     sharpened_tip_taken,
		"bullseye_taken":          bullseye_taken,
		"flanking_strike_taken":   flanking_strike_taken,
		"eagle_eye_taken":         eagle_eye_taken,
		"sniper_focus_taken":      sniper_focus_taken,
		# Grape
		"combo_master_taken":      combo_master_taken,
		"noble_rot_taken":         noble_rot_taken,
		"bunch_bonus_taken":       bunch_bonus_taken,
		"cluster_mastery_taken":   cluster_mastery_taken,
		"cluster_cascade_taken":   cluster_cascade_taken,
		"cluster_strike_taken":    cluster_strike_taken,
		"overhead_crush_taken":    overhead_crush_taken,
		"grape_shot_taken":        grape_shot_taken,
		"vine_lash_taken":         vine_lash_taken,
		"bunch_burst_taken":       bunch_burst_taken,
		"voltaic_engine_taken":    voltaic_engine_taken,
		# Watermelon
		"rising_tide_taken":       rising_tide_taken,
		"hydration_taken":         hydration_taken,
		"tidal_refresh_taken":     tidal_refresh_taken,
		"tide_master_taken":       tide_master_taken,
		"melon_gelato_mode":       melon_gelato_mode,
		"hydro_jab_taken":         hydro_jab_taken,
		"heavy_tide_taken":        heavy_tide_taken,
		"bubble_shot_taken":       bubble_shot_taken,
		"hydro_slide_taken":       hydro_slide_taken,
		"flood_charge_taken":      flood_charge_taken,
		"tidal_tsunami_taken":     tidal_tsunami_taken,
		# Pepper
		"spicy_jab_taken":         spicy_jab_taken,
		"searing_strike_taken":    searing_strike_taken,
		"fire_damage_mult":        fire_damage_mult,
		"lightning_damage_mult":   lightning_damage_mult,
		"slow_cook_taken":         slow_cook_taken,
		"blazing_aura_taken":      blazing_aura_taken,
		"pyromania_taken":         pyromania_taken,
		"hot_footed_taken":        hot_footed_taken,
		"combust_taken":           combust_taken,
		"fireball_taken":          fireball_taken,
		"fire_trail_taken":        fire_trail_taken,
		"inferno_charge_taken":    inferno_charge_taken,
		"inferno_crown_taken":     inferno_crown_taken,
		# Potato
		"starch_armor_taken":      starch_armor_taken,
		"spineback_taken":         spineback_taken,
		"heavy_stance_taken":      heavy_stance_taken,
		"tremor_walk_taken":       tremor_walk_taken,
		"spud_stomp_taken":        spud_stomp_taken,
		"rock_smash_taken":        rock_smash_taken,
		"stone_throw_taken":       stone_throw_taken,
		"tuber_burrow_taken":      tuber_burrow_taken,
		"quake_charge_taken":      quake_charge_taken,
		# Banana
		"tailwind_taken":          tailwind_taken,
		"tailwind_pct":            tailwind_pct,
		"peel_out_taken":          peel_out_taken,
		"extra_banana_taken":      extra_banana_taken,
		"greased_lightning_mode":  greased_lightning_mode,
		"peel_slap_taken":         peel_slap_taken,
		"voltaic_strike_taken":    voltaic_strike_taken,
		"bananarang_taken":        bananarang_taken,
		"zip_dash_taken":          zip_dash_taken,
		"storm_charge_taken":      storm_charge_taken,
		"slip_stream_taken":       slip_stream_taken,
		# Onion
		"layered_defense_taken":   layered_defense_taken,
		"rotten_core_taken":       rotten_core_taken,
		"chronic_reek_taken":      chronic_reek_taken,
		"fermented_strength_taken": fermented_strength_taken,
		"overripe_taken":          overripe_taken,
		"poison_max_stacks_bonus": poison_max_stacks_bonus,
		"pungent_jab_taken":       pungent_jab_taken,
		"tear_strike_taken":       tear_strike_taken,
		"stink_bomb_taken":        stink_bomb_taken,
		"gas_bookends_taken":      gas_bookends_taken,
		"reek_charge_taken":       reek_charge_taken,
		# Corrupt
	}


func load_from_dict(d: Dictionary) -> void:
	reset_run()
	if d.is_empty():
		return
	# Boon ownership
	if d.has("shino_boon_set"):  shino_boon_set  = d["shino_boon_set"].duplicate()
	if d.has("bea_boon_set"):    bea_boon_set    = d["bea_boon_set"].duplicate()
	if d.has("boons_taken"):     boons_taken     = d["boons_taken"].duplicate()
	if d.has("owned_slots"):     owned_slots     = d["owned_slots"].duplicate()
	if d.has("owned_slots_by_char"): owned_slots_by_char = d["owned_slots_by_char"].duplicate(true)   # Run 44
	if d.has("boon_levels"):     boon_levels     = d["boon_levels"].duplicate()
	if d.has("boon_rarities"):   boon_rarities   = d["boon_rarities"].duplicate()   # Run 40
	if d.has("duos_taken"):      duos_taken      = d["duos_taken"].duplicate()      # Run 41
	if d.has("pending_reward"):  pending_reward  = d["pending_reward"].duplicate()
	# Numerics
	if d.has("max_hp_bonus_pct"):     max_hp_bonus_pct     = float(d["max_hp_bonus_pct"])
	if d.has("apple_pie_stacks"):     apple_pie_stacks     = int(d["apple_pie_stacks"])
	if d.has("apple_juice_consumed_count"): apple_juice_consumed_count = int(d["apple_juice_consumed_count"])
	if d.has("damage_mult"):          damage_mult          = float(d["damage_mult"])
	if d.has("damage_taken_mult"):    damage_taken_mult    = float(d["damage_taken_mult"])
	if d.has("move_speed_mult"):      move_speed_mult      = float(d["move_speed_mult"])
	if d.has("attack_speed_mult"):    attack_speed_mult    = float(d["attack_speed_mult"])
	if d.has("max_chi_bonus"):        max_chi_bonus        = int(d["max_chi_bonus"])
	if d.has("charge_kill_heal_pct"): charge_kill_heal_pct = float(d["charge_kill_heal_pct"])
	if d.has("melee_lifesteal_pct"):  melee_lifesteal_pct  = float(d["melee_lifesteal_pct"])
	if d.has("crit_chance"):          crit_chance          = float(d["crit_chance"])
	if d.has("crit_damage_bonus"):    crit_damage_bonus    = float(d["crit_damage_bonus"])
	if d.has("heal_amp_mult"):        heal_amp_mult        = float(d["heal_amp_mult"])
	if d.has("dragon_souls"):        dragon_souls        = int(d["dragon_souls"])
	# Run 117 — Daytime world: karma & family healing (values re-int'd at
	# read sites since JSON round-trips numbers as floats).
	if d.has("karma_banked"):         karma_banked         = d["karma_banked"].duplicate()
	if d.has("karma_progress"):       karma_progress       = d["karma_progress"].duplicate()
	if d.has("family_tier"):          family_tier          = d["family_tier"].duplicate()
	if d.has("family_story_layer"):   family_story_layer   = d["family_story_layer"].duplicate()
	if d.has("family_visits"):        family_visits        = d["family_visits"].duplicate()
	if d.has("member_visits"):        member_visits        = d["member_visits"].duplicate()
	if d.has("full_ending_beaten"):   full_ending_beaten   = bool(d["full_ending_beaten"])
	# Run 43 — Dream World
	if d.has("dream_world_mode"):     dream_world_mode     = bool(d["dream_world_mode"])
	if d.has("current_biome"):        current_biome        = String(d["current_biome"])
	if d.has("biome_room"):           biome_room           = int(d["biome_room"])
	if d.has("peak_room_type"):       peak_room_type       = String(d["peak_room_type"])
	if d.has("biomes_cleared") and d["biomes_cleared"] is Dictionary:
		for bk in biomes_cleared.keys():
			if (d["biomes_cleared"] as Dictionary).has(bk):
				biomes_cleared[bk] = bool(d["biomes_cleared"][bk])
	if d.has("gauntlet_cleared"):     gauntlet_cleared     = bool(d["gauntlet_cleared"])
	if d.has("run_coins"):            run_coins            = int(d["run_coins"])
	if d.has("shop_spark_bought"):    shop_spark_bought    = bool(d["shop_spark_bought"])
	# Sensei Z permanent upgrades (Run 41 — these were saved but never LOADED
	# before this fix; purchases silently vanished on save reload).
	if d.has("sensei_damage_pct"):    sensei_damage_pct    = float(d["sensei_damage_pct"])
	if d.has("sensei_dr_pct"):        sensei_dr_pct        = float(d["sensei_dr_pct"])
	if d.has("sensei_extra_dash"):    sensei_extra_dash    = int(d["sensei_extra_dash"])
	if d.has("sensei_extra_dd"):      sensei_extra_dd      = int(d["sensei_extra_dd"])
	if d.has("sensei_chi_regen"):     sensei_chi_regen     = int(d["sensei_chi_regen"])
	if d.has("sensei_pocket_ranks"):  sensei_pocket_ranks  = int(d["sensei_pocket_ranks"])
	if d.has("sensei_haggle_ranks"):  sensei_haggle_ranks  = int(d["sensei_haggle_ranks"])
	if d.has("sensei_reroll_ranks"):  sensei_reroll_ranks  = int(d["sensei_reroll_ranks"])
	if d.has("sensei_revive_ranks"):  sensei_revive_ranks  = int(d["sensei_revive_ranks"])
	if d.has("sensei_boss_dmg_pct"):  sensei_boss_dmg_pct  = float(d["sensei_boss_dmg_pct"])
	if d.has("rerolls_left"):         rerolls_left         = int(d["rerolls_left"])
	elif d.has("sensei_chi_bonus"):
		# Run 46 migration — old Dragon Chi (+10 max Chi/purchase) → regen ranks.
		sensei_chi_regen = roundi(float(d["sensei_chi_bonus"]) / 10.0)
	if d.has("sensei_hp_pct"):        sensei_hp_pct        = float(d["sensei_hp_pct"])
	if d.has("sensei_crit_pct"):      sensei_crit_pct      = float(d["sensei_crit_pct"])
	if d.has("sensei_speed_pct"):     sensei_speed_pct     = float(d["sensei_speed_pct"])
	# Run 46 migration — old per-tier amounts (8/15/6/8%) don't divide evenly by
	# the new 5%/2% steps; snap to the new grid and clamp to new maxes so the
	# shop's purchase counter stays sane.
	sensei_damage_pct = clampf(snappedf(sensei_damage_pct, 0.05), 0.0, 0.25)
	sensei_dr_pct     = clampf(snappedf(sensei_dr_pct,     0.05), 0.0, 0.25)
	sensei_hp_pct     = clampf(snappedf(sensei_hp_pct,     0.05), 0.0, 0.25)
	sensei_speed_pct  = clampf(snappedf(sensei_speed_pct,  0.05), 0.0, 0.25)
	sensei_crit_pct   = clampf(snappedf(sensei_crit_pct,   0.02), 0.0, 0.10)
	sensei_chi_regen  = clampi(sensei_chi_regen, 0, 5)
	sensei_extra_dash = clampi(sensei_extra_dash, 0, 3)
	sensei_extra_dd   = clampi(sensei_extra_dd, 0, 1)
	if d.has("sensei_rarity_ranks"):  sensei_rarity_ranks  = int(d["sensei_rarity_ranks"])
	if d.has("sensei_legendary_ranks"): sensei_legendary_ranks = int(d["sensei_legendary_ranks"])
	if d.has("sensei_duo_ranks"):       sensei_duo_ranks       = int(d["sensei_duo_ranks"])
	# Family counters
	if d.has("broccoli_boons_taken"):   broccoli_boons_taken   = int(d["broccoli_boons_taken"])
	if d.has("apple_boons_taken"):      apple_boons_taken      = int(d["apple_boons_taken"])
	if d.has("coconut_boons_taken"):    coconut_boons_taken    = int(d["coconut_boons_taken"])
	if d.has("carrot_boons_taken"):     carrot_boons_taken     = int(d["carrot_boons_taken"])
	if d.has("grape_boons_taken"):      grape_boons_taken      = int(d["grape_boons_taken"])
	if d.has("watermelon_boons_taken"): watermelon_boons_taken = int(d["watermelon_boons_taken"])
	if d.has("pepper_boons_taken"):     pepper_boons_taken     = int(d["pepper_boons_taken"])
	if d.has("potato_boons_taken"):     potato_boons_taken     = int(d["potato_boons_taken"])
	if d.has("banana_boons_taken"):     banana_boons_taken     = int(d["banana_boons_taken"])
	if d.has("onion_boons_taken"):      onion_boons_taken      = int(d["onion_boons_taken"])
	if d.has("corrupt_boons_taken"):    corrupt_boons_taken    = int(d["corrupt_boons_taken"])
	if d.has("corrupt_accepted"):       corrupt_accepted       = bool(d.get("corrupt_accepted", false))
	if d.has("corrupt_apple_taken"):      corrupt_apple_taken      = bool(d.get("corrupt_apple_taken", false))
	if d.has("corrupt_coconut_taken"):    corrupt_coconut_taken    = bool(d.get("corrupt_coconut_taken", false))
	if d.has("corrupt_broccoli_taken"):   corrupt_broccoli_taken   = bool(d.get("corrupt_broccoli_taken", false))
	if d.has("corrupt_carrot_taken"):     corrupt_carrot_taken     = bool(d.get("corrupt_carrot_taken", false))
	if d.has("corrupt_grape_taken"):      corrupt_grape_taken      = bool(d.get("corrupt_grape_taken", false))
	if d.has("corrupt_pepper_taken"):     corrupt_pepper_taken     = bool(d.get("corrupt_pepper_taken", false))
	if d.has("corrupt_watermelon_taken"): corrupt_watermelon_taken = bool(d.get("corrupt_watermelon_taken", false))
	if d.has("watermelon_surge_active"):  watermelon_surge_active  = bool(d.get("watermelon_surge_active",  false))
	if d.has("watermelon_tide_active"):   watermelon_tide_active   = bool(d.get("watermelon_tide_active",   false))
	if d.has("corrupt_potato_taken"):     corrupt_potato_taken     = bool(d.get("corrupt_potato_taken", false))
	if d.has("corrupt_banana_taken"):     corrupt_banana_taken     = bool(d.get("corrupt_banana_taken", false))
	if d.has("corrupt_onion_taken"):      corrupt_onion_taken      = bool(d.get("corrupt_onion_taken", false))
	# Run-meta
	if d.has("arenas_cleared"):   arenas_cleared   = int(d["arenas_cleared"])
	if d.has("loops_completed"):  loops_completed  = int(d["loops_completed"])
	if d.has("ai_helper_tier"):   ai_helper_tier   = int(d["ai_helper_tier"])
	if d.has("highest_ai_tier_used_this_run"):
		highest_ai_tier_used_this_run = int(d["highest_ai_tier_used_this_run"])
	else:
		highest_ai_tier_used_this_run = ai_helper_tier
	# Carry
	if d.has("carry_hp"):   carry_hp  = int(d["carry_hp"])
	if d.has("carry_chi"):  carry_chi = int(d["carry_chi"])
	if d.has("bea_carry_hp"):   bea_carry_hp  = int(d["bea_carry_hp"])
	if d.has("bea_carry_chi"):  bea_carry_chi = int(d["bea_carry_chi"])
	if d.has("carry_player_controlled_char"): carry_player_controlled_char = int(d["carry_player_controlled_char"])
	if d.has("resume_scene_path"): resume_scene_path = String(d["resume_scene_path"])
	# Tutorial & story progression
	if d.has("tutorial_completed"):  tutorial_completed  = bool(d["tutorial_completed"])
	if d.has("sensei_lore_tier"):    sensei_lore_tier    = int(d["sensei_lore_tier"])
	if d.has("nights_completed"):    nights_completed    = int(d["nights_completed"])
	# DD
	if d.has("shino_dd_charges"):  shino_dd_charges  = int(d["shino_dd_charges"])
	if d.has("bea_dd_charges"):    bea_dd_charges    = int(d["bea_dd_charges"])
	if d.has("shino_dd_payloads"): shino_dd_payloads = d["shino_dd_payloads"].duplicate(true)
	if d.has("bea_dd_payloads"):   bea_dd_payloads   = d["bea_dd_payloads"].duplicate(true)
	if d.has("family_dd_taken"):   family_dd_taken   = bool(d["family_dd_taken"])
	# Bool flags
	baked_apple_taken       = d.get("baked_apple_taken",       false)
	full_bloom_taken        = d.get("full_bloom_taken",        false)
	ripened_core_taken      = d.get("ripened_core_taken",      false)
	heart_of_orchard_taken  = d.get("heart_of_orchard_taken",  false)
	sweet_dreams_taken      = d.get("sweet_dreams_taken",      false)
	grannys_recipe_taken    = d.get("grannys_recipe_taken",    false)
	apple_hour_taken        = d.get("apple_hour_taken",        false)
	juicebox_of_youth_taken = d.get("juicebox_of_youth_taken", false)
	heavy_harvest_taken     = d.get("heavy_harvest_taken",     false)
	seeded_shot_taken       = d.get("seeded_shot_taken",       false)
	evergreen_step_taken    = d.get("evergreen_step_taken",    false)
	sweet_harvest_taken     = d.get("sweet_harvest_taken",     false)
	heavy_stalk_taken       = d.get("heavy_stalk_taken",       false)
	bash_on_hit_chance      = float(d.get("bash_on_hit_chance",    0.0))
	bash_bonus_damage       = int(d.get("bash_bonus_damage",       0))
	shell_breaker_chance    = float(d.get("shell_breaker_chance",  0.0))
	overshield_grant_on_dash = int(d.get("overshield_grant_on_dash", 0))
	overshield_max          = int(d.get("overshield_max",           0))
	# Run 150b — per-hero overshield config. Legacy saves (no dict): seed BOTH
	# heroes from the old globals so an in-flight run keeps its shields.
	if d.has("overshield_grant_on_dash_by"):
		overshield_grant_on_dash_by = (d["overshield_grant_on_dash_by"] as Dictionary).duplicate()
		overshield_max_by           = (d.get("overshield_max_by", {"shino": 0, "bea": 0}) as Dictionary).duplicate()
	else:
		overshield_grant_on_dash_by = {"shino": overshield_grant_on_dash, "bea": overshield_grant_on_dash}
		overshield_max_by           = {"shino": overshield_max, "bea": overshield_max}
	stockpile_taken         = d.get("stockpile_taken",         false)
	nutshell_taken          = d.get("nutshell_taken",          false)
	hard_landing_taken      = d.get("hard_landing_taken",      false)
	tough_hide_taken_count  = int(d.get("tough_hide_taken_count",  0))
	chip_proof_taken        = d.get("chip_proof_taken",        false)
	tough_cookie_taken      = d.get("tough_cookie_taken",      false)
	battle_shell_taken      = d.get("battle_shell_taken",      false)
	coconut_volley_taken    = d.get("coconut_volley_taken",    false)
	coco_slam_taken         = d.get("coco_slam_taken",         false)
	adamantium_husk_taken   = d.get("adamantium_husk_taken",   false)
	green_rage_taken        = d.get("green_rage_taken",        false)
	combat_fury_taken       = d.get("combat_fury_taken",       false)
	combat_fury_pct_per_tier = float(d.get("combat_fury_pct_per_tier", 0.0))
	iron_will_taken         = d.get("iron_will_taken",         false)
	crushing_blow_taken     = d.get("crushing_blow_taken",     false)
	bash_big_ones_taken     = d.get("bash_big_ones_taken",     false)
	big_broccoli_taken      = d.get("big_broccoli_taken",      false)
	brute_force_taken       = d.get("brute_force_taken",       false)
	slugshot_taken          = d.get("slugshot_taken",          false)
	bull_rush_taken         = d.get("bull_rush_taken",         false)
	fury_release_taken      = d.get("fury_release_taken",      false)
	hulk_smash_taken        = d.get("hulk_smash_taken",        false)
	hawkeye_taken           = d.get("hawkeye_taken",           false)
	golden_carrot_taken     = d.get("golden_carrot_taken",     false)
	critical_mass_taken     = d.get("critical_mass_taken",     false)
	opening_strike_taken    = d.get("opening_strike_taken",    false)
	finishers_aim_taken     = d.get("finishers_aim_taken",     false)
	keen_eye_taken          = d.get("keen_eye_taken",          false)
	sharpened_tip_taken     = d.get("sharpened_tip_taken",     false)
	bullseye_taken          = d.get("bullseye_taken",          false)
	flanking_strike_taken   = d.get("flanking_strike_taken",   false)
	eagle_eye_taken         = d.get("eagle_eye_taken",         false)
	sniper_focus_taken      = d.get("sniper_focus_taken",      false)
	combo_master_taken      = d.get("combo_master_taken",      false)
	noble_rot_taken         = d.get("noble_rot_taken",         false)
	bunch_bonus_taken       = d.get("bunch_bonus_taken",       false)
	cluster_mastery_taken   = d.get("cluster_mastery_taken",   false)
	cluster_cascade_taken   = d.get("cluster_cascade_taken",   false)
	cluster_strike_taken    = d.get("cluster_strike_taken",    false)
	overhead_crush_taken    = d.get("overhead_crush_taken",    false)
	grape_shot_taken        = d.get("grape_shot_taken",        false)
	vine_lash_taken         = d.get("vine_lash_taken",         false)
	bunch_burst_taken       = d.get("bunch_burst_taken",       false)
	voltaic_engine_taken    = d.get("voltaic_engine_taken",    false)
	rising_tide_taken       = d.get("rising_tide_taken",       false)
	hydration_taken         = d.get("hydration_taken",         false)
	tidal_refresh_taken     = d.get("tidal_refresh_taken",     false)
	tide_master_taken       = d.get("tide_master_taken",       false)
	melon_gelato_mode       = d.get("melon_gelato_mode",       false)
	hydro_jab_taken         = d.get("hydro_jab_taken",         false)
	heavy_tide_taken        = d.get("heavy_tide_taken",        false)
	bubble_shot_taken       = d.get("bubble_shot_taken",       false)
	hydro_slide_taken       = d.get("hydro_slide_taken",       false)
	flood_charge_taken      = d.get("flood_charge_taken",      false)
	tidal_tsunami_taken     = d.get("tidal_tsunami_taken",     false)
	spicy_jab_taken         = d.get("spicy_jab_taken",         false)
	searing_strike_taken    = d.get("searing_strike_taken",    false)
	fire_damage_mult        = float(d.get("fire_damage_mult",        1.0))
	lightning_damage_mult   = float(d.get("lightning_damage_mult",   1.0))
	slow_cook_taken         = d.get("slow_cook_taken",         false)
	blazing_aura_taken      = d.get("blazing_aura_taken",      false)
	pyromania_taken         = d.get("pyromania_taken",         false)
	hot_footed_taken        = d.get("hot_footed_taken",        false)
	combust_taken           = d.get("combust_taken",           false)
	fireball_taken          = d.get("fireball_taken",          false)
	fire_trail_taken        = d.get("fire_trail_taken",        false)
	inferno_charge_taken    = d.get("inferno_charge_taken",    false)
	inferno_crown_taken     = d.get("inferno_crown_taken",     false)
	starch_armor_taken      = d.get("starch_armor_taken",      false)
	spineback_taken         = d.get("spineback_taken",         false)
	heavy_stance_taken      = d.get("heavy_stance_taken",      false)
	tremor_walk_taken       = d.get("tremor_walk_taken",       false)
	spud_stomp_taken        = d.get("spud_stomp_taken",        false)
	rock_smash_taken        = d.get("rock_smash_taken",        false)
	stone_throw_taken       = d.get("stone_throw_taken",       false)
	tuber_burrow_taken      = d.get("tuber_burrow_taken",      false)
	quake_charge_taken      = d.get("quake_charge_taken",      false)
	tailwind_taken          = d.get("tailwind_taken",          false)
	tailwind_pct            = float(d.get("tailwind_pct",      0.0))
	peel_out_taken          = d.get("peel_out_taken",          false)
	extra_banana_taken      = d.get("extra_banana_taken",      false)
	greased_lightning_mode  = d.get("greased_lightning_mode",  false)
	peel_slap_taken         = d.get("peel_slap_taken",         false)
	voltaic_strike_taken    = d.get("voltaic_strike_taken",    false)
	bananarang_taken        = d.get("bananarang_taken",        false)
	zip_dash_taken          = d.get("zip_dash_taken",          false)
	storm_charge_taken      = d.get("storm_charge_taken",      false)
	slip_stream_taken       = d.get("slip_stream_taken",       false)
	layered_defense_taken   = d.get("layered_defense_taken",   false)
	rotten_core_taken       = d.get("rotten_core_taken",       false)
	chronic_reek_taken      = d.get("chronic_reek_taken",      false)
	fermented_strength_taken = d.get("fermented_strength_taken", false)
	overripe_taken          = d.get("overripe_taken",          false)
	poison_max_stacks_bonus = int(d.get("poison_max_stacks_bonus", 0))
	pungent_jab_taken       = d.get("pungent_jab_taken",       false)
	tear_strike_taken       = d.get("tear_strike_taken",       false)
	stink_bomb_taken        = d.get("stink_bomb_taken",        false)
	gas_bookends_taken      = d.get("gas_bookends_taken",      false)
	reek_charge_taken       = d.get("reek_charge_taken",       false)
