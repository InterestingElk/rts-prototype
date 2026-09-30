class_name ATInfantry
extends Unit

# AT infantry: same chassis and speed as regular infantry, equipped for anti-tank work instead.
# Weak against other infantry (soft attack 5, half of regular infantry's 10) but a real threat
# to armor, especially lighter vehicles -- tanks resist infantry-carried AT weapons much more
# than they resist vehicle guns, so a heavy tank is still a hard target even for AT infantry.

func _init() -> void:
	# Movement/selection/notice stats match plain infantry (Unit.gd's defaults), so nothing to set here.
	soft_attack = 5.0        # infantry: 10.0
	hard_attack = 16.0       # infantry: 2.0
	hard_type = HardType.HARD_INFANTRY
	# soft_resist / hard_infantry_resist / hard_vehicle_resist: same as infantry (Unit.gd's defaults)
