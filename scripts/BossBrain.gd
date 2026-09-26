extends "res://scripts/DummyEnemy.gd"

# ============================================================
# BossBrain.gd - Run 173 (2026-09-03) - boss / mini-boss AI engine
# Run 176 (2026-09-26) - ZELDA PASS: bosses stop walking at you
# ============================================================
# ROOT CAUSE of "they just kinda chase after the player": all 9 melee
# bosses and mini-bosses in DreamBiomes.gd hosted on DummyEnemy.tscn -
# literally the basic-grunt script - with one bolt-on "secondary":"smash"
# flag. Chase -> bite at 34px -> ring AoE every 5.5s, no phases, no move
# pool, and no reason to ever be anywhere except on top of the hero.
#
# Run 176 (Bruno): "they should not chase the player around and just become
# following attackers that are easy to kite or dodge. They should jump around
# the stage (or fly where appropriate), do landing attacks over the player they
# have to dodge - make them feel like Zelda bosses."
#
# So the two new movement modes below are the heart of the file:
#   "hop"  - the boss NEVER walks toward you. It plants, attacks, and moves
#            by LEAPING - around you, over you, away from you. Most leaps are
#            landing attacks with a RED marker that TRACKS you while the boss
#            is in the air, then LOCKS (crosshair) before it comes down.
#   "fly"  - the Phoenix. Glides above the arena in a wide orbit, ignores
#            walls, and only touches down for plunges (your punish window).
# Bosses are UNTOUCHABLE while airborne; the damage window is the recovery
# after every landing. That rhythm - read, dodge, punish - is the Zelda feel.
#
# The engine EXTENDS DummyEnemy rather than copying it, deliberately:
# take_damage, the StatusComponent plumbing, the Vulnerable/Rising-Tide/
# Pepper-Potato amps, breakbar knockback immunity, damage numbers,
# process_enemy_death_boons and the death sequence all stay in ONE place.
# Runs 131-139 were spent hunting boons that leaked because hero logic got
# duplicated. Only the AI is overridden. (LOCK - do not fork that plumbing.)
#
# ZERO-REGRESSION RULE: a boss with no BossMoves entry resolves to
# BossMoves.legacy_pool() and behaves exactly as it did before Run 173.
#
# The inherited `state` var is kept in sync (CHASE while moving, ATTACKING
# while executing or airborne) so DummyEnemy.take_damage's super-armour and
# stun rules keep applying unchanged.
# ============================================================

const MovesDB  = preload("res://scripts/BossMoves.gd")
const HazardGD = preload("res://scripts/BossHazard.gd")
const StrikeGD = preload("res://scripts/BossStrike.gd")
const DB       = preload("res://scripts/DreamBiomes.gd")
const SPAWNER  = preload("res://scripts/DreamSpawner.gd")

# Set by DreamSpawner.apply_config from the DreamBiomes entry.
@export var moveset_id: String = ""
@export var boss_display_name: String = "Boss"
@export var is_big_boss: bool = false

# Add configs (boss "adds" list) + tier, for the "summon" move kind.
var add_configs: Array = []
var spawn_tier: int = 0

# --- Resolved moveset -------------------------------------------------------
var _set: Dictionary       = {}
var _moves: Array          = []
var _movement: Dictionary  = {}
var _phase_defs: Array     = []
var _gcd_base: float       = 0.0
var _is_legacy: bool       = true
var _mode: String          = "chase"

# --- Phase state ------------------------------------------------------------
var _phase: int             = 1
var _phase_speed_mult: float = 1.0
var _phase_cd_mult: float    = 1.0
var _forced: Dictionary      = {}     # move queued by a phase's "on_enter"

# --- Move-engine state ------------------------------------------------------
# _mp: "roam" | "windup" | "active" | "recover" | "repos"
var _mp: String        = "roam"
var _mt: float         = 0.0
var _cur: Dictionary   = {}
var _cds: Dictionary   = {}
var _gcd: float        = 0.0
var _moves_done: int   = 0
var _rep_left: int     = 0

# Sequenced emissions (staggered strikes, projectile waves). While this queue
# is non-empty the boss stays planted in "active" - the barrage IS its punish
# window.
var _emit_queue: Array = []
var _emit_t: float     = 0.0

# --- Arena / positioning ----------------------------------------------------
var _arena_half: Vector2 = Vector2(680.0, 480.0)
var _anchor: Vector2     = Vector2.ZERO
var _anchor_hold: float  = 0.0
var _repos_t: float      = 0.0
const ANCHOR_ARRIVE: float = 46.0
const ANCHOR_REPICK: float = 4.5

# --- Hop / fly --------------------------------------------------------------
var _hop_t: float        = 2.0       # countdown to the next relocation hop
var _no_pick_t: float    = 0.0       # time spent with no legal move
var _lift: float         = 0.0       # current body lift (local px)
var _fly_h: float        = 0.0       # resting lift while flying
var _orbit_ang: float    = 0.0
var _orbit_dir: float    = 1.0
var _saved_mask: int     = -1
var _air_invuln: bool    = false

# --- Charge runtime ---------------------------------------------------------
var _lock_dir: Vector2  = Vector2.RIGHT
var _lock_len: float    = 0.0
var _travelled: float   = 0.0
var _trail_acc: float   = 0.0
var _struck: Dictionary = {}

# --- Leap runtime -----------------------------------------------------------
var _leap_from: Vector2 = Vector2.ZERO
var _leap_to: Vector2   = Vector2.ZERO
var _leap_t: float      = 0.0
var _leap_dur: float    = 0.55
var _leap_h: float      = 34.0
var _leap_lift0: float  = 0.0
var _leap_track: float  = 0.0
var _leap_locked: bool  = false
var _marker: Node2D     = null
const LEAP_HOP_PX: float = 34.0

# --- Telegraph palette (RED - locked project rule) --------------------------
const TELE_FILL: Color = Color(1.0, 0.18, 0.08, 0.30)
const TELE_BEAM: Color = Color(1.0, 0.12, 0.07, 0.26)

var _projectile_scene: PackedScene = null


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	super._ready()

	_set        = MovesDB.resolve(moveset_id, secondary_smash)
	_moves      = _set.get("moves", [])
	_movement   = _set.get("movement", MovesDB.DEFAULT_MOVEMENT)
	_phase_defs = _set.get("phases", [])
	_gcd_base   = float(_set.get("gcd", 0.0))
	_is_legacy  = bool(_set.get("legacy", false))
	_mode       = String(_movement.get("mode", "chase"))

	var disp: String = String(_set.get("display", ""))
	if disp != "":
		boss_display_name = disp

	for mv in _moves:
		_cds[String(mv.get("id", ""))] = float(mv.get("start_cooldown", 0.0))

	_arena_half = _resolve_arena_half()
	_anchor     = global_position
	_anchor_hold = ANCHOR_REPICK
	_hop_t = _roll_hop_interval()
	_orbit_ang = randf() * TAU
	_orbit_dir = 1.0 if randf() < 0.5 else -1.0

	if _mode == "fly":
		# Flyers glide over rocks and water; the arena clamp is their wall.
		_fly_h = float(_movement.get("fly_height", 40.0))
		_lift = _fly_h
		_saved_mask = collision_mask
		collision_mask = 0

	if ResourceLoader.exists("res://scenes/EnemyProjectile.tscn"):
		_projectile_scene = load("res://scenes/EnemyProjectile.tscn")

	# Dream bosses never fed the HUD boss bar - only the legacy arena bosses
	# (Shadow Commander / Triheaded Wyrm) did. Wire it up.
	if get_node_or_null("/root/FX") and FX.has_method("register_boss"):
		FX.register_boss(self)
		FX.notify_boss_hp(current_hp, max_hp, boss_display_name)
		FX.notify_boss_phase(_phase, maxi(1, _phase_defs.size()))

	Log.dbg("[BossBrain] %s ready - moveset '%s' (%d moves, %d phases, mode %s)%s" % [
		boss_display_name, moveset_id, _moves.size(), _phase_defs.size(), _mode,
		" [LEGACY]" if _is_legacy else ""])


func _display_name() -> String:
	return boss_display_name


# Half-extents of the room floor. Room 8 is the wide boss chamber (Run 173).
func _resolve_arena_half() -> Vector2:
	var biome: String = String(RunState.current_biome)
	var room: int = int(RunState.biome_room)
	if biome != "":
		return DB.room_half_extents(room, biome)
	return Vector2(680.0, 480.0)


# The DreamLayout node, for walkability probes. Walks up the tree because the
# spawner may parent enemies below the room node.
func _layout() -> Node:
	var n: Node = get_parent()
	var guard: int = 0
	while n != null and guard < 6:
		var lay = n.get("dream_layout")
		if lay != null:
			return lay
		n = n.get_parent()
		guard += 1
	return null


func _walkable(p: Vector2) -> bool:
	var lay: Node = _layout()
	if lay != null and lay.has_method("is_walkable_world"):
		return lay.is_walkable_world(p)
	return true


func _clamp_arena(p: Vector2, margin: float = 60.0) -> Vector2:
	return Vector2(
		clampf(p.x, -_arena_half.x + margin, _arena_half.x - margin),
		clampf(p.y, -_arena_half.y + margin, _arena_half.y - margin))


# ---------------------------------------------------------------------------
# Main tick - replaces DummyEnemy's chase/attack state machine wholesale.
# ---------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if state == State.DEAD:
		return

	_knockback_vel = _knockback_vel.lerp(Vector2.ZERO, KNOCKBACK_FRICTION * delta)

	# A stun lands only on a grounded boss - you can't Bash something mid-air.
	var airborne: bool = _mp == "active" and String(_cur.get("kind", "")) == "leap"
	if status and status.is_movement_locked() and not airborne:
		velocity = _knockback_vel
		move_and_slide()
	else:
		_update_phase()
		_tick_timers(delta)
		match _mp:
			"roam":    _tick_roam(delta)
			"repos":   _tick_repos(delta)
			"windup":  _tick_windup(delta)
			"active":  _tick_active(delta)
			"recover": _tick_recover(delta)

	_tick_lift(delta)
	_drive_anim()

	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0:
			_end_flash()


func _tick_timers(delta: float) -> void:
	if _gcd > 0.0:
		_gcd -= delta
	for k in _cds.keys():
		if _cds[k] > 0.0:
			_cds[k] = maxf(0.0, _cds[k] - delta)


# Flyers settle back to cruising height whenever they are not mid-leap.
func _tick_lift(delta: float) -> void:
	if _mp == "active" and String(_cur.get("kind", "")) == "leap":
		return   # _tick_leap owns the lift during a leap
	# A flyer only stays down during the recovery that follows a PLUNGE (its
	# punish window); every other move is performed from the air.
	var grounded: bool = _mp == "recover" and String(_cur.get("kind", "")) == "leap"
	var want: float = _fly_h if _mode == "fly" and not grounded else 0.0
	_lift = move_toward(_lift, want, 140.0 * delta)
	_apply_lift()


func _apply_lift() -> void:
	if body_anim and body_anim is Node2D:
		(body_anim as Node2D).position.y = -_lift
	queue_redraw()


# Ground shadow under a lifted body - the only honest cue of where a flying or
# leaping boss actually IS (and therefore where your hits connect).
func _draw() -> void:
	if _lift < 2.0 and not (_mp == "active" and String(_cur.get("kind", "")) == "leap"):
		return
	var s: float = clampf(1.0 - _lift / 140.0, 0.55, 1.0)
	draw_set_transform(Vector2(0, 6), 0.0, Vector2(1.0, 0.38))
	draw_circle(Vector2.ZERO, 17.0 * s, Color(0.0, 0.0, 0.0, 0.34))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------

func _update_phase() -> void:
	if _phase_defs.is_empty():
		return
	var frac: float = float(current_hp) / maxf(1.0, float(max_hp))
	var want: int = 1
	for i in range(_phase_defs.size()):
		if frac <= float((_phase_defs[i] as Dictionary).get("hp", 1.0)):
			want = i + 1
	if want <= _phase:
		return

	_phase = want
	var pd: Dictionary = _phase_defs[_phase - 1]
	_phase_speed_mult = float(pd.get("speed_mult", 1.0))
	_phase_cd_mult    = float(pd.get("cooldown_mult", 1.0))

	# Phase-change tell: RED body flash + shake, then the HUD pips.
	FX.apply_body_tint(_body_base, Color(1.0, 0.20, 0.10, 1.0), 0.85)
	_flash_timer = FLASH_DURATION * 3.0
	FX.screen_shake(7.0, 0.30)
	FX.spawn_burst_particles(global_position, Color(1.0, 0.35, 0.15, 0.95), 22)
	if get_node_or_null("/root/FX") and FX.has_method("notify_boss_phase"):
		FX.notify_boss_phase(_phase, maxi(1, _phase_defs.size()))

	# A phase can open with a signature move (fired as soon as the boss is free).
	var opener: String = String(pd.get("on_enter", ""))
	if opener != "":
		for mv in _moves:
			if String((mv as Dictionary).get("id", "")) == opener:
				_forced = mv
				break

	# A phase change should feel like a gear shift, not a pause.
	_gcd = 0.0
	Log.dbg("[BossBrain] %s -> phase %s" % [boss_display_name, String(pd.get("name", str(_phase)))])


# ---------------------------------------------------------------------------
# ROAM - the between-moves state.
# ---------------------------------------------------------------------------

func _tick_roam(delta: float) -> void:
	state = State.CHASE
	_is_winding_up = false

	if _player == null or not _player.visible \
	or (_player.has_method("is_downed") and _player.is_downed()):
		_find_player()
		if _player == null:
			velocity = _knockback_vel
			move_and_slide()
			return

	var dist: float = global_position.distance_to(_player.global_position)

	if not _forced.is_empty():
		var f: Dictionary = _forced
		_forced = {}
		_begin_move(f)
		return

	if _gcd <= 0.0:
		var pick: Dictionary = _pick_move(dist)
		if not pick.is_empty():
			_no_pick_t = 0.0
			_begin_move(pick)
			return
		_no_pick_t += delta

	match _mode:
		"hop":
			_tick_hop_idle(dist, delta)
		"fly":
			_tick_fly(dist, delta)
		_:
			_walk(_desired_dir(dist, delta), _roam_speed_mult(), delta)


func _roam_speed_mult() -> float:
	return float(_movement.get("speed_mult", 1.0)) * _phase_speed_mult


func _roll_hop_interval() -> float:
	var iv: Array = _movement.get("hop_interval", [2.2, 3.4])
	var lo: float = float(iv[0]) if iv.size() > 0 else 2.2
	var hi: float = float(iv[1]) if iv.size() > 1 else lo
	return randf_range(lo, hi) / maxf(0.5, _phase_speed_mult)


# HOP mode between moves: plant and face the hero (a tiny optional shuffle
# keeps big bodies from looking frozen), then LEAP somewhere new when the hop
# timer runs out or nothing in the pool can reach. It never walks after you.
func _tick_hop_idle(dist: float, delta: float) -> void:
	_face(_player.global_position)
	var drift: float = float(_movement.get("drift", 0.0))
	var dir: Vector2 = Vector2.ZERO
	if drift > 0.0:
		var band: Array = _movement.get("hop_range", [180.0, 300.0])
		var lo: float = float(band[0])
		var hi: float = float(band[1])
		var to_h: Vector2 = (_player.global_position - global_position).normalized()
		if dist < lo * 0.8:
			dir = -to_h
		elif dist > hi * 1.2:
			dir = to_h
		else:
			dir = to_h.orthogonal() * _orbit_dir
	_walk(dir, drift * _phase_speed_mult, delta)

	_hop_t -= delta
	var far: float = float(_movement.get("hop_when_farther", 460.0))
	if _hop_t <= 0.0 or dist > far or _no_pick_t > 1.1:
		_hop_t = _roll_hop_interval()
		_no_pick_t = 0.0
		_begin_move(_hop_move("near"))


# FLY mode between moves: a wide banking orbit around the hero, direct flight
# (no navmesh - it is above the rocks), clamped to the arena.
func _tick_fly(_dist: float, delta: float) -> void:
	var r: float = float(_movement.get("preferred_range", 260.0))
	_orbit_ang += delta * float(_movement.get("orbit_speed", 0.7)) * _orbit_dir * _phase_speed_mult
	if randf() < delta * 0.12:
		_orbit_dir = -_orbit_dir     # occasionally bank the other way
	var want: Vector2 = _clamp_arena(_player.global_position + Vector2(cos(_orbit_ang), sin(_orbit_ang) * 0.75) * r)
	var to_w: Vector2 = want - global_position
	var spd: float = move_speed * _roam_speed_mult()
	var step: Vector2 = to_w.normalized() * minf(spd * delta, to_w.length())
	global_position = _clamp_arena(global_position + step + _knockback_vel * delta)
	velocity = step / maxf(delta, 0.0001)
	_face(_player.global_position)


# The synthetic relocation leap used by hop mode and "reposition_every".
func _hop_move(where: String) -> Dictionary:
	var dmg: float = float(_movement.get("hop_land_dmg", 0.0))
	return {
		"id": "_hop",
		"kind": "leap",
		"target": "near" if where == "near" else "away",
		"windup": float(_movement.get("hop_windup", 0.30)),
		"recovery": float(_movement.get("hop_recovery", 0.35)),
		"air_time": float(_movement.get("hop_air", 0.75)),
		"height": float(_movement.get("hop_height", 30.0)),
		"style": String(_movement.get("hop_style", "jump")),
		"track": float(_movement.get("hop_track", 0.0)),
		"radius": float(_movement.get("hop_land_radius", 70.0)),
		"dmg_mult": dmg,
		"no_damage": dmg <= 0.0,
		"knockback": float(_movement.get("hop_knockback", 0.6)),
		"max_dist": float(_movement.get("hop_max_dist", 520.0)),
		"anim": String(_movement.get("hop_anim", "smash")),
	}


# Where the boss WANTS to be this frame, for the walking modes (legacy chase,
# anchor, orbit, roam). Hop/fly bosses never use this.
func _desired_dir(dist: float, delta: float) -> Vector2:
	match _mode:
		"anchor":
			_anchor_hold -= delta
			if _anchor_hold <= 0.0 and global_position.distance_to(_anchor) <= ANCHOR_ARRIVE:
				_anchor = _pick_anchor()
				_anchor_hold = ANCHOR_REPICK
			if global_position.distance_to(_anchor) > ANCHOR_ARRIVE:
				return EnemyNav.move_dir(self, _anchor, delta)
			_face(_player.global_position)
			return Vector2.ZERO

		"orbit":
			var want_r: float = float(_movement.get("preferred_range", 170.0))
			var to_hero: Vector2 = _player.global_position - global_position
			var radial: Vector2 = to_hero.normalized() * signf(dist - want_r)
			var tangent: Vector2 = to_hero.orthogonal().normalized()
			var blend: Vector2 = (radial * 0.75 + tangent * 0.85).normalized()
			return EnemyNav.move_dir(self, global_position + blend * 120.0, delta)

		"roam":
			_anchor_hold -= delta
			if _anchor_hold <= 0.0 or global_position.distance_to(_anchor) <= ANCHOR_ARRIVE:
				_anchor = _pick_anchor()
				_anchor_hold = ANCHOR_REPICK
			return EnemyNav.move_dir(self, _anchor, delta)

		_:
			if dist <= 1.0:
				return Vector2.ZERO
			return EnemyNav.move_dir(self, _player.global_position, delta)


func _walk(dir: Vector2, speed_mult: float, _delta: float) -> void:
	var ms: float = 1.0
	if status:
		ms = status.get_move_speed_mult()
	velocity = dir * move_speed * speed_mult * ms + _knockback_vel
	move_and_slide()


func _face(target: Vector2) -> void:
	if body_anim and body_anim.has_method("face_towards"):
		body_anim.face_towards(target.x - global_position.x)


# Pick an arena point away from the heroes so the party has to come to it.
func _pick_anchor() -> Vector2:
	var best: Vector2 = global_position
	var best_score: float = -INF
	var rx: float = _arena_half.x * 0.62
	var ry: float = _arena_half.y * 0.62

	for _i in range(16):
		var ang: float = randf() * TAU
		var cand: Vector2 = Vector2(cos(ang) * rx, sin(ang) * ry) * randf_range(0.45, 1.0)
		if not _walkable(cand):
			continue
		var score: float = _dist_to_nearest_hero(cand) - global_position.distance_to(cand) * 0.35
		if score > best_score:
			best_score = score
			best = cand
	return best


# A landing spot at a comfortable striking distance AROUND the hero - the
# "circle the player" hop. Prefers spots on the far side of where it is now so
# consecutive hops actually move it around you.
func _pick_near_spot() -> Vector2:
	if _player == null:
		return _pick_anchor()
	var band: Array = _movement.get("hop_range", [180.0, 300.0])
	var lo: float = float(band[0]) if band.size() > 0 else 180.0
	var hi: float = float(band[1]) if band.size() > 1 else 300.0
	var hero: Vector2 = _player.global_position
	var from_ang: float = (global_position - hero).angle()
	var best: Vector2 = Vector2.INF
	var best_score: float = -INF
	for _i in range(18):
		var ang: float = from_ang + PI * randf_range(0.35, 1.65) * (1.0 if randf() < 0.5 else -1.0)
		var cand: Vector2 = _clamp_arena(hero + Vector2(cos(ang), sin(ang)) * randf_range(lo, hi))
		if not _walkable(cand):
			continue
		var score: float = cand.distance_to(global_position) * 0.5 - absf(cand.distance_to(hero) - (lo + hi) * 0.5)
		if score > best_score:
			best_score = score
			best = cand
	return best if best != Vector2.INF else _pick_anchor()


func _dist_to_nearest_hero(p: Vector2) -> float:
	var best: float = 4000.0
	for h in get_tree().get_nodes_in_group("player"):
		if not (h is Node2D) or not (h as Node2D).visible:
			continue
		best = minf(best, (h as Node2D).global_position.distance_to(p))
	return best


# ---------------------------------------------------------------------------
# REPOSITION - the walking break-away (legacy/anchor modes only).
# ---------------------------------------------------------------------------

func _tick_repos(delta: float) -> void:
	state = State.CHASE
	_repos_t -= delta
	if _repos_t <= 0.0 or global_position.distance_to(_anchor) <= ANCHOR_ARRIVE:
		_mp = "roam"
		_anchor_hold = ANCHOR_REPICK
		return
	_walk(EnemyNav.move_dir(self, _anchor, delta),
		float(_movement.get("reposition_speed_mult", 1.5)) * _phase_speed_mult, delta)


func _maybe_reposition() -> bool:
	var every: int = int(_movement.get("reposition_every", 0))
	if every <= 0 or _moves_done < every:
		return false
	_moves_done = 0
	if _mode == "fly":
		# A flyer "breaks away" by banking hard to the far side of its orbit.
		_orbit_ang += PI
		_orbit_dir = -_orbit_dir
		return false
	if _mode == "hop":
		# Leapers break away by LEAPING across the arena, never by jogging.
		_begin_move(_hop_move("away"))
		return true
	_anchor  = _pick_anchor()
	_repos_t = float(_movement.get("reposition_time", 1.4))
	_mp = "repos"
	return true


# ---------------------------------------------------------------------------
# Move selection
# ---------------------------------------------------------------------------

func _pick_move(dist: float) -> Dictionary:
	var legal: Array = []
	var total_w: float = 0.0

	for mv in _moves:
		var m: Dictionary = mv
		var mid: String = String(m.get("id", ""))
		if float(_cds.get(mid, 0.0)) > 0.0:
			continue
		if _phase < int(m.get("phase_min", 1)):
			continue
		if _phase > int(m.get("phase_max", 99)):
			continue
		var band: Array = m.get("range", [0.0, 99999.0])
		var lo: float = float(band[0]) if band.size() > 0 else 0.0
		var hi: float = float(band[1]) if band.size() > 1 else 99999.0
		if dist < lo or dist > hi:
			continue
		# Leaps arc OVER walls, and a flyer's shots come from above - LOS only
		# gates grounded direct attacks.
		var kind: String = String(m.get("kind", ""))
		var needs_los: bool = bool(m.get("los", kind != "leap" and _mode != "fly"))
		if needs_los and _player != null \
		and not EnemyNav.has_line_of_sight(self, global_position, _player.global_position):
			continue
		# A summon with its adds already at cap is a wasted turn.
		if (kind == "summon" or m.has("then_summon")) and _adds_alive() >= _summon_cap(m):
			if kind == "summon":
				continue
		var w: float = maxf(0.01, float(m.get("weight", 1.0)))
		legal.append({"mv": m, "w": w})
		total_w += w

	if legal.is_empty():
		return {}

	var roll: float = randf() * total_w
	for entry in legal:
		roll -= float(entry["w"])
		if roll <= 0.0:
			return entry["mv"]
	return legal[legal.size() - 1]["mv"]


func _summon_cap(m: Dictionary) -> int:
	if m.has("then_summon"):
		return int((m["then_summon"] as Dictionary).get("max_alive", 4))
	return int(m.get("max_alive", 4))


# ---------------------------------------------------------------------------
# Move execution
# ---------------------------------------------------------------------------

func _begin_move(mv: Dictionary, is_repeat: bool = false) -> void:
	if not is_repeat:
		_cur = mv
		_rep_left = int(mv.get("repeat", 0))
		if _phase >= 2 and mv.has("repeat_p2"):
			_rep_left = int(mv["repeat_p2"])
		if _phase >= 3 and mv.has("repeat_p3"):
			_rep_left = int(mv["repeat_p3"])
	_mp  = "windup"
	_mt  = float(mv.get("repeat_windup", 0.25)) if is_repeat else float(mv.get("windup", 0.4))
	state = State.ATTACKING
	_is_winding_up = true
	_struck.clear()
	_emit_queue.clear()

	if _player != null:
		_face(_player.global_position)
	if _flash_timer <= 0.0:
		FX.apply_body_tint(_body_base, ATTACK_COLOR, WINDUP_STRENGTH)

	# Lock aim NOW so the telegraph never lies about where the hit lands.
	match String(mv.get("kind", "")):
		"charge": _lock_charge(mv)
		"leap":   _lock_leap(mv)

	_telegraph(mv)


func _telegraph(mv: Dictionary) -> void:
	var wind: float = _mt
	var kind: String = String(mv.get("kind", ""))

	match kind:
		"melee_arc":
			var reach: float = float(mv.get("reach", attack_range * 2.0))
			var dir: Vector2 = _aim_dir()
			if float(mv.get("arc_deg", 150.0)) >= 300.0:
				FX.spawn_danger_circle(global_position, reach, TELE_FILL, wind)
			else:
				FX.spawn_danger_circle(global_position + dir * reach * 0.55,
					reach * 0.62, TELE_FILL, wind)
		"aoe_self":
			FX.spawn_danger_circle(global_position,
				float(mv.get("radius", 130.0)), TELE_FILL, wind)
		"charge":
			FX.spawn_danger_beam(global_position, _lock_dir, _lock_len,
				float(mv.get("half_width", 34.0)), TELE_BEAM, wind)
		"leap":
			pass   # the tracking landing marker (_marker) is the telegraph
		"projectile":
			var d: Vector2 = _aim_dir()
			FX.spawn_danger_beam(global_position, d,
				_clamped_len(d, 420.0), 16.0, TELE_BEAM, wind)
		"radial":
			FX.spawn_danger_circle(global_position, 70.0, TELE_FILL, wind)
		"aoe_point", "hazard":
			pass   # every impact draws its own filling RED marker
		"summon", "reposition":
			FX.spawn_danger_circle(global_position, 60.0, TELE_FILL, wind)


func _tick_windup(delta: float) -> void:
	var as_mult: float = 1.0
	if status:
		as_mult = maxf(0.05, status.get_attack_speed_mult())
	_mt -= delta * as_mult
	if _mode == "fly":
		velocity = Vector2.ZERO
	else:
		velocity = _knockback_vel
		move_and_slide()

	# A leap's marker can already be hunting the hero during the crouch.
	if String(_cur.get("kind", "")) == "leap":
		_track_leap_target(delta)

	_set_move_anim(true)
	_windup_glow(true)

	if _mt <= 0.0:
		_windup_glow(false)
		_fire_move()


func _fire_move() -> void:
	_is_winding_up = false
	if _flash_timer <= 0.0:
		FX.clear_body_tint(_body_base)
	_set_move_anim(false)

	var kind: String = String(_cur.get("kind", ""))
	match kind:
		"melee_arc":  _do_melee_arc(_cur)
		"aoe_self":   _do_aoe_self(_cur)
		"aoe_point":  _do_aoe_point(_cur)
		"projectile": _do_projectile(_cur)
		"radial":     _do_radial(_cur)
		"hazard":     _do_hazard(_cur)
		"summon":     _do_summon(_cur)
		"charge":
			_travelled = 0.0
			_trail_acc = 0.0
			_mp = "active"
			if _mode == "fly" or bool(_cur.get("fly", false)):
				_set_ghost(true)
			return
		"leap":
			_leap_from = global_position
			_leap_t    = 0.0
			_leap_dur  = maxf(0.12, float(_cur.get("air_time", 0.55)))
			_leap_lift0 = _lift
			_mp = "active"
			state = State.ATTACKING
			return
		"reposition":
			_end_move()
			_anchor  = _pick_anchor()
			_repos_t = float(_movement.get("reposition_time", 1.4))
			_mp = "repos"
			return

	if _cur.has("then_summon"):
		_do_summon(_cur["then_summon"] as Dictionary)

	# Staggered patterns keep the boss planted until the last shot is out.
	if not _emit_queue.is_empty():
		_mp = "active"
		return
	_after_hit()


# Called when a move's damage is fully out. Repeats re-enter windup (re-aimed);
# otherwise the boss recovers - the punish window.
func _after_hit() -> void:
	if _rep_left > 0:
		_rep_left -= 1
		_begin_move(_cur, true)
		return
	_mp = "recover"
	_mt = float(_cur.get("recovery", 0.45))


func _tick_active(delta: float) -> void:
	match String(_cur.get("kind", "")):
		"charge": _tick_charge(delta)
		"leap":   _tick_leap(delta)
		_:
			_tick_emit(delta)


func _tick_recover(delta: float) -> void:
	var as_mult: float = 1.0
	if status:
		as_mult = maxf(0.05, status.get_attack_speed_mult())
	_mt -= delta * as_mult
	if _mode == "fly":
		velocity = Vector2.ZERO
	else:
		velocity = _knockback_vel
		move_and_slide()
	if _mt <= 0.0:
		_end_move()
		if not _maybe_reposition():
			_mp = "roam"


# Stamp the cooldown, bank the move, drop back to neutral.
func _end_move() -> void:
	var mid: String = String(_cur.get("id", ""))
	if mid != "" and not mid.begins_with("_"):
		_cds[mid] = float(_cur.get("cooldown", 2.0)) * _phase_cd_mult
		_moves_done += 1
	_gcd = _gcd_base * _phase_cd_mult
	state = State.CHASE
	_windup_glow(false)
	_set_ghost(_mode == "fly")


# ---------------------------------------------------------------------------
# Sequenced emissions (staggered strikes / projectile waves)
# ---------------------------------------------------------------------------

func _tick_emit(delta: float) -> void:
	if _mode == "fly":
		velocity = Vector2.ZERO
	else:
		velocity = _knockback_vel
		move_and_slide()
	if _player != null:
		_face(_player.global_position)
	_emit_t += delta
	while not _emit_queue.is_empty() and float((_emit_queue[0] as Dictionary)["t"]) <= _emit_t:
		var e: Dictionary = _emit_queue.pop_front()
		match String(e.get("what", "")):
			"strike":
				var p: Vector2 = e.get("pos", Vector2.INF)
				if p == Vector2.INF:
					p = _hero_point(float(_cur.get("lead", 0.0)))
				_spawn_strike(p, _cur)
			"wave":
				_fire_radial_wave(_cur, int(e.get("i", 0)))
			"volley":
				_fire_volley(_cur)
	if _emit_queue.is_empty():
		_after_hit()


# ---------------------------------------------------------------------------
# Move kinds
# ---------------------------------------------------------------------------

func _do_melee_arc(mv: Dictionary) -> void:
	# Status-driven whiff chance, same rule the grunt bite uses.
	if status:
		var miss: float = status.get_miss_chance()
		if miss > 0.0 and randf() < miss:
			FX.spawn_hit_particles(global_position, Color(0.85, 0.85, 0.85, 0.85), 5)
			return

	var reach: float = float(mv.get("reach", attack_range * 2.0))
	var half_arc: float = deg_to_rad(float(mv.get("arc_deg", 150.0)) * 0.5)
	var dir: Vector2 = _aim_dir()

	# Optional lunge: the boss steps INTO the swing (spear thrusts, pounces).
	var lunge: float = float(mv.get("lunge", 0.0))
	if lunge > 0.0:
		var step: float = _clamped_len(dir, lunge)
		var dest: Vector2 = global_position + dir * step
		if _walkable(dest):
			global_position = dest

	FX.spawn_swing_arc(global_position, dir, reach * 0.8)
	FX.screen_shake(4.0, 0.16)

	for h in _heroes():
		var to_h: Vector2 = (h as Node2D).global_position - global_position
		if to_h.length() > reach:
			continue
		if absf(dir.angle_to(to_h)) > half_arc:
			continue
		_strike(h, mv)


func _do_aoe_self(mv: Dictionary) -> void:
	var radius: float = float(mv.get("radius", 130.0))
	FX.spawn_burst_particles(global_position, Color(1.0, 0.55, 0.20, 0.9), 18)
	FX.spawn_explosion_ring(global_position, radius)
	FX.screen_shake(6.5, 0.26)
	for h in _heroes():
		if (h as Node2D).global_position.distance_to(global_position) <= radius:
			_strike(h, mv)
	_spawn_rings(global_position, mv.get("rings", []), mv, radius)


# Outward shockwave DONUTS: each ring hits only its own band, so the dodge is
# "step INTO the ring you just survived" - a classic Zelda read.
func _spawn_rings(center: Vector2, rings: Array, mv: Dictionary, prev: float) -> void:
	var inner: float = prev
	for r in rings:
		var rd: Dictionary = r
		var outer: float = float(rd.get("radius", inner + 90.0))
		var over: Dictionary = mv.duplicate()
		over["dmg_mult"] = float(rd.get("dmg_mult", float(mv.get("dmg_mult", 1.0)) * 0.8))
		var s: Node2D = _make_strike(center, over, outer, float(rd.get("delay", 0.4)))
		if s != null:
			s.set("inner_radius", inner)
		inner = outer


func _do_aoe_point(mv: Dictionary) -> void:
	var stagger: float = float(mv.get("stagger", 0.0))
	var pattern: String = String(mv.get("pattern", "scatter"))
	var count: int = maxi(1, int(mv.get("count", 1)))
	if _phase >= 2 and mv.has("count_p2"):
		count = int(mv["count_p2"])
	var pts: Array = [] if pattern == "chase" else _aoe_points(mv, count)
	FX.screen_shake(3.0, 0.14)

	if stagger <= 0.0 and pattern != "chase":
		for p in pts:
			_spawn_strike(p, mv)
		return
	# Sequenced: queue every impact; "chase" re-targets the hero at each beat.
	_emit_t = 0.0
	for i in range(count):
		var e: Dictionary = {"t": float(i) * maxf(stagger, 0.05), "what": "strike"}
		if pattern != "chase":
			e["pos"] = pts[i]
		_emit_queue.append(e)


func _spawn_strike(p: Vector2, mv: Dictionary) -> void:
	_make_strike(p, mv, float(mv.get("radius", 80.0)), float(mv.get("strike_delay", 0.75)))


func _make_strike(p: Vector2, mv: Dictionary, radius: float, delay: float) -> Node2D:
	var parent: Node = get_parent()
	if parent == null:
		return null
	var s: Node2D = Node2D.new()
	s.set_script(StrikeGD)
	s.set("radius", radius)
	s.set("delay", delay)
	s.set("owner_boss", self)
	var pay: Dictionary = _payload(mv)
	for k in pay.keys():
		s.set(k, pay[k])
	if mv.has("leave_hazard"):
		s.set("leave_hazard", _hazard_cfg(mv["leave_hazard"] as Dictionary))
	parent.add_child(s)
	s.global_position = p
	return s


func _do_projectile(mv: Dictionary) -> void:
	var waves: int = maxi(1, int(mv.get("waves", 1)))
	_fire_volley(mv)
	if waves > 1:
		_emit_t = 0.0
		for i in range(1, waves):
			_emit_queue.append({"t": float(i) * float(mv.get("wave_gap", 0.3)), "what": "volley"})


func _fire_volley(mv: Dictionary) -> void:
	var count: int = maxi(1, int(mv.get("count", 1)))
	var spread: float = deg_to_rad(float(mv.get("spread_deg", 0.0)))
	var base: Vector2 = _aim_dir()
	for i in range(count):
		var t: float = 0.0 if count == 1 else (float(i) / float(count - 1) - 0.5)
		_launch(base.rotated(t * spread), mv)
	FX.spawn_ranged_flash(global_position, base)


func _do_radial(mv: Dictionary) -> void:
	var waves: int = maxi(1, int(mv.get("waves", 1)))
	_fire_radial_wave(mv, 0)
	if waves > 1:
		_emit_t = 0.0
		for i in range(1, waves):
			_emit_queue.append({"t": float(i) * float(mv.get("wave_gap", 0.35)), "what": "wave", "i": i})


# A full ring of shots. Alternate waves rotate half a gap so the second ring
# fills the lanes the first one left open - you weave, you don't stand still.
func _fire_radial_wave(mv: Dictionary, i: int, center: Vector2 = Vector2.INF) -> void:
	var count: int = maxi(3, int(mv.get("count", 10)))
	var step: float = TAU / float(count)
	var off: float = randf() * step if i == 0 else step * 0.5 * float(i % 2)
	for k in range(count):
		_launch(Vector2.RIGHT.rotated(off + step * float(k)), mv, center)
	FX.screen_shake(3.0, 0.12)


func _launch(dir: Vector2, mv: Dictionary, from: Vector2 = Vector2.INF) -> void:
	if _projectile_scene == null:
		return
	var parent: Node = get_parent()
	if parent == null:
		return
	var origin: Vector2 = global_position if from == Vector2.INF else from
	var proj = _projectile_scene.instantiate()
	var sprite_path: String = String(mv.get("sprite", ""))
	if sprite_path != "":
		proj.set("custom_texture_path", sprite_path)
	parent.add_child(proj)
	proj.global_position = origin + dir * 26.0
	if proj.has_method("launch"):
		proj.launch(dir, float(mv.get("speed", 300.0)) * _phase_speed_mult,
			_out_damage(float(mv.get("dmg_mult", 1.0))))
	proj.set("max_range", float(mv.get("proj_range", 720.0)))
	# Per-move payload first, the roster's on-hit hooks as the fallback.
	proj.set("on_hit_poison_stacks", int(mv.get("poison_stacks", on_hit_poison_stacks)))
	proj.set("on_hit_poison_duration", float(mv.get("poison_duration", on_hit_poison_duration)))
	proj.set("on_hit_slow_stacks", int(mv.get("slow_stacks", on_hit_slow_stacks)))
	proj.set("on_hit_stun_duration", float(mv.get("stun", on_hit_stun_duration)))
	proj.set("on_hit_burn_stacks", int(mv.get("burn_stacks", on_hit_burn_stacks)))
	proj.set("on_hit_burn_duration", float(mv.get("burn_duration", on_hit_burn_duration)))


func _do_hazard(mv: Dictionary) -> void:
	var parent: Node = get_parent()
	if parent == null:
		return
	var count: int = maxi(1, int(mv.get("count", 1)))
	for p in _aoe_points(mv, count):
		var hz: Node2D = Node2D.new()
		hz.set_script(HazardGD)
		var cfg: Dictionary = _hazard_cfg(mv)
		for k in cfg.keys():
			hz.set(k, cfg[k])
		parent.add_child(hz)
		hz.global_position = p


# BossHazard property map from a move (or a "leave_hazard"/"land_hazard"/
# "trail_hazard" sub-dict).
func _hazard_cfg(mv: Dictionary) -> Dictionary:
	var cfg: Dictionary = {
		"radius": float(mv.get("radius", 78.0)),
		"duration": float(mv.get("duration", 4.0)),
		"warmup": float(mv.get("warmup", 0.55)),
		"tick_interval": float(mv.get("tick_interval", 0.6)),
		"tick_damage": int(round(float(attack_damage) * float(mv.get("tick_mult", 0.45)))),
		"status_id": String(mv.get("status", "")),
		"status_stacks": int(mv.get("stacks", 1)),
		"status_duration": float(mv.get("status_duration", 3.0)),
		"frost_stacks": int(mv.get("frost_stacks", 0)),
	}
	if mv.has("color"):
		cfg["pool_color"] = mv["color"]
	return cfg


func _do_summon(mv: Dictionary) -> void:
	if add_configs.is_empty():
		return
	var parent: Node = get_parent()
	if parent == null:
		return
	var count: int = maxi(1, int(mv.get("count", 2)))
	var cap: int = int(mv.get("max_alive", 4))
	var alive: int = _adds_alive()

	for _i in range(count):
		if alive >= cap:
			break
		var cfg: Dictionary = (add_configs[randi() % add_configs.size()] as Dictionary).duplicate(true)
		var scene_path: String = DB.ARCH_SCENES.get(String(cfg.get("arch", "melee")), DB.ARCH_SCENES["melee"])
		if not ResourceLoader.exists(scene_path):
			continue
		var e: Node = (load(scene_path) as PackedScene).instantiate()
		SPAWNER.apply_config(e, cfg, spawn_tier)
		e.add_to_group("boss_add")
		parent.add_child(e)
		if e is Node2D:
			var at: Vector2 = global_position
			for _t in range(8):
				var ang: float = randf() * TAU
				at = _clamp_arena(global_position + Vector2(cos(ang), sin(ang)) * randf_range(80.0, 150.0), 40.0)
				if _walkable(at):
					break
			(e as Node2D).global_position = at
			FX.spawn_burst_particles(at, Color(0.95, 0.70, 0.90, 0.9), 12)
		alive += 1


func _adds_alive() -> int:
	var n: int = 0
	for a in get_tree().get_nodes_in_group("boss_add"):
		if is_instance_valid(a):
			n += 1
	return n


# --- Charge ---------------------------------------------------------------

func _lock_charge(mv: Dictionary) -> void:
	_lock_dir = _aim_dir()
	var want: float = float(mv.get("distance", 520.0))
	if _mode == "fly" or bool(mv.get("fly", false)):
		# A dive crosses the arena above the rocks: only the arena edge stops it.
		_lock_len = _arena_len(_lock_dir, want)
	else:
		_lock_len = _clamped_len(_lock_dir, want)
	_travelled = 0.0


# Distance along dir before leaving the arena rectangle (with margin).
func _arena_len(dir: Vector2, want: float) -> float:
	var best: float = want
	var m: float = 50.0
	if absf(dir.x) > 0.001:
		var lim_x: float = ((_arena_half.x - m) * signf(dir.x) - global_position.x) / dir.x
		best = minf(best, lim_x)
	if absf(dir.y) > 0.001:
		var lim_y: float = ((_arena_half.y - m) * signf(dir.y) - global_position.y) / dir.y
		best = minf(best, lim_y)
	return maxf(60.0, best)


func _tick_charge(delta: float) -> void:
	var spd: float = float(_cur.get("speed", 420.0)) * _phase_speed_mult
	var step: float = spd * delta
	var flying: bool = _mode == "fly" or bool(_cur.get("fly", false))
	if flying:
		global_position = _clamp_arena(global_position + _lock_dir * step, 30.0)
		velocity = _lock_dir * spd
	else:
		velocity = _lock_dir * spd + _knockback_vel
		move_and_slide()
	_travelled += step

	# Fire / ice / brine left in the wake of the dive.
	if _cur.has("trail_hazard"):
		_trail_acc += step
		var every: float = float((_cur["trail_hazard"] as Dictionary).get("every", 90.0))
		if _trail_acc >= every:
			_trail_acc = 0.0
			var hz: Node2D = Node2D.new()
			hz.set_script(HazardGD)
			var cfg: Dictionary = _hazard_cfg(_cur["trail_hazard"] as Dictionary)
			cfg["warmup"] = 0.0
			for k in cfg.keys():
				hz.set(k, cfg[k])
			var parent: Node = get_parent()
			if parent != null:
				parent.add_child(hz)
				hz.global_position = global_position

	for h in _heroes():
		var hid: int = h.get_instance_id()
		if _struck.has(hid):
			continue
		if (h as Node2D).global_position.distance_to(global_position) <= float(_cur.get("hit_radius", 58.0)):
			_struck[hid] = true
			_strike(h, _cur)

	if _travelled >= _lock_len or (not flying and is_on_wall()):
		FX.screen_shake(6.0, 0.22)
		FX.spawn_burst_particles(global_position, Color(1.0, 0.6, 0.25, 0.9), 14)
		if _rep_left > 0:
			_struck.clear()
		_after_hit()


# --- Leap -----------------------------------------------------------------

func _lock_leap(mv: Dictionary) -> void:
	_leap_from = global_position
	_leap_locked = false
	_leap_track = float(mv.get("track", 0.0))
	_leap_h = float(mv.get("height", LEAP_HOP_PX))
	var target: Vector2
	match String(mv.get("target", "player")):
		"near":
			target = _pick_near_spot()
		"away":
			target = _pick_anchor()
		"center":
			target = Vector2.ZERO
		_:
			target = _hero_point(float(mv.get("lead", 0.0)))
	_leap_to = _settle_landing(target, float(mv.get("max_dist", 460.0)))

	# The landing marker. It lives for the whole windup + flight and, when the
	# leap tracks, slides after the hero until it locks.
	_free_marker()
	var parent: Node = get_parent()
	if parent != null and not bool(mv.get("no_damage", false)):
		_marker = Node2D.new()
		_marker.set_script(StrikeGD)
		_marker.set("radius", float(mv.get("radius", 110.0)))
		_marker.set("visual_only", true)
		_marker.set("owner_boss", self)
		parent.add_child(_marker)
		_marker.global_position = _leap_to
		if _leap_track <= 0.0:
			_marker.call("lock")
			_leap_locked = true


# Clamp a desired landing point to the leap range, the arena and real floor.
# A leap clamped only to arena bounds can land inside a rock and wedge the
# boss (Run 89's "no invisible wall" rule cuts both ways) - walk it back toward
# the take-off until it is on walkable floor.
func _settle_landing(target: Vector2, max_d: float) -> Vector2:
	var to_t: Vector2 = target - _leap_from
	if to_t.length() > max_d:
		to_t = to_t.normalized() * max_d
	var want: Vector2 = _clamp_arena(_leap_from + to_t)
	for step in range(7):
		var probe: Vector2 = _leap_from.lerp(want, 1.0 - 0.15 * float(step))
		if _walkable(probe):
			return probe
	return _leap_from


# While tracking, the landing spot homes in on the hero at a capped speed, so a
# player who keeps moving can outrun it - but only until it LOCKS.
func _track_leap_target(delta: float) -> void:
	if _leap_locked or _player == null or _marker == null:
		return
	var spd: float = float(_cur.get("track_speed", 280.0))
	var want: Vector2 = _settle_landing(_player.global_position, float(_cur.get("max_dist", 460.0)))
	_leap_to = _leap_to.move_toward(want, spd * delta)
	if is_instance_valid(_marker):
		_marker.global_position = _leap_to


func _tick_leap(delta: float) -> void:
	_leap_t += delta
	var t: float = clampf(_leap_t / _leap_dur, 0.0, 1.0)

	# Track for the first `track` seconds of flight, then LOCK (crosshair).
	if not _leap_locked:
		if _leap_t < _leap_track:
			_track_leap_target(delta)
		else:
			_leap_locked = true
			if _marker != null and is_instance_valid(_marker):
				_marker.call("lock")

	# Ease the ground track so the arc reads as a jump, not a slide.
	var e: float = t * t * (3.0 - 2.0 * t)
	global_position = _leap_from.lerp(_leap_to, e)
	velocity = Vector2.ZERO

	var burrow: bool = String(_cur.get("style", "jump")) == "burrow"
	if burrow:
		# Sink into the ground / brine, travel unseen, erupt under the target.
		var vis: float = absf(cos(t * PI))
		if body_anim and body_anim is CanvasItem:
			(body_anim as CanvasItem).modulate.a = clampf(vis, 0.0, 1.0)
		_lift = 0.0
		if randf() < 0.35:
			FX.spawn_burst_particles(global_position, Color(0.55, 0.45, 0.30, 0.7), 2)
	else:
		# Fake the arc by lifting the body art, not the collider. A flyer
		# plunges from its cruising height; a walker hops up and back down.
		_lift = _leap_lift0 * (1.0 - t) + sin(t * PI) * _leap_h
	_apply_lift()

	# Untouchable in the air (or underground). The window is the landing.
	_air_invuln = bool(_cur.get("air_invuln", true)) and t > 0.12 and t < 0.92

	if t >= 1.0:
		_air_invuln = false
		_lift = 0.0
		_apply_lift()
		if body_anim and body_anim is CanvasItem:
			(body_anim as CanvasItem).modulate.a = 1.0
		_free_marker()
		_land(_cur)


func _land(mv: Dictionary) -> void:
	_set_move_anim(false)
	var radius: float = float(mv.get("radius", 110.0))
	FX.spawn_burst_particles(global_position, Color(1.0, 0.55, 0.20, 0.9),
		10 if bool(mv.get("no_damage", false)) else 20)
	if not bool(mv.get("no_damage", false)):
		FX.spawn_explosion_ring(global_position, radius)
		FX.screen_shake(7.5, 0.28)
		for h in _heroes():
			if (h as Node2D).global_position.distance_to(global_position) <= radius:
				_strike(h, mv)
	else:
		FX.screen_shake(3.0, 0.14)

	# Landing extras - the Zelda "and THEN" beat.
	if mv.has("land_rings"):
		_spawn_rings(global_position, mv["land_rings"], mv, radius)
	if mv.has("land_radial"):
		var lr: Dictionary = (mv["land_radial"] as Dictionary).duplicate()
		for k in ["poison_stacks", "burn_stacks", "slow_stacks", "stun"]:
			if not lr.has(k) and mv.has(k):
				lr[k] = mv[k]
		_fire_radial_wave(lr, 0)
	if mv.has("land_hazard"):
		var parent: Node = get_parent()
		if parent != null:
			var hz: Node2D = Node2D.new()
			hz.set_script(HazardGD)
			var cfg: Dictionary = _hazard_cfg(mv["land_hazard"] as Dictionary)
			cfg["warmup"] = 0.0
			for k in cfg.keys():
				hz.set(k, cfg[k])
			parent.add_child(hz)
			hz.global_position = global_position
	if mv.has("then_summon"):
		_do_summon(mv["then_summon"] as Dictionary)

	# Consecutive leaps chain straight into the next crouch.
	if _rep_left > 0:
		_rep_left -= 1
		_begin_move(_cur, true)
		return
	_mp = "recover"
	_mt = float(mv.get("recovery", 0.55))


# Rigged bosses have no ColorRect parts for the inherited orange windup tint,
# so the wind-up reads as a hot pulse on the sprite itself.
func _windup_glow(on: bool) -> void:
	if body_anim == null or not (body_anim is CanvasItem):
		return
	var ci: CanvasItem = body_anim as CanvasItem
	var a: float = ci.modulate.a
	if on:
		var pulse: float = 0.5 + 0.5 * sin(float(Time.get_ticks_msec()) * 0.022)
		ci.modulate = Color(1.0, 0.55 + 0.30 * pulse, 0.45 + 0.30 * pulse, a)
	else:
		ci.modulate = Color(1.0, 1.0, 1.0, a)


func _free_marker() -> void:
	if _marker != null and is_instance_valid(_marker):
		_marker.call("release")
	_marker = null


# Flyers drop collision with walls (they are above them); grounded hosts keep it.
func _set_ghost(on: bool) -> void:
	if on:
		if _saved_mask < 0:
			_saved_mask = collision_mask
		collision_mask = 0
	elif _saved_mask >= 0:
		collision_mask = _saved_mask
		_saved_mask = -1


# ---------------------------------------------------------------------------
# Damage application
# ---------------------------------------------------------------------------

# The status/knockback payload of a move, resolved once. Shared by direct hits
# (_strike) and delayed impacts (BossStrike) so both behave identically.
func _payload(mv: Dictionary) -> Dictionary:
	var kb: float = float(mv.get("knockback", 0.0))
	if kb <= 0.0 and on_hit_knockback:
		kb = MELEE_KNOCKBACK
	return {
		"damage": _out_damage(float(mv.get("dmg_mult", 1.0))),
		"knockback": kb,
		"stun": float(mv.get("stun", 0.0)),
		"poison_stacks": int(mv.get("poison_stacks", 0)),
		"poison_duration": float(mv.get("poison_duration", 4.0)),
		"burn_stacks": int(mv.get("burn_stacks", 0)),
		"burn_duration": float(mv.get("burn_duration", 3.0)),
		"frost_stacks": int(mv.get("slow_stacks", 0)),
	}


# Every direct hit routes through here so on-hit statuses, knockback and the
# Frost Shield discount behave identically across all move kinds.
func _strike(h: Node, mv: Dictionary, origin: Vector2 = Vector2.INF) -> void:
	if not h.has_method("take_damage"):
		return
	var src: Vector2 = origin if origin != Vector2.INF else global_position
	var pay: Dictionary = _payload(mv)
	var kb: float = float(pay["knockback"])
	if kb > 0.0:
		var kdir: Vector2 = ((h as Node2D).global_position - src)
		if kdir.length() < 0.01:
			kdir = Vector2.DOWN
		h.take_damage(int(pay["damage"]), kdir.normalized() * kb)
	else:
		h.take_damage(int(pay["damage"]))

	# Roster on-hit payload (poison / frost slow / bash) - the monster's identity.
	StatusComponent.inflict_hero_status(h, self)

	var hs: Node = h.get_node_or_null("StatusComponent")
	if hs and hs.has_method("apply"):
		if on_hit_burn_stacks > 0:
			hs.apply("burning", on_hit_burn_duration, on_hit_burn_stacks)
		# Per-move payload on top.
		if float(pay["stun"]) > 0.0:
			hs.apply("bash", float(pay["stun"]), 1)
		if int(pay["poison_stacks"]) > 0:
			hs.apply("poison", float(pay["poison_duration"]), int(pay["poison_stacks"]))
		if int(pay["burn_stacks"]) > 0:
			hs.apply("burning", float(pay["burn_duration"]), int(pay["burn_stacks"]))
	if int(pay["frost_stacks"]) > 0 and h.has_method("add_frost_stack"):
		h.add_frost_stack(int(pay["frost_stacks"]))


func _out_damage(mult: float) -> int:
	var dmg: int = int(round(float(attack_damage) * mult))
	# Frost Shield duo: a chilled/frozen attacker hits softer.
	if status and (status.has("chilled") or status.has("frozen")):
		var red: float = float(RunState.get_frost_shield_reduction())
		if red > 0.0:
			dmg = int(round(float(dmg) * (1.0 - red)))
	return maxi(1, dmg)


func _heroes() -> Array:
	var out: Array = []
	for h in get_tree().get_nodes_in_group("player"):
		if not (h is Node2D) or not (h as Node2D).visible:
			continue
		if h.has_method("is_downed") and h.is_downed():
			continue
		out.append(h)
	return out


# ---------------------------------------------------------------------------
# Aiming helpers
# ---------------------------------------------------------------------------

func _aim_dir() -> Vector2:
	if _player == null:
		return Vector2.RIGHT
	var d: Vector2 = _player.global_position - global_position
	return d.normalized() if d.length() > 0.01 else Vector2.RIGHT


# The hero's position, optionally led by their velocity (seconds of lead).
func _hero_point(lead: float) -> Vector2:
	if _player == null:
		return global_position
	var p: Vector2 = _player.global_position
	if lead > 0.0 and _player.get("velocity") != null:
		p += (_player.velocity as Vector2) * lead
	return _clamp_arena(p, 40.0)


# Never paint or travel through a barrier (Run 90 rule).
func _clamped_len(dir: Vector2, want: float) -> float:
	var wall: float = EnemyNav.wall_distance(self, global_position, dir, want)
	return maxf(40.0, minf(want, wall))


# Impact points for aoe_point / hazard.
#   "scatter"     - centred on the hero (optionally led) + `count-1` around it
#   "line"        - a travelling fault line from the boss THROUGH the hero
#   "ring"        - a circle around the BOSS at ring_radius
#   "ring_player" - a circle closing around the HERO (leave through a gap)
#   "cross"       - plus-shape centred on the hero
func _aoe_points(mv: Dictionary, count: int = -1) -> Array:
	var pts: Array = []
	if count < 0:
		count = maxi(1, int(mv.get("count", 1)))
	var spread: float = float(mv.get("spread", 120.0))
	var centre: Vector2 = _hero_point(float(mv.get("lead", 0.0)))

	match String(mv.get("pattern", "scatter")):
		"line":
			var dir: Vector2 = _aim_dir()
			var gap: float = float(mv.get("spacing", 70.0))
			var start: float = float(mv.get("line_start", 60.0))
			for i in range(count):
				pts.append(_clamp_arena(global_position + dir * (start + gap * float(i)), 30.0))
		"ring":
			var rr: float = float(mv.get("ring_radius", 170.0))
			var off: float = randf() * TAU
			for i in range(count):
				var a: float = off + TAU * float(i) / float(count)
				pts.append(_clamp_arena(global_position + Vector2(cos(a), sin(a)) * rr, 30.0))
		"ring_player":
			var pr: float = float(mv.get("ring_radius", 150.0))
			var off2: float = randf() * TAU
			for i in range(count):
				var a2: float = off2 + TAU * float(i) / float(count)
				pts.append(_clamp_arena(centre + Vector2(cos(a2), sin(a2)) * pr, 30.0))
		"cross":
			var cg: float = float(mv.get("spacing", 80.0))
			pts.append(centre)
			var dirs: Array = [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]
			var ring: int = 1
			while pts.size() < count:
				for d in dirs:
					if pts.size() >= count:
						break
					pts.append(_clamp_arena(centre + (d as Vector2) * cg * float(ring), 30.0))
				ring += 1
		_:
			for i in range(count):
				if i == 0:
					pts.append(centre)
					continue
				var ang: float = TAU * float(i) / float(count) + randf() * 0.6
				var p: Vector2 = centre + Vector2(cos(ang), sin(ang)) * randf_range(spread * 0.5, spread)
				pts.append(_clamp_arena(p, 40.0))
	return pts


# ---------------------------------------------------------------------------
# Animation
# ---------------------------------------------------------------------------

func _set_move_anim(winding: bool) -> void:
	if body_anim == null or not body_anim.has_method("set_anim_state"):
		return
	var anim: String = String(_cur.get("anim", "smash"))
	if anim == "attack":
		body_anim.set_anim_state("windup_y" if winding else "swing_y")
	elif anim == "idle":
		body_anim.set_anim_state("idle")
	else:
		body_anim.set_anim_state("smash_windup" if winding else "smash_hit")


func _drive_anim() -> void:
	if body_anim == null or not body_anim.has_method("set_anim_state"):
		return
	body_anim.set_motion_speed(velocity.length())
	match _mp:
		"roam", "repos":
			if _mode == "fly":
				body_anim.set_anim_state("walking")   # the glide/flap strip
			else:
				body_anim.set_anim_state("walking" if velocity.length() > 6.0 else "idle")
		"active":
			var k: String = String(_cur.get("kind", ""))
			if k == "charge":
				body_anim.set_anim_state("walking")
			# leap: hold the crouch/raise pose from the windup through the air.
		_:
			pass   # windup / recover already pinned by _set_move_anim


# ---------------------------------------------------------------------------
# Overrides
# ---------------------------------------------------------------------------

func take_damage(amount: int, knockback_dir: Vector2 = Vector2.ZERO) -> void:
	if _air_invuln and state != State.DEAD:
		# Swings pass under a leaping boss - a grey puff says "not now".
		FX.spawn_hit_particles(global_position, Color(0.85, 0.85, 0.85, 0.7), 3)
		return
	super.take_damage(amount, knockback_dir)
	if get_node_or_null("/root/FX") and FX.has_method("notify_boss_hp"):
		FX.notify_boss_hp(current_hp, max_hp, boss_display_name)


func apply_status_dot_damage(amount: int, src_id: String) -> void:
	super.apply_status_dot_damage(amount, src_id)
	if get_node_or_null("/root/FX") and FX.has_method("notify_boss_hp"):
		FX.notify_boss_hp(current_hp, max_hp, boss_display_name)


# The AI-revive helper asks "is this thing about to hit me?"
func is_attack_imminent() -> bool:
	return state != State.DEAD and (_mp == "windup" or _mp == "active")


func _die() -> void:
	if get_node_or_null("/root/FX") and FX.has_method("unregister_boss"):
		FX.unregister_boss(self)
	_free_marker()
	_windup_glow(false)
	_air_invuln = false
	_emit_queue.clear()
	_lift = 0.0
	if body_anim and body_anim is Node2D:
		(body_anim as Node2D).position.y = 0.0
	if body_anim and body_anim is CanvasItem:
		(body_anim as CanvasItem).modulate.a = 1.0
	await super._die()
