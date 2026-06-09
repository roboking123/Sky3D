// Copyright (c) 2023-2025 Cory Petkovsek and Contributors
// 體積雲合成 compute shader
// 把八面體預計算貼圖合成到螢幕色彩緩衝
// 支援時序累積、大氣散射、深度遮擋

#[compute]
#version 450

#define PI 3.141592653589793
#define MAX_VIEWS 2

// 不用 Godot SceneData UBO（.glsl 不支援 include，手寫容易跑偏）
// 改為在 GenericDataBuffer 裡傳必要的相機矩陣

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// binding 0: 螢幕色彩（讀寫）
layout(rgba16f, binding = 0) uniform image2D screen_image;

// binding 1: 深度
layout(binding = 1) uniform sampler2D depth_image;

// binding 2-3: 八面體雲貼圖（blend_from / blend_to）
layout(binding = 2) uniform sampler2D blend_from_texture;
layout(binding = 3) uniform sampler2D blend_to_texture;

// binding 4: 通用資料
layout(binding = 4, std140) uniform GenericDataBuffer {
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
	float resolution_scale;    // 19 — 1=原生, 2=半, 4=四分之一, 8=八分之一
	// 剩餘 12 floats 保留
	vec4 _reserved[3];         // 20-31
} params;

// binding 5-8: 時序累積貼圖
layout(rgba16f, binding = 5) uniform image2D accum_color_a;
layout(rgba16f, binding = 6) uniform image2D accum_color_b;
layout(rgba16f, binding = 7) uniform image2D accum_data_a;
layout(rgba16f, binding = 8) uniform image2D accum_data_b;

// binding 9: 相機矩陣（手動傳入，取代 SceneData UBO）
layout(binding = 9, std140) uniform CameraData {
	mat4 inv_projection;         // 當前幀
	mat4 inv_view;               // 當前幀（main_cam_inv_view_matrix）
	mat4 prev_view;              // 前一幀 view matrix
	mat4 prev_projection;        // 前一幀 projection matrix
	float z_far;
	float z_near;
	float _cpad0;
	float _cpad1;
} camera;


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
// Bicubic 徑向模糊（SSC2 移植）
// ============================================================================

float w0_bicubic(float a) { return (1.0/6.0)*(a*(a*(-a + 3.0) - 3.0) + 1.0); }
float w1_bicubic(float a) { return (1.0/6.0)*(a*a*(3.0*a - 6.0) + 4.0); }
float w2_bicubic(float a) { return (1.0/6.0)*(a*(a*(-3.0*a + 3.0) + 3.0) + 1.0); }
float w3_bicubic(float a) { return (1.0/6.0)*(a*a*a); }
float g0_bicubic(float a) { return w0_bicubic(a) + w1_bicubic(a); }
float g1_bicubic(float a) { return w2_bicubic(a) + w3_bicubic(a); }
float h0_bicubic(float a) { return -1.0 + w1_bicubic(a) / (w0_bicubic(a) + w1_bicubic(a)); }
float h1_bicubic(float a) { return 1.0 + w3_bicubic(a) / (w2_bicubic(a) + w3_bicubic(a)); }

vec4 bicubic_sample(ivec2 center, vec2 frac_uv, ivec2 img_size) {
	float g0x = g0_bicubic(frac_uv.x);
	float g1x = g1_bicubic(frac_uv.x);

	ivec2 p0 = clamp(center + ivec2(int(h0_bicubic(frac_uv.x)), int(h0_bicubic(frac_uv.y))), ivec2(0), img_size - ivec2(1));
	ivec2 p1 = clamp(center + ivec2(int(h1_bicubic(frac_uv.x)), int(h0_bicubic(frac_uv.y))), ivec2(0), img_size - ivec2(1));
	ivec2 p2 = clamp(center + ivec2(int(h0_bicubic(frac_uv.x)), int(h1_bicubic(frac_uv.y))), ivec2(0), img_size - ivec2(1));
	ivec2 p3 = clamp(center + ivec2(int(h1_bicubic(frac_uv.x)), int(h1_bicubic(frac_uv.y))), ivec2(0), img_size - ivec2(1));

	// 用 accum buffer 做 bicubic 取樣
	float gy0 = g0_bicubic(frac_uv.y);
	float gy1 = g1_bicubic(frac_uv.y);
	return gy0 * (g0x * imageLoad(accum_color_a, p0) + g1x * imageLoad(accum_color_a, p1))
	     + gy1 * (g0x * imageLoad(accum_color_a, p2) + g1x * imageLoad(accum_color_a, p3));
}

vec4 radial_blur(vec4 start_color, ivec2 center_uv, ivec2 img_size, float blur_h, float blur_v, float quality) {
	float pi2 = 6.28318530718;
	float count = 1.0;
	vec4 result = start_color;
	for (float d = 0.0; d < pi2; d += pi2 / (quality * 4.0)) {
		for (float i = 1.0 / quality; i <= 1.0; i += 1.0 / quality) {
			ivec2 offset = ivec2(int(cos(d) * blur_h * i), int(sin(d) * blur_v * i));
			ivec2 sample_uv = clamp(center_uv + offset, ivec2(0), img_size - ivec2(1));
			result += imageLoad(accum_color_a, sample_uv);
			count += 1.0;
		}
	}
	return result / count;
}

// ============================================================================
// 主程式
// ============================================================================

void main() {
	ivec2 size = ivec2(params.screen_size);
	int res_scale_i = max(1, int(params.resolution_scale));
	ivec2 work_size = (size + ivec2(res_scale_i - 1)) / ivec2(res_scale_i);
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);

	if (uv.x >= work_size.x || uv.y >= work_size.y) {
		return;
	}

	// 低解析度 UV 映射到全解析度中心
	vec2 screen_uv = (vec2(uv) * float(res_scale_i) + 0.5 * float(res_scale_i)) / vec2(size);

	// 讀取深度
	float depth_raw = texture(depth_image, screen_uv).r;

	// 深度線性化
	vec4 view = camera.inv_projection * vec4(screen_uv * 2.0 - 1.0, depth_raw, 1.0);
	view.xyz /= view.w;
	float linear_depth = length(view.xyz);
	bool is_sky = linear_depth >= camera.z_far * 0.99;
	if (is_sky) {
		linear_depth *= 100.0;
	}

	// 重建世界空間視線方向
	vec4 clip_pos = vec4(screen_uv * 2.0 - 1.0, 0.0, 1.0);
	vec4 view_pos = camera.inv_projection * clip_pos;
	view_pos.xyz /= view_pos.w;
	vec3 rd_view = normalize(view_pos.xyz);
	vec3 rd_world = mat3(camera.inv_view) * rd_view;
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
		vec3 world_pos = mat3(camera.inv_view) * view.xyz
			+ camera.inv_view[3].xyz;

		// 相機位移量
		vec3 cam_delta = camera.inv_view[3].xyz
			- camera.inv_view[3].xyz;
		vec3 reprojected_pos = world_pos + cam_delta;

		// 投影到前一幀螢幕空間
		// 注意：Godot 4.6 的 view_matrix 是 mat3x4，乘 vec4 得到 vec3
		// prev_view 是前一幀的 view matrix (mat4)，直接乘
		vec4 prev_view_pos4 = camera.prev_view * vec4(reprojected_pos, 1.0);
		vec4 prev_clip = camera.prev_projection * prev_view_pos4;
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

	// Bicubic 徑向模糊（SSC2 做法）
	if (params.blur_power > 0.0 && params.blur_quality > 0.0) {
		float blur_h = params.blur_power;
		float blur_v = params.blur_power;
		accum_result = radial_blur(accum_result, uv, size, blur_h, blur_v, params.blur_quality);
	}

	// 大氣散射
	vec3 atmo = sample_atmospherics(ray_dir, params.sun_direction, linear_depth, accum_result.a, params.atmospheric_density);

	// 合成到螢幕（支援可變解析度：每個 thread 寫 NxN 像素）
	int res_scale = max(1, int(params.resolution_scale));
	vec3 blended_cloud = accum_result.rgb + atmo;
	float final_alpha = accum_result.a;

	for (int dy = 0; dy < res_scale; dy++) {
		for (int dx = 0; dx < res_scale; dx++) {
			ivec2 write_uv = uv * res_scale + ivec2(dx, dy);
			if (write_uv.x >= size.x || write_uv.y >= size.y) continue;
			vec4 screen_color = imageLoad(screen_image, write_uv);
			vec3 final_color = mix(screen_color.rgb, blended_cloud, final_alpha);
			imageStore(screen_image, write_uv, vec4(final_color, screen_color.a));
		}
	}
}
