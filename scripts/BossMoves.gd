extends RefCounted

# ============================================================
# BossMoves.gd - Run 173 (2026-09-03) - boss moveset DATA
# Run 176 (2026-09-26) - every boss + mini-boss gets a real moveset
# ============================================================
# Bruno, Run 173: "almost all of them just kinda chase after the player,
# doing mostly nothing aside from an occasional attack that is pretty easy
# to dodge."
# Bruno, Run 176: "revamp all of the bosses and minibosses movesets, make
# them believable and unique ... a real challenge (not impossible, but tougher
# than basic mobs)" + "they should not chase the player around ... They should
# jump around the stage (or fly where appropriate), do landing attacks over
# the player they have to dodge - make them feel like Zelda bosses."
#
# This file is the DATA half. BossBrain.gd is the engine. A boss opts in with
# "moveset": "<key>" on its DreamBiomes entry; anything without one falls
# through to legacy_pool() (pre-Run-173 chase/bite/smash).
#
# ------------------------------------------------------------
# DESIGN RULES every set below follows (the "Zelda contract")
# ------------------------------------------------------------
#  1. Nobody walks at you. Movement is "hop" (leaps between spots AROUND the
#     hero) or "fly" (the Phoenix). Breaking away is a leap too.
#  2. The signature attack is a LANDING: a RED marker tracks the hero while
#     the boss is in the air (track_speed < hero speed 220, so running works),
#     then LOCKS with a crosshair for >= 0.4s before impact. Dodge = commit.
#  3. The boss cannot be hit in the air. Every landing / big swing ends in a
#     "recovery" - that planted beat is THE damage window.
#  4. Each boss owns one idea no one else has (Kraken burrows, Hydra's heads
#     bite where you stand, Rock-Candy cracks fault lines, Phoenix dives from
#     the sky, Sentinel fences you in with spear thrusts, Yeti drops the
#     mountain on you...).
#  5. Phases add ONE new verb each and tighten cooldowns - never just +HP.
#  6. Every telegraph is RED (locked project rule) and every status goes
#     through an existing hook (burn / poison / frost-slow / bash-stun /
#     knockback).
#
# ------------------------------------------------------------
# MOVESET SCHEMA
# ------------------------------------------------------------
# {
#   "display":  "Corn Dog Colossus",   # HUD boss-bar name
#   "gcd":      0.7,                   # min seconds between any two moves
#   "movement": { ...MOVEMENT... },
#   "phases":   [ ...PHASES... ],
#   "moves":    [ ...MOVE... ],
# }
#
# MOVEMENT
#   "mode": "hop"    - plants between moves; relocates by leaping (Run 176)
#           "fly"    - orbits the hero in the air, ignores walls (Run 176)
#           "chase" / "anchor" / "orbit" / "roam" - walking modes (legacy)
#   hop:  "hop_interval" [lo, hi] s between relocation hops
#         "hop_range" [lo, hi] px from the hero it lands at
#         "hop_air", "hop_height", "hop_windup", "hop_recovery", "hop_track"
#         "hop_land_radius", "hop_land_dmg" (0 = harmless hop, no marker)
#         "hop_style" "jump" | "burrow", "hop_when_farther" px, "drift" 0..1
#   fly:  "fly_height" (local px), "preferred_range", "orbit_speed" rad/s,
#         "speed_mult"
#   "reposition_every": N - after N moves: leap far away (hop), bank to the
#                       far side of the orbit (fly), or walk (legacy modes)
#
# PHASES - HP fractions, top-down:
#   {"hp": 0.55, "name": "II", "speed_mult": 1.12, "cooldown_mult": 0.85,
#    "on_enter": "<move id>"}   # signature move fired on entering the phase
#
# MOVE - common keys:
#   "id", "kind", "weight", "cooldown", "start_cooldown", "range" [lo, hi],
#   "phase_min", "phase_max", "windup", "recovery", "anim" "attack"|"smash",
#   "los" (default: true for grounded direct attacks), "repeat" N,
#   "repeat_p2"/"repeat_p3" (repeat count from that phase on),
#   "repeat_windup", "then_summon" {"count", "max_alive"}
#   payload: "dmg_mult", "knockback", "stun", "poison_stacks",
#            "poison_duration", "burn_stacks", "burn_duration", "slow_stacks"
#
# KINDS
#   "melee_arc"  reach, arc_deg (>=300 = all round), lunge px
#   "aoe_self"   radius, rings [{radius, delay, dmg_mult}] (outward DONUTS)
#   "aoe_point"  pattern scatter|line|ring|ring_player|cross|chase, count,
#                count_p2, spread, spacing, line_start, ring_radius, lead,
#                radius, strike_delay (telegraph time), stagger (s between
#                impacts; boss stays planted meanwhile), leave_hazard {...}
#   "charge"     speed, distance, half_width, hit_radius, fly (over walls),
#                trail_hazard {every, radius, duration, tick_mult, status...}
#   "leap"       target player|near|away|center, lead, track (s), track_speed,
#                air_time, height, style jump|burrow, radius, max_dist,
#                air_invuln (default true), land_rings [...],
#                land_radial {count, speed, dmg_mult, ...}, land_hazard {...}
#   "projectile" count, spread_deg, speed, waves, wave_gap, proj_range, sprite
#   "radial"     count, speed, waves, wave_gap (alternate waves interleave)
#   "hazard"     pattern/count/spread as aoe_point + radius, duration,
#                warmup, tick_interval, tick_mult, status, stacks,
#                status_duration, frost_stacks, color
#   "summon"     count, max_alive
#   "reposition" pure movement
# ============================================================


const DEFAULT_MOVEMENT: Dictionary = {
	"mode": "chase",
	"speed_mult": 1.0,
	"preferred_range": 0.0,
	"reposition_every": 0,
	"reposition_speed_mult": 1.5,
	"reposition_time": 1.4,
}


# Colours for lingering pools (the pool itself; its ARMING ring is always red).
const OIL:    Color = Color(1.00, 0.62, 0.12, 0.36)
const POISON: Color = Color(0.55, 0.85, 0.25, 0.34)
const BRINE:  Color = Color(0.45, 0.70, 0.35, 0.34)
const MAGMA:  Color = Color(1.00, 0.35, 0.10, 0.38)
const CHILI:  Color = Color(0.95, 0.25, 0.10, 0.34)
const FROST:  Color = Color(0.60, 0.85, 1.00, 0.34)
const SUGAR:  Color = Color(0.95, 0.55, 0.80, 0.32)


const SETS: Dictionary = {

	# =======================================================================
	# BEACH - MINI-BOSS - Corn Dog Colossus
	# A boardwalk bouncer that POGOS on its skewer. Plants, swings, and when
	# you back off it springs up and comes down on top of you. Phase II it
	# chains bounces and every landing sprays hot corn kernels.
	# =======================================================================
	"colossus": {
		"display": "Corn Dog Colossus",
		"gcd": 0.75,
		"movement": {
			"mode": "hop",
			"hop_interval": [2.4, 3.4],
			"hop_range": [150.0, 260.0],
			"hop_air": 0.70, "hop_height": 30.0, "hop_windup": 0.30,
			"hop_land_radius": 72.0, "hop_land_dmg": 0.55,
			"hop_when_farther": 420.0,
			"reposition_every": 4,
		},
		"phases": [
			{"hp": 1.00, "name": "I"},
			{"hp": 0.50, "name": "II", "speed_mult": 1.12, "cooldown_mult": 0.80, "on_enter": "pogo_slam"},
		],
		"moves": [
			# Pogo Slam - the signature. Springs high, the marker hunts you,
			# locks, and the skewer drives into the sand.
			{"id": "pogo_slam", "kind": "leap", "weight": 3.0, "cooldown": 4.2,
			 "start_cooldown": 1.0, "range": [120.0, 560.0],
			 "windup": 0.45, "recovery": 0.85, "anim": "smash",
			 "target": "player", "track": 0.55, "track_speed": 190.0,
			 "air_time": 1.05, "height": 44.0, "radius": 105.0, "max_dist": 560.0,
			 "dmg_mult": 1.2, "knockback": 1.1,
			 "repeat_p2": 1, "repeat_windup": 0.35,
			 "land_rings": [{"radius": 175.0, "delay": 0.35, "dmg_mult": 0.7}]},
			# Skewer Smash - wide swing, two-way in phase II (swing, swing BACK).
			{"id": "skewer_smash", "kind": "melee_arc", "weight": 3.0, "cooldown": 2.4,
			 "start_cooldown": 0.6, "range": [0.0, 160.0],
			 "windup": 0.50, "recovery": 0.55, "anim": "attack",
			 "reach": 140.0, "arc_deg": 160.0, "dmg_mult": 1.0, "knockback": 1.15,
			 "repeat_p2": 1, "repeat_windup": 0.32},
			# Batter Quake - punishes hugging it. Inner hit + an outer DONUT: step
			# back in after the first ring and you're safe from the second.
			{"id": "batter_quake", "kind": "aoe_self", "weight": 2.0, "cooldown": 6.0,
			 "start_cooldown": 3.0, "range": [0.0, 200.0],
			 "windup": 0.85, "recovery": 0.70, "anim": "smash",
			 "radius": 140.0, "dmg_mult": 1.0, "knockback": 0.7, "stun": 0.45,
			 "rings": [{"radius": 250.0, "delay": 0.40, "dmg_mult": 0.7}]},
			# Kernel Pop (II) - a corn-kernel ring that pops in two interleaved
			# waves. Weave through the gaps.
			{"id": "kernel_pop", "kind": "radial", "weight": 2.0, "cooldown": 7.0,
			 "start_cooldown": 2.0, "range": [0.0, 520.0], "phase_min": 2,
			 "windup": 0.60, "recovery": 0.55, "anim": "smash",
			 "count": 12, "speed": 240.0, "waves": 2, "wave_gap": 0.40,
			 "dmg_mult": 0.55, "burn_stacks": 1, "proj_range": 520.0},
		],
	},

	# =======================================================================
	# BEACH - BOSS - Corn Dog Kraken
	# Never walks: it SINKS into the sand and erupts under you. Between dives
	# it whips tentacles, geysers hot fry-oil along your path, and belches
	# cotton-candy wisps. Phase III fences you in with a tentacle ring.
	# =======================================================================
	"kraken": {
		"display": "Corn Dog Kraken",
		"gcd": 0.65,
		"movement": {
			"mode": "hop", "hop_style": "burrow",
			"hop_interval": [3.0, 4.2],
			"hop_range": [200.0, 320.0],
			"hop_air": 1.00, "hop_height": 0.0, "hop_windup": 0.40,
			"hop_land_radius": 95.0, "hop_land_dmg": 0.8,
			"hop_when_farther": 460.0,
		},
		"phases": [
			{"hp": 1.00, "name": "I"},
			{"hp": 0.66, "name": "II", "speed_mult": 1.10, "cooldown_mult": 0.85, "on_enter": "squall"},
			{"hp": 0.33, "name": "III", "speed_mult": 1.18, "cooldown_mult": 0.72, "on_enter": "tentacle_cage"},
		],
		"moves": [
			# Undertow Ambush - burrow, the ripple hunts you, then it ERUPTS.
			{"id": "undertow", "kind": "leap", "weight": 3.0, "cooldown": 5.0,
			 "start_cooldown": 1.5, "range": [0.0, 900.0],
			 "windup": 0.45, "recovery": 0.95, "anim": "smash",
			 "target": "player", "style": "burrow", "track": 0.75, "track_speed": 175.0,
			 "air_time": 1.30, "radius": 120.0, "max_dist": 800.0,
			 "dmg_mult": 1.25, "knockback": 1.2, "burn_stacks": 1,
			 "repeat_p3": 1, "repeat_windup": 0.40,
			 "land_radial": {"count": 10, "speed": 230.0, "dmg_mult": 0.5, "proj_range": 460.0}},
			# Tentacle Sweep - huge arc, then the whip comes back the other way.
			{"id": "tentacle_sweep", "kind": "melee_arc", "weight": 3.0, "cooldown": 3.2,
			 "start_cooldown": 0.8, "range": [0.0, 230.0],
			 "windup": 0.65, "recovery": 0.60, "anim": "attack",
			 "reach": 220.0, "arc_deg": 190.0, "dmg_mult": 1.1, "knockback": 1.3,
			 "repeat": 1, "repeat_windup": 0.40},
			# Fry-Oil Geysers - erupt one after another UNDER YOU. Keep moving.
			{"id": "oil_geysers", "kind": "aoe_point", "weight": 2.5, "cooldown": 6.0,
			 "start_cooldown": 3.0, "range": [0.0, 900.0],
			 "windup": 0.45, "recovery": 0.55, "anim": "smash",
			 "pattern": "chase", "count": 5, "count_p2": 7, "stagger": 0.38,
			 "strike_delay": 0.70, "radius": 70.0, "lead": 0.25,
			 "dmg_mult": 0.8, "burn_stacks": 1,
			 "leave_hazard": {"radius": 60.0, "duration": 2.5, "tick_mult": 0.25,
			  "status": "burning", "stacks": 1, "status_duration": 2.5, "color": OIL}},
			# Cotton-Candy Squall - belches wisps into the fight.
			{"id": "squall", "kind": "summon", "weight": 1.5, "cooldown": 11.0,
			 "start_cooldown": 7.0, "range": [0.0, 9999.0],
			 "windup": 0.70, "recovery": 0.50, "anim": "attack",
			 "count": 3, "max_alive": 7},
			# Tentacle Cage (III) - tentacles slam a ring AROUND you, then the
			# middle. Leave through the gap before the second beat.
			{"id": "tentacle_cage", "kind": "aoe_point", "weight": 2.0, "cooldown": 8.0,
			 "start_cooldown": 0.0, "range": [0.0, 900.0], "phase_min": 3,
			 "windup": 0.50, "recovery": 0.80, "anim": "attack",
			 "pattern": "ring_player", "count": 7, "ring_radius": 135.0,
			 "strike_delay": 0.75, "radius": 62.0, "stagger": 0.06,
			 "dmg_mult": 0.9, "knockback": 0.8},
		],
	},

	# =======================================================================
	# JUNGLE - MINI-BOSS - Gummy Gorilla
	# A frantic jumper: bounds around you, pounds with alternating fists, and
	# sprays sticky sour sugar. Phase II it bounces three times in a row.
	# =======================================================================
	"gorilla": {
		"display": "Gummy Gorilla",
		"gcd": 0.6,
		"movement": {
			"mode": "hop",
			"hop_interval": [1.8, 2.8],
			"hop_range": [140.0, 240.0],
			"hop_air": 0.60, "hop_height": 34.0, "hop_windup": 0.25,
			"hop_land_radius": 70.0, "hop_land_dmg": 0.55,
			"hop_when_farther": 380.0,
			"reposition_every": 5,
		},
		"phases": [
			{"hp": 1.00, "name": "I"},
			{"hp": 0.50, "name": "II", "speed_mult": 1.15, "cooldown_mult": 0.78, "on_enter": "chest_thump"},
		],
		"moves": [
			# Gummy Bounce - short tracked leaps; II chains three.
			{"id": "gummy_bounce", "kind": "leap", "weight": 3.0, "cooldown": 3.8,
			 "start_cooldown": 0.8, "range": [100.0, 520.0],
			 "windup": 0.35, "recovery": 0.65, "anim": "smash",
			 "target": "player", "track": 0.40, "track_speed": 200.0,
			 "air_time": 0.85, "height": 40.0, "radius": 95.0, "max_dist": 480.0,
			 "dmg_mult": 1.1, "knockback": 1.1,
			 "repeat_p2": 2, "repeat_windup": 0.22},
			# Knuckle Pound - left, right: two lunging fist slams.
			{"id": "knuckle_pound", "kind": "melee_arc", "weight": 3.0, "cooldown": 2.4,
			 "start_cooldown": 0.4, "range": [0.0, 170.0],
			 "windup": 0.45, "recovery": 0.55, "anim": "attack",
			 "reach": 130.0, "arc_deg": 120.0, "lunge": 36.0,
			 "dmg_mult": 1.0, "knockback": 1.2,
			 "repeat": 1, "repeat_windup": 0.28},
			# Sour-Sugar Splatter - sticky poison globs lobbed around you.
			{"id": "sugar_splatter", "kind": "aoe_point", "weight": 2.0, "cooldown": 6.5,
			 "start_cooldown": 2.5, "range": [0.0, 600.0],
			 "windup": 0.55, "recovery": 0.50, "anim": "smash",
			 "pattern": "scatter", "count": 5, "spread": 170.0, "lead": 0.35,
			 "strike_delay": 0.85, "radius": 70.0, "stagger": 0.08,
			 "dmg_mult": 0.7, "poison_stacks": 1,
			 "leave_hazard": {"radius": 58.0, "duration": 3.0, "tick_mult": 0.2,
			  "status": "poison", "stacks": 1, "status_duration": 3.0, "color": SUGAR}},
			# Chest Thump (II) - long wind-up, BIG shove: get out or get launched.
			{"id": "chest_thump", "kind": "aoe_self", "weight": 1.5, "cooldown": 8.0,
			 "start_cooldown": 0.0, "range": [0.0, 260.0], "phase_min": 2,
			 "windup": 1.00, "recovery": 0.80, "anim": "smash",
			 "radius": 210.0, "dmg_mult": 1.1, "knockback": 1.5, "stun": 0.40},
		],
	},

	# =======================================================================
	# JUNGLE - BOSS - Banana-Split Simian
	# The acrobat. Vine-swings across the arena, lobs scoop barrages, hurls
	# banana fans, drops fudge-fist slams that splash in a ring, and calls
	# trail-mix squirrels. Phase III: splits the sundae - bullet rings.
	# =======================================================================
	"simian": {
		"display": "Banana-Split Simian",
		"gcd": 0.55,
		"movement": {
			"mode": "hop",
			"hop_interval": [1.8, 2.6],
			"hop_range": [220.0, 360.0],
			"hop_air": 0.70, "hop_height": 50.0, "hop_windup": 0.22,
			"hop_land_radius": 70.0, "hop_land_dmg": 0.5,
			"hop_when_farther": 520.0,
			"reposition_every": 3,
		},
		"phases": [
			{"hp": 1.00, "name": "I"},
			{"hp": 0.66, "name": "II", "speed_mult": 1.12, "cooldown_mult": 0.85, "on_enter": "trail_mix_call"},
			{"hp": 0.33, "name": "III", "speed_mult": 1.20, "cooldown_mult": 0.72, "on_enter": "banana_split"},
		],
		"moves": [
			# Fudge-Fist Leap - high vault onto you; fudge splashes outward.
			{"id": "fudge_leap", "kind": "leap", "weight": 3.0, "cooldown": 4.2,
			 "start_cooldown": 1.0, "range": [120.0, 700.0],
			 "windup": 0.40, "recovery": 0.80, "anim": "smash",
			 "target": "player", "track": 0.55, "track_speed": 195.0,
			 "air_time": 1.05, "height": 60.0, "radius": 115.0, "max_dist": 700.0,
			 "dmg_mult": 1.25, "knockback": 1.2,
			 "repeat_p2": 1, "repeat_windup": 0.30,
			 "land_radial": {"count": 8, "speed": 210.0, "dmg_mult": 0.5, "proj_range": 420.0}},
			# Scoop Barrage - lobbed ice-cream scoops led onto your path.
			{"id": "scoop_barrage", "kind": "aoe_point", "weight": 2.5, "cooldown": 5.0,
			 "start_cooldown": 2.0, "range": [150.0, 900.0],
			 "windup": 0.55, "recovery": 0.45, "anim": "attack",
			 "pattern": "scatter", "count": 5, "count_p2": 7, "spread": 190.0, "lead": 0.45,
			 "strike_delay": 0.90, "radius": 75.0, "stagger": 0.12,
			 "dmg_mult": 0.8, "slow_stacks": 1},
			# Banana Fan - a spread of boomerang bananas, three volleys.
			{"id": "banana_fan", "kind": "projectile", "weight": 2.0, "cooldown": 5.5,
			 "start_cooldown": 3.0, "range": [120.0, 900.0],
			 "windup": 0.45, "recovery": 0.45, "anim": "attack",
			 "count": 5, "spread_deg": 55.0, "speed": 320.0,
			 "waves": 3, "wave_gap": 0.28, "dmg_mult": 0.6},
			# Vine Swing - two rapid vaults to either side of you, then a slam.
			{"id": "vine_swing", "kind": "leap", "weight": 2.0, "cooldown": 7.0,
			 "start_cooldown": 4.0, "range": [0.0, 900.0], "phase_min": 2,
			 "windup": 0.30, "recovery": 0.70, "anim": "smash",
			 "target": "near", "track": 0.0, "air_time": 0.55, "height": 44.0,
			 "radius": 80.0, "max_dist": 600.0, "dmg_mult": 0.8, "knockback": 0.9,
			 "repeat": 2, "repeat_windup": 0.15},
			# Trail-Mix Call - chest-beat, squirrels pour in.
			{"id": "trail_mix_call", "kind": "summon", "weight": 1.5, "cooldown": 12.0,
			 "start_cooldown": 8.0, "range": [0.0, 9999.0],
			 "windup": 0.70, "recovery": 0.50, "anim": "smash",
			 "count": 3, "max_alive": 7},
			# Banana Split (III) - two interleaved bullet rings of sprinkles.
			{"id": "banana_split", "kind": "radial", "weight": 2.0, "cooldown": 7.5,
			 "start_cooldown": 0.0, "range": [0.0, 9999.0], "phase_min": 3,
			 "windup": 0.70, "recovery": 0.60, "anim": "smash",
			 "count": 16, "speed": 250.0, "waves": 3, "wave_gap": 0.35,
			 "dmg_mult": 0.5, "proj_range": 620.0},
		],
	},

	# =======================================================================
	# SWAMP - MINI-BOSS - Mustard Marauder  (re-hosted on BossBrain)
	# The artillery. Keeps its distance by HOPPING away, fires burst volleys,
	# floods lanes with brine, and rains mustard mortars that chase you. Get
	# close and it slams its lid to shove you off.
	# =======================================================================
	"mustard": {
		"display": "Mustard Marauder",
		"gcd": 0.55,
		"movement": {
			"mode": "hop",
			"hop_interval": [2.2, 3.2],
			"hop_range": [280.0, 380.0],
			"hop_air": 0.65, "hop_height": 32.0, "hop_windup": 0.25,
			"hop_land_radius": 70.0, "hop_land_dmg": 0.5,
			"hop_when_farther": 560.0, "hop_anim": "attack",
			"reposition_every": 3,
		},
		"phases": [
			{"hp": 1.00, "name": "I"},
			{"hp": 0.50, "name": "II", "speed_mult": 1.12, "cooldown_mult": 0.80, "on_enter": "mustard_rain"},
		],
		"moves": [
			# Mustard Volley - three burst fans; each glob stings with poison.
			{"id": "volley", "kind": "projectile", "weight": 3.0, "cooldown": 3.0,
			 "start_cooldown": 0.8, "range": [120.0, 900.0],
			 "windup": 0.45, "recovery": 0.45, "anim": "attack",
			 "count": 5, "spread_deg": 44.0, "speed": 340.0,
			 "waves": 3, "wave_gap": 0.26, "dmg_mult": 0.55, "poison_stacks": 1},
			# Brine Bog - pools that slow you where the volleys land.
			{"id": "brine_bog", "kind": "hazard", "weight": 2.0, "cooldown": 7.0,
			 "start_cooldown": 2.5, "range": [0.0, 900.0],
			 "windup": 0.50, "recovery": 0.45, "anim": "attack",
			 "pattern": "scatter", "count": 3, "spread": 160.0, "lead": 0.3,
			 "radius": 80.0, "duration": 5.0, "warmup": 0.70, "tick_interval": 0.6,
			 "tick_mult": 0.25, "status": "poison", "stacks": 1, "status_duration": 2.5,
			 "frost_stacks": 1, "color": BRINE},
			# Lid Slam - the answer to melee: short-fuse shove.
			{"id": "lid_slam", "kind": "aoe_self", "weight": 3.0, "cooldown": 4.0,
			 "start_cooldown": 1.0, "range": [0.0, 140.0],
			 "windup": 0.55, "recovery": 0.55, "anim": "attack",
			 "radius": 150.0, "dmg_mult": 0.9, "knockback": 1.4},
			# Condiment Hop - leaps AWAY and splatters a glob ring on landing.
			{"id": "condiment_hop", "kind": "leap", "weight": 2.0, "cooldown": 6.0,
			 "start_cooldown": 3.0, "range": [0.0, 260.0],
			 "windup": 0.30, "recovery": 0.55, "anim": "attack",
			 "target": "away", "air_time": 0.75, "height": 40.0, "radius": 80.0,
			 "max_dist": 520.0, "dmg_mult": 0.7,
			 "land_radial": {"count": 10, "speed": 230.0, "dmg_mult": 0.45,
			  "poison_stacks": 1, "proj_range": 480.0}},
			# Mustard Rain (II) - mortars that follow you across the mire.
			{"id": "mustard_rain", "kind": "aoe_point", "weight": 2.0, "cooldown": 7.5,
			 "start_cooldown": 0.0, "range": [0.0, 900.0], "phase_min": 2,
			 "windup": 0.50, "recovery": 0.60, "anim": "attack",
			 "pattern": "chase", "count": 6, "stagger": 0.34, "lead": 0.3,
			 "strike_delay": 0.75, "radius": 68.0, "dmg_mult": 0.75, "poison_stacks": 1},
		],
	},

	# =======================================================================
	# SWAMP - BOSS - Pickled Hydra
	# A barrel that SUBMERGES and resurfaces under you. Its heads bite where you
	# stand (three chomps chasing you), spit brine, and roll out fermenting fog
	# that stuns. Phase II: heads strike in a ring around the barrel. Phase III:
	# the whole brine bursts - spit rings.
	# =======================================================================
	"hydra": {
		"display": "Pickled Hydra",
		"gcd": 0.6,
		"movement": {
			"mode": "hop", "hop_style": "burrow",
			"hop_interval": [3.2, 4.4],
			"hop_range": [210.0, 330.0],
			"hop_air": 1.05, "hop_height": 0.0, "hop_windup": 0.40,
			"hop_land_radius": 100.0, "hop_land_dmg": 0.8,
			"hop_when_farther": 480.0,
		},
		"phases": [
			{"hp": 1.00, "name": "I"},
			{"hp": 0.66, "name": "II", "speed_mult": 1.10, "cooldown_mult": 0.85, "on_enter": "head_frenzy"},
			{"hp": 0.33, "name": "III", "speed_mult": 1.18, "cooldown_mult": 0.72, "on_enter": "brine_burst"},
		],
		"moves": [
			# Snapping Heads - three bites that land where you WERE standing.
			{"id": "snapping_heads", "kind": "aoe_point", "weight": 3.0, "cooldown": 3.8,
			 "start_cooldown": 0.8, "range": [0.0, 420.0],
			 "windup": 0.40, "recovery": 0.55, "anim": "attack",
			 "pattern": "chase", "count": 3, "count_p2": 4, "stagger": 0.42,
			 "strike_delay": 0.62, "radius": 78.0, "lead": 0.15,
			 "dmg_mult": 1.0, "poison_stacks": 1},
			# Brine Spit - volleys from the heads.
			{"id": "brine_spit", "kind": "projectile", "weight": 2.5, "cooldown": 4.5,
			 "start_cooldown": 2.0, "range": [150.0, 900.0],
			 "windup": 0.50, "recovery": 0.45, "anim": "attack",
			 "count": 3, "spread_deg": 34.0, "speed": 330.0,
			 "waves": 3, "wave_gap": 0.30, "dmg_mult": 0.6, "poison_stacks": 1},
			# Fermenting Fog - long-fuse stun cloud, leaves a poison haze.
			{"id": "fermenting_fog", "kind": "aoe_self", "weight": 1.5, "cooldown": 8.0,
			 "start_cooldown": 4.0, "range": [0.0, 260.0],
			 "windup": 1.05, "recovery": 0.70, "anim": "smash",
			 "radius": 200.0, "dmg_mult": 0.8, "stun": 0.70, "poison_stacks": 1,
			 "rings": [{"radius": 300.0, "delay": 0.45, "dmg_mult": 0.5}]},
			# Brine Dive - submerge and erupt under you.
			{"id": "brine_dive", "kind": "leap", "weight": 2.5, "cooldown": 5.5,
			 "start_cooldown": 3.0, "range": [0.0, 900.0],
			 "windup": 0.45, "recovery": 0.95, "anim": "smash",
			 "target": "player", "style": "burrow", "track": 0.75, "track_speed": 175.0,
			 "air_time": 1.30, "radius": 125.0, "max_dist": 800.0,
			 "dmg_mult": 1.2, "knockback": 1.0, "poison_stacks": 2,
			 "land_hazard": {"radius": 95.0, "duration": 3.5, "tick_mult": 0.25,
			  "status": "poison", "stacks": 1, "status_duration": 3.0, "color": POISON},
			 "then_summon": {"count": 2, "max_alive": 7}},
			# Head Frenzy (II) - every head strikes a ring round the barrel, then
			# the inner ring. Stay mid-distance or dance between.
			{"id": "head_frenzy", "kind": "aoe_point", "weight": 2.0, "cooldown": 7.0,
			 "start_cooldown": 0.0, "range": [0.0, 400.0], "phase_min": 2,
			 "windup": 0.55, "recovery": 0.75, "anim": "attack",
			 "pattern": "ring", "count": 8, "ring_radius": 170.0,
			 "strike_delay": 0.75, "radius": 70.0, "stagger": 0.05,
			 "dmg_mult": 0.9, "poison_stacks": 1},
			# Brine Burst (III) - the barrel pops: spit rings.
			{"id": "brine_burst", "kind": "radial", "weight": 2.0, "cooldown": 7.0,
			 "start_cooldown": 0.0, "range": [0.0, 9999.0], "phase_min": 3,
			 "windup": 0.70, "recovery": 0.60, "anim": "smash",
			 "count": 14, "speed": 235.0, "waves": 3, "wave_gap": 0.40,
			 "dmg_mult": 0.5, "poison_stacks": 1, "proj_range": 600.0},
		],
	},

	# =======================================================================
	# CAVERNS - MINI-BOSS - Rock-Candy Golem
	# Heavy and deliberate. Its crashing leap is slow but huge and flings
	# crystal shards; it splits the floor with travelling FAULT LINES and
	# flares its molten core in two rings. Phase II opens magma vents.
	# =======================================================================
	"rockcandy": {
		"display": "Rock-Candy Golem",
		"gcd": 0.8,
		"movement": {
			"mode": "hop",
			"hop_interval": [3.0, 4.0],
			"hop_range": [160.0, 260.0],
			"hop_air": 0.85, "hop_height": 26.0, "hop_windup": 0.40,
			"hop_land_radius": 85.0, "hop_land_dmg": 0.6,
			"hop_when_farther": 420.0,
		},
		"phases": [
			{"hp": 1.00, "name": "I"},
			{"hp": 0.50, "name": "II", "speed_mult": 1.10, "cooldown_mult": 0.80, "on_enter": "magma_vents"},
		],
		"moves": [
			# Crystal Crash - slow, high, heavy. Shards burst out on impact.
			{"id": "crystal_crash", "kind": "leap", "weight": 3.0, "cooldown": 4.8,
			 "start_cooldown": 1.2, "range": [120.0, 600.0],
			 "windup": 0.60, "recovery": 1.05, "anim": "smash",
			 "target": "player", "track": 0.65, "track_speed": 170.0,
			 "air_time": 1.30, "height": 52.0, "radius": 130.0, "max_dist": 560.0,
			 "dmg_mult": 1.35, "knockback": 1.0, "stun": 0.40,
			 "land_radial": {"count": 10, "speed": 220.0, "dmg_mult": 0.5, "proj_range": 440.0}},
			# Crystal Smash - one enormous fist.
			{"id": "crystal_smash", "kind": "melee_arc", "weight": 3.0, "cooldown": 2.8,
			 "start_cooldown": 0.6, "range": [0.0, 170.0],
			 "windup": 0.60, "recovery": 0.65, "anim": "attack",
			 "reach": 150.0, "arc_deg": 130.0, "dmg_mult": 1.2, "knockback": 1.1, "stun": 0.35},
			# Fault Line - a crack races from the golem through you. Side-step.
			{"id": "fault_line", "kind": "aoe_point", "weight": 2.5, "cooldown": 5.0,
			 "start_cooldown": 2.0, "range": [140.0, 900.0],
			 "windup": 0.55, "recovery": 0.55, "anim": "smash",
			 "pattern": "line", "count": 8, "spacing": 68.0, "line_start": 70.0,
			 "strike_delay": 0.55, "radius": 58.0, "stagger": 0.09,
			 "dmg_mult": 0.9, "burn_stacks": 1},
			# Core Flare - molten core: inner burst, then an outer donut.
			{"id": "core_flare", "kind": "aoe_self", "weight": 2.0, "cooldown": 6.5,
			 "start_cooldown": 3.5, "range": [0.0, 220.0],
			 "windup": 0.90, "recovery": 0.70, "anim": "smash",
			 "radius": 160.0, "dmg_mult": 1.0, "burn_stacks": 2,
			 "rings": [{"radius": 270.0, "delay": 0.45, "dmg_mult": 0.7}]},
			# Magma Vents (II) - burning pools crack open around you.
			{"id": "magma_vents", "kind": "hazard", "weight": 1.5, "cooldown": 9.0,
			 "start_cooldown": 0.0, "range": [0.0, 900.0], "phase_min": 2,
			 "windup": 0.50, "recovery": 0.50, "anim": "smash",
			 "pattern": "scatter", "count": 4, "spread": 200.0,
			 "radius": 75.0, "duration": 5.0, "warmup": 0.80, "tick_interval": 0.5,
			 "tick_mult": 0.3, "status": "burning", "stacks": 1, "status_duration": 2.5,
			 "color": MAGMA},
		],
	},

	# =======================================================================
	# CAVERNS - BOSS - Spicy Ramen Phoenix  (FLYER)
	# Circles above the arena and only touches down to plunge. Ember Dives
	# rake the floor and leave fire; Broth Rain pours down; Feather Fans are
	# bullet rings. Phase III: Rebirth Blaze - the whole floor erupts.
	# =======================================================================
	"phoenix": {
		"display": "Spicy Ramen Phoenix",
		"gcd": 0.55,
		"movement": {
			"mode": "fly",
			"fly_height": 46.0,
			"preferred_range": 280.0,
			"orbit_speed": 0.75,
			"speed_mult": 1.6,
			"reposition_every": 4,
		},
		"phases": [
			{"hp": 1.00, "name": "I"},
			{"hp": 0.66, "name": "II", "speed_mult": 1.12, "cooldown_mult": 0.85, "on_enter": "chili_slick"},
			{"hp": 0.33, "name": "III", "speed_mult": 1.22, "cooldown_mult": 0.70, "on_enter": "rebirth_blaze"},
		],
		"moves": [
			# Ember Dive - screams across the arena along the RED lane, leaving a
			# burning trail. II/III chain back-to-back dives.
			{"id": "ember_dive", "kind": "charge", "weight": 3.0, "cooldown": 4.2,
			 "start_cooldown": 1.2, "range": [120.0, 900.0],
			 "windup": 0.70, "recovery": 0.55, "anim": "attack",
			 "speed": 640.0, "distance": 900.0, "half_width": 42.0, "hit_radius": 62.0,
			 "dmg_mult": 1.15, "knockback": 1.0, "burn_stacks": 1,
			 "repeat_p2": 1, "repeat_p3": 2, "repeat_windup": 0.45,
			 "trail_hazard": {"every": 85.0, "radius": 46.0, "duration": 2.4,
			  "tick_mult": 0.25, "status": "burning", "stacks": 1, "status_duration": 2.0,
			  "color": CHILI}},
			# Talon Plunge - drops out of the sky onto you, then is GROUNDED
			# for a long beat: the big punish window.
			{"id": "talon_plunge", "kind": "leap", "weight": 2.5, "cooldown": 5.5,
			 "start_cooldown": 3.0, "range": [0.0, 900.0],
			 "windup": 0.40, "recovery": 1.40, "anim": "smash",
			 "target": "player", "track": 0.70, "track_speed": 190.0,
			 "air_time": 1.15, "height": 30.0, "radius": 120.0, "max_dist": 900.0,
			 "dmg_mult": 1.3, "knockback": 1.2, "burn_stacks": 1,
			 "land_rings": [{"radius": 200.0, "delay": 0.35, "dmg_mult": 0.6}]},
			# Broth Rain - scalding gouts poured over the hero's area.
			{"id": "broth_rain", "kind": "aoe_point", "weight": 2.5, "cooldown": 5.0,
			 "start_cooldown": 2.0, "range": [0.0, 900.0],
			 "windup": 0.50, "recovery": 0.45, "anim": "attack",
			 "pattern": "scatter", "count": 7, "count_p2": 9, "spread": 230.0, "lead": 0.35,
			 "strike_delay": 0.80, "radius": 66.0, "stagger": 0.10,
			 "dmg_mult": 0.8, "burn_stacks": 1},
			# Feather Fan - two interleaved rings of burning feathers.
			{"id": "feather_fan", "kind": "radial", "weight": 2.0, "cooldown": 6.0,
			 "start_cooldown": 3.5, "range": [0.0, 9999.0],
			 "windup": 0.55, "recovery": 0.45, "anim": "attack",
			 "count": 14, "speed": 260.0, "waves": 2, "wave_gap": 0.38,
			 "dmg_mult": 0.5, "burn_stacks": 1, "proj_range": 620.0},
			# Chili-Oil Slick (II) - slowing oil under you + chili critters.
			{"id": "chili_slick", "kind": "hazard", "weight": 1.5, "cooldown": 11.0,
			 "start_cooldown": 0.0, "range": [0.0, 9999.0], "phase_min": 2,
			 "windup": 0.60, "recovery": 0.50, "anim": "attack",
			 "pattern": "scatter", "count": 3, "spread": 170.0,
			 "radius": 90.0, "duration": 5.5, "warmup": 0.70, "tick_interval": 0.6,
			 "tick_mult": 0.2, "status": "burning", "stacks": 1, "status_duration": 2.0,
			 "frost_stacks": 1, "color": CHILI,
			 "then_summon": {"count": 3, "max_alive": 8}},
			# Rebirth Blaze (III) - long fuse, then three expanding fire rings.
			{"id": "rebirth_blaze", "kind": "aoe_self", "weight": 1.5, "cooldown": 10.0,
			 "start_cooldown": 0.0, "range": [0.0, 9999.0], "phase_min": 3,
			 "windup": 1.20, "recovery": 0.90, "anim": "smash",
			 "radius": 170.0, "dmg_mult": 1.2, "burn_stacks": 2,
			 "rings": [{"radius": 300.0, "delay": 0.45, "dmg_mult": 0.8},
			           {"radius": 430.0, "delay": 0.90, "dmg_mult": 0.6}]},
		],
	},

	# =======================================================================
	# FROSTPEAK - MINI-BOSS - Sundae Sentinel
	# The disciplined spear-knight. Pole-VAULTS onto you, thrusts in long
	# lunging lines (two in phase II), fences you in with icicle volleys and
	# stomps frost shockwaves. Never jogs - it vaults.
	# =======================================================================
	"sentinel": {
		"display": "Sundae Sentinel",
		"gcd": 0.65,
		"movement": {
			"mode": "hop",
			"hop_interval": [2.4, 3.4],
			"hop_range": [170.0, 280.0],
			"hop_air": 0.70, "hop_height": 42.0, "hop_windup": 0.30,
			"hop_land_radius": 70.0, "hop_land_dmg": 0.5,
			"hop_when_farther": 440.0,
			"reposition_every": 4,
		},
		"phases": [
			{"hp": 1.00, "name": "I"},
			{"hp": 0.50, "name": "II", "speed_mult": 1.12, "cooldown_mult": 0.80, "on_enter": "frost_stomp"},
		],
		"moves": [
			# Spear Vault - high tracked vault, spear-first. II: vault twice.
			{"id": "spear_vault", "kind": "leap", "weight": 3.0, "cooldown": 4.2,
			 "start_cooldown": 1.0, "range": [140.0, 620.0],
			 "windup": 0.40, "recovery": 0.80, "anim": "attack",
			 "target": "player", "track": 0.50, "track_speed": 195.0,
			 "air_time": 0.95, "height": 58.0, "radius": 95.0, "max_dist": 600.0,
			 "dmg_mult": 1.2, "knockback": 0.8, "slow_stacks": 1,
			 "repeat_p2": 1, "repeat_windup": 0.30},
			# Wafer Thrust - a long lunge down a RED lane; II thrusts again.
			{"id": "wafer_thrust", "kind": "charge", "weight": 3.0, "cooldown": 3.4,
			 "start_cooldown": 0.8, "range": [0.0, 420.0],
			 "windup": 0.55, "recovery": 0.60, "anim": "attack",
			 "speed": 720.0, "distance": 330.0, "half_width": 28.0, "hit_radius": 50.0,
			 "dmg_mult": 1.1, "knockback": 0.9, "slow_stacks": 1,
			 "repeat_p2": 1, "repeat_windup": 0.35},
			# Icicle Volley - narrow fans that box you into a lane.
			{"id": "icicle_volley", "kind": "projectile", "weight": 2.0, "cooldown": 5.0,
			 "start_cooldown": 2.5, "range": [160.0, 900.0],
			 "windup": 0.45, "recovery": 0.40, "anim": "attack",
			 "count": 3, "spread_deg": 26.0, "speed": 360.0,
			 "waves": 3, "wave_gap": 0.30, "dmg_mult": 0.55, "slow_stacks": 1},
			# Frost Stomp - inner stomp + an outer frost donut.
			{"id": "frost_stomp", "kind": "aoe_self", "weight": 2.0, "cooldown": 6.0,
			 "start_cooldown": 3.0, "range": [0.0, 220.0],
			 "windup": 0.80, "recovery": 0.65, "anim": "smash",
			 "radius": 145.0, "dmg_mult": 1.0, "knockback": 1.3, "slow_stacks": 1,
			 "rings": [{"radius": 245.0, "delay": 0.38, "dmg_mult": 0.7}]},
		],
	},

	# =======================================================================
	# FROSTPEAK - BOSS - Brain-Freeze Yeti Sundae
	# The avalanche. Its Body Slam is the biggest landing in the game and
	# throws ice chunks; it swipes twice, cannons scoops onto you, and roars a
	# stun wave that calls the wraiths. Phase II: icicles rain and it slides
	# across the glacier. Phase III: back-to-back slams.
	# =======================================================================
	"yetiboss": {
		"display": "Brain-Freeze Yeti Sundae",
		"gcd": 0.6,
		"movement": {
			"mode": "hop",
			"hop_interval": [2.6, 3.6],
			"hop_range": [190.0, 300.0],
			"hop_air": 0.80, "hop_height": 32.0, "hop_windup": 0.35,
			"hop_land_radius": 90.0, "hop_land_dmg": 0.7,
			"hop_when_farther": 460.0,
			"reposition_every": 4,
		},
		"phases": [
			{"hp": 1.00, "name": "I"},
			{"hp": 0.66, "name": "II", "speed_mult": 1.10, "cooldown_mult": 0.85, "on_enter": "brain_freeze_roar"},
			{"hp": 0.33, "name": "III", "speed_mult": 1.18, "cooldown_mult": 0.72, "on_enter": "avalanche_slam"},
		],
		"moves": [
			# Avalanche Body Slam - huge tracked slam; ice chunks fly out and a
			# frost donut follows. III: slams twice.
			{"id": "avalanche_slam", "kind": "leap", "weight": 3.0, "cooldown": 5.0,
			 "start_cooldown": 1.2, "range": [120.0, 800.0],
			 "windup": 0.55, "recovery": 1.00, "anim": "smash",
			 "target": "player", "track": 0.70, "track_speed": 185.0,
			 "air_time": 1.35, "height": 56.0, "radius": 140.0, "max_dist": 760.0,
			 "dmg_mult": 1.35, "knockback": 1.2, "stun": 0.30, "slow_stacks": 1,
			 "repeat_p3": 1, "repeat_windup": 0.40,
			 "land_radial": {"count": 12, "speed": 220.0, "dmg_mult": 0.5, "slow_stacks": 1, "proj_range": 500.0},
			 "land_rings": [{"radius": 240.0, "delay": 0.40, "dmg_mult": 0.6}]},
			# Avalanche Swipe - rake, then rake back.
			{"id": "avalanche_swipe", "kind": "melee_arc", "weight": 3.0, "cooldown": 3.0,
			 "start_cooldown": 0.6, "range": [0.0, 210.0],
			 "windup": 0.60, "recovery": 0.60, "anim": "attack",
			 "reach": 190.0, "arc_deg": 170.0, "lunge": 30.0,
			 "dmg_mult": 1.15, "knockback": 1.2, "slow_stacks": 1,
			 "repeat": 1, "repeat_windup": 0.35},
			# Scoop Cannon - heavy frozen scoops lobbed where you're going.
			{"id": "scoop_cannon", "kind": "aoe_point", "weight": 2.5, "cooldown": 5.0,
			 "start_cooldown": 2.0, "range": [150.0, 900.0],
			 "windup": 0.55, "recovery": 0.45, "anim": "attack",
			 "pattern": "scatter", "count": 4, "count_p2": 6, "spread": 170.0, "lead": 0.45,
			 "strike_delay": 0.95, "radius": 85.0, "stagger": 0.15,
			 "dmg_mult": 0.9, "slow_stacks": 1,
			 "leave_hazard": {"radius": 70.0, "duration": 3.0, "tick_mult": 0.0,
			  "frost_stacks": 1, "tick_interval": 0.8, "color": FROST}},
			# Brain-Freeze Roar - long wind-up stun wave, then wraiths swoop in.
			{"id": "brain_freeze_roar", "kind": "aoe_self", "weight": 1.5, "cooldown": 11.0,
			 "start_cooldown": 6.0, "range": [0.0, 9999.0],
			 "windup": 1.10, "recovery": 0.80, "anim": "smash",
			 "radius": 220.0, "dmg_mult": 0.8, "stun": 0.60,
			 "rings": [{"radius": 340.0, "delay": 0.45, "dmg_mult": 0.5}],
			 "then_summon": {"count": 3, "max_alive": 8}},
			# Icicle Rain (II) - a wide hail of small impacts; keep threading.
			{"id": "icicle_rain", "kind": "aoe_point", "weight": 2.0, "cooldown": 7.0,
			 "start_cooldown": 2.0, "range": [0.0, 9999.0], "phase_min": 2,
			 "windup": 0.50, "recovery": 0.50, "anim": "smash",
			 "pattern": "scatter", "count": 12, "spread": 320.0,
			 "strike_delay": 0.75, "radius": 52.0, "stagger": 0.07,
			 "dmg_mult": 0.65, "slow_stacks": 1},
			# Glacier Slide (II) - belly-slides across the ice down a RED lane.
			{"id": "glacier_slide", "kind": "charge", "weight": 2.0, "cooldown": 6.5,
			 "start_cooldown": 3.0, "range": [160.0, 900.0], "phase_min": 2,
			 "windup": 0.70, "recovery": 0.75, "anim": "smash",
			 "speed": 600.0, "distance": 720.0, "half_width": 46.0, "hit_radius": 66.0,
			 "dmg_mult": 1.1, "knockback": 1.3, "slow_stacks": 1},
		],
	},
}


# ---------------------------------------------------------------------------
# Lookup. Unknown / empty id -> the legacy pool.
# ---------------------------------------------------------------------------
static func resolve(id: String, has_smash: bool) -> Dictionary:
	if id != "" and SETS.has(id):
		var found: Dictionary = (SETS[id] as Dictionary).duplicate(true)
		if not found.has("movement"):
			found["movement"] = DEFAULT_MOVEMENT.duplicate(true)
		else:
			var mv: Dictionary = DEFAULT_MOVEMENT.duplicate(true)
			mv.merge(found["movement"] as Dictionary, true)
			found["movement"] = mv
		return found
	return legacy_pool(has_smash)


static func has_set(id: String) -> bool:
	return id != "" and SETS.has(id)


# ---------------------------------------------------------------------------
# The pre-Run-173 behaviour, expressed in the new schema. Chase, bite at
# contact range, self-centred smash every 5.5s if the config had one.
# ---------------------------------------------------------------------------
static func legacy_pool(has_smash: bool) -> Dictionary:
	var moves: Array = [
		{
			"id": "legacy_bite",
			"kind": "melee_arc",
			"weight": 1.0,
			"cooldown": 1.5,
			"start_cooldown": 0.0,
			"range": [0.0, 34.0],
			"windup": 0.28,
			"recovery": 0.45,
			"anim": "attack",
			"reach": 54.0,
			"arc_deg": 360.0,
			"dmg_mult": 1.0,
			"knockback": 0.0,
		},
	]
	if has_smash:
		moves.append({
			"id": "legacy_smash",
			"kind": "aoe_self",
			"weight": 1.0,
			"cooldown": 5.5,
			"start_cooldown": 3.0,
			"range": [0.0, 190.0],
			"windup": 0.85,
			"recovery": 0.55,
			"anim": "smash",
			"radius": 130.0,
			"dmg_mult": 1.0,
			"knockback": 0.7,
		})
	return {
		"display": "",
		"gcd": 0.0,
		"movement": DEFAULT_MOVEMENT.duplicate(true),
		"phases": [],
		"moves": moves,
		"legacy": true,
	}
