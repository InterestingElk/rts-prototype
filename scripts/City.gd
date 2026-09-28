extends Node3D

# --- Resource stockpiles ---
var manpower: float = 150.0
var steel: float = 200.0
var oil: float = 20.0   # small starting stock; the oil field in the middle of the map pays more

# --- Regen rates (per second, derived from per-minute design numbers) ---
const MANPOWER_REGEN_PER_SEC: float = 2.0 / 60.0
const STEEL_INCOME_PER_SEC: float = 5.0 / 60.0

# --- Infantry recruit cost/time ---
const INFANTRY_MANPOWER_COST: float = 15.0
const INFANTRY_STEEL_COST: float = 10.0
const INFANTRY_RECRUIT_TIME: float = 20.0

@export var infantry_scene: PackedScene
@export var is_player_city: bool = true

var recruit_timer: float = 0.0
var is_recruiting: bool = false

const OVERRUN_UNIT_COUNT: int = 5
const OVERRUN_CHECK_RADIUS: float = 15.0

signal overrun

# --- Trickle-back ---
const TRICKLE_BACK_DURATION: float = 60.0
var trickle_back_batches: Array = [] # each entry: {amount: float}

signal resources_changed(manpower: float, steel: float)
signal infantry_recruited(unit: Node3D)
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

	if is_recruiting:
		recruit_timer -= delta
		if recruit_timer <= 0.0:
			_finish_recruit()

func try_recruit_infantry() -> bool:
	if is_recruiting:
		return false
	if manpower < INFANTRY_MANPOWER_COST or steel < INFANTRY_STEEL_COST:
		return false

	manpower -= INFANTRY_MANPOWER_COST
	steel -= INFANTRY_STEEL_COST
	is_recruiting = true
	recruit_timer = INFANTRY_RECRUIT_TIME
	resources_changed.emit(manpower, steel)
	return true

func _finish_recruit() -> void:
	is_recruiting = false
	var unit = infantry_scene.instantiate()
	unit.is_player_unit = is_player_city
	get_tree().current_scene.add_child(unit)

	var direction_x: float = 1.0 if is_player_city else -1.0
	var offset := Vector3(direction_x * (6 + randf_range(-2.0, 2.0)), 0, randf_range(-4.0, 4.0))
	unit.global_position = global_position + offset
	infantry_recruited.emit(unit)

func add_oil(amount: float) -> void:
	oil += amount
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
