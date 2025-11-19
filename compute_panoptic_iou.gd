class_name PanopticIoUCache
extends RefCounted

const SHADER_PATH = "res://compute_panoptic_iou.glsl"
const PAIR_SIZE = 200000 
const AREA_SIZE = 50000

# The final cached data
# _iou_cache[layer_a][layer_b] = { id_a: { target_id: id_b, iou: float } }
var _iou_cache: Dictionary = {}

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _texture_rid: RID

var _tex_width: int
var _tex_height: int

# Number of layers in the *logical* index space (original images array, including nulls)
var _layer_count: int

# Maps logical layer index -> texture layer index (or -1 if null / not uploaded)
var _layer_remap: PackedInt32Array = PackedInt32Array()

func _init():
	_rd = RenderingServer.create_local_rendering_device()
	var shader_file = load(SHADER_PATH)
	var shader_spirv = shader_file.get_spirv()
	_shader = _rd.shader_create_from_spirv(shader_spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)

func bake_all_maps(images: Array[Image]):
	if images.is_empty():
		return

	_layer_count = images.size()

	# Build remap and compact list of valid images
	_layer_remap = PackedInt32Array()
	_layer_remap.resize(_layer_count)

	var gpu_images: Array[Image] = []
	for i in range(_layer_count):
		var img := images[i]
		if img == null:
			_layer_remap[i] = -1
		else:
			_layer_remap[i] = gpu_images.size()
			gpu_images.append(img)

	# If there are no valid images, clear and exit
	if gpu_images.is_empty():
		_iou_cache.clear()
		return

	_upload_images(gpu_images)
	_iou_cache.clear()

	# Prepare per-layer dictionaries in logical index space
	for i in range(_layer_count):
		_iou_cache[i] = {}

	# Loop unique pairs (A vs B) in logical index space
	# Skip any layer that maps to -1 (null entries)
	for i in range(_layer_count):
		if _layer_remap[i] == -1:
			continue

		for j in range(i + 1, _layer_count):
			if _layer_remap[j] == -1:
				continue

			_compute_pair(i, j)

func get_best_match(source_layer: int, target_layer: int, source_id: int) -> Dictionary:
	if not _iou_cache.has(source_layer):
		return {}
	if not _iou_cache[source_layer].has(target_layer):
		return {}
	return _iou_cache[source_layer][target_layer].get(source_id, {})

# -------------------------------------------------------------------------
# INTERNAL
# -------------------------------------------------------------------------
func _compute_pair(layer_a: int, layer_b: int):
	# layer_a / layer_b are logical indices.
	# Convert them to texture layer indices for the shader.
	var tex_layer_a := _layer_remap[layer_a]
	var tex_layer_b := _layer_remap[layer_b]
	if tex_layer_a == -1 or tex_layer_b == -1:
		return # Safety; should already be filtered in bake_all_maps

	# 1. Create Buffers (Zeroed)
	var b_pair = _create_buffer(PAIR_SIZE * 16)
	var b_area_a = _create_buffer(AREA_SIZE * 16)
	var b_area_b = _create_buffer(AREA_SIZE * 16)
	
	# 2. Bind Uniforms
	var sampler = _rd.sampler_create(RDSamplerState.new())
	var u_tex = _create_uniform(0, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [sampler, _texture_rid])
	var u_pair = _create_uniform(1, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, [b_pair])
	var u_aa = _create_uniform(2, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, [b_area_a])
	var u_ab = _create_uniform(3, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, [b_area_b])
	
	var uniform_set = _rd.uniform_set_create([u_tex, u_pair, u_aa, u_ab], _shader, 0)
	
	# 3. Push Constants
	var push = PackedByteArray()
	push.resize(32)
	push.encode_float(0, float(_tex_width))
	push.encode_float(4, float(_tex_height))
	# Use texture layer indices in the shader
	push.encode_u32(8, tex_layer_a)
	push.encode_u32(12, tex_layer_b)
	push.encode_u32(16, PAIR_SIZE)
	# Append area size
	push.encode_u32(20, AREA_SIZE) 

	# 4. Dispatch
	var cl = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	_rd.compute_list_set_push_constant(cl, push, 32)
	_rd.compute_list_dispatch(cl, int(ceil(_tex_width / 16.0)), int(ceil(_tex_height / 16.0)), 1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()

	# 5. Read Data
	var d_pair = _rd.buffer_get_data(b_pair)
	var d_area_a = _rd.buffer_get_data(b_area_a)
	var d_area_b = _rd.buffer_get_data(b_area_b)

	# 6. Parse & Calculate IoU
	# Note: We store results under *logical* indices (layer_a, layer_b)
	_process_results(layer_a, layer_b, d_pair, d_area_a, d_area_b)

	# Cleanup
	_rd.free_rid(b_pair)
	_rd.free_rid(b_area_a)
	_rd.free_rid(b_area_b)
	_rd.free_rid(sampler)

func _process_results(layer_a, layer_b, bytes_pair, bytes_aa, bytes_ab):
	# Parse Areas
	var map_aa = _parse_area_buffer(bytes_aa)
	var map_ab = _parse_area_buffer(bytes_ab)
	
	var matches_a = {} # Key: ID_A, Value: { target_id, iou }
	var matches_b = {} # Key: ID_B, Value: { target_id, iou }
	
	# Parse Intersections and Compute IoU immediately
	for k in range(PAIR_SIZE):
		var off = k * 16
		var id_a = bytes_pair.decode_u32(off)
		if id_a == 0:
			continue # empty slot

		var id_b = bytes_pair.decode_u32(off + 4)
		var intersect = bytes_pair.decode_u32(off + 8)
		var area_a = map_aa.get(id_a, 0)
		var area_b = map_ab.get(id_b, 0)
		
		if area_a > 0 and area_b > 0:
			var union_val = area_a + area_b - intersect
			var iou = float(intersect) / float(union_val)
			
			# Update Best Match for A
			if not matches_a.has(id_a) or iou > matches_a[id_a].iou:
				matches_a[id_a] = { "target_id": id_b, "iou": iou }
			
			# Update Best Match for B
			if not matches_b.has(id_b) or iou > matches_b[id_b].iou:
				matches_b[id_b] = { "target_id": id_a, "iou": iou }

	# Store under logical layer indices
	_iou_cache[layer_a][layer_b] = matches_a
	_iou_cache[layer_b][layer_a] = matches_b

func _parse_area_buffer(bytes: PackedByteArray) -> Dictionary:
	var res = {}
	for k in range(AREA_SIZE):
		var off = k * 16
		var id = bytes.decode_u32(off) # AreaEntry.id
		if id != 0: # 0 = empty slot
			res[id] = bytes.decode_u32(off + 4) # AreaEntry.count
	return res

# Boilerplate helpers
func _create_buffer(size):
	var z = PackedByteArray()
	z.resize(size)
	return _rd.storage_buffer_create(size, z)

func _create_uniform(binding, type, ids):
	var u = RDUniform.new()
	u.binding = binding
	u.uniform_type = type
	for id in ids:
		u.add_id(id)
	return u

func _upload_images(images: Array[Image]):
	if images.is_empty():
		return

	if _texture_rid.is_valid():
		_rd.free_rid(_texture_rid)

	_tex_width = images[0].get_width()
	_tex_height = images[0].get_height()
	var tex_layer_count := images.size()

	var fmt = RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	fmt.width = _tex_width
	fmt.height = _tex_height
	fmt.depth = 1
	fmt.array_layers = tex_layer_count
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT

	_texture_rid = _rd.texture_create(fmt, RDTextureView.new(), [])

	for tex_layer in range(tex_layer_count):
		var img = images[tex_layer]
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		_rd.texture_update(_texture_rid, tex_layer, img.get_data())
