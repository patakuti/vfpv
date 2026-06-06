extends Node

# Procedural sound effects using AudioStreamGenerator

const MIX_RATE: int = 22050
const BUFFER_LENGTH: float = 0.1

# Crash sound
var _crash_player: AudioStreamPlayer
var _crash_playback: AudioStreamGeneratorPlayback
var _crash_timer: float = 0.0
const CRASH_DURATION: float = 0.4

# Boost sound
var _boost_player: AudioStreamPlayer
var _boost_playback: AudioStreamGeneratorPlayback
var _boost_phase: float = 0.0
var _boost_active: bool = false

# Drone propeller sound
var _drone_player: AudioStreamPlayer
var _drone_enabled: bool = false
var _drone_smooth_power: float = 0.3   # smoothed motor_power to avoid abrupt pitch jumps
var _drone_phases: Array[float] = [0.0, 0.0, 0.0, 0.0]
const DRONE_FREQ_OFFSETS: Array[float] = [1.00, 1.02, 0.98, 1.01]  # per-motor pitch variation
const DRONE_POWER_SMOOTH: float = 4.0  # how fast motor power tracks (1/s)
const DRONE_FREQ_MIN: float = 60.0     # Hz at minimum motor power
const DRONE_FREQ_MAX: float = 240.0    # Hz at full motor power

var player: CharacterBody3D

func setup(p_player: CharacterBody3D) -> void:
	player = p_player
	_crash_player = _create_generator_player(-6.0)
	_boost_player = _create_generator_player(-14.0)
	_drone_player = _create_generator_player(-4.0)

func _create_generator_player(volume_db: float) -> AudioStreamPlayer:
	var stream := AudioStreamGenerator.new()
	stream.mix_rate = MIX_RATE
	stream.buffer_length = BUFFER_LENGTH
	var asp := AudioStreamPlayer.new()
	asp.stream = stream
	asp.volume_db = volume_db
	asp.bus = "Master"
	add_child(asp)
	asp.play()
	return asp

func _process(delta: float) -> void:
	if not player:
		return

	_process_crash(delta)
	_process_boost(delta)
	_process_drone(delta)

# --- Crash: noise burst with exponential decay ---

func play_crash() -> void:
	_crash_timer = CRASH_DURATION

func _process_crash(_delta: float) -> void:
	var playback := _crash_player.get_stream_playback() as AudioStreamGeneratorPlayback
	if not playback:
		return

	var frames := playback.get_frames_available()
	if _crash_timer <= 0.0:
		for i in range(frames):
			playback.push_frame(Vector2.ZERO)
		return

	for i in range(frames):
		var t: float = _crash_timer
		var envelope: float = exp(-t * -8.0)  # decay
		envelope = clampf(1.0 - envelope, 0.0, 1.0)
		envelope = exp(-envelope * 6.0)
		var noise: float = randf_range(-1.0, 1.0) * envelope
		playback.push_frame(Vector2(noise, noise))
		_crash_timer -= 1.0 / MIX_RATE
		if _crash_timer <= 0.0:
			_crash_timer = 0.0
			break

# --- Boost: rising sine sweep ---

func set_boost_active(active: bool) -> void:
	_boost_active = active

func _process_boost(_delta: float) -> void:
	var playback := _boost_player.get_stream_playback() as AudioStreamGeneratorPlayback
	if not playback:
		return

	var frames := playback.get_frames_available()
	if not _boost_active:
		for i in range(frames):
			playback.push_frame(Vector2.ZERO)
		_boost_phase = 0.0
		return

	for i in range(frames):
		# Sweep from 80Hz to 200Hz
		var freq: float = lerp(80.0, 200.0, clampf(_boost_phase * 0.5, 0.0, 1.0))
		_boost_phase += 1.0 / MIX_RATE
		var sample: float = sin(_boost_phase * freq * TAU) * 0.5
		# Add some harmonics
		sample += sin(_boost_phase * freq * 2.0 * TAU) * 0.15
		sample += randf_range(-0.1, 0.1)  # slight noise texture
		playback.push_frame(Vector2(sample, sample))

# --- Wind: bandpass noise linked to pitch input ---

# --- Drone: 4-motor propeller sound with pitch tied to motor power ---

func set_drone_enabled(enabled: bool) -> void:
	_drone_enabled = enabled

func _process_drone(delta: float) -> void:
	var playback := _drone_player.get_stream_playback() as AudioStreamGeneratorPlayback
	if not playback:
		return

	var frames := playback.get_frames_available()
	if not _drone_enabled:
		for i in range(frames):
			playback.push_frame(Vector2.ZERO)
		_drone_smooth_power = 0.3
		return

	_drone_smooth_power = lerpf(_drone_smooth_power, player.motor_power, DRONE_POWER_SMOOTH * delta)
	var base_freq := lerpf(DRONE_FREQ_MIN, DRONE_FREQ_MAX, _drone_smooth_power)
	var dt := 1.0 / MIX_RATE

	for _f in range(frames):
		var sample := 0.0
		for i in range(4):
			var freq := base_freq * DRONE_FREQ_OFFSETS[i]
			_drone_phases[i] += freq * dt
			if _drone_phases[i] >= 1.0:
				_drone_phases[i] -= 1.0
			var p := _drone_phases[i] * TAU
			sample += sin(p) * 0.12           # fundamental
			sample += sin(p * 2.0) * 0.06     # 2nd harmonic
			sample += sin(p * 3.0) * 0.03     # 3rd harmonic
			sample += randf_range(-1.0, 1.0) * 0.008  # air turbulence noise
		playback.push_frame(Vector2(sample, sample))
