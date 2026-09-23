#include <flutter/runtime_effect.glsl>

// 导航列的**水墨底**（2026-09-23 用户定）：亮色 = 白纸淡墨；暗色 = 黑纸亮墨。
//
// ## 为什么 GLSL 这么小
// 形状数学（fBm + 域扭曲 + 阈值晕染）**全部在 Dart**（`lib/src/theme/nav_ink.dart`），
// 预先烘焙成一张低分辨率 LUT（最终颜色），这里只做"采样 + 抖动"。这样安排的三个理由：
// 1. **单一事实来源**：对比度闸门直接测 Dart 数学（GLSL 在测试里编译不了）；
// 2. **SkSL 兼容**：第一版把噪声数学写在 GLSL 里、用了 uint 位运算 ⇒ impellerc
//    直接 SIGABRT（"incompatible with SkSL"）——SkSL 不支持无符号整数；
// 3. LUT 的双线性采样本身就会平均相邻值 ⇒ 残余台阶进一步被抹平。
//
// ## ⚠️ 抖动必须保留（同 pass）
// 晕染边缘是慢渐变 ⇒ 8-bit 色带照旧会出现；±0.5 级（1 LSB）的 IGN 抖动把它打散。
// 本仓实测：**独立噪点层治不了**（与渐变取值不相关），必须同一 pass 逐像素算。

out vec4 fragColor;

uniform sampler2D uLut;  // 水墨底色 LUT（Dart 生成；含最终颜色，含主题）
uniform vec2 uSize;      // 绘制区域（逻辑 px）
uniform float uDpr;      // 设备像素比（抖动按设备像素取样，DPR 2 下颗粒不翻倍）

float ign(vec2 p) {
  return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

void main() {
  vec2 coord = FlutterFragCoord().xy;
  vec2 uv = coord / max(uSize, vec2(1.0, 1.0));

  vec3 col = texture(uLut, uv).rgb;

  // ★ 同 pass 抖动：±0.5 级（1/255），按设备像素取样。
  col += (ign(coord * uDpr) - 0.5) / 255.0;

  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
