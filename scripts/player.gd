extends CharacterBody3D

@onready var vi_input: Node = $ViInput
@onready var fpv_camera: Camera3D = $FPVCamera
@onready var follow_camera: Camera3D = $FollowCamera

# Speed
var speed: float = 80.0
var base_speed: float = 80.0
const MIN_SPEED: float = 20.0
const MAX_SPEED: float = 400.0

# Boost
var boost_fuel: float = 100.0
const BOOST_MAX: float = 100.0
const BOOST_CONSUME_RATE: float = 30.0
const BOOST_RECOVERY_RATE: float = 10.0
const BOOST_MULTIPLIER: float = 2.0
var is_boosting: bool = false

# Rotation rates (degrees/sec)
const YAW_RATE: float = 90.0
const PITCH_RATE: float = 60.0

# Physics
const GRAVITY: float = 2.0
const BOUNCE_DAMPING: float = 0.6

# FOV
const FOV_MIN: float = 80.0
const FOV_MAX: float = 110.0

# Records
var max_speed_record: float = 0.0
var elapsed_time: float = 0.0

# Crash
var _is_crashed: bool = false
var _spawn_position: Vector3
var _spawn_rotation: Vector3
var post_process: Node  # set by main.gd
var main: Node  # set by main.gd

# God mode
var god_mode: bool = false

# Camera
var is_fpv: bool = true

# Drone model
var _propellers: Array[MeshInstance3D] = []
const PROP_SPIN_SPEED: float = 25.0

func _ready() -> void:
	_spawn_position = global_position
	_spawn_rotation = rotation

	# Connect vi_input signals
	vi_input.set_max_speed.connect(_on_set_max_speed)
	vi_input.set_min_speed.connect(_on_set_min_speed)
	vi_input.command_submitted.connect(_on_command_submitted)
	vi_input.toggle_pause.connect(_on_toggle_pause)
	vi_input.set_speed.connect(_on_set_speed)

	# Build drone model
	_build_drone_model()

	# Start with FPV
	_activate_camera(fpv_camera)

func _physics_process(delta: float) -> void:
	# Spin propellers always (even when crashed, for visual)
	for prop in _propellers:
		prop.rotate_y(PROP_SPIN_SPEED * delta)

	if _is_crashed:
		return

	elapsed_time += delta

	# Rotation
	var yaw_delta = -vi_input.yaw_input * deg_to_rad(YAW_RATE) * delta
	var pitch_delta = vi_input.pitch_input * deg_to_rad(PITCH_RATE) * delta
	rotate_y(yaw_delta)
	rotate_object_local(Vector3.RIGHT, pitch_delta)

	# Boost
	if vi_input.boost_pressed and boost_fuel > 0.0:
		is_boosting = true
		boost_fuel = max(0.0, boost_fuel - BOOST_CONSUME_RATE * delta)
	else:
		is_boosting = false
		boost_fuel = min(BOOST_MAX, boost_fuel + BOOST_RECOVERY_RATE * delta)

	# Speed
	var current_speed = speed
	if is_boosting:
		current_speed *= BOOST_MULTIPLIER

	# Forward movement
	var forward = -global_transform.basis.z
	velocity = forward * current_speed

	# Gravity
	velocity.y -= GRAVITY * delta

	# Move
	move_and_slide()

	# Collision check
	if get_slide_collision_count() > 0:
		if god_mode:
			_bounce()
		else:
			_crash()
			return

	# Update records
	max_speed_record = max(max_speed_record, current_speed)

	# FOV
	var speed_ratio = clamp((current_speed - MIN_SPEED) / (MAX_SPEED - MIN_SPEED), 0.0, 1.0)
	var active_cam = get_viewport().get_camera_3d()
	if active_cam:
		active_cam.fov = lerp(FOV_MIN, FOV_MAX, speed_ratio)

	# Update follow camera position
	_update_follow_camera()

func _build_drone_model() -> void:
	# === Materials ===
	var carbon_mat := StandardMaterial3D.new()
	carbon_mat.albedo_color = Color(0.10, 0.10, 0.13)
	carbon_mat.metallic = 0.4
	carbon_mat.roughness = 0.35

	var dark_metal := StandardMaterial3D.new()
	dark_metal.albedo_color = Color(0.18, 0.18, 0.22)
	dark_metal.metallic = 0.7
	dark_metal.roughness = 0.25

	var accent_blue := StandardMaterial3D.new()
	accent_blue.albedo_color = Color(0.0, 0.6, 1.0)
	accent_blue.emission_enabled = true
	accent_blue.emission = Color(0.0, 0.5, 1.0)
	accent_blue.emission_energy_multiplier = 3.0

	var accent_red := StandardMaterial3D.new()
	accent_red.albedo_color = Color(1.0, 0.1, 0.1)
	accent_red.emission_enabled = true
	accent_red.emission = Color(1.0, 0.0, 0.0)
	accent_red.emission_energy_multiplier = 2.5

	var motor_mat := StandardMaterial3D.new()
	motor_mat.albedo_color = Color(0.15, 0.15, 0.2)
	motor_mat.metallic = 0.8
	motor_mat.roughness = 0.2

	var prop_mat := StandardMaterial3D.new()
	prop_mat.albedo_color = Color(0.6, 0.6, 0.65, 0.35)
	prop_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	var guard_mat := StandardMaterial3D.new()
	guard_mat.albedo_color = Color(0.12, 0.12, 0.15, 0.6)
	guard_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	guard_mat.metallic = 0.3

	# === Central body (multi-layer) ===
	# Main chassis
	_add_box(Vector3(0.45, 0.08, 0.55), Vector3.ZERO, carbon_mat)
	# Bottom plate
	_add_box(Vector3(0.35, 0.02, 0.40), Vector3(0, -0.05, 0), dark_metal)

	# === Top structure (mecha detail) ===
	# Raised center spine
	_add_box(Vector3(0.08, 0.04, 0.48), Vector3(0, 0.06, -0.02), dark_metal)
	# Side armor plates (angled look via stacked boxes)
	for side in [-1.0, 1.0]:
		_add_box(Vector3(0.12, 0.025, 0.40), Vector3(side * 0.14, 0.05, -0.02), dark_metal)
		_add_box(Vector3(0.08, 0.02, 0.35), Vector3(side * 0.16, 0.065, -0.02), carbon_mat)
	# Heat sink fins on spine
	for i in range(5):
		var z_off: float = -0.18 + i * 0.08
		_add_box(Vector3(0.06, 0.025, 0.012), Vector3(0, 0.085, z_off), motor_mat)
	# Flight controller box (raised center module)
	_add_box(Vector3(0.10, 0.035, 0.12), Vector3(0, 0.075, 0.06), dark_metal)
	_add_box(Vector3(0.06, 0.01, 0.08), Vector3(0, 0.095, 0.06), motor_mat)
	# Blue accent lines on FC box
	_add_box(Vector3(0.10, 0.004, 0.005), Vector3(0, 0.093, 0.01), accent_blue)
	_add_box(Vector3(0.10, 0.004, 0.005), Vector3(0, 0.093, 0.11), accent_blue)
	# ESC stack (front of spine)
	_add_box(Vector3(0.07, 0.03, 0.08), Vector3(0, 0.07, -0.18), dark_metal)
	_add_box(Vector3(0.04, 0.008, 0.06), Vector3(0, 0.088, -0.18), accent_blue)

	# === Front nose ===
	_add_box(Vector3(0.30, 0.06, 0.08), Vector3(0, 0.01, -0.30), carbon_mat)
	# Front camera gimbal mount
	_add_box(Vector3(0.10, 0.10, 0.10), Vector3(0, -0.02, -0.35), dark_metal)
	_add_box(Vector3(0.06, 0.06, 0.06), Vector3(0, -0.02, -0.40), motor_mat)

	# === Side LED strips ===
	for side in [-1.0, 1.0]:
		_add_box(Vector3(0.02, 0.035, 0.40), Vector3(side * 0.235, 0.01, 0), accent_blue)

	# === Rear LED bar ===
	_add_box(Vector3(0.20, 0.03, 0.025), Vector3(0, 0.02, 0.29), accent_red)

	# === X-frame arms (two crossing bars, thick) ===
	for angle in [45.0, -45.0]:
		var bar := MeshInstance3D.new()
		var bar_mesh := BoxMesh.new()
		bar_mesh.size = Vector3(0.07, 0.04, 1.25)
		bar.mesh = bar_mesh
		bar.material_override = carbon_mat
		bar.rotation.y = deg_to_rad(angle)
		add_child(bar)
		# Reinforcement rib on top
		var rib := MeshInstance3D.new()
		var rib_mesh := BoxMesh.new()
		rib_mesh.size = Vector3(0.03, 0.015, 1.20)
		rib.mesh = rib_mesh
		rib.material_override = dark_metal
		rib.position.y = 0.028
		rib.rotation.y = deg_to_rad(angle)
		add_child(rib)

	# === Motor assemblies at 4 corners ===
	var motor_positions: Array[Vector3] = [
		Vector3(-0.55, 0.0, -0.55),
		Vector3(0.55, 0.0, -0.55),
		Vector3(-0.55, 0.0, 0.55),
		Vector3(0.55, 0.0, 0.55),
	]
	var is_front := [true, true, false, false]

	for i in range(4):
		var pos: Vector3 = motor_positions[i]

		# Motor base plate
		_add_cylinder(0.09, 0.10, 0.03, pos + Vector3(0, 0.02, 0), dark_metal)
		# Motor body
		_add_cylinder(0.065, 0.065, 0.08, pos + Vector3(0, 0.06, 0), motor_mat)
		# Motor cap
		_add_cylinder(0.04, 0.03, 0.02, pos + Vector3(0, 0.10, 0), dark_metal)
		# Motor LED ring
		var led_mat: StandardMaterial3D = accent_blue if is_front[i] else accent_red
		_add_cylinder(0.075, 0.075, 0.008, pos + Vector3(0, 0.035, 0), led_mat)

		# Propeller disc (spinning)
		var prop := MeshInstance3D.new()
		var prop_mesh := CylinderMesh.new()
		prop_mesh.top_radius = 0.22
		prop_mesh.bottom_radius = 0.22
		prop_mesh.height = 0.006
		prop.mesh = prop_mesh
		prop.material_override = prop_mat
		prop.position = pos + Vector3(0, 0.115, 0)
		add_child(prop)
		_propellers.append(prop)

		# Prop guard (partial ring, 4 posts)
		var guard_r: float = 0.26
		var guard_h: float = 0.06
		for j in range(4):
			var a: float = j * PI * 0.5
			var gx: float = cos(a) * guard_r
			var gz: float = sin(a) * guard_r
			_add_box(Vector3(0.015, guard_h, 0.015),
				pos + Vector3(gx, 0.06, gz), guard_mat)
		# Guard ring (top connector)
		_add_cylinder(0.265, 0.265, 0.008, pos + Vector3(0, 0.09, 0), guard_mat)
		_add_cylinder(0.24, 0.24, 0.010, pos + Vector3(0, 0.09, 0), carbon_mat)  # inner cutout illusion

	# === Rear antenna mast ===
	_add_box(Vector3(0.015, 0.15, 0.015), Vector3(0.08, 0.10, 0.22), dark_metal)
	_add_box(Vector3(0.015, 0.15, 0.015), Vector3(-0.08, 0.10, 0.22), dark_metal)
	_add_box(Vector3(0.005, 0.02, 0.005), Vector3(0.08, 0.18, 0.22), accent_red)
	_add_box(Vector3(0.005, 0.02, 0.005), Vector3(-0.08, 0.18, 0.22), accent_red)

	# === Rear receiver box ===
	_add_box(Vector3(0.12, 0.06, 0.08), Vector3(0, 0.04, 0.20), dark_metal)

func _add_box(size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
	return mi

func _add_cylinder(top_r: float, bot_r: float, h: float, pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = top_r
	mesh.bottom_radius = bot_r
	mesh.height = h
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
	return mi

func _update_follow_camera() -> void:
	if follow_camera:
		var behind = global_transform.basis.z * 1.5
		var up = Vector3.UP * 0.5
		follow_camera.global_position = global_position + behind + up
		follow_camera.look_at(global_position, Vector3.UP)

func _bounce() -> void:
	var collision := get_slide_collision(0)
	var normal := collision.get_normal()
	var forward := -global_transform.basis.z
	var reflected := forward.reflect(normal).normalized()
	if reflected.y < 0.0:
		reflected.y = 0.1
		reflected = reflected.normalized()
	look_at(global_position + reflected, Vector3.UP)
	global_position += normal * 3.0 + Vector3.UP * 2.0
	speed *= BOUNCE_DAMPING
	speed = max(speed, MIN_SPEED)
	if post_process:
		var active_cam = get_viewport().get_camera_3d()
		if active_cam:
			post_process.shake(active_cam, 0.2, 0.15)

func _crash() -> void:
	_is_crashed = true
	velocity = Vector3.ZERO
	if post_process:
		post_process.flash()
		var active_cam = get_viewport().get_camera_3d()
		if active_cam:
			post_process.shake(active_cam)

func respawn() -> void:
	_is_crashed = false
	global_position = _spawn_position
	rotation = _spawn_rotation
	velocity = Vector3.ZERO
	speed = base_speed
	boost_fuel = BOOST_MAX

func _activate_camera(cam: Camera3D) -> void:
	fpv_camera.current = (cam == fpv_camera)
	follow_camera.current = (cam == follow_camera)
	is_fpv = (cam == fpv_camera)

func _on_toggle_pause() -> void:
	get_tree().paused = not get_tree().paused

# Signal handlers
func _on_set_max_speed() -> void:
	speed = MAX_SPEED

func _on_set_speed(value: float) -> void:
	base_speed = clamp(value, MIN_SPEED, MAX_SPEED)
	speed = base_speed

func _on_set_min_speed() -> void:
	speed = MIN_SPEED

func _on_command_submitted(command: String) -> void:
	var parts = command.strip_edges().split(" ", false)
	if parts.is_empty():
		return
	match parts[0]:
		"speed":
			if parts.size() >= 2:
				var val = parts[1].to_float()
				if val > 0.0:
					base_speed = clamp(val, MIN_SPEED, MAX_SPEED)
					speed = base_speed
		"reset":
			respawn()
		"god":
			god_mode = not god_mode
		"fpv":
			_activate_camera(fpv_camera)
		"follow":
			_activate_camera(follow_camera)
		"stage":
			if parts.size() >= 2 and main:
				main.switch_stage(parts[1])
		"quit", "q":
			get_tree().quit()
