extends Node3D

# Raycast configuration
const RAY_COUNT_H: int = 9       # horizontal fan: -4..0..+4
const RAY_COUNT_V: int = 3       # vertical fan: -1, 0, +1
const FAN_ANGLE_H: float = 15.0  # degrees between horizontal rays (total ±60°)
const FAN_ANGLE_V: float = 15.0  # degrees between vertical rays
const REACTION_TIME: float = 1.2 # seconds ahead to detect
const SMOOTHING: float = 6.0     # lerp speed (higher = faster response)

# Avoidance output (read by player)
var auto_yaw: float = 0.0    # -1..+1
var auto_pitch: float = 0.0  # -1..+1
var enabled: bool = false

# Smoothing targets
var _target_yaw: float = 0.0
var _target_pitch: float = 0.0

# Internals
var _rays_h: Array[RayCast3D] = []  # horizontal fan rays
var _rays_up: Array[RayCast3D] = [] # upward tilted rays
var _rays_dn: Array[RayCast3D] = [] # downward tilted rays
var _player: CharacterBody3D
var _returning_to_level: bool = false  # true only after auto vertical avoidance
const LEVEL_RETURN_STRENGTH: float = 0.6

func setup(player: CharacterBody3D) -> void:
	_player = player
	_build_rays()

func _build_rays() -> void:
	# Horizontal fan: 9 rays from -60° to +60°
	# Negate angle: Godot rotated(UP, +angle) goes LEFT, so negate to match index order
	for i in range(RAY_COUNT_H):
		var angle: float = -(i - (RAY_COUNT_H - 1) * 0.5) * FAN_ANGLE_H
		var ray := _create_ray(angle, 0.0)
		_rays_h.append(ray)

	# Upward tilted rays: positive pitch around RIGHT = upward in Godot
	for i in range(RAY_COUNT_V):
		var angle_h: float = -(i - (RAY_COUNT_V - 1) * 0.5) * FAN_ANGLE_H
		var ray := _create_ray(angle_h, FAN_ANGLE_V)
		_rays_up.append(ray)

	# Downward tilted rays
	for i in range(RAY_COUNT_V):
		var angle_h: float = -(i - (RAY_COUNT_V - 1) * 0.5) * FAN_ANGLE_H
		var ray := _create_ray(angle_h, -FAN_ANGLE_V)
		_rays_dn.append(ray)

func _create_ray(yaw_deg: float, pitch_deg: float) -> RayCast3D:
	var ray := RayCast3D.new()
	var dir := Vector3.FORWARD
	dir = dir.rotated(Vector3.UP, deg_to_rad(yaw_deg))
	dir = dir.rotated(Vector3.RIGHT, deg_to_rad(pitch_deg))
	ray.target_position = dir * 50.0
	ray.enabled = true
	ray.collide_with_areas = false
	ray.collide_with_bodies = true
	ray.set_meta("base_dir", dir)
	add_child(ray)
	return ray

func _physics_process(delta: float) -> void:
	if not enabled or not _player:
		_target_yaw = 0.0
		_target_pitch = 0.0
		auto_yaw = 0.0
		auto_pitch = 0.0
		return

	# Update ray lengths based on speed
	var ray_length: float = _player.speed * REACTION_TIME
	ray_length = max(ray_length, 20.0)
	for ray in _rays_h:
		ray.target_position = ray.get_meta("base_dir") * ray_length
	for ray in _rays_up:
		ray.target_position = ray.get_meta("base_dir") * ray_length
	for ray in _rays_dn:
		ray.target_position = ray.get_meta("base_dir") * ray_length

	# Calculate target avoidance values
	_target_yaw = 0.0
	_target_pitch = 0.0
	_calc_avoidance(ray_length)

	# Manual pitch input cancels return-to-level
	var vi_input: Node = _player.get_node("ViInput")
	if vi_input and vi_input.pitch_input != 0.0:
		_returning_to_level = false

	# Return-to-level: proportional correction, only cleared by manual pitch input
	if _target_pitch == 0.0 and _returning_to_level:
		var up := _player.global_transform.basis.y
		var tilt := acos(clamp(up.dot(Vector3.UP), -1.0, 1.0))
		if tilt > deg_to_rad(2.0):
			var forward := -_player.global_transform.basis.z
			var pitch_angle: float = asin(clamp(forward.y, -1.0, 1.0))
			_target_pitch = clamp(-pitch_angle / deg_to_rad(30.0), -1.0, 1.0) * LEVEL_RETURN_STRENGTH

	# Smooth toward target
	auto_yaw = lerp(auto_yaw, _target_yaw, SMOOTHING * delta)
	auto_pitch = lerp(auto_pitch, _target_pitch, SMOOTHING * delta)

func _calc_avoidance(ray_length: float) -> void:
	# Check ALL horizontal rays - find closest hit
	var closest_dist: float = ray_length
	var any_hit: bool = false
	for ray in _rays_h:
		if ray.is_colliding():
			var d: float = ray.global_position.distance_to(ray.get_collision_point())
			if d < closest_dist:
				closest_dist = d
			any_hit = true

	if not any_hit:
		return

	# Urgency: closer obstacle = stronger avoidance
	var urgency: float = clamp(1.0 - closest_dist / ray_length, 0.0, 1.0)

	# 1. Try horizontal avoidance (strongly preferred)
	var left_score: float = _calc_side_score(-1)
	var right_score: float = _calc_side_score(1)
	var best_side: float = max(left_score, right_score)

	if best_side > 0.0:
		if right_score >= left_score:
			_target_yaw = urgency
		else:
			_target_yaw = -urgency
		return

	# 2. Both sides completely blocked - try vertical avoidance
	# Skip if already returning to level (rays are unreliable while pitched)
	if _returning_to_level:
		return
	var up_clear: float = _check_vertical_clearance(_rays_up)
	var dn_clear: float = _check_vertical_clearance(_rays_dn)

	if up_clear >= dn_clear:
		_target_pitch = urgency
	else:
		_target_pitch = -urgency
	_returning_to_level = true

func _calc_side_score(side: int) -> float:
	# Score a side by counting clear rays, weighting outer rays more heavily.
	# Outer rays being clear means there IS an escape path on that side.
	var score: float = 0.0
	var center: int = RAY_COUNT_H / 2
	for i in range(RAY_COUNT_H):
		var offset: int = i - center
		if offset * side > 0:  # ray is on the requested side
			if not _rays_h[i].is_colliding():
				# Weight by distance from center: outer = more important
				var weight: float = abs(offset)
				score += weight
	return score

func _check_vertical_clearance(rays: Array[RayCast3D]) -> float:
	var clear_count: int = 0
	for ray in rays:
		if not ray.is_colliding():
			clear_count += 1
	return float(clear_count) / float(rays.size())

