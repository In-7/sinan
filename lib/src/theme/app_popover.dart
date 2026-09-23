import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'app_float_surface.dart';
import 'app_theme.dart';
import 'tokens.dart';

/// 通用**锚定浮层**：点按钮弹出面板，点面板外任意处 / 按 Esc 关闭。
///
/// ## 为什么用 OverlayPortal 而不是 LayerLink
/// 走官方 3.47 推荐的 `OverlayPortal.overlayChildLayoutBuilder`：位置由框架给的
/// [OverlayChildLayoutInfo]（锚点尺寸 + 到浮层的变换 + 浮层尺寸）算出，锚点移动 /
/// 窗口缩放**自动跟随**，不必手写 `OverlayEntry` 与坐标反查；隐藏时它的
/// RenderObject 会移出树、不参与 layout/paint。
///
/// ## 两个容易踩的点
/// 1. **锚点按钮必须由调用方构建**（[anchorBuilder]），不能在内部包一层
///    `GestureDetector`——`IconButton` 自己会赢下点击手势的竞技场，外层手势永远
///    收不到 tap，开关就成了摆设；
/// 2. 按钮与面板**必须同属一个 [TapRegion] 组**：否则点按钮关闭时，down 先触发
///    "点外部"收起、up 的 `onPressed` 又把它打开，表现为"关不掉"
///    （目录气泡那次实测踩过）。
///
/// 面板内容统一套 [AppFloatSurface]（浮层三件套），只负责内容本身。
class AppPopover extends StatefulWidget {
  const AppPopover({
    super.key,
    required this.anchorBuilder,
    required this.builder,
    required this.panelWidth,
    this.blur = false,
  });

  /// **磨砂档**：面板底色转半透明（[AppTheme.menuFill]）并在面板矩形内做局部模糊
  /// （见 [AppFloatSurface.blur]）。主菜单用它（2026-09-22）。
  final bool blur;

  /// 锚点构建器：`toggle` 开关浮层，`isOpen` 供高亮态使用。
  final Widget Function(BuildContext context, VoidCallback toggle, bool isOpen)
  anchorBuilder;

  /// 浮层内容构建器（外层已套 [AppFloatSurface]）。
  ///
  /// `close` 供**选完即关**的菜单项调用（点一项就收起，是浮层菜单的常规行为）。
  final Widget Function(BuildContext context, VoidCallback close) builder;

  /// 面板固定宽度：定位要在**知道宽度**时才能把面板钳进屏幕内，否则靠右的
  /// 工具条弹面板会溢出窗口。
  final double panelWidth;

  @override
  State<AppPopover> createState() => _AppPopoverState();
}

class _AppPopoverState extends State<AppPopover> {
  final OverlayPortalController _controller = OverlayPortalController();

  /// 按钮与面板共用的 TapRegion 组（见类文档第 2 点）。
  final Object _groupId = Object();

  /// 自己记一份开合态：`OverlayPortalController` 的变化不会让锚点重建，
  /// 只读 `isShowing` 的话按钮的高亮态会一直停在旧值。
  bool _open = false;

  // ⚠️ 刻意**不**在 dispose 里调 `_controller.hide()`：拆卸过程中浮层条目已经
  // 从 theater 摘掉，再 hide 会踩 `OverlayPortalController` 的
  // `assert(_zOrderIndex != null)`（实测直接让整棵树的 finalize 抛异常）。
  // 浮层生命周期由 OverlayPortal 自己收尾。

  void _show() {
    if (_open) return;
    setState(() => _open = true);
    _controller.show();
  }

  void _hide() {
    if (!_open) return;
    setState(() => _open = false);
    if (_controller.isShowing) _controller.hide();
  }

  void _toggle() => _open ? _hide() : _show();

  @override
  Widget build(BuildContext context) {
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _controller,
      overlayChildBuilder: _buildOverlay,
      child: TapRegion(
        groupId: _groupId,
        child: widget.anchorBuilder(context, _toggle, _open),
      ),
    );
  }

  Widget _buildOverlay(BuildContext context, OverlayChildLayoutInfo info) {
    // 锚点矩形（浮层坐标）：框架给的是"子 → 浮层"的变换，套在锚点矩形上即得位置。
    final Rect anchor = MatrixUtils.transformRect(
      info.childPaintTransform,
      Offset.zero & info.childSize,
    );
    const double margin = Tokens.spaceSm;
    final double maxLeft = info.overlaySize.width - widget.panelWidth - margin;
    final double left = anchor.left.clamp(margin, math.max(margin, maxLeft));

    return Positioned(
      left: left,
      // 落在按钮下方一档间距处（与目录气泡同口径）。
      top: anchor.bottom + Tokens.spaceXs,
      child: TapRegion(
        groupId: _groupId,
        onTapOutside: (_) => _hide(),
        child: CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.escape): _hide,
          },
          // 自动聚焦：Esc 需要一个有焦点的节点才收得到（点外关闭不依赖它）。
          child: Focus(
            autofocus: true,
            child: AppFloatSurface(
              width: widget.panelWidth,
              blur: widget.blur,
              // 磨砂档必须**同时**把底色调透：实色会把模糊整块盖住。
              color: widget.blur
                  ? AppTheme.menuFill(Theme.of(context).brightness)
                  : null,
              child: widget.builder(context, _hide),
            ),
          ),
        ),
      ),
    );
  }
}
