extends Area2D
# ============================================================
# EnemyProjectile.gd — generic enemy ranged shot
# ============================================================
# Inverse of KiBlast: layer EnemyHitbox (16), mask Player (2).
# Damages the player on contact, then despawns. Despawns at max_range.
#
# Spawned by RangedShooter.gd via launch(dir, speed, damage).
# Visual is tinted magenta-pink to distinguish from Shino's cyan Ki Blast.
# ============================================================

@export var speed:     float = 280.0
@export var damage:    int   = 10
@export var max_range: float = 720.0
# Run 122 — optional on-hit status payload the shooter stamps on this projectile.
# Applied to the hero on contact via StatusComponent.inflict_hero_status. 0 = none.
@export var on_hit_poison_stacks: int = 0
@export var on_hit_poison_duration: float = 4.0
@export var on_hit_slow_stacks: int = 0
@export var on_hit_stun_duration: float = 0.0
# Run 122 — burn payload (e.g. Popcorn Popper's sizzling kernels).
@export var on_hit_burn_stacks: int = 0
@export var on_hit_burn_duration: float = 3.0

var direction: Vector2 = Vector2.DOWN
var _traveled: float = 0.0
# Run 140 — optional custom sprite texture for the projectile (e.g. chocofrog dart).
# If set before _ready(), replaces the default ColorRect with a Sprite2D.
var custom_texture_path: String = ""

@onready var sprite: ColorRect = $Sprite


func _ready() -> void:
	# Run 168 — join "enemy_attack" so UltFreeze can stop this projectile with the
	# rest of the world during an ultimate. This node is parented to the SCENE,
	# not to the enemy that fired it, so disabling the shooter never stopped it —
	# a shot already in flight used to sail on and hit the partner who was pinned
	# in place by the ult freeze. That was one of the four holes behind Bruno's
	# "enemies continue to attack her" report. See UltFreeze.gd.
	add_to_group("enemy_attack")
	collision_layer = 16       # EnemyHitbox
	collision_mask  = 2 | 1    # Player + World (Run 90 — stop on walls, no phasing through rocks)
	body_entered.connect(_on_body_entered)
	# Run 140 — swap ColorRect for a real sprite when a custom texture is provided.
	# Run 150 — the parent node rotates via `direction.angle() - PI/2` (assumes a
	# DOWN-facing default). Custom sprites face RIGHT, so rotate the child +PI/2
	# to compensate → dart always points in the travel direction.
	if custom_texture_path != "" and ResourceLoader.exists(custom_texture_path):
		var tex: Texture2D = load(custom_texture_path)
		if tex:
			var sp := Sprite2D.new()
			sp.texture = tex
			sp.scale = Vector2(0.35, 0.35)   # dart master is large; scale to projectile size
			sp.rotation = PI / 2.0            # compensate parent's -PI/2 offset
			add_child(sp)
			$Sprite.visible = false
			$Core.visible = false


func launch(dir: Vector2, spd: float, dmg: int) -> void:
	direction = dir.normalized()
	speed = spd
	damage = dmg
	rotation = direction.angle() - PI / 2.0


func _physics_process(delta: float) -> void:
	var move_vec: Vector2 = direction * speed * delta
	position += move_vec
	_traveled += move_vec.length()
	if _traveled >= max_range:
		queue_free()


func _on_body_entered(body: Node) -> void:
	if body.is_in_group("player"):
		if body.has_method("take_damage"):
			body.take_damage(damage)
			# Run 122 — poison / slow / stun on-hit hooks carried by this shot.
			StatusComponent.inflict_hero_status(body, self)
			# Burn payload (Popcorn Popper kernels sizzle on contact).
			if on_hit_burn_stacks > 0:
				var bhs: Node = body.get_node_or_null("StatusComponent")
				if bhs and bhs.has_method("apply"):
					bhs.apply("burning", on_hit_burn_duration, on_hit_burn_stacks)
		# Phase 7 — magenta impact particles (player's take_damage handles shake)
		FX.spawn_hit_particles(global_position, Color(0.95, 0.30, 0.95, 1.0), 6)
		FX.play_sound("enemy_projectile_hit", 0.6)
		queue_free()
	else:
		# Run 90 — hit a wall/barrier (World layer): fizzle out instead of phasing.
		FX.spawn_hit_particles(global_position, Color(0.95, 0.30, 0.95, 0.8), 4)
		queue_free()
