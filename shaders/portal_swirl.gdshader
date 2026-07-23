shader_type canvas_item;

// Swirling portal effect — Rick-and-Morty inspired vortex.
// Color-parameterised per biome via `portal_color`.
// Sits INSIDE the torii gate opening (between pillars, under lintel).

uniform vec4 portal_color : source_color = vec4(0.3, 0.7, 0.9, 1.0);
uniform float speed : hint_range(0.2, 3.0) = 0.8;
uniform float swirl_strength : hint_range(1.0, 10.0) = 4.0;
uniform float ring_count : hint_range(2.0, 12.0) = 6.0;
uniform float distortion : hint_range(0.0, 0.5) = 0.15;
uniform float glow_intensity : hint_range(0.0, 2.0) = 0.6;
uniform float edge_fade : hint_range(0.0, 0.5) = 0.15;

void fragment() {
	// Center UV to [-1, 1] range
	vec2 uv = UV * 2.0 - 1.0;
	float dist = length(uv);

	// Elliptical fade — softer at edges
	float fade = smoothstep(1.0, 1.0 - edge_fade, dist);

	// Swirl: rotate UV by angle that increases toward center
	float angle = atan(uv.y, uv.x);
	float swirl_angle = swirl_strength * (1.0 - dist) + TIME * speed;
	float new_angle = angle + swirl_angle;

	// Distorted radial coordinate for organic feel
	float r = dist + sin(angle * 3.0 + TIME * speed * 1.3) * distortion * (1.0 - dist);

	// Spiral arms — concentric rings that twist
	float spiral = sin(r * ring_count * PI * 2.0 - swirl_angle * 2.0);
	spiral = spiral * 0.5 + 0.5;   // normalise to [0, 1]

	// Secondary finer detail layer
	float detail = sin(new_angle * 5.0 + r * 14.0 - TIME * speed * 2.5) * 0.5 + 0.5;
	detail *= sin(r * 20.0 - TIME * speed * 3.0) * 0.5 + 0.5;

	// Combine layers
	float pattern = mix(spiral, detail, 0.35);

	// Color: bright core → biome color → darker rim
	vec3 core_color = mix(portal_color.rgb, vec3(1.0), 0.6);       // bright white-ish core
	vec3 mid_color = portal_color.rgb * 1.2;                        // saturated biome color
	vec3 rim_color = portal_color.rgb * 0.5;                        // darker rim

	vec3 col = mix(rim_color, mid_color, pattern);
	col = mix(col, core_color, smoothstep(0.5, 0.0, dist) * 0.7);  // bright center glow

	// Pulsing glow
	float pulse = sin(TIME * speed * 2.0) * 0.15 + 0.85;
	col *= pulse;

	// Add sparkle highlights
	float sparkle = pow(detail * spiral, 3.0) * smoothstep(0.6, 0.1, dist);
	col += vec3(sparkle * glow_intensity);

	// Final alpha: combine with portal_color alpha for easy toggling
	float alpha = fade * portal_color.a * (0.65 + pattern * 0.35);

	COLOR = vec4(col, alpha);
}
