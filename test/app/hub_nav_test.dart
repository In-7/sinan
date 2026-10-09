import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'dart:math' as math;
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
    summary: '',
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

  testWidgets('全局图标已迁出本板；切换器分段 + 该空间的列表照常', (WidgetTester tester) async {
    await tester.pumpWidget(scope());
    // notesProvider 是异步的（AsyncNotifier.build）⇒ 必须等它落地，否则列表是空的。
    await tester.pumpAndSettle();

    // 2026-09-29：设置 / 搜索 / 收藏 / 主页迁去主区顶条（50px 第一列总导航栏
    // 同日撤掉），HubNav 子树里**一个都不许剩**（防两处入口复活）。
    for (final String t in <String>['设置', '搜索', '收藏', '主页']) {
      expect(
        find.descendant(of: find.byType(HubNav), matching: find.byTooltip(t)),
        findsNothing,
        reason: '「$t」已属于主区顶条，不该再出现在导航板里',
      );
    }
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
  /// [AppTheme.hoverOverlay]——否则"悬浮背景没有了"的回归就抓不到。
  /// 此 Flutter 版本无 `tester.hover`，手动派发一个鼠标 hover 事件。
  testWidgets('行 hover ⇒ 底色变 hoverOverlay（非透明）', (WidgetTester tester) async {
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
      reason: 'hover 后底色应变成 hoverOverlay，不能还是透明',
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
  /// （2026-09-29 起切换器滑块那枚凸阴影——曾经的"唯一例外"——也已去除，见
  /// [_SpaceSwitch]；现在全应用零凸起阴影。）
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
    // 等列表落地。
    await tester.pumpAndSettle();

    final List<Material> materials = tester
        .widgetList<Material>(
          find.descendant(
            of: find.byType(HubNav),
            matching: find.byType(Material),
          ),
        )
        .toList();
    // 2026-09-29 顶行 4 枚全局图标迁去主区顶条（50px 第一列同日撤掉）后，
    // 板内只剩笔记空间的
    // 1 条列表行 + 该行「···」按钮（Visibility 用 maintainSize/maintainState，
    // 即便 hover 前不可见也仍驻树，自带一个透明 Material）。切换器与「新建」
    // 都是纯 DecoratedBox（2026-09-29 改平：hover 才换底色，不铺凸玻璃）。
    expect(materials.length, 2);

    final int transparent = materials
        .where((Material m) => m.color == Colors.transparent)
        .length;
    expect(transparent, 2, reason: '列表行与其「···」按钮必须全部透明——落到 surface 就是黑块');
  });

  /// **M3 药丸闸门**（2026-09-29 改方案，替掉原"玻璃片选中态"）：
  /// 切换器滑块 = [ColorScheme.primaryContainer] 实色药丸，**无凸阴影、无玻璃
  /// 三层光**；轨道 = [ColorScheme.surfaceContainer] 平底。钉两条：
  /// ① 滑块取色**只吃 [ColorScheme]**（明暗各自派生 ⇒ 选中信号来自色相而非明
  ///   度差，明暗天然对称——原新拟态做不到，见 [AppTheme.raisedFill] 注释）；
  /// ② 滑块子树里不许再挂 boxShadow / 渐变（新拟态不许回潮）。
  testWidgets('切换器滑块 = primaryContainer 药丸：无阴影、无玻璃', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(scope());

    final List<DecoratedBox> boxes = tester
        .widgetList<DecoratedBox>(
          find.descendant(
            of: find.byKey(const Key('spaceThumb')),
            matching: find.byType(DecoratedBox),
          ),
        )
        .toList();
    // 改平之后滑块就是**一枚**纯色 DecoratedBox（原先还挂着玻璃光层 + ClipRRect）。
    expect(boxes.length, 1, reason: '滑块应只剩一枚纯色 DecoratedBox');

    final BoxDecoration decoration = boxes.first.decoration as BoxDecoration;
    expect(
      decoration.color,
      AppTheme.light().colorScheme.primaryContainer,
      reason: '滑块必须取 primaryContainer（M3 容器/内容配对）',
    );
    expect(decoration.boxShadow, isNull, reason: 'M3 药丸不许有凸阴影（新拟态不许回潮）');
    expect(decoration.gradient, isNull, reason: '药丸是实色，不许挂玻璃渐变');
  });

  /// **明暗感知差闸门**（2026-09-29 改 M3 药丸的核心动机）：轨道取
  /// [ColorScheme.surfaceContainer]，它与列底的**感知明度差 ΔL\*** 必须落在
  /// 可读区间内——否则就是"整条轨道消失"或"轨道太抢戏"的回归。
  ///
  /// 2026-10-09 双色底都换掉后（暗 #080808 / 亮 #DDDDDB），M3 钉死的 tone
  ///（暗 12 / 亮 94）对底差双双出闸 ⇒ `surfaceContainer` 在 app_theme 里
  /// **明暗都显式钉到浮面档 panelFill**（新架构里导航列本就落在浮面卡内）。
  /// 区间明暗**不对称是刻意的**：暗色 ΔL\* 5.0（近黑区人眼放大，2~6 足够）；
  /// 亮色 ΔL\* 11.9——白端压缩感知，且亮面悬浮本来就靠更大色阶 + 软投影，
  /// chrome 每往深压一档这条就跟着涨（面板钉死纯白），放到 2~13。
  ///
  /// 历史候选（旧底 7.7 时实测，ΔL\* 亮 / 暗）：`surfaceContainerLow` −1.1 /
  /// +2.4（亮色近乎不可见）、**`surfaceContainer` −3.2 / +4.4（曾最对称）**、
  /// `surfaceContainerHigh` −5.3 / +9.2、`surfaceContainerHighest` −7.1 /
  /// +14.3（暗色过冲）。
  ///
  /// ⚠️ 必须量 **L\*** 不能用相对亮度：后者在近黑区被指数压缩，会得出
  /// "列底 0.85 vs 轨道 1.42 ≈ 没差别"的**错误结论**（实际 L\* 7.7 vs 12.1，
  /// 肉眼可见）。换种子色只要 ΔL\* 还在这档就不该红。
  testWidgets('轨道在明暗下与列底的感知差都落在可读区间', (WidgetTester tester) async {
    double lStar(Color c) {
      final double y = c.computeLuminance();
      return y <= 0.008856
          ? 903.3 * y
          : (116 * math.pow(y, 1 / 3) - 16).toDouble();
    }

    for (final Brightness b in <Brightness>[
      Brightness.light,
      Brightness.dark,
    ]) {
      final ThemeData t = b == Brightness.light
          ? AppTheme.light()
          : AppTheme.dark();
      final double d =
          (lStar(t.colorScheme.surfaceContainer) -
                  lStar(AppTheme.windowBackground(b)))
              .abs();
      // 暗 2~6（近黑放大）；亮 2~13（白端压缩 + 面板钉死纯白，chrome 越深差越大）。
      final (double lo, double hi) = b == Brightness.light
          ? (2.0, 13.0)
          : (2.0, 6.0);
      expect(
        d,
        inInclusiveRange(lo, hi),
        reason:
            '${b.name} 轨道与列底 ΔL* = ${d.toStringAsFixed(1)}，'
            '应落在 ${lo.toStringAsFixed(0)}~${hi.toStringAsFixed(0)}',
      );
    }
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
}
