import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/theme/app_theme.dart';

/// 编辑器浮层（下拉菜单）若取**画布色**做底：文字对比度是否满足 WCAG。
void main() {
  test('打印各预设下 画布底 的对比度', () {
    for (final Color seed in AppTheme.seedPresets) {
      for (final ThemeData theme in <ThemeData>[
        AppTheme.light(seed: seed),
        AppTheme.dark(seed: seed),
      ]) {
        final ColorScheme s = theme.colorScheme;
        final Color bg = AppTheme.contentCanvas(theme.brightness);
        String p(String label, Color fg) =>
            '$label=${_contrast(fg, bg).toStringAsFixed(2)}';
        // ignore: avoid_print
        print(
          '${theme.brightness.name.padRight(5)} seed=#${seed.toARGB32().toRadixString(16).substring(2)} '
          'bg=#${bg.toARGB32().toRadixString(16).substring(2)} '
          '${p('onSurface', s.onSurface)} '
          '${p('onSurfaceVar', s.onSurfaceVariant)} '
          '${p('primary', s.primary)} '
          '${p('primary@.85', s.onSurfaceVariant.withValues(alpha: 0.85).withValues(alpha: 0.85))}',
        );
      }
    }
  });
}

/// WCAG 相对亮度。
double _luminance(Color c) {
  double ch(double v) {
    final double x = v;
    return x <= 0.03928 ? x / 12.92 : math.pow((x + 0.055) / 1.055, 2.4).toDouble();
  }

  final double r = ch(c.r);
  final double g = ch(c.g);
  final double b = ch(c.b);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/// WCAG 对比度（1 ~ 21）。
double _contrast(Color a, Color b) {
  final double la = _luminance(a);
  final double lb = _luminance(b);
  final double hi = math.max(la, lb);
  final double lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}
