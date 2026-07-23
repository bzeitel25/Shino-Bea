class_name HeroHitFX
extends Node

# ============================================================
# HeroHitFX.gd — Run 102 (Bruno) — hero damage/status outlines
# ============================================================
# One per hero (Shino / Bea). Gives clear, non-obstructive visual feedback for
# every kind of damage the ninjas take:
#
#   • DIRECT ENEMY HIT  → brief RED outline flash around the body frame.
#   • SWAMP POISON      → PURPLE outline held for the poison duration, with
#                         little purple bubbles rising off the hero; ticks low
#                         trap damage once a second. Re-touching refreshes the
#                         timer instead of stacking.
#   • CAVE LAVA         → ORANGE outline flash + little ember burst each time
#                         the lava burns them (no DoT — TrapZone deals the hit
#                         on contact and again every interval while standing).
#
# The outline itself is a duplicate of the hero's AnimatedSprite2D, drawn with
# the hero_silhouette shader (flat solid colour from the sprite's alpha), scaled
# a touch larger and parked one z-layer BEHIND the body. The solid silhouette
# pokes out around the edges → a clean coloured rim/glow that hugs the figure.
#
# Usage (host-side, in _ready once the sprite exists):
#   _hitfx = HeroHitFX.new()
#   add_child(_hitfx)
#   _hitfx.setup(self, _sprite)
# Then route feedback:
#   _hitfx.flash(HeroHitFX.COLOR_HIT, 0.22)     # red enemy hit
#   _hitfx.flash(HeroHitFX.COLOR_LAVA, 0.25)    # orange lava burn
#   _hitfx.start_poison()                       # purple poison (refreshable)
# ============================================================

const SHADER_PATH: String = "res://shaders/hero_silhouette.gdshader"

# Outline palette.
const COLOR_HIT:    Color = Color(1.0, 0.18, 0.16, 1.0)   # direct enemy damage (red)
const COLOR_LAVA:   Color = Color(1.0, 0.50, 0.10, 1.0)   # cave lava burn (orange)
const COLOR_POISON: Color = Color(0.70, 0.25, 0.95, 1.0)  # swamp poison (purple)
const COLOR_FROST:  Color = Color(0.55, 0.82, 1.0, 1.0)   # frost slow (icy blue)
# Run 112 — charge tell: a clean body-hugging aura (replaces the old square
# ColorRect). Warm yellow while winding up, bright near-white pulsing at full.
# These are Shino's defaults; Bea overrides with teal via set_charge_colors().
const COLOR_CHARGE:  Color = Color(1.0, 0.86, 0.25, 1.0)  # CHARGING wind-up (yellow)
const COLOR_CHARGED: Color = Color(1.0, 0.97, 0.58, 1.0)  # CHARGED ready (bright)

# How much bigger than the body the silhouette is drawn (the rim thickness).
const OUTLINE_SCALE: float = 1.14
# Peak opacity of a transient flash (red / orange); fades to 0 over its window.
const FLASH_ALPHA: float = 0.95
# Steady opacity of the held poison outline (gently pulses around this).
const POISON_ALPHA: float = 0.80
# Held frost outline opacity (scales a touch with stack count via start_frost).
const FROST_ALPHA: float = 0.72

# --- Poison tuning (Bruno's spec) ---
const POISON_DURATION: float   = 3.0    # seconds the status lingers after a touch
const POISON_TICK_DMG: int     = 5      # trap damage per tick — bites enough to discourage standing in it, still under lava
const POISON_TICK_INTERVAL: float = 1.0 # one tick per second
const POISON_BUBBLE_PERIOD: float = 0.32

var _host: Node2D = null
var _main: AnimatedSprite2D = null
var _outline: AnimatedSprite2D = null

# Transient flash (red enemy hit / orange lava burn).
var _flash_t: float = 0.0
var _flash_dur: float = 0.22
var _flash_col: Color = COLOR_HIT

# Held poison state.
var _poison_t: float = 0.0
var _poison_tick_accum: float = 0.0
var _poison_bubble_accum: float = 0.0

# Held frost state (icy-blue outline; no damage tick — frost only slows).
var _frost_t: float = 0.0
var _frost_intensity: float = 0.0   # 0..1, scales with stack count

# Held charge state (0 = off, 1 = charging/wind-up, 2 = fully charged).
var _charge_level: int = 0
# Per-hero charge palette (overridable via set_charge_colors).
var _color_charge:  Color = COLOR_CHARGE
var _color_charged: Color = COLOR_CHARGED

var _pulse_t: float = 0.0
# Per-frame extra scale on the silhouette (charge breathes a little bigger).
var _scale_boost: float = 1.0


func setup(host: Node2D, main_sprite: AnimatedSprite2D) -> void:
	_host = host
	_main = main_sprite
	if _main == null or _host == null:
		return
	_outline = AnimatedSprite2D.new()
	_outline.name = "HitFXOutline"
	_outline.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var mat := ShaderMaterial.new()
	if ResourceLoader.exists(SHADER_PATH):
		mat.shader = load(SHADER_PATH)
		mat.set_shader_parameter("tint", Color(1, 1, 1, 0))
	_outline.material = mat
	_outline.visible = false
	# Sibling of the main sprite so it shares the hero's local space; synced each
	# frame in _process and kept one z-layer behind the body.
	_host.add_child(_outline)


func _process(delta: float) -> void:
	if _main == null or not is_instance_valid(_main) or _outline == null:
		return
	_pulse_t += delta

	# --- Poison: hold the purple outline, tick damage, shed bubbles ---
	if _poison_t > 0.0:
		_poison_t -= delta
		_poison_tick_accum += delta
		if _poison_tick_accum >= POISON_TICK_INTERVAL:
			_poison_tick_accum -= POISON_TICK_INTERVAL
			if is_instance_valid(_host) and _host.has_method("take_damage"):
				_host.take_damage(POISON_TICK_DMG, Vector2.ZERO, "poison")
		_poison_bubble_accum += delta
		if _poison_bubble_accum >= POISON_BUBBLE_PERIOD:
			_poison_bubble_accum = 0.0
			_spawn_poison_bubbles()

	# --- Decide the current outline colour ---
	# Priority (low → high): charge < poison < flash. A damage flash always
	# reads through, and poison reads over a charge aura.
	var col := Color(0, 0, 0, 0)
	_scale_boost = 1.0
	if _charge_level == 1:
		col = _color_charge
		col.a = 0.55
		_scale_boost = 1.05
	elif _charge_level == 2:
		var p: float = sin(_pulse_t * 9.0) * 0.5 + 0.5   # 0 → 1 pulse
		col = _color_charged
		col.a = 0.55 + 0.40 * p
		_scale_boost = 1.08 + 0.10 * p
	# Frost: icy-blue held outline (over charge, under poison/flash). No tick.
	if _frost_t > 0.0:
		_frost_t -= delta
		col = COLOR_FROST
		col.a = FROST_ALPHA * (0.60 + 0.40 * _frost_intensity) * (0.85 + 0.15 * sin(_pulse_t * 5.0))
		_scale_boost = 1.0
	if _poison_t > 0.0:
		col = COLOR_POISON
		col.a = POISON_ALPHA * (0.80 + 0.20 * sin(_pulse_t * 7.0))
		_scale_boost = 1.0
	if _flash_t > 0.0:
		_flash_t -= delta
		var k: float = clampf(_flash_t / max(0.001, _flash_dur), 0.0, 1.0)
		col = _flash_col
		col.a = FLASH_ALPHA * k
		_scale_boost = 1.0

	# --- Drive the silhouette ---
	if col.a <= 0.01 or not _main.visible:
		_outline.visible = false
		return
	_sync_outline()
	_outline.visible = true
	if _outline.material is ShaderMaterial:
		(_outline.material as ShaderMaterial).set_shader_parameter("tint", col)


# Mirror the body sprite so the silhouette matches its current pose/frame.
func _sync_outline() -> void:
	_outline.sprite_frames = _main.sprite_frames
	if _main.animation != &"" and _outline.animation != _main.animation:
		_outline.animation = _main.animation
	_outline.frame = _main.frame
	_outline.flip_h = _main.flip_h
	_outline.flip_v = _main.flip_v
	_outline.centered = _main.centered
	_outline.offset = _main.offset
	_outline.position = _main.position
	_outline.scale = _main.scale * OUTLINE_SCALE * _scale_boost
	_outline.z_index = _main.z_index - 1


# Run 112 — set the held charge aura: 0 = off, 1 = winding up, 2 = fully charged.
# The aura is rendered + pulsed by _process from this level.
func set_charge(level: int) -> void:
	_charge_level = clampi(level, 0, 2)


# Override the default (Shino-yellow) charge palette for this hero.
func set_charge_colors(charging: Color, charged: Color) -> void:
	_color_charge = charging
	_color_charged = charged


# Brief coloured flash (red enemy hit / orange lava). Re-calling refreshes it.
func flash(color: Color, dur: float = 0.22) -> void:
	_flash_col = color
	_flash_dur = dur
	_flash_t = dur


# Apply / refresh the swamp poison (purple outline + per-second tick). Calling
# again just resets the timer — never stacks.
func start_poison() -> void:
	_poison_t = POISON_DURATION
	# Keep the tick cadence rolling on a refresh (don't reset accum to 0, so a
	# hero standing in the pool keeps ticking on schedule).
	if _poison_tick_accum > POISON_TICK_INTERVAL:
		_poison_tick_accum = 0.0


func is_poisoned() -> bool:
	return _poison_t > 0.0


# Show/refresh the icy-blue frost outline for `dur` seconds. `intensity` (0..1)
# scales the glow with the hero's current frost stack count. No damage tick —
# frost only slows movement (handled hero-side).
func start_frost(dur: float, intensity: float = 0.5) -> void:
	_frost_t = maxf(_frost_t, dur)
	_frost_intensity = clampf(intensity, 0.0, 1.0)


func is_frosted() -> bool:
	return _frost_t > 0.0


# Little purple bubbles drifting up off the hero while poisoned.
func _spawn_poison_bubbles() -> void:
	if not is_instance_valid(_host):
		return
	var parent: Node = _host.get_parent()
	if parent == null:
		return
	var n: int = randi_range(1, 2)
	for i in range(n):
		var b := ColorRect.new()
		var sz: int = randi_range(3, 6)
		b.size = Vector2(sz, sz)
		b.color = Color(0.66, 0.28, 0.92, 0.82)
		b.position = _host.global_position + Vector2(randf_range(-11.0, 11.0), randf_range(-4.0, 12.0))
		b.z_index = 9
		b.mouse_filter = Control.MOUSE_FILTER_IGNORE
		parent.add_child(b)
		var tw: Tween = b.create_tween()
		tw.tween_property(b, "position", b.position + Vector2(randf_range(-3.0, 3.0), -randf_range(12.0, 20.0)), 0.6)
		tw.parallel().tween_property(b, "modulate:a", 0.0, 0.6)
		tw.tween_callback(b.queue_free)


# Small orange ember burst when the lava burns the hero.
func spawn_lava_embers() -> void:
	if not is_instance_valid(_host):
		return
	var parent: Node = _host.get_parent()
	if parent == null:
		return
	for i in range(randi_range(3, 5)):
		var p := ColorRect.new()
		var sz: int = randi_range(3, 6)
		p.size = Vector2(sz, sz)
		p.color = Color(1.0, randf_range(0.45, 0.75), 0.12, 0.92)
		p.position = _host.global_position + Vector2(randf_range(-10.0, 10.0), randf_range(-2.0, 10.0))
		p.z_index = 9
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		parent.add_child(p)
		var tw: Tween = p.create_tween()
		tw.tween_property(p, "position", p.position + Vector2(randf_range(-5.0, 5.0), -randf_range(10.0, 18.0)), 0.4)
		tw.parallel().tween_property(p, "modulate:a", 0.0, 0.4)
		tw.tween_callback(p.queue_free)
