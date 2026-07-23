extends Node2D
# ============================================================
# BurrowMound.gd — placeholder visual for Tuber Burrow state
# ============================================================
# Drawn as a squashed earthy mound sitting just below the
# player's feet, pulsing slightly to read as "underground."
#
# When real art is available, replace this with an
# AnimatedSprite2D on a separate scene and swap the
# _burrow_mound reference in Player._enter_burrow().
# ============================================================

const MOUND_COLOR:      Color = Color(0.42, 0.28, 0.12, 0.88)
const MOUND_OUTLINE:    Color = Color(0.22, 0.14, 0.05, 0.70)
const MOUND_WIDTH:      float = 22.0
const MOUND_HEIGHT:     float = 9.0
# Vertical offset — sits just beneath the sprite's feet.
const MOUND_Y_OFFSET:   float = 6.0

# Pulse animation
var _pulse_t: float = 0.0

func _process(delta: float) -> void:
	_pulse_t += delta * 3.5
	queue_redraw()

func _draw() -> void:
	# Slightly squashed ellipse that bobs on a sine wave.
	var pulse: float = 1.0 + sin(_pulse_t) * 0.08
	var w: float = MOUND_WIDTH  * pulse
	var h: float = MOUND_HEIGHT * pulse
	var center: Vector2 = Vector2(0.0, MOUND_Y_OFFSET)

	# Outline (slightly larger, darker).
	draw_arc(center, w * 0.55, 0.0, TAU, 20, MOUND_OUTLINE, 3.0)

	# Filled squashed ellipse (approximate with scaled circle).
	# Godot 4 doesn't have draw_ellipse natively; use draw_arc in a loop
	# or draw_circle with scale trick via polygon.
	var pts: PackedVector2Array = PackedVector2Array()
	var steps: int = 24
	for i in range(steps + 1):
		var angle: float = TAU * float(i) / float(steps)
		pts.append(center + Vector2(cos(angle) * w * 0.55, sin(angle) * h * 0.55))
	draw_polygon(pts, PackedColorArray([MOUND_COLOR]))

	# Small dirt clumps — three circles.
	var clump_col: Color = Color(0.38, 0.24, 0.10, 0.70)
	draw_circle(center + Vector2(-8.0, 0.0), 3.5, clump_col)
	draw_circle(center + Vector2( 5.0, 2.0), 2.5, clump_col)
	draw_circle(center + Vector2( 9.0, -1.0), 3.0, clump_col)
