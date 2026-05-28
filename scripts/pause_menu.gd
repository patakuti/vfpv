extends CanvasLayer

signal resume_pressed
signal settings_pressed

var _ui_scale: float = 1.0

func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	_ui_scale = _compute_ui_scale()
	_build_ui()

func _compute_ui_scale() -> float:
	var dpi := float(DisplayServer.screen_get_dpi())
	if dpi <= 0.0:
		return 1.0
	var window := Vector2(DisplayServer.window_get_size())
	var content_scale := minf(window.x / 1920.0, window.y / 1080.0)
	if content_scale <= 0.0:
		return 1.0
	return clampf((dpi / 320.0) / content_scale, 0.5, 3.0)

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0, 0, 0, 0.6)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)

	# Panel anchored to fill center of screen — guarantees all buttons fit
	var panel := Panel.new()
	panel.anchor_left = 0.2
	panel.anchor_top = 0.05
	panel.anchor_right = 0.8
	panel.anchor_bottom = 0.95
	add_child(panel)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left",   int(30 * _ui_scale))
	margin.add_theme_constant_override("margin_right",  int(30 * _ui_scale))
	margin.add_theme_constant_override("margin_top",    int(20 * _ui_scale))
	margin.add_theme_constant_override("margin_bottom", int(20 * _ui_scale))
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", int(12 * _ui_scale))
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "PAUSED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", int(40 * _ui_scale))
	vbox.add_child(title)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, int(10 * _ui_scale))
	vbox.add_child(spacer)

	_make_button(vbox, "Resume", _on_resume_pressed)
	_make_button(vbox, "Settings", _on_settings_pressed)
	_make_button(vbox, "Quit", _on_quit_pressed)

func _make_button(parent: Node, label: String, callback: Callable) -> void:
	var btn := Button.new()
	btn.text = label
	# Expand to fill available height equally among all buttons
	btn.size_flags_vertical = Control.SIZE_EXPAND_FILL
	btn.add_theme_font_size_override("font_size", int(30 * _ui_scale))
	btn.pressed.connect(callback)
	parent.add_child(btn)

func show_menu() -> void:
	visible = true

func hide_menu() -> void:
	visible = false

func _on_resume_pressed() -> void:
	hide_menu()
	get_tree().paused = false
	resume_pressed.emit()

func _on_settings_pressed() -> void:
	settings_pressed.emit()

func _on_quit_pressed() -> void:
	get_tree().quit()
