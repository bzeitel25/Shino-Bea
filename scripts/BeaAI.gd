extends "res://scripts/HeroBase.gd"

const ICE = preload("res://scripts/IceField.gd")   # Frostpeak slippery-ice glide

# ============================================================
# BeaAI.gd — Bea (The Blade Ninja) — Phase 6 stub
# ============================================================
# Two modes:
#   AI mode (default): follows Shino, throws a Kunai at nearest
#   enemy every AI_ATTACK_INTERVAL seconds. Tier 1/2 behavior
#   per GDD §8.5 ("light ranged poking, stays close to partner").
#
#   Player-controlled mode: WASD movement + SPACE dash + J/L Kunai throw.
#   (Full Bea kit — katana combo, whirl, leap, fan — is a later task.)
#
# NOTE: Bea's ranged is a thrown Kunai, NOT a Ki Blast.
# Ki Blast / Kamehameha = Shino's signature ranged kit only.
#
# Hot-swap: double-tap Q (keyboard) or LB (joypad button 4).
#   Toggles player_controlled on both Bea and Shino.
#   Shino's Player.gd must expose set_player_controlled(bool).
#
# Collision layer: Layer 2 (Player) — enemy hitboxes and enemy AI
# will target Bea just like Shino, which is correct co-op behavior.
#
# Bea is purple (placeholder art).
# ============================================================

@export var max_hp: int = 80
@export var move_speed: float = 230.0

# current_hp, current_chi moved to HeroBase (Batch 3); current_hp reset to
# max_hp at _ready top.
const MAX_CHI: int = 100

const CHI_PER_DAMAGE_DEALT: float = 0.5
const CHI_PER_DAMAGE_TAKEN: float = 1.5

# --- AI behavior tuning ---
const AI_FOLLOW_DIST_TARGET: float = 72.0    # Preferred spacing from Shino
const AI_FOLLOW_DIST_STOP: float = 40.0      # Back-off threshold (don't crowd)
const AI_ATTACK_RANGE: float = 310.0         # Max range Bea will throw from
const AI_ATTACK_INTERVAL: float = 2.5        # Seconds between Kunai throws (AI mode)  [LEGACY — overridden per-tier via RunState.AI_TIER_TABLE]
var _attack_timer: float = 1.0               # Start at 1s so she doesn't throw instantly

# --- Run 64c — Bea "dancer" orbit. She doesn't stand and trade blows; she
# swirls around her target in fluid circles (strong tangential motion + soft
# radius correction), reversing direction every few seconds like a dancer
# turning. The radius "breathes" via a slow sine so the path swirls instead of
# tracing a rigid ring. Orbit lives in the AI_FOLLOW movement tick — i.e. the
# gaps between/around her quick katana swings.
const BEA_ORBIT_RADIUS: float = 46.0         # preferred circling distance (inside katana reach 64)
var _bea_orbit_sign: float = 1.0             # +1 / -1 = clockwise / counter-clockwise swirl
var _bea_orbit_flip_timer: float = 3.0       # seconds until the next direction reversal

# --- Run 61: 5-tier AI behavior support ---
# Per-tier cadence for charge-up attempts. Resets to a randomised window after
# each attempt (success or skip) so partner AI doesn't lockstep with Shino.
var _ai_charge_try_timer: float = 4.0
# Last melee-swing time — used to keep the AI from spamming katana taps when
# crowded. Goes hand in hand with the per-tier melee_chance.
var _ai_melee_cd: float = 0.0
# Hazard avoidance heading bias — recomputed each tick.
var _ai_hazard_push: Vector2 = Vector2.ZERO
# Run 63 — smoothed AI heading. The follow/avoid blend is lerped toward this
# each frame so clustered traps can't make her vibrate in place; higher rate =
# snappier turns, lower = glidier. Zero = uninitialised (snaps on first move).
const AI_STEER_SMOOTH_RATE: float = 14.0
var _ai_steer_smoothed: Vector2 = Vector2.ZERO

# Run 69 — STUCK-ON-WALL escape. Hazard steering only rounds trap zones, not solid
# geometry, so chasing an enemy into a corner could pin the AI against a wall
# (wants to move, but move_and_slide eats the velocity). This is a position
# sensor: if she's trying to move yet barely advances (< AI_STUCK_MIN_STEP px per
# physics frame) for AI_STUCK_TIME, she commits a tangential detour for
# AI_UNSTICK_BURST seconds to slide around the obstacle, flipping sides each retry.
const AI_STUCK_MIN_STEP: float = 0.65   # px/frame; below this while trying to move = grinding
const AI_STUCK_TIME: float = 0.40       # seconds of grinding before an escape engages
const AI_UNSTICK_BURST: float = 1.00    # seconds committed to one detour side before flipping
var _ai_last_pos: Vector2 = Vector2.ZERO
var _ai_stuck_timer: float = 0.0
var _ai_unstick_timer: float = 0.0
var _ai_unstick_dir: Vector2 = Vector2.ZERO
var _ai_unstick_side: float = 1.0
var _ai_unstick_fails: int = 0          # consecutive failed bursts → peel further off the wall

# --- Apple DD revive HoT state (Run 12 — Cider Mercy, mirrors Player.gd) ---
var _dd_hot_pct_per_sec: float = 0.0
var _dd_hot_remaining:   float = 0.0
var _dd_hot_accum:       float = 0.0
# --- Baked Apple finisher HoT (Run 27 — mirrors Player.gd _start_baked_apple_hot) ---
var _baked_apple_hot_remaining: float = 0.0
var _baked_apple_hot_accum:     float = 0.0
# --- apply_runstate_modifiers HP-delta tracking (mirrors Player.gd) ---
var _last_applied_max_hp: int = 0
# --- Evergreen Step dash-heal state (mirrors Player.gd) ---
var _evergreen_step_active: bool = false
var _evergreen_step_cd_timer: float = 0.0
var _golden_carrot_armed: bool = false   # Run 131 — a dash arms Bea's next combo finisher crit
# Run 132 — Bea ult-boon post-cast windows (mirrors Player.gd _titans_roar_window /
# _bullseye_finale_window). Set by _bea_apply_ult_boon_cast_effects, ticked in _tick_timers.
var _titans_roar_window: float = 0.0     # Titan's Roar +20% all damage post-ult
var _bullseye_finale_window: float = 0.0 # Bullseye Finale +25% crit chance post-ult
const BUNCH_BONUS_RADIUS: float = 192.0  # Grape Bunch Bonus: 2+ enemies within 3m → +25% dmg

# --- Dash (mirrors Shino's tuning: shorter but faster burst) ---
const DASH_SPEED: float = 950.0
const DASH_DURATION: float = 0.09
const DASH_INTERNAL_CD: float = 0.5
const DASH_IFRAME_DURATION: float = 0.13
var dash_timer: float = 0.0
var _dash_ghost_cd: float = 0.0          # afterimage spawn cooldown
const DASH_GHOST_INTERVAL: float = 0.02  # spawn a ghost every ~20ms during dash
var dash_cd_timer: float = 0.0
var dash_charges: int = 1   # Extra Banana grants +1; refills per DASH_INTERNAL_CD
var dash_direction: Vector2 = Vector2.ZERO

# --- Run 150 — Tuber Burrow (Potato B, Bruno fix 3): Bea parity with Player.gd.
# Tap B = normal dash. Hold B = when the dash ends with the button still held
# (+ boon + no internal CD) → Bea dives underground. Same tuning as Shino.
const BURROW_MAX_DURATION:     float = 3.0    # max seconds underground
const BURROW_INTERNAL_CD:      float = 2.5    # CD after rising (standard dash still free)
const BURROW_MOVE_SPEED_MULT:  float = 0.65   # underground move speed fraction
const BURROW_RISE_RADIUS:      float = 80.0   # rise-attack hit radius (px)
const BURROW_RISE_DAMAGE_MULT: float = 1.5    # rise-attack damage multiplier vs base
var burrow_timer: float    = 0.0
var burrow_cd_timer: float = 0.0
var _burrow_mound: Node2D  = null             # placeholder dirt-mound visual node

# --- Run 150b — Vine Lash (Grape B): dash-then-attack window (mirror of Player.gd) ---
var _vine_lash_window: float = 0.0

# --- Combo inter-step delay (mirrors Shino's ATTACK_RECOVERY) ---
const COMBO_STEP_RECOVERY: float = 0.08   # brief pause between hits so each lands distinctly
var _combo_chain_pending: bool = false
var _combo_chain_timer: float = 0.0
var _combo_chain_weapon: String = ""   # "y" or "x" — which weapon to fire next

# --- Invulnerability ---
var is_invulnerable: bool = false
var iframe_timer: float = 0.0

# --- State ---
# Run 13 — DOWNED + REVIVING added for the revive-system rework. DEAD is now
# only reachable via team Game Over (called by RunState.resolve_team_down).
enum State { AI_FOLLOW, PLAYER_CONTROLLED, DASHING, DEAD,
			 BEA_ATTACKING,    # katana / naginata swing lockout
			 BEA_CHARGING,     # holding Y or X or A (charge wind-up)
			 BEA_CHARGED,      # fully charged, waiting for release
			 BEA_DIVING,     # Meteor Dive (X-hold release)
			 BEA_WHIRLING,      # Katana Whirl / Vortex Spin (Y-hold release)
			 BEA_FLURRYING,    # Shuriken Flurry (A-hold release) — brief lockout
			 BEA_ULT_CASTING,  # Thousand Cut Dance cinematic
			 DOWNED,           # Run 13 — knocked down; awaiting partner revive or team-DD
			 REVIVING,         # Run 13 — channel-reviving downed partner (rooted, vulnerable)
			 BEA_BURROWING }   # Run 150 — Tuber Burrow (Potato B) underground state (Bruno fix 3)
var state: State = State.AI_FOLLOW

# --- Run 13 — Revive system constants (mirror Player.gd's constants) ---
const REVIVE_CIRCLE_RADIUS:    float = 90.0
const REVIVE_CHANNEL_RANGE:    float = 40.0
const REVIVE_CIRCLE_RATE:      float = 1.0 / 6.0   # 6s base
const REVIVE_CHANNEL_RATE:     float = 1.0 / 3.0   # 3s channel
const REVIVE_AT_HP_PCT:        float = 0.28
const REVIVE_IFRAME_ON_GET_UP: float = 0.8

# --- Run 13 — Revive system state ---
var rez_fill: float = 0.0                  # 0..1; only relevant while DOWNED
var _channeling_partner: Node = null       # who Bea is reviving
var _revive_circle_node: Node2D = null
var _rez_bar_bg:         ColorRect = null
var _rez_bar_fill:       ColorRect = null
var _interact_prompt:    Label = null
# Which attack button is being charged ("y" | "x" | "a"). Used by tick_charge
# to know which release handler to fire.
var _charging_button: String = ""
var player_controlled: bool = false
var facing: Vector2 = Vector2.LEFT   # Bea faces away from Shino initially

# --- Run 38: Dojo mode (set by Dojo.gd on scene load) ---
# In the dojo the off-duty Bea does NOT follow Shino or throw kunai at the
# training dummy. Instead she walks to dojo_wait_pos (middle of the room)
# and sits there until swapped to.
var dojo_mode: bool = false
var dojo_wait_pos: Vector2 = Vector2.ZERO

# --- Hot-swap (double-tap / 2P tag-in) ---
# 1P: Q+Q (same player) swaps both characters.
# 2P: First Q raises "🙋 TAG IN?" icon on the requesting character.
#     Second Q (either player) confirms — identical to 1P double-tap.
const SWAP_DBL_TAP_WINDOW: float = 1.20   # Run 30: extended to 1.2s so 2P partner has time to respond
var _swap_tap_count: int = 0
var _swap_tap_timer: float = 0.0
var _tag_in_label: Label = null   # "🙋 TAG IN?" visual shown after first Q press
# Run 73 — 2P co-op swap: BOTH players must press swap within the window. These
# track which side has asked so far (cleared on swap or window expiry).
var _swap_shino_req: bool = false
var _swap_bea_req: bool = false

# --- Player shot cooldown (when player-controlled) ---
const PLAYER_SHOT_COOLDOWN: float = 0.12   # Run 49 — A-button kunai cadence (fast tap identity preserved; DPS balanced via lower KUNAI_DAMAGE)
# Run 106 — hold-to-aim auto-fire is throttled SLOWER than the A-button so parking
# the right stick isn't strictly better than manual tapping. Stick-only gate.
const STICK_AUTO_INTERVAL: float = 0.22    # right-stick steady-barrage cadence (s)
const KUNAI_SPEED: float = 1150.0          # Run 30 — much faster flight (was 720)
const KUNAI_DAMAGE: int = 7                # Run 117 balance: was 9 — lower per-hit, bleed makes up the diff
var _player_shot_timer: float = 0.0
# Run 60 — Twin-stick ranged + melee aim snap (player-controlled Bea). Stick fire
# shares _player_shot_timer with the A button so they can't double the fire rate.
const AIM_STICK_DEADZONE: float = 0.5
# Run 105 (Bruno) — melee auto-aim hardening (mirror of Player.gd). Weighted
# best-target by closeness + front-alignment; anything inside strike reach snaps
# unconditionally so combos never finish into empty space. Opposite-push escape
# only applies beyond reach (deliberate backpedal-swing still possible).
const MELEE_SNAP_RANGE: float = 120.0          # was 84 — covers naginata reach + foes drifting in
const MELEE_REACH: float = 96.0                # within this, snap unconditionally (sweep reach)
const MELEE_SNAP_ALIGN_WEIGHT: float = 0.65
const MELEE_SNAP_MIN_ALIGN: float = -0.30
const MELEE_SNAP_OPPOSITE_DOT: float = -0.5
# Run 105 — kunai A-button aim-assist (button throws only; stick stays free-aim).
const KUNAI_AIM_ASSIST_RANGE: float = 520.0
const KUNAI_AIM_ASSIST_CONE_COS: float = 0.15  # cos(~81°) wide forward arc
const KUNAI_AIM_ASSIST_ALIGN_WEIGHT: float = 220.0

# --- Katana combo (Y tap — REVISED Run 115, CrossCode-style) ---
# 4-hit combo: 3 large forward swipes + spinning double-swipe finisher.
# Every hit locks Bea into a small forward step and PUSHES enemies with her
# so they stay in blade range for the next swing (CrossCode Lea feel).
# Hit 4 = double-spin with slightly more forward carry.
const KATANA_COMBO_STEPS: int = 4
const KATANA_DAMAGE: int = 4              # Run 117 balance: was 8 — halved per-swing; fast katana identity = many light cuts + bleed
const KATANA_FINISHER_DAMAGE: int = 6     # Run 117 balance: was 12 — combo total 18 / 0.41s ≈ 43.9 DPS (aligned w/ Shino Y 43.3)
const KATANA_RANGE: float = 62.0          # reach in pixels from center
const KATANA_ARC_DEG: float = 180.0       # hits 1-3 = full forward semicircle
const KATANA_FINISHER_ARC_DEG: float = 360.0   # hit 4 = full circle
const KATANA_SWING_LOCKOUT: float = 0.09  # Run 116: rapid-slash (was 0.14) — clearly faster than naginata 0.25
const KATANA_FINISHER_LOCKOUT: float = 0.14    # spin finisher (was 0.22) — still reads but doesn't drag
const KATANA_COMBO_WINDOW: float = 0.70        # tighter window for fast 4-hit chain
# Per-hit forward glide — small step that carries Bea (and pushed enemies) forward.
const KATANA_HIT_GLIDE: float = 14.0      # px per swipe (hits 1-3) — small CrossCode-style step
const KATANA_FINISHER_GLIDE: float = 22.0 # hit 4 spin — slightly more carry than regular swipes
# Enemy push: on each hit, nudge the struck enemy forward so it stays in range.
const KATANA_ENEMY_PUSH: float = 16.0     # px pushed per hit (hits 1-3)
const KATANA_FINISHER_PUSH: float = 20.0  # hit 4 push — a bit more

# --- Charge / Whirling Strike (Y hold, per GDD §8.2.2) ---
# Run 112 — charge timing read from RunState so Bea matches Shino exactly for
# every skill (single source of truth).
var CHARGE_DETECT: float = RunState.CHARGE_DETECT   # hold threshold to arm a charge
var CHARGE_WINDUP: float = RunState.CHARGE_WINDUP   # time from arm→fully charged (mirrors Shino)
const WHIRL_DURATION: float = 0.55      # total whirl move time
const WHIRL_SPEED: float = 87.0         # forward px/s (~1.5 body lengths @ 32px over 0.55s)
const WHIRL_TICK_INTERVAL: float = 0.12 # damage tick frequency
const WHIRL_DAMAGE: int = 9             # Run 117 balance: was 16 — vortex DPS 30.8 (vs Shino Pegasus 27.9). Used by _fire_lunge_spin.
const WHIRL_RADIUS: float = 46.0        # 360° AoE radius around Bea during whirl

# --- Naginata combo (X tap — REVISED Run 115) ---
# Thrust → 180° Sweep → 360° Spin+Slam. 3-hit total (slower, hits harder).
# Mirrors Shino's 4-hit fast / 3-hit slow pattern.
const NAGINATA_COMBO_STEPS: int = 3
const NAGINATA_THRUST_DAMAGE: int = 10    # step 0 — single poke (was 8 per thrust ×2; now one heavier thrust)
const NAGINATA_SWEEP_DAMAGE: int  = 12    # step 1 — wide sweep (bumped from 10)
const NAGINATA_SPIN_DAMAGE: int = 15      # step 2 part 1 — 360° spin around Bea (bumped from 13)
const NAGINATA_SLAM_DAMAGE: int = 22      # step 2 part 2 — forward slam finisher (bumped from 20)
# Reach / shape per step:
const NAGINATA_THRUST_RANGE: float = 110.0   # piercing line — a tad past sweep reach (96) to really poke
const NAGINATA_THRUST_WIDTH: float = 34.0    # Run 33: widened from 12 — old needle-line whiffed constantly
const NAGINATA_POKE_LOCK_HALF_DEG: float = 75.0  # Run 33: poke aim-assist — snap facing to nearest enemy in this front cone
const NAGINATA_SWEEP_RANGE: float = 96.0     # Run 32: double katana (48×2=96px) — long polearm sweep
const NAGINATA_SWEEP_ARC_DEG: float = 180.0  # wide horizontal AoE — full half-circle in front
# Run 33 — 4th hit reworked: fast 360° spin around Bea at sweep reach (uniform
# with hits 1-3). Run 34 — forward slam re-added as part 2, landing at the end
# of the spin: spin (immediate) → slam in front (deferred).
const NAGINATA_SLAM_DIST: float = 88.0    # Run 36: slam at the END of the blade's reach — just shy of the 96px spin perimeter (was 44)
const NAGINATA_SLAM_RADIUS: float = 72.0  # slam-point AoE circle radius
const NAGINATA_SLAM_FOLLOW: float = 0.10  # follow-through after the spin where the slam lands
const NAGINATA_SPIN_LOCKOUT_MULT: float = 1.2     # Run 49 — sweep/spin a touch more deliberate (was 1.1)
const NAGINATA_THRUST_LOCKOUT_MULT: float = 0.85  # snappier pokes for combo flow
const NAGINATA_SWING_LOCKOUT: float = 0.25   # Run 49 — slowed from 0.20: it was out-spamming the whole kit; sweeps read slower + bigger inter-hit gap
const NAGINATA_COMBO_WINDOW: float = 1.00    # tap window before combo resets

# --- Katana Whirl / Vortex Spin (Y hold) — Run 116 rework ---
# Bea lunges forward while spinning, pulling nearby enemies into her vortex.
# Caught enemies are stunned + dragged with her, then tossed in front at the end
# so she can follow up with Y combo.
const VORTEX_SPIN_DURATION: float = 0.55     # total spin time (matches old lunge duration)
const VORTEX_PULL_RADIUS: float = 120.0      # enemies within this get sucked in
const VORTEX_PULL_SPEED: float = 260.0       # px/s pull toward center
const VORTEX_INNER_RADIUS: float = 18.0      # stop pulling closer than this (clump, not overlap)
const VORTEX_TOSS_DIST: float = 72.0         # how far in front enemies land after spin
const VORTEX_TOSS_SPREAD: float = 24.0       # lateral scatter so they don't stack exactly
const VORTEX_TOSS_DURATION: float = 0.22     # tween time for the forward toss (smooth, not teleport)
const VORTEX_TICK_INTERVAL: float = 0.14     # damage tick frequency while spinning
const VORTEX_POST_INVULN: float = 0.18       # brief i-frames after spin ends for repositioning
const METEOR_LEAP_DIST: float = 288.0        # forward travel distance (unchanged)
# Legacy aliases kept for tornado visuals.
const METEOR_LEAP_DURATION: float = VORTEX_SPIN_DURATION
const LUNGE_SPIN_RADIUS_1: float = 80.0
const LUNGE_SPIN_RADIUS_2: float = VORTEX_PULL_RADIUS
# ── Meteor Dive (new X charge) ──────────────────────────────────────────────
# Bea leaps into the air, locks on to the nearest enemy within range, then
# dives down onto them for a meteor-crash AoE. If no target, hops forward.
const METEOR_DIVE_LOCK_RANGE: float = 336.0   # Run 49b — -20% (was 420; was 280 pre-49): snap + max leap range
const METEOR_DIVE_ASCENT_DUR: float = 0.22    # Run 49b — snappier hop (was 0.28)
const METEOR_DIVE_FALL_SPEED: float = 1650.0  # Run 49b — METEOR SLAM (was 750): jump → crash, fast + snappy
const METEOR_DIVE_FALL_SAFETY: float = 0.6    # Run 49b — force-land if the fall somehow stalls (wall snag)
const METEOR_DIVE_AOE_RADIUS: float = 80.0    # crash AoE radius
const METEOR_DIVE_DAMAGE: int = 28            # Run 117 balance: was 48 — single-target divebomb DPS 26.2 (vs Crane 24.3, +8% for single-target commit)
const METEOR_DIVE_NO_TARGET_DIST: float = 136.0 # hop forward when no target found (doubled)
# Run 49 — aimable landing reticle (Bruno): while holding the X charge, a circle
# AoE indicator appears ahead of Bea. It auto-snaps to the nearest target in
# front of her (else 50% of max range), then movement input MOVES the circle
# freely (Bea stands still) to aim the landing. Release dives to the circle.
const METEOR_DIVE_RETICLE_SPEED: float = 600.0   # px/s reticle drag speed
const METEOR_DIVE_RETICLE_DEFAULT_PCT: float = 0.5  # no-target start: 50% of max range ahead

# --- Shuriken Flurry (A hold, per GDD §8.2.2) — Run 39: SHOTGUN CONE ---
# Run 39 (Bruno): still ONE shotgun blast, but with depth — a CONE of stars
# instead of a single wide arc. Tighter 50° fan, 12 shuriken split into 3
# rapid-fire waves (0.05s apart, reads as one blast with body to it). Same
# muzzle velocity and same total power (12 × 8) as Run 30d. Per-shuriken
# angular jitter + speed variance scatter the cloud like the sketch.
const SHURIKEN_WAVES: int = 3
const SHURIKEN_PER_WAVE: int = 4            # 3 × 4 = 12 total, power unchanged
const SHURIKEN_WAVE_INTERVAL: float = 0.05  # waves at t=0 / 0.05 / 0.10 — inside lockout
const SHURIKEN_CONE_HALF_DEG: float = 25.0  # ±25° = 50° fan (was 70°) — tighter per Bruno
const SHURIKEN_DAMAGE: int = 6              # Run 117 balance: was 8 — 12×6=72 total volley; ~6 hit single-target ≈ 41 DPS (vs beam 35 ranged / 71 melee)
const SHURIKEN_SPEED: float = 1350.0        # shotgun muzzle velocity (unchanged)
const SHURIKEN_SPEED_VARIANCE: float = 0.15 # ±15% per shuriken — blast-cloud depth
const SHURIKEN_RANGE: float = 360.0         # shorter than kunai (480) — close-range identity
# BALANCE TOGGLE: 1 = no pierce (despawn on first hit), 0 = pierce all,
# N = pierce N enemies. Applied per-shuriken at spawn in _throw_shuriken —
# future boons should modify the value passed there, nothing else.
const SHURIKEN_PIERCE_LIMIT: int = 1
const FLURRY_LOCKOUT: float = 0.25          # punchy commit window post-blast

# --- Thousand Cut Dance ult (per GDD §8.2.3) ---
const ULT_CHI_COST: int = 100
const ULT_CINEMATIC_DURATION: float = 1.50  # parallel to Shino's (prototype value; spec 5s)
const ULT_DIZZY_DURATION: float = 0.30      # final flourish hold
const ULT_PER_ENEMY_DAMAGE: int = 30        # per blink-hit (user tuning: ult flat 50)
const ULT_FLOURISH_DAMAGE: int = 20         # bonus on finisher → 30+20 = 50 single-target
const ULT_FLOURISH_RADIUS: float = 100.0    # finisher hits anyone within this of last target
const ULT_BLINK_INTERVAL: float = 0.10      # visual cadence of teleports

# --- Katana combo state ---
var katana_step: int = 0
var _swing_timer: float = 0.0
var _combo_window_timer: float = 0.0
# Per-swing glide velocity (applied during swing lockout). Set when a swing starts.
var _swing_glide_velocity: Vector2 = Vector2.ZERO
var _swing_is_finisher: bool = false   # affects rotation reset logic in _tick_swing
var _enemy_pinned_this_swing: bool = false  # Run 116: true when a katana push hit a wall

# --- Naginata combo state (separate step counter, shares _swing_timer + window) ---
var naginata_step: int = 0
var _naginata_combo_timer: float = 0.0
# --- Run 34 — Spin-finisher deferred slam state ---
# Spin damage fires on tap; the forward slam lands at the end of the spin so
# the impact pulse syncs with the blade thrusting forward. Ticks in _tick_swing.
var _pending_spin_slam: bool = false
var _spin_slam_timer: float = 0.0
var _spin_slam_pos: Vector2 = Vector2.ZERO
# --- Run 12 — Cancel system: track which weapon is currently swinging ---
# "y" = katana, "x" = naginata, "" = no swing. Used by BEA_ATTACKING cross-cancel.
var _active_swing: String = ""

# --- Charge state ---
var _y_hold_dur: float = -1.0   # -1 = not tracking; 0+ = accumulating hold time
var _x_hold_dur: float = -1.0   # parallel for X (naginata charge → Meteor Dive)
var _a_hold_dur: float = -1.0   # parallel for A (kunai charge → Shuriken Flurry)
var _charge_windup_timer: float = 0.0

# --- Whirl state ---
var _whirl_timer: float = 0.0
var _whirl_tick_timer: float = 0.0
var _whirl_dir: Vector2 = Vector2.RIGHT
var _whirl_hit_cache: Dictionary = {}  # deduplicate hits per whirl

# --- Katana Whirl / Vortex Spin state (Y charge) ---
var _leap_timer: float = 0.0
var _vortex_caught: Array = []          # enemies currently held by the vortex
var _vortex_tick_timer: float = 0.0     # damage tick countdown
var _leap_start: Vector2 = Vector2.ZERO
var _leap_target: Vector2 = Vector2.ZERO
var _lunge_dir: Vector2 = Vector2.RIGHT
var _lunge_spin1_fired: bool = false
var _lunge_spin2_fired: bool = false
# Run 35 — sword-tornado visual node (parented to Bea, lives for the lunge).
var _lunge_tornado: Node2D = null
# Meteor Dive (X charge) state
var _dive_target_pos: Vector2 = Vector2.ZERO
var _dive_has_target: bool = false
var _dive_phase: int = 0    # 0 = ascent/hold, 1 = falling to target
var _dive_ascent_timer: float = 0.0
# Run 49 — X-charge landing reticle (world-space circle, moved while holding)
var _dive_reticle: Line2D = null
var _dive_reticle_pos: Vector2 = Vector2.ZERO
var _dive_fall_timer: float = 0.0   # Run 49b — safety: force-land if fall stalls on a wall

# --- Shuriken Flurry state ---
var _flurry_timer: float = 0.0
# Run 30b/30c — staggered flurry waves. _flurry_wave_idx counts waves already
# fired; _flurry_wave_timer counts down to the next one (during BEA_FLURRYING).
# _flurry_aim is the direction LOCKED at release — every wave fires the same
# fan along it (shotgun blast, not a swept spray).
var _flurry_wave_idx: int = 99   # 99 = no waves pending
var _flurry_wave_timer: float = 0.0
var _flurry_aim: Vector2 = Vector2.RIGHT

# --- Pirouette dash visual ---
var _pirouette_phase: float = 0.0   # advances during DASHING for body spin

# --- Ult state ---
var _ult_timer: float = 0.0
var _ult_in_dizzy: bool = false
var _ult_freeze_targets: Array = []
var _was_ult_frozen: bool = false      # Run 151 — tracks partner ult freeze for post-freeze cleanup
var _ult_blink_positions: Array = []   # remembered positions for body marker
var _ult_blink_timer: float = 0.0
var _ult_blink_idx: int = 0

# --- Signal-forwarded references for boon book-keeping etc ---
signal ult_fired()

# --- Node refs ---
var _shino: Node = null   # Shino reference — found after one frame in _ready
@onready var _bea_sprite: AnimatedSprite2D = get_node_or_null("BeaSprite")
# Run 102 — damage/status outlines (red enemy hit, orange lava, purple poison).
var _hitfx: HeroHitFX = null

# ── Frost (Popsicle Pelican) ────────────────────────────────────────────────
# Stacking movement slow (mirrors Player.gd). Applied by the pelican's popsicle
# hit / icy patch; decays one stack at a time.
const FROST_MAX_STACKS: int       = 5
# FROST_SLOW_PER_STACK moved to HeroBase (Batch 2).
const FROST_STACK_DECAY: float    = 1.4
const FROST_OUTLINE_HOLD: float   = 1.2
# frost_stacks moved to HeroBase (Batch 2).
var _frost_decay_t: float = 0.0

@onready var sprite: ColorRect    = get_node_or_null("Sprite")
@onready var swap_label: Label    = get_node_or_null("NameLabel")
@onready var body_anim: Node      = get_node_or_null("Body")   # BodyAnimator (Run 9)

# --- Weapon visuals (Run 11) ---
# Children of Body. Hidden by default; shown during their respective combos.
# Rotation pivots around Body origin so the blade swings around Bea's center.
@onready var katana_node: Node2D   = get_node_or_null("Body/Katana")
@onready var naginata_node: Node2D = get_node_or_null("Body/Naginata")
var _katana_tween: Tween = null
var _naginata_tween: Tween = null

# --- Status component (Bash, Vulnerable, etc. — Run 9) ---
var status: StatusComponent = null

# --- Coconut overshield (Run 15 — mirror of Player.gd) ---
# Charges granted on dash by RunState.overshield_grant_on_dash (rarity-scaled).
# Each charge absorbs one incoming hit (take_damage early-returns on consume).
# When a charge breaks AND Nutshell is taken, _fire_nutshell_shockwave runs.
# overshield_charges, _overshield_aura moved to HeroBase (Batch 3).

# --- Run 133 — Bea on-kill hook (mirror of Player.gd _on_enemy_killed) ---
# Battle Shell temp-overshield duration marker (bookkeeping; overshields also
# expire via dash ICD, same as Shino). _bea_last_killed_* carry the last KO's
# context to _bea_on_enemy_killed for Rotten Core's poison-death burst.
var _battle_shell_timer: float = 0.0
var _bea_last_killed_pos: Vector2 = Vector2.ZERO
var _bea_last_killed_was_poisoned: bool = false

var projectile_scene: PackedScene = null

# --- Signals → HUD ---
signal bea_hp_changed(new_hp: int, max_hp_val: int)
signal bea_chi_changed(new_chi: int, max_chi_val: int)
signal combo_count_changed(count: int)

# Bea combo meter — mirrors Player.gd's hit-streak counter (§8.3.1).
const COMBO_CAP: int = 30
const COMBO_RESET_GRACE: float = 5.0
var combo_count: int = 0
var combo_grace_timer: float = 0.0
var _drupe_invuln_timer: float = 0.0   # Run 128 — Drupe Guard post-hit invuln window
var _ghost_stealthed: bool = false     # Run 130 — Ghost Pepper vanish state

func _bump_combo() -> void:
	# Run 128 — Vineyard Reserve (Grape Legendary): +2 combo per hit.
	var _combo_inc: int = 2 if RunState.bea_has("vineyard_reserve") else 1
	combo_count = min(COMBO_CAP, combo_count + _combo_inc)
	# Run 129 — One Big Grape corrupt: combo locked at 15 (Bea parity; Shino
	# already clamps in his combo tick).
	if RunState.bea_has("corrupt_grape"):
		combo_count = min(combo_count, 15)
	combo_grace_timer = COMBO_RESET_GRACE
	# Run 60 — mirror to RunState (single source of truth for external systems).
	RunState.set_combo("bea", combo_count)
	emit_signal("combo_count_changed", combo_count)


func _ready() -> void:
	hero_id = "bea"   # HeroBase identity — per-hero RunState gating key
	current_hp = max_hp
	# Batch 3 — Bea's external-heal particle FX (base default is Shino's).
	_heal_fx_color = Color(0.90, 0.60, 0.20, 1.0)
	_heal_fx_count = 4
	add_to_group("bea")
	add_to_group("player")   # so door trigger and enemy AI can find both characters

	# Weapons start hidden — only visible during their combo.
	if katana_node:
		katana_node.visible = false
	if naginata_node:
		naginata_node.visible = false

	# Run 53 — Bea's stick-figure Body is retired in favor of BeaSprite, BUT the
	# Katana/Naginata live UNDER Body and rely on body_anim.rotation for their
	# compound swing/spin animations. So keep Body itself VISIBLE (the weapons
	# need a visible parent) and hide ONLY the stick-figure parts. The weapons
	# remain controlled by their own visible flags (shown during combos).
	if body_anim:
		body_anim.visible = true
		for part_name in ["Head", "HeadOutline", "HairDetail", "Torso", "TorsoSash",
						   "ArmL", "ArmR", "LegL", "LegR", "EyeL", "EyeR", "FacingMarker"]:
			var part: Node = body_anim.get_node_or_null(part_name)
			if part:
				part.visible = false

	# Build Bea's animated sprite frames from the extracted strip PNG.
	_setup_bea_sprite_frames()
	# Run 102 — damage/status outline FX (red hit, orange lava, purple poison).
	_hitfx = HeroHitFX.new()
	add_child(_hitfx)
	_hitfx.setup(self, _bea_sprite)
	# Run 115 — Bea's charge silhouette aura is teal (Shino's is yellow).
	_hitfx.set_charge_colors(
		Color(0.20, 0.82, 0.78, 1.0),   # charging wind-up (teal)
		Color(0.35, 1.0, 0.92, 1.0))    # fully charged (bright teal)

	# Status component — Bea can be Bashed / made Vulnerable like anyone else.
	status = StatusComponent.new()
	status.name = "StatusComponent"
	add_child(status)
	status.host = self

	# One-frame defer to let Shino finish adding itself to the scene tree
	await get_tree().process_frame

	var all_players: Array = get_tree().get_nodes_in_group("player")
	for p in all_players:
		if p != self and p.has_method("get_current_hp"):
			_shino = p
			break

	# Bea throws Kunai — Ki Blast is Shino's signature attack only.
	projectile_scene = load("res://scenes/Kunai.tscn") if ResourceLoader.exists("res://scenes/Kunai.tscn") else null

	# Apply any run-persistent boon modifiers (same boon pool affects both characters)
	apply_runstate_modifiers()
	_apply_bea_carry_state()
	# Run 30 — restore which character the human was controlling on the previous arena.
	# Player._apply_carry_state() already set Shino's player_controlled flag synchronously.
	# Here we finalise Bea's side and clear the carry field.
	if RunState.two_player:
		# Run 73 — 2P co-op: both ninjas are human-controlled. Bea reads her own
		# device; Shino stays player-controlled (set in his _apply_carry_state).
		player_controlled = true
		state = State.PLAYER_CONTROLLED
		if _shino != null and is_instance_valid(_shino) and _shino.has_method("set_player_controlled"):
			_shino.set_player_controlled(true)
		_refresh_swap_label()
	elif RunState.carry_player_controlled_char == 1:
		# Bea was in control — confirm her flag and ensure Shino is in AI mode.
		player_controlled = true
		if _shino != null and is_instance_valid(_shino) and _shino.has_method("set_player_controlled"):
			_shino.set_player_controlled(false)
		state = State.PLAYER_CONTROLLED
		_refresh_swap_label()
	elif RunState.carry_player_controlled_char == 0:
		player_controlled = false   # Shino controlled — Bea stays in AI mode
		state = State.AI_FOLLOW
	# Field consumed — clear it so a full reset doesn't reuse stale data.
	RunState.carry_player_controlled_char = -1
	# Initialise dash charges after boons applied (Extra Banana may raise max).
	dash_charges = _get_max_dash_charges()

	# Initial HUD signals
	emit_signal("bea_hp_changed", current_hp, get_effective_max_hp())
	emit_signal("bea_chi_changed", current_chi, MAX_CHI)

	# Nameplate (Run 54) — live-toggle when Settings.nameplates_enabled changes.
	var _settings := get_node_or_null("/root/Settings")
	if _settings and _settings.has_signal("nameplates_changed"):
		_settings.nameplates_changed.connect(_on_nameplates_changed)

	_refresh_swap_label()


# ============================================================
# ============================================================
# Bea sprite animation (SpriteFrames built at runtime from strip PNG)
# ============================================================

# Run 53 — Bea now uses Bruno's hand-drawn art (single forward-facing pose):
#   idle  ← bea_static.png  (1 frame)
#   walk  ← bea_walk.png     (2-frame waddle, two equal halves side-by-side)
# Both serve ALL directions; flip_h handles left/right. The source art is large
# (~320-340px tall), so the node is scaled down to ~52px on screen — same idea
# as Player.gd's SHINO_SPRITE_SCALE.
# IMPORTANT: BEA_SPRITE_SCALE is the SINGLE source of truth for Bea's on-screen
# size. Any combat VFX that scales the sprite (e.g. Meteor Dive) must multiply
# BEA_SPRITE_SCALE — never hardcode 1.0, or she'll snap to ~6× size.
const BEA_SPRITE_SCALE: float = 52.0 / 340.0   # art ~340px tall → ~52px on screen

func _setup_bea_sprite_frames() -> void:
	if _bea_sprite == null:
		return
	var frames := SpriteFrames.new()
	if frames.has_animation("default"):
		frames.remove_animation("default")

	# Idle — single static frame (full image).
	var idle_path := "res://Assets/Sprites/bea_static.png"
	if ResourceLoader.exists(idle_path):
		var idle_tex: Texture2D = load(idle_path)
		frames.add_animation(&"idle")
		frames.set_animation_loop(&"idle", true)
		frames.set_animation_speed(&"idle", 1.0)
		var it := AtlasTexture.new()
		it.atlas = idle_tex
		it.region = Rect2(0, 0, idle_tex.get_width(), idle_tex.get_height())
		frames.add_frame(&"idle", it)
	else:
		push_warning("Bea SpriteFrames: missing — %s" % idle_path)

	# Walk — 2-frame waddle cycle (sheet split into two equal halves).
	var walk_path := "res://Assets/Sprites/bea_walk.png"
	if ResourceLoader.exists(walk_path):
		var walk_tex: Texture2D = load(walk_path)
		var fw: int = int(walk_tex.get_width() / 2)
		var fh: int = walk_tex.get_height()
		frames.add_animation(&"walk")
		frames.set_animation_loop(&"walk", true)
		frames.set_animation_speed(&"walk", 6.0)
		for i in range(2):
			var wt := AtlasTexture.new()
			wt.atlas = walk_tex
			wt.region = Rect2(i * fw, 0, fw, fh)
			frames.add_frame(&"walk", wt)
	else:
		push_warning("Bea SpriteFrames: missing — %s" % walk_path)

	_bea_sprite.sprite_frames = frames
	_bea_sprite.scale = Vector2.ONE * BEA_SPRITE_SCALE
	_bea_sprite.centered = true
	if frames.has_animation(&"idle"):
		_bea_sprite.animation = &"idle"
		_bea_sprite.frame = 0
	elif frames.has_animation(&"walk"):
		_bea_sprite.play(&"walk")
		_bea_sprite.stop()


func _update_bea_sprite_animation() -> void:
	if _bea_sprite == null or _bea_sprite.sprite_frames == null:
		return
	# Run 150 — sprite is hidden while burrowed; skip animation updates.
	if state == State.BEA_BURROWING:
		return
	# Y-sort depth: Bea's sprite sits at z=0 (same as interior prop wraps) so the
	# parent y_sort sorts heroes and obstacles by foot Y — south = in front,
	# north = behind.  A DASH lifts to HERO_DASH_Z so she flies OVER props.
	_bea_sprite.z_index = RunState.HERO_DASH_Z if state == State.DASHING else 0
	var spd: float = velocity.length()
	if spd > 20.0:
		# Single-direction art: one walk cycle serves all directions; flip_h
		# faces her left/right. Step cadence follows move speed (like Shino).
		if _bea_sprite.sprite_frames.has_animation(&"walk"):
			if _bea_sprite.animation != &"walk" or not _bea_sprite.is_playing():
				_bea_sprite.play(&"walk")
			_bea_sprite.speed_scale = clampf(spd / move_speed, 0.75, 1.5)
		if absf(velocity.x) > 4.0:
			_bea_sprite.flip_h = velocity.x < 0.0
	else:
		# Idle — rest on the static pose.
		if _bea_sprite.sprite_frames.has_animation(&"idle") and _bea_sprite.animation != &"idle":
			_bea_sprite.animation = &"idle"
			_bea_sprite.frame = 0
		if _bea_sprite.is_playing():
			_bea_sprite.stop()


# ============================================================
# Main loop
# ============================================================

func _physics_process(delta: float) -> void:
	# Run 150 (Bruno fix 11) — GLOBAL ULT FREEZE: while Shino's ultimate
	# cinematic runs, Bea (player-controlled OR AI) is fully frozen. The only
	# input read is the ult button → queues the future double-ult.
	if RunState.ult_freeze_caster == "shino" and state != State.DOWNED:
		velocity = Vector2.ZERO
		_was_ult_frozen = true
		if player_controlled and _act_jp("ult"):
			RunState.double_ult_queued = true
			FX.spawn_hit_particles(global_position, Color(0.9, 0.6, 1.0, 0.9), 6)
		return
	# Run 151 — Post-freeze cleanup: if Bea was frozen (ult freeze OR tree
	# pause from boon offers/menus), cancel any charge whose button release
	# was missed. Without this, Bea stays stuck in BEA_CHARGING/CHARGED.
	if _was_ult_frozen:
		_was_ult_frozen = false
		if state == State.BEA_CHARGING or state == State.BEA_CHARGED:
			var _btn: String = _input_for_charge()
			if _btn == "" or not _act_p(_btn):
				_cancel_bea_charge()
		# Clear stale hold-duration trackers whose accumulation was paused.
		_y_hold_dur = -1.0
		_x_hold_dur = -1.0
		_a_hold_dur = -1.0
	if _drupe_invuln_timer > 0.0:
		_drupe_invuln_timer -= delta   # Run 128 — Drupe Guard window
	# Run 130 — Ghost Pepper: 1.5s without attacking → vanish.
	if RunState.bea_has("ghost_pepper"):
		var _gp_want: bool = _no_attack_timer >= 1.5 and current_hp > 0 and state != State.DOWNED
		if _gp_want != _ghost_stealthed:
			_ghost_stealthed = _gp_want
			modulate.a = 0.45 if _ghost_stealthed else 1.0
	elif _ghost_stealthed:
		_ghost_stealthed = false
		modulate.a = 1.0
	if state == State.DEAD:
		return
	# Run 13 — DOWNED is a frozen-on-ground state. Don't tick movement / AI /
	# input. (HoT can still tick after revive — only matters if revived.)
	# EXCEPT: swap input must remain reachable so the player can manually swap
	# to the standing partner from a downed-Bea state (no auto-swap rule).
	if state == State.DOWNED:
		velocity = Vector2.ZERO
		_tick_dd_hot(delta)
		# Tick swap-tap timer and process the input so Q+Q still works while down.
		if _swap_tap_timer > 0.0:
			_swap_tap_timer -= delta
			if _swap_tap_timer <= 0.0:
				_swap_tap_count = 0
				_swap_shino_req = false   # Run 73
				_swap_bea_req = false
		_handle_swap_input()
		return

	# Run 117 — defensive revive-UI cleanup: if we left DOWNED by ANY path that
	# forgot to call _clear_revive_ui(), catch it here on the first non-DOWNED
	# frame so the circle / rez bar never lingers on a standing hero.
	if _revive_circle_node and is_instance_valid(_revive_circle_node) and _revive_circle_node.visible:
		_clear_revive_ui()
		modulate = Color(1.0, 1.0, 1.0, 1.0)

	# Run 44 — hit-knockback impulse: applied as its own decaying move so the
	# AI/state velocity assignments below can't erase it next frame.
	if _hit_knockback_vel.length() > 1.0:
		var _pre_kb_vel: Vector2 = velocity
		velocity = _hit_knockback_vel
		move_and_slide()
		velocity = _pre_kb_vel
		_hit_knockback_vel = _hit_knockback_vel.lerp(Vector2.ZERO, delta * 9.0)
	else:
		_hit_knockback_vel = Vector2.ZERO

	_tick_timers(delta)
	_tick_dd_hot(delta)
	_tick_baked_apple_hot(delta)
	_tick_bea_juicebox_regen(delta)
	_handle_swap_input()

	# Run 27b — Ingrained (standing-still) tracking + Ingrained-gated duos.
	if global_position.distance_to(_ingrained_last_pos) < 1.5:
		_ingrained_time += delta
	else:
		_ingrained_time = 0.0
		_deep_roots_timer = 0.0
		_bunker_timer = 0.0
	_ingrained_last_pos = global_position
	RunState.bea_ingrained = _ingrained_time >= RunState.INGRAINED_THRESHOLD
	if _ingrained_time >= RunState.INGRAINED_THRESHOLD:
		# Deep Roots duo (Apple+Potato): regen 1 HP/sec while Ingrained, in combat.
		if RunState.is_duo_active("apple_potato") and _count_nearby_enemies(600.0) >= 1:
			_deep_roots_timer += delta
			if _deep_roots_timer >= 1.0:
				_deep_roots_timer -= 1.0
				heal_external(1)
		# Bunker duo (Coconut+Potato): 1 overshield per 4s while Ingrained.
		if RunState.is_duo_active("coconut_potato"):
			_bunker_timer += delta
			if _bunker_timer >= 4.0:
				_bunker_timer = 0.0
				if overshield_charges < 1:
					grant_overshield_external(1)
	if _hot_shell_icd > 0.0:
		_hot_shell_icd -= delta
	if _smokestack_icd > 0.0:
		_smokestack_icd -= delta
	if _peel_resto_icd > 0.0:
		_peel_resto_icd -= delta
	# Run 133 — Battle Shell temp-overshield duration marker (mirror Player.gd).
	if _battle_shell_timer > 0.0:
		_battle_shell_timer -= delta
	# Run 60 — Tremor Walk (Potato passive): drop Cracked Soil patches behind Bea while moving.
	_tick_tremor_walk_bea(delta)
	# Run 60 — Scorched Earth duo (Pepper+Potato): persistent lava patch follows Bea.
	_tick_scorched_earth_bea(delta)
	# Run 60 — Hot Step duo (Banana+Pepper): burning trail while moving fast / post-dash.
	_tick_hot_step_bea(delta)
	_no_attack_timer += delta   # Run 27f — Drawn Bow pause tracker
	# Run 27e — Heirloom duo (Apple+Onion): regen follows the hero — 1 HP/2s in combat.
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

	# UNIVERSAL RULE (Run 17 — Status Taxonomy): dash always works.
	# Even when Bashed / Frozen / Rooted (movement_lock), the player-controlled
	# Bea can still escape via dash. AI-controlled Bea waits it out.
	# Bash/Frozen freeze
	if status and status.is_movement_locked():
		if player_controlled and _act_jp("dash") and dash_charges > 0:
			_y_hold_dur = -1.0
			_x_hold_dur = -1.0
			_a_hold_dur = -1.0
			_start_dash()
		else:
			velocity = Vector2.ZERO
			move_and_slide()
	else:
		match state:
			State.DASHING:
				_tick_dash(delta)
			State.BEA_BURROWING:
				_tick_burrow(delta)
			State.PLAYER_CONTROLLED, \
			State.BEA_ATTACKING, \
			State.BEA_CHARGING, \
			State.BEA_CHARGED, \
			State.BEA_DIVING, \
			State.BEA_WHIRLING, \
			State.BEA_FLURRYING, \
			State.BEA_ULT_CASTING:
				_handle_player_input(delta)
			State.AI_FOLLOW:
				_handle_ai(delta)
			State.REVIVING:
				_tick_channel_revive(delta)

	# Run 13 — revive-attempt tick. (Run 150: not while underground either.)
	if state != State.DASHING and state != State.REVIVING and state != State.DOWNED \
	and state != State.BEA_BURROWING:
		_tick_revive_attempt(delta)

	# Boon effects that tick every frame — mirror of Player.gd.
	_tick_layered_defense(delta)
	_tick_hydration(delta)
	# Run 46 — Dragon Chi (Sensei Z): passive Chi regen, 1 Chi/5s per rank.
	_tick_sensei_chi_regen(delta)
	_tick_iron_will(delta)
	_tick_critical_mass(delta)
	_tick_combat_fury(delta)

	# Drive animator based on resulting velocity.
	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_motion_speed(velocity.length())
		if velocity.length() > 6.0:
			body_anim.set_anim_state("walking")
		else:
			body_anim.set_anim_state("idle")
	# Update Bea's animated sprite.
	_update_bea_sprite_animation()


# ============================================================
# Timers
# ============================================================

func _tick_timers(delta: float) -> void:
	# Frost decay — melt one stack every FROST_STACK_DECAY seconds.
	if frost_stacks > 0:
		_frost_decay_t -= delta
		if _frost_decay_t <= 0.0:
			frost_stacks -= 1
			_frost_decay_t = FROST_STACK_DECAY
			if _hitfx and frost_stacks > 0:
				_hitfx.start_frost(FROST_OUTLINE_HOLD, float(frost_stacks) / float(FROST_MAX_STACKS))
	if iframe_timer > 0.0:
		iframe_timer -= delta
		if iframe_timer <= 0.0:
			is_invulnerable = false

	# Dash charge refill (mirrors Shino's system).
	if dash_cd_timer > 0.0:
		dash_cd_timer -= delta
		if dash_cd_timer <= 0.0:
			var max_ch: int = _get_max_dash_charges()
			if dash_charges < max_ch:
				dash_charges = min(max_ch, dash_charges + 1)
				if dash_charges < max_ch:
					dash_cd_timer = DASH_INTERNAL_CD
	# Run 150 — Tuber Burrow internal cooldown (gates the burrow extension only).
	if burrow_cd_timer > 0.0:
		burrow_cd_timer = max(0.0, burrow_cd_timer - delta)
	# Run 150b — Vine Lash dash-then-attack window countdown.
	if _vine_lash_window > 0.0:
		_vine_lash_window = max(0.0, _vine_lash_window - delta)

	if _attack_timer > 0.0:
		_attack_timer -= delta

	if _player_shot_timer > 0.0:
		_player_shot_timer -= delta

	# Evergreen Step — cooldown tick (mirrors Player.gd).
	if _evergreen_step_cd_timer > 0.0:
		_evergreen_step_cd_timer = max(0.0, _evergreen_step_cd_timer - delta)

	# Run 132 — post-ult boon windows (mirrors Player.gd).
	if _titans_roar_window > 0.0:
		_titans_roar_window -= delta
	if _bullseye_finale_window > 0.0:
		_bullseye_finale_window -= delta

	if _swap_tap_timer > 0.0:
		_swap_tap_timer -= delta
		if _swap_tap_timer <= 0.0:
			_swap_tap_count = 0   # tap window expired — hide tag-in icon
			_swap_shino_req = false   # Run 73 — drop any un-answered 2P swap request
			_swap_bea_req = false
			_show_tag_in_icon(false)
			if _shino != null and is_instance_valid(_shino):
				var shino_lbl: Node = _shino.get_node_or_null("TagInLabel")
				if shino_lbl:
					shino_lbl.visible = false

	# Combo chain delay (inter-step pause between hits).
	# Combo meter grace — no hit for COMBO_RESET_GRACE seconds → hard reset.
	if combo_grace_timer > 0.0:
		combo_grace_timer -= delta
		if combo_grace_timer <= 0.0 and combo_count > 0:
			# Run 128 — Combo Master / Vineyard Reserve soften the hard reset
			# into a 1 pt/sec gradual decay (parity with Shino's soft decay).
			if RunState.bea_has("combo_master") or RunState.bea_has("vineyard_reserve"):
				combo_count -= 1
				combo_grace_timer = 1.0
				RunState.set_combo("bea", combo_count)
				emit_signal("combo_count_changed", combo_count)
			else:
				combo_count = 0
				RunState.set_combo("bea", 0)   # Run 60 — mirror combo reset
				emit_signal("combo_count_changed", combo_count)

	if _combo_chain_pending and _combo_chain_timer > 0.0:
		_combo_chain_timer -= delta
		if _combo_chain_timer <= 0.0:
			_combo_chain_pending = false
			if _combo_chain_weapon == "y":
				_tap_katana()
			elif _combo_chain_weapon == "x":
				_tap_naginata()
			_combo_chain_weapon = ""


# ============================================================
# Hot-swap — double-tap Q or LB
# ============================================================

func _handle_swap_input() -> void:
	# Run 73 — 2P co-op uses a both-players-confirm swap (trade characters).
	if RunState.two_player:
		_handle_swap_input_2p()
		return
	# 1P — classic double-tap on the one controller.
	if Input.is_action_just_pressed("swap_character"):
		_swap_tap_count += 1
		_swap_tap_timer = SWAP_DBL_TAP_WINDOW
		if _swap_tap_count == 1:
			# First press — show tag-in hand icon above both ninjas.
			_show_tag_in_icon(true)
			_show_shino_tag_in(true)
		if _swap_tap_count >= 2:
			_swap_tap_count = 0
			_swap_tap_timer = 0.0
			_show_tag_in_icon(false)
			_show_shino_tag_in(false)
			_execute_swap()


# Run 73 — 2P swap: each player presses swap on their OWN controller; the swap
# fires only once BOTH have pressed within SWAP_DBL_TAP_WINDOW. The first press
# raises the "TAG IN?" prompt on that player's ninja, asking the partner to
# confirm. Swapping trades which controller drives which ninja.
func _handle_swap_input_2p() -> void:
	if InputRouter.just_pressed(RunState.shino_device, "swap_character"):
		_swap_shino_req = true
		_swap_tap_timer = SWAP_DBL_TAP_WINDOW
	if InputRouter.just_pressed(RunState.bea_device, "swap_character"):
		_swap_bea_req = true
		_swap_tap_timer = SWAP_DBL_TAP_WINDOW
	if _swap_shino_req or _swap_bea_req:
		_show_tag_in_icon(_swap_bea_req)
		_show_shino_tag_in(_swap_shino_req)
	if _swap_shino_req and _swap_bea_req:
		_swap_shino_req = false
		_swap_bea_req = false
		_swap_tap_timer = 0.0
		_show_tag_in_icon(false)
		_show_shino_tag_in(false)
		_execute_swap_2p()


# Toggle the "🙋 TAG IN?" label above Shino (creating it lazily).
func _show_shino_tag_in(vis: bool) -> void:
	if _shino == null or not is_instance_valid(_shino):
		return
	var shino_lbl: Node = _shino.get_node_or_null("TagInLabel")
	if shino_lbl == null:
		if not vis:
			return
		shino_lbl = Label.new()
		shino_lbl.name = "TagInLabel"
		shino_lbl.add_theme_font_size_override("font_size", 18)
		shino_lbl.add_theme_color_override("font_color", Color(1.0, 0.95, 0.30, 1.0))
		shino_lbl.position = Vector2(-22, -64)
		shino_lbl.z_index = 20
		_shino.add_child(shino_lbl)
	shino_lbl.text = "🙋 TAG IN?"
	shino_lbl.visible = vis


# 2P character swap — exchange which device drives which ninja. Both ninjas
# remain human-controlled; only the controlling player changes.
func _execute_swap_2p() -> void:
	RunState.swap_two_player_devices()
	_refresh_swap_label()
	if _shino != null and is_instance_valid(_shino) and _shino.has_method("_refresh_name_label"):
		_shino._refresh_name_label()
	print("[Bea] 2P swap — Shino dev=%d, Bea dev=%d" % [RunState.shino_device, RunState.bea_device])


func _show_tag_in_icon(visible: bool) -> void:
	if _tag_in_label == null and visible:
		_tag_in_label = Label.new()
		_tag_in_label.name = "TagInLabel"
		_tag_in_label.add_theme_font_size_override("font_size", 18)
		_tag_in_label.add_theme_color_override("font_color", Color(1.0, 0.95, 0.30, 1.0))
		_tag_in_label.position = Vector2(-22, -64)
		_tag_in_label.z_index = 20
		add_child(_tag_in_label)
	if _tag_in_label:
		_tag_in_label.text = "🙋 TAG IN?"
		_tag_in_label.visible = visible


func _execute_swap() -> void:
	# Run 62 — Beast Mode swap-lock: while the HUMAN-controlled ninja is DOWNED,
	# lock swapping at tier 5. Otherwise the player could hand control to the
	# immortal tier-5 AI — which strips its HP floor — and orphan the downed
	# body, risking a double-down that ends the run. Locking forces the AI to
	# revive the player first. Lower tiers keep the old free-swap behavior.
	if RunState.ai_helper_tier == 5:
		var controlled_downed: bool = false
		if player_controlled:
			controlled_downed = (state == State.DOWNED)
		elif _shino != null and is_instance_valid(_shino) and _shino.has_method("is_downed"):
			controlled_downed = _shino.is_downed()
		if controlled_downed:
			# Run 65 — repurpose the otherwise-dead swap input while down: instead of
			# silently blocking, treat Q+Q as a "come revive me" recall. The standing
			# tier-5 AI drops its target and beelines to the body (Priority 0 in its AI
			# tick) and force-channels the rez even with enemies nearby.
			RunState.revive_recall_active = true
			print("[Bea] Swap→RECALL — tier-5 AI summoned to revive the downed ninja.")
			return

	# Run 13 — guard: if the partner being swapped TO is DOWNED, refuse the swap
	# (no point taking control of a corpse). Player keeps current character.
	var partner_downed: bool = false
	if _shino != null and is_instance_valid(_shino) and _shino.has_method("is_downed"):
		# We want to swap TO Shino if currently on Bea; if Shino is down, refuse.
		if player_controlled and _shino.is_downed():
			partner_downed = true
	if partner_downed:
		print("[Bea] Swap refused — partner is downed.")
		return

	# Save current downed status so we don't yank a downed Bea out of DOWNED.
	var was_downed: bool = (state == State.DOWNED)

	player_controlled = !player_controlled

	# Tell Shino to flip his flag
	if _shino != null and is_instance_valid(_shino) and _shino.has_method("set_player_controlled"):
		_shino.set_player_controlled(!player_controlled)

	if was_downed:
		# Stay in DOWNED — player_controlled flag flipped but Bea remains on the ground.
		# Camera/cursor follow can still target her since she's the controlled char.
		pass
	elif player_controlled:
		state = State.PLAYER_CONTROLLED
		# Run 38 — stand up from the dojo "sitting" pose when control arrives.
		if _bea_sprite:
			_bea_sprite.position.y = -9.0
	else:
		state = State.AI_FOLLOW
		velocity = Vector2.ZERO

	# Reset any combat state that might have been in-progress when the swap happened.
	_y_hold_dur = -1.0
	_x_hold_dur = -1.0
	_a_hold_dur = -1.0
	_charge_windup_timer = 0.0
	_charging_button = ""
	modulate = Color(1.0, 1.0, 1.0, 1.0)
	if _hitfx:
		_hitfx.set_charge(0)
	if body_anim:
		body_anim.rotation = 0.0
		body_anim.position.y = 0.0
	# Defensive: holster weapons if swap happens mid-combo.
	_hide_weapons()
	_free_lunge_tornado()   # Run 35 — don't leak the tornado if swap fires mid-whirl
	# Run 116 — release vortex-caught enemies on swap so they don't stay perma-bashed.
	if _vortex_caught.size() > 0:
		_vortex_release_enemies()
	_free_dive_reticle()    # Run 49 — don't leak the landing circle if swap fires mid-aim
	_set_barrier_phasing(false)   # Run 110 — don't leak airborne barrier-phasing if swap fires mid-leap
	# Defensive: if the swap fires mid-ult, un-freeze any pending freeze targets
	# so enemies don't become permanent statues. (Edge case — flagged for review.)
	for e in _ult_freeze_targets:
		if is_instance_valid(e):
			e.process_mode = Node.PROCESS_MODE_INHERIT
	_ult_freeze_targets.clear()
	_ult_blink_positions.clear()

	_refresh_swap_label()
	print("[Bea] Hot-swap executed — Bea player_controlled = %s" % str(player_controlled))


func _clear_flash() -> void:
	if is_instance_valid(self) and state != State.DEAD:
		modulate = Color(1.0, 1.0, 1.0, 1.0)


func _refresh_swap_label() -> void:
	if swap_label:
		# Hide the whole plate when nameplates are disabled in Settings (Run 54).
		var show: bool = true
		var s := get_node_or_null("/root/Settings")
		if s and "nameplates_enabled" in s:
			show = s.nameplates_enabled
		swap_label.visible = show
		if player_controlled:
			swap_label.text = "BEA ✦"
			swap_label.modulate = Color(1.0, 0.55, 1.0, 1.0)
		else:
			swap_label.text = "BEA"
			swap_label.modulate = Color(0.8, 0.5, 0.9, 0.75)


func _on_nameplates_changed(_enabled: bool) -> void:
	_refresh_swap_label()


# ============================================================
# Player-controlled input — full kit (Phase 7.5 COMPLETE, Run 10)
#   Y tap  → 3-hit katana combo: 180° L→R / 180° R→L / 360° spin finisher (with glide)
#   Y hold → Katana Whirl / Vortex Spin (forward lunge + pull enemies + toss)
#   X tap  → 3-hit naginata combo: Thrust / 180° Sweep / 360° Spin+Slam
#   X hold → Meteor Dive (leap up + dive onto enemy)
#   A tap  → Kunai throw (single fast projectile)
#   A hold → Shuriken Flurry (5 shuriken cone spread)
#   B / SPACE → Pirouette Dodge (dash with pirouette body spin visual)
#   U / RT → Thousand Cut Dance ult (blink-chain + final flourish, requires full Chi)
# ============================================================

func _handle_player_input(delta: float) -> void:
	# ---- Sub-state routing (combat states run their own tick) ----
	# Run 12 — CANCEL SYSTEM (canonical, mirrors Shino):
	#   - Same attack button = combo continues (handled by tap-fn re-entry)
	#   - Different attack button = cancels current combo, starts the other
	#   - Dash = cancels EITHER combo (top-priority interrupt)
	#   - Charge = HOLD only; brief tap of other button never enters charge state
	match state:
		State.BEA_ATTACKING:
			# Dash always cancels swing (top-priority).
			if _act_jp("dash") and dash_charges > 0:
				_clear_swing_state()
				_y_hold_dur = -1.0
				_x_hold_dur = -1.0
				_a_hold_dur = -1.0
				_start_dash()
				return
			# Cross-button cancel: opposite-attack-button press fires a fresh tap on the other combo.
			# Charge stays a HOLD-only gesture: the cross-cancel only starts a tap-step,
			# not a pending charge — preventing brief taps from being mistaken for charges.
			if _act_jp("attack_y") and _active_swing != "y":
				_cancel_swing_into_new("y")
				return
			if _act_jp("attack_x") and _active_swing != "x":
				_cancel_swing_into_new("x")
				return
			# A press during melee swing: cancel swing, fire a kunai immediately.
			# (A is a throw, not a combo — it follows the same "different button cancels" rule.)
			if _act_jp("attack_a") and _player_shot_timer <= 0.0:
				_cancel_swing_into_new("a")
				return
			_tick_swing(delta)
			_do_movement(delta)   # light movement allowed during swing
			return
		State.BEA_CHARGING, State.BEA_CHARGED:
			_tick_charge(delta)   # includes its own movement lock
			return
		State.BEA_DIVING:
			_tick_dive(delta)     # Meteor Dive (X charge)
			return
		State.BEA_WHIRLING:
			_tick_whirl(delta)     # Katana Whirl / Vortex Spin (Y charge)
			return
		State.BEA_FLURRYING:
			_tick_flurry_lockout(delta)
			return
		State.BEA_ULT_CASTING:
			_tick_ult(delta)
			return

	# ---- Combo window ticks (both katana and naginata, independent) ----
	if katana_step > 0:
		_combo_window_timer -= delta
		if _combo_window_timer <= 0.0:
			katana_step = 0
	if naginata_step > 0:
		_naginata_combo_timer -= delta
		if _naginata_combo_timer <= 0.0:
			naginata_step = 0

	# ---- Ult (per GDD §8.2.3) — preempts everything when Chi is full ----
	if _act_jp("ult") and current_chi >= max(1, int(round(float(ULT_CHI_COST) * RunState.tide_master_ult_cost_mult("bea")))):
		_start_ult()
		return

	# ---- Dash (pirouette dodge) — cancels any pending charge ----
	if _act_jp("dash") and dash_charges > 0:
		_y_hold_dur = -1.0
		_x_hold_dur = -1.0
		_a_hold_dur = -1.0
		_start_dash()
		return

	# ---- Y button — katana tap vs. hold-charge (Katana Whirl / Vortex Spin) ----
	if _act_jp("attack_y"):
		_y_hold_dur = 0.0
	elif _act_p("attack_y") and _y_hold_dur >= 0.0:
		_y_hold_dur += delta
		if _y_hold_dur >= CHARGE_DETECT:
			_y_hold_dur = -1.0
			_start_bea_charge("y")
			return
	if _act_jr("attack_y") and _y_hold_dur >= 0.0:
		if _y_hold_dur < CHARGE_DETECT:
			_apply_melee_aim_snap()   # Run 60
			_tap_katana()
		_y_hold_dur = -1.0

	# ---- X button — naginata tap vs. hold-charge (Meteor Dive) ----
	if _act_jp("attack_x"):
		_x_hold_dur = 0.0
	elif _act_p("attack_x") and _x_hold_dur >= 0.0:
		_x_hold_dur += delta
		if _x_hold_dur >= CHARGE_DETECT:
			_x_hold_dur = -1.0
			_start_bea_charge("x")
			return
	if _act_jr("attack_x") and _x_hold_dur >= 0.0:
		if _x_hold_dur < CHARGE_DETECT:
			_apply_melee_aim_snap()   # Run 60
			_tap_naginata()
		_x_hold_dur = -1.0

	# ---- A button — kunai tap vs. hold-charge (Shuriken Flurry) ----
	if _act_jp("attack_a"):
		_a_hold_dur = 0.0
	elif _act_p("attack_a") and _a_hold_dur >= 0.0:
		_a_hold_dur += delta
		if _a_hold_dur >= CHARGE_DETECT:
			_a_hold_dur = -1.0
			_start_bea_charge("a")
			return
	if _act_jr("attack_a") and _a_hold_dur >= 0.0:
		if _a_hold_dur < CHARGE_DETECT and _player_shot_timer <= 0.0:
			# Run 105 — A-button kunai snaps to the best forward target (the stick
			# path below stays pure free-aim). Set facing so the throw + visuals align.
			facing = _pick_kunai_aim_dir()
			_throw_kunai(facing)
			_player_shot_timer = PLAYER_SHOT_COOLDOWN
		_a_hold_dur = -1.0

	# ---- Run 60 — twin-stick ranged: hold the right stick to auto-fire kunai
	# that way (free aim). Shares _player_shot_timer with A so no double rate.
	var aim: Vector2 = _aim_vec()
	if aim.length() >= AIM_STICK_DEADZONE:
		facing = aim.normalized()
		if _player_shot_timer <= 0.0:
			_throw_kunai(facing)
			# Run 106 — slower stick-only cadence so holding the aim stick fires
			# less often than max A-button tapping.
			_player_shot_timer = STICK_AUTO_INTERVAL

	# ---- Movement ----
	_do_movement(delta)


# ---- Shared movement helper (used by PLAYER_CONTROLLED and BEA_ATTACKING) ----
func _do_movement(delta: float) -> void:
	# Tick post-dash buff timers.
	if _peel_out_timer > 0.0:
		_peel_out_timer = max(0.0, _peel_out_timer - delta)
	if _hot_footed_timer > 0.0:
		_hot_footed_timer = max(0.0, _hot_footed_timer - delta)
	if _zip_dash_ms_timer > 0.0:
		_zip_dash_ms_timer = max(0.0, _zip_dash_ms_timer - delta)

	var dir: Vector2 = Vector2(
		_move_axis().x,
		_move_axis().y
	)
	var has_input: bool = dir.length_squared() > 0.01
	var target_vel: Vector2 = Vector2.ZERO
	if has_input:
		dir = dir.normalized()
		facing = dir
		var peel_mult: float = 1.30 if (_peel_out_timer > 0.0 and RunState.bea_has("peel_out")) else 1.0
		var hotfoot_mult: float = (1.0 + HOT_FOOTED_SPEED_BONUS) if (_hot_footed_timer > 0.0 and RunState.bea_has("hot_footed")) else 1.0
		var zip_mult: float = 1.15 if (_zip_dash_ms_timer > 0.0 and RunState.bea_has("zip_dash")) else 1.0
		var crit_mass_ms: float = 1.0
		if RunState.bea_has("critical_mass") and _critical_mass_stacks > 0:
			crit_mass_ms = 1.0 + RunState.CRITICAL_MASS_PER_STACK_PCT * float(_critical_mass_stacks)
		target_vel = dir * move_speed * RunState.get_char_move_speed_mult("bea") * peel_mult * hotfoot_mult * zip_mult * crit_mass_ms * _frost_move_mult()
	# Frostpeak ice: walkable but slippery — Mario-style momentum. Off-ice keeps
	# the original snap-on-input / soft-stop-on-release behavior unchanged.
	if get_meta("on_ice", false):
		velocity = ICE.glide(velocity, target_vel, has_input, delta)
	elif has_input:
		velocity = target_vel
	else:
		velocity = velocity.move_toward(Vector2.ZERO, move_speed * 14.0 * delta)
	move_and_slide()


# ---- Katana tap: deal AoE hit by step shape, advance combo, animate ----
# REVISED Run 115 — CrossCode-style 4-hit combo:
#   Steps 0-2: 180° alternating swipes (L→R / R→L / L→R) with forward step + enemy push
#   Step 3:    360° spinning double-swipe finisher, slightly more carry
# Every hit locks Bea into a small forward lunge and pushes struck enemies WITH her
# so they stay in blade range for the next swing. No more pass-through catapult.
func _tap_katana() -> void:
	_maybe_fire_vine_lash()   # Run 150b — Vine Lash dash-then-attack trigger
	# Run 131 — One Big Grape (corrupt_grape): pin every katana tap to the spin
	# finisher step so the 360° double-swipe animation, finisher damage/arc/push,
	# and every finisher-gated proc (Golden Carrot, Master Stroke, Cluster Strike,
	# cluster-splash, bunch-bloom heal) fire on EVERY hit.
	if RunState.bea_has("corrupt_grape"):
		katana_step = KATANA_COMBO_STEPS - 1
	var is_finisher: bool = (katana_step == KATANA_COMBO_STEPS - 1)
	var base_dmg: int = KATANA_FINISHER_DAMAGE if is_finisher else KATANA_DAMAGE
	_enemy_pinned_this_swing = false  # Run 116: reset per swing
	var arc_deg: float = KATANA_FINISHER_ARC_DEG if is_finisher else KATANA_ARC_DEG
	var hit_count: int = 0
	var swing_arc: float = arc_deg if arc_deg < 360.0 else 260.0
	var swing_color: Color = Color(0.15, 0.95, 0.82, 0.65) if is_finisher else Color(0.25, 0.88, 0.78, 0.55)
	swing_color = _fx_col(swing_color, "Y")
	var arc_origin: Vector2 = global_position + facing * 14.0
	var arc_facing: Vector2 = facing
	FX.spawn_swing_arc(arc_origin, arc_facing, KATANA_RANGE * 0.92, swing_arc,
		swing_color, 0.18 if is_finisher else 0.13)

	# Run 115 — enemy push direction: always Bea's facing so enemies are herded forward.
	var push_dist: float = KATANA_FINISHER_PUSH if is_finisher else KATANA_ENEMY_PUSH

	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or not e.has_method("take_damage"):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		var to_e: Vector2 = e.global_position - global_position
		# Run 131 — One Big Grape: +50% finisher AoE radius (every hit is a finisher).
		var _kat_reach: float = KATANA_RANGE * (1.5 if RunState.bea_has("corrupt_grape") else 1.0)
		if to_e.length() > _kat_reach:
			continue
		if arc_deg < 360.0 and to_e.length() > 0.01:
			var angle_diff: float = abs(facing.angle_to(to_e.normalized()))
			if angle_diff > deg_to_rad(arc_deg * 0.5):
				continue
		var scaled: int = _bea_scale_damage(base_dmg, is_finisher, true, e)
		_try_vital_harvest_crit_heal()
		if RunState.last_crit_result and RunState.burning_aim_active() and e.has_node("StatusComponent"):
			e.get_node("StatusComponent").apply("burning", 3.0, RunState.BURNING_AIM_STACKS_PER_CRIT)
		_bea_corrupt_hit_procs(e, scaled, is_finisher)
		if _try_apply_coconut_bash(e):
			scaled += RunState.bash_bonus_damage
		_bea_apply_family_statuses_on_hit(e, true, false, false, false, false)
		# Run 134 — killer attribution for the universal on-death hook (fix 5).
		e.set_meta("last_damager", "bea")
		e.take_damage(scaled, to_e.normalized() if to_e.length() > 0.01 else facing)
		hit_count += 1
		_add_chi(int(CHI_PER_DAMAGE_DEALT * float(base_dmg)))
		_try_evergreen_step_heal()
		FX.spawn_hit_particles(e.global_position, Color(0.20, 0.92, 0.82, 1.0), 6)
		# Run 115 — push enemy forward with Bea so they stay in blade range.
		# Run 116 — barrier pin: use move_and_collide so enemies stop at walls
		# instead of being shoved through them.  If the enemy is pinned against
		# a barrier, flag it so Bea's own glide is suppressed (corner-lock feel).
		if e is CharacterBody2D and push_dist > 0.0 and not e.is_in_group("immovable"):
			var col: KinematicCollision2D = e.move_and_collide(facing * push_dist)
			if col:
				_enemy_pinned_this_swing = true

	# Sound + shake feedback
	FX.play_sound("bea_katana_%d" % clampi(katana_step + 1, 1, 4))
	if is_finisher and hit_count > 0:
		_spawn_bea_finisher_impact(global_position, true)
		FX.play_sound("bea_katana_finisher")
		_start_baked_apple_hot()
	elif hit_count > 0:
		FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_TINY)
	if is_finisher:
		_bea_try_hulk_smash(global_position)
		# Run 132 — Y-finisher slot boons (mirror of Player._apply_slot_boon_hit_effects).
		# Grape Cluster Strike: Vinewrap (root) all enemies in katana reach.
		if RunState.bea_has("cluster_strike"):
			_bea_apply_vinewrap(global_position, KATANA_RANGE)
		# Potato Spud Stomp: Ground Pound knockdown around Bea.
		if RunState.bea_has("spud_stomp"):
			_bea_spawn_ground_pound(global_position, 96.0)
		# Run 132 — Grape+Potato "Stomp Combo" duo: Y finisher → cracked-earth line.
		if RunState.stomp_combo_active():
			_bea_spawn_stomp_earth_line(global_position, RunState.get_stomp_combo_line_length(combo_count), false)
		# Run 129 — Master Stroke force-crit moved into _bea_scale_damage
		# (pre-roll); the old post-hit set here primed the WRONG hit.
		var bb_heal: int = RunState.get_bunch_bloom_finisher_heal(_shino.combo_count if is_instance_valid(_shino) else 0)
		if bb_heal > 0:
			var bea_max: int = get_effective_max_hp()
			current_hp = min(bea_max, current_hp + bb_heal)
			emit_signal("bea_hp_changed", current_hp, bea_max)
			FX.spawn_hit_particles(global_position, Color(0.90, 0.55, 0.75, 0.9), 4)
		var sg_poison: int = RunState.get_broccoli_onion_finisher_poison()
		var og_burst: int = RunState.get_onion_grape_poison_burst()
		for e in get_tree().get_nodes_in_group("enemy"):
			if is_instance_valid(e) and e.has_method("is_alive") and e.is_alive():
				var dist: float = (e.global_position - global_position).length()
				if dist <= KATANA_RANGE and e.has_node("StatusComponent"):
					var sc: Node = e.get_node("StatusComponent")
					if sg_poison > 0:
						sc.apply("poison", 5.0, sg_poison)
					if og_burst > 0 and sc.has("poison"):
						sc.apply("poison", 5.0, og_burst)
					if RunState.should_cluster_splash_trigger(true, _shino.combo_count if is_instance_valid(_shino) else 0):
						_bea_apply_cluster_splash(e.global_position)

	# Lockout window for this swing
	var lockout: float = KATANA_FINISHER_LOCKOUT if is_finisher else KATANA_SWING_LOCKOUT

	# Run 115 — every hit glides Bea forward (CrossCode step-with-each-swing feel).
	# Run 116 — suppress glide when an enemy is pinned against a barrier so Bea
	# doesn't keep mashing into the wall; also suppress if Bea herself would
	# collide (test_move check).
	var glide_dist: float = KATANA_FINISHER_GLIDE if is_finisher else KATANA_HIT_GLIDE
	if _enemy_pinned_this_swing:
		_swing_glide_velocity = Vector2.ZERO
	elif test_move(global_transform, facing * glide_dist):
		_swing_glide_velocity = Vector2.ZERO
	else:
		_swing_glide_velocity = facing * (glide_dist / max(lockout, 0.001))
	_swing_is_finisher = is_finisher

	# --- Visual: body rotation tween per step ---
	if body_anim:
		if "rotation" in body_anim:
			body_anim.rotation = 0.0
		var tw: Tween = create_tween()
		if is_finisher:
			# Full 360° spin (clockwise) for the double-swipe finisher
			tw.tween_property(body_anim, "rotation", TAU, lockout)
			tw.tween_callback(Callable(self, "_reset_body_rotation"))
		else:
			# Alternating lean: steps 0,2 = right (+0.28), step 1 = left (-0.28)
			var lean_target: float = -0.28 if katana_step == 1 else 0.28
			tw.tween_property(body_anim, "rotation", lean_target, lockout * 0.50)
			tw.tween_property(body_anim, "rotation", 0.0, lockout * 0.50)

	_spawn_katana_slash_fx(katana_step, is_finisher)
	_animate_katana(katana_step, is_finisher, lockout)

	# Advance combo step and lock Bea briefly into the swing
	katana_step = (katana_step + 1) % KATANA_COMBO_STEPS
	_combo_window_timer = KATANA_COMBO_WINDOW
	state = State.BEA_ATTACKING
	_swing_timer = lockout
	_active_swing = "y"


# Called via Tween callback on finisher completion to snap rotation back upright.
func _reset_body_rotation() -> void:
	if body_anim and "rotation" in body_anim:
		body_anim.rotation = 0.0


# Spawn arc-shaped particle fan for the AoE telegraph. Direction encodes which
# way the sweep is going: step 0 = L→R, step 1 = R→L, finisher = ring.
func _spawn_katana_slash_fx(step: int, is_finisher: bool) -> void:
	var arc_color: Color = Color(0.25, 0.95, 0.85, 1.0)
	if is_finisher:
		# Spin = ring of sparks around Bea at half-range
		var n: int = 16
		for i in range(n):
			var ang: float = TAU * float(i) / float(n)
			var p: Vector2 = global_position + Vector2(cos(ang), sin(ang)) * (KATANA_RANGE * 0.5)
			FX.spawn_hit_particles(p, arc_color, 2)
	else:
		# Sweep arc fan — alternating direction per step (L→R / R→L / L→R)
		var n2: int = 8
		var base_ang: float = facing.angle()
		var start_off: float = -deg_to_rad(KATANA_ARC_DEG * 0.5)
		var end_off: float   =  deg_to_rad(KATANA_ARC_DEG * 0.5)
		if step == 1:  # R→L on odd steps
			var tmp: float = start_off; start_off = end_off; end_off = tmp
		for i in range(n2):
			var t: float = float(i) / float(n2 - 1)
			var off: float = lerp(start_off, end_off, t)
			var p2: Vector2 = global_position + Vector2(cos(base_ang + off), sin(base_ang + off)) * (KATANA_RANGE * 0.7)
			FX.spawn_hit_particles(p2, arc_color, 2)


# ------------------------------------------------------------
# Weapon visuals (Run 11) — Katana + Naginata Polygon2D-style rigs
# ------------------------------------------------------------
# Both weapon nodes are children of Body. Their rotation is set relative
# to `facing` (which is the world-space attack direction) so the blade
# always reads as pointing toward the target.
#
# Convention: weapon parts are drawn extending in the local +X direction
# from origin (0,0). To orient the weapon to face `facing`, we set
# weapon.rotation = facing.angle(). Swing arcs add/subtract from this base.

func _hide_weapons() -> void:
	if katana_node:
		katana_node.visible = false
	if naginata_node:
		naginata_node.visible = false
	# Kill any in-flight weapon tweens so they don't fire stale rotation
	# updates after the weapon is supposed to be holstered.
	if _katana_tween and _katana_tween.is_valid():
		_katana_tween.kill()
	if _naginata_tween and _naginata_tween.is_valid():
		_naginata_tween.kill()


func _animate_katana(step: int, is_finisher: bool, lockout: float) -> void:
	# Run 115 — 4-hit CrossCode katana animation:
	#   steps 0,2 = L→R sweep; step 1 = R→L sweep; step 3 = full 360° double-spin
	if katana_node == null:
		return
	katana_node.visible = true
	katana_node.position = Vector2.ZERO
	katana_node.scale = Vector2.ONE
	if _katana_tween and _katana_tween.is_valid():
		_katana_tween.kill()
	var base_ang: float = facing.angle()
	if is_finisher:
		# Step 3 — double-spin: blade whirls TAU on top of body's TAU = 2 turns.
		katana_node.rotation = base_ang
		_katana_tween = create_tween()
		_katana_tween.tween_property(katana_node, "rotation", base_ang + TAU, lockout)
	else:
		# Alternating sweep: steps 0,2 = L→R; step 1 = R→L
		var start_off: float = -PI * 0.5
		var end_off: float   =  PI * 0.5
		if step == 1:
			start_off =  PI * 0.5
			end_off   = -PI * 0.5
		katana_node.rotation = base_ang + start_off
		_katana_tween = create_tween()
		_katana_tween.tween_property(katana_node, "rotation",
			base_ang + end_off, lockout)


func _animate_naginata(step: int, lockout: float) -> void:
	# Run 115 — 3-hit naginata animation:
	#   step 0 (thrust): shaft extends forward then retracts
	#   step 1 (sweep): rotation arc through 180°
	#   step 2 (spin+slam): full revolution then forward thrust
	if naginata_node == null:
		return
	naginata_node.visible = true
	naginata_node.scale = Vector2.ONE
	if _naginata_tween and _naginata_tween.is_valid():
		_naginata_tween.kill()
	var base_ang: float = facing.angle()
	naginata_node.rotation = base_ang
	naginata_node.position = Vector2.ZERO

	match step:
		0:
			# Single thrust — punchier stab.
			naginata_node.rotation = base_ang - 0.08
			var thrust_dir: Vector2 = facing
			_naginata_tween = create_tween()
			_naginata_tween.tween_property(naginata_node, "position",
				thrust_dir * 16.0, lockout * 0.35)
			_naginata_tween.tween_property(naginata_node, "position",
				Vector2.ZERO, lockout * 0.65)
		1:
			# Sweep arc — 180° rotation matching the hitbox arc.
			var sweep_half: float = deg_to_rad(NAGINATA_SWEEP_ARC_DEG * 0.5)
			naginata_node.rotation = base_ang - sweep_half
			_naginata_tween = create_tween()
			_naginata_tween.tween_property(naginata_node, "rotation",
				base_ang + sweep_half, lockout)
		2:
			# Spin + slam finisher.
			var spin_start: float = base_ang + deg_to_rad(NAGINATA_SWEEP_ARC_DEG * 0.5)
			var slam_t: float = min(NAGINATA_SLAM_FOLLOW, lockout * 0.4)
			var spin_t: float = max(0.05, lockout - slam_t)
			naginata_node.rotation = spin_start
			_naginata_tween = create_tween()
			_naginata_tween.tween_property(naginata_node, "rotation",
				spin_start + TAU, spin_t)
			_naginata_tween.tween_property(naginata_node, "rotation",
				base_ang, slam_t * 0.4)
			_naginata_tween.parallel().tween_property(naginata_node, "position",
				facing * NAGINATA_SLAM_DIST * 0.45, slam_t)


func _tick_swing(delta: float) -> void:
	if _combo_window_timer > 0.0:
		_combo_window_timer -= delta
	_swing_timer -= delta
	# Run 34 — spin-finisher deferred slam: fire damage + impact ring as the spin ends.
	if _pending_spin_slam:
		_spin_slam_timer -= delta
		if _spin_slam_timer <= 0.0:
			_pending_spin_slam = false
			_fire_spin_slam()
	# Apply glide momentum during the swing lockout (finisher always; hits 1/2 if enabled)
	# Run 116 — stop glide on wall contact so Bea doesn't grind into barriers.
	if _swing_glide_velocity.length() > 0.01:
		velocity = _swing_glide_velocity
		move_and_slide()
		if is_on_wall():
			_swing_glide_velocity = Vector2.ZERO
	if _swing_timer <= 0.0:
		# Clear glide on swing end so subsequent input drives velocity again
		_swing_glide_velocity = Vector2.ZERO
		# Defensive rotation reset for finisher (Tween callback also resets, but if
		# the swing is interrupted by hit_recoil etc., this ensures we end upright).
		if _swing_is_finisher and body_anim:
			body_anim.rotation = 0.0
		_swing_is_finisher = false
		# Defensive: if the swing exits with the slam still pending (timer drift),
		# fire it now so a committed finisher is never unrewarded.
		if _pending_spin_slam:
			_pending_spin_slam = false
			_fire_spin_slam()
		# Holster weapons unless the player is mid-combo (about to swing again).
		# We rely on _katana/_naginata combo step + window being > 0 to know
		# the player is still committed — but weapons can re-show on next tap.
		_hide_weapons()
		_active_swing = ""   # Run 12 — clear active-swing tracker on swing end
		# Run 61b — respect AI vs. player control. Hardcoded PLAYER_CONTROLLED
		# was the silent killer: AI-driven Bea got stuck out of AI_FOLLOW
		# after her first swing and never re-entered combat heuristics.
		state = State.PLAYER_CONTROLLED if player_controlled else State.AI_FOLLOW


# ============================================================
# Dash (Pirouette Dodge) — RECONSTRUCTED Run 12
# Existing bug from Run 10 tooling incident: _start_dash + _tick_dash were
# referenced but never re-added. Pirouette spec (per Run 10 log + GDD §8.2.2):
#   - Mechanically identical to Shino's dash (same speed/duration/iframes/CD)
#   - Visual: body_anim rotation tweens to TAU over DASH_DURATION (one full spin)
#   - Cancels charges and combos cleanly (per universal §8.2.0 rule)
# ============================================================
func _get_max_dash_charges() -> int:
	var max_ch: int = 1
	if RunState.bea_has("extra_banana"):
		max_ch += 1
	max_ch += RunState.sensei_extra_dash   # Sensei Z: Shadow Dash upgrade
	if RunState.bea_has("corrupt_potato"):
		max_ch += 2   # Uprooted corrupt (parity with Shino)
	# Run 130 — Slapstick (Banana Legendary): +1 dash charge.
	if RunState.bea_has("slapstick"):
		max_ch += 1
	return max_ch


func _start_dash() -> void:
	# Prefer movement input direction; fall back to facing if no input held.
	var input_vec: Vector2 = Vector2(
		_move_axis().x,
		_move_axis().y
	)
	dash_direction = input_vec.normalized() if input_vec.length() > 0.1 else facing
	facing = dash_direction   # snap facing so projectile/melee orient with dash
	state = State.DASHING
	_set_barrier_phasing(true)   # Hades-style: dash phases through inner barriers
	dash_timer = DASH_DURATION * (1.20 if RunState.bea_has("zip_dash") else 1.0)
	# Run 131 — Burnout corrupt (Broccoli): dash distance halved (Combat_Boons §6.3).
	if RunState.bea_has("corrupt_broccoli"):
		dash_timer *= 0.5
	dash_charges = max(0, dash_charges - 1)
	if dash_cd_timer <= 0.0:
		dash_cd_timer = DASH_INTERNAL_CD
	iframe_timer = DASH_IFRAME_DURATION
	is_invulnerable = true
	_pirouette_phase = 0.0
	# Run 27f — Bea parity: dash-hazard spawns (Fire Trail / Gas Bookends /
	# Slick Trail), routed through Shino's shared zone helpers.
	if RunState.bea_has("fire_trail") or RunState.bea_has("gas_bookends") or RunState.bea_has("slick_trail"):
		for _pl in get_tree().get_nodes_in_group("player"):
			if RunState.bea_has("fire_trail") and _pl.has_method("_spawn_fire_zone"):
				_pl._spawn_fire_zone(global_position, 32.0, 2.0)
			if RunState.bea_has("gas_bookends") and _pl.has_method("_spawn_gas_bookend"):
				_pl._spawn_gas_bookend(global_position)
			if RunState.bea_has("slick_trail") and _pl.has_method("_spawn_status_zone"):
				var _st_id: String = "sparked" if RunState.greased_lightning_mode else "slippery"
				_pl._spawn_status_zone(global_position, 40.0, 3.0, _st_id, 1, Color(0.85, 0.85, 0.20, 0.80))
				if RunState.is_duo_active("banana_onion"):
					_pl._spawn_status_zone(global_position, 48.0, 3.0, "poison", 1, Color(0.60, 0.85, 0.40, 0.35))
			break
	# Run 128 — Hydro Slide parity: Bea's dash also splashes + puddles
	# (was Shino-only). Spawned at dash start; move to a dash-end hook if
	# landing-point placement reads better in playtest.
	if RunState.bea_has("hydro_slide"):
		for _pl2 in get_tree().get_nodes_in_group("player"):
			if _pl2.has_method("_spawn_hydro_slide_puddle"):
				_pl2._spawn_hydro_slide_puddle(global_position)
				break
	# Run 130 — Slapstick: giant banana / bolt at Bea's dash point (routed
	# through Shino's shared spawner).
	if RunState.bea_has("slapstick"):
		for _pl4 in get_tree().get_nodes_in_group("player"):
			if _pl4.has_method("_spawn_slapstick_drop"):
				_pl4._spawn_slapstick_drop(global_position)
				break
	# Defensive: clear any in-flight swing/combo/charge state so they don't
	# resume mid-dash. Cancel system mandate: dash is top-priority interrupt.
	_clear_swing_state()
	katana_step = 0
	naginata_step = 0
	_combo_window_timer = 0.0
	_naginata_combo_timer = 0.0
	_combo_chain_pending = false
	_combo_chain_timer = 0.0
	_combo_chain_weapon = ""
	_y_hold_dur = -1.0
	_x_hold_dur = -1.0
	_a_hold_dur = -1.0
	_charge_windup_timer = 0.0
	_charging_button = ""
	modulate = Color(1.0, 1.0, 1.0, 1.0)
	if _hitfx:
		_hitfx.set_charge(0)
	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_anim_state("dash")
	# Coconut Overshield (Run 15) — dash grants charges (rarity-scaled).
	_grant_overshield_on_dash()
	# Post-dash speed buffs (mirrors Player.gd).
	if RunState.bea_has("peel_out"):
		_peel_out_timer = 5.0
	if RunState.bea_has("zip_dash"):
		_zip_dash_ms_timer = 4.0
		FX.spawn_hit_particles(global_position, Color(0.95, 0.88, 0.20, 0.80), 5)
	if RunState.bea_has("hot_footed"):
		_hot_footed_timer = HOT_FOOTED_DURATION
	# Evergreen Step — arm the first-hit heal window after this dash (6s CD).
	if RunState.bea_has("evergreen_step") and _evergreen_step_cd_timer <= 0.0:
		_evergreen_step_active = true
		_evergreen_step_cd_timer = 6.0
	# Run 131 — Golden Carrot: a dash arms Bea's next combo finisher as a crit
	# (one finisher per dash; re-arms on the next dash, no stacking).
	if RunState.bea_has("golden_carrot"):
		_golden_carrot_armed = true
	# Afterimage ghost trail — first ghost at start position.
	_dash_ghost_cd = 0.0
	FX.spawn_dash_afterimage(_bea_sprite, global_position,
		Color(0.55, 0.25, 0.85, 0.50))
	FX.play_sound("bea_dash")


# Toggle collision exceptions with every inner-barrier body (group set by
# DreamRoom). ON during a dash → Bea slips through rocks/walls; OFF otherwise.
# Outer walls + gates are separate bodies, so she can't dash out of bounds.
func _set_barrier_phasing(on: bool) -> void:
	for b in get_tree().get_nodes_in_group("dashable_barrier"):
		if b is PhysicsBody2D:
			if on:
				add_collision_exception_with(b)
			else:
				remove_collision_exception_with(b)


func _tick_dash(delta: float) -> void:
	velocity = dash_direction * DASH_SPEED
	# Afterimage ghost trail — spawn ghosts along the dash path.
	_dash_ghost_cd -= delta
	if _dash_ghost_cd <= 0.0:
		_dash_ghost_cd = DASH_GHOST_INTERVAL
		FX.spawn_dash_afterimage(_bea_sprite, global_position,
			Color(0.55, 0.25, 0.85, 0.50))
	move_and_slide()
	# Pirouette body-spin: rotate body_anim from 0 → TAU across DASH_DURATION
	_pirouette_phase += delta
	if body_anim and "rotation" in body_anim:
		body_anim.rotation = TAU * clamp(_pirouette_phase / DASH_DURATION, 0.0, 1.0)
	# Dash duration tick (mirror of Player.gd pattern)
	dash_timer -= delta
	if dash_timer <= 0.0:
		# Run 116 — on ice, carry a fraction of dash speed as momentum
		# so the dash overshoots in a fun slippery way. Off-ice → zero.
		if get_meta("on_ice", false):
			velocity = dash_direction * DASH_SPEED * ICE.DASH_ICE_CARRY
		else:
			velocity = Vector2.ZERO
		_set_barrier_phasing(false)   # restore collision with inner barriers
		if body_anim and "rotation" in body_anim:
			body_anim.rotation = 0.0   # snap upright at dash end
		# Run 150b — Vine Lash (Grape B): arm the 0.5s dash-then-attack window.
		if RunState.bea_has("vine_lash"):
			_vine_lash_window = RunState.VINE_LASH_WINDOW
		# Run 150 — Tuber Burrow (Bruno fix 3): if the dash button is STILL held
		# at dash-end + boon owned + no internal CD → dive underground instead of
		# returning to control. Player-controlled only (mirrors Player.gd).
		if player_controlled and RunState.bea_has("tuber_burrow") \
		and _act_p("dash") and burrow_cd_timer <= 0.0:
			_enter_burrow()
			return
		# Return to player-control if we were under player control;
		# otherwise the AI behavior tick resumes from AI_FOLLOW.
		state = State.PLAYER_CONTROLLED if player_controlled else State.AI_FOLLOW


# -------------------------------------------------------
# Run 150 — Tuber Burrow (Potato B, Bruno fix 3) — Bea parity with Player.gd.
# -------------------------------------------------------

## Enter burrow state. Called from _tick_dash when the dash ends button-held.
func _enter_burrow() -> void:
	state = State.BEA_BURROWING
	burrow_timer = BURROW_MAX_DURATION
	is_invulnerable = true
	iframe_timer = 0.0  # burrow manages its own invuln; clear dash iframe so it doesn't fight
	velocity = Vector2.ZERO
	# Hide Bea's sprite and show the dirt-mound placeholder.
	if _bea_sprite:
		_bea_sprite.visible = false
	if body_anim and body_anim.has_method("set_visible"):
		body_anim.set_visible(false)
	if _burrow_mound == null:
		var mound_script: GDScript = load("res://scripts/BurrowMound.gd")
		if mound_script:
			_burrow_mound = mound_script.new()
		else:
			_burrow_mound = Node2D.new()
		add_child(_burrow_mound)
	_burrow_mound.visible = true
	FX.spawn_burst_particles(global_position, Color(0.50, 0.35, 0.18, 0.95), 18)
	FX.screen_shake(FX.SHAKE_LIGHT, 0.15)
	FX.play_sound("ground_pound", 0.7)


## Per-physics tick while underground.
func _tick_burrow(delta: float) -> void:
	burrow_timer -= delta
	is_invulnerable = true   # iframe expiry must not strip burrow invuln
	# Free movement underground at reduced speed.
	var input_vec: Vector2 = _move_axis()
	if input_vec.length() > 1.0:
		input_vec = input_vec.normalized()
	if input_vec.length() > 0.1:
		facing = input_vec.normalized()
	velocity = input_vec * move_speed * BURROW_MOVE_SPEED_MULT
	move_and_slide()
	if _burrow_mound != null:
		_burrow_mound.queue_redraw()
	# Periodic dirt particles while moving.
	var phase: float = fmod(burrow_timer, 0.35)
	if phase < delta and input_vec.length() > 0.1:
		FX.spawn_hit_particles(global_position, Color(0.48, 0.33, 0.16, 0.80), 4)
	# Emerge conditions: button released OR max duration elapsed.
	if not _act_p("dash") or burrow_timer <= 0.0:
		_emerge()


## Rise from underground: AoE hit + earth statuses + visuals (mirrors Player.gd).
func _emerge() -> void:
	state = State.PLAYER_CONTROLLED if player_controlled else State.AI_FOLLOW
	is_invulnerable = false
	burrow_cd_timer = BURROW_INTERNAL_CD
	if _bea_sprite:
		_bea_sprite.visible = true
	if _burrow_mound != null:
		_burrow_mound.visible = false
	var base_dmg: int = int(round(float(NAGINATA_SWEEP_DAMAGE) * BURROW_RISE_DAMAGE_MULT * RunState.get_char_damage_mult("bea")))
	if RunState.char_family_count("bea", "Potato") > 0:
		base_dmg = int(float(base_dmg) * 1.20)   # Potato earth identity bonus
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or (e.has_method("is_alive") and not e.is_alive()):
			continue
		if global_position.distance_to(e.global_position) > BURROW_RISE_RADIUS:
			continue
		var kb_dir: Vector2 = (e.global_position - global_position).normalized()
		if e.has_method("take_damage"):
			e.set_meta("last_damager", "bea")   # kill attribution
			e.take_damage(base_dmg, kb_dir)
		var ts: Variant = e.get("status") if e.has_method("get") else null
		if ts != null and ts.has_method("apply"):
			ts.apply("cracked_soil", 4.0, 1)
			ts.apply("stagger", 0.5, 1)
			if ts.get_stacks("cracked_soil") >= 3:
				if RunState.shino_has("petrify") or RunState.bea_has("petrify"):
					ts.apply("bash", 3.0, 1)
					ts.apply("vulnerable", 3.0, 2)
				else:
					ts.apply("root", 1.5, 1)
				ts.remove("cracked_soil")
				FX.spawn_burst_particles(e.global_position, Color(0.45, 0.30, 0.15, 0.90), 10)
	FX.spawn_burst_particles(global_position, Color(0.52, 0.38, 0.18, 1.0), 24)
	FX.spawn_hit_particles(global_position + Vector2(0, -20), Color(0.60, 0.45, 0.22, 0.9), 12)
	FX.screen_shake(4.0, 0.20)


# -------------------------------------------------------
# Run 150b — Vine Lash (Grape B) — mirror of Player.gd.
# Damage-only vines (no pull / root per Bruno); each landed vine routes
# through _on_hit_connected (chi + combo — Grape's identity).
# -------------------------------------------------------
func _maybe_fire_vine_lash() -> void:
	if _vine_lash_window <= 0.0 or not RunState.bea_has("vine_lash"):
		return
	_vine_lash_window = 0.0
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
	var vine_col := Color(0.45, 0.75, 0.30, 0.95)
	var lashes: int = 0
	for e2 in targets:
		if lashes >= RunState.VINE_LASH_COUNT:
			break
		lashes += 1
		var dmg: int = _bea_scale_damage(RunState.VINE_LASH_DAMAGE, false, false, e2, "ranged")
		e2.set_meta("last_damager", "bea")
		e2.take_damage(dmg, ((e2 as Node2D).global_position - global_position).normalized() * 0.25)
		_spawn_vine_visual(global_position, (e2 as Node2D).global_position, vine_col)
		FX.spawn_hit_particles((e2 as Node2D).global_position, vine_col, 5)
	# Whiff vines: fan the unused lashes so the boon always reads on screen.
	if lashes < RunState.VINE_LASH_COUNT:
		var half_fan: float = deg_to_rad(RunState.VINE_LASH_CONE_DEG * 0.5)
		for i in range(RunState.VINE_LASH_COUNT - lashes):
			var t: float = 0.0 if RunState.VINE_LASH_COUNT <= 1 else \
				(float(i + lashes) / float(RunState.VINE_LASH_COUNT - 1)) * 2.0 - 1.0
			var vdir: Vector2 = facing.rotated(t * half_fan)
			_spawn_vine_visual(global_position, global_position + vdir * RunState.VINE_LASH_RANGE * 0.8, vine_col)
	FX.play_sound("kunai_hit", 0.5)


# Quick whip-line visual (mirror of Player.gd._spawn_vine_visual).
func _spawn_vine_visual(from_pos: Vector2, to_pos: Vector2, col: Color) -> void:
	var vine := Line2D.new()
	vine.width = 4.0
	vine.default_color = col
	vine.z_index = 7
	var mid: Vector2 = (from_pos + to_pos) * 0.5
	var perp: Vector2 = (to_pos - from_pos).orthogonal().normalized()
	var bow: Vector2 = mid + perp * (to_pos - from_pos).length() * 0.12
	for i in range(9):
		var t: float = float(i) / 8.0
		var p: Vector2 = from_pos.lerp(bow, t).lerp(bow.lerp(to_pos, t), t)
		vine.add_point(p)
	get_tree().current_scene.add_child(vine)
	var tw: Tween = vine.create_tween()
	tw.tween_property(vine, "modulate:a", 0.0, 0.28)
	tw.tween_callback(vine.queue_free)


# -------------------------------------------------------
# Coconut family helpers (Run 15) — mirror of Player.gd.
# Bash on Y (katana) hits, ShellBreaker on X (naginata) hits,
# Overshield on dash, Nutshell on overshield break, Hard Landing
# vetoes Bash while charging.
# -------------------------------------------------------
# can_receive_status moved to HeroBase (Batch 3). Per-hero hooks it calls:
func _hero_has(id: String) -> bool:
	return RunState.bea_has(id)

func _emit_hp_signal() -> void:
	emit_signal("bea_hp_changed", current_hp, get_effective_max_hp())

func _emit_chi_signal() -> void:
	emit_signal("bea_chi_changed", current_chi, get_effective_max_chi())

func _in_charge_or_release_state() -> bool:
	return state in [State.BEA_CHARGING, State.BEA_CHARGED, State.BEA_WHIRLING, State.BEA_DIVING, State.BEA_FLURRYING]

func _is_charging_state() -> bool:
	return state == State.BEA_CHARGING or state == State.BEA_CHARGED


func _grant_overshield_on_dash() -> void:
	# Run 150b (Bruno ruling) — holder-only: Bea's dash grants read HER config.
	if RunState.get_overshield_grant_on_dash("bea") <= 0:
		return
	var cap: int = max(1, RunState.get_overshield_max("bea"))
	var new_total: int = min(cap, overshield_charges + RunState.get_overshield_grant_on_dash("bea"))
	if new_total > overshield_charges:
		overshield_charges = new_total
		_refresh_overshield_aura()
		FX.play_sound("overshield_gain", 0.85)
		# Run 19 — Shell Cluster duo (Coconut + Grape): mirror-share to Shino.
		# Batch 3 — unified into HeroBase._shell_cluster_mirror_share (hero_id-keyed).
		_shell_cluster_mirror_share()


# Run 28 — Grape+Watermelon Cluster Splash AoE (Bea mirror of Player._apply_cluster_splash).
func _bea_apply_cluster_splash(origin: Vector2) -> void:
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


# _bea_shell_cluster_mirror_share + _bea_shell_cluster_mirror_pending moved to
# HeroBase._shell_cluster_mirror_share (Batch 3; hero_id-keyed partner group).


# Run 22 — Vital Harvest duo: Player can heal Bea when a crit occurs.
# Run 23 — _try_vital_harvest_crit_heal: Bea-side crit heal mirror.
# Called immediately after _bea_scale_damage (which runs roll_crit_mult and sets
# RunState.last_crit_result). Heals Bea + Shino 3% max HP on a crit landing.
func _try_vital_harvest_crit_heal() -> void:
	if not RunState.last_crit_result:
		return
	var vh_pct: float = RunState.get_vital_harvest_heal_pct()
	if vh_pct <= 0.0:
		return
	# Heal Bea
	var bea_heal: int = max(1, int(round(float(get_effective_max_hp()) * vh_pct)))
	current_hp = min(get_effective_max_hp(), current_hp + bea_heal)
	emit_signal("bea_hp_changed", current_hp, get_effective_max_hp())
	FX.spawn_hit_particles(global_position, Color(0.90, 0.60, 0.20, 1.0), 4)
	# Heal Shino too (symmetric: whoever crits heals both)
	if _shino != null and is_instance_valid(_shino) and _shino.has_method("get_effective_max_hp"):
		var shino_heal: int = max(1, int(round(float(_shino.get_effective_max_hp()) * vh_pct)))
		if "current_hp" in _shino:
			_shino.current_hp = min(_shino.get_effective_max_hp(), _shino.current_hp + shino_heal)
			_shino.emit_signal("hp_changed", _shino.current_hp, _shino.get_effective_max_hp())
			FX.spawn_hit_particles(_shino.global_position, Color(0.90, 0.60, 0.20, 1.0), 4)


func start_juicebox_regen() -> void:
	# Called by Player.gd when a Juice Box is collected — both heroes regen.
	_bea_juicebox_regen_timer = 10.0
	_bea_juicebox_regen_accum = 0.0

var _bea_juicebox_regen_timer: float = 0.0
var _bea_juicebox_regen_accum: float = 0.0

func _tick_bea_juicebox_regen(delta: float) -> void:
	if _bea_juicebox_regen_timer <= 0.0:
		return
	_bea_juicebox_regen_timer -= delta
	_bea_juicebox_regen_accum += 1.0 * delta
	if _bea_juicebox_regen_accum >= 1.0:
		var heal: int = int(floor(_bea_juicebox_regen_accum))
		_bea_juicebox_regen_accum -= float(heal)
		var mx: int = get_effective_max_hp()
		if current_hp < mx:
			current_hp = min(mx, current_hp + heal)
			emit_signal("bea_hp_changed", current_hp, mx)


# heal_external, grant_overshield_external moved to HeroBase (Batch 3). The Batch 0
# ROT-2 (bea_hp_changed emit) and ROT-3 (current_hp<=0 guard) fixes are preserved
# in the unified base versions (emit via _emit_hp_signal; guard inline). Bea's
# heal particle FX (Color(0.90,0.60,0.20,1.0), 4) is set via _heal_fx_* in _ready.


func _consume_overshield() -> bool:
	# Returns true if a charge absorbed the hit (caller should skip damage).
	if overshield_charges <= 0:
		return false
	# Run 27b — on-absorb duo procs (Hot Shell / Smokestack), Bea-side.
	_overshield_absorb_duo_procs()
	overshield_charges -= 1
	_refresh_overshield_aura()
	FX.play_sound("overshield_break", 1.0)
	# Visual: small white burst at Bea + medium shake.
	FX.spawn_burst_particles(global_position, Color(1.0, 1.0, 1.0, 0.95), 14)
	FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_SHORT)
	# Nutshell — on break, Bash all nearby enemies briefly.
	# Run 27 — Slip 'n Shell duo (Banana+Coconut) reuses the same shockwave.
	if RunState.bea_has("nutshell") or RunState.is_duo_active("banana_coconut"):
		_fire_nutshell_shockwave()
	# Run 19/20 — Adamantium Husk (Coconut Legendary): on break, fire shockwave +
	# grant 2s i-frames. The shockwave reuses Nutshell visuals; it's additive.
	if RunState.has_method("adamantium_active") and RunState.adamantium_active():
		_on_overshield_broken_legendary()
	return true


func _on_overshield_broken_legendary() -> void:
	# Adamantium Husk (Coconut Legendary): shockwave + 2s i-frames on overshield break.
	_fire_nutshell_shockwave()
	is_invulnerable = true
	iframe_timer = max(iframe_timer, 2.0)


# ============================================================
# Run 133 — Bea on-kill hook (mirror of Player._on_enemy_killed / 4204).
# ============================================================
# _bea_note_kill is called at every Bea hit site right after e.take_damage:
# it detects a KO (was alive going in, dead coming out) and fires the on-kill
# boons. Kept as a shared helper so the six hit sites (katana tap, naginata
# line/arc/circle, vortex tick, Kunai) each only add two lines.
func _bea_note_kill(e: Node, was_alive: bool) -> void:
	if not is_instance_valid(e):
		return
	if was_alive and e.has_method("is_alive") and not e.is_alive():
		var was_poisoned: bool = (e.get("status") != null and e.status.has_method("has") and e.status.has("poison"))
		_bea_on_enemy_killed(e.global_position, was_poisoned)


func _bea_on_enemy_killed(pos: Vector2, was_poisoned: bool) -> void:
	# Called whenever Bea lands a killing blow (from any hit path).
	_bea_last_killed_pos = pos
	_bea_last_killed_was_poisoned = was_poisoned
	# Battle Shell (Coconut): KO grants 1 overshield charge for BATTLE_SHELL_DURATION.
	if RunState.bea_has("battle_shell"):
		grant_overshield_external(1)
		_battle_shell_timer = RunState.BATTLE_SHELL_DURATION
	# Rotten Core (Onion): if the killed enemy was poisoned, burst a stink cloud.
	if RunState.bea_has("rotten_core") and was_poisoned:
		_spawn_bea_rotten_core_burst(pos)


func _spawn_bea_rotten_core_burst(pos: Vector2) -> void:
	# Mirror of Player._spawn_rotten_core_burst (4218). Immediate 2-stack poison
	# spread is the guaranteed minimum; the lingering zone reuses Shino's
	# _spawn_status_zone (routed through the player group, like Bea's trail zones).
	FX.spawn_burst_particles(pos, Color(0.50, 0.85, 0.25, 0.9), 14)
	# Initial 2-stack spread (the death-burst itself).
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		if pos.distance_to(e.global_position) < 120.0:
			if e.get("status") != null and e.status.has_method("apply"):
				e.status.apply("poison", 4.0, 2)
			FX.spawn_hit_particles(e.global_position, Color(0.50, 0.85, 0.25, 0.6), 4)
	# Lingering poison puddle — reuse Shino's zone helper if a player exposes it.
	for _pl in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(_pl) and _pl.has_method("_spawn_status_zone"):
			_pl._spawn_status_zone(pos, 60.0, 3.0, "poison", 1, Color(0.50, 0.85, 0.25, 0.55))
			break


# Run 27f — Corrupt + Legendary per-hit procs (Bea melee). Mirrors Player's
# block: Concussive Hit, Burnout random CC, Chaos Carrot, Solar Flare
# explosion, Thunderstruck chain, Mountain King ring, Heatwave finisher.
func _bea_corrupt_hit_procs(body: Node, final_dmg: int, is_finisher: bool) -> void:
	if not is_instance_valid(body) or not (body is Node2D):
		return
	if RunState.bea_has("corrupt_coconut"):
		for ce in get_tree().get_nodes_in_group("enemy"):
			if ce != body and is_instance_valid(ce) and ce is Node2D \
			and ce.global_position.distance_to(body.global_position) <= 60.0 \
			and ce.has_node("StatusComponent"):
				ce.get_node("StatusComponent").apply("bash", 0.3, 1)
	if RunState.bea_has("corrupt_broccoli") and randf() < 0.30 and body.has_node("StatusComponent"):
		var _cc_pick: Array = [["bash", 0.5], ["stagger", 0.7], ["root", 1.0]]
		var _cc: Array = _cc_pick[randi() % _cc_pick.size()]
		body.get_node("StatusComponent").apply(_cc[0], _cc[1], 1)
	if RunState.bea_has("corrupt_carrot") and RunState.last_crit_result and body.has_node("StatusComponent"):
		var _dbf: Array = [["burning", 3.0, 2], ["wet", 4.0, 2], ["chilled", 4.0, 2],
			["poison", 4.0, 2], ["cracked_soil", 4.0, 1], ["slippery", 3.0, 1],
			["sparked", 3.0, 1], ["vulnerable", 5.0, 1]]
		var _db: Array = _dbf[randi() % _dbf.size()]
		body.get_node("StatusComponent").apply(_db[0], _db[1], _db[2])
		match randi() % 2:
			0: _peel_out_timer = 5.0
			1: _hot_footed_timer = 3.0
	if RunState.bea_has("corrupt_pepper"):
		var _sf_dmg: int = max(1, int(round(float(final_dmg) * 0.30 * RunState.fire_damage_mult)))
		FX.spawn_burst_particles(body.global_position, Color(1.0, 0.45, 0.10, 0.95), 10)
		for se in get_tree().get_nodes_in_group("enemy"):
			if se != body and is_instance_valid(se) and se is Node2D \
			and se.global_position.distance_to(body.global_position) <= 120.0 \
			and se.has_method("take_damage"):
				se.take_damage(_sf_dmg, (se.global_position - body.global_position).normalized() * 40.0)
	if RunState.bea_has("corrupt_banana"):
		_bea_banana_lightning_chain(body, 3.0)
	if RunState.bea_has("mountain_king") and _ingrained_time >= RunState.INGRAINED_THRESHOLD:
		FX.spawn_burst_particles(body.global_position, Color(0.65, 0.50, 0.30, 0.95), 12)
		for me in get_tree().get_nodes_in_group("enemy"):
			if is_instance_valid(me) and me is Node2D \
			and me.global_position.distance_to(body.global_position) <= 120.0:
				if me.has_method("take_damage"):
					me.take_damage(6, (me.global_position - body.global_position).normalized() * 30.0)
				if me.has_node("StatusComponent"):
					me.get_node("StatusComponent").apply("cracked_soil", 4.0, 1)
	if is_finisher and RunState.bea_has("heatwave"):
		for _pl in get_tree().get_nodes_in_group("player"):
			if _pl.has_method("_spawn_fire_zone"):
				_pl._spawn_fire_zone(body.global_position, 96.0, 4.0)
				break


# gain_chi_external, peel_restoration_slip_credit moved to HeroBase (Batch 3).


# Run 27b — Hot Shell (Coconut+Pepper) + Smokestack (Coconut+Onion) duo procs
# when Bea's overshield absorbs a hit. Smokestack cloud routes through Shino's
# zone helper (BeaAI has no zone spawner of its own).
func _overshield_absorb_duo_procs() -> void:
	if RunState.is_duo_active("coconut_pepper") and _hot_shell_icd <= 0.0:
		var best: Node2D = null
		var best_d: float = 240.0
		for e in get_tree().get_nodes_in_group("enemy"):
			if e is Node2D and is_instance_valid(e) and (not e.has_method("is_alive") or e.is_alive()):
				var d: float = e.global_position.distance_to(global_position)
				if d < best_d:
					best = e
					best_d = d
		if best != null:
			_hot_shell_icd = 1.0
			FX.spawn_burst_particles(best.global_position, Color(1.0, 0.55, 0.15, 0.95), 12)
			if best.has_method("take_damage"):
				best.take_damage(6, (best.global_position - global_position).normalized() * 60.0)
			if best.has_node("StatusComponent"):
				best.get_node("StatusComponent").apply("burning", 3.0, 2)
	if RunState.is_duo_active("coconut_onion") and _smokestack_icd <= 0.0:
		_smokestack_icd = 2.0
		for _pl in get_tree().get_nodes_in_group("player"):
			if _pl.has_method("_spawn_status_zone"):
				_pl._spawn_status_zone(global_position, 80.0, 5.0, "poison", 1, Color(0.55, 0.75, 0.45, 0.45))
				break
		for e in get_tree().get_nodes_in_group("enemy"):
			if e is Node2D and is_instance_valid(e) \
			and e.global_position.distance_to(global_position) <= 80.0 \
			and e.has_node("StatusComponent"):
				e.get_node("StatusComponent").apply("bash", 0.2, 1)


# _fire_nutshell_shockwave, _refresh_overshield_aura moved to HeroBase (Batch 3).


# Per-hit Bash roll — called for melee enemy hits from katana / naginata strikes.
# Returns true on proc (caller adds RunState.bash_bonus_damage to outgoing damage).
func _try_apply_coconut_bash(target: Node) -> bool:
	if RunState.bash_on_hit_chance <= 0.0:
		return false
	if randf() >= RunState.bash_on_hit_chance:
		return false
	var target_status: Variant = target.get("status") if target.has_method("get") else null
	if target_status != null and target_status.has_method("apply"):
		target_status.apply("bash", 1.0)
		FX.play_sound("bash_proc", 0.8)
		FX.spawn_hit_particles(target.global_position, Color(0.80, 0.55, 0.20, 1.0), 6)
	return true


# _try_apply_shell_breaker moved to HeroBase (Batch 3).


# Run 17 — Bea's mirror of Player._apply_family_statuses_on_hit. See Player.gd
# for documentation. Pragmatic family-count gate; per-slot wiring lands when
# Y/X/A/B/Charge/Ult slot boons are filled. Stack counts follow LOCKED v0.28.
var _bea_tidal_refresh_per_target: Dictionary = {}
# Run 58 — Bea fights with sharp steel on every attack (katana, naginata, kunai),
# so all of her hits apply a light stacking Bleed DoT.
# Run 111 — bleed is now FLAT 1 dmg/stack/sec (was %-max-HP), and EVERY hit applies
# exactly 1 stack, shared across A/X/Y, capped at 3 stacks (see StatusComponent bleed def).
const BEA_BLADE_BLEED_DUR: float = 4.0
const BEA_BLADE_BLEED_STACKS: int = 1

func _bea_apply_family_statuses_on_hit(target: Node, is_primary: bool, is_heavy: bool, _is_ranged: bool, _is_charge: bool, is_ult: bool) -> void:
	if not is_instance_valid(target):
		return
	# Run 27f — Static Charge (Banana passive, Bea ranged): every 3rd ranged
	# hit drops caltrops at the target (default) or chains + Sparks (GL).
	if _is_ranged and RunState.bea_has("static_charge"):
		_static_charge_count += 1
		if _static_charge_count >= 3:
			_static_charge_count = 0
			if RunState.greased_lightning_mode:
				_bea_banana_lightning_chain(target, 3.0)
			elif target is Node2D:
				for _pl in get_tree().get_nodes_in_group("player"):
					if _pl.has_method("_spawn_status_zone"):
						_pl._spawn_status_zone(target.global_position, 40.0, 4.0, "slippery", 1, Color(0.95, 0.85, 0.30, 0.55))
						break
	var ts: Variant = target.get("status") if target.has_method("get") else null
	if ts == null or not ts.has_method("apply"):
		return

	# --- Run 59 — A-slot ranged-transform boons (Bea) ---
	# Mirror of Shino's wiring; gated per-character (bea_has). Zone spawns route
	# through a player node since the spawn helpers live on Player.gd.
	if _is_ranged:
		if RunState.bea_has("fireball"):
			var fb_dur: float = 3.0 * (1.5 if RunState.bea_has("slow_cook") else 1.0)
			ts.apply("burning", fb_dur, 2)
			for _pl in get_tree().get_nodes_in_group("player"):
				if _pl.has_method("_spawn_fire_zone"):
					_pl._spawn_fire_zone(target.global_position, 28.0, 1.5)
					break
		if RunState.bea_has("coconut_volley") and randf() < 0.30:
			ts.apply("bash", 0.4, 1)
			if target.has_method("take_damage"):
				var cv_dmg: int = RunState.bash_bonus_damage if RunState.bash_bonus_damage > 0 else 4
				target.take_damage(cv_dmg, Vector2.ZERO)
		if RunState.bea_has("stink_bomb") and not RunState.bea_has("corrupt_onion"):
			for _pl in get_tree().get_nodes_in_group("player"):
				if _pl.has_method("_spawn_gas_bookend"):
					_pl._spawn_gas_bookend(target.global_position)
					break

	# --- Run 58/111 — Bleed on every blade hit (Bea's universal "sharp steel").
	# Always 1 stack per hit (shared A/X/Y, caps at 3 in the status def). ---
	ts.apply("bleed", BEA_BLADE_BLEED_DUR, BEA_BLADE_BLEED_STACKS)

	# --- Watermelon: Wet (water) / Chilled (Gelato) ---
	# Run 129 — Bea parity: gate per SLOT BOON like Shino (was: any Watermelon
	# boon soaked every hit). Slot boons are the only Wet appliers; Ult always
	# applies if any Watermelon boon is owned. Cold Waters corrupt bypasses.
	if RunState.char_family_count("bea", "Watermelon") > 0:
		var wet_id: String = "chilled" if RunState.melon_gelato_mode else "wet"
		var wet_dur: float = 4.0
		var wet_stacks: int = 0
		if is_ult:
			wet_stacks = 5
		elif is_heavy and RunState.bea_has("heavy_tide"):
			wet_stacks = 2
		elif is_primary and RunState.bea_has("hydro_jab"):
			wet_stacks = 1
		elif not is_primary and not is_heavy and RunState.bea_has("bubble_shot"):
			wet_stacks = 2
		if RunState.bea_has("corrupt_watermelon"):
			wet_stacks = max(wet_stacks, 1)   # corrupt: every hit dual-stacks
		if wet_stacks > 0:
			ts.apply(wet_id, wet_dur, wet_stacks)
			# Run 128 — Seed Spit rework mirror (Bruno): Bea ranged impacts splash —
			# neighbors knocked back + soaked, slowing puddle (1 Chilled/sec) left.
			if RunState.bea_has("bubble_shot") and not is_primary and not is_heavy \
			and not is_ult and target is Node2D:
				var _ss_pos: Vector2 = (target as Node2D).global_position
				for _ss_e in get_tree().get_nodes_in_group("enemy"):
					if _ss_e != target and is_instance_valid(_ss_e) and _ss_e is Node2D \
					and _ss_pos.distance_to(_ss_e.global_position) < 80.0:
						if _ss_e.has_method("take_damage"):
							_ss_e.take_damage(1, (_ss_e.global_position - _ss_pos).normalized())
						var _ss_ts: Variant = _ss_e.get("status") if _ss_e.has_method("get") else null
						if _ss_ts != null and _ss_ts.has_method("apply"):
							_ss_ts.apply(wet_id, wet_dur, 1)
				for _pl3 in get_tree().get_nodes_in_group("player"):
					if _pl3.has_method("_spawn_status_zone"):
						_pl3._spawn_status_zone(_ss_pos, 56.0, 3.0, "chilled", 1, Color(0.45, 0.80, 0.95, 0.45))
						break
			# Run 27f — Cold Waters corrupt: apply BOTH Soaked AND Chilled.
			if RunState.bea_has("corrupt_watermelon"):
				ts.apply("chilled" if wet_id == "wet" else "wet", wet_dur, wet_stacks)
			if RunState.bea_has("tidal_refresh"):
				_bea_try_tidal_refresh_chi(target)

	# --- Pepper: Burning ---
	if RunState.char_family_count("bea", "Pepper") > 0:
		var burn_dur: float = 3.0
		if RunState.bea_has("slow_cook"):
			burn_dur *= 1.5
		# Run 129 — Bea parity: gate per SLOT BOON like Shino (was: any Pepper
		# boon burned every hit).
		var burn_stacks: int = 0
		if is_ult:
			burn_stacks = 5
		elif is_heavy and RunState.bea_has("searing_strike"):
			burn_stacks = 2
		elif is_primary and RunState.bea_has("spicy_jab"):
			burn_stacks = 1
		# Run 23 — Shock Ignition (Pepper + Grape duo) mirror. Shocked
		# enemies have +25% chance to take an extra burn stack on Pepper hit.
		if burn_stacks > 0 and ts.has("shocked") and RunState.shock_ignition_active():
			if randf() < RunState.get_shock_ignition_burn_bonus():
				burn_stacks += 1
		# Run 59 — Pyromania (Pepper passive, Bea): consecutive-hit Burn streak.
		if burn_stacks > 0 and RunState.bea_has("pyromania"):
			var _now: float = float(Time.get_ticks_msec()) / 1000.0
			if _now - _pyromania_last_hit <= 2.0:
				_pyromania_streak = min(_pyromania_streak + 1, 5)
			else:
				_pyromania_streak = 1
			_pyromania_last_hit = _now
			burn_stacks += clampi(_pyromania_streak - 1, 0, 3)
		# Run 19 — Elemental Synergy pre-checks (additive-only, no consumption).
		var was_wet_pre: bool         = ts.is_wet()
		var was_frostbitten_pre: bool = ts.is_frostbitten()
		# Run 129 — the whole fire-hit payload only fires when a Burn slot
		# boon actually made this a fire hit (parity with Shino's gating).
		if burn_stacks > 0:
			# Run 27f — Solar Flare corrupt: Burn application disabled (explosions
			# replace the DoT identity — see per-hit procs).
			if not RunState.bea_has("corrupt_pepper"):
				ts.apply("burning", burn_dur, burn_stacks)
			# Run 27 — Magma Vein synergy (Potato×Pepper): fire hit on a Cracked
			# Soil target erupts a small fire patch (routed via Shino's zone helper).
			if RunState.is_synergy_active("magma_vein") and ts.has("cracked_soil"):
				for _pl in get_tree().get_nodes_in_group("player"):
					if _pl.has_method("_spawn_fire_zone"):
						_pl._spawn_fire_zone(target.global_position, 32.0, 3.0)
						break
			if was_frostbitten_pre and RunState.is_synergy_active("thaw_burst"):
				_bea_trigger_thaw_burst(target)
			elif was_wet_pre and RunState.is_synergy_active("steam_burst"):
				_bea_trigger_steam_burst(target)

	# --- Banana: Slippery/Greased (default) or Sparked/Bolted (GL) ---
	# Run 129 — Bea parity: gate per SLOT BOON like Shino (was: any Banana
	# boon slicked every hit).
	var _ban_ok: bool = is_ult \
		or (is_heavy and RunState.bea_has("voltaic_strike")) \
		or (is_primary and RunState.bea_has("peel_slap")) \
		or (not is_primary and not is_heavy and not is_ult and RunState.bea_has("bananarang"))
	if RunState.char_family_count("bea", "Banana") > 0 and _ban_ok:
		# Run 23 — Bruise Peel pre-check (Bea mirror).
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
		# Run 19 — chain-lightning (Bea mirror).
		if RunState.greased_lightning_mode:
			ts.apply("shocked", slip_dur, 1)
			_bea_banana_lightning_chain(target, slip_dur)
		# Run 23 — Bruise Peel apply (Bea mirror).
		if was_slipping_pre and RunState.bruise_peel_active():
			var stagger_dur: float = RunState.get_bruise_peel_stagger_dur()
			if stagger_dur > 0.0:
				ts.apply("stagger", stagger_dur, 1)
		# Run 24 — Banana+Pepper "Slip & Burn" (Bea mirror).
		if was_slipping_pre and RunState.banana_pepper_active():
			var bp_chance: float = RunState.get_banana_pepper_ignite_chance()
			if randf() < bp_chance:
				ts.apply("burning", 4.0, 2)

	# --- Onion: Poison ---
	# Run 129 — Bea parity: gate per SLOT BOON like Shino (was: any Onion
	# boon poisoned every hit).
	if RunState.char_family_count("bea", "Onion") > 0:
		var p_dur: float = 4.0
		if RunState.bea_has("chronic_reek"):
			p_dur *= 1.5
		var p_stacks: int = 0
		if is_ult:
			p_stacks = 5
		elif is_heavy and RunState.bea_has("tear_strike"):
			p_stacks = 2
		elif is_primary and RunState.bea_has("pungent_jab"):
			p_stacks = 1
		# Run 27f — Fermented Wrath corrupt: attack-applied Poison disabled
		# (the walking miasma aura replaces it).
		if p_stacks > 0 and not RunState.bea_has("corrupt_onion"):
			ts.apply("poison", p_dur, p_stacks)

	# --- Potato: Cracked Soil on heavy X; 3 stacks → Earthbind Root ---
	# Run 129 — Bea parity: Cracked Soil requires the Rock Smash X boon.
	if RunState.char_family_count("bea", "Potato") > 0 and is_heavy \
	and RunState.bea_has("rock_smash"):
		ts.apply("cracked_soil", 4.0, 1)
		if ts.get_stacks("cracked_soil") >= 3:
			# Run 27f — Petrify (Potato Legendary): Earthbind → 3s Stun + Vulnerable.
			if RunState.shino_has("petrify") or RunState.bea_has("petrify"):
				ts.apply("bash", 3.0, 1)
				ts.apply("vulnerable", 3.0, 2)
			else:
				ts.apply("root", 1.5, 1)
			ts.remove("cracked_soil")


# Run 19 — Banana chain-lightning (Bea mirror of Player.gd).
const BANANA_CHAIN_RADIUS_BEA: float = 140.0
const BANANA_CHAIN_MAX_JUMPS_BEA: int = 2
const BANANA_CHAIN_DMG_PCT_BEA: float = 0.30

func _bea_banana_lightning_chain(primary_target: Node, dur: float) -> void:
	if primary_target == null or not is_instance_valid(primary_target):
		return
	var tree := get_tree()
	if tree == null:
		return
	var visited: Dictionary = { primary_target.get_instance_id(): true }
	var origin: Vector2 = primary_target.global_position
	var jumps_done: int = 0
	var candidates: Array = []
	for body in tree.get_nodes_in_group("enemy"):
		if not is_instance_valid(body) or body == primary_target:
			continue
		if visited.has(body.get_instance_id()):
			continue
		var dist: float = (body.global_position - origin).length()
		if dist > BANANA_CHAIN_RADIUS_BEA:
			continue
		candidates.append({"body": body, "d": dist})
	candidates.sort_custom(func(a, b): return float(a["d"]) < float(b["d"]))
	var _bea_max_jumps: int = BANANA_CHAIN_MAX_JUMPS_BEA + (1 if RunState.voltaic_engine_taken else 0)
	# Run 27 — Grounding synergy (Potato×Banana): +1 chain jump when the
	# primary target has Cracked Soil or is Earthbound (rooted).
	var _pts: Variant = primary_target.get("status") if primary_target.has_method("get") else null
	if _pts != null and RunState.is_synergy_active("grounding") \
	and (_pts.has("cracked_soil") or _pts.has("root")):
		_bea_max_jumps += 1
	for c in candidates:
		if jumps_done >= _bea_max_jumps:
			break
		var b: Node = c["body"]
		var ts2: Variant = b.get("status") if b.has_method("get") else null
		if ts2 == null or not ts2.has_method("apply"):
			continue
		ts2.apply("sparked", dur, 1)
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
		var tick: int = max(1, int(round(float(RunState.HULK_SMASH_BASE_DAMAGE) * BANANA_CHAIN_DMG_PCT_BEA)))
		if b.has_method("take_damage"):
			b.take_damage(tick, Vector2.ZERO)
		_bea_spawn_chain_arc(origin, b.global_position)
		jumps_done += 1


func _bea_spawn_chain_arc(from: Vector2, to: Vector2) -> void:
	var parent: Node = get_tree().get_root().get_node_or_null("World")
	if parent == null:
		parent = get_tree().get_current_scene()
	if parent == null:
		return
	var arc := Line2D.new()
	arc.default_color = Color(0.95, 0.65, 1.0, 0.95)   # tinted slightly purple (Bea-flavored)
	arc.width = 2.0
	arc.add_point(from)
	var mid: Vector2 = (from + to) * 0.5 + Vector2(randf_range(-12.0, 12.0), randf_range(-12.0, 12.0))
	arc.add_point(mid)
	arc.add_point(to)
	arc.z_index = 12
	parent.add_child(arc)
	var tween: Tween = arc.create_tween()
	tween.tween_property(arc, "modulate:a", 0.0, 0.18)
	tween.tween_callback(arc.queue_free)


# Run 19 — Bea Elemental Synergy helpers (mirror of Shino's, additive-only).
func _bea_trigger_steam_burst(target: Node) -> void:
	if not is_instance_valid(target):
		return
	if target.has_method("take_damage"):
		target.take_damage(RunState.STEAM_BURST_FLAT_DMG, Vector2.ZERO)
	var origin: Vector2 = target.global_position
	for body in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(body):
			continue
		var dist: float = (body.global_position - origin).length()
		if dist > RunState.STEAM_BURST_PUFF_RADIUS:
			continue
		var ts2: Variant = body.get("status") if body.has_method("get") else null
		if ts2 != null and ts2.has_method("apply"):
			ts2.apply("slippery", RunState.STEAM_BURST_BLIND_DUR, 1)
	_bea_spawn_steam_puff(origin)
	if get_node_or_null("/root/FX") != null:
		FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_SHORT)
		FX.play_sound("steam_burst", 0.9)


func _bea_spawn_steam_puff(pos: Vector2) -> void:
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


func _bea_trigger_thaw_burst(target: Node) -> void:
	if not is_instance_valid(target):
		return
	if target.has_method("take_damage"):
		target.take_damage(RunState.THAW_BURST_FLAT_DMG, Vector2.ZERO)
	if get_node_or_null("/root/FX") != null:
		FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_SHORT)
		FX.spawn_burst_particles(target.global_position, Color(0.95, 0.80, 0.55, 1.0), 10)
		FX.play_sound("thaw_burst", 0.9)


func _bea_try_tidal_refresh_chi(target: Node) -> void:
	var now: float = Time.get_ticks_msec() / 1000.0
	var key: int = target.get_instance_id()
	var last: float = float(_bea_tidal_refresh_per_target.get(key, -10.0))
	if now - last < 3.0:
		return
	_bea_tidal_refresh_per_target[key] = now
	_add_chi(2)


# ---- Run 12 — Cancel system helpers ----
# Centralized swing-state cleanup. Called by both swing-end and cross-cancel paths
# so we don't drift in what "swing finished" means as features get added.
func _clear_swing_state() -> void:
	_swing_glide_velocity = Vector2.ZERO
	_swing_is_finisher = false
	_enemy_pinned_this_swing = false
	_swing_timer = 0.0
	# Run 34 — dash/cross-cancel drops the pending slam (player chose the cancel).
	_pending_spin_slam = false
	_spin_slam_timer = 0.0
	if body_anim and "rotation" in body_anim:
		body_anim.rotation = 0.0
	_hide_weapons()


# Cross-button cancel: stop the current swing cleanly and immediately fire a
# fresh first-step on the new button. Resets both combo step counters so the
# new combo starts at step 0 (per user spec: "interrupt X, start fresh Y step").
# `button` ∈ {"y", "x", "a"}.
func _cancel_swing_into_new(button: String) -> void:
	_clear_swing_state()
	katana_step = 0
	naginata_step = 0
	_combo_window_timer = 0.0
	_naginata_combo_timer = 0.0
	state = State.PLAYER_CONTROLLED if player_controlled else State.AI_FOLLOW   # Run 61b: respect AI flag
	# Arm the new button's hold-detector so the press still pathways into a
	# charge if the player keeps holding — but ONLY if we just executed a tap.
	# (Charge=hold-only, so the press becomes a tap immediately AND begins
	# hold-tracking; if the player releases under CHARGE_DETECT, the just_released
	# handler clears the tracker. If the player holds past CHARGE_DETECT, the
	# next frame's _handle_player_input will see the held button and… NOT charge,
	# because we're now in BEA_ATTACKING again from the fresh tap. Charge has to
	# wait for the second swing's lockout to end. This matches Shino's behavior:
	# you can cross-cancel into a tap, but charges still need a fresh press from idle.)
	match button:
		"y":
			_y_hold_dur = 0.0
			_tap_katana()
		"x":
			_x_hold_dur = 0.0
			_tap_naginata()
		"a":
			_a_hold_dur = 0.0
			_throw_kunai(facing)
			_player_shot_timer = PLAYER_SHOT_COOLDOWN
			# A-throw doesn't enter BEA_ATTACKING — set a brief lockout to read.
			# Fixed 0.11s (was FLURRY_LOCKOUT*0.5 before Run 30b lengthened the
			# lockout for waves) so the cancel feels deliberate.
			state = State.BEA_FLURRYING
			_flurry_timer = 0.11
			_flurry_wave_idx = 99   # kunai cancel-tap — no shuriken waves pending


# ---- Charge: Y/X/A hold → CHARGING → CHARGED → release-attack ----
# `button` is "y" | "x" | "a" — determines which release fires on button-up
# and which input is monitored for cancel-on-release-before-wind-up.
func _start_bea_charge(button: String) -> void:
	_charging_button = button
	state = State.BEA_CHARGING
	_charge_windup_timer = CHARGE_WINDUP
	velocity = Vector2.ZERO
	FX.play_sound("bea_charge_start")
	# Run 115 — charge tell is now a body-hugging silhouette aura (like Shino),
	# teal for all 3 buttons; replaces old per-button modulate tint.
	if _hitfx:
		_hitfx.set_charge(1)
	# Run 49 — X charge: spawn the landing reticle. Auto-snap to the nearest
	# living enemy AHEAD of Bea (front half-plane) within range; otherwise start
	# at 50% of max range straight ahead.
	if button == "x":
		var snap: Node = null
		var best_d: float = METEOR_DIVE_LOCK_RANGE
		for e in get_tree().get_nodes_in_group("enemy"):
			if not is_instance_valid(e) or not e.has_method("take_damage"):
				continue
			if e.has_method("is_alive") and not e.is_alive():
				continue
			var to_e: Vector2 = e.global_position - global_position
			var d: float = to_e.length()
			if d < 4.0 or d > best_d:
				continue
			if to_e.dot(facing) <= 0.0:
				continue   # only targets ahead of her
			snap = e
			best_d = d
		if snap != null:
			_dive_reticle_pos = snap.global_position
		else:
			_dive_reticle_pos = global_position \
				+ facing.normalized() * (METEOR_DIVE_LOCK_RANGE * METEOR_DIVE_RETICLE_DEFAULT_PCT)
		_clamp_reticle_to_walls()   # Run 49b — initial spot can't start beyond a wall
		_spawn_dive_reticle()


func _tick_charge(delta: float) -> void:
	# Allow facing steer during wind-up (per GDD §8.2.0)
	var steer: Vector2 = Vector2(
		_move_axis().x,
		_move_axis().y
	)
	# Run 49 — X charge: movement input drags the landing reticle instead of
	# steering facing. Bea stays planted; she turns to face the circle.
	if _charging_button == "x" and _dive_reticle != null:
		if steer.length_squared() > 0.01:
			_dive_reticle_pos += steer.normalized() * METEOR_DIVE_RETICLE_SPEED * delta
			# Clamp to max leap range around Bea.
			var off: Vector2 = _dive_reticle_pos - global_position
			if off.length() > METEOR_DIVE_LOCK_RANGE:
				_dive_reticle_pos = global_position + off.normalized() * METEOR_DIVE_LOCK_RANGE
		_clamp_reticle_to_walls()   # Run 49b — circle stops at arena walls
		var to_ret: Vector2 = _dive_reticle_pos - global_position
		if to_ret.length() > 4.0:
			facing = to_ret.normalized()
		_update_dive_reticle()
	elif steer.length_squared() > 0.01:
		facing = steer.normalized()
	velocity = Vector2.ZERO
	move_and_slide()

	# Dash cancels charge (universal — applies to all 3 charge buttons)
	if _act_jp("dash") and dash_cd_timer <= 0.0:
		_cancel_bea_charge()
		_start_dash()
		return

	var input_name: String = _input_for_charge()

	if state == State.BEA_CHARGING:
		_charge_windup_timer -= delta
		# Run 115 — HeroHitFX silhouette handles the charge aura pulse;
		# no per-frame modulate needed.

		# Early release = cancel (no fire)
		if input_name != "" and _act_jr(input_name):
			_cancel_bea_charge()
			return
		# Run 151 — Fallback: if the button is simply not held (e.g. released
		# during an ult freeze when _tick_charge wasn't running), cancel now.
		# Mirrors Player.gd's `not _act_p()` pattern so charge can't get stuck.
		if input_name != "" and not _act_p(input_name):
			_cancel_bea_charge()
			return

		if _charge_windup_timer <= 0.0:
			state = State.BEA_CHARGED
			if _hitfx:
				_hitfx.set_charge(2)   # Run 115 — bright pulsing "ready" aura
			FX.play_sound("bea_charge_ready")

	elif state == State.BEA_CHARGED:
		# Run 151 — Fallback: button no longer held but release was missed
		# (e.g. released during ult freeze). Cancel instead of staying stuck.
		if input_name != "" and not _act_p(input_name) and not _act_jr(input_name):
			_cancel_bea_charge()
			return
		if input_name != "" and _act_jr(input_name):
			match _charging_button:
				"y": _start_katana_whirl()    # Katana Whirl / Vortex Spin
				"x":
					_start_meteor_dive()    # new crash-dive
					# Run 60 — Quake Charge (Potato): X-charge is Bea's "slam" — same
					# placement as Shino's X-charge dispatch.
					if RunState.bea_has("quake_charge"):
						_bea_apply_quake_charge()
				"a": _start_shuriken_flurry()
			# Run 60 — universal family charge-release dispatches (mirror Player.gd:1622-1633).
			_bea_apply_family_charge_releases()


func _input_for_charge() -> String:
	match _charging_button:
		"y": return "attack_y"
		"x": return "attack_x"
		"a": return "attack_a"
	return ""


func _cancel_bea_charge() -> void:
	state = State.PLAYER_CONTROLLED if player_controlled else State.AI_FOLLOW   # Run 61b: respect AI flag
	_charge_windup_timer = 0.0
	_charging_button = ""
	modulate = Color(1.0, 1.0, 1.0, 1.0)
	if _hitfx:
		_hitfx.set_charge(0)   # Run 115 — drop silhouette charge aura
	_free_dive_reticle()   # Run 49 — drop the landing circle


# Run 49 — landing reticle visuals ------------------------------------------
func _spawn_dive_reticle() -> void:
	_free_dive_reticle()
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	_dive_reticle = Line2D.new()
	_dive_reticle.width = 3.0
	_dive_reticle.default_color = Color(1.0, 0.62, 0.18, 0.85)
	_dive_reticle.closed = true
	var radius: float = METEOR_DIVE_AOE_RADIUS * RunState.get_big_broccoli_aoe_mult()
	var n: int = 24
	for i in range(n):
		var ang: float = TAU * float(i) / float(n)
		_dive_reticle.add_point(Vector2(cos(ang), sin(ang)) * radius)
	_dive_reticle.z_index = 4
	scene.add_child(_dive_reticle)
	_update_dive_reticle()


func _update_dive_reticle() -> void:
	if _dive_reticle == null or not is_instance_valid(_dive_reticle):
		return
	_dive_reticle.global_position = _dive_reticle_pos
	# Gentle pulse so it reads as "live" while aiming.
	var t: float = float(Time.get_ticks_msec()) / 1000.0
	var pulse: float = 0.65 + 0.35 * (sin(t * 6.0) * 0.5 + 0.5)
	_dive_reticle.default_color = Color(1.0, 0.62, 0.18, 0.55 + 0.35 * pulse)
	_dive_reticle.scale = Vector2.ONE * (0.95 + 0.10 * pulse)


func _free_dive_reticle() -> void:
	if _dive_reticle != null and is_instance_valid(_dive_reticle):
		_dive_reticle.queue_free()
	_dive_reticle = null


# Run 110 — the Meteor leap is AIRBORNE and clears EVERY interior obstacle
# (crystals, rocks, logs, rivers, rubble — whatever their collision group). The
# ONLY thing it can't pass is the true ARENA BOUNDARY: the outer wall ring,
# gates, and exit door-pockets, which DreamRoom/World tag "leap_blocker". So the
# reticle is clamped to the nearest leap_blocker along the flight line and is
# free to sail over anything else inside the arena.
func _clamp_reticle_to_walls() -> void:
	_dive_reticle_pos = _clamp_point_to_boundary(_dive_reticle_pos)


# Raycast Bea → target on layer 1, stepping past every NON-boundary collider, and
# return the target pulled just inside the first "leap_blocker" (or unchanged if
# the flight line never leaves the arena). Used for both the player reticle and
# the AI fallback hop so neither can land out of bounds.
func _clamp_point_to_boundary(target: Vector2) -> Vector2:
	var to_t: Vector2 = target - global_position
	if to_t.length() < 4.0:
		return target
	var space := get_world_2d().direct_space_state
	if space == null:
		return target
	var exclude: Array[RID] = []
	for _i in range(16):   # safety cap on stacked interior obstacles
		var q := PhysicsRayQueryParameters2D.create(global_position, target, 1)
		q.exclude = exclude
		var hit: Dictionary = space.intersect_ray(q)
		if hit.is_empty():
			return target            # clear flight to target — nothing bounds it
		var collider = hit.get("collider")
		if collider != null and collider is Node \
		and collider.is_in_group("leap_blocker"):
			# Hit the arena boundary: stop just inside it.
			return hit.position - to_t.normalized() * 14.0
		# Any interior obstacle — leap over it, keep scanning toward the target.
		exclude.append(hit.get("rid"))
	return target


# ============================================================
# Meteor Dive (X charge) — Bea leaps up, locks onto nearest enemy,
# dives down onto them with a meteor-crash AoE. No target = short hop forward.
# BEA_DIVING state is reused for this attack.
# ============================================================
func _start_meteor_dive() -> void:
	state = State.BEA_DIVING
	_dive_phase = 0
	_dive_ascent_timer = METEOR_DIVE_ASCENT_DUR

	# Run 49 — the landing reticle IS the target now: the player aimed the
	# circle while holding the charge, so dive exactly there.
	if _dive_reticle != null and is_instance_valid(_dive_reticle):
		_dive_target_pos = _dive_reticle_pos
		_dive_has_target = true
		var to_t: Vector2 = _dive_target_pos - global_position
		if to_t.length() > 4.0:
			facing = to_t.normalized()
		_free_dive_reticle()
	else:
		# Fallback (no reticle, e.g. future AI use): old nearest-enemy lock-on.
		var nearest: Node = null
		var best_dist: float = METEOR_DIVE_LOCK_RANGE
		for e in get_tree().get_nodes_in_group("enemy"):
			if not is_instance_valid(e) or not e.has_method("take_damage"):
				continue
			if e.has_method("is_alive") and not e.is_alive():
				continue
			var d: float = global_position.distance_to(e.global_position)
			if d < best_dist:
				best_dist = d
				nearest = e
		if nearest != null:
			_dive_target_pos = nearest.global_position
			_dive_has_target = true
			facing = (_dive_target_pos - global_position).normalized()
		else:
			_dive_target_pos = _clamp_point_to_boundary(
				global_position + facing.normalized() * METEOR_DIVE_NO_TARGET_DIST)
			_dive_has_target = false

	is_invulnerable = true
	iframe_timer = METEOR_DIVE_ASCENT_DUR + 0.50
	velocity = Vector2.ZERO
	_charging_button = ""
	modulate = Color(1.0, 1.0, 1.0, 1.0)
	if _hitfx:
		_hitfx.set_charge(0)
	# Run 110 — she's AIRBORNE for the whole leap: phase inner barriers (same as
	# a dash) so the ascent + slam fly OVER rocks/logs/rivers/rubble instead of
	# snagging on them. Restored on landing in _finish_meteor_dive. Outer walls
	# aren't in this group, so she still can't leap out of bounds.
	_set_barrier_phasing(true)

	# Visual: scale up to fake the "jump" ascending (relative to base scale).
	if _bea_sprite:
		var tw: Tween = create_tween()
		tw.tween_property(_bea_sprite, "scale", Vector2.ONE * BEA_SPRITE_SCALE * 1.35, METEOR_DIVE_ASCENT_DUR * 0.85)
	# Warning ring at landing target
	_spawn_dive_warning_ring()
	FX.spawn_burst_particles(global_position, Color(1.0, 0.65, 0.20, 1.0), 16)
	FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_TINY)
	FX.play_sound("bea_meteor_dive_start")   # X-charge Meteor Dive — dedicated meteor sound


func _spawn_dive_warning_ring() -> void:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	var ring := Line2D.new()
	ring.width = 3.0
	ring.default_color = Color(1.0, 0.60, 0.15, 0.80)
	ring.closed = true
	var n: int = 20
	for i in range(n):
		var ang: float = TAU * float(i) / float(n)
		ring.add_point(Vector2(cos(ang), sin(ang)) * (METEOR_DIVE_AOE_RADIUS * 0.75))
	ring.global_position = _dive_target_pos
	ring.z_index = 3
	scene.add_child(ring)
	# Pulse: expand slightly then contract while Bea is ascending
	var tw: Tween = create_tween()
	tw.set_loops(2)
	tw.tween_property(ring, "scale", Vector2(1.2, 1.2), METEOR_DIVE_ASCENT_DUR * 0.4)
	tw.tween_property(ring, "scale", Vector2(0.9, 0.9), METEOR_DIVE_ASCENT_DUR * 0.4)
	# Free after dive completes
	var free_tw: Tween = create_tween()
	free_tw.tween_interval(METEOR_DIVE_ASCENT_DUR + 0.55)
	free_tw.tween_callback(Callable(ring, "queue_free"))


func _tick_dive(delta: float) -> void:
	if _dive_phase == 0:
		# Ascent: hold in place, let the scale tween show the "jump"
		velocity = Vector2.ZERO
		move_and_slide()
		_dive_ascent_timer -= delta
		if _dive_ascent_timer <= 0.0:
			_dive_phase = 1
			_dive_fall_timer = METEOR_DIVE_FALL_SAFETY   # Run 49b — stall safety
			# Peak of leap: brief scale peak then shrink back to base as we fall.
			if _bea_sprite:
				_bea_sprite.scale = Vector2.ONE * BEA_SPRITE_SCALE * 1.4
				var tw2: Tween = create_tween()
				tw2.tween_property(_bea_sprite, "scale", Vector2.ONE * BEA_SPRITE_SCALE, 0.10)
	else:
		# Fall: METEOR SLAM toward the target (Run 49b — 1650 px/s, very snappy).
		# Run 110 — she's AIRBORNE: move by POSITION (not move_and_slide) so the
		# slam sails OVER every interior obstacle and never snags. The target is
		# already clamped inside the arena boundary, so she can't overshoot walls.
		var to_target: Vector2 = _dive_target_pos - global_position
		var dist: float = to_target.length()
		var step: float = METEOR_DIVE_FALL_SPEED * delta
		if dist <= step + 5.0:
			global_position = _dive_target_pos
			_finish_meteor_dive()
			return
		global_position += to_target.normalized() * step
		# Run 49b — speed streak so the slam reads as a blur, not a glide.
		FX.spawn_hit_particles(global_position, Color(1.0, 0.70, 0.25, 0.55), 2)
		# Safety: if the fall somehow stalls, force the landing where she is.
		_dive_fall_timer -= delta
		if _dive_fall_timer <= 0.0:
			_dive_target_pos = global_position
			_finish_meteor_dive()


func _finish_meteor_dive() -> void:
	global_position = _dive_target_pos
	velocity = Vector2.ZERO
	is_invulnerable = false
	iframe_timer = 0.0
	_dive_phase = 0
	# Run 110 — back on the ground: restore inner-barrier collision. The reticle
	# clamp keeps the landing spot inside the arena walls; if she came down on an
	# interior barrier, move_and_slide depenetrates her next frame (dash model).
	_set_barrier_phasing(false)
	modulate = Color(1.0, 1.0, 1.0, 1.0)
	if _hitfx:
		_hitfx.set_charge(0)
	if _bea_sprite:
		_bea_sprite.scale = Vector2.ONE * BEA_SPRITE_SCALE   # back to base — NOT 1.0

	# Crash AoE — Big Broccoli scales the radius.
	var dive_radius: float = METEOR_DIVE_AOE_RADIUS * RunState.get_big_broccoli_aoe_mult()
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or not e.has_method("take_damage"):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		var d: float = global_position.distance_to(e.global_position)
		if d > dive_radius:
			continue
		var dir: Vector2 = (e.global_position - global_position).normalized()
		if dir.length() < 0.01:
			dir = facing
		var dmg: int = _bea_scale_damage(METEOR_DIVE_DAMAGE, false, false, null, "charge")
		_try_apply_shell_breaker(e)
		_bea_apply_family_statuses_on_hit(e, false, true, false, true, false)
		e.set_meta("last_damager", "bea")   # Run 134 — killer attribution (fix 5)
		e.take_damage(dmg, dir)
		_add_chi(int(CHI_PER_DAMAGE_DEALT * float(METEOR_DIVE_DAMAGE)))
		_try_bea_fall_harvest_heal(e)
		_try_evergreen_step_heal()
		FX.spawn_hit_particles(e.global_position, Color(1.0, 0.70, 0.25, 1.0), 10)

	# Impact visual: explosive crater (Run 49b — double ring + bigger burst so
	# the slam lands with a BOOM; shake kept modest — settings toggle later).
	FX.spawn_swing_arc(global_position, Vector2.RIGHT, dive_radius,
		360.0, Color(1.0, 0.60, 0.18, 0.70), 0.32)
	FX.spawn_swing_arc(global_position, Vector2.RIGHT, dive_radius * 1.35,
		360.0, Color(1.0, 0.92, 0.70, 0.45), 0.22)   # outer white-hot shockwave
	FX.spawn_burst_particles(global_position, Color(1.0, 0.72, 0.22, 1.0), 34)
	FX.spawn_burst_particles(global_position, Color(1.0, 0.95, 0.65, 1.0), 12)
	FX.screen_shake(FX.SHAKE_HEAVY, FX.SHAKE_DUR_MED)
	FX.play_sound("bea_meteor_dive_end")   # X-charge Meteor Dive impact — dedicated meteor sound

	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_anim_state("idle")
	state = State.PLAYER_CONTROLLED if player_controlled else State.AI_FOLLOW   # Run 61b


# ============================================================
# Naginata (X-tap) — 4-hit combo: Thrust → Thrust → Sweep → Overhead
# ============================================================

# Run 27 — family-color attack glow: blend the owned slot boon's family color
# into Bea's attack/impact FX. Returns base unchanged when no slot boon owned.
# _fx_col moved to HeroBase (Batch 2).


func _tap_naginata() -> void:
	_maybe_fire_vine_lash()   # Run 150b — Vine Lash dash-then-attack trigger
	# Run 115 — 3-hit naginata: Thrust → Sweep → Spin+Slam
	# Run 131 — One Big Grape (corrupt_grape): pin every naginata tap to the
	# Spin+Slam finisher step so every X hit is the AoE finisher.
	if RunState.bea_has("corrupt_grape"):
		naginata_step = NAGINATA_COMBO_STEPS - 1
	var hit_count: int = 0
	var is_overhead: bool = (naginata_step == 2)
	var step_lockout: float = NAGINATA_SWING_LOCKOUT
	if is_overhead:
		step_lockout = step_lockout * NAGINATA_SPIN_LOCKOUT_MULT + NAGINATA_SLAM_FOLLOW
	elif naginata_step == 0:
		step_lockout *= NAGINATA_THRUST_LOCKOUT_MULT
	match naginata_step:
		0:
			# Single piercing thrust (was two thrusts; now one heavier poke).
			_poke_lock_facing()
			hit_count = _hit_naginata_line(NAGINATA_THRUST_RANGE, NAGINATA_THRUST_WIDTH, NAGINATA_THRUST_DAMAGE)
			if RunState.is_duo_active("broccoli_grape"):
				for _bf_i in range(2):
					get_tree().create_timer(0.08 * float(_bf_i + 1)).timeout.connect(func():
						_hit_naginata_line(NAGINATA_THRUST_RANGE, NAGINATA_THRUST_WIDTH, NAGINATA_THRUST_DAMAGE)
					)
			FX.spawn_ranged_flash(global_position, facing,
				NAGINATA_THRUST_RANGE * 0.95,
				_fx_col(Color(0.72, 0.90, 1.0, 0.80), "X"), 0.14)
			FX.play_sound("bea_naginata_thrust_1")
		1:
			# 180° sweep — full forward half-circle at naginata reach.
			hit_count = _hit_naginata_arc(NAGINATA_SWEEP_RANGE, NAGINATA_SWEEP_ARC_DEG, NAGINATA_SWEEP_DAMAGE)
			if RunState.is_duo_active("broccoli_grape"):
				for _bf_i in range(2):
					get_tree().create_timer(0.08 * float(_bf_i + 1)).timeout.connect(func():
						_hit_naginata_arc(NAGINATA_SWEEP_RANGE, NAGINATA_SWEEP_ARC_DEG, NAGINATA_SWEEP_DAMAGE)
					)
			FX.spawn_swing_arc(global_position, facing,
				NAGINATA_SWEEP_RANGE, 180.0,
				_fx_col(Color(0.55, 0.82, 1.0, 0.65), "X"), 0.22)
			FX.spawn_swing_arc(global_position, facing,
				NAGINATA_SWEEP_RANGE * 0.55, 180.0,
				_fx_col(Color(0.70, 0.88, 1.0, 0.28), "X"), 0.18)
			FX.play_sound("bea_naginata_sweep")
		2:
			# Spin + Slam finisher (same as old step 3).
			hit_count = _fire_spin_finisher()
			_spin_slam_pos = global_position + facing * NAGINATA_SLAM_DIST
			_pending_spin_slam = true
			_spin_slam_timer = step_lockout - NAGINATA_SLAM_FOLLOW
			if RunState.is_duo_active("broccoli_grape"):
				for _bf_i in range(2):
					get_tree().create_timer(0.08 * float(_bf_i + 1)).timeout.connect(func():
						_hit_naginata_arc(NAGINATA_SWEEP_RANGE, 360.0, NAGINATA_SPIN_DAMAGE, true)
					)

	if hit_count > 0:
		# Non-overhead per-step feedback (overhead's shake happens at slam impact)
		FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_TINY)
		# Run 132 — Broccoli Brute Force (X/heavy): one shockwave per naginata swing
		# (fired once here, not per pierced enemy, to avoid multi-proc). Owner-gated.
		if RunState.bea_has("brute_force"):
			_bea_spawn_brute_force_shockwave(global_position + facing * 24.0)

	# Weapon visual — naginata extends/sweeps/spins per step.
	_animate_naginata(naginata_step, step_lockout)

	# Run 33 — spin finisher: body whirls a full revolution with the blade
	# (mirrors the katana finisher's body spin).
	_swing_is_finisher = is_overhead
	if is_overhead and body_anim and "rotation" in body_anim:
		body_anim.rotation = 0.0
		var btw: Tween = create_tween()
		# Run 34 — body completes its revolution during the spin portion; the
		# slam follow-through happens with the body already squared up.
		btw.tween_property(body_anim, "rotation", TAU, step_lockout - NAGINATA_SLAM_FOLLOW)
		btw.tween_callback(Callable(self, "_reset_body_rotation"))

	naginata_step = (naginata_step + 1) % NAGINATA_COMBO_STEPS
	_naginata_combo_timer = NAGINATA_COMBO_WINDOW
	state = State.BEA_ATTACKING
	_swing_timer = step_lockout
	_active_swing = "x"   # Run 12 — cancel system tracks which weapon's swing is active
	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_anim_state("swing_x")


# Run 33 — Poke aim-assist: snap facing to the nearest living enemy within
# thrust reach (+15% leeway) and a generous front cone. Keeps pokes honest —
# never flips Bea backwards, just corrects aim toward what's in front of her.
func _poke_lock_facing() -> void:
	var best: Node = null
	var best_d: float = NAGINATA_THRUST_RANGE * 1.15
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or not e.has_method("take_damage"):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		var to_e: Vector2 = e.global_position - global_position
		var d: float = to_e.length()
		if d < 4.0 or d > best_d:
			continue
		if abs(facing.angle_to(to_e / d)) > deg_to_rad(NAGINATA_POKE_LOCK_HALF_DEG):
			continue
		best = e
		best_d = d
	if best != null:
		facing = (best.global_position - global_position).normalized()


# Piercing line: enemy is "inside the line" if (1) its forward-projection along
# `facing` is in [0, range] AND (2) its perpendicular offset is within ±width/2.
# Pierces: all enemies along the line take damage (no first-hit stop).
# `big_knockback` boosts knockback for the overhead finisher.
func _hit_naginata_line(line_range: float, line_width: float, base_dmg: int, big_knockback: bool = false, is_finisher: bool = false) -> int:
	var hit: int = 0
	var perp: Vector2 = Vector2(-facing.y, facing.x)  # 90° perpendicular
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or not e.has_method("take_damage"):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		var to_e: Vector2 = e.global_position - global_position
		var fwd: float = to_e.dot(facing)
		var side: float = abs(to_e.dot(perp))
		if fwd < 0.0 or fwd > line_range or side > line_width * 0.5:
			continue
		var scaled: int = _bea_scale_damage(base_dmg, is_finisher)
		# Run 23 — Vital Harvest crit-heal (naginata thrust).
		_try_vital_harvest_crit_heal()
		# Shell Breaker (Run 15) — X (naginata) attacks roll for Vulnerable.
		_try_apply_shell_breaker(e)
		# Run 17 — X naginata is HEAVY → family statuses at 2 stacks (Cracked Soil chains too).
		_bea_apply_family_statuses_on_hit(e, false, true, false, false, false)
		var kb_dir: Vector2 = facing
		var _kb_mag: float = 2.0 if big_knockback else 1.0
		# Run 134 — killer attribution for the universal on-death hook (fix 5).
		e.set_meta("last_damager", "bea")
		e.take_damage(scaled, kb_dir)
		_add_chi(int(CHI_PER_DAMAGE_DEALT * float(base_dmg)))
		# Naginata thrust = blue-white spark feel; overhead = brighter flash
		var col: Color = Color(0.85, 0.95, 1.0, 1.0) if not big_knockback else Color(1.0, 0.95, 0.6, 1.0)
		FX.spawn_hit_particles(e.global_position, col, 7 if not big_knockback else 12)
		hit += 1
	return hit


# Run 12 — circular AoE around `center`. Back in service as of Run 34: used by
# _fire_spin_slam (the spin finisher's forward slam).
# Pierces — every alive enemy inside the radius takes the hit (no first-hit stop).
# Knockback direction = away from slam center (radial push), unlike thrust which pushes
# along facing. This sells the impact-pulse feel: enemies get blasted outward from the slam.
func _hit_naginata_circle(center: Vector2, radius: float, base_dmg: int, is_finisher: bool = false) -> int:
	var hit: int = 0
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or not e.has_method("take_damage"):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		var to_e: Vector2 = e.global_position - center
		if to_e.length() > radius:
			continue
		var scaled: int = _bea_scale_damage(base_dmg, is_finisher)
		# Run 23 — Vital Harvest crit-heal (naginata overhead slam).
		_try_vital_harvest_crit_heal()
		# Shell Breaker — X-charge naginata overhead slam counts as X attack.
		_try_apply_shell_breaker(e)
		# Run 17 — naginata overhead is HEAVY X.
		_bea_apply_family_statuses_on_hit(e, false, true, false, false, false)
		var kb_dir: Vector2 = to_e.normalized() if to_e.length() > 0.01 else facing
		# Run 134 — killer attribution for the universal on-death hook (fix 5).
		e.set_meta("last_damager", "bea")
		e.take_damage(scaled, kb_dir)
		_add_chi(int(CHI_PER_DAMAGE_DEALT * float(base_dmg)))
		FX.spawn_hit_particles(e.global_position, Color(1.0, 0.85, 0.55, 1.0), 12)
		hit += 1
	return hit


# Run 33/115 — Spin finisher (3rd naginata hit): one fast 360° cut around Bea at
# sweep reach — uniform with the rest of the combo. Fires immediately on tap; returns hit count.
func _fire_spin_finisher() -> int:
	# Run 134 — pass is_finisher=true so the Spin+Slam finisher's damage funnel
	# consumes Golden Carrot (dash-armed crit) + Master Stroke / Cluster Cascade,
	# matching the katana (Y) finisher path (fix 1).
	var hits: int = _hit_naginata_arc(NAGINATA_SWEEP_RANGE, 360.0, NAGINATA_SPIN_DAMAGE, true)
	# Spin visual — full ring at blade reach + fainter inner trail for depth.
	FX.spawn_swing_arc(global_position, Vector2.RIGHT,
		NAGINATA_SWEEP_RANGE, 360.0,
		_fx_col(Color(0.60, 0.82, 1.0, 0.70), "X"), 0.18)
	FX.spawn_swing_arc(global_position, Vector2.RIGHT,
		NAGINATA_SWEEP_RANGE * 0.55, 360.0,
		_fx_col(Color(0.70, 0.88, 1.0, 0.30), "X"), 0.14)
	FX.play_sound("bea_naginata_spin")
	if hits > 0:
		# Shared finisher impact (violet — X identity) at Bea's center.
		_spawn_bea_finisher_impact(global_position, false)
		FX.spawn_hit_particles(global_position, Color(1.0, 0.95, 0.70, 1.0), 8)
	# --- Finisher boon hooks (carried over from the old overhead slam) ---
	# Broccoli Legendary — Hulk Smash shockwave on X finisher (Run 22 wiring).
	_bea_try_hulk_smash(global_position)
	# Run 133 — Battle Shell (Coconut): X finisher also grants 1 overshield
	# (mirror of Player.gd:2823, Shino's side-kick finisher).
	if RunState.bea_has("battle_shell"):
		grant_overshield_external(1)
		_battle_shell_timer = RunState.BATTLE_SHELL_DURATION
	# Run 132 — Grape Overhead Crush (X finisher): Vinewrap (root) around the spin.
	if RunState.bea_has("overhead_crush"):
		_bea_apply_vinewrap(global_position, 56.0)
	# Run 132 — Grape+Potato "Stomp Combo" duo: X finisher → earthspike line.
	if RunState.stomp_combo_active():
		_bea_spawn_stomp_earth_line(global_position, RunState.get_stomp_combo_line_length(combo_count), true)
	# Run 129 — Master Stroke force-crit moved into _bea_scale_damage
	# (pre-roll); the old post-hit set here primed the WRONG hit.
	# Run 28 — Broccoli+Potato "Earthshaker": X finisher launches enemies + 3 Cracked Soil.
	if RunState.earthshaker_active():
		for e in get_tree().get_nodes_in_group("enemy"):
			if not is_instance_valid(e) or (e.has_method("is_alive") and not e.is_alive()):
				continue
			if global_position.distance_to(e.global_position) > NAGINATA_SWEEP_RANGE:
				continue
			var ts_e: Variant = e.get("status") if e.has_method("get") else null
			if ts_e != null and ts_e.has_method("apply"):
				ts_e.apply("stagger", 0.5, 1)
				ts_e.apply("cracked_soil", 5.0, 3)
		FX.screen_shake(FX.SHAKE_MEDIUM, FX.SHAKE_DUR_SHORT)
	return hits


# Run 34 — Spin-finisher part 2: forward slam landing as the spin ends.
# Circular AoE at the slam point in front of Bea (radial knockback via
# _hit_naginata_circle) + ground-impact ring. Called from _tick_swing.
func _fire_spin_slam() -> void:
	var hits: int = _hit_naginata_circle(_spin_slam_pos, NAGINATA_SLAM_RADIUS, NAGINATA_SLAM_DAMAGE, true)
	_spawn_slam_impact_ring(_spin_slam_pos, NAGINATA_SLAM_RADIUS)
	FX.play_sound("bea_naginata_overhead_slam")
	if hits > 0:
		_spawn_bea_finisher_impact(_spin_slam_pos, false)
		FX.spawn_hit_particles(_spin_slam_pos, Color(1.0, 0.95, 0.70, 1.0), 8)
		FX.screen_shake(FX.SHAKE_MEDIUM, FX.SHAKE_DUR_SHORT)


# Run 34 — slam impact ring (restored from Run 12): expanding/fading ground
# ring at the slam point. Lives under current_scene so it isn't yanked if Bea moves.
func _spawn_slam_impact_ring(center: Vector2, radius: float) -> void:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	var ring := Line2D.new()
	ring.width = 4.0
	ring.default_color = Color(1.0, 0.85, 0.45, 1.0)
	ring.closed = true
	var n: int = 24
	for i in range(n):
		var ang: float = TAU * float(i) / float(n)
		ring.add_point(Vector2(cos(ang), sin(ang)) * radius)
	ring.global_position = center
	ring.z_index = 4
	scene.add_child(ring)
	ring.scale = Vector2(0.35, 0.35)
	var tw: Tween = create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", Vector2(1.10, 1.10), 0.35)
	tw.tween_property(ring, "modulate:a", 0.0, 0.35)
	tw.chain().tween_callback(Callable(ring, "queue_free"))


func _hit_naginata_arc(arc_range: float, arc_deg: float, base_dmg: int, is_finisher: bool = false) -> int:
	var hit: int = 0
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or not e.has_method("take_damage"):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		var to_e: Vector2 = e.global_position - global_position
		if to_e.length() > arc_range:
			continue
		if to_e.length() > 0.01:
			var angle_diff: float = abs(facing.angle_to(to_e.normalized()))
			if angle_diff > deg_to_rad(arc_deg * 0.5):
				continue
		var scaled: int = _bea_scale_damage(base_dmg, is_finisher)
		# Shell Breaker — naginata sweep counts as X attack.
		_try_apply_shell_breaker(e)
		# Run 17 — naginata sweep is HEAVY X.
		_bea_apply_family_statuses_on_hit(e, false, true, false, false, false)
		# Run 134 — killer attribution for the universal on-death hook (fix 5).
		e.set_meta("last_damager", "bea")
		e.take_damage(scaled, to_e.normalized() if to_e.length() > 0.01 else facing)
		_add_chi(int(CHI_PER_DAMAGE_DEALT * float(base_dmg)))
		FX.spawn_hit_particles(e.global_position, Color(0.85, 0.95, 1.0, 1.0), 7)
		# Run 28 — Firebrand + Splash Smash on heavy (X) hits.
		var ts_n: Variant = e.get("status") if e.has_method("get") else null
		if ts_n != null and ts_n.has_method("apply"):
			if RunState.firebrand_active():
				ts_n.apply("burning", 3.0, 2)
			if RunState.splash_smash_active():
				var sm_id: String = "chilled" if RunState.melon_gelato_mode else "wet"
				ts_n.apply(sm_id, 4.0, 3)
		hit += 1
	return hit


# ============================================================
# Katana Whirl / Vortex Spin (Y-hold release) — Run 116 rework.
# Bea spins in place, pulling nearby enemies to her center (stunned).
# At the end, caught enemies are tossed in front of her for Y follow-up.
# Invulnerable during spin + brief post-spin window.
# ============================================================
func _start_katana_whirl() -> void:
	state = State.BEA_WHIRLING
	_leap_timer = VORTEX_SPIN_DURATION
	_lunge_dir = facing.normalized() if facing.length() > 0.01 else Vector2.RIGHT
	_lunge_spin1_fired = false
	_lunge_spin2_fired = false
	_vortex_caught = []
	_vortex_tick_timer = 0.0
	# i-frames for the full spin + brief post-spin repositioning window.
	is_invulnerable = true
	iframe_timer = VORTEX_SPIN_DURATION + VORTEX_POST_INVULN
	modulate = Color(1.0, 1.0, 1.0, 1.0)
	if _hitfx:
		_hitfx.set_charge(0)
	# Launch flash + sound — teal (matches Y special slice colour).
	FX.spawn_burst_particles(global_position, Color(0.20, 0.90, 0.80, 1.0), 14)
	FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_TINY)
	FX.play_sound("bea_whirl_start")
	_charging_button = ""
	# Show katana for the spin.
	if katana_node:
		katana_node.visible = true
		katana_node.position = Vector2.ZERO
		katana_node.rotation = facing.angle()
	# HURRICANE SPIN: body + katana complete THREE full revolutions (Run 117).
	if body_anim and "rotation" in body_anim:
		body_anim.rotation = 0.0
		var tw_body: Tween = create_tween()
		tw_body.tween_property(body_anim, "rotation", TAU * 3.0, VORTEX_SPIN_DURATION)
		tw_body.tween_callback(Callable(self, "_reset_body_rotation"))
	if katana_node:
		if _katana_tween and _katana_tween.is_valid():
			_katana_tween.kill()
		_katana_tween = create_tween()
		_katana_tween.tween_property(katana_node, "rotation",
			katana_node.rotation + TAU * 3.0, VORTEX_SPIN_DURATION)
	_spawn_lunge_tornado()


func _tick_whirl(delta: float) -> void:
	_leap_timer -= delta
	# Move forward at constant speed (same lunge as before).
	velocity = _lunge_dir * (METEOR_LEAP_DIST / VORTEX_SPIN_DURATION)
	move_and_slide()

	# --- Run 117: trailing wind streaks behind hurricane path ---
	# Spawn teal wisps behind Bea (opposite travel dir) so the cyclone
	# reads as moving forward, not just spinning in place.
	_whirl_tick_timer += delta
	if _whirl_tick_timer >= 0.06:  # ~16/sec, moderate density
		_whirl_tick_timer -= 0.06
		var trail_pos: Vector2 = global_position - _lunge_dir * 28.0
		# Scatter slightly perpendicular for width.
		var perp: Vector2 = Vector2(-_lunge_dir.y, _lunge_dir.x)
		trail_pos += perp * randf_range(-22.0, 22.0)
		FX.spawn_hit_particles(trail_pos, Color(0.30, 0.88, 0.78, 0.45), 2)

	# --- Vortex: pull enemies inward + capture new ones ---
	var pull_r: float = VORTEX_PULL_RADIUS * RunState.get_big_broccoli_aoe_mult()
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or not e.has_method("take_damage"):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		var dist: float = global_position.distance_to(e.global_position)
		if dist > pull_r:
			continue
		# Run 117/134 — immovable targets (training dummy) DO take the vortex
		# damage ticks, but are never stunned, pulled, dragged, or tossed. Add
		# them to the caught list (so _fire_vortex_damage_tick damages them and
		# spawns damage numbers — fix 4) but skip the stun + pull/drag. The
		# release loop skips immovable so they are never flung.
		if e.is_in_group("immovable"):
			if not _vortex_caught.has(e):
				_vortex_caught.append(e)
			continue
		# Run 150 (Bruno fix 9): breakbar hosts (boss/miniboss) are UNSTOPPABLE —
		# damage-tick them like immovables (the stun attempt routes through
		# StatusComponent and chips the breakbar) but never pull/drag/toss.
		if e.has_node("StatusComponent"):
			var _vsc: Node = e.get_node("StatusComponent")
			if _vsc.breakbar_enabled and not _vsc.is_breakbar_broken():
				if not _vortex_caught.has(e):
					_vortex_caught.append(e)
					_vortex_stun_enemy(e)   # intercepted → breakbar chip only
				continue
		# Capture: stun the enemy so it can't act or damage Bea.
		if not _vortex_caught.has(e):
			_vortex_caught.append(e)
			_vortex_stun_enemy(e)
		# Pull toward Bea's current position (she's moving, so they travel with her).
		if dist > VORTEX_INNER_RADIUS:
			var to_center: Vector2 = (global_position - e.global_position).normalized()
			var pull_step: float = VORTEX_PULL_SPEED * delta
			pull_step = minf(pull_step, dist - VORTEX_INNER_RADIUS)
			e.global_position += to_center * pull_step
		else:
			# Already inside inner radius — drag them along with Bea's movement.
			e.global_position = e.global_position.lerp(global_position, 8.0 * delta)

	# --- Periodic damage ticks on caught enemies ---
	_vortex_tick_timer -= delta
	if _vortex_tick_timer <= 0.0:
		_vortex_tick_timer = VORTEX_TICK_INTERVAL
		_fire_vortex_damage_tick()

	# Prune dead/freed enemies from the caught list.
	var i: int = _vortex_caught.size() - 1
	while i >= 0:
		var e = _vortex_caught[i]
		if not is_instance_valid(e) or (e.has_method("is_alive") and not e.is_alive()):
			_vortex_caught.remove_at(i)
		i -= 1

	if _leap_timer <= 0.0:
		_finish_katana_whirl()


# --- Vortex helpers (Run 116) ---

func _fire_vortex_damage_tick() -> void:
	# Damage all caught enemies each tick.
	for e in _vortex_caught:
		if not is_instance_valid(e) or (e.has_method("is_alive") and not e.is_alive()):
			continue
		var dir: Vector2 = (e.global_position - global_position).normalized()
		if dir.length() < 0.01:
			dir = _lunge_dir
		var scaled: int = _bea_scale_damage(WHIRL_DAMAGE, false, false, null, "charge")
		_try_apply_shell_breaker(e)
		_bea_apply_family_statuses_on_hit(e, false, true, false, true, false)
		# Firebrand + Splash Smash on heavy charge hits.
		var ts_n: Variant = e.get("status") if e.has_method("get") else null
		if ts_n != null and ts_n.has_method("apply"):
			if RunState.firebrand_active():
				ts_n.apply("burning", 3.0, 2)
			if RunState.splash_smash_active():
				var sm_id: String = "chilled" if RunState.melon_gelato_mode else "wet"
				ts_n.apply(sm_id, 4.0, 3)
		# Zero-vector knockback so stun isn't broken by recoil movement.
		# Run 134 — killer attribution for the universal on-death hook (fix 5).
		e.set_meta("last_damager", "bea")
		e.take_damage(scaled, Vector2.ZERO)
		_add_chi(int(CHI_PER_DAMAGE_DEALT * float(WHIRL_DAMAGE)))
		_try_bea_fall_harvest_heal(e)
		FX.spawn_hit_particles(e.global_position, Color(0.20, 0.90, 0.80, 1.0), 6)
	# Tornado pulse feedback.
	if _lunge_tornado != null and is_instance_valid(_lunge_tornado):
		var tw_pulse: Tween = create_tween()
		tw_pulse.tween_property(_lunge_tornado, "modulate",
			Color(1.35, 1.35, 1.35, 1.0), 0.06)
		tw_pulse.tween_property(_lunge_tornado, "modulate",
			Color(1.0, 1.0, 1.0, 1.0), 0.10)
	FX.play_sound("bea_whirl_start", 0.85)


func _vortex_stun_enemy(e: Node) -> void:
	# Apply bash (movement lock) via StatusComponent — all enemies check
	# status.is_movement_locked() in _physics_process and freeze when true.
	# Generous duration; we clear it manually in _vortex_release_enemies.
	if e.has_node("StatusComponent"):
		e.get_node("StatusComponent").apply("bash", VORTEX_SPIN_DURATION + 0.5, 1)
	elif "velocity" in e:
		e.velocity = Vector2.ZERO


func _vortex_release_enemies() -> void:
	# Toss all caught enemies in front of Bea (her facing direction) and un-stun.
	var toss_dir: Vector2 = _lunge_dir
	var toss_center: Vector2 = global_position + toss_dir * VORTEX_TOSS_DIST
	var perp: Vector2 = Vector2(-toss_dir.y, toss_dir.x)  # perpendicular for spread
	var count: int = _vortex_caught.size()
	for idx in range(count):
		var e = _vortex_caught[idx]
		if not is_instance_valid(e):
			continue
		# Run 134 — immovable targets (training dummy) were damage-ticked but must
		# never be flung; skip the toss entirely for them (fix 4).
		if e.is_in_group("immovable"):
			continue
		# Run 150 (Bruno fix 9): never fling breakbar hosts (boss/miniboss).
		if e.has_node("StatusComponent"):
			var _tsc: Node = e.get_node("StatusComponent")
			if _tsc.breakbar_enabled and not _tsc.is_breakbar_broken():
				continue
		# Spread enemies evenly across a line perpendicular to facing.
		var spread_offset: float = 0.0
		if count > 1:
			spread_offset = lerp(-VORTEX_TOSS_SPREAD, VORTEX_TOSS_SPREAD,
				float(idx) / float(count - 1))
		var land_pos: Vector2 = toss_center + perp * spread_offset
		# Clamp to arena boundary so enemies never fly past walls/barriers.
		land_pos = _clamp_point_to_boundary(land_pos)
		# Smooth toss: tween from current pos to landing so the player sees
		# enemies flung forward, not teleported.
		if "velocity" in e:
			e.velocity = Vector2.ZERO
		var tw_toss: Tween = create_tween()
		tw_toss.set_ease(Tween.EASE_OUT)
		tw_toss.set_trans(Tween.TRANS_CUBIC)
		tw_toss.tween_property(e, "global_position", land_pos, VORTEX_TOSS_DURATION)
		# Keep bash active through the toss so enemy can't act mid-flight,
		# then leave a tiny window so Bea can start Y1 before they recover.
		if e.has_node("StatusComponent"):
			e.get_node("StatusComponent").remove("bash")
			e.get_node("StatusComponent").apply("bash", VORTEX_TOSS_DURATION + 0.12, 1)
		# Small knockback on landing so they "tumble out."
		if "_knockback_vel" in e:
			var _e_ref = e
			var _toss_d = toss_dir
			tw_toss.tween_callback(func():
				if is_instance_valid(_e_ref) and "_knockback_vel" in _e_ref:
					_e_ref._knockback_vel = _toss_d * 60.0
			)
		# Landing burst at destination (fires when tween finishes).
		var _lp = land_pos
		tw_toss.tween_callback(func():
			FX.spawn_burst_particles(_lp, Color(0.20, 0.90, 0.80, 0.9), 6)
		)
	_vortex_caught = []


# Run 117 — HURRICANE SPIN: Wind Waker-style cyclone that moves WITH Bea.
# 5 long spiral arms (~270° sweep each) wrap around her like a proper tornado,
# with a ground dust ring at the base and inner eye swirls for depth.
# 3 full revolutions (faster spin = reads as hurricane, not lazy pirouette).
# Arms widen mid-length then taper at tips (comet shape). Freed in _finish.
func _spawn_lunge_tornado() -> void:
	_free_lunge_tornado()
	_lunge_tornado = Node2D.new()
	_lunge_tornado.z_index = 6
	add_child(_lunge_tornado)
	var spin_sign: float = -1.0 if _lunge_dir.x >= 0.0 else 1.0

	# --- GROUND DUST RING: faint ellipse at feet suggesting kicked-up debris ---
	var dust_ring := Line2D.new()
	dust_ring.width = 3.0
	dust_ring.z_index = -1  # behind everything
	var dust_grad := Gradient.new()
	dust_grad.set_color(0, Color(0.85, 0.80, 0.65, 0.35))
	dust_grad.set_color(1, Color(0.85, 0.80, 0.65, 0.35))
	dust_ring.gradient = dust_grad
	var ring_pts: int = 32
	for i in range(ring_pts + 1):
		var ang: float = TAU * float(i) / float(ring_pts)
		dust_ring.add_point(Vector2(cos(ang) * LUNGE_SPIN_RADIUS_1 * 0.95,
			sin(ang) * LUNGE_SPIN_RADIUS_1 * 0.55))  # ellipse (foreshortened Y)
	_lunge_tornado.add_child(dust_ring)

	# --- OUTER SPIRAL ARMS: 5 long teal energy trails, each ~270° sweep ---
	# Width curve: thin at center → wide mid-arm → tapered tip (comet shape).
	var arm_count: int = 5
	for arm in range(arm_count):
		var line := Line2D.new()
		var grad := Gradient.new()
		# Trailing edge transparent → bright teal leading edge.
		grad.set_color(0, Color(0.20, 0.90, 0.80, 0.0))
		grad.set_color(1, Color(0.45, 1.0, 0.92, 0.90))
		line.gradient = grad
		var pts: int = 28
		var arm_off: float = TAU * float(arm) / float(arm_count)
		for i in range(pts):
			var t: float = float(i) / float(pts - 1)
			# 270° sweep per arm — ¾ wrap reads as a proper cyclone spiral.
			var ang: float = arm_off + spin_sign * t * deg_to_rad(270.0)
			# Radius spirals outward: starts at 15% of rim, ends at full rim.
			var r: float = LUNGE_SPIN_RADIUS_1 * lerp(0.15, 1.0, t)
			line.add_point(Vector2(cos(ang), sin(ang)) * r)
		# Width curve: thin→thick→thin (comet). WidthCurve on Line2D.
		var wcurve := Curve.new()
		wcurve.add_point(Vector2(0.0, 0.25))   # thin at spiral center
		wcurve.add_point(Vector2(0.35, 1.0))    # thickest mid-arm
		wcurve.add_point(Vector2(0.75, 0.85))   # still wide near tip
		wcurve.add_point(Vector2(1.0, 0.15))    # sharp taper at leading edge
		line.width = 9.0
		line.width_curve = wcurve
		_lunge_tornado.add_child(line)

	# --- INNER EYE SWIRLS: 3 tight spirals near center for cyclone depth ---
	for swirl in range(3):
		var sline := Line2D.new()
		var sgrad := Gradient.new()
		sgrad.set_color(0, Color(0.90, 0.98, 1.0, 0.08))   # nearly invisible at core
		sgrad.set_color(1, Color(0.70, 0.95, 0.90, 0.55))   # soft glow outward
		sline.gradient = sgrad
		sline.width = 3.0
		var spts: int = 14
		var swirl_off: float = TAU * float(swirl) / 3.0
		for i in range(spts):
			var t: float = float(i) / float(spts - 1)
			# Tight ~200° sweep, radius 5%→40% of rim (stays inside outer arms).
			var ang: float = swirl_off + spin_sign * t * deg_to_rad(200.0)
			var r: float = LUNGE_SPIN_RADIUS_1 * lerp(0.05, 0.40, t)
			sline.add_point(Vector2(cos(ang), sin(ang)) * r)
		_lunge_tornado.add_child(sline)

	# --- KATANA BLADE STREAKS: 3 steel-white curved blades (pinwheel) ---
	# Kept from original design (Bruno's red-line sketch) — the disc reads
	# as hit-area. Longer sweep now (160°) to match the hurricane density.
	for blade in range(3):
		var bline := Line2D.new()
		var bgrad := Gradient.new()
		bgrad.set_color(0, Color(0.85, 0.95, 1.0, 0.10))
		bgrad.set_color(1, Color(0.95, 0.99, 1.0, 0.85))
		bline.gradient = bgrad
		bline.width = 5.0
		var bpts: int = 20
		var blade_off: float = TAU * float(blade) / 3.0 + deg_to_rad(36.0)
		for i in range(bpts):
			var t: float = float(i) / float(bpts - 1)
			var ang: float = blade_off + spin_sign * t * deg_to_rad(160.0)
			var r: float = lerp(LUNGE_SPIN_RADIUS_1 * 0.10, LUNGE_SPIN_RADIUS_1 * 0.94, t)
			bline.add_point(Vector2(cos(ang), sin(ang)) * r)
		var bwcurve := Curve.new()
		bwcurve.add_point(Vector2(0.0, 0.3))
		bwcurve.add_point(Vector2(0.5, 1.0))
		bwcurve.add_point(Vector2(1.0, 0.5))
		bline.width_curve = bwcurve
		_lunge_tornado.add_child(bline)

	# 3 full revolutions (hurricane speed) + scale-up from inner to outer AoE.
	var tw: Tween = create_tween()
	tw.set_parallel(true)
	tw.tween_property(_lunge_tornado, "rotation", spin_sign * TAU * 3.0, METEOR_LEAP_DURATION)
	tw.tween_property(_lunge_tornado, "scale",
		Vector2.ONE * (LUNGE_SPIN_RADIUS_2 / LUNGE_SPIN_RADIUS_1), METEOR_LEAP_DURATION)


func _free_lunge_tornado() -> void:
	if _lunge_tornado != null and is_instance_valid(_lunge_tornado):
		_lunge_tornado.queue_free()
	_lunge_tornado = null


func _finish_katana_whirl() -> void:
	# --- Toss caught enemies in front of Bea ---
	_vortex_release_enemies()
	velocity = Vector2.ZERO
	# Post-spin invuln: iframe_timer was set in _start to cover spin + post window,
	# so just leave is_invulnerable true — it'll expire via iframe_timer naturally.
	# Reset body rotation and holster katana (mirrors katana finisher cleanup).
	_reset_body_rotation()
	_free_lunge_tornado()
	_hide_weapons()
	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_anim_state("idle")
	FX.spawn_burst_particles(global_position, Color(0.20, 0.90, 0.80, 1.0), 16)
	FX.screen_shake(FX.SHAKE_MEDIUM, FX.SHAKE_DUR_SHORT)
	FX.play_sound("bea_whirl_end")
	state = State.PLAYER_CONTROLLED if player_controlled else State.AI_FOLLOW


# ============================================================
# Shuriken Flurry (A-hold release) — Run 30b rework
# ============================================================
# Run 39 (Bruno): SHOTGUN CONE — 3 rapid waves of 4 shuriken (0.05s apart)
# along the aim locked at release. Same speed/power as the Run 30d single
# blast, but the wave cadence + jitter gives the cloud depth: a cone of
# stars rather than one flat arc. Aim stays locked — shotgun, not a spray.

func _start_shuriken_flurry() -> void:
	# Lock the aim at release — the whole blast shares one fan direction.
	_flurry_aim = facing
	_fire_shuriken_wave()
	_flurry_wave_idx = 1
	_flurry_wave_timer = SHURIKEN_WAVE_INTERVAL
	# Shotgun punch: heavy kick + big muzzle flash.
	FX.screen_shake(FX.SHAKE_HEAVY, FX.SHAKE_DUR_SHORT)
	FX.spawn_ranged_flash(global_position, _flurry_aim, 90.0,
		Color(1.0, 0.92, 0.45, 0.70), 0.14)
	FX.play_sound("bea_shuriken_flurry")
	state = State.BEA_FLURRYING
	_flurry_timer = FLURRY_LOCKOUT
	_charging_button = ""
	modulate = Color(1.0, 1.0, 1.0, 1.0)
	if _hitfx:
		_hitfx.set_charge(0)
	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_anim_state("swing_a")


func _fire_shuriken_wave() -> void:
	# Evenly-spaced fan across the arc, centered on the locked aim. Run 39 —
	# each shuriken also gets ±35%-of-a-step angular jitter so the three waves
	# don't stack into neat lanes: combined with the speed variance the blast
	# reads as a scattered CONE of stars (per Bruno's sketch), not a flat arc.
	var half: float = deg_to_rad(SHURIKEN_CONE_HALF_DEG)
	var base: float = _flurry_aim.angle()
	var step: float = 0.0
	if SHURIKEN_PER_WAVE > 1:
		step = 2.0 * half / float(SHURIKEN_PER_WAVE - 1)
	for i in range(SHURIKEN_PER_WAVE):
		var ang: float = base
		if SHURIKEN_PER_WAVE > 1:
			ang = base - half + step * float(i) + randf_range(-0.35, 0.35) * step
		_throw_shuriken(Vector2(cos(ang), sin(ang)))
	FX.spawn_burst_particles(global_position + _flurry_aim * 12.0, Color(1.0, 0.95, 0.55, 1.0), 12)


func _tick_flurry_lockout(delta: float) -> void:
	# Movement allowed during the commit window (aim stays locked).
	_do_movement(delta)
	# Run 30b/30c — fire pending shuriken waves on their stagger timer.
	if _flurry_wave_idx < SHURIKEN_WAVES:
		_flurry_wave_timer -= delta
		if _flurry_wave_timer <= 0.0:
			_fire_shuriken_wave()
			_flurry_wave_idx += 1
			_flurry_wave_timer = SHURIKEN_WAVE_INTERVAL
	_flurry_timer -= delta
	if _flurry_timer <= 0.0:
		state = State.PLAYER_CONTROLLED if player_controlled else State.AI_FOLLOW   # Run 61b


func _throw_shuriken(dir: Vector2) -> void:
	if projectile_scene == null:
		return
	# Run 134 — Drawn Bow: reset the idle timer on ANY attack (fix 2). Shuriken
	# spawns Kunai projectiles directly (bypassing _spawn_kunai), so reset here too.
	_no_attack_timer = 0.0
	var k: Node2D = projectile_scene.instantiate()
	get_parent().add_child(k)
	k.global_position = global_position + dir * 18.0
	# Run 27 — family-color glow on the projectile (A-slot boon family).
	var sh_tint: Color = RunState.get_attack_tint("bea", "A")
	if sh_tint.a > 0.0:
		k.modulate = Color(1, 1, 1, 1).lerp(sh_tint, 0.55)
	# Run 30b — shuriken visual (spinning 4-point star) replaces the old
	# gold-tinted kunai blade. Pierce limit applied per-shuriken here; boons
	# that change shuriken pierce should modify this assignment ONLY.
	if k.has_method("make_shuriken"):
		k.make_shuriken()
	k.set("pierce_limit", SHURIKEN_PIERCE_LIMIT)
	# Reuse Kunai's launch — Run 30d: 12 shuriken × 8 dmg in one blast. A
	# point-blank target can eat most of the fan (~50-95) — shotgun rules:
	# devastating up close, falls off hard with distance (short SHURIKEN_RANGE).
	if k.has_method("launch"):
		var shuriken_dmg: int = _bea_scale_damage(SHURIKEN_DAMAGE, false, false, null, "ranged")
		shuriken_dmg += RunState.seeded_shot_bonus_dmg(current_hp, "bea")
		# ±SHURIKEN_SPEED_VARIANCE per shuriken stretches the cloud in depth.
		var spd: float = SHURIKEN_SPEED * randf_range(
			1.0 - SHURIKEN_SPEED_VARIANCE, 1.0 + SHURIKEN_SPEED_VARIANCE)
		k.launch(dir, spd, shuriken_dmg)
		k.set("max_range", SHURIKEN_RANGE)   # short reach — close-range identity
		# Run 24 — Carrot+Watermelon "Refreshing Aim": ranged crits heal Bea 4% max HP.
		if RunState.last_crit_result:
			var cw_pct: float = RunState.get_carrot_watermelon_ranged_crit_heal_pct()
			if cw_pct > 0.0:
				var heal_amt: int = max(1, int(round(float(get_effective_max_hp()) * cw_pct)))
				current_hp = min(get_effective_max_hp(), current_hp + heal_amt)
				emit_signal("bea_hp_changed", current_hp, get_effective_max_hp())
				FX.spawn_hit_particles(global_position, Color(0.25, 0.90, 0.70, 1.0), 3)


# ============================================================
# Thousand Cut Dance (Ult — §8.2.3)
# ============================================================

func _start_ult() -> void:
	# Tide Master: pay reduced cost; refund 25% of base cost.
	var ult_pay: int = max(1, int(round(float(ULT_CHI_COST) * RunState.tide_master_ult_cost_mult("bea"))))
	current_chi = max(0, current_chi - ult_pay)
	var tm_refund: int = RunState.tide_master_refund(ULT_CHI_COST, "bea")
	if tm_refund > 0:
		current_chi = min(get_effective_max_chi(), current_chi + tm_refund)
	# Run 136 — Shell Wall retired: redundant with Bulwark Strike (Ult slot).
	emit_signal("bea_chi_changed", current_chi, MAX_CHI)
	# Run 132 — apply Bea's ult-boon cast payloads (parity with Player.gd). Bea's ult
	# previously skipped these entirely; now her own harvest_moon / bulwark_strike /
	# titans_roar / bullseye_finale / bunch_bloom_ult fire when SHE casts.
	_bea_apply_ult_boon_cast_effects()
	state = State.BEA_ULT_CASTING
	# Run 150 (Bruno fix 11) — freeze Shino (player or AI) for the cinematic.
	RunState.ult_freeze_caster = "bea"
	RunState.double_ult_queued = false
	_ult_timer = ULT_CINEMATIC_DURATION
	_ult_in_dizzy = false
	_ult_freeze_targets.clear()
	_ult_blink_positions.clear()
	_ult_blink_idx = 0
	_ult_blink_timer = 0.0
	is_invulnerable = true
	iframe_timer = ULT_CINEMATIC_DURATION + ULT_DIZZY_DURATION + 0.10
	velocity = Vector2.ZERO

	# Build the blink chain: every alive on-screen enemy.
	var targets: Array = []
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or not e.has_method("take_damage"):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		targets.append(e)
	# Sort by distance for a more pleasing ribbon path
	targets.sort_custom(func(a, b): return global_position.distance_to(a.global_position) < global_position.distance_to(b.global_position))

	# Deal damage to each target now; visual blinks happen during the cinematic.
	var scaled: int = _bea_scale_damage(ULT_PER_ENEMY_DAMAGE)
	var last_target_pos: Vector2 = global_position
	for e in targets:
		var dir: Vector2 = (e.global_position - global_position).normalized()
		# Run 17 — Ult applies family statuses at ULT magnitude (5 stacks where applicable).
		_bea_apply_family_statuses_on_hit(e, false, false, false, false, true)
		e.set_meta("last_damager", "bea")   # Run 134 — killer attribution (fix 5)
		e.take_damage(scaled, dir)
		_ult_blink_positions.append(e.global_position)
		last_target_pos = e.global_position
		FX.spawn_hit_particles(e.global_position, Color(1.0, 0.8, 1.0, 1.0), 8)

	# Final flourish — bonus damage burst at last target (or back at start if no enemies)
	var flourish_scaled: int = _bea_scale_damage(ULT_FLOURISH_DAMAGE)
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or not e.has_method("take_damage"):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		if last_target_pos.distance_to(e.global_position) <= ULT_FLOURISH_RADIUS:
			var dir2: Vector2 = (e.global_position - last_target_pos).normalized()
			if dir2.length() < 0.01:
				dir2 = facing
			e.set_meta("last_damager", "bea")   # Run 134 — killer attribution (fix 5)
			e.take_damage(flourish_scaled, dir2)
			FX.spawn_burst_particles(e.global_position, Color(1.0, 0.95, 0.6, 1.0), 12)

	# Time-freeze any survivors (e.g., future boss enemy) for the cinematic
	for e in get_tree().get_nodes_in_group("enemy"):
		if is_instance_valid(e) and e.has_method("is_alive") and e.is_alive():
			e.process_mode = Node.PROCESS_MODE_DISABLED
			_ult_freeze_targets.append(e)

	# Spawn the screen-wide flash overlay (purple-pink, distinct from Shino's gold)
	_spawn_ult_flash()
	FX.screen_shake(FX.SHAKE_ULT, FX.SHAKE_DUR_LONG)
	FX.play_sound("bea_ult_fire", 1.3)
	emit_signal("ult_fired")


func _tick_ult(delta: float) -> void:
	_ult_timer -= delta
	velocity = Vector2.ZERO
	move_and_slide()

	# Visual: teleport Bea between blink positions over the cinematic window
	if not _ult_in_dizzy and _ult_blink_positions.size() > 0:
		_ult_blink_timer -= delta
		if _ult_blink_timer <= 0.0:
			_ult_blink_timer = ULT_BLINK_INTERVAL
			if _ult_blink_idx < _ult_blink_positions.size():
				# Brief afterimage at current pos
				FX.spawn_hit_particles(global_position, Color(1.0, 0.8, 1.0, 0.7), 5)
				global_position = _ult_blink_positions[_ult_blink_idx]
				FX.spawn_burst_particles(global_position, Color(1.0, 0.6, 0.95, 1.0), 8)
				_ult_blink_idx += 1

	if _ult_timer <= 0.0:
		if not _ult_in_dizzy:
			_ult_in_dizzy = true
			_ult_timer = ULT_DIZZY_DURATION
			# Final flourish pose
			if body_anim and body_anim.has_method("set_anim_state"):
				body_anim.set_anim_state("swing_y")
			FX.spawn_burst_particles(global_position, Color(1.0, 0.95, 0.7, 1.0), 24)
		else:
			# Dizzy resolved → restore enemies + return to player control
			for e in _ult_freeze_targets:
				if is_instance_valid(e):
					e.process_mode = Node.PROCESS_MODE_INHERIT
			_ult_freeze_targets.clear()
			_ult_blink_positions.clear()
			# Run 150 (Bruno fix 11) — release the partner freeze.
			if RunState.ult_freeze_caster == "bea":
				RunState.ult_freeze_caster = ""
			state = State.PLAYER_CONTROLLED if player_controlled else State.AI_FOLLOW   # Run 61b
			if body_anim and body_anim.has_method("set_anim_state"):
				body_anim.set_anim_state("idle")


func _spawn_ult_flash() -> void:
	# Mirror of Shino's _spawn_ult_flash but in Bea's purple/pink palette.
	var layer := CanvasLayer.new()
	layer.layer = 50
	get_tree().current_scene.add_child(layer)
	var flash := ColorRect.new()
	flash.color = Color(1.0, 0.85, 1.0, 0.80)
	flash.anchor_right = 1.0
	flash.anchor_bottom = 1.0
	layer.add_child(flash)
	var tw: Tween = create_tween()
	tw.tween_property(flash, "color:a", 0.0, ULT_CINEMATIC_DURATION + ULT_DIZZY_DURATION)
	tw.tween_callback(Callable(layer, "queue_free"))


# ---- Damage scaling (boon mults + crit, parallel to Shino's _scale_damage) ----
# Run 12 — extended to apply the same Apple HP-tier / Full Bloom / Grape mults
# Shino uses, so both heroes get the boon payoff. Bea doesn't track a combo
# counter of her own yet (Phase 8 candidate), so Combo Master / Noble Rot use
# the shared `combo_count` if a Player node is reachable, else 0.
# Run 16 — added is_primary flag (Y-gate) for Heavy Stalk + Full Bloom; mirrors Player.gd.
# -------------------------------------------------------
# Bea finisher impact — mirrors Shino's _spawn_finisher_impact.
# is_spin = true for katana 360° spin (Y finisher, teal ring).
# is_spin = false for naginata overhead slam (X finisher, violet ring).
# -------------------------------------------------------
func _spawn_bea_finisher_impact(pos: Vector2, is_spin: bool) -> void:
	var parent: Node = get_parent()
	if parent:
		var ring := Line2D.new()
		ring.width = 3.5
		ring.default_color = Color(0.25, 0.95, 0.85, 0.90) if is_spin else Color(1.0, 1.0, 1.0, 0.90)
		ring.z_index = 12
		# Points as LOCAL offsets (center at ring.position = pos).
		# Old code baked world coords into points, making the tween scale from origin
		# instead of from pos — which caused the ring to fly toward the screen corner.
		var pts: PackedVector2Array = []
		var n: int = 24
		for i in range(n + 1):
			var a: float = TAU * float(i) / float(n)
			pts.append(Vector2(cos(a), sin(a)) * 18.0)
		ring.points = pts
		ring.position = pos   # place at impact point BEFORE add_child so tween scales correctly
		parent.add_child(ring)
		var tw: Tween = ring.create_tween()
		tw.tween_property(ring, "scale", Vector2(3.2, 3.2), 0.20)
		tw.parallel().tween_property(ring, "modulate:a", 0.0, 0.20)
		tw.tween_callback(ring.queue_free)

	# Enemy white-flash.
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or (e.has_method("is_alive") and not e.is_alive()):
			continue
		if pos.distance_to(e.global_position) > 52.0:
			continue
		if e is Node2D:
			var orig: Color = (e as Node2D).modulate
			(e as Node2D).modulate = Color(1.8, 1.8, 1.8, 1.0)
			var etw: Tween = (e as Node2D).create_tween()
			etw.tween_property(e, "modulate", orig, 0.14)

	# Burst particles — gold (katana spin) or violet (naginata overhead).
	var col: Color = Color(1.0, 0.82, 0.35, 1.0) if is_spin else Color(0.75, 0.45, 1.0, 1.0)
	FX.spawn_burst_particles(pos, col, 16)
	FX.spawn_hit_particles(pos, Color(1.0, 1.0, 1.0, 0.9), 8)
	FX.screen_shake(FX.SHAKE_MEDIUM, FX.SHAKE_DUR_SHORT)


# Run 132 — Bea mirror of Player._apply_ult_boon_cast_effects, gated to Bea's own
# boons (she is the caster). Team-wide EFFECTS (heal/shield both) still hit both
# heroes but only trigger when Bea owns the boon; self-buffs land on Bea.
func _bea_apply_ult_boon_cast_effects() -> void:
	# Harvest Moon (Apple): both heroes heal 25% max HP on cast.
	if RunState.bea_has("harvest_moon"):
		heal_external(max(1, int(round(float(get_effective_max_hp()) * 0.25))))
		if _shino != null and is_instance_valid(_shino) and _shino.has_method("heal_external") \
		and _shino.has_method("get_effective_max_hp"):
			_shino.heal_external(max(1, int(round(float(_shino.get_effective_max_hp()) * 0.25))))
	# Bulwark Strike (Coconut): both heroes gain max overshells.
	if RunState.bea_has("bulwark_strike"):
		grant_overshield_external(3)
		if _shino != null and is_instance_valid(_shino) and _shino.has_method("grant_overshield_external"):
			_shino.grant_overshield_external(3)
	# Titan's Roar (Broccoli): +20% all damage for 5s post-cast (Bea's window).
	if RunState.bea_has("titans_roar"):
		_titans_roar_window = 5.0
	# Bullseye Finale (Carrot): +25% crit chance for 10s post-cast (Bea's window).
	if RunState.bea_has("bullseye_finale"):
		_bullseye_finale_window = 10.0
	# Bunch Bloom (Grape): combo counter instantly set to max (30) — Bea's meter.
	if RunState.bea_has("bunch_bloom_ult"):
		combo_count = 30
		RunState.set_combo("bea", combo_count)
		emit_signal("combo_count_changed", combo_count)


func _get_bea_target_status_damage_mult(target: Node) -> float:
	# Target-dependent damage amps — mirrors Player._get_target_status_damage_mult.
	var mult: float = 1.0
	if not is_instance_valid(target):
		return mult
	var ts: Variant = target.get("status") if target.has_method("get") else null
	# Run 150b (Bruno ruling): target-status damage amps are SELF-buffs —
	# only the ninja holding the boon benefits. Global flags → bea_has() gates.
	if RunState.bea_has("crushing_blow"):
		var t_hp: int = int(target.get("current_hp") if "current_hp" in target else -1)
		var t_max: int = int(target.get("max_hp") if "max_hp" in target else 1)
		if t_hp > 0 and t_max > 0:
			mult *= RunState.get_crushing_blow_mult(float(t_hp) / float(t_max))
	if RunState.bea_has("bash_big_ones"):
		mult *= RunState.get_bash_big_ones_mult(target.is_in_group("boss") or target.is_in_group("elite"))

	# Run 46 — Boss Hunter (Sensei Z): +5%/tier vs bosses, mini-bosses, elites.
	if RunState.sensei_boss_dmg_pct > 0.0:
		if target.is_in_group("boss") or target.is_in_group("miniboss") or target.is_in_group("elite"):
			mult *= (1.0 + RunState.sensei_boss_dmg_pct)
	if ts != null and ts.has_method("has"):
		if RunState.bea_has("blazing_aura") and ts.has("burning"):
			mult *= 1.10
		if RunState.bea_has("inferno_crown") and ts.has("burning"):
			mult *= 1.40
		if RunState.bea_has("rising_tide") and (ts.has("wet") or ts.has("chilled") or ts.has("drenched") or ts.has("frostbitten")):
			mult *= 1.15
		if RunState.bea_has("tough_cookie") and (ts.has("bash") or ts.has("stagger") or ts.has("vulnerable")):
			mult *= 1.15
		if RunState.bea_has("fermented_strength") and ts.has_method("get_stacks"):
			var ps: int = ts.get_stacks("poison")
			if ps > 0:
				mult *= (1.0 + 0.05 * float(ps))
	return mult


func _bea_scale_damage(base: int, is_finisher: bool = false, is_primary: bool = false, target: Node = null, attack_type: String = "") -> int:
	var mult: float = RunState.get_char_damage_mult("bea")
	var _atype: String = attack_type if attack_type != "" else ("primary" if is_primary else "heavy")
	# Run 27f — One Big Grape corrupt: every Y/X press is a finisher.
	if RunState.bea_has("corrupt_grape"):
		is_finisher = true
	# Run 27f/134 — Drawn Bow (Carrot passive): idle pause → guaranteed crit
	# (melee AND ranged). CHARGED attacks (vortex/meteor) need the longer 3s idle.
	var _db_thresh: float = RunState.DRAWN_BOW_IDLE_CHARGED if _atype == "charge" else RunState.DRAWN_BOW_IDLE
	if RunState.bea_has("drawn_bow") and _no_attack_timer >= _db_thresh:
		RunState.force_next_crit = true
	_no_attack_timer = 0.0
	# Run 132 — Bullseye Finale post-ult window: +25% crit chance (mirrors Player.gd).
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
	if RunState.bea_has("topshot") and target != null and is_instance_valid(target) \
	and not target.has_meta("topshot_bea"):
		target.set_meta("topshot_bea", true)
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
	# Run 129 — Golden Carrot (Bea parity — was Shino-only) + Master Stroke
	# guarantee, moved PRE-roll so the FINISHER itself crits (the old post-hit
	# sets primed the hit AFTER the finisher — removed).
	# Run 131 — Golden Carrot is now dash-armed (one finisher per dash). Master
	# Stroke duo keeps the unconditional every-finisher guarantee.
	if is_finisher and RunState.master_stroke_active():
		RunState.force_next_crit = true
	elif is_finisher and RunState.bea_has("golden_carrot") and _golden_carrot_armed:
		RunState.force_next_crit = true
		_golden_carrot_armed = false
	if RunState.has_method("roll_crit_mult"):
		mult *= RunState.roll_crit_mult(_atype, "bea")
	# Run 128 — Smash Zone (Broccoli Legendary): melee-only proximity damage.
	if (_atype == "primary" or _atype == "heavy") and target != null \
	and is_instance_valid(target) and target is Node2D:
		mult *= RunState.get_smash_zone_mult("bea", global_position.distance_to((target as Node2D).global_position))
	# Run 128 — Vineyard Reserve (Grape Legendary): at 30+ combo, +30% all damage.
	if RunState.bea_has("vineyard_reserve") and combo_count >= 30:
		mult *= 1.30
	# Run 128 — Master Stroke duo arm 2: finisher crits deal +50% crit damage.
	if is_finisher and RunState.last_crit_result and RunState.master_stroke_active():
		mult *= 1.5
	# Run 130 — Marksman's Eye: +30% crit damage vs the Marked target.
	if _atype == "ranged" and RunState.last_crit_result and target != null \
	and is_instance_valid(target) and target.has_meta("me_marked") \
	and RunState.team_has("marksmans_eye"):
		mult *= 1.30
	# Apple Heavy Harvest — heavy/X attacks gain up to +25% at full HP (per-Bea).
	var max_hp_bea: int = get_effective_max_hp()
	var hp_frac_bea: float = float(current_hp) / float(max(1, max_hp_bea))
	if not is_primary:
		mult *= RunState.get_heavy_harvest_mult(hp_frac_bea, "bea")
	# Apple Sweet Harvest — charge attacks +20% dmg at 75%+ HP (per-Bea).
	if _atype == "charge":
		mult *= RunState.get_sweet_harvest_mult(hp_frac_bea, "bea")
		# Run 132 — Fury Release (Broccoli Charge): +60% charge damage (owner-gated).
		if RunState.bea_has("fury_release"):
			mult *= (1.0 + RunState.FURY_RELEASE_DMG_BONUS)
	# Run 127 — status-slot baseline dmg (Hades parity)
	# Status-only slot boons (Soaked/Slippery/Greased appliers) also boost that
	# slot's base damage. Map attack type → slot so each fires ONLY for its slot.
	# NOTE: Bea's kunai (A) bypasses this funnel — its A hook is at _spawn_kunai.
	var _status_slot: String = ""
	match _atype:
		"primary": _status_slot = "Y"
		"heavy": _status_slot = "X"
		"ranged": _status_slot = "A"
		"charge": _status_slot = "Charge"
	if _status_slot != "":
		mult *= RunState.get_status_slot_dmg_mult("bea", _status_slot)
	# Run 132 — Grape Bunch Bonus: +25% dmg with 2+ enemies within 3m (owner-gated).
	if RunState.bea_has("bunch_bonus") and _count_nearby_enemies(BUNCH_BONUS_RADIUS) >= 2:
		mult *= 1.25
	# Cluster Cascade — cross-finisher buff.
	if is_finisher:
		mult *= RunState.get_cluster_cascade_mult(is_primary)
		RunState.notify_cluster_cascade_finisher(is_primary)
	# Critical Mass: trigger on crit.
	if RunState.bea_has("critical_mass") and RunState.last_crit_result:
		_critical_mass_stacks = min(RunState.CRITICAL_MASS_MAX_STACKS, _critical_mass_stacks + 1)
		_critical_mass_timer = RunState.CRITICAL_MASS_DURATION
	# Broccoli Heavy Stalk + Stalk of Might — per-Bea ownership.
	mult *= RunState.get_heavy_stalk_mult(is_primary, "bea")
	# Run 27b — Potato Heavy Stance: +15% damage while Ingrained (1.5s+ still).
	if RunState.bea_has("heavy_stance") and _ingrained_time >= RunState.INGRAINED_THRESHOLD:
		mult *= 1.15
	mult *= RunState.get_stalk_of_might_mult_for("bea")
	# Broccoli Combat Fury — Run 139: Bea rides her OWN tier now (was borrowing
	# Shino's, which leaked his ramp cross-hero). Multiply with the current
	# tier, then advance it — this function runs once per landed hit.
	mult *= RunState.get_combat_fury_mult(_combat_fury_tier, "bea")
	if RunState.bea_has("combat_fury"):
		_combat_fury_tier = min(RunState.COMBAT_FURY_MAX_TIERS, _combat_fury_tier + 1)
		_combat_fury_decay_timer = RunState.COMBAT_FURY_DECAY_SEC
	# Apple Full Bloom + Ripened Core + Heart of the Orchard — HP-fraction-driven.
	var max_hp_eff: int = get_effective_max_hp()
	var hp_frac: float = float(current_hp) / float(max(1, max_hp_eff))
	mult *= RunState.get_full_bloom_mult(hp_frac, is_primary, "bea")
	mult *= RunState.get_apple_hp_tier_mult(hp_frac, "bea")
	mult *= RunState.get_green_rage_mult(hp_frac, "bea")
	# This function runs once per landed hit — bump Bea's own combo meter here.
	_bump_combo()
	# Grape combo scaling — Bea now uses her OWN combo counter.
	var shared_combo: int = combo_count
	mult *= RunState.get_combo_master_mult(shared_combo, "bea")
	mult *= RunState.get_noble_rot_mult(shared_combo, is_finisher, "bea")
	# Run 19 — Iron Core duo (Apple + Broccoli) damage amp.
	mult *= RunState.get_iron_core_damage_mult()
	# Dragon Fruit: apply Coconut+Broccoli Ironwood if Bea has overshield.
	mult *= RunState.get_coconut_broccoli_dmg_mult(overshield_charges)
	# Run 132 — Sniper's Focus (Carrot Legendary 2): +50% dmg during the bonus
	# Run 134 — per-hero streak + window (fix 3). Bea maintains her OWN Sniper's
	# Focus streak; Shino's crits never advance her buff and vice versa.
	mult *= RunState.get_sniper_focus_mult("bea")
	RunState.tick_sniper_focus(RunState.last_crit_result, "bea")
	# Run 132 — Titan's Roar post-ult window: +20% all damage (mirrors Player.gd).
	if _titans_roar_window > 0.0:
		mult *= 1.20
	# Run 132 — Killshot (Carrot passive): crits on targets below 25% HP have a 7%
	# chance to Super-Mega-Crit (~3x extra). Owner-gated to Bea (mirrors Player.gd).
	if RunState.last_crit_result and RunState.bea_has("killshot") \
	and target != null and target.get("max_hp") != null and target.get("current_hp") != null:
		if float(target.current_hp) / max(1.0, float(target.max_hp)) < 0.25 and randf() < 0.07:
			mult *= 3.0
			RunState._set_crit_tier(2)   # Super-Mega-Crit shows RED
			FX.spawn_burst_particles((target as Node2D).global_position, Color(1.0, 0.30, 0.10, 1.0), 16)
	# Target-status multipliers (Blazing Aura, Rising Tide, Crushing Blow, etc.)
	if target != null and is_instance_valid(target):
		mult *= _get_bea_target_status_damage_mult(target)
	# Sensei Z: Dragon Vigor flat damage bonus.
	mult *= (1.0 + RunState.sensei_damage_pct)
	var _scaled_out: float = float(base) * mult
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
				_me_e.take_damage(max(1, int(round(_scaled_out * 0.75))), Vector2.ZERO)
				FX.spawn_hit_particles(_me_e.global_position, Color(1.0, 0.45, 0.15, 0.9), 5)
				_me_hits += 1
				if _me_hits >= 3:
					break
	return max(1, int(_scaled_out))


# ============================================================
# AI — follow Shino + attack enemies
# ============================================================

func _handle_ai(delta: float) -> void:
	# Run 38 — Dojo: walk to her spot on the Training Mat and sit; no
	# following, no kunai (she'd pepper the training dummy forever).
	if dojo_mode:
		_tick_dojo_wait(delta)
		return

	# Run 61 — pull the live tier spec once per tick. Tier 1 means "Spectator":
	# zero attacks, just follow and avoid hazards. Higher tiers add offense.
	var spec: Dictionary = RunState.get_ai_tier_spec()
	var tier: int = RunState.ai_helper_tier

	# Run 64c — reverse the dance direction every few seconds so she doesn't
	# trace endless same-way circles. Randomized interval = organic, not robotic.
	_bea_orbit_flip_timer -= delta
	if _bea_orbit_flip_timer <= 0.0:
		_bea_orbit_sign = -_bea_orbit_sign
		_bea_orbit_flip_timer = 2.5 + randf() * 2.5

	# ---------------- MOVEMENT (universal) ----------------
	var move_vec: Vector2 = Vector2.ZERO
	# Run 91 — straight-line direction to whatever she's trying to reach this
	# frame (gate / enemy / Shino). Used by the dash-through-barrier check so she
	# phases an inner barrier that's blocking the path instead of grinding on it.
	var ai_goal_dir: Vector2 = Vector2.ZERO
	var ai_goal_dist: float = 1.0e9
	# Run 39 — consensus-exit assist: gate priority over combat (universal).
	var rally: Vector2 = _get_gate_rally_pos()
	# Run 61 — pick a combat target (used by both move + attack decisions
	# so melee tiers can close the gap, not just react after arriving).
	var target: Node = _get_nearest_enemy()
	var target_dist: float = 1.0e9
	if target != null and is_instance_valid(target):
		target_dist = global_position.distance_to(target.global_position)

	# --- Priority 0 (Run 65): revive a downed partner ---
	# Mirror of Player.gd's Shino AI. A downed ally outranks gates and combat:
	# beeline to the body (hazard-avoided) so _tick_revive_attempt can finish the
	# rez. RunState.revive_recall_active (set by a downed player's Q+Q at tier 5)
	# forces the channel even when Bea would normally hold back.
	var downed_ally: Node = _find_downed_partner()
	if downed_ally != null and is_instance_valid(downed_ally):
		var to_down: Vector2 = downed_ally.global_position - global_position
		if to_down.length() > REVIVE_CHANNEL_RANGE * 0.85:
			# Run 91 — phase an inner barrier between her and the body, too.
			if _ai_try_dash_through_barrier(to_down.normalized(), to_down.length()):
				return
			var mvd: Vector2 = to_down.normalized()
			_ai_hazard_push = _ai_compute_hazard_push(mvd)
			var goal_d: Vector2 = mvd + _ai_hazard_push
			if goal_d.length() > 0.001:
				mvd = goal_d.normalized()
			facing = mvd
			velocity = mvd * move_speed * RunState.move_speed_mult
		else:
			velocity = Vector2.ZERO
		move_and_slide()
		return

	if rally.is_finite():
		var to_rally: Vector2 = rally - global_position
		if to_rally.length() > 6.0:
			move_vec = to_rally.normalized()
			facing = move_vec
			ai_goal_dir = move_vec
			ai_goal_dist = to_rally.length()
	else:
		# Tier 2..5 close the gap to engageable enemies. Tier 1 = pure follow.
		# Bug-fix Run 61b: do NOT fall back to "follow Shino" once inside
		# melee range — the AI would backpedal and never land a swing.
		var melee_engage: float = float(spec.get("melee_engage_dist", -1.0))
		var ranged_iv: float = float(spec.get("ranged_interval", -1.0))
		var want_close: bool = false
		if tier >= 2 and target != null:
			# At T2 (no melee tier) we still close to ranged-window range so
			# Bea has a clear line to throw. At T4/T5 we close all the way.
			var max_close_dist: float = melee_engage if melee_engage > 0.0 else AI_ATTACK_RANGE
			if target_dist <= max_close_dist:
				# Stay near the player-controlled hero — pursuit leash is
				# loose (1.6x AI_ATTACK_RANGE) so Beast Mode can swing wide.
				if _shino == null or not is_instance_valid(_shino) \
				or global_position.distance_to(_shino.global_position) <= AI_ATTACK_RANGE * 1.6:
					want_close = true
		if want_close:
			var to_t: Vector2 = target.global_position - global_position
			var td: float = to_t.length()
			var radial: Vector2 = to_t.normalized() if td > 0.001 else facing
			facing = radial
			ai_goal_dir = radial
			ai_goal_dist = td
			if melee_engage > 0.0:
				# Run 64c — DANCER ORBIT. Bea swirls around her target instead of
				# planting. Motion is mostly tangential (circling), with a soft
				# radial nudge that keeps her near BEA_ORBIT_RADIUS — pull in when
				# too far, drift out when too close. The radius breathes via a slow
				# sine so the orbit looks like a swirl, not a fixed ring. She still
				# stays inside katana reach (64px), so she keeps landing swings as
				# she circles. _bea_orbit_sign flips every few seconds (below).
				var orbit_r: float = BEA_ORBIT_RADIUS + sin(Time.get_ticks_msec() * 0.0016) * 10.0
				var tangent: Vector2 = Vector2(-radial.y, radial.x) * _bea_orbit_sign
				var radius_err: float = clampf((td - orbit_r) / 36.0, -1.0, 1.0)
				move_vec = (tangent + radial * radius_err * 0.7).normalized()
			else:
				# Pure-ranged tiers: close to a comfortable shooting distance, hold.
				if td > 180.0:
					move_vec = radial
				else:
					move_vec = Vector2.ZERO
		elif _shino != null and is_instance_valid(_shino):
			var to_shino: Vector2 = _shino.global_position - global_position
			var dist: float = to_shino.length()
			if dist > AI_FOLLOW_DIST_TARGET + 12.0:
				move_vec = to_shino.normalized()
				facing = move_vec
				ai_goal_dir = move_vec
				ai_goal_dist = dist
			elif dist < AI_FOLLOW_DIST_STOP:
				move_vec = -to_shino.normalized() * 0.35

	# Run 63 — UNIVERSAL trap / hazard avoidance: every tier steers around hazard
	# zones (lava patches, gas clouds, biome traps). The avoidance vector now
	# rounds traps that sit ahead (see _ai_compute_hazard_push), and the final
	# heading is smoothed frame-to-frame so clusters of close traps make her
	# glide through the gap instead of vibrating between them.
	_ai_hazard_push = _ai_compute_hazard_push(move_vec)
	var goal_vec: Vector2 = move_vec + _ai_hazard_push
	if goal_vec.length() > 0.001:
		var target_dir: Vector2 = goal_vec.normalized()
		if _ai_steer_smoothed == Vector2.ZERO:
			_ai_steer_smoothed = target_dir
		else:
			_ai_steer_smoothed = _ai_steer_smoothed.lerp(target_dir, clampf(delta * AI_STEER_SMOOTH_RATE, 0.0, 1.0)).normalized()
		move_vec = _ai_steer_smoothed
	else:
		# Wants to hold position (in range / no push) — let her settle, don't keep a stale heading.
		_ai_steer_smoothed = Vector2.ZERO
		move_vec = Vector2.ZERO

	# Run 61 — natural movement variance (gentle sideways drift so she doesn't
	# trace robotic straight lines). Tiny lateral wobble scaled by speed.
	if move_vec != Vector2.ZERO:
		var wobble: float = sin(Time.get_ticks_msec() * 0.0027) * 0.18
		var perp: Vector2 = Vector2(-move_vec.y, move_vec.x)
		move_vec = (move_vec + perp * wobble).normalized()

	# Run 91 — DASH THROUGH BARRIERS. Before we fall back to grinding/sidestepping
	# around an obstacle, check whether the thing blocking the path to her goal is
	# an inner "dashable_barrier" (rock slat, river, log). If so, dash through it
	# exactly like the player can, so she keeps following / closing instead of
	# stalling behind a barrier she's allowed to phase. Returns true if a dash
	# started — the DASHING tick takes over from here this frame.
	if _ai_try_dash_through_barrier(ai_goal_dir, ai_goal_dist):
		return

	# Run 69 — wall/corner escape (after all steering, before we commit velocity).
	move_vec = _ai_unstick(move_vec, delta)

	velocity = move_vec * move_speed * RunState.move_speed_mult
	move_and_slide()

	# ---------------- COMBAT (tier-gated) ----------------
	# Tier 1 NEVER attacks (Spectator). Bail out cleanly.
	if tier <= 1:
		return

	# Update charge-attempt cadence.
	if _ai_charge_try_timer > 0.0:
		_ai_charge_try_timer -= delta
	if _ai_melee_cd > 0.0:
		_ai_melee_cd -= delta

	if target == null or not is_instance_valid(target):
		return
	var dir: Vector2 = (target.global_position - global_position).normalized()
	facing = dir

	# ---------- MELEE WINDOW (Tier 3/4/5) ----------
	# Tier 3 occasionally chips in; Tier 4/5 prefers melee. Triggers a Y-tap
	# katana when in range and the melee-chance roll wins. Trigger range is
	# whichever is shorter: the tier's melee_engage_dist (200px @T5) or a
	# fixed close-strike range — at any closer distance the swing is reliable.
	var melee_eng: float = float(spec.get("melee_engage_dist", -1.0))
	const MELEE_SWING_REACH: float = 64.0   # katana sweep covers ~50-60px; swing inside this
	var swing_now: bool = false
	# Run 64b — once a katana combo has started (katana_step != 0) we must keep
	# swinging until the finisher, otherwise the per-swing melee_chance roll stalls
	# the chain (e.g. T3's 25% roll leaves it stuck on hit 1, "one strike per ~1s").
	# A fresh combo still only starts on a winning melee_chance roll.
	var bea_mid_combo: bool = (katana_step != 0)
	if melee_eng > 0.0 and target_dist <= MELEE_SWING_REACH and _ai_melee_cd <= 0.0 \
	and state == State.AI_FOLLOW:
		if bea_mid_combo:
			swing_now = true
		else:
			var melee_chance: float = float(spec.get("melee_chance", 0.0))
			if randf() < melee_chance:
				swing_now = true
	if swing_now and has_method("_tap_katana"):
		# Close-range katana tap. Reuses Bea's player kit entry point.
		# _tap_katana sets BEA_ATTACKING; the state machine will return
		# to AI_FOLLOW after the swing lockout. Print so Bruno can see it.
		print("[Bea AI T%d] melee swing — target @%.0fpx" % [tier, target_dist])
		_tap_katana()
		# Run 64b/115 — two-phase cadence. _tap_katana just advanced katana_step;
		# ==0 means the 4-hit combo's finisher landed. Mid-combo we re-tap fast
		# (well under the combo window) so all 4 hits chain; after the
		# finisher we rest by tier aggressiveness before the next melee_chance roll.
		if katana_step == 0:
			_ai_melee_cd = 0.55 if tier >= 5 else (0.85 if tier == 4 else 1.25)
		else:
			_ai_melee_cd = 0.10  # Run 116: matches faster katana lockout (was 0.16)
		return

	# ---------- CHARGE ATTEMPT (Tier 2..5, gated) ----------
	# Only fires when:
	#   * tier's charge_chance roll wins
	#   * no enemies within AI_CHARGE_SAFE_RANGE (safe to channel)
	#   * Bea isn't already mid-attack
	# Tier 2 uses it very rarely; Tier 5 reaches for charges aggressively.
	if _ai_charge_try_timer <= 0.0 and state == State.AI_FOLLOW:
		var charge_chance: float = float(spec.get("charge_chance", 0.0))
		if charge_chance > 0.0 and randf() < charge_chance and _ai_safe_to_charge():
			_ai_try_release_charge(dir)
			# Reset cadence whether or not the charge fired (some prerequisites
			# may have failed silently in _ai_try_release_charge).
			_ai_charge_try_timer = 4.5 if tier >= 5 else (6.0 if tier == 4 else 7.5)
		else:
			# Short retry window so we don't sit on a missed roll forever.
			_ai_charge_try_timer = 1.2

	# ---------- RANGED WINDOW (Tier 2..5) ----------
	# Tier-driven cadence overrides the legacy AI_ATTACK_INTERVAL.
	var iv: float = float(spec.get("ranged_interval", -1.0))
	if iv > 0.0 and _attack_timer <= 0.0 and target_dist <= AI_ATTACK_RANGE * 1.2:
		print("[Bea AI T%d] kunai @%.0fpx (iv=%.2f)" % [tier, target_dist, iv])
		_throw_kunai(dir)
		# +/-15% jitter so partner shots feel organic, not metronomic.
		_attack_timer = iv * (0.85 + randf() * 0.30)


# Run 39 — Ask the arena controller (World.gd, group "world") where the
# consensus exit is waiting, if anywhere. Vector2.INF = nobody's waiting.
func _get_gate_rally_pos() -> Vector2:
	for w in get_tree().get_nodes_in_group("world"):
		if w.has_method("get_ai_gate_rally_pos"):
			return w.get_ai_gate_rally_pos()
	return Vector2.INF


# Run 38 — Dojo wait AI. Off-duty Bea walks to the middle of the dojo
# (her spot on the Training Mat) and sits there until swapped to.
# Placeholder "sit": sprite nudged down a few px + animation frozen.
func _tick_dojo_wait(_delta: float) -> void:
	var to_spot: Vector2 = dojo_wait_pos - global_position
	if to_spot.length() > 8.0:
		facing = to_spot.normalized()
		velocity = facing * move_speed * RunState.move_speed_mult * 0.8
		if _bea_sprite:
			_bea_sprite.position.y = -9.0   # standing while walking over
	else:
		velocity = Vector2.ZERO
		if _bea_sprite:
			_bea_sprite.position.y = -4.0   # placeholder sitting pose
	move_and_slide()


# ============================================================
# Kunai throw (shared between AI and player-controlled)
# Bea's ranged attack — fast thrown blade, NOT a Ki Blast.
# ============================================================

## Run 60 — Melee aim snap: orient a tap toward the nearest enemy within reach,
## unless the player is pushing the stick roughly opposite that enemy.
func _apply_melee_aim_snap() -> void:
	# Run 105 — weighted best-target auto-aim (mirror of Player.gd). Intent = stick
	# push if moving, else current facing. Score blends front-alignment + closeness
	# so a tap turns toward the foe you mean to hit, never the raw-nearest behind
	# you or your walk direction (empty space).
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
		if d > MELEE_REACH and align < MELEE_SNAP_MIN_ALIGN:
			continue
		var closeness: float = 1.0 - clampf(d / MELEE_SNAP_RANGE, 0.0, 1.0)
		var score: float = align * MELEE_SNAP_ALIGN_WEIGHT + closeness
		if score > best_score:
			best_score = score
			best = e
	if best == null:
		# No valid target — swing straight ahead. If Bea is actively moving,
		# snap facing to her travel direction so the katana lands directly in
		# front of her path; standing still, keep current facing (already ahead).
		if pushing:
			facing = move_dir
		return
	var to_best: Vector2 = (best.global_position - global_position).normalized()
	# Deliberate-retreat escape: refuse the snap only when actively pushing hard
	# AWAY from the target AND it's beyond strike reach. In-reach hits always land.
	if pushing and move_dir.dot(to_best) < MELEE_SNAP_OPPOSITE_DOT \
			and global_position.distance_to(best.global_position) > MELEE_REACH:
		return
	facing = to_best


## Run 105 — kunai soft aim-assist (A-button throws only). Among foes in a wide
## forward arc, pick the best closeness+alignment blend so button throws snap to
## the threat Bea is facing. Falls back to raw facing when the arc is empty.
## NOTE: the twin-stick throw path does NOT call this — stick aim stays free.
func _pick_kunai_aim_dir() -> Vector2:
	var best: Node2D = null
	var best_score: float = -1.0e9
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or not (e is Node2D):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		var to_e: Vector2 = e.global_position - global_position
		var d: float = to_e.length()
		if d < 4.0 or d > KUNAI_AIM_ASSIST_RANGE:
			continue
		var align: float = to_e.normalized().dot(facing)
		if align < KUNAI_AIM_ASSIST_CONE_COS:
			continue
		# Lower score = better: distance minus an alignment bonus.
		var score: float = d - align * KUNAI_AIM_ASSIST_ALIGN_WEIGHT
		if best == null or score < best_score:
			best_score = score
			best = e
	if best != null:
		return (best.global_position - global_position).normalized()
	return facing


func _throw_kunai(dir: Vector2) -> void:
	if projectile_scene == null:
		return
	_maybe_fire_vine_lash()   # Run 150b — Vine Lash dash-then-attack trigger
	# Run 58 — Stone Throw (Potato A) fires 2 kunai in a spaced line. Bananarang
	# is a single boomerang regardless.
	var shots: int = 1
	if not RunState.bea_has("bananarang"):
		shots = RunState.ranged_shot_count("bea")
	for i in shots:
		_spawn_kunai(dir, float(i) * RunState.STONE_THROW_SPACING)


func _spawn_kunai(dir: Vector2, forward_extra: float) -> void:
	var k: Node2D = projectile_scene.instantiate()
	get_parent().add_child(k)
	k.global_position = global_position + dir * (20.0 + forward_extra)
	# Run 27 — family-color glow on the projectile (A-slot boon family).
	var ku_tint: Color = RunState.get_attack_tint("bea", "A")
	if ku_tint.a > 0.0:
		k.modulate = Color(1, 1, 1, 1).lerp(ku_tint, 0.55)
	var dmg: int = int(round(float(KUNAI_DAMAGE) * RunState.get_ranged_damage_mult("bea")))
	# Run 127 — status-slot baseline dmg (Hades parity)
	# Kunai is Bea's A-slot ranged and bypasses _bea_scale_damage, so apply the
	# A-slot status boon damage boost here (not via the funnel).
	dmg = int(round(float(dmg) * RunState.get_status_slot_dmg_mult("bea", "A")))
	# Run 134 — Drawn Bow for ranged (fix 2): the kunai bypasses _bea_scale_damage,
	# so arm the guaranteed crit here. Uncharged threshold (1.5s). Reset the idle
	# timer on ANY attack. Only the first kunai of a multi-shot consumes the crit
	# (the reset gates the rest). roll_crit_mult is called ONLY when armed, so we
	# don't add natural crit chance to the kunai — just the Drawn Bow guarantee.
	if RunState.bea_has("drawn_bow") and _no_attack_timer >= RunState.DRAWN_BOW_IDLE:
		RunState.force_next_crit = true
		dmg = int(round(float(dmg) * RunState.roll_crit_mult("ranged", "bea")))
	_no_attack_timer = 0.0
	if RunState.bea_has("bananarang") and k.has_method("launch_bananarang"):
		k.launch_bananarang(dir, KUNAI_SPEED, dmg, self, RunState.greased_lightning_mode)
		return
	# Run 58 — Slugshot pierces all (pierce_limit 0); Stone Throw = heavy knockback.
	if RunState.bea_has("slugshot"):
		k.set("pierce_limit", 0)
	if RunState.bea_has("stone_throw"):
		k.set("heavy_knockback", true)
	if k.has_method("launch"):
		k.launch(dir, KUNAI_SPEED, dmg)


# ============================================================
# Take damage / death
# ============================================================
# Run 11 — reconstructed tail. Run 10 tooling incident left this section
# truncated; functions called elsewhere (take_damage, _die, _add_chi, etc.)
# were missing from the file. Rebuilt from the Run 10 log spec.

# Run 44 — hit knockback impulse (see Player.gd take_damage note): stored
# separately and applied as a decaying push in _physics_process, because the
# AI movement code reassigns `velocity` every frame.
var _hit_knockback_vel: Vector2 = Vector2.ZERO

func take_damage(amount: int, knockback_vector: Vector2 = Vector2.ZERO, source: String = "enemy") -> void:
	if state == State.DEAD:
		return
	# A downed body is never a valid target — no enemy hit, trap, lava, or DoT
	# may chip it while it waits for revive. (Belt-and-suspenders with the
	# is_invulnerable flag set in the downed-enter.)
	if state == State.DOWNED:
		return
	if is_invulnerable:
		return
	# Run 128 — Drupe Guard (Coconut Legendary): active invuln window.
	if _drupe_invuln_timer > 0.0:
		return
	# Run 130 — Ghost Pepper: while vanished, direct enemy hits can't find
	# you (lava/poison ground hazards still connect per doc).
	if _ghost_stealthed and source == "enemy":
		return
	# Coconut Overshield (Run 15) — fully absorb the hit if a charge is held.
	if amount > 0 and _consume_overshield():
		return
	# Run 128 — Drupe Guard proc: the triggering hit lands, then 1.5s of
	# full invulnerability (10s CD, -2s per level — handled in RunState).
	var _drupe_dur: float = RunState.try_drupe_guard("bea")
	if _drupe_dur > 0.0:
		_drupe_invuln_timer = _drupe_dur
		FX.spawn_burst_particles(global_position, Color(0.90, 0.75, 0.40, 0.95), 16)
	# Apply knockback impulse (decayed in _physics_process)
	_hit_knockback_vel = (_hit_knockback_vel + knockback_vector).limit_length(400.0)
	# Apply boon-driven incoming damage reduction (Tough Shell, etc.) and
	# status-driven amplification (Vulnerable stacks) — Batch 0 ROT-1 parity
	# with Player.gd (Bea had a live StatusComponent but never applied it).
	var status_mult: float = 1.0
	if status:
		status_mult = status.get_damage_taken_mult()
	# Green Rage <25% HP tier: -25% damage taken (Combat_Boons §8.3 passive 1).
	var gr_dr: float = RunState.get_green_rage_dr(float(current_hp) / max(1.0, float(get_effective_max_hp())), "bea")
	var adjusted: int = int(round(amount * RunState.get_damage_taken_mult_for("bea") * status_mult * gr_dr))
	if adjusted < 1 and amount > 0:
		adjusted = 1
	# Run 139 — Chip-Proof (Bea parity): no single hit removes >15% max HP.
	adjusted = RunState.chip_proof_cap(adjusted, get_effective_max_hp(), "bea")
	# Run 27f — Poison Apple corrupt: ALL damage = exactly 1 HP per hit.
	if RunState.bea_has("corrupt_apple"):
		adjusted = 1
	# Run 27f — Rampart (Potato passive): 20% chance to raise a rock wall
	# (routed through Shino's wall spawner — shared terrain helper).
	if RunState.bea_has("rampart") and randf() < 0.20:
		for _pl in get_tree().get_nodes_in_group("player"):
			if _pl.has_method("_spawn_rampart_wall"):
				_pl._spawn_rampart_wall(global_position + facing.rotated(PI * 0.5) * 36.0)
				break
	# Run 139 — Spineback (Bea parity): 30% chance retaliatory spike at nearby
	# enemies (mirrors Player.gd — spike carries half the incoming hit).
	var _bea_spike: int = RunState.spineback_retaliate(adjusted, "bea")
	if _bea_spike > 0:
		for _se in get_tree().get_nodes_in_group("enemy"):
			if not is_instance_valid(_se):
				continue
			if _se.has_method("take_damage") and global_position.distance_to(_se.global_position) < 150.0:
				_se.take_damage(_bea_spike, (_se.global_position - global_position).normalized())
				FX.spawn_hit_particles(_se.global_position, Color(0.65, 0.45, 0.25, 0.9), 4)
				break   # one nearest enemy — Batch 0 ROT-4 parity with Player.gd
	# Run 62 — Beast Mode (Tier 5) HP floor. When Bea is the tier-5 AI
	# partner (not player-controlled), clamp HP at the floor: the hit still
	# lands (knockback/chi above) but net HP loss stops here, so she never
	# downs. Floor is 0 in every other case → normal downable behavior. The
	# HUD reads tier/control/HP% to paint the guarded bar. (Covers every
	# damage source — melee, ranged, traps, DoT all funnel through here.)
	var _bm_floor: int = RunState.beastmode_hp_floor_value(player_controlled, get_effective_max_hp())
	current_hp = max(_bm_floor, current_hp - adjusted)
	# Run 128 — Shocking Return (Banana passive): 20% when hit — knock down
	# the attacker (nearest-enemy proxy). GL mode: zap + ministun instead.
	if RunState.roll_shocking_return("bea"):
		var _sr_best: Node2D = null
		var _sr_dist: float = 200.0
		for se in get_tree().get_nodes_in_group("enemy"):
			if is_instance_valid(se) and se is Node2D:
				var _sr_d: float = global_position.distance_to(se.global_position)
				if _sr_d < _sr_dist:
					_sr_dist = _sr_d
					_sr_best = se
		if _sr_best != null:
			var _sr_status: Variant = _sr_best.get("status") if _sr_best.has_method("get") else null
			if RunState.greased_lightning_mode:
				if _sr_best.has_method("take_damage"):
					_sr_best.take_damage(4, Vector2.ZERO)
				if _sr_status != null and _sr_status.has_method("apply"):
					_sr_status.apply("bash", 0.3)
				FX.spawn_hit_particles(_sr_best.global_position, Color(0.95, 0.90, 0.30, 1.0), 8)
			else:
				if _sr_status != null and _sr_status.has_method("apply"):
					_sr_status.apply("bash", 1.0)
				FX.spawn_hit_particles(_sr_best.global_position, Color(0.95, 0.85, 0.20, 1.0), 8)
	# Chi gain on taking damage (§8.3.2) — Batch 0 ROT-6/7 parity: route through
	# _add_chi so Cold Waters halving + Poison Apple conversion apply, and the
	# cap honors get_effective_max_chi(). (_add_chi emits bea_chi_changed.)
	_add_chi(int(CHI_PER_DAMAGE_TAKEN * adjusted))
	emit_signal("bea_hp_changed", current_hp, get_effective_max_hp())
	# Phase 7 — Bea-hit shake + purple particles + sound stub.
	FX.screen_shake(FX.SHAKE_MEDIUM, FX.SHAKE_DUR_SHORT)
	FX.spawn_hit_particles(global_position, Color(0.85, 0.45, 0.95, 1.0), 8)
	FX.play_sound("bea_hurt")
	# Run 102 — damage outline: red for direct enemy hits, orange for lava.
	# (Poison keeps its own held purple outline, applied via apply_trap_poison.)
	if _hitfx:
		match source:
			"lava":
				_hitfx.flash(HeroHitFX.COLOR_LAVA, 0.25)
				_hitfx.spawn_lava_embers()
			"poison":
				pass   # purple outline handled by the held poison state
			_:
				_hitfx.flash(HeroHitFX.COLOR_HIT, 0.22)
	# Run 9 — procedural hit-recoil on the body wireframe.
	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_anim_state("hit_recoil")
	if current_hp <= 0:
		# Run 13 rework — DD is no longer per-character. Individual death enters
		# DOWNED; the standing partner may revive (circle/channel). DD only fires
		# when BOTH ninjas are down simultaneously with no rez completed — handled
		# centrally by RunState.resolve_team_down via _check_team_down_state().
		_enter_downed_state()


# Run 102 — swamp poison entry point (called by TrapZone poison pools). Applies
# the 3s purple-outline poison; re-calling refreshes the timer (never stacks).
# The HeroHitFX node ticks the low trap damage once a second on its own.
func apply_trap_poison() -> void:
	if state == State.DOWNED:
		return
	if is_invulnerable:
		return
	if _hitfx:
		_hitfx.start_poison()


# ── Frost (Popsicle Pelican) — mirrors Player.gd ────────────────────────────
func add_frost_stack(n: int = 1) -> void:
	if state == State.DOWNED or is_invulnerable:
		return
	frost_stacks = clampi(frost_stacks + n, 0, FROST_MAX_STACKS)
	_frost_decay_t = FROST_STACK_DECAY
	if _hitfx:
		_hitfx.start_frost(FROST_OUTLINE_HOLD, float(frost_stacks) / float(FROST_MAX_STACKS))


# _frost_move_mult moved to HeroBase (Batch 2).


# Run 13 — Replaced "hide-and-disable" Phase 6 stub with a proper DOWNED state.
# Triggered by take_damage on lethal HP. Bea stays visible on the ground; her
# partner can revive her via circle/channel. DD is no longer fired here.
func _enter_downed_state() -> void:
	if state == State.DOWNED:
		return
	print("[Bea] Bea has been knocked down — waiting for revive.")
	RunState.notify_downed("bea")
	state = State.DOWNED
	velocity = Vector2.ZERO
	rez_fill = 0.0
	# Holster weapons + reset combat state.
	_hide_weapons()
	_charging_button = ""
	_charge_windup_timer = 0.0
	if _hitfx:
		_hitfx.set_charge(0)
	_y_hold_dur = -1.0
	_x_hold_dur = -1.0
	_a_hold_dur = -1.0
	_free_dive_reticle()   # Run 49 — drop landing circle if downed mid-aim
	_set_barrier_phasing(false)   # Run 110 — restore barrier collision if downed mid-leap
	# Permanent i-frames while down (cleared on revive).
	is_invulnerable = true
	iframe_timer = 999.0
	# Dimmed slumped visual.
	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_anim_state("death")
	modulate = Color(0.55, 0.30, 0.55, 0.85)
	# Run 13 — DESIGN: NO auto-swap on KO. Player stays on their downed
	# character; the standing partner keeps fighting and may attempt a revive.
	# Player can manually swap via Q+Q / LB at any time. _handle_swap_input
	# stays reachable from DOWNED state so the swap input isn't lost.
	# Build revive UI (circle + rez bar above body).
	_build_revive_ui()
	# Feel cue.
	FX.spawn_burst_particles(global_position, Color(0.72, 0.22, 0.90, 1.0), 16)
	FX.screen_shake(FX.SHAKE_MEDIUM, FX.SHAKE_DUR_MED)
	FX.play_sound("bea_down", 1.2)
	# Bea remains visible & collide-able as a downed body so partner can find her.
	# (Old Phase 6 stub did `visible = false` + disable collision — both wrong now.)
	call_deferred("_check_team_down_state")


# Legacy `_die()` kept as alias so any callsite that still refers to it routes
# through the new downed-state pipeline.
func _die() -> void:
	_enter_downed_state()


func is_downed() -> bool:
	return state == State.DOWNED


# Called by RunState.resolve_team_down (autoload) when both ninjas down + DD
# charges available. Restores HP, exits DOWNED, applies all queued payload HoTs.
func revive_from_dd(refill_pct: float, payloads: Array) -> void:
	if state != State.DOWNED:
		return
	var max_hp_eff: int = get_effective_max_hp()
	current_hp = max(1, int(round(max_hp_eff * refill_pct)))
	emit_signal("bea_hp_changed", current_hp, max_hp_eff)
	var hot_pct: float = 0.0
	var hot_dur: float = 0.0
	for p in payloads:
		var pd: Dictionary = p
		hot_pct = max(hot_pct, float(pd.get("hot_pct_per_sec", 0.0)))
		hot_dur = max(hot_dur, float(pd.get("hot_duration", 0.0)))
	_dd_hot_pct_per_sec = hot_pct
	_dd_hot_remaining   = hot_dur
	_dd_hot_accum       = 0.0
	_clear_revive_ui()
	is_invulnerable = true
	iframe_timer = REVIVE_IFRAME_ON_GET_UP
	modulate = Color(1.0, 1.0, 1.0, 1.0)
	state = State.PLAYER_CONTROLLED if player_controlled else State.AI_FOLLOW   # respect who's driving (stuck-after-rez bugfix)
	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_anim_state("idle")
	FX.screen_shake(FX.SHAKE_HEAVY, FX.SHAKE_DUR_MED)
	FX.spawn_burst_particles(global_position, Color(1.0, 0.55, 0.30, 1.0), 22)
	FX.play_sound("dd_revive", 1.2)
	print("[Bea] DD team-revive — Bea back at %d/%d HP, HoT %.1f%%/s for %.1fs (payloads=%d)." % [
		current_hp, max_hp_eff,
		_dd_hot_pct_per_sec * 100.0,
		_dd_hot_remaining,
		payloads.size(),
	])


# Called by the standing partner when their rez bar fills 100%.
func revive_from_partner() -> void:
	# Run 27f — Avalanche Aid (Potato passive): completed revive drops 3
	# boulders on enemies within ~200px.
	if state == State.DOWNED and (RunState.shino_has("avalanche_aid") or RunState.bea_has("avalanche_aid")):
		var _aa_hit: int = 0
		for ae in get_tree().get_nodes_in_group("enemy"):
			if _aa_hit >= 3:
				break
			if is_instance_valid(ae) and ae is Node2D \
			and ae.global_position.distance_to(global_position) <= 200.0:
				_aa_hit += 1
				FX.spawn_burst_particles(ae.global_position, Color(0.55, 0.42, 0.28, 1.0), 14)
				if ae.has_method("take_damage"):
					ae.take_damage(15, Vector2.ZERO)
				if ae.has_node("StatusComponent"):
					ae.get_node("StatusComponent").apply("stagger", 0.7, 1)
	if state != State.DOWNED:
		return
	var max_hp_eff: int = get_effective_max_hp()
	current_hp = max(1, int(round(max_hp_eff * REVIVE_AT_HP_PCT)))
	emit_signal("bea_hp_changed", current_hp, max_hp_eff)
	_clear_revive_ui()
	is_invulnerable = true
	iframe_timer = REVIVE_IFRAME_ON_GET_UP
	modulate = Color(1.0, 1.0, 1.0, 1.0)
	state = State.PLAYER_CONTROLLED if player_controlled else State.AI_FOLLOW   # respect who's driving (stuck-after-rez bugfix)
	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_anim_state("idle")
	FX.screen_shake(FX.SHAKE_MEDIUM, FX.SHAKE_DUR_MED)
	FX.spawn_burst_particles(global_position, Color(0.6, 1.0, 0.6, 1.0), 16)
	FX.play_sound("partner_revive", 1.0)
	print("[Bea] Partner revive — Bea back at %d/%d HP (%.0f%%)." % [
		current_hp, max_hp_eff, REVIVE_AT_HP_PCT * 100.0,
	])


# Called by Bea AFTER both ninjas down + RunState says no DD → team Game Over.
func trigger_team_game_over() -> void:
	# Hand off to Shino's death/recap/fade flow (single canonical path).
	if _shino != null and is_instance_valid(_shino) and _shino.has_method("trigger_team_game_over"):
		_shino.trigger_team_game_over()


func _check_team_down_state() -> void:
	# Iterate every player+bea node; if all are downed, route to RunState.
	var team: Array = []
	for n in get_tree().get_nodes_in_group("player"):
		team.append(n)
	for n in get_tree().get_nodes_in_group("bea"):
		if not team.has(n):
			team.append(n)
	if team.is_empty():
		return
	var all_down: bool = true
	for n in team:
		if not is_instance_valid(n):
			continue
		if not (n.has_method("is_downed") and n.is_downed()):
			all_down = false
			break
	if not all_down:
		return
	RunState.resolve_team_down(team)


# -------------------------------------------------------
# Revive UI (mirrors Player.gd — single Polygon2D ring + 2 ColorRects)
# -------------------------------------------------------
func _build_revive_ui() -> void:
	if _revive_circle_node == null:
		_revive_circle_node = Node2D.new()
		_revive_circle_node.name = "ReviveCircle"
		_revive_circle_node.z_index = -1
		add_child(_revive_circle_node)
		var ring := Line2D.new()
		ring.width = 3.0
		ring.default_color = Color(0.4, 1.0, 0.6, 0.55)
		ring.closed = true
		var n: int = 28
		for i in range(n):
			var ang: float = TAU * float(i) / float(n)
			ring.add_point(Vector2(cos(ang), sin(ang)) * REVIVE_CIRCLE_RADIUS)
		_revive_circle_node.add_child(ring)
	_revive_circle_node.visible = true

	if _rez_bar_bg == null:
		_rez_bar_bg = ColorRect.new()
		_rez_bar_bg.name = "RezBarBG"
		_rez_bar_bg.color = Color(0.1, 0.1, 0.1, 0.85)
		_rez_bar_bg.size = Vector2(48.0, 6.0)
		_rez_bar_bg.position = Vector2(-24.0, -38.0)
		add_child(_rez_bar_bg)
		_rez_bar_fill = ColorRect.new()
		_rez_bar_fill.name = "RezBarFill"
		_rez_bar_fill.color = Color(0.45, 1.0, 0.55, 0.95)
		_rez_bar_fill.size = Vector2(0.0, 6.0)
		_rez_bar_fill.position = Vector2(-24.0, -38.0)
		add_child(_rez_bar_fill)
	_rez_bar_bg.visible = true
	_rez_bar_fill.visible = true
	_rez_bar_fill.size.x = 0.0


func _clear_revive_ui() -> void:
	if _revive_circle_node and is_instance_valid(_revive_circle_node):
		_revive_circle_node.visible = false
	if _rez_bar_bg and is_instance_valid(_rez_bar_bg):
		_rez_bar_bg.visible = false
	if _rez_bar_fill and is_instance_valid(_rez_bar_fill):
		_rez_bar_fill.visible = false
	if _interact_prompt and is_instance_valid(_interact_prompt):
		_interact_prompt.visible = false
	rez_fill = 0.0


func _refresh_rez_bar() -> void:
	if _rez_bar_fill and is_instance_valid(_rez_bar_fill):
		_rez_bar_fill.size.x = clamp(rez_fill, 0.0, 1.0) * 48.0


func add_rez_fill(amount: float) -> bool:
	if state != State.DOWNED:
		return false
	rez_fill = min(1.0, rez_fill + amount)
	_refresh_rez_bar()
	return rez_fill >= 1.0


func get_rez_fill() -> float:
	return rez_fill


# ============================================================
# Chi
# ============================================================

func _add_chi(amount: int) -> void:
	# Run 139 — central Chi-gain scaling for Bea: Cold Waters halving (taker
	# only; was missing on Bea entirely) + Poison Apple conversion bonus.
	if amount > 0:
		var _chi_mult: float = 0.5 if RunState.bea_has("corrupt_watermelon") else 1.0
		_chi_mult *= (1.0 + RunState.get_poison_apple_conversion_pct("bea"))
		amount = max(1, int(round(float(amount) * _chi_mult)))
	# Batch 0 ROT-7 — cap honors max-chi boons (was raw MAX_CHI).
	current_chi = min(get_effective_max_chi(), current_chi + amount)
	emit_signal("bea_chi_changed", current_chi, get_effective_max_chi())


# Run 150 — parity shim (Bruno fix 1): Kunai.gd and other projectiles route
# landed hits through `_on_hit_connected` on their owner. Player.gd defines it,
# but Bea never did — the callers' has_method() guard silently skipped her, so
# her RANGED hits built no combo and no chi. Chi routes through _add_chi (which
# applies Cold Waters / Poison Apple scaling); combo through _bump_combo.
func _on_hit_connected(dmg: int) -> void:
	_add_chi(int(CHI_PER_DAMAGE_DEALT * float(dmg)))
	_bump_combo()


# ============================================================
# RunState integration (boons + carry across arena transitions)
# ============================================================

# -------------------------------------------------------
# Boon tick mirrors (Layered Defense, Hydration, Iron Will, Critical Mass,
# Peel Out, Hot-Footed). These mirror Player.gd implementations for Bea.
# -------------------------------------------------------
var _layered_defense_tick: float = 0.0
const LAYERED_DEFENSE_RADIUS: float = 192.0
const LAYERED_DEFENSE_INTERVAL: float = 1.0

var _hydration_combat_timer: float = 0.0
var _hydration_tick_accum: float = 0.0
const HYDRATION_BASE_RATE: float = 0.5
const HYDRATION_RAMP_RATE: float = 1.5
const HYDRATION_RAMP_TIME: float = 8.0

# _iron_will_ready, _iron_will_cd_timer moved to HeroBase (Batch 3).

var _critical_mass_stacks: int = 0
var _critical_mass_timer: float = 0.0

# Combat Fury (Broccoli) — Bea's own consecutive-hit tier tracker.
var _combat_fury_tier: int = 0
var _combat_fury_decay_timer: float = 0.0

var _peel_out_timer: float = 0.0
var _hot_footed_timer: float = 0.0
var _zip_dash_ms_timer: float = 0.0
# Run 27b — Ingrained (standing-still) system + on-absorb duo ICDs (Bea-side).
# _ingrained_time moved to HeroBase (Batch 3).
var _ingrained_last_pos: Vector2 = Vector2.ZERO
var _deep_roots_timer: float = 0.0
var _bunker_timer: float = 0.0
var _hot_shell_icd: float = 0.0
var _smokestack_icd: float = 0.0
# _peel_resto_icd, _candy_apple_bonus moved to HeroBase (Batch 3).
var _candy_apple_decay: float = 0.0  # decays 1/min while out of combat
# Run 60 — Tremor Walk (Potato passive) Bea-side: cracked-earth trail on movement.
var _tremor_walk_timer: float = 0.0
var _tremor_walk_last_pos: Vector2 = Vector2.ZERO
# Run 60 — Scorched Earth (Pepper+Potato duo) Bea-side: persistent lava patch.
var _scorched_earth_timer: float = 0.0
# Run 60 — Hot Step (Banana+Pepper duo) Bea-side: burning trail on dash.
var _hot_step_timer: float = 0.0
var _hot_step_last_pos: Vector2 = Vector2.ZERO
var _heirloom_timer: float = 0.0     # Run 27e — Heirloom follower regen (1 HP/2s)
var _no_attack_timer: float = 0.0    # Run 27f — Drawn Bow pause tracker
var _static_charge_count: int = 0    # Run 27f — Static Charge (Bea ranged)
# Run 59 — Pyromania (Pepper passive) consecutive-hit Burn streak (Bea).
var _pyromania_streak: int = 0
var _pyromania_last_hit: float = -10.0
const HOT_FOOTED_SPEED_BONUS: float = 0.30
const HOT_FOOTED_DURATION: float = 3.0


func _tick_layered_defense(delta: float) -> void:
	if not RunState.layered_defense_taken or current_hp <= 0:
		return
	_layered_defense_tick -= delta
	if _layered_defense_tick > 0.0:
		return
	_layered_defense_tick = LAYERED_DEFENSE_INTERVAL
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or (e.has_method("is_alive") and not e.is_alive()):
			continue
		if global_position.distance_to(e.global_position) > LAYERED_DEFENSE_RADIUS:
			continue
		var es: Variant = e.get("status") if e.has_method("get") else null
		if es != null and es.has_method("apply"):
			var dur: float = 4.0 * (1.5 if RunState.bea_has("chronic_reek") else 1.0)
			es.apply("poison", dur, 1)


# Run 46 — Dragon Chi (Sensei Z): passive Chi regen. Mirror of Player.gd.
var _sensei_chi_accum: float = 0.0

func _tick_sensei_chi_regen(delta: float) -> void:
	var rate: float = RunState.get_sensei_chi_regen_rate()
	if rate <= 0.0 or current_hp <= 0:
		return
	var cap: int = get_effective_max_chi()
	if current_chi >= cap:
		_sensei_chi_accum = 0.0
		return
	_sensei_chi_accum += rate * delta
	if _sensei_chi_accum >= 1.0:
		var whole: int = int(_sensei_chi_accum)
		_sensei_chi_accum -= float(whole)
		current_chi = min(cap, current_chi + whole)
		emit_signal("bea_chi_changed", current_chi, cap)


func _tick_hydration(delta: float) -> void:
	# Run 150b (Bruno ruling) — holder-only: Bea regens Chi only if SHE picked it.
	if not RunState.bea_has("hydration") or current_hp <= 0:
		_hydration_combat_timer = 0.0
		return
	var in_combat: bool = false
	for e in get_tree().get_nodes_in_group("enemy"):
		if is_instance_valid(e) and (not e.has_method("is_alive") or e.is_alive()):
			if global_position.distance_to(e.global_position) < 480.0:
				in_combat = true
				break
	if in_combat:
		_hydration_combat_timer = min(_hydration_combat_timer + delta, HYDRATION_RAMP_TIME + 1.0)
	else:
		_hydration_combat_timer = max(0.0, _hydration_combat_timer - delta * 2.0)
	if not in_combat or _hydration_combat_timer < 0.1:
		return
	var rate: float = HYDRATION_RAMP_RATE if _hydration_combat_timer >= HYDRATION_RAMP_TIME else HYDRATION_BASE_RATE
	_hydration_tick_accum += rate * delta
	if _hydration_tick_accum >= 1.0:
		var gain: int = int(floor(_hydration_tick_accum))
		_hydration_tick_accum -= float(gain)
		if current_chi < MAX_CHI:
			current_chi = min(MAX_CHI, current_chi + gain)
			emit_signal("bea_chi_changed", current_chi, MAX_CHI)


func _tick_iron_will(delta: float) -> void:
	if not RunState.bea_has("iron_will") or _iron_will_ready:
		return
	_iron_will_cd_timer -= delta
	if _iron_will_cd_timer <= 0.0:
		_iron_will_ready = true


func _tick_critical_mass(delta: float) -> void:
	if not RunState.bea_has("critical_mass") or _critical_mass_stacks <= 0:
		return
	_critical_mass_timer -= delta
	if _critical_mass_timer <= 0.0:
		_critical_mass_stacks = 0


# Run 139 — Bea's own Combat Fury decay (mirrors Player.gd: tier → 0 after
# COMBAT_FURY_DECAY_SEC without a landed hit).
func _tick_combat_fury(delta: float) -> void:
	if not RunState.bea_has("combat_fury") or _combat_fury_decay_timer <= 0.0:
		return
	_combat_fury_decay_timer -= delta
	if _combat_fury_decay_timer <= 0.0:
		_combat_fury_tier = 0


# Run 60 — Bea-side family charge-release dispatches. Mirrors Player.gd's
# Inferno/Flood/Storm/Reek/Quake charge-release behavior at Bea's release
# position. Routes status application & lingering zone visuals through Shino's
# already-loaded helpers (zone visuals share the Run 59 filled-puddle upgrade).
func _bea_apply_family_charge_releases() -> void:
	var pl: Node = _get_shino_player()
	# Inferno Charge (Pepper): scorched patch at Bea's position.
	if RunState.bea_has("inferno_charge") and pl != null and pl.has_method("_spawn_fire_zone"):
		pl._spawn_fire_zone(global_position, 40.0, 4.0)
	# Flood Charge (Watermelon): apply 3 Soaked nearby + lingering wet/chilled zone.
	if RunState.bea_has("flood_charge"):
		_bea_apply_flood_charge()
	# Storm Charge (Banana): knockdown wind or chain-3 electrify burst.
	if RunState.bea_has("storm_charge"):
		_bea_apply_storm_charge()
	# Reek Charge (Onion): 360° gas poison + lingering stink cloud.
	if RunState.bea_has("reek_charge"):
		_bea_apply_reek_charge()
	# Run 150b — Spring Tide duo (Apple+Watermelon): spring puddle at Bea's
	# release position (routed through Shino's shared puddle helper).
	if RunState.apple_watermelon_active() and pl != null and pl.has_method("_spawn_spring_tide_puddle"):
		pl._spawn_spring_tide_puddle(global_position)


func _get_shino_player() -> Node:
	for p in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(p) and p.has_method("_spawn_status_zone"):
			return p
	return null


func _bea_apply_reek_charge() -> void:
	if RunState.bea_has("corrupt_onion"):
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
	var pl: Node = _get_shino_player()
	if pl != null and pl.has_method("_spawn_gas_bookend"):
		pl._spawn_gas_bookend(global_position)
	FX.spawn_burst_particles(global_position, Color(0.60, 0.85, 0.30, 0.9), 16)


func _bea_apply_quake_charge() -> void:
	var radius: float = RunState.QUAKE_CHARGE_RADIUS
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or (e.has_method("is_alive") and not e.is_alive()):
			continue
		if global_position.distance_to(e.global_position) > radius:
			continue
		var ts: Variant = e.get("status") if e.has_method("get") else null
		if ts != null and ts.has_method("apply"):
			ts.apply("stagger", 0.7, 1)
			ts.apply("cracked_soil", 4.0, 1)
	var pl: Node = _get_shino_player()
	if pl != null and pl.has_method("_spawn_status_zone"):
		pl._spawn_status_zone(global_position, radius, 3.0, "cracked_soil", 1, Color(0.55, 0.40, 0.20, 0.55))
	FX.spawn_burst_particles(global_position, Color(0.55, 0.40, 0.20, 0.9), 16)
	FX.screen_shake(FX.SHAKE_HEAVY, FX.SHAKE_DUR_SHORT)
	FX.play_sound("ground_pound", 1.0)


func _bea_apply_flood_charge() -> void:
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
	var zone_col: Color = Color(col.r, col.g, col.b, 0.55)
	var pl: Node = _get_shino_player()
	if pl != null and pl.has_method("_spawn_status_zone"):
		pl._spawn_status_zone(global_position, radius, 3.0, wet_id, 1, zone_col)
	FX.spawn_burst_particles(global_position, col, 14)


func _bea_apply_storm_charge() -> void:
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
				ts.apply("stagger", 0.8, 1)
		hit += 1
	var col: Color = Color(0.60, 0.80, 1.0, 0.85) if RunState.greased_lightning_mode else Color(0.95, 0.90, 0.50, 0.85)
	if hit > 0:
		FX.spawn_burst_particles(global_position, col, 14)


# Run 60 — Bea-side Tremor Walk: drop Cracked Soil patches behind her while
# moving (0.5s cadence) + bigger pulse from her feet every 3s while Ingrained.
# Mirrors Player.gd._tick_tremor_walk. Routes through Shino's _spawn_status_zone
# (any "player"-group node will do — already-loaded scene helper) so both heroes
# share the upgraded visible-fill puddle visual from Run 59.
func _tick_tremor_walk_bea(delta: float) -> void:
	if not RunState.bea_has("tremor_walk"):
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
	# Find any player-group node that exposes _spawn_status_zone (Shino's Player.gd does).
	for _pl in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(_pl) and _pl.has_method("_spawn_status_zone"):
			_pl._spawn_status_zone(global_position, radius, dur, "cracked_soil", 1, Color(0.48, 0.30, 0.12, 0.75))
			break
	FX.spawn_hit_particles(global_position, Color(0.55, 0.40, 0.20, 0.9), 4)


# Run 60 — Bea-side Scorched Earth (Pepper+Potato duo): mirror of Player.gd
# _tick_scorched_earth. Drops paired Burn + Cracked Soil zones underfoot every
# 1s; radius grows while Ingrained.
func _tick_scorched_earth_bea(delta: float) -> void:
	if not RunState.is_duo_active("pepper_potato"):
		return
	if _scorched_earth_timer > 0.0:
		_scorched_earth_timer -= delta
		return
	_scorched_earth_timer = 1.0
	var ingrained: bool = _ingrained_time >= RunState.INGRAINED_THRESHOLD
	var radius: float = 80.0
	if ingrained:
		var growth: float = clamp(_ingrained_time - RunState.INGRAINED_THRESHOLD, 0.0, 3.0)
		radius = 80.0 + 64.0 * (growth / 3.0)
	var pl: Node = _get_shino_player()
	if pl != null and pl.has_method("_spawn_status_zone"):
		pl._spawn_status_zone(global_position, radius, 2.0, "burning",      1, Color(0.95, 0.30, 0.05, 0.80))
		pl._spawn_status_zone(global_position, radius, 2.0, "cracked_soil", 1, Color(0.40, 0.18, 0.05, 0.70))
	FX.spawn_hit_particles(global_position, Color(1.00, 0.45, 0.10, 0.95), 5)


# Run 60 — Bea-side Hot Step (Banana+Pepper duo): burning trail while moving
# fast. Drops a small Burn zone every ~0.4s while in motion. Simple movement
# gate (no dash event hook needed in BeaAI's compact loop).
func _tick_hot_step_bea(delta: float) -> void:
	if not RunState.is_duo_active("banana_pepper"):
		_hot_step_last_pos = global_position
		return
	var moving: bool = global_position.distance_to(_hot_step_last_pos) >= 3.0
	_hot_step_last_pos = global_position
	if _hot_step_timer > 0.0:
		_hot_step_timer -= delta
		return
	if not moving:
		return
	_hot_step_timer = 0.4
	var pl: Node = _get_shino_player()
	if pl != null and pl.has_method("_spawn_status_zone"):
		pl._spawn_status_zone(global_position, 36.0, 1.8, "burning", 1, Color(0.95, 0.45, 0.10, 0.70))
	FX.spawn_hit_particles(global_position, Color(1.00, 0.50, 0.15, 0.85), 3)


func apply_runstate_modifiers() -> void:
	# Re-apply boon-driven max-HP scaling, healing the delta (mirrors Player.gd).
	var new_max: int = get_effective_max_hp()
	var prev_max: int = _last_applied_max_hp if _last_applied_max_hp > 0 else max_hp
	var delta: int = new_max - prev_max
	if delta > 0:
		current_hp = min(new_max, current_hp + delta)
	current_hp = clamp(current_hp, 0, new_max)
	_last_applied_max_hp = new_max
	emit_signal("bea_hp_changed", current_hp, new_max)
	emit_signal("bea_chi_changed", current_chi, MAX_CHI)
	# Refresh dash charges if Extra Banana was just picked (mirrors Player.gd).
	var new_max_ch: int = _get_max_dash_charges()
	if dash_charges > new_max_ch:
		dash_charges = new_max_ch
	elif dash_charges < new_max_ch and dash_cd_timer <= 0.0:
		dash_charges = new_max_ch


func _apply_bea_carry_state() -> void:
	# Hydrate from cached HP/Chi if the previous arena cached one.
	if RunState.bea_carry_hp >= 0:
		current_hp = min(RunState.bea_carry_hp, get_effective_max_hp())
	if RunState.bea_carry_chi >= 0:
		current_chi = min(RunState.bea_carry_chi, MAX_CHI)


func get_effective_max_hp() -> int:
	# Per-character Orchard Bloom bonus (only Bea's picks count for Bea).
	# Pie bonus is shared (both ninjas get it from apply_pie).
	var total_pct: float = RunState.get_orchard_bloom_pct_for("bea") + RunState.get_apple_pie_max_hp_pct()
	total_pct += RunState.sensei_hp_pct   # Run 46 — Vital Core (Sensei Z), now wired
	var raw: float = float(max_hp) * (1.0 + total_pct)
	raw *= RunState.get_iron_core_hp_mult()
	# Run 27f — Poison Apple corrupt: max HP capped at 50.
	if RunState.bea_has("corrupt_apple"):
		return mini(50, int(round(raw)) + _candy_apple_bonus)
	# Run 27d — Candy Apple duo: flat temp max HP bonus (cap +10).
	return int(round(raw)) + _candy_apple_bonus


# ---- DEPRECATED Run 13 — `_try_consume_dd_charge` removed ----
# Per-character DD consumption is gone. DD now fires only on team-down via
# RunState.resolve_team_down → revive_from_dd. This stub preserves the old
# signature in case any external caller still references it; always returns
# false (no-op). Safe to delete in a future cleanup pass.
func _try_consume_dd_charge() -> bool:
	return false


func _tick_dd_hot(delta: float) -> void:
	if _dd_hot_remaining <= 0.0 or _dd_hot_pct_per_sec <= 0.0:
		return
	_dd_hot_remaining -= delta
	var max_hp_eff: int = get_effective_max_hp()
	_dd_hot_accum += float(max_hp_eff) * _dd_hot_pct_per_sec * delta
	if _dd_hot_accum >= 1.0:
		var whole: int = int(floor(_dd_hot_accum))
		_dd_hot_accum -= float(whole)
		current_hp = min(max_hp_eff, current_hp + whole)
		emit_signal("bea_hp_changed", current_hp, max_hp_eff)
	if _dd_hot_remaining <= 0.0:
		_dd_hot_remaining = 0.0
		_dd_hot_accum = 0.0
		_dd_hot_pct_per_sec = 0.0


# ---------------------------------------------------------------------------
# Baked Apple finisher HoT — Run 27 (mirrors Player.gd implementation)
# ---------------------------------------------------------------------------
# Called by _tap_katana when is_finisher == true.
# Starts a 5s / 1 HP-per-sec regen; refreshes on each finisher proc.

func _start_baked_apple_hot() -> void:
	if not RunState.bea_has("baked_apple"):
		return
	_baked_apple_hot_remaining = RunState.BAKED_APPLE_HOT_DURATION
	_baked_apple_hot_accum = 0.0
	# Tiny amber particle ping so the player sees the proc on Bea.
	FX.spawn_hit_particles(global_position + Vector2(0, -20),
		Color(0.95, 0.55, 0.30, 1.0), 3)


func _tick_baked_apple_hot(delta: float) -> void:
	if _baked_apple_hot_remaining <= 0.0:
		return
	var step: float = min(delta, _baked_apple_hot_remaining)
	_baked_apple_hot_remaining -= step
	_baked_apple_hot_accum += step * RunState.BAKED_APPLE_HOT_HP_PER_SEC
	if _baked_apple_hot_accum >= 1.0:
		var whole: int = int(floor(_baked_apple_hot_accum))
		_baked_apple_hot_accum -= float(whole)
		var max_hp_eff: int = get_effective_max_hp()
		if current_hp < max_hp_eff:
			current_hp = min(max_hp_eff, current_hp + whole)
			emit_signal("bea_hp_changed", current_hp, max_hp_eff)


# Sweet Dreams room-clear heal — per-character per §8.1 spec.
# World.gd calls this on each wave clear. Returns heal applied (0 if no-op).
func apply_sweet_dreams_heal() -> int:
	var pct: float = RunState.get_sweet_dreams_heal_pct("bea")
	if pct <= 0.0:
		return 0
	if current_hp <= 0:
		return 0   # downed Bea doesn't auto-revive from room clears (§8.5.2)
	var max_hp_eff: int = get_effective_max_hp()
	var heal: int = max(1, int(round(max_hp_eff * pct)))
	var before: int = current_hp
	current_hp = min(max_hp_eff, current_hp + heal)
	emit_signal("bea_hp_changed", current_hp, max_hp_eff)
	return current_hp - before


# ---------------------------------------------------------------------------
# Evergreen Step — heal 1% max HP on the first hit after a dash (6s CD).
# Call this from any attack path right after dealing damage to a live enemy.
# ---------------------------------------------------------------------------
func _try_evergreen_step_heal() -> void:
	if not _evergreen_step_active:
		return
	_evergreen_step_active = false
	var max_hp_eff: int = get_effective_max_hp()
	var heal: int = max(1, int(round(max_hp_eff * 0.01)))
	current_hp = min(max_hp_eff, current_hp + heal)
	emit_signal("bea_hp_changed", current_hp, max_hp_eff)
	FX.spawn_hit_particles(global_position, Color(0.40, 0.90, 0.50, 0.85), 4)


# ---------------------------------------------------------------------------
# Fall Harvest — charge-attack kills heal 1% max HP (Apple boon, per-Bea).
# Call this from charge-attack hit paths when the target dies.
# ---------------------------------------------------------------------------
func _try_bea_fall_harvest_heal(target: Node) -> void:
	var pct: float = RunState.get_fall_harvest_heal_pct_for("bea")
	if pct <= 0.0:
		return
	if target == null or not is_instance_valid(target):
		return
	if target.has_method("is_alive") and target.is_alive():
		return
	var max_hp_eff: int = get_effective_max_hp()
	var heal: int = max(1, int(round(max_hp_eff * pct)))
	current_hp = min(max_hp_eff, current_hp + heal)
	emit_signal("bea_hp_changed", current_hp, max_hp_eff)
	FX.spawn_hit_particles(global_position, Color(0.55, 0.90, 0.35, 0.85), 5)


func get_current_hp() -> int:
	return current_hp


func get_current_chi() -> int:
	return current_chi


# ============================================================
# Hot-swap glue — called by Player.gd's set_player_controlled.
# Mirror of Player.gd's pattern — toggles AI vs. player-controlled mode.
# ============================================================

# ============================================================
# Run 73 — per-device input routing (local 2-player).
# In 1P these defer to the global Input singleton, so single-player behavior
# is unchanged. In 2P they read ONLY Bea's assigned device via InputRouter.
# ============================================================
func _input_device() -> int:
	return RunState.bea_device

# _act_p/_act_jp/_act_jr/_move_axis/_aim_vec moved to HeroBase (Batch 2).


func set_player_controlled(val: bool) -> void:
	player_controlled = val
	# Guard: never overwrite DOWNED state — the revive pipeline must exit it
	# so the circle / rez bar / modulate get cleaned up properly.
	if state == State.DOWNED:
		_refresh_swap_label()
		return
	if val:
		state = State.PLAYER_CONTROLLED
	else:
		state = State.AI_FOLLOW
		velocity = Vector2.ZERO
		# Cancel any in-progress charge / combo so the AI doesn't fire a stale move
		_y_hold_dur = -1.0
		_x_hold_dur = -1.0
		_a_hold_dur = -1.0
		_charge_windup_timer = 0.0
		_charging_button = ""
		modulate = Color(1.0, 1.0, 1.0, 1.0)
		if _hitfx:
			_hitfx.set_charge(0)
		_hide_weapons()
	_refresh_swap_label()


# ============================================================
# Helper: nearest valid enemy for AI follow tick
# ============================================================

func _get_nearest_enemy() -> Node:
	var best: Node = null
	var best_d: float = INF
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		var d: float = global_position.distance_to(e.global_position)
		if d < best_d:
			best_d = d
			best = e
	return best


# ============================================================
# Run 13 — Revive system (standing partner side, mirrors Player.gd)
# ============================================================
func _tick_revive_attempt(delta: float) -> void:
	# Don't try to revive while we're committed to a non-cancellable move.
	if state == State.BEA_ATTACKING or state == State.BEA_CHARGING or state == State.BEA_CHARGED:
		return
	if state == State.BEA_DIVING or state == State.BEA_WHIRLING or state == State.BEA_FLURRYING or state == State.BEA_ULT_CASTING:
		return
	var downed: Node = _find_downed_partner()
	if downed == null:
		RunState.revive_recall_active = false   # Run 65 — nobody down; drop any recall
		_hide_interact_prompt()
		return
	var dist: float = global_position.distance_to(downed.global_position)
	var in_circle: bool = (dist <= REVIVE_CIRCLE_RADIUS)
	var in_channel_range: bool = (dist <= REVIVE_CHANNEL_RANGE)
	# Player-side channel input
	if player_controlled and in_channel_range and _act_jp("interact"):
		_start_channel_revive(downed)
		return
	# AI heuristic (Run 15) — tier-gated per RunState.ai_helper_tier / GDD §8.5.
	# Tier 1: circle-only (no channel).
	# Tier 2: channel if HP > AI_CHANNEL_HP_T2 AND no enemy in AI_CHANNEL_SAFE_RANGE.
	# Tier 3: channel-prioritize at HP >= AI_CHANNEL_HP_T3; dash-cancel in tick.
	if not player_controlled and in_channel_range:
		var tier: int = RunState.ai_helper_tier
		var max_hp_eff: int  = get_effective_max_hp()
		var hp_pct: float    = float(current_hp) / float(max(1, max_hp_eff))
		var safe_r: float    = RunState.AI_CHANNEL_SAFE_RANGE
		var t2_hp: float     = RunState.AI_CHANNEL_HP_T2
		var t3_hp: float     = RunState.AI_CHANNEL_HP_T3
		var no_enemies_in_safe: bool = (_count_nearby_enemies(safe_r) == 0)
		var should_channel: bool = false
		match tier:
			1:
				should_channel = false
			2:
				should_channel = (hp_pct > t2_hp) and no_enemies_in_safe
			_:
				should_channel = (hp_pct >= t3_hp) and no_enemies_in_safe
		# Run 65 — manual recall overrides the hesitation: come get me NOW.
		if RunState.revive_recall_active:
			should_channel = true
		if should_channel:
			_start_channel_revive(downed)
			return
	# Passive circle fill
	if in_circle:
		var inc: float = REVIVE_CIRCLE_RATE * delta * RunState.get_sensei_revive_mult()   # Run 46 — Sibling Bond
		if downed.has_method("add_rez_fill"):
			var done: bool = downed.add_rez_fill(inc)
			if done and downed.has_method("revive_from_partner"):
				downed.revive_from_partner()
	if player_controlled and in_channel_range:
		_show_interact_prompt(downed)
	else:
		_hide_interact_prompt()


func _start_channel_revive(downed: Node) -> void:
	# Cancel any in-flight combat state.
	_hide_weapons()
	_charging_button = ""
	_charge_windup_timer = 0.0
	_y_hold_dur = -1.0
	_x_hold_dur = -1.0
	_a_hold_dur = -1.0
	state = State.REVIVING
	_channeling_partner = downed
	velocity = Vector2.ZERO
	# Spec: vulnerable during channel.
	is_invulnerable = false
	iframe_timer = 0.0
	FX.play_sound("revive_channel_start", 0.9)
	print("[Bea] Channel-reviving partner...")


func _tick_channel_revive(delta: float) -> void:
	if _channeling_partner == null or not is_instance_valid(_channeling_partner):
		_cancel_channel_revive()
		return
	if not (_channeling_partner.has_method("is_downed") and _channeling_partner.is_downed()):
		_cancel_channel_revive()
		return
	if _act_jp("dash") and dash_cd_timer <= 0.0:
		_cancel_channel_revive()
		_start_dash()
		return
	# Run 15 — Tier-3 AI dash-cancel: if an enemy windup begins inside
	# AI_DASH_CANCEL_RANGE, bail before the strike lands.
	# Run 66 — manual recall (downed player's Q+Q) suppresses the T3+ dash-cancel.
	# Otherwise, when the body is swarmed, "enemy attack imminent" fires every
	# frame and the AI thrashes between REVIVING and AI_FOLLOW — the rez bar never
	# advances and Bea looks frozen on the body (the T5 softlock Bruno hit). A
	# manual recall means "rez me NOW, I accept the risk," so we push the channel
	# through even with enemies adjacent.
	if not player_controlled and RunState.ai_helper_tier >= 3 and dash_cd_timer <= 0.0 \
	and not RunState.revive_recall_active:
		if _ai_enemy_attack_imminent(RunState.AI_DASH_CANCEL_RANGE):
			print("[Bea AI T3] Dash-canceling channel — enemy attack imminent.")
			_cancel_channel_revive()
			_start_dash()
			return
	velocity = Vector2.ZERO
	move_and_slide()
	var inc: float = REVIVE_CHANNEL_RATE * delta * RunState.get_sensei_revive_mult()   # Run 46 — Sibling Bond
	if _channeling_partner.has_method("add_rez_fill"):
		var done: bool = _channeling_partner.add_rez_fill(inc)
		if done:
			if _channeling_partner.has_method("revive_from_partner"):
				_channeling_partner.revive_from_partner()
			_channeling_partner = null
			# Bugfix — return to the correct state for who's driving: a
			# player-controlled Bea was getting stuck in AI_FOLLOW (input
			# ignored until a manual swap reset her state).
			state = State.PLAYER_CONTROLLED if player_controlled else State.AI_FOLLOW
			FX.play_sound("revive_channel_complete", 1.1)


func _cancel_channel_revive() -> void:
	_channeling_partner = null
	state = State.PLAYER_CONTROLLED if player_controlled else State.AI_FOLLOW


# -------------------------------------------------------
# Find a downed partner (checks player + bea groups, excludes self).
# -------------------------------------------------------
func _find_downed_partner() -> Node:
	var pool: Array = []
	for n in get_tree().get_nodes_in_group("player"):
		if n != self:
			pool.append(n)
	for n in get_tree().get_nodes_in_group("bea"):
		if n != self and not pool.has(n):
			pool.append(n)
	for c in pool:
		if not is_instance_valid(c):
			continue
		if c.has_method("is_downed") and c.is_downed():
			return c
	return null


# -------------------------------------------------------
# Interact prompt UI
# -------------------------------------------------------
func _show_interact_prompt(_downed: Node) -> void:
	if _interact_prompt == null:
		_interact_prompt = Label.new()
		_interact_prompt.name = "InteractPrompt"
		_interact_prompt.text = "Press [E] to revive"
		_interact_prompt.add_theme_font_size_override("font_size", 12)
		_interact_prompt.modulate = Color(1.0, 1.0, 0.7, 1.0)
		_interact_prompt.position = Vector2(-50.0, -54.0)
		add_child(_interact_prompt)
	_interact_prompt.visible = true


func _hide_interact_prompt() -> void:
	if _interact_prompt and is_instance_valid(_interact_prompt):
		_interact_prompt.visible = false


# -------------------------------------------------------
# Hulk Smash Legendary — Bea's finisher shockwave (mirrors Shino's).
# -------------------------------------------------------
func _bea_try_hulk_smash(origin: Vector2) -> void:
	if not RunState.bea_has("hulk_smash"):
		return
	var combo_ct: int = _shino.combo_count if (_shino != null and is_instance_valid(_shino)) else 0
	var radius: float = RunState.get_hulk_smash_radius(combo_ct)
	var dmg: int = RunState.get_hulk_smash_damage(combo_ct)
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or not e.has_method("take_damage"):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		if origin.distance_to(e.global_position) > radius:
			continue
		var knockback_dir = (e.global_position - global_position).normalized()
		e.take_damage(dmg, knockback_dir * 300.0)


# -------------------------------------------------------
# Run 132 — slot-boon world effects (Bea mirrors of Player.gd helpers).
# Fired once per finisher/swing to avoid multi-proc through Bea's piercing hits.
# -------------------------------------------------------

# Grape Cluster Strike (Y) / Overhead Crush (X): root all enemies in radius 2s.
func _bea_apply_vinewrap(origin: Vector2, radius: float) -> void:
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


# Potato Spud Stomp (Y finisher): Ground Pound — knock down + Cracked Soil in radius.
func _bea_spawn_ground_pound(origin: Vector2, radius: float) -> void:
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or (e.has_method("is_alive") and not e.is_alive()):
			continue
		if origin.distance_to(e.global_position) > radius:
			continue
		var ts: Variant = e.get("status") if e.has_method("get") else null
		if ts != null and ts.has_method("apply"):
			ts.apply("stagger", 0.7, 1)        # knockdown proxy
			ts.apply("cracked_soil", 4.0, 1)   # residual earth tick
	FX.spawn_burst_particles(origin, Color(0.55, 0.40, 0.20, 0.9), 14)
	FX.screen_shake(FX.SHAKE_MEDIUM, FX.SHAKE_DUR_SHORT)
	FX.play_sound("ground_pound", 0.9)


# Broccoli Brute Force (X / heavy): small earth-shockwave around the swing.
func _bea_spawn_brute_force_shockwave(origin: Vector2) -> void:
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
	FX.spawn_burst_particles(origin, Color(0.45, 0.75, 0.35, 0.85), 10)


# Grape+Potato "Stomp Combo" duo (Bea mirror of Player._spawn_stomp_earth_line):
# Y finisher → cracked-earth line; X finisher → earthspike line (stagger + heavier soil).
func _bea_spawn_stomp_earth_line(origin: Vector2, length: float, is_spike: bool) -> void:
	var step: float = 32.0
	var steps: int = int(length / step)
	var dir: Vector2 = facing.normalized() if facing.length() > 0.01 else Vector2.RIGHT
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
	var line_col: Color = Color(0.55, 0.38, 0.18, 0.85) if not is_spike else Color(0.42, 0.28, 0.12, 0.90)
	FX.spawn_burst_particles(origin + dir * (length * 0.5), line_col, 10)
	if is_spike:
		FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_TINY)


# -------------------------------------------------------
# Utility helpers (mirrors of Player.gd equivalents)
# -------------------------------------------------------
func get_effective_max_chi() -> int:
	return MAX_CHI + RunState.max_chi_bonus


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


# Run 63 — Universal hazard-zone avoidance, reworked from pure radial repulsion
# to STEERING. Given the direction she WANTS to move (toward Shino / a target /
# a gate), this returns a steering vector that:
#   * radially pushes out only when she's actually deep inside a danger ring
#     (so two facing traps don't shove against each other in an open gap), and
#   * tangentially steers AROUND any trap that sits ahead of her heading, on the
#     side that keeps her pointed at the goal — i.e. she rounds the obstacle and
#     threads the gap instead of braking head-on and stalling between two traps.
# The result is NOT normalized; magnitude encodes urgency for the blend/smooth
# step in _handle_ai. Zero vector = nothing to avoid.
func _ai_compute_hazard_push(desired: Vector2) -> Vector2:
	var steer: Vector2 = Vector2.ZERO
	var my_pos: Vector2 = global_position
	var have_dir: bool = desired.length() > 0.001
	var dir: Vector2 = desired.normalized() if have_dir else Vector2.ZERO
	for z in get_tree().get_nodes_in_group("hazard_zone"):
		if not is_instance_valid(z):
			continue
		var zr: float = float(z.get_meta("hazard_radius", 40.0))
		var avoid: float = zr + RunState.AI_HAZARD_AVOID_RADIUS
		var off: Vector2 = my_pos - z.global_position   # points away from the trap
		var d: float = off.length()
		if d < 0.001 or d > avoid:
			continue
		var away: Vector2 = off / d
		var depth: float = 1.0 - (d / avoid)            # 0 at edge → 1 at center
		# Radial: only bites hard when she's well inside the ring (depth^2), so a
		# clear corridor between two traps reads as "safe" rather than "squeezed".
		steer += away * depth * depth
		# Tangential: if the trap is AHEAD of her heading, slide around it.
		if have_dir:
			var toward: Vector2 = -away                 # me → trap
			var ahead: float = dir.dot(toward)          # 1 = trap dead ahead
			if ahead > 0.0:
				var perp: Vector2 = Vector2(-toward.y, toward.x)
				if dir.dot(perp) < 0.0:
					perp = -perp                        # pick the goal-ward side
				# Strong when head-on and close; fades as she clears the trap.
				steer += perp * ahead * (0.5 + depth)
	return steer


# Run 69 — STUCK-ON-WALL escape. Position sensor + tangential detour for solid
# geometry (which the hazard steering above doesn't see). Given the heading she
# WANTS this frame, returns the heading to actually use: normally unchanged, but
# if she's been trying to move while pinned (tiny per-frame displacement) it
# commits a sideways "go around" burst, alternating sides each retry so a wrong
# guess self-corrects. Called once per physics frame, before velocity is set.
func _ai_unstick(heading: Vector2, delta: float) -> Vector2:
	var moved: float = 1.0e9
	if _ai_last_pos != Vector2.ZERO:
		moved = global_position.distance_to(_ai_last_pos)
	_ai_last_pos = global_position
	var wants_move: bool = heading.length() > 0.05

	# Build / decay the "grinding against something" timer.
	if wants_move and moved < AI_STUCK_MIN_STEP:
		_ai_stuck_timer += delta
	else:
		_ai_stuck_timer = maxf(0.0, _ai_stuck_timer - delta * 2.0)

	# Active detour — commit fully to one side for the whole burst (~1s) so she
	# has time to clear a deep corner before we even consider the other side.
	if _ai_unstick_timer > 0.0:
		_ai_unstick_timer -= delta
		if moved >= AI_STUCK_MIN_STEP * 2.5:
			# Moving freely again — escape worked, reset everything.
			_ai_unstick_timer = 0.0
			_ai_stuck_timer = 0.0
			_ai_unstick_fails = 0
			return heading
		if wants_move:
			return _ai_unstick_dir   # fixed escape heading for the burst

	# Burst just ended and she's STILL stuck → flip side and peel harder.
	if _ai_unstick_timer <= 0.0 and _ai_stuck_timer >= AI_STUCK_TIME and wants_move:
		_ai_unstick_side = -_ai_unstick_side          # try the other way round
		_ai_unstick_fails = mini(_ai_unstick_fails + 1, 4)
		_ai_unstick_dir = _ai_make_escape(heading, _ai_unstick_side, _ai_unstick_fails)
		_ai_unstick_timer = AI_UNSTICK_BURST
		_ai_stuck_timer = 0.0
		return _ai_unstick_dir

	return heading


# Build the escape heading: mostly sidestep (perpendicular to the blocked goal),
# blended with a growing BACKWARD bias so she peels off the wall instead of
# re-ramming it. More consecutive failures (deeper pocket) → back away harder.
func _ai_make_escape(heading: Vector2, side: float, fails: int) -> Vector2:
	var fwd: Vector2 = heading.normalized()
	var perp: Vector2 = Vector2(-fwd.y, fwd.x) * side
	var back_bias: float = 0.15 + 0.25 * float(fails - 1)   # f1 -0.15 … f4 -0.90
	var esc: Vector2 = perp - fwd * back_bias
	return esc.normalized() if esc.length() > 0.001 else perp


# Run 91 — Should the AI dash THROUGH an inner barrier right now?
# The player can dash across anything in the "dashable_barrier" group (rock slats,
# rivers, logs); the AI never used that to traverse, so she'd stall behind a
# barrier between her and Shino / an enemy. This raycasts straight at her goal:
# if the FIRST thing in the way is a dashable barrier that sits between her and
# the goal, and a dash is ready, she dashes through it. If the first hit is a
# solid wall (or there's nothing in the way), she does NOT dash — _ai_unstick
# handles solid geometry by sidestepping. Returns true if a dash was started.
const AI_DASH_BARRIER_REACH: float = 96.0   # ~ one dash length (950px * 0.09s ≈ 86px) + margin
func _ai_try_dash_through_barrier(goal_dir: Vector2, goal_dist: float) -> bool:
	if player_controlled:
		return false
	if state != State.AI_FOLLOW:
		return false
	if dash_cd_timer > 0.0 or dash_charges <= 0:
		return false
	if goal_dir.length() < 0.01:
		return false
	var dir: Vector2 = goal_dir.normalized()
	# Don't bother if the goal is basically on top of her.
	if goal_dist < 24.0:
		return false
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
	# A dashable barrier is directly between her and the goal: phase through it.
	facing = dir                    # _start_dash uses facing when there's no input
	print("[Bea AI] Dashing through barrier to reach goal.")
	_start_dash()
	return true


# Run 61 — Charge attempts must be "safe to channel": no enemies in the
# AI_CHARGE_SAFE_RANGE radius AND no incoming attacks imminent. Used by
# Tier 2/3 sparingly and Tier 4/5 freely.
func _ai_safe_to_charge() -> bool:
	if _count_nearby_enemies(RunState.AI_CHARGE_SAFE_RANGE) > 0:
		return false
	if _ai_enemy_attack_imminent(RunState.AI_CHARGE_SAFE_RANGE):
		return false
	# Don't try to charge while already in a special state.
	if state != State.AI_FOLLOW:
		return false
	return true


# Run 61 — AI-driven charge release. Picks Y / X / A based on the current
# fight: a target in melee → Y (Katana Whirl), target far → A (Shuriken
# Flurry), default → Y (Katana Whirl). Routes through the same start_*
# entry points the player kit uses, so all VFX + boon dispatches fire.
func _ai_try_release_charge(aim: Vector2) -> void:
	var target: Node = _get_nearest_enemy()
	var d: float = 1.0e9
	if target != null and is_instance_valid(target):
		d = global_position.distance_to(target.global_position)
	# Set facing to aim before firing.
	facing = aim
	# Pick the charge release by range bucket. Close → Katana Whirl (vortex),
	# far → Shuriken Flurry, fallback → Katana Whirl.
	if d <= 220.0 and has_method("_start_katana_whirl"):
		_start_katana_whirl()
	elif has_method("_start_shuriken_flurry"):
		_start_shuriken_flurry()
	elif has_method("_start_katana_whirl"):
		_start_katana_whirl()
	# Run 60 — charge-release family dispatches (Inferno/Flood/etc) fire from
	# each _start_* path's tail via _bea_apply_family_charge_releases().
	if has_method("_bea_apply_family_charge_releases"):
		_bea_apply_family_charge_releases()
