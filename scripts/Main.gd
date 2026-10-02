extends Node3D

@onready var player_city: Node3D = $PlayerCity
@onready var ai_city: Node3D = $AICity

var game_over: bool = false
var _elapsed: float = 0.0

func _ready() -> void:
	player_city.overrun.connect(_on_player_defeated)
	ai_city.overrun.connect(_on_ai_defeated)

	# Supply: who is connected to a city (units recover health only while supplied). V toggles the overlay.
	var supply := Node3D.new()
	supply.name = "SupplyMap"
	supply.set_script(load("res://scripts/SupplyMap.gd"))
	add_child(supply)

	# Health bars over damaged units (drawn in screen space, built here so no scene setup is needed)
	var bars := Node.new()
	bars.name = "HealthBars"
	bars.set_script(load("res://scripts/HealthBars.gd"))
	add_child(bars)

func _process(delta: float) -> void:
	if not game_over:
		_elapsed += delta

func _on_player_defeated() -> void:
	_end_game("DEFEAT", "Your city has been overrun.", Color(1.0, 0.4, 0.4))

func _on_ai_defeated() -> void:
	_end_game("VICTORY", "The enemy city has been overrun.", Color(0.4, 1.0, 0.5))

func _end_game(title: String, subtitle: String, color: Color) -> void:
	if game_over:
		return
	game_over = true
	print("%s - %s" % [title, subtitle])
	get_tree().paused = true
	_show_end_screen(title, subtitle, color)

# Dim overlay with the result and a Play again button. Its layer keeps running while the game is paused.
func _show_end_screen(title: String, subtitle: String, color: Color) -> void:
	var layer := CanvasLayer.new()
	layer.layer = 20
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(layer)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	center.add_child(box)

	var title_label := Label.new()
	title_label.text = title
	title_label.add_theme_font_size_override("font_size", 72)
	title_label.add_theme_color_override("font_color", color)
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title_label)

	var info := Label.new()
	var minutes: int = floori(_elapsed / 60.0)
	var seconds: int = int(_elapsed) % 60
	info.text = "%s\nTime: %d:%02d" % [subtitle, minutes, seconds]
	info.add_theme_font_size_override("font_size", 22)
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(info)

	var button := Button.new()
	button.text = "Play again"
	button.add_theme_font_size_override("font_size", 24)
	button.pressed.connect(_restart)
	box.add_child(button)

func _restart() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()
