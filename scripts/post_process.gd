extends CanvasLayer

@onready var blur_rect: ColorRect = $MotionBlurRect
@onready var aberration_rect: ColorRect = $ChromaticAberrationRect
@onready var speed_lines_rect: ColorRect = $SpeedLinesRect
@onready var flash_rect: ColorRect = $FlashRect

var player: CharacterBody3D
var _bgm: AudioStreamPlayer

const HYPERSPEED_THRESHOLD: float = 200.0
const MUSIC_PITCH_MAX: float = 1.3

func setup(p_player: CharacterBody3D) -> void:
	player = p_player
	_bgm = get_node_or_null("/root/Main/BGM")

func _process(_delta: float) -> void:
	if not player:
		return

	var current_speed: float = player.speed
	if player.is_boosting:
		current_speed *= player.BOOST_MULTIPLIER
	var speed_ratio: float = clamp((current_speed - player.MIN_SPEED) / (player.MAX_SPEED - player.MIN_SPEED), 0.0, 1.0)

	# Update shader uniforms
	if blur_rect.material:
		(blur_rect.material as ShaderMaterial).set_shader_parameter("speed_ratio", speed_ratio)
	if aberration_rect.material:
		(aberration_rect.material as ShaderMaterial).set_shader_parameter("speed_ratio", speed_ratio)

	# Hyperspeed effects (boost + over 200 m/s, disabled on crash)
	var hyper_ratio: float = 0.0
	if not player._is_crashed and player.is_boosting and current_speed > HYPERSPEED_THRESHOLD:
		hyper_ratio = clamp((current_speed - HYPERSPEED_THRESHOLD) / (player.MAX_SPEED * player.BOOST_MULTIPLIER - HYPERSPEED_THRESHOLD), 0.0, 1.0)

	# Speed lines
	if speed_lines_rect.material:
		(speed_lines_rect.material as ShaderMaterial).set_shader_parameter("intensity", hyper_ratio)

	# Music pitch
	if _bgm:
		_bgm.pitch_scale = lerp(1.0, MUSIC_PITCH_MAX, hyper_ratio)


func flash() -> void:
	flash_rect.color = Color(1, 1, 1, 0.8)
	flash_rect.visible = true
	var tween := create_tween()
	tween.tween_property(flash_rect, "color:a", 0.0, 0.4)
	tween.tween_callback(func(): flash_rect.visible = false)

func shake(camera: Camera3D, duration: float = 0.5, intensity: float = 0.3) -> void:
	var tween := create_tween()
	var original_offset: float = camera.h_offset
	for i in range(10):
		var t: float = duration / 10.0
		var offset: float = randf_range(-intensity, intensity)
		tween.tween_property(camera, "h_offset", offset, t)
	tween.tween_property(camera, "h_offset", original_offset, 0.05)
