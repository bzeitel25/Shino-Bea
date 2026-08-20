extends Node

# ============================================================
# FX.gd — global feel/polish bus (Phase 7)
# ============================================================
# Autoload singleton. Centralizes:
#   - Screen shake (any system calls FX.screen_shake(magnitude, duration)
#     and CameraFollow.gd reads `get_shake_offset()` each frame)
#   - Hit particles (small ColorRect bursts at world positions)
#   - Sound event stubs (prints for now — wire real AudioStreams later)
#   - Fade overlay helper for scene transitions / death
#   - **Boss broadcast bus** (Run 15): boss_registered / boss_unregistered /
#     boss_hp_changed / boss_phase_changed. HUD subscribes; BossEnemy emits.
#     This keeps the HUD from needing to scan the scene tree for boss nodes,
#     and supports arena transitions cleanly (boss_unregistered fires on
#     queue_free + scene teardown).
#
# Keeping all of this in one autoload means combat code doesn't need to
# know which scene-tree node owns the camera or audio bus — it just calls
# FX.X(...) and the autoload handles routing.
#
# Registered in project.godot as:   FX = "*res://scripts/FX.gd"
# ============================================================

# -------------------------------------------------------
# Boss broadcast bus (Run 15)
# -------------------------------------------------------
# Bosses call register_boss(self) on _ready and unregister_boss(self) on
# death / _exit_tree. HUD listens on the signals below to show/hide and
# refresh the dedicated boss HP bar.
signal boss_registered(boss: Node)
signal boss_unregistered(boss: Node)
signal boss_hp_changed(current_hp: int, max_hp: int, boss_name: String)
signal boss_phase_changed(phase: int, max_phase: int)
signal boss_breakbar_changed(current: float, max_val: float, is_broken: bool)   # Run 117

# Currently-active boss (one at a time for the prototype — arena 3 only).
# HUD uses this to seed its state on hot-reload.
var current_boss: Node = null


func register_boss(boss: Node) -> void:
	if boss == null:
		return
	current_boss = boss
	emit_signal("boss_registered", boss)


func unregister_boss(boss: Node) -> void:
	if current_boss == boss:
		current_boss = null
	emit_signal("boss_unregistered", boss)


func notify_boss_hp(current_hp: int, max_hp: int, boss_name: String) -> void:
	emit_signal("boss_hp_changed", current_hp, max_hp, boss_name)


func notify_boss_phase(phase: int, max_phase: int) -> void:
	emit_signal("boss_phase_changed", phase, max_phase)


func notify_boss_breakbar(current: float, max_val: float, is_broken: bool) -> void:
	emit_signal("boss_breakbar_changed", current, max_val, is_broken)

# -------------------------------------------------------
# Screen shake
# -------------------------------------------------------
var _shake_magnitude: float = 0.0
var _shake_duration: float = 0.0
var _shake_max_for_run: float = 0.0   # peak magnitude this shake event was requested at; decays toward 0

const SHAKE_VERBOSE: bool = false

# Loudness "presets" — combat code uses these so we have one place to tune.
const SHAKE_LIGHT: float = 2.5
const SHAKE_MEDIUM: float = 5.0
const SHAKE_HEAVY: float = 9.0
const SHAKE_ULT: float = 14.0

const SHAKE_DUR_TINY: float = 0.08
const SHAKE_DUR_SHORT: float = 0.18
const SHAKE_DUR_MED: float = 0.35
const SHAKE_DUR_LONG: float = 0.55


func _process(delta: float) -> void:
	if _shake_duration > 0.0:
		_shake_duration -= delta
		# Linear decay so the screen calms down across the shake window
		var t: float = clamp(_shake_duration / max(0.001, _shake_max_for_run_duration()), 0.0, 1.0)
		_shake_magnitude = _shake_max_for_run * t
		if _shake_duration <= 0.0:
			_shake_magnitude = 0.0
			_shake_max_for_run = 0.0


func _shake_max_for_run_duration() -> float:
	# Cached "duration at which we started this shake" — we set it at the time of request.
	return _shake_max_duration_started


var _shake_max_duration_started: float = 0.01


func screen_shake(magnitude: float, duration: float) -> void:
	# Run 54 — scale every shake by the player's Settings preference
	# (shake_intensity, or 0 when shake is disabled). Done here so all call
	# sites are covered and a 0 setting fully silences the screen.
	# Phase 6a — capture the UNSCALED request before the shake setting is
	# applied. Rumble is driven off this raw value and fired before the early
	# return below, because screen shake and rumble are separate accessibility
	# choices: a player who turns shake off (motion sensitivity) should keep
	# their haptics, and lowering shake intensity should not quietly halve them.
	var raw_magnitude: float = magnitude

	var _s := get_node_or_null("/root/Settings")
	if _s and _s.has_method("get_shake_mult"):
		magnitude *= _s.get_shake_mult()

	# NOTE (2026-08-01): screen shake NO LONGER drives rumble. Bruno's rule is
	# that haptics fire on a hit CONNECTING, from the ninja that player is
	# controlling — whereas screen_shake also fires on whiffs, on the partner's
	# attacks, and on world events. Rumble is now raised explicitly at the
	# connect/charge sites instead. See hit_rumble() / charge_rumble() below.
	# `raw_magnitude` is retained for the shake logic only.

	if magnitude <= 0.0:
		return
	# If a louder shake comes in, override; otherwise leave existing in place.
	# This avoids small shakes (eg every melee tick) trampling a big one (eg Ult).
	if magnitude > _shake_max_for_run or _shake_duration <= 0.0:
		_shake_max_for_run = magnitude
		_shake_max_duration_started = duration
		_shake_duration = duration
		_shake_magnitude = magnitude
	if SHAKE_VERBOSE:
		Log.dbg("[FX] shake mag=%.1f dur=%.2fs" % [magnitude, duration])


# -------------------------------------------------------
# Phase 6a — controller rumble
# -------------------------------------------------------
# The game shipped with no haptics at all. Rather than add rumble calls to
# ~110 impact sites, it hangs off screen_shake() — the one function every
# impact in the game already calls — so rumble intensity automatically tracks
# what the screen is doing and stays consistent for free.
#
# In 2P both pads buzz: the screen shake is a shared-screen effect, so shared
# haptics match it. In 1P there is normally one pad and it just works.
#
# Godot's API is start_joy_vibration(device, weak, strong, duration):
#   weak   = the high-frequency buzzy motor
#   strong = the low-frequency rumble motor
# Mapping magnitude to mostly-strong with a little weak reads as "impact"
# rather than "phone notification".
const RUMBLE_REF_MAGNITUDE: float = 14.0   # SHAKE_ULT — the loudest normal shake

# ── IMPACT MODEL (Bruno's spec, 2026-08-01) ─────────────────
# "Each hit is a split-second Bzzt. Bzzt. Bzzt. for each hit in a 4-hit combo.
#  The vibration should never last longer than it takes for the next hit to
#  land, so there is no spillover from one hit's buzz into the next."
#
# So rumble is a PULSE, not a sustain. Every hit re-triggers; loudness is
# expressed through motor STRENGTH, never through duration.
#
# The numbers are derived from the game's real attack cadence:
#   Shino.ATTACK_ANIM_DURATION   = 0.20s per combo slice  <- the normal case
#   Bea.KATANA_COMBO_STEPS/WINDOW= 4 hits / 0.70s
#   Bea.SHURIKEN_WAVE_INTERVAL   = 0.05s                  <- the tightest burst
#
# PULSE (0.06s) < RETRIGGER GAP (0.07s) is the guarantee: two pulses can never
# overlap, so there is always at least ~10ms of silence between them and each
# hit is felt as its own tap.
#
# WHY 70ms AND NOT HIGHER
# A longer retrigger window (110ms+) would fold Bea's 3-wave shuriken volley
# into a single tap, which is tidier. It was rejected because attack speed is an
# UNCAPPED multiplier (Shino.gd:2087 — get_char_attack_speed_mult has a floor,
# no ceiling), so a boon-heavy build compresses the 200ms combo cadence toward
# 100ms. At 110ms the game would start silently DROPPING combo hits on exactly
# the builds that hit hardest — a direct violation of "a bzzt for every hit".
# 70ms keeps every combo hit at any realistic attack speed.
#
# The accepted trade: the 0.05s shuriken volley (t=0/50/100) yields two pulses
# rather than one. They still do not overlap, and two quick taps read fine as a
# flurry — this is a cosmetic imperfection, not a spec violation.
const RUMBLE_PULSE_SEC: float = 0.06       # the "bzzt"
const RUMBLE_RETRIGGER_MS: int = 70        # must exceed RUMBLE_PULSE_SEC
const RUMBLE_MIN_DURATION: float = 0.02    # ⚠ Godot treats duration 0 as INFINITE
const RUMBLE_MAX_DURATION: float = 0.35    # ceiling for explicit sustained calls

# Preset strengths for the three haptic events.
const RUMBLE_HIT: float          = 0.75   # a hit connecting
const RUMBLE_HIT_HEAVY: float    = 1.00   # finisher / charged release
const RUMBLE_CHARGE_READY: float = 0.28   # tiny "you can let go now" tick
const RUMBLE_HURT: float         = 0.65   # you took a hit

## Last pulse per DEVICE, not global. In local 2P each player has their own
## no-overlap window, so P1 mid-combo can never swallow P2's hits.
var _rumble_last_ms_by_dev: Dictionary = {}


# ---------------------------------------------------------------------------
# Targeted haptics  (Bruno's spec 2026-08-01)
# ---------------------------------------------------------------------------
# Rumble belongs to the PLAYER WHO CAUSED IT, and only fires when something
# actually happens — a hit connecting, a charge coming ready, a charge
# releasing. Never on a whiff, never from the AI partner's attacks, and never
# from the other player's hits in local 2P.
#
# Screen shake stays global and shared (it is one screen), which is exactly why
# the two systems are now decoupled: shake is about the SCENE, rumble is about
# YOUR hands.

## A hit from `who` ("shino"/"bea") connected. Call at the moment damage lands.
## Safe to call in an AoE loop — the per-device retrigger window collapses a
## multi-enemy hit into one pulse, so a 5-enemy sweep is one bzzt, while a
## 4-hit combo is four.
func hit_rumble(who: String, heavy: bool = false) -> void:
	var strength: float = RUMBLE_HIT_HEAVY if heavy else RUMBLE_HIT
	pulse_for_hero(who, strength)


## Charge state feedback. `ready` = the tiny tick when the charge is armed;
## otherwise the fuller thump on release.
func charge_rumble(who: String, ready: bool) -> void:
	if ready:
		pulse_for_hero(who, RUMBLE_CHARGE_READY)
	else:
		pulse_for_hero(who, RUMBLE_HIT_HEAVY)


## `who` took damage — buzz their own pad only.
func hurt_rumble(who: String) -> void:
	pulse_for_hero(who, RUMBLE_HURT)


## Core entry point: pulse the pad(s) belonging to hero `who`.
## `strength` is 0..1 BEFORE the player's rumble-strength multiplier.
func pulse_for_hero(who: String, strength: float, duration: float = RUMBLE_PULSE_SEC) -> void:
	_pulse(_devices_for_hero(who), strength * 0.55, strength, duration)


## Resolves which physical pads should feel an event caused by `who`.
##
## Returns EMPTY (no rumble) when:
##   * that hero is AI-controlled — you only feel your own ninja
##   * that hero's device is the keyboard (-1)
##   * rumble is disabled or no pad is connected
func _devices_for_hero(who: String) -> Array:
	var hero: Node = null
	for p in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(p) and "hero_id" in p and String(p.hero_id) == who:
			hero = p
			break
	if hero == null:
		return []
	# Only the ninja the player is actually driving produces haptics.
	if "player_controlled" in hero and not bool(hero.player_controlled):
		return []

	var rs: Node = get_node_or_null("/root/RunState")
	if rs != null and "two_player" in rs and bool(rs.two_player):
		# Local 2P: route strictly to that player's own pad.
		var dev: int = -1
		if who == "shino" and "shino_device" in rs:
			dev = int(rs.shino_device)
		elif who == "bea" and "bea_device" in rs:
			dev = int(rs.bea_device)
		return [dev] if dev >= 0 else []   # -1 = keyboard, nothing to buzz

	# 1P (and online, where each machine has one local player): whatever pad
	# this machine has.
	return Input.get_connected_joypads()


## Low-level pulse. Enforces the settings check and the per-device no-overlap
## guarantee. `weak`/`strong` are pre-multiplier.
func _pulse(devices: Array, weak: float, strong: float, duration: float) -> void:
	if devices.is_empty():
		return
	var s := get_node_or_null("/root/Settings")
	var mult: float = 1.0
	if s and s.has_method("get_rumble_mult"):
		mult = float(s.get_rumble_mult())
	if mult <= 0.0:
		return   # rumble disabled — entirely independent of the shake setting

	var s_mag: float = clampf(strong * mult, 0.0, 1.0)
	var w_mag: float = clampf(weak * mult, 0.0, 1.0)
	if s_mag <= 0.0 and w_mag <= 0.0:
		return

	var dur: float = clampf(duration, RUMBLE_MIN_DURATION, RUMBLE_MAX_DURATION)
	var now: int = Time.get_ticks_msec()
	for dev in devices:
		var last: int = int(_rumble_last_ms_by_dev.get(dev, -100000))
		if now - last < RUMBLE_RETRIGGER_MS:
			continue   # would overlap this pad's previous pulse
		_rumble_last_ms_by_dev[dev] = now
		Input.start_joy_vibration(dev, w_mag, s_mag, dur)


## For the rare genuinely-sustained moment (team defeat, a boss landing).
func rumble_sustained(who: String, strength: float, duration: float) -> void:
	pulse_for_hero(who, strength, clampf(duration, RUMBLE_PULSE_SEC, RUMBLE_MAX_DURATION))


## Immediately silences all pads — used when the player turns rumble off.
func stop_rumble() -> void:
	_rumble_last_ms_by_dev.clear()
	for dev in Input.get_connected_joypads():
		Input.stop_joy_vibration(dev)


func get_shake_offset() -> Vector2:
	if _shake_magnitude <= 0.01:
		return Vector2.ZERO
	return Vector2(
		randf_range(-_shake_magnitude, _shake_magnitude),
		randf_range(-_shake_magnitude, _shake_magnitude)
	)


# -------------------------------------------------------
# Hit particles — simple ColorRect bursts
# -------------------------------------------------------
# `count` small squares spawned at `pos`, each fly outward and fade.
# Parented to current scene so they get freed on scene change.
func spawn_hit_particles(pos: Vector2, color: Color = Color(1.0, 0.85, 0.20, 1.0), count: int = 8, parent: Node = null) -> void:
	if parent == null:
		parent = get_tree().current_scene
	if parent == null:
		return
	for i in count:
		var p := ColorRect.new()
		p.color = color
		p.size = Vector2(4, 4)
		p.position = pos - Vector2(2, 2)
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		parent.add_child(p)
		var dir: Vector2 = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0))
		if dir.length() < 0.01:
			dir = Vector2.RIGHT
		dir = dir.normalized()
		var dist: float = randf_range(20.0, 56.0)
		var dur: float = randf_range(0.22, 0.45)
		var tw := create_tween()
		tw.set_parallel(true)
		tw.tween_property(p, "position", p.position + dir * dist, dur)
		tw.tween_property(p, "color:a", 0.0, dur)
		tw.set_parallel(false)
		tw.tween_callback(Callable(p, "queue_free"))


# Bigger burst variant — used for charge-release & ult hits
func spawn_burst_particles(pos: Vector2, color: Color = Color(1.0, 0.95, 0.40, 1.0), count: int = 16, parent: Node = null) -> void:
	spawn_hit_particles(pos, color, count, parent)


# -------------------------------------------------------
# Swing arc visualization (Run 26c — Bruno's polish ask)
# -------------------------------------------------------
# Spawns a brief colored wedge in front of the attacker so the player can
# actually see where the hitbox is sweeping. Polygon2D is built as a triangle
# fan from the attacker's position, sweeping `arc_deg` total degrees around
# `facing`. Fades out and frees itself in `duration` seconds.
#
# Parameters:
#   pos       — origin position (typically attacker.global_position)
#   facing    — Vector2 unit direction; defines where the arc points
#   radius    — how far in front the arc reaches (pixels)
#   arc_deg   — angular span of the wedge (60-140 typical)
#   color     — fill color (RGBA; alpha applied at start)
#   duration  — fade-out duration
func spawn_swing_arc(pos: Vector2, facing: Vector2, radius: float = 56.0,
		arc_deg: float = 80.0, color: Color = Color(1.0, 0.92, 0.40, 0.55),
		duration: float = 0.16, parent: Node = null) -> void:
	if parent == null:
		parent = get_tree().current_scene
	if parent == null:
		return
	if facing.length() < 0.01:
		facing = Vector2.RIGHT
	facing = facing.normalized()
	var poly := Polygon2D.new()
	poly.color = color
	poly.position = pos
	# Build the fan: center + arc points sampled around `facing` over arc_deg.
	var pts: PackedVector2Array = PackedVector2Array()
	pts.append(Vector2.ZERO)
	var center_a: float = facing.angle()
	var half_a: float = deg_to_rad(arc_deg) * 0.5
	var seg: int = 14
	for i in range(seg + 1):
		var t: float = float(i) / float(seg)
		var a: float = lerp(center_a - half_a, center_a + half_a, t)
		pts.append(Vector2(cos(a), sin(a)) * radius)
	poly.polygon = pts
	poly.z_index = 5   # render above floor, below HUD
	parent.add_child(poly)
	# Fade + slight scale-out for a "swoosh" feel.
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(poly, "color:a", 0.0, duration)
	tw.tween_property(poly, "scale", Vector2(1.18, 1.18), duration)
	tw.set_parallel(false)
	tw.tween_callback(Callable(poly, "queue_free"))


# -------------------------------------------------------
# Run 47 — Punch comets + hook sweep (Bruno's combat-feel pass)
# -------------------------------------------------------
# Shared teardrop-comet builder: glowing head with a tapering tail pointing
# back along the travel path. Flies from `from_pos` to `to_pos` and fades.
func _spawn_comet(from_pos: Vector2, to_pos: Vector2,
		color: Color, duration: float, size: float, parent: Node) -> void:
	if parent == null:
		parent = get_tree().current_scene
	if parent == null:
		return
	var travel: Vector2 = to_pos - from_pos
	if travel.length() < 0.01:
		travel = Vector2.RIGHT
	var comet := Polygon2D.new()
	var pts := PackedVector2Array()
	var head_r: float = size * 0.5
	var steps: int = 10
	for i in range(steps + 1):
		var a: float = lerp(-PI * 0.55, PI * 0.55, float(i) / float(steps))
		# Run 48 — head stretched 1.35× laterally so the comet reads wide,
		# not needle-thin (chi-enhanced impact).
		pts.append(Vector2(cos(a) * head_r, sin(a) * head_r * 1.35))
	pts.append(Vector2(-size * 2.2, 0.0))   # tail tip trails behind the head
	comet.polygon = pts
	comet.color = color
	comet.position = from_pos
	comet.rotation = travel.angle()
	comet.z_index = 5
	parent.add_child(comet)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(comet, "position", to_pos, duration)\
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.tween_property(comet, "color:a", 0.0, duration * 1.35)
	tw.set_parallel(false)
	tw.tween_callback(Callable(comet, "queue_free"))


# Punch comet — replaces the cone flash for Y jab/cross so punches read as a
# little comet flying FROM Shino TO the target point.
func spawn_punch_comet(pos: Vector2, facing: Vector2, reach: float = 52.0,
		color: Color = Color(1.0, 0.92, 0.45, 0.85), duration: float = 0.12,
		size: float = 7.0, parent: Node = null) -> void:
	if facing.length() < 0.01:
		facing = Vector2.RIGHT
	facing = facing.normalized()
	_spawn_comet(pos + facing * 10.0, pos + facing * reach, color, duration, size, parent)


# Uppercut comet — low-to-high rising comet right in front of the attacker,
# selling the down-to-up motion of the Y4 uppercut.
func spawn_uppercut_comet(pos: Vector2, facing: Vector2,
		color: Color = Color(1.0, 0.95, 0.30, 0.85), duration: float = 0.22,
		parent: Node = null) -> void:
	if facing.length() < 0.01:
		facing = Vector2.RIGHT
	facing = facing.normalized()
	var from_pos: Vector2 = pos + facing * 28.0 + Vector2(0, 16.0)
	var to_pos: Vector2 = pos + facing * 38.0 + Vector2(0, -36.0)
	_spawn_comet(from_pos, to_pos, color, duration, 8.0, parent)


# Hook sweep — crescent swoosh (Bruno's chakram-swipe screenshot ref, scaled
# down for barehand) that sweeps across the attacker's front from their left
# to their right, like a left-hand hook punch. The crescent is parented to a
# pivot whose rotation tweens across the frontal arc while fading.
# `sweep_sign` flips the sweep direction: 1.0 = attacker's left → right,
# -1.0 = right → left (Run 48 — mirrored roundhouse kicks alternate legs).
func spawn_hook_sweep(pos: Vector2, facing: Vector2, radius: float = 52.0,
		color: Color = Color(1.0, 0.70, 0.25, 0.65), duration: float = 0.18,
		sweep_sign: float = 1.0, parent: Node = null) -> void:
	if parent == null:
		parent = get_tree().current_scene
	if parent == null:
		return
	if facing.length() < 0.01:
		facing = Vector2.RIGHT
	facing = facing.normalized()
	var pivot := Node2D.new()
	pivot.position = pos
	pivot.z_index = 5
	var cres := Polygon2D.new()
	var pts := PackedVector2Array()
	var seg: int = 12
	var half: float = deg_to_rad(38.0)
	# Outer edge of the crescent…
	for i in range(seg + 1):
		var a: float = lerp(-half, half, float(i) / float(seg))
		pts.append(Vector2(cos(a), sin(a)) * radius)
	# …then back along the inner edge, fattest at center, tapering at the tips.
	for i in range(seg + 1):
		var a2: float = lerp(half, -half, float(i) / float(seg))
		var center_t: float = 1.0 - absf(a2) / half     # 1 center → 0 tips
		var inner_r: float = radius * (1.0 - 0.34 * center_t)
		pts.append(Vector2(cos(a2), sin(a2)) * inner_r)
	cres.polygon = pts
	cres.color = color
	pivot.add_child(cres)
	parent.add_child(pivot)
	# Sweep across the front; sweep_sign picks which side it starts from.
	pivot.rotation = facing.angle() - deg_to_rad(55.0) * sweep_sign
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(pivot, "rotation", facing.angle() + deg_to_rad(55.0) * sweep_sign, duration)\
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(cres, "color:a", 0.0, duration * 1.25)
	tw.set_parallel(false)
	tw.tween_callback(Callable(pivot, "queue_free"))


# Side-kick / push-attack rectangle (Run 26e — Bruno's spec). Spawns a
# forward-pointing rectangle aligned with `facing` so the player can read
# the side-kick's straight-rectangular hitbox vs. an arc roundhouse.
# Forward dimension = length; sideways dimension = width.
# `slide` (Run 48): pixels the rect travels forward along `facing` while it
# fades — sells push-out motion instead of a static flash (push kick).
func spawn_swing_rect(pos: Vector2, facing: Vector2, length: float = 70.0,
		width: float = 36.0, color: Color = Color(0.85, 0.55, 1.0, 0.60),
		duration: float = 0.20, slide: float = 0.0, parent: Node = null) -> void:
	if parent == null:
		parent = get_tree().current_scene
	if parent == null:
		return
	if facing.length() < 0.01:
		facing = Vector2.RIGHT
	facing = facing.normalized()
	var poly := Polygon2D.new()
	poly.color = color
	poly.position = pos
	var fwd: Vector2 = facing
	var side: Vector2 = facing.rotated(PI * 0.5)
	# Rectangle from player position forward, centered on facing line.
	# Corners: front-left, front-right, back-right, back-left.
	var pts: PackedVector2Array = PackedVector2Array()
	pts.append(fwd * 6.0 + side * (width * 0.5))    # back-left (slight inset)
	pts.append(fwd * length + side * (width * 0.5))  # front-left
	pts.append(fwd * length + side * (-width * 0.5)) # front-right
	pts.append(fwd * 6.0 + side * (-width * 0.5))   # back-right
	poly.polygon = pts
	poly.z_index = 5
	parent.add_child(poly)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(poly, "color:a", 0.0, duration)
	# Slight forward stretch as it fades — sells the "push" motion.
	tw.tween_property(poly, "scale", Vector2(1.10, 1.0), duration)
	if slide > 0.0:
		tw.tween_property(poly, "position", pos + facing * slide, duration)\
			.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.set_parallel(false)
	tw.tween_callback(Callable(poly, "queue_free"))


# ============================================================
# Run 60 — sprite-based Y-combo punch impacts (Bruno's blue-impact sheet).
# ============================================================
# Replaces the procedural Polygon2D comets/sweeps for Shino's Y combo with
# the hand-keyed blue impact frames extracted from "Punch impacts.png".
# Each impact is a 3-frame horizontal strip (hframes=3) that plays fast and
# fades; the uppercut additionally rises a translucent dragon silhouette as a
# finishing flair. All sizing/timing is tunable via the constants below.
#
#   kind: "jab" | "cross" | "hook" | "uppercut"
#   jab/cross — comet flies forward along `facing` (anchored at the fist).
#   hook      — crescent sweep oriented along `facing`.
#   uppercut  — rises in screen-space just ahead of the attacker (+ dragon).
const IMPACT_TEX: Dictionary = {
	"jab":      "res://Assets/Sprites/impact_jab.png",
	"cross":    "res://Assets/Sprites/impact_cross.png",
	"hook":     "res://Assets/Sprites/impact_hook.png",
	"uppercut": "res://Assets/Sprites/impact_uppercut.png",
	"dragon":   "res://Assets/Sprites/impact_dragon.png",
}
const IMPACT_SCALE: float        = 0.22   # global on-screen scale (tunable)
const IMPACT_FRAME_TIME: float   = 0.040  # seconds per frame (3 frames) — snappy but readable
const IMPACT_FADE: float         = 0.11   # fade-out after last frame
const IMPACT_ALPHA: float        = 0.82   # base opacity — ethereal, see-through punch
const IMPACT_DRAGON_ENABLED: bool = true  # uppercut dragon finisher toggle
const IMPACT_DRAGON_DEBUG: bool   = true  # prints spawn pos/scale to Output (flip false to silence)
const IMPACT_DRAGON_ALPHA: float  = 0.78  # settled opacity — mostly visible, slight ethereal transparency
# Run 61 — the jab/cross art is hand-drawn on a diagonal: the bright head leads
# ~29° down-right of the texture's +X axis. We subtract that so the comet flies
# straight along the AIMED direction (snapped to the 8 isometric dirs) instead
# of always veering off-axis. Per-kind so each strip can be tuned independently.
const IMPACT_FWD_DEG: Dictionary = {"jab": 30.0, "cross": 28.0}
# Run 68c — Jab & cross spawn FROM Shino's hands, using the SAME hand points as
# his Ki blasts (Player KI_HAND_OFFSET). The comet is centered on the hand with a
# small forward nudge + a lift to hand height, so it reads as a punch coming from
# him rather than a streak floating to his side.
#   Jab   = his LEFT  hand = facing.orthogonal() * +IMPACT_HAND_OFFSET
#   Cross = his RIGHT hand = facing.orthogonal() * -IMPACT_HAND_OFFSET
# If the two hands read swapped on your camera, flip the sign of the two
# `hand_side` lines in the "jab"/"cross" cases (one character each).
const IMPACT_HAND_OFFSET: float = 12.0   # lateral px to a hand (matches KI_HAND_OFFSET)
const IMPACT_HAND_FWD: float    = 12.0   # forward nudge so the comet sits in front of the hand
const IMPACT_HAND_LIFT: float   = 16.0   # px up from body origin to hand height
const IMPACT_JAB_INWARD_DEG: float = 12.0  # toe the jab's tip inward toward Shino's aim center
const IMPACT_JAB_X_NUDGE: float    = 5.0   # small extra px toward the hand side for alignment
const IMPACT_JAB_LATERAL_MULT: float = 0.35  # pull the jab in toward body (was floating to his side)
const IMPACT_JAB_FWD_EXTRA: float    = 9.0   # extra forward push so it reads in front of his fist
# Run 68d — Rising-dragon finisher: a BIG spirit dragon that soars steadily up
# out of the uppercut and dissolves the whole way, hitting alpha 0 exactly as it
# reaches the top. Rise and fade share ONE timeline (RISE_TIME) so there's no
# bottom-pop / top-flash — it reads as a single continuous rising dissolve,
# launched at the uppercut's knockup peak.
const IMPACT_DRAGON_START_DELAY: float = 0.08   # born right on the punch contact, rides into the knockup
const IMPACT_DRAGON_RISE: float        = 78.0   # px it soars above the hero over its life
const IMPACT_DRAGON_BURST_TIME: float  = 0.06   # quick fade-in at launch
const IMPACT_DRAGON_RISE_TIME: float   = 0.80   # total soar/dissolve duration (motion == fade)
const IMPACT_DRAGON_START_SCALE: float = 0.8    # ×base_scale at spawn
const IMPACT_DRAGON_PEAK_SCALE: float  = 1.5    # ×base_scale — grows to a bit bigger than Shino
# Hook = a real hook punch: the crescent orbits across Shino's front (one side to
# the other) with the bright head leading, rather than sitting as a static curve.
# The crescent is a ~60px-wide bowl (273×139 frame × IMPACT_SCALE), oriented by
# CRESCENT_DEG so its width spans laterally across Shino's front and its depth
# points radially outward. RADIUS pushes that bowl OUT to punch reach so it sits
# clearly in FRONT of him (far edge ≈ RADIUS + ~15 ≈ jab/cross reach of 52),
# instead of hugging his body and wrapping past his sides. ARC is now a short
# swipe so the bowl stays in front rather than orbiting around him.
const IMPACT_HOOK_RADIUS: float   = 30.0   # px out from Shino the bowl rides (pulled in so it hugs him, not floating out front)
const IMPACT_HOOK_ARC: float      = 24.0   # half-arc (deg) swept each side of facing → 48° quick swipe, no wrap-around
const IMPACT_HOOK_TIME: float     = 0.18   # sweep duration — snappy hook
const IMPACT_HOOK_CRESCENT_DEG: float = 90.0  # local spin so the bowl cups across his front
const IMPACT_HOOK_LIFT: float     = 10.0   # px UP from body origin so the bowl sits at fist height, low in front of him
const IMPACT_HOOK_AIM_BIAS: float = 14.0   # deg clockwise offset on the whole sweep → head nudged right, tail left, bowl recentered on Shino
# Translate the whole bowl in FACING-RELATIVE space so the tail stops emanating
# from Shino's body. FWD pushes it out in front of him (along facing); SIDE
# slides it to one side (along facing's right). Both rotate with his facing, so
# the offset stays correct whichever way he's punching. Flip SIDE's sign if the
# tail lands on the wrong side.
const IMPACT_HOOK_FWD: float      = 6.0    # px forward along facing — lifts the tail off his body
const IMPACT_HOOK_SIDE: float     = 12.0   # px to his right (along facing.orthogonal()); negative = his left
var _impact_cache: Dictionary = {}

# Snap a direction to the nearest of the 8 isometric directions (45° steps).
func _snap8(v: Vector2) -> Vector2:
	if v.length() < 0.01:
		return Vector2.RIGHT
	var step: float = TAU / 8.0
	var a: float = round(v.angle() / step) * step
	return Vector2(cos(a), sin(a))

func _impact_texture(key: String) -> Texture2D:
	if _impact_cache.has(key):
		return _impact_cache[key]
	var t: Texture2D = null
	if IMPACT_TEX.has(key) and ResourceLoader.exists(IMPACT_TEX[key]):
		t = load(IMPACT_TEX[key])
	_impact_cache[key] = t
	return t


func spawn_punch_impact(kind: String, pos: Vector2, facing: Vector2,
		scale_mul: float = 1.0, parent: Node = null) -> void:
	if parent == null:
		parent = get_tree().current_scene
	if parent == null:
		return
	var tex: Texture2D = _impact_texture(kind)
	if tex == null:
		return
	if facing.length() < 0.01:
		facing = Vector2.RIGHT
	facing = facing.normalized()
	var frames: int = 3
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.hframes = frames
	spr.frame = 0
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.z_index = 6
	var cw: float = float(tex.get_width()) / float(frames)
	var ch: float = float(tex.get_height())
	var s: float = IMPACT_SCALE * scale_mul
	spr.scale = Vector2(s, s)
	spr.modulate.a = IMPACT_ALPHA            # ethereal see-through punch
	var hook_pivot: Node2D = null
	match kind:
		"jab":
			# Jab comes from Shino's LEFT hand (same hand point as his Ki blasts),
			# centered on the hand + a small forward nudge so it reads as a punch
			# coming from him, not a streak floating to his side.
			var snapped_j: Vector2 = _snap8(facing)
			var off_j: float = IMPACT_FWD_DEG.get("jab", 30.0)
			var hand_side_j: float = IMPACT_HAND_OFFSET            # LEFT hand
			spr.scale = Vector2(s * 1.55, s * 1.18)  # Run 111 — jab bumped up (was 1.25/0.95)
			spr.offset = Vector2.ZERO
			# Toe the tip inward toward center (clockwise/+), mirroring how the
			# cross reads — so the jab doesn't aim outward to his left.
			spr.rotation = snapped_j.angle() - deg_to_rad(off_j) + deg_to_rad(IMPACT_JAB_INWARD_DEG)
			# Hand offset + a small extra nudge toward the hand side. Both use
			# orthogonal(), so they rotate with his facing (east/west/north/south).
			spr.position = pos + snapped_j.orthogonal() * (hand_side_j + IMPACT_JAB_X_NUDGE) * IMPACT_JAB_LATERAL_MULT \
				+ snapped_j * (IMPACT_HAND_FWD + IMPACT_JAB_FWD_EXTRA) + Vector2(0.0, -IMPACT_HAND_LIFT)
		"cross":
			# Cross comes from Shino's RIGHT hand (same hand point as his Ki blasts),
			# centered on the hand + small forward nudge, like the jab mirrored.
			var snapped: Vector2 = _snap8(facing)
			var off_deg: float = IMPACT_FWD_DEG.get("cross", 28.0)
			var hand_side_c: float = -IMPACT_HAND_OFFSET           # RIGHT hand
			# Run 136 — cross texture is ~1.77× jab pixels (855×177 vs 483×101),
			# so scale it DOWN to match the jab's on-screen footprint, and push
			# it further forward so the comet reads in front of Shino.
			var cross_pixel_ratio: float = 483.0 / 855.0   # jab_w / cross_w
			spr.scale = Vector2(s * 1.55 * cross_pixel_ratio, s * 1.18 * cross_pixel_ratio * 1.45)
			spr.offset = Vector2.ZERO
			spr.rotation = snapped.angle() - deg_to_rad(off_deg)
			spr.position = pos + snapped.orthogonal() * hand_side_c * IMPACT_JAB_LATERAL_MULT \
				+ snapped * (IMPACT_HAND_FWD + IMPACT_JAB_FWD_EXTRA + 6.0) + Vector2(0.0, -IMPACT_HAND_LIFT)
		"hook":
			# Real hook punch: crescent orbits across the front (one side → other),
			# bright head leading, like a horizontal swipe around Shino.
			var snapped_h: Vector2 = _snap8(facing)
			hook_pivot = Node2D.new()
			# Place the pivot IN FRONT of Shino (facing-relative forward + side) and
			# lifted to fist height, so the bowl — tail included — sits ahead of him
			# instead of the tail emanating from his body.
			hook_pivot.position = pos \
				+ snapped_h * IMPACT_HOOK_FWD \
				+ snapped_h.orthogonal() * IMPACT_HOOK_SIDE \
				+ Vector2(0.0, -IMPACT_HOOK_LIFT)
			hook_pivot.z_index = 6
			parent.add_child(hook_pivot)
			hook_pivot.add_child(spr)
			spr.offset = Vector2.ZERO
			spr.flip_v = true                       # crescent was upside-down
			spr.position = Vector2(IMPACT_HOOK_RADIUS, 0.0)
			spr.rotation = deg_to_rad(IMPACT_HOOK_CRESCENT_DEG)
			var hook_bias: float = deg_to_rad(IMPACT_HOOK_AIM_BIAS)
			hook_pivot.rotation = snapped_h.angle() + hook_bias - deg_to_rad(IMPACT_HOOK_ARC)
			var sweep := create_tween()
			sweep.tween_property(hook_pivot, "rotation",
				snapped_h.angle() + hook_bias + deg_to_rad(IMPACT_HOOK_ARC), IMPACT_HOOK_TIME)\
				.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
		"uppercut":
			# Anchor bottom-center; rises in screen-space, nudged toward facing.
			spr.offset = Vector2(0.0, -ch * 0.5)
			spr.position = pos + facing * 20.0 + Vector2(0.0, 8.0)
		_:
			spr.offset = Vector2(cw * 0.5, 0.0)
			spr.rotation = facing.angle()
			spr.position = pos + facing * 10.0
	if spr.get_parent() == null:
		parent.add_child(spr)
	var tw := create_tween()
	for i in range(1, frames):
		tw.tween_interval(IMPACT_FRAME_TIME)
		tw.tween_callback(Callable(spr, "set_frame").bind(i))
	tw.tween_interval(IMPACT_FRAME_TIME)
	tw.tween_property(spr, "modulate:a", 0.0, IMPACT_FADE)
	tw.tween_callback(Callable(spr, "queue_free"))
	if hook_pivot != null:
		tw.tween_callback(Callable(hook_pivot, "queue_free"))
	if kind == "uppercut" and IMPACT_DRAGON_ENABLED:
		_spawn_dragon_finisher(pos + facing * 20.0, s, parent)


# Rising dragon silhouette — the uppercut's finishing flair. Waits for the
# uppercut's knockup peak, pops to strong visibility, then soars to a medium
# height while fading the whole way up (strong → gone). Kept translucent so it
# reads as a rising spirit dragon rather than a solid pasted sprite.
func _spawn_dragon_finisher(pos: Vector2, base_scale: float, parent: Node) -> void:
	var tex: Texture2D = _impact_texture("dragon")
	if tex == null:
		return
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.offset = Vector2(0.0, -float(tex.get_height()) * 0.5)  # bottom anchor — rises
	spr.position = pos + Vector2(0.0, -8.0)                    # start just above the hero
	var s0: float = base_scale * IMPACT_DRAGON_START_SCALE
	var s1: float = base_scale * IMPACT_DRAGON_PEAK_SCALE     # the big rising dragon
	spr.scale = Vector2(s0, s0)
	spr.modulate = Color(0.62, 0.86, 1.0, 0.0)                # translucent spirit blue
	spr.z_index = 50                                          # well above hero + flame
	parent.add_child(spr)
	if IMPACT_DRAGON_DEBUG:
		Log.dbg(str("[FX] dragon finisher spawn  pos=", spr.position, "  scale ", s0, "→", s1, "  tex=", tex.resource_path))
	var top: Vector2 = spr.position + Vector2(0.0, -IMPACT_DRAGON_RISE)
	# Motion tween — launched by the uppercut: bursts upward with the punch's
	# force, then decelerates and glides to the apex. EASE_OUT (fast→slow) is what
	# makes it feel thrown rather than floated. Scale grows with the same launch.
	var move := create_tween()
	move.tween_interval(IMPACT_DRAGON_START_DELAY)            # born on the punch contact
	move.set_parallel(true)
	move.tween_property(spr, "scale", Vector2(s1, s1), IMPACT_DRAGON_RISE_TIME)\
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	move.tween_property(spr, "position", top, IMPACT_DRAGON_RISE_TIME)\
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)  # soars then settles at the apex
	# Opacity tween — quick fade-in at launch, then a dissolve on the SAME EASE_OUT
	# curve as the rise, so alpha tracks the deceleration: bright low, faint as it
	# settles, gone exactly at the apex. No float, no top-flash.
	var fade := create_tween()
	fade.tween_interval(IMPACT_DRAGON_START_DELAY)
	fade.tween_property(spr, "modulate:a", IMPACT_DRAGON_ALPHA, IMPACT_DRAGON_BURST_TIME)\
		.set_ease(Tween.EASE_OUT)                            # quick fade-in as it launches
	fade.tween_property(spr, "modulate:a", 0.0, IMPACT_DRAGON_RISE_TIME - IMPACT_DRAGON_BURST_TIME)\
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)  # dissolve coupled to the rise
	fade.tween_callback(Callable(spr, "queue_free"))


# Run 69 — Flurry punch: a single ethereal jab/cross impact sprite that flies
# OUTWARD along `dir` from `origin`, playing its 3 frames while it travels and
# fades. Used by Shino's Y-charge pummel to scatter the same hand-keyed blue
# punch art (jab/cross) all around him, replacing the old procedural comets.
#   kind: "jab" | "cross"
func spawn_flurry_punch(kind: String, origin: Vector2, dir: Vector2,
		reach: float = 70.0, duration: float = 0.11, scale_mul: float = 1.0,
		parent: Node = null) -> void:
	if parent == null:
		parent = get_tree().current_scene
	if parent == null:
		return
	var tex: Texture2D = _impact_texture(kind)
	if tex == null:
		return
	if dir.length() < 0.01:
		dir = Vector2.RIGHT
	dir = dir.normalized()
	var frames: int = 3
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.hframes = frames
	spr.frame = 0
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.z_index = 6
	var s: float = IMPACT_SCALE * scale_mul
	# Mirror spawn_punch_impact's per-kind stretch so the comet reads like the
	# real jab/cross (cross is the wider, fatter one).
	if kind == "cross":
		spr.scale = Vector2(s * 1.4, s * 1.05)
	else:
		spr.scale = Vector2(s * 1.25, s * 0.95)
	spr.modulate.a = IMPACT_ALPHA            # ethereal see-through punch
	# The jab/cross art's bright head leads ~29° off the texture's +X axis; subtract
	# that baked-in diagonal so the head flies straight along `dir`.
	var off: float = IMPACT_FWD_DEG.get(kind, 29.0)
	spr.rotation = dir.angle() - deg_to_rad(off)
	spr.position = origin + dir * 8.0
	parent.add_child(spr)
	# Frame playback (snappy, same cadence as the static impacts).
	var anim := create_tween()
	for i in range(1, frames):
		anim.tween_interval(IMPACT_FRAME_TIME)
		anim.tween_callback(Callable(spr, "set_frame").bind(i))
	# Fly-out + fade over the whole life, decelerating as it shoots out.
	var fly := create_tween()
	fly.set_parallel(true)
	fly.tween_property(spr, "position", origin + dir * reach, duration)\
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	fly.tween_property(spr, "modulate:a", 0.0, duration)\
		.set_ease(Tween.EASE_IN)
	fly.set_parallel(false)
	fly.tween_callback(Callable(spr, "queue_free"))


# Ranged-attack flash (Run 26c) — short forward line/cone for Ki Blasts.
# Visually distinct from melee arcs so the player can see they fired a
# projectile even before the actual KiBlast scene catches up.
func spawn_ranged_flash(pos: Vector2, facing: Vector2, length: float = 64.0,
		color: Color = Color(0.55, 1.0, 0.55, 0.65), duration: float = 0.12, parent: Node = null) -> void:
	if parent == null:
		parent = get_tree().current_scene
	if parent == null:
		return
	if facing.length() < 0.01:
		facing = Vector2.RIGHT
	facing = facing.normalized()
	var poly := Polygon2D.new()
	poly.color = color
	poly.position = pos
	# Narrow forward-pointing kite shape.
	var fwd: Vector2 = facing
	var side: Vector2 = facing.rotated(PI * 0.5)
	var pts: PackedVector2Array = PackedVector2Array()
	pts.append(Vector2.ZERO)
	pts.append(side * 8.0)
	pts.append(fwd * length)
	pts.append(side * -8.0)
	poly.polygon = pts
	poly.z_index = 5
	parent.add_child(poly)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(poly, "color:a", 0.0, duration)
	tw.tween_property(poly, "scale", Vector2(1.08, 1.0), duration)
	tw.set_parallel(false)
	tw.tween_callback(Callable(poly, "queue_free"))


# Expanding explosion circle — Run 30 (Ki Blast impact boom). Scales out from
# the impact point while fading, so the AoE footprint reads instantly.
func spawn_explosion_ring(center: Vector2, radius: float = 80.0,
		color: Color = Color(0.55, 1.0, 0.65, 0.45), duration: float = 0.22) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var poly := Polygon2D.new()
	var steps: int = 24
	var pts := PackedVector2Array()
	for i in steps:
		var ang: float = TAU * i / steps
		pts.append(Vector2(cos(ang), sin(ang)) * radius)
	poly.polygon = pts
	poly.color = color
	poly.global_position = center
	poly.z_index = 4
	poly.scale = Vector2(0.25, 0.25)
	scene.add_child(poly)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(poly, "scale", Vector2.ONE, duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(poly, "color:a", 0.0, duration)
	tw.set_parallel(false)
	tw.tween_callback(Callable(poly, "queue_free"))


# Run 58 — light scorch decal left where a projectile detonates against a wall,
# obstacle, or floor (Shino's ki blast). Deliberately subtle: a small, slightly
# irregular dark smudge that sits on the ground behind characters, holds briefly,
# then fades over `lifetime` seconds so the arena never accumulates visual noise.
func spawn_scorch_decal(center: Vector2, radius: float = 13.0,
		color: Color = Color(0.08, 0.06, 0.05, 0.32), lifetime: float = 3.0) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var poly := Polygon2D.new()
	poly.z_index = -1   # on the floor, behind characters
	var steps: int = 14
	var pts := PackedVector2Array()
	for i in steps:
		var ang: float = TAU * i / steps
		var r: float = radius * randf_range(0.72, 1.0)   # organic scorch, not a clean disc
		pts.append(Vector2(cos(ang), sin(ang)) * r)
	poly.polygon = pts
	poly.color = color
	poly.global_position = center
	scene.add_child(poly)
	var tw := create_tween()
	tw.tween_interval(lifetime * 0.35)   # linger at full, then fade across the rest of its life
	tw.tween_property(poly, "color:a", 0.0, lifetime * 0.65)
	tw.tween_callback(Callable(poly, "queue_free"))


# -------------------------------------------------------
# Enemy attack telegraphs — Run 27
# -------------------------------------------------------
# Draw a fading danger-zone polygon in world-space so the player can read
# incoming attacks and dash to safety. Each helper spawns a Polygon2D as a
# child of the current scene root (z_index -1 so it sits behind characters).
# The node fades from its start alpha to 0 over `duration`, then self-frees.
# Call sites pass the WINDUP duration so the zone vanishes exactly when the
# hit lands — the timing pressure is the telegraph.

# Circular danger zone — for melee AoE stomps, close-range slams.
func spawn_danger_circle(center: Vector2, radius: float,
		color: Color = Color(1.0, 0.20, 0.10, 0.30),
		duration: float = 0.25) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var poly := Polygon2D.new()
	poly.z_index = -1
	var steps: int = 20
	var pts := PackedVector2Array()
	for i in steps:
		var ang: float = TAU * i / steps
		pts.append(Vector2(cos(ang) * radius, sin(ang) * radius))
	poly.polygon = pts
	poly.color   = color
	poly.global_position = center
	scene.add_child(poly)
	var tw := create_tween()
	tw.tween_property(poly, "color:a", 0.0, duration)
	tw.tween_callback(Callable(poly, "queue_free"))


# Flashing danger circle — used for death explosions (Popcorn Popper, Expired-Egg
# Bloater). Pulses alpha like other enemy telegraphs so the player reads it as
# "get out." Uses Telegraph's shared RED danger palette. Auto-frees after `duration`.
func spawn_flashing_danger_circle(center: Vector2, radius: float,
		duration: float = 1.5) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	# Build the circle poly with an edge outline (mirrors Telegraph.make_circle_poly).
	var poly := Polygon2D.new()
	poly.z_index = -1
	var pts := PackedVector2Array()
	var steps: int = 26
	for i in steps:
		var ang: float = TAU * i / steps
		pts.append(Vector2(cos(ang) * radius, sin(ang) * radius))
	poly.polygon = pts
	poly.color = Color(Telegraph.AOE_COLOR.r, Telegraph.AOE_COLOR.g,
			Telegraph.AOE_COLOR.b, Telegraph.FILL_ALPHA)
	poly.global_position = center
	# Edge outline.
	var edge := Line2D.new()
	edge.name = "Edge"
	edge.width = Telegraph.EDGE_WIDTH
	edge.default_color = Color(Telegraph.AOE_COLOR.r, Telegraph.AOE_COLOR.g,
			Telegraph.AOE_COLOR.b, Telegraph.EDGE_ALPHA)
	edge.closed = true
	var edge_pts := PackedVector2Array(pts)
	edge_pts.append(pts[0])
	edge.points = edge_pts
	poly.add_child(edge)
	scene.add_child(poly)
	# Pulse: oscillate alpha 4× over the duration, then flash-fire and free.
	var tw := create_tween()
	var pulse_count: int = 4
	var pulse_dur: float = duration / float(pulse_count)
	for _i in pulse_count:
		tw.tween_property(poly, "color:a", Telegraph.FILL_ALPHA + 0.28, pulse_dur * 0.5)
		tw.tween_property(poly, "color:a", Telegraph.FILL_ALPHA, pulse_dur * 0.5)
	tw.tween_callback(Callable(self, "_flash_and_free_poly").bind(poly))


func _flash_and_free_poly(poly: Polygon2D) -> void:
	if poly == null or not is_instance_valid(poly):
		return
	Telegraph.flash_fire(poly)
	# Hold the bright flash for one frame then free.
	get_tree().create_timer(0.08).timeout.connect(Callable(poly, "queue_free"))


# Rectangular beam danger zone — for ranged shots, charges, linear attacks.
# `origin` is the shooter, `direction` a normalised Vector2, `length` is beam
# reach, `half_width` is the half-width of the danger corridor.
func spawn_danger_beam(origin: Vector2, direction: Vector2,
		length: float = 400.0, half_width: float = 22.0,
		color: Color = Color(1.0, 0.10, 0.08, 0.28),
		duration: float = 0.35) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var poly := Polygon2D.new()
	poly.z_index = -1
	var perp: Vector2 = direction.orthogonal()
	var pts := PackedVector2Array()
	pts.append(-perp * half_width)
	pts.append( perp * half_width)
	pts.append( perp * half_width + direction * length)
	pts.append(-perp * half_width + direction * length)
	poly.polygon = pts
	poly.color   = color
	poly.global_position = origin
	scene.add_child(poly)
	var tw := create_tween()
	tw.tween_property(poly, "color:a", 0.0, duration)
	tw.tween_callback(Callable(poly, "queue_free"))


# -------------------------------------------------------
# Sound events  (Phase 2a — now real audio, was a print stub)
# -------------------------------------------------------
# All combat code calls FX.play_sound("event_name") instead of touching an
# AudioStreamPlayer directly. This function is a THIN FORWARDER to the SFX
# autoload, which owns the voice pool, rate limiting and the sound bank.
#
# WHY IT STAYS HERE: 110 call sites across the combat scripts already call
# FX.play_sound(). Forwarding rather than replacing means none of them had to
# change — wiring a new sound is purely a SoundBank.gd data edit.
#
# Behaviour when a sound isn't authored yet: SFX no-ops silently. An event
# declared in SoundBank with an empty "streams" array is silent BY DESIGN and
# never warns; only genuinely unknown event names warn (typo catcher).
#
# The old print()-based stub, its SOUND_VERBOSE flag and its rate-limit
# bookkeeping are gone — SFX.gd does all of that properly now, and Log.gd
# handles debug-gated printing project-wide.
#
# See: scripts/audio/SFX.gd, scripts/audio/SoundBank.gd
# Cached SFX autoload reference.
#
# WHY CACHE: play_sound() is called from 110 sites, several of them per-frame
# combat paths (flurry_tick, enemy_hit). get_node_or_null("/root/SFX") does a
# string path parse and tree walk EVERY call — pointless work in the hottest
# code in the game. Resolved once, lazily, on first use.
#
# Lazily rather than in _ready() because FX is declared BEFORE SFX in the
# autoload list (SFX has to come after Settings, which creates the audio buses),
# so at FX._ready() time /root/SFX does not exist yet.
var _sfx: Node = null


func _resolve_sfx() -> Node:
	if is_instance_valid(_sfx):
		return _sfx
	_sfx = get_node_or_null("/root/SFX")
	return _sfx


func play_sound(event_name: String, vol: float = 1.0) -> void:
	var s: Node = _resolve_sfx()
	if s != null:
		s.play(event_name, vol)


## Positional variant — currently non-positional (the camera follows the pair,
## so everything audible is on-screen). Present so future call sites can pass a
## world position without needing a signature change later.
func play_sound_at(event_name: String, world_pos: Vector2, vol: float = 1.0) -> void:
	var s: Node = _resolve_sfx()
	if s != null:
		s.play_at(event_name, world_pos, vol)


# -------------------------------------------------------
# Fade overlay — used by death + arena transitions
# -------------------------------------------------------
# Spawns a fullscreen CanvasLayer overlay that fades from 0→target_alpha over
# `duration`. Optionally calls `on_complete` (Callable) at the end. Layer
# auto-frees after `hold` extra seconds.
func fade_to_black(duration: float = 0.6, hold: float = 0.15, target_alpha: float = 1.0, on_complete: Callable = Callable()) -> CanvasLayer:
	var layer := CanvasLayer.new()
	layer.layer = 80
	var scene := get_tree().current_scene
	if scene == null:
		return layer   # nothing to attach to
	scene.add_child(layer)
	var rect := ColorRect.new()
	rect.color = Color(0.0, 0.0, 0.0, 0.0)
	rect.anchor_right = 1.0
	rect.anchor_bottom = 1.0
	rect.offset_left = 0.0
	rect.offset_top = 0.0
	rect.offset_right = 0.0
	rect.offset_bottom = 0.0
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(rect)
	var tw := create_tween()
	tw.tween_property(rect, "color:a", target_alpha, duration)
	if hold > 0.0:
		tw.tween_interval(hold)
	if on_complete.is_valid():
		tw.tween_callback(on_complete)
	return layer


# Spawn a black overlay that immediately starts fading OUT (alpha 1→0).
# Used by World.gd._ready() so each new arena fades in from black instead of
# popping in instantly after the fade-out of the previous room.
func fade_from_black(duration: float = 0.35, on_complete: Callable = Callable()) -> void:
	var layer := CanvasLayer.new()
	layer.layer = 80
	var scene := get_tree().current_scene
	if scene == null:
		return
	scene.add_child(layer)
	var rect := ColorRect.new()
	rect.color = Color(0.0, 0.0, 0.0, 1.0)   # starts fully opaque
	rect.anchor_right = 1.0
	rect.anchor_bottom = 1.0
	rect.offset_left = 0.0
	rect.offset_top = 0.0
	rect.offset_right = 0.0
	rect.offset_bottom = 0.0
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(rect)
	var tw := create_tween()
	tw.tween_property(rect, "color:a", 0.0, duration)
	if on_complete.is_valid():
		tw.tween_callback(on_complete)
	tw.tween_callback(Callable(layer, "queue_free"))


# ============================================================
# Run 55 — Silhouette hit-flash helpers
# ------------------------------------------------------------
# Old enemy flash painted a full-bounding-box ColorRect overlay opaque red,
# which read as a big solid square that swallowed the figure. Instead we tint
# the Body's ColorRect parts directly so the flash takes the figure's SHAPE,
# and we lerp toward the tint (not replace) so partial strength leaves the
# enemy readable — a red glow rather than a solid block.
#
# Usage (host caches base colours once, then applies/clears tints):
#   _body_base = FX.cache_body_colors($Body)   # at _ready, while pristine
#   FX.apply_body_tint(_body_base, HIT_COLOR, 0.6)   # on hit
#   FX.clear_body_tint(_body_base)                   # on flash end
# Every tint is computed from the cached pristine base, so overlapping
# flash / wind-up / restore calls never compound or corrupt the colours.
func cache_body_colors(body: Node) -> Dictionary:
	var base: Dictionary = {}
	if body == null:
		return base
	for c in body.get_children():
		if c is ColorRect:
			base[c] = (c as ColorRect).color
	return base


func apply_body_tint(base: Dictionary, tint: Color, strength: float) -> void:
	for c in base.keys():
		if is_instance_valid(c):
			(c as ColorRect).color = (base[c] as Color).lerp(tint, strength)


func clear_body_tint(base: Dictionary) -> void:
	for c in base.keys():
		if is_instance_valid(c):
			(c as ColorRect).color = base[c]


# -------------------------------------------------------
# Dash afterimage / ghost trail
# -------------------------------------------------------
# Spawns a translucent snapshot of an AnimatedSprite2D at its current
# position. The ghost fades out and slightly scales down over `duration`.
# Call this every frame (or every other frame) during a dash to leave
# a trailing shadow behind the character.
#
# `tint` lets each character have a distinct ghost colour — e.g. a cool
# blue for Shino and purple for Bea.
func spawn_dash_afterimage(sprite: AnimatedSprite2D, world_pos: Vector2,
		tint: Color = Color(0.3, 0.45, 0.9, 0.55), duration: float = 0.18,
		parent: Node = null) -> void:
	if sprite == null or sprite.sprite_frames == null:
		return
	if parent == null:
		parent = get_tree().current_scene
	if parent == null:
		return

	# Build a plain Sprite2D from the current animation frame texture.
	var ghost := Sprite2D.new()
	ghost.texture = sprite.sprite_frames.get_frame_texture(
		sprite.animation, sprite.frame)
	ghost.global_position = world_pos + sprite.position   # offset matches sprite child
	ghost.scale = sprite.scale
	ghost.flip_h = sprite.flip_h
	ghost.z_index = sprite.z_index - 1   # sit just behind the real sprite
	ghost.modulate = tint
	ghost.centered = sprite.centered
	parent.add_child(ghost)

	# Fade + slight shrink → ghostly dissolve.
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(ghost, "modulate:a", 0.0, duration)
	tw.tween_property(ghost, "scale", ghost.scale * 0.92, duration)
	tw.set_parallel(false)
	tw.tween_callback(Callable(ghost, "queue_free"))
