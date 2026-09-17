import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/pending_saves.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/canvas/canvas_note_view.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// 记账替身：记下每次保存，并真的走父类落库（证明"唯一写入者仍然写库"，
/// 而不是把保存变成空操作）。
///
/// 字段加 `@visibleForTesting`：riverpod_lint 的
/// `avoid_public_notifier_properties` 认可该注解为豁免（测试替身不是对外 API）。
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

/// 画布**写入路径唯一性**的回归（2026-09-17）。
///
/// ## 钉住的问题
/// 画布此前有两条落盘路径：
/// - 防抖 `_flush` → `notesProvider.notifier.saveContent`；
/// - 卸载兜底（`dispose`）→ **直写 `NoteStore.updateContent`**。
///
/// 后者绕过 `NotesNotifier`，形成"第二个写入者"：库里有新内容、列表快照
/// （`notesProvider` 的 state）却还是旧的——后续任何基于旧快照的保存都可能
/// 把这期间的画布改动覆盖掉。
///
/// 修复后两条路都经 `_notes`（`NotesNotifier`）。注意 `dispose` 里**不能**
/// 现取 `ref`：Riverpod 会抛 `Using "ref" when a widget is about to or has
/// been unmounted is unsafe`（本次实测），所以 notifier 必须在 `initState`
/// 提前抓取——这正是本用例能通过的关键。
///
/// ## 覆盖边界
/// 只管**写入路径**，不测绘制：打开画布本身就会让控制器变脏（首帧设置
/// viewport 会 `notifyListeners`），因此无需造手势即可触发兜底落盘，
/// 用例也就没有"手势落点/指针类型"这类与主题无关的脆弱依赖。
/// 笔迹的序列化往返由 `canvas_note_persistence_test.dart` 覆盖。
void main() {
  late Database db;
  late NoteStore store;
  late Directory tempDir;

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    store = NoteStore(db);
    tempDir = Directory.systemTemp.createTempSync('sinan_canvas_save_path');
  });

  tearDown(() {
    db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('卸载兜底落盘必须走 NotesNotifier，不能绕过它直写 store', (
    WidgetTester tester,
  ) async {
    final Note note = store.create(kind: NoteKind.canvas);
    final _RecordingNotes recorder = _RecordingNotes();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // 真库（内存）：让"唯一写入者仍写库"这件事可被验证。
          noteStoreProvider.overrideWithValue(store),
          appDataDirProvider.overrideWithValue(tempDir.path),
          // 替身接管 notesProvider：它的调用记录就是"走了哪条路径"的证据。
          notesProvider.overrideWith(() => recorder),
        ],
        child: MaterialApp(
          home: Scaffold(body: CanvasNoteView(noteId: note.id)),
        ),
      ),
    );
    // 首帧后控制器会因 viewport 落定而变脏 —— 兜底落盘的前提成立。
    await tester.pump();
    // 正常画布**不该**出现"载入失败"提示条（它只在解析失败时出现）。
    expect(find.textContaining('无法读取'), findsNothing);

    // 防抖窗口内直接卸载（等价于"打开画布后立刻切到别的笔记"）：
    // 计时器被取消 ⇒ 只剩 dispose 的兜底落盘这一条路。
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.pump();

    expect(
      recorder.savedContents,
      hasLength(1),
      reason: 'dispose 的兜底落盘绕过了 NotesNotifier（双写路径回归）',
    );

    // 内容是合法画布 JSON（形状与 `CanvasDocument.toJson` 对得上），
    // 且与库里的完全一致：写入者只有一个。
    final Map<String, dynamic> saved =
        jsonDecode(recorder.savedContents.single) as Map<String, dynamic>;
    // 顶层是 `{camera, document}`（`CanvasController.toJson`），文档在里面。
    expect(saved['camera'], isA<Map<String, dynamic>>());
    final Map<String, dynamic> doc =
        saved['document'] as Map<String, dynamic>;
    expect(doc['schemaVersion'], 2);
    expect(doc['strokes'], isA<Map<String, dynamic>>()); // id → 笔迹
    expect(store.noteById(note.id)!.content, recorder.savedContents.single);
  });

  testWidgets('退出前落盘：防抖窗口内关窗口，最后那张画布也要写下去', (
    WidgetTester tester,
  ) async {
    final Note note = store.create(kind: NoteKind.canvas);
    final _RecordingNotes recorder = _RecordingNotes();
    final PendingSaves saves = PendingSaves();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          noteStoreProvider.overrideWithValue(store),
          appDataDirProvider.overrideWithValue(tempDir.path),
          notesProvider.overrideWith(() => recorder),
          pendingSavesProvider.overrideWithValue(saves),
        ],
        child: MaterialApp(
          home: Scaffold(body: CanvasNoteView(noteId: note.id)),
        ),
      ),
    );
    await tester.pump();
    // 先让首帧那次"viewport 落定"的脏自己落完盘，再清账：本用例要测的是
    // **关窗口前那一次**改动，首帧那次脏会把它掩盖掉。
    await tester.pump(const Duration(milliseconds: 700));
    recorder.savedContents.clear();

    // 画一笔（挂上 600ms 防抖），但**不推进时间**：此刻还没落盘。
    // 等价于用户"画完/改完立刻关窗口"。
    final TestGesture gesture = await tester.startGesture(const Offset(120, 120));
    await gesture.moveBy(const Offset(30, 10));
    await gesture.up();
    await tester.pump();
    expect(
      recorder.savedContents,
      isEmpty,
      reason: '前置条件不成立：防抖已经自己落盘了，本用例就测不到退出路径',
    );

    // 关窗口：引擎发来退出请求 → `didRequestAppExit` → 先等落盘
    // （见 `pending_saves.dart` 的 `flushThenExit`）。
    await saves.flushAll();

    expect(
      recorder.savedContents,
      hasLength(1),
      reason: '关窗口时最后一次画布改动没写下去（这条路径此前完全没有）',
    );
    // 真的进了库：重开后读回来的就是这一份。
    expect(store.noteById(note.id)!.content, recorder.savedContents.single);
    expect(
      jsonDecode(recorder.savedContents.single),
      isA<Map<String, dynamic>>(),
    );
  });

  testWidgets('连续运笔不停手时，最迟 2s 也必落盘一次（防抖上限）', (
    WidgetTester tester,
  ) async {
    final Note note = store.create(kind: NoteKind.canvas);
    final _RecordingNotes recorder = _RecordingNotes();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          noteStoreProvider.overrideWithValue(store),
          appDataDirProvider.overrideWithValue(tempDir.path),
          notesProvider.overrideWith(() => recorder),
        ],
        child: MaterialApp(
          home: Scaffold(body: CanvasNoteView(noteId: note.id)),
        ),
      ),
    );
    await tester.pump();
    recorder.savedContents.clear(); // 首帧那次不算（要测的是"连续输入"这一段）

    // 每 300ms 画一笔：比 600ms 的防抖窗口短 ⇒ 纯防抖下一次都不会落盘。
    // 连画 8 笔 = 2.4s > 2s 上限 ⇒ 期间**必须**落过盘。
    for (int i = 0; i < 8; i++) {
      final TestGesture gesture = await tester.startGesture(
        Offset(120 + i * 6, 120),
      );
      await gesture.moveBy(const Offset(30, 10));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(
      recorder.savedContents,
      isNotEmpty,
      reason: '连续 2.4s 不停笔却一次都没落盘：暴露窗口会随时间线性增长（缺防抖上限）',
    );
  });

  testWidgets('载入失败（内容非空却解析不出）时冻结保存：不得把空画布写回去', (
    WidgetTester tester,
  ) async {
    // 一份"坏掉"的画布正文：非空、但解析不出（模拟旧格式 / 被别处覆盖）。
    const String broken = '{"camera": {"scale": 1}, "document": ';
    final Note note = store.create(kind: NoteKind.canvas);
    await store.updateContent(note.id, broken, plainText: '');

    final _RecordingNotes recorder = _RecordingNotes();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          noteStoreProvider.overrideWithValue(store),
          appDataDirProvider.overrideWithValue(tempDir.path),
          notesProvider.overrideWith(() => recorder),
        ],
        child: MaterialApp(
          home: Scaffold(body: CanvasNoteView(noteId: note.id)),
        ),
      ),
    );
    await tester.pump();
    // ⚠️ 冻结保存的**代价必须可见**：否则用户会以为在正常编辑，在空白画布上
    // 画完才发现什么都没存（2026-09-17 补的提示条）。
    expect(
      find.textContaining('无法读取'),
      findsOneWidget,
      reason: '冻结了保存却不告诉用户：他会继续在空白画布上白画',
    );
    // ⚠️ 让**防抖窗口真的到期**：否则用例只能证明"卸载兜底没写"，而覆盖原文
    // 更常见的路径是"用户就停在这张坏画布上不动，600ms 后防抖自己写了"。
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.pump();

    expect(
      recorder.savedContents,
      isEmpty,
      reason: '载入失败却仍回写：空画布会把用户原文覆盖掉（数据丢失）',
    );
    expect(
      store.noteById(note.id)!.content,
      broken,
      reason: '库里的原文被动过',
    );
  });
}
