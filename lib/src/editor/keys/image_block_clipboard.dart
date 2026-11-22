import 'dart:async' show unawaited;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;

import '../../clipboard/block_clipboard_transport.dart';
import '../../clipboard/clipboard_codec.dart';

/// **块剪贴板**：图片块的复制 / 剪切 / 粘贴。
///
/// ## 为什么不能直接用官方复制
/// `copyCommand` 只取 text + html，`AppFlowyClipboard.setData` 在
/// `text == null`（图片块没有 delta）时**直接 return** ⇒ 图片块复制是空操作。
///
/// ## 双通道设计（2026-11-22 第二版）
/// - **系统剪贴板**（优先）：把块载荷写进自定义格式（Windows 注册格式 /
///   macOS UTI，见 `lib/src/clipboard/`），同时挂纯文本与位图给外部应用。
///   ⇒ 重启后仍能粘、能粘到别的应用、外部复制会覆盖它（不存在"粘出旧图片"）。
/// - **内存剪贴板**（回落）：平台不支持自定义格式（Linux/Web）或写入失败时，
///   用进程内快照，行为与上一版一致。
///
/// 两条通道共用同一份 [ClipboardCodec] 协议。
abstract final class ImageBlockClipboard {
  /// 平台层（可注入假实现做单测）。
  static BlockClipboardTransport transport = createClipboardTransport();

  /// 内存回落。
  static final List<Node> _memory = <Node>[];

  /// 系统剪贴板读取缓存：读是异步的，而命令 handler 是同步的。
  ///
  /// 复制/剪切时同步写入，粘贴时直接命中；[refresh] 在编辑器聚焦/打开笔记时
  /// 异步从系统剪贴板回填（覆盖"重启后粘贴"）。
  static List<Node>? _cached;

  /// 当前是否有可粘贴的图片块（同步判定，供命令 handler 用）。
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

  /// 从系统剪贴板回填缓存（编辑器打开/聚焦时调用）。
  ///
  /// 读到块载荷 ⇒ 覆盖缓存；读不到 ⇒ 清空缓存（外部复制了别的东西）。
  /// 这样"内存里还留着旧图片块"的污染问题在系统剪贴板可用时自然消失。
  static Future<void> refresh() async {
    if (!transport.isSupported) return;
    final String? payload = await transport.read();
    if (payload == null) {
      _cached = null;
      _memory.clear();
      return;
    }
    final List<Node>? nodes = ClipboardCodec.decode(payload);
    if (nodes == null) {
      _cached = null;
      _memory.clear();
      return;
    }
    _cached = nodes;
    _memory
      ..clear()
      ..addAll(nodes);
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
