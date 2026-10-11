extends PanelContainer

@onready var opt_provider: OptionButton = %opt_provider
@onready var opt_layer: OptionButton = %opt_layer
@onready var sl_view_scale: HSlider = %sl_view_scale
@onready var lb_view_scale: Label = %lb_view_scale
@onready var ck_debug: CheckButton = %ck_debug

@onready var mouse_lat_log_pos: Label = %mouse_lat_log_pos
@onready var map_info: Label = %map_info

@onready var david_maps: DavidMaps = %DavidMaps


func _ready() -> void:
	_populate_opt()
	_update_settings_nodes()
	_connect_tool_signals()


func _populate_opt() -> void:
	for value: String in DavidMaps.ProviderType.keys():
		opt_provider.add_item(value)
	for value: String in DavidMaps.MapLayer.keys():
		opt_layer.add_item(value)


func _update_settings_nodes() -> void:
	opt_provider.selected = david_maps.provider_type as int
	opt_layer.selected = david_maps.map_layer as int
	sl_view_scale.value = david_maps.visualization_scale
	lb_view_scale.text = "%.02f" % david_maps.visualization_scale
	ck_debug.button_pressed = david_maps.debug_view_on


func _connect_tool_signals() -> void:
	opt_provider.item_selected.connect(_on_opt_provider_item_selected)
	opt_layer.item_selected.connect(_on_opt_layer_item_selected)
	sl_view_scale.value_changed.connect(_on_sl_view_scale_value_changed)
	ck_debug.toggled.connect(_on_ck_debug_toggled)


func _on_david_maps_map_mouse_event(
			event: InputEventMouse,
			lat: float,
			lon: float
		) -> void:
	if event is InputEventMouseMotion:
		mouse_lat_log_pos.text = "Lat: %.6f\nLon: %.6f" % [lat, lon]
	
	elif event is InputEventMouseButton:
		if event.is_released(): return
		if event.button_index == MOUSE_BUTTON_LEFT:
			david_maps.go_to(
				ceilf(david_maps.get_zoom_level()),
				lat,
				lon,
				true
				)


func _on_david_maps_view_changed(
			zoom: float,
			lat: float,
			lon: float
		) -> void:
	map_info.text = "Zoom: %.2f\nLat: %.6f\nLon: %.6f" % [zoom, lat, lon]


func _on_opt_provider_item_selected(index: int) -> void:
	david_maps.set_provider(index as DavidMaps.ProviderType)
func _on_opt_layer_item_selected(index: int) -> void:
	david_maps.set_layer(index as DavidMaps.MapLayer)
func _on_sl_view_scale_value_changed(value: float) -> void:
	david_maps.visualization_scale = value
	lb_view_scale.text = "%.02f" % value
func _on_ck_debug_toggled(toggled_on: bool) -> void:
	david_maps.debug_view_on = toggled_on
