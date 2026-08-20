extends Label

# ============================================================
# DamageNumber.gd — Floating damage text (Phase 3)
# ============================================================
# Spawned by enemy take_damage() at the enemy's position.
# Floats upward and fades out, then self-destructs.
#
# Run 127 — crit-aware display (Bruno's spec: Carrot crits must
# visibly pay off):
#   tier 1 (rolled crit)      → ORANGE, larger font
#   tier 2 (forced Mega-Crit) → RED, biggest font + "!"
# Tier is read from RunState.get_display_crit_tier(), which is
# frame-stamped by roll_crit_mult() so AoE hits from one roll all
# tint, while unrelated DoT ticks stay plain.
#
# Usage:
#   var dn = dmg_num_scene.instantiate()
#   get_parent().add_child(dn)
#   dn.setup(damage_amount, enemy.global_position)
#   # or, position first then: dn.show_damage(damage_amount)
# ============================================================

const FLOAT_SPEED: float = 55.0    # pixels per second upward
const LIFETIME: float = 0.75       # seconds until gone
const X_DRIFT_RANGE: float = 14.0  # small random horizontal wobble for readability

const CRIT_COLOR: Color      = Color(1.0, 0.55, 0.10)   # orange
const MEGA_CRIT_COLOR: Color = Color(1.0, 0.15, 0.10)   # red

var _elapsed: float = 0.0


func setup(damage: int, spawn_pos: Vector2) -> void:
	# Anchor the text centered on spawn position with slight random offset
	global_position = spawn_pos + Vector2(randf_range(-X_DRIFT_RANGE, X_DRIFT_RANGE), -16.0)
	show_damage(damage)


# Run 127 — also the entry point bosses call (was missing entirely:
# BossEnemy/Boss2Enemy guard with has_method("show_damage"), so boss
# damage numbers never rendered before this).
func show_damage(damage: int) -> void:
	text = str(damage)
	modulate.a = 1.0
	var tier: int = 0
	var rs: Node = get_node_or_null("/root/RunState")
	if rs != null and rs.has_method("get_display_crit_tier"):
		tier = int(rs.get_display_crit_tier())

	# ---------------------------------------------------------------
	# Phase 6a — damage number visibility (0 All / 1 Crits only / 2 Off)
	# ---------------------------------------------------------------
	# Gated HERE because every spawn site in the game (Enemy, BossEnemy,
	# Boss2Enemy, MonsterRig, ...) funnels through setup() -> show_damage().
	# One check covers all of them, and none of those files had to change.
	#
	# The crit tier is resolved above first, so "Crits only" can keep the
	# numbers that actually matter to a Carrot build while silencing the
	# chip-damage spam.
	var st: Node = get_node_or_null("/root/Settings")
	if st != null and "damage_number_mode" in st:
		var mode: int = int(st.damage_number_mode)
		if mode == 2 or (mode == 1 and tier < 1):
			queue_free()
			return
	if tier >= 2:
		text = str(damage) + "!"
		add_theme_font_size_override("font_size", 30)
		add_theme_color_override("font_color", MEGA_CRIT_COLOR)
		add_theme_color_override("font_outline_color", Color(0.10, 0.0, 0.0))
		add_theme_constant_override("outline_size", 5)
	elif tier == 1:
		add_theme_font_size_override("font_size", 24)
		add_theme_color_override("font_color", CRIT_COLOR)
		add_theme_color_override("font_outline_color", Color(0.10, 0.04, 0.0))
		add_theme_constant_override("outline_size", 4)


func _process(delta: float) -> void:
	_elapsed += delta
	position.y -= FLOAT_SPEED * delta
	modulate.a = 1.0 - (_elapsed / LIFETIME)
	if _elapsed >= LIFETIME:
		queue_free()
