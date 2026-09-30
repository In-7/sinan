import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sqlite3/sqlite3.dart';

/// 笔记「删除 / 撤销」的回归（列表右键菜单背后的数据行为）。
///
/// 关注四件事：
/// 1. 删的是当前打开的笔记时，自动选中列表里的**下一条**（而非清空选中）；
/// 2. 撤销把笔记**原样**写回（id / 时间戳 / 内容都不变，不是新建一条）；
/// 3. 删空后回到空态；
/// 4. 列表排序在**并列时间戳**下仍确定（毫秒精度撞车时靠兜底键，不跳序）。
void main() {
  late Database db;
  late ProviderContainer container;

  setUp(() {
    db = sqlite3.openInMemory();
    // 复用真实迁移：测试不会与线上 schema 漂移。
    AppDatabase.migrateForTesting(db);
    container = ProviderContainer(
      overrides: [
        noteStoreProvider.overrideWithValue(NoteStore(db)),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    db.close();
  });

  Future<List<Note>> currentNotes() => container.read(notesProvider.future);

  test('删除当前笔记 → 自动选中下一条；撤销 → 原样恢复', () async {
    final NotesNotifier notifier = container.read(notesProvider.notifier);

    // 三条笔记。列表按 revised_at 倒序——三条几乎同毫秒创建，**并列时
    // 顺序不作保证**，故测试不假设顺序，期望值按实际列表现算（见下）。
    final Note a = await notifier.createNote();
    await notifier.saveTitle(a.id, 'A');
    final Note b = await notifier.createNote();
    await notifier.saveTitle(b.id, 'B');
    final Note c = await notifier.createNote();
    await notifier.saveTitle(c.id, 'C');

    final List<Note> listed = await currentNotes();
    expect(listed.length, 3);
    expect(
      listed.map((Note n) => n.title).toSet(),
      <String>{'A', 'B', 'C'},
    );
    final int index = listed.indexWhere((Note n) => n.id == b.id);
    expect(index, isNonNegative);

    // 打开 B，删它。
    container.read(selectedNoteIdProvider.notifier).select(b.id);
    final Note? removed = await notifier.deleteNote(b.id);

    expect(removed, isNotNull);
    expect(removed!.id, b.id);
    final List<Note> rest = await currentNotes();
    expect(rest.length, 2, reason: '删除后列表应少一条');
    expect(rest.map((Note n) => n.id), isNot(contains(b.id)));
    expect(
      container.read(selectedNoteIdProvider),
      rest[index.clamp(0, rest.length - 1)].id,
      reason: '删除当前笔记后应选中"原位置的下一条"（列表已重排）',
    );

    // 撤销：id / 标题 / 时间戳原样回来，并重新选中它。
    await notifier.restoreNote(removed);
    final List<Note> restored = await currentNotes();
    expect(restored.length, 3);
    final Note back = restored.firstWhere((Note n) => n.id == b.id);
    expect(back.title, 'B');
    // 与**删除时的那份快照**（removed）比，而不是与 createNote 的返回值比：
    // saveTitle 会刷新 revised_at，内存里的 b 早已是旧值。
    // （落库是**毫秒**精度，比较时间戳而非 DateTime 对象——后者带微秒。）
    expect(
      back.createdAt.millisecondsSinceEpoch,
      removed.createdAt.millisecondsSinceEpoch,
    );
    expect(
      back.revisedAt.millisecondsSinceEpoch,
      removed.revisedAt.millisecondsSinceEpoch,
    );
    expect(container.read(selectedNoteIdProvider), b.id);

    // 三条内容都在（撤销没有把别的笔记挤掉）。
    expect(
      restored.map((Note n) => n.title).toSet(),
      <String>{'A', 'B', 'C'},
    );
    expect(a.id, isNot(b.id));
    expect(c.id, isNot(b.id));
  });

  test('删空 → 回到空态（选中置 null）', () async {
    final NotesNotifier notifier = container.read(notesProvider.notifier);
    final Note only = await notifier.createNote();
    container.read(selectedNoteIdProvider.notifier).select(only.id);

    await notifier.deleteNote(only.id);

    expect(await currentNotes(), isEmpty);
    expect(container.read(selectedNoteIdProvider), isNull);
  });

  test('收藏：置顶排序，且可取消（可逆）', () async {
    final NotesNotifier notifier = container.read(notesProvider.notifier);
    final Note a = await notifier.createNote();
    await notifier.saveTitle(a.id, 'A');
    // ⚠️ 落库时间戳是**毫秒**精度：不隔开的话 a / b 的 revised_at 会相等，
    // 而并列项的先后由兜底键决定（created_at 倒序 → id 升序），"B 在前"
    // 这个前提就不再成立（实测：同毫秒时下面这条断言会随机失败）。
    // 本条要验证的是"最近修改倒序"，前提本身必须先真正成立 ⇒ 隔 2ms。
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final Note b = await notifier.createNote();
    await notifier.saveTitle(b.id, 'B');

    // 初始按最近修改倒序：B 在前。
    expect((await currentNotes()).first.id, b.id);

    await notifier.togglePromoted(a);
    expect(
      (await currentNotes()).first.id,
      a.id,
      reason: '收藏项应排在列表最前（不靠最近修改）',
    );

    final Note promoted = (await currentNotes()).first;
    expect(promoted.promotedAt, isNotNull);
    await notifier.togglePromoted(promoted);
    expect((await currentNotes()).first.promotedAt, isNull);
    expect((await currentNotes()).first.id, b.id, reason: '取消后应回到原顺序');
  });

  test('删除不存在的 id：不抛、返回 null、不动选中', () async {
    final NotesNotifier notifier = container.read(notesProvider.notifier);
    final Note kept = await notifier.createNote();
    container.read(selectedNoteIdProvider.notifier).select(kept.id);

    expect(await notifier.deleteNote('not-a-real-id'), isNull);
    expect(container.read(selectedNoteIdProvider), kept.id);
    expect((await currentNotes()).length, 1);
  });

  test('并列时间戳下排序确定：created_at 倒序 → id 升序（刷新之间不跳序）', () async {
    // 落库时间戳是**毫秒**精度，同毫秒创建/修改的两条会并列。并列且没有
    // 兜底键时，SQLite 的返回顺序取决于扫描顺序（= 插入顺序），同一份数据
    // 在不同刷新之间都可能换序——列表会莫名跳动。
    // 这里用 restore **精确写时间戳**：三条笔记的 created_at / revised_at
    // 完全相同，只剩 id 可区分 ⇒ 顺序必须由 id 兜底键决定，且每次一致。
    final NoteStore store = container.read(noteStoreProvider);
    final DateTime t = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    Note tied(String id) => Note(
      id: id,
      kind: NoteKind.spark,
      title: id,
      content: '',
      plainText: '',
      summary: '',
      contentHash: '',
      createdAt: t,
      revisedAt: t,
    );

    // 故意**乱序**插入：若没有兜底键，返回的就是这个插入顺序。
    for (final String id in <String>['b-note', 'c-note', 'a-note']) {
      await store.restore(tied(id));
    }

    const List<String> byIdAsc = <String>['a-note', 'b-note', 'c-note'];
    expect(store.allNotes().map((Note n) => n.id).toList(), byIdAsc);
    // 同一份数据再查一次仍是同一顺序。
    expect(store.allNotes().map((Note n) => n.id).toList(), byIdAsc);
  });
}
