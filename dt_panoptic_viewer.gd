extends GTPanopticViewer

var current_pred_to_gt = {}
var current_pred_to_iou = {}

func set_dt_image(image, panoptic_image, segments, pred_to_gt, pred_to_iou) -> void:
	$Image.update_shader_image(image, panoptic_image)
	current_segments = segments
	current_pred_to_gt = pred_to_gt
	current_pred_to_iou = pred_to_iou

func set_selected_segment(segment_id: int) -> void:
	if segment_id == -1:
		$NameContainer/MarginContainer/Label.text = "No mask selected"
		$Image.set_selected_id(segment_id)
		return
	
	var gt_cat := "Unknown"
	if current_segments.has(segment_id):
		gt_cat = str(current_segments[segment_id])
	
	var iou := 0.0
	if current_pred_to_iou.has(segment_id):
		iou = current_pred_to_iou[segment_id]

	$NameContainer/MarginContainer/Label.text = "%s (matched with IoU %f)" % [gt_cat, iou]
	$Image.set_selected_id(segment_id)
