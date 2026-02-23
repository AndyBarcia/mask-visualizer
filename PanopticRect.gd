extends ZoomPanRect

signal segment_clicked(segment_id: int, append_selection: bool, remove_selection: bool)

const BBOX_COLOR := Color(1.0, 1.0, 0.0, 1.0)
const BBOX_LINE_WIDTH := 2.0

var selected_ids: Array[int] = []
var segment_bounds_uv: Dictionary = {}

func _ready() -> void:
	super()
	set_selected_ids([])

func _gui_input(event: InputEvent) -> void:
	# Add picking on left click
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_pick_mask(event.position, event.shift_pressed, event.ctrl_pressed)
	# Let parent handle zoom/pan
	super._gui_input(event)

func set_selected_id(id: int) -> void:
	if id < 0:
		set_selected_ids([])
		return
	set_selected_ids([id])

func set_selected_ids(ids: Array[int]) -> void:
	selected_ids = ids.duplicate()
	queue_redraw()

	var shader_ids := PackedFloat32Array()
	for id in ids:
		shader_ids.append(float(id))

	var mat := material
	if mat is ShaderMaterial:
		mat.set_shader_parameter("selected_count", ids.size())
		mat.set_shader_parameter("selected_ids", shader_ids)

func _draw() -> void:
	if selected_ids.is_empty() or reference_image == null:
		return

	for id in selected_ids:
		if not segment_bounds_uv.has(id):
			continue

		var uv_rect: Rect2 = segment_bounds_uv[id]
		var min_screen := _tex_to_screen_with_letterbox(uv_rect.position)
		var max_screen := _tex_to_screen_with_letterbox(uv_rect.end)

		var screen_rect := Rect2(min_screen, max_screen - min_screen).abs()
		draw_rect(screen_rect, BBOX_COLOR, false, BBOX_LINE_WIDTH)

func _pick_mask(screen_pos: Vector2, append_selection: bool, remove_selection: bool) -> void:
	if reference_image == null:
		return

	var tex_uv: Vector2 = _screen_to_tex_with_letterbox(screen_pos)
	if tex_uv.x < 0.0 or tex_uv.y < 0.0 or tex_uv.x > 1.0 or tex_uv.y > 1.0:
		return

	var w := reference_image.get_width()
	var h := reference_image.get_height()

	var x: int = clamp(int(tex_uv.x * float(w)), 0, w - 1)
	var y: int = clamp(int(tex_uv.y * float(h)), 0, h - 1)

	var col: Color = reference_image.get_pixel(x, y)

	var r: int = int(round(col.r * 255.0))
	var g: int = int(round(col.g * 255.0))
	var b: int = int(round(col.b * 255.0))
	var id: int = r + g * 256 + b * 256 * 256
	
	if id == 0:
		emit_signal("segment_clicked", -1, append_selection, remove_selection)
		return

	emit_signal("segment_clicked", id, append_selection, remove_selection)

func update_shader_image(image, panoptic_image) -> void:
	var tex := ImageTexture.create_from_image(image)
	var gt_tex := ImageTexture.create_from_image(panoptic_image)

	var mat := material
	if mat is ShaderMaterial:
		mat.set_shader_parameter("base_image", tex)
		mat.set_shader_parameter("panoptic_ground_truth", gt_tex)

	# Use the panoptic image for UV calculations
	set_reference_image(panoptic_image)
	segment_bounds_uv = _compute_segment_bounds_uv(panoptic_image)

	_update_shader_control_size()
	_update_shader_zoompan()
	set_selected_ids([])

func _compute_segment_bounds_uv(panoptic_image: Image) -> Dictionary:
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
