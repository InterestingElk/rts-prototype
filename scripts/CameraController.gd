extends Camera3D

# --- Map bounds (match the ground plane size in Main.tscn) ---
@export var map_half_width: float = 50.0   # x extent: -50 .. +50
@export var map_half_depth: float = 40.0   # z extent: -40 .. +40

# --- Panning ---
@export var pan_speed: float = 40.0        # units/sec at base zoom
@export var edge_scroll_margin: float = 20.0  # pixels from screen edge
@export var edge_scroll_enabled: bool = true

# --- Zoom (camera height above the ground) ---
@export var min_height: float = 5.0
@export var max_height: float = 60.0
@export var zoom_factor_per_notch: float = 1.12  # each wheel notch scales height by this (12%)
@export var zoom_smoothing: float = 10.0
@export var trackpad_scroll_sensitivity: float = 0.5   # two-finger scroll strength
@export var pinch_sensitivity: float = 8.0                # pinch-to-zoom strength

# The camera keeps its tilt; only its position changes.
var target_height: float = 10.0
var tilt_z_offset: float = 0.0

func _ready() -> void:
	target_height = global_position.y
	# How far behind the look-at point the camera sits, based on its tilt.
	# For a camera tilted down by angle a at height h, the ground point it
	# looks at is h / tan(a) in front of it. We keep that ratio when zooming.
	var pitch := -rotation.x  # positive when looking down
	tilt_z_offset = 1.0 / tan(pitch)

func _unhandled_input(event: InputEvent) -> void:
	# Mouse wheel (also what smooth-scroll tools like MOS emit). `factor` is 1.0 for a
	# normal click and a fraction for smoothed input, so we scale by it instead of
	# counting each event as a full notch.
	if event is InputEventMouseButton and event.pressed:
		var amount: float = event.factor if event.factor > 0.0 else 1.0
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_apply_zoom(amount)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_apply_zoom(-amount)
	# Two-finger trackpad scroll
	elif event is InputEventPanGesture:
		_apply_zoom(-event.delta.y * trackpad_scroll_sensitivity)
	# Trackpad pinch
	elif event is InputEventMagnifyGesture:
		_apply_zoom((event.factor - 1.0) * pinch_sensitivity)

# Positive amount = zoom in (lower height), negative = zoom out.
func _apply_zoom(amount: float) -> void:
	var scale_change: float = pow(zoom_factor_per_notch, -amount)
	target_height = clamp(target_height * scale_change, min_height, max_height)

func _process(delta: float) -> void:
	var move := Vector3.ZERO

	# Keyboard: arrow keys (WASD is reserved for unit hotkeys)
	if Input.is_key_pressed(KEY_UP):
		move.z -= 1.0
	if Input.is_key_pressed(KEY_DOWN):
		move.z += 1.0
	if Input.is_key_pressed(KEY_LEFT):
		move.x -= 1.0
	if Input.is_key_pressed(KEY_RIGHT):
		move.x += 1.0

	# Screen-edge scrolling
	if edge_scroll_enabled:
		var viewport := get_viewport()
		var mouse := viewport.get_mouse_position()
		var screen_size := viewport.get_visible_rect().size
		if mouse.x >= 0 and mouse.y >= 0 and mouse.x <= screen_size.x and mouse.y <= screen_size.y:
			if mouse.x < edge_scroll_margin:
				move.x -= 1.0
			elif mouse.x > screen_size.x - edge_scroll_margin:
				move.x += 1.0
			if mouse.y < edge_scroll_margin:
				move.z -= 1.0
			elif mouse.y > screen_size.y - edge_scroll_margin:
				move.z += 1.0

	# Pan faster when zoomed out so crossing the map doesn't feel slow
	var height_scale := global_position.y / 10.0
	if move != Vector3.ZERO:
		move = move.normalized() * pan_speed * height_scale * delta
		global_position.x += move.x
		global_position.z += move.z

	# Smooth zoom: change height and slide back/forward to keep the same view point
	var old_height := global_position.y
	var new_height: float = lerp(old_height, target_height, clamp(zoom_smoothing * delta, 0.0, 1.0))
	global_position.y = new_height
	global_position.z += (new_height - old_height) * tilt_z_offset

	_clamp_to_bounds()

func _clamp_to_bounds() -> void:
	# Clamp based on where the camera is LOOKING (ground point), not where it sits,
	# so you can see the map edges but not scroll into empty space.
	var look_z := global_position.z - global_position.y * tilt_z_offset
	var clamped_x: float = clamp(global_position.x, -map_half_width, map_half_width)
	var clamped_look_z: float = clamp(look_z, -map_half_depth, map_half_depth)
	global_position.x = clamped_x
	global_position.z = clamped_look_z + global_position.y * tilt_z_offset
