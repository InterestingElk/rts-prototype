extends Node

# Classic RTS controls:
#   Left click / drag box ... select your units   (Shift = add to selection)
#   Right click ............. ground: move   |   enemy unit: attack it   |   enemy city: attack-move onto it
#   A, then left click ...... attack-move       (right click or Esc cancels)
#   S ....................... stop

# Map limits so orders can't send units off the edge (keep in sync with the ground plane / camera)
@export var map_half_width: float = 50.0
@export var map_half_depth: float = 40.0

const DRAG_THRESHOLD: float = 6.0          # pixels before a click becomes a drag box
const PICK_MIN_RADIUS: float = 0.7         # world units, for clicking on small units up close
const PICK_ANGULAR_RADIUS: float = 0.03    # grows with distance so units stay clickable zoomed out
const CITY_PICK_RADIUS: float = 3.5        # ground distance from a city's centre that counts as clicking it
const CITY_APPROACH_DISTANCE: float = 4.0  # how far in front of an enemy city attackers gather

var selected: Array = []
var attack_move_pending: bool = false

var _dragging: bool = false
var _drag_start: Vector2 = Vector2.ZERO
var _drag_current: Vector2 = Vector2.ZERO
var _overlay: Control = null

func _ready() -> void:
	# Screen overlay (drag box + status text), built here so no extra scene setup is needed
	var canvas := CanvasLayer.new()
	canvas.layer = 5
	add_child(canvas)

	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_on_overlay_draw)
	canvas.add_child(_overlay)

func _process(_delta: float) -> void:
	_prune_selection()
	_overlay.queue_redraw()

# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_on_left_pressed(event.position)
			else:
				_on_left_released(event.position)
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_on_right_pressed(event.position)

	elif event is InputEventMouseMotion:
		if _dragging:
			_drag_current = event.position

	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_A:
				if not selected.is_empty():
					attack_move_pending = true
			KEY_S:
				_order_stop()
			KEY_ESCAPE:
				attack_move_pending = false

func _on_left_pressed(pos: Vector2) -> void:
	if attack_move_pending:
		attack_move_pending = false
		var ground: Variant = _ground_point(pos)
		if ground != null:
			_order_attack_move(ground)
		return

	_dragging = true
	_drag_start = pos
	_drag_current = pos

func _on_left_released(pos: Vector2) -> void:
	if not _dragging:
		return
	_dragging = false
	_drag_current = pos

	var additive: bool = Input.is_key_pressed(KEY_SHIFT)
	var picked: Array = []

	if _drag_start.distance_to(pos) < DRAG_THRESHOLD:
		var clicked := _pick_unit_at(pos, "player_units")
		if clicked != null:
			picked.append(clicked)
	else:
		picked = _units_in_box(Rect2(_drag_start, Vector2.ZERO).expand(pos))

	# Without Shift the new pick replaces the selection (so clicking empty ground clears it)
	if additive:
		for unit in selected:
			if not picked.has(unit):
				picked.append(unit)

	_set_selection(picked)

func _on_right_pressed(pos: Vector2) -> void:
	if attack_move_pending:
		attack_move_pending = false # right click cancels targeting mode
		return
	if selected.is_empty():
		return

	# 1) an enemy unit under the cursor -> attack it
	var enemy := _pick_unit_at(pos, "ai_units")
	if enemy != null:
		_order_attack_unit(enemy)
		return

	var ground: Variant = _ground_point(pos)
	if ground == null:
		return

	# 2) an enemy city under the cursor -> attack-move to its front door
	var city := _enemy_city_near(ground)
	if city != null:
		_order_attack_move(_city_approach_point(city))
		return

	# 3) plain ground -> move
	_order_move(ground)

# ---------------------------------------------------------------------------
# Orders
# ---------------------------------------------------------------------------

func _order_move(point: Vector3) -> void:
	_prune_selection()
	var destinations := Unit.formation_for(selected, _clamp_to_map(point))
	for i in selected.size():
		selected[i].move_to(destinations[i])

func _order_attack_move(point: Vector3) -> void:
	_prune_selection()
	var destinations := Unit.formation_for(selected, _clamp_to_map(point))
	for i in selected.size():
		selected[i].attack_move_to(destinations[i])

func _order_attack_unit(enemy: Node3D) -> void:
	_prune_selection()
	for unit in selected:
		unit.attack_unit(enemy)

func _order_stop() -> void:
	attack_move_pending = false
	_prune_selection()
	for unit in selected:
		unit.stop()

# ---------------------------------------------------------------------------
# Selection helpers
# ---------------------------------------------------------------------------

func _set_selection(units: Array) -> void:
	for unit in selected:
		if is_instance_valid(unit):
			unit.set_selected(false)
	selected = units
	for unit in selected:
		unit.set_selected(true)

func _prune_selection() -> void:
	selected = selected.filter(func(u): return is_instance_valid(u))

func _units_in_box(rect: Rect2) -> Array:
	var camera := get_viewport().get_camera_3d()
	var result: Array = []
	if camera == null:
		return result
	for unit: Unit in get_tree().get_nodes_in_group("player_units"):
		var world_pos: Vector3 = unit.global_position + Vector3(0.0, 0.4, 0.0)
		if camera.is_position_behind(world_pos):
			continue
		if rect.has_point(camera.unproject_position(world_pos)):
			result.append(unit)
	return result

# Picks the unit whose centre is closest to the mouse ray (within a tolerance that grows with distance)
func _pick_unit_at(screen_pos: Vector2, group: String) -> Unit:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return null
	var origin := camera.project_ray_origin(screen_pos)
	var direction := camera.project_ray_normal(screen_pos)

	var best: Unit = null
	var best_miss: float = INF
	for unit: Unit in get_tree().get_nodes_in_group(group):
		var to_unit: Vector3 = (unit.global_position + Vector3(0.0, 0.4, 0.0)) - origin
		var along: float = to_unit.dot(direction)
		if along <= 0.0:
			continue
		var miss: float = (to_unit - direction * along).length()
		var tolerance: float = maxf(PICK_MIN_RADIUS, along * PICK_ANGULAR_RADIUS)
		if miss <= tolerance and miss < best_miss:
			best_miss = miss
			best = unit
	return best

# ---------------------------------------------------------------------------
# World helpers
# ---------------------------------------------------------------------------

# Where the mouse ray meets the ground (y = 0). Returns a Vector3, or null if the ray never hits it.
func _ground_point(screen_pos: Vector2) -> Variant:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return null
	var origin := camera.project_ray_origin(screen_pos)
	var direction := camera.project_ray_normal(screen_pos)
	return Plane(Vector3.UP, 0.0).intersects_ray(origin, direction)

func _clamp_to_map(point: Vector3) -> Vector3:
	return Vector3(
		clampf(point.x, -map_half_width, map_half_width),
		0.0,
		clampf(point.z, -map_half_depth, map_half_depth)
	)

func _enemy_city_near(ground: Vector3) -> Node3D:
	for city: Node3D in get_tree().get_nodes_in_group("cities"):
		if not is_instance_valid(city):
			continue
		if city.is_player_city:
			continue
		var flat := city.global_position - ground
		flat.y = 0.0
		if flat.length() <= CITY_PICK_RADIUS:
			return city
	return null

# A point on the near side of the city (facing our own city), so attackers gather in front of it
func _city_approach_point(city: Node3D) -> Vector3:
	var own_city: Node3D = null
	for c in get_tree().get_nodes_in_group("cities"):
		if is_instance_valid(c) and c.is_player_city:
			own_city = c
			break
	if own_city == null:
		return city.global_position
	var toward_us := (own_city.global_position - city.global_position).normalized()
	return city.global_position + toward_us * CITY_APPROACH_DISTANCE

# ---------------------------------------------------------------------------
# Overlay drawing (drag box + status text)
# ---------------------------------------------------------------------------

func _on_overlay_draw() -> void:
	if _dragging and _drag_start.distance_to(_drag_current) >= DRAG_THRESHOLD:
		var rect := Rect2(_drag_start, Vector2.ZERO).expand(_drag_current)
		_overlay.draw_rect(rect, Color(0.3, 1.0, 0.4, 0.15), true)
		_overlay.draw_rect(rect, Color(0.3, 1.0, 0.4, 0.9), false, 2.0)

	var font := ThemeDB.fallback_font
	_overlay.draw_string(font, Vector2(20.0, 170.0), "Selected: %d" % selected.size(),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.8, 1.0, 0.8))
	if attack_move_pending:
		_overlay.draw_string(font, Vector2(20.0, 194.0),
			"ATTACK-MOVE: left-click a location (right-click or Esc to cancel)",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1.0, 0.8, 0.3))
