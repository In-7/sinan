import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/editor/core/image_metrics.dart';

/// **图片宽高比解析**（`blocks/image_metrics.dart`）。
///
/// 它存在的理由：滚动器要在图片块**被构建之前**就知道图片多高（官方只给一个
/// 固定的"加载中"高度，解码完再撑开 ⇒ 总高变一次）。所以这里量的是
/// "只读标头能不能拿到原始宽高"以及三条来源路径的行为。
void main() {
  /// 现场生成一张 **2×1** 的 PNG（避免手写图片字节与写错的 CRC）。
  Future<Uint8List> makePng(int width, int height) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = const Color(0xFF336699),
    );
    final ui.Image image = await recorder.endRecording().toImage(
      width,
      height,
    );
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    image.dispose();
    return data!.buffer.asUint8List();
  }

  testWidgets('本地文件 / data URL 都能解析；缺文件不重试', (WidgetTester tester) async {
    final ImageAspectRatios ratios = ImageAspectRatios();
    final Map<String, double?> resolved = <String, double?>{};
    final Set<String> callbacks = <String>{};

    // 真实异步（文件 IO + 引擎解码）必须跑在 runAsync 里。
    await tester.runAsync(() async {
      final Uint8List png = await makePng(4, 3); // 高/宽 = 0.75
      final File file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}sinan_ratio_test.png',
      );
      await file.writeAsBytes(png);
      addTearDown(() async {
        // 同步 exists：清理路径上不必为它多排一次事件循环。
        if (file.existsSync()) await file.delete();
      });

      final String dataUrl = 'data:image/png;base64,${base64Encode(png)}';
      const String missing = 'C:/sinan/not-exist/never.png';

      void track(String src, String key) => ratios.ensure(
        src,
        onResolved: () {
          callbacks.add(key);
          resolved[key] = ratios[src];
        },
      );

      track(file.path, 'file');
      track(dataUrl, 'data');
      track(missing, 'missing');
      // 重复 ensure 不应再排一次（去重）。
      track(file.path, 'file-again');

      // 等三条解析各自落地。
      for (int i = 0; i < 100 && callbacks.length < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });

    expect(
      resolved['file'],
      closeTo(0.75, 0.001),
      reason: '4×3 的图 ⇒ 高/宽 = 0.75',
    );
    expect(resolved['data'], closeTo(0.75, 0.001), reason: 'data URL 同源');
    expect(resolved['missing'], isNull, reason: '文件不存在 ⇒ 记住失败，不抛');
    expect(callbacks, isNot(contains('file-again')), reason: '同一 src 只解析一次');
  });

  testWidgets('解析完成后**同步**可读（预算器在布局期间就是这么取的）', (
    WidgetTester tester,
  ) async {
    final ImageAspectRatios ratios = ImageAspectRatios();
    expect(ratios['not-resolved-yet'], isNull, reason: '没解析过就是 null');

    late String dataUrl;
    await tester.runAsync(() async {
      final Uint8List png = await makePng(2, 5); // 高/宽 = 2.5（细高）
      dataUrl = 'data:image/png;base64,${base64Encode(png)}';
      ratios.ensure(dataUrl, onResolved: () {});
      for (int i = 0; i < 100 && ratios[dataUrl] == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });

    expect(ratios[dataUrl], closeTo(2.5, 0.001));
  });
}
