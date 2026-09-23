extends Node3D

# Real-world terrain stage: downloads GSI (Geospatial Information Authority
# of Japan) elevation tiles at runtime and builds a finite terrain patch
# around a curated real-world location.
#
# Tile format spec (verified against https://maps.gsi.go.jp/development/demtile.html):
#   x = R*65536 + G*256 + B
#   x < 8388608        -> h = x * 0.01
#   x == 8388608        -> no data
#   x > 8388608        -> h = (x - 16777216) * 0.01
#   no-data pixel is (128, 0, 0)

const TILE_ZOOM: int = 14
const TILE_SIZE: int = 256
const GRID: int = 3  # NxN dem_png tiles fetched around the center point
const DEM_URL_TEMPLATE: String = "https://cyberjapandata.gsi.go.jp/xyz/dem_png/%d/%d/%d.png"

const LOCATIONS: Dictionary = {
	"fuji": {"name": "Mt. Fuji", "lat": 35.3606, "lon": 138.7274},
	"miyajima": {
		"name": "Miyajima (Itsukushima Shrine)",
		# Center point roughly midway between the Otorii and Mt. Misen so a
		# single 3x3 tile patch (~6km) covers both.
		"lat": 34.2886, "lon": 132.3189,
		"landmarks": [
			# Otorii (Great Torii) coordinates from OpenStreetMap (ODbL,
			# https://www.openstreetmap.org/way/555763409), verified live
			# against the tile server. DEM has no data here (it stands in
			# tidal water), which is exactly why it needs to be added
			# separately from the terrain mesh.
			{"lat": 34.2972999, "lon": 132.3181356, "type": "torii"},
		],
	},
}

# Quality presets: downsample factor (source pixels per mesh cell)
const QUALITY_PRESETS: Dictionary = {
	"low": 8,
	"mid": 5,
	"high": 3,
}
const DEFAULT_DOWNSAMPLE: int = 5
const ELEVATION_UNIT: float = 0.01  # meters per DEM PNG encoding step

var quality_mode: String = "auto"
var status_text: String = ""

var _downsample: int = DEFAULT_DOWNSAMPLE
var _http: HTTPRequest
var _enabled: bool = false
var _loading: bool = false
var _cache: Dictionary = {}  # location_id -> {heights, size, resolution_m}
var _current_location: String = ""
var _static_body: StaticBody3D
var _mesh_instance: MeshInstance3D
var _shared_material: StandardMaterial3D
var _water_mesh_instance: MeshInstance3D
var _water_material: ShaderMaterial
var _water_viewport: SubViewport
var _water_camera: Camera3D
var _water_active: bool = false
var _player: CharacterBody3D
var _spawn_position: Vector3 = Vector3.ZERO
var _spawn_rotation: Vector3 = Vector3.ZERO
var _status_timer: float = 0.0

func _process(delta: float) -> void:
	if _status_timer > 0.0:
		_status_timer -= delta
		if _status_timer <= 0.0:
			status_text = ""

	if _water_active and _water_camera:
		_update_water_camera()
	if _water_active and _player:
		_update_water_ripple()

func _ready() -> void:
	_http = HTTPRequest.new()
	_http.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_http)

	_shared_material = StandardMaterial3D.new()
	_shared_material.vertex_color_use_as_albedo = true
	_shared_material.roughness = 0.85

	_water_material = ShaderMaterial.new()
	_water_material.shader = preload("res://shaders/water_reflection.gdshader")

func is_loading() -> bool:
	return _loading

func location_name(location_id: String) -> String:
	if LOCATIONS.has(location_id):
		return LOCATIONS[location_id]["name"]
	return location_id

func set_quality(mode: String) -> void:
	quality_mode = mode
	var factor: int = QUALITY_PRESETS.get(mode, DEFAULT_DOWNSAMPLE)
	if factor != _downsample:
		_downsample = factor
		if _enabled and _current_location != "" and _cache.has(_current_location):
			_build_mesh(_current_location)

# Kicks off (or reuses a cached) load of the given location, then calls back
# into `main` via _on_real_terrain_ready(location_id) or
# _on_real_terrain_failed(location_id, reason). Async because tiles are
# fetched over the network.
func request_location(location_id: String, main: Node) -> void:
	if _loading or not LOCATIONS.has(location_id):
		return
	if _cache.has(location_id):
		_build_mesh(location_id)
		main._on_real_terrain_ready(location_id)
		return
	_loading = true
	status_text = "Loading %s terrain..." % location_name(location_id)
	_download_location(location_id, main)

func _download_location(location_id: String, main: Node) -> void:
	var loc: Dictionary = LOCATIONS[location_id]
	var center := _latlon_to_tile_f(loc["lat"], loc["lon"], TILE_ZOOM)
	var tx0 := int(floor(center.x)) - GRID / 2
	var ty0 := int(floor(center.y)) - GRID / 2

	var grid_px := GRID * TILE_SIZE
	var heights := PackedFloat32Array()
	heights.resize(grid_px * grid_px)
	# GSI's DEM has no data over the sea (it's a land elevation model), so a
	# "no data" pixel reliably means water — that's what drives the sea
	# color below, not a height threshold (which would misclassify real
	# low-lying land near 0m).
	var water_mask := PackedByteArray()
	water_mask.resize(grid_px * grid_px)

	var ok := true
	for gy in range(GRID):
		for gx in range(GRID):
			var tx := tx0 + gx
			var ty := ty0 + gy
			var url := DEM_URL_TEMPLATE % [TILE_ZOOM, tx, ty]
			var err := _http.request(url)
			if err != OK:
				ok = false
				continue
			var result: Array = await _http.request_completed
			var response_code: int = result[1]
			var body: PackedByteArray = result[3]
			if response_code != 200:
				ok = false
				continue
			var img := Image.new()
			if img.load_png_from_buffer(body) != OK:
				ok = false
				continue
			img.convert(Image.FORMAT_RGB8)
			for py in range(TILE_SIZE):
				for px in range(TILE_SIZE):
					var c := img.get_pixel(px, py)
					var ix := gx * TILE_SIZE + px
					var iy := gy * TILE_SIZE + py
					var idx := iy * grid_px + ix
					heights[idx] = _decode_height(c)
					water_mask[idx] = 1 if _is_no_data(c) else 0

	_loading = false

	if not ok:
		status_text = "Failed to load %s terrain (network error)" % loc["name"]
		_status_timer = 4.0
		main._on_real_terrain_failed(location_id, status_text)
		return

	status_text = ""
	_cache[location_id] = {
		"heights": heights,
		"water_mask": water_mask,
		"size": grid_px,
		"resolution_m": _meters_per_pixel(loc["lat"], TILE_ZOOM),
		"tx0": tx0,
		"ty0": ty0,
	}
	_build_mesh(location_id)
	main._on_real_terrain_ready(location_id)

# Converts a lat/lon into this location's local mesh XZ (meters from the
# NW corner of the fetched tile grid) — the same coordinate space used for
# both the raw and downsampled height grids, regardless of downsample factor.
func _latlon_to_local_xz(location_id: String, lat: float, lon: float) -> Vector2:
	var data: Dictionary = _cache[location_id]
	var tile_f := _latlon_to_tile_f(lat, lon, TILE_ZOOM)
	var tx0: int = data["tx0"]
	var ty0: int = data["ty0"]
	var px: float = (tile_f.x - tx0) * TILE_SIZE
	var pz: float = (tile_f.y - ty0) * TILE_SIZE
	var resolution_m: float = data["resolution_m"]
	return Vector2(px * resolution_m, pz * resolution_m)

func _height_at_local_xz(location_id: String, local_xz: Vector2) -> float:
	var data: Dictionary = _cache[location_id]
	var size: int = data["size"]
	var resolution_m: float = data["resolution_m"]
	var sx: int = clampi(int(round(local_xz.x / resolution_m)), 0, size - 1)
	var sz: int = clampi(int(round(local_xz.y / resolution_m)), 0, size - 1)
	var heights: PackedFloat32Array = data["heights"]
	return heights[sz * size + sx]

# Whether the given world position sits over a water cell of the active
# location. `RealTerrainManager` itself sits at the world origin, so world
# XZ and this location's local mesh XZ are the same coordinate space.
func is_water_at_world_xz(world_pos: Vector3) -> bool:
	if not _enabled or _current_location == "" or not _cache.has(_current_location):
		return false
	var data: Dictionary = _cache[_current_location]
	var size: int = data["size"]
	var resolution_m: float = data["resolution_m"]
	var sx: int = clampi(int(round(world_pos.x / resolution_m)), 0, size - 1)
	var sz: int = clampi(int(round(world_pos.z / resolution_m)), 0, size - 1)
	var water_mask: PackedByteArray = data["water_mask"]
	return water_mask[sz * size + sx] != 0

func _is_no_data(c: Color) -> bool:
	var r := int(round(c.r * 255.0))
	var g := int(round(c.g * 255.0))
	var b := int(round(c.b * 255.0))
	return r == 128 and g == 0 and b == 0

func _decode_height(c: Color) -> float:
	var r := int(round(c.r * 255.0))
	var g := int(round(c.g * 255.0))
	var b := int(round(c.b * 255.0))
	if r == 128 and g == 0 and b == 0:
		return 0.0  # no-data fallback (e.g. coastline edge) — also sea, see water_mask
	var x := (r << 16) + (g << 8) + b
	if x < 8388608:
		return x * ELEVATION_UNIT
	elif x == 8388608:
		return 0.0  # NA sentinel (formula boundary case)
	else:
		return float(x - 16777216) * ELEVATION_UNIT

func _latlon_to_tile_f(lat: float, lon: float, zoom: int) -> Vector2:
	var n := pow(2.0, zoom)
	var lat_rad := deg_to_rad(lat)
	var fx := (lon + 180.0) / 360.0 * n
	var fy := (1.0 - log(tan(lat_rad) + 1.0 / cos(lat_rad)) / PI) / 2.0 * n
	return Vector2(fx, fy)

func _meters_per_pixel(lat: float, zoom: int) -> float:
	return 156543.03392804097 * cos(deg_to_rad(lat)) / pow(2.0, zoom)

func activate(player: CharacterBody3D) -> void:
	_enabled = true
	_player = player
	if _static_body:
		_static_body.visible = true

func deactivate() -> void:
	_enabled = false
	if _static_body:
		_static_body.queue_free()
		_static_body = null
		_mesh_instance = null
		_water_mesh_instance = null
	_water_active = false
	if _water_viewport:
		_water_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED

func get_spawn_position() -> Vector3:
	return _spawn_position

func get_spawn_rotation() -> Vector3:
	return _spawn_rotation

func _height_color(h: float, max_h: float, location_id: String) -> Color:
	if location_id == "fuji":
		return _fuji_height_color(h, max_h)
	var low := Color(0.30, 0.42, 0.20)   # forested base
	var mid := Color(0.45, 0.38, 0.30)   # bare rock
	var high := Color(0.92, 0.92, 0.95)  # snow/rim
	var t: float = clamp(h / maxf(max_h, 1.0), 0.0, 1.0)
	if t < 0.6:
		return low.lerp(mid, t / 0.6)
	return mid.lerp(high, (t - 0.6) / 0.4)

const FUJI_SNOW_THRESHOLD: float = 0.78  # fraction of summit height where snow starts
const FUJI_SNOW_BLEND: float = 0.06      # width of the body-to-snow transition band

# Mt. Fuji's classic look: a blue-grey body (the well-known "blue Fuji"
# haze), brightening into white snow near the summit.
func _fuji_height_color(h: float, max_h: float) -> Color:
	var body_low := Color(0.22, 0.30, 0.40)
	var body_high := Color(0.40, 0.48, 0.58)
	var snow := Color(0.97, 0.97, 1.00)
	var t: float = clamp(h / maxf(max_h, 1.0), 0.0, 1.0)
	var body := body_low.lerp(body_high, clamp(t / FUJI_SNOW_THRESHOLD, 0.0, 1.0))
	var snow_t: float = clamp((t - FUJI_SNOW_THRESHOLD) / FUJI_SNOW_BLEND, 0.0, 1.0)
	return body.lerp(snow, snow_t)

const SEA_COLOR: Color = Color(0.04, 0.15, 0.22)  # flat sea color for no-data (ocean) cells
const SLOPE_SHADE_STRENGTH: float = 0.45  # how dark steep faces get vs. flat ground
const RELIEF_CONTRAST: float = 0.06       # brightness change per meter of local relief
const RELIEF_CLAMP: float = 6.0           # cap relief before shading (avoid blown-out spikes)

# Combines the height gradient with real-geometry-derived shading so gentle
# real-world undulation reads clearly instead of looking like a smooth blob:
#  - slope shading (steep faces darker, ridges/flats brighter), from the
#    smooth vertex normal
#  - local relief contrast (small real bumps brighter, small dips darker),
#    from the height-vs-neighbor-average delta
func _vertex_color(h: float, max_h: float, normal: Vector3, relief: float, location_id: String) -> Color:
	var base := _height_color(h, max_h, location_id)

	# absf(): this project's cross-product winding convention (matching
	# canyon_manager.gd) yields a consistently-signed but not necessarily
	# positive "up" component, so magnitude (not raw sign) is what tracks
	# flat vs. steep.
	var slope_t: float = clamp(1.0 - absf(normal.y), 0.0, 1.0)
	var shadow := Color(0.12, 0.10, 0.09)
	base = base.lerp(shadow, slope_t * SLOPE_SHADE_STRENGTH)

	var relief_clamped: float = clamp(relief, -RELIEF_CLAMP, RELIEF_CLAMP)
	var relief_mult: float = 1.0 + relief_clamped * RELIEF_CONTRAST
	base.r = clamp(base.r * relief_mult, 0.0, 1.0)
	base.g = clamp(base.g * relief_mult, 0.0, 1.0)
	base.b = clamp(base.b * relief_mult, 0.0, 1.0)
	return base

func _build_mesh(location_id: String) -> void:
	if _static_body:
		_static_body.queue_free()
		_static_body = null
		_mesh_instance = null

	_current_location = location_id
	var data: Dictionary = _cache[location_id]
	var src_size: int = data["size"]
	var src: PackedFloat32Array = data["heights"]
	var step: int = _downsample
	var dst_size: int = src_size / step + 1

	var src_water: PackedByteArray = data["water_mask"]

	var heights := PackedFloat32Array()
	heights.resize(dst_size * dst_size)
	var water := PackedByteArray()
	water.resize(dst_size * dst_size)
	var max_h: float = -1e9
	for z in range(dst_size):
		for x in range(dst_size):
			var sx: int = mini(x * step, src_size - 1)
			var sz: int = mini(z * step, src_size - 1)
			var src_idx := sz * src_size + sx
			var h: float = src[src_idx]
			var dst_idx := z * dst_size + x
			heights[dst_idx] = h
			water[dst_idx] = src_water[src_idx]
			max_h = maxf(max_h, h)

	var cell_m: float = data["resolution_m"] * step

	# Pass 1: smooth per-vertex normals (averaged from adjacent face normals).
	# Real mountains are broad, gently-curved forms — flat per-face normals
	# (one normal per triangle) make that read as faceted/blocky. Smooth
	# normals let the true, gradual slope changes drive the shading instead.
	var normals := PackedVector3Array()
	normals.resize(dst_size * dst_size)
	for z in range(dst_size - 1):
		for x in range(dst_size - 1):
			var idx00 := z * dst_size + x
			var idx10 := idx00 + 1
			var idx01 := idx00 + dst_size
			var idx11 := idx01 + 1
			var v00 := Vector3(x * cell_m, heights[idx00], z * cell_m)
			var v10 := Vector3((x + 1) * cell_m, heights[idx10], z * cell_m)
			var v01 := Vector3(x * cell_m, heights[idx01], (z + 1) * cell_m)
			var v11 := Vector3((x + 1) * cell_m, heights[idx11], (z + 1) * cell_m)
			var n1 := (v10 - v00).cross(v01 - v00).normalized()
			var n2 := (v01 - v11).cross(v10 - v11).normalized()
			normals[idx00] += n1
			normals[idx10] += n1 + n2
			normals[idx01] += n1 + n2
			normals[idx11] += n2
	for i in range(normals.size()):
		normals[i] = normals[i].normalized()

	# Pass 2: local relief (height minus the average of the 4 neighbors).
	# Downsampling flattens a mountain's true small-scale bumps into a
	# smooth-looking blob; this measures each real bump/dip that survived
	# downsampling so it can be pushed back into visibility as shading.
	var relief := PackedFloat32Array()
	relief.resize(dst_size * dst_size)
	for z in range(dst_size):
		for x in range(dst_size):
			var idx := z * dst_size + x
			var xm := maxi(x - 1, 0)
			var xp := mini(x + 1, dst_size - 1)
			var zm := maxi(z - 1, 0)
			var zp := mini(z + 1, dst_size - 1)
			var avg_neighbor: float = (
				heights[z * dst_size + xm] + heights[z * dst_size + xp]
				+ heights[zm * dst_size + x] + heights[zp * dst_size + x]
			) * 0.25
			relief[idx] = heights[idx] - avg_neighbor

	var colors := PackedColorArray()
	colors.resize(dst_size * dst_size)
	for i in range(colors.size()):
		if water[i] != 0:
			colors[i] = SEA_COLOR
		else:
			colors[i] = _vertex_color(heights[i], max_h, normals[i], relief[i], location_id)

	# Quads where every corner is a water cell go to their own flat, unshaded
	# mesh (its own reflective material); everything else — land and the
	# land/water boundary — stays on the shaded land mesh exactly as before,
	# so the existing coastline color blend is untouched.
	var land_st := SurfaceTool.new()
	land_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var water_st := SurfaceTool.new()
	water_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var water_quad_count := 0

	for z in range(dst_size - 1):
		for x in range(dst_size - 1):
			var idx00 := z * dst_size + x
			var idx10 := idx00 + 1
			var idx01 := idx00 + dst_size
			var idx11 := idx01 + 1

			var v00 := Vector3(x * cell_m, heights[idx00], z * cell_m)
			var v10 := Vector3((x + 1) * cell_m, heights[idx10], z * cell_m)
			var v01 := Vector3(x * cell_m, heights[idx01], (z + 1) * cell_m)
			var v11 := Vector3((x + 1) * cell_m, heights[idx11], (z + 1) * cell_m)

			var all_water: bool = water[idx00] != 0 and water[idx10] != 0 and water[idx01] != 0 and water[idx11] != 0
			if all_water:
				water_quad_count += 1
				water_st.set_normal(Vector3.UP); water_st.add_vertex(v00)
				water_st.set_normal(Vector3.UP); water_st.add_vertex(v10)
				water_st.set_normal(Vector3.UP); water_st.add_vertex(v01)

				water_st.set_normal(Vector3.UP); water_st.add_vertex(v10)
				water_st.set_normal(Vector3.UP); water_st.add_vertex(v11)
				water_st.set_normal(Vector3.UP); water_st.add_vertex(v01)
			else:
				land_st.set_color(colors[idx00]); land_st.set_normal(normals[idx00]); land_st.add_vertex(v00)
				land_st.set_color(colors[idx10]); land_st.set_normal(normals[idx10]); land_st.add_vertex(v10)
				land_st.set_color(colors[idx01]); land_st.set_normal(normals[idx01]); land_st.add_vertex(v01)

				land_st.set_color(colors[idx10]); land_st.set_normal(normals[idx10]); land_st.add_vertex(v10)
				land_st.set_color(colors[idx11]); land_st.set_normal(normals[idx11]); land_st.add_vertex(v11)
				land_st.set_color(colors[idx01]); land_st.set_normal(normals[idx01]); land_st.add_vertex(v01)

	var mesh := land_st.commit()

	_static_body = StaticBody3D.new()
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.mesh = mesh
	_mesh_instance.material_override = _shared_material
	_static_body.add_child(_mesh_instance)

	if water_quad_count > 0:
		_water_mesh_instance = MeshInstance3D.new()
		_water_mesh_instance.mesh = water_st.commit()
		_water_mesh_instance.material_override = _water_material
		_static_body.add_child(_water_mesh_instance)
		_water_active = true
		_setup_water_reflection()
	else:
		_water_mesh_instance = null
		_water_active = false
		if _water_viewport:
			_water_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED

	var col_shape := CollisionShape3D.new()
	var hmap := HeightMapShape3D.new()
	hmap.map_width = dst_size
	hmap.map_depth = dst_size
	hmap.map_data = heights
	col_shape.shape = hmap
	col_shape.position = Vector3((dst_size - 1) * cell_m * 0.5, 0, (dst_size - 1) * cell_m * 0.5)
	col_shape.scale = Vector3(cell_m, 1.0, cell_m)
	_static_body.add_child(col_shape)

	add_child(_static_body)

	_build_landmarks(location_id)
	_compute_spawn(location_id, dst_size, cell_m, max_h)

# Render resolution of the mirror-camera reflection, relative to the main
# viewport. Downscaled for cost; SCREEN_UV mapping in water_reflection.gdshader
# stays correct at any resolution as long as the aspect ratio matches.
const WATER_REFLECTION_SCALE: float = 0.5

# Lazily creates the SubViewport + mirror camera used for the water surface's
# live reflection (shared world, no duplicated geometry) and points the water
# material at its output texture. Re-entrant: safe to call on every stage
# switch that has water, only builds the nodes once.
func _setup_water_reflection() -> void:
	if not _water_viewport:
		_water_viewport = SubViewport.new()
		_water_viewport.own_world_3d = false
		_water_viewport.world_3d = get_viewport().world_3d
		_water_viewport.transparent_bg = false
		add_child(_water_viewport)

		_water_camera = Camera3D.new()
		_water_camera.current = true
		_water_viewport.add_child(_water_camera)

		_water_material.set_shader_parameter("reflection_tex", _water_viewport.get_texture())
		_water_material.set_shader_parameter("water_color", SEA_COLOR)

	_water_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_resize_water_viewport()

func _resize_water_viewport() -> void:
	var main_size: Vector2i = get_viewport().size
	var target := Vector2i(
		maxi(int(main_size.x * WATER_REFLECTION_SCALE), 1),
		maxi(int(main_size.y * WATER_REFLECTION_SCALE), 1)
	)
	if _water_viewport.size != target:
		_water_viewport.size = target

# Mirrors the active game camera across the water plane (world Y=0) so the
# SubViewport renders exactly what that camera would see reflected in a
# perfectly flat mirror, matching FOV/near/far so SCREEN_UV sampling in the
# water shader lines up 1:1 with the main view.
func _update_water_camera() -> void:
	var active_cam := get_viewport().get_camera_3d()
	if not active_cam:
		return
	_water_camera.fov = active_cam.fov
	_water_camera.near = active_cam.near
	_water_camera.far = active_cam.far
	_water_camera.transform = _mirror_transform_y(active_cam.global_transform)
	_resize_water_viewport()

# Matches low_altitude_particles.gd's ALTITUDE_THRESHOLD so the rotor-wash
# ripple and the spray particles agree on what counts as "close".
const RIPPLE_ALTITUDE_THRESHOLD: float = 30.0

# Rotor-downwash ripple, one wave source per rotor: strongest at water level,
# fading out by RIPPLE_ALTITUDE_THRESHOLD. The water surface is always at
# world Y=0 (see is_water_at_world_xz), so altitude is just the player's Y.
# The real rotor spacing (~1.1m across) is used as-is: an earlier version of
# the ripple wavelength (3.5m) made the real spacing produce an interference
# pattern indistinguishable from a single source, needing the rotor offsets
# exaggerated up to 6x to read as 4 sources. Shortening the wavelength to
# ~1.0m (see water_reflection.gdshader) fixed that at the source, so the
# real spacing alone now produces a visibly distinct pattern.
func _update_water_ripple() -> void:
	var pos := _player.global_position
	var intensity := 0.0
	if is_water_at_world_xz(pos):
		intensity = clamp(1.0 - pos.y / RIPPLE_ALTITUDE_THRESHOLD, 0.0, 1.0)
	var rotor_positions_xz := PackedVector2Array()
	for rotor_pos in _player.get_rotor_world_positions():
		rotor_positions_xz.append(Vector2(rotor_pos.x, rotor_pos.z))
	_water_material.set_shader_parameter("rotor_pos_xz", rotor_positions_xz)
	_water_material.set_shader_parameter("ripple_intensity", intensity)

# Reflects a transform across the world Y=0 plane: negate the Y component of
# the origin and of each basis axis. Verified with a headless script (camera
# looking straight down from above mirrors to looking straight up from
# below, at the mirrored position) before relying on it here.
func _mirror_transform_y(t: Transform3D) -> Transform3D:
	var b := t.basis
	var mx := Vector3(b.x.x, -b.x.y, b.x.z)
	var my := Vector3(b.y.x, -b.y.y, b.y.z)
	var mz := Vector3(b.z.x, -b.z.y, b.z.z)
	var origin := Vector3(t.origin.x, -t.origin.y, t.origin.z)
	return Transform3D(Basis(mx, my, mz), origin)

func _compute_spawn(location_id: String, dst_size: int, cell_m: float, max_h: float) -> void:
	var loc: Dictionary = LOCATIONS[location_id]
	var landmarks: Array = loc.get("landmarks", [])
	for lm in landmarks:
		if lm["type"] == "torii":
			# Approach from the seaward (north) side, elevated, facing south
			# (+Z) toward the torii with the shrine/Mt. Misen behind it —
			# the classic view.
			var xz := _latlon_to_local_xz(location_id, lm["lat"], lm["lon"])
			var base_h := _height_at_local_xz(location_id, xz)
			_spawn_position = Vector3(xz.x, base_h + 60.0, xz.y - 400.0)
			_spawn_rotation = Vector3(0.0, PI, 0.0)
			return

	# Default: spawn above and south of the highest point, facing -Z (north,
	# toward the peak) — GSI tile rows increase southward, so +Z is south.
	var center_x: float = (dst_size - 1) * cell_m * 0.5
	var center_z: float = (dst_size - 1) * cell_m * 0.5
	var offset_z: float = (dst_size - 1) * cell_m * 0.3
	_spawn_position = Vector3(center_x, max_h + 150.0, center_z + offset_z)
	_spawn_rotation = Vector3.ZERO

# Places decorative/gameplay landmarks (currently just the Otorii) that the
# DEM cannot capture (structures standing in water read as "no data").
func _build_landmarks(location_id: String) -> void:
	var loc: Dictionary = LOCATIONS[location_id]
	for lm in loc.get("landmarks", []):
		var xz := _latlon_to_local_xz(location_id, lm["lat"], lm["lon"])
		var base_h := _height_at_local_xz(location_id, xz)
		var base_pos := Vector3(xz.x, base_h, xz.y)
		match lm["type"]:
			"torii":
				_build_torii(base_pos)

# Simplified O-torii of Itsukushima Shrine, built from primitives (same
# technique as the player drone model). Confirmed real dimensions (see
# https://www.miyajima.or.jp/sightseeing/ss_ootorii.html and the 桁行/梁間
# figures reported alongside it): overall height 16.6m, main-pillar
# center-to-center span 10.939m, support-leg center-to-center depth 9.394m,
# main pillar circumference 9.9m (-> ~3.15m diameter), top beam (kasagi)
# length 24.2m. Individual beam thicknesses and support-leg diameter are
# not published; they are proportional estimates typical of ryobu-style
# torii, not sourced measurements.
func _build_torii(base_pos: Vector3) -> void:
	const MAIN_SPAN: float = 10.939
	const SUPPORT_DEPTH: float = 9.394
	const MAIN_DIAMETER: float = 3.15
	const SUPPORT_DIAMETER: float = 1.2
	const PILLAR_HEIGHT: float = 14.6
	const SUPPORT_HEIGHT: float = 14.0
	const SHIMAKI_LENGTH: float = 22.0
	const SHIMAKI_HEIGHT: float = 0.8
	const KASAGI_LENGTH: float = 24.2
	const KASAGI_HEIGHT: float = 1.2
	const NUKI_HEIGHT_FRAC: float = 0.55  # tie beam height as a fraction of pillar height

	var vermillion := StandardMaterial3D.new()
	vermillion.albedo_color = Color(0.72, 0.24, 0.10)
	vermillion.roughness = 0.75

	var gold := StandardMaterial3D.new()
	gold.albedo_color = Color(0.85, 0.70, 0.25)
	gold.metallic = 0.6
	gold.roughness = 0.35

	var root := StaticBody3D.new()
	root.position = base_pos

	var half_span := MAIN_SPAN * 0.5
	var half_depth := SUPPORT_DEPTH * 0.5

	# Main pillars (shin-bashira)
	for side in [-1.0, 1.0]:
		var pillar := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = MAIN_DIAMETER * 0.5
		mesh.bottom_radius = MAIN_DIAMETER * 0.5
		mesh.height = PILLAR_HEIGHT
		pillar.mesh = mesh
		pillar.material_override = vermillion
		pillar.position = Vector3(side * half_span, PILLAR_HEIGHT * 0.5, 0.0)
		root.add_child(pillar)

		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(MAIN_DIAMETER, PILLAR_HEIGHT, MAIN_DIAMETER)
		col.shape = box
		col.position = pillar.position
		root.add_child(col)

	# Support legs (sode-bashira), 2 per main pillar (fore/aft)
	for side in [-1.0, 1.0]:
		for depth_side in [-1.0, 1.0]:
			var leg := MeshInstance3D.new()
			var mesh := CylinderMesh.new()
			mesh.top_radius = SUPPORT_DIAMETER * 0.5
			mesh.bottom_radius = SUPPORT_DIAMETER * 0.5
			mesh.height = SUPPORT_HEIGHT
			leg.mesh = mesh
			leg.material_override = vermillion
			leg.position = Vector3(side * half_span, SUPPORT_HEIGHT * 0.5, depth_side * half_depth)
			root.add_child(leg)

	# Tie beam (nuki), between the two main pillars
	var nuki := MeshInstance3D.new()
	var nuki_mesh := BoxMesh.new()
	nuki_mesh.size = Vector3(MAIN_SPAN + MAIN_DIAMETER, 0.8, 1.0)
	nuki.mesh = nuki_mesh
	nuki.material_override = vermillion
	nuki.position = Vector3(0.0, PILLAR_HEIGHT * NUKI_HEIGHT_FRAC, 0.0)
	root.add_child(nuki)

	# Gaku (central plaque) on the tie beam
	var gaku := MeshInstance3D.new()
	var gaku_mesh := BoxMesh.new()
	gaku_mesh.size = Vector3(1.6, 1.2, 0.15)
	gaku.mesh = gaku_mesh
	gaku.material_override = gold
	gaku.position = Vector3(0.0, PILLAR_HEIGHT * NUKI_HEIGHT_FRAC + 1.0, 0.6)
	root.add_child(gaku)

	# Shimaki (lower top beam)
	var shimaki := MeshInstance3D.new()
	var shimaki_mesh := BoxMesh.new()
	shimaki_mesh.size = Vector3(SHIMAKI_LENGTH, SHIMAKI_HEIGHT, 1.6)
	shimaki.mesh = shimaki_mesh
	shimaki.material_override = vermillion
	shimaki.position = Vector3(0.0, PILLAR_HEIGHT + SHIMAKI_HEIGHT * 0.5, 0.0)
	root.add_child(shimaki)

	# Kasagi (top beam, widest — the torii's signature overhanging cap)
	var kasagi := MeshInstance3D.new()
	var kasagi_mesh := BoxMesh.new()
	kasagi_mesh.size = Vector3(KASAGI_LENGTH, KASAGI_HEIGHT, 2.0)
	kasagi.mesh = kasagi_mesh
	kasagi.material_override = vermillion
	kasagi.position = Vector3(0.0, PILLAR_HEIGHT + SHIMAKI_HEIGHT + KASAGI_HEIGHT * 0.5, 0.0)
	root.add_child(kasagi)

	var top_col := CollisionShape3D.new()
	var top_box := BoxShape3D.new()
	top_box.size = Vector3(KASAGI_LENGTH, SHIMAKI_HEIGHT + KASAGI_HEIGHT, 2.0)
	top_col.shape = top_box
	top_col.position = Vector3(0.0, PILLAR_HEIGHT + (SHIMAKI_HEIGHT + KASAGI_HEIGHT) * 0.5, 0.0)
	root.add_child(top_col)

	_static_body.add_child(root)
