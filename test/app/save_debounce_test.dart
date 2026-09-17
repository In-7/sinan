import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/app/save_debounce.dart';

/// 落盘防抖**上限**的回归（2026-09-17，崩溃恢复评估的 A 项）。
///
/// 要钉的是那个反直觉的差别：
/// - **纯防抖**在连续输入下**一次都不落盘**（"停顿"这个条件永远不成立）⇒ 暴露窗口
///   随时间**线性增长**（打三分钟就丢三分钟）；
/// - 加上 [SaveDebounce.maxWait] 之后，暴露窗口才有**硬上界**。
///
/// 第二条用例特意把 `maxWait` 设得极大来**复现旧行为**——它就是这个组件存在的理由：
/// 将来谁把 `??=` 改成可重置（"顺手优化"），那条断言会立刻红。
///
/// 时钟用 `testWidgets` 的假时钟（`tester.pump(duration)` 会推进它并触发计时器），
/// 因此不需要引入 `fake_async` 依赖。⚠️ 每条用例结束前必须让计时器清零
/// （`cancel()` 或已落盘），否则 testWidgets 会报"残留 Timer"。
void main() {
  /// 起一棵最小 widget 树：让 `tester.pump` 有明确的帧上下文。
  Future<void> mount(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox());

  testWidgets('停顿即落盘：一次变更 + 等过 window ⇒ 落一次', (WidgetTester tester) async {
    await mount(tester);
    int flushes = 0;
    final SaveDebounce save = SaveDebounce(
      window: const Duration(milliseconds: 500),
      maxWait: const Duration(seconds: 2),
      onFlush: () => flushes++,
    );

    save.bump();
    await tester.pump(const Duration(milliseconds: 499));
    expect(flushes, 0, reason: '防抖窗口内不该提前落盘（即时性由 window 保证）');
    await tester.pump(const Duration(milliseconds: 2));
    expect(flushes, 1);
    expect(save.pending, isFalse);
    save.cancel();
  });

  testWidgets('反面证据：没有上限时，连续输入可以一直不落盘（旧行为）', (
    WidgetTester tester,
  ) async {
    await mount(tester);
    int flushes = 0;
    // maxWait 取到足够大 ⇒ 等价于"纯防抖"（改动前的实现）。
    final SaveDebounce save = SaveDebounce(
      window: const Duration(milliseconds: 500),
      maxWait: const Duration(days: 1),
      onFlush: () => flushes++,
    );

    // 每 100ms 变一次，连续 30 秒（模拟不停手地打字 / 运笔）。
    for (int i = 0; i < 300; i++) {
      save.bump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(
      flushes,
      0,
      reason: '纯防抖在连续输入下永不落盘——这正是必须给防抖加上限的原因',
    );
    save.cancel();
  });

  testWidgets('有上限：连续输入时最迟每 maxWait 落一次', (WidgetTester tester) async {
    await mount(tester);
    final List<Duration> flushedAt = <Duration>[];
    Duration now = Duration.zero;
    final SaveDebounce save = SaveDebounce(
      window: const Duration(milliseconds: 500),
      maxWait: const Duration(seconds: 2),
      onFlush: () => flushedAt.add(now),
    );

    // 每 100ms 变一次，连续 10 秒（中间没有任何一次停顿够 500ms）。
    for (int i = 0; i < 100; i++) {
      save.bump();
      await tester.pump(const Duration(milliseconds: 100));
      now += const Duration(milliseconds: 100);
    }

    expect(
      flushedAt.length,
      greaterThanOrEqualTo(4),
      reason: '10 秒连续输入至少该落 4 次（10s / 2s）',
    );
    for (int i = 1; i < flushedAt.length; i++) {
      expect(
        flushedAt[i] - flushedAt[i - 1],
        lessThanOrEqualTo(const Duration(seconds: 2)),
        reason: '两次落盘间隔超过了上限：暴露窗口没有被封顶',
      );
    }
    save.cancel();
  });

  testWidgets('flushNow 立即落盘并清空；cancel 是丢弃（不落盘）', (WidgetTester tester) async {
    await mount(tester);
    int flushes = 0;
    final SaveDebounce save = SaveDebounce(
      window: const Duration(milliseconds: 500),
      maxWait: const Duration(seconds: 2),
      onFlush: () => flushes++,
    );

    save.bump();
    save.flushNow();
    expect(flushes, 1);
    expect(save.pending, isFalse);
    await tester.pump(const Duration(seconds: 5));
    expect(flushes, 1, reason: '落盘后不该有残留计时器再补一次');

    save.bump();
    save.cancel();
    expect(save.pending, isFalse);
    await tester.pump(const Duration(seconds: 5));
    expect(flushes, 1, reason: 'cancel 用于"dispose 里已手动落过盘"的场景');
  });

  test('断言：maxWait 短于 window 是配置错误', () {
    expect(
      () => SaveDebounce(
        window: const Duration(seconds: 2),
        maxWait: const Duration(milliseconds: 500),
        onFlush: () {},
      ),
      throwsA(isA<AssertionError>()),
    );
  });
}
