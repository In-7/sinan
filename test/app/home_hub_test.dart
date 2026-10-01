import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/home_hub.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/canvas/kernel/canvas_painters.dart';
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
/// ④ 搜索框常驻顶栏；**一输入就切到全局搜索结果态**——跨笔记/画布、覆盖
///    任何 tab（含日历），撤词回到原视图（2026-09-30 定）；
/// ⑤ 收藏视图可就地取消收藏；**排序方案与标签筛选不是页面**——它们合住顶栏
///    右侧一枚「筛选与排序」漏斗钮（一个菜单：上半排序、下半标签），对所有
///    视图全局生效（2026-09-30 合并）；
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
  /// [canvasContentByTitle]：标题 → 画布存档 JSON，建完直接写 content
  /// （缩略图 provider 按 content 懒解析）；空画布不用传。
  Future<ProviderContainer> pumpHub(
    WidgetTester tester, {
    List<String> titles = const <String>[],
    List<String> canvasTitles = const <String>[],
    Map<String, String> canvasContentByTitle = const <String, String>{},
  }) async {
    final ProviderContainer container = newContainer();
    bool touchedCanvasContent = false;
    for (final String t in titles) {
      final Note n = await container.read(notesProvider.notifier).createNote();
      await container.read(notesProvider.notifier).saveTitle(n.id, t);
    }
    for (final String t in canvasTitles) {
      final Note n = await container
          .read(notesProvider.notifier)
          .createNote(kind: NoteKind.canvas);
      await container.read(notesProvider.notifier).saveTitle(n.id, t);
      final String? content = canvasContentByTitle[t];
      if (content != null) {
        db.execute('UPDATE notes SET content = ? WHERE id = ?', <Object?>[
          content,
          n.id,
        ]);
        touchedCanvasContent = true;
      }
    }
    // 建完笔记后才补的 content 要让列表快照重读一次（contentHash 随之变）。
    if (touchedCanvasContent) container.invalidate(notesProvider);
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

    expect(container.read(navHistoryProvider).view, HomeView.all);
    // 常驻 tab 只剩高频三枚——「更多」不是视图，是三点溢出菜单。
    for (final String t in <String>['全部', '日历', '收藏']) {
      expect(find.text(t), findsOneWidget, reason: '顶栏必须有「$t」常驻 tab');
    }
    expect(find.byTooltip('更多页面'), findsOneWidget, reason: '三点溢出菜单（图标+文字标签钮）');
    expect(find.text('更多'), findsOneWidget, reason: '⋯ 光标读不出入口，必须带文字');
    // 笔记 / 画布是低频页面 ⇒ 入口在三点菜单里，不是常驻 tab。
    expect(find.text('笔记'), findsNothing);
    expect(find.text('画布'), findsNothing);
    // 筛选与排序是一枚全局控件钮（不是页面）⇒ 恒在顶栏。
    expect(find.byTooltip('筛选与排序'), findsOneWidget);
    // 上一步 / 下一步在主区顶条，不在 HomeHub 顶栏里。
    expect(find.byTooltip('上一步'), findsNothing);
    expect(find.byTooltip('下一步'), findsNothing);
    expect(find.text('搜索标题与内容'), findsOneWidget, reason: '常驻搜索框（hint）');
    expect(find.text('甲'), findsOneWidget);
    expect(find.text('乙'), findsOneWidget);
    // 空白新笔记给可读兜底。
    expect(find.text('（空白）'), findsNWidgets(2));
    // 键盘可达（§5.2）：3 枚 tab + 三点菜单钮 + 2 张卡片接 FocusRing
    // （筛选器是 IconButton，走自身焦点环，不挂 FocusRing）。
    expect(find.byType(FocusRing), findsNWidgets(6));
  });

  testWidgets('空库：全部视图给指路文案，tab 照常', (WidgetTester tester) async {
    await pumpHub(tester);
    expect(find.text('还没有笔记或画布'), findsOneWidget);
    // 空库只剩 3 枚 tab + 三点菜单钮是 FocusRing 交互件。
    expect(find.byType(FocusRing), findsNWidgets(4));
  });

  testWidgets('无标题卡片借正文首行当标题；摘要吃余下行，不落「（空白）」', (WidgetTester tester) async {
    final ProviderContainer container = await pumpHub(tester);
    final Note n = await container.read(notesProvider.notifier).createNote();
    await container
        .read(notesProvider.notifier)
        .saveContent(
          n.id,
          '会议纪要：定了三件事',
          plainText: '会议纪要：定了三件事\n第一件是时间表\n第二件是分工',
        );
    await tester.pumpAndSettle();

    expect(find.text('会议纪要：定了三件事'), findsOneWidget, reason: '首行站标题位');
    expect(
      find.text('第一件是时间表\n第二件是分工'),
      findsOneWidget,
      reason: '摘要从余下行起，不重复首行',
    );
    expect(find.text('无标题'), findsNothing, reason: '有正文就不该再叫无标题');
    expect(find.text('（空白）'), findsNothing, reason: '有内容的卡片不放假占位');
  });

  testWidgets('标题 + 正文齐全的卡片：标题照旧，摘要是全部正文', (WidgetTester tester) async {
    final ProviderContainer container = await pumpHub(tester);
    final Note n = await container.read(notesProvider.notifier).createNote();
    await container.read(notesProvider.notifier).saveTitle(n.id, '周报');
    await container
        .read(notesProvider.notifier)
        .saveContent(n.id, '本周写完了主页', plainText: '本周写完了主页');
    await tester.pumpAndSettle();

    expect(find.text('周报'), findsOneWidget);
    expect(find.text('本周写完了主页'), findsOneWidget);
    expect(find.text('（空白）'), findsNothing);
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

    expect(container.read(navHistoryProvider).view, HomeView.canvas);
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

    expect(container.read(navHistoryProvider).view, HomeView.all);
    expect(find.text('甲'), findsOneWidget);
    expect(find.text('乙画布'), findsOneWidget, reason: '全部不分笔记与画布');
  });

  testWidgets('画布卡：有内容渲染几何缩略图，空画布落形状水印（不再显示「空白」）', (WidgetTester tester) async {
    final CanvasController controller = CanvasController();
    controller.document.addItem(
      ShapeItem(
        id: 'sh1',
        rect: const Rect.fromLTRB(0, 0, 100, 80),
        kind: CanvasShapeKind.rectangle,
        color: const Color(0xFF1F1F1F),
      ),
    );
    final String content = jsonEncode(controller.toJson());
    controller.dispose();

    await pumpHub(
      tester,
      canvasTitles: <String>['图形画布', '空画布'],
      canvasContentByTitle: <String, String>{'图形画布': content},
    );

    // 有 item 的画布卡：内核 ItemPainter 上台（真实几何 fit 绘制）。
    expect(
      find.byWidgetPredicate(
        (Widget w) => w is CustomPaint && w.painter is ItemPainter,
      ),
      findsOneWidget,
      reason: '有 item 的画布卡必须渲染几何缩略图',
    );
    // 空画布：淡形状水印居中（tabler Shape2），不是一片死白。
    expect(
      find.byWidgetPredicate(
        (Widget w) => w.runtimeType.toString() == 'Shape2',
      ),
      findsOneWidget,
      reason: '空画布落形状图标水印',
    );
    // 两种画布卡都不再借笔记卡的「（空白）」文案。
    expect(find.text('（空白）'), findsNothing);
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

  testWidgets('搜索跨形态：笔记视图里也能搜到画布；清空撤词回原视图', (WidgetTester tester) async {
    await pumpHub(tester, titles: <String>['甲'], canvasTitles: <String>['乙画布']);

    // 进「笔记」视图（经三点菜单）：搜「乙」命中的是画布。搜索是**全局**
    // 意图（2026-09-30 定）⇒ 不被当前 tab 收窄，画布照样出现在结果里。
    await tester.tap(find.byTooltip('更多页面'));
    await tester.pumpAndSettle();
    await tester.tap(menuItem('笔记'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '乙');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('1 条结果'), findsOneWidget);
    expect(find.text('乙画布'), findsOneWidget, reason: '搜索跨形态，画布不能被笔记 tab 挡掉');

    // 搜索态里切 tab 也不撤词——看到的仍是同一份全局结果。
    await tester.tap(find.byTooltip('更多页面'));
    await tester.pumpAndSettle();
    await tester.tap(menuItem('画布'));
    await tester.pumpAndSettle();
    expect(find.text('1 条结果'), findsOneWidget);
    expect(find.text('乙画布'), findsOneWidget);

    // 清空（Esc 钮）⇒ 撤词，回到画布视图本身：只见画布。
    await tester.tap(find.byTooltip('清空（Esc）'));
    await tester.pumpAndSettle();
    expect(find.text('乙画布'), findsOneWidget);
    expect(find.text('甲'), findsNothing, reason: '撤词后回到画布视图，笔记不该出现');
    expect(find.text('1 条结果'), findsNothing, reason: '结果栏随搜索态一起撤');
  });

  testWidgets('搜索态覆盖日历：日历 tab 下输入显示全局结果，撤词回月网格', (WidgetTester tester) async {
    await pumpHub(tester, titles: <String>['甲']);

    // 先在日历，再输入（搜索与 tab 无关，谁先谁后都一样）。
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '甲');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // 月网格被搜索结果态盖掉，不再回答"哪天"。
    final DateTime now = DateTime.now();
    expect(find.text('${now.year} 年 ${now.month} 月'), findsNothing);
    expect(find.text('1 条结果'), findsOneWidget);
    // 「甲」两处：搜索框回显 + 结果卡片标题。
    expect(find.text('甲'), findsNWidgets(2));
    expect(find.byType(GridView), findsOneWidget, reason: '搜索结果网格在场');

    // 撤词 ⇒ 月网格原样回来。
    await tester.tap(find.byTooltip('清空（Esc）'));
    await tester.pumpAndSettle();
    expect(find.text('${now.year} 年 ${now.month} 月'), findsOneWidget);
  });

  testWidgets('无匹配：结果栏在，内容区给明确空态（不是一片空网格）', (WidgetTester tester) async {
    await pumpHub(tester, titles: <String>['甲']);

    await tester.enterText(find.byType(TextField), '不存在的词');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('没有与「不存在的词」匹配的结果'), findsOneWidget);
    expect(find.byType(GridView), findsNothing, reason: '零结果不该渲染空网格');
  });

  testWidgets('搜索结果卡片：摘要吃命中片段，查询词高亮', (WidgetTester tester) async {
    final ProviderContainer container = await pumpHub(
      tester,
      titles: <String>['速记'],
    );
    final Note note = container
        .read(notesProvider)
        .value!
        .firstWhere((Note n) => n.title == '速记');
    // 内容路的 FTS 建在 blocks 投影上（纯文本 content 过不了格式门闩）⇒
    // 直插一个段落块并同步关键词索引（同 search_test 的 seedContent）。
    const String body = '今天在会议室聊了量子计算的落地节奏';
    db.execute(
      'INSERT INTO blocks (id, note_id, type, props_json, ord, parent_id, '
      'created_at, updated_at, fingerprint) '
      "VALUES (?, ?, 'paragraph', ?, 1024, NULL, 0, 0, 'fp-test')",
      <Object?>[note.id, note.id, '{"text":"$body"}'],
    );
    IndexJob(db: db).indexNoteKeywordPath(note.id);

    await tester.enterText(find.byType(TextField), '量子计算');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('1 条结果'), findsOneWidget);

    // 摘要位的 RichText 同时含上下文（会议室）与命中词——证明内容路 snippet
    // 真的渲染到了卡片上，而不是只显示默认前三行（本例两者同文，故再钉高亮）。
    final Finder bodyRich = find.byWidgetPredicate((Widget w) {
      if (w is! RichText) return false;
      final String t = w.text.toPlainText();
      return t.contains('量子计算') && t.contains('会议室');
    });
    expect(bodyRich, findsWidgets, reason: '命中片段进了摘要位');

    bool highlighted = false;
    void walk(InlineSpan span) {
      if (span is TextSpan) {
        if (span.text == '量子计算' && span.style?.fontWeight == FontWeight.w700) {
          highlighted = true;
        }
        span.children?.forEach(walk);
      }
    }

    for (final Element e in bodyRich.evaluate()) {
      walk((e.widget as RichText).text);
    }
    expect(highlighted, isTrue, reason: '命中词必须披主题色加粗高亮');
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

  /// **筛选器是顶栏全局控件**（2026-09-30 合并）：排序与标签同住一个菜单
  /// （上半排序、下半标签），改排序不必先去任何低频页；标签筛选对**当前
  /// 视图**生效（跨形态一套池）。
  testWidgets('筛选菜单：上半排序、下半标签，点选过滤（跨形态一套池）', (WidgetTester tester) async {
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

    final Finder filterButton = find.byTooltip('筛选与排序');

    // ① 一个菜单里同时有排序段和标签段（分段标题各一枚）。
    await tester.tap(filterButton);
    await tester.pumpAndSettle();
    expect(find.text('排序'), findsOneWidget, reason: '排序分段标题');
    expect(find.text('标签'), findsOneWidget, reason: '有标签 ⇒ 标签段出现');
    expect(find.text('最近编辑'), findsOneWidget);
    expect(find.text('最近创建'), findsOneWidget);
    expect(find.text('标题 A–Z'), findsOneWidget);

    // 落位（2026-10-01 修复）：菜单**右缘对齐漏斗钮、顶边贴按钮底边**。
    // 旧锚点是按钮左下角的零宽度矩形，菜单向右放不下时被框架吸到屏幕右缘，
    // 整体甩开按钮很远（用户实测"面板离搜索按钮很远"）。
    // showMenu 的内容是框架私有 _PopupMenu<void>，按运行时类型名定位。
    final Rect btnRect = tester.getRect(filterButton);
    final Finder popup = find.byWidgetPredicate(
      (Widget w) => w.runtimeType.toString() == '_PopupMenu<void>',
    );
    expect(popup, findsOneWidget);
    final Rect menuRect = tester.getRect(popup);
    expect(
      menuRect.right,
      closeTo(btnRect.right, 2),
      reason: '菜单右缘应与漏斗钮对齐，而不是甩到窗口边缘',
    );
    expect(menuRect.top, closeTo(btnRect.bottom, 2), reason: '菜单顶边应贴着按钮底边');
    // 点一枚排序（选默认的，不改变排序）⇒ 菜单关闭。
    await tester.tap(menuItem('最近编辑'));
    await tester.pumpAndSettle();
    expect(container.read(homeSortProvider), NoteSort.revised);

    // ② 标签在**同一枚钮**的下半段：带篇数，点选即过滤。
    await tester.tap(filterButton);
    await tester.pumpAndSettle();
    expect(menuItem('工作法'), findsOneWidget);
    await tester.tap(menuItem('工作法'));
    await tester.pumpAndSettle();
    expect(find.text('甲'), findsOneWidget);
    expect(find.text('乙'), findsNothing, reason: '无标签的那篇必须被筛掉');
    // 已选标签 ⇒ 菜单里给一枚显式的"清除"。
    await tester.tap(filterButton);
    await tester.pumpAndSettle();
    expect(menuItem('全部标签（清除筛选）'), findsOneWidget);
    await tester.tap(menuItem('全部标签（清除筛选）'));
    await tester.pumpAndSettle();
    expect(find.text('乙'), findsOneWidget, reason: '清除后无标签的那篇回来');
  });

  testWidgets('排序方案写入 homeSortProvider，且切视图后保留（顶栏筛选器）', (
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

    // 排序在**顶栏筛选器**里 ⇒ 改排序不必先去任何低频页。
    await tester.tap(find.byTooltip('筛选与排序'));
    await tester.pumpAndSettle();
    await tester.tap(menuItem('标题 A–Z'));
    await tester.pumpAndSettle();
    expect(container.read(homeSortProvider), NoteSort.title);

    // 对全部 / 收藏 / 笔记 / 画布**全局生效**：切走再回，选中不丢。
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('筛选与排序'));
    await tester.pumpAndSettle();
    expect(container.read(homeSortProvider), NoteSort.title);
    // 无标签库 ⇒ 菜单里**没有标签段**（但筛选钮常驻，排序永远可达）。
    expect(find.text('标签'), findsNothing);
    expect(find.text('排序'), findsOneWidget);
    // 点当前方案关菜单收尾。
    await tester.tap(menuItem('标题 A–Z'));
    await tester.pumpAndSettle();
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

  test('navHistoryProvider：默认全部，selectHome 入栈、goBack/goForward 重做', () {
    final ProviderContainer container = newContainer();
    expect(container.read(navHistoryProvider).view, HomeView.all);

    final NavHistoryNotifier nav = container.read(navHistoryProvider.notifier);
    nav.selectHome(HomeView.notes);
    expect(container.read(navHistoryProvider).view, HomeView.notes);
    // 可用态在 **state** 里（[NavHistoryState]）⇒ 从 provider 读，不是 notifier
    // 的公开 getter（`riverpod_lint` 禁后者，且它拿不到重建通知）。
    expect(container.read(navHistoryProvider).canGoBack, isTrue);
    expect(container.read(navHistoryProvider).canGoForward, isFalse);

    // 第二个视图用「画布」（低频页）——枚举里已无 `HomeView.filter`：
    // 「更多」是容器不是视图（2026-09-29 定）。
    nav.selectHome(HomeView.canvas);
    expect(container.read(navHistoryProvider).view, HomeView.canvas);

    nav.goBack();
    expect(container.read(navHistoryProvider).view, HomeView.notes);
    nav.goBack();
    expect(container.read(navHistoryProvider).view, HomeView.all);
    expect(
      container.read(navHistoryProvider).canGoBack,
      isFalse,
      reason: '退到底了',
    );

    nav.goForward();
    expect(container.read(navHistoryProvider).view, HomeView.notes);
    nav.goForward();
    expect(container.read(navHistoryProvider).view, HomeView.canvas);
    expect(
      container.read(navHistoryProvider).canGoForward,
      isFalse,
      reason: '进到底了',
    );

    // 新导航清空前进栈。
    nav.selectHome(HomeView.calendar);
    expect(container.read(navHistoryProvider).canGoForward, isFalse);
  });
}
