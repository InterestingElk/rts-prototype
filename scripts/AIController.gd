extends Node

# AI level 2: perception + counter-building.
#   - The AI only knows about player units that its own units, city or buildings have SPOTTED,
#     and forgets a sighting after MEMORY_TIME seconds without seeing that unit again.
#   - From what it knows, it adjusts what it builds:
#       * lots of enemy tanks known      -> build AT infantry
#       * enemy mostly plain infantry    -> lean on tanks
#       * enemy heavy on AT infantry     -> build fewer tanks
#   - Barracks and Tank Factory run in parallel.
#
# AI level 3: strength assessment + retreat.
#   - Every unit has a rough "power" (infantry 1, AT infantry 1, tank 3; own units scaled by
#     health). Before launching a wave the AI compares it to the power of the enemies it has
#     spotted near the target, and keeps massing units if it would be outgunned (defenders at
#     the player's city count extra). It attacks anyway once the army reaches MAX_WAVE_SIZE.
#   - Waves go to the oil field if the AI doesn't own it, otherwise at the player's city, and
#     arrive in formation. Units sent to the oil field hold ground there once it is captured.
#   - A group that finds itself outgunned (below RETREAT_RATIO of the enemy power near it)
#     falls back to its city, regroups, and rejoins the pool for the next wave.

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

# --- Strength assessment / retreat ---
const POWER_INFANTRY: float = 1.0
const POWER_AT: float = 1.0
const POWER_TANK: float = 3.0
const ATTACK_MARGIN_OIL: float = 1.0     # wave power must be at least this x the known enemy power at the oil field
const ATTACK_MARGIN_CITY: float = 1.3    # ... and this much at the player's city (defenders fight 30% tougher at home)
const OIL_THREAT_RADIUS: float = 22.0
const CITY_THREAT_RADIUS: float = 30.0
const MAX_WAVE_SIZE: int = 12            # attack regardless once the army is this big
const RETREAT_RATIO: float = 0.6         # retreat when own power < this x the enemy power nearby
const ENGAGE_RADIUS: float = 22.0        # how close known enemies must be to count as "the fight"
const RALLY_DISTANCE: float = 8.0        # retreat point: this far in front of the AI city, toward the player
const RETREAT_TIMEOUT: float = 25.0      # seconds before a retreating group counts as home regardless

var wave_threshold: int = 5
var wave_units: Array[Node3D] = []   # recruited units waiting for the next wave

# Waves that have been sent out. Each: {units, goal ("oil"/"city"), state ("advancing"/"garrison"/"retreating"), since}
var groups: Array = []

# unit -> {time, pos}: when and where it was last spotted. Only spotted units are in here.
var known_enemies: Dictionary = {}
var known_tanks: int = 0
var known_at: int = 0
var known_infantry: int = 0          # plain infantry (everything that is not a tank or AT infantry)

var _tank_factory: Building = null
var _deposit: OilDeposit = null
var _last_plan: String = ""
var _massing_reported: bool = false
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
			_update_groups()

func _scan() -> void:
	var now: float = _now()

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
				known_enemies[enemy] = {"time": now, "pos": enemy.global_position}
				break

	# Forget dead units and stale sightings, then recount
	known_tanks = 0
	known_at = 0
	known_infantry = 0
	for enemy in known_enemies.keys():
		if not is_instance_valid(enemy) or now - known_enemies[enemy]["time"] > MEMORY_TIME:
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
	_try_launch()

func _on_unit_died(unit: Node3D) -> void:
	wave_units.erase(unit)

# ---------------------------------------------------------------------------
# Strength assessment
# ---------------------------------------------------------------------------

func _unit_power(u: Node3D) -> float:
	if u is Tank:
		return POWER_TANK
	if u is ATInfantry:
		return POWER_AT
	return POWER_INFANTRY

# Our own units are worth less the more damaged they are
func _own_power(u: Node3D) -> float:
	var max_health: float = Tank.TANK_HEALTH if u is Tank else 100.0
	return _unit_power(u) * clampf(u.get_effective_health() / max_health, 0.0, 1.0)

func _group_power(units: Array) -> float:
	var total: float = 0.0
	for u in units:
		total += _own_power(u)
	return total

# Power of the enemies we have spotted within `radius` of `point`, where we last saw them
func _known_power_near(point: Vector3, radius: float) -> float:
	var total: float = 0.0
	for enemy in known_enemies.keys():
		if not is_instance_valid(enemy):
			continue
		var pos: Vector3 = known_enemies[enemy]["pos"]
		if Vector2(pos.x - point.x, pos.z - point.z).length() <= radius:
			total += _unit_power(enemy)
	return total

func _centroid(units: Array) -> Vector3:
	var c := Vector3.ZERO
	for u in units:
		c += u.global_position
	return c / float(units.size())

# ---------------------------------------------------------------------------
# Waves
# ---------------------------------------------------------------------------

func _try_launch() -> void:
	if wave_units.size() < wave_threshold:
		return
	var group: Array = _alive(wave_units)
	wave_units.assign(group)
	if group.size() < wave_threshold:
		return

	var goal: String = "oil" if _wants_oil() else "city"
	var threat: float
	var point: Vector3
	if goal == "oil":
		threat = _known_power_near(_deposit.global_position, OIL_THREAT_RADIUS) * ATTACK_MARGIN_OIL
		point = _deposit.global_position
	else:
		threat = _known_power_near(player_city.global_position, CITY_THREAT_RADIUS) * ATTACK_MARGIN_CITY
		var toward_ai := (ai_city.global_position - player_city.global_position).normalized()
		point = player_city.global_position + toward_ai * 4.0   # gather on the near side of the city

	var power: float = _group_power(group)
	if power < threat and group.size() < MAX_WAVE_SIZE:
		if not _massing_reported:
			_massing_reported = true
			print("AI holding wave of %d (power %.1f) vs %.1f known at the %s" % [group.size(), power, threat, goal])
		return

	_massing_reported = false
	print("AI launching wave of %d (power %.1f) at the %s (known enemy power there %.1f)" % [group.size(), power, goal, threat])
	wave_units.clear()
	_pick_new_threshold()
	groups.append({"units": group, "goal": goal, "state": "advancing", "since": _now()})
	Unit.formation_order(group, point, Vector3.ZERO, true)

# Go for the oil if we don't own it and no earlier oil wave is still out there
func _wants_oil() -> bool:
	if _deposit == null:
		return false
	if _deposit.controller == OilDeposit.Controller.AI:
		return false
	for g in groups:
		if g["goal"] == "oil" and g["state"] != "retreating":
			return false
	return true

# ---------------------------------------------------------------------------
# Groups in the field: garrison the oil, retreat when outgunned
# ---------------------------------------------------------------------------

func _update_groups() -> void:
	for g in groups.duplicate():
		var units: Array = _alive(g["units"])
		g["units"] = units
		if units.is_empty():
			groups.erase(g)
			continue

		if g["state"] == "retreating":
			if _now() - g["since"] > RETREAT_TIMEOUT or _all_idle(units):
				_rejoin(g)
			continue

		var centroid: Vector3 = _centroid(units)
		var threat: float = _known_power_near(centroid, ENGAGE_RADIUS)
		if threat > 0.0 and _group_power(units) < threat * RETREAT_RATIO:
			_begin_retreat(g, centroid, threat)
		elif g["goal"] == "oil" and g["state"] == "advancing" and _holding_oil(units):
			# Captured: stay and guard it (hold ground) instead of wandering off after enemies
			g["state"] = "garrison"
			print("AI group of %d garrisoning the oil field" % units.size())
			for u in units:
				u.stop()

func _holding_oil(units: Array) -> bool:
	if _deposit == null or _deposit.controller != OilDeposit.Controller.AI:
		return false
	for u in units:
		var flat := Vector2(u.global_position.x - _deposit.global_position.x, u.global_position.z - _deposit.global_position.z)
		if flat.length() > _deposit.control_radius:
			return false
	return true

func _all_idle(units: Array) -> bool:
	for u in units:
		if u.order != Unit.Order.NONE:
			return false
	return true

func _begin_retreat(g: Dictionary, centroid: Vector3, threat: float) -> void:
	print("AI group of %d retreating (power %.1f vs %.1f nearby)" % [g["units"].size(), _group_power(g["units"]), threat])
	g["state"] = "retreating"
	g["since"] = _now()
	var toward_player := (player_city.global_position - ai_city.global_position).normalized()
	var rally: Vector3 = ai_city.global_position + toward_player * RALLY_DISTANCE
	# Fall back to the rally point but end up facing the enemy
	Unit.formation_order(g["units"], rally, centroid - rally, false)

# A retreated group goes back into the pool for the next wave
func _rejoin(g: Dictionary) -> void:
	for u in g["units"]:
		if not wave_units.has(u):
			wave_units.append(u)
	groups.erase(g)
	_try_launch()

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _alive(units: Array) -> Array:
	return units.filter(func(u): return is_instance_valid(u))
