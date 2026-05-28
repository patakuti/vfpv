extends Node

const SETTINGS_PATH := "user://settings.cfg"
const SECTION := "settings"

var min_speed: float = 30.0
var max_speed: float = 200.0
var ref_gravity: Vector3 = Vector3.DOWN
var quality: String = "auto"
var stage: String = "terrain"
var god_mode: bool = false
var camera_mode: String = "fpv"
var bgm_muted: bool = false

func _ready() -> void:
	load_settings()

func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	min_speed   = cfg.get_value(SECTION, "min_speed",   min_speed)
	max_speed   = cfg.get_value(SECTION, "max_speed",   max_speed)
	quality     = cfg.get_value(SECTION, "quality",     quality)
	stage       = cfg.get_value(SECTION, "stage",       stage)
	god_mode    = cfg.get_value(SECTION, "god_mode",    god_mode)
	camera_mode = cfg.get_value(SECTION, "camera_mode", camera_mode)
	bgm_muted   = cfg.get_value(SECTION, "bgm_muted",   bgm_muted)
	var rg: Array = cfg.get_value(SECTION, "ref_gravity", [ref_gravity.x, ref_gravity.y, ref_gravity.z])
	ref_gravity = Vector3(rg[0], rg[1], rg[2])

func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value(SECTION, "min_speed",   min_speed)
	cfg.set_value(SECTION, "max_speed",   max_speed)
	cfg.set_value(SECTION, "quality",     quality)
	cfg.set_value(SECTION, "stage",       stage)
	cfg.set_value(SECTION, "god_mode",    god_mode)
	cfg.set_value(SECTION, "camera_mode", camera_mode)
	cfg.set_value(SECTION, "bgm_muted",   bgm_muted)
	cfg.set_value(SECTION, "ref_gravity", [ref_gravity.x, ref_gravity.y, ref_gravity.z])
	cfg.save(SETTINGS_PATH)

func apply_to_game(player: Node, main: Node) -> void:
	if not player or not main:
		return
	player.god_mode = god_mode
	player._activate_camera(player.fpv_camera if camera_mode == "fpv" else player.follow_camera)
	main.switch_stage(stage)
	main.set_quality(quality)
	var bgm := main.get_node_or_null("BGM")
	if bgm:
		bgm.volume_db = -80.0 if bgm_muted else 0.0
