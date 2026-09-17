import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import '../theme/tokens.dart';
import 'window_service.dart';

/// 窗口 Chrome 组件（自绘标题栏体系，原生标题栏已由 [WindowService]
/// 隐藏）。
///
/// 桌面布局为**左右分栏**（见 HomeScreen），标题栏不再是横贯整窗的
/// 一条，拆成两个各自独立的顶条：
///
/// - [SidebarHeader]：**侧栏通高列**的顶部——功能按钮（新建/搜索/
///   设置）+ 应用名 + 拖拽区。按钮归属侧栏本体，不再借道标题栏注入；
/// - [WindowStrip]：**主区顶条**——拖拽区（+ 可选窄屏动作/标题）+
///   最小化/最大化/关闭。
///
/// 两条 Chrome 都不铺底色（底 = 窗口 Mica 材质），各自承担
/// DragToMoveArea 与双击最大化；失焦时文字降一级颜色（与系统应用
/// 的非焦点窗口行为一致）。
///
/// 已知取舍：自绘按钮拿不到 Windows 11 的 Snap Layouts 悬停菜单。

/// 侧栏头部：功能按钮 + 应用名 + 拖拽区（侧栏通高列的顶条）。
class SidebarHeader extends StatefulWidget {
  const SidebarHeader({super.key, this.actions, this.title});

  /// 侧栏功能按钮（新建/搜索/设置等高频操作）。
  final List<Widget>? actions;

  /// 应用名，显示在按钮右侧的拖拽区内。
  final String? title;

  @override
  State<SidebarHeader> createState() => _SidebarHeaderState();
}

class _SidebarHeaderState extends State<SidebarHeader> with WindowListener {
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
      height: Tokens.titleBarHeight,
      color: Colors.transparent,
      child: Row(
        children: <Widget>[
          const SizedBox(width: Tokens.spaceSm),
          ...?widget.actions?.map((Widget action) => chromeActionButton(context, action)),
          Expanded(
            child: Column(
              children: <Widget>[
                // 顶边缩放带：占拖拽区最顶几条像素。隐藏标题栏后系统顶边
                // 缩放框缺失，且 [DragToMoveArea] 会把顶边的拖动吞成「移动窗口」，
                // 于是顶边几乎没有可用的缩放手柄（其余三边有原生边框，不受影响）。
                // 这条带只铺在拖拽区，避开两端贴边的按钮；详见 [_TopResizeHandle]。
                const _TopResizeHandle(),
                Expanded(
                  child: DragToMoveArea(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onDoubleTap: WindowService.toggleMaximize,
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 主区顶条：拖拽区 + 窗控按钮（最小化/最大化/关闭）。
///
/// 宽屏布局下只放拖拽与窗控；窄屏兜底布局（整宽一条）可通过
/// [leading]/[title] 放动作与应用名。
class WindowStrip extends StatefulWidget {
  const WindowStrip({super.key, this.leading, this.title, this.trailing});

  /// 窄屏兜底布局的左侧动作区（宽屏分栏时为 null——按钮在侧栏头部）。
  final List<Widget>? leading;

  /// 窄屏兜底布局的应用名。
  final String? title;

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
      height: Tokens.titleBarHeight,
      color: Colors.transparent,
      child: Row(
        children: <Widget>[
          ...?widget.leading?.map(
            (Widget action) => chromeActionButton(context, action),
          ),
          Expanded(
            child: Column(
              children: <Widget>[
                // 顶边缩放带：占拖拽区最顶几条像素。隐藏标题栏后系统顶边
                // 缩放框缺失，且 [DragToMoveArea] 会把顶边的拖动吞成「移动窗口」，
                // 于是顶边几乎没有可用的缩放手柄（其余三边有原生边框，不受影响）。
                // 这条带只铺在拖拽区，避开两端贴边的按钮；详见 [_TopResizeHandle]。
                const _TopResizeHandle(),
                Expanded(
                  child: DragToMoveArea(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onDoubleTap: WindowService.toggleMaximize,
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
              ],
            ),
          ),
          ...?widget.trailing?.map(
            (Widget action) => chromeActionButton(context, action),
          ),
          const _CaptionButtons(),
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
      textDirection: TextDirection.ltr,
      child: Row(
        mainAxisSize: MainAxisSize.min,
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
          minimumSize: const Size(Tokens.titleBarHeight, Tokens.titleBarHeight),
          maximumSize: const Size(
            Tokens.titleBarHeight + 8,
            Tokens.titleBarHeight,
          ),
          padding: EdgeInsets.zero,
          iconSize: Tokens.iconMd,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    ),
    child: action,
  );
}

/// 顶边缩放手柄：一条极窄的透明感应带，仅铺在标题栏拖拽区的最顶部。
///
/// 背景：隐藏标题栏 + 透明 Mica 后，系统顶边的缩放框缺失；而标题栏的
/// [DragToMoveArea] 覆盖了整个拖拽区（含最顶端），会把顶边的拖动识别成
/// 「移动窗口」——于是顶边几乎没有可用的缩放手柄。其余三边有原生边框、不受
/// 影响，唯独顶边需要显式补回（这就是用户实测「其他三个边还好、顶部难触发」）。
///
/// 只铺在拖拽区、不压两端贴边的按钮（侧栏动作按钮 / 窗控按钮），故按钮的
/// 点击区完好。`startResizing(ResizeEdge.top)` 发 `WM_NCLBUTTONDOWN + HTTOP`，
/// 对无边框窗口同样生效（与 window_manager 的 `DragToResizeArea` 同一机制）。
class _TopResizeHandle extends StatelessWidget {
  const _TopResizeHandle();

  /// 感应带高度：对齐系统窗口顶边缩放框的抓取厚度
  /// （≈ SM_CXSIZEFRAME + SM_CXPADDEDBORDER，随 DPI 约 4~8px）。
  static const double _height = 8;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _height,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeUp,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => windowManager.startResizing(ResizeEdge.top),
        ),
      ),
    );
  }
}
