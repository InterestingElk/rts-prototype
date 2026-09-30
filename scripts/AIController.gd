extends Node

# AI level 2: perception + counter-building.
#   - The AI only knows about player units that its own units, city or buildings have SPOTTED,
#     and forgets a sighting after MEMORY_TIME seconds without seeing that unit again.
#   - From what it knows, it adjusts what it builds:
#       * lots of enemy tanks known      -> build AT infantry
#       * enemy mostly plain infantry    -> lean on tanks
#       * enemy heavy on AT infantry     -> build fewer tanks
#   - Everything else is as before: Barracks and Tank Factory run in parallel, waves go to the
#     oil field if the AI doesn't own it, otherwise at the player's city.

@export var ai_city: Node3D          # the City this controls
@export var ai_barracks: Building    # where infantry / AT infantry are recruited from
@export var player_city: Node3D      # attack target

# --- Perception ---
const SIGHT_RANGE: float = 16.0      # how far units and buildings see (a bit past a tank's notice range)
const CITY_SIGHT_RANGE: float = 24.0
const SCAN_INTERVAL: float = 0.5
const MEMORY_TIME: float = 45.0      # seconds before an unseen enemy is forgotten

# --- Build tuning ---
const TANK_SHARE_DEFAULT: float = 0.25   # about 1 tank per 4 units in the army
const TANK_SHARE_VS_INFANTRY: float = 0.40
const TANK_SHARE_VS_AT: float = 0.10
const AT_PER_ENEMY_TANK: float = 1.5     # wants this many AT infantry per known enemy tank
const MIN_KNOWN_FOR_PLAN: int = 3        # need at least this many sightings before adapting
const TANK_OIL_RESERVE: float = 10.0     # oil kept back for fuel on top of the tank's build cost
const RECRUIT_INTERVAL: float = 1.0

var wave_threshold: int = 5
var wave_units: Array[Node3D] = []   # recruited units waiting for the next wave
var oil_group: Array = []            # the last wave sent to the oil field (used to avoid sending two)

# unit -> last time it was spotted (seconds). Only spotted units are in here.
var known_enemies: Dictionary = {}
var known_tanks: int = 0
var known_at: int = 0
var known_infantry: int = 0          # plain infantry (everything that is not a tank or AT infantry)

var _tank_factory: Building = null
var _deposit: OilDeposit = null
var _last_plan: String = ""
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

	_scan_loop()
	_recruit_loop()

func _find_tank_factory() -> Building:
	for b in get_tree().get_nodes_in_group("ai_buildings"):
		if b is TankFactory:
			return b as Building
	return null

func _pick_new_threshold() -> void:
	wave_threshold = randi_range(3, 7)

# ---------------------------------------------------------------------------
# Perception
# ---------------------------------------------------------------------------

func _scan_loop() -> void:
	while true:
		await get_tree().create_timer(SCAN_INTERVAL).timeout
		if _active:
			_scan()

func _scan() -> void:
	var now: float = Time.get_ticks_msec() / 1000.0

	# Everything on our side that can see: (position, range) pairs
	var eyes: Array = []
	for u in get_tree().get_nodes_in_group("ai_units"):
		if is_instance_valid(u):
			eyes.append([u.global_position, SIGHT_RANGE])
	for b in get_tree().get_nodes_in_group("ai_buildings"):
		if is_instance_valid(b):
			eyes.append([b.global_position, SIGHT_RANGE])
	if is_instance_valid(ai_city):
		eyes.append([ai_city.global_position, CITY_SIGHT_RANGE])

	# Spot player units
	for enemy in get_tree().get_nodes_in_group("player_units"):
		if not is_instance_valid(enemy):
			continue
		for e in eyes:
			if enemy.global_position.distance_to(e[0]) <= e[1]:
				known_enemies[enemy] = now
				break

	# Forget dead units and stale sightings, then recount
	known_tanks = 0
	known_at = 0
	known_infantry = 0
	for enemy in known_enemies.keys():
		if not is_instance_valid(enemy) or now - known_enemies[enemy] > MEMORY_TIME:
			known_enemies.erase(enemy)
			continue
		if enemy is Tank:
			known_tanks += 1
		elif enemy is ATInfantry:
			known_at += 1
		else:
			known_infantry += 1

func _known_total() -> int:
	return known_tanks + known_at + known_infantry

# ---------------------------------------------------------------------------
# Decisions (what the AI wants to build, given what it knows)
# ---------------------------------------------------------------------------

# How much of the army should be tanks
func _tank_share() -> float:
	var total: int = _known_total()
	if total < MIN_KNOWN_FOR_PLAN:
		return TANK_SHARE_DEFAULT
	if float(known_at) / float(total) >= 0.4:
		return TANK_SHARE_VS_AT           # they have anti-tank answers: tanks are a poor buy
	if float(known_infantry) / float(total) >= 0.7:
		return TANK_SHARE_VS_INFANTRY     # they have almost nothing that hurts tanks
	return TANK_SHARE_DEFAULT

# Do we want another AT infantry?
func _want_at() -> bool:
	if _known_total() < MIN_KNOWN_FOR_PLAN:
		return false
	return float(_at_count()) < float(known_tanks) * AT_PER_ENEMY_TANK

func _at_count() -> int:
	var n: int = 0
	for u in get_tree().get_nodes_in_group("ai_units"):
		if is_instance_valid(u) and u is ATInfantry:
			n += 1
	if ai_barracks.is_recruiting and ai_barracks.recruit_name == "AT Infantry":
		n += 1
	return n

# Print the AI's current read of the situation whenever it changes (handy for testing)
func _report_plan() -> void:
	var plan := "AI sees %d tanks, %d AT, %d infantry -> tank share %.2f, wants AT: %s" % [
		known_tanks, known_at, known_infantry, _tank_share(), str(_want_at())]
	if plan != _last_plan:
		_last_plan = plan
		print(plan)

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
	_report_plan()

	var tank_wanted := _tank_wanted()
	if tank_wanted:
		_tank_factory.try_recruit("tank")

	# Barracks runs alongside the tank factory. If a tank is wanted but couldn't be paid for yet,
	# keep enough steel and manpower back that the tank stays affordable.
	var reserve_steel: float = 0.0
	var reserve_manpower: float = 0.0
	if tank_wanted and not _tank_factory.is_recruiting:
		reserve_steel = TankFactory.TANK_STEEL_COST
		reserve_manpower = TankFactory.TANK_MANPOWER_COST

	var key: String = "at_infantry" if _want_at() else "infantry"
	var steel_cost: float = Barracks.AT_INFANTRY_STEEL_COST if key == "at_infantry" else Barracks.INFANTRY_STEEL_COST
	var manpower_cost: float = Barracks.AT_INFANTRY_MANPOWER_COST if key == "at_infantry" else Barracks.INFANTRY_MANPOWER_COST
	if ai_city.steel - steel_cost < reserve_steel:
		return
	if ai_city.manpower - manpower_cost < reserve_manpower:
		return
	ai_barracks.try_recruit(key)

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
	return float(tanks) < float(total + 1) * _tank_share()

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
