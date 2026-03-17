extends CanvasLayer

@onready var blur_rect: ColorRect = $MotionBlurRect
@onready var aberration_rect: ColorRect = $ChromaticAberrationRect
@onready var flash_rect: ColorRect = $FlashRect

var player: CharacterBody3D

func setup(p_player: CharacterBody3D) -> void:
	player = p_player

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
