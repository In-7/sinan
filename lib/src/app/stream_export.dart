import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/note.dart';
import '../editor/blocks/note_picker.dart';
import '../editor/blocks/reference_to_canvas.dart';
import 'providers.dart';

/// 速记（心流）导出：**单向，速记 → 笔记 / 画布**（2026-10-17 重定）。
///
/// 三种语义：
/// - **引用**（活链）：笔记里插 `ref` 块（`ref_type='stream'`）指向这条速记。
///   只有笔记读速记，速记永不回读；删速记后引用处显示「已失效」，笔记内容不丢。
/// - **复制**（快照）：笔记里插段落块 / 画布上建独立卡片，此后互不相干。
/// - **转新**（归档）：建成一篇新笔记，速记条目**归档**（不删，可回看）。
///
/// 画布**不做活链**（同日定）：卡片必须有自己的块，速记更新不推过去。
/// 心流从不读笔记 / 画布正文——这里的对话框只列标题让你选目标。

/// 引用到**笔记**（活链）：选一篇文档笔记，在它块树里插 `ref` 块。
Future<void> referenceStreamToNote({
  required BuildContext context,
  required String streamId,
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
  final bool ok = store.referenceStreamInNote(streamId, target);
  if (ok) container.invalidate(notesProvider);
  _toast(context, ok ? '已引用（改速记会同步显示）' : '这篇笔记已经引用过它了');
}

/// 复制到**笔记**（快照）：把文本复制成目标里的一个真段落块。
Future<void> copyStreamToNote({
  required BuildContext context,
  required String streamId,
}) async {
  final ProviderContainer container = ProviderScope.containerOf(
    context,
    listen: false,
  );
  final store = container.read(noteStoreProvider);
  final String? target = await pickNoteToReference(
    context,
    docsOnly: true,
    dialogTitle: '复制到哪篇笔记',
  );
  if (target == null || !context.mounted) return;
  final bool ok = store.copyStreamIntoNote(streamId, target);
  if (ok) container.invalidate(notesProvider);
  _toast(context, ok ? '已复制（快照，之后互不影响）' : '复制失败：目标不是可写的文档笔记');
}

/// 复制到**画布**（快照卡）：新建一张独立卡片，速记之后与它无关。
Future<void> copyStreamToCanvas({
  required BuildContext context,
  required String streamId,
}) async {
  final ProviderContainer container = ProviderScope.containerOf(
    context,
    listen: false,
  );
  final store = container.read(noteStoreProvider);
  final String? target = await pickCanvasToTarget(
    context,
    dialogTitle: '复制到哪张画布',
    emptyHint: '还没有画布笔记 —— 先新建一张画布，再回来复制',
  );
  if (target == null || !context.mounted) return;
  final bool ok = store.copyStreamOntoCanvas(streamId, target);
  _toast(context, ok ? '已复制成独立卡片（与速记再无关联）' : '复制失败：目标不是画布');
}

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
  // 速记少了一条（进归档）+ 文库多了一篇 ⇒ 两个列表都重读。
  container.invalidate(streamProvider);
  container.invalidate(notesProvider);
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
  if (context.mounted) _toast(context, '已建成新画布，速记已归档');
}

/// **合并成一篇新笔记**（多选）：按时间顺序拼起来，参与的都归档。
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
  container.invalidate(streamProvider);
  container.invalidate(notesProvider);
  if (context.mounted) _toast(context, '已合并成新笔记（${streamIds.length} 条已归档）');
}

void _toast(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
      ?.showSnackBar(SnackBar(content: Text(message)));
}
