import 'dart:async';
import 'dart:ui' as ui;
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import 'package:appflowy_editor/appflowy_editor.dart';import 'package:material_ui/material_ui.dart';

import '../../theme/app_float_surface.dart';
import '../../theme/tokens.dart';
import '../core/shortcut_label.dart';

/// 对齐工具栏条目：把官方的「左 / 中 / 右」三个独立按钮合并成**一个下拉按钮**，
/// 按钮显示当前对齐方式，点开列出三选一（与 Word / Google Docs 同款）。
///
/// 应用逻辑完全复用官方 [alignmentItems]（`editor.updateNode` 写
/// [blockComponentAlign]），不另立一套语义；只把"三按钮"换成"一按钮 + 弹层"。
final ToolbarItem sinanAlignItem = ToolbarItem(
  id: 'sinan.align',
  group: 6,
  isActive: onlyShowInTextType,
  builder: (
    context,
    editorState,
    highlightColor,
    iconColor,
    tooltipBuilder,
  ) {
    final Selection selection = editorState.selection!;
    final String align = _currentAlign(editorState, selection);
    final Widget child = _SinanAlignButton(
      editorState: editorState,
      selection: selection,
      align: align,
      iconColor: iconColor,
      highlightColor: highlightColor,
    );
    if (tooltipBuilder != null) {
      return tooltipBuilder(context, 'sinan.align', '对齐', child);
    }
    return child;
  },
);

/// 取当前选区的一致对齐：三块都相同时返回该值，否则回落默认「左对齐」。
String _currentAlign(EditorState editorState, Selection selection) {
  final List<Node> nodes = editorState.getNodesInSelection(selection);
  if (nodes.isEmpty) return 'left';
  for (final String value in const <String>['center', 'right']) {
    if (nodes.every((Node n) => n.attributes[blockComponentAlign] == value)) {
      return value;
    }
  }
  return 'left';
}

class _SinanAlignButton extends StatefulWidget {
  const _SinanAlignButton({
    required this.editorState,
    required this.selection,
    required this.align,
    required this.iconColor,
    required this.highlightColor,
  });

  final EditorState editorState;
  final Selection selection;
  final String align;
  final Color? iconColor;
  final Color highlightColor;

  @override
  State<_SinanAlignButton> createState() => _SinanAlignButtonState();
}

class _SinanAlignButtonState extends State<_SinanAlignButton> {
  OverlayEntry? _overlay;

  @override
  void dispose() {
    _dismiss();
    super.dispose();
  }

  void _showOverlay() {
    keepEditorFocusNotifier.increase();
    final RenderBox box = context.findRenderObject()! as RenderBox;
    final Offset offset = box.localToGlobal(Offset.zero);
    final Size size = box.size;

    _overlay = OverlayEntry(
      builder: (BuildContext context) => _AlignOverlay(
        editorState: widget.editorState,
        selection: widget.selection,
        currentAlign: widget.align,
        anchorOffset: offset,
        anchorSize: size,
        onDismiss: _dismiss,
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_overlay!);
  }

  void _dismiss() {
    if (_overlay != null) {
      _overlay!.remove();
      _overlay = null;
      keepEditorFocusNotifier.decrease();
    }
  }

  @override
  Widget build(BuildContext context) {
    final IconData icon = switch (widget.align) {
      'center' => tabler.AlignCenter(height: 24, width: 24, strokeWidth: 1.5),
      'right' => tabler.AlignRight(height: 24, width: 24, strokeWidth: 1.5),
      _ => tabler.AlignLeft(height: 24, width: 24, strokeWidth: 1.5),
    };
    final Color color =
        widget.iconColor ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return SVGIconItemWidget(
      // 当前对齐图标 + 小箭头（"这是下拉"的可供性，与块样式按钮一致）。
      iconBuilder: (BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: Tokens.iconSm, color: color),
          tabler.ChevronDown(height: 12, width: 12, strokeWidth: 1.5, colorFilter: ui.ColorFilter.mode(color.withValues(alpha: 0.7, ui.BlendMode.srcIn))),
        ],
      ),
      isHighlight: false,
      highlightColor: widget.highlightColor,
      iconColor: widget.iconColor,
      onPressed: _showOverlay,
    );
  }
}

class _AlignOption {
  const _AlignOption(this.align, this.label, this.icon, this.shortcut);

  final String align;
  final String label;
  final IconData icon;
  final String shortcut;
}

class _AlignOverlay extends StatelessWidget {
  const _AlignOverlay({
    required this.editorState,
    required this.selection,
    required this.currentAlign,
    required this.anchorOffset,
    required this.anchorSize,
    required this.onDismiss,
  });

  final EditorState editorState;
  final Selection selection;
  final String currentAlign;
  final Offset anchorOffset;
  final Size anchorSize;
  final VoidCallback onDismiss;

  // 248：容得下「图标 + 名称 + 勾选 + 右对齐快捷键」一整行并留余量。
  // （160 时快捷键标注会被挤出面板、点不到——实测；216 仍差 0.8px 溢出。）
  static const double _panelWidth = 248;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    const List<_AlignOption> options = <_AlignOption>[
      _AlignOption('left', '左对齐', tabler.AlignLeft(height: 24, width: 24, strokeWidth: 1.5), 'Ctrl+Shift+L'),
      _AlignOption('center', '居中', tabler.AlignCenter(height: 24, width: 24, strokeWidth: 1.5), 'Ctrl+Shift+E'),
      _AlignOption('right', '右对齐', tabler.AlignRight(height: 24, width: 24, strokeWidth: 1.5), 'Ctrl+Shift+R'),
    ];

    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onDismiss,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: anchorOffset.dx,
          top: anchorOffset.dy + anchorSize.height + 4,
          child: AppFloatSurface(
            width: _panelWidth,
            padding: const EdgeInsets.symmetric(vertical: Tokens.spaceXs),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: options.map((_AlignOption o) {
                final bool active = o.align == currentAlign;
                return InkWell(
                  onTap: () {
                    _applyAlign(o.align);
                    onDismiss();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Tokens.spaceMd,
                      vertical: Tokens.spaceSm,
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          o.icon,
                          size: Tokens.iconSm,
                          color: active
                              ? scheme.onSurface
                              : scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: Tokens.spaceSm),
                        Expanded(
                          child: Text(
                            o.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: active
                                      ? scheme.onSurface
                                      : scheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                        if (active) ...<Widget>[
                          tabler.Check(height: 14, width: 14, strokeWidth: 1.5, colorFilter: ui.ColorFilter.mode(scheme.onSurface, ui.BlendMode.srcIn)),
                          const SizedBox(width: Tokens.spaceXs),
                        ],
                        // 快捷键右对齐标注（与块样式菜单同一惯例）。
                        Text(
                          shortcutLabel(o.shortcut),
                          maxLines: 1,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: scheme.onSurfaceVariant.withValues(
                                  alpha: 0.85,
                                ),
                                fontSize: Tokens.fontSizeSm,
                              ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ],
    );
  }

  void _applyAlign(String align) {
    unawaited(
      editorState.updateNode(
        selection,
        (Node node) => node.copyWith(
          attributes: <String, dynamic>{
            ...node.attributes,
            blockComponentAlign: align,
          },
        ),
      ),
    );
  }
}
