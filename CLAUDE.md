# Sky3D_temp 專案筆記

## 進行中（未驗收）

- **魚鱗雲（CIRROCUMULUS）外觀尚未達使用者預期**：已迭代三版（天氣圖壓平 `weather_map_flatten`、鱗片化三件套：胞 9000／雲帶 7~11km／密度 0.45／coverage 0.90），截圖見開發紀錄，但使用者回饋「跟想像中仍有差距」——**此狀態不可視為定稿**，桌機接手繼續調。可動旋鈕都在 `SunshineCloudsWeatherController.gd` 的 PRESETS 註解（coverage 調縫寬、lg_scale 調鱗片大小、注意胞太小閃爍會回來）。
- 雲緣閃爍機制已結案：根源＝雲移動×時域累積交互（量測工具 `demo/tools/flicker_bench.gd`，top5%σ 基準：修復後約 3／全速約 9／凍結地板約 1.4），治理＝每天氣風速倍率＋時域響應（PRESETS 的 wind_mult／resp）。

## 未來項目

- **coverage 門檻語意根治（路線 A）**：`SunshineCloudsCompute.glsl` 的 coverage 實為「大噪聲×天氣圖×高度梯度」乘積的門檻——乘積值域上限約 0.45，有效區僅 0.58~1.0，不是線性的天空覆蓋比例。根治＝shader 端鏈式 remap 把 coverage 線性化（Schneider 慣例）。風險：所有既有視覺位移，PARTLY_CLOUDY 基準（coverage 0.874／濁度 0.503）與四種天氣手感需整批重調；**動工前先凍結一份現役視覺快照**。目前以校準預設處理，詳見 `SunshineCloudsWeatherController.gd` 的 PRESETS 註解。
