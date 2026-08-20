extends Node

# ============================================================
# Telegraph.gd — Run 57 (2026-06-13) — global attack-telegraph coordinator
# ============================================================
# Two jobs:
#
#  1. CONCURRENCY CAP. Only a few enemies may be running a BIG aimed
#     ground-AoE attack (laser zap, charger rush, slime leap) at once.
#     Each such enemy calls request_slot(self) before it starts its
#     telegraph and release_slot(self) when the attack resolves. If the
#     cap is full the enemy keeps doing basic behaviour (move / small
#     melee) and retries next cooldown. This is the "no bullet hell"
#     safety: the player always gets windows to mow enemies down instead
#     of permanently dodging.  Small touch/swipe attacks DON'T use slots.
#
#  2. CONSISTENT TELEGRAPH VISUALS. One shared danger colour + two poly
#     builders (line corridor + landing circle) so every enemy's "dodge
#     out of here" zone reads identically: same amber, opaque enough to
#     pop but translucent enough to see the floor through.
#
# Registered as an autoload (see project.godot) so any enemy can call
# Telegraph.request_slot(...) / Telegraph.make_beam_poly(...) etc.
# ============================================================

# How many enemies may telegraph a big dodge-AoE simultaneously.
# Kid-friendly challenge: a handful of zones to watch, never a screen full.
const MAX_CONCURRENT_AOE: int = 3

# Shared danger palette — every enemy ground highlight uses these so the
# player learns ONE colour means "move." VIVID RED (Run 122): pure danger,
# clearly distinct from the player's own orange fire-element zones. Readable
# on every biome floor (sand, snow, swamp, lava, cake).
const AOE_COLOR:   Color = Color(0.95, 0.06, 0.06)   # base hue
const FILL_ALPHA:  float = 0.34                       # see-the-floor translucent fill
const EDGE_ALPHA:  float = 0.90                       # crisp readable border
const EDGE_WIDTH:  float = 3.0
# Hot flash colour for the instant an attack actually fires (zap / impact).
# Red-white hot so the resolve still reads as the same RED danger family.
const FIRE_COLOR:  Color = Color(1.00, 0.55, 0.45)

# instance_id -> true. Enemies currently holding an AoE slot.
var _active: Dictionary = {}


# ---------------------------------------------------------------------------
# Concurrency tokens
# ---------------------------------------------------------------------------

# Try to claim a big-AoE slot. Returns true and registers `who` if a slot is
# free, false if the global cap is already met. Idempotent: an enemy that
# already holds a slot always succeeds.
func request_slot(who: Node) -> bool:
	if who == null:
		return false
	_purge()
	var id: int = who.get_instance_id()
	if _active.has(id):
		return true
	if _active.size() >= MAX_CONCURRENT_AOE:
		return false
	_active[id] = true
	return true


func release_slot(who: Node) -> void:
	if who == null:
		return
	_active.erase(who.get_instance_id())


func has_slot(who: Node) -> bool:
	return who != null and _active.has(who.get_instance_id())


func active_count() -> int:
	_purge()
	return _active.size()


# Drop ids whose nodes were freed mid-attack (died while telegraphing).
func _purge() -> void:
	if _active.is_empty():
		return
	var stale: Array = []
	for id in _active.keys():
		if not is_instance_valid(instance_from_id(id)):
			stale.append(id)
	for id in stale:
		_active.erase(id)


# ---------------------------------------------------------------------------
# Shared telegraph poly builders
# ---------------------------------------------------------------------------
# These return the Polygon2D so the caller controls its lifetime (pulse during
# windup, flash on fire, free on resolve). They do NOT auto-fade — that's the
# point: a big dodge-zone must stay solid for the whole windup, then vanish the
# instant the hit lands. (FX.spawn_danger_circle/beam keep their auto-fade for
# the small melee tells.)

# Rectangular corridor from `origin` along `dir` (normalised) for `length`,
# `half_width` to each side. Used by laser zap + charger rush.
func make_beam_poly(parent: Node, origin: Vector2, dir: Vector2,
		length: float, half_width: float) -> Polygon2D:
	var poly := Polygon2D.new()
	poly.z_index = -1
	var d: Vector2 = dir.normalized()
	var perp: Vector2 = d.orthogonal()
	var pts := PackedVector2Array()
	pts.append(-perp * half_width)
	pts.append( perp * half_width)
	pts.append( perp * half_width + d * length)
	pts.append(-perp * half_width + d * length)
	poly.polygon = pts
	poly.color = Color(AOE_COLOR.r, AOE_COLOR.g, AOE_COLOR.b, FILL_ALPHA)
	poly.global_position = origin
	_add_edge(poly, pts)
	if parent and parent.is_inside_tree():
		parent.add_child(poly)
	else:
		var scene := get_tree().current_scene
		if scene:
			scene.add_child(poly)
	return poly


# Circular landing/impact zone. Used by slime leap + (optionally) stomps.
func make_circle_poly(parent: Node, center: Vector2, radius: float) -> Polygon2D:
	var poly := Polygon2D.new()
	poly.z_index = -1
	var pts := PackedVector2Array()
	var steps: int = 26
	for i in steps:
		var ang: float = TAU * i / steps
		pts.append(Vector2(cos(ang) * radius, sin(ang) * radius))
	poly.polygon = pts
	poly.color = Color(AOE_COLOR.r, AOE_COLOR.g, AOE_COLOR.b, FILL_ALPHA)
	poly.global_position = center
	_add_edge(poly, pts)
	if parent and parent.is_inside_tree():
		parent.add_child(poly)
	else:
		var scene := get_tree().current_scene
		if scene:
			scene.add_child(poly)
	return poly


# Forward cone / wedge from `origin` along `dir` for `length`, opening
# `half_angle_deg` to each side. Used by the jelly elemental breath (Run 135) —
# the arc matches the gameplay dot-product check so the painted zone is honest.
func make_cone_poly(parent: Node, origin: Vector2, dir: Vector2,
		length: float, half_angle_deg: float) -> Polygon2D:
	var poly := Polygon2D.new()
	poly.z_index = -1
	var base_ang: float = dir.angle()
	var half: float = deg_to_rad(half_angle_deg)
	var pts := PackedVector2Array()
	pts.append(Vector2.ZERO)
	var steps: int = 14
	for i in range(steps + 1):
		var ang: float = base_ang - half + (half * 2.0) * float(i) / float(steps)
		pts.append(Vector2(cos(ang), sin(ang)) * length)
	poly.polygon = pts
	poly.color = Color(AOE_COLOR.r, AOE_COLOR.g, AOE_COLOR.b, FILL_ALPHA)
	poly.global_position = origin
	_add_edge(poly, pts)
	if parent and parent.is_inside_tree():
		parent.add_child(poly)
	else:
		var scene := get_tree().current_scene
		if scene:
			scene.add_child(poly)
	return poly


# Brighten a telegraph poly to the hot FIRE_COLOR for the instant it resolves.
func flash_fire(poly: Polygon2D) -> void:
	if poly == null or not is_instance_valid(poly):
		return
	# Phase 6a — photosensitivity. This is the brightest single moment in the
	# game: the telegraph going off. Scaling only the ALPHA keeps the shape and
	# colour (and therefore the RED danger-read locked in Run 122) fully intact
	# while letting a sensitive player take the punch out of the flash.
	# Default 1.0 = unchanged.
	var fm: float = _flash_mult()
	poly.color = Color(FIRE_COLOR.r, FIRE_COLOR.g, FIRE_COLOR.b, 0.85 * fm)
	var edge: Line2D = poly.get_node_or_null("Edge") as Line2D
	if edge:
		edge.default_color = Color(FIRE_COLOR.r, FIRE_COLOR.g, FIRE_COLOR.b, 1.0 * fm)


# ---------------------------------------------------------------------------
# ⚠ FLOOR — a cosmetic setting must never hide a danger cue
# ---------------------------------------------------------------------------
# The telegraph fire flash is GAMEPLAY-CRITICAL information: it is the "this is
# happening NOW" read on an incoming attack. Scaling its alpha straight from the
# slider meant Flash Intensity 0 made it fully transparent — an accessibility
# option silently turning into a difficulty increase.
#
# So the 0..1 slider maps onto MIN_FLASH_MULT..1.0 instead of 0..1. At the
# lowest setting the flash is dimmed hard but still plainly visible; at the
# default it is bit-identical to the pre-Phase-6 build.
#
# Purely decorative flashes may use Settings.get_flash_mult() raw. Anything the
# player has to REACT to goes through this floor.
const MIN_FLASH_MULT: float = 0.45


## Player's flash-intensity preference, floored so the danger read survives.
## Returns 1.0 when Settings isn't up yet.
func _flash_mult() -> float:
	var s: Node = get_node_or_null("/root/Settings")
	if s != null and s.has_method("get_flash_mult"):
		return lerpf(MIN_FLASH_MULT, 1.0, clampf(float(s.get_flash_mult()), 0.0, 1.0))
	return 1.0


# Add a crisp border outline as a child Line2D so the zone edge is readable.
func _add_edge(poly: Polygon2D, pts: PackedVector2Array) -> void:
	var edge := Line2D.new()
	edge.name = "Edge"
	edge.width = EDGE_WIDTH
	edge.default_color = Color(AOE_COLOR.r, AOE_COLOR.g, AOE_COLOR.b, EDGE_ALPHA)
	edge.closed = true
	for p in pts:
		edge.add_point(p)
	poly.add_child(edge)
