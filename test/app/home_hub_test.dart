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

/// 主页（2026-09-29 重做：顶栏视图切换 + 常驻搜索 + 卡片网格）的回归。
///
/// 钉的是"主页是什么"这几条结构性事实：
/// ① 顶栏 = 3 枚常驻 tab（全部/日历/收藏）+ **三点溢出菜单**（低频页面
///    笔记/画布 的入口，点了整页切换）+ 排序/标签两枚全局控件钮，默认落
///    **全部**；「更多」**不是视图**（2026-09-29 定：它只是低频页面的
///    收纳容器，[HomeView] 里没有它这一项）；
/// ② 内容 = 小卡片网格，卡片**静止态有底色**（cardFill——与列表行的
///   "显式透明"相反，卡片就该是一块浮起的板子）；
/// ③ 点卡片走 `locateProvider`（§4 唯一跳转通道）；
/// ④ 搜索框常驻顶栏，**在当前视图范围内**过滤（日历忽略搜索词）；
/// ⑤ 收藏视图可就地取消收藏；**排序方案与标签筛选不是页面**——它们是顶栏
///    右侧的两枚控件钮，对所有视图全局生效（2026-09-29 定）；
/// ⑥「全部」跨形态统一池（默认按最近编辑排序，不单设「最近」视图）；
/// ⑦ 视图历史（上一步 / 下一步）在**主区顶条**（title_bar_nav_test.dart 钉），
///    provider 语义在本文件钉。
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
      // 检索设施只读这条裸连接（内容路缺席时优雅降级，标题路照常）。
      databaseProvider.overrideWithValue(db),
    ],
  );

  /// 先建好笔记（[titles] = 普通笔记，[canvasTitles] = 画布）再挂主页。
  Future<ProviderContainer> pumpHub(
    WidgetTester tester, {
    List<String> titles = const <String>[],
    List<String> canvasTitles = const <String>[],
  }) async {
    final ProviderContainer container = newContainer();
    for (final String t in titles) {
      final Note n = await container.read(notesProvider.notifier).createNote();
      await container.read(notesProvider.notifier).saveTitle(n.id, t);
    }
    for (final String t in canvasTitles) {
      final Note n = await container
          .read(notesProvider.notifier)
          .createNote(kind: NoteKind.canvas);
      await container.read(notesProvider.notifier).saveTitle(n.id, t);
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

  /// 顶栏控件菜单里的某一项（排序 / 标签 / 三点溢出菜单）。
  ///
  /// ⚠️ 两个坑：① 菜单画在 **overlay** 里，不在页面内容树里；② **标签名会
  /// 同时出现在卡片上** ⇒ 裸 `find.text('工作法')` 撞两处，必须圈进菜单项。
  Finder menuItem(String label) => find.descendant(
    of: find.byType(PopupMenuItem<void>),
    matching: find.text(label),
  );

  testWidgets('默认落全部视图：3 枚 tab + 三点菜单 + 排序控件 + 卡片网格', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await pumpHub(
      tester,
      titles: <String>['甲', '乙'],
    );

    expect(container.read(homeViewProvider).view, HomeView.all);
    // 常驻 tab 只剩高频三枚——「更多」不是视图，是三点溢出菜单。
    for (final String t in <String>['全部', '日历', '收藏']) {
      expect(find.text(t), findsOneWidget, reason: '顶栏必须有「$t」常驻 tab');
    }
    expect(find.byTooltip('更多页面'), findsOneWidget, reason: '三点溢出菜单');
    // 笔记 / 画布是低频页面 ⇒ 入口在三点菜单里，不是常驻 tab。
    expect(find.text('笔记'), findsNothing);
    expect(find.text('画布'), findsNothing);
    // 排序是全局控件钮（不是页面）⇒ 恒在顶栏。
    expect(find.byTooltip('排序方案'), findsOneWidget);
    // 上一步 / 下一步在主区顶条，不在 HomeHub 顶栏里。
    expect(find.byTooltip('上一步'), findsNothing);
    expect(find.byTooltip('下一步'), findsNothing);
    expect(find.text('搜索标题与内容'), findsOneWidget, reason: '常驻搜索框（hint）');
    expect(find.text('甲'), findsOneWidget);
    expect(find.text('乙'), findsOneWidget);
    // 空白新笔记给可读兜底。
    expect(find.text('（空白）'), findsNWidgets(2));
    // 键盘可达（§5.2）：3 枚 tab + 2 张卡片接 FocusRing（三点 / 排序 / 标签是
    // IconButton，走各自焦点环，不挂 FocusRing）。
    expect(find.byType(FocusRing), findsNWidgets(5));
  });

  testWidgets('空库：全部视图给指路文案，tab 照常', (WidgetTester tester) async {
    await pumpHub(tester);
    expect(find.text('还没有笔记或画布'), findsOneWidget);
    // 空库只剩 3 枚 tab 是交互件（箭头禁用不进交互链）。
    expect(find.byType(FocusRing), findsNWidgets(3));
  });

  testWidgets('三点菜单进画布：整页切换，只看画布形态，笔记被滤掉', (WidgetTester tester) async {
    final ProviderContainer container = await pumpHub(
      tester,
      titles: <String>['甲'],
      canvasTitles: <String>['乙画布'],
    );

    // 「更多」= 顶栏三点溢出菜单（**不是视图**）：菜单里列出的都是整页。
    await tester.tap(find.byTooltip('更多页面'));
    await tester.pumpAndSettle();
    await tester.tap(menuItem('画布'));
    await tester.pumpAndSettle();

    expect(container.read(homeViewProvider).view, HomeView.canvas);
    // 进了低频页 ⇒ 顶栏**临时长出**该页的 tab（"我在哪个视图"的着落）。
    expect(find.text('画布'), findsOneWidget, reason: '低频页进入后应有自己的 tab');
    expect(find.text('乙画布'), findsOneWidget);
    expect(find.text('甲'), findsNothing, reason: '笔记视图的东西不该混进画布');
  });

  testWidgets('「全部」视图：笔记 + 画布跨形态同一池', (WidgetTester tester) async {
    final ProviderContainer container = await pumpHub(
      tester,
      titles: <String>['甲'],
      canvasTitles: <String>['乙画布'],
    );

    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();

    expect(container.read(homeViewProvider).view, HomeView.all);
    expect(find.text('甲'), findsOneWidget);
    expect(find.text('乙画布'), findsOneWidget, reason: '全部不分笔记与画布');
  });

  testWidgets('点卡片进入该笔记：走 locateProvider（唯一跳转通道）', (WidgetTester tester) async {
    final ProviderContainer container = await pumpHub(
      tester,
      titles: <String>['甲'],
    );

    expect(container.read(selectedNoteIdProvider), isNull, reason: '主页 = 未选中');

    await tester.tap(find.text('甲'));
    await tester.pumpAndSettle();

    final String? selected = container.read(selectedNoteIdProvider);
    expect(selected, isNotNull, reason: '点了卡片却没有选中笔记');
    expect(
      notes.allNotes().map((Note n) => n.id).toList(),
      contains(selected),
      reason: '选中的必须是库里真实存在的一篇',
    );
  });

  testWidgets('卡片静止态有底色 cardFill（不许透明）', (WidgetTester tester) async {
    await pumpHub(tester, titles: <String>['甲']);

    final Material card = tester.widget<Material>(
      find.ancestor(of: find.text('甲'), matching: find.byType(Material)).first,
    );
    expect(
      card.color,
      AppTheme.cardFill(Brightness.light),
      reason: '卡片是一块浮起的板子——静止态就该有底色（与列表行的透明相反）',
    );
  });

  testWidgets('搜索在当前视图范围内过滤；清空钮撤词', (WidgetTester tester) async {
    await pumpHub(tester, titles: <String>['甲'], canvasTitles: <String>['乙画布']);

    // 进「笔记」视图（经三点菜单）：搜「乙」命中的是画布 ⇒ 超出当前范围，
    // 视图内无结果。
    await tester.tap(find.byTooltip('更多页面'));
    await tester.pumpAndSettle();
    await tester.tap(menuItem('笔记'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '乙');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('没有与「乙」匹配的结果'), findsOneWidget);

    // 切画布视图（同一个词还在）：命中范围内的画布。
    await tester.tap(find.byTooltip('更多页面'));
    await tester.pumpAndSettle();
    await tester.tap(menuItem('画布'));
    await tester.pumpAndSettle();
    expect(find.text('乙画布'), findsOneWidget);

    // 清空（Esc 钮）⇒ 撤词，回到视图默认内容。
    await tester.tap(find.byTooltip('清空（Esc）'));
    await tester.pumpAndSettle();
    expect(find.text('乙画布'), findsOneWidget);
    expect(find.text('甲'), findsNothing, reason: '还在画布视图，笔记不该出现');
  });

  testWidgets('日历视图：月网格照常，且忽略搜索词', (WidgetTester tester) async {
    await pumpHub(tester, titles: <String>['甲']);

    await tester.enterText(find.byType(TextField), '不存在的词');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();

    final DateTime now = DateTime.now();
    expect(find.text('${now.year} 年 ${now.month} 月'), findsOneWidget);
    expect(
      find.text('没有与「不存在的词」匹配的结果'),
      findsNothing,
      reason: '日历回答"哪天写过什么"，不吃搜索词',
    );

    // 默认选中今天，「甲」（今天新建）以**卡片**出现在卡片网格里
    // （2026-09-29 用户定：篇目不再用列表行）。
    expect(find.text('甲'), findsOneWidget);
    expect(find.byType(GridView), findsOneWidget);
  });

  testWidgets('日历「写日记」只落今天：点选别天不改变新建日期', (WidgetTester tester) async {
    final ProviderContainer container = await pumpHub(
      tester,
      titles: <String>['甲'],
    );

    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();

    // 点选 15 号回看（任何月份都有 15 号，且不会与相邻月补位重号）。
    await tester.tap(find.text('15'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('写日记'));
    await tester.pumpAndSettle();

    // 新建的是无标题那篇（库里唯一非「甲」的篇目）。
    final Note created = container
        .read(notesProvider)
        .value!
        .firstWhere((Note n) => n.title.isEmpty);
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    expect(
      !created.createdAt.isBefore(today) &&
          created.createdAt.isBefore(today.add(const Duration(days: 1))),
      isTrue,
      reason:
          '写日记只写今天（实际 ${created.createdAt}）——点选日只用于回看，'
          '不得盖住新建日期',
    );
  });

  testWidgets('收藏视图：只出 promoted，可就地取消收藏', (WidgetTester tester) async {
    final ProviderContainer container = await pumpHub(
      tester,
      titles: <String>['甲', '乙'],
    );

    // createNote 新笔记置顶 ⇒ 按标题找，别按下标猜。
    final Note jia = container
        .read(notesProvider)
        .value!
        .firstWhere((Note n) => n.title == '甲');
    await container.read(notesProvider.notifier).togglePromoted(jia);
    await tester.pumpAndSettle();

    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();

    // 只有被收藏的那篇出现，且带就地取消入口。
    expect(find.text('甲'), findsOneWidget);
    expect(find.text('乙'), findsNothing);
    expect(find.byTooltip('取消收藏'), findsOneWidget);

    await tester.tap(find.byTooltip('取消收藏'));
    await tester.pumpAndSettle();
    expect(find.text('还没有收藏'), findsOneWidget);
    expect(notes.noteById(jia.id)!.promotedAt, isNull, reason: '点星标必须真的落库取消收藏');
  });

  /// **排序 / 标签是顶栏全局控件**（2026-09-29 定）：它们不是页面，改排序
  /// 不必先去任何低频页；标签筛选对**当前视图**生效（跨形态一套池）。
  testWidgets('排序菜单 + 标签菜单：点选过滤（跨形态一套池）', (WidgetTester tester) async {
    // 默认 800 宽下最后一枚 tab 贴着右侧搜索框（tab 区可横滚），命中不稳——
    // 加宽测试表面让整排 tab 从容露出再点。
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ProviderContainer container = await pumpHub(
      tester,
      titles: <String>['甲', '乙'],
    );

    // createNote 新笔记置顶 ⇒ 按标题找，别按下标猜。
    final Note jia = container
        .read(notesProvider)
        .value!
        .firstWhere((Note n) => n.title == '甲');
    await container.read(notesProvider.notifier).saveTags(jia.id, <String>[
      '工作法',
    ]);
    await tester.pumpAndSettle();

    // ① 排序：顶栏控件钮 ⇒ 三枚方案都在菜单里。**不必**先去某个「更多」页。
    await tester.tap(find.byTooltip('排序方案'));
    await tester.pumpAndSettle();
    expect(find.text('最近编辑'), findsOneWidget);
    expect(find.text('最近创建'), findsOneWidget);
    expect(find.text('标题 A–Z'), findsOneWidget);
    // 点一枚（选默认的，不改变排序）⇒ 菜单关闭。
    await tester.tap(menuItem('最近编辑'));
    await tester.pumpAndSettle();
    expect(container.read(homeSortProvider), NoteSort.revised);

    // ② 标签：同款控件钮 ⇒ 菜单里是带篇数的标签。
    expect(find.byTooltip('标签筛选'), findsOneWidget, reason: '有标签 ⇒ 钮要出现');
    await tester.tap(find.byTooltip('标签筛选'));
    await tester.pumpAndSettle();
    expect(menuItem('工作法'), findsOneWidget);
    await tester.tap(menuItem('工作法'));
    await tester.pumpAndSettle();
    expect(find.text('甲'), findsOneWidget);
    expect(find.text('乙'), findsNothing, reason: '无标签的那篇必须被筛掉');
    // 已选标签 ⇒ 菜单里给一枚显式的"清除"。
    await tester.tap(find.byTooltip('标签筛选'));
    await tester.pumpAndSettle();
    expect(menuItem('全部标签（清除筛选）'), findsOneWidget);
    await tester.tap(menuItem('全部标签（清除筛选）'));
    await tester.pumpAndSettle();
    expect(find.text('乙'), findsOneWidget, reason: '清除后无标签的那篇回来');
  });

  testWidgets('排序方案写入 homeSortProvider，且切视图后保留（顶栏控件）', (
    WidgetTester tester,
  ) async {
    // 同上：加宽测试表面，让整排 tab 从容露出。
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ProviderContainer container = await pumpHub(
      tester,
      titles: <String>['甲'],
    );

    expect(
      container.read(homeSortProvider),
      NoteSort.revised,
      reason: '默认最近编辑',
    );

    // 排序在**顶栏** ⇒ 改排序不必先去任何低频页（2026-09-29 定）。
    await tester.tap(find.byTooltip('排序方案'));
    await tester.pumpAndSettle();
    await tester.tap(menuItem('标题 A–Z'));
    await tester.pumpAndSettle();
    expect(container.read(homeSortProvider), NoteSort.title);

    // 对全部 / 收藏 / 笔记 / 画布**全局生效**：切走再回，选中不丢。
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('排序方案'));
    await tester.pumpAndSettle();
    expect(container.read(homeSortProvider), NoteSort.title);
    // 无标签库 ⇒ 标签控件钮**整枚收起**（不再有"还没有标签"的空态指路）。
    expect(find.byTooltip('标签筛选'), findsNothing);
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

  test('homeViewProvider：默认全部，select 入栈、goBack/goForward 重做', () {
    final ProviderContainer container = newContainer();
    expect(container.read(homeViewProvider).view, HomeView.all);

    final HomeViewNotifier nav = container.read(homeViewProvider.notifier);
    nav.select(HomeView.notes);
    expect(container.read(homeViewProvider).view, HomeView.notes);
    // 可用态在 **state** 里（[HomeNavState]）⇒ 从 provider 读，不是 notifier
    // 的公开 getter（`riverpod_lint` 禁后者，且它拿不到重建通知）。
    expect(container.read(homeViewProvider).canGoBack, isTrue);
    expect(container.read(homeViewProvider).canGoForward, isFalse);

    // 第二个视图用「画布」（低频页）——枚举里已无 `HomeView.filter`：
    // 「更多」是容器不是视图（2026-09-29 定）。
    nav.select(HomeView.canvas);
    expect(container.read(homeViewProvider).view, HomeView.canvas);

    nav.goBack();
    expect(container.read(homeViewProvider).view, HomeView.notes);
    nav.goBack();
    expect(container.read(homeViewProvider).view, HomeView.all);
    expect(container.read(homeViewProvider).canGoBack, isFalse, reason: '退到底了');

    nav.goForward();
    expect(container.read(homeViewProvider).view, HomeView.notes);
    nav.goForward();
    expect(container.read(homeViewProvider).view, HomeView.canvas);
    expect(
      container.read(homeViewProvider).canGoForward,
      isFalse,
      reason: '进到底了',
    );

    // 新导航清空前进栈。
    nav.select(HomeView.calendar);
    expect(container.read(homeViewProvider).canGoForward, isFalse);
  });
}
