import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// **APCA 0.1.9（SAPC）的 Lc**：正 = 浅底深字（亮色档），负 = 深底浅字（暗色档）。
///
/// ## 为什么不用 WCAG
/// WCAG 的 4.5 / 7 只是**下限**，而且**对深色严重高估**（APCA 官方口径）——
/// 同一个"够读"的观感，亮色侧约 9.8:1、暗色侧要 14.4:1。实测对照（底亮 `#F8F8F6`
/// / 暗 `#171715`，两边都取"刚好达标"那端）：
///
/// | WCAG | 亮色侧 | 暗色侧 |
/// |---|---|---|
/// | 4.5:1（AA） | Lc +69 | **Lc −31.7** |
/// | 10:1 | Lc +90.6 | Lc −65 |
///
/// 机制两条：① `+0.05` 那个常数在暗色侧成了分母主导项（底的亮度 0.0036 ≪ 0.05），
/// 公式其实在量"字有多亮"；② 浅字压深底会发光（halation），感知对比低于亮度差 ⇒
/// APCA 用了两套指数（0.56/0.57 vs 0.65/0.62）+ 黑位软夹，WCAG 只有一套。
///
/// ## 档位（APCA 官方）
/// - **正文**（分栏、≥14px/400）：首选 **90**、最低 **75**
/// - **非分栏文本**（短句/标签）：最低 **60**
/// - **占位符 / 禁用**：最低 **30**
/// - **图形**：重要的 ≥ 30、**绝对最低 15**（细线最容易掉到 15 以下 ⇒ 等于看不见）
/// - ⚠️ **暗色上限约 −90**（初步结论）：再亮就是"字在发光"
/// - 原则是**对比恒常性**：过了临界对比，再加大对比**不会**更好读
///
/// 自检锚点：黑 on 白 = **106.04**、白 on 黑 = **−107.88**（官方基准值，
/// `test/theme/app_theme_test.dart` 先用它验尺子）。
double apcaLc(Color txt, Color bg) {
  double y(Color c) {
    double ch(double v) => math.pow(v, 2.4).toDouble();
    final double raw =
        0.2126729 * ch(c.r) + 0.7151522 * ch(c.g) + 0.0721750 * ch(c.b);
    // 软夹黑（补偿环境光）——少了这一步锚点就对不上。
    return raw < 0.022 ? raw + math.pow(0.022 - raw, 1.414).toDouble() : raw;
  }

  final double ytxt = y(txt);
  final double ybg = y(bg);
  if (ybg > ytxt) {
    final double sapc = (math.pow(ybg, 0.56) - math.pow(ytxt, 0.57)) * 1.14;
    return sapc < 0.1 ? 0 : (sapc - 0.027) * 100;
  }
  final double sapc = (math.pow(ybg, 0.65) - math.pow(ytxt, 0.62)) * 1.14;
  return sapc > -0.1 ? 0 : (sapc + 0.027) * 100;
}

/// 同 [apcaLc]，但**先把半透明 [fg] 叠到 [bg] 上**。
///
/// ⚠️ 带 alpha 的色必须走它：`divider` 是 `outlineVariant@60%`、`hint` 是
/// `onSurface@35%`——直接拿色值算会把它当成"不透明的深色"，Lc 虚高一大截
/// （体检表第一版就这么骗过了自己：暗色分隔线显示 Lc 26，实际是 **0**）。
double apcaLcBlended(Color fg, Color bg) =>
    apcaLc(Color.alphaBlend(fg, bg), bg);

/// **APCA 下限钳制**：把 [fg] 朝黑（亮底）/ 朝白（暗底）平移**明度**，直到对 [bg]
/// 的 |Lc| ≥ [minLc]；**已达标则原样返回**（不动观感）。
///
/// 为什么需要它：有些色**不能写死**——
/// - **链接**吃种子色 ⇒ 种子偏深时暗色下几乎看不见（实测某个种子只有 1.83:1）；
/// - **分隔线 / 浮层描边**是 `outlineVariant` 乘 alpha ⇒ 暗色下叠完只剩 Lc 0；
/// - **占位符**是 `onSurface@35%` ⇒ 暗色下叠完只剩 Lc −16.5。
///
/// 这些都不该靠"再手调一个色值"解决（换个种子就又坏了），而是**保底**：这里钳一次，
/// 调用方不必知道阈值。半透明入参会先落成实色（返回的也是实色）。
Color withMinLc(Color fg, Color bg, double minLc) {
  if (apcaLcBlended(fg, bg).abs() >= minLc) return fg;
  // 亮底往黑压、暗底往白提。方向用 WCAG 亮度判（与极性一一对应，够用且便宜）。
  final bool darken = bg.computeLuminance() > 0.5;
  final Color opaque = Color.alphaBlend(fg, bg);
  for (int i = 1; i <= 100; i++) {
    final Color candidate = Color.lerp(
      opaque,
      darken ? const Color(0xFF000000) : const Color(0xFFFFFFFF),
      i / 100,
    )!;
    if (apcaLc(candidate, bg).abs() >= minLc) return candidate;
  }
  return darken ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
}
