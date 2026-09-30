class_name Barracks
extends Building

# Recruits Infantry (I) and AT Infantry (G). Hotkeys only fire while the barracks is selected.

const INFANTRY_MANPOWER_COST: float = 15.0
const INFANTRY_STEEL_COST: float = 10.0
const INFANTRY_RECRUIT_TIME: float = 20.0

const AT_INFANTRY_MANPOWER_COST: float = 15.0
const AT_INFANTRY_STEEL_COST: float = 25.0   # costlier than plain infantry: the launcher is the expensive part
const AT_INFANTRY_RECRUIT_TIME: float = 25.0

@export var infantry_scene: PackedScene = preload("res://scenes/Infantry.tscn")
@export var at_infantry_scene: PackedScene = preload("res://scenes/ATInfantry.tscn")

func _ready() -> void:
	building_name = "Barracks"
	selection_radius = 2.5
	recruit_options = [
		{
			"key": "infantry", "name": "Infantry", "keycode": KEY_I,
			"manpower": INFANTRY_MANPOWER_COST, "steel": INFANTRY_STEEL_COST, "oil": 0.0,
			"time": INFANTRY_RECRUIT_TIME, "scene": infantry_scene,
			"signal": "infantry_recruited",   # AI wave logic listens for this on the City
		},
		{
			"key": "at_infantry", "name": "AT Infantry", "keycode": KEY_G,
			"manpower": AT_INFANTRY_MANPOWER_COST, "steel": AT_INFANTRY_STEEL_COST, "oil": 0.0,
			"time": AT_INFANTRY_RECRUIT_TIME, "scene": at_infantry_scene,
			"signal": "",
		},
	]
	super._ready()
