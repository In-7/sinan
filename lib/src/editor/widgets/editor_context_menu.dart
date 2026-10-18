import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:material_ui/material_ui.dart';

import '../../theme/app_float_surface.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';

/// 编辑器正文的**右键菜单**（官方 `contextMenuBuilder` 的实现）。
///
/// ## 为什么必须自己给（2026-09-15）
/// 官方 `_showContextMenu`（`desktop_selection_service.dart`）第一件事就是
/// `if (widget.contextMenuBuilder == null) return;` ⇒ **不传 builder，右键毫无
/// 反应**（此前正是如此）。而官方自带的 `ContextMenu` 容器也**不能用**：
/// 它没有底色（只靠内层无色 `Material`）、投影是硬编码的 blur 5 / spread 1 /
/// 黑 10%、且无描边 —— 与全场浮层（三件套）不是一族。
///
/// 所以这里自建面板：底色走 [AppFloatSurface]（= [AppTheme.floatSurface] +
/// 描边 + 投影），条目直接调**官方命令的 handler**（`ctrl+x` / `ctrl+c` /
/// `ctrl+v` / `ctrl+a` 的同一实现 ⇒ 菜单与快捷键永不脱节）。
///
/// ## 条目与可用性
/// 剪切 / 复制 需要**非折叠选区**（否则置灰不发命令）；粘贴 / 全选 恒可用。
///
/// ## 与"空白处"的关系
/// 官方 `_showContextMenu` 只对**文本节点**弹（`currentSelectedNodes.every(
/// (n) => n.delta != null)`），且要求选区矩形非空——所以正文行的空白处右键
/// 有效（那一行本身就是段落），而"整页末尾的大空白"（我们自己的
/// `editor.trailingArea`）不在官方链路里，由视图侧另行处理。
Widget sinanEditorContextMenu({
  required BuildContext context,
  required Offset position,
  required EditorState editorState,
  required VoidCallback onDismiss,
  /// 自定义「粘贴」实现（缺省用官方 `pasteCommand`）。
  /// 视图侧传入「先试剪贴板图片、否则回退文字」的智能粘贴，与 Ctrl+V 一致。
  KeyEventResult Function(EditorState)? onPaste,
}) {
  final Selection? selection = editorState.selection;
  final bool hasRange = selection != null && !selection.isCollapsed;

  // 出屏钳制：菜单 200 宽、四行约 160 高（够用即可，不做测量回调）。
  final Size window = MediaQuery.sizeOf(context);
  const double width = 200;
  const double height = 160;
  final double left = position.dx + width > window.width
      ? (position.dx - width).clamp(0.0, window.width - width)
      : position.dx;
  final double top = position.dy + height > window.height
      ? (position.dy - height).clamp(0.0, window.height - height)
      : position.dy;

  return Positioned(
    left: left,
    top: top,
    child: AppFloatSurface(
      width: width,
      padding: const EdgeInsets.symmetric(vertical: Tokens.spaceXs),
      child: Column(
        mainAxisSize: .min,
        crossAxisAlignment: .stretch,
        children: <Widget>[
          _ContextMenuRow(
            label: '剪切',
            shortcut: 'Ctrl+X',
            onPressed: hasRange ? cutCommand.handler : null,
            editorState: editorState,
            onDismiss: onDismiss,
          ),
          _ContextMenuRow(
            label: '复制',
            shortcut: 'Ctrl+C',
            onPressed: hasRange ? copyCommand.handler : null,
            editorState: editorState,
            onDismiss: onDismiss,
          ),
          const SizedBox(height: Tokens.spaceXs),
          _ContextMenuRow(
            label: '粘贴',
            shortcut: 'Ctrl+V',
            onPressed: onPaste ?? pasteCommand.handler,
            editorState: editorState,
            onDismiss: onDismiss,
          ),
          const SizedBox(height: Tokens.spaceXs),
          _ContextMenuRow(
            label: '全选',
            shortcut: 'Ctrl+A',
            onPressed: selectAllCommand.handler,
            editorState: editorState,
            onDismiss: onDismiss,
          ),
        ],
      ),
    ),
  );
}

/// 菜单行：左标签 + 右快捷键，悬停状态层与工具栏同一口径。
///
/// [handler] 为 null 表示置灰（如无选区时的剪切/复制）——与官方命令的可用性
/// 判定一致，按下去不发命令。
class _ContextMenuRow extends StatefulWidget {
  const _ContextMenuRow({
    required this.label,
    required this.shortcut,
    required this.onPressed,
    required this.editorState,
    required this.onDismiss,
  });

  final String label;
  final String shortcut;
  final KeyEventResult Function(EditorState editorState)? onPressed;
  final EditorState editorState;
  final VoidCallback onDismiss;

  @override
  State<_ContextMenuRow> createState() => _ContextMenuRowState();
}

class _ContextMenuRowState extends State<_ContextMenuRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool enabled = widget.onPressed != null;
    final Color foreground = enabled
        ? scheme.onSurface
        : AppTheme.disabledInk(scheme.onSurfaceVariant);

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: .opaque,
        onTap: enabled
            ? () {
                widget.onPressed!(widget.editorState);
                widget.onDismiss();
              }
            : null,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: Tokens.spaceXs),
          padding: const EdgeInsets.symmetric(
            horizontal: Tokens.spaceSm,
            vertical: Tokens.spaceSm,
          ),
          decoration: BoxDecoration(
            color: _hovered && enabled
                ? AppTheme.stateLayer(scheme.onSurfaceVariant)
                : null,
            borderRadius: BorderRadius.circular(Tokens.radiusSm),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  widget.label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: foreground,
                  ),
                ),
              ),
              Text(
                widget.shortcut,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: enabled
                      ? scheme.onSurfaceVariant
                      : AppTheme.disabledInk(scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
