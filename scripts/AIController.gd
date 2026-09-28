extends Node

@export var ai_city: Node3D # the City this controls
@export var player_city: Node3D # attack target

var wave_threshold: int = 5
var wave_units: Array[Node3D] = []

func _ready() -> void:
	print("AIController ready!")
	ai_city.infantry_recruited.connect(_on_infantry_recruited)
	_pick_new_threshold()
	_try_recruit_loop()

func _pick_new_threshold() -> void:
	wave_threshold = randi_range(3, 7)

func _try_recruit_loop() -> void:
	# Keep attempting to recruit; City itself blocks double-recruiting
	while true:
		await get_tree().create_timer(1.0).timeout
		ai_city.try_recruit_infantry()

func _on_infantry_recruited(unit: Node3D) -> void:
	wave_units.append(unit)
	unit.died.connect(_on_unit_died)

	if wave_units.size() >= wave_threshold:
		_launch_attack()
		_pick_new_threshold()

func _launch_attack() -> void:
	var attackers: Array = []
	for unit in wave_units:
		if is_instance_valid(unit):
			attackers.append(unit)
	wave_units.clear()

	# Gather on the near side of the player's city, fighting anything met on the way
	var toward_ai := (ai_city.global_position - player_city.global_position).normalized()
	var approach_point := player_city.global_position + toward_ai * 4.0
	var destinations := Unit.formation_for(attackers, approach_point)
	for i in attackers.size():
		attackers[i].attack_move_to(destinations[i])

func _on_unit_died(unit: Node3D) -> void:
	wave_units.erase(unit)
