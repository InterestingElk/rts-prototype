class_name Unit
extends CharacterBody3D

# --- Team ---
@export var is_player_unit: bool = true

# --- Stats (vars, not consts, so other unit types like tanks can override them later) ---
@export var move_speed: float = 3.0
@export var attack_range: float = 1.5   # how close it must get to actually hit something
@export var notice_range: float = 8.0   # how far away it notices enemies (auto-engage)
@export var turn_speed: float = 10.0    # how fast it rotates to face where it is going / shooting
var attack_interval: float = 1.0

# --- Attack profile (soft/hard split; overridden per unit type) ---
# HARD_INFANTRY = infantry-carried AT (rifles, grenades, AT infantry, flak).
# HARD_VEHICLE  = vehicle-mounted AT (tank guns, dedicated AT guns, tank destroyers).
enum HardType { HARD_INFANTRY, HARD_VEHICLE }
var soft_attack: float = 10.0
var hard_attack: float = 2.0
var hard_type: HardType = HardType.HARD_INFANTRY

# --- Defense profile (how much of each incoming damage type is reduced) ---
var soft_resist: float = 0.0
var hard_infantry_resist: float = 0.65
var hard_vehicle_resist: float = 0.5
var formation_spacing: float = 1.6      # room this unit needs when a group is spread out
var selection_radius: float = 0.7       # outer radius of the green selection ring
var pick_radius: float = 0.7            # how close to its centre a click must land to select/target it

# --- Health pools ---
var manpower_health: float = 100.0
var equipment_health: float = 100.0

func get_effective_health() -> float:
	return min(manpower_health, equipment_health)

# --- Combat ---
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
#
# Stance while idle: a unit that has just finished an order (or was never given one) chases any
# enemy it notices. After Stop (S) it HOLDS GROUND instead: it only shoots enemies that come
# within its attack range and never walks after them. Any new order ends the hold.
enum Order { NONE, MOVE, ATTACK_MOVE, ATTACK_TARGET }

var hold_position: bool = false

# Formation extras (set by formation_order, cleared by any other order)
var order_facing: Vector3 = Vector3.ZERO   # direction to face once the order is done (zero = don't care)
var speed_limit: float = -1.0              # cap on march speed so a group arrives together (<= 0 = none)

var order: Order = Order.NONE
var order_position: Vector3 = Vector3.ZERO
var order_target: Node3D = null

var attack_timer: float = 0.0
var _stuck_time: float = 0.0
var _selection_ring: MeshInstance3D = null

const PLAYER_COLOR: Color = Color(0.3, 0.55, 1.0)
const ENEMY_COLOR: Color = Color(0.9, 0.3, 0.3)

signal died(unit: Node3D)

func _ready() -> void:
	add_to_group("player_units" if is_player_unit else "ai_units")
	_apply_team_color()

# Placeholder look: tint every mesh on the unit blue (yours) or red (enemy)
func _apply_team_color() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = PLAYER_COLOR if is_player_unit else ENEMY_COLOR
	for child in get_children():
		if child is MeshInstance3D:
			child.material_override = mat

# Hooks for vehicles (see Tank.gd). Infantry can always move and burns nothing.
func _can_move() -> bool:
	return true

func _on_moved(_delta: float) -> void:
	pass

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

func move_to(pos: Vector3, facing: Vector3 = Vector3.ZERO, limit: float = -1.0) -> void:
	hold_position = false
	order = Order.MOVE
	order_position = pos
	order_target = null
	order_facing = facing
	speed_limit = limit
	_stuck_time = 0.0

func attack_move_to(pos: Vector3, facing: Vector3 = Vector3.ZERO, limit: float = -1.0) -> void:
	hold_position = false
	order = Order.ATTACK_MOVE
	order_position = pos
	order_target = null
	order_facing = facing
	speed_limit = limit
	_stuck_time = 0.0

func attack_unit(enemy: Node3D) -> void:
	hold_position = false
	order = Order.ATTACK_TARGET
	order_target = enemy
	order_facing = Vector3.ZERO
	speed_limit = -1.0
	_stuck_time = 0.0

# Stop = drop the current order and hold ground (see the stance note above)
func stop() -> void:
	_finish_order()
	order_facing = Vector3.ZERO
	speed_limit = -1.0
	hold_position = true

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
	_move_toward(order_position, delta, true)

func _process_attack_move(delta: float) -> void:
	var enemy := _find_nearest_enemy()
	if enemy != null:
		_engage(enemy, delta)
		return
	if _at_destination():
		_finish_order()
		return
	_move_toward(order_position, delta, true)

func _process_attack_target(delta: float) -> void:
	if order_target == null or not is_instance_valid(order_target):
		_finish_order()
		return
	_engage(order_target, delta)

func _process_idle(delta: float) -> void:
	if hold_position:
		# Stand ground: only fire at what is already inside attack range, never move
		var target := _find_nearest_enemy(attack_range)
		if target != null:
			_try_attack(target, delta)
		else:
			_face_direction(order_facing, delta)
		return
	var enemy := _find_nearest_enemy()
	if enemy != null:
		_engage(enemy, delta)
	else:
		_face_direction(order_facing, delta) # settle into the formation's facing

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

# Nearest enemy within max_range (defaults to notice_range when max_range is left negative)
func _find_nearest_enemy(max_range: float = -1.0) -> Node3D:
	var enemy_group := "ai_units" if is_player_unit else "player_units"
	var nearest: Node3D = null
	var nearest_dist: float = notice_range if max_range < 0.0 else max_range

	for enemy in get_tree().get_nodes_in_group(enemy_group):
		if not is_instance_valid(enemy):
			continue
		var d := global_position.distance_to(enemy.global_position)
		if d < nearest_dist:
			nearest_dist = d
			nearest = enemy

	return nearest

# use_limit: marching to an order destination, so the formation's speed cap applies
# (chasing an enemy always runs at full speed).
func _move_toward(pos: Vector3, delta: float, use_limit: bool = false) -> void:
	var flat := pos - global_position
	flat.y = 0.0
	if flat.length() < 0.001:
		velocity = Vector3.ZERO
		return

	_face_direction(flat, delta)

	# Out of fuel: stand still but keep the order, so it resumes by itself when fuel returns.
	# Waiting for fuel is not the same as being blocked, so the stuck timer stays at zero.
	if not _can_move():
		velocity = Vector3.ZERO
		_stuck_time = 0.0
		return

	var speed: float = move_speed
	if use_limit and speed_limit > 0.0:
		speed = minf(move_speed, speed_limit)
	velocity = flat.normalized() * speed
	var before := global_position
	move_and_slide()

	# Track being blocked (e.g. by friendly units) so move orders can give up gracefully
	var moved := before.distance_to(global_position)
	if moved < speed * delta * 0.25:
		_stuck_time += delta
	else:
		_stuck_time = 0.0
		_on_moved(delta) # only real movement costs fuel

func _face_direction(direction: Vector3, delta: float) -> void:
	if direction.length() < 0.001:
		return
	var target_angle := atan2(-direction.x, -direction.z) # units face -Z
	rotation.y = lerp_angle(rotation.y, target_angle, clampf(turn_speed * delta, 0.0, 1.0))

func _try_attack(enemy: Node3D, delta: float) -> void:
	velocity = Vector3.ZERO
	_face_direction(enemy.global_position - global_position, delta)
	attack_timer -= delta
	if attack_timer <= 0.0:
		attack_timer = attack_interval
		if enemy.has_method("take_damage"):
			enemy.take_damage(soft_attack, hard_attack, hard_type)

func take_damage(atk_soft: float, atk_hard: float, atk_hard_type: HardType) -> void:
	var hard_resist: float = hard_infantry_resist if atk_hard_type == HardType.HARD_INFANTRY else hard_vehicle_resist
	var actual_amount: float = atk_soft * (1.0 - soft_resist) + atk_hard * (1.0 - hard_resist)
	if _is_near_own_city():
		actual_amount *= (1.0 - DEFENSE_DAMAGE_REDUCTION)

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
	torus.inner_radius = selection_radius - 0.15
	torus.outer_radius = selection_radius
	ring.mesh = torus

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 1.0, 0.3)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material_override = mat

	ring.position = Vector3(0.0, 0.05, 0.0)
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return ring

# ---------------------------------------------------------------------------
# Formations
#
# A group is laid out as a block of ranks facing `facing`: wider than it is deep, front rank
# first. Units are matched to slots by where they currently stand (front-most units take the
# front rank, left-most take the left of their rank) so they don't cross over each other.
# ---------------------------------------------------------------------------

const FORMATION_ASPECT: float = 2.0         # width is about sqrt(count * aspect) units
const MIN_FORMATION_SPEED_SHARE: float = 0.3  # slowest a unit is ever throttled, as a share of its top speed

# The facing to use: the one given, otherwise the direction the group has to travel.
static func resolve_facing(units: Array, center: Vector3, facing: Vector3) -> Vector3:
	var f := Vector3(facing.x, 0.0, facing.z)
	if f.length() < 0.001 and not units.is_empty():
		var centroid := Vector3.ZERO
		for u in units:
			centroid += u.global_position
		centroid /= float(units.size())
		f = Vector3(center.x - centroid.x, 0.0, center.z - centroid.z)
	if f.length() < 0.001:
		f = Vector3(0.0, 0.0, -1.0)
	return f.normalized()

# One destination per unit (same order as `units`)
static func formation_slots(units: Array, center: Vector3, facing: Vector3) -> Array[Vector3]:
	var count: int = units.size()
	var slots: Array[Vector3] = []
	if count == 0:
		return slots

	var f: Vector3 = resolve_facing(units, center, facing)
	var r: Vector3 = f.cross(Vector3.UP).normalized() # the group's right-hand side

	var spacing: float = 1.6
	for u in units:
		spacing = maxf(spacing, u.formation_spacing)

	var cols: int = mini(ceili(sqrt(float(count) * FORMATION_ASPECT)), count)
	var rows: int = ceili(float(count) / float(cols))

	# Front-most units first, then split into ranks and order each rank left to right
	var idx: Array = range(count)
	idx.sort_custom(func(a, b): return units[a].global_position.dot(f) > units[b].global_position.dot(f))

	slots.resize(count)
	for row in rows:
		var first: int = row * cols
		var last: int = mini(first + cols, count)
		var rank: Array = idx.slice(first, last)
		rank.sort_custom(func(a, b): return units[a].global_position.dot(r) < units[b].global_position.dot(r))
		var in_rank: int = rank.size()
		var depth: float = (float(rows - 1) * 0.5 - float(row)) * spacing
		for j in in_rank:
			var lateral: float = (float(j) - float(in_rank - 1) * 0.5) * spacing
			slots[rank[j]] = center + r * lateral + f * depth
	return slots

# Order a whole group to a point in formation. Everyone is throttled so the group arrives
# together (a move) or keeps pace with its slowest member (an attack-move).
static func formation_order(units: Array, center: Vector3, facing: Vector3, attack_move: bool) -> void:
	var slots := formation_slots(units, center, facing)
	if slots.is_empty():
		return
	var f: Vector3 = resolve_facing(units, center, facing)

	var longest_time: float = 0.0
	var slowest: float = INF
	for i in units.size():
		var flat: Vector3 = slots[i] - units[i].global_position
		flat.y = 0.0
		longest_time = maxf(longest_time, flat.length() / units[i].move_speed)
		slowest = minf(slowest, units[i].move_speed)

	for i in units.size():
		var flat: Vector3 = slots[i] - units[i].global_position
		flat.y = 0.0
		var limit: float = -1.0
		if attack_move:
			limit = slowest
		elif longest_time > 0.01:
			limit = maxf(flat.length() / longest_time, units[i].move_speed * MIN_FORMATION_SPEED_SHARE)
		if attack_move:
			units[i].attack_move_to(slots[i], f, limit)
		else:
			units[i].move_to(slots[i], f, limit)
