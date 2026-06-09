# Copyright (c) 2023-2025 Cory Petkovsek and Contributors
# Compute shader 體積雲渲染器
# 基底：clayjohn/godot-volumetric-cloud-demo-v2 (MIT)
# curl noise / 風切 / AO / 自適應步長：Bonkahe/SunshineClouds2 (MIT)

@tool
class_name VolumetricCloudRenderer
extends RefCounted

const COMPUTE_SHADER_PATH := "res://addons/sky_3d/shaders/VolumetricCloudsCompute.glsl"

var rd: RenderingDevice
var shader_rd: RID
var pipeline: RID

# 三重緩衝貼圖
var texture_rd: Array = [RID(), RID(), RID()]
var texture_set: Array = [RID(), RID(), RID()]
var textures: Array[Texture2DRD] = []

var noise_uniform_set: RID = RID()
var noise_sampler: RID = RID()        # 重複取樣器（3D 噪音用），init 建一次重用
var clamp_sampler: RID = RID()        # 夾邊取樣器（梯度紋理用），init 建一次重用
var _noise_fail_count: int = 0        # 連續建立失敗計數，用來節流錯誤訊息

# uniform buffer（取代 push constant）
var params_buffer: RID = RID()
var params_uniform_set: RID = RID()
var lights_buffer: RID = RID()
var lights_uniform_set: RID = RID()

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

# === 基本參數 ===
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

# === 新增參數（SSC2 零件） ===
var curl_strength: float = 4500.0
var wind_shear_power: float = 0.0
var wind_direction: Vector2 = Vector2(1.0, 0.0)
var wind_shear_range: float = 0.54
var ao_strength: float = 0.3

# 噪音尺度
var base_noise_scale: float = 0.00008
var detail_noise_scale: float = 0.001
var weather_scale: float = 0.0002
var curl_noise_scale: float = 0.00005

# 品質
var march_steps: float = 128.0
var shadow_steps: float = 6.0

# Uniform buffer 大小（對齊到 std140）
const PARAMS_BUFFER_SIZE := 256
# Lights buffer: 4 DirLight(32B each) + 16 PtLight(32B each) + 16B counts = 656B
const LIGHTS_BUFFER_SIZE := 672

# 光源追蹤
var directional_lights: Array[Dictionary] = []  # [{direction: Vector3, color: Color, energy: float, shadow_steps: int}]
var point_lights: Array[Dictionary] = []  # [{position: Vector3, color: Color, energy: float, radius: float}]

# 雲密度查詢 — 精確版讀回八面體結果貼圖的實際 alpha（走完整管線的真實密度）
var _density_queries: Array[Vector3] = []
var _density_callbacks: Array[Callable] = []
var _density_readback_bytes: PackedByteArray = PackedByteArray()  # 上次讀回的 rgba16f raw bytes
var _density_readback_dim: int = 0                                # 讀回貼圖的邊長
var _density_readback_pending: bool = false                       # readback 排程中
var _density_readback_fresh: bool = false                         # 有新資料待消費


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
		if clamp_sampler.is_valid():
			rd.free_rid(clamp_sampler)
			clamp_sampler = RID()
		if params_buffer.is_valid():
			rd.free_rid(params_buffer)
			params_buffer = RID()
		if lights_buffer.is_valid():
			rd.free_rid(lights_buffer)
			lights_buffer = RID()


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

# 確保這一幀要用的 uniform set 都有效，必要時重建。回傳是否就緒。
#
# 為什麼 noise set（set 1）需要延遲建立 + 失效重建，其他 set 不用：
#   set 1 綁的是 RenderingServer.texture_get_rd_texture() 拿到的「共享 view RID」，
#   那不是我們擁有的 RID。perlworlnoise/worlnoise 是 vram_texture=true 的 BPTC 壓縮
#   3D 紋理，開機後才延遲上傳到 VRAM。引擎補完上傳（重建底層 RD view）時會釋放舊
#   view，而 RenderingDevice.free 會「遞迴釋放所有依賴它的 uniform set」
#   （Godot issue #103073 維護者確認、#118292 印證 texture_replace 路徑），於是
#   set 1 在我們建好後、首次 dispatch 前被引擎連帶作廢。
#
#   這是 Godot CompositorEffect 社群的標準應對：用引擎管理的紋理時，把含 sampled
#   紋理的 uniform set 視為可被引擎作廢，dispatch 前驗證、失效就重建。失效實務上只
#   發生在開機延遲上傳完成那一次，之後穩定，每幀只多一次 O(1) 的 is_valid 檢查。
#
#   set 0/2/3（輸出貼圖、參數、光源）綁的是我們自己 rd.texture_create /
#   uniform_buffer_create 出來的 RID，生命週期歸我們管，不會被引擎作廢，故只在
#   初始化建一次即可。
func _ensure_uniform_sets(p_texture_to_update: int) -> bool:
	# set 1：noise（引擎共享 RID，可能被作廢 → 延遲建立 + 失效重建）
	if not rd.uniform_set_is_valid(noise_uniform_set):
		noise_uniform_set = _create_noise_uniform_set()
		if not rd.uniform_set_is_valid(noise_uniform_set):
			# 紋理尚未就緒，安靜跳過這一幀（下一幀會再試）
			return false

	# set 2/3：我們擁有的 buffer，理論上恆有效；無效代表初始化出問題，直接跳過
	if not rd.uniform_set_is_valid(params_uniform_set):
		return false
	if not rd.uniform_set_is_valid(lights_uniform_set):
		return false

	# set 0：我們擁有的輸出貼圖，恆有效；防禦性重建以防萬一
	if not rd.uniform_set_is_valid(texture_set[p_texture_to_update]):
		texture_set[p_texture_to_update] = _create_texture_uniform_set(texture_rd[p_texture_to_update])
		if not rd.uniform_set_is_valid(texture_set[p_texture_to_update]):
			return false

	return true


func _render_process(p_texture_to_update: int) -> void:
	if not can_run:
		return
	if not _ensure_uniform_sets(p_texture_to_update):
		return
	textures[p_texture_to_update].texture_rd_rid = texture_rd[p_texture_to_update]

	# 組裝 uniform buffer 資料（std140 對齊）
	var data := PackedByteArray()
	data.resize(PARAMS_BUFFER_SIZE)
	var idx: int = 0

	# vec2 texture_size + vec2 update_position → vec4
	data.encode_float(idx, texture_size); idx += 4
	data.encode_float(idx, texture_size); idx += 4
	data.encode_float(idx, update_position.x); idx += 4
	data.encode_float(idx, update_position.y); idx += 4

	# vec2 cloud_pos + vec2 detail_pos → vec4
	data.encode_float(idx, cloud_pos.x); idx += 4
	data.encode_float(idx, cloud_pos.y); idx += 4
	data.encode_float(idx, detail_pos.x); idx += 4
	data.encode_float(idx, detail_pos.y); idx += 4

	# vec2 weather_pos + coverage + cloud_type → vec4
	data.encode_float(idx, weather_pos.x); idx += 4
	data.encode_float(idx, weather_pos.y); idx += 4
	data.encode_float(idx, coverage); idx += 4
	data.encode_float(idx, cloud_type); idx += 4

	# vec3 sun_direction + detail_strength → vec4
	data.encode_float(idx, sun_direction.x); idx += 4
	data.encode_float(idx, sun_direction.y); idx += 4
	data.encode_float(idx, sun_direction.z); idx += 4
	data.encode_float(idx, detail_strength); idx += 4

	# vec3 moon_direction + time → vec4
	data.encode_float(idx, moon_direction.x); idx += 4
	data.encode_float(idx, moon_direction.y); idx += 4
	data.encode_float(idx, moon_direction.z); idx += 4
	data.encode_float(idx, current_time); idx += 4

	# vec3 cloud_day_color + use_weather → vec4
	data.encode_float(idx, cloud_day_color.r); idx += 4
	data.encode_float(idx, cloud_day_color.g); idx += 4
	data.encode_float(idx, cloud_day_color.b); idx += 4
	data.encode_float(idx, 1.0 if use_weather else 0.0); idx += 4

	# vec3 cloud_horizon_color + curl_strength → vec4
	data.encode_float(idx, cloud_horizon_color.r); idx += 4
	data.encode_float(idx, cloud_horizon_color.g); idx += 4
	data.encode_float(idx, cloud_horizon_color.b); idx += 4
	data.encode_float(idx, curl_strength); idx += 4

	# vec3 cloud_night_color + wind_shear_power → vec4
	data.encode_float(idx, cloud_night_color.r); idx += 4
	data.encode_float(idx, cloud_night_color.g); idx += 4
	data.encode_float(idx, cloud_night_color.b); idx += 4
	data.encode_float(idx, wind_shear_power); idx += 4

	# vec2 wind_direction + wind_shear_range + ao_strength → vec4
	data.encode_float(idx, wind_direction.x); idx += 4
	data.encode_float(idx, wind_direction.y); idx += 4
	data.encode_float(idx, wind_shear_range); idx += 4
	data.encode_float(idx, ao_strength); idx += 4

	# 4 floats: noise scales → vec4
	data.encode_float(idx, base_noise_scale); idx += 4
	data.encode_float(idx, detail_noise_scale); idx += 4
	data.encode_float(idx, weather_scale); idx += 4
	data.encode_float(idx, curl_noise_scale); idx += 4

	# 4 floats: quality → vec4
	data.encode_float(idx, march_steps); idx += 4
	data.encode_float(idx, shadow_steps); idx += 4
	data.encode_float(idx, density); idx += 4
	data.encode_float(idx, absorption); idx += 4

	rd.buffer_update(params_buffer, 0, PARAMS_BUFFER_SIZE, data)
	_update_lights_buffer()

	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, texture_set[p_texture_to_update], 0)
	rd.compute_list_bind_uniform_set(compute_list, noise_uniform_set, 1)
	rd.compute_list_bind_uniform_set(compute_list, params_uniform_set, 2)
	rd.compute_list_bind_uniform_set(compute_list, lights_uniform_set, 3)
	rd.compute_list_dispatch(compute_list, num_workgroups, num_workgroups, 1)
	rd.compute_list_end()


func _initialize_compute(p_texture_size: int) -> void:
	rd = RenderingServer.get_rendering_device()
	if not rd:
		can_run = false
		return

	# shader
	var shader_file := load(COMPUTE_SHADER_PATH)
	if not shader_file:
		can_run = false
		return
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	var compile_err: String = shader_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if compile_err != "":
		printerr("VolumetricCloudRenderer: Compute shader 編譯失敗:\n", compile_err)
		can_run = false
		return
	shader_rd = rd.shader_create_from_spirv(shader_spirv)
	if not shader_rd.is_valid():
		printerr("VolumetricCloudRenderer: shader_create_from_spirv 失敗")
		can_run = false
		return
	pipeline = rd.compute_pipeline_create(shader_rd)

	# 取樣器建一次重用（我們擁有、生命週期穩定）
	var sampler_state := RDSamplerState.new()
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	noise_sampler = rd.sampler_create(sampler_state)

	var clamp_state := RDSamplerState.new()
	clamp_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	clamp_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	clamp_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	clamp_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	clamp_sampler = rd.sampler_create(clamp_state)

	# 注意：set 1（noise）不在這裡建。它綁的是引擎共享的紋理 view RID，開機時
	# BPTC 3D 紋理的延遲 VRAM 上傳可能還沒完成，現在建會被引擎隨即作廢。改為
	# 在首次 _render_process 由 _ensure_uniform_sets() 延遲建立。詳見該函數註解。

	# 參數 uniform buffer (set 2)
	params_buffer = rd.uniform_buffer_create(PARAMS_BUFFER_SIZE)
	var params_uniform := RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	params_uniform.binding = 0
	params_uniform.add_id(params_buffer)
	params_uniform_set = rd.uniform_set_create([params_uniform], shader_rd, 2)

	# 光源 uniform buffer (set 3)
	lights_buffer = rd.uniform_buffer_create(LIGHTS_BUFFER_SIZE)
	var lights_uniform := RDUniform.new()
	lights_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	lights_uniform.binding = 0
	lights_uniform.add_id(lights_buffer)
	lights_uniform_set = rd.uniform_set_create([lights_uniform], shader_rd, 3)
	_update_lights_buffer()

	# 三重緩衝貼圖 (set 0)
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
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT +
		# 密度查詢需要把貼圖讀回 CPU（texture_get_data_async）
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)

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


func _add_texture_uniform(uniforms: Array[RDUniform], binding: int, sampler: RID,
		texture: Texture, label: String) -> bool:
	var tex_rd := RenderingServer.texture_get_rd_texture(texture.get_rid())
	if not tex_rd.is_valid():
		printerr("VolumetricCloudRenderer: 紋理 RD RID 無效 — ", label)
		return false
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = binding
	u.add_id(sampler)
	u.add_id(tex_rd)
	uniforms.push_back(u)
	return true


# 建立 set 1（noise）。可能被反覆呼叫（失效重建），故 sampler 重用、錯誤節流。
func _create_noise_uniform_set() -> RID:
	var uniforms: Array[RDUniform] = []

	# binding 0: 基底噪音 (Perlin-Worley 3D)
	var base_noise := preload("res://addons/sky_3d/assets/thirdparty/textures/clouds/perlworlnoise.tga")
	if not _add_texture_uniform(uniforms, 0, noise_sampler, base_noise, "perlworlnoise"):
		return _on_noise_set_fail()

	# binding 1: 細節噪音 (Worley 3D)
	var detail_noise := preload("res://addons/sky_3d/assets/thirdparty/textures/clouds/worlnoise.bmp")
	if not _add_texture_uniform(uniforms, 1, noise_sampler, detail_noise, "worlnoise"):
		return _on_noise_set_fail()

	# binding 2: 天氣圖 (2D，程式化生成)
	if not _add_texture_uniform(uniforms, 2, noise_sampler, generated_weather_map, "weather_map"):
		return _on_noise_set_fail()

	# binding 3: Curl noise (SSC2, 3D 紋理 — 128 切片)
	var curl_tex := preload("res://addons/sky_3d/assets/thirdparty/textures/clouds/curl_noise_varied.tga")
	if not _add_texture_uniform(uniforms, 3, noise_sampler, curl_tex, "curl_noise"):
		return _on_noise_set_fail()

	# binding 4: 高度梯度 (SSC2, GradientTexture1D)
	var height_grad := preload("res://addons/sky_3d/assets/resources/height_gradient.tres")
	if not _add_texture_uniform(uniforms, 4, clamp_sampler, height_grad, "height_gradient"):
		return _on_noise_set_fail()

	var result := rd.uniform_set_create(uniforms, shader_rd, 1)
	if not result.is_valid():
		return _on_noise_set_fail()
	_noise_fail_count = 0  # 成功，重置節流
	return result


# 建立失敗時節流錯誤訊息（延遲建立的前幾幀失敗是預期的，不該洗版）
func _on_noise_set_fail() -> RID:
	_noise_fail_count += 1
	# 開機瞬態允許靜默重試；持續失敗才報（第 60 次 ≈ 1 秒後）
	if _noise_fail_count == 60:
		printerr("VolumetricCloudRenderer: noise uniform set 持續建立失敗（已 60 次），體積雲不會渲染")
	return RID()


## 查詢某位置（方向）的雲密度。精確版：非同步讀回八面體結果貼圖的實際 alpha，
## 那是走完整 ray-march 管線（噪音/curl/侵蝕/高度梯度）後的真實積分密度。
## 八面體模型無深度，所以查的是「該方向的雲量」，position 取其方向。
## callback 簽名：func(position: Vector3, density: float) -> void
func query_density(position: Vector3, callback: Callable) -> void:
	if _density_queries.size() >= 32:
		push_warning("VolumetricCloudRenderer: 密度查詢佇列已滿（最多 32 個）")
		return
	_density_queries.append(position)
	_density_callbacks.append(callback)


## 從已讀回的八面體 alpha 取樣某方向的密度。回傳 -1 表示尚無讀回資料。
func sample_octahedral_density(dir: Vector3) -> float:
	if _density_readback_bytes.is_empty() or _density_readback_dim == 0:
		return -1.0
	var n := dir.normalized()
	n.y = maxf(0.001, n.y)
	n = n.normalized()
	# 跟 display/composite shader 一致：vec3_to_oct(dir.xzy)
	var uv := _vec3_to_oct(Vector3(n.x, n.z, n.y))
	var dim := _density_readback_dim
	var px := clampi(int(uv.x * float(dim)), 0, dim - 1)
	var py := clampi(int(uv.y * float(dim)), 0, dim - 1)
	# rgba16f：每像素 8 bytes，alpha 在 byte offset 6
	var offset := (py * dim + px) * 8 + 6
	if offset + 2 > _density_readback_bytes.size():
		return -1.0
	return _density_readback_bytes.decode_half(offset)


## 同步近似查詢（用天氣圖覆蓋率，平滑、不含噪音侵蝕細節，最省、不走 GPU readback）。
## 回傳 0.0~1.0 的覆蓋率近似值。要精確值用 query_density()。
func query_density_sync(world_position: Vector3) -> float:
	if not generated_weather_map:
		return 0.0
	var weather_uv := Vector2(
		world_position.x * weather_scale + 0.5 + weather_pos.x,
		world_position.z * weather_scale + 0.5 + weather_pos.y
	)
	weather_uv = Vector2(fmod(weather_uv.x, 1.0), fmod(weather_uv.y, 1.0))
	if weather_uv.x < 0: weather_uv.x += 1.0
	if weather_uv.y < 0: weather_uv.y += 1.0

	var img: Image = generated_weather_map.get_image()
	if not img:
		return 0.0
	var px: int = clampi(int(weather_uv.x * img.get_width()), 0, img.get_width() - 1)
	var py: int = clampi(int(weather_uv.y * img.get_height()), 0, img.get_height() - 1)
	var weather_color: Color = img.get_pixel(px, py)
	return weather_color.b * coverage


## 處理佇列中的密度查詢（每幀呼叫）。非同步：先排 readback，資料回來下一幀才回答。
func process_density_queries() -> void:
	if _density_queries.is_empty():
		return

	# 沒有新資料 → 排一次 readback，等下一幀
	if not _density_readback_fresh:
		if not _density_readback_pending:
			_density_readback_pending = true
			RenderingServer.call_on_render_thread(_do_density_readback)
		return

	# 有新資料，回答所有排隊查詢
	while _density_queries.size() > 0:
		var pos: Vector3 = _density_queries[0]
		var cb: Callable = _density_callbacks[0]
		_density_queries.remove_at(0)
		_density_callbacks.remove_at(0)
		var d: float = sample_octahedral_density(pos)
		if d < 0.0:
			d = query_density_sync(pos)  # 還沒讀回時用近似後備
		cb.call(pos, clampf(d, 0.0, 1.0))
	_density_readback_fresh = false  # 用過，下批查詢再讀新的


# 渲染執行緒：把當前完成的八面體貼圖非同步讀回 CPU
func _do_density_readback() -> void:
	if not can_run or not rd:
		_density_readback_pending = false
		return
	var tex: RID = texture_rd[texture_to_blend_from]
	if not tex.is_valid():
		_density_readback_pending = false
		return
	_density_readback_dim = texture_size
	rd.texture_get_data_async(tex, 0, _on_density_readback)


# readback 完成回呼（render thread）
func _on_density_readback(bytes: PackedByteArray) -> void:
	_density_readback_bytes = bytes
	_density_readback_pending = false
	_density_readback_fresh = true


# 八面體編碼（跟 shader 的 vec3_to_oct 一致），方向 → UV
func _vec3_to_oct(e: Vector3) -> Vector2:
	var s := absf(e.x) + absf(e.y) + absf(e.z)
	if s == 0.0:
		return Vector2(0.5, 0.5)
	e /= s
	var exy := Vector2(e.x, e.y)
	if e.z < 0.0:
		var sx := 1.0 if e.x >= 0.0 else -1.0
		var sy := 1.0 if e.y >= 0.0 else -1.0
		exy = Vector2((1.0 - absf(e.y)) * sx, (1.0 - absf(e.x)) * sy)
	var n := Vector2()
	n.y = exy.y * 0.5 + 0.5
	n.x = exy.x * 0.5 + n.y
	n.y = exy.x * -0.5 + n.y
	return n


func _update_lights_buffer() -> void:
	if not rd or not lights_buffer.is_valid():
		return
	var data := PackedByteArray()
	data.resize(LIGHTS_BUFFER_SIZE)
	var idx: int = 0

	# 方向光（4 個，每個 32 bytes = 2 × vec4）
	for i in range(4):
		if i < directional_lights.size():
			var light: Dictionary = directional_lights[i]
			var dir: Vector3 = light.get("direction", Vector3(0, 1, 0))
			var col: Color = light.get("color", Color.WHITE)
			var energy: float = light.get("energy", 1.0)
			var steps: int = light.get("shadow_steps", 6)
			data.encode_float(idx, dir.x); idx += 4
			data.encode_float(idx, dir.y); idx += 4
			data.encode_float(idx, dir.z); idx += 4
			data.encode_float(idx, float(steps)); idx += 4
			data.encode_float(idx, col.r); idx += 4
			data.encode_float(idx, col.g); idx += 4
			data.encode_float(idx, col.b); idx += 4
			data.encode_float(idx, col.a * energy); idx += 4
		else:
			# 預設太陽光
			if i == 0:
				data.encode_float(idx, sun_direction.x); idx += 4
				data.encode_float(idx, sun_direction.y); idx += 4
				data.encode_float(idx, sun_direction.z); idx += 4
				data.encode_float(idx, shadow_steps); idx += 4
				data.encode_float(idx, 1.0); idx += 4
				data.encode_float(idx, 1.0); idx += 4
				data.encode_float(idx, 1.0); idx += 4
				data.encode_float(idx, 1.0); idx += 4
			else:
				idx += 32

	# 點光源（16 個，每個 32 bytes = 2 × vec4）
	for i in range(16):
		if i < point_lights.size():
			var light: Dictionary = point_lights[i]
			var pos: Vector3 = light.get("position", Vector3.ZERO)
			var col: Color = light.get("color", Color.WHITE)
			var energy: float = light.get("energy", 1.0)
			var radius: float = light.get("radius", 100.0)
			data.encode_float(idx, pos.x); idx += 4
			data.encode_float(idx, pos.y); idx += 4
			data.encode_float(idx, pos.z); idx += 4
			data.encode_float(idx, radius); idx += 4
			data.encode_float(idx, col.r); idx += 4
			data.encode_float(idx, col.g); idx += 4
			data.encode_float(idx, col.b); idx += 4
			data.encode_float(idx, col.a * energy); idx += 4
		else:
			idx += 32

	# counts (4 floats = 1 vec4)
	data.encode_float(idx, float(maxi(directional_lights.size(), 1))); idx += 4
	data.encode_float(idx, float(point_lights.size())); idx += 4
	data.encode_float(idx, 0.0); idx += 4
	data.encode_float(idx, 0.0); idx += 4

	rd.buffer_update(lights_buffer, 0, LIGHTS_BUFFER_SIZE, data)


func _generate_weather_map() -> void:
	const MAP_SIZE := 512

	# R：雲型 — cellular 噪音給每個區塊一個隨機值
	var type_noise := FastNoiseLite.new()
	type_noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	type_noise.frequency = 0.004
	type_noise.seed = 42
	type_noise.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE

	# B：覆蓋率
	var cov_noise := FastNoiseLite.new()
	cov_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	cov_noise.frequency = 0.005
	cov_noise.seed = 123
	cov_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	cov_noise.fractal_octaves = 4

	# 大尺度遮罩
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

			# R：雲型 — 量化到四段
			var type_raw := type_noise.get_noise_2d(fx, fy) * 0.5 + 0.5
			var type_quantized := floorf(type_raw * 4.0) / 4.0
			var type_frac := fmod(type_raw * 4.0, 1.0) * 0.2
			var type_val := clampf(type_quantized + type_frac, 0.0, 1.0)

			# B：覆蓋率 — 雙層混合 + 雙重 smoothstep
			var cov_detail := cov_noise.get_noise_2d(fx, fy) * 0.5 + 0.5
			var mask := mask_noise.get_noise_2d(fx, fy) * 0.5 + 0.5
			var cov_raw := mask * 0.6 + cov_detail * 0.4
			var t := clampf((cov_raw - 0.3) / 0.3, 0.0, 1.0)
			var cov_val := t * t * (3.0 - 2.0 * t)
			t = clampf(cov_val, 0.0, 1.0)
			cov_val = t * t * (3.0 - 2.0 * t)

			# G：降水
			var precip_val := (precip_noise.get_noise_2d(fx, fy) * 0.5 + 0.5) * cov_val

			img.set_pixel(x, y, Color(type_val, precip_val, cov_val))

	generated_weather_map = ImageTexture.create_from_image(img)
