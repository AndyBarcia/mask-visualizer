extends ColorRect
class_name ZoomPanRect

signal panzoom_sync(pan: Vector2, zoom: float)

@export var zoom_min: float = 0.2
@export var zoom_max: float = 20.0

var sync_view: bool = true

var zoom: float = 1.0
var pan: Vector2 = Vector2(0.5, 0.5)
var dragging: bool = false
var last_mouse_pos: Vector2 = Vector2.ZERO

# Image used to compute aspect ratio / UV mapping
var reference_image: Image

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_update_shader_control_size()
	_update_shader_zoompan()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_shader_control_size()

func set_reference_image(img: Image) -> void:
	reference_image = img
	_update_shader_control_size()
	_update_shader_zoompan()

func _update_shader_control_size() -> void:
	var mat := material
	if mat is ShaderMaterial:
		mat.set_shader_parameter("control_size", size)
	queue_redraw()

func _update_shader_zoompan() -> void:
	var mat := material
	if mat is ShaderMaterial:
		mat.set_shader_parameter("zoom", zoom)
		mat.set_shader_parameter("pan", pan)
	queue_redraw()

func _gui_input(event: InputEvent) -> void:
	var changed = false
	
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			if event.pressed:
				dragging = true
				last_mouse_pos = event.position
			else:
				dragging = false
			
			if event.double_click:
				emit_signal("panzoom_sync", pan, zoom)

		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_set_zoom(zoom * 1.1, event.position)
			changed = true

		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_set_zoom(zoom / 1.1, event.position)
			changed = true

	elif event is InputEventMouseMotion and dragging:
		var prev_pos: Vector2 = last_mouse_pos
		var cur_pos: Vector2 = event.position
		last_mouse_pos = cur_pos

		var prev_uv: Vector2 = _screen_to_tex_with_letterbox(prev_pos)
		var cur_uv: Vector2 = _screen_to_tex_with_letterbox(cur_pos)
		var delta_uv: Vector2 = cur_uv - prev_uv
		pan -= delta_uv
		_update_shader_zoompan()
		changed = true
	
	if changed and sync_view:
		emit_signal("panzoom_sync", pan, zoom)

func _set_zoom(new_zoom: float, focus_pos: Vector2) -> void:
	new_zoom = clamp(new_zoom, zoom_min, zoom_max)

	var before: Vector2 = _screen_to_tex_with_letterbox(focus_pos)
	zoom = new_zoom
	var after: Vector2 = _screen_to_tex_with_letterbox(focus_pos)

	if before.x >= 0.0 and after.x >= 0.0:
		pan += before - after

	_update_shader_zoompan()

func _screen_to_tex_with_letterbox(p: Vector2) -> Vector2:
	# Same logic you had, but using reference_image
	if reference_image == null:
		return Vector2(-1.0, -1.0)

	var uv: Vector2 = p / size
	var tex_aspect: float = float(reference_image.get_size().x) / float(reference_image.get_size().y)
	var ctrl_aspect: float = size.x / size.y

	var r_uv: Vector2
	if tex_aspect <= ctrl_aspect:
		var width_frac: float = tex_aspect / ctrl_aspect
		var left: float = 0.5 - width_frac * 0.5
		var u_img: float = (uv.x - left) / width_frac
		var v_img: float = uv.y
		r_uv = Vector2(u_img, v_img)
	else:
		var height_frac: float = ctrl_aspect / tex_aspect
		var top: float = 0.5 - height_frac * 0.5
		var u_img: float = uv.x
		var v_img: float = (uv.y - top) / height_frac
		r_uv = Vector2(u_img, v_img)

	var tex_uv: Vector2 = (r_uv - Vector2(0.5, 0.5)) / zoom + pan
	return tex_uv
