#[compute]
#version 450

// 工作組大小 8x8
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// 輸出貼圖
layout(rgba16f, set = 0, binding = 0) uniform restrict writeonly image2D current_image;

// 噪音貼圖
layout(set = 1, binding = 0) uniform sampler3D large_scale_noise;
layout(set = 1, binding = 1) uniform sampler3D small_scale_noise;
layout(set = 1, binding = 2) uniform sampler2D weather_noise;

// Push constants（128 bytes 上限 = 32 floats）
layout(push_constant, std430) uniform Params {
	vec2 texture_size;
	vec2 update_position;

	vec2 cloud_pos;
	vec2 detailed_pos;

	vec2 weather_pos;
	float coverage;
	float cloud_type;

	vec3 sun_direction;
	float density;

	vec3 moon_direction;
	float absorption;

	vec3 cloud_day_color;
	float detail_strength;

	vec3 cloud_horizon_color;
	float time;

	vec3 cloud_night_color;
	float use_weather;
} params;

// 球體常數
const float GROUND_RADIUS = 6000000.0;
const float SKY_B_RADIUS = 6001500.0;
const float SKY_T_RADIUS = 6006000.0;
const float PI = 3.141592;

// 噪音尺度
const float BASE_SCALE = 0.00008;
const float DETAIL_SCALE = 0.001;
const float WEATHER_SCALE = 0.0002;

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

// ============================================================================
// 高度梯度
// ============================================================================

vec4 mix_gradients(float cloud_t) {
	// x,y = 底部 smoothstep 邊界, z,w = 頂部 smoothstep 邊界
	const vec4 STRATUS = vec4(0.02, 0.06, 0.10, 0.13);          // 極薄扁平
	const vec4 STRATOCUMULUS = vec4(0.02, 0.15, 0.40, 0.55);    // 中等厚度
	const vec4 CUMULUS = vec4(0.01, 0.08, 0.70, 0.90);          // 蓬鬆高塔
	const vec4 CUMULONIMBUS = vec4(0.005, 0.03, 0.92, 1.0);     // 暴風雨巨塔，幾乎填滿雲層

	// 四段混合：0~0.33 層雲↔層積雲, 0.33~0.66 層積雲↔積雲, 0.66~1.0 積雲↔積雨雲
	float t = cloud_t * 3.0;
	if (t < 1.0) {
		return mix(STRATUS, STRATOCUMULUS, t);
	} else if (t < 2.0) {
		return mix(STRATOCUMULUS, CUMULUS, t - 1.0);
	} else {
		return mix(CUMULUS, CUMULONIMBUS, t - 2.0);
	}
}

float density_height_gradient(float height_frac, float cloud_t) {
	vec4 g = mix_gradients(cloud_t);
	return smoothstep(g.x, g.y, height_frac) - smoothstep(g.z, g.w, height_frac);
}

// ============================================================================
// 密度取樣
// ============================================================================

float sample_density(vec3 pip, vec3 weather, float mip) {
	vec3 p = pip;
	float height_fraction = get_height_fraction(length(p));

	// 雲底波浪：用大尺度噪音微調高度，讓凝結面不是完美平面
	float base_wave = textureLod(large_scale_noise, pip.xyz * BASE_SCALE * 0.5, 2.0).g;
	height_fraction += (base_wave - 0.5) * 0.08;
	height_fraction = clamp(height_fraction, 0.0, 1.0);

	p.xz += 20.0 * params.cloud_pos * 0.6;

	vec4 n = textureLod(large_scale_noise, p.xyz * BASE_SCALE, mip - 2.0);
	float fbm = n.g * 0.625 + n.b * 0.25 + n.a * 0.125;

	float g = density_height_gradient(height_fraction, weather.r);
	float base_cloud = remap(n.r, -(1.0 - fbm), 1.0, 0.0, 1.0);
	float weather_coverage = params.coverage * weather.b;
	base_cloud = remap(base_cloud * g, 1.0 - weather_coverage, 1.0, 0.0, 1.0);
	base_cloud *= weather_coverage;

	if (base_cloud <= 0.01) return 0.0;

	p.xz -= params.detailed_pos * 40.0;
	p.y -= params.time * 40.0;

	vec3 hn = textureLod(small_scale_noise, p * DETAIL_SCALE, mip).rgb;
	float hfbm = hn.r * 0.625 + hn.g * 0.25 + hn.b * 0.125;
	hfbm = mix(hfbm, 1.0 - hfbm, clamp(height_fraction * 4.0, 0.0, 1.0));
	base_cloud = remap(base_cloud, hfbm * params.detail_strength * height_fraction, 1.0, 0.0, 1.0);

	return pow(clamp(base_cloud, 0.0, 1.0), (1.0 - height_fraction) * 0.8 + 0.5);
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
// 光線步進
// ============================================================================

vec4 march(vec3 pos, vec3 end, vec3 dir, int depth) {
	const vec3 RANDOM_VECTORS[6] = {
		vec3(0.38051305, 0.92453449, -0.02111345),
		vec3(-0.50625799, -0.03590792, -0.86163418),
		vec3(-0.32509218, -0.94557439, 0.01428793),
		vec3(0.09026238, -0.27376545, 0.95755165),
		vec3(0.28128598, 0.42443639, -0.86065785),
		vec3(-0.16852403, 0.14748697, 0.97460106)
	};

	float ss = length(dir);
	dir = normalize(dir);
	vec3 p = pos + dir * hash(pos * 10.0) * ss;

	float t_dist = SKY_T_RADIUS - SKY_B_RADIUS;
	float lss = t_dist / 64.0;
	vec3 ldir = normalize(params.sun_direction);

	float T = 1.0;
	float alpha = 0.0;
	vec3 L = vec3(0.0);

	float costheta = dot(ldir, dir);
	float phase = max(
		max(henyey_greenstein(costheta, 0.6),
		    henyey_greenstein(costheta, 0.4 - 1.4 * ldir.y)),
		henyey_greenstein(costheta, -0.2)
	);

	// 日夜顏色
	float sun_h = params.sun_direction.y;
	float day_amt = smoothstep(-0.1, 0.3, sun_h);
	float night_amt = smoothstep(0.1, -0.5, sun_h);
	float horiz_amt = max(1.0 - day_amt - night_amt, 0.0);
	vec3 sun_color = params.cloud_day_color * day_amt + params.cloud_horizon_color * horiz_amt + params.cloud_night_color * night_amt;

	// 環境光
	vec3 ambient_top = sun_color * 0.15;
	vec3 ambient_bottom = sun_color * 0.08;

	// 天氣圖用光線方向取樣（不用世界座標，天空各方向均勻分布）
	vec2 weather_uv = vec3_to_oct(dir.xzy) + params.weather_pos;
	vec3 weather_sample;
	if (params.use_weather > 0.5) {
		weather_sample = texture(weather_noise, weather_uv).rgb;
	} else {
		weather_sample = vec3(params.cloud_type, 0.5, 1.0);
	}

	for (int i = 0; i < depth; i++) {
		p += dir * ss;
		float height_fraction = get_height_fraction(length(p));

		float t = sample_density(p, weather_sample, 0.0);
		float dt = exp(-params.density * t * ss);

		if (t > 0.0) {
			vec3 lp = p;
			float cd = 0.0;

			for (int j = 0; j < 6; j++) {
				lp += (ldir + RANDOM_VECTORS[j] * float(j)) * lss;
				cd += sample_density(lp, weather_sample, float(j));
			}

			// 遠距取樣
			lp = p + ldir * 18.0 * lss;
			float lh = get_height_fraction(length(lp));
			float lt = pow(sample_density(lp, weather_sample, 5.0), (1.0 - lh) * 0.8 + 0.5);
			cd += lt;

			// Beer-Lambert + 粉末效應
			float beers = exp(-params.density * cd * lss * 3.0);
			float powder = 1.0 - exp(-params.density * cd * lss * 3.0 * 2.0);
			float beers_total = 2.0 * beers * powder;

			vec3 ambient = mix(ambient_bottom, ambient_top, smoothstep(0.0, 1.0, height_fraction));
			float sun_factor = clamp(params.sun_direction.y + 0.3, 0.0, 1.0);
			alpha += (1.0 - dt) * (1.0 - alpha);
			vec3 radiance = (ambient + beers_total * sun_color * sun_factor * phase) * t;
			L += T * (radiance - radiance * dt) / max(0.0000001, t);
			T *= dt;
		}
	}

	return vec4(L, clamp(alpha, 0.0, 1.0));
}

// ============================================================================
// 主函數
// ============================================================================

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy) + ivec2(params.update_position);
	vec2 uv = vec2(pos) / params.texture_size;
	vec3 dir = oct_to_vec3(uv).xzy;

	vec4 col = vec4(0.0);
	if (dir.y > 0.0) {
		vec3 cam_pos = vec3(0.0, GROUND_RADIUS, 0.0);
		vec3 start = cam_pos + dir * intersect_sphere(cam_pos, dir, SKY_B_RADIUS);
		vec3 end_pos = cam_pos + dir * intersect_sphere(cam_pos, dir, SKY_T_RADIUS);
		float shell_dist = length(end_pos - start);
		vec3 raystep = dir * shell_dist / 128.0;
		col = march(start, end_pos, raystep, 128);
	}

	imageStore(current_image, pos, col);
}
