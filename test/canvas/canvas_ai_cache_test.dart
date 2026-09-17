import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sinan/src/canvas/kernel/canvas_ai.dart';
import 'package:sinan/src/canvas/kernel/canvas_ai_cache.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/canvas/kernel/ink_stroke.dart';

/// 计数生成器：记录被真正调用的次数，用来证明"命中缓存 = 没调模型"。
class _CountingGenerator implements AiGenerator {
  _CountingGenerator(this.build);

  final Future<GeneratedResult> Function(int call) build;
  int calls = 0;
  Map<String, Uint8List>? lastInputs;

  @override
  Future<GeneratedResult> generate(
    GenRecipe recipe, {
    required Region region,
    Map<String, Uint8List>? inputImages,
  }) async {
    calls++;
    lastInputs = inputImages;
    return build(calls);
  }
}

Region _region([Rect bbox = const Rect.fromLTWH(0, 0, 64, 64)]) =>
    Region(id: 'r1', bbox: bbox);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('缓存键', () {
    test('同输入稳定、跨调用一致（不能用会随机化的 String.hashCode）', () {
      const GenRecipe r = GenRecipe(model: 'm', prompt: 'p', seed: 7);
      expect(aiCacheKey(r, _region(), null), aiCacheKey(r, _region(), null));
    });

    test('prompt / seed / 尺寸 / 输入图字节 任一变化 ⇒ 换键', () {
      const GenRecipe r = GenRecipe(model: 'm', prompt: 'p', seed: 7);
      final String base = aiCacheKey(r, _region(), null);
      expect(aiCacheKey(r.copyWith(prompt: 'q'), _region(), null), isNot(base));
      expect(aiCacheKey(r.copyWith(seed: 8), _region(), null), isNot(base));
      expect(
        aiCacheKey(r, _region(const Rect.fromLTWH(0, 0, 32, 64)), null),
        isNot(base),
      );
      expect(
        aiCacheKey(r, _region(), <String, Uint8List>{
          'image': Uint8List.fromList(<int>[1, 2, 3]),
        }),
        isNot(base),
      );
      expect(
        aiCacheKey(r, _region(), <String, Uint8List>{
          'image': Uint8List.fromList(<int>[9, 9, 9]),
        }),
        isNot(aiCacheKey(r, _region(), <String, Uint8List>{
          'image': Uint8List.fromList(<int>[1, 2, 3]),
        })),
      );
    });

    test('选区**平移**（同尺寸）不换键：模型只看到像素', () {
      const GenRecipe r = GenRecipe(model: 'm', prompt: 'p', seed: 7);
      expect(
        aiCacheKey(r, _region(const Rect.fromLTWH(500, 900, 64, 64)), null),
        aiCacheKey(r, _region(), null),
      );
    });
  });

  group('结果缓存', () {
    test('命中缓存则不再调模型，且结果落成可持久化的路径', () async {
      final Directory dir = await Directory.systemTemp.createTemp('ai_cache_');
      final File src = File('${dir.path}/src.png');
      await src.writeAsBytes(<int>[137, 80, 78, 71]);

      final _CountingGenerator inner =
          _CountingGenerator((int _) async => GeneratedResult(path: src.path));
      final CachingAiGenerator generator = CachingAiGenerator(
        inner,
        AiResultCache(resolveDirectory: () async => '${dir.path}/cache'),
      );
      const GenRecipe recipe = GenRecipe(model: 'm', prompt: 'p', seed: 7);

      final GeneratedResult first = await generator.generate(recipe, region: _region());
      final GeneratedResult second = await generator.generate(recipe, region: _region());

      expect(inner.calls, 1, reason: '第二次应当命中缓存');
      expect(first.path, isNotNull);
      expect(second.path, first.path);
      expect(File(second.path!).existsSync(), isTrue);

      // 换了 prompt ⇒ 未命中，模型被调第二次。
      await generator.generate(recipe.copyWith(prompt: 'other'), region: _region());
      expect(inner.calls, 2);

      await dir.delete(recursive: true);
    });

    test('内存图（本地桩）也会落盘 ⇒ 生成图能随画布存档、重启还在', () async {
      final Directory dir = await Directory.systemTemp.createTemp('ai_cache_');
      final _CountingGenerator inner = _CountingGenerator((int _) async {
        final ui.PictureRecorder recorder = ui.PictureRecorder();
        ui.Canvas(recorder).drawRect(
          const Rect.fromLTWH(0, 0, 4, 4),
          ui.Paint()..color = const Color(0xFF00FF00),
        );
        final ui.Image image = await recorder.endRecording().toImage(4, 4);
        return GeneratedResult(image: image);
      });
      final CachingAiGenerator generator = CachingAiGenerator(
        inner,
        AiResultCache(resolveDirectory: () async => '${dir.path}/cache'),
      );

      final GeneratedResult result = await generator.generate(
        const GenRecipe(model: 'm', prompt: 'p', seed: 1),
        region: _region(),
      );
      expect(result.path, isNotNull);
      expect(File(result.path!).lengthSync(), greaterThan(0));

      await dir.delete(recursive: true);
    });

    test('重启（新缓存实例）仍能命中：索引从目录重建', () async {
      final Directory dir = await Directory.systemTemp.createTemp('ai_cache_');
      final File src = File('${dir.path}/src.png');
      await src.writeAsBytes(<int>[137, 80, 78, 71]);
      const GenRecipe recipe = GenRecipe(model: 'm', prompt: 'p', seed: 7);

      final CachingAiGenerator first = CachingAiGenerator(
        _CountingGenerator((int _) async => GeneratedResult(path: src.path)),
        AiResultCache(resolveDirectory: () async => '${dir.path}/cache'),
      );
      await first.generate(recipe, region: _region());

      // 模拟应用重启：全新的缓存实例，内存索引是空的。
      final _CountingGenerator afterRestart =
          _CountingGenerator((int _) async => GeneratedResult(path: src.path));
      final CachingAiGenerator second = CachingAiGenerator(
        afterRestart,
        AiResultCache(resolveDirectory: () async => '${dir.path}/cache'),
      );
      await second.generate(recipe, region: _region());
      expect(afterRestart.calls, 0, reason: '磁盘上已有结果，不该再调模型');

      await dir.delete(recursive: true);
    });
  });

  group('容量与清理（LRU + 引用保护）', () {
    /// 缓存目录里现存的 `<key>.png`。
    Set<String> names(Directory dir) => <String>{
          for (final FileSystemEntity e in dir.listSync())
            if (e is File) e.uri.pathSegments.last,
        };

    test('没有引用保护时 prune 什么都不删（安全默认）', () async {
      final Directory dir = await Directory.systemTemp.createTemp('ai_prune_');
      final AiResultCache cache = AiResultCache(
        resolveDirectory: () async => dir.path,
        maxEntries: 1,
        maxBytes: 1, // 必然超限
      );
      await cache.store('a', Uint8List(64));
      await cache.store('b', Uint8List(64));

      final CachePruneReport report = await cache.prune();
      expect(report.removed, 0);
      expect(
        names(dir),
        <String>{'a.png', 'b.png'},
        reason: '内核判断不了"谁还被引用"，宁可不删',
      );
      await dir.delete(recursive: true);
    });

    test('按 LRU 淘汰到限额内（最久未用的先走）', () async {
      final Directory dir = await Directory.systemTemp.createTemp('ai_prune_');
      final AiResultCache cache = AiResultCache(
        resolveDirectory: () async => dir.path,
        maxEntries: 2,
        protectedPaths: () => <String>{},
      );
      for (final String key in <String>['a', 'b', 'c']) {
        await cache.store(key, Uint8List(8));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final CachePruneReport report = await cache.prune();
      expect(report.removed, 1);
      expect(report.kept, 2);
      expect(names(dir), <String>{'b.png', 'c.png'});
      await dir.delete(recursive: true);
    });

    test('被引用的文件即使最旧也不会被淘汰', () async {
      final Directory dir = await Directory.systemTemp.createTemp('ai_prune_');
      final String protectedA =
          '${dir.path}${Platform.pathSeparator}a.png';
      final AiResultCache cache = AiResultCache(
        resolveDirectory: () async => dir.path,
        maxEntries: 1,
        protectedPaths: () => <String>{protectedA},
      );
      for (final String key in <String>['a', 'b', 'c']) {
        await cache.store(key, Uint8List(8));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final CachePruneReport report = await cache.prune();
      expect(names(dir), <String>{'a.png'}, reason: 'a 被引用 ⇒ 留下');
      expect(report.removed, 2);
      expect(report.kept, 1);
      await dir.delete(recursive: true);
    });

    test('按字节上限淘汰', () async {
      final Directory dir = await Directory.systemTemp.createTemp('ai_prune_');
      final AiResultCache cache = AiResultCache(
        resolveDirectory: () async => dir.path,
        maxEntries: 100,
        maxBytes: 128, // 正好放得下 2 个 64 字节的条目
        protectedPaths: () => <String>{},
      );
      for (final String key in <String>['a', 'b', 'c', 'd']) {
        await cache.store(key, Uint8List(64));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final CachePruneReport report = await cache.prune();
      expect(report.removed, 2);
      expect(names(dir), <String>{'c.png', 'd.png'});
      await dir.delete(recursive: true);
    });

    test('命中会刷新"最近使用"，常用的结果不会被淘汰', () async {
      final Directory dir = await Directory.systemTemp.createTemp('ai_prune_');
      final AiResultCache cache = AiResultCache(
        resolveDirectory: () async => dir.path,
        maxEntries: 2,
        protectedPaths: () => <String>{},
      );
      await cache.store('a', Uint8List(8));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await cache.store('b', Uint8List(8));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // a 虽写得早，但刚被用过 ⇒ 比 b"新"。
      expect(await cache.lookup('a'), isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await cache.store('c', Uint8List(8));

      await cache.prune();
      expect(
        names(dir),
        containsAll(<String>['a.png', 'c.png']),
        reason: 'a 刚命中过，不该比从未命中的 b 先走',
      );
      expect(names(dir), isNot(contains('b.png')));
      await dir.delete(recursive: true);
    });

    test('引用扫描一次即够：prune 只回调一次 protectedPaths', () async {
      final Directory dir = await Directory.systemTemp.createTemp('ai_prune_');
      int calls = 0;
      final AiResultCache cache = AiResultCache(
        resolveDirectory: () async => dir.path,
        protectedPaths: () {
          calls++;
          return <String>{};
        },
      );
      await cache.prune();
      expect(calls, 1, reason: '逐文件回调会把宿主的数据库扫描重复 N 遍');
      await dir.delete(recursive: true);
    });
  });

  group('过期传播（stale）', () {
    test('输入改动 ⇒ stale；撤销回去 ⇒ 自动恢复 done', () async {
      final CanvasController controller = CanvasController(
        generator: _CountingGenerator((int _) async => const GeneratedResult()),
      );
      final ShapeItem shape = ShapeItem(
        rect: const Rect.fromLTWH(0, 0, 80, 60),
        kind: CanvasShapeKind.rectangle,
        color: const Color(0xFF112233),
        filled: true,
      );
      controller.document.addItem(shape);

      final AiImageItem layer = await controller.generateFromRegion(
        Region(id: 'r', bbox: shape.rect),
      );
      expect(layer.gen.status, GenStatus.done);
      expect(layer.gen.inputFingerprint, isNotNull);
      expect(layer.gen.seed, isNotNull, reason: '种子必须固定，结果才可复现');

      // 动了一下被引用的形状 = 输入变了（走真实落账路径，才能撤销回去）。
      final Rect before = shape.rect;
      shape.rect = before.shift(const Offset(10, 0));
      controller.document.setItemTransforms(
        <(CanvasItem, Rect, double)>[(shape, before, shape.angle)],
      );
      expect(controller.refreshStaleness(), isTrue);
      expect(layer.gen.status, GenStatus.stale);

      // 撤销 ⇒ 输入改回去 ⇒ 过期标记应撤掉（不该一直挂着）。
      controller.undo();
      expect(layer.gen.status, GenStatus.done);
      controller.dispose();
    });

    test('在选区内补一笔也算输入变化', () async {
      final CanvasController controller = CanvasController(
        generator: _CountingGenerator((int _) async => const GeneratedResult()),
      );
      final ShapeItem shape = ShapeItem(
        rect: const Rect.fromLTWH(0, 0, 80, 60),
        kind: CanvasShapeKind.rectangle,
        color: const Color(0xFF112233),
        filled: true,
      );
      controller.document.addItem(shape);
      final AiImageItem layer = await controller.generateFromRegion(
        Region(id: 'r', bbox: shape.rect),
      );
      expect(layer.gen.status, GenStatus.done);

      controller.document
          .addStroke(InkStroke(
            color: const Color(0xFF000000),
            baseWidth: 3,
            points: const <InkPoint>[
              InkPoint(Offset(10, 10), 0),
              InkPoint(Offset(20, 20), 0),
            ],
          ));
      expect(controller.refreshStaleness(), isTrue);
      expect(layer.gen.status, GenStatus.stale);
      controller.dispose();
    });

    test('纯文生图（选区无内容）不记指纹 ⇒ 永不 stale', () async {
      final CanvasController controller = CanvasController(
        generator: _CountingGenerator((int _) async => const GeneratedResult()),
      );
      final AiImageItem layer = await controller.generateFromRegion(
        Region(id: 'r', bbox: const Rect.fromLTWH(0, 0, 100, 100)),
      );
      expect(layer.gen.inputFingerprint, isNull);
      controller.document
          .addStroke(InkStroke(
            color: const Color(0xFF000000),
            baseWidth: 3,
            points: const <InkPoint>[
              InkPoint(Offset(10, 10), 0),
              InkPoint(Offset(20, 20), 0),
            ],
          ));
      expect(controller.refreshStaleness(), isFalse);
      expect(layer.gen.status, GenStatus.done);
      controller.dispose();
    });
  });
}
