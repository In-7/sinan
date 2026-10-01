import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/app/search_palette.dart';
import 'package:sinan/src/app/search_provider.dart';
import 'package:sinan/src/app/settings_panel.dart' show appNavigatorKey;
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/theme/app_theme.dart';
// 只取 Database / sqlite3：sqlite3 还导出一个 `Row`，与 Flutter 的 Row 撞名。
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// **Ctrl+K 全局搜索浮层**（[SearchPalette]）的回归。
///
/// 与主页内搜索共用 [searchAllNotes] 核心（相关口径的测试在
/// home_hub_test / search_test 里），这里只钉浮层自己的交互：
/// ① 打开即"最近编辑"，不必先打字；
/// ② 输入 250ms 去抖后按标题过滤；无匹配给明确空态；
/// ③ 全程键盘：↓ 移动选中、Enter 跳转（走 locateProvider）并关闭；
/// ④ 浮层浏览时是**即用即走**：不写 searchNotifierProvider（主页查询词不受污染）；
/// ⑤ 唯一例外是**交接**（底部行 / Shift+Enter）：关浮层、回主页、把词灌进
///    页内搜索，铺开全部结果。
/// 有界轮询等**异步检索结果落帧**（500ms 上限）。
///
/// 浮层检索走 FFI（sqlite3）+ 250ms 去抖，全量回归高负载时固定 pump 两三帧
/// 未必等到续体；又因为输入框光标持续闪烁，pumpAndSettle 会永久挂起——只能
/// 显式推进时间并轮询目标 widget。
///
/// ⚠️ **不能等"最近编辑"里本来就有的词**（如某篇标题）：浮层一打开就铺最近
/// 8 篇，finder 会在搜索结果回来**之前**命中旧列表，随后结果 setState 把
/// `_selected` 重置为 0（全量回归负载下实测：↓ 像没生效一样跳了第一项）。
/// 等一个**只有搜索结果态才成立**的条件（如非命中项消失）。
Future<void> pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (condition()) return;
  }
  fail('检索结果未在 500ms 内落帧（条件未成立）');
}

void main() {
  late Database db;
  late NoteStore notes;
  late SettingsStore settings;

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    notes = NoteStore(db);
    settings = SettingsStore(db);
  });

  tearDown(() {
    // 单例守卫兜底：用例失败/中断时浮层可能没走正常关闭，否则同进程后续
    // 用例（包括本文件重跑）将永远打不开浮层。
    debugResetSearchPaletteGuard();
    db.close();
  });

  /// 卸下树：浮层在 initState 装了**全局键盘旁观者**，且聚焦输入框的光标
  /// 闪烁会挂周期帧——不卸干净会漏到下一个用例（命令面板测试同此做法）。
  Future<void> unmount(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox.shrink());

  ProviderContainer newContainer() => ProviderContainer(
    overrides: [
      noteStoreProvider.overrideWithValue(notes),
      settingsStoreProvider.overrideWithValue(settings),
      appDataDirProvider.overrideWithValue(r'C:\test\sinan'),
      databaseProvider.overrideWithValue(db),
    ],
  );

  testWidgets('空查询列最近编辑；标题过滤、无匹配空态、不污染主页查询态', (WidgetTester tester) async {
    final ProviderContainer container = newContainer();
    addTearDown(container.dispose);
    Future<void> titled(String t, {bool canvas = false}) async {
      final Note n = await container
          .read(notesProvider.notifier)
          .createNote(kind: canvas ? NoteKind.canvas : NoteKind.spark);
      await container.read(notesProvider.notifier).saveTitle(n.id, t);
    }

    await titled('甲笔记');
    await titled('乙笔记');
    await titled('画布稿', canvas: true);

    bool closed = false;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(child: SearchPalette(onClose: () => closed = true)),
          ),
        ),
      ),
    );
    // ⚠️ 不能用 pumpAndSettle：聚焦的 TextField 光标闪烁周期性调度帧，
    // settle 会永久挂起（命令面板测试同此坑）——一律显式 pump。
    await tester.pump();

    // ① 打开即三篇最近（跨形态）。
    expect(find.text('甲笔记'), findsOneWidget);
    expect(find.text('乙笔记'), findsOneWidget);
    expect(find.text('画布稿'), findsOneWidget);
    // 主页搜索态没被动过。
    expect(container.read(searchNotifierProvider).query, isEmpty);

    // ② 输入「甲」：去抖后只剩甲。等「画布稿」消失（它在最近列表里，
    //    只有搜索结果态才会被滤掉——不能等甲标题，见 pumpUntil 注释）。
    await tester.enterText(find.byType(TextField), '甲');
    await tester.pump(const Duration(milliseconds: 300));
    await pumpUntil(tester, () => find.text('画布稿').evaluate().isEmpty);
    expect(find.text('甲笔记'), findsOneWidget);
    expect(find.text('乙笔记'), findsNothing);
    expect(find.text('画布稿'), findsNothing);
    expect(
      container.read(searchNotifierProvider).query,
      isEmpty,
      reason: '浮层不写页内搜索状态',
    );

    // ③ 无匹配空态。
    await tester.enterText(find.byType(TextField), '不存在的词');
    await tester.pump(const Duration(milliseconds: 300));
    await pumpUntil(
      tester,
      () => find.text('没有与「不存在的词」匹配的结果').evaluate().isNotEmpty,
    );
    expect(closed, isFalse);

    await unmount(tester);
  });

  testWidgets('键盘全流程：↓ 选中第二项，Enter 跳转并关闭', (WidgetTester tester) async {
    final ProviderContainer container = newContainer();
    addTearDown(container.dispose);

    final Note first = await container
        .read(notesProvider.notifier)
        .createNote();
    await container.read(notesProvider.notifier).saveTitle(first.id, '甲笔记');
    final Note second = await container
        .read(notesProvider.notifier)
        .createNote();
    await container.read(notesProvider.notifier).saveTitle(second.id, '乙笔记');

    bool closed = false;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(child: SearchPalette(onClose: () => closed = true)),
          ),
        ),
      ),
    );
    // 同坑：光标闪烁 ⇒ 不用 pumpAndSettle。
    await tester.pump();

    // 共同词「笔记」⇒ 标题命中两篇；乙后建、revisedAt 更新，排第一。
    await tester.enterText(find.byType(TextField), '笔记');
    await tester.pump(const Duration(milliseconds: 300));
    // 本例只有两篇且都在最近列表里 ⇒ 不能靠行内容区分；等**交接行**——
    // 它只在搜索结果态（query 非空且 total>0）出现。否则结果 setState
    // 会在 ↓ 之后把选中重置回 0（全量回归负载下实测跳了第一项）。
    await pumpUntil(
      tester,
      () => find.text('在主页显示全部 2 条结果').evaluate().isNotEmpty,
    );
    expect(find.text('乙笔记'), findsOneWidget);

    // ↓ 一次：选中移到甲（方向键走全局 HardwareKeyboard 旁观者，
    // sendKeyEvent 能到——和命令面板测试同一条路）。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    // Enter：真机上由**引擎**把 Enter 翻译成 done 动作再回调 onSubmitted；
    // tester.sendKeyEvent(enter) 只把键送进框架、不会触发（EditableText
    // 官方文档明示），测试必须直接收 done 动作。
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(
      container.read(selectedNoteIdProvider),
      first.id,
      reason: '↓ 后 Enter 必须跳第二项',
    );
    expect(closed, isTrue, reason: '跳转同时关闭浮层');

    await unmount(tester);
  });

  testWidgets('内容命中：副行显示命中片段且查询词高亮', (WidgetTester tester) async {
    final ProviderContainer container = newContainer();
    addTearDown(container.dispose);
    final Note note = await container.read(notesProvider.notifier).createNote();
    await container.read(notesProvider.notifier).saveTitle(note.id, '速记');
    const String body = '今天在会议室聊了量子计算的落地节奏';
    db.execute(
      'INSERT INTO blocks (id, note_id, type, props_json, ord, parent_id, '
      'created_at, updated_at, fingerprint) '
      "VALUES (?, ?, 'paragraph', ?, 1024, NULL, 0, 0, 'fp-test')",
      <Object?>[note.id, note.id, '{"text":"$body"}'],
    );
    IndexJob(db: db).indexNoteKeywordPath(note.id);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: Center(child: SearchPalette(onClose: _noop)),
          ),
        ),
      ),
    );
    // 光标闪烁坑：显式 pump。
    await tester.pump();

    await tester.enterText(find.byType(TextField), '量子计算');
    await tester.pump(const Duration(milliseconds: 300));

    final Finder snippetRich = find.byWidgetPredicate((Widget w) {
      if (w is! RichText) return false;
      return w.text.toPlainText().contains('量子计算') &&
          w.text.toPlainText().contains('会议室');
    });
    await pumpUntil(tester, () => snippetRich.evaluate().isNotEmpty);
    expect(snippetRich, findsWidgets, reason: '副行是命中块片段');
    bool highlighted = false;
    void walk(InlineSpan span) {
      if (span is TextSpan) {
        if (span.text == '量子计算' && span.style?.fontWeight == FontWeight.w700) {
          highlighted = true;
        }
        span.children?.forEach(walk);
      }
    }

    for (final Element e in snippetRich.evaluate()) {
      walk((e.widget as RichText).text);
    }
    expect(highlighted, isTrue, reason: '命中词披主题色加粗');

    await unmount(tester);
  });

  testWidgets('showSearchPalette：单例浮层，Esc 关闭', (WidgetTester tester) async {
    final ProviderContainer container = newContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: appNavigatorKey,
          theme: AppTheme.light(),
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    // 空 Scaffold 无动画，首次挂载可 settle；浮层打开后（聚焦输入框）只能 pump。
    await tester.pump();

    // ⚠️ 不能 await：showSearchPalette 返回的是"**关闭**"Future（浮层关掉才
    // complete），await 会把用例永久挂起、永远到不了下面的 Esc。生产里命令
    // 回调同样是 fire-and-forget（见 GlobalSearchButton / commands.dart）。
    unawaited(showSearchPalette());
    // 再调一次不叠层（单例守卫）。
    unawaited(showSearchPalette());
    // OverlayEntry 在调用当帧同步插入，首帧构建后浮层才在树里。
    await tester.pump();
    expect(find.byType(SearchPalette), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump();
    expect(find.byType(SearchPalette), findsNothing);
  });

  testWidgets('交接行（鼠标）：关浮层、离开编辑器回主页、查询词灌进页内搜索', (WidgetTester tester) async {
    final ProviderContainer container = newContainer();
    addTearDown(container.dispose);

    final Note first = await container
        .read(notesProvider.notifier)
        .createNote();
    await container.read(notesProvider.notifier).saveTitle(first.id, '甲笔记');
    final Note second = await container
        .read(notesProvider.notifier)
        .createNote();
    await container.read(notesProvider.notifier).saveTitle(second.id, '乙笔记');

    // 模拟"在编辑器里写到一半唤起浮层"。
    container.read(locateProvider.notifier).locate(noteId: first.id);
    expect(container.read(selectedNoteIdProvider), first.id);

    bool closed = false;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(child: SearchPalette(onClose: () => closed = true)),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), '笔记');
    await tester.pump(const Duration(milliseconds: 300));

    // 交接行带**全部**命中数（浮层列表本身只显示前 8 行）。
    final Finder footer = find.text('在主页显示全部 2 条结果');
    await pumpUntil(tester, () => footer.evaluate().isNotEmpty);

    await tester.tap(footer);
    await tester.pump();

    expect(closed, isTrue, reason: '交接即关浮层');
    expect(container.read(selectedNoteIdProvider), isNull, reason: '已离开编辑器');
    expect(container.read(navHistoryProvider).view, HomeView.all);
    expect(
      container.read(searchNotifierProvider).query,
      '笔记',
      reason: '词灌进页内搜索，主页铺开全部结果',
    );

    // submit 在页内 notifier 里起了 250ms 去抖 + 异步检索：放完再收摊，
    // 否则挂起的定时器会让用例末尾的 !timersPending 断言失败。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.pump();

    await unmount(tester);
  });

  testWidgets('交接（Shift+Enter 键盘）：关浮层并灌词，但不跳转笔记', (WidgetTester tester) async {
    final ProviderContainer container = newContainer();
    addTearDown(container.dispose);

    final Note note = await container.read(notesProvider.notifier).createNote();
    await container.read(notesProvider.notifier).saveTitle(note.id, '甲笔记');

    bool closed = false;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(child: SearchPalette(onClose: () => closed = true)),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), '笔记');
    await tester.pump(const Duration(milliseconds: 300));
    await pumpUntil(
      tester,
      () => find.text('在主页显示全部 1 条结果').evaluate().isNotEmpty,
    );

    // ⚠️ sendKeyEvent 的 isShiftPressed 不会把 shift 压进 HardwareKeyboard
    // 的按下表（修饰标志是合成的），必须真实地下压 / 抬起 Shift 键。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(closed, isTrue);
    expect(
      container.read(searchNotifierProvider).query,
      '笔记',
      reason: 'Shift+Enter = 交接给页内搜索',
    );
    expect(
      container.read(selectedNoteIdProvider),
      isNull,
      reason: '交接不是跳转：不该打开首条命中',
    );

    // 同上：放完页内搜索的去抖定时器再收摊。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.pump();

    await unmount(tester);
  });
}

void _noop() {}
