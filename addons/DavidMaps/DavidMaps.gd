@icon ("david_maps_icon.svg")
extends PanelContainer
class_name DavidMaps

#region Enums
enum ProviderType {
	OSM,
	BING,
	YANDEX,
}

enum MapStyle {
	SATELLITE,
	STREET,
	HYBRID,
}

enum ImgFormat {JPG, PNG, BMP, WEBP, TGA}
#endregion

@export var debug_view_on: bool = true
@export var provider_type: ProviderType = ProviderType.OSM
@export var show_attribution: bool = true
@export var map_style: MapStyle = MapStyle.STREET
@export_range(0.0, 20.0, 0.001) var start_zoom: float = 1.0
@export var start_longitude: float = 14.998
@export var start_latitude: float = 40.897
@export_enum("en", "it", "es", "fr", "ru", "de")
var language_code: String = "en"


var _provider: Provider
var tile_loader: TileLoader
var cont_tile_renderer: Control

var map_center_coord: Vector2
var pointer_coord: Vector2
var _last_zoom: int = -1
var _target_zoom: int = 0
var _current_zoom: float = 0
var _loaded_tiles: Dictionary = {} # key: Vector3i(z,x,y), value: ImageTexture
var _visible_tiles: Dictionary = {} # key: Vector3i(z,x,y), value: ImageTexture
var _tiles_to_display: Array[Vector3i] = []
var _wanted_keys: Dictionary = {}  # acts as a Set[Vector3i]



#region Init
func _ready() -> void:
	setup()
	draw.connect(_draw_renderer)
	resized.connect(update)
	update()


func setup() -> void:
	set_process(false)
	map_center_coord = Vector2(start_longitude, start_latitude)
	_current_zoom = start_zoom
	_target_zoom = start_zoom
	_provider = Provider.new(provider_type)


func setup_nodes() -> void:
	tile_loader = TileLoader.new()
	tile_loader.tile_loaded.connect(_on_tile_loaded)
	add_child(tile_loader)
	
	cont_tile_renderer = Control.new()
	cont_tile_renderer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cont_tile_renderer.clip_contents = true
	cont_tile_renderer.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	add_child(cont_tile_renderer)
	cont_tile_renderer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	
#endregion


func _gui_input(event: InputEvent) -> void:
	if not event is InputEventMouse: return
	if event is InputEventMouseMotion:
		var dragging: bool = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		if dragging:
			map_center_coord += _screen_to_tilef(event.relative, _current_zoom)
		queue_redraw()
	
	if event is InputEventMouseButton:
		if event.is_pressed():
			if event.button_index == MOUSE_BUTTON_WHEEL_UP: _target_zoom = clampi(_target_zoom + 1, 0, 19)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN: _target_zoom = clampi(_target_zoom - 1, 0, 19)
			queue_redraw()


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
	queue_redraw()


#region Renderer
func update() -> void:
	if not is_node_ready(): return
	if _last_zoom != _target_zoom:
		_visible_tiles.clear()
		_wanted_keys.clear()
		_last_zoom = _target_zoom
	_request_visible_tiles()
	queue_redraw()


func _draw_renderer() -> void:
	var center_f: Vector2 = _tile_coords_f(map_center_coord, _target_zoom)
	var n: int = 1 << _target_zoom
	var period_px: Vector2 = float(n) * _provider.tile_size
	var center_screen := size / 2.0

	var tiles_w := int(ceil(size.x / _provider.tile_size.x)) + 2
	var tiles_h := int(ceil(size.y / _provider.tile_size.y)) + 2

	var x0 := int(floor(center_f.x - tiles_w / 2.0))
	var y0 := int(floor(center_f.y - tiles_h / 2.0))

	for j in range(tiles_h):
		var y_un := y0 + j
		var y_wr := clampi(y_un, 0, n - 1)

		for i in range(tiles_w):
			var x_un := x0 + i
			var x_wr := ((x_un % n) + n) % n

			var key: Vector3i = Vector3i(_target_zoom, x_wr, y_wr) # (z,x,y)
			var tex: Texture2D = _visible_tiles.get(key)
			if tex == null:
				continue

			var base_pos := center_screen + Vector2(
				(x_un - center_f.x) * _provider.tile_size.x,
				(y_un - center_f.y) * _provider.tile_size.y
			)

			_draw_tex_if_visible(tex, base_pos)

			# repeat in X by world width
			if period_px.x > 0.0:
				var k_min := int(floor((-_provider.tile_size.x - base_pos.x) / period_px.x))
				var k_max := int(ceil((size.x + _provider.tile_size.x - base_pos.x) / period_px.x))
				for k in range(k_min, k_max + 1):
					if k == 0: continue
					_draw_tex_if_visible(tex, base_pos + Vector2(period_px.x * k, 0.0))
	
	# debug
	if debug_view_on:
		var m_pos: Vector2 = get_global_mouse_position()
		if get_global_rect().has_point(m_pos):
			_draw_renderer_debug(get_local_mouse_position())


func _draw_renderer_debug(mouse_pos: Vector2) -> void:
	# 1) Mouse → float tile coords
	var tf := _screen_to_tilef(mouse_pos, _current_zoom)
	var tile_x_unwrapped := int(floor(tf.x))
	var tile_y_unwrapped := int(floor(tf.y))

	# 2) Indices for fetching/label (wrap X, clamp Y)
	var n := int( pow(2.0, _target_zoom))
	var tile_x := ((tile_x_unwrapped % n) + n) % n
	var tile_y := clampi(tile_y_unwrapped, 0, n - 1)

	# 3) Where to draw the outline (use UNWRAPPED indices so the box is exactly under the mouse)
	var center_f := _coord_to_tilef(map_center_coord, _current_zoom)
	var tilef_scale: float = get_current_zoom_tilef_scale()
	var top_left := (size / 2.0) + Vector2(
		(tile_x_unwrapped - center_f.x),
		(tile_y_unwrapped - center_f.y)
	)
	top_left *= _provider.tile_size
	var r := Rect2(top_left, _provider.tile_size)

	# 4) Draw: outline + center label
	draw_rect(r, Color(1, 0.3, 0.1, 1.0), false, 2.0)  # outline

	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()
	var label := str(Vector3i(_target_zoom, tile_x, tile_y))  # "(z, x, y)"
	var text_size := font.get_string_size(label, font_size)
	# center text in the tile
	var text_pos := top_left + _provider.tile_size * 0.5 - text_size * 0.5
	# nudge down a bit to account for ascent
	text_pos.y += font.get_ascent(font_size) * 0.5
	draw_string(font, text_pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(1,1,1,0.95))

	# (optional) small crosshair at mouse
	draw_line(mouse_pos + Vector2(-6, 0), mouse_pos + Vector2(6, 0), Color(1,1,1,0.5), 1.0)
	draw_line(mouse_pos + Vector2(0, -6), mouse_pos + Vector2(0, 6), Color(1,1,1,0.5), 1.0)


func _draw_tex_if_visible(tex: Texture2D, pos: Vector2) -> void:
	# quick cull so we don't overdraw offscreen
	var r := Rect2(pos, _provider.tile_size)
	if r.end.x < 0 or r.position.x > size.x or r.end.y < 0 or r.position.y > size.y:
		return
	draw_texture(tex, pos)


func _draw_attribution() -> void:
	if not show_attribution: return
	var font := get_theme_default_font()
	var fs := get_theme_default_font_size()
	var pad := Vector2(8, 6)
	var text := _provider.attribution_text
	var size := font.get_string_size(text, fs)
	var box := Rect2(
		Vector2(size.x - size.x - pad.x * 2.0 - 8.0, size.y - size.y - pad.y * 2.0 - 8.0),
		size + pad * 2.0
	)
	draw_rect(box, Color(0,0,0,0.55), true)
	draw_rect(box, Color(1,1,1,0.25), false, 1.0)
	var pos := box.position + pad + Vector2(0, font.get_ascent(fs))
	draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1,1,1,0.96))
#endregion


#region Tiles Requests
func _request_visible_tiles() -> void:
	_wanted_keys.clear()
	
	var center_f := _tile_coords_f(map_center_coord, _target_zoom)
	var n := 1 << _target_zoom

	var tiles_w := int(ceil(size.x / _provider.tile_size.x)) + 2
	var tiles_h := int(ceil(size.y / _provider.tile_size.y)) + 2

	var x0 := int(floor(center_f.x - tiles_w / 2.0))
	var y0 := int(floor(center_f.y - tiles_h / 2.0))

	for j in range(tiles_h):
		for i in range(tiles_w):
			var x_un := x0 + i
			var y_un := y0 + j

			var x_wr := ((x_un % n) + n) % n   # wrap X for fetching
			var y_wr := clampi(y_un, 0, n - 1) # clamp Y

			var key := Vector3i(_target_zoom, x_wr, y_wr)  # (z,x,y)
			_wanted_keys[key] = true

			# Enqueue all; MapTileLoader will queue if needed
			#tile_loader.load_tile_by_indices(x_wr, y_wr, _target_zoom, true)
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
	var delta_tiles := (pix - (size / 2.0)) / _provider.tile_size
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
func _on_tile_loaded(status, tile: Tile) -> void:
	if status != OK or tile == null:
		return
	# Drop non-current zoom immediately
	if tile.index.z != _target_zoom:
		return
	
	if not _wanted_keys.has(tile.index):
		return

	var img := Image.new()
	var err := OK
	
	if tile.format == ImgFormat.JPG:
		err = img.load_jpg_from_buffer(tile.image)
	else:
		err = img.load_png_from_buffer(tile.image)
	if err != OK:
		return

	_visible_tiles[tile.index] = ImageTexture.create_from_image(img)
	queue_redraw()
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
	var img_format: ImgFormat = ImgFormat.PNG
	var language_code: String = "en"
	var tile_size: Vector2 = Vector2(256, 256)
	var attribution_text: String
	var attribution_url: String
	
	
	func _init(_provider_type: ProviderType) -> void:
		type = _provider_type
		match type:
			ProviderType.OSM:
				attribution_text = "© OpenStreetMap contributors"
				attribution_url = "https://www.openstreetmap.org/copyright"
	
	
	func url_from_coord(zoom: int, lon: float, lat: float) -> String:
		var index: Vector3i = DavidMaps.coord_to_tile_index(zoom, lon, lat)
		return url_from_index(index)
	
	
	func url_from_index(tile_index: Vector3i) -> String:
		var zoom: int = tile_index.x
		var lon: int = tile_index.y
		var lat: int = tile_index.z
		match type:
			ProviderType.BING:
				match style:
					MapStyle.SATELLITE: return ""
					MapStyle.STREET: return ""
					MapStyle.HYBRID: return ""
			
			ProviderType.OSM:
				return "https://tile.openstreetmap.org/%d/%d/%d.png" % [zoom, lon, lat]
		
		return ""
	
	
	#func _construct_quad_key(x: int, y: int, zoom: int) -> String:
		#var str: PackedByteArray = []
		#var i: int = zoom
		#
		#while i > 0:
			#i -= 1
			#var digit: int = 0x30
			#var mask: int = 1 << i
			#if (x & mask) != 0:
				#digit += 1
			#if (y & mask) != 0:
				#digit += 2
			#str.append(digit)
		#
		#return str.get_string_from_ascii()


class TileKey:
	var zoom: int
	var lon_idx: int
	var lat_idx: int
	
	func _init(_index: Vector3i) -> void:
		zoom = _index.x
		lon_idx = _index.y
		lat_idx = _index.z


class Tile extends RefCounted:
	var index: Vector3i # (z, x, y) == (zoom level, longitude index, latitude index)
	var bounds: Rect2
	var size: Vector2
	
	# from Map Provider
	var provider_type: ProviderType
	var tile_size: Vector2 = Vector2(256, 256)
	var img_format: ImgFormat = ImgFormat.PNG
	
	# Data
	var _img_data: PackedByteArray
	var key: TileKey
	
	
	func _init(_index: Vector3i, _size: Vector2) -> void:
		index = _index
		size = _size
		key = TileKey.new(index)
		bounds = DavidMaps.tile_index_to_bounds(key.zoom, key.lon_idx, key.lat_idx)
	
	
	func has_image() -> bool:
		return not _img_data.is_empty()
	
	
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


class TileLoader extends HTTPRequest:
	var user_agent: String = "Mozilla/5.0 Gecko/20100101 Firefox/118.0"
	var allow_network: bool = true
	var cache_tiles: bool = false
	var tile_provider: Provider
	var concurrent_requests: int = 1


class TileRenderer extends TextureRect:
	var index: Vector3i
	var zoom: int:
		get: return index.x
	
	
	func _init(_index: Vector3i) -> void:
		index = _index
		expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		stretch_mode = TextureRect.STRETCH_SCALE
#endregion
