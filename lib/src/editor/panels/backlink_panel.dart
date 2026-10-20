import 'package:flutter/material.dart';

import 'dart:ui' as ui;

import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/backlink.dart';
import '../../theme/tokens.dart';

/// 反链面板：**谁引用了我**（双链的读侧）。
///
/// 数据来自 [NoteStore.backlinks]，它把指向本笔记的两类结构化边合起来：
/// 别的笔记里的 `ref` 块、画布上的卡片（见 `domain/backlink.dart`）。
///
/// 2026-10-18 起多一段 **「来自灵感」**：灵感的「复制 / 引用 / 转新 / 合并」都记在
/// 台账 `stream_exports` 里，而**复制是快照、没有结构化边**——不反过来读，复制进
/// 本篇的灵感就永久失联，双链只剩一半（见 [NoteStore.streamSourcesOf]）。
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
    required this.onOpenStream,
  });

  /// 面板宽度（浮层用；与目录气泡同档）。
  static const double width = 240;

  /// 查谁的引文。
  final String noteId;

  /// 点条目 → 打开来源笔记。
  final ValueChanged<String> onOpenNote;

  /// 点「来自灵感」那一条 → 灵感页定位该灵感（双链的灵感侧出口）。
  final ValueChanged<String> onOpenStream;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 内容保存后列表快照会换一份 ⇒ 重建本面板（只在打开期间，成本可控）。
    ref.watch(notesProvider);
    // 类型由 provider 推断（本层不 import `data/`，见架构闸门）。
    final store = ref.read(noteStoreProvider);
    final List<Backlink> links = store.backlinks(noteId);
    // **来自灵感**：复制是快照、没有结构化边，这份关系只存在于台账里
    // （见 [NoteStore.streamSourcesOf]）⇒ 双链的另一半在此补齐。
    final List<StreamSource> sources = store.streamSourcesOf(noteId);

    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool empty = links.isEmpty && sources.isEmpty;

    return SizedBox(
      width: width,
      // ⚠️ 与 [TagsPanel] 同一条自保：本面板挂在**根 Overlay** 的气泡里，
      // InkWell 要求 Material 祖先——不补这块直接炸 "No Material widget found"
      // （tags_panel 2026-09-26 实机踩过）。透明型 Material 只提供墨水/焦点
      // 基础设施、不画底，浮层底色仍由外层的 AppFloatSurface 负责。
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          // 高度自适应内容（气泡用法）：条目少就贴着内容收短，多了才在给定的
          // maxHeight 内滚动。列表用 Flexible（松 fit）—— Expanded 是紧 fit，
          // 会把面板撑满约束上限，气泡底部留一大截白。
          mainAxisSize: .min,
          crossAxisAlignment: .stretch,
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
              child: empty
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(
                        Tokens.spaceMd,
                        Tokens.spaceXs,
                        Tokens.spaceMd,
                        Tokens.spaceMd,
                      ),
                      child: Text(
                        '还没有笔记引用这里。\n在别处输入「引用笔记」就能建立链接',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      child: Column(
                        mainAxisSize: .min,
                        crossAxisAlignment: .stretch,
                        children: <Widget>[
                          for (final Backlink b in links) _row(context, b),
                          // 灵感单独一段：它与 ref 反链不是同一种边（快照 vs 活链），
                          // 混在一锅会让人以为点进去是同一回事。
                          if (sources.isNotEmpty) ...<Widget>[
                            _sectionLabel('来自灵感', theme, scheme),
                            for (final StreamSource s in sources)
                              _streamRow(context, s),
                          ],
                          const SizedBox(height: Tokens.spaceXs),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text, ThemeData theme, ColorScheme scheme) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(
          Tokens.spaceMd,
          Tokens.spaceSm,
          Tokens.spaceMd,
          Tokens.spaceXxs,
        ),
        child: Text(
          text,
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
            letterSpacing: 1,
          ),
        ),
      );

  /// 一条灵感反链：原文首行 + 手法。点它 → 灵感页定位那一条。
  Widget _streamRow(BuildContext context, StreamSource s) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String first = s.text.trim().split('\n').first.trim();
    return InkWell(
      onTap: () => onOpenStream(s.streamId),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Tokens.spaceMd,
          vertical: Tokens.spaceXs,
        ),
        child: Row(
          children: <Widget>[
            tabler.Inbox(
              height: Tokens.iconMd,
              width: Tokens.iconMd,
              strokeWidth: 1.5,
              colorFilter: ui.ColorFilter.mode(
                scheme.onSurfaceVariant,
                ui.BlendMode.srcIn,
              ),
            ),
            const SizedBox(width: Tokens.spaceSm),
            Expanded(
              child: Column(
                crossAxisAlignment: .start,
                mainAxisSize: .min,
                children: <Widget>[
                  Text(
                    first.isEmpty ? '（空灵感）' : first,
                    maxLines: 2,
                    overflow: .ellipsis,
                    style: theme.textTheme.bodyLarge,
                  ),
                  Text(
                    s.kind.label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
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

  Widget _row(BuildContext context, Backlink b) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => onOpenNote(b.sourceNoteId),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Tokens.spaceMd,
          vertical: Tokens.spaceXs,
        ),
        child: Row(
          children: <Widget>[
            tabler.LayoutDashboard(
              height: Tokens.iconMd,
              width: Tokens.iconMd,
              strokeWidth: 1.5,
              colorFilter: ui.ColorFilter.mode(
                scheme.onSurfaceVariant,
                ui.BlendMode.srcIn,
              ),
            ),
            const SizedBox(width: Tokens.spaceSm),
            Expanded(
              child: Column(
                crossAxisAlignment: .start,
                mainAxisSize: .min,
                children: <Widget>[
                  Text(
                    b.sourceTitle.trim().isEmpty ? '未命名笔记' : b.sourceTitle,
                    maxLines: 1,
                    overflow: .ellipsis,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  // 说清"怎么引用的"：画布卡片 / 文档里的引用块 —— 两者的后续
                  // 操作完全不同（前者去画布上找卡片，后者去正文里找那一行）。
                  Text(
                    b.viaCanvasCard ? '画布卡片' : '引用',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
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
                        overflow: .ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
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
