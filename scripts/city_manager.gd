extends Node3D

const CHUNK_SIZE: float = 120.0
const SLOT_SIZE: float = 30.0
const SLOTS_PER_CHUNK: int = 4  # 4x4 slots per chunk
const RENDER_DISTANCE: int = 3
const CHUNKS_PER_FRAME: int = 2

var _active_chunks: Dictionary = {}
var _player: Node3D
var _pending_chunks: Array[Vector2i] = []
var _enabled: bool = false

# Shared materials
var _mat_grey: StandardMaterial3D
var _mat_beige: StandardMaterial3D
var _mat_dark: StandardMaterial3D
var _mat_brown: StandardMaterial3D
var _mat_light: StandardMaterial3D

func _ready() -> void:
	_mat_grey = _make_mat(Color(0.55, 0.57, 0.60))
	_mat_beige = _make_mat(Color(0.75, 0.70, 0.58))
	_mat_dark = _make_mat(Color(0.20, 0.25, 0.32), 0.6, 0.1)   # dark glass
	_mat_brown = _make_mat(Color(0.52, 0.42, 0.32))
	_mat_light = _make_mat(Color(0.82, 0.83, 0.85))

func _make_mat(color: Color, roughness: float = 0.7, metallic: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	return m

func activate(player: Node3D) -> void:
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

	_pending_chunks.clear()
	for x in range(player_chunk.x - RENDER_DISTANCE, player_chunk.x + RENDER_DISTANCE + 1):
		for z in range(player_chunk.y - RENDER_DISTANCE, player_chunk.y + RENDER_DISTANCE + 1):
			var key := Vector2i(x, z)
			if not _active_chunks.has(key):
				_pending_chunks.append(key)

	_pending_chunks.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da := (a - player_chunk).length_squared()
		var db := (b - player_chunk).length_squared()
		return da < db
	)

	var created := 0
	for key in _pending_chunks:
		if created >= CHUNKS_PER_FRAME:
			break
		_create_chunk(key)
		created += 1

	var to_remove: Array[Vector2i] = []
	for key in _active_chunks:
		if abs(key.x - player_chunk.x) > RENDER_DISTANCE + 1 or abs(key.y - player_chunk.y) > RENDER_DISTANCE + 1:
			to_remove.append(key)
	for key in to_remove:
		_active_chunks[key].queue_free()
		_active_chunks.erase(key)

func _create_chunk(coord: Vector2i) -> void:
	var chunk := Node3D.new()
	chunk.position = Vector3(coord.x * CHUNK_SIZE, 0.0, coord.y * CHUNK_SIZE)

	var rng := RandomNumberGenerator.new()
	rng.seed = hash(coord)

	var materials := [_mat_grey, _mat_beige, _mat_dark, _mat_brown, _mat_light]

	for sx in range(SLOTS_PER_CHUNK):
		for sz in range(SLOTS_PER_CHUNK):
			var slot_x := sx * SLOT_SIZE
			var slot_z := sz * SLOT_SIZE

			var bw := rng.randf_range(15.0, 22.0)
			var bd := rng.randf_range(15.0, 22.0)
			var bh := rng.randf_range(15.0, 100.0)
			var mat: StandardMaterial3D = materials[rng.randi() % materials.size()]

			var cx := slot_x + SLOT_SIZE * 0.5
			var cz := slot_z + SLOT_SIZE * 0.5

			var body := StaticBody3D.new()
			body.position = Vector3(cx, bh * 0.5, cz)

			var mi := MeshInstance3D.new()
			var mesh := BoxMesh.new()
			mesh.size = Vector3(bw, bh, bd)
			mi.mesh = mesh
			mi.material_override = mat
			body.add_child(mi)

			var col := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = Vector3(bw, bh, bd)
			col.shape = shape
			body.add_child(col)

			# Aviation warning light on top
			var light_mi := MeshInstance3D.new()
			var light_mesh := SphereMesh.new()
			light_mesh.radius = 0.4
			light_mesh.height = 0.8
			light_mi.mesh = light_mesh
			var light_mat := StandardMaterial3D.new()
			light_mat.albedo_color = Color(1.0, 0.2, 0.1)
			light_mat.emission_enabled = true
			light_mat.emission = Color(1.0, 0.1, 0.0)
			light_mat.emission_energy_multiplier = 3.0
			light_mi.material_override = light_mat
			light_mi.position = Vector3(0.0, bh * 0.5 + 0.5, 0.0)
			body.add_child(light_mi)

			chunk.add_child(body)

	# Ground plane for this chunk
	var ground := StaticBody3D.new()
	var gmi := MeshInstance3D.new()
	var gmesh := BoxMesh.new()
	gmesh.size = Vector3(CHUNK_SIZE, 0.5, CHUNK_SIZE)
	gmi.mesh = gmesh
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.18, 0.18, 0.20)
	gmi.material_override = gmat
	ground.add_child(gmi)
	var gcol := CollisionShape3D.new()
	var gshape := BoxShape3D.new()
	gshape.size = Vector3(CHUNK_SIZE, 0.5, CHUNK_SIZE)
	gcol.shape = gshape
	ground.add_child(gcol)
	ground.position = Vector3(CHUNK_SIZE * 0.5, -0.25, CHUNK_SIZE * 0.5)
	chunk.add_child(ground)

	add_child(chunk)
	_active_chunks[coord] = chunk
