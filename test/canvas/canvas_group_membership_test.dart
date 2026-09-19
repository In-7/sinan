import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sinan/src/canvas/kernel/canvas_document.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/canvas/kernel/ink_stroke.dart' show kThemeInk;

/// 分组**成员关系**的回归（A6，2026-09-19）。
///
/// ## 背景：分组框此前只有存档能造
/// `CanvasItem.groupId` 曾是 `final` —— 只有构造器与 `fromJson` 能写它，
/// "把元素加进分组框"在**运行时**做不到。于是 `CanvasGroupItem` 是个**半成品**：
/// 能序列化、能画，但没人能创建成员关系（AI 的 `group` 动作因此在阶段 A 被摘掉）。
///
/// 现在 `setItemGroupIds` 补上了这条路，本文件钉住三件事：
/// ① 归属改动**可撤销**（一次操作一条命令，照 `colorSlot` 的范式）；
/// ② 删掉分组框时成员**自动解绑** —— 否则会留下指向不存在分组的悬空 `groupId`；
/// ③ 解绑与删框是**同一条**命令（撤销后"框回来、成员也重新属于它"）。
void main() {
  ShapeItem shape(double x) => ShapeItem(
    rect: Rect.fromLTWH(x, 0, 40, 40),
    kind: CanvasShapeKind.rectangle,
    color: kThemeInk,
  );

  test('setItemGroupIds：一次调用 = 一条命令，撤销/重做都还原归属', () {
    final CanvasDocument doc = CanvasDocument();
    final ShapeItem a = shape(0);
    final ShapeItem b = shape(60);
    doc.addItem(a);
    doc.addItem(b);

    // 调用方**先就地改**，再把旧值交进来（与 `setItemColorSlots` 同范式）。
    final List<(CanvasItem, String?)> changes = <(CanvasItem, String?)>[
      (a, a.groupId),
      (b, b.groupId),
    ];
    a.groupId = 'grp-1';
    b.groupId = 'grp-1';
    doc.setItemGroupIds(changes);

    expect(a.groupId, 'grp-1');
    expect(b.groupId, 'grp-1');

    doc.undo();
    expect(a.groupId, isNull, reason: '一次撤销要把整批归属改动还原');
    expect(b.groupId, isNull);

    doc.redo();
    expect(a.groupId, 'grp-1');
    expect(b.groupId, 'grp-1');
  });

  test('值没真变的项被过滤（重复调用不刷历史）', () {
    final CanvasDocument doc = CanvasDocument();
    final ShapeItem a = shape(0);
    doc.addItem(a);

    doc.setItemGroupIds(<(CanvasItem, String?)>[(a, null)]); // a.groupId 本来就是 null
    // 直接再调一次：仍不该产生新命令 —— 只有 addItem 那一条，撤销后 items 为空。
    doc.undo();
    expect(doc.items, isEmpty, reason: '空改动不该占一条历史');
  });

  test('删掉分组框 ⇒ 成员**自动解绑**（不留悬空 groupId）', () {
    final CanvasDocument doc = CanvasDocument();
    final ShapeItem a = shape(0);
    final CanvasGroupItem group = CanvasGroupItem(
      rect: const Rect.fromLTWH(-10, -10, 120, 60),
      label: '一组',
    );
    doc.addItem(a);
    doc.addItem(group);
    // 直接写字段：模拟"从存档载入时就带着 groupId"的既有状态。
    a.groupId = group.id;

    doc.removeItems(<CanvasItem>[group]);

    expect(
      a.groupId,
      isNull,
      reason: '框没了，成员不能还认为自己属于它——那会是一条指向不存在分组的悬空引用',
    );
    expect(doc.items, hasLength(1));
  });

  test('撤销「删框」时成员**重新绑回**同一个框（同一条命令）', () {
    final CanvasDocument doc = CanvasDocument();
    final ShapeItem a = shape(0);
    final CanvasGroupItem group = CanvasGroupItem(
      rect: const Rect.fromLTWH(-10, -10, 80, 60),
    );
    doc.addItem(a);
    doc.addItem(group);
    // 把归属直接写进 items（模拟"从存档载入时就带着 groupId"的状态）。
    a.groupId = group.id;

    doc.removeItems(<CanvasItem>[group]);
    expect(a.groupId, isNull);
    expect(doc.items, hasLength(1));

    doc.undo();
    expect(doc.items, hasLength(2), reason: '框回来了');
    expect(
      a.groupId,
      group.id,
      reason: '成员也要重新绑回 —— 否则用户按一次撤销得到的是"框在、归属没了"的怪状态',
    );
  });
}
