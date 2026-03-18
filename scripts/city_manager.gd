extends Node3D

const CHUNK_SIZE: float = 132.0   # 3 slots × 44m
const SLOT_SIZE: float = 44.0
const SLOTS_PER_CHUNK: int = 3
const RENDER_DISTANCE: int = 3
const CHUNKS_PER_FRAME: int = 2
const EMPTY_LOT_CHANCE: float = 0.30

var _active_chunks: Dictionary = {}
var _player: Node3D
var _pending_chunks: Array[Vector2i] = []
var _enabled: bool = false

var _mats_facade: Array[StandardMaterial3D] = []
var _mat_glass: StandardMaterial3D
var _mat_concrete: StandardMaterial3D
var _mat_window: StandardMaterial3D
var _mat_ground: StandardMaterial3D

func _ready() -> void:
	_mats_facade = [
		_make_mat(Color(0.55, 0.57, 0.60)),
		_make_mat(Color(0.75, 0.70, 0.58)),
		_make_mat(Color(0.52, 0.42, 0.32)),
		_make_mat(Color(0.82, 0.83, 0.85)),
		_make_mat(Color(0.38, 0.36, 0.33)),
	]
	_mat_glass = _make_mat(Color(0.22, 0.32, 0.42), 0.1, 0.8)
	_mat_concrete = _make_mat(Color(0.28, 0.28, 0.30))
	_mat_window = _make_emission_mat(Color(1.0, 0.92, 0.65), Color(0.9, 0.80, 0.4), 1.2)
	_mat_ground = _make_mat(Color(0.16, 0.16, 0.18))

func _make_mat(color: Color, roughness: float = 0.75, metallic: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	return m

func _make_emission_mat(albedo: Color, emission: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.emission_enabled = true
	m.emission = emission
	m.emission_energy_multiplier = energy
	return m

# Add one visual+collision piece to a parent node (local coords)
func _add_piece(parent: Node3D, size: Vector3, local_pos: Vector3, mat: StandardMaterial3D, with_collision: bool = true) -> void:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = local_pos
	parent.add_child(mi)
	if with_collision:
		var col := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		col.shape = shape
		col.position = local_pos
		parent.add_child(col)

func _add_aviation_light(parent: Node3D, top_y: float) -> void:
	var mi := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.4
	mesh.height = 0.8
	mi.mesh = mesh
	mi.material_override = _make_emission_mat(Color(1.0, 0.2, 0.1), Color(1.0, 0.05, 0.0), 3.0)
	mi.position = Vector3(0.0, top_y + 0.5, 0.0)
	parent.add_child(mi)

func _add_window_strips(parent: Node3D, bw: float, bh: float, bd: float, base_y: float) -> void:
	var y := base_y + 7.0
	while y < base_y + bh - 5.0:
		var mi := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(bw + 0.06, 0.7, bd + 0.06)
		mi.mesh = mesh
		mi.material_override = _mat_window
		mi.position = Vector3(0.0, y, 0.0)
		parent.add_child(mi)
		y += 9.0

# ── Building types ──────────────────────────────────────────

func _place_basic(body: StaticBody3D, rng: RandomNumberGenerator) -> Dictionary:
	var bw := rng.randf_range(14.0, 24.0)
	var bd := rng.randf_range(14.0, 24.0)
	var bh := rng.randf_range(20.0, 80.0)
	var mat: StandardMaterial3D = _mats_facade[rng.randi() % _mats_facade.size()]
	_add_piece(body, Vector3(bw, bh, bd), Vector3(0.0, bh * 0.5, 0.0), mat)
	_add_window_strips(body, bw, bh, bd, 0.0)
	_add_aviation_light(body, bh)
	return {height = bh, width = bw, depth = bd}

func _place_tower(body: StaticBody3D, rng: RandomNumberGenerator) -> Dictionary:
	var bw := rng.randf_range(8.0, 14.0)
	var bd := rng.randf_range(8.0, 14.0)
	var bh := rng.randf_range(70.0, 120.0)
	var mat: StandardMaterial3D = _mat_glass if rng.randf() < 0.5 else _mats_facade[rng.randi() % _mats_facade.size()]
	_add_piece(body, Vector3(bw, bh, bd), Vector3(0.0, bh * 0.5, 0.0), mat)
	_add_window_strips(body, bw, bh, bd, 0.0)
	_add_aviation_light(body, bh)
	return {height = bh, width = bw, depth = bd}

func _place_stepped(body: StaticBody3D, rng: RandomNumberGenerator) -> Dictionary:
	var bw := rng.randf_range(18.0, 28.0)
	var bd := rng.randf_range(18.0, 28.0)
	var bh := rng.randf_range(40.0, 90.0)
	var split := rng.randf_range(0.4, 0.6)
	var base_h := bh * split
	var top_h := bh - base_h
	var top_w := bw * rng.randf_range(0.45, 0.65)
	var top_d := bd * rng.randf_range(0.45, 0.65)
	var mat1: StandardMaterial3D = _mats_facade[rng.randi() % _mats_facade.size()]
	var mat2: StandardMaterial3D = _mats_facade[rng.randi() % _mats_facade.size()]
	_add_piece(body, Vector3(bw, base_h, bd), Vector3(0.0, base_h * 0.5, 0.0), mat1)
	_add_piece(body, Vector3(top_w, top_h, top_d), Vector3(0.0, base_h + top_h * 0.5, 0.0), mat2)
	_add_window_strips(body, bw, base_h, bd, 0.0)
	_add_window_strips(body, top_w, top_h, top_d, base_h)
	_add_aviation_light(body, bh)
	return {height = bh, width = bw, depth = bd}

func _place_arch(body: StaticBody3D, rng: RandomNumberGenerator) -> Dictionary:
	var bw := rng.randf_range(24.0, 34.0)
	var bd := rng.randf_range(16.0, 24.0)
	var bh := rng.randf_range(65.0, 105.0)
	var mat: StandardMaterial3D = _mats_facade[rng.randi() % _mats_facade.size()]

	var tunnel_w := bw * rng.randf_range(0.40, 0.55)  # width of the hole
	var tunnel_h := rng.randf_range(18.0, 24.0)       # height of the hole
	var tunnel_y := rng.randf_range(16.0, 30.0)       # starts at this height from ground
	var wall_w := (bw - tunnel_w) * 0.5
	var top_h := bh - tunnel_y - tunnel_h

	# Bottom solid
	_add_piece(body, Vector3(bw, tunnel_y, bd), Vector3(0.0, tunnel_y * 0.5, 0.0), mat)
	# Left wall beside hole
	_add_piece(body, Vector3(wall_w, tunnel_h, bd),
		Vector3(-(tunnel_w + wall_w) * 0.5, tunnel_y + tunnel_h * 0.5, 0.0), mat)
	# Right wall beside hole
	_add_piece(body, Vector3(wall_w, tunnel_h, bd),
		Vector3((tunnel_w + wall_w) * 0.5, tunnel_y + tunnel_h * 0.5, 0.0), mat)
	# Top cap
	_add_piece(body, Vector3(bw, top_h, bd),
		Vector3(0.0, tunnel_y + tunnel_h + top_h * 0.5, 0.0), mat)

	_add_window_strips(body, bw, tunnel_y, bd, 0.0)
	_add_window_strips(body, bw, top_h, bd, tunnel_y + tunnel_h)
	_add_aviation_light(body, bh)
	return {height = bh, width = bw, depth = bd}

func _place_low_wide(body: StaticBody3D, rng: RandomNumberGenerator) -> Dictionary:
	var bw := rng.randf_range(22.0, 36.0)
	var bd := rng.randf_range(22.0, 36.0)
	var bh := rng.randf_range(8.0, 20.0)
	var mat: StandardMaterial3D = _mats_facade[rng.randi() % _mats_facade.size()]
	_add_piece(body, Vector3(bw, bh, bd), Vector3(0.0, bh * 0.5, 0.0), mat)
	return {height = bh, width = bw, depth = bd}

# ── Bridge ───────────────────────────────────────────────────

func _place_bridge(chunk: Node3D, b1: Dictionary, b2: Dictionary) -> void:
	var bridge_y: float = min(float(b1.height), float(b2.height)) * 0.5
	var dx: float = float(b2.cx) - float(b1.cx)
	var dz: float = float(b2.cz) - float(b1.cz)
	var length: float = sqrt(dx * dx + dz * dz) - (float(b1.width) + float(b2.width)) * 0.25
	if length <= 2.0:
		return
	var cx: float = (float(b1.cx) + float(b2.cx)) * 0.5
	var cz: float = (float(b1.cz) + float(b2.cz)) * 0.5
	var angle: float = atan2(dx, dz)

	var bridge := StaticBody3D.new()
	bridge.position = Vector3(cx, bridge_y, cz)
	bridge.rotation.y = angle
	_add_piece(bridge, Vector3(length, 2.5, 4.5), Vector3.ZERO, _mat_concrete)
	# Railings (visual only)
	for side in [-1.0, 1.0]:
		var rail := MeshInstance3D.new()
		var rmesh := BoxMesh.new()
		rmesh.size = Vector3(length, 0.9, 0.2)
		rail.mesh = rmesh
		rail.material_override = _mat_concrete
		rail.position = Vector3(0.0, 1.7, side * 2.2)
		bridge.add_child(rail)
	chunk.add_child(bridge)

# ── Chunk management ─────────────────────────────────────────

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
		return (a - player_chunk).length_squared() < (b - player_chunk).length_squared()
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

	# Collect placed buildings for bridge generation
	var placed: Array[Dictionary] = []

	for sx in range(SLOTS_PER_CHUNK):
		for sz in range(SLOTS_PER_CHUNK):
			if rng.randf() < EMPTY_LOT_CHANCE:
				continue

			var cx := sx * SLOT_SIZE + SLOT_SIZE * 0.5
			var cz := sz * SLOT_SIZE + SLOT_SIZE * 0.5

			var body := StaticBody3D.new()
			body.position = Vector3(cx, 0.0, cz)

			var roll := rng.randf()
			var info: Dictionary
			if roll < 0.20:
				info = _place_arch(body, rng)
			elif roll < 0.40:
				info = _place_stepped(body, rng)
			elif roll < 0.55:
				info = _place_tower(body, rng)
			elif roll < 0.65:
				info = _place_low_wide(body, rng)
			else:
				info = _place_basic(body, rng)

			chunk.add_child(body)
			info.cx = cx
			info.cz = cz
			placed.append(info)

	# Bridges between adjacent tall buildings
	for i in range(placed.size()):
		for j in range(i + 1, placed.size()):
			var b1: Dictionary = placed[i]
			var b2: Dictionary = placed[j]
			if b1.height < 40.0 or b2.height < 40.0:
				continue
			var dist := Vector2(b1.cx, b1.cz).distance_to(Vector2(b2.cx, b2.cz))
			if dist < SLOT_SIZE * 1.6 and rng.randf() < 0.25:
				_place_bridge(chunk, b1, b2)

	# Ground plane
	var ground := StaticBody3D.new()
	var gmi := MeshInstance3D.new()
	var gmesh := BoxMesh.new()
	gmesh.size = Vector3(CHUNK_SIZE, 0.5, CHUNK_SIZE)
	gmi.mesh = gmesh
	gmi.material_override = _mat_ground
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
