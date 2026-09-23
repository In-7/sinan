import 'package:flutter/material.dart';
import 'dart:ui' as ui;
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;
import 'package:flutter_riverpod/flutter_riverpod.dart';import '../../app/providers.dart';
import '../../domain/note.dart';
import '../../theme/tokens.dart';

/// 弹「选一篇笔记」对话框，返回所选笔记 id（取消 → null）。
///
/// 双链在**文档侧的创建入口**（斜杠菜单「引用笔记」调它）。引用存的是 **id**
/// 而不是标题，所以这里只需要把 id 带回去 —— 目标日后改名不会断链，被删则显示
/// "引用已失效"（见 `RefBlockKeys`）。
///
/// [excludeId] 用来排掉"正在编辑的这篇"：引用自己几乎总是误操作。
Future<String?> pickNoteToReference(
  BuildContext context, {
  String? excludeId,
}) async {
  final ProviderContainer container =
      ProviderScope.containerOf(context, listen: false);
  // 类型由 provider 推断：本层**不 import `data/`**（架构闸门要求经 DI 取 store，
  // 见 test/architecture/architecture_test.dart）。
  final store = container.read(noteStoreProvider);
  // 列表优先取 provider 快照；它还没装载完时**直接查库兜底**（同步，不引入等待）。
  final List<Note> all =
      container.read(notesProvider).value ?? store.allNotes();
  final List<Note> candidates = <Note>[
    for (final Note n in all)
      if (n.id != excludeId) n,
  ];

  if (!context.mounted) return null;
  if (candidates.isEmpty) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('还没有别的笔记可以引用 —— 先新建一篇')),
    );
    return null;
  }
  return showDialog<String>(
    context: context,
    builder: (BuildContext ctx) => _NotePickerDialog(candidates: candidates),
  );
}

/// 笔记选择框：标题筛选 + 列表（画布与文档同列，用图标区分）。
///
/// 带筛选框是因为笔记一多，纯列表找起来比打字慢得多；这里只按标题匹配
/// （正文匹配是搜索的活，不是选择器的活）。
class _NotePickerDialog extends StatefulWidget {
  const _NotePickerDialog({required this.candidates});

  final List<Note> candidates;

  @override
  State<_NotePickerDialog> createState() => _NotePickerDialogState();
}

class _NotePickerDialogState extends State<_NotePickerDialog> {
  final TextEditingController _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  List<Note> get _hits {
    final String q = _filter.text.trim().toLowerCase();
    if (q.isEmpty) return widget.candidates;
    return <Note>[
      for (final Note n in widget.candidates)
        if (n.title.toLowerCase().contains(q)) n,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<Note> hits = _hits;
    return AlertDialog(
      title: const Text('引用笔记'),
      content: SizedBox(
        width: 360,
        height: 380,
        child: Column(
          children: <Widget>[
            TextField(
              controller: _filter,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '按标题筛选',
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: hits.isEmpty
                  ? Align(
                      alignment: Alignment.topLeft,
                      child: Text(
                        '没有匹配的笔记',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    )
                  : ListView.builder(
                      itemCount: hits.length,
                      itemBuilder: (BuildContext ctx, int i) {
                        final Note n = hits[i];
                        return ListTile(
                          dense: true,
                          leading: tabler.LayoutDashboard(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5, colorFilter: ui.ColorFilter.mode(scheme.onSurfaceVariant, ui.BlendMode.srcIn)),
                          title: Text(
                            n.title.trim().isEmpty ? '未命名笔记' : n.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => Navigator.of(ctx).pop(n.id),
                        );
                      },
                    ),
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
