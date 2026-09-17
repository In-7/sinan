import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';

class SVGIconItemWidget extends StatelessWidget {
  const SVGIconItemWidget({
    super.key,
    this.size = const Size.square(30.0),
    this.iconSize = const Size.square(18.0),
    this.iconName,
    this.iconBuilder,
    required this.isHighlight,
    required this.highlightColor,
    this.iconColor,
    this.onPressed,
  });

  final Size size;
  final Size iconSize;
  final String? iconName;
  final WidgetBuilder? iconBuilder;
  final bool isHighlight;
  final Color highlightColor;
  final Color? iconColor;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    Widget child = iconBuilder != null
        ? iconBuilder!(context)
        : EditorSvg(
            name: iconName,
            color: isHighlight ? highlightColor : iconColor,
            width: iconSize.width,
            height: iconSize.height,
          );
    if (onPressed != null) {
      child = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: IconButton(
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          splashColor: Colors.transparent,
          padding: EdgeInsets.zero,
          icon: child,
          iconSize: size.width,
          onPressed: onPressed,
        ),
      );
    }

    // ── sinan 补丁 6（2026-09-11）：激活态加 primary 底 ──────────────
    // 官方激活态只给图标换色（highlightColor），没有底色 ⇒ 常驻工具栏里
    // "激活"读起来只是图标变了颜色，不像一个按下的按钮。这里给 isHighlight
    // 加一层 `highlightColor @ 14%` 的圆角底（圆角 6 = 官方浮层圆角，也与
    // 应用侧 M3 状态层半径一致）——**触发点与图标变色同源**（同一个
    // isHighlight 参数），所有经此 widget 的条目（桌面工具栏全部条目）
    // 一处生效。颜色语义与目录面板/斜杠菜单的激活底（primary @ 14%）一致。
    // 详见 PATCHES.md；撤销条件：上游给激活态加底色时。
    if (isHighlight) {
      child = Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: highlightColor.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
        ),
        child: child,
      );
    }

    return SizedBox(
      width: size.width,
      height: size.height,
      child: child,
    );
  }
}
