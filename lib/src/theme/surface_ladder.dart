import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// 面的**形状**（同一档明度下，色相往哪偏）。
///
/// 这三条形状都是 2026-09-22 定下的、各自有理由的，**不是随手挑的**：
/// - [warm]：底 / 纸面。H=60° 的极淡暖调（R=G、B 低 2），明暗同色相 —— 切主题不该像
///   "换了个应用"；
/// - [neutral]：浮层。`R=G=B`，本仓"**大面不染种子色**"的机器可检形式
///   （`app_theme_test` 有闸门钉着，别把底的暖调复制给浮层）；
/// - [cool]：板底。Craft 那种"中性 sheet"，略偏冷（R, R+1, R+5），与底的暖调区分。
enum SurfaceShape {
  warm,
  neutral,
  cool;

  /// 该形状下 R 通道为 [r] 时的色值（B 会夹到 0..255）。
  Color of(int r) => switch (this) {
    warm => Color.fromARGB(255, r, r, math.max(0, r - 2)),
    neutral => Color.fromARGB(255, r, r, r),
    cool => Color.fromARGB(255, r, r + 1, math.min(255, r + 5)),
  };
}

/// **面的明度序（ladder）**：应用里每一块"面"的底色都从这一张表派生。
///
/// ## 为什么要有它（2026-09-22 的代价换来的）
/// 此前每个面**各写各的 hex**，档差只存在于注释里 ⇒ "抬一次暗底"要动四处绝对色值
/// （底 / 浮层 / 板底 / 呼出块），**漏一个就会比底还暗、整块陷进去**（实测踩过：
/// 板底 `#1E1F23` 在底抬到 L\* 13.7 之后就是陷进去的）。
/// 改成"底 + ΔL\*"的关系式之后：**抬档 = 改 [baseLstar] 一个数**，其余档位自动跟随。
///
/// ## 表里只有两个旋钮
/// [baseLstar]（底的明度）与各档的 ΔL\*。色值、hex、增量全部由 [_derive] 反解 ——
/// **别在这里写死 hex**：那等于把刚拆掉的东西又装回去。
///
/// ## ⚠️ 它管的是"面"，不管"字"
/// 文字档（正文 `#DDDDDD` / `onSurfaceVariant`）**不在本表**：它们被对比度闸门夹住
/// （APCA 舒适带 + "正文必须比 onSurface 更柔"），是**解出来的**而不是派生的。
/// 抬档之后要**重新验**它们（`app_theme_test` 与 `apca_audit_test` 会当场报）。
class SurfaceLadder {
  /// ⚠️ **业务代码不要自建**：用 [light] / [dark]，或经 `AppTheme.ladder(brightness)`。
  /// 公开构造只为**测试**能构造一个"假设的档位"，验证"抬档只改 [baseLstar] 一个数、
  /// 其余档位跟着走"这条性质（`test/theme/surface_ladder_test.dart`）。
  ///
  /// ⚠️ **不是 `const`**：色值是三个 `late final`（首次访问才反解，见 [_derive]），
  /// 而 `late final` 与 `const` 构造互斥。
  SurfaceLadder({
    required this.baseLstar,
    required this.floatingDelta,
    required this.boardDelta,
    this.boardOverride,
  });

  /// **亮色**一套：底 L\* 97.5 → 浮层 100（纯白）→ **板底向下 3.1**（一列下沉的导航列）。
  ///
  /// ⚠️ 亮色这头已经**贴到白端**：浮层就是纯白，没有可再抬的空间；底要动只能**往下压**
  /// （那是另一个决定，见 §5.6 的"亮色侧余量"）。所以这几种 Δ 在这里更像"记录结果"
  /// 而不是旋钮。
  static final SurfaceLadder light = SurfaceLadder(
    baseLstar: 97.5,
    floatingDelta: 2.5, // 97.5 → 100（纯白）
    // ⚠️ **破例：板底是向下的那一档**（2026-09-23 用户定）——详注见 [boardOverride]。
    boardDelta: -3.1,
    boardOverride: const Color(0xFFEFEFED),
  );

  /// **暗色**一套：底 L\* 7.67 → 板底 17.6 → 浮层 19.4。
  ///
  /// ⚠️ **抬档就是改 [baseLstar] 这一个数**（2026-09-22 从近黑 1.83 抬到 7.67 一档；
  /// 更早试过 13.65 两档，实机上"有点多"）。改完**别忘**：文字档要重验、
  /// 体检表那张 α 扫描表要重扫（半透明浮层压在最亮内容上的余量跟着底走）。
  static final SurfaceLadder dark = SurfaceLadder(
    baseLstar: 7.67,
    floatingDelta: 11.7, // 暗色浮层要比亮色跨得大得多（投影更弱，靠底色差撑）
    boardDelta: 9.9, // 板底必须比底亮（板是"浮在底上的 sheet"）
  );

  /// 底的 L\*（**唯一的手定数字**）。
  final double baseLstar;

  /// 浮层比底高多少 L\*。
  final double floatingDelta;

  /// 板底比底高多少 L\*。
  final double boardDelta;

  /// 板底不走明度序时的**直接取值**（目前只有亮色用它）。
  ///
  /// ## 亮色的板底为什么是`#EFEFED`——而且**比底更深**（2026-09-23 用户定）
  /// 它是**非 Mica 平台**（macOS / Linux / Win10）那条路上的导航列实色：
  /// Win11 将来开了 Mica 之后，左栏会改成"系统材质 + 不透明下限叠色"，而 macOS /
  /// Linux 拿不到材质 ⇒ 必须有一档**实色**让那一列仍然读得出"这是一列"。
  ///
  /// **为什么向下而不是向上**：此前它是"叠白 95%"（`0xF2FFFFFF`，合成后 `#FFFFFF`，
  /// 比主区 `#F8F8F6` 亮 2.35 ΔL\*）；而 Win11 的 Mica 在亮色下**比内容区更沉**
  /// （它是壁纸的均色，通常不是纯白）⇒ 回退档往下沉才与 Mica 那一侧同向，
  /// 也正是 Notion 侧栏 / macOS Source List 的方向（**侧栏比内容区更沉**）。
  ///
  /// 📌 取值是**量出来的**，不是挑的：候选按 ΔL\* 与文字 Lc 两个轴扫过一轮 ——
  /// | 候选 | ΔL\*（对底） | 正文 Lc | 次文字 Lc |
  /// |---|---|---|---|
  /// | `#FFFFFF`（旧） | +2.35 | 103.0 | 92.1 |
  /// | **`#EFEFED`（现）** | **−3.13** | **94.7** | **83.8** |
  /// | `#ECECEA` | −4.18 | 92.9 | 82.0 |
  /// ⇒ 取它的理由：比底深 ≥2.5 ΔL\*（肉眼一定读得出分列），而文字余量仍远超门槛
  /// （正文 75 / 次文字 60）。🔧 要更深就把这里与 [boardDelta] 一起改，别忘跑 `app_theme_test`。
  ///
  /// ⚠️ **必须不透明**（`alpha == 0xFF`）：回退档底下什么都没有，透一点就等于
  /// 直接把 `WindowBase` 那层掺进来 ⇒ 颜色不确定。
  final Color? boardOverride;

  double get floatingLstar => baseLstar + floatingDelta;
  double get boardLstar => baseLstar + boardDelta;

  /// 底（**= 纸面**：`contentCanvas` 直接复用它，两处不许再漂开）。
  late final Color base = _derive(baseLstar, SurfaceShape.warm);

  /// 浮层（菜单 / 面板 / 工具条 / 卡片的底）。
  late final Color floating = _derive(floatingLstar, SurfaceShape.neutral);

  /// 板底（导航板那种"浮在底上的 sheet"）。
  late final Color board =
      boardOverride ??
      _derive(boardLstar, SurfaceShape.cool).withValues(alpha: 0.95);
}

/// 按 **L\*** 反解出色值（尽量保住 [shape]）。
///
/// ## 为什么是"搜"而不是"算"
/// L\* ⇄ sRGB 有两套公式：CIE 正式版在 L\* < 8 处有**分段**（线性段），而本仓文档与
/// 体检表一直用的是**连续式** `116·∛Y − 16`（暗底 L\* 1.8 / 7.7 都在那一段附近）。
/// 自己写一套反解，就会与"量 L\* 的人"用两套尺子 —— 那是本项目最容易踩的坑之一
/// （体检表里"两套公式对不上"的账已经出现过）。
/// 所以这里**直接拿引擎的 [Color.computeLuminance] 搜 0..255**：写进表里的 L\* 与
/// 闸门量到的 L\* **天然同源**。代价是 256 次求值 —— 但每个档只在首次访问时算一次
/// （[SurfaceLadder] 的 `late final`），且实例是 `static const`。
Color _derive(double lstar, SurfaceShape shape) {
  int best = 0;
  double bestDelta = double.infinity;
  for (int r = 0; r <= 255; r++) {
    final double d = (_lstar(shape.of(r)) - lstar).abs();
    if (d < bestDelta) {
      bestDelta = d;
      best = r;
    }
  }
  return shape.of(best);
}

/// L\*（**连续式**，与文档 / 体检表同一把尺子；见 [_derive] 的说明）。
double _lstar(Color c) => 116 * math.pow(c.computeLuminance(), 1 / 3) - 16;
