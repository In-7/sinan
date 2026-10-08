import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:window_manager/window_manager.dart';

import '../theme/app_theme.dart';

/// 桌面窗口能力的唯一出口。
///
/// 业务层不直接接触 window_manager——所有窗口操作都收在这里。
/// window_manager 官方已挂出迁往 libnativeapi/nativeapi 的通知，
/// 届时只需改本文件，上层零改动。
abstract final class WindowService {
  // 默认 1300×800：侧栏收为 300 后，在「侧栏 300 + 正文（标准 720 列，
  // 窄窗下收缩）+ TOC 248」三栏**同时显示**的前提下尽量收小——窗口 ≥1100
  // 即开 TOC（见 note_editor_view 的显隐阈值），1300 下编辑器正文约 750px
  // （≈45 字/行，标准档甜点区）。比 1440×900 略小、更紧凑。
  static const Size _initialSize = Size(1340, 800);
  static const Size _minimumSize = Size(720, 560);

  /// 当前平台是否具备桌面窗口能力（移动端/Web 恒为 false）。
  static bool get isSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// 窗口圆角政策（2026-09-10 定）：**Win11 交给系统，Win10 保持直角**。
  ///
  /// 试过并**否决**的做法：Win10 上把窗口改透明（`WindowEffect.transparent`）
  /// 再由 Flutter 自绘圆角。问题在于 Win10 的 DWM 只按**窗口矩形**画影子，而
  /// 透明窗口的四角仍属于窗口 ⇒ 四角留下方角的透明区：影子是方的、角上还会抢
  /// 点击（俗称"透明耳朵"，实测踩过）。
  ///
  /// 要在 Win10 上真圆角，只能 `SetWindowRgn` 裁**窗口区域**——但那是整数像素、
  /// **没有抗锯齿**，弧线带锯齿。权衡后不采用：**Win10 直角 + Win11 系统圆角**
  /// 是问题最少的组合。
  ///
  /// Win11 的窗口圆角由系统**强制**裁好，我们不需要做任何事。因此本类不再探测
  /// Windows 版本号——曾经那套探测只为窗口材质（Mica）存在，材质已取消。

  /// 必须在 runApp 之前调用；非桌面平台自动跳过。
  static Future<void> init() async {
    if (!isSupported) return;

    await windowManager.ensureInitialized();

    const WindowOptions options = WindowOptions(
      size: _initialSize,
      minimumSize: _minimumSize,
      center: true,
      // ⚠️ **首帧之前仍是透明**：此刻还读不到设置里的明暗（要等 provider 就绪），
      // 写死一个不透明色会在暗色下闪一下亮色。主题一确定，
      // [applyWindowBackground] 就把它切成**不透明**（见那里的说明）。
      backgroundColor: Color(0x00000000),
      titleBarStyle: TitleBarStyle.hidden,
    );

    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });

    // ⚠️ 这里**不要**加 `window_manager.setPreventClose(true)` 去自己拦关闭：
    // 关窗口在 Windows 上由 Flutter 引擎接管（`WM_CLOSE` → `System.requestAppExit`
    // → `WidgetsBindingObserver.didRequestAppExit`，收口见 `app/pending_saves.dart`
    // 的 `flushThenExit`）。preventClose 会**先吞掉** WM_CLOSE（原生 `return -1`），
    // 引擎的官方流程根本收不到，于是只剩"自己 `PostQuitMessage`"这条半拆解的路
    // ——2026-09-17 实测：改完内容立刻关窗口，窗口卡在 "(未响应)"。
  }

  /// **上次应用到窗口自身的底色**（明暗）。与 [applyWindowBackground] 配合做幂等短路：
  /// 明暗没变就不必再重设一次平台窗底（每次重设都是一次 DWM / 窗口服务器往返）。
  static Brightness? _lastBaseBrightness;

  /// 把**窗口自身**的底色设成 [AppTheme.windowBackground] 的**不透明**值。
  ///
  /// ## 为什么（2026-09-23）
  /// 此前窗口是**全透明**的（`Color(0x00000000)`），底色靠 Flutter 侧自绘 ⇒
  /// 只要窗口透明，DWM 就得每帧把**整扇窗与桌面**做一次合成/混合（它不知道我们
  /// 的内容其实是实心的）。改成不透明后这笔就省了。
  ///
  /// ⚠️ **Windows 的落点是未公开 API**：window_manager 在
  /// `windows/window_manager.cpp:706` 用的是 `SetWindowCompositionAttribute` +
  /// `ACCENT_ENABLE_GRADIENT`（不是画刷、也不是 `WM_ERASEBKGND`）。所以这一步
  /// **必须实机验三条**：① Win11 圆角还在不在 ② 切明暗闪不闪 ③ 有没有黑底 / 露桌面。
  /// ✅ 2026-09-23 **三条都已确认**（圆角由系统强制保留、切明暗不闪、无黑底）
  /// ⇒ [WindowBase] 那层自绘底随即删除（每帧一次全屏 fill 也省掉了）。
  ///
  /// 🔧 **回退方案 C**（把那层自绘底加回来）**未启用**，完整配方记在
  /// `docs/ui_rewrite_plan.md` §5.6：出现"露桌面 / 黑底 / 切明暗闪 / mac-linux 异常"
  /// 任一情形就照它装回（代价是付回第二笔，第一笔不受影响）。
  static Future<void> applyWindowBackground(Brightness brightness) async {
    if (!isSupported) return;
    if (_lastBaseBrightness == brightness) return;
    await windowManager.setBackgroundColor(
      AppTheme.windowBackground(brightness),
    );
    // ⚠️ **只在成功之后才记**：若记在 await 之前，一次平台调用失败就会被永久记住
    // "已应用" ⇒ 之后不再重试。而自绘底已经删了，铺底失败就等于**露桌面**，
    // 且要等用户下次切换明暗才自愈。现在失败会留给下一次 build 重试。
    _lastBaseBrightness = brightness;
  }

  static Future<void> minimize() async {
    if (!isSupported) return;
    await windowManager.minimize();
  }

  static Future<void> toggleMaximize() async {
    if (!isSupported) return;
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  /// 请求关闭窗口（标题栏关闭按钮 / 菜单里的"退出"）。
  ///
  /// ⚠️ 它不是"立刻关闭"：原生侧是 `WM_SYSCOMMAND/SC_CLOSE`，系统会把它转成
  /// `WM_CLOSE`，而**引擎**随后先问 Dart 是否放行退出（`didRequestAppExit`）——
  /// 未落盘的编辑在那一问里写完，引擎再补发第二个 `WM_CLOSE` 才真正销毁窗口。
  /// 整条链路见 `app/pending_saves.dart` 的 `flushThenExit`。
  static Future<void> close() async {
    if (!isSupported) return;
    await windowManager.close();
  }
}
