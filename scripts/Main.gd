extends Node3D

@onready var player_city: Node3D = $PlayerCity
@onready var ai_city: Node3D = $AICity

var game_over: bool = false

func _ready() -> void:
	player_city.overrun.connect(_on_player_defeated)
	ai_city.overrun.connect(_on_ai_defeated)

func _unhandled_input(event: InputEvent) -> void:
	if game_over:
		return
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_R:
			player_city.try_recruit_infantry()

func _on_player_defeated() -> void:
	if game_over:
		return
	game_over = true
	print("DEFEAT — your city has been overrun.")
	get_tree().paused = true

func _on_ai_defeated() -> void:
	if game_over:
		return
	game_over = true
	print("VICTORY — enemy city has been overrun.")
	get_tree().paused = true
