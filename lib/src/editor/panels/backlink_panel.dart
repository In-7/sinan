import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/providers.dart';
import '../../domain/backlink.dart';
import '../../domain/note.dart';
import '../../theme/tokens.dart';

/// 反链面板：**谁引用了我**（双链的读侧）。
///
/// 数据来自 [NoteStore.backlinks]，它把指向本笔记的两类边合起来：
/// 别的笔记里的 `ref` 块、画布上的卡片（见 `domain/backlink.dart`）。
///
/// ## 为什么是 ConsumerWidget 而不是宿主把数据传进来
/// 面板**只在打开时挂载**，所以它可以放心 `watch(notesProvider)`：任何笔记内容
/// 变化（= 可能新增/删除引用）都会让它重算。宿主若为了同样效果去 watch 列表，
/// 整个编辑器都会被重建 —— 那正是本仓库明确避开的做法（见编辑器里
/// `ref.listen` 而非 `watch` 的那条注释）。
class BacklinkPanel extends ConsumerWidget {
  const BacklinkPanel({
    super.key,
    required this.noteId,
    required this.onOpenNote,
  });

  /// 面板宽度（浮层用；与目录气泡同档）。
  static const double width = 240;

  /// 查谁的引文。
  final String noteId;

  /// 点条目 → 打开来源笔记。
  final ValueChanged<String> onOpenNote;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 内容保存后列表快照会换一份 ⇒ 重建本面板（只在打开期间，成本可控）。
    ref.watch(notesProvider);
    // 类型由 provider 推断（本层不 import `data/`，见架构闸门）。
    final store = ref.read(noteStoreProvider);
    final List<Backlink> links = store.backlinks(noteId);

    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return SizedBox(
      width: width,
      child: Column(
        // 高度自适应内容（气泡用法）：条目少就贴着内容收短，多了才在给定的
        // maxHeight 内滚动。列表用 Flexible（松 fit）—— Expanded 是紧 fit，
        // 会把面板撑满约束上限，气泡底部留一大截白。
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Tokens.spaceMd,
              Tokens.spaceMd,
              Tokens.spaceMd,
              Tokens.spaceXs,
            ),
            child: Text(
              '反链',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                letterSpacing: 1,
              ),
            ),
          ),
          Flexible(
            child: links.isEmpty
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(
                      Tokens.spaceMd,
                      Tokens.spaceXs,
                      Tokens.spaceMd,
                      Tokens.spaceMd,
                    ),
                    child: Text(
                      '还没有笔记引用这里。\n在别处输入「/引用笔记」就能建立链接。',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        for (final Backlink b in links) _row(context, b),
                        const SizedBox(height: Tokens.spaceXs),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, Backlink b) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool canvas = b.sourceKind == NoteKind.canvas;
    return InkWell(
      onTap: () => onOpenNote(b.sourceNoteId),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Tokens.spaceMd,
          vertical: Tokens.spaceXs,
        ),
        child: Row(
          children: <Widget>[
            Icon(
              canvas ? LucideIcons.layoutDashboard300 : LucideIcons.fileText300,
              size: Tokens.iconSm,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: Tokens.spaceSm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    b.sourceTitle.trim().isEmpty ? '未命名笔记' : b.sourceTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14),
                  ),
                  // 说清"怎么引用的"：画布卡片 / 文档里的引用块 —— 两者的后续
                  // 操作完全不同（前者去画布上找卡片，后者去正文里找那一行）。
                  Text(
                    b.viaCanvasCard ? '画布卡片' : '引用块',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  // 上下文：光有来源标题看不出"它为什么引用我"，这一句是判断
                  // 要不要点进去的唯一依据（Roam / Logseq 的反链都带它）。
                  if (b.context.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        b.context,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.4,
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
