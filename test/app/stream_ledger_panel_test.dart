import 'package:flutter/services.dart'
    show LogicalKeyboardKey, MethodCall, MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/app/settings_panel.dart' show appNavigatorKey;
import 'package:sinan/src/app/stream_view.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/data/stream_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// **已处理浮层（处理台账）**的回归（2026-10-18 定稿）。
///
/// 钉五件事：
/// ① 它是**浮层不是页面**——背后灵感页原样在，导航历史不被占；
/// ② Esc / × / 点外面都能关；
/// ③ 全貌正文不截断；
/// ④ 点流向**带着块 id** 跳过去（P2 双链的实质）；
/// ⑤ 删除后条目进回收站。
void main() {
  late Database db;
  late NoteStore store;
  late StreamStore stream;
  late ProviderContainer container;

  void seed(String id, String text, DateTime at, {bool archived = false}) {
    db.execute(
      'INSERT INTO stream_items (id, text, created_at, updated_at, archived_at) '
      'VALUES (?, ?, ?, ?, ?)',
      <Object?>[
        id,
        text,
        at.millisecondsSinceEpoch,
        at.millisecondsSinceEpoch,
        archived ? at.millisecondsSinceEpoch : null,
      ],
    );
  }

  /// 挂一个能弹台账的最小宿主：面板从 `appNavigatorKey` 的 Overlay 取出，
  /// 所以 MaterialApp 必须带上这个 key（设置面板测试同一招）。
  Future<void> pumpStream(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: appNavigatorKey,
          theme: AppTheme.light(),
          home: const Scaffold(body: StreamView()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    store = NoteStore(db);
    stream = StreamStore(db);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), (
          MethodCall call,
        ) async => false);
    container = ProviderContainer(
      overrides: [
        noteStoreProvider.overrideWithValue(store),
        settingsStoreProvider.overrideWithValue(SettingsStore(db)),
        appDataDirProvider.overrideWithValue(r'C:\test\sinan'),
        databaseProvider.overrideWithValue(db),
      ],
    );
    addTearDown(() {
      container.dispose();
      db.close();
    });
  });

  Future<void> openLedger(WidgetTester tester) async {
    // 入口是表头那枚「归档 N」（2026-10-18 用户定稿：图标 + 动词，别让用户猜）。
    await tester.tap(find.text('归档 1'));
    await tester.pumpAndSettle();
  }

  testWidgets('浮层不是页面：背后灵感页原样在，导航历史不占', (WidgetTester tester) async {
    final DateTime now = DateTime.now();
    seed('a', '待处理', now);
    seed('b', '已归档', now.subtract(const Duration(days: 1)), archived: true);
    await pumpStream(tester);
    expect(find.text('灵感 1 条'), findsOneWidget, reason: '表头计数灵感 1 条');

    await openLedger(tester);

    expect(find.text('已处理 1 条'), findsOneWidget, reason: '面板标题');
    // 背后灵感页仍在渲染（浮层不换页）。
    expect(find.text('待处理'), findsOneWidget);
    expect(find.bySemanticsLabel('灵感输入，回车记下'), findsOneWidget);
    // 视图没被切走，导航历史也没被占一步。
    expect(container.read(navHistoryProvider).view, HomeView.timeline);
    expect(container.read(navHistoryProvider).canGoBack, isFalse);
  });

  testWidgets('三种关闭：× / Esc / 点卡片外', (WidgetTester tester) async {
    seed('a', '已归档', DateTime.now(), archived: true);
    await pumpStream(tester);

    await openLedger(tester);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('已处理 1 条'), findsNothing);

    await openLedger(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('已处理 1 条'), findsNothing);

    await openLedger(tester);
    // 点卡片外（左上角落，卡片是居中的）。
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.text('已处理 1 条'), findsNothing);
  });

  testWidgets('全貌正文：不点开也看得见，且不截断', (WidgetTester tester) async {
    seed('a', '第一行\n第二行\n第三行\n第四行', DateTime.now(), archived: true);
    await pumpStream(tester);
    await openLedger(tester);

    // 卡片流：打开即见全貌，不需要先点某一条（2026-10-18 用户定稿）。
    expect(find.textContaining('第一行'), findsOneWidget);
    expect(
      tester.widgetList<Text>(find.byType(Text)).map((Text t) => t.maxLines),
      isNot(contains(3)),
      reason: '全貌正文不许 maxLines=3',
    );
    // 每张卡自带「删除」，不必进详情就能操作。
    expect(find.text('删除'), findsOneWidget);
  });

  testWidgets('扫读即见"它变成了什么"：流向带落地内容预览', (WidgetTester tester) async {
    seed('a', '想清楚的那句话', DateTime.now(), archived: true);
    store.streamToNewNote('a');
    await pumpStream(tester);
    await openLedger(tester);

    expect(find.textContaining('笔记《想清楚的那句话》'), findsOneWidget);
    // 落点块的正文就在卡片里，不用点出去（P2 预览）。
    expect(find.textContaining('想清楚的那句话'), findsWidgets);
  });

  testWidgets('P2 双链：点流向带着块 id 跳过去', (WidgetTester tester) async {
    seed('a', '想清楚的那句话', DateTime.now(), archived: true);
    final Note target = store.create(title: '周五的闲聊');
    store.copyStreamIntoNote('a', target.id);
    await pumpStream(tester);
    await openLedger(tester);

    final StreamExport export = store.allStreamExports()['a']!.single;
    await tester.tap(find.textContaining('笔记《周五的闲聊》'));
    await tester.pumpAndSettle();

    final LocateRequest? request = container.read(locateProvider);
    expect(request!.noteId, target.id);
    expect(
      request.blockId,
      export.targetBlockId,
      reason: 'P2：定位到导出时写入的那个块（ref 块），不是只跳笔记',
    );
    // 跳转前面板已关（否则打不开目标）。
    expect(find.text('已处理 1 条'), findsNothing);
  });

  testWidgets('删除：条目进回收站，浮层里消失', (WidgetTester tester) async {
    seed('a', '待处理', DateTime.now());
    seed('b', '已归档的那条', DateTime.now(), archived: true);
    await pumpStream(tester);

    await openLedger(tester);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    // 确认框：点实色确认按钮（标题与按钮同名，用 FilledButton 精确定位）。
    await tester.tap(find.widgetWithText(FilledButton, '移入回收站'));
    await tester.pumpAndSettle();

    expect(stream.byId('b'), isNull, reason: '软删后不再正向可读');
    expect(stream.listTrash().map((i) => i.id), contains('b'));
    expect(find.text('还没有已处理的灵感'), findsOneWidget);
  });
}
