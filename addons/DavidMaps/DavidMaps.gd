@icon ("david_maps_icon.svg")
extends PanelContainer
class_name DavidMaps

enum ProviderType {
	OSM,
	BING,
}

enum MapStyle {
	SATELLITE,
	STREET,
	HYBRID,
}

var provider: Provider
var provider_type: ProviderType = ProviderType.OSM
var map_style




class Provider extends RefCounted:
	var type: ProviderType


class Tile extends RefCounted:
	var vector: Vector3i # (z, x, y) == (zoom level, longitude index, latitude index)
