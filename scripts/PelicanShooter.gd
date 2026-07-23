extends "res://scripts/RangedShooter.gd"
# ============================================================
# PelicanShooter.gd — Popsicle Pelican (beach RANGED archetype)
# ============================================================
# Replaces the generic ranged/lobber shooter on the beach. Same kite + windup +
# stun + death loop as RangedShooter, but fires TWO distinct attacks, alternating:
#
#   • SNOWBALL — a fast, straight icy shot (SnowballProjectile). Pure damage.
#   • POPSICLE — a slow, high-arc LOB (PopsicleProjectile) aimed at the hero's
#     feet. It plops into a brief IcyPatch; a direct hit or standing on the patch
#     applies Frost stacks that slow the hero.
#
# The bespoke pelican sprite (MonsterRig "pelican") is swapped onto $Body by
# DreamSpawner.apply_config when the roster entry sets sprite_rig = "pelican".
# We drive its two fire poses via set_anim_state("fire_snowball"/"fire_popsicle")
# and aim its beak with face_towards().
# ============================================================

const SNOWBALL := preload("res://scripts/SnowballProjectile.gd")
const POPSICLE := preload("res://scripts/PopsicleProjectile.gd")

# Snowball flies faster than the base shot; popsicle is a slow lob (its own speed).
const SNOWBALL_SPEED: float = 360.0
const FIRE_POSE_HOLD: float = 0.24
# Popsicle scatter around the hero's feet so the lob isn't pixel-perfect.
const LOB_SCATTER: float = 26.0

var _shot_parity: int = 0   # alternates snowball / popsicle


# Fully override the base single-projectile fire with the two-attack picker.
func _fire_shot() -> void:
	if _player == null:
		return
	var to_player: Vector2 = _player.global_position - global_position
	if to_player.length() < 1.0:
		return
	var dir: Vector2 = to_player.normalized()

	# Aim the beak at the player (velocity is ~0 while lining up a shot).
	if body_anim and body_anim.has_method("face_towards"):
		body_anim.face_towards(dir.x)

	# Frost-shield chill (Run 23): a chilled/frozen pelican fires weaker shots.
	var dmg_out: int = shot_damage
	if status and (status.has("chilled") or status.has("frozen")):
		var fs_red: float = float(RunState.get_frost_shield_reduction())
		if fs_red > 0.0:
			dmg_out = maxi(1, int(round(float(dmg_out) * (1.0 - fs_red))))

	var parent: Node = get_parent()
	if parent == null:
		return
	var muzzle: Vector2 = global_position + dir * 20.0 + Vector2(0, -6)

	if _shot_parity == 0:
		_fire_snowball(parent, muzzle, dir, dmg_out)
		if body_anim and body_anim.has_method("set_anim_state"):
			body_anim.set_anim_state("fire_snowball")
	else:
		_fire_popsicle(parent, muzzle, dmg_out)
		if body_anim and body_anim.has_method("set_anim_state"):
			body_anim.set_anim_state("fire_popsicle")
	_shot_parity = 1 - _shot_parity
	_anim_lock_timer = FIRE_POSE_HOLD

	# Drop the magenta windup tint like the base shooter does.
	if _flash_timer <= 0.0:
		FX.clear_body_tint(_body_base)


func _fire_snowball(parent: Node, muzzle: Vector2, dir: Vector2, dmg: int) -> void:
	var proj := Area2D.new()
	proj.set_script(SNOWBALL)
	parent.add_child(proj)
	proj.global_position = muzzle
	if proj.has_method("launch"):
		proj.launch(dir, SNOWBALL_SPEED, dmg)


func _fire_popsicle(parent: Node, muzzle: Vector2, dmg: int) -> void:
	var target: Vector2 = _player.global_position + Vector2(
		randf_range(-LOB_SCATTER, LOB_SCATTER),
		randf_range(-LOB_SCATTER, LOB_SCATTER))
	var proj := Area2D.new()
	proj.set_script(POPSICLE)
	parent.add_child(proj)
	if proj.has_method("launch_lob"):
		proj.launch_lob(muzzle, target, dmg)
