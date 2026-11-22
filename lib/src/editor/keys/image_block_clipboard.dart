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

/// 复制命令：只在纯图片选区接管，其余交回官方。
///
/// ⚠️ 非图片选区（文本/混合）时**顺手清空块剪贴板**再 `ignored` 交回官方：
/// 否则"复制图片块 → 再复制一段文字 → Ctrl+V"会粘出旧图片（用户 2026-11-22
/// 实测）。文本复制走官方 `copyCommand`，它不认识这块内存剪贴板，只能由
/// 本命令在让行前清理。返回 `ignored` 后官方命令照常执行（先命中先赢）。
final CommandShortcutEvent sinanImageCopyCommand = CommandShortcutEvent(
  key: 'sinan.image.copy',
  getDescription: () => '复制图片块',
  command: 'ctrl+c',
  macOSCommand: 'cmd+c',
  handler: (EditorState editorState) {
    if (!isImageOnlySelection(editorState)) {
      ImageBlockClipboard.clear();
      return KeyEventResult.ignored;
    }
    final Selection selection = editorState.selection!.normalized;
    ImageBlockClipboard.copy(
      editorState.getNodesInSelection(selection),
      cut: false,
    );
    return KeyEventResult.handled;
  },
);

/// 剪切命令：复制快照 + 删除源块，只在纯图片选区接管。
///
/// 非图片选区同样先清空块剪贴板（同 [sinanImageCopyCommand] 的理由）。
final CommandShortcutEvent sinanImageCutCommand = CommandShortcutEvent(
  key: 'sinan.image.cut',
  getDescription: () => '剪切图片块',
  command: 'ctrl+x',
  macOSCommand: 'cmd+x',
  handler: (EditorState editorState) {
    if (!isImageOnlySelection(editorState)) {
      ImageBlockClipboard.clear();
      return KeyEventResult.ignored;
    }
    final Selection selection = editorState.selection!.normalized;
    // ⚠️ getSelectedNodes 返回脱离树的副本（copyWith ⇒ parent=null ⇒ path=[]），
    // deleteNode(副本) 删不掉真节点；getNodesInSelection 才是带 path 的真节点。
    final List<Node> nodes = editorState.getNodesInSelection(selection);
    ImageBlockClipboard.copy(nodes, cut: true);
    final Transaction transaction = editorState.transaction;
    // 删除后选区必须落回一个**存在的**块：否则选区悬空（path 指向已删块），
    // 后续 Ctrl+V 无处可插、右键菜单判块拿不到节点。落点取"删除位置"（同层
    // 兄弟），删到该层末尾则取前一个；该层被删空则上移到父级（交给框架补）。
    // ⚠️ 用完整 path 而非 path.first：图片可能嵌在列表/引用里。
    final Path firstPath = nodes.first.path;
    final Path parentPath = firstPath.sublist(0, firstPath.length - 1);
    final Node? parent = parentPath.isEmpty
        ? editorState.document.root
        : editorState.getNodeAtPath(parentPath);
    final int remainCount = (parent?.children.length ?? 0) - nodes.length;
    for (final Node node in nodes) {
      transaction.deleteNode(node);
    }
    if (remainCount > 0) {
      final int index = firstPath.last;
      final int anchor = index < remainCount ? index : remainCount - 1;
      transaction.afterSelection = Selection.collapsed(
        Position(path: <int>[...parentPath, anchor]),
      );
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
    // 落点 = 当前块之后；若越界（选区 path 与文档不同步、或光标本就在末尾块）
    // 夹到合法范围——顶层直接夹到 children.length，嵌套层夹到父节点的子数。
    Path insertAt = selection.end.path.next;
    if (insertAt.isNotEmpty) {
      final Path parentPath = insertAt.sublist(0, insertAt.length - 1);
      final Node? parent = parentPath.isEmpty
          ? editorState.document.root
          : editorState.getNodeAtPath(parentPath);
      final int limit = parent?.children.length ?? 0;
      if (insertAt.last > limit) {
        insertAt = <int>[...parentPath, limit];
      }
    }
    final Transaction transaction = editorState.transaction
      ..insertNodes(insertAt, nodes)
      ..afterSelection = Selection.collapsed(Position(path: insertAt));
    unawaited(editorState.apply(transaction));
    ImageBlockClipboard.clear();
    return KeyEventResult.handled;
  },
);
