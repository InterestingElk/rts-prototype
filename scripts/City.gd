extends Node3D

# --- Resource stockpiles ---
var manpower: float = 150.0
var steel: float = 200.0
var oil: float = 20.0   # small starting stock; the oil field in the middle of the map pays more

# --- Regen rates (per second, derived from per-minute design numbers) ---
const MANPOWER_REGEN_PER_SEC: float = 2.0 / 60.0
const STEEL_INCOME_PER_SEC: float = 5.0 / 60.0

@export var is_player_city: bool = true

const OVERRUN_UNIT_COUNT: int = 5
const OVERRUN_CHECK_RADIUS: float = 15.0

signal overrun

# --- Trickle-back ---
const TRICKLE_BACK_DURATION: float = 60.0
var trickle_back_batches: Array = [] # each entry: {amount: float}

signal resources_changed(manpower: float, steel: float)
signal infantry_recruited(unit: Node3D)   # emitted by Barracks on this city's behalf; AI wave logic listens for it
signal oil_changed(oil: float)

func _ready() -> void:
	add_to_group("cities")

func _process(delta: float) -> void:
	_check_overrun()
	manpower += MANPOWER_REGEN_PER_SEC * delta
	steel += STEEL_INCOME_PER_SEC * delta

	for batch in trickle_back_batches:
		var rate: float = batch["amount"] / TRICKLE_BACK_DURATION
		var drain: float = min(rate * delta, batch["amount"])
		manpower += drain
		batch["amount"] -= drain

	trickle_back_batches = trickle_back_batches.filter(func(b): return b["amount"] > 0.0)

	resources_changed.emit(manpower, steel)

func add_oil(amount: float) -> void:
	oil += amount
	oil_changed.emit(oil)

# Fuel use. The stockpile can't go below zero.
func spend_oil(amount: float) -> void:
	oil = maxf(0.0, oil - amount)
	oil_changed.emit(oil)

func start_trickle_back(amount: float) -> void:
	trickle_back_batches.append({"amount": amount})

func _check_overrun() -> void:
	var enemy_group := "ai_units" if is_player_city else "player_units"
	var own_group := "player_units" if is_player_city else "ai_units"

	var nearby_enemies := 0
	for unit in get_tree().get_nodes_in_group(enemy_group):
		if not is_instance_valid(unit):
			continue
		if global_position.distance_to(unit.global_position) <= OVERRUN_CHECK_RADIUS:
			nearby_enemies += 1

	var nearby_own := 0
	for unit in get_tree().get_nodes_in_group(own_group):
		if not is_instance_valid(unit):
			continue
		if global_position.distance_to(unit.global_position) <= OVERRUN_CHECK_RADIUS:
			nearby_own += 1

	if nearby_enemies >= OVERRUN_UNIT_COUNT and nearby_own == 0:
		overrun.emit()
