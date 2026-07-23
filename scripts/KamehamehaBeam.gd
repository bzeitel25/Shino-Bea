extends Area2D

# ============================================================
# KamehamehaBeam.gd — Shino A-charge release (§8.2.1)
# ============================================================
# Long, thin line AoE beam emitted from Shino's position in the
# direction supplied by Player.gd (already snapped to the auto-aim
# target). Lives for `duration` and ticks damage on a fixed interval
# to every enemy currently overlapping the beam volume.
#
# Per GDD §8.2.1: "Long-range line AoE beam. Auto-aims to nearest
# enemy in forward cone on release; straight ahead if none." The
# Player handles the auto-aim pick; this scene just renders + damages
# along the snapped direction.
# ============================================================

@export var damage_per_tick: int = 9    # slight nerf to base; proximity mult makes up for it close-up
@export var tick_interval: float = 0.10
@export var duration: float = 0.40
@export var beam_length: float = 1000.0  # Run 47 — reaches across the arena; clipped to first wall at launch
@export var beam_width: float = 40.0     # Run 48 — widened again (24 → 34 → 40)

var direction: Vector2 = Vector2.RIGHT
var _age: float = 0.0
var _next_tick_at: float = 0.0
var _shape_node: CollisionShape2D = null
var _visual: ColorRect = null
var _glow_core: ColorRect = null


func _ready() -> void:
	# Big Broccoli: widen the beam by 1.5×.
	beam_width *= RunState.get_big_broccoli_aoe_mult()

	collision_layer = 8   # PlayerHitbox
	collision_mask = 4    # Enemy
	monitoring = true
	var rect_shape := RectangleShape2D.new()
	rect_shape.size = Vector2(beam_length, beam_width)
	_shape_node = CollisionShape2D.new()
	_shape_node.shape = rect_shape
	_shape_node.position = Vector2(beam_length * 0.5, 0.0)
	add_child(_shape_node)
	_visual = ColorRect.new()
	_visual.offset_left   = 0.0
	_visual.offset_top    = -beam_width * 0.5
	_visual.offset_right  = beam_length
	_visual.offset_bottom = beam_width * 0.5
	_visual.color = Color(0.30, 0.85, 1.0, 0.55)
	add_child(_visual)
	_glow_core = ColorRect.new()
	_glow_core.offset_left   = 0.0
	_glow_core.offset_top    = -beam_width * 0.20
	_glow_core.offset_right  = beam_length
	_glow_core.offset_bottom = beam_width * 0.20
	_glow_core.color = Color(0.92, 0.98, 1.0, 0.95)
	add_child(_glow_core)
	rotation = direction.angle()
	_next_tick_at = 0.0


func launch(dir: Vector2) -> void:
	if dir.length() > 0.01:
		direction = dir.normalized()
	rotation = direction.angle()
	_clip_to_walls()


# Run 47 — stop the beam at the first wall (layer 1) along its path, so it
# reads as "reaches the end of the arena" without punching through geometry.
func _clip_to_walls() -> void:
	var space := get_world_2d().direct_space_state
	if space == null:
		return
	var params := PhysicsRayQueryParameters2D.create(
		global_position, global_position + direction * beam_length, 1)
	params.exclude = [get_rid()]
	var hit: Dictionary = space.intersect_ray(params)
	if hit.is_empty():
		return
	_set_beam_length(maxf(40.0, (hit["position"] as Vector2).distance_to(global_position)))


func _set_beam_length(new_len: float) -> void:
	beam_length = new_len
	if _shape_node and _shape_node.shape is RectangleShape2D:
		_shape_node.shape.size = Vector2(beam_length, beam_width)
		_shape_node.position = Vector2(beam_length * 0.5, 0.0)
	if _visual:
		_visual.offset_right = beam_length
	if _glow_core:
		_glow_core.offset_right = beam_length


func _physics_process(delta: float) -> void:
	if _age >= _next_tick_at:
		_deal_tick()
		_next_tick_at += tick_interval
	_age += delta
	# Fade out across lifetime for a satisfying "beam dissipates" feel
	if _visual:
		var t: float = clamp(_age / duration, 0.0, 1.0)
		var fade: float = 1.0 - (t * 0.6)
		_visual.color.a = 0.55 * fade
		_glow_core.color.a = 0.95 * fade
	if _age >= duration:
		queue_free()


func _deal_tick() -> void:
	var bodies: Array = get_overlapping_bodies()
	var hits: int = 0
	var kills: int = 0
	# Route per-tick scaling through Player._scale_damage so Combo Master /
	# Noble Rot / Bunch Bonus all apply consistently. Beam ticks count as
	# "charge release" hits → is_finisher=true (Noble Rot amp applies).
	var player_ref: Node = null
	# Run 131 — Shino's charge beam; route through the Shino node (not players[0],
	# which can be Bea in 2P) and tag as "charge" so Fury Release applies.
	for cand in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(cand) and cand.has_method("_scale_damage") and not cand.is_in_group("bea"):
			player_ref = cand
			break
	var scaled: int
	if player_ref and player_ref.has_method("_scale_damage"):
		scaled = player_ref._scale_damage(damage_per_tick, true, false, null, "charge")
	else:
		scaled = max(1, int(round(damage_per_tick * RunState.get_char_damage_mult("shino") * RunState.roll_crit_mult())))   # Run 139 — beam is Shino-only
	for body in bodies:
		if body == null:
			continue
		if not body.is_in_group("enemy") or not body.has_method("take_damage"):
			continue
		var was_alive: bool = (not body.has_method("is_alive")) or body.is_alive()
		# Proximity bonus: 2× at point-blank, 1× at beam tip — rewards getting in close
		var dist_from_origin: float = (body.global_position - global_position).length()
		var proximity: float = clamp(1.0 - dist_from_origin / beam_length, 0.0, 1.0)
		var final_dmg: int = max(1, int(round(scaled * (1.0 + proximity))))
		body.set_meta("last_damager", "shino")   # Run 134 — killer attribution (fix 5)
		body.take_damage(final_dmg, direction)
		hits += 1
		if was_alive and body.has_method("is_alive") and not body.is_alive():
			kills += 1
		# Bananarang boon: charge ranged applies the heavier debuff (Greased/Bolted)
		# since it's a sustained charge attack rather than a quick tap.
		# Run 132 — owner-gated: this beam is Shino's A-charge, so gate on Shino's
		# ownership (was team-wide bananarang_taken, which leaked Bea's copy onto it).
		if RunState.shino_has("bananarang"):
			var ts: Variant = body.get("status") if body.has_method("get") else null
			if ts != null and ts.has_method("apply"):
				var ret_id: String = "bolted" if RunState.greased_lightning_mode else "greased"
				ts.apply(ret_id, 4.0, 1)
	if hits > 0:
		var player_nodes: Array = get_tree().get_nodes_in_group("player")
		if player_nodes.size() > 0:
			var p = player_nodes[0]
			if p.has_method("_on_charge_hits_dealt"):
				p._on_charge_hits_dealt(scaled, hits)
			if p.has_method("_apply_charge_kill_heal"):
				for _i in range(kills):
					p._apply_charge_kill_heal()
