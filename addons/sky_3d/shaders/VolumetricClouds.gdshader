// Copyright (c) 2023-2025 Cory Petkovsek and Contributors
// Volumetric Clouds
// 噪音取樣參考 clayjohn/godot-volumetric-cloud-demo-v2 (MIT)
// 層級 remap 參考 Bonkahe/SunshineClouds2 (MIT)

shader_type spatial;
render_mode blend_mix, cull_disabled, unshaded, depth_draw_never;

// ============================================================================
// UNIFORMS
// ============================================================================

uniform vec2 color_correction = vec2(0.0, 1.0);
uniform vec3 sun_direction = vec3(0.0, 0.5, 0.5);
uniform vec3 moon_direction = vec3(0.0, -0.5, 0.5);

// 密度
uniform float coverage : hint_range(0.0, 1.0) = 0.5;
uniform float cloud_type : hint_range(0.0, 1.0) = 0.5;
uniform float density_mult : hint_range(0.1, 5.0) = 1.0;
uniform float absorption : hint_range(0.01, 0.5) = 0.06;

// 噪音貼圖
uniform sampler3D base_noise_texture : filter_linear_mipmap, repeat_enable;
uniform sampler3D detail_noise_texture : filter_linear_mipmap, repeat_enable;
uniform float detail_strength : hint_range(0.0, 1.0) = 0.4;

// 天氣圖
uniform sampler2D weather_map : filter_linear_mipmap, repeat_enable;
uniform bool use_weather_map = false;

// 動畫
uniform vec2 cloud_pos = vec2(0.0);
uniform vec2 detail_pos = vec2(0.0);
uniform vec2 weather_pos = vec2(0.0);

// 品質
uniform int march_steps : hint_range(16, 128) = 32;
uniform int shadow_steps : hint_range(2, 16) = 4;

// 顏色
uniform vec4 cloud_day_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 cloud_horizon_color : source_color = vec4(1.0, 0.9, 0.8, 1.0);
uniform vec4 cloud_night_color : source_color = vec4(0.06, 0.08, 0.14, 1.0);

uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_linear_mipmap;

#include "res://addons/sky_3d/shaders/Common.gdshaderinc"

// ============================================================================
// 球體幾何常數（跟 clayjohn 一致）
// ============================================================================

const float GROUND_RADIUS = 6000000.0;
const float SKY_B_RADIUS = 6001500.0;
const float SKY_T_RADIUS = 6004000.0;

// clayjohn 的噪音取樣尺度
const float BASE_NOISE_SCALE = 0.00008;
const float DETAIL_NOISE_SCALE = 0.001;
const float WEATHER_SCALE = 0.00006;

// ============================================================================
// 工具函數
// ============================================================================

float remap(float value, float old_min, float old_max, float new_min, float new_max) {
	return new_min + (((value - old_min) / (old_max - old_min)) * (new_max - new_min));
}

float intersect_sphere(vec3 pos, vec3 dir, float r) {
	float a = dot(dir, dir);
	float b = 2.0 * dot(dir, pos);
	float c = dot(pos, pos) - (r * r);
	float d = sqrt((b * b) - 4.0 * a * c);
	float p = -b - d;
	float p2 = -b + d;
	return max(p, p2) / (2.0 * a);
}

float get_height_fraction(float altitude) {
	return clamp((altitude - SKY_B_RADIUS) / (SKY_T_RADIUS - SKY_B_RADIUS), 0.0, 1.0);
}

// ============================================================================
// 高度梯度
// ============================================================================

vec4 mix_gradients(float cloud_t) {
	const vec4 STRATUS = vec4(0.02, 0.05, 0.09, 0.11);
	const vec4 STRATOCUMULUS = vec4(0.02, 0.2, 0.48, 0.625);
	const vec4 CUMULUS = vec4(0.01, 0.0625, 0.78, 1.0);
	float stratus = 1.0 - clamp(cloud_t * 2.0, 0.0, 1.0);
	float stratocumulus = 1.0 - abs(cloud_t - 0.5) * 2.0;
	float cumulus = clamp(cloud_t - 0.5, 0.0, 1.0) * 2.0;
	return STRATUS * stratus + STRATOCUMULUS * stratocumulus + CUMULUS * cumulus;
}

float density_height_gradient(float height_frac, float cloud_t) {
	vec4 g = mix_gradients(cloud_t);
	return smoothstep(g.x, g.y, height_frac) - smoothstep(g.z, g.w, height_frac);
}

// ============================================================================
// 光照
// ============================================================================

float beer_lambert(float od) {
	return exp(-od);
}

// ============================================================================
// 密度取樣
// ============================================================================

float sample_density(vec3 pip, vec3 weather_sample, float mip) {
	vec3 p = pip;
	float height_fraction = get_height_fraction(length(p));

	// 基底風偏移
	p.xz += 20.0 * cloud_pos * 0.6;

	// 取樣基底噪音
	vec4 n = textureLod(base_noise_texture, p.xyz * BASE_NOISE_SCALE, mip - 2.0);
	float fbm = n.g * 0.625 + n.b * 0.25 + n.a * 0.125;

	// 高度梯度 + 覆蓋率
	float g = density_height_gradient(height_fraction, weather_sample.r);
	float base_cloud = remap(n.r, -(1.0 - fbm), 1.0, 0.0, 1.0);
	float weather_coverage = coverage * weather_sample.b;
	base_cloud = remap(base_cloud * g, 1.0 - weather_coverage, 1.0, 0.0, 1.0);
	base_cloud *= weather_coverage;

	if (base_cloud <= 0.01) return 0.0;

	// 細節風偏移
	p.xz -= detail_pos * 40.0;
	p.y -= TIME * 40.0;

	// 細節侵蝕
	vec3 hn = textureLod(detail_noise_texture, p * DETAIL_NOISE_SCALE, mip).rgb;
	float hfbm = hn.r * 0.625 + hn.g * 0.25 + hn.b * 0.125;
	hfbm = mix(hfbm, 1.0 - hfbm, clamp(height_fraction * 4.0, 0.0, 1.0));
	base_cloud = remap(base_cloud, hfbm * detail_strength * height_fraction, 1.0, 0.0, 1.0);

	return pow(clamp(base_cloud, 0.0, 1.0), (1.0 - height_fraction) * 0.8 + 0.5) * density_mult;
}

// ============================================================================
// 光線步進
// ============================================================================

vec4 march_clouds(vec3 dir, vec3 sun_dir, vec2 screen_uv) {
	if (dir.y <= 0.0) return vec4(0.0);

	vec3 cam_pos = vec3(0.0, GROUND_RADIUS, 0.0);
	float t_min = intersect_sphere(cam_pos, dir, SKY_B_RADIUS);
	float t_max = intersect_sphere(cam_pos, dir, SKY_T_RADIUS);
	if (t_min < 0.0 || t_max < 0.0 || t_min >= t_max) return vec4(0.0);

	float shell_dist = t_max - t_min;
	float step_size = shell_dist / float(march_steps);
	float t_dist = SKY_T_RADIUS - SKY_B_RADIUS;
	float light_step = t_dist / 64.0;
	vec3 ldir = normalize(sun_dir);

	// 抖動
	vec3 start_pos = cam_pos + dir * t_min;
	float hash_val = fract(dot(screen_uv, vec2(12.9898, 78.233)));
	hash_val = fract(hash_val * 43758.5453);
	vec3 p = start_pos + dir * hash_val * step_size;

	float transmittance = 1.0;
	float alpha = 0.0;
	vec3 light_accum = vec3(0.0);

	// 日夜顏色
	float sun_height = sun_dir.y;
	float day_amount = smoothstep(-0.1, 0.3, sun_height);
	float night_amount = smoothstep(0.1, -0.5, sun_height);
	float horizon_amount = max(1.0 - day_amount - night_amount, 0.0);
	vec3 col = cloud_day_color.rgb * day_amount + cloud_horizon_color.rgb * horizon_amount + cloud_night_color.rgb * night_amount;

	// Henyey-Greenstein 相位函數
	float cos_theta = dot(ldir, dir);
	float phase = max(
		max(
			(0.0795774715459 * (1.0 - 0.36) / pow(1.0 + 0.36 - 1.2 * cos_theta, 1.5)),
			(0.0795774715459 * (1.0 - 0.04) / pow(1.0 + 0.04 + 0.4 * cos_theta, 1.5))
		),
		(0.0795774715459 * (1.0 - 0.0196) / pow(1.0 + 0.0196 - 2.0 * (-0.14) * cos_theta, 1.5))
	);

	// 隨機光線取樣方向（clayjohn 做法）
	const vec3 RANDOM_VECTORS[6] = {
		vec3(0.38051305, 0.92453449, -0.02111345),
		vec3(-0.50625799, -0.03590792, -0.86163418),
		vec3(-0.32509218, -0.94557439, 0.01428793),
		vec3(0.09026238, -0.27376545, 0.95755165),
		vec3(0.28128598, 0.42443639, -0.86065785),
		vec3(-0.16852403, 0.14748697, 0.97460106)
	};

	for (int i = 0; i < march_steps; i++) {
		p += dir * step_size;
		float height_fraction = get_height_fraction(length(p));

		// 天氣圖取樣
		vec3 weather;
		if (use_weather_map) {
			weather = texture(weather_map, p.xz * WEATHER_SCALE + 0.5 + weather_pos).rgb;
		} else {
			weather = vec3(cloud_type, 0.5, 1.0);
		}

		float d = sample_density(p, weather, 0.0);
		float dt = exp(-absorption * d * step_size);

		if (d > 0.0) {
			// 光照光線
			vec3 lp = p;
			float cd = 0.0;
			for (int j = 0; j < shadow_steps; j++) {
				lp += (ldir + RANDOM_VECTORS[j] * float(j)) * light_step;
				float lheight = get_height_fraction(length(lp));
				vec3 lweather;
				if (use_weather_map) {
					lweather = texture(weather_map, lp.xz * WEATHER_SCALE + 0.5 + weather_pos).rgb;
				} else {
					lweather = vec3(cloud_type, 0.5, 1.0);
				}
				cd += sample_density(lp, lweather, float(j));
			}

			// Beer-Lambert + 粉末效應
			float beers = exp(-absorption * cd * light_step * 3.0);
			float powder = 1.0 - exp(-absorption * cd * light_step * 3.0 * 2.0);
			float beers_total = 2.0 * beers * powder;

			// 環境光（高處用天空色，低處用地面反射）
			float sun_factor = clamp(sun_dir.y + 0.3, 0.0, 1.0);
			vec3 ambient = col * 0.15;
			vec3 radiance = (ambient + beers_total * col * sun_factor * phase) * d;

			alpha += (1.0 - dt) * (1.0 - alpha);
			light_accum += transmittance * (radiance - radiance * dt) / max(0.0000001, d);
			transmittance *= dt;
		}

		if (alpha >= 0.99) break;
	}

	return vec4(light_accum, clamp(alpha, 0.0, 1.0));
}

// ============================================================================
// VERTEX / FRAGMENT
// ============================================================================

varying mat4 camera_matrix;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
	camera_matrix = INV_VIEW_MATRIX;
}

void fragment() {
	float depth_raw = textureLod(DEPTH_TEXTURE, SCREEN_UV, 0.0).r;

	vec2 texel = 1.0 / vec2(textureSize(DEPTH_TEXTURE, 0));
	float depth_l = textureLod(DEPTH_TEXTURE, SCREEN_UV + vec2(-texel.x, 0.0), 0.0).r;
	float depth_r = textureLod(DEPTH_TEXTURE, SCREEN_UV + vec2(texel.x, 0.0), 0.0).r;
	float depth_u = textureLod(DEPTH_TEXTURE, SCREEN_UV + vec2(0.0, texel.y), 0.0).r;
	float depth_d = textureLod(DEPTH_TEXTURE, SCREEN_UV + vec2(0.0, -texel.y), 0.0).r;
	float depth_max = max(depth_raw, max(max(depth_l, depth_r), max(depth_u, depth_d)));
	float depth_fade = smoothstep(0.0001, 0.0, depth_max);

	if (depth_fade < 0.00001) {
		discard;
	}

	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth_raw);
	vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view.xyz /= view.w;

	vec4 world_view = camera_matrix * view;
	world_view.xyz /= world_view.w;
	world_view.xyz -= (camera_matrix * vec4(0.0, 0.0, 0.0, 1.0)).xyz;

	vec3 rd = normalize(world_view.xyz);

	vec4 clouds = march_clouds(rd, sun_direction, SCREEN_UV);
	clouds.rgb = apply_photo_tonemap(clouds.rgb, color_correction.y, color_correction.x);

	ALBEDO = clouds.rgb;
	ALPHA = clouds.a * depth_fade;
}
