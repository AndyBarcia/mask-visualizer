extends VBoxContainer
class_name GTPanopticViewer

signal segment_clicked(segment_id: int, append_selection: bool)
signal panzoom_sync(pan: Vector2, zoom: float)
signal on_folder_selected(folder: String)

var current_segments = []

func set_panoptic_image(image, panoptic_image, segments) -> void:
	$Image.update_shader_image(image, panoptic_image)
	current_segments = segments

func set_selected_segment(segment_id: int, iou: float) -> void:
	if segment_id == -1:
		set_selected_segments([])
		return
	set_selected_segments([segment_id], {segment_id: iou})

func set_selected_segments(segment_ids: Array[int], iou_by_segment: Dictionary = {}) -> void:
	if segment_ids.is_empty():
		$NameContainer/MarginContainer/Label.text = "No mask selected"
		$Image.set_selected_ids([])
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

func _on_segment_clicked(segment_id: int, append_selection: bool) -> void:
	emit_signal("segment_clicked", segment_id, append_selection)

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

func _on_folder_selected(folder: String):
	emit_signal("on_folder_selected", folder)
	$PanelContainer/MarginContainer/HBoxContainer/Label.text = folder
