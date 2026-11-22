import 'dart:async' show unawaited;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:material_ui/material_ui.dart';

import '../keys/image_block_clipboard.dart';
import '../../theme/app_float_surface.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../notes/services/note_image_preview.dart';
import '../../notes/services/note_media_service.dart';

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
/// 是否给图片块显示「复制图片」：只有**本地文件**能写系统剪贴板。
///
/// - 网络图（http/https）：没有本地字节，复制要另外下载，不出该项；
/// - 内嵌 base64（`data:image/...;base64,...`）：不是文件路径，`File(src)`
///   必然读失败 —— 早先只挡 http，用户点了「复制图片」毫无反应（2026-11-22）。
bool shouldShowCopyImageItem(String src) =>
    src.isNotEmpty && !src.startsWith('http') && !src.startsWith('data:');

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

  // 当前选区是否落在**非文本块**（图片等，delta == null）：这类块没有文字
  // 可剪切/复制/全选，给通用的四项全灰没意义——换成块级「删除 / 复制块」
  // （Notion 同款：图片块的菜单就是删除/复制/替换）。
  final Node? selectedNode = selection == null
      ? null
      : editorState.getNodeAtPath(selection.end.path);
  final bool isMediaBlock =
      selectedNode != null && selectedNode.delta == null;
  // 只有图片块能预览（媒体块还可能是公式 / 附件等，它们没有灯箱）。
  final bool isImageBlock =
      selectedNode != null && selectedNode.type == ImageBlockKeys.type;
  // 「复制图片」写系统剪贴板只支持**本地文件**（旧 quill 版同口径）；
  // 网络图没有本地字节，给置灰入口没意义，直接不显示。
  final String imageSrc = isImageBlock
      ? (selectedNode.attributes[ImageBlockKeys.url] as String?) ?? ''
      : '';
  final bool isLocalImage = shouldShowCopyImageItem(imageSrc);

  // 出屏钳制：菜单 200 宽、四行约 160 高（够用即可，不做测量回调）。
  final Size window = MediaQuery.sizeOf(context);
  const double width = 200;
  final double height = isImageBlock ? 220 : 160;
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
          // 图片块首行「预览图片」：与双击同一灯箱（入口两处、实现一份）。
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
          if (isLocalImage)
            _ContextMenuRow(
              label: '复制图片',
              shortcut: '',
              onPressed: (EditorState _) {
                unawaited(
                  NoteMediaService.copyImageFileToWindowsClipboard(imageSrc),
                );
                return KeyEventResult.handled;
              },
              editorState: editorState,
              onDismiss: onDismiss,
            ),
          // 媒体块（图片等无 delta）：文本四项对它全灰没意义，次行换成
          // 「删除图片」——块级删除走官方 transaction（与 Delete 键同款）。
          if (isMediaBlock)
            _ContextMenuRow(
              label: '删除图片',
              shortcut: 'Del',
              onPressed: (EditorState state) {
                final Selection? s = state.selection;
                if (s == null) return KeyEventResult.ignored;
                unawaited(
                  state.apply(
                    state.transaction..deleteNodesAtPath(s.end.path),
                  ),
                );
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
