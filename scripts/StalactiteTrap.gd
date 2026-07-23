class_name StalactiteTrap
extends Area2D
## Frostpeak cave stalactite trap.
##
## Spawns as a dark circular shadow on the floor. When a hero steps into the
## shadow, a 1-second delay starts; after the delay a random icicle prop falls
## from above with gravity-like acceleration. On impact it deals damage +
## sideways knockback, then becomes a permanent dashable_barrier obstacle.

# ── Tunables ──────────────────────────────────────────────────────────────────
const SHADOW_RADIUS: float = 22.0       # px, visual + collision
const FALL_HEIGHT: float = 300.0        # px above shadow center
const FALL_DURATION: float = 0.5        # seconds (ease-in = gravity feel)
const DAMAGE: int = 15
const KNOCKBACK_FORCE: float = 140.0
const TRIGGER_DELAY: float = 1.0        # seconds after hero enters shadow
const LODGE_DEPTH: float = 10.0         # px the tip embeds below ground

const WORLD_CELL: float = 32.0
const PROP_PX_SCALE: float = 0.46       # same as PeakTileset
const PROP_HEIGHT_CELLS: float = 1.75   # 1.5-2.0 range, capped to native

# Only stalactite sprites (point DOWN) — stalagmites (point UP) are static
# obstacles, not falling traps.
const STALACTITE_POOL: Array = [
	"micicle_1", "micicle_3", "micicle_5", "micicle_6",
	"mspike_1", "mspike_3", "mspike_5",
]

# ── State machine ─────────────────────────────────────────────────────────────
enum Phase { IDLE, TRIGGERED, FALLING, LODGED }
var phase: int = Phase.IDLE

# ── Internals ─────────────────────────────────────────────────────────────────
var _trigger_timer: float = 0.0
var _icicle_sprite: Sprite2D = null
var _icicle_tex: ImageTexture = null
var _obstacle_body: StaticBody2D = null


func _ready() -> void:
	# Collision: detect heroes (layer 2) only.
	collision_layer = 0
	collision_mask = 2
	monitoring = true
	monitorable = false

	# Circle collision shape matching the shadow radius.
	var cs := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = SHADOW_RADIUS
	cs.shape = circle
	add_child(cs)

	# Pre-load a random stalactite texture from the pool.
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var pick: String = STALACTITE_POOL[rng.randi() % STALACTITE_POOL.size()]
	_icicle_tex = _load_stalactite_tex(pick)

	# Connect hero-enter signal.
	body_entered.connect(_on_body_entered)


func _draw() -> void:
	if phase == Phase.LODGED:
		return  # shadow gone after landing
	# Semi-transparent dark circle = danger zone.
	draw_circle(Vector2.ZERO, SHADOW_RADIUS, Color(0.0, 0.0, 0.0, 0.35))


func _process(delta: float) -> void:
	if phase == Phase.TRIGGERED:
		_trigger_timer -= delta
		if _trigger_timer <= 0.0:
			_start_fall()


# ── Trigger ───────────────────────────────────────────────────────────────────
func _on_body_entered(body: Node2D) -> void:
	if phase != Phase.IDLE:
		return
	# Only react to heroes (Player / BeaAI).
	if not (body.is_in_group("hero") or body.has_method("take_damage")):
		return
	phase = Phase.TRIGGERED
	_trigger_timer = TRIGGER_DELAY


# ── Fall ──────────────────────────────────────────────────────────────────────
func _start_fall() -> void:
	phase = Phase.FALLING

	# Build the icicle sprite.
	_icicle_sprite = Sprite2D.new()
	if _icicle_tex != null:
		_icicle_sprite.texture = _icicle_tex
		# Scale: cap to native resolution (never upscale past source).
		var desired_h: float = WORLD_CELL * PROP_HEIGHT_CELLS
		var native_h: float = float(_icicle_tex.get_height()) * PROP_PX_SCALE
		var draw_h: float = minf(desired_h, native_h)
		var scale_f: float = draw_h / float(_icicle_tex.get_height())
		_icicle_sprite.scale = Vector2(scale_f, scale_f)
		# Pool contains only stalactite sprites (already point downward).
	else:
		push_warning("[StalactiteTrap] No icicle texture loaded; using placeholder.")

	# Start position: above the shadow center.
	# Anchor = bottom-center so the tip aligns with the ground.
	_icicle_sprite.centered = true
	_icicle_sprite.position = Vector2(0.0, -FALL_HEIGHT)
	_icicle_sprite.z_index = RunState.BARRIER_OVERHANG_Z if RunState else 3
	add_child(_icicle_sprite)

	# The landing Y: LODGE_DEPTH below the shadow center (tip embeds in floor).
	var land_y: float = LODGE_DEPTH
	var tw := create_tween()
	tw.tween_property(_icicle_sprite, "position:y", land_y, FALL_DURATION) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(_on_landed)


# ── Landing ───────────────────────────────────────────────────────────────────
func _on_landed() -> void:
	phase = Phase.LODGED

	# Damage + knockback every hero inside the shadow zone right now.
	var overlaps := get_overlapping_bodies()
	for body in overlaps:
		if not is_instance_valid(body):
			continue
		if body.has_method("take_damage"):
			var knock_dir: Vector2 = (body.global_position - global_position).normalized()
			# Ensure a non-zero direction (hero standing dead-center).
			if knock_dir.length_squared() < 0.01:
				knock_dir = Vector2.RIGHT
			body.take_damage(DAMAGE, knock_dir * KNOCKBACK_FORCE, "stalactite")

	# Disable the Area2D trigger — no longer needed.
	monitoring = false
	set_process(false)

	# Hide the shadow (redraw with nothing).
	queue_redraw()

	# Spawn a permanent obstacle (StaticBody2D + dashable_barrier).
	_spawn_obstacle()


func _spawn_obstacle() -> void:
	_obstacle_body = StaticBody2D.new()
	_obstacle_body.collision_layer = 1
	_obstacle_body.collision_mask = 0
	_obstacle_body.add_to_group("dashable_barrier")

	var cs := CollisionShape2D.new()
	var sh := RectangleShape2D.new()
	# Collision rect roughly matching the icicle's visual footprint.
	var col_w: float = 16.0
	var col_h: float = 24.0
	if _icicle_tex != null:
		var desired_h: float = WORLD_CELL * PROP_HEIGHT_CELLS
		var native_h: float = float(_icicle_tex.get_height()) * PROP_PX_SCALE
		var draw_h: float = minf(desired_h, native_h)
		var draw_w: float = float(_icicle_tex.get_width()) * (draw_h / float(_icicle_tex.get_height()))
		col_w = maxf(8.0, draw_w * 0.6)
		col_h = maxf(8.0, draw_h * 0.45)
	sh.size = Vector2(col_w, col_h)
	cs.shape = sh
	# Center the collider around the lodged sprite (slightly above ground).
	cs.position = Vector2(0.0, LODGE_DEPTH - col_h * 0.3)
	_obstacle_body.add_child(cs)
	add_child(_obstacle_body)


# ── PNG loader (import-agnostic, same pattern as PeakTileset) ─────────────────
static func _load_stalactite_tex(name: String) -> ImageTexture:
	var path: String = "res://Assets/Tilesets/Mountain_props/%s.png" % name
	var img: Image = _load_png(path)
	if img == null:
		return null
	return ImageTexture.create_from_image(img)


static func _load_png(path: String) -> Image:
	var out: Image = null
	if ResourceLoader.exists(path):
		var res: Resource = ResourceLoader.load(path)
		if res is Texture2D:
			out = (res as Texture2D).get_image()
	if out == null:
		var img := Image.new()
		if img.load(ProjectSettings.globalize_path(path)) == OK:
			out = img
	if out != null and out.get_format() != Image.FORMAT_RGBA8:
		out.convert(Image.FORMAT_RGBA8)
	if out == null:
		push_warning("[StalactiteTrap] Could not load %s." % path)
	return out
