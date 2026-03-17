extends Node3D

func _ready() -> void:
	var player = $Player
	var vi_input = $Player/ViInput
	var hud = $HUD
	hud.setup(player, vi_input)
	var terrain = $TerrainManager
	terrain.setup(player)
