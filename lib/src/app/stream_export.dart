import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/note.dart';
import '../editor/blocks/note_picker.dart';
import '../editor/blocks/reference_to_canvas.dart';
import 'providers.dart';

/// 心流导出（**单向：心流 → 笔记 / 画布**）的交互入口。
///
/// 三种语义（2026-10-16 用户定）：
/// - **引用**（活链）：目标里插 `ref` 块 / 画布卡**指向**该心流块——块**留在心流**，
///   两边同一份真身，`backlinks` 自动记「这条灵感被哪几篇用了」；
/// - **注入**（快照）：把文本**复制**成目标里的一个真段落块——块留在心流，互不影响；
/// - **转新**（消耗）：建成一篇新笔记，心流条目随之删除。
///
/// 心流**永不反向读**用户笔记：这里只写目标 / 建新篇，不回读用户内容。
/// 「引用到画布」直接复用编辑器的 [referenceBlockToCanvas]（它本就是「把一块引用到
/// 画布上、块原地不动」——心流块带了 `text` 投影，它的读口认）。

/// 引用到**笔记**（活链）：选一篇文档笔记，在它块树里插 `ref` 块指向这条心流。
Future<void> referenceStreamBlockToNote({
  required BuildContext context,
  required String blockId,
}) async {
  final ProviderContainer container = ProviderScope.containerOf(
    context,
    listen: false,
  );
  final store = container.read(noteStoreProvider);
  final String? target = await pickNoteToReference(
    context,
    docsOnly: true,
    dialogTitle: '引用到哪篇笔记',
  );
  if (target == null || !context.mounted) return;
  final bool ok = store.referenceStreamBlockInNote(blockId, target);
  _toast(context, ok ? '已引用（活链，改心流这边会同步）' : '这篇笔记已经引用过它了');
}

/// 注入到**笔记**（快照）：选一篇文档笔记，把文本复制成它的一个真段落块。
Future<void> injectStreamBlockToNote({
  required BuildContext context,
  required String blockId,
}) async {
  final ProviderContainer container = ProviderScope.containerOf(
    context,
    listen: false,
  );
  final store = container.read(noteStoreProvider);
  final String? target = await pickNoteToReference(
    context,
    docsOnly: true,
    dialogTitle: '注入到哪篇笔记',
  );
  if (target == null || !context.mounted) return;
  final bool ok = store.injectStreamBlockInNote(blockId, target);
  if (ok) {
    // 目标正文变了 ⇒ 文库快照重读（卡片摘要要更新）。
    container.invalidate(notesProvider);
  }
  _toast(context, ok ? '已注入（快照副本，互不影响）' : '注入失败：目标不是可写的文档笔记');
}

/// **转成新笔记**（消耗）：建一篇正式笔记装上这段文本，心流条目随之删除。
Future<void> streamBlockToNewNote({
  required BuildContext context,
  required String blockId,
}) async {
  final ProviderContainer container = ProviderScope.containerOf(
    context,
    listen: false,
  );
  final store = container.read(noteStoreProvider);
  final Note? created = store.streamBlockToNewNote(blockId);
  if (created == null) {
    if (context.mounted) _toast(context, '转换失败：找不到这条心流');
    return;
  }
  // 心流少了一条 + 文库多了一篇 ⇒ 两个列表都重读。
  container.invalidate(streamProvider);
  container.invalidate(notesProvider);
  if (context.mounted) _toast(context, '已转成新笔记，心流里已清掉这条');
}

void _toast(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
      ?.showSnackBar(SnackBar(content: Text(message)));
}
