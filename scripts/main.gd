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
