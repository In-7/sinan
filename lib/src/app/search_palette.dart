import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import '../domain/note.dart';
import '../theme/app_custom_icons.dart';
import '../theme/app_float_surface.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'providers.dart';
import 'search_provider.dart';
import 'settings_panel.dart' show appNavigatorKey;

/// **全局搜索浮层**（2026-09-30 用户定，`Ctrl+K` / 标题栏胶囊唤起）。
///
/// 与主页**页内搜索框**是同一台引擎（[searchAllNotes]），两种形态回答两种
/// 意图（VS Code 的侧边栏搜索 vs `Ctrl+P` 同构）：
/// - 页内搜索：探索式翻找，结果接管整个内容区，卡片网格 + 三行摘要；
/// - **本浮层**：任何界面（尤其编辑器写到一半）"抓一篇就走"，顶部居中、
///   紧凑行、全程键盘（↑↓ 选、Enter 跳、Esc 关）。
///
/// 浮层刻意**不写** [searchNotifierProvider]：它是"即用即走"的临时动作，
/// 不该把主页的浏览态（查询词、标签筛选）带走或污染。去抖与结果都是浮层
/// 自己的局部状态，关掉即清空。
const double _paletteWidth = 600;
const double _topGap = 96;
const double _maxHeightFactor = 0.6;

/// 浮层里最多显示多少行（"抓一篇"场景不需要长列表；与命令面板同档）。
const int _maxRows = 8;

/// 空查询时展示的"最近编辑"条数（用户还没打字，给最近碰过的几篇当落点）。
const int _recentRows = 8;

/// 单例守卫：连按两次 `Ctrl+K` 不叠两层（与命令/设置浮层同一原因）。
bool _open = false;

/// 打开全局搜索浮层。
Future<void> showSearchPalette() {
  if (_open) return Future<void>.value();
  _open = true;

  final OverlayState overlay = appNavigatorKey.currentState!.overlay!;
  final Completer<void> closed = Completer<void>();
  OverlayEntry? entry;
  late final bool Function(KeyEvent event) handleEscKey;

  void close() {
    _open = false;
    if (!closed.isCompleted) closed.complete();
    if (entry != null && entry!.mounted) entry!.remove();
    entry = null;
    HardwareKeyboard.instance.removeHandler(handleEscKey);
  }

  // Esc 走**全局旁观者**（与命令面板同一条路）：输入框里的 EditableText 会
  // 把方向键等消费掉，焦点树祖先收不到——Esc 同理不能只指望 Actions。
  handleEscKey = (KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      close();
    }
    return false;
  };
  HardwareKeyboard.instance.addHandler(handleEscKey);

  entry = OverlayEntry(
    builder: (BuildContext _) => _SearchPaletteOverlay(onClose: close),
  );
  overlay.insert(entry!);
  return closed.future;
}

/// 仅供测试：用例异常中断时 [_open] 会卡在 true（浮层没走正常关闭），同进程
/// 后续用例将再也打不开浮层。测试在 tearDown 里兜底复位；生产关闭路径永远
/// 由 [showSearchPalette] 自己的 close 复位，不调这里。
@visibleForTesting
void debugResetSearchPaletteGuard() {
  _open = false;
}

/// 遮罩 + 顶部居中点位（与命令面板同规格，浮层族保持一套摆放语言）。
class _SearchPaletteOverlay extends StatelessWidget {
  const _SearchPaletteOverlay({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            child: ColoredBox(color: scheme.scrim.withValues(alpha: 0.18)),
          ),
        ),
        Positioned.fill(
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: _topGap),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight:
                      MediaQuery.sizeOf(context).height * _maxHeightFactor,
                ),
                child: SearchPalette(onClose: onClose),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 全局搜索浮层本体（公开仅为 widget 测试可直接 pump）。
///
/// 状态全部局部：查询词、去抖、命中、键盘选中。不碰 [searchNotifierProvider]
/// （见文件头注释）。
class SearchPalette extends ConsumerStatefulWidget {
  const SearchPalette({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  ConsumerState<SearchPalette> createState() => _SearchPaletteState();
}

class _SearchPaletteState extends ConsumerState<SearchPalette> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();
  Timer? _debounce;
  int _seq = 0;

  String _query = '';
  List<SearchHit> _hits = const <SearchHit>[];
  bool _searching = false;
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    // 空查询先落"最近编辑"——打开即有东西可跳，不必先打字。
    _hits = _recentNotes();
    // ↑↓ 走全局旁观者（同命令面板：EditableText 消费方向键，焦点树祖先收不到）。
    HardwareKeyboard.instance.addHandler(_onNavigateKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onNavigateKey);
    _debounce?.cancel();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<SearchHit> _recentNotes() {
    final List<Note> notes = List<Note>.of(
      ref.read(notesProvider).value ?? const <Note>[],
    )..sort((Note a, Note b) => b.revisedAt.compareTo(a.revisedAt));
    return <SearchHit>[
      for (final Note n in notes.take(_recentRows))
        (note: n, titleMatch: false, snippet: null, score: null),
    ];
  }

  bool _onNavigateKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _move(1);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _move(-1);
    }
    return false; // 旁观，不消费（见 command/bindings.dart 的 SDK 引文）
  }

  void _move(int delta) {
    if (_hits.isEmpty) return;
    // 到边界停住而不是回绕：回绕时多按一下跳到列表另一端，选错目标。
    setState(() => _selected = (_selected + delta).clamp(0, _hits.length - 1));
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    final String q = value.trim();
    setState(() {
      _query = value;
      _searching = q.isNotEmpty;
      _selected = 0;
    });
    if (q.isEmpty) {
      _seq++; // 作废在途检索
      setState(() {
        _hits = _recentNotes();
        _searching = false;
      });
      return;
    }
    final int seq = ++_seq;
    _debounce = Timer(kSearchDebounce, () async {
      final List<Note> notes = ref.read(notesProvider).value ?? const <Note>[];
      final ({List<SearchHit> hits, String? fallback}) outcome =
          await searchAllNotes(
            notes: notes,
            retrieve: ref.read(contentRetrieverProvider),
            query: q,
          );
      if (!mounted || seq != _seq) return;
      setState(() {
        _hits = outcome.hits.take(_maxRows).toList(growable: false);
        _searching = false;
        _selected = 0;
      });
    });
  }

  void _open(SearchHit hit) {
    widget.onClose(); // 先关：编辑器/画布不该被浮层压着
    ref.read(locateProvider.notifier).locate(noteId: hit.note.id);
  }

  void _openSelected() {
    if (_hits.isEmpty) return;
    _open(_hits[_selected.clamp(0, _hits.length - 1)]);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String trimmed = _query.trim();

    // DismissIntent 兜底：输入框收到 Esc 会 invoke DismissIntent 收触屏工具条，
    // MaterialApp 没映射它会抛异常（命令面板踩过，2026-09-21）。
    return Actions(
      actions: <Type, Action<Intent>>{
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (DismissIntent _) {
            widget.onClose();
            return null;
          },
        ),
      },
      child: FocusScope(
        child: AppFloatSurface(
          width: _paletteWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Tokens.spaceMd,
                  Tokens.spaceSm,
                  Tokens.spaceSm,
                  Tokens.spaceSm,
                ),
                child: Row(
                  children: <Widget>[
                    tabler.Search(
                      height: Tokens.iconMdSm,
                      width: Tokens.iconMdSm,
                      strokeWidth: 1.5,
                      colorFilter: ui.ColorFilter.mode(
                        theme.colorScheme.onSurfaceVariant,
                        ui.BlendMode.srcIn,
                      ),
                    ),
                    const SizedBox(width: Tokens.spaceSm),
                    Expanded(
                      child: TextField(
                        controller: _input,
                        focusNode: _focus,
                        onChanged: _onQueryChanged,
                        // 单行 TextField 消费 Enter 并回调这里——"回车跳转"
                        // 只有这一条路径，不与旁观者重复触发。
                        onSubmitted: (String _) => _openSelected(),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          isDense: true,
                          hintText: _searching ? '正在搜索…' : '搜索全部笔记与画布',
                        ),
                      ),
                    ),
                    const _KbdBadge('Esc'),
                  ],
                ),
              ),
              Container(height: 1, color: theme.dividerColor),
              if (_hits.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(Tokens.spaceLg),
                  child: Text(
                    '没有与「$trimmed」匹配的结果',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(
                      vertical: Tokens.spaceXs,
                    ),
                    itemCount: _hits.length,
                    itemBuilder: (BuildContext _, int i) {
                      final SearchHit hit = _hits[i];
                      return _PaletteResultRow(
                        key: ValueKey<String>(hit.note.id),
                        hit: hit,
                        query: trimmed,
                        recent: trimmed.isEmpty,
                        selected: i == _selected,
                        onHoverSelect: () {
                          if (_selected != i) {
                            setState(() => _selected = i);
                          }
                        },
                        onTap: () => _open(hit),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 键位提示小胶囊（如 `Esc`）。
class _KbdBadge extends StatelessWidget {
  const _KbdBadge(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Tokens.spaceXs + 1,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Tokens.radiusSm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
          fontSize: 10,
        ),
      ),
    );
  }
}

/// 一行结果：形态图标 + 高亮标题 + 一行命中片段（空查询时显示相对时间）。
class _PaletteResultRow extends StatelessWidget {
  const _PaletteResultRow({
    super.key,
    required this.hit,
    required this.query,
    required this.recent,
    required this.selected,
    required this.onHoverSelect,
    required this.onTap,
  });

  final SearchHit hit;
  final String query;
  final bool recent;
  final bool selected;
  final VoidCallback onHoverSelect;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Note n = hit.note;
    final bool isCanvas = n.kind == NoteKind.canvas;

    final String rawSnippet = hit.snippet?.trim() ?? '';
    final String? snippet = rawSnippet.isEmpty
        ? null
        : rawSnippet.replaceAll(RegExp(r'\s+'), ' ').trim();

    return InkWell(
      onTap: onTap,
      onHover: (bool v) {
        if (v) onHoverSelect();
      },
      child: Container(
        color: selected ? AppTheme.navSelectedTint(scheme.onSurface) : null,
        padding: const EdgeInsets.symmetric(
          horizontal: Tokens.spaceMd,
          vertical: Tokens.spaceXs + 1,
        ),
        child: Row(
          children: <Widget>[
            if (isCanvas)
              CustomIcons.canvas(size: Tokens.iconSm)
            else
              tabler.FileText(
                height: Tokens.iconSm,
                width: Tokens.iconSm,
                strokeWidth: 1.5,
                colorFilter: ui.ColorFilter.mode(
                  scheme.onSurfaceVariant,
                  ui.BlendMode.srcIn,
                ),
              ),
            const SizedBox(width: Tokens.spaceSm),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _matchRich(
                    n.title.trim().isEmpty ? '无标题' : n.title,
                    base:
                        theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurface,
                        ) ??
                        const TextStyle(),
                    context: context,
                    maxLines: 1,
                  ),
                  // 副行：有查询词且内容命中 ⇒ 命中片段（高亮）；
                  // 空查询的"最近编辑" ⇒ 形态 + 相对时间，回答"我什么时候碰过"。
                  if (snippet != null)
                    _matchRich(
                      snippet,
                      base:
                          theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ) ??
                          const TextStyle(),
                      context: context,
                      maxLines: 1,
                    )
                  else if (recent)
                    Text(
                      isCanvas ? '画布' : '笔记',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
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

  /// 命中词高亮（与 home_hub 卡片同一语义：空白拆 token、大小写不敏感、
  /// 主题色加粗）。浮层只需要一行，故就地实现一份精简版。
  Widget _matchRich(
    String text, {
    required TextStyle base,
    required BuildContext context,
    int? maxLines,
  }) {
    final String q = query.trim();
    if (q.isEmpty || text.isEmpty) {
      return Text(
        text,
        style: base,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
      );
    }
    final List<String> tokens = q
        .split(RegExp(r'\s+'))
        .where((String t) => t.isNotEmpty)
        .map(_escapeRegExp)
        .toList(growable: false);
    if (tokens.isEmpty) {
      return Text(
        text,
        style: base,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
      );
    }

    final RegExp pattern = RegExp(
      '(${tokens.join('|')})',
      caseSensitive: false,
    );
    final Color matchColor = Theme.of(context).colorScheme.primary;
    final List<TextSpan> spans = <TextSpan>[];
    int last = 0;
    for (final RegExpMatch m in pattern.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      spans.add(
        TextSpan(
          text: m.group(0),
          style: base.copyWith(color: matchColor, fontWeight: FontWeight.w700),
        ),
      );
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));

    return Text.rich(
      TextSpan(style: base, children: spans),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// 转义正则元字符（字符类用 raw：`${` 在普通字符串里会被当插值开头）。
String _escapeRegExp(String s) => s.replaceAllMapped(
  RegExp(r'[.*+?^${}()|[\]\\]'),
  (Match m) => '\\${m.group(0)}',
);
