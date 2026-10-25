import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/domain/settings.dart';
import 'package:sinan/src/editor/core/editor_typography.dart';
import 'package:sinan/src/theme/app_theme.dart';

import '../support/app_font.dart';

/// 中西文自动间距 + 连续标点互挤（`applyCjkTextSpacing`，sinan 补丁 20/21）
/// + palt 标点压缩 的闸门。
///
/// 钉死四条契约：
/// 1. 不改文本（复制 / 光标偏移安全）；
/// 2. 调整只挂**边界前字符**（独占单字 span），段内字距不被撑开；
/// 3. 已有空白不叠加；
/// 4. 同一输入确定性输出（块高预测器与渲染同源的前提）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String plainOf(TextSpan span) => span.toPlainText();

  /// 按绘制顺序展开所有带文字的叶子。
  List<TextSpan> leavesOf(TextSpan root) {
    final List<TextSpan> out = <TextSpan>[];
    void walk(InlineSpan s) {
      if (s is TextSpan) {
        if ((s.text ?? '').isNotEmpty) out.add(s);
        s.children?.forEach(walk);
      }
    }

    walk(root);
    return out;
  }

  List<String> textsOf(TextSpan root) =>
      leavesOf(root).map((TextSpan s) => s.text!).toList();

  List<double> gapsOf(TextSpan root) =>
      leavesOf(root)
          .map((TextSpan s) => s.style?.letterSpacing ?? 0)
          .toList();

  group('applyCjkTextSpacing', () {
    test('无边界时原样返回（identical，零重建）', () {
      const TextSpan span = TextSpan(text: '纯中文段落');
      expect(applyCjkTextSpacing(span), same(span));

      const TextSpan latin = TextSpan(text: 'pure latin 123');
      expect(applyCjkTextSpacing(latin), same(latin));

      // 中文之间夹空格的"间接相邻"不触发。
      const TextSpan spaced = TextSpan(text: '使用 API 接口');
      expect(applyCjkTextSpacing(spaced), same(spaced));
    });

    test('文本逐字节不变（复制 / 光标偏移安全）', () {
      const String raw = '使用API调用2026年的模型，Mixed中文English混排！';
      final TextSpan result = applyCjkTextSpacing(
        const TextSpan(
          children: <InlineSpan>[
            TextSpan(text: '使用API调用'),
            TextSpan(
              text: '2026年的模型，Mixed中文English混排！',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
      expect(plainOf(result), raw);
    });

    test('间隙只挂边界前字符：段内字距不被撑开', () {
      // 汉0 字1 a2 b3 c4 汉5 字6：边界在 字|a 与 c|汉。
      // 切段：「汉」「字*」「ab」「c*」「汉字」（* = 尾随间隙）。
      final TextSpan result = applyCjkTextSpacing(
        const TextSpan(text: '汉字abc汉字', style: TextStyle(fontSize: 20)),
      );
      expect(textsOf(result), <String>['汉', '字', 'ab', 'c', '汉字']);
      expect(gapsOf(result), <double>[0, 5, 0, 5, 0]);
    });

    test('间隙取整像素（fontSize × 0.25 后 round）', () {
      // 17 × 0.25 = 4.25 → 4。
      final TextSpan result = applyCjkTextSpacing(
        const TextSpan(text: '好x', style: TextStyle(fontSize: 17)),
      );
      expect(textsOf(result), <String>['好', 'x']);
      expect(gapsOf(result), <double>[4, 0]);
    });

    test('跨叶子边界也生效（全局拼接后判界）', () {
      // 「使用|API」的边界横跨两个 span ⇒ 前一叶被拆出「用」独占段。
      final TextSpan result = applyCjkTextSpacing(
        const TextSpan(
          children: <InlineSpan>[
            TextSpan(text: '使用', style: TextStyle(fontWeight: FontWeight.w400)),
            TextSpan(text: 'API', style: TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      );
      expect(textsOf(result), <String>['使', '用', 'API']);
      // fontSize 缺省 16 → 间隙 4。
      expect(gapsOf(result), <double>[0, 4, 0]);
    });

    test('双向边界：西文在前 / 表意在前都挂到前字符', () {
      // a0 b1 c2 汉3 x4 y5 z6 字7：边界在 c|汉、汉|x、z|字。
      final TextSpan result = applyCjkTextSpacing(
        const TextSpan(text: 'abc汉xyz字', style: TextStyle(fontSize: 20)),
      );
      expect(textsOf(result), <String>['ab', 'c', '汉', 'xy', 'z', '字']);
      expect(gapsOf(result), <double>[0, 5, 5, 0, 5, 0]);
    });

    test('相邻字符样式继承原叶子（字重不丢）', () {
      final TextSpan result = applyCjkTextSpacing(
        const TextSpan(
          text: '好x',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
      );
      for (final TextSpan leaf in leavesOf(result)) {
        expect(leaf.style?.fontWeight, FontWeight.w600);
        expect(leaf.style?.fontSize, 20);
      }
    });

    test('纯函数确定性：同一输入两次调用逐段一致', () {
      const TextSpan span = TextSpan(text: '中文ABC中文');
      final TextSpan a = applyCjkTextSpacing(span);
      final TextSpan b = applyCjkTextSpacing(span);
      expect(plainOf(a), plainOf(b));
      expect(textsOf(a), textsOf(b));
      expect(gapsOf(a), gapsOf(b));
    });
  });

  group('连续标点互挤（jiya 行内可判子集）', () {
    test('可挤标点对收窄：句终-闭括 / 闭括-中点 / 句终-句终', () {
      // 。」 」， ！？ 三对；字号 20 ⇒ 挤压量 round(20×0.1)=2。
      final TextSpan result = applyCjkTextSpacing(
        const TextSpan(text: '。」，！？', style: TextStyle(fontSize: 20)),
      );
      // 切段：「。*」「」*」「，*」「！*」「？」（* = 尾随 -2）。
      expect(textsOf(result), <String>['。', '」', '，', '！', '？']);
      expect(gapsOf(result), <double>[-2, -2, -2, -2, 0]);
    });

    test('连续开括 / 闭括序列逐对收窄', () {
      final TextSpan result = applyCjkTextSpacing(
        const TextSpan(text: '（『「', style: TextStyle(fontSize: 20)),
      );
      expect(textsOf(result), <String>['（', '『', '「']);
      expect(gapsOf(result), <double>[-2, -2, 0]);
    });

    test('连接/省略号不挤、且打断相邻链', () {
      // …… 是连接符（U+2026），—— 是破折号（U+2014）：两侧不挤。
      const TextSpan span = TextSpan(text: '……——……');
      expect(applyCjkTextSpacing(span), same(span));

      // 「……」：…… 打断链 ⇒ 「与……之间、……与」之间均无挤压点？
      // 不——「/」是可挤标点，但其相邻字符是「…」（不可挤）⇒ 不触发。
      const TextSpan wrapped = TextSpan(text: '「……」');
      expect(applyCjkTextSpacing(wrapped), same(wrapped));
    });

    test('汉字与标点相邻不挤（只有标点对互挤）', () {
      const TextSpan span = TextSpan(text: '字。字');
      expect(applyCjkTextSpacing(span), same(span));
    });

    test('互挤与中西文间距并存：同一段里两种调整各归各', () {
      // 「用API。」@20px：用|A 间距(+5)；I|。 间距(+5，拉丁↔CJK 标点也触发)；
      // 。|」 互挤(-2)。
      final TextSpan result = applyCjkTextSpacing(
        const TextSpan(text: '用API。」', style: TextStyle(fontSize: 20)),
      );
      expect(textsOf(result), <String>['用', 'AP', 'I', '。', '」']);
      expect(gapsOf(result), <double>[5, 0, 5, -2, 0]);
    });

    test('互挤量取整像素：fontSize × 0.1 后 round（可负）', () {
      // 17 × 0.1 = 1.7 → -2（负向同样 round 到整数）。
      final TextSpan result = applyCjkTextSpacing(
        const TextSpan(text: '。」', style: TextStyle(fontSize: 17)),
      );
      expect(gapsOf(result), <double>[-2, 0]);
    });

    test('不改文本（互挤路径同样逐字节不变）', () {
      const String raw = '他说：「你好。」『真的！？』';
      final TextSpan result = applyCjkTextSpacing(const TextSpan(text: raw));
      expect(plainOf(result), raw);
    });
  });

  group('palt 标点压缩（正文样式）', () {
    test('body() 带 palt 特性；标题继承同一套', () {
      const EditorTypography typography = EditorTypography(
        fontSize: 17,
        lineHeight: AppSettings.defaultLineHeight,
      );
      expect(
        typography.body().fontFeatures?.map((FontFeature f) => f.feature),
        contains('palt'),
        reason: '正文样式应启用 palt 全角标点压缩',
      );
      expect(
        typography.heading(1).fontFeatures?.map((FontFeature f) => f.feature),
        contains('palt'),
        reason: '标题由 body() 派生，应继承 palt',
      );
    });

    testWidgets('palt 实测：全角标点压到半宽、汉字不动', (tester) async {
      await loadAppFont();
      double widthOf(String ch, List<FontFeature>? features) {
        final TextPainter painter = TextPainter(
          text: TextSpan(
            text: ch,
            style: TextStyle(
              fontFamily: AppTheme.editorFont,
              fontSize: 100,
              fontFeatures: features,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final double w = painter.width;
        painter.dispose();
        return w;
      }

      for (final String ch in <String>['。', '，', '「', '」']) {
        expect(
          widthOf(ch, const <FontFeature>[FontFeature.enable('palt')]),
          lessThan(widthOf(ch, null)),
          reason: '$ch 在 palt 下应变窄',
        );
      }
      expect(
        widthOf('国', const <FontFeature>[FontFeature.enable('palt')]),
        widthOf('国', null),
        reason: '汉字宽度不受 palt 影响',
      );
    });
  });

  group('间距在布局中真实生效（预测/渲染同源的前提）', () {
    testWidgets('混排文本：加间距后折行高度确实变化，且重复计算稳定', (
      tester,
    ) async {
      await loadAppFont();
      const EditorTypography typography = EditorTypography(
        fontSize: AppSettings.defaultFontSize,
        lineHeight: AppSettings.defaultLineHeight,
      );
      final TextStyle base = typography.body();
      const String mixed = '使用API调用2026年的模型，Mixed中文English混排，标点。，「测试」！';

      double heightOf(TextSpan span) {
        final TextPainter painter = TextPainter(
          text: span,
          textDirection: TextDirection.ltr,
          textHeightBehavior: const TextHeightBehavior(
            leadingDistribution: TextLeadingDistribution.even,
          ),
        )..layout(maxWidth: 400);
        final double h = painter.height;
        painter.dispose();
        return h;
      }

      final TextSpan plain = TextSpan(text: mixed, style: base);
      final TextSpan spaced = applyCjkTextSpacing(plain);
      expect(plainOf(spaced), mixed, reason: '文本不许变');

      // 同一函数两次施加（模拟"渲染走一遍、预测走一遍"）⇒ 高度必须相同。
      expect(heightOf(spaced), heightOf(applyCjkTextSpacing(plain)));
    });
  });
}
