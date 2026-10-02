class_name Tank
extends Unit

# Medium tank: faster, tougher and harder-hitting than infantry, but it burns oil while it moves.
#
# Fuel comes from the global oil stockpile, which for now is the owning side's city (City.oil).
#   - Oil is spent only while the tank is actually moving (standing still and shooting is free).
#   - With no oil the tank cannot move, but it keeps its order and still shoots anything inside
#     its attack range, so a stranded tank turns into a pillbox. Its order resumes by itself
#     as soon as oil is available again.

# --- Tuning ---
const FUEL_PER_SECOND: float = 0.1     # oil burned per second of real movement (6 oil per minute)
const TANK_HEALTH: float = 300.0       # starting manpower AND equipment pools (infantry: 100 each)

var _own_city: Node3D = null

func _init() -> void:
	move_speed = 5.0        # infantry: 3.0
	attack_range = 4.0      # infantry: 1.5, so a tank shoots first while infantry close in
	notice_range = 12.0     # infantry: 8.0
	turn_speed = 4.0
	formation_spacing = 3.2
	selection_radius = 1.7  # the ring must be wider than the 1.4 x 2.4 hull or it hides inside it
	pick_radius = 1.4       # the hull is long, so clicks on the front or rear should still hit
	bar_height = 1.7        # health bar sits above the turret
	manpower_cost = 20.0    # what a tank costs to recruit; healing it is priced from this

	# Soft/hard attack profile (medium tank tier, locked in the design doc).
	# Light/heavy tank tiers are future work and would subclass Tank the same way this subclasses Unit.
	soft_attack = 12.0
	hard_attack = 8.0
	hard_type = HardType.HARD_VEHICLE
	soft_resist = 0.4
	hard_infantry_resist = 0.55
	hard_vehicle_resist = 0.35

func _ready() -> void:
	super._ready()
	manpower_health = TANK_HEALTH
	equipment_health = TANK_HEALTH
	max_health = TANK_HEALTH

func _get_own_city() -> Node3D:
	if _own_city == null or not is_instance_valid(_own_city):
		_own_city = _find_nearest_city()
	return _own_city

func _can_move() -> bool:
	var city := _get_own_city()
	return city == null or city.oil > 0.0

func _on_moved(delta: float) -> void:
	var city := _get_own_city()
	if city != null:
		city.spend_oil(FUEL_PER_SECOND * delta)
