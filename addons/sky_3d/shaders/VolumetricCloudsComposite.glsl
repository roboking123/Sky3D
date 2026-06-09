// Copyright (c) 2023-2025 Cory Petkovsek and Contributors
// 體積雲合成 compute shader
// 把八面體預計算貼圖合成到螢幕色彩緩衝
// 支援時序累積、大氣散射、深度遮擋

#[compute]
#version 450

#define PI 3.141592653589793
#define MAX_VIEWS 2

// Godot 4.6 SceneData 結構（從 CloudsInc.comp 參考）
struct SceneData {
	mat4 projection_matrix;
	mat4 inv_projection_matrix;
	mat3x4 inv_view_matrix;
	mat3x4 view_matrix;

	mat4 projection_matrix_view[MAX_VIEWS];
	mat4 inv_projection_matrix_view[MAX_VIEWS];
	vec4 eye_offset[MAX_VIEWS];

	mat4 main_cam_inv_view_matrix;

	vec2 viewport_size;
	vec2 screen_pixel_size;

	vec4 directional_penumbra_shadow_kernel[32];
	vec4 directional_soft_shadow_kernel[32];
	vec4 penumbra_shadow_kernel[32];
	vec4 soft_shadow_kernel[32];

	vec2 shadow_atlas_pixel_size;
	vec2 directional_shadow_pixel_size;

	float radiance_pixel_size;
	float radiance_border_size;
	vec2 reflection_atlas_border_size;

	uint directional_light_count;
	float dual_paraboloid_side;
	float z_far;
	float z_near;

	float roughness_limiter_amount;
	float roughness_limiter_limit;
	float opaque_prepass_threshold;
	uint flags;

	mat3 radiance_inverse_xform;

	vec4 ambient_light_color_energy;

	float ambient_color_sky_mix;
	float fog_density;
	float fog_height;
	float fog_height_density;

	float fog_depth_curve;
	float fog_depth_begin;
	float fog_depth_end;
	float fog_sun_scatter;

	vec3 fog_light_color;
	float fog_aerial_perspective;

	float time;
	float taa_frame_count;
	vec2 taa_jitter;

	float emissive_exposure_normalization;
	float IBL_exposure_normalization;
	uint camera_visible_layers;
	float pass_alpha_multiplier;
};

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// binding 0: 螢幕色彩（讀寫）
layout(rgba16f, binding = 0) uniform image2D screen_image;

// binding 1: 深度
layout(binding = 1) uniform sampler2D depth_image;

// binding 2-3: 八面體雲貼圖（blend_from / blend_to）
layout(binding = 2) uniform sampler2D blend_from_texture;
layout(binding = 3) uniform sampler2D blend_to_texture;

// binding 4: 通用資料
layout(binding = 4) uniform GenericDataBuffer {
	vec2 screen_size;          // 0-1
	float blend_amount;        // 2
	float is_accumulation_a;   // 3
	vec3 sun_direction;        // 4-6
	float atmospheric_density; // 7
	vec3 moon_direction;       // 8-10
	float blur_power;          // 11
	vec2 color_correction;     // 12-13
	float blur_quality;        // 14
	float accumulation_decay;  // 15
	vec3 atmosphere_color;     // 16-18
	float _pad0;               // 19
	// 剩餘 12 floats 保留
	vec4 _reserved[3];         // 20-31
} params;

// binding 5-8: 時序累積貼圖
layout(rgba16f, binding = 5) uniform image2D accum_color_a;
layout(rgba16f, binding = 6) uniform image2D accum_color_b;
layout(rgba16f, binding = 7) uniform image2D accum_data_a;
layout(rgba16f, binding = 8) uniform image2D accum_data_b;

// binding 9: 場景資料
layout(binding = 9, std140) uniform SceneDataBlock {
	SceneData data;
	SceneData prev_data;
} scene_data_block;


// ============================================================================
// 八面體映射（跟 clayjohn 一致）
// ============================================================================

vec2 oct_wrap(vec2 v) {
	vec2 signVal;
	signVal.x = v.x >= 0.0 ? 1.0 : -1.0;
	signVal.y = v.y >= 0.0 ? 1.0 : -1.0;
	return (1.0 - abs(v.yx)) * signVal;
}

vec2 vec3_to_oct(vec3 e) {
	e /= abs(e.x) + abs(e.y) + abs(e.z);
	e.xy = e.z >= 0.0 ? e.xy : oct_wrap(e.xy);
	vec2 n;
	n.y = e.y * 0.5 + 0.5;
	n.x = e.x * 0.5 + n.y;
	n.y = e.x * -0.5 + n.y;
	return n;
}

// ============================================================================
// 色調映射
// ============================================================================

vec3 apply_photo_tonemap(vec3 color, float exposure, float level) {
	color.rgb *= exposure;
	return mix(color.rgb, 1.0 - exp(-color.rgb), level);
}

// ============================================================================
// 大氣散射（簡化版 Rayleigh + Mie，從 SSC2 借鑑）
// ============================================================================

float henyey_greenstein(float cos_theta, float g) {
	const float k = 0.0795774715459; // 1 / (4*PI)
	return k * (1.0 - g * g) / pow(1.0 + g * g - 2.0 * g * cos_theta, 1.5);
}

vec3 sample_atmospherics(vec3 ray_dir, vec3 sun_dir, float distance_traveled, float density, float atmo_density) {
	if (atmo_density <= 0.001 || distance_traveled <= 0.0) return vec3(0.0);

	const vec3 RayleighCoef = vec3(5.5e-6, 13.0e-6, 22.4e-6);
	const float MieCoef = 21e-6;
	const float MieG = 0.758;

	float mu = dot(ray_dir, sun_dir);
	float pRlh = 3.0 / (16.0 * PI) * (1.0 + mu * mu);
	float gg = MieG * MieG;
	float pMie = 3.0 / (8.0 * PI) * ((1.0 - gg) * (mu * mu + 1.0)) / (pow(1.0 + gg - 2.0 * mu * MieG, 1.5) * (2.0 + gg));

	float optical_depth = distance_traveled * atmo_density * 0.0001;
	vec3 scatter = (pRlh * RayleighCoef + pMie * MieCoef) * optical_depth * (1.0 - density);
	return scatter * params.atmosphere_color * 22.0;
}

// ============================================================================
// 主程式
// ============================================================================

void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.screen_size);

	if (uv.x >= size.x || uv.y >= size.y) {
		return;
	}

	vec2 screen_uv = (vec2(uv) + 0.5) / vec2(size);

	// 讀取深度
	float depth_raw = texture(depth_image, screen_uv).r;

	// 深度線性化
	vec4 view = scene_data_block.data.inv_projection_matrix * vec4(screen_uv * 2.0 - 1.0, depth_raw, 1.0);
	view.xyz /= view.w;
	float linear_depth = length(view.xyz);
	bool is_sky = linear_depth >= scene_data_block.data.z_far * 0.99;
	if (is_sky) {
		linear_depth *= 100.0;
	}

	// 重建世界空間視線方向
	vec4 clip_pos = vec4(screen_uv * 2.0 - 1.0, 0.0, 1.0);
	vec4 view_pos = scene_data_block.data.inv_projection_matrix * clip_pos;
	view_pos.xyz /= view_pos.w;
	vec3 rd_view = normalize(view_pos.xyz);
	vec3 rd_world = mat3(scene_data_block.data.main_cam_inv_view_matrix) * rd_view;
	vec3 ray_dir = normalize(rd_world);

	// 只渲染地平線以上
	if (ray_dir.y <= 0.0) {
		return;
	}

	// 八面體 UV（跟 compute shader 一致：xzy 交換）
	vec3 norm = ray_dir;
	norm.y = max(0.001, norm.y);
	norm = normalize(norm);
	vec2 oct_uv = vec3_to_oct(norm.xzy);

	// 取樣八面體貼圖並混合
	vec4 cloud_from = texture(blend_from_texture, oct_uv);
	vec4 cloud_to = texture(blend_to_texture, oct_uv);
	vec4 clouds = mix(cloud_from, cloud_to, params.blend_amount);

	// 色調映射
	clouds.rgb = apply_photo_tonemap(clouds.rgb, params.color_correction.y, params.color_correction.x);

	// 深度遮擋軟邊（SSC2 做法的簡化版）
	float cloud_distance = 6001500.0; // SKY_B_RADIUS - GROUND_RADIUS，雲底距離
	float depth_fade = 1.0;
	if (!is_sky && linear_depth < cloud_distance) {
		depth_fade = smoothstep(0.0, cloud_distance * 0.1, linear_depth);
		if (linear_depth < cloud_distance * 0.5) {
			depth_fade *= 0.0;
		}
	}

	float alpha = clamp(clouds.a * depth_fade, 0.0, 1.0);

	// 地平線淡出
	float horizon_fade = smoothstep(0.0, 0.05, ray_dir.y);
	alpha *= horizon_fade;

	// 時序重投影累積（SSC2 做法）
	vec4 current_cloud = vec4(clouds.rgb, alpha);
	vec4 accum_result = current_cloud;

	float decay = params.accumulation_decay;
	if (decay > 0.001) {
		// 重投影：用前一幀相機矩陣算出上一幀的螢幕位置
		vec3 world_pos = mat3(scene_data_block.data.main_cam_inv_view_matrix) * view.xyz
			+ scene_data_block.data.main_cam_inv_view_matrix[3].xyz;

		// 相機位移量
		vec3 cam_delta = scene_data_block.data.main_cam_inv_view_matrix[3].xyz
			- scene_data_block.prev_data.main_cam_inv_view_matrix[3].xyz;
		vec3 reprojected_pos = world_pos + cam_delta;

		// 投影到前一幀螢幕空間
		// 注意：Godot 4.6 的 view_matrix 是 mat3x4，乘 vec4 得到 vec3
		vec3 prev_view_pos = scene_data_block.prev_data.view_matrix * vec4(reprojected_pos, 1.0);
		vec4 prev_clip = scene_data_block.prev_data.projection_matrix * vec4(prev_view_pos, 1.0);
		vec2 prev_ndc = prev_clip.xy / prev_clip.w;
		vec2 prev_screen = prev_ndc * 0.5 + 0.5;
		vec2 reproject_offset = prev_screen - screen_uv;

		ivec2 prev_uv = uv + ivec2(reproject_offset * vec2(size));
		ivec2 clamped_prev = clamp(prev_uv, ivec2(0), size - ivec2(1));

		// 超出螢幕邊界或前一幀位置差太遠 → 不用累積，直接用當前值
		bool reject = (clamped_prev != prev_uv) || (prev_clip.z > 0.0);

		vec4 prev_color;
		if (params.is_accumulation_a > 0.5) {
			prev_color = reject ? current_cloud : imageLoad(accum_color_a, clamped_prev);
		} else {
			prev_color = reject ? current_cloud : imageLoad(accum_color_b, clamped_prev);
		}

		accum_result = prev_color * decay + current_cloud * (1.0 - decay);
	}

	// 寫入累積緩衝（乒乓交替）
	if (params.is_accumulation_a > 0.5) {
		imageStore(accum_color_b, uv, accum_result);
	} else {
		imageStore(accum_color_a, uv, accum_result);
	}

	// 大氣散射
	vec3 atmo = sample_atmospherics(ray_dir, params.sun_direction, linear_depth, accum_result.a, params.atmospheric_density);

	// 合成到螢幕
	vec4 screen_color = imageLoad(screen_image, uv);
	vec3 final_color = mix(screen_color.rgb, accum_result.rgb, accum_result.a);
	final_color += atmo;

	imageStore(screen_image, uv, vec4(final_color, screen_color.a));
}
