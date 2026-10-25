import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/theme/app_theme.dart';

import '../support/app_font.dart';

/// **思源黑体 SC 可变字体**：`wght` 轴是否**真的生效**（默认字体，2026-10-24）。
///
/// 为什么要这条测试：可变字体“看起来生效”非常容易——`fontWeight: w600` 写出来
/// 界面就变粗了，但那可能是**引擎合成加粗**，不是 VF 实例化的真字重。而 Flutter
/// **不会**把 `fontWeight` 映射到 `wght` 轴（已核对 3.47 源码：`'wght'` 只出现在
/// 显式传 `fontVariations` 的地方）。所以必须**量**出来：
/// 同一串拉丁字母在 w400 与 w600 下**宽度不同** ⇒ 轴生效；宽度相同 ⇒ 还是同一个
/// 默认实例（等于白换）。
///
/// 实测值（100px 下量「MMMMiiii」）：w400≈434.8 / w600≈455.2 / w700≈462.8。
void main() {
  testWidgets('wght 轴真生效：400 / 600 / 700 三档宽度互不相同', (tester) async {
    await loadAppFont();

    /// 量一串拉丁字母的宽度（拉丁是比例宽度 ⇒ 字重不同则 advance 不同；
    /// CJK 各字重都是 1em，**单看中文测不出**轴生效）。
    double widthAt(double wght) {
      final TextPainter painter = TextPainter(
        text: TextSpan(
          text: 'MMMMiiii',
          style: TextStyle(
            fontFamily: AppTheme.editorFont,
            fontSize: 100,
            fontWeight: FontWeight.w400,
            fontVariations: <FontVariation>[FontVariation('wght', wght)],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final double w = painter.width;
      painter.dispose();
      return w;
    }

    final double w400 = widthAt(400);
    final double w600 = widthAt(600);
    final double w700 = widthAt(700);

    // 轴生效 ⇒ 三个实例不是同一份 ⇒ 宽度有差异（哪怕只有零点几像素）。
    // （实测：w400≈434.8 / w600≈455.2 / w700≈462.8 @100px「MMMMiiii」）
    expect(
      w400,
      isNot(w600),
      reason: 'wght 轴没生效：400 与 600 渲染宽度相同 ⇒ 还是合成加粗（换了等于白换）',
    );
    expect(w600, isNot(w700), reason: 'wght 轴没生效：600 与 700 渲染宽度相同');
    // 顺序也该是"越重越宽"（拉丁的 M 在重字重下更宽）。
    expect(w700, greaterThanOrEqualTo(w600), reason: '字重递增，拉丁宽度不该变窄');
  });
}
