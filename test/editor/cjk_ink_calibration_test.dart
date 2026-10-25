import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/editor/blocks/block_markers.dart';
import 'package:sinan/src/theme/app_theme.dart';

import '../support/app_font.dart';

/// [cjkInkCompensation] 的**重标定闸门**（换字体必须回来改那个数）。
///
/// ## 为什么不断言"实测墨迹偏移"
/// 真正的标定要光栅化后逐行扫 alpha 找墨迹带（方法写在
/// `block_markers.dart` 的常量文档里），而 `Picture.toImage` 在 **flutter test
/// 里会挂住**（实测 Timeout，与是否 dispose 无关）⇒ 那条只能离线跑一次。
///
/// ## 那这条测什么
/// 退一步测**字体度量指纹**：ascent / descent（em）由字体决定，换字体就变。
/// 指纹一变 ⇒ 说明常量已经失准，必须按文档方法重新标定后再改这里。
/// 这条便宜、秒级、且能抓住"换字体忘记重标"这个真实失败模式。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('字体度量指纹 = 思源黑体 SC VF（变了 ⇒ 重标 cjkInkCompensation）', () async {
    await loadAppFont();

    const double fs = 200;
    const double height = 1.5;
    final TextPainter painter = TextPainter(
      text: const TextSpan(
        text: '国',
        style: TextStyle(
          fontFamily: AppTheme.editorFont,
          fontSize: fs,
          height: height,
          leadingDistribution: TextLeadingDistribution.even,
          color: const Color(0xFF000000), // ignore: unnecessary_const
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: fs * 4);

    final LineMetrics m = painter.computeLineMetrics().first;
    final double ascentEm = m.ascent / fs;
    final double descentEm = m.descent / fs;

    // 思源黑体 SC @ height 1.5 的实测指纹（2026-10-24）。
    expect(ascentEm, closeTo(1.186, 0.01), reason: '字体度量变了 ⇒ 重标墨迹补偿');
    expect(descentEm, closeTo(0.314, 0.01), reason: '字体度量变了 ⇒ 重标墨迹补偿');
    // ascent + descent 恰好等于行高（even 分布的必然结果）。
    expect(ascentEm + descentEm, closeTo(height, 1e-6));

    // 与之配套的系数（五组样本实测平均 +0.060em ⇒ −0.06）。
    expect(cjkInkCompensation, -0.06, reason: '与上面的指纹成对，改一个要改两个');
    painter.dispose();
  });
}
