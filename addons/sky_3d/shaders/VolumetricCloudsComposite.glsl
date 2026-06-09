// 體積雲合成 — 非 MSAA 變體（薄包裝）
#[compute]
#version 450

#define MSAA_ENABLED 0
#include "VolumetricCloudsComposite.comp"
