import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// 删除当前笔记后的自动选中必须**留在同一种形态**（2026-11-21 bug）：
/// 在画布视图删掉选中的画布，右格却弹出了**笔记编辑页**——根因是
/// NotesNotifier.trashNote 用 `rest[旧 index]` 从**全池**(含别的形态)取下一条。
/// 画布删空应留空态，笔记删空也应留空态，绝不跨形态跳转。
void main() {
  late Database db;
  late ProviderContainer container;

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    container = ProviderContainer(
      overrides: [noteStoreProvider.overrideWithValue(NoteStore(db))],
    );
  });

  tearDown(() {
    container.dispose();
    db.close();
  });

  test('画布视图删掉唯一画布 → 不跳到别的笔记（应留空态）', () async {
    final NotesNotifier notifier = container.read(notesProvider.notifier);
    final Note doc = await notifier.createNote();
    await notifier.saveTitle(doc.id, '文档');
    final Note canvas = await notifier.createNote(kind: NoteKind.canvas);
    await notifier.saveTitle(canvas.id, '画布');

    // 当前打开的是画布（列表按最近编辑倒序 ⇒ [画布, 文档]，index 0）。
    container.read(selectedNoteIdProvider.notifier).select(canvas.id);
    await notifier.trashNote(canvas.id);

    final String? selected = container.read(selectedNoteIdProvider);
    expect(
      selected,
      isNull,
      reason: '画布删空后不能跳到别的形态的笔记（否则右格变文档编辑页）',
    );
  });

  test('笔记视图删掉唯一笔记 → 不跳到画布（应留空态）', () async {
    final NotesNotifier notifier = container.read(notesProvider.notifier);
    final Note canvas = await notifier.createNote(kind: NoteKind.canvas);
    await notifier.saveTitle(canvas.id, '画布');
    final Note doc = await notifier.createNote();
    await notifier.saveTitle(doc.id, '文档');

    container.read(selectedNoteIdProvider.notifier).select(doc.id);
    await notifier.trashNote(doc.id);

    expect(
      container.read(selectedNoteIdProvider),
      isNull,
      reason: '笔记删空后不能跳到画布（否则右格变画布）',
    );
  });

  test('硬删：画布删空也不跳到文档（deleteNote 同一处 bug）', () async {
    final NotesNotifier notifier = container.read(notesProvider.notifier);
    final Note doc = await notifier.createNote();
    await notifier.saveTitle(doc.id, '文档');
    final Note canvas = await notifier.createNote(kind: NoteKind.canvas);
    await notifier.saveTitle(canvas.id, '画布');

    container.read(selectedNoteIdProvider.notifier).select(canvas.id);
    await notifier.deleteNote(canvas.id);

    expect(
      container.read(selectedNoteIdProvider),
      isNull,
      reason: '硬删画布后同样不能跨形态跳页',
    );
  });

  test('删掉当前项但**同形态还有其它** → 选中同形态的下一条', () async {
    final NotesNotifier notifier = container.read(notesProvider.notifier);
    final Note c1 = await notifier.createNote(kind: NoteKind.canvas);
    await notifier.saveTitle(c1.id, '画布甲');
    final Note doc = await notifier.createNote();
    await notifier.saveTitle(doc.id, '文档');
    final Note c2 = await notifier.createNote(kind: NoteKind.canvas);
    await notifier.saveTitle(c2.id, '画布乙');

    container.read(selectedNoteIdProvider.notifier).select(c2.id);
    await notifier.trashNote(c2.id);

    final String? selected = container.read(selectedNoteIdProvider);
    expect(selected, c1.id, reason: '同形态还有画布甲 ⇒ 选中它，不跳到文档');
  });
}
