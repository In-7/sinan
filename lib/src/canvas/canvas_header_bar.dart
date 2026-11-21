import 'package:material_ui/material_ui.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import '../editor/panels/backlink_panel.dart';
import '../editor/panels/tags_panel.dart';
import '../theme/app_float_surface.dart';
import '../theme/header_action_button.dart';
import '../theme/tokens.dart';
import 'kernel/canvas_controller.dart';
import 'kernel/canvas_item.dart';
import 'kernel/canvas_text.dart';

/// 画布顶部**动作带**（2026-11-21）：与笔记标题行同款同位置——
/// 左端撤销/重做，右端 搜索 / 反链 / 标签（**不含目录**，画布没有大纲）。
///
/// 规格全部取自 `theme/header_action_button.dart`（上留白 4 / 热区 28 /
/// 图标 18），两处因此逐像素一致。浮层用 `OverlayPortal`，定位方式与笔记
/// 那三只耳相同（贴按钮下边、右对齐）。
class CanvasHeaderBar extends StatefulWidget {
  const CanvasHeaderBar({
    super.key,
    required this.controller,
    this.noteId,
    this.onOpenNote,
    this.center,
  });

  final CanvasController controller;

  /// 当前画布笔记 id。为 null 时不渲染右端三只耳（独立演示 / 测试壳）。
  final String? noteId;

  /// 反链点条目 → 打开来源笔记。
  final void Function(String noteId)? onOpenNote;

  /// 中段内容（绘制工具组，见 [CanvasToolStrip]）。
  /// 为空时这条带只剩左右两组。
  final Widget? center;

  @override
  State<CanvasHeaderBar> createState() => CanvasHeaderBarState();
}

/// 公开 State：宿主（[CanvasSurface]）用 GlobalKey 调 [openFind]，
/// 让 Ctrl+F 与点搜索耳走同一条路径。
class CanvasHeaderBarState extends State<CanvasHeaderBar> {
  // ── 搜索 ──────────────────────────────────────────────
  final OverlayPortalController _findController = OverlayPortalController();
  final GlobalKey _findButtonKey = GlobalKey();
  final Object _findTapGroupId = Object();
  final TextEditingController _findText = TextEditingController();
  final FocusNode _findFocus = FocusNode();
  bool _findVisible = false;

  // ── 反链 / 标签 ───────────────────────────────────────
  final OverlayPortalController _backlinkController = OverlayPortalController();
  final GlobalKey _backlinkButtonKey = GlobalKey();
  final Object _backlinkTapGroupId = Object();
  bool _backlinkVisible = false;

  final OverlayPortalController _tagsController = OverlayPortalController();
  final GlobalKey _tagsButtonKey = GlobalKey();
  final Object _tagsTapGroupId = Object();
  bool _tagsVisible = false;

  @override
  void dispose() {
    _findText.dispose();
    _findFocus.dispose();
    super.dispose();
  }

  /// 宿主调（Ctrl+F）：与点搜索耳同一条路径。
  void openFind() {
    if (!_findVisible) _toggleFind();
  }

  void _toggleFind() {
    final bool next = !_findVisible;
    setState(() => _findVisible = next);
    if (next) {
      if (!_findController.isShowing) _findController.show();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _findFocus.requestFocus();
      });
    } else {
      _closeFind();
    }
  }

  void _closeFind() {
    if (_findVisible) setState(() => _findVisible = false);
    if (_findController.isShowing) _findController.hide();
  }

  void _toggleBacklink() {
    final bool next = !_backlinkVisible;
    setState(() => _backlinkVisible = next);
    if (next) {
      if (!_backlinkController.isShowing) _backlinkController.show();
    } else {
      _closeInlay(_backlinkController, () => _backlinkVisible = false);
    }
  }

  void _toggleTags() {
    final bool next = !_tagsVisible;
    setState(() => _tagsVisible = next);
    if (next) {
      if (!_tagsController.isShowing) _tagsController.show();
    } else {
      _closeInlay(_tagsController, () => _tagsVisible = false);
    }
  }

  void _closeInlay(OverlayPortalController c, VoidCallback flip) {
    if (mounted) setState(flip);
    if (c.isShowing) c.hide();
  }

  /// 浮层定位（与笔记三只耳同一套）：贴按钮**下边**、右对齐。
  ({double top, double right, double available}) _anchor(
    GlobalKey key,
    OverlayChildLayoutInfo info,
  ) {
    final RenderBox? box = key.currentContext?.findRenderObject() as RenderBox?;
    final Offset origin = box == null
        ? const Offset(0, 48)
        : box.localToGlobal(Offset.zero);
    final double top = box == null ? 56 : origin.dy + box.size.height;
    final double right = box == null
        ? 16
        : info.overlaySize.width - (origin.dx + box.size.width);
    return (
      top: top,
      right: right,
      available: info.overlaySize.height - top - 16,
    );
  }

  @override
  Widget build(BuildContext context) {
    final String? noteId = widget.noteId;
    // 一条**连续浮岛**（2026-11-21 用户定案）：两端按钮位置/尺寸不变，
    // 中段塞绘制工具，段间用分隔线区分语义——文档级 │ 绘制 │ 文档信息。
    // 浮岛底顺手解决"透明按钮在画布网格上糊"的问题。
    return Padding(
      // 上留白交给浮岛内部的 vertical 4：带子贴画布顶，两端的 28 按钮落在
      // y=6（原 4，差 2px 不可察），与中间 32 工具共用同一条中心线。
      padding: const EdgeInsets.only(
        left: Tokens.spaceMd,
        right: Tokens.spaceMd,
      ),
      child: AppFloatSurface(
        // 水平 0 / 垂直 4：让两端的 28 按钮仍落在原来的 left:12 上（位置不变）。
        padding: const EdgeInsets.symmetric(vertical: Tokens.spaceXs),
        // 40 高（4+32+4）⇒ 圆角取半高，与内部 32 工具的方角形成"胶囊里嵌方件"。
        borderRadius: BorderRadius.circular(
          (Tokens.toolbarButtonSize + Tokens.spaceXs * 2) / 2,
        ),
        child: Row(
          children: <Widget>[
            // 左：撤销 / 重做（**永远显示**——文档级、无选区也要能用）。
            ListenableBuilder(
              listenable: widget.controller,
              builder: (BuildContext context, Widget? _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  HeaderHistoryButton(
                    itemKey: 'canvas.undo',
                    icon: const tabler.ArrowBackUp(
                      height: Tokens.iconSm,
                      width: Tokens.iconSm,
                      strokeWidth: Tokens.iconStroke,
                    ),
                    tooltip: '撤销（Ctrl+Z）',
                    enabled: widget.controller.document.canUndo,
                    onPressed: widget.controller.undo,
                  ),
                  const SizedBox(width: Tokens.spaceXs),
                  HeaderHistoryButton(
                    itemKey: 'canvas.redo',
                    icon: const tabler.ArrowForwardUp(
                      height: Tokens.iconSm,
                      width: Tokens.iconSm,
                      strokeWidth: Tokens.iconStroke,
                    ),
                    tooltip: '重做（Ctrl+Shift+Z）',
                    enabled: widget.controller.document.canRedo,
                    onPressed: widget.controller.redo,
                  ),
                ],
              ),
            ),
            // 分隔：文档级动作 │ 绘制工具。
            const SizedBox(
              height: 20,
              child: VerticalDivider(width: Tokens.spaceSm),
            ),
            // 中段：能居中就居中；窄到放不下时**横向滚动**而不是溢出裁切
            // （2026-11-21：顶部带换行会把 40 撑成 80、压掉画布一条，所以
            // 这里不能再用 Wrap）。
            Expanded(
              // `heightFactor: 1` 让这层只吃内容高度（裸 `Center` 会把
              // 高度撑满整块画布 ⇒ 整条带变高、按钮跑到屏幕中间）。
              child: Align(
                heightFactor: 1,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: widget.center,
                ),
              ),
            ),
            if (noteId != null) ...[
              // 分隔：绘制工具 │ 文档信息。
              const SizedBox(
                height: 20,
                child: VerticalDivider(width: Tokens.spaceSm),
              ),
              // 搜索：在本画布里找卡片文字，点结果直接带过去。
              OverlayPortal.overlayChildLayoutBuilder(
                controller: _findController,
                overlayChildBuilder: _findPopover,
                child: TapRegion(
                  groupId: _findTapGroupId,
                  child: HeaderActionButton(
                    key: _findButtonKey,
                    itemKey: 'canvas.ear.find',
                    icon: const tabler.ListSearch(
                      height: Tokens.iconSm,
                      width: Tokens.iconSm,
                      strokeWidth: Tokens.iconStroke,
                    ),
                    tooltip: '搜索画布（Ctrl+F）',
                    active: _findVisible,
                    onPressed: _toggleFind,
                  ),
                ),
              ),
              const SizedBox(width: Tokens.spaceXs),
              OverlayPortal.overlayChildLayoutBuilder(
                controller: _backlinkController,
                overlayChildBuilder: _backlinkPopover,
                child: TapRegion(
                  groupId: _backlinkTapGroupId,
                  child: HeaderActionButton(
                    key: _backlinkButtonKey,
                    itemKey: 'canvas.ear.backlink',
                    icon: const tabler.ArrowsSort(
                      height: Tokens.iconSm,
                      width: Tokens.iconSm,
                      strokeWidth: Tokens.iconStroke,
                    ),
                    tooltip: '反链（谁引用了我）',
                    active: _backlinkVisible,
                    onPressed: _toggleBacklink,
                  ),
                ),
              ),
              const SizedBox(width: Tokens.spaceXs),
              OverlayPortal.overlayChildLayoutBuilder(
                controller: _tagsController,
                overlayChildBuilder: _tagsPopover,
                child: TapRegion(
                  groupId: _tagsTapGroupId,
                  child: HeaderActionButton(
                    key: _tagsButtonKey,
                    itemKey: 'canvas.ear.tags',
                    icon: const tabler.Tag(
                      height: Tokens.iconSm,
                      width: Tokens.iconSm,
                      strokeWidth: Tokens.iconStroke,
                    ),
                    tooltip: '标签',
                    active: _tagsVisible,
                    onPressed: _toggleTags,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── 搜索面板 ──────────────────────────────────────────

  Widget _findPopover(BuildContext context, OverlayChildLayoutInfo info) {
    final ({double top, double right, double available}) a = _anchor(
      _findButtonKey,
      info,
    );
    return Positioned(
      top: a.top,
      right: a.right,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: a.available.clamp(160, double.infinity),
          maxWidth: 280,
        ),
        child: TapRegion(
          groupId: _findTapGroupId,
          onTapOutside: (_) => _closeFind(),
          child: _CanvasFindPanel(
            controller: widget.controller,
            text: _findText,
            focusNode: _findFocus,
            onPick: (CanvasItem item) {
              widget.controller.selectItems(<CanvasItem>[item]);
              widget.controller.focusItem(item);
              _closeFind();
            },
          ),
        ),
      ),
    );
  }

  // ── 反链 / 标签面板 ───────────────────────────────────

  Widget _backlinkPopover(BuildContext context, OverlayChildLayoutInfo info) {
    final ({double top, double right, double available}) a = _anchor(
      _backlinkButtonKey,
      info,
    );
    return Positioned(
      top: a.top,
      right: a.right,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: a.available.clamp(160, double.infinity),
          maxWidth: BacklinkPanel.width,
        ),
        child: TapRegion(
          groupId: _backlinkTapGroupId,
          onTapOutside: (_) => _toggleBacklink(),
          child: BacklinkPanel(
            noteId: widget.noteId!,
            onOpenNote: (String id) {
              _toggleBacklink();
              widget.onOpenNote?.call(id);
            },
          ),
        ),
      ),
    );
  }

  Widget _tagsPopover(BuildContext context, OverlayChildLayoutInfo info) {
    final ({double top, double right, double available}) a = _anchor(
      _tagsButtonKey,
      info,
    );
    return Positioned(
      top: a.top,
      right: a.right,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: a.available.clamp(120, double.infinity),
          maxWidth: TagsPanel.width,
        ),
        child: TapRegion(
          groupId: _tagsTapGroupId,
          onTapOutside: (_) => _toggleTags(),
          child: TagsPanel(noteId: widget.noteId!),
        ),
      ),
    );
  }
}

/// 画布内搜索面板：输入即过滤本画布的卡片/导图/分组文字，点结果带过去。
class _CanvasFindPanel extends StatefulWidget {
  const _CanvasFindPanel({
    required this.controller,
    required this.text,
    required this.focusNode,
    required this.onPick,
  });

  final CanvasController controller;
  final TextEditingController text;
  final FocusNode focusNode;
  final void Function(CanvasItem item) onPick;

  @override
  State<_CanvasFindPanel> createState() => _CanvasFindPanelState();
}

class _CanvasFindPanelState extends State<_CanvasFindPanel> {
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      elevation: 3,
      borderRadius: BorderRadius.circular(Tokens.radiusMd),
      child: Padding(
        padding: const EdgeInsets.all(Tokens.spaceSm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: widget.text,
              focusNode: widget.focusNode,
              autofocus: true,
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索画布内容',
                prefixIcon: const Icon(Icons.search, size: Tokens.iconSm),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Tokens.radiusSm),
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Tokens.spaceXs),
            Flexible(
              child: ListenableBuilder(
                listenable: widget.text,
                builder: (BuildContext context, Widget? _) {
                  final String q = widget.text.text.trim();
                  if (q.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: Tokens.spaceSm,
                      ),
                      child: Text(
                        '输入关键字，找画布里的卡片文字',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  }
                  final List<(CanvasItem, String)> hits =
                      <(CanvasItem, String)>[
                        for (final CanvasItem item
                            in widget.controller.document.items)
                          if (canvasItemText(item)
                              .toLowerCase()
                              .contains(q.toLowerCase()))
                            (item, canvasItemText(item)),
                      ];
                  if (hits.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: Tokens.spaceSm,
                      ),
                      child: Text(
                        '没有匹配的卡片',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: hits.length,
                    itemBuilder: (BuildContext context, int i) {
                      final (CanvasItem item, String text) = hits[i];
                      return ListTile(
                        dense: true,
                        title: Text(
                          text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                        onTap: () => widget.onPick(item),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
