import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import '../theme/app_theme.dart';

/// **窗口最外层**：顶边/顶角缩放手柄——挂在 `MaterialApp.builder`。
///
/// ## 为什么要有这个类（而不写在 `main.dart` 的 builder 里）
/// 抽成具名件是为了**它可测**：`main.dart` 是入口、测不到，而这里的决定都是
/// "改起来无声、坏了才疼"的那种，必须有闸门（`test/window/window_base_test.dart`）。
///
/// ## ⚠️ 2026-09-23：**这里不再铺窗口底**
/// 底色改由**平台窗口**铺（[WindowService.applyWindowBackground]，同一个
/// [AppTheme.windowBackground] 令牌、不透明）⇒ 本类只剩手柄职责。
/// 收益：省掉每帧一次全屏 fill（第一笔是"透明窗口 ⇒ DWM 每帧全窗混合"，见那个方法）。
///
/// ## 关于窗口底（历史，留着解释"为什么是纯色"）
/// 取 [AppTheme.windowBackground] 令牌，明暗**同色相**的极淡暖调（亮 `#F8F8F6` /
/// 暗 `#171715`）。
///
/// ⚠️ **2026-09-22 由「微渐变」改成纯色**（用户实报色带后量化出来的账）：那条渐变
/// 两端只差 **6~7 个 8-bit 台阶**，铺满全屏对角线（≈2900 逻辑 px）⇒ **每 ~420px 一条**
/// 能看见的带。**台阶数 = 色带数** ⇒ 只有三条路：接受色带 / 抖动掉它 / 把台阶压到 1
/// （= 纯色）。这层是窗口底、不承载任何信息 ⇒ 取纯色。想再要渐变的味道见
/// `docs/ui_rewrite_plan.md` §5.6：必须**同时**做成同 pass 抖动（`FragmentShader`
/// 有序抖动）；⛔ 独立噪点层治不了（实测：摘掉它色带仍在、加回它更重）。
///
/// ⚠️ **窗口材质不做**（Mica 等，2026-09-22 定案）：三端（Win/mac/Linux）都用同一个
/// 令牌，观感完全一致，也不依赖 DWM 合成是否成功。首帧之前那一小段窗口仍是透明的。
///
/// 📌 **实机已确认（2026-09-23）**才敢把自绘底删掉：Win11 圆角仍在（系统强制）、
/// 切明暗不闪、无黑底 / 露桌面。Windows 那条落点是未公开的 `ACCENT_ENABLE_GRADIENT`
/// （`window_manager.cpp:706`），所以这三条是**必须**验的，不是可选。
///
/// ## 顶边/顶角缩放手柄：一处管全窗口
/// 隐藏标题栏后系统顶边的缩放框缺失，而 [DragToMoveArea] 会把顶边的拖动吞成「移动
/// 窗口」⇒ 顶边必须显式补回。此前是**两条 chrome 各自铺一条 8px 感应带**
/// （`app_title_bar.dart` 的 `_TopResizeHandle`），三个隐患：① 换布局必漏（漏了就是
/// "顶边拖不动"，历史上真踩过）；② 只有 `top`、**两个顶角没有手柄**；③ 厚度是散落的
/// 常量。现在由 [DragToResizeArea] 在最外层统一盖一层，三条一起解决。
///
/// ⚠️ **只圈顶边**（`top` / `topLeft` / `topRight`）：Flutter 侧的手柄是**压在内容上**
/// 的，圈了右边就会吃掉 8px 的滚动条抓取区（原生边框在客户区之外，没这问题）。左右底
/// 三边继续走系统原生边框。
/// ⚠️ 两个顶角因此压在两端按钮的**最上 8px** 上（无边框应用都这样）：想完全避开就把
/// 它们从 `enableResizeEdges` 里去掉。
///
/// ## 厚度：与另外三边**同档**（8 物理 px）
/// 三边的原生边框不是来自 `SM_CXSIZEFRAME`，而是 **window_manager 自己留的**——
/// 它在 `WM_NCCALCSIZE` 里把客户区缩进：
///
/// ```cpp
/// sz->rgrc[0].top    += IsWindows11OrGreater() ? 0 : 1;   // ← 顶边**原生 0**，所以要我们补
/// sz->rgrc[0].right  -= 8;
/// sz->rgrc[0].bottom -= 8;
/// sz->rgrc[0].left   += 8;   // 原码写作 `-= -8`，注释："required for resizing"
/// ```
///
/// （`window_manager.cpp` 的 `WM_NCCALCSIZE` 分支、`TitleBarStyle.hidden`；那些数值是
/// **物理 px**——`WM_GETMINMAXINFO` 里 `minimum_size_ * pixel_ratio_` 可证。）
/// 而 `resizeEdgeSize` 收的是**逻辑 px** ⇒ 写死 8 只在 100% 缩放时同档，125% 会厚成
/// 10 物理 px。所以这里**按 DPR 折算**（[`_kNativeResizeBandDevicePx`]）——
/// 四条边在**任何缩放**下都是 8 物理 px。
///
/// ⚠️ **别单独把顶边调薄**：它会变成"四条边里最难抓的一条"（历史上"其他三边还好、
/// 顶部难触发"正是这个方向）。要更厚/更薄，改 [_kNativeResizeBandDevicePx]（四边一起变，
/// 但左右底是原生的、改不到 ⇒ 实际上只有顶边会动，所以**别动**）。
class WindowBase extends StatelessWidget {
  const WindowBase({super.key, required this.child});

  /// 应用本体（`main.dart` 传桥 + Navigator）。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 与左右底三边的原生边框同档：**8 物理 px** ⇒ 折成逻辑 px 交给 Flutter
    // （见类文档里那段 `WM_NCCALCSIZE`）。
    final double edge =
        _kNativeResizeBandDevicePx / MediaQuery.devicePixelRatioOf(context);
    return DragToResizeArea(
      resizeEdgeSize: edge,
      enableResizeEdges: const <ResizeEdge>[
        ResizeEdge.top,
        ResizeEdge.topLeft,
        ResizeEdge.topRight,
      ],
      // ⚠️ **这里不再铺底色**（2026-09-23）：窗口自身已是不透明的
      // [AppTheme.windowBackground]（[WindowService.applyWindowBackground]）⇒
      // 铺底交给平台，省掉每帧一次全屏 fill。
      // 🔧 **回退方案 C**（把自绘底加回来）的完整配方见 `docs/ui_rewrite_plan.md` §5.6
      // —— 未启用；一旦出现"露桌面 / 黑底"就照它装回（约 10 分钟，4 步）。
      child: child,
    );
  }
}

/// 左右底三边**原生**边框的厚度（**物理 px**）：window_manager 在 `WM_NCCALCSIZE`
/// 里写死的 8（`TitleBarStyle.hidden` 分支，注释 "required for resizing"）。
///
/// ⚠️ 它不是 `SM_CXSIZEFRAME + SM_CXPADDEDBORDER`（早先的注释猜错了）——那套系统度量
/// 随 DPI 变，而这个是常量 8 物理 px。
const double _kNativeResizeBandDevicePx = 8;
