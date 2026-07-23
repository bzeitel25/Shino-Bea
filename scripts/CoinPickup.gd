extends Node2D
class_name CoinPickup

# ============================================================
# CoinPickup.gd — Run 43 (2026-06-10) — Dream World coin reward
# ============================================================
# Spawned by DreamRoom.gd after a wave clears in a room entered
# through a 💰 COIN door (replaces the boon pickup for that room).
# Press [E] → grant RunState coins → emits `coins_collected` so
# the room controller can unlock the exits.
# ============================================================

signal coins_collected(amount: int)

const INTERACT_RADIUS: float = 72.0
const PEDESTAL_SCALE: float = 0.19
const GOLD_BIG_TEX:   String = "res://Assets/Sprites/Families/Boons/Boon_Gold_Big.png"
const GOLD_SMALL_TEX: String = "res://Assets/Sprites/Families/Boons/Boon_Gold_Small.png"
# Pre-rolled amount so the sprite matches what the player will receive.
var _pre_rolled_amount: int = 0

var _player_in_range: bool = false
var _picked: bool = false
var _pulse_phase: float = 0.0
var _icon_sprite: Sprite2D = null
var _icon_label: Label = null   # emoji fallback
var _prompt_label: Label = null
var _glow_ring: Line2D = null
var _glow_light: PointLight2D = null


func _ready() -> void:
	# Pre-roll the gold amount so we can pick small vs big stack art.
	_pre_rolled_amount = randi_range(RunState.COIN_DOOR_GRANT_MIN, RunState.COIN_DOOR_GRANT_MAX)
	_build_visual()
	_build_interaction_zone()
	RunState.apply_night_exemption(self)
	if get_node_or_null("/root/FX") != null:
		FX.spawn_burst_particles(global_position, Color(1.0, 0.85, 0.30), 20)


func _build_visual() -> void:
	var gold := Color(1.0, 0.85, 0.30)

	# Pick big or small stack based on pre-rolled amount.
	# 50-74 = small stack, 75-100 = big stack.
	var tex_path: String = GOLD_BIG_TEX if _pre_rolled_amount >= 75 else GOLD_SMALL_TEX
	if ResourceLoader.exists(tex_path):
		_icon_sprite = Sprite2D.new()
		_icon_sprite.texture = load(tex_path)
		_icon_sprite.scale = Vector2(PEDESTAL_SCALE, PEDESTAL_SCALE)
		_icon_sprite.z_index = 8
		_icon_sprite.offset.y = -_icon_sprite.texture.get_height() * 0.35
		add_child(_icon_sprite)
		# Pulsing glow shader (reuse BoonPickup's pattern).
		var glow_shader := ShaderMaterial.new()
		glow_shader.shader = _make_glow_shader()
		glow_shader.set_shader_parameter("glow_color", Vector4(gold.r, gold.g, gold.b, 1.0))
		glow_shader.set_shader_parameter("glow_width", 3.0)
		glow_shader.set_shader_parameter("pulse_speed", 2.5)
		glow_shader.set_shader_parameter("pulse_min", 0.3)
		glow_shader.set_shader_parameter("pulse_max", 1.0)
		_icon_sprite.material = glow_shader
	else:
		_icon_label = Label.new()
		_icon_label.text = "💰"
		_icon_label.add_theme_font_size_override("font_size", 52)
		_icon_label.position = Vector2(-30, -46)
		_icon_label.z_index = 8
		_icon_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_icon_label)

	# PointLight2D glow halo
	_glow_light = PointLight2D.new()
	_glow_light.texture = _make_glow_texture()
	_glow_light.color = gold
	_glow_light.energy = 0.8
	_glow_light.texture_scale = 1.8
	_glow_light.z_index = 5
	_glow_light.blend_mode = Light2D.BLEND_MODE_ADD
	_glow_light.position.y = -20
	add_child(_glow_light)

	_glow_ring = Line2D.new()
	_glow_ring.width = 4.0
	_glow_ring.default_color = Color(gold.r, gold.g, gold.b, 0.55)
	_glow_ring.z_index = 6
	var n: int = 32
	for i in range(n + 1):
		var a: float = TAU * float(i) / float(n)
		_glow_ring.add_point(Vector2(cos(a), sin(a)) * 42.0)
	add_child(_glow_ring)

	_prompt_label = Label.new()
	_prompt_label.text = "Press [E] to collect"
	_prompt_label.add_theme_font_size_override("font_size", 14)
	_prompt_label.add_theme_color_override("font_color", Color(1.0, 1.0, 0.7))
	_prompt_label.add_theme_color_override("font_outline_color", Color(0.05, 0.05, 0.0))
	_prompt_label.add_theme_constant_override("outline_size", 3)
	_prompt_label.position = Vector2(-58, -74)
	_prompt_label.z_index = 10
	_prompt_label.visible = false
	_prompt_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_prompt_label)


func _build_interaction_zone() -> void:
	var zone := Area2D.new()
	zone.collision_layer = 0
	zone.collision_mask = 2
	var shape := CircleShape2D.new()
	shape.radius = INTERACT_RADIUS
	var col := CollisionShape2D.new()
	col.shape = shape
	zone.add_child(col)
	zone.body_entered.connect(_on_body_entered)
	zone.body_exited.connect(_on_body_exited)
	add_child(zone)


func _is_active_player(body: Node) -> bool:
	if body.is_in_group("player") and not body.is_in_group("bea"):
		return true
	if body.is_in_group("bea") and body.get("player_controlled") == true:
		return true
	return false


func _on_body_entered(body: Node) -> void:
	if _is_active_player(body):
		_player_in_range = true
		if _prompt_label and not _picked:
			_prompt_label.visible = true


func _on_body_exited(body: Node) -> void:
	if _is_active_player(body):
		_player_in_range = false
		if _prompt_label:
			_prompt_label.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if _picked or not _player_in_range:
		return
	if event.is_action_pressed("interact") and not event.is_echo():
		_collect()


func _collect() -> void:
	_picked = true
	RunState.add_coins(_pre_rolled_amount)
	if get_node_or_null("/root/FX") != null:
		FX.spawn_burst_particles(global_position, Color(1.0, 0.85, 0.30), 26)
		FX.play_sound("boon_pickup_spawn", 1.0)
	print("[CoinPickup] +%d coins (%d total)." % [_pre_rolled_amount, RunState.run_coins])
	emit_signal("coins_collected", _pre_rolled_amount)
	queue_free()


func _process(delta: float) -> void:
	_pulse_phase += delta * 2.8
	var pulse: float = sin(_pulse_phase) * 0.5 + 0.5
	if _icon_sprite:
		var s: float = PEDESTAL_SCALE * (1.0 + pulse * 0.04)
		_icon_sprite.scale = Vector2(s, s)
	if _icon_label:
		var s: float = 1.0 + pulse * 0.06
		_icon_label.scale = Vector2(s, s)
	if _glow_light:
		_glow_light.energy = 0.5 + 0.6 * pulse
		_glow_light.texture_scale = 1.6 + 0.4 * pulse
	if _glow_ring:
		_glow_ring.default_color = Color(1.0, 0.85, 0.30, 0.30 + 0.50 * pulse)


# -------------------------------------------------------
# Glow shader (same as BoonPickup)
# -------------------------------------------------------
func _make_glow_shader() -> Shader:
	var s := Shader.new()
	s.code = """
shader_type canvas_item;

uniform vec4 glow_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float glow_width : hint_range(1.0, 8.0) = 3.0;
uniform float pulse_speed : hint_range(0.5, 6.0) = 2.5;
uniform float pulse_min : hint_range(0.0, 1.0) = 0.3;
uniform float pulse_max : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec4 col = texture(TEXTURE, UV);
	vec2 ps = TEXTURE_PIXEL_SIZE * glow_width;
	float a_sum = 0.0;
	a_sum += texture(TEXTURE, UV + vec2( ps.x, 0.0)).a;
	a_sum += texture(TEXTURE, UV + vec2(-ps.x, 0.0)).a;
	a_sum += texture(TEXTURE, UV + vec2(0.0,  ps.y)).a;
	a_sum += texture(TEXTURE, UV + vec2(0.0, -ps.y)).a;
	a_sum += texture(TEXTURE, UV + vec2( ps.x,  ps.y)).a;
	a_sum += texture(TEXTURE, UV + vec2(-ps.x,  ps.y)).a;
	a_sum += texture(TEXTURE, UV + vec2( ps.x, -ps.y)).a;
	a_sum += texture(TEXTURE, UV + vec2(-ps.x, -ps.y)).a;
	float pulse = mix(pulse_min, pulse_max, (sin(TIME * pulse_speed) * 0.5 + 0.5));
	if (col.a < 0.1 && a_sum > 0.0) {
		float edge = clamp(a_sum / 3.0, 0.0, 1.0);
		COLOR = vec4(glow_color.rgb, edge * pulse);
	} else {
		float add_glow = pulse * 0.18;
		COLOR = vec4(col.rgb + glow_color.rgb * add_glow * col.a, col.a);
	}
}
"""
	return s


func _make_glow_texture() -> GradientTexture2D:
	var gt := GradientTexture2D.new()
	gt.width = 128; gt.height = 128
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5); gt.fill_to = Vector2(0.5, 0.0)
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 1))
	grad.add_point(0.4, Color(1, 1, 1, 0.5))
	grad.set_color(grad.get_point_count() - 1, Color(1, 1, 1, 0))
	gt.gradient = grad
	return gt
