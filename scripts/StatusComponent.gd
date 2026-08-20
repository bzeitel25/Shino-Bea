class_name StatusComponent
extends Node
# ============================================================
# StatusComponent.gd — modular status effect framework
# ============================================================
# Generic system that any entity (Player, Bea, DummyEnemy,
# RangedShooter, FastScout, BossEnemy, etc.) can host as a
# child node.
#
# Usage (host-side):
#   var status: StatusComponent = StatusComponent.new()
#   add_child(status)
#   status.host = self                # back-reference to owner entity
#
#   # Apply
#   status.apply("bash", 1.0)             # 1.0s of Bash
#   status.apply("vulnerable", 5.0, 1)    # 1 stack of Vulnerable for 5s
#   status.apply("wet", 4.0, 1)           # 1 Soaked stack for 4s
#   status.apply("burning", 3.0, 2)       # 2 Burn stacks for 3s
#
#   # Query (in take_damage / movement code)
#   var dmg_mult: float = status.get_damage_taken_mult()
#   if status.is_movement_locked(): velocity = Vector2.ZERO
#   var ms_mult: float  = status.get_move_speed_mult()
#   var as_mult: float  = status.get_attack_speed_mult()
#   var miss: float     = status.get_miss_chance()
#
# Each status definition supplies:
#   - max_stacks (int)
#   - stack_policy ("refresh"|"extend"|"stack")
#   - on_apply(host, stacks) Callable (optional)
#   - on_tick(host, dt, stacks) Callable (optional)
#   - on_expire(host) Callable (optional)
#   - tag flags (movement_lock, action_lock, dot_pct_per_sec_per_stack,
#     damage_taken_amp_per_stack, move_speed_mult_per_stack,
#     attack_speed_mult_per_stack, miss_chance, cap_state, etc.)
#
# Add new statuses by adding entries to STATUS_DEFS at the
# bottom of this file. Boons / enemy attacks call
# `host.status.apply(id, dur)` to inflict them.
#
# ============================================================
# Run 17 — Taxonomy expansion (Combat_Boons v0.28 + tails).
# Added: wet/drenched (Watermelon water), chilled/frozen (Gelato),
# burning (Pepper), poison (Onion), slippery/greased + sparked/bolted
# (Banana modes), shocked (Banana chain), cracked_soil/root (Potato),
# stagger, bleed.
#
# UNIVERSAL RULE — dash always works. action_lock here only signals
# attack/ability blocking; host code (Player.gd / BeaAI.gd) must let
# dash through even when is_action_locked() is true. See _handle_input
# in those files.
# ============================================================

# Active statuses keyed by id. Value dict:
#   { "remaining": float, "stacks": int, "def": Dictionary, "dot_accum": float }
var _active: Dictionary = {}

# Host back-reference — the entity this component is attached to.
# Caller sets this immediately after instancing.
var host: Node = null

# Per-instance Poison-stacks bonus from RunState.poison_max_stacks_bonus
# (Onion Overripe). Read at apply-time.

# Emitted whenever a status is applied, refreshed, or removed.
# Listeners can use this to drive visual indicators.
signal status_changed(id: String, stacks: int, remaining: float)

# ============================================================
# Breakbar (Run 117) — boss/miniboss CC immunity + breakbar
# ============================================================
# Instead of directly applying hard CC (bash, frozen, root, stagger,
# knockback, knockup, slow), bosses/minibosses accumulate breakbar
# damage. When the bar empties the boss enters a BROKEN state (brief
# stun). The bar then refills after a recovery window.
#
# CC weights — harder CC contributes more:
#   bash / frozen / knockup  = 30  (hard stun/lockdown)
#   root / stagger           = 20  (medium: immobilize / interrupt)
#   knockback                = 10  (soft displacement)
#   slow (chilled/cracked)   = 5   (per stack, soft)
#   wet / slippery / greased = 3   (light debuff)
# ============================================================

# Set true by _ready-time auto-detect (host in "boss"/"miniboss" group).
var breakbar_enabled: bool = false

const BREAKBAR_MAX_BOSS: float     = 300.0
const BREAKBAR_MAX_MINIBOSS: float = 180.0
const BREAKBAR_BROKEN_STUN: float  = 3.0   # seconds stunned when bar breaks
const BREAKBAR_REFILL_DELAY: float = 2.0   # seconds after broken stun before bar refills (legacy, unused)
const BREAKBAR_REFILL_RATE: float  = 25.0  # units/sec during refill (legacy, unused)

var breakbar_max: float     = 0.0
var breakbar_current: float = 0.0
var _breakbar_broken: bool  = false
var _breakbar_broken_timer: float = 0.0
var _breakbar_refilling: bool = false
var _breakbar_refill_delay: float = 0.0

# CC weight table — maps status ids + special keys to breakbar contribution.
const BREAKBAR_CC_WEIGHTS: Dictionary = {
	"bash":         30.0,
	"frozen":       30.0,
	"knockup":      30.0,
	"root":         20.0,
	"stagger":      20.0,
	"scalded":      20.0,
	"shattered":    20.0,
	"knockback":    10.0,   # special key, not a status id
	"hitstop":       2.0,   # Run 150 — base-attack punch freeze: tiny chip only
	"chilled":       5.0,   # per stack
	"cracked_soil":  5.0,   # per stack
	"wet":           3.0,   # per stack
	"slippery":      3.0,
	"greased":       3.0,
}

# Statuses that are fully blocked on breakbar hosts (applied as breakbar
# damage instead). Everything NOT in this list passes through normally
# (vulnerable, burning, poison, bleed, etc. still land).
const BREAKBAR_CC_IDS: Array = [
	"bash", "frozen", "root", "stagger", "scalded", "shattered",
	"hitstop",   # Run 150 — never freezes a boss; tiny breakbar chip instead
]

signal breakbar_changed(current: float, max_val: float, is_broken: bool)

# --- Local breakbar visual (above the enemy sprite) ---
var _local_bb_bg: ColorRect = null
var _local_bb_fill: ColorRect = null
const LOCAL_BB_WIDTH: float = 40.0
const LOCAL_BB_HEIGHT: float = 5.0
const LOCAL_BB_OFFSET_Y: float = -60.0   # above the sprite
const BREAKBAR_FILL_COLOR: Color = Color(0.85, 0.75, 0.15, 0.95)   # gold

# --- Visual indicator (Run 17) ---
# Lazy-instanced Label2D that floats above the host showing active
# status icons + stack counts. Disabled if host opts out via meta
# (`set_meta("status_indicator_disabled", true)`).
var _indicator: Label = null
const INDICATOR_OFFSET: Vector2 = Vector2(-26.0, -52.0)


# ============================================================
# Run 55 — Poison / Burning DoT rework (Bruno's interval spec)
# ------------------------------------------------------------
# Both effects now deal FLAT damage on a TIMER instead of a
# continuous %-max-HP drain. The two have deliberately opposite
# identities:
#
#   POISON  — bigger numbers, slow steady cadence. Fixed 3s tick;
#             damage = POISON_TICK_DMG_PER_STACK × stacks. At 5
#             stacks that's a chunky 10 every 3s. Scales hard with
#             investment (more stacks via Overripe/Pom, Chronic
#             Plague, +base via Dragonfruit hooks later).
#
#   BURNING — smaller number, ramps FREQUENCY with stacks ("heat
#             builds"). Flat 5 per tick; interval shrinks from 5s
#             at 1 stack to 1s at 5 stacks. Caps out hot & fast.
#
# DPS @ stacks 1..5:
#   Poison  (2/stack): 0.67, 1.33, 2.0, 2.67, 3.33
#   Burning (5 flat) : 1.0,  1.25, 1.67, 2.5, 5.0
# Burning clearly wins the max-stack payoff (its identity); poison
# is the reliable mid-tier that out-scales with boon investment.
# All four numbers below are single-line tunables.
# ------------------------------------------------------------
const POISON_TICK_DMG_PER_STACK: int = 2     # Bruno's baseline was 1; 2 reads better. 3 = DPS-parity with Burning.
const POISON_TICK_INTERVAL:      float = 3.0 # fixed cadence, every 3s
const BURN_TICK_DMG:             int = 5     # flat per tick
const BURN_INTERVAL_MAX:         float = 5.0 # interval at 1 stack
const BURN_INTERVAL_MIN:         float = 1.0 # interval at 5 stacks
const BURN_INTERVAL_STEP:        float = 1.0 # seconds shaved per extra stack

# Continuous status-aura emit cadence accumulators (Run 55).
var _burn_aura_accum:    float = 0.0
var _poison_bubble_accum: float = 0.0
var _wildfire_accum:     float = 0.0   # Run 128 — Wildfire 2s spread tick
var _bonk_accum:         float = 0.0   # Run 130 — BONK/ZAP 3s punish tick


func _ready() -> void:
	set_process(true)
	# Deferred so the host has finished _ready and joined its groups.
	call_deferred("_auto_detect_breakbar")


# Run 168 — is this component bolted to one of the two ninjas (rather than an
# enemy)? Groups are the source of truth: Shino joins "player"; Bea joins BOTH
# "bea" and "player" (she is added to "player" so door/pickup triggers see her),
# so testing "player" alone covers both heroes and neither enemy.
func _host_is_hero() -> bool:
	if host == null or not is_instance_valid(host):
		return false
	return host.is_in_group("player") or host.is_in_group("bea")


func _auto_detect_breakbar() -> void:
	if host == null or not is_instance_valid(host):
		Log.dbg("[BreakBar] _auto_detect: host is null/invalid")
		return
	var groups: Array = host.get_groups()
	Log.dbg("[BreakBar] _auto_detect on %s — groups: %s" % [host.name, str(groups)])
	if host.is_in_group("boss"):
		breakbar_enabled = true
		breakbar_max = BREAKBAR_MAX_BOSS
		breakbar_current = breakbar_max
	elif host.is_in_group("miniboss"):
		breakbar_enabled = true
		breakbar_max = BREAKBAR_MAX_MINIBOSS
		breakbar_current = breakbar_max
	if breakbar_enabled:
		Log.dbg("[BreakBar] ENABLED on %s — max %.0f" % [host.name, breakbar_max])
		# Route breakbar changes through FX bus so HUD can display the bar.
		breakbar_changed.connect(_on_breakbar_changed_relay)
		# Local breakbar visual bar above the enemy sprite.
		breakbar_changed.connect(_update_local_breakbar_visual)
		_create_local_breakbar_visual()
		# Emit initial state so HUD seeds correctly.
		emit_signal("breakbar_changed", breakbar_current, breakbar_max, false)
	else:
		Log.dbg("[BreakBar] NOT enabled on %s (no boss/miniboss group)" % host.name)


func _on_breakbar_changed_relay(current: float, max_val: float, is_broken: bool) -> void:
	var fx := get_node_or_null("/root/FX")
	if fx and fx.has_method("notify_boss_breakbar"):
		fx.notify_boss_breakbar(current, max_val, is_broken)


func _process(delta: float) -> void:
	# ============================================================
	# Run 168 — FULL STATUS PAUSE FOR HEROES DURING ANY ULT CINEMATIC.
	# ============================================================
	# This component ticks in its OWN _process, completely independently of the
	# host's _physics_process. That independence is why the ult freeze leaked
	# damage: while the frozen partner's _physics_process was early-returning
	# (no movement, no input, no healing, no dodge), THIS loop happily kept
	# rolling burn and poison ticks straight into her HP. Over a ~3s cinematic a
	# survivable stack turned lethal, which is what Bruno saw as "Shino's ult
	# killed Bea".
	#
	# HeroBase.take_damage() already hard-refuses damage during a cinematic, so
	# the DoT could not land anyway — but returning here matters for a second
	# reason: it also stops `remaining` from ticking down. Without that, a hero
	# would silently burn 3 seconds off every one of her debuffs while the
	# camera was busy, so an ult would double as a free cleanse. Freeze means
	# freeze in BOTH directions: no damage out, no duration off.
	#
	# Enemies are deliberately NOT exempted here — they are process-disabled
	# wholesale by UltFreeze, which stops this component along with them.
	if _host_is_hero() and RunState.ult_cinematic_active():
		return
	# --- Breakbar tick (Run 117) ---
	if breakbar_enabled:
		_tick_breakbar(delta)
	if _active.is_empty():
		_hide_indicator_if_empty()
		return
	var to_remove: Array = []
	for id in _active.keys():
		var entry: Dictionary = _active[id]
		entry["remaining"] -= delta
		var def: Dictionary = entry["def"]
		# --- Run 55 — interval DoT for Burning & Poison (flat damage on a timer,
		# replacing the old continuous %-max-HP drain). See _dot_interval /
		# _dot_tick_damage for the per-effect cadence + scaling. ---
		if (id == "burning" or id == "poison") and is_instance_valid(host):
			entry["dot_timer"] = entry.get("dot_timer", 0.0) + delta
			var interval: float = _dot_interval(id, int(entry["stacks"]))
			if entry["dot_timer"] >= interval:
				entry["dot_timer"] -= interval
				var dmg: int = _dot_tick_damage(id, int(entry["stacks"]))
				if dmg > 0:
					_apply_dot_damage(dmg, id)
		# --- Continuous %-max-HP DoT (Bleed + any future pct status). Uses a
		# per-status accumulator so partial HP per frame batches into integer
		# hits (avoids spamming hits-of-zero). ---
		elif def.has("dot_pct_per_sec_per_stack") and is_instance_valid(host):
			var max_hp: float = _host_max_hp()
			if max_hp > 0.0:
				var pct: float = float(def["dot_pct_per_sec_per_stack"]) * float(entry["stacks"])
				# Thunderstruck (corrupt_banana): lightning_damage_mult scales sparked/bolted ticks.
				if id == "sparked" or id == "bolted":
					pct *= RunState.lightning_damage_mult
				var amount: float = max_hp * pct * delta
				entry["dot_accum"] = entry.get("dot_accum", 0.0) + amount
				if entry["dot_accum"] >= 1.0:
					var whole: int = int(floor(entry["dot_accum"]))
					entry["dot_accum"] -= float(whole)
					_apply_dot_damage(whole, id)
		# --- Run 111 — FLAT interval DoT (Bleed): `value` dmg per stack, applied
		# once per second on a per-status timer. Flat (not %-HP) so it stays light. ---
		elif def.has("dot_flat_per_sec_per_stack") and is_instance_valid(host):
			entry["dot_timer"] = entry.get("dot_timer", 0.0) + delta
			if entry["dot_timer"] >= 1.0:
				entry["dot_timer"] -= 1.0
				var fdmg: int = int(def["dot_flat_per_sec_per_stack"]) * int(entry["stacks"])
				if fdmg > 0:
					_apply_dot_damage(fdmg, id)
		# on_tick hook fires every frame the status is active.
		if def.has("on_tick") and def["on_tick"] is Callable:
			(def["on_tick"] as Callable).call(host, delta, entry["stacks"])
		if entry["remaining"] <= 0.0:
			to_remove.append(id)
	# Run 27b — Loose Earth duo (Banana+Potato): while the host has any
	# Banana status, the ground cracks — +1 Cracked Soil per second.
	if RunState.is_duo_active("banana_potato") \
	and (_active.has("slippery") or _active.has("greased") or _active.has("sparked") or _active.has("bolted")):
		_loose_earth_accum += delta
		if _loose_earth_accum >= 1.0:
			_loose_earth_accum -= 1.0
			apply("cracked_soil", 4.0, 1)
	else:
		_loose_earth_accum = 0.0
	# Run 27d — Slippery/Greased slip-and-fall (Combat_Boons §8.9 status spec):
	# Slippery = 10%/sec chance, Greased = 25%/sec → 0.5s prone (stagger).
	if (_active.has("slippery") or _active.has("greased")) and not _active.has("stagger"):
		_slip_roll_accum += delta
		if _slip_roll_accum >= 1.0:
			_slip_roll_accum -= 1.0
			var _slip_chance: float = 0.25 if _active.has("greased") else 0.10
			if randf() < _slip_chance:
				_do_slip_fall()
		# Visual drip — banana-yellow droplets shed while slick. Greased drips
		# bigger/faster than Slippery so intensity reads at a glance.
		_slip_drip_accum += delta
		var _drip_period: float = 0.35 if _active.has("greased") else 0.70
		if _slip_drip_accum >= _drip_period:
			_slip_drip_accum -= _drip_period
			var _drip_col: Color = Color(1.0, 0.92, 0.35, 0.85) if _active.has("greased") \
				else Color(0.95, 0.85, 0.30, 0.65)
			_spawn_status_puff(_drip_col, 2 if _active.has("greased") else 1)
	else:
		_slip_roll_accum = 0.0
		_slip_drip_accum = 0.0
	# Run 27d — Tide Storm duo (Banana+Watermelon) cross-status refreshers:
	# Soaked hosts keep a refreshing Sparked; Chilled hosts a refreshing Slippery.
	if RunState.is_duo_active("banana_watermelon"):
		_tide_storm_accum += delta
		if _tide_storm_accum >= 1.0:
			_tide_storm_accum -= 1.0
			if _active.has("wet") or _active.has("drenched"):
				apply("sparked", 1.2, 1)
			if _active.has("chilled"):
				apply("slippery", 1.2, 1)
	# Run 27e — Sparked/Bolted interval procs (enemies only). Bolted takes
	# precedence when both are present (it's the heavy variant).
	if (_active.has("sparked") or _active.has("bolted")) \
	and is_instance_valid(host) and host.is_in_group("enemy"):
		_zap_proc_accum += delta
		if _zap_proc_accum >= 1.0:
			_zap_proc_accum -= 1.0
			if _active.has("bolted"):
				_do_bolt_strike()
			else:
				_do_spark_chain()
	else:
		_zap_proc_accum = 0.0
	# Run 27e — Scald/Shatter duo (Pepper+Watermelon) build-up: Burning+Soaked
	# grows Steam; Burning+Chilled grows Brittle. 1 stack/sec while both coexist.
	if RunState.is_duo_active("pepper_watermelon") and _active.has("burning"):
		_scald_accum += delta
		if _scald_accum >= 1.0:
			_scald_accum -= 1.0
			if _active.has("wet") or _active.has("drenched"):
				apply("steam", 6.0, 1)
			if _active.has("chilled") or _active.has("frozen"):
				apply("brittle", 6.0, 1)
	else:
		_scald_accum = 0.0
	# Run 55 — continuous Poison-bubble / Burning-aura emitters (visual only).
	_update_status_auras(delta)
	for id in to_remove:
		_expire(id)
	_refresh_indicator()


# -------------------------------------------------------
# Breakbar (Run 117) — tick + contribution + broken state
# -------------------------------------------------------

func _tick_breakbar(delta: float) -> void:
	if _breakbar_broken:
		_breakbar_broken_timer -= delta
		if _breakbar_broken_timer <= 0.0:
			# Broken stun ends → boss stands back up and resumes its normal AI.
			# The bar is RESET TO FULL immediately (not slowly refilled) so it can
			# be broken again in a fresh cycle. A gradual refill left the bar near
			# empty for seconds, and any CC hit landing during that window instantly
			# re-broke it (current <= 0 → _trigger_breakbar_broken again) which read
			# in-game as a permanent stun. Full reset closes that re-break window.
			_breakbar_broken = false
			_breakbar_refilling = false
			breakbar_current = breakbar_max
			# Remove the broken-stun bash (it was applied with the broken duration)
			# so is_movement_locked()/is_action_locked() clear and the AI unfreezes.
			if _active.has("breakbar_broken"):
				_expire("breakbar_broken")
			emit_signal("breakbar_changed", breakbar_current, breakbar_max, false)
		return


# Called when a CC status would be applied but is intercepted by the breakbar.
# Returns true if the CC was consumed (breakbar active), false if it should
# pass through (bar is broken → the broken-stun bash is already on).
func contribute_breakbar(cc_id: String, stacks: int = 1) -> bool:
	if not breakbar_enabled:
		return false
	if _breakbar_broken:
		return true   # bar is broken, CC still doesn't apply directly
	var weight: float = BREAKBAR_CC_WEIGHTS.get(cc_id, 0.0)
	if weight <= 0.0:
		return false   # not a CC status — let it through
	var contribution: float = weight * float(max(1, stacks))
	breakbar_current = maxf(0.0, breakbar_current - contribution)
	emit_signal("breakbar_changed", breakbar_current, breakbar_max, false)
	# Spawn a visual pip at the host so the player sees CC "landing".
	_spawn_breakbar_pip(contribution)
	if breakbar_current <= 0.0:
		_trigger_breakbar_broken()
	return true


# Called externally for knockback (not a status, so it bypasses apply()).
func contribute_breakbar_knockback() -> void:
	contribute_breakbar("knockback", 1)


func _trigger_breakbar_broken() -> void:
	_breakbar_broken = true
	_breakbar_broken_timer = BREAKBAR_BROKEN_STUN
	_breakbar_refilling = false
	breakbar_current = 0.0
	# Apply a special "breakbar_broken" status that acts like bash but with
	# the broken duration. This goes through the raw _active dict, bypassing
	# can_receive_status (the whole point is to stun them).
	var bash_def: Dictionary = STATUS_DEFS["bash"]
	_active["breakbar_broken"] = {
		"remaining": BREAKBAR_BROKEN_STUN,
		"stacks": 1,
		"def": bash_def,
		"dot_accum": 0.0,
	}
	emit_signal("status_changed", "breakbar_broken", 1, BREAKBAR_BROKEN_STUN)
	emit_signal("breakbar_changed", 0.0, breakbar_max, true)
	# Visual + audio feedback for the break.
	if is_instance_valid(host) and host is Node2D:
		FX.spawn_burst_particles(host.global_position, Color(0.95, 0.85, 0.20, 1.0), 18)
		FX.screen_shake(FX.SHAKE_MEDIUM, FX.SHAKE_DUR_SHORT)
	Log.dbg("[BreakBar] BROKEN on %s — %0.1fs stun" % [host.name if host else "?", BREAKBAR_BROKEN_STUN])


func _spawn_breakbar_pip(amount: float) -> void:
	if not is_instance_valid(host) or not (host is Node2D):
		return
	var parent: Node = host.get_parent()
	if parent == null:
		return
	var label := Label.new()
	label.text = "-%d" % int(round(amount))
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color(0.95, 0.80, 0.15, 1.0))
	label.add_theme_color_override("font_outline_color", Color(0.10, 0.05, 0.0, 0.95))
	label.add_theme_constant_override("outline_size", 3)
	label.position = host.global_position + Vector2(randf_range(-16, 16), -58)
	label.z_index = 100
	parent.add_child(label)
	var tw: Tween = label.create_tween()
	tw.set_parallel(true)
	tw.tween_property(label, "position:y", label.position.y - 18, 0.55)
	tw.tween_property(label, "modulate:a", 0.0, 0.55)
	tw.chain().tween_callback(label.queue_free)


func is_breakbar_broken() -> bool:
	return _breakbar_broken


func _create_local_breakbar_visual() -> void:
	if not is_instance_valid(host) or not (host is Node2D):
		return
	_local_bb_bg = ColorRect.new()
	_local_bb_bg.color = Color(0.12, 0.10, 0.08, 0.80)
	_local_bb_bg.size = Vector2(LOCAL_BB_WIDTH, LOCAL_BB_HEIGHT)
	_local_bb_bg.position = Vector2(-LOCAL_BB_WIDTH * 0.5, LOCAL_BB_OFFSET_Y)
	_local_bb_bg.z_index = 15
	host.add_child(_local_bb_bg)
	_local_bb_fill = ColorRect.new()
	_local_bb_fill.color = BREAKBAR_FILL_COLOR
	_local_bb_fill.size = Vector2(LOCAL_BB_WIDTH - 2.0, LOCAL_BB_HEIGHT - 2.0)
	_local_bb_fill.position = Vector2(1.0, 1.0)
	_local_bb_bg.add_child(_local_bb_fill)


func _update_local_breakbar_visual(current: float, max_val: float, is_broken: bool) -> void:
	if _local_bb_fill == null or not is_instance_valid(_local_bb_fill):
		return
	var pct: float = clampf(current / maxf(max_val, 1.0), 0.0, 1.0)
	_local_bb_fill.size.x = (LOCAL_BB_WIDTH - 2.0) * pct
	if is_broken:
		_local_bb_fill.color = Color(0.95, 0.25, 0.15, 0.95)
	else:
		_local_bb_fill.color = BREAKBAR_FILL_COLOR
	if _local_bb_bg and is_instance_valid(_local_bb_bg):
		_local_bb_bg.visible = true


# -------------------------------------------------------
# Public API
# -------------------------------------------------------

# Apply a status. Stack policies:
#   "refresh"     — reset duration; stacks unchanged.
#   "extend"      — add duration on top of remaining; stacks unchanged.
#   "stack"       — +stacks_to_add (cap at max_stacks); reset duration.
#                   Also triggers cap_state transition when stacks hit cap.
func apply(id: String, duration: float, stacks_to_add: int = 1) -> void:
	if not STATUS_DEFS.has(id):
		push_warning("[StatusComponent] Unknown status id: %s" % id)
		return
	# --- Run 118 — Breakbar: ALL CC intercepted on bosses/minibosses ---
	# Both hard and soft CC are consumed by the breakbar. Bosses are FULLY
	# immune to all CC — no slows, no debuffs, no knockback.
	if breakbar_enabled and not _breakbar_broken:
		if id in BREAKBAR_CC_IDS:
			contribute_breakbar(id, stacks_to_add)
			return   # consumed — don't apply the status
		# Soft CC: contribute to breakbar AND block application.
		# Bosses/minibosses are fully immune to all CC — no slows, no debuffs.
		if BREAKBAR_CC_WEIGHTS.has(id):
			contribute_breakbar(id, stacks_to_add)
			return   # consumed — boss stays at full speed
	# Run 27f — Uprooted corrupt: Cracked Soil no longer applies to enemies
	# (the player weaponizes it instead — see Player movement stacks).
	# Run 139 — taker only: only the corrupt-taker's OWN hits stop applying
	# soil. Source attribution rides the last_damager meta every hero hit
	# stamps; unattributed applies (zones) pass through so the non-taker's
	# Potato build keeps working.
	if id == "cracked_soil" and host != null and host.is_in_group("enemy"):
		var _up_src: String = str(host.get_meta("last_damager")) if host.has_meta("last_damager") else ""
		if _up_src != "" and RunState.char_has("corrupt_potato", _up_src):
			return
	# Host can veto an incoming status apply (e.g. Player blocks Bash while
	# charging via Coconut Hard Landing; bosses ignore stun/Frozen).
	if host != null and host.has_method("can_receive_status"):
		if not host.can_receive_status(id):
			return
	var def: Dictionary = STATUS_DEFS[id]
	# Determine effective max stacks: base cap + RunState bonuses where applicable.
	var cap: int = def.get("max_stacks", 1)
	if id == "poison" and Engine.has_singleton("RunState"):
		pass  # noop; we read bonus inline below to avoid coupling
	# Inline RunState lookup for Onion Overripe (poison stack cap bump 5 → 7).
	var rs = Engine.get_singleton("RunState") if Engine.has_singleton("RunState") else null
	if rs == null:
		# Fall back: try autoload via global scope
		rs = Engine.get_main_loop().get_root().get_node_or_null("RunState") if Engine.get_main_loop() != null else null
	if id == "poison" and rs != null and "poison_max_stacks_bonus" in rs:
		cap = max(cap, def.get("max_stacks", 5) + int(rs.poison_max_stacks_bonus))

	# Run 128 — Embrace (Watermelon Legendary): every Soaked/Chilled
	# application gains +1 bonus stack (all Watermelon sources, per doc).
	# NOTE: the Soaked stacking id in this codebase is "wet".
	if (id == "wet" or id == "chilled") and host != null and host.is_in_group("enemy") \
	and (RunState.shino_has("embrace") or RunState.bea_has("embrace")):
		stacks_to_add += 1

	if _active.has(id):
		var entry: Dictionary = _active[id]
		var prev_stacks: int = entry["stacks"]
		match def.get("stack_policy", "refresh"):
			"refresh":
				entry["remaining"] = duration
			"extend":
				entry["remaining"] += duration
			"stack":
				var new_stacks: int = min(prev_stacks + stacks_to_add, cap)
				entry["stacks"] = new_stacks
				entry["remaining"] = duration
				# Poison spec: stacks refresh duration globally (refreshing
				# the entry already covers this — single entry per id).
				if def.has("cap_state") and new_stacks >= cap and _cap_state_allowed(id):
					_trigger_cap_state(id, def)
					return
		emit_signal("status_changed", id, entry["stacks"], entry["remaining"])
	else:
		var initial_stacks: int = min(stacks_to_add, cap)
		_active[id] = {
			"remaining": duration,
			"stacks": initial_stacks,
			"def": def,
			"dot_accum": 0.0,
		}
		if def.has("on_apply") and def["on_apply"] is Callable:
			(def["on_apply"] as Callable).call(host, initial_stacks)
		emit_signal("status_changed", id, initial_stacks, duration)
		# If the FIRST apply already saturates a stacking status (e.g. ult
		# applies 5 Soaked at once), trigger cap state immediately.
		if def.has("cap_state") and initial_stacks >= cap and def.get("stack_policy", "refresh") == "stack" and _cap_state_allowed(id):
			_trigger_cap_state(id, def)
	_refresh_indicator()


# Force-remove a status mid-way (calls on_expire). No-op if not active.
func remove(id: String) -> void:
	if _active.has(id):
		_expire(id)


func _expire(id: String) -> void:
	if not _active.has(id):
		return
	var entry: Dictionary = _active[id]
	var def: Dictionary = entry["def"]
	_active.erase(id)
	if def.has("on_expire") and def["on_expire"] is Callable:
		(def["on_expire"] as Callable).call(host)
	# Run 27d — Tide Storm duo max-state escalations (cross-axis):
	# Drenched expires → Bolted (5s); Frozen thaws → Greased (5s).
	if RunState.is_duo_active("banana_watermelon"):
		if id == "drenched":
			apply("bolted", 5.0, 1)
		elif id == "frozen":
			apply("greased", 5.0, 1)
	# Run 27f — Chronic Plague floor: once Poisoned, never below 1 stack.
	if id == "poison" and host != null and host.is_in_group("enemy") \
	and (RunState.shino_has("chronic_plague") or RunState.bea_has("chronic_plague")):
		apply("poison", 4.0, 1)
	# Run 128 — Embrace (Watermelon Legendary): after Drenched/Frozen expires
	# the host keeps 4 stacks — the next hit re-triggers the max-state loop.
	if (id == "drenched" or id == "frozen") and host != null and host.is_in_group("enemy") \
	and (RunState.shino_has("embrace") or RunState.bea_has("embrace")):
		apply("wet" if id == "drenched" else "chilled", 4.0, 4)
	# Run 128 — Wildfire (Pepper Legendary): Burn never times out — expiring
	# stacks jump to the nearest enemy within 3m (fresh 3s); lost if alone.
	if id == "burning" and host != null and host.is_in_group("enemy") \
	and (RunState.shino_has("wildfire") or RunState.bea_has("wildfire")):
		var _wf_stacks: int = int(entry.get("stacks", 1))
		var _wf_best: Node = null
		var _wf_d: float = 144.0
		if host is Node2D:
			for _wf_e in get_tree().get_nodes_in_group("enemy"):
				if _wf_e != host and is_instance_valid(_wf_e) and _wf_e is Node2D \
				and _wf_e.has_node("StatusComponent"):
					var _wf_dist: float = (host as Node2D).global_position.distance_to(_wf_e.global_position)
					if _wf_dist < _wf_d:
						_wf_d = _wf_dist
						_wf_best = _wf_e
		if _wf_best != null:
			_wf_best.get_node("StatusComponent").apply("burning", 3.0, _wf_stacks)
	emit_signal("status_changed", id, 0, 0.0)
	_refresh_indicator()


# Run 27e — Sparked/Bolted interval procs + Shattered burst (Bruno's spec).
const SPARK_TICK_DMG: int     = 2      # host zap per interval (light)
const SPARK_CHAIN_DMG: int    = 3      # per chain jump
const SPARK_CHAIN_JUMPS: int  = 2
const SPARK_CHAIN_RADIUS: float = 150.0
const BOLT_HOST_DMG: int      = 8      # bolted is the heavy hit
const BOLT_AOE_DMG: int       = 5
const BOLT_AOE_RADIUS: float  = 90.0
const SHATTER_DMG: int        = 6
const SHATTER_RADIUS: float   = 100.0

func _do_spark_chain() -> void:
	if not is_instance_valid(host):
		return
	var lm: float = RunState.lightning_damage_mult
	_apply_dot_damage(max(1, int(round(float(SPARK_TICK_DMG) * lm))), "sparked")
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	var candidates: Array = []
	for e in tree.get_nodes_in_group("enemy"):
		if e == host or not is_instance_valid(e) or not (e is Node2D):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		if host.global_position.distance_to(e.global_position) <= SPARK_CHAIN_RADIUS:
			candidates.append(e)
	if candidates.is_empty():
		return
	var from_pos: Vector2 = host.global_position
	for i in range(SPARK_CHAIN_JUMPS):
		# Revisit targets when the pool is small — keeps the chain going.
		var t: Node2D = candidates[i % candidates.size()]
		_spawn_zap_arc(from_pos, t.global_position)
		if t.has_method("take_damage"):
			t.take_damage(max(1, int(round(float(SPARK_CHAIN_DMG) * lm))), Vector2.ZERO)
		from_pos = t.global_position

func _do_bolt_strike() -> void:
	if not is_instance_valid(host):
		return
	var lm: float = RunState.lightning_damage_mult
	# Vertical bolt visual: strike from above straight down onto the host.
	_spawn_zap_arc(host.global_position + Vector2(randf_range(-8.0, 8.0), -130.0), host.global_position)
	_spawn_status_puff(Color(0.85, 0.90, 1.0, 0.95), 4)
	_apply_dot_damage(max(1, int(round(float(BOLT_HOST_DMG) * lm))), "bolted")
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	for e in tree.get_nodes_in_group("enemy"):
		if e == host or not is_instance_valid(e) or not (e is Node2D):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		if host.global_position.distance_to(e.global_position) <= BOLT_AOE_RADIUS \
		and e.has_method("take_damage"):
			e.take_damage(max(1, int(round(float(BOLT_AOE_DMG) * lm))),
				(e.global_position - host.global_position).normalized() * 40.0)

func _do_shatter_burst() -> void:
	if not is_instance_valid(host) or not host.is_in_group("enemy"):
		return
	_spawn_status_puff(Color(0.85, 0.95, 1.0, 0.95), 6)
	FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_TINY)
	# Stun the shattered target itself + damage/stun everything nearby.
	apply("bash", 1.0, 1)
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	for e in tree.get_nodes_in_group("enemy"):
		if e == host or not is_instance_valid(e) or not (e is Node2D):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		if host.global_position.distance_to(e.global_position) <= SHATTER_RADIUS:
			if e.has_method("take_damage"):
				e.take_damage(SHATTER_DMG, (e.global_position - host.global_position).normalized() * 50.0)
			if e.has_node("StatusComponent"):
				e.get_node("StatusComponent").apply("bash", 1.0, 1)

func _spawn_zap_arc(from: Vector2, to: Vector2) -> void:
	var parent: Node = host.get_parent() if is_instance_valid(host) else null
	if parent == null:
		return
	var arc := Line2D.new()
	arc.default_color = Color(0.75, 0.85, 1.0, 0.95)
	arc.width = 2.0
	arc.add_point(from)
	arc.add_point((from + to) * 0.5 + Vector2(randf_range(-10.0, 10.0), randf_range(-10.0, 10.0)))
	arc.add_point(to)
	arc.z_index = 12
	parent.add_child(arc)
	var tw: Tween = arc.create_tween()
	tw.tween_property(arc, "modulate:a", 0.0, 0.18)
	tw.tween_callback(arc.queue_free)


# Run 27d — small particle puff at the host (generic helper, no FX autoload
# dependency — mirrors _spawn_dot_tick_particles' approach).
func _spawn_status_puff(col: Color, count: int) -> void:
	if not is_instance_valid(host):
		return
	var parent: Node = host.get_parent()
	if parent == null:
		return
	for i in range(count):
		var p := ColorRect.new()
		p.size = Vector2(randi_range(4, 7), randi_range(4, 7))
		p.color = col
		p.position = host.global_position + Vector2(randf_range(-12.0, 12.0), randf_range(-6.0, 8.0))
		p.z_index = 9
		parent.add_child(p)
		var tw: Tween = p.create_tween()
		# Droplets fall DOWN (slick dripping off), unlike DoT puffs that rise.
		tw.tween_property(p, "position", p.position + Vector2(randf_range(-4.0, 4.0), 10.0), 0.35)
		tw.parallel().tween_property(p, "modulate:a", 0.0, 0.35)
		tw.tween_callback(p.queue_free)


# Run 27d — forced slip-fall: 0.5s prone + comedy faceplant FX. Also feeds
# Tide Storm (slip events apply 1 Chilled) and Peel Restoration's default arm
# (hero heals 1 HP when an enemy slips; per-hero ICD lives on the heroes).
func _do_slip_fall() -> void:
	apply("stagger", 0.5, 1)
	if is_instance_valid(host) and host is Node2D:
		FX.spawn_hit_particles(host.global_position, Color(0.95, 0.85, 0.30, 1.0), 7)
		FX.play_sound("enemy_hit", 0.5)
		# Comedy faceplant: tip the host's sprite 90° for the prone window,
		# then snap back upright. Duck-typed — enemies expose `sprite`.
		var spr: Variant = host.get("sprite") if host.has_method("get") else null
		if spr is Control:
			(spr as Control).pivot_offset = (spr as Control).size * 0.5
			var tip: float = 90.0 if randf() < 0.5 else -90.0
			var tw2: Tween = (spr as Control).create_tween()
			tw2.tween_property(spr, "rotation_degrees", tip, 0.10)
			tw2.tween_interval(0.30)
			tw2.tween_property(spr, "rotation_degrees", 0.0, 0.10)
	if RunState.is_duo_active("banana_watermelon"):
		apply("chilled", 4.0, 1)
	if RunState.is_duo_active("apple_banana"):
		var tree: SceneTree = get_tree()
		if tree != null:
			for grp in ["player", "bea"]:
				for pl in tree.get_nodes_in_group(grp):
					if is_instance_valid(pl) and pl.has_method("peel_restoration_slip_credit"):
						pl.peel_restoration_slip_credit()


# Run 55 — Burning's cap-state ("combusted") is the Combust-boon detonation.
# Without that boon it would just delete the burn at 5 stacks for no payoff,
# which fights the new design where Burning is meant to DWELL at 5 stacks and
# tick every 1s. So only allow Burning's cap-state when Combust was taken;
# all other statuses (Soaked→Drenched, Chilled→Frozen, etc.) are unaffected.
func _cap_state_allowed(id: String) -> bool:
	if id == "burning":
		return RunState.combust_taken
	return true


func _trigger_cap_state(source_id: String, source_def: Dictionary) -> void:
	var cap: Dictionary = source_def["cap_state"]
	var cap_id: String = cap.get("id", "")
	var cap_dur: float = cap.get("duration", 1.0)
	var consume: bool = cap.get("consume_stacks", true)
	# Run 128 — Embrace (Watermelon Legendary): Drenched/Frozen last 2x AND
	# pull nearby enemies (3m) toward the max-stated target (clump for AoE).
	if (cap_id == "drenched" or cap_id == "frozen") \
	and (RunState.shino_has("embrace") or RunState.bea_has("embrace")):
		cap_dur *= 2.0
		if host != null and host is Node2D:
			for _em_e in get_tree().get_nodes_in_group("enemy"):
				if _em_e != host and is_instance_valid(_em_e) and _em_e is Node2D \
				and (host as Node2D).global_position.distance_to(_em_e.global_position) < 144.0:
					_em_e.global_position = _em_e.global_position.move_toward((host as Node2D).global_position, 40.0)
	# Run 130 — Summer's / Winter's End (Watermelon Legendary): the max-state
	# moment DETONATES — 3m AoE applies 1 stack + leaves a puddle / ice patch
	# (2m, 5s, 1 stack/sec) at the detonation point.
	if (cap_id == "drenched" or cap_id == "frozen") and RunState.team_has("summers_end") \
	and host != null and host is Node2D:
		var _se_id: String = "chilled" if cap_id == "frozen" else "wet"
		var _se_pos: Vector2 = (host as Node2D).global_position
		for _se_e in get_tree().get_nodes_in_group("enemy"):
			if _se_e != host and is_instance_valid(_se_e) and _se_e is Node2D \
			and _se_pos.distance_to(_se_e.global_position) < 144.0 \
			and _se_e.has_node("StatusComponent"):
				_se_e.get_node("StatusComponent").apply(_se_id, 4.0, 1)
		for _se_pl in get_tree().get_nodes_in_group("player"):
			if _se_pl.has_method("_spawn_status_zone"):
				_se_pl._spawn_status_zone(_se_pos, 64.0, 5.0, _se_id, 1,
					Color(0.55, 0.85, 0.95, 0.45) if _se_id == "chilled" else Color(0.30, 0.70, 0.95, 0.45))
				break
		_spawn_status_puff(Color(0.40, 0.80, 0.95, 0.9), 8)
	# Drop the stacking light status before promoting (Drenched replaces Soaked,
	# Frozen replaces Chilled). Avoid recursive cap-trigger by erasing directly.
	if consume:
		_active.erase(source_id)
		emit_signal("status_changed", source_id, 0, 0.0)
	if cap_id != "":
		apply(cap_id, cap_dur, 1)
	# Combust detonation (Pepper boon — Combat_Boons §8.6).
	# Fires AFTER the cap-state apply so the "combusted" cooldown marker is
	# already in _active before the explosion tries to spread Burn to host.
	if cap_id == "combusted":
		_do_combust_explosion()
	# Run 27e — Shattered (Brittle cap): AoE burst stun around the target.
	if cap_id == "shattered":
		_do_shatter_burst()


# -------------------------------------------------------
# Combust detonation — Pepper boon (Combat_Boons §8.6)
# -------------------------------------------------------
# Called when a Burning status on `host` saturates at 5 stacks.
# Conditions: RunState.combust_taken must be true.
# Effect: 120px AoE explosion centred on host; deals flat burst damage to
# all nearby entities (enemies + players/bea) except host itself; then
# spreads 2 Burn stacks (3s) to each entity hit.
# Visual: orange flash + heavy shake + orange particles via FX autoload.
const COMBUST_RADIUS:   float = 120.0
const COMBUST_FLAT_DMG: int   = 20      # Burst damage before target mitigation
const COMBUST_KNOCKBACK: float = 90.0   # Radial impulse magnitude
const COMBUST_SPREAD_STACKS: int = 2    # Burn stacks spread to neighbours
const COMBUST_SPREAD_DUR: float = 3.0   # Duration of spread Burn stacks

func _do_combust_explosion() -> void:
	# Gate on boon ownership so accidental 5-stack procs don't explode in
	# a run where the player never picked Combust.
	var rs = Engine.get_singleton("RunState") if Engine.has_singleton("RunState") else null
	if rs == null:
		rs = Engine.get_main_loop().get_root().get_node_or_null("RunState") if Engine.get_main_loop() != null else null
	if rs == null or not ("combust_taken" in rs) or not bool(rs.combust_taken):
		return

	if not is_instance_valid(host):
		return

	var origin: Vector2 = host.global_position
	var tree: SceneTree = host.get_tree() if host.has_method("get_tree") else null
	if tree == null:
		return

	# --- Visual FX ---
	var fx = tree.get_root().get_node_or_null("FX")
	if fx != null:
		if fx.has_method("shake"):
			fx.shake(5.5)
		# Spawn orange burst particles at the detonation point.
		_spawn_combust_particles(origin, tree)

	# --- Scan and hit nearby targets ---
	var scan_groups: Array[String] = ["enemy", "player", "bea"]
	for group in scan_groups:
		for body in tree.get_nodes_in_group(group):
			if body == host:
				continue  # Host already took damage from its own DoT
			if not is_instance_valid(body):
				continue
			var dist: float = (body.global_position - origin).length()
			if dist > COMBUST_RADIUS:
				continue
			# Radial knockback direction (push away from explosion center).
			var dir: Vector2 = Vector2.RIGHT if dist < 1.0 else (body.global_position - origin).normalized()
			# Deal burst damage.
			if body.has_method("take_damage"):
				# Run 27 — Acid Burn synergy (Pepper×Onion): +10% Combust
				# damage per Poison stack on the detonating host.
				var _combust_dmg: int = COMBUST_FLAT_DMG
				if _active.has("poison") and rs.has_method("is_synergy_active") \
				and rs.is_synergy_active("acid_burn"):
					_combust_dmg = int(round(float(_combust_dmg) * (1.0 + 0.10 * float(get_stacks("poison")))))
				body.take_damage(_combust_dmg, dir * COMBUST_KNOCKBACK)
			# Spread Burn stacks to the hit target (if it has a StatusComponent).
			if "status" in body and body.status != null and is_instance_valid(body.status):
				# Don't spread to targets already on the "combusted" cooldown —
				# this prevents chain-reaction cascades in the prototype.
				if not body.status.has("combusted"):
					body.status.apply("burning", COMBUST_SPREAD_DUR, COMBUST_SPREAD_STACKS)

	Log.dbg("[Combust] Detonated at %s — radius %dpx, %d flat dmg, spreading %d Burn stacks" % [
		origin, int(COMBUST_RADIUS), COMBUST_FLAT_DMG, COMBUST_SPREAD_STACKS])


# Spawns a brief cluster of orange ColorRect "spark" particles at pos.
# Reuses the lightweight particle approach used elsewhere in the project.
func _spawn_combust_particles(pos: Vector2, tree: SceneTree) -> void:
	var parent: Node = tree.get_root().get_node_or_null("World")
	if parent == null:
		parent = tree.get_current_scene()
	if parent == null:
		return
	for i in range(10):
		var p := ColorRect.new()
		p.size = Vector2(randi_range(5, 10), randi_range(5, 10))
		p.color = Color(1.0, randf_range(0.2, 0.5), 0.05, 0.92)
		p.position = pos + Vector2(randf_range(-30.0, 30.0), randf_range(-30.0, 30.0))
		p.z_index = 10
		parent.add_child(p)
		# Fade and free after 0.35s.
		var tween: Tween = p.create_tween()
		tween.tween_property(p, "modulate:a", 0.0, 0.35)
		tween.tween_callback(p.queue_free)


# DoT helper: routes damage through host.take_damage so existing flash + KB
# logic fires for free. Per-status id passed so future hooks can read which
# status fired the tick (e.g. Pepper Combust trigger at 5 Burn stacks).
func _apply_dot_damage(amount: int, _src_id: String) -> void:
	if amount <= 0:
		return
	if not is_instance_valid(host):
		return
	# Run 23 — Root & Rot (Potato + Onion duo): Rooted targets take +20%
	# poison-DoT damage.
	if _src_id == "poison" and _active.has("root"):
		var rs = Engine.get_main_loop().get_root().get_node_or_null("RunState") if Engine.get_main_loop() != null else null
		if rs != null and rs.has_method("get_root_and_rot_amp"):
			var amp: float = float(rs.get_root_and_rot_amp())
			if amp > 0.0:
				amount = int(round(float(amount) * (1.0 + amp)))
	# Run 27 — Toxic Soil synergy (Potato×Onion): Poison DoT on Cracked Soil
	# hosts deals +15% damage. (Decay-slowing arm deferred — see audit doc.)
	if _src_id == "poison" and _active.has("cracked_soil"):
		var rs_ts = Engine.get_main_loop().get_root().get_node_or_null("RunState") if Engine.get_main_loop() != null else null
		if rs_ts != null and rs_ts.has_method("is_synergy_active") and rs_ts.is_synergy_active("toxic_soil"):
			amount = int(round(float(amount) * 1.15))
	# Run 27b — Acid Puddle/Mist duo (Onion+Watermelon): Wet/Frostbitten
	# hosts take 2× Poison DoT.
	if _src_id == "poison" and (is_wet() or is_frostbitten()) \
	and RunState.is_duo_active("onion_watermelon"):
		amount *= 2
	# Run 27f — Tears of Restoration (Onion passive): each Poison tick you
	# deal siphons Chi to the hero(es) who own the boon. Fractional 0.5
	# Chi/tick approximated as a 50% chance of +1.
	if _src_id == "poison" and host != null and host.is_in_group("enemy") and randf() < 0.5:
		var _tr_tree: SceneTree = get_tree()
		if _tr_tree != null:
			if RunState.shino_has("tears_of_restoration"):
				for pl in _tr_tree.get_nodes_in_group("player"):
					if pl.has_method("gain_chi_external"):
						pl.gain_chi_external(1)
						break
			if RunState.bea_has("tears_of_restoration"):
				for bl in _tr_tree.get_nodes_in_group("bea"):
					if bl.has_method("gain_chi_external"):
						bl.gain_chi_external(1)
						break
	# Spawn element-themed tick particles so ongoing DoTs have continuous
	# visual feedback matching their family identity.
	_spawn_dot_tick_particles(_src_id)
	if host.has_method("apply_status_dot_damage"):
		host.apply_status_dot_damage(amount, _src_id)
		return
	if host.has_method("take_damage"):
		host.take_damage(amount, Vector2.ZERO)


# -------------------------------------------------------
# Run 55 — interval DoT helpers (Burning / Poison)
# -------------------------------------------------------
# Seconds between ticks for a given DoT id at the current stack count.
func _dot_interval(id: String, stacks: int) -> float:
	if id == "poison":
		var iv: float = POISON_TICK_INTERVAL
		# Chronic Plague (Onion Legendary) — faster cadence (half interval).
		if RunState.shino_has("chronic_plague") or RunState.bea_has("chronic_plague"):
			iv *= 0.5
		return iv
	if id == "burning":
		# Heat ramps: 1 stack → 5s, each extra stack shaves a second, floor 1s.
		var biv: float = clampf(
			BURN_INTERVAL_MAX - float(max(0, stacks - 1)) * BURN_INTERVAL_STEP,
			BURN_INTERVAL_MIN, BURN_INTERVAL_MAX)
		# Run 130 — Ghost Pepper (Pepper Legendary): Burn ticks 2x faster.
		if RunState.team_has("ghost_pepper"):
			biv *= 0.5
		return biv
	return 1.0


# Flat damage dealt per tick for a given DoT id at the current stack count.
func _dot_tick_damage(id: String, stacks: int) -> int:
	if id == "poison":
		var pd: float = float(POISON_TICK_DMG_PER_STACK * max(1, stacks))
		# Chronic Plague — +50% per tick (combined with halved interval ≈ 3× throughput, matching the old model).
		if RunState.shino_has("chronic_plague") or RunState.bea_has("chronic_plague"):
			pd *= 1.5
		return int(round(pd))
	if id == "burning":
		# Solar Flare (corrupt_pepper) & other fire boons scale the number.
		return max(1, int(round(float(BURN_TICK_DMG) * RunState.fire_damage_mult)))
	return 0


# -------------------------------------------------------
# Run 55 — continuous status auras (visual only)
# -------------------------------------------------------
# Burning emits a rising flame aura whose density / size / heat-colour grow
# with stacks; Poison emits rising purple bubbles. Both are decoupled from the
# damage tick so the effect reads continuously even though damage is on a timer.
func _update_status_auras(delta: float) -> void:
	# Run 128 — Wildfire (Pepper Legendary) spread arm: every 2s, a burning
	# enemy passes 1 Burn stack to the nearest enemy within 3m (copy, not
	# transfer — wildfire grows; tunable if it snowballs too hard).
	if _active.has("burning") and host != null and host.is_in_group("enemy") \
	and (RunState.shino_has("wildfire") or RunState.bea_has("wildfire")):
		_wildfire_accum += delta
		if _wildfire_accum >= 2.0:
			_wildfire_accum = 0.0
			var _wfs_best: Node = null
			var _wfs_d: float = 144.0
			if host is Node2D:
				for _wfs_e in get_tree().get_nodes_in_group("enemy"):
					if _wfs_e != host and is_instance_valid(_wfs_e) and _wfs_e is Node2D \
					and _wfs_e.has_node("StatusComponent"):
						var _wfs_dist: float = (host as Node2D).global_position.distance_to(_wfs_e.global_position)
						if _wfs_dist < _wfs_d:
							_wfs_d = _wfs_dist
							_wfs_best = _wfs_e
			if _wfs_best != null:
				_wfs_best.get_node("StatusComponent").apply("burning", 3.0, 1)
				_spawn_status_puff(Color(1.0, 0.45, 0.10, 0.8), 4)
	else:
		_wildfire_accum = 0.0
	# Run 130 — BONK / ZAP (Banana Legendary): every 3s, Banana-statused
	# enemies get punished — default: forced slip-fall + ~10% max HP;
	# GL: bolt strike ~15% max HP + re-Spark.
	if host != null and host.is_in_group("enemy") and RunState.team_has("bonk_zap"):
		var _bz_on: bool = false
		if RunState.greased_lightning_mode:
			_bz_on = _active.has("sparked") or _active.has("bolted")
		else:
			_bz_on = _active.has("slippery") or _active.has("greased")
		if _bz_on:
			_bonk_accum += delta
			if _bonk_accum >= 3.0:
				_bonk_accum = 0.0
				var _bz_max: int = int(host.get("max_hp")) if "max_hp" in host else 40
				if RunState.greased_lightning_mode:
					if host.has_method("take_damage"):
						host.take_damage(max(1, int(round(_bz_max * 0.15))), Vector2.ZERO)
					apply("sparked", 3.0, 1)
					_spawn_status_puff(Color(0.75, 0.88, 1.0, 0.9), 6)
				else:
					if host.has_method("take_damage"):
						host.take_damage(max(1, int(round(_bz_max * 0.10))), Vector2.ZERO)
					_do_slip_fall()
		else:
			_bonk_accum = 0.0
	if not is_instance_valid(host):
		return
	if _active.has("burning"):
		var bstacks: int = int(_active["burning"]["stacks"])
		_burn_aura_accum += delta
		# More stacks → emit more often (denser flame).
		var bperiod: float = lerpf(0.28, 0.08, clampf(float(bstacks - 1) / 4.0, 0.0, 1.0))
		if _burn_aura_accum >= bperiod:
			_burn_aura_accum = 0.0
			_spawn_burn_aura(bstacks)
	else:
		_burn_aura_accum = 0.0
	if _active.has("poison"):
		var pstacks: int = int(_active["poison"]["stacks"])
		_poison_bubble_accum += delta
		var pperiod: float = lerpf(0.45, 0.22, clampf(float(pstacks - 1) / 4.0, 0.0, 1.0))
		if _poison_bubble_accum >= pperiod:
			_poison_bubble_accum = 0.0
			_spawn_poison_bubbles(pstacks)
	else:
		_poison_bubble_accum = 0.0


func _spawn_burn_aura(stacks: int) -> void:
	var parent: Node = host.get_parent() if is_instance_valid(host) else null
	if parent == null:
		return
	var heat: float = clampf(float(stacks - 1) / 4.0, 0.0, 1.0)
	var n: int = 1 + int(stacks / 2)   # 1 flame at low stacks → 3 at 5
	for i in range(n):
		var p := ColorRect.new()
		var sz: int = randi_range(3, 5) + stacks   # bigger flames as it intensifies
		p.size = Vector2(sz, sz)
		# Cooler orange at low heat → hot yellow-white at high stacks.
		p.color = Color(1.0, lerpf(0.35, 0.80, heat), lerpf(0.06, 0.30, heat), lerpf(0.55, 0.85, heat))
		p.position = host.global_position + Vector2(randf_range(-11.0, 11.0), randf_range(-2.0, 14.0))
		p.z_index = 9
		parent.add_child(p)
		var rise: float = 16.0 + float(stacks) * 3.0
		var life: float = lerpf(0.45, 0.28, heat)
		var tw: Tween = p.create_tween()
		tw.tween_property(p, "position", p.position + Vector2(randf_range(-4.0, 4.0), -rise), life)
		tw.parallel().tween_property(p, "modulate:a", 0.0, life)
		tw.tween_callback(p.queue_free)


func _spawn_poison_bubbles(stacks: int) -> void:
	var parent: Node = host.get_parent() if is_instance_valid(host) else null
	if parent == null:
		return
	var n: int = 1 + int(stacks / 3)   # 1–2 bubbles
	for i in range(n):
		var b := ColorRect.new()
		var sz: int = randi_range(3, 6)
		b.size = Vector2(sz, sz)
		b.color = Color(0.62, 0.24, 0.85, 0.78)   # toxic purple
		b.position = host.global_position + Vector2(randf_range(-10.0, 10.0), randf_range(-2.0, 12.0))
		b.z_index = 9
		parent.add_child(b)
		var tw: Tween = b.create_tween()
		# Bubble drifts up, wobbles, then "pops" (fade out).
		tw.tween_property(b, "position", b.position + Vector2(randf_range(-3.0, 3.0), -randf_range(12.0, 20.0)), 0.6)
		tw.parallel().tween_property(b, "modulate:a", 0.0, 0.6)
		tw.tween_callback(b.queue_free)


# Per-tick element-themed particle puff — small so it reads as "ongoing"
# without obscuring the hit FX. Only spawns every N ticks via a simple
# per-status frame counter to avoid saturating the scene with particles.
var _dot_tick_counter: Dictionary = {}   # src_id → frames-since-last-spawn
var _loose_earth_accum: float = 0.0      # Run 27b — Loose Earth duo 1s tick
var _slip_roll_accum: float = 0.0        # Run 27d — Slippery/Greased slip-fall 1s roll
var _tide_storm_accum: float = 0.0       # Run 27d — Tide Storm cross-status 1s tick
var _slip_drip_accum: float = 0.0        # Run 27d — Slippery/Greased visual drip cadence
var _zap_proc_accum: float = 0.0         # Run 27e — Sparked/Bolted interval proc
var _scald_accum: float = 0.0            # Run 27e — Steam/Brittle build-up tick

func _spawn_dot_tick_particles(src_id: String) -> void:
	if not is_instance_valid(host):
		return
	# Only spawn a particle puff every 3 DoT ticks to avoid overwhelming.
	_dot_tick_counter[src_id] = _dot_tick_counter.get(src_id, 0) + 1
	if _dot_tick_counter[src_id] % 3 != 0:
		return
	var pos: Vector2 = host.global_position
	# Element-themed colours (match the per-apply FX added in Player.gd).
	var col: Color
	var count: int = 2
	match src_id:
		"burning", "poison":
			return   # Run 55 — handled by continuous auras (_spawn_burn_aura / _spawn_poison_bubbles)
		"sparked", "bolted":
			col   = Color(0.65, 0.80, 1.0, 0.80)   # electric blue-white
		"bleed":
			col   = Color(0.85, 0.15, 0.20, 0.80)   # crimson
		_:
			return   # no themed puff for non-DoT statuses
	# Spawn small puff without calling FX autoload (StatusComponent is generic).
	var parent: Node = host.get_parent() if is_instance_valid(host) else null
	if parent == null:
		return
	for i in range(count):
		var p := ColorRect.new()
		p.size = Vector2(randi_range(4, 7), randi_range(4, 7))
		p.color = col
		p.position = pos + Vector2(randf_range(-10.0, 10.0), randf_range(-14.0, 4.0))
		p.z_index = 9
		parent.add_child(p)
		var tw: Tween = p.create_tween()
		tw.tween_property(p, "position", p.position + Vector2(randf_range(-6.0, 6.0), -12.0), 0.30)
		tw.parallel().tween_property(p, "modulate:a", 0.0, 0.30)
		tw.tween_callback(p.queue_free)


func _host_max_hp() -> float:
	if not is_instance_valid(host):
		return 0.0
	if host.has_method("get_effective_max_hp"):
		return float(host.get_effective_max_hp())
	# Common fields used in this codebase
	if "max_hp" in host:
		return float(host.max_hp)
	return 100.0


# -------------------------------------------------------
# Query helpers
# -------------------------------------------------------
func has(id: String) -> bool:
	return _active.has(id)


func get_stacks(id: String) -> int:
	if not _active.has(id):
		return 0
	return _active[id]["stacks"]


func get_remaining(id: String) -> float:
	if not _active.has(id):
		return 0.0
	return _active[id]["remaining"]


func get_all_active_ids() -> Array:
	return _active.keys()


# -------------------------------------------------------
# Aggregated effect queries (host calls these in tick/take_damage)
# -------------------------------------------------------

# Multiplicative damage-taken amp from every active status with
# damage_taken_amp_per_stack. Used by Vulnerable (+25%/stack, cap 4).
func get_damage_taken_mult() -> float:
	var mult: float = 1.0
	for id in _active.keys():
		var entry: Dictionary = _active[id]
		var def: Dictionary = entry["def"]
		if def.has("damage_taken_amp_per_stack"):
			var amp: float = def["damage_taken_amp_per_stack"]
			mult *= 1.0 + amp * float(entry["stacks"])
	return mult


# Aggregated move-speed multiplier from every status that scopes it.
# Chilled = -10%/stack (5 stacks → 0.5×). Cracked Soil = -20%/stack.
# Returns 1.0 if no effects. Floored at 0.0.
func get_move_speed_mult() -> float:
	var mult: float = 1.0
	for id in _active.keys():
		var entry: Dictionary = _active[id]
		var def: Dictionary = entry["def"]
		if def.has("move_speed_mult_per_stack"):
			mult *= max(0.0, 1.0 + float(def["move_speed_mult_per_stack"]) * float(entry["stacks"]))
		if def.has("flat_move_speed_mult"):
			mult *= max(0.0, 1.0 + float(def["flat_move_speed_mult"]))
	return max(0.0, mult)


# Aggregated attack-speed multiplier from every status that scopes it.
# Wet = -5%/stack (cap -25%). Drenched = -25% flat (replaces Wet at cap).
func get_attack_speed_mult() -> float:
	var mult: float = 1.0
	for id in _active.keys():
		var entry: Dictionary = _active[id]
		var def: Dictionary = entry["def"]
		if def.has("attack_speed_mult_per_stack"):
			mult *= max(0.0, 1.0 + float(def["attack_speed_mult_per_stack"]) * float(entry["stacks"]))
		if def.has("flat_attack_speed_mult"):
			mult *= max(0.0, 1.0 + float(def["flat_attack_speed_mult"]))
	return max(0.0, mult)


# Aggregated miss-chance from every status that contributes to it.
# Slippery 20%, Greased 40%; Burning adds 5%/stack (Pepper blind);
# Sparked/Bolted have their own % per spec — set in STATUS_DEFS.
func get_miss_chance() -> float:
	# Run 27f — Singed (Pepper passive): burning enemies suffer +10% extra
	# blind miss chance (on top of the per-stack Burn blind).
	if _active.has("burning") and (RunState.shino_has("singed") or RunState.bea_has("singed")):
		return _get_miss_chance_base() + 0.10
	return _get_miss_chance_base()

func _get_miss_chance_base() -> float:
	var miss: float = 0.0
	for id in _active.keys():
		var entry: Dictionary = _active[id]
		var def: Dictionary = entry["def"]
		# Run 58 (Bruno): flat miss_chance statuses now STACK additively instead
		# of the strongest one taking over. So Slippery (0.20) + Greased (0.40) on
		# the same enemy = 0.60 miss, rewarding landing both bananarang legs.
		if def.has("miss_chance"):
			miss += float(def["miss_chance"])
		if def.has("miss_chance_per_stack"):
			miss += float(def["miss_chance_per_stack"]) * float(entry["stacks"])
	return clamp(miss, 0.0, 0.95)


# Returns true if any active status has the movement_lock tag.
# Bash, Frozen, Root — and the soft "hitstop" — all freeze the host in place.
func is_movement_locked() -> bool:
	for id in _active.keys():
		var def: Dictionary = _active[id]["def"]
		if def.get("movement_lock", false):
			return true
	return false


# Run 150 (Bruno fix 10) — TRUE CC lock only (excludes soft locks like
# "hitstop"). Enemy scripts use THIS to decide whether to CANCEL a windup /
# attack: base-attack hitstop pauses the body but never robs the attack;
# real stuns (bash/frozen/root from boons) still cancel.
func is_hard_locked() -> bool:
	for id in _active.keys():
		var def: Dictionary = _active[id]["def"]
		if def.get("movement_lock", false) and not def.get("soft_lock", false):
			return true
	return false


# Returns true if any active status has the action_lock tag.
# UNIVERSAL RULE: action_lock does NOT block dash. Host input
# code must let dash through even when this is true (handled in
# Player.gd / BeaAI.gd by ordering the dash check before the
# is_action_locked() early-return).
func is_action_locked() -> bool:
	for id in _active.keys():
		var def: Dictionary = _active[id]["def"]
		if def.get("action_lock", false):
			return true
	return false


# Convenience predicates for umbrella states (spec triggers).
func is_wet() -> bool:
	return _active.has("wet") or _active.has("drenched")

func is_frostbitten() -> bool:
	return _active.has("chilled") or _active.has("frozen")

func is_burning() -> bool:
	return _active.has("burning")

func is_poisoned() -> bool:
	return _active.has("poison")


# -------------------------------------------------------
# Visual indicator (Run 17)
# -------------------------------------------------------
# Single text Label parented to host. Shows compact icons (one short
# string per active status) + total stack count if >1. Lazy-init.
# Avoids extra texture deps; sits above the host at INDICATOR_OFFSET.
# ColorRect background gives just enough contrast over arena floor.
func _ensure_indicator() -> void:
	if not is_instance_valid(host):
		return
	if host.has_meta("status_indicator_disabled") and bool(host.get_meta("status_indicator_disabled")):
		return
	if _indicator != null and is_instance_valid(_indicator):
		return
	var lab := Label.new()
	lab.name = "StatusIndicator"
	lab.position = INDICATOR_OFFSET
	lab.z_index = 8
	lab.add_theme_font_size_override("font_size", 11)
	lab.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0))
	lab.add_theme_color_override("font_outline_color", Color(0.05, 0.05, 0.05, 0.95))
	lab.add_theme_constant_override("outline_size", 3)
	lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host.add_child(lab)
	_indicator = lab


func _refresh_indicator() -> void:
	if _active.is_empty():
		_hide_indicator_if_empty()
		return
	_ensure_indicator()
	if _indicator == null or not is_instance_valid(_indicator):
		return
	var parts: Array[String] = []
	for id in _active.keys():
		var entry: Dictionary = _active[id]
		var def: Dictionary = entry["def"]
		var icon: String = def.get("icon_char", "?")
		var stacks: int = entry["stacks"]
		if stacks > 1:
			parts.append("%s%d" % [icon, stacks])
		else:
			parts.append(icon)
	_indicator.text = " ".join(parts)
	_indicator.visible = true


func _hide_indicator_if_empty() -> void:
	if _indicator != null and is_instance_valid(_indicator):
		_indicator.visible = false


# -------------------------------------------------------
# Status definitions
# -------------------------------------------------------
# New statuses go here. Each entry is a Dictionary describing
# duration semantics and gameplay effects.
#
# Per-stack flags drive aggregated query helpers. Cap-state entries
# auto-promote on saturation. Default durations are passed by the
# caller (boon proc or charge attack); these dicts only define cap,
# stack policy, and mechanical effects.
# ============================================================
const STATUS_DEFS: Dictionary = {

	# === Coconut (Run 14-16 — already wired) ===
	"bash": {
		"max_stacks":    1,
		"stack_policy":  "refresh",
		"movement_lock": true,
		"action_lock":   true,
		"display_name":  "Bash",
		"icon_char":     "B",
		"tint":          Color(1.0, 0.95, 0.30, 0.95),
	},
	# Run 150 (Bruno fix 10) — HITSTOP: the base-attack "punch feel" freeze.
	# Movement-locks the host for a beat (Run 47 hitstop identity preserved)
	# but is a SOFT lock: enemy scripts must NOT cancel windups/attacks on it
	# (use is_hard_locked() for cancel decisions). Never applies to breakbar
	# hosts — it's consumed as a tiny chip instead (see BREAKBAR tables).
	"hitstop": {
		"max_stacks":    1,
		"stack_policy":  "refresh",
		"movement_lock": true,
		"soft_lock":     true,
		"display_name":  "Hitstop",
		"icon_char":     "",
		"tint":          Color(1.0, 1.0, 1.0, 0.0),
	},
	"vulnerable": {
		"max_stacks":                 4,
		"stack_policy":               "stack",
		"damage_taken_amp_per_stack": 0.25,
		"display_name":               "Vulnerable",
		"icon_char":                  "V",
		"tint":                       Color(0.95, 0.30, 0.85, 0.95),
	},

	# === Watermelon (water mode) — Combat_Boons §8.7 ===
	# "wet" is the internal id for Soaked stacks (umbrella state name is
	# "Wet" per spec; storing as wet to match the boon-getter naming).
	"wet": {
		"max_stacks":                  5,
		"stack_policy":                "stack",
		"attack_speed_mult_per_stack": -0.05,   # -25% AS at 5 stacks
		"cap_state":                   {"id": "drenched", "duration": 4.0, "consume_stacks": true},
		"display_name":                "Wet",
		"icon_char":                   "~",
		"tint":                        Color(0.30, 0.70, 0.95, 0.95),
	},
	"drenched": {
		"max_stacks":              1,
		"stack_policy":            "refresh",
		"flat_attack_speed_mult":  -0.25,
		"display_name":            "Drenched",
		"icon_char":               "≈",
		"tint":                    Color(0.15, 0.55, 0.95, 0.95),
		# NOTE: drenched does NOT lock dash (universal rule).
	},

	# === Watermelon (Gelato mode) — Combat_Boons §8.7 + tail v028 ===
	"chilled": {
		"max_stacks":                 5,
		"stack_policy":               "stack",
		"move_speed_mult_per_stack":  -0.10,   # -50% MS at 5 stacks
		"cap_state":                  {"id": "frozen", "duration": 2.0, "consume_stacks": true},
		"display_name":               "Chilled",
		"icon_char":                  "*",
		"tint":                       Color(0.55, 0.85, 0.95, 0.95),
	},
	"frozen": {
		"max_stacks":    1,
		"stack_policy":  "refresh",
		"action_lock":   true,
		"movement_lock": true,
		"display_name":  "Frozen",
		"icon_char":     "F",
		"tint":          Color(0.40, 0.80, 1.0, 0.95),
		# NOTE: dash still works (universal rule).
	},

	# === Pepper — Combat_Boons §8.6 + tail v028b ===
	# Per stack: 3% HP/sec for 3s; max 5 stacks; +5% blind miss/stack.
	# Combust: at 5 stacks the cap_state fires "combusted" (short marker).
	# _trigger_cap_state detects cap_id == "combusted" and calls
	# _do_combust_explosion — AoE 120px burst + 2 Burn to nearby targets.
	# Only fires when RunState.combust_taken == true (Pepper Combust boon).
	"burning": {
		"max_stacks":                5,
		"stack_policy":              "stack",
		# Run 55 — DoT is now interval-based (flat BURN_TICK_DMG, cadence shrinks
		# with stacks). See _dot_interval / _dot_tick_damage. No dot_pct field.
		"miss_chance_per_stack":     0.05,
		"cap_state":                 {"id": "combusted", "duration": 0.5, "consume_stacks": true},
		"display_name":              "Burning",
		"icon_char":                 "!",
		"tint":                      Color(0.95, 0.35, 0.10, 0.95),
	},
	# Brief marker applied on Combust detonation. No mechanical effect —
	# just prevents immediate re-application of a fresh Burn cap for 0.5s.
	"combusted": {
		"max_stacks":   1,
		"stack_policy": "refresh",
		"display_name": "Combusted",
		"icon_char":    "☄",
		"tint":         Color(1.0, 0.50, 0.10, 0.95),
	},

	# === Onion — Combat_Boons §8.10 + tail v028 ===
	# 2% HP/sec/stack for 4s base, stacks 5 base (extended to 7 with Overripe,
	# 10 with Pom). Stacks refresh globally (single entry already covers this).
	"poison": {
		"max_stacks":                5,
		"stack_policy":              "stack",
		# Run 55 — DoT is now interval-based (flat POISON_TICK_DMG_PER_STACK ×
		# stacks every POISON_TICK_INTERVAL s). See _dot_interval / _dot_tick_damage.
		"display_name":              "Poison",
		"icon_char":                 "p",
		"tint":                      Color(0.70, 0.85, 0.40, 0.95),
	},

	# === Banana (default mode) — Combat_Boons §8.9 ===
	# Slippery 20% miss; Greased 40% miss. Both refresh-on-reapply.
	"slippery": {
		"max_stacks":   1,
		"stack_policy": "refresh",
		"miss_chance":  0.20,
		"display_name": "Slippery",
		"icon_char":    "s",
		"tint":         Color(0.95, 0.85, 0.30, 0.95),
	},
	"greased": {
		"max_stacks":   1,
		"stack_policy": "refresh",
		"miss_chance":  0.40,
		"display_name": "Greased",
		"icon_char":    "g",
		"tint":         Color(1.0, 0.95, 0.45, 0.95),
	},

	# === Banana (Greased Lightning mode) — Combat_Boons §8.9 ===
	# Sparked/Bolted replace Slippery/Greased. No miss. Run 27e (Bruno's spec):
	# damage comes from interval PROCS, not a flat DoT —
	#   Sparked = fast/light: small zap on host + chain lightning jumps to
	#             nearby enemies each interval (revisits targets when few
	#             are around, keeping the chain alive).
	#   Bolted  = strong/slow: large bolt strikes the host — bigger damage +
	#             small-medium AoE around them. No chain.
	"sparked": {
		"max_stacks":   1,
		"stack_policy": "refresh",
		"display_name": "Sparked",
		"icon_char":    "z",
		"tint":         Color(0.90, 0.85, 1.0, 0.95),
	},
	"bolted": {
		"max_stacks":   1,
		"stack_policy": "refresh",
		"display_name": "Bolted",
		"icon_char":    "Z",
		"tint":         Color(0.90, 0.85, 1.0, 0.95),
	},
	"shocked": {
		"max_stacks":   1,
		"stack_policy": "refresh",
		"display_name": "Shocked",
		"icon_char":    "+",
		"tint":         Color(0.85, 0.85, 1.0, 0.95),
		# Chain-target flag — Banana chain-lightning procs read .has("shocked").
	},

	# === Potato — Combat_Boons §8.8 + tail v028 ===
	# Cracked Soil: 3 stacks → next X triggers Earthbind (full Root 1.5s).
	# The 3-stack threshold is checked at the X-attack call site; here we
	# only express the per-stack slow + cap.
	"cracked_soil": {
		"max_stacks":                3,
		"stack_policy":              "stack",
		"move_speed_mult_per_stack": -0.20,
		"display_name":              "Cracked Soil",
		"icon_char":                 ".",
		"tint":                      Color(0.65, 0.50, 0.30, 0.95),
	},
	"root": {
		"max_stacks":    1,
		"stack_policy":  "refresh",
		"movement_lock": true,
		# Per Earthbind: rooted enemy CANNOT move but CAN still attack.
		# action_lock left FALSE so the spec's "rooted-but-attacking" mob behaves correctly.
		"display_name":  "Rooted",
		"icon_char":     "#",
		"tint":          Color(0.60, 0.40, 0.25, 0.95),
	},

	# === Scald/Shatter duo (Pepper+Watermelon) — Run 27e ===
	# Steam builds while Burning+Soaked coexist; Brittle while Burning+Chilled.
	# At 5 stacks: Steam → Scalded (2s panic — approximated as action lock
	# until a fear AI state exists); Brittle → Shattered (AoE burst stun,
	# fired in _trigger_cap_state).
	"steam": {
		"max_stacks":   5,
		"stack_policy": "stack",
		"cap_state":    {"id": "scalded", "duration": 2.0, "consume_stacks": true},
		"display_name": "Steam",
		"icon_char":    "≋",
		"tint":         Color(0.95, 0.75, 0.75, 0.95),
	},
	"scalded": {
		"max_stacks":   1,
		"stack_policy": "refresh",
		"action_lock":  true,
		"display_name": "Scalded",
		"icon_char":    "S",
		"tint":         Color(1.0, 0.55, 0.55, 0.95),
	},
	"brittle": {
		"max_stacks":   5,
		"stack_policy": "stack",
		"cap_state":    {"id": "shattered", "duration": 0.5, "consume_stacks": true},
		"display_name": "Brittle",
		"icon_char":    "▽",
		"tint":         Color(0.75, 0.85, 0.95, 0.95),
	},
	"shattered": {
		"max_stacks":   1,
		"stack_policy": "refresh",
		"display_name": "Shattered",
		"icon_char":    "✸",
		"tint":         Color(0.85, 0.95, 1.0, 0.95),
	},

	# === Generic crowd-control (used by future bosses + various boons) ===
	"stagger": {
		"max_stacks":    1,
		"stack_policy":  "refresh",
		"action_lock":   true,
		"display_name":  "Stagger",
		"icon_char":     "x",
		"tint":          Color(0.95, 0.70, 0.40, 0.95),
	},
	"bleed": {
		"max_stacks":                 3,
		"stack_policy":               "stack",
		"dot_flat_per_sec_per_stack": 1,   # Run 111: FLAT 1 dmg per stack per second (was %-max-HP, which was far too strong). Cap 3 stacks → max 3 dmg/sec. Only Bea applies bleed (blades + kunai).
		"display_name":               "Bleed",
		"icon_char":                  "♦",
		"tint":                       Color(0.85, 0.20, 0.25, 0.95),
	},

	# === Breakbar broken stun (Run 117) ===
	# Applied directly into _active by _trigger_breakbar_broken, bypassing
	# can_receive_status. Uses bash's movement_lock + action_lock flags.
	# Defined here so the indicator can display it.
	"breakbar_broken": {
		"max_stacks":    1,
		"stack_policy":  "refresh",
		"movement_lock": true,
		"action_lock":   true,
		"display_name":  "BROKEN",
		"icon_char":     "☆",
		"tint":          Color(0.95, 0.85, 0.20, 0.95),
	},
}


# ============================================================
# Run 122 — generic enemy → HERO on-hit status hook
# ============================================================
# Shared by every archetype host (DummyEnemy melee, FastScout contact,
# RangedShooter projectile, SlimeEnemy landing, ChargerEnemy impact,
# LaserEnemy zap). Reads the on_hit_* fields DreamSpawner.apply_config
# stamped from a roster entry ("on_hit_poison"/"on_hit_slow"/"on_hit_stun")
# and routes them through the hero's EXISTING receivers so no new DoT/CC
# system is introduced:
#   poison → hero StatusComponent.apply("poison", …)  (same path as burn)
#   slow   → hero.add_frost_stack(n)                  (Run 121 frost slow)
#   stun   → hero StatusComponent.apply("bash", …)    (movement+action lock)
# Downed / i-framed heroes are protected by their own receivers (the DoT's
# take_damage is downed-guarded; add_frost_stack early-returns when downed).
# `src` supplies the four export ints/floats a host exposes; call this once,
# right after a connecting hit is confirmed.
static func inflict_hero_status(hero: Node, src: Object) -> void:
	if hero == null or not is_instance_valid(hero) or src == null:
		return
	# Poison — flat interval DoT via the hero's own StatusComponent.
	var p_stacks: int = int(src.get("on_hit_poison_stacks"))
	if p_stacks > 0:
		var hs: Node = hero.get_node_or_null("StatusComponent")
		if hs and hs.has_method("apply"):
			hs.apply("poison", float(src.get("on_hit_poison_duration")), p_stacks)
	# Slow — frost stacks (Popsicle-Pelican path). Heroes expose add_frost_stack.
	var slow_n: int = int(src.get("on_hit_slow_stacks"))
	if slow_n > 0 and hero.has_method("add_frost_stack"):
		hero.add_frost_stack(slow_n)
	# Stun — short Bash (movement + action lock).
	var stun_dur: float = float(src.get("on_hit_stun_duration"))
	if stun_dur > 0.0:
		var hs2: Node = hero.get_node_or_null("StatusComponent")
		if hs2 and hs2.has_method("apply"):
			hs2.apply("bash", stun_dur, 1)
