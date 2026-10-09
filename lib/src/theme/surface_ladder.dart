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
    required this.panelDelta,
    this.boardOverride,
    this.railDelta = -3.0,
  });

  /// **亮色**一套（2026-10-09 晚定案第三版：chrome 沉到 L\* 88.1 `#DDDDDB` →
  /// 纯白浮面 100；板底再向下 3.1 档）。
  ///
  /// 轨迹（用户每轮都在实机上往上/下压一档）：94.5 grouped 灰 → 91.2 `#E6E6E4`
  /// → **88.1 `#DDDDDB`**（用户："亮色的底色可以再暗一档吗"）——压档的动力一直是
  /// 同一个：白端 L\* 差人眼是**压缩感知**，白卡压浅灰读不出悬浮。压到 88.1 后
  /// 白卡与 chrome 的 sRGB 色阶从 25 级拉到 **34 级**（221→255），再叠加卡片
  /// **软投影**（见 [AppTheme.panelShadow]，macOS / Things 3 的成熟解法），
  /// 三个通道（色阶 / 描边 / 投影）一起托白卡。
  ///
  /// 镜像口径（L\* 极内档不对称是物理性的）：暗色 chrome 在黑极 2.2、卡片
  /// 浮到 7.2（+5.0 近黑放大感知）；亮色卡片在白极 100、chrome 沉 11.9 到
  /// 88.1，再由投影补足高度感。⚠️ 亮色的 [floatingDelta] / [panelDelta] 是
  /// **天花板绑定的**（= 100 − baseLstar），底每沉一档它就自动涨一档——别当成
  /// "又调大了一档档差"，它只是白极在手边。
  static final SurfaceLadder light = SurfaceLadder(
    baseLstar: 88.1,
    floatingDelta: 11.9, // → 100（纯白；天花板绑定）
    // 内嵌浮面 = 纯白卡片，靠深一档灰底 + panelEdge（黑 α0.06）+ panelShadow
    // 软投影 + 8px 环缝浮起。
    panelDelta: 11.9, // 88.1 → 100
    // 板底仍是"下沉的一列"：比灰底再深 3.1 档（#D5D5D3）——详注 [boardOverride]。
    boardDelta: -3.1,
    boardOverride: const Color(0xFFD5D5D3),
    // railDelta 走默认（−3.0）：亮色侧栏与板底**同档**（"比灰底深一档"）。
  );

  /// **暗色**一套：底 #080808（CIE 分段尺 L\* 2.2）→ 内嵌浮面 #161616
  /// （L\* 7.2）→ 板底 17.6 → 浮层 19.4。
  ///
  /// ⚠️ **双尺注意**：本文件的 [_derive] / [_lstar] 用的是**连续式**
  /// `116·∛Y−16`，CIE 正式版在暗端则是分段的（`903.3·Y`）。#080808 在
  /// CIE 尺上 2.2、在本仓连续尺上是 **−0.33**；#161616 两尺都约 7.2。
  /// 所以 [baseLstar] 配的是连续尺值 −0.33（若配 2.2 会反解出 #0D0D0D——
  /// 2026-10-09 踩过，表面不变量闸门当场报）。
  ///
  /// 轨迹：近黑 1.83 → 2026-09-22 抬到 7.67（怕太黑）→ 2026-10-09 用户对照
  /// opencode 实机拍板**压回 #080808**（"颜色完全按照 opencode 的
  /// #080808 / #161616，同版也可以"）：工作区浮面在近黑 chrome 上才"浮"得
  /// 起来。这次**面板与底一起重排**，不是只抬面板——面板 7.2 恰好≈上一版
  /// 的底（7.67），编辑区在浮面卡内，观感几乎不变，变黑的只是标题栏 / 缝隙
  /// 这圈 chrome。改完**别忘**：文字档重验、α 扫描表重扫。
  static final SurfaceLadder dark = SurfaceLadder(
    // 连续尺 −0.33 = sRGB 8（#08；暖形 B 低 2 ⇒ #080806）。
    baseLstar: -0.33,
    // 浮层（菜单 / 面板 / 输入控件）保持**绝对** L* 19.4 不跟底下沉（delta 是
    // 连续尺差值 19.73）：近黑底上它对底差更大，菜单反而更"亮出来"。
    floatingDelta: 19.73,
    // 内嵌浮面：**精确取 opencode 值** #161616 = 连续尺 7.2（delta 7.53）。
    // 配 AppTheme.panelEdge 的 1px 白 α0.08 光边 + 8px 近黑环缝，三件套成立
    // （量截图：顶边 #2e≈白α0.10 / 侧边 #1d）。
    panelDelta: 7.53,
    // 板底保持绝对 17.6（休眠的 NavRail / HubNav 用，不跟底沉）。
    boardDelta: 17.93,
    // 侧轨"凹进一列"：连续尺 −0.91 = #070705，比底 #08 恰好沉一级；
    // 近黑底再深就是纯黑，只能让这 1 级。
    railDelta: -0.58,
  );

  /// 底的 L\*（**唯一的手定数字**）。
  final double baseLstar;

  /// 浮层比底高多少 L\*。
  final double floatingDelta;

  /// 板底比底高多少 L\*。
  final double boardDelta;

  /// **内嵌浮面**比底高多少 L\*（2026-10-09 新增；opencode 风外壳的工作区卡片）。
  final double panelDelta;

  /// 板底不走明度序时的**直接取值**（目前只有亮色用它）。
  ///
  /// ## 亮色的板底是 `#D5D5D3`——比灰底再沉 3.1 档（2026-10-09 晚版）
  /// 它是导航列那一列的**实色**（三端一致）：必须有一档实色，让左栏仍然读得出
  /// "这是一列"。方向一直是**向下沉**（Notion 侧栏 / macOS Source List 的语言：
  /// 侧栏比内容区更沉）。
  ///
  /// 轨迹：2026-09-23 旧底 #F8F8F6 时定为 `#EFEFED`（−3.1 ΔL\*）；
  /// 2026-10-09 下午亮色 chrome 沉到 #EFEFED，板底同步到 `#E7E7E5`；当晚
  /// chrome 压到 `#E6E6E4`（91.2），板底同步沉到 `#DDDDDB`；**同日再压一档**：
  /// chrome `#DDDDDB`（88.1），板底同步沉到 **`#D5D5D3`**（L\*≈85.3，对底 −3.1）
  /// ——保持"肉眼读得出分列、文字余量远超门槛（正文 75 / 次文字 60）"。
  /// 🔧 要更深就把这里与 [boardDelta] 一起改，别忘跑 `app_theme_test`。
  ///
  /// ⚠️ **必须不透明**（`alpha == 0xFF`）：回退档底下什么都没有，透一点就等于
  /// 直接把 `WindowBase` 那层掺进来 ⇒ 颜色不确定。
  final Color? boardOverride;

  /// **侧轨**比纸面沉多少 ΔL\*（阶段 0 新增；最左图标轨 / AI 轨共用）。
  ///
  /// 方向是**两个模式一致地往下沉**（rail 读作"凹进窗体的那一列"，与
  /// [boardDelta] 在暗色那端**相反**——board 是"浮起的 sheet"，rail 不是）。
  ///
  /// ⚠️ 这两个数是**要实机 eyeball 的**，不是推导结论：改 `light` / `dark` 里
  /// 各一个数即可，**别在调用点各自叠透明度**（那等于把刚拆掉的东西装回去）。
  final double railDelta;

  double get floatingLstar => baseLstar + floatingDelta;
  double get boardLstar => baseLstar + boardDelta;
  double get railLstar => baseLstar + railDelta;
  double get panelLstar => baseLstar + panelDelta;

  /// 底（**= 纸面**：`contentCanvas` 直接复用它，两处不许再漂开）。
  late final Color base = _derive(baseLstar, SurfaceShape.warm);

  /// 浮层（菜单 / 面板 / 工具条 / 卡片的底）。
  late final Color floating = _derive(floatingLstar, SurfaceShape.neutral);

  /// **内嵌浮面**（2026-10-09：opencode 风外壳的工作区卡片）。
  ///
  /// 夹在底与浮层之间的一档**大面积常驻面**，纯中性（大面不染种子色）；
  /// 与窗口底之间靠 `Tokens.appPanelInset` 的环缝 + 明度差分层，不画分割线。
  late final Color panel = _derive(panelLstar, SurfaceShape.neutral);

  /// 板底（导航板那种"浮在底上的 sheet"）。
  late final Color board =
      boardOverride ??
      _derive(boardLstar, SurfaceShape.cool).withValues(alpha: 0.95);

  /// **侧轨**（最左图标轨 / AI 轨那一列）：比纸面**沉一档**。
  ///
  /// 形状取 [SurfaceShape.warm]（与底**同族**）——读作"同一材质深一档"，
  /// 而不是另一种材质的色块（[board] 那端才有冷灰的 sheet 语义）。
  late final Color rail = _derive(railLstar, SurfaceShape.warm);
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
