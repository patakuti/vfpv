extends CanvasLayer

signal closed

var _player: Node
var _main: Node

var _min_speed_label: Label
var _max_speed_label: Label
var _min_slider: HSlider
var _max_slider: HSlider
var _stage_option: OptionButton
var _quality_option: OptionButton
var _god_check: Button
var _camera_option: OptionButton
var _bgm_mute_check: Button

var _ui_scale: float = 1.0
var _FONT_TITLE: int = 36
var _FONT_SECTION: int = 22
var _FONT_ITEM: int = 26
var _BTN_H: int = 80
var _ROW_H: int = 70

func _ready() -> void:
	layer = 11
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	_ui_scale = _compute_ui_scale()
	_FONT_TITLE   = int(36 * _ui_scale)
	_FONT_SECTION = int(22 * _ui_scale)
	_FONT_ITEM    = int(26 * _ui_scale)
	_BTN_H        = int(80 * _ui_scale)
	_ROW_H        = int(70 * _ui_scale)
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

func setup(player: Node, main: Node) -> void:
	_player = player
	_main = main

func show_screen() -> void:
	_sync_from_settings()
	visible = true

func hide_screen() -> void:
	visible = false

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0, 0, 0, 0.8)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)

	var panel := Panel.new()
	panel.anchor_left = 0.05
	panel.anchor_top = 0.04
	panel.anchor_right = 0.95
	panel.anchor_bottom = 0.96
	add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.add_child(scroll)

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", int(30 * _ui_scale))
	margin.add_theme_constant_override("margin_right", int(30 * _ui_scale))
	margin.add_theme_constant_override("margin_top", int(20 * _ui_scale))
	margin.add_theme_constant_override("margin_bottom", int(20 * _ui_scale))
	scroll.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", int(8 * _ui_scale))
	margin.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "Settings"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", _FONT_TITLE)
	vbox.add_child(title)
	vbox.add_child(HSeparator.new())

	# --- Sensor ---
	_section(vbox, "Sensor")
	vbox.add_child(_btn("Calibrate Tilt", _on_calibrate_pressed))
	vbox.add_child(HSeparator.new())

	# --- Speed ---
	_section(vbox, "Speed")
	_min_speed_label = Label.new()
	_min_speed_label.add_theme_font_size_override("font_size", _FONT_ITEM)
	vbox.add_child(_min_speed_label)
	_min_slider = _slider(vbox, 10.0, 150.0, 5.0, _on_min_speed_changed)

	_max_speed_label = Label.new()
	_max_speed_label.add_theme_font_size_override("font_size", _FONT_ITEM)
	vbox.add_child(_max_speed_label)
	_max_slider = _slider(vbox, 50.0, 300.0, 10.0, _on_max_speed_changed)
	vbox.add_child(HSeparator.new())

	# --- Stage ---
	_section(vbox, "Stage")
	_stage_option = _option(vbox, ["Terrain", "City", "Canyon"])
	vbox.add_child(HSeparator.new())

	# --- Quality ---
	_section(vbox, "Quality")
	_quality_option = _option(vbox, ["Low", "Mid", "High", "Auto"])
	vbox.add_child(HSeparator.new())

	# --- Game ---
	_section(vbox, "Game")
	var god_row := HBoxContainer.new()
	god_row.add_theme_constant_override("separation", 16)
	vbox.add_child(god_row)
	var god_lbl := Label.new()
	god_lbl.text = "God Mode"
	god_lbl.add_theme_font_size_override("font_size", _FONT_ITEM)
	god_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	god_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	god_row.add_child(god_lbl)
	_god_check = _make_toggle(god_row)

	var bgm_row := HBoxContainer.new()
	bgm_row.add_theme_constant_override("separation", 16)
	vbox.add_child(bgm_row)
	var bgm_lbl := Label.new()
	bgm_lbl.text = "Mute BGM"
	bgm_lbl.add_theme_font_size_override("font_size", _FONT_ITEM)
	bgm_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bgm_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bgm_row.add_child(bgm_lbl)
	_bgm_mute_check = _make_toggle(bgm_row)

	var cam_row := HBoxContainer.new()
	cam_row.add_theme_constant_override("separation", 16)
	vbox.add_child(cam_row)
	var cam_lbl := Label.new()
	cam_lbl.text = "Camera"
	cam_lbl.add_theme_font_size_override("font_size", _FONT_ITEM)
	cam_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cam_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cam_row.add_child(cam_lbl)
	_camera_option = OptionButton.new()
	_camera_option.custom_minimum_size = Vector2(int(160 * _ui_scale), _ROW_H)
	_camera_option.add_theme_font_size_override("font_size", _FONT_ITEM)
	_camera_option.add_item("FPV")
	_camera_option.add_item("Follow")
	cam_row.add_child(_camera_option)
	_camera_option.get_popup().add_theme_font_size_override("font_size", _FONT_ITEM)
	vbox.add_child(HSeparator.new())

	# --- Close ---
	vbox.add_child(_btn("Close", _on_close_pressed))
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 20)
	vbox.add_child(spacer)

func _section(parent: Node, text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", _FONT_SECTION)
	lbl.modulate = Color(0.7, 0.9, 1.0)
	parent.add_child(lbl)

func _btn(label: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(0, _BTN_H)
	btn.add_theme_font_size_override("font_size", _FONT_ITEM)
	btn.pressed.connect(callback)
	return btn

func _make_toggle(parent: Node) -> Button:
	var btn := Button.new()
	btn.toggle_mode = true
	btn.text = "OFF"
	btn.custom_minimum_size = Vector2(int(120 * _ui_scale), _ROW_H)
	btn.add_theme_font_size_override("font_size", _FONT_ITEM)
	btn.toggled.connect(func(pressed: bool) -> void: btn.text = "ON" if pressed else "OFF")
	parent.add_child(btn)
	return btn

func _slider(parent: Node, min_v: float, max_v: float, step: float, cb: Callable) -> HSlider:
	var s := HSlider.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.custom_minimum_size = Vector2(0, 50)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.value_changed.connect(cb)
	parent.add_child(s)
	return s

func _option(parent: Node, items: Array) -> OptionButton:
	var ob := OptionButton.new()
	ob.custom_minimum_size = Vector2(0, _ROW_H)
	ob.add_theme_font_size_override("font_size", _FONT_ITEM)
	for item in items:
		ob.add_item(item)
	parent.add_child(ob)
	# Popup is available after add_child; set font size for dropdown items
	ob.get_popup().add_theme_font_size_override("font_size", _FONT_ITEM)
	return ob

func _sync_from_settings() -> void:
	_min_slider.value = SettingsManager.min_speed
	_max_slider.value = SettingsManager.max_speed
	_update_speed_labels()

	var stages := ["terrain", "city", "canyon"]
	var si := stages.find(SettingsManager.stage)
	_stage_option.selected = si if si >= 0 else 0

	var qualities := ["low", "mid", "high", "auto"]
	var qi := qualities.find(SettingsManager.quality)
	_quality_option.selected = qi if qi >= 0 else 3

	_god_check.button_pressed = SettingsManager.god_mode
	_god_check.text = "ON" if SettingsManager.god_mode else "OFF"
	_bgm_mute_check.button_pressed = SettingsManager.bgm_muted
	_bgm_mute_check.text = "ON" if SettingsManager.bgm_muted else "OFF"

	var cameras := ["fpv", "follow"]
	var ci := cameras.find(SettingsManager.camera_mode)
	_camera_option.selected = ci if ci >= 0 else 0

func _update_speed_labels() -> void:
	_min_speed_label.text = "Min Speed: %d m/s" % int(_min_slider.value)
	_max_speed_label.text = "Max Speed: %d m/s" % int(_max_slider.value)

func _on_min_speed_changed(value: float) -> void:
	if value >= _max_slider.value:
		_max_slider.set_value_no_signal(value + _max_slider.step)
	_update_speed_labels()

func _on_max_speed_changed(value: float) -> void:
	if value <= _min_slider.value:
		_min_slider.set_value_no_signal(value - _min_slider.step)
	_update_speed_labels()

func _on_calibrate_pressed() -> void:
	if not _player:
		return
	var ai := _player.get_node_or_null("AndroidInput")
	if ai and ai.has_method("calibrate"):
		ai.calibrate()

func _on_close_pressed() -> void:
	_apply_and_save()
	hide_screen()
	closed.emit()

func _apply_and_save() -> void:
	SettingsManager.min_speed = _min_slider.value
	SettingsManager.max_speed = _max_slider.value

	var stages := ["terrain", "city", "canyon"]
	SettingsManager.stage = stages[_stage_option.selected]

	var qualities := ["low", "mid", "high", "auto"]
	SettingsManager.quality = qualities[_quality_option.selected]

	SettingsManager.god_mode = _god_check.button_pressed
	SettingsManager.bgm_muted = _bgm_mute_check.button_pressed

	var cameras := ["fpv", "follow"]
	SettingsManager.camera_mode = cameras[_camera_option.selected]

	SettingsManager.save_settings()
	if _player and _main:
		SettingsManager.apply_to_game(_player, _main)
