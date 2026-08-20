extends Area2D
# ============================================================
# SnowballProjectile.gd — Popsicle Pelican FAST attack
# ============================================================
# A direct icy snowball that flies FAST in a straight line (the pelican's
# snap shot). Pure damage — no frost (frost is the popsicle-lob's job). Built
# entirely in code (no .tscn) so the Pelican host can just `.new()` it.
#
#   layer 16 (EnemyHitbox), mask 2|1 (Player + World) — hurts the player,
#   fizzles on walls like the generic EnemyProjectile.
# ============================================================

var speed:     float = 360.0
var damage:    int   = 10
var max_range: float = 720.0
const RADIUS:  float = 8.0

var direction: Vector2 = Vector2.RIGHT
var _traveled: float = 0.0
var _spin: float = 0.0


func _ready() -> void:
	# Run 168 — join "enemy_attack" so UltFreeze can stop this projectile with the
	# rest of the world during an ultimate. This node is parented to the SCENE,
	# not to the enemy that fired it, so disabling the shooter never stopped it —
	# a shot already in flight used to sail on and hit the partner who was pinned
	# in place by the ult freeze. That was one of the four holes behind Bruno's
	# "enemies continue to attack her" report. See UltFreeze.gd.
	add_to_group("enemy_attack")
	collision_layer = 16
	collision_mask  = 2 | 1
	var cs := CollisionShape2D.new()
	var sh := CircleShape2D.new()
	sh.radius = RADIUS
	cs.shape = sh
	add_child(cs)
	body_entered.connect(_on_body_entered)
	z_index = 6
	queue_redraw()


func launch(dir: Vector2, spd: float, dmg: int) -> void:
	direction = dir.normalized()
	speed = spd
	damage = dmg


func _physics_process(delta: float) -> void:
	var mv: Vector2 = direction * speed * delta
	position += mv
	_traveled += mv.length()
	_spin += delta * 12.0
	queue_redraw()
	if _traveled >= max_range:
		queue_free()


func _on_body_entered(body: Node) -> void:
	if body.is_in_group("player"):
		if body.has_method("take_damage"):
			body.take_damage(damage, Vector2.ZERO, "frost")
		FX.spawn_hit_particles(global_position, Color(0.75, 0.90, 1.0, 1.0), 7)
		FX.play_sound("enemy_projectile_hit", 0.6)
		queue_free()
	elif not body.is_in_group("enemy"):
		# Wall/barrier — shatter into ice flecks, don't phase through.
		FX.spawn_hit_particles(global_position, Color(0.75, 0.90, 1.0, 0.8), 5)
		queue_free()


func _draw() -> void:
	# Icy snowball: white core, cool-blue rim, a couple of glint flecks.
	draw_circle(Vector2.ZERO, RADIUS + 1.0, Color(0.40, 0.68, 0.95, 0.55))   # frosty aura
	draw_circle(Vector2.ZERO, RADIUS, Color(0.62, 0.82, 0.98, 1.0))          # rim
	draw_circle(Vector2.ZERO, RADIUS - 2.5, Color(0.94, 0.99, 1.0, 1.0))     # core
	var g: Vector2 = Vector2(cos(_spin), sin(_spin)) * (RADIUS - 3.5)
	draw_circle(g, 1.6, Color(1, 1, 1, 0.9))
