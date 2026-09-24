extends Control

# Drone-transmitter throttle stick shown while the right-half altitude touch is held.
# Circular base centered on the touch-down point; the knob moves vertically only.

const BASE_FILL := Color(0.0, 0.0, 0.0, 0.25)
const BASE_RING := Color(1.0, 1.0, 1.0, 0.45)
const GROOVE_COLOR := Color(1.0, 1.0, 1.0, 0.25)
const DEADZONE_COLOR := Color(1.0, 1.0, 1.0, 0.35)
const ARROW_COLOR := Color(1.0, 1.0, 1.0, 0.45)
const KNOB_IDLE := Color(0.32, 0.32, 0.32, 0.95)
const KNOB_MAX := Color(0.16, 0.16, 0.16, 0.95)
const KNOB_EDGE := Color(1.0, 1.0, 1.0, 0.55)
const SHADOW_COLOR := Color(0.0, 0.0, 0.0, 0.3)
const KNOB_RADIUS_RATIO: float = 0.35  # of base radius

var player: CharacterBody3D
var _input: Node

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)

func _process(_delta: float) -> void:
	if _input == null and player:
		_input = player.get_node_or_null("AndroidInput")
	queue_redraw()

func _draw() -> void:
	if _input == null or not _input.altitude_touch_active:
		return
	var origin: Vector2 = _input.altitude_origin
	var base_r: float = _input.altitude_full_px
	var dead_r: float = _input.altitude_deadzone_px
	var knob_r: float = base_r * KNOB_RADIUS_RATIO

	# Base: disc, rim and vertical groove
	draw_circle(origin, base_r, BASE_FILL)
	draw_arc(origin, base_r, 0.0, TAU, 64, BASE_RING, 3.0, true)
	draw_line(origin + Vector2(0, -base_r), origin + Vector2(0, base_r), GROOVE_COLOR, knob_r * 0.5)

	# Dead zone and up/down arrows
	draw_arc(origin, dead_r, 0.0, TAU, 32, DEADZONE_COLOR, 2.0, true)
	var a := knob_r * 0.5
	for dir in [-1.0, 1.0]:
		var tip := origin + Vector2(0, dir * (base_r - a * 0.6))
		var base_y: float = tip.y - dir * a
		draw_colored_polygon(PackedVector2Array([
			tip, Vector2(tip.x - a * 0.8, base_y), Vector2(tip.x + a * 0.8, base_y)]), ARROW_COLOR)

	# Knob: follows the finger vertically, clamped to the base
	var knob_y: float = clampf(_input.altitude_touch_pos.y, origin.y - base_r, origin.y + base_r)
	var knob := Vector2(origin.x, knob_y)
	var color := KNOB_IDLE.lerp(KNOB_MAX, absf(_input.altitude_ratio))
	draw_circle(knob + Vector2(3, 5), knob_r, SHADOW_COLOR)
	draw_circle(knob, knob_r, color)
	draw_arc(knob, knob_r, 0.0, TAU, 32, KNOB_EDGE, 3.0, true)
	draw_circle(knob + Vector2(-knob_r * 0.25, -knob_r * 0.25), knob_r * 0.3,
			Color(1, 1, 1, 0.35))
