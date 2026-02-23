extends Control
class_name BoundingBoxOverlay

const BBOX_COLOR := Color(1.0, 1.0, 0.0, 1.0)

var rects: Array[Rect2] = []
var line_width: float = 2.0

func set_rects(next_rects: Array[Rect2], next_line_width: float = 2.0) -> void:
	rects = next_rects.duplicate()
	line_width = next_line_width
	queue_redraw()

func _draw() -> void:
	for r in rects:
		draw_rect(r, BBOX_COLOR, false, line_width)
