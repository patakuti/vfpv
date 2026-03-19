extends Node3D

func _ready() -> void:
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

func switch_stage(stage_name: String) -> void:
	var terrain = $TerrainManager
	var city = $CityManager
	var player = $Player

	match stage_name:
		"terrain":
			city.deactivate()
			terrain.setup(player)
		"city":
			terrain.deactivate()
			city.activate(player)
		_:
			return

	player.respawn()
