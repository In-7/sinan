import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/app/search_provider.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// 全局搜索 **provider 层**的契约（2026-09-29：搜索 UX 并入主页顶栏，
/// widget 级用例迁到 `home_hub_test.dart`；这里只钉检索本身）。
///
/// 钉的是 [searchNotifierProvider] 的核心行为：
/// - **标题 + 内容一次合并**（标题路内存 contains、内容路走 FTS），标题命中置顶；
/// - 清词不丢标签筛选（落进"标签视图"）；
/// - 列表一变结果跟着重算（hits 是静态快照 ⇒ 必须 listen notesProvider）。
void main() {
  late Database db;
  late NoteStore notes;
  late SettingsStore settings;

  const String kDataDir = r'C:\Users\test\AppData\Roaming\sinan';

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    notes = NoteStore(db);
    settings = SettingsStore(db);
  });
  tearDown(() => db.close());

  ProviderContainer newContainer() => ProviderContainer(
    overrides: [
      noteStoreProvider.overrideWithValue(notes),
      settingsStoreProvider.overrideWithValue(settings),
      appDataDirProvider.overrideWithValue(kDataDir),
      // 检索设施只读这条裸连接（AppDatabase 只有 open()，内存库直接给 db）。
      databaseProvider.overrideWithValue(db),
    ],
  );

  /// 直插一个带文本的段落块并同步进关键词索引。
  void seedContent(String noteId, String text) {
    db.execute(
      'INSERT INTO blocks (id, note_id, type, props_json, ord, parent_id, '
      'created_at, updated_at, fingerprint) '
      "VALUES (?, ?, 'paragraph', ?, 1024, NULL, 0, 0, 'fp-test')",
      <Object?>[
        'blk-$noteId',
        noteId,
        '{"text":"${text.replaceAll('"', r'\"')}"}',
      ],
    );
    IndexJob(db: db).indexNoteKeywordPath(noteId);
  }

  test('标题+内容合并：标题命中置顶，内容命中带摘要', () async {
    final ProviderContainer container = newContainer();
    addTearDown(container.dispose);

    // A：标题命中；B：只有内容命中。
    final Note a = await container.read(notesProvider.notifier).createNote();
    await container.read(notesProvider.notifier).saveTitle(a.id, '番茄工作法笔记');
    final Note b = await container.read(notesProvider.notifier).createNote();
    await container.read(notesProvider.notifier).saveTitle(b.id, '读书摘抄');
    seedContent(b.id, '今天读了讲番茄工作法的一章，先专注再休息');

    container.read(searchNotifierProvider.notifier).submit('番茄');
    // 去抖 250ms + 检索落地。
    await Future<void>.delayed(const Duration(milliseconds: 400));

    final SearchState s = container.read(searchNotifierProvider);
    final List<String> hitIds = s.hits.map((SearchHit h) => h.note.id).toList();
    expect(hitIds, containsAll(<String>[a.id, b.id]), reason: '两路命中都要在');
    expect(
      hitIds.first,
      a.id,
      reason: '标题命中（最强信号）必须排在内容命中之前',
    );
    expect(
      s.hits.firstWhere((SearchHit h) => h.note.id == a.id).titleMatch,
      isTrue,
    );
    expect(
      s.hits.firstWhere((SearchHit h) => h.note.id == b.id).snippet,
      isNotNull,
      reason: '内容命中要带摘要',
    );
  });

  test('无结果给空 hits，不装作在搜', () async {
    final ProviderContainer container = newContainer();
    addTearDown(container.dispose);
    await container.read(notesProvider.notifier).createNote();

    container.read(searchNotifierProvider.notifier).submit('不存在的词');
    await Future<void>.delayed(const Duration(milliseconds: 400));

    final SearchState s = container.read(searchNotifierProvider);
    expect(s.query, '不存在的词');
    expect(s.hits, isEmpty);
  });

  test('标签筛选：有词时内存过滤；清词不丢筛选，落标签视图', () async {
    final ProviderContainer container = newContainer();
    addTearDown(container.dispose);

    final Note a = await container.read(notesProvider.notifier).createNote();
    await container.read(notesProvider.notifier).saveTitle(a.id, '番茄工作法笔记');
    await container
        .read(notesProvider.notifier)
        .saveTags(a.id, <String>['工作法']);
    final Note b = await container.read(notesProvider.notifier).createNote();
    await container.read(notesProvider.notifier).saveTitle(b.id, '番茄时钟');

    container.read(searchNotifierProvider.notifier).submit('番茄');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(container.read(searchNotifierProvider).hits.length, 2);

    // 有词点 chip ⇒ 内存过滤，只剩带标签的 A。
    container.read(searchNotifierProvider.notifier).selectTag('工作法');
    SearchState s = container.read(searchNotifierProvider);
    expect(s.activeTag, '工作法');
    expect(s.hits.map((SearchHit h) => h.note.id).toList(), <String>[a.id]);

    // 清词 ⇒ 不丢标签筛选，落进"标签视图"（该标签全部笔记）。
    container.read(searchNotifierProvider.notifier).submit('');
    s = container.read(searchNotifierProvider);
    expect(s.query, isEmpty);
    expect(s.activeTag, '工作法');
    expect(s.hits.map((SearchHit h) => h.note.id).toList(), <String>[a.id]);

    // 再点同一 chip（UI 传 null）= 取消 ⇒ 回初始空态。
    container.read(searchNotifierProvider.notifier).selectTag(null);
    s = container.read(searchNotifierProvider);
    expect(s.activeTag, isNull);
    expect(s.hits, isEmpty);
  });

  test('摘掉标签：结果同步收窄；最后一个摘掉时连筛选一起撤', () async {
    final ProviderContainer container = newContainer();
    addTearDown(container.dispose);

    final Note a = await container.read(notesProvider.notifier).createNote();
    await container.read(notesProvider.notifier).saveTitle(a.id, '甲');
    final Note b = await container.read(notesProvider.notifier).createNote();
    await container.read(notesProvider.notifier).saveTitle(b.id, '乙');
    await container
        .read(notesProvider.notifier)
        .saveTags(a.id, <String>['工作法']);
    await container
        .read(notesProvider.notifier)
        .saveTags(b.id, <String>['工作法']);

    // 无词点 chip ⇒ 标签视图：甲 + 乙。
    container.read(searchNotifierProvider.notifier).selectTag('工作法');
    expect(container.read(searchNotifierProvider).hits.length, 2);

    // 摘掉甲的 ⇒ 列表 listen 触发重算：甲立即消失，乙还在。
    await container.read(notesProvider.notifier).saveTags(a.id, <String>[]);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    SearchState s = container.read(searchNotifierProvider);
    expect(
      s.hits.map((SearchHit h) => h.note.id).toList(),
      <String>[b.id],
      reason: '标签摘了，hits 快照不许还挂着这篇（2026-09-26 实机 bug）',
    );

    // 摘掉乙的 ⇒ 标签从池子彻底消失 ⇒ 连筛选一起撤（回初始空态）。
    await container.read(notesProvider.notifier).saveTags(b.id, <String>[]);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    s = container.read(searchNotifierProvider);
    expect(s.activeTag, isNull, reason: '最后一篇的标签摘掉后筛选必须一并撤');
    expect(s.hits, isEmpty);
  });

  test('allTagsProvider：跨形态一套池，按篇数倒序', () async {
    final ProviderContainer container = newContainer();
    addTearDown(container.dispose);

    final Note a = await container.read(notesProvider.notifier).createNote();
    final Note b = await container
        .read(notesProvider.notifier)
        .createNote(kind: NoteKind.canvas);
    await container
        .read(notesProvider.notifier)
        .saveTags(a.id, <String>['工作法', '读书']);
    await container
        .read(notesProvider.notifier)
        .saveTags(b.id, <String>['工作法']);

    final List<(String, int)> tags = container.read(allTagsProvider);
    expect(
      tags,
      containsAll(<(String, int)>[('工作法', 2), ('读书', 1)]),
      reason: '画布的标签与笔记同池计数',
    );
    expect(
      tags.first,
      ('工作法', 2),
      reason: '出现篇数多的排前',
    );
  });
}
