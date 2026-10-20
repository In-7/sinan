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
/// - [WindowStrip]：由 [Tokens.titleBarHeightMain] 定高（当前 **32**）的全宽**通栏**——
///   左起拖拽带（含可选应用名 [WindowStrip.title]）+ 右端 `trailing` 动作簇
///   （2026-10-12 起仅设置钮，紧贴最小化左侧、与窗控成组）+ 窗控按钮
///   （最小化 / 最大化·还原 / 关闭，见 [_CaptionButtons]）。
///   ⚠️ 导航（四枚目的地图标药丸：灵感 / 全部 / 日历 / 收藏 + 新建胶囊）已于
///   2026-10-12 移出标题栏、落在工作区左侧扁平导航 [AppIconRail]；标题栏内**不含**
///   任何导航入口（问笔记 AI 入口是条内 `trailing` 钮：设置右、最小化左）。
/// - 条下**不画分隔线**：内容区是 8px 环缝内的圆角浮面卡，层次只靠窗口底与
///   浮面的明度差 + 缝隙表达。
///
/// 顶条不铺底色（底 = 窗口底纯色），承担 DragToMoveArea 与双击
/// 最大化；失焦时文字降一级颜色（与系统应用的非焦点窗口行为一致）。
///
/// 已知取舍：自绘按钮拿不到 Windows 11 的 Snap Layouts 悬停菜单。

/// 全宽顶条：左侧动作簇（可选）+ 拖拽区 + 右侧动作簇 + 窗控按钮。
///
/// [trailing] 放右侧动作；[leading] 放左侧动作（2026-10-15 加回「上一步 /
/// 下一步」历史钮用）；[title] 可放应用名。
class WindowStrip extends ConsumerStatefulWidget {
  const WindowStrip({
    super.key,
    this.title,
    this.trailing,
    this.leading,
    this.leadingEdge,
    this.leadingInset = 0,
  });

  /// 应用名（可选，渲染在拖拽带左端）。
  final String? title;

  /// 右侧动作簇（可选扩展位；2026-10-12 起放设置钮，2026-10-16 加问笔记 AI 钮；
  /// 二者紧贴最小化左侧、与窗控成组）。窗控按钮由 [_CaptionButtons] 单独渲染。
  final List<Widget>? trailing;

  /// **左侧动作簇**（2026-10-15 新增）：上一步 / 下一步历史钮。与 [trailing]
  /// 一样逐个过 [chromeActionButton]（统一 32×32 方块 + 条内垂直居中）。
  ///
  /// ⚠️ 传的是**多个独立动作**（列表里每个元素各占一枚 32 方块），不要把一个
  /// Row 塞进来——那会被外层的 32 宽约束压扁。
  final List<Widget>? leading;

  /// [leading] 左侧的留白：把左簇推到调用方指定的 x（桌面外壳 = 内容卡左缘
  /// `railWidth` 再 + 12px 呼吸；有折叠钮时调用方会先减掉它的 32）。
  /// 这段留白本身仍是拖拽区——它上方的条带要能拖窗口。
  final double leadingInset;

  /// **最左缘动作**（2026-10-15 新增）：渲染在窗口左缘（x=0）、[leadingInset] 之前的
  /// **单一**动作——现放「折叠 / 展开左侧导航」钮。与 [leading] / [trailing] 一样过
  /// [chromeActionButton]（32×32 方块）。侧栏折叠后 home 把 [leadingInset] 归 0，此钮
  /// 仍钉在最左缘，是展开回来的唯一入口。
  final Widget? leadingEdge;

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
            // 底层：左簇（含侧栏宽留白）+ 拖拽带 + 右簇 + 窗控。
            Row(
              children: <Widget>[
                // 最左缘：折叠 / 展开侧栏钮（x=0，独立于 [leading] 的左簇）。
                if (widget.leadingEdge != null)
                  chromeActionButton(context, widget.leadingEdge!),
                // 左簇：先让出侧栏宽度的拖拽区（左簇从此开始 ⇒ 与内容卡左缘
                // 对齐），再过 chromeActionButton 统一主题。
                if (widget.leading != null) ...<Widget>[
                  SizedBox(
                    width: widget.leadingInset,
                    child: const DragToMoveArea(
                      child: SizedBox.expand(),
                    ),
                  ),
                  ...widget.leading!.map(
                    (Widget action) => chromeActionButton(context, action),
                  ),
                ],
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

/// 标题栏内 IconButton 的统一主题包裹：全局 iconButtonTheme 的最小尺寸是 40×40，
/// 直接放进 [Tokens.titleBarHeightMain] 顶条会贴满全高——收成 [Tokens.chromeButtonSize]
/// （32）固定方块，在条内垂直居中（与条同高）。现仅服务 `trailing` 的设置钮。
Widget chromeActionButton(BuildContext context, Widget action) {
  final ThemeData theme = Theme.of(context);
  return Theme(
    data: theme.copyWith(
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          // 形状与全局一致（radiusButton 圆角方形，与内面板同 10px）。M3 的
          // IconButton 默认是 StadiumBorder 正圆，不显式指定会盖掉全局样式。
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Tokens.radiusButton),
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
