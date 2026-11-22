import 'dart:async';
import 'dart:typed_data';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/widgets.dart';

import '../../clipboard/clipboard_html.dart';
import '../../editor/toolbar/link_toolbar_item.dart';
import 'note_media_service.dart';

/// 编辑器「智能粘贴」，三级优先：
///
/// 1. **富文本 HTML**（网页/Word 复制）⇒ 官方 `DocumentHTMLDecoder` 还原标题 /
///    列表 / 引用 / 代码 / 表格 / 加粗 / 链接。样式（字体、字号、行高、颜色）
///    一律**丢弃**，按 sinan 自己的排版渲染——见 [pasteHtmlFromClipboard]。
/// 2. **位图**（截图 / 复制单张图）⇒ 落盘 + 插入 image 块（离线可用）。
/// 3. 其余 ⇒ 原有行为（选中文字贴网址转链 / 官方纯文本粘贴）。
///
/// 为什么必须自己接：官方 `AppFlowyClipboard.getData` 只读 `kTextPlain`，
/// `html` 恒为 null（`pasteCommand` 里那段 HTML 分支是死代码）；图片粘贴官方
/// 干脆没有实现。两层都得由这里补上。
KeyEventResult pasteIntoEditor(EditorState editorState) {
  unawaited(() async {
    if (await pasteHtmlFromClipboard(editorState)) return;
    if (await pasteImageFromClipboard(editorState)) return;
    sinanPasteCommand.handler(editorState);
  }());
  return KeyEventResult.handled;
}

/// 剪贴板里若是富文本：交给官方 HTML→块 解析器，返回 true（否则 false）。
///
/// **样式归零**：`DocumentHTMLDecoder` 只认语义标签（`h1~h6` / `ul` / `ol` /
/// `blockquote` / `pre` / `table` / `strong` / `em` / `a` / `code`…），本身不解析
/// `font-family` / `font-size` / `line-height`；颜色由 `enableColorParse` 控制，
/// 这里显式关掉 ⇒ 从网页粘过来的内容不会把外部配色/字号带进笔记。
Future<bool> pasteHtmlFromClipboard(EditorState editorState) async {
  final String? html = await readClipboardHtml();
  if (html == null || html.trim().isEmpty) return false;
  return pasteHtmlText(editorState, html);
}

/// 把一段 HTML 按 sinan 的块模型粘进编辑器（与读剪贴板解耦，便于单测）。
///
/// 样式一律重映射为 sinan 自己的排版：`DocumentHTMLDecoder` 不解析字号/字体/
/// 行高，颜色由 `enableColorParse` 关掉。
Future<bool> pasteHtmlText(EditorState editorState, String html) async {
  if (html.trim().isEmpty) return false;
  final Selection? selection = editorState.selection;
  if (selection == null) return false;

  try {
    DocumentHTMLDecoder.enableColorParse = false;
    // 官方 decoder 没有 code 块解析器，<pre> 会被整段丢弃 ⇒ 先降级成 <p>。
    final String normalized = normalizeHtmlForPaste(html);
    // 只有一张图（复制网页里的单张图片）⇒ 让位给位图路径：位图会落盘成
    // 本地文件（离线可用），而 HTML 里的 <img src=http…> 只是外链。
    final List<Node> nodes = htmlToDocument(normalized).root.children.toList();
    // 裁掉首尾空段落（HTML 的 <p></p> 会产出空块，粘进来就是多余空行）。
    while (nodes.isNotEmpty &&
        nodes.first.delta?.isEmpty == true &&
        nodes.first.children.isEmpty) {
      nodes.removeAt(0);
    }
    while (nodes.isNotEmpty &&
        nodes.last.delta?.isEmpty == true &&
        nodes.last.children.isEmpty) {
      nodes.removeLast();
    }
    if (nodes.isEmpty) return false;
    if (nodes.length == 1 && nodes.single.type == ImageBlockKeys.type) {
      return false;
    }
    return await _insertPastedNodes(editorState, nodes);
  } on Object {
    // 畸形 HTML 不该让粘贴整体失败——交给后面的位图/纯文本分支。
    return false;
  }
}

/// 把解析好的节点插到当前光标处，返回是否成功。
///
/// 语义对齐官方 `pasteHtml`（那是库内私有 unnamed extension，跨库不可见，
/// 只能用公开 API 复刻）：
/// - **单个段落** ⇒ 内容合并进当前光标位置（不新起块），行内属性（加粗/链接）
///   逐段保留；
/// - **其余情况**（标题/列表/表格/多块）⇒ 在光标块之后插入，保留块类型与结构。
Future<bool> _insertPastedNodes(
  EditorState editorState,
  List<Node> nodes,
) async {
  final Selection? selection = await editorState.deleteSelectionIfNeeded();
  if (selection == null) return false;
  final Path cursorPath = selection.end.path;
  final Node? cursorNode = editorState.getNodeAtPath(cursorPath);

  // ⚠️ 不能用 nodes.single：多块时会抛（被外层 catch 吞成"粘贴失败"）。
  final bool mergeIntoLine = nodes.length == 1 &&
      nodes.first.type == ParagraphBlockKeys.type &&
      nodes.first.delta != null &&
      cursorNode?.delta != null;

  final Transaction transaction = editorState.transaction;
  if (mergeIntoLine) {
    // 逐段插入，保留行内属性（加粗/斜体/链接/行内代码）。
    final Node target = cursorNode!;
    int index = selection.end.offset;
    for (final TextOperation op in nodes.first.delta!) {
      if (op is! TextInsert || op.text.isEmpty) continue;
      transaction.insertText(
        target,
        index,
        op.text,
        attributes: op.attributes,
      );
      index += op.text.length;
    }
    transaction.afterSelection = Selection.collapsed(
      Position(path: cursorPath, offset: index),
    );
  } else {
    final Path insertAt = cursorPath.next;
    transaction
      ..insertNodes(insertAt, nodes)
      ..afterSelection = Selection.collapsed(Position(path: insertAt));
  }
  await editorState.apply(transaction);
  return true;
}

/// 剪贴板里若是图片：存进媒体目录并插入 image 块，返回 true（否则 false）。
///
/// 落盘走 [NoteMediaService.saveBytes]：与「选图导入」同一目录、同一命名，
/// 笔记保持自包含（源截图被删也不影响）。
Future<bool> pasteImageFromClipboard(EditorState editorState) async {
  final Selection? selection = editorState.selection;
  if (selection == null) return false;
  final Uint8List? bytes = await NoteMediaService.readClipboardImage();
  if (bytes == null) return false;
  final String path = await NoteMediaService.saveBytes(bytes);
  // 与官方 `doPaste` 一致：插图前先 `deleteSelectionIfNeeded()`——有选区就把
  // 选区内容删掉并折叠（贴图替换选中的文字），`insertImageNode` 只认折叠光标。
  if (await editorState.deleteSelectionIfNeeded() == null) return false;
  await editorState.insertImageNode(path);
  return true;
}

/// Ctrl / Cmd + V 的替代命令：先试图片，再回退原有粘贴。
/// 与 `sinanPasteCommand` 同 key，视图侧用它替换后者（官方 `pasteCommand`
/// 已从标准表摘掉，避免两条 Ctrl+V 并存）。
final CommandShortcutEvent sinanPasteWithImageCommand = CommandShortcutEvent(
  key: 'sinan.paste',
  getDescription: () => '粘贴',
  command: 'ctrl+v',
  macOSCommand: 'cmd+v',
  handler: pasteIntoEditor,
);
