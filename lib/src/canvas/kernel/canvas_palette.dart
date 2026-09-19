import 'dart:ui' show Color;

import 'ink_stroke.dart' show kThemeInk;

/// 画布 item 的**语义色槽位**（对标 JSON Canvas 规范的预设色：具体色值由应用按
/// 自身配色方案决定，规范有意不写死）。
///
/// ## 为什么存"槽位名"而不是直接存 ARGB
/// 直接存颜色会把颜色**固化**进存档：换主题后它不跟着变，暗色画布上就会"黑墨画
/// 黑纸"（2026-09-17 那次用户截图反馈的同类坑）。存槽位名则相反——**语义**（"这是
/// 需要留意的红"）跟着主题走，将来调整配色也不用迁移任何数据。
///
/// `null`（没有槽位）= **跟随主题墨色**，等价于现在的默认观感。
enum CanvasColorSlot { red, orange, yellow, green, cyan, blue, purple, pink }

/// 画布调色板：**亮/暗底都够对比**的中高饱和色（Excalidraw 口径）。
///
/// ⚠️ 这份常量住在**内核**（而不是 UI 层）是刻意的：绘制层（`ItemPainter`）与
/// 栅格化导出都要用它，而 kernel 不该依赖 Material/theme 层。
///
/// 首项是 [kThemeInk]——**哨兵 = 跟随主题**，保证"默认就是能看见的颜色"：用户不必
/// 知道暗色档具体是多少，选它就永远可见。
const List<Color> canvasPalette = <Color>[
  kThemeInk, // 跟随主题（亮：近黑 / 暗：浅灰）
  Color(0xFFE5484D), // 红
  Color(0xFFF76B15), // 橙
  Color(0xFFFFC53D), // 黄
  Color(0xFF30A46C), // 绿
  Color(0xFF00A2C7), // 青
  Color(0xFF3E63DD), // 蓝
  Color(0xFF8E4EC6), // 紫
  Color(0xFFE93D82), // 粉
];

/// 槽位 → 实色。
///
/// **单一来源 = [canvasPalette]**（序号 = 槽位序 + 1，跳过首项哨兵）⇒ "调色板"与
/// "槽位"不会各写一份而漂移。它们的对应关系由
/// `test/canvas/canvas_palette_test.dart` 钉住。
Color canvasSlotColor(CanvasColorSlot slot) => canvasPalette[slot.index + 1];

/// 槽位名 → 枚举；未知名返回 null（**不抛**：脏存档不该让整张画布打不开，
/// 与 `CanvasEdge` 的端口解析同一口径）。
CanvasColorSlot? canvasColorSlotOf(Object? raw) {
  if (raw is! String) return null;
  for (final CanvasColorSlot s in CanvasColorSlot.values) {
    if (s.name == raw) return s;
  }
  return null;
}
