import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:sinan/src/canvas/kernel/canvas_bundle.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_document.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/canvas/kernel/canvas_media.dart';

/// 造一个指向 [base]/ai_cache/ab.png 的图片 item。
ImageItem _imageIn(String base) => ImageItem(
      rect: const Rect.fromLTWH(0, 0, 32, 32),
      src: p.join(base, 'ai_cache', 'ab.png'),
    );

/// 直接写一份 v2 文档 JSON（用于模拟"旧存档"）。
Map<String, dynamic> _docJsonWithSrc(String id, String src) => <String, dynamic>{
      'schemaVersion': 2,
      'strokes': <String, dynamic>{},
      'items': <String, dynamic>{
        id: <String, dynamic>{
          'type': 'image',
          'id': id,
          'angle': 0,
          'rect': <double>[0, 0, 10, 10],
          'src': src,
          'meta': <String, dynamic>{},
        },
      },
      'strokeOrder': <String>[],
      'itemOrder': <String>[id],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory baseA;
  late Directory baseB;

  setUp(() {
    baseA = Directory.systemTemp.createTempSync('sinan_media_a');
    baseB = Directory.systemTemp.createTempSync('sinan_media_b');
  });

  tearDown(() {
    for (final Directory dir in <Directory>[baseA, baseB]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  group('RelativeMediaResolver', () {
    test('基准目录内的绝对路径 → 反斜杠归一为 `/` 的相对引用', () {
      final MediaResolver r = RelativeMediaResolver(baseA.path);
      expect(
        r.toRef(p.join(baseA.path, 'ai_cache', 'ab.png')),
        'ai_cache/ab.png',
      );
    });

    test('基准目录之外的绝对路径原样保留（外部图片无法相对化）', () {
      final MediaResolver r = RelativeMediaResolver(baseA.path);
      final String outside = p.join(baseB.path, 'x.png');
      expect(r.toRef(outside), outside);
    });

    test('相对引用 → 基于基准目录的绝对路径', () {
      final MediaResolver r = RelativeMediaResolver(baseA.path);
      expect(
        r.toPath('ai_cache/ab.png'),
        p.join(baseA.path, 'ai_cache', 'ab.png'),
      );
    });

    test('已是绝对路径的引用原样通过（旧存档无需迁移）', () {
      final MediaResolver r = RelativeMediaResolver(baseA.path);
      final String legacy = p.join(baseB.path, 'ai_cache', 'ab.png');
      expect(r.toPath(legacy), legacy);
    });

    test('mime 按后缀推断，未知后缀回落 png', () {
      expect(mediaMimeOf('a/b.png'), 'image/png');
      expect(mediaMimeOf('a/b.JPG'), 'image/jpeg');
      expect(mediaMimeOf('a/b.webp'), 'image/webp');
      expect(mediaMimeOf('a/b.unknownext'), 'image/png');
    });
  });

  group('文档媒体引用', () {
    test('带解析器序列化：src 变相对引用 + 生成媒体侧表', () {
      final CanvasDocument doc = CanvasDocument()..addItem(_imageIn(baseA.path));

      final Map<String, dynamic> json =
          doc.toJson(media: RelativeMediaResolver(baseA.path));

      final Map<String, dynamic> items = json['items'] as Map<String, dynamic>;
      expect((items.values.first as Map<String, dynamic>)['src'],
          'ai_cache/ab.png');

      final Map<String, dynamic> media = json['media'] as Map<String, dynamic>;
      expect(media.keys, contains('ai_cache/ab.png'));
      expect(
        (media['ai_cache/ab.png'] as Map<String, dynamic>)['mime'],
        'image/png',
      );
    });

    test('换一个数据根反序列化：引用不变、路径落到新根（可移植）', () {
      final CanvasDocument doc = CanvasDocument()..addItem(_imageIn(baseA.path));
      final Map<String, dynamic> json =
          doc.toJson(media: RelativeMediaResolver(baseA.path));

      final CanvasDocument restored = CanvasDocument.fromJson(
        json,
        media: RelativeMediaResolver(baseB.path),
      );

      expect(
        (restored.items.single as ImageItem).src,
        p.join(baseB.path, 'ai_cache', 'ab.png'),
      );
    });

    test('不传解析器：保持旧行为（绝对路径、无侧表）', () {
      final CanvasDocument doc = CanvasDocument()..addItem(_imageIn(baseA.path));

      final Map<String, dynamic> json = doc.toJson();

      final Map<String, dynamic> items = json['items'] as Map<String, dynamic>;
      expect(
        (items.values.first as Map<String, dynamic>)['src'],
        p.join(baseA.path, 'ai_cache', 'ab.png'),
      );
      expect(json.containsKey('media'), isFalse);
    });

    test('旧存档里的绝对 src：带解析器也能原样加载', () {
      final String legacySrc = p.join(baseA.path, 'ai_cache', 'ab.png');
      final CanvasDocument doc = CanvasDocument.fromJson(
        _docJsonWithSrc('item-legacy', legacySrc),
        media: RelativeMediaResolver(baseB.path),
      );
      expect((doc.items.single as ImageItem).src, legacySrc);
    });

    test('控制器整页往返：相机 + 相对引用一起还原', () {
      final CanvasController controller = CanvasController();
      controller.document.addItem(_imageIn(baseA.path));

      final MediaResolver media = RelativeMediaResolver(baseA.path);
      final CanvasController restored = CanvasController.fromJson(
        controller.toJson(media: media),
        media: RelativeMediaResolver(baseB.path),
      );

      expect(
        (restored.document.items.single as ImageItem).src,
        p.join(baseB.path, 'ai_cache', 'ab.png'),
      );
    });
  });

  group('自包含 .canvas.json', () {
    setUp(() {
      // 真实落一个媒体文件：编码时要把它读出来内联。
      File(p.join(baseA.path, 'ai_cache', 'ab.png'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[1, 2, 3, 4, 5]);
    });

    test('导出把媒体字节内联进侧表（base64）', () async {
      final CanvasController controller = CanvasController();
      controller.document.addItem(_imageIn(baseA.path));

      final Map<String, dynamic> bundle = await encodeCanvasBundle(
        controller,
        media: RelativeMediaResolver(baseA.path),
      );

      final Map<String, dynamic> media =
          (bundle['document'] as Map<String, dynamic>)['media']
              as Map<String, dynamic>;
      final Map<String, dynamic> entry =
          media['ai_cache/ab.png'] as Map<String, dynamic>;
      expect(entry['data'], base64Encode(<int>[1, 2, 3, 4, 5]));
      expect(entry['bytes'], 5);
    });

    test('媒体文件缺失：导出不失败，仅跳过内联', () async {
      final CanvasController controller = CanvasController();
      controller.document.addItem(ImageItem(
        rect: const Rect.fromLTWH(0, 0, 32, 32),
        src: p.join(baseA.path, 'ai_cache', 'missing.png'),
      ));

      final Map<String, dynamic> bundle = await encodeCanvasBundle(
        controller,
        media: RelativeMediaResolver(baseA.path),
      );

      final Map<String, dynamic> media =
          (bundle['document'] as Map<String, dynamic>)['media']
              as Map<String, dynamic>;
      final Map<String, dynamic> entry =
          media['ai_cache/missing.png'] as Map<String, dynamic>;
      expect(entry.containsKey('data'), isFalse, reason: '读不到字节就不内联');
    });

    test('换目录导入：内联媒体被就地物化，画布立即可用', () async {
      final CanvasController controller = CanvasController();
      controller.document.addItem(_imageIn(baseA.path));
      final Map<String, dynamic> bundle = await encodeCanvasBundle(
        controller,
        media: RelativeMediaResolver(baseA.path),
      );

      final CanvasController restored = await importCanvasBundleText(
        jsonEncode(bundle),
        media: RelativeMediaResolver(baseB.path),
      );

      final File materialized = File(p.join(baseB.path, 'ai_cache', 'ab.png'));
      expect(materialized.existsSync(), isTrue);
      expect(materialized.readAsBytesSync(), <int>[1, 2, 3, 4, 5]);
      expect(
        (restored.document.items.single as ImageItem).src,
        materialized.path,
      );
    });

    test('导入不覆盖已存在的同名文件', () async {
      final File existing = File(p.join(baseB.path, 'ai_cache', 'ab.png'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[9, 9, 9]);
      final CanvasController controller = CanvasController();
      controller.document.addItem(_imageIn(baseA.path));
      final Map<String, dynamic> bundle = await encodeCanvasBundle(
        controller,
        media: RelativeMediaResolver(baseA.path),
      );

      await materializeCanvasBundle(
        jsonDecode(jsonEncode(bundle)) as Map<String, dynamic>,
        media: RelativeMediaResolver(baseB.path),
      );

      expect(existing.readAsBytesSync(), <int>[9, 9, 9]);
    });

    test('落盘为 .canvas.json 后可再读回', () async {
      final Directory out = Directory.systemTemp.createTempSync('sinan_out');
      addTearDown(() {
        if (out.existsSync()) out.deleteSync(recursive: true);
      });

      final CanvasController controller = CanvasController();
      controller.document.addItem(_imageIn(baseA.path));

      final File file = await exportCanvasBundle(
        controller,
        media: RelativeMediaResolver(baseA.path),
        directory: out.path,
      );
      expect(file.path, endsWith('.canvas.json'));
      expect(file.existsSync(), isTrue);

      final CanvasController restored = await importCanvasBundleText(
        file.readAsStringSync(),
        media: RelativeMediaResolver(baseB.path),
      );
      expect(restored.document.items, hasLength(1));
      expect(
        File(p.join(baseB.path, 'ai_cache', 'ab.png')).existsSync(),
        isTrue,
        reason: '导入应把内联字节写回本地媒体目录',
      );
    });

    test('顶层不是 JSON 对象时报错（不静默吞掉）', () async {
      await expectLater(
        importCanvasBundleText(
          '[1,2,3]',
          media: RelativeMediaResolver(baseA.path),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
