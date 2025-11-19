extends VBoxContainer
class_name GTPanopticViewer

signal segment_clicked(segment_id: int)
signal panzoom_sync(pan: Vector2, zoom: float)
signal on_folder_selected(folder: String)

var current_segments = []

func set_panoptic_image(image, panoptic_image, segments) -> void:
	$Image.update_shader_image(image, panoptic_image)
	current_segments = segments

func set_selected_segment(segment_id: int, iou: float) -> void:
	if segment_id == -1:
		$NameContainer/MarginContainer/Label.text = "No mask selected"
		$Image.set_selected_id(segment_id)
		return
	
	var gt_cat := "Unknown"
	if current_segments.has(segment_id):
		gt_cat = str(current_segments[segment_id]).capitalize()
	
	if iou != 0.0:
		$NameContainer/MarginContainer/Label.text = "%s (matched with IoU %.2f%%)" % [gt_cat, iou*100]
	else:
		$NameContainer/MarginContainer/Label.text = gt_cat
	$Image.set_selected_id(segment_id)
	
func _on_segment_clicked(segment_id: int) -> void:
	emit_signal("segment_clicked", segment_id)
	set_selected_segment(segment_id, 0.0)

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
