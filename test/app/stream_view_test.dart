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
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// 灵感界面 2026-10-17 P1：
/// 按日分组的时间流、灵感内搜索、已处理折叠区、多选合并、Enter 即录。
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

  testWidgets('灵感内搜索：即时过滤，不命中给"没有匹配"', (WidgetTester tester) async {
    final DateTime now = DateTime.now();
    seed('a', '今天的想法', now);
    seed('b', '昨天的想法', now.subtract(const Duration(days: 1)));
    await pumpView(tester);

    // 搜索**常驻**在列表头（Apple 备忘录 / Bear 口径）。2026-10-18 起工具栏
    // 挪到输入框之上 ⇒ 树里第一个输入框就是搜索框。
    await tester.enterText(find.byType(TextField).at(0), '昨天');
    await tester.pumpAndSettle();
    expect(find.text('今天的想法'), findsNothing);
    expect(find.text('昨天的想法'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), '不存在');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的灵感'), findsOneWidget);
  });

  testWidgets('已处理：默认不显示，点表头计数跳到台账页', (WidgetTester tester) async {
    final DateTime now = DateTime.now();
    seed('a', '待处理', now);
    seed('b', '已归档', now.subtract(const Duration(days: 2)), archived: true);
    await pumpView(tester);

    expect(find.text('已归档'), findsNothing);
    // 计数是入口；归档走**浮层**（2026-10-18 定稿：低频功能，不换页、不占导航）。
    // 本文件只挂 StreamView（没有 appNavigatorKey 的宿主）⇒ 这里只验证"流里不留"。
    // 浮层本身的开/关/跳转由 stream_ledger_panel_test.dart 钉。
    expect(find.text('灵感 1 条'), findsOneWidget);
  });

  testWidgets('多选合并：勾一条 → 合并为新笔记，条目仍留在灵感（不归档）', (
    WidgetTester tester,
  ) async {
    final DateTime now = DateTime.now();
    seed('a', '要合并的想法', now);
    await pumpView(tester);

    // 列表头（2026-10-17）：搜索常驻输入框，选择是文字钮（图标版本实机认不出）。
    expect(find.text('灵感 1 条'), findsOneWidget, reason: '列表头报灵感条数');
    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('要合并的想法'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 / 1 条'), findsOneWidget);

    await tester.tap(find.text('合并为新笔记'));
    await tester.pumpAndSettle();

    expect(
      db.select("SELECT id FROM notes WHERE kind = 'note'"),
      hasLength(1),
      reason: '合并要真的建出一篇笔记',
    );
    // 合并只是"整理"，不算使用 ⇒ **不归档**，条目仍留在灵感（2026-10-18 用户定）。
    expect(stream.list(), hasLength(1), reason: '合并后条目仍待处理');
    expect(stream.byId('a')!.archived, isFalse);
    expect(find.text('要合并的想法'), findsOneWidget);
  });

  testWidgets('聚焦：从引用跳来只显示那一条，可"显示全部"', (WidgetTester tester) async {
    final DateTime now = DateTime.now();
    seed('a', '被引用的那条', now);
    seed('b', '别的灵感', now);
    container.read(streamFocusProvider.notifier).focusOn('a');
    await pumpView(tester);

    expect(find.text('正在查看被引用的灵感'), findsOneWidget);
    expect(find.text('被引用的那条'), findsOneWidget);
    expect(find.text('别的灵感'), findsNothing);

    await tester.tap(find.text('显示全部'));
    await tester.pumpAndSettle();
    expect(find.text('别的灵感'), findsOneWidget);
  });

  testWidgets('聚焦到已归档条目：仍然看得见、可删除（进回收站）', (WidgetTester tester) async {
    seed(
      'b',
      '已归档的被引用条目',
      DateTime.now().subtract(const Duration(days: 1)),
      archived: true,
    );
    container.read(streamFocusProvider.notifier).focusOn('b');
    await pumpView(tester);

    expect(find.text('已归档的被引用条目'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(find.text('正在查看被引用的灵感'), findsOneWidget);
  });

  testWidgets('归档不是死路：只剩已处理时入口仍在、能跳过去', (WidgetTester tester) async {
    seed(
      'b',
      '已归档的那条',
      DateTime.now().subtract(const Duration(days: 1)),
      archived: true,
    );
    await pumpView(tester);

    // 待处理 0 条 + 归档 1 条：不能再被空态吞掉（2026-10-17 复查的 P0）。
    expect(find.text('还没有灵感'), findsNothing);
    expect(find.text('待处理清空了'), findsOneWidget, reason: '清空 ≠ 没开始');
    // 入口仍在：图标 + 「归档 N」（点它弹台账浮层，见 stream_ledger_panel_test.dart）。
    expect(find.text('归档 1'), findsOneWidget);
  });

  testWidgets('编辑清空：提示"灵感不能为空"，不改原文', (WidgetTester tester) async {
    seed('a', '原文', DateTime.now());
    await pumpView(tester);

    await tester.tap(find.text('原文'));
    await tester.pumpAndSettle();
    // 搜索框(0，工具栏在输入框之上) / 捕获条(1) / 行内编辑框(2)
    await tester.enterText(find.byType(TextField).at(2), '');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(find.text('灵感不能为空'), findsOneWidget);
    expect(stream.byId('a')!.text, '原文', reason: '空文本不该落库');
  });

  testWidgets('多选只看待处理：勾选框不落在已处理上', (WidgetTester tester) async {
    final DateTime now = DateTime.now();
    seed('a', '待处理', now);
    seed('b', '已归档', now.subtract(const Duration(days: 1)), archived: true);
    await pumpView(tester);

    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();

    expect(find.text('选择灵感'), findsOneWidget);
    // 流里只剩下待处理的那条，已处理的不在合并池里（它在浮层里）。
    expect(find.text('已归档'), findsNothing);
    expect(find.text('待处理'), findsOneWidget);
  });

  testWidgets('hover 操作簇不挤动正文（占位固定）', (WidgetTester tester) async {
    const String text = '这一行足够长，用来量宽度是否会被悬浮出现的图标挤动';
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

    // 操作簇确实出现了（复制 / 更多两枚；归档改为自动，不再有手动钮）……
    expect(find.byTooltip('复制'), findsOneWidget);
    expect(find.byTooltip('归档（已处理）'), findsNothing);
    // ……但正文宽度一点没变（62 的占位是常驻的，只是"填不填内容"）。
    expect(tester.getSize(find.text(text)).width, before.width);
  });

  testWidgets('空库：邀请文案 + 输入条常驻', (WidgetTester tester) async {
    await pumpView(tester);
    expect(find.text('还没有灵感'), findsOneWidget);
    expect(find.text('按 Ctrl+Shift+M 随时记一条，或在上面写第一句'), findsOneWidget);
    expect(find.text('记下此刻的想法…'), findsOneWidget, reason: '输入框常驻，空库也能写');
  });

  testWidgets('单向：笔记绝不漏进灵感页', (WidgetTester tester) async {
    // 文库里的甲 / 乙（普通笔记）与灵感是两条数据线，灵感页只读 `stream_items`。
    store.create(title: '甲');
    store.create(title: '乙');
    seed('a', '一条灵感', DateTime.now());
    await pumpView(tester);

    expect(find.text('一条灵感'), findsOneWidget);
    expect(find.text('甲'), findsNothing, reason: '灵感不读笔记数据（单向）');
    expect(find.text('乙'), findsNothing);
  });

  test('版式闸门：灵感页零投影 / 零模糊 / 零 Opacity（Bauhaus 口径）', () {
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

  testWidgets('贴图入口：单枚图钉按钮，不再有来源子菜单', (WidgetTester tester) async {
    await pumpView(tester);
    // 用户要最简：图钉就是直接开系统文件框（默认桌面），不再弹
    // 「选文件 / 粘贴剪贴板」的来源选择器；截图走输入框里的 Ctrl+V。
    expect(find.byTooltip('贴图片'), findsOneWidget);
    expect(find.text('选择图片文件…'), findsNothing);
    expect(find.text('粘贴剪贴板图片'), findsNothing);
  });

  testWidgets('全选：只选当前可见（搜索过滤后的）条目', (WidgetTester tester) async {
    final DateTime now = DateTime.now();
    seed('a', '苹果 想法', now);
    seed('b', '香蕉 想法', now.subtract(const Duration(seconds: 1)));
    await pumpView(tester);

    // 搜索到只剩一条（选择模式的候选 = open 过滤结果）。
    await tester.enterText(find.byType(TextField).at(0), '苹果');
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();

    expect(find.text('已选 1 / 1 条'), findsOneWidget);
    expect(find.text('取消全选'), findsOneWidget);
  });

  testWidgets('页头：搜索框/占位符/归档/选择 中心线一致（28 高）', (
    WidgetTester tester,
  ) async {
    seed('a', '一条', DateTime.now());
    seed('b', '归档的', DateTime.now(), archived: true);
    await pumpView(tester);

    final Rect search = tester.getRect(find.byType(TextField).at(0));
    final Rect hint = tester.getRect(find.text('搜索'));
    final Rect arch = tester.getRect(find.text('归档 1'));
    final Rect sel = tester.getRect(find.text('选择'));

    // 主题 `inputDecorationTheme` 会用 OutlineInputBorder 兜底 enabled/focused；
    // 必须显式 none，否则会画出"第二个搜索框"（2026-10-20 实报）。
    final TextField field = tester.widget<TextField>(
      find.byType(TextField).at(0),
    );
    expect(field.decoration?.enabledBorder, InputBorder.none);
    expect(field.decoration?.focusedBorder, InputBorder.none);

    final Rect editable = tester.getRect(find.byType(EditableText).first);
    expect(
      editable.center.dy,
      closeTo(search.center.dy, 1.0),
      reason: '输入行垂直居中（不能顶到上沿）',
    );
    expect(
      editable.center.dy,
      closeTo(hint.center.dy, 1.0),
      reason: '输入行与占位符对齐',
    );

    expect(search.height, 28, reason: '搜索框与按钮同高');
    expect(hint.center.dy, closeTo(search.center.dy, 0.5), reason: '占位符居中');
    expect(arch.center.dy, closeTo(search.center.dy, 0.5), reason: '归档标签对齐');
    expect(sel.center.dy, closeTo(search.center.dy, 0.5), reason: '选择标签对齐');

    final Rect count = tester.getRect(find.text('灵感 1 条'));
    expect(arch.center.dx, lessThan(search.center.dx), reason: '归档在最左');
    expect(search.center.dx, lessThan(count.center.dx),
        reason: '搜索框在归档右侧');
    expect(count.center.dx, lessThan(sel.center.dx),
        reason: '灵感计数在最右、「选择」更右');
  });

  testWidgets('搜索时归档入口不消失（计数用归档总数）', (
    WidgetTester tester,
  ) async {
    seed('a', '一条', DateTime.now());
    seed('b', '归档的', DateTime.now(), archived: true);
    await pumpView(tester);

    expect(find.text('归档 1'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), '一条');
    await tester.pump();

    expect(
      find.text('归档 1'),
      findsOneWidget,
      reason: '归档入口不参与搜索过滤，不能因为搜不到归档条目就消失',
    );
  });

  testWidgets('批量删除：确认后进回收站，主列表清空', (WidgetTester tester) async {
    final DateTime now = DateTime.now();
    seed('a', '第一条', now);
    seed('b', '第二条', now.subtract(const Duration(seconds: 1)));
    await pumpView(tester);

    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 / 2 条'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    // 确认框：点实色确认按钮（标题与按钮同名，用 FilledButton 精确定位）。
    await tester.tap(find.widgetWithText(FilledButton, '移入回收站'));
    await tester.pumpAndSettle();

    expect(stream.list(), isEmpty, reason: '两条都软删');
    expect(stream.listTrash(), hasLength(2), reason: '进回收站而不是硬删');
  });

  test('回收站：软删 → 恢复 → 彻底删除', () {
    final String a = stream.add('要删的')!.id;
    final String b = stream.add('要留的')!.id;
    expect(stream.list().map((i) => i.id), containsAll(<String>[a, b]));

    expect(stream.trash(a), isTrue);
    expect(stream.byId(a), isNull, reason: '回收站不参与正向读取');
    expect(stream.list().map((i) => i.id), <String>[b]);
    expect(stream.listTrash().map((i) => i.id), <String>[a]);

    expect(stream.restore(a), isTrue);
    expect(stream.listTrash(), isEmpty);
    expect(stream.list().map((i) => i.id), containsAll(<String>[a, b]));

    expect(stream.trashMany(<String>[a, b]), isTrue);
    expect(stream.listTrash(), hasLength(2));
    expect(stream.removeMany(<String>[a, b]), isTrue);
    expect(stream.listTrash(), isEmpty);
    expect(stream.byId(a), isNull);
  });

  test('使用即归档：复制到笔记 / 复制到画布后，源灵感自动进归档', () {
    // 先用一条灵感建出合法的文档目标（createSpark 的默认 content 不是块树）。
    final Note target = store.streamToNewNote(stream.add('目标笔记内容')!.id)!;
    final Note canvas = store.streamToNewCanvas(stream.add('目标画布内容')!.id)!;

    final String copied = stream.add('要复制到笔记的')!.id;
    expect(store.copyStreamIntoNote(copied, target.id), isTrue);
    expect(stream.byId(copied)!.archived, isTrue, reason: '复制=使用，应自动归档');

    final String onCanvas = stream.add('要复制到画布的')!.id;
    expect(store.copyStreamOntoCanvas(onCanvas, canvas.id), isTrue);
    expect(stream.byId(onCanvas)!.archived, isTrue, reason: '复制到画布=使用，应自动归档');
  });
}
