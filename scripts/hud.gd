extends CanvasLayer

@onready var speed_label: Label = $SpeedLabel
@onready var time_label: Label = $TimeLabel
@onready var boost_bar: ProgressBar = $BoostBar
@onready var command_line: LineEdit = $CommandLine
@onready var status_label: Label = $StatusLabel

var player: CharacterBody3D
var vi_input: Node

func _ready() -> void:
	command_line.visible = false
	command_line.text_submitted.connect(_on_command_submitted)

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
	if get_tree().paused and (not vi_input or vi_input.mode != vi_input.Mode.COMMAND):
		status_parts.append("PAUSED")
	if player.god_mode:
		status_parts.append("GOD")
	if player._is_crashed:
		status_parts.append("CRASHED - :reset to restart")
	status_label.text = "  ".join(status_parts)

	# Toggle command line visibility
	if vi_input:
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
