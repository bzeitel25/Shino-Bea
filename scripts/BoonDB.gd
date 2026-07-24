class_name BoonDB
extends RefCounted
# ============================================================
# BoonDB.gd — single source of truth for boon/duo/synergy/rarity/
# color/door data tables (Phase 2 B1).
#
# Plain data class (NOT an autoload). Holds the PURE-DATA `const`
# tables extracted verbatim from RunState.gd. RunState re-exports
# each one under its original name (const alias) so every existing
# `RunState.<CONST>` reference keeps resolving unchanged.
# ============================================================

# --- Family colors (centralized) ---
const FAM_COLOR: Dictionary = {
	"Apple":      Color(0.95, 0.25, 0.30),
	"Coconut":    Color(0.72, 0.50, 0.22),
	"Broccoli":   Color(0.20, 0.65, 0.30),
	"Carrot":     Color(0.95, 0.55, 0.15),
	"Grape":      Color(0.55, 0.25, 0.75),
	"Watermelon": Color(0.30, 0.70, 0.90),
	"Pepper":     Color(0.95, 0.30, 0.15),
	"Potato":     Color(0.55, 0.40, 0.25),
	"Banana":     Color(0.95, 0.85, 0.20),
	"Onion":      Color(0.70, 0.80, 0.45),
	"Corrupt":    Color(0.80, 0.20, 0.80),   # Run 19 — magenta/purple-black
}

# --- Rarity → border color (Hades-ish progression) ---
const RARITY_COLOR: Dictionary = {
	"common":    Color(0.78, 0.78, 0.82),
	"uncommon":  Color(0.40, 0.85, 0.40),
	"rare":      Color(0.35, 0.55, 0.95),
	"epic":      Color(0.75, 0.40, 0.95),
	"legendary": Color(1.0,  0.85, 0.20),
	"duo":       Color(1.0,  0.62, 0.25),   # Run 41 — warm dual-tone orange
	"corrupt":   Color(0.85, 0.20, 0.85),
}

const RARITY_LABEL: Dictionary = {
	"common":    "COMMON",
	"uncommon":  "UNCOMMON",
	"rare":      "RARE",
	"epic":      "EPIC",
	"legendary": "LEGENDARY",
	"duo":       "DUO",
	"corrupt":   "CORRUPT",
}

const RARITY_CHANCE_EPIC:     float = 0.10
const RARITY_CHANCE_RARE:     float = 0.20
const RARITY_CHANCE_UNCOMMON: float = 0.30

# Effect-bonus multiplier per rarity.
const RARITY_EFFECT_MULT: Dictionary = {
	"common":    1.00,
	"uncommon":  1.30,
	"rare":      1.60,
	"epic":      2.00,
	"legendary": 1.00,
	"corrupt":   1.00,
}

# Dragon Fruit per-level effect bonus, by the boon's rolled rarity.
const RARITY_LEVEL_BONUS: Dictionary = {
	"common":    0.10,
	"uncommon":  0.12,
	"rare":      0.15,
	"epic":      0.20,
	"legendary": 0.10,
	"corrupt":   0.10,
}

# Run 44 — slot trade-up: rarity ladder bump (fixed tiers never bump).
const _RARITY_LADDER: Array = ["common", "uncommon", "rare", "epic"]

# Run 44 — Shellburst flat damage on overshell break, by taken rarity.
const SHELLBURST_DMG_BY_RARITY: Dictionary = {
	"common": 5, "uncommon": 8, "rare": 12, "epic": 16, "legendary": 20,
}

# Per-tier AI behavior table — read by BeaAI / Shino-AI heuristics.
const AI_TIER_TABLE: Dictionary = {
	1: {  # No Help (Spectator)
		"label": "No Help",
		"name": "Spectator",
		"desc": "Just follows and watches. Will not attack. Protect them.",
		"ranged_interval": -1.0,    # never
		"melee_engage_dist": -1.0,  # never
		"charge_chance": 0.0,
		"revive_mode": "circle_only",
	},
	2: {  # Low Help (Sidekick)
		"label": "Low Help",
		"name": "Sidekick",
		"desc": "Throws a ranged shot now and then. Rarely charges.",
		"ranged_interval": 3.5,     # ~1 shot every 3-4s
		"melee_engage_dist": -1.0,  # ranged only
		"charge_chance": 0.05,      # 5% per ranged window when safe
		"revive_mode": "channel_safe_hi",   # HP > AI_CHANNEL_HP_T2 + safe
	},
	3: {  # Helpful (Balanced) — DEFAULT
		"label": "Helpful",
		"name": "Balanced",
		"desc": "Fights at range; steps into melee sometimes. Sparing charges.",
		"ranged_interval": 1.6,
		"melee_engage_dist": 60.0,  # rare melee chip-in
		"melee_chance": 0.25,       # 25% of windows when in range
		"charge_chance": 0.10,
		"revive_mode": "channel_priority",  # HP >= AI_CHANNEL_HP_T3 + safe + dash-cancel
	},
	4: {  # Aggressive (Bruiser)
		"label": "Aggressive",
		"name": "Bruiser",
		"desc": "Goes melee first. Ranged only when she can't close fast.",
		"ranged_interval": 2.2,     # sprinkled while repositioning
		"melee_engage_dist": 140.0, # close gap aggressively
		"melee_chance": 0.85,
		"charge_chance": 0.18,
		"revive_mode": "channel_priority",
	},
	5: {  # Heroic (Beast Mode)
		"label": "Heroic",
		"name": "Beast Mode",
		"desc": "Carries the room. Aggressive melee + ranged + charges.",
		"ranged_interval": 0.9,
		"melee_engage_dist": 200.0, # will chase
		"melee_chance": 1.0,
		"charge_chance": 0.35,
		"revive_mode": "channel_aggressive",  # any HP, dash-cancel
	},
}

# Constants used by revive logic + safety probes.
const AI_CHANNEL_SAFE_RANGE: float = 200.0   # no enemies in this radius = safe
const AI_CHANNEL_HP_T2:      float = 0.70    # Tier 2 channel threshold
const AI_CHANNEL_HP_T3:      float = 0.85    # Tier 3 channel threshold
const AI_DASH_CANCEL_RANGE:  float = 110.0   # T3+ bails channel if enemy windup inside this
const AI_CHARGE_SAFE_RANGE:  float = 140.0   # no enemies within this = OK to channel-up a charge
const AI_HAZARD_AVOID_RADIUS: float = 56.0   # avoid hazard zones within this (added to natural dist)

const BOON_ATTACK_SLOT: Dictionary = {
	# Apple
	"full_bloom_apple": "Y",
	"baked_apple":      "Y/X",
	"ripened_core":     "ALL",
	"heart_of_the_orchard": "ALL",
	"juicebox_of_youth": "ALL",
	# Coconut
	"coconut_bash":     "Y",
	"shell_breaker":    "X",
	"tough_cookie":     "ALL",   # debuff-amp on hits the player applied
	# Broccoli
	"heavy_stalk":      "Y",
	"combat_fury":      "ALL",
	"crushing_blow":    "ALL",
	"bash_big_ones":    "ALL",
	"big_broccoli":     "Y/X",
	"green_rage":       "ALL",
	"hulk_smash":       "Y/X",
	# Carrot
	"hawkeye":          "ALL",
	"golden_carrot":    "ALL",
	"critical_mass":    "ALL",
	# Run 131 — opening_strike retired (merged into Topshot); slot entry removed.
	"finishers_aim":    "ALL",
	"eagle_eye":        "ALL",
	# Grape
	"combo_master":     "ALL",
	"noble_rot":        "Y/X",
	"bunch_bonus":      "ALL",
	"cluster_mastery":  "ALL",
	"cluster_cascade":  "Y/X",
	# Apple slots
	"heavy_harvest":    "X",
	"seeded_shot":      "A",
	"evergreen_step":   "B",
	"sweet_harvest":    "Charge",
	# Coconut slots
	"coconut_volley":   "A",
	"coco_slam":        "Charge",
	# Broccoli slots
	"brute_force":      "X",
	"slugshot":         "A",
	"bull_rush":        "B",
	"fury_release":     "Charge",
	# Carrot slots
	"keen_eye":         "Y",
	"sharpened_tip":    "X",
	"bullseye":         "A",
	# Run 131 — flanking_strike retired (merged into Golden Carrot); slot removed.
	# Grape slots
	"cluster_strike":   "Y",
	"overhead_crush":   "X",
	"grape_shot":       "A",
	"vine_lash":        "B",
	"bunch_burst":      "Charge",
	# Watermelon slots
	"hydro_slide":      "B",
	"flood_charge":     "Charge",
	"rising_tide":      "ALL",
	"tidal_tsunami":    "ALL",
	# Pepper slots
	"fireball":         "A",
	"fire_trail":       "B",
	"inferno_charge":   "Charge",
	# Potato slots
	"spud_stomp":       "Y",
	"rock_smash":       "X",
	"stone_throw":      "A",
	"tuber_burrow":     "B",
	"quake_charge":     "Charge",
	# Banana slots
	"peel_slap":        "Y",
	"voltaic_strike":   "X",
	"bananarang":       "A",
	"zip_dash":         "B",
	"storm_charge":     "Charge",
	"voltaic_engine":   "ALL",
	# Onion slots
	"pungent_jab":      "Y",
	"tear_strike":      "X",
	"stink_bomb":       "A",
	"gas_bookends":     "B",
	"reek_charge":      "Charge",
	# Pepper passives
	"slow_cook":        "ALL",
	"blazing_aura":     "ALL",
	"pyromania":        "ALL",
	"combust":          "ALL",
	"inferno_crown":    "ALL",
	# Potato
	"heavy_stance":     "ALL",
	"tremor_walk":      "ALL",
	# Banana
	"tailwind":         "ALL",
	"static_charge":    "A",   # Run 27e — every-3rd-ranged-hit proc
	# Run 27f — new passives/legendaries
	"long_shot":        "A",
	"drawn_bow":        "ALL",
	"killshot":         "ALL",
	"singed":           "ALL",
	"heatwave":         "Y",
	"petrify":          "X",
	"mountain_king":    "ALL",
	"chronic_plague":   "ALL",
	# Onion
	"chronic_reek":     "ALL",
	"fermented_strength": "ALL",
	"layered_defense":  "ALL",
	# Corrupt
}

const EFFECT_APPLIERS: Dictionary = {
	# Burn sources (Pepper slots + streak stacker + Heatwave patches + Ult + corrupt)
	"burning": ["spicy_jab", "searing_strike", "fireball", "fire_trail",
		"inferno_charge", "heatwave", "pyromania", "inferno_blossom", "corrupt_pepper"],
	# Soaked/Chilled sources (Watermelon slots + Ult)
	"wet": ["hydro_jab", "heavy_tide", "bubble_shot", "hydro_slide",
		"flood_charge", "tidal_surge", "corrupt_watermelon"],
	# Poison sources (Onion slots + aura + Ult + corrupt)
	"poison": ["pungent_jab", "tear_strike", "stink_bomb", "gas_bookends",
		"reek_charge", "layered_defense", "miasma_burst", "corrupt_onion"],
	# Stun/Bash/Vulnerable appliers (Coconut CC family — feeds Tough Cookie)
	"cc_debuff": ["coconut_bash", "shell_breaker", "coconut_volley", "coco_slam",
		"bulwark_strike"],
	# Overshell generators (feeds Shellburst / Stockpile / Adamantium Husk)
	"overshell": ["overshield_dash", "battle_shell", "iron_husk",
		"bulwark_strike"],
	# Slippery/Greased/Sparked/Bolted sources (feeds Greased Lightning switch)
	"banana_status": ["peel_slap", "voltaic_strike", "bananarang", "zip_dash",
		"storm_charge", "slick_trail", "static_charge", "storm_finale",
		"corrupt_banana"],
	# Cracked Soil sources (feeds Petrify's Earthbind upgrade)
	"cracked_soil": ["rock_smash", "quake_charge", "tremor_walk", "terrashock"],
	# Run 127 — crit-chance sources (Carrot). Gates the crit PAYOFF boons.
	"crit_chance": ["keen_eye", "sharpened_tip", "bullseye",
		"golden_carrot", "drawn_bow", "finishers_aim",
		"heart_shot", "topshot", "corrupt_carrot"],
}

const STATUS_SLOT_DMG_BONUS: Dictionary = {
	"Y": 0.10, "X": 0.15, "A": 0.10, "Charge": 0.20,
}
const STATUS_SLOT_DMG_BOONS: Dictionary = {
	# Watermelon (Soaked/Chilled appliers)
	"hydro_jab": "Y", "heavy_tide": "X", "bubble_shot": "A", "flood_charge": "Charge",
	# Banana (Slippery/Greased/Sparked/Bolted appliers)
	# Run 128 — bananarang REMOVED (Bruno: multi-projectile/multi-pass ranged
	# boons — boomerang, Stone Throw, Grape Shot — don't get baseline damage).
	"peel_slap": "Y", "voltaic_strike": "X", "storm_charge": "Charge",
}

# --- Day / Karma / Family data ---
const FAMILIES: Array = ["Apple", "Coconut", "Broccoli", "Carrot", "Grape",
	"Watermelon", "Pepper", "Potato", "Banana", "Onion"]

# Which two families live in each biome's daytime room (Daytime_World_Spec.md §2).
const FAMILY_HOMES: Dictionary = {
	"beach":   ["Coconut", "Watermelon"],
	"jungle":  ["Banana", "Broccoli"],
	"swamp":   ["Onion", "Grape"],
	"caverns": ["Pepper", "Potato"],
	"peaks":   ["Carrot", "Apple"],
}

const KARMA_THRESHOLDS: Array = [10, 25, 50]   # cumulative karma to reach tier 1, 2, 3
const _HEALING_TIER_WEIGHT: Array = [0, 1, 2, 4]   # index = tier
const SENSEI_LORE_THRESHOLDS: Array = [0, 0, 2, 8, 18, 30, 40]

# --- Door / room-roll data ---
const DOOR_FAMILIES: Array = ["apple", "coconut", "broccoli", "carrot", "grape", "watermelon", "pepper", "potato", "banana", "onion"]
const DOOR_RARITIES: Array = ["common", "uncommon", "rare", "epic"]
const UPGRADE_ROOM_CHANCE: float = 0.40        # 40% of choice rooms are Pie+DragonFruit
const THREE_EXIT_CHANCE:   float = 0.40        # 40% of boon rooms show 3 exits (else 2)
const DOOR_LEGENDARY_CHANCE: float = 0.08      # 8% chance of a Legendary door (within boon budget)

const SYNERGY_DEFS: Dictionary = {
	"wet_lightning": {
		"name":         "Wet + Lightning",
		"desc":         "Wet/Drenched enemies take +5%/stack lightning damage (max +25%).",
		"required_any": ["Watermelon", "Banana"],
		"mode_required": "water",
		"color":        Color(0.45, 0.65, 1.0),
	},
	"steam_burst": {
		"name":         "Steam Burst",
		"desc":         "Fire hit on Wet enemy: +15% on the hit + 2m steam puff (blind).",
		"required_any": ["Pepper", "Watermelon"],
		"mode_required": "water",
		"color":        Color(0.85, 0.85, 0.95),
	},
	"thaw_burst": {
		"name":         "Thaw Burst",
		"desc":         "Fire hit on Frostbitten enemy: +15% bonus damage (no thaw).",
		"required_any": ["Pepper", "Watermelon"],
		"mode_required": "gelato",
		"color":        Color(0.95, 0.80, 0.55),
	},
	# Run 27 — remaining 8 synergies wired (Combat_Boons §8.11 full catalog).
	"shatter": {
		"name":         "Shatter (Ice + Earth)",
		"desc":         "Rock attacks on Frostbitten enemies: +10% bonus damage.",
		"required_any": ["Watermelon", "Potato"],
		"mode_required": "gelato",
		"color":        Color(0.60, 0.75, 0.85),
	},
	"brittle_toxin": {
		"name":         "Brittle Toxin",
		"desc":         "Poison-applying hits on Frostbitten enemies: +15% damage.",
		"required_any": ["Watermelon", "Onion"],
		"mode_required": "gelato",
		"color":        Color(0.60, 0.85, 0.70),
	},
	"grounding": {
		"name":         "Grounding (Earth + Lightning)",
		"desc":         "Lightning on Cracked Soil/Earthbound targets chains +1 extra jump.",
		"required_any": ["Potato", "Banana"],
		"color":        Color(0.75, 0.70, 0.40),
	},
	"magma_vein": {
		"name":         "Magma Vein (Earth + Fire)",
		"desc":         "Fire hit on Cracked Soil enemy erupts a small fire patch (3s).",
		"required_any": ["Potato", "Pepper"],
		"color":        Color(0.90, 0.45, 0.20),
	},
	"toxic_soil": {
		"name":         "Toxic Soil (Earth + Poison)",
		"desc":         "Poison DoT on Cracked Soil enemies: +15% damage.",
		"required_any": ["Potato", "Onion"],
		"color":        Color(0.60, 0.65, 0.35),
	},
	"plasma_strike": {
		"name":         "Plasma Strike (Fire + Lightning)",
		"desc":         "Lightning hit on a Burning enemy: +15% bonus damage.",
		"required_any": ["Pepper", "Banana"],
		"color":        Color(0.95, 0.70, 0.30),
	},
	"acid_burn": {
		"name":         "Acid Burn (Fire + Poison)",
		"desc":         "Combust explosions: +10% damage per Poison stack on the target.",
		"required_any": ["Pepper", "Onion"],
		"color":        Color(0.85, 0.65, 0.30),
	},
	"toxic_conduit": {
		"name":         "Toxic Conduit (Poison + Lightning)",
		"desc":         "Lightning chains through a Poisoned target carry 1 Poison stack.",
		"required_any": ["Onion", "Banana"],
		"color":        Color(0.75, 0.85, 0.55),
	},
}

const DUO_DEFS: Dictionary = {
	"iron_core": {
		"name":         "Iron Core",
		"desc":         "Each Apple OR Broccoli boon: +5% max HP & +5% damage (stacks).",
		"required_any": ["Apple", "Broccoli"],
		"color":        Color(0.58, 0.45, 0.30),
	},
	"aimed_guard": {
		"name":         "Aimed Guard",
		"desc":         "Crits grant 1 overshield (3s). 2s ICD to prevent rapid-crit spam.",
		"required_any": ["Carrot", "Coconut"],
		"color":        Color(0.85, 0.55, 0.20),
	},
	"shell_cluster": {
		"name":         "Shell Cluster",
		"desc":         "When either hero gains an overshield, the other also gains 1.",
		"required_any": ["Coconut", "Grape"],
		"color":        Color(0.65, 0.40, 0.50),
	},
	# ---- Run 22 additions (5 new duos) ----
	"vital_harvest": {
		"name":         "Vital Harvest",
		"desc":         "Crits heal both heroes for 3% max HP. Carrot precision meets Apple vitality.",
		"required_any": ["Apple", "Carrot"],
		"color":        Color(0.80, 0.60, 0.20),
	},
	"shock_ignition": {
		"name":         "Shock Ignition",
		"desc":         "Shocked enemies are 25% more likely to ignite on next Pepper hit. Grape lightning primes the blaze.",
		"required_any": ["Pepper", "Grape"],
		"color":        Color(0.90, 0.45, 0.10),
	},
	"root_and_rot": {
		"name":         "Root & Rot",
		"desc":         "Rooted enemies take +20% Poison damage. Earth immobilizes, Onion corrodes.",
		"required_any": ["Potato", "Onion"],
		"color":        Color(0.45, 0.60, 0.25),
	},
	"bruise_peel": {
		"name":         "Bruise Peel",
		"desc":         "Slipping enemies receive a 1.5s Stagger on next melee hit. Banana slip + Broccoli force.",
		"required_any": ["Banana", "Broccoli"],
		"color":        Color(0.82, 0.78, 0.20),
	},
	"frost_shield": {
		"name":         "Frost Shield",
		"desc":         "Frozen or Chilled enemies deal 15% reduced damage when they attack you. Cold slows offense.",
		"required_any": ["Watermelon", "Coconut"],
		"color":        Color(0.40, 0.70, 0.90),
	},
	# Run 24 — 5 new duos
	"grape_banana": {
		"name":         "Shocking Slip",
		"desc":         "Sparked/Bolted (Greased Lightning) enemies grant +20% crit chance on the landing hit.",
		"required_any": ["Grape", "Banana"],
		"color":        Color(0.75, 0.75, 0.20),
	},
	"apple_pepper": {
		"name":         "Baked Apple",
		"desc":         "Heals > 10% max HP in one event ignite the nearest enemy within 200px (2 Burn stacks).",
		"required_any": ["Apple", "Pepper"],
		"color":        Color(0.95, 0.45, 0.25),
	},
	"potato_watermelon": {
		"name":         "Mud Tide",
		"desc":         "Wet + Rooted enemies take +25% damage from all sources.",
		"required_any": ["Potato", "Watermelon"],
		"color":        Color(0.45, 0.65, 0.55),
	},
	"coconut_broccoli": {
		"name":         "Ironwood",
		"desc":         "While an Overshield is active, deal +10% increased damage.",
		"required_any": ["Coconut", "Broccoli"],
		"color":        Color(0.55, 0.72, 0.35),
	},
	"carrot_onion": {
		"name":         "Toxic Aim",
		"desc":         "Ranged hits (A attacks) against Poisoned enemies gain +10% crit chance.",
		"required_any": ["Carrot", "Onion"],
		"color":        Color(0.75, 0.85, 0.30),
	},
	# Run 23 — 6 new duos
	"pepper_potato": {
		"name":         "Scorched Earth",
		"desc":         "Persistent lava patch follows each hero — Burn + Cracked Soil to nearby enemies. Grows while Ingrained.",
		"required_any": ["Pepper", "Potato"],
		"color":        Color(0.85, 0.45, 0.10),
	},
	# Run 150b — Bruno ruling: Apple+Watermelon duo is SPRING TIDE (per the MBR
	# table). Orchard Rain (heal-cleanse) retired — too niche, was never wired.
	"apple_watermelon": {
		"name":         "Spring Tide",
		"desc":         "Charge attacks leave a spring puddle: heroes inside regen HP, enemies get Soaked each second.",
		"required_any": ["Apple", "Watermelon"],
		"color":        Color(0.75, 0.90, 0.40),
	},
	"onion_grape": {
		"name":         "Toxic Combo",
		"desc":         "Poisoned enemies hit by a finisher take an extra 20% Poison damage burst.",
		"required_any": ["Onion", "Grape"],
		"color":        Color(0.65, 0.30, 0.75),
	},
	"banana_pepper": {
		"name":         "Hot Step",
		"desc":         "Dashes leave a burning trail. Slipping enemies have a 40% chance to ignite (2 Burn) on the next hit.",
		"required_any": ["Banana", "Pepper"],
		"color":        Color(0.95, 0.70, 0.10),
	},
	"carrot_watermelon": {
		"name":         "Refreshing Aim",
		"desc":         "Ranged crits (A attacks) restore 4% max HP to the crit hero.",
		"required_any": ["Carrot", "Watermelon"],
		"color":        Color(0.25, 0.85, 0.65),
	},
	"broccoli_onion": {
		"name":         "Stinging Greens",
		"desc":         "Y heavy finishers apply 1 stack of Poison to hit targets.",
		"required_any": ["Broccoli", "Onion"],
		"color":        Color(0.40, 0.72, 0.20),
	},
	# ---- Run 28 additions — remaining 26 pairs (data complete, all 45 pairs now filled) ----
	"apple_banana": {
		"name":         "Peel Restoration",
		"desc":         "Default: slip on a peel heals 1 HP. Greased Lightning: lightning bolt hit heals 1 HP. 1.5s ICD per hero.",
		"required_any": ["Apple", "Banana"],
		"color":        Color(0.95, 0.85, 0.30),
	},
	"apple_coconut": {
		"name":         "Candy Apple",
		"desc":         "Overshields gained at full HP convert into +1 temporary max HP (cap +10). Decay 1/min out of combat.",
		"required_any": ["Apple", "Coconut"],
		"color":        Color(0.90, 0.35, 0.35),
	},
	"apple_grape": {
		# Run 128 — renamed from "Bunch Bloom" (collided with the Grape Ult name).
		"name":         "Sweet Cluster",
		"desc":         "Every combo finisher (final Y or X) refunds 1 HP. At max combo (30), refund doubles to 2 HP.",
		"required_any": ["Apple", "Grape"],
		"color":        Color(0.78, 0.38, 0.72),
	},
	"apple_onion": {
		"name":         "Heirloom",
		"desc":         "All regen zones (HoT, puddle ticks) follow you instead of staying planted.",
		"required_any": ["Apple", "Onion"],
		"color":        Color(0.80, 0.65, 0.28),
	},
	"apple_potato": {
		"name":         "Deep Roots",
		"desc":         "While Ingrained (standing still 1.5s+, in-combat), regen 1 HP/sec.",
		"required_any": ["Apple", "Potato"],
		"color":        Color(0.60, 0.72, 0.30),
	},
	"banana_carrot": {
		"name":         "Night-Vision Peel",
		"desc":         "Slipped/Greased enemies count as flanked — attacking them grants +20% crit chance for 2s.",
		"required_any": ["Banana", "Carrot"],
		"color":        Color(0.90, 0.85, 0.20),
	},
	"banana_coconut": {
		"name":         "Slip 'n Shell",
		"desc":         "When your overshield breaks, emit a knockdown shockwave (2m) that trips nearby enemies.",
		"required_any": ["Banana", "Coconut"],
		"color":        Color(0.85, 0.75, 0.35),
	},
	"banana_onion": {
		"name":         "Slapstink",
		"desc":         "Banana hazards leave a paired poison cloud (1 Poison/sec, 3-4s, scales to hazard size). Greased Lightning: lightning bolts leave the cloud instead.",
		"required_any": ["Banana", "Onion"],
		"color":        Color(0.78, 0.80, 0.25),
	},
	"banana_potato": {
		"name":         "Loose Earth",
		"desc":         "Enemies with any Banana status gain +1 Cracked Soil/sec while active. Earthbind/Petrify drops a bonus banana hazard at their location.",
		"required_any": ["Banana", "Potato"],
		"color":        Color(0.72, 0.55, 0.20),
	},
	"banana_watermelon": {
		"name":         "Tide Storm",
		"desc":         "Soaked enemies gain refreshing Sparked; Chilled gain refreshing Slippery. Lightning applies +1 Soaked; slip events apply +1 Chilled. Drenched expires→Bolted; Frozen thaws→Greased.",
		"required_any": ["Banana", "Watermelon"],
		"color":        Color(0.45, 0.78, 0.90),
	},
	"broccoli_carrot": {
		"name":         "Heavy Crit",
		"desc":         "Charge attacks (Y/X/A-charge) become guaranteed Mega-Crits hitting every AoE enemy. Excess crit chance above 100% converts 1:1 to bonus crit damage for charges.",
		"required_any": ["Broccoli", "Carrot"],
		"color":        Color(0.75, 0.72, 0.20),
	},
	"broccoli_grape": {
		"name":         "Bunchfist",
		"desc":         "X heavy attacks strike 3 times in rapid sequence — each hit resolves separately for status/crits.",
		"required_any": ["Broccoli", "Grape"],
		"color":        Color(0.55, 0.40, 0.70),
	},
	"broccoli_pepper": {
		"name":         "Firebrand",
		"desc":         "Heavy attacks (X) apply 2 Burn stacks for 3s on hit.",
		"required_any": ["Broccoli", "Pepper"],
		"color":        Color(0.88, 0.38, 0.15),
	},
	"broccoli_potato": {
		"name":         "Earthshaker",
		"desc":         "X finisher or X-charge: earthspike launches hit enemies airborne (~0.5s stagger) + 3 Cracked Soil stacks on landing.",
		"required_any": ["Broccoli", "Potato"],
		"color":        Color(0.52, 0.38, 0.20),
	},
	"broccoli_watermelon": {
		"name":         "Splash Smash",
		"desc":         "Every X or X-charge applies +3 Soaked stacks (water) or +3 Chilled stacks (Gelato) to all hit enemies. 2 heavy hits = Drenched/Frozen.",
		"required_any": ["Broccoli", "Watermelon"],
		"color":        Color(0.35, 0.60, 0.88),
	},
	"carrot_grape": {
		# Run 128 — redundancy fix: guarantee arm overlapped Golden Carrot 1:1.
		# Duo keeps the guarantee (works without Golden Carrot) and adds a
		# +50% crit-damage amp on finisher crits so it's never a dead pick.
		"name":         "Master Stroke",
		"desc":         "Combo finishers (final Y or X) are guaranteed crits AND deal +50% bonus crit damage.",
		"required_any": ["Carrot", "Grape"],
		"color":        Color(0.88, 0.68, 0.20),
	},
	"carrot_pepper": {
		"name":         "Burning Aim",
		"desc":         "Crits apply 2 Burn stacks. Per Burn stack on any arena enemy: +1% AS and +1% crit chance (uncapped feedback loop).",
		"required_any": ["Carrot", "Pepper"],
		"color":        Color(0.95, 0.52, 0.10),
	},
	"carrot_potato": {
		"name":         "Headshot",
		"desc":         "While Ingrained (standing still 1.5s+), all attacks gain +25% crit chance and +25% crit damage.",
		"required_any": ["Carrot", "Potato"],
		"color":        Color(0.78, 0.58, 0.22),
	},
	"coconut_onion": {
		"name":         "Smokestack",
		"desc":         "Inside any stink cloud: 1 overshield every 4s. Overshield absorbed: drop a 2.5m Smokestack cloud (5s, 1 Poison/sec + 0.2s ministun/sec). 2s ICD.",
		"required_any": ["Coconut", "Onion"],
		"color":        Color(0.62, 0.52, 0.38),
	},
	"coconut_pepper": {
		"name":         "Hot Shell",
		"desc":         "Overshield absorbs a hit: launch a homing burning coconut at the attacker (small AoE, 2 Burn stacks). 1s ICD.",
		"required_any": ["Coconut", "Pepper"],
		"color":        Color(0.90, 0.48, 0.18),
	},
	"coconut_potato": {
		"name":         "Bunker",
		"desc":         "While Ingrained (standing still 1.5s+), passively generate 1 overshield every 4s. Also raises overshield cap by +1.",
		"required_any": ["Coconut", "Potato"],
		"color":        Color(0.55, 0.48, 0.30),
	},
	"grape_potato": {
		"name":         "Stomp Combo",
		"desc":         "Y finisher: short cracked-earth line (3 tiles, 1 Cracked Soil/enemy). X finisher: earthspike line launching enemies + 2 Cracked Soil each. At combo 30: both extend to 6 tiles.",
		"required_any": ["Grape", "Potato"],
		"color":        Color(0.58, 0.35, 0.60),
	},
	"grape_watermelon": {
		"name":         "Cluster Splash",
		"desc":         "Melee finishers: 2m AoE burst (2 Soaked or 2 Chilled in Gelato). Finishers also grant +3 combo counter. At combo 30: every Y/X hit triggers the burst.",
		"required_any": ["Grape", "Watermelon"],
		"color":        Color(0.45, 0.60, 0.85),
	},
	"onion_pepper": {
		"name":         "Tear Gas",
		"desc":         "All Onion stink clouds and zones also apply 1 Burn stack/sec to enemies inside.",
		"required_any": ["Onion", "Pepper"],
		"color":        Color(0.85, 0.55, 0.15),
	},
	"onion_watermelon": {
		"name":         "Acid Puddle",
		"desc":         "Watermelon zones become hybrid: +1 Soaked/sec + 1 Poison/sec (water) or +1 Chilled/sec + 1 Poison/sec (Gelato). Wet/Frostbitten enemies take 2x Poison DoT.",
		"required_any": ["Onion", "Watermelon"],
		"color":        Color(0.45, 0.72, 0.42),
	},
	"pepper_watermelon": {
		"name":         "Scald",
		"desc":         "Default (Burn+Soaked): Steam stacks to 5 = Scalded (enemy panics 2s). Gelato (Burn+Chilled): Brittle stacks to 5 = Shattered (AoE burst stun around target).",
		"required_any": ["Pepper", "Watermelon"],
		"color":        Color(0.90, 0.42, 0.30),
	},
}

const BOON_POOL: Dictionary = {
	# ------------------------------------------------------------
	# APPLE (Combat_Boons §8.1) — HP/heal tree
	# ------------------------------------------------------------
	"orchard_bloom": {
		"family": "Apple",
		"name":   "Orchard Bloom",
		"desc":   "+20% Max HP.\nLevel up with\nDragon Fruit.",
		"color":  Color(0.95, 0.25, 0.30),
		"rarity": "uncommon",
		"stackable": false,   # Non-stackable per design lock: level via Dragon Fruit instead
	},
	"full_bloom_apple": {
		"family": "Apple",
		"name":   "Full Bloom",
		"desc":   "+15% Y damage\nwhile above 80% HP.",
		"color":  Color(0.95, 0.25, 0.30),
		"rarity": "common",
		"stackable": false,
		"boon_slot": "Y",   # Run 44 — explicit slot tag (older entry predates the field)
	},
	"ripened_core": {
		"family": "Apple",
		"name":   "Ripened Core",
		"desc":   "HP-scaled damage:\n+10% above 50% HP\n+20% above 80% HP\n+30% at full HP.",
		"color":  Color(0.95, 0.25, 0.30),
		"rarity": "uncommon",
		"stackable": false,
	},
	"sweet_dreams": {
		"family": "Apple",
		"name":   "Sweet Dreams",
		"desc":   "Heal 5% max HP\non room clear.",
		"color":  Color(0.95, 0.25, 0.30),
		"rarity": "common",
		"stackable": false,
	},
	"grannys_recipe": {
		"family": "Apple",
		"name":   "Granny's Recipe",
		"desc":   "+30% to all\nhealing you receive.",
		"color":  Color(0.95, 0.25, 0.30),
		"rarity": "uncommon",
		"stackable": false,
	},
	# Run 150b — "apple_hour" RETIRED (Bruno): hard-to-justify pick, few timed
	# buffs to extend, was never wired. Def removed so it never appears in
	# offers; the save flag remains for old-save compatibility. Slot reserved
	# for a future Apple boon if the family needs another card.
	"fall_harvest": {
		"family": "Apple",
		"name":   "Fall Harvest",
		"desc":   "Charge-attack kills\nheal 1% max HP.",
		"color":  Color(0.95, 0.25, 0.30),
		"rarity": "uncommon",
		"stackable": false,
	},
	"baked_apple": {
		"family": "Apple",
		"name":   "Baked Apple",
		"desc":   "Combo finishers start\n1 HP/sec regen for 5s\n(refreshes).",
		"color":  Color(0.95, 0.25, 0.30),
		"rarity": "common",
		"stackable": false,
	},
	"cider_mercy": {
		"family": "Apple",
		"name":   "Cider Mercy",
		"desc":   "+1 Death-Defiance.\nRevive: 50% HP refill\n+ regen for 5s.",
		"color":  Color(0.95, 0.25, 0.30),
		"rarity": "uncommon",
		"stackable": false,
		"family_dd": true,
	},
	"heart_of_the_orchard": {
		"family": "Apple",
		"name":   "Heart of the Orchard",
		"desc":   "+100% damage\nabove 80% HP.\n+200% at full HP.",
		"color":  Color(0.95, 0.25, 0.30),
		"rarity": "legendary",
		"stackable": false,
	},
	# ------------------------------------------------------------
	# COCONUT (Combat_Boons §8.2) — Toughness/disruption
	# ------------------------------------------------------------
	"coconut_bash": {
		"family": "Coconut",
		"name":   "Coconut Bash",
		"desc":   "20% on Y hit:\nBash (1s stun)\n+ bonus damage.",
		"color":  Color(0.72, 0.50, 0.22),
		"rarity": "common",
		"stackable": false,
		"boon_slot": "Y",   # Run 44
	},
	"shell_breaker": {
		"family": "Coconut",
		"name":   "Shell Breaker",
		"desc":   "30% on X hit:\nVulnerable +25%\nfor 5s.",
		"color":  Color(0.72, 0.50, 0.22),
		"rarity": "uncommon",
		"stackable": false,
		"boon_slot": "X",   # Run 44
	},
	"overshield_dash": {
		"family": "Coconut",
		"name":   "Hardshell Roll",
		"desc":   "Dash grants an\novershield charge\n(more at higher rarity).",
		"color":  Color(0.72, 0.50, 0.22),
		"rarity": "rare",
		"stackable": false,
		"boon_slot": "B",   # Run 44
	},
	# Run 44 — was the last "stackable: true" boon in the pool (old-GDD
	# iteration). Under Run 40 rolled-rarity, every non-fixed-tier boon is
	# single-pick + Dragon Fruit leveling. Stackable let it re-offer after
	# being taken — Bruno saw two Tough Hides in one run.
	"tough_hide": {
		"family": "Coconut",
		"name":   "Tough Hide",
		"desc":   "-15% damage taken\nfrom all sources.",
		"color":  Color(0.72, 0.50, 0.22),
		"rarity": "common",
		"stackable": false,
	},
	"chip_proof": {
		"family": "Coconut",
		"name":   "Chip-Proof",
		"desc":   "No single hit removes\nmore than 15% max HP.",
		"color":  Color(0.72, 0.50, 0.22),
		"rarity": "rare",
		"stackable": false,
	},
	# Run 136 — "shell_wall" retired: 1:1 redundant with Bulwark Strike (Ult
	# slot grants max overshells to both heroes). Removed from pool + wiring.
	"hard_landing": {
		"family": "Coconut",
		"name":   "Hard Landing",
		"desc":   "-50% knockback taken.\nStun-immune\nwhile charging.",
		"color":  Color(0.72, 0.50, 0.22),
		"rarity": "common",
		"stackable": false,
	},
	# Run 44 — renamed from old-GDD "Nutshell" to canonical Shellburst
	# (Combat_Boons §8.2 passive 5). Same id to keep saves/wiring intact.
	"nutshell": {
		"family": "Coconut",
		"name":   "Shellburst",
		"desc":   "Overshell break:\ndamage + 0.3s ministun\nto nearby enemies.",
		"color":  Color(0.72, 0.50, 0.22),
		"rarity": "common",
		"stackable": false,
		"requires_effect": "overshell",   # Run 44 — needs an overshell generator
	},
	"tough_cookie": {
		"family": "Coconut",
		"name":   "Tough Cookie",
		"desc":   "Stunned, Bashed or\nVulnerable enemies take\n+15% damage.",
		"color":  Color(0.72, 0.50, 0.22),
		"rarity": "rare",
		"stackable": false,
		"requires_effect": "cc_debuff",   # Run 44 — needs a Stun/Bash/Vuln applier
	},
	"battle_shell": {
		"family": "Coconut",
		"name":   "Battle Shell",
		"desc":   "KO or X-finisher:\ngain 1 overshield\ncharge (3s).",
		"color":  Color(0.72, 0.50, 0.22),
		"rarity": "uncommon",
		"stackable": false,
	},
	"stockpile": {
		"family": "Coconut",
		"name":   "Stockpile",
		"desc":   "Overshield cap +1\n(1 → 2).",
		"color":  Color(0.72, 0.50, 0.22),
		"rarity": "uncommon",
		"stackable": false,
		"requires_effect": "overshell",   # Run 44 — cap is useless without a generator
	},
	"iron_husk": {
		"family": "Coconut",
		"name":   "Iron Husk",
		"desc":   "+1 Death-Defiance.\nRevive: 3 overshields\nboth + stun nearby 1.5s.",
		"color":  Color(0.72, 0.50, 0.22),
		"rarity": "uncommon",
		"stackable": false,
		"family_dd": true,
	},
	# ------------------------------------------------------------
	# BROCCOLI (Combat_Boons §8.3) — Strength / Hulk
	# ------------------------------------------------------------
	"heavy_stalk": {
		"family": "Broccoli",
		"name":   "Heavy Stalk",
		"boon_slot": "Y",   # Run 44
		"desc":   "+15% Y damage\n+10% Y attack speed.",
		"color":  Color(0.20, 0.65, 0.30),
		"rarity": "common",
		"stackable": false,
	},
	"stalk_of_might": {
		"family": "Broccoli",
		"name":   "Stalk of Might",
		"desc":   "+5% damage per\nBroccoli boon owned.",
		"color":  Color(0.20, 0.65, 0.30),
		"rarity": "uncommon",
		"stackable": false,
	},
	"green_rage": {
		"family": "Broccoli",
		"name":   "Green Rage",
		"desc":   "Below 50% HP: +30% dmg.\nBelow 25% HP: +50% dmg\n+ 25% damage reduction.",
		"color":  Color(0.20, 0.65, 0.30),
		"rarity": "rare",
		"stackable": false,
	},
	"combat_fury": {
		"family": "Broccoli",
		"name":   "Combat Fury",
		"desc":   "Consecutive melee hits\nstack +5% damage,\nup to 5 stacks.",
		"color":  Color(0.20, 0.65, 0.30),
		"rarity": "uncommon",
		"stackable": false,
	},
	"iron_will": {
		"family": "Broccoli",
		"name":   "Iron Will",
		"desc":   "Every 10s, fully defy\nthe next incoming CC.",
		"color":  Color(0.20, 0.65, 0.30),
		"rarity": "rare",
		"stackable": false,
	},
	"crushing_blow": {
		"family": "Broccoli",
		"name":   "Crushing Blow",
		"desc":   "+50% damage to enemies\nbelow 30% HP.",
		"color":  Color(0.20, 0.65, 0.30),
		"rarity": "uncommon",
		"stackable": false,
	},
	"bash_big_ones": {
		"family": "Broccoli",
		"name":   "Bash the Big Ones",
		"desc":   "+25% damage to\nelites and bosses.",
		"color":  Color(0.20, 0.65, 0.30),
		"rarity": "uncommon",
		"stackable": false,
	},
	"big_broccoli": {
		"family": "Broccoli",
		"name":   "Big Broccoli",
		"desc":   "+50% melee reach.\n+50% projectile size.",
		"color":  Color(0.20, 0.65, 0.30),
		"rarity": "uncommon",
		"stackable": false,
	},
	"green_vengeance": {
		"family": "Broccoli",
		"name":   "Green Vengeance",
		"desc":   "+1 Death-Defiance.\nRevive: +50% damage\nfor 5-7s.",
		"color":  Color(0.20, 0.65, 0.30),
		"rarity": "uncommon",
		"stackable": false,
		"family_dd": true,
	},
	# ------------------------------------------------------------
	# APPLE slot boons (X/A/B/Charge — Y full_bloom_apple already exists)
	# ------------------------------------------------------------
	"heavy_harvest": {
		"family": "Apple", "name": "Heavy Harvest",
		"desc":   "X damage scales\nwith HP, up to\n+25% at full HP.",
		"color":  Color(0.95, 0.25, 0.30), "rarity": "uncommon", "stackable": false, "boon_slot": "X",
	},
	"seeded_shot": {
		"family": "Apple", "name": "Seeded Shot",
		"desc":   "Ranged hits deal\n+1% max HP\nbonus damage.",
		"color":  Color(0.95, 0.25, 0.30), "rarity": "common", "stackable": false, "boon_slot": "A",
	},
	"evergreen_step": {
		"family": "Apple", "name": "Evergreen Step",
		"desc":   "First hit after a dash\nheals 1% max HP.\n(6s cooldown)",
		"color":  Color(0.95, 0.25, 0.30), "rarity": "uncommon", "stackable": false, "boon_slot": "B",
	},
	"sweet_harvest": {
		"family": "Apple", "name": "Sweet Harvest",
		"desc":   "Charge attacks +20% dmg\nabove 75% HP, heal\n1% max HP. (8s CD)",
		"color":  Color(0.95, 0.25, 0.30), "rarity": "rare", "stackable": false, "boon_slot": "Charge",
	},
	# --- Coconut slot boons (A + Charge) ---
	"coconut_volley": {
		"family": "Coconut", "name": "Coconut Volley",
		"desc":   "30% on ranged hit:\nMini-Bash (0.4s stun)\n+ bonus damage.",
		"color":  Color(0.72, 0.50, 0.22), "rarity": "uncommon", "stackable": false, "boon_slot": "A",
	},
	"coco_slam": {
		"family": "Coconut", "name": "Coco-Slam",
		"desc":   "Charge ends in a\nshell-bash: ministun\n+ Vulnerable 3s.",
		"color":  Color(0.72, 0.50, 0.22), "rarity": "rare", "stackable": false, "boon_slot": "Charge",
	},
	# --- Broccoli slot boons (X/A/B/Charge) ---
	"brute_force": {
		"family": "Broccoli", "name": "Brute Force",
		"desc":   "+35% X damage.\nHits create a small\nAoE shockwave.",
		"color":  Color(0.20, 0.65, 0.30), "rarity": "uncommon", "stackable": false, "boon_slot": "X",
	},
	"slugshot": {
		"family": "Broccoli", "name": "Slugshot",
		"desc":   "Slower ranged shot,\n+50% damage,\npierces all in a line.",
		"color":  Color(0.20, 0.65, 0.30), "rarity": "uncommon", "stackable": false, "boon_slot": "A",
	},
	"bull_rush": {
		"family": "Broccoli", "name": "Bull Rush",
		"desc":   "Dashing into enemies\ndeals contact damage\n(scales with distance).",
		"color":  Color(0.20, 0.65, 0.30), "rarity": "common", "stackable": false, "boon_slot": "B",
	},
	"fury_release": {
		"family": "Broccoli", "name": "Fury Release",
		"desc":   "Charge attacks deal\n+60% damage and\nhit a wider area.",
		"color":  Color(0.20, 0.65, 0.30), "rarity": "rare", "stackable": false, "boon_slot": "Charge",
	},
	# ------------------------------------------------------------
	# CARROT (Combat_Boons §8.4) — Precision/crits
	# Replaces Run-15 junk: quickfoot + crit_eye.
	# ------------------------------------------------------------
	"keen_eye": {
		"family": "Carrot", "name": "Keen Eye",
		"desc":   "Y attacks:\n+15% crit chance\n+10% crit damage.",
		"color":  Color(0.95, 0.55, 0.15), "rarity": "common", "stackable": false, "boon_slot": "Y",
	},
	"sharpened_tip": {
		"family": "Carrot", "name": "Sharpened Tip",
		"desc":   "X attacks:\n+25% crit chance\n+20% crit damage.",
		"color":  Color(0.95, 0.55, 0.15), "rarity": "uncommon", "stackable": false, "boon_slot": "X",
	},
	"bullseye": {
		"family": "Carrot", "name": "Bullseye",
		"desc":   "Ranged attacks:\n+20% crit chance\n+30% crit damage.",
		"color":  Color(0.95, 0.55, 0.15), "rarity": "uncommon", "stackable": false, "boon_slot": "A",
	},
	# Run 131 — RETIRED: flanking_strike (dash-spam perma-crit) merged INTO
	# golden_carrot. Golden Carrot is now the single dash-crit boon: a dash arms
	# the next combo finisher as a guaranteed crit (one finisher per dash).
	# Entry removed from the pool so it is never offered.
	"hawkeye": {
		"family": "Carrot",
		"name":   "Hawkeye",
		"desc":   "+25% crit damage\non every crit.",
		"color":  Color(0.95, 0.55, 0.15),
		"rarity": "common",
		"stackable": false,
		"requires_effect": "crit_chance",   # Run 127 — needs a crit source
	},
	"golden_carrot": {
		"family": "Carrot",
		"name":   "Golden Carrot",
		"desc":   "After a dash, your next\ncombo finisher (final Y\nor X) is a guaranteed crit.",
		"color":  Color(0.95, 0.55, 0.15),
		"rarity": "uncommon",
		"stackable": false,
	},
	"finishers_aim": {
		"family": "Carrot",
		"name":   "Finisher's Aim",
		"desc":   "Combo finishers gain\n+50% crit chance.",
		"color":  Color(0.95, 0.55, 0.15),
		"rarity": "rare",
		"stackable": false,
		"boon_slot": "Charge",   # Run 44 — explicit slot tag
	},
	"critical_mass": {
		"family": "Carrot",
		"name":   "Critical Mass",
		"desc":   "Crits: +15% move &\nattack speed for 4s,\nstacks to 3.",
		"color":  Color(0.95, 0.55, 0.15),
		"rarity": "rare",
		"stackable": false,
		"requires_effect": "crit_chance",   # Run 127 — needs a crit source
	},
	# Run 131 — RETIRED: opening_strike (first hit on a full-HP enemy = crit)
	# merged INTO the legendary Topshot, which is now the single "opener" boon:
	# the first hit on each NEW enemy (charge attacks included) is a guaranteed
	# Mega-Crit. Entry removed from the pool so it is never offered.
	"heart_shot": {
		"family": "Carrot",
		"name":   "Heart Shot",
		"desc":   "+1 Death-Defiance.\nRevive: 100% crit chance\nfor 10-20s.",
		"color":  Color(0.95, 0.55, 0.15),
		"rarity": "uncommon",
		"stackable": false,
		"family_dd": true,
	},
	# ------------------------------------------------------------
	# GRAPE (Combat_Boons §8.5) — Combo/cluster
	# ---- Grape slot boons (all 5 slots) ----
	"cluster_strike": {
		"family": "Grape", "name": "Cluster Strike",
		"desc":   "Y finisher: +60% dmg\n+ Vinewrap (root 2s)\nto all hit.",
		"color":  Color(0.55, 0.25, 0.75), "rarity": "uncommon", "stackable": false, "boon_slot": "Y",
	},
	"overhead_crush": {
		"family": "Grape", "name": "Overhead Crush",
		"desc":   "X finisher: bonus dmg\n+ Vinewrap (root 2s)\nto all hit.",
		"color":  Color(0.55, 0.25, 0.75), "rarity": "uncommon", "stackable": false, "boon_slot": "X",
	},
	"grape_shot": {
		"family": "Grape", "name": "Grape Shot",
		"desc":   "Ranged splits on hit:\n1 main + 2 shots\nat 40% damage.",
		"color":  Color(0.55, 0.25, 0.75), "rarity": "common", "stackable": false, "boon_slot": "A",
	},
	"vine_lash": {
		"family": "Grape", "name": "Vine Lash",
		"desc":   "Attack within 0.5s\nof a dash: fire 3\nbonus vines in a cone.",
		"color":  Color(0.55, 0.25, 0.75), "rarity": "rare", "stackable": false, "boon_slot": "B",
	},
	"bunch_burst": {
		"family": "Grape", "name": "Bunch Burst",
		"desc":   "Charge attacks hit\n2 extra times at\n50% damage.",
		"color":  Color(0.55, 0.25, 0.75), "rarity": "rare", "stackable": false, "boon_slot": "Charge",
	},
	# ------------------------------------------------------------
	"combo_master": {
		"family": "Grape",
		"name":   "Combo Master",
		"desc":   "+1% damage per\ncombo point on all hits.",
		"color":  Color(0.55, 0.25, 0.75),
		"rarity": "common",
		"stackable": false,
	},
	"noble_rot": {
		"family": "Grape",
		"name":   "Noble Rot",
		"desc":   "Combo finishers gain\nan extra +1% damage\nper combo point.",
		"color":  Color(0.55, 0.25, 0.75),
		"rarity": "uncommon",
		"stackable": false,
	},
	"bunch_bonus": {
		"family": "Grape",
		"name":   "Bunch Bonus",
		"desc":   "+25% damage while\n2+ enemies are near.",
		"color":  Color(0.55, 0.25, 0.75),
		"rarity": "common",
		"stackable": false,
	},
	"cluster_mastery": {
		"family": "Grape",
		"name":   "Cluster Mastery",
		"desc":   "1% per combo point to\nstrike twice (max 30%).\nKills refund Chi.",
		"color":  Color(0.55, 0.25, 0.75),
		"rarity": "rare",
		"stackable": false,
	},
	"cluster_cascade": {
		"family": "Grape",
		"name":   "Cluster Cascade",
		"desc":   "Y finisher buffs next\nX finisher +25% (4s).\nX finisher buffs next\nY finisher +50% (4s).",
		"color":  Color(0.55, 0.25, 0.75),
		"rarity": "rare",
		"stackable": false,
	},
	"vintage_surge": {
		"family": "Grape",
		"name":   "Vintage Surge",
		"desc":   "+1 Death-Defiance.\nRevive: combo locks at\n30, no decay (10-20s).",
		"color":  Color(0.55, 0.25, 0.75),
		"rarity": "uncommon",
		"stackable": false,
		"family_dd": true,
	},
	# ------------------------------------------------------------
	# WATERMELON (Combat_Boons §8.7) — Chi-economy + water/ice
	# SLOT BOONS (no prereq — these ARE the entry boons that apply Wet).
	# Scalers (Rising Tide, Tidal Refresh, Tide Master) require prereq_family
	# so they never appear before the player has a Wet source.
	# ------------------------------------------------------------
	# Run 44 — Watermelon slot names reconciled to Combat_Boons §8.7
	# (old-GDD iterations: Hydro Jab / Heavy Tide / Bubble Shot / Flood Charge).
	# Ids unchanged for save/wiring compat.
	"hydro_jab": {
		"family": "Watermelon",
		"name":   "Rind Slap",
		"desc":   "Y hits: +10% damage\n+ 1 Soaked stack.\n(5 stacks → Drenched)",
		"color":  Color(0.30, 0.70, 0.90),
		"rarity": "common",
		"stackable": false,
		"boon_slot": "Y",
	},
	"heavy_tide": {
		"family": "Watermelon",
		"name":   "Splash Crush",
		"desc":   "X hits: +15% damage\n+ 2 Soaked stacks.",
		"color":  Color(0.30, 0.70, 0.90),
		"rarity": "uncommon",
		"stackable": false,
		"boon_slot": "X",
	},
	"bubble_shot": {
		"family": "Watermelon",
		"name":   "Seed Spit",
		"desc":   "Ranged: +10% damage,\n2 Soaked + splash knocks\nback nearby enemies\n+ slowing puddle.",
		"color":  Color(0.30, 0.70, 0.90),
		"rarity": "uncommon",
		"stackable": false,
		"boon_slot": "A",
	},
	"hydration": {
		"family": "Watermelon",
		"name":   "Hydration",
		"desc":   "+0.5 Chi/sec in combat,\nramps to +1.5/sec\nafter 8s.",
		"color":  Color(0.30, 0.70, 0.90),
		"rarity": "uncommon",
		"stackable": false,
	},
	"rising_tide": {
		"family": "Watermelon",
		"name":   "Rising Tide",
		"desc":   "Wet/Frostbitten enemies\ntake +15% damage.",
		"color":  Color(0.30, 0.70, 0.90),
		"rarity": "common",
		"stackable": false,
		"prereq_family": "Watermelon",   # requires a Wet source first
		"requires_effect": "wet",   # Run 44 — strict: a real Wet applier
	},
	"tidal_refresh": {
		"family": "Watermelon",
		"name":   "Tidal Refresh",
		"desc":   "+2 Chi when you apply\nWet/Chilled.\n(3s per target)",
		"color":  Color(0.30, 0.70, 0.90),
		"rarity": "uncommon",
		"stackable": false,
		"prereq_family": "Watermelon",   # requires a Wet source first
		"requires_effect": "wet",   # Run 44
	},
	"tide_master": {
		"family": "Watermelon",
		"name":   "Tide Master",
		"desc":   "Ult cost -20%.\nRefunds 25% Chi\non cast.",
		"color":  Color(0.30, 0.70, 0.90),
		"rarity": "rare",
		"stackable": false,
		"prereq_family": "Watermelon",   # requires a Wet source first
	},
	"melon_gelato": {
		"family": "Watermelon",
		"name":   "Melon Gelato",
		"desc":   "MODE SWITCH: Water → Ice.\nSoaked becomes Chilled.\nLoses Wet+Lightning\nsynergy.",
		"color":  Color(0.55, 0.85, 0.95),
		"rarity": "uncommon",
		"stackable": false,
		"prereq_family": "Watermelon",
		"requires_effect": "wet",   # Run 44 — converting stacks needs a stack source
	},
	"tide_pool": {
		"family": "Watermelon",
		"name":   "Tide Pool",
		"desc":   "+1 Death-Defiance.\nRevive: +30% HP, 75% Chi\n+ Wet/Chilled burst.",
		"color":  Color(0.30, 0.70, 0.90),
		"rarity": "uncommon",
		"stackable": false,
		"family_dd": true,
	},
	# ---- Watermelon B + Charge slot boons ----
	"hydro_slide": {
		"family": "Watermelon", "name": "Hydro Slide",
		"desc":   "Dash splashes on landing\n(AoE dmg + 1 Soaked)\n+ leaves a soaking puddle.",
		"color":  Color(0.30, 0.70, 0.90), "rarity": "uncommon", "stackable": false, "boon_slot": "B",
	},
	"flood_charge": {
		"family": "Watermelon", "name": "Geyser Charge",
		"desc":   "Charge: +20% damage.\nWater column erupts —\n3 Soaked + brief\nair-stun launch.",
		"color":  Color(0.30, 0.70, 0.90), "rarity": "rare", "stackable": false,
		"boon_slot": "Charge", "prereq_family": "Watermelon",
	},
	# ------------------------------------------------------------
	# PEPPER (Combat_Boons §8.6) — Burn DoT escalation
	# SLOT BOONS (no prereq — these ARE the Burn sources).
	# ------------------------------------------------------------
	"spicy_jab": {
		"family": "Pepper",
		"name":   "Spicy Jab",
		"desc":   "Y hits apply\n1 Burn stack.\n(5 stacks → Combust)",
		"color":  Color(0.95, 0.30, 0.15),
		"rarity": "common",
		"stackable": false,
		"boon_slot": "Y",
	},
	"searing_strike": {
		"family": "Pepper",
		"name":   "Searing Strike",
		"desc":   "X hits: +40% fire dmg\n+ 2 Burn stacks.",
		"color":  Color(0.95, 0.30, 0.15),
		"rarity": "uncommon",
		"stackable": false,
		"boon_slot": "X",
	},
	"slow_cook": {
		"family": "Pepper",
		"name":   "Slow Cook",
		"desc":   "Burn duration +50%.",
		"color":  Color(0.95, 0.30, 0.15),
		"rarity": "common",
		"stackable": false,
		"prereq_family": "Pepper",   # Run 26c — needs an existing burn source
		"requires_effect": "burning",   # Run 44 — strict: a real Burn applier
	},
	"blazing_aura": {
		"family": "Pepper",
		"name":   "Blazing Aura",
		"desc":   "Burning enemies take\n+10% damage.",
		"color":  Color(0.95, 0.30, 0.15),
		"rarity": "uncommon",
		"stackable": false,
		"prereq_family": "Pepper",   # Run 26c
		"requires_effect": "burning",   # Run 44
	},
	"pyromania": {
		"family": "Pepper",
		"name":   "Pyromania",
		"desc":   "Hit streaks add extra\nBurn stacks per hit\n(up to +3).",
		"color":  Color(0.95, 0.30, 0.15),
		"rarity": "uncommon",
		"stackable": false,
		"prereq_family": "Pepper",   # Run 26c
	},
	"hot_footed": {
		"family": "Pepper",
		"name":   "Hot-Footed",
		"desc":   "After a dash:\n+30% move speed\nfor 3s.",
		"color":  Color(0.95, 0.30, 0.15),
		"rarity": "common",
		"stackable": false,
	},
	"combust": {
		"family": "Pepper",
		"name":   "Combust",
		"desc":   "At 5 Burn stacks:\ntarget explodes,\n+2 Burn to nearby.",
		"color":  Color(0.95, 0.30, 0.15),
		"rarity": "rare",
		"stackable": false,
		"prereq_family": "Pepper",   # Run 26c — burning is a prereq
		"requires_effect": "burning",   # Run 44
	},
	"phoenix_pepper": {
		"family": "Pepper",
		"name":   "Phoenix Pepper",
		"desc":   "+1 Death-Defiance.\nRevive: 3 Burn to all\n+ 30% HP refill.",
		"color":  Color(0.95, 0.30, 0.15),
		"rarity": "uncommon",
		"stackable": false,
		"family_dd": true,
	},
	# ---- Pepper A/B/Charge slot boons ----
	"fireball": {
		"family": "Pepper", "name": "Fireball",
		"desc":   "Ranged explodes on hit:\nsmall AoE fire\n+ 2 Burn stacks.",
		"color":  Color(0.95, 0.30, 0.15), "rarity": "common", "stackable": false,
		"boon_slot": "A", "prereq_family": "Pepper",
	},
	"fire_trail": {
		"family": "Pepper", "name": "Fire Trail",
		"desc":   "Dash leaves a flame\ntrail (2s). Crossing\nenemies gain 1 Burn.",
		"color":  Color(0.95, 0.30, 0.15), "rarity": "uncommon", "stackable": false,
		"boon_slot": "B", "prereq_family": "Pepper",
	},
	"inferno_charge": {
		"family": "Pepper", "name": "Inferno Charge",
		"desc":   "Charge leaves a\nscorched patch (4s):\n1 Burn/sec inside.",
		"color":  Color(0.95, 0.30, 0.15), "rarity": "rare", "stackable": false,
		"boon_slot": "Charge", "prereq_family": "Pepper",
	},
	# ------------------------------------------------------------
	# POTATO (Combat_Boons §8.8) — Earth/rock
	# SLOT BOONS (all 5 slots)
	# ------------------------------------------------------------
	"spud_stomp": {
		"family": "Potato", "name": "Spud Stomp",
		"desc":   "+15% earth dmg on Y.\nY finisher: Ground Pound\nknockdown (AoE).",
		"color":  Color(0.55, 0.40, 0.25), "rarity": "common", "stackable": false, "boon_slot": "Y",
	},
	"rock_smash": {
		"family": "Potato", "name": "Rock Smash",
		"desc":   "+30% earth dmg on X.\nEach X hit: 1 Cracked\nSoil stack.",
		"color":  Color(0.55, 0.40, 0.25), "rarity": "uncommon", "stackable": false, "boon_slot": "X",
	},
	"stone_throw": {
		"family": "Potato", "name": "Stone Throw",
		"desc":   "Ranged → heavy rocks.\nFires 2 in a line,\nheavy knockback.",
		"color":  Color(0.55, 0.40, 0.25), "rarity": "uncommon", "stackable": false, "boon_slot": "A",
	},
	"tuber_burrow": {
		"family": "Potato", "name": "Tuber Burrow",
		"desc":   "Hold dash to burrow\nunderground (invuln 3s).\nRise to attack.",
		"color":  Color(0.55, 0.40, 0.25), "rarity": "rare", "stackable": false, "boon_slot": "B",
	},
	"quake_charge": {
		"family": "Potato", "name": "Quake Charge",
		"desc":   "Charge: ring quake +\nearth spikes, knockdown,\n+1 Cracked Soil to all.",
		"color":  Color(0.55, 0.40, 0.25), "rarity": "rare", "stackable": false, "boon_slot": "Charge",
	},
	"starch_armor": {
		"family": "Potato",
		"name":   "Starch Armor",
		"desc":   "-10% damage taken.\nKnockback-immune.",
		"color":  Color(0.55, 0.40, 0.25),
		"rarity": "common",
		"stackable": false,
	},
	"spineback": {
		"family": "Potato",
		"name":   "Spineback",
		"desc":   "30% when hit: spike\nthe attacker + take\n50% less from that hit.",
		"color":  Color(0.55, 0.40, 0.25),
		"rarity": "uncommon",
		"stackable": false,
	},
	"heavy_stance": {
		"family": "Potato",
		"name":   "Heavy Stance",
		"desc":   "While Ingrained:\n+15% damage +\nstagger immunity.",
		"color":  Color(0.55, 0.40, 0.25),
		"rarity": "uncommon",
		"stackable": false,
	},
	"tremor_walk": {
		"family": "Potato",
		"name":   "Tremor Walk",
		"desc":   "Moving leaves a Cracked\nSoil trail. Ingrained:\npulse every 3s.",
		"color":  Color(0.55, 0.40, 0.25),
		"rarity": "uncommon",
		"stackable": false,
	},
	"stone_form": {
		"family": "Potato",
		"name":   "Stone Form",
		"desc":   "+1 Death-Defiance.\nRevive: invulnerable\nfor 5s (can act).",
		"color":  Color(0.55, 0.40, 0.25),
		"rarity": "uncommon",
		"stackable": false,
		"family_dd": true,
	},
	# ------------------------------------------------------------
	# BANANA (Combat_Boons §8.9) — Slip/lightning
	# ------------------------------------------------------------
	# ---- Banana slot boons (all 5 slots) ----
	"peel_slap": {
		"family": "Banana", "name": "Peel Slap",
		"desc":   "Y hits: +10% damage\n+ Slippery\n(Sparked in GL mode).",
		"color":  Color(0.95, 0.85, 0.20), "rarity": "common", "stackable": false, "boon_slot": "Y",
	},
	"voltaic_strike": {
		"family": "Banana", "name": "Voltaic Strike",
		"desc":   "X hits: +15% damage\n+ Greased\n(Bolted in GL mode).",
		"color":  Color(0.95, 0.85, 0.20), "rarity": "uncommon", "stackable": false, "boon_slot": "X",
	},
	# Run 128 — no baseline dmg (boomerang double-pass = its damage value)
	"bananarang": {
		"family": "Banana", "name": "Bananarang",
		"desc":   "Ranged → boomerang.\nSlippery out, Greased back\n(Sparked/Bolted in GL).",
		"color":  Color(0.95, 0.85, 0.20), "rarity": "uncommon", "stackable": false, "boon_slot": "A",
	},
	"zip_dash": {
		"family": "Banana", "name": "Zip Dash",
		"desc":   "+20% dash distance,\n+15% move speed.\nGL: dash shocks enemies.",
		"color":  Color(0.95, 0.85, 0.20), "rarity": "common", "stackable": false, "boon_slot": "B",
	},
	"storm_charge": {
		"family": "Banana", "name": "Storm Charge",
		"desc":   "Charge: +20% damage,\nknockdown burst.\nGL: chains to 3 nearby.",
		"color":  Color(0.95, 0.85, 0.20), "rarity": "rare", "stackable": false, "boon_slot": "Charge",
	},
	"slick_trail": {
		"family": "Banana",
		"name":   "Slick Trail",
		"desc":   "Dash drops caltrops\nat start + end.\nTouch = Slippery.",
		"color":  Color(0.95, 0.85, 0.20),
		"rarity": "common",
		"stackable": false,
	},
	# Run 128 — previously-missing doc passive (Combat_Boons §8.9 #2).
	"shocking_return": {
		"family": "Banana",
		"name":   "Shocking Return",
		"desc":   "20% chance when hit:\nknock the attacker down 1s\n(GL: zap + ministun).",
		"color":  Color(0.95, 0.85, 0.20),
		"rarity": "common",
		"stackable": false,
	},
	"static_charge": {
		"family": "Banana",
		"name":   "Static Charge",
		"desc":   "Every 3rd ranged hit\ndrops caltrops.\nGL: chain lightning.",
		"color":  Color(0.95, 0.85, 0.20),
		"rarity": "common",
		"stackable": false,
	},
	"tailwind": {
		"family": "Banana",
		"name":   "Tailwind",
		"desc":   "Always-on: +5% dodge,\nmove & attack speed.\nGL: lightning dmg\ninstead of dodge.",
		"color":  Color(0.95, 0.85, 0.20),
		"rarity": "common",
		"stackable": false,
	},
	"peel_out": {
		"family": "Banana",
		"name":   "Peel Out",
		"desc":   "On dodge: +30% move\n& attack speed for 5s.",
		"color":  Color(0.95, 0.85, 0.20),
		"rarity": "uncommon",
		"stackable": false,
	},
	"extra_banana": {
		"family": "Banana",
		"name":   "Extra Banana",
		"desc":   "+1 dash charge\n(hold 2 at once).",
		"color":  Color(0.95, 0.85, 0.20),
		"rarity": "uncommon",
		"stackable": false,
	},
	"greased_lightning": {
		"family": "Banana",
		"name":   "Greased Lightning",
		"desc":   "MODE SWITCH:\nSlippery → Sparked,\nGreased → Bolted.\nTrades CC for lightning.",
		"color":  Color(1.0, 0.95, 0.45),
		"rarity": "uncommon",
		"stackable": false,
		"prereq_family": "Banana",   # Run 26c — mode switch requires existing Banana boon
		"requires_effect": "banana_status",   # Run 44 — converting statuses needs a source
	},
	"banana_splits": {
		"family": "Banana",
		"name":   "Banana Splits",
		"desc":   "+1 Death-Defiance.\nRevive: +50% dodge 10s\n+ drop slippery peels.",
		"color":  Color(0.95, 0.85, 0.20),
		"rarity": "uncommon",
		"stackable": false,
		"family_dd": true,
	},
	# ------------------------------------------------------------
	# ONION (Combat_Boons §8.10) — Poison DoT
	# SLOT BOONS (all 5 slots — these ARE the Poison application sources)
	# ------------------------------------------------------------
	"pungent_jab": {
		"family": "Onion", "name": "Pungent Jab",
		"desc":   "Y hits apply\n1 Poison stack.",
		"color":  Color(0.70, 0.80, 0.45), "rarity": "common", "stackable": false, "boon_slot": "Y",
	},
	"tear_strike": {
		"family": "Onion", "name": "Tear Strike",
		"desc":   "X hits: +30% damage\n+ 2 Poison stacks.",
		"color":  Color(0.70, 0.80, 0.45), "rarity": "uncommon", "stackable": false, "boon_slot": "X",
	},
	"stink_bomb": {
		"family": "Onion", "name": "Stink Bomb",
		"desc":   "Ranged explodes into a\ngas cloud (6s):\n1 Poison/sec inside.",
		"color":  Color(0.70, 0.80, 0.45), "rarity": "uncommon", "stackable": false, "boon_slot": "A",
	},
	"gas_bookends": {
		"family": "Onion", "name": "Gas Bookends",
		"desc":   "Dash drops stink clouds\nat start + landing\n(4s each).",
		"color":  Color(0.70, 0.80, 0.45), "rarity": "rare", "stackable": false, "boon_slot": "B",
	},
	"reek_charge": {
		"family": "Onion", "name": "Reek Charge",
		"desc":   "Charge: gas burst\naround you + stink\ncloud (5s).",
		"color":  Color(0.70, 0.80, 0.45), "rarity": "rare", "stackable": false,
		"boon_slot": "Charge", "prereq_family": "Onion",
	},
	"layered_defense": {
		"family": "Onion",
		"name":   "Layered Defense",
		"desc":   "Aura around you\npassively poisons\nnearby enemies.",
		"color":  Color(0.70, 0.80, 0.45),
		"rarity": "common",
		"stackable": false,
	},
	"rotten_core": {
		"family": "Onion",
		"name":   "Rotten Core",
		"desc":   "Poisoned enemies burst\ninto a stink cloud\non death.",
		"color":  Color(0.70, 0.80, 0.45),
		"rarity": "uncommon",
		"stackable": false,
		"prereq_family": "Onion",
		"requires_effect": "poison",   # Run 44 — strict: a real Poison applier
	},
	"chronic_reek": {
		"family": "Onion",
		"name":   "Chronic Reek",
		"desc":   "Poison duration +50%.\nPoison damage +20%.",
		"color":  Color(0.70, 0.80, 0.45),
		"rarity": "uncommon",
		"stackable": false,
		"prereq_family": "Onion",
		"requires_effect": "poison",   # Run 44
	},
	"fermented_strength": {
		"family": "Onion",
		"name":   "Fermented Strength",
		"desc":   "+5% damage to a target\nper Poison stack\non it.",
		"color":  Color(0.70, 0.80, 0.45),
		"rarity": "uncommon",
		"stackable": false,
		"prereq_family": "Onion",
		"requires_effect": "poison",   # Run 44
	},
	"overripe": {
		"family": "Onion",
		"name":   "Overripe",
		"desc":   "Poison max stacks\n5 → 7.",
		"color":  Color(0.70, 0.80, 0.45),
		"rarity": "rare",
		"stackable": false,
		"prereq_family": "Onion",
		"requires_effect": "poison",   # Run 44
	},
	"death_bloom": {
		"family": "Onion",
		"name":   "Death Bloom",
		"desc":   "+1 Death-Defiance.\nRevive: stink cloud on\nevery enemy on screen.",
		"color":  Color(0.70, 0.80, 0.45),
		"rarity": "uncommon",
		"stackable": false,
		"family_dd": true,
	},
	# ------------------------------------------------------------
	# LEGENDARIES (Run 19) — gold-tier finishers per family.
	# Surfaced in BoonOffer with the existing rarity legendary border
	# PLUS a special "✦ LEGENDARY ✦" badge above the family banner.
	# Already-shipped: heart_of_the_orchard (Apple — see above).
	# ------------------------------------------------------------
	# ── Run 27f — previously-missing passives (Combat_Boons §8) ──
	"long_shot": {
		"family": "Carrot", "name": "Long Shot",
		"desc": "Ranged damage scales\nwith distance flown\n(up to +25%).",
		"color": Color(0.95, 0.55, 0.15), "rarity": "common", "stackable": false,
	},
	"drawn_bow": {
		"family": "Carrot", "name": "Drawn Bow",
		"desc": "1.5s without attacking →\nnext hit crits (melee OR\nranged). Charged: 3s.",
		"color": Color(0.95, 0.55, 0.15), "rarity": "uncommon", "stackable": false,
	},
	"killshot": {
		"family": "Carrot", "name": "Killshot",
		"desc": "Crits below 25% HP:\n7% chance for a\nSuper-Mega-Crit (~3x).",
		"color": Color(0.95, 0.55, 0.15), "rarity": "rare", "stackable": false,
		"requires_effect": "crit_chance",   # Run 127 — needs a crit source
	},
	"singed": {
		"family": "Pepper", "name": "Singed",
		"desc": "Burning enemies gain\n+10% miss chance\n(blinded).",
		"color": Color(0.95, 0.30, 0.15), "rarity": "common", "stackable": false,
		"prereq_family": "Pepper",
		"requires_effect": "burning",   # Run 44
	},
	"heatwave": {
		"family": "Pepper", "name": "Heatwave",
		"desc": "Any finisher leaves a\nburning patch (4s)\nat the target.",
		"color": Color(0.95, 0.30, 0.15), "rarity": "uncommon", "stackable": false,
	},
	"wave_crash": {
		"family": "Watermelon", "name": "Wave Crash / Brain Freeze",
		"desc": "Wet/Frostbitten enemies\nburst on death: splash\n+ 1 stack to nearby.",
		"color": Color(0.30, 0.70, 0.90), "rarity": "uncommon", "stackable": false,
		"prereq_family": "Watermelon",
		"requires_effect": "wet",   # Run 44
	},
	"rampart": {
		"family": "Potato", "name": "Rampart",
		"desc": "20% when hit: raise\na rock wall beside\nyou (4s).",
		"color": Color(0.55, 0.40, 0.25), "rarity": "common", "stackable": false,
	},
	# Run 127 — "avalanche_aid" CUT from the pool (Bruno: boulders-on-revive
	# felt useless). Revive hooks in Player.gd/BeaAI.gd remain but can never
	# fire (ownership check can't pass). Doc updated same pass.
	"tears_of_restoration": {
		"family": "Onion", "name": "Tears of Restoration",
		"desc": "Your Poison ticks\ngenerate Chi.",
		"color": Color(0.70, 0.80, 0.45), "rarity": "uncommon", "stackable": false,
		"prereq_family": "Onion",
		"requires_effect": "poison",   # Run 44
	},
	# ── Run 27f — Potato + Onion Legendaries (families had none) ──
	"petrify": {
		"family": "Potato", "name": "Petrify",
		"desc": "Earthbind becomes\n3s full Stun\n+ Vulnerable.",
		"color": Color(0.55, 0.40, 0.25), "rarity": "legendary", "stackable": false,
		"requires_effect": "cracked_soil",   # Run 44 — upgrades Earthbind, needs a soil source
	},
	"mountain_king": {
		"family": "Potato", "name": "Mountain King",
		"desc": "While Ingrained,\nevery melee hit erupts\na spike ring.",
		"color": Color(0.55, 0.40, 0.25), "rarity": "legendary", "stackable": false,
	},
	"chronic_plague": {
		"family": "Onion", "name": "Chronic Plague",
		"desc": "Poison ticks 2x faster,\n+50% damage. Poisoned\nenemies never cure.",
		"color": Color(0.70, 0.80, 0.45), "rarity": "legendary", "stackable": false,
		"requires_effect": "poison",   # Run 44
	},
	# ── Run 27f — Ultimate boons (one per family, Ult slot) ──
	"harvest_moon": {
		"family": "Apple", "name": "Harvest Moon", "boon_slot": "Ult",
		"desc": "ULT: heals both heroes\n25% max HP on cast",
		"color": Color(0.95, 0.25, 0.30), "rarity": "rare", "stackable": false,
	},
	"bulwark_strike": {
		"family": "Coconut", "name": "Bulwark Strike", "boon_slot": "Ult",
		"desc": "ULT: enemies hit are\nstunned 3s; both heroes\ngain max overshells",
		"color": Color(0.72, 0.50, 0.22), "rarity": "rare", "stackable": false,
	},
	"titans_roar": {
		"family": "Broccoli", "name": "Titan's Roar", "boon_slot": "Ult",
		"desc": "ULT: +50% Ult damage\n+20% all damage for 5s\nafter cast",
		"color": Color(0.20, 0.65, 0.30), "rarity": "rare", "stackable": false,
	},
	"bullseye_finale": {
		"family": "Carrot", "name": "Bullseye Finale", "boon_slot": "Ult",
		"desc": "ULT: guaranteed crit;\n+25% crit chance for\n10s after cast",
		"color": Color(0.95, 0.55, 0.15), "rarity": "rare", "stackable": false,
	},
	"bunch_bloom_ult": {
		"family": "Grape", "name": "Bunch Bloom", "boon_slot": "Ult",
		"desc": "ULT: combo counter\ninstantly set to max (30)\non cast",
		"color": Color(0.55, 0.25, 0.75), "rarity": "rare", "stackable": false,
	},
	"inferno_blossom": {
		"family": "Pepper", "name": "Inferno Blossom", "boon_slot": "Ult",
		"desc": "ULT: all enemies hit\ngain 3 Burn stacks",
		"color": Color(0.95, 0.30, 0.15), "rarity": "rare", "stackable": false,
	},
	"tidal_surge": {
		"family": "Watermelon", "name": "Tidal Surge", "boon_slot": "Ult",
		"desc": "ULT: applies 5 Soaked\n(or 5 Chilled in Gelato)\n— instant max-state",
		"color": Color(0.30, 0.70, 0.90), "rarity": "rare", "stackable": false,
	},
	"terrashock": {
		"family": "Potato", "name": "Terrashock", "boon_slot": "Ult",
		"desc": "ULT: enemies hit gain\n3 Cracked Soil + brief\nair-stagger",
		"color": Color(0.55, 0.40, 0.25), "rarity": "rare", "stackable": false,
	},
	"storm_finale": {
		"family": "Banana", "name": "Storm Finale", "boon_slot": "Ult",
		"desc": "ULT: enemies hit are\nGreased (or Bolted in\nGreased Lightning)",
		"color": Color(0.95, 0.85, 0.20), "rarity": "rare", "stackable": false,
	},
	"miasma_burst": {
		"family": "Onion", "name": "Miasma Burst", "boon_slot": "Ult",
		"desc": "ULT: enemies hit are\ninstantly stacked to\n5x Poison",
		"color": Color(0.70, 0.80, 0.45), "rarity": "rare", "stackable": false,
	},
	"juicebox_of_youth": {
		"family": "Apple",
		"name":   "Juicebox of Youth",
		"desc":   "A Juice Box drops\nevery 10s. Pickup:\nboth heroes regen\n1 HP/sec for 10s.",
		"color":  Color(0.95, 0.25, 0.30),
		"rarity": "legendary",
		"stackable": false,
	},
	"adamantium_husk": {
		"family": "Coconut",
		"name":   "Adamantium Husk",
		"desc":   "Every overshield\nblocks 2 hits\ninstead of 1.",
		"color":  Color(0.72, 0.50, 0.22),
		"rarity": "legendary",
		"stackable": false,
		"requires_effect": "overshell",   # Run 44
	},
	"hulk_smash": {
		"family": "Broccoli",
		"name":   "Hulk Smash",
		"desc":   "Combo finishers emit\na shockwave — size &\ndamage scale with\ncombo count.",
		"color":  Color(0.20, 0.65, 0.30),
		"rarity": "legendary",
		"stackable": false,
	},
	# =========================================================================
	# Run 128 — LEGENDARY RECONCILIATION (Bruno's call): the 6 non-doc
	# substitutes (Eagle Eye, Sniper's Focus, Voltaic Engine, Slip Stream,
	# Inferno Crown, Tidal Tsunami) are RETIRED. Run 130 completed the set —
	# all 20 doc legendaries (2 per family) are in the pool and wired.
	# =========================================================================
	"topshot": {
		"family": "Carrot",
		"name":   "Topshot",
		"desc":   "Your first hit on every\nnew enemy (charge\nattacks too) is a\nguaranteed Mega-Crit.",
		"color":  Color(0.95, 0.55, 0.15),
		"rarity": "legendary",
		"stackable": false,
	},
	"drupe_guard": {
		"family": "Coconut",
		"name":   "Drupe Guard",
		"desc":   "Taking damage triggers\na 1.5s invulnerable shell.\n10s cooldown\n(-2s per level).",
		"color":  Color(0.72, 0.50, 0.22),
		"rarity": "legendary",
		"stackable": false,
	},
	"smash_zone": {
		"family": "Broccoli",
		"name":   "Smash Zone",
		"desc":   "Melee: +10% damage per\nmeter closer to target.\nCap +50% at point-blank.",
		"color":  Color(0.20, 0.65, 0.30),
		"rarity": "legendary",
		"stackable": false,
	},
	"vineyard_reserve": {
		"family": "Grape",
		"name":   "Vineyard Reserve",
		"desc":   "+2 combo per hit.\nNo combo reset on miss\n(decays 1/sec instead).\nAt 30 combo: +30% damage.",
		"color":  Color(0.55, 0.25, 0.75),
		"rarity": "legendary",
		"stackable": false,
	},
	"wildfire": {
		"family": "Pepper",
		"name":   "Wildfire",
		"desc":   "Burn never expires —\nexpiring stacks jump to a\nnearby enemy, and spread\nevery 2s while burning.",
		"color":  Color(0.95, 0.45, 0.10),
		"rarity": "legendary",
		"stackable": false,
		"requires_effect": "burning",
	},
	"embrace": {
		"family": "Watermelon",
		"name":   "Embrace",
		"desc":   "+1 bonus stack per hit.\nDrenched/Frozen lasts 2x\n+ pulls nearby enemies in.\nExpiry leaves 4 stacks.",
		"color":  Color(0.30, 0.55, 0.85),
		"rarity": "legendary",
		"stackable": false,
		"requires_effect": "wet",
	},
	# ── Run 130 — final doc-legendary wave (all wired this run) ──
	"marksmans_eye": {
		"family": "Carrot",
		"name":   "Marksman's Eye",
		"desc":   "Every 5s the highest-HP\nenemy is Marked. Ranged\nhits on it: guaranteed crit,\n+30% dmg, ricochet to 3.",
		"color":  Color(0.95, 0.55, 0.15),
		"rarity": "legendary",
		"stackable": false,
	},
	"cluster_theory": {
		"family": "Grape",
		"name":   "Cluster Theory",
		"desc":   "Every projectile splits\ninto 3 on impact — and\nthe splits split once more.",
		"color":  Color(0.55, 0.25, 0.75),
		"rarity": "legendary",
		"stackable": false,
	},
	"ghost_pepper": {
		"family": "Pepper",
		"name":   "Ghost Pepper",
		"desc":   "1.5s without attacking:\nvanish (untargetable).\nFirst strike from stealth\n= max Burn. Burn ticks 2x.",
		"color":  Color(0.95, 0.45, 0.10),
		"rarity": "legendary",
		"stackable": false,
		"requires_effect": "burning",
	},
	"summers_end": {
		"family": "Watermelon",
		"name":   "Summer's / Winter's End",
		"desc":   "Drenched/Frozen triggers\nand wet deaths detonate:\nAoE +1 stack + a lingering\npuddle / ice patch.",
		"color":  Color(0.30, 0.55, 0.85),
		"rarity": "legendary",
		"stackable": false,
		"requires_effect": "wet",
	},
	"bonk_zap": {
		"family": "Banana",
		"name":   "BONK / ZAP",
		"desc":   "Every 3s: Slippery/Greased\nenemies slip-fall for ~10%\nmax HP (GL: bolt strike\n~15% + re-Spark).",
		"color":  Color(0.95, 0.85, 0.25),
		"rarity": "legendary",
		"stackable": false,
		"requires_effect": "banana_status",
	},
	"slapstick": {
		"family": "Banana",
		"name":   "Slapstick",
		"desc":   "+1 dash charge.\nEvery dash drops a giant\nbanana (slip + big dmg)\n(GL: lightning bolt).",
		"color":  Color(0.95, 0.85, 0.25),
		"rarity": "legendary",
		"stackable": false,
	},
	"plague_layer": {
		"family": "Onion",
		"name":   "Plague Layer",
		"desc":   "Poisoned enemies rise as\nfriendly Zonions (10s) that\nchase + poison your foes.",
		"color":  Color(0.70, 0.80, 0.45),
		"rarity": "legendary",
		"stackable": false,
		"requires_effect": "poison",
	},
	# =========================================================================
	# CORRUPT BOONS — Identity-flip tier (GDD §6.3). Each boon's family matches
	# its SOURCE family so it appears in that family's room offer via
	# _maybe_inject_corrupt(). rarity:"corrupt" + corrupt:true triggers the
	# BoonOffer purple-gradient and ☠ CORRUPT ☠ badge.
	# =========================================================================
	"corrupt_apple": {
		"family": "Apple", "rarity": "corrupt", "corrupt": true,
		"name":   "Poison Apple",
		"desc":   "Max HP locked to 50.\nAll hits dealt to you = 1.\nAll healing blocked.\nRipened Core always active.\n1× Golden Apple DD (full restore).",
		"color":  Color(0.95, 0.25, 0.30),
	},
	"corrupt_coconut": {
		"family": "Coconut", "rarity": "corrupt", "corrupt": true,
		"name":   "Cracked Shell",
		"desc":   "Overshield disabled.\n+50% damage dealt.\n-40% damage taken.\nEvery melee hit shockwaves\nnearby enemies (0.3s stagger).",
		"color":  Color(0.72, 0.50, 0.22),
	},
	"corrupt_broccoli": {
		"family": "Broccoli", "rarity": "corrupt", "corrupt": true,
		"name":   "Burnout",
		"desc":   "All ramps locked at max.\n+100% damage dealt.\n50% CC resist.\nDash distance halved.",
		"color":  Color(0.20, 0.65, 0.30),
	},
	"corrupt_carrot": {
		"family": "Carrot", "rarity": "corrupt", "corrupt": true,
		"name":   "Chaos Carrot",
		"desc":   "Crit damage disabled.\n50% flat crit chance.\nEach crit: random debuff on enemy\n+ random buff on self.",
		"color":  Color(0.95, 0.55, 0.15),
	},
	"corrupt_grape": {
		"family": "Grape", "rarity": "corrupt", "corrupt": true,
		"name":   "One Big Grape",
		"desc":   "Combo locked at 15.\nY and X only fire finishers.\nFinisher damage massively boosted.\n+50% finisher AoE radius.",
		"color":  Color(0.55, 0.25, 0.75),
	},
	"corrupt_pepper": {
		"family": "Pepper", "rarity": "corrupt", "corrupt": true,
		"name":   "Solar Flare",
		"desc":   "Burn stacks removed.\nEvery hit: instant explosion (~3m AoE).\n+100% fire damage.\nExplosion hits all foes in range.",
		"color":  Color(0.95, 0.30, 0.15),
	},
	"corrupt_watermelon": {
		"family": "Watermelon", "rarity": "corrupt", "corrupt": true,
		"name":   "Cold Waters",
		"desc":   "Both modes always active.\nEvery hit: +1 Soaked AND +1 Chilled.\n-50% Chi gain.\n-50% HP regen / healing.",
		"color":  Color(0.30, 0.70, 0.90),
	},
	"corrupt_potato": {
		"family": "Potato", "rarity": "corrupt", "corrupt": true,
		"name":   "Uprooted",
		"desc":   "Cracked Soil CC chain removed.\n+20% move speed.\n+2 dash charges.",
		"color":  Color(0.55, 0.40, 0.25),
	},
	"corrupt_banana": {
		"family": "Banana", "rarity": "corrupt", "corrupt": true,
		"name":   "Thunderstruck",
		"desc":   "Y hits chain to 3 enemies.\nX hits mark Bolted.\n+75% lightning damage.\n3m shock aura (zap every 0.5s).",
		"color":  Color(0.95, 0.85, 0.20),
	},
	"corrupt_onion": {
		"family": "Onion", "rarity": "corrupt", "corrupt": true,
		"name":   "Fermented Wrath",
		"desc":   "Attack poison removed.\n5m stink aura:\nrapid-stacks Poison (10 cap).\n+3 Poison/sec to nearby foes.",
		"color":  Color(0.70, 0.80, 0.45),
	},
}

# --- Per-boon / per-duo effect tuning constants (Phase-2 B1) ---
const FURY_RELEASE_DMG_BONUS: float = 0.60
const FURY_RELEASE_AREA_BONUS: float = 0.40   # Run 131 — +40% charge hitbox/AoE size
const BRUTE_FORCE_DMG_BONUS:  float = 0.35
const BRUTE_FORCE_SHOCKWAVE_RADIUS: float = 72.0
const KEEN_EYE_CRIT_CHANCE: float = 0.15
const KEEN_EYE_CRIT_DMG:    float = 0.10
const SHARPENED_TIP_CRIT_CHANCE: float = 0.25
const SHARPENED_TIP_CRIT_DMG:    float = 0.20
const BULLSEYE_CRIT_CHANCE: float = 0.20
const BULLSEYE_CRIT_DMG:    float = 0.30
const VINE_LASH_WINDOW: float = 0.5     # seconds after a dash to trigger
const VINE_LASH_COUNT: int = 3          # vines per lash
const VINE_LASH_DAMAGE: int = 7         # per-vine base (scaled by holder's damage path)
const VINE_LASH_RANGE: float = 170.0    # reach in px
const VINE_LASH_CONE_DEG: float = 60.0  # total cone width around facing
const CLUSTER_STRIKE_BONUS: float = 0.60
const BUNCH_BURST_HITS: int   = 2
const BUNCH_BURST_DMG_PCT: float = 0.50
const SPUD_STOMP_EARTH_BONUS:  float = 0.15
const ROCK_SMASH_EARTH_BONUS:  float = 0.30
const STONE_THROW_DMG_BONUS:   float = 0.60
const QUAKE_CHARGE_RADIUS:     float = 80.0
const SHELL_BREAKER_VULN_DUR: float = 5.0
const NUTSHELL_RADIUS:        float = 90.0
const NUTSHELL_BASH_DURATION: float = 0.4
const BATTLE_SHELL_DURATION:  float = 3.0    # spec: 3s base, +1s per Pom level
const COMBAT_FURY_MAX_TIERS: int = 5
const COMBAT_FURY_DECAY_SEC: float = 3.0
const CRITICAL_MASS_DURATION: float = 4.0
const CRITICAL_MASS_PER_STACK_PCT: float = 0.15
const CRITICAL_MASS_MAX_STACKS: int = 3
const HOT_FOOTED_DURATION: float = 3.0
const HOT_FOOTED_SPEED_BONUS: float = 0.30
const SPINEBACK_PROC_CHANCE: float = 0.30
const SPINEBACK_MITIGATION:  float = 0.50
const SMASH_ZONE_PX_PER_M: float = 48.0
const APPLE_PIE_HP_PER_STACK: float = 0.10
const APPLE_JUICE_HEAL_PCT: float = 0.50   # heal 50% of effective max HP, both characters
const IRON_CORE_PER_BOON_PCT: float = 0.05
const AIMED_GUARD_OVERSHIELD_DUR: float = 3.0
const AIMED_GUARD_ICD: float = 2.0
const VITAL_HARVEST_HEAL_PCT: float = 0.03
const SHOCK_IGNITION_BURN_CHANCE_BONUS: float = 0.25
const ROOT_AND_ROT_POISON_AMP: float = 0.20
const BRUISE_PEEL_STAGGER_DUR: float = 1.5
const FROST_SHIELD_DAMAGE_REDUCTION: float = 0.15
const PEPPER_POTATO_DAMAGE_AMP: float = 0.30
const SPRING_TIDE_RADIUS: float = 70.0    # puddle radius (px)
const SPRING_TIDE_DURATION: float = 4.0   # puddle lifetime (s)
const SPRING_TIDE_REGEN_HP: int = 1       # HP/sec to heroes standing inside
const ONION_GRAPE_POISON_BURST_STACKS: int = 3
const BANANA_PEPPER_IGNITE_CHANCE: float = 0.40
const CARROT_WATERMELON_RANGED_CRIT_HEAL_PCT: float = 0.04
const BROCCOLI_ONION_FINISHER_POISON_STACKS: int = 1
const HULK_SMASH_CHARGE_DMG_MULT: float = 2.0    # ×2 on all charge attacks
const HULK_SMASH_AOE_MULT: float = 2.0            # doubles crane-kick radius, flurry reach, etc.
const HULK_SMASH_WINDUP_MULT: float = 0.50        # charge time × 0.50 (50% faster)
const HULK_SMASH_BASE_RADIUS: float = 110.0
const HULK_SMASH_PER_COMBO_RADIUS: float = 4.0
const HULK_SMASH_BASE_DAMAGE: int = 18
const HULK_SMASH_PER_COMBO_DAMAGE: float = 0.4
const DRAWN_BOW_IDLE: float = 1.5
const DRAWN_BOW_IDLE_CHARGED: float = 3.0
const SNIPER_FOCUS_STREAK_TRIGGER: int = 3
const SNIPER_FOCUS_BONUS_WINDOW: float = 2.0
const SNIPER_FOCUS_BONUS_DMG: float    = 0.50
const SLIP_STREAM_IFRAMES_BONUS: float = 0.5  # extra i-frame seconds on top of base dash
const GRAPE_BANANA_CRIT_BONUS: float = 0.20
const BAKED_APPLE_HEAL_THRESHOLD_PCT: float = 0.10
const BAKED_APPLE_BURN_STACKS: int = 2
const POTATO_WATERMELON_AMP: float = 0.25
const COCONUT_BROCCOLI_SHIELD_DMG_BONUS: float = 0.10
const BURNING_AIM_STACKS_PER_CRIT: int = 2
const BURNING_AIM_PCT_PER_STACK: float = 0.01
const CARROT_ONION_POISON_CRIT_BONUS: float = 0.10
const BURNING_AIM_PER_STACK_BONUS: float = 0.01
const CLUSTER_SPLASH_RADIUS: float = 80.0   # ~2m
const CLUSTER_SPLASH_STACKS: int   = 2
const CLUSTER_SPLASH_COMBO_BONUS: int = 3
const STEAM_BURST_FLAT_DMG:      int   = 8        # proxy for +15% bonus damage
const STEAM_BURST_PUFF_RADIUS:   float = 100.0    # 2m ≈ 100px
const STEAM_BURST_BLIND_DUR:     float = 1.5      # 1.5s puff per spec
const THAW_BURST_FLAT_DMG: int = 10               # proxy for +15% on Frostbitten

# ============================================================
# BoonDB query helpers — pure lookups/derivations over the data
# tables (Phase 2 B2). Moved verbatim from RunState.gd; RunState
# keeps a one-line delegating wrapper for each (name/signature
# unchanged). These read ONLY BoonDB consts + their args — no
# mutable RunState state, no autoload side effects.
# ============================================================

# Family display colors mirror FAM_COLOR but exposed for DoorChoice UI.
static func get_family_color(family: String) -> Color:
	return FAM_COLOR.get(family, Color(0.85, 0.85, 0.85))

static func get_rarity_color(rarity: String) -> Color:
	return RARITY_COLOR.get(rarity, Color(0.85, 0.85, 0.85))

# Resolve a boon's slot from its explicit boon_slot field ONLY. (Do NOT fall
# back to BOON_ATTACK_SLOT — that map tags passives like static_charge "A" or
# heatwave "Y" for attack-tint purposes; treating those as slot boons would
# wrongly evict real slot picks.)
static func get_slot_for_boon(boon_id: String) -> String:
	return String(BOON_POOL.get(boon_id, {}).get("boon_slot", ""))

static func is_attack_boon(boon_id: String) -> bool:
	return BOON_ATTACK_SLOT.has(boon_id)

# Base rarity: legendary/corrupt/duo keep their fixed tier; everything else
# (including legacy "uncommon"/"rare" pool entries) is common.
static func get_base_rarity(boon_id: String) -> String:
	if boon_id.begins_with("duo:"):
		return "duo"   # Run 41 — duo cards are a fixed tier, never rolled
	var br: String = String(BOON_POOL.get(boon_id, {}).get("rarity", "common"))
	if br == "legendary" or br == "corrupt":
		return br
	return "common"

# Run 44 — slot trade-up: rarity ladder bump (fixed tiers never bump).
static func bump_rarity(r: String) -> String:
	var i: int = _RARITY_LADDER.find(r)
	if i == -1:
		return r
	return _RARITY_LADDER[min(i + 1, _RARITY_LADDER.size() - 1)]

