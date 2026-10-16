import 'dart:async';

// 键盘事件（Enter 生成 / Shift+Enter 换行 / Enter 展开）：KeyDownEvent /
// LogicalKeyboardKey / HardwareKeyboard 都在 `services.dart`，不由 material 转出。
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import '../domain/note.dart';
import '../editor/blocks/reference_to_canvas.dart';
import '../theme/app_theme.dart';
import '../theme/focus_ring.dart';
import '../theme/tokens.dart';
import 'note_display.dart';
import 'providers.dart' show streamProvider;
import 'stream_export.dart';

/// **心流 v2**（2026-10-16 用户定重置）：灵感卡片流 + 顶部输入条。
///
/// 设计：心流是汇聚灵感的地方，要轻——一屏瀑布流 spark 卡（无框、无重底，文本
/// 优先），**点卡就地放大展开、可直接改**（不跳编辑器 / 新页面）；顶部一条醒目
/// 输入框，打字回车即落一张卡，零摩擦（一句话也行）。
///
/// ⚠️ **单向**：心流只读 [streamProvider]（自己那个隐藏容器），**不读笔记数据**；
/// 条目经 `stream_export.dart` **单向流出**（引用 / 注入 / 转新笔记 / 引用到画布）。
class StreamView extends ConsumerStatefulWidget {
  const StreamView({super.key, this.tag});

  /// 顶栏标签筛选。**心流刻意忽略它**：心流条目是纯文本、无标签 ⇒ 标签筛选对心流
  /// 不生效（心流永远是全部灵感）；标签筛选在「全部」等笔记视图照常。
  final String? tag;

  @override
  ConsumerState<StreamView> createState() => _StreamViewState();
}

class _StreamViewState extends ConsumerState<StreamView> {
  Future<void> _capture(String text) async {
    await ref.read(streamProvider.notifier).add(text);
  }

  /// 瀑布流列数随窗宽（约 320 一列，2–4 列夹取）。
  int _columnsFor(double width) => (width ~/ 320).clamp(2, 4).toInt();

  @override
  Widget build(BuildContext context) {
    final List<StreamItem> items =
        ref.watch(streamProvider).value ?? const <StreamItem>[];
    final int columns = _columnsFor(MediaQuery.sizeOf(context).width);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 顶部输入条：进界面第一眼看到、明确可辨（有淡底 + 占位 + 发送钮），
        // 与下面无边框的文本卡彻底两种语言。
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Tokens.spaceLg,
            Tokens.spaceMd,
            Tokens.spaceLg,
            Tokens.spaceSm,
          ),
          child: StreamComposer(onSubmit: _capture),
        ),
        Expanded(
          child: items.isEmpty
              ? const _StreamEmpty()
              : MasonryGridView.builder(
                  padding: const EdgeInsets.fromLTRB(
                    Tokens.spaceLg,
                    Tokens.spaceSm,
                    Tokens.spaceLg,
                    Tokens.spaceLg,
                  ),
                  gridDelegate: SliverSimpleGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                  ),
                  mainAxisSpacing: Tokens.cardGridSpacing,
                  crossAxisSpacing: Tokens.cardGridSpacing,
                  itemCount: items.length,
                  // 瀑布流按列高自动排 ⇒ 卡片高度随内容（一句话 = 矮卡，长文 = 高卡）。
                  itemBuilder: (BuildContext context, int i) => _SparkCard(
                    key: ValueKey<String>(items[i].id),
                    item: items[i],
                  ),
                ),
        ),
      ],
    );
  }
}

/// 空态：一句轻邀请 + 指向顶部输入框（输入条常驻，空库也能直接写第一条）。
class _StreamEmpty extends StatelessWidget {
  const _StreamEmpty();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Tokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '还没有灵感',
              style: theme.textTheme.titleMedium?.copyWith(
                color: Bauhaus.ink(theme.colorScheme.brightness),
              ),
            ),
            const SizedBox(height: Tokens.spaceXs),
            Text(
              '在上面写下第一条，一句话也算',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Bauhaus.inkMuted(theme.colorScheme.brightness),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 心流里的一张 **spark 灵感卡**（v2：无边框、无重底，文本优先）。
///
/// - 折叠态：正文摘要（clamp）+ meta 行（相对时间）；hover 浮淡影 + 右上「⋯」导出
///   菜单；**点击就地放大展开**（不跳转）。
/// - 展开态：一个随内容长高的文本区，直接改；失焦 / 点「完成」即存并收回
///   （[StreamNotifier.update]，没改不落盘）。
/// - 「⋯」菜单 = 单向导出：引用到笔记 / 引用到画布 / 注入到笔记 / 转为新笔记 / 删除。
class _SparkCard extends ConsumerStatefulWidget {
  const _SparkCard({super.key, required this.item});

  final StreamItem item;

  @override
  ConsumerState<_SparkCard> createState() => _SparkCardState();
}

class _SparkCardState extends ConsumerState<_SparkCard> {
  final FocusNode _previewFocus = FocusNode();
  final FocusNode _editFocus = FocusNode();
  final TextEditingController _editController = TextEditingController();
  bool _hover = false;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _editFocus.addListener(_onEditFocusChange);
  }

  @override
  void dispose() {
    _editFocus.removeListener(_onEditFocusChange);
    _previewFocus.dispose();
    _editFocus.dispose();
    _editController.dispose();
    super.dispose();
  }

  void _expand() {
    _editController.text = widget.item.text;
    setState(() => _expanded = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _editFocus.requestFocus();
    });
  }

  /// 编辑区失焦 ⇒ 保存并收回（点别处 / 切卡都走这里，零摩擦提交）。
  void _onEditFocusChange() {
    if (!_editFocus.hasFocus && _expanded) {
      unawaited(_saveAndCollapse());
    }
  }

  Future<void> _saveAndCollapse() async {
    final String text = _editController.text;
    // 没改就不落盘（hash 判变在更底层，这里省一次 provider 刷新）。
    if (text.trim() != widget.item.text.trim()) {
      await ref.read(streamProvider.notifier).edit(widget.item.id, text);
    }
    if (mounted) setState(() => _expanded = false);
  }

  Future<void> _onMenu(String value) async {
    final String id = widget.item.id;
    switch (value) {
      case 'ref-note':
        await referenceStreamBlockToNote(context: context, blockId: id);
      case 'ref-canvas':
        await referenceBlockToCanvas(context: context, blockId: id);
      case 'inject':
        await injectStreamBlockToNote(context: context, blockId: id);
      case 'to-note':
        await streamBlockToNewNote(context: context, blockId: id);
      case 'delete':
        await ref.read(streamProvider.notifier).remove(id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Brightness brightness = theme.brightness;
    final BorderRadius radius = BorderRadius.circular(Tokens.radiusMd);

    return MouseRegion(
      onEnter: (_) {
        if (mounted && !_hover) setState(() => _hover = true);
      },
      onExit: (_) {
        if (mounted && _hover) setState(() => _hover = false);
      },
      child: _expanded
          ? _buildEditor(theme, brightness)
          : _buildPreview(theme, brightness, radius),
    );
  }

  Widget _buildPreview(
    ThemeData theme,
    Brightness brightness,
    BorderRadius radius,
  ) {
    return Semantics(
      button: true,
      label: widget.item.text,
      child: GestureDetector(
        onTap: _expand,
        child: FocusRing(
          focusNode: _previewFocus,
          borderRadius: radius,
          child: Focus(
            focusNode: _previewFocus,
            onKeyEvent: (FocusNode _, KeyEvent event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.enter) {
                _expand();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            // 无边框、无重底：只有 hover 时一层淡影（[AppTheme.hoverOverlay]），
            // 静止态完全透明——卡片身份靠网格间距 + 文本，不靠盒子。
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _hover
                    ? AppTheme.hoverOverlay(brightness)
                    : Colors.transparent,
                borderRadius: radius,
              ),
              child: Padding(
                padding: const EdgeInsets.all(Tokens.spaceMd),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            widget.item.text,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: Bauhaus.ink(brightness),
                            ),
                          ),
                        ),
                        // 「⋯」导出菜单：hover 才浮出（静止态保持轻量）。
                        if (_hover)
                          SizedBox(
                            width: 24,
                            height: 24,
                            child: PopupMenuButton<String>(
                              tooltip: '心流操作',
                              padding: EdgeInsets.zero,
                              iconSize: Tokens.iconSm,
                              icon: const tabler.Dots(
                                height: Tokens.iconSm,
                                width: Tokens.iconSm,
                                strokeWidth: Tokens.iconStroke,
                              ),
                              onSelected: _onMenu,
                              itemBuilder: (BuildContext _) =>
                                  const <PopupMenuEntry<String>>[
                                    PopupMenuItem(
                                      value: 'ref-note',
                                      child: Text('引用到笔记…'),
                                    ),
                                    PopupMenuItem(
                                      value: 'ref-canvas',
                                      child: Text('引用到画布…'),
                                    ),
                                    PopupMenuItem(
                                      value: 'inject',
                                      child: Text('注入到笔记…'),
                                    ),
                                    PopupMenuItem(
                                      value: 'to-note',
                                      child: Text('转为新笔记'),
                                    ),
                                    PopupMenuItem(
                                      value: 'delete',
                                      child: Text('删除'),
                                    ),
                                  ],
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: Tokens.spaceSm),
                    Text(
                      relativeTime(widget.item.createdAt),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Bauhaus.inkMuted(brightness),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEditor(ThemeData theme, Brightness brightness) {
    return Padding(
      padding: const EdgeInsets.all(Tokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            controller: _editController,
            focusNode: _editFocus,
            minLines: 1,
            maxLines: null, // 随内容长高，展开即可看全稿
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Bauhaus.ink(brightness),
            ),
            cursorColor: theme.colorScheme.primary,
            decoration: const InputDecoration(
              hintText: '改点什么…',
              isDense: true,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const SizedBox(height: Tokens.spaceSm),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  relativeTime(widget.item.createdAt),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Bauhaus.inkMuted(brightness),
                  ),
                ),
              ),
              TextButton(onPressed: _saveAndCollapse, child: const Text('完成')),
            ],
          ),
        ],
      ),
    );
  }
}

/// 心流**顶部输入条**（2026-10-16 用户定置顶 + 与卡片明确区分）：打字回车即落一张
/// 心流卡，零摩擦。套路同 `AskPanelBody` 的 composer（焦点节点收 Enter / Shift+Enter
/// 换行 / 空态禁用 / 提交后留焦点），但这里提交 = 录一条心流（[StreamNotifier.add]）。
///
/// 视觉上与无边框的文本卡彻底分开：一条**同色新拟态**输入条——底色与页面同色
///（`scheme.surface`），只靠柔光（上）/柔暗（下）双影浮出，不染种子色、不做玻璃：
/// 一眼"能打字"，不再是"又一张卡"。
class StreamComposer extends ConsumerStatefulWidget {
  const StreamComposer({super.key, required this.onSubmit});

  /// 提交回调：入参是 trim 后的文本，返回落库完成的 Future。
  final Future<void> Function(String text) onSubmit;

  @override
  ConsumerState<StreamComposer> createState() => _StreamComposerState();
}

class _StreamComposerState extends ConsumerState<StreamComposer> {
  final TextEditingController _controller = TextEditingController();
  late final FocusNode _focus = FocusNode(onKeyEvent: _onKey);
  bool _canSend = false;

  /// 「已保存」反馈：提交后亮起，**直到下次重新输入才收起**（无定时器）。
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged() {
    final bool can = _controller.text.trim().isNotEmpty;
    final bool hideSaved = _controller.text.isNotEmpty && _saved;
    if (can != _canSend || hideSaved) {
      setState(() {
        _canSend = can;
        if (hideSaved) _saved = false;
      });
    }
  }

  /// **Enter 生成 / Shift+Enter 换行**：挂在输入框自己的 [FocusNode] 上，返回
  /// `handled` 后换行符不会插进文本（同 ask_panel composer）。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      unawaited(_submit());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _submit() async {
    final String text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear(); // 清空但保留焦点，方便连续记录
    setState(() => _saved = true);
    await widget.onSubmit(text);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Brightness brightness = theme.brightness;
    final BorderRadius radius = BorderRadius.circular(Tokens.radiusLg);

    // 同色新拟态输入框：底色与页面同色（scheme.surface），靠柔光（上）/柔暗（下）
    // 双影浮出，不染种子色、不做玻璃。零 backdrop、认主题。
    final Color surface = scheme.surface;
    final bool isDark = brightness == Brightness.dark;
    final Color darkShadow = isDark
        ? Colors.black.withOpacity(0.45)
        : Colors.black.withOpacity(0.10);
    final Color lightShadow = isDark
        ? Colors.white.withOpacity(0.06)
        : Colors.white.withOpacity(0.9);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface,
        borderRadius: radius,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: lightShadow,
            blurRadius: 6,
            offset: const Offset(0, -1),
          ),
          BoxShadow(
            color: darkShadow,
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Tokens.spaceMd,
          Tokens.spaceSm,
          Tokens.spaceSm,
          Tokens.spaceXs,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Semantics(
              textField: true,
              label: '心流快速输入，回车生成卡片',
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                minLines: 1,
                maxLines: 6,
                style: theme.textTheme.bodyMedium,
                cursorColor: scheme.primary,
                decoration: const InputDecoration(
                  hintText: '记下此刻的想法…',
                  isDense: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(
                    vertical: Tokens.spaceSm,
                  ),
                ),
              ),
            ),
            Row(
              children: <Widget>[
                // 底行左：提交后「✓ 已保存」，否则键位提示；Flexible + ellipsis，
                // 窄窗（拖过断点）也不溢出；发送钮固定右缘。
                Flexible(
                  child: _saved
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(
                              Icons.check,
                              size: Tokens.iconXs,
                              color: Bauhaus.green(brightness),
                            ),
                            const SizedBox(width: Tokens.spaceXs),
                            Flexible(
                              child: Text(
                                '已保存',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        )
                      : Text(
                          'Enter 生成 · Shift+Enter 换行',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                ),
                const SizedBox(width: Tokens.spaceXs),
                IconButton(
                  onPressed: _canSend ? _submit : null,
                  tooltip: '生成卡片',
                  iconSize: Tokens.iconSm,
                  visualDensity: VisualDensity.compact,
                  style: IconButton.styleFrom(
                    backgroundColor: _canSend
                        ? scheme.primary
                        : scheme.surfaceContainerHighest,
                    foregroundColor: _canSend
                        ? scheme.onPrimary
                        : scheme.onSurfaceVariant,
                  ),
                  icon: const Icon(Icons.arrow_upward),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
