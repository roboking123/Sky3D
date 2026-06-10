@tool
extends Node
class_name CloudSkyAmbientSync

## 雲底天空色連動橋接（Cloud Sky Ambient Sync）
##
## 作用：把場景的環境光色（Sky3D 隨日夜算出來、寫進 WorldEnvironment.ambient_light_color
## 的那個顏色）即時餵給 SunshineClouds2 的雲底環境色（cloud_ambient_color），
## 讓雲的暗面／底部跟著天空一起變——白天冷藍、黃昏暖橘、夜晚暗藍。
##
## 設計：只讀寫雙方的「公開屬性」，不碰 Sky3D 或 SSC2 任何源碼。
## 來源端只依賴引擎原生的 WorldEnvironment，所以即使日後換掉 Sky3D，
## 只要場景的 ambient_light_color 有被驅動，這個橋接照樣能用。

## 環境光來源（指向 Sky3D 的 WorldEnvironment 節點）
@export var sky_environment: WorldEnvironment

## 要連動的 SSC2 雲驅動器（會取它身上的 clouds_resource）
@export var clouds_driver: SunshineCloudsDriverGD

## 連動強度：0 = 完全不連動（保留雲自身的固定底色），1 = 完全採用天空色
@export_range(0.0, 1.0) var 連動強度: float = 1.0

## 雲底色調：在天空色之上再乘一層，整體微調雲底偏暖／偏冷或壓暗
@export var 雲底色調: Color = Color(1.0, 1.0, 1.0, 1.0)

## 最低亮度：避免夜晚雲底全黑、看不見輪廓（取顏色的明度 v 下限）
@export_range(0.0, 1.0) var 最低亮度: float = 0.12

## 大氣色來源（指向 Sky3D 的 SkyDome 節點，用它的日／昏／夜色調算地平線色）
@export var sky_dome: SkyDome

## 大氣連動強度：把 Sky3D 地平線色餵給雲的大氣散射色（atmosphere_color），
## 讓遠景雲霧跟天空同一套色調。0 = 不連動（維持雲自身固定大氣色）
@export_range(0.0, 1.0) var 大氣連動強度: float = 0.0

## 大氣色調：在算出的地平線色之上再乘一層微調
@export var 大氣色調: Color = Color(1.0, 1.0, 1.0, 1.0)

# 第一次執行時記下雲資源原本的固定底色，當作連動強度<1 時的混合基準
var _原始雲底色: Color = Color(0.761, 0.784, 0.824, 1.0)
var _原始大氣色: Color = Color(1.0, 1.0, 1.0, 1.0)
var _已快取原始色: bool = false


func _process(_delta: float) -> void:
	# 只在實際執行時連動。編輯器裡不動手，把 cloud_ambient_color 的控制權
	# 完整還給 Inspector，避免 @tool 偷改使用者正在調的值又被存檔
	if Engine.is_editor_hint():
		return
	if sky_environment == null or sky_environment.environment == null:
		return
	if clouds_driver == null or clouds_driver.clouds_resource == null:
		return

	var res: SunshineCloudsGD = clouds_driver.clouds_resource

	if not _已快取原始色:
		_原始雲底色 = res.cloud_ambient_color
		_原始大氣色 = res.atmosphere_color
		_已快取原始色 = true

	# 取當前天空環境色，乘上色調乘數
	var 天空色: Color = sky_environment.environment.ambient_light_color * 雲底色調
	# 套最低亮度，夜晚不至於全黑
	天空色.v = maxf(天空色.v, 最低亮度)
	# 依連動強度在「原始固定底色」與「天空色」之間混合
	var 結果: Color = _原始雲底色.lerp(天空色, 連動強度)
	結果.a = 1.0
	res.cloud_ambient_color = 結果

	# 大氣色連動：用 SkyDome 的日／昏／夜色調近似當前地平線色，
	# 餵給雲的大氣散射色，讓遠景雲霧與 Sky3D 天空同一套色調
	if 大氣連動強度 > 0.0 and sky_dome != null:
		var 太陽高度: float = 0.0
		if clouds_driver.tracked_directional_lights.size() > 0 \
		and clouds_driver.tracked_directional_lights[0] != null:
			# basis.z 指向太陽，y 分量即太陽仰角 sin 值
			太陽高度 = clouds_driver.tracked_directional_lights[0].global_transform.basis.z.y

		var 白天權重: float = smoothstep(-0.05, 0.25, 太陽高度)
		# 黃昏權重：太陽貼近地平線時最強的鐘形權重
		var 黃昏權重: float = clampf(1.0 - absf(太陽高度) / 0.18, 0.0, 1.0)

		var 夜空色: Color = sky_dome.atm_night_tint
		var 地平線色: Color = 夜空色.lerp(sky_dome.atm_day_tint, 白天權重)
		地平線色 = 地平線色.lerp(sky_dome.atm_horizon_light_tint, 黃昏權重 * 0.7)
		地平線色 = 地平線色 * 大氣色調

		var 大氣結果: Color = _原始大氣色.lerp(地平線色, 大氣連動強度)
		大氣結果.a = _原始大氣色.a
		res.atmosphere_color = 大氣結果
