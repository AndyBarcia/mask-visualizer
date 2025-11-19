extends HBoxContainer

@export var gt_view_path: NodePath
@export var label_node: NodePath
@export var dt_view_scene: PackedScene

signal on_dataset_folder_selected(folder: String)
signal on_detections_folder_selected(folder: String, view: int)

var gt_view
var dt_views: Array = []                          # actual dt view nodes

# Per-view matching & categories
var iou_cache = PanopticIoUCache.new()
var gt_categories: Dictionary = {}                # GT segment_id -> category_name
var dt_categories_list: Array = []                # Array[Dictionary] per view (pred segment_id -> category_name)

func _ready() -> void:
	gt_view = get_node(gt_view_path)

func set_num_views(num_views: int) -> void:
	num_views = max(num_views, 0)
	var current := dt_views.size()

	# If nothing changes, don't touch existing views
	if num_views == current:
		return

	# Shrink: remove extra views from the end
	if num_views < current:
		for i in range(current - 1, num_views - 1, -1):
			var v = dt_views[i]
			if is_instance_valid(v):
				remove_child(v)
				v.queue_free()
			dt_views.remove_at(i)
		return 

	# Grow: add new views after the existing ones
	for i in range(current, num_views):
		var dt_instance = dt_view_scene.instantiate()
		add_child(dt_instance)
		dt_views.append(dt_instance)

		# Auto-connect signals for the new instance only.
		dt_instance.segment_clicked.connect(_on_segment_clicked.bind("dt", i))
		dt_instance.panzoom_sync.connect(_on_panzoom_sync)
		dt_instance.on_folder_selected.connect(_on_detections_folder_selected.bind(i))

# Called from the image_selected signal:
func load_image_pair(base_img, gt_img: Image, gt_segments, det_images: Array[Image], det_segments_array) -> void:
	# Store categories
	gt_categories = gt_segments
	dt_categories_list = det_segments_array

	var all_images := det_images.duplicate()
	all_images.insert(0, gt_img)
	iou_cache.bake_all_maps(all_images)

	# Update GT view: only GT info here
	gt_view.set_panoptic_image(
		base_img,
		gt_img,
		gt_categories
	)

	# Update all DT views with their own detection info
	for i in range(dt_views.size()):
		dt_views[i].set_panoptic_image(
			base_img,
			det_images[i],
			det_segments_array[i],
		)

func _on_segment_clicked(seg_id: int, kind: String, dt_view_idx: int) -> void:
	# If background was selected, just clear the selection of all viewers.
	if seg_id == -1:
		gt_view.set_selected_segment(-1, 0.0)
		for v in dt_views:
			v.set_selected_segment(-1, 0.0)
		return

	if kind == "gt":
		gt_view.set_selected_segment(seg_id, 0.0)
		for i in range(dt_views.size()):
			var det_match = iou_cache.get_best_match(0, i+1, seg_id)
			if not det_match.is_empty() and det_match["iou"] > 0.3:
				dt_views[i].set_selected_segment(det_match["target_id"], det_match["iou"])
			else:
				dt_views[i].set_selected_segment(-1, 0.0)
	else:
		dt_views[dt_view_idx].set_selected_segment(seg_id, 0.0)
		var gt_match = iou_cache.get_best_match(dt_view_idx+1, 0, seg_id)
		if not gt_match.is_empty() and gt_match["iou"] > 0.3:
			gt_view.set_selected_segment(gt_match["target_id"], gt_match["iou"])
		else:
			gt_view.set_selected_segment(-1, 0.0)
		for i in range(dt_views.size()):
			if i == dt_view_idx:
				continue
			var det_match = iou_cache.get_best_match(dt_view_idx+1, i+1, seg_id)
			if not det_match.is_empty() and det_match["iou"] > 0.3:
				dt_views[i].set_selected_segment(det_match["target_id"], det_match["iou"])
			else:
				dt_views[i].set_selected_segment(-1, 0.0)

func set_view_sync(sync_view: bool) -> void:
	# Start everyone from the GT view's current pan/zoom
	gt_view.set_sync_view(sync_view)
	for v in dt_views:
		v.set_sync_view(sync_view)
		v.set_panzoom_like(gt_view)

func _on_panzoom_sync(pan: Vector2, zoom: float) -> void:
	# A DT view changed -> sync GT and all DT views to it
	gt_view.set_panzoom(pan, zoom)
	for v in dt_views:
		v.set_panzoom(pan, zoom)

func _on_dataset_folder_selected(folder: String) -> void:
	emit_signal("on_dataset_folder_selected", folder)

func _on_detections_folder_selected(folder: String, view: int) -> void:
	emit_signal("on_detections_folder_selected", folder, view)
