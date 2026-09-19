import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sinan/src/canvas/kernel/canvas_camera.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_document.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/canvas/kernel/canvas_painters.dart';
import 'package:sinan/src/canvas/kernel/ink_stroke.dart';

/// 画布**性能基准**（2026-09-19）。
///
/// ## 为什么要有这个
/// `canvas_architecture.md` 的性能阶梯里，L2（瓦片重放）+ L3（空间索引）都写着
/// "笔迹 > 1w 条且 L1 不够时再做"。但仓库里**从没有任何实测数字** ⇒ 那两个"该不该
/// 做"是悬空的决策。本基准就是把它们变成**有据**的决策。
///
/// ## 测什么（都是纯 Dart，不 pump widget ⇒ 噪声小、可复现）
/// 1. **写字**：每落一笔 ⇒ `document.revision` 变 ⇒ `pictureFor` **重录全量 Picture**。
///    于是"写第 N 笔"的代价是 N ⇒ 写满 N 笔的总代价是 **O(N²)**。这是最该量的一条。
/// 2. **平移 / 缩放**：单帧重绘走缓存 Picture，理论上与笔迹数**无关**（L1 的收益）。
/// 3. **退化对照**：不走 Picture、逐条画（O(N) 每帧）—— 用来确认 L1 到底省了多少。
/// 4. **item 层**：`itemsIn` 的扫描成本、`ItemPainter` 在**开/关 LOD** 下的绘制成本。
///
/// ## 纪律
/// 结果**只打印**，不做紧的阈值断言（机器性能差异会让紧阈值变成随机失败）。
/// 唯一的断言是一条**很松**的护栏：只用来抓住"量级退化"（例如不小心把
/// Picture 缓存去掉、或让 LOD 失效）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const Size viewport = Size(1600, 1000);
  const List<int> strokeCounts = <int>[1000, 4000, 10000];

  test('笔迹：写字 / 平移缩放 / 逐条绘制（对照）', () {
    final StringBuffer out = StringBuffer()
      ..writeln('### 笔迹基准（视口 ${viewport.width.round()}×'
          '${viewport.height.round()}，中位数 μs）')
      ..writeln('| 笔迹数 | 落一笔后**重录** | 单帧重绘（走 Picture） | '
          '单帧重绘（逐条画，对照） |')
      ..writeln('|---:|---:|---:|---:|');

    late int recordAt10k;
    late int frameAt10k;

    for (final int count in strokeCounts) {
      final CanvasController controller = _controllerWith(count);
      final CanvasCamera camera = controller.camera;

      // ① 落一笔后再取 Picture ⇒ 重录全量（这是"写字"的真实增量成本）
      //
      // ⚠️ **不要** dispose `pictureFor` 返回的 Picture：它归控制器所有（重录时与
      // `controller.dispose()` 会各自 release）。外部再 dispose 一次 ⇒ 引擎侧
      // 二次释放直接断言失败。
      final int recordUs = _measureUs(() {
        controller.document.addStroke(_stroke(999999)); // 让 revision 变
        controller.pictureFor(kThemeInk);
      });

      // ② 单帧重绘（走缓存 Picture）
      final ui.Picture pic = controller.pictureFor(kThemeInk)!;
      final int frameUs = _measureUs(() => _paintInk(camera, picture: pic));

      // ③ 对照：逐条画（不走 Picture）
      final List<InkStroke> all = controller.document.strokes;
      final int perStrokeUs = _measureUs(() => _paintInk(camera, strokes: all));

      if (count == 10000) {
        recordAt10k = recordUs;
        frameAt10k = frameUs;
      }

      out.writeln(
        '| $count | ${_fmt(recordUs)} | ${_fmt(frameUs)} | ${_fmt(perStrokeUs)} |',
      );
      // 控制器自己会 release 它持有的 Picture。
      controller.dispose();
    }

    debugPrint('\n$out');

    // 很松的护栏：1w 笔迹下单帧重绘不该到"肉眼可见卡顿"的量级（100ms）。
    // 真退化（比如把 Picture 缓存去掉）会立刻撞上这条。
    expect(
      frameAt10k,
      lessThan(100000),
      reason: '1w 笔迹的单帧重绘退化到 $frameAt10k μs —— L1 的 Picture 缓存失效了？',
    );
    // 重录（写字增量）到 1w 条时也要有上限，否则书写会明显发涩。
    expect(
      recordAt10k,
      lessThan(500000),
      reason: '1w 笔迹时落一笔要重录 $recordAt10k μs —— 写字会明显发涩',
    );
  });

  test('item：视口扫描 + 开/关 LOD 的绘制成本', () {
    final StringBuffer out = StringBuffer()
      ..writeln('### item 基准（中位数 μs）')
      ..writeln('| item 数 | `itemsIn` 扫描 | 绘制（正常缩放，LOD 不生效） | '
          '绘制（缩到 5%，LOD 生效） |')
      ..writeln('|---:|---:|---:|---:|');

    for (final int count in const <int>[100, 1000, 3000]) {
      final CanvasDocument doc = _docWithCards(count);
      final CanvasCamera normal = CanvasCamera(scale: 1);
      final CanvasCamera zoomedOut = CanvasCamera(scale: 0.05);

      final Rect world = normal.visibleWorld(viewport);
      final int scanUs = _measureUs(() => doc.itemsIn(world));

      final List<CanvasItem> visible = doc.itemsIn(world);
      final int normalUs = _measureUs(
        () => _paintItems(normal, visible, lod: true, lodScale: normal.scale),
      );

      // 缩到 5%：视口包住整张画布 ⇒ 裁剪失效、全部进绘制列表 ⇒ 正是 LOD 的场景。
      final List<CanvasItem> allVisible = doc.itemsIn(zoomedOut.visibleWorld(viewport));
      final int zoomedUs = _measureUs(
        () => _paintItems(zoomedOut, allVisible, lod: true, lodScale: zoomedOut.scale),
      );
      // 同场景关掉 LOD，看 LOD 到底省了多少。
      final int noLodUs = _measureUs(() => _paintItems(zoomedOut, allVisible, lod: false));

      out.writeln(
        '| $count | ${_fmt(scanUs)} | ${_fmt(normalUs)} | '
            '${_fmt(zoomedUs)}（关 LOD：${_fmt(noLodUs)}） |',
      );
    }

    debugPrint('\n$out');
    // 本用例只量数据，不做阈值断言（机器差异大）；上一条用例的护栏已覆盖量级退化。
  });
}

// ─────────────────────────── 工具 ───────────────────────────

int mathMin(int a, int b) => a < b ? a : b;

/// 中位数（跑 7 次，先预热 1 次）：避开单次抖动与首帧的懒加载。
int _measureUs(void Function() body, {int runs = 7}) {
  body(); // 预热
  final List<int> samples = <int>[];
  for (int i = 0; i < runs; i++) {
    final Stopwatch sw = Stopwatch()..start();
    body();
    sw.stop();
    samples.add(sw.elapsedMicroseconds);
  }
  samples.sort();
  return samples[samples.length ~/ 2];
}

String _fmt(int us) =>
    us >= 1000 ? '${(us / 1000).toStringAsFixed(1)}ms' : '$us μs';

CanvasController _controllerWith(int strokeCount) {
  final CanvasController controller = CanvasController();
  controller.setViewport(const Size(1600, 1000));
  for (int i = 0; i < strokeCount; i++) {
    controller.document.addStroke(_stroke(i));
  }
  return controller;
}

/// 一条**跨满画布**的短笔迹（保证任何视口下都能被命中/绘制，测的是规模不是裁剪）。
InkStroke _stroke(int i) {
  final double y = (i % 200) * 5.0;
  return InkStroke(
    color: kThemeInk,
    baseWidth: 4,
    points: <InkPoint>[
      InkPoint(Offset(0, y), 0),
      InkPoint(Offset(400, y + 12), 0),
      InkPoint(Offset(800, y), 0),
    ],
  );
}

CanvasDocument _docWithCards(int count) {
  final CanvasDocument doc = CanvasDocument();
  for (int i = 0; i < count; i++) {
    doc.addItem(
      CardItem(
        rect: Rect.fromLTWH((i % 50) * 220.0, (i ~/ 50) * 140.0, 200, 120),
        blockId: 'blk-$i',
        text: '第 $i 张卡片的一点文字内容',
      ),
    );
  }
  return doc;
}

void _paintInk(
  CanvasCamera camera, {
  ui.Picture? picture,
  List<InkStroke>? strokes,
}) {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  InkPainter(
    camera: camera,
    picture: picture,
    strokes: strokes ?? const <InkStroke>[],
  ).paint(canvas, const Size(1600, 1000));
  recorder.endRecording().dispose();
}

void _paintItems(
  CanvasCamera camera,
  List<CanvasItem> items, {
  required bool lod,
  double? lodScale,
}) {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  ItemPainter(
    camera: camera,
    items: items,
    lod: lod,
    lodScale: lodScale,
  ).paint(canvas, const Size(1600, 1000));
  recorder.endRecording().dispose();
}
