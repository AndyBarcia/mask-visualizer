extends ZoomPanRect

signal segment_clicked(segment_id: int, append_selection: bool, remove_selection: bool)

var selected_ids: Array[int] = []
var segment_bounds_uv: Dictionary = {}
var bbox_overlay: BoundingBoxOverlay

func _ready() -> void:
	super()
	bbox_overlay = BoundingBoxOverlay.new()
	bbox_overlay.name = "BoundingBoxOverlay"
	bbox_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bbox_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bbox_overlay)
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
	if bbox_overlay != null:
		bbox_overlay.set_selected_ids(selected_ids)

	var shader_ids := PackedFloat32Array()
	for id in ids:
		shader_ids.append(float(id))

	var mat := material
	if mat is ShaderMaterial:
		mat.set_shader_parameter("selected_count", ids.size())
		mat.set_shader_parameter("selected_ids", shader_ids)

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
	segment_bounds_uv = bbox_overlay.compute_segment_bounds_uv(panoptic_image)
	bbox_overlay.set_segment_bounds_uv(segment_bounds_uv)

	_update_shader_control_size()
	_update_shader_zoompan()
	set_selected_ids([])

func _update_shader_control_size() -> void:
	super._update_shader_control_size()
	_update_overlay_view()

func _update_shader_zoompan() -> void:
	super._update_shader_zoompan()
	_update_overlay_view()

func _update_overlay_view() -> void:
	if bbox_overlay == null:
		return
	bbox_overlay.set_view(reference_image, pan, zoom)
