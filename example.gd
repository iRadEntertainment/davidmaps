extends PanelContainer

@onready var david_maps: DavidMaps = %DavidMaps

@onready var mouse_lat_log_pos: Label = %mouse_lat_log_pos
@onready var map_info: Label = %map_info


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
