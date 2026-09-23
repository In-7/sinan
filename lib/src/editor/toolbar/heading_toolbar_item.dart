import 'dart:async';
import 'dart:ui' as ui;
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:material_ui/material_ui.dart';

import '../../theme/app_float_surface.dart';
import '../../theme/tokens.dart';
import '../core/shortcut_label.dart';

/// 块样式（**正文 / 标题 1~3 合并成一个下拉按钮**）。
///
/// ## 为什么合并 + 成熟方案长什么样
/// 主流文档应用的"块样式"都是**一个下拉**，而不是 4 个平铺按钮：
/// - **Google Docs / Word**：「样式」下拉，**按钮显示当前样式**；
/// - **飞书 / 语雀**：顶栏「正文 / 标题」下拉；
/// - **Notion**：块类型菜单（拖柄点开或输入 `/`）；
/// - **桌面软件菜单惯例**：菜单项右侧**右对齐标注快捷键**
///   （Material 的 `MenuItemButton.shortcut` 就是这个惯例的官方实现）。
///
/// 这里取三者的交集：按钮显示当前样式 + 下拉四选一 + 每项右侧标快捷键 +
/// 当前项打勾。好处与颜色/对齐条目一致：省 3 个槽位、激活态一眼可读、
/// 新增档位（h4~h6）不用再占工具栏位置。
///
/// ## 语义差异（有意为之）
/// - **下拉里选一项 = 直接应用**该样式（Word/Google Docs 的样式下拉语义，
///   重复选同一项不会跳回正文）；
/// - **快捷键仍是 toggle**（官方 `Ctrl+Shift+B/T/G/J`，appflowy 原生行为，
///   未改动）——tooltip 里声明的就是这四个键。
final ToolbarItem sinanHeadingItem = ToolbarItem(
  id: 'sinan.heading',
  group: 1,
  isActive: onlyShowInTextType,
  builder: (context, editorState, highlightColor, iconColor, tooltipBuilder) {
    final Selection selection = editorState.selection!;
    final Node? node = editorState.getNodeAtPath(selection.start.path);
    final int? level = currentHeadingLevel(node);

    final Widget child = _SinanHeadingButton(
      editorState: editorState,
      selection: selection,
      level: level,
      iconColor: iconColor,
      highlightColor: highlightColor,
    );
    if (tooltipBuilder != null) {
      return tooltipBuilder(context, 'sinan.heading', '段落样式', child);
    }
    return child;
  },
);

/// 当前块是几级标题；非标题（或空块）返回 null。
int? currentHeadingLevel(Node? node) {
  if (node == null || node.type != HeadingBlockKeys.type) return null;
  final Object? level = node.attributes[HeadingBlockKeys.level];
  return level is int ? level : 1;
}

/// 应用块样式：[level] 为 null 即正文。
///
/// 与官方 `toggleBody/toggleH1~H3` 的差别只在"不做 toggle"；属性处理照抄
/// 官方：**只带走背景色 / 文字方向 / 文本 delta**，其余不继承（避免把待办
/// 的 `checked` 之类脏属性带给标题）。转正文时**摘掉 level**，不留脏数据。
void applyBlockStyle(
  EditorState editorState,
  Selection selection, {
  int? level,
}) {
  unawaited(
    editorState.formatNode(
      selection,
      (Node node) => node.copyWith(
        type: level == null ? ParagraphBlockKeys.type : HeadingBlockKeys.type,
        attributes: <String, dynamic>{
          // 转正文时不带 level（`?` = 值为 null 就整条省略），不留脏属性。
          HeadingBlockKeys.level: ?level,
          blockComponentBackgroundColor:
              node.attributes[blockComponentBackgroundColor],
          blockComponentTextDirection:
              node.attributes[blockComponentTextDirection],
          blockComponentDelta: (node.delta ?? Delta()).toJson(),
        },
      ),
    ),
  );
}

/// 档位定义（顺序即菜单顺序）：正文 + 标题 1~3。
///
/// 快捷键取自官方绑定（`heading_command_shortcut.dart`），改这里等于同时改
/// 菜单标注——`fixed_toolbar_test.dart` 会核对它们与官方命令一致。
class _BlockStyle {
  const _BlockStyle(this.level, this.label, this.icon, this.shortcut);

  final int? level;
  final String label;
  final Widget icon;
  final String shortcut;
}

const List<_BlockStyle> _styles = <_BlockStyle>[
  _BlockStyle(null, '正文', tabler.Typography(height: Tokens.iconSm, width: Tokens.iconSm, strokeWidth: 1.5), 'Ctrl+Shift+B'),
  _BlockStyle(1, '标题 1', tabler.H1(height: Tokens.iconSm, width: Tokens.iconSm, strokeWidth: 1.5), 'Ctrl+Shift+T'),
  _BlockStyle(2, '标题 2', tabler.H2(height: Tokens.iconSm, width: Tokens.iconSm, strokeWidth: 1.5), 'Ctrl+Shift+G'),
  _BlockStyle(3, '标题 3', tabler.H3(height: Tokens.iconSm, width: Tokens.iconSm, strokeWidth: 1.5), 'Ctrl+Shift+J'),
];

class _SinanHeadingButton extends StatefulWidget {
  const _SinanHeadingButton({
    required this.editorState,
    required this.selection,
    required this.level,
    required this.iconColor,
    required this.highlightColor,
  });

  final EditorState editorState;
  final Selection selection;
  final int? level;
  final Color? iconColor;
  final Color highlightColor;

  @override
  State<_SinanHeadingButton> createState() => _SinanHeadingButtonState();
}

class _SinanHeadingButtonState extends State<_SinanHeadingButton> {
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
      builder: (BuildContext context) => _HeadingOverlay(
        editorState: widget.editorState,
        selection: widget.selection,
        currentLevel: widget.level,
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
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 当前样式图标 + 小箭头（箭头是"这是下拉"的可供性，与对齐按钮一致）。
    final _BlockStyle current = _styles.firstWhere(
      (_BlockStyle s) => s.level == widget.level,
      orElse: () => _styles.first,
    );
    final Color color =
        widget.iconColor ?? scheme.onSurfaceVariant;

    return SVGIconItemWidget(
      iconBuilder: (BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          current.icon,
          tabler.ChevronDown(height: Tokens.iconXxs, width: Tokens.iconXxs, strokeWidth: 1.5, colorFilter: ui.ColorFilter.mode(color.withValues(alpha: 0.7), ui.BlendMode.srcIn)),
        ],
      ),
      // 光标落在标题里时点亮（"你在某级标题上"），与旧的四按钮行为等价。
      isHighlight: widget.level != null,
      highlightColor: widget.highlightColor,
      iconColor: widget.iconColor,
      onPressed: _showOverlay,
    );
  }
}

class _HeadingOverlay extends StatelessWidget {
  const _HeadingOverlay({
    required this.editorState,
    required this.selection,
    required this.currentLevel,
    required this.anchorOffset,
    required this.anchorSize,
    required this.onDismiss,
  });

  final EditorState editorState;
  final Selection selection;
  final int? currentLevel;
  final Offset anchorOffset;
  final Size anchorSize;
  final VoidCallback onDismiss;

  // 248：与对齐下拉菜单同宽，两个面板视觉完全统一。
  static const double _panelWidth = 248;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    final double screenWidth = MediaQuery.of(context).size.width;
    final double left =
        (anchorOffset.dx + _panelWidth + Tokens.spaceMd) > screenWidth
        ? screenWidth - _panelWidth - Tokens.spaceMd
        : anchorOffset.dx;

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
          left: left,
          top: anchorOffset.dy + anchorSize.height + 4,
          child: AppFloatSurface(
            width: _panelWidth,
            padding: const EdgeInsets.symmetric(vertical: Tokens.spaceXs),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final _BlockStyle style in _styles)
                  _row(
                    context,
                    style: style,
                    active: style.level == currentLevel,
                    scheme: scheme,
                    textTheme: textTheme,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(
    BuildContext context, {
    required _BlockStyle style,
    required bool active,
    required ColorScheme scheme,
    required TextTheme textTheme,
  }) {
    final Color color = active ? scheme.onSurface : scheme.onSurfaceVariant;
    return InkWell(
      onTap: () {
        applyBlockStyle(editorState, selection, level: style.level);
        onDismiss();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Tokens.spaceMd,
          vertical: Tokens.spaceSm,
        ),
        child: Row(
          children: <Widget>[
            style.icon,
            const SizedBox(width: Tokens.spaceSm),
            Expanded(
              child: Text(
                style.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall?.copyWith(color: color),
              ),
            ),
            // 当前项打勾；快捷键**右对齐**标注（桌面软件菜单惯例）。
            if (active) ...<Widget>[
              tabler.Check(height: Tokens.iconXs, width: Tokens.iconXs, strokeWidth: 1.5, colorFilter: ui.ColorFilter.mode(scheme.onSurface, ui.BlendMode.srcIn)),
              const SizedBox(width: Tokens.spaceXs),
            ],
            Text(
              shortcutLabel(style.shortcut),
              maxLines: 1,
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
                fontSize: Tokens.fontSizeSm,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
