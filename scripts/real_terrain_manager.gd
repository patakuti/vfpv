extends Node3D

# Real-world terrain stage: downloads elevation tiles at runtime and builds a
# finite terrain patch around a curated real-world location. Each location
# picks a tile_source ("gsi" by default), which selects the tile URL/zoom and
# the decode/water-detection rules below — the rest of this file (mesh
# building, landmarks, water reflection, etc.) is tile-source-agnostic.
#
# gsi tile format spec (verified against
# https://maps.gsi.go.jp/development/demtile.html):
#   x = R*65536 + G*256 + B
#   x < 8388608        -> h = x * 0.01
#   x == 8388608        -> no data
#   x > 8388608        -> h = (x - 16777216) * 0.01
#   no-data pixel is (128, 0, 0)
#   GSI's DEM only covers land, so a no-data pixel reliably means water.
#
# aws_terrarium tile format spec (Terrarium encoding, see
# https://github.com/tilezen/joerd/blob/master/docs/formats.md):
#   h = R*256 + G + B/256 - 32768
#   Unlike GSI, this dataset carries real bathymetry under water (verified
#   live: mid-channel Golden Gate strait decodes to ~-96m, matching its known
#   depth, not a sentinel value) — so water here is detected by an elevation
#   threshold instead of a no-data pixel code.

const TILE_SIZE: int = 256
const GRID: int = 3  # NxN tiles fetched around the center point

const TILE_SOURCES: Dictionary = {
	"gsi": {
		"url_template": "https://cyberjapandata.gsi.go.jp/xyz/dem_png/%d/%d/%d.png",
		"zoom": 14,
	},
	"aws_terrarium": {
		"url_template": "https://elevation-tiles-prod.s3.amazonaws.com/terrarium/%d/%d/%d.png",
		"zoom": 14,
	},
}

# Sea-level threshold for aws_terrarium's real bathymetry data. 0m is the
# geodetic/tidal datum most terrain sources normalize to; verified live
# against real values (mid-strait ~-96m, shoreline land positive), see
# 02_design.md. May need a small tidal-offset adjustment once the coastline
# is actually rendered for a specific location.
const AWS_TERRARIUM_WATER_LEVEL: float = 0.0

const LOCATIONS: Dictionary = {
	"fuji": {"name": "Mt. Fuji", "lat": 35.3606, "lon": 138.7274, "tile_source": "gsi"},
	"miyajima": {
		"name": "Miyajima (Itsukushima Shrine)",
		# Center point roughly midway between the Otorii and Mt. Misen so a
		# single 3x3 tile patch (~6km) covers both.
		"lat": 34.2886, "lon": 132.3189,
		"tile_source": "gsi",
		"landmarks": [
			# Otorii (Great Torii) coordinates from OpenStreetMap (ODbL,
			# https://www.openstreetmap.org/way/555763409), verified live
			# against the tile server. DEM has no data here (it stands in
			# tidal water), which is exactly why it needs to be added
			# separately from the terrain mesh.
			{"lat": 34.2972999, "lon": 132.3181356, "type": "torii"},
		],
		# Winter solstice golden hour, tuned (see main.gd _apply_sunset_lighting
		# and 03_plan.md Phase 15-17) so the sun clears Mt. Misen (~535m) from
		# a low, near-sea-level vantage.
		"lighting": {"month": 12, "day": 21, "target_elevation_deg": 25.0, "light_color": Color(1.0, 0.72, 0.45)},
	},
	"goldengate": {
		"name": "Golden Gate Bridge",
		# Roughly the bridge's midpoint over the strait; a 3x3 tile patch
		# (~6km at zoom 14) comfortably covers the ~2.7km bridge plus both
		# shores. Verified live (Phase 24-1): decodes to real bathymetry
		# (~-96m at mid-channel), not GSI-style "no data".
		"lat": 37.8199, "lon": -122.4783,
		"tile_source": "aws_terrarium",
		"landmarks": [
			{
				"type": "golden_gate_bridge",
				# South tower (San Francisco side): OpenStreetMap building
				# (way 1330586852, height=225 tag, close to the official
				# 227m), directly sourced. Verified ~4.3m from the OSM road
				# centerline (Phase 24-4).
				"south_tower": {"lat": 37.8140144, "lon": -122.4778921},
				# North tower (Marin side): no matching OSM feature found.
				# Derived from the south tower + the official main-span
				# length (1280m) + the real bridge bearing measured from OSM
				# road geometry near the south tower (~354.7deg). Cross-
				# checked: lands ~4.4m from the road centerline, matching the
				# south tower's own ~4.3m offset (Phase 24-4).
				"north_tower": {"lat": 37.8254769, "lon": -122.4792333},
			},
		],
		# Placeholder, NOT tuned: unlike Miyajima's 25 deg (tuned against a
		# known ~535m peak actually occluding the sun), there is no
		# landmark-occlusion analysis yet for this stage (the bridge model
		# doesn't exist yet), so this reuses the original pre-Miyajima-tuning
		# default (3 deg = just before sunset) as a neutral starting point.
		# Equinox is used for the date because it's the one astronomically
		# well-defined "no particular reason to pick otherwise" default
		# (sunset is due west at any latitude — already verified in
		# solar_position.gd), unlike Miyajima's winter-solstice date, which
		# was chosen for a documented cultural/photographic reason specific
		# to that shrine. Revisit once the bridge model exists and an actual
		# view can be checked.
		"lighting": {"month": 3, "day": 20, "target_elevation_deg": 3.0, "light_color": Color(1.0, 0.72, 0.45)},
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
	var tile_source: String = loc.get("tile_source", "gsi")
	var source: Dictionary = TILE_SOURCES[tile_source]
	var zoom: int = source["zoom"]
	var url_template: String = source["url_template"]

	var center := _latlon_to_tile_f(loc["lat"], loc["lon"], zoom)
	var tx0 := int(floor(center.x)) - GRID / 2
	var ty0 := int(floor(center.y)) - GRID / 2

	var grid_px := GRID * TILE_SIZE
	var heights := PackedFloat32Array()
	heights.resize(grid_px * grid_px)
	var water_mask := PackedByteArray()
	water_mask.resize(grid_px * grid_px)

	var ok := true
	for gy in range(GRID):
		for gx in range(GRID):
			var tx := tx0 + gx
			var ty := ty0 + gy
			var url := url_template % [zoom, tx, ty]
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
					var h := _decode_height(c, tile_source)
					heights[idx] = h
					water_mask[idx] = 1 if _is_water(c, h, tile_source) else 0

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
		"resolution_m": _meters_per_pixel(loc["lat"], zoom),
		"zoom": zoom,
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
	var tile_f := _latlon_to_tile_f(lat, lon, data["zoom"])
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

func _is_no_data_gsi(c: Color) -> bool:
	var r := int(round(c.r * 255.0))
	var g := int(round(c.g * 255.0))
	var b := int(round(c.b * 255.0))
	return r == 128 and g == 0 and b == 0

func _decode_height_gsi(c: Color) -> float:
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

func _decode_height_terrarium(c: Color) -> float:
	var r := int(round(c.r * 255.0))
	var g := int(round(c.g * 255.0))
	var b := int(round(c.b * 255.0))
	return float(r * 256 + g) + float(b) / 256.0 - 32768.0

func _decode_height(c: Color, tile_source: String) -> float:
	if tile_source == "aws_terrarium":
		return _decode_height_terrarium(c)
	return _decode_height_gsi(c)

# Water detection is tile-source-specific: gsi flags water via a no-data
# pixel code (its DEM only covers land), aws_terrarium via an elevation
# threshold (it carries real bathymetry, see the file-level comment above).
func _is_water(c: Color, h: float, tile_source: String) -> bool:
	if tile_source == "aws_terrarium":
		return h <= AWS_TERRARIUM_WATER_LEVEL
	return _is_no_data_gsi(c)

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
	var resolution_m: float = data["resolution_m"]

	# Max height is measured from the full-resolution data, not the
	# downsampled grid, so the boundary high-res subdivision below (which
	# reads real elevations that downsampling may have skipped) never sees a
	# value above what _vertex_color()'s height ratio was normalized against.
	var max_h: float = -1e9
	for h in src:
		max_h = maxf(max_h, h)

	var heights := PackedFloat32Array()
	heights.resize(dst_size * dst_size)
	var water := PackedByteArray()
	water.resize(dst_size * dst_size)
	for z in range(dst_size):
		for x in range(dst_size):
			var sx: int = mini(x * step, src_size - 1)
			var sz: int = mini(z * step, src_size - 1)
			var src_idx := sz * src_size + sx
			var dst_idx := z * dst_size + x
			heights[dst_idx] = src[src_idx]
			water[dst_idx] = src_water[src_idx]

	var cell_m: float = resolution_m * step

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
	# mesh (its own reflective material); quads that are entirely land stay on
	# the shaded land mesh, both using the downsampled grid as before (this is
	# most of the area, so it keeps the original performance). Quads whose
	# underlying full-resolution data is a mix of land and water are the
	# coastline itself — those are rebuilt from the full-resolution source
	# data instead of the downsampled grid, so the coastline's shape doesn't
	# collapse to the mesh's (much coarser) quad grid.
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

			var sx0: int = mini(x * step, src_size - 1)
			var sx1: int = mini((x + 1) * step, src_size - 1)
			var sz0: int = mini(z * step, src_size - 1)
			var sz1: int = mini((z + 1) * step, src_size - 1)

			var any_water := false
			var any_land := false
			for bz in range(sz0, sz1 + 1):
				for bx in range(sx0, sx1 + 1):
					if src_water[bz * src_size + bx] != 0:
						any_water = true
					else:
						any_land = true

			if any_water and any_land and sx1 > sx0 and sz1 > sz0:
				water_quad_count += _emit_coastline_block(
					src, src_water, src_size, sx0, sx1, sz0, sz1, resolution_m,
					max_h, location_id, land_st, water_st
				)
				continue

			var v00 := Vector3(x * cell_m, heights[idx00], z * cell_m)
			var v10 := Vector3((x + 1) * cell_m, heights[idx10], z * cell_m)
			var v01 := Vector3(x * cell_m, heights[idx01], (z + 1) * cell_m)
			var v11 := Vector3((x + 1) * cell_m, heights[idx11], (z + 1) * cell_m)

			if any_water:  # all_water (the "any_water and any_land" mixed case is handled above)
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

# How many sub-steps the coastline boundary is supersampled into per native
# DEM pixel. The land/water mask is only known at native-pixel samples, so a
# boundary built directly from it (one sub-quad per pixel) is a staircase of
# ~8m steps. Sampling water_mask's spline-smoothed field (see
# _sample_water_smooth) at a finer step than the pixels it's built from turns
# that staircase into a curve that rounds each pixel corner into an arc,
# instead of just shrinking the steps.
const COASTLINE_SUPERSAMPLE: int = 4

# Rebuilds a downsampled-grid quad whose full-resolution source data (unlike
# its 4 coarse corners) contains both land and water — i.e. an actual stretch
# of coastline that downsampling would otherwise flatten into one of the
# mesh's large axis-aligned quads. Re-triangulates it at native pixel
# resolution first (cheap: one quad per native pixel, same as a normal land
# or water quad) and only spline-supersamples (_emit_coastline_submesh, the
# expensive part) the individual native pixels that themselves straddle land
# and water. Most native pixels inside a "mixed" coarse quad are actually
# uniform — the true coastline is a thin curve, not most of the quad's area —
# so this keeps the expensive step's cost proportional to the coastline's
# real length, instead of to the coarse grid's (quality-dependent) cell size.
# Appends the result straight into the shared land/water SurfaceTools.
# Returns the number of all-water quads/sub-quads emitted (added to the
# caller's water_quad_count).
func _emit_coastline_block(
	src: PackedFloat32Array, src_water: PackedByteArray, src_size: int,
	sx0: int, sx1: int, sz0: int, sz1: int, resolution_m: float, max_h: float,
	location_id: String, land_st: SurfaceTool, water_st: SurfaceTool
) -> int:
	var water_quad_count := 0
	for sz in range(sz0, sz1):
		for sx in range(sx0, sx1):
			var i00 := sz * src_size + sx
			var i10 := sz * src_size + (sx + 1)
			var i01 := (sz + 1) * src_size + sx
			var i11 := (sz + 1) * src_size + (sx + 1)

			var w00: bool = src_water[i00] != 0
			var w10: bool = src_water[i10] != 0
			var w01: bool = src_water[i01] != 0
			var w11: bool = src_water[i11] != 0

			if w00 != w10 or w00 != w01 or w00 != w11:
				# This one native pixel straddles the coastline: refine it
				# with the spline-smoothed supersampled tessellation.
				water_quad_count += _emit_coastline_submesh(
					src, src_water, src_size, sx, sx + 1, sz, sz + 1,
					resolution_m, max_h, location_id, land_st, water_st
				)
				continue

			# Uniform native pixel (the large majority, even inside a "mixed"
			# coarse quad): emit it directly at native resolution, same as
			# the coarse loop's own all-water/all-land fast paths.
			var v00 := Vector3(sx * resolution_m, src[i00], sz * resolution_m)
			var v10 := Vector3((sx + 1) * resolution_m, src[i10], sz * resolution_m)
			var v01 := Vector3(sx * resolution_m, src[i01], (sz + 1) * resolution_m)
			var v11 := Vector3((sx + 1) * resolution_m, src[i11], (sz + 1) * resolution_m)

			if w00:
				water_quad_count += 1
				water_st.set_normal(Vector3.UP); water_st.add_vertex(v00)
				water_st.set_normal(Vector3.UP); water_st.add_vertex(v10)
				water_st.set_normal(Vector3.UP); water_st.add_vertex(v01)

				water_st.set_normal(Vector3.UP); water_st.add_vertex(v10)
				water_st.set_normal(Vector3.UP); water_st.add_vertex(v11)
				water_st.set_normal(Vector3.UP); water_st.add_vertex(v01)
			else:
				var n00 := _native_normal(src, src_size, sx, sz, resolution_m)
				var n10 := _native_normal(src, src_size, sx + 1, sz, resolution_m)
				var n01 := _native_normal(src, src_size, sx, sz + 1, resolution_m)
				var n11 := _native_normal(src, src_size, sx + 1, sz + 1, resolution_m)

				var c00 := _vertex_color(src[i00], max_h, n00, _native_relief(src, src_size, sx, sz), location_id)
				var c10 := _vertex_color(src[i10], max_h, n10, _native_relief(src, src_size, sx + 1, sz), location_id)
				var c01 := _vertex_color(src[i01], max_h, n01, _native_relief(src, src_size, sx, sz + 1), location_id)
				var c11 := _vertex_color(src[i11], max_h, n11, _native_relief(src, src_size, sx + 1, sz + 1), location_id)

				land_st.set_color(c00); land_st.set_normal(n00); land_st.add_vertex(v00)
				land_st.set_color(c10); land_st.set_normal(n10); land_st.add_vertex(v10)
				land_st.set_color(c01); land_st.set_normal(n01); land_st.add_vertex(v01)

				land_st.set_color(c10); land_st.set_normal(n10); land_st.add_vertex(v10)
				land_st.set_color(c11); land_st.set_normal(n11); land_st.add_vertex(v11)
				land_st.set_color(c01); land_st.set_normal(n01); land_st.add_vertex(v01)
	return water_quad_count

# Spline-supersamples a single native-pixel cell that straddles land and
# water (called only from _emit_coastline_block, only for such cells).
# Re-triangulates it at COASTLINE_SUPERSAMPLE sub-steps per axis, classifying
# each sub-quad corner from a spline-smoothed reconstruction of the land/
# water mask (see _sample_water_smooth) rather than the raw pixel mask, so
# the boundary follows a smooth curve through the real coastline instead of
# jumping straight from land to water at this pixel's edges. Appends the
# result straight into the shared land/water SurfaceTools. Returns the
# number of all-water sub-quads emitted.
func _emit_coastline_submesh(
	src: PackedFloat32Array, src_water: PackedByteArray, src_size: int,
	sx0: int, sx1: int, sz0: int, sz1: int, resolution_m: float, max_h: float,
	location_id: String, land_st: SurfaceTool, water_st: SurfaceTool
) -> int:
	var sub := COASTLINE_SUPERSAMPLE
	var nx := (sx1 - sx0) * sub
	var nz := (sz1 - sz0) * sub

	# Precompute the spline-smoothed water field and bilinear heights once per
	# grid corner instead of once per sub-quad corner: each interior corner
	# is shared by up to 4 adjacent sub-quads, and _sample_water_smooth in
	# particular (a 16-tap bicubic) is too expensive to redo that many times.
	var gw := nx + 1
	var gh := nz + 1
	var w_grid := PackedFloat32Array()
	w_grid.resize(gw * gh)
	var h_grid := PackedFloat32Array()
	h_grid.resize(gw * gh)
	for jz in range(gh):
		var fz: float = sz0 + float(jz) / sub
		for jx in range(gw):
			var fx: float = sx0 + float(jx) / sub
			var gi := jz * gw + jx
			w_grid[gi] = _sample_water_smooth(src_water, src_size, fx, fz)
			h_grid[gi] = _sample_height_bilinear(src, src_size, fx, fz)

	# Shading (normal/relief) stays pinned to native-pixel resolution rather
	# than following the supersampled geometry: the DEM has no real elevation
	# detail below native-pixel resolution, so shading any finer than that
	# would be inventing detail the source data doesn't have, not revealing
	# it (see _vertex_color's "measured DEM variation, not fabricated" design
	# intent). Precomputed once per native pixel in this block, since many
	# supersampled corners round to the same pixel.
	var nw := sx1 - sx0 + 1
	var nh := sz1 - sz0 + 1
	var normal_grid := PackedVector3Array()
	normal_grid.resize(nw * nh)
	var relief_grid := PackedFloat32Array()
	relief_grid.resize(nw * nh)
	for lz in range(nh):
		for lx in range(nw):
			var ni := lz * nw + lx
			normal_grid[ni] = _native_normal(src, src_size, sx0 + lx, sz0 + lz, resolution_m)
			relief_grid[ni] = _native_relief(src, src_size, sx0 + lx, sz0 + lz)

	var water_subquad_count := 0
	for jz in range(nz):
		for jx in range(nx):
			var gi00 := jz * gw + jx
			var gi10 := gi00 + 1
			var gi01 := gi00 + gw
			var gi11 := gi01 + 1

			var fx0: float = sx0 + float(jx) / sub
			var fz0: float = sz0 + float(jz) / sub
			var fx1: float = fx0 + 1.0 / sub
			var fz1: float = fz0 + 1.0 / sub

			var w00 := w_grid[gi00]; var w10 := w_grid[gi10]; var w01 := w_grid[gi01]; var w11 := w_grid[gi11]
			var h00 := h_grid[gi00]; var h10 := h_grid[gi10]; var h01 := h_grid[gi01]; var h11 := h_grid[gi11]

			var v00 := Vector3(fx0 * resolution_m, h00, fz0 * resolution_m)
			var v10 := Vector3(fx1 * resolution_m, h10, fz0 * resolution_m)
			var v01 := Vector3(fx0 * resolution_m, h01, fz1 * resolution_m)
			var v11 := Vector3(fx1 * resolution_m, h11, fz1 * resolution_m)

			var all_water: bool = w00 >= 0.5 and w10 >= 0.5 and w01 >= 0.5 and w11 >= 0.5
			if all_water:
				water_subquad_count += 1
				water_st.set_normal(Vector3.UP); water_st.add_vertex(v00)
				water_st.set_normal(Vector3.UP); water_st.add_vertex(v10)
				water_st.set_normal(Vector3.UP); water_st.add_vertex(v01)

				water_st.set_normal(Vector3.UP); water_st.add_vertex(v10)
				water_st.set_normal(Vector3.UP); water_st.add_vertex(v11)
				water_st.set_normal(Vector3.UP); water_st.add_vertex(v01)
			else:
				var lx0 := clampi(int(round(fx0)) - sx0, 0, nw - 1)
				var lz0 := clampi(int(round(fz0)) - sz0, 0, nh - 1)
				var lx1 := clampi(int(round(fx1)) - sx0, 0, nw - 1)
				var lz1 := clampi(int(round(fz1)) - sz0, 0, nh - 1)

				var n00 := normal_grid[lz0 * nw + lx0]
				var n10 := normal_grid[lz0 * nw + lx1]
				var n01 := normal_grid[lz1 * nw + lx0]
				var n11 := normal_grid[lz1 * nw + lx1]

				var c00 := SEA_COLOR if w00 >= 0.5 else _vertex_color(h00, max_h, n00, relief_grid[lz0 * nw + lx0], location_id)
				var c10 := SEA_COLOR if w10 >= 0.5 else _vertex_color(h10, max_h, n10, relief_grid[lz0 * nw + lx1], location_id)
				var c01 := SEA_COLOR if w01 >= 0.5 else _vertex_color(h01, max_h, n01, relief_grid[lz1 * nw + lx0], location_id)
				var c11 := SEA_COLOR if w11 >= 0.5 else _vertex_color(h11, max_h, n11, relief_grid[lz1 * nw + lx1], location_id)

				land_st.set_color(c00); land_st.set_normal(n00); land_st.add_vertex(v00)
				land_st.set_color(c10); land_st.set_normal(n10); land_st.add_vertex(v10)
				land_st.set_color(c01); land_st.set_normal(n01); land_st.add_vertex(v01)

				land_st.set_color(c10); land_st.set_normal(n10); land_st.add_vertex(v10)
				land_st.set_color(c11); land_st.set_normal(n11); land_st.add_vertex(v11)
				land_st.set_color(c01); land_st.set_normal(n01); land_st.add_vertex(v01)
	return water_subquad_count

# 1D Catmull-Rom spline segment through 4 control points (p1..p2 is the
# interpolated span, p0/p3 are the neighbors that shape its tangents), t in
# [0, 1].
func _catmull_rom_1d(p0: float, p1: float, p2: float, p3: float, t: float) -> float:
	return 0.5 * (
		2.0 * p1 + (-p0 + p2) * t
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t * t
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t * t * t
	)

# Reconstructs the land/water mask as a continuous field via bicubic
# Catmull-Rom interpolation (separable: 1D spline along x, then along z) of
# the native 0/1 pixel mask, and samples it at fractional pixel coordinates
# (fx, fz). A Catmull-Rom spline passes exactly through the original 0/1
# samples, so thresholding this field at 0.5 reproduces the original
# coastline at the sample points while smoothly (and consistently — the
# spline has a single well-defined value at every point) curving between
# them, rounding what would otherwise be square pixel corners into arcs.
# Clamped to [0, 1] because Catmull-Rom can overshoot slightly past a sharp
# 0->1 step (Gibbs-like ringing) right next to the transition.
func _sample_water_smooth(src_water: PackedByteArray, src_size: int, fx: float, fz: float) -> float:
	var ix := int(floor(fx))
	var iz := int(floor(fz))
	var tx := fx - ix
	var tz := fz - iz
	var col := PackedFloat32Array()
	col.resize(4)
	for j in range(4):
		var zz := clampi(iz - 1 + j, 0, src_size - 1)
		var p := PackedFloat32Array()
		p.resize(4)
		for i in range(4):
			var xx := clampi(ix - 1 + i, 0, src_size - 1)
			p[i] = float(src_water[zz * src_size + xx])
		col[j] = _catmull_rom_1d(p[0], p[1], p[2], p[3], tx)
	return clampf(_catmull_rom_1d(col[0], col[1], col[2], col[3], tz), 0.0, 1.0)

# Bilinear height sample at fractional native-pixel coordinates, used only to
# position coastline sub-mesh vertices smoothly between native DEM pixels
# (shading itself still snaps to the nearest native pixel — see
# _emit_coastline_submesh).
func _sample_height_bilinear(src: PackedFloat32Array, src_size: int, fx: float, fz: float) -> float:
	var ix := clampi(int(floor(fx)), 0, src_size - 1)
	var iz := clampi(int(floor(fz)), 0, src_size - 1)
	var ix1 := mini(ix + 1, src_size - 1)
	var iz1 := mini(iz + 1, src_size - 1)
	var tx := clampf(fx - ix, 0.0, 1.0)
	var tz := clampf(fz - iz, 0.0, 1.0)
	var h00: float = src[iz * src_size + ix]
	var h10: float = src[iz * src_size + ix1]
	var h01: float = src[iz1 * src_size + ix]
	var h11: float = src[iz1 * src_size + ix1]
	return lerp(lerp(h00, h10, tx), lerp(h01, h11, tx), tz)

# Per-vertex normal at native pixel resolution, from a central difference of
# the full-resolution source heights (not the smoothed-normal averaging pass
# used for the downsampled grid, which only covers the coarse grid's
# vertices). Used only for the coastline high-res rebuild above, where the
# affected area is a thin strip, so the shading seam against the coarse
# grid's averaged normals is not noticeable in practice.
func _native_normal(src: PackedFloat32Array, src_size: int, sx: int, sz: int, resolution_m: float) -> Vector3:
	var xm := maxi(sx - 1, 0)
	var xp := mini(sx + 1, src_size - 1)
	var zm := maxi(sz - 1, 0)
	var zp := mini(sz + 1, src_size - 1)
	var dx: float = (src[sz * src_size + xp] - src[sz * src_size + xm]) / ((xp - xm) * resolution_m)
	var dz: float = (src[zp * src_size + sx] - src[zm * src_size + sx]) / ((zp - zm) * resolution_m)
	return Vector3(-dx, 1.0, -dz).normalized()

# Native-resolution counterpart of the downsampled grid's relief pass (see
# _build_mesh): height minus the average of the 4 immediate neighbor pixels.
func _native_relief(src: PackedFloat32Array, src_size: int, sx: int, sz: int) -> float:
	var xm := maxi(sx - 1, 0)
	var xp := mini(sx + 1, src_size - 1)
	var zm := maxi(sz - 1, 0)
	var zp := mini(sz + 1, src_size - 1)
	var avg_neighbor: float = (
		src[sz * src_size + xm] + src[sz * src_size + xp]
		+ src[zm * src_size + sx] + src[zp * src_size + sx]
	) * 0.25
	return src[sz * src_size + sx] - avg_neighbor

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
		if lm["type"] == "golden_gate_bridge":
			# Approach from south of the south tower (Pacific/ocean side of
			# the side span), at deck height, facing along the bridge (north)
			# so the flight path runs straight down the span and through
			# both towers' openings — the low-altitude, near-structure flying
			# this project is built around.
			var geo := _golden_gate_geometry(location_id, lm)
			var approach: Vector3 = geo["south_pos"] - geo["along"] * (SIDE_SPAN_LENGTH + 200.0)
			_spawn_position = approach + Vector3(0.0, GG_DECK_HEIGHT + 40.0, 0.0)
			_spawn_rotation = Vector3(0.0, atan2(geo["along"].x, geo["along"].z) + PI, 0.0)
			return

	# Default: spawn above and south of the highest point, facing -Z (north,
	# toward the peak) — GSI tile rows increase southward, so +Z is south.
	var center_x: float = (dst_size - 1) * cell_m * 0.5
	var center_z: float = (dst_size - 1) * cell_m * 0.5
	var offset_z: float = (dst_size - 1) * cell_m * 0.3
	_spawn_position = Vector3(center_x, max_h + 150.0, center_z + offset_z)
	_spawn_rotation = Vector3.ZERO

# Places decorative/gameplay landmarks (currently just the Otorii and the
# Golden Gate Bridge) that the DEM cannot capture (structures standing in or
# right at the edge of water read as "no data"/near-zero elevation).
func _build_landmarks(location_id: String) -> void:
	var loc: Dictionary = LOCATIONS[location_id]
	for lm in loc.get("landmarks", []):
		match lm["type"]:
			"torii":
				var xz := _latlon_to_local_xz(location_id, lm["lat"], lm["lon"])
				var base_h := _height_at_local_xz(location_id, xz)
				_build_torii(Vector3(xz.x, base_h, xz.y))
			"golden_gate_bridge":
				_build_golden_gate_bridge(location_id, lm)

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

# Golden Gate Bridge, built from primitives (same technique as the Otorii).
# Confirmed real dimensions (Golden Gate Bridge Highway and Transportation
# District official stats, re-verified live in Phase 24-4):
#   tower height above water 227m, main span 1280m, side span 343m (each),
#   main cable diameter 0.92m, suspender spacing 15.2m / diameter 6.8cm,
#   roadway width 19m, clearance above water 67m.
# Tower footprint (leg spacing, leg cross-section) and the tower's internal
# cross-bracing pattern are NOT published anywhere this project found; they
# are proportional estimates (see GG_TOWER_* constants below), same status as
# the Otorii's unpublished support-leg diameter. The cable sag (143m) is
# corroborated only by secondary sources, not the official site itself — see
# 01_requirements.md/02_design.md.
const GG_TOWER_HEIGHT: float = 227.0        # official, above water (this stage's Y=0)
const GG_MAIN_SPAN_OFFICIAL: float = 1280.0 # official; actual geometry uses the real tower-to-tower distance instead (see _golden_gate_geometry)
const SIDE_SPAN_LENGTH: float = 343.0       # official, each side
const GG_DECK_HEIGHT: float = 67.0          # official clearance above water; the deck is simplified as flat at this height along its full length
const GG_DECK_WIDTH: float = 19.0           # official, curb-to-curb (sidewalks not separately modeled)
const GG_DECK_THICKNESS: float = 3.0        # not an official figure; a reasonable visual thickness for the deck box
const GG_MAIN_CABLE_DIAMETER: float = 0.92  # official
const GG_MAIN_CABLE_SAG: float = 143.0      # secondary-source figure only, not corroborated against a primary source — see 02_design.md
const GG_MAIN_CABLE_SEGMENTS: int = 32      # parabola smoothness vs. mesh count tradeoff
const GG_SUSPENDER_SPACING: float = 15.2    # official (50ft)
const GG_SUSPENDER_DIAMETER: float = 0.068  # official (2-11/16in)
const GG_TOWER_LEG_ACROSS: float = 27.0     # estimate: not published; roadway width (19m) + sidewalks, with the cables sitting just outside them
const GG_TOWER_LEG_ALONG: float = 9.0       # estimate: not published; suspension towers are typically slimmer along the direction of travel than across it
const GG_TOWER_LEG_SIZE: float = 3.0        # estimate: leg cross-section (square)
const GG_TOWER_BRACE_LEVELS: int = 6        # simplified lattice (evenly spaced rings), not the real tower's finer diagonal cross-bracing
const GG_TOWER_BRACE_THICKNESS: float = 1.0 # estimate

# Shared geometry for both landmark building (_build_golden_gate_bridge) and
# spawn placement (_compute_spawn): tower positions (base height sampled from
# the DEM, same convention as the Otorii — see the note on _is_water in
# 02_design.md about why these come out near sea level for this stage) and
# the bridge's actual bearing, derived from the two tower positions rather
# than assumed, so geometry stays self-consistent even though the north
# tower's coordinates were themselves derived (see 02_design.md/03_plan.md
# Phase 24-4) — the real computed span_len is used for the cable parabola,
# not GG_MAIN_SPAN_OFFICIAL, so there's no seam between "official" and
# "measured" numbers.
func _golden_gate_geometry(location_id: String, lm: Dictionary) -> Dictionary:
	var s_ll: Dictionary = lm["south_tower"]
	var n_ll: Dictionary = lm["north_tower"]
	var s_xz := _latlon_to_local_xz(location_id, s_ll["lat"], s_ll["lon"])
	var n_xz := _latlon_to_local_xz(location_id, n_ll["lat"], n_ll["lon"])
	var south_pos := Vector3(s_xz.x, _height_at_local_xz(location_id, s_xz), s_xz.y)
	var north_pos := Vector3(n_xz.x, _height_at_local_xz(location_id, n_xz), n_xz.y)
	var delta := north_pos - south_pos
	var span_len: float = Vector2(delta.x, delta.z).length()
	var along := Vector3(delta.x, 0.0, delta.z).normalized()
	var across := Vector3(-along.z, 0.0, along.x)
	return {
		"south_pos": south_pos, "north_pos": north_pos,
		"along": along, "across": across, "span_len": span_len,
	}

func _build_golden_gate_bridge(location_id: String, lm: Dictionary) -> void:
	var geo := _golden_gate_geometry(location_id, lm)
	var south_pos: Vector3 = geo["south_pos"]
	var north_pos: Vector3 = geo["north_pos"]
	var along: Vector3 = geo["along"]
	var across: Vector3 = geo["across"]
	var span_len: float = geo["span_len"]

	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.72, 0.30, 0.13)  # International Orange
	steel.roughness = 0.6
	steel.metallic = 0.3

	var root := StaticBody3D.new()

	_build_gg_tower(root, south_pos, GG_TOWER_HEIGHT, along, across, steel)
	_build_gg_tower(root, north_pos, GG_TOWER_HEIGHT, along, across, steel)

	# Two main cables, one on each side of the deck, each with its own
	# suspenders and simplified side-span cable.
	for side: float in [-1.0, 1.0]:
		var offset: Vector3 = across * (GG_TOWER_LEG_ACROSS * 0.5 * side)
		var s_pt: Vector3 = south_pos + offset
		var n_pt: Vector3 = north_pos + offset
		_build_gg_main_cable(root, s_pt, span_len, along, steel)
		_build_gg_side_span_cable(root, s_pt, -along, steel)
		_build_gg_side_span_cable(root, n_pt, along, steel)
		_build_gg_suspenders(root, s_pt, span_len, along, steel)

	_build_gg_deck(root, south_pos, north_pos, along, across, steel)

	_static_body.add_child(root)

# One tower: 4 vertical legs at the real footprint estimate (see GG_TOWER_*
# above), plus evenly-spaced horizontal bracing rings with open gaps between
# them so near-structure flying can pass through the tower rather than into
# a solid block. Collision is legs-only (same simplification as the Otorii's
# pillars) — the bracing is visual only, matching the Otorii's tie-beams.
func _build_gg_tower(root: Node3D, base_pos: Vector3, top_y: float, along: Vector3, across: Vector3, material: Material) -> void:
	var half_along := along * (GG_TOWER_LEG_ALONG * 0.5)
	var half_across := across * (GG_TOWER_LEG_ACROSS * 0.5)
	# [along-, across-], [along-, across+], [along+, across-], [along+, across+]
	var corners: Array[Vector3] = [
		base_pos - half_along - half_across,
		base_pos - half_along + half_across,
		base_pos + half_along - half_across,
		base_pos + half_along + half_across,
	]

	for c in corners:
		var bottom := Vector3(c.x, base_pos.y, c.z)
		var top := Vector3(c.x, top_y, c.z)
		_add_beam_segment(root, bottom, top, GG_TOWER_LEG_SIZE, material)
		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(GG_TOWER_LEG_SIZE, top_y - base_pos.y, GG_TOWER_LEG_SIZE)
		col.shape = box
		col.position = (bottom + top) * 0.5
		root.add_child(col)

	for i in range(1, GG_TOWER_BRACE_LEVELS):
		var t := float(i) / float(GG_TOWER_BRACE_LEVELS)
		var brace_y: float = lerp(base_pos.y, top_y, t)
		var mm := Vector3(corners[0].x, brace_y, corners[0].z)
		var mp := Vector3(corners[1].x, brace_y, corners[1].z)
		var pm := Vector3(corners[2].x, brace_y, corners[2].z)
		var pp := Vector3(corners[3].x, brace_y, corners[3].z)
		_add_beam_segment(root, mm, mp, GG_TOWER_BRACE_THICKNESS, material)  # across-beam, along-
		_add_beam_segment(root, pm, pp, GG_TOWER_BRACE_THICKNESS, material)  # across-beam, along+
		_add_beam_segment(root, mm, pm, GG_TOWER_BRACE_THICKNESS, material)  # along-beam, across-
		_add_beam_segment(root, mp, pp, GG_TOWER_BRACE_THICKNESS, material)  # along-beam, across+

# Main-span cable: a parabola (y = tower_top - 4*sag*t*(1-t), t in [0,1]),
# the real shape a suspension cable takes under the deck's approximately
# uniform load, approximated as GG_MAIN_CABLE_SEGMENTS straight cylinder
# segments. `s_pt` is the south tower attachment point (already offset to
# this cable's side of the deck by the caller); the curve is walked toward
# the north tower along `along`.
func _build_gg_main_cable(root: Node3D, s_pt: Vector3, span_len: float, along: Vector3, material: Material) -> void:
	var prev := Vector3(s_pt.x, GG_TOWER_HEIGHT, s_pt.z)
	for i in range(1, GG_MAIN_CABLE_SEGMENTS + 1):
		var t := float(i) / float(GG_MAIN_CABLE_SEGMENTS)
		var p := s_pt + along * (span_len * t)
		p.y = GG_TOWER_HEIGHT - 4.0 * GG_MAIN_CABLE_SAG * t * (1.0 - t)
		_add_cylinder_segment(root, prev, p, GG_MAIN_CABLE_DIAMETER * 0.5, material)
		prev = p

# Side-span cable: simplified as a single straight segment from the tower
# top down to sea level over SIDE_SPAN_LENGTH in the given direction (away
# from the main span). The real side-span cable is a shallower catenary
# ending at an anchorage well above sea level, but this project doesn't have
# anchorage coordinates/height, so this is a deliberate simplification (see
# 02_design.md "Phase B") rather than a researched shape.
func _build_gg_side_span_cable(root: Node3D, tower_pt: Vector3, dir: Vector3, material: Material) -> void:
	var top := Vector3(tower_pt.x, GG_TOWER_HEIGHT, tower_pt.z)
	var far := tower_pt + dir * SIDE_SPAN_LENGTH
	var bottom := Vector3(far.x, 0.0, far.z)
	_add_cylinder_segment(root, top, bottom, GG_MAIN_CABLE_DIAMETER * 0.5, material)

# Vertical suspenders from the main cable down to the deck, at the real
# spacing (GG_SUSPENDER_SPACING), across the main span only (side-span
# suspenders are omitted for now — see 02_design.md "Phase B" known gaps).
func _build_gg_suspenders(root: Node3D, s_pt: Vector3, span_len: float, along: Vector3, material: Material) -> void:
	var count := int(span_len / GG_SUSPENDER_SPACING)
	for i in range(1, count):
		var x: float = i * GG_SUSPENDER_SPACING
		var t := x / span_len
		var cable_y := GG_TOWER_HEIGHT - 4.0 * GG_MAIN_CABLE_SAG * t * (1.0 - t)
		var p := s_pt + along * x
		_add_cylinder_segment(
			root, Vector3(p.x, cable_y, p.z), Vector3(p.x, GG_DECK_HEIGHT, p.z),
			GG_SUSPENDER_DIAMETER * 0.5, material
		)

# Deck: a single flat box across the main span plus both side spans (real
# roadway width, simplified constant thickness/height — see GG_DECK_* above).
func _build_gg_deck(root: Node3D, south_pos: Vector3, north_pos: Vector3, along: Vector3, across: Vector3, material: Material) -> void:
	var start := south_pos - along * SIDE_SPAN_LENGTH
	var end := north_pos + along * SIDE_SPAN_LENGTH
	var total_len: float = Vector2(end.x - start.x, end.z - start.z).length()
	var center := (start + end) * 0.5
	center.y = GG_DECK_HEIGHT

	var mesh_inst := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(GG_DECK_WIDTH, GG_DECK_THICKNESS, total_len)
	mesh_inst.mesh = mesh
	mesh_inst.material_override = material
	var deck_transform := Transform3D(Basis(across, Vector3.UP, along), center)
	mesh_inst.transform = deck_transform
	root.add_child(mesh_inst)

	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = mesh.size
	col.shape = box
	col.transform = deck_transform
	root.add_child(col)

# Builds a straight box "beam" between two points with the given square
# cross-section thickness, oriented so its long axis (local Z, matching
# BoxMesh.size.z) points from a to b. Used for the tower's legs and
# horizontal bracing.
func _add_beam_segment(root: Node3D, a: Vector3, b: Vector3, thickness: float, material: Material) -> void:
	var diff := b - a
	var length := diff.length()
	if length < 0.001:
		return
	var mesh_inst := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(thickness, thickness, length)
	mesh_inst.mesh = mesh
	mesh_inst.material_override = material
	var z_axis := diff / length
	var helper := Vector3.RIGHT if absf(z_axis.dot(Vector3.UP)) > 0.99 else Vector3.UP
	var x_axis := helper.cross(z_axis).normalized()
	var y_axis := z_axis.cross(x_axis).normalized()
	mesh_inst.transform = Transform3D(Basis(x_axis, y_axis, z_axis), (a + b) * 0.5)
	root.add_child(mesh_inst)

# Builds a cylinder "cable" segment between two points, oriented so its
# height axis (local Y, CylinderMesh's default) points from a to b. Used for
# the main cables, side-span cables, and suspenders.
func _add_cylinder_segment(root: Node3D, a: Vector3, b: Vector3, radius: float, material: Material) -> void:
	var diff := b - a
	var length := diff.length()
	if length < 0.001:
		return
	var mesh_inst := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = length
	mesh_inst.mesh = mesh
	mesh_inst.material_override = material
	var y_axis := diff / length
	var helper := Vector3.RIGHT if absf(y_axis.dot(Vector3.UP)) > 0.99 else Vector3.UP
	var x_axis := helper.cross(y_axis).normalized()
	var z_axis := x_axis.cross(y_axis).normalized()
	mesh_inst.transform = Transform3D(Basis(x_axis, y_axis, z_axis), (a + b) * 0.5)
	root.add_child(mesh_inst)
