shader_type spatial;
render_mode unshaded, cull_back;

// Base color for unlit wall panels
uniform vec4 color_wall : source_color = vec4(0.05, 0.05, 0.08, 1.0);
// Grid line color (cycles slowly between scan_a and scan_b)
uniform vec4 color_scan_a : source_color = vec4(0.0, 0.90, 1.0, 1.0);   // cyan
uniform vec4 color_scan_b : source_color = vec4(1.0, 0.10, 0.90, 1.0);  // magenta

// Grid parameters
uniform float grid_u_lines : hint_range(4.0, 32.0) = 16.0;  // circumferential line count
uniform float grid_brightness : hint_range(0.0, 1.0) = 0.22;

// Scan wave parameters
uniform float scan_period : hint_range(2.0, 32.0) = 8.0;    // length in segments per cycle
uniform float scan_speed : hint_range(0.0, 3.0) = 0.55;     // set from GDScript to track player speed
uniform float scan_brightness : hint_range(0.0, 2.0) = 1.1;

// Digital glitch: sparse bright cell flicker, intensity driven by player speed
uniform float glitch_intensity : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	float u = UV.x;   // 0..1 around tube circumference
	float v = UV.y;   // segment index (integer boundaries = ring seams)

	// Vertex color carries ring markers (cyan/magenta) and spine (white)
	vec3 vcol = COLOR.rgb;
	// Detect non-wall vertices: ring markers and spine differ from wall color
	float is_marked = step(0.2, length(vcol - color_wall.rgb));

	// --- Grid lines ---
	// Circumferential lines at every 1/grid_u_lines of the tube
	float fu = fract(u * grid_u_lines);
	float lu = 1.0 - smoothstep(0.0, 0.08, min(fu, 1.0 - fu));
	// Axial lines at every segment boundary
	float fv = fract(v);
	float lv = 1.0 - smoothstep(0.0, 0.10, min(fv, 1.0 - fv));
	float grid = max(lu, lv);

	// Grid color cycles slowly between cyan and magenta
	vec3 grid_col = mix(color_scan_a.rgb, color_scan_b.rgb, fract(TIME * 0.07));

	// --- Scan wave (ring of light rushing toward player) ---
	// fract(...+ TIME*speed) makes the wave travel in the -V direction
	// which matches the player moving in +V: walls rush past
	float sv = fract(v / scan_period + TIME * scan_speed);
	// Soft pulse: peak at sv=0 and sv=1 (same point), falloff either side
	float scan = pow(max(0.0, 1.0 - abs(sv - 0.5) * 3.2), 2.2);

	// Scan color alternates hue over time
	vec3 scan_col = mix(color_scan_a.rgb, color_scan_b.rgb,
		fract(v / scan_period * 0.5 + TIME * 0.06));

	// --- Digital glitch: random grid-cell flicker ---
	// Hash changes ~8 times per second for a "corrupted data" feel
	float cell_u = floor(u * grid_u_lines);
	float cell_v = floor(v);
	float hash = fract(sin(cell_u * 127.1 + cell_v * 311.7 + floor(TIME * 8.0) * 74.3) * 43758.5453);
	// Only light up the rarest cells; threshold rises with speed
	float glitch = step(1.0 - glitch_intensity * 0.12, hash);
	vec3 glitch_col = mix(color_scan_a.rgb, color_scan_b.rgb, fract(hash * 7.0));

	// --- Compose ---
	vec3 col = color_wall.rgb;
	col += grid_col * grid * grid_brightness;
	col += scan_col * scan * scan_brightness;
	col += glitch_col * glitch * 2.0;
	// Ring markers / spine take over, boosted slightly for glow feel
	col = mix(col, max(col, vcol * 1.6), is_marked);

	ALBEDO = col;
}
