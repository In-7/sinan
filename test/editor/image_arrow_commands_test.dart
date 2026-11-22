import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/editor/keys/image_arrow_commands.dart';

/// 键盘 ↓/↑ 到图片块的两阶段判据（2026-11-22）：
/// "部分露出 = 未看全"必须返回 false 才会放行给 Flutter 原生 ScrollAction，
/// 否则光标卡在图片上、大图永远看不全。
void main() {
  const Rect viewport = Rect.fromLTRB(0, 100, 800, 700);

  group('rectFullyVisible：几何分界', () {
    test('整块在视口内 ⇒ true', () {
      expect(
        rectFullyVisible(viewport, const Rect.fromLTRB(0, 150, 800, 500)),
        isTrue,
      );
    });

    test('图片比视口高（上下溢出）⇒ false（要继续滚）', () {
      expect(
        rectFullyVisible(viewport, const Rect.fromLTRB(0, 50, 800, 900)),
        isFalse,
        reason: '这正是用户实报的场景：光标到图片但看不全',
      );
    });

    test('只露出上半 ⇒ false', () {
      expect(
        rectFullyVisible(viewport, const Rect.fromLTRB(0, 600, 800, 1000)),
        isFalse,
      );
    });

    test('底部越界 1px 内（容差）⇒ true，避免浮点抖动反复滚', () {
      expect(
        rectFullyVisible(viewport, const Rect.fromLTRB(0, 100, 800, 701)),
        isTrue,
      );
    });

    test('未布局（empty rect）⇒ false', () {
      expect(rectFullyVisible(viewport, Rect.zero), isFalse);
    });
  });
}
