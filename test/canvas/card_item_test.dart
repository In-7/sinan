import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/data/canvas_store.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sqlite3/sqlite3.dart';

/// 卡片（v9）的回归：内核 `CardItem` + 它与**存储契约**的对齐。
///
/// 最值得钉的是最后一组：卡片是**分裂存储**（内容在 blocks、几何在 canvas_items），
/// 而内核 `toJson` 是存档格式的权威。两边一旦漂移，表现不是报错，而是
/// "校验失败 ⇒ 静默回退 JSON ⇒ 卡片改动不生效"——很难查。
void main() {
  CardItem card({
    String text = '一个想法',
    double angle = 0,
  }) => CardItem(
    id: 'card-1',
    rect: const Rect.fromLTRB(0, 0, 120, 60),
    blockId: 'b1',
    text: text,
    angle: angle,
  );

  group('CardItem 序列化', () {
    test('toJson 字段与存储契约逐项一致', () {
      final Map<String, dynamic> j = card().toJson();
      expect(j['type'], 'card');
      expect(j['id'], 'card-1');
      expect(j['blockId'], 'b1');
      expect(j['text'], '一个想法');
      expect(j['rect'], <double>[0.0, 0.0, 120.0, 60.0]);
      expect(j['meta'], isEmpty);
    });

    test('fromJson 往返：几何 / blockId / 文本都不丢', () {
      final CardItem item = CardItem.fromJson(card().toJson());
      expect(item.id, 'card-1');
      expect(item.blockId, 'b1');
      expect(item.text, '一个想法');
      expect(item.rect, const Rect.fromLTRB(0, 0, 120, 60));
    });

    test('CanvasItem.fromJson 按 type 分发到 CardItem', () {
      expect(CanvasItem.fromJson(card().toJson()), isA<CardItem>());
    });

    test('旧存档缺 blockId：兜底成 item id（内容仍能落 blocks）', () {
      final Map<String, dynamic> j = card().toJson()..remove('blockId');
      expect(
        CardItem.fromJson(j).blockId,
        'card-1',
        reason: '为空会被存储层跳过 ⇒ 卡片变成没有内容的空框',
      );
    });
  });

  group('CardItem 交互', () {
    test('hitTest：卡片是实心的，盒内即命中', () {
      final CardItem item = card();
      expect(item.hitTest(const Offset(60, 30), 2), isTrue); // 中心
      expect(item.hitTest(const Offset(2, 2), 2), isTrue); // 近左上角
      expect(item.hitTest(const Offset(200, 30), 2), isFalse); // 盒外
    });

    test('paint 不抛（覆盖空文本 / 旋转 / 长文本溢出）', () {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final ui.Canvas canvas = ui.Canvas(recorder);

      for (final CardItem item in <CardItem>[
        card(),
        card(angle: 0.5),
        card(text: ''), // 空文本：不该走排版
        card(text: '很长的一段文字' * 50), // 溢出：被裁到文本区，不该画到卡片外
      ]) {
        expect(
          () => item.paint(canvas, ink: const Color(0xFF1F1F1F)),
          returnsNormally,
        );
      }

      // ⚠️ endRecording 必须在**绘制之后**：它结束录制，之后这个 canvas 就画不动了。
      // 放在前面的话，用例会变成空转 —— 什么都不画也一样"不抛"。
      final ui.Picture picture = recorder.endRecording();
      addTearDown(picture.dispose);
    });

    test('dispose 可重复调用（释放排版缓存）', () {
      final CardItem item = card();
      item.dispose();
      expect(item.dispose, returnsNormally);
    });
  });

  group('内核 ↔ 存储：契约必须对齐', () {
    test('CardItem.toJson 能穿过 CanvasStore 并校验通过', () {
      final Database db = sqlite3.openInMemory();
      addTearDown(db.close);
      AppDatabase.migrateForTesting(db);
      db.execute('PRAGMA foreign_keys = ON;');
      db.execute(
        'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
        "created_at, revised_at) VALUES ('n1','canvas','','','fp1:0:0','',1,1)",
      );
      final CanvasStore store = CanvasStore(db);

      // ⚠️ 用**内核的 toJson** 造存档，而不是手写一份"看起来对"的夹具：
      // 于是两边（内核格式 ↔ 存储投影）任何一处漂移都会在这里红，
      // 而不是等到用户发现"卡片改了却没保存"。
      final String content = jsonEncode(<String, dynamic>{
        'camera': <String, dynamic>{
          'scale': 1.0,
          'translation': <double>[0.0, 0.0],
          'minScale': 0.05,
          'maxScale': 4.0,
        },
        'document': <String, dynamic>{
          'schemaVersion': 2,
          'strokes': <String, dynamic>{},
          'items': <String, dynamic>{'card-1': card().toJson()},
          'strokeOrder': <String>[],
          'itemOrder': <String>['card-1'],
        },
      });

      expect(store.replaceCanvasRows('n1', content), greaterThan(0));
      expect(
        store.verifyCanvasRows('n1', content),
        isTrue,
        reason: '内核 toJson 与存储契约不一致 ⇒ 卡片会静默回退 JSON',
      );
      // 内容确实进了 blocks —— 这是"能被搜索 / 引用 / AI 索引"的前提。
      expect(
        db.select("SELECT COUNT(*) AS c FROM blocks WHERE id='b1'").single['c'],
        1,
      );
    });
  });
}
