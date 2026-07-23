extends RefCounted

# ============================================================
# ToriiGate.gd — Run 151 (2026-07-17) — Torii gate builder
# ============================================================
# Builds a Node2D containing:
#   1. The hand-drawn torii sprite (per-biome variant)
#   2. An optional swirling portal effect inside the gate opening
#
# Portal can be toggled off easily:
#   var gate = ToriiGate.build("beach")          # with portal
#   var gate = ToriiGate.build("beach", false)    # gate only, no portal
#   gate.get_node("Portal").visible = false       # hide portal at runtime
# ============================================================

const SHADER_PATH := "res://shaders/portal_swirl.gdshader"

# Sprite paths — one per biome + carnival
const SPRITE_DIR := "res://Assets/Tilesets/Torii/"
const SPRITES: Dictionary = {
	"beach":    "torii_beach.png",
	"jungle":   "torii_jungle.png",
	"swamp":    "torii_swamp.png",
	"caverns":  "torii_caverns.png",
	"peaks":    "torii_peaks.png",
	"carnival": "torii_carnival.png",
}

# Target rendered width of the full torii sprite (px). Passage opening is
# roughly 40% of this, matching the old procedural gate mouth (~88 px).
const TARGET_WIDTH: float = 180.0

# Portal colours per biome — tuned to match each biome's accent palette.
const PORTAL_COLORS: Dictionary = {
	"beach":    Color(0.20, 0.55, 0.90, 0.85),   # ocean blue
	"jungle":   Color(0.30, 0.75, 0.25, 0.85),   # verdant green
	"swamp":    Color(0.58, 0.25, 0.78, 0.85),   # toxic purple
	"caverns":  Color(0.85, 0.40, 0.15, 0.85),   # molten orange
	"peaks":    Color(0.45, 0.75, 0.95, 0.85),   # glacial cyan
	"carnival": Color(0.92, 0.30, 0.45, 0.85),   # festive magenta-red
}

# Portal placement as fraction of sprite dims (center_x, center_y, width, height).
# Measured from the passageway openings in each sprite.
const PORTAL_RECTS: Dictionary = {
	"beach":    Vector4(0.51, 0.72, 0.38, 0.50),
	"jungle":   Vector4(0.50, 0.72, 0.38, 0.50),
	"swamp":    Vector4(0.49, 0.72, 0.36, 0.50),
	"caverns":  Vector4(0.51, 0.74, 0.32, 0.46),
	"peaks":    Vector4(0.50, 0.72, 0.38, 0.48),
	"carnival": Vector4(0.53, 0.68, 0.34, 0.42),
}


## Build a torii gate Node2D. Attach it to a parent and position it.
## [param biome_id] — key from SPRITES ("beach", "jungle", etc.)
## [param with_portal] — set false to skip the swirling portal effect.
## Returns the Node2D (caller must add_child it).
static func build(biome_id: String, with_portal: bool = true) -> Node2D:
	var root := Node2D.new()
	root.name = "ToriiGate_%s" % biome_id

	var sprite_file: String = SPRITES.get(biome_id, "")
	if sprite_file == "":
		push_warning("ToriiGate: unknown biome '%s'" % biome_id)
		return root

	var tex_path: String = SPRITE_DIR + sprite_file
	if not ResourceLoader.exists(tex_path):
		push_warning("ToriiGate: missing sprite '%s'" % tex_path)
		return root

	var tex: Texture2D = load(tex_path)
	var tw: float = tex.get_width()
	var th: float = tex.get_height()
	var sc: float = TARGET_WIDTH / tw

	# --- Gate sprite ---
	var spr := Sprite2D.new()
	spr.name = "GateSprite"
	spr.texture = tex
	spr.scale = Vector2(sc, sc)
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	# Anchor at bottom-center of the sprite so the gate "sits" on the ground
	# at the node's position (foot Y sorting friendly).
	spr.offset.y = -th * 0.5
	spr.z_index = 1
	root.add_child(spr)

	# --- Portal effect (optional) ---
	if with_portal:
		var pr: Vector4 = PORTAL_RECTS.get(biome_id, Vector4(0.5, 0.7, 0.36, 0.48))
		var portal_w: float = tw * pr.z * sc
		var portal_h: float = th * pr.w * sc
		# Portal center in local coords (sprite bottom-center anchored)
		var portal_cx: float = (pr.x - 0.5) * tw * sc
		var portal_cy: float = -(1.0 - pr.y) * th * sc

		var portal := ColorRect.new()
		portal.name = "Portal"
		portal.offset_left = portal_cx - portal_w * 0.5
		portal.offset_right = portal_cx + portal_w * 0.5
		portal.offset_top = portal_cy - portal_h * 0.5
		portal.offset_bottom = portal_cy + portal_h * 0.5
		# Run 152 — portal draws AHEAD of the gate sprite so the swirl is
		# never occluded by posts/lintel (the caverns torii was partially
		# hiding its portal). The rect is narrower than the opening, so it
		# still reads as swirling INSIDE the gate.
		portal.z_index = 2
		portal.color = Color(1, 1, 1, 1)   # shader handles colour

		if ResourceLoader.exists(SHADER_PATH):
			var shader: Shader = load(SHADER_PATH)
			var mat := ShaderMaterial.new()
			mat.shader = shader
			mat.set_shader_parameter("portal_color", PORTAL_COLORS.get(biome_id, Color(0.5, 0.5, 0.9, 0.85)))
			mat.set_shader_parameter("speed", 0.8)
			mat.set_shader_parameter("swirl_strength", 4.0)
			mat.set_shader_parameter("ring_count", 6.0)
			mat.set_shader_parameter("distortion", 0.15)
			mat.set_shader_parameter("glow_intensity", 0.6)
			mat.set_shader_parameter("edge_fade", 0.15)
			portal.material = mat
		else:
			# Fallback: flat tinted rect if shader is missing
			portal.color = PORTAL_COLORS.get(biome_id, Color(0.5, 0.5, 0.9, 0.5))

		root.add_child(portal)

	return root


## Convenience: remove just the portal from an existing ToriiGate node.
static func strip_portal(gate: Node2D) -> void:
	var p := gate.get_node_or_null("Portal")
	if p:
		p.queue_free()
