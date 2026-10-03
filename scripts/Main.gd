extends Node3D

@onready var player_city: Node3D = $PlayerCity
@onready var ai_city: Node3D = $AICity

var game_over: bool = false
var _elapsed: float = 0.0
var _debug_label: Label = null

func _ready() -> void:
	player_city.overrun.connect(_on_player_defeated)
	ai_city.overrun.connect(_on_ai_defeated)

	# Spatial grid: fast "who is near here?" lookups. Added first so it is ready before any unit exists.
	var grid := Node.new()
	grid.name = "SpatialGrid"
	grid.set_script(load("res://scripts/SpatialGrid.gd"))
	add_child(grid)

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
	if _debug_label != null:
		_debug_label.text = "FPS %d   player units %d   AI units %d" % [Engine.get_frames_per_second(),
			get_tree().get_nodes_in_group("player_units").size(), get_tree().get_nodes_in_group("ai_units").size()]

# ---------------------------------------------------------------------------
# Debug / stress test.  F3 = FPS and unit counts.  F5 = spawn 100 infantry per side facing off.
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F3:
			_toggle_debug_label()
		elif event.keycode == KEY_F5 and not game_over:
			_spawn_stress_armies(100)

func _toggle_debug_label() -> void:
	if _debug_label != null:
		_debug_label.get_parent().queue_free()
		_debug_label = null
		return
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	_debug_label = Label.new()
	_debug_label.position = Vector2(20.0, 260.0)
	layer.add_child(_debug_label)

func _spawn_stress_armies(per_side: int) -> void:
	var scene: PackedScene = load("res://scenes/Infantry.tscn")
	var cols: int = 10
	for side in 2:
		var is_player: bool = side == 0
		var x0: float = -24.0 if is_player else 0.0
		for i in per_side:
			var unit: Unit = scene.instantiate()
			unit.is_player_unit = is_player
			add_child(unit)
			unit.global_position = Vector3(x0 + float(i % cols) * 2.0, 0.0, -20.0 + float(floori(float(i) / float(cols))) * 2.0)

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
