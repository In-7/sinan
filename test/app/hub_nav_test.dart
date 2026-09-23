import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/hub_nav.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/focus_ring.dart';
import 'package:sinan/src/theme/tokens.dart';

/// 导航板骨架的回归（`docs/ui_rewrite_plan.md` §5.6 阶段 2）。
///
/// 钉三件结构性事实：四项都在且都接了焦点环（§5.2）、未选中项的底必须透明
/// （`Material(color: null)` 的坑）、以及**点占位项之后主页能点回去**
/// （2026-09-22 用户实报的死角：主页的 `onTap` 曾被设成 null）。
void main() {
  Widget host({Widget? body}) => MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(body: body ?? const HubNav()),
  );

  testWidgets('渲染全部导航项与分区标题，且每项都可键盘聚焦', (WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(child: host()));

    // 顶部主操作（Craft 的 New Doc 同位）+ 分区项 + 底部设置。
    expect(find.text('新建笔记'), findsOneWidget);
    expect(find.text('主页'), findsOneWidget);
    expect(find.text('全部笔记'), findsOneWidget);
    expect(find.text('画布'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    // 分组结构（Craft 的侧栏留白主要花在这里）：没有组标题就是"一串按钮"。
    expect(find.text('工作区'), findsOneWidget);
    expect(
      find.byType(FocusRing),
      findsNWidgets(5),
      reason: '导航项必须接进 Focus 树（Tab 可达 + 焦点环）',
    );
  });

  /// **真实宿主**的回归（2026-09-22 运行时实炸）。
  ///
  /// `HubNav` 在产品里是 `Row` 的**非 flex 子项**——Row 给非 flex 子项的是无界宽度，
  /// 若它不自己锁宽，内部的 `Row + Expanded` 会撞 "unbounded width constraints"。
  /// 挂在 `Scaffold body`（有界）里**测不出这个炸**——所以必须有这条按产品真实
  /// 挂载方式写的用例。
  /// ⚠️ 2026-09-22 起宿主**不再给 Padding**（导航板铺满左侧、三方不留缝）⇒ 这里
  /// 也跟着改成裸挂载，否则这条"真实宿主"用例会反过来保护一个已经不存在的写去。
  testWidgets('真实宿主（Row 的非 flex 子项）里布局不炸', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: host(
          body: const Row(
            children: <Widget>[
              HubNav(),
              Expanded(child: ColoredBox(color: Colors.red)),
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('主页'), findsOneWidget);
  });

  /// 2026-09-22 用户定：导航板**铺满左侧**（主机不再给上/左/下 6px 缝）。
  /// ⇒ 它现在是通高列，贴窗的两角**必须是方角**，否则窗口角会露出月牙。
  testWidgets('铺满左侧 ⇒ 只圆右边两角', (WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(child: host()));

    final DecoratedBox box = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byType(HubNav),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final BoxDecoration decoration = box.decoration as BoxDecoration;
    expect(decoration.color, AppTheme.boardFill(Brightness.light));
    expect(
      decoration.borderRadius,
      const BorderRadius.horizontal(right: Radius.circular(Tokens.radiusLg)),
      reason: '贴窗的那两角若留圆角 ⇒ 窗口角露出两块窗口底的月牙，看着就不像一整列',
    );
  });

  testWidgets('未选中的导航项底色是透明的（不能落到 surface 的近黑）', (tester) async {
    await tester.pumpWidget(ProviderScope(child: host()));

    final List<Material> materials = tester
        .widgetList<Material>(
          find.descendant(
            of: find.byType(HubNav),
            matching: find.byType(Material),
          ),
        )
        .toList();
    expect(materials.length, 5, reason: '每个导航项一个 Material');

    final int transparent = materials
        .where((Material m) => m.color == Colors.transparent)
        .length;
    expect(
      transparent,
      4,
      reason:
          '只有「主页」有选中 pill；其余四项（新建/全部笔记/画布/设置）必须透明，'
          '让板底透出来——落到 surface 就是黑块',
    );
  });

  testWidgets('点占位项之后，主页必须还能点回去（2026-09-22 用户实报的死角）', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = ProviderContainer();
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: host()),
    );

    await tester.tap(find.text('全部笔记'));
    await tester.pump();
    expect(container.read(hubNavSelectionProvider), 1);

    // 修复前：主页的 onTap 是 null ⇒ 高亮被占位项拿走后就"回不去"。
    await tester.tap(find.text('主页'));
    await tester.pump();
    expect(container.read(hubNavSelectionProvider), 0);
  });
}
