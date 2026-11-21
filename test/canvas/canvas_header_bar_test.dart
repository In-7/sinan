import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/canvas/canvas_surface.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/canvas/kernel/canvas_media.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/tokens.dart';
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// 画布顶部动作带（2026-11-21 用户定）：与笔记标题行**同款同位置**——
/// 左撤销/重做，右 搜索/反链/标签；**不含目录**（画布没有大纲）。
void main() {
  late Database db;
  late ProviderContainer container;

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        noteStoreProvider.overrideWithValue(NoteStore(db)),
        settingsStoreProvider.overrideWithValue(SettingsStore(db)),
        appDataDirProvider.overrideWithValue(r'C:\test\sinan'),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    db.close();
  });

  Future<CanvasController> pumpSurface(
    WidgetTester tester, {
    String? noteId,
  }) async {
    final CanvasController controller = CanvasController();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: CanvasSurface(
              controller: controller,
              media: const RelativeMediaResolver('/data/sinan'),
              noteId: noteId,
            ),
          ),
        ),
      ),
    );
    return controller;
  }

  Future<void> teardown(WidgetTester tester, CanvasController c) async {
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  }

  testWidgets('无 noteId：只有撤销/重做（演示壳）', (tester) async {
    final CanvasController c = await pumpSurface(tester);
    expect(find.byKey(const ValueKey<String>('canvas.undo')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('canvas.redo')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('canvas.ear.find')), findsNothing);
    expect(find.byKey(const ValueKey<String>('canvas.ear.backlink')), findsNothing);
    expect(find.byKey(const ValueKey<String>('canvas.ear.tags')), findsNothing);
    await teardown(tester, c);
  });

  testWidgets('有 noteId：左撤销重做 + 右 搜索/反链/标签，且同一 y 同一热区', (
    tester,
  ) async {
    final CanvasController c = await pumpSurface(tester, noteId: 'n1');

    for (final String k in <String>[
      'canvas.undo',
      'canvas.redo',
      'canvas.ear.find',
      'canvas.ear.backlink',
      'canvas.ear.tags',
    ]) {
      expect(find.byKey(ValueKey<String>(k)), findsOneWidget, reason: k);
    }
    // 不含目录（画布没有大纲）。
    expect(find.byTooltip('目录'), findsNothing);

    final Rect undo = tester.getRect(
      find.byKey(const ValueKey<String>('canvas.undo')),
    );
    final Rect find_ = tester.getRect(
      find.byKey(const ValueKey<String>('canvas.ear.find')),
    );
    final Rect tags = tester.getRect(
      find.byKey(const ValueKey<String>('canvas.ear.tags')),
    );

    // 同一条按钮带：同一 y。
    expect(find_.top, closeTo(undo.top, 0.5), reason: '左右两组同一 y');
    expect(tags.top, closeTo(undo.top, 0.5));
    // 热区 = 笔记同档（Tokens.headerActionSize）。
    expect(undo.width, closeTo(Tokens.headerActionSize, 0.5));
    expect(find_.width, closeTo(Tokens.headerActionSize, 0.5));
    // 浮岛内边距 2 + (32-28)/2 ⇒ 两端 28 按钮顶缘回到 **4**（与加浮岛前一致）。
    expect(undo.top, closeTo(4, 0.5), reason: '两端按钮位置不变（顶缘 4）');
    expect(find_.top, closeTo(4, 0.5), reason: '右端同样在 4');
    // 撤销在左、三只耳在右（标签最靠右，右内距 = Tokens.spaceMd）。
    expect(undo.left, closeTo(Tokens.spaceMd, 1));
    final double screenRight =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(tags.right, closeTo(screenRight - Tokens.spaceMd, 1));
    expect(find_.right, lessThan(tags.left), reason: '顺序：搜索 → 反链 → 标签');

    await teardown(tester, c);
  });

  testWidgets('搜索：输入卡片文字 → 命中并可选中该卡片', (tester) async {
    final CanvasController c = await pumpSurface(tester, noteId: 'n1');
    final CardItem card = CardItem(
      id: 'c1',
      rect: const Rect.fromLTWH(0, 0, 200, 100),
      blockId: 'b1',
      text: '番茄工作法',
    );
    c.document.addItem(card);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey<String>('canvas.ear.find')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '番茄');
    await tester.pumpAndSettle();
    expect(find.text('番茄工作法'), findsWidgets, reason: '结果列表有这条');

    await tester.tap(find.text('番茄工作法').last);
    await tester.pumpAndSettle();
    expect(c.hasSelection, isTrue, reason: '选中命中的卡片');
    expect(c.selectedItems.single.id, 'c1');

    await teardown(tester, c);
  });
}
