import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;
import 'package:material_ui/material_ui.dart';

import 'tokens.dart';

/// 一个可选中的颜色项。
///
/// [value] 与 [display] 分开是**必需的**：画布墨色里 `kThemeInk` 是"跟随主题"的
/// **哨兵**，回调要拿哨兵（才能自动跟随），但画出来得是**解析后的真实颜色**
/// ——否则暗色浮层上那个"当前墨色"的圆点就是近黑，等于看不见。
class AppColorOption {
  const AppColorOption({required this.value, Color? display, this.tooltip})
    : display = display ?? value;

  /// 选中时回调出去的值（可以是哨兵）。
  final Color value;

  /// 实际画出来的颜色（默认与 [value] 相同）。
  final Color display;

  final String? tooltip;
}

/// 圆形色块：选中态加粗描边 + 对勾。
///
/// 与编辑器色板里的私有实现**同形制**（24 圆 + 对勾 + 描边），但这一份**不依赖
/// `EditorState`**，供画布等其它模块复用（编辑器那份早于本文件，暂未回迁）。
class AppColorSwatch extends StatelessWidget {
  const AppColorSwatch({
    super.key,
    required this.color,
    required this.isSelected,
    required this.onTap,
    this.size = 24,
    this.tooltip,
  });

  final Color color;
  final bool isSelected;
  final VoidCallback onTap;
  final double size;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget dot = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(size / 2),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? scheme.onSurface : scheme.outlineVariant,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: isSelected
            ? tabler.Check(height: size * 0.58, width: size * 0.58, strokeWidth: 1.5)
            : null,
      ),
    );
    // tooltip 传空串时 Tooltip 仍会占位；用条件包裹避免无谓的层。
    return tooltip == null ? dot : Tooltip(message: tooltip!, child: dot);
  }
}

/// 一组色块（自动换行）。
class AppColorGrid extends StatelessWidget {
  const AppColorGrid({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelect,
    this.swatchSize = 24,
  });

  final List<AppColorOption> options;

  /// 当前选中值：与 [AppColorOption.value] 比较（**不是** display）。
  final Color selected;

  final ValueChanged<Color> onSelect;
  final double swatchSize;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: Tokens.spaceSm,
      runSpacing: Tokens.spaceSm,
      children: <Widget>[
        for (final AppColorOption option in options)
          AppColorSwatch(
            color: option.display,
            isSelected: option.value == selected,
            size: swatchSize,
            tooltip: option.tooltip,
            onTap: () => onSelect(option.value),
          ),
      ],
    );
  }
}
