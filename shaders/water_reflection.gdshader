shader_type spatial;
render_mode unshaded, cull_back;

// Live capture from a mirror camera (real_terrain_manager.gd), matching the
// main camera's FOV/aspect frame-by-frame so SCREEN_UV lines up with it.
uniform sampler2D reflection_tex : filter_linear;
// Base sea color blended in at grazing-away angles (matches SEA_COLOR).
uniform vec4 water_color : source_color = vec4(0.06, 0.22, 0.32, 1.0);
// Reflection strength looking straight down.
uniform float base_reflectivity : hint_range(0.0, 1.0) = 0.45;
// Cap on reflection strength even at the most grazing angles — real water
// never becomes a perfect mirror, and without a cap the sky/sun wash the
// surface out to near-white at the shallow angles typical of low FPV flight.
uniform float max_reflectivity : hint_range(0.0, 1.0) = 0.85;
uniform float fresnel_power : hint_range(0.5, 8.0) = 3.0;
// Dims the captured reflection itself so bright sky/sun highlights don't
// read as a blown-out white sheet; water absorbs and scatters much of what
// it reflects rather than mirroring it at full brightness.
uniform float reflection_darken : hint_range(0.0, 1.0) = 0.65;

// Rotor-downwash ripple: one wave source per rotor (real_terrain_manager.gd
// updates these every frame from player.gd's get_rotor_world_positions()),
// summed into a single interference wavefront rather than 4 separate rings —
// a clearer "how close am I" cue than particles alone since it appears at
// the exact point on the water below the aircraft.
uniform vec2 rotor_pos_xz[4];
uniform float ripple_intensity : hint_range(0.0, 1.0) = 0.0;
uniform float ripple_radius : hint_range(1.0, 30.0) = 10.0;
uniform vec4 foam_color : source_color = vec4(0.9, 0.95, 1.0, 1.0);

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 reflection = texture(reflection_tex, SCREEN_UV).rgb * reflection_darken;
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fresnel = pow(1.0 - facing, fresnel_power);
	float reflect_amount = clamp(base_reflectivity + fresnel * (max_reflectivity - base_reflectivity), 0.0, max_reflectivity);
	vec3 col = mix(water_color.rgb, reflection, reflect_amount);

	// Sum the 4 rotors' waves first (so they constructively/destructively
	// interfere like real overlapping downwash), then shape the result once.
	// Wavenumber 6.3 -> wavelength 2*PI/6.3 =~ 1.0m: short enough that real
	// small-scale water ripples (cm-to-dm scale) look plausible, and short
	// enough that the 4 rotors interfere visibly without needing to spread
	// their positions as far from reality (see RIPPLE_SOURCE_SPREAD_MULT).
	float wave_sum = 0.0;
	float falloff_max = 0.0;
	for (int i = 0; i < 4; i++) {
		float dist = distance(world_pos.xz, rotor_pos_xz[i]);
		float falloff = 1.0 - smoothstep(0.0, ripple_radius, dist);
		wave_sum += sin(dist * 6.3 - TIME * 7.0) * falloff;
		falloff_max = max(falloff_max, falloff);
	}
	float rings = pow(clamp(wave_sum * 0.25 * 0.5 + 0.5, 0.0, 1.0), 2.0);
	float ripple = rings * falloff_max * ripple_intensity;
	col = mix(col, foam_color.rgb, clamp(ripple, 0.0, 1.0));

	ALBEDO = col;
}
