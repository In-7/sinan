import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/app/home_hub.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// [homeItemsProvider]（2026-09-30 从 _HomeBody._itemsFor 抽出）的回归。
///
/// 钉两类事实：
/// ① **语义不变**：视图范围（全部/笔记/画布/收藏）、标签过滤、收藏固定
///    "最近收藏在前"；
/// ② **记忆化**：入参不变时重复读拿到**同一个 List 实例**（窗口 resize 等
///    无关 rebuild 不再全量重排）；排序方案一变，结果实例随之更新。
void main() {
  late Database db;
  late NoteStore store;
  late SettingsStore settings;
  late ProviderContainer container;

  const String kDataDir = r'C:\Users\test\AppData\Roaming\sinan';
  final DateTime t = DateTime.fromMillisecondsSinceEpoch(1700000000000);

  setUp(() async {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    store = NoteStore(db);
    settings = SettingsStore(db);
    container = ProviderContainer(
      overrides: [
        noteStoreProvider.overrideWithValue(store),
        settingsStoreProvider.overrideWithValue(settings),
        appDataDirProvider.overrideWithValue(kDataDir),
        databaseProvider.overrideWithValue(db),
      ],
    );

    // 用 restore 精确钉时间戳 / 标签 / 收藏位（create 只给当下时间）。
    Future<void> put(
      String id, {
      NoteKind kind = NoteKind.note,
      List<String> tags = const <String>[],
      int createdOffset = 0,
      int revisedOffset = 0,
      int? promotedOffset,
    }) async {
      await store.restore(
        Note(
          id: id,
          kind: kind,
          title: id,
          content: '',
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
    }

    await put('n1', tags: <String>['工作'], revisedOffset: 100);
    await put('n2', tags: <String>['生活'], createdOffset: 1, revisedOffset: 200);
    await put(
      'cv1',
      kind: NoteKind.canvas,
      createdOffset: 2,
      revisedOffset: 50,
    );
    await put('fav', createdOffset: 3, revisedOffset: 10, promotedOffset: 500);

    // restore 直接写库 ⇒ 让 notesProvider 重新拉快照。
    container.invalidate(notesProvider);
    await container.read(notesProvider.future);
  });

  tearDown(() {
    container.dispose();
    db.close();
  });

  List<String> ids(
    HomeView view, {
    String? tag,
    NoteKindFacet kind = NoteKindFacet.all,
  }) => container
      .read(homeItemsProvider((view: view, tag: tag, kind: kind)))
      .map((Note n) => n.id)
      .toList();

  test('语义：全部按最近编辑倒序；视图、形态、标签各管各的池子', () {
    expect(ids(HomeView.all), <String>['n2', 'n1', 'cv1', 'fav']);
    // 形态是 facet（2026-10-05 决策 E）⇒ 不再有 notes / canvas 两个视图。
    expect(
      ids(HomeView.all, kind: NoteKindFacet.docs),
      <String>['n2', 'n1', 'fav'],
    );
    expect(ids(HomeView.all, kind: NoteKindFacet.canvas), <String>['cv1']);
    expect(ids(HomeView.all, tag: '工作'), <String>['n1']);
    expect(ids(HomeView.all, tag: '不存在的标签'), <String>[]);
  });

  test('收藏视图固定"最近收藏在前"，不跟全局排序', () {
    container.read(homeSortProvider.notifier).select(NoteSort.created);
    expect(ids(HomeView.favorites), <String>['fav']);
  });

  test('记忆化：入参不变重复读是同一实例；排序变了才重算', () {
    const HomeItemsArgs args = (
      view: HomeView.all,
      tag: null,
      kind: NoteKindFacet.all,
    );

    // listen 住条目（autoDispose 不会在两次读之间释放）。
    final sub = container.listen(homeItemsProvider(args), (_, _) {});
    final List<Note> first = sub.read();
    final List<Note> again = container.read(homeItemsProvider(args));
    expect(identical(first, again), isTrue, reason: '快照/排序/入参都没变 ⇒ 必须复用，不该重排');

    // 换排序方案 ⇒ 结果与实例都更新。
    container.read(homeSortProvider.notifier).select(NoteSort.created);
    final List<Note> byCreated = container.read(homeItemsProvider(args));
    expect(byCreated.map((Note n) => n.id).toList(), <String>[
      'fav',
      'cv1',
      'n2',
      'n1',
    ]);
    expect(identical(byCreated, first), isFalse);
  });
}
