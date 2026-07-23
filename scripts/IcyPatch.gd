extends Area2D
# ============================================================
# IcyPatch.gd — Popsicle Pelican lob aftermath
# ============================================================
# A brief slick of ice left where a lobbed popsicle plopped. Stepping into it
# (or standing in it) applies 1 stack of Frost to a hero, which slows their
# movement (stacks + slow handled hero-side via add_frost_stack()). Re-applies
# on a short per-hero cooldown while they linger. Fades out and frees itself.
#
#   collision_mask 2 (heroes only). Built in code — no .tscn.
# ============================================================

const TEXEL: int = 2
var radius: float = 32.0
const LIFETIME: float = 3.5
const FADE: float = 0.7            # last N seconds fade the sprite out
const REAPPLY_CD: float = 0.8      # per-hero re-frost interval while standing in it

var _t: float = 0.0
var _cd_until: Dictionary = {}     # instance_id -> msec when re-frost allowed
var _spr: Sprite2D = null


func _ready() -> void:
	collision_layer = 0
	collision_mask  = 2
	z_index = -32                    # above terrain, below entities (like TrapZone)
	add_to_group("hazard_zone")      # AI partner trap-avoidance reads this
	set_meta("hazard_status", "frost")
	set_meta("hazard_radius", radius)
	var cs := CollisionShape2D.new()
	var sh := CircleShape2D.new()
	sh.radius = radius * 0.9
	cs.shape = sh
	add_child(cs)
	_spr = Sprite2D.new()
	_spr.texture = _make_visual()
	_spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_spr.scale = Vector2(TEXEL, TEXEL)
	add_child(_spr)
	# Pop-in.
	scale = Vector2(0.4, 0.4)
	var tw := create_tween()
	tw.tween_property(self, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	body_entered.connect(_on_enter)


func _process(delta: float) -> void:
	_t += delta
	# Keep frosting anyone standing in it.
	for b in get_overlapping_bodies():
		_frost(b)
	if _spr:
		var remain: float = LIFETIME - _t
		if remain < FADE:
			_spr.modulate.a = clampf(remain / FADE, 0.0, 1.0)
		else:
			_spr.modulate.a = 0.85 + sin(_t * 3.0) * 0.1
	if _t >= LIFETIME:
		queue_free()


func _on_enter(body: Node) -> void:
	_frost(body)


func _frost(body: Node) -> void:
	if body == null or body.is_in_group("enemy"):
		return
	if body.has_method("is_downed") and body.is_downed():
		return
	if not body.has_method("add_frost_stack"):
		return
	var id: int = body.get_instance_id()
	if Time.get_ticks_msec() < int(_cd_until.get(id, 0)):
		return
	_cd_until[id] = Time.get_ticks_msec() + int(REAPPLY_CD * 1000.0)
	body.add_frost_stack(1)


# Icy slick disc: pale blue with a bright rim and a few crystal flecks.
func _make_visual() -> ImageTexture:
	var w: int = 34
	var h: int = 26
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = randi()
	var cx: float = float(w) * 0.5
	var cy: float = float(h) * 0.5
	var rx: float = cx - 1.0
	var ry: float = cy - 1.0
	for y in range(h):
		for x in range(w):
			var d: float = pow((float(x) - cx) / rx, 2) + pow((float(y) - cy) / ry, 2)
			if d > 1.0:
				continue
			var col: Color = Color(0.72, 0.88, 0.98, 0.92)   # rim
			if d < 0.30:
				col = Color(0.86, 0.95, 1.0, 0.88)           # bright core sheen
			elif d < 0.65:
				col = Color(0.60, 0.80, 0.96, 0.90)
			if rng.randf() < 0.06 and d < 0.8:
				col = Color(1, 1, 1, 0.95)                   # frost sparkle
			img.set_pixel(x, y, col)
	return ImageTexture.create_from_image(img)
