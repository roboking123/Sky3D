// Copyright (c) 2023-2025 Cory Petkovsek and Contributors
// 體積雲八面體 Compute Shader
// 基底：clayjohn/godot-volumetric-cloud-demo-v2 (MIT)
// 高度梯度/curl noise/自適應步長/風切/AO：Bonkahe/SunshineClouds2 (MIT)
// 天氣圖/四雲種/雲底波浪/日夜顏色：原創

#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// === set 0: 輸出 ===
layout(rgba16f, set = 0, binding = 0) uniform restrict writeonly image2D current_image;

// === set 1: 紋理 ===
layout(set = 1, binding = 0) uniform sampler3D large_scale_noise;    // Perlin-Worley (clayjohn)
layout(set = 1, binding = 1) uniform sampler3D small_scale_noise;    // Worley detail (clayjohn)
layout(set = 1, binding = 2) uniform sampler2D weather_noise;        // 天氣圖 (程式化生成)
layout(set = 1, binding = 3) uniform sampler3D curl_noise;           // Curl noise (SSC2)
layout(set = 1, binding = 4) uniform sampler2D height_gradient;      // 高度梯度紋理 (SSC2)

// === set 2: 參數（uniform buffer 取代 push constant，突破 128 bytes 限制） ===
// 用 vec4 成員確保 std140 對齊，名稱只是語意標記
layout(set = 2, binding = 0, std140) uniform CloudParams {
	vec4 v0;  // texture_size.xy, update_position.xy
	vec4 v1;  // cloud_pos.xy, detail_pos.xy
	vec4 v2;  // weather_pos.xy, coverage, cloud_type
	vec4 v3;  // sun_direction.xyz, detail_strength
	vec4 v4;  // moon_direction.xyz, time
	vec4 v5;  // cloud_day_color.rgb, use_weather
	vec4 v6;  // cloud_horizon_color.rgb, curl_strength
	vec4 v7;  // cloud_night_color.rgb, wind_shear_power
	vec4 v8;  // wind_direction.xy, wind_shear_range, ao_strength
	vec4 v9;  // base_noise_scale, detail_noise_scale, weather_scale, curl_noise_scale
	vec4 v10; // march_steps, shadow_steps, density, absorption
} ub;

// 語意存取巨集
#define param_texture_size     ub.v0.xy
#define param_update_position  ub.v0.zw
#define param_cloud_pos        ub.v1.xy
#define param_detail_pos       ub.v1.zw
#define param_weather_pos      ub.v2.xy
#define param_coverage         ub.v2.z
#define param_cloud_type       ub.v2.w
#define param_sun_direction    ub.v3.xyz
#define param_detail_strength  ub.v3.w
#define param_moon_direction   ub.v4.xyz
#define param_time             ub.v4.w
#define param_cloud_day_color  ub.v5.xyz
#define param_use_weather      ub.v5.w
#define param_cloud_horizon_color ub.v6.xyz
#define param_curl_strength    ub.v6.w
#define param_cloud_night_color ub.v7.xyz
#define param_wind_shear_power ub.v7.w
#define param_wind_direction   ub.v8.xy
#define param_wind_shear_range ub.v8.z
#define param_ao_strength      ub.v8.w
#define param_base_noise_scale   ub.v9.x
#define param_detail_noise_scale ub.v9.y
#define param_weather_scale      ub.v9.z
#define param_curl_noise_scale   ub.v9.w
#define param_march_steps      ub.v10.x
#define param_shadow_steps     ub.v10.y
#define param_density          ub.v10.z
#define param_absorption       ub.v10.w

// === set 3: 光源資料（SSC2 做法） ===
struct DirLight {
	vec4 direction; // xyz = 方向, w = 陰影步數
	vec4 color;     // rgb = 顏色, a = 強度
};

struct PtLight {
	vec4 position; // xyz = 位置, w = 半徑
	vec4 color;    // rgb = 顏色, a = 強度
};

layout(set = 3, binding = 0, std140) uniform LightsBuffer {
	DirLight dir_lights[4];
	PtLight pt_lights[16];
	float dir_light_count;
	float pt_light_count;
	float _lpad0;
	float _lpad1;
} lights;

// ============================================================================
// 常數
// ============================================================================

const float GROUND_RADIUS = 6000000.0;
const float SKY_B_RADIUS = 6001500.0;
const float SKY_T_RADIUS = 6006000.0;
const float PI = 3.141592;

// ============================================================================
// 工具函數
// ============================================================================

float remap(float value, float old_min, float old_max, float new_min, float new_max) {
	return new_min + (((value - old_min) / (old_max - old_min)) * (new_max - new_min));
}

float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float henyey_greenstein(float cos_theta, float g) {
	const float k = 0.0795774715459;
	return k * (1.0 - g * g) / (pow(1.0 + g * g - 2.0 * g * cos_theta, 1.5));
}

float intersect_sphere(vec3 pos, vec3 dir, float r) {
	float a = dot(dir, dir);
	float b = 2.0 * dot(dir, pos);
	float c = dot(pos, pos) - (r * r);
	float d = sqrt((b * b) - 4.0 * a * c);
	float p1 = -b - d;
	float p2 = -b + d;
	return max(p1, p2) / (2.0 * a);
}

float get_height_fraction(float altitude) {
	return clamp((altitude - SKY_B_RADIUS) / (SKY_T_RADIUS - SKY_B_RADIUS), 0.0, 1.0);
}

// SSC2 的二次緩出（風切用）
float quadratic_in(float t) {
	return t * t;
}

// ============================================================================
// 高度梯度（雙軌：紋理優先，硬編碼備用）
// ============================================================================

// 硬編碼梯度（四雲種，保留作為備用）
vec4 mix_gradients_hardcoded(float cloud_t) {
	const vec4 STRATUS        = vec4(0.02, 0.06, 0.10, 0.13);
	const vec4 STRATOCUMULUS   = vec4(0.02, 0.15, 0.40, 0.55);
	const vec4 CUMULUS         = vec4(0.01, 0.08, 0.70, 0.90);
	const vec4 CUMULONIMBUS    = vec4(0.005, 0.03, 0.92, 1.0);

	float t = cloud_t * 3.0;
	if (t < 1.0) {
		return mix(STRATUS, STRATOCUMULUS, t);
	} else if (t < 2.0) {
		return mix(STRATOCUMULUS, CUMULUS, t - 1.0);
	} else {
		return mix(CUMULUS, CUMULONIMBUS, t - 2.0);
	}
}

// 紋理梯度（SSC2 做法：用高度 fraction 去取樣 1D 紋理的 RGBA）
// R = 大尺度形狀衰減, G = 小尺度細節衰減, B = 覆蓋率衰減, A = curl 強度衰減
vec4 sample_height_gradient(float height_frac) {
	return texture(height_gradient, vec2(height_frac, 0.5));
}

float density_height_gradient(float height_frac, float cloud_t) {
	// 主路徑：用紋理梯度
	vec4 grad = sample_height_gradient(height_frac);
	// grad.r 控制大尺度形狀
	float shape = grad.r;

	// 同時用硬編碼梯度做 smoothstep 邊界（四雲種保留）
	vec4 g = mix_gradients_hardcoded(cloud_t);
	float hard_grad = smoothstep(g.x, g.y, height_frac) - smoothstep(g.z, g.w, height_frac);

	// 混合：紋理梯度 × 硬編碼梯度
	return shape * hard_grad;
}

// ============================================================================
// 密度取樣（升級版：加入 curl noise、風切、紋理梯度）
// ============================================================================

float sample_density(vec3 pip, vec3 weather, float mip, bool is_ambient) {
	vec3 p = pip;
	float height_fraction = get_height_fraction(length(p));

	// 雲底波浪（原創：打破完美凝結面）
	float base_wave = textureLod(large_scale_noise, pip.xyz * param_base_noise_scale * 0.5, 2.0).g;
	height_fraction += (base_wave - 0.5) * 0.08;
	height_fraction = clamp(height_fraction, 0.0, 1.0);

	// 紋理梯度取樣
	vec4 grad_sample = sample_height_gradient(height_fraction);
	float edge_fade = min(smoothstep(0.0, 0.1, height_fraction), smoothstep(1.0, 0.9, height_fraction));

	// 風切效果（SSC2）：低處的雲被風吹偏
	if (param_wind_shear_power > 0.0) {
		float shear_factor = quadratic_in(1.0 - clamp(height_fraction / max(param_wind_shear_range, 0.01), 0.0, 1.0));
		p += vec3(param_wind_direction.x, 0.0, param_wind_direction.y) * param_wind_shear_power * shear_factor;
	}

	// Curl noise 位置偏移（SSC2）：雲邊緣捲曲變形
	if (!is_ambient && param_curl_strength > 0.0 && mip < 1.0) {
		float curl_height = grad_sample.a; // 紋理梯度 A 通道控制 curl 強度
		if (curl_height > 0.0) {
			vec3 curl = textureLod(curl_noise, p * param_curl_noise_scale, 0.0).xyz * 2.0 - 1.0;
			curl *= vec3(1.0, 0.2, 1.0); // 垂直方向抑制
			p += curl * param_curl_strength * curl_height;
		}
	}

	// 基底風偏移
	p.xz += 20.0 * param_cloud_pos * 0.6;

	// 取樣基底噪音（clayjohn Perlin-Worley）
	vec4 n = textureLod(large_scale_noise, p.xyz * param_base_noise_scale, mip - 2.0);
	float fbm = n.g * 0.625 + n.b * 0.25 + n.a * 0.125;

	// 高度梯度 + 覆蓋率
	float g = density_height_gradient(height_fraction, weather.r);
	float base_cloud = remap(n.r, -(1.0 - fbm), 1.0, 0.0, 1.0);
	float weather_coverage = param_coverage * weather.b * grad_sample.b; // 紋理 B 通道加權覆蓋率
	base_cloud = remap(base_cloud * g, 1.0 - weather_coverage, 1.0, 0.0, 1.0);
	base_cloud *= weather_coverage;

	if (base_cloud <= 0.01) return 0.0;

	// 細節風偏移
	p.xz -= param_detail_pos * 40.0;
	p.y -= param_time * 40.0;

	// 細節侵蝕（clayjohn Worley）
	vec3 hn = textureLod(small_scale_noise, p * param_detail_noise_scale, mip).rgb;
	float hfbm = hn.r * 0.625 + hn.g * 0.25 + hn.b * 0.125;
	hfbm = mix(hfbm, 1.0 - hfbm, clamp(height_fraction * 4.0, 0.0, 1.0));
	// 紋理 G 通道控制細節強度
	float detail_weight = param_detail_strength * height_fraction * grad_sample.g;
	base_cloud = remap(base_cloud, hfbm * detail_weight, 1.0, 0.0, 1.0);

	return pow(clamp(base_cloud, 0.0, 1.0), (1.0 - height_fraction) * 0.8 + 0.5) * edge_fade;
}

// ============================================================================
// AO 取樣（SSC2：雲上方隨機位置取密度）
// ============================================================================

float sample_ao(vec3 world_pos, vec3 weather, float ao_range) {
	vec3 sample_pos = world_pos;
	sample_pos.y += ao_range * 0.5;
	// 用 hash 產生偽隨機偏移
	sample_pos.y += ao_range * (hash(world_pos.xzy) * 2.0 - 1.0);
	sample_pos.x += ao_range * (hash(world_pos.zyx) * 2.0 - 1.0);
	sample_pos.z += ao_range * (hash(world_pos.yxz) * 2.0 - 1.0);
	return sample_density(sample_pos, weather, 1.0, true);
}

// ============================================================================
// 八面體映射
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

vec3 oct_to_vec3(vec2 e) {
	vec3 n;
	n.x = (e.x - e.y);
	n.y = (e.x + e.y) - 1.0;
	n.z = 1.0 - abs(n.x) - abs(n.y);
	n.xy = n.z >= 0.0 ? n.xy : oct_wrap(n.xy);
	return normalize(n);
}

// ============================================================================
// 光線步進（升級版：自適應步長 + AO + 多光源準備）
// ============================================================================

vec4 march(vec3 pos, vec3 end_pos, vec3 dir, int max_steps) {
	const vec3 RANDOM_VECTORS[6] = {
		vec3(0.38051305, 0.92453449, -0.02111345),
		vec3(-0.50625799, -0.03590792, -0.86163418),
		vec3(-0.32509218, -0.94557439, 0.01428793),
		vec3(0.09026238, -0.27376545, 0.95755165),
		vec3(0.28128598, 0.42443639, -0.86065785),
		vec3(-0.16852403, 0.14748697, 0.97460106)
	};

	float shell_dist = length(end_pos - pos);
	float base_step = shell_dist / float(max_steps);
	dir = normalize(dir);

	// 抖動起始位置
	vec3 p = pos + dir * hash(pos * 10.0) * base_step;

	float t_dist = SKY_T_RADIUS - SKY_B_RADIUS;
	float lss = t_dist / 64.0;
	int shadow_step_count = int(param_shadow_steps);
	int num_dir_lights = int(lights.dir_light_count);

	float T = 1.0;
	float alpha = 0.0;
	vec3 L = vec3(0.0);
	float total_ao = 0.0;
	float ao_samples = 0.0;

	// 預計算每個方向光的相位函數和顏色
	vec3 light_dirs[4];
	float light_phases[4];
	vec3 light_colors[4];
	float light_sun_factors[4];

	// 日夜顏色（用主光源 = 第一個方向光）
	vec3 primary_dir = normalize(lights.dir_lights[0].direction.xyz);
	float sun_h = primary_dir.y;
	float day_amt = smoothstep(-0.1, 0.3, sun_h);
	float night_amt = smoothstep(0.1, -0.5, sun_h);
	float horiz_amt = max(1.0 - day_amt - night_amt, 0.0);
	vec3 base_color = param_cloud_day_color * day_amt
	               + param_cloud_horizon_color * horiz_amt
	               + param_cloud_night_color * night_amt;

	for (int li = 0; li < num_dir_lights && li < 4; li++) {
		light_dirs[li] = normalize(lights.dir_lights[li].direction.xyz);
		float ct = dot(light_dirs[li], dir);
		light_phases[li] = max(
			max(henyey_greenstein(ct, 0.6),
			    henyey_greenstein(ct, 0.4 - 1.4 * light_dirs[li].y)),
			henyey_greenstein(ct, -0.2)
		);
		float up_weight = smoothstep(-0.03, 0.07, light_dirs[li].y);
		light_colors[li] = lights.dir_lights[li].color.rgb * lights.dir_lights[li].color.a * up_weight;
		light_sun_factors[li] = clamp(light_dirs[li].y + 0.3, 0.0, 1.0);
	}

	vec3 ambient_top = base_color * 0.15;
	vec3 ambient_bottom = base_color * 0.08;

	// 天氣圖取樣
	vec2 weather_uv = vec3_to_oct(dir.xzy) + param_weather_pos;
	vec3 weather_sample;
	if (param_use_weather > 0.5) {
		weather_sample = texture(weather_noise, weather_uv).rgb;
	} else {
		weather_sample = vec3(param_cloud_type, 0.5, 1.0);
	}

	// 自適應步長變數（SSC2 做法）
	float current_step = base_step;
	float traveled = 0.0;

	for (int i = 0; i < max_steps; i++) {
		p += dir * current_step;
		traveled += current_step;
		if (traveled > shell_dist) break;

		float height_fraction = get_height_fraction(length(p));

		float t = sample_density(p, weather_sample, 0.0, false);
		float dt = exp(-param_density * t * current_step);

		if (t > 0.0) {
			// 自適應步長：密度高時步長縮短（SSC2 做法）
			current_step = mix(base_step * 0.5, base_step, 1.0 - pow(t, 0.1));

			// 多光源光照（SSC2 做法：每個方向光獨立步進）
			vec3 total_light = vec3(0.0);
			for (int li = 0; li < num_dir_lights && li < 4; li++) {
				vec3 lp = p;
				float cd = 0.0;
				int steps_this_light = min(shadow_step_count, int(lights.dir_lights[li].direction.w));

				for (int j = 0; j < steps_this_light; j++) {
					lp += (light_dirs[li] + RANDOM_VECTORS[j % 6] * float(j)) * lss;
					cd += sample_density(lp, weather_sample, float(j), true);
				}

				// 遠距取樣
				lp = p + light_dirs[li] * 18.0 * lss;
				float lh = get_height_fraction(length(lp));
				float lt = pow(sample_density(lp, weather_sample, 5.0, true), (1.0 - lh) * 0.8 + 0.5);
				cd += lt;

				// Beer-Lambert + 粉末效應
				float beers = exp(-param_density * cd * lss * 3.0);
				float powder = 1.0 - exp(-param_density * cd * lss * 3.0 * 2.0);
				float beers_total = 2.0 * beers * powder;

				total_light += beers_total * light_colors[li] * light_sun_factors[li] * light_phases[li];
			}

			// AO 取樣（SSC2）
			if (param_ao_strength > 0.0) {
				total_ao += sample_ao(p, weather_sample, base_step * 2.0);
				ao_samples += 1.0;
			}

			vec3 ambient = mix(ambient_bottom, ambient_top, smoothstep(0.0, 1.0, height_fraction));
			alpha += (1.0 - dt) * (1.0 - alpha);
			vec3 radiance = (ambient + total_light) * t;
			L += T * (radiance - radiance * dt) / max(0.0000001, t);
			T *= dt;
		} else {
			// 空白區域恢復大步長
			current_step = base_step;
		}

		if (alpha >= 0.99) break;
	}

	// 套用 AO 暗化
	if (param_ao_strength > 0.0 && ao_samples > 0.0) {
		float ao = clamp(total_ao / ao_samples, 0.0, 1.0);
		L = mix(L, L * (1.0 - ao), param_ao_strength);
	}

	return vec4(L, clamp(alpha, 0.0, 1.0));
}

// ============================================================================
// 主函數
// ============================================================================

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy) + ivec2(param_update_position);
	vec2 uv = vec2(pos) / param_texture_size;
	vec3 dir = oct_to_vec3(uv).xzy;

	vec4 col = vec4(0.0);
	if (dir.y > 0.0) {
		vec3 cam_pos = vec3(0.0, GROUND_RADIUS, 0.0);
		vec3 start = cam_pos + dir * intersect_sphere(cam_pos, dir, SKY_B_RADIUS);
		vec3 end_pos = cam_pos + dir * intersect_sphere(cam_pos, dir, SKY_T_RADIUS);
		int steps = int(param_march_steps);
		col = march(start, end_pos, dir, steps);
	}

	imageStore(current_image, pos, col);
}
