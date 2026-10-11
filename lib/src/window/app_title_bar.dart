import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import '../app/providers.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'window_service.dart';

/// 窗口 Chrome 组件（自绘标题栏体系，原生标题栏已由 [WindowService]
/// 隐藏）。
///
/// 桌面外壳为**全宽顶条 + 内嵌浮面**（2026-10-09 用户定，opencode 风，
/// 见 HomeScreen）：
///
/// - [WindowStrip]：44 高全宽**通栏**——拖拽区（+ 可选标题）+ **正中**动作组（四枚
///   目的地图标药丸：心流 / 全部 / 日历 / 收藏，彼此 16 隔，精确几何居中；左 `Expanded`
///   等分放历史键浮「心流」左，不挤占导航位）+ 设置钮（紧贴最小化
///   左、与窗控成组）+ 最小化 / 最大化 / 关闭。（问笔记 2026-10-11 起移入 hub 头栏，
///   贴「筛选与排序」右侧。）
/// - 条下**不画分隔线**：内容区是 8px 环缝内的圆角浮面卡，层次只靠窗口底与
///   浮面的明度差 + 缝隙表达。
///
/// 顶条不铺底色（底 = 窗口底纯色），承担 DragToMoveArea 与双击
/// 最大化；失焦时文字降一级颜色（与系统应用的非焦点窗口行为一致）。
///
/// 已知取舍：自绘按钮拿不到 Windows 11 的 Snap Layouts 悬停菜单。

/// 全宽顶条：左/右动作簇 + 拖拽区 + 窗控按钮（最小化/最大化/关闭）。
///
/// [leading]/[trailing] 放动作；[title] 可放应用名。
class WindowStrip extends ConsumerStatefulWidget {
  const WindowStrip({
    super.key,
    this.leading,
    this.title,
    this.center,
    this.trailing,
  });

  /// 左侧动作簇（可选扩展位；2026-10-11 起上一步 / 下一步已并入 [center] 居中组、
  /// 紧挨心流左侧，此处通常留空）。
  final List<Widget>? leading;

  /// 应用名（可选，渲染在拖拽带左端）。
  final String? title;

  /// 拖拽带**正中**的控件（2026-10-11 起承载居中的目的地图标药丸：心流 / 全部 /
  /// 日历 / 收藏；全局搜索胶囊后续也接进此槽，与导航同段或取代之）。
  ///
  /// 实现上它是盖在拖拽带之上的**外层 Stack 兄弟**，不活在 [DragToMoveArea]
  /// 内：否则双击最大化与拖窗两个手势识别器会和它的点击同处一个竞技场，
  /// 双击识别器要等 300ms 才认输——胶囊点击被凭空拖慢半拍，测试里则永不触发。
  final Widget? center;

  /// 右侧动作簇（可选扩展位；2026-10-11 起仅放设置钮，紧贴最小化左侧、与窗控成组；
  /// 问笔记同日移入 hub 头栏）。窗控按钮由 [_CaptionButtons] 单独渲染。
  final List<Widget>? trailing;

  @override
  ConsumerState<WindowStrip> createState() => _WindowStripState();
}

class _WindowStripState extends ConsumerState<WindowStrip> with WindowListener {
  bool _focused = true;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(_sync());
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _sync() async {
    final bool focused = await windowManager.isFocused();
    if (!mounted) return;
    setState(() => _focused = focused);
  }

  @override
  void onWindowFocus() => _safeSet(() => _focused = true);

  @override
  void onWindowBlur() => _safeSet(() => _focused = false);

  void _safeSet(VoidCallback apply) {
    if (!mounted) return;
    setState(apply);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 标题条是透明容器，透出平台窗色（chrome = 主题色）；其上的图标 / 文字
    // 必须吃 onChrome（按 chrome 色明度翻转的墨色），否则在饱和主题色底上
    // 不可读。tabler 图标经 AppIconTheme 桥接读 Material IconTheme，故套一层
    // IconTheme 即生效。
    final settings = ref.watch(settingsProvider);
    final Color? seed = settings.themeSeed == 0 ? null : Color(settings.themeSeed);
    final Color onChrome = AppTheme.onChrome(seed, theme.brightness);

    return Container(
      height: Tokens.titleBarHeightMain,
      color: Colors.transparent,
      child: IconTheme(
        data: IconThemeData(color: onChrome),
        child: Stack(
          children: <Widget>[
            // 底层：动作区 + 拖拽带 + 窗控。
            Row(
              children: <Widget>[
                ...?widget.leading?.map(
                  (Widget action) => chromeActionButton(context, action),
                ),
                // 顶边的缩放手柄**不在这里**：由 `main.dart` 的 builder 层统一盖
                // 一层 `DragToResizeArea`（含两个顶角、一处管全窗口，见那里的
                // 说明）。这里只负责"拖动窗口"：[DragToMoveArea] + 双击最大化。
                Expanded(
                  child: DragToMoveArea(
                    child: GestureDetector(
                      behavior: .translucent,
                      onDoubleTap: WindowService.toggleMaximize,
                      // 应用名（未传时为空盒，拖拽照常吃事件）。
                      child: Container(
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(
                          horizontal: Tokens.spaceMd,
                        ),
                        child: DefaultTextStyle(
                          style: TextStyle(
                            color: onChrome.withValues(
                              alpha: _focused ? 1.0 : 0.62,
                            ),
                            fontSize: Tokens.fontSizeSm,
                          ),
                          child: widget.title != null
                              ? Text(widget.title!)
                              : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ),
                ),
                ...?widget.trailing?.map(
                  (Widget action) => chromeActionButton(context, action),
                ),
                const _CaptionButtons(),
              ],
            ),
            // 正中控件（全局搜索胶囊）：盖在拖拽带**之上**的兄弟层，不进
            // DragToMoveArea 的手势竞技场（见 [center] 字段注释）。Center 自身
            // 不吃事件，胶囊之外的点击照常落到底层拖拽带。
            if (widget.center != null)
              Positioned.fill(child: Center(child: widget.center)),
          ],
        ),
      ),
    );
  }
}

/// 窗控按钮组：最小化 / 最大化·还原 / 关闭。复用 window_manager 的
/// 标准字形（图标库里没有这三个字形，不要自己画）。
class _CaptionButtons extends StatefulWidget {
  const _CaptionButtons();

  @override
  State<_CaptionButtons> createState() => _CaptionButtonsState();
}

class _CaptionButtonsState extends State<_CaptionButtons> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(_sync());
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _sync() async {
    final bool maximized = await windowManager.isMaximized();
    if (!mounted) return;
    setState(() => _maximized = maximized);
  }

  @override
  void onWindowMaximize() => _safeSet(() => _maximized = true);

  @override
  void onWindowUnmaximize() => _safeSet(() => _maximized = false);

  void _safeSet(VoidCallback apply) {
    if (!mounted) return;
    setState(apply);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Directionality(
      textDirection: .ltr,
      child: Row(
        mainAxisSize: .min,
        children: <Widget>[
          Tooltip(
            message: '最小化',
            child: WindowCaptionButton.minimize(
              brightness: theme.brightness,
              onPressed: WindowService.minimize,
            ),
          ),
          Tooltip(
            message: _maximized ? '向下还原' : '最大化',
            child: _maximized
                ? WindowCaptionButton.unmaximize(
                    brightness: theme.brightness,
                    onPressed: WindowService.toggleMaximize,
                  )
                : WindowCaptionButton.maximize(
                    brightness: theme.brightness,
                    onPressed: WindowService.toggleMaximize,
                  ),
          ),
          Tooltip(
            message: '关闭',
            child: WindowCaptionButton.close(
              brightness: theme.brightness,
              onPressed: WindowService.close,
            ),
          ),
        ],
      ),
    );
  }
}

/// Chrome 内 IconButton 的统一主题包裹：全局 iconButtonTheme 的最小
/// 尺寸是 40×40，直接放进 44 高的顶条会贴满全高——收成 [Tokens.chromeButtonSize]
/// （32）固定方块，与居中目的地图标药丸同大（2026-10-11 用户定悬浮背景齐平），
/// 在条内垂直居中（上下各 6 呼吸）。
Widget chromeActionButton(BuildContext context, Widget action) {
  final ThemeData theme = Theme.of(context);
  return Theme(
    data: theme.copyWith(
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          // 形状与全局一致（radiusSm 圆角方形）。M3 的 IconButton
          // 默认是 StadiumBorder 正圆，不显式指定会盖掉全局样式。
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Tokens.radiusSm),
          ),
          minimumSize: const Size.square(Tokens.chromeButtonSize),
          maximumSize: const Size(
            Tokens.chromeButtonSize + 8,
            Tokens.chromeButtonSize,
          ),
          padding: EdgeInsets.zero,
          iconSize: Tokens.iconMd,
          tapTargetSize: .shrinkWrap,
        ),
      ),
    ),
    child: action,
  );
}

// 顶边缩放手柄曾在这里（`_TopResizeHandle`，两条 chrome 各铺一条 6~8px 感应带）。
// 2026-09-22 搬到 `main.dart` 的 builder 层，改用 window_manager 的
// `DragToResizeArea`（只圈 top / topLeft / topRight）：
// ① 一处管全窗口 ⇒ 换布局不会再漏掉（漏了就是"顶边拖不动"，历史上真踩过）；
// ② 两个**顶角**一并有了手柄（旧版只有 top）；
// ③ 厚度收成一个常量（左/右/底三边仍是系统原生边框，不受影响）。
