@tool
extends EditorScript

# 生成體積雲天氣圖
# Script > Run 即可執行

const SIZE = 512
const OUTPUT_PATH = "res://addons/sky_3d/assets/resources/weather_generated.tres"

func _run() -> void:
	print("開始生成天氣圖...")

	# R 通道：雲型（0=層雲, 0.5=積雲, 1.0=積雨雲）
	# 用低頻噪音產生大範圍的雲型變化
	var type_noise := FastNoiseLite.new()
	type_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	type_noise.frequency = 0.003
	type_noise.seed = 42

	# B 通道：覆蓋率（哪裡有雲、哪裡晴天）
	# 用中頻噪音產生自然的雲/無雲分界
	var coverage_noise := FastNoiseLite.new()
	coverage_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	coverage_noise.frequency = 0.006
	coverage_noise.seed = 123
	coverage_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	coverage_noise.fractal_octaves = 3

	# 額外一層大尺度噪音，讓覆蓋率有大片晴天和大片雲區
	var coverage_large := FastNoiseLite.new()
	coverage_large.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	coverage_large.frequency = 0.002
	coverage_large.seed = 789

	# G 通道：降水/密度（較暗的雲更厚）
	var precip_noise := FastNoiseLite.new()
	precip_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	precip_noise.frequency = 0.005
	precip_noise.seed = 456

	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGB8)

	for y in SIZE:
		for x in SIZE:
			var fx := float(x)
			var fy := float(y)

			# R：雲型，完整 0~1 範圍
			var type_val := type_noise.get_noise_2d(fx, fy) * 0.5 + 0.5
			# 稍微偏向積雲（0.3~0.7 居多，但保留極端值）
			type_val = clampf(type_val * 0.8 + 0.1, 0.0, 1.0)

			# B：覆蓋率
			var cov_detail := coverage_noise.get_noise_2d(fx, fy) * 0.5 + 0.5
			var cov_large := coverage_large.get_noise_2d(fx, fy) * 0.5 + 0.5
			# 大尺度控制整體分布，細節噪音加變化
			var cov_val := cov_large * 0.7 + cov_detail * 0.3
			# 增加對比度：讓晴天更晴、多雲更雲
			cov_val = smoothstep(0.25, 0.75, cov_val)

			# G：降水，跟覆蓋率相關但有獨立變化
			var precip_val := precip_noise.get_noise_2d(fx, fy) * 0.5 + 0.5
			precip_val *= cov_val

			img.set_pixel(x, y, Color(type_val, precip_val, cov_val))

	# 存成 ImageTexture
	var tex := ImageTexture.create_from_image(img)
	var err := ResourceSaver.save(tex, OUTPUT_PATH)
	if err == OK:
		print("天氣圖已儲存到: ", OUTPUT_PATH)
	else:
		print("儲存失敗: ", err)

	print("完成！")


func smoothstep(edge0: float, edge1: float, x: float) -> float:
	var t := clampf((x - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
