import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/theme/app_theme.dart';

/// **玻璃档的两个渐变令牌**（`AppFloatSurface(glass: true)` 消费）。
///
/// 它们只负责"质感"，错起来却很难看 —— 而且**很难靠眼睛归因**（看着"有点脏"，
/// 但说不清是哪儿）。所以这里把三条最容易犯的错钉成机器可检：
/// 1. 淡出端写成 `Colors.transparent`（= 透明**黑**）⇒ 渐变中段插出灰带；
/// 2. 光泽拉满整块面板（应该 45% 处就归零，否则下半部一起被洗白）；
/// 3. 暗色的光边没收够（近黑面上白线极显眼，一超就"塑料亮边"）。
void main() {
  for (final Brightness b in Brightness.values) {
    test('渐变的淡出端必须是**白**的透明，不是透明黑（$b）', () {
      for (final (String name, LinearGradient g) in <(String, LinearGradient)>[
        ('内光泽 glassSheen', AppTheme.glassSheen(b)),
        ('顶沿光边 glassRim', AppTheme.glassRim(b)),
      ]) {
        for (final Color c in g.colors) {
          expect(
            (c.r, c.g, c.b),
            (1.0, 1.0, 1.0),
            reason:
                '$name 用了非白的端色 ⇒ 插值会在中段拉出灰带'
                '（近黑面板上就是一道脏印）；淡出请用 `白.withValues(alpha: 0)`',
          );
        }
        expect(g.colors.last.a, 0, reason: '$name 没有淡出端');
      }
    });
  }

  test('内光泽：只压上半（顶端 = glassSheenAlpha，45% 处归零）', () {
    final LinearGradient g = AppTheme.glassSheen(Brightness.dark);
    expect(g.colors.first.a, closeTo(AppTheme.glassSheenAlpha, 1e-9));
    expect(g.stops, <double>[0, 0.45], reason: '光泽拉满整块面板会把下半部一起洗白');
    expect(
      AppTheme.glassSheenAlpha,
      lessThanOrEqualTo(0.08),
      reason: '超过 ~8% 立刻读成"塑料 / 油面"（本次取 5%）',
    );
  });

  test('顶沿光边：暗色必须比亮色收得多（近黑面上白线极显眼）', () {
    expect(
      AppTheme.glassRimAlpha(Brightness.dark),
      lessThanOrEqualTo(0.10),
      reason: '暗色白线一超 ~10% 就成"塑料亮边"（本次取 8%）',
    );
    expect(
      AppTheme.glassRimAlpha(Brightness.light),
      greaterThan(AppTheme.glassRimAlpha(Brightness.dark)),
      reason: '亮色面板本来就近白，光边是它唯一的"亮"，要更强才看得见',
    );
  });
}
