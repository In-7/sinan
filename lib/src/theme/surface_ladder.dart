import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// 面的**形状**（同一档明度下，色相往哪偏）。
///
/// 这三条形状都是 2026-09-22 定下的、各自有理由的，**不是随手挑的**：
/// - [warm]：**纸族**（2026-10-09 起，底 / 侧轨 / 内嵌浮面 / 浮层**共用**它）。
///   H=60° 的极淡暖调（R=G、B 按 [warmRatio] **按比例**下沉）—— 明暗同色相，
///   切主题不该像"换了个应用"。
///   ⚠️ 2026-10-09 晚用户定：**亮色走"类纸暖白"**（Bear / Craft / Apple Notes
///   那条语言），大面一律同族。此前卡片 / 浮层是 [neutral]（R=G=B），暖底配冷
///   白卡会在浅色下出现**色温差**（纸是暖的、卡是冷的），看着像两种材质；同族
///   之后层次**只**由明度承担，这正是纸感的含义。
///   ⚠️ 2026-10-10 下沉方式由**绝对值**改为**比例**（见 [warmRatio]）：同一个
///   绝对偏移在近黑端会被感知放大数倍，暗色会发棕。
/// - [neutral]：纯中性（R=G=B）。仅**退染的文字档**用它的语义（不随种子色漂移），
///   面不再用它。
/// - [cool]：板底。略偏冷（R, R+1, R+5），保留作为"另一种材质的 sheet"语义。
///
/// ⚠️ **"大面不染种子色"这条不用靠 R=G=B 来保证**：本表是编译期静态的（`static
/// final`，构造函数**不接收** seed），它天然不可能随主题种子色漂移。R=G=B 只是
/// 当年顺手取的机器形式，代价是连"固定暖调"一起禁掉。
enum SurfaceShape {
  warm,
  neutral,
  cool;

  /// [warm] 的 B 通道**相对**下沉比例（= 纸感的强度）。
  ///
  /// ## ⚠️ 2026-10-10：由**绝对值 5** 改为**按比例 2%**
  /// 同一个绝对偏移，在暗端会被感知放大数倍——这是它必须按比例的原因：
  ///   · R=244（浅色纸）减 5 ⇒ 相对偏移 **2%** ⇒ 微暖，正是想要的那点纸感
  ///   · R=34（暗色底）减 5 ⇒ 相对偏移 **15%** ⇒ 发棕、发脏（实机截图确认）
  /// 按比例之后两侧的**暖度感知一致**：浅色仍差 5（暖纸不变），暗色只差 1
  /// ⇒ 自动落到 Apple 的中性深灰，且不需要给暗色单独写一套色。
  ///
  /// 2% 是按浅色反推的（244 × 2% ≈ 5，与 Bear / Craft 的纸同一量级）。
  static const double warmRatio = 0.02;

  /// 该形状下 R 通道为 [r] 时的色值（B 按 [warmRatio] 下沉后取整）。
  Color of(int r) => switch (this) {
    warm => Color.fromARGB(
        255,
        r,
        r,
        (r * (1 - warmRatio)).round().clamp(0, 255),
      ),
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
    // ⚠️ 2026-10-09 晚用户改拍：**从 IDE 的"深灰 chrome + 纯白卡"换成类纸暖白**
    // （第①步）——原 88.1 是照着 opencode 压的，11.9 的档差靠软投影撑悬浮；
    // 但那是**看代码**的语言。笔记软件要的是**读和写的舒服**，纸感靠的是
    // 暖度 + 极小色差（Bear / Craft / Apple Notes 那条），不是深灰框。
    // 抬到 96 的另一笔收益：正文 Lc 从 76 回到 85+，余量不再是 1。
    baseLstar: 96,
    floatingDelta: 4, // 96 → 100（纯白仍是天花板，但只差 4）
    // 第②步：工作区卡的档差从 11.9 压到 **3**（用户定 2–4）。
    // 纸上的东西本来就该是微差——不再需要"被托起来"那套。
    panelDelta: 3, // 96 → 99
    // 板底仍是"下沉的一列"；改走 [boardDelta] 推导（不再写死 hex）。
    boardDelta: -3,
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
    // ⚠️ 2026-10-10（第③步）：底从**近黑 −0.33（#080803）抬到深暖灰 13**。
    // 动因是"类纸暖白"要明暗成一对——#080808 是 opencode / IDE 的近黑语言，
    // 跟浅色的暖纸不是同一张纸；Bear / Craft 的暗色是**深暖灰**，不是纯黑。
    //
    // 📌 连带的两处结构改动（不是顺手调的）：
    // 1. **浮层 / 板底从"绝对钉死"改回相对 delta**。它们原先钉死在 19.4 / 17.6，
    //    理由是"底压到近黑时跟着沉就看不见"。底抬回深灰后那个理由消失，
    //    继续钉死会把层次压扁（底 13 与板底 17.6 只差 4.6）⇒ 回归"底 + Δ"。
    //    ⚠️ 新 delta 是**照着原绝对值反推**的（13+4.5=17.5≈17.6、13+6.5=19.5
    //    ≈19.4）⇒ 这两个面的**绝对观感几乎不变**，变的是它们重新跟随底。
    // 2. **侧轨恢复可辨**：原先 railDelta 只有 −0.58（近黑没有向下空间，
    //    暖度加大后更是彻底与底同色）。底抬到 13 后重新有空间 ⇒ −3。
    baseLstar: 13,
    floatingDelta: 6.5, // 13 → 19.5
    // ⚠️ 2026-10-10 用户定：内容区由「浮面」翻转为「**凹陷**」——13 → **9**。
    // 理由：暗色模式的第一目的是**减少发光面积**。原先内容区是深灰（L\*18），
    // 一大块面在发光，只有文字是暗的（反了），用户实机反馈"面板有点亮"。
    // 翻过来之后只有**文字**发光，焦点自然落在内容上；且与浅色真正镜像
    // （浅色 chrome 灰 → 卡片趋向白；暗色 chrome 灰 → 内容区趋向黑）。
    // 📌 顺带把正文余量从 1.8 拉回 7（主阅读面变暗 ⇒ 对比回来了）。
    panelDelta: -4, // 13 → 9
    boardDelta: 4.5, // 13 → 17.5
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



  double get floatingLstar => baseLstar + floatingDelta;
  double get boardLstar => baseLstar + boardDelta;
  double get panelLstar => baseLstar + panelDelta;

  /// 底（**= 纸面**：`contentCanvas` 直接复用它，两处不许再漂开）。
  late final Color base = _derive(baseLstar, SurfaceShape.warm);

  /// 浮层（菜单 / 面板 / 工具条 / 卡片的底）。
  ///
  /// ⚠️ 2026-10-09 起与 [base] **同族**（[SurfaceShape.warm]）：浅色下不再允许
  /// "暖白纸 + 冷白浮层"这套冷暖并置。
  late final Color floating = _derive(floatingLstar, SurfaceShape.warm);

  /// **内嵌浮面**（2026-10-09：opencode 风外壳的工作区卡片）。
  ///
  /// 夹在底与浮层之间的一档**大面积常驻面**；同样与 [base] 同族（暖），
  /// 层次**只**由明度承担。与窗口底之间靠 `Tokens.appPanelInset` 的环缝 +
  /// 明度差分层，不画分割线。
  late final Color panel = _derive(panelLstar, SurfaceShape.warm);

  /// 板底（导航板那种"浮在底上的 sheet"）。
  late final Color board =
      boardOverride ??
      _derive(boardLstar, SurfaceShape.cool).withValues(alpha: 0.95);

  /// **侧轨**（最左图标轨 / AI 轨那一列）：比纸面**沉一档**。
  ///
  /// 形状取 [SurfaceShape.warm]（与底**同族**）——读作"同一材质深一档"，
  /// 而不是另一种材质的色块（[board] 那端才有冷灰的 sheet 语义）。
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
