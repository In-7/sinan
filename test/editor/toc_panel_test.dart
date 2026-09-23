import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/editor/panels/toc_panel.dart';
import 'package:sinan/src/theme/app_theme.dart';

/// 目录面板（阶段 2 · 第 2 项）的两层验证：
/// - **抽取规则**：只收 1~3 级标题、空标题跳过、索引=顶层块索引；
/// - **当前章节判定**：只剩一条规则（视口顶之上最近的标题）——quill 时代的
///   「点击固定 / 到底兜底」两条补偿规则已随留白方案的调整删除；
/// - **渲染/点击**：条目出现在树上、点击不抛、滚动区间变化能改高亮。
void main() {
  // 文档：0 前言 / 1 H1 / 2 正文 / 3 H2 / 4 正文 / 5 H3 / 6 结尾
  Document doc() => Document(
    root: pageNode(
      children: <Node>[
        paragraphNode(text: '前言'),
        headingNode(level: 1, text: ' 第一章 '),
        paragraphNode(text: '正文一'),
        headingNode(level: 2, text: '小节'),
        paragraphNode(text: '正文二'),
        headingNode(level: 3, text: '末节'),
        paragraphNode(text: '结尾'),
      ],
    ),
  );

  group('目录条目抽取', () {
    test('只收 1~3 级、文本两端裁剪、索引=顶层块索引、路径可用于定位', () {
      final List<TocEntry> entries = tocEntriesOf(doc());

      expect(entries.map((TocEntry e) => e.text).toList(), <String>[
        '第一章',
        '小节',
        '末节',
      ]);
      expect(entries.map((TocEntry e) => e.level).toList(), <int>[1, 2, 3]);
      // 索引是**顶层块索引**（appflowy 的滚动定位按它走），不是标题序号。
      expect(entries.map((TocEntry e) => e.index).toList(), <int>[1, 3, 5]);
      expect(entries.first.path, <int>[1]);
    });

    test('4 级及以上不入目录（与 Notion/飞书一致）', () {
      final Document document = Document(
        root: pageNode(
          children: <Node>[
            headingNode(level: 1, text: '一级'),
            Node(
              type: HeadingBlockKeys.type,
              attributes: <String, dynamic>{
                HeadingBlockKeys.level: 4,
                blockComponentDelta: (Delta()..insert('四级')).toJson(),
              },
            ),
          ],
        ),
      );
      expect(
        tocEntriesOf(document).map((TocEntry e) => e.text).toList(),
        <String>['一级'],
      );
    });

    test('空标题（只有格式没有字）跳过：点一个空条目没有意义', () {
      final Document document = Document(
        root: pageNode(
          children: <Node>[
            headingNode(level: 1, text: ''),
            headingNode(level: 2, text: '   '),
            headingNode(level: 3, text: '有字'),
          ],
        ),
      );
      expect(
        tocEntriesOf(document).map((TocEntry e) => e.text).toList(),
        <String>['有字'],
      );
    });
  });

  group('当前章节判定（一条规则）', () {
    final List<TocEntry> entries = tocEntriesOf(doc());

    test('常规：视口顶部之上最近的标题', () {
      // 视口首个可见块 = 4（正文二）→ 上面最近的标题是索引 1 的「小节」。
      expect(activeTocIndex(entries: entries, visibleRange: (4, 5)), 1);
      // 视口首个可见块 = 1（第一章本身）→ 命中它。
      expect(activeTocIndex(entries: entries, visibleRange: (1, 3)), 0);
      // 视口含最后一块也一样：规则只认"视口顶部之上最近的标题"，不做
      // "到底兜底"（那条补偿规则已删，见 toc_panel.dart 的 activeTocIndex）。
      expect(activeTocIndex(entries: entries, visibleRange: (4, 6)), 1);
    });

    test('视口还在第一条标题之前 → 不高亮（-1，不做错误指示）', () {
      expect(activeTocIndex(entries: entries, visibleRange: (0, 0)), -1);
    });

    test('可见区间未知（-1）或没有标题 → -1', () {
      expect(activeTocIndex(entries: entries, visibleRange: (-1, -1)), -1);
      expect(
        activeTocIndex(entries: const <TocEntry>[], visibleRange: (0, 6)),
        -1,
      );
    });

    test('到底兜底：文档末尾已在视口里 ⇒ 当前章节 = 最后一条', () {
      // 留白是一屏（editorTrailingSpace = 600）时，末尾标题仍差一点点够不到
      // "视口顶部之上"，没有这条兜底它就**永远不会**被高亮——用户实测：点最后
      // 一条，目录里那一行没有激活底色。
      expect(
        activeTocIndex(entries: entries, visibleRange: (4, 6), endInView: true),
        entries.length - 1,
      );
      // 末尾不在视口里时，照旧走"视口顶部之上最近的标题"（不误伤）。
      expect(activeTocIndex(entries: entries, visibleRange: (4, 6)), 1);
      // 没有标题时不抛（-1）。
      expect(
        activeTocIndex(
          entries: const <TocEntry>[],
          visibleRange: (0, 0),
          endInView: true,
        ),
        -1,
      );
    });
  });

  group('跳转落点：够不到顶部就不动（tocJumpCanReachTop）', () {
    // 视口 1000、留白 = 官方口径 600 ⇒ 留白占 0.6 个视口。
    const double viewport = 1000;
    bool canReach({
      required double leadingEdge,
      double? lastBlockTrailingEdge,
      double lastVisibleTrailingEdge = 1,
      int blocksBelow = 0,
    }) => tocJumpCanReachTop(
      leadingEdge: leadingEdge,
      viewportHeight: viewport,
      trailingSpace: editorTrailingSpace,
      lastBlockTrailingEdge: lastBlockTrailingEdge,
      blocksBelow: blocksBelow,
      lastVisibleTrailingEdge: lastVisibleTrailingEdge,
    );

    test('末块可见、下方还有不止一屏 ⇒ 够得到（照常跳到顶部）', () {
      expect(
        // 末块下沿还在视口下方 0.6 屏 ⇒ 下方内容比一屏多。
        canReach(
          leadingEdge: 0.4,
          lastBlockTrailingEdge: 1.6,
          lastVisibleTrailingEdge: 1.2,
          blocksBelow: 5,
        ),
        isTrue,
      );
    });

    test('末尾已到视口里 ⇒ 够不到（这一次**不动**，只给高亮）', () {
      // 目标在视口 71% 处、下方只剩留白那 600px：官方 `jumpTo` 的"先归零、
      // 再重锚"在这里不合法，会被框架**动画**修正回来（实测
      // `-644 → 0 → … → -644`，用户描述"往上跳一下再回去"）。
      expect(
        canReach(
          leadingEdge: 0.71,
          lastBlockTrailingEdge: 0.95,
          lastVisibleTrailingEdge: 0.95,
        ),
        isFalse,
      );
    });

    test('末尾已到视口里、而目标本来就在顶部附近 ⇒ 够得到（0 位移也无妨）', () {
      expect(
        canReach(
          leadingEdge: 0.02,
          lastBlockTrailingEdge: 0.95,
          lastVisibleTrailingEdge: 0.95,
        ),
        isTrue,
      );
    });

    test('末块在视口外：下方块数够多 ⇒ 够得到；只剩一两块 ⇒ 够不到', () {
      expect(
        canReach(
          leadingEdge: 0.5,
          lastVisibleTrailingEdge: 1.3,
          blocksBelow: 40,
        ),
        isTrue,
      );
      // 只剩一块（至少一行 ≈20px）⇒ 可滚余量下界只有 0.62 屏，而目标在
      // 0.9 处，够不到顶部 ⇒ 宁可不动（靠高亮给反馈），也不要跳了还不到位。
      expect(canReach(leadingEdge: 0.9, blocksBelow: 1), isFalse);
    });

    test('视口量不到（0）⇒ 不武断拦（true）', () {
      expect(
        tocJumpCanReachTop(
          leadingEdge: 0.9,
          viewportHeight: 0,
          trailingSpace: editorTrailingSpace,
          lastBlockTrailingEdge: 0.9,
          blocksBelow: 0,
          lastVisibleTrailingEdge: 0.9,
        ),
        isTrue,
      );
    });
  });

  group('编辑器末尾留白（官方口径：固定一屏 + 可点"继续写"）', () {
    test('固定 600（别再退回"只剩呼吸"的 48）', () {
      // 2026-09-14 白天先收到 48（为消掉"滚到底滑块变短"），当天又按**官方口径**
      // 改回 600：官方 app 的 `editor_page.dart` 就是给 footer 挂固定 600 的
      // 可点热区。它买到两件事：① 点空白 = 继续写；② 距文末一屏内的块大体能
      // 滚到视口顶部（目录 `jumpTo(alignment: 0)` 的前提）。
      // 代价：它是列表里最高的项（普通段落的 20 多倍），滚到尾部时"按已构建孩子
      // 平均外推"的总高会修正一次 ⇒ 滑块略变短。这个取舍是**有意接受**的。
      // 固定值而非"视口高 − 一行"：后者随窗口高度变，会让总高估计跟着跳。
      expect(editorTrailingSpace, 600);
    });
  });

  group('面板渲染与交互', () {
    testWidgets('收起（visible: false）时冻结重建；展开后一次性补算', (
      WidgetTester tester,
    ) async {
      final EditorState state = EditorState(document: doc());
      final EditorScrollController scroll = EditorScrollController(
        editorState: state,
      );
      addTearDown(() {
        scroll.dispose();
        state.dispose();
      });
      final TextEditingController title = TextEditingController(text: '我的笔记');
      addTearDown(title.dispose);

      Widget panel({required bool visible}) => MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: AppFlowyTocPanel(
            editorState: state,
            scrollController: scroll,
            titleListenable: title,
            visible: visible,
          ),
        ),
      );

      await tester.pumpWidget(panel(visible: false));
      // 装载时仍算一次（首屏内容就绪，展开时无需等待）。
      expect(find.text('第一章'), findsOneWidget);

      // 收起期间文档加新章节 ⇒ 面板不跟随（冻结，实测这里占滚动每步
      // ~35-40% 的泵帧成本）。
      final transaction = state.transaction
        ..insertNode(<int>[
          state.document.root.children.length,
        ], headingNode(level: 1, text: '冻结期新增章节'));
      await state.apply(transaction);
      await tester.pump();
      expect(find.text('冻结期新增章节'), findsNothing);

      // 滚动位置变化同样不触发重建。
      scroll.visibleRangeNotifier.value = (2, 4);
      await tester.pump();
      expect(find.text('冻结期新增章节'), findsNothing);

      // 展开 ⇒ 一次性补算，新章节出现。
      await tester.pumpWidget(panel(visible: true));
      await tester.pumpAndSettle();
      expect(find.text('冻结期新增章节'), findsOneWidget);
    });

    testWidgets('条目上树；滚动区间变化即时改高亮', (WidgetTester tester) async {
      final EditorState state = EditorState(document: doc());
      final EditorScrollController scroll = EditorScrollController(
        editorState: state,
      );
      addTearDown(() {
        scroll.dispose();
        state.dispose();
      });
      final TextEditingController title = TextEditingController(text: '我的笔记');
      addTearDown(title.dispose);
      final ThemeData theme = AppTheme.light();

      // 视口首个可见块 = 1 → 「第一章」为当前章节。
      scroll.visibleRangeNotifier.value = (1, 4);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: AppFlowyTocPanel(
              editorState: state,
              scrollController: scroll,
              titleListenable: title,
            ),
          ),
        ),
      );

      expect(find.text('第一章'), findsOneWidget);
      expect(find.text('小节'), findsOneWidget);
      expect(find.text('末节'), findsOneWidget);
      // 激活项：中性 onSurface 文字 + onSurface @10% 底色（navSelectedTint 令牌；
      // 2026-09-11 统一中性后不再染 primary，测试口径同步）。
      expect(_colorOf(tester, '第一章'), theme.colorScheme.onSurface);
      expect(
        _containerColorOf(tester, '第一章'),
        AppTheme.navSelectedTint(theme.colorScheme.onSurface),
      );
      expect(_colorOf(tester, '小节'), theme.colorScheme.onSurfaceVariant);
      expect(_containerColorOf(tester, '小节'), isNull);

      // 滚到「小节」之后 → 高亮跟着换（滚动跟随）。
      // 区间不含最后一块，走的是常规规则。
      scroll.visibleRangeNotifier.value = (4, 5);
      await tester.pump();
      expect(_colorOf(tester, '小节'), isNot(theme.colorScheme.onSurfaceVariant));
      expect(_colorOf(tester, '第一章'), theme.colorScheme.onSurfaceVariant);
      expect(_containerColorOf(tester, '第一章'), isNull);
    });

    testWidgets('没有标题时给引导文案；点击条目不抛（滚动器未挂载时安全退出）', (WidgetTester tester) async {
      final EditorState state = EditorState(
        document: Document(
          root: pageNode(children: <Node>[paragraphNode(text: '只有正文')]),
        ),
      );
      final EditorScrollController scroll = EditorScrollController(
        editorState: state,
      );
      addTearDown(() {
        scroll.dispose();
        state.dispose();
      });

      final TextEditingController title = TextEditingController(
        text: '只有正文的笔记',
      );
      addTearDown(title.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: AppFlowyTocPanel(
              editorState: state,
              scrollController: scroll,
              titleListenable: title,
            ),
          ),
        ),
      );
      // 首条标题入口始终在；没有标题块时末尾补引导文案。
      expect(find.text('只有正文的笔记'), findsOneWidget);
      expect(find.textContaining('用「标题 1~3」组织正文'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('窄宽度不 overflow（面板宽是 0↔208 的滑出动画）', (WidgetTester tester) async {
      final EditorState state = EditorState(document: doc());
      final EditorScrollController scroll = EditorScrollController(
        editorState: state,
      );
      addTearDown(() {
        scroll.dispose();
        state.dispose();
      });
      final TextEditingController title = TextEditingController(text: '我的笔记');
      addTearDown(title.dispose);

      // 宿主用 AnimatedContainer 在 0 ↔ 208 之间做滑出动画 ⇒ 收起后/动画
      // 途中可用宽度会低到 0。这条守住"面板内容在任意宽度下都不报
      // RenderFlex overflow"——2026-09-14 编号列曾在这里踩过（面板 20px
      // 时 "overflowed by 11 pixels"：固定宽子项撑破了 Row）。
      for (final double width in <double>[0, 20, 60, 120]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: SizedBox(
                width: width,
                child: AppFlowyTocPanel(
                  editorState: state,
                  scrollController: scroll,
                  titleListenable: title,
                ),
              ),
            ),
          ),
        );
        expect(
          tester.takeException(),
          isNull,
          reason: '面板宽 $width 时不该 overflow',
        );
      }
    });
  });

  group('首条「页面标题」入口', () {
    test('构造规则：空标题回落「无标题」、裁剪空格、不参与块定位', () {
      expect(titleEntryOf('   ').text, '无标题');
      expect(titleEntryOf('  我的笔记  ').text, '我的笔记');
      expect(titleEntryOf('x').isTitle, isTrue);
      // index 固定 0（跳转回到文档开头）、path 空（不参与"点击固定"）。
      expect(titleEntryOf('x').index, 0);
      expect(titleEntryOf('x').path, isEmpty);
      // 普通标题条目不受影响。
      expect(tocEntriesOf(doc()).first.isTitle, isFalse);
    });

    test('首块标题的文字可作兜底：标题为空时用它，仍空才回落「无标题」', () {
      // 页面标题有值时以页面标题为准（首块标题不再单独成条）。
      expect(titleEntryOf('我的笔记', fallbackText: '第一章').text, '我的笔记');
      // 页面标题为空 → 用首块标题的文字（显示"无标题"却明明有标题会怪）。
      expect(titleEntryOf('   ', fallbackText: ' 第一章 ').text, '第一章');
      // 两边都没有 → 仍是「无标题」。
      expect(titleEntryOf('   ', fallbackText: '   ').text, '无标题');
    });

    testWidgets('显示标题、随标题实时更新、滚到顶部时高亮、点击不抛', (WidgetTester tester) async {
      final EditorState state = EditorState(document: doc());
      final EditorScrollController scroll = EditorScrollController(
        editorState: state,
      );
      final TextEditingController title = TextEditingController(text: '我的笔记');
      addTearDown(() {
        scroll.dispose();
        state.dispose();
        title.dispose();
      });
      final ThemeData theme = AppTheme.light();

      scroll.visibleRangeNotifier.value = (1, 4);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: AppFlowyTocPanel(
              editorState: state,
              scrollController: scroll,
              titleListenable: title,
            ),
          ),
        ),
      );

      // 不在顶部时：首条不高亮（字色更实以区别于章节），章节照常高亮。
      expect(find.text('我的笔记'), findsOneWidget);
      expect(_colorOf(tester, '我的笔记'), theme.colorScheme.onSurface);
      expect(_colorOf(tester, '第一章'), theme.colorScheme.onSurface);
      expect(
        _containerColorOf(tester, '第一章'),
        AppTheme.navSelectedTint(theme.colorScheme.onSurface),
      );

      // 标题变化 → 目录实时更新（直接监听标题控制器）。
      title.text = '改过的标题';
      await tester.pump();
      expect(find.text('改过的标题'), findsOneWidget);
      expect(find.text('我的笔记'), findsNothing);

      // 视口回到文档最顶（首个可见块 = 0）→ 首条高亮。首条文字色本就是
      // 实色 onSurface，激活的可见差异在底色（navSelectedTint）。
      scroll.visibleRangeNotifier.value = (0, 3);
      await tester.pump();
      expect(
        _containerColorOf(tester, '改过的标题'),
        AppTheme.navSelectedTint(theme.colorScheme.onSurface),
      );

      // 点击首条（滚动器未挂载时安全退出，不抛）。
      await tester.tap(find.text('改过的标题'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('首块标题与页面标题合并', () {
    testWidgets('首块是标题时目录里只出现一条（否则是同一目标的重复）', (WidgetTester tester) async {
      final EditorState state = EditorState(
        document: Document(
          root: pageNode(
            children: <Node>[
              headingNode(level: 1, text: '第一章'),
              paragraphNode(text: '正文'),
            ],
          ),
        ),
      );
      final EditorScrollController scroll = EditorScrollController(
        editorState: state,
      );
      final TextEditingController title = TextEditingController(text: '我的笔记');
      addTearDown(() {
        scroll.dispose();
        state.dispose();
        title.dispose();
      });

      scroll.visibleRangeNotifier.value = (1, 1);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: AppFlowyTocPanel(
              editorState: state,
              scrollController: scroll,
              titleListenable: title,
            ),
          ),
        ),
      );

      // 页面标题在，首块标题**不再单独出现**（合并成一条，点击目标相同）。
      expect(find.text('我的笔记'), findsOneWidget);
      expect(find.text('第一章'), findsNothing);

      // 页面标题清空 → 用首块标题的文字兜底。
      title.text = '   ';
      await tester.pump();
      expect(find.text('第一章'), findsOneWidget);
    });
  });

  group('面板高度跟随内容（无内部滚动条；超长时兜底滚动）', () {
    // 面板已于 2026-09-17 改为**高度跟随内容自适应**：
    // - 条目装得下 ⇒ 面板紧贴内容收短，**没有**滚动条（旧行为是撑满上限、
    //   底部留一大截白）；
    // - 条目装不下（标题多到超出可用高度）⇒ 内部滚动态兜底，**不能**让
    //   RenderFlex 溢出（这点由下面的用例守住：去掉兜底滚动会立刻溢出 3255px）；
    // - "激活项自动滚进可视区"（`_ensureActiveVisible`）也随之删除：条目全量
    //   构建、常态无滚动，高亮永远可见，不再需要它。
    testWidgets('短目录：面板紧贴内容收短', (WidgetTester tester) async {
      final EditorState state = EditorState(
        document: Document(
          root: pageNode(
            children: <Node>[
              for (int i = 1; i <= 3; i++) headingNode(level: 1, text: '章节 $i'),
            ],
          ),
        ),
      );
      final EditorScrollController scroll = EditorScrollController(
        editorState: state,
      );
      final TextEditingController title = TextEditingController(text: '我的笔记');
      addTearDown(() {
        scroll.dispose();
        state.dispose();
        title.dispose();
      });

      scroll.visibleRangeNotifier.value = (0, 0);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: AppFlowyTocPanel(
              editorState: state,
              scrollController: scroll,
              titleListenable: title,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 3 条 + "页面标题"首条 + 标题行：远低于测试视口 600 ⇒ 面板应被内容撑起
      // 而非铺满（旧行为会顶到 600）。
      final double panelHeight = tester
          .getSize(find.byType(AppFlowyTocPanel))
          .height;
      expect(panelHeight, lessThan(300));
      // 条目全量构建：首条标题块与"页面标题"合并成一条（点击目标相同），
      // 所以树里是「我的笔记 / 章节 2 / 章节 3」而不是 4 条。
      expect(find.text('我的笔记'), findsOneWidget);
      expect(find.text('章节 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('长目录：兜底滚动生效，不溢出（高亮仍跟随）', (WidgetTester tester) async {
      // 40 条标题：面板一屏放不下（每条 ≈27~29px，测试视口 600）。
      final EditorState state = EditorState(
        document: Document(
          root: pageNode(
            children: <Node>[
              for (int i = 1; i <= 40; i++)
                headingNode(level: 1, text: '章节 $i'),
            ],
          ),
        ),
      );
      final EditorScrollController scroll = EditorScrollController(
        editorState: state,
      );
      final TextEditingController title = TextEditingController(text: '我的笔记');
      addTearDown(() {
        scroll.dispose();
        state.dispose();
        title.dispose();
      });

      scroll.visibleRangeNotifier.value = (0, 0);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: AppFlowyTocPanel(
              editorState: state,
              scrollController: scroll,
              titleListenable: title,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 关键回归点：**没有** RenderFlex 溢出异常（去掉兜底滚动必炸）。
      expect(tester.takeException(), isNull);
      // 条目仍是全量构建（滚动态不是 ListView.builder），首尾都在树里。
      expect(find.text('章节 40'), findsOneWidget);

      // 高亮跟随正文滚动：不再有"面板自动滚过去"的行为，但条目本身还在。
      scroll.visibleRangeNotifier.value = (39, 39);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('章节 40'), findsOneWidget);
    });
  });
}

/// 取某条目录文本的渲染色（用于断言高亮）。
Color? _colorOf(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style?.color;

/// 条目容器的底色（激活项是 navSelectedTint，非激活为 null）。
Color? _containerColorOf(WidgetTester tester, String text) {
  final Container container = tester.widget<Container>(
    find.ancestor(of: find.text(text), matching: find.byType(Container)).first,
  );
  final BoxDecoration? decoration = container.decoration as BoxDecoration?;
  return decoration?.color;
}
