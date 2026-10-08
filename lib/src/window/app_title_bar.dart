import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import '../theme/tokens.dart';
import 'window_service.dart';

/// 窗口 Chrome 组件（自绘标题栏体系，原生标题栏已由 [WindowService]
/// 隐藏）。
///
/// 桌面布局为**左右分栏**（见 HomeScreen），主区是一条自绘顶条：
///
/// - [WindowStrip]：**主区顶条**——拖拽区（+ 可选窄屏动作/标题）+
///   最小化/最大化/关闭。左侧导航板的顶行由 [HubNav] 自己承载，不在这里。
///
/// 顶条不铺底色（底 = 窗口底纯色），承担 DragToMoveArea 与双击
/// 最大化；失焦时文字降一级颜色（与系统应用的非焦点窗口行为一致）。
///
/// 已知取舍：自绘按钮拿不到 Windows 11 的 Snap Layouts 悬停菜单。

/// 主区顶条：拖拽区 + 窗控按钮（最小化/最大化/关闭）。
///
/// 宽屏布局下只放拖拽与窗控；窄屏兜底布局（整宽一条）可通过
/// [leading]/[title] 放动作与应用名。
class WindowStrip extends StatefulWidget {
  const WindowStrip({
    super.key,
    this.leading,
    this.title,
    this.center,
    this.trailing,
  });

  /// 窄屏兜底布局的左侧动作区（宽屏分栏时为 null——按钮在侧栏头部）。
  final List<Widget>? leading;

  /// 窄屏兜底布局的应用名。
  final String? title;

  /// 拖拽带**正中**的控件（2026-09-30：全局搜索胶囊）。
  ///
  /// 实现上它是盖在拖拽带之上的**外层 Stack 兄弟**，不活在 [DragToMoveArea]
  /// 内：否则双击最大化与拖窗两个手势识别器会和它的点击同处一个竞技场，
  /// 双击识别器要等 300ms 才认输——胶囊点击被凭空拖慢半拍，测试里则永不触发。
  final Widget? center;

  /// 右侧紧贴窗控按钮前的动作区（如主菜单）。宽屏分栏时用来把主菜单
  /// 放在「最小化」左侧，与窗控成组。
  final List<Widget>? trailing;

  @override
  State<WindowStrip> createState() => _WindowStripState();
}

class _WindowStripState extends State<WindowStrip> with WindowListener {
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

    return Container(
      height: Tokens.titleBarHeightMain,
      color: Colors.transparent,
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
                    // 窄屏兜底的应用名（宽屏为空盒，拖拽照常吃事件）。
                    child: Container(
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(
                        horizontal: Tokens.spaceMd,
                      ),
                      child: DefaultTextStyle(
                        style: TextStyle(
                          color: _focused
                              ? theme.colorScheme.onSurface
                              : theme.colorScheme.onSurfaceVariant,
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
/// 尺寸是 40×40，直接放进 48 高的顶条会溢出——收成紧凑方形。
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
          minimumSize: const Size(
            Tokens.titleBarHeightMain,
            Tokens.titleBarHeightMain,
          ),
          maximumSize: const Size(
            Tokens.titleBarHeightMain + 8,
            Tokens.titleBarHeightMain,
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
