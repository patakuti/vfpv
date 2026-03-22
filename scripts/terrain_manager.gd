extends Node3D

const CHUNK_SIZE: float = 64.0
const RENDER_DISTANCE: int = 4
const MESH_RESOLUTION: int = 32  # vertices per side
const CHUNKS_PER_FRAME: int = 2  # max chunks to generate per frame

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

func deactivate() -> void:
	_enabled = false
	_player = null
	for key in _active_chunks:
		_active_chunks[key].queue_free()
	_active_chunks.clear()
	_pending_chunks.clear()

func _process(_delta: float) -> void:
	if not _enabled or not _player:
		return

	var player_chunk := Vector2i(
		floori(_player.global_position.x / CHUNK_SIZE),
		floori(_player.global_position.z / CHUNK_SIZE)
	)

	# Queue missing chunks (sorted by distance to player)
	_pending_chunks.clear()
	for x in range(player_chunk.x - RENDER_DISTANCE, player_chunk.x + RENDER_DISTANCE + 1):
		for z in range(player_chunk.y - RENDER_DISTANCE, player_chunk.y + RENDER_DISTANCE + 1):
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
		if created >= CHUNKS_PER_FRAME:
			break
		_create_chunk(key)
		created += 1

	# Remove chunks out of range
	var to_remove: Array[Vector2i] = []
	for key in _active_chunks:
		if abs(key.x - player_chunk.x) > RENDER_DISTANCE + 1 or abs(key.y - player_chunk.y) > RENDER_DISTANCE + 1:
			to_remove.append(key)

	for key in to_remove:
		_active_chunks[key].queue_free()
		_active_chunks.erase(key)

func _create_chunk(coord: Vector2i) -> void:
	var chunk := StaticBody3D.new()
	chunk.position = Vector3(coord.x * CHUNK_SIZE, 0, coord.y * CHUNK_SIZE)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var step := CHUNK_SIZE / MESH_RESOLUTION
	var heights := PackedFloat32Array()
	heights.resize((MESH_RESOLUTION + 1) * (MESH_RESOLUTION + 1))

	# Pre-compute per-vertex colors
	var vert_count := (MESH_RESOLUTION + 1) * (MESH_RESOLUTION + 1)
	var colors := PackedColorArray()
	colors.resize(vert_count)

	# Calculate heights and colors per vertex
	for z in range(MESH_RESOLUTION + 1):
		for x in range(MESH_RESOLUTION + 1):
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

			var idx := z * (MESH_RESOLUTION + 1) + x
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
	for z in range(MESH_RESOLUTION):
		for x in range(MESH_RESOLUTION):
			var idx00 := z * (MESH_RESOLUTION + 1) + x
			var idx10 := idx00 + 1
			var idx01 := idx00 + (MESH_RESOLUTION + 1)
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
	var map_size := MESH_RESOLUTION + 1
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
