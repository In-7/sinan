import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/app/providers.dart';

/// `locateProvider` 的行为（`docs/ui_rewrite_plan.md` §4）。
///
/// 它只做一件事：把"要到哪里"变成一条**可被编辑器消费的请求**。这里盯三个
/// 做错了现象很隐蔽的点——目标笔记要跟着切；**连点两次也要能再跳**（靠序号）；
/// 消费后要清干净（否则重开笔记会莫名其妙又跳一次）。
void main() {
  late ProviderContainer container;
  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  test('locate：切换当前笔记，并把目标写进请求', () {
    container.read(locateProvider.notifier).locate(noteId: 'n1');

    expect(container.read(selectedNoteIdProvider), 'n1');
    final LocateRequest? req = container.read(locateProvider);
    expect(req?.noteId, 'n1');
    expect(req?.blockId, isNull);
    expect(req?.focus, isFalse);
  });

  test('连着两次相同目标：seq 递增（否则第二次是"状态没变"，跳不动）', () {
    final LocateNotifier notifier = container.read(locateProvider.notifier);
    notifier.locate(noteId: 'n1', blockId: 'b1');
    final int first = container.read(locateProvider)!.seq;

    notifier.locate(noteId: 'n1', blockId: 'b1');

    expect(container.read(locateProvider)!.seq, greaterThan(first));
  });

  test('同一篇笔记换一个块：也算新请求', () {
    final LocateNotifier notifier = container.read(locateProvider.notifier);
    notifier.locate(noteId: 'n1', blockId: 'b1');
    final int first = container.read(locateProvider)!.seq;

    notifier.locate(noteId: 'n1', blockId: 'b2');

    expect(container.read(locateProvider)!.seq, greaterThan(first));
  });

  test('focus 只在要求时带上（从列表点开一篇不该抢焦点）', () {
    final LocateNotifier notifier = container.read(locateProvider.notifier);

    notifier.locate(noteId: 'n1');
    expect(container.read(locateProvider)!.focus, isFalse);

    notifier.locate(noteId: 'n2', blockId: 'b1', focus: true);
    expect(container.read(locateProvider)!.focus, isTrue);
  });

  test('consume 置空（消费即置空，避免重开笔记时重复跳）', () {
    container.read(locateProvider.notifier).locate(noteId: 'n1', blockId: 'b1');

    container.read(locateProvider.notifier).consume();

    expect(container.read(locateProvider), isNull);
  });
}
