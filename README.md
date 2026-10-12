# DavidMaps

[![Godot 4.7.2](https://img.shields.io/badge/Godot-4.7.2-478CBF?logo=godot-engine&logoColor=white)](https://godotengine.org/)

DavidMaps is a Godot 4 `Control` widget for displaying interactive raster tile maps inside regular UI layouts. It supports floating zoom levels, mouse-centered zooming, middle-button panning, runtime provider switching, overlays, and prioritized concurrent tile loading.

The project is under active development. It is currently developed and tested with Godot 4.7.2.

## Features

- Reusable `PanelContainer`-based map widget.
- Arbitrary floating zoom values with scaled raster tiles.
- High-precision panning and navigation at high zoom levels.
- Mouse-centered wheel zoom and middle-button drag panning.
- Tweened navigation across the shortest antimeridian path.
- Runtime basemap, layer, and overlay switching.
- Concurrent HTTP request queue prioritized by pointer proximity.
- Bounded in-memory least-recently-used tile cache.
- Previous-zoom fallback while the new zoom level loads.
- Screen-to-coordinate and coordinate-to-screen conversion.
- Optional built-in attribution and debug rendering.

## Installation

1. Copy `addons/DavidMaps` into your project's `addons` directory.
2. Open **Project > Project Settings > Plugins** and enable **DavidMaps**.
3. Add a `DavidMaps` node from the **Create New Node** dialog.
4. Give the node a usable size directly or place it inside a `Container` that controls its layout.

The widget creates its internal renderers and tile loader at runtime. It does not require a separate child scene.

## Quick start

Configure the initial provider, layer, zoom, latitude, and longitude from the Inspector. Navigation and source changes can also be controlled from GDScript:

```gdscript
extends Control

@onready var map: DavidMaps = %DavidMaps


func _ready() -> void:
	map.view_changed.connect(_on_map_view_changed)
	map.set_provider(DavidMaps.ProviderType.OPENTOPOMAP)
	map.set_layer(DavidMaps.MapLayer.TOPOGRAPHIC)
	map.go_to(8.7, 40.897, 14.998, true)


func _on_map_view_changed(zoom: float, lat: float, lon: float) -> void:
	print("Zoom %.2f at %.6f, %.6f" % [zoom, lat, lon])
```

Latitude and longitude arguments are always ordered as `(lat, lon)`. Geographic `Vector2` values use `(lon, lat)`.

## Interaction

- **Middle mouse button:** Pan the map.
- **Mouse wheel:** Zoom around the current pointer position.
- **Left mouse button:** No built-in action. Use `map_mouse_event` to implement selection, markers, or click-to-center behavior.

Built-in gestures can be controlled with `set_interaction_enabled()`, `set_pan_enabled()`, and `set_zoom_enabled()`. Mouse events continue to be emitted through `map_mouse_event` when individual gestures are disabled.

Example click-to-center behavior:

```gdscript
func _on_map_mouse_event(event: InputEventMouse, lat: float, lon: float) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			map.pan_to(lat, lon, true)
```

## Providers and layers

| Provider | Layers |
| --- | --- |
| `OSM` | Road |
| `WORLD_IMAGERY` | Satellite |
| `TERRARIUM` | Terrain |
| `OSM_FRANCE` | Road, Humanitarian |
| `CYCLOSM` | Cycling, Cycling Lite |
| `OPENMAPS` | Hiking, Topographic |
| `OPNVKARTE` | Transit |
| `USGS` | Topographic, Shaded Relief, Satellite, Hybrid |
| `OPENTOPOMAP` | Topographic |

Available overlays are `SEAMARKS` and `RAILWAYS`.

Use the source API instead of assigning `provider_type` or `map_layer` directly at runtime:

```gdscript
map.set_provider(DavidMaps.ProviderType.USGS)

for layer: DavidMaps.MapLayer in map.get_available_layers():
	print(DavidMaps.MapLayer.find_key(layer))

map.set_layer(DavidMaps.MapLayer.SATELLITE)
map.set_overlay_enabled(DavidMaps.MapOverlay.RAILWAYS, true)
```

Terrarium tiles contain RGB-encoded elevation data. DavidMaps currently displays the raw raster tile and does not decode it into shaded terrain or elevation values.

## API overview

### Navigation and coordinates

| Method | Description |
| --- | --- |
| `go_to(zoom, lat, lon, tweened)` | Change zoom and center together. |
| `go_tov(zoom, position, tweened)` | Vector form of `go_to()` using `(lon, lat)`. |
| `pan_to(lat, lon, tweened)` | Change the center without changing zoom. |
| `zoom_to(zoom, tweened)` | Change zoom while retaining the center. |
| `fit_bounds(south, west, north, east, tweened, padding_px)` | Fit geographic bounds inside the widget. |
| `get_zoom_level()` | Return the current floating zoom. |
| `get_center_coord()` | Return the current center as `(lon, lat)`. |
| `screen_to_coord(local_position)` | Convert a widget-local position to `(lon, lat)`. |
| `coord_to_screen(lat, lon)` | Convert a coordinate to a widget-local position. |

`fit_bounds()` supports antimeridian-crossing bounds by passing `west_lon > east_lon`.

### Sources and overlays

| Method | Description |
| --- | --- |
| `set_provider(provider)` | Switch basemap provider and select a compatible layer if necessary. |
| `get_provider()` | Return the active provider. |
| `set_layer(layer)` | Switch layer; returns `false` when unsupported. |
| `get_layer()` | Return the active layer. |
| `get_available_layers()` | Return layers supported by the active provider. |
| `get_layers_for_provider(provider)` | Return layers supported by another provider. |
| `set_overlay_enabled(overlay, enabled)` | Enable or disable an overlay. |
| `get_enabled_overlays()` | Return active overlays. |
| `get_attribution_links()` | Return attribution URLs for the active sources. |

### Signals

| Signal | Emitted when |
| --- | --- |
| `map_mouse_event(event, lat, lon)` | A mouse event occurs over the widget. |
| `view_changed(zoom, lat, lon)` | The visible center or zoom changes. |
| `navigation_finished` | A tweened navigation completes. |
| `drag_started` / `drag_ended` | Built-in middle-button dragging starts or ends. |
| `provider_changed(provider)` | The basemap provider changes. |
| `layer_changed(layer)` | The basemap layer changes. |
| `overlay_changed(overlay, enabled)` | An overlay is enabled or disabled. |

## Zoom and visualization scale

The public zoom is a floating-point value. DavidMaps requests tiles from the ceiling integer zoom level and scales them for the fractional part. For example, zoom `8.7` requests zoom-level `9` tiles.

`visualization_scale` is independent from geographic zoom. A value of `1.0` displays tiles at their logical size, while `2.0` doubles their rendered dimensions.

## Network use and attribution

DavidMaps requests data from third-party tile services. Availability, licensing, attribution, caching, request limits, and permitted use differ between providers and can change independently of this addon.

- Keep `show_attribution` enabled unless your application provides equivalent visible attribution.
- Set `tile_user_agent` to a stable, truthful application identifier with a contact URL or email before shipping.
- Review every selected provider's current usage policy before distributing an application.
- Do not use community tile servers for bulk downloading or offline prefetching unless their policy explicitly permits it.

The current cache is memory-only. Some services, including the standard OpenStreetMap tile service, require persistent caching according to their HTTP caching headers. Applications using those services must add compliant persistent caching or select a provider whose terms match their use case.

Useful references:

- [OpenStreetMap tile usage policy](https://operations.osmfoundation.org/policies/tiles/)
- [Esri attribution guidance](https://developers.arcgis.com/documentation/mapping-and-location-services/mapping/basemaps/introduction-basemap-styles-service/)
- [Terrarium terrain tiles](https://registry.opendata.aws/terrain-tiles/)

## Example project

Open and run `example.tscn` to try provider and layer switching, visualization scaling, debug rendering, pointer coordinates, and click-to-center navigation.

To validate the main script from the command line:

```text
godot --headless --path . --check-only --script res://addons/DavidMaps/DavidMaps.gd
```

## License

A project license has not been added yet. License information must be added before the first public distribution.
