class_name HeroBase
extends CharacterBody2D
# ============================================================
# HeroBase.gd — Batch 1 of the architecture refactor (2026-07-23)
# ============================================================
# Shared base for the two playable heroes:
#   Player.gd (Shino)  and  BeaAI.gd (Bea)
# Both extend this class BY PATH (extends "res://scripts/HeroBase.gd")
# so no global-class-cache scan is required for a correct first load.
#
# Extraction plan: shared functions/vars migrate here batch-by-batch per
# Hero_Diff_Map.md §7 (project root docs folder). Rules:
#   - A function moves here ONLY when its behavior is verified identical
#     (or made identical) in both heroes, and every var/const it touches
#     either moves with it or already lives here.
#   - Hero-specific values become vars set by the child in _init/_ready
#     (e.g. hero_id, sprite scale) — never hardcoded here.
#   - Public API names, signal names, group memberships must NOT change
#     (Wiring_Map.md contracts).
# ============================================================

# --- Hero identity (set by each child before/at _ready) -------------
# "shino" or "bea" — the key used across RunState per-hero gating
# (shino_has/bea_has, get_*_for(hero_id), etc.).
var hero_id: String = ""

# --- Frost / chill status (shared; Run 92 slippery-ice + frost stacks) -----
# Stacking movement slow. Each stack shaves FROST_SLOW_PER_STACK off move speed.
const FROST_SLOW_PER_STACK: float = 0.08   # 5 stacks → ×0.60 move speed (40% slow)
var frost_stacks: int = 0


# ============================================================
# Batch 2 extraction (2026-07-23) — shared leaf helpers.
# Migrated verbatim from Player.gd / BeaAI.gd (verified identical).
# Per-hero differences resolved via hero_id or child-overridable stubs.
# ============================================================

# --- Per-device input routing (Run 73, local 2-player) --------------
# _input_device() stays child-implemented (Shino → RunState.shino_device,
# Bea → RunState.bea_device). This neutral stub lets the shared wrappers
# below compile in HeroBase; each child overrides it with its own device.
func _input_device() -> int:
	return 0

func _act_p(action: String) -> bool:
	if RunState.two_player:
		return InputRouter.pressed(_input_device(), action)
	return Input.is_action_pressed(action)

func _act_jp(action: String) -> bool:
	if RunState.two_player:
		return InputRouter.just_pressed(_input_device(), action)
	return Input.is_action_just_pressed(action)

func _act_jr(action: String) -> bool:
	if RunState.two_player:
		return InputRouter.just_released(_input_device(), action)
	return Input.is_action_just_released(action)

func _move_axis() -> Vector2:
	if RunState.two_player:
		return InputRouter.move_vector(_input_device())
	return Vector2(Input.get_axis("move_left", "move_right"), Input.get_axis("move_up", "move_down"))

func _aim_vec() -> Vector2:
	if RunState.two_player:
		return InputRouter.aim_vector(_input_device())
	return Input.get_vector("aim_left", "aim_right", "aim_up", "aim_down")


# --- Slot attack-tint helper (per-hero via hero_id) -----------------
func _fx_col(base: Color, slot: String) -> Color:
	var tint: Color = RunState.get_attack_tint(hero_id, slot)
	if tint.a <= 0.0:
		return base
	var mixed: Color = base.lerp(tint, 0.65)
	mixed.a = base.a
	return mixed


# --- Frost movement multiplier --------------------------------------
func _frost_move_mult() -> float:
	if frost_stacks <= 0:
		return 1.0
	return maxf(0.25, 1.0 - FROST_SLOW_PER_STACK * float(frost_stacks))


# ============================================================
# Batch 3 extraction (2026-07-23) — overshield / heal / status-gate cluster.
# Migrated from Player.gd / BeaAI.gd. Per-hero differences resolved via
# hero_id, child-overridable stubs, and the signal-emit helpers below.
# ============================================================

# --- Shared HP / Chi / overshield state (declarations lifted from both) -----
# current_hp's literal default is overwritten by each child's `current_hp =
# max_hp` at the top of _ready (Shino max 100, Bea max 80), so it is a
# placeholder only. current_chi starts at 0 for both.
var current_hp: int = 100
var current_chi: int = 0
var overshield_charges: int = 0
var _overshield_aura: Node2D = null            # lazy visual halo (Line2D ring)
var _candy_apple_bonus: int = 0                # Run 27d — Candy Apple temp max HP (cap +10)
var _peel_resto_icd: float = 0.0               # Peel Restoration per-hero heal ICD
var _ingrained_time: float = 0.0               # stand-still timer (Ingrained mechanic)
var _iron_will_ready: bool = true              # Iron Will: defy next CC
var _iron_will_cd_timer: float = 0.0
# Run 19 — Shell Cluster mirror-share recursion guard (one flag per hero instance).
var _shell_cluster_mirror_pending: bool = false

# Per-hero external-heal particle FX (Shino defaults here; Bea overrides in _ready).
var _heal_fx_color: Color = Color(0.95, 0.55, 0.20, 1.0)
var _heal_fx_count: int = 6


# --- Child-overridable stubs (per-hero RunState gating / signals / state) ----
# Per-hero boon ownership (Shino → RunState.shino_has, Bea → RunState.bea_has).
func _hero_has(_id: String) -> bool:
	return false

# HP/Chi HUD signals differ per hero (hp_changed vs bea_hp_changed). Each child
# overrides to emit its own signal with (current, effective-max) args.
func _emit_hp_signal() -> void:
	pass

func _emit_chi_signal() -> void:
	pass

# Charge/release state predicates — each hero's State enum is distinct, so the
# charge-state checks are expressed via these child-implemented predicates.
func _in_charge_or_release_state() -> bool:
	return false

func _is_charging_state() -> bool:
	return false

# Effective max HP/Chi — unified in Batch 5 (orchard-bloom + max-chi-bonus math).
# Per-hero gating via hero_id / _hero_has; backing consts (max_hp, MAX_CHI) live
# in the Batch 5 declarations block below.
func get_effective_max_hp() -> int:
	# Per-character Orchard Bloom bonus (only THIS hero's picks count). Pie bonus
	# is shared (both ninjas). Iron Core is a duo boon — remains global.
	var total_pct: float = RunState.get_orchard_bloom_pct_for(hero_id) + RunState.get_apple_pie_max_hp_pct()
	total_pct += RunState.sensei_hp_pct   # Run 46 — Vital Core (Sensei Z)
	var raw: float = float(max_hp) * (1.0 + total_pct)
	raw *= RunState.get_iron_core_hp_mult()
	# Run 27f — Poison Apple corrupt: max HP capped at 50 (hits-remaining counter).
	if _hero_has("corrupt_apple"):
		return mini(50, int(round(raw)) + _candy_apple_bonus)
	# Run 27d — Candy Apple duo: flat temp max HP bonus (cap +10).
	return int(round(raw)) + _candy_apple_bonus

func get_effective_max_chi() -> int:
	return MAX_CHI + RunState.max_chi_bonus


# -------------------------------------------------------
# Status gate (CC-immunity boons) — Run 15+
# -------------------------------------------------------
func can_receive_status(id: String) -> bool:
	var cc_ids: Array = ["bash", "frozen", "root", "stagger", "slippery", "greased"]
	# Hulk Smash: full super-armor during any charge or release state.
	if _hero_has("hulk_smash") and id in cc_ids:
		if _in_charge_or_release_state():
			return false
	# Run 27b — Heavy Stance: stagger immunity while Ingrained (1.5s+ still).
	if _hero_has("heavy_stance") and _ingrained_time >= RunState.INGRAINED_THRESHOLD and id in ["stagger", "bash"]:
		return false
	# Run 27f — Burnout corrupt: 50% chance to fully resist any incoming CC.
	if _hero_has("corrupt_broccoli") and id in cc_ids and randf() < 0.50:
		return false
	# Hard Landing: immune to bash while charging.
	if _hero_has("hard_landing"):
		if id == "bash" and _is_charging_state():
			return false
	# Iron Will: defy next CC every 10s.
	if _hero_has("iron_will") and _iron_will_ready and id in ["bash", "frozen", "root", "stagger"]:
		_iron_will_ready = false
		_iron_will_cd_timer = 10.0
		FX.spawn_hit_particles(global_position, Color(0.25, 0.70, 0.25, 0.90), 8)
		FX.play_sound("iron_will_proc", 0.85)
		return false
	return true


# -------------------------------------------------------
# Coconut Overshield helpers (Run 15/19)
# -------------------------------------------------------
# Run 19 — Shell Cluster mirror-share. When one hero gains an overshield, the
# OTHER hero also gains 1 (capped by their overshield cap). Recursion guard via
# _shell_cluster_mirror_pending. Shino mirrors to the "bea" group; Bea mirrors
# to the "player" group (self-excluded → Shino).
func _shell_cluster_mirror_share() -> void:
	if not RunState.shell_cluster_active():
		return
	if _shell_cluster_mirror_pending:
		return
	_shell_cluster_mirror_pending = true
	var partner_group: String = "bea" if hero_id == "shino" else "player"
	for other in get_tree().get_nodes_in_group(partner_group):
		if other == self:
			continue
		if other.has_method("grant_overshield_external"):
			other.grant_overshield_external(1)
	_shell_cluster_mirror_pending = false


# Run 23 — external heal hook (Apple Juice / co-op heals). Safe for downed
# state (returns early if current_hp <= 0).
func heal_external(amount: int) -> void:
	# Run 27f — Poison Apple corrupt: ALL healing blocked.
	if _hero_has("corrupt_apple"):
		return
	# Run 129 — Cold Waters corrupt: HP regen/heals halved (doc §6.3 arm).
	if _hero_has("corrupt_watermelon") and amount > 0:
		amount = max(1, int(ceil(float(amount) * 0.5)))
	amount = max(1, int(round(float(amount) * RunState.get_heal_mult(hero_id)))) if amount > 0 else amount
	if amount <= 0:
		return
	if current_hp <= 0:
		return
	current_hp = min(get_effective_max_hp(), current_hp + amount)
	_emit_hp_signal()
	FX.spawn_hit_particles(global_position, _heal_fx_color, _heal_fx_count)


# Run 19 — external overshield grant (Shell Cluster mirror + future hooks).
func grant_overshield_external(amount: int) -> void:
	if amount <= 0:
		return
	# Run 27f — Cracked Shell corrupt: overshell generation disabled entirely.
	if _hero_has("corrupt_coconut"):
		return
	# Run 27d — Bunker duo cap arm: +1 overshield cap while the duo is active.
	var cap: int = max(1, RunState.get_overshield_max(hero_id) + (1 if RunState.is_duo_active("coconut_potato") else 0))   # Run 150b — per-hero cap
	# Run 27d — Candy Apple duo (Apple+Coconut): overshields gained at full HP
	# convert into +1 temp max HP (cap +10), decaying 1/min out of combat.
	if RunState.is_duo_active("apple_coconut") and current_hp >= get_effective_max_hp() \
	and _candy_apple_bonus < 10:
		_candy_apple_bonus += 1
		_emit_hp_signal()
		FX.spawn_hit_particles(global_position, Color(0.95, 0.45, 0.45, 0.9), 5)
	var new_total: int = min(cap, overshield_charges + amount)
	if new_total > overshield_charges:
		overshield_charges = new_total
		_refresh_overshield_aura()
		FX.play_sound("overshield_gain", 0.7)


# Run 27f — Tears of Restoration (Onion passive): Chi siphon from Poison ticks.
func gain_chi_external(amount: int) -> void:
	if amount <= 0:
		return
	current_chi = min(get_effective_max_chi(), current_chi + amount)
	_emit_chi_signal()


# Run 27d — Peel Restoration duo (Apple+Banana): an enemy slip-fall heals this
# hero 1 HP (1.5s ICD per hero). Called by the slipping enemy's StatusComponent.
func peel_restoration_slip_credit() -> void:
	if _peel_resto_icd <= 0.0:
		_peel_resto_icd = 1.5
		heal_external(1)


# Nutshell (Coconut CC identity) — on overshield break, briefly Bash all nearby
# enemies. Shellburst (Run 44) adds flat rarity-scaled damage when this hero owns
# the boon (the Slip 'n Shell duo reuses the shockwave but stays CC-only).
func _fire_nutshell_shockwave() -> void:
	var radius: float = RunState.NUTSHELL_RADIUS
	var bash_dur: float = RunState.NUTSHELL_BASH_DURATION
	var burst_dmg: int = RunState.get_shellburst_damage() if _hero_has("nutshell") else 0
	var hit_count: int = 0
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		if global_position.distance_to(e.global_position) > radius:
			continue
		if burst_dmg > 0 and e.has_method("take_damage"):
			e.take_damage(burst_dmg, (e.global_position - global_position).normalized() * 90.0)
		# Apply Bash via status if available (skips bosses' super-armor).
		var es: Variant = e.get("status") if e.has_method("get") else null
		if es != null and es.has_method("apply"):
			es.apply("bash", bash_dur)
			hit_count += 1
	FX.spawn_burst_particles(global_position, Color(0.95, 0.80, 0.40, 1.0), 20)
	print("[%s] Shellburst shockwave: %d enemies bashed (%d dmg each) in %.0fpx." % [hero_id, hit_count, burst_dmg, radius])


func _refresh_overshield_aura() -> void:
	# Lightweight visual: a thin tan/brown ring that brightens with charge count.
	if _overshield_aura == null:
		var ring := Line2D.new()
		ring.name = "OvershieldAura"
		ring.width = 3.0
		ring.default_color = Color(0.85, 0.65, 0.30, 0.95)
		var pts: PackedVector2Array = []
		var n := 28
		var r: float = 26.0
		for i in range(n + 1):
			var a: float = TAU * float(i) / float(n)
			pts.append(Vector2(cos(a), sin(a)) * r)
		ring.points = pts
		ring.z_index = 5
		add_child(ring)
		_overshield_aura = ring
	if _overshield_aura is Line2D:
		_overshield_aura.visible = (overshield_charges > 0)
		# Color intensity ramps with charges held.
		var t: float = clamp(float(overshield_charges) / float(max(1, RunState.get_overshield_max(hero_id))), 0.0, 1.0)
		(_overshield_aura as Line2D).default_color = Color(0.85, 0.65, 0.30, 0.55 + 0.40 * t)
		(_overshield_aura as Line2D).width = 2.0 + 1.5 * t


# Coconut Shell Breaker (Run 15) — X (secondary) attacks roll to apply Vulnerable
# (+25% dmg taken / 5s, stacks via StatusComponent's "stack" policy).
func _try_apply_shell_breaker(target: Node) -> bool:
	if RunState.shell_breaker_chance <= 0.0:
		return false
	if randf() >= RunState.shell_breaker_chance:
		return false
	var ts: Variant = target.get("status") if target.has_method("get") else null
	if ts != null and ts.has_method("apply"):
		ts.apply("vulnerable", RunState.SHELL_BREAKER_VULN_DUR, 1)
		FX.play_sound("shell_breaker_crack", 0.85)
		FX.spawn_hit_particles(target.global_position, Color(0.95, 0.30, 0.85, 1.0), 8)
		return true
	return false


# ============================================================
# Batch 4 extraction (2026-07-23) — health / downed / revive / DD cluster.
# The contract-critical batch. Per-hero differences resolved via hero_id, the
# child-overridable state predicates/setters below, per-hero FX/config vars set
# in each child's _ready, and a few kit/AI method stubs (overridden per child).
#
# HARD LOCKS preserved byte-for-byte:
#   - A downed body takes ZERO damage (guarded twice: state + is_invulnerable).
#   - `last_damager` kill-attribution is untouched (set at hit sites, not here).
# ============================================================

# --- Combat/dash/i-frame state (declarations lifted from both children) ------
var dash_cd_timer: float = 0.0
var iframe_timer: float = 0.0
var is_invulnerable: bool = false
var _drupe_invuln_timer: float = 0.0   # Run 128 — Drupe Guard post-hit invuln window
var _ghost_stealthed: bool = false     # Run 130 — Ghost Pepper vanish state
var _hit_knockback_vel: Vector2 = Vector2.ZERO
var status: StatusComponent = null     # Bash/Vulnerable/etc. — created in each child's _ready
# body_anim resolves the "Body" child (BodyAnimator, Run 9) on both hero scenes.
@onready var body_anim: Node = get_node_or_null("Body")
var _hitfx: HeroHitFX = null           # HeroHitFX overlay — created in each child's _ready
# Control assignment. Base default = player-controlled (Shino). Bea flips this to
# false in her _ready (she spawns as the AI partner). Read only after _ready.
var player_controlled: bool = true

# --- Downed / revive state (Run 13 rework — shared mirrors) ------------------
const REVIVE_CIRCLE_RADIUS:    float = 90.0    # standing-in-circle slow revive zone
const REVIVE_CHANNEL_RANGE:    float = 40.0    # touching/adjacent — interact channel range
const REVIVE_CIRCLE_RATE:      float = 1.0 / 6.0   # full rez over 6s in circle (base rate)
const REVIVE_CHANNEL_RATE:     float = 1.0 / 3.0   # full rez over 3s on channel (2x speed)
const REVIVE_AT_HP_PCT:        float = 0.28    # partner rez brings downed back at ~28%
const REVIVE_IFRAME_ON_GET_UP: float = 0.8     # brief i-frames after rez
var rez_fill: float = 0.0                       # 0..1; only relevant while DOWNED
var _channeling_partner: Node = null            # who we're reviving (their downed node)
var _revive_circle_node: Node2D = null          # ground-ring shown around downed body
var _rez_bar_bg:         ColorRect = null
var _rez_bar_fill:       ColorRect = null
var _interact_prompt:    Label = null           # "Press [E] to revive" prompt
# DD (Deadly Dream) team-revive HoT accumulator.
var _dd_hot_pct_per_sec: float = 0.0
var _dd_hot_remaining:   float = 0.0
var _dd_hot_accum:       float = 0.0             # fractional HP accumulator between applies

# --- Per-hero FX/config (Shino defaults here; Bea overrides in her _ready) ----
# take_damage hurt cue.
var _hurt_fx_color: Color = Color(1.0, 0.25, 0.25, 1.0)
var _hurt_fx_count: int = 10
var _hurt_sound: String = "player_hurt"
# _enter_downed_state cue + dimmed body tint.
var _downed_modulate: Color = Color(0.45, 0.45, 0.45, 0.85)
var _downed_fx_color: Color = Color(0.65, 0.10, 0.10, 1.0)
var _downed_fx_count: int = 14
var _downed_sound: String = "player_downed"
var _downed_sound_pitch: float = 1.1


# --- Child-overridable state predicates / setters ---------------------------
# Both hero State enums contain DOWNED and REVIVING, and Bea additionally has a
# DEAD state + AI_FOLLOW/PLAYER_CONTROLLED control states. Base code cannot name
# State.X, so all state reads/writes route through these. Base impls are neutral;
# each child overrides with its own enum.
func _is_state_downed() -> bool:
	return false

func _is_state_dead() -> bool:
	return false   # Shino has no DEAD state; Bea overrides.

func _set_state_downed() -> void:
	pass

func _set_state_reviving() -> void:
	pass

# Neutral / resume state after a revive or channel-cancel. Shino → IDLE; Bea →
# PLAYER_CONTROLLED or AI_FOLLOW depending on who's driving (stuck-after-rez fix).
func _set_state_neutral() -> void:
	pass

# _tick_revive_attempt bail-out: the per-hero set of non-cancellable states.
func _revive_attempt_locked() -> bool:
	return false


# --- Child-overridable kit/AI hooks (real impls live in the children) --------
# Overshield absorb (Batch-3-skipped kit drift: Adamantium). Real per child.
func _consume_overshield() -> bool:
	return false

# Rampart (Potato passive) wall spawn. Shino spawns directly; Bea routes through
# a "player"-group member (she owns no wall spawner). Each computes its own facing.
func _spawn_rampart_wall_routed() -> void:
	pass

# Chi gained from taking damage. Shino applies Cold-Waters/Poison-Apple inline;
# Bea routes through _add_chi (which applies the same mults). Emits its chi signal.
func _gain_chi_from_damage_taken(_adjusted: int) -> void:
	pass

# Per-hero combat-state teardown when entering DOWNED / starting a channel-rez.
func _cleanup_combat_on_downed() -> void:
	pass

func _cleanup_combat_on_channel_start() -> void:
	pass

# AI helpers (real impls slated for a later AI batch; stubbed so the revive
# functions resolve in base scope — always overridden, base never runs).
func _count_nearby_enemies(_radius: float) -> int:
	return 0

func _ai_enemy_attack_imminent(_range: float) -> bool:
	return false

func _start_dash() -> void:
	pass


# -------------------------------------------------------
# take_damage — the single damage sink for both heroes (Run 13 downed rework).
# -------------------------------------------------------
func take_damage(amount: int, knockback_vector: Vector2 = Vector2.ZERO, source: String = "enemy") -> void:
	# Bea has a DEAD state Shino lacks; base predicate returns false for Shino.
	if _is_state_dead():
		return
	# A downed body is never a valid target — HARD LOCK (zero damage while downed).
	# Belt-and-suspenders with is_invulnerable set in _enter_downed_state.
	if _is_state_downed():
		return
	if is_invulnerable:
		return   # Dash i-frames active
	# Run 128 — Drupe Guard (Coconut Legendary): active invuln window.
	if _drupe_invuln_timer > 0.0:
		return
	# Run 130 — Ghost Pepper: while vanished, direct enemy hits can't find you
	# (lava/poison ground hazards still connect per doc).
	if _ghost_stealthed and source == "enemy":
		return
	# Coconut Overshield — absorb the entire hit if a charge is held. Charge
	# breaks → Nutshell shockwave (if taken). Damage is fully negated.
	if amount > 0 and _consume_overshield():
		return
	# Run 128 — Drupe Guard proc: the triggering hit lands, then 1.5s of full
	# invulnerability (10s CD, -2s per level — handled in RunState).
	var _drupe_dur: float = RunState.try_drupe_guard(hero_id)
	if _drupe_dur > 0.0:
		_drupe_invuln_timer = _drupe_dur
		FX.spawn_burst_particles(global_position, Color(0.90, 0.75, 0.40, 0.95), 16)
	_hit_knockback_vel = (_hit_knockback_vel + knockback_vector).limit_length(400.0)
	# Boon-driven damage reduction (Tough Shell, etc.) + status amplification
	# (Vulnerable stacks — Batch 0 ROT-1 gave Bea parity here).
	var status_mult: float = 1.0
	if status:
		status_mult = status.get_damage_taken_mult()
	# Green Rage <25% HP tier: -25% damage taken (Combat_Boons §8.3 passive 1).
	var gr_dr: float = RunState.get_green_rage_dr(float(current_hp) / max(1.0, float(get_effective_max_hp())), hero_id)
	var adjusted: int = int(round(amount * RunState.get_damage_taken_mult_for(hero_id) * status_mult * gr_dr))
	if adjusted < 1 and amount > 0:
		adjusted = 1   # never reduce a real hit below 1 dmg
	# Chip-Proof — no single hit may remove more than 15% max HP.
	adjusted = RunState.chip_proof_cap(adjusted, get_effective_max_hp(), hero_id)
	# Run 27f — Poison Apple corrupt: ALL damage = exactly 1 HP per hit.
	if _hero_has("corrupt_apple"):
		adjusted = 1
	# Run 27f — Rampart (Potato passive): 20% chance on damage taken to raise a
	# rock wall (Shino spawns directly; Bea routes through the wall spawner).
	if _hero_has("rampart") and randf() < 0.20:
		_spawn_rampart_wall_routed()
	# Run 62 — Beast Mode (Tier 5) HP floor. When this hero is the tier-5 AI
	# partner (not player-controlled), clamp HP at the floor: the hit lands
	# (knockback/chi above) but net HP loss stops here, so they never down.
	# Floor is 0 in every other case → normal downable behavior.
	var _bm_floor: int = RunState.beastmode_hp_floor_value(player_controlled, get_effective_max_hp())
	current_hp = max(_bm_floor, current_hp - adjusted)
	# Spineback — 30% chance: retaliatory spike at the nearest enemy only.
	var spike_dmg: int = RunState.spineback_retaliate(adjusted, hero_id)
	if spike_dmg > 0:
		for e in get_tree().get_nodes_in_group("enemy"):
			if not is_instance_valid(e):
				continue
			if e.has_method("take_damage") and global_position.distance_to(e.global_position) < 150.0:
				e.take_damage(spike_dmg, (e.global_position - global_position).normalized())
				FX.spawn_hit_particles(e.global_position, Color(0.65, 0.45, 0.25, 0.9), 4)
				break   # one nearest enemy
	# Run 128 — Shocking Return (Banana passive): 20% when hit — knock down the
	# attacker (nearest-enemy proxy). GL mode: zap + ministun instead.
	if RunState.roll_shocking_return(hero_id):
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
	# Chi gain on taking damage (§8.3.2) — per-hero path (Shino inline cw_mult /
	# Bea via _add_chi). Batch 0 ROT-6/7 made these behavior-identical.
	_gain_chi_from_damage_taken(adjusted)
	_emit_hp_signal()
	# Feel — hit shake + per-hero particles + hurt sound.
	FX.screen_shake(FX.SHAKE_MEDIUM, FX.SHAKE_DUR_SHORT)
	FX.spawn_hit_particles(global_position, _hurt_fx_color, _hurt_fx_count)
	FX.play_sound(_hurt_sound)
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
	# Run 9 — procedural hit-recoil animation on the body wireframe.
	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_anim_state("hit_recoil")
	if current_hp <= 0:
		# Run 13 — individual death enters DOWNED; the partner can revive
		# (circle/channel). DD only fires when BOTH are down with no rez —
		# resolved centrally by RunState.resolve_team_down (see _check_team_down_state).
		_enter_downed_state()


# -------------------------------------------------------
# Downed state + revive system (Run 13 — replaces per-character DD).
# -------------------------------------------------------
func is_downed() -> bool:
	return _is_state_downed()


func _enter_downed_state() -> void:
	if _is_state_downed():
		return   # defensive — take_damage shouldn't fire on a downed body
	print("[%s] knocked down — waiting for revive." % hero_id)
	RunState.notify_downed(hero_id)
	_set_state_downed()
	velocity = Vector2.ZERO
	rez_fill = 0.0
	# Per-hero combat teardown (attack combo / weapons / charge aim-lines).
	_cleanup_combat_on_downed()
	if _hitfx:
		_hitfx.set_charge(0)   # Run 112 — drop charge aura if downed mid-charge
	# Permanent i-frames while down (cleared on revive). HARD LOCK: the downed
	# body can't take damage — only the standing partner is a valid target.
	is_invulnerable = true
	iframe_timer = 999.0
	# Visual: tip the body over via the death pose, dim colors.
	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_anim_state("death")
	modulate = _downed_modulate
	# Build revive UI (circle + rez bar above body).
	_build_revive_ui()
	# Feel cue — softer than full death (it's recoverable).
	FX.spawn_burst_particles(global_position, _downed_fx_color, _downed_fx_count)
	FX.screen_shake(FX.SHAKE_MEDIUM, FX.SHAKE_DUR_MED)
	FX.play_sound(_downed_sound, _downed_sound_pitch)
	# Run 13 — DESIGN: NO auto-swap on KO. The player stays on their downed
	# character; the standing partner keeps fighting and may attempt a revive.
	# Check if both are now down → team-down resolution (DD or Game Over).
	# Defer one frame so a same-tick partner downed-enter completes first.
	call_deferred("_check_team_down_state")


func _check_team_down_state() -> void:
	# Iterate every player+bea group node; if ALL are downed, route to RunState.
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
	# Both down — let RunState decide DD vs. Game Over.
	RunState.resolve_team_down(team)


# Called by RunState.resolve_team_down when DD fires on the team.
# Restores HP, exits DOWNED state, applies all queued payload HoTs.
func revive_from_dd(refill_pct: float, payloads: Array) -> void:
	if not _is_state_downed():
		return   # defensive
	var max_hp_eff: int = get_effective_max_hp()
	current_hp = max(1, int(round(max_hp_eff * refill_pct)))
	_emit_hp_signal()
	# Accumulate HoT contributions from ALL payloads (max strength + max duration).
	var hot_pct: float = 0.0
	var hot_dur: float = 0.0
	for p in payloads:
		var pd: Dictionary = p
		hot_pct = max(hot_pct, float(pd.get("hot_pct_per_sec", 0.0)))
		hot_dur = max(hot_dur, float(pd.get("hot_duration", 0.0)))
	_dd_hot_pct_per_sec = hot_pct
	_dd_hot_remaining   = hot_dur
	_dd_hot_accum       = 0.0
	# Exit downed state with brief get-up i-frames.
	_clear_revive_ui()
	iframe_timer = REVIVE_IFRAME_ON_GET_UP
	is_invulnerable = true
	modulate = Color(1.0, 1.0, 1.0, 1.0)
	_set_state_neutral()
	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_anim_state("idle")
	FX.screen_shake(FX.SHAKE_HEAVY, FX.SHAKE_DUR_MED)
	FX.spawn_burst_particles(global_position, Color(1.0, 0.55, 0.30, 1.0), 22)
	FX.play_sound("dd_revive", 1.2)
	print("[%s] DD team-revive — back at %d/%d HP, HoT %.1f%%/s for %.1fs (payloads=%d)." % [
		hero_id, current_hp, max_hp_eff,
		_dd_hot_pct_per_sec * 100.0, _dd_hot_remaining, payloads.size(),
	])


# Called by the standing partner when their rez bar fills 100%.
func revive_from_partner() -> void:
	if not _is_state_downed():
		return
	# Run 27f — Avalanche Aid (Potato passive, team-wide): a completed revive
	# drops 3 boulders on enemies within ~200px of the revive spot.
	if RunState.shino_has("avalanche_aid") or RunState.bea_has("avalanche_aid"):
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
	var max_hp_eff: int = get_effective_max_hp()
	current_hp = max(1, int(round(max_hp_eff * REVIVE_AT_HP_PCT)))
	_emit_hp_signal()
	_clear_revive_ui()
	iframe_timer = REVIVE_IFRAME_ON_GET_UP
	is_invulnerable = true
	modulate = Color(1.0, 1.0, 1.0, 1.0)
	_set_state_neutral()
	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_anim_state("idle")
	FX.screen_shake(FX.SHAKE_MEDIUM, FX.SHAKE_DUR_MED)
	FX.spawn_burst_particles(global_position, Color(0.6, 1.0, 0.6, 1.0), 16)
	FX.play_sound("partner_revive", 1.0)
	print("[%s] Partner revive — back at %d/%d HP (%.0f%%)." % [
		hero_id, current_hp, max_hp_eff, REVIVE_AT_HP_PCT * 100.0,
	])


# -------------------------------------------------------
# Revive UI helpers (revive circle around downed body + rez bar above body).
# Lightweight — single Line2D ring + 2 ColorRects. Created lazily.
# -------------------------------------------------------
func _build_revive_ui() -> void:
	if _revive_circle_node == null:
		_revive_circle_node = Node2D.new()
		_revive_circle_node.name = "ReviveCircle"
		_revive_circle_node.z_index = -1   # under the body sprite
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
	# Called by the standing partner via add_rez_fill — update the bar above the
	# downed body.
	if _rez_bar_fill and is_instance_valid(_rez_bar_fill):
		_rez_bar_fill.size.x = clamp(rez_fill, 0.0, 1.0) * 48.0


# Called by the standing partner each physics frame they're inside our circle.
# Returns true if the bar just filled to 100% (caller fires revive_from_partner).
func add_rez_fill(amount: float) -> bool:
	if not _is_state_downed():
		return false
	rez_fill = min(1.0, rez_fill + amount)
	_refresh_rez_bar()
	return rez_fill >= 1.0


func get_rez_fill() -> float:
	return rez_fill


# -------------------------------------------------------
# Revive attempt / channel (runs on the STANDING partner).
# -------------------------------------------------------
func _tick_revive_attempt(delta: float) -> void:
	# Don't try to revive while committed to a non-cancellable move (per-hero set).
	if _revive_attempt_locked():
		return
	var downed: Node = _find_downed_partner()
	if downed == null:
		RunState.revive_recall_active = false   # Run 65 — nobody down; drop any recall
		_hide_interact_prompt()
		return
	var dist: float = global_position.distance_to(downed.global_position)
	var in_circle: bool = (dist <= REVIVE_CIRCLE_RADIUS)
	var in_channel_range: bool = (dist <= REVIVE_CHANNEL_RANGE)
	if player_controlled and in_channel_range and _act_jp("interact"):
		_start_channel_revive(downed)
		return
	# AI heuristic (Run 15) — tier-gated per RunState.ai_helper_tier / GDD §8.5.
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
	_cleanup_combat_on_channel_start()
	_set_state_reviving()
	_channeling_partner = downed
	velocity = Vector2.ZERO
	# Spec: vulnerable during channel.
	is_invulnerable = false
	iframe_timer = 0.0
	FX.play_sound("revive_channel_start", 0.9)
	print("[%s] Channel-reviving partner..." % hero_id)


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
	# Run 66 — manual recall (downed player's Q+Q) suppresses the T3+ dash-cancel.
	# Otherwise a swarmed body makes "enemy attack imminent" fire every frame and
	# the AI thrashes between REVIVING and neutral — the rez bar never advances
	# (the T5 softlock). A recall means "rez me NOW," so push the channel through.
	if not player_controlled and RunState.ai_helper_tier >= 3 and dash_cd_timer <= 0.0 \
	and not RunState.revive_recall_active:
		if _ai_enemy_attack_imminent(RunState.AI_DASH_CANCEL_RANGE):
			print("[%s AI T3] Dash-canceling channel — enemy attack imminent." % hero_id)
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
			_set_state_neutral()
			FX.play_sound("revive_channel_complete", 1.1)


func _cancel_channel_revive() -> void:
	_channeling_partner = null
	_set_state_neutral()


# -------------------------------------------------------
# Find a downed partner — checks both bea and player groups, excludes self.
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
# Interact prompt UI.
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
# Trivial getters (public API — Wiring_Map §7).
# -------------------------------------------------------
func get_current_hp() -> int:
	return current_hp


func get_current_chi() -> int:
	return current_chi


# ============================================================
# Batch 5 extraction (2026-07-23) — boon ticks / carry-adjacent /
# runstate-modifier cluster (Hero_Diff_Map §7 "Batch 4").
# Migrated from Player.gd / BeaAI.gd (verified identical or cleanly
# parameterized via hero_id / _hero_has / the signal-emit helpers).
# ============================================================

# --- Vars/consts moved here with the Batch 5 functions below ---------------
# max_hp is @export (per-instance in the inspector, though no .tscn overrides it
# today). Base default = Shino's 100; Bea sets `max_hp = 80` early in her _ready,
# before `current_hp = max_hp` — same pattern Batch 4 used for player_controlled.
@export var max_hp: int = 100
const MAX_CHI: int = 100                         # identical on both heroes
var _last_applied_max_hp: int = -1               # sentinel; both heroes fall to max_hp on first apply
var dash_charges: int = 1                        # current available dashes (Extra Banana raises max)
# Frost (Popsicle Pelican) — the remaining consts (FROST_SLOW_PER_STACK/frost_stacks
# landed in Batch 2). Decay timer read by each child's _tick_timers frost loop.
const FROST_MAX_STACKS: int    = 5
const FROST_STACK_DECAY: float = 1.4             # seconds before one stack melts off
const FROST_OUTLINE_HOLD: float = 1.2            # icy outline refresh window
var _frost_decay_t: float = 0.0
# Dragon Chi (Sensei Z) fractional accumulator.
var _sensei_chi_accum: float = 0.0


# Max dash charges — real per-hero impl (Extra Banana + duo charges) lives in each
# child and overrides this; the base stub only lets apply_runstate_modifiers resolve.
func _get_max_dash_charges() -> int:
	return dash_charges


# Coconut Bash — chance per melee hit to apply Bash (1s stun) to the target and
# grant the caller flat bonus damage. Target must expose a status component.
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


# Trap poison tick FX (swamp bite-traps). A downed / i-framed hero is untouched.
func apply_trap_poison() -> void:
	if _is_state_downed():
		return
	if is_invulnerable:
		return
	if _hitfx:
		_hitfx.start_poison()


# Frost (Popsicle Pelican) — add `n` frost stacks (capped), refreshing the decay
# timer + icy outline. Downed / i-framed hero untouched. Frost only slows.
func add_frost_stack(n: int = 1) -> void:
	if _is_state_downed() or is_invulnerable:
		return
	frost_stacks = clampi(frost_stacks + n, 0, FROST_MAX_STACKS)
	_frost_decay_t = FROST_STACK_DECAY
	if _hitfx:
		_hitfx.start_frost(FROST_OUTLINE_HOLD, float(frost_stacks) / float(FROST_MAX_STACKS))


# DD (Deadly Dream) team-revive HoT — heals a % of max HP/sec for its duration.
# Fractional HP accumulates across frames so small %/s ticks resolve cleanly.
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
		_emit_hp_signal()
	if _dd_hot_remaining <= 0.0:
		_dd_hot_remaining = 0.0
		_dd_hot_accum = 0.0
		_dd_hot_pct_per_sec = 0.0


# Sweet Dreams room-clear heal — heals a flat % of max HP on wave clear if this
# hero owns the boon. Called by World.gd. Returns the heal applied (0 if no-op).
func apply_sweet_dreams_heal() -> int:
	var pct: float = RunState.get_sweet_dreams_heal_pct(hero_id)
	if pct <= 0.0:
		return 0
	if current_hp <= 0:
		return 0   # downed — don't auto-heal corpses (§8.5.2)
	var max_hp_eff: int = get_effective_max_hp()
	var heal: int = max(1, int(round(max_hp_eff * pct)))
	var before: int = current_hp
	current_hp = min(max_hp_eff, current_hp + heal)
	_emit_hp_signal()
	return current_hp - before


# Re-apply boon-driven stat changes that need re-application after a boon pick:
#   - Max HP scaling: heals by the DELTA since the last apply (so each Orchard
#     Bloom pick feels +N rewarding instead of compounding into a free heal).
#   - Refresh dash charges (Extra Banana may have just raised the max).
func apply_runstate_modifiers() -> void:
	var new_max_hp: int = get_effective_max_hp()
	var prev_max_hp: int = _last_applied_max_hp if _last_applied_max_hp > 0 else max_hp
	var delta: int = new_max_hp - prev_max_hp
	if delta > 0:
		current_hp = min(new_max_hp, current_hp + delta)
	current_hp = clamp(current_hp, 0, new_max_hp)
	_last_applied_max_hp = new_max_hp
	_emit_hp_signal()
	_emit_chi_signal()
	var new_max_ch: int = _get_max_dash_charges()
	if dash_charges > new_max_ch:
		dash_charges = new_max_ch
	elif dash_charges < new_max_ch and dash_cd_timer <= 0.0:
		dash_charges = new_max_ch   # fill to new max when not mid-CD recharge


# Dragon Chi (Sensei Z) — passive Chi regen. Fractional Chi accumulates in
# _sensei_chi_accum; whole points bank into current_chi.
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
		_emit_chi_signal()
