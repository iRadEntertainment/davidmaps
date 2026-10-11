@tool
@icon ("david_maps_icon.svg")
extends PanelContainer
class_name DavidMaps

#region Enums
enum ProviderType {
	OSM,
	WORLD_IMAGERY,
	TERRARIUM,
	BING,
	YANDEX,
}

enum MapLayer {
	ROAD,
	SATELLITE,
	HYBRID,
	TERRAIN,
	FUTURE_MAP,
	DRIVING,
	TRANSIT,
	ADMIN,
}

enum ImgFormat {JPG, PNG, BMP, WEBP, TGA}
#endregion

#region Signals
signal map_mouse_event(event: InputEventMouse, lat: float, lon: float)
signal view_changed(zoom: float, lat: float, lon: float)
signal navigation_finished
signal drag_started
signal drag_ended
signal provider_changed(provider: ProviderType)
signal layer_changed(layer: MapLayer)
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
@export var map_layer: int = MapLayer.ROAD
@export_range(0.0, 19.0, 0.01) var start_zoom: float = 10.0
@export var start_longitude: float = 14.998
@export var start_latitude: float = 40.897
@export_enum("en", "it", "es", "fr", "ru", "de")
var language_code: String = "en"
@export_group("Navigation")
@export_range(0.05, 5.0, 0.05, "suffix:s") var navigation_duration: float = 0.45
@export var interaction_enabled: bool = true
@export var pan_enabled: bool = true
@export var zoom_enabled: bool = true
@export_group("Provider Credentials")
@export var yandex_api_key: String = ""
@export_group("Tile Cache")
@export_range(1, 1000, 1) var max_cached_tiles: int = 50
@export_group("")

var _provider: Provider
var tile_loader: TileLoader
var cont_tile_renderer: Control
var cont_debug_renderer: Control
var tile_canvas: Control

var map_center_coord: Vector2
var _target_zoom: float = 0.0
var _rendered_tile_zoom: int = -1
var _last_rendered_tile_zoom: int = -1
var _rendered_source_id: StringName
var _previous_rendered_source_id: StringName
var _tile_cache := TileCache.new()
var _visible_tiles: Dictionary[Vector3i, Tile] = {}
var _previous_rendered_tiles: Dictionary[Vector3i, Tile] = {}
var _debug_mouse_position: Vector2
var _debug_mouse_inside: bool = false
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
	map_center_coord = _sanitize_coord(Vector2(start_longitude, start_latitude))
	_provider = Provider.new(provider_type, map_layer, language_code, yandex_api_key)
	map_layer = _provider.layer
	_target_zoom = clampf(start_zoom, _provider.min_zoom, _provider.max_zoom)
	var provider_error := _provider.get_configuration_error()
	if not provider_error.is_empty():
		push_warning(provider_error)
	
	# setup_nodes
	if tile_loader == null:
		tile_loader = TileLoader.new()
		add_child(tile_loader)

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
	var is_visible := true
	match property_name:
		&"map_layer":
			# Dynamic inspector enum: only show the selected provider's layers.
			var options := PackedStringArray()
			for layer in Provider.layers_for_type(provider_type):
				options.append("%s:%d" % [MapLayer.keys()[layer].capitalize(), layer])
			property.hint = PROPERTY_HINT_ENUM
			property.hint_string = ",".join(options)
		&"yandex_api_key":
			is_visible = provider_type == ProviderType.YANDEX
		&"language_code":
			is_visible = provider_type == ProviderType.BING or provider_type == ProviderType.YANDEX
	if not is_visible:
		property.usage = property.usage & ~PROPERTY_USAGE_EDITOR
#endregion


#region API
# All lat/lon arguments are degrees; returned Vector2 values are (lon, lat).
# Screen coordinates are LOCAL to this Control, including when placed inside
# other Controls/Containers. The closest horizontal world copy is used.

func go_to(zoom: float, lat: float, lon: float, tweened: bool = false) -> void:
	var destination := _sanitize_coord(Vector2(lon, lat))
	if _provider == null:
		start_zoom = zoom
		start_latitude = destination.y
		start_longitude = destination.x
		return

	var target_zoom := clampf(zoom, _provider.min_zoom, _provider.max_zoom)
	_cancel_navigation()
	if not tweened or not is_inside_tree() or navigation_duration <= 0.0:
		_apply_view(target_zoom, destination)
		return

	# Interpolate normalized Web Mercator coordinates instead of degrees.
	# Unwrap X across the shortest antimeridian path.
	var start_world := _coord_to_tilef(map_center_coord, 0.0)
	var end_world := _coord_to_tilef(destination, 0.0)
	var shortest_dx := fposmod(end_world.x - start_world.x + 0.5, 1.0) - 0.5
	end_world.x = start_world.x + shortest_dx
	var start_zoom_value := _target_zoom
	if start_world.is_equal_approx(end_world) and is_equal_approx(start_zoom_value, target_zoom):
		return

	_navigation_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_navigation_tween.tween_method(
		_animate_view.bind(start_world, end_world, start_zoom_value, target_zoom),
		0.0, 1.0, navigation_duration
	)
	_navigation_tween.finished.connect(_on_navigation_finished)


func pan_to(lat: float, lon: float, tweened: bool = false) -> void:
	go_to(get_zoom_level(), lat, lon, tweened)


func zoom_to(zoom: float, tweened: bool = false) -> void:
	var center := get_center_coord()
	go_to(zoom, center.y, center.x, tweened)


# Legacy entry point from the original widget.
func set_zoom_level(new_zoom_level: float) -> void:
	zoom_to(new_zoom_level)


func get_zoom_level() -> float:
	return _target_zoom if _provider != null else start_zoom


func get_center_coord() -> Vector2:
	return map_center_coord if _provider != null else Vector2(start_longitude, start_latitude)


func screen_to_coord(local_position: Vector2) -> Vector2:
	if _provider == null or cont_tile_renderer == null:
		return get_center_coord()
	var tile_zoom := _get_tile_zoom_level()
	var tile_pos := _screen_to_tilef(
		local_position - cont_tile_renderer.position,
		tile_zoom, _get_display_tile_size(tile_zoom)
	)
	return _sanitize_coord(_tilef_to_coord(tile_pos, tile_zoom))


func coord_to_screen(lat: float, lon: float) -> Vector2:
	if _provider == null or cont_tile_renderer == null:
		return size / 2.0
	var tile_zoom := _get_tile_zoom_level()
	var center_tiles := _coord_to_tilef(map_center_coord, tile_zoom)
	var point_tiles := _coord_to_tilef(_sanitize_coord(Vector2(lon, lat)), tile_zoom)
	var n := pow(2.0, tile_zoom)
	var delta := point_tiles - center_tiles
	delta.x = fposmod(delta.x + n * 0.5, n) - n * 0.5
	return cont_tile_renderer.position + cont_tile_renderer.size / 2.0 + delta * _get_display_tile_size(tile_zoom)


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
	var north_y := _coord_to_tilef(Vector2(0.0, north), 0.0).y
	var south_y := _coord_to_tilef(Vector2(0.0, south), 0.0).y
	var y_span := south_y - north_y

	var target_zoom := float(_provider.max_zoom)
	if x_span > 0.0:
		target_zoom = minf(target_zoom, log(view_size.x / (_provider.tile_size.x * x_span)) / log(2.0))
	if y_span > 0.0:
		target_zoom = minf(target_zoom, log(view_size.y / (_provider.tile_size.y * y_span)) / log(2.0))

	var center_world := Vector2(
		fposmod((west + 180.0) / 360.0 + x_span * 0.5, 1.0),
		(north_y + south_y) * 0.5
	)
	var center := _tilef_to_coord(center_world, 0.0)
	go_to(target_zoom, center.y, center.x, tweened)


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
	_provider = Provider.new(provider_type, map_layer, language_code, yandex_api_key)
	map_layer = _provider.layer
	var configuration_error := _provider.get_configuration_error()
	if not configuration_error.is_empty():
		push_warning(configuration_error)
	var clamped_zoom := clampf(_target_zoom, _provider.min_zoom, _provider.max_zoom)
	if not is_equal_approx(clamped_zoom, _target_zoom):
		_apply_view(clamped_zoom, map_center_coord)
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
		_provider = Provider.new(provider_type, map_layer, language_code, yandex_api_key)
		update()
		layer_changed.emit(layer)
	return true


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

	# Convert using the camera state at the instant the event arrives.
	var mouse_event: InputEventMouse = event
	var world_coord := screen_to_coord(mouse_event.position)
	map_mouse_event.emit(mouse_event, world_coord.y, world_coord.x)

	if event is InputEventMouseMotion:
		var event_canvas_position: Vector2 = get_global_transform_with_canvas() * event.position
		_debug_mouse_position = (
			cont_debug_renderer.get_global_transform_with_canvas().affine_inverse()
			* event_canvas_position
		)
		_debug_mouse_inside = Rect2(Vector2.ZERO, cont_debug_renderer.size).has_point(
			_debug_mouse_position
		)
		cont_debug_renderer.queue_redraw()

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
	if button_event.button_index == MOUSE_BUTTON_WHEEL_UP:
		_cancel_navigation()
		_set_zoom_level_at_screen_position(_target_zoom + 0.2, zoom_anchor)
	elif button_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_cancel_navigation()
		_set_zoom_level_at_screen_position(_target_zoom - 0.2, zoom_anchor)


func _end_drag() -> void:
	if _is_dragging:
		_is_dragging = false
		drag_ended.emit()


func _pan_by_screen_delta(screen_delta: Vector2) -> void:
	var tile_zoom := _get_tile_zoom_level()
	var display_tile_size := _get_display_tile_size(tile_zoom)
	var center_f := _coord_to_tilef(map_center_coord, tile_zoom)
	center_f -= screen_delta / display_tile_size
	var world_tile_count := pow(2.0, tile_zoom)
	center_f.x = fposmod(center_f.x, world_tile_count)
	center_f.y = clampf(center_f.y, 0.0, world_tile_count)
	_apply_view(_target_zoom, _tilef_to_coord(center_f, tile_zoom))


func _set_zoom_level_at_screen_position(new_zoom_level: float, screen_position: Vector2) -> void:
	var clamped_zoom := clampf(new_zoom_level, _provider.min_zoom, _provider.max_zoom)
	if is_equal_approx(clamped_zoom, _target_zoom):
		return

	var old_tile_zoom := _get_tile_zoom_level()
	var anchor_tile_f := _screen_to_tilef(screen_position, old_tile_zoom, _get_display_tile_size(old_tile_zoom))
	var anchor_coord := _tilef_to_coord(anchor_tile_f, old_tile_zoom)
	var new_tile_zoom := clampi(ceili(clamped_zoom), _provider.min_zoom, _provider.max_zoom)
	var new_display_tile_size := _provider.tile_size * pow(2.0, clamped_zoom - new_tile_zoom)
	var new_anchor_tile_f := _coord_to_tilef(anchor_coord, new_tile_zoom)
	var screen_offset_tiles := (screen_position - cont_tile_renderer.size / 2.0) / new_display_tile_size
	var new_center_f := new_anchor_tile_f - screen_offset_tiles
	var world_tile_count := pow(2.0, new_tile_zoom)
	new_center_f.x = fposmod(new_center_f.x, world_tile_count)
	new_center_f.y = clampf(new_center_f.y, 0.0, world_tile_count)
	_apply_view(clamped_zoom, _tilef_to_coord(new_center_f, new_tile_zoom))


func _cancel_navigation() -> void:
	if _navigation_tween != null:
		_navigation_tween.kill()
		_navigation_tween = null


func _animate_view(
	progress: float, start_world: Vector2, end_world: Vector2,
	from_zoom: float, to_zoom: float,
) -> void:
	var world := start_world.lerp(end_world, progress)
	var center := _tilef_to_coord(world, 0.0)
	_apply_view(lerpf(from_zoom, to_zoom, progress), center)


func _on_navigation_finished() -> void:
	_navigation_tween = null
	navigation_finished.emit()


func _apply_view(zoom: float, coord: Vector2) -> void:
	if _provider == null:
		return
	var next_zoom := clampf(zoom, _provider.min_zoom, _provider.max_zoom)
	var next_center := _sanitize_coord(coord)
	if is_equal_approx(_target_zoom, next_zoom) and map_center_coord.is_equal_approx(next_center):
		return
	_target_zoom = next_zoom
	map_center_coord = next_center
	update()
	view_changed.emit(_target_zoom, map_center_coord.y, map_center_coord.x)


func _sanitize_coord(coord: Vector2) -> Vector2:
	return Vector2(
		wrapf(coord.x, -180.0, 180.0),
		clampf(coord.y, -MAX_MERCATOR_LATITUDE, MAX_MERCATOR_LATITUDE)
	)


func _get_tile_zoom_level() -> int:
	return clampi(ceili(_target_zoom), _provider.min_zoom, _provider.max_zoom)


func _get_display_tile_size(tile_zoom: int) -> Vector2:
	var scale := pow(2.0, _target_zoom - tile_zoom)
	return _provider.tile_size * scale
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
		_draw_tile_layer(_last_rendered_tile_zoom, renderer_size, false)
	_draw_tile_layer(tile_zoom, renderer_size, true)
	_draw_attribution()


func _draw_debug_renderer() -> void:
	if not debug_view_on or not _debug_mouse_inside:
		return
	_draw_renderer_debug(_debug_mouse_position)


func _on_mouse_exited() -> void:
	_debug_mouse_inside = false
	cont_debug_renderer.queue_redraw()


func _draw_tile_layer(
			tile_zoom: int,
			renderer_size: Vector2,
			current_layer: bool
		) -> void:
	var display_tile_size := _get_display_tile_size(tile_zoom)
	var center_f: Vector2 = _coord_to_tilef(map_center_coord, tile_zoom)
	var n: int = 1 << tile_zoom
	var center_screen := renderer_size / 2.0
	var tile_rect := _get_tile_grid_rect(center_f, renderer_size, display_tile_size)

	for y_un in range(tile_rect.position.y, tile_rect.end.y):
		if y_un < 0 or y_un >= n:
			continue

		for x_un in range(tile_rect.position.x, tile_rect.end.x):
			var x_wr: int = ((x_un % n) + n) % n

			var tile_index := Vector3i(tile_zoom, x_wr, y_un) # (z,x,y)
			var tile: Tile
			if current_layer:
				tile = _visible_tiles.get(tile_index)
			elif _previous_rendered_source_id == _provider.source.id:
				tile = _previous_rendered_tiles.get(tile_index)
			if tile == null:
				continue

			var tex: Texture2D = tile.get_texture()
			if tex == null:
				continue

			var base_pos := center_screen + Vector2(
				(x_un - center_f.x) * display_tile_size.x,
				(y_un - center_f.y) * display_tile_size.y
			)

			_draw_tex_if_visible(tex, base_pos, display_tile_size, renderer_size)


func _draw_renderer_debug(mouse_pos: Vector2) -> void:
	var tile_zoom := _get_tile_zoom_level()
	var display_tile_size := _get_display_tile_size(tile_zoom)
	# Mouse -> float tile coords at the requested integer zoom.
	var tf := _screen_to_tilef(mouse_pos, tile_zoom, display_tile_size)
	var tile_x_unwrapped := int(floor(tf.x))
	var tile_y_unwrapped := int(floor(tf.y))

	# Indices for fetching/label (wrap X, clamp Y)
	var n: int = 1 << tile_zoom
	var tile_x: int = ((tile_x_unwrapped % n) + n) % n
	var tile_y: int = clampi(tile_y_unwrapped, 0, n - 1)

	# Where to draw the outline (use UNWRAPPED indices so the box is exactly under the mouse)
	var center_f: Vector2 = _coord_to_tilef(map_center_coord, tile_zoom)
	var top_left: Vector2 = (cont_tile_renderer.size / 2.0) + Vector2(
		(tile_x_unwrapped - center_f.x),
		(tile_y_unwrapped - center_f.y)
	) * display_tile_size
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
	if not show_attribution: return
	var font := get_theme_default_font()
	var fs := get_theme_default_font_size()
	var pad := Vector2(8, 6)
	var text := _provider.attribution_text
	var text_size := font.get_string_size(text, fs)
	var box := Rect2(
		cont_tile_renderer.size - text_size - pad * 2.0 - Vector2(8, 8),
		text_size + pad * 2.0
	)
	tile_canvas.draw_rect(box, Color(0,0,0,0.55), true)
	tile_canvas.draw_rect(box, Color(1,1,1,0.25), false, 1.0)
	var pos := box.position + pad + Vector2(0, font.get_ascent(fs))
	tile_canvas.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1,1,1,0.96))
#endregion


#region Tiles Requests
func _request_visible_tiles() -> void:
	_visible_tiles.clear()

	var tile_zoom := _get_tile_zoom_level()
	_track_rendered_tile_zoom(tile_zoom)
	var display_tile_size := _get_display_tile_size(tile_zoom)
	var center_f := _coord_to_tilef(map_center_coord, tile_zoom)
	var n := 1 << tile_zoom
	var tile_rect := _get_tile_grid_rect(center_f, cont_tile_renderer.size, display_tile_size)

	for y_un in range(tile_rect.position.y, tile_rect.end.y):
		if y_un < 0 or y_un >= n:
			continue

		for x_un in range(tile_rect.position.x, tile_rect.end.x):
			var x_wr := ((x_un % n) + n) % n
			var tile_index := Vector3i(tile_zoom, x_wr, y_un)  # (z,x,y)
			var definition := TileDefinition.new(_provider.source, tile_index)

			if _visible_tiles.has(tile_index):
				continue

			var tile := _tile_cache.get_tile(definition)
			if tile == null:
				tile = Tile.new(definition)
				tile.image_updated.connect(_on_tile_image_updated)
				_tile_cache.store_tile(tile)

			_visible_tiles[tile_index] = tile
			tile.request_image(tile_loader, _provider.url_from_index(tile_index))

	_trim_tile_cache()


func _on_tile_image_updated(definition: TileDefinition) -> void:
	if definition.source.id == _provider.source.id:
		_queue_renderer_redraw()


func _trim_tile_cache() -> void:
	while _tile_cache.size() > max_cached_tiles:
		var eviction_entry := _tile_cache.find_least_recently_used(
			_provider.source.id,
			_visible_tiles,
		)
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
		_cancel_obsolete_tile_requests(tile_zoom, source_id)
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

	_cancel_obsolete_tile_requests(tile_zoom, source_id)
	_rendered_tile_zoom = tile_zoom


func _cancel_obsolete_tile_requests(current_tile_zoom: int, current_source_id: StringName) -> void:
	for tile in _tile_cache.get_all_tiles():
		if tile.definition.source.id != current_source_id or tile.index.x != current_tile_zoom:
			tile.cancel_image_request(tile_loader)


func _get_tile_grid_rect(
	center_f: Vector2,
	renderer_size: Vector2,
	display_tile_size: Vector2,
	prefetch_padding: int = 1,
) -> Rect2i:
	var half_span := renderer_size / display_tile_size / 2.0
	var first := Vector2i(
		floori(center_f.x - half_span.x) - prefetch_padding,
		floori(center_f.y - half_span.y) - prefetch_padding,
	)
	var end := Vector2i(
		ceili(center_f.x + half_span.x) + prefetch_padding,
		ceili(center_f.y + half_span.y) + prefetch_padding,
	)
	return Rect2i(first, end - first)
#endregion


#region Canvas/Tile Coord
# Convert a pixel in renderer local coords to float tile coords.
func _screen_to_tilef(
			pix: Vector2,
			tile_zoom: int,
			display_tile_size: Vector2
		) -> Vector2:
	var center_f := _coord_to_tilef(map_center_coord, tile_zoom)
	var delta_tiles := (pix - (cont_tile_renderer.size / 2.0)) / display_tile_size
	return center_f + delta_tiles


func _coord_to_tilef(coord: Vector2, zoom: float) -> Vector2:
	var lat_rad = deg_to_rad(coord.y)
	var n = pow(2.0, zoom)
	var x = (coord.x + 180.0) / 360.0 * n
	var y = (1.0 - log(tan(lat_rad) + 1.0 / cos(lat_rad)) / PI) / 2.0 * n
	return Vector2(x, y)


func _tilef_to_coord(tile_coord: Vector2, zoom: float) -> Vector2:
	var n := pow(2.0, zoom)
	var longitude := tile_coord.x / n * 360.0 - 180.0
	var latitude := rad_to_deg(atan(sinh(PI * (1.0 - 2.0 * tile_coord.y / n))))
	return Vector2(longitude, latitude)
#endregion


#region Inner Classes
class TileSourceDefinition extends RefCounted:
	var id: StringName
	var provider_type: ProviderType
	var layer_id: StringName
	var language: StringName
	var img_format: ImgFormat
	var tile_size: Vector2i


	func _init(
				_id: StringName,
				_provider_type: ProviderType,
				_layer_id: StringName,
				_language: StringName,
				_img_format: ImgFormat,
				_tile_size: Vector2i,
			) -> void:
		id = _id
		provider_type = _provider_type
		layer_id = _layer_id
		language = _language
		img_format = _img_format
		tile_size = _tile_size


class TileDefinition extends RefCounted:
	var source: TileSourceDefinition
	var index: Vector3i


	func _init(_source: TileSourceDefinition, _index: Vector3i) -> void:
		source = _source
		index = _index


class Provider extends RefCounted:
	var type: ProviderType = ProviderType.OSM
	var layer: MapLayer = MapLayer.ROAD
	var available_layers: Array[MapLayer] = []
	var img_format: ImgFormat = ImgFormat.PNG
	var language_code: String = "en"
	var api_key: String
	var tile_size: Vector2 = Vector2(256, 256)
	var min_zoom: int = 0
	var max_zoom: int = 19
	var attribution_text: String
	var source: TileSourceDefinition


	static func layers_for_type(provider: ProviderType) -> Array[MapLayer]:
		match provider:
			ProviderType.OSM:
				return [MapLayer.ROAD]
			ProviderType.BING:
				return [MapLayer.ROAD, MapLayer.SATELLITE, MapLayer.HYBRID]
			ProviderType.YANDEX:
				return [MapLayer.ROAD, MapLayer.FUTURE_MAP, MapLayer.DRIVING, MapLayer.TRANSIT, MapLayer.ADMIN]
			ProviderType.TERRARIUM:
				return [MapLayer.TERRAIN]
			ProviderType.WORLD_IMAGERY:
				return [MapLayer.SATELLITE]
		return [MapLayer.ROAD]


	func _init(
				_provider_type: ProviderType,
				_map_layer: MapLayer = MapLayer.ROAD,
				_language_code: String = "en",
				_api_key: String = "",
			) -> void:
		type = _provider_type
		available_layers = layers_for_type(type)
		layer = _map_layer if available_layers.has(_map_layer) else available_layers[0]
		language_code = _language_code
		api_key = _api_key
		match type:
			ProviderType.OSM:
				img_format = ImgFormat.PNG
				attribution_text = "© OpenStreetMap contributors"
			ProviderType.BING:
				img_format = ImgFormat.JPG
				min_zoom = 1
				attribution_text = "© Microsoft Bing"
			ProviderType.YANDEX:
				img_format = ImgFormat.PNG
				attribution_text = "© Yandex"
			ProviderType.TERRARIUM:
				img_format = ImgFormat.PNG
				max_zoom = 15
				attribution_text = "Mapzen Terrain Tiles"
			ProviderType.WORLD_IMAGERY:
				img_format = ImgFormat.JPG
				attribution_text = "Tiles © Esri — Source: Esri, Maxar, Earthstar Geographics, and the GIS User Community"
		source = _create_source_definition()


	func get_configuration_error() -> String:
		if type == ProviderType.YANDEX and api_key.is_empty():
			return "Yandex Tiles API requires yandex_api_key. No Yandex tiles will be requested until it is set."
		return ""


	func url_from_index(tile_index: Vector3i) -> String:
		var zoom: int = tile_index.x
		var x: int = tile_index.y
		var y: int = tile_index.z
		match type:
			ProviderType.BING:
				var prefix: String
				match layer:
					MapLayer.SATELLITE: prefix = "a"
					MapLayer.HYBRID: prefix = "h"
					_: prefix = "r"
				var quadkey := _construct_quadkey(x, y, zoom)
				var subdomain := posmod(x + y, 4)
				return "https://ecn.t%d.tiles.virtualearth.net/tiles/%s%s.jpeg?g=1&mkt=%s" % [
					subdomain, prefix, quadkey, _bing_culture(),
				]

			ProviderType.OSM:
				return "https://tile.openstreetmap.org/%d/%d/%d.png" % [zoom, x, y]

			ProviderType.YANDEX:
				if api_key.is_empty():
					return ""
				return "https://tiles.api-maps.yandex.ru/v1/tiles/?apikey=%s&lang=%s&x=%d&y=%d&z=%d&l=map&projection=web_mercator&maptype=%s" % [
					api_key.uri_encode(), _yandex_language(), x, y, zoom, _yandex_maptype(),
				]

			ProviderType.TERRARIUM:
				return "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/%d/%d/%d.png" % [zoom, x, y]

			ProviderType.WORLD_IMAGERY:
				return "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/%d/%d/%d" % [zoom, y, x]

		return ""


	func _construct_quadkey(x: int, y: int, zoom: int) -> String:
		var quadkey := ""
		for level in range(zoom, 0, -1):
			var digit := 0
			var mask := 1 << (level - 1)
			if (x & mask) != 0:
				digit += 1
			if (y & mask) != 0:
				digit += 2
			quadkey += str(digit)
		return quadkey


	func _bing_culture() -> String:
		match language_code:
			"it": return "it-IT"
			"es": return "es-ES"
			"fr": return "fr-FR"
			"ru": return "ru-RU"
			"de": return "de-DE"
			_: return "en-US"


	func _yandex_language() -> String:
		if language_code == "ru":
			return "ru_RU"
		return "en_US"


	func _yandex_maptype() -> String:
		match layer:
			MapLayer.FUTURE_MAP: return "future_map"
			MapLayer.DRIVING: return "driving"
			MapLayer.TRANSIT: return "transit"
			MapLayer.ADMIN: return "admin"
			_: return "map"


	func _create_source_definition() -> TileSourceDefinition:
		var layer_id: StringName = StringName(MapLayer.keys()[layer].to_lower())
		var source_language: StringName
		var source_id: StringName
		match type:
			ProviderType.BING:
				source_language = StringName(_bing_culture())
				source_id = StringName("bing:%s:%s" % [layer_id, source_language])
			ProviderType.YANDEX:
				layer_id = StringName(_yandex_maptype())
				source_language = StringName(_yandex_language())
				source_id = StringName("yandex:%s:%s" % [layer_id, source_language])
			ProviderType.TERRARIUM:
				source_id = &"terrarium:terrain"
			ProviderType.WORLD_IMAGERY:
				source_id = &"world_imagery:satellite"
			_:
				source_id = &"osm:road"

		return TileSourceDefinition.new(
			source_id, type, layer_id, source_language,
			img_format, Vector2i(tile_size),
		)


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


	func _init(_url: String, _custom_headers: PackedStringArray) -> void:
		url = _url
		custom_headers = _custom_headers


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


	func request_image(loader: TileLoader, url: String) -> void:
		if has_image() or _pending_request != null:
			return
		if loader == null or url.is_empty():
			return

		var pending := loader.queue_request(url)
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


	func cancel_image_request(loader: TileLoader) -> bool:
		if loader == null or _pending_request == null:
			return false
		return loader.cancel_request(_pending_request)
	
	
	func get_image() -> Image:
		if not has_image(): return null
		var img := Image.new()
		match img_format:
			ImgFormat.BMP: img.load_bmp_from_buffer(_img_data)
			ImgFormat.JPG: img.load_jpg_from_buffer(_img_data)
			ImgFormat.PNG: img.load_png_from_buffer(_img_data)
			ImgFormat.TGA: img.load_tga_from_buffer(_img_data)
			ImgFormat.WEBP: img.load_webp_from_buffer(_img_data)
		return img


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


	func find_least_recently_used(
		protected_source_id: StringName,
		protected_indices: Dictionary,
	) -> TileCacheEntry:
		var oldest: TileCacheEntry
		for source_id: StringName in _tiles_by_source:
			var source_tiles: Dictionary = _tiles_by_source[source_id]
			for tile_index: Vector3i in source_tiles:
				if source_id == protected_source_id and protected_indices.has(tile_index):
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

	var user_agent: String = "Mozilla/5.0 Gecko/20100101 Firefox/118.0"
	var allow_network: bool = true
	var concurrent_requests: int = 8:
		set(value):
			concurrent_requests = maxi(1, value)
			_schedule_pump()

	var _request_queue: Array[TileRequest] = []
	var _workers: Array[HTTPRequest] = []
	var _active_requests: Dictionary[HTTPRequest, TileRequest] = {}
	var _pump_scheduled: bool = false


	func _ready() -> void:
		_ensure_worker_pool()
		_pump_queue()


	func queue_request(
		url: String,
		custom_headers: PackedStringArray = PackedStringArray(),
	) -> TileRequest:
		var pending := TileRequest.new(url, custom_headers)
		_request_queue.append(pending)
		_schedule_pump()
		return pending


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

			var pending: TileRequest = _request_queue.pop_front()
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
