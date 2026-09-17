import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_document.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/canvas/kernel/ink_stroke.dart';

ShapeItem _shape() => ShapeItem(
      rect: const Rect.fromLTWH(0, 0, 20, 20),
      kind: CanvasShapeKind.rectangle,
      color: kThemeInk,
    );

/// 形状样式的撤销命令（`setItemStyles`）与控制器入口（`updateSelectedShapeStyle`）。
///
/// 范式与 `setItemTransforms` 一致：**就地改 + 快照命令**。钉两件事：
/// ① 一次面板操作 = 一条命令（undo 能回到改之前）；
/// ② **值没变不记命令**——滑杆拖动会连发很多次，值相同的那些不该各占一条历史
///   （否则拖一次就把撤销栈刷满，用户再也撤不回真正的编辑）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('setItemStyles：快照命令', () {
    test('改样式 → undo 回到旧样式 → redo 再前进', () {
      final CanvasDocument document = CanvasDocument();
      final ShapeItem shape = _shape();
      document.addItem(shape);

      final ShapeStyle before = shape.style;
      shape.applyStyle(
        const ShapeStyle(
          color: Color(0xFFE5484D),
          strokeWidth: 6,
          filled: true,
        ),
      );
      document.setItemStyles(<(ShapeItem, ShapeStyle)>[(shape, before)]);

      document.undo();
      expect(shape.color, kThemeInk);
      expect(shape.strokeWidth, 2);
      expect(shape.filled, isFalse);

      document.redo();
      expect(shape.color, const Color(0xFFE5484D));
      expect(shape.strokeWidth, 6);
      expect(shape.filled, isTrue);
    });

    test('值没真变就不记命令（撤销一次就该退到"加这个形状之前"）', () {
      final CanvasDocument document = CanvasDocument();
      final ShapeItem shape = _shape();
      document.addItem(shape);

      // 面板会以相同值反复提交（滑杆 onChanged 连发）——这里模拟一次"没变"。
      final ShapeStyle before = shape.style;
      document.setItemStyles(<(ShapeItem, ShapeStyle)>[(shape, before)]);

      document.undo();
      expect(
        document.items,
        isEmpty,
        reason: '空提交占了历史：撤销一次没能退到加形状之前（撤销栈被刷满的元凶）',
      );
    });
  });

  group('控制器入口：只作用于所选形状', () {
    test('改所选形状的样式（未传的项不动）', () {
      final CanvasController controller = CanvasController();
      final ShapeItem shape = _shape();
      controller.document.addItem(shape);
      controller.selectItems(<CanvasItem>[shape]);

      controller.updateSelectedShapeStyle(color: const Color(0xFF3E63DD));
      expect(shape.color, const Color(0xFF3E63DD));
      expect(shape.strokeWidth, 2, reason: '只改颜色不该顺带把粗细重置');

      controller.updateSelectedShapeStyle(strokeWidth: 9);
      expect(shape.strokeWidth, 9);
      expect(shape.color, const Color(0xFF3E63DD), reason: '只改粗细不该顺带把颜色重置');

      // 越界值被夹住（面板滑杆范围 1~24）。
      controller.updateSelectedShapeStyle(strokeWidth: 999);
      expect(shape.strokeWidth, 24);

      controller.dispose();
    });

    test('选中的是图片 / 没有选中时：不抛、不记命令', () {
      final CanvasController controller = CanvasController();
      final ImageItem image = ImageItem(rect: const Rect.fromLTWH(0, 0, 20, 20));
      controller.document.addItem(image);
      controller.selectItems(<CanvasItem>[image]);

      controller.updateSelectedShapeStyle(color: const Color(0xFF30A46C));
      expect(image.rect, const Rect.fromLTWH(0, 0, 20, 20)); // 图片没有样式可改

      // 只应有 `addItem` 那一条命令：再 undo 一次就空。
      controller.document.undo();
      expect(controller.document.items, isEmpty);
      controller.dispose();
    });
  });
}
