@tool
@icon ("david_maps_icon.svg")
extends PanelContainer
class_name DavidMaps

#region Enums
enum ProviderType {
	OSM,
	BING,
	YANDEX,
	TERRARIUM,
	WORLD_IMAGERY,
}

enum MapStyle {
	SATELLITE,
	STREET,
	HYBRID,
}

enum YandexLayer {
	MAP,
	FUTURE_MAP,
	DRIVING,
	TRANSIT,
	ADMIN,
}

enum ImgFormat {JPG, PNG, BMP, WEBP, TGA}
#endregion

@export var debug_view_on: bool = true
@export var provider_type: ProviderType = ProviderType.OSM:
	set(value):
		provider_type = value
		notify_property_list_changed()
@export var show_attribution: bool = true
@export var map_style: MapStyle = MapStyle.STREET
@export var yandex_layer: YandexLayer = YandexLayer.MAP
@export_range(0.0, 19.0, 0.5) var start_zoom: float = 10.0
@export var start_longitude: float = 14.998
@export var start_latitude: float = 40.897
@export_enum("en", "it", "es", "fr", "ru", "de")
var language_code: String = "en"
@export_group("Provider Credentials")
@export var yandex_api_key: String = ""
@export_group("")


var _provider: Provider
var tile_loader: TileLoader
var cont_tile_renderer: Control
var tile_canvas: Control

var map_center_coord: Vector2
var pointer_coord: Vector2
var _last_zoom: int = -1
var _target_zoom: int = 0
var _current_zoom: float = 0
var _loaded_tiles: Dictionary[TileKey, Tile] = {}
var _visible_tiles: Dictionary[TileKey, Tile] = {}
var _tiles_to_display: Array[TileKey] = []
var _tile_keys_by_index: Dictionary[Vector3i, TileKey] = {}
var _wanted_keys: Dictionary[Vector3i, bool] = {}



#region Init
func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(false)
		return

	setup()
	tile_canvas.draw.connect(_draw_renderer)
	cont_tile_renderer.resized.connect(update)
	update()


func setup() -> void:
	set_process(false)
	map_center_coord = Vector2(start_longitude, start_latitude)
	_provider = Provider.new(provider_type, map_style, language_code, yandex_api_key, yandex_layer)
	_current_zoom = clampf(start_zoom, _provider.min_zoom, _provider.max_zoom)
	_target_zoom = clampi(roundi(start_zoom), _provider.min_zoom, _provider.max_zoom)
	var provider_error := _provider.get_configuration_error()
	if not provider_error.is_empty():
		push_warning(provider_error)
	setup_nodes()


func _validate_property(property: Dictionary) -> void:
	var property_name: StringName = property.name
	var is_visible := true
	match property_name:
		&"map_style":
			is_visible = provider_type == ProviderType.BING
		&"yandex_layer", &"yandex_api_key":
			is_visible = provider_type == ProviderType.YANDEX
		&"language_code":
			is_visible = provider_type == ProviderType.BING or provider_type == ProviderType.YANDEX

	if not is_visible:
		property.usage = property.usage & ~PROPERTY_USAGE_EDITOR


func setup_nodes() -> void:
	if tile_loader != null:
		return

	tile_loader = TileLoader.new()
	tile_loader.tile_provider = _provider
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
#endregion


func _gui_input(event: InputEvent) -> void:
	if not event is InputEventMouse: return
	if event is InputEventMouseMotion:
		var dragging: bool = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		if dragging:
			map_center_coord += _screen_to_tilef(event.relative, _current_zoom)
			update()
	
	if event is InputEventMouseButton:
		if event.is_pressed():
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_target_zoom = clampi(_target_zoom + 1, _provider.min_zoom, _provider.max_zoom)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_target_zoom = clampi(_target_zoom - 1, _provider.min_zoom, _provider.max_zoom)
			update()


var _tw_zoom: Tween
func set_zoom_level(_new_zoom_level: int) -> void:
	if _tw_zoom: _tw_zoom.kill()
	_tw_zoom = create_tween()
	_tw_zoom.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_CUBIC)
	_tw_zoom.tween_callback(set_process.bind(true))
	_tw_zoom.tween_property(self, ^"_current_zoom", _new_zoom_level, 0.5)
	_tw_zoom.tween_property(self, ^"_last_zoom", _new_zoom_level, 0.0)
	_tw_zoom.tween_callback(set_process.bind(false))


func _process(_delta: float) -> void:
	print(_delta)
	_queue_renderer_redraw()


#region Renderer
func update() -> void:
	if not is_node_ready(): return
	if _last_zoom != _target_zoom:
		_visible_tiles.clear()
		_wanted_keys.clear()
		_last_zoom = _target_zoom
	_request_visible_tiles()
	_queue_renderer_redraw()


func _queue_renderer_redraw() -> void:
	if tile_canvas != null:
		tile_canvas.queue_redraw()


func _draw_renderer() -> void:
	var center_f: Vector2 = _tile_coords_f(map_center_coord, _target_zoom)
	var n: int = 1 << _target_zoom
	var renderer_size := cont_tile_renderer.size
	var center_screen := renderer_size / 2.0
	var tile_rect := _get_tile_grid_rect(center_f, renderer_size)

	for y_un in range(tile_rect.position.y, tile_rect.end.y):
		if y_un < 0 or y_un >= n:
			continue

		for x_un in range(tile_rect.position.x, tile_rect.end.x):
			var x_wr: int = ((x_un % n) + n) % n

			var tile_index := Vector3i(_target_zoom, x_wr, y_un) # (z,x,y)
			var key: TileKey = _tile_keys_by_index.get(tile_index)
			if key == null:
				continue

			var tile: Tile = _visible_tiles.get(key)
			if tile == null:
				continue

			var tex: Texture2D = tile.get_texture()
			if tex == null:
				continue

			var base_pos := center_screen + Vector2(
				(x_un - center_f.x) * _provider.tile_size.x,
				(y_un - center_f.y) * _provider.tile_size.y
			)

			_draw_tex_if_visible(tex, base_pos, renderer_size)
	
	# debug
	if debug_view_on:
		var m_pos: Vector2 = get_global_mouse_position()
		if cont_tile_renderer.get_global_rect().has_point(m_pos):
			_draw_renderer_debug(cont_tile_renderer.get_local_mouse_position())
	_draw_attribution()


func _draw_renderer_debug(mouse_pos: Vector2) -> void:
	# Mouse → float tile coords
	var tf := _screen_to_tilef(mouse_pos, _target_zoom)
	var tile_x_unwrapped := int(floor(tf.x))
	var tile_y_unwrapped := int(floor(tf.y))

	# Indices for fetching/label (wrap X, clamp Y)
	var n: int = int(pow(2.0, _target_zoom))
	var tile_x: int = ((tile_x_unwrapped % n) + n) % n
	var tile_y: int = clampi(tile_y_unwrapped, 0, n - 1)

	# Where to draw the outline (use UNWRAPPED indices so the box is exactly under the mouse)
	var center_f: Vector2 = _coord_to_tilef(map_center_coord, _target_zoom)
	var top_left: Vector2 = (cont_tile_renderer.size / 2.0) + Vector2(
		(tile_x_unwrapped - center_f.x),
		(tile_y_unwrapped - center_f.y)
	) * _provider.tile_size
	var r := Rect2(top_left, _provider.tile_size)

	# Draw: outline + center label
	tile_canvas.draw_rect(r, Color(1, 0.3, 0.1, 1.0), false, 2.0)  # outline

	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()
	var label := str(Vector3i(_target_zoom, tile_x, tile_y))  # "(z, x, y)"
	var text_size := font.get_string_size(label, font_size)
	# center text in the tile
	var text_pos := top_left + _provider.tile_size * 0.5 - text_size * 0.5
	# nudge down a bit to account for ascent
	text_pos.y += font.get_ascent(font_size) * 0.5
	tile_canvas.draw_string(font, text_pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(1,1,1,0.95))

	# (optional) small crosshair at mouse
	tile_canvas.draw_line(mouse_pos + Vector2(-6, 0), mouse_pos + Vector2(6, 0), Color(1,1,1,0.5), 1.0)
	tile_canvas.draw_line(mouse_pos + Vector2(0, -6), mouse_pos + Vector2(0, 6), Color(1,1,1,0.5), 1.0)


func _draw_tex_if_visible(tex: Texture2D, pos: Vector2, renderer_size: Vector2) -> void:
	# quick cull so we don't overdraw offscreen
	var r := Rect2(pos, _provider.tile_size)
	if r.end.x <= 0 or r.position.x >= renderer_size.x or r.end.y <= 0 or r.position.y >= renderer_size.y:
		return
	tile_canvas.draw_texture(tex, pos)


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
	_wanted_keys.clear()
	_visible_tiles.clear()
	_tiles_to_display.clear()
	
	var center_f := _tile_coords_f(map_center_coord, _target_zoom)
	var n := 1 << _target_zoom
	var tile_rect := _get_tile_grid_rect(center_f, cont_tile_renderer.size)

	for y_un in range(tile_rect.position.y, tile_rect.end.y):
		if y_un < 0 or y_un >= n:
			continue

		for x_un in range(tile_rect.position.x, tile_rect.end.x):
			var x_wr := ((x_un % n) + n) % n
			var tile_index := Vector3i(_target_zoom, x_wr, y_un)  # (z,x,y)
			_wanted_keys[tile_index] = true

			var key := _get_or_create_tile_key(tile_index)
			if _visible_tiles.has(key):
				continue

			var tile: Tile = _loaded_tiles.get(key)
			if tile == null:
				tile = Tile.new(tile_index, _provider.tile_size, key)
				tile.provider_type = _provider.type
				tile.img_format = _provider.img_format
				tile.image_updated.connect(_queue_renderer_redraw)
				_loaded_tiles[key] = tile

			_visible_tiles[key] = tile
			_tiles_to_display.append(key)
			tile.request_image(tile_loader, _provider.url_from_index(tile_index))


func _get_or_create_tile_key(tile_index: Vector3i) -> TileKey:
	var key: TileKey = _tile_keys_by_index.get(tile_index)
	if key == null:
		key = TileKey.new(tile_index)
		_tile_keys_by_index[tile_index] = key
	return key


func _get_tile_grid_rect(
	center_f: Vector2,
	renderer_size: Vector2,
	prefetch_padding: int = 1,
) -> Rect2i:
	var half_span := renderer_size / _provider.tile_size / 2.0
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
func _tile_coords_f(coord: Vector2, zoom: float) -> Vector2:
	var lat_rad := deg_to_rad(coord.y)
	var n := pow(2.0, zoom)
	var x := (coord.x + 180.0) / 360.0 * n
	var y := (1.0 - log(tan(lat_rad) + 1.0 / cos(lat_rad)) / PI) / 2.0 * n
	return Vector2(x, y)


# Convert a pixel in renderer local coords to float tile coords
func _screen_to_tilef(pix: Vector2, zoom: float) -> Vector2:
	var center_f := _coord_to_tilef(map_center_coord, zoom)
	var delta_tiles := (pix - (cont_tile_renderer.size / 2.0)) / _provider.tile_size
	return center_f + delta_tiles


func _coord_to_tilef(coord: Vector2, zoom: float) -> Vector2:
	var lat_rad = deg_to_rad(coord.y)
	var n = pow(2.0, zoom)
	var x = (coord.x + 180.0) / 360.0 * n
	var y = (1.0 - log(tan(lat_rad) + 1.0 / cos(lat_rad)) / PI) / 2.0 * n
	return Vector2(x, y)


func get_current_zoom_tilef_scale() -> float:
	var diff: float = _current_zoom - _target_zoom
	var tilef_scale: float = lerp(1.0, 2.0, diff)
	return tilef_scale
#endregion


#region Script Signals
#func _on_tile_loaded(status, tile: Tile) -> void:
	#if status != OK or tile == null:
		#return
	## Drop non-current zoom immediately
	#if tile.index.z != _target_zoom:
		#return
	#
	#if not _wanted_keys.has(tile.index):
		#return
#
	#var img := Image.new()
	#var err := OK
	#
	#if tile.format == ImgFormat.JPG:
		#err = img.load_jpg_from_buffer(tile.image)
	#else:
		#err = img.load_png_from_buffer(tile.image)
	#if err != OK:
		#return
#
	#_visible_tiles[tile.index] = ImageTexture.create_from_image(img)
	#queue_redraw()
#endregion


#region Helpers
static func longitude_to_tile_index(zoom: int, lon: float) -> int:
	return floori((lon + 180.0) / 360.0 * (1 << zoom))


static func latitude_to_tile_index(zoom: int, lat: float) -> int:
	return floori(
			(1.0 - log(tan(deg_to_rad(lat)) + 1.0 / cos(deg_to_rad(lat))) / PI) /
			2.0 * (1 << zoom)
	)


static func coord_to_tile_index(zoom: int, lon: float, lat: float) -> Vector3i:
	return Vector3i(zoom, longitude_to_tile_index(zoom, lon), latitude_to_tile_index(zoom, lat))


static func tile_index_to_longitude(zoom: int, x: int) -> float:
	return x * 360.0 / (1 << zoom) - 180.0


static func tile_index_to_latitude(zoom: int, y: int) -> float:
	return rad_to_deg(atan(sinh(PI * (1 - 2.0 * y / (1 << zoom)))))


static func tile_index_to_coordinates(zoom: int, x: int, y: int) -> Vector2:
	return Vector2(tile_index_to_latitude(y, zoom), tile_index_to_longitude(x, zoom))


static func tile_index_to_bounds(zoom: int, x: int, y: int, tile_scale: float = 1.0) -> Rect2:
	var lat = tile_index_to_latitude(zoom, y)
	var lon = tile_index_to_longitude(zoom, x)
	var pos := Vector2()
	var bound_size := Vector2(
		tile_index_to_longitude(zoom, x + 1) - lon,
		tile_index_to_latitude(zoom, y - 1) - lat,
	)
	return Rect2(pos, bound_size)


static func degrees_per_pixel(size: Vector2i, bounds: Rect2) -> Vector2:
	var degrees = bounds.size
	return Vector2(degrees.x / size.x, degrees.y / size.y)


static func pixels_per_degree(size: Vector2i, bounds: Rect2) -> Vector2:
	var degrees = bounds.size
	return Vector2(size.x / degrees.x, size.y / degrees.y)
#endregion


#region Inner Classes
class Provider extends RefCounted:
	var type: ProviderType = ProviderType.OSM
	var style: MapStyle = MapStyle.STREET
	var yandex_layer: YandexLayer = YandexLayer.MAP
	var img_format: ImgFormat = ImgFormat.PNG
	var language_code: String = "en"
	var api_key: String
	var tile_size: Vector2 = Vector2(256, 256)
	var min_zoom: int = 0
	var max_zoom: int = 19
	var attribution_text: String
	var attribution_url: String
	
	
	func _init(
		_provider_type: ProviderType,
		_map_style: MapStyle = MapStyle.STREET,
		_language_code: String = "en",
		_api_key: String = "",
		_yandex_layer: YandexLayer = YandexLayer.MAP,
	) -> void:
		type = _provider_type
		style = _map_style
		yandex_layer = _yandex_layer
		language_code = _language_code
		api_key = _api_key
		match type:
			ProviderType.OSM:
				img_format = ImgFormat.PNG
				attribution_text = "© OpenStreetMap contributors"
				attribution_url = "https://www.openstreetmap.org/copyright"
			ProviderType.BING:
				img_format = ImgFormat.JPG
				min_zoom = 1
				attribution_text = "© Microsoft Bing"
				attribution_url = "https://www.microsoft.com/maps/product/terms.html"
			ProviderType.YANDEX:
				img_format = ImgFormat.PNG
				attribution_text = "© Yandex"
				attribution_url = "https://yandex.com/legal/maps_termsofuse/"
			ProviderType.TERRARIUM:
				img_format = ImgFormat.PNG
				max_zoom = 15
				attribution_text = "Mapzen Terrain Tiles"
				attribution_url = "https://github.com/tilezen/joerd/blob/master/docs/attribution.md"
			ProviderType.WORLD_IMAGERY:
				img_format = ImgFormat.JPG
				attribution_text = "Tiles © Esri — Source: Esri, Maxar, Earthstar Geographics, and the GIS User Community"
				attribution_url = "https://www.esri.com/en-us/legal/terms/full-master-agreement"


	func get_configuration_error() -> String:
		if type == ProviderType.YANDEX and api_key.is_empty():
			return "Yandex Tiles API requires yandex_api_key. No Yandex tiles will be requested until it is set."
		return ""
	
	
	func url_from_coord(zoom: int, lon: float, lat: float) -> String:
		var index: Vector3i = DavidMaps.coord_to_tile_index(zoom, lon, lat)
		return url_from_index(index)
	
	
	func url_from_index(tile_index: Vector3i) -> String:
		var zoom: int = tile_index.x
		var x: int = tile_index.y
		var y: int = tile_index.z
		match type:
			ProviderType.BING:
				var prefix: String
				match style:
					MapStyle.SATELLITE: prefix = "a"
					MapStyle.STREET: prefix = "r"
					MapStyle.HYBRID: prefix = "h"
				var quadkey := _construct_quadkey(x, y, zoom)
				var subdomain := posmod(x + y, 4)
				return "https://ecn.t%d.tiles.virtualearth.net/tiles/%s%s.jpeg?g=1&mkt=%s" % [
					subdomain,
					prefix,
					quadkey,
					_bing_culture(),
				]
			
			ProviderType.OSM:
				return "https://tile.openstreetmap.org/%d/%d/%d.png" % [zoom, x, y]

			ProviderType.YANDEX:
				if api_key.is_empty():
					return ""
				return "https://tiles.api-maps.yandex.ru/v1/tiles/?apikey=%s&lang=%s&x=%d&y=%d&z=%d&l=map&projection=web_mercator&maptype=%s" % [
					api_key.uri_encode(),
					_yandex_language(),
					x,
					y,
					zoom,
					_yandex_maptype(),
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
		match yandex_layer:
			YandexLayer.FUTURE_MAP: return "future_map"
			YandexLayer.DRIVING: return "driving"
			YandexLayer.TRANSIT: return "transit"
			YandexLayer.ADMIN: return "admin"
			_: return "map"


class TileKey:
	var zoom: int
	var lon_idx: int
	var lat_idx: int
	
	func _init(_index: Vector3i) -> void:
		zoom = _index.x
		lon_idx = _index.y
		lat_idx = _index.z


	func to_vector3i() -> Vector3i:
		return Vector3i(zoom, lon_idx, lat_idx)


class TileRequest extends RefCounted:
	signal completed(
		result: int,
		response_code: int,
		response_headers: PackedStringArray,
		body: PackedByteArray,
	)

	var url: String
	var custom_headers: PackedStringArray


	func _init(_url: String, _custom_headers: PackedStringArray) -> void:
		url = _url
		custom_headers = _custom_headers


class Tile extends RefCounted:
	signal image_updated
	signal request_completed(result: int, response_code: int)

	var index: Vector3i # (z, x, y) == (zoom level, longitude index, latitude index)
	var bounds: Rect2
	var size: Vector2
	
	# from Map Provider
	var provider_type: ProviderType
	var tile_size: Vector2 = Vector2(256, 256)
	var img_format: ImgFormat = ImgFormat.PNG
	
	# Data
	var _img_data: PackedByteArray
	var _texture: ImageTexture
	var _pending_request: TileRequest
	var key: TileKey
	
	func _init(_index: Vector3i, _size: Vector2, _key: TileKey = null) -> void:
		index = _index
		size = _size
		key = _key if _key != null else TileKey.new(index)
		bounds = DavidMaps.tile_index_to_bounds(key.zoom, key.lon_idx, key.lat_idx)
	
	
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
			image_updated.emit()

		request_completed.emit(result, response_code)
	
	
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
	
	
	func save_to_file(filepath: String) -> void:
		var f := FileAccess.open(filepath, FileAccess.WRITE)
		f.store_var(index, true)
		f.store_var(size, true)
		f.store_32(img_format)
		f.store_32(len(_img_data))
		f.store_buffer(_img_data)
		f.close()
	
	
	static func from_file(filepath: String) -> Tile:
		if not FileAccess.file_exists(filepath):
			return null
		var f := FileAccess.open(filepath, FileAccess.READ)
		var _index: Vector3i = f.get_var(true)
		var _size: Vector2 = f.get_var(true)
		var _format: ImgFormat = f.get_32()
		var _img_data_buffer_len: int = f.get_32()
		var _img_data: PackedByteArray = f.get_buffer(_img_data_buffer_len)
		return Tile.new(_index, _size)


class TileLoader extends Node:
	signal queue_drained

	var user_agent: String = "Mozilla/5.0 Gecko/20100101 Firefox/118.0"
	var allow_network: bool = true
	var cache_tiles: bool = false
	var tile_provider: Provider
	var concurrent_requests: int = 4:
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
		if _request_queue.is_empty() and _active_requests.is_empty():
			queue_drained.emit()
		else:
			_schedule_pump()


	func _has_user_agent_header(headers: PackedStringArray) -> bool:
		for header in headers:
			if header.to_lower().begins_with("user-agent:"):
				return true
		return false


class TileRenderer extends TextureRect:
	var index: Vector3i
	var zoom: int:
		get: return index.x
	
	
	func _init(_index: Vector3i) -> void:
		index = _index
		expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		stretch_mode = TextureRect.STRETCH_SCALE
#endregion
