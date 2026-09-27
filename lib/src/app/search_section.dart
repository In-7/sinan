import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import '../domain/note.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'providers.dart' show locateProvider;
import 'search_provider.dart';

/// 搜索分区内容最大宽度：过宽窗口下把搜索�?/ 标签 / 结果收在中间�?
/// 整体居中而非靠左�?026-09-26 用户定）。窄窗时该上限不生效，照常铺满�?
const double _searchContentMaxWidth = 860;

/// 全局搜索分区（主�?3 �?= [kSearchNavIndex]，从导航板顶行搜索图标进入）�?
///
/// 交互契约�?026-09-25 方案定稿）：
/// - 输入去抖后检�?*标题 + 内容**（[searchNotifierProvider]，状态在 provider �?
///   �?点结果跳进笔记再回来，词与结果都还在）；
/// - `Esc`：有�?= 清空，无�?= 回主页；`Enter` = 跳第一个结果；
/// - 结果�?*笔记**为单位（内容命中保留最�?snippet），标题命中置顶�?
/// - 语义路缺席只出提示不出错�?.4：降级而非不可用）�?
class SearchSection extends ConsumerStatefulWidget {
  const SearchSection({super.key});

  @override
  ConsumerState<SearchSection> createState() => _SearchSectionState();
}

class _SearchSectionState extends ConsumerState<SearchSection> {
  final TextEditingController _controller = TextEditingController();
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    // 回到分区时回填上次的查询词（状态在 provider，不在本 widget）�?
    _controller.text = ref.read(searchNotifierProvider).query;
    _focus = FocusNode(onKeyEvent: _onKey);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final SearchState s = ref.read(searchNotifierProvider);
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      // 逐层退出：清词（保留标签筛选，落进标签视图）→ 清标�?�?回主页�?
      if (s.query.isNotEmpty) {
        _controller.clear();
        ref.read(searchNotifierProvider.notifier).submit('');
        _focus.requestFocus();
      } else if (s.activeTag != null) {
        ref.read(searchNotifierProvider.notifier).selectTag(null);
        _focus.requestFocus();
      } else {
        ref.read(locateProvider.notifier).goHome();
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (s.hits.isNotEmpty) {
        ref
            .read(locateProvider.notifier)
            .locate(noteId: s.hits.first.note.id, focus: true);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final SearchState s = ref.watch(searchNotifierProvider);

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _searchContentMaxWidth),
        child: Column(
          crossAxisAlignment: .stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Tokens.spaceXl,
                Tokens.spaceLg,
                Tokens.spaceXl,
                0,
              ),
              // 搜索框占内容区可用宽�?**2/3**�?026-09-26 用户定：整宽太旷�?
              // �?1/3；整体居中而非靠左）。比例式而非定宽，窗口缩放时保持同一观感�?
              child: FractionallySizedBox(
                widthFactor: 2 / 3,
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  autofocus: true,
                  onChanged: (String v) =>
                      ref.read(searchNotifierProvider.notifier).submit(v),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '搜索标题与内容',
                    // tabler 图标�?*自绘 widget** 不是 IconData �?直接放（同导航板顶行）�?
                    prefixIcon: const Center(
                      widthFactor: 1,
                      child: tabler.Search(
                        height: Tokens.iconMd,
                        width: Tokens.iconMd,
                        strokeWidth: Tokens.iconStroke,
                      ),
                    ),
                    suffixIcon: s.query.isEmpty
                        ? null
                        : IconButton(
                            icon: const tabler.CircleX(
                              height: Tokens.iconSm,
                              width: Tokens.iconSm,
                              strokeWidth: Tokens.iconStroke,
                            ),
                            tooltip: '清空（Esc）',
                            onPressed: () {
                              _controller.clear();
                              ref
                                  .read(searchNotifierProvider.notifier)
                                  .submit('');
                              _focus.requestFocus();
                            },
                          ),
                  ),
                ),
              ),
            ),
            // 标签筛选行：全库标签池（跨 kind 一套），点�?= 过滤、再�?= 取消�?
            // 空池（还没打过标签）不占位。数据全在内存（[allTagsProvider]），�?SQL�?
            const _TagChips(),
            // 检索进行中：一条细进度线（FTS 本地查询几乎不可见，配了语义路时才有体感）�?
            AnimatedSwitcher(
              duration: Tokens.durationFast,
              child: s.searching
                  ? const LinearProgressIndicator(minHeight: 2)
                  : const SizedBox(height: 2),
            ),
            if (s.vectorFallbackReason != null && s.query.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Tokens.spaceXl,
                  Tokens.spaceSm,
                  Tokens.spaceXl,
                  0,
                ),
                child: Text(
                  s.vectorFallbackReason!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            Expanded(
              // 空查询但有标签筛�?�?不给 _Idle，给"标签视图"的结果列表�?
              child: (s.query.isEmpty && s.activeTag == null)
                  ? const _Idle()
                  : _Results(state: s),
            ),
          ],
        ),
      ),
    );
  }
}

/// 空态：还没输入�?
class _Idle extends StatelessWidget {
  const _Idle();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: .min,
        children: <Widget>[
          tabler.Search(
            height: 28,
            width: 28,
            strokeWidth: Tokens.iconStroke,
            colorFilter: ColorFilter.mode(
              theme.colorScheme.onSurfaceVariant,
              BlendMode.srcIn,
            ),
          ),
          const SizedBox(height: Tokens.spaceMd),
          Text(
            '搜索标题与内容',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 标签筛选行：全库标签池（[allTagsProvider]，按出现篇数倒序）�?
///
/// �?`select` 只订�?[SearchState.activeTag]——chips 行不该因为结果列�?
/// 变化而重建（打字时每 250ms 重建一�?chip，纯浪费）�?
class _TagChips extends ConsumerWidget {
  const _TagChips();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<(String, int)> tags = ref.watch(allTagsProvider);
    if (tags.isEmpty) return const SizedBox.shrink();
    final String? active = ref.watch(
      searchNotifierProvider.select((SearchState s) => s.activeTag),
    );
    return SizedBox(
      height: 40,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(
          horizontal: Tokens.spaceXl,
          vertical: Tokens.spaceSm,
        ),
        scrollDirection: .horizontal,
        itemCount: tags.length,
        separatorBuilder: (BuildContext _, int _) =>
            const SizedBox(width: Tokens.spaceSm),
        itemBuilder: (BuildContext context, int i) {
          final (String tag, int count) = tags[i];
          final bool selected = tag == active;
          return _TagChip(
            tag: tag,
            count: count,
            selected: selected,
            onTap: () => ref
                .read(searchNotifierProvider.notifier)
                .selectTag(selected ? null : tag),
          );
        },
      ),
    );
  }
}

/// 一枚标�?chip：标签名 + 篇数小字。选中 = 导航项同款选中底（"这是个筛�""?
/// 开关，且它开着"），未选中 = 极淡描边（[AppTheme.cardStroke]，卡片同款语言）�""?
class _TagChip extends StatelessWidget {
  const _TagChip({
    required this.tag,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String tag;
  final int count;
  final bool selected;
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
          horizontal: Tokens.spaceSm + 2,
          vertical: 4,
        ),
        decoration: BoxDecoration(
          color: selected ? AppTheme.navSelectedTint(scheme.onSurface) : null,
          borderRadius: BorderRadius.circular(Tokens.radiusLg),
          border: Border.fromBorderSide(
            BorderSide(color: AppTheme.cardStroke(theme.brightness)),
          ),
        ),
        child: Row(
          mainAxisSize: .min,
          children: <Widget>[
            Text(
              tag,
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(width: Tokens.spaceXs),
            Text(
              '$count',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 结果列表�?
class _Results extends StatelessWidget {
  const _Results({required this.state});

  final SearchState state;

  @override
  Widget build(BuildContext context) {
    if (state.hits.isEmpty && !state.searching) {
      final ThemeData theme = Theme.of(context);
      return Center(
        child: Text(
          // 标签视图（无查询词）与关键词查询的空态各说各的�?
          state.query.isEmpty
              ? '「${state.activeTag}」标签下还没有笔记'
              : '没有与「${state.query}」匹配的结果',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(
        horizontal: Tokens.spaceXl,
        vertical: Tokens.spaceMd,
      ),
      itemCount: state.hits.length,
      itemBuilder: (BuildContext _, int i) =>
          _ResultRow(hit: state.hits[i], query: state.query),
    );
  }
}

/// 一条结果：标题行（+「标题」徽�?+ 形态标签）+ 摘要行（关键词高亮）+ 行尾时间�?
class _ResultRow extends ConsumerStatefulWidget {
  const _ResultRow({required this.hit, required this.query});

  final SearchHit hit;
  final String query;

  @override
  ConsumerState<_ResultRow> createState() => _ResultRowState();
}

class _ResultRowState extends ConsumerState<_ResultRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Note note = widget.hit.note;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        onTap: () => ref
            .read(locateProvider.notifier)
            .locate(noteId: note.id, focus: true),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Tokens.spaceMd,
            vertical: Tokens.spaceSm,
          ),
          decoration: BoxDecoration(
            color: _hover ? AppTheme.boardFillHover(theme.brightness) : null,
            borderRadius: BorderRadius.circular(Tokens.radiusMd),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: .start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            note.title.isEmpty ? '无标题' : note.title,
                            style: theme.textTheme.bodyLarge,
                            maxLines: 1,
                            overflow: .ellipsis,
                          ),
                        ),
                        // 「标题」徽标：这个词在标题里就命中了——最强信号，值得说一句�?
                        if (widget.hit.titleMatch) ...<Widget>[
                          const SizedBox(width: Tokens.spaceSm),
                          Text(
                            '标题',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        if (note.kind == NoteKind.canvas) ...<Widget>[
                          const SizedBox(width: Tokens.spaceSm),
                          Text(
                            '画布',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (widget.hit.snippet != null) ...<Widget>[
                      const SizedBox(height: 2),
                      _Snippet(
                        snippet: widget.hit.snippet!,
                        query: widget.query,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: Tokens.spaceMd),
              Text(
                _relativeTime(note.revisedAt),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 摘要：先以第一个命中为中心裁到 ~140 字，再高亮查询词�?
class _Snippet extends StatelessWidget {
  const _Snippet({required this.snippet, required this.query});

  final String snippet;
  final String query;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String text = _trimSnippet(snippet, query);
    final String needle = query.toLowerCase();

    final List<TextSpan> spans = <TextSpan>[];
    if (needle.isEmpty) {
      spans.add(TextSpan(text: text));
    } else {
      int start = 0;
      while (true) {
        final int idx = text.toLowerCase().indexOf(needle, start);
        if (idx < 0) {
          spans.add(TextSpan(text: text.substring(start)));
          break;
        }
        if (idx > start) {
          spans.add(TextSpan(text: text.substring(start, idx)));
        }
        spans.add(
          TextSpan(
            text: text.substring(idx, idx + query.length),
            style: TextStyle(color: scheme.primary, fontWeight: .w600),
          ),
        );
        start = idx + query.length;
      }
    }

    return Text.rich(
      TextSpan(
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        children: spans,
      ),
      maxLines: 2,
      overflow: .ellipsis,
    );
  }

  /// chunk 原文最�?512 �?�?以第一个命中为中心裁到 ~140 字，保证关键词可见�?
  static String _trimSnippet(String snippet, String query) {
    if (snippet.length <= 140) return snippet;
    final int idx = snippet.toLowerCase().indexOf(query.toLowerCase());
    if (idx < 0) return '${snippet.substring(0, 140)}…';
    final int start = (idx - 40).clamp(0, snippet.length);
    final int end = (idx + query.length + 80).clamp(0, snippet.length);
    return '${start > 0 ? '…' : ''}'
        '${snippet.substring(start, end)}'
        '${end < snippet.length ? '…' : ''}';
  }
}

/// 相对时间（行尾小灰字）。口径与 `home_hub.dart` / `hub_nav.dart` 的同名私�?
/// 函数一致——各视图各持一份，不跨文件 import 私有函数（同一项目惯例）�?
String _relativeTime(DateTime at) {
  final Duration d = DateTime.now().difference(at);
  if (d.inMinutes < 1) return '刚刚';
  if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
  if (d.inHours < 24) return '${d.inHours} 小时前';
  if (d.inDays < 7) return '${d.inDays} 天前';
  return '${at.month}/${at.day}';
}
