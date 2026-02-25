extends VBoxContainer
class_name GTPanopticViewer

signal segment_clicked(segment_id: int, append_selection: bool, remove_selection: bool)
signal panzoom_sync(pan: Vector2, zoom: float)
signal on_folder_selected(folder: String)

var current_segments = []
var current_base_image: Image = null
var current_panoptic_image: Image = null
var randomize_dense_instance_colors: bool = false

func set_panoptic_image(image, panoptic_image, segments) -> void:
	current_base_image = image
	current_panoptic_image = panoptic_image
	current_segments = segments
	_apply_panoptic_overlay()

func set_randomize_dense_instance_colors(enabled: bool) -> void:
	randomize_dense_instance_colors = enabled
	_apply_panoptic_overlay()

func _apply_panoptic_overlay() -> void:
	if current_base_image == null or current_panoptic_image == null:
		return

	var overlay_image: Image = current_panoptic_image
	if randomize_dense_instance_colors:
		overlay_image = _build_randomized_overlay(current_panoptic_image, current_segments)

	$Image.update_shader_image(current_base_image, current_panoptic_image, overlay_image)

func _build_randomized_overlay(panoptic_image: Image, segments: Dictionary) -> Image:
	var category_segments: Dictionary = {}
	for seg_key in segments.keys():
		var segment_id := int(seg_key)
		var category_name := str(segments[seg_key])
		if not category_segments.has(category_name):
			category_segments[category_name] = []
		category_segments[category_name].append(segment_id)

	var randomized_colors: Dictionary = {}
	for category_name in category_segments.keys():
		var segment_ids: Array = category_segments[category_name]
		if segment_ids.size() <= 2:
			continue
		_assign_maximally_separated_colors(segment_ids, category_name, randomized_colors)

	if randomized_colors.is_empty():
		return panoptic_image

	var output := panoptic_image.duplicate()
	for y in range(output.get_height()):
		for x in range(output.get_width()):
			var pixel : Color = output.get_pixel(x, y)
			var r: int = int(round(pixel.r * 255.0))
			var g: int = int(round(pixel.g * 255.0))
			var b: int = int(round(pixel.b * 255.0))
			var segment_id: int = r + g * 256 + b * 256 * 256
			if randomized_colors.has(segment_id):
				output.set_pixel(x, y, randomized_colors[segment_id])

	return output

func _assign_maximally_separated_colors(segment_ids: Array, category_name: String, color_map: Dictionary) -> void:
	segment_ids.sort()
	var count := segment_ids.size()
	if count == 0:
		return

	var category_offset := _stable_hash_01(category_name)
	var sat_levels := [0.72, 0.9]
	var val_levels := [0.95, 0.8]
	for idx in range(count):
		var segment_id := int(segment_ids[idx])
		var frac := (float(idx) + 0.5) / float(count)
		var hue := fmod(category_offset + frac, 1.0)
		var sat : float = sat_levels[idx % sat_levels.size()]
		var val : float = val_levels[(idx / int(sat_levels.size())) % int(val_levels.size())]
		color_map[segment_id] = Color.from_hsv(hue, sat, val)

func _stable_hash_01(value: String) -> float:
	var hash_value := 2166136261
	for i in range(value.length()):
		hash_value = int((hash_value ^ value.unicode_at(i)) * 16777619) & 0x7fffffff
	return float(hash_value % 1000003) / 1000003.0

func set_selected_segment(segment_id: int, iou: float) -> void:
	if segment_id == -1:
		set_selected_segments([])
		return
	set_selected_segments([segment_id], {segment_id: iou})

func set_selected_segments(segment_ids: Array[int], iou_by_segment: Dictionary = {}) -> void:
	if segment_ids.is_empty():
		$NameContainer/MarginContainer/Label.text = "No mask selected"
		var empty_selection: Array[int] = []
		$Image.set_selected_ids(empty_selection)
		return

	if segment_ids.size() > 1:
		$NameContainer/MarginContainer/Label.text = "%d masks selected" % segment_ids.size()
		$Image.set_selected_ids(segment_ids)
		return

	var segment_id := segment_ids[0]
	var gt_cat := "Unknown"
	if current_segments.has(segment_id):
		gt_cat = str(current_segments[segment_id]).capitalize()

	var iou := float(iou_by_segment.get(segment_id, 0.0))
	if iou != 0.0:
		$NameContainer/MarginContainer/Label.text = "%s (matched with IoU %.2f%%)" % [gt_cat, iou * 100.0]
	else:
		$NameContainer/MarginContainer/Label.text = gt_cat

	$Image.set_selected_ids(segment_ids)

func _on_segment_clicked(segment_id: int, append_selection: bool, remove_selection: bool) -> void:
	emit_signal("segment_clicked", segment_id, append_selection, remove_selection)

func _on_panzoom_sync(pan: Vector2, zoom: float) -> void:
	emit_signal("panzoom_sync", pan, zoom)

func set_sync_view(sync_view: bool) -> void:
	$Image.sync_view = sync_view
	
func set_panzoom(pan: Vector2, zoom: float) -> void:
	$Image.pan = pan
	$Image.zoom = zoom
	$Image._update_shader_zoompan()

func set_panzoom_like(other) -> void:
	$Image.pan = other.get_child(1).pan
	$Image.zoom = other.get_child(1).zoom
	$Image._update_shader_zoompan()

func set_show_bounding_boxes(is_visible: bool) -> void:
	$Image.set_bounding_boxes_visible(is_visible)

func set_overlay_alpha(alpha: float) -> void:
	$Image.set_overlay_alpha(alpha)

func set_highlight_alpha(alpha: float) -> void:
	$Image.set_highlight_alpha(alpha)

func _on_folder_selected(folder: String):
	emit_signal("on_folder_selected", folder)
	$PanelContainer/MarginContainer/HBoxContainer/Label.text = folder

func _on_export_pressed() -> void:
	$PanelContainer/MarginContainer/HBoxContainer/Export/FileDialog.popup_centered_ratio(0.6)

func _on_export_file_selected(path: String) -> void:
	var target_path := path
	if not target_path.to_lower().ends_with(".png"):
		target_path += ".png"

	var image_control: ZoomPanRect = $Image
	if not is_instance_valid(image_control):
		push_error("Unable to export view: image control is missing")
		return

	var viewport_texture := get_viewport().get_texture()
	if viewport_texture == null:
		push_error("Unable to export view: viewport texture is unavailable")
		return

	var full_frame := viewport_texture.get_image()
	if full_frame == null:
		push_error("Unable to export view: viewport image is unavailable")
		return

	var crop_rect := _get_visible_shader_rect_in_viewport(image_control)
	if crop_rect.size.x <= 0 or crop_rect.size.y <= 0:
		push_error("Unable to export view: image control has an invalid visible size")
		return

	var frame_bounds := Rect2i(Vector2i.ZERO, full_frame.get_size())
	var clipped_rect := crop_rect.intersection(frame_bounds)
	if clipped_rect.size.x <= 0 or clipped_rect.size.y <= 0:
		push_error("Unable to export view: image control is outside of viewport")
		return

	var output := full_frame.get_region(clipped_rect)
	var err := output.save_png(target_path)
	if err != OK:
		push_error("Unable to export PNG: %s" % target_path)

func _get_visible_shader_rect_in_viewport(image_control: ZoomPanRect) -> Rect2i:
	var global_rect := image_control.get_global_rect()
	if image_control.reference_image == null:
		return Rect2i(
			int(round(global_rect.position.x)),
			int(round(global_rect.position.y)),
			int(round(global_rect.size.x)),
			int(round(global_rect.size.y))
		)

	var control_size := global_rect.size
	if control_size.x <= 0.0 or control_size.y <= 0.0:
		return Rect2i()

	var image_size := image_control.reference_image.get_size()
	if image_size.x <= 0 or image_size.y <= 0:
		return Rect2i(
			int(round(global_rect.position.x)),
			int(round(global_rect.position.y)),
			int(round(global_rect.size.x)),
			int(round(global_rect.size.y))
		)

	var tex_aspect: float = float(image_size.x) / float(image_size.y)
	var ctrl_aspect: float = control_size.x / control_size.y

	var visible_pos := global_rect.position
	var visible_size := control_size
	if tex_aspect <= ctrl_aspect:
		var width_frac: float = tex_aspect / ctrl_aspect
		visible_size.x = control_size.x * width_frac
		visible_pos.x += (control_size.x - visible_size.x) * 0.5
	else:
		var height_frac: float = ctrl_aspect / tex_aspect
		visible_size.y = control_size.y * height_frac
		visible_pos.y += (control_size.y - visible_size.y) * 0.5

	return Rect2i(
		int(round(visible_pos.x)),
		int(round(visible_pos.y)),
		int(round(visible_size.x)),
		int(round(visible_size.y))
	)
