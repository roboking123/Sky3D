# Sky3D_temp 專案筆記

## 未來項目

- **coverage 門檻語意根治（路線 A）**：`SunshineCloudsCompute.glsl` 的 coverage 實為「大噪聲×天氣圖×高度梯度」乘積的門檻——乘積值域上限約 0.45，有效區僅 0.58~1.0，不是線性的天空覆蓋比例。根治＝shader 端鏈式 remap 把 coverage 線性化（Schneider 慣例）。風險：所有既有視覺位移，PARTLY_CLOUDY 基準（coverage 0.874／濁度 0.503）與四種天氣手感需整批重調；**動工前先凍結一份現役視覺快照**。目前以校準預設處理，詳見 `SunshineCloudsWeatherController.gd` 的 PRESETS 註解。
