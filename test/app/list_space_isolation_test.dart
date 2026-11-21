import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/app/home_hub.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/app/search_provider.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// 笔记 / 画布两个**空间**的数据隔离（2026-11-20 用户定）：
/// 共用同一套列表样式模板，但筛选（排序 / 只看收藏 / 标签）与页内搜索
/// 各存一份——在笔记页改的，不带到画布页；切回来还在。
void main() {
  late Database db;
  late ProviderContainer container;

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    container = ProviderContainer(
      overrides: [
        noteStoreProvider.overrideWithValue(NoteStore(db)),
        settingsStoreProvider.overrideWithValue(SettingsStore(db)),
        appDataDirProvider.overrideWithValue(r'C:\test\sinan'),
        databaseProvider.overrideWithValue(db),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    db.close();
  });

  test('排序：笔记页改标题序，画布页仍是默认最近编辑', () {
    expect(container.read(homeSortProvider(NoteSpace.notes)), NoteSort.revised);
    expect(container.read(homeSortProvider(NoteSpace.canvas)), NoteSort.revised);

    container
        .read(homeSortProvider(NoteSpace.notes).notifier)
        .select(NoteSort.title);

    expect(container.read(homeSortProvider(NoteSpace.notes)), NoteSort.title);
    expect(
      container.read(homeSortProvider(NoteSpace.canvas)),
      NoteSort.revised,
      reason: '笔记页的排序不带到画布页',
    );
    // 再改画布，反过来也不影响笔记。
    container
        .read(homeSortProvider(NoteSpace.canvas).notifier)
        .select(NoteSort.created);
    expect(container.read(homeSortProvider(NoteSpace.notes)), NoteSort.title);
  });

  test('只看收藏：两空间各自独立', () {
    container.read(favoriteOnlyProvider(NoteSpace.notes).notifier).toggle();
    expect(container.read(favoriteOnlyProvider(NoteSpace.notes)), isTrue);
    expect(
      container.read(favoriteOnlyProvider(NoteSpace.canvas)),
      isFalse,
      reason: '笔记页的只看收藏不带到画布页',
    );
  });

  test('标签筛选：两空间各自独立，toggle 语义不变', () {
    container.read(listTagProvider(NoteSpace.notes).notifier).toggle('工作');
    expect(container.read(listTagProvider(NoteSpace.notes)), '工作');
    expect(container.read(listTagProvider(NoteSpace.canvas)), isNull);

    container.read(listTagProvider(NoteSpace.canvas).notifier).toggle('画布');
    expect(container.read(listTagProvider(NoteSpace.canvas)), '画布');
    // 点已选中的 = 取消。
    container.read(listTagProvider(NoteSpace.notes).notifier).toggle('工作');
    expect(container.read(listTagProvider(NoteSpace.notes)), isNull);
    expect(container.read(listTagProvider(NoteSpace.canvas)), '画布');
  });

  test('页内搜索：词与展开态各自独立，close 只清本空间', () {
    container
        .read(listSearchProvider(NoteSpace.notes).notifier)
        .setQuery('笔记词');
    expect(container.read(listSearchProvider(NoteSpace.notes)).query, '笔记词');
    expect(container.read(listSearchProvider(NoteSpace.notes)).open, isTrue);
    expect(container.read(listSearchProvider(NoteSpace.canvas)).query, '');

    container
        .read(listSearchProvider(NoteSpace.canvas).notifier)
        .setQuery('画布词');
    expect(container.read(listSearchProvider(NoteSpace.canvas)).query, '画布词');
    expect(container.read(listSearchProvider(NoteSpace.notes)).query, '笔记词');

    container.read(listSearchProvider(NoteSpace.notes).notifier).close();
    expect(container.read(listSearchProvider(NoteSpace.notes)).query, '');
    expect(container.read(listSearchProvider(NoteSpace.notes)).open, isFalse);
    expect(
      container.read(listSearchProvider(NoteSpace.canvas)).query,
      '画布词',
      reason: '关笔记页搜索不影响画布页',
    );
  });

  test('标签池按空间隔离：画布筛选不列笔记的标签', () async {
    // 2026-11-21 用户定：标签池也按空间分家——笔记的标签不出现在画布筛选里。
    final NoteStore store = container.read(noteStoreProvider);
    final DateTime now = DateTime.now();
    Future<void> put(
      String id, {
      required NoteKind kind,
      required List<String> tags,
    }) =>
        store.restore(
          Note(
            id: id,
            kind: kind,
            title: id,
            content: '',
            plainText: '',
            summary: '',
            contentHash: '',
            tags: tags,
            createdAt: now,
            revisedAt: now,
          ),
        );

    await put('n1', kind: NoteKind.note, tags: const <String>['工作']);
    await put('sp', kind: NoteKind.spark, tags: const <String>['灵感']);
    await put('cv', kind: NoteKind.canvas, tags: const <String>['画布标签']);
    container.invalidate(notesProvider);
    await container.read(notesProvider.future);

    expect(
      container.read(tagsForSpaceProvider(NoteSpace.notes)).map((e) => e.$1),
      <String>['工作', '灵感'],
      reason: '笔记空间只列 spark / note 的标签',
    );
    expect(
      container.read(tagsForSpaceProvider(NoteSpace.canvas)).map((e) => e.$1),
      <String>['画布标签'],
      reason: '画布空间只列画布笔记的标签',
    );
    // 全库池（给全局搜索 / 标签建议）仍是三枚都在。
    expect(
      container.read(allTagsProvider).map((e) => e.$1),
      containsAll(<String>['工作', '灵感', '画布标签']),
    );
  });

  test('HomeView → 空间映射：画布独立，其余归笔记', () {
    expect(HomeView.canvas.space, NoteSpace.canvas);
    for (final HomeView v in <HomeView>[
      HomeView.notes,
      HomeView.all,
      HomeView.favorites,
      HomeView.calendar,
      HomeView.timeline,
    ]) {
      expect(v.space, NoteSpace.notes, reason: '${v.label} 归笔记空间');
    }
  });
}
