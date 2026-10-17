import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/app/stream_view.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/data/stream_store.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// 速记（心流）界面 2026-10-17 P1：
/// 按日分组的时间流、心流内搜索、已处理折叠区、多选合并、Enter 即录。
void main() {
  late Database db;
  late NoteStore store;
  late StreamStore stream;
  late ProviderContainer container;

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    store = NoteStore(db);
    stream = StreamStore(db);
    container = ProviderContainer(
      overrides: [
        noteStoreProvider.overrideWithValue(store),
        settingsStoreProvider.overrideWithValue(SettingsStore(db)),
        appDataDirProvider.overrideWithValue('C:\\test\\sinan'),
        databaseProvider.overrideWithValue(db),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    db.close();
  });

  /// 直接插行以便钉住 `created_at`（分组与合并顺序都靠它）。
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

  Future<void> pumpView(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: StreamView()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('按日分组：今天 / 昨天各一个组标', (WidgetTester tester) async {
    final DateTime now = DateTime.now();
    seed('a', '今天的想法', now);
    seed('b', '昨天的想法', now.subtract(const Duration(days: 1)));
    await pumpView(tester);

    expect(find.text('今天'), findsOneWidget);
    expect(find.text('昨天'), findsOneWidget);
    expect(find.text('今天的想法'), findsOneWidget);
    expect(find.text('昨天的想法'), findsOneWidget);
  });

  testWidgets('心流内搜索：即时过滤，不命中给"没有匹配"', (WidgetTester tester) async {
    final DateTime now = DateTime.now();
    seed('a', '今天的想法', now);
    seed('b', '昨天的想法', now.subtract(const Duration(days: 1)));
    await pumpView(tester);

    // 搜索**常驻**在列表头（Apple 备忘录 / Bear 口径）：第一个输入框是捕获条，
    // 第二个就是列表头的搜索框，直接输入即可。
    await tester.enterText(find.byType(TextField).at(1), '昨天');
    await tester.pumpAndSettle();
    expect(find.text('今天的想法'), findsNothing);
    expect(find.text('昨天的想法'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(1), '不存在');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的速记'), findsOneWidget);
  });

  testWidgets('已处理：默认不显示，点开关后露出', (WidgetTester tester) async {
    final DateTime now = DateTime.now();
    seed('a', '待处理', now);
    seed('b', '已归档', now.subtract(const Duration(days: 2)), archived: true);
    await pumpView(tester);

    expect(find.text('已归档'), findsNothing);
    await tester.tap(find.text('已处理 1 条'));
    await tester.pumpAndSettle();
    expect(find.text('已归档'), findsOneWidget);
  });

  testWidgets('多选合并：勾一条 → 合并为新笔记，条目归档', (WidgetTester tester) async {
    final DateTime now = DateTime.now();
    seed('a', '要合并的想法', now);
    await pumpView(tester);

    // 列表头（2026-10-17）：搜索常驻输入框，选择是文字钮（图标版本实机认不出）。
    expect(find.text('1 条'), findsOneWidget, reason: '列表头只报条数');
    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('要合并的想法'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 条'), findsOneWidget);

    await tester.tap(find.text('合并为新笔记'));
    await tester.pumpAndSettle();

    expect(
      db.select("SELECT id FROM notes WHERE kind = 'note'"),
      hasLength(1),
      reason: '合并要真的建出一篇笔记',
    );
    expect(stream.list(), isEmpty, reason: '参与合并的条目进归档，不再是待处理');
    expect(stream.byId('a')!.archived, isTrue);
    expect(find.text('要合并的想法'), findsNothing);
  });

  testWidgets('聚焦：从引用跳来只显示那一条，可"显示全部"', (WidgetTester tester) async {
    final DateTime now = DateTime.now();
    seed('a', '被引用的那条', now);
    seed('b', '别的速记', now);
    container.read(streamFocusProvider.notifier).focusOn('a');
    await pumpView(tester);

    expect(find.text('正在查看被引用的速记'), findsOneWidget);
    expect(find.text('被引用的那条'), findsOneWidget);
    expect(find.text('别的速记'), findsNothing);

    await tester.tap(find.text('显示全部'));
    await tester.pumpAndSettle();
    expect(find.text('别的速记'), findsOneWidget);
  });

  testWidgets('聚焦到已归档条目：仍然看得见、可拿回', (WidgetTester tester) async {
    seed(
      'b',
      '已归档的被引用条目',
      DateTime.now().subtract(const Duration(days: 1)),
      archived: true,
    );
    container.read(streamFocusProvider.notifier).focusOn('b');
    await pumpView(tester);

    expect(find.text('已归档的被引用条目'), findsOneWidget);
    expect(find.text('拿回'), findsOneWidget);
    expect(find.text('已处理 1 条'), findsNothing, reason: '聚焦时不再给折叠行');
  });

  testWidgets('归档不是死路：只剩已处理时折叠行仍在、能展开', (WidgetTester tester) async {
    seed(
      'b',
      '已归档的那条',
      DateTime.now().subtract(const Duration(days: 1)),
      archived: true,
    );
    await pumpView(tester);

    // 待处理 0 条 + 归档 1 条：不能再被空态吞掉（2026-10-17 复查的 P0）。
    expect(find.text('还没有灵感'), findsNothing);
    expect(find.text('已处理 1 条'), findsOneWidget);
    await tester.tap(find.text('已处理 1 条'));
    await tester.pumpAndSettle();
    expect(find.text('已归档的那条'), findsOneWidget);
  });

  testWidgets('编辑清空：提示"速记不能为空"，不改原文', (WidgetTester tester) async {
    seed('a', '原文', DateTime.now());
    await pumpView(tester);

    await tester.tap(find.text('原文'));
    await tester.pumpAndSettle();
    // 捕获条(0) / 搜索框(1) / 行内编辑框(2)
    await tester.enterText(find.byType(TextField).at(2), '');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(find.text('速记不能为空'), findsOneWidget);
    expect(stream.byId('a')!.text, '原文', reason: '空文本不该落库');
  });

  testWidgets('选择模式下归档条目不可勾选', (WidgetTester tester) async {
    final DateTime now = DateTime.now();
    seed('a', '待处理', now);
    seed('b', '已归档', now.subtract(const Duration(days: 1)), archived: true);
    await pumpView(tester);

    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已处理 1 条'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已归档'));
    await tester.pumpAndSettle();

    expect(
      find.text('选择要合并的速记'),
      findsOneWidget,
      reason: '归档条目不该进合并池',
    );
  });

  testWidgets('hover 操作簇不挤动正文（占位固定）', (WidgetTester tester) async {
    const String text = '这一行足够长，用来量宽度是否会被悬浮出现的三枚图标挤动';
    seed('a', text, DateTime.now());
    await pumpView(tester);

    final Size before = tester.getSize(find.text(text));
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text(text)));
    await tester.pumpAndSettle();

    // 操作簇确实出现了……
    expect(find.byTooltip('归档（已处理）'), findsOneWidget);
    // ……但正文宽度一点没变（92 的占位是常驻的，只是"填不填内容"）。
    expect(tester.getSize(find.text(text)).width, before.width);
  });

  testWidgets('空库：邀请文案 + 输入条常驻', (WidgetTester tester) async {
    await pumpView(tester);
    expect(find.text('还没有灵感'), findsOneWidget);
    expect(find.text('按 Ctrl+Shift+M 随时记一条，或在上面写第一句'), findsOneWidget);
    expect(find.text('记下此刻的想法…'), findsOneWidget, reason: '输入框常驻，空库也能写');
  });

  testWidgets('单向：笔记绝不漏进速记页', (WidgetTester tester) async {
    // 文库里的甲 / 乙（普通笔记）与速记是两条数据线，速记页只读 `stream_items`。
    store.create(title: '甲');
    store.create(title: '乙');
    seed('a', '一条速记', DateTime.now());
    await pumpView(tester);

    expect(find.text('一条速记'), findsOneWidget);
    expect(find.text('甲'), findsNothing, reason: '速记不读笔记数据（单向）');
    expect(find.text('乙'), findsNothing);
  });

  test('版式闸门：心流页零投影 / 零模糊 / 零 Opacity（Bauhaus 口径）', () {
    final String src = File('lib/src/app/stream_view.dart').readAsStringSync();
    expect(src.contains('BoxShadow'), isFalse, reason: '全站零投影：浮起靠边线与留白');
    expect(src.contains('BackdropFilter'), isFalse);
    expect(RegExp(r'\bOpacity\(').hasMatch(src), isFalse, reason: 'Opacity 会触发 saveLayer');
  });

  testWidgets('输入条：Enter 即落库（不跳页）', (WidgetTester tester) async {
    await pumpView(tester);
    await tester.enterText(find.byType(TextField).first, '刚想到的一句');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(stream.list().map((i) => i.text), contains('刚想到的一句'));
    expect(find.text('刚想到的一句'), findsOneWidget);
  });
}
