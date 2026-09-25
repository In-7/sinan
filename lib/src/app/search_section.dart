import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import '../domain/note.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'providers.dart' show locateProvider;
import 'search_provider.dart';

/// 全局搜索分区（主区 3 号 = [kSearchNavIndex]，从导航板顶行搜索图标进入）。
///
/// 交互契约（2026-09-25 方案定稿）：
/// - 输入去抖后检索**标题 + 内容**（[searchNotifierProvider]，状态在 provider 里
///   ⇒ 点结果跳进笔记再回来，词与结果都还在）；
/// - `Esc`：有词 = 清空，无词 = 回主页；`Enter` = 跳第一个结果；
/// - 结果以**笔记**为单位（内容命中保留最优 snippet），标题命中置顶；
/// - 语义路缺席只出提示不出错（6.4：降级而非不可用）。
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
    // 回到分区时回填上次的查询词（状态在 provider，不在本 widget）。
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
      if (s.query.isEmpty) {
        ref.read(locateProvider.notifier).goHome();
      } else {
        _controller.clear();
        ref.read(searchNotifierProvider.notifier).submit('');
        _focus.requestFocus();
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Tokens.spaceXl,
            Tokens.spaceLg,
            Tokens.spaceXl,
            0,
          ),
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            autofocus: true,
            onChanged: (String v) =>
                ref.read(searchNotifierProvider.notifier).submit(v),
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索标题与内容',
              // tabler 图标是**自绘 widget** 不是 IconData ⇒ 直接放（同导航板顶行）。
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
                        ref.read(searchNotifierProvider.notifier).submit('');
                        _focus.requestFocus();
                      },
                    ),
            ),
          ),
        ),
        // 检索进行中：一条细进度线（FTS 本地查询几乎不可见，配了语义路时才有体感）。
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
          child: s.query.isEmpty ? const _Idle() : _Results(state: s),
        ),
      ],
    );
  }
}

/// 空态：还没输入。
class _Idle extends StatelessWidget {
  const _Idle();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
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

/// 结果列表。
class _Results extends StatelessWidget {
  const _Results({required this.state});

  final SearchState state;

  @override
  Widget build(BuildContext context) {
    if (state.hits.isEmpty && !state.searching) {
      final ThemeData theme = Theme.of(context);
      return Center(
        child: Text(
          '没有与「${state.query}」匹配的结果',
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

/// 一条结果：标题行（+「标题」徽标 + 形态标签）+ 摘要行（关键词高亮）+ 行尾时间。
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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            note.title.isEmpty ? '无标题' : note.title,
                            style: theme.textTheme.bodyLarge,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // 「标题」徽标：这个词在标题里就命中了——最强信号，值得说一句。
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

/// 摘要：先以第一个命中为中心裁到 ~140 字，再高亮查询词。
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
            style: TextStyle(
              color: scheme.primary,
              fontWeight: FontWeight.w600,
            ),
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
      overflow: TextOverflow.ellipsis,
    );
  }

  /// chunk 原文最长 512 字 ⇒ 以第一个命中为中心裁到 ~140 字，保证关键词可见。
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

/// 相对时间（行尾小灰字）。口径与 `home_hub.dart` / `hub_nav.dart` 的同名私有
/// 函数一致——各视图各持一份，不跨文件 import 私有函数（同一项目惯例）。
String _relativeTime(DateTime at) {
  final Duration d = DateTime.now().difference(at);
  if (d.inMinutes < 1) return '刚刚';
  if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
  if (d.inHours < 24) return '${d.inHours} 小时前';
  if (d.inDays < 7) return '${d.inDays} 天前';
  return '${at.month}/${at.day}';
}
