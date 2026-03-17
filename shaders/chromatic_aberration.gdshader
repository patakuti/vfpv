shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform float speed_ratio : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	float offset = speed_ratio * 0.005;
	vec2 dir = SCREEN_UV - vec2(0.5);
	float dist = length(dir);

	float r = texture(screen_texture, SCREEN_UV + dir * offset * dist).r;
	float g = texture(screen_texture, SCREEN_UV).g;
	float b = texture(screen_texture, SCREEN_UV - dir * offset * dist).b;

	COLOR = vec4(r, g, b, 1.0);
}
