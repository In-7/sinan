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
/// ④ 浮层是**即用即走**：不写 searchNotifierProvider（主页查询词不受污染）。
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

    // ② 输入「甲」：去抖后只剩甲。
    await tester.enterText(find.byType(TextField), '甲');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(); // 放过去抖回调 + 异步检索的续体与重建帧
    await tester.pump();
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
    await tester.pump();
    await tester.pump();
    expect(find.text('没有与「不存在的词」匹配的结果'), findsOneWidget);
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
    await tester.pump();
    await tester.pump();
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
    await tester.pump();
    await tester.pump();

    final Finder snippetRich = find.byWidgetPredicate((Widget w) {
      if (w is! RichText) return false;
      return w.text.toPlainText().contains('量子计算') &&
          w.text.toPlainText().contains('会议室');
    });
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
    // 回调同样是 fire-and-forget（见 GlobalSearchCapsule / commands.dart）。
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
}

void _noop() {}
