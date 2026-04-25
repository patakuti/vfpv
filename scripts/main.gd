extends Node3D

func _ready() -> void:
	_adjust_light_for_renderer()

	var player = $Player
	var vi_input = $Player/ViInput
	var hud = $HUD
	hud.setup(player, vi_input)
	var terrain = $TerrainManager
	terrain.setup(player)
	var post_process = $PostProcess
	post_process.setup(player)
	player.post_process = post_process
	player.main = self
	var auto_pilot = $Player/AutoPilot
	auto_pilot.setup(player)
	player.auto_pilot = auto_pilot
	var sfx = $SFX
	sfx.setup(player)
	player.sfx = sfx

func _adjust_light_for_renderer() -> void:
	# Workaround for godotengine/godot#90259:
	# Compatibility renderer makes shadowed lights overbright due to
	# sRGB multipass rendering. Disable shadows to avoid white surfaces.
	if RenderingServer.get_rendering_device() == null:
		$DirectionalLight3D.shadow_enabled = false

func set_quality(level: String) -> void:
	if level not in ["low", "mid", "high", "auto"]:
		return
	$TerrainManager.set_quality(level)
	$CityManager.set_quality(level)
	$CanyonManager.set_quality(level)

func switch_stage(stage_name: String) -> void:
	var terrain = $TerrainManager
	var city = $CityManager
	var canyon = $CanyonManager
	var player = $Player

	match stage_name:
		"terrain":
			city.deactivate()
			canyon.deactivate()
			terrain.setup(player)
		"city":
			terrain.deactivate()
			canyon.deactivate()
			city.activate(player)
		"canyon":
			terrain.deactivate()
			city.deactivate()
			canyon.activate(player)
		_:
			return

	player.respawn()
