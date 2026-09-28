class_name OilDeposit
extends Node3D

# The oil field in the middle of the map.
#
# Control rules:
#   - One side alone in the zone, and it doesn't control the field yet -> it builds CAPTURE PROGRESS.
#     After `capture_time` seconds of that, it takes control.
#   - Progress drains away when that side leaves (or the current controller is back in the zone alone).
#   - A different side starting to capture resets progress to zero.
#   - Both sides in the zone -> CONTESTED: progress freezes and nobody earns oil.
#   - Nobody in the zone     -> the last controller keeps the field and keeps earning.
#
# Income is paid straight into the controlling side's city stockpile (City.oil).

enum Controller { NONE, PLAYER, AI }

@export var control_radius: float = 13.0
@export var income_per_minute: float = 6.0
@export var capture_time: float = 15.0        # seconds alone in the zone needed to take the field
@export var capture_decay_speed: float = 1.0  # progress lost per second when nobody is pushing

const CHECK_INTERVAL: float = 0.2

const COLOR_NEUTRAL: Color = Color(0.6, 0.6, 0.6)
const COLOR_PLAYER: Color = Color(0.25, 0.5, 1.0)
const COLOR_ENEMY: Color = Color(1.0, 0.3, 0.3)
const COLOR_CONTESTED: Color = Color(1.0, 0.85, 0.2)

var controller: Controller = Controller.NONE
var contested: bool = false
var capturer: Controller = Controller.NONE   # who is currently building capture progress
var capture_progress: float = 0.0            # seconds, 0 .. capture_time

var _player_count: int = 0
var _ai_count: int = 0
var _check_timer: float = 0.0
var _zone_material: StandardMaterial3D
var _marker_material: StandardMaterial3D

# Emitted whenever the controller or the contested flag changes (the HUD listens to this)
signal status_changed(controller: int, contested: bool)

func _ready() -> void:
	add_to_group("oil_deposits")
	_build_visuals()
	_refresh_visuals()

func _physics_process(delta: float) -> void:
	_check_timer -= delta
	if _check_timer <= 0.0:
		_check_timer = CHECK_INTERVAL
		_update_presence()
	_update_capture(delta)

	if controller != Controller.NONE and not contested:
		var city := _city_for(controller)
		if city != null:
			city.add_oil(income_per_minute / 60.0 * delta)

# ---------------------------------------------------------------------------
# Control
# ---------------------------------------------------------------------------

func _update_presence() -> void:
	_player_count = _count_units_in_zone("player_units")
	_ai_count = _count_units_in_zone("ai_units")

	var new_contested: bool = _player_count > 0 and _ai_count > 0
	if new_contested != contested:
		contested = new_contested
		_refresh_visuals()
		status_changed.emit(controller, contested)

func _update_capture(delta: float) -> void:
	if contested:
		return # progress is frozen while both sides are in the zone

	var occupant: Controller = Controller.NONE
	if _player_count > 0:
		occupant = Controller.PLAYER
	elif _ai_count > 0:
		occupant = Controller.AI

	if occupant != Controller.NONE and occupant != controller:
		# someone who doesn't own the field is alone in it: build progress
		if capturer != occupant:
			capturer = occupant
			capture_progress = 0.0
		capture_progress += delta
		if capture_progress >= capture_time:
			_complete_capture(occupant)
		else:
			_refresh_visuals()
	elif capture_progress > 0.0:
		# nobody is pushing (they left, or the owner is back): progress drains away
		capture_progress = maxf(0.0, capture_progress - delta * capture_decay_speed)
		if capture_progress == 0.0:
			capturer = Controller.NONE
		_refresh_visuals()

func _complete_capture(who: Controller) -> void:
	controller = who
	capturer = Controller.NONE
	capture_progress = 0.0
	_refresh_visuals()
	status_changed.emit(controller, contested)

func capture_fraction() -> float:
	if capture_time <= 0.0:
		return 0.0
	return clampf(capture_progress / capture_time, 0.0, 1.0)

func _count_units_in_zone(group: String) -> int:
	var count := 0
	for unit: Node3D in get_tree().get_nodes_in_group(group):
		if not is_instance_valid(unit):
			continue
		var flat := Vector2(unit.global_position.x - global_position.x, unit.global_position.z - global_position.z)
		if flat.length() <= control_radius:
			count += 1
	return count

func _city_for(who: Controller) -> Node3D:
	var want_player: bool = who == Controller.PLAYER
	for city: Node3D in get_tree().get_nodes_in_group("cities"):
		if is_instance_valid(city) and city.is_player_city == want_player:
			return city
	return null

# ---------------------------------------------------------------------------
# Placeholder visuals: a translucent disc showing the control zone + a marker in the middle.
# Both change colour with the state (grey = neutral, blue = yours, red = enemy's, yellow = contested).
# ---------------------------------------------------------------------------

func _build_visuals() -> void:
	_zone_material = StandardMaterial3D.new()
	_zone_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_zone_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	var disc := CylinderMesh.new()
	disc.top_radius = control_radius
	disc.bottom_radius = control_radius
	disc.height = 0.02
	disc.radial_segments = 64
	disc.rings = 1

	var zone := MeshInstance3D.new()
	zone.mesh = disc
	zone.material_override = _zone_material
	zone.position = Vector3(0.0, 0.03, 0.0)
	zone.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(zone)

	_marker_material = StandardMaterial3D.new()
	_marker_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var tower := CylinderMesh.new()
	tower.top_radius = 0.7
	tower.bottom_radius = 1.1
	tower.height = 3.0

	var marker := MeshInstance3D.new()
	marker.mesh = tower
	marker.material_override = _marker_material
	marker.position = Vector3(0.0, 1.5, 0.0)
	marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(marker)

func _color_for(who: Controller) -> Color:
	match who:
		Controller.PLAYER:
			return COLOR_PLAYER
		Controller.AI:
			return COLOR_ENEMY
		_:
			return COLOR_NEUTRAL

func _refresh_visuals() -> void:
	if _zone_material == null:
		return
	var color: Color = _color_for(controller)
	if contested:
		color = COLOR_CONTESTED
	elif capturer != Controller.NONE:
		color = color.lerp(_color_for(capturer), capture_fraction())
	_zone_material.albedo_color = Color(color.r, color.g, color.b, 0.22)
	_marker_material.albedo_color = color
