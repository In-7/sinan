import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/canvas/kernel/canvas_document.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';

/// 画布元素 id 的**唯一性**回归（2026-09-17）。
///
/// ## 背景：id 是进程级计数器，载入存档不推进它
/// `CanvasItem` 的 id 由 `'item-${_nextItemId++}'` 生成，而 `_nextItemId` 是
/// **顶层可变变量**（进程启动为 0）。存到 `notes.content` 里的存档带着
/// `item-0 / item-1 / …`，下次启动载入时计数器仍从 0 开始 ⇒ 新建元素会分配
/// 到**与存档里已有元素相同**的 id，而 `CanvasDocument.addItem` 是
/// `_items[item.id] = item` —— **静默覆盖**：载入的形状凭空消失。
///
/// ⚠️ 本文件里**不能有任何更早创建 CanvasItem 的用例**：计数器是进程级的，
/// 早跑一个用例就会把它推过撞号点、让本用例失去意义（`flutter test` 每个
/// 文件独立 isolate，故只在本文件内成立）。
void main() {
  ShapeItem rect(String id) => ShapeItem(
    id: id,
    rect: const Rect.fromLTWH(0, 0, 10, 10),
    kind: CanvasShapeKind.rectangle,
    color: const Color(0xFF000000),
  );

  /// 构造一份"上个进程存下来的"存档：两个元素，id 是计数器**最初**会产出的那些。
  Map<String, dynamic> archiveWith(List<String> ids) => <String, dynamic>{
    'schemaVersion': 2,
    'strokes': <String, dynamic>{},
    'items': <String, dynamic>{
      for (final String id in ids) id: rect(id).toJson(),
    },
    'strokeOrder': <String>[],
    'itemOrder': ids,
  };

  testWidgets('载入存档后新建元素：不得与存档里的 id 撞号（会静默覆盖旧元素）', (
    WidgetTester tester,
  ) async {
    final CanvasDocument doc = CanvasDocument.fromJson(
      archiveWith(<String>['item-0', 'item-1']),
    );
    expect(doc.items.length, 2, reason: '存档本身没载入成功');

    doc.addItem(
      ShapeItem(
        rect: const Rect.fromLTWH(20, 20, 10, 10),
        kind: CanvasShapeKind.rectangle,
        color: const Color(0xFFFF0000),
      ),
    );

    // ⚠️ 不能断言 `items.length == 3`：`items` 由 `_itemOrder` 派生，撞号时
    // 顺序表里会多出一条**重复 id**（长度仍是 3），而 `_items` 里那个旧元素
    // 已经被静默覆盖 —— 断言长度会**假通过**。唯一性才是正确的不变量。
    final List<String> ids = doc.items
        .map((CanvasItem i) => i.id)
        .toList();
    expect(ids.length, 3);
    expect(
      ids.toSet().length,
      3,
      reason: '新元素分到了与存档里重复的 id，把旧元素覆盖掉了',
    );
  });

  test('存档里 id 的数值被纳入考虑（新的必须排在最大者之后）', () {
    final CanvasDocument doc = CanvasDocument.fromJson(
      archiveWith(<String>['item-9999']),
    );
    doc.addItem(
      ShapeItem(
        rect: const Rect.fromLTWH(0, 0, 10, 10),
        kind: CanvasShapeKind.rectangle,
        color: const Color(0xFF000000),
      ),
    );

    final Iterable<String> ids = doc.items.map((CanvasItem i) => i.id);
    expect(ids.toSet().length, ids.length, reason: 'id 出现重复');
    expect(ids.any((String id) => id == 'item-9999'), isTrue);
  });
}
