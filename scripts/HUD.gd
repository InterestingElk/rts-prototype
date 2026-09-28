extends CanvasLayer

@onready var manpower_label: Label = $ManpowerLabel
@onready var steel_label: Label = $SteelLabel
@onready var oil_label: Label = $OilLabel
@onready var oil_status_label: Label = $OilStatusLabel

@export var player_city: Node3D

var _deposit: OilDeposit = null

func _ready() -> void:
	if player_city:
		player_city.resources_changed.connect(_on_resources_changed)
		player_city.oil_changed.connect(_on_oil_changed)
		_on_resources_changed(player_city.manpower, player_city.steel)
		_on_oil_changed(player_city.oil)
	_refresh_oil_status()

func _process(_delta: float) -> void:
	# The oil field may be created after the HUD is ready, so link to it lazily
	if _deposit == null:
		_deposit = get_tree().get_first_node_in_group("oil_deposits") as OilDeposit
		if _deposit != null:
			_deposit.status_changed.connect(_on_oil_status_changed)
	_refresh_oil_status() # every frame, so the capture percentage ticks up smoothly

func _on_resources_changed(manpower: float, steel: float) -> void:
	manpower_label.text = "Manpower: %d" % floor(manpower)
	steel_label.text = "Steel: %d" % floor(steel)

func _on_oil_changed(oil: float) -> void:
	oil_label.text = "Oil: %d" % floor(oil)

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
