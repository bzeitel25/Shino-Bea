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

# Effective max HP/Chi — real implementations live in each child (orchard-bloom
# and max-chi-bonus math). These stubs only satisfy base-scope resolution; they
# are always overridden and never actually run.
func get_effective_max_hp() -> int:
	return current_hp

func get_effective_max_chi() -> int:
	return current_chi


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
