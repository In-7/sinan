import 'dart:async' show unawaited;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;

import '../../clipboard/block_clipboard_transport.dart';
import '../../clipboard/clipboard_codec.dart';
import '../../notes/services/editor_image_paste.dart';

/// **块剪贴板**：任意块的复制 / 剪切 / 粘贴（2026-11-22 从"仅图片"泛化）。
///
/// ## 为什么不能直接用官方复制
/// `copyCommand` 只取 `text`（+ 生成但不落盘的 html），`AppFlowyClipboard.setData`
/// 在 `text == null` 时**直接 return** ⇒ 公式 / 附件 / 分隔线 / 表格这些
/// `delta == null` 的块复制出来是**空操作**（剪贴板里什么都没有）；纯文本又能
/// 保证格式（标题/列表丢光）。
///
/// ## 双通道
/// - **系统剪贴板**（优先）：块载荷写进自定义格式（Windows 注册格式 /
///   macOS UTI，见 `lib/src/clipboard/`），同时挂纯文本与位图给外部应用。
///   ⇒ 重启后仍能粘、外部复制会覆盖它（不会"粘出旧内容"）。
/// - **内存**（回落）：平台不支持自定义格式（Linux/Web）或写入失败时用它。
///
/// 两条通道共用同一份 [ClipboardCodec] 协议。
abstract final class BlockClipboard {
  /// 平台层（可注入假实现做单测）。
  static BlockClipboardTransport transport = createClipboardTransport();

  /// 内存回落。
  static final List<Node> _memory = <Node>[];

  /// 系统剪贴板读取缓存：读是异步的，而命令 handler 是同步的。
  ///
  /// 复制/剪切时同步写入，粘贴时直接命中；[refresh] 在打开笔记时异步回填
  /// （覆盖"重启后粘贴"）。
  static List<Node>? _cached;

  /// 当前是否有可粘贴的块（同步判定，供命令 handler 用）。
  static bool get hasContent => _cached != null || _memory.isNotEmpty;

  /// 取粘贴用节点（同步；每次克隆新 id，允许多次粘贴）。
  static List<Node> takeForPaste() {
    final List<Node> source = _cached ?? _memory;
    return source.map((Node n) => n.copyWith()).toList(growable: false);
  }

  /// 复制/剪切：同步填缓存 + 异步写系统剪贴板（不阻塞 UI）。
  static void copy(List<Node> nodes, {required bool cut}) {
    if (nodes.isEmpty) return;
    _memory
      ..clear()
      ..addAll(nodes.map((Node n) => n.copyWith()));
    _cached = List<Node>.of(_memory);
    unawaited(_writeToSystem(_memory));
  }

  /// 从系统剪贴板回填缓存（打开笔记时调用）。
  ///
  /// 读到块载荷 ⇒ 覆盖缓存；读不到 ⇒ 清空缓存（外部复制了别的东西）。
  static Future<void> refresh() async {
    if (!transport.isSupported) return;
    final String? payload = await transport.read();
    final List<Node>? nodes =
        payload == null ? null : ClipboardCodec.decode(payload);
    _cached = nodes;
    _memory
      ..clear()
      ..addAll(nodes ?? const <Node>[]);
  }

  static void clear() {
    _cached = null;
    _memory.clear();
  }

  /// 写系统剪贴板：载荷 + 纯文本 + （单张本地图时）位图。
  static Future<bool> _writeToSystem(List<Node> nodes) async {
    if (!transport.isSupported) return false;
    try {
      return await transport.write(
        payload: ClipboardCodec.encode(nodes),
        plainText: ClipboardCodec.plainTextOf(nodes),
        imageFilePath: ClipboardCodec.singleLocalImagePath(nodes),
      );
    } on Object {
      return false;
    }
  }
}

/// 当前选区是否**整块覆盖**（可以走块级复制）。
///
/// 判据：非折叠，且**首块从 offset 0 起、末块到块末尾止**（中间块必然完整）。
/// `delta == null` 的块（图片/公式/附件/表格…）天然只能整块，无需查 offset。
///
/// 为什么不等于"任意非折叠选区"：用户选中一句话按 Ctrl+C，期望复制的是**这几个
/// 字**（纯文本），不是整段。只有整块选中才升级为"复制块"（保留格式/结构）。
bool isWholeBlockSelection(EditorState editorState) {
  final Selection? selection = editorState.selection?.normalized;
  if (selection == null || selection.isCollapsed) return false;
  final List<Node> nodes = editorState.getNodesInSelection(selection);
  if (nodes.isEmpty) return false;

  final Node first = nodes.first;
  final Delta? firstDelta = first.delta;
  // 首块是文本 ⇒ 起点必须落在 0；非文本块 offset 无意义。
  if (firstDelta != null && selection.start.offset != 0) return false;

  final Node last = nodes.last;
  final Delta? lastDelta = last.delta;
  // 末块是文本 ⇒ 终点必须到块末尾。
  if (lastDelta != null && selection.end.offset != lastDelta.length) {
    return false;
  }
  return true;
}

/// 复制命令：整块选区时接管，其余交回官方（纯文本）。
///
/// ⚠️ 让行前**清空块剪贴板**：否则"复制块 → 复制一句话 → Ctrl+V"会粘出旧块
/// （系统剪贴板可用时 [BlockClipboard.refresh] 也会纠正，但这层兜底更直接）。
final CommandShortcutEvent sinanBlockCopyCommand = CommandShortcutEvent(
  key: 'sinan.block.copy',
  getDescription: () => '复制块',
  command: 'ctrl+c',
  macOSCommand: 'cmd+c',
  handler: (EditorState editorState) {
    if (!isWholeBlockSelection(editorState)) {
      BlockClipboard.clear();
      return KeyEventResult.ignored;
    }
    BlockClipboard.copy(
      editorState.getNodesInSelection(editorState.selection!.normalized),
      cut: false,
    );
    return KeyEventResult.handled;
  },
);

/// 剪切命令：复制快照 + 删除源块，整块选区时接管。
final CommandShortcutEvent sinanBlockCutCommand = CommandShortcutEvent(
  key: 'sinan.block.cut',
  getDescription: () => '剪切块',
  command: 'ctrl+x',
  macOSCommand: 'cmd+x',
  handler: (EditorState editorState) {
    if (!isWholeBlockSelection(editorState)) {
      BlockClipboard.clear();
      return KeyEventResult.ignored;
    }
    // ⚠️ getSelectedNodes 返回脱离树的副本（copyWith ⇒ parent=null ⇒ path=[]），
    // deleteNode(副本) 删不掉真节点；getNodesInSelection 才是带 path 的真节点。
    final List<Node> nodes = editorState.getNodesInSelection(
      editorState.selection!.normalized,
    );
    BlockClipboard.copy(nodes, cut: true);
    final Transaction transaction = editorState.transaction;
    // 删除后选区必须落回一个**存在的**块：否则选区悬空（path 指向已删块），
    // 后续 Ctrl+V 无处可插、右键菜单判块拿不到节点。落点取"删除位置"（同层
    // 兄弟），删到该层末尾则取前一个；该层被删空则交给框架补段落。
    // ⚠️ 用完整 path 而非 path.first：块可能嵌在列表/引用里。
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

/// 粘贴命令：块剪贴板有内容 ⇒ 插到当前块之后；否则 ignored 回退智能粘贴
/// （剪贴板位图落盘 / 官方文本粘贴，见 `editor_image_paste.dart`）。
final CommandShortcutEvent sinanBlockPasteCommand = CommandShortcutEvent(
  key: 'sinan.block.paste',
  getDescription: () => '粘贴块',
  command: 'ctrl+v',
  macOSCommand: 'cmd+v',
  handler: (EditorState editorState) {
    if (!BlockClipboard.hasContent) return KeyEventResult.ignored;
    final Selection? selection = editorState.selection?.normalized;
    if (selection == null) return KeyEventResult.ignored;
    final List<Node> nodes = BlockClipboard.takeForPaste();
    // 落点 = 当前块之后；越界（选区 path 与文档不同步、或光标本就在末尾块）
    // 夹到合法范围——顶层夹到 children.length，嵌套层夹到父节点的子数。
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
    BlockClipboard.clear();
    return KeyEventResult.handled;
  },
);

// ─── 右键菜单用的"块优先 → 官方回退"组合 ───────────────────────────────
// 命令表里不能自己回退（ignored 后框架会继续试下一个命令，自己回退会执行两遍）；
// 菜单是一次性调用，没有后续命令接力，所以这里显式回退。

KeyEventResult menuCopy(EditorState editorState) {
  if (sinanBlockCopyCommand.handler(editorState) == KeyEventResult.handled) {
    return KeyEventResult.handled;
  }
  BlockClipboard.clear();
  return copyCommand.handler(editorState);
}

KeyEventResult menuCut(EditorState editorState) {
  if (sinanBlockCutCommand.handler(editorState) == KeyEventResult.handled) {
    return KeyEventResult.handled;
  }
  BlockClipboard.clear();
  return cutCommand.handler(editorState);
}

KeyEventResult menuPaste(
  EditorState editorState, {
  KeyEventResult Function(EditorState)? fallback,
}) {
  if (sinanBlockPasteCommand.handler(editorState) == KeyEventResult.handled) {
    return KeyEventResult.handled;
  }
  return (fallback ?? pasteIntoEditor)(editorState);
}
