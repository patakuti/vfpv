extends CharacterBody3D

@onready var vi_input: Node = $ViInput
@onready var fpv_camera: Camera3D = $FPVCamera
@onready var follow_camera: Camera3D = $FollowCamera
var auto_pilot: Node3D  # set by main.gd
var sfx: Node  # set by main.gd

var _input_handler: Node   # vi_input (desktop) or android_input (Android)
var _is_android: bool = false

# Speed
var speed: float = 80.0
var base_speed: float = 80.0
const MIN_SPEED: float = 20.0
const MAX_SPEED: float = 400.0

# Boost
var boost_fuel: float = 100.0
const BOOST_MAX: float = 100.0
const BOOST_CONSUME_RATE: float = 15.0
const BOOST_RECOVERY_RATE: float = 10.0
const BOOST_MULTIPLIER: float = 1.5
var is_boosting: bool = false

# Rotation rates (degrees/sec)
const YAW_RATE: float = 90.0
const PITCH_RATE: float = 60.0
const AUTO_RATE_MULTIPLIER: float = 4.0

# Physics
const GRAVITY: float = 2.0
const BOUNCE_DAMPING: float = 0.6

# Tube assist (Android only)
const TUBE_CENTERING_STRENGTH: float = 10.0   # max centering speed at wall (m/s)
const TUBE_REPULSION_THRESHOLD: float = 0.65  # fraction of TUBE_RADIUS where repulsion starts
const TUBE_REPULSION_STRENGTH: float = 40.0   # max repulsion speed at wall (m/s)

# FOV
const FOV_MIN: float = 80.0
const FOV_MAX: float = 110.0

# Records
var max_speed_record: float = 0.0
var elapsed_time: float = 0.0

# Crash
var _is_crashed: bool = false
var _respawn_grace: float = 0.0  # brief invincibility after respawn
var _spawn_position: Vector3
var _spawn_rotation: Vector3
var post_process: Node  # set by main.gd
var main: Node  # set by main.gd

# God mode
var god_mode: bool = false

# Stage context (set by stage managers)
var tube_manager: Node = null

# Camera
var is_fpv: bool = true

# Drone model
var _propellers: Array[MeshInstance3D] = []
const PROP_SPIN_SPEED: float = 25.0
var drone_pivot: Node3D  # groups all drone meshes for bank roll

# Bank
const BANK_MAX_ANGLE: float = 30.0  # degrees
const BANK_SHARP_ANGLE: float = 55.0  # degrees (for sharp turn)
const BANK_SMOOTHING: float = 8.0  # lerp speed
var _current_bank: float = 0.0  # current bank angle in degrees

# Pitch tilt (nose-down proportional to speed)
const PITCH_TILT_MAX: float = 60.0  # degrees nose-down at max speed
const PITCH_TILT_SMOOTHING: float = 3.0
var _current_pitch_tilt: float = 0.0

func _ready() -> void:
	_spawn_position = global_position
	_spawn_rotation = rotation

	_is_android = (OS.get_name() == "Android")
	if _is_android:
		var ai := preload("res://scripts/android_input.gd").new()
		ai.name = "AndroidInput"
		add_child(ai)
		_input_handler = ai
	else:
		_input_handler = vi_input
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
		if sfx:
			sfx.set_boost_active(false)
		return

	elapsed_time += delta

	var yaw_in: float = _input_handler.yaw_input
	var current_speed: float

	if _is_android:
		# --- Android: Altitude Hold model ---
		# Yaw rotation only (no pitch)
		rotate_y(-yaw_in * deg_to_rad(YAW_RATE) * delta)

		speed = _input_handler.speed_target
		current_speed = speed

		# Horizontal movement (ignore pitch component of basis)
		var horiz_fwd := Vector3(-global_transform.basis.z.x, 0.0, -global_transform.basis.z.z)
		if horiz_fwd.length_squared() > 0.001:
			horiz_fwd = horiz_fwd.normalized()
		velocity = horiz_fwd * current_speed
		velocity.y = _input_handler.altitude_delta
	else:
		# --- Desktop: original flight model ---
		var pitch_in: float = _input_handler.pitch_input
		var yaw_rate: float = YAW_RATE
		var pitch_rate: float = PITCH_RATE
		if auto_pilot and auto_pilot.enabled:
			if yaw_in == 0.0 and auto_pilot.auto_yaw != 0.0:
				yaw_in = auto_pilot.auto_yaw
				yaw_rate = YAW_RATE * AUTO_RATE_MULTIPLIER
			if pitch_in == 0.0 and auto_pilot.auto_pitch != 0.0:
				pitch_in = auto_pilot.auto_pitch
				pitch_rate = PITCH_RATE * AUTO_RATE_MULTIPLIER
		rotate_y(-yaw_in * deg_to_rad(yaw_rate) * delta)
		rotate_object_local(Vector3.RIGHT, pitch_in * deg_to_rad(pitch_rate) * delta)

		# Boost
		if _input_handler.boost_pressed and boost_fuel > 0.0:
			is_boosting = true
			boost_fuel = max(0.0, boost_fuel - BOOST_CONSUME_RATE * delta)
		else:
			is_boosting = false
			boost_fuel = min(BOOST_MAX, boost_fuel + BOOST_RECOVERY_RATE * delta)
		if sfx:
			sfx.set_boost_active(is_boosting)

		current_speed = speed
		if is_boosting:
			current_speed *= BOOST_MULTIPLIER

		velocity = -global_transform.basis.z * current_speed
		velocity.y -= GRAVITY * delta

	# Tube assist (both platforms)
	if tube_manager:
		velocity += _compute_tube_assist()

	# Move
	move_and_slide()

	# Collision check
	if _respawn_grace > 0.0:
		_respawn_grace -= delta
	elif get_slide_collision_count() > 0:
		if god_mode:
			_bounce()
		else:
			_crash()
			return

	# Update records
	max_speed_record = max(max_speed_record, current_speed)

	# FOV (desktop only; Android uses fixed FOV to avoid false sense of forward motion)
	var speed_ratio = clamp((current_speed - MIN_SPEED) / (MAX_SPEED - MIN_SPEED), 0.0, 1.0)
	if not _is_android:
		var active_cam = get_viewport().get_camera_3d()
		if active_cam:
			active_cam.fov = lerp(FOV_MIN, FOV_MAX, speed_ratio)

	# Bank
	var abs_yaw := absf(yaw_in)
	var target_bank: float = 0.0
	if abs_yaw > 1.0:
		var t := clampf((abs_yaw - 1.0) / (_input_handler.SHARP_YAW - 1.0), 0.0, 1.0)
		target_bank = lerp(BANK_MAX_ANGLE, BANK_SHARP_ANGLE, t)
	elif abs_yaw > 0.0:
		target_bank = BANK_MAX_ANGLE * abs_yaw
	target_bank *= -signf(yaw_in)
	_current_bank = lerp(_current_bank, target_bank, BANK_SMOOTHING * delta)

	# Apply bank and pitch to drone_pivot; fpv_camera is a child of drone_pivot
	# so it inherits both rotations automatically (camera stays fixed relative to frame)
	if drone_pivot:
		drone_pivot.rotation.z = deg_to_rad(_current_bank)

	# Pitch tilt: nose-down proportional to speed
	var target_pitch_tilt: float = PITCH_TILT_MAX * speed_ratio
	_current_pitch_tilt = lerp(_current_pitch_tilt, target_pitch_tilt, PITCH_TILT_SMOOTHING * delta)
	if drone_pivot:
		drone_pivot.rotation.x = deg_to_rad(-_current_pitch_tilt)

	# Update follow camera position
	_update_follow_camera()

func _build_drone_model() -> void:
	drone_pivot = Node3D.new()
	drone_pivot.name = "DronePivot"
	add_child(drone_pivot)
	# Attach fpv_camera to drone_pivot so camera and frame tilt together as one unit.
	# From the FPV camera view, the frame appears fixed; the world tilts.
	fpv_camera.reparent(drone_pivot, true)

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
		drone_pivot.add_child(bar)
		# Reinforcement rib on top
		var rib := MeshInstance3D.new()
		var rib_mesh := BoxMesh.new()
		rib_mesh.size = Vector3(0.03, 0.015, 1.20)
		rib.mesh = rib_mesh
		rib.material_override = dark_metal
		rib.position.y = 0.028
		rib.rotation.y = deg_to_rad(angle)
		drone_pivot.add_child(rib)

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
		drone_pivot.add_child(prop)
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
	drone_pivot.add_child(mi)
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
	drone_pivot.add_child(mi)
	return mi

func _update_follow_camera() -> void:
	if follow_camera:
		var behind = global_transform.basis.z * 1.5
		var up = Vector3.UP * 0.5
		follow_camera.global_position = global_position + behind + up
		follow_camera.look_at(global_position, Vector3.UP)

func _bounce() -> void:
	if tube_manager:
		_tube_bounce()
		return
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

func _compute_tube_assist() -> Vector3:
	var info: Dictionary = tube_manager.get_tube_info_near(global_position)
	var tube_center: Vector3 = info["center"]
	var tube_tan: Vector3 = info["tangent"]

	# Radial offset in the cross-section plane (remove tangent component)
	var to_center := tube_center - global_position
	to_center -= tube_tan * to_center.dot(tube_tan)
	var dist := to_center.length()
	if dist < 0.001:
		return Vector3.ZERO
	var r_hat := to_center / dist

	# Tube "up" direction projected onto cross-section plane
	var tube_up := Vector3.UP - Vector3.UP.dot(tube_tan) * tube_tan
	if tube_up.length_squared() > 0.001:
		tube_up = tube_up.normalized()
	else:
		tube_up = Vector3.UP

	var tube_radius: float = tube_manager.TUBE_RADIUS

	# Centering force: all directions, weak, proportional to distance from center
	var assist := r_hat * TUBE_CENTERING_STRENGTH * (dist / tube_radius)

	# Wall repulsion: only near the wall
	var repulsion_start := TUBE_REPULSION_THRESHOLD * tube_radius
	var repulsion_mag := 0.0
	if dist > repulsion_start:
		var t := (dist - repulsion_start) / (tube_radius - repulsion_start)
		repulsion_mag = TUBE_REPULSION_STRENGTH * t
		if god_mode:
			assist += r_hat * repulsion_mag
		else:
			# Non-god: vertical component only, scaled by dot product with tube_up
			var vertical_factor := r_hat.dot(tube_up)
			assist += tube_up * vertical_factor * repulsion_mag

	if OS.is_debug_build():
		print("[tube_assist] dist=%.2f/%.2f(%.0f%%) repulsion_mag=%.2f god=%s assist=%.2f,%.2f,%.2f" % [
				dist, tube_radius, dist / tube_radius * 100.0,
				repulsion_mag, str(god_mode),
				assist.x, assist.y, assist.z])

	return assist

func _tube_bounce() -> void:
	var info: Dictionary = tube_manager.get_tube_info_near(global_position)
	var tube_center: Vector3 = info["center"]
	var tube_tan: Vector3 = info["tangent"]
	var to_center: Vector3 = tube_center - global_position
	if to_center.length_squared() < 0.001:
		to_center = Vector3.UP
	var dist_from_center: float = to_center.length()
	to_center = to_center.normalized()
	if god_mode:
		# Push player to 1/3 of tube radius from center
		var target_dist: float = tube_manager.TUBE_RADIUS / 3.0
		var push: float = max(dist_from_center - target_dist, 0.0)
		global_position += to_center * push
	else:
		global_position += to_center * 1.0
	# Orient along tube direction closest to current forward
	var current_forward := -global_transform.basis.z
	if current_forward.dot(tube_tan) < 0.0:
		tube_tan = -tube_tan
	look_at(global_position + tube_tan, Vector3.UP)
	speed = max(speed * BOUNCE_DAMPING * BOUNCE_DAMPING, MIN_SPEED)
	_respawn_grace = 0.2
	if post_process:
		var active_cam := get_viewport().get_camera_3d()
		if active_cam:
			post_process.shake(active_cam, 0.2, 0.15)

func _crash() -> void:
	_is_crashed = true
	velocity = Vector3.ZERO
	if sfx:
		sfx.play_crash()
	if post_process:
		post_process.flash()
		var active_cam = get_viewport().get_camera_3d()
		if active_cam:
			post_process.shake(active_cam)

func respawn() -> void:
	_is_crashed = false
	_respawn_grace = 0.5
	global_position = _spawn_position
	rotation = _spawn_rotation
	velocity = Vector3.ZERO
	speed = base_speed
	boost_fuel = BOOST_MAX

func set_spawn_y(y: float) -> void:
	global_position.y = y
	_spawn_position.y = y

func set_spawn(pos: Vector3, rot: Vector3) -> void:
	_spawn_position = pos
	_spawn_rotation = rot

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
		"auto":
			if auto_pilot:
				auto_pilot.enabled = not auto_pilot.enabled
		"quality":
			if parts.size() >= 2 and main:
				main.set_quality(parts[1])
		"debug":
			var hud = get_node("/root/Main/HUD")
			if hud:
				hud.debug_mode = not hud.debug_mode
		"quit", "q":
			get_tree().quit()
