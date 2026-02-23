extends Control
class_name BoundingBoxOverlay

@export var box_color: Color = Color(1.0, 1.0, 0.0, 1.0)
@export_range(1.0, 12.0, 1.0) var line_width: float = 2.0

var rects: Array[Rect2] = []
var selected_ids: Array[int] = []
var segment_bounds_uv: Dictionary = {}

var reference_image: Image
var pan: Vector2 = Vector2(0.5, 0.5)
var zoom: float = 1.0

func set_selected_ids(ids: Array[int]) -> void:
	selected_ids = ids.duplicate()
	_refresh_rects()

func set_segment_bounds_uv(bounds_uv: Dictionary) -> void:
	segment_bounds_uv = bounds_uv.duplicate(true)
	_refresh_rects()

func set_view(image: Image, next_pan: Vector2, next_zoom: float) -> void:
	reference_image = image
	pan = next_pan
	zoom = next_zoom
	_refresh_rects()

func compute_segment_bounds_uv(panoptic_image: Image) -> Dictionary:
	var bounds_px: Dictionary = {}
	var image_size := panoptic_image.get_size()
	var width := image_size.x
	var height := image_size.y

	for y in range(height):
		for x in range(width):
			var col: Color = panoptic_image.get_pixel(x, y)
			var r: int = int(round(col.r * 255.0))
			var g: int = int(round(col.g * 255.0))
			var b: int = int(round(col.b * 255.0))
			var id: int = r + g * 256 + b * 256 * 256
			if id == 0:
				continue

			if not bounds_px.has(id):
				bounds_px[id] = Rect2i(x, y, 1, 1)
				continue

			var rect: Rect2i = bounds_px[id]
			var left := min(rect.position.x, x)
			var top := min(rect.position.y, y)
			var right := max(rect.end.x - 1, x)
			var bottom := max(rect.end.y - 1, y)
			bounds_px[id] = Rect2i(left, top, right - left + 1, bottom - top + 1)

	var bounds_uv: Dictionary = {}
	for id in bounds_px.keys():
		var rect_px: Rect2i = bounds_px[id]
		var min_uv := Vector2(
			float(rect_px.position.x) / float(width),
			float(rect_px.position.y) / float(height)
		)
		var max_uv := Vector2(
			float(rect_px.end.x) / float(width),
			float(rect_px.end.y) / float(height)
		)
		bounds_uv[id] = Rect2(min_uv, max_uv - min_uv)

	return bounds_uv

func _refresh_rects() -> void:
	var next_rects: Array[Rect2] = []
	if reference_image == null or selected_ids.is_empty():
		rects = next_rects
		queue_redraw()
		return

	for id in selected_ids:
		if not segment_bounds_uv.has(id):
			continue
		var uv_rect: Rect2 = segment_bounds_uv[id]
		var min_screen := _tex_to_screen_with_letterbox(uv_rect.position)
		var max_screen := _tex_to_screen_with_letterbox(uv_rect.end)
		next_rects.append(Rect2(min_screen, max_screen - min_screen).abs())

	rects = next_rects
	queue_redraw()

func _tex_to_screen_with_letterbox(tex_uv: Vector2) -> Vector2:
	if reference_image == null:
		return Vector2.ZERO

	var r_uv: Vector2 = (tex_uv - pan) * zoom + Vector2(0.5, 0.5)
	var tex_aspect: float = float(reference_image.get_size().x) / float(reference_image.get_size().y)
	var ctrl_aspect: float = size.x / size.y

	var uv: Vector2
	if tex_aspect <= ctrl_aspect:
		var width_frac: float = tex_aspect / ctrl_aspect
		var left: float = 0.5 - width_frac * 0.5
		uv = Vector2(left + r_uv.x * width_frac, r_uv.y)
	else:
		var height_frac: float = ctrl_aspect / tex_aspect
		var top: float = 0.5 - height_frac * 0.5
		uv = Vector2(r_uv.x, top + r_uv.y * height_frac)

	return uv * size

func _draw() -> void:
	for r in rects:
		draw_rect(r, box_color, false, line_width)
