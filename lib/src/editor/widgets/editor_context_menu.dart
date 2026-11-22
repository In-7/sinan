import 'dart:async' show unawaited;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:material_ui/material_ui.dart';

import '../keys/image_block_clipboard.dart';
import '../../theme/app_float_surface.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../notes/services/note_image_preview.dart';

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
/// ## 条目（2026-11-22 统一：图片与文本共用同一套）
/// 预览图片（**图片专有**）/ 剪切 / 复制 / 粘贴 / 删除 / 全选。
///
/// - 剪切 / 复制：图片走应用内块剪贴板（系统剪贴板承载），文本走官方命令；
/// - 删除：图片按块删、文本走官方 `deleteCommand`（见条目注释）；
/// - 剪切 / 复制 在无选区时置灰；粘贴 / 删除 / 全选 只要 `selection != null` 就可用。
///
/// 不再给图片单独做「复制图片 / 删除图片」：块复制已经把位图挂进系统剪贴板
/// （`ClipboardCodec.singleLocalImagePath`），外部应用照样能粘到图片。
///
/// ## 与"空白处"的关系
/// 官方 `_showContextMenu` 只对**文本节点**弹（`currentSelectedNodes.every(
/// (n) => n.delta != null)`），且要求选区矩形非空——所以正文行的空白处右键
/// 有效（那一行本身就是段落），而"整页末尾的大空白"（我们自己的
/// `editor.trailingArea`）不在官方链路里，由视图侧另行处理。
///
/// 菜单条目数（决定出屏钳制的估算高度）：图片块比文本块多一行「预览图片」，
/// 其余行完全相同——按行数算，不写死 160/220 这种估大了的常数。
int _rowCount({required bool isImageBlock}) => isImageBlock ? 6 : 5;

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

  // 当前选区落在哪个块。图片块只比文本块多一行「预览」——其余条目共用，
  // 不再给它另做「复制图片 / 删除图片」（2026-11-22 用户定：菜单要统一）。
  final Node? selectedNode = selection == null
      ? null
      : editorState.getNodeAtPath(selection.end.path);
  // 非文本块（图片/公式/附件…，`delta == null`）：没有文字可切/复制，
  // 删除要按**块**删（见下面「删除」条目）。
  final bool isMediaBlock = selectedNode != null && selectedNode.delta == null;
  // 只有图片块能预览（其它非文本块如公式/附件没有灯箱）。
  final bool isImageBlock =
      selectedNode != null && selectedNode.type == ImageBlockKeys.type;
  final String imageSrc = isImageBlock
      ? (selectedNode.attributes[ImageBlockKeys.url] as String?) ?? ''
      : '';

  // 出屏钳制：菜单 200 宽、按行数估高（行高 ~34，取够用即可，不做测量回调）。
  final Size window = MediaQuery.sizeOf(context);
  const double width = 200;
  final double height = _rowCount(isImageBlock: isImageBlock) * 34 + 24;
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
          // 图片块**专有**的一行：预览灯箱（与双击同一实现）。其余条目与文本共用。
          if (isImageBlock)
            _ContextMenuRow(
              label: '预览图片',
              shortcut: '双击',
              onPressed: (EditorState state) {
                if (imageSrc.isEmpty) return KeyEventResult.ignored;
                unawaited(showNoteImagePreview(context, imageSrc));
                return KeyEventResult.handled;
              },
              editorState: editorState,
              onDismiss: onDismiss,
            ),
          _ContextMenuRow(
            label: '剪切',
            shortcut: 'Ctrl+X',
            // 图片块走应用内块剪贴板（官方 cutCommand 对 delta==null 是空操作）；
            // 文本块仍走官方，且仅选区非空时才可用——但**先清空块剪贴板**：
            // 否则"复制图片块 → 复制文字 → 粘贴"会粘出旧图片（同 Ctrl+C 路径）。
            onPressed: isImageBlock
                ? sinanImageCutCommand.handler
                : hasRange
                    ? (EditorState state) {
                        ImageBlockClipboard.clear();
                        return cutCommand.handler(state);
                      }
                    : null,
            editorState: editorState,
            onDismiss: onDismiss,
          ),
          _ContextMenuRow(
            label: '复制',
            shortcut: 'Ctrl+C',
            onPressed: isImageBlock
                ? sinanImageCopyCommand.handler
                : hasRange
                    ? (EditorState state) {
                        ImageBlockClipboard.clear();
                        return copyCommand.handler(state);
                      }
                    : null,
            editorState: editorState,
            onDismiss: onDismiss,
          ),
          const SizedBox(height: Tokens.spaceXs),
          _ContextMenuRow(
            label: '粘贴',
            shortcut: 'Ctrl+V',
            // 块剪贴板有图片时在任意块上都优先粘图片块（同 Ctrl+V 顺序）。
            onPressed: ImageBlockClipboard.hasContent
                ? sinanImagePasteCommand.handler
                : onPaste ?? pasteCommand.handler,
            editorState: editorState,
            onDismiss: onDismiss,
          ),
          const SizedBox(height: Tokens.spaceXs),
          // 删除：图片与文本**同一个条目**，但处理分两种：
          // - 文本块：官方 `deleteCommand`（按 selectionType 分流：删选区/删字符）；
          // - 媒体块：直接按 path 删整块。
          //   为什么不也用官方：`deleteCommand` 对 **collapsed** 选区 + `delta ==
          //   null` 的块会 `return ignored`（`_deleteInCollapsedSelection` 里
          //   `delta == null` 直接放弃）⇒ 选区形态一换就删不掉。块级删除不依赖
          //   选区形态，稳定。
          _ContextMenuRow(
            label: '删除',
            shortcut: 'Del',
            onPressed: selection == null
                ? null
                : isMediaBlock
                    ? (EditorState state) {
                        unawaited(
                          state.apply(
                            state.transaction
                              ..deleteNodesAtPath(selectedNode.path),
                          ),
                        );
                        return KeyEventResult.handled;
                      }
                    : deleteCommand.handler,
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
