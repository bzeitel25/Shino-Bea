extends "res://scripts/HeroBase.gd"

const ICE = preload("res://scripts/IceField.gd")   # Frostpeak slippery-ice glide

# ============================================================
# Player.gd — Shino base controller (Phase 1 + 2 + 3 + 4 complete)
# ============================================================
# Phase 3 additions:
#   - B dash with i-frames (§8.2.-1 global dash rule)
#   - Combo Counter (HUD bar, §8.3.1)
#   - Chi meter (§8.3.2 universal Chi)
#   - Signals emitted for HP / Chi / Combo → HUD.gd
#   - i-frame invulnerability window during/after dash
#
# Phase 4 (now complete) additions:
#   - Universal Charge Attack Model (§8.2.0):
#       * Hold-detect window after press → enter CHARGING (locked 0.7s wind-up)
#       * After wind-up → CHARGED (can hold indefinitely, can steer facing)
#       * Release → unleash attack at full power
#       * Dash (B) cancels charge without firing
#       * Super-armor stub: take_damage applies, but no hurt-stagger flow exists yet
#   - Hold Y → Punch Flurry (§8.2.1): forward multi-hit barrage with finisher.
#   - Hold X → Spinning Crane Kick (§8.2.1, Run 48): in-place double spin —
#     leg-blade visual, heavy capped damage + outward shove + 0.5s stun.
#     Spawns scenes/SpinningCraneKick.tscn at caster's position.
#   - Hold A → Kamehameha (§8.2.1): auto-aims to nearest enemy in forward cone,
#     snaps facing, spawns scenes/KamehamehaBeam.tscn which ticks damage for ~0.4s.
#   - Ult button (U / right trigger) when Chi == MAX → Final Ki Blast stub
#     (§8.2.3): screen-wide AoE damaging all enemies in the "enemy" group,
#     consumes Chi, brief dizzy lockout, then back to IDLE.
#   - Visible "ChargeAura" tell — yellow during CHARGING, brighter/larger CHARGED.
# ============================================================

# --- Tunable stats (placeholder — balance in playtest) ---
@export var move_speed: float = 220.0
# max_hp moved to HeroBase (Batch 5; @export, base default 100 = Shino).
# current_hp moved to HeroBase (Batch 3); reset to max_hp at _ready top.
# _last_applied_max_hp moved to HeroBase (Batch 5).

# --- Dash (GDD §8.2.-1: global dash rule) ---
# Tuned: shorter distance (~2/3 of original 126px = ~84px) but higher
# impulse speed so it reads as a snappy burst rather than a slow roll.
const DASH_SPEED: float = 950.0
const DASH_DURATION: float = 0.09          # 950 × 0.09 ≈ 85px ≈ 2/3 original
const DASH_INTERNAL_CD: float = 0.5        # baseline CD per charge
const DASH_IFRAME_DURATION: float = 0.13   # i-frames slightly longer than burst
var dash_timer: float = 0.0
var _dash_ghost_cd: float = 0.0          # afterimage spawn cooldown
const DASH_GHOST_INTERVAL: float = 0.02  # spawn a ghost every ~20ms during dash
# dash_cd_timer, iframe_timer moved to HeroBase (Batch 4)
var dash_direction: Vector2 = Vector2.ZERO
# is_invulnerable, _drupe_invuln_timer moved to HeroBase (Batch 4)
var _marksman_timer: float = 0.0       # Run 130 — Marksman's Eye retarget tick
var _marksman_target: Node = null      # Run 130 — currently Marked enemy
# _ghost_stealthed moved to HeroBase (Batch 4)
var _golden_carrot_armed: bool = false # Run 131 — a dash arms the next combo finisher crit (Golden Carrot)
var _slapstick_bananas: Array = []     # Run 130 — live banana drops [{pos, until, node}]

# --- Dash charges (Extra Banana: hold 2 at once; Slapstick L2: hold 3) ---
# dash_charges moved to HeroBase (Batch 5).

# --- Tuber Burrow (Potato B — GDD §8.8) ---
# Tap B = normal dash. Hold B = after dash ends, if button still held → burrow.
# Underground: full invuln, free movement (65% speed), no attacks.
# Emerge: rise attack AoE (damage + cracked_soil + knockup + earth bonus).
# 2.5s cooldown on the burrow extension after rising.
const BURROW_MAX_DURATION:    float = 3.0    # max seconds underground
const BURROW_INTERNAL_CD:     float = 2.5    # CD after rising (standard dash still free)
const BURROW_MOVE_SPEED_MULT: float = 0.65   # underground move speed fraction
const BURROW_RISE_RADIUS:     float = 80.0   # rise-attack hit radius (px)
const BURROW_RISE_DAMAGE_MULT: float = 1.5   # rise-attack damage multiplier vs base
var burrow_timer: float     = 0.0
var burrow_cd_timer: float  = 0.0

# --- Run 150b — Vine Lash (Grape B): dash-then-attack window ---
var _vine_lash_window: float = 0.0
var _burrow_mound: Node2D   = null            # placeholder dirt-mound visual node

# --- Chi (GDD §8.3.2 — universal Chi, both characters share gain rules) ---
# MAX_CHI moved to HeroBase (Batch 5).
# current_chi moved to HeroBase (Batch 3).
const CHI_PER_DAMAGE_DEALT: float = 0.5    # per point of damage dealt
const CHI_PER_DAMAGE_TAKEN: float = 1.5    # per point of damage taken (higher to reward aggression)

# --- Combo Counter (GDD §8.3.1 — HUD bar counting consecutive hits) ---
# NOTE: `combo_count` is the HUD hit-streak counter.
#       `combo_step` (below) is the within-attack step (Jab=1, Cross=2, …).
#       These are separate concepts.
const COMBO_CAP: int = 30
const COMBO_RESET_GRACE: float = 5.0       # seconds of no hit → counter resets to 0
const COMBO_SOFT_DECAY_INTERVAL: float = 1.0  # Combo Master: 1pt lost per second post-grace
const BUNCH_BONUS_RADIUS: float = 192.0    # Grape Bunch Bonus: enemies within 3m (192px ≈ 3 tiles)
var combo_count: int = 0
var combo_grace_timer: float = 0.0
var combo_decay_timer: float = 0.0   # Combo Master only — counts off the next 1pt decrement

# --- Attack tuning (placeholder timings — playtest-tunable) ---
const Y_COMBO_HITS: int = 4
const X_COMBO_HITS: int = 3
const ATTACK_ANIM_DURATION: float = 0.20   # seconds per hit slice
const ATTACK_RECOVERY: float = 0.10        # delay at end of combo before idle
const HIT_PAUSE: float = 0.05             # normal freeze-frame duration on hit
const HIT_PAUSE_FINISHER: float = 0.12    # longer freeze on combo finishers (more satisfying crunch)
const ATTACK_MOVE_DAMPING: float = 0.4    # movement multiplier while attacking
const RANGED_PROJECTILE_SPEED: float = 780.0   # Run 48 — was 600; snappier pew-pew

# Run 48 / Run 105 — Ki Blast soft aim-assist: A-button (not stick) tap shots
# snap to the BEST enemy in a wide forward arc, scored by closeness + alignment
# so spam reliably finds the nearest threat you're roughly facing. Falls back to
# raw facing only when nothing is in the arc. Stick aim stays pure free-aim.
const KI_AIM_ASSIST_CONE_COS: float = 0.15     # cos(~81°) — was 0.82 (~35°), far too narrow
const KI_AIM_ASSIST_RANGE: float = 460.0
const KI_AIM_ASSIST_ALIGN_WEIGHT: float = 220.0  # px-equivalent pull toward better-aligned foes

# Run 60 — Twin-stick ranged. The right stick auto-fires the ranged attack in
# its aimed direction (free aim, NO assist). Shares a cadence gate with A so the
# two can't stack into a double fire rate; A keeps soft aim-assist + charge and
# can spam a touch faster via the combo buffer.
const AIM_STICK_DEADZONE: float = 0.5
const STICK_RANGED_INTERVAL: float = 0.22   # A-button shared gate (s)
# Run 106 — hold-to-aim auto-fire is throttled SLOWER than the A-button so manual
# tapping isn't strictly inferior to parking the right stick. Stick-only gate.
const STICK_AUTO_INTERVAL: float = 0.30     # right-stick steady-barrage cadence (s)
var _ranged_fire_cd: float = 0.0
# Run 60 — Melee aim snap: a swing orients to the best enemy in reach.
# Run 105 (Bruno) — auto-aim hardening. Picks the best target by BOTH closeness
# and how well it lines up with the player's intent (stick push, else facing),
# so a combo never finishes into empty space. Anything inside actual strike
# reach ALWAYS snaps — the opposite-push escape only applies to farther foes,
# so a deliberate backpedal-swing is still possible but in-reach hits connect.
const MELEE_SNAP_RANGE: float = 112.0          # was 84 — covers kick reach + foes drifting in
const MELEE_REACH: float = 80.0                # within this, snap unconditionally (kick far edge ~77)
const MELEE_SNAP_ALIGN_WEIGHT: float = 0.65    # how much front-alignment counts vs. closeness
const MELEE_SNAP_MIN_ALIGN: float = -0.30      # mid-range foes must be within ~107° of intent
const MELEE_SNAP_OPPOSITE_DOT: float = -0.5
const RANGED_PROJECTILE_DAMAGE: int = 8
const MELEE_Y_DAMAGE: int = 7             # Run 117 balance: was 5 — bump to align Y-combo DPS with Bea's fast katana
const MELEE_X_DAMAGE: int = 10
# Combo finisher bonus damage — adds on top of the base per-hit damage.
# Y4 (Spinning Uppercut): +11 on top of MELEE_Y_DAMAGE = 18 total before scaling.
# X3 (Side Kick): +18 on top of MELEE_X_DAMAGE = 28 total before scaling.
const Y_FINISHER_BONUS: int = 11           # Run 117 balance: was 12 — slight trim, total Y combo 39 (was 32)
const X_FINISHER_BONUS: int = 18

# --- Co-op swap flag (Phase 6) ---
# When false, Shino ignores input — Bea is under player control.
# Toggled by BeaAI._execute_swap() via set_player_controlled().
# player_controlled moved to HeroBase (Batch 4; base default true = Shino).

# --- Phase 7: Shino auto-defend AI (only used when player_controlled == false) ---
const SHINO_AI_SHOT_INTERVAL: float = 2.0
const SHINO_AI_SHOT_RANGE: float = 360.0
var _shino_ai_shot_timer: float = 1.2

# --- Run 38: Dojo mode (set by Dojo.gd on scene load) ---
# In the dojo the off-duty character does NOT auto-defend (he'd whack the
# training dummy forever). Instead he walks to dojo_wait_pos (middle of the
# room) and sits there until swapped to.
var dojo_mode: bool = false
var dojo_wait_pos: Vector2 = Vector2.ZERO

# --- Apple DD revive HoT state (Run 12 — Cider Mercy) ---
# Set by _try_consume_dd_charge when an Apple DD revive fires. Ticks each
# physics frame inside _tick_dd_hot and applies the regen up to max HP.
# _dd_hot_pct_per_sec, _dd_hot_remaining, _dd_hot_accum moved to HeroBase (Batch 4)

# Run 26d — Baked Apple finisher-only HoT. Set to BAKED_APPLE_HOT_DURATION
# on each Y4/X3 finisher; tick down in _physics_process. Refreshes (doesn't
# stack) — multiple finishers within the window just reset the timer.
var _baked_apple_hot_remaining: float = 0.0
var _baked_apple_hot_accum:     float = 0.0

# --- Post-dash temporary buffs ---
# Peel Out (Banana): on dash → +30% MS + AS for 5s (approximation: any dash counts).
# Hot-Footed (Pepper): on dash → +30% MS for 3s.
# Zip Dash (Banana B): +15% MS for 4s after dash (also extends dash distance 20%).
var _peel_out_timer: float = 0.0
var _hot_footed_timer: float = 0.0
# Run 59 — Pyromania (Pepper passive) consecutive-hit Burn streak.
var _pyromania_streak: int = 0
var _pyromania_last_hit: float = -10.0
# Run 27b — Ingrained (standing-still) system + on-absorb duo ICDs.
# _ingrained_time moved to HeroBase (Batch 3).
var _ingrained_last_pos: Vector2 = Vector2.ZERO
# Run 59 — Tremor Walk (Potato passive): Cracked Soil patches while moving / pulses while Ingrained.
var _tremor_walk_timer: float = 0.0
var _tremor_walk_last_pos: Vector2 = Vector2.ZERO
# Run 60 — Scorched Earth (Pepper+Potato duo): persistent lava patch follows
# the hero, dropping overlapping Burn + Cracked Soil zones on a 1.0s cadence.
# Radius scales up while Ingrained per the canonical spec.
var _scorched_earth_timer: float = 0.0
var _deep_roots_timer: float = 0.0
var _bunker_timer: float = 0.0
# _hot_shell_icd / _smokestack_icd moved to HeroBase (Batch 6).
# _peel_resto_icd, _candy_apple_bonus moved to HeroBase (Batch 3).
var _candy_apple_decay: float = 0.0  # decays 1/min while out of combat
var _static_charge_count: int = 0    # Run 27e — Static Charge every-3rd-ranged-hit
var _heirloom_timer: float = 0.0     # Run 27e — Heirloom follower regen (1 HP/2s)
# Run 27f — final-pass state.
var _no_attack_timer: float = 0.0       # Drawn Bow pause tracker
var _titans_roar_window: float = 0.0    # Titan's Roar +20% post-ult window
var _bullseye_finale_window: float = 0.0 # Bullseye Finale +25% crit window
var _corrupt_aura_accum: float = 0.0    # Thunderstruck / Fermented Wrath aura tick
var _zip_dash_ms_timer: float = 0.0

# --- Critical Mass (Carrot) — crit → +15% MS/AS per stack, max 3 stacks, 4s each ---
var _critical_mass_stacks: int = 0
var _critical_mass_timer: float = 0.0   # duration of current top stack

# --- Iron Will (Broccoli) — CC defy: immune to next CC every 10s ---
# _iron_will_ready, _iron_will_cd_timer moved to HeroBase (Batch 3).

# --- Battle Shell (Coconut) — 1 overshield on KO or X finisher ---
var _battle_shell_timer: float = 0.0   # 3s duration window
var _last_killed_enemy_pos: Vector2 = Vector2.ZERO
var _sweet_harvest_heal_icd: float = 0.0   # 8s ICD per spec
var _last_killed_enemy_was_poisoned: bool = false

# --- Run 19 — Aimed Guard duo (Carrot+Coconut): crit → overshield, 2s ICD ---
var _aimed_guard_icd: float = 0.0

# --- Run 19 — Cursed Heart Corrupt: passive HP regen accumulator ---

# --- Juicebox of Youth (Apple L2) — spawns a pickup every 10s ---
var _juicebox_spawn_timer: float = 10.0   # first box after 10s

# --- Layered Defense (Onion) — 3m passive poison aura ---
var _layered_defense_tick: float = 0.0
const LAYERED_DEFENSE_RADIUS: float = 192.0   # 3m ≈ 192px (3 tiles @ 64px)
const LAYERED_DEFENSE_INTERVAL: float = 1.0   # poison pulse every 1s

# --- Hydration (Watermelon) — Chi/sec in combat, ramps after 8s sustained ---
var _hydration_combat_timer: float = 0.0     # how long we've been in active combat
var _hydration_tick_accum: float = 0.0       # fractional Chi accumulator
const HYDRATION_BASE_RATE: float = 0.5       # Chi/sec baseline
const HYDRATION_RAMP_RATE: float = 1.5       # Chi/sec after 8s combat
const HYDRATION_RAMP_TIME: float = 8.0       # seconds to reach ramp rate

# --- Combat Fury (Broccoli) — per-player consecutive-hit tier tracker ---
# Tier increments on each hit, decays to 0 after COMBAT_FURY_DECAY_SEC of no hits.
var _combat_fury_tier: int = 0
var _combat_fury_decay_timer: float = 0.0

# --- Combo inter-step chain delay ---
# ATTACK_RECOVERY is defined but was unused. This timer applies it between
# consecutive combo steps so each hit lands distinctly before the next begins.
var _combo_chain_timer: float = 0.0
var _combo_chain_pending: bool = false   # queued next-step waiting on the timer

# Run 26d — Y4 (Spinning Uppercut) recovery lockout. Bruno's request: brief
# realistic pause between combos when Y is spammed, with the uppercut as the
# visible "landing" tell. Locks new Y combos for Y_COMBO_RECOVERY seconds
# after the Y4 finisher fires. Cross-button (X) is unaffected, so X cancel
# still works as canonical (per CANCEL SYSTEM doc above).
const Y_COMBO_RECOVERY: float = 0.30
var _y_combo_recovery_timer: float = 0.0
# Run 26e — X combo side-kick finisher recovery lockout (Bruno's spec:
# "defined pause between combos"). Same pattern as Y4 recovery.
const X_COMBO_RECOVERY: float = 0.30
var _x_combo_recovery_timer: float = 0.0

# Run 47 — Bruno's punch/kick feel split:
#   Punches (Y1-Y3) stop the target dead for PUNCH_HITSTOP (no shove).
#   Kicks (X1-X2)  trade the stop for a tiny pushback impulse.
#   Uppercut (Y4)  launches: UPPERCUT_AIR_TIME airborne (= stunned, via Bash)
#                  + UPPERCUT_LAND_STUN landing ministun on touchdown.
const PUNCH_HITSTOP: float = 0.10
const KICK_PUSHBACK: float = 130.0
const UPPERCUT_AIR_TIME: float = 0.50
const UPPERCUT_LAND_STUN: float = 0.10

# --- Facing direction ---
var facing: Vector2 = Vector2.DOWN

# --- State machine ---
# Run 13 — DOWNED and REVIVING added for the revive system rework.
#   DOWNED   = ninja knocked out, waiting for partner revive (or team-DD trigger).
#   REVIVING = standing ninja is channeling a fast revive (rooted, vulnerable).
enum State { IDLE, MOVING, ATTACKING, DASHING, HURT, CHARGING, CHARGED, FLURRYING, CRANE_KICKING, BEAMING, ULT_CASTING, DOWNED, REVIVING, BURROWING }
var state: State = State.IDLE

# --- Run 13 — Revive system constants + state moved to HeroBase (Batch 4) ---
# (REVIVE_* consts, rez_fill, _channeling_partner, _revive_circle_node,
#  _rez_bar_bg, _rez_bar_fill, _interact_prompt now live in HeroBase.)

# --- Attack tracking (within-attack combo step) ---
enum AttackType { NONE, Y, X, A }
var current_attack: int = AttackType.NONE
var combo_step: int = 0           # 1..N = current hit within the combo
var attack_timer: float = 0.0
var combo_window_timer: float = 0.0
# Run 105 — melee hitbox stays live until attack_timer drops below this cutoff.
# Set per-swing to ~45% of THIS swing's duration so the active window is always a
# fair fraction of the swing, regardless of attack-speed boons. (Previously a
# fixed ATTACK_ANIM_DURATION*0.4, which at high attack speed could shrink the
# window to nothing — jabs whiffed entirely.)
var _melee_active_cutoff: float = 0.0

# Run 29 — Buffered combo tap. If the player taps the same button while ATTACKING,
# queue the next step so it fires the instant the current animation ends, rather
# than requiring the button to still be held at animation end.
# The buffer expires after COMBO_CHAIN_BUFFER seconds so old presses don't ghost.
const COMBO_CHAIN_BUFFER: float = 0.60
var _y_chain_queued: bool = false
var _x_chain_queued: bool = false
var _y_chain_queue_timer: float = 0.0
var _x_chain_queue_timer: float = 0.0

# Run 30 — Rapid Ki Blast. Tapping A again while the A swing is still playing
# buffers the next shot (same pattern as Y/X). Chained shots fire ~45% faster
# and alternate left/right hand spawn points — left-right pew pew.
var _a_chain_queued: bool = false
var _a_chain_queue_timer: float = 0.0
var _ki_alt_hand: int = 0                # 0 = right hand, 1 = left hand
const KI_RAPID_DUR_MULT: float = 0.55    # chained A swings are this fraction of a fresh shot
const KI_HAND_OFFSET: float = 12.0       # perpendicular spawn offset per hand (px)

# Cross-cancel delay flag. When a cross-button cancel fires (Y→X, X→Y, any→A,
# etc.) we route it through _combo_chain_timer so the player is locked into
# the current strike's animation before the new attack begins — same feel as
# the intra-combo chain delay. When true, the timer fires _perform_attack_swing()
# directly (current_attack + combo_step are already set to the new attack).
var _combo_chain_is_cross_cancel: bool = false

# --- Universal Charge Attack Model (GDD §8.2.0) ---
# Run 112 — charge timing now lives in RunState (single source of truth shared
# with Bea). Hulk Smash still scales Shino's windup further at runtime.
var CHARGE_PHASE_DURATION: float = RunState.CHARGE_WINDUP   # base wind-up
var CHARGE_DETECT: float = RunState.CHARGE_DETECT           # button-hold threshold to commit to charge

var charge_attack_type: int = AttackType.NONE   # which attack is being charged
var charge_phase_timer: float = 0.0              # counts down during wind-up

# Pending-charge tracker (just_pressed → if still held at CHARGE_DETECT, enter CHARGING)
var pending_charge_type: int = AttackType.NONE
var pending_charge_timer: float = 0.0

# --- Punch Flurry execution (GDD §8.2.1) ---
# Run 49 — Y-charge rework (Bruno): free-aim vector charge. While holding Y,
# movement input aims a vector line in ANY direction; the line snaps to the
# nearest enemy (range doubled 210→420). On release Shino DASHES along the
# line; first enemy contact stops the dash and triggers the Pegasus-Meteor
# pummel (scatter punch comets). No contact = it's just a long dash.
const FLURRY_DURATION: float = 0.6              # total time spent flurrying (pummel phase)
const FLURRY_TRAVEL_DIST: float = 96.0          # pummel forward drift (~3 body lengths)
const FLURRY_LOCK_RANGE: float = 336.0          # Run 49b — -20% (was 420); kept equal to dash range so the arrow never promises a target the dash can't reach
const FLURRY_LOCK_CONE_COS: float = 0.42        # cos(65°) — ~130° total forward cone for lock-on
const FLURRY_HIT_INTERVAL: float = 0.10         # tick rate of damage during flurry
const FLURRY_HIT_DAMAGE: int = 4                # per non-final hit (placeholder)
const FLURRY_FINAL_DAMAGE: int = 14             # bigger payoff on the last hit (placeholder)
const FLURRY_FINAL_KNOCKBACK_MULT: float = 2.5  # bigger separating push on final hit
const Y_CHARGE_DASH_RANGE: float = 336.0        # Run 49b — -20% per Bruno (was 420); = snap range
const Y_CHARGE_DASH_SPEED: float = 1350.0       # Run 49 — px/s during the charge dash
const Y_CHARGE_AIM_SNAP_DEG: float = 20.0       # Run 49 — re-snap aim to enemy within this half-angle
const Y_CHARGE_CONTACT_RADIUS: float = 46.0     # Run 49 — dash stops when enemy within this of fist point
const METEOR_COMETS_PER_TICK: int = 2           # Run 49 — Pegasus Meteor scatter comets per pummel tick

var flurry_timer: float = 0.0
var flurry_next_hit_at: float = 0.0   # absolute "time-remaining" threshold for next hit
var flurry_hits_dealt: int = 0
var flurry_direction: Vector2 = Vector2.DOWN
# Run 49 — flurry phases: 0 = charge dash along aim line, 1 = meteor pummel.
var _flurry_phase: int = 0
var _flurry_dash_traveled: float = 0.0
# Run 49 — Y-charge aim state (aim indicator + soft target lock while holding).
# Run 49b — indicator is now a wide semi-transparent ARROW (Polygon2D), not a
# thin line; when locked it shortens to the enemy so the dash endpoint is clear.
var _y_charge_aim_line: Polygon2D = null
var _y_charge_target: Node2D = null

# --- Spinning Crane Kick (X-charge, §8.2.1) ---
# Self-contained scene with its own AoE + visual ring; Player just spawns it
# and stays locked for a brief tell window before returning to IDLE.
const CRANE_KICK_LOCKOUT: float = 0.45   # matches scene's `lifetime` (Run 48 — double-spin)
var crane_kick_timer: float = 0.0

# --- Kamehameha (A-charge, §8.2.1) ---
# Auto-aim picks the nearest enemy whose direction-from-Shino lies inside
# a forward cone of half-angle KAMEHAMEHA_CONE_HALF_DEG. Falls back to current
# facing if no enemy is in cone. Snaps facing to the chosen direction on fire.
const KAMEHAMEHA_LOCKOUT: float = 0.40            # matches beam scene `duration`
const KAMEHAMEHA_CONE_HALF_DEG: float = 60.0      # 120° total forward cone
const KAMEHAMEHA_MAX_RANGE: float = 1000.0        # Run 47 — beam now spans the arena; aim pick matches
var kamehameha_timer: float = 0.0

# --- Ult — Final Ki Blast (§8.2.3) ---
# Screen-wide AoE that damages every "enemy"-group member currently in the
# scene tree. Consumes full Chi. Player is locked through the cinematic +
# tiny "dizzy" tail (animation-only flavor per spec, no real debuff).
const ULT_CINEMATIC_DURATION: float = 1.50        # was 0.90s — bumped now that enemy freeze is wired; spec says 5s, 1.5s for prototype
const ULT_DIZZY_DURATION: float = 0.45            # post-cast wobble — bumped for dizzy animation room
const ULT_BASE_DAMAGE: int = 50                   # flat ult damage — proportionate to per-hit damage (user tuning)
const ULT_CHI_COST: int = 100

# ---- Bea Thousand Cut Dance (GDD §8.2.3) ----
# BEA_ULT_* consts removed (Batch 6): only the removed dead _run_bea_ult used them.

# ---- Shino Final Ki Blast (GDD §8.2.3) ----
const SHINO_ULT_WINDUP: float       = 0.50   # ki wind-up before beam extends
const SHINO_ULT_SPIN_DUR: float     = 3.00   # full 3-spin beam duration
const SHINO_ULT_NUM_SPINS: int      = 3      # CCW rotations
const SHINO_ULT_BEAM_LEN: float     = 650.0  # beam length (clears past screen edge)
const SHINO_ULT_BEAM_WIDTH: float   = 28.0   # visual beam width
var ult_timer: float = 0.0
var ult_in_dizzy: bool = false
var _ult_freeze_targets: Array = []   # enemies frozen during ult cinematic (phase 7 time-freeze)
var _was_ult_frozen: bool = false      # Run 151 — tracks partner ult freeze for post-freeze cleanup

# --- Node refs ---
@onready var melee_hitbox: Area2D = $MeleeHitbox
@onready var melee_hitbox_shape: CollisionShape2D = $MeleeHitbox/MeleeHitboxShape
@onready var charge_aura: ColorRect = get_node_or_null("ChargeAura")
# body_anim moved to HeroBase (Batch 4)
@onready var _sprite: AnimatedSprite2D = get_node_or_null("ShinoSprite")
@onready var name_label: Label = get_node_or_null("NameLabel")

# Run 102 — damage/status outlines. _hitfx moved to HeroBase (Batch 4).

# ── Frost (Popsicle Pelican) ────────────────────────────────────────────────
# Stacking movement slow. Each stack shaves FROST_SLOW_PER_STACK off move speed;
# stacks decay one at a time. Applied by the pelican's popsicle hit / icy patch.
# FROST_SLOW_PER_STACK moved to HeroBase (Batch 2).
# FROST_MAX_STACKS / FROST_STACK_DECAY / FROST_OUTLINE_HOLD / _frost_decay_t
# moved to HeroBase (Batch 5). frost_stacks moved to HeroBase (Batch 2).

# Last horizontal direction — persists on idle so sprite faces correctly while standing.
var _last_h_dir: int = 1   # +1 = right, -1 = left

# --- Run 52: hand-drawn combat-stance sprite state (Bruno's sheet) ---
# After any melee swing Shino holds his fight stance; each punch flashes the
# combo-step frame for a beat, then snaps back to stance ("punch and back").
const MELEE_STANCE_HOLD: float = 2.5    # s in fight stance after last melee swing
const PUNCH_FLASH_MAX: float   = 0.15   # snappy single-frame punch flash cap
const SHINO_SPRITE_SCALE: float = 48.0 / 135.0   # art ~135px tall in 96x140 cells → ~48px on screen
const WALK_ANIM_BASE_FPS: float = 6.0   # 2-frame step loop; speed_scale follows move speed
var _melee_stance_timer: float = 0.0
var _punch_flash_timer: float = 0.0
var _punch_flash_step: int = 0          # 1=Jab 2=Cross 3=Hook 4=Uppercut

# --- Status component (Bash, Vulnerable, etc. — Run 9) ---
# Created lazily at _ready so we don't depend on a scene-tree edit. Hosts on self.
# status moved to HeroBase (Batch 4)

# --- Coconut overshield (Run 15) ---
# Charges absorb the next incoming hit completely. Granted on dash by the
# Overshield boon; cap is RunState.overshield_max. When a charge breaks,
# Nutshell (if taken) fires a Bash AoE on nearby enemies.
# overshield_charges, _overshield_aura moved to HeroBase (Batch 3).
# Adamantium Husk (GDD v028): each charge blocks 2 hits. Tracks remaining
# hits the current top charge can absorb before breaking (reset on new grant).
var _adamantium_hits_on_current_charge: int = 2

# --- Scenes ---
var projectile_scene: PackedScene = null
var crane_kick_scene: PackedScene = null
var kamehameha_scene: PackedScene = null

# --- Signals (consumed by HUD.gd and future systems) ---
signal hp_changed(new_hp: int, max_hp: int)
signal chi_changed(new_chi: int, max_chi: int)
signal combo_count_changed(count: int)
signal attack_started(attack_type: int, combo_step: int)
signal dash_started()
signal charge_started(attack_type: int)        # CHARGING entered
signal charge_completed(attack_type: int)      # wind-up done, CHARGED
signal charge_canceled(attack_type: int)       # dash-cancel or button-release before wind-up
signal charge_released(attack_type: int)       # fired from CHARGED
signal ult_fired()                              # Final Ki Blast cinematic start


func _ready() -> void:
	hero_id = "shino"   # HeroBase identity — per-hero RunState gating key
	current_hp = max_hp
	state = State.IDLE
	add_to_group("player")   # HUD.gd finds player via this group
	# Status component — Bash, Vulnerable, etc. Mount as child node.
	status = StatusComponent.new()
	status.name = "StatusComponent"
	add_child(status)
	status.host = self
	if melee_hitbox:
		melee_hitbox.monitoring = false
		melee_hitbox.body_entered.connect(_on_melee_hitbox_body_entered)
	projectile_scene = load("res://scenes/KiBlast.tscn") if ResourceLoader.exists("res://scenes/KiBlast.tscn") else null
	crane_kick_scene = load("res://scenes/SpinningCraneKick.tscn") if ResourceLoader.exists("res://scenes/SpinningCraneKick.tscn") else null
	kamehameha_scene = load("res://scenes/KamehamehaBeam.tscn") if ResourceLoader.exists("res://scenes/KamehamehaBeam.tscn") else null
	if charge_aura:
		charge_aura.visible = false
	# Build Shino's SpriteFrames from the extracted strip PNGs.
	_setup_shino_sprite_frames()
	# Hide the legacy Run-9 stick-figure Body — ShinoSprite replaces it.
	if body_anim and body_anim is Node2D:
		body_anim.visible = false
	# Run 102 — damage/status outline FX (red hit, orange lava, purple poison).
	_hitfx = HeroHitFX.new()
	add_child(_hitfx)
	_hitfx.setup(self, _sprite)
	# Apply RunState modifiers BEFORE emitting initial signals so HUD shows
	# the boon-adjusted max HP / Chi caps from the moment the scene loads.
	apply_runstate_modifiers()
	_apply_carry_state()
	# Initialise dash charges after RunState boons are applied (Extra Banana may raise max).
	dash_charges = _get_max_dash_charges()
	# Emit initial values so HUD bars start at the correct fill on load
	emit_signal("hp_changed", current_hp, get_effective_max_hp())
	emit_signal("chi_changed", current_chi, get_effective_max_chi())
	emit_signal("combo_count_changed", combo_count)
	# Nameplate (Run 54) — live-toggle via Settings, refresh active-star state.
	var _settings := get_node_or_null("/root/Settings")
	if _settings and _settings.has_signal("nameplates_changed"):
		_settings.nameplates_changed.connect(_on_nameplates_changed)
	_refresh_name_label()


# Shino's blue nameplate. Shows "SHINO ✦" while player-controlled, "SHINO"
# while AI, and hides entirely when nameplates are disabled in Settings.
func _refresh_name_label() -> void:
	if name_label == null:
		return
	var show: bool = true
	var s := get_node_or_null("/root/Settings")
	if s and "nameplates_enabled" in s:
		show = s.nameplates_enabled
	name_label.visible = show
	if player_controlled:
		name_label.text = "SHINO ✦"
		name_label.modulate = Color(0.45, 0.70, 1.0, 1.0)
	else:
		name_label.text = "SHINO"
		name_label.modulate = Color(0.40, 0.55, 0.90, 0.75)


func _on_nameplates_changed(_enabled: bool) -> void:
	_refresh_name_label()


# --- Phase 6: called by BeaAI on hot-swap ---
func set_player_controlled(val: bool) -> void:
	player_controlled = val
	_refresh_name_label()
	if not player_controlled:
		# Cancel any pending charge so Shino doesn't fire when player returns
		if state == State.CHARGING or state == State.CHARGED:
			pending_charge_type = 0   # AttackType.NONE
			charge_attack_type  = 0
			state = State.IDLE
			_free_y_charge_aim_line()   # Run 49 — drop aim line on hot-swap
			if charge_aura:
				charge_aura.visible = false
			if _hitfx:
				_hitfx.set_charge(0)   # Run 112 — drop charge aura on hot-swap
	else:
		# Run 38 — stand up from the dojo "sitting" pose when control returns.
		if _sprite:
			_sprite.position.y = -9.0
	print("[Player] player_controlled = %s" % str(player_controlled))


# ============================================================
# Run 73 — per-device input routing (local 2-player).
# In 1P these defer to the global Input singleton, so single-player behavior
# is unchanged. In 2P they read ONLY Shino's assigned device via InputRouter.
# ============================================================
func _input_device() -> int:
	return RunState.shino_device

# _act_p/_act_jp/_act_jr/_move_axis/_aim_vec moved to HeroBase (Batch 2).


func _physics_process(delta: float) -> void:
	# Run 150 (Bruno fix 11) — GLOBAL ULT FREEZE: while the OTHER hero's
	# ultimate cinematic runs, this hero is fully frozen (no input, no AI, no
	# free-attacking the stunned boss). The ONLY input read is the ult button,
	# which queues the future double-ult (wiring per GDD notes — flag only).
	var _my_ult_id: String = "bea" if is_in_group("bea") else "shino"
	if RunState.ult_freeze_caster != "" and RunState.ult_freeze_caster != _my_ult_id \
	and state != State.DOWNED:
		velocity = Vector2.ZERO
		_was_ult_frozen = true
		if player_controlled and _act_jp("ult"):
			RunState.double_ult_queued = true
			FX.spawn_hit_particles(global_position, Color(1.0, 0.9, 0.3, 0.9), 6)
		return
	# Run 151 — Post-freeze cleanup: if this hero was frozen by the partner's
	# ult and is now unfrozen, cancel any charge whose button release was missed
	# during the freeze. Player.gd's _handle_input already uses `not _act_p()`
	# which self-corrects on the next frame, but pending_charge_type can also
	# get stuck (its timer was paused during the freeze).
	if _was_ult_frozen:
		_was_ult_frozen = false
		if (state == State.CHARGING or state == State.CHARGED):
			var _ac: String = _action_for(charge_attack_type)
			if _ac == "" or not _act_p(_ac):
				_cancel_charge()
		pending_charge_type = AttackType.NONE
		pending_charge_timer = 0.0
	_tick_timers(delta)
	# Run 13 — DOWNED takes priority over everything except the rez-bar tick.
	# The downed body doesn't move, doesn't take input, doesn't auto-defend.
	# (Visuals still tick the HoT once revived.)
	if state == State.DOWNED:
		velocity = Vector2.ZERO
		return
	# Run 117 — defensive revive-UI cleanup (mirrors BeaAI): catch any exit
	# from DOWNED that forgot _clear_revive_ui() so the circle never lingers.
	if _revive_circle_node and is_instance_valid(_revive_circle_node) and _revive_circle_node.visible:
		_clear_revive_ui()
		modulate = Color(1.0, 1.0, 1.0, 1.0)
	# REVIVING (this character is channel-rezzing partner) — rooted, vulnerable.
	if state == State.REVIVING:
		_tick_channel_revive(delta)
		return
	# Run 44 — hit-knockback impulse: applied as its own decaying move so the
	# state-machine velocity assignments below can't erase it next frame.
	if _hit_knockback_vel.length() > 1.0:
		var _pre_kb_vel: Vector2 = velocity
		velocity = _hit_knockback_vel
		move_and_slide()
		velocity = _pre_kb_vel
		_hit_knockback_vel = _hit_knockback_vel.lerp(Vector2.ZERO, delta * 9.0)
	else:
		_hit_knockback_vel = Vector2.ZERO
	# Phase 6: skip input processing when Bea has control (hot-swap)
	if player_controlled:
		_handle_input(delta)
		_tick_stick_fire(delta)   # Run 60 — twin-stick ranged
	else:
		# Stand still while Bea is controlled; don't interrupt in-flight attacks
		if state == State.IDLE or state == State.MOVING:
			velocity = Vector2.ZERO
	_handle_movement(delta)
	if state == State.FLURRYING:
		_tick_flurry(delta)
	_tick_charge_release_lockouts(delta)
	_tick_ult(delta)
	_tick_dd_hot(delta)
	_tick_baked_apple_hot(delta)   # Run 26d — Baked Apple HoT
	if _y_combo_recovery_timer > 0.0:
		_y_combo_recovery_timer = max(0.0, _y_combo_recovery_timer - delta)
	if _x_combo_recovery_timer > 0.0:
		_x_combo_recovery_timer = max(0.0, _x_combo_recovery_timer - delta)
	# Run 26e — Drive the CHARGED pulse every frame. Cheap: just sets color
	# + scale on a ColorRect. Only runs while state == CHARGED.
	if state == State.CHARGED:
		_update_charge_aura()
	# Run 13 — revive attempt tick (standing player checks for downed partners).
	# Runs in both player-controlled (interact press) and AI modes.
	_tick_revive_attempt(delta)
	# Onion Layered Defense — 3m passive poison aura, ticks every 1s.
	_tick_layered_defense(delta)
	# Watermelon Hydration — Chi/sec in combat, ramping after 8s sustained combat.
	_tick_hydration(delta)
	# Potato Tremor Walk — drop Cracked Soil patches while moving / Ingrained.
	_tick_tremor_walk(delta)
	# Scorched Earth duo (Pepper+Potato) — persistent lava patch follows hero.
	_tick_scorched_earth(delta)
	# Run 46 — Dragon Chi (Sensei Z): passive Chi regen, 1 Chi/5s per rank.
	_tick_sensei_chi_regen(delta)
	# Apple Juicebox of Youth — spawns a regen pickup every 10s + ticks regen.
	_tick_juicebox(delta)
	_tick_juicebox_regen(delta)
	# Phase 7 — Shino auto-defend stub when Bea has player control.
	# He stands still but turns to face the nearest enemy and fires a Ki Blast
	# on cooldown. Pure follower behavior (§8.5 Tier 1/2). Doesn't move, doesn't
	# combo, doesn't charge.
	if not player_controlled and (state == State.IDLE or state == State.MOVING):
		if dojo_mode:
			_tick_dojo_wait(delta)
		else:
			_tick_shino_auto_defend(delta)
	# Update Shino's animated sprite each frame.
	_update_sprite_animation()


# -------------------------------------------------------
# Sprite setup — build SpriteFrames at runtime from strip PNGs.
# Run 52: hand-drawn N/S art (Bruno's sheet), sliced into 96×140 cells,
# bottom-center anchored (feet planted). E/W still placeholder art upscaled
# onto the same cell grid so one node scale fits everything.
# -------------------------------------------------------
func _setup_shino_sprite_frames() -> void:
	if _sprite == null:
		return
	var frames := SpriteFrames.new()
	if frames.has_animation("default"):
		frames.remove_animation("default")

	var _add := func(anim: StringName, path: String, n: int,
					 fps: float, loop: bool) -> void:
		if not ResourceLoader.exists(path):
			push_warning("SpriteFrames: missing strip %s" % path)
			return
		var tex: Texture2D = load(path)
		frames.add_animation(anim)
		frames.set_animation_speed(anim, fps)
		frames.set_animation_loop(anim, loop)
		for i in range(n):
			var at := AtlasTexture.new()
			at.atlas = tex
			at.region = Rect2(i * 96, 0, 96, 140)
			frames.add_frame(anim, at)

	# Hand-drawn 2-frame step loops (left step / right step).
	# N/S rows serve ALL directions (Bruno's call) — no old placeholder art.
	_add.call(&"run_south", "res://Assets/Sprites/shino_walk_s.png", 2, WALK_ANIM_BASE_FPS, true)
	_add.call(&"run_north", "res://Assets/Sprites/shino_walk_n.png", 2, WALK_ANIM_BASE_FPS, true)
	# Punch rows — frame 0 = fight stance, 1=Jab 2=Cross 3=Hook 4=Uppercut.
	# Never play()ed; _update_sprite_animation sets frames directly.
	_add.call(&"punch_south", "res://Assets/Sprites/shino_punch_s.png", 5, 1.0, false)
	_add.call(&"punch_north", "res://Assets/Sprites/shino_punch_n.png", 5, 1.0, false)

	_sprite.sprite_frames = frames
	_sprite.scale = Vector2.ONE * SHINO_SPRITE_SCALE
	_sprite.play(&"run_south")
	_sprite.stop()


# -------------------------------------------------------
# Sprite update — pick animation from velocity + facing each frame.
# Priority: punch flash > fight stance (2.5s after last melee) > walk > idle.
# -------------------------------------------------------
func _update_sprite_animation() -> void:
	if _sprite == null or _sprite.sprite_frames == null:
		return
	# Y-sort depth: hero sprite sits at z=0 (same as interior prop wraps) so the
	# parent y_sort sorts heroes and obstacles by foot Y — south = in front,
	# north = behind.  A DASH lifts to HERO_DASH_Z so the ninja flies OVER props.
	_sprite.z_index = RunState.HERO_DASH_Z if state == State.DASHING else 0
	# Sprite is hidden while burrowing; skip animation updates.
	if state == State.BURROWING:
		return
	# Run 52 — combat stance / punch frames (hand-drawn N/S rows).
	# Punch flash shows the combo-step frame, then snaps back to stance.
	# Stance persists while shuffling around; expires MELEE_STANCE_HOLD after
	# the last swing. N/S only (no E/W rows yet) — dominant-north uses north
	# row, everything else reads fine with the south row.
	if _punch_flash_timer > 0.0 or _melee_stance_timer > 0.0:
		var p_anim: StringName = &"punch_south"
		if facing.y < 0.0 and absf(facing.y) >= absf(facing.x):
			p_anim = &"punch_north"
		if _sprite.animation != p_anim:
			_sprite.animation = p_anim
		if _sprite.is_playing():
			_sprite.stop()
		_sprite.frame = clampi(_punch_flash_step, 1, 4) if _punch_flash_timer > 0.0 else 0
		return
	var spd: float = velocity.length()
	if spd > 20.0:
		# N/S rows serve all directions: pick by vertical velocity sign; on
		# pure-horizontal movement keep whichever N/S walk is already playing.
		var anim: StringName
		if velocity.y < -1.0:
			anim = &"run_north"
		elif velocity.y > 1.0:
			anim = &"run_south"
		elif _sprite.animation == &"run_north" or _sprite.animation == &"run_south":
			anim = _sprite.animation
		else:
			anim = &"run_south"
		# Step cadence follows current move speed — speed boons make the steps
		# snappier, clamped so it never goes comical.
		_sprite.speed_scale = clampf(spd / move_speed, 0.75, 1.5)
		if _sprite.animation != anim or not _sprite.is_playing():
			_sprite.play(anim)
	else:
		# Freeze on the current frame — keeps facing direction when idle.
		if _sprite.is_playing():
			_sprite.stop()


# -------------------------------------------------------
# Timer management
# -------------------------------------------------------
func _tick_timers(delta: float) -> void:
	# Frost decay — melt one stack every FROST_STACK_DECAY seconds.
	if frost_stacks > 0:
		_frost_decay_t -= delta
		if _frost_decay_t <= 0.0:
			frost_stacks -= 1
			_frost_decay_t = FROST_STACK_DECAY
			if _hitfx and frost_stacks > 0:
				_hitfx.start_frost(FROST_OUTLINE_HOLD, float(frost_stacks) / float(FROST_MAX_STACKS))
	# Run 52 — combat-stance sprite timers.
	if _melee_stance_timer > 0.0:
		_melee_stance_timer = max(0.0, _melee_stance_timer - delta)
	if _punch_flash_timer > 0.0:
		_punch_flash_timer = max(0.0, _punch_flash_timer - delta)
	# Dash charge refill. Each charge refills after DASH_INTERNAL_CD.
	# With Extra Banana (max 2 charges), if both are spent the second refills
	# DASH_INTERNAL_CD after the first.
	if dash_cd_timer > 0.0:
		dash_cd_timer -= delta
		if dash_cd_timer <= 0.0:
			var max_ch: int = _get_max_dash_charges()
			if dash_charges < max_ch:
				dash_charges = min(max_ch, dash_charges + 1)
				# If still under max, restart timer to refill the next charge.
				if dash_charges < max_ch:
					dash_cd_timer = DASH_INTERNAL_CD

	# Tuber Burrow internal cooldown (gates the burrow extension; standard dash is unaffected).
	if burrow_cd_timer > 0.0:
		burrow_cd_timer = max(0.0, burrow_cd_timer - delta)

	# Run 150b — Vine Lash dash-then-attack window countdown.
	if _vine_lash_window > 0.0:
		_vine_lash_window = max(0.0, _vine_lash_window - delta)

	# Burrow tick — handle underground state here so timers always run.
	if state == State.BURROWING:
		_tick_burrow(delta)

	# Post-dash buff timers.
	if _peel_out_timer > 0.0:
		_peel_out_timer = max(0.0, _peel_out_timer - delta)
	if _hot_footed_timer > 0.0:
		_hot_footed_timer = max(0.0, _hot_footed_timer - delta)
	if _zip_dash_ms_timer > 0.0:
		_zip_dash_ms_timer = max(0.0, _zip_dash_ms_timer - delta)
	RunState.tick_cluster_cascade(delta)
	if _sweet_harvest_heal_icd > 0.0:
		_sweet_harvest_heal_icd -= delta
	# Run 131 — flanking_strike retired; its dash-window perma-crit is replaced by
	# Golden Carrot's dash-armed finisher crit (see _golden_carrot_armed).
	# Apple Evergreen Step CD.
	if _evergreen_step_cd_timer > 0.0:
		_evergreen_step_cd_timer = max(0.0, _evergreen_step_cd_timer - delta)

	# Run 27b — Ingrained (standing-still) tracking + Ingrained-gated duos.
	# Position-delta based so baked-in attack lunges/charge windups don't break
	# the state harder than actual movement does (per Combat_Boons §5.1 note).
	if global_position.distance_to(_ingrained_last_pos) < 1.5:
		_ingrained_time += delta
	else:
		_ingrained_time = 0.0
		_deep_roots_timer = 0.0
		_bunker_timer = 0.0
	_ingrained_last_pos = global_position
	RunState.shino_ingrained = _ingrained_time >= RunState.INGRAINED_THRESHOLD
	if _ingrained_time >= RunState.INGRAINED_THRESHOLD:
		# Deep Roots duo (Apple+Potato): regen 1 HP/sec while Ingrained, in combat.
		if RunState.is_duo_active("apple_potato") and _count_nearby_enemies(600.0) >= 1:
			_deep_roots_timer += delta
			if _deep_roots_timer >= 1.0:
				_deep_roots_timer -= 1.0
				heal_external(1)
		# Bunker duo (Coconut+Potato): 1 overshield per 4s while Ingrained
		# (max 1 stored from this source — only grants when none held).
		if RunState.is_duo_active("coconut_potato"):
			_bunker_timer += delta
			if _bunker_timer >= 4.0:
				_bunker_timer = 0.0
				if overshield_charges < 1:
					grant_overshield_external(1)
	# On-absorb duo ICD ticks.
	if _hot_shell_icd > 0.0:
		_hot_shell_icd -= delta
	if _smokestack_icd > 0.0:
		_smokestack_icd -= delta
	if _peel_resto_icd > 0.0:
		_peel_resto_icd -= delta
	# Run 27f — Drawn Bow pause tracker + post-ult windows + corrupt auras.
	_no_attack_timer += delta
	if _titans_roar_window > 0.0:
		_titans_roar_window -= delta
	if _bullseye_finale_window > 0.0:
		_bullseye_finale_window -= delta
	if _drupe_invuln_timer > 0.0:
		_drupe_invuln_timer -= delta   # Run 128 — Drupe Guard window
	# Run 130 — Marksman's Eye: every 5s Mark the highest-HP enemy on screen.
	if RunState.team_has("marksmans_eye"):
		_marksman_timer -= delta
		if _marksman_timer <= 0.0:
			_marksman_timer = 5.0
			_marksman_retarget()
	# Run 130 — Ghost Pepper: 1.5s without attacking → vanish (translucent;
	# direct enemy hits can't connect, ground hazards still do).
	if RunState.shino_has("ghost_pepper"):
		var _gp_want: bool = _no_attack_timer >= 1.5 and current_hp > 0 and state != State.DOWNED
		if _gp_want != _ghost_stealthed:
			_ghost_stealthed = _gp_want
			modulate.a = 0.45 if _ghost_stealthed else 1.0
	elif _ghost_stealthed:
		_ghost_stealthed = false
		modulate.a = 1.0
	# Run 130 — Slapstick banana drops: first enemy to touch one slips hard.
	if not _slapstick_bananas.is_empty():
		_tick_slapstick_bananas()
	# One Big Grape corrupt: combo counter locked at 15.
	if RunState.shino_has("corrupt_grape") and combo_count > 15:
		combo_count = 15
		RunState.set_combo("shino", combo_count)   # Run 60 — mirror
		emit_signal("combo_count_changed", combo_count)
	# Thunderstruck corrupt: shocking aura — zap enemies within 120px every 0.5s.
	# Fermented Wrath corrupt: walking miasma — 3 Poison/sec within 200px.
	if RunState.shino_has("corrupt_banana") or RunState.shino_has("corrupt_onion"):
		_corrupt_aura_accum += delta
		if _corrupt_aura_accum >= 0.5:
			_corrupt_aura_accum -= 0.5
			for e in get_tree().get_nodes_in_group("enemy"):
				if not is_instance_valid(e) or not (e is Node2D):
					continue
				if e.has_method("is_alive") and not e.is_alive():
					continue
				var d: float = e.global_position.distance_to(global_position)
				if RunState.shino_has("corrupt_banana") and d <= 120.0:
					if e.has_method("take_damage"):
						e.take_damage(max(1, int(round(3.0 * RunState.lightning_damage_mult))), Vector2.ZERO)
					if e.has_node("StatusComponent"):
						e.get_node("StatusComponent").apply("bash", 0.2, 1)
				if RunState.shino_has("corrupt_onion") and d <= 200.0:
					if e.has_node("StatusComponent"):
						# 3 stacks/sec = ~1.5 per half-second tick → alternate 1/2.
						e.get_node("StatusComponent").apply("poison", 4.0, 2)
	# Run 27e — Heirloom duo (Apple+Onion): regen follows the player — soft
	# orchard aura heals 1 HP per 2s while in combat (approximation of
	# "regen zones follow you" until a zone-ownership system exists).
	if RunState.is_duo_active("apple_onion") and _count_nearby_enemies(600.0) >= 1:
		_heirloom_timer += delta
		if _heirloom_timer >= 2.0:
			_heirloom_timer -= 2.0
			heal_external(1)
			FX.spawn_hit_particles(global_position, Color(0.45, 0.90, 0.45, 0.55), 3)
	else:
		_heirloom_timer = 0.0
	# Run 27d — Candy Apple temp max HP decay: 1 per minute out of combat.
	if _candy_apple_bonus > 0:
		if _count_nearby_enemies(600.0) == 0:
			_candy_apple_decay += delta
			if _candy_apple_decay >= 60.0:
				_candy_apple_decay = 0.0
				_candy_apple_bonus -= 1
				current_hp = min(current_hp, get_effective_max_hp())
				emit_signal("hp_changed", current_hp, get_effective_max_hp())
		else:
			_candy_apple_decay = 0.0

	# Critical Mass (Carrot) — each crit grants +15% MS/AS for 4s, max 3 stacks.
	# All stacks share one timer; landing a new crit refreshes to full duration.
	if RunState.shino_has("critical_mass") and _critical_mass_stacks > 0:
		_critical_mass_timer -= delta
		if _critical_mass_timer <= 0.0:
			_critical_mass_stacks = 0

	# Iron Will (Broccoli) — CC defy cooldown tick.
	if RunState.shino_has("iron_will") and not _iron_will_ready:
		_iron_will_cd_timer -= delta
		if _iron_will_cd_timer <= 0.0:
			_iron_will_ready = true

	# Battle Shell (Coconut) — duration of the temp overshield granted on KO/X-finisher.
	if _battle_shell_timer > 0.0:
		_battle_shell_timer -= delta

	# Run 19 — Aimed Guard duo ICD (Carrot+Coconut crit→overshield)
	if _aimed_guard_icd > 0.0:
		_aimed_guard_icd -= delta

	# Dash burst duration
	if dash_timer > 0.0:
		dash_timer -= delta
		if dash_timer <= 0.0:
			_set_barrier_phasing(false)   # restore collision with inner barriers
			# Tuber Burrow: if button still held at dash-end + boon active + no CD → burrow.
			var can_burrow: bool = (RunState.shino_has("tuber_burrow")
				and _act_p("dash")
				and burrow_cd_timer <= 0.0)
			if can_burrow:
				_enter_burrow()
			else:
				state = State.IDLE
				# Run 116 — on ice, carry a fraction of dash speed as momentum
				# so the dash overshoots in a fun slippery way without the old
				# 950 px/s catapult. Off-ice snaps to zero (handled by normal path).
				if get_meta("on_ice", false):
					velocity = dash_direction * DASH_SPEED * ICE.DASH_ICE_CARRY
			# Run 150b — Vine Lash (Grape B): arm the 0.5s dash-then-attack window.
			if RunState.shino_has("vine_lash"):
				_vine_lash_window = RunState.VINE_LASH_WINDOW
			# Dash-end slot boon effects always fire regardless of burrow entry.
			if RunState.shino_has("gas_bookends"):
				_spawn_gas_bookend(global_position)   # end-point cloud
			if RunState.shino_has("slick_trail"):
				_spawn_slick_trail_caltrops()         # Run 27e — end-point caltrops
			# Run 60 — Hot Step duo end-point burn patch.
			if RunState.is_duo_active("banana_pepper"):
				_spawn_status_zone(global_position, 36.0, 2.0, "burning", 1, Color(0.95, 0.45, 0.10, 0.75))
			if RunState.shino_has("hydro_slide"):
				_spawn_hydro_slide_puddle(global_position)
			# Run 130 — Slapstick: giant banana / lightning bolt at dash end.
			if RunState.shino_has("slapstick"):
				_spawn_slapstick_drop(global_position)
			if RunState.shino_has("bull_rush"):
				_apply_bull_rush_damage()
			# Slip Stream (Banana Legendary): dash through enemy leaves 3s grease field + 0.5s extra i-frames.
			if RunState.slip_stream_taken:
				_apply_slip_stream()

	# I-frame window (may outlast the burst).
	# BURROWING keeps invulnerability alive independently of iframe_timer.
	if state == State.BURROWING:
		is_invulnerable = true
	elif iframe_timer > 0.0:
		iframe_timer -= delta
		is_invulnerable = true
	else:
		is_invulnerable = false

	# Attack animation clock
	if attack_timer > 0.0:
		attack_timer -= delta
		# Auto-deactivate hitbox after the active frame window (Run 105: proportional
		# to this swing's duration via _melee_active_cutoff, set in _activate_melee_hitbox).
		if melee_hitbox.monitoring and attack_timer < _melee_active_cutoff:
			melee_hitbox.monitoring = false
		if attack_timer <= 0.0:
			_on_attack_animation_finished()

	if combo_window_timer > 0.0:
		combo_window_timer -= delta
		if combo_window_timer <= 0.0:
			combo_step = 0
			current_attack = AttackType.NONE

	# Run 29 — Expire buffered combo taps after COMBO_CHAIN_BUFFER seconds.
	if _y_chain_queue_timer > 0.0:
		_y_chain_queue_timer -= delta
		if _y_chain_queue_timer <= 0.0:
			_y_chain_queued = false
	if _x_chain_queue_timer > 0.0:
		_x_chain_queue_timer -= delta
		if _x_chain_queue_timer <= 0.0:
			_x_chain_queued = false
	if _a_chain_queue_timer > 0.0:
		_a_chain_queue_timer -= delta
		if _a_chain_queue_timer <= 0.0:
			_a_chain_queued = false

	# HUD combo counter grace timer
	if combo_grace_timer > 0.0:
		combo_grace_timer -= delta
		if combo_grace_timer <= 0.0:
			# Grape "Combo Master" softens the reset into a 1pt/sec decay
			# (Combat_Boons.md §Grape — Combo Master). Without it, hard-reset.
			# Run 128 — Vineyard Reserve also grants the gradual-decay arm.
			if (RunState.shino_has("combo_master") or RunState.shino_has("vineyard_reserve")) and combo_count > 0:
				combo_decay_timer = COMBO_SOFT_DECAY_INTERVAL
			else:
				_reset_combo_counter()
	elif combo_decay_timer > 0.0 and combo_count > 0:
		# Soft-decay mode (Combo Master only). Drop 1pt every second until 0
		# or until a new hit refills the grace and exits decay.
		combo_decay_timer -= delta
		if combo_decay_timer <= 0.0:
			combo_count = max(0, combo_count - 1)
			RunState.set_combo("shino", combo_count)   # Run 60 — mirror soft-decay
			emit_signal("combo_count_changed", combo_count)
			if combo_count > 0:
				combo_decay_timer = COMBO_SOFT_DECAY_INTERVAL
			else:
				combo_decay_timer = 0.0

	# Combat Fury (Broccoli) — decay tier toward 0 after 3s of no hits.
	if RunState.shino_has("combat_fury") and _combat_fury_decay_timer > 0.0:
		_combat_fury_decay_timer -= delta
		if _combat_fury_decay_timer <= 0.0:
			_combat_fury_tier = 0

	# Combo chain delay — brief pause between combo steps (ATTACK_RECOVERY).
	# Also used for cross-cancel delays (see _combo_chain_is_cross_cancel).
	if _combo_chain_pending and _combo_chain_timer > 0.0:
		_combo_chain_timer -= delta
		if _combo_chain_timer <= 0.0:
			_combo_chain_pending = false
			if _combo_chain_is_cross_cancel:
				# Cross-cancel: current_attack + combo_step already set to the
				# new attack. Just fire the swing directly without incrementing.
				_combo_chain_is_cross_cancel = false
				_perform_attack_swing()
			else:
				combo_step += 1
				_perform_attack_swing()

	# Pending-charge hold detection (§8.2.0 — tap-vs-charge gate)
	if pending_charge_type != AttackType.NONE:
		pending_charge_timer -= delta
		var action_name: String = _action_for(pending_charge_type)
		if action_name != "" and not _act_p(action_name):
			# Released before threshold → confirmed tap, clear pending
			pending_charge_type = AttackType.NONE
			pending_charge_timer = 0.0
		elif pending_charge_timer <= 0.0:
			# Still held → commit to charge (cancels in-flight tap if any)
			var atk: int = pending_charge_type
			pending_charge_type = AttackType.NONE
			pending_charge_timer = 0.0
			_start_charging(atk)

	# Charge wind-up timer (CHARGING → CHARGED at 0.0)
	if state == State.CHARGING and charge_phase_timer > 0.0:
		charge_phase_timer -= delta
		if charge_phase_timer <= 0.0:
			state = State.CHARGED
			_update_charge_aura()
			emit_signal("charge_completed", charge_attack_type)


# -------------------------------------------------------
# Input
# -------------------------------------------------------
func _handle_input(_delta: float) -> void:
	if state == State.HURT:
		return

	# UNIVERSAL RULE (Run 17 — Status Taxonomy): dash always works.
	# Check the dash input BEFORE the action_lock early-return so Bash,
	# Frozen, Stagger and any future action-locking status cannot remove
	# the player's escape option. Per Combat_Boons §8 status taxonomy.
	if _act_jp("dash") and state != State.DASHING and state != State.BURROWING and dash_charges > 0:
		# Run 112 — Shino-unique: dashing while his X is FULLY charged unleashes
		# the X spinning-crane AoE as a travelling whirlwind along the dash path,
		# hitting everything he passes (instead of wasting the charge). Other
		# charges (Y/A) still simply cancel on dash.
		var x_dash_strike: bool = (state == State.CHARGED and charge_attack_type == AttackType.X)
		if state == State.CHARGING or state == State.CHARGED:
			_cancel_charge()
		_start_dash()
		if x_dash_strike:
			_spawn_x_dash_strike()
		return

	# Bash / Frozen / Stagger / any action_lock — ignore non-dash inputs.
	if status and status.is_action_locked():
		return

	# Ult — usable from IDLE / MOVING / ATTACKING only. Costs full Chi.
	# Cancels in-flight tap swing on fire (charge / dash / flurry states must
	# resolve first — no overriding a committed charge or active beam/crane).
	if _act_jp("ult") and _can_fire_ult():
		_start_ult()
		return

	# Charge-release lockouts are non-interruptible (like flurry)
	if state == State.CRANE_KICKING or state == State.BEAMING or state == State.ULT_CASTING:
		return

	if state == State.DASHING:
		return

	# Burrowing: only allow releasing the button to emerge early (handled in _tick_burrow).
	if state == State.BURROWING:
		return

	# Flurry is non-interruptible (lockout) — ignore inputs while flurrying
	if state == State.FLURRYING:
		return

	# Charge-state handling: steer facing + watch for button release
	if state == State.CHARGING or state == State.CHARGED:
		_handle_charge_steering()
		# Release detection: if the corresponding button is no longer held
		var action_name: String = _action_for(charge_attack_type)
		if action_name == "" or not _act_p(action_name):
			if state == State.CHARGED:
				_release_charge()
			else:
				# Released mid-wind-up → cancel, no fire
				_cancel_charge()
		return

	# Attack inputs (taps + start pending-charge tracker)
	if _act_jp("attack_y"):
		_try_start_attack(AttackType.Y)
		_arm_pending_charge(AttackType.Y)
	elif _act_jp("attack_x"):
		_try_start_attack(AttackType.X)
		_arm_pending_charge(AttackType.X)
	elif _act_jp("attack_a"):
		_try_start_attack(AttackType.A)
		_arm_pending_charge(AttackType.A)


func _arm_pending_charge(attack_type: int) -> void:
	pending_charge_type = attack_type
	pending_charge_timer = CHARGE_DETECT


func _action_for(attack_type: int) -> String:
	match attack_type:
		AttackType.Y: return "attack_y"
		AttackType.X: return "attack_x"
		AttackType.A: return "attack_a"
		_: return ""


func _handle_charge_steering() -> void:
	# Facing can be steered during charge (per §8.2.0 — even during wind-up).
	# Character is locked in place (no velocity); only the facing vector follows input.
	var input_vec: Vector2 = Vector2(
		_move_axis().x,
		_move_axis().y
	)
	# Run 49 — Y-charge free-aim: input aims the vector; the line soft-snaps to
	# the nearest enemy within Y_CHARGE_AIM_SNAP_DEG of the aim. With no input,
	# a locked target keeps being tracked (line follows a moving enemy).
	if charge_attack_type == AttackType.Y:
		if input_vec.length() > 0.1:
			facing = input_vec.normalized()
			_y_charge_target = _pick_y_aim_target(facing)
			if _y_charge_target != null:
				facing = (_y_charge_target.global_position - global_position).normalized()
		elif _is_y_target_valid():
			facing = (_y_charge_target.global_position - global_position).normalized()
		_update_y_charge_aim_line()
		return
	if input_vec.length() > 0.1:
		facing = input_vec.normalized()


# Run 49 — Y-charge aim helpers --------------------------------------------
func _is_y_target_valid() -> bool:
	if _y_charge_target == null or not is_instance_valid(_y_charge_target):
		return false
	if _y_charge_target.has_method("is_alive") and not _y_charge_target.is_alive():
		return false
	return global_position.distance_to(_y_charge_target.global_position) <= FLURRY_LOCK_RANGE


# Nearest living enemy within FLURRY_LOCK_RANGE and within Y_CHARGE_AIM_SNAP_DEG
# of `aim`. Returns null if the cone is empty.
func _pick_y_aim_target(aim: Vector2) -> Node2D:
	var best: Node2D = null
	var best_d: float = FLURRY_LOCK_RANGE
	var cone_cos: float = cos(deg_to_rad(Y_CHARGE_AIM_SNAP_DEG))
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or not (e is Node2D) or not e.has_method("take_damage"):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		var to_e: Vector2 = e.global_position - global_position
		var d: float = to_e.length()
		if d < 4.0 or d > best_d:
			continue
		if (to_e / d).dot(aim) < cone_cos:
			continue
		best = e
		best_d = d
	return best


# Nearest living enemy in ANY direction within range (initial snap on charge start).
func _pick_nearest_enemy_any_dir(max_range: float) -> Node2D:
	var best: Node2D = null
	var best_d: float = max_range
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or not (e is Node2D) or not e.has_method("take_damage"):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		var d: float = global_position.distance_to(e.global_position)
		if d < 4.0 or d > best_d:
			continue
		best = e
		best_d = d
	return best


func _update_y_charge_aim_line() -> void:
	# Run 49b — wide semi-transparent arrow (was a thin Line2D). When the arrow
	# touches a locked enemy the tip shortens to where the dash actually STOPS,
	# so the landing point reads clearly before release.
	if _y_charge_aim_line == null:
		_y_charge_aim_line = Polygon2D.new()
		_y_charge_aim_line.z_index = 4
		add_child(_y_charge_aim_line)
	var locked: bool = _is_y_target_valid()
	var aim: Vector2 = facing
	var length: float = Y_CHARGE_DASH_RANGE
	if locked:
		var to_t: Vector2 = _y_charge_target.global_position - global_position
		var d: float = to_t.length()
		if d > 4.0:
			aim = to_t / d
		# Dash stops at contact — show the tip where Shino's body ends up.
		length = clampf(d - Y_CHARGE_CONTACT_RADIUS * 0.6, 24.0, Y_CHARGE_DASH_RANGE)
	# Arrow built along +X, node rotated to the aim direction.
	var shaft_hw: float = 7.0      # shaft half-width
	var head_hw: float = 18.0      # arrowhead half-width
	var head_len: float = minf(30.0, length * 0.45)
	var shaft_len: float = length - head_len
	_y_charge_aim_line.polygon = PackedVector2Array([
		Vector2(10.0, -shaft_hw),
		Vector2(shaft_len, -shaft_hw),
		Vector2(shaft_len, -head_hw),
		Vector2(length, 0.0),
		Vector2(shaft_len, head_hw),
		Vector2(shaft_len, shaft_hw),
		Vector2(10.0, shaft_hw),
	])
	_y_charge_aim_line.rotation = aim.angle()
	# Warm gold + brighter when locked; cool cyan when free-aiming. Semi-transparent.
	_y_charge_aim_line.color = Color(1.0, 0.80, 0.25, 0.40) if locked \
		else Color(0.45, 0.85, 1.0, 0.28)


func _free_y_charge_aim_line() -> void:
	if _y_charge_aim_line != null and is_instance_valid(_y_charge_aim_line):
		_y_charge_aim_line.queue_free()
	_y_charge_aim_line = null
	_y_charge_target = null


# -------------------------------------------------------
# Dash
# -------------------------------------------------------
func _start_dash() -> void:
	# Prefer current movement input direction; fall back to facing
	var input_vec: Vector2 = Vector2(
		_move_axis().x,
		_move_axis().y
	)
	dash_direction = input_vec.normalized() if input_vec.length() > 0.1 else facing
	facing = dash_direction   # snap facing to dash direction

	state = State.DASHING
	_set_barrier_phasing(true)   # Hades-style: dash phases through inner barriers
	# Zip Dash (Banana B): +20% dash distance by extending the burst timer.
	dash_timer = DASH_DURATION * (1.20 if RunState.shino_has("zip_dash") else 1.0)
	# Run 131 — Burnout corrupt (Broccoli): dash distance halved (Combat_Boons §6.3).
	if RunState.shino_has("corrupt_broccoli"):
		dash_timer *= 0.5
	# Consume a charge and start the refill CD.
	dash_charges = max(0, dash_charges - 1)
	if dash_cd_timer <= 0.0:
		dash_cd_timer = DASH_INTERNAL_CD   # start refill countdown for this charge
	iframe_timer = DASH_IFRAME_DURATION

	# Cancel any in-progress attack + clear any pending-charge intent
	_reset_attack_combo()
	pending_charge_type = AttackType.NONE
	pending_charge_timer = 0.0
	# Coconut Overshield (Run 15) — dash grants N charges (rarity-scaled).
	_grant_overshield_on_dash()
	# Banana Peel Out: +30% MS + AS for 5s after any dash.
	if RunState.shino_has("peel_out"):
		_peel_out_timer = 5.0
	# Banana Zip Dash: +15% MS for 4s after any dash.
	if RunState.shino_has("zip_dash"):
		_zip_dash_ms_timer = 4.0
		FX.spawn_hit_particles(global_position, Color(0.95, 0.88, 0.20, 0.80), 5)
	# Pepper Hot-Footed: +30% MS for 3s after any dash.
	if RunState.shino_has("hot_footed"):
		_hot_footed_timer = RunState.HOT_FOOTED_DURATION
	# Apple Evergreen Step: next hit heals 1% max HP (6s CD).
	if RunState.shino_has("evergreen_step") and _evergreen_step_cd_timer <= 0.0:
		_evergreen_step_active = true
		_evergreen_step_cd_timer = 6.0
	# Run 131 — Golden Carrot: a dash arms the NEXT combo finisher as a guaranteed
	# crit (one finisher per dash; dashing again just re-arms, no stacking).
	if RunState.shino_has("golden_carrot"):
		_golden_carrot_armed = true
	# Pepper Fire Trail: spawn flame line along dash path.
	if RunState.shino_has("fire_trail"):
		_spawn_fire_trail()
	# Banana Slick Trail: caltrops at start + end. (Run 27e — boon is now in
	# the pool; the old `"slick_trail_taken" in RunState` guard was dead code.)
	if RunState.shino_has("slick_trail"):
		_spawn_slick_trail_caltrops()
	# Run 60 — Hot Step (Banana+Pepper duo): dashes leave a burning trail.
	# Start-point burst; end-point will fire from the same dash-end block below.
	if RunState.is_duo_active("banana_pepper"):
		_spawn_status_zone(global_position, 36.0, 2.0, "burning", 1, Color(0.95, 0.45, 0.10, 0.75))
		FX.spawn_hit_particles(global_position, Color(1.00, 0.50, 0.15, 0.85), 4)
	# Onion Gas Bookends: stink clouds at start + end.
	if RunState.shino_has("gas_bookends"):
		_spawn_gas_bookend(global_position)   # start point; end spawned in _tick_dash
	# Bull Rush: check for enemies hit during dash (handled in _tick_dash).
	# Afterimage ghost trail — first ghost at start position.
	_dash_ghost_cd = 0.0
	FX.spawn_dash_afterimage(_sprite, global_position,
		Color(0.25, 0.50, 0.95, 0.50))
	emit_signal("dash_started")


# Toggle collision exceptions with every inner-barrier body (group set by
# DreamRoom). ON during a dash → the ninja slips through rocks/walls; OFF
# otherwise. Outer walls + gates are separate bodies (not in the group), so
# the hero can never dash out of the arena bounds.
func _set_barrier_phasing(on: bool) -> void:
	for b in get_tree().get_nodes_in_group("dashable_barrier"):
		if b is PhysicsBody2D:
			if on:
				add_collision_exception_with(b)
			else:
				remove_collision_exception_with(b)


func _get_max_dash_charges() -> int:
	var max_ch: int = 1
	if RunState.shino_has("extra_banana"):
		max_ch += 1   # GDD: Extra Banana = hold 2 dashes at once
	max_ch += RunState.sensei_extra_dash   # Sensei Z: Shadow Dash upgrade
	if RunState.shino_has("corrupt_potato"):
		max_ch += 2   # Uprooted corrupt: +2 dash charges (Combat_Boons §6.3)
	# Run 130 — Slapstick (Banana Legendary): +1 dash charge (cap 3 w/ Extra Banana).
	if RunState.shino_has("slapstick"):
		max_ch += 1
	return max_ch


# Run 15 — Coconut Hard Landing: stun-immune while charging.
# Iron Will (Broccoli): defy the next CC every 10s.
# StatusComponent calls this before applying any new status.
# can_receive_status moved to HeroBase (Batch 3). Per-hero hooks it calls:
func _hero_has(id: String) -> bool:
	return RunState.shino_has(id)

func _emit_hp_signal() -> void:
	emit_signal("hp_changed", current_hp, get_effective_max_hp())

func _emit_chi_signal() -> void:
	emit_signal("chi_changed", current_chi, get_effective_max_chi())

func _in_charge_or_release_state() -> bool:
	return state in [State.CHARGING, State.CHARGED, State.FLURRYING, State.CRANE_KICKING, State.BEAMING]

func _is_charging_state() -> bool:
	return state == State.CHARGING or state == State.CHARGED

# --- Batch 4 child overrides (state predicates/setters + kit hooks) ---
# (Shino has no DEAD state → base _is_state_dead()==false is correct; no override.)
func _is_state_downed() -> bool:
	return state == State.DOWNED

func _set_state_downed() -> void:
	state = State.DOWNED

func _set_state_reviving() -> void:
	state = State.REVIVING

func _set_state_neutral() -> void:
	state = State.IDLE

func _revive_attempt_locked() -> bool:
	if state == State.DOWNED or state == State.DASHING or state == State.REVIVING or state == State.BURROWING:
		return true
	if state == State.FLURRYING or state == State.BEAMING or state == State.CRANE_KICKING or state == State.ULT_CASTING:
		return true
	return false

# Run 27f — Rampart: Shino raises the rock wall directly (he hosts the spawner).
func _spawn_rampart_wall_routed() -> void:
	_spawn_rampart_wall(global_position + facing.rotated(PI * 0.5) * 36.0)

# Chi gained from taking damage — Shino's inline Cold-Waters / Poison-Apple path.
func _gain_chi_from_damage_taken(adjusted: int) -> void:
	var chi_cap: int = get_effective_max_chi()
	var _cw_mult: float = 0.5 if RunState.shino_has("corrupt_watermelon") else 1.0
	_cw_mult *= (1.0 + RunState.get_poison_apple_conversion_pct("shino"))   # Run 139
	current_chi = min(chi_cap, current_chi + int(CHI_PER_DAMAGE_TAKEN * adjusted * _cw_mult))
	emit_signal("chi_changed", current_chi, chi_cap)

# Combat teardown when Shino is downed (drops fist combo + charge aim-line).
func _cleanup_combat_on_downed() -> void:
	_reset_attack_combo()
	if charge_aura:
		charge_aura.visible = false
	charge_attack_type = AttackType.NONE
	charge_phase_timer = 0.0
	pending_charge_type = AttackType.NONE
	pending_charge_timer = 0.0
	_free_y_charge_aim_line()   # Run 49 — drop aim line if downed mid-charge

# Combat teardown when Shino starts channel-reviving a partner.
func _cleanup_combat_on_channel_start() -> void:
	_reset_attack_combo()
	pending_charge_type = AttackType.NONE
	pending_charge_timer = 0.0
	if charge_aura:
		charge_aura.visible = false


# -------------------------------------------------------
# Coconut Overshield helpers (Run 15)
# -------------------------------------------------------
func _grant_overshield_on_dash() -> void:
	# Run 150b (Bruno ruling) — holder-only: Shino's dash grants read HIS config.
	if RunState.get_overshield_grant_on_dash("shino") <= 0:
		return
	var cap: int = max(1, RunState.get_overshield_max("shino"))
	var new_total: int = min(cap, overshield_charges + RunState.get_overshield_grant_on_dash("shino"))
	if new_total > overshield_charges:
		overshield_charges = new_total
		# Adamantium Husk: new charge always starts fresh with 2-hit capacity.
		if RunState.adamantium_active():
			_adamantium_hits_on_current_charge = 2
		_refresh_overshield_aura()
		FX.play_sound("overshield_gain", 0.85)
		# Run 19 — Shell Cluster duo (Coconut + Grape): mirror-share to Bea.
		_shell_cluster_mirror_share()


# _shell_cluster_mirror_share, heal_external, grant_overshield_external moved to
# HeroBase (Batch 3). Mirror-share is now hero_id-parameterized (Shino → "bea"
# group; Bea → "player" group). Shino's dash grant still calls the inherited
# _shell_cluster_mirror_share().


# Run 19 — Aimed Guard duo (Carrot + Coconut): crits grant 1 overshield with a 2s ICD.
func _try_aimed_guard_grant() -> void:
	if not RunState.aimed_guard_active():
		return
	if _aimed_guard_icd > 0.0:
		return
	_aimed_guard_icd = 2.0
	grant_overshield_external(1)
	FX.spawn_hit_particles(global_position, Color(0.85, 0.65, 0.30, 0.90), 6)


func _consume_overshield() -> bool:
	# Returns true if a charge absorbed the hit (caller should skip damage).
	if overshield_charges <= 0:
		return false
	# Run 27b — on-absorb duo procs (Hot Shell / Smokestack), fire on ANY
	# absorbed hit (including Adamantium first-hits).
	_overshield_absorb_duo_procs()

	# Adamantium Husk (Coconut Legendary — GDD v028): each overshield charge
	# absorbs 2 hits instead of 1 before breaking. Track hits-remaining per
	# charge via _adamantium_hits_on_current_charge. On the first hit, reduce
	# to 1. On the second hit (or without Adamantium), the charge breaks.
	if RunState.adamantium_active():
		if _adamantium_hits_on_current_charge > 1:
			# First hit on this charge — absorb it, reduce counter, no break.
			_adamantium_hits_on_current_charge -= 1
			FX.play_sound("overshield_break", 0.6)   # softer "hit absorbed" cue
			FX.spawn_hit_particles(global_position, Color(0.95, 0.85, 0.55, 0.9), 8)
			_refresh_overshield_aura()
			return true
		else:
			# Second hit — charge breaks normally.
			_adamantium_hits_on_current_charge = 2   # reset for next charge
	overshield_charges -= 1
	_refresh_overshield_aura()
	# Reset adamantium counter for whatever charge is now on top.
	if RunState.adamantium_active():
		_adamantium_hits_on_current_charge = 2
	FX.play_sound("overshield_break", 1.0)
	# Visual: small white burst at player + medium shake
	FX.spawn_burst_particles(global_position, Color(1.0, 1.0, 1.0, 0.95), 14)
	FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_SHORT)
	# Nutshell — on break, briefly Bash all nearby enemies (Coconut CC identity).
	# Run 27 — Slip 'n Shell duo (Banana+Coconut) reuses the Nutshell
	# knockdown shockwave on overshield break.
	if RunState.shino_has("nutshell") or RunState.is_duo_active("banana_coconut"):
		_fire_nutshell_shockwave()
	return true


# Run 27f — Rampart (Potato passive): raise a temporary rock wall segment —
# real terrain (StaticBody2D) that blocks movement + projectiles for ~4s.
func _spawn_rampart_wall(pos: Vector2) -> void:
	var parent: Node = get_parent()
	if parent == null:
		return
	var wall := StaticBody2D.new()
	wall.global_position = pos
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(18.0, 56.0)
	shape.shape = rect
	wall.add_child(shape)
	var vis := ColorRect.new()
	vis.size = Vector2(18.0, 56.0)
	vis.position = Vector2(-9.0, -28.0)
	vis.color = Color(0.55, 0.42, 0.28, 0.95)
	wall.add_child(vis)
	parent.add_child(wall)
	FX.spawn_burst_particles(pos, Color(0.6, 0.45, 0.3, 0.9), 8)
	get_tree().create_timer(4.0).timeout.connect(func():
		if is_instance_valid(wall):
			wall.queue_free()
	)


# gain_chi_external, peel_restoration_slip_credit moved to HeroBase (Batch 3).


# Run 27b — Hot Shell (Coconut+Pepper) + Smokestack (Coconut+Onion) duo procs
# when an overshield absorbs a hit.
# _overshield_absorb_duo_procs moved to HeroBase (Batch 6). Shino owns the real
# `_spawn_status_zone`, so his routing hook calls it directly.
func _spawn_status_zone_routed(pos: Vector2, radius: float, duration: float, status_id: String, stacks: int, col: Color) -> void:
	_spawn_status_zone(pos, radius, duration, status_id, stacks, col)


# Run 19/20 — Hulk Smash Legendary: combo finishers emit a shockwave.
# Radius and damage scale with the live HUD combo counter.
func _try_hulk_smash(origin: Vector2) -> void:
	if not RunState.shino_has("hulk_smash"):
		return
	var radius: float = RunState.get_hulk_smash_radius(combo_count)
	var dmg: int = RunState.get_hulk_smash_damage(combo_count)
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		if origin.distance_to(e.global_position) > radius:
			continue
		if e.has_method("take_damage"):
			e.take_damage(dmg, (e.global_position - origin).normalized())
	FX.spawn_burst_particles(origin, Color(0.35, 0.90, 0.35, 1.0), 18)
	FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_SHORT)
	FX.play_sound("hulk_smash", 1.0)


# _fire_nutshell_shockwave, _refresh_overshield_aura moved to HeroBase (Batch 3).


# -------------------------------------------------------
# Charge (universal §8.2.0)
# -------------------------------------------------------
func _start_charging(attack_type: int) -> void:
	# Cancel any in-flight tap swing before locking into wind-up
	_reset_attack_combo()
	state = State.CHARGING
	charge_attack_type = attack_type
	# Hulk Smash: 50% faster windup on top of base 0.47s.
	charge_phase_timer = CHARGE_PHASE_DURATION * RunState.get_hulk_smash_windup_mult()
	# Run 49 — Y-charge: snap aim to the nearest enemy (any direction) on charge
	# start, then show the aim vector line. Steering can move it off afterwards.
	if attack_type == AttackType.Y:
		_y_charge_target = _pick_nearest_enemy_any_dir(FLURRY_LOCK_RANGE)
		if _y_charge_target != null:
			facing = (_y_charge_target.global_position - global_position).normalized()
		_update_y_charge_aim_line()
	_update_charge_aura()
	# Drive animation rig — hold windup pose for the duration of the charge.
	if body_anim and body_anim.has_method("set_anim_state"):
		match attack_type:
			AttackType.Y: body_anim.set_anim_state("windup_y")
			AttackType.X: body_anim.set_anim_state("windup_x")
			AttackType.A: body_anim.set_anim_state("windup_a")
	emit_signal("charge_started", attack_type)


func _cancel_charge() -> void:
	# Used by dash-cancel and by button-release before wind-up completes
	var atk: int = charge_attack_type
	charge_attack_type = AttackType.NONE
	charge_phase_timer = 0.0
	_free_y_charge_aim_line()   # Run 49 — drop the aim vector line
	if charge_aura:
		charge_aura.visible = false
	if _hitfx:
		_hitfx.set_charge(0)   # Run 112 — drop the silhouette charge aura
	if state == State.CHARGING or state == State.CHARGED:
		state = State.IDLE
	emit_signal("charge_canceled", atk)


func _release_charge() -> void:
	# Player released the button while CHARGED → fire the attack
	var atk: int = charge_attack_type
	charge_attack_type = AttackType.NONE
	charge_phase_timer = 0.0
	# Run 49 — keep _y_charge_target for the dash aim, but drop the visual line.
	var y_aim_target: Node2D = _y_charge_target if _is_y_target_valid() else null
	_free_y_charge_aim_line()
	_y_charge_target = y_aim_target
	if charge_aura:
		charge_aura.visible = false
	if _hitfx:
		_hitfx.set_charge(0)   # Run 112 — drop the silhouette charge aura on fire
	# Trigger swing pose on release (windup → swing transition).
	if body_anim and body_anim.has_method("set_anim_state"):
		match atk:
			AttackType.Y: body_anim.set_anim_state("swing_y")
			AttackType.X: body_anim.set_anim_state("swing_x")
			AttackType.A: body_anim.set_anim_state("swing_a")
	emit_signal("charge_released", atk)
	match atk:
		AttackType.Y:
			_start_punch_flurry()
		AttackType.X:
			_start_spinning_crane_kick()
			# Coco-Slam: charge ends in ministun + Vulnerable 3s (AoE around player).
			if RunState.shino_has("coco_slam"):
				_apply_coco_slam()
			# Quake Charge (Potato): ring quake + earth spikes + Cracked Soil AoE.
			if RunState.shino_has("quake_charge"):
				_apply_quake_charge()
		AttackType.A:
			_start_kamehameha()
		_:
			state = State.IDLE
	# Inferno Charge (Pepper): scorched patch at Shino's position on any charge release.
	if RunState.shino_has("inferno_charge"):
		_spawn_fire_zone(global_position, 40.0, 4.0)
	# Flood Charge (Watermelon): apply 3 Soaked to nearby enemies on charge release.
	if RunState.shino_has("flood_charge"):
		_apply_flood_charge()
	# Storm Charge (Banana): knockdown wind-burst or chain-3 electrify on charge release.
	if RunState.shino_has("storm_charge"):
		_apply_storm_charge()
	# Reek Charge (Onion): 360° gas burst (poison nearby) + lingering stink cloud.
	if RunState.shino_has("reek_charge"):
		_apply_reek_charge()
	# Run 150b — Spring Tide duo (Apple+Watermelon): charge release leaves a
	# spring puddle — heroes inside regen, enemies get Soaked/sec.
	if RunState.apple_watermelon_active():
		_spawn_spring_tide_puddle(global_position)


func _update_charge_aura() -> void:
	# Run 112 — the charge tell is now a clean, body-hugging silhouette aura
	# driven by HeroHitFX (warm yellow while winding up, bright pulsing at full),
	# replacing the old rectangular ColorRect that read as an awkward box.
	if charge_aura:
		charge_aura.visible = false   # legacy node retired — kept hidden
	if _hitfx == null:
		return
	if state == State.CHARGING:
		_hitfx.set_charge(1)
	elif state == State.CHARGED:
		_hitfx.set_charge(2)
	else:
		_hitfx.set_charge(0)


# -------------------------------------------------------
# Punch Flurry (§8.2.1 Y-charge — forward multi-hit barrage)
# -------------------------------------------------------
func _start_punch_flurry() -> void:
	# Run 49 — rework (Bruno): release = DASH along the aimed vector (line shown
	# during hold). First enemy contact stops the dash and starts the Pegasus-
	# Meteor pummel; no contact across the full dash = it was just a long dash.
	flurry_direction = facing
	if _is_y_target_valid():
		flurry_direction = (_y_charge_target.global_position - global_position).normalized()
		facing = flurry_direction
	_y_charge_target = null
	# Big Broccoli: scale the melee hitbox for the flurry duration.
	if melee_hitbox_shape and melee_hitbox_shape.shape is RectangleShape2D:
		var bb: float = RunState.get_big_broccoli_aoe_mult() * RunState.get_fury_release_area_mult("shino")
		melee_hitbox_shape.shape.size = Vector2(40, 36) * bb
	state = State.FLURRYING
	_flurry_phase = 0
	_flurry_dash_traveled = 0.0
	flurry_timer = FLURRY_DURATION   # safety floor; pummel timers reset on contact
	flurry_next_hit_at = FLURRY_DURATION
	flurry_hits_dealt = 0
	# Position + orient the melee hitbox out in front for the dash + pummel.
	if melee_hitbox:
		melee_hitbox.position = flurry_direction * 32.0
		melee_hitbox.rotation = flurry_direction.angle()
		melee_hitbox.monitoring = true
	emit_signal("attack_started", AttackType.Y, 99)   # 99 = special "flurry" combo step


# Run 49 — enemy contact check during the charge dash: any living enemy within
# Y_CHARGE_CONTACT_RADIUS of the fist point (just ahead of Shino).
func _y_dash_contact() -> bool:
	var probe: Vector2 = global_position + flurry_direction * 32.0
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or not (e is Node2D) or not e.has_method("take_damage"):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		if probe.distance_to(e.global_position) <= Y_CHARGE_CONTACT_RADIUS:
			return true
	return false


func _begin_meteor_pummel() -> void:
	_flurry_phase = 1
	flurry_timer = FLURRY_DURATION
	flurry_next_hit_at = FLURRY_DURATION   # first hit fires immediately
	flurry_hits_dealt = 0
	# Impact frame on contact — the dash slams to pummel speed.
	_apply_hit_pause(HIT_PAUSE)
	FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_TINY)
	FX.spawn_burst_particles(global_position + flurry_direction * 32.0,
		_fx_col(Color(1.0, 0.90, 0.40, 1.0), "Y"), 12)
	FX.play_sound("flurry_tick")


# Run 49 — Pegasus Meteor visual: superspeed scatter punches flying out from
# Shino's front AND sides, converging forward. A few per pummel tick
# (≈12 across the flurry) at randomized offsets/angles/length = punch barrage.
# Run 69 — swapped the procedural comets for the ethereal jab/cross impact
# sprites (alternating), so the flurry reads as a real flurry of his punches.
func _spawn_meteor_comets() -> void:
	for _i in range(METEOR_COMETS_PER_TICK):
		var side_off: float = randf_range(-26.0, 26.0)
		var back_off: float = randf_range(-8.0, 10.0)
		var origin: Vector2 = global_position \
			+ flurry_direction.orthogonal() * side_off \
			- flurry_direction * back_off
		var dir: Vector2 = flurry_direction.rotated(deg_to_rad(randf_range(-14.0, 14.0)))
		var kind: String = "jab" if (randi() % 2 == 0) else "cross"
		FX.spawn_flurry_punch(kind, origin, dir, randf_range(58.0, 92.0),
			randf_range(0.09, 0.13), randf_range(0.75, 1.05))


func _tick_flurry(delta: float) -> void:
	if state != State.FLURRYING:
		return

	# ---- Phase 0: charge dash along the aim vector ----
	if _flurry_phase == 0:
		velocity = flurry_direction * Y_CHARGE_DASH_SPEED
		move_and_slide()
		_flurry_dash_traveled += Y_CHARGE_DASH_SPEED * delta
		# Dash trail streak so the superspeed reads.
		FX.spawn_punch_comet(global_position - flurry_direction * 18.0, flurry_direction,
			34.0, _fx_col(Color(0.75, 0.92, 1.0, 0.45), "Y"), 0.08, 6.0)
		if melee_hitbox:
			melee_hitbox.position = flurry_direction * 32.0
		if _y_dash_contact():
			_begin_meteor_pummel()
			return
		if _flurry_dash_traveled >= Y_CHARGE_DASH_RANGE:
			_end_flurry()   # no enemy hit — it was just a long dash
		return

	# ---- Phase 1: meteor pummel ----
	# Travel forward at constant velocity — keeps pushing enemies so they stay
	# inside the punch zone (knockback per tick is along flurry_direction).
	var travel_speed: float = FLURRY_TRAVEL_DIST / FLURRY_DURATION
	velocity = flurry_direction * travel_speed
	move_and_slide()

	# Keep the melee hitbox riding in front of us
	if melee_hitbox:
		melee_hitbox.position = flurry_direction * 32.0

	# Fire periodic damage ticks
	if flurry_timer <= flurry_next_hit_at:
		_deal_flurry_tick()
		_spawn_meteor_comets()
		flurry_next_hit_at -= FLURRY_HIT_INTERVAL

	flurry_timer -= delta
	if flurry_timer <= 0.0:
		_end_flurry()


func _deal_flurry_tick() -> void:
	if melee_hitbox == null:
		return
	var bodies: Array = melee_hitbox.get_overlapping_bodies()
	flurry_hits_dealt += 1
	var is_final: bool = (flurry_hits_dealt >= FLURRY_NUM_HITS())
	var base_dmg: int = FLURRY_FINAL_DAMAGE if is_final else FLURRY_HIT_DAMAGE
	# Run 131 — Fury Release charge +60% dmg now applied in _scale_damage's charge
	# branch (so X-crane and A-beam charges get it too, gated on the owning hero).
	# Hulk Smash: +100% charge damage (stacks with Fury Release multiplicatively).
	base_dmg = int(round(float(base_dmg) * RunState.get_hulk_smash_charge_mult()))
	var knockback_dir: Vector2 = flurry_direction
	# Final hit also pushes enemies AWAY harder via a temporary direction boost.
	# Non-final hits push gently forward (so enemies travel with us, can't phase out).
	for body in bodies:
		if not body.is_in_group("enemy") or not body.has_method("take_damage"):
			continue
		# Final flurry tick is a "finisher" (charge-release amp via Noble Rot);
		# non-final ticks are regular charge-release damage with no finisher amp.
		var final_dmg: int = _scale_damage(base_dmg, is_final, false, body, "charge")
		var was_alive: bool = (not body.has_method("is_alive")) or body.is_alive()
		body.set_meta("last_damager", "shino")   # Run 134 — killer attribution (fix 5)
		body.take_damage(final_dmg, knockback_dir)
		_on_hit_connected(final_dmg)
		_apply_melee_lifesteal(final_dmg)
		# Sweet Harvest — 1% max HP self-heal on charge hit (8s ICD).
		if RunState.shino_has("sweet_harvest") and _sweet_harvest_heal_icd <= 0.0:
			var sh_heal: int = max(1, int(round(float(get_effective_max_hp()) * 0.01 * RunState.get_heal_mult("shino"))))
			current_hp = min(get_effective_max_hp(), current_hp + sh_heal)
			emit_signal("hp_changed", current_hp, get_effective_max_hp())
			FX.spawn_hit_particles(global_position, Color(0.85, 0.35, 0.35, 0.7), 4)
			_sweet_harvest_heal_icd = 8.0
		# Fall Harvest — charge-attack kills heal
		if was_alive and body.has_method("is_alive") and not body.is_alive():
			_apply_charge_kill_heal()
		# Phase 7 feel — small per-tick burst, bigger on final
		var p_pos: Vector2 = body.global_position
		if is_final:
			FX.spawn_burst_particles(p_pos, Color(1.0, 0.65, 0.10, 1.0), 14)
		else:
			FX.spawn_hit_particles(p_pos, Color(1.0, 0.85, 0.30, 1.0), 4)
	if is_final:
		_apply_hit_pause(HIT_PAUSE_FINISHER)
		FX.screen_shake(FX.SHAKE_HEAVY, FX.SHAKE_DUR_MED)
		FX.play_sound("flurry_finisher")
		# Bunch Burst (Grape Charge): fire 2 extra hits at 50% damage on flurry final.
		if RunState.shino_has("bunch_burst"):
			for body2 in bodies:
				if not body2.is_in_group("enemy") or not body2.has_method("take_damage"):
					continue
				var burst_dmg: int = max(1, int(round(float(_scale_damage(base_dmg, true, false, body2)) * RunState.BUNCH_BURST_DMG_PCT)))
				for _i in range(RunState.BUNCH_BURST_HITS):
					body2.take_damage(burst_dmg, knockback_dir)
			FX.spawn_burst_particles(global_position + flurry_direction * 32.0, Color(0.55, 0.20, 0.75, 0.9), 10)
	else:
		FX.play_sound("flurry_tick", 0.6)


func _apply_charge_kill_heal() -> void:
	# Apple Fall Harvest: charge-attack kills heal 1% max HP.
	# Run 19 Legendary stack: Juicebox of Youth adds +5% max HP per kill on top.
	var pct: float = RunState.charge_kill_heal_pct + RunState.get_juicebox_kill_heal_pct()
	if pct <= 0.0:
		return
	var max_hp_eff: int = get_effective_max_hp()
	var heal: int = max(1, int(round(max_hp_eff * pct)))
	current_hp = min(max_hp_eff, current_hp + heal)
	emit_signal("hp_changed", current_hp, max_hp_eff)


func FLURRY_NUM_HITS() -> int:
	# Number of damage ticks = floor(DURATION / INTERVAL). Final hit is the bonus one.
	return int(FLURRY_DURATION / FLURRY_HIT_INTERVAL)   # 0.6 / 0.10 = 6


func _end_flurry() -> void:
	velocity = Vector2.ZERO
	if melee_hitbox:
		melee_hitbox.monitoring = false
	# Restore hitbox to base size (Big Broccoli may have scaled it during flurry).
	if melee_hitbox_shape and melee_hitbox_shape.shape is RectangleShape2D:
		melee_hitbox_shape.shape.size = Vector2(40, 36)
	flurry_timer = 0.0
	flurry_next_hit_at = 0.0
	flurry_hits_dealt = 0
	_flurry_phase = 0          # Run 49 — reset dash/pummel phase
	_flurry_dash_traveled = 0.0
	state = State.IDLE


# -------------------------------------------------------
# Attack state machine
# -------------------------------------------------------
func _try_start_attack(attack_type: int) -> void:
	# ============================================================
	# CANCEL SYSTEM (canonical — mirrored across Shino + Bea, Run 12):
	#   - Same attack button = combo continues / advances
	#   - Different attack button = cancels current combo + starts fresh step on the other
	#   - Dash = top-priority interrupt (handled in _handle_input)
	#   - Charge = HOLD-only; brief taps never enter charge state
	# ============================================================
	# Cross-button cancel: Y ↔ X cancel each other mid-combo.
	# Same-button does NOT cancel itself (wait for chain window).
	if state == State.ATTACKING:
		if attack_type == current_attack:
			# Run 29 — Buffer the tap so the next combo step fires the moment the
			# current animation ends (even if the button is released by then).
			# Expires after COMBO_CHAIN_BUFFER seconds to prevent ghost chains.
			if attack_type == AttackType.Y and combo_step < Y_COMBO_HITS:
				_y_chain_queued = true
				_y_chain_queue_timer = COMBO_CHAIN_BUFFER
			elif attack_type == AttackType.X and combo_step < X_COMBO_HITS:
				_x_chain_queued = true
				_x_chain_queue_timer = COMBO_CHAIN_BUFFER
			elif attack_type == AttackType.A:
				# Run 30 — Rapid Ki Blast: buffer the tap; the next shot fires
				# faster + from the other hand the instant this swing ends.
				_a_chain_queued = true
				_a_chain_queue_timer = COMBO_CHAIN_BUFFER
			return
		else:
			# Cross-button cancel: lock the player into the current strike for
			# ATTACK_RECOVERY before the new attack starts. This prevents
			# spamming Y/A/X alternately with no inter-button cooldown.
			_reset_attack_combo()
			current_attack = attack_type
			combo_step = 1
			state = State.ATTACKING   # stay locked during the delay
			_combo_chain_pending = true
			_combo_chain_is_cross_cancel = true
			_combo_chain_timer = ATTACK_RECOVERY
			return

	# Combo continuation window: animation finished and state returned to IDLE
	# (or MOVING — Run 150, Bruno fix 7: walking between taps must NOT reset the
	# chain to Jab 1; the movement tick flips IDLE→MOVING every frame the stick
	# is held, which silently bypassed this branch), but combo_window_timer is
	# still running. A same-button press here continues the chain.
	if (state == State.IDLE or state == State.MOVING) \
	and combo_window_timer > 0.0 and current_attack == attack_type:
		if attack_type == AttackType.Y and combo_step < Y_COMBO_HITS:
			if _y_combo_recovery_timer > 0.0:
				return   # finisher recovery still active; block even late taps
			combo_step += 1
			_perform_attack_swing()
			return
		elif attack_type == AttackType.X and combo_step < X_COMBO_HITS:
			if _x_combo_recovery_timer > 0.0:
				return
			combo_step += 1
			_perform_attack_swing()
			return
		# A has no multi-step combo; fall through to fresh start.

	# Run 26d — Brief recovery lockout after a Y4 Spinning Uppercut. Bruno's
	# request: a visible "landing" pause when Y is spammed so the combo doesn't
	# blur into a single attack stream. X (cross-cancel) ignores this gate so
	# the cancel system stays canonical.
	if attack_type == AttackType.Y and _y_combo_recovery_timer > 0.0:
		return
	# Run 26e — Same pattern for X3 Side Kick recovery.
	if attack_type == AttackType.X and _x_combo_recovery_timer > 0.0:
		return

	current_attack = attack_type
	combo_step = 1
	_perform_attack_swing()


func _perform_attack_swing() -> void:
	# Run 150b — Vine Lash (Grape B, holder-only): the FIRST attack within
	# 0.5s of a dash lashes 3 bonus vines in a cone. Pure bonus damage — no
	# pull, no root (Bruno's call: no CC conflicts with movement or the
	# "base attacks never interrupt" rule). Consumes the window.
	if _vine_lash_window > 0.0 and RunState.shino_has("vine_lash"):
		_vine_lash_window = 0.0
		_fire_vine_lash()
	state = State.ATTACKING
	# Run 131 — One Big Grape (corrupt_grape): pin every Y/X swing to its combo
	# finisher step. This makes the finisher ANIMATION play, sets the finisher
	# hitbox profile, and — because the is_finisher hit check reads combo_step ==
	# Y/X_COMBO_HITS — routes every hit through the full finisher path (bonus
	# damage, knockup, Golden Carrot arm, Master Stroke, Cluster Strike root,
	# Finisher's Aim, baked-apple HoT, cluster-splash). A (ranged) is untouched.
	if RunState.shino_has("corrupt_grape"):
		if current_attack == AttackType.Y:
			combo_step = Y_COMBO_HITS
		elif current_attack == AttackType.X:
			combo_step = X_COMBO_HITS
	# Heavy Stalk +10% attack speed (and any future attack-speed boons) shorten
	# the swing window. Combo chain window scales with it so cross-cancels still
	# feel snappy at high stack counts.
	# Critical Mass attack-speed contribution (+15% per stack).
	var crit_mass_as: float = 1.0
	if RunState.shino_has("critical_mass") and _critical_mass_stacks > 0:
		crit_mass_as = 1.0 + RunState.CRITICAL_MASS_PER_STACK_PCT * float(_critical_mass_stacks)
	var spd: float = max(0.25, RunState.get_char_attack_speed_mult("shino") * crit_mass_as)

	# Run 26d / 26e — Per-step combo personality.
	# Y: Jab → Cross → Hook → Uppercut. (Run 26d.)
	# X: Roundhouse → Roundhouse → Side Kick finisher. (Run 26e — per Bruno's
	#    spec: 2× arc-swipe roundhouses and a rectangular side-kick finisher
	#    that pushes enemies back.)
	# Run 47 — Bruno's feel split: punches fly out faster between hits;
	# kicks are a tad slower but hit harder (pushback at the hit site).
	var step_duration_mult: float = 1.0
	if current_attack == AttackType.Y:
		match combo_step:
			1: step_duration_mult = 0.55   # Jab — snappy
			2: step_duration_mult = 0.75   # Cross — quick follow
			3: step_duration_mult = 1.00   # Hook — wider commit
			4: step_duration_mult = 1.25   # Uppercut — heavy landing
			_: step_duration_mult = 0.85
	elif current_attack == AttackType.X:
		match combo_step:
			1: step_duration_mult = 1.15   # Roundhouse — sweeping, deliberate
			2: step_duration_mult = 1.20   # Roundhouse — mirror sweep
			3: step_duration_mult = 1.45   # Side Kick — heavy commit + push
			_: step_duration_mult = 1.15
	elif current_attack == AttackType.A and combo_step > 1:
		# Run 30 — Rapid Ki Blast: chained shots (fast A taps) fire much
		# faster, alternating hands. combo_step > 1 means this shot was
		# chained from a buffered tap during the previous swing.
		step_duration_mult = KI_RAPID_DUR_MULT

	attack_timer = (ATTACK_ANIM_DURATION * step_duration_mult) / spd
	combo_window_timer = ((ATTACK_ANIM_DURATION * step_duration_mult) + 0.30) / spd

	# Run 52 — hand-drawn punch frames: flash the combo-step frame for a beat,
	# then snap back to fight stance. Any melee swing refreshes the stance hold.
	if current_attack == AttackType.Y or current_attack == AttackType.X:
		_melee_stance_timer = MELEE_STANCE_HOLD
	if current_attack == AttackType.Y:
		_punch_flash_timer = minf(attack_timer, PUNCH_FLASH_MAX)
		_punch_flash_step = clampi(combo_step, 1, 4)

	if current_attack == AttackType.A:
		_fire_ki_blast()
	else:
		_apply_melee_aim_snap()   # Run 60 — face nearest in-reach foe
		_activate_melee_hitbox()

	# Drive animation rig — show the swing pose.
	if body_anim and body_anim.has_method("set_anim_state"):
		match current_attack:
			AttackType.Y: body_anim.set_anim_state("swing_y")
			AttackType.X: body_anim.set_anim_state("swing_x")
			AttackType.A: body_anim.set_anim_state("swing_a")

	# Run 26c / 26d — Visible swing arc, now varied per step for Y combo so
	# the player can read each strike's identity (Jab/Cross/Hook/Uppercut).
	match current_attack:
		AttackType.Y:
			# Run 47 — Y combo per-step visuals (Bruno's comet pass).
			# Jab (step 1)      — small comet flying from Shino to target.
			# Cross (step 2)    — brighter, slightly bigger comet.
			# Hook (step 3)     — crescent swoosh sweeping his left → right.
			# Uppercut (step 4) — rect hitbox flash + rising low-to-high comet.
			match combo_step:
				1:
					FX.spawn_punch_impact("jab", global_position, facing)
				2:
					FX.spawn_punch_impact("cross", global_position, facing)
				3:
					FX.spawn_punch_impact("hook", global_position, facing)
				4:
					# Uppercut — rectangular hitbox read + rising comet.
					FX.spawn_punch_impact("uppercut", global_position, facing)
					# (dragon-silhouette finisher is spawned inside FX.spawn_punch_impact)
					# Small "lift" particles to flair the landing.
					FX.spawn_hit_particles(global_position + Vector2(0, -14),
						_fx_col(Color(1.0, 0.92, 0.30, 1.0), "Y"), 5)
				_:
					FX.spawn_punch_impact("jab", global_position, facing)
		AttackType.X:
			# Run 26e — X combo per-step visuals per Bruno's spec.
			# Step 1 (Roundhouse)        — wide cyan-blue arc sweep.
			# Step 2 (Roundhouse mirror) — wide arc on the OTHER side, slightly
			#                              brighter blue — reads as the second leg.
			# Step 3 (Side Kick)         — straight rectangular hitbox (violet),
			#                              wider rect + push-feel. Knockback boost
			#                              applied at the hit site below.
			# Run 48 — X1/X2 are now sweeping roundhouse kicks: same crescent
			# motion as the Y hook, mirrored legs (X1 left→right, X2 right→left).
			# X3 push kick keeps the rect but SLIDES forward from Shino so the
			# push reads as motion, not a static flash.
			match combo_step:
				1:
					FX.spawn_hook_sweep(global_position, facing, 78.0,
						_fx_col(Color(0.40, 0.85, 1.0, 0.60), "X"), 0.20, -1.0)
				2:
					FX.spawn_hook_sweep(global_position, facing, 80.0,
						_fx_col(Color(0.55, 0.92, 1.0, 0.65), "X"), 0.20, -1.0)
				3:
					# Side Kick finisher — rect pushes out from the player.
					FX.spawn_swing_rect(global_position, facing, 90.0, 52.0,
						_fx_col(Color(0.80, 0.55, 1.0, 0.65), "X"), 0.24, 30.0)
					# Burst particles in front to sell the impact frame.
					FX.spawn_burst_particles(global_position + facing * 70.0,
						_fx_col(Color(0.90, 0.70, 1.0, 1.0), "X"), 8)
				_:
					FX.spawn_hook_sweep(global_position, facing, 78.0,
						_fx_col(Color(0.40, 0.85, 1.0, 0.55), "X"), 0.20, -1.0)
		AttackType.A:
			# Ki Blast — narrow forward ranged flash (lime green).
			# Run 48 — flash follows the aim-assist direction so the muzzle
			# flash and the snapped projectile line up.
			FX.spawn_ranged_flash(global_position, _pick_ki_blast_aim_dir(), 70.0,
				_fx_col(Color(0.55, 1.0, 0.55, 0.65), "A"), 0.12)

	emit_signal("attack_started", current_attack, combo_step)


# Run 27 — family-color attack glow: blend the owned slot boon's family color
# into attack/impact FX. Returns base unchanged when no slot boon is owned.
# _fx_col moved to HeroBase (Batch 2).


func _activate_melee_hitbox() -> void:
	if melee_hitbox == null:
		return
	# Run 47 — per-attack hitbox profiles (Bruno's combat-tightening pass):
	#   Punches (Y1-Y3): base reach (far edge ~52px).
	#   Uppercut (Y4):   taller rectangular box right in front, punch reach —
	#                    reads as a realistic rising hit, not a floor cone.
	#   Kicks (X1-X3):   +30% reach over punches (far edge ~68px).
	var box_size: Vector2 = Vector2(40, 36)
	var box_dist: float = 32.0
	if current_attack == AttackType.X:
		# Run 104 (Bruno) — kicks reach a touch farther + wider on all 3 hits.
		box_size = Vector2(62, 48)
		box_dist = 46.0
	elif current_attack == AttackType.Y and combo_step == Y_COMBO_HITS:
		box_size = Vector2(44, 48)
		box_dist = 32.0
	elif current_attack == AttackType.Y and combo_step <= 2:
		# Run 48 — jab/cross widened: his chi enhances the impact zone, so the
		# punch hits around him laterally, not just a thin line.
		# Run 111 (Bruno) — jab/cross felt too tiny; nudged reach + lateral spread up.
		box_size = Vector2(50, 62)
		box_dist = 34.0
	# Run 131 — One Big Grape (corrupt_grape): every melee hit is a finisher, so
	# grow the strike box +50% ("+50% finisher AoE radius" per the corrupt desc).
	if RunState.shino_has("corrupt_grape") and (current_attack == AttackType.Y or current_attack == AttackType.X):
		box_size *= 1.5
		box_dist *= 1.25
	if melee_hitbox_shape and melee_hitbox_shape.shape is RectangleShape2D:
		melee_hitbox_shape.shape.size = box_size
	melee_hitbox.position = facing * box_dist
	melee_hitbox.rotation = facing.angle()
	melee_hitbox.monitoring = true
	# Run 105 — keep the box live for the first ~55% of THIS swing (proportional,
	# so attack-speed boons can't collapse the active window). max() guards a floor.
	_melee_active_cutoff = max(0.0, attack_timer * 0.45)


# Run 48 — pick the ki blast direction: nearest enemy in the assist cone, or
# raw facing if the cone is empty.
func _pick_ki_blast_aim_dir() -> Vector2:
	# Run 105 — wide weighted assist. Among foes in a generous forward arc, pick
	# the one with the best closeness+alignment blend (not just the raw-nearest in
	# a narrow cone), so A-button shots reliably snap to the threat you're facing.
	var best: Node2D = null
	var best_score: float = -1.0e9
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or not (e is Node2D):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		var to_e: Vector2 = e.global_position - global_position
		var d: float = to_e.length()
		if d < 4.0 or d > KI_AIM_ASSIST_RANGE:
			continue
		var align: float = to_e.normalized().dot(facing)
		if align < KI_AIM_ASSIST_CONE_COS:
			continue
		# Lower score = better. Distance minus an alignment bonus (better-aligned
		# foes feel "closer" to the crosshair) picks the natural target to snap to.
		var score: float = d - align * KI_AIM_ASSIST_ALIGN_WEIGHT
		if best == null or score < best_score:
			best_score = score
			best = e
	if best != null:
		return (best.global_position - global_position).normalized()
	return facing


# Run 60 — Twin-stick ranged: hold the right stick in a direction to auto-fire
# the ranged attack that way (flick = one shot, hold = steady barrage). Free aim,
# shares _ranged_fire_cd with the A button so the two never double the fire rate.
func _tick_stick_fire(delta: float) -> void:
	if _ranged_fire_cd > 0.0:
		_ranged_fire_cd -= delta
	var aim: Vector2 = _aim_vec()
	if aim.length() < AIM_STICK_DEADZONE:
		return
	# Only fire while free to act — never mid-melee, charge, dash, or downed.
	if state != State.IDLE and state != State.MOVING:
		return
	facing = aim.normalized()
	if _ranged_fire_cd <= 0.0:
		# continuous = true → keeps alternating L/R hands instead of resetting to
		# the right hand each shot (combo_step is never advanced on the stick path).
		_fire_ki_blast(facing, true)
		# Run 106 — override the shared gate with the slower stick-only cadence so
		# parking the aim stick fires less often than max A-button spamming.
		_ranged_fire_cd = STICK_AUTO_INTERVAL


# Run 60 — Melee aim snap: orient the swing toward the nearest enemy within
# reach, unless the player is actively pushing roughly opposite that enemy.
func _apply_melee_aim_snap() -> void:
	# Run 105 — weighted best-target auto-aim. Intent = stick push if the player
	# is moving, else current facing. Score blends front-alignment with closeness
	# so the swing turns toward the foe you mean to hit instead of the raw-nearest
	# (which could be behind you) or your walk direction (empty space).
	var mv: Vector2 = _move_axis()
	var pushing: bool = mv.length() > 0.4
	var move_dir: Vector2 = mv.normalized() if pushing else Vector2.ZERO
	var intent: Vector2 = move_dir if pushing else facing
	var best: Node2D = null
	var best_score: float = -1.0e9
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or not (e is Node2D):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		var to_e: Vector2 = e.global_position - global_position
		var d: float = to_e.length()
		if d < 4.0 or d > MELEE_SNAP_RANGE:
			continue
		var dir: Vector2 = to_e / d
		var align: float = dir.dot(intent)
		# Foes already inside strike reach are always eligible; farther ones must
		# be roughly in the intended direction so a deliberate swing isn't hijacked.
		if d > MELEE_REACH and align < MELEE_SNAP_MIN_ALIGN:
			continue
		var closeness: float = 1.0 - clampf(d / MELEE_SNAP_RANGE, 0.0, 1.0)
		var score: float = align * MELEE_SNAP_ALIGN_WEIGHT + closeness
		if score > best_score:
			best_score = score
			best = e
	if best == null:
		return
	var to_best: Vector2 = (best.global_position - global_position).normalized()
	# Deliberate-retreat escape: refuse the snap only when actively pushing hard
	# AWAY from the target AND it's beyond strike reach. In-reach hits always land.
	if pushing and move_dir.dot(to_best) < MELEE_SNAP_OPPOSITE_DOT \
			and global_position.distance_to(best.global_position) > MELEE_REACH:
		return
	facing = to_best


func _fire_ki_blast(override_dir: Vector2 = Vector2.ZERO, continuous: bool = false) -> void:
	if projectile_scene == null:
		print("[Player] KiBlast.tscn not loaded — skip projectile")
		return
	# Run 60 — twin-stick supplies an explicit free-aim direction (no assist);
	# the A-button path passes nothing and keeps its soft aim-assist cone.
	var shot_dir: Vector2 = override_dir.normalized() if override_dir != Vector2.ZERO else _pick_ki_blast_aim_dir()
	_ranged_fire_cd = STICK_RANGED_INTERVAL   # shared gate so stick + A can't double up
	if get_parent() == null:
		return
	# Run 58 — Stone Throw (Potato A) fires 2 blasts in a spaced line; bananarang
	# stays a single boomerang.
	var shots: int = 1
	if not RunState.shino_has("bananarang"):
		shots = RunState.ranged_shot_count("shino")
	for i in shots:
		_spawn_ki_blast(shot_dir, float(i) * RunState.STONE_THROW_SPACING, continuous)
	# Run 24 — Carrot+Watermelon "Refreshing Aim": ranged crits heal Shino 4% max HP (once per attack).
	if RunState.last_crit_result:
		var cw_pct: float = RunState.get_carrot_watermelon_ranged_crit_heal_pct()
		if cw_pct > 0.0:
			var heal_amt: int = max(1, int(round(float(get_effective_max_hp()) * cw_pct)))
			current_hp = min(get_effective_max_hp(), current_hp + heal_amt)
			emit_signal("hp_changed", current_hp, get_effective_max_hp())
			FX.spawn_hit_particles(global_position, Color(0.25, 0.90, 0.70, 1.0), 5)


func _spawn_ki_blast(shot_dir: Vector2, forward_extra: float, continuous: bool = false) -> void:
	var projectile = projectile_scene.instantiate()
	var parent = get_parent()
	if parent == null:
		return
	parent.add_child(projectile)
	# Run 30 — alternate left/right hand spawn points so rapid-fire reads
	# as a two-handed pew-pew. Alternates every shot; fresh single shots
	# restart from the right hand (combo_step == 1 resets in _try_start_attack).
	# Run 106 — continuous stick auto-fire never runs the combo state machine, so
	# combo_step stays <=1 and would reset to the right hand EVERY shot (one-handed).
	# Skip the reset while holding the aim stick so it keeps alternating hands.
	if combo_step <= 1 and not continuous:
		_ki_alt_hand = 0
	var hand_side: float = KI_HAND_OFFSET if _ki_alt_hand == 0 else -KI_HAND_OFFSET
	_ki_alt_hand = 1 - _ki_alt_hand
	projectile.global_position = global_position + shot_dir * (20.0 + forward_extra) \
		+ shot_dir.orthogonal() * hand_side
	# Run 27 — family-color glow on the projectile (A-slot boon family).
	var a_tint: Color = RunState.get_attack_tint("shino", "A")
	if a_tint.a > 0.0:
		projectile.modulate = Color(1, 1, 1, 1).lerp(a_tint, 0.55)
	var scaled_dmg: int = _scale_damage(RANGED_PROJECTILE_DAMAGE, false, false, null, "ranged")
	# Seeded Shot — ranged bonus damage = 1% current HP.
	scaled_dmg += RunState.seeded_shot_bonus_dmg(current_hp, "shino")
	# Run 58 — Slugshot +50% ranged damage.
	scaled_dmg = int(round(float(scaled_dmg) * RunState.get_ranged_damage_mult("shino")))
	if RunState.shino_has("bananarang") and projectile.has_method("launch_bananarang"):
		# Bananarang: pierce outward applying Slippery/Sparked, return applying Greased/Bolted.
		projectile.launch_bananarang(shot_dir, RANGED_PROJECTILE_SPEED, scaled_dmg,
			self, RunState.greased_lightning_mode)
		FX.spawn_ranged_flash(global_position, shot_dir, 40.0,
			Color(0.95, 0.85, 0.15, 0.60) if not RunState.greased_lightning_mode \
			else Color(0.45, 0.95, 0.30, 0.60), 0.10)
		return
	# Run 58 — Slugshot makes the blast pierce every enemy in a line (no detonation).
	if RunState.shino_has("slugshot"):
		projectile.set("_pierce_all", true)
	if projectile.has_method("launch"):
		projectile.launch(shot_dir, RANGED_PROJECTILE_SPEED, scaled_dmg)


func _on_attack_animation_finished() -> void:
	# Chain if player held input OR buffered a tap (Run 29 combo buffer).
	var queued: bool = false
	if current_attack == AttackType.Y and combo_step < Y_COMBO_HITS:
		if _act_p("attack_y") or _y_chain_queued:
			queued = true
			_y_chain_queued = false
			_y_chain_queue_timer = 0.0
	elif current_attack == AttackType.X and combo_step < X_COMBO_HITS:
		if _act_p("attack_x") or _x_chain_queued:
			queued = true
			_x_chain_queued = false
			_x_chain_queue_timer = 0.0
	elif current_attack == AttackType.A:
		# Run 30 — Rapid Ki Blast chain. Only the buffered TAP counts here —
		# a still-held A button means charge intent (Kamehameha), not spam.
		if _a_chain_queued:
			queued = true
			_a_chain_queued = false
			_a_chain_queue_timer = 0.0

	# Run 26d — Y4 Spinning Uppercut "landing" recovery. Bruno's request:
	# a brief realistic pause between Y combos when Y is spammed. Triggers
	# when the Y4 swing animation completes (not at swing-start, so the
	# 0.3s sits AFTER the uppercut's heavy landing, not overlapping it).
	if current_attack == AttackType.Y and combo_step == Y_COMBO_HITS:
		_y_combo_recovery_timer = Y_COMBO_RECOVERY
	# Run 26e — X3 Side Kick recovery (same pattern as Y4).
	if current_attack == AttackType.X and combo_step == X_COMBO_HITS:
		_x_combo_recovery_timer = X_COMBO_RECOVERY

	if queued:
		# Apply ATTACK_RECOVERY delay between steps so each hit lands distinctly
		# before the next swing starts. The timer tick in _tick_timers fires the
		# next _perform_attack_swing() after the brief pause resolves.
		_combo_chain_pending = true
		_combo_chain_timer = ATTACK_RECOVERY
	else:
		_combo_chain_pending = false
		_combo_chain_timer = 0.0
		_y_chain_queued = false
		_y_chain_queue_timer = 0.0
		_x_chain_queued = false
		_x_chain_queue_timer = 0.0
		_a_chain_queued = false
		_a_chain_queue_timer = 0.0
		# Do NOT call _reset_attack_combo() here. Keep current_attack and
		# combo_step alive so a late tap within combo_window_timer continues
		# the chain instead of restarting from step 1.
		# _tick_timers fully resets when combo_window_timer expires.
		state = State.IDLE


func _reset_attack_combo() -> void:
	# Resets the within-attack step (NOT the HUD combo counter)
	current_attack = AttackType.NONE
	combo_step = 0
	attack_timer = 0.0
	combo_window_timer = 0.0
	_combo_chain_pending = false
	_combo_chain_timer = 0.0
	_combo_chain_is_cross_cancel = false
	_y_chain_queued = false
	_y_chain_queue_timer = 0.0
	_x_chain_queued = false
	_x_chain_queue_timer = 0.0
	_a_chain_queued = false
	_a_chain_queue_timer = 0.0
	if melee_hitbox:
		melee_hitbox.monitoring = false


# -------------------------------------------------------
# Movement
# -------------------------------------------------------
func _handle_movement(_delta: float) -> void:
	if state == State.HURT:
		return

	# Status-driven movement lock (Bash). Bash also locks actions, but
	# _handle_input early-outs are state-based — see the explicit check below.
	if status and status.is_movement_locked():
		velocity = Vector2.ZERO
		move_and_slide()
		return

	if state == State.DASHING:
		velocity = dash_direction * DASH_SPEED
		# Afterimage ghost trail — spawn ghosts along the dash path.
		_dash_ghost_cd -= _delta
		if _dash_ghost_cd <= 0.0:
			_dash_ghost_cd = DASH_GHOST_INTERVAL
			FX.spawn_dash_afterimage(_sprite, global_position,
				Color(0.25, 0.50, 0.95, 0.50))
		move_and_slide()
		return

	# Burrowing: free movement at reduced speed; handled in _tick_burrow → velocity set there.
	if state == State.BURROWING:
		move_and_slide()
		return

	# Charge wind-up / aim: player is locked in place (no velocity, no slide).
	# Facing steering is handled in _handle_charge_steering.
	if state == State.CHARGING or state == State.CHARGED:
		velocity = Vector2.ZERO
		move_and_slide()
		return

	# Flurry handles its own movement in _tick_flurry — don't double-apply here.
	if state == State.FLURRYING:
		return

	# Charge-release lockouts: caster planted, no movement allowed.
	# (Spec §8.2.1: Spinning Crane = "in-place 360°"; Kamehameha = "stand, charge,
	# aim, BLAST." Ult cinematic also freezes the caster.)
	if state == State.CRANE_KICKING or state == State.BEAMING or state == State.ULT_CASTING:
		velocity = Vector2.ZERO
		move_and_slide()
		return

	# In AI mode the velocity is set (and move_and_slide called) by
	# _tick_shino_auto_defend. Overwriting it here with zero player input
	# was the bug that made Shino freeze in place while following Bea.
	if not player_controlled:
		return

	var input_vec: Vector2 = Vector2(
		_move_axis().x,
		_move_axis().y
	)
	if input_vec.length() > 1.0:
		input_vec = input_vec.normalized()

	var speed_mod: float = ATTACK_MOVE_DAMPING if state == State.ATTACKING else 1.0
	# Post-dash + crit speed buffs (stack multiplicatively).
	var peel_mult: float = 1.30 if (_peel_out_timer > 0.0 and RunState.shino_has("peel_out")) else 1.0
	var hotfoot_mult: float = (1.0 + RunState.HOT_FOOTED_SPEED_BONUS) if (_hot_footed_timer > 0.0 and RunState.shino_has("hot_footed")) else 1.0
	var zip_mult: float = 1.15 if (_zip_dash_ms_timer > 0.0 and RunState.shino_has("zip_dash")) else 1.0
	# Critical Mass: +15% MS per active stack.
	var crit_mass_ms: float = 1.0
	if RunState.shino_has("critical_mass") and _critical_mass_stacks > 0:
		crit_mass_ms = 1.0 + RunState.CRITICAL_MASS_PER_STACK_PCT * float(_critical_mass_stacks)
	var target_vel: Vector2 = input_vec * move_speed * speed_mod * RunState.get_char_move_speed_mult("shino") * peel_mult * hotfoot_mult * zip_mult * crit_mass_ms * _frost_move_mult()
	# Frostpeak ice: walkable but slippery — Mario-style momentum (hard to start,
	# hard to stop). Solid ground snaps to the target velocity as before.
	if get_meta("on_ice", false):
		velocity = ICE.glide(velocity, target_vel, input_vec.length() > 0.1, _delta)
	else:
		velocity = target_vel
	move_and_slide()

	if input_vec.length() > 0.1 and state != State.ATTACKING:
		facing = input_vec.normalized()
		state = State.MOVING
	elif state == State.MOVING:
		state = State.IDLE

	# Drive procedural animation rig based on movement state.
	# Higher-priority states (attack/charge/death) override below in their respective handlers.
	if body_anim and body_anim.has_method("set_anim_state") and state != State.ATTACKING:
		body_anim.set_motion_speed(velocity.length())
		if state == State.MOVING:
			body_anim.set_anim_state("walking")
		elif state == State.IDLE:
			body_anim.set_anim_state("idle")


# -------------------------------------------------------
# Hit registration (player hitting an enemy)
# -------------------------------------------------------
func _on_melee_hitbox_body_entered(body: Node) -> void:
	# Flurry uses periodic get_overlapping_bodies() ticks; ignore Area2D entry-events
	# to avoid double-counting damage on the first frame an enemy enters the hitbox.
	if state == State.FLURRYING:
		return
	if not body.is_in_group("enemy"):
		return
	if not body.has_method("take_damage"):
		return

	var dmg: int = MELEE_Y_DAMAGE if current_attack == AttackType.Y else MELEE_X_DAMAGE
	# Bonus damage on final hit of each combo
	var is_finisher: bool = false
	if current_attack == AttackType.X and combo_step == X_COMBO_HITS:
		dmg += X_FINISHER_BONUS   # Side Kick finisher — big push-through hit
		is_finisher = true
	if current_attack == AttackType.Y and combo_step == Y_COMBO_HITS:
		dmg += Y_FINISHER_BONUS   # Spinning Uppercut finisher — heavy impact
		is_finisher = true

	# Run 131 — Golden Carrot: a dash arms the next combo finisher as a guaranteed
	# crit (one finisher per dash). Master Stroke duo keeps the unconditional
	# every-finisher guarantee.
	if is_finisher and RunState.master_stroke_active():
		RunState.force_next_crit = true
	elif is_finisher and RunState.shino_has("golden_carrot") and _golden_carrot_armed:
		RunState.force_next_crit = true
		_golden_carrot_armed = false

	# Run 131 — Opening Strike retired; the "first hit on a new enemy = crit" role
	# is now covered by the legendary Topshot (applied in _scale_damage).

	# Finisher's Aim (Carrot Charge slot): +50% crit chance on all combo finishers.
	if RunState.shino_has("finishers_aim") and is_finisher:
		RunState.finisher_crit_chance_bonus = 0.50

	# Apply boon-driven damage scaling (Heavy Stalk, Stalk of Might, Hawkeye,
	# Combo Master + Noble Rot scaling, Bunch Bonus, Apple Full Bloom).
	# is_finisher flag drives Noble Rot's extra +1%/combo-point on Y-final/X-final hits.
	# is_primary flag (Run 16): true ONLY when current_attack == Y — gates Y-slot boons
	# (Heavy Stalk, Full Bloom) per Combat_Boons §8.2/§8.3 Y/X principle.
	# target passed so Crushing Blow, Blazing Aura, Rising Tide, etc. can apply.
	var is_primary_y: bool = (current_attack == AttackType.Y)
	var final_dmg: int = _scale_damage(dmg, is_finisher, is_primary_y, body)
	# Coconut Bash — roll for stun+bonus damage. Lands BEFORE take_damage so
	# the Bash status amp can interact with subsequent damage in the same frame.
	if _try_apply_coconut_bash(body):
		final_dmg += RunState.bash_bonus_damage
	# Shell Breaker (Run 15) — X (secondary) hits 30% per stack to apply
	# Vulnerable (+25% dmg taken / 5s). Stacks refresh duration. Lands BEFORE
	# take_damage so this hit benefits from the freshly-applied amp.
	if current_attack == AttackType.X:
		_try_apply_shell_breaker(body)
	# Run 17 — Status taxonomy: retroactively apply family statuses on melee hit.
	# Watermelon → Wet (or Chilled in Gelato), Pepper → Burning, Banana →
	# Slippery/Greased (or Sparked/Bolted in Greased Lightning), Onion → Poison,
	# Potato (X only) → Cracked Soil → Earthbind Root at 3 stacks. Per-family
	# gate is `<family>_boons_taken > 0` until per-slot boons are wired.
	_apply_family_statuses_on_hit(body, is_primary_y, current_attack == AttackType.X, false, false, false)
	# Run 47 — punches don't shove (they STOP the target); kicks push.
	var kb_vec: Vector2 = Vector2.ZERO if current_attack == AttackType.Y else facing
	# Run 134 — killer attribution for the universal on-death hook (fix 5).
	body.set_meta("last_damager", "shino")
	body.take_damage(final_dmg, kb_vec)
	# Cluster Mastery — combo-point double-strike chance.
	if RunState.get_cluster_mastery_double_chance(combo_count) > randf():
		body.take_damage(final_dmg, kb_vec)
		FX.spawn_hit_particles(body.global_position, Color(0.75, 0.45, 1.0, 0.8), 4)
	# ── Run 27f — Corrupt + Legendary per-hit procs ─────────────────────────
	# Cracked Shell: Concussive Hit — every melee hit ministuns nearby (no dmg).
	if RunState.shino_has("corrupt_coconut"):
		for ce in get_tree().get_nodes_in_group("enemy"):
			if ce != body and is_instance_valid(ce) and ce is Node2D \
			and ce.global_position.distance_to(body.global_position) <= 60.0 \
			and ce.has_node("StatusComponent"):
				ce.get_node("StatusComponent").apply("bash", 0.3, 1)
	# Burnout: 30% chance to apply a random CC on hit.
	if RunState.shino_has("corrupt_broccoli") and randf() < 0.30 and body.has_node("StatusComponent"):
		var _cc_pick: Array = [["bash", 0.5], ["stagger", 0.7], ["root", 1.0]]
		var _cc: Array = _cc_pick[randi() % _cc_pick.size()]
		body.get_node("StatusComponent").apply(_cc[0], _cc[1], 1)
	# Chaos Carrot: every crit applies a random debuff to the target + a
	# random quick buff to yourself.
	if RunState.shino_has("corrupt_carrot") and RunState.last_crit_result and body.has_node("StatusComponent"):
		var _dbf: Array = [["burning", 3.0, 2], ["wet", 4.0, 2], ["chilled", 4.0, 2],
			["poison", 4.0, 2], ["cracked_soil", 4.0, 1], ["slippery", 3.0, 1],
			["sparked", 3.0, 1], ["vulnerable", 5.0, 1]]
		var _db: Array = _dbf[randi() % _dbf.size()]
		body.get_node("StatusComponent").apply(_db[0], _db[1], _db[2])
		match randi() % 3:
			0: _peel_out_timer = 5.0
			1: _hot_footed_timer = 3.0
			2: _critical_mass_stacks = min(3, _critical_mass_stacks + 1); _critical_mass_timer = 4.0
	# Solar Flare: every hit triggers an instant explosion at the target
	# (~30% of the hit's damage, 120px AoE, flat fire).
	if RunState.shino_has("corrupt_pepper"):
		var _sf_dmg: int = max(1, int(round(float(final_dmg) * 0.30 * RunState.fire_damage_mult)))
		FX.spawn_burst_particles(body.global_position, Color(1.0, 0.45, 0.10, 0.95), 10)
		for se in get_tree().get_nodes_in_group("enemy"):
			if se != body and is_instance_valid(se) and se is Node2D \
			and se.global_position.distance_to(body.global_position) <= 120.0 \
			and se.has_method("take_damage"):
				se.take_damage(_sf_dmg, (se.global_position - body.global_position).normalized() * 40.0)
	# Thunderstruck: Y hits chain-lightning; X hits drop a heavy bolt.
	if RunState.shino_has("corrupt_banana") and body.has_node("StatusComponent"):
		if is_primary_y:
			_banana_lightning_chain(body, 3.0)
		elif current_attack == AttackType.X:
			body.get_node("StatusComponent").apply("bolted", 5.0, 1)
	# Mountain King (Potato Legendary): while Ingrained, every hit erupts a
	# spike ring at the target — flat dmg + 1 Cracked Soil in ~120px.
	if RunState.shino_has("mountain_king") and _ingrained_time >= RunState.INGRAINED_THRESHOLD:
		FX.spawn_burst_particles(body.global_position, Color(0.65, 0.50, 0.30, 0.95), 12)
		for me in get_tree().get_nodes_in_group("enemy"):
			if is_instance_valid(me) and me is Node2D \
			and me.global_position.distance_to(body.global_position) <= 120.0:
				if me.has_method("take_damage"):
					me.take_damage(6, (me.global_position - body.global_position).normalized() * 30.0)
				if me.has_node("StatusComponent"):
					me.get_node("StatusComponent").apply("cracked_soil", 4.0, 1)
	# Heatwave (Pepper passive): any combo finisher leaves a burning patch.
	if is_finisher and RunState.shino_has("heatwave"):
		_spawn_fire_zone(body.global_position, 96.0, 4.0)
	# Run 27d — Bunchfist duo (Broccoli+Grape): X heavy attacks strike 3 times
	# in rapid sequence (two delayed echo hits, each resolving separately).
	if current_attack == AttackType.X and RunState.is_duo_active("broccoli_grape"):
		var _bf_body: Node = body
		for _bf_i in range(2):
			get_tree().create_timer(0.08 * float(_bf_i + 1)).timeout.connect(func():
				if is_instance_valid(_bf_body) and _bf_body.has_method("take_damage"):
					if not _bf_body.has_method("is_alive") or _bf_body.is_alive():
						_bf_body.take_damage(final_dmg, facing)
						FX.spawn_hit_particles(_bf_body.global_position, Color(0.40, 0.80, 0.40, 0.85), 4)
			)
	# Run 134 — kill credit (Battle Shell / Rotten Core) now fires from the central
	# Enemy._die() → RunState.process_enemy_death_boons hook, routed to the KILLER
	# hero via the "last_damager" meta set above. Removing the attacker-side
	# detection makes it fire on ALL of Shino's kill types (melee, ranged, charge,
	# ult, procs, DoT) exactly once, with no cross-hero leak and no double-proc.
	# Run 26e — Side Kick (X3 finisher) push: amplify the enemy's knockback
	# velocity after take_damage applies the base impulse. Duck-typed via
	# `in body` so non-knockback enemies (statues, future boss tiers) are
	# safely skipped. Multiplier picked at 2.5× of the base impulse so the
	# enemy reads as "pushed back" rather than "tapped".
	# Run 150 (Bruno fixes 9/10): compute the target's breakbar state ONCE —
	# every direct _knockback_vel write below must respect boss immunity
	# (these writes previously bypassed take_damage's breakbar guard, which is
	# why bosses were still getting shoved by X kicks / Side Kick finishers).
	var _sc_bb: Node = body.get_node("StatusComponent") if body.has_node("StatusComponent") else null
	var _bb_up: bool = _sc_bb != null and _sc_bb.breakbar_enabled and not _sc_bb.is_breakbar_broken()
	if is_finisher and current_attack == AttackType.X and "_knockback_vel" in body and not _bb_up:
		body._knockback_vel = facing.normalized() * (body._knockback_vel.length() * 2.5 if body._knockback_vel.length() > 1.0 else 500.0)
	# Run 47 — punch/kick feel split (Bruno).
	if current_attack == AttackType.Y:
		# Punches: stop the target in place — kill any residual knockback,
		# then a brief freeze. Run 150 (fix 10): Y1-Y3 now apply the SOFT
		# "hitstop" status instead of a real Bash — the enemy pauses for the
		# punch feel but its windup/attack is NEVER cancelled by base attacks.
		# The Y4 uppercut finisher keeps the true Bash + knockup (knockups are
		# a sanctioned full interrupt).
		if _sc_bb != null:
			if "_knockback_vel" in body and not _bb_up:
				body._knockback_vel = Vector2.ZERO
			if is_finisher:
				_sc_bb.apply("bash", UPPERCUT_AIR_TIME + UPPERCUT_LAND_STUN, 1)
				# Run 117 — skip knockup visual if breakbar absorbed the bash.
				if not _bb_up:
					_apply_uppercut_knockup(body)
			else:
				_sc_bb.apply("hitstop", PUNCH_HITSTOP, 1)
		else:
			if "_knockback_vel" in body:
				body._knockback_vel = Vector2.ZERO
			if is_finisher:
				_apply_uppercut_knockup(body)
	elif current_attack == AttackType.X and not is_finisher and "_knockback_vel" in body and not _bb_up:
		# Kicks (X1/X2): tiny pushback — softer than the raw take_damage impulse.
		body._knockback_vel = facing.normalized() * KICK_PUSHBACK
	_on_hit_connected(final_dmg)
	_apply_melee_lifesteal(final_dmg)
	# --- New slot boon per-hit effects ---
	_apply_slot_boon_hit_effects(body, is_finisher, is_primary_y, current_attack == AttackType.X, final_dmg)

	# Run 26d — Baked Apple HoT triggers on combo finishers only (Y4/X3).
	if is_finisher:
		_start_baked_apple_hot()
		# Battle Shell: X finisher (side kick) also grants 1 overshield.
		if current_attack == AttackType.X and RunState.shino_has("battle_shell"):
			grant_overshield_external(1)
	# Finisher hits use a longer freeze-frame so the impact registers clearly.
	if is_finisher:
		_apply_hit_pause(HIT_PAUSE_FINISHER)
	else:
		_apply_hit_pause(HIT_PAUSE)
	# Run 19/20 — Aimed Guard duo (Carrot + Coconut): crits grant 1 overshield
	# (2s ICD). _scale_damage already rolled the crit; check RunState flag.
	if RunState.last_crit_result:
		_try_aimed_guard_grant()
		# Run 27 — Burning Aim duo arm 1 (Carrot+Pepper): crits apply 2 Burn stacks.
		if RunState.burning_aim_active() and body.has_node("StatusComponent"):
			body.get_node("StatusComponent").apply("burning", 3.0, RunState.BURNING_AIM_STACKS_PER_CRIT)
		# Run 22 — Vital Harvest duo (Apple + Carrot): crits heal both heroes 3% max HP.
		var vh_pct: float = RunState.get_vital_harvest_heal_pct()
		if vh_pct > 0.0:
			var heal_amt: int = max(1, int(round(float(get_effective_max_hp()) * vh_pct)))
			current_hp = min(get_effective_max_hp(), current_hp + heal_amt)
			emit_signal("hp_changed", current_hp, get_effective_max_hp())
			FX.spawn_hit_particles(global_position, Color(0.90, 0.60, 0.20, 1.0), 5)
			# Also heal Bea if present. Player.gd doesn't hold a direct Bea ref;
			# query the "bea" group like every other Bea-aware call site (Run 26 fix
			# for the Run 22 START-blocking parse error "_bea not declared").
			for _bea_n in get_tree().get_nodes_in_group("bea"):
				if _bea_n != null and is_instance_valid(_bea_n) and _bea_n.has_method("heal_external") and _bea_n.has_method("get_effective_max_hp"):
					_bea_n.heal_external(max(1, int(round(float(_bea_n.get_effective_max_hp()) * vh_pct))))
	# Run 19/20 — Hulk Smash Legendary: combo finishers (Y4 / X3) emit a
	# shockwave whose radius + damage scale with the live combo counter.
	if is_finisher:
		_try_hulk_smash(body.global_position)
		# Broccoli+Onion "Stinging Greens": Y finishers apply 1 Poison stack.
		var sg_poison: int = RunState.get_broccoli_onion_finisher_poison()
		if sg_poison > 0 and body.has_node("StatusComponent"):
			body.get_node("StatusComponent").apply("poison", 5.0, sg_poison)
		# Onion+Grape "Toxic Combo": finisher on already-Poisoned enemy → +3 Poison burst.
		var og_burst: int = RunState.get_onion_grape_poison_burst()
		if og_burst > 0 and body.has_node("StatusComponent"):
			var sc: Node = body.get_node("StatusComponent")
			if sc.has("poison"):
				sc.apply("poison", 5.0, og_burst)
		# Run 28 — Carrot+Grape "Master Stroke": combo finishers are guaranteed crits.
		if RunState.master_stroke_active():
			RunState.force_next_crit = true
		# Run 28 — Apple+Grape "Bunch Bloom": finisher refunds 1 HP (2 at combo 30).
		var bb_heal: int = RunState.get_bunch_bloom_finisher_heal(combo_count)
		if bb_heal > 0:
			var max_hp_eff: int = get_effective_max_hp()
			current_hp = min(max_hp_eff, current_hp + bb_heal)
			emit_signal("hp_changed", current_hp, max_hp_eff)
			FX.spawn_hit_particles(global_position, Color(0.90, 0.55, 0.75, 0.9), 4)

	# Phase 7 — feel
	var impact_pos: Vector2 = body.global_position
	if is_finisher:
		_spawn_finisher_impact(impact_pos, current_attack == AttackType.Y)
		FX.play_sound("hit_heavy")
	else:
		FX.spawn_hit_particles(impact_pos, Color(1.0, 0.85, 0.30, 1.0), 6)
		FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_TINY)
		FX.play_sound("hit_light")


# Run 47 — Y4 uppercut knockup: pop the enemy's rendered body up ~26px and
# drop it back over UPPERCUT_AIR_TIME. The physics body stays put (Bash
# handles the movement/action lock, so "airborne = stunned" holds), only the
# visual lifts — keeps top-down collision sane. Landing flair on touchdown;
# the landing ministun is the tail of the same Bash window.
func _apply_uppercut_knockup(body: Node) -> void:
	if not (body is Node):
		return
	var lifted: bool = false
	for node_name in ["Body", "Sprite"]:
		var vis: Node = body.get_node_or_null(node_name)
		if vis == null or not (vis is Node2D or vis is Control):
			continue
		var base_y: float = vis.position.y
		var tw := body.create_tween()
		tw.tween_property(vis, "position:y", base_y - 26.0, UPPERCUT_AIR_TIME * 0.35)\
			.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
		tw.tween_property(vis, "position:y", base_y, UPPERCUT_AIR_TIME * 0.65)\
			.set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
		if not lifted:
			# Landing dust on the first lifted visual only (avoid double FX).
			var b_ref: Node = body
			tw.tween_callback(func():
				if is_instance_valid(b_ref) and b_ref is Node2D:
					FX.spawn_hit_particles(b_ref.global_position + Vector2(0, 6),
						Color(0.85, 0.80, 0.60, 0.9), 4)
			)
		lifted = true


# _try_apply_coconut_bash moved to HeroBase (Batch 5).
# _try_apply_shell_breaker moved to HeroBase (Batch 3).


# Run 17 — Family status application on hit. Pragmatic gate: any boon owned
# from a given family enables that family's hit-side status (Wet, Burning,
# Slippery, Poison, Cracked Soil). Slot-boon-specific gating can land when
# the per-slot Y/X/A/B/Charge/Ult boons are filled in. Stack counts follow
# the v0.28 LOCKED mechanic tables (Y=1, X=2, Ult=cap).
func _apply_family_statuses_on_hit(target: Node, is_primary: bool, is_heavy: bool, _is_ranged: bool, _is_charge: bool, is_ult: bool) -> void:
	if not is_instance_valid(target):
		return
	# Run 27e — Static Charge (Banana passive): every 3rd ranged hit drops
	# caltrops at the target's feet (default) or fires a chain + Sparked (GL).
	if _is_ranged and RunState.shino_has("static_charge"):
		_static_charge_count += 1
		if _static_charge_count >= 3:
			_static_charge_count = 0
			if RunState.greased_lightning_mode:
				_banana_lightning_chain(target, 3.0)
			else:
				_spawn_status_zone(target.global_position, 40.0, 4.0, "slippery", 1, Color(0.95, 0.85, 0.30, 0.55))
				# Slapstink pairing applies to this hazard too.
				if RunState.is_duo_active("banana_onion"):
					_spawn_status_zone(target.global_position, 48.0, 3.0, "poison", 1, Color(0.60, 0.85, 0.40, 0.35))
	# Run 27f — Ultimate boon per-hit payloads (Combat_Boons §8 family Ults).
	if is_ult:
		var uts: Variant = target.get("status") if target.has_method("get") else null
		if uts != null and uts.has_method("apply"):
			# Run 131 — ult payloads gate on the ulting hero (Shino) only, not team.
			var owns := func(id: String) -> bool: return RunState.shino_has(id)
			if owns.call("bulwark_strike"):
				uts.apply("bash", 3.0, 1)
			if owns.call("inferno_blossom"):
				uts.apply("burning", 3.0, 3)
			if owns.call("tidal_surge"):
				uts.apply("chilled" if RunState.melon_gelato_mode else "wet", 4.0, 5)
			if owns.call("terrashock"):
				uts.apply("cracked_soil", 4.0, 3)
				uts.apply("stagger", 0.5, 1)
			if owns.call("storm_finale"):
				uts.apply("bolted" if RunState.greased_lightning_mode else "greased", 5.0, 1)
			if owns.call("miasma_burst"):
				uts.apply("poison", 4.0, 5)
	var ts: Variant = target.get("status") if target.has_method("get") else null
	if ts == null or not ts.has_method("apply"):
		return

	# --- Run 59 — A-slot ranged-transform boons (Shino) ---
	# Fireball / Coconut Volley / Stink Bomb were defined + saved but had NO
	# ranged read-site, so they did nothing. Wired per-character (shino_has) so
	# they apply only when SHINO is the picker. Layered ON TOP of the default
	# Ki-Blast impact (modifiers add, never replace).
	if _is_ranged:
		# Fireball (Pepper A): impact ignites — 2 Burn + small fire splash patch.
		if RunState.shino_has("fireball"):
			var fb_dur: float = 3.0 * (1.5 if RunState.shino_has("slow_cook") else 1.0)
			ts.apply("burning", fb_dur, 2)
			_spawn_fire_zone(target.global_position, 28.0, 1.5)
		# Coconut Volley (Coconut A): 30% mini-bash (~0.4s) + flat bonus damage.
		if RunState.shino_has("coconut_volley") and randf() < 0.30:
			ts.apply("bash", 0.4, 1)
			if target.has_method("take_damage"):
				var cv_dmg: int = RunState.bash_bonus_damage if RunState.bash_bonus_damage > 0 else 4
				target.take_damage(cv_dmg, Vector2.ZERO)
			FX.spawn_hit_particles(target.global_position, Color(0.72, 0.50, 0.22, 0.9), 4)
		# Stink Bomb (Onion A): ranged impact bursts into a lingering gas cloud.
		if RunState.shino_has("stink_bomb") and not RunState.shino_has("corrupt_onion"):
			_spawn_gas_bookend(target.global_position)

	# --- Watermelon: Soaked (water) / Chilled (Gelato) ---
	# Slot boons (hydro_jab/heavy_tide/bubble_shot) are the ONLY sources of Wet;
	# the old fallback of "any watermelon boon enables wet" is replaced with explicit gates.
	# Run 131 — per-ninja isolation: gate on SHINO's ownership (was global *_taken,
	# which leaked Bea's Watermelon boons onto Shino's attacks). Mirrors BeaAI.
	var _has_wet_source: bool = RunState.shino_has("hydro_jab") or RunState.shino_has("heavy_tide") or RunState.shino_has("bubble_shot") or is_ult
	if _has_wet_source and RunState.char_family_count("shino", "Watermelon") > 0:
		var wet_id: String = "chilled" if RunState.melon_gelato_mode else "wet"
		var wet_dur: float = 4.0   # spec: 4s per stack baseline
		var wet_stacks: int = 0
		if is_ult:
			wet_stacks = 5    # cap → instant Drenched/Frozen
		elif is_heavy and RunState.shino_has("heavy_tide"):
			wet_stacks = 2
		elif is_primary and RunState.shino_has("hydro_jab"):
			wet_stacks = 1
		elif _is_ranged and RunState.shino_has("bubble_shot"):
			wet_stacks = 2
		# Run 23 — Tidal Tsunami (Watermelon Legendary): +1 stack per hit
		# (caps at 5 inside StatusComponent.apply).
		if RunState.tidal_tsunami_taken:
			wet_stacks += 1
		if wet_stacks > 0:
			ts.apply(wet_id, wet_dur, wet_stacks)
			# Run 128 — Seed Spit rework (Bruno's spec, replaces the doc's
			# 3-seed volley — too close to Grape Shot): ranged impacts SPLASH.
			# Neighbors are knocked back + soaked, and the impact leaves a
			# small slowing puddle (1 Chilled/sec — Chilled = the move slow).
			if _is_ranged and RunState.shino_has("bubble_shot") and target is Node2D:
				var _ss_pos: Vector2 = (target as Node2D).global_position
				for _ss_e in get_tree().get_nodes_in_group("enemy"):
					if _ss_e != target and is_instance_valid(_ss_e) and _ss_e is Node2D \
					and _ss_pos.distance_to(_ss_e.global_position) < 80.0:
						if _ss_e.has_method("take_damage"):
							_ss_e.take_damage(1, (_ss_e.global_position - _ss_pos).normalized())
						var _ss_ts: Variant = _ss_e.get("status") if _ss_e.has_method("get") else null
						if _ss_ts != null and _ss_ts.has_method("apply"):
							_ss_ts.apply(wet_id, wet_dur, 1)
				_spawn_status_zone(_ss_pos, 56.0, 3.0, "chilled", 1, Color(0.45, 0.80, 0.95, 0.45))
			# Run 27f — Cold Waters corrupt: every Watermelon hit applies BOTH
			# Soaked AND Chilled simultaneously.
			if RunState.shino_has("corrupt_watermelon"):
				ts.apply("chilled" if wet_id == "wet" else "wet", wet_dur, wet_stacks)
			# Visual: small aqua/teal splash particles on the target.
			var wet_col: Color = Color(0.30, 0.85, 0.95, 0.9) if not RunState.melon_gelato_mode else Color(0.65, 0.92, 1.0, 0.9)
			FX.spawn_hit_particles(target.global_position, wet_col, 4)
			# Tidal Refresh — +2 Chi on apply. 3s ICD per target.
			if RunState.shino_has("tidal_refresh"):
				_try_tidal_refresh_chi(target)

	# --- Pepper: Burning ---
	# Slot boons (spicy_jab / searing_strike) are the explicit Burn sources.
	# Ult always applies Burn if any Pepper boon is owned.
	var _has_burn_source: bool = RunState.shino_has("spicy_jab") or RunState.shino_has("searing_strike") or is_ult
	if _has_burn_source and RunState.char_family_count("shino", "Pepper") > 0:
		var burn_dur: float = 3.0
		if RunState.shino_has("slow_cook"):
			burn_dur *= 1.5
		var burn_stacks: int = 0
		if is_ult:
			burn_stacks = 5
		elif is_heavy and RunState.shino_has("searing_strike"):
			burn_stacks = 2
		elif is_primary and RunState.shino_has("spicy_jab"):
			burn_stacks = 1
		# Run 23 — Shock Ignition (Pepper + Grape duo): Shocked targets ignite
		# more reliably. In the prototype the "25% extra ignite chance" is
		# realized as +1 burn stack when the target is currently Shocked
		# (rolled at apply time). Caps at the burning stack cap inside
		# StatusComponent.apply, so no overflow.
		if ts.has("shocked") and RunState.shock_ignition_active():
			if randf() < RunState.get_shock_ignition_burn_bonus():
				burn_stacks += 1
		# Run 59 — Pyromania (Pepper passive): consecutive Pepper hits within a 2s
		# window build a streak, adding bonus Burn stacks (cap +3 at streak 4+).
		if burn_stacks > 0 and RunState.shino_has("pyromania"):
			var _now: float = float(Time.get_ticks_msec()) / 1000.0
			if _now - _pyromania_last_hit <= 2.0:
				_pyromania_streak = min(_pyromania_streak + 1, 5)
			else:
				_pyromania_streak = 1
			_pyromania_last_hit = _now
			burn_stacks += clampi(_pyromania_streak - 1, 0, 3)
		# Run 19 — Elemental Synergy pre-checks (additive-only, no stack consumption).
		# Steam Burst (Pepper × Watermelon water): +15% bonus on fire-hit-on-wet.
		# Thaw Burst (Pepper × Watermelon Gelato): +15% bonus on fire-hit-on-frostbitten.
		if burn_stacks > 0 and not RunState.shino_has("corrupt_pepper"):
			var was_wet_pre: bool         = ts.is_wet()
			var was_frostbitten_pre: bool = ts.is_frostbitten()
			ts.apply("burning", burn_dur, burn_stacks)
			# Run 27 — Magma Vein synergy (Potato×Pepper): fire hit on a
			# Cracked Soil target erupts a small fire patch at their feet.
			if RunState.is_synergy_active("magma_vein") and ts.has("cracked_soil"):
				_spawn_fire_zone(target.global_position, 32.0, 3.0)
			# Visual: small orange-red ember particles on the target.
			FX.spawn_hit_particles(target.global_position, Color(1.0, 0.45, 0.10, 0.9), 4)
			# Per spec §11: synergies NEVER consume stacks — always additive.
			if was_frostbitten_pre and RunState.is_synergy_active("thaw_burst"):
				_trigger_thaw_burst(target)
			elif was_wet_pre and RunState.is_synergy_active("steam_burst"):
				_trigger_steam_burst(target)

	# --- Banana: Slippery/Greased via slot boons (Peel Slap Y / Voltaic Strike X) ---
	# Peel Slap applies on Y hits; Voltaic Strike on X hits. Ult applies both.
	var _banana_should_apply: bool = (is_primary and RunState.shino_has("peel_slap")) \
		or (is_heavy and RunState.shino_has("voltaic_strike")) \
		or is_ult
	if _banana_should_apply and RunState.char_family_count("shino", "Banana") > 0:
		var was_slipping_pre: bool = ts.has("slippery") or ts.has("greased")
		var slip_id: String
		var slip_dur: float
		if RunState.greased_lightning_mode:
			slip_id = "bolted" if is_heavy else "sparked"
			slip_dur = 5.0 if is_heavy else 3.0
		else:
			slip_id = "greased" if is_heavy else "slippery"
			slip_dur = 5.0 if is_heavy else 3.0
		ts.apply(slip_id, slip_dur, 1)
		# Visual: yellow peel puff (default) or blue spark (Greased Lightning).
		if RunState.greased_lightning_mode:
			FX.spawn_hit_particles(target.global_position, Color(0.55, 0.80, 1.0, 0.85), 3)
		else:
			FX.spawn_hit_particles(target.global_position, Color(0.95, 0.90, 0.25, 0.85), 3)
		# Run 19 — chain-lightning. When Greased Lightning mode is on, the
		# primary hit also chains to nearby enemies via Shocked tagging.
		# Depth-limited to avoid runaway in dense rooms.
		if RunState.greased_lightning_mode:
			ts.apply("shocked", slip_dur, 1)
			_banana_lightning_chain(target, slip_dur)
		# Run 23 — Bruise Peel apply (post-slip-tag, gated on pre-state).
		if was_slipping_pre and RunState.bruise_peel_active():
			var stagger_dur: float = RunState.get_bruise_peel_stagger_dur()
			if stagger_dur > 0.0:
				ts.apply("stagger", stagger_dur, 1)
		# Run 24 — Banana+Pepper "Slip & Burn": slipping enemy +40% ignite chance on this hit.
		# Fires if the enemy was already slipping before this hit.
		if was_slipping_pre and RunState.banana_pepper_active():
			var bp_chance: float = RunState.get_banana_pepper_ignite_chance()
			if randf() < bp_chance:
				ts.apply("burning", 4.0, 2)

	# --- Run 19 Elemental Synergy: Wet + Lightning damage amp is applied at
	#       target's take_damage via RunState.get_wet_lightning_target_mult.

	# --- Onion: Poison via slot boons (Pungent Jab Y / Tear Strike X) ---
	var _onion_should_apply: bool = (is_primary and RunState.shino_has("pungent_jab")) \
		or (is_heavy and RunState.shino_has("tear_strike")) \
		or is_ult
	if _onion_should_apply and RunState.char_family_count("shino", "Onion") > 0 and not RunState.shino_has("corrupt_onion"):
		var p_dur: float = 4.0
		if RunState.shino_has("chronic_reek"):
			p_dur *= 1.5
		var p_stacks: int = 1
		if is_ult:
			p_stacks = 5
		elif is_heavy and RunState.shino_has("tear_strike"):
			p_stacks = 2
		elif is_primary and RunState.shino_has("pungent_jab"):
			p_stacks = 1
		ts.apply("poison", p_dur, p_stacks)
		FX.spawn_hit_particles(target.global_position, Color(0.55, 0.85, 0.30, 0.85), 3)

	# --- Potato: Cracked Soil on heavy (X) only; 3 stacks → Earthbind Root ---
	if RunState.char_family_count("shino", "Potato") > 0 and is_heavy:
		ts.apply("cracked_soil", 4.0, 1)
		# Visual: brown dust puff on Cracked Soil application.
		FX.spawn_hit_particles(target.global_position, Color(0.55, 0.40, 0.20, 0.80), 3)
		if ts.get_stacks("cracked_soil") >= 3:
			# Run 27f — Petrify (Potato Legendary): Earthbind upgrades to a 3s
			# full Stun + Vulnerable (total action lock + damage amp).
			if RunState.shino_has("petrify") or RunState.bea_has("petrify"):
				ts.apply("bash", 3.0, 1)
				ts.apply("vulnerable", 3.0, 2)
			else:
				ts.apply("root", 1.5, 1)
			ts.remove("cracked_soil")
			# Visual: earthen burst when Earthbind Root triggers.
			FX.spawn_burst_particles(target.global_position, Color(0.45, 0.30, 0.15, 0.90), 10)


# Run 19 — Banana chain-lightning. Depth-limited spread of Sparked/Bolted +
# Shocked tag from the primary target to nearby enemies.
# Tuning constants:
const BANANA_CHAIN_RADIUS:   float = 140.0
const BANANA_CHAIN_MAX_JUMPS: int   = 2    # primary + 2 chains = 3 enemies max
const BANANA_CHAIN_DMG_PCT:  float = 0.30   # chained enemies take 30% of a flat tick

func _banana_lightning_chain(primary_target: Node, dur: float) -> void:
	if primary_target == null or not is_instance_valid(primary_target):
		return
	var tree := get_tree()
	if tree == null:
		return
	var visited: Dictionary = { primary_target.get_instance_id(): true }
	var origin: Vector2 = primary_target.global_position
	var jumps_done: int = 0
	# Collect candidates: enemies (not the primary, not already shocked).
	var candidates: Array = []
	for body in tree.get_nodes_in_group("enemy"):
		if not is_instance_valid(body) or body == primary_target:
			continue
		if visited.has(body.get_instance_id()):
			continue
		var dist: float = (body.global_position - origin).length()
		if dist > BANANA_CHAIN_RADIUS:
			continue
		candidates.append({"body": body, "d": dist})
	# Sort by distance — closest first.
	candidates.sort_custom(func(a, b): return float(a["d"]) < float(b["d"]))
	# Voltaic Engine (Banana Legendary): +1 chain jump (2 → 3).
	var max_jumps: int = BANANA_CHAIN_MAX_JUMPS + (1 if RunState.voltaic_engine_taken else 0)
	# Run 27 — Grounding synergy (Potato×Banana): +1 chain jump when the
	# primary target has Cracked Soil or is Earthbound (rooted).
	var _pts: Variant = primary_target.get("status") if primary_target.has_method("get") else null
	if _pts != null and RunState.is_synergy_active("grounding") \
	and (_pts.has("cracked_soil") or _pts.has("root")):
		max_jumps += 1
	for c in candidates:
		if jumps_done >= max_jumps:
			break
		var b: Node = c["body"]
		var ts2: Variant = b.get("status") if b.has_method("get") else null
		if ts2 == null or not ts2.has_method("apply"):
			continue
		# Apply Shocked + chain-mode status (Bolted prefers if mode swap'd).
		var chain_id: String = "sparked"   # always chain to lighter spark
		ts2.apply(chain_id, dur, 1)
		ts2.apply("shocked", dur, 1)
		# Run 27 — Toxic Conduit synergy (Onion×Banana): chains through a
		# Poisoned primary carry 1 Poison stack to each chain target.
		if _pts != null and _pts.has("poison") and RunState.is_synergy_active("toxic_conduit"):
			ts2.apply("poison", 4.0, 1)
		# Run 27b — Peel Restoration duo (Apple+Banana, GL arm): lightning
		# bolt hits heal the hero 1 HP (1.5s ICD per hero).
		if RunState.is_duo_active("apple_banana") and _peel_resto_icd <= 0.0:
			_peel_resto_icd = 1.5
			heal_external(1)
		# Run 27d — Tide Storm duo: lightning applies 1 Soaked on hit.
		if RunState.is_duo_active("banana_watermelon"):
			ts2.apply("wet", 4.0, 1)
		# Flat lightning tick — keeps chain feeling impactful even on low combo.
		var tick: int = max(1, int(round(float(RunState.HULK_SMASH_BASE_DAMAGE) * BANANA_CHAIN_DMG_PCT)))
		if b.has_method("take_damage"):
			b.take_damage(tick, Vector2.ZERO)
		# Subtle blue spark FX between origin and chained body.
		_spawn_chain_arc(origin, b.global_position)
		jumps_done += 1


# Brief Line2D arc between two points for chain-lightning visual.
func _spawn_chain_arc(from: Vector2, to: Vector2) -> void:
	var parent: Node = get_tree().get_root().get_node_or_null("World")
	if parent == null:
		parent = get_tree().get_current_scene()
	if parent == null:
		return
	var arc := Line2D.new()
	arc.default_color = Color(0.65, 0.85, 1.0, 0.95)
	arc.width = 2.0
	arc.add_point(from)
	# Slight zig in the middle for spark feel.
	var mid: Vector2 = (from + to) * 0.5 + Vector2(randf_range(-12.0, 12.0), randf_range(-12.0, 12.0))
	arc.add_point(mid)
	arc.add_point(to)
	arc.z_index = 12
	parent.add_child(arc)
	var tween: Tween = arc.create_tween()
	tween.tween_property(arc, "modulate:a", 0.0, 0.18)
	tween.tween_callback(arc.queue_free)


# Run 19 — Elemental Synergy: Steam Burst (Pepper × Watermelon water).
# Per spec §11 #2: +15% bonus damage on the hit + 2m steam puff for 1.5s that
# briefly blinds enemies inside (-20% accuracy). NO stack consumption.
# Implementation: small flat damage bonus tick (representing the +15%) + spawn
# the 100px steam puff with brief slippery (proxy for blind miss-chance).
func _trigger_steam_burst(target: Node) -> void:
	if not is_instance_valid(target):
		return
	# +15% bonus damage represented as flat 8 dmg follow-up tick.
	if target.has_method("take_damage"):
		target.take_damage(RunState.STEAM_BURST_FLAT_DMG, Vector2.ZERO)
	var origin: Vector2 = target.global_position
	# Brief blind via slippery on enemies inside the puff (2m ≈ 100px).
	for body in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(body):
			continue
		var dist: float = (body.global_position - origin).length()
		if dist > RunState.STEAM_BURST_PUFF_RADIUS:
			continue
		var ts2: Variant = body.get("status") if body.has_method("get") else null
		if ts2 != null and ts2.has_method("apply"):
			ts2.apply("slippery", RunState.STEAM_BURST_BLIND_DUR, 1)
	_spawn_steam_puff(origin)
	if get_node_or_null("/root/FX") != null:
		FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_SHORT)
		FX.play_sound("steam_burst", 0.9)


func _spawn_steam_puff(pos: Vector2) -> void:
	var parent: Node = get_tree().get_root().get_node_or_null("World")
	if parent == null:
		parent = get_tree().get_current_scene()
	if parent == null:
		return
	for i in range(8):
		var p := ColorRect.new()
		p.size = Vector2(randi_range(8, 14), randi_range(8, 14))
		p.color = Color(0.85, 0.92, 0.98, 0.75)
		p.position = pos + Vector2(randf_range(-40.0, 40.0), randf_range(-40.0, 40.0))
		p.z_index = 9
		parent.add_child(p)
		var tween: Tween = p.create_tween()
		tween.tween_property(p, "position", p.position + Vector2(0, -28), 0.45)
		tween.parallel().tween_property(p, "modulate:a", 0.0, 0.45)
		tween.tween_callback(p.queue_free)


# Run 19 — Elemental Synergy: Thaw Burst (Pepper × Watermelon Gelato).
# Per spec §11 #4: +15% bonus damage on the hit. NO thaw/consumption.
# Stacks remain intact for max-state ramp toward Frozen.
func _trigger_thaw_burst(target: Node) -> void:
	if not is_instance_valid(target):
		return
	if target.has_method("take_damage"):
		target.take_damage(RunState.THAW_BURST_FLAT_DMG, Vector2.ZERO)
	if get_node_or_null("/root/FX") != null:
		FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_SHORT)
		FX.spawn_burst_particles(target.global_position, Color(0.95, 0.80, 0.55, 1.0), 10)
		FX.play_sound("thaw_burst", 0.9)


# Watermelon Tidal Refresh — +2 Chi on Wet/Chilled apply (1 trigger / target / 3s ICD).
# ICD enforced via per-target meta on the target's status component.
var _tidal_refresh_per_target: Dictionary = {}   # weak-ref id → timestamp
func _try_tidal_refresh_chi(target: Node) -> void:
	var now: float = Time.get_ticks_msec() / 1000.0
	var key: int = target.get_instance_id()
	var last: float = float(_tidal_refresh_per_target.get(key, -10.0))
	if now - last < 3.0:
		return
	_tidal_refresh_per_target[key] = now
	current_chi = min(get_effective_max_chi(), current_chi + 2)
	emit_signal("chi_changed", current_chi, get_effective_max_chi())


func _apply_melee_lifesteal(damage_dealt: int) -> void:
	# Reserved for future lifesteal-on-hit boons. Baked Apple no longer uses
	# this path as of Run 26d — it now drives a finisher-only HoT instead.
	# Kept as a no-op when no boon writes to melee_lifesteal_pct.
	if RunState.melee_lifesteal_pct <= 0.0:
		return
	var heal: int = max(1, int(round(damage_dealt * RunState.melee_lifesteal_pct)))
	var max_hp_eff: int = get_effective_max_hp()
	if current_hp >= max_hp_eff:
		return
	current_hp = min(max_hp_eff, current_hp + heal)
	emit_signal("hp_changed", current_hp, max_hp_eff)


# Run 26d — Baked Apple finisher HoT.
# Called on each Y4 / X3 combo finisher. (Re)starts a 5s 1-HP/sec regen.
# Stacks with the existing healing pipeline (no special amp; uses raw HP set).
func _start_baked_apple_hot() -> void:
	# Run 154 Batch 6 — picker-only self-buff (Run 150b lock; sibling Apple passive
	# Sweet Dreams gates per-hero too). Was RunState.baked_apple_taken (GLOBAL) — a
	# rot that let Shino heal from a finisher-HoT only Bea owned. Now per-hero.
	if not RunState.shino_has("baked_apple"):
		return
	_baked_apple_hot_remaining = RunState.BAKED_APPLE_HOT_DURATION
	_baked_apple_hot_accum = 0.0
	# Tiny visual ping so the player sees the proc.
	FX.spawn_hit_particles(global_position + Vector2(0, -20),
		Color(0.95, 0.55, 0.30, 1.0), 3)


func _tick_baked_apple_hot(delta: float) -> void:
	if _baked_apple_hot_remaining <= 0.0:
		return
	# Tick down the duration.
	var step: float = min(delta, _baked_apple_hot_remaining)
	_baked_apple_hot_remaining -= step
	# Heal 1 HP per accumulated second (fractional accumulator → whole-HP applies).
	_baked_apple_hot_accum += step * RunState.BAKED_APPLE_HOT_HP_PER_SEC
	if _baked_apple_hot_accum >= 1.0:
		var whole: int = int(floor(_baked_apple_hot_accum))
		_baked_apple_hot_accum -= float(whole)
		var max_hp_eff: int = get_effective_max_hp()
		if current_hp < max_hp_eff:
			current_hp = min(max_hp_eff, current_hp + whole)
			emit_signal("hp_changed", current_hp, max_hp_eff)


func _on_hit_connected(dmg: int) -> void:
	# Chi gain on damage dealt (§8.3.2)
	var chi_cap: int = get_effective_max_chi()
	# Run 27f — Cold Waters corrupt: Chi generation halved from all sources.
	var _chi_gain_mult: float = 0.5 if RunState.shino_has("corrupt_watermelon") else 1.0
	_chi_gain_mult *= (1.0 + RunState.get_poison_apple_conversion_pct("shino"))   # Run 139
	current_chi = min(chi_cap, current_chi + int(CHI_PER_DAMAGE_DEALT * dmg * _chi_gain_mult))
	emit_signal("chi_changed", current_chi, chi_cap)

	# HUD combo counter increment + reset grace timer (§8.3.1)
	# Run 128 — Vineyard Reserve (Grape Legendary): +2 combo per hit.
	var _combo_inc: int = 2 if RunState.shino_has("vineyard_reserve") else 1
	combo_count = min(COMBO_CAP, combo_count + _combo_inc)
	combo_grace_timer = COMBO_RESET_GRACE
	combo_decay_timer = 0.0   # any new hit cancels Combo Master soft-decay
	# Run 60 — mirror to RunState so external systems read a single source of truth.
	RunState.set_combo("shino", combo_count)
	emit_signal("combo_count_changed", combo_count)

	# Combat Fury (Broccoli) — advance tier up to max on each consecutive hit.
	if RunState.shino_has("combat_fury"):
		_combat_fury_tier = min(RunState.COMBAT_FURY_MAX_TIERS, _combat_fury_tier + 1)
		_combat_fury_decay_timer = RunState.COMBAT_FURY_DECAY_SEC

	# Critical Mass (Carrot) — if the last hit was a crit, gain a stack.
	if RunState.shino_has("critical_mass") and RunState.last_crit_result:
		_critical_mass_stacks = min(RunState.CRITICAL_MASS_MAX_STACKS, _critical_mass_stacks + 1)
		_critical_mass_timer = RunState.CRITICAL_MASS_DURATION   # refresh all stacks on new crit
		# AS boost is applied by modifying attack_speed_mult temporarily. We track it via
		# the stacks rather than mutating RunState.attack_speed_mult to avoid drift.



# -------------------------------------------------------
# Slot boon per-hit effects (all new boons)
# Called from _on_melee_hitbox_body_entered after take_damage.
# -------------------------------------------------------
func _apply_slot_boon_hit_effects(target: Node, is_finisher: bool, is_primary: bool, is_heavy: bool, dmg_dealt: int) -> void:
	if not is_instance_valid(target):
		return

	# Apple Heavy Harvest (X): scales dmg with HP fraction — already applied via _scale_damage.
	# Apple Seeded Shot, Evergreen Step, Sweet Harvest: handled in ranged / dash / charge paths.

	# Broccoli Brute Force (X): small shockwave around the hit target.
	if is_heavy and RunState.shino_has("brute_force"):
		_spawn_brute_force_shockwave(target.global_position)

	# Broccoli Fury Release (Charge): handled in charge release path.

	# Grape Cluster Strike (Y finisher): +60% dmg already in _scale_damage via is_finisher;
	# also apply Vinewrap (root 2s) to all enemies in range.
	if is_finisher and is_primary and RunState.shino_has("cluster_strike"):
		_apply_vinewrap(target.global_position, KATANA_RANGE if RunState.shino_has("cluster_strike") else 48.0)
	# Grape Overhead Crush (X finisher): Vinewrap on X finisher.
	if is_finisher and is_heavy and RunState.shino_has("overhead_crush"):
		_apply_vinewrap(target.global_position, 56.0)

	# Potato Spud Stomp (Y): +15% earth dmg already in scale_damage; Ground Pound on Y finisher.
	if is_finisher and is_primary and RunState.shino_has("spud_stomp"):
		_spawn_ground_pound(target.global_position, 96.0)
	# Potato Rock Smash (X): +30% earth dmg + 1 Cracked Soil — Cracked Soil already in family_status.

	# Coconut Coco-Slam (Charge): handled in charge release path.

	# Tear Strike (Onion X): +30% bonus dmg — applied in _scale_damage via X modifier.

	# Apple Evergreen Step: first hit post-dash heals.
	if RunState.shino_has("evergreen_step") and _evergreen_step_active:
		_evergreen_step_active = false
		var heal: int = max(1, int(round(float(get_effective_max_hp()) * 0.01)))
		current_hp = min(get_effective_max_hp(), current_hp + heal)
		emit_signal("hp_changed", current_hp, get_effective_max_hp())
		FX.spawn_hit_particles(global_position, Color(0.95, 0.30, 0.30, 0.9), 5)

	# Flanking Strike: guaranteed crit timer ticking in _tick_timers; flag set on dash.

	# --- Run 28 Duo hit effects ---
	var ts_target: Variant = target.get("status") if target.has_method("get") else null

	# Broccoli+Pepper "Firebrand": X (heavy) hits apply 2 Burn stacks for 3s.
	if is_heavy and RunState.firebrand_active() and ts_target != null and ts_target.has_method("apply"):
		ts_target.apply("burning", 3.0, 2)
		FX.spawn_hit_particles(target.global_position, Color(0.95, 0.40, 0.10, 0.9), 4)

	# Broccoli+Watermelon "Splash Smash": X / X-charge applies +3 Soaked (water) or +3 Chilled (Gelato).
	if is_heavy and RunState.splash_smash_active() and ts_target != null and ts_target.has_method("apply"):
		var wet_id: String = "chilled" if RunState.melon_gelato_mode else "wet"
		ts_target.apply(wet_id, 4.0, 3)
		var wet_col: Color = Color(0.55, 0.85, 0.95, 0.9) if RunState.melon_gelato_mode else Color(0.30, 0.70, 0.95, 0.9)
		FX.spawn_hit_particles(target.global_position, wet_col, 5)

	# Grape+Watermelon "Cluster Splash": finishers (or every hit at combo 30) burst 2m AoE.
	if RunState.should_cluster_splash_trigger(is_finisher, combo_count):
		_apply_cluster_splash(target.global_position)
		# +3 combo counter bonus on finishers.
		if is_finisher:
			combo_count = min(COMBO_CAP, combo_count + RunState.CLUSTER_SPLASH_COMBO_BONUS)
			RunState.set_combo("shino", combo_count)   # Run 60 — mirror cluster-splash bonus
			emit_signal("combo_count_changed", combo_count)

	# Grape+Potato "Stomp Combo": Y finisher → cracked earth line; X finisher → earthspike line.
	if is_finisher and RunState.stomp_combo_active():
		var line_len: float = RunState.get_stomp_combo_line_length(combo_count)
		if is_primary:
			_spawn_stomp_earth_line(target.global_position, line_len, false)
		elif is_heavy:
			_spawn_stomp_earth_line(target.global_position, line_len, true)

	# Broccoli+Potato "Earthshaker": X finisher launches enemies + 3 Cracked Soil.
	if is_finisher and is_heavy and RunState.earthshaker_active() and ts_target != null and ts_target.has_method("apply"):
		ts_target.apply("stagger", 0.5, 1)   # launch proxy (stagger = airborne stub)
		ts_target.apply("cracked_soil", 5.0, 3)
		FX.spawn_burst_particles(target.global_position, Color(0.55, 0.38, 0.18, 0.9), 12)
		FX.screen_shake(FX.SHAKE_MEDIUM, FX.SHAKE_DUR_SHORT)


const KATANA_RANGE: float = 48.0   # same range for Y finisher Vinewrap

# --- Grape+Watermelon Cluster Splash AoE ---
func _apply_cluster_splash(origin: Vector2) -> void:
	var wet_id: String = "chilled" if RunState.melon_gelato_mode else "wet"
	var col: Color = Color(0.55, 0.85, 0.95, 0.8) if RunState.melon_gelato_mode else Color(0.30, 0.70, 0.95, 0.8)
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or (e.has_method("is_alive") and not e.is_alive()):
			continue
		if origin.distance_to(e.global_position) > RunState.CLUSTER_SPLASH_RADIUS:
			continue
		var ts: Variant = e.get("status") if e.has_method("get") else null
		if ts != null and ts.has_method("apply"):
			ts.apply(wet_id, 4.0, RunState.CLUSTER_SPLASH_STACKS)
	FX.spawn_burst_particles(origin, col, 8)


# --- Grape+Potato Stomp Combo line ---
func _spawn_stomp_earth_line(origin: Vector2, length: float, is_spike: bool) -> void:
	# Spawns a line of cracked-earth / earthspike effects in front of the player.
	var step: float = 32.0
	var steps: int = int(length / step)
	var dir: Vector2 = facing.normalized()
	for i in range(1, steps + 1):
		var pos: Vector2 = origin + dir * (step * float(i))
		for e in get_tree().get_nodes_in_group("enemy"):
			if not is_instance_valid(e) or (e.has_method("is_alive") and not e.is_alive()):
				continue
			if pos.distance_to(e.global_position) > 28.0:
				continue
			var ts: Variant = e.get("status") if e.has_method("get") else null
			if ts != null and ts.has_method("apply"):
				if is_spike:
					ts.apply("stagger", 0.5, 1)
					ts.apply("cracked_soil", 4.0, 2)
				else:
					ts.apply("cracked_soil", 4.0, 1)
	# Visual: thin line of earth-colored dots along the direction.
	var line_col: Color = Color(0.55, 0.38, 0.18, 0.85) if not is_spike else Color(0.42, 0.28, 0.12, 0.90)
	FX.spawn_burst_particles(origin + dir * (length * 0.5), line_col, 10)
	if is_spike:
		FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_TINY)


func _spawn_brute_force_shockwave(origin: Vector2) -> void:
	var radius: float = RunState.BRUTE_FORCE_SHOCKWAVE_RADIUS
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or e == null:
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		if origin.distance_to(e.global_position) > radius:
			continue
		if e.has_method("take_damage"):
			e.take_damage(int(round(float(RunState.BRUTE_FORCE_DMG_BONUS * 8))), (e.global_position - origin).normalized())
	# Visual: green earth-shockwave ring.
	var parent: Node = get_parent()
	if parent:
		var ring := Line2D.new()
		ring.width = 3.0
		ring.default_color = Color(0.20, 0.65, 0.30, 0.80)
		ring.z_index = 9
		var n: int = 20
		for i in range(n + 1):
			var a: float = TAU * float(i) / float(n)
			ring.add_point(origin + Vector2(cos(a), sin(a)) * 12.0)
		parent.add_child(ring)
		var tw: Tween = ring.create_tween()
		tw.tween_property(ring, "scale", Vector2(radius / 12.0, radius / 12.0), 0.18)
		tw.parallel().tween_property(ring, "modulate:a", 0.0, 0.18)
		tw.tween_callback(ring.queue_free)
	FX.spawn_burst_particles(origin, Color(0.20, 0.65, 0.30, 0.9), 10)


func _apply_vinewrap(origin: Vector2, radius: float) -> void:
	# Grape Vinewrap: root all enemies in radius for 2s (Grape identity root).
	var hit: int = 0
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or (e.has_method("is_alive") and not e.is_alive()):
			continue
		if origin.distance_to(e.global_position) > radius:
			continue
		var ts: Variant = e.get("status") if e.has_method("get") else null
		if ts != null and ts.has_method("apply"):
			ts.apply("root", 2.0, 1)
			hit += 1
	if hit > 0:
		FX.spawn_burst_particles(origin, Color(0.50, 0.20, 0.75, 0.9), 10)
		FX.play_sound("vinewrap_proc", 0.80)


func _spawn_ground_pound(origin: Vector2, radius: float) -> void:
	# Potato Spud Stomp Y-finisher: Ground Pound knocks down enemies in radius.
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or (e.has_method("is_alive") and not e.is_alive()):
			continue
		if origin.distance_to(e.global_position) > radius:
			continue
		var ts: Variant = e.get("status") if e.has_method("get") else null
		if ts != null and ts.has_method("apply"):
			ts.apply("stagger", 0.7, 1)   # knockdown proxy via stagger
	# Run 59 — drop a short-lived earth patch so the impact area is visible (and
	# applies a residual Cracked Soil tick to anyone walking through, feeding
	# the Earthbind threshold on X follow-ups).
	_spawn_status_zone(origin, radius, 2.0, "cracked_soil", 1, Color(0.55, 0.40, 0.20, 0.55))
	# Visual: brown expanding ring + dust burst.
	FX.spawn_burst_particles(origin, Color(0.55, 0.40, 0.20, 0.9), 14)
	FX.screen_shake(FX.SHAKE_MEDIUM, FX.SHAKE_DUR_SHORT)
	FX.play_sound("ground_pound", 0.9)


# -------------------------------------------------------
# Slot boon world-effect helpers
# -------------------------------------------------------

# Generic zone node: a glowing circle that applies a status to enemies inside per-second.
func _spawn_status_zone(pos: Vector2, radius: float, duration: float, status_id: String, stacks: int, col: Color) -> void:
	var parent: Node = get_parent()
	if parent == null:
		return
	var zone := Node2D.new()
	zone.global_position = pos
	zone.z_index = 4
	parent.add_child(zone)
	# Run 61 — AI helper trap-avoidance: tag every spawned status puddle as a
	# hazard zone and stash radius via meta so partner AI heuristics can
	# steer around it (universal "avoid traps and environmental hazards" rule).
	zone.add_to_group("hazard_zone")
	zone.set_meta("hazard_radius", radius)
	zone.set_meta("hazard_status", status_id)
	# Run 59 — visible puddle. Filled Polygon2D under a brighter ring outline so
	# the player can SEE the active area, not just its perimeter. The fill alpha
	# is ~35% of the ring's alpha (subtle enough to read as a stain, opaque
	# enough to spot from across the room). A gentle pulse over the duration
	# tells the eye the zone is "alive."
	var fill := Polygon2D.new()
	var fpts: PackedVector2Array = PackedVector2Array()
	var fn: int = 28
	for fi in range(fn):
		var fa: float = TAU * float(fi) / float(fn)
		fpts.append(Vector2(cos(fa), sin(fa)) * radius)
	fill.polygon = fpts
	var fill_col: Color = col
	fill_col.a = col.a * 0.40
	fill.color = fill_col
	fill.z_index = -1   # sits below the ring on the zone node
	zone.add_child(fill)
	# Gentle scale pulse + alpha breath so the puddle reads as active.
	var pulse_tw: Tween = fill.create_tween()
	pulse_tw.set_loops()
	pulse_tw.tween_property(fill, "scale", Vector2(1.06, 1.06), 0.55) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	pulse_tw.tween_property(fill, "scale", Vector2(0.96, 0.96), 0.55) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	# Brighter ring on top for the silhouette.
	var ring := Line2D.new()
	ring.width = 2.5
	ring.default_color = col
	var n: int = 24
	for i in range(n + 1):
		var a: float = TAU * float(i) / float(n)
		ring.add_point(Vector2(cos(a), sin(a)) * radius)
	zone.add_child(ring)
	# Tick logic via a repeating timer.
	var tick_count: int = int(duration)
	var timer_node := Timer.new()
	timer_node.wait_time = 1.0
	timer_node.autostart = true
	zone.add_child(timer_node)
	var ticks_done: int = 0
	timer_node.timeout.connect(func():
		ticks_done += 1
		for e in get_tree().get_nodes_in_group("enemy"):
			if not is_instance_valid(e) or (e.has_method("is_alive") and not e.is_alive()):
				continue
			if pos.distance_to(e.global_position) > radius:
				continue
			var ts: Variant = e.get("status") if e.has_method("get") else null
			if ts != null and ts.has_method("apply"):
				ts.apply(status_id, 3.0, stacks)
		# Run 27b — Smokestack duo arm 1 (Coconut+Onion): standing inside any
		# stink (poison) cloud generates 1 overshield every 4s (only when the
		# hero holds none — "max 1 stored from this source").
		if status_id == "poison" and ticks_done % 4 == 0 and RunState.is_duo_active("coconut_onion"):
			for grp in ["player", "bea"]:
				for pl in get_tree().get_nodes_in_group(grp):
					if not is_instance_valid(pl):
						continue
					if pos.distance_to(pl.global_position) > radius:
						continue
					if "overshield_charges" in pl and pl.overshield_charges < 1 \
					and pl.has_method("grant_overshield_external"):
						pl.grant_overshield_external(1)
		if ticks_done >= tick_count:
			zone.queue_free()
	)
	# Fade ring + fill together over duration so the puddle dissolves cleanly.
	var tw: Tween = ring.create_tween()
	tw.tween_property(ring, "modulate:a", 0.0, duration)
	var ftw: Tween = fill.create_tween()
	ftw.tween_property(fill, "modulate:a", 0.0, duration)


# --- Pepper Fire Trail ---
func _spawn_fire_trail() -> void:
	# Spawn a short-lived fire zone along the dash path (simplified: zone at start pos).
	_spawn_status_zone(global_position, 32.0, 2.0, "burning", 1, Color(0.95, 0.35, 0.10, 0.65))
	FX.spawn_hit_particles(global_position, Color(1.0, 0.40, 0.10, 0.85), 8)


# --- Pepper Inferno Charge: scorched patch ---
func _spawn_fire_zone(pos: Vector2, radius: float, duration: float) -> void:
	_spawn_status_zone(pos, radius, duration, "burning", 1, Color(0.95, 0.40, 0.10, 0.55))
	FX.spawn_burst_particles(pos, Color(1.0, 0.50, 0.10, 0.9), 12)


# --- Banana Slick Trail: drop banana-peel caltrops at dash start + end ---
func _spawn_slick_trail_caltrops() -> void:
	# Applies Slippery (or Sparked in Greased Lightning mode) to enemies near the dash origin.
	var slip_id: String = "sparked" if RunState.greased_lightning_mode else "slippery"
	var col: Color = Color(0.85, 0.85, 0.20, 0.80) if not RunState.greased_lightning_mode else Color(0.85, 0.90, 0.30, 0.85)
	_spawn_status_zone(global_position, 40.0, 3.0, slip_id, 1, col)
	FX.spawn_hit_particles(global_position, col, 6)
	# Run 27e — Slapstink/Slapshock duo (Banana+Onion): every Banana hazard
	# leaves a paired poison cloud around it.
	if RunState.is_duo_active("banana_onion"):
		_spawn_status_zone(global_position, 48.0, 3.0, "poison", 1, Color(0.60, 0.85, 0.40, 0.35))


# --- Onion Gas Bookend: stink cloud ---
func _spawn_gas_bookend(pos: Vector2) -> void:
	_spawn_status_zone(pos, 64.0, 4.0, "poison", 1, Color(0.60, 0.85, 0.30, 0.50))
	FX.spawn_hit_particles(pos, Color(0.55, 0.85, 0.30, 0.80), 8)
	# Run 27 — Tear Gas duo (Onion+Pepper): Onion zones also apply Burn.
	if RunState.is_duo_active("onion_pepper"):
		_spawn_status_zone(pos, 64.0, 4.0, "burning", 1, Color(0.95, 0.45, 0.15, 0.30))


# --- Watermelon Hydro Slide: puddle at dash landing ---
func _spawn_hydro_slide_puddle(pos: Vector2) -> void:
	var wet_id: String = "chilled" if RunState.melon_gelato_mode else "wet"
	var col: Color = Color(0.55, 0.85, 0.95, 0.50) if RunState.melon_gelato_mode else Color(0.30, 0.70, 0.95, 0.50)
	# Run 128 — landing SPLASH (doc §8.7): small AoE damage + 1 stack on
	# impact, in addition to the lingering puddle.
	for _hs_e in get_tree().get_nodes_in_group("enemy"):
		if is_instance_valid(_hs_e) and _hs_e is Node2D \
		and pos.distance_to(_hs_e.global_position) < 96.0:
			if _hs_e.has_method("take_damage"):
				_hs_e.take_damage(4, (_hs_e.global_position - pos).normalized() * 0.4)
			var _hs_ts: Variant = _hs_e.get("status") if _hs_e.has_method("get") else null
			if _hs_ts != null and _hs_ts.has_method("apply"):
				_hs_ts.apply(wet_id, 4.0, 1)
	_spawn_status_zone(pos, 64.0, 3.0, wet_id, 1, col)
	FX.spawn_hit_particles(pos, col, 8)
	# Run 27b — Acid Puddle/Mist duo (Onion+Watermelon): Watermelon zones
	# become hybrid poison zones (+1 Poison/sec inside).
	if RunState.is_duo_active("onion_watermelon"):
		_spawn_status_zone(pos, 64.0, 3.0, "poison", 1, Color(0.60, 0.85, 0.40, 0.30))


# Run 150b — Spring Tide duo (Apple+Watermelon): spring puddle on charge
# release. Enemies inside soak 1 stack/sec (standard status zone); heroes
# standing in it regen SPRING_TIDE_REGEN_HP per second for the duration.
# Bea's charge releases route here via _bea_apply_family_charge_releases.
func _spawn_spring_tide_puddle(pos: Vector2) -> void:
	var wet_id: String = "chilled" if RunState.melon_gelato_mode else "wet"
	_spawn_status_zone(pos, RunState.SPRING_TIDE_RADIUS, RunState.SPRING_TIDE_DURATION,
		wet_id, 1, Color(0.45, 0.90, 0.75, 0.50))
	FX.spawn_hit_particles(pos, Color(0.45, 0.90, 0.75, 0.9), 10)
	_spring_tide_regen_loop(pos)


func _spring_tide_regen_loop(pos: Vector2) -> void:
	# Coroutine: 1 HP/sec to any hero inside the puddle while it lives.
	for i in range(int(RunState.SPRING_TIDE_DURATION)):
		await get_tree().create_timer(1.0).timeout
		if not is_instance_valid(self) or not is_inside_tree():
			return
		for h in get_tree().get_nodes_in_group("player"):
			if not is_instance_valid(h) or not (h is Node2D):
				continue
			if (h as Node2D).global_position.distance_to(pos) <= RunState.SPRING_TIDE_RADIUS \
			and h.has_method("heal_external"):
				h.heal_external(RunState.SPRING_TIDE_REGEN_HP)


# --- Broccoli Bull Rush: contact damage to enemies crossed during dash ---
func _apply_slip_stream() -> void:
	# Slip Stream: 0.5s extra i-frames + greased field on nearby enemies.
	iframe_timer = max(iframe_timer, 0.5)
	is_invulnerable = true
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e):
			continue
		if global_position.distance_to(e.global_position) < 80.0:
			if e.get("status") != null and e.status.has_method("apply"):
				var slip_id: String = "bolted" if RunState.greased_lightning_mode else "greased"
				e.status.apply(slip_id, 3.0, 1)
	FX.spawn_burst_particles(global_position, Color(1.0, 0.95, 0.30, 0.85), 10)


func _apply_bull_rush_damage() -> void:
	# Deals flat contact damage to any enemy near Shino at dash end.
	var radius: float = 40.0
	var dmg: int = int(round(20.0 * RunState.get_char_damage_mult("shino")))   # Run 139 — per-char
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or (e.has_method("is_alive") and not e.is_alive()):
			continue
		if global_position.distance_to(e.global_position) > radius:
			continue
		if e.has_method("take_damage"):
			e.take_damage(dmg, (e.global_position - global_position).normalized())
	FX.spawn_burst_particles(global_position, Color(0.20, 0.65, 0.30, 0.85), 10)


# --- Coconut Coco-Slam: ministun + Vulnerable on charge release ---
func _apply_coco_slam() -> void:
	var radius: float = 80.0
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or (e.has_method("is_alive") and not e.is_alive()):
			continue
		if global_position.distance_to(e.global_position) > radius:
			continue
		var ts: Variant = e.get("status") if e.has_method("get") else null
		if ts != null and ts.has_method("apply"):
			ts.apply("bash", 0.4, 1)      # mini-bash (~0.4s stun)
			ts.apply("vulnerable", 3.0, 1)
	FX.spawn_burst_particles(global_position, Color(0.72, 0.50, 0.22, 0.9), 12)
	FX.play_sound("coco_slam", 0.85)


# --- Potato Tremor Walk: Cracked Soil trail while moving, pulse while Ingrained ---
# Run 60 audit fix: cadence WAS 2s while moving → trail was invisible (one patch
# every 2 seconds at running speed leaves ~480px gaps — reads as nothing). Now
# 0.5s cadence while moving with smaller radius reads as a continuous cracked
# trail behind the player. Color/alpha bumped for readability against dream
# floor palettes. Ingrained pulse stays at 3s with a wider radius for the
# "stand-still earthquake" feel. Both Shino and Bea now use this pattern (Bea
# wired in BeaAI.gd._tick_tremor_walk).
func _tick_tremor_walk(delta: float) -> void:
	if not RunState.shino_has("tremor_walk"):
		_tremor_walk_last_pos = global_position
		return
	var moving: bool = global_position.distance_to(_tremor_walk_last_pos) >= 2.0
	_tremor_walk_last_pos = global_position
	if _tremor_walk_timer > 0.0:
		_tremor_walk_timer -= delta
		return
	var ingrained: bool = _ingrained_time >= RunState.INGRAINED_THRESHOLD
	var radius: float = 40.0
	var dur: float = 2.5
	if moving:
		_tremor_walk_timer = 0.5
	elif ingrained:
		_tremor_walk_timer = 3.0
		radius = 64.0
		dur = 3.5
	else:
		return
	# Deeper brown, alpha 0.75 (fill ends up ~0.30 after the spawner's 0.40×
	# multiplier — clearly readable as a cracked dirt patch over any biome floor).
	_spawn_status_zone(global_position, radius, dur, "cracked_soil", 1, Color(0.48, 0.30, 0.12, 0.75))
	FX.spawn_hit_particles(global_position, Color(0.55, 0.40, 0.20, 0.9), 4)


# --- Run 60: Scorched Earth (Pepper+Potato duo) ---
# Persistent lava patch follows the hero. Drops paired Burning + Cracked Soil
# zones underfoot every ~1s. Radius grows while Ingrained (matches the canonical
# spec — "stand and burn" turret-mage build payoff). Pairs visually with the
# Tremor Walk trail when both are owned (cracked floor + lava ring).
func _tick_scorched_earth(delta: float) -> void:
	if not RunState.is_duo_active("pepper_potato"):
		return
	if _scorched_earth_timer > 0.0:
		_scorched_earth_timer -= delta
		return
	_scorched_earth_timer = 1.0
	var ingrained: bool = _ingrained_time >= RunState.INGRAINED_THRESHOLD
	# Base 80px; grows up to 144px after 3s Ingrained (spec: 3m base / 6m max).
	var radius: float = 80.0
	if ingrained:
		var growth: float = clamp(_ingrained_time - RunState.INGRAINED_THRESHOLD, 0.0, 3.0)
		radius = 80.0 + 64.0 * (growth / 3.0)
	# Two overlapping zones — one for Burn DoT visual (orange-red), one for
	# Cracked Soil (deeper brown). The fill polygons blend visually into a
	# "scorched ground" stain.
	_spawn_status_zone(global_position, radius, 2.0, "burning",      1, Color(0.95, 0.30, 0.05, 0.80))
	_spawn_status_zone(global_position, radius, 2.0, "cracked_soil", 1, Color(0.40, 0.18, 0.05, 0.70))
	FX.spawn_hit_particles(global_position, Color(1.00, 0.45, 0.10, 0.95), 5)


# --- Onion Reek Charge: 360° gas burst + stink cloud on charge release ---
func _apply_reek_charge() -> void:
	if RunState.shino_has("corrupt_onion"):
		return
	var radius: float = 96.0
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or (e.has_method("is_alive") and not e.is_alive()):
			continue
		if global_position.distance_to(e.global_position) > radius:
			continue
		var ts: Variant = e.get("status") if e.has_method("get") else null
		if ts != null and ts.has_method("apply"):
			ts.apply("poison", 5.0, 2)
	# Lingering cloud at the player's position (reuses the gas-bookend zone).
	_spawn_gas_bookend(global_position)
	FX.spawn_burst_particles(global_position, Color(0.60, 0.85, 0.30, 0.9), 16)


# --- Potato Quake Charge: ring quake + Cracked Soil AoE ---
func _apply_quake_charge() -> void:
	var radius: float = RunState.QUAKE_CHARGE_RADIUS
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or (e.has_method("is_alive") and not e.is_alive()):
			continue
		if global_position.distance_to(e.global_position) > radius:
			continue
		var ts: Variant = e.get("status") if e.has_method("get") else null
		if ts != null and ts.has_method("apply"):
			ts.apply("stagger", 0.7, 1)    # knockdown
			ts.apply("cracked_soil", 4.0, 1)
	# Run 59 — lingering cracked-soil patch the ring leaves behind. Without this
	# the AoE was visually invisible to the player — only the brown burst spray
	# remained for one frame.
	_spawn_status_zone(global_position, radius, 3.0, "cracked_soil", 1, Color(0.55, 0.40, 0.20, 0.55))
	FX.spawn_burst_particles(global_position, Color(0.55, 0.40, 0.20, 0.9), 16)
	FX.screen_shake(FX.SHAKE_HEAVY, FX.SHAKE_DUR_SHORT)
	FX.play_sound("ground_pound", 1.0)


# -------------------------------------------------------
# Tuber Burrow (Potato B — GDD §8.8)
# -------------------------------------------------------

## Enter burrow state. Called when dash ends and button is still held.
func _enter_burrow() -> void:
	state = State.BURROWING
	burrow_timer = BURROW_MAX_DURATION
	is_invulnerable = true
	iframe_timer = 0.0  # burrow manages its own invuln; clear normal iframe so it doesn't fight
	velocity = Vector2.ZERO

	# Hide player sprite and show the dirt-mound placeholder.
	if _sprite:
		_sprite.visible = false
	if body_anim and body_anim.has_method("set_visible"):
		body_anim.set_visible(false)

	# Spawn / reuse the mound node (placeholder drawn by BurrowMound.gd).
	if _burrow_mound == null:
		var mound_script: GDScript = load("res://scripts/BurrowMound.gd")
		if mound_script:
			_burrow_mound = mound_script.new()
		else:
			_burrow_mound = Node2D.new()
		add_child(_burrow_mound)
	_burrow_mound.visible = true

	# Dive particles — dirt scattering downward.
	FX.spawn_burst_particles(global_position, Color(0.50, 0.35, 0.18, 0.95), 18)
	FX.screen_shake(FX.SHAKE_LIGHT, 0.15)
	FX.play_sound("ground_pound", 0.7)


## Per-physics tick while underground. Called from _tick_timers when BURROWING.
func _tick_burrow(delta: float) -> void:
	burrow_timer -= delta

	# Free movement underground at reduced speed.
	var input_vec: Vector2 = Vector2(
		_move_axis().x,
		_move_axis().y
	)
	if input_vec.length() > 1.0:
		input_vec = input_vec.normalized()
	if input_vec.length() > 0.1:
		facing = input_vec.normalized()
	velocity = input_vec * move_speed * BURROW_MOVE_SPEED_MULT

	# Dirt mound follows player position (mound node is a child, so offset is local).
	if _burrow_mound != null:
		# Draw a small brown bump above the player origin — hand-drawn each frame.
		_burrow_mound.queue_redraw()

	# Periodic mound particles to show movement.
	# Use a simple modulo on timer instead of another variable.
	var phase: float = fmod(burrow_timer, 0.35)
	if phase < delta and input_vec.length() > 0.1:
		FX.spawn_hit_particles(global_position, Color(0.48, 0.33, 0.16, 0.80), 4)

	# Emerge conditions: button released OR max duration elapsed.
	if not _act_p("dash") or burrow_timer <= 0.0:
		_emerge()


## Rise from underground: AoE hit + earth effects + visuals.
func _emerge() -> void:
	state = State.IDLE
	is_invulnerable = false
	burrow_cd_timer = BURROW_INTERNAL_CD

	# Restore player sprite.
	if _sprite:
		_sprite.visible = true
	# body_anim (legacy stick-figure) stays hidden — ShinoSprite is the visual.
	if _burrow_mound != null:
		_burrow_mound.visible = false

	# Rise-attack AoE: hit all enemies within BURROW_RISE_RADIUS.
	var base_dmg: int = int(round(float(MELEE_X_DAMAGE) * BURROW_RISE_DAMAGE_MULT * RunState.get_char_damage_mult("shino")))   # Run 139
	# Potato earth damage bonus: +15% on Y attacks from Spud Stomp; rise is similarly earth-flavoured.
	# We add a flat 20% earth bonus on top of the multiplier (matches Potato's earth identity).
	if RunState.char_family_count("shino", "Potato") > 0:
		base_dmg = int(float(base_dmg) * 1.20)

	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or (e.has_method("is_alive") and not e.is_alive()):
			continue
		var dist: float = global_position.distance_to(e.global_position)
		if dist > BURROW_RISE_RADIUS:
			continue

		# Damage.
		var kb_dir: Vector2 = (e.global_position - global_position).normalized()
		if e.has_method("take_damage"):
			e.take_damage(base_dmg, kb_dir)

		# Earth status effects: Cracked Soil + stagger (knockup stand-in).
		var ts: Variant = e.get("status") if e.has_method("get") else null
		if ts != null and ts.has_method("apply"):
			# 1 Cracked Soil stack (feeds Earthbind chain on X follow-up).
			ts.apply("cracked_soil", 4.0, 1)
			# Stagger as knockup (~0.5s air-stagger — same as Earthshaker duo).
			ts.apply("stagger", 0.5, 1)
			# Earthbind check: if target hits 3 stacks, trigger root.
			if ts.get_stacks("cracked_soil") >= 3:
				# Run 27f — Petrify (Potato Legendary): Earthbind upgrades to a
				# 3s full Stun + Vulnerable (total action lock + damage amp).
				if RunState.shino_has("petrify") or RunState.bea_has("petrify"):
					ts.apply("bash", 3.0, 1)
					ts.apply("vulnerable", 3.0, 2)
				else:
					ts.apply("root", 1.5, 1)
				ts.remove("cracked_soil")
				FX.spawn_burst_particles(e.global_position, Color(0.45, 0.30, 0.15, 0.90), 10)

	# Rise visuals: earth spike burst + screen shake.
	FX.spawn_burst_particles(global_position, Color(0.52, 0.38, 0.18, 1.0), 24)
	# Extra upward-flung dirt spray using hit_particles offset above origin.
	FX.spawn_hit_particles(global_position + Vector2(0, -20), Color(0.60, 0.45, 0.22, 0.9), 12)
	FX.screen_shake(4.0, 0.20)


# -------------------------------------------------------
# Run 150b — Vine Lash (Grape B, wired per Bruno's ruling)
# -------------------------------------------------------
# Up to VINE_LASH_COUNT vines whip out at the nearest enemies inside a
# forward cone. Damage-only (no pull / root); each landed vine routes
# through the normal hit pipeline (chi + combo — Grape's identity).
func _fire_vine_lash() -> void:
	var targets: Array = []
	var cone_dot: float = cos(deg_to_rad(RunState.VINE_LASH_CONE_DEG * 0.5))
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or not (e is Node2D) or not e.has_method("take_damage"):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		var off: Vector2 = (e as Node2D).global_position - global_position
		var d: float = off.length()
		if d > RunState.VINE_LASH_RANGE or d < 1.0:
			continue
		if facing.dot(off / d) < cone_dot:
			continue
		targets.append(e)
	targets.sort_custom(func(a, b):
		return global_position.distance_squared_to(a.global_position) \
			 < global_position.distance_squared_to(b.global_position))
	var vine_col := Color(0.45, 0.75, 0.30, 0.95)   # leafy grape-vine green
	var lashes: int = 0
	for e2 in targets:
		if lashes >= RunState.VINE_LASH_COUNT:
			break
		lashes += 1
		var dmg: int = _scale_damage(RunState.VINE_LASH_DAMAGE, false, false, e2, "ranged")
		e2.set_meta("last_damager", "shino")
		e2.take_damage(dmg, ((e2 as Node2D).global_position - global_position).normalized() * 0.25)
		_spawn_vine_visual(global_position, (e2 as Node2D).global_position, vine_col)
		FX.spawn_hit_particles((e2 as Node2D).global_position, vine_col, 5)
		_on_hit_connected(dmg)
	# Whiff vines: fan the unused lashes so the boon always reads on screen.
	if lashes < RunState.VINE_LASH_COUNT:
		var half_fan: float = deg_to_rad(RunState.VINE_LASH_CONE_DEG * 0.5)
		for i in range(RunState.VINE_LASH_COUNT - lashes):
			var t: float = 0.0 if RunState.VINE_LASH_COUNT <= 1 else \
				(float(i + lashes) / float(RunState.VINE_LASH_COUNT - 1)) * 2.0 - 1.0
			var vdir: Vector2 = facing.rotated(t * half_fan)
			_spawn_vine_visual(global_position, global_position + vdir * RunState.VINE_LASH_RANGE * 0.8, vine_col)
	FX.play_sound("kunai_hit", 0.5)


# Quick whip-line visual: a slightly bowed Line2D that fades out fast.
# _spawn_vine_visual moved to HeroBase (Batch 6).


# --- Burrow mound draw helper ---
# Attached to the _burrow_mound Node2D so it draws a simple dirt bump each frame.
# Wired up in _enter_burrow via set_script; using a lambda approach instead since
# GDScript doesn't support inline _draw overrides — we draw directly via CanvasItem API.
# Placeholder: the mound is drawn as a squashed ellipse tinted earthy brown.


# --- Watermelon Flood Charge: 3 Soaked stacks to nearby enemies ---
func _apply_flood_charge() -> void:
	var radius: float = 96.0
	var wet_id: String = "chilled" if RunState.melon_gelato_mode else "wet"
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or (e.has_method("is_alive") and not e.is_alive()):
			continue
		if global_position.distance_to(e.global_position) > radius:
			continue
		var ts: Variant = e.get("status") if e.has_method("get") else null
		if ts != null and ts.has_method("apply"):
			ts.apply(wet_id, 4.0, 3)
			# Run 128 — Geyser Charge rework (doc §8.7): the water column
			# LAUNCHES enemies — brief air-stun instead of the old slow.
			ts.apply("stagger", 0.6, 1)
			FX.spawn_hit_particles(e.global_position + Vector2(0, -24), Color(0.45, 0.80, 0.98, 0.9), 6)
	var col: Color = Color(0.55, 0.85, 0.95, 0.8) if RunState.melon_gelato_mode else Color(0.30, 0.70, 0.95, 0.8)
	# Run 59 — lingering water/ice zone the charge leaves behind so the AoE area
	# stays visible after the burst. Same color family as the burst.
	var zone_col: Color = Color(col.r, col.g, col.b, 0.55)
	_spawn_status_zone(global_position, radius, 3.0, wet_id, 1, zone_col)
	FX.spawn_burst_particles(global_position, col, 14)


# --- Banana Storm Charge: knockdown or chain-3 electrify ---
func _apply_storm_charge() -> void:
	var radius: float = 80.0
	var hit: int = 0
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or (e.has_method("is_alive") and not e.is_alive()):
			continue
		if global_position.distance_to(e.global_position) > radius:
			continue
		var ts: Variant = e.get("status") if e.has_method("get") else null
		if ts != null and ts.has_method("apply"):
			if RunState.greased_lightning_mode:
				ts.apply("bolted", 5.0, 1)
				ts.apply("shocked", 5.0, 1)
			else:
				ts.apply("stagger", 0.8, 1)   # wind-burst knockdown
		hit += 1
	var col: Color = Color(0.60, 0.80, 1.0, 0.85) if RunState.greased_lightning_mode else Color(0.95, 0.90, 0.50, 0.85)
	if hit > 0:
		FX.spawn_burst_particles(global_position, col, 14)


# Run 130 — Marksman's Eye (Carrot Legendary): re-mark the highest-HP enemy.
func _marksman_retarget() -> void:
	if _marksman_target != null and is_instance_valid(_marksman_target):
		if _marksman_target.has_meta("me_marked"):
			_marksman_target.remove_meta("me_marked")
		var _old_tag: Node = _marksman_target.get_node_or_null("MEMark")
		if _old_tag != null:
			_old_tag.queue_free()
	_marksman_target = null
	var best: Node = null
	var best_hp: int = -1
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or (e.has_method("is_alive") and not e.is_alive()):
			continue
		var hp: int = int(e.get("current_hp")) if "current_hp" in e else 0
		if hp > best_hp:
			best_hp = hp
			best = e
	if best == null:
		return
	_marksman_target = best
	best.set_meta("me_marked", true)
	var tag := Label.new()
	tag.name = "MEMark"
	tag.text = "◎"
	tag.add_theme_font_size_override("font_size", 20)
	tag.add_theme_color_override("font_color", Color(1.0, 0.35, 0.15))
	tag.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	tag.add_theme_constant_override("outline_size", 4)
	tag.position = Vector2(-9, -72)
	tag.z_index = 50
	best.add_child(tag)


# Run 130 — Slapstick (Banana Legendary): hazard at the dash endpoint.
func _spawn_slapstick_drop(pos: Vector2) -> void:
	if RunState.greased_lightning_mode:
		# "Bolt Drop": immediate ~2m AoE strike + Bolted, strike-and-gone.
		for e in get_tree().get_nodes_in_group("enemy"):
			if not is_instance_valid(e) or not (e is Node2D):
				continue
			if pos.distance_to(e.global_position) > 96.0:
				continue
			var e_max: int = int(e.get("max_hp")) if "max_hp" in e else 40
			if e.has_method("take_damage"):
				e.take_damage(max(1, int(round(e_max * 0.25))), Vector2.ZERO)
			var b_ts: Variant = e.get("status") if e.has_method("get") else null
			if b_ts != null and b_ts.has_method("apply"):
				b_ts.apply("bolted", 5.0, 1)
		FX.spawn_burst_particles(pos, Color(0.70, 0.85, 1.0, 0.95), 16)
		FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_SHORT)
		return
	# "Banana Drop": giant banana lies for 8s; first enemy to touch it slips
	# hard + takes ~30% max HP. Placeholder crescent visual.
	var vis := Polygon2D.new()
	vis.polygon = PackedVector2Array([Vector2(-10, 2), Vector2(-4, -4),
		Vector2(4, -5), Vector2(10, 0), Vector2(4, 4), Vector2(-4, 5)])
	vis.color = Color(0.95, 0.85, 0.20)
	vis.z_index = 1
	var parent: Node = get_tree().current_scene
	if parent == null:
		return
	parent.add_child(vis)
	vis.global_position = pos
	_slapstick_bananas.append({"pos": pos, "until": Time.get_ticks_msec() + 8000, "node": vis})


func _tick_slapstick_bananas() -> void:
	var now: int = Time.get_ticks_msec()
	for i in range(_slapstick_bananas.size() - 1, -1, -1):
		var b: Dictionary = _slapstick_bananas[i]
		var expired: bool = now > int(b["until"])
		var consumed: bool = false
		if not expired:
			for e in get_tree().get_nodes_in_group("enemy"):
				if not is_instance_valid(e) or not (e is Node2D):
					continue
				if (b["pos"] as Vector2).distance_to(e.global_position) <= 48.0:
					var e_max: int = int(e.get("max_hp")) if "max_hp" in e else 40
					if e.has_method("take_damage"):
						e.take_damage(max(1, int(round(e_max * 0.30))), Vector2.ZERO)
					var s_ts: Variant = e.get("status") if e.has_method("get") else null
					if s_ts != null and s_ts.has_method("apply"):
						s_ts.apply("stagger", 0.6, 1)
						s_ts.apply("slippery", 3.0, 1)
					FX.spawn_burst_particles(b["pos"], Color(0.95, 0.85, 0.20, 0.95), 14)
					FX.play_sound("bash_proc", 0.8)
					consumed = true
					break
		if expired or consumed:
			var n: Variant = b.get("node")
			if n != null and is_instance_valid(n):
				n.queue_free()
			_slapstick_bananas.remove_at(i)


# --- Grape Bunch Burst: extra hits on charge attacks (wired in flurry tick) ---
# (Bunch Burst ticks in _deal_flurry_tick via RunState.shino_has("bunch_burst") check)

# --- Evergreen Step (Apple B) active flag ---
var _evergreen_step_active: bool = false
var _evergreen_step_cd_timer: float = 0.0

func _on_enemy_killed() -> void:
	# Called whenever Shino lands a killing blow (from any hit path).
	# Battle Shell: KO grants 1 overshield charge for BATTLE_SHELL_DURATION seconds.
	if RunState.shino_has("battle_shell"):
		grant_overshield_external(1)
		# The "3s duration" is handled by treating overshield_charges as a counter
		# (they already expire via dash ICD). Mark a timer so we know to revoke it.
		_battle_shell_timer = RunState.BATTLE_SHELL_DURATION
	# Rotten Core (Onion): if the killed enemy was poisoned, burst a stink cloud.
	if RunState.shino_has("rotten_core"):
		_spawn_rotten_core_burst(_last_killed_enemy_pos)



func _spawn_rotten_core_burst(pos: Vector2) -> void:
	if not _last_killed_enemy_was_poisoned:
		return
	# Rotten Core: poisoned enemy death bursts a stink cloud (spec §8.9 passive 2).
	# Run 59 — the "puff" was just particles; now drops a real lingering zone so
	# the cloud actually persists and ticks poison on anyone walking through.
	_spawn_status_zone(pos, 60.0, 3.0, "poison", 1, Color(0.50, 0.85, 0.25, 0.55))
	FX.spawn_burst_particles(pos, Color(0.50, 0.85, 0.25, 0.9), 14)
	# Initial 2-stack spread (the death-burst itself) — distinct from the zone tick.
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e):
			continue
		if pos.distance_to(e.global_position) < 120.0:
			if e.get("status") != null and e.status.has_method("apply"):
				e.status.apply("poison", 4.0, 2)
			FX.spawn_hit_particles(e.global_position, Color(0.50, 0.85, 0.25, 0.6), 4)

func _reset_combo_counter() -> void:
	# Called when grace timer expires — hit streak broken
	combo_count = 0
	RunState.set_combo("shino", 0)   # Run 60 — mirror reset
	emit_signal("combo_count_changed", combo_count)


func _apply_hit_pause(duration: float = HIT_PAUSE) -> void:
	Engine.time_scale = 0.05
	await get_tree().create_timer(duration, true, false, true).timeout
	Engine.time_scale = 1.0


# -------------------------------------------------------
# Finisher impact — radial ring + enemy flash + burst
# -------------------------------------------------------
# Called on Y4 (Spinning Uppercut) and X3 (Side Kick) finishers.
# Designed to feel powerful without causing disorientation:
#   • Expanding white ring (reads as "shockwave" — classic beat-em-up feel)
#   • Brief white-flash on the target enemy (confirms the hit landed)
#   • Burst particles: Y4 = golden-orange upward burst; X3 = blue-violet sideways burst
#   • Light screen shake (shorter than a charge attack shake)
#   • Extended hit-pause via HIT_PAUSE_FINISHER (already called by caller)
func _spawn_finisher_impact(pos: Vector2, is_uppercut: bool) -> void:
	# --- Radial expanding ring ---
	# A Line2D circle that expands and fades over 0.22s.
	var parent: Node = get_parent()
	if parent:
		var ring := Line2D.new()
		ring.width = 3.5
		ring.default_color = Color(1.0, 1.0, 1.0, 0.90)
		ring.z_index = 12
		var pts: PackedVector2Array = []
		var n := 24
		var r: float = 18.0   # starts small — expands via tween
		for i in range(n + 1):
			var a: float = TAU * float(i) / float(n)
			pts.append(Vector2(cos(a), sin(a)) * r)   # local offsets only
		ring.points = pts
		ring.position = pos   # center at impact point so tween scales from here
		parent.add_child(ring)
		var tw: Tween = ring.create_tween()
		tw.tween_property(ring, "scale", Vector2(3.5, 3.5), 0.22)
		tw.parallel().tween_property(ring, "modulate:a", 0.0, 0.22)
		tw.tween_callback(ring.queue_free)

	# --- Enemy white-flash (modulate to white and back) ---
	# Find enemies near impact_pos that are alive (the one we just hit).
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		if pos.distance_to(e.global_position) > 48.0:
			continue
		# Flash white then restore.
		var orig_mod: Color = (e as Node2D).modulate if e is Node2D else Color.WHITE
		if e is Node2D:
			(e as Node2D).modulate = Color(1.8, 1.8, 1.8, 1.0)
			var etw: Tween = (e as Node2D).create_tween()
			etw.tween_property(e, "modulate", orig_mod, 0.14)

	# --- Burst particles (directional — uppercut = upward, side kick = horizontal) ---
	var burst_col: Color
	var burst_dir_offset: Vector2
	if is_uppercut:
		burst_col = Color(1.0, 0.85, 0.25, 1.0)   # gold — Shino's Y identity
		burst_dir_offset = Vector2(0, -24)
	else:
		burst_col = Color(0.70, 0.55, 1.0, 1.0)   # violet — X kick identity
		burst_dir_offset = facing.normalized() * 20.0
	FX.spawn_burst_particles(pos + burst_dir_offset, burst_col, 16)
	FX.spawn_hit_particles(pos, Color(1.0, 1.0, 1.0, 0.9), 8)

	# --- Light screen shake (noticeable but not nauseating) ---
	FX.screen_shake(FX.SHAKE_MEDIUM, FX.SHAKE_DUR_SHORT)


# -------------------------------------------------------
# Taking damage (called by enemies / hazards)
# -------------------------------------------------------
# Run 44 — hit knockback impulse (_hit_knockback_vel) moved to HeroBase (Batch 4).
# take_damage moved to HeroBase (Batch 4). Per-hero bits routed via child overrides
# (_gain_chi_from_damage_taken, _spawn_rampart_wall_routed, _hurt_* FX vars,
# _is_state_dead/downed) — see the Batch 4 override block above.


# Run 102 — swamp poison entry point (called by TrapZone poison pools). Applies
# the 3s purple-outline poison; re-calling refreshes the timer (never stacks).
# The HeroHitFX node ticks the low trap damage once a second on its own.
# apply_trap_poison / add_frost_stack moved to HeroBase (Batch 5).
# _frost_move_mult moved to HeroBase (Batch 2).


# Run 13 — Team Game Over (called by RunState.resolve_team_down when both
# ninjas are downed AND no DD charges remain). Kept the old _handle_death name
# and animation flow because the recap+fade still applies — only the trigger
# condition changed (was per-character death; now team-down + no DD).
func trigger_team_game_over() -> void:
	_handle_death()


func _handle_death() -> void:
	# Reset the run when player dies — full vertical slice loops back to Arena1
	# with fresh boons-cleared state. Defensive: cap to player group only.
	print("[Player] TEAM DEFEAT — both ninjas down, no DD charges left. Resetting run.")
	# Phase 7 — feel: heavy shake + dark particle burst + sound on death
	FX.screen_shake(FX.SHAKE_HEAVY, FX.SHAKE_DUR_LONG)
	FX.spawn_burst_particles(global_position, Color(0.85, 0.10, 0.10, 1.0), 24)
	FX.play_sound("player_death", 1.3)
	# Run 9 — body tips over + fades via animator.
	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_anim_state("death")
	# Disable further input/physics on the dead body so a frozen Shino doesn't
	# move during the fade.
	state = State.HURT
	velocity = Vector2.ZERO
	# Show a brief "you died" recap overlay, then fade-to-black, then reload.
	_show_death_recap()
	FX.fade_to_black(0.8, 0.25, 1.0, Callable(self, "_reload_arena1"))


func _show_death_recap() -> void:
	# Quick run-stats overlay shown during the fade. Reads from RunState.
	var layer := CanvasLayer.new()
	layer.layer = 75   # below fade (80), above HUD (10)
	var scene := get_tree().current_scene
	if scene == null:
		return
	scene.add_child(layer)
	var label := Label.new()
	label.anchor_left = 0.5
	label.anchor_right = 0.5
	label.anchor_top = 0.5
	label.anchor_bottom = 0.5
	label.offset_left = -260.0
	label.offset_top = -40.0
	label.offset_right = 260.0
	label.offset_bottom = 80.0
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 28)
	label.modulate = Color(1.0, 0.85, 0.85, 1.0)
	var boons_taken: int = (RunState.boons_taken.size() if "boons_taken" in RunState else 0)
	var arenas: int = (RunState.arenas_cleared if "arenas_cleared" in RunState else 0)
	var loops: int = (RunState.loops_completed if "loops_completed" in RunState else 0)
	label.text = "✦  THE DREAM ENDS  ✦\n\nArenas cleared: %d   |   Boons: %d   |   Loops: %d\n\nShino awakens back at the Dojo..." % [arenas, boons_taken, loops]
	layer.add_child(label)
	# Auto-free the recap layer after the fade has completed.
	# Use a Callable.bind so we capture `layer` without a multi-line lambda.
	get_tree().create_timer(1.4).timeout.connect(Callable(self, "_free_recap_layer").bind(layer), CONNECT_ONE_SHOT)


func _free_recap_layer(layer: Node) -> void:
	if is_instance_valid(layer):
		layer.queue_free()


func _reload_arena1() -> void:
	# Run 117 — bank hidden karma from this run's boons even on DEFEAT
	# (win OR succumb both bank, per Townsfolk §1). Must run BEFORE the
	# save below so it persists, and before reset_run() wipes boons_taken.
	RunState.bank_run_karma()
	# Save meta progress (dragon_souls, sensei upgrades) before clearing run state.
	var sm: Node = get_node_or_null("/root/SaveManager")
	if sm and sm.has_method("save_active_slot") and sm.active_slot >= 0:
		sm.save_active_slot()
	RunState.reset_run()   # preserves dragon_souls + sensei_* (meta fields)
	RunState.clear_carry()
	RunState.clear_bea_carry()
	get_tree().change_scene_to_file("res://scenes/Dojo.tscn")


# -------------------------------------------------------
# Run 13 — Downed state + revive system moved to HeroBase (Batch 4).
# Moved: is_downed, _enter_downed_state, _check_team_down_state, revive_from_dd,
# revive_from_partner, _build_revive_ui, _clear_revive_ui, _refresh_rez_bar,
# add_rez_fill, get_rez_fill. Shino's combat teardown + downed FX are supplied
# via the Batch 4 child overrides / FX vars. trigger_team_game_over + _handle_death
# stay below (Shino is the canonical death sink).
# -------------------------------------------------------


# _tick_dd_hot / apply_sweet_dreams_heal moved to HeroBase (Batch 5).


# -------------------------------------------------------
# Phase 7 — Shino auto-defend stub (only ticks when Bea is player-controlled)
# -------------------------------------------------------
# -------------------------------------------------------
# Shino AI (when Bea is player-controlled) — Run 32 rework.
# Priority order:
#   1. If an exit gate is open and Bea is near it → walk to the same gate.
#   2. If enemies are nearby → attack (melee + ki blast).
#   3. Otherwise → follow Bea, keep ~80px distance.
# -------------------------------------------------------
const SHINO_AI_FOLLOW_DIST: float = 80.0    # target distance from Bea
const SHINO_AI_ATTACK_RANGE: float = 280.0  # engage enemies within this range (was 160 — too short)
const SHINO_AI_MELEE_RANGE: float = 48.0    # close enough for Y-combo tap

# Run 64b — split the AI melee cadence into two phases so combos always COMPLETE:
#   * STEP_GAP — re-tap delay WHILE a combo is in progress. Must be shorter than
#     the combo-continuation window (~0.40s after the snappy jab) at every tier,
#     or the chain resets to the first hit. Fixed + fast for all tiers.
#   * REENGAGE_GAP — pause AFTER a combo finishes, before the next melee_chance
#     roll. Tier-scaled: Beast Mode re-engages almost immediately; cautious tiers
#     hang back and circle. This (plus melee_chance) is the "aggressiveness" knob.
const SHINO_AI_COMBO_STEP_GAP: float = 0.16
var _shino_ai_strafe_sign: float = 1.0   # circling direction during between-combo reposition

# Run 38 — Dojo wait AI. The off-duty character walks to the middle of the
# dojo (his spot on the Training Mat) and sits there until swapped to.
# Placeholder "sit": sprite nudged down a few px + animation frozen.
func _tick_dojo_wait(_delta: float) -> void:
	var to_spot: Vector2 = dojo_wait_pos - global_position
	if to_spot.length() > 8.0:
		facing = to_spot.normalized()
		velocity = facing * RunState.move_speed_mult * move_speed * 0.8
		state = State.MOVING
		if _sprite:
			_sprite.position.y = -9.0   # standing while walking over
	else:
		velocity = Vector2.ZERO
		state = State.IDLE
		if _sprite:
			_sprite.position.y = -4.0   # placeholder sitting pose
	move_and_slide()


func _tick_shino_auto_defend(delta: float) -> void:
	if _shino_ai_shot_timer > 0.0:
		_shino_ai_shot_timer -= delta

	# Run 61 — 5-tier behavior. Tier 1 = follow + dodge only.
	var spec: Dictionary = RunState.get_ai_tier_spec()
	var tier: int = RunState.ai_helper_tier

	# --- Find Bea ---
	var bea: Node = null
	for b in get_tree().get_nodes_in_group("bea"):
		if is_instance_valid(b):
			bea = b
			break

	# --- Run 91: DASH THROUGH BARRIERS ---
	# Before walking the priority branches (which would otherwise grind/sidestep
	# around an obstacle), check whether the thing blocking the straight path to
	# his current goal is an inner "dashable_barrier". If so, phase through it the
	# same way the player can, so he keeps following / closing instead of stalling.
	var _g: Dictionary = _shino_ai_primary_goal(bea, tier)
	if _ai_try_dash_through_barrier_shino(_g["dir"], _g["dist"]):
		return

	# --- Priority 0 (Run 65): revive a downed partner ---
	# The standing AI must drop the chase and beeline to a downed ally so the
	# circle/channel rez in _tick_revive_attempt can finish. Before this, no
	# path-to-body behavior existed — the AI happily kited enemies off-screen
	# while the player bled out (the softlock Bruno hit). A manual recall (the
	# downed player tapping Q+Q at tier 5) sets RunState.revive_recall_active,
	# which also forces the channel even past hazards / nearby enemies.
	var downed_ally: Node = _find_downed_partner()
	if downed_ally != null and is_instance_valid(downed_ally):
		var to_down: Vector2 = downed_ally.global_position - global_position
		var ddist: float = to_down.length()
		if ddist > REVIVE_CHANNEL_RANGE * 0.85:
			# Walk to the body. Hazard-avoid + smoothed heading so we still
			# thread traps instead of grinding into the corner Shino got stuck on.
			var mvd: Vector2 = _ai_avoid_and_smooth_shino(to_down.normalized(), delta)
			facing = mvd if mvd != Vector2.ZERO else facing
			velocity = mvd * RunState.move_speed_mult * move_speed
			state = State.MOVING if mvd != Vector2.ZERO else State.IDLE
			move_and_slide()
			return
		else:
			# In range — plant and let _tick_revive_attempt drive the rez.
			velocity = Vector2.ZERO
			state = State.IDLE
			move_and_slide()
			return

	# --- Priority 1: Follow Bea to an open exit gate (universal) ---
	if bea != null and is_instance_valid(bea):
		var near_gate: String = _find_gate_bea_is_near(bea)
		if near_gate != "":
			var gate_pos: Vector2 = _find_gate_position(near_gate)
			if gate_pos != Vector2.ZERO:
				var to_gate: Vector2 = gate_pos - global_position
				var move_g: Vector2 = Vector2.ZERO
				if to_gate.length() > 16.0:
					move_g = to_gate.normalized()
				# Universal hazard avoidance (steer-around + smoothed heading).
				move_g = _ai_avoid_and_smooth_shino(move_g, delta)
				facing = move_g if move_g != Vector2.ZERO else facing
				velocity = move_g * RunState.move_speed_mult * move_speed
				state = State.MOVING if move_g != Vector2.ZERO else State.IDLE
				move_and_slide()
				return

	# --- Priority 2 (T2+): Engage nearest enemy ---
	# Tier 1 = Spectator: skip combat entirely, fall through to follow.
	var nearest_enemy: Node = null
	var best_dist: float = SHINO_AI_ATTACK_RANGE
	if tier >= 2:
		for e in get_tree().get_nodes_in_group("enemy"):
			if not is_instance_valid(e) or (e.has_method("is_alive") and not e.is_alive()):
				continue
			var d: float = global_position.distance_to(e.global_position)
			if d < best_dist:
				best_dist = d
				nearest_enemy = e

	if nearest_enemy != null:
		var to_enemy: Vector2 = (nearest_enemy.global_position - global_position)
		facing = to_enemy.normalized()
		var melee_eng: float = float(spec.get("melee_engage_dist", -1.0))
		# T2 = pure ranged (engage_dist=-1); T3=60 occasional; T4=140 prefer; T5=200 chase.
		# T2 still closes to shooting distance via the "outside melee range" branch.
		var has_melee_intent: bool = (melee_eng > 0.0)
		var want_close: bool = has_melee_intent and (best_dist <= melee_eng)
		if want_close and best_dist > SHINO_AI_MELEE_RANGE:
			# Close the gap fast (full speed) so Beast Mode actually charges in.
			var mv: Vector2 = _ai_avoid_and_smooth_shino(facing, delta)
			velocity = mv * RunState.move_speed_mult * move_speed
			state = State.MOVING
		elif best_dist <= SHINO_AI_MELEE_RANGE:
			# In melee range. Run 64b — two-phase cadence so the full 4-hit combo
			# always lands instead of replaying the first hit after a long delay.
			var melee_chance: float = float(spec.get("melee_chance", 0.0))
			# A Y combo is "in progress" until the finisher (step 4). While in
			# progress we NEVER re-roll melee_chance — once started, it runs to all
			# four hits. A fresh combo only starts on a winning melee_chance roll.
			var combo_in_progress: bool = (current_attack == AttackType.Y and combo_step >= 1 and combo_step < Y_COMBO_HITS)
			if _shino_ai_shot_timer <= 0.0 and (combo_in_progress or (melee_chance > 0.0 and randf() < melee_chance)):
				if not combo_in_progress:
					print("[Shino AI T%d] Y combo start — target @%.0fpx" % [tier, best_dist])
				velocity = Vector2.ZERO
				state = State.IDLE
				_try_start_attack(AttackType.Y)
				# Fast re-tap — shorter than the continuation window at every tier,
				# so the chain advances (1→2→3→4) instead of resetting to the jab.
				_shino_ai_shot_timer = SHINO_AI_COMBO_STEP_GAP
			elif combo_in_progress or state == State.ATTACKING or _y_combo_recovery_timer > 0.0:
				# Mid-swing / brief inter-hit pause / Y4 finisher recovery — hold ground.
				velocity = Vector2.ZERO
				if state != State.ATTACKING:
					state = State.IDLE
			else:
				# Between combos — reposition by tier aggressiveness. Beast Mode hovers
				# on top of the target; cautious tiers break off and circle. When the
				# melee_chance roll above fails, this is what makes them "move out".
				if _shino_ai_shot_timer <= 0.0:
					if randf() < 0.5:
						_shino_ai_strafe_sign = -_shino_ai_strafe_sign
					_shino_ai_shot_timer = 0.25 if tier >= 5 else (0.55 if tier == 4 else 0.90)
				var rdir: Vector2 = _ai_shino_melee_reposition(to_enemy.normalized(), tier)
				rdir = _ai_avoid_and_smooth_shino(rdir, delta)
				velocity = rdir * RunState.move_speed_mult * move_speed * (0.7 if tier >= 5 else 0.6)
				state = State.MOVING if rdir != Vector2.ZERO else State.IDLE
		else:
			# Out of melee_engage range. Still walk forward toward the enemy
			# so Tier 2 (pure ranged) closes to shot range and Tier 4/5 can
			# chase enemies that flee past their engage radius.
			var mv2: Vector2 = _ai_avoid_and_smooth_shino(facing, delta)
			# Faster for higher tiers — Beast Mode commits to the chase.
			var pursue_mult: float = 0.95 if tier >= 4 else (0.80 if tier == 3 else 0.65)
			velocity = mv2 * RunState.move_speed_mult * move_speed * pursue_mult
			state = State.MOVING
		move_and_slide()

		# Tier-aware ranged: cadence pulled from AI_TIER_TABLE. Fires from
		# any distance up to ~SHOT_RANGE so AI partner can poke at runners.
		var iv: float = float(spec.get("ranged_interval", -1.0))
		if iv > 0.0 and best_dist > SHINO_AI_MELEE_RANGE \
		and best_dist <= SHINO_AI_SHOT_RANGE \
		and _shino_ai_shot_timer <= 0.0 and projectile_scene != null:
			_shino_ai_shot_timer = iv * (0.85 + randf() * 0.30)
			print("[Shino AI T%d] ki blast @%.0fpx (iv=%.2f)" % [tier, best_dist, iv])
			var proj = projectile_scene.instantiate()
			var parent = get_parent()
			if parent:
				parent.add_child(proj)
				proj.global_position = global_position + facing * 20.0
				if proj.has_method("launch"):
					proj.launch(facing, RANGED_PROJECTILE_SPEED, _scale_damage(RANGED_PROJECTILE_DAMAGE, false, false, null, "ranged") + RunState.seeded_shot_bonus_dmg(current_hp, "shino"))
			FX.play_sound("shino_ai_fire", 0.7)
		return

	# --- Priority 3: Follow Bea (universal, all tiers) ---
	if bea != null and is_instance_valid(bea):
		var to_bea: Vector2 = bea.global_position - global_position
		var dist: float = to_bea.length()
		var mv3: Vector2 = Vector2.ZERO
		if dist > SHINO_AI_FOLLOW_DIST:
			mv3 = to_bea.normalized()
		# Hazard avoidance (steer-around + smoothed heading; universal).
		mv3 = _ai_avoid_and_smooth_shino(mv3, delta)
		# Natural wobble.
		if mv3 != Vector2.ZERO:
			var wob: float = sin(Time.get_ticks_msec() * 0.0029) * 0.16
			var perp: Vector2 = Vector2(-mv3.y, mv3.x)
			mv3 = (mv3 + perp * wob).normalized()
			facing = mv3
			velocity = mv3 * RunState.move_speed_mult * move_speed * 0.9
			state = State.MOVING
		else:
			velocity = Vector2.ZERO
			state = State.IDLE
		move_and_slide()


# Run 63 — Shino-side hazard avoidance (mirrors BeaAI._ai_compute_hazard_push).
# Steering, not pure repulsion: radial push only when deep inside a ring, plus a
# tangential "round the trap toward the goal" component for any trap ahead of the
# desired heading. NOT normalized — magnitude feeds _ai_avoid_and_smooth_shino.
const AI_STEER_SMOOTH_RATE: float = 14.0
var _ai_steer_smoothed_shino: Vector2 = Vector2.ZERO

# Run 69 — STUCK-ON-WALL escape (mirrors BeaAI). Hazard steering only rounds trap
# zones, not solid geometry, so chasing an enemy into a corner could pin Shino's
# AI against a wall. Position sensor: trying to move yet barely advancing
# (< AI_STUCK_MIN_STEP px/frame) for AI_STUCK_TIME triggers a tangential detour
# burst (AI_UNSTICK_BURST sec), flipping sides each retry so a wrong guess fixes.
const AI_STUCK_MIN_STEP: float = 0.65
const AI_STUCK_TIME: float = 0.40
const AI_UNSTICK_BURST: float = 1.00
var _ai_last_pos_shino: Vector2 = Vector2.ZERO
var _ai_stuck_timer_shino: float = 0.0
var _ai_unstick_timer_shino: float = 0.0
var _ai_unstick_dir_shino: Vector2 = Vector2.ZERO
var _ai_unstick_side_shino: float = 1.0
var _ai_unstick_fails_shino: int = 0

func _ai_compute_hazard_push_shino(desired: Vector2) -> Vector2:
	var steer: Vector2 = Vector2.ZERO
	var my_pos: Vector2 = global_position
	var have_dir: bool = desired.length() > 0.001
	var dir: Vector2 = desired.normalized() if have_dir else Vector2.ZERO
	for z in get_tree().get_nodes_in_group("hazard_zone"):
		if not is_instance_valid(z):
			continue
		var zr: float = float(z.get_meta("hazard_radius", 40.0))
		var avoid: float = zr + RunState.AI_HAZARD_AVOID_RADIUS
		var off: Vector2 = my_pos - z.global_position
		var d: float = off.length()
		if d < 0.001 or d > avoid:
			continue
		var away: Vector2 = off / d
		var depth: float = 1.0 - (d / avoid)
		steer += away * depth * depth
		if have_dir:
			var toward: Vector2 = -away
			var ahead: float = dir.dot(toward)
			if ahead > 0.0:
				var perp: Vector2 = Vector2(-toward.y, toward.x)
				if dir.dot(perp) < 0.0:
					perp = -perp
				steer += perp * ahead * (0.5 + depth)
	return steer


# Run 63 — blend the desired heading with hazard steering and smooth it over
# time so clustered traps don't make Shino's AI vibrate between them. Returns a
# unit heading (or zero when he should hold position).
func _ai_avoid_and_smooth_shino(desired: Vector2, delta: float) -> Vector2:
	var goal: Vector2 = desired + _ai_compute_hazard_push_shino(desired)
	if goal.length() <= 0.001:
		_ai_steer_smoothed_shino = Vector2.ZERO
		return Vector2.ZERO
	var tdir: Vector2 = goal.normalized()
	if _ai_steer_smoothed_shino == Vector2.ZERO:
		_ai_steer_smoothed_shino = tdir
	else:
		_ai_steer_smoothed_shino = _ai_steer_smoothed_shino.lerp(tdir, clampf(delta * AI_STEER_SMOOTH_RATE, 0.0, 1.0)).normalized()
	# Run 69 — wall/corner escape on the final heading (every move branch routes
	# through here, so it covers chase, follow, gate, and revive walks).
	return _ai_unstick_shino(_ai_steer_smoothed_shino, delta)


# Run 69 — STUCK-ON-WALL escape for Shino's AI. Position sensor + tangential
# detour for solid geometry the hazard steering can't see. Returns the heading to
# actually use: unchanged normally, but a sideways "go around" burst when he's
# been trying to move while pinned, alternating sides each retry. Called once per
# physics frame (one move branch runs per tick), before velocity is committed.
func _ai_unstick_shino(heading: Vector2, delta: float) -> Vector2:
	var moved: float = 1.0e9
	if _ai_last_pos_shino != Vector2.ZERO:
		moved = global_position.distance_to(_ai_last_pos_shino)
	_ai_last_pos_shino = global_position
	var wants_move: bool = heading.length() > 0.05

	if wants_move and moved < AI_STUCK_MIN_STEP:
		_ai_stuck_timer_shino += delta
	else:
		_ai_stuck_timer_shino = maxf(0.0, _ai_stuck_timer_shino - delta * 2.0)

	# Commit fully to one side for the whole burst (~1s) so a deep corner has time
	# to clear before we flip.
	if _ai_unstick_timer_shino > 0.0:
		_ai_unstick_timer_shino -= delta
		if moved >= AI_STUCK_MIN_STEP * 2.5:
			_ai_unstick_timer_shino = 0.0
			_ai_stuck_timer_shino = 0.0
			_ai_unstick_fails_shino = 0
			return heading
		if wants_move:
			return _ai_unstick_dir_shino   # fixed escape heading for the burst

	# Burst ended, still stuck → flip side and peel harder off the wall.
	if _ai_unstick_timer_shino <= 0.0 and _ai_stuck_timer_shino >= AI_STUCK_TIME and wants_move:
		_ai_unstick_side_shino = -_ai_unstick_side_shino
		_ai_unstick_fails_shino = mini(_ai_unstick_fails_shino + 1, 4)
		_ai_unstick_dir_shino = _ai_make_escape_shino(heading, _ai_unstick_side_shino, _ai_unstick_fails_shino)
		_ai_unstick_timer_shino = AI_UNSTICK_BURST
		_ai_stuck_timer_shino = 0.0
		return _ai_unstick_dir_shino

	return heading


# Build Shino's escape heading: mostly sidestep (perpendicular to the blocked
# goal) plus a growing BACKWARD bias so he peels off the wall instead of grinding
# into it. Deeper pocket (more failed bursts) → backs away harder.
func _ai_make_escape_shino(heading: Vector2, side: float, fails: int) -> Vector2:
	var fwd: Vector2 = heading.normalized()
	var perp: Vector2 = Vector2(-fwd.y, fwd.x) * side
	var back_bias: float = 0.15 + 0.25 * float(fails - 1)
	var esc: Vector2 = perp - fwd * back_bias
	return esc.normalized() if esc.length() > 0.001 else perp


# Run 91 — Resolve the single most important thing Shino's AI is trying to reach
# this frame, mirroring the priority order of _tick_shino_auto_defend's branches
# (downed ally > Bea's exit gate > nearest engageable enemy > follow Bea). Returns
# {dir, dist} toward that goal, or a zero dir when he should just hold position.
# Used only by the dash-through-barrier check; the branches still drive movement.
func _shino_ai_primary_goal(bea: Node, tier: int) -> Dictionary:
	var downed: Node = _find_downed_partner()
	if downed != null and is_instance_valid(downed):
		var dd: Vector2 = downed.global_position - global_position
		if dd.length() > REVIVE_CHANNEL_RANGE * 0.85:
			return {"dir": dd.normalized(), "dist": dd.length()}
		return {"dir": Vector2.ZERO, "dist": 0.0}
	if bea != null and is_instance_valid(bea):
		var ng: String = _find_gate_bea_is_near(bea)
		if ng != "":
			var gp: Vector2 = _find_gate_position(ng)
			if gp != Vector2.ZERO:
				var tg: Vector2 = gp - global_position
				if tg.length() > 16.0:
					return {"dir": tg.normalized(), "dist": tg.length()}
	if tier >= 2:
		var ne: Node = null
		var bd: float = SHINO_AI_ATTACK_RANGE
		for e in get_tree().get_nodes_in_group("enemy"):
			if not is_instance_valid(e) or (e.has_method("is_alive") and not e.is_alive()):
				continue
			var de: float = global_position.distance_to(e.global_position)
			if de < bd:
				bd = de
				ne = e
		if ne != null:
			var te: Vector2 = ne.global_position - global_position
			return {"dir": te.normalized(), "dist": te.length()}
	if bea != null and is_instance_valid(bea):
		var tb: Vector2 = bea.global_position - global_position
		if tb.length() > SHINO_AI_FOLLOW_DIST:
			return {"dir": tb.normalized(), "dist": tb.length()}
	return {"dir": Vector2.ZERO, "dist": 0.0}


# Run 91 — Should Shino's AI dash THROUGH an inner barrier right now? Raycasts at
# his goal: if the FIRST thing in the way is a "dashable_barrier" between him and
# the goal and a dash is ready, he dashes through it. A solid wall (or clear path)
# → no dash (the per-branch _ai_unstick_shino sidesteps solid geometry). Returns
# true if a dash started; the DASHING tick takes over from there.
const AI_DASH_BARRIER_REACH: float = 96.0   # ~ one dash length (950px * 0.09s ≈ 86px) + margin
func _ai_try_dash_through_barrier_shino(goal_dir: Vector2, goal_dist: float) -> bool:
	if player_controlled:
		return false
	if state != State.IDLE and state != State.MOVING:
		return false
	if dash_cd_timer > 0.0 or dash_charges <= 0:
		return false
	if goal_dir.length() < 0.01 or goal_dist < 24.0:
		return false
	var dir: Vector2 = goal_dir.normalized()
	var reach: float = minf(AI_DASH_BARRIER_REACH, goal_dist + 16.0)
	var space := get_world_2d().direct_space_state
	var q := PhysicsRayQueryParameters2D.create(
		global_position, global_position + dir * reach)
	q.collision_mask = 1            # dashable barriers + walls live on layer 1
	q.collide_with_areas = false
	q.collide_with_bodies = true
	q.exclude = [self]
	var hit: Dictionary = space.intersect_ray(q)
	if hit.is_empty():
		return false                # clear path — nothing to phase
	var collider = hit.get("collider")
	if collider == null or not (collider is Node) \
	or not collider.is_in_group("dashable_barrier"):
		return false                # first blocker is solid (a wall) — let unstick steer
	facing = dir                    # _start_dash uses facing when there's no input
	print("[Shino AI] Dashing through barrier to reach goal.")
	_start_dash()
	return true


## Run 64b/64c — between-combo footwork heading. Shino moves like a martial
## artist managing range: a lateral SIDESTEP to change angle (direction =
## _shino_ai_strafe_sign, which flips between bouts) layered over an in/out BOB —
## a rhythmic weight-shift that steps him in to threaten and back out to reset,
## like bouncing on the balls of his feet. A tier standoff bias sets the resting
## distance: cautious tiers hang back, Beast Mode crowds in to keep pressure.
func _ai_shino_melee_reposition(to_enemy_dir: Vector2, tier: int) -> Vector2:
	if to_enemy_dir == Vector2.ZERO:
		return Vector2.ZERO
	var back_off: float = 0.55 if tier <= 3 else (0.22 if tier == 4 else -0.12)
	# In/out feint: oscillates ±0.45 so he repeatedly steps in then resets out.
	var bob: float = sin(Time.get_ticks_msec() * 0.006) * 0.45
	# +to_enemy_dir = step toward target; net radial = bob (in) minus standoff bias.
	var radial: Vector2 = to_enemy_dir * (bob - back_off)
	var perp: Vector2 = Vector2(-to_enemy_dir.y, to_enemy_dir.x) * _shino_ai_strafe_sign
	var move: Vector2 = perp + radial
	return move.normalized() if move.length() > 0.001 else Vector2.ZERO


func _find_gate_bea_is_near(bea: Node) -> String:
	# Ask World.gd whether Bea is standing near an open gate — returns gate name or "".
	var world: Node = get_tree().current_scene
	if world == null:
		return ""
	# Use world.get() directly — the "in" operator can miss unexported script vars.
	var bea_near_raw = world.get("_bea_near_gate")
	if bea_near_raw == null:
		return ""
	var bea_near: Dictionary = bea_near_raw as Dictionary
	var gates_raw = world.get("_gates")
	var gates_open: Dictionary = {}
	if gates_raw != null:
		for g in gates_raw:
			if g.get("opened", false):
				gates_open[String(g.get("name", ""))] = true
	for gate_name in bea_near.keys():
		if bool(bea_near[gate_name]) and gates_open.get(gate_name, false):
			return gate_name
	return ""


func _find_gate_position(gate_name: String) -> Vector2:
	var world: Node = get_tree().current_scene
	if world == null:
		return Vector2.ZERO
	var gates_raw = world.get("_gates")
	if gates_raw == null:
		return Vector2.ZERO
	for g in gates_raw:
		if String(g.get("name", "")) == gate_name:
			# Prefer the DoorTrigger Area2D position so Shino actually enters the
			# trigger zone (gate node center is the wall, not the walkable threshold).
			var trigger: Node = g.get("trigger")
			if trigger != null and is_instance_valid(trigger):
				return (trigger as Node2D).global_position
			var node: Node = g.get("node")
			if node != null and is_instance_valid(node):
				return (node as Node2D).global_position
	return Vector2.ZERO


func get_facing() -> Vector2:
	return facing


# -------------------------------------------------------
# RunState integration — boons + carry-over state
# -------------------------------------------------------
# get_effective_max_hp / get_effective_max_chi moved to HeroBase (Batch 5).
# get_current_hp / get_current_chi moved to HeroBase (Batch 4).
# apply_runstate_modifiers moved to HeroBase (Batch 5).


func _apply_carry_state() -> void:
	# Restore HP / Chi from previous arena.
	if RunState.carry_hp >= 0:
		current_hp = min(RunState.carry_hp, get_effective_max_hp())
	if RunState.carry_chi >= 0:
		current_chi = min(RunState.carry_chi, get_effective_max_chi())
	# Restore player-controlled flag BEFORE clear_carry() so Bea can also read it.
	# carry_player_controlled_char == 1 means Bea was in control → Shino is AI.
	if RunState.carry_player_controlled_char == 1:
		player_controlled = false
	# else: 0 or -1 means Shino was/should be controlled — keep default true.
	# Run 73 — in 2P co-op Shino is ALWAYS human-controlled (Bea is the other
	# human, not AI), regardless of the carried hot-swap flag.
	if RunState.two_player:
		player_controlled = true
	# HP/Chi carry is consumed now; player_controlled_char is consumed by BeaAI._ready().
	RunState.clear_carry()


# Scale outgoing damage by boons + a fresh crit roll. Returns the final integer.
# `is_finisher` = true for combo-finisher hits (Y-final, X-final) and for
#   charge releases (Crane Kick, Kamehameha ticks, Ult) per Combat_Boons.md
#   §Grape Noble Rot definition. Adds Noble Rot's +1%/combo-point amp on top.
# `is_primary` = true ONLY for primary (Y) attack hits (Y-tap combo).
#   Gates Heavy Stalk (+15%) and Full Bloom (+15% > 80% HP) — both are
#   Y-slot boons per Combat_Boons §8.2/§8.3 "Y = primary attacks".
# Grape Combo Master adds +1%/combo-point to ALL hits regardless of is_finisher.
# Grape Bunch Bonus adds +25% when 2+ enemies are within 192px of the player.
func _scale_damage(base: int, is_finisher: bool = false, is_primary: bool = false, target: Node = null, attack_type: String = "") -> int:
	# Resolve attack_type if not explicitly passed.
	var _atype: String = attack_type
	if _atype == "":
		_atype = "primary" if is_primary else "heavy"
	# Run 27f — One Big Grape corrupt: every Y/X press is a finisher.
	if RunState.shino_has("corrupt_grape"):
		is_finisher = true
	# Run 27f — Drawn Bow (Carrot passive): 1.5s+ without attacking → next
	# attack is a guaranteed crit. Timer resets on every attack (this call).
	# Run 134 — Drawn Bow now covers ranged too (ranged routes through here as
	# _atype == "ranged"); CHARGED attacks need the longer 3s idle (anti-cheese).
	var _db_thresh: float = RunState.DRAWN_BOW_IDLE_CHARGED if _atype == "charge" else RunState.DRAWN_BOW_IDLE
	if RunState.shino_has("drawn_bow") and _no_attack_timer >= _db_thresh:
		RunState.force_next_crit = true
	_no_attack_timer = 0.0
	# Run 27f — Bullseye Finale post-ult window: +25% crit chance.
	if _bullseye_finale_window > 0.0:
		RunState.finisher_crit_chance_bonus += 0.25
	# Run 27 — Shocking Slip duo (Grape+Banana): Sparked/Bolted target grants
	# +20% crit chance on this landing hit (seeded pre-roll, consumed by roll).
	if target != null and target.has_node("StatusComponent"):
		var _ts_pre = target.get_node("StatusComponent")
		if _ts_pre.has("sparked") or _ts_pre.has("bolted"):
			RunState.finisher_crit_chance_bonus += RunState.get_grape_banana_crit_bonus()
		# Run 27 — Night-Vision Peel duo (Banana+Carrot): Slipped/Greased
		# targets count as flanked — +20% crit chance on the landing hit.
		if (_ts_pre.has("slippery") or _ts_pre.has("greased")) and RunState.is_duo_active("banana_carrot"):
			RunState.finisher_crit_chance_bonus += 0.20
	# Run 128 — Topshot (Carrot Legendary): first attack on every NEW enemy
	# is a guaranteed Mega-Crit (per-enemy meta flag, per hero).
	if RunState.shino_has("topshot") and target != null and is_instance_valid(target) \
	and not target.has_meta("topshot_shino"):
		target.set_meta("topshot_shino", true)
		RunState.force_next_crit = true
	# Run 130 — Ghost Pepper: first strike from stealth applies max Burn (5).
	if _ghost_stealthed:
		_ghost_stealthed = false
		modulate.a = 1.0
		if target != null and is_instance_valid(target) and target.has_node("StatusComponent"):
			target.get_node("StatusComponent").apply("burning", 3.0, 5)
			FX.spawn_burst_particles((target as Node2D).global_position, Color(1.0, 0.45, 0.10, 0.95), 12)
	# Run 130 — Marksman's Eye: ranged hits on the Marked target always crit.
	if _atype == "ranged" and RunState.team_has("marksmans_eye") \
	and target != null and is_instance_valid(target) and target.has_meta("me_marked"):
		RunState.force_next_crit = true
	var mult: float = RunState.get_char_damage_mult("shino") * RunState.roll_crit_mult(_atype)
	# Run 128 — Smash Zone (Broccoli Legendary): melee-only proximity damage.
	if (_atype == "primary" or _atype == "heavy") and target != null \
	and is_instance_valid(target) and target is Node2D:
		mult *= RunState.get_smash_zone_mult("shino", global_position.distance_to((target as Node2D).global_position))
	# Run 128 — Vineyard Reserve (Grape Legendary): at 30+ combo, +30% all damage.
	if RunState.shino_has("vineyard_reserve") and combo_count >= 30:
		mult *= 1.30
	# Run 128 — Master Stroke duo arm 2: finisher crits deal +50% crit damage.
	if is_finisher and RunState.last_crit_result and RunState.master_stroke_active():
		mult *= 1.5
	# Run 130 — Marksman's Eye: +30% crit damage vs the Marked target.
	if _atype == "ranged" and RunState.last_crit_result and target != null \
	and is_instance_valid(target) and target.has_meta("me_marked") \
	and RunState.team_has("marksmans_eye"):
		mult *= 1.30
	mult *= RunState.get_combo_master_mult(combo_count, "shino")
	mult *= RunState.get_noble_rot_mult(combo_count, is_finisher, "shino")
	# Apple Heavy Harvest — X attacks gain up to +25% at full HP.
	mult *= RunState.get_heavy_harvest_mult(float(current_hp) / float(max(1, get_effective_max_hp())) if not is_primary else 1.0, "shino") if not is_primary else 1.0
	# Cluster Cascade — cross-finisher buff (+25% X primed; +50% Y primed).
	if is_finisher:
		mult *= RunState.get_cluster_cascade_mult(is_primary)
		RunState.notify_cluster_cascade_finisher(is_primary)
	# Broccoli Heavy Stalk — Y-only +15% (Run 16: pulled out of damage_mult global).
	mult *= RunState.get_heavy_stalk_mult(is_primary, "shino")
	# Run 27b — Potato Heavy Stance: +15% damage while Ingrained (1.5s+ still).
	if RunState.shino_has("heavy_stance") and _ingrained_time >= RunState.INGRAINED_THRESHOLD:
		mult *= 1.15
	# Broccoli Stalk of Might — +5% per Broccoli boon owned (commit-reward, always-on).
	mult *= RunState.get_stalk_of_might_mult_for("shino")
	# Broccoli Combat Fury — tier-driven consecutive-hit ramp.
	mult *= RunState.get_combat_fury_mult(_combat_fury_tier, "shino")
	# Apple Full Bloom — Y-only +15% when player is above 80% HP.
	var hp_frac: float = float(current_hp) / float(max(1, get_effective_max_hp()))
	mult *= RunState.get_full_bloom_mult(hp_frac, is_primary, "shino")
	# Apple Ripened Core + Heart of the Orchard — tiered HP-scaled damage.
	mult *= RunState.get_apple_hp_tier_mult(hp_frac, "shino")
	# Broccoli Green Rage — always-on tiered rage at low HP.
	mult *= RunState.get_green_rage_mult(hp_frac, "shino")
	# Apple Sweet Harvest — charge attacks: +20% dmg when above 75% HP.
	if _atype == "charge":
		mult *= RunState.get_sweet_harvest_mult(hp_frac, "shino")
		# Run 131 — Fury Release (Broccoli Charge): +60% charge damage (owner-gated).
		if RunState.shino_has("fury_release"):
			mult *= (1.0 + RunState.FURY_RELEASE_DMG_BONUS)
	# Run 127 — status-slot baseline dmg (Hades parity)
	# Status-only slot boons (Soaked/Slippery/Greased appliers) also boost that
	# slot's base damage. Map attack type → slot so each fires ONLY for its slot.
	var _status_slot: String = ""
	match _atype:
		"primary": _status_slot = "Y"
		"heavy": _status_slot = "X"
		"ranged": _status_slot = "A"
		"charge": _status_slot = "Charge"
	if _status_slot != "":
		mult *= RunState.get_status_slot_dmg_mult("shino", _status_slot)
	if RunState.shino_has("bunch_bonus") and _count_nearby_enemies(BUNCH_BONUS_RADIUS) >= 2:
		mult *= 1.25
	# Run 19 — Iron Core duo (Apple + Broccoli): +5% damage per owned boon.
	mult *= RunState.get_iron_core_damage_mult()
	# Run 24 — Coconut+Broccoli "Ironwood": +10% damage while overshield is active.
	mult *= RunState.get_coconut_broccoli_dmg_mult(overshield_charges)
	# Run 24/134 — Sniper's Focus (Carrot Legendary 2): +50% dmg during 2s window.
	# Per-hero streak + window (Shino) — his crits never advance Bea's buff.
	mult *= RunState.get_sniper_focus_mult("shino")
	# Tick streak counter based on last crit result (already rolled above).
	RunState.tick_sniper_focus(RunState.last_crit_result, "shino")
	# Run 27f — Titan's Roar post-ult window: +20% all damage for 5s.
	if _titans_roar_window > 0.0:
		mult *= 1.20
	# Run 27f — Killshot (Carrot passive): crits on targets below 25% HP have
	# a 7% chance to Super-Mega-Crit (~3× extra on top of the crit).
	if RunState.last_crit_result and RunState.shino_has("killshot") \
	and target != null and target.get("max_hp") != null and target.get("current_hp") != null:
		if float(target.current_hp) / max(1.0, float(target.max_hp)) < 0.25 and randf() < 0.07:
			mult *= 3.0
			RunState._set_crit_tier(2)   # Run 128 — Super-Mega-Crit shows RED
			FX.spawn_burst_particles(target.global_position, Color(1.0, 0.30, 0.10, 1.0), 16)
	# Target-dependent multipliers (Crushing Blow, Blazing Aura, Inferno Crown,
	# Rising Tide, Tough Cookie). Skipped if no target passed.
	if target != null and is_instance_valid(target):
		mult *= _get_target_status_damage_mult(target)
	# Sensei Z: Dragon Vigor flat damage bonus.
	mult *= (1.0 + RunState.sensei_damage_pct)
	var scaled: float = float(base) * mult
	# Run 130 — Marksman's Eye ricochet: ranged hits on the Marked target
	# bounce to up to 3 nearby enemies at 75% damage.
	if _atype == "ranged" and RunState.team_has("marksmans_eye") \
	and target != null and is_instance_valid(target) and target is Node2D \
	and target.has_meta("me_marked"):
		var _me_hits: int = 0
		for _me_e in get_tree().get_nodes_in_group("enemy"):
			if _me_e == target or not is_instance_valid(_me_e) or not (_me_e is Node2D):
				continue
			if (target as Node2D).global_position.distance_to(_me_e.global_position) < 240.0 \
			and _me_e.has_method("take_damage"):
				_me_e.take_damage(max(1, int(round(scaled * 0.75))), Vector2.ZERO)
				FX.spawn_hit_particles(_me_e.global_position, Color(1.0, 0.45, 0.15, 0.9), 5)
				_me_hits += 1
				if _me_hits >= 3:
					break
	return max(1, int(round(scaled)))


# Accumulate all target-status multipliers from boons that amp damage based on
# the enemy's current status (Blazing Aura, Inferno Crown, Rising Tide,
# Crushing Blow, Bash the Big Ones, Tough Cookie). Returns the combined
# multiplier to apply on top of the base _scale_damage result.
func _get_target_status_damage_mult(target: Node) -> float:
	var mult: float = 1.0
	if not is_instance_valid(target):
		return mult
	var ts: Variant = target.get("status") if target.has_method("get") else null

	# Broccoli Crushing Blow — +50% to enemies below 30% HP.
	if RunState.shino_has("crushing_blow"):
		var t_hp: int = int(target.get("current_hp") if "current_hp" in target else -1)
		var t_max: int = int(target.get("max_hp") if "max_hp" in target else 1)
		if t_hp > 0 and t_max > 0:
			var t_frac: float = float(t_hp) / float(t_max)
			mult *= RunState.get_crushing_blow_mult(t_frac)

	# Broccoli Bash the Big Ones — +25% to elites/bosses.
	if RunState.shino_has("bash_big_ones"):
		var is_boss: bool = target.is_in_group("boss") or target.is_in_group("elite")
		mult *= RunState.get_bash_big_ones_mult(is_boss)

	# Run 46 — Boss Hunter (Sensei Z): +5%/tier vs bosses, mini-bosses, elites.
	if RunState.sensei_boss_dmg_pct > 0.0:
		if target.is_in_group("boss") or target.is_in_group("miniboss") or target.is_in_group("elite"):
			mult *= (1.0 + RunState.sensei_boss_dmg_pct)

	if ts != null and ts.has_method("has"):
		# Run 150b (Bruno ruling): "X% more damage vs status-Y enemies" boons
		# are SELF-buffs — only the ninja holding the boon benefits. All the
		# global `*_taken` reads below became shino_has() gates.
		# Pepper Blazing Aura — burning enemies take +10% from YOUR hits.
		if RunState.shino_has("blazing_aura") and ts.has("burning"):
			mult *= 1.10

		# Pepper Inferno Crown (Legendary) — +40% to burning enemies.
		if RunState.shino_has("inferno_crown") and ts.has("burning"):
			mult *= 1.40

		# Watermelon Rising Tide — wet/frostbitten enemies take +15% from YOUR hits.
		if RunState.shino_has("rising_tide") and (ts.has("wet") or ts.has("chilled") or ts.has("drenched") or ts.has("frostbitten")):
			mult *= 1.15

		# Coconut Tough Cookie — +15% to enemies with any Coconut debuff active.
		if RunState.shino_has("tough_cookie"):
			if ts.has("bash") or ts.has("stagger") or ts.has("vulnerable"):
				mult *= 1.15

		# Onion Fermented Strength +5%/poison stack.
		if RunState.shino_has("fermented_strength") and ts.has_method("get_stacks"):
			var p_stacks: int = ts.get_stacks("poison")
			if p_stacks > 0:
				mult *= (1.0 + 0.05 * float(p_stacks))

	return mult


# Count alive enemies within `radius` px of this player. Used by Bunch Bonus.
func _count_nearby_enemies(radius: float) -> int:
	var r2: float = radius * radius
	var count: int = 0
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e):
			continue
		if e.has_method("is_alive") and not e.call("is_alive"):
			continue
		if global_position.distance_squared_to(e.global_position) <= r2:
			count += 1
	return count


# Tier-3 AI helper — is any enemy within `radius` currently in an attack
# windup or active-strike state? Used by the channel-revive AI to dash-cancel.
func _ai_enemy_attack_imminent(radius: float) -> bool:
	var r2: float = radius * radius
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e):
			continue
		if e.has_method("is_alive") and not e.call("is_alive"):
			continue
		if global_position.distance_squared_to(e.global_position) > r2:
			continue
		if e.has_method("is_attack_imminent") and e.is_attack_imminent():
			return true
	return false


# -------------------------------------------------------
# Spinning Crane Kick (§8.2.1 X-charge — in-place 360° AoE)
# -------------------------------------------------------
func _start_spinning_crane_kick() -> void:
	state = State.CRANE_KICKING
	crane_kick_timer = CRANE_KICK_LOCKOUT
	velocity = Vector2.ZERO
	if crane_kick_scene == null:
		print("[Player] SpinningCraneKick.tscn not loaded — skip AoE")
		state = State.IDLE
		return
	var sck = crane_kick_scene.instantiate()
	var parent = get_parent()
	if parent:
		parent.add_child(sck)
		sck.global_position = global_position
		# Hulk Smash: doubled AoE radius.
		if RunState.shino_has("hulk_smash") and "radius" in sck:
			sck.radius = sck.radius * RunState.HULK_SMASH_AOE_MULT
	FX.screen_shake(FX.SHAKE_HEAVY, FX.SHAKE_DUR_MED)
	FX.spawn_burst_particles(global_position, Color(1.0, 0.95, 0.40, 1.0), 18)
	FX.play_sound("crane_kick")
	emit_signal("attack_started", AttackType.X, 98)


# Run 112 — X-charge DASH release: instead of a stationary spin, the AoE rides
# along with Shino's dash so it sweeps the whole path and hits everyone he tears
# through. Reuses the SpinningCraneKick scene (its body_entered + per-enemy
# de-dupe means each enemy in the path is struck exactly once); parented to
# Shino so it travels, with a lifetime covering the dash burst plus a short tail.
func _spawn_x_dash_strike() -> void:
	if crane_kick_scene == null:
		return
	var sck = crane_kick_scene.instantiate()
	# Lifetime spans the dash burst + a short settle so the landing reads.
	if "lifetime" in sck:
		sck.lifetime = max(dash_timer, DASH_DURATION) + 0.22
	# Hulk Smash keeps its doubled AoE (set BEFORE _ready builds shape/visual).
	if RunState.shino_has("hulk_smash") and "radius" in sck:
		sck.radius = sck.radius * RunState.HULK_SMASH_AOE_MULT
	# Parent to Shino so the hitbox follows the dash; local origin keeps it centred.
	add_child(sck)
	sck.position = Vector2.ZERO
	FX.screen_shake(FX.SHAKE_MEDIUM, FX.SHAKE_DUR_SHORT)
	FX.spawn_burst_particles(global_position, Color(0.55, 0.92, 1.0, 1.0), 14)
	FX.play_sound("crane_kick")
	emit_signal("attack_started", AttackType.X, 98)


# -------------------------------------------------------
# Kamehameha (§8.2.1 A-charge — line-AoE beam with auto-aim)
# -------------------------------------------------------
func _start_kamehameha() -> void:
	state = State.BEAMING
	kamehameha_timer = KAMEHAMEHA_LOCKOUT
	velocity = Vector2.ZERO
	var aim_dir: Vector2 = _pick_kamehameha_aim_dir()
	facing = aim_dir
	if kamehameha_scene == null:
		print("[Player] KamehamehaBeam.tscn not loaded — skip beam")
		state = State.IDLE
		return
	var beam = kamehameha_scene.instantiate()
	var parent = get_parent()
	if parent:
		parent.add_child(beam)
		beam.global_position = global_position + aim_dir * 16.0
		if beam.has_method("launch"):
			beam.launch(aim_dir)
	FX.screen_shake(FX.SHAKE_MEDIUM, FX.SHAKE_DUR_MED)
	FX.spawn_burst_particles(global_position + aim_dir * 16.0, Color(0.40, 0.95, 1.0, 1.0), 14)
	FX.play_sound("kamehameha_fire")
	emit_signal("attack_started", AttackType.A, 97)


func _pick_kamehameha_aim_dir() -> Vector2:
	var best_dir: Vector2 = facing
	var best_score: float = INF
	var cone_half_rad: float = deg_to_rad(KAMEHAMEHA_CONE_HALF_DEG)
	var enemies: Array = get_tree().get_nodes_in_group("enemy")
	for e in enemies:
		if e == null or not is_instance_valid(e):
			continue
		var to: Vector2 = e.global_position - global_position
		var dist: float = to.length()
		if dist < 1.0 or dist > KAMEHAMEHA_MAX_RANGE:
			continue
		var dir: Vector2 = to / dist
		var angle_diff: float = abs(facing.angle_to(dir))
		if angle_diff > cone_half_rad:
			continue
		var bias: float = 1.0 + (angle_diff / cone_half_rad) * 0.2
		var score: float = dist * bias
		if score < best_score:
			best_score = score
			best_dir = dir
	return best_dir


# Called by externally-spawned hitbox scenes (SpinningCraneKick, KamehamehaBeam)
func _on_charge_hits_dealt(damage_per_hit: int, hit_count: int) -> void:
	for i in range(hit_count):
		_on_hit_connected(damage_per_hit)


# -------------------------------------------------------
# Ult — Final Ki Blast (§8.2.3 — screen-wide AoE)
# -------------------------------------------------------
# Run 27f — Ultimate boon cast-time effects (Combat_Boons §8 per-family Ults).
# Per-hit Ult payloads (statuses) live in _apply_family_statuses_on_hit's
# is_ult branch; this handles the cast-moment arms. Ownership check covers
# both heroes (whichever ninja bought the Ult boon empowers the cast).
func _apply_ult_boon_cast_effects() -> void:
	# Run 132 — narrow cast payloads to the CASTER's boons. Rule: the ulting hero's
	# boons empower THEIR ult (mirrors Run 131's per-hit narrowing). Team-wide EFFECTS
	# (harvest_moon heal-both, bulwark_strike shield-both) still apply to both heroes,
	# but only TRIGGER when the caster owns the boon. Self-buff payloads (Titan's Roar,
	# Bullseye Finale, Bunch Bloom) land on the caster (self) — no cross-hero leak.
	var _who: String = "bea" if is_in_group("bea") else "shino"
	var owns := func(id: String) -> bool: return RunState.char_has(id, _who)
	# Harvest Moon (Apple): both heroes heal 25% max HP on cast.
	if owns.call("harvest_moon"):
		heal_external(max(1, int(round(float(get_effective_max_hp()) * 0.25))))
		for b in get_tree().get_nodes_in_group("bea"):
			if b.has_method("heal_external") and b.has_method("get_effective_max_hp"):
				b.heal_external(max(1, int(round(float(b.get_effective_max_hp()) * 0.25))))
	# Bulwark Strike (Coconut): both heroes gain max overshells.
	if owns.call("bulwark_strike"):
		grant_overshield_external(3)
		for b in get_tree().get_nodes_in_group("bea"):
			if b.has_method("grant_overshield_external"):
				b.grant_overshield_external(3)
	# Titan's Roar (Broccoli): +20% all damage for 5s post-cast.
	if owns.call("titans_roar"):
		_titans_roar_window = 5.0
	# Bullseye Finale (Carrot): +25% crit chance for 10s post-cast.
	if owns.call("bullseye_finale"):
		_bullseye_finale_window = 10.0
	# Bunch Bloom (Grape): combo counter instantly set to max (30) — caster's meter.
	if owns.call("bunch_bloom_ult"):
		combo_count = 30
		RunState.set_combo(_who, combo_count)   # Run 132 — mirror to the caster's meter
		emit_signal("combo_count_changed", combo_count)


func _can_fire_ult() -> bool:
	# Tide Master: -20% ult cost. (Run 150b — holder-only.)
	var effective_cost: int = max(1, int(round(float(ULT_CHI_COST) * RunState.tide_master_ult_cost_mult("bea" if is_in_group("bea") else "shino"))))
	if current_chi < effective_cost:
		return false
	match state:
		State.IDLE, State.MOVING, State.ATTACKING:
			return true
		_:
			return false


func _start_ult() -> void:
	_reset_attack_combo()
	# Tide Master: pay reduced cost, then refund 25% of base cost. (Run 150b — holder-only.)
	var _tm_who: String = "bea" if is_in_group("bea") else "shino"
	var ult_pay: int = max(1, int(round(float(ULT_CHI_COST) * RunState.tide_master_ult_cost_mult(_tm_who))))
	current_chi = max(0, current_chi - ult_pay)
	var refund: int = RunState.tide_master_refund(ULT_CHI_COST, _tm_who)
	if refund > 0:
		current_chi = min(get_effective_max_chi(), current_chi + refund)
	# Run 136 — Shell Wall retired: redundant with Bulwark Strike (Ult slot),
	# which already grants max overshells to both heroes on cast.
	emit_signal("chi_changed", current_chi, MAX_CHI)
	state = State.ULT_CASTING
	# Run 150 (Bruno fix 11) — freeze the partner for the whole cinematic.
	RunState.ult_freeze_caster = "bea" if is_in_group("bea") else "shino"
	RunState.double_ult_queued = false
	# Coroutine drives lifecycle — _tick_ult() is a no-op while ult_timer == 0.
	ult_timer = 0.0
	ult_in_dizzy = false
	velocity = Vector2.ZERO
	emit_signal("ult_fired")
	_apply_ult_boon_cast_effects()
	_ult_freeze_targets.clear()
	FX.play_sound("ult_fire", 1.2)
	_spawn_ult_flash()
	# Run 154 Batch 6 — Player.gd is only ever a Shino instance (it adds itself to
	# group "player", never "bea"), so the old is_in_group("bea") dispatch to
	# _run_bea_ult was unreachable. Bea hosts her own live ult in BeaAI.gd
	# (_start_ult/_tick_ult, blink-position mechanism). Call Shino's directly.
	_run_shino_ult()


func _tick_ult(delta: float) -> void:
	if state != State.ULT_CASTING:
		return
	if ult_timer > 0.0:
		ult_timer -= delta
		if ult_timer <= 0.0:
			if not ult_in_dizzy:
				ult_in_dizzy = true
				ult_timer = ULT_DIZZY_DURATION
			else:
				ult_in_dizzy = false
				state = State.IDLE
				for e in _ult_freeze_targets:
					if is_instance_valid(e):
						e.process_mode = Node.PROCESS_MODE_INHERIT
				_ult_freeze_targets.clear()
				# Run 150 (Bruno fix 11) — release the partner freeze.
				if RunState.ult_freeze_caster == ("bea" if is_in_group("bea") else "shino"):
					RunState.ult_freeze_caster = ""


func _spawn_ult_flash() -> void:
	# Quick full-screen flash on ult activation — fades in 0.5 s.
	var layer := CanvasLayer.new()
	layer.layer = 50
	get_tree().current_scene.add_child(layer)
	var flash := ColorRect.new()
	flash.color = Color(1.0, 0.97, 0.85, 0.85)
	flash.anchor_right = 1.0
	flash.anchor_bottom = 1.0
	flash.offset_left = 0.0
	flash.offset_top = 0.0
	flash.offset_right = 0.0
	flash.offset_bottom = 0.0
	layer.add_child(flash)
	var tw := create_tween()
	tw.tween_property(flash, "color:a", 0.0, 0.50)
	tw.tween_callback(Callable(layer, "queue_free"))


# _run_bea_ult removed (Batch 6): unreachable dead duplicate — Player.gd is never
# in group "bea"; Bea's live ult lives in BeaAI.gd. See REFACTOR_HANDOFF Batch 6.


# -------------------------------------------------------
# Shino's Ultimate: Final Ki Blast (GDD §8.2.3)
# -------------------------------------------------------
# Wind-up ki aura → beam extends and sweeps CCW three full rotations →
# Shino stumbles dizzy as the energy dissipates (flavor only, GDD §8.2.3).
func _run_shino_ult() -> void:
	# Freeze all enemies up front.
	for e in get_tree().get_nodes_in_group("enemy"):
		if e == null or not is_instance_valid(e) or not e.has_method("take_damage"):
			continue
		e.process_mode = Node.PROCESS_MODE_DISABLED
		_ult_freeze_targets.append(e)

	# ---- Wind-up ----
	_spawn_shino_ki_windup()
	FX.screen_shake(FX.SHAKE_MEDIUM, FX.SHAKE_DUR_MED)
	await get_tree().create_timer(SHINO_ULT_WINDUP).timeout
	if state != State.ULT_CASTING:
		return

	# ---- Spinning beam ----
	var beam_pivot: Node2D = _spawn_shino_spin_beam()
	get_tree().current_scene.add_child(beam_pivot)
	beam_pivot.global_position = global_position

	# Tween rotates the pivot CCW (negative) — 3 full turns over SHINO_ULT_SPIN_DUR.
	var spin_tw: Tween = create_tween()
	spin_tw.tween_property(beam_pivot, "rotation",
		beam_pivot.rotation - TAU * float(SHINO_ULT_NUM_SPINS),
		SHINO_ULT_SPIN_DUR).set_trans(Tween.TRANS_LINEAR)

	# Damage pulse once per spin (beam sweeps past every enemy each rotation).
	var pulse_interval: float = SHINO_ULT_SPIN_DUR / float(SHINO_ULT_NUM_SPINS)
	for spin_i in range(SHINO_ULT_NUM_SPINS):
		# Wait for midpoint of this spin so the hit lands when beam has ~swept past.
		await get_tree().create_timer(pulse_interval * 0.5).timeout
		if state != State.ULT_CASTING:
			break
		for e in _ult_freeze_targets:
			if not is_instance_valid(e):
				continue
			if e.has_method("is_alive") and not e.is_alive():
				continue
			var dir: Vector2 = (e.global_position - global_position).normalized()
			if dir.length() < 0.01:
				dir = Vector2.RIGHT
			# Apply family statuses only on the first pass.
			if spin_i == 0:
				_apply_family_statuses_on_hit(e, false, false, false, false, true)
			var was_alive: bool = (not e.has_method("is_alive")) or e.is_alive()
			e.set_meta("last_damager", "shino"); e.take_damage(_scale_damage(ULT_BASE_DAMAGE, true), dir)   # Run 134 — killer attribution (fix 5)
			if was_alive and e.has_method("is_alive") and not e.is_alive():
				_apply_charge_kill_heal()
			FX.spawn_burst_particles(e.global_position, Color(0.30, 0.85, 1.0, 1.0), 10)
		FX.screen_shake(FX.SHAKE_HEAVY, FX.SHAKE_DUR_SHORT)
		# Wait the second half of this spin interval.
		await get_tree().create_timer(pulse_interval * 0.5).timeout

	# Beam fade-out.
	if is_instance_valid(beam_pivot):
		var fade_tw: Tween = create_tween()
		fade_tw.set_parallel(true)
		fade_tw.tween_property(beam_pivot, "modulate:a", 0.0, 0.30)
		fade_tw.set_parallel(false)
		fade_tw.tween_callback(Callable(beam_pivot, "queue_free"))

	FX.screen_shake(FX.SHAKE_ULT, FX.SHAKE_DUR_LONG)
	await get_tree().create_timer(0.30).timeout

	# Unfreeze survivors.
	for e in _ult_freeze_targets:
		if is_instance_valid(e):
			e.process_mode = Node.PROCESS_MODE_INHERIT
	_ult_freeze_targets.clear()

	# Dizzy stumble (GDD §8.2.3 — flavor only, no gameplay cost).
	await _do_ult_dizzy()
	state = State.IDLE


# Shared dizzy tail: brief position wobble + orbiting stars above head.
func _do_ult_dizzy() -> void:
	ult_in_dizzy = true
	_spawn_dizzy_stars()
	# Stumble: lurch in the opposite of last facing direction, then recover.
	var stagger: Vector2 = Vector2(-float(_last_h_dir), 0.0) * 8.0
	var origin: Vector2 = global_position
	var tw: Tween = create_tween()
	tw.tween_property(self, "global_position", origin + stagger,
		ULT_DIZZY_DURATION * 0.40).set_trans(Tween.TRANS_SINE)
	tw.tween_property(self, "global_position", origin,
		ULT_DIZZY_DURATION * 0.60).set_trans(Tween.TRANS_SINE)
	await get_tree().create_timer(ULT_DIZZY_DURATION).timeout
	ult_in_dizzy = false


# _spawn_bea_blink_flash / _spawn_bea_flourish_pulse removed (Batch 6): dead
# duplicates that only _run_bea_ult (also removed) called. See REFACTOR_HANDOFF.


# -------------------------------------------------------
# Shino ult VFX helpers
# -------------------------------------------------------

# Three expanding ki-energy rings during wind-up phase.
func _spawn_shino_ki_windup() -> void:
	var parent: Node = get_tree().current_scene
	if parent == null:
		return
	for ring_i in range(3):
		var ring := Node2D.new()
		ring.global_position = global_position
		ring.z_index = 6
		parent.add_child(ring)
		var line := Line2D.new()
		line.width = 5.0 - ring_i * 1.5
		line.default_color = Color(0.30, 0.85, 1.0, 0.75 - ring_i * 0.15)
		line.joint_mode = Line2D.LINE_JOINT_ROUND
		line.closed = true
		var pts: PackedVector2Array = PackedVector2Array()
		for si in range(20):
			var a: float = TAU * float(si) / 20.0
			pts.append(Vector2(cos(a), sin(a)) * 20.0)
		line.points = pts
		ring.add_child(line)
		var delay: float = ring_i * 0.10
		var dur: float = SHINO_ULT_WINDUP - delay
		var tw: Tween = create_tween()
		if delay > 0.0:
			tw.tween_interval(delay)
		tw.set_parallel(true)
		tw.tween_property(ring, "scale", Vector2(6.0, 6.0), dur) \
			.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
		tw.tween_property(line, "default_color:a", 0.0, dur)
		tw.set_parallel(false)
		tw.tween_callback(Callable(ring, "queue_free"))


# Builds the spinning-beam Node2D (outer glow + inner core Line2D).
# Caller adds it to the scene and sets global_position before rotating.
func _spawn_shino_spin_beam() -> Node2D:
	var pivot := Node2D.new()
	pivot.z_index = 7
	# Start the beam pointing in Shino's current facing direction.
	pivot.rotation = facing.angle() if facing.length() > 0.01 else 0.0

	# Outer translucent glow.
	var glow := Line2D.new()
	glow.width = SHINO_ULT_BEAM_WIDTH
	glow.default_color = Color(0.20, 0.75, 1.0, 0.45)
	glow.begin_cap_mode = Line2D.LINE_CAP_ROUND
	glow.end_cap_mode  = Line2D.LINE_CAP_ROUND
	glow.points = PackedVector2Array([Vector2.ZERO, Vector2(SHINO_ULT_BEAM_LEN, 0.0)])
	pivot.add_child(glow)

	# Bright inner core.
	var core := Line2D.new()
	core.width = SHINO_ULT_BEAM_WIDTH * 0.38
	core.default_color = Color(0.85, 0.97, 1.0, 0.95)
	core.begin_cap_mode = Line2D.LINE_CAP_ROUND
	core.end_cap_mode  = Line2D.LINE_CAP_ROUND
	core.points = PackedVector2Array([Vector2.ZERO, Vector2(SHINO_ULT_BEAM_LEN, 0.0)])
	pivot.add_child(core)

	return pivot


# Small yellow dots that orbit above the character's head during the dizzy tail.
func _spawn_dizzy_stars() -> void:
	var orbit_host := Node2D.new()
	orbit_host.z_index = 10
	orbit_host.position = Vector2(0.0, -36.0)   # local offset: above player head
	add_child(orbit_host)   # child of player — follows automatically

	var n_stars: int = 5
	var orbit_r: float = 18.0
	for si in range(n_stars):
		var dot := Node2D.new()
		var a: float = TAU * float(si) / float(n_stars)
		dot.position = Vector2(cos(a), sin(a)) * orbit_r
		var poly := Polygon2D.new()
		poly.color = Color(1.0, 0.95, 0.30, 1.0)
		var pts: PackedVector2Array = PackedVector2Array()
		for pi in range(8):
			var pa: float = TAU * float(pi) / 8.0
			pts.append(Vector2(cos(pa), sin(pa)) * 4.0)
		poly.polygon = pts
		dot.add_child(poly)
		orbit_host.add_child(dot)

	# Spin the orbit host 1.5 full turns over the dizzy duration, then free it.
	var tw: Tween = create_tween()
	tw.tween_property(orbit_host, "rotation", TAU * 1.5, ULT_DIZZY_DURATION) \
		.set_trans(Tween.TRANS_LINEAR)
	tw.tween_callback(Callable(orbit_host, "queue_free"))


# -------------------------------------------------------
# Per-frame timer ticks for the new charge-release lockouts
# -------------------------------------------------------
func _tick_charge_release_lockouts(delta: float) -> void:
	if state == State.CRANE_KICKING and crane_kick_timer > 0.0:
		crane_kick_timer -= delta
		if crane_kick_timer <= 0.0:
			state = State.IDLE
	if state == State.BEAMING and kamehameha_timer > 0.0:
		kamehameha_timer -= delta
		if kamehameha_timer <= 0.0:
			state = State.IDLE


# -------------------------------------------------------
# Run 13 — Revive system (standing partner side) moved to HeroBase (Batch 4).
# Moved: _tick_revive_attempt, _start_channel_revive, _tick_channel_revive,
# _cancel_channel_revive, _find_downed_partner, _show_interact_prompt,
# _hide_interact_prompt. Shino's non-cancellable state set + channel-start combat
# teardown are supplied via the Batch 4 child overrides (_revive_attempt_locked /
# _cleanup_combat_on_channel_start).
# -------------------------------------------------------


# -------------------------------------------------------
# Onion Layered Defense — passive poison aura
# -------------------------------------------------------
# -------------------------------------------------------
# Juicebox of Youth — Apple L2 Legendary
# -------------------------------------------------------
# GDD: spawns a Juice Box pickup near Shino every 10s.
# Any ninja picks it up: BOTH ninjas regen 1 HP/sec for 10s.
# The pickup node is a simple colored sphere with interaction zone.
func _tick_juicebox(delta: float) -> void:
	if not RunState.juicebox_of_youth_taken:
		return
	if current_hp <= 0:
		return
	_juicebox_spawn_timer -= delta
	if _juicebox_spawn_timer > 0.0:
		return
	_juicebox_spawn_timer = 10.0
	_spawn_juice_box()


func _spawn_juice_box() -> void:
	var parent: Node = get_parent()
	if parent == null:
		return
	# Spawn position: slightly offset from Shino so it's reachable but not under his feet.
	var offset: Vector2 = Vector2(randf_range(-48.0, 48.0), randf_range(-32.0, -64.0))
	var box := Node2D.new()
	box.name = "JuiceBox"
	box.global_position = global_position + offset
	box.z_index = 6
	parent.add_child(box)

	# Visual: glowing apple-green circle.
	var ring := Line2D.new()
	ring.width = 3.0
	ring.default_color = Color(0.45, 0.90, 0.35, 0.90)
	var n: int = 20
	for i in range(n + 1):
		var a: float = TAU * float(i) / float(n)
		ring.add_point(Vector2(cos(a), sin(a)) * 12.0)
	box.add_child(ring)
	var icon_lbl := Label.new()
	icon_lbl.text = "🍎"
	icon_lbl.add_theme_font_size_override("font_size", 20)
	icon_lbl.position = Vector2(-12, -20)
	box.add_child(icon_lbl)

	# Interaction zone.
	var zone := Area2D.new()
	zone.collision_layer = 0
	zone.collision_mask = 2
	zone.monitoring = true
	var shape := CircleShape2D.new()
	shape.radius = 24.0
	var cs := CollisionShape2D.new()
	cs.shape = shape
	zone.add_child(cs)
	box.add_child(zone)

	# Pulse + despawn after 10s.
	var tw: Tween = box.create_tween().set_loops()
	tw.tween_property(ring, "modulate:a", 0.35, 0.5)
	tw.tween_property(ring, "modulate:a", 1.0, 0.5)
	get_tree().create_timer(10.0).timeout.connect(func():
		if is_instance_valid(box):
			box.queue_free())

	# On pickup: apply 10s regen to both ninjas.
	zone.body_entered.connect(func(body: Node):
		if not (body.is_in_group("player") or body.is_in_group("bea")):
			return
		if not is_instance_valid(box):
			return
		tw.kill()
		box.queue_free()
		FX.spawn_burst_particles(box.global_position, Color(0.45, 0.90, 0.35, 1.0), 14)
		FX.play_sound("apple_pie_eat", 0.80)
		# Apply 10s regen to both characters.
		_apply_juicebox_regen()
	)


var _juicebox_regen_timer: float = 0.0
var _juicebox_regen_accum: float = 0.0

func _apply_juicebox_regen() -> void:
	# Start/refresh 10s regen for both heroes.
	_juicebox_regen_timer = 10.0
	_juicebox_regen_accum = 0.0
	# Trigger on Bea too.
	for bea in get_tree().get_nodes_in_group("bea"):
		if is_instance_valid(bea) and bea.has_method("start_juicebox_regen"):
			bea.start_juicebox_regen()


func _tick_juicebox_regen(delta: float) -> void:
	if _juicebox_regen_timer <= 0.0:
		return
	_juicebox_regen_timer -= delta
	_juicebox_regen_accum += 1.0 * delta   # 1 HP/sec
	if _juicebox_regen_accum >= 1.0:
		var heal: int = int(floor(_juicebox_regen_accum))
		_juicebox_regen_accum -= float(heal)
		var max_hp_eff: int = get_effective_max_hp()
		if current_hp < max_hp_eff:
			current_hp = min(max_hp_eff, current_hp + heal)
			emit_signal("hp_changed", current_hp, max_hp_eff)


func _tick_layered_defense(delta: float) -> void:
	if not RunState.layered_defense_taken:
		return
	if current_hp <= 0:
		return
	_layered_defense_tick -= delta
	if _layered_defense_tick > 0.0:
		return
	_layered_defense_tick = LAYERED_DEFENSE_INTERVAL
	var hit_count: int = 0
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		if global_position.distance_to(e.global_position) > LAYERED_DEFENSE_RADIUS:
			continue
		var es: Variant = e.get("status") if e.has_method("get") else null
		if es != null and es.has_method("apply"):
			# Apply 1 Poison stack (4s). Duration extended by Chronic Reek.
			var dur: float = 4.0
			if RunState.chronic_reek_taken:
				dur *= 1.5
			es.apply("poison", dur, 1)
			hit_count += 1
	# Visual: subtle green wisp ring around Shino when the aura pulses.
	if hit_count > 0:
		FX.spawn_hit_particles(global_position, Color(0.50, 0.85, 0.25, 0.70), 5)


# -------------------------------------------------------
# Watermelon Hydration — Chi/sec in combat, ramps after 8s sustained (Run 26)
# -------------------------------------------------------
# _tick_sensei_chi_regen (+ _sensei_chi_accum) moved to HeroBase (Batch 5).


func _tick_hydration(delta: float) -> void:
	# Run 150b (Bruno ruling) — holder-only: Shino regens Chi only if HE picked it.
	if not RunState.shino_has("hydration"):
		return
	if current_hp <= 0:
		return
	# "In combat" = at least one live enemy within 400px (Bruno ruling 2026-07-23:
	# unified both heroes to 400 — was Shino 320 / Bea 480).
	var in_combat: bool = false
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		if global_position.distance_to(e.global_position) <= 400.0:
			in_combat = true
			break
	if in_combat:
		_hydration_combat_timer = min(_hydration_combat_timer + delta, HYDRATION_RAMP_TIME)
	else:
		_hydration_combat_timer = max(0.0, _hydration_combat_timer - delta * 2.0)
	if _hydration_combat_timer <= 0.0:
		_hydration_tick_accum = 0.0
		return
	var rate: float = HYDRATION_RAMP_RATE if _hydration_combat_timer >= HYDRATION_RAMP_TIME else HYDRATION_BASE_RATE
	_hydration_tick_accum += rate * delta
	if _hydration_tick_accum >= 1.0:
		var gain: int = int(floor(_hydration_tick_accum))
		_hydration_tick_accum -= float(gain)
		var cap: int = get_effective_max_chi()
		if current_chi < cap:
			current_chi = min(cap, current_chi + gain)
			emit_signal("chi_changed", current_chi, cap)
