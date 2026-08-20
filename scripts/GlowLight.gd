class_name GlowLight
extends PointLight2D
## Run 163 — reusable "HD" light source for lamps, lanterns, braziers, candles.
##
## LOCK (Bruno, Run 163): THE GLOW LIVES IN THE LIGHT, NEVER IN THE SPRITE ART.
## Prop textures stay clean cut-outs with a transparent background; every warm
## halo in the world comes from one of these nodes. Do NOT bake a glow blob
## into a PNG, and do NOT fake "flicker" by swapping between two sprite frames
## (that reads as a texture pop, not as light). If a prop should breathe, let
## THIS node breathe — the pixel art stays perfectly still.
##
## Run 163b (Bruno): CANDLELIGHT, NOT FLICKER. The modulation is a slow swell —
## the light gently dims and glows over a couple of seconds, the way a candle
## behind paper does. It must never read as a strobe, a pop, or a fast wobble.
## Two SLOW detuned sines at an irrational-ish ratio (0.34Hz + 0.53Hz) so the
## cycle never visibly repeats, and the halo's REACH breathes with it (a real
## flame's pool of light grows and shrinks, it doesn't just change brightness).
##
## Usage (world-space, attach to the container the prop lives in):
##     GlowLight.attach(decor_node, lantern_centre, GlowLight.WARM_PAPER, 165.0, 0.78)

# --- Palette -----------------------------------------------------------------
const WARM_PAPER: Color = Color(1.00, 0.82, 0.52)   # paper lantern — candlelight
const WARM_STONE: Color = Color(1.00, 0.78, 0.45)   # stone garden lantern
const EMBER: Color      = Color(1.00, 0.58, 0.24)   # brazier / fire
const LAMP_TOWN: Color  = Color(1.00, 0.86, 0.62)   # town street lamp
const MOON: Color       = Color(0.62, 0.74, 1.00)   # cool fill

# Master dimmer. Every GlowLight multiplies its energy by this, so the whole
# world's lighting can be pulled up or down from one place.
const GLOBAL_GAIN: float = 1.0

# Candle swell rates, in Hz. Keep these SLOW — see the Run 163b note above.
const BREATH_HZ_A: float = 0.34   # ~2.9s primary swell
const BREATH_HZ_B: float = 0.53   # ~1.9s secondary, detuned so it never loops
# How much of the brightness swell also shows up as halo reach (0 = none).
const BREATH_REACH: float = 0.35

# Gradient is authored once and shared by every light in the game.
const TEX_SIZE: int = 256

static var _tex_cache: GradientTexture2D = null

# --- Breathing ---------------------------------------------------------------
# Depth of the swell as a fraction of base energy (0.0 = dead steady).
# 0.10–0.20 reads as candlelight; above ~0.35 it starts to look like a fault.
var breath: float = 0.14
var base_energy: float = 1.0
var base_scale: float = 1.0

var _t: float = 0.0
var _seed: float = 0.0


static func glow_texture() -> GradientTexture2D:
	if _tex_cache != null:
		return _tex_cache
	var gt := GradientTexture2D.new()
	gt.width = TEX_SIZE
	gt.height = TEX_SIZE
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(0.5, 0.0)
	var grad := Gradient.new()
	# Hot core → soft falloff → nothing. The long tail is what makes it read
	# as light spilling onto the floor instead of a hard disc.
	grad.set_color(0, Color(1, 1, 1, 1))
	grad.add_point(0.18, Color(1, 1, 1, 0.85))
	grad.add_point(0.45, Color(1, 1, 1, 0.34))
	grad.add_point(0.72, Color(1, 1, 1, 0.10))
	grad.set_color(grad.get_point_count() - 1, Color(1, 1, 1, 0))
	gt.gradient = grad
	_tex_cache = gt
	return gt


## Build a light and parent it. `local_pos` is in `parent`'s space — attach to
## the DECOR CONTAINER, not to the prop Sprite2D: prop sprites carry a scale,
## and a light parented under one inherits it (halo silently shrinks).
static func attach(parent: Node, local_pos: Vector2, color: Color = WARM_PAPER,
		radius: float = 140.0, energy: float = 1.0, breath_amt: float = 0.14) -> GlowLight:
	if parent == null or not is_instance_valid(parent):
		return null
	var l := GlowLight.new()
	l.name = "GlowLight"
	l.texture = GlowLight.glow_texture()
	l.color = color
	l.position = local_pos
	l.set_radius(radius)
	l.base_scale = l.texture_scale
	l.base_energy = maxf(0.0, energy) * GLOBAL_GAIN
	l.energy = l.base_energy
	l.breath = maxf(0.0, breath_amt)
	l.blend_mode = Light2D.BLEND_MODE_ADD
	l.shadow_enabled = false
	# Light the floor bakes (z ≈ -26) right through to props above the heroes.
	l.range_z_min = -128
	l.range_z_max = 128
	l.z_index = 0
	l.z_as_relative = false
	parent.add_child(l)
	return l


## Halo reach in world pixels (texture is drawn centred, so half-width scales).
func set_radius(radius: float) -> void:
	texture_scale = maxf(0.01, radius) / (float(TEX_SIZE) * 0.5)


func get_radius() -> float:
	return texture_scale * float(TEX_SIZE) * 0.5


func _ready() -> void:
	base_scale = texture_scale
	# Random phase so a row of lanterns never swells in unison.
	_seed = randf() * 100.0
	set_process(breath > 0.0)


func _process(delta: float) -> void:
	# Two SLOW detuned sines. No per-frame RNG, so the flame never strobes or
	# pops — it just breathes, dimming and glowing, and never quite repeats.
	_t += delta
	var wave: float = sin((_t + _seed) * TAU * BREATH_HZ_A) * 0.68 \
		+ sin((_t + _seed * 0.61) * TAU * BREATH_HZ_B) * 0.32
	energy = base_energy * (1.0 + breath * wave)
	texture_scale = base_scale * (1.0 + breath * BREATH_REACH * wave)
