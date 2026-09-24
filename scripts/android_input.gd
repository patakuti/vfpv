extends Node

# Sensor
const FILTER_ALPHA: float = 0.15
const MAX_PITCH_TILT: float = 0.30  # diff.y threshold → max speed
const MAX_YAW_TILT: float = 0.30    # diff.x threshold → max yaw

# Touch altitude (floating vertical slider: offset from touch-down point → climb rate)
const ALTITUDE_SPEED: float = 60.0       # m/s at full deflection
const ALTITUDE_DEADZONE_RATIO: float = 0.02  # of viewport height; offsets within this are ignored
const ALTITUDE_FULL_RATIO: float = 0.20      # of viewport height that reaches full deflection

# Debug
const DEBUG_SPEED_STEP: float = 0.1  # fraction of speed range per UP/DOWN press

# --- Duck-typing interface (compatible with vi_input) ---
const SHARP_YAW: float = 2.5  # defined for interface compat; Android yaw stays ≤1.0
var yaw_input: float = 0.0
var pitch_input: float = 0.0    # unused in Android flight model
var boost_pressed: bool = false  # no boost on Android
# --- Android-specific ---
var speed_target: float = 0.0
var altitude_delta: float = 0.0
# Altitude slider state (read by altitude_slider.gd for drawing)
var altitude_touch_active: bool = false
var altitude_origin: Vector2 = Vector2.ZERO
var altitude_touch_pos: Vector2 = Vector2.ZERO
var altitude_ratio: float = 0.0  # -1..1, positive = ascend
var altitude_deadzone_px: float = 0.0  # fixed at touch-down from viewport height
var altitude_full_px: float = 1.0
var is_pause_requested: bool = false

var _filtered_gravity: Vector3 = Vector3.DOWN
var _ref_gravity: Vector3 = Vector3.DOWN

# Touch
var _right_touch_id: int = -1

# Debug state (debug builds only)
var _debug_pitch_ratio: float = 0.0  # 0.0..1.0, stepped by UP/DOWN
var _debug_yaw: float = 0.0          # held by LEFT/RIGHT
var _debug_altitude: float = 0.0     # held by W/S

func _ready() -> void:
	_ref_gravity = SettingsManager.ref_gravity
	_filtered_gravity = _ref_gravity
	speed_target = SettingsManager.min_speed

func calibrate() -> void:
	var raw := Input.get_accelerometer()
	if raw.length_squared() < 0.01:
		return
	_ref_gravity = raw.normalized()
	_filtered_gravity = _ref_gravity
	SettingsManager.ref_gravity = _ref_gravity
	SettingsManager.save_settings()

func _process(_delta: float) -> void:
	_update_sensor()
	_compute_from_tilt()
	if OS.is_debug_build():
		_apply_debug_override()

func _update_sensor() -> void:
	var raw := Input.get_accelerometer()
	if raw.length_squared() < 0.01:
		return
	_filtered_gravity = _filtered_gravity.lerp(raw.normalized(), FILTER_ALPHA)

func _compute_from_tilt() -> void:
	var diff := _filtered_gravity - _ref_gravity
	var tilt_ratio := clampf(diff.y / MAX_PITCH_TILT, 0.0, 1.0)
	speed_target = SettingsManager.min_speed + tilt_ratio * (SettingsManager.max_speed - SettingsManager.min_speed)
	yaw_input = clampf(diff.x / MAX_YAW_TILT, -1.0, 1.0)

func _apply_debug_override() -> void:
	if _debug_pitch_ratio > 0.0:
		speed_target = SettingsManager.min_speed + _debug_pitch_ratio * (SettingsManager.max_speed - SettingsManager.min_speed)
	if _debug_yaw != 0.0:
		yaw_input = _debug_yaw
	if _debug_altitude != 0.0:
		altitude_delta = _debug_altitude

func _input(event: InputEvent) -> void:
	_handle_touch(event)
	if OS.is_debug_build():
		_handle_debug_keys(event)

func _handle_touch(event: InputEvent) -> void:
	var half_w := get_viewport().get_visible_rect().size.x * 0.5

	if event is InputEventScreenTouch:
		if event.pressed:
			if event.position.x >= half_w and _right_touch_id == -1:
				_right_touch_id = event.index
				altitude_touch_active = true
				altitude_origin = event.position
				var view_h := get_viewport().get_visible_rect().size.y
				altitude_deadzone_px = view_h * ALTITUDE_DEADZONE_RATIO
				altitude_full_px = view_h * ALTITUDE_FULL_RATIO
				altitude_touch_pos = event.position
				_set_altitude_ratio(0.0)
		elif event.index == _right_touch_id:
			_right_touch_id = -1
			altitude_touch_active = false
			_set_altitude_ratio(0.0)

	elif event is InputEventScreenDrag:
		if event.index == _right_touch_id:
			altitude_touch_pos = event.position
			# Screen Y+ is downward; dragging above the origin → ascend
			var offset: float = altitude_origin.y - event.position.y
			var magnitude := maxf(absf(offset) - altitude_deadzone_px, 0.0)
			var ratio := clampf(magnitude / (altitude_full_px - altitude_deadzone_px), 0.0, 1.0)
			_set_altitude_ratio(ratio * signf(offset))
			if OS.is_debug_build():
				print("[alt] offset=%.1f ratio=%.3f delta=%.3f" % [offset, altitude_ratio, altitude_delta])

func _set_altitude_ratio(ratio: float) -> void:
	altitude_ratio = ratio
	altitude_delta = ratio * ALTITUDE_SPEED

func _handle_debug_keys(event: InputEvent) -> void:
	if not event is InputEventKey or event.echo:
		return

	if event.pressed:
		match event.keycode:
			KEY_UP:
				_debug_pitch_ratio = clampf(_debug_pitch_ratio + DEBUG_SPEED_STEP, 0.0, 1.0)
			KEY_DOWN:
				_debug_pitch_ratio = clampf(_debug_pitch_ratio - DEBUG_SPEED_STEP, 0.0, 1.0)
			KEY_LEFT:
				_debug_yaw = -1.0
			KEY_RIGHT:
				_debug_yaw = 1.0
			KEY_W:
				_debug_altitude = ALTITUDE_SPEED
			KEY_S:
				_debug_altitude = -ALTITUDE_SPEED
	else:
		match event.keycode:
			KEY_LEFT, KEY_RIGHT:
				_debug_yaw = 0.0
			KEY_W, KEY_S:
				_debug_altitude = 0.0
