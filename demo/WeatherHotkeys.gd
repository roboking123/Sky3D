extends Node

## demo 專用天氣快捷鍵入口：
## 1 晴朗 / 2 多雲 / 3 陰天 / 4 暴風 / L 立刻閃電 / P 自動循環開關
## 左上角第二行顯示目前天氣與過渡狀態（第一行是相機高度）。

@export var weather_controller: SunshineCloudsWeatherController

const WEATHER_NAMES: Dictionary = {
	SunshineCloudsWeatherController.WeatherType.CLEAR: "晴朗",
	SunshineCloudsWeatherController.WeatherType.PARTLY_CLOUDY: "多雲",
	SunshineCloudsWeatherController.WeatherType.OVERCAST: "陰天",
	SunshineCloudsWeatherController.WeatherType.STORM: "暴風",
}

var _label: Label = null


func _ready() -> void:
	var hud: CanvasLayer = CanvasLayer.new()
	add_child(hud)
	_label = Label.new()
	_label.position = Vector2(20, 52)
	_label.add_theme_font_size_override("font_size", 18)
	hud.add_child(_label)


func _process(_delta: float) -> void:
	if weather_controller == null or _label == null:
		return
	var status: String = "（過渡中…）" if weather_controller.is_transitioning() else ""
	var auto_text: String = "開" if weather_controller.自動循環 else "關"
	_label.text = "天氣：%s%s  [1 晴朗 / 2 多雲 / 3 陰天 / 4 暴風 / L 閃電 / P 自動循環：%s]" % [
		WEATHER_NAMES.get(weather_controller.目前天氣, "?"), status, auto_text]


func _unhandled_key_input(event: InputEvent) -> void:
	if weather_controller == null:
		return
	var key: InputEventKey = event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_1, KEY_KP_1:
			weather_controller.set_weather(SunshineCloudsWeatherController.WeatherType.CLEAR)
		KEY_2, KEY_KP_2:
			weather_controller.set_weather(SunshineCloudsWeatherController.WeatherType.PARTLY_CLOUDY)
		KEY_3, KEY_KP_3:
			weather_controller.set_weather(SunshineCloudsWeatherController.WeatherType.OVERCAST)
		KEY_4, KEY_KP_4:
			weather_controller.set_weather(SunshineCloudsWeatherController.WeatherType.STORM)
		KEY_L:
			weather_controller.trigger_lightning()
		KEY_P:
			weather_controller.自動循環 = not weather_controller.自動循環
		_:
			return
	get_viewport().set_input_as_handled()
