import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/home_screen.dart';
import 'package:sinan/src/app/note_list_column.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/editor/core/note_title_field.dart';
import 'package:sinan/src/theme/app_icon_button.dart';
import 'package:sinan/src/theme/app_split_icon_button.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/tokens.dart';
// 只取 Database / sqlite3：sqlite3 还导出一个 `Row`，与 Flutter 的 Row 撞名。
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// **列表头**的四个交互（2026-10-21 用户定，复刻 ima 的头部）：
///
/// ① 折叠钮在**内容卡左上角**，折叠（收到 0）/ 展开时**位置不变**；
/// ② 工具行右簇：搜索 / 筛选 / **新建**（新建最右，2026-11-09 用户定）；
///    折叠钮是独立左侧区域，不参与这一排；
/// ③ 点 ⌕ 展开输入框、输入即过滤；空查询时点外部可关，有词时点外部 /
///    点结果都不打断，只有关闭钮 / Esc 退出（退出即清空）；
/// ④ `+ ▾` 的箭头**能开托盘**（`MenuAnchor` 不会自动响应点击，必须由按钮自己
///    `controller.open()`——第一版漏了这步，箭头点了没反应，新建菜单 / 导入全
///    用不了，故这条测试是那次返工的闸门）。
void main() {
  void mockWindowManager(WidgetTester tester) {
    const MethodChannel channel = MethodChannel('window_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      MethodCall call,
    ) async {
      return switch (call.method) {
        'isFocused' || 'isMaximized' || 'isFullScreen' => false,
        _ => null,
      };
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
  }

  Future<ProviderContainer> pumpList(WidgetTester tester) async {
    final TestFlutterView view = tester.view;
    view.devicePixelRatio = 1;
    view.physicalSize = const Size(1200, 900);
    addTearDown(() {
      view.devicePixelRatio = 3;
      view.physicalSize = const Size(2400, 1800);
    });
    mockWindowManager(tester);

    final Database db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    final NoteStore store = NoteStore(db);
    final ProviderContainer container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        noteStoreProvider.overrideWithValue(store),
        settingsStoreProvider.overrideWithValue(SettingsStore(db)),
        appDataDirProvider.overrideWithValue(r'C:\test\sinan'),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(db.close);

    store.create(title: '甲');
    store.create(title: '乙');
    container.read(navHistoryProvider.notifier).selectHome(HomeView.notes);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light(), home: const HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Finder inList(Finder of) =>
      find.descendant(of: find.byType(NoteListColumn), matching: of);

  /// 只认 [Text]（排除输入框的 `EditableText`——搜索框里也有同样的字）。
  /// 兼容 `Text.rich`：搜索命中高亮时标题 / 摘要是 span，`data` 为 null。
  Finder listText(String s) => inList(
    find.byWidgetPredicate(
      (Widget w) =>
          w is Text && (w.data == s || (w.textSpan?.toPlainText() ?? '') == s),
    ),
  );

  testWidgets('折叠钮：折叠到 0 后仍在原坐标（位置不变）', (tester) async {
    await pumpList(tester);

    final Finder collapse = find.byTooltip('收起列表');
    expect(collapse, findsOneWidget, reason: '内容卡左上角要有折叠钮');
    final Rect before = tester.getRect(collapse);

    await tester.tap(collapse);
    await tester.pumpAndSettle();

    expect(find.byTooltip('展开列表'), findsOneWidget, reason: '折叠后钮还在');
    final Rect after = tester.getRect(find.byTooltip('展开列表'));
    expect(after.topLeft, before.topLeft, reason: '折叠 / 展开都在同一坐标——按钮位置不变');
  });

  testWidgets('搜索：点 ⌕ 展开输入框，输入即过滤，Esc 收起', (tester) async {
    await pumpList(tester);

    expect(listText('甲'), findsOneWidget);
    expect(listText('乙'), findsOneWidget);

    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    expect(inList(find.byType(TextField)), findsOneWidget, reason: '出现输入框');

    await tester.enterText(inList(find.byType(TextField)), '乙');
    await tester.pumpAndSettle();
    expect(listText('甲'), findsNothing, reason: '没命中 ⇒ 滤掉');
    expect(listText('乙'), findsOneWidget);

    // Esc ⇒ 收起并清词，列表恢复。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(inList(find.byType(TextField)), findsNothing, reason: 'Esc 收起');
    expect(listText('甲'), findsOneWidget, reason: '清词后恢复');
  });

  testWidgets('搜索：空查询时点外部即收起（安全的"取消"）', (tester) async {
    await pumpList(tester);

    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    expect(inList(find.byType(TextField)), findsOneWidget, reason: '出现输入框');

    // 收起钮**常驻**：不输入词时也要有可见的关闭入口（之前"有词才显"，
    // 无词时整排只剩 Esc 能关 ⇒ 用户实报"点开后关不掉"）。
    expect(find.byTooltip('关闭搜索'), findsOneWidget, reason: '收起钮常驻');

    // 点框**内**不该关。
    await tester.tap(inList(find.byType(TextField)));
    await tester.pumpAndSettle();
    expect(inList(find.byType(TextField)), findsOneWidget, reason: '点框内不该关');

    // **空查询**时点外部（列表列以外、编辑区空白）⇒ 收起（"取消"语义）。
    await tester.tapAt(const Offset(600, 500));
    await tester.pumpAndSettle();
    expect(inList(find.byType(TextField)), findsNothing, reason: '空查询点外部收起');
    expect(listText('甲'), findsOneWidget, reason: '列表恢复');
  });

  testWidgets('搜索：有词时点外部 / 点结果都不关，只有关闭钮才关且清空', (tester) async {
    final ProviderContainer container = await pumpList(tester);

    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(inList(find.byType(TextField)), '乙');
    await tester.pumpAndSettle();
    expect(listText('甲'), findsNothing, reason: '过滤生效');
    expect(listText('乙'), findsOneWidget);

    // ① 有词时点外部（编辑区空白）⇒ **不关**（保护已进行的搜索态）。
    await tester.tapAt(const Offset(600, 500));
    await tester.pumpAndSettle();
    expect(
      inList(find.byType(TextField)),
      findsOneWidget,
      reason: '有词时点外部不关（2026-10-28 用户定）',
    );

    // ② 点结果 ⇒ 打开对应笔记，搜索框**仍在**、词仍在、列表仍过滤。
    final String targetId = container
        .read(notesProvider)
        .value!
        .firstWhere((e) => e.title == '乙')
        .id;
    await tester.tap(listText('乙'));
    await tester.pumpAndSettle();
    expect(
      container.read(selectedNoteIdProvider),
      targetId,
      reason: '点结果打开对应笔记',
    );
    expect(inList(find.byType(TextField)), findsOneWidget, reason: '点结果不打断搜索');
    expect(listText('甲'), findsNothing, reason: '词保留 ⇒ 仍过滤');

    // ③ 关闭钮 ⇒ 关闭并清空。
    await tester.tap(find.byTooltip('关闭搜索'));
    await tester.pumpAndSettle();
    expect(inList(find.byType(TextField)), findsNothing, reason: '关闭钮关掉');
    expect(listText('甲'), findsOneWidget, reason: '清空后列表恢复');
  });

  testWidgets('搜索：收起钮能关（无词时也有效）', (tester) async {
    await pumpList(tester);

    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('关闭搜索'));
    await tester.pumpAndSettle();
    expect(inList(find.byType(TextField)), findsNothing, reason: '收起钮能关');
  });

  testWidgets('搜索增强：命中计数 + ↑/↓ 移动 + Enter 打开', (tester) async {
    final ProviderContainer container = await pumpList(tester);

    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();

    // 未过滤 ⇒ 计数 = 全部条数（2 条）。
    expect(inList(find.text('2 条')), findsOneWidget, reason: '计数要显示命中条数');

    // 过滤到唯一命中 ⇒ 计数变 1。
    await tester.enterText(inList(find.byType(TextField)), '乙');
    await tester.pumpAndSettle();
    expect(inList(find.text('1 条')), findsOneWidget, reason: '计数随后更新');

    // ↓ 进入高亮 → Enter 打开该行。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    final String targetId = container
        .read(notesProvider)
        .value!
        .firstWhere((e) => e.title == '乙')
        .id;
    expect(
      container.read(selectedNoteIdProvider),
      targetId,
      reason: 'Enter 要打开键盘高亮的那条',
    );
    expect(
      inList(find.byType(TextField)),
      findsOneWidget,
      reason: 'Enter 打开笔记不打断搜索态',
    );
  });

  testWidgets('搜索增强：关闭后焦点回「⌕」钮', (tester) async {
    await pumpList(tester);

    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('关闭搜索'));
    await tester.pumpAndSettle();

    final Iterable<Focus> focuses = tester.widgetList<Focus>(
      find.descendant(of: find.byTooltip('搜索'), matching: find.byType(Focus)),
    );
    expect(
      focuses.any((Focus f) => f.focusNode?.hasFocus ?? false),
      isTrue,
      reason: '关闭后焦点要回到「⌕」钮（键盘用户不用再 Tab 一圈）',
    );
  });

  testWidgets('搜索增强：命中片段高亮成主色', (tester) async {
    await pumpList(tester);

    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(inList(find.byType(TextField)), '乙');
    await tester.pumpAndSettle();

    final Color primary = AppTheme.light().colorScheme.primary;
    final bool hasHit = tester.widgetList<Text>(inList(find.byType(Text))).any((
      Text t,
    ) {
      bool found = false;
      t.textSpan?.visitChildren((InlineSpan span) {
        if (span is TextSpan &&
            span.text == '乙' &&
            span.style?.color == primary) {
          found = true;
        }
        return !found;
      });
      return found;
    });
    expect(hasHit, isTrue, reason: '命中片段要用主色高亮');
  });

  testWidgets('新建：点 + 直建当前页类型（笔记页建笔记）', (tester) async {
    final ProviderContainer container = await pumpList(tester);
    final int before = container.read(notesProvider).value!.length;

    await tester.tap(find.byTooltip('新建'));
    await tester.pumpAndSettle();

    expect(
      container.read(notesProvider).value!.length,
      before + 1,
      reason: '新建一篇',
    );
    expect(container.read(selectedNoteIdProvider), isNotNull);
  });

  testWidgets('头部标尺：与编辑页撤销 / 重做同一 y、同一 30 热区', (tester) async {
    // 2026-10-22 用户定：列表顶部按钮的**位置与大小**要和编辑页头部那排一致
    // （上留白 5 + 热区 30 + 图标 20）。先开一篇笔记让编辑器渲染出撤销钮，
    // 再逐个比矩形——纯肉眼对齐很难看出 2px 差。
    final ProviderContainer container = await pumpList(tester);
    container
        .read(locateProvider.notifier)
        .locate(noteId: container.read(notesProvider).value!.first.id);
    await tester.pumpAndSettle();

    // **带高锚点**（2026-10-22 热区 30→28 时最怕断的那一根）：编辑页按钮带高
    // = 上留白 + 热区 + 下留白，必须仍是 [Tokens.brandStripHeight](40)（侧栏
    // 「logo + 应用名」行的锚）。标题行就挂在带下面 ⇒ 量它离卡顶的距离即可。
    final Rect column = tester.getRect(find.byType(NoteListColumn));
    final Rect title = tester.getRect(find.byType(NoteTitleField));
    expect(
      title.top - column.top,
      Tokens.brandStripHeight,
      reason: '编辑页按钮带高要仍锚着侧栏页头 40（标题行位置不能漂）',
    );

    // 编辑器那两个钮是 M3 `IconButton`：**可视 30、热区被 tap target 撑到 46**。
    // 所以按**中心**比（中心相同 = 视觉同一行），另外单独钉列表侧是 30 的可视盒。
    final Rect undo = tester.getRect(find.byTooltip('撤销（Ctrl+Z）'));
    final double undoCenter = undo.center.dy;
    for (final String tip in <String>['新建', '搜索', '更多', '收起列表']) {
      final Rect r = tester.getRect(find.byTooltip(tip));
      expect(
        r.height,
        Tokens.headerActionSize,
        reason: '「$tip」的可视热区要是 30（与撤销钮的图标盒同档）',
      );
      expect(
        (r.center.dy - undoCenter).abs(),
        lessThan(1.5),
        reason: '「$tip」要与撤销钮落在同一条竖向位置（r=$r undo=$undo）',
      );
    }
  });

  testWidgets('列表头布局：第一行 搜索 → 新建；筛选在篇数右边', (tester) async {
    // 2026-11-09 筛选从工具行搬进「视图名 + 篇数」行；2026-11-17 挪到
    // **篇数右边紧挨着**（语义挨着列表名与篇数），不再贴行右端——
    // 旧的"漏斗中心对齐＋中心"光学约定随位置一并撤。
    await pumpList(tester);

    final Rect collapse = tester.getRect(find.byTooltip('收起列表'));
    final Rect search = tester.getRect(find.byTooltip('搜索'));
    final Rect create = tester.getRect(find.byTooltip('新建'));
    final Rect createArrow = tester.getRect(find.byTooltip('更多'));
    final Rect filter = tester.getRect(find.byTooltip('筛选与排序'));
    final Rect column = tester.getRect(find.byType(NoteListColumn));
    final Rect label = tester.getRect(
      find.descendant(
        of: find.byType(NoteListColumn),
        matching: find.text('笔记'),
      ),
    );

    // 第一行：折叠独立，右簇只剩 搜索 → 新建。
    expect(
      search.left - collapse.right,
      greaterThan(60),
      reason: '折叠钮单独在左侧，右簇不贴着它',
    );
    expect(
      collapse.left + (Tokens.headerActionSize - Tokens.iconSm) / 2,
      closeTo(label.left, 1),
      reason: '折叠钮**图标**左缘与「笔记」标题左缘对齐（热区左 7 + 居中偏移 5 = 12）',
    );
    expect(
      create.left - search.right,
      closeTo(Tokens.spaceXxs, 1),
      reason: '搜索与新建相邻（同一右簇）',
    );
    expect(
      createArrow.right,
      closeTo(column.right - Tokens.spaceSm, 1),
      reason: '新建在最右端、贴右侧 spaceSm(8) 留白',
    );

    // 第二行：筛选在工具行下方、与视图名同一行、贴该行右端。
    expect(
      filter.top,
      greaterThanOrEqualTo(search.bottom),
      reason: '筛选不该还在工具行',
    );
    expect(
      (filter.center.dy - label.center.dy).abs(),
      lessThan(2),
      reason: '筛选与「笔记」标题同一行',
    );
    expect(
      label.center.dy - search.center.dy,
      inInclusiveRange(25, 30),
      reason: '标题行不该被 28 高的筛选热区推下去（搬过来之前是 27）',
    );
    // 2026-11-17：筛选紧贴**篇数**右边（间隔 spaceSm），不贴行右端。
    final Rect count = tester.getRect(inList(find.text('2')));
    expect(
      (filter.center.dy - count.center.dy).abs(),
      lessThan(2),
      reason: '筛选与篇数同高、垂直居中',
    );
    expect(
      filter.left - count.right,
      closeTo(Tokens.spaceSm, 1),
      reason: '筛选紧贴篇数右边（间隔 spaceSm）',
    );
    expect(
      filter.right,
      lessThan(column.right - 60),
      reason: '筛选不再贴行右端（旧的「对齐＋中心」约定已撤）',
    );
  });

  testWidgets('新建分半钮：4/2 两半居中、无发丝线、颜色层级、hover 分区', (tester) async {
    // 2026-11-09 方案 A + 4/2 重排：文案「新建 / 更多」；tooltip 150ms 跟手；
    // 主区 26（4+18+4）/ 副区 12（2+8+2）⇒ 2.17:1；发丝线撤掉；
    // 副区叠加底比主区淡一档（颜色层级）；整块亮的同时当前半再叠一层底。
    await pumpList(tester);

    for (final String tip in <String>['新建', '更多']) {
      // ⚠️ `find.byTooltip` 命中的是 material_ui 的 `RawTooltip`（不是
      // `Tooltip`），所以这里直接按类型谓词找 `Tooltip` 本身读 waitDuration。
      expect(
        find.byWidgetPredicate(
          (Widget w) =>
              w is Tooltip &&
              w.message == tip &&
              w.waitDuration == const Duration(milliseconds: 150) &&
              // 位置参数不覆盖 ⇒ 与搜索 / 筛选同吃主题默认（曾传 8 贴到按钮上）。
              w.verticalOffset == null &&
              w.preferBelow == null,
        ),
        findsOneWidget,
        reason: '「$tip」只覆盖等待时长，位置必须与搜索 / 筛选一致',
      );
    }
    expect(find.byTooltip('新建笔记'), findsNothing, reason: '旧文案已撤');
    expect(find.byTooltip('更多新建选项'), findsNothing, reason: '旧文案已撤');

    // 半区自己的那层底：按 tooltip 子树找，并用宽度排除 FocusRing 的装饰盒。
    Color? halfColor(String tip) {
      final Finder f = find.descendant(
        of: find.byTooltip(tip),
        matching: find.byWidgetPredicate(
          (Widget w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              w.constraints != null &&
              w.constraints!.maxWidth < Tokens.headerActionSize,
        ),
      );
      expect(f, findsOneWidget, reason: '「$tip」半区只有一个带底的 Container');
      return (tester.widget<Container>(f).decoration! as BoxDecoration).color;
    }

    // 「＋▾」常驻 surface 底（2026-11-16 用户定：主操作要有视觉权重），不加描边。
    expect(
      find.descendant(
        of: find.byType(AppSplitIconButton),
        matching: find.byWidgetPredicate((Widget w) {
          if (w is! AnimatedContainer || w.decoration is! BoxDecoration) {
            return false;
          }
          final BoxDecoration d = w.decoration as BoxDecoration;
          return d.color == Bauhaus.controlFill(Brightness.light) &&
              d.border == null;
        }),
      ),
      findsOneWidget,
      reason: '「＋▾」常驻 surface 底、无描边',
    );
    expect(halfColor('新建'), Colors.transparent, reason: '初始左半无叠加底');
    expect(halfColor('更多'), Colors.transparent, reason: '初始右半无叠加底');

    // ① 两半宽 26 / 12 ⇒ 2.17:1。全是偶数 ⇒ DPR 1.5 下整数物理像素。
    final List<double> halfWidths =
        tester
            .widgetList<Container>(
              find.descendant(
                of: find.byType(AppSplitIconButton),
                matching: find.byWidgetPredicate(
                  (Widget w) =>
                      w is Container &&
                      w.decoration is BoxDecoration &&
                      w.constraints != null &&
                      w.constraints!.maxWidth < Tokens.headerActionSize,
                ),
              ),
            )
            .map((Container c) => c.constraints!.maxWidth)
            .toList()
          ..sort();
    expect(halfWidths, <double>[12, 26], reason: '主区 26 / 副区 12（4/2 居中）');

    // ② 1px 发丝线已撤（DPR 1.5 下宽 1.5 物理像素，必糊）。
    expect(
      find.descendant(
        of: find.byType(AppSplitIconButton),
        matching: find.byType(ColoredBox),
      ),
      findsNothing,
      reason: '发丝线覆盖层不该再出现',
    );

    final Rect left = tester.getRect(find.byTooltip('新建'));
    final Rect right = tester.getRect(find.byTooltip('更多'));
    final TestGesture gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await gesture.addPointer(location: left.center);
    await tester.pump();

    final Color? primaryHover = halfColor('新建');
    expect(primaryHover, isNot(Colors.transparent), reason: 'hover 左半 ⇒ 左半叠底');
    expect(halfColor('更多'), Colors.transparent, reason: '右半不该跟着亮');

    await gesture.moveTo(right.center);
    await tester.pump();
    expect(halfColor('新建'), Colors.transparent, reason: '左半恢复');
    final Color? secondaryHover = halfColor('更多');
    expect(
      secondaryHover,
      isNot(Colors.transparent),
      reason: 'hover 右半 ⇒ 右半叠底',
    );

    // ③ 颜色层级：副区叠加底比主区淡一档（更多是次级动作）。
    expect(secondaryHover!.a, lessThan(primaryHover!.a), reason: '副区叠加浓度要低于主区');
  });

  testWidgets('托盘：只保留导入（新建两项已撤）', (tester) async {
    // 2026-11-09 用户定：主区「＋」已按当前页类型直接建，菜单里再列
    // 「新建笔记 / 新建画布」是重复入口 ⇒ 托盘只留导入。
    await pumpList(tester);

    // 先确认托盘是**收起**的（菜单项不在树上）。
    expect(find.text('导入 Markdown…'), findsNothing);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    // ⚠️ 返工闸门：`MenuAnchor` 不会自动响应点击 ⇒ 箭头必须自己 open。
    expect(find.text('导入 Markdown…'), findsOneWidget, reason: '导入项仍在');
    expect(find.text('新建笔记'), findsNothing, reason: '新建笔记项已撤');
    expect(find.text('新建画布'), findsNothing, reason: '新建画布项已撤');
  });

  testWidgets('工具钮：色源单一（单钮 / 分半钮同一墨色）', (tester) async {
    // 2026-10-26 用户实报"同一行图标两种灰"（实测 33,34,34 与 76,76,76）：
    // 根因是同一行混用 M3 `IconButton`（组件下发色）与手搓容器（调用点钉色）。
    // 2026-10-28 新建钮改成 [AppSplitIconButton]（一枚控件两个半区）⇒ 它不继承
    // AppIconButton 的宿主，所以断言从"同一宿主"改为"**按色源**"：两种宿主
    // 内部那层 IconTheme 必须同一墨色。
    await pumpList(tester);

    // 单动作钮（折叠 / 搜索）仍必须是 AppIconButton。
    for (final String tip in <String>['收起列表', '搜索']) {
      expect(
        find.ancestor(
          of: find.byTooltip(tip),
          matching: find.byType(AppIconButton),
        ),
        findsOneWidget,
        reason: '「$tip」的宿主必须是 AppIconButton',
      );
    }
    // 筛选 2026-11-17 换**小方件皮肤**（日历切月同款）：透明底 + hairline
    // + 4px 圆角方件。按皮肤断言（宿主是 home_hub 的私有 _TinyButton）。
    expect(
      find.descendant(
        of: find.byTooltip('筛选与排序'),
        matching: find.byWidgetPredicate((Widget w) {
          if (w is! DecoratedBox || w.decoration is! BoxDecoration) {
            return false;
          }
          final BoxDecoration d = w.decoration as BoxDecoration;
          // 外层皮肤盒才有边框（内层是 hover/pressed 叠加层，无边框）。
          return d.color == Colors.transparent &&
              d.border != null &&
              d.borderRadius == BorderRadius.circular(Tokens.radiusXxs);
        }),
      ),
      findsOneWidget,
      reason: '筛选 = 小方件皮肤（透明底 + hairline + 4px 圆角，日历同款）',
    );
    // 新建 / 更多选项：两半同属**一枚**分半钮。
    expect(find.byType(AppSplitIconButton), findsOneWidget);
    for (final String tip in <String>['新建', '更多']) {
      expect(
        find.ancestor(
          of: find.byTooltip(tip),
          matching: find.byType(AppSplitIconButton),
        ),
        findsOneWidget,
        reason: '「$tip」是分半钮的一个半区（不是独立按钮）',
      );
    }

    // 五枚工具图标（折叠 / 搜索 / 筛选 / 新建半 / 更多半）的 IconTheme 色
    // 全部相等——按 tooltip 子树逐枚收（宿主有三种，色源只有一条）。
    final List<Color> inks = <Color>[];
    for (final String tip in <String>['收起列表', '搜索', '筛选与排序', '新建', '更多']) {
      final IconTheme t = tester.widget<IconTheme>(
        find
            .descendant(
              of: find.byTooltip(tip),
              matching: find.byType(IconTheme),
            )
            .first,
      );
      inks.add(t.data.color!);
    }
    expect(inks.toSet(), hasLength(1), reason: '所有工具钮必须同一墨色（$inks）——否则又会看到两档灰');
    expect(inks.first, AppTheme.light().colorScheme.onSurfaceVariant);
  });
}
