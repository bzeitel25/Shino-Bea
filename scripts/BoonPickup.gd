extends Node2D
class_name BoonPickup

# ============================================================
# BoonPickup.gd — World-space boon icon dropped on wave clear.
# ============================================================
# Spawned by World.gd at the center of the arena when enemies
# are all defeated. The player presses [E] to interact with it,
# which opens the BoonOffer overlay. After a boon is picked the
# pickup auto-frees and emits `boon_collected` so World.gd can
# unlock the exit gates.
#
# Visual: pedestal sprite + pulsing glow shader + interaction prompt.
# ============================================================

signal boon_collected(boon_id: String)

# Set by World.gd before adding to scene tree.
var room_family: String = ""

const INTERACT_RADIUS: float = 72.0   # px — how close the player must be to press E
const BOON_OFFER_SCENE: String = "res://scenes/BoonOffer.tscn"

# Pedestal display scale — native art is ~420×520; scale to ~80×100 in world.
const PEDESTAL_SCALE: float = 0.19

# Pedestal texture paths keyed by family name.
const PEDESTAL_TEXTURES: Dictionary = {
	"Apple":      "res://Assets/Sprites/Families/Boons/Boon_Apple.png",
	"Carrot":     "res://Assets/Sprites/Families/Boons/Boon_Carrot.png",
	"Grape":      "res://Assets/Sprites/Families/Boons/Boon_Grape.png",
	"Onion":      "res://Assets/Sprites/Families/Boons/Boon_Onion.png",
	"Potato":     "res://Assets/Sprites/Families/Boons/Boon_Potato.png",
	"Pepper":     "res://Assets/Sprites/Families/Boons/Boon_Pepper.png",
	"Banana":     "res://Assets/Sprites/Families/Boons/Boon_Banana.png",
	"Watermelon": "res://Assets/Sprites/Families/Boons/Boon_Watermelon.png",
	"Broccoli":   "res://Assets/Sprites/Families/Boons/Boon_Broccoli.png",
	"Coconut":    "res://Assets/Sprites/Families/Boons/Boon_Coconut.png",
	"__pie__":       "res://Assets/Sprites/Families/Boons/Boon_Pie.png",
	"__upgrade__":      "res://Assets/Sprites/Families/Boons/Boon_DragonFruit.png",
	"__upgrade_rare__": "res://Assets/Sprites/Families/Boons/Boon_DragonFruit_Rare.png",
	"__dragon_soul__": "res://Assets/Sprites/Families/Boons/Boon_DragonSoul.png",
}

# Internal state
var _player_in_range: bool = false
var _picked: bool = false
var _pulse_phase: float = 0.0
var _glow_ring: Line2D = null
var _prompt_label: Label = null
var _icon_sprite: Sprite2D = null
var _icon_label: Label = null   # fallback for families without art
var _interact_zone: Area2D = null
var _glow_light: PointLight2D = null


func _ready() -> void:
	_build_visual()
	_build_interaction_zone()
	# Run 113 — boon reward icon stays full-bright under the Dream-World night.
	RunState.apply_night_exemption(self)
	# Spawn-flash: brief bright burst to draw the player's attention.
	call_deferred("_spawn_flash")


func setup(family: String) -> void:
	room_family = family


# -------------------------------------------------------
# Visual construction
# -------------------------------------------------------
func _build_visual() -> void:
	var fam_col: Color = RunState.get_family_color(room_family) if RunState else Color(1, 1, 1)

	# --- Pedestal sprite (replaces old emoji icon) ---
	var tex_path: String = PEDESTAL_TEXTURES.get(room_family, "")
	if tex_path != "" and ResourceLoader.exists(tex_path):
		_icon_sprite = Sprite2D.new()
		_icon_sprite.texture = load(tex_path)
		_icon_sprite.scale = Vector2(PEDESTAL_SCALE, PEDESTAL_SCALE)
		_icon_sprite.z_index = 8
		# Center the pedestal so the base sits near y=0.
		_icon_sprite.offset.y = -_icon_sprite.texture.get_height() * 0.35
		add_child(_icon_sprite)

		# --- Pulsing glow shader on the pedestal sprite ---
		var glow_shader := ShaderMaterial.new()
		glow_shader.shader = _make_glow_shader()
		glow_shader.set_shader_parameter("glow_color", Vector4(fam_col.r, fam_col.g, fam_col.b, 1.0))
		glow_shader.set_shader_parameter("glow_width", 3.0)
		glow_shader.set_shader_parameter("pulse_speed", 2.5)
		glow_shader.set_shader_parameter("pulse_min", 0.3)
		glow_shader.set_shader_parameter("pulse_max", 1.0)
		_icon_sprite.material = glow_shader
	else:
		# Fallback: emoji icon for families without pedestal art (Corrupt, Pie, Upgrade).
		_icon_label = Label.new()
		_icon_label.text = _icon_for_family(room_family)
		_icon_label.add_theme_font_size_override("font_size", 52)
		_icon_label.position = Vector2(-30, -46)
		_icon_label.z_index = 8
		_icon_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_icon_label)

	# --- PointLight2D glow halo (soft radial light that pulses) ---
	_glow_light = PointLight2D.new()
	_glow_light.texture = _make_glow_texture()
	_glow_light.color = fam_col
	_glow_light.energy = 0.8
	_glow_light.texture_scale = 1.8
	_glow_light.z_index = 5
	_glow_light.blend_mode = Light2D.BLEND_MODE_ADD
	_glow_light.position.y = -20   # center on the fruit, not the pedestal base
	add_child(_glow_light)

	# Glow ring (Line2D circle) — pulsing alpha driven in _process.
	_glow_ring = Line2D.new()
	_glow_ring.width = 4.0
	_glow_ring.default_color = Color(fam_col.r, fam_col.g, fam_col.b, 0.55)
	_glow_ring.z_index = 6
	var n: int = 32
	var r: float = 42.0
	for i in range(n + 1):
		var a: float = TAU * float(i) / float(n)
		_glow_ring.add_point(Vector2(cos(a), sin(a)) * r)
	add_child(_glow_ring)

	# "Press [E]" prompt — hidden until player is in range.
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


# -------------------------------------------------------
# Glow shader — outline + pulse on the pedestal sprite
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
	// Sample neighbours to detect edge of visible pixels
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
		// Transparent pixel near an opaque edge → glow outline
		float edge = clamp(a_sum / 3.0, 0.0, 1.0);
		COLOR = vec4(glow_color.rgb, edge * pulse);
	} else {
		// Original pixel — add subtle additive glow that pulses
		float add_glow = pulse * 0.18;
		COLOR = vec4(col.rgb + glow_color.rgb * add_glow * col.a, col.a);
	}
}
"""
	return s


# -------------------------------------------------------
# Procedural radial gradient texture for the PointLight2D
# -------------------------------------------------------
func _make_glow_texture() -> GradientTexture2D:
	var gt := GradientTexture2D.new()
	gt.width = 128
	gt.height = 128
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(0.5, 0.0)
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 1))
	grad.add_point(0.4, Color(1, 1, 1, 0.5))
	grad.set_color(grad.get_point_count() - 1, Color(1, 1, 1, 0))
	gt.gradient = grad
	return gt


func _build_interaction_zone() -> void:
	_interact_zone = Area2D.new()
	_interact_zone.name = "BoonPickupZone"
	_interact_zone.collision_layer = 0
	_interact_zone.collision_mask = 2   # player's CharacterBody2D is on layer 2
	_interact_zone.monitoring = true
	var shape := CircleShape2D.new()
	shape.radius = INTERACT_RADIUS
	var col_shape := CollisionShape2D.new()
	col_shape.shape = shape
	_interact_zone.add_child(col_shape)
	_interact_zone.body_entered.connect(_on_body_entered)
	_interact_zone.body_exited.connect(_on_body_exited)
	add_child(_interact_zone)


# -------------------------------------------------------
# Input
# -------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if _picked or not _player_in_range:
		return
	if event.is_action_pressed("interact") and not event.is_echo():
		_collect()


# -------------------------------------------------------
# Collection
# -------------------------------------------------------
func _collect() -> void:
	if _picked:
		return
	_picked = true
	_prompt_label.visible = false

	# Run 150 (Bruno fix 8): ITEM pickups (juice / dragon soul) are direct
	# collects — no BoonOffer overlay. The room script grants the actual
	# reward in its _after_boon_picked handler.
	if room_family == "__juice__" or room_family == "__dragon_soul__":
		FX.spawn_burst_particles(global_position,
			Color(0.30, 0.80, 0.95) if room_family == "__juice__" else Color(1.0, 0.85, 0.30), 24)
		FX.play_sound("boon_pickup_spawn", 0.9)
		emit_signal("boon_collected", "")
		queue_free()
		return

	if not ResourceLoader.exists(BOON_OFFER_SCENE):
		push_warning("[BoonPickup] BoonOffer.tscn not found — auto-skipping pickup.")
		emit_signal("boon_collected", "")
		queue_free()
		return

	var overlay: CanvasLayer = load(BOON_OFFER_SCENE).instantiate()
	overlay.name = "BoonOffer"
	get_tree().current_scene.add_child(overlay)
	overlay.boon_picked.connect(_on_boon_picked)


func _on_boon_picked(boon_id: String) -> void:
	emit_signal("boon_collected", boon_id)
	queue_free()


# -------------------------------------------------------
# Proximity tracking
# -------------------------------------------------------
func _is_active_player(body: Node) -> bool:
	# Shino is always an active player. Bea counts when she's player-controlled.
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


# -------------------------------------------------------
# Per-frame animation (pulse)
# -------------------------------------------------------
func _process(delta: float) -> void:
	_pulse_phase += delta * 2.8
	var pulse: float = sin(_pulse_phase) * 0.5 + 0.5   # 0..1

	# Pulse the pedestal sprite scale gently.
	var s: float = PEDESTAL_SCALE * (1.0 + pulse * 0.04)
	if _icon_sprite:
		_icon_sprite.scale = Vector2(s, s)

	# Fallback emoji pulse.
	if _icon_label:
		var ls: float = 1.0 + pulse * 0.06
		_icon_label.scale = Vector2(ls, ls)
		_icon_label.position = Vector2(-30 * ls, -46 * ls)

	# Pulse the PointLight2D energy and scale.
	if _glow_light:
		_glow_light.energy = 0.5 + 0.6 * pulse
		_glow_light.texture_scale = 1.6 + 0.4 * pulse

	# Pulse the glow ring alpha.
	if _glow_ring:
		var fam_col: Color = RunState.get_family_color(room_family) if RunState else Color(1, 1, 1)
		_glow_ring.default_color = Color(fam_col.r, fam_col.g, fam_col.b,
										  0.30 + 0.50 * pulse)


# -------------------------------------------------------
# Spawn-flash effect
# -------------------------------------------------------
func _spawn_flash() -> void:
	if get_node_or_null("/root/FX") != null:
		var fam_col: Color = RunState.get_family_color(room_family) if RunState else Color(1, 1, 1)
		FX.spawn_burst_particles(global_position, fam_col, 20)
		FX.play_sound("boon_pickup_spawn", 0.85)


# -------------------------------------------------------
# Family icon map
# -------------------------------------------------------
func _icon_for_family(fam: String) -> String:
	match fam:
		"Apple":      return "🍎"
		"Coconut":    return "🥥"
		"Broccoli":   return "🥦"
		"Carrot":     return "🥕"
		"Grape":      return "🍇"
		"Watermelon": return "🍉"
		"Pepper":     return "🌶️"
		"Potato":     return "🥔"
		"Banana":     return "🍌"
		"Onion":      return "🧅"
		"Corrupt":    return "💀"
		"__pie__":    return "🥧"
		"__upgrade__": return "🐉"
		"__upgrade_rare__": return "🐉"
		"__juice__":  return "🧃"
		"__dragon_soul__": return "✨"
		_:            return "✦"


# Display name for the chip below the icon (strips sentinel underscores).
func _label_for_family(fam: String) -> String:
	match fam:
		"__pie__":     return "PIE"
		"__upgrade__": return "UPGRADE"
		"__upgrade_rare__": return "RARE UPGRADE"
		"__juice__":   return "JUICE"
		"__dragon_soul__": return "DRAGON SOUL"
		_:             return fam.to_upper()
