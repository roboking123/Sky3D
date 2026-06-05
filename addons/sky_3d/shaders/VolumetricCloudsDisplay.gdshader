// 顯示 compute shader 算好的體積雲貼圖
shader_type spatial;
render_mode blend_mix, cull_disabled, unshaded, depth_draw_never;

uniform sampler2D blend_from_texture : filter_linear, repeat_disable;
uniform sampler2D blend_to_texture : filter_linear, repeat_disable;
uniform float blend_amount : hint_range(0.0, 1.0) = 0.0;
uniform vec2 color_correction = vec2(0.0, 1.0);
uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_linear_mipmap;

#include "res://addons/sky_3d/shaders/Common.gdshaderinc"

// clayjohn 的八面體映射反向函數（方向 → UV）
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

varying mat4 camera_matrix;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
	camera_matrix = INV_VIEW_MATRIX;
}

void fragment() {
	float depth_raw = textureLod(DEPTH_TEXTURE, SCREEN_UV, 0.0).r;

	// MSAA 修正
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

	// 重建視線方向
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth_raw);
	vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view.xyz /= view.w;
	vec4 world_view = camera_matrix * view;
	world_view.xyz /= world_view.w;
	world_view.xyz -= (camera_matrix * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 rd = normalize(world_view.xyz);

	// 只顯示地平線以上
	vec3 norm = rd;
	norm.y = max(0.0, norm.y);
	norm = normalize(norm);

	// 跟 clayjohn 一致的映射：先 xzy 交換再轉八面體 UV
	vec2 oct_uv = vec3_to_oct(norm.xzy);

	// 混合兩幀
	vec4 cloud_from = textureLod(blend_from_texture, oct_uv, 0.0);
	vec4 cloud_to = textureLod(blend_to_texture, oct_uv, 0.0);
	vec4 clouds = mix(cloud_from, cloud_to, blend_amount);

	clouds.rgb = apply_photo_tonemap(clouds.rgb, color_correction.y, color_correction.x);

	// 地平線淡出
	float horizon_fade = smoothstep(0.0, 0.05, rd.y);
	ALBEDO = clouds.rgb;
	ALPHA = clouds.a * depth_fade * horizon_fade;
}
