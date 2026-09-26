import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/note.dart';
import 'hub_nav.dart' show SpaceItemRow;
import 'providers.dart'
    show NotesNotifier, locateProvider, notesProvider, selectedNoteIdProvider;
import 'undo_toast.dart' show showUndoToast;
import '../theme/tokens.dart';

/// 收藏页（主区分区 [kFavoritesNavIndex]）：把跨形态（笔记 / 画布）的收藏笔记
/// 聚合成一页。复�?[SpaceItemRow]（与导航板内联列表同款行），只换数据�?
/// ——按 [Note.promotedAt] 过滤，两类形态都收�?
class FavoritesSection extends ConsumerWidget {
  const FavoritesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<Note> all = ref.watch(notesProvider).value ?? const <Note>[];
    final String? openId = ref.watch(selectedNoteIdProvider);

    // 跨形态拆两栏：笔记（spark/note�? 画布（canvas），都按收藏时间倒序�?
    final List<Note> noteItems =
        all
            .where(
              (Note n) => n.promotedAt != null && n.kind != NoteKind.canvas,
            )
            .toList()
          ..sort((Note a, Note b) => b.promotedAt!.compareTo(a.promotedAt!));
    final List<Note> canvasItems =
        all
            .where(
              (Note n) => n.promotedAt != null && n.kind == NoteKind.canvas,
            )
            .toList()
          ..sort((Note a, Note b) => b.promotedAt!.compareTo(a.promotedAt!));

    if (noteItems.isEmpty && canvasItems.isEmpty) {
      return Center(
        child: Text(
          '还没有收�?,
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }

    // 删除 + 可撤销提示（与 [SpaceItemList] 同一�?[showUndoToast] 通道）�?
    Future<void> deleteNote(Note note) async {
      final NotesNotifier notifier = ref.read(notesProvider.notifier);
      final Note? removed = await notifier.deleteNote(note.id);
      if (removed == null || !context.mounted) return;
      final String title = removed.title.isNotEmpty ? removed.title : '无标�?;
      showUndoToast(
        context,
        message: '已删除�?title�?,
        onUndo: () => notifier.restoreNote(removed),
      );
    }

    // 单栏：栏头（标题 + 数量�? 可滚动列�?/ 各自空态。行上标出形态图标�?
    Widget columnFor(String title, List<Note> items) {
      final bool isCanvas = title == '画布';
      return Column(
        crossAxisAlignment: .stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Tokens.spaceLg,
              Tokens.spaceMd,
              0,
              Tokens.spaceSm,
            ),
            child: Text(
              items.isEmpty ? title : '$title  ${items.length}',
              style: theme.textTheme.titleLarge?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: .w500,
              ),
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Text(
                      isCanvas ? '还没有收藏的画布' : '还没有收藏的笔记',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: items.length,
                    itemBuilder: (BuildContext _, int i) => SpaceItemRow(
                      note: items[i],
                      open: items[i].id == openId,
                      onTap: () => ref
                          .read(locateProvider.notifier)
                          .locate(noteId: items[i].id),
                      // 右键 / 「···」菜单三件事，与导航板列表项同源�?
                      // 重命�?/ 收藏 / 删除�?
                      onRename: (String t) => ref
                          .read(notesProvider.notifier)
                          .saveTitle(items[i].id, t),
                      onTogglePromoted: () => ref
                          .read(notesProvider.notifier)
                          .togglePromoted(items[i]),
                      onDelete: () => deleteNote(items[i]),
                      // 2026-09-26 定：行上额外标出画布 / 笔记形态图标�?
                      showKindIcon: true,
                    ),
                  ),
          ),
        ],
      );
    }

    // 响应式：宽屏左右两栏（≥720），窄屏上下堆叠。纯留白 + 栏头，无分隔�?面板�?
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Tokens.spaceLg,
        vertical: Tokens.spaceSm,
      ),
      child: LayoutBuilder(
        builder: (BuildContext _, BoxConstraints constraints) {
          if (constraints.maxWidth >= 720) {
            return Row(
              children: <Widget>[
                Expanded(child: columnFor('笔记', noteItems)),
                const SizedBox(width: Tokens.spaceLg),
                Expanded(child: columnFor('画布', canvasItems)),
              ],
            );
          }
          return Column(
            children: <Widget>[
              Expanded(child: columnFor('笔记', noteItems)),
              const SizedBox(height: Tokens.spaceLg),
              Expanded(child: columnFor('画布', canvasItems)),
            ],
          );
        },
      ),
    );
  }
}
