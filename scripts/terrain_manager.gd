extends Node3D

const CHUNK_SIZE: float = 64.0

# Quality presets: [render_distance, mesh_resolution, chunks_per_frame]
const QUALITY_PRESETS: Dictionary = {
	"low": [2, 16, 1],
	"mid": [3, 24, 2],
	"high": [4, 32, 2],
}
const AUTO_RENDER_MIN: int = 2
const AUTO_RENDER_MAX: int = 4
const AUTO_FPS_LOW: float = 30.0
const AUTO_FPS_HIGH: float = 50.0
const AUTO_FPS_WINDOW: float = 3.0  # seconds to average

var render_distance: int = 4
var mesh_resolution: int = 32
var chunks_per_frame: int = 2
var quality_mode: String = "auto"

# FPS tracking for auto mode
var _fps_samples: Array[float] = []
var _fps_timer: float = 0.0

var _noise: FastNoiseLite
var _biome_noise: FastNoiseLite
var _active_chunks: Dictionary = {}  # Vector2i -> Node3D
var _player: Node3D
var _pending_chunks: Array[Vector2i] = []
var _shared_material: StandardMaterial3D
var _enabled: bool = false

func _ready() -> void:
	# Primary terrain noise
	_noise = FastNoiseLite.new()
	_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	_noise.seed = randi()
	_noise.frequency = 0.015
	_noise.fractal_octaves = 5

	# Biome noise (larger scale)
	_biome_noise = FastNoiseLite.new()
	_biome_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	_biome_noise.seed = randi()
	_biome_noise.frequency = 0.003

	# Shared material for all chunks
	_shared_material = StandardMaterial3D.new()
	_shared_material.vertex_color_use_as_albedo = true

func setup(player: Node3D) -> void:
	_player = player
	_enabled = true

func set_quality(mode: String) -> void:
	quality_mode = mode
	_fps_samples.clear()
	_fps_timer = 0.0
	if mode in QUALITY_PRESETS:
		var preset: Array = QUALITY_PRESETS[mode]
		var new_resolution: int = preset[1]
		var need_rebuild: bool = (new_resolution != mesh_resolution)
		render_distance = preset[0]
		mesh_resolution = new_resolution
		chunks_per_frame = preset[2]
		if need_rebuild and _enabled:
			_rebuild_all_chunks()
	elif mode == "auto":
		mesh_resolution = 32
		chunks_per_frame = 2
		# render_distance stays current, will be adjusted by fps

func _rebuild_all_chunks() -> void:
	var keys: Array = _active_chunks.keys().duplicate()
	for key in keys:
		_active_chunks[key].queue_free()
		_active_chunks.erase(key)

func _update_auto_quality(delta: float) -> void:
	if quality_mode != "auto" or not _enabled:
		return
	_fps_timer += delta
	_fps_samples.append(Engine.get_frames_per_second())
	if _fps_timer < AUTO_FPS_WINDOW:
		return
	# Calculate average fps
	var total: float = 0.0
	for s in _fps_samples:
		total += s
	var avg_fps: float = total / _fps_samples.size()
	_fps_samples.clear()
	_fps_timer = 0.0
	if avg_fps < AUTO_FPS_LOW and render_distance > AUTO_RENDER_MIN:
		render_distance -= 1
	elif avg_fps > AUTO_FPS_HIGH and render_distance < AUTO_RENDER_MAX:
		render_distance += 1

func deactivate() -> void:
	_enabled = false
	_player = null
	for key in _active_chunks:
		_active_chunks[key].queue_free()
	_active_chunks.clear()
	_pending_chunks.clear()

func _process(delta: float) -> void:
	if not _enabled or not _player:
		return

	_update_auto_quality(delta)

	var player_chunk := Vector2i(
		floori(_player.global_position.x / CHUNK_SIZE),
		floori(_player.global_position.z / CHUNK_SIZE)
	)

	# Queue missing chunks (sorted by distance to player)
	_pending_chunks.clear()
	for x in range(player_chunk.x - render_distance, player_chunk.x + render_distance + 1):
		for z in range(player_chunk.y - render_distance, player_chunk.y + render_distance + 1):
			var key := Vector2i(x, z)
			if not _active_chunks.has(key):
				_pending_chunks.append(key)

	# Sort by distance to player chunk (prioritize nearest)
	_pending_chunks.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da := (a - player_chunk).length_squared()
		var db := (b - player_chunk).length_squared()
		return da < db
	)

	# Generate only a few chunks per frame
	var created := 0
	for key in _pending_chunks:
		if created >= chunks_per_frame:
			break
		_create_chunk(key)
		created += 1

	# Remove chunks out of range
	var to_remove: Array[Vector2i] = []
	for key in _active_chunks:
		if abs(key.x - player_chunk.x) > render_distance + 1 or abs(key.y - player_chunk.y) > render_distance + 1:
			to_remove.append(key)

	for key in to_remove:
		_active_chunks[key].queue_free()
		_active_chunks.erase(key)

func _create_chunk(coord: Vector2i) -> void:
	var chunk := StaticBody3D.new()
	chunk.position = Vector3(coord.x * CHUNK_SIZE, 0, coord.y * CHUNK_SIZE)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var step := CHUNK_SIZE / mesh_resolution
	var heights := PackedFloat32Array()
	heights.resize((mesh_resolution + 1) * (mesh_resolution + 1))

	# Pre-compute per-vertex colors
	var vert_count := (mesh_resolution + 1) * (mesh_resolution + 1)
	var colors := PackedColorArray()
	colors.resize(vert_count)

	# Calculate heights and colors per vertex
	for z in range(mesh_resolution + 1):
		for x in range(mesh_resolution + 1):
			var world_x := coord.x * CHUNK_SIZE + x * step
			var world_z := coord.y * CHUNK_SIZE + z * step

			var biome_val := _biome_noise.get_noise_2d(world_x, world_z)
			var h := _noise.get_noise_2d(world_x, world_z)

			if biome_val < -0.2:
				h = h * 25.0 - 8.0
			elif biome_val > 0.2:
				h = h * 80.0 + 15.0
			else:
				h = h * 40.0

			var idx := z * (mesh_resolution + 1) + x
			heights[idx] = h

			# Per-vertex biome color with smooth blending
			var canyon_color := Color(0.9, 0.5, 0.15).lerp(
				Color(0.7, 0.2, 0.1), clamp(-h / 10.0, 0.0, 1.0))
			var mountain_color := Color(0.4, 0.3, 0.7).lerp(
				Color(0.9, 0.9, 1.0), clamp((h - 30.0) / 40.0, 0.0, 0.6))
			var normal_color := Color(0.0, 0.3, 0.05).lerp(
				Color(0.4, 0.85, 0.15), clamp(h / 25.0, 0.0, 1.0))

			var color: Color
			if biome_val < -0.3:
				color = canyon_color
			elif biome_val < -0.1:
				# Canyon-to-normal transition
				var t := (biome_val - (-0.3)) / 0.2
				color = canyon_color.lerp(normal_color, t)
			elif biome_val < 0.1:
				color = normal_color
			elif biome_val < 0.3:
				# Normal-to-mountain transition
				var t := (biome_val - 0.1) / 0.2
				color = normal_color.lerp(mountain_color, t)
			else:
				color = mountain_color

			# High altitude snow caps
			if h > 50.0:
				color = color.lerp(Color(1.0, 1.0, 1.0), clamp((h - 50.0) / 25.0, 0.0, 0.7))

			colors[idx] = color

	# Generate triangles
	for z in range(mesh_resolution):
		for x in range(mesh_resolution):
			var idx00 := z * (mesh_resolution + 1) + x
			var idx10 := idx00 + 1
			var idx01 := idx00 + (mesh_resolution + 1)
			var idx11 := idx01 + 1

			var x0 := x * step
			var z0 := z * step
			var x1 := x0 + step
			var z1 := z0 + step

			var h00 := heights[idx00]
			var h10 := heights[idx10]
			var h01 := heights[idx01]
			var h11 := heights[idx11]

			var v00 := Vector3(x0, h00, z0)
			var v10 := Vector3(x1, h10, z0)
			var v01 := Vector3(x0, h01, z1)
			var v11 := Vector3(x1, h11, z1)

			var c00 := colors[idx00]
			var c10 := colors[idx10]
			var c01 := colors[idx01]
			var c11 := colors[idx11]

			# Triangle 1
			var n1 := (v10 - v00).cross(v01 - v00).normalized()
			st.set_color(c00)
			st.set_normal(n1)
			st.add_vertex(v00)
			st.set_color(c10)
			st.set_normal(n1)
			st.add_vertex(v10)
			st.set_color(c01)
			st.set_normal(n1)
			st.add_vertex(v01)

			# Triangle 2
			var n2 := (v01 - v11).cross(v10 - v11).normalized()
			st.set_color(c10)
			st.set_normal(n2)
			st.add_vertex(v10)
			st.set_color(c11)
			st.set_normal(n2)
			st.add_vertex(v11)
			st.set_color(c01)
			st.set_normal(n2)
			st.add_vertex(v01)

	var mesh := st.commit()

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh
	mesh_instance.material_override = _shared_material
	chunk.add_child(mesh_instance)

	# Collision using HeightMapShape3D
	var col_shape := CollisionShape3D.new()
	var hmap := HeightMapShape3D.new()
	var map_size := mesh_resolution + 1
	hmap.map_width = map_size
	hmap.map_depth = map_size
	hmap.map_data = heights
	col_shape.shape = hmap
	# HeightMapShape3D is centered, so offset to match mesh
	col_shape.position = Vector3(CHUNK_SIZE * 0.5, 0, CHUNK_SIZE * 0.5)
	col_shape.scale = Vector3(step, 1.0, step)
	chunk.add_child(col_shape)

	add_child(chunk)
	_active_chunks[coord] = chunk
