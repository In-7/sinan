import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/tokens.dart';
import 'package:sinan/src/window/window_base.dart';
import 'package:window_manager/window_manager.dart';

/// 窗口最外层（[WindowBase]）的回归。
///
/// ## 它钉的是什么
/// 两条"改起来无声、坏了才疼"的接线：
/// 1. **不再自绘窗口底**（2026-09-23）：底色改由平台窗口铺
///    （[WindowService.applyWindowBackground]，同一个 [AppTheme.windowBackground] 令牌）
///    ⇒ 这里再留一层 `ColoredBox` 就是每帧一次全屏 fill 白付，还会与平台那层打架。
///    ⚠️ 将来**上 Mica** 时这层必须回来（窗口重新透明 + 除左栏外铺），见类文档；
/// 2. **顶边/顶角缩放手柄**只在最外层圈一次，且**只圈顶边**（圈了右边会吃掉滚动条
///    抓取区）。它同时保证"顶边 8px = 缩放、顶边之下 = 拖动窗口"这个**一个手势一个
///    归宿**的分工——历史上"顶边拖不动"就是这层断掉（见 `window_base.dart` 文档）。
///
/// ## 判据为什么用 platform channel 而不是"看有没有那个 widget"
/// `startResizing(edge)` / `startDragging()` 是这两个部件的**唯一对外动作**，直接读
/// 通道就知道**发真手势**之后到底谁接了：结构对不对会骗人，命中归属不会。
/// （`window_manager` 的通道名与方法名见 `window_manager.dart:43` / `:719` / `:728`。）
void main() {
  /// `window_manager` 的平台通道。
  const MethodChannel channel = MethodChannel('window_manager');

  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          // `startDragging` 在 Windows 上会先问 `isFullScreen()`，为真就直接返回
          // （`window_manager.dart:720`）⇒ 一律回 false 让流程走下去。
          return false;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// 搭一棵**微缩的真实树**：`WindowBase`（窗口底 + 顶边手柄）包住应用内容，内容
  /// 顶部是一条 [DragToMoveArea]——真实场景里那是自绘标题栏的拖拽区
  /// （`app_title_bar.dart` 的 `WindowStrip`）。
  Future<void> pump(
    WidgetTester tester, {
    required Brightness brightness,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: brightness == Brightness.dark
            ? AppTheme.dark()
            : AppTheme.light(),
        home: const WindowBase(
          child: Column(
            children: <Widget>[
              DragToMoveArea(
                child: SizedBox(
                  width: double.infinity,
                  height: Tokens.titleBarHeightMain,
                ),
              ),
              Expanded(child: SizedBox.expand()),
            ],
          ),
        ),
      ),
    );
  }

  /// 在 [at] 按下并拖一小段，然后松开——鼠标设备（真实输入），判定阈值是 1px 那档。
  Future<void> dragAt(WidgetTester tester, Offset at) async {
    final TestGesture gesture = await tester.startGesture(
      at,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveBy(const Offset(4, 4));
    await tester.pump();
    await gesture.up();
    // 通道调用是异步的：多推一帧再断言，免得读到"还没发出去"的 `calls`。
    await tester.pump();
    // ⚠️ 再等过**双击判定窗口**：`DragToResizeArea` 的边上挂着 `onDoubleTap`
    // （Win 上 = 垂直最大化），`DoubleTapGestureRecognizer` 会为每次按下挂一个
    // ~300ms 的计时器。不等它到期，测试会以 "Pending timers" 失败。
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 收到的动作名（`startResizing` / `startDragging` …）。
  List<String> methods() => calls.map((MethodCall c) => c.method).toList();

  /// 顶边那条感应带的厚度（**逻辑 px**，随 DPR 折算）。
  double bandOf(WidgetTester tester) => tester
      .widget<DragToResizeArea>(find.byType(DragToResizeArea))
      .resizeEdgeSize;

  /// 收到的缩放边（`top` / `topLeft` …）。
  List<Object?> resizedEdges() => calls
      .where((MethodCall c) => c.method == 'startResizing')
      .map(
        (MethodCall c) => (c.arguments as Map<Object?, Object?>)['resizeEdge'],
      )
      .toList();

  for (final Brightness brightness in Brightness.values) {
    testWidgets('$brightness：不自绘窗口底（交给平台窗口，省每帧一次全屏 fill）', (
      WidgetTester tester,
    ) async {
      await pump(tester, brightness: brightness);

      // ⚠️ 判据是"**没有**这层"：底色已由 [WindowService.applyWindowBackground]
      // 铺在平台窗口上，这里再铺一次就是白付一次全屏 fill。
      // （2026-09-23 实机确认后才敢删：圆角在 / 切明暗不闪 / 无黑底。）
      //
      // ⚠️ 只看 `DragToResizeArea` 的**直接子节点**：不能用"树里有没有 ColoredBox"
      // ——`Material` 部件内部自己就画 `ColoredBox`（实测找得到 3 个）。
      final DragToResizeArea area = tester.widget<DragToResizeArea>(
        find.byType(DragToResizeArea),
      );
      expect(
        area.child,
        isNot(isA<ColoredBox>()),
        reason: '又在 Flutter 侧铺了一层窗口底 ⇒ 与平台那层重复，每帧白付一次全屏 fill',
      );
    });
  }

  testWidgets('缩放手柄只圈顶边三条（左右底该走系统原生边框）', (WidgetTester tester) async {
    await pump(tester, brightness: Brightness.dark);

    final DragToResizeArea area = tester.widget<DragToResizeArea>(
      find.byType(DragToResizeArea),
    );
    expect(
      area.enableResizeEdges,
      <ResizeEdge>[ResizeEdge.top, ResizeEdge.topLeft, ResizeEdge.topRight],
      reason:
          '左右底三边该走系统原生边框；Flutter 侧的手柄压在内容上，'
          '圈了右边会吃掉滚动条的抓取区',
    );
  });

  // 厚度：`resizeEdgeSize` 收的是**逻辑 px**，而左右底三边的原生边框是 **8 物理 px**
  // （window_manager 在 `WM_NCCALCSIZE` 里写死的、不随 DPI 变）⇒ 必须按 DPR 折算才同档。
  // 写死 `8` 的话：100% 下正好 8 物理 px，125% 就厚成 10 物理 px（顶边比另外三边厚）。
  for (final double dpr in <double>[1.0, 1.25, 1.5, 2.0]) {
    testWidgets('顶边手柄与三边原生同档（DPR $dpr ⇒ 8 物理 px）', (WidgetTester tester) async {
      tester.view.devicePixelRatio = dpr;
      addTearDown(tester.view.reset);
      await pump(tester, brightness: Brightness.dark);

      final DragToResizeArea area = tester.widget<DragToResizeArea>(
        find.byType(DragToResizeArea),
      );
      expect(
        area.resizeEdgeSize * dpr,
        closeTo(8, 0.001),
        reason: '顶边比左右底厚/薄了 ⇒ 四条边手感不一致（别把逻辑 px 当物理 px 写死）',
      );
    });
  }

  testWidgets('顶边带内拖动 = 缩放窗口（不是移动窗口）', (WidgetTester tester) async {
    await pump(tester, brightness: Brightness.dark);
    final Size size = tester.getSize(find.byType(DragToResizeArea));

    // 取**带内**的点：厚度随 DPR 折算，所以按实际值算，别写死 `y=2`。
    await dragAt(tester, Offset(size.width / 2, bandOf(tester) / 2));

    expect(resizedEdges(), <Object?>['top'], reason: '顶边没接住缩放');
    expect(
      methods(),
      isNot(contains('startDragging')),
      reason: '顶边那条带被 [DragToMoveArea] 吞成"移动窗口"了 ⇒ 顶边缩放又没了',
    );
  });

  testWidgets('两个顶角也能缩放（旧版只有 top，没有角）', (WidgetTester tester) async {
    await pump(tester, brightness: Brightness.dark);
    final Size size = tester.getSize(find.byType(DragToResizeArea));
    final double d = bandOf(tester) / 2;

    await dragAt(tester, Offset(d, d));
    expect(resizedEdges(), <Object?>['topLeft']);

    await dragAt(tester, Offset(size.width - d, d));
    expect(resizedEdges(), <Object?>['topLeft', 'topRight']);
  });

  testWidgets('顶边带之外：窗口内容照常收手势，右侧边不缩放（只圈顶边）', (WidgetTester tester) async {
    await pump(tester, brightness: Brightness.dark);
    final Size size = tester.getSize(find.byType(DragToResizeArea));
    final double band = bandOf(tester);

    // 带**之下**、仍在标题栏拖拽区里（`Tokens.titleBarHeightMain` 有 36px 富余）⇒
    // 该是"移动窗口"。
    await dragAt(tester, Offset(size.width / 2, band + 12));
    expect(methods(), contains('startDragging'), reason: '标题栏拖不动窗口了');
    expect(resizedEdges(), isEmpty, reason: '感应带越界了（比原生厚 ⇒ 想拖窗口却缩放）');

    // 右边中部：既不该缩放（Flutter 侧没圈），也不该拖动。
    calls.clear();
    await dragAt(tester, Offset(size.width - 2, size.height / 2));
    expect(methods(), isEmpty, reason: '右边被 Flutter 侧的手柄接住了 ⇒ 会吃掉滚动条的抓取区');
  });
}
