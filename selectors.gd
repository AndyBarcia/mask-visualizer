extends HBoxContainer

signal image_selected(image_id, image, gt_image, segments, det_images, det_segments, det_matching)

@onready var image_input_node: Node = $ImageInput

# Dataset information (shared for all slots)
var dataset_dir: String

var detections_dirs: Array[String] = []          # one path per slot

# Per-slot caches (index == slot index)
var per_view_category_maps: Array = []    # Array[Dictionary image_id -> {seg_id: cat_name}]

# Image id lists
var gt_image_ids: Array[String] = []      # image_ids from GT JSON
var image_ids: Array[String] = []         # actually visible image_ids (maybe filtered by detections)

# Category + panoptic info for ground truth
var category_names: Dictionary = {}             # category_id -> name
var segment_category_maps: Dictionary = {}      # image_basename -> {segment_id: category_name}

# For picking ground-truth masks
var current_image_id: String

func _on_spinbox_value_changed(value: float) -> void:
	var count := int(value)

	# Resize per-slot arrays
	detections_dirs.resize(count)
	per_view_category_maps.resize(count)

	# Ensure each slot has Dictionaries
	for i in range(count):
		if typeof(per_view_category_maps[i]) != TYPE_DICTIONARY:
			per_view_category_maps[i] = {}
	_update_visible_image_ids()

func _dataset_folder_selected(dir: String) -> void:
	print("Dataset folder:", dir)
	dataset_dir = dir

	# Path to the JSON file
	var json_path := dir.path_join("ade20k_panoptic_val.json")

	if not FileAccess.file_exists(json_path):
		push_error("JSON file not found: %s" % json_path)
		return

	# Read & parse JSON
	var json_text := FileAccess.get_file_as_string(json_path)
	var data = JSON.parse_string(json_text)
	if data == null:
		push_error("Failed to parse JSON file: %s" % json_path)
		return

	# categories from "categories"
	if data.has("categories") and typeof(data["categories"]) == TYPE_ARRAY:
		category_names.clear()
		for c in data["categories"]:
			if typeof(c) == TYPE_DICTIONARY and c.has("id") and c.has("name"):
				var cat_id: int = int(c["id"])
				var cat_name: String = str(c["name"])
				category_names[cat_id] = cat_name
	else:
		push_warning('"categories" key not found in JSON or not an Array.')

	# Build per-image mapping: segment_id -> category name
	if data.has("annotations") and typeof(data["annotations"]) == TYPE_ARRAY:
		segment_category_maps.clear()

		for ann in data["annotations"]:
			if typeof(ann) != TYPE_DICTIONARY:
				continue
			if not ann.has("file_name") or not ann.has("segments_info"):
				continue

			var img_key: String = ann["file_name"].get_basename()
			var seg_map: Dictionary = {}

			var segs = ann["segments_info"]
			if typeof(segs) != TYPE_ARRAY:
				continue

			for seg in segs:
				if typeof(seg) != TYPE_DICTIONARY:
					continue
				if not seg.has("id") or not seg.has("category_id"):
					continue
				
				var seg_id: int = int(seg["id"])
				var cat_id: int = int(seg["category_id"])

				var cat_name := "Unknown"
				if category_names.has(cat_id):
					cat_name = category_names[cat_id]

				seg_map[seg_id] = cat_name

			segment_category_maps[img_key] = seg_map
	else:
		push_warning('"annotations" key not found in JSON or not an Array. Category lookup from masks will not work.')

	# Expecting a dictionary with key "images"
	if typeof(data) != TYPE_DICTIONARY or not data.has("images"):
		push_error('"images" key not found in JSON or root is not a Dictionary.')
		return

	var images = data["images"]
	if typeof(images) != TYPE_ARRAY:
		push_error('"images" is not an Array.')
		return

	# Clear and fill GT filenames array
	gt_image_ids.clear()
	for img_entry in images:
		if typeof(img_entry) == TYPE_DICTIONARY and img_entry.has("file_name"):
			var id = img_entry["file_name"].get_basename()
			gt_image_ids.append(id)
	if gt_image_ids.is_empty():
		push_warning("No image filenames found in JSON.")
		return

	# Recompute the visible image list (intersection with detections of current slot, if present)
	_update_visible_image_ids()

func _detections_folder_selected(dir: String, view: int) -> void:
	print("Detections folder for view %d: %s" % [view, dir])

	var json_path := dir.path_join("detections.json")
	if not FileAccess.file_exists(json_path):
		push_error("Detections JSON file not found: %s" % json_path)
		return

	var json_text := FileAccess.get_file_as_string(json_path)
	var parsed = JSON.parse_string(json_text)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY or not parsed.has("predictions"):
		push_error("Detections JSON must be a dictionary with a 'predictions' Array.")
		return

	var data = parsed["predictions"]
	if data == null or typeof(data) != TYPE_ARRAY:
		push_error("Detections JSON 'predictions' must be an Array of per-image entries.")
		return

	var local_det_maps: Dictionary = {}

	for entry in data:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		if not entry.has("image_name"):
			continue

		var img_key: String = entry["image_name"].get_basename()
		var seg_map: Dictionary = {}

		var segs = entry.get("segments_info", null)
		if typeof(segs) != TYPE_ARRAY:
			continue

		for seg in segs:
			if typeof(seg) != TYPE_DICTIONARY:
				continue
			if not seg.has("id") or not seg.has("category_id"):
				continue
			var seg_id: int = int(seg["id"])
			var cat_id: int = int(seg["category_id"])

			var cat_name := "Unknown"
			if category_names.has(cat_id):
				cat_name = category_names[cat_id]
			seg_map[seg_id] = cat_name

		local_det_maps[img_key] = seg_map

	if local_det_maps.is_empty():
		push_warning("No detection entries with image_name found in detections.json for view %d." % view)

	# Cache into per-slot arrays
	per_view_category_maps[view] = local_det_maps
	detections_dirs[view] = dir

	_update_visible_image_ids()

func _update_visible_image_ids() -> void:
	image_ids.clear()

	if gt_image_ids.is_empty():
		# Can't do much without GT information
		return
	
	var is_empty := true
	for map in per_view_category_maps:
		if not map.is_empty():
			is_empty = false
			break 
	
	if is_empty:
		image_ids = gt_image_ids.duplicate()
	else:
		for id in gt_image_ids:
			var was_match := false
			for map in per_view_category_maps:
				if map.has(id):
					was_match = true
					break
			
			if was_match:
				image_ids.append(id)

	if image_ids.is_empty():
		return

	# Check if the current image id is present in the list of visible images.
	if current_image_id not in image_ids:
		current_image_id = image_ids[0]
		image_input_node.text = current_image_id
	_load_image(current_image_id)

func _next_image() -> void:
	if image_ids.is_empty():
		return
	var current_id := image_ids.find(current_image_id)
	_load_image(image_ids[(current_id + 1) % len(image_ids)])

func _previous_image() -> void:
	if image_ids.is_empty():
		return
	var current_id := image_ids.find(current_image_id)
	_load_image(image_ids[current_id - 1])

func _load_image(image_id: String) -> void:
	# Ground truth paths
	var image_path := dataset_dir.path_join("images".path_join("validation".path_join(image_id + ".jpg")))
	var ground_truth_path := dataset_dir.path_join("ade20k_panoptic_val".path_join(image_id + ".png"))

	if not FileAccess.file_exists(image_path):
		print("Image not found on disk: %s" % image_path)
		image_input_node.text = current_image_id
		return
	if not FileAccess.file_exists(ground_truth_path):
		print("GT image not found on disk: %s" % ground_truth_path)
		image_input_node.text = current_image_id
		return
	if not segment_category_maps.has(image_id):
		print("Image doesn't have GT segments:", image_id)
		image_input_node.text = current_image_id
		return

	# Load base image
	var image := Image.load_from_file(image_path)

	# Load GT image (keep Image around for picking)
	var gt_image := Image.load_from_file(ground_truth_path)

	# GT segment->category mapping
	var current_segment_categories = segment_category_maps[image_id]

	# Gather detection info for ALL slots
	var det_images: Array[Image] = []
	var det_segments_array: Array = []

	for slot in range(detections_dirs.size()):
		var slot_dir := detections_dirs[slot] if slot < detections_dirs.size() else ""
		var slot_det_maps: Dictionary = {}

		if slot < per_view_category_maps.size():
			slot_det_maps = per_view_category_maps[slot]

		# Per-slot categories and matches for this image
		var slot_det_categories = slot_det_maps.get(image_id, {})

		# Per-slot detection image
		var det_image: Image = null
		if slot_dir != "":
			var det_image_path := slot_dir.path_join("images").path_join(image_id).path_join("panoptic_output.png")
			if not FileAccess.file_exists(det_image_path):
				print("Detection panoptic image not found on disk for slot %d: %s" % [slot, det_image_path])
			else:
				det_image = Image.load_from_file(det_image_path)

		det_images.append(det_image)
		det_segments_array.append(slot_det_categories)

	# Emit everything: GT + detections (all slots)
	image_selected.emit(
		image,                  # RGB image
		gt_image,               # GT panoptic
		current_segment_categories,   # GT segment_id -> category_name
		det_images,             # Array[Image] per slot (can have null entries)
		det_segments_array,     # Array[Dictionary] per slot
	)

	current_image_id = image_id
	image_input_node.text = current_image_id
