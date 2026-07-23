extends Area2D
# ============================================================
# PopsicleProjectile.gd — Popsicle Pelican LOBBED attack
# ============================================================
# A slow popsicle lobbed in a high arc toward a target ground spot. When it
# lands it PLOPS and spawns a brief IcyPatch. A direct mid-air hit on a hero
# deals damage + 1 frost stack (and still plops a patch). Frost slows the hero
# (stacks handled hero-side via add_frost_stack()).
#
#   layer 16 (EnemyHitbox), mask 2 (Player only) — it ARCS OVER walls, so it
#   does not collide with World; it always reaches its target and plops.
# ============================================================

const ICY_PATCH := preload("res://scripts/IcyPatch.gd")

var speed:   float = 165.0      # ground travel speed (slow lob)
var damage:  int   = 10
const RADIUS: float = 9.0
const ARC_HEIGHT: float = 46.0  # peak visual lift of the arc

var _start: Vector2 = Vector2.ZERO
var _target: Vector2 = Vector2.ZERO
var _total: float = 0.0         # total travel time
var _t: float = 0.0
var _landed: bool = false
var _spin: float = 0.0
var _gfx: Node2D = null         # the popsicle, offset up by the arc height
var _cs: CollisionShape2D = null


func _ready() -> void:
	collision_layer = 16
	collision_mask  = 2            # Player only — the lob clears walls
	_cs = CollisionShape2D.new()
	var sh := CircleShape2D.new()
	sh.radius = RADIUS
	_cs.shape = sh
	add_child(_cs)
	body_entered.connect(_on_body_entered)
	z_index = 7
	_gfx = Node2D.new()
	_gfx.set_script(_GFX_SCRIPT)
	add_child(_gfx)
	queue_redraw()


# launch from `from` toward a ground point `to`. dmg = direct-hit damage.
func launch_lob(from: Vector2, to: Vector2, dmg: int) -> void:
	_start = from
	_target = to
	damage = dmg
	global_position = from
	var dist: float = from.distance_to(to)
	_total = max(0.35, dist / speed)
	# Run 138 — honest landing telegraph: paint the icy-patch footprint at the
	# lob's target for the whole flight, so the plop spot is dodged off a ground
	# cue (standard RED danger family), not just by eyeballing the arc. Sized to
	# the IcyPatch it spawns (radius 32) + a small forgiveness rim.
	FX.spawn_danger_circle(
		_target,
		34.0,
		Color(Telegraph.AOE_COLOR.r, Telegraph.AOE_COLOR.g, Telegraph.AOE_COLOR.b, 0.30),
		_total)


func _physics_process(delta: float) -> void:
	if _landed:
		return
	_t += delta
	_spin += delta * 6.0
	var f: float = clampf(_t / _total, 0.0, 1.0)
	global_position = _start.lerp(_target, f)
	# Parabola: 0 at ends, ARC_HEIGHT at midpoint. gfx floats up by this.
	var h: float = ARC_HEIGHT * 4.0 * f * (1.0 - f)
	if _gfx:
		_gfx.position = Vector2(0, -h)
		_gfx.rotation = _spin
		_gfx.set_meta("shadow_h", h)
		_gfx.queue_redraw()
	queue_redraw()
	if f >= 1.0:
		_plop()


func _on_body_entered(body: Node) -> void:
	if _landed:
		return
	if body.is_in_group("player"):
		if body.has_method("take_damage"):
			body.take_damage(damage, Vector2.ZERO, "frost")
		if body.has_method("add_frost_stack"):
			body.add_frost_stack(1)
		_plop()   # still leaves a small patch where it splattered
	# Note: no World mask, so walls never trigger this — the lob arcs over them.


func _plop() -> void:
	if _landed:
		return
	_landed = true
	set_deferred("monitoring", false)
	FX.spawn_hit_particles(global_position, Color(0.55, 0.78, 1.0, 1.0), 10)
	FX.play_sound("enemy_projectile_hit", 0.5)
	# Spawn the icy patch at the landing spot.
	var parent: Node = get_parent()
	if parent:
		var patch := Area2D.new()
		patch.set_script(ICY_PATCH)
		parent.add_child(patch)
		patch.global_position = global_position
	queue_free()


func _draw() -> void:
	# Ground shadow at the arc's landing point (parent origin tracks the ground).
	var h: float = float(_gfx.get_meta("shadow_h", 0.0)) if _gfx else 0.0
	var shrink: float = clampf(1.0 - h / (ARC_HEIGHT * 1.6), 0.35, 1.0)
	draw_set_transform(Vector2(0, 2), 0.0, Vector2(1.0, 0.5))
	draw_circle(Vector2.ZERO, (RADIUS + 2.0) * shrink, Color(0.05, 0.10, 0.18, 0.28))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# ---- Inline gfx drawer (child Node2D so it can float above the shadow) ----
const _GFX_SCRIPT := preload("res://scripts/PopsicleProjectileGfx.gd")
