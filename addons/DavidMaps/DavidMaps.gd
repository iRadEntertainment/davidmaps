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

enum ImgFormat {JPG, PNG, BTM, WEBP}
#endregion

@export var provider_type: ProviderType = ProviderType.OSM
@export var map_style: MapStyle = MapStyle.STREET
@export_enum("en", "it", "es", "fr", "ru", "de")
var language_code: String = "en"

var provider: Provider



func _ready() -> void:
	provider = Provider.new(provider_type)


#region Helpers
static func longitude_to_tile(zoom: int, lon: float) -> int:
	return floori((lon + 180.0) / 360.0 * (1 << zoom))


static func latitude_to_tile(zoom: int, lat: float) -> int:
	return floori(
			(1.0 - log(tan(deg_to_rad(lat)) + 1.0 / cos(deg_to_rad(lat))) / PI) /
			2.0 * (1 << zoom)
	)


static func coord_to_tile(zoom: int, lon: float, lat: float) -> Vector3i:
	return Vector3i(zoom, longitude_to_tile(zoom, lon), latitude_to_tile(zoom, lat))


static func tile_to_longitude(zoom: int, x: int) -> float:
	return x * 360.0 / (1 << zoom) - 180.0


static func tile_to_latitude(zoom: int, y: int) -> float:
	return rad_to_deg(atan(sinh(PI * (1 - 2.0 * y / (1 << zoom)))))


static func tile_to_coordinates(zoom: int, x: int, y: int) -> Vector2:
	return Vector2(tile_to_latitude(y, zoom), tile_to_longitude(x, zoom))


static func tile_to_bounds(zoom: int, x: int, y: int) -> Rect2:
	var lat = tile_to_latitude(zoom, y)
	var lon = tile_to_longitude(zoom, x)
	return Rect2(
			lon, lat,
			tile_to_longitude(zoom, x + 1) - lon, tile_to_latitude(zoom, y - 1) - lat
	)
#endregion


#region Inner Classes
class Provider extends RefCounted:
	var type: ProviderType
	
	var style: MapStyle
	var img_format: ImgFormat
	var language_code: String = "en"
	
	
	func _init(
				_type: ProviderType,
				_language_code := "en"
			) -> void:
		type = _type
		language_code = _language_code
	
	
	func url_from_coord(zoom: int, lat: float, long: float) -> String:
		var index: Vector3i
		return url_from_index(index)
	
	
	func url_from_index(tile_index: Vector3i) -> String:
		match type:
			ProviderType.BING:
				match style:
					MapStyle.SATELLITE: return ""
					MapStyle.STREET: return ""
					MapStyle.HYBRID: return ""
			
			ProviderType.OSM:
				return ""
			
			
		return ""
	
	func _get_parameters_from_index(zoom: int, x: int, y: int) -> Dictionary:
		return {
			"server": _select_server(x, y),
			"quad": _construct_quad_key(x, y, zoom),
			"x": x,
			"y": y,
			"zoom": zoom,
			
			"lang": language_code,
			"map_style": style,
			"format": img_format
		}
	
	
	func _construct_quad_key(x: int, y: int, zoom: int) -> String:
		var str: PackedByteArray = []
		var i: int = zoom
		
		while i > 0:
			i -= 1
			var digit: int = 0x30
			var mask: int = 1 << i
			if (x & mask) != 0:
				digit += 1
			if (y & mask) != 0:
				digit += 2
			str.append(digit)
		
		return str.get_string_from_ascii()
	
	
	func _select_server(x: int, y: int) -> int:
		return (x + 2 * y) % 4


class Tile extends RefCounted:
	var index: Vector3i # (z, x, y) == (zoom level, longitude index, latitude index)
	
	# from Map Provider
	var provider: Provider
	#var tile_size: Vector2 = Vector2(256, 256)
	#var img_format: ImgFormat
	#var language_code: String = "en"
	
	# Data
	var _img_data: PackedByteArray
	
	
	func save_to_file(filepath: String) -> void:
		var f := FileAccess.open(filepath, FileAccess.WRITE)
		f.store_buffer(_img_data)
		f.close()
	
	
	static func from_file(filepath: String) -> Tile:
		return Tile.new()
	
#endregion
