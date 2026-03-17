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

# God mode
var god_mode: bool = false

func _ready() -> void:
	_spawn_position = global_position
	_spawn_rotation = rotation

	# Connect vi_input signals
	vi_input.set_max_speed.connect(_on_set_max_speed)
	vi_input.set_min_speed.connect(_on_set_min_speed)
	vi_input.switch_fpv.connect(_on_switch_fpv)
	vi_input.switch_follow.connect(_on_switch_follow)
	vi_input.command_submitted.connect(_on_command_submitted)
	vi_input.toggle_pause.connect(_on_toggle_pause)
	vi_input.set_speed.connect(_on_set_speed)

	# Start with FPV
	_activate_camera(fpv_camera)

func _physics_process(delta: float) -> void:
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

func _update_follow_camera() -> void:
	if follow_camera:
		var behind = global_transform.basis.z * 5.0
		var up = Vector3.UP * 2.0
		follow_camera.global_position = global_position + behind + up
		follow_camera.look_at(global_position, Vector3.UP)

func _bounce() -> void:
	var collision := get_slide_collision(0)
	var normal := collision.get_normal()
	# Reflect direction off surface normal
	var forward := -global_transform.basis.z
	var reflected := forward.reflect(normal).normalized()
	# If reflected direction points downward, force horizontal + slight upward
	if reflected.y < 0.0:
		reflected.y = 0.1
		reflected = reflected.normalized()
	# Reorient player to reflected direction
	look_at(global_position + reflected, Vector3.UP)
	# Push away from surface generously
	global_position += normal * 3.0 + Vector3.UP * 2.0
	speed *= BOUNCE_DAMPING
	speed = max(speed, MIN_SPEED)
	# Effects
	if post_process:
		var active_cam = get_viewport().get_camera_3d()
		if active_cam:
			post_process.shake(active_cam, 0.2, 0.15)

func _crash() -> void:
	_is_crashed = true
	velocity = Vector3.ZERO
	# Crash effects
	if post_process:
		post_process.flash()
		var active_cam = get_viewport().get_camera_3d()
		if active_cam:
			post_process.shake(active_cam)

func _respawn() -> void:
	_is_crashed = false
	global_position = _spawn_position
	rotation = _spawn_rotation
	velocity = Vector3.ZERO
	speed = base_speed
	boost_fuel = BOOST_MAX

func _activate_camera(cam: Camera3D) -> void:
	fpv_camera.current = (cam == fpv_camera)
	follow_camera.current = (cam == follow_camera)

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

func _on_switch_fpv() -> void:
	_activate_camera(fpv_camera)

func _on_switch_follow() -> void:
	_activate_camera(follow_camera)

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
			_respawn()
		"god":
			god_mode = not god_mode
		"quit", "q":
			get_tree().quit()
