extends CharacterBody2D

# ============================================================
# DojoTrainingDummy.gd — Practice target in Shino's dojo room
# ============================================================
# Infinite HP. Shows floating damage numbers on every hit.
# Flashes red on hit, then fades back to normal.
# Tracks combo streak and total damage dealt this session.
# Added to the "enemy" group so Player.gd's hitbox + ki blast
# targeting recognise it as a valid target.
# ============================================================

const FLASH_DURATION: float  = 0.10
const RESET_DELAY: float     = 3.0    # seconds of no hits before streak resets

@onready var body_rect: ColorRect  = $BodyRect
@onready var name_label: Label     = $NameLabel
@onready var stats_label: Label    = $StatsLabel

var _combo_streak: int   = 0
var _total_damage: int   = 0
var _reset_timer: float  = 0.0
var _is_flashing: bool   = false

# Dummy has a StatusComponent so status effects (burn, poison, etc.) work on it.
var status: Node = null


func _ready() -> void:
	add_to_group("enemy")   # lets Player hitboxes and ki blasts hit it
	add_to_group("immovable")  # Run 115: katana push skips this
	collision_layer = 4     # Enemy layer
	collision_mask  = 1     # World walls

	if has_node("StatusComponent"):
		status = $StatusComponent

	_refresh_stats()


func _physics_process(delta: float) -> void:
	# Reset streak if no hits for RESET_DELAY seconds.
	if _combo_streak > 0:
		_reset_timer -= delta
		if _reset_timer <= 0.0:
			_combo_streak = 0
			_refresh_stats()
	# StatusComponent tick (burn/poison visual indicator, etc.)
	if status and status.has_method("tick"):
		status.tick(delta)


# Called by Player.gd / BeaAI.gd / projectile scripts.
func take_damage(amount: int, _knockback_dir: Vector2 = Vector2.ZERO) -> void:
	if amount <= 0:
		return

	_combo_streak += 1
	_total_damage  += amount
	_reset_timer   = RESET_DELAY
	_refresh_stats()
	_spawn_damage_number(amount)
	_flash_red()


func is_alive() -> bool:
	return true   # never dies


func _flash_red() -> void:
	if _is_flashing or body_rect == null:
		return
	_is_flashing = true
	var original: Color = Color(0.72, 0.50, 0.28, 1.0)
	body_rect.color = Color(1.0, 0.25, 0.20, 1.0)
	await get_tree().create_timer(FLASH_DURATION).timeout
	body_rect.color = original
	_is_flashing = false


func _spawn_damage_number(amount: int) -> void:
	var dmg_scene: PackedScene = load("res://scenes/DamageNumber.tscn")
	if dmg_scene == null:
		return
	var lbl: Node = dmg_scene.instantiate()
	var parent: Node = get_parent()
	if parent:
		parent.add_child(lbl)
		if lbl.has_method("setup"):
			lbl.setup(amount, global_position + Vector2(0, -20))


func _refresh_stats() -> void:
	if stats_label == null:
		return
	if _combo_streak > 0:
		stats_label.text = "Combo: %d\nTotal: %d" % [_combo_streak, _total_damage]
	else:
		stats_label.text = "Hit me!\nTotal: %d" % _total_damage
