import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/canvas/kernel/canvas_document.dart';
import 'package:sinan/src/canvas/kernel/canvas_migration.dart';

/// 画布 schema **迁移链**回归（2026-09-18，对照笔记清单 #1）。
///
/// 要钉的三件事：
/// ① v1（双 List、无版本键）能升到 v2（id-keyed map + 显式 order）；
/// ② 迁移**幂等**（重复载入不会反复改结构）；
/// ③ 存档版本**比内核新**时**抛异常**——绝不静默按旧规则解析（那会丢新字段）。
void main() {
  /// 一份 v1 存档的 `document` 节点：`strokes`/`items` 是**数组**，且**无版本键**。
  Map<String, dynamic> v1Doc() => <String, dynamic>{
    'strokes': <Object?>[
      <String, dynamic>{
        'id': 's1',
        'version': 1,
        'color': 0xFF000000,
        'baseWidth': 4.0,
        'simulatePressure': true,
        'points': <List<double>>[
          <double>[0.0, 0.0, 0.5],
          <double>[1.0, 1.0, 0.5],
        ],
      },
    ],
    'items': <Object?>[
      <String, dynamic>{
        'type': 'shape',
        'id': 'i1',
        'kind': 'rectangle',
        'color': 0xFF1F1F1F,
        'strokeWidth': 2.0,
        'filled': false,
        'angle': 0.0,
        'rect': <double>[0.0, 0.0, 10.0, 20.0],
        'meta': <String, Object?>{},
      },
    ],
  };

  group('迁移链', () {
    test('v1（双 List、无版本键）⇒ v2（id-keyed map + 显式 order）', () {
      final Map<String, dynamic> out = CanvasMigrations.migrate(v1Doc());
      expect(out['schemaVersion'], kCanvasSchemaVersion);
      expect(out['strokes'], isA<Map<String, dynamic>>());
      expect(out['items'], isA<Map<String, dynamic>>());
      expect(out['strokeOrder'], <String>['s1']);
      expect(out['itemOrder'], <String>['i1']);
      // 内容不能丢：map 里就是原来那条。
      expect((out['items'] as Map<String, dynamic>)['i1'], isNotNull);
    });

    test('幂等：对已迁移的结果再迁移，结构不变', () {
      final Map<String, dynamic> once = CanvasMigrations.migrate(v1Doc());
      final Map<String, dynamic> twice = CanvasMigrations.migrate(once);
      expect(twice['schemaVersion'], kCanvasSchemaVersion);
      expect(twice['strokeOrder'], once['strokeOrder']);
      expect(twice['itemOrder'], once['itemOrder']);
      expect(twice['strokes'], once['strokes']);
      expect(twice['items'], once['items']);
    });

    test('畸形条目（没有 id）被跳过，而不是造出空键顶掉别人', () {
      final Map<String, dynamic> doc = v1Doc();
      (doc['items']! as List<Object?>).insert(0, <String, dynamic>{'type': 'shape'});
      final Map<String, dynamic> out = CanvasMigrations.migrate(doc);
      expect((out['items']! as Map<String, dynamic>).keys, <String>['i1']);
      expect(out['itemOrder'], <String>['i1']);
    });

    test('未来版本 ⇒ 抛 CanvasSchemaTooNewException（不静默丢字段）', () {
      final Map<String, dynamic> future = <String, dynamic>{
        'schemaVersion': kCanvasSchemaVersion + 5,
        'strokes': <String, dynamic>{},
        'items': <String, dynamic>{},
        'somethingNew': '这是新版才有的字段，不能被旧版悄悄吃掉',
      };
      expect(
        () => CanvasMigrations.migrate(future),
        throwsA(isA<CanvasSchemaTooNewException>()),
      );
    });
  });

  group('CanvasDocument.fromJson 端到端吃旧存档', () {
    test('v1 存档能载入：笔迹与图形都在，顺序正确', () {
      final CanvasDocument doc = CanvasDocument.fromJson(v1Doc());
      expect(doc.items, hasLength(1));
      expect(doc.items.single.id, 'i1');
    });

    test('toJson 输出当前版本号；往返后内容稳定', () {
      final CanvasDocument doc = CanvasDocument.fromJson(v1Doc());
      final Map<String, dynamic> j = doc.toJson();
      expect(j['schemaVersion'], kCanvasSchemaVersion);

      final CanvasDocument back = CanvasDocument.fromJson(j);
      expect(back.items.single.id, 'i1');
      expect(back.toJson()['itemOrder'], j['itemOrder']);
    });

    test('未来版本的画布 ⇒ fromJson 抛出（宿主据此冻结保存，不覆盖数据）', () {
      final Map<String, dynamic> future = <String, dynamic>{
        'schemaVersion': kCanvasSchemaVersion + 1,
        'strokes': <String, dynamic>{},
        'items': <String, dynamic>{},
      };
      expect(
        () => CanvasDocument.fromJson(future),
        throwsA(isA<CanvasSchemaTooNewException>()),
      );
    });
  });
}
