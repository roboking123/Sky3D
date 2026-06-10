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

# 每個型態的目標參數：覆蓋率 / 密度 / 大氣濁度 / 天氣圖演化速度。
# PARTLY_CLOUDY 取 demo 調好的基準值，掛上節點預設不改變現有視覺
const PRESETS: Dictionary = {
	WeatherType.CLEAR:         {"coverage": 0.60, "density": 0.10, "atmo": 0.25, "evolve": 0.002},
	WeatherType.PARTLY_CLOUDY: {"coverage": 0.862, "density": 0.14, "atmo": 0.40, "evolve": 0.004},
	WeatherType.OVERCAST:      {"coverage": 0.96, "density": 0.30, "atmo": 0.65, "evolve": 0.006},
	WeatherType.STORM:         {"coverage": 1.0, "density": 0.70, "atmo": 0.90, "evolve": 0.012},
}

var _過渡中: bool = false
var _過渡計時: float = 0.0
var _起點覆蓋率: float = 0.0
var _起點密度: float = 0.0
var _起點濁度: float = 0.0
var _起點演化速度: float = 0.0
var _循環倒數: float = 0.0


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
		if t >= 1.0:
			_過渡中 = false


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
	_過渡中 = false


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
	_過渡計時 = 0.0
	_過渡中 = true


func _隨機下一個型態() -> int:
	var candidates: Array[int] = []
	for type: int in PRESETS.keys():
		if type != 目前天氣:
			candidates.append(type)
	return candidates[randi() % candidates.size()]


func _重置循環倒數() -> void:
	_循環倒數 = randf_range(循環最短間隔秒, maxf(循環最長間隔秒, 循環最短間隔秒))
