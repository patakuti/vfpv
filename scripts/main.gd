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
		"fuji", "miyajima":
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
	$TerrainManager.deactivate()
	$CityManager.deactivate()
	$CanyonManager.deactivate()
	$TubeManager.deactivate()
	real.activate()

	if location_id == "miyajima":
		_apply_sunset_lighting(real.LOCATIONS["miyajima"]["lat"], real.LOCATIONS["miyajima"]["lon"])

	var player = $Player
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

# Points the sun at its real astronomical position for the winter solstice
# golden hour at the given location (SolarPosition, verified against known
# reference facts — see scripts/solar_position.gd). Northern hemisphere
# winter solstice sunset swings the most south of due west, which is the
# classic angle for this location's famous sunset-torii photos. The warm
# color tint is an artistic addition on top of that real direction, not
# itself measured data.
const WINTER_SOLSTICE_MONTH: int = 12
const WINTER_SOLSTICE_DAY: int = 21
# Mt. Misen (~535m) sits close to the torii in the sun's direction; from a
# low, near-sea-level vantage the sun would be hidden behind it at the
# original 3deg target. 25deg clears a ~535m peak from ~1.15km away
# (535m / tan(25deg) =~ 1147m) — earlier in the golden hour, but still a low,
# warm-toned sun rather than an overhead one. This is a practical clearance
# margin, not a guarantee from every possible vantage point (closer than
# ~1.15km, the peak can still hide it).
const SUN_TARGET_ELEVATION_DEG: float = 25.0

func _apply_sunset_lighting(lat: float, lon: float) -> void:
	var utc := Time.get_datetime_dict_from_system(true)
	var sun := SolarPosition.find_evening_elevation(lat, lon, utc["year"], WINTER_SOLSTICE_MONTH, WINTER_SOLSTICE_DAY, SUN_TARGET_ELEVATION_DEG)
	var az := deg_to_rad(float(sun["azimuth_deg"]))
	var elev := deg_to_rad(float(sun["elevation_deg"]))

	# Compass azimuth (0=north=-Z, 90=east=+X, clockwise) + elevation to a
	# unit vector pointing from the scene toward the sun.
	var sun_dir := Vector3(sin(az) * cos(elev), sin(elev), -cos(az) * cos(elev))

	var light = $DirectionalLight3D
	light.look_at(light.global_position - sun_dir, Vector3.UP)
	light.light_color = Color(1.0, 0.72, 0.45)
