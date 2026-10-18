import 'dart:async' show Completer;
import 'dart:ui' as ui;

import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, KeyEvent, LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import '../domain/note.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'providers.dart';
import 'settings_panel.dart' show appNavigatorKey, settingsScrimAlpha;

/// **已处理（处理台账）浮层**（2026-10-18 定稿）。
///
/// ## 为什么是浮层而不是一页
/// 它是「偶尔翻一下」的功能：看一眼某条归档灵感后来流去了哪里，然后继续写。
/// 做成页面会换掉整个主区、还会往导航历史里塞一步（`Alt+←` 得多退一次）；
/// 做成浮层则背后心流页**原样留着**——滚动位置、输入框里的草稿、选中态都不动，
/// 与设置面板同一种形态（用户 2026-10-18 原话："和设置一样不影响当前页面"）。
///
/// ## 为什么是双列卡片流而不是「列表 ┃ 详情」
/// 归档的用途是**快速扫读**。先点一条才能看全貌，扫读效率反而更低；所以全部卡片
/// 平铺、按归档时间倒序、每张高度自适应（长文不截断），一眼看完全部。点流向只是
/// **可选的跳转**，不是查看前提。
///
/// ## 入口
/// 只有心流页表头那枚 `N 已处理`（低频 ⇒ 不占侧栏常驻位）。
void showStreamLedger() {
  final OverlayState overlay = appNavigatorKey.currentState!.overlay!;
  final Completer<void> closed = Completer<void>();
  OverlayEntry? entry;
  late final bool Function(KeyEvent event) handleEscKey;

  void close() {
    if (!closed.isCompleted) closed.complete();
    if (entry != null && entry!.mounted) entry!.remove();
    entry = null;
    HardwareKeyboard.instance.removeHandler(handleEscKey);
  }

  handleEscKey = (KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      close();
    }
    return false;
  };
  HardwareKeyboard.instance.addHandler(handleEscKey);

  entry = OverlayEntry(
    builder: (BuildContext context) => _LedgerOverlay(onClose: close),
  );
  overlay.insert(entry!);
}

/// 台账卡的宽：比设置面板再宽一档——它要同时放两列卡片。
const double _ledgerWidth = 880;

/// 台账卡高：占窗口 85%（与设置面板同口径）。
const double _ledgerHeightRatio = 0.85;

/// 遮罩 + 居中卡（骨架与 `_SettingsOverlay` 同源：手势层压在最底下负责"点外面关"）。
class _LedgerOverlay extends StatefulWidget {
  const _LedgerOverlay({required this.onClose});

  final VoidCallback onClose;

  @override
  State<_LedgerOverlay> createState() => _LedgerOverlayState();
}

class _LedgerOverlayState extends State<_LedgerOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    duration: Tokens.durationNormal,
    vsync: this,
  )..forward();
  late final Animation<double> _fade = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeOut,
  );

  /// 面板自己的**作用域**节点：打开时接管焦点，同时它就是 Tab 的边界
  /// （否则 Tab 会走到背后心流页的控件上，看起来"按了没反应"）。
  final FocusScopeNode _panelScope = FocusScopeNode(
    debugLabel: 'stream.ledger',
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _panelScope.requestFocus();
    });
  }

  @override
  void dispose() {
    _panelScope.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    return Stack(
      children: <Widget>[
        // 手势层：点卡片外关闭。浓度跟随设置面板（现值 0 = 不压暗）。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
            child: FadeTransition(
              opacity: _fade,
              child: ColoredBox(
                color: Theme.of(context).colorScheme.scrim.withValues(
                  alpha: settingsScrimAlpha,
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: Center(
            child: FadeTransition(
              opacity: _fade,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.96, end: 1).animate(_fade),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: _ledgerWidth,
                    maxHeight: screen.height * _ledgerHeightRatio,
                  ),
                  child: FocusTraversalGroup(
                    child: FocusScope(
                      node: _panelScope,
                      child: _LedgerCard(onClose: widget.onClose),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 卡本体：标题行 + 双列卡片流。
class _LedgerCard extends ConsumerStatefulWidget {
  const _LedgerCard({required this.onClose});

  final VoidCallback onClose;

  @override
  ConsumerState<_LedgerCard> createState() => _LedgerCardState();
}

class _LedgerCardState extends ConsumerState<_LedgerCard> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(StreamItem i) =>
      i.text.toLowerCase().contains(_query.trim().toLowerCase());

  @override
  Widget build(BuildContext context) {
    final List<StreamItem> all =
        ref.watch(streamProvider).value ?? const <StreamItem>[];
    final List<StreamItem> done = <StreamItem>[
      for (final StreamItem i in all)
        if (i.archived && _matches(i)) i,
    ]..sort(
      (StreamItem a, StreamItem b) =>
          (b.archivedAt ?? b.createdAt).compareTo(
            a.archivedAt ?? a.createdAt,
          ),
    );

    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Brightness b = theme.brightness;

    return Material(
      color: AppTheme.floatSurface(b),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Tokens.radiusLg),
        side: AppTheme.menuBorder(scheme),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 标题行：计数 + summary + 搜索 + ×。
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Tokens.spaceLg,
              Tokens.spaceSm,
              Tokens.spaceSm,
              Tokens.spaceSm,
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        '已处理 ${done.length} 条',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: Bauhaus.ink(b),
                        ),
                      ),
                      if (done.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(
                          '$_flowed 条已流出 · ${done.length - _flowed} 条手动结案',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: Bauhaus.inkMuted(b),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                SizedBox(
                  width: 190,
                  height: 28,
                  child: TextField(
                    controller: _search,
                    style: theme.textTheme.bodySmall,
                    cursorColor: scheme.primary,
                    textAlignVertical: TextAlignVertical.center,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '搜索已处理',
                      hintStyle: theme.textTheme.labelSmall?.copyWith(
                        color: Bauhaus.inkMuted(b),
                      ),
                      filled: false,
                      prefixIcon: const tabler.Search(
                        height: Tokens.iconXs,
                        width: Tokens.iconXs,
                      ),
                      prefixIconConstraints: const BoxConstraints(minWidth: 28),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: '清空搜索',
                              iconSize: Tokens.iconXs,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 28),
                              onPressed: () {
                                _search.clear();
                                setState(() => _query = '');
                              },
                              icon: const tabler.X(),
                            ),
                      suffixIconConstraints: const BoxConstraints(minWidth: 28),
                      contentPadding: const EdgeInsets.symmetric(
                        vertical: Tokens.spaceXs,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Tokens.radiusSm),
                        borderSide: BorderSide(color: scheme.outlineVariant),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Tokens.radiusSm),
                        borderSide: BorderSide(color: scheme.outlineVariant),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Tokens.radiusSm),
                        borderSide: BorderSide(color: scheme.primary),
                      ),
                    ),
                    onChanged: (String v) => setState(() => _query = v),
                  ),
                ),
                const SizedBox(width: Tokens.spaceXs),
                IconButton(
                  tooltip: '关闭',
                  iconSize: Tokens.iconXs,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.all(Tokens.spaceSm),
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: widget.onClose,
                  icon: const tabler.X(),
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: AppTheme.divider(scheme)),
          Expanded(child: _board(done, theme, b)),
        ],
      ),
    );
  }

  int get _flowed {
    final Map<String, List<StreamExport>> book = ref.watch(
      streamExportsProvider,
    );
    final List<StreamItem> all =
        ref.watch(streamProvider).value ?? const <StreamItem>[];
    return all.fold<int>(
      0,
      (int n, StreamItem i) =>
          n + ((i.archived && (book[i.id]?.isNotEmpty ?? false)) ? 1 : 0),
    );
  }

  // ── 双列卡片流 ────────────────────────────────────────────────────

  static const EdgeInsets _boardPadding = EdgeInsets.fromLTRB(
    Tokens.spaceLg,
    Tokens.spaceSm,
    Tokens.spaceLg,
    Tokens.spaceLg,
  );

  /// 分列：按索引奇偶插花（左 0/2/4…，右 1/3/5…）⇒ 两列都保持时间序，
  /// 且天然等高（长卡不会把另一列顶出水面）。
  Widget _board(List<StreamItem> done, ThemeData theme, Brightness b) {
    if (done.isEmpty) {
      return _hint(
        _query.trim().isNotEmpty ? '没有匹配的已处理速记' : '还没有已处理的速记',
        _query.trim().isNotEmpty ? '换个词试试' : '速记归档后会出现在这里',
        theme,
        b,
      );
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final List<Widget> cards = <Widget>[
          for (final StreamItem item in done) _card(item, theme, b),
        ];
        // 窄卡单列：两列会把每条压成窄条，长文更难扫。
        if (constraints.maxWidth < 760) {
          return ListView(padding: _boardPadding, children: cards);
        }
        final List<Widget> left = <Widget>[];
        final List<Widget> right = <Widget>[];
        for (int i = 0; i < cards.length; i++) {
          (i.isEven ? left : right).add(cards[i]);
        }
        return ListView(
          padding: _boardPadding,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: left,
                  ),
                ),
                const SizedBox(width: Tokens.spaceLg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: right,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  /// 一张卡：**全貌原文** + 元信息 + 它流去了哪（带落地内容预览）+ 拿回。
  Widget _card(StreamItem item, ThemeData theme, Brightness b) {
    final List<StreamExport> exports =
        ref.watch(streamExportsProvider)[item.id] ?? const <StreamExport>[];
    // 卡片底色与心流页的速记卡同源（同一支"纸"的色），圆角同为控件档。
    final Color fill = Color.alphaBlend(
      AppTheme.hoverOverlay(b),
      theme.colorScheme.surface,
    );
    return Container(
      // 与速记页同规格的 6px 卡片间距。
      margin: const EdgeInsets.only(bottom: Tokens.spaceXs + Tokens.spaceXxs),
      padding: const EdgeInsets.all(Tokens.spaceSm),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(Tokens.radiusSm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // **全貌**：不设 maxLines、不省略号——扫读的前提就是"不用点也能看全部"。
          Text(
            item.text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Bauhaus.ink(b),
              height: 1.6,
            ),
          ),
          const SizedBox(height: Tokens.spaceXs),
          Text(
            '记于 ${_stamp(item.createdAt)} · 归档于 ${_stamp(item.archivedAt ?? item.createdAt)}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: Bauhaus.inkMuted(b),
            ),
          ),
          const SizedBox(height: Tokens.spaceSm),
          if (exports.isEmpty)
            Text(
              '手动结案 · 没有流出到别处',
              style: theme.textTheme.bodySmall?.copyWith(
                color: Bauhaus.inkMuted(b),
              ),
            )
          else
            for (final StreamExport e in exports) _flowRow(e, theme, b),
          Align(
            alignment: Alignment.centerRight,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 28),
              child: TextButton(
                onPressed: () =>
                    ref.read(streamProvider.notifier).unarchive(item.id),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: Tokens.spaceSm,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: Bauhaus.inkMuted(b),
                  textStyle: theme.textTheme.labelMedium,
                ),
                child: const Text('拿回'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 一条流向：`→ 笔记《标题》 · 手法 · 日期`，下面跟**落地内容的预览**。
  ///
  /// 点击是可选动作（跳到那一块）；扫读时不点也能看到"它变成了什么"。
  Widget _flowRow(StreamExport e, ThemeData theme, Brightness b) {
    final String? preview = ref.read(noteStoreProvider).streamExportPreview(e);
    return InkWell(
      onTap: () {
        if (!ref.read(noteStoreProvider).targetNoteExists(e.targetId)) {
          ScaffoldMessenger.maybeOf(
            context,
          )?.showSnackBar(const SnackBar(content: Text('这个去向已经删掉了')));
          return;
        }
        widget.onClose();
        ref.read(locateProvider.notifier).locate(
          noteId: e.targetId,
          blockId: e.targetBlockId,
        );
      },
      borderRadius: BorderRadius.circular(Tokens.radiusSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Tokens.spaceXs,
          vertical: Tokens.spaceXxs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(
                    '→',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
                const SizedBox(width: Tokens.spaceXs),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: <TextSpan>[
                        TextSpan(
                          text:
                              '${e.isCanvas ? '画布' : '笔记'}《${e.targetTitle}》',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: Bauhaus.ink(b),
                            decoration: TextDecoration.underline,
                            decorationColor: theme.colorScheme.primary
                                .withValues(alpha: 0.4),
                          ),
                        ),
                        TextSpan(
                          text: ' · ${e.kind.label} · ${_date(e.createdAt)}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: Bauhaus.inkMuted(b),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: Tokens.spaceXs),
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: tabler.ArrowUpRight(
                    height: Tokens.iconXs,
                    width: Tokens.iconXs,
                    colorFilter: ui.ColorFilter.mode(
                      theme.colorScheme.primary,
                      ui.BlendMode.srcIn,
                    ),
                  ),
                ),
              ],
            ),
            if (preview != null) ...<Widget>[
              const SizedBox(height: Tokens.spaceXxs),
              Padding(
                padding: const EdgeInsets.only(left: Tokens.spaceMd),
                child: Text(
                  preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Bauhaus.inkMuted(b),
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _hint(String title, String sub, ThemeData theme, Brightness b) =>
      Center(
        child: Padding(
          padding: const EdgeInsets.all(Tokens.spaceLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: Bauhaus.ink(b),
                ),
              ),
              const SizedBox(height: Tokens.spaceXs),
              Text(
                sub,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Bauhaus.inkMuted(b),
                ),
              ),
            ],
          ),
        ),
      );

  static String _date(DateTime t) => '${t.month} 月 ${t.day} 日';

  static String _stamp(DateTime t) =>
      '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';

  static String _two(int n) => n.toString().padLeft(2, '0');
}
