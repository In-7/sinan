import 'package:flutter/widgets.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';

/// 交互件的**悬停 / 按下底色**（M3 状态层口径）。
///
/// ## 为什么需要它（2026-09-15 用户实机反馈）
/// 编辑器里两类"小图标按钮"都没有指针反馈：
/// - **官方 `SVGIconItemWidget`**（浮动工具条的官方条目 + 我们的自研条目共用）
///   把三色显式置透明：`hoverColor / highlightColor / splashColor:
///   Colors.transparent` ⇒ 只有 tooltip、按下去"没有动静"；
/// - **块手柄**（`custom_block_components.dart` 自绘）同样只有图标变色。
///
/// vendored 渲染件内部改不了，故在**控件最外层**补一层自己的状态层。抽成公共件
/// 是为了两处共用同一套口径（[AppTheme.stateLayer] @12% / [AppTheme.stateLayerPressed]
/// @18%），不会各自漂移。
///
/// ## 尺寸与"不干扰"的保证
/// - **不加 padding/margin**：底色恰好等于被包控件的自身尺寸（工具条条目 30×30、
///   手柄按钮 [size]²），不会糊成一条；
/// - [MouseRegion] / [Listener] 都**只观察不拦截**指针 ⇒ 内层按钮的点击、
///   `Tooltip` 的悬停全部照旧；
/// - 指针离开时连 `_pressed` 一起清（否则在按钮上按下、拖出去松开会留下一层
///   永不消失的按下色）。
class HoverStateLayer extends StatefulWidget {
  const HoverStateLayer({super.key, required this.base, required this.child});

  /// 状态层基色（工具条 / 手柄都传 `onSurfaceVariant`）。
  final Color base;

  final Widget child;

  @override
  State<HoverStateLayer> createState() => _HoverStateLayerState();
}

class _HoverStateLayerState extends State<HoverStateLayer> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final Color? color = _pressed
        ? AppTheme.stateLayerPressed(widget.base)
        : _hovered
        ? AppTheme.stateLayer(widget.base)
        : null;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: Listener(
        onPointerDown: (_) => setState(() => _pressed = true),
        onPointerUp: (_) => setState(() => _pressed = false),
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(Tokens.radiusSm),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
