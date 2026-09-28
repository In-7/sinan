import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'dart:ui' show PointerDeviceKind;

import 'package:sinan/src/app/hub_nav.dart';
import 'package:sinan/src/app/providers.dart'
    show
        NotesNotifier,
        appDataDirProvider,
        databaseProvider,
        noteStoreProvider,
        notesProvider,
        selectedNoteIdProvider,
        settingsStoreProvider;
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/focus_ring.dart';
import 'package:sinan/src/theme/tokens.dart';
// 只取 Database / sqlite3：sqlite3 还导出一个 `Row`，与 Flutter 的 Row 撞名。
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// 覆写用的假 Notifier：直接吐固定列表，不碰真库（[NotesNotifier.build] 原本
/// 读 `_store.allNotes()`，本类绕开它 —— 测试只要确定的几条笔记）。
class _FakeNotes extends NotesNotifier {
  _FakeNotes(this._notes);

  final List<Note> _notes;

  @override
  Future<List<Note>> build() async => _notes;
}

/// 导航板骨架的回归（`docs/ui_rewrite_plan.md` §5.6 阶段 2）。
///
/// 2026-09-24 用户定后的新结构：**顶行图标**（设置 / 搜索 / 主页）→ 分隔线 →
/// **空间切换器**（笔记 / 画布，滑块滑动）→ **该空间的内联列表**（按
/// [NoteKind] 过滤 [notesProvider]）。本文件钉住这个新结构的行为。
///
/// ⚠️ 一律用 [`scope`] 把 [notesProvider] **覆成固定两条**（一条普通笔记 + 一条
/// 画布笔记）：列表现在读真实数据，不覆写就会撞真库、结果不确定。
void main() {
  Note note(String id, NoteKind kind, String title) => Note(
    id: id,
    kind: kind,
    title: title,
    content: '',
    plainText: '',
    contentHash: '',
    createdAt: DateTime(2026, 9, 20),
    revisedAt: DateTime(2026, 9, 23),
  );

  /// 两条：普通笔记「灵感碎片」+ 画布笔记「架构草图」——正好能被两个空间
  /// 分别滤出，用来钉"切换器真的在过滤"。
  final List<Note> fakeNotes = <Note>[
    note('n1', NoteKind.spark, '灵感碎片'),
    note('c1', NoteKind.canvas, '架构草图'),
  ];

  Widget host({Widget? body}) => MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(body: body ?? const HubNav()),
  );

  /// 把 [notesProvider] 覆成 [fakeNotes] 的 ProviderScope。
  ProviderScope scope({Widget? body}) => ProviderScope(
    overrides: [notesProvider.overrideWith(() => _FakeNotes(fakeNotes))],
    child: host(body: body),
  );

  testWidgets('渲染顶行图标 + 切换器分段 + 该空间的列表', (WidgetTester tester) async {
    await tester.pumpWidget(scope());
    // notesProvider 是异步的（AsyncNotifier.build）⇒ 必须等它落地，否则列表是空的。
    await tester.pumpAndSettle();

    // 顶行三枚是图标（Tooltip），不落成文本项。
    expect(find.text('设置'), findsNothing, reason: '设置是顶行图标（Tooltip），不是文本项');
    expect(find.text('主页'), findsNothing, reason: '主页是顶行图标（Tooltip），不是文本项');
    expect(find.byTooltip('设置'), findsOneWidget);
    // 搜索图标已接线（2026-09-25）：不再是"开发中"占位，tooltip 是真动作。
    expect(find.byTooltip('搜索'), findsOneWidget);
    expect(find.byTooltip('主页'), findsOneWidget);
    // 新建（2026-09-26 定：挪进切换器，作为第三个同款单元格）同样是图标（Tooltip）。
    expect(find.byTooltip('新建'), findsOneWidget);
    expect(find.text('新建'), findsNothing);

    // 切换器的两段标签都在（滑块在其下滑动，标签不动）。
    expect(find.text('笔记'), findsOneWidget);
    expect(find.text('画布'), findsOneWidget);

    // 默认空间 = 笔记 ⇒ 只滤出非画布的那条。
    expect(find.text('灵感碎片'), findsOneWidget);
    expect(find.text('架构草图'), findsNothing, reason: '画布笔记不该出现在笔记空间里');
  });

  /// **右键菜单闸门**（2026-09-25）：导航内联列表的条目与左侧 [NoteListView]
  /// 同款——右键弹出 重命名 / 收藏 / 删除 三件事。
  testWidgets('行右键 ⇒ 菜单含 重命名 / 收藏 / 删除', (WidgetTester tester) async {
    await tester.pumpWidget(scope());
    await tester.pumpAndSettle();

    // 右键条目（buttons = 次键 ⇒ onSecondaryTapDown）。
    await tester.tap(find.text('灵感碎片'), buttons: 2);
    await tester.pumpAndSettle();

    expect(find.text('重命名'), findsOneWidget, reason: '菜单应含就地重命名');
    // 未收藏 ⇒ 菜单项是「收藏」（不是「取消收藏」）。
    expect(find.text('收藏'), findsOneWidget, reason: '菜单应含收藏切换');
    expect(find.text('删除笔记'), findsOneWidget, reason: '菜单应含删除');
  });

  /// **hover 背景闸门**（2026-09-25 回归）：行 hover 必须真的把底色从透明换成
  /// [AppTheme.boardFillHover]——否则"悬浮背景没有了"的回归就抓不到。
  /// 此 Flutter 版本无 `tester.hover`，手动派发一个鼠标 hover 事件。
  testWidgets('行 hover ⇒ 底色变 boardFillHover（非透明）', (WidgetTester tester) async {
    await tester.pumpWidget(scope());
    await tester.pumpAndSettle();

    final Finder rowMaterial = find.ancestor(
      of: find.text('灵感碎片'),
      matching: find.byType(Material),
    );
    expect(
      tester.widget<Material>(rowMaterial.first).color,
      Colors.transparent,
      reason: '未 hover 时底色必须透明',
    );

    // 手动派发鼠标移动事件（驱动 MouseTracker 触发 MouseRegion.onEnter）。
    // 必须先 addPointer 把鼠标指针登记进 tracker，否则 move 事件不触发 hover。
    final Offset at = tester.getCenter(find.text('灵感碎片'));
    final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.addPointer(location: at));
    await tester.sendEventToBinding(pointer.hover(at));
    await tester.pump();

    expect(
      tester.widget<Material>(rowMaterial.first).color,
      isNot(equals(Colors.transparent)),
      reason: 'hover 后底色应变成 boardFillHover，不能还是透明',
    );
  });

  /// **滑动闸门**（2026-09-24 用户定的核心交互）：滑块必须真的从左半边
  /// 滑到右半边，不能只是换色。
  testWidgets('点「画布」⇒ 滑块滑到右半边', (WidgetTester tester) async {
    await tester.pumpWidget(scope());

    final Rect atNotes = tester.getRect(find.byKey(const Key('spaceThumb')));
    await tester.tap(find.text('画布'));
    await tester.pumpAndSettle();
    final Rect atCanvas = tester.getRect(find.byKey(const Key('spaceThumb')));

    expect(
      atCanvas.left,
      greaterThan(atNotes.left),
      reason: '滑块应向右滑（画布段在右），实际 ${atCanvas.left} vs ${atNotes.left}',
    );
  });

  /// **过滤闸门**：切空间 = 换下面列表的内容，且不碰主区选中。
  testWidgets('切空间只换列表、不切主区', (WidgetTester tester) async {
    final ProviderContainer container = ProviderContainer(
      overrides: [notesProvider.overrideWith(() => _FakeNotes(fakeNotes))],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: host()),
    );

    await tester.tap(find.text('画布'));
    await tester.pumpAndSettle();

    // 列表换成画布笔记。
    expect(container.read(navSpaceProvider), isTrue);
    expect(find.text('架构草图'), findsOneWidget);
    expect(find.text('灵感碎片'), findsNothing);

    // 主区选中（0 = 主页）不受影响——否则一切空间主页就没了。
    expect(
      container.read(hubNavSelectionProvider),
      0,
      reason: '空间切换器不得写 hubNavSelectionProvider',
    );
  });

  /// **真实宿主**的回归（2026-09-22 运行时实炸）。
  ///
  /// `HubNav` 在产品里是 `Row` 的**非 flex 子项**——Row 给非 flex 子项的是无界宽度，
  /// 若它不自己锁宽，内部的 `Row + Expanded` 会撞 "unbounded width constraints"。
  /// 挂在 `Scaffold body`（有界）里**测不出这个炸**——所以必须有这条按产品真实
  /// 挂载方式写的用例。
  testWidgets('真实宿主（Row 的非 flex 子项）里布局不炸', (WidgetTester tester) async {
    await tester.pumpWidget(
      scope(
        body: const Row(
          children: <Widget>[
            HubNav(),
            Expanded(child: ColoredBox(color: Colors.red)),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('笔记'), findsOneWidget);
  });

  /// 2026-09-24 用户定：撤掉新拟态浮雕，恢复贴窗三边 + 同色平铺。
  /// 切换器滑块的阴影是**唯一**允许的例外，且只挂在滑块上（见 [_SpaceSwitch]）。
  testWidgets('铺满左侧 ⇒ 只圆右边两角 + 同色底', (WidgetTester tester) async {
    await tester.pumpWidget(scope());

    final DecoratedBox box = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byType(HubNav),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final BoxDecoration decoration = box.decoration as BoxDecoration;
    // 整个页面同色：列底 = 窗口底（撤掉浮雕后的平铺）。
    expect(
      decoration.color,
      AppTheme.windowBackground(Brightness.light),
      reason: '恢复同色平铺，不靠色差也不靠阴影分层',
    );
    expect(
      decoration.borderRadius,
      const BorderRadius.horizontal(right: Radius.circular(Tokens.radiusLg)),
      reason: '贴窗的那两角若留圆角 ⇒ 窗口角露出两块窗口底的月牙，看着就不像一整列',
    );
    expect(decoration.boxShadow, isNull, reason: '板底不允许阴影（浮雕已撤）');
  });

  testWidgets('未选中行的底色是透明的（不能落到 surface 的近黑）', (WidgetTester tester) async {
    await tester.pumpWidget(scope());
    // 等列表落地（否则只有顶行 3 个 Material）。
    await tester.pumpAndSettle();

    final List<Material> materials = tester
        .widgetList<Material>(
          find.descendant(
            of: find.byType(HubNav),
            matching: find.byType(Material),
          ),
        )
        .toList();
    // 顶行 4 个图标（设置 / 搜索 / **收藏** / 主页）+ 笔记空间的 1 条列表行 + 该行
    // 「···」按钮（Visibility 用 maintainSize/maintainState，即便 hover 前不可见
    // 也仍驻树，自带一个透明 Material）。切换器用 DecoratedBox，无 Material；
    // 「新建」在切换器井内最右，是同款新拟态正方格（DecoratedBox，无 Material）。
    // ⚠️ 收藏图标是后来加的（顶行由 3 枚变 4 枚）⇒ 计数是 6 不是 5。
    expect(materials.length, 6);

    final int transparent = materials
        .where((Material m) => m.color == Colors.transparent)
        .length;
    expect(
      transparent,
      6,
      reason:
          '顶行**无选中态**（2026-09-24 用户定：主页只是动作）⇒ 6 个'
          '（设置/搜索/收藏/主页图标 + 列表行 + 列表行的「···」按钮）必须全部透明'
          '——落到 surface 就是黑块',
    );
  });

  /// **玻璃片选中态闸门**（2026-09-24 用户定）：选中项 = tint 底 + 三层纯绘制的光
  /// （内光泽 / 顶沿光边 / 底沿厚度边）。钉两条：
  /// ① 三层光**只在选中处**出现；② 光的三条渐变必须与 [AppTheme] 令牌同一实例。
  testWidgets('选中 = 玻璃片：三层光只挂在选中处', (WidgetTester tester) async {
    await tester.pumpWidget(scope());

    bool hasGradient(Gradient? g) => g != null;

    // ⚠️ 只数**切换器滑块**（Key `spaceThumb`）子树里的玻璃片，故意**排除**
    // 切换器井内最右那枚「+」正方格——它按设计也是同款凸玻璃（永远抬起），
    // 自带一层玻璃光；若算进 HubNav 全树就会多一片。本用例只钉"切换器本身的玻璃
    // 片只在选中处出现"这一条，+ 格的玻璃不在此断言范围。
    final List<DecoratedBox> lit = tester
        .widgetList<DecoratedBox>(
          find.descendant(
            of: find.byKey(const Key('spaceThumb')),
            matching: find.byType(DecoratedBox),
          ),
        )
        .where(
          (DecoratedBox box) =>
              box.decoration is BoxDecoration &&
              hasGradient((box.decoration as BoxDecoration).gradient),
        )
        .toList();

    // 一层「玻璃片」= 一个 sheen（内光泽）+ rim + baseEdge ⇒ 数 sheen 的个数
    // 就是数玻璃片的个数。当前恰好**一片**：切换器滑块（滑块本身就是抬起
    // 的那块玻璃）。顶行主页图标已无选中态（2026-09-24 用户定：主页只是动作）。
    // ⚠️ 切换器轨道的那条内渐变（凹井用）不是玻璃令牌，不会混进来。
    final Gradient sheen = AppTheme.glassSheen(
      Brightness.light,
      alphaScale: AppTheme.glassSheetBoost,
    );
    final int sheets = lit
        .where(
          (DecoratedBox box) =>
              (box.decoration as BoxDecoration).gradient == sheen,
        )
        .length;
    expect(sheets, 1, reason: '玻璃片应恰好一片（切换器滑块）；多 ⇒ 有非选中处也挂了光');
    final Set<Gradient> gradients = lit
        .map((DecoratedBox box) => (box.decoration as BoxDecoration).gradient!)
        .toSet();
    expect(
      gradients,
      containsAll(<Gradient>[
        AppTheme.glassSheen(
          Brightness.light,
          alphaScale: AppTheme.glassSheetBoost,
        ),
        AppTheme.glassRim(
          Brightness.light,
          alphaScale: AppTheme.glassSheetBoost,
        ),
        AppTheme.glassBaseEdge(
          Brightness.light,
          alphaScale: AppTheme.glassSheetBoost,
        ),
      ]),
      reason: '三层光必须直接取 AppTheme 令牌（含玻璃片加力），不许就地手搓',
    );
  });

  /// **玻璃片与文字对齐闸门**（2026-09-24 实机截图抓到的错位）：
  /// Row 进了 Stack 之后，Stack 默认 `topStart` 会把文字钉在上沿。
  /// 现在列表行也带玻璃片（打开的那篇）⇒ 在列表行上验证同一条事实。
  testWidgets('玻璃片与文字垂直居中（Stack 不得把行顶到上沿）', (WidgetTester tester) async {
    final ProviderContainer container = ProviderContainer(
      overrides: [notesProvider.overrideWith(() => _FakeNotes(fakeNotes))],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: host()),
    );
    await tester.pumpAndSettle();

    // 点开那篇 ⇒ 该行披玻璃片，且主区选中被置为它。
    await tester.tap(find.text('灵感碎片'));
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteIdProvider), 'n1');

    final Rect text = tester.getRect(find.text('灵感碎片'));
    final Rect pill = tester.getRect(
      find.ancestor(of: find.text('灵感碎片'), matching: find.byType(FocusRing)),
    );

    expect(
      (text.center.dy - pill.center.dy).abs(),
      lessThan(0.5),
      reason:
          '文字中心与玻璃片中心差了 ${text.center.dy - pill.center.dy}px —— '
          'Stack 对齐丢了，行又被钉到上沿了',
    );
  });

  /// **切换器内「新建」**（2026-09-26 定：井内最右的正方格）：点它弹出
  /// 「新建笔记 / 新建画布」两行菜单，
  /// 且菜单里标出快捷键（§3.5：键位的发现入口）。
  testWidgets('切换器「新建」⇒ 菜单含 新建笔记 / 新建画布 + 快捷键，锚在按钮右下', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(scope());
    await tester.pumpAndSettle();

    final Rect anchor = tester.getRect(find.byTooltip('新建'));
    await tester.tap(find.byTooltip('新建'));
    await tester.pumpAndSettle();

    expect(find.text('新建笔记'), findsOneWidget);
    expect(find.text('新建画布'), findsOneWidget);
    // 快捷键写在行尾（发现入口）。
    expect(find.text('Ctrl+N'), findsOneWidget);
    expect(find.text('Ctrl+Shift+N'), findsOneWidget);

    // **锚点闸门**（2026-09-26 实机抓到）：菜单必须贴按钮右下角弹出。曾有
    // GlobalKey 没挂到按钮树上 ⇒ currentContext 为 null ⇒ position 落在
    // Offset.zero ⇒ 菜单弹到屏幕左上角。钉死：菜单首行要在按钮**下方**、
    // 且横向不早于按钮左缘。
    final Offset firstItem = tester.getTopLeft(find.text('新建笔记'));
    expect(
      firstItem.dy,
      greaterThanOrEqualTo(anchor.bottom - 4),
      reason: '菜单应从按钮下缘往下弹，而不是跑到屏幕顶部',
    );
    expect(
      firstItem.dx,
      greaterThanOrEqualTo(anchor.left),
      reason: '菜单应锚在按钮右下角，而不是跑到屏幕左上角',
    );
  });

  /// 菜单选「新建画布」⇒ 真的建出画布，**并把空间切到画布**。
  ///
  /// 钉的是那条最容易漏的：命令层只 create + locate，**不切空间** ⇒ 在笔记空间
  /// 建画布，主区开了、侧栏列表却把新画布筛掉 ⇒ "点了没反应"。
  testWidgets('菜单「新建画布」⇒ 建出画布并把空间切过去', (WidgetTester tester) async {
    // 真库（内存）：新建要走真实 [NoteStore]，不是假列表。
    final Database db = sqlite3.openInMemory();
    addTearDown(db.close);
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');

    const String dataDir = r'C:\Users\test\AppData\Roaming\sinan';
    final ProviderContainer container = ProviderContainer(
      overrides: [
        noteStoreProvider.overrideWithValue(NoteStore(db)),
        settingsStoreProvider.overrideWithValue(SettingsStore(db)),
        appDataDirProvider.overrideWithValue(dataDir),
        databaseProvider.overrideWithValue(db),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: HubNav()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(container.read(navSpaceProvider), isFalse, reason: '默认笔记空间');

    await tester.tap(find.byTooltip('新建'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建画布'));
    await tester.pumpAndSettle();

    expect(
      container.read(navSpaceProvider),
      isTrue,
      reason: '建画布必须把空间切到画布，否则侧栏列表里看不见它（"点了没反应"）',
    );
    final List<Note> notes = container.read(notesProvider).value ?? <Note>[];
    expect(
      notes.any((Note n) => n.kind == NoteKind.canvas),
      isTrue,
      reason: '菜单的「新建画布」必须真的建出一条画布笔记',
    );
  });

  /// 主页入口的回归（2026-09-22 用户实报的死角：主页的 `onTap` 曾被设成 null）。
  /// 主页只剩顶行图标这一个入口 ⇒ 钉住它点得动、且不炸。
  testWidgets('顶行主页图标点得动（onTap 非 null 的回归）', (WidgetTester tester) async {
    final ProviderContainer container = ProviderContainer(
      overrides: [notesProvider.overrideWith(() => _FakeNotes(fakeNotes))],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: host()),
    );

    await tester.tap(find.byTooltip('主页'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(container.read(hubNavSelectionProvider), 0);
  });
}
