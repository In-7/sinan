import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/home_hub.dart'
    show homeItemsProvider, homeKindFacetProvider;
import 'package:sinan/src/app/home_screen.dart';
import 'package:sinan/src/app/note_list_column.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/theme/app_theme.dart';
// 只取 Database / sqlite3：sqlite3 还导出一个 `Row`，与 Flutter 的 Row 撞名。
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// 笔记列表列的 **↑/↓ 键盘选**（2026-10-17 用户定；曾两度触雷回退，此测试钉住）。
///
/// 钉四条：
/// ① 点行 → 开（走 [locateProvider]，入历史）；
/// ② ↑/↓ → 预览切上/下一篇（[LocateNotifier.preview]：**不入导航历史**——连续浏览
///    不该把前进/后退栈刷爆，`Alt+←` 一步回到点开前，而不是逐篇回退）；
/// ③ 两端钳制：末行再 ↓ 不动、首行再 ↑ 不动；
/// ④ 列表在宽面（≥ [noteListBreakpoint]）常开——窄窗自动折是另一条断点，此处不混测。
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

  testWidgets('↑/↓ 预览选中（不入历史）+ 点行开 + 两端钳制', (tester) async {
    // dpr 锁 1 ⇒ physical 即 logical；1200 宽 > noteListBreakpoint(1040) ⇒ 列表常开。
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

    // 建三篇（同视图、默认"最近编辑在前"排序 ⇒ 列表顺序由 provider 定；测试自读、
    // 不假设方向，避免同毫秒创建时排序不稳定）。
    store.create(title: '甲');
    store.create(title: '乙');
    store.create(title: '丙');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light(), home: const HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // 列表实际渲染顺序（与列表列同一个 [homeItemsProvider] ⇒ 自洽）。
    final List<Note> ordered = container.read(
      homeItemsProvider((
        view: HomeView.timeline,
        tag: null,
        kind: container.read(homeKindFacetProvider),
      )),
    );
    expect(ordered.length, 3, reason: '三篇都在列表里');
    expect(find.byType(NoteListColumn), findsOneWidget, reason: '宽面列表常开');

    // ① 点首行 → 开（locate：选中 + 入历史；焦点留在**行**上——编辑器不抢，
    //   这样紧接着按 ↑/↓ 能继续在列表里走，见 note_editor_view 的 autoFocus 注释）。
    await tester.tap(find.text(ordered.first.title));
    await tester.pumpAndSettle();
    expect(
      container.read(selectedNoteIdProvider),
      ordered.first.id,
      reason: '点行即开（选中该篇）',
    );
    expect(
      container.read(navHistoryProvider).canGoBack,
      isTrue,
      reason: '点行开笔记 = 一次导航（入历史）',
    );

    // ② ↓ → 下一篇（预览，不入历史）。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      container.read(selectedNoteIdProvider),
      ordered[1].id,
      reason: '↓ 切下一篇',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      container.read(selectedNoteIdProvider),
      ordered[2].id,
      reason: '再 ↓ 切再下一篇',
    );

    // ③ 两端钳制。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      container.read(selectedNoteIdProvider),
      ordered[2].id,
      reason: '末行再 ↓ 不动',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
      container.read(selectedNoteIdProvider),
      ordered[0].id,
      reason: '↑↑ 回首行',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
      container.read(selectedNoteIdProvider),
      ordered[0].id,
      reason: '首行再 ↑ 不动',
    );

    // ②（续）预览不入历史：连按 ↓↑ 之后「上一步」应一步回到点开前的主页空态，
    // 而非逐篇回退（若每篇预览都入栈，这里会落在中间某篇）。
    await tester.tap(find.byTooltip('上一步（Alt+←）'));
    await tester.pumpAndSettle();
    expect(
      container.read(selectedNoteIdProvider),
      isNull,
      reason: '↑/↓ 预览不入历史：上一步直接回主页空态',
    );
    expect(
      container.read(navHistoryProvider).canGoForward,
      isTrue,
      reason: '回退后可在“下一步”重进点开的那篇',
    );
  });
}
