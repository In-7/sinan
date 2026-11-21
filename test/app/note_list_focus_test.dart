import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/home_hub.dart' show homeItemsProvider;
import 'package:sinan/src/app/home_screen.dart';
import 'package:sinan/src/app/note_list_column.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/focus_ring.dart';
// 只取 Database / sqlite3：sqlite3 还导出一个 `Row`，与 Flutter 的 Row 撞名。
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// 列表键盘导航焦点环的两条回归（2026-11-21 用户实报）：
/// ① ↑/↓ 移动时列表要跟着滚（不能让蓝框走出视口）；
/// ② 蓝框尺寸与行背景一致（现在环比背景宽 8px——margin 在 FocusRing 内侧）。
void main() {
  void mockWindowManager(WidgetTester tester) {
    const MethodChannel channel = MethodChannel('window_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      MethodCall call,
    ) async {
      return switch (call.method) {
        'isFocused' || 'isMaximized' || 'isFullScreen' => false,
        _ => null,
      };
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
  }

  Future<ProviderContainer> pumpList(
    WidgetTester tester, {
    int count = 40,
  }) async {
    final TestFlutterView view = tester.view;
    view.devicePixelRatio = 1;
    view.physicalSize = const Size(1200, 900);
    addTearDown(() {
      view.devicePixelRatio = 3;
      view.physicalSize = const Size(2400, 1800);
    });
    mockWindowManager(tester);

    final Database db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    final NoteStore store = NoteStore(db);
    final ProviderContainer container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        noteStoreProvider.overrideWithValue(store),
        settingsStoreProvider.overrideWithValue(SettingsStore(db)),
        appDataDirProvider.overrideWithValue(r'C:\test\sinan'),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(db.close);
    for (int i = 0; i < count; i++) {
      store.create(title: '笔记 $i');
    }
    container.read(navHistoryProvider.notifier).selectHome(HomeView.all);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light(), home: const HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('↑/↓ 键盘移动时列表跟着滚（蓝框不出视口）', (tester) async {
    final ProviderContainer container = await pumpList(tester);
    final Finder listScroll = find.descendant(
      of: find.byType(NoteListColumn),
      matching: find.byType(Scrollable),
    );
    final ScrollPosition pos = tester
        .state<ScrollableState>(listScroll)
        .position;
    expect(pos.maxScrollExtent, greaterThan(0), reason: '列表可滚');

    // 点首行建立键盘锚（焦点落在行上，但键盘高亮模式还没开）。
    // 40 篇同毫秒创建 ⇒ 排序按兜底 id，不假设"笔记 0"在最前。
    final List<Note> ordered = container.read(
      homeItemsProvider((view: HomeView.all, tag: null)),
    );
    await tester.tap(find.text(ordered.first.title));
    await tester.pumpAndSettle();

    // 连按 ↓ 走到视口外（40 篇、每行 26px、视口 803 ⇒ 约第 31 篇起超界）：
    // 选中走到深层行时列表必须跟着滚，不能让蓝框走出视口。
    for (int i = 0; i < 35; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    final String? selectedAfter = container.read(selectedNoteIdProvider);
    final int idx = ordered.indexWhere((Note n) => n.id == selectedAfter);
    // 先钉"导航是否真的前进"——区分「导航没触发」与「导航触发但没滚」。
    expect(idx, greaterThanOrEqualTo(30), reason: '↓ 35 次应选中靠后的笔记');
    expect(pos.pixels, greaterThan(0), reason: '键盘走到视口外的行，列表必须跟着滚（不能让蓝框停在原地）');
  });

  testWidgets('按住 ↑ 不放能一路走到顶（不被滚动动画卡住）', (tester) async {
    // 2026-11-21 用户实报：单次按正常，**按住不放**从下往上会在中间停住、再也
    // 按不动。怀疑：键盘连发比滚动动画快 ⇒ 目标行被甩出 cacheExtent 卸载 ⇒
    // 焦点丢失（行 FocusNode 随 State dispose），后续按键没人接。
    // 200 行：连发时选中前进得比滚动动画快，目标行会被甩出 cacheExtent
    // （40 行太矮，整列都在 cache 里，复现不出用户的现象）。
    final ProviderContainer container = await pumpList(tester, count: 200);
    final Finder listScroll = find.descendant(
      of: find.byType(NoteListColumn),
      matching: find.byType(Scrollable),
    );
    final ScrollPosition pos = tester
        .state<ScrollableState>(listScroll)
        .position;
    final List<Note> ordered = container.read(
      homeItemsProvider((view: HomeView.all, tag: null)),
    );

    // 先滚到底部，点最后一行建立焦点（模拟用户从下往上）。
    pos.jumpTo(pos.maxScrollExtent);
    await tester.pumpAndSettle();
    await tester.tap(find.text(ordered.last.title));
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteIdProvider), ordered.last.id);

    // 按住 ↑：按下 + 多次 repeat，每次只推 1ms（滚动动画 nowhere near 跑完）。
    // 真实 key repeat ≈30ms/次、动画 150ms，量级一致。
    final Rect viewRect = tester.getRect(listScroll);
    int prevIdx = ordered.length - 1;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
    for (int i = 0; i < 40; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowUp);
      // 两帧：第 1 帧跑 didUpdateWidget→post-frame reveal（duration 0 的
      // jumpTo），第 2 帧让新偏移真正布局出来（否则目标行还停在旧位置）。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));

      // 每次连发后：① 选中必须**前进**（不能停在原地="按不动"）；
      // ② 选中行必须仍在视口内（否则蓝框消失，用户以为卡住）。
      final String? id = container.read(selectedNoteIdProvider);
      final int idx = ordered.indexWhere((Note n) => n.id == id);
      expect(idx, lessThan(prevIdx), reason: '第 $i 次连发：选中必须继续向上（不能停在原地）');
      prevIdx = idx;

      // 限定在列表列内：编辑器标题行也可能有同名 Text（点行会打开详情）。
      final Finder rowFinder = find.descendant(
        of: find.byType(NoteListColumn),
        matching: find.text(ordered[idx].title),
      );
      expect(
        rowFinder,
        findsOneWidget,
        reason: '第 $i 次连发：选中行 idx=$idx 必须在列表内（滚跟上了才会有）',
      );
      final Rect rowRect = tester.getRect(rowFinder);
      expect(
        rowRect.top >= viewRect.top - 1 &&
            rowRect.bottom <= viewRect.bottom + 1,
        isTrue,
        reason: '第 $i 次连发：选中行必须在视口内（蓝框不能消失）',
      );
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(prevIdx, lessThanOrEqualTo(ordered.length - 41));
  });

  testWidgets('蓝框尺寸与行背景一致', (tester) async {
    await pumpList(tester, count: 3);

    // 找到首行的 FocusRing 与它内部的背景 Container（有 BoxDecoration + 圆角）。
    final Finder title = find.text('笔记 0');
    final Finder ring = find.ancestor(
      of: title,
      matching: find.byType(FocusRing),
    );
    final Rect ringRect = tester.getRect(ring);
    final Finder bg = find.descendant(
      of: ring,
      matching: find.byWidgetPredicate(
        (Widget w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).borderRadius != null,
      ),
    );
    expect(bg, findsWidgets);
    final Rect bgRect = tester.getRect(bg.first);
    expect(
      ringRect.width,
      closeTo(bgRect.width, 1),
      reason: '蓝框宽度应与行背景一致（现在 margin 让环宽 8px）',
    );
    expect(ringRect.height, closeTo(bgRect.height, 1), reason: '蓝框高度应与行背景一致');
  });
}
