extends Control

# Floating vertical slider shown while the right-half altitude touch is held.
# Draws a bar centered on the touch-down point and a knob at the finger.

const BAR_WIDTH: float = 10.0
const KNOB_RADIUS: float = 22.0
const BAR_COLOR := Color(1, 1, 1, 0.35)
const CENTER_COLOR := Color(1, 1, 1, 0.7)
const KNOB_COLOR := Color(1, 1, 1, 0.85)

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
	var half_len: float = _input.ALTITUDE_FULL_PX
	draw_rect(Rect2(origin.x - BAR_WIDTH * 0.5, origin.y - half_len, BAR_WIDTH, half_len * 2.0),
			BAR_COLOR)
	draw_line(origin + Vector2(-BAR_WIDTH * 2.0, 0), origin + Vector2(BAR_WIDTH * 2.0, 0),
			CENTER_COLOR, 3.0)
	# Knob follows the finger vertically, clamped to the bar
	var knob_y: float = clampf(_input.altitude_touch_pos.y, origin.y - half_len, origin.y + half_len)
	draw_circle(Vector2(origin.x, knob_y), KNOB_RADIUS, KNOB_COLOR)
