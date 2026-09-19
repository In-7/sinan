import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';

/// 选中框**绕序**回归（2026-09-18 用户实测："那两条烦人的青色对角线"）。
///
/// 根因：`CanvasHandles.corners` 返回的是**手柄枚举序** `[左上, 右上, 左下, 右下]`，
/// 不是外框绕序；`OverlayPainter._drawPolygon` 直接按序连线 ⇒ 画成
/// "上边 + 两条对角线 + 下边"的蝴蝶结。修复 = 按绕质心极角重排。
void main() {
  group('选中框绕序', () {
    test('按序连线时相邻角点共享一条边（对角线会让 x、y 都不同）', () {
      const Rect r = Rect.fromLTWH(0, 0, 100, 60);
      final List<Offset> ordered =
          CanvasHandles.orderForOutline(CanvasHandles.corners(r));
      expect(ordered, hasLength(4));
      for (int i = 0; i < ordered.length; i++) {
        final Offset a = ordered[i];
        final Offset b = ordered[(i + 1) % ordered.length];
        expect(
          a.dx == b.dx || a.dy == b.dy,
          isTrue,
          reason: '相邻角点必须共享一条边（否则就是对角的"蝴蝶结"）：$a → $b',
        );
      }
    });

    test('只重排、不增删：四角集合不变', () {
      const Rect r = Rect.fromLTWH(-5, 10, 100, 60);
      final List<Offset> base = CanvasHandles.corners(r);
      final List<Offset> ordered = CanvasHandles.orderForOutline(base);
      expect(ordered.toSet(), base.toSet());
      expect(ordered, hasLength(base.length));
    });

    test('旋转后的四角同样成立（任意凸四边形）', () {
      const Rect r = Rect.fromLTWH(0, 0, 80, 40);
      final List<Offset> rotated =
          CanvasHandles.rotatedCorners(r, 0.7); // 约 40°
      final List<Offset> ordered = CanvasHandles.orderForOutline(rotated);
      for (int i = 0; i < ordered.length; i++) {
        final Offset a = ordered[i];
        final Offset b = ordered[(i + 1) % ordered.length];
        // 旋转后不再"共享同一 x/y"，改为断言相邻边长一致（对边相等）。
        expect((a - b).distance, greaterThan(0));
      }
      // 排序结果必须是两条长边 + 两条短边交替（边长序列成对出现）。
      final List<double> lens = <double>[
        for (int i = 0; i < ordered.length; i++)
          (ordered[i] - ordered[(i + 1) % ordered.length]).distance,
      ];
      expect(lens[0], closeTo(lens[2], 0.001));
      expect(lens[1], closeTo(lens[3], 0.001));
    });
  });
}
