import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import '../../app/providers.dart';
import '../../app/search_provider.dart' show allTagsProvider;
import '../../domain/note.dart';
import '../../theme/tokens.dart';

/// 标签编辑面板（编辑器标题行第四只"耳"的气泡内容）。
///
/// 与 [BacklinkPanel] 同一自治模式：**只在打开时挂载** ⇒ 可以放心
/// `watch(notesProvider)`（打/删标签后列表快照换一份，本面板自动重算），
/// 宿主不用为此 watch 整个列表。写走 [NotesNotifier.saveTags]（整理元数据，
/// 不动 revised_at），UI 传原始列表，归一化在 store 层。
///
/// 结构三段：当前标签（可删）→ 输入框（回车即加）→ 全库标签池里的**建议**
/// （排除已打的，点一下就加——省得重新打一遍已有的标签名）。
class TagsPanel extends ConsumerStatefulWidget {
  const TagsPanel({super.key, required this.noteId});

  /// 面板宽度（浮层用；与反链气泡同档）。
  static const double width = 240;

  /// 给哪篇笔记打标签。跨 kind 通用——画布笔记的标签同在这一列
  /// （画布视图的入口留待后续，数据层不做区分）。
  final String noteId;

  @override
  ConsumerState<TagsPanel> createState() => _TagsPanelState();
}

class _TagsPanelState extends ConsumerState<TagsPanel> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  /// 当前标签（**只在 build 里用**——内部是 `ref.watch`）。
  List<String> _currentWatch() {
    final List<Note> notes =
        ref.watch(notesProvider).value ?? const <Note>[];
    for (final Note n in notes) {
      if (n.id == widget.noteId) return n.tags;
    }
    return const <String>[];
  }

  /// 当前标签（**回调里用**——`ref.watch` 不许出 build，读一份快照即可）。
  List<String> _currentRead() {
    final List<Note> notes =
        ref.read(notesProvider).value ?? const <Note>[];
    for (final Note n in notes) {
      if (n.id == widget.noteId) return n.tags;
    }
    return const <String>[];
  }

  Future<void> _add(String raw) async {
    final String tag = raw.trim();
    if (tag.isEmpty) return;
    final List<String> current = _currentRead();
    if (current.contains(tag)) {
      _input.clear(); // 已有同名的：不加，但输入框照清（用户意图是"加上"）
      return;
    }
    _input.clear();
    await ref
        .read(notesProvider.notifier)
        .saveTags(widget.noteId, <String>[...current, tag]);
    // 连续打标签不断焦：加完回到输入框等着下一个。
    if (mounted) _inputFocus.requestFocus();
  }

  Future<void> _remove(String tag) async {
    await ref.read(notesProvider.notifier).saveTags(
          widget.noteId,
          <String>[..._currentRead()]..remove(tag),
        );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<String> current = _currentWatch();

    // 建议池：全库标签（按出现篇数倒序），排除已打的，最多给 12 个防撑爆。
    final Set<String> have = current.toSet();
    final List<String> suggestions = <String>[
      for (final (String tag, _) in ref.watch(allTagsProvider))
        if (!have.contains(tag)) tag,
    ].take(12).toList();

    return SizedBox(
      width: TagsPanel.width,
      // ⚠️ 本面板挂在**根 Overlay**（AppFloatSurface 是纯表面容器，没有
      // Material）——TextField / InkWell 都要求 Material 祖先，不补这块
      // 直接炸 "No Material widget found"（2026-09-26 实机）。透明型 Material
      // 只提供墨水/焦点基础设施、不画底，浮层底色仍由 AppFloatSurface 负责。
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.all(Tokens.spaceMd),
          // 高度兜底：标签多到超过气泡的 maxHeight 时滚动，而不是 RenderFlex
          // overflow（Column(min) 在有界高度下超出就炸）。
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
            Text(
              '标签',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: Tokens.spaceSm),
            if (current.isEmpty)
              Text(
                '还没有标签。回车即加。',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else
              Wrap(
                spacing: Tokens.spaceSm,
                runSpacing: Tokens.spaceXs,
                children: <Widget>[
                  for (final String tag in current)
                    _TagPill(tag: tag, onRemove: () => _remove(tag)),
                ],
              ),
            const SizedBox(height: Tokens.spaceSm),
            TextField(
              controller: _input,
              focusNode: _inputFocus,
              autofocus: true,
              style: theme.textTheme.bodyMedium,
              onSubmitted: _add,
              decoration: const InputDecoration(
                isDense: true,
                hintText: '添加标签，回车确认',
                prefixIcon: Center(
                  widthFactor: 1,
                  child: tabler.Tag(
                    height: Tokens.iconSm,
                    width: Tokens.iconSm,
                    strokeWidth: Tokens.iconStroke,
                  ),
                ),
              ),
            ),
            if (suggestions.isNotEmpty) ...<Widget>[
              const SizedBox(height: Tokens.spaceSm),
              Text(
                '现有标签',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Tokens.spaceXs),
              Wrap(
                spacing: Tokens.spaceSm,
                runSpacing: Tokens.spaceXs,
                children: <Widget>[
                  for (final String tag in suggestions)
                    _SuggestionPill(tag: tag, onTap: () => _add(tag)),
                ],
              ),
            ],
          ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 当前标签的一枚（带 × 删除）。样式与搜索页标签 chips 同族（描边 pill），
/// 但**不接 provider**——加减只经由 [_add] / [_remove] 一条写路径。
class _TagPill extends StatelessWidget {
  const _TagPill({required this.tag, required this.onRemove});

  final String tag;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(Tokens.spaceSm, 2, 2, 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Tokens.radiusLg),
        border: Border.fromBorderSide(
          BorderSide(color: scheme.outlineVariant),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            tag,
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurface,
            ),
          ),
          SizedBox(
            width: 18,
            height: 18,
            child: InkWell(
              onTap: onRemove,
              borderRadius: BorderRadius.circular(Tokens.radiusSm),
              // tabler 图标是自绘 widget（不是 IconData），直接放。
              // 尺寸走 iconXxs（行内装饰记号档，见 test/theme/icon_size_test）。
              child: const tabler.X(
                height: Tokens.iconXxs,
                width: Tokens.iconXxs,
                strokeWidth: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 建议池里的一枚（点击 = 加上，无 ×）。
class _SuggestionPill extends StatelessWidget {
  const _SuggestionPill({required this.tag, required this.onTap});

  final String tag;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Tokens.radiusLg),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Tokens.spaceSm,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Tokens.radiusLg),
          border: Border.fromBorderSide(
            BorderSide(color: scheme.outlineVariant),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const tabler.Plus(
              height: Tokens.iconXxs,
              width: Tokens.iconXxs,
              strokeWidth: 1.5,
            ),
            const SizedBox(width: 2),
            Text(
              tag,
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
