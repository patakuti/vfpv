shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform float speed_ratio : hint_range(0.0, 1.0) = 0.0;
uniform int samples : hint_range(2, 16) = 8;

void fragment() {
	float strength = speed_ratio * 0.02;
	vec2 dir = (SCREEN_UV - vec2(0.5)) * strength;

	vec4 col = vec4(0.0);
	for (int i = 0; i < samples; i++) {
		float t = float(i) / float(samples - 1) - 0.5;
		col += texture(screen_texture, SCREEN_UV + dir * t);
	}
	col /= float(samples);

	COLOR = col;
}
