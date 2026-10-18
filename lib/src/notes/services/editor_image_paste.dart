import 'dart:async';
import 'dart:typed_data';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/widgets.dart';

import '../../editor/toolbar/link_toolbar_item.dart';
import 'note_media_service.dart';

/// 编辑器「智能粘贴」：剪贴板是图 ⇒ 落盘 + 插入 image 块；否则回退原有粘贴
/// （选中文字贴网址转链 / 官方纯文本·富文本粘贴）。
///
/// 为什么必须自己接：官方 appflowy_editor **没有任何图片粘贴实现**——
/// `AppFlowyClipboard` 只读 text/html，桌面也没接 `contentInsertionConfiguration`。
/// 官方唯一给的入口是 `EditorState.insertImageNode(url)`（slash `/图片` 的上传菜单
/// 也走它）。所以图片这一路只能：读剪贴板 → 存媒体文件 → `insertImageNode`。
KeyEventResult pasteIntoEditor(EditorState editorState) {
  unawaited(() async {
    if (await pasteImageFromClipboard(editorState)) return;
    // 不是图 ⇒ 保持原有行为（粘贴 URL 自动转链，否则官方文本粘贴）。
    sinanPasteCommand.handler(editorState);
  }());
  return KeyEventResult.handled;
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
