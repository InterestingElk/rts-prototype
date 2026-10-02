extends CanvasLayer

@onready var manpower_label: Label = $ManpowerLabel
@onready var steel_label: Label = $SteelLabel
@onready var oil_label: Label = $OilLabel
@onready var oil_status_label: Label = $OilStatusLabel

@export var player_city: Node3D

var _deposit: OilDeposit = null
var _selection_manager: Node = null
var production_label: Label
var hint_label: Label

const UNIT_KEYS: String = "Right-click  Move (drag to set facing)     A  Attack-move (drag to set facing)     S  Stop / hold ground     V  Supply view"

func _ready() -> void:
	if player_city:
		player_city.resources_changed.connect(_on_resources_changed)
		player_city.oil_changed.connect(_on_oil_changed)
		_on_resources_changed(player_city.manpower, player_city.steel)
		_on_oil_changed(player_city.oil)
	_refresh_oil_status()

	# Labels built in code (placeholder UI until there is a proper one)
	production_label = Label.new()
	production_label.name = "ProductionLabel"
	production_label.position = Vector2(20.0, 140.0)
	add_child(production_label)

	hint_label = Label.new()
	hint_label.name = "HintLabel"
	add_child(hint_label)
	# NOT looked up here: SelectionManager may not have registered itself yet this frame
	# (node ready-order in the scene tree isn't guaranteed), so this is resolved lazily below.

func _process(_delta: float) -> void:
	if _selection_manager == null:
		_selection_manager = get_tree().get_first_node_in_group("selection_managers")
	_refresh_production()
	hint_label.position = Vector2(20.0, get_viewport().get_visible_rect().size.y - 58.0)

	# The oil field may be created after the HUD is ready, so link to it lazily
	if _deposit == null:
		_deposit = get_tree().get_first_node_in_group("oil_deposits") as OilDeposit
		if _deposit != null:
			_deposit.status_changed.connect(_on_oil_status_changed)
	_refresh_oil_status() # every frame, so the capture percentage ticks up smoothly

func _building_hint(b: Building) -> String:
	var parts: Array[String] = []
	for o in b.recruit_options:
		var cost := "%d manpower, %d steel" % [o.get("manpower", 0.0), o.get("steel", 0.0)]
		if o.get("oil", 0.0) > 0.0:
			cost += ", %d oil" % o["oil"]
		parts.append("%s  %s (%s)" % [OS.get_keycode_string(o["keycode"]), o["name"], cost])
	return "   ".join(parts)

func _on_resources_changed(manpower: float, steel: float) -> void:
	manpower_label.text = "Manpower: %d" % floor(manpower)
	steel_label.text = "Steel: %d" % floor(steel)

func _on_oil_changed(oil: float) -> void:
	if oil <= 0.0:
		oil_label.text = "Oil: 0  (OUT OF FUEL - tanks can't move)"
	elif oil < 1.0:
		oil_label.text = "Oil: %.1f" % oil
	else:
		oil_label.text = "Oil: %d" % floor(oil)

func _refresh_production() -> void:
	var selected: Building = _selection_manager.selected_building if _selection_manager else null
	if selected == null:
		production_label.text = "No building selected"
		hint_label.text = "Click your Barracks or Tank Factory to select it, then use its hotkeys.\n" + UNIT_KEYS
		return

	hint_label.text = _building_hint(selected) + "\n" + UNIT_KEYS
	if selected.is_recruiting:
		production_label.text = "%s: building %s (%ds)" % [selected.building_name, selected.recruit_name, ceili(selected.recruit_timer)]
	else:
		production_label.text = "%s: idle" % selected.building_name

func _on_oil_status_changed(_controller: int, _contested: bool) -> void:
	_refresh_oil_status()

func _refresh_oil_status() -> void:
	if _deposit == null:
		oil_status_label.text = "Oil field: --"
		return
	if _deposit.contested:
		oil_status_label.text = "Oil field: CONTESTED"
		return
	if _deposit.capturer != OilDeposit.Controller.NONE:
		var percent := int(_deposit.capture_fraction() * 100.0)
		if _deposit.capturer == OilDeposit.Controller.PLAYER:
			oil_status_label.text = "Oil field: CAPTURING %d%%" % percent
		else:
			oil_status_label.text = "Oil field: ENEMY CAPTURING %d%%" % percent
		return
	match _deposit.controller:
		OilDeposit.Controller.PLAYER:
			oil_status_label.text = "Oil field: YOURS (+%d/min)" % int(_deposit.income_per_minute)
		OilDeposit.Controller.AI:
			oil_status_label.text = "Oil field: ENEMY"
		_:
			oil_status_label.text = "Oil field: neutral"
