extends "res://scripts/RangedShooter.gd"
# ============================================================
# PopcornPopper.gd — Popcorn Popper (caverns RANGED archetype) — Run 122
# ============================================================
# A caverns ranged shooter that spits TWO distinct popcorn jets, alternating —
# mirrors the Popsicle Pelican's two-attack structure but themed to BURN:
#
#   • SHORT JET — a fast, straight kernel volley (low arc, quick to arrive).
#   • BIG JET  — a slower, heavier kernel that pops on impact with a bigger
#     burst FX (popcorn_burst-style embers). Hits a little harder.
#
# Both shots carry the enemy's on-hit BURN payload (set from the roster's
# on_hit_burn field via DreamSpawner.apply_config), so either jet sizzles the
# hero briefly. No lingering ground patch (kept cheap per the Run 122 spec).
#
# The bespoke popcorn sprite (MonsterRig "popcorn") is swapped onto $Body by
# DreamSpawner.apply_config when the roster entry sets sprite_rig = "popcorn".
# Its two spit poses are driven via set_anim_state("fire_snowball") = short jet
# and ("fire_popsicle") = big jet (reusing the rig's two attack_fire_frames).
# ============================================================

# Short jet is fast; big jet is slower + a touch harder.
const SHORT_JET_SPEED: float = 340.0
const BIG_JET_SPEED:   float = 210.0
const BIG_JET_DMG_MULT: float = 1.35
const FIRE_POSE_HOLD:  float = 0.24

var _shot_parity: int = 0   # alternates short jet / big jet

# On-hit burn payload (mirrors the export fields on other hosts; set by
# DreamSpawner.apply_config). Popcorn's jets always sizzle.
@export var on_hit_burn_stacks: int = 1
@export var on_hit_burn_duration: float = 3.0


# Fully override the base single-projectile fire with the two-jet picker.
func _fire_shot() -> void:
	if _player == null:
		return
	var to_player: Vector2 = _player.global_position - global_position
	if to_player.length() < 1.0:
		return
	var dir: Vector2 = to_player.normalized()

	# Aim the mouth at the player (velocity is ~0 while lining up a shot).
	if body_anim and body_anim.has_method("face_towards"):
		body_anim.face_towards(dir.x)

	# Frost-shield chill (Run 23): a chilled/frozen popper fires weaker shots.
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
		_fire_jet(parent, muzzle, dir, dmg_out, SHORT_JET_SPEED, false)
		if body_anim and body_anim.has_method("set_anim_state"):
			body_anim.set_anim_state("fire_snowball")   # short-jet pose
	else:
		_fire_jet(parent, muzzle, dir, int(round(float(dmg_out) * BIG_JET_DMG_MULT)), BIG_JET_SPEED, true)
		if body_anim and body_anim.has_method("set_anim_state"):
			body_anim.set_anim_state("fire_popsicle")   # big-jet pose
	_shot_parity = 1 - _shot_parity
	_anim_lock_timer = FIRE_POSE_HOLD

	# Drop the magenta windup tint like the base shooter does.
	if _flash_timer <= 0.0:
		FX.clear_body_tint(_body_base)


func _fire_jet(parent: Node, muzzle: Vector2, dir: Vector2, dmg: int, spd: float, big: bool) -> void:
	if _projectile_scene == null:
		return
	var proj = _projectile_scene.instantiate()
	parent.add_child(proj)
	proj.global_position = muzzle
	if proj.has_method("launch"):
		proj.launch(dir, spd, dmg)
	# Both jets carry the burn payload — either kernel sizzles on contact.
	proj.set("on_hit_burn_stacks", on_hit_burn_stacks)
	proj.set("on_hit_burn_duration", on_hit_burn_duration)
	# Warm ember tint so the shot reads as a hot kernel (vs magenta base).
	var s: ColorRect = proj.get_node_or_null("Sprite") as ColorRect
	if s:
		s.color = Color(1.0, 0.72, 0.25, 1.0) if big else Color(1.0, 0.85, 0.45, 1.0)


# ── Run 122b — KAMIKAZE KETTLE ─────────────────────────────────────────────
# The popper's death strip literally ends in a kernel explosion, so death IS
# an attack: a short RED danger circle (dodge window synced to the topple
# frames), then an AoE pop that sizzles anyone still inside. This is also
# where popcorn_burst.png finally gets used — as the boom flash.
const BOOM_RADIUS:   float = 78.0
const BOOM_DELAY:    float = 1.50    # 1.5s flashing telegraph — dodge window
const BOOM_DMG_MULT: float = 1.25
const BOOM_SPR_SCALE: float = 0.164  # matches the rig's world scale


# Full override of the base shooter death (keeps its credit/sound beats, adds
# the telegraphed explosion before freeing).
func _die() -> void:
	state = State.DEAD
	FX.apply_body_tint(_body_base, Color(1.0, 1.0, 1.0, 1.0), 0.85)
	set_physics_process(false)
	FX.play_sound("enemy_die")
	# Run 131 — shared on-death boon hook (Juicebox, Wave Crash, Summer's End,
	# Rotten Core, Plague Layer — replaces the inline Juicebox broadcast).
	RunState.process_enemy_death_boons(self)
	# Flashing RED danger circle — 1.5s pulsing telegraph so the player can dodge.
	var boom_pos: Vector2 = global_position
	FX.spawn_flashing_danger_circle(boom_pos, BOOM_RADIUS, BOOM_DELAY)
	if body_anim and body_anim.has_method("set_anim_state"):
		body_anim.set_anim_state("death")
	var tree := get_tree()
	await tree.create_timer(BOOM_DELAY).timeout
	_kernel_boom(tree, boom_pos)
	queue_free()


func _kernel_boom(tree: SceneTree, pos: Vector2) -> void:
	var scene: Node = tree.current_scene
	if scene == null:
		return
	# Boom flash — popcorn_burst.png popped up and faded out.
	if ResourceLoader.exists("res://Assets/Sprites/popcorn_burst.png"):
		var spr := Sprite2D.new()
		spr.texture = load("res://Assets/Sprites/popcorn_burst.png")
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		spr.scale = Vector2(BOOM_SPR_SCALE, BOOM_SPR_SCALE) * 0.8
		spr.z_index = 5
		scene.add_child(spr)
		spr.global_position = pos + Vector2(0, -14)
		var tw := scene.create_tween()
		tw.tween_property(spr, "scale", Vector2(BOOM_SPR_SCALE, BOOM_SPR_SCALE) * 1.3, 0.16)
		tw.parallel().tween_property(spr, "modulate:a", 0.0, 0.32)
		tw.tween_callback(Callable(spr, "queue_free"))
	FX.spawn_burst_particles(pos, Color(1.0, 0.72, 0.25, 1.0), 18)
	FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_TINY)
	# AoE sizzle on anyone still inside the circle (downed heroes untouched).
	var dmg: int = maxi(1, int(round(float(shot_damage) * BOOM_DMG_MULT)))
	for h in tree.get_nodes_in_group("player"):
		if not (h is Node2D):
			continue
		if h.has_method("is_downed") and h.is_downed():
			continue
		if (h as Node2D).global_position.distance_to(pos) > BOOM_RADIUS:
			continue
		if h.has_method("take_damage"):
			var kdir: Vector2 = ((h as Node2D).global_position - pos).normalized()
			h.take_damage(dmg, kdir)
			if on_hit_burn_stacks > 0:
				var hs: Node = h.get_node_or_null("StatusComponent")
				if hs and hs.has_method("apply"):
					hs.apply("burning", on_hit_burn_duration, on_hit_burn_stacks)
