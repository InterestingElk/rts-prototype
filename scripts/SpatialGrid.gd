class_name SpatialGrid
extends Node

# Spatial grid: answers "who is near here?" without looking at every unit.
#
# The map is cut into square buckets. Once per physics frame (before any unit thinks) every unit
# is dropped into the bucket it stands in, one set of buckets per side. A query then only looks at
# the few buckets inside its radius instead of every enemy on the map, so the cost of a lookup
# depends on how crowded the neighbourhood is, not on how big the armies are.
#
# Units and the other systems reach it through SpatialGrid.instance. If it is missing they fall
# back to their old group scans, so nothing breaks if it isn't added.

static var instance: SpatialGrid = null

@export var map_half_width: float = 50.0   # keep in sync with the ground plane / camera
@export var map_half_depth: float = 40.0

const CELL_SIZE: float = 8.0        # about the size of a typical notice range
const FINE_CELL_SIZE: float = 3.0   # small buckets for "who is touching me?" (separation)
const MAX_TOUCHING: int = 6         # in a dense crowd, stop after this many overlapping neighbours

var cols: int = 0
var rows: int = 0
var fine_cols: int = 0
var fine_rows: int = 0
var _cells: Array = [[], []]   # [0] = player side, [1] = AI side; each is one Array of units per cell
var _fine: Array = [[], []]    # the same units again, in the small buckets

func _enter_tree() -> void:
	instance = self
	process_physics_priority = -100   # rebuild before any unit's _physics_process runs

func _exit_tree() -> void:
	if instance == self:
		instance = null

func _ready() -> void:
	cols = ceili(map_half_width * 2.0 / CELL_SIZE)
	rows = ceili(map_half_depth * 2.0 / CELL_SIZE)
	fine_cols = ceili(map_half_width * 2.0 / FINE_CELL_SIZE)
	fine_rows = ceili(map_half_depth * 2.0 / FINE_CELL_SIZE)
	for side in 2:
		_cells[side] = []
		for i in cols * rows:
			_cells[side].append([])
		_fine[side] = []
		for i in fine_cols * fine_rows:
			_fine[side].append([])

func _physics_process(_delta: float) -> void:
	_rebuild(0, "player_units")
	_rebuild(1, "ai_units")

func _rebuild(side: int, group: String) -> void:
	var buckets: Array = _cells[side]
	var fine: Array = _fine[side]
	for bucket in buckets:
		bucket.clear()
	for bucket in fine:
		bucket.clear()
	for u: Node3D in get_tree().get_nodes_in_group(group):
		if is_instance_valid(u):
			var pos: Vector3 = u.global_position
			buckets[_index_of(pos)].append(u)
			fine[_fine_index_of(pos)].append(u)

# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

# Nearest unit of a side within max_range (3D distance, strictly closer than max_range), or null.
func nearest_unit(pos: Vector3, player_side: bool, max_range: float) -> Node3D:
	var buckets: Array = _cells[0 if player_side else 1]
	var span: int = ceili(max_range / CELL_SIZE)
	var cx: int = _col_of(pos.x)
	var cz: int = _row_of(pos.z)
	var best: Node3D = null
	var best_d2: float = max_range * max_range
	for z in range(maxi(0, cz - span), mini(rows - 1, cz + span) + 1):
		for x in range(maxi(0, cx - span), mini(cols - 1, cx + span) + 1):
			for u: Node3D in buckets[z * cols + x]:
				if not is_instance_valid(u):
					continue
				var d2: float = pos.distance_squared_to(u.global_position)
				if d2 < best_d2:
					best_d2 = d2
					best = u
	return best

# How many units of a side stand within `radius` of pos (flat distance, ignoring height).
func count_within(pos: Vector3, player_side: bool, radius: float) -> int:
	var buckets: Array = _cells[0 if player_side else 1]
	var span: int = ceili(radius / CELL_SIZE)
	var cx: int = _col_of(pos.x)
	var cz: int = _row_of(pos.z)
	var r2: float = radius * radius
	var count: int = 0
	for z in range(maxi(0, cz - span), mini(rows - 1, cz + span) + 1):
		for x in range(maxi(0, cx - span), mini(cols - 1, cx + span) + 1):
			for u: Node3D in buckets[z * cols + x]:
				if not is_instance_valid(u):
					continue
				var dx: float = u.global_position.x - pos.x
				var dz: float = u.global_position.z - pos.z
				if dx * dx + dz * dz <= r2:
					count += 1
	return count

# Sideways push that keeps `unit` from standing on top of friendly units (flat, ignores height).
# Each neighbour closer than the average of the two units' separation radii pushes it away, harder
# the deeper the overlap. Returns a vector of roughly length 0..1 per touching neighbour.
func separation_push(unit: Unit, player_side: bool, own_radius: float) -> Vector3:
	var buckets: Array = _fine[0 if player_side else 1]
	var pos: Vector3 = unit.global_position
	var cx: int = clampi(floori((pos.x + map_half_width) / FINE_CELL_SIZE), 0, fine_cols - 1)
	var cz: int = clampi(floori((pos.z + map_half_depth) / FINE_CELL_SIZE), 0, fine_rows - 1)
	var push := Vector3.ZERO
	var touching: int = 0
	for z in range(maxi(0, cz - 1), mini(fine_rows - 1, cz + 1) + 1):
		for x in range(maxi(0, cx - 1), mini(fine_cols - 1, cx + 1) + 1):
			for other: Unit in buckets[z * fine_cols + x]:
				if other == unit or not is_instance_valid(other):
					continue
				var dx: float = pos.x - other.global_position.x
				var dz: float = pos.z - other.global_position.z
				var limit: float = (own_radius + other.separation_radius) * 0.5
				var d2: float = dx * dx + dz * dz
				if d2 >= limit * limit:
					continue
				if d2 < 0.000001:
					# exactly on top of each other: pick a stable direction from the unit's id
					var angle: float = float(unit.get_instance_id() % 628) * 0.01
					push += Vector3(cos(angle), 0.0, sin(angle))
				else:
					var d: float = sqrt(d2)
					push += Vector3(dx, 0.0, dz) / d * ((limit - d) / limit)
				touching += 1
				if touching >= MAX_TOUCHING:
					return push
	return push

# ---------------------------------------------------------------------------
# Cell helpers (positions outside the map are clamped onto the edge cells)
# ---------------------------------------------------------------------------

func _col_of(x: float) -> int:
	return clampi(floori((x + map_half_width) / CELL_SIZE), 0, cols - 1)

func _row_of(z: float) -> int:
	return clampi(floori((z + map_half_depth) / CELL_SIZE), 0, rows - 1)

func _index_of(pos: Vector3) -> int:
	return _row_of(pos.z) * cols + _col_of(pos.x)

func _fine_index_of(pos: Vector3) -> int:
	var fx: int = clampi(floori((pos.x + map_half_width) / FINE_CELL_SIZE), 0, fine_cols - 1)
	var fz: int = clampi(floori((pos.z + map_half_depth) / FINE_CELL_SIZE), 0, fine_rows - 1)
	return fz * fine_cols + fx
