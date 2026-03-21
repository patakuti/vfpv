shader_type canvas_item;

uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform float line_count : hint_range(10.0, 80.0) = 40.0;
uniform float line_speed : hint_range(0.5, 5.0) = 2.0;
uniform float inner_radius : hint_range(0.0, 0.6) = 0.1;

void fragment() {
	vec2 center = SCREEN_UV - vec2(0.5);
	float dist = length(center);
	float angle = atan(center.y, center.x);

	// Radial lines pattern
	float lines = sin(angle * line_count + TIME * line_speed * 10.0);
	lines = smoothstep(0.3, 1.0, lines);

	// Fade: invisible at center, strong at edges
	float radial_fade = smoothstep(inner_radius, 0.7, dist);

	// Thin streaks
	float alpha = lines * radial_fade * intensity * 0.6;

	COLOR = vec4(1.0, 1.0, 1.0, alpha);
}
