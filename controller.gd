extends HBoxContainer

@export var gt_view_path: NodePath
@export var label_node: NodePath
@export var dt_view_scene: PackedScene

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

# Called from the image_selected signal:
# signal image_selected(image_id, base_img, gt_img, gt_segments, det_images, det_segments_array, det_matches_array)
func load_image_pair(image_id, base_img, gt_img, gt_segments, det_images, det_segments_array, matches_array) -> void:
	# Store categories
	gt_categories = gt_segments
	dt_categories_list = det_segments_array
	matches_list = matches_array

	# Build per-view match maps
	_build_match_maps(matches_array)

	# Update GT view: only GT info here
	gt_view.update_shader_image(
		image_id,
		base_img,
		gt_img,
		gt_segments,
		null,       # det_img
		{},         # det_segments
		{}          # matches
	)

	# Update all DT views with their own detection info
	for i in range(dt_views.size()):
		var det_img = null
		var det_segments: Dictionary = {}
		var matches: Dictionary = {}

		if i < det_images.size():
			det_img = det_images[i]
		if i < det_segments_array.size():
			det_segments = det_segments_array[i]
		if i < matches_array.size():
			matches = matches_array[i]

		dt_views[i].update_shader_image(
			image_id,
			base_img,
			gt_img,
			gt_segments,
			det_img,
			det_segments,
			matches
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
		gt_view.set_selected_id(-1)
		for v in dt_views:
			v.set_selected_id(-1)
		get_node(label_node).text = ""
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
	var per_view_ious: Array = []
	per_view_pred_ids.resize(dt_views.size())
	per_view_ious.resize(dt_views.size())

	for i in range(dt_views.size()):
		per_view_pred_ids[i] = -1
		per_view_ious[i] = 0.0

		if gt_id != -1 and i < gt_to_pred_list.size():
			var dict_for_view: Dictionary = gt_to_pred_list[i]
			if dict_for_view.has(gt_id):
				var pred_id = int(dict_for_view[gt_id])
				per_view_pred_ids[i] = pred_id

				var iou_dict_for_view: Dictionary = gt_to_iou_list[i]
				per_view_ious[i] = float(iou_dict_for_view.get(gt_id, 0.0))

	# 2b) SPECIAL CASE: clicking a DT segment with **no GT match**
	#     -> we still want that detection selected and labeled.
	if kind == "dt" and gt_id == -1:
		# Select only the clicked detection in its own view
		if dt_view_idx >= 0 and dt_view_idx < per_view_pred_ids.size():
			per_view_pred_ids[dt_view_idx] = seg_id

			# If we happen to have an IoU stored, we can show it; else it stays 0.0
			if dt_view_idx < pred_to_iou_list.size():
				var iou_dict: Dictionary = pred_to_iou_list[dt_view_idx]
				if iou_dict.has(seg_id):
					per_view_ious[dt_view_idx] = float(iou_dict[seg_id])

	# 3) Update visuals
	gt_view.set_selected_id(gt_id)
	for i in range(dt_views.size()):
		dt_views[i].set_selected_id(per_view_pred_ids[i])

	# 4) Update label once, with precomputed info
	_update_label(gt_id, per_view_pred_ids, per_view_ious)

func _update_label(gt_id: int, per_view_pred_ids: Array, per_view_ious: Array) -> void:
	var lines: Array[String] = []

	# GT line
	if gt_id != -1:
		var gt_cat := "unknown"
		if gt_categories.has(gt_id):
			gt_cat = str(gt_categories[gt_id])
		lines.append("GT: %s (id: %d)" % [gt_cat, gt_id])
	else:
		lines.append("GT: none selected")

	# Per-view DT lines
	for i in range(dt_views.size()):
		var pred_id_i := -1
		var iou_i := 0.0

		if i < per_view_pred_ids.size():
			pred_id_i = int(per_view_pred_ids[i])
		if i < per_view_ious.size():
			iou_i = float(per_view_ious[i])

		var dt_cat := "unknown"
		if pred_id_i != -1 and i < dt_categories_list.size():
			var dt_cats: Dictionary = dt_categories_list[i]
			if dt_cats.has(pred_id_i):
				dt_cat = str(dt_cats[pred_id_i])

		var line := "View %d: " % (i + 1)
		if pred_id_i == -1:
			line += "—"
		else:
			line += "%s (id: %d, IoU: %.3f)" % [dt_cat, pred_id_i, iou_i]

		lines.append(line)

	get_node(label_node).text = " | ".join(lines)

func set_view_sync(sync_view: bool) -> void:
	gt_view.sync_view = sync_view
	for v in dt_views:
		v.sync_view = sync_view
	# Start everyone from the GT view's current pan/zoom
	_on_panzoom_sync(gt_view.pan, gt_view.zoom)

func _on_panzoom_sync(pan: Vector2, zoom: float) -> void:
	# A DT view changed -> sync GT and all DT views to it
	gt_view.pan = pan
	gt_view.zoom = zoom
	gt_view._update_shader_zoompan()

	for v in dt_views:
		v.pan = pan
		v.zoom = zoom
		v._update_shader_zoompan()
