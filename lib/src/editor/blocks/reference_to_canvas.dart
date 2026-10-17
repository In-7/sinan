import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/note.dart';

/// 块可迁移 #5「双链多视图」（反向：文档 → 画布）的交互入口。
///
/// 把文档里的一**块**引用到画布上：文档里那块**原地不动**（不摘除），画布上多一张
/// 指向同一份内容的卡片 —— 两边编辑的是同一个 `blocks` 行。
///
/// 没有画布笔记时提示先建一张；只有一张画布时直接用它，多张则弹选择框。
Future<void> referenceBlockToCanvas({
  required BuildContext context,
  required String blockId,
}) async {
  final ProviderContainer container = ProviderScope.containerOf(
    context,
    listen: false,
  );
  // 类型由 provider 推断（本层不 import `data/`，见架构闸门）。
  final store = container.read(noteStoreProvider);
  final String? target = await pickCanvasToTarget(
    context,
    dialogTitle: '引用到画布',
    emptyHint: '还没有画布笔记 —— 先新建一张画布，再回来引用',
  );
  if (target == null || !context.mounted) return;

  final bool added = store.referenceBlockOnCanvas(blockId, target);
  if (!context.mounted) return;
  _toast(context, added ? '已在画布上引用这张卡片' : '这张卡片已经在画布上了');
}

/// 选一张画布（只有一张就直接用）。速记导出与块引用共用同一套选择口径。
///
/// 返回 `null` = 用户取消 / 没有画布（已弹提示）。
Future<String?> pickCanvasToTarget(
  BuildContext context, {
  String dialogTitle = '选择画布',
  String emptyHint = '还没有画布笔记 —— 先新建一张画布',
}) async {
  final ProviderContainer container = ProviderScope.containerOf(
    context,
    listen: false,
  );
  final store = container.read(noteStoreProvider);
  // 列表优先取 provider 的快照；它还没装载完时**直接查库兜底** —— 否则会误报
  // "还没有画布笔记"（明明有）。`allNotes()` 是同步的，兜底不引入等待。
  final List<Note> all =
      container.read(notesProvider).value ?? store.allNotes();
  final List<Note> canvases = <Note>[
    for (final Note n in all)
      if (n.kind == NoteKind.canvas) n,
  ];
  if (!context.mounted) return null;
  if (canvases.isEmpty) {
    _toast(context, emptyHint);
    return null;
  }
  if (canvases.length == 1) return canvases.first.id;
  return showDialog<String>(
    context: context,
    builder: (BuildContext ctx) =>
        _CanvasPickerDialog(canvases: canvases, title: dialogTitle),
  );
}

void _toast(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
      ?.showSnackBar(SnackBar(content: Text(message)));
}

/// 「引用到哪张画布？」—— 仅在有多张画布时才弹。
class _CanvasPickerDialog extends StatelessWidget {
  const _CanvasPickerDialog({required this.canvases, this.title = '引用到画布'});

  final List<Note> canvases;
  final String title;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 320,
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            for (final Note c in canvases)
              ListTile(
                title: Text(c.title.trim().isEmpty ? '未命名画布' : c.title),
                onTap: () => Navigator.of(context).pop(c.id),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
