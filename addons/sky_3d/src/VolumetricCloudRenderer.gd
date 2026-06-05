# Copyright (c) 2023-2025 Cory Petkovsek and Contributors
# Compute shader 體積雲渲染器
# 參考 clayjohn/godot-volumetric-cloud-demo-v2 (MIT)

@tool
class_name VolumetricCloudRenderer
extends RefCounted

const COMPUTE_SHADER_PATH = "res://addons/sky_3d/shaders/VolumetricCloudsCompute.glsl"

var rd: RenderingDevice
var shader_rd: RID
var pipeline: RID

# 三重緩衝貼圖
var texture_rd: Array = [RID(), RID(), RID()]
var texture_set: Array = [RID(), RID(), RID()]
var textures: Array[Texture2DRD] = []

var noise_uniform_set: RID = RID()
var noise_sampler: RID

var texture_to_update: int = 0
var texture_to_blend_from: int = 1
var texture_to_blend_to: int = 2

var update_position: Vector2i = Vector2i.ZERO
var update_region_size: int = 96
var num_workgroups: int = 12
var texture_size: int = 768
var frames_to_update: int = 64
var frame: int = 0

var can_run: bool = false
var needs_full_init: bool = true

# 每幀快取的資料
var cloud_pos: Vector2 = Vector2.ZERO
var detail_pos: Vector2 = Vector2.ZERO
var weather_pos: Vector2 = Vector2.ZERO
var sun_direction: Vector3 = Vector3(0, 1, 0)
var moon_direction: Vector3 = Vector3(0, -1, 0)
var coverage: float = 0.25
var cloud_type: float = 0.5
var density: float = 0.05
var absorption: float = 0.06
var detail_strength: float = 0.4
var cloud_day_color: Color = Color.WHITE
var cloud_horizon_color: Color = Color(1.0, 0.9, 0.8)
var cloud_night_color: Color = Color(0.06, 0.08, 0.14)
var use_weather: bool = true
var current_time: float = 0.0
var generated_weather_map: ImageTexture


func initialize(p_texture_size: int = 768, p_frames: int = 64) -> void:
	_generate_weather_map()

	texture_size = p_texture_size
	frames_to_update = p_frames

	var frames_sqrt: int = int(sqrt(frames_to_update))
	update_region_size = texture_size / frames_sqrt
	if texture_size % frames_sqrt != 0:
		texture_size = update_region_size * frames_sqrt
	num_workgroups = (update_region_size + 7) / 8

	RenderingServer.call_on_render_thread(_initialize_compute.bind(texture_size))


func cleanup() -> void:
	can_run = false
	frame = 0
	texture_to_update = 0
	texture_to_blend_from = 1
	texture_to_blend_to = 2
	update_position = Vector2i.ZERO

	if rd:
		for i in range(3):
			if texture_rd[i].is_valid():
				rd.free_rid(texture_rd[i])
				texture_rd[i] = RID()
		if shader_rd.is_valid():
			rd.free_rid(shader_rd)
			shader_rd = RID()
		if noise_sampler.is_valid():
			rd.free_rid(noise_sampler)
			noise_sampler = RID()


func get_blend_from_texture() -> Texture2DRD:
	if textures.size() > texture_to_blend_from:
		return textures[texture_to_blend_from]
	return null


func get_blend_to_texture() -> Texture2DRD:
	if textures.size() > texture_to_blend_to:
		return textures[texture_to_blend_to]
	return null


func get_blend_amount() -> float:
	return float(frame) / float(frames_to_update)


func render_frame() -> void:
	if not can_run:
		return

	if needs_full_init:
		needs_full_init = false
		render_full()

	if frame >= frames_to_update:
		texture_to_update = (texture_to_update + 1) % 3
		texture_to_blend_from = (texture_to_blend_from + 1) % 3
		texture_to_blend_to = (texture_to_blend_to + 1) % 3
		frame = 0

	RenderingServer.call_on_render_thread(_render_process.bind(texture_to_update))

	update_position.x += update_region_size
	if update_position.x >= texture_size:
		update_position.x = 0
		update_position.y += update_region_size
	if update_position.y >= texture_size:
		update_position = Vector2i.ZERO

	frame += 1


func render_full() -> void:
	for i in range(frames_to_update * 2):
		render_frame()


# ============================================================================
# 渲染執行緒
# ============================================================================

func _render_process(p_texture_to_update: int) -> void:
	if not can_run:
		return
	textures[p_texture_to_update].texture_rd_rid = texture_rd[p_texture_to_update]

	var push_constant := PackedFloat32Array()

	# texture_size, update_position (vec2, vec2)
	push_constant.push_back(texture_size)
	push_constant.push_back(texture_size)
	push_constant.push_back(update_position.x)
	push_constant.push_back(update_position.y)

	# cloud_pos, detailed_pos (vec2, vec2)
	push_constant.push_back(cloud_pos.x)
	push_constant.push_back(cloud_pos.y)
	push_constant.push_back(detail_pos.x)
	push_constant.push_back(detail_pos.y)

	# weather_pos, coverage, cloud_type (vec2, float, float)
	push_constant.push_back(weather_pos.x)
	push_constant.push_back(weather_pos.y)
	push_constant.push_back(coverage)
	push_constant.push_back(cloud_type)

	# sun_direction, density (vec3, float)
	push_constant.push_back(sun_direction.x)
	push_constant.push_back(sun_direction.y)
	push_constant.push_back(sun_direction.z)
	push_constant.push_back(density)

	# moon_direction, absorption (vec3, float)
	push_constant.push_back(moon_direction.x)
	push_constant.push_back(moon_direction.y)
	push_constant.push_back(moon_direction.z)
	push_constant.push_back(absorption)

	# cloud_day_color, detail_strength (vec3, float)
	push_constant.push_back(cloud_day_color.r)
	push_constant.push_back(cloud_day_color.g)
	push_constant.push_back(cloud_day_color.b)
	push_constant.push_back(detail_strength)

	# cloud_horizon_color, time (vec3, float)
	push_constant.push_back(cloud_horizon_color.r)
	push_constant.push_back(cloud_horizon_color.g)
	push_constant.push_back(cloud_horizon_color.b)
	push_constant.push_back(current_time)

	# cloud_night_color, use_weather (vec3, float)
	push_constant.push_back(cloud_night_color.r)
	push_constant.push_back(cloud_night_color.g)
	push_constant.push_back(cloud_night_color.b)
	push_constant.push_back(1.0 if use_weather else 0.0)

	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, noise_uniform_set, 1)
	rd.compute_list_bind_uniform_set(compute_list, texture_set[p_texture_to_update], 0)
	rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
	rd.compute_list_dispatch(compute_list, num_workgroups, num_workgroups, 1)
	rd.compute_list_end()


func _initialize_compute(p_texture_size: int) -> void:
	rd = RenderingServer.get_rendering_device()
	if not rd:
		can_run = false
		return

	# 建立 shader
	var shader_file = load(COMPUTE_SHADER_PATH)
	if not shader_file:
		can_run = false
		return
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	shader_rd = rd.shader_create_from_spirv(shader_spirv)
	if not shader_rd.is_valid():
		can_run = false
		return
	pipeline = rd.compute_pipeline_create(shader_rd)

	# 建立噪音 uniform set
	noise_uniform_set = _create_noise_uniform_set()

	# 建立三重緩衝貼圖
	var tf := RDTextureFormat.new()
	tf.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tf.width = p_texture_size
	tf.height = p_texture_size
	tf.depth = 1
	tf.array_layers = 1
	tf.mipmaps = 1
	tf.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT +
		RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT +
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT +
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT +
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	)
	if Engine.is_editor_hint():
		tf.usage_bits += RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT

	textures.clear()
	for i in range(3):
		texture_rd[i] = rd.texture_create(tf, RDTextureView.new(), [])
		rd.texture_clear(texture_rd[i], Color(0, 0, 0, 0), 0, 1, 0, 1)
		texture_set[i] = _create_texture_uniform_set(texture_rd[i])

		var tex := Texture2DRD.new()
		tex.texture_rd_rid = texture_rd[i]
		textures.push_back(tex)

	can_run = true


func _create_texture_uniform_set(p_texture_rd: RID) -> RID:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = 0
	uniform.add_id(p_texture_rd)
	return rd.uniform_set_create([uniform], shader_rd, 0)


func _create_noise_uniform_set() -> RID:
	var uniforms: Array[RDUniform] = []

	var sampler_state := RDSamplerState.new()
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	noise_sampler = rd.sampler_create(sampler_state)

	# 基底噪音
	var base_noise = preload("res://addons/sky_3d/assets/thirdparty/textures/clouds/perlworlnoise.tga")
	var base_rd = RenderingServer.texture_get_rd_texture(base_noise.get_rid())
	var u0 := RDUniform.new()
	u0.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u0.binding = 0
	u0.add_id(noise_sampler)
	u0.add_id(base_rd)
	uniforms.push_back(u0)

	# 細節噪音
	var detail_noise = preload("res://addons/sky_3d/assets/thirdparty/textures/clouds/worlnoise.bmp")
	var detail_rd = RenderingServer.texture_get_rd_texture(detail_noise.get_rid())
	var u1 := RDUniform.new()
	u1.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u1.binding = 1
	u1.add_id(noise_sampler)
	u1.add_id(detail_rd)
	uniforms.push_back(u1)

	# 天氣圖（自動生成）
	var weather_rd = RenderingServer.texture_get_rd_texture(generated_weather_map.get_rid())
	var u2 := RDUniform.new()
	u2.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u2.binding = 2
	u2.add_id(noise_sampler)
	u2.add_id(weather_rd)
	uniforms.push_back(u2)

	return rd.uniform_set_create(uniforms, shader_rd, 1)


func _generate_weather_map() -> void:
	const MAP_SIZE := 512

	# R：雲型 — 低頻，大片區域同一種雲
	var type_noise := FastNoiseLite.new()
	type_noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	type_noise.frequency = 0.004
	type_noise.seed = 42
	type_noise.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE

	# B：覆蓋率 — 用 cellular 噪音產生明確的雲團/晴天分界
	var cov_noise := FastNoiseLite.new()
	cov_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	cov_noise.frequency = 0.005
	cov_noise.seed = 123
	cov_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	cov_noise.fractal_octaves = 4

	# 大尺度遮罩：決定哪裡是大片晴天
	var mask_noise := FastNoiseLite.new()
	mask_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	mask_noise.frequency = 0.0015
	mask_noise.seed = 789

	# G：降水
	var precip_noise := FastNoiseLite.new()
	precip_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	precip_noise.frequency = 0.005
	precip_noise.seed = 456

	var img := Image.create(MAP_SIZE, MAP_SIZE, false, Image.FORMAT_RGB8)

	for y in MAP_SIZE:
		for x in MAP_SIZE:
			var fx := float(x)
			var fy := float(y)

			# R：雲型 — cellular noise 給每個區塊一個隨機值
			# 量化到四段讓四種雲型都有機會出現
			var type_raw := type_noise.get_noise_2d(fx, fy) * 0.5 + 0.5
			var type_quantized := floorf(type_raw * 4.0) / 4.0
			# 保留區塊內的微小變化（不要完全硬切）
			var type_frac := fmod(type_raw * 4.0, 1.0) * 0.2
			var type_val := clampf(type_quantized + type_frac, 0.0, 1.0)

			# B：覆蓋率 — 兩層混合後做強力 smoothstep
			var cov_detail := cov_noise.get_noise_2d(fx, fy) * 0.5 + 0.5
			var mask := mask_noise.get_noise_2d(fx, fy) * 0.5 + 0.5
			var cov_raw := mask * 0.6 + cov_detail * 0.4
			# 強力對比：0.3 以下全切、0.6 以上全開
			var t := clampf((cov_raw - 0.3) / 0.3, 0.0, 1.0)
			var cov_val := t * t * (3.0 - 2.0 * t)
			# 再做一次讓邊界更銳利
			t = clampf(cov_val, 0.0, 1.0)
			cov_val = t * t * (3.0 - 2.0 * t)

			# G：降水
			var precip_val := (precip_noise.get_noise_2d(fx, fy) * 0.5 + 0.5) * cov_val

			img.set_pixel(x, y, Color(type_val, precip_val, cov_val))

	generated_weather_map = ImageTexture.create_from_image(img)
