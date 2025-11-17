extends HBoxContainer

@export var gt_view_path: NodePath
@export var label_node: NodePath
@export var dt_view_scene: PackedScene

signal on_dataset_folder_selected(folder: String)
signal on_detections_folder_selected(folder: String, view: int)

var gt_view
var dt_views: Array = []                          # actual dt view nodes

# Per-view matching & categories
var matches_list: Array = []                      # Array[Dictionary] per view
var gt_to_pred_list: Array = []                   # Array[Dictionary gt_id -> pred_id] per view
var pred_to_gt_list: Array = []                   # Array[Dictionary pred_id -> gt_id] per view
var gt_to_iou_list: Array = []                    # Array[Dictionary gt_id -> iou] per view
var pred_to_iou_list: Array = []                  # Array[Dictionary pred_id -> iou] per view

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
func load_image_pair(base_img, gt_img, gt_segments, det_images, det_segments_array, matches_array) -> void:
	# Store categories
	gt_categories = gt_segments
	dt_categories_list = det_segments_array
	matches_list = matches_array

	# Build per-view match maps
	_build_match_maps(matches_array)

	# Update GT view: only GT info here
	gt_view.set_gt_image(
		base_img,
		gt_img,
		gt_categories
	)

	# Update all DT views with their own detection info
	for i in range(dt_views.size()):
		dt_views[i].set_dt_image(
			base_img,
			det_images[i],
			det_segments_array[i],
			pred_to_gt_list[i],
			pred_to_iou_list[i]
		)

func _build_match_maps(matches_array: Array) -> void:
	gt_to_pred_list.resize(matches_array.size())
	pred_to_gt_list.resize(matches_array.size())
	gt_to_iou_list.resize(matches_array.size())
	pred_to_iou_list.resize(matches_array.size())

	for view_idx in range(matches_array.size()):
		var local_matches: Dictionary = matches_array[view_idx] if typeof(matches_array[view_idx]) == TYPE_DICTIONARY else {}

		var gt_to_pred: Dictionary = {}
		var pred_to_gt: Dictionary = {}
		var gt_to_iou: Dictionary = {}
		var pred_to_iou: Dictionary = {}

		if local_matches.has("hungarian_matches"):
			for entry in local_matches["hungarian_matches"]:
				var gt_id = int(entry["gt_id"])
				var pred_id = int(entry["pred_id"])
				var iou = float(entry["iou"])
				if iou > 0.4:
					gt_to_pred[gt_id] = pred_id
					pred_to_gt[pred_id] = gt_id
					gt_to_iou[gt_id] = iou
					pred_to_iou[pred_id] = iou

		gt_to_pred_list[view_idx] = gt_to_pred
		pred_to_gt_list[view_idx] = pred_to_gt
		gt_to_iou_list[view_idx] = gt_to_iou
		pred_to_iou_list[view_idx] = pred_to_iou

func _on_segment_clicked(seg_id: int, kind: String, dt_view_idx: int) -> void:
	if seg_id == -1:
		# Clear selection in all views
		gt_view.set_selected_segment(-1)
		for v in dt_views:
			v.set_selected_segment(-1)
		return

	# 1) Decide GT id (if any)
	var gt_id := -1
	if kind == "gt":
		gt_id = seg_id
	else:
		# Click from a DT view: find which GT segment it matches (if any)
		if dt_view_idx >= 0 and dt_view_idx < pred_to_gt_list.size():
			var local_pred_to_gt: Dictionary = pred_to_gt_list[dt_view_idx]
			if local_pred_to_gt.has(seg_id):
				gt_id = int(local_pred_to_gt[seg_id])

	# 2) Build per-view predictions + IoUs for that GT id (if we have one)
	var per_view_pred_ids: Array = []
	per_view_pred_ids.resize(dt_views.size())

	for i in range(dt_views.size()):
		per_view_pred_ids[i] = -1

		if gt_id != -1 and i < gt_to_pred_list.size():
			var dict_for_view: Dictionary = gt_to_pred_list[i]
			if dict_for_view.has(gt_id):
				var pred_id = int(dict_for_view[gt_id])
				per_view_pred_ids[i] = pred_id

	# 2b) SPECIAL CASE: clicking a DT segment with **no GT match**
	#     -> we still want that detection selected and labeled.
	if kind == "dt" and gt_id == -1:
		# Select only the clicked detection in its own view
		if dt_view_idx >= 0 and dt_view_idx < per_view_pred_ids.size():
			per_view_pred_ids[dt_view_idx] = seg_id

	# 3) Update visuals
	gt_view.set_selected_segment(gt_id)
	for i in range(dt_views.size()):
		dt_views[i].set_selected_segment(per_view_pred_ids[i])

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
