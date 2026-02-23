class_name PanopticBBoxCache
extends RefCounted

const SHADER_PATH := "res://compute_panoptic_bboxes.glsl"
const BBOX_MAP_SIZE := 200000
const ENTRY_SIZE := 32
const U32_MAX := 0xFFFFFFFF

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID

func _init() -> void:
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		push_error("Unable to create local RenderingDevice for bounding-box compute shader")
		return

	var shader_file = load(SHADER_PATH)
	var shader_spirv = shader_file.get_spirv()
	_shader = _rd.shader_create_from_spirv(shader_spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)

func compute_bounds_uv(image: Image) -> Dictionary:
	if image == null:
		return {}
	if _rd == null:
		return _compute_bounds_uv_cpu(image)

	var width := image.get_width()
	var height := image.get_height()
	if width <= 0 or height <= 0:
		return {}

	var img := image.duplicate()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)

	var texture_rid := _create_texture(img)
	var bbox_buffer := _create_bbox_buffer()
	var sampler := _rd.sampler_create(RDSamplerState.new())

	var u_tex = _create_uniform(0, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [sampler, texture_rid])
	var u_bbox = _create_uniform(1, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, [bbox_buffer])
	var uniform_set = _rd.uniform_set_create([u_tex, u_bbox], _shader, 0)

	var push := PackedByteArray()
	push.resize(16)
	push.encode_float(0, float(width))
	push.encode_float(4, float(height))
	push.encode_u32(8, BBOX_MAP_SIZE)

	var cl = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	_rd.compute_list_set_push_constant(cl, push, 16)
	_rd.compute_list_dispatch(cl, int(ceil(width / 16.0)), int(ceil(height / 16.0)), 1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()

	var bytes := _rd.buffer_get_data(bbox_buffer)
	var bounds := _parse_bounds_uv(bytes, width, height)

	_rd.free_rid(sampler)
	_rd.free_rid(uniform_set)
	_rd.free_rid(bbox_buffer)
	_rd.free_rid(texture_rid)

	return bounds

func _parse_bounds_uv(bytes: PackedByteArray, width: int, height: int) -> Dictionary:
	var result: Dictionary = {}

	for i in range(BBOX_MAP_SIZE):
		var off := i * ENTRY_SIZE
		var id := int(bytes.decode_u32(off))
		if id == 0:
			continue

		var min_x := int(bytes.decode_u32(off + 4))
		var min_y := int(bytes.decode_u32(off + 8))
		var max_x := int(bytes.decode_u32(off + 12))
		var max_y := int(bytes.decode_u32(off + 16))

		if min_x == U32_MAX or min_y == U32_MAX:
			continue

		var min_uv := Vector2(float(min_x) / float(width), float(min_y) / float(height))
		var max_uv := Vector2(float(max_x + 1) / float(width), float(max_y + 1) / float(height))
		result[id] = Rect2(min_uv, max_uv - min_uv)

	return result

func _create_texture(image: Image) -> RID:
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	fmt.width = image.get_width()
	fmt.height = image.get_height()
	fmt.depth = 1
	fmt.array_layers = 1
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT

	return _rd.texture_create(fmt, RDTextureView.new(), [image.get_data()])

func _create_bbox_buffer() -> RID:
	var data := PackedByteArray()
	data.resize(BBOX_MAP_SIZE * ENTRY_SIZE)

	for i in range(BBOX_MAP_SIZE):
		var off := i * ENTRY_SIZE
		data.encode_u32(off, 0)
		data.encode_u32(off + 4, U32_MAX)
		data.encode_u32(off + 8, U32_MAX)
		data.encode_u32(off + 12, 0)
		data.encode_u32(off + 16, 0)

	return _rd.storage_buffer_create(data.size(), data)

func _create_uniform(binding: int, type: int, ids: Array) -> RDUniform:
	var u := RDUniform.new()
	u.binding = binding
	u.uniform_type = type
	for id in ids:
		u.add_id(id)
	return u

func _compute_bounds_uv_cpu(image: Image) -> Dictionary:
	var bounds_px: Dictionary = {}
	var width := image.get_width()
	var height := image.get_height()

	for y in range(height):
		for x in range(width):
			var col: Color = image.get_pixel(x, y)
			var r: int = int(round(col.r * 255.0))
			var g: int = int(round(col.g * 255.0))
			var b: int = int(round(col.b * 255.0))
			var id: int = r + g * 256 + b * 256 * 256
			if id == 0:
				continue

			if not bounds_px.has(id):
				bounds_px[id] = Rect2i(x, y, 1, 1)
				continue

			var rect: Rect2i = bounds_px[id]
			var left : int = min(rect.position.x, x)
			var top : int = min(rect.position.y, y)
			var right : int = max(rect.end.x - 1, x)
			var bottom : int = max(rect.end.y - 1, y)
			bounds_px[id] = Rect2i(left, top, right - left + 1, bottom - top + 1)

	var bounds_uv: Dictionary = {}
	for id in bounds_px.keys():
		var rect_px: Rect2i = bounds_px[id]
		var min_uv := Vector2(float(rect_px.position.x) / float(width), float(rect_px.position.y) / float(height))
		var max_uv := Vector2(float(rect_px.end.x) / float(width), float(rect_px.end.y) / float(height))
		bounds_uv[id] = Rect2(min_uv, max_uv - min_uv)

	return bounds_uv
