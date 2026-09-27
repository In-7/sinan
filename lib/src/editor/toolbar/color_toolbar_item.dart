import 'package:appflowy_editor/appflowy_editor.dart';

import 'dart:ui' as ui;

import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;
import 'package:material_ui/material_ui.dart';

import '../../theme/app_float_surface.dart';
import '../../theme/tokens.dart';

/// 颜色工具栏条目：两?字体颜色"两?背景颜色"合并到一个面板里官?
///
/// 官方 [buildTextColorItem] / [buildHighlightColorItem] 是两个独立按钮(?
/// 各自弹一个浮层。这里改成单按钮 ,?双区色板，与参考图的交互一致,?
final ToolbarItem sinanColorItem = ToolbarItem(
  id: 'sinan.color',
  group: 4,
  isActive: onlyShowInTextType,
  builder: (context, editorState, highlightColor, iconColor, tooltipBuilder) {
    final selection = editorState.selection!;
    final Widget child = _SinanColorButton(
      editorState: editorState,
      selection: selection,
      iconColor: iconColor,
      highlightColor: highlightColor,
    );
    if (tooltipBuilder != null) {
      return tooltipBuilder(context, 'sinan.color', '颜色', child);
    }
    return child;
  },
);

class _SinanColorButton extends StatefulWidget {
  const _SinanColorButton({
    required this.editorState,
    required this.selection,
    required this.iconColor,
    required this.highlightColor,
  });

  final EditorState editorState;
  final Selection selection;
  final Color? iconColor;
  final Color highlightColor;

  @override
  State<_SinanColorButton> createState() => _SinanColorButtonState();
}

class _SinanColorButtonState extends State<_SinanColorButton> {
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
      builder: (BuildContext context) => _ColorOverlay(
        editorState: widget.editorState,
        selection: widget.selection,
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
    return SVGIconItemWidget(
      iconBuilder: (BuildContext context) => tabler.Palette(
        height: Tokens.iconSm,
        width: Tokens.iconSm,
        strokeWidth: 1.5,
        colorFilter: ui.ColorFilter.mode(
          widget.iconColor ?? Theme.of(context).colorScheme.onSurfaceVariant,
          ui.BlendMode.srcIn,
        ),
      ),
      isHighlight: false,
      highlightColor: widget.highlightColor,
      iconColor: widget.iconColor,
      onPressed: _showOverlay,
    );
  }
}

class _ColorOverlay extends StatelessWidget {
  const _ColorOverlay({
    required this.editorState,
    required this.selection,
    required this.anchorOffset,
    required this.anchorSize,
    required this.onDismiss,
  });

  final EditorState editorState;
  final Selection selection;
  final Offset anchorOffset;
  final Size anchorSize;
  final VoidCallback onDismiss;

  static const double _panelWidth = 240;
  static const double _panelPadding = Tokens.spaceMd * 2;

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final double left =
        (anchorOffset.dx + _panelWidth + _panelPadding) > screenWidth
        ? screenWidth - _panelWidth - _panelPadding
        : anchorOffset.dx;

    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: GestureDetector(
            behavior: .translucent,
            onTap: onDismiss,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: left,
          top: anchorOffset.dy + anchorSize.height + 4,
          child: _SinanColorPanel(
            editorState: editorState,
            selection: selection,
            onDone: onDismiss,
          ),
        ),
      ],
    );
  }
}

class _SinanColorPanel extends StatelessWidget {
  const _SinanColorPanel({
    required this.editorState,
    required this.selection,
    required this.onDone,
  });

  final EditorState editorState;
  final Selection selection;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final List<Node> nodes = editorState.getNodesInSelection(selection);
    final String? textColor = _commonColor(
      nodes,
      selection,
      AppFlowyRichTextKeys.textColor,
    );
    final String? backgroundColor = _commonColor(
      nodes,
      selection,
      AppFlowyRichTextKeys.backgroundColor,
    );

    return AppFloatSurface(
      // 浮层令牌,?026-09-14）：色板是弹出浮层，底色/描边/投影走三件套
      // （此前是 `Card.filled` + 画布[?[?与纸面同色、且无描边无投影）[?
      child: Padding(
        padding: const EdgeInsets.all(Tokens.spaceMd),
        child: SizedBox(
          width: 240,
          child: Column(
            mainAxisSize: .min,
            crossAxisAlignment: .start,
            children: <Widget>[
              _buildSection(
                context,
                label: '字体颜色',
                options: generateTextColorOptions(),
                currentColor: textColor,
                onSelected: (String? color) {
                  formatFontColor(editorState, editorState.selection, color);
                  onDone();
                },
              ),
              const SizedBox(height: Tokens.spaceMd),
              _buildSection(
                context,
                label: '背景颜色',
                options: generateHighlightColorOptions(),
                currentColor: backgroundColor,
                onSelected: (String? color) {
                  formatHighlightColor(
                    editorState,
                    editorState.selection,
                    color,
                  );
                  onDone();
                },
              ),
              if (textColor != null || backgroundColor != null) ...[
                const SizedBox(height: Tokens.spaceMd),
                SizedBox(
                  width: double.infinity,
                  child: TextButton.icon(
                    onPressed: () {
                      if (textColor != null) {
                        formatFontColor(
                          editorState,
                          editorState.selection,
                          null,
                        );
                      }
                      if (backgroundColor != null) {
                        formatHighlightColor(
                          editorState,
                          editorState.selection,
                          null,
                        );
                      }
                      onDone();
                    },
                    icon: const tabler.Eraser(
                      height: Tokens.iconSm,
                      width: Tokens.iconSm,
                      strokeWidth: 1.5,
                    ),
                    label: const Text('恢复默认'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String? _commonColor(
    List<Node> nodes,
    Selection selection,
    String key,
  ) {
    String? color;
    bool first = true;
    final bool allSame = nodes.allSatisfyInSelection(selection, (Delta delta) {
      if (delta.isEmpty) return true;
      return delta.everyAttributes((Attributes attr) {
        final String? value = attr[key] as String?;
        if (first) {
          color = value;
          first = false;
          return true;
        }
        return color == value;
      });
    });
    return allSame ? color : null;
  }

  Widget _buildSection(
    BuildContext context, {
    required String label,
    required List<ColorOption> options,
    required String? currentColor,
    required ValueChanged<String?> onSelected,
  }) {
    return Column(
      crossAxisAlignment: .start,
      children: <Widget>[
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: Tokens.spaceXs),
        Wrap(
          spacing: Tokens.spaceXs,
          runSpacing: Tokens.spaceXs,
          children: <Widget>[
            _ColorSwatch(
              color: null,
              isSelected: currentColor == null,
              onTap: () => onSelected(null),
            ),
            ...options.map(
              (ColorOption option) => _ColorSwatch(
                color: option.colorHex.tryToColor(),
                isSelected: option.colorHex == currentColor,
                onTap: () => onSelected(option.colorHex),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.color,
    required this.isSelected,
    required this.onTap,
  });

  final Color? color;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    const double size = 24;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(size / 2),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color ?? scheme.onSurfaceVariant,
          shape: .circle,
          border: Border.all(
            color: isSelected ? scheme.onSurface : scheme.outlineVariant,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: color == null
            ? tabler.X(
                height: Tokens.iconXs,
                width: Tokens.iconXs,
                strokeWidth: 1.5,
                colorFilter: ui.ColorFilter.mode(
                  scheme.onSurfaceVariant,
                  ui.BlendMode.srcIn,
                ),
              )
            : isSelected
            ? tabler.Check(
                height: Tokens.iconXs,
                width: Tokens.iconXs,
                strokeWidth: 1.5,
                colorFilter: ui.ColorFilter.mode(
                  scheme.onPrimary,
                  ui.BlendMode.srcIn,
                ),
              )
            : null,
      ),
    );
  }
}
