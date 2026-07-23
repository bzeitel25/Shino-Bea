shader_type canvas_item;

// Flat-color silhouette shader (Run 102 — damage/status outlines).
// Renders the sprite as a single solid colour wherever the texture has alpha.
// HeroHitFX draws a copy of the hero sprite with this material, scaled slightly
// larger and parked BEHIND the body, so the solid silhouette peeks out as a
// clean coloured rim/glow around the figure. No neighbour sampling, so it works
// correctly with AtlasTexture animation frames (no bleed into adjacent frames).
uniform vec4 tint : source_color = vec4(1.0, 0.2, 0.2, 1.0);

void fragment() {
	float a = texture(TEXTURE, UV).a;
	COLOR = vec4(tint.rgb, a * tint.a);
}
