import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/canvas/kernel/canvas_mindmap.dart';
import 'package:sinan/src/canvas/kernel/canvas_palette.dart';
import 'package:sinan/src/canvas/kernel/ink_stroke.dart';

/// 语义色槽位（对照笔记清单 #2，对标 JSON Canvas 的预设色）回归。
///
/// 三个要点：
/// ① **单一来源**：槽位 → 颜色必须与 [canvasPalette] 逐项一致（不许各写一份）；
/// ② **老存档兼容**：空槽位**不写** `colorSlot` 键（否则深比较失配 ⇒ 静默回退）；
/// ③ **可撤销**：一次设置 = 一条命令（undo 回到"无槽位"）。
void main() {
  group('调色板与槽位', () {
    test('槽位数 = 调色板长度 − 1（首项是哨兵）', () {
      expect(canvasPalette.length, CanvasColorSlot.values.length + 1);
      expect(canvasPalette.first, kThemeInk);
    });

    test('槽位 → 颜色与调色板逐项一致（单一来源）', () {
      for (final CanvasColorSlot slot in CanvasColorSlot.values) {
        expect(canvasSlotColor(slot), canvasPalette[slot.index + 1]);
      }
    });

    test('槽位名解析：合法名往返、脏输入不抛', () {
      expect(canvasColorSlotOf('red'), CanvasColorSlot.red);
      expect(canvasColorSlotOf('purple'), CanvasColorSlot.purple);
      expect(canvasColorSlotOf('不存在的色'), isNull);
      expect(canvasColorSlotOf(null), isNull);
      expect(canvasColorSlotOf(42), isNull);
    });
  });

  group('卡片槽位（序列化契约）', () {
    test('空槽位不写键（老存档兼容）；有槽位才写且往返保留', () {
      final CardItem plain = CardItem(
        rect: const Rect.fromLTWH(0, 0, 100, 60),
        blockId: 'b1',
      );
      expect(plain.toJson().containsKey('colorSlot'), isFalse);

      final CardItem marked = CardItem(
        rect: const Rect.fromLTWH(0, 0, 100, 60),
        blockId: 'b1',
        colorSlot: CanvasColorSlot.green,
      );
      final Map<String, dynamic> j = marked.toJson();
      expect(j['colorSlot'], 'green');

      final CanvasItem back = CanvasItem.fromJson(j);
      expect((back as CardItem).colorSlot, CanvasColorSlot.green);
    });

    test('脏槽位名 ⇒ null（不抛，脏存档不该打不开画布）', () {
      final CanvasItem back = CanvasItem.fromJson(<String, dynamic>{
        'type': 'card',
        'id': 'c1',
        'blockId': 'b1',
        'text': '',
        'angle': 0.0,
        'rect': <double>[0, 0, 10, 10],
        'colorSlot': '不存在',
        'meta': <String, Object?>{},
      });
      expect((back as CardItem).colorSlot, isNull);
    });
  });

  group('思维导图槽位', () {
    test('往返保留槽位', () {
      final MindMapItem item = newMindMapItem(
        rect: const Rect.fromLTWH(0, 0, 300, 200),
      );
      item.colorSlot = CanvasColorSlot.purple;

      final CanvasItem back = CanvasItem.fromJson(item.toJson());
      expect((back as MindMapItem).colorSlot, CanvasColorSlot.purple);
    });
  });

  group('统一读写口（基类）', () {
    test('形状不支持槽位：恒为 null、赋值是空操作、不写键', () {
      final ShapeItem shape = ShapeItem(
        rect: const Rect.fromLTWH(0, 0, 10, 10),
        kind: CanvasShapeKind.rectangle,
        color: kThemeInk,
      );
      shape.colorSlot = CanvasColorSlot.red;
      expect(shape.colorSlot, isNull);
      expect(shape.toJson().containsKey('colorSlot'), isFalse);
    });
  });

  group('撤销（CanvasController）', () {
    test('设置槽位 = 一条命令；undo 回无槽位、redo 再标上', () {
      final CanvasController controller = CanvasController();
      final CardItem card = CardItem(
        rect: const Rect.fromLTWH(0, 0, 100, 60),
        blockId: 'b1',
      );
      controller.document.addItem(card);
      controller.selectItems(<CanvasItem>[card]);

      controller.setSelectedColorSlot(CanvasColorSlot.red);
      expect(card.colorSlot, CanvasColorSlot.red);

      controller.undo();
      expect(card.colorSlot, isNull, reason: 'undo 应回到"无槽位"');

      controller.redo();
      expect(card.colorSlot, CanvasColorSlot.red);

      controller.dispose();
    });

    test('同值不刷栈（连点同色板不该堆命令）', () {
      final CanvasController controller = CanvasController();
      final CardItem card = CardItem(
        rect: const Rect.fromLTWH(0, 0, 100, 60),
        blockId: 'b1',
      );
      controller.document.addItem(card);
      controller.selectItems(<CanvasItem>[card]);

      controller.setSelectedColorSlot(CanvasColorSlot.blue);
      final int after = controller.document.revision;
      controller.setSelectedColorSlot(CanvasColorSlot.blue);
      expect(controller.document.revision, after);

      controller.dispose();
    });
  });
}
