extends CanvasLayer

@onready var speed_label: Label = $SpeedLabel
@onready var time_label: Label = $TimeLabel
@onready var boost_bar: ProgressBar = $BoostBar
@onready var command_line: LineEdit = $CommandLine
@onready var status_label: Label = $StatusLabel

var player: CharacterBody3D
var vi_input: Node
var debug_mode: bool = false
var _debug_label: Label
var _is_android: bool = false
var _pause_button: Button
var _pause_menu: Node
var _settings_screen: Node

func _ready() -> void:
	_is_android = (OS.get_name() == "Android")
	command_line.visible = false
	command_line.text_submitted.connect(_on_command_submitted)

	if _is_android:
		boost_bar.visible = false
		_add_pause_button()

	_debug_label = Label.new()
	_debug_label.anchors_preset = 1  # top-right
	_debug_label.anchor_left = 1.0
	_debug_label.anchor_right = 1.0
	_debug_label.offset_left = -350.0
	_debug_label.offset_top = 40.0
	_debug_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_debug_label.visible = false
	add_child(_debug_label)

func _add_pause_button() -> void:
	_pause_button = Button.new()
	_pause_button.text = "| |"
	_pause_button.custom_minimum_size = Vector2(120, 80)
	_pause_button.anchor_left = 0.0
	_pause_button.anchor_top = 0.0
	_pause_button.anchor_right = 0.0
	_pause_button.anchor_bottom = 0.0
	_pause_button.offset_right = 120.0
	_pause_button.offset_bottom = 80.0
	# Must respond even while tree is paused
	_pause_button.process_mode = Node.PROCESS_MODE_ALWAYS
	_pause_button.pressed.connect(_on_pause_button_pressed)
	add_child(_pause_button)

	_pause_menu = preload("res://scenes/pause_menu.tscn").instantiate()
	_pause_menu.resume_pressed.connect(_on_pause_menu_resume)
	_pause_menu.settings_pressed.connect(_on_pause_menu_settings)
	_pause_menu.calibrate_pressed.connect(_on_calibrate_pressed)
	add_child(_pause_menu)

	_settings_screen = preload("res://scenes/settings_screen.tscn").instantiate()
	_settings_screen.closed.connect(_on_settings_screen_closed)
	add_child(_settings_screen)

func _on_pause_button_pressed() -> void:
	get_tree().paused = true
	_pause_menu.show_menu()

func _on_pause_menu_resume() -> void:
	pass

func _on_calibrate_pressed() -> void:
	if player:
		var ai := player.get_node_or_null("AndroidInput")
		if ai:
			ai.calibrate()

func show_startup() -> void:
	get_tree().paused = true
	if _is_android and _pause_menu:
		_pause_menu.show_menu()

func _on_pause_menu_settings() -> void:
	_pause_menu.hide_menu()
	_settings_screen.setup(player, player.main)
	_settings_screen.show_screen()

func _on_settings_screen_closed() -> void:
	_pause_menu.show_menu()

func setup(p_player: CharacterBody3D, p_vi_input: Node) -> void:
	player = p_player
	vi_input = p_vi_input

func _process(_delta: float) -> void:
	if not player:
		return

	# Update displays
	var current_spd = player.speed
	if player.is_boosting:
		current_spd *= player.BOOST_MULTIPLIER
	speed_label.text = "%d / %d m/s" % [int(current_spd), int(player.max_speed_record)]

	var mins = int(player.elapsed_time) / 60
	var secs = int(player.elapsed_time) % 60
	time_label.text = "%02d:%02d" % [mins, secs]

	boost_bar.value = player.boost_fuel

	# Status indicator
	var status_parts: Array[String] = []
	var in_command_mode: bool = (not _is_android) and vi_input != null and vi_input.mode == vi_input.Mode.COMMAND
	if get_tree().paused and not in_command_mode:
		status_parts.append("PAUSED")
	if player.god_mode:
		status_parts.append("GOD")
	if player.auto_pilot and player.auto_pilot.enabled:
		status_parts.append("AUTO")
	if player._is_crashed:
		status_parts.append("CRASHED" if _is_android else "CRASHED - :reset to restart")
	status_label.text = "  ".join(status_parts)

	# Debug display
	if debug_mode:
		_debug_label.visible = true
		var lines: Array[String] = []
		# Quality info
		var tm = get_node_or_null("/root/Main/TerrainManager")
		if tm:
			lines.append("=== QUALITY ===")
			lines.append("mode: %s" % tm.quality_mode)
			lines.append("render_dist: %d" % tm.render_distance)
			lines.append("mesh_res: %d" % tm.mesh_resolution)
			lines.append("fps: %d" % Engine.get_frames_per_second())
		# Auto pilot info
		if player.auto_pilot:
			var ap = player.auto_pilot
			var forward := -player.global_transform.basis.z
			var pitch_deg: float = rad_to_deg(asin(forward.y))
			var up := player.global_transform.basis.y
			var tilt_deg: float = rad_to_deg(acos(clamp(up.dot(Vector3.UP), -1.0, 1.0)))
			lines.append("=== AUTO ===")
			lines.append("pitch: %.1f deg" % pitch_deg)
			lines.append("tilt: %.1f deg" % tilt_deg)
			lines.append("returning_to_level: %s" % str(ap._returning_to_level))
			lines.append("target_yaw: %.2f" % ap._target_yaw)
			lines.append("target_pitch: %.2f" % ap._target_pitch)
			lines.append("auto_yaw: %.2f" % ap.auto_yaw)
			lines.append("auto_pitch: %.2f" % ap.auto_pitch)
		_debug_label.text = "\n".join(lines)
	else:
		_debug_label.visible = false

	# Toggle command line visibility (desktop only)
	if not _is_android and vi_input:
		if vi_input.mode == vi_input.Mode.COMMAND:
			if not command_line.visible:
				command_line.visible = true
				command_line.text = ""
				command_line.grab_focus()
		else:
			command_line.visible = false

func _on_command_submitted(text: String) -> void:
	if vi_input:
		vi_input.submit_command(text)

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed:
		return
	if vi_input and vi_input.mode == vi_input.Mode.COMMAND:
		if event.keycode == KEY_ESCAPE:
			vi_input.exit_command_mode()
			get_viewport().set_input_as_handled()
