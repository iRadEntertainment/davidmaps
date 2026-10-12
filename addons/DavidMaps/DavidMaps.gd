@tool
@icon ("david_maps_icon.svg")
extends PanelContainer
class_name DavidMaps

#region Enums
# Basemaps only; transparent thematic sources are in MapOverlay below.
enum ProviderType {
	OSM,
	WORLD_IMAGERY,
	TERRARIUM,
	OSM_FRANCE,
	CYCLOSM,
	OPENMAPS,
	OPNVKARTE,
	USGS,
	OPENTOPOMAP,
}

enum MapLayer {
	ROAD,
	SATELLITE,
	HYBRID,
	TERRAIN,
	TRANSIT,
	HIKING,
	TOPOGRAPHIC,
	CYCLING,
	CYCLING_LITE,
	HUMANITARIAN,
	SHADED_RELIEF,
}

enum MapOverlay { SEAMARKS, RAILWAYS }

enum ImgFormat {JPG, PNG, BMP, WEBP, TGA, AUTO}
#endregion

#region Signals
signal map_mouse_event(event: InputEventMouse, lat: float, lon: float)
signal view_changed(zoom: float, lat: float, lon: float)
signal navigation_finished
signal drag_started
signal drag_ended
signal provider_changed(provider: ProviderType)
signal layer_changed(layer: MapLayer)
signal overlay_changed(overlay: MapOverlay, enabled: bool)
#endregion

@export var debug_view_on: bool = true
@export var provider_type: ProviderType = ProviderType.OSM:
	set(value):
		provider_type = value
		# Keep the initial inspector layer valid when the provider is changed.
		var supported: Array = Provider.layers_for_type(value)
		if not supported.has(map_layer):
			map_layer = supported.front()
		notify_property_list_changed()
@export var show_attribution: bool = true
@export_range(0.25, 2.50, 0.05, "or_greater") var visualization_scale: float = 1.0:
	set(value):
		visualization_scale = maxf(0.01, value)
		if _provider != null and is_node_ready():
			update()
@export var map_layer: MapLayer = MapLayer.ROAD
@export_range(0.0, 20.0, 0.01) var start_zoom: float = 10.0
@export var start_longitude: float = 14.998
@export var start_latitude: float = 40.897
@export_group("Navigation")
@export_range(0.05, 5.0, 0.05, "suffix:s") var navigation_duration: float = 0.45
@export var interaction_enabled: bool = true
@export var pan_enabled: bool = true
@export var zoom_enabled: bool = true
@export_group("Overlays")
@export_flags("Sea Marks", "Railways") var enabled_overlays: int = 0
@export_group("Network")
# Change this to a truthful, app-specific User-Agent with a contact URL/email
# before shipping; community tile servers may block anonymous library agents.
@export var tile_user_agent: String = "DavidMaps/1.0"
@export_group("Tile Cache")
@export_range(1, 1000, 1) var max_cached_tiles: int = 50
@export_group("")

var _provider: Provider
var tile_loader: TileLoader
var cont_tile_renderer: Control
var cont_debug_renderer: Control
var tile_canvas: Control

var _center_longitude: float
var _center_latitude: float
var _target_zoom: float = 0.0
var _rendered_tile_zoom: int = -1
var _last_rendered_tile_zoom: int = -1
var _rendered_source_id: StringName
var _previous_rendered_source_id: StringName
var _tile_cache := TileCache.new()
var _visible_tiles: Dictionary[Vector3i, Tile] = {}
# Each enabled overlay has its own visible tile set and independently capped zoom.
var _overlay_sources: Dictionary[MapOverlay, OverlaySource] = {}
var _visible_overlay_tiles: Dictionary[MapOverlay, Dictionary] = {}
var _overlay_tile_zooms: Dictionary[MapOverlay, int] = {}
var _previous_rendered_tiles: Dictionary[Vector3i, Tile] = {}
var _debug_mouse_position: Vector2
var _debug_mouse_inside: bool = false
var _request_focus_position: Vector2
var _request_focus_inside: bool = false
var _request_reprioritization_scheduled: bool = false
var _navigation_tween: Tween
var _is_dragging: bool = false

const MAX_MERCATOR_LATITUDE: float = 85.0511287798066



#region Init
func _ready() -> void:
	if Engine.is_editor_hint():
		return

	setup()
	_sync_mouse_scroll_passthrough()
	update()


func setup() -> void:
	_center_longitude = _sanitize_longitude(start_longitude)
	_center_latitude = _sanitize_latitude(start_latitude)
	_provider = Provider.new(provider_type, map_layer)
	map_layer = _provider.layer
	_target_zoom = _normalize_zoom(clampf(start_zoom, _provider.min_zoom, _provider.max_zoom))
	
	# setup_nodes
	if tile_loader == null:
		tile_loader = TileLoader.new()
		add_child(tile_loader)
	tile_loader.user_agent = tile_user_agent
	_overlay_sources[MapOverlay.SEAMARKS] = OverlaySource.new(MapOverlay.SEAMARKS)
	_overlay_sources[MapOverlay.RAILWAYS] = OverlaySource.new(MapOverlay.RAILWAYS)

	cont_tile_renderer = Control.new()
	cont_tile_renderer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cont_tile_renderer.clip_contents = true
	cont_tile_renderer.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	add_child(cont_tile_renderer)
	cont_tile_renderer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	tile_canvas = Control.new()
	tile_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cont_tile_renderer.add_child(tile_canvas)
	tile_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	cont_debug_renderer = Control.new()
	cont_debug_renderer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cont_debug_renderer.clip_contents = true
	add_child(cont_debug_renderer)
	cont_debug_renderer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	
	# connect signals
	tile_canvas.draw.connect(_draw_renderer)
	cont_debug_renderer.draw.connect(_draw_debug_renderer)
	cont_tile_renderer.resized.connect(update)
	mouse_exited.connect(_on_mouse_exited)


func _validate_property(property: Dictionary) -> void:
	var property_name: StringName = property.name
	if property_name == &"map_layer":
		# Dynamic inspector enum: only show the selected provider's layers.
		var options := PackedStringArray()
		for layer in Provider.layers_for_type(provider_type):
			options.append("%s:%d" % [String(MapLayer.find_key(layer)).capitalize(), layer])
		property.hint = PROPERTY_HINT_ENUM
		property.hint_string = ",".join(options)
#endregion


#region API
# All lat/lon arguments are degrees; returned Vector2 values are (lon, lat).
# Screen coordinates are LOCAL to this Control, including when placed inside
# other Controls/Containers. The closest horizontal world copy is used.

func go_to(zoom: float, lat: float, lon: float, tweened: bool = false) -> void:
	var destination_longitude: float = _sanitize_longitude(lon)
	var destination_latitude: float = _sanitize_latitude(lat)
	if _provider == null:
		start_zoom = zoom
		start_latitude = destination_latitude
		start_longitude = destination_longitude
		return

	var target_zoom: float = _normalize_zoom(
		clampf(zoom, _provider.min_zoom, _provider.max_zoom)
	)
	_cancel_navigation()
	if not tweened or not is_inside_tree() or navigation_duration <= 0.0:
		_apply_view(target_zoom, destination_latitude, destination_longitude)
		return

	# Interpolate normalized Web Mercator coordinates instead of degrees.
	# Unwrap X across the shortest antimeridian path.
	var start_world_x: float = _longitude_to_tile_x(_center_longitude, 0.0)
	var start_world_y: float = _latitude_to_tile_y(_center_latitude, 0.0)
	var end_world_x: float = _longitude_to_tile_x(destination_longitude, 0.0)
	var end_world_y: float = _latitude_to_tile_y(destination_latitude, 0.0)
	var shortest_dx: float = fposmod(end_world_x - start_world_x + 0.5, 1.0) - 0.5
	end_world_x = start_world_x + shortest_dx
	var start_zoom_value: float = _target_zoom
	if (
		start_world_x == end_world_x
		and start_world_y == end_world_y
		and start_zoom_value == target_zoom
	):
		return

	_navigation_tween = create_tween()
	_navigation_tween.set_meta(&"target_zoom", target_zoom)
	_navigation_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_navigation_tween.tween_method(
		_animate_view.bind(
			start_world_x,
			start_world_y,
			end_world_x,
			end_world_y,
			start_zoom_value,
			target_zoom,
		),
		0.0, 1.0, navigation_duration
	)
	_navigation_tween.finished.connect(_on_navigation_finished)


func go_tov(zoom: float, pos: Vector2, tweened: bool = false) -> void:
	var lat: float = pos.y
	var lon: float = pos.x
	go_to(zoom, lat, lon, tweened)


func pan_to(lat: float, lon: float, tweened: bool = false) -> void:
	go_to(get_zoom_level(), lat, lon, tweened)


func zoom_to(zoom: float, tweened: bool = false) -> void:
	go_to(zoom, _center_latitude, _center_longitude, tweened)


# Legacy entry point from the original widget.
func set_zoom_level(new_zoom_level: float) -> void:
	zoom_to(new_zoom_level)


func get_zoom_level() -> float:
	return _target_zoom if _provider != null else start_zoom


func get_center_coord() -> Vector2:
	if _provider == null:
		return Vector2(start_longitude, start_latitude)
	return Vector2(_center_longitude, _center_latitude)


func screen_to_coord(local_position: Vector2) -> Vector2:
	if _provider == null or cont_tile_renderer == null:
		return get_center_coord()
	var tile_zoom: int = _get_tile_zoom_level()
	var renderer_position: Vector2 = local_position - cont_tile_renderer.position
	var display_tile_size: Vector2 = _get_display_tile_size(tile_zoom)
	var longitude: float = _sanitize_longitude(
		_tile_x_to_longitude(
			_screen_to_tile_x(renderer_position.x, tile_zoom, display_tile_size.x),
			tile_zoom,
		)
	)
	var latitude: float = _sanitize_latitude(
		_tile_y_to_latitude(
			_screen_to_tile_y(renderer_position.y, tile_zoom, display_tile_size.y),
			tile_zoom,
		)
	)
	return Vector2(longitude, latitude)


func coord_to_screen(lat: float, lon: float) -> Vector2:
	if _provider == null or cont_tile_renderer == null:
		return size / 2.0
	var tile_zoom: int = _get_tile_zoom_level()
	var tile_count: float = pow(2.0, tile_zoom)
	var delta_x: float = (
		_longitude_to_tile_x(_sanitize_longitude(lon), tile_zoom)
		- _longitude_to_tile_x(_center_longitude, tile_zoom)
	)
	delta_x = fposmod(delta_x + tile_count * 0.5, tile_count) - tile_count * 0.5
	var delta_y: float = (
		_latitude_to_tile_y(_sanitize_latitude(lat), tile_zoom)
		- _latitude_to_tile_y(_center_latitude, tile_zoom)
	)
	var display_tile_size: Vector2 = _get_display_tile_size(tile_zoom)
	return (
		cont_tile_renderer.position
		+ cont_tile_renderer.size / 2.0
		+ Vector2(delta_x * display_tile_size.x, delta_y * display_tile_size.y)
	)


# west_lon > east_lon denotes bounds crossing the antimeridian.
# padding_px is applied on every side. Widget must have a nonzero size.
func fit_bounds(
	south_lat: float, west_lon: float, north_lat: float, east_lon: float,
	tweened: bool = false, padding_px: float = 24.0,
) -> void:
	if _provider == null or cont_tile_renderer == null:
		return
	var view_size := cont_tile_renderer.size - Vector2.ONE * maxf(0.0, padding_px) * 2.0
	if view_size.x <= 0.0 or view_size.y <= 0.0:
		push_warning("fit_bounds() needs a sized DavidMaps Control with space for its padding.")
		return

	var south := clampf(minf(south_lat, north_lat), -MAX_MERCATOR_LATITUDE, MAX_MERCATOR_LATITUDE)
	var north := clampf(maxf(south_lat, north_lat), -MAX_MERCATOR_LATITUDE, MAX_MERCATOR_LATITUDE)
	var west := wrapf(west_lon, -180.0, 180.0)
	var east := wrapf(east_lon, -180.0, 180.0)
	# Keep the full-world case distinct from a zero-width meridian.
	var x_span := 1.0 if absf(east_lon - west_lon) >= 360.0 else fposmod(east - west, 360.0) / 360.0
	var north_y: float = _latitude_to_tile_y(north, 0.0)
	var south_y: float = _latitude_to_tile_y(south, 0.0)
	var y_span := south_y - north_y

	var target_zoom := float(_provider.max_zoom)
	var scaled_tile_size := _provider.tile_size * visualization_scale
	if x_span > 0.0:
		target_zoom = minf(target_zoom, log(view_size.x / (scaled_tile_size.x * x_span)) / log(2.0))
	if y_span > 0.0:
		target_zoom = minf(target_zoom, log(view_size.y / (scaled_tile_size.y * y_span)) / log(2.0))

	var center_world_x: float = fposmod(
		(west + 180.0) / 360.0 + x_span * 0.5,
		1.0,
	)
	var center_world_y: float = (north_y + south_y) * 0.5
	go_to(
		target_zoom,
		_tile_y_to_latitude(center_world_y, 0.0),
		_tile_x_to_longitude(center_world_x, 0.0),
		tweened,
	)


func get_provider() -> ProviderType:
	return _provider.type if _provider != null else provider_type


func get_layer() -> MapLayer:
	return _provider.layer if _provider != null else map_layer


# Array contains typed MapLayer values (e.g. MapLayer.ROAD).
func get_available_layers() -> Array[MapLayer]:
	if _provider == null:
		return Provider.layers_for_type(provider_type)
	# Return a copy, so external callers cannot change the provider's metadata.
	var layers: Array[MapLayer] = []
	layers.assign(_provider.available_layers)
	return layers


func get_layers_for_provider(type: ProviderType) -> Array[MapLayer]:
	return Provider.layers_for_type(type)


# Picks a supported layer if the new provider cannot serve the old one.
# Rebuilds the provider so the cache/request source ID is updated.
func set_provider(type: ProviderType) -> void:
	var old_type := get_provider()
	var old_layer := get_layer()
	provider_type = type
	if _provider == null:
		return
	_cancel_navigation()
	_provider = Provider.new(provider_type, map_layer)
	map_layer = _provider.layer
	var clamped_zoom := clampf(_target_zoom, _provider.min_zoom, _provider.max_zoom)
	if not is_equal_approx(clamped_zoom, _target_zoom):
		_apply_view(clamped_zoom, _center_latitude, _center_longitude)
	else:
		update()  # The source changed, even if camera coordinates did not.
	if old_type != type:
		provider_changed.emit(type)
	if old_layer != map_layer:
		layer_changed.emit(map_layer)


# Returns false (without changing anything) when the provider lacks the layer.
func set_layer(layer: MapLayer) -> bool:
	if not get_available_layers().has(layer):
		return false
	if get_layer() == layer:
		return true
	map_layer = layer
	if _provider != null:
		_cancel_navigation()
		_provider = Provider.new(provider_type, map_layer)
		update()
		layer_changed.emit(layer)
	return true


func get_available_overlays() -> Array[MapOverlay]:
	return [MapOverlay.SEAMARKS, MapOverlay.RAILWAYS]


func get_enabled_overlays() -> Array[MapOverlay]:
	var result: Array[MapOverlay] = []
	for overlay in get_available_overlays():
		if is_overlay_enabled(overlay):
			result.append(overlay)
	return result


func is_overlay_enabled(overlay: MapOverlay) -> bool:
	if not get_available_overlays().has(overlay):
		return false
	return (enabled_overlays & (1 << int(overlay))) != 0


func set_overlay_enabled(overlay: MapOverlay, enabled: bool) -> void:
	if not get_available_overlays().has(overlay):
		return
	if is_overlay_enabled(overlay) == enabled:
		return
	var bit := 1 << int(overlay)
	if enabled:
		enabled_overlays |= bit
	else:
		enabled_overlays &= ~bit
	if _provider != null:
		update()
	overlay_changed.emit(overlay, enabled)


# Return provider attribution destinations for a host application's clickable UI.
func get_attribution_links() -> PackedStringArray:
	var urls := _provider.attribution_urls.duplicate() if _provider != null else PackedStringArray()
	for overlay in get_enabled_overlays():
		if _overlay_sources.has(overlay):
			for url in _overlay_sources[overlay].attribution_urls:
				if not urls.has(url):
					urls.append(url)
	return urls

# These flags govern built-in gestures, NOT map_mouse_event delivery.
func set_interaction_enabled(enabled: bool) -> void:
	interaction_enabled = enabled
	_sync_mouse_scroll_passthrough()
	if not enabled:
		_end_drag()


func set_pan_enabled(enabled: bool) -> void:
	pan_enabled = enabled
	if not enabled:
		_end_drag()


func set_zoom_enabled(enabled: bool) -> void:
	zoom_enabled = enabled
	_sync_mouse_scroll_passthrough()

#endregion


#region Input
func _sync_mouse_scroll_passthrough() -> void:
	# While zooming, consume wheel events instead of scrolling an ancestor
	# ScrollContainer. When disabled, let the parent handle wheel events.
	mouse_force_pass_scroll_events = not (interaction_enabled and zoom_enabled)


func _gui_input(event: InputEvent) -> void:
	if not event is InputEventMouse:
		return

	var mouse_event: InputEventMouse = event
	var tile_zoom: int = _get_tile_zoom_level()
	var renderer_position: Vector2 = mouse_event.position - cont_tile_renderer.position
	var display_tile_size: Vector2 = _get_display_tile_size(tile_zoom)
	var longitude: float = _sanitize_longitude(
		_tile_x_to_longitude(
			_screen_to_tile_x(renderer_position.x, tile_zoom, display_tile_size.x),
			tile_zoom,
		)
	)
	var latitude: float = _sanitize_latitude(
		_tile_y_to_latitude(
			_screen_to_tile_y(renderer_position.y, tile_zoom, display_tile_size.y),
			tile_zoom,
		)
	)
	map_mouse_event.emit(mouse_event, latitude, longitude)

	if event is InputEventMouseMotion:
		var event_canvas_position: Vector2 = get_global_transform_with_canvas() * event.position
		_debug_mouse_position = (
			cont_debug_renderer.get_global_transform_with_canvas().affine_inverse()
			* event_canvas_position
		)
		_request_focus_position = (
			cont_tile_renderer.get_global_transform_with_canvas().affine_inverse()
			* event_canvas_position
		)
		_debug_mouse_inside = Rect2(Vector2.ZERO, cont_debug_renderer.size).has_point(
			_debug_mouse_position
		)
		_request_focus_inside = Rect2(Vector2.ZERO, cont_tile_renderer.size).has_point(
			_request_focus_position
		)
		cont_debug_renderer.queue_redraw()
		_schedule_request_reprioritization()

		if _is_dragging and interaction_enabled and pan_enabled:
			_cancel_navigation()
			_pan_by_screen_delta(event.relative)
		return

	if not event is InputEventMouseButton:
		return

	var button_event: InputEventMouseButton = event
	if button_event.button_index == MOUSE_BUTTON_MIDDLE:
		if button_event.pressed and interaction_enabled and pan_enabled:
			if not _is_dragging:
				_cancel_navigation()
				_is_dragging = true
				drag_started.emit()
		elif not button_event.pressed:
			_end_drag()
		return

	if not button_event.pressed or not interaction_enabled or not zoom_enabled:
		return
	var zoom_anchor := button_event.position - cont_tile_renderer.position
	var zoom_input_base := _get_navigation_target_zoom()
	var zoom_step := 0.2 * button_event.factor
	if button_event.button_index == MOUSE_BUTTON_WHEEL_UP:
		_set_zoom_level_at_screen_position(zoom_input_base + zoom_step, zoom_anchor)
	elif button_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_set_zoom_level_at_screen_position(zoom_input_base - zoom_step, zoom_anchor)


func _end_drag() -> void:
	if _is_dragging:
		_is_dragging = false
		drag_ended.emit()


func _pan_by_screen_delta(screen_delta: Vector2) -> void:
	var tile_zoom: int = _get_tile_zoom_level()
	var display_tile_size: Vector2 = _get_display_tile_size(tile_zoom)
	var world_tile_count: float = pow(2.0, tile_zoom)
	var center_tile_x: float = (
		_longitude_to_tile_x(_center_longitude, tile_zoom)
		- screen_delta.x / display_tile_size.x
	)
	var center_tile_y: float = (
		_latitude_to_tile_y(_center_latitude, tile_zoom)
		- screen_delta.y / display_tile_size.y
	)
	center_tile_x = fposmod(center_tile_x, world_tile_count)
	center_tile_y = clampf(center_tile_y, 0.0, world_tile_count)
	_apply_view(
		_target_zoom,
		_tile_y_to_latitude(center_tile_y, tile_zoom),
		_tile_x_to_longitude(center_tile_x, tile_zoom),
	)


func _set_zoom_level_at_screen_position(
			new_zoom_level: float,
			screen_position: Vector2
		) -> void:

	var clamped_zoom := _normalize_zoom(
		clampf(new_zoom_level, _provider.min_zoom, _provider.max_zoom)
	)
	if is_equal_approx(clamped_zoom, _target_zoom):
		return

	var old_tile_zoom: int = _get_tile_zoom_level()
	var old_display_tile_size: Vector2 = _get_display_tile_size(old_tile_zoom)
	var anchor_longitude: float = _tile_x_to_longitude(
		_screen_to_tile_x(screen_position.x, old_tile_zoom, old_display_tile_size.x),
		old_tile_zoom,
	)
	var anchor_latitude: float = _tile_y_to_latitude(
		_screen_to_tile_y(screen_position.y, old_tile_zoom, old_display_tile_size.y),
		old_tile_zoom,
	)
	var new_tile_zoom: int = _tile_zoom_from_value(clamped_zoom)
	var new_display_tile_size: Vector2 = _get_display_tile_size_at_zoom(
		new_tile_zoom,
		clamped_zoom,
	)
	var screen_offset: Vector2 = screen_position - cont_tile_renderer.size / 2.0
	var new_center_tile_x: float = (
		_longitude_to_tile_x(anchor_longitude, new_tile_zoom)
		- screen_offset.x / new_display_tile_size.x
	)
	var new_center_tile_y: float = (
		_latitude_to_tile_y(anchor_latitude, new_tile_zoom)
		- screen_offset.y / new_display_tile_size.y
	)
	var world_tile_count: float = pow(2.0, new_tile_zoom)
	new_center_tile_x = fposmod(new_center_tile_x, world_tile_count)
	new_center_tile_y = clampf(new_center_tile_y, 0.0, world_tile_count)
	go_to(
		clamped_zoom,
		_tile_y_to_latitude(new_center_tile_y, new_tile_zoom),
		_tile_x_to_longitude(new_center_tile_x, new_tile_zoom),
		true,
	)


func _get_navigation_target_zoom() -> float:
	if _navigation_tween != null and _navigation_tween.has_meta(&"target_zoom"):
		return float(_navigation_tween.get_meta(&"target_zoom"))
	return _target_zoom


func _cancel_navigation() -> void:
	if _navigation_tween != null:
		_navigation_tween.kill()
		_navigation_tween = null


func _animate_view(
	progress: float,
	start_world_x: float,
	start_world_y: float,
	end_world_x: float,
	end_world_y: float,
	from_zoom: float, to_zoom: float,
) -> void:
	var world_x: float = lerpf(start_world_x, end_world_x, progress)
	var world_y: float = lerpf(start_world_y, end_world_y, progress)
	_apply_view(
		lerpf(from_zoom, to_zoom, progress),
		_tile_y_to_latitude(world_y, 0.0),
		_tile_x_to_longitude(world_x, 0.0),
	)


func _on_navigation_finished() -> void:
	_navigation_tween = null
	navigation_finished.emit()


func _apply_view(zoom: float, latitude: float, longitude: float) -> void:
	if _provider == null:
		return
	var next_zoom: float = _normalize_zoom(
		clampf(zoom, _provider.min_zoom, _provider.max_zoom)
	)
	var next_longitude: float = _sanitize_longitude(longitude)
	var next_latitude: float = _sanitize_latitude(latitude)
	if (
		_target_zoom == next_zoom
		and _center_longitude == next_longitude
		and _center_latitude == next_latitude
	):
		return
	_target_zoom = next_zoom
	_center_longitude = next_longitude
	_center_latitude = next_latitude
	update()
	view_changed.emit(_target_zoom, _center_latitude, _center_longitude)


func _sanitize_longitude(longitude: float) -> float:
	return wrapf(longitude, -180.0, 180.0)


func _sanitize_latitude(latitude: float) -> float:
	return clampf(latitude, -MAX_MERCATOR_LATITUDE, MAX_MERCATOR_LATITUDE)


func _get_tile_zoom_level() -> int:
	return _tile_zoom_from_value(_target_zoom)


func _tile_zoom_from_value(zoom: float) -> int:
	return clampi(ceili(_normalize_zoom(zoom)), _provider.min_zoom, _provider.max_zoom)


func _normalize_zoom(zoom: float) -> float:
	var nearest_integer := roundf(zoom)
	return nearest_integer if is_equal_approx(zoom, nearest_integer) else zoom


func _get_display_tile_size(tile_zoom: int) -> Vector2:
	return _get_display_tile_size_at_zoom(tile_zoom, _target_zoom)


func _get_display_tile_size_at_zoom(tile_zoom: int, zoom: float) -> Vector2:
	var fractional_zoom_scale := pow(2.0, zoom - tile_zoom)
	return _provider.tile_size * visualization_scale * fractional_zoom_scale
#endregion


#region Renderer
func update() -> void:
	if not is_node_ready(): return
	_request_visible_tiles()
	_queue_renderer_redraw()


func _queue_renderer_redraw() -> void:
	if tile_canvas != null:
		tile_canvas.queue_redraw()
	if cont_debug_renderer != null:
		cont_debug_renderer.queue_redraw()


func _draw_renderer() -> void:
	var tile_zoom := _get_tile_zoom_level()
	var renderer_size := cont_tile_renderer.size
	if _last_rendered_tile_zoom >= 0 and _last_rendered_tile_zoom != tile_zoom:
		if _previous_rendered_source_id == _provider.source.id:
			_draw_tile_layer(_last_rendered_tile_zoom, renderer_size, _previous_rendered_tiles)
	_draw_tile_layer(tile_zoom, renderer_size, _visible_tiles)
	for overlay in get_enabled_overlays():
		if _visible_overlay_tiles.has(overlay) and _overlay_tile_zooms.has(overlay):
			_draw_tile_layer(
				_overlay_tile_zooms[overlay], renderer_size, _visible_overlay_tiles[overlay]
			)
	_draw_attribution()


func _draw_debug_renderer() -> void:
	if not debug_view_on or not _debug_mouse_inside:
		return
	_draw_renderer_debug(_debug_mouse_position)


func _on_mouse_exited() -> void:
	_debug_mouse_inside = false
	_request_focus_inside = false
	cont_debug_renderer.queue_redraw()
	_schedule_request_reprioritization()


func _draw_tile_layer(
			tile_zoom: int,
			renderer_size: Vector2,
			tiles: Dictionary
		) -> void:
	var display_tile_size: Vector2 = _get_display_tile_size(tile_zoom)
	var center_tile_x: float = _longitude_to_tile_x(_center_longitude, tile_zoom)
	var center_tile_y: float = _latitude_to_tile_y(_center_latitude, tile_zoom)
	var n: int = 1 << tile_zoom
	var center_screen: Vector2 = renderer_size / 2.0
	var tile_rect: Rect2i = _get_tile_grid_rect(
		center_tile_x,
		center_tile_y,
		renderer_size,
		display_tile_size,
	)

	for y_un in range(tile_rect.position.y, tile_rect.end.y):
		if y_un < 0 or y_un >= n:
			continue

		for x_un in range(tile_rect.position.x, tile_rect.end.x):
			var x_wr: int = ((x_un % n) + n) % n

			var tile_index := Vector3i(tile_zoom, x_wr, y_un) # (z,x,y)
			var tile: Tile = tiles.get(tile_index)
			if tile == null:
				continue

			var tex: Texture2D = tile.get_texture()
			if tex == null:
				continue

			var base_pos: Vector2 = center_screen + Vector2(
				(float(x_un) - center_tile_x) * display_tile_size.x,
				(float(y_un) - center_tile_y) * display_tile_size.y,
			)

			_draw_tex_if_visible(tex, base_pos, display_tile_size, renderer_size)


func _draw_renderer_debug(mouse_pos: Vector2) -> void:
	var tile_zoom: int = _get_tile_zoom_level()
	var display_tile_size: Vector2 = _get_display_tile_size(tile_zoom)
	var mouse_tile_x: float = _screen_to_tile_x(
		mouse_pos.x,
		tile_zoom,
		display_tile_size.x,
	)
	var mouse_tile_y: float = _screen_to_tile_y(
		mouse_pos.y,
		tile_zoom,
		display_tile_size.y,
	)
	var tile_x_unwrapped: int = floori(mouse_tile_x)
	var tile_y_unwrapped: int = floori(mouse_tile_y)

	# Indices for fetching/label (wrap X, clamp Y)
	var n: int = 1 << tile_zoom
	var tile_x: int = ((tile_x_unwrapped % n) + n) % n
	var tile_y: int = clampi(tile_y_unwrapped, 0, n - 1)

	# Use unwrapped indices so the box is exactly under the mouse.
	var center_tile_x: float = _longitude_to_tile_x(_center_longitude, tile_zoom)
	var center_tile_y: float = _latitude_to_tile_y(_center_latitude, tile_zoom)
	var top_left: Vector2 = (cont_tile_renderer.size / 2.0) + Vector2(
		(float(tile_x_unwrapped) - center_tile_x) * display_tile_size.x,
		(float(tile_y_unwrapped) - center_tile_y) * display_tile_size.y,
	)
	var r := Rect2(top_left, display_tile_size)

	# Draw: outline + center label
	cont_debug_renderer.draw_rect(r, Color(1, 0.3, 0.1, 1.0), false, 2.0)  # outline

	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()
	var label := str(Vector3i(tile_zoom, tile_x, tile_y))  # "(z, x, y)"
	var text_size := font.get_string_size(label, font_size)
	# center text in the tile
	var text_pos := top_left + display_tile_size * 0.5 - text_size * 0.5
	# nudge down a bit to account for ascent
	text_pos.y += font.get_ascent(font_size) * 0.5
	cont_debug_renderer.draw_string(
		font,
		text_pos,
		label,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		font_size,
		Color(0.076, 0.076, 0.076, 0.95))
	
	# small crosshair at mouse
	cont_debug_renderer.draw_line(
		mouse_pos + Vector2(-6, 0),
		mouse_pos + Vector2(6, 0),
		Color(1,1,1,0.5), 1.0)
	cont_debug_renderer.draw_line(
		mouse_pos + Vector2(0, -6),
		mouse_pos + Vector2(0, 6),
		Color(1,1,1,0.5), 1.0)


func _draw_tex_if_visible(
			tex: Texture2D,
			pos: Vector2,
			display_tile_size: Vector2,
			renderer_size: Vector2,
		) -> void:
	# quick cull so we don't overdraw offscreen
	var r := Rect2(pos, display_tile_size)
	if r.end.x <= 0 or r.position.x >= renderer_size.x or r.end.y <= 0 or r.position.y >= renderer_size.y:
		return
	tile_canvas.draw_texture_rect(tex, r, false)


func _draw_attribution() -> void:
	if not show_attribution:
		return
	var font := get_theme_default_font()
	var fs := get_theme_default_font_size()
	var renderer_size := cont_tile_renderer.size
	var max_text_width := maxf(40.0, renderer_size.x - 32.0)
	var attributions := PackedStringArray([_provider.attribution_text])
	for overlay in get_enabled_overlays():
		if _overlay_sources.has(overlay):
			attributions.append(_overlay_sources[overlay].attribution_text)
	# Wrap lengthy attribution strings so they are visible in narrower widgets.
	var lines := PackedStringArray()
	for attribution in attributions:
		var line := ""
		for word in attribution.split(" ", false):
			var candidate := word if line.is_empty() else line + " " + word
			if not line.is_empty() and font.get_string_size(candidate, fs).x > max_text_width:
				lines.append(line)
				line = word
			else:
				line = candidate
		if not line.is_empty():
			lines.append(line)
	if lines.is_empty():
		return
	var widest := 0.0
	for line in lines:
		widest = maxf(widest, font.get_string_size(line, fs).x)
	var line_height := font.get_height(fs) + 2.0
	var pad := Vector2(8, 5)
	var box_size := Vector2(widest, line_height * lines.size()) + pad * 2.0
	var box := Rect2(Vector2(maxf(0.0, renderer_size.x - box_size.x - 5.0),
		maxf(0.0, renderer_size.y - box_size.y - 5.0)), box_size)
	tile_canvas.draw_rect(box, Color(0, 0, 0, 0.65), true)
	var cursor := box.position + pad + Vector2(0.0, font.get_ascent(fs))
	for line in lines:
		tile_canvas.draw_string(font, cursor, line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)
		cursor.y += line_height


#endregion


#region Tiles Requests
func _request_visible_tiles() -> void:
	_visible_tiles.clear()
	_visible_overlay_tiles.clear()
	_overlay_tile_zooms.clear()
	var candidates: Array[TileLoadCandidate] = []

	var tile_zoom: int = _get_tile_zoom_level()
	_track_rendered_tile_zoom(tile_zoom)
	var display_tile_size: Vector2 = _get_display_tile_size(tile_zoom)
	var center_tile_x: float = _longitude_to_tile_x(_center_longitude, tile_zoom)
	var center_tile_y: float = _latitude_to_tile_y(_center_latitude, tile_zoom)
	var n: int = 1 << tile_zoom
	var tile_rect: Rect2i = _get_tile_grid_rect(
		center_tile_x,
		center_tile_y,
		cont_tile_renderer.size,
		display_tile_size,
	)

	for y_un in range(tile_rect.position.y, tile_rect.end.y):
		if y_un < 0 or y_un >= n:
			continue
		for x_un in range(tile_rect.position.x, tile_rect.end.x):
			var x_wr := posmod(x_un, n)
			var tile_index := Vector3i(tile_zoom, x_wr, y_un)
			if _visible_tiles.has(tile_index):
				continue
			var tile := _get_or_create_tile(_provider.source, tile_index)
			_visible_tiles[tile_index] = tile
			candidates.append(TileLoadCandidate.new(
				tile, _provider.url_from_index(tile_index), 0
			))

	# Overlays use independent zoom limits; high-zoom maps can upscale their
	# last native level, and low-zoom maps skip unsupported overlay levels.
	for overlay in get_enabled_overlays():
		var overlay_source: OverlaySource = _overlay_sources[overlay]
		if tile_zoom < overlay_source.min_zoom:
			continue
		var overlay_zoom: int = mini(tile_zoom, overlay_source.max_zoom)
		_overlay_tile_zooms[overlay] = overlay_zoom
		var overlay_tiles: Dictionary = {}
		_visible_overlay_tiles[overlay] = overlay_tiles
		var overlay_n: int = 1 << overlay_zoom
		var overlay_rect: Rect2i = _get_tile_grid_rect(
			_longitude_to_tile_x(_center_longitude, overlay_zoom),
			_latitude_to_tile_y(_center_latitude, overlay_zoom),
			cont_tile_renderer.size,
			_get_display_tile_size(overlay_zoom),
		)
		for y_un in range(overlay_rect.position.y, overlay_rect.end.y):
			if y_un < 0 or y_un >= overlay_n:
				continue
			for x_un in range(overlay_rect.position.x, overlay_rect.end.x):
				var tile_index := Vector3i(overlay_zoom, posmod(x_un, overlay_n), y_un)
				if overlay_tiles.has(tile_index):
					continue
				var tile := _get_or_create_tile(overlay_source.source, tile_index)
				overlay_tiles[tile_index] = tile
				candidates.append(TileLoadCandidate.new(
					tile,
					overlay_source.url_from_index(tile_index),
					1 + int(overlay),
				))

	_cancel_obsolete_tile_requests()
	_queue_tile_candidates(candidates)
	_trim_tile_cache()


func _get_or_create_tile(source: TileSourceDefinition, index: Vector3i) -> Tile:
	var definition := TileDefinition.new(source, index)
	var tile := _tile_cache.get_tile(definition)
	if tile == null:
		tile = Tile.new(definition)
		tile.image_updated.connect(_on_tile_image_updated)
		_tile_cache.store_tile(tile)
	return tile


func _queue_tile_candidates(candidates: Array[TileLoadCandidate]) -> void:
	for candidate in candidates:
		var distance_priority := _get_tile_distance_priority(candidate.tile.index)
		candidate.tile.request_image(
			tile_loader,
			candidate.url,
			int(distance_priority.x),
			candidate.layer_priority,
			distance_priority.y,
		)


# Returns (distance ring, exact squared screen-space distance). The world copy
# nearest to the focus is used so prioritization remains correct at the dateline.
func _get_tile_distance_priority(tile_index: Vector3i) -> Vector2:
	var tile_zoom: int = tile_index.x
	var display_tile_size: Vector2 = _get_display_tile_size(tile_zoom)
	var renderer_size: Vector2 = cont_tile_renderer.size
	var focus: Vector2 = (
		_request_focus_position if _request_focus_inside else renderer_size / 2.0
	)
	var focus_tile_x: float = _screen_to_tile_x(
		focus.x,
		tile_zoom,
		display_tile_size.x,
	)
	var center_tile_x: float = _longitude_to_tile_x(_center_longitude, tile_zoom)
	var center_tile_y: float = _latitude_to_tile_y(_center_latitude, tile_zoom)
	var world_tile_count: int = 1 << tile_zoom
	var unwrapped_x: float = float(tile_index.y) + roundf(
		(focus_tile_x - float(tile_index.y)) / float(world_tile_count)
	) * float(world_tile_count)
	var top_left: Vector2 = renderer_size / 2.0 + Vector2(
		(unwrapped_x - center_tile_x) * display_tile_size.x,
		(float(tile_index.z) - center_tile_y) * display_tile_size.y,
	)
	var tile_rect := Rect2(top_left, display_tile_size)
	var nearest_point := Vector2(
		clampf(focus.x, tile_rect.position.x, tile_rect.end.x),
		clampf(focus.y, tile_rect.position.y, tile_rect.end.y),
	)
	var distance_squared := focus.distance_squared_to(nearest_point)
	var ring := 0
	if not tile_rect.has_point(focus):
		var tile_extent := maxf(1.0, minf(display_tile_size.x, display_tile_size.y))
		ring = floori(sqrt(distance_squared) / tile_extent) + 1
	return Vector2(ring, distance_squared)


func _schedule_request_reprioritization() -> void:
	if _request_reprioritization_scheduled or not is_inside_tree():
		return
	_request_reprioritization_scheduled = true
	call_deferred("_reprioritize_visible_requests")


func _reprioritize_visible_requests() -> void:
	_request_reprioritization_scheduled = false
	if _provider == null or tile_loader == null or tile_loader.get_queued_request_count() == 0:
		return
	for tile in _visible_tiles.values():
		_update_tile_request_priority(tile, 0)
	for overlay in _visible_overlay_tiles:
		for tile in _visible_overlay_tiles[overlay].values():
			_update_tile_request_priority(tile, 1 + int(overlay))


func _update_tile_request_priority(tile: Tile, layer_priority: int) -> void:
	var distance_priority := _get_tile_distance_priority(tile.index)
	tile.update_image_request_priority(
		tile_loader,
		int(distance_priority.x),
		layer_priority,
		distance_priority.y,
	)


func _get_protected_tiles() -> Dictionary:
	var protected: Dictionary = {}
	protected[_provider.source.id] = _visible_tiles
	for overlay in _visible_overlay_tiles:
		protected[_overlay_sources[overlay].source.id] = _visible_overlay_tiles[overlay]
	return protected


func _cancel_obsolete_tile_requests() -> void:
	var protected := _get_protected_tiles()
	for tile in _tile_cache.get_all_tiles():
		var source_id := tile.definition.source.id
		if not protected.has(source_id) or not protected[source_id].has(tile.index):
			tile.cancel_image_request(tile_loader)


func _on_tile_image_updated(definition: TileDefinition) -> void:
	if definition.source.id == _provider.source.id:
		_queue_renderer_redraw()
		return
	for overlay in get_enabled_overlays():
		if _overlay_sources[overlay].source.id == definition.source.id:
			_queue_renderer_redraw()
			return


func _trim_tile_cache() -> void:
	while _tile_cache.size() > max_cached_tiles:
		var eviction_entry := _tile_cache.find_least_recently_used(_get_protected_tiles())
		if eviction_entry == null:
			break
		_evict_cached_tile(eviction_entry)


func _evict_cached_tile(entry: TileCacheEntry) -> void:
	entry.tile.cancel_image_request(tile_loader)
	_tile_cache.remove_tile(entry.definition)
	if entry.definition.source.id == _previous_rendered_source_id:
		_previous_rendered_tiles.erase(entry.definition.index)


func _track_rendered_tile_zoom(tile_zoom: int) -> void:
	var source_id := _provider.source.id
	if source_id != _rendered_source_id:
		_previous_rendered_tiles.clear()
		_previous_rendered_source_id = &""
		_last_rendered_tile_zoom = -1
		_rendered_source_id = source_id
		_rendered_tile_zoom = tile_zoom
		return

	if tile_zoom == _rendered_tile_zoom:
		return

	var loaded_snapshot: Dictionary[Vector3i, Tile] = {}
	if _rendered_tile_zoom >= 0:
		for tile in _tile_cache.get_tiles_for_source(source_id):
			if tile.index.x == _rendered_tile_zoom and tile.has_image():
				loaded_snapshot[tile.index] = tile

	if not loaded_snapshot.is_empty():
		_previous_rendered_tiles = loaded_snapshot
		_previous_rendered_source_id = source_id
		_last_rendered_tile_zoom = _rendered_tile_zoom

	_rendered_tile_zoom = tile_zoom


func _get_tile_grid_rect(
	center_tile_x: float,
	center_tile_y: float,
	renderer_size: Vector2,
	display_tile_size: Vector2,
	prefetch_padding: int = 1,
) -> Rect2i:
	var half_span: Vector2 = renderer_size / display_tile_size / 2.0
	var first := Vector2i(
		floori(center_tile_x - half_span.x) - prefetch_padding,
		floori(center_tile_y - half_span.y) - prefetch_padding,
	)
	var end := Vector2i(
		ceili(center_tile_x + half_span.x) + prefetch_padding,
		ceili(center_tile_y + half_span.y) + prefetch_padding,
	)
	return Rect2i(first, end - first)
#endregion


#region Canvas/Tile Coord
func _screen_to_tile_x(pixel_x: float, tile_zoom: int, tile_width: float) -> float:
	var center_tile_x: float = _longitude_to_tile_x(_center_longitude, tile_zoom)
	return center_tile_x + (pixel_x - cont_tile_renderer.size.x / 2.0) / tile_width


func _screen_to_tile_y(pixel_y: float, tile_zoom: int, tile_height: float) -> float:
	var center_tile_y: float = _latitude_to_tile_y(_center_latitude, tile_zoom)
	return center_tile_y + (pixel_y - cont_tile_renderer.size.y / 2.0) / tile_height


func _longitude_to_tile_x(longitude: float, zoom: float) -> float:
	return (longitude + 180.0) / 360.0 * pow(2.0, zoom)


func _latitude_to_tile_y(latitude: float, zoom: float) -> float:
	var latitude_radians: float = deg_to_rad(latitude)
	return (
		1.0
		- log(tan(latitude_radians) + 1.0 / cos(latitude_radians)) / PI
	) / 2.0 * pow(2.0, zoom)


func _tile_x_to_longitude(tile_x: float, zoom: float) -> float:
	return tile_x / pow(2.0, zoom) * 360.0 - 180.0


func _tile_y_to_latitude(tile_y: float, zoom: float) -> float:
	var tile_count: float = pow(2.0, zoom)
	return rad_to_deg(atan(sinh(PI * (1.0 - 2.0 * tile_y / tile_count))))
#endregion


#region Inner Classes
class TileSourceDefinition extends RefCounted:
	var id: StringName
	var layer_id: StringName
	var img_format: ImgFormat
	var tile_size: Vector2i

	func _init(_id: StringName, _layer_id: StringName,
			_img_format: ImgFormat, _tile_size: Vector2i) -> void:
		id = _id
		layer_id = _layer_id
		img_format = _img_format
		tile_size = _tile_size


class TileDefinition extends RefCounted:
	var source: TileSourceDefinition
	var index: Vector3i

	func _init(_source: TileSourceDefinition, _index: Vector3i) -> void:
		source = _source
		index = _index


class TileLoadCandidate extends RefCounted:
	var tile: Tile
	var url: String
	var layer_priority: int

	func _init(_tile: Tile, _url: String, _layer_priority: int) -> void:
		tile = _tile
		url = _url
		layer_priority = _layer_priority


# Raster basemap. See the suppliers' tile policies before distributing an app.
class Provider extends RefCounted:
	var type: ProviderType = ProviderType.OSM
	var layer: MapLayer = MapLayer.ROAD
	var available_layers: Array[MapLayer] = []
	var img_format: ImgFormat = ImgFormat.PNG
	var tile_size: Vector2 = Vector2(256, 256)
	var min_zoom: int = 0
	var max_zoom: int = 19
	var attribution_text: String = ""
	var attribution_urls: PackedStringArray = PackedStringArray()
	var source: TileSourceDefinition

	static func layers_for_type(provider: ProviderType) -> Array[MapLayer]:
		match provider:
			ProviderType.OSM, ProviderType.OSM_FRANCE:
				if provider == ProviderType.OSM_FRANCE:
					return [MapLayer.ROAD, MapLayer.HUMANITARIAN]
				return [MapLayer.ROAD]
			ProviderType.CYCLOSM:
				return [MapLayer.CYCLING, MapLayer.CYCLING_LITE]
			ProviderType.OPENMAPS:
				return [MapLayer.HIKING, MapLayer.TOPOGRAPHIC]
			ProviderType.OPNVKARTE:
				return [MapLayer.TRANSIT]
			ProviderType.USGS:
				return [MapLayer.TOPOGRAPHIC, MapLayer.SHADED_RELIEF, MapLayer.SATELLITE, MapLayer.HYBRID]
			ProviderType.OPENTOPOMAP:
				return [MapLayer.TOPOGRAPHIC]
			ProviderType.TERRARIUM:
				return [MapLayer.TERRAIN]
			ProviderType.WORLD_IMAGERY:
				return [MapLayer.SATELLITE]
		return [MapLayer.ROAD]

	func _init(_provider_type: ProviderType,
			_map_layer: MapLayer = MapLayer.ROAD) -> void:
		type = _provider_type
		available_layers = layers_for_type(type)
		layer = _map_layer if available_layers.has(_map_layer) else available_layers[0]
		var osm_link := "https://www.openstreetmap.org/copyright"
		match type:
			ProviderType.OSM:
				attribution_text = "© OpenStreetMap contributors"
				attribution_urls = [osm_link]
				max_zoom = 19
			ProviderType.OSM_FRANCE:
				attribution_text = "© OpenStreetMap contributors · OSM France / HOT"
				attribution_urls = [osm_link, "https://www.openstreetmap.fr/"]
				max_zoom = 20 if layer == MapLayer.ROAD else 19
			ProviderType.CYCLOSM:
				attribution_text = "© OpenStreetMap contributors · CyclOSM (CC BY-SA)"
				attribution_urls = [osm_link, "https://www.cyclosm.org/"]
				max_zoom = 20
			ProviderType.OPENMAPS:
				attribution_text = (
					"© OpenStreetMap · OpenHikingMap · donate: openmaps.fr/donate"
					if layer == MapLayer.HIKING else
					"© OpenStreetMap · OpenTopoMap-R · donate: openmaps.fr/donate"
				)
				attribution_urls = [osm_link, "https://openmaps.fr/donate",
					"https://wiki.openstreetmap.org/wiki/OpenHikingMap" if layer == MapLayer.HIKING
					else "https://github.com/sletuffe/OpenTopoMap"]
				max_zoom = 19
			ProviderType.OPNVKARTE:
				attribution_text = "Map © MeMoMaps CC BY-SA · Data © OpenStreetMap ODbL"
				attribution_urls = ["https://memomaps.de/", osm_link]
				max_zoom = 18
			ProviderType.USGS:
				img_format = ImgFormat.AUTO # ArcGIS tiles are MIXED PNG/JPEG.
				attribution_text = "USGS The National Map / USDA (where applicable)"
				attribution_urls = ["https://www.usgs.gov/programs/national-geospatial-program/national-map"]
				max_zoom = 19
			ProviderType.OPENTOPOMAP:
				attribution_text = "© OpenTopoMap (CC BY-SA) · © OpenStreetMap"
				attribution_urls = ["https://opentopomap.org/", osm_link]
				max_zoom = 17
			ProviderType.TERRARIUM:
				attribution_text = "Mapzen Terrarium elevation tiles"
				attribution_urls = ["https://registry.opendata.aws/terrain-tiles/"]
				max_zoom = 15
			ProviderType.WORLD_IMAGERY:
				img_format = ImgFormat.AUTO
				attribution_text = "Tiles © Esri · Esri, Maxar, Earthstar Geographics, GIS User Community"
				attribution_urls = ["https://www.esri.com/en-us/legal/terms/full-master-agreement"]
				max_zoom = 19
		source = _create_source_definition()

	func url_from_index(tile_index: Vector3i) -> String:
		var z := tile_index.x
		var x := tile_index.y
		var y := tile_index.z
		match type:
			ProviderType.OSM:
				return "https://tile.openstreetmap.org/%d/%d/%d.png" % [z, x, y]
			ProviderType.OSM_FRANCE:
				var style := "hot" if layer == MapLayer.HUMANITARIAN else "osmfr"
				return "https://a.tile.openstreetmap.fr/%s/%d/%d/%d.png" % [style, z, x, y]
			ProviderType.CYCLOSM:
				var style := "cyclosm-lite" if layer == MapLayer.CYCLING_LITE else "cyclosm"
				return "https://a.tile-cyclosm.openstreetmap.fr/%s/%d/%d/%d.png" % [style, z, x, y]
			ProviderType.OPENMAPS:
				var style := "openhikingmap" if layer == MapLayer.HIKING else "opentopomap"
				return "https://tile.openmaps.fr/%s/%d/%d/%d.png" % [style, z, x, y]
			ProviderType.OPNVKARTE:
				return "https://tile.memomaps.de/tilegen/%d/%d/%d.png" % [z, x, y]
			ProviderType.USGS:
				var service := "USGSTopo"
				match layer:
					MapLayer.SHADED_RELIEF: service = "USGSShadedReliefOnly"
					MapLayer.SATELLITE: service = "USGSImageryOnly"
					MapLayer.HYBRID: service = "USGSImageryTopo"
				return "https://basemap.nationalmap.gov/arcgis/rest/services/%s/MapServer/tile/%d/%d/%d" % [service, z, y, x]
			ProviderType.OPENTOPOMAP:
				return "https://a.tile.opentopomap.org/%d/%d/%d.png" % [z, x, y]
			ProviderType.TERRARIUM:
				return "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/%d/%d/%d.png" % [z, x, y]
			ProviderType.WORLD_IMAGERY:
				return "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/%d/%d/%d" % [z, y, x]
		return ""

	func _create_source_definition() -> TileSourceDefinition:
		var layer_id := StringName(String(MapLayer.find_key(layer)).to_lower())
		var source_id := StringName("base:%d:%s" % [int(type), layer_id])
		return TileSourceDefinition.new(source_id, layer_id, img_format, Vector2i(tile_size))


class OverlaySource extends RefCounted:
	var type: MapOverlay
	var min_zoom: int = 0
	var max_zoom: int = 19
	var attribution_text: String
	var attribution_urls: PackedStringArray
	var source: TileSourceDefinition

	func _init(overlay: MapOverlay) -> void:
		type = overlay
		match type:
			MapOverlay.SEAMARKS:
				min_zoom = 0
				max_zoom = 18
				attribution_text = "Seamarks © OpenSeaMap · © OpenStreetMap (not for navigation)"
				attribution_urls = ["https://www.openseamap.org/", "https://www.openstreetmap.org/copyright"]
				source = TileSourceDefinition.new(&"overlay:openseamap:seamarks", &"seamarks", ImgFormat.PNG, Vector2i(256, 256))
			MapOverlay.RAILWAYS:
				min_zoom = 2
				max_zoom = 19
				attribution_text = "Railways © OpenRailwayMap (CC BY-SA 2.0) · © OpenStreetMap"
				attribution_urls = ["https://www.openrailwaymap.org/", "https://creativecommons.org/licenses/by-sa/2.0/", "https://www.openstreetmap.org/copyright"]
				# Served as 512px retina images for a logical 256px tile.
				source = TileSourceDefinition.new(&"overlay:openrailwaymap:standard", &"railways", ImgFormat.PNG, Vector2i(256, 256))

	func url_from_index(tile_index: Vector3i) -> String:
		var z := tile_index.x
		var x := tile_index.y
		var y := tile_index.z
		match type:
			MapOverlay.SEAMARKS:
				return "https://tiles.openseamap.org/seamark/%d/%d/%d.png" % [z, x, y]
			MapOverlay.RAILWAYS:
				return "https://tiles.openrailwaymap.org/standard/%d/%d/%d.png" % [z, x, y]
		return ""


class TileRequest extends RefCounted:
	signal completed(
		result: int,
		response_code: int,
		response_headers: PackedStringArray,
		body: PackedByteArray,
	)

	var url: String
	var custom_headers: PackedStringArray
	var cancelled: bool = false
	var distance_ring: int
	var layer_priority: int
	var distance_priority: float
	var sequence: int


	func _init(
		_url: String,
		_custom_headers: PackedStringArray,
		_distance_ring: int,
		_layer_priority: int,
		_distance_priority: float,
		_sequence: int,
	) -> void:
		url = _url
		custom_headers = _custom_headers
		distance_ring = _distance_ring
		layer_priority = _layer_priority
		distance_priority = _distance_priority
		sequence = _sequence


class Tile extends RefCounted:
	signal image_updated(definition: TileDefinition)
	signal request_completed(definition: TileDefinition, result: int, response_code: int)

	var definition: TileDefinition
	var index: Vector3i # (z, x, y) == (zoom level, longitude index, latitude index)
	var img_format: ImgFormat = ImgFormat.PNG
	
	# Data
	var _img_data: PackedByteArray
	var _texture: ImageTexture
	var _pending_request: TileRequest
	
	func _init(_definition: TileDefinition) -> void:
		definition = _definition
		index = definition.index
		img_format = definition.source.img_format
	
	
	func has_image() -> bool:
		return not _img_data.is_empty()


	func request_image(
		loader: TileLoader,
		url: String,
		distance_ring: int,
		layer_priority: int,
		distance_priority: float,
	) -> void:
		if has_image():
			return
		if loader == null or url.is_empty():
			return
		if _pending_request != null:
			loader.update_request_priority(
				_pending_request,
				distance_ring,
				layer_priority,
				distance_priority,
			)
			return

		var pending := loader.queue_request(
			url,
			PackedStringArray(),
			distance_ring,
			layer_priority,
			distance_priority,
		)
		_pending_request = pending
		var response: Array = await pending.completed

		if _pending_request != pending:
			return
		_pending_request = null

		var result: int = response[0]
		var response_code: int = response[1]
		var body: PackedByteArray = response[3]
		if result == HTTPRequest.RESULT_SUCCESS and response_code >= 200 and response_code < 300:
			_img_data = body
			_texture = null
			image_updated.emit(definition)

		request_completed.emit(definition, result, response_code)


	func update_image_request_priority(
		loader: TileLoader,
		distance_ring: int,
		layer_priority: int,
		distance_priority: float,
	) -> void:
		if loader == null or _pending_request == null:
			return
		loader.update_request_priority(
			_pending_request,
			distance_ring,
			layer_priority,
			distance_priority,
		)


	func cancel_image_request(loader: TileLoader) -> bool:
		if loader == null or _pending_request == null:
			return false
		return loader.cancel_request(_pending_request)
	
	
	func get_image() -> Image:
		if not has_image():
			return null
		var format := img_format
		if format == ImgFormat.AUTO:
			if _img_data.size() >= 8 and _img_data[0] == 0x89 and _img_data[1] == 0x50:
				format = ImgFormat.PNG
			elif _img_data.size() >= 3 and _img_data[0] == 0xff and _img_data[1] == 0xd8:
				format = ImgFormat.JPG
			elif _img_data.size() >= 4 and _img_data[0] == 0x52 and _img_data[1] == 0x49:
				format = ImgFormat.WEBP
			else:
				return null
		var img := Image.new()
		var error := ERR_FILE_UNRECOGNIZED
		match format:
			ImgFormat.BMP: error = img.load_bmp_from_buffer(_img_data)
			ImgFormat.JPG: error = img.load_jpg_from_buffer(_img_data)
			ImgFormat.PNG: error = img.load_png_from_buffer(_img_data)
			ImgFormat.TGA: error = img.load_tga_from_buffer(_img_data)
			ImgFormat.WEBP: error = img.load_webp_from_buffer(_img_data)
		return img if error == OK else null


	func get_texture() -> Texture2D:
		if _texture != null:
			return _texture
		var image := get_image()
		if image == null or image.is_empty():
			return null
		_texture = ImageTexture.create_from_image(image)
		return _texture


class TileCacheEntry extends RefCounted:
	var definition: TileDefinition
	var tile: Tile
	var last_used: int


	func _init(_tile: Tile, _last_used: int) -> void:
		tile = _tile
		definition = tile.definition
		last_used = _last_used


class TileCache extends RefCounted:
	var _tiles_by_source: Dictionary[StringName, Dictionary] = {}
	var _tile_count: int = 0
	var _access_serial: int = 0


	func get_tile(definition: TileDefinition) -> Tile:
		if not _tiles_by_source.has(definition.source.id):
			return null
		var source_tiles: Dictionary = _tiles_by_source[definition.source.id]

		var entry: TileCacheEntry = source_tiles.get(definition.index)
		if entry == null:
			return null
		_touch(entry)
		return entry.tile


	func store_tile(tile: Tile) -> void:
		var source_id := tile.definition.source.id
		var source_tiles: Dictionary
		if _tiles_by_source.has(source_id):
			source_tiles = _tiles_by_source[source_id]
		else:
			source_tiles = {}
			_tiles_by_source[source_id] = source_tiles

		var existing: TileCacheEntry = source_tiles.get(tile.index)
		if existing != null:
			existing.tile = tile
			existing.definition = tile.definition
			_touch(existing)
			return

		_access_serial += 1
		source_tiles[tile.index] = TileCacheEntry.new(tile, _access_serial)
		_tile_count += 1


	func remove_tile(definition: TileDefinition) -> Tile:
		var source_id := definition.source.id
		if not _tiles_by_source.has(source_id):
			return null
		var source_tiles: Dictionary = _tiles_by_source[source_id]

		var entry: TileCacheEntry = source_tiles.get(definition.index)
		if entry == null:
			return null
		source_tiles.erase(definition.index)
		_tile_count -= 1
		if source_tiles.is_empty():
			_tiles_by_source.erase(source_id)
		return entry.tile


	func get_tiles_for_source(source_id: StringName) -> Array[Tile]:
		var tiles: Array[Tile] = []
		if not _tiles_by_source.has(source_id):
			return tiles
		var source_tiles: Dictionary = _tiles_by_source[source_id]
		for entry: TileCacheEntry in source_tiles.values():
			tiles.append(entry.tile)
		return tiles


	func get_all_tiles() -> Array[Tile]:
		var tiles: Array[Tile] = []
		for source_tiles: Dictionary in _tiles_by_source.values():
			for entry: TileCacheEntry in source_tiles.values():
				tiles.append(entry.tile)
		return tiles


	func find_least_recently_used(protected_sources: Dictionary) -> TileCacheEntry:
		var oldest: TileCacheEntry
		for source_id: StringName in _tiles_by_source:
			var source_tiles: Dictionary = _tiles_by_source[source_id]
			for tile_index: Vector3i in source_tiles:
				if protected_sources.has(source_id) and protected_sources[source_id].has(tile_index):
					continue
				var entry: TileCacheEntry = source_tiles[tile_index]
				if oldest == null or entry.last_used < oldest.last_used:
					oldest = entry
		return oldest


	func size() -> int:
		return _tile_count


	func _touch(entry: TileCacheEntry) -> void:
		_access_serial += 1
		entry.last_used = _access_serial


class TileLoader extends Node:
	signal queue_drained

	var user_agent: String = "DavidMaps/1.0"
	var allow_network: bool = true
	var concurrent_requests: int = 8:
		set(value):
			concurrent_requests = maxi(1, value)
			_schedule_pump()

	var _request_queue: Array[TileRequest] = []
	var _workers: Array[HTTPRequest] = []
	var _active_requests: Dictionary[HTTPRequest, TileRequest] = {}
	var _pump_scheduled: bool = false
	var _next_sequence: int = 0


	func _ready() -> void:
		_ensure_worker_pool()
		_pump_queue()


	func queue_request(
		url: String,
		custom_headers: PackedStringArray = PackedStringArray(),
		distance_ring: int = 0,
		layer_priority: int = 0,
		distance_priority: float = 0.0,
	) -> TileRequest:
		var pending := TileRequest.new(
			url,
			custom_headers,
			distance_ring,
			layer_priority,
			distance_priority,
			_next_sequence,
		)
		_next_sequence += 1
		_request_queue.append(pending)
		_schedule_pump()
		return pending


	func update_request_priority(
		pending: TileRequest,
		distance_ring: int,
		layer_priority: int,
		distance_priority: float,
	) -> void:
		if pending == null or pending.cancelled:
			return
		pending.distance_ring = distance_ring
		pending.layer_priority = layer_priority
		pending.distance_priority = distance_priority


	func get_queued_request_count() -> int:
		return _request_queue.size()


	func get_active_request_count() -> int:
		return _active_requests.size()


	func cancel_request(pending: TileRequest) -> bool:
		if pending == null or pending.cancelled:
			return false

		var queued_index := _request_queue.find(pending)
		if queued_index >= 0:
			_request_queue.remove_at(queued_index)
			_complete_cancelled_request(pending)
			return true

		for worker in _active_requests:
			if _active_requests[worker] != pending:
				continue
			_active_requests.erase(worker)
			worker.cancel_request()
			_complete_cancelled_request(pending)
			return true

		return false


	func _schedule_pump() -> void:
		if _pump_scheduled or not is_inside_tree():
			return
		_pump_scheduled = true
		call_deferred("_pump_queue")


	func _pump_queue() -> void:
		_pump_scheduled = false
		_ensure_worker_pool()

		while not _request_queue.is_empty():
			if _active_requests.size() >= concurrent_requests:
				return
			var worker := _get_available_worker()
			if worker == null:
				return

			var pending := _pop_highest_priority_request()
			_active_requests[worker] = pending

			if not allow_network:
				_finish_request(worker, HTTPRequest.RESULT_REQUEST_FAILED, 0, PackedStringArray(), PackedByteArray())
				continue

			var headers := pending.custom_headers.duplicate()
			if not user_agent.is_empty() and not _has_user_agent_header(headers):
				headers.append("User-Agent: %s" % user_agent)

			var error := worker.request(pending.url, headers)
			if error != OK:
				_finish_request(worker, HTTPRequest.RESULT_REQUEST_FAILED, 0, PackedStringArray(), PackedByteArray())


	func _pop_highest_priority_request() -> TileRequest:
		var best_index := 0
		for index in range(1, _request_queue.size()):
			if _has_higher_priority(_request_queue[index], _request_queue[best_index]):
				best_index = index
		return _request_queue.pop_at(best_index)


	func _has_higher_priority(candidate: TileRequest, current: TileRequest) -> bool:
		if candidate.distance_ring != current.distance_ring:
			return candidate.distance_ring < current.distance_ring
		if candidate.layer_priority != current.layer_priority:
			return candidate.layer_priority < current.layer_priority
		if not is_equal_approx(candidate.distance_priority, current.distance_priority):
			return candidate.distance_priority < current.distance_priority
		return candidate.sequence < current.sequence


	func _ensure_worker_pool() -> void:
		while _workers.size() < concurrent_requests:
			var worker := HTTPRequest.new()
			worker.request_completed.connect(_on_worker_request_completed.bind(worker))
			add_child(worker)
			_workers.append(worker)


	func _get_available_worker() -> HTTPRequest:
		for index in mini(_workers.size(), concurrent_requests):
			var worker := _workers[index]
			if not _active_requests.has(worker):
				return worker
		return null


	func _on_worker_request_completed(
		result: int,
		response_code: int,
		response_headers: PackedStringArray,
		body: PackedByteArray,
		worker: HTTPRequest,
	) -> void:
		_finish_request(worker, result, response_code, response_headers, body)


	func _finish_request(
		worker: HTTPRequest,
		result: int,
		response_code: int,
		response_headers: PackedStringArray,
		body: PackedByteArray,
	) -> void:
		var pending: TileRequest = _active_requests.get(worker)
		if pending == null:
			return
		_active_requests.erase(worker)
		pending.completed.emit(result, response_code, response_headers, body)
		_continue_or_finish_queue()


	func _complete_cancelled_request(pending: TileRequest) -> void:
		pending.cancelled = true
		pending.completed.emit(
			HTTPRequest.RESULT_REQUEST_FAILED,
			0,
			PackedStringArray(),
			PackedByteArray(),
		)
		_continue_or_finish_queue()


	func _continue_or_finish_queue() -> void:
		if _request_queue.is_empty() and _active_requests.is_empty():
			queue_drained.emit()
		else:
			_schedule_pump()


	func _has_user_agent_header(headers: PackedStringArray) -> bool:
		for header in headers:
			if header.to_lower().begins_with("user-agent:"):
				return true
		return false
#endregion
