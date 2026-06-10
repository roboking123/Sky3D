extends SceneTree

## 雲閃爍量測工具（回歸測試用）。
## 用法：godot --path . --windowed --resolution 960x540 --script demo/tools/flicker_bench.gd
## 原理：固定鏡頭仰角 40° 看魚鱗雲，鎖 30fps，逐幀截圖統計每像素亮度的時域標準差。
## top5%σ ＝ 雲緣閃爍熱區指標（歷史基準：正常風速約 9、半速約 5、凍結雲場約 1.6）。
## 注意：各配置依序量測，雲場會隨風漂移，配置間比較需風速相同或凍結。
const CONFIGS: Array = [
	{"name": "目前demo設定(天氣系統風速)", "spd": []},
	{"name": "強制全速(140/100/40/12)   ", "spd": [140.0, 100.0, 40.0, 12.0]},
	{"name": "凍結雲場(機制噪聲地板)    ", "spd": [0.0, 0.0, 0.0, 0.0]},
]
const W: int = 320
const H: int = 180
const WARMUP: int = 110
const SAMPLES: int = 48

func _init() -> void:
	_main()

func _main() -> void:
	await process_frame
	Engine.max_fps = 30
	var packed: PackedScene = load("res://demo/Sky3DDemo.tscn")
	var scene: Node = packed.instantiate()
	root.add_child(scene)
	await process_frame
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	var cam: Camera3D = scene.get_node("CameraManager/Camera3D")
	cam.rotation.x = deg_to_rad(40.0)
	var wc: Node = scene.get_node("WeatherController")
	wc.set("目前天氣", 4)
	wc.call("apply_immediately")
	var driver: Node = scene.get_node("SunshineCloudsDriver")
	var res: Resource = driver.get("clouds_resource")
	res.set("temporal_responsiveness", 0.0)
	print("BENCH_BEGIN")
	for cfg: Dictionary in CONFIGS:
		var spd: Array = cfg["spd"]
		if spd.size() == 4:
			driver.set("extra_large_structures_wind_speed", spd[0])
			driver.set("large_structures_wind_speed", spd[1])
			driver.set("medium_structures_wind_speed", spd[2])
			driver.set("small_structures_wind_speed", spd[3])
		for i: int in WARMUP:
			await process_frame
		var n: int = W * H
		var sums: PackedFloat32Array = PackedFloat32Array()
		var sumsq: PackedFloat32Array = PackedFloat32Array()
		sums.resize(n)
		sumsq.resize(n)
		var t0: int = Time.get_ticks_msec()
		for f: int in SAMPLES:
			await process_frame
			var img: Image = root.get_viewport().get_texture().get_image()
			img.resize(W, H, Image.INTERPOLATE_BILINEAR)
			img.convert(Image.FORMAT_L8)
			var data: PackedByteArray = img.get_data()
			for i: int in n:
				var v: float = float(data[i])
				sums[i] += v
				sumsq[i] += v * v
		var fps: float = SAMPLES * 1000.0 / float(Time.get_ticks_msec() - t0)
		var sigmas: Array[float] = []
		var sum_sigma: float = 0.0
		for i: int in n:
			var mu: float = sums[i] / SAMPLES
			var var_i: float = maxf(sumsq[i] / SAMPLES - mu * mu, 0.0)
			var s: float = sqrt(var_i)
			sigmas.append(s)
			sum_sigma += s
		sigmas.sort()
		var p95: float = sigmas[int(n * 0.95)]
		var top5_sum: float = 0.0
		var top5_n: int = int(n * 0.05)
		for i: int in range(n - top5_n, n):
			top5_sum += sigmas[i]
		print("%s | 平均σ %.3f | p95σ %.3f | top5%%σ %.3f | fps %.1f" % [cfg["name"], sum_sigma / n, p95, top5_sum / top5_n, fps])
	print("BENCH_DONE")
	quit(0)
