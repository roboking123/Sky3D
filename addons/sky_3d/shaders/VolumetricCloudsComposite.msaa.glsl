// 體積雲合成 — MSAA 變體（薄包裝）
// MSAA 開啟時必須用這個：寫進 MSAA color 緩衝（image2DMS）逐樣本，
// 否則往 resolved 緩衝寫雲，後續 pass 用 MSAA 緩衝會看不到雲。
#[compute]
#version 450

#define MSAA_ENABLED 1
#include "VolumetricCloudsComposite.comp"
