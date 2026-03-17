extends Node

enum Mode { NORMAL, COMMAND }

var mode: int = Mode.NORMAL

# Input state (read by Player each frame)
var yaw_input: float = 0.0    # -1 = left(h), +1 = right(l)
var pitch_input: float = 0.0  # -1 = down(j), +1 = up(k)
var boost_pressed: bool = false

# g prefix state: g -> g(wait) -> gg or g<digits>
var _g_pending: bool = false
var _g_timer: float = 0.0
var _g_digits: String = ""
const G_TIMEOUT: float = 0.5

# Dot repeat
var _last_action: String = ""
var _replaying: bool = false
var _replay_timer: float = 0.0
const REPLAY_DURATION: float = 1.0

# Signals
signal command_submitted(command: String)
signal set_max_speed()
signal set_min_speed()
signal set_speed(value: float)
signal switch_fpv()
signal switch_follow()
signal dot_replay_start(action: String)
signal toggle_pause()

func _process(delta: float) -> void:
	if mode == Mode.COMMAND:
		return

	# g prefix timer
	if _g_pending:
		_g_timer -= delta
		if _g_timer <= 0.0:
			_finish_g_prefix()

	# Dot replay timer
	if _replaying:
		_replay_timer -= delta
		if _replay_timer <= 0.0:
			_replaying = false

	# Reset per-frame input
	yaw_input = 0.0
	pitch_input = 0.0
	boost_pressed = false

	if _replaying:
		_apply_action(_last_action)
		return

	# Read held keys
	if Input.is_key_pressed(KEY_H):
		yaw_input = -1.0
		_last_action = "h"
	elif Input.is_key_pressed(KEY_L):
		yaw_input = 1.0
		_last_action = "l"

	if Input.is_key_pressed(KEY_J):
		pitch_input = -1.0
		_last_action = "j"
	elif Input.is_key_pressed(KEY_K):
		pitch_input = 1.0
		_last_action = "k"

	if Input.is_key_pressed(KEY_SPACE):
		boost_pressed = true
		_last_action = "boost"

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed:
		return

	var key_event := event as InputEventKey

	if mode == Mode.NORMAL:
		_handle_normal_key(key_event)
	# COMMAND mode input is handled by HUD's LineEdit

func _handle_normal_key(event: InputEventKey) -> void:
	# Ctrl combinations
	if event.ctrl_pressed:
		match event.keycode:
			KEY_F:
				switch_fpv.emit()
				get_viewport().set_input_as_handled()
			KEY_B:
				switch_follow.emit()
				get_viewport().set_input_as_handled()
		return

	# p -> toggle pause
	if event.keycode == KEY_P and not event.shift_pressed:
		toggle_pause.emit()
		get_viewport().set_input_as_handled()
		return

	# Colon -> command mode (auto-pause)
	if event.keycode == KEY_SEMICOLON and event.shift_pressed:
		mode = Mode.COMMAND
		if not get_tree().paused:
			get_tree().paused = true
		get_viewport().set_input_as_handled()
		return

	# G (shift+g) -> min speed
	if event.keycode == KEY_G and event.shift_pressed:
		set_min_speed.emit()
		_g_pending = false
		_g_digits = ""
		get_viewport().set_input_as_handled()
		return

	# g prefix: digits collected while g_pending
	if _g_pending and _is_digit_key(event.keycode):
		_g_digits += _key_to_digit(event.keycode)
		_g_timer = G_TIMEOUT  # reset timer on each digit
		get_viewport().set_input_as_handled()
		return

	# g key
	if event.keycode == KEY_G and not event.shift_pressed:
		if _g_pending and _g_digits.is_empty():
			# gg -> max speed
			set_max_speed.emit()
			_g_pending = false
		else:
			_g_pending = true
			_g_timer = G_TIMEOUT
			_g_digits = ""
		get_viewport().set_input_as_handled()
		return

	# Any other key while g_pending -> finish g prefix first
	if _g_pending:
		_finish_g_prefix()

	# Dot repeat
	if event.keycode == KEY_PERIOD:
		if _last_action != "":
			_replaying = true
			_replay_timer = REPLAY_DURATION
			dot_replay_start.emit(_last_action)
		get_viewport().set_input_as_handled()
		return

func _finish_g_prefix() -> void:
	if _g_digits != "":
		var val := _g_digits.to_float()
		if val > 0.0:
			set_speed.emit(val)
	_g_pending = false
	_g_digits = ""

func _is_digit_key(keycode: Key) -> bool:
	return keycode >= KEY_0 and keycode <= KEY_9

func _key_to_digit(keycode: Key) -> String:
	return str(keycode - KEY_0)

func _apply_action(action: String) -> void:
	match action:
		"h": yaw_input = -1.0
		"l": yaw_input = 1.0
		"j": pitch_input = -1.0
		"k": pitch_input = 1.0
		"boost": boost_pressed = true

func exit_command_mode() -> void:
	mode = Mode.NORMAL
	get_tree().paused = false

func submit_command(text: String) -> void:
	command_submitted.emit(text)
	mode = Mode.NORMAL
	get_tree().paused = false
