extends Node

# Level 1 AI (step 7):
#   - Barracks and Tank Factory run in parallel. Infantry is built whenever it is affordable;
#     a tank is built whenever tanks are below TANK_SHARE of the army and there is oil to build
#     AND fuel it. While a tank is wanted but not yet affordable, infantry only spends what
#     still leaves enough steel and manpower for that tank.
#   - Every time its army reaches the wave size, it launches an attack-move:
#       * oil field not owned by the AI (and no earlier wave already sent) -> go to the oil field
#       * otherwise -> attack the player's city
#   - Units sent to the oil field stay there as its garrison.

@export var ai_city: Node3D          # the City this controls
@export var ai_barracks: Building    # where infantry is recruited from
@export var player_city: Node3D      # attack target

const TANK_SHARE: float = 0.25       # aim for about 1 tank per 4 units in the army
const TANK_OIL_RESERVE: float = 10.0 # oil kept back for fuel on top of the tank's build cost
const RECRUIT_INTERVAL: float = 1.0

var wave_threshold: int = 5
var wave_units: Array[Node3D] = []   # recruited units waiting for the next wave
var oil_group: Array = []            # the last wave sent to the oil field (used to avoid sending two)

var _tank_factory: Building = null
var _deposit: OilDeposit = null
var _active: bool = true   # set false to halt recruiting/attacking (used by tests; not exposed in play)

func _ready() -> void:
	print("AIController ready!")
	_pick_new_threshold()

	# The tank factory and oil field are siblings that finish _ready() after this node, so wait
	# one frame before looking them up.
	await get_tree().process_frame
	_tank_factory = _find_tank_factory()
	_deposit = get_tree().get_first_node_in_group("oil_deposits") as OilDeposit

	ai_barracks.unit_recruited.connect(_on_unit_recruited)
	if _tank_factory != null:
		_tank_factory.unit_recruited.connect(_on_unit_recruited)
	else:
		push_warning("AIController: no AI TankFactory found, tanks disabled")

	_recruit_loop()

func _find_tank_factory() -> Building:
	for b in get_tree().get_nodes_in_group("ai_buildings"):
		if b is TankFactory:
			return b as Building
	return null

func _pick_new_threshold() -> void:
	wave_threshold = randi_range(3, 7)

# ---------------------------------------------------------------------------
# Production
# ---------------------------------------------------------------------------

func _recruit_loop() -> void:
	# Uses a SceneTreeTimer, which set_process(false) on this node does NOT stop -- _active is
	# the actual off switch.
	while true:
		await get_tree().create_timer(RECRUIT_INTERVAL).timeout
		if _active:
			_produce()

func _produce() -> void:
	var tank_wanted := _tank_wanted()
	if tank_wanted:
		_tank_factory.try_recruit("tank")

	# Infantry runs alongside the tank factory. If a tank is wanted but couldn't be paid for yet,
	# keep enough steel and manpower back that the tank stays affordable.
	var reserve_steel: float = 0.0
	var reserve_manpower: float = 0.0
	if tank_wanted and not _tank_factory.is_recruiting:
		reserve_steel = TankFactory.TANK_STEEL_COST
		reserve_manpower = TankFactory.TANK_MANPOWER_COST
	if ai_city.steel - Barracks.INFANTRY_STEEL_COST < reserve_steel:
		return
	if ai_city.manpower - Barracks.INFANTRY_MANPOWER_COST < reserve_manpower:
		return
	ai_barracks.try_recruit("infantry")

func _tank_wanted() -> bool:
	if _tank_factory == null or _tank_factory.is_recruiting:
		return false
	# Only build a tank if there is oil to build it AND some left over to run it
	if ai_city.oil < TankFactory.TANK_OIL_COST + TANK_OIL_RESERVE:
		return false

	# Army composition: living units plus whatever is in production right now
	var tanks: int = 0
	var total: int = 0
	for u in get_tree().get_nodes_in_group("ai_units"):
		if is_instance_valid(u):
			total += 1
			if u is Tank:
				tanks += 1
	if ai_barracks.is_recruiting:
		total += 1
	return float(tanks) < float(total + 1) * TANK_SHARE

func _on_unit_recruited(unit: Node3D) -> void:
	wave_units.append(unit)
	unit.died.connect(_on_unit_died)

	if wave_units.size() >= wave_threshold:
		_launch_wave()
		_pick_new_threshold()

func _on_unit_died(unit: Node3D) -> void:
	wave_units.erase(unit)

# ---------------------------------------------------------------------------
# Waves
# ---------------------------------------------------------------------------

func _launch_wave() -> void:
	var group: Array = _alive(wave_units)
	wave_units.clear()
	if group.is_empty():
		return

	if _wants_oil():
		oil_group = group
		_send(group, _deposit.global_position)
	else:
		# Gather on the near side of the player's city, fighting anything met on the way
		var toward_ai := (ai_city.global_position - player_city.global_position).normalized()
		_send(group, player_city.global_position + toward_ai * 4.0)

# Go for the oil if we don't own it and an earlier oil wave isn't still alive
func _wants_oil() -> bool:
	if _deposit == null:
		return false
	if _deposit.controller == OilDeposit.Controller.AI:
		return false
	return _alive(oil_group).is_empty()

func _send(group: Array, point: Vector3) -> void:
	var destinations := Unit.formation_for(group, point)
	for i in group.size():
		group[i].attack_move_to(destinations[i])

func _alive(units: Array) -> Array:
	return units.filter(func(u): return is_instance_valid(u))
