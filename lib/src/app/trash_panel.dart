import 'dart:async' show Completer;

import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, KeyEvent, LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import '../domain/trash.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'providers.dart';
import 'settings_panel.dart' show appNavigatorKey, settingsScrimAlpha;
import 'stream_delete.dart' show showStreamConfirm;

/// **全局回收站浮层**（2026-10-18）：笔记 / 画布 / 灵感 统一一个入口。
///
/// 与设置 / 台账同一套浮层形态：背后页面原样留着，Esc / 点卡片外关闭。
/// 入口在最左图标轨底部（见 `app_icon_rail.dart`）。
void showTrash() {
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
    builder: (BuildContext context) => _TrashOverlay(onClose: close),
  );
  overlay.insert(entry!);
}

const double _trashWidth = 760;
const double _trashHeightRatio = 0.85;

enum _TrashFilter { all, stream, note, canvas }

class _TrashOverlay extends StatefulWidget {
  const _TrashOverlay({required this.onClose});

  final VoidCallback onClose;

  @override
  State<_TrashOverlay> createState() => _TrashOverlayState();
}

class _TrashOverlayState extends State<_TrashOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    duration: Tokens.durationNormal,
    vsync: this,
  )..forward();
  late final Animation<double> _fade = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeOut,
  );
  final FocusScopeNode _panelScope = FocusScopeNode(
    debugLabel: 'global.trash',
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
                    maxWidth: _trashWidth,
                    maxHeight: screen.height * _trashHeightRatio,
                  ),
                  child: FocusTraversalGroup(
                    child: FocusScope(
                      node: _panelScope,
                      child: _TrashCard(onClose: widget.onClose),
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

class _TrashCard extends ConsumerStatefulWidget {
  const _TrashCard({required this.onClose});

  final VoidCallback onClose;

  @override
  ConsumerState<_TrashCard> createState() => _TrashCardState();
}

class _TrashCardState extends ConsumerState<_TrashCard> {
  _TrashFilter _filter = _TrashFilter.all;

  @override
  Widget build(BuildContext context) {
    final List<TrashEntry> all = ref.watch(trashProvider);
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Brightness b = theme.brightness;
    final List<TrashEntry> shown = switch (_filter) {
      _TrashFilter.all => all,
      _TrashFilter.stream => <TrashEntry>[
        for (final TrashEntry e in all)
          if (e.kind == TrashKind.stream) e,
      ],
      _TrashFilter.note => <TrashEntry>[
        for (final TrashEntry e in all)
          if (e.kind == TrashKind.note) e,
      ],
      _TrashFilter.canvas => <TrashEntry>[
        for (final TrashEntry e in all)
          if (e.kind == TrashKind.canvas) e,
      ],
    };

    int count(TrashKind k) =>
        all.where((TrashEntry e) => e.kind == k).length;

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
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Tokens.spaceLg,
              Tokens.spaceSm,
              Tokens.spaceSm,
              Tokens.spaceSm,
            ),
            child: Row(
              children: <Widget>[
                Text(
                  '回收站 ${all.length} 条',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: Bauhaus.ink(b),
                  ),
                ),
                const SizedBox(width: Tokens.spaceSm),
                Text(
                  '30 天后自动彻底删除',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Bauhaus.inkMuted(b),
                  ),
                ),
                const Spacer(),
                if (all.isNotEmpty)
                  TextButton(
                    onPressed: () => _clearAll(all),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: scheme.error,
                      textStyle: theme.textTheme.labelMedium,
                    ),
                    child: const Text('清空回收站'),
                  ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: widget.onClose,
                  iconSize: Tokens.iconSm,
                  icon: const tabler.X(),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Tokens.spaceLg,
              0,
              Tokens.spaceLg,
              Tokens.spaceSm,
            ),
            child: SegmentedButton<_TrashFilter>(
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStatePropertyAll<TextStyle?>(
                  theme.textTheme.labelMedium,
                ),
              ),
              segments: <ButtonSegment<_TrashFilter>>[
                ButtonSegment<_TrashFilter>(
                  value: _TrashFilter.all,
                  label: Text('全部 ${all.length}'),
                ),
                ButtonSegment<_TrashFilter>(
                  value: _TrashFilter.stream,
                  label: Text('灵感 ${count(TrashKind.stream)}'),
                ),
                ButtonSegment<_TrashFilter>(
                  value: _TrashFilter.note,
                  label: Text('笔记 ${count(TrashKind.note)}'),
                ),
                ButtonSegment<_TrashFilter>(
                  value: _TrashFilter.canvas,
                  label: Text('画布 ${count(TrashKind.canvas)}'),
                ),
              ],
              selected: <_TrashFilter>{_filter},
              onSelectionChanged: (Set<_TrashFilter> s) {
                setState(() => _filter = s.first);
              },
            ),
          ),
          const Divider(height: 1),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.all(Tokens.spaceXl),
              child: Text(
                '回收站是空的',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Bauhaus.inkMuted(b),
                ),
              ),
            )
          else
            Flexible(
              child: ListView.separated(
                padding: const EdgeInsets.all(Tokens.spaceSm),
                itemCount: shown.length,
                separatorBuilder: (BuildContext _, int _) =>
                    const SizedBox(height: Tokens.spaceXs),
                itemBuilder: (BuildContext _, int i) =>
                    _row(shown[i], theme, scheme, b),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(
    TrashEntry e,
    ThemeData theme,
    ColorScheme scheme,
    Brightness b,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        Tokens.spaceMd,
        Tokens.spaceSm,
        Tokens.spaceSm,
        Tokens.spaceSm,
      ),
      decoration: BoxDecoration(
        color: Color.alphaBlend(AppTheme.hoverOverlay(b), scheme.surface),
        borderRadius: BorderRadius.circular(Tokens.radiusSm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Tokens.spaceXs,
              vertical: 1,
            ),
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(Tokens.radiusSm),
            ),
            child: Text(
              switch (e.kind) {
                TrashKind.stream => '灵感',
                TrashKind.note => '笔记',
                TrashKind.canvas => '画布',
              },
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSecondaryContainer,
              ),
            ),
          ),
          const SizedBox(width: Tokens.spaceSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  e.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Bauhaus.ink(b),
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '删除于 ${_stamp(e.deletedAt)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Bauhaus.inkMuted(b),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: Tokens.spaceSm),
          TextButton(
            onPressed: () => _restore(e),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              textStyle: theme.textTheme.labelMedium,
            ),
            child: const Text('恢复'),
          ),
          TextButton(
            onPressed: () => _purge(e),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              foregroundColor: scheme.error,
              textStyle: theme.textTheme.labelMedium,
            ),
            child: const Text('彻底删除'),
          ),
        ],
      ),
    );
  }

  Future<void> _restore(TrashEntry e) async {
    switch (e.kind) {
      case TrashKind.stream:
        await ref.read(streamProvider.notifier).restore(e.id);
      case TrashKind.note || TrashKind.canvas:
        await ref.read(notesProvider.notifier).restoreNoteFromTrash(e.id);
    }
  }

  Future<void> _purge(TrashEntry e) async {
    final bool ok = await showStreamConfirm(
      context: context,
      title: '彻底删除',
      message: '彻底删除「${e.title}」？删除后不可恢复。',
      confirmLabel: '彻底删除',
      destructive: true,
    );
    if (!ok || !mounted) return;
    switch (e.kind) {
      case TrashKind.stream:
        await ref.read(streamProvider.notifier).remove(e.id);
      case TrashKind.note || TrashKind.canvas:
        await ref.read(notesProvider.notifier).purgeNote(e.id);
    }
  }

  Future<void> _clearAll(List<TrashEntry> all) async {
    final bool ok = await showStreamConfirm(
      context: context,
      title: '清空回收站',
      message: '彻底删除回收站里的 ${all.length} 条内容？删除后不可恢复。',
      confirmLabel: '彻底删除',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final List<String> streamIds = <String>[
      for (final TrashEntry e in all)
        if (e.kind == TrashKind.stream) e.id,
    ];
    if (streamIds.isNotEmpty) {
      await ref.read(streamProvider.notifier).removeMany(streamIds);
    }
    await ref.read(notesProvider.notifier).purgeAllTrashNotes();
  }

  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }
}
