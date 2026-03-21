extends GPUParticles3D

const ALTITUDE_THRESHOLD: float = 30.0

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

		# Combine altitude and speed
		var intensity: float = alt_ratio * speed_ratio
		amount_ratio = intensity
		emitting = intensity > 0.05

		# Scale particle velocity with player speed
		var mat := process_material as ParticleProcessMaterial
		if mat:
			mat.initial_velocity_min = 10.0 + speed_ratio * 20.0
			mat.initial_velocity_max = 20.0 + speed_ratio * 30.0
	else:
		emitting = false
