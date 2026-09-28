class_name Unit
extends CharacterBody3D

# --- Team ---
@export var is_player_unit: bool = true

# --- Stats (vars, not consts, so other unit types like tanks can override them later) ---
@export var move_speed: float = 3.0
@export var attack_range: float = 1.5   # how close it must get to actually hit something
@export var notice_range: float = 8.0   # how far away it notices enemies (auto-engage)

# --- Health pools ---
var manpower_health: float = 100.0
var equipment_health: float = 100.0

func get_effective_health() -> float:
	return min(manpower_health, equipment_health)

# --- Combat ---
const ATTACK_DAMAGE: float = 10.0
const ATTACK_INTERVAL: float = 1.0
const MANPOWER_DAMAGE_SHARE: float = 0.6
const EQUIPMENT_DAMAGE_SHARE: float = 0.4
const DEFENSE_BONUS_RADIUS: float = 15.0
const DEFENSE_DAMAGE_REDUCTION: float = 0.3 # 30% less damage taken near own city

# --- Movement ---
const ARRIVE_DISTANCE: float = 0.4    # close enough to a move destination
const STUCK_TIMEOUT: float = 0.6      # give up on a destination if blocked this long

# --- Orders ---
# MOVE: walk there, ignore enemies.  ATTACK_MOVE: walk there, fight anything met on the way.
# ATTACK_TARGET: chase and fight one specific enemy.  NONE: idle (still auto-engages in range).
enum Order { NONE, MOVE, ATTACK_MOVE, ATTACK_TARGET }

var order: Order = Order.NONE
var order_position: Vector3 = Vector3.ZERO
var order_target: Node3D = null

var attack_timer: float = 0.0
var _stuck_time: float = 0.0
var _selection_ring: MeshInstance3D = null

signal died(unit: Node3D)

func _ready() -> void:
	add_to_group("player_units" if is_player_unit else "ai_units")

func _physics_process(delta: float) -> void:
	match order:
		Order.MOVE:
			_process_move(delta)
		Order.ATTACK_MOVE:
			_process_attack_move(delta)
		Order.ATTACK_TARGET:
			_process_attack_target(delta)
		Order.NONE:
			_process_idle(delta)

# ---------------------------------------------------------------------------
# Public order API (used by SelectionManager and AIController)
# ---------------------------------------------------------------------------

func move_to(pos: Vector3) -> void:
	order = Order.MOVE
	order_position = pos
	order_target = null
	_stuck_time = 0.0

func attack_move_to(pos: Vector3) -> void:
	order = Order.ATTACK_MOVE
	order_position = pos
	order_target = null
	_stuck_time = 0.0

func attack_unit(enemy: Node3D) -> void:
	order = Order.ATTACK_TARGET
	order_target = enemy
	_stuck_time = 0.0

func stop() -> void:
	_finish_order()

func set_selected(value: bool) -> void:
	if value and _selection_ring == null:
		_selection_ring = _make_selection_ring()
		add_child(_selection_ring)
	if _selection_ring != null:
		_selection_ring.visible = value

# ---------------------------------------------------------------------------
# Order processing
# ---------------------------------------------------------------------------

func _process_move(delta: float) -> void:
	if _at_destination():
		_finish_order()
		return
	_move_toward(order_position, delta)

func _process_attack_move(delta: float) -> void:
	var enemy := _find_nearest_enemy()
	if enemy != null:
		_engage(enemy, delta)
		return
	if _at_destination():
		_finish_order()
		return
	_move_toward(order_position, delta)

func _process_attack_target(delta: float) -> void:
	if order_target == null or not is_instance_valid(order_target):
		_finish_order()
		return
	_engage(order_target, delta)

func _process_idle(delta: float) -> void:
	var enemy := _find_nearest_enemy()
	if enemy != null:
		_engage(enemy, delta)

func _finish_order() -> void:
	order = Order.NONE
	order_target = null
	velocity = Vector3.ZERO
	_stuck_time = 0.0

func _at_destination() -> bool:
	var flat := order_position - global_position
	flat.y = 0.0
	return flat.length() <= ARRIVE_DISTANCE or _stuck_time >= STUCK_TIMEOUT

# ---------------------------------------------------------------------------
# Movement + combat helpers
# ---------------------------------------------------------------------------

func _engage(enemy: Node3D, delta: float) -> void:
	var distance := global_position.distance_to(enemy.global_position)
	if distance > attack_range:
		_move_toward(enemy.global_position, delta)
	else:
		_try_attack(enemy, delta)

func _find_nearest_enemy() -> Node3D:
	var enemy_group := "ai_units" if is_player_unit else "player_units"
	var nearest: Node3D = null
	var nearest_dist: float = notice_range

	for enemy in get_tree().get_nodes_in_group(enemy_group):
		if not is_instance_valid(enemy):
			continue
		var d := global_position.distance_to(enemy.global_position)
		if d < nearest_dist:
			nearest_dist = d
			nearest = enemy

	return nearest

func _move_toward(pos: Vector3, delta: float) -> void:
	var flat := pos - global_position
	flat.y = 0.0
	if flat.length() < 0.001:
		velocity = Vector3.ZERO
		return

	velocity = flat.normalized() * move_speed
	var before := global_position
	move_and_slide()

	# Track being blocked (e.g. by friendly units) so move orders can give up gracefully
	var moved := before.distance_to(global_position)
	if moved < move_speed * delta * 0.25:
		_stuck_time += delta
	else:
		_stuck_time = 0.0

func _try_attack(enemy: Node3D, delta: float) -> void:
	velocity = Vector3.ZERO
	attack_timer -= delta
	if attack_timer <= 0.0:
		attack_timer = ATTACK_INTERVAL
		if enemy.has_method("take_damage"):
			enemy.take_damage(ATTACK_DAMAGE)

func take_damage(amount: float) -> void:
	var actual_amount := amount
	if _is_near_own_city():
		actual_amount = amount * (1.0 - DEFENSE_DAMAGE_REDUCTION)

	var manpower_lost: float = actual_amount * MANPOWER_DAMAGE_SHARE
	var equipment_lost: float = actual_amount * EQUIPMENT_DAMAGE_SHARE

	manpower_health -= manpower_lost
	equipment_health -= equipment_lost

	var trickle_amount: float = manpower_lost * 0.3
	var nearest_city := _find_nearest_city()
	if nearest_city:
		nearest_city.start_trickle_back(trickle_amount)

	if get_effective_health() <= 0.0:
		died.emit(self)
		queue_free()

func _is_near_own_city() -> bool:
	for city in get_tree().get_nodes_in_group("cities"):
		if not is_instance_valid(city):
			continue
		if city.is_player_city != is_player_unit:
			continue # only our own city counts
		if global_position.distance_to(city.global_position) <= DEFENSE_BONUS_RADIUS:
			return true
	return false

func _find_nearest_city() -> Node3D:
	var nearest: Node3D = null
	var nearest_dist: float = INF
	for city in get_tree().get_nodes_in_group("cities"):
		if not is_instance_valid(city):
			continue
		if city.is_player_city != is_player_unit:
			continue # only search cities on our own side
		var d := global_position.distance_to(city.global_position)
		if d < nearest_dist:
			nearest_dist = d
			nearest = city
	return nearest

# ---------------------------------------------------------------------------
# Selection ring (placeholder visual: a flat green ring on the ground)
# ---------------------------------------------------------------------------

func _make_selection_ring() -> MeshInstance3D:
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.55
	torus.outer_radius = 0.7
	ring.mesh = torus

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 1.0, 0.3)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material_override = mat

	ring.position = Vector3(0.0, 0.05, 0.0)
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return ring

# ---------------------------------------------------------------------------
# Formation helper: spread a group around a point so units don't all pile onto one spot.
# Returns one destination per unit (same order as `units`), each unit taking the nearest free slot.
# ---------------------------------------------------------------------------

static func formation_for(units: Array, center: Vector3, spacing: float = 1.6) -> Array[Vector3]:
	var result: Array[Vector3] = []
	var count: int = units.size()
	if count == 0:
		return result

	var cols: int = ceili(sqrt(float(count)))
	var rows: int = ceili(float(count) / float(cols))

	var slots: Array[Vector3] = []
	for i in count:
		var col: int = i % cols
		var row: int = floori(float(i) / float(cols))
		var offset := Vector3(
			(float(col) - (cols - 1) * 0.5) * spacing,
			0.0,
			(float(row) - (rows - 1) * 0.5) * spacing
		)
		slots.append(center + offset)

	var remaining: Array[Vector3] = []
	remaining.assign(slots)
	for unit in units:
		var best_index: int = 0
		var best_dist: float = INF
		for j in remaining.size():
			var d: float = unit.global_position.distance_squared_to(remaining[j])
			if d < best_dist:
				best_dist = d
				best_index = j
		result.append(remaining[best_index])
		remaining.remove_at(best_index)

	return result
