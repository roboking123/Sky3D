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

# 第一次執行時記下雲資源原本的固定底色，當作連動強度<1 時的混合基準
var _原始雲底色: Color = Color(0.761, 0.784, 0.824, 1.0)
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
		_已快取原始色 = true

	# 取當前天空環境色，乘上色調乘數
	var 天空色: Color = sky_environment.environment.ambient_light_color * 雲底色調
	# 套最低亮度，夜晚不至於全黑
	天空色.v = maxf(天空色.v, 最低亮度)
	# 依連動強度在「原始固定底色」與「天空色」之間混合
	var 結果: Color = _原始雲底色.lerp(天空色, 連動強度)
	結果.a = 1.0
	res.cloud_ambient_color = 結果
