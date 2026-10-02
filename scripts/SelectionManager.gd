extends Node

# Classic RTS controls:
#   Left click / drag box ... select your units, or click a building to select it (Shift = add to selection)
#   Right click ............. ground: move in formation   |   enemy unit: attack it   |   enemy city: attack-move onto it
#   Right click + drag ...... move in formation and face the way you drag (a preview of the slots is shown)
#   A, then left click ...... attack-move       (right click or Esc cancels)
#   S ....................... stop
#   Building hotkeys (I, G, T, ...) only do anything while that specific building is selected.

# Map limits so orders can't send units off the edge (keep in sync with the ground plane / camera)
@export var map_half_width: float = 50.0
@export var map_half_depth: float = 40.0

const DRAG_THRESHOLD: float = 6.0          # pixels before a click becomes a drag box
const PICK_MIN_RADIUS: float = 0.7         # world units, for clicking on small units up close
const PICK_ANGULAR_RADIUS: float = 0.03    # grows with distance so units stay clickable zoomed out
const CITY_PICK_RADIUS: float = 3.5        # ground distance from a city's centre that counts as clicking it
const CITY_APPROACH_DISTANCE: float = 4.0  # how far in front of an enemy city attackers gather
const BUILDING_PICK_RADIUS: float = 3.5    # ground distance from a building's centre that counts as clicking it
const RIGHT_DRAG_THRESHOLD: float = 12.0   # pixels before a right click becomes a "face this way" drag

var selected: Array = []
var attack_move_pending: bool = false
var selected_building: Building = null

var _dragging: bool = false
var _drag_start: Vector2 = Vector2.ZERO
var _drag_current: Vector2 = Vector2.ZERO
var _overlay: Control = null

var _rdragging: bool = false               # right button held on plain ground (a move order in progress)
var _rdrag_start_screen: Vector2 = Vector2.ZERO
var _rdrag_current_screen: Vector2 = Vector2.ZERO
var _rdrag_start_ground: Vector3 = Vector3.ZERO
var _rdrag_attack: bool = false            # true when the drag is an attack-move (A + left button)

func _ready() -> void:
	add_to_group("selection_managers")
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
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_on_right_pressed(event.position)
			else:
				_on_right_released(event.position)

	elif event is InputEventMouseMotion:
		if _dragging:
			_drag_current = event.position
		if _rdragging:
			_rdrag_current_screen = event.position

	elif event is InputEventKey and event.pressed and not event.echo:
		if selected_building != null and is_instance_valid(selected_building):
			selected_building.handle_hotkey(event.keycode)
			return  # a selected building owns the keyboard: A/S below are for unit orders, not buildings
		match event.keycode:
			KEY_A:
				if not selected.is_empty():
					attack_move_pending = true
			KEY_S:
				_order_stop()
			KEY_ESCAPE:
				attack_move_pending = false
				_rdragging = false

func _on_left_pressed(pos: Vector2) -> void:
	if attack_move_pending:
		attack_move_pending = false
		var ground: Variant = _ground_point(pos)
		if ground != null:
			_begin_formation_drag(pos, ground, true) # issued on release so the drag can set the facing
		return

	_dragging = true
	_drag_start = pos
	_drag_current = pos

func _on_left_released(pos: Vector2) -> void:
	if _rdragging and _rdrag_attack:
		_finish_formation_drag(pos)
		return
	if not _dragging:
		return
	_dragging = false
	_drag_current = pos

	# A plain click (not a drag) on one of our own buildings selects that building instead
	# of a unit; buildings and units are never selected together.
	if _drag_start.distance_to(pos) < DRAG_THRESHOLD:
		var ground: Variant = _ground_point(pos)
		if ground != null:
			var building := _own_building_near(ground)
			if building != null:
				_set_selection([])
				_set_selected_building(building)
				return

	var additive: bool = Input.is_key_pressed(KEY_SHIFT)
	var picked: Array = []

	if _drag_start.distance_to(pos) < DRAG_THRESHOLD:
		var clicked := _pick_unit_at(pos, "player_units")
		if clicked != null:
			picked.append(clicked)
	else:
		picked = _units_in_box(Rect2(_drag_start, Vector2.ZERO).expand(pos))

	# Without Shift the new pick replaces the selection (so clicking empty ground clears it,
	# and clicking a unit or empty ground also clears any selected building)
	if additive:
		for unit in selected:
			if not picked.has(unit):
				picked.append(unit)
	else:
		_set_selected_building(null)

	_set_selection(picked)

func _on_right_pressed(pos: Vector2) -> void:
	if _rdragging and _rdrag_attack:
		_rdragging = false # right click cancels an attack-move drag in progress
		return
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

	# 3) plain ground -> start a move order; it is issued on release so the drag can set the facing
	_begin_formation_drag(pos, ground, false)

func _on_right_released(pos: Vector2) -> void:
	if not _rdragging or _rdrag_attack:
		return
	_finish_formation_drag(pos)

func _begin_formation_drag(screen_pos: Vector2, ground: Vector3, attack: bool) -> void:
	_rdragging = true
	_rdrag_attack = attack
	_rdrag_start_screen = screen_pos
	_rdrag_current_screen = screen_pos
	_rdrag_start_ground = ground

func _finish_formation_drag(pos: Vector2) -> void:
	_rdragging = false
	_rdrag_current_screen = pos
	var facing := _rdrag_facing()
	if _rdrag_attack:
		_order_attack_move(_rdrag_start_ground, facing)
	else:
		_order_move(_rdrag_start_ground, facing)

# The direction the player dragged on the ground, or zero for a plain click (the formation then
# faces the way it has to travel).
func _rdrag_facing() -> Vector3:
	if _rdrag_start_screen.distance_to(_rdrag_current_screen) < RIGHT_DRAG_THRESHOLD:
		return Vector3.ZERO
	var ground: Variant = _ground_point(_rdrag_current_screen)
	if ground == null:
		return Vector3.ZERO
	var d: Vector3 = ground - _rdrag_start_ground
	d.y = 0.0
	if d.length() < 0.5:
		return Vector3.ZERO
	return d.normalized()

# ---------------------------------------------------------------------------
# Orders
# ---------------------------------------------------------------------------

func _order_move(point: Vector3, facing: Vector3 = Vector3.ZERO) -> void:
	_prune_selection()
	Unit.formation_order(selected, _clamp_to_map(point), facing, false, _bounds())

func _order_attack_move(point: Vector3, facing: Vector3 = Vector3.ZERO) -> void:
	_prune_selection()
	Unit.formation_order(selected, _clamp_to_map(point), facing, true, _bounds())

func _bounds() -> Vector2:
	return Vector2(map_half_width, map_half_depth)

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

func _set_selected_building(building: Building) -> void:
	if selected_building != null and is_instance_valid(selected_building):
		selected_building.set_selected(false)
	selected_building = building
	if selected_building != null:
		selected_building.set_selected(true)

func _own_building_near(ground: Vector3) -> Building:
	for b: Building in get_tree().get_nodes_in_group("player_buildings"):
		if not is_instance_valid(b):
			continue
		var flat := b.global_position - ground
		flat.y = 0.0
		if flat.length() <= BUILDING_PICK_RADIUS:
			return b
	return null

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
		var tolerance: float = maxf(maxf(PICK_MIN_RADIUS, unit.pick_radius), along * PICK_ANGULAR_RADIUS)
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

	var camera := get_viewport().get_camera_3d()
	if camera != null:
		_draw_order_markers(camera)

	var font := ThemeDB.fallback_font
	var unsupplied: int = 0
	for u: Unit in selected:
		if not u.in_supply:
			unsupplied += 1
	var selected_text: String = "Selected: %d" % selected.size()
	if unsupplied > 0:
		selected_text += "   (%d OUT OF SUPPLY - not recovering)" % unsupplied
	_overlay.draw_string(font, Vector2(20.0, 200.0), selected_text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1.0, 0.7, 0.3) if unsupplied > 0 else Color(0.8, 1.0, 0.8))
	if attack_move_pending:
		_overlay.draw_string(font, Vector2(20.0, 224.0),
			"ATTACK-MOVE: left-click a location (right-click or Esc to cancel)",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1.0, 0.8, 0.3))

# Markers for where units are going, drawn even when you are not dragging:
#   - while a move / attack-move is being placed (button held): the formation slots plus a facing tick
#   - always, for selected units that have a move or attack-move order: a line and a dot at the destination
func _draw_order_markers(camera: Camera3D) -> void:
	_prune_selection()
	var move_color := Color(0.3, 1.0, 0.4, 0.9)
	var attack_color := Color(1.0, 0.65, 0.2, 0.9)

	for u: Unit in selected:
		if u.order != Unit.Order.MOVE and u.order != Unit.Order.ATTACK_MOVE:
			continue
		var c: Color = move_color if u.order == Unit.Order.MOVE else attack_color
		if camera.is_position_behind(u.global_position) or camera.is_position_behind(u.order_position):
			continue
		var from := camera.unproject_position(u.global_position)
		var to := camera.unproject_position(u.order_position)
		_overlay.draw_line(from, to, Color(c.r, c.g, c.b, 0.35), 1.0)
		_overlay.draw_circle(to, 3.0, c)

	if _rdragging and not selected.is_empty():
		var c: Color = attack_color if _rdrag_attack else move_color
		var facing := _rdrag_facing()
		var center := _clamp_to_map(_rdrag_start_ground)
		var f := Unit.resolve_facing(selected, center, facing)
		var slots := Unit.formation_slots(selected, center, facing, _bounds())
		for slot in slots:
			if camera.is_position_behind(slot):
				continue
			var p := camera.unproject_position(slot)
			_overlay.draw_circle(p, 4.0, c)
			_overlay.draw_line(p, camera.unproject_position(slot + f * 1.4), c, 2.0)
		if facing != Vector3.ZERO:
			_overlay.draw_line(_rdrag_start_screen, _rdrag_current_screen, c, 2.0)
