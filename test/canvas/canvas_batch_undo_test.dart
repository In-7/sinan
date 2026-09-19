import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sinan/src/canvas/kernel/canvas_document.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';

/// `CanvasDocument.batch` 的回归（A 阶段硬前置，2026-09-19）。
///
/// ## 为什么需要批量命令
/// 一次 AI 指令会同时改很多元素。按单条入栈的话用户要按 N 次 Ctrl+Z 才回到原点
/// —— 那等于"AI 的改动不可撤销"。所以一批改动必须合成**一条**命令。
///
/// 本文件钉住四件容易写坏的事：
/// 1. 一次 undo 回滚整批、一次 redo 重放整批，且**顺序严格互逆**；
/// 2. 批中途**不入栈**（`canUndo` 保持原样），清重做栈/暂存回收都推迟到收尾；
/// 3. `retainedIds` 取并集 —— 少了它，批里删掉的元素撤销后回不来；
/// 4. `body` 抛异常时已生效的改动**仍然**可撤销。
void main() {
  ShapeItem shape(double x) => ShapeItem(
    rect: Rect.fromLTWH(x, 0, 20, 20),
    kind: CanvasShapeKind.rectangle,
    color: const Color(0xFF000000),
  );

  test('一次 undo 回滚整批，一次 redo 重放整批', () {
    final CanvasDocument doc = CanvasDocument();
    final ShapeItem a = shape(0);
    final ShapeItem b = shape(40);

    doc.batch(() {
      doc.addItem(a);
      doc.addItem(b);
    });

    expect(doc.items.length, 2);
    expect(doc.canUndo, isTrue);

    doc.undo();
    expect(doc.items, isEmpty, reason: '一条命令应回滚批内全部改动');

    doc.redo();
    expect(doc.items.length, 2);
  });

  test('批中途**不入栈**（所以 canUndo 在此期间不变）', () {
    final CanvasDocument doc = CanvasDocument();

    doc.batch(() {
      doc.addItem(shape(0));
      expect(doc.canUndo, isFalse, reason: '批中途只记账，不进撤销栈');
    });

    expect(doc.canUndo, isTrue, reason: '收尾时才合成一条入栈');
  });

  test('空批不产生命令', () {
    final CanvasDocument doc = CanvasDocument();
    doc.batch(() {});
    expect(doc.canUndo, isFalse);
  });

  test('嵌套 batch 只产生**一条**命令', () {
    final CanvasDocument doc = CanvasDocument();

    doc.batch(() {
      doc.addItem(shape(0));
      doc.batch(() {
        doc.addItem(shape(40));
      });
    });

    expect(doc.items.length, 2);
    doc.undo();
    expect(doc.items, isEmpty);
    expect(doc.canUndo, isFalse, reason: '内层不该另起一条命令');
  });

  test('批内删除的元素撤销后**拿得回原件**（retainedIds 并集）', () {
    final CanvasDocument doc = CanvasDocument();
    final ShapeItem victim = shape(0);
    doc.addItem(victim);

    doc.batch(() {
      doc.removeItems(<CanvasItem>[victim]);
      doc.addItem(shape(40));
    });
    expect(doc.items.length, 1);

    doc.undo();

    // ⚠️ 这条是 `_BatchCommands.retainedIds` 的闸门：不取并集的话，收尾回收会把
    // victim 当垃圾丢掉，撤销后 items 为空（元素永久消失）。
    expect(doc.items.length, 1);
    expect(doc.items.single, same(victim), reason: '拿回的必须是**同一个**对象');
  });

  test('重做栈在**收尾**时清空（批中途不是清空的时机）', () {
    final CanvasDocument doc = CanvasDocument();
    doc.addItem(shape(0));
    doc.undo();
    expect(doc.canRedo, isTrue);

    doc.batch(() {
      doc.addItem(shape(40));
    });

    expect(doc.canRedo, isFalse, reason: '新操作作废重做栈（标准语义）');
  });

  test('body 抛异常时，已生效的改动**仍然**可撤销', () {
    final CanvasDocument doc = CanvasDocument();

    expect(
      () => doc.batch(() {
        doc.addItem(shape(0));
        throw StateError('模型给了坏动作');
      }),
      throwsStateError,
    );

    expect(doc.items.length, 1, reason: '改动已经生效，不能假装没发生');
    doc.undo();
    expect(doc.items, isEmpty, reason: '绝不能留下"改了但撤不了"的状态');
  });
}
