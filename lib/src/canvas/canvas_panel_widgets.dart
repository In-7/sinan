/// 画布浮层面板里的小件（笔刷面板与形状属性面板共用）�?
///
/// 单独一份的理由：这两个面板的滑杆与图标必须**永远同形�?*，而浮层里最容易
/// 悄悄漂移的就是这类小件（各自 `copyWith` 一次就分叉了）�?
library;

import 'package:material_ui/material_ui.dart';

/// 紧凑高度的小滑杆：默�?`Slider` 的上下留白在浮层面板里太空�?
///
/// [onChanged] �?null 表示该项当前不适用（如填充形状�?描边粗细"）—�""?
/// 显示为禁用态，而不是让用户拖了没反应�?
class CanvasPanelSlider extends StatelessWidget {
  const CanvasPanelSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final double value;
  final double min;
  final double max;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 3,
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
      ),
      child: Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        onChanged: onChanged,
      ),
    );
  }
}

/// 图标 + 右下角一�?当前颜色"圆点�""?
///
/// 颜色类设置（笔色 / 图形描边色）改完必须**一眼可�?*：工具栏其余按钮都是
/// 无状态图标，只靠图标本身用户看不出颜色改了没有�?
class CanvasInkDotIcon extends StatelessWidget {
  const CanvasInkDotIcon({super.key, required this.icon, required this.ink});

  final Widget icon;

  /// 已解析成实际绘制色的颜色（哨兵要先解析，否则暗色下发黑）�?
  final Color ink;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: <Widget>[
        icon,
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: ink,
              shape: .circle,
              // 描边让浅色墨点在浅色工具条上也有轮廓�?
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
