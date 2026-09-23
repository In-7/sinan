import 'dart:convert';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sinan/main.dart' as app;
import 'package:sinan/src/dev/frame_probe.dart';

/// **性能场景采集**（`docs/perf_baseline.md` §2 的自动化部分）。
///
/// ## 为什么不用 integration_test 的 `traceAction` / `flutter drive`
/// 桌面端实测走不通，两条都被证伪过：
/// - `flutter drive --driver=…`：运行期警告 `integration_test plugin was not
///   detected`，测试全过但**什么都不上报**（表现为"没有数字"）；
/// - `traceAction` 在 Flutter 3.47 返回 **void**（它的 Timeline 只经 `reportData`
///   上报，而那条路依赖上面的 driver）。
///
/// 所以直接用引擎的 [SchedulerBinding.addTimingsCallback] 收 [FrameTiming]，
/// 统计交给 [summarizeFrameDurations]（`lib/src/dev/frame_probe.dart`）——那是与
/// 人工场景「连打」**共用的一份实现**，两处产出的 JSON 因此同形状、同口径。
/// 好处是**不依赖任何上报通道**：这套数字在
/// `flutter test integration_test/perf_test.dart --profile -d windows` 下就能拿到。
///
/// ## 它测什么、不测什么
/// - ✅ **滚动 / 画布拖动缩放 / 画布书写**：合成指针事件走的渲染路径与真人一致。
/// - ❌ **连打**：测试只能整段替换式输入，不等于真人逐键 ⇒ 人工测（`flutter run
///   --profile` 里按 F9 开关采集，见 `lib/src/dev/frame_probe.dart`）。
/// - ❌ **冷启动**：应用已在运行时测不了启动 ⇒ `flutter run --profile
///   --trace-startup`（人工）。
///
/// ## 前置条件
/// 库里必须有夹具（标题见 [_noteTitle] / [_canvasTitle]）：
/// ```powershell
/// flutter test test/perf/fixture_generator.dart --dart-define=SINAN_FIXTURES=make
/// ```
/// 用 `tool/perf_run.ps1` 会连生成带清理一起做完。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('采集：滚动 / 画布拖动缩放 / 画布书写', (WidgetTester tester) async {
    // 跑真实应用（真实 DB、设置、窗口）——不是"重建一个测试用 App"，
    // 那样测到的是测试壳而不是我们的壳。
    await app.main();
    await tester.pumpAndSettle();

    final _FrameCollector frames = _FrameCollector();

    // ── 场景 1：大笔记滚动 ──────────────────────────────────────────────
    await _openNote(tester, _noteTitle);
    await frames.scene('scroll_editor', tester, () async {
      for (int i = 0; i < 8; i++) {
        // 用**屏幕坐标**而不是 finder 定位编辑器：编辑器在右栏（左侧约 300px
        // 侧栏），取 62% 宽度处一定落在正文里。不依赖内部 widget 类型 ⇒
        // 换皮换掉滚动实现也不会让这个测试失效。
        await tester.dragFrom(_editorPoint(tester), const Offset(0, -600));
        await tester.pump();
      }
    });

    // ── 场景 2：画布拖动 + 缩放 ────────────────────────────────────────
    await _openNote(tester, _canvasTitle);
    // 抓手拖拽 = 平移（整屏重绘）；缩放 = 全量重排 + 重新裁剪，且缩小会跨过
    // LOD 阈值（正是要复测的那条路径）。
    await tester.tap(find.byTooltip('抓手（空格）').first);
    await tester.pumpAndSettle();
    await frames.scene('canvas_pan_zoom', tester, () async {
      for (int i = 0; i < 6; i++) {
        await tester.dragFrom(_canvasPoint(tester), const Offset(-320, -180));
        await tester.pump();
      }
      for (int i = 0; i < 5; i++) {
        await tester.tap(find.byTooltip('缩小').first);
        await tester.pump();
      }
      for (int i = 0; i < 5; i++) {
        await tester.tap(find.byTooltip('放大').first);
        await tester.pump();
      }
    });

    // ── 场景 3：画布书写 ────────────────────────────────────────────────
    // 笔迹层走"已完笔迹烤成 Picture + 书写时只画 activeStroke"，与平移/缩放的
    // 成本结构完全不同，必须单独测。
    await tester.tap(find.byTooltip('画笔').first);
    await tester.pumpAndSettle();
    await frames.scene('canvas_draw', tester, () async {
      for (int i = 0; i < 6; i++) {
        final Offset start = _canvasPoint(tester) + Offset(0, i * 30.0);
        final TestGesture gesture = await tester.startGesture(start);
        for (int k = 0; k < 20; k++) {
          await gesture.moveBy(const Offset(12, 4));
          await tester.pump();
        }
        await gesture.up();
        await tester.pump();
      }
    });

    frames.detach();
  });
}

const String _noteTitle = '【性能夹具】大笔记';
const String _canvasTitle = '【性能夹具】大画布';

/// 帧耗时收集器：攒 [FrameTiming]，统计交给 [summarizeFrameDurations]
/// （`lib/src/dev/frame_probe.dart`，与人工探针共用同一份实现）。
///
/// 单位统一为**毫秒**；除均值外还算 **p90**——卡顿看尾部，均值会把卡顿平均掉
/// （这是 `docs/perf_baseline.md` §4 的规则）。
class _FrameCollector {
  _FrameCollector() {
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  final List<FrameTiming> _frames = <FrameTiming>[];

  void _onTimings(List<FrameTiming> timings) => _frames.addAll(timings);

  void detach() => SchedulerBinding.instance.removeTimingsCallback(_onTimings);

  /// 采集一个场景：[body] 是驱动动作，前后各留一帧把边界排除掉。
  Future<void> scene(
    String key,
    WidgetTester tester,
    Future<void> Function() body,
  ) async {
    // 边界对齐：先空转两帧，避免把上一个场景的尾帧算进来。
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    _frames.clear();

    await body();

    // 收尾：等回调把最后几帧送到（FrameTiming 是**异步**上报的）。
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final Map<String, Object?> summary = summarizeFrameTimings(_frames, key);
    final Directory dir = Directory('build/perf')..createSync(recursive: true);
    final File out = File('${dir.path}/$key.json');
    out.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(summary),
    );
    // ignore: avoid_print
    print('PERF $key ${jsonEncode(summary)}');
  }
}

/// 打开标题为 [title] 的笔记（列表按最近修改排序 ⇒ 夹具在最前，
/// 但用 `first` 兜住"用户自己也有同名笔记"的极端情况）。
Future<void> _openNote(WidgetTester tester, String title) async {
  final Finder entry = find.text(title);
  expect(
    entry,
    findsWidgets,
    reason: '列表里没有【$title】：先跑夹具生成器（见文件头说明）',
  );
  await tester.tap(entry.first);
  await tester.pumpAndSettle();
}

/// 编辑器正文里的一个点（右栏、纵向居中）。
Offset _editorPoint(WidgetTester tester) => _pointAt(tester, 0.62, 0.5);

/// 画布里的一个点（避开底部工具条与左上角历史条）。
Offset _canvasPoint(WidgetTester tester) => _pointAt(tester, 0.5, 0.4);

Offset _pointAt(WidgetTester tester, double fx, double fy) {
  final Size size = tester.view.physicalSize / tester.view.devicePixelRatio;
  return Offset(size.width * fx, size.height * fy);
}
