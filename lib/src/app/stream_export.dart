import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/note.dart';
import 'providers.dart';

/// 速记（心流）导出：**单向，速记 → 笔记 / 画布**（2026-10-17 重定）。
///
/// 保留两种语义：
/// - **转新**：建成一篇新笔记 / 新画布（**归档**源速记）。
/// - **合并**：多条按时间拼成一篇新笔记（**不归档**：合并只是整理，条目仍留在
///   心流里，等真正使用再归档 —— 2026-10-18 用户定）。
///
/// 复制到笔记 / 画布的 UI 入口已撤（2026-10-18 用户定）：心流卡片的「复制」
/// 改为直接写系统剪贴板，用户爱贴哪贴哪。后端 `NoteStore.copyStreamIntoNote`
/// / `copyStreamOntoCanvas` 仍保留（能力不删）。
/// 引用（活链）的 UI 入口同样已撤；后端 `referenceStreamInNote` 仍在。

/// **转成新笔记**（归档）：建一篇正式笔记装上这段文本，速记条目归档。
Future<void> streamToNewNote({
  required BuildContext context,
  required String streamId,
}) async {
  final ProviderContainer container = ProviderScope.containerOf(
    context,
    listen: false,
  );
  final store = container.read(noteStoreProvider);
  final Note? created = store.streamToNewNote(streamId);
  if (created == null) {
    if (context.mounted) _toast(context, '转换失败：找不到这条速记');
    return;
  }
  // 速记少了一条（进归档）+ 文库多了一篇 ⇒ 三个列表都重读（含处理台账）。
  container.invalidate(streamProvider);
  container.invalidate(notesProvider);
  container.invalidate(streamExportsProvider);
  if (context.mounted) _toast(context, '已转成新笔记，速记已归档');
}

/// **转成新画布**（归档）：新建一张画布 + 一张卡片，速记归档。
Future<void> streamToNewCanvas({
  required BuildContext context,
  required String streamId,
}) async {
  final ProviderContainer container = ProviderScope.containerOf(
    context,
    listen: false,
  );
  final store = container.read(noteStoreProvider);
  final Note? created = store.streamToNewCanvas(streamId);
  if (created == null) {
    if (context.mounted) _toast(context, '转换失败：找不到这条速记');
    return;
  }
  container.invalidate(streamProvider);
  container.invalidate(notesProvider);
  container.invalidate(streamExportsProvider);
  if (context.mounted) _toast(context, '已建成新画布，速记已归档');
}

/// **合并成一篇新笔记**（多选）：按时间顺序拼起来，**不归档**（条目仍留在心流）。
Future<void> mergeStreamToNewNote({
  required BuildContext context,
  required List<String> streamIds,
}) async {
  if (streamIds.isEmpty) return;
  final ProviderContainer container = ProviderScope.containerOf(
    context,
    listen: false,
  );
  final store = container.read(noteStoreProvider);
  final Note? created = store.streamMergeToNewNote(streamIds);
  if (created == null) {
    if (context.mounted) _toast(context, '合并失败：没有可用的速记');
    return;
  }
  // 合并**不归档**（2026-10-18 用户定）：心流列表不变，只多一篇笔记 + 台账一行。
  container.invalidate(notesProvider);
  container.invalidate(streamExportsProvider);
  if (context.mounted) _toast(context, '已合并成新笔记（${streamIds.length} 条）');
}

void _toast(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
      ?.showSnackBar(SnackBar(content: Text(message)));
}
