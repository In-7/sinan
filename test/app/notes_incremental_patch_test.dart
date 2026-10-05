import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// 保存热路径的**增量换行**（2026-10-04，阶段 B 探针落地的定向优化）。
///
/// 背景：探针实测 `allNotes()` 在 1k 篇 ≈ 15ms、1w 篇 ≈ 117ms（JIT），其中
/// ~87% 是 `Row → Note` 映射——而编辑器**每次防抖保存**都整表重查一次，全在
/// UI 线程。改动后只取变动的那一行（[NoteStore.noteListRow]）替换进快照并按
/// [NoteStore.compareForList] 重排。
///
/// 本文件钉两件事：
/// ① 比较器 == [NoteStore.allNotes] 的 SQL `ORDER BY`（**逐字等价**，一旦
///    有人改了一处忘了另一处，这里立刻红）；
/// ② 各保存路径的补丁行为：顺序与整表重查一致、字段刷新、无关行保持
///    对象同一性（下游 provider 不因它重建）、行缺失时安全不动。
void main() {
  late Database db;
  late NoteStore store;
  late ProviderContainer container;

  const String kDataDir = r'C:\Users\test\AppData\Roaming\sinan';
  final DateTime t = DateTime.fromMillisecondsSinceEpoch(1700000000000);

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    store = NoteStore(db);
    container = ProviderContainer(
      overrides: [
        noteStoreProvider.overrideWithValue(store),
        settingsStoreProvider.overrideWithValue(SettingsStore(db)),
        appDataDirProvider.overrideWithValue(kDataDir),
        databaseProvider.overrideWithValue(db),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    db.close();
  });

  /// 用 restore 精确钉时间戳 / 收藏位（create 只给当下时间，无法造并列）。
  Future<void> put(
    String id, {
    NoteKind kind = NoteKind.note,
    List<String> tags = const <String>[],
    int createdOffset = 0,
    int revisedOffset = 0,
    int? promotedOffset,
    String content = '',
  }) => store.restore(
    Note(
      id: id,
      kind: kind,
      title: id,
      content: content,
      plainText: '',
      summary: '',
      contentHash: '',
      tags: tags,
      createdAt: t.add(Duration(milliseconds: createdOffset)),
      revisedAt: t.add(Duration(milliseconds: revisedOffset)),
      promotedAt: promotedOffset == null
          ? null
          : t.add(Duration(milliseconds: promotedOffset)),
    ),
  );

  List<String> idsOf(List<Note> notes) =>
      <String>[for (final Note n in notes) n.id];

  group('比较器与 SQL ORDER BY 等价', () {
    test('收藏置顶 / revised DESC / created DESC / id ASC 全链路', () async {
      // 收藏组：p1 收藏更晚（t+300）⇒ 在 p2 前（promoted_at DESC）。
      await put('p1', revisedOffset: 10, promotedOffset: 300);
      await put('p2', revisedOffset: 50, promotedOffset: 200);
      // 非收藏：n1/n2/n3 同 revised（t+100）⇒ 看 created DESC；
      // n2/n3 连 created 也并列 ⇒ 看 id ASC。
      await put('n1', revisedOffset: 100, createdOffset: 5);
      await put('n2', revisedOffset: 100, createdOffset: 9);
      await put('n3', revisedOffset: 100, createdOffset: 9);
      await put('n0', revisedOffset: 1);

      final List<Note> sqlOrder = store.allNotes();
      // 同一批对象换成 Dart 比较器排一遍，必须得到完全相同的 id 序列。
      final List<Note> dartOrder = List<Note>.of(sqlOrder)
        ..sort(NoteStore.compareForList);

      expect(idsOf(sqlOrder), <String>['p1', 'p2', 'n2', 'n3', 'n1', 'n0']);
      expect(idsOf(dartOrder), idsOf(sqlOrder));
    });
  });

  group('增量换行：保存路径', () {
    test('saveContent：顺序与整表重查一致，且无关行保持同一对象', () async {
      await put('a', revisedOffset: 10, content: 'old');
      await put('b', revisedOffset: 20);
      await put('c', revisedOffset: 30);
      final List<Note> before = await container.read(notesProvider.future);
      final Note untouched = before.firstWhere((Note n) => n.id == 'b');

      // a 保存新正文 ⇒ revised_at 刷到当下（最大）⇒ 应升到最前。
      await container
          .read(notesProvider.notifier)
          .saveContent('a', '{"v":2}', plainText: '新正文摘要');

      final List<Note> after = container.read(notesProvider).value!;
      // ① 顺序与"老实整表重查"逐字等价（这是消费者按索引渲染的前提）。
      expect(idsOf(after), idsOf(store.allNotes()));
      expect(after.first.id, 'a');
      // ② 变动行的字段确实刷新（摘要投影 / 哈希 / 时间）。
      final Note a = after.firstWhere((Note n) => n.id == 'a');
      expect(a.summary, '新正文摘要');
      expect(a.contentHash, isNotEmpty);
      // ③ 未变动的行是**同一个对象实例**——下游 select(该行哈希) 不重建它的卡。
      expect(identical(after.firstWhere((Note n) => n.id == 'b'), untouched), isTrue);
    });

    test('saveTitle：改名刷 revised_at ⇒ 补丁后同样升到最前', () async {
      await put('a', revisedOffset: 10);
      await put('b', revisedOffset: 20);
      await container.read(notesProvider.future);

      await container.read(notesProvider.notifier).saveTitle('a', '新标题');

      final List<Note> after = container.read(notesProvider).value!;
      expect(idsOf(after), idsOf(store.allNotes()));
      expect(after.first.id, 'a');
      expect(after.first.title, '新标题');
    });

    test('togglePromoted：进收藏组置顶，顺序与整表重查一致', () async {
      await put('a', revisedOffset: 30);
      await put('b', revisedOffset: 20);
      await put('c', revisedOffset: 10);
      final List<Note> before = await container.read(notesProvider.future);

      // 收藏 c（revised 最小）⇒ 应跳到最前（收藏组）。
      await container
          .read(notesProvider.notifier)
          .togglePromoted(before.firstWhere((Note n) => n.id == 'c'));

      final List<Note> after = container.read(notesProvider).value!;
      expect(idsOf(after), idsOf(store.allNotes()));
      expect(after.first.id, 'c');
      expect(after.first.promotedAt, isNotNull);
    });

    test('行不存在：补丁安全不动（不崩、不误插一行）', () async {
      await put('a', revisedOffset: 10);
      final List<Note> before = await container.read(notesProvider.future);

      // 对不存在的 id 保存标题：updateTitle 影响 0 行，noteListRow 返 null。
      await container.read(notesProvider.notifier).saveTitle('ghost', 'x');

      final List<Note> after = container.read(notesProvider).value!;
      expect(idsOf(after), idsOf(before));
    });
  });
}