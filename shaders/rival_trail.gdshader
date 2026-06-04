shader_type spatial;
render_mode unshaded;

uniform vec4 base_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float node_index : hint_range(0.0, 8.0) = 0.0;
uniform float emission_energy : hint_range(0.0, 10.0) = 5.0;

void fragment() {
	// Brightness pulse: each node has a phase offset so a wave travels
	// from the head of the trail toward the tail.
	float phase = TIME * 3.0 - node_index * 0.5;
	float pulse = 0.35 + 0.65 * abs(sin(phase));

	// Slowly cycle the hue toward the tube's cyan/magenta palette.
	// node_index offset makes the color shift ripple along the trail.
	float hue_t = fract(TIME * 0.35 + node_index * 0.12);
	vec3 accent_a = vec3(0.0, 0.90, 1.0);   // cyan
	vec3 accent_b = vec3(1.0, 0.10, 0.90);  // magenta
	vec3 accent = mix(accent_a, accent_b, abs(sin(hue_t * 3.14159)));

	// Blend rival's base color with the tube accent for visual coherence
	vec3 col = mix(base_color.rgb, accent, 0.55) * pulse;
	ALBEDO = col * emission_energy;
}
