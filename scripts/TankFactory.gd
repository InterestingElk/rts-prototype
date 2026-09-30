class_name TankFactory
extends Building

# Recruits medium Tanks (T). Hotkey only fires while the tank factory is selected.

const TANK_MANPOWER_COST: float = 20.0
const TANK_STEEL_COST: float = 40.0
const TANK_OIL_COST: float = 10.0
const TANK_RECRUIT_TIME: float = 40.0

@export var tank_scene: PackedScene = preload("res://scenes/Tank.tscn")

func _ready() -> void:
	building_name = "Tank Factory"
	selection_radius = 3.0
	recruit_options = [
		{
			"key": "tank", "name": "Tank", "keycode": KEY_T,
			"manpower": TANK_MANPOWER_COST, "steel": TANK_STEEL_COST, "oil": TANK_OIL_COST,
			"time": TANK_RECRUIT_TIME, "scene": tank_scene,
			"signal": "",
		},
	]
	super._ready()
