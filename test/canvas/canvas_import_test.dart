import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/pending_saves.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/canvas/canvas_note_view.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/canvas/kernel/canvas_view.dart';
import 'package:sinan/src/canvas/kernel/ink_stroke.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// 记账替身：记下每次保存，并真的走父类落库（证明导入的文档**确实进了库**）。
class _RecordingNotes extends NotesNotifier {
  @visibleForTesting
  final List<String> savedContents = <String>[];

  @override
  Future<void> saveContent(
    String id,
    String content, {
    required String plainText,
  }) async {
    savedContents.add(content);
    await super.saveContent(id, content, plainText: plainText);
  }
}

/// `.canvas.json` 导入（2026-09-17，画布 P0 收尾）。
///
/// 导入是**破坏性**动作（换掉当前文档、撤销历史一并丢弃），所以钉这四条：
/// ① 先问后选（确认框在文件对话框之前）；
/// ② 解析成功才换文档——**失败绝不能把当前内容清掉**；
/// ③ 换完必须**排进落盘**（否则这份导入只活在内存里，关窗口就丢）；
/// ④ 用户取消则完全不动。
///
/// 文件对话框不可测，所以拾取那一半是注入的（`pickBundleText`）——真实实现见
/// `canvas_import.dart`，测试塞"直接返回文本"的替身即可覆盖整条链路。
void main() {
  late Database db;
  late NoteStore store;
  late Directory tempDir;

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    store = NoteStore(db);
    tempDir = Directory.systemTemp.createTempSync('sinan_canvas_import');
  });

  tearDown(() {
    db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  final Finder importButton = find.byTooltip('导入画布文件（.canvas.json，替换当前画布）');

  /// 一份含两个形状的 `.canvas.json`（用"2 个 item"区分"导入成功"与"原本空画布"）。
  String bundleWithShapes() {
    final CanvasController source = CanvasController();
    for (int i = 0; i < 2; i++) {
      source.document.addItem(
        ShapeItem(
          rect: Rect.fromLTWH(i * 40.0, 0, 20, 20),
          kind: CanvasShapeKind.rectangle,
          color: kThemeInk,
        ),
      );
    }
    final String text = jsonEncode(source.toJson());
    source.dispose();
    return text;
  }

  Future<void> pumpCanvas(
    WidgetTester tester, {
    required Note note,
    required PendingSaves saves,
    required Future<String?> Function() pickBundleText,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          noteStoreProvider.overrideWithValue(store),
          appDataDirProvider.overrideWithValue(tempDir.path),
          notesProvider.overrideWith(_RecordingNotes.new),
          pendingSavesProvider.overrideWithValue(saves),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: CanvasNoteView(
              noteId: note.id,
              pickBundleText: pickBundleText,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  CanvasController current(WidgetTester tester) =>
      tester.widget<CanvasView>(find.byType(CanvasView)).controller;

  testWidgets('导入：换掉文档，并排进落盘（否则只活在内存里）', (WidgetTester tester) async {
    final Note note = store.create(kind: NoteKind.canvas);
    final PendingSaves saves = PendingSaves();
    await pumpCanvas(
      tester,
      note: note,
      saves: saves,
      pickBundleText: () async => bundleWithShapes(),
    );
    expect(current(tester).document.items, isEmpty); // 前提：原本是空画布

    await tester.tap(importButton);
    await tester.pumpAndSettle();
    expect(
      find.text('导入画布文件'),
      findsOneWidget,
      reason: '破坏性替换必须先问一句（"保护数据的取舍要可见告知"）',
    );

    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    expect(
      current(tester).document.items,
      hasLength(2),
      reason: '导入没换掉文档',
    );

    // 换完必须排落盘：无论走退出前落盘还是防抖，库里都得是新文档。
    await saves.flushAll();
    await tester.pump(const Duration(milliseconds: 700));
    expect(
      store.noteById(note.id)!.content,
      contains('"shape"'),
      reason: '导入的文档没落盘：关窗口/切笔记就丢',
    );
  });

  testWidgets('先问后选：在确认框取消时，连文件对话框都不该弹', (WidgetTester tester) async {
    final Note note = store.create(kind: NoteKind.canvas);
    bool picked = false;
    await pumpCanvas(
      tester,
      note: note,
      saves: PendingSaves(),
      pickBundleText: () async {
        picked = true;
        return bundleWithShapes();
      },
    );

    await tester.tap(importButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(picked, isFalse, reason: '用户还没确认就去弹文件对话框：白挑一次文件');
    expect(current(tester).document.items, isEmpty);
  });

  testWidgets('文件不是画布：提示失败，且**不**动当前画布', (WidgetTester tester) async {
    final Note note = store.create(kind: NoteKind.canvas);
    await pumpCanvas(
      tester,
      note: note,
      saves: PendingSaves(),
      pickBundleText: () async => '这不是画布文件',
    );

    await tester.tap(importButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    expect(find.textContaining('导入失败'), findsOneWidget);
    expect(
      current(tester).document.items,
      isEmpty,
      reason: '解析失败却换了文档：等于把用户当前的内容清空了',
    );
  });

  testWidgets('用户取消选文件：什么都不变，也不提示成功', (WidgetTester tester) async {
    final Note note = store.create(kind: NoteKind.canvas);
    await pumpCanvas(
      tester,
      note: note,
      saves: PendingSaves(),
      pickBundleText: () async => null,
    );

    await tester.tap(importButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    expect(find.text('已导入画布文件'), findsNothing);
    expect(current(tester).document.items, isEmpty);
  });
}
