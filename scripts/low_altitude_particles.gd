extends GPUParticles3D

const ALTITUDE_THRESHOLD: float = 30.0

const DUST_COLOR: Color = Color(0.95, 0.85, 0.5, 0.9)
const DUST_DIRECTION: Vector3 = Vector3(0, 1, 0.3)
const DUST_SPREAD: float = 40.0

# Whiter, flatter-spreading than the dust — reads as spray kicked up off the
# surface rather than dust kicked up off the ground.
const SPRAY_COLOR: Color = Color(0.85, 0.92, 0.95, 0.85)
const SPRAY_DIRECTION: Vector3 = Vector3(0, 0.4, 0.3)
const SPRAY_SPREAD: float = 60.0

var real_terrain: Node  # RealTerrainManager, set by main.gd; null off real-terrain stages

func _process(_delta: float) -> void:
	var player := get_parent() as CharacterBody3D
	if not player:
		return

	if player._is_crashed:
		emitting = false
		return

	# Raycast down to estimate altitude
	var space_state := get_world_3d().direct_space_state
	var from := player.global_position
	var to := from + Vector3.DOWN * ALTITUDE_THRESHOLD
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [player.get_rid()]
	var result: Dictionary = space_state.intersect_ray(query)

	if result:
		var altitude: float = from.y - result.position.y
		var alt_ratio: float = 1.0 - clamp(altitude / ALTITUDE_THRESHOLD, 0.0, 1.0)

		# Speed factor
		var current_speed: float = player.speed
		if player.is_boosting:
			current_speed *= player.BOOST_MULTIPLIER
		var speed_ratio: float = clamp(current_speed / player.MAX_SPEED, 0.0, 1.0)

		# Altitude alone drives how much shows — this is a proximity cue, so it
		# must stay clearly visible even at low cruising speed. Speed still
		# scales how fast the particles fly (below), just not whether/how many
		# appear.
		amount_ratio = alt_ratio
		emitting = alt_ratio > 0.05

		# Scale particle velocity with player speed
		var mat := process_material as ParticleProcessMaterial
		if mat:
			mat.initial_velocity_min = 10.0 + speed_ratio * 20.0
			mat.initial_velocity_max = 20.0 + speed_ratio * 30.0

			var over_water: bool = real_terrain != null and real_terrain.is_water_at_world_xz(result.position)
			mat.color = SPRAY_COLOR if over_water else DUST_COLOR
			mat.direction = SPRAY_DIRECTION if over_water else DUST_DIRECTION
			mat.spread = SPRAY_SPREAD if over_water else DUST_SPREAD
	else:
		emitting = false
