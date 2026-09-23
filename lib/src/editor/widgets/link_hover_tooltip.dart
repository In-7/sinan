import 'dart:async';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/gestures.dart' show PointerHoverEvent;import 'package:material_ui/material_ui.dart';

import '../../theme/app_float_surface.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';

/// **链接悬浮提示**（自研）——指针停在链接上，浮出一枚小面板：完整 URL +
/// 「打开」「复制」。
///
/// ## 官方为什么不够（2026-09-15）
/// 官方对 href 的**点击**行为是：`default_text_span_decorator_for_attribute.dart`
/// 里挂一个 tap recognizer——单击 = 选中该链接并弹它的编辑菜单，Ctrl/Cmd+单击
/// 或双击才打开。**没有任何悬浮提示**，于是"这段蓝字点下去会去哪"只能靠肉眼
/// 认短链接；长链接（带 query 的那种）更是完全看不出。
///
/// ## 命中怎么算
/// **不自己算文本排版**（行内换行、混合样式、与图片相邻都会被算错）——一律问
/// 官方选区服务：
/// - `getNodeInOffset` / `getPositionInOffset`（都是**全局坐标**入参）；
/// - `Selectable.getRectsInSelection(..., shiftWithBaseOffset: true)` 拿到该链接
///   段的**屏幕矩形**（`shiftWithBaseOffset` 正是加编辑器原点，官方选区浮层
///   也用它）。
///
/// ## 开关节奏
/// 悬停 [showDelay] 才浮出（扫过不闪）；离开后 [hideGrace] 才收起——这段宽限
/// 正是"从链接移到面板上"要用的时间。另外：滚轮滚动、按下鼠标、组件卸载都会
/// 立刻收起（滚动后矩形就失效了，必须收）。
///
/// ⚠️ **两条"必须"，缺一条就"点不到按钮"**（2026-09-15 用户实机反馈：
/// "悬浮菜单无法点击，鼠标离开内容就消失了"）：
/// 1. 面板命中区要**含它到链接之间那段空隙**（下面 `Listener(opaque)` 的
///    padding）——指针穿空隙时页面层被 overlay 挡着收不到 hover；
/// 2. 页面层的 `onExit` 要走**宽限**而不是立即收——指针一进面板，编辑器那层
///    必然先收到 `onExit`，立即收 = 面板自己把自己关掉，`onEnter` 来不及生效。
class LinkHoverTooltip extends StatefulWidget {
  const LinkHoverTooltip({
    super.key,
    required this.editorState,
    required this.child,
  });

  final EditorState editorState;
  final Widget child;

  /// 悬停多久才浮出。取 220ms：慢于"鼠标扫过"（扫过通常 <150ms，不会误弹），
  /// 又快于浏览器的 title tooltip（~500ms）——链接预览属于"想立刻看到"的那类。
  static const Duration showDelay = Duration(milliseconds: 220);

  /// 离开后的宽限：够指针从链接移到下方面板上（面板命中区已含那段空隙，
  /// 这里再留足余量给"手慢"的用户）。
  static const Duration hideGrace = Duration(milliseconds: 220);

  /// 面板宽度（URL 单行省略，超出部分靠「复制」拿走）。
  static const double panelWidth = 320;

  @override
  State<LinkHoverTooltip> createState() => _LinkHoverTooltipState();
}

class _LinkHoverTooltipState extends State<LinkHoverTooltip> {
  Timer? _showTimer;
  Timer? _hideTimer;
  OverlayEntry? _entry;
  _HoveredLink? _link;

  /// 指针是否落在面板上（落在面板上时不收起，否则"想点打开"会先把面板弄没）。
  bool _onPanel = false;

  /// 指针**当前**是否落在某条链接上（待弹出计时器到点时复查它）。
  bool _overLink = false;

  @override
  void dispose() {
    _showTimer?.cancel();
    _hideTimer?.cancel();
    _removeEntry();
    super.dispose();
  }

  void _removeEntry() {
    _entry?.remove();
    _entry = null;
    _link = null;
    _onPanel = false;
    _overLink = false;
  }

  void _onHover(PointerHoverEvent event) {
    final _HoveredLink? link = _resolve(event.position);
    if (link == null) {
      _overLink = false;
      // ⚠️ 只是"这一帧不在链接上"——**不动**待弹出的计时器。指针沿着文字走
      // 时会有一帧帧的判空（字形边界抖动、跨字符、手抖），一判空就取消倒数
      // 等于要求"一动不动盯满 showDelay"（旧写法就是这样：用户实机反馈
      // "不太灵敏，有时候没有"）。计时器到点时再看 `_overLink` 决定弹不弹。
      if (!_onPanel) _dismissLater();
      return;
    }

    _overLink = true;
    _hideTimer?.cancel();

    // 已浮出：同一链接内移动只更新锚点（面板跟着走），不重开。
    if (_entry != null) {
      if (_link?.href != link.href || _link?.anchor != link.anchor) {
        _link = link;
        _entry!.markNeedsBuild();
      }
      return;
    }

    // 同一链接上继续悬停（还没到点）：不重置计时器，否则手一抖就永远不弹。
    if (_link?.href == link.href && _showTimer != null) {
      _link = link;
      return;
    }

    _link = link;
    _showTimer?.cancel();
    _showTimer = Timer(LinkHoverTooltip.showDelay, () {
      _showTimer = null;
      // ⚠️ 到点时指针必须**还在**链接上：中间真的移开了就不弹（这一条替代
      // 了"一判空就取消计时器"的作用，既不误弹也不怕抖动）。
      if (mounted && _overLink) _show();
    });
  }

  /// 安排收起（宽限内指针又回到链接/面板上会被取消）。
  void _dismissLater() {
    _hideTimer?.cancel();
    _hideTimer = Timer(LinkHoverTooltip.hideGrace, () {
      if (_onPanel) return;
      _removeEntry();
    });
  }

  void _dismissNow() {
    _showTimer?.cancel();
    _showTimer = null;
    _hideTimer?.cancel();
    _hideTimer = null;
    _removeEntry();
  }

  void _show() {
    final _HoveredLink? link = _link;
    if (link == null || _entry != null) return;
    final OverlayEntry entry = OverlayEntry(
      builder: (BuildContext context) => _buildPanel(context, link),
    );
    _entry = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
  }

  Widget _buildPanel(BuildContext context, _HoveredLink link) {
    final Size window = MediaQuery.sizeOf(context);
    // 高度是估算值：仅供"下方放不下就翻到上方"与出屏钳制用，不做测量回调。
    const double height = 84;
    const double gap = 6;
    // 下方放不下 ⇒ 翻到链接上方（命中区的空隙跟着换到另一侧）。
    final bool below = link.anchor.bottom + gap + height <= window.height - 8;
    double left = link.anchor.left;
    if (left + LinkHoverTooltip.panelWidth > window.width - 8) {
      left = window.width - 8 - LinkHoverTooltip.panelWidth;
    }
    if (left < 8) left = 8;
    double top = below ? link.anchor.bottom : link.anchor.top - gap - height;
    if (top < 8) top = 8;

    return Positioned(
      left: left,
      top: top,
      child: MouseRegion(
        onEnter: (_) {
          _onPanel = true;
          _hideTimer?.cancel();
        },
        onExit: (_) {
          _onPanel = false;
          _dismissLater();
        },
        child: Listener(
          // ⚠️ **opaque 是必需的**：面板与链接之间那 [gap] 的空隙必须落在命中
          // 区里。指针穿过空隙时，页面层（编辑器那棵子树）因为被这层 overlay
          // 挡住而收不到 hover ⇒ 判不到链接 ⇒ 会提前收起面板，手稍慢就永远
          // 点不到按钮（用户实机反馈："无法点击，离开内容就消失"）。
          behavior: HitTestBehavior.opaque,
          // 面板上滚轮：先收起——否则面板压着正文，滚轮感觉像卡住。
          onPointerSignal: (_) => _dismissNow(),
          child: Padding(
            padding: below
                ? const EdgeInsets.only(top: gap)
                : const EdgeInsets.only(bottom: gap),
            child: _LinkHoverPanel(
              href: link.href,
              onOpen: () {
                unawaited(editorLaunchUrl(link.href));
                _dismissNow();
              },
              onCopy: () {
                unawaited(AppFlowyClipboard.setData(text: link.href));
                _dismissNow();
              },
            ),
          ),
        ),
      ),
    );
  }

  /// 指针位置命中的链接（含该链接段的屏幕矩形）。没有则 null。
  _HoveredLink? _resolve(Offset global) {
    final AppFlowySelectionService service =
        widget.editorState.service.selectionService;
    final Node? node = service.getNodeInOffset(global);
    final Delta? delta = node?.delta;
    final SelectableMixin? selectable = node?.selectable;
    if (delta == null || selectable == null) return null;

    final Position? position = service.getPositionInOffset(global);
    if (position == null) return null;

    // 指针落在字符**右半边**时 `getPositionInOffset` 指向下一个字符，故
    // `index` 与 `index - 1` 都要试——不试的话链接末尾那半字判不中。
    final _HrefRun? run =
        _runAt(delta, position.offset) ?? _runAt(delta, position.offset - 1);
    if (run == null) return null;

    // ⚠️ 两步都要：`getRectsInSelection(+base)` 给的是**容器内**坐标，还得
    // `transformRectToGlobal(+base)` 才落到全局——官方选区浮层就是这么拼的
    // （`editor_state.dart` 的 `selectionRects`、移动端选区服务同款）。
    // 只做第一步的话，点在链接上永远判不中（矩形差了一个编辑器原点的距离）。
    final List<Rect> rects = <Rect>[
      for (final Rect rect in selectable.getRectsInSelection(
        Selection.single(
          path: node!.path,
          startOffset: run.start,
          endOffset: run.end,
        ),
        shiftWithBaseOffset: true,
      ))
        selectable.transformRectToGlobal(rect, shiftWithBaseOffset: true),
    ];
    if (rects.isEmpty) return null;
    // 必须真的落在该链接的**字形矩形**内才算悬停：`getPositionInOffset` 会把
    // 行尾空白也算作"最近的位置"，不校验的话停在链接右侧的空白上也会弹面板。
    // 容差 2px：字形行盒两侧的"手感边界"比墨迹略宽一点，太严会让人觉得
    // "明明指着链接了却不弹"（行盒本身已含行距，纵向本来就宽）。
    if (!rects.any((Rect rect) => rect.inflate(2).contains(global))) {
      return null;
    }

    Rect anchor = rects.first;
    for (final Rect rect in rects.skip(1)) {
      anchor = anchor.expandToInclude(rect);
    }
    return _HoveredLink(run.href, anchor);
  }

  /// [index] 处的 href 及其所在**连续同 href 段**（同一链接可能被行内样式
  /// 切成多个 insert，故要合并相邻段）。
  _HrefRun? _runAt(Delta delta, int index) {
    if (index < 0) return null;
    final List<_HrefRun> runs = <_HrefRun>[];
    int cursor = 0;
    for (final TextInsert insert in delta.whereType<TextInsert>()) {
      final String? href =
          insert.attributes?[AppFlowyRichTextKeys.href] as String?;
      final int next = cursor + insert.text.length;
      if (href != null) {
        final _HrefRun? last = runs.isEmpty ? null : runs.last;
        if (last != null && last.href == href && last.end == cursor) {
          last.end = next;
        } else {
          runs.add(_HrefRun(cursor, next, href));
        }
      }
      cursor = next;
    }
    for (final _HrefRun run in runs) {
      if (index >= run.start && index < run.end) return run;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // hitTestBehavior.translucent + opaque:false：**只旁听**悬浮事件，不抢
    // 编辑器自己的命中（链接手型光标、块手柄悬浮等照旧）。
    return Listener(
      behavior: HitTestBehavior.translucent,
      // 滚动 / 按下鼠标：链接矩形立刻失效，直接收。
      onPointerSignal: (_) => _dismissNow(),
      onPointerDown: (_) => _dismissNow(),
      child: MouseRegion(
        opaque: false,
        hitTestBehavior: HitTestBehavior.translucent,
        onHover: _onHover,
        // ⚠️ **必须走宽限，不能立即收**：面板是根 overlay 里的另一棵子树，
        // 指针一进面板，这层就收到 `onExit`（hover 命中被 overlay 挡住）
        // ⇒ 立即收就等于"面板自己把自己关掉"，`onEnter` 来不及生效（用户
        // 实机反馈的"无法点击、离开内容就消失"就是这个）。宽限期内面板的
        // `onEnter` 会把它取消。
        onExit: (_) {
          _overLink = false; // 待弹出计时器到点时不该再弹（指针已离开编辑器）
          _dismissLater();
        },
        child: widget.child,
      ),
    );
  }
}

class _HoveredLink {
  const _HoveredLink(this.href, this.anchor);

  final String href;

  /// 该链接段在屏幕上的包围盒（全局坐标，可跨行 ⇒ 取并集）。
  final Rect anchor;
}

class _HrefRun {
  _HrefRun(this.start, this.end, this.href);

  final int start;
  int end;
  final String href;
}

/// 面板本体：URL 一行 + 「打开」「复制」两个动作。
class _LinkHoverPanel extends StatelessWidget {
  const _LinkHoverPanel({
    required this.href,
    required this.onOpen,
    required this.onCopy,
  });

  final String href;
  final VoidCallback onOpen;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return AppFloatSurface(
      width: LinkHoverTooltip.panelWidth,
      padding: const EdgeInsets.all(Tokens.spaceSm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            href,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurface),
          ),
          const SizedBox(height: Tokens.spaceXs),
          Row(
            children: <Widget>[
              _PanelAction(
                icon: tabler.ExternalLink(height: 24, width: 24, strokeWidth: 1.5),
                label: '打开',
                onPressed: onOpen,
              ),
              const SizedBox(width: Tokens.spaceXs),
              _PanelAction(
                icon: tabler.Copy(height: 24, width: 24, strokeWidth: 1.5),
                label: '复制',
                onPressed: onCopy,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 面板里的动作钮：悬停状态层与工具栏/菜单同一口径。
class _PanelAction extends StatefulWidget {
  const _PanelAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  State<_PanelAction> createState() => _PanelActionState();
}

class _PanelActionState extends State<_PanelAction> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Tokens.spaceSm,
            vertical: Tokens.spaceXs,
          ),
          decoration: BoxDecoration(
            color: _hovered
                ? AppTheme.stateLayer(scheme.onSurfaceVariant)
                : null,
            borderRadius: BorderRadius.circular(Tokens.radiusSm),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                widget.icon,
                size: Tokens.iconSm,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: Tokens.spaceXs),
              Text(
                widget.label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
