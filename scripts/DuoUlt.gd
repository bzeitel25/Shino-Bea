extends Node

# ============================================================
# DuoUlt.gd — "Ki Prism Mirror Cut" — combined-ultimate orchestrator
# ============================================================
# Autoload singleton. Owns the combined-ult cinematic that fires when both
# ninjas commit their meters to one attack.
#
#   NAME   KI PRISM MIRROR CUT
#   KANJI  気稜鏡斬   (KI-RYOKYO-ZAN)
#   Built as Shino's FIRST character + Bea's LAST character, with the
#   prism-mirror compound sandwiched between:   気 |稜鏡| 斬
#   — so the duo literally opens with his ult (気弾 FINAL KI BLAST) and closes
#   with hers (千斬 THOUSAND CUTS). 稜鏡 is the Sino-Japanese word for prism,
#   literally "edged mirror", which is also a fair description of the move:
#   Bea's blade splits Shino's beam into a dozen falling light-shards.
#
# ---- HOW IT IS TRIGGERED (rewritten in Run 168) ----------------------------
# OLD (Run 150-167): the partner could press ult at ANY point during the other
# hero's ultimate and this file would hijack it mid-animation. There was no
# window, no warning, and no way to tell which ult you were going to get. Worse,
# hijacking an attack already in flight left the game half-transitioned — the
# solo coroutine bailing out while this file tweened the same two heroes from
# wherever they happened to be standing. That is the origin of the frozen-Bea
# and dead-Bea states Bruno reported in 2P.
#
# NEW (Run 168): every ult opens with a splash frame (UltSplash.gd), and THAT
# ~2s frame is the one and only window in which the duo can be chosen:
#
#     press ult -> [SPLASH: one panel, 1.75s] -> solo attack animation
#                        |                              ^
#                        | partner presses ult          | LOCKED — nothing
#                        v   (only here)                |  can convert it now
#                  [SPLASH: both panels, 気稜鏡斬] -> duo cinematic
#
# The split of responsibility is now:
#   request()          — VALIDATE + ARM only. Checks the window is open
#                        (RunState.ult_splash_active && !ult_locked_in), both
#                        heroes are up, the partner has full Chi, then asks
#                        UltSplash to promote and sets the duo flags. Runs no
#                        cinematic and commits nothing if the splash refuses.
#   start_cinematic()  — called by UltSplash once its combined banner has played
#                        and the frame has torn down. This is what runs _run().
#
# While the duo is active, RunState.ult_freeze_caster is the sentinel "duo",
# which matches NEITHER hero id so both freeze-blocks early-return and this file
# owns both transforms. (Run 168 note: Bea's freeze-block compared against the
# literal string "shino" and so never actually honoured that sentinel — she ran
# her full physics process while this file tweened her. Fixed in Bea.gd.)
#
# ---- THE CINEMATIC (see _run) ----------------------------------------------
#   • Both ninjas leap to opposite screen corners.
#   • Shino charges his Ki-Beam; Bea readies her katana.
#   • Shino fires the beam across the arena; Bea slices it.
#   • The beam splits into a dozen light-beams that arc out and crash down like
#     meteors, damaging EVERY enemy in the arena and applying BOTH heroes'
#     Ult-slot boon payloads.
#   • Both ninjas leap back to their exact start positions.
#   • Cleanup — restore heroes, clear flags, THEN release the world-freeze.
#
# ---- FREEZING ---------------------------------------------------------------
# This file no longer freezes anything itself. UltFreeze.gd is the single owner
# of every process_mode write for the whole ult sequence, and it re-scans each
# frame so mid-cinematic spawns and in-flight projectiles are caught too. Hero
# SAFETY is separate again: HeroBase.take_damage() hard-refuses all damage while
# RunState.ult_cinematic_active(), so neither ninja can be hurt at any point.
#
# Art is placeholder-friendly: portraits reuse each hero's live sprite frame and
# everything else is procedural (Line2D / Polygon2D / tweens) so Bruno can drop
# in nicer art later without touching the choreography.
#
# Registered in project.godot as:  DuoUlt = "*res://scripts/DuoUlt.gd"
# ============================================================

# ---- Tunables ------------------------------------------------------------
const CORNER_INSET: float        = 0.72   # fraction of the half-view the corners sit at
const NUM_LIGHT_BEAMS: int       = 12     # "a dozen beams of light"
const METEOR_HIT_RADIUS: float   = 150.0  # AoE radius of each meteor impact
const METEOR_BASE_DAMAGE: int    = 60     # per-meteor base (scaled by the attributed hero's mults)
const FINISHER_BASE_DAMAGE: int  = 110    # guaranteed arena-wide pass base (scaled)

# Palette
const COL_SHINO: Color   = Color(0.30, 0.85, 1.00)   # cyan ki
const COL_BEA: Color     = Color(1.00, 0.50, 0.95)   # magenta blade
const COL_BEAM: Color    = Color(0.90, 0.98, 1.00)   # white-hot beam core
const COL_LIGHT: Color   = Color(1.00, 0.97, 0.78)   # golden light-beams

var active: bool = false

# Run 168 — the scene _run() started in. Compared after every await so the
# cinematic cannot continue (or deal damage) in a room it does not belong to.
var _run_scene: Node = null


func _ready() -> void:
	# Run 168 — the cinematic must keep animating even if something pauses the
	# tree underneath it. Without this, DuoUlt ran at PROCESS_MODE_INHERIT while
	# its own `await get_tree().create_timer(...)` calls kept ticking regardless
	# (SceneTreeTimers default to process_always), so a pause mid-cinematic
	# stopped the TWEENS but not the TIMELINE — the beats desynced from the
	# choreography and heroes were left mid-leap. Matches UltFreeze / UltSplash.
	process_mode = Node.PROCESS_MODE_ALWAYS


# --------------------------------------------------------------------------
# Run 168 — hard abort. Called by RunState.reset_ult_state() on run reset /
# scene teardown.
#
# WHY THIS HAS TO EXIST: `active` was set in request() and cleared in exactly
# one place — _cleanup(), at the end of a cinematic that had actually run. But
# request() only ARMS the duo; the cinematic is started later, by UltSplash's
# tail. If anything tore the splash down in between (a room change, a reset,
# UltSplash.force_close()), start_cinematic() was never called, _cleanup() never
# ran, and `active` stayed true FOREVER. Since autoloads outlive reset_run(),
# that silently disabled the duo ult for the entire rest of the process — every
# later request() bouncing off the `if active: return false` guard at the top,
# with no error and no visible cause.
func abort() -> void:
	active = false
	_run_scene = null


# --------------------------------------------------------------------------
# Public entry — called from the hero freeze-blocks when the partner presses
# ult with full Chi during the first hero's ult.
# --------------------------------------------------------------------------
func request() -> bool:
	if active:
		return false
	# ------------------------------------------------------------------
	# Run 168 — THE WINDOW GATE. This is the whole anti-hijack fix.
	# ------------------------------------------------------------------
	# The duo can ONLY be armed while a splash frame is on screen and before it
	# locks in. Previously request() would happily fire in the middle of a
	# cinematic that was already three spins into its attack animation, which
	# tore the game in half: the solo coroutine bailed out mid-sequence while
	# this file started tweening the same two heroes from wherever they stood.
	# The callers gate on these flags too — this is the authoritative backstop,
	# because a missed gate here is a corrupted run, not a cosmetic glitch.
	if not RunState.ult_splash_active or RunState.ult_locked_in:
		return false
	# There must be an ult already running (a caster to combine with).
	var caster_id: String = RunState.ult_freeze_caster
	if caster_id == "" or caster_id == "duo":
		return false
	var shino: Node = _find_shino()
	var bea: Node = _find_bea()
	if shino == null or bea == null:
		return false
	if not is_instance_valid(shino) or not is_instance_valid(bea):
		return false
	# Both must be up (not downed / dead).
	if _is_down(shino) or _is_down(bea):
		return false
	# Authoritative gate (covers BOTH entry paths — the frozen partner pressing in
	# 2P, and the controlling player pressing again during their own ult in 1P):
	# the OTHER ninja (the one who hasn't ulted) must have FULL Chi.
	var partner: Node = bea if caster_id == "shino" else shino
	if not _has_full_chi(partner):
		return false

	# Ask the splash to promote. It refuses if the window shut between the button
	# press and this call (a real race: input is read in _physics_process, the
	# window closes on a process frame). If it refuses, we commit to NOTHING —
	# no flags are set and the solo ult continues cleanly.
	var joiner_id: String = "bea" if caster_id == "shino" else "shino"
	if not UltSplash.promote(joiner_id):
		return false

	active = true
	RunState.duo_ult_active = true
	RunState.double_ult_queued = false
	# Sentinel that matches neither hero id → both freeze-blocks early-return, so
	# DuoUlt fully owns both heroes for the duration of the cinematic.
	# (Run 168: Bea's freeze-block only matched the literal "shino" until now, so
	# this sentinel silently failed to freeze her. Fixed in Bea.gd.)
	RunState.ult_freeze_caster = "duo"
	return true


# --------------------------------------------------------------------------
# Run 168 — the cinematic is now started BY THE SPLASH, not by request().
# ------------------------------------------------------------------------
# request() only ARMS the duo (validate + set flags + promote the splash frame).
# The splash then finishes its combined banner, closes, and the caster hero's
# _start_ult() sees outcome == "duo" and returns without firing its solo attack.
# This function is what actually runs the show, and it is invoked from
# UltSplash.play()'s tail so the cinematic starts on a clean frame with both
# heroes settled and no solo coroutine still unwinding underneath it.
func start_cinematic() -> void:
	if not active:
		return
	var shino: Node = _find_shino()
	var bea: Node = _find_bea()
	if shino == null or bea == null or not is_instance_valid(shino) or not is_instance_valid(bea):
		# A hero vanished between arming and starting (downed-out, room change).
		# Unwind fully rather than returning — otherwise `active`, the duo flags
		# and the world-freeze would all stay set with no cinematic to clear them.
		_cleanup(shino, bea)
		return
	_run(shino, bea)


# --------------------------------------------------------------------------
# Cinematic coroutine
# --------------------------------------------------------------------------
func _run(shino: Node, bea: Node) -> void:
	FX.play_sound("duo_ult_activate", 1.4)

	# Remember exact start positions so we can drop both heroes right back.
	var shino_home: Vector2 = (shino as Node2D).global_position
	var bea_home: Vector2 = (bea as Node2D).global_position

	# Run 168 — the world is ALREADY frozen (UltFreeze.begin() ran back in the
	# caster's _start_ult, before the splash) and keeps re-sweeping every frame,
	# so enemies that spawn mid-cinematic get caught too. The old one-shot
	# `for e in enemies: e.process_mode = DISABLED` snapshot that lived here is
	# gone: it made this file a third owner of process_mode alongside Shino and
	# Bea, and whichever finished first un-froze enemies the others still wanted
	# stopped. Idempotent begin() below just re-asserts ownership.
	UltFreeze.begin()
	# Snapshot the scene this cinematic belongs to — _still_live() compares
	# against it after every await (see below).
	_run_scene = get_tree().current_scene

	# ---- Beat 2: leap to opposite corners ----
	var geo: Dictionary = _view_geometry()
	var center: Vector2 = geo["center"]
	var half: Vector2 = geo["half"]
	# Shino bottom-left, Bea top-right (beam travels up-and-right diagonally).
	var shino_corner: Vector2 = center + Vector2(-half.x * CORNER_INSET, half.y * CORNER_INSET)
	var bea_corner: Vector2 = center + Vector2(half.x * CORNER_INSET, -half.y * CORNER_INSET)
	_leap_to(shino, shino_corner, COL_SHINO, 0.22)
	_leap_to(bea, bea_corner, COL_BEA, 0.22)
	FX.screen_shake(FX.SHAKE_MEDIUM, 0.20)
	await get_tree().create_timer(0.24).timeout
	if not _still_live(shino, bea): return

	# ---- Beat 3: Shino charges Ki-Beam, Bea readies katana ----
	_spawn_charge_orb(shino_corner, COL_SHINO)
	_spawn_blade_ready(bea, bea_corner, (shino_corner - bea_corner).normalized())
	FX.screen_shake(FX.SHAKE_HEAVY, 0.45)
	FX.play_sound("duo_ult_charge", 1.3)
	await get_tree().create_timer(0.50).timeout
	if not _still_live(shino, bea): return

	# ---- Beat 4: fire the beam, Bea slices it ----
	await _fire_beam(shino_corner, bea_corner)
	if not _still_live(shino, bea): return
	# The slice happens at Bea's corner.
	_spawn_slice_flash(bea_corner, (bea_corner - shino_corner).normalized())
	FX.screen_shake(FX.SHAKE_ULT, FX.SHAKE_DUR_MED)
	FX.play_sound("duo_ult_slice", 1.5)

	# Both heroes' Ult-slot boon cast payloads fire (heal-both, shield-both, and
	# each hero's self-buff windows). Combined ult = both contribute.
	if shino.has_method("_apply_ult_boon_cast_effects"):
		shino.call("_apply_ult_boon_cast_effects")
	if bea.has_method("_bea_apply_ult_boon_cast_effects"):
		bea.call("_bea_apply_ult_boon_cast_effects")

	# ---- Beat 5: split into a dozen meteors + arena-wide damage ----
	await _rain_meteors(bea_corner, center, half, shino, bea)
	if not _still_live(shino, bea): return

	# ---- Beat 6: leap home, restore control ----
	_leap_to(shino, shino_home, COL_SHINO, 0.22)
	_leap_to(bea, bea_home, COL_BEA, 0.22)
	await get_tree().create_timer(0.24).timeout

	_cleanup(shino, bea)


# --------------------------------------------------------------------------
# Run 168 — post-await liveness check. Called after EVERY await in _run().
# --------------------------------------------------------------------------
# abort() only flips `active`; it cannot stop a coroutine that is already
# suspended. And _run() is driven by SceneTreeTimers on a PROCESS_MODE_ALWAYS
# autoload, so those awaits keep resolving straight through a scene change and
# through RunState.reset_ult_state().
#
# Without this check, a room transition (or reset_run()) mid-cinematic meant
# _run() simply carried on in the NEW room: it re-read get_tree().current_scene,
# spawned the beam and meteor VFX there, and — the real damage — ran
# _rain_meteors() -> _all_enemies() -> _deal_duo_damage() against the new room's
# enemies, landing 12 meteors plus the arena-wide FINISHER_BASE_DAMAGE pass for
# free, before finally reaching the guarded _cleanup(). The late-arrival guard in
# _cleanup() protects the FLAGS; this protects the WORLD.
#
# Bailing here is safe and complete: whatever tore us down (abort / reset /
# UltFreeze's scene hook) has already cleared the flags and released the freeze,
# and _cleanup()'s own not-active branch restores the heroes if they survived.
func _still_live(shino: Node, bea: Node) -> bool:
	if not active:
		return false
	if not is_instance_valid(shino) or not is_instance_valid(bea):
		_cleanup(shino, bea)
		return false
	var tree: SceneTree = get_tree()
	if tree == null or (_run_scene != null and tree.current_scene != _run_scene):
		_cleanup(shino, bea)
		return false
	return true


# --------------------------------------------------------------------------
# Beat 1 — REMOVED in Run 168.
# --------------------------------------------------------------------------
# The action split-frame that used to open this cinematic now lives in
# UltSplash.gd, where it does double duty: it is BOTH the per-hero solo splash
# and the duo frame, and it plays BEFORE the ult rather than inside it. That is
# what creates the window in which the duo can be chosen at all. Its helpers
# (_portrait_splitframe / _add_portrait_face / _add_speed_lines /
# _add_name_label) moved with it — do not resurrect them here, or the game will
# have two split-frame implementations drifting apart.


# --------------------------------------------------------------------------
# Beat 2/6 — leap helper (tween a hero to a point, trailing afterimages)
# --------------------------------------------------------------------------
func _leap_to(hero: Node, dest: Vector2, tint: Color, dur: float) -> void:
	if not is_instance_valid(hero):
		return
	var h2d := hero as Node2D
	var tw := create_tween()
	tw.tween_property(h2d, "global_position", dest, dur) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	# A few afterimages along the leap.
	var spr: AnimatedSprite2D = _hero_sprite(hero)
	if spr != null:
		var from: Vector2 = h2d.global_position
		for i in range(4):
			var t: float = float(i) / 4.0
			var p: Vector2 = from.lerp(dest, t)
			get_tree().create_timer(dur * t).timeout.connect(
				func() -> void:
					if is_instance_valid(spr):
						FX.spawn_dash_afterimage(spr, p, Color(tint.r, tint.g, tint.b, 0.5), 0.22))


# --------------------------------------------------------------------------
# Beat 3 — charge visuals
# --------------------------------------------------------------------------
func _spawn_charge_orb(pos: Vector2, col: Color) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	# Growing core orb.
	var orb := Polygon2D.new()
	var pts := PackedVector2Array()
	for i in range(20):
		var a: float = TAU * float(i) / 20.0
		pts.append(Vector2(cos(a), sin(a)) * 14.0)
	orb.polygon = pts
	orb.color = Color(col.r, col.g, col.b, 0.9)
	orb.global_position = pos
	orb.z_index = 8
	orb.scale = Vector2(0.2, 0.2)
	scene.add_child(orb)
	var tw := create_tween()
	tw.tween_property(orb, "scale", Vector2(1.6, 1.6), 0.50) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(Callable(orb, "queue_free"))
	# Converging rings.
	for ring_i in range(3):
		var ring := Line2D.new()
		ring.width = 4.0
		ring.default_color = Color(col.r, col.g, col.b, 0.6)
		ring.closed = true
		var rp := PackedVector2Array()
		for si in range(24):
			var aa: float = TAU * float(si) / 24.0
			rp.append(Vector2(cos(aa), sin(aa)) * 70.0)
		ring.points = rp
		ring.global_position = pos
		ring.z_index = 8
		scene.add_child(ring)
		var rt := create_tween()
		rt.tween_interval(ring_i * 0.12)
		rt.set_parallel(true)
		rt.tween_property(ring, "scale", Vector2(0.1, 0.1), 0.44)
		rt.tween_property(ring, "default_color:a", 0.0, 0.44)
		rt.set_parallel(false)
		rt.tween_callback(Callable(ring, "queue_free"))


func _spawn_blade_ready(bea: Node, pos: Vector2, aim: Vector2) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	# Katana glint — a bright blade line held ready across Bea's body, plus a
	# quick sheath-draw spark.
	var blade := Line2D.new()
	blade.width = 6.0
	blade.default_color = Color(1.0, 1.0, 1.0, 0.0)
	blade.begin_cap_mode = Line2D.LINE_CAP_ROUND
	blade.end_cap_mode = Line2D.LINE_CAP_ROUND
	var perp: Vector2 = aim.orthogonal()
	blade.points = PackedVector2Array([pos - perp * 30.0 - aim * 6.0, pos + perp * 30.0 - aim * 6.0])
	blade.z_index = 9
	scene.add_child(blade)
	var tw := create_tween()
	tw.tween_property(blade, "default_color:a", 0.95, 0.35)
	tw.tween_interval(0.10)
	tw.tween_property(blade, "default_color:a", 0.0, 0.30)
	tw.tween_callback(Callable(blade, "queue_free"))
	FX.spawn_burst_particles(pos, COL_BEA, 8)


# --------------------------------------------------------------------------
# Beat 4 — fire the Ki-Beam across the arena
# --------------------------------------------------------------------------
func _fire_beam(from_pos: Vector2, to_pos: Vector2) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var dir: Vector2 = (to_pos - from_pos)
	var full_len: float = dir.length()
	dir = dir.normalized()

	# Outer glow + inner core, both grown from the muzzle toward Bea.
	var glow := Line2D.new()
	glow.width = 34.0
	glow.default_color = Color(COL_SHINO.r, COL_SHINO.g, COL_SHINO.b, 0.5)
	glow.begin_cap_mode = Line2D.LINE_CAP_ROUND
	glow.end_cap_mode = Line2D.LINE_CAP_ROUND
	glow.z_index = 7
	glow.points = PackedVector2Array([from_pos, from_pos])
	scene.add_child(glow)

	var core := Line2D.new()
	core.width = 13.0
	core.default_color = Color(COL_BEAM.r, COL_BEAM.g, COL_BEAM.b, 0.98)
	core.begin_cap_mode = Line2D.LINE_CAP_ROUND
	core.end_cap_mode = Line2D.LINE_CAP_ROUND
	core.z_index = 8
	core.points = PackedVector2Array([from_pos, from_pos])
	scene.add_child(core)

	FX.spawn_burst_particles(from_pos, COL_SHINO, 14)
	FX.play_sound("duo_ult_beam", 1.4)

	var steps: int = 8
	for i in range(1, steps + 1):
		var tip: Vector2 = from_pos + dir * (full_len * float(i) / float(steps))
		glow.points = PackedVector2Array([from_pos, tip])
		core.points = PackedVector2Array([from_pos, tip])
		await get_tree().create_timer(0.14 / float(steps)).timeout

	# Hold a beat then fade the beam (the slice consumes it).
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(glow, "modulate:a", 0.0, 0.18)
	tw.tween_property(core, "modulate:a", 0.0, 0.18)
	tw.set_parallel(false)
	tw.tween_callback(Callable(glow, "queue_free"))
	tw.tween_callback(Callable(core, "queue_free"))


func _spawn_slice_flash(pos: Vector2, out_dir: Vector2) -> void:
	# Big white slice burst at Bea's blade.
	_screen_flash(Color(1.0, 1.0, 1.0, 0.6), 0.16)
	FX.spawn_swing_arc(pos, out_dir, 90.0, 130.0, Color(1.0, 1.0, 1.0, 0.75), 0.20)
	FX.spawn_burst_particles(pos, COL_LIGHT, 24)
	FX.spawn_explosion_ring(pos, 90.0, Color(1.0, 1.0, 0.9, 0.5), 0.25)


# --------------------------------------------------------------------------
# Beat 5 — split into a dozen light-beams that crash down as meteors
# --------------------------------------------------------------------------
func _rain_meteors(slice_pos: Vector2, center: Vector2, half: Vector2, shino: Node, bea: Node) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var enemies: Array = _all_enemies()

	# Choose impact points: first onto living enemies (spread the love), the rest
	# scattered across the arena so the whole map gets hit.
	var impacts: Array = []
	for i in range(NUM_LIGHT_BEAMS):
		if i < enemies.size() and is_instance_valid(enemies[i]):
			impacts.append((enemies[i] as Node2D).global_position
				+ Vector2(randf_range(-24, 24), randf_range(-24, 24)))
		else:
			impacts.append(center + Vector2(
				randf_range(-half.x * 0.9, half.x * 0.9),
				randf_range(-half.y * 0.9, half.y * 0.9)))

	# Launch each light-beam: arc out from the slice, then drop into the impact.
	for i in range(impacts.size()):
		var target: Vector2 = impacts[i]
		var delay: float = float(i) * 0.035
		get_tree().create_timer(delay).timeout.connect(
			func() -> void: _one_meteor(slice_pos, target, shino, bea, i))

	# Wait for the volley (launch spread + travel + a beat).
	await get_tree().create_timer(float(impacts.size()) * 0.035 + 0.55).timeout

	# Guaranteed arena-wide finisher pass so EVERY enemy takes the combined hit,
	# even ones no meteor happened to land on.
	for e in enemies:
		if not is_instance_valid(e) or not e.has_method("take_damage"):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		_deal_duo_damage(e, FINISHER_BASE_DAMAGE, (e as Node2D).global_position, shino, bea, true)
	FX.screen_shake(FX.SHAKE_ULT, FX.SHAKE_DUR_LONG)


func _one_meteor(slice_pos: Vector2, target: Vector2, shino: Node, bea: Node, idx: int) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	# Apex above the impact — the beam flies OUT to here, then drops straight down.
	var apex: Vector2 = target + Vector2(randf_range(-40, 40), -randf_range(240.0, 340.0))

	# The light-beam streak (slice → apex).
	var streak := Line2D.new()
	streak.width = 7.0
	streak.default_color = Color(COL_LIGHT.r, COL_LIGHT.g, COL_LIGHT.b, 0.9)
	streak.begin_cap_mode = Line2D.LINE_CAP_ROUND
	streak.end_cap_mode = Line2D.LINE_CAP_ROUND
	streak.z_index = 8
	streak.points = PackedVector2Array([slice_pos, slice_pos])
	scene.add_child(streak)
	var out_tw := create_tween()
	out_tw.tween_method(Callable(self, "_update_streak_line").bind(streak, slice_pos),
		slice_pos, apex, 0.14).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	out_tw.tween_callback(Callable(streak, "queue_free"))

	# After it reaches the apex, drop the meteor straight down into the impact.
	get_tree().create_timer(0.15).timeout.connect(
		func() -> void: _drop_meteor(apex, target, shino, bea))


func _drop_meteor(apex: Vector2, target: Vector2, shino: Node, bea: Node) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var comet := Line2D.new()
	comet.width = 9.0
	comet.default_color = Color(COL_LIGHT.r, COL_LIGHT.g, COL_LIGHT.b, 0.95)
	comet.begin_cap_mode = Line2D.LINE_CAP_ROUND
	comet.end_cap_mode = Line2D.LINE_CAP_ROUND
	comet.z_index = 9
	comet.points = PackedVector2Array([apex, apex])
	scene.add_child(comet)
	var drop := create_tween()
	drop.tween_method(Callable(self, "_update_drop_comet").bind(comet, apex),
		apex, target, 0.13).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	drop.tween_callback(Callable(comet, "queue_free"))
	drop.tween_callback(func() -> void: _meteor_impact(target, shino, bea))


# tween_method targets (bound Callables — the interpolated value arrives first).
func _update_streak_line(p: Vector2, line: Line2D, anchor: Vector2) -> void:
	if is_instance_valid(line):
		line.points = PackedVector2Array([anchor, p])


func _update_drop_comet(p: Vector2, comet: Line2D, apex: Vector2) -> void:
	if is_instance_valid(comet):
		# Short trailing tail behind the falling head.
		var tail: Vector2 = p.lerp(apex, 0.35)
		comet.points = PackedVector2Array([tail, p])


func _meteor_impact(pos: Vector2, shino: Node, bea: Node) -> void:
	FX.spawn_explosion_ring(pos, METEOR_HIT_RADIUS, Color(1.0, 0.95, 0.7, 0.5), 0.30)
	FX.spawn_burst_particles(pos, COL_LIGHT, 14)
	FX.spawn_scorch_decal(pos, 18.0)
	FX.screen_shake(FX.SHAKE_HEAVY, FX.SHAKE_DUR_SHORT)
	FX.play_sound("duo_ult_meteor", 1.1)
	# AoE damage to every enemy within the impact radius.
	for e in _all_enemies():
		if not is_instance_valid(e) or not e.has_method("take_damage"):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		if (e as Node2D).global_position.distance_to(pos) <= METEOR_HIT_RADIUS:
			_deal_duo_damage(e, METEOR_BASE_DAMAGE, pos, shino, bea, false)


# Deal one duo hit, attributed alternately to each hero so BOTH heroes' Ult-slot
# boon payloads (statuses) get applied across the arena.
var _duo_attrib_toggle: bool = false
func _deal_duo_damage(e: Node, base: int, from_pos: Vector2, shino: Node, bea: Node, finisher: bool) -> void:
	var dir: Vector2 = ((e as Node2D).global_position - from_pos)
	if dir.length() < 0.01:
		dir = Vector2.RIGHT
	dir = dir.normalized()
	_duo_attrib_toggle = not _duo_attrib_toggle
	var use_shino: bool = _duo_attrib_toggle
	var dmg: int = base
	var was_alive: bool = (not e.has_method("is_alive")) or e.is_alive()
	if use_shino and is_instance_valid(shino):
		if shino.has_method("_scale_damage"):
			dmg = int(shino.call("_scale_damage", base, finisher, false, e, ""))
		if shino.has_method("_apply_family_statuses_on_hit"):
			shino.call("_apply_family_statuses_on_hit", e, false, false, false, false, true)
		e.set_meta("last_damager", "shino")
		FX.hit_rumble("shino")
	elif is_instance_valid(bea):
		if bea.has_method("_bea_scale_damage"):
			dmg = int(bea.call("_bea_scale_damage", base, finisher, false, e, ""))
		if bea.has_method("_bea_apply_family_statuses_on_hit"):
			bea.call("_bea_apply_family_statuses_on_hit", e, false, false, false, false, true)
		e.set_meta("last_damager", "bea")
		FX.hit_rumble("bea")
	e.take_damage(max(1, dmg), dir)
	FX.spawn_burst_particles((e as Node2D).global_position, COL_LIGHT, 8)


# --------------------------------------------------------------------------
# Cleanup — always runs at the end of the cinematic
# --------------------------------------------------------------------------
func _cleanup(shino: Node, bea: Node) -> void:
	# Run 168 — LATE-ARRIVAL GUARD. abort() (room change / run reset) sets
	# `active` false while _run()'s awaits are still unwinding. When that
	# coroutine finally reaches this line, the flags it is about to clear may
	# already belong to a DIFFERENT, freshly-started ult in the new room — and
	# clearing those would drop that ult's freeze and invulnerability mid-cast.
	# If we were aborted, restore the heroes we were given (harmless, guarded)
	# and touch no global state at all.
	if not active:
		if is_instance_valid(shino) and shino.has_method("duo_ult_finish"):
			shino.call("duo_ult_finish")
		if is_instance_valid(bea) and bea.has_method("duo_ult_finish"):
			bea.call("duo_ult_finish")
		_run_scene = null
		return

	# ORDER IS LOAD-BEARING below, and it is the reverse of what it used to be.
	#
	# This function previously un-froze every enemy on its FIRST line, before
	# either hero had been restored. For those few frames the arena was live
	# while both ninjas were still mid-restoration with duo flags set — enemies
	# got a free swing at two players who did not have control back yet. That is
	# the same shape of bug as the un-freeze that sat before Shino's dizzy tail.
	#
	# Correct order is: restore the PEOPLE, then clear the FLAGS, then release
	# the WORLD. Nothing wakes up until both heroes can actually respond to it.

	# 1. Spend both heroes' Chi (the duo consumes both meters) + restore state.
	if is_instance_valid(shino):
		if shino.has_method("duo_ult_spend_chi"):
			shino.call("duo_ult_spend_chi")
		if shino.has_method("duo_ult_finish"):
			shino.call("duo_ult_finish")
	if is_instance_valid(bea):
		if bea.has_method("duo_ult_spend_chi"):
			bea.call("duo_ult_spend_chi")
		if bea.has_method("duo_ult_finish"):
			bea.call("duo_ult_finish")

	# 2. Clear every duo / splash / freeze flag so the heroes resume normally.
	RunState.duo_ult_active = false
	RunState.double_ult_queued = false
	if RunState.ult_freeze_caster == "duo":
		RunState.ult_freeze_caster = ""
	RunState.ult_splash_active = false
	RunState.ult_splash_hero = ""
	RunState.ult_splash_joiner = ""
	RunState.ult_locked_in = false
	active = false
	_run_scene = null

	# 3. LAST — wake the world back up. UltFreeze restores each node to the exact
	#    process_mode it had before the ult, rather than blanket-INHERIT, so a
	#    node something else had deliberately disabled stays disabled.
	UltFreeze.end()


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
func _find_bea() -> Node:
	for n in get_tree().get_nodes_in_group("bea"):
		if is_instance_valid(n):
			return n
	return null


func _find_shino() -> Node:
	# Shino is in "player" but NOT in "bea".
	for n in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(n) and not n.is_in_group("bea"):
			return n
	return null


func _hero_sprite(hero: Node) -> AnimatedSprite2D:
	if hero == null:
		return null
	var s: Node = hero.get_node_or_null("ShinoSprite")
	if s == null:
		s = hero.get_node_or_null("BeaSprite")
	return s as AnimatedSprite2D


func _has_full_chi(hero: Node) -> bool:
	if hero == null or not is_instance_valid(hero):
		return false
	if not ("current_chi" in hero):
		return false
	var who: String = "bea" if hero.is_in_group("bea") else "shino"
	var cost: int = max(1, int(round(100.0 * RunState.tide_master_ult_cost_mult(who))))
	return int(hero.current_chi) >= cost


func _is_down(hero: Node) -> bool:
	if hero == null or not is_instance_valid(hero):
		return true
	if "current_hp" in hero and int(hero.current_hp) <= 0:
		return true
	# Run 168 — was is_in_group("downed"), which nothing in the codebase ever
	# joins, so the check was permanently false. Heroes have a "semi-alive"
	# DOWNED state at POSITIVE hp, so the hp test above does not cover it:
	# a downed-but-not-dead partner could be dragged into a duo ult.
	if hero.has_method("is_downed") and hero.is_downed():
		return true
	return false


func _all_enemies() -> Array:
	return get_tree().get_nodes_in_group("enemy")


# View geometry in WORLD space from the active Camera2D.
func _view_geometry() -> Dictionary:
	var cam: Camera2D = get_viewport().get_camera_2d()
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var center: Vector2 = vp * 0.5
	var half: Vector2 = vp * 0.5
	if cam != null:
		center = cam.get_screen_center_position()
		var zoom: Vector2 = cam.zoom
		half = Vector2(vp.x * 0.5 / max(0.01, zoom.x), vp.y * 0.5 / max(0.01, zoom.y))
	return {"center": center, "half": half}


# Full-screen flash on its own CanvasLayer.
func _screen_flash(col: Color, dur: float) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var layer := CanvasLayer.new()
	layer.layer = 58
	scene.add_child(layer)
	var rect := ColorRect.new()
	rect.color = col
	rect.anchor_right = 1.0
	rect.anchor_bottom = 1.0
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(rect)
	var tw := create_tween()
	tw.tween_property(rect, "color:a", 0.0, dur)
	tw.tween_callback(Callable(layer, "queue_free"))
