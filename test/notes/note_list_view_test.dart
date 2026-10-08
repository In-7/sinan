import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/notes/note_list_view.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/tokens.dart';
import 'package:sqlite3/sqlite3.dart';

/// 列表条目菜单的端到端回归：**重命名 / 收藏 / 删除（含撤销提示）**。
///
/// 两个必须遵守的测试约定（都踩过）：
/// 1. **有界 pump**，别用 `pumpAndSettle`——列表 loading 态里的
///    [CircularProgressIndicator] 是无限动画，`pumpAndSettle` 永不收敛
///    （实测卡满 10 分钟超时）；
/// 2. 点菜单项要用 `tester.runAsync` 包一层：Riverpod 的 future 链在
///    FakeAsync 里不会自己跑完，否则表现为"点了没反应"的假象。
void main() {
  late Database db;
  late ProviderContainer container;
  late Note note;

  setUp(() async {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    container = ProviderContainer(
      overrides: [noteStoreProvider.overrideWithValue(NoteStore(db))],
    );
    // 一条笔记，并选中它（选中时「···」才显形）。
    note = await container.read(notesProvider.notifier).createNote();
    await container.read(notesProvider.notifier).saveTitle(note.id, '原始标题');
    container.read(selectedNoteIdProvider.notifier).select(note.id);
    // 先把首次装载走完：进 UI 时不会停在 loading 态。
    await container.read(notesProvider.future);
  });

  tearDown(() {
    container.dispose();
    db.close();
  });

  /// 当前列表（同步读，避免在 FakeAsync 里 await future）。
  List<Note> notesNow() => container.read(notesProvider).value ?? <Note>[];

  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> pumpList(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: NoteListView(
              selectedId: note.id,
              onPick: (String id) =>
                  container.read(selectedNoteIdProvider.notifier).select(id),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  /// 「当前项」两件齐（2026-10-08 强调色药丸换装）——任何一件被改回去，
  /// 这条都会红：底色退回纸面色 / 中性 tint，或左指示条复活（混搭回潮）。
  testWidgets('选中的列表项：强调色药丸底 + w600（2026-10-08 换装）', (tester) async {
    await pumpList(tester);
    final ColorScheme scheme = AppTheme.light().colorScheme;

    expect(
      find.byWidgetPredicate(
        (Widget w) =>
            w is Container && w.color == AppTheme.selectedPill(scheme),
      ),
      findsWidgets,
      reason: '选中项底色不是 selectedPill（退回纸面色/中性 tint/secondaryContainer？）',
    );
    expect(
      find.byWidgetPredicate((Widget w) {
        if (w is! Container) return false;
        final Decoration? d = w.decoration;
        if (d is! BoxDecoration) return false;
        final BoxBorder? border = d.border;
        return border is Border && border.left.color == scheme.primary;
      }),
      findsNothing,
      reason: '3px 左指示条已随换装撤掉——药丸一种形状信号，不许复活',
    );
    final Text title = tester.widget<Text>(find.text('原始标题'));
    expect(
      title.style?.fontWeight,
      FontWeight.w600,
      reason: '选中项标题应是 w600（两件里的第二件）',
    );
  });

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip('更多'));
    await settle(tester);
  }

  /// 点菜单项 + 驱动真实异步（见文件头第 2 条）。
  Future<void> tapMenuItem(WidgetTester tester, String label) async {
    await tester.runAsync(() async {
      await tester.tap(find.text(label));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await settle(tester);
  }

  testWidgets('菜单打开期间：目标条目保持悬浮态（否则看不出菜单对着哪篇）', (WidgetTester tester) async {
    // 再来一条并**不选中它**：目标行的基线底色是"无"，于是后面底色出现
    // 只可能来自菜单状态（而不是选中态——选中行本来就有底色）。
    // ⚠️ 必须 `runAsync`：Riverpod 的 future 链在 FakeAsync 里不会自己跑完
    // （文件头第 2 条约定），直接 await 会挂到超时。
    await tester.runAsync(() async {
      final Note target = await container
          .read(notesProvider.notifier)
          .createNote();
      await container.read(notesProvider.notifier).saveTitle(target.id, '目标标题');
    });
    await pumpList(tester);

    /// 条目行的底色（那层 `height: noteTileHeight` 的 Container）。
    Color? rowColor() => tester
        .widget<Container>(
          find
              .ancestor(
                of: find.text('目标标题'),
                matching: find.byWidgetPredicate(
                  (Widget w) =>
                      w is Container &&
                      w.constraints?.maxHeight == Tokens.noteTileHeight,
                ),
              )
              .first,
        )
        .color;

    ///「···」是否显形（`Visibility.maintainSize` 下尺寸恒在，只能读标志位）。
    /// 按**行**取（两行的「···」都在树上）。
    bool moreVisible() => tester
        .widget<Visibility>(
          find
              .descendant(
                of: find
                    .ancestor(
                      of: find.text('目标标题'),
                      matching: find.byType(MouseRegion),
                    )
                    .first,
                matching: find.byType(Visibility),
              )
              .first,
        )
        .visible;

    expect(rowColor(), Colors.transparent, reason: '基线不成立：非选中的行本来就有底色');

    // 右键打开（非选中行的「···」本来就不可见，右键是它的正当入口）。
    await tester.tap(
      find.text('目标标题'),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await settle(tester);
    expect(find.text('重命名'), findsOneWidget, reason: '右键菜单没开起来');

    // ★ 指针移开（真实场景：鼠标去点菜单）——这正是此前的失效条件。
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(const Offset(700, 560)));
    await tester.pump();

    expect(
      rowColor(),
      AppTheme.contentCanvas(Brightness.light),
      reason: '指针离开后目标行高亮消失 ⇒ 菜单与"它操作哪一篇"断了视觉联系',
    );
    expect(moreVisible(), isTrue, reason: '「···」锚点随高亮一起消失 ⇒ 菜单看着悬空');
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('删除笔记 → **左下角**通知条：窄条、带撤销、到点自动消失', (WidgetTester tester) async {
    await pumpList(tester);
    await openMenu(tester);
    expect(find.text('删除笔记'), findsOneWidget);

    await tapMenuItem(tester, '删除笔记');

    // 列表空态
    expect(find.textContaining('还没有笔记'), findsOneWidget);
    expect(notesNow(), isEmpty);

    // 通知条（不是 SnackBar——后者铺满整行且不自动消失）。
    final Finder toast = find.byKey(const ValueKey<String>('undo-toast'));
    expect(toast, findsOneWidget);
    expect(find.text('已删除「原始标题」'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '撤销'), findsOneWidget);

    // 位置：贴**左下角**，且宽度远小于窗口（不是横跨整行）。
    final Rect rect = tester.getRect(toast);
    final Size screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(rect.left, lessThan(40), reason: '应贴左边');
    expect(rect.bottom, greaterThan(screen.height - 40), reason: '应贴底部');
    expect(rect.width, lessThan(screen.width / 2), reason: '应是窄条不是横幅');

    // 到点自动消失（8 秒）。
    await tester.pump(const Duration(seconds: 9));
    await settle(tester);
    expect(toast, findsNothing, reason: '通知条到点应自动收起');
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('通知条「撤销」→ 笔记回到列表', (WidgetTester tester) async {
    await pumpList(tester);
    await openMenu(tester);
    await tapMenuItem(tester, '删除笔记');
    expect(notesNow(), isEmpty);

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(TextButton, '撤销'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('原始标题'), findsOneWidget, reason: '撤销后笔记应回到列表');
    expect(notesNow().single.id, note.id);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('重命名 → 就地改标题并落库', (WidgetTester tester) async {
    await pumpList(tester);
    await openMenu(tester);

    await tapMenuItem(tester, '重命名');

    // 就地编辑：条目里出现输入框（不是弹窗）。
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), '改过的标题');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    expect(find.text('改过的标题'), findsOneWidget);
    expect(find.byType(TextField), findsNothing, reason: '提交后应退出编辑态');
    expect(notesNow().single.title, '改过的标题');
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('收藏 → 菜单变「取消收藏」，可逆', (WidgetTester tester) async {
    await pumpList(tester);
    await openMenu(tester);

    expect(find.text('收藏'), findsOneWidget);
    await tapMenuItem(tester, '收藏');
    expect(notesNow().single.promotedAt, isNotNull);

    // 再开菜单：文案应变成「取消收藏」（可逆）。
    await openMenu(tester);
    expect(find.text('取消收藏'), findsOneWidget);
    await tapMenuItem(tester, '取消收藏');
    expect(notesNow().single.promotedAt, isNull);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
