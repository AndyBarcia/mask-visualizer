extends ZoomPanRect

signal segment_clicked(segment_id: int)

func _ready() -> void:
	super()
	set_selected_id(-1)

func _gui_input(event: InputEvent) -> void:
	# Add picking on left click
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_pick_mask(event.position)
	# Let parent handle zoom/pan
	super._gui_input(event)

func set_selected_id(id: int) -> void:
	var mat := material
	if mat is ShaderMaterial:
		mat.set_shader_parameter("selected_id", float(id))

func _pick_mask(screen_pos: Vector2) -> void:
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
		set_selected_id(-1)
		emit_signal("segment_clicked", -1)
		return

	set_selected_id(id)
	emit_signal("segment_clicked", id)

func update_shader_image(image, panoptic_image) -> void:
	var tex := ImageTexture.create_from_image(image)
	var gt_tex := ImageTexture.create_from_image(panoptic_image)

	var mat := material
	if mat is ShaderMaterial:
		mat.set_shader_parameter("base_image", tex)
		mat.set_shader_parameter("panoptic_ground_truth", gt_tex)

	# Use the panoptic image for UV calculations
	set_reference_image(panoptic_image)

	_update_shader_control_size()
	_update_shader_zoompan()
	set_selected_id(-1)
