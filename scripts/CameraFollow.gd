extends Camera2D

# ============================================================
# CameraFollow.gd — top-down camera tracking the player(s)
# ============================================================
# 1P: smooth-follows whichever ninja is currently player-controlled (the
#     hot-swap target), keeping the scene's authored zoom.
# 2P (Run 73): frames BOTH ninjas — centers on their midpoint and eases the
#     zoom so both stay on-screen with a comfortable margin, never zooming in
#     past the authored zoom and never so far out that a ninja leaves view.
# ============================================================

@export var target_path: NodePath
@export var follow_speed: float = 8.0  # higher = snappier follow
@export var follow_enabled: bool = true

var target: Node2D = null

# --- 2P framing tunables ---
const TWOP_MARGIN: Vector2 = Vector2(260.0, 220.0)  # world px padding around the pair
const TWOP_ZOOM_LERP: float = 5.0                    # zoom easing speed
var _default_zoom: Vector2 = Vector2(1.5, 1.5)       # authored zoom = tightest (max-in) bound
const TWOP_MIN_ZOOM: float = 0.55                    # furthest-out we allow (keeps both visible)


func _ready() -> void:
	_default_zoom = zoom   # remember the scene's authored zoom as the "in" bound
	if target_path:
		target = get_node_or_null(target_path)
	if target == null:
		_refresh_target()


# Find whichever character is currently player-controlled and follow them.
func _refresh_target() -> void:
	var parent_scene := get_tree().current_scene
	if parent_scene == null:
		return
	for node in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(node):
			continue
		if "player_controlled" in node and bool(node.player_controlled):
			target = node as Node2D
			return
	target = parent_scene.find_child("Player", true, false)


# Collect the live (non-dead) ninja Node2Ds for 2P framing.
func _gather_players() -> Array:
	var out: Array = []
	for node in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(node) and node is Node2D:
			out.append(node)
	return out


func _physics_process(delta: float) -> void:
	if follow_enabled and RunState.two_player:
		_update_two_player(delta)
	else:
		_refresh_target()
		if follow_enabled and target != null and is_instance_valid(target):
			global_position = global_position.lerp(target.global_position, clamp(follow_speed * delta, 0.0, 1.0))
	# Apply screen shake offset from the FX autoload.
	offset = FX.get_shake_offset()


func _update_two_player(delta: float) -> void:
	var players: Array = _gather_players()
	if players.is_empty():
		return

	# Center on the midpoint of the two ninjas.
	var mn := (players[0] as Node2D).global_position
	var mx := mn
	for p in players:
		var gp: Vector2 = (p as Node2D).global_position
		mn.x = min(mn.x, gp.x); mn.y = min(mn.y, gp.y)
		mx.x = max(mx.x, gp.x); mx.y = max(mx.y, gp.y)
	var center: Vector2 = (mn + mx) * 0.5
	global_position = global_position.lerp(center, clamp(follow_speed * delta, 0.0, 1.0))

	# Required visible world span = bounding box + margins.
	var span: Vector2 = (mx - mn) + TWOP_MARGIN * 2.0
	var vp: Vector2 = get_viewport_rect().size
	# zoom such that vp / zoom >= span  →  zoom <= vp / span (per-axis), take min.
	var zx: float = vp.x / max(1.0, span.x)
	var zy: float = vp.y / max(1.0, span.y)
	var fit: float = min(zx, zy)
	# Never zoom in tighter than the authored zoom; never further than the floor.
	fit = clampf(fit, TWOP_MIN_ZOOM, _default_zoom.x)
	var target_zoom := Vector2(fit, fit)
	zoom = zoom.lerp(target_zoom, clamp(TWOP_ZOOM_LERP * delta, 0.0, 1.0))
