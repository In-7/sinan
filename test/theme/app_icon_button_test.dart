import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sinan/src/theme/app_custom_icons.dart';
import 'package:sinan/src/theme/app_icon_button.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/focus_ring.dart';
import 'package:sinan/src/theme/tokens.dart';

/// **自绘 PC 图标钮**的色源 / 观感契约。
///
/// 这些断言的存在理由只有一个：2026-10-26 列表头同一行里出现过**两档灰**
/// （实测 `33,34,34` 与 `76,76,76`）——根因是同一行混用 M3 `IconButton`
/// （组件下发色）与手搓容器（调用点钉色）。宿主统一到 [AppIconButton] 后，
/// 色源只剩这一个出口，本文件把它钉住，防止哪天又长出第二条取色链路。
void main() {
  Widget host(Widget child, {Brightness brightness = Brightness.light}) =>
      MaterialApp(
        theme: brightness == Brightness.dark
            ? AppTheme.dark()
            : AppTheme.light(),
        home: Center(child: child),
      );

  /// ⚠️ 用 `enabled` 开关而不是直接传 `onPressed: null`：后者会被 linter 判为
  /// "与默认值冗余"，且第一版因为 helper 兜底 `?? () {}` 导致测的永远是启用态。
  /// ⚠️ 不接 `width`：传 null 会被 linter 判为"与默认值冗余"，而 Dart 的
  /// 参数列表不支持 `if (…) param: v`（那是 collection 语法）。窄钮那条测试
  /// 直接构造 [AppIconButton]。
  AppIconButton btn({bool enabled = true}) => AppIconButton(
        icon: CustomIcons.plus(size: Tokens.iconSm),
        tooltip: '测试',
        onPressed: enabled ? () {} : null,
      );

  /// 组件**内部**那层 [IconTheme] 的色——图标真正读的就是它。
  Color inkOf(WidgetTester tester) => tester
      .widget<IconTheme>(
        find.descendant(
          of: find.byType(AppIconButton),
          matching: find.byType(IconTheme),
        ),
      )
      .data
      .color!;

  /// 热区底色**为 [color] 的那枚容器**。
  ///
  /// ⚠️ 刻意用"找带该底色的容器"而不是"找唯一的 Container"：`Tooltip` 浮出后
  /// 树里会有第二个装饰容器，按类型取唯一会 "Too many elements"。
  Finder hotZoneWith(Color color) => find.byWidgetPredicate(
        (Widget w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).color == color,
      );

  /// 本件的语义节点。`Tooltip` 自己也有 `Semantics`，靠 `button=true` 区分。
  Semantics semanticsOf(WidgetTester tester) => tester.widget<Semantics>(
        find.byWidgetPredicate(
          (Widget w) => w is Semantics && w.properties.button == true,
        ),
      );

  Future<void> hover(WidgetTester tester) async {
    final TestGesture g = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await g.moveTo(tester.getCenter(find.byType(AppIconButton)));
    // ⚠️ 只 pump **一帧**，不用 pumpAndSettle：后者会把 Tooltip 也等出来，
    // 它的装饰容器会让 byType(Container) 变成多匹配（"Too many elements"）。
    // hover 铺底是 setState 直接换色、无动画，一帧即到位。
    await tester.pump();
  }

  group('AppIconButton：色源单点', () {
    testWidgets('常驻色 = onSurfaceVariant（与基准 _HeadIconButton 同档）', (
      tester,
    ) async {
      await tester.pumpWidget(host(btn()));
      expect(inkOf(tester), AppTheme.light().colorScheme.onSurfaceVariant);
    });

    testWidgets('禁用态降一档：disabledInk（不是全强度）', (tester) async {
      await tester.pumpWidget(host(btn(enabled: false)));
      final ColorScheme scheme = AppTheme.light().colorScheme;
      expect(inkOf(tester), AppTheme.disabledInk(scheme.onSurfaceVariant));
      expect(inkOf(tester).a, lessThan(1.0));
    });

    testWidgets('暗色同样跟主题（不写死亮色）', (tester) async {
      await tester.pumpWidget(
        host(btn(), brightness: Brightness.dark),
      );
      expect(inkOf(tester), AppTheme.dark().colorScheme.onSurfaceVariant);
    });
  });

  group('AppIconButton：PC 观感', () {
    testWidgets('hover 铺 hoverOverlay；静止与禁用都不铺底', (tester) async {
      await tester.pumpWidget(host(btn()));
      expect(hotZoneWith(Colors.transparent), findsOneWidget);

      await hover(tester);
      expect(
        hotZoneWith(AppTheme.hoverOverlay(Brightness.light)),
        findsOneWidget,
      );

      // 禁用态：hover 也不铺底（按钮不可用就不给"热区"暗示）。
      await tester.pumpWidget(host(btn(enabled: false)));
      await hover(tester);
      expect(hotZoneWith(Colors.transparent), findsOneWidget);
    });

    testWidgets('热区默认 28 正方；width 可覆盖（托盘窄钮 22）', (tester) async {
      await tester.pumpWidget(host(btn()));
      expect(
        tester.getSize(find.byType(AppIconButton)),
        const Size.square(Tokens.headerActionSize),
      );

      // 窄钮（托盘箭头 22 宽）：直接构造，不走 helper。
      await tester.pumpWidget(
        host(
          AppIconButton(
            icon: CustomIcons.plus(size: Tokens.iconSm),
            tooltip: '测试',
            onPressed: () {},
            width: 22,
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(AppIconButton)),
        const Size(22, 28),
      );
    });

    testWidgets('无 Ink 涟漪（PC 不要触摸反馈）', (tester) async {
      await tester.pumpWidget(host(btn()));
      expect(find.byType(InkWell), findsNothing);
      expect(find.byType(Material), findsNothing);
    });

    testWidgets('语义：button + enabled + label（读屏靠它）', (tester) async {
      await tester.pumpWidget(host(btn()));
      final Semantics s = semanticsOf(tester);
      expect(s.properties.button, isTrue);
      expect(s.properties.enabled, isTrue);
      expect(s.properties.label, '测试');
    });

    testWidgets('禁用时语义报 enabled=false', (tester) async {
      await tester.pumpWidget(host(btn(enabled: false)));
      expect(semanticsOf(tester).properties.enabled, isFalse);
    });

    testWidgets('焦点环只给键盘（鼠标点过不戴环）', (tester) async {
      await tester.pumpWidget(host(btn()));
      final FocusRing ring = tester.widget<FocusRing>(
        find.descendant(
          of: find.byType(AppIconButton),
          matching: find.byType(FocusRing),
        ),
      );
      expect(ring.keyboardOnly, isTrue);
    });
  });
}
