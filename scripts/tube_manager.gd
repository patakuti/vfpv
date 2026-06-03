extends Node3D

# ─── Path parameters ───────────────────────────────────────────────────────
const SEGMENT_LENGTH: float = 30.0
const TUBE_RADIUS: float = 20.0
const TUBE_SIDES: int = 16
const LOOK_AHEAD: int = 25
const LOOK_BEHIND: int = 10
const SEGS_PER_FRAME: int = 2
const MAX_YAW_PER_SEG: float = 5.0
const MAX_PITCH_PER_SEG: float = 3.0
const MAX_PITCH_Y: float = 0.64  # sin(~40°): prevents vertical loops

# ─── Visual ────────────────────────────────────────────────────────────────
const COLOR_WALL: Color = Color(0.08, 0.08, 0.10)
const COLOR_RING_A: Color = Color(0.0, 0.80, 1.0)
const COLOR_RING_B: Color = Color(1.0, 0.10, 0.85)
const COLOR_SPINE: Color = Color(0.95, 0.95, 0.95)
const RING_INTERVAL: int = 4  # bright ring every N segments

# ─── Rivals ────────────────────────────────────────────────────────────────
const RIVAL_SPAWN_AHEAD: float = 150.0
const RIVAL_DESPAWN_BEHIND: float = 100.0
const RIVAL_MAX: int = 5
const RIVAL_SPEED_MIN: float = 35.0
const RIVAL_SPEED_MAX: float = 65.0

const RIVAL_DRONE_COLORS: Array = [
	Color(0.9, 0.15, 0.1),
	Color(0.1, 0.75, 0.2),
	Color(0.95, 0.55, 0.0),
	Color(0.7, 0.1, 0.9),
]

enum RivalType { DRONE, JET, POD }

# ─── State ─────────────────────────────────────────────────────────────────
var _enabled: bool = false
var _player: Node3D

# Control point arrays — index 0 maps to global index _base_idx
var _ctrl_pos: Array[Vector3] = []
var _ctrl_tan: Array[Vector3] = []
var _ctrl_norm: Array[Vector3] = []
var _base_idx: int = 0  # global index of _ctrl_pos[0]
var _gen_idx: int = 0   # global index of next point to generate

var _segments: Dictionary = {}  # global_seg_idx -> StaticBody3D
var _player_seg: int = 0
var _player_dist: float = 0.0

var _rivals: Array = []  # Array of Dictionary
var _rival_timer: float = 0.0

var _noise_yaw: FastNoiseLite
var _noise_pitch: FastNoiseLite
var _mat_wall: StandardMaterial3D

# ─── Init ──────────────────────────────────────────────────────────────────
func _ready() -> void:
	_noise_yaw = FastNoiseLite.new()
	_noise_yaw.noise_type = FastNoiseLite.TYPE_PERLIN
	_noise_yaw.seed = randi()
	_noise_yaw.frequency = 0.05
	_noise_yaw.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise_yaw.fractal_octaves = 2

	_noise_pitch = FastNoiseLite.new()
	_noise_pitch.noise_type = FastNoiseLite.TYPE_PERLIN
	_noise_pitch.seed = randi()
	_noise_pitch.frequency = 0.035
	_noise_pitch.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise_pitch.fractal_octaves = 2

	_mat_wall = StandardMaterial3D.new()
	_mat_wall.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_wall.vertex_color_use_as_albedo = true
	_mat_wall.cull_mode = BaseMaterial3D.CULL_BACK

# ─── Public API ────────────────────────────────────────────────────────────
func activate(player: Node3D) -> void:
	_player = player
	_enabled = true
	_reset()
	if player.has_method("set_spawn"):
		# Spawn player LOOK_BEHIND segments inside the tube so the tube
		# extends behind them and they cannot escape through the entrance.
		var tan := _ctrl_tan[LOOK_BEHIND]
		player.set_spawn(_ctrl_pos[LOOK_BEHIND], Vector3(0.0, atan2(-tan.x, -tan.z), 0.0))
	if "tube_manager" in player:
		player.tube_manager = self

func deactivate() -> void:
	_enabled = false
	if _player and "tube_manager" in _player:
		_player.tube_manager = null
	_player = null
	_clear_all()

func get_tube_info_near(pos: Vector3) -> Dictionary:
	if _ctrl_pos.is_empty():
		return {"center": pos, "tangent": Vector3(0.0, 0.0, -1.0)}
	var local_cur: int = clamp(_player_seg - _base_idx, 0, _ctrl_pos.size() - 1)
	var lo: int = max(0, local_cur - 5)
	var hi: int = min(_ctrl_pos.size() - 1, local_cur + 5)
	var best_li: int = lo
	var best_dsq: float = INF
	for li in range(lo, hi + 1):
		var dsq: float = pos.distance_squared_to(_ctrl_pos[li])
		if dsq < best_dsq:
			best_dsq = dsq
			best_li = li
	return {"center": _ctrl_pos[best_li], "tangent": _ctrl_tan[best_li]}

func set_quality(_mode: String) -> void:
	pass  # Tube stage has no quality presets

# ─── Internal ──────────────────────────────────────────────────────────────
func _reset() -> void:
	_clear_all()
	_ctrl_pos.clear()
	_ctrl_tan.clear()
	_ctrl_norm.clear()
	_base_idx = 0
	_gen_idx = 0
	# Player starts LOOK_BEHIND segments inside so the tube exists behind them
	_player_seg = LOOK_BEHIND
	_player_dist = float(LOOK_BEHIND) * SEGMENT_LENGTH
	_rival_timer = 0.0

	# Tube origin at world (0, 80, 0) facing -Z
	_ctrl_pos.append(Vector3(0.0, 80.0, 0.0))
	_ctrl_tan.append(Vector3(0.0, 0.0, -1.0))
	_ctrl_norm.append(Vector3(0.0, 1.0, 0.0))
	_gen_idx = 1

	# Pre-generate enough points to cover behind and ahead of spawn
	for _i in range(LOOK_BEHIND + LOOK_AHEAD + 2):
		_generate_next_point()

	# Build all initial segments so the tube is fully enclosed on entry
	for si in range(LOOK_BEHIND + LOOK_AHEAD):
		_create_segment(si)

func _clear_all() -> void:
	for key in _segments:
		_segments[key].queue_free()
	_segments.clear()
	for r in _rivals:
		if r.has("node") and r.node:
			r.node.queue_free()
	_rivals.clear()

func _process(delta: float) -> void:
	if not _enabled or not _player:
		return

	_player_seg = _find_player_seg()
	_player_dist = float(_player_seg) * SEGMENT_LENGTH

	# Ensure enough control points ahead of player
	var need_to := _player_seg + LOOK_AHEAD + 2
	while _gen_idx <= need_to:
		_generate_next_point()

	# Create missing segments around player
	var created := 0
	for si in range(max(0, _player_seg - LOOK_BEHIND), _player_seg + LOOK_AHEAD):
		if not _segments.has(si) and created < SEGS_PER_FRAME:
			_create_segment(si)
			created += 1

	# Remove segments that are too far away
	var to_remove_segs: Array[int] = []
	for si in _segments:
		if si < _player_seg - LOOK_BEHIND - 1 or si >= _player_seg + LOOK_AHEAD + 1:
			to_remove_segs.append(si)
	for si in to_remove_segs:
		_segments[si].queue_free()
		_segments.erase(si)

	# Trim old control points to save memory
	var trim_to := _player_seg - LOOK_BEHIND - 2
	if trim_to > _base_idx:
		var count := trim_to - _base_idx
		_ctrl_pos = _ctrl_pos.slice(count)
		_ctrl_tan = _ctrl_tan.slice(count)
		_ctrl_norm = _ctrl_norm.slice(count)
		_base_idx = trim_to

	_update_rivals(delta)

	_rival_timer -= delta
	if _rival_timer <= 0.0 and _rivals.size() < RIVAL_MAX:
		_spawn_rival()
		_rival_timer = randf_range(1.0, 3.0)

# ─── Path generation ───────────────────────────────────────────────────────
func _find_player_seg() -> int:
	if _ctrl_pos.size() < 2:
		return _player_seg
	var best: int = _player_seg
	var best_dsq: float = INF
	var local_cur: int = clamp(_player_seg - _base_idx, 0, _ctrl_pos.size() - 1)
	var lo: int = max(0, local_cur - 3)
	var hi: int = min(_ctrl_pos.size() - 2, local_cur + 6)
	for li in range(lo, hi + 1):
		var dsq: float = _player.global_position.distance_squared_to(_ctrl_pos[li])
		if dsq < best_dsq:
			best_dsq = dsq
			best = li + _base_idx
	return best

func _generate_next_point() -> void:
	var li := _gen_idx - 1 - _base_idx
	if li < 0 or li >= _ctrl_pos.size():
		return

	var prev_pos := _ctrl_pos[li]
	var prev_tan := _ctrl_tan[li]
	var prev_norm := _ctrl_norm[li]

	var t := float(_gen_idx)
	var yaw_d := _noise_yaw.get_noise_1d(t) * MAX_YAW_PER_SEG
	var pitch_d := _noise_pitch.get_noise_1d(t) * MAX_PITCH_PER_SEG

	var right := prev_tan.cross(Vector3.UP)
	if right.length_squared() < 0.001:
		right = prev_tan.cross(Vector3.FORWARD)
	right = right.normalized()

	var new_tan := prev_tan.rotated(Vector3.UP, deg_to_rad(yaw_d))
	new_tan = new_tan.rotated(right, deg_to_rad(pitch_d)).normalized()

	# Clamp to prevent vertical loops (no upside-down flying)
	if abs(new_tan.y) > MAX_PITCH_Y:
		new_tan.y = sign(new_tan.y) * MAX_PITCH_Y
		new_tan = new_tan.normalized()

	# Rotation-minimizing frame: project prev_norm onto plane ⊥ new_tan
	var dp := prev_norm.dot(new_tan)
	var new_norm := (prev_norm - new_tan * dp).normalized()
	# Gently bias toward world up to prevent cumulative roll drift
	new_norm = new_norm.lerp(Vector3.UP, 0.05).normalized()
	dp = new_norm.dot(new_tan)
	new_norm = (new_norm - new_tan * dp).normalized()
	if new_norm.y < 0.0:
		new_norm = -new_norm

	_ctrl_pos.append(prev_pos + new_tan * SEGMENT_LENGTH)
	_ctrl_tan.append(new_tan)
	_ctrl_norm.append(new_norm)
	_gen_idx += 1

# ─── Tube segment mesh ─────────────────────────────────────────────────────
func _ring_color(global_ring_idx: int) -> Color:
	if global_ring_idx % RING_INTERVAL == 0:
		return COLOR_RING_A if (global_ring_idx / RING_INTERVAL) % 2 == 0 else COLOR_RING_B
	return COLOR_WALL

func _create_segment(seg_idx: int) -> void:
	var ls := seg_idx - _base_idx
	var le := ls + 1
	if ls < 0 or le >= _ctrl_pos.size():
		return

	var ps := _ctrl_pos[ls]; var ts := _ctrl_tan[ls]; var ns := _ctrl_norm[ls]
	var pe := _ctrl_pos[le]; var te := _ctrl_tan[le]; var ne := _ctrl_norm[le]
	var rs := ts.cross(ns).normalized()
	var re := te.cross(ne).normalized()

	var c_s := _ring_color(seg_idx)
	var c_e := _ring_color(seg_idx + 1)

	var vs := PackedVector3Array(); vs.resize(TUBE_SIDES)
	var ve := PackedVector3Array(); ve.resize(TUBE_SIDES)
	var cs := PackedColorArray();  cs.resize(TUBE_SIDES)
	var ce := PackedColorArray();  ce.resize(TUBE_SIDES)

	for i in range(TUBE_SIDES):
		var angle := TAU * float(i) / float(TUBE_SIDES)
		var ca := cos(angle); var sa := sin(angle)
		vs[i] = ps + ns * ca * TUBE_RADIUS + rs * sa * TUBE_RADIUS
		ve[i] = pe + ne * ca * TUBE_RADIUS + re * sa * TUBE_RADIUS
		# Spine: top vertex (i == 0, the normal direction) is white for orientation
		cs[i] = COLOR_SPINE if i == 0 else c_s
		ce[i] = COLOR_SPINE if i == 0 else c_e

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for i in range(TUBE_SIDES):
		var i1 := (i + 1) % TUBE_SIDES
		# Reversed winding so face normals point inward (toward tube center).
		# CULL_BACK culls the outer face; inner face is rendered and collision
		# normals point inward so god-mode bounce pushes player back inside.
		st.set_color(cs[i]);  st.add_vertex(vs[i])
		st.set_color(cs[i1]); st.add_vertex(vs[i1])
		st.set_color(ce[i]);  st.add_vertex(ve[i])
		st.set_color(ce[i]);  st.add_vertex(ve[i])
		st.set_color(cs[i1]); st.add_vertex(vs[i1])
		st.set_color(ce[i1]); st.add_vertex(ve[i1])

	var mesh := st.commit()

	var body := StaticBody3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _mat_wall
	body.add_child(mi)

	var col := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(mesh.get_faces())
	col.shape = shape
	body.add_child(col)

	add_child(body)
	_segments[seg_idx] = body

# ─── Path sampling for rivals ──────────────────────────────────────────────
func _sample_path(path_dist: float) -> Dictionary:
	var si := int(path_dist / SEGMENT_LENGTH)
	var t := fmod(path_dist, SEGMENT_LENGTH) / SEGMENT_LENGTH
	var ls := si - _base_idx
	var le := ls + 1
	if ls < 0 or le >= _ctrl_pos.size():
		return {}
	return {
		"pos": _ctrl_pos[ls].lerp(_ctrl_pos[le], t),
		"tan": _ctrl_tan[ls].lerp(_ctrl_tan[le], t).normalized(),
		"norm": _ctrl_norm[ls].lerp(_ctrl_norm[le], t).normalized(),
	}


# ─── Rivals ────────────────────────────────────────────────────────────────
func _update_rivals(delta: float) -> void:
	var to_remove: Array[int] = []
	for i in range(_rivals.size()):
		var r: Dictionary = _rivals[i]
		r.path_dist = float(r.path_dist) + float(r.speed) * delta
		if float(r.path_dist) < _player_dist - RIVAL_DESPAWN_BEHIND:
			to_remove.append(i)
			continue
		var sample: Dictionary = _sample_path(float(r.path_dist))
		if sample.is_empty():
			to_remove.append(i)
			continue
		var tan: Vector3 = sample["tan"]
		var norm: Vector3 = sample["norm"]
		var pos: Vector3 = sample["pos"]
		var right: Vector3 = tan.cross(norm).normalized()
		var off: Vector2 = r.get("offset", Vector2.ZERO)
		pos += norm * off.y + right * off.x
		r.node.global_transform = Transform3D(Basis(right, norm, -tan), pos)

	for i in range(to_remove.size() - 1, -1, -1):
		var idx: int = to_remove[i]
		_rivals[idx].node.queue_free()
		_rivals.remove_at(idx)

func _spawn_rival() -> void:
	if _rivals.size() >= RIVAL_MAX:
		return
	var rtype: int = randi() % 3
	var player_speed: float = float(_player.speed) if _player else 80.0
	var speed: float = clampf(player_speed + randf_range(-10.0, -5.0), 10.0, 400.0)
	# Random offset within inner 40% of tube radius so rivals stay near center
	var angle: float = randf() * TAU
	var dist: float = randf() * TUBE_RADIUS * 0.3
	var offset := Vector2(cos(angle), sin(angle)) * dist
	var node := _build_rival(rtype)
	add_child(node)
	_rivals.append({
		"type": rtype,
		"path_dist": _player_dist + RIVAL_SPAWN_AHEAD,
		"speed": speed,
		"offset": offset,
		"node": node,
	})

# ─── Rival model builders ──────────────────────────────────────────────────
func _mat(color: Color, roughness: float = 0.6, metallic: float = 0.2) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	return m

func _emit_mat(albedo: Color, emit: Color, energy: float = 2.5) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.emission_enabled = true
	m.emission = emit
	m.emission_energy_multiplier = energy
	return m

func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: StandardMaterial3D, rot: Vector3 = Vector3.ZERO) -> void:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)

func _cyl(parent: Node3D, radius: float, height: float, pos: Vector3, mat: StandardMaterial3D, rot: Vector3 = Vector3.ZERO) -> void:
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 8
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)

func _build_rival(rtype: int) -> Node3D:
	# Wrapper holds position/rotation (set each frame via global_transform).
	# The inner model node holds the scale so it is not overwritten each frame.
	var wrapper := Node3D.new()
	var model: Node3D
	match rtype:
		RivalType.DRONE: model = _build_drone()
		RivalType.JET:   model = _build_jet()
		RivalType.POD:   model = _build_pod()
		_: model = Node3D.new()
	wrapper.add_child(model)
	return wrapper

func _build_drone() -> Node3D:
	var root := Node3D.new()
	var accent_col: Color = RIVAL_DRONE_COLORS[randi() % RIVAL_DRONE_COLORS.size()]
	var carbon := _mat(Color(0.10, 0.10, 0.13), 0.35, 0.4)
	var dark   := _mat(Color(0.18, 0.18, 0.22), 0.25, 0.7)
	var accent := _emit_mat(accent_col, accent_col, 3.0)

	_box(root, Vector3(0.45, 0.08, 0.55), Vector3.ZERO, carbon)
	_box(root, Vector3(0.35, 0.02, 0.40), Vector3(0, -0.05, 0), dark)

	for ang in [45.0, -45.0]:
		_box(root, Vector3(0.06, 0.04, 1.1), Vector3.ZERO, carbon, Vector3(0, deg_to_rad(ang), 0))

	var motor_offsets := [
		Vector3(0.46, 0.0, 0.46), Vector3(-0.46, 0.0, 0.46),
		Vector3(0.46, 0.0, -0.46), Vector3(-0.46, 0.0, -0.46),
	]
	for mp: Vector3 in motor_offsets:
		_cyl(root, 0.06, 0.06, mp, dark)
		_cyl(root, 0.18, 0.01, mp + Vector3(0, 0.04, 0), accent)

	_box(root, Vector3(0.02, 0.03, 0.40), Vector3( 0.24, 0.01, 0), accent)
	_box(root, Vector3(0.02, 0.03, 0.40), Vector3(-0.24, 0.01, 0), accent)
	return root

func _build_jet() -> Node3D:
	var root := Node3D.new()
	var silver  := _mat(Color(0.70, 0.72, 0.75), 0.25, 0.8)
	var dark    := _mat(Color(0.15, 0.15, 0.20), 0.40, 0.6)
	var exhaust := _emit_mat(Color(0.4, 0.6, 1.0), Color(0.2, 0.4, 1.0), 3.5)
	var cockpit := _emit_mat(Color(0.3, 0.8, 1.0), Color(0.1, 0.6, 1.0), 1.5)

	# Fuselage (elongated along Z, which is "backward" in model space — forward is -Z)
	_box(root, Vector3(0.28, 0.22, 1.8), Vector3.ZERO, silver)
	# Nose
	_box(root, Vector3(0.16, 0.14, 0.5), Vector3(0, 0, -1.15), dark)
	# Cockpit bubble
	var cmi := MeshInstance3D.new()
	var csph := SphereMesh.new(); csph.radius = 0.13; csph.height = 0.22
	cmi.mesh = csph; cmi.material_override = cockpit
	cmi.position = Vector3(0, 0.15, -0.5)
	root.add_child(cmi)
	# Wings (one box centered, wide in X)
	_box(root, Vector3(2.0, 0.05, 0.55), Vector3(0, 0, 0.25), silver)
	# Tail fin (vertical)
	_box(root, Vector3(0.05, 0.40, 0.40), Vector3(0, 0.22, 0.75), dark)
	# Horizontal stabilizer
	_box(root, Vector3(0.80, 0.05, 0.28), Vector3(0, 0, 0.78), dark)
	# Engine exhaust ring
	_cyl(root, 0.10, 0.28, Vector3(0, 0, 1.05), exhaust)
	return root

func _build_pod() -> Node3D:
	var root := Node3D.new()
	var body_mat := _mat(Color(0.08, 0.08, 0.12), 0.5, 0.3)
	var glow_l   := _emit_mat(Color(0.1, 1.0, 0.5), Color(0.0, 1.0, 0.4), 3.5)
	var glow_r   := _emit_mat(Color(0.5, 0.1, 1.0), Color(0.3, 0.0, 1.0), 3.5)
	var core_mat := _emit_mat(Color(0.8, 0.8, 1.0), Color(0.6, 0.6, 1.0), 2.0)

	# Flattened disc body
	var bmi := MeshInstance3D.new()
	var bsph := SphereMesh.new(); bsph.radius = 0.5; bsph.height = 1.0
	bmi.mesh = bsph; bmi.material_override = body_mat
	bmi.scale = Vector3(1.0, 0.42, 1.3)
	root.add_child(bmi)

	# Engine pods (left / right), oriented along Z
	for side in [-1.0, 1.0]:
		var glow: StandardMaterial3D = glow_l if side > 0 else glow_r
		_cyl(root, 0.07, 1.0, Vector3(side * 0.55, 0, 0.05), glow, Vector3(deg_to_rad(90), 0, 0))
		# Exhaust ring at rear of pod
		_cyl(root, 0.12, 0.03, Vector3(side * 0.55, 0, 0.55), glow)

	# Center glow spine along Z
	_box(root, Vector3(0.03, 0.03, 1.1), Vector3.ZERO, core_mat)
	return root
