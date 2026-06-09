# Copyright (c) 2023-2025 Cory Petkovsek and Contributors
# CompositorEffect 體積雲合成器
# 負責把八面體預計算貼圖合成到螢幕上
# 架構參考 Bonkahe/SunshineClouds2 (MIT)

@tool
class_name VolumetricCloudEffect
extends CompositorEffect

const COMPOSITE_SHADER_PATH := "res://addons/sky_3d/shaders/VolumetricCloudsComposite.glsl"
const SCENE_DATA_INC_PATH := "res://addons/sky_3d/shaders/CloudsSceneData.comp"

var rd: RenderingDevice
var composite_shader: RID = RID()
var composite_pipeline: RID = RID()

# 取樣器
var linear_sampler: RID = RID()
var nearest_sampler: RID = RID()

# 從 VolumetricCloudRenderer 接收的貼圖
var blend_from_texture: Texture2DRD
var blend_to_texture: Texture2DRD
var blend_amount: float = 0.0

# 色調映射參數
var color_correction: Vector2 = Vector2(0.0, 1.0)

# 太陽/月亮方向（供大氣散射用）
var sun_direction: Vector3 = Vector3(0.0, 1.0, 0.0)
var moon_direction: Vector3 = Vector3(0.0, -1.0, 0.0)

# 大氣散射參數
var atmospheric_density: float = 0.5
var atmosphere_color: Color = Color.WHITE

# 時序累積
var accumulation_textures: Array[RID] = []
var accumulation_is_a: bool = false
var last_size: Vector2i = Vector2i.ZERO

# 通用資料緩衝
var general_data_buffer: RID = RID()
var general_data: PackedByteArray

# 相機矩陣緩衝（取代 SceneData UBO）
var camera_buffer: RID = RID()
var camera_data: PackedByteArray
# 4 mat4 (256 bytes) + 4 floats (16 bytes) = 272 bytes, 對齊到 288
const CAMERA_BUFFER_SIZE := 288

# uniform set 快取（每個 view 一組）
var uniform_sets: Array[RID] = []
var last_blend_from_rd: RID = RID()
var last_blend_to_rd: RID = RID()

# 模糊參數
var blur_power: float = 2.0
var blur_quality: float = 1.0

## 解析度縮放：0=原生, 1=半, 2=四分之一, 3=八分之一
var resolution_scale: int = 1

# 反射紋理輸出（SSC2 做法）
var reflections_param_name: String = ""
var reflections_texture: Texture2DRD
var reflections_rd: RID = RID()

# 啟用旗標
var clouds_enabled: bool = true


func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	access_resolved_depth = true
	access_resolved_color = true
	needs_motion_vectors = true
	RenderingServer.call_on_render_thread(_initialize_compute)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and is_instance_valid(self):
		RenderingServer.call_on_render_thread(_cleanup_compute)


func _cleanup_compute() -> void:
	if rd:
		if composite_pipeline.is_valid():
			rd.free_rid(composite_pipeline)
		composite_pipeline = RID()

		if composite_shader.is_valid():
			rd.free_rid(composite_shader)
		composite_shader = RID()

		if linear_sampler.is_valid():
			rd.free_rid(linear_sampler)
		linear_sampler = RID()

		if nearest_sampler.is_valid():
			rd.free_rid(nearest_sampler)
		nearest_sampler = RID()

		if general_data_buffer.is_valid():
			rd.free_rid(general_data_buffer)
		general_data_buffer = RID()

		if camera_buffer.is_valid():
			rd.free_rid(camera_buffer)
		camera_buffer = RID()

		for tex in accumulation_textures:
			if tex.is_valid():
				rd.free_rid(tex)
		accumulation_textures.clear()
		uniform_sets.clear()


func _initialize_compute() -> void:
	rd = RenderingServer.get_rendering_device()
	if not rd:
		enabled = false
		printerr("VolumetricCloudEffect: 沒有可用的 RenderingDevice")
		return

	# 建立取樣器
	var linear_state := RDSamplerState.new()
	linear_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	linear_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	linear_sampler = rd.sampler_create(linear_state)

	var nearest_state := RDSamplerState.new()
	nearest_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	nearest_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	nearest_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	nearest_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	nearest_sampler = rd.sampler_create(nearest_state)

	# 載入合成 shader
	var shader_file := load(COMPOSITE_SHADER_PATH) as RDShaderFile
	if not shader_file:
		enabled = false
		printerr("VolumetricCloudEffect: 找不到合成 shader")
		return

	var spirv := shader_file.get_spirv()
	var compile_err: String = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if compile_err != "":
		enabled = false
		printerr("VolumetricCloudEffect: Composite shader 編譯失敗:\n", compile_err)
		return
	composite_shader = rd.shader_create_from_spirv(spirv)
	if not composite_shader.is_valid():
		enabled = false
		printerr("VolumetricCloudEffect: shader_create_from_spirv 失敗")
		return

	composite_pipeline = rd.compute_pipeline_create(composite_shader)

	# 建立通用資料緩衝（128 bytes = 32 floats）
	general_data_buffer = rd.uniform_buffer_create(128)
	general_data.resize(128)

	# 建立相機矩陣緩衝
	camera_buffer = rd.uniform_buffer_create(CAMERA_BUFFER_SIZE)
	camera_data.resize(CAMERA_BUFFER_SIZE)


func _render_callback(p_effect_callback_type: int, p_render_data: RenderData) -> void:
	if not rd or not composite_pipeline.is_valid() or not clouds_enabled:
		return

	if not blend_from_texture or not blend_to_texture:
		return

	var blend_from_rd := blend_from_texture.texture_rd_rid
	var blend_to_rd := blend_to_texture.texture_rd_rid
	if not blend_from_rd.is_valid() or not blend_to_rd.is_valid():
		return

	var render_scene_buffers := p_render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if not render_scene_buffers:
		return

	var size := render_scene_buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return

	var render_scene_data: RenderSceneData = p_render_data.get_render_scene_data()
	var view_count := render_scene_buffers.get_view_count()

	# 重建條件：解析度變、blend 貼圖 RID 變、或 uniform set 被引擎作廢。
	# 最後一項跟 noise set 同理：本 set 綁了引擎擁有的 color/depth 緩衝 RID，
	# 解析度或 render target 變動時引擎會重建那些 view、連帶作廢本 set。用
	# uniform_set_is_valid 主動偵測，比只靠 size 比較更穩。
	var set_invalid: bool = uniform_sets.is_empty() or not rd.uniform_set_is_valid(uniform_sets[0])
	var needs_rebuild: bool = (size != last_size
		or uniform_sets.size() != view_count
		or blend_from_rd != last_blend_from_rd
		or blend_to_rd != last_blend_to_rd
		or set_invalid)
	if needs_rebuild:
		_rebuild_resources(render_scene_buffers, size, view_count, blend_from_rd, blend_to_rd, render_scene_data)
		last_size = size
		last_blend_from_rd = blend_from_rd
		last_blend_to_rd = blend_to_rd

	# 更新通用資料
	_update_general_data(size, render_scene_data)

	# 執行合成（考慮解析度縮放）
	var res_div: int = int(pow(2.0, float(resolution_scale)))
	var work_size_x: int = (size.x + res_div - 1) / res_div
	var work_size_y: int = (size.y + res_div - 1) / res_div
	var x_groups := ((work_size_x - 1) / 8) + 1
	var y_groups := ((work_size_y - 1) / 8) + 1

	for view in view_count:
		if view >= uniform_sets.size():
			break
		# 防呆：重建後仍無效就跳過該 view，不送進 dispatch（避免 null bind 連鎖錯誤）
		if not rd.uniform_set_is_valid(uniform_sets[view]):
			continue
		var compute_list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(compute_list, composite_pipeline)
		rd.compute_list_bind_uniform_set(compute_list, uniform_sets[view], 0)
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
		rd.compute_list_end()

	accumulation_is_a = not accumulation_is_a


func _rebuild_resources(buffers: RenderSceneBuffersRD, size: Vector2i, view_count: int,
		blend_from_rd: RID, blend_to_rd: RID, scene_data: RenderSceneData) -> void:
	# 清理舊的
	for tex in accumulation_textures:
		if tex.is_valid():
			rd.free_rid(tex)
	accumulation_textures.clear()
	uniform_sets.clear()
	if reflections_rd.is_valid():
		rd.free_rid(reflections_rd)
		reflections_rd = RID()

	# 建立反射紋理
	var refl_format := RDTextureFormat.new()
	refl_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	refl_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	refl_format.width = size.x
	refl_format.height = size.y
	refl_format.depth = 1
	refl_format.array_layers = 1
	refl_format.mipmaps = 1
	refl_format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	)
	reflections_rd = rd.texture_create(refl_format, RDTextureView.new())
	reflections_texture = Texture2DRD.new()
	reflections_texture.texture_rd_rid = reflections_rd
	if reflections_param_name != "":
		RenderingServer.global_shader_parameter_set(reflections_param_name, reflections_texture)

	var msaa_mode := buffers.get_msaa_3d()
	var is_msaa: bool = msaa_mode != RenderingServer.ViewportMSAA.VIEWPORT_MSAA_DISABLED

	for view in view_count:
		# MSAA 支援：用 resolved 版本（false）確保可以當 sampler 取樣
		var color_image: RID = buffers.get_color_layer(view, false)
		var depth_image: RID = buffers.get_depth_layer(view, false)

		# 建立累積貼圖（顏色 A/B + 資料 A/B = 4 張）
		var accum_format := RDTextureFormat.new()
		accum_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		accum_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
		accum_format.width = size.x
		accum_format.height = size.y
		accum_format.depth = 1
		accum_format.array_layers = 1
		accum_format.mipmaps = 1
		accum_format.usage_bits = (
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
			RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
			RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
		)

		for i in 4:
			accumulation_textures.append(rd.texture_create(accum_format, RDTextureView.new()))

		# 建立 uniform set
		var uniforms: Array[RDUniform] = []

		# binding 0: 螢幕色彩（讀寫）
		var color_uniform := RDUniform.new()
		color_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		color_uniform.binding = 0
		color_uniform.add_id(color_image)
		uniforms.push_back(color_uniform)

		# binding 1: 深度
		var depth_uniform := RDUniform.new()
		depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		depth_uniform.binding = 1
		depth_uniform.add_id(nearest_sampler)
		depth_uniform.add_id(depth_image)
		uniforms.push_back(depth_uniform)

		# binding 2: 八面體貼圖 blend_from
		var from_uniform := RDUniform.new()
		from_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		from_uniform.binding = 2
		from_uniform.add_id(linear_sampler)
		from_uniform.add_id(blend_from_rd)
		uniforms.push_back(from_uniform)

		# binding 3: 八面體貼圖 blend_to
		var to_uniform := RDUniform.new()
		to_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		to_uniform.binding = 3
		to_uniform.add_id(linear_sampler)
		to_uniform.add_id(blend_to_rd)
		uniforms.push_back(to_uniform)

		# binding 4: 通用資料
		var data_uniform := RDUniform.new()
		data_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		data_uniform.binding = 4
		data_uniform.add_id(general_data_buffer)
		uniforms.push_back(data_uniform)

		# binding 5: 累積顏色 A
		var accum_ca := RDUniform.new()
		accum_ca.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		accum_ca.binding = 5
		accum_ca.add_id(accumulation_textures[view * 4])
		uniforms.push_back(accum_ca)

		# binding 6: 累積顏色 B
		var accum_cb := RDUniform.new()
		accum_cb.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		accum_cb.binding = 6
		accum_cb.add_id(accumulation_textures[view * 4 + 1])
		uniforms.push_back(accum_cb)

		# binding 7: 累積資料 A
		var accum_da := RDUniform.new()
		accum_da.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		accum_da.binding = 7
		accum_da.add_id(accumulation_textures[view * 4 + 2])
		uniforms.push_back(accum_da)

		# binding 8: 累積資料 B
		var accum_db := RDUniform.new()
		accum_db.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		accum_db.binding = 8
		accum_db.add_id(accumulation_textures[view * 4 + 3])
		uniforms.push_back(accum_db)

		# binding 9: 相機矩陣（自建 UBO）
		var cam_uniform := RDUniform.new()
		cam_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		cam_uniform.binding = 9
		cam_uniform.add_id(camera_buffer)
		uniforms.push_back(cam_uniform)

		uniform_sets.append(rd.uniform_set_create(uniforms, composite_shader, 0))


func _update_general_data(size: Vector2i, _scene_data: RenderSceneData) -> void:
	var idx := 0

	# vec2 screen_size (0-1)
	general_data.encode_float(idx, float(size.x)); idx += 4
	general_data.encode_float(idx, float(size.y)); idx += 4

	# float blend_amount (2)
	general_data.encode_float(idx, blend_amount); idx += 4

	# float is_accumulation_a (3)
	general_data.encode_float(idx, 1.0 if accumulation_is_a else 0.0); idx += 4

	# vec3 sun_direction (4-6)
	general_data.encode_float(idx, sun_direction.x); idx += 4
	general_data.encode_float(idx, sun_direction.y); idx += 4
	general_data.encode_float(idx, sun_direction.z); idx += 4

	# float atmospheric_density (7)
	general_data.encode_float(idx, atmospheric_density); idx += 4

	# vec3 moon_direction (8-10)
	general_data.encode_float(idx, moon_direction.x); idx += 4
	general_data.encode_float(idx, moon_direction.y); idx += 4
	general_data.encode_float(idx, moon_direction.z); idx += 4

	# float blur_power (11)
	general_data.encode_float(idx, blur_power); idx += 4

	# vec2 color_correction (12-13)
	general_data.encode_float(idx, color_correction.x); idx += 4
	general_data.encode_float(idx, color_correction.y); idx += 4

	# float blur_quality (14)
	general_data.encode_float(idx, blur_quality); idx += 4

	# float accumulation_decay (15) — 時序累積衰減
	general_data.encode_float(idx, 0.7); idx += 4

	# vec3 atmosphere_color (16-18)
	general_data.encode_float(idx, atmosphere_color.r); idx += 4
	general_data.encode_float(idx, atmosphere_color.g); idx += 4
	general_data.encode_float(idx, atmosphere_color.b); idx += 4

	# resolution_scale (19)
	general_data.encode_float(idx, float(int(pow(2.0, float(resolution_scale))))); idx += 4

	# 剩餘 12 floats 保留給未來擴充
	# (idx = 80, 剩 48 bytes = 12 floats)

	rd.buffer_update(general_data_buffer, 0, general_data.size(), general_data)

	# 更新相機矩陣
	_update_camera_data(_scene_data)


func _encode_projection(data: PackedByteArray, offset: int, proj: Projection) -> int:
	for col in 4:
		var v: Vector4 = proj[col]
		data.encode_float(offset, v.x); offset += 4
		data.encode_float(offset, v.y); offset += 4
		data.encode_float(offset, v.z); offset += 4
		data.encode_float(offset, v.w); offset += 4
	return offset


func _encode_transform_as_mat4(data: PackedByteArray, offset: int, xform: Transform3D) -> int:
	# 編碼成 column-major mat4
	data.encode_float(offset, xform.basis.x.x); offset += 4
	data.encode_float(offset, xform.basis.x.y); offset += 4
	data.encode_float(offset, xform.basis.x.z); offset += 4
	data.encode_float(offset, 0.0); offset += 4

	data.encode_float(offset, xform.basis.y.x); offset += 4
	data.encode_float(offset, xform.basis.y.y); offset += 4
	data.encode_float(offset, xform.basis.y.z); offset += 4
	data.encode_float(offset, 0.0); offset += 4

	data.encode_float(offset, xform.basis.z.x); offset += 4
	data.encode_float(offset, xform.basis.z.y); offset += 4
	data.encode_float(offset, xform.basis.z.z); offset += 4
	data.encode_float(offset, 0.0); offset += 4

	data.encode_float(offset, xform.origin.x); offset += 4
	data.encode_float(offset, xform.origin.y); offset += 4
	data.encode_float(offset, xform.origin.z); offset += 4
	data.encode_float(offset, 1.0); offset += 4
	return offset


var _prev_cam_transform: Transform3D = Transform3D.IDENTITY
var _prev_cam_projection: Projection = Projection.IDENTITY
var _camera_initialized: bool = false


# 為什麼自建 CameraData UBO，而不是用 Godot 原生的 SceneData UBO（SSC2 做法）：
#   原生 SceneData UBO 含引擎自己維護的 prev_data，理論上時序最準。但要在 .glsl
#   手寫一份逐位元組對齊 Godot 4.6 內部佈局的 SceneData 結構，抄錯就是靜默拖影
#   （不報錯、雲糊掉），且綁的是引擎擁有的 UBO RID，會踩跟 noise set 同一類的
#   失效問題（見 VolumetricCloudRenderer 的 _ensure_uniform_sets 註解）。
#
#   自建 UBO：我們完全擁有、每幀更新、恆有效，不依賴引擎內部結構。prev 用上一幀
#   的 cam_transform，時序精確是 1 幀前；跟引擎 prev_data 唯一差別是 TAA jitter
#   的次像素偏移——對模糊、緩變的八面體雲重投影完全不可見。用安全換取看不見的
#   精度，是划算的。
func _update_camera_data(scene_data: RenderSceneData) -> void:
	if not camera_buffer.is_valid():
		return

	var cam_xform: Transform3D = scene_data.get_cam_transform()
	var cam_proj: Projection = scene_data.get_cam_projection()

	# 首幀：prev = current，避免第一幀重投影用 IDENTITY 跑出垃圾偏移
	if not _camera_initialized:
		_prev_cam_transform = cam_xform
		_prev_cam_projection = cam_proj
		_camera_initialized = true

	var idx: int = 0
	# mat4 inv_projection（從 Projection 反轉）
	var inv_proj: Projection = cam_proj.inverse()
	idx = _encode_projection(camera_data, idx, inv_proj)

	# mat4 inv_view（cam_transform 就是 inv_view）
	idx = _encode_transform_as_mat4(camera_data, idx, cam_xform)

	# mat4 prev_view（前一幀的 view = inv(prev_cam_transform)）
	var prev_view: Transform3D = _prev_cam_transform.affine_inverse()
	idx = _encode_transform_as_mat4(camera_data, idx, prev_view)

	# mat4 prev_projection
	idx = _encode_projection(camera_data, idx, _prev_cam_projection)

	# z_far, z_near, padding
	camera_data.encode_float(idx, cam_proj.get_z_far()); idx += 4
	camera_data.encode_float(idx, cam_proj.get_z_near()); idx += 4
	camera_data.encode_float(idx, 0.0); idx += 4
	camera_data.encode_float(idx, 0.0); idx += 4

	rd.buffer_update(camera_buffer, 0, CAMERA_BUFFER_SIZE, camera_data)

	# 記住當前幀給下一幀用
	_prev_cam_transform = cam_xform
	_prev_cam_projection = cam_proj
