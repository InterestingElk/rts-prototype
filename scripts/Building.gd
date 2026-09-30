class_name Building
extends Node3D

# Base class for production buildings (Barracks, TankFactory). A building:
#   - belongs to a city (where resources are spent from, and where units spawn)
#   - holds ONE production queue slot, same rule as the old City-based recruiting
#   - is selectable (like a unit, but selecting a building never issues move orders)
#   - only responds to its own recruit hotkeys while selected (see _unhandled_input below)

@export var owning_city: Node3D
@export var is_player_building: bool = true
var building_name: String = "Building"   # overridden by Barracks/TankFactory for HUD display

var is_recruiting: bool = false
var recruit_timer: float = 0.0
var recruit_name: String = ""          # what is currently being built (for the HUD)
var _recruit_scene: PackedScene = null
var _recruit_signal_name: String = ""  # "infantry_recruited" style signals some listeners (AI) care about

var _selection_ring: MeshInstance3D = null
var selection_radius: float = 3.0      # override per building if its footprint differs

signal unit_recruited(unit: Node3D)
signal production_changed  # recruit started/finished/cancelled -- the HUD listens to this

# Each recruit option this building offers: {key, name, manpower, steel, oil, time, scene}
# Subclasses (Barracks, TankFactory) fill this in.
var recruit_options: Array = []

func _ready() -> void:
	add_to_group("buildings")
	add_to_group("player_buildings" if is_player_building else "ai_buildings")

func _process(delta: float) -> void:
	if is_recruiting:
		recruit_timer -= delta
		if recruit_timer <= 0.0:
			_finish_recruit()

# ---------------------------------------------------------------------------
# Recruiting
# ---------------------------------------------------------------------------

func try_recruit(key: String) -> bool:
	if is_recruiting or owning_city == null:
		return false
	var opt: Variant = null
	for o in recruit_options:
		if o["key"] == key:
			opt = o
			break
	if opt == null:
		return false

	var mp: float = opt.get("manpower", 0.0)
	var steel: float = opt.get("steel", 0.0)
	var oil: float = opt.get("oil", 0.0)
	if owning_city.manpower < mp or owning_city.steel < steel or owning_city.oil < oil:
		return false

	owning_city.manpower -= mp
	owning_city.steel -= steel
	if oil > 0.0:
		owning_city.spend_oil(oil)
	owning_city.resources_changed.emit(owning_city.manpower, owning_city.steel)

	is_recruiting = true
	recruit_timer = opt["time"]
	recruit_name = opt["name"]
	_recruit_scene = opt["scene"]
	_recruit_signal_name = opt.get("signal", "")
	production_changed.emit()
	return true

func _finish_recruit() -> void:
	is_recruiting = false
	var unit = _recruit_scene.instantiate()
	unit.is_player_unit = is_player_building
	get_tree().current_scene.add_child(unit)

	var direction_x: float = 1.0 if is_player_building else -1.0
	var offset := Vector3(direction_x * (6 + randf_range(-2.0, 2.0)), 0, randf_range(-4.0, 4.0))
	unit.global_position = global_position + offset

	if _recruit_signal_name != "" and owning_city.has_signal(_recruit_signal_name):
		owning_city.emit_signal(_recruit_signal_name, unit)
	unit_recruited.emit(unit)
	production_changed.emit()

# ---------------------------------------------------------------------------
# Selection + per-building hotkeys
# ---------------------------------------------------------------------------

func set_selected(value: bool) -> void:
	if value and _selection_ring == null:
		_selection_ring = _make_selection_ring()
		add_child(_selection_ring)
	if _selection_ring != null:
		_selection_ring.visible = value

# Called by SelectionManager only when THIS building is the selected one.
# Subclasses don't need to override this -- add entries to recruit_options and the
# key -> recruit mapping is automatic.
func handle_hotkey(keycode: int) -> void:
	for o in recruit_options:
		if o["keycode"] == keycode:
			try_recruit(o["key"])
			return

func _make_selection_ring() -> MeshInstance3D:
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = selection_radius - 0.25
	torus.outer_radius = selection_radius
	ring.mesh = torus

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 1.0, 0.3)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material_override = mat

	ring.position = Vector3(0.0, 0.05, 0.0)
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return ring
