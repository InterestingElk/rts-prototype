extends Node

# Health bars drawn in screen space over every unit that is damaged (and over your selected units).
# One bar per unit showing its effective health (the lower of manpower and equipment).

const BAR_HEIGHT: float = 4.0
const MIN_BAR_WIDTH: float = 14.0

var _overlay: Control = null

func _ready() -> void:
	var canvas := CanvasLayer.new()
	canvas.layer = 4
	add_child(canvas)

	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_on_draw)
	canvas.add_child(_overlay)

func _process(_delta: float) -> void:
	_overlay.queue_redraw()

func _on_draw() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	for group in ["player_units", "ai_units"]:
		for unit: Unit in get_tree().get_nodes_in_group(group):
			if not is_instance_valid(unit):
				continue
			var fraction: float = unit.get_health_fraction()
			if fraction >= 0.999 and not unit.is_selected:
				continue
			var top: Vector3 = unit.global_position + Vector3(0.0, unit.bar_height, 0.0)
			if camera.is_position_behind(top):
				continue
			var centre: Vector2 = camera.unproject_position(top)
			var half_width: float = absf(camera.unproject_position(top + Vector3(unit.pick_radius, 0.0, 0.0)).x - centre.x)
			var width: float = maxf(MIN_BAR_WIDTH, half_width * 2.0)
			var rect := Rect2(centre.x - width * 0.5, centre.y - BAR_HEIGHT, width, BAR_HEIGHT)
			# Orange outline = out of supply (not recovering)
			var outline: Color = Color(0.0, 0.0, 0.0, 0.7) if unit.in_supply else Color(1.0, 0.55, 0.1, 0.95)
			_overlay.draw_rect(rect.grow(1.0 if unit.in_supply else 2.0), outline, true)
			if not unit.in_supply:
				_overlay.draw_string(ThemeDB.fallback_font, Vector2(rect.end.x + 4.0, rect.end.y + 3.0), "!",
					HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1.0, 0.55, 0.1))
			_overlay.draw_rect(Rect2(rect.position, Vector2(width * fraction, BAR_HEIGHT)), _bar_color(fraction), true)

func _bar_color(fraction: float) -> Color:
	if fraction > 0.6:
		return Color(0.3, 0.9, 0.3)
	if fraction > 0.3:
		return Color(0.95, 0.8, 0.2)
	return Color(0.9, 0.25, 0.2)
