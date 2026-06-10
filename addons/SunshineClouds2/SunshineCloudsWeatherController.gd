@tool
extends Node
class_name SunshineCloudsWeatherController

## 天氣狀態機（Weather Controller）
##
## 在預設天氣型態（晴朗／多雲／陰天／暴風／魚鱗雲／散積雲／雨天）之間
## 平滑過渡 SSC2 的覆蓋率、密度、大氣濁度、噪聲尺度與天氣圖演化速度，
## 並可自動循環漫遊。
##
## 純外掛節點：只寫 clouds_resource 的公開屬性，不碰 SSC2 源碼；
## 可與 CloudSkyAmbientSync 並存（兩者管的欄位不重疊）。

enum WeatherType { CLEAR, PARTLY_CLOUDY, OVERCAST, STORM, CIRROCUMULUS, SCATTERED_CUMULUS, RAIN }

## 要驅動的 SSC2 雲驅動器（取它身上的 clouds_resource）
@export var clouds_driver: SunshineCloudsDriverGD

## 目前天氣型態：執行中改變會平滑過渡；編輯器裡改變會立即套用（快速預覽）
@export var 目前天氣: WeatherType = WeatherType.PARTLY_CLOUDY:
	set(value):
		if value == 目前天氣:
			return
		目前天氣 = value
		# 編輯器：一次性立即套用方便預覽，不走每幀過渡（避免搶走 Inspector 調參權）。
		# is_inside_tree 擋掉場景載入時的屬性還原，免得一開檔就改寫雲資源
		if Engine.is_editor_hint():
			if is_inside_tree():
				apply_immediately()
			return
		_開始過渡()

## 過渡秒數：從目前狀態漸變到目標型態所需時間
@export_range(1.0, 600.0) var 過渡秒數: float = 45.0

## 自動循環：依隨機間隔在型態之間漫遊
@export var 自動循環: bool = false

## 自動循環的最短／最長間隔（秒）
@export_range(30.0, 3600.0) var 循環最短間隔秒: float = 180.0
@export_range(30.0, 3600.0) var 循環最長間隔秒: float = 480.0

## 閃電啟用：暴風天氣時在雲層內隨機閃放高強度點光（雲內透光 + 短暫照亮場景）
@export_subgroup("Lightning")
@export var 閃電啟用: bool = true
## 閃電間隔（秒）：暴風期間兩次閃電之間的隨機範圍
@export_range(1.0, 120.0) var 閃電最短間隔秒: float = 4.0
@export_range(1.0, 120.0) var 閃電最長間隔秒: float = 14.0
## 閃電強度（點光能量峰值）
@export_range(1.0, 200.0) var 閃電強度: float = 40.0
## 閃電影響半徑（公尺）
@export_range(1000.0, 100000.0) var 閃電範圍_m: float = 24000.0
## 閃電色（冷白偏藍）
@export var 閃電顏色: Color = Color(0.85, 0.88, 1.0, 1.0)
## 同時照亮場景：閃電點光也作為真實場景光源（地面跟著閃）
@export var 閃電照亮場景: bool = true

# 每個型態的目標參數：覆蓋率 / 密度 / 大氣濁度 / 天氣圖演化速度 / 雲種偏置 / 三層噪聲尺度（公尺）。
# PARTLY_CLOUDY 取 demo 調好的基準值，掛上節點預設不改變現有視覺。
# 噪聲尺度控制雲胞大小：魚鱗雲=小胞滿天、散積雲=大胞孤立；既有四型固定 demo 基準尺度（100000/60000/20000）不變。
# RAIN = 複製 STORM 再調暗（密度與濁度拉高，形狀語言相同）。
# type_bias 只在雲資源的 cloud_type_variation > 0 時有視覺效果。
# 注意：coverage 是「大噪聲×天氣圖×高度梯度」乘積的門檻，乘積值域上限約 0.45，
# 所以有效範圍約 0.58（近乎無雲）~ 1.0（蓋滿），不是線性的天空覆蓋比例。
# 魚鱗雲 0.84 / 散積雲 0.76 由 CPU 離線重現 shader 數學掃描而得（存在率約 62% / 28%）。
# TODO（未來項目）：根治＝shader 端鏈式 remap 把 coverage 線性化（Schneider 慣例）；
# 會位移所有既有視覺、四種天氣基準需整批重調，動工前先凍結一份現役視覺快照
# floor_m / ceiling_m：雲層底/頂高度（公尺）。多雲＝使用者基準、暴風/雨天需高層給雲塔，維持 1500/16000。
# 陰天＝低雲毯壓到 8000 頂（與多雲拉開差距）；魚鱗雲＝高雲族（卷積雲 5~12km）抬到 6000~14000；散積雲＝低雲族，頂壓到 9000。
# 魚鱗雲 evolve 壓極低 + md_scale 取 12000：高空卷積雲穩定少變形，並降低時域閃爍的高頻侵蝕源。
# wind_mult：驅動器四層風速的倍率（只在執行期套用，編輯器不動 driver）。
# 閃爍量測（demo/tools/flicker_bench.gd）實證雲緣閃爍與風速近線性（全速 σ9.2／半速 σ5.1／凍結 σ1.6），
# 魚鱗雲 0.25 一石二鳥：高空卷積雲視覺上本就近乎靜止，同時把閃爍壓向機制地板
const PRESETS: Dictionary = {
	WeatherType.CLEAR:             {"coverage": 0.60, "density": 0.10, "atmo": 0.25, "evolve": 0.002, "type_bias": -0.4, "xl_scale": 100000.0, "lg_scale": 60000.0, "md_scale": 20000.0, "floor_m": 1500.0, "ceiling_m": 16000.0, "wind_mult": 1.0},
	WeatherType.PARTLY_CLOUDY:     {"coverage": 0.874, "density": 0.14, "atmo": 0.503, "evolve": 0.004, "type_bias": 0.0, "xl_scale": 100000.0, "lg_scale": 60000.0, "md_scale": 20000.0, "floor_m": 1500.0, "ceiling_m": 16000.0, "wind_mult": 1.0},
	WeatherType.OVERCAST:          {"coverage": 0.96, "density": 0.30, "atmo": 0.65, "evolve": 0.006, "type_bias": -0.6, "xl_scale": 100000.0, "lg_scale": 60000.0, "md_scale": 20000.0, "floor_m": 1500.0, "ceiling_m": 8000.0, "wind_mult": 1.0},
	WeatherType.STORM:             {"coverage": 1.0, "density": 0.70, "atmo": 0.90, "evolve": 0.012, "type_bias": 0.7, "xl_scale": 100000.0, "lg_scale": 60000.0, "md_scale": 20000.0, "floor_m": 1500.0, "ceiling_m": 16000.0, "wind_mult": 1.0},
	WeatherType.CIRROCUMULUS:      {"coverage": 0.84, "density": 0.10, "atmo": 0.30, "evolve": 0.0005, "type_bias": -0.5, "xl_scale": 100000.0, "lg_scale": 20000.0, "md_scale": 12000.0, "floor_m": 6000.0, "ceiling_m": 14000.0, "wind_mult": 0.25},
	WeatherType.SCATTERED_CUMULUS: {"coverage": 0.76, "density": 0.30, "atmo": 0.35, "evolve": 0.003, "type_bias": 0.45, "xl_scale": 140000.0, "lg_scale": 70000.0, "md_scale": 20000.0, "floor_m": 1500.0, "ceiling_m": 9000.0, "wind_mult": 0.7},
	WeatherType.RAIN:              {"coverage": 1.0, "density": 1.60, "atmo": 1.10, "evolve": 0.012, "type_bias": 0.7, "xl_scale": 100000.0, "lg_scale": 60000.0, "md_scale": 20000.0, "floor_m": 1500.0, "ceiling_m": 16000.0, "wind_mult": 1.0},
}

var _過渡中: bool = false
var _過渡計時: float = 0.0
var _起點覆蓋率: float = 0.0
var _起點密度: float = 0.0
var _起點濁度: float = 0.0
var _起點演化速度: float = 0.0
var _起點雲種偏置: float = 0.0
var _起點特大尺度: float = 0.0
var _起點大尺度: float = 0.0
var _起點中尺度: float = 0.0
var _起點雲底_m: float = 0.0
var _起點雲頂_m: float = 0.0
var _循環倒數: float = 0.0

# 風速倍率狀態：基準風速懶捕捉一次（之後不重抓，避免倍率複利漂移）
var _目前風速倍率: float = 1.0
var _起點風速倍率: float = 1.0
var _基準風速: Array[float] = []

# 閃電狀態
var _閃電燈: OmniLight3D = null
var _閃電燈已註冊: bool = false
var _閃電倒數: float = 0.0
var _脈衝佇列: int = 0
var _脈衝間隔計時: float = 0.0


func _ready() -> void:
	_重置循環倒數()
	# 啟動時套用目前天氣的風速倍率：場景存檔時若停在非預設天氣（例如魚鱗雲），
	# 不補套會卡在 1.0 全速；且再按同天氣快捷鍵因「值未變」不會觸發 setter
	if not Engine.is_editor_hint():
		var preset: Dictionary = PRESETS[目前天氣]
		_套用風速倍率(preset["wind_mult"])


func _process(delta: float) -> void:
	# 編輯器裡不跑每幀過渡／閃電／自動循環（避免搶 Inspector 調參權）；
	# 下拉切換的即時預覽由「目前天氣」setter 一次性套用
	if Engine.is_editor_hint():
		return
	var res: SunshineCloudsGD = _取得雲資源()
	if res == null:
		return

	if 自動循環 and not _過渡中:
		_循環倒數 -= delta
		if _循環倒數 <= 0.0:
			_重置循環倒數()
			set_weather(_隨機下一個型態())

	if _過渡中:
		_過渡計時 += delta
		var t: float = clampf(_過渡計時 / maxf(過渡秒數, 0.001), 0.0, 1.0)
		# 平滑進出，避免起訖瞬間的速度跳變
		t = smoothstep(0.0, 1.0, t)
		var preset: Dictionary = PRESETS[目前天氣]
		res.clouds_coverage = lerpf(_起點覆蓋率, preset["coverage"], t)
		res.clouds_density = lerpf(_起點密度, preset["density"], t)
		res.atmospheric_density = lerpf(_起點濁度, preset["atmo"], t)
		res.weather_evolution_speed = lerpf(_起點演化速度, preset["evolve"], t)
		res.cloud_type_bias = lerpf(_起點雲種偏置, preset["type_bias"], t)
		res.extra_large_noise_scale = lerpf(_起點特大尺度, preset["xl_scale"], t)
		res.large_noise_scale = lerpf(_起點大尺度, preset["lg_scale"], t)
		res.medium_noise_scale = lerpf(_起點中尺度, preset["md_scale"], t)
		res.cloud_floor = lerpf(_起點雲底_m, preset["floor_m"], t)
		res.cloud_ceiling = lerpf(_起點雲頂_m, preset["ceiling_m"], t)
		_套用風速倍率(lerpf(_起點風速倍率, preset["wind_mult"], t))
		if t >= 1.0:
			_過渡中 = false

	_更新閃電(delta)


## 公開 API：切換天氣（等同改「目前天氣」，會走平滑過渡）
func set_weather(type: int) -> void:
	目前天氣 = type as WeatherType


## 公開 API：立刻套用目前型態，不做過渡
func apply_immediately() -> void:
	var res: SunshineCloudsGD = _取得雲資源()
	if res == null:
		return
	var preset: Dictionary = PRESETS[目前天氣]
	res.clouds_coverage = preset["coverage"]
	res.clouds_density = preset["density"]
	res.atmospheric_density = preset["atmo"]
	res.weather_evolution_speed = preset["evolve"]
	res.cloud_type_bias = preset["type_bias"]
	res.extra_large_noise_scale = preset["xl_scale"]
	res.large_noise_scale = preset["lg_scale"]
	res.medium_noise_scale = preset["md_scale"]
	res.cloud_floor = preset["floor_m"]
	res.cloud_ceiling = preset["ceiling_m"]
	_套用風速倍率(preset["wind_mult"])
	_過渡中 = false


## 公開 API：是否正在過渡中（給 UI／demo 顯示狀態用）
func is_transitioning() -> bool:
	return _過渡中


## 公開 API：立刻觸發一道閃電（不限天氣型態，給劇情腳本用）
func trigger_lightning() -> void:
	if not is_inside_tree():
		return
	var res: SunshineCloudsGD = _取得雲資源()
	if res == null or Engine.is_editor_hint():
		return
	_確保閃電燈()
	_脈衝佇列 = randi_range(1, 3)
	_脈衝間隔計時 = 0.0
	_重新定位閃電(res)


# 閃電燈具生成與向驅動器註冊（懶初始化；範圍/顏色每次同步，執行中調參數即時生效）
func _確保閃電燈() -> void:
	if _閃電燈 == null:
		_閃電燈 = OmniLight3D.new()
		_閃電燈.name = "_LightningLight"
		_閃電燈.light_energy = 0.0
		_閃電燈.shadow_enabled = false
		add_child(_閃電燈)
	_閃電燈.omni_range = 閃電範圍_m
	_閃電燈.light_color = 閃電顏色
	_閃電燈.visible = 閃電照亮場景
	if not _閃電燈已註冊 and clouds_driver != null:
		clouds_driver.tracked_point_lights.append(_閃電燈)
		_閃電燈已註冊 = true
		# 立即重建燈光資料：不依賴 driver 的 update_continuously 尺寸檢查
		clouds_driver.retrieve_texture_data()


func _重新定位閃電(res: SunshineCloudsGD) -> void:
	var center: Vector3 = Vector3.ZERO
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam != null:
		center = cam.global_position
	var 高度_m: float = lerpf(res.cloud_floor, res.cloud_ceiling, randf_range(0.2, 0.5))
	var 方位_rad: float = randf() * TAU
	var 水平距離_m: float = randf_range(3000.0, 15000.0)
	_閃電燈.global_position = Vector3(
		center.x + cos(方位_rad) * 水平距離_m,
		高度_m,
		center.z + sin(方位_rad) * 水平距離_m)


func _更新閃電(delta: float) -> void:
	var 暴風中: bool = 目前天氣 == WeatherType.STORM and 閃電啟用
	if 暴風中:
		_確保閃電燈()
		_閃電倒數 -= delta
		if _閃電倒數 <= 0.0:
			_閃電倒數 = randf_range(閃電最短間隔秒, maxf(閃電最長間隔秒, 閃電最短間隔秒))
			trigger_lightning()
	if _閃電燈 == null:
		return
	# 先衰減、再發新脈衝：剛設定的峰值不會同幀被削掉。
	# 指數形式 exp(-k·delta) 與幀率無關（線性形式在低幀率會一幀歸零）
	if _閃電燈.light_energy > 0.0:
		_閃電燈.light_energy *= exp(-16.0 * delta)
		if _閃電燈.light_energy < 0.05:
			_閃電燈.light_energy = 0.0
	# 脈衝佇列：一道閃電 1~3 次連閃
	if _脈衝佇列 > 0:
		_脈衝間隔計時 -= delta
		if _脈衝間隔計時 <= 0.0:
			_脈衝佇列 -= 1
			_脈衝間隔計時 = randf_range(0.05, 0.14)
			_閃電燈.light_energy = 閃電強度 * randf_range(0.6, 1.0)


# 把天氣風速倍率套到驅動器的四層風速。
# 編輯器一律不動 driver：倍率後的值若被存進場景，下次載入會把它誤當基準（複利漂移）
func _套用風速倍率(mult: float) -> void:
	_目前風速倍率 = mult
	if Engine.is_editor_hint() or clouds_driver == null:
		return
	if _基準風速.is_empty():
		_基準風速 = [
			clouds_driver.extra_large_structures_wind_speed,
			clouds_driver.large_structures_wind_speed,
			clouds_driver.medium_structures_wind_speed,
			clouds_driver.small_structures_wind_speed,
		]
	clouds_driver.extra_large_structures_wind_speed = _基準風速[0] * mult
	clouds_driver.large_structures_wind_speed = _基準風速[1] * mult
	clouds_driver.medium_structures_wind_speed = _基準風速[2] * mult
	clouds_driver.small_structures_wind_speed = _基準風速[3] * mult


func _exit_tree() -> void:
	# 從驅動器移除閃電燈，避免殘留懸空引用（is_instance_valid 擋已釋放的 driver）
	if _閃電燈已註冊 and is_instance_valid(clouds_driver) and _閃電燈 != null:
		clouds_driver.tracked_point_lights.erase(_閃電燈)
		_閃電燈已註冊 = false
	# 還原驅動器基準風速（控制器移除後不留下倍率污染）
	if not _基準風速.is_empty() and is_instance_valid(clouds_driver):
		clouds_driver.extra_large_structures_wind_speed = _基準風速[0]
		clouds_driver.large_structures_wind_speed = _基準風速[1]
		clouds_driver.medium_structures_wind_speed = _基準風速[2]
		clouds_driver.small_structures_wind_speed = _基準風速[3]


func _取得雲資源() -> SunshineCloudsGD:
	if clouds_driver == null:
		return null
	return clouds_driver.clouds_resource


func _開始過渡() -> void:
	if Engine.is_editor_hint():
		return
	var res: SunshineCloudsGD = _取得雲資源()
	if res == null:
		return
	_起點覆蓋率 = res.clouds_coverage
	_起點密度 = res.clouds_density
	_起點濁度 = res.atmospheric_density
	_起點演化速度 = res.weather_evolution_speed
	_起點雲種偏置 = res.cloud_type_bias
	_起點特大尺度 = res.extra_large_noise_scale
	_起點大尺度 = res.large_noise_scale
	_起點中尺度 = res.medium_noise_scale
	_起點雲底_m = res.cloud_floor
	_起點雲頂_m = res.cloud_ceiling
	_起點風速倍率 = _目前風速倍率
	_過渡計時 = 0.0
	_過渡中 = true
	# 進入暴風：第一道閃電等到過渡過半再打（天空夠陰才打雷，視覺不突兀）
	if 目前天氣 == WeatherType.STORM:
		_閃電倒數 = 過渡秒數 * 0.6 + randf_range(閃電最短間隔秒, maxf(閃電最長間隔秒, 閃電最短間隔秒))


func _隨機下一個型態() -> int:
	var candidates: Array[int] = []
	for type: int in PRESETS.keys():
		if type != 目前天氣:
			candidates.append(type)
	return candidates[randi() % candidates.size()]


func _重置循環倒數() -> void:
	_循環倒數 = randf_range(循環最短間隔秒, maxf(循環最長間隔秒, 循環最短間隔秒))
