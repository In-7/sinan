import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/home_hub.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/focus_ring.dart';
import 'package:sqlite3/sqlite3.dart';

/// 主页骨架的回归（Things 3 式一页纸，2026-09-24 重写）。
///
/// 钉的是"主页是什么"这四条结构性事实：
/// ① 未选中 = 主页（不是空面板）；② **行都接了焦点环**（§5.2：主页行是新出现的
/// 自绘交互件，不能又变成只有鼠标能用）；③ 点行 = 走 `locateProvider`（§4 的唯一
/// 跳转通道）；④ **永远单列**：行全宽等宽、垂直堆叠——一旦出现并排/不等宽，
/// 就是退回了 Bento 卡片格（2026-09-24 明确弃用）。
void main() {
  late Database db;
  late NoteStore notes;
  late SettingsStore settings;

  const String kDataDir = r'C:\Users\test\AppData\Roaming\sinan';

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    notes = NoteStore(db);
    settings = SettingsStore(db);
  });

  tearDown(() => db.close());

  ProviderContainer newContainer() => ProviderContainer(
        overrides: [
          noteStoreProvider.overrideWithValue(notes),
          settingsStoreProvider.overrideWithValue(settings),
          appDataDirProvider.overrideWithValue(kDataDir),
        ],
      );

  /// [noteCount] 条笔记先建好再挂主页（建笔记走 `notesProvider.notifier`，
  /// 与产品路径同源）。
  Future<ProviderContainer> pumpHub(
    WidgetTester tester, {
    int noteCount = 0,
  }) async {
    final ProviderContainer container = newContainer();
    for (int i = 0; i < noteCount; i++) {
      await container.read(notesProvider.notifier).createNote();
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: HomeHub()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('空库：不给空行，直接指路', (WidgetTester tester) async {
    await pumpHub(tester);

    expect(find.text('还没有笔记'), findsOneWidget);
    expect(find.text('新建第一条'), findsOneWidget);
    // 空库时主页只有指路文案 + 一个 FilledButton，没有自绘行 ⇒ 没有焦点环。
    expect(
      find.byType(FocusRing),
      findsNothing,
      reason: '空库没有行可交互；新建入口走 FilledButton（Material 自带焦点）',
    );
  });

  testWidgets('有笔记：继续 + 最近 + 新建三段，行都接了焦点环', (WidgetTester tester) async {
    await pumpHub(tester, noteCount: 3);

    expect(find.text('继续'), findsOneWidget);
    expect(find.text('最近'), findsOneWidget);
    expect(find.text('新建'), findsOneWidget);
    // 3 篇笔记 ⇒ 日历 3 行（都建在今天、选中当天）+ 继续 1 行 +
    // 最近折叠头 1 + 最近 2 行 + 新建 ghost 2 行 = 9。
    // ⚠️ 日历分区在最前，它的行同样带 FocusRing —— 增删分区这个数要跟着改。
    expect(
      find.byType(FocusRing),
      findsNWidgets(9),
      reason: '主页行与折叠头都是自绘交互件 ⇒ 必须全部接进 Focus 树（§5.2）',
    );
  });

  testWidgets('点行进入该笔记：走 locateProvider（唯一跳转通道）', (WidgetTester tester) async {
    final ProviderContainer container = await pumpHub(tester, noteCount: 3);

    expect(container.read(selectedNoteIdProvider), isNull, reason: '主页 = 未选中');

    // FocusRing 视觉顺序：0..2 = 日历当天行，3 = 继续行，4 = 最近折叠头，
    // 5..6 = 最近行，7..8 = 新建。这里 at(2) 落在日历的一行上（同样是笔记行）。
    await tester.tap(find.byType(FocusRing).at(2));
    await tester.pumpAndSettle();

    final String? selected = container.read(selectedNoteIdProvider);
    expect(selected, isNotNull, reason: '点了行却没有选中笔记');
    expect(
      notes.allNotes().map((Note n) => n.id).toList(),
      contains(selected),
      reason: '选中的必须是库里真实存在的一篇',
    );
  });

  /// **单列闸门**（2026-09-24）：Things 式一页纸的结构事实。
  ///
  /// 钉的都是"布局一改就会立刻被抓到"的：
  /// ① 所有行**全宽等宽**（出现不等宽 = 退回 Bento 的跨列卡）；
  /// ② 行**垂直堆叠**（second 在 first 正下方、left 相同——出现并排 = 退回多列）；
  /// ③ 内容列有 [HomeHub.maxWidth] 上限（不写死：钳制后 ≤ 700）。
  testWidgets('单列：行全宽等宽、垂直堆叠，内容列不超 maxWidth', (WidgetTester tester) async {
    // 4 篇 ⇒ 日历 4 + 继续 1 + 最近头 1 + 最近 3 + 新建 2；FocusRing 顺序 = 视觉顺序。
    await pumpHub(tester, noteCount: 4);

    // ⚠️ 日历在最前占 4 个 ⇒ 继续行 = at(4)，最近行从 at(6) 起。
    final Rect hero = tester.getRect(find.byType(FocusRing).at(4));
    final Rect first = tester.getRect(find.byType(FocusRing).at(6));
    final Rect second = tester.getRect(find.byType(FocusRing).at(7));

    expect(
      hero.width,
      first.width,
      reason: '继续行与普通行不等宽 ⇒ 退回了 Bento 的"大卡跨两列"',
    );
    expect(first.width, second.width, reason: '同一列的行应当等宽');
    expect(
      second.top,
      greaterThan(first.top),
      reason: '行出现并排 ⇒ 退回了多列网格',
    );
    expect(first.left, second.left, reason: '行没有落到同一列');
    expect(
      first.width,
      lessThanOrEqualTo(HomeHub.maxWidth),
      reason: '内容列超出了 maxWidth 上限',
    );
  });

  testWidgets('折叠「最近」：头可切换，折叠时计数可见、行收起', (WidgetTester tester) async {
    await pumpHub(tester, noteCount: 3);

    // 折叠头 = 「最近」那个标题所在的 FocusRing。
    // ⚠️ **不写死下标**：日历分区在最前、且它的行同样是 FocusRing，写死
    // `at(1)` 会点到日历的行上（没点中折叠头 ⇒ 后面两条断言全不成立）。
    final Finder recentHeader = find.ancestor(
      of: find.text('最近'),
      matching: find.byType(FocusRing),
    );
    // ⚠️ 日历把主页撑高了 ⇒ 「最近」头会落到 800×600 测试视口**之外**
    // （实测 y=630 > 600）。不先滚进视口就 tap，会**打空且不报错**（只有
    // 一条 hit-test 警告）⇒ 表现为"折叠没生效"，实则根本没点到。
    await tester.ensureVisible(recentHeader);
    await tester.pumpAndSettle();
    await tester.tap(recentHeader);
    await tester.pumpAndSettle();

    // 3 篇 ⇒ 最近里有 2 篇；折叠后行收起、计数出现。
    expect(find.text('2 篇'), findsOneWidget, reason: '折叠时分组头应交代收起了几篇');
    expect(
      find.byType(FocusRing),
      // 日历 3 + 继续行 1 + 折叠头 1 + 新建 2；最近 2 行已收起。
      findsNWidgets(7),
      reason: '折叠后「最近」的行不该还挂在树上',
    );

    // 再点一次展开回来（同样先滚进视口：展开后页面又变高）。
    await tester.ensureVisible(recentHeader);
    await tester.pumpAndSettle();
    await tester.tap(recentHeader);
    await tester.pumpAndSettle();
    expect(find.byType(FocusRing), findsNWidgets(9));
  });

  test('回主页（`locateProvider.goHome`）：清空选中与待消费的跳转请求', () {
    final ProviderContainer container = newContainer();

    container.read(locateProvider.notifier).locate(noteId: 'x');
    expect(container.read(selectedNoteIdProvider), 'x');
    expect(container.read(locateProvider), isNotNull);

    container.read(locateProvider.notifier).goHome();
    expect(container.read(selectedNoteIdProvider), isNull);
    expect(container.read(locateProvider), isNull);
  });

  /// **收藏分区闸门**（2026-09-25 A 方案）：promotedAt 非空的笔记进主页
  /// 「收藏」段，且能在主页就地取消收藏（行尾星标），取消后该段消失。
  testWidgets('收藏分区：promoted 笔记出现，可就地取消收藏', (WidgetTester tester) async {
    final ProviderContainer container = await pumpHub(tester, noteCount: 2);

    // 默认无收藏 ⇒ 主页三段、无「收藏」头。
    expect(find.text('收藏'), findsNothing);

    // 收藏第一篇（与产品路径同源的 togglePromoted）。
    final Note first =
        container.read(notesProvider).value!.first;
    await container.read(notesProvider.notifier).togglePromoted(first);
    await tester.pumpAndSettle();

    expect(find.text('收藏'), findsOneWidget,
        reason: '有收藏后主页应出现「收藏」分区头');
    expect(find.byTooltip('取消收藏'), findsOneWidget,
        reason: '收藏行的行尾星标应可就地取消收藏');

    // 点星标取消收藏 ⇒ 分区消失（无收藏不出空分组头）。
    await tester.tap(find.byTooltip('取消收藏'));
    await tester.pumpAndSettle();
    expect(find.text('收藏'), findsNothing,
        reason: '取消最后一枚收藏后「收藏」分区应整体消失');
  });
}
