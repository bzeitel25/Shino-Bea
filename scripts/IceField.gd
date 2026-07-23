extends Area2D

# ============================================================
# IceField.gd — Run 92 (2026-06-19) — Frostpeak slippery ice
# ============================================================
# A single Area2D covering every FROZEN cell (rivers + lakes/puddles) in a
# Frostpeak room. Frozen ice is WALKABLE — there is NO collision body for it
# (DreamLayout marks ice walkable, DreamRoom skips the water collider) — so
# heroes can cross it freely. What this field does is FLAG the heroes standing
# on it (`on_ice` meta) so their locomotion switches to Mario-style momentum:
# hard to get moving, hard to stop, you keep sliding.
#
# Only group "player" bodies are flagged (enemies don't slip — keeps their nav
# stable). Built from DreamLayout.water_runs() (merged horizontal ice rects).
# Sits on no collision layer, masks the hero layer (2) like TrapZone.
# ============================================================

# --- Ice-glide tuning (shared by Player.gd + BeaAI.gd via IF.glide) ----------
# Lower = slipperier. ACCEL governs how fast you can change/build velocity while
# pushing a direction (low → "hard to build momentum"); BRAKE governs how fast
# you bleed speed while coasting (low → "you keep sliding").
const ICE_ACCEL: float = 560.0     # px/s² while a direction is held
const ICE_BRAKE: float = 230.0     # px/s² while coasting (no input)
# Run 116 — post-dash ice carry: fraction of DASH_SPEED the hero keeps when a
# dash ends on ice. 1.0 = full rocket, 0.0 = dead stop. 0.38 ≈ 360 px/s →
# noticeable slide-out without the old catapult.
const DASH_ICE_CARRY: float = 0.38


# Mario-ice velocity integration. `target` is the velocity the hero WOULD move
# at on solid ground this frame; returns the slid velocity. Call only while the
# body has the "on_ice" meta set.
static func glide(cur: Vector2, target: Vector2, has_input: bool, delta: float) -> Vector2:
	var rate: float = ICE_ACCEL if has_input else ICE_BRAKE
	return cur.move_toward(target, rate * delta)


func setup(runs: Array) -> void:
	name = "IceField"
	collision_layer = 0
	collision_mask = 2                 # hero layer (mirrors TrapZone)
	monitoring = true
	monitorable = false
	add_to_group("ice_field")
	for run in runs:
		var cs := CollisionShape2D.new()
		var sh := RectangleShape2D.new()
		sh.size = run.size
		cs.shape = sh
		cs.position = run.pos
		add_child(cs)
	body_entered.connect(_on_enter)
	body_exited.connect(_on_exit)
	# Safety: if the field is freed while a hero still overlaps (room change),
	# clear the flag so nobody carries "on_ice" into a room with no ice.
	tree_exiting.connect(_clear_all)


func _clear_all() -> void:
	for b in get_overlapping_bodies():
		if b != null and is_instance_valid(b) and b.is_in_group("player"):
			b.set_meta("on_ice", false)


func _on_enter(body: Node) -> void:
	if body != null and body.is_in_group("player"):
		body.set_meta("on_ice", true)


func _on_exit(body: Node) -> void:
	if body != null and is_instance_valid(body) and body.is_in_group("player"):
		body.set_meta("on_ice", false)
