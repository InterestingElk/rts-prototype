class_name SupplyMap
extends Node3D

# Supply and encirclement.
#
# The map is cut into a coarse grid. Every unit (and city) pushes "influence" into the cells around
# it; a side CONTROLS a cell when its influence there is strong enough and clearly beats the other
# side's. Supply then spreads out from each city, cell to cell, up to SUPPLY_RANGE, but can't enter
# a cell the enemy controls. A unit standing on a cell that supply reached is IN SUPPLY.
#
#   - too far from every city of its side -> out of supply (the reach limit)
#   - enemy-controlled ground cutting the way back -> out of supply (encirclement)
#
# Units read their result through Unit.in_supply (set here every UPDATE_INTERVAL seconds).
# V toggles the overlay: blue = your supplied ground, red = the enemy's.

@export var map_half_width: float = 50.0   # keep in sync with the ground plane / camera
@export var map_half_depth: float = 40.0

const CELL_SIZE: float = 4.0
const SUPPLY_RANGE: float = 45.0      # how far supply spreads from a city (ground distance)
const INFLUENCE_RADIUS: float = 8.0   # how far a unit's influence reaches
const CITY_INFLUENCE: float = 5.0     # a city counts as a strong point for its own side
const CONTROL_MIN: float = 0.5        # influence needed to control a cell (one infantry holds the ground right around it)
const CONTROL_RATIO: float = 1.5      # ... and it must beat the other side's influence by this factor
const UPDATE_INTERVAL: float = 0.5
const OVERLAY_Y: float = 0.04

var cols: int = 0
var rows: int = 0
var overlay_visible: bool = true

var _player_influence := PackedFloat32Array()
var _ai_influence := PackedFloat32Array()
var _player_dist := PackedFloat32Array()   # supply distance from the nearest city; INF = not supplied
var _ai_dist := PackedFloat32Array()
var _player_open := PackedFloat32Array()   # same, ignoring enemy-held ground (pure reach)
var _ai_open := PackedFloat32Array()

var _overlay: MeshInstance3D = null
var _timer: float = 0.0

func _ready() -> void:
	add_to_group("supply_maps")
	cols = ceili(map_half_width * 2.0 / CELL_SIZE)
	rows = ceili(map_half_depth * 2.0 / CELL_SIZE)
	_player_influence.resize(cols * rows)
	_ai_influence.resize(cols * rows)
	_player_dist.resize(cols * rows)
	_ai_dist.resize(cols * rows)
	_player_open.resize(cols * rows)
	_ai_open.resize(cols * rows)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	_overlay = MeshInstance3D.new()
	_overlay.material_override = mat
	_overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_overlay)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_V:
		overlay_visible = not overlay_visible
		_overlay.visible = overlay_visible
		if overlay_visible:
			_rebuild_overlay()

func _process(delta: float) -> void:
	_timer -= delta
	if _timer <= 0.0:
		_timer = UPDATE_INTERVAL
		update_supply()

# ---------------------------------------------------------------------------
# Public
# ---------------------------------------------------------------------------

func is_supplied(pos: Vector3, player_side: bool) -> bool:
	var dist: PackedFloat32Array = _player_dist if player_side else _ai_dist
	return dist[_index(_cell_of(pos))] < INF

# Cut off = close enough to a city of its side to be supplied, but enemy-held ground blocks the way.
# (A unit that is simply too far away is out of supply but NOT cut off.)
func is_cut_off(pos: Vector3, player_side: bool) -> bool:
	var i: int = _index(_cell_of(pos))
	if player_side:
		return _player_open[i] < INF and _player_dist[i] == INF
	return _ai_open[i] < INF and _ai_dist[i] == INF

func update_supply() -> void:
	_compute_influence()
	_player_dist = _spread(true)
	_ai_dist = _spread(false)
	_player_open = _spread(true, true)
	_ai_open = _spread(false, true)
	for u: Unit in get_tree().get_nodes_in_group("player_units"):
		if is_instance_valid(u):
			u.in_supply = _player_dist[_index(_cell_of(u.global_position))] < INF
	for u: Unit in get_tree().get_nodes_in_group("ai_units"):
		if is_instance_valid(u):
			u.in_supply = _ai_dist[_index(_cell_of(u.global_position))] < INF
	if overlay_visible:
		_rebuild_overlay()

# ---------------------------------------------------------------------------
# Grid helpers
# ---------------------------------------------------------------------------

func _cell_of(pos: Vector3) -> Vector2i:
	return Vector2i(
		clampi(floori((pos.x + map_half_width) / CELL_SIZE), 0, cols - 1),
		clampi(floori((pos.z + map_half_depth) / CELL_SIZE), 0, rows - 1))

func _index(cell: Vector2i) -> int:
	return cell.y * cols + cell.x

func _cell_center(x: int, z: int) -> Vector2:
	return Vector2(-map_half_width + (float(x) + 0.5) * CELL_SIZE, -map_half_depth + (float(z) + 0.5) * CELL_SIZE)

# ---------------------------------------------------------------------------
# Influence and control
# ---------------------------------------------------------------------------

func _compute_influence() -> void:
	_player_influence.fill(0.0)
	_ai_influence.fill(0.0)
	for u: Unit in get_tree().get_nodes_in_group("player_units"):
		if is_instance_valid(u):
			_add_influence(_player_influence, u.global_position, _unit_weight(u))
	for u: Unit in get_tree().get_nodes_in_group("ai_units"):
		if is_instance_valid(u):
			_add_influence(_ai_influence, u.global_position, _unit_weight(u))
	for city: Node3D in get_tree().get_nodes_in_group("cities"):
		if is_instance_valid(city):
			_add_influence(_player_influence if city.is_player_city else _ai_influence, city.global_position, CITY_INFLUENCE)

# Tanks count for more than infantry; badly hurt units count for less
func _unit_weight(u: Unit) -> float:
	return u.max_health / 100.0 * clampf(u.get_health_fraction(), 0.3, 1.0)

func _add_influence(arr: PackedFloat32Array, pos: Vector3, weight: float) -> void:
	var c: Vector2i = _cell_of(pos)
	var span: int = ceili(INFLUENCE_RADIUS / CELL_SIZE)
	for dz in range(-span, span + 1):
		for dx in range(-span, span + 1):
			var x: int = c.x + dx
			var z: int = c.y + dz
			if x < 0 or z < 0 or x >= cols or z >= rows:
				continue
			var d: float = (_cell_center(x, z) - Vector2(pos.x, pos.z)).length()
			if d <= INFLUENCE_RADIUS:
				arr[z * cols + x] += weight * (1.0 - d / INFLUENCE_RADIUS)

# Is this cell held by the enemy of `player_side`?
func _blocked(index: int, player_side: bool) -> bool:
	var own: float = _player_influence[index] if player_side else _ai_influence[index]
	var enemy: float = _ai_influence[index] if player_side else _player_influence[index]
	return enemy >= CONTROL_MIN and enemy >= own * CONTROL_RATIO

# ---------------------------------------------------------------------------
# Supply spreading
# ---------------------------------------------------------------------------

func _spread(player_side: bool, ignore_enemy: bool = false) -> PackedFloat32Array:
	var dist := PackedFloat32Array()
	dist.resize(cols * rows)
	dist.fill(INF)

	var queue: Array[int] = []
	for city: Node3D in get_tree().get_nodes_in_group("cities"):
		if is_instance_valid(city) and city.is_player_city == player_side:
			var i: int = _index(_cell_of(city.global_position))
			dist[i] = 0.0
			queue.append(i)

	var head: int = 0
	while head < queue.size():
		var i: int = queue[head]
		head += 1
		var cz: int = floori(float(i) / float(cols))
		var cx: int = i - cz * cols
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dz == 0:
					continue
				var nx: int = cx + dx
				var nz: int = cz + dz
				if nx < 0 or nz < 0 or nx >= cols or nz >= rows:
					continue
				var diagonal: bool = dx != 0 and dz != 0
				var nd: float = dist[i] + CELL_SIZE * (1.4142 if diagonal else 1.0)
				if nd > SUPPLY_RANGE:
					continue
				var ni: int = nz * cols + nx
				if nd >= dist[ni]:
					continue
				if not ignore_enemy:
					if _blocked(ni, player_side):
						continue
					# No squeezing through a diagonal gap between two enemy-held cells
					if diagonal and _blocked(cz * cols + nx, player_side) and _blocked(nz * cols + cx, player_side):
						continue
				dist[ni] = nd
				queue.append(ni)
	return dist

# ---------------------------------------------------------------------------
# Overlay: one coloured quad per supplied cell
# ---------------------------------------------------------------------------

func _rebuild_overlay() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var quads: int = 0
	for z in rows:
		for x in cols:
			var i: int = z * cols + x
			var mine: bool = _player_dist[i] < INF
			var theirs: bool = _ai_dist[i] < INF
			if not mine and not theirs:
				continue
			var base: Color
			if mine and theirs:
				base = Color(0.8, 0.45, 1.0)
			elif mine:
				base = Color(0.3, 0.6, 1.0)
			else:
				base = Color(1.0, 0.35, 0.3)
			# The edge of supplied ground is drawn stronger so the front line is easy to read
			var alpha: float = 0.5 if _is_frontier(x, z, mine, theirs) else 0.26
			var color := Color(base.r, base.g, base.b, alpha)
			var x0: float = -map_half_width + float(x) * CELL_SIZE
			var z0: float = -map_half_depth + float(z) * CELL_SIZE
			var x1: float = x0 + CELL_SIZE
			var z1: float = z0 + CELL_SIZE
			for v in [Vector3(x0, OVERLAY_Y, z0), Vector3(x1, OVERLAY_Y, z0), Vector3(x1, OVERLAY_Y, z1),
					Vector3(x0, OVERLAY_Y, z0), Vector3(x1, OVERLAY_Y, z1), Vector3(x0, OVERLAY_Y, z1)]:
				st.set_color(color)
				st.add_vertex(v)
			quads += 1
	_overlay.mesh = st.commit() if quads > 0 else null

# A supplied cell next to a cell that is not supplied (for the same side) or the map edge of nothing
func _is_frontier(x: int, z: int, mine: bool, theirs: bool) -> bool:
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var nx: int = x + d.x
		var nz: int = z + d.y
		if nx < 0 or nz < 0 or nx >= cols or nz >= rows:
			continue
		var ni: int = nz * cols + nx
		if mine and _player_dist[ni] == INF:
			return true
		if theirs and _ai_dist[ni] == INF:
			return true
	return false
