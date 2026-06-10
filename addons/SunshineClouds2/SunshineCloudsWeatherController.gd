@tool
extends Node
class_name SunshineCloudsWeatherController

## 天氣狀態機（Weather Controller）
##
## 在預設天氣型態（晴朗／多雲／陰天／暴風）之間平滑過渡 SSC2 的
## 覆蓋率、密度、大氣濁度與天氣圖演化速度，並可自動循環漫遊。
##
## 純外掛節點：只寫 clouds_resource 的公開屬性，不碰 SSC2 源碼；
## 可與 CloudSkyAmbientSync 並存（兩者管的欄位不重疊）。

enum WeatherType { CLEAR, PARTLY_CLOUDY, OVERCAST, STORM }

## 要驅動的 SSC2 雲驅動器（取它身上的 clouds_resource）
@export var clouds_driver: SunshineCloudsDriverGD

## 目前天氣型態：執行中改變就會開始平滑過渡
@export var 目前天氣: WeatherType = WeatherType.PARTLY_CLOUDY:
	set(value):
		if value == 目前天氣:
			return
		目前天氣 = value
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

# 每個型態的目標參數：覆蓋率 / 密度 / 大氣濁度 / 天氣圖演化速度 / 雲種偏置。
# PARTLY_CLOUDY 取 demo 調好的基準值，掛上節點預設不改變現有視覺。
# type_bias 只在雲資源的 cloud_type_variation > 0 時有視覺效果
const PRESETS: Dictionary = {
	WeatherType.CLEAR:         {"coverage": 0.60, "density": 0.10, "atmo": 0.25, "evolve": 0.002, "type_bias": -0.4},
	WeatherType.PARTLY_CLOUDY: {"coverage": 0.874, "density": 0.14, "atmo": 0.503, "evolve": 0.004, "type_bias": 0.0},
	WeatherType.OVERCAST:      {"coverage": 0.96, "density": 0.30, "atmo": 0.65, "evolve": 0.006, "type_bias": -0.6},
	WeatherType.STORM:         {"coverage": 1.0, "density": 0.70, "atmo": 0.90, "evolve": 0.012, "type_bias": 0.7},
}

var _過渡中: bool = false
var _過渡計時: float = 0.0
var _起點覆蓋率: float = 0.0
var _起點密度: float = 0.0
var _起點濁度: float = 0.0
var _起點演化速度: float = 0.0
var _起點雲種偏置: float = 0.0
var _循環倒數: float = 0.0

# 閃電狀態
var _閃電燈: OmniLight3D = null
var _閃電燈已註冊: bool = false
var _閃電倒數: float = 0.0
var _脈衝佇列: int = 0
var _脈衝間隔計時: float = 0.0


func _ready() -> void:
	_重置循環倒數()


func _process(delta: float) -> void:
	# 編輯器裡不動手，把參數控制權完整留給 Inspector
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


func _exit_tree() -> void:
	# 從驅動器移除閃電燈，避免殘留懸空引用（is_instance_valid 擋已釋放的 driver）
	if _閃電燈已註冊 and is_instance_valid(clouds_driver) and _閃電燈 != null:
		clouds_driver.tracked_point_lights.erase(_閃電燈)
		_閃電燈已註冊 = false


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
