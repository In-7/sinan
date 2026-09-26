import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/editor/panels/tags_panel.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/theme/app_float_surface.dart';
import 'package:sqlite3/sqlite3.dart';

/// 标签面板挂在**根 Overlay**（无 Material 祖先）的回归。
///
/// 2026-09-26 实机炸过：浮层三件套的 `AppFloatSurface` 是纯表面容器（无
/// Material），而编辑器的气泡经 `OverlayPortal` 挂到根 Overlay——它在
/// MaterialApp 的 Navigator 之上、Scaffold 的 Material 之外 ⇒ TextField
/// 抛 "No Material widget found"，连锁把整帧布局拖崩（RenderFlex overflow）。
///
/// 本测试忠实复刻挂载环境：`home` 直接是 `Overlay`（**不是** Scaffold），
/// 上面没有任何 Material。面板不补 Material 祖先的话，这条直接红。
void main() {
  testWidgets('无 Material 祖先的 Overlay 里挂载不炸，回车能加标签', (
    WidgetTester tester,
  ) async {
    final Database db = sqlite3.openInMemory();
    addTearDown(db.close);
    AppDatabase.migrateForTesting(db);
    final NoteStore store = NoteStore(db);
    final ProviderContainer container = ProviderContainer(
      overrides: [
        noteStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);

    // 面板服务一篇真实存在的笔记（空列表测不出加标签的交互）。
    final Note note = await container.read(notesProvider.notifier).createNote();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Overlay(
            initialEntries: <OverlayEntry>[
              OverlayEntry(
                builder: (_) => AppFloatSurface(
                  width: TagsPanel.width,
                  padding: EdgeInsets.zero,
                  child: TagsPanel(noteId: note.id),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 输入 + 回车 ⇒ 标签经 saveTags 落库并出现在面板上。
    await tester.enterText(find.byType(TextField), '工作法');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(
      find.text('工作法'),
      findsOneWidget,
      reason: '面板在无 Material 祖先的 Overlay 里也要能正常打标签',
    );
    // 落库验证（不只是 UI 画出来了）。
    expect(store.noteById(note.id)!.tags, <String>['工作法']);
  });
}
