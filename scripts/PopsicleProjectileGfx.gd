extends Node2D
# Draws the tumbling popsicle for PopsicleProjectile (a child Node2D so it can
# float above the ground shadow via its parent-set position).

func _draw() -> void:
	# Popsicle: red/white ice pop on a tan stick. Drawn around local origin.
	# Stick.
	draw_line(Vector2(0, 6), Vector2(0, 12), Color(0.80, 0.62, 0.38, 1.0), 3.0)
	# Body (rounded bar) — cool red pop with a frosty highlight.
	draw_circle(Vector2(0, -1), 9.5, Color(0.45, 0.70, 0.95, 0.5))     # frost aura
	draw_rect(Rect2(-6.5, -8.0, 13.0, 12.0), Color(0.92, 0.28, 0.42, 1.0), true)
	draw_circle(Vector2(0, -8), 6.5, Color(0.92, 0.28, 0.42, 1.0))     # rounded top
	draw_rect(Rect2(-6.5, -3.0, 13.0, 4.0), Color(0.98, 0.62, 0.72, 1.0), true)  # drip band
	draw_circle(Vector2(-2.5, -6.0), 1.8, Color(1, 1, 1, 0.85))        # glint
