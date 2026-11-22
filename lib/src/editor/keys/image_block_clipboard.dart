import 'dart:async' show unawaited;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;

/// 应用内**块剪贴板**（2026-11-22）：图片块的复制 / 剪切 / 粘贴。
///
/// ## 为什么不用系统剪贴板
/// 官方 `copyCommand` 只写 text + html，而 `AppFlowyClipboard.setData` 在
/// `text == null`（图片块没有 delta）时**直接 return** ⇒ 图片块复制是空操作。
/// 跨应用复制本地图又必须传位图（见 note_media_service.copyImageFileToWindowsClipboard），
/// 那条路粘回编辑器会**重新落盘一份文件副本**——不是块复制的语义。
///
/// 飞书 / Notion 的块复制是**应用内**的：复制的是节点快照，粘贴时插入新块、
/// 指向**同一个**图片文件（零文件副本、零 IO）。这里照此实现。
///
/// ## 生命周期
/// 进程内单例，app 重启即失效（与飞书/Notion 的块复制一致）。
/// 只承载图片块；文本块的复制粘贴仍走官方命令，互不干扰。
abstract final class ImageBlockClipboard {
  static final List<Node> _nodes = <Node>[];
  static bool _cut = false;

  /// 当前是否有可粘贴的图片块。
  static bool get hasContent => _nodes.isNotEmpty;

  /// 复制或剪切：存节点快照（`copyWith()` 生成新 id，避免与源块 id 冲突）。
  static void copy(List<Node> nodes, {required bool cut}) {
    if (nodes.isEmpty) return;
    _nodes
      ..clear()
      ..addAll(nodes.map((Node n) => n.copyWith()));
    _cut = cut;
  }

  /// 取出粘贴用的快照（每次取都再克隆一份，允许多次粘贴）。
  static List<Node> takeForPaste() =>
      _nodes.map((Node n) => n.copyWith()).toList(growable: false);

  /// 剪切源是否已被剪切器删除（供粘贴端决定是否需要清理原块）。
  /// 当前剪切在 `cut` 命令里同步删源，故此标记只用于语义/测试。
  static bool get wasCut => _cut;

  static void clear() {
    _nodes.clear();
    _cut = false;
  }
}

/// 当前选区是否**只含图片块**（且非空）。文本/混合选区一律 false ⇒ 交回官方命令。
bool isImageOnlySelection(EditorState editorState) {
  final Selection? selection = editorState.selection?.normalized;
  if (selection == null || selection.isCollapsed) return false;
  final List<Node> nodes = editorState.getNodesInSelection(selection);
  return nodes.isNotEmpty &&
      nodes.every((Node n) => n.type == ImageBlockKeys.type);
}

/// 选区所在的**单个**图片块（右键菜单用：图片块选中时选区可能 collapsed 与否）。
Node? imageNodeAtSelection(EditorState editorState) {
  final Selection? selection = editorState.selection;
  if (selection == null) return null;
  final Node? node = editorState.getNodeAtPath(selection.end.path);
  if (node == null || node.type != ImageBlockKeys.type) return null;
  return node;
}

/// 复制命令：只在纯图片选区接管，其余交回官方。
final CommandShortcutEvent sinanImageCopyCommand = CommandShortcutEvent(
  key: 'sinan.image.copy',
  getDescription: () => '复制图片块',
  command: 'ctrl+c',
  macOSCommand: 'cmd+c',
  handler: (EditorState editorState) {
    if (!isImageOnlySelection(editorState)) return KeyEventResult.ignored;
    final Selection selection = editorState.selection!.normalized;
    ImageBlockClipboard.copy(
      editorState.getNodesInSelection(selection),
      cut: false,
    );
    return KeyEventResult.handled;
  },
);

/// 剪切命令：复制快照 + 删除源块，只在纯图片选区接管。
final CommandShortcutEvent sinanImageCutCommand = CommandShortcutEvent(
  key: 'sinan.image.cut',
  getDescription: () => '剪切图片块',
  command: 'ctrl+x',
  macOSCommand: 'cmd+x',
  handler: (EditorState editorState) {
    if (!isImageOnlySelection(editorState)) return KeyEventResult.ignored;
    final Selection selection = editorState.selection!.normalized;
    // ⚠️ getSelectedNodes 返回脱离树的副本（copyWith ⇒ parent=null ⇒ path=[]），
    // deleteNode(副本) 删不掉真节点；getNodesInSelection 才是带 path 的真节点。
    final List<Node> nodes = editorState.getNodesInSelection(selection);
    ImageBlockClipboard.copy(nodes, cut: true);
    final Transaction transaction = editorState.transaction;
    for (final Node node in nodes) {
      transaction.deleteNode(node);
    }
    unawaited(editorState.apply(transaction));
    return KeyEventResult.handled;
  },
);

/// 粘贴命令：块剪贴板有内容 ⇒ 插到当前光标后面；否则 ignored 回退智能粘贴
/// （剪贴板位图落盘 / 官方文本粘贴，见 editor_image_paste.dart）。
final CommandShortcutEvent sinanImagePasteCommand = CommandShortcutEvent(
  key: 'sinan.image.paste',
  getDescription: () => '粘贴图片块',
  command: 'ctrl+v',
  macOSCommand: 'cmd+v',
  handler: (EditorState editorState) {
    if (!ImageBlockClipboard.hasContent) return KeyEventResult.ignored;
    final Selection? selection = editorState.selection?.normalized;
    if (selection == null) return KeyEventResult.ignored;
    final List<Node> nodes = ImageBlockClipboard.takeForPaste();
    final Path insertAt = selection.end.path.next;
    final Transaction transaction = editorState.transaction
      ..insertNodes(insertAt, nodes)
      ..afterSelection = Selection.collapsed(Position(path: insertAt));
    unawaited(editorState.apply(transaction));
    ImageBlockClipboard.clear();
    return KeyEventResult.handled;
  },
);
