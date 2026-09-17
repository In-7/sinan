import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/app/pending_saves.dart';

/// 退出前落盘登记处：它决定"关窗口会不会丢掉最后一次编辑"，所以三条护栏
/// ——**等得到**、**不连累**、**不阻塞**——各自单独钉一遍。
///
/// 对应的真实故障：2026-09-17 用户实测"删掉一段文字、马上关窗口，重开后那段
/// 文字又回来了"——防抖还没到期，进程就退出了。
void main() {
  test('flushAll 会**等到**动作写完，而不是发出去就算', () async {
    final PendingSaves saves = PendingSaves();
    final Completer<void> written = Completer<void>();
    bool done = false;
    saves.register(() async {
      await written.future;
      done = true;
    });

    final Future<void> flushing = saves.flushAll();
    await Future<void>.delayed(Duration.zero);
    expect(
      done,
      isFalse,
      reason: 'flushAll 提前返回了：关窗口时我们会在写入完成前就退出进程',
    );

    written.complete();
    await flushing;
    expect(done, isTrue, reason: '写完了 flushAll 却还没回来');
  });

  test('注销后不再被落盘（视图已销毁，不该再写它）', () async {
    final PendingSaves saves = PendingSaves();
    int calls = 0;
    final void Function() unregister = saves.register(() async => calls++);

    unregister();
    expect(saves.registeredCount, 0, reason: '注销没生效：已销毁的视图仍会被落盘');

    await saves.flushAll();
    expect(calls, 0);
  });

  test('一个动作抛异常：不影响其它动作，也不抛给调用方', () async {
    final PendingSaves saves = PendingSaves();
    bool otherRan = false;
    saves.register(() async => throw StateError('写库炸了'));
    saves.register(() async => otherRan = true);

    await saves.flushAll();
    expect(otherRan, isTrue, reason: '一个视图写不进去，另一个视图的编辑跟着丢了');
  });

  test('超时后照常返回（写库卡住不能让窗口关不掉）', () async {
    final PendingSaves saves = PendingSaves();
    final Completer<void> never = Completer<void>();
    saves.register(() => never.future);

    final Stopwatch watch = Stopwatch()..start();
    await saves.flushAll(timeout: const Duration(milliseconds: 50));
    watch.stop();

    expect(
      watch.elapsedMilliseconds,
      lessThan(1000),
      reason: '超时没兜住：落盘卡住时窗口会一直关不掉',
    );
  });

  test('退出应答：写完才放行 exit', () async {
    final PendingSaves saves = PendingSaves();
    final Completer<void> written = Completer<void>();
    bool done = false;
    saves.register(() async {
      await written.future;
      done = true;
    });

    final Future<AppExitResponse> answer = flushThenExit(saves);
    await Future<void>.delayed(Duration.zero);
    expect(
      done,
      isFalse,
      reason: '落盘没写完就放行退出了：最后那次编辑会丢（就是用户实测的那个 bug）',
    );

    written.complete();
    expect(await answer, AppExitResponse.exit);
  });

  test('落盘失败或卡住也必须答 exit（答 cancel 会让窗口彻底关不掉）', () async {
    final PendingSaves boom = PendingSaves();
    boom.register(() async => throw StateError('写库炸了'));
    expect(await flushThenExit(boom), AppExitResponse.exit);

    final PendingSaves stalled = PendingSaves();
    stalled.register(() => Completer<void>().future);
    expect(
      await flushThenExit(stalled, timeout: const Duration(milliseconds: 50)),
      AppExitResponse.exit,
      reason: '落盘卡住时答了 cancel：用户从此关不掉这个窗口',
    );
  });
}
