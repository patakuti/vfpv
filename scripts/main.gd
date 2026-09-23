extends Node3D

const SolarPosition = preload("res://scripts/solar_position.gd")

var _default_light_transform: Transform3D
var _default_light_color: Color

func _ready() -> void:
	_adjust_light_for_renderer()
	_default_light_transform = $DirectionalLight3D.transform
	_default_light_color = $DirectionalLight3D.light_color

	var player = $Player
	var vi_input = $Player/ViInput
	var hud = $HUD
	hud.setup(player, vi_input)
	var terrain = $TerrainManager
	terrain.setup(player)
	$Player/LowAltitudeParticles.real_terrain = $RealTerrainManager
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

	SettingsManager.apply_to_game(player, self)
	hud.show_startup()

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
	$TubeManager.set_quality(level)
	$RealTerrainManager.set_quality(level)

func switch_stage(stage_name: String) -> void:
	var terrain = $TerrainManager
	var city = $CityManager
	var canyon = $CanyonManager
	var tube = $TubeManager
	var real = $RealTerrainManager
	var player = $Player

	_reset_lighting()

	match stage_name:
		"terrain":
			city.deactivate()
			canyon.deactivate()
			tube.deactivate()
			real.deactivate()
			terrain.setup(player)
		"city":
			terrain.deactivate()
			canyon.deactivate()
			tube.deactivate()
			real.deactivate()
			city.activate(player)
		"canyon":
			terrain.deactivate()
			city.deactivate()
			tube.deactivate()
			real.deactivate()
			canyon.activate(player)
			var safe_pos: Vector3 = canyon.find_safe_spawn()
			player.set_spawn(safe_pos, Vector3.ZERO)
		"tube":
			terrain.deactivate()
			city.deactivate()
			canyon.deactivate()
			real.deactivate()
			tube.activate(player)
		"fuji", "miyajima", "goldengate":
			# Async: tiles are downloaded over the network. The stage swap
			# completes later in _on_real_terrain_ready/_on_real_terrain_failed
			# so the previous stage stays active while loading.
			if real.is_loading():
				return
			real.request_location(stage_name, self)
			return
		_:
			return

	player.respawn()

func _on_real_terrain_ready(location_id: String) -> void:
	var real = $RealTerrainManager
	var player = $Player
	$TerrainManager.deactivate()
	$CityManager.deactivate()
	$CanyonManager.deactivate()
	$TubeManager.deactivate()
	real.activate(player)

	var loc: Dictionary = real.LOCATIONS[location_id]
	if loc.has("lighting"):
		_apply_sunset_lighting(loc["lat"], loc["lon"], loc["lighting"])

	player.set_spawn(real.get_spawn_position(), real.get_spawn_rotation())
	player.respawn()

func _on_real_terrain_failed(_location_id: String, _reason: String) -> void:
	# Previous stage is untouched; the failure reason is surfaced via
	# RealTerrainManager.status_text, which HUD displays for a few seconds.
	pass

func _reset_lighting() -> void:
	var light = $DirectionalLight3D
	light.transform = _default_light_transform
	light.light_color = _default_light_color

# Points the sun at its real astronomical position for a given date/target
# elevation at the given location (SolarPosition, verified against known
# reference facts — see scripts/solar_position.gd). `lighting` comes from
# RealTerrainManager.LOCATIONS[location_id]["lighting"] — each location picks
# its own date and target elevation (see the comments on each LOCATIONS entry
# for why); this function itself is location-agnostic. The light_color tint
# is an artistic addition on top of the real sun direction, not itself
# measured data.
func _apply_sunset_lighting(lat: float, lon: float, lighting: Dictionary) -> void:
	var utc := Time.get_datetime_dict_from_system(true)
	var sun := SolarPosition.find_evening_elevation(lat, lon, utc["year"], lighting["month"], lighting["day"], lighting["target_elevation_deg"])
	var az := deg_to_rad(float(sun["azimuth_deg"]))
	var elev := deg_to_rad(float(sun["elevation_deg"]))

	# Compass azimuth (0=north=-Z, 90=east=+X, clockwise) + elevation to a
	# unit vector pointing from the scene toward the sun.
	var sun_dir := Vector3(sin(az) * cos(elev), sin(elev), -cos(az) * cos(elev))

	var light = $DirectionalLight3D
	light.look_at(light.global_position - sun_dir, Vector3.UP)
	light.light_color = lighting["light_color"]
