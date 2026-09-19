import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';

/// 块可迁移（#5）的控制器侧：选中卡片 → 「发回文档」把卡片从画布摘除，
/// 返回它的 blockId 交给上层落进文档块树（见 `NoteStore.moveBlockToDocument`）。
void main() {
  group('CanvasController 块可迁移（#5）', () {
    test('detachSelectedCard：摘除单张选中卡片并返回 blockId，清空选区', () {
      final CanvasController controller = CanvasController();
      final CardItem card = CardItem(
        rect: const Rect.fromLTRB(0, 0, 40, 40),
        blockId: 'b1',
      );
      controller.document.addItem(card);
      controller.selectItems(<CanvasItem>[card]);

      expect(controller.selectedCard, card);

      final String? blockId = controller.detachSelectedCard();
      expect(blockId, 'b1');
      // 卡片从内存文档移除。
      expect(controller.document.items, isEmpty);
      // 选区清空（按钮随后隐藏）。
      expect(controller.selectedCard, isNull);
      expect(controller.selectedItems, isEmpty);
    });

    test('detachSelectedCard：非卡片选中 / 空选区 ⇒ 返回 null、不动状态', () {
      final CanvasController controller = CanvasController();
      final ShapeItem shape = ShapeItem(
        rect: const Rect.fromLTRB(0, 0, 40, 40),
        kind: CanvasShapeKind.rectangle,
        color: const Color(0xFF000000),
      );
      controller.document.addItem(shape);
      controller.selectItems(<CanvasItem>[shape]);

      // 选中的不是卡片 ⇒ selectedCard 为 null，按钮不会出现。
      expect(controller.selectedCard, isNull);
      expect(controller.detachSelectedCard(), isNull);
      // 形状原封不动。
      expect(controller.document.items, hasLength(1));
    });
  });
}
