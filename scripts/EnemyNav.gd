extends Node

# ============================================================
# EnemyNav.gd — Run 90 (2026-06-19) — barrier-aware enemy steering
# ============================================================
# Bruno's note (Run 89 follow-up): enemies were BEELINING straight at
# the player (to_player.normalized()) which jams them against rock
# barriers / interior slats and leaves them stuck behind walls near the
# exit. This autoload replaces the beeline with raycast-based steering
# that routes AROUND barriers — no navmesh, no baking, works on every
# procedural arena because it just probes the live World colliders.
#
# How it works (per enemy, per physics frame):
#   1. Cast a 3-ray "lane" (centre + two body-width whiskers) toward the
#      player. If it's clear → walk straight.
#   2. If blocked → fan outwards left/right in SCAN_STEP_DEG increments
#      and pick the SMALLEST turn that opens a clear lane. Commit to that
#      side for a short window (SIDE_HOLD) so the enemy hugs the wall
#      smoothly around the obstacle instead of jittering at the corner.
#   3. Smooth the heading (HEADING_SMOOTH) so turns read as decisions,
#      not twitches.
#   4. Stuck-sensor: if displacement stalls while we still want to move,
#      flip the committed detour side to pop out of dead-end pockets.
#
# Also exposes line-of-sight + wall-distance helpers so charge / laser
# telegraphs (and their hit math) can be clamped to the first barrier —
# a ground indicator must never paint or hit through a rock.
#
# World barriers (walls, gates, rock barriers, water) all live on 2D
# physics layer 1 = "World" (see project.godot). We probe only that
# layer, excluding the querying enemy itself.
# ============================================================

const WORLD_MASK: int = 1            # physics layer 1 = "World" (all barriers)

# --- Steering tunables ---
const LOOKAHEAD: float      = 90.0   # how far ahead we probe for a clear lane (px)
const BODY_RADIUS: float    = 15.0   # whisker offset so we clear corners by our width
const SCAN_STEP_DEG: float  = 18.0   # angular resolution of the detour fan
const SCAN_MAX_DEG: float   = 162.0  # widest detour considered before "fully boxed"
const HEADING_SMOOTH: float = 12.0   # lerp rate of heading toward the desired dir
const STUCK_SPEED: float    = 8.0    # px/s; below this (while wanting to move) = stalling
const STUCK_TIME: float     = 0.45   # seconds of stalling before we flip detour side
const SIDE_HOLD: float      = 0.80   # min seconds to commit to a chosen detour side

# --- Explore / lock-on tunables (Run 91) ---------------------------------
# When an enemy can't make headway toward the player (pinned behind a wall it
# can't round by local steering alone), it stops grinding against the barrier
# and instead WANDERS the arena — biased toward the player — until it either
# rounds the obstacle or re-gains line of sight, at which point it LOCKS back
# onto a direct chase.
const FRUSTRATION_TIME: float   = 1.10  # sec of zero progress toward player → start exploring
const PROGRESS_EPS: float       = 6.0   # px improvement in closest-distance that counts as "progress"
const EXPLORE_EXIT_PROGRESS: float = 56.0  # px closer than explore-start dist → snap back to chase
const EXPLORE_SPEED_SCALE: float   = 0.62  # wanderers move slower than a locked-on chaser
const EXPLORE_PROBE: float      = 240.0 # how far we ray-probe for open wander lanes (px)
const EXPLORE_MIN_OPEN: float   = 56.0  # a lane must be at least this open to be a candidate
const EXPLORE_STEP: float       = 170.0 # nominal distance of a wander waypoint
const EXPLORE_ARRIVE: float     = 26.0  # within this of the waypoint = arrived, pick another
const EXPLORE_REPICK: float     = 1.50  # sec before we re-pick a waypoint regardless
const EXPLORE_DIRS: int         = 16    # angular resolution of the 360° wander scan
const EXPLORE_PLAYER_BIAS: float = 1.70 # how strongly a lane toward the player is preferred
const EXPLORE_INERTIA: float    = 0.55  # prefer keeping current heading (smooth wandering)
const EXPLORE_JITTER: float     = 28.0  # random tie-breaker so wandering looks organic

# --- Barrier hop (stuck failsafe) -----------------------------------------
# If an enemy grinds against a DASHABLE interior barrier for too long, it
# does a little hop over — temporarily phases collision with dashable_barrier
# bodies so move_and_slide carries it past. Does NOT trigger for outer walls,
# gates, or leap_blocker geometry. Only fires when a raycast confirms the
# obstruction is actually a dashable_barrier.
const BARRIER_HOP_TRIGGER: float = 3.0    # accumulated stuck seconds before hop (explore starts at ~1.1s, so ~4s total)
const BARRIER_HOP_DURATION: float = 0.40  # hop airtime (visual arc)
const BARRIER_HOP_HEIGHT: float  = 28.0   # visual arc peak (px)
const BARRIER_HOP_GRACE: float   = 0.25   # collision stays off briefly after landing

# instance_id -> per-enemy nav state. Steering: {heading, side, side_timer,
# stuck_timer, last_pos}. Explore/lock-on: {mode, best_dist, frustration,
# explore_target, explore_timer, explore_start_dist}. Barrier hop:
# {barrier_stuck_accum, hopping, hop_elapsed, hop_dir, hop_body_y0}.
var _state: Dictionary = {}


# ---------------------------------------------------------------------------
# Per-enemy state
# ---------------------------------------------------------------------------

func _enemy_state(e: Node2D) -> Dictionary:
	var id: int = e.get_instance_id()
	if not _state.has(id):
		_state[id] = {
			"heading": Vector2.ZERO,
			"side": 0,           # -1 = turn left, +1 = turn right, 0 = none committed
			"side_timer": 0.0,
			"stuck_timer": 0.0,
			"last_pos": e.global_position,
			# explore / lock-on
			"mode": "chase",     # "chase" = beeline-with-detours, "explore" = wander
			"best_dist": INF,    # closest we've gotten to the player this chase
			"frustration": 0.0,  # time spent making no progress toward the player
			"explore_target": Vector2.ZERO,
			"explore_has_target": false,
			"explore_timer": 0.0,
			"explore_start_dist": 0.0,
			# barrier hop
			"barrier_stuck_accum": 0.0,
			"hopping": false,
			"hop_elapsed": 0.0,
			"hop_dir": Vector2.ZERO,
			"hop_body_y0": 0.0,
		}
	return _state[id]


# Drop state for enemies that have been freed.
func _gc() -> void:
	if _state.is_empty():
		return
	var stale: Array = []
	for id in _state.keys():
		if not is_instance_valid(instance_from_id(id)):
			stale.append(id)
	for id in stale:
		_state.erase(id)


# ---------------------------------------------------------------------------
# Public: barrier-aware movement direction
# ---------------------------------------------------------------------------

# Returns a direction the enemy should walk to reach `target` while routing
# around World barriers. Magnitude is 1.0 when locked on / chasing, and scaled
# down (EXPLORE_SPEED_SCALE) while wandering so explorers move slower — callers
# multiply this by move_speed, so the slowdown is automatic. Returns ZERO when
# essentially on top of target.
#
# Run 91: layers an explore / lock-on brain over the raw steering. If the enemy
# can't reach `target` (no progress for FRUSTRATION_TIME and no line of sight),
# it switches to WANDER — picking open lanes biased toward the player — instead
# of grinding face-first into the wall. The instant a clear line of sight opens
# it LOCKS back onto a direct chase.
func move_dir(enemy: Node2D, target: Vector2, delta: float) -> Vector2:
	if enemy == null or not is_instance_valid(enemy):
		return Vector2.ZERO
	_gc()
	var s: Dictionary = _enemy_state(enemy)
	var from: Vector2 = enemy.global_position
	var dist: float = from.distance_to(target)
	if dist < 1.0:
		return Vector2.ZERO

	# Decide chase vs explore, and what point we're actually steering toward.
	var nav: Dictionary = _resolve_target(enemy, from, target, dist, delta, s)
	var goal: Vector2 = nav["goal"]
	var speed_scale: float = nav["speed"]

	var to_g: Vector2 = goal - from
	var gdist: float = to_g.length()
	if gdist < 1.0:
		return Vector2.ZERO
	var desired: Vector2 = to_g / gdist
	var look: float = min(LOOKAHEAD, gdist)

	# Stuck tracking from actual displacement since last call.
	var moved: float = from.distance_to(s["last_pos"])
	s["last_pos"] = from
	if moved < STUCK_SPEED * delta:
		s["stuck_timer"] += delta
	else:
		s["stuck_timer"] = max(0.0, s["stuck_timer"] - delta * 2.0)

	# --- Barrier hop: accumulate while the enemy can't reach the player
	#     (explore mode = already frustrated), trigger when a dashable_barrier
	#     sits between us and the player. During the hop, phase collision. ---
	if s["hopping"]:
		var hop_result: Dictionary = _tick_barrier_hop(enemy, from, target, delta, s)
		return hop_result["dir"] * hop_result["speed"]

	# Accumulate hop pressure while in explore mode (already stuck ≥1.1s) OR
	# while physically stalled in chase mode. Decay when making real progress.
	if s["mode"] == "explore" or moved < STUCK_SPEED * delta:
		s["barrier_stuck_accum"] += delta
	else:
		s["barrier_stuck_accum"] = max(0.0, s["barrier_stuck_accum"] - delta * 2.0)

	if s["barrier_stuck_accum"] >= BARRIER_HOP_TRIGGER:
		# Check toward the PLAYER (target), not the current steering goal —
		# in explore mode `desired` points at a wander waypoint, not through
		# the barrier we actually need to clear.
		var to_player: Vector2 = (target - from).normalized()
		if _blocked_by_dashable(enemy, from, to_player):
			_start_barrier_hop(enemy, from, target, s)
			var hop_result: Dictionary = _tick_barrier_hop(enemy, from, target, delta, s)
			return hop_result["dir"] * hop_result["speed"]
		else:
			# Stuck on an outer wall / gate — reset so we don't re-check every frame.
			s["barrier_stuck_accum"] = BARRIER_HOP_TRIGGER * 0.5

	var chosen: Vector2 = desired
	if _lane_clear(enemy, from, desired, look):
		# Direct path open — relax the committed detour side.
		s["side_timer"] = max(0.0, s["side_timer"] - delta)
		if s["side_timer"] <= 0.0:
			s["side"] = 0
		s["stuck_timer"] = 0.0
	else:
		chosen = _detour(enemy, from, desired, look, s)

	# Smooth heading so direction changes read as deliberate.
	if s["heading"] == Vector2.ZERO:
		s["heading"] = chosen
	else:
		s["heading"] = s["heading"].lerp(chosen, clamp(HEADING_SMOOTH * delta, 0.0, 1.0))
		if s["heading"].length() < 0.01:
			s["heading"] = chosen
	return s["heading"].normalized() * speed_scale


# ---------------------------------------------------------------------------
# Explore / lock-on brain
# ---------------------------------------------------------------------------

# Picks the point we should actually steer toward this frame and the speed
# scale to use, mutating per-enemy chase/explore state. Returns
# {goal: Vector2, speed: float}.
func _resolve_target(enemy: Node2D, from: Vector2, player: Vector2,
		dist: float, delta: float, s: Dictionary) -> Dictionary:
	var los: bool = has_line_of_sight(enemy, from, player)

	# Progress = improving our closest-ever distance to the player. Each frame we
	# either improve (reset frustration) or stall (accumulate it).
	if dist < float(s["best_dist"]) - PROGRESS_EPS:
		s["best_dist"] = dist
		s["frustration"] = 0.0
	else:
		s["best_dist"] = min(float(s["best_dist"]), dist)
		s["frustration"] = float(s["frustration"]) + delta

	# A clear line of sight ALWAYS wins: lock straight onto the player.
	if los:
		if s["mode"] == "explore":
			s["mode"] = "chase"
		s["frustration"] = 0.0
		s["explore_has_target"] = false
		return {"goal": player, "speed": 1.0}

	# No LOS. If we've been making no headway, give up grinding and wander.
	if s["mode"] == "chase":
		if float(s["frustration"]) >= FRUSTRATION_TIME:
			_begin_explore(enemy, from, player, dist, s)
		else:
			return {"goal": player, "speed": 1.0}

	# --- explore mode ---
	# Snap back to chasing if wandering has carried us meaningfully closer; the
	# direct route may have opened up (or the player drifted toward us).
	if dist <= float(s["explore_start_dist"]) - EXPLORE_EXIT_PROGRESS:
		s["mode"] = "chase"
		s["explore_has_target"] = false
		s["frustration"] = 0.0
		return {"goal": player, "speed": 1.0}

	s["explore_timer"] = float(s["explore_timer"]) - delta
	var need_new: bool = not bool(s["explore_has_target"]) \
		or float(s["explore_timer"]) <= 0.0 \
		or from.distance_to(s["explore_target"]) <= EXPLORE_ARRIVE \
		or float(s["stuck_timer"]) >= STUCK_TIME
	if need_new:
		_pick_explore_target(enemy, from, player, s)
	return {"goal": s["explore_target"], "speed": EXPLORE_SPEED_SCALE}


func _begin_explore(enemy: Node2D, from: Vector2, player: Vector2,
		dist: float, s: Dictionary) -> void:
	s["mode"] = "explore"
	s["explore_start_dist"] = dist
	s["explore_has_target"] = false
	_pick_explore_target(enemy, from, player, s)


# Scan a full 360° fan of rays and choose an open lane to wander down, biased
# toward the player and toward the current heading (so the path stays smooth).
# Writes the chosen waypoint into s["explore_target"].
func _pick_explore_target(enemy: Node2D, from: Vector2, player: Vector2, s: Dictionary) -> void:
	var to_player: Vector2 = (player - from)
	if to_player.length() > 0.001:
		to_player = to_player.normalized()
	var head: Vector2 = s["heading"]
	var best_dir: Vector2 = Vector2.ZERO
	var best_open: float = 0.0
	var best_score: float = -1.0
	for i in EXPLORE_DIRS:
		var ang: float = TAU * float(i) / float(EXPLORE_DIRS)
		var dir: Vector2 = Vector2.from_angle(ang)
		var od: float = _open_dist(enemy, from, dir, EXPLORE_PROBE)
		if od < EXPLORE_MIN_OPEN:
			continue
		var toward: float = max(0.0, dir.dot(to_player))
		var inertia: float = max(0.0, dir.dot(head)) if head != Vector2.ZERO else 0.0
		var score: float = od * (1.0 + EXPLORE_PLAYER_BIAS * toward + EXPLORE_INERTIA * inertia)
		score += randf() * EXPLORE_JITTER
		if score > best_score:
			best_score = score
			best_dir = dir
			best_open = od
	s["explore_timer"] = EXPLORE_REPICK
	if best_dir == Vector2.ZERO:
		# Fully boxed: stand essentially still rather than charge a wall.
		s["explore_target"] = from
		s["explore_has_target"] = true
		return
	var reach: float = min(best_open - BODY_RADIUS, EXPLORE_STEP)
	reach = max(reach, 24.0)
	s["explore_target"] = from + best_dir * reach
	s["explore_has_target"] = true


# ---------------------------------------------------------------------------
# Barrier hop
# ---------------------------------------------------------------------------

# True if the first World barrier in `toward` direction is a dashable_barrier.
func _blocked_by_dashable(enemy: Node2D, from: Vector2, toward: Vector2) -> bool:
	var hit: Dictionary = _ray(enemy, from, from + toward.normalized() * LOOKAHEAD)
	if hit.is_empty():
		return false
	var collider = hit.get("collider")
	return collider != null and collider is Node and collider.is_in_group("dashable_barrier")


func _start_barrier_hop(enemy: Node2D, from: Vector2, target: Vector2, s: Dictionary) -> void:
	# Phase collision with all interior dashable barriers.
	if enemy.is_inside_tree():
		for b in enemy.get_tree().get_nodes_in_group("dashable_barrier"):
			if b is PhysicsBody2D:
				enemy.add_collision_exception_with(b)
	s["hopping"] = true
	s["hop_elapsed"] = 0.0
	s["hop_dir"] = (target - from).normalized()
	s["barrier_stuck_accum"] = 0.0
	s["stuck_timer"] = 0.0
	# Cache the Body node's local y so we can arc it and restore cleanly.
	var body: Node = enemy.get_node_or_null("Body")
	if body is Node2D:
		s["hop_body_y0"] = (body as Node2D).position.y


# Ticks the hop each frame. Returns {dir: Vector2, speed: float} for the
# caller to use as movement this frame.
func _tick_barrier_hop(enemy: Node2D, from: Vector2, target: Vector2,
		delta: float, s: Dictionary) -> Dictionary:
	s["hop_elapsed"] += delta
	var t: float = s["hop_elapsed"] / BARRIER_HOP_DURATION
	var total_time: float = BARRIER_HOP_DURATION + BARRIER_HOP_GRACE

	# Visual arc on the Body node (peak at mid-hop, settles back at landing).
	var body: Node = enemy.get_node_or_null("Body")
	if body is Node2D:
		if t <= 1.0:
			var arc: float = sin(PI * t) * BARRIER_HOP_HEIGHT
			(body as Node2D).position.y = s["hop_body_y0"] - arc
		else:
			(body as Node2D).position.y = float(s["hop_body_y0"])

	# End the hop after duration + grace.
	if s["hop_elapsed"] >= total_time:
		_end_barrier_hop(enemy, s)
		# Return normal chase toward target for this last frame.
		return {"dir": (target - from).normalized(), "speed": 1.0}

	return {"dir": Vector2(s["hop_dir"]), "speed": 1.0}


func _end_barrier_hop(enemy: Node2D, s: Dictionary) -> void:
	s["hopping"] = false
	# Restore Body y.
	var body: Node = enemy.get_node_or_null("Body")
	if body is Node2D:
		(body as Node2D).position.y = float(s["hop_body_y0"])
	# Remove all collision exceptions we added.
	if enemy.is_inside_tree():
		for b in enemy.get_tree().get_nodes_in_group("dashable_barrier"):
			if b is PhysicsBody2D:
				enemy.remove_collision_exception_with(b)


# ---------------------------------------------------------------------------
# Public: line-of-sight / wall distance helpers (for telegraph clamping)
# ---------------------------------------------------------------------------

# True if a straight line a → b is NOT broken by a World barrier.
func has_line_of_sight(node: Node2D, a: Vector2, b: Vector2) -> bool:
	return not _ray_hit(node, a, b)


# Distance from `origin` along `dir` to the first World barrier, capped at
# `max_dist`. Returns max_dist when nothing is hit.
func wall_distance(node: Node2D, origin: Vector2, dir: Vector2, max_dist: float) -> float:
	var d: Vector2 = dir.normalized()
	var hit: Dictionary = _ray(node, origin, origin + d * max_dist)
	if hit.is_empty():
		return max_dist
	return origin.distance_to(hit["position"])


# Like wall_distance but for a WIDE corridor: also probes the two edges offset
# by `half_width`, returning the nearest of the three so the clamp honours the
# full lane width (a barrier clipping the edge stops the lane too).
func corridor_distance(node: Node2D, origin: Vector2, dir: Vector2,
		max_dist: float, half_width: float) -> float:
	var d: Vector2 = dir.normalized()
	var perp: Vector2 = d.orthogonal() * half_width
	var best: float = wall_distance(node, origin, d, max_dist)
	best = min(best, wall_distance(node, origin + perp, d, max_dist))
	best = min(best, wall_distance(node, origin - perp, d, max_dist))
	return best


# ---------------------------------------------------------------------------
# Internal raycast helpers
# ---------------------------------------------------------------------------

func _ray(node: Node2D, a: Vector2, b: Vector2) -> Dictionary:
	if node == null or not is_instance_valid(node) or not node.is_inside_tree():
		return {}
	var space: PhysicsDirectSpaceState2D = node.get_world_2d().direct_space_state
	if space == null:
		return {}
	var q := PhysicsRayQueryParameters2D.create(a, b, WORLD_MASK, [node.get_rid()])
	q.collide_with_bodies = true
	q.collide_with_areas = false
	return space.intersect_ray(q)


func _ray_hit(node: Node2D, a: Vector2, b: Vector2) -> bool:
	return not _ray(node, a, b).is_empty()


# Center ray + two body-width whiskers must all be clear for `dist`.
func _lane_clear(enemy: Node2D, from: Vector2, dir: Vector2, dist: float) -> bool:
	var perp: Vector2 = dir.orthogonal() * BODY_RADIUS
	if _ray_hit(enemy, from, from + dir * dist):
		return false
	if _ray_hit(enemy, from + perp, from + perp + dir * dist):
		return false
	if _ray_hit(enemy, from - perp, from - perp + dir * dist):
		return false
	return true


# Open distance of a single centre ray along `dir`, capped at `length`.
func _open_dist(enemy: Node2D, from: Vector2, dir: Vector2, length: float) -> float:
	var hit: Dictionary = _ray(enemy, from, from + dir * length)
	if hit.is_empty():
		return length
	return from.distance_to(hit["position"])


# Fan outward from the desired heading to find the smallest clear turn.
func _detour(enemy: Node2D, from: Vector2, desired: Vector2, look: float, s: Dictionary) -> Vector2:
	# Stalling too long → flip the committed side to escape a pocket.
	if s["stuck_timer"] >= STUCK_TIME:
		s["side"] = (-s["side"]) if s["side"] != 0 else 1
		s["side_timer"] = SIDE_HOLD
		s["stuck_timer"] = 0.0

	var base_ang: float = desired.angle()
	var pref: int = s["side"] if s["side"] != 0 else 1
	var sides: Array = [pref, -pref]

	var deg: float = SCAN_STEP_DEG
	while deg <= SCAN_MAX_DEG:
		for side in sides:
			var cand: Vector2 = Vector2.from_angle(base_ang + deg_to_rad(deg) * side)
			if _open_dist(enemy, from, cand, look) >= look - 1.0:
				if s["side"] == 0:
					s["side"] = side
				s["side_timer"] = SIDE_HOLD
				return cand
		deg += SCAN_STEP_DEG

	# Fully boxed in — head toward the single most-open direction.
	return _best_open(enemy, from, desired, s)


# When no lane fully clears, pick the direction with the longest open ray,
# preferring the committed side on ties.
func _best_open(enemy: Node2D, from: Vector2, desired: Vector2, s: Dictionary) -> Vector2:
	var base_ang: float = desired.angle()
	var best: Vector2 = desired
	var best_d: float = _open_dist(enemy, from, desired, LOOKAHEAD)
	var pref: int = s["side"] if s["side"] != 0 else 1
	var deg: float = SCAN_STEP_DEG
	while deg <= 180.0:
		for side in [pref, -pref]:
			var cand: Vector2 = Vector2.from_angle(base_ang + deg_to_rad(deg) * side)
			var od: float = _open_dist(enemy, from, cand, LOOKAHEAD)
			if od > best_d + 0.5:
				best_d = od
				best = cand
		deg += SCAN_STEP_DEG
	return best
