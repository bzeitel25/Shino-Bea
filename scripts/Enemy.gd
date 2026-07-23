extends CharacterBody2D

# ============================================================
# DummyEnemy.gd — placeholder testable enemy (Phase 2)
# ============================================================
# Stationary green square with HP. Takes damage from player
# attacks. Flashes red briefly and gets knocked back on hit.
# Phase 5 will add AI walking + attacking.
# ============================================================

@export var max_hp: int = 30
@export var current_hp: int = 30
@export var knockback_strength: float = 220.0
@export var hit_flash_duration: float = 0.10
@export var stagger_duration: float = 0.15

@onready var sprite: ColorRect = $Sprite
@onready var hp_label: Label = $HPLabel

var knockback_velocity: Vector2 = Vector2.ZERO
var stagger_timer: float = 0.0
var flash_timer: float = 0.0
var base_color: Color = Color(0.30, 0.70, 0.35, 1.0)
var flash_color: Color = Color(1.0, 0.3, 0.3, 1.0)


func _ready() -> void:
	add_to_group("enemy")
	current_hp = max_hp
	if sprite:
		sprite.color = base_color
	_update_hp_label()


func _physics_process(delta: float) -> void:
	if flash_timer > 0.0:
		flash_timer -= delta
		if flash_timer <= 0.0 and sprite:
			sprite.color = base_color

	if stagger_timer > 0.0:
		stagger_timer -= delta

	# Apply knockback decay
	if knockback_velocity.length() > 1.0:
		velocity = knockback_velocity
		knockback_velocity = knockback_velocity.lerp(Vector2.ZERO, delta * 6.0)
	else:
		velocity = Vector2.ZERO

	move_and_slide()


func take_damage(amount: int, knockback_dir: Vector2 = Vector2.ZERO) -> void:
	current_hp = max(0, current_hp - amount)
	_update_hp_label()
	_hit_reaction(amount, knockback_dir)
	if current_hp <= 0:
		_die()


# Run 55 — DoT damage path (no hit-flash). Legacy placeholder has no
# StatusComponent so this is defensive, kept for API parity with other enemies.
func apply_status_dot_damage(amount: int, _src_id: String) -> void:
	var dmg: int = max(1, amount)
	current_hp = max(0, current_hp - dmg)
	_update_hp_label()
	_spawn_damage_number(dmg)
	if current_hp <= 0:
		_die()


func _hit_reaction(amount: int, knockback_dir: Vector2 = Vector2.ZERO) -> void:
	if sprite:
		sprite.color = flash_color
	flash_timer = hit_flash_duration
	stagger_timer = stagger_duration

	# Run 49 — knockback vector length acts as a strength scalar (clamped ≤1.0).
	var kb_scale: float = minf(knockback_dir.length(), 1.0) if knockback_dir.length() > 0.01 else 1.0
	var player = get_tree().current_scene.find_child("Player", true, false)
	if player and player is Node2D:
		var dir = (global_position - player.global_position).normalized()
		knockback_velocity = dir * knockback_strength * kb_scale

	_spawn_damage_number(amount)


func _spawn_damage_number(amount: int) -> void:
	var label = Label.new()
	label.text = str(amount)
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", Color(1, 1, 0.5, 1))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	label.add_theme_constant_override("outline_size", 4)
	label.position = global_position + Vector2(-12, -40)
	label.z_index = 100
	get_tree().current_scene.add_child(label)

	var tween = label.create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "position:y", label.position.y - 30, 0.7)
	tween.tween_property(label, "modulate:a", 0.0, 0.7)
	tween.chain().tween_callback(label.queue_free)


func _update_hp_label() -> void:
	if hp_label:
		hp_label.text = "%d/%d" % [current_hp, max_hp]


func _die() -> void:
	# Run 134 — route through the shared on-death boon hook so this legacy
	# placeholder also fires killer-attributed on-kill boons (fix 5 / resolves the
	# Wiring_Gaps "Enemy._die() has no boon notification" row).
	RunState.process_enemy_death_boons(self)
	queue_free()
