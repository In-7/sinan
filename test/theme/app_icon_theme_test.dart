import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/theme/app_icon_theme.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

/// **桥接的产出**：tabler 图标在它**自己的** build context 上会看到的图标色。
///
/// 刻意取 element 当 BuildContext —— `tabler` 的 `Icon.build` 里调的就是
/// `IconTheme.of(context)`，同一个起点读到的就是它**真正会用的那个值**。
/// 这比翻更底层的 `SvgPicture` 更准，也免了给测试加 `flutter_svg` 直接依赖。
Color? _tablerColorOf(WidgetTester tester) =>
    tabler.IconTheme.of(tester.element(find.byType(tabler.Plus).first)).color;

/// 图标**自身**那条 `colorFilter` 参数（调用点显式指定的色走这条路）。
ColorFilter? _iconFilterArgOf(WidgetTester tester) =>
    tester.widget<tabler.Plus>(find.byType(tabler.Plus).first).colorFilter;

/// 宿主主题用**生产的那两套**（`AppTheme`），不是裸 `ThemeData`。
///
/// ⚠️ 这不是小事：裸 `ThemeData(colorScheme:)` 会把 `iconTheme` 默认派生自
/// `Typography`（实测亮色 `black87`、暗色纯白）——那是**文字**色，会把
/// `ThemeData.iconTheme` 的意图顶掉。用裸 ThemeData 搭台，测的就不是生产行为了。
ThemeData _themeOf(Brightness brightness) =>
    brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light();

/// 全应用图标的默认色源（见 `app_theme.dart` 的 `iconTheme`）。
Color _defaultIconColorOf(Brightness brightness) =>
    _themeOf(brightness).colorScheme.onSurfaceVariant;

/// 把 [child] 放进一套最小可用的 Material 环境（[brightness] 决定明暗）。
Widget _host(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(theme: _themeOf(brightness), home: Center(child: child));

void main() {
  group('tabler 图标主题桥（AppIconTheme）', () {
    testWidgets('病根：不桥接时 tabler 图标恒定死黑', (tester) async {
      // 2026-09-23 用户实报的两个症状（"不随明暗变色"+"没有未激活的浅色"）
      // 根因之一就在这里：tabler 自带一套独立 IconTheme，color 为 null 时
      // 恒定回落到 fallback 的纯黑。这条钉住病根本身——它一旦变红，
      // 说明 tabler 上游改了回落行为，本文件其余断言要重新推一遍。
      await tester.pumpWidget(_host(const tabler.Plus()));
      expect(_tablerColorOf(tester), const Color(0xFF000000));
    });

    testWidgets('采纳米桥接的 Material IconTheme 色（未激活浅色的来源）', (tester) async {
      // Material 组件（`IconButton` / `ListTile` / 按钮…）正是这样下发图标色的，
      // 本例用 `IconTheme` 直接模拟那一层。
      const Color inactive = Color(0xFF6B7280);
      await tester.pumpWidget(
        _host(
          const AppIconTheme(
            child: IconTheme(
              data: IconThemeData(color: inactive),
              child: tabler.Plus(),
            ),
          ),
        ),
      );
      expect(_tablerColorOf(tester), inactive);
    });

    testWidgets('亮色：裸放图标取默认图标色（onSurfaceVariant）', (tester) async {
      await tester.pumpWidget(_host(const AppIconTheme(child: tabler.Plus())));
      expect(_tablerColorOf(tester), _defaultIconColorOf(Brightness.light));
    });

    testWidgets('暗色：裸放图标取默认图标色（onSurfaceVariant）', (tester) async {
      await tester.pumpWidget(
        _host(
          const AppIconTheme(child: tabler.Plus()),
          brightness: Brightness.dark,
        ),
      );
      expect(_tablerColorOf(tester), _defaultIconColorOf(Brightness.dark));
    });

    testWidgets('明暗切换：图标色跟着变（InheritedTheme 必须通知子树）', (tester) async {
      await tester.pumpWidget(_host(const AppIconTheme(child: tabler.Plus())));
      await tester.pumpAndSettle();
      expect(_tablerColorOf(tester), _defaultIconColorOf(Brightness.light));

      await tester.pumpWidget(
        _host(
          const AppIconTheme(child: tabler.Plus()),
          brightness: Brightness.dark,
        ),
      );
      // ⚠️ 必须等动画：`MaterialApp` 的主题切换走 `AnimatedTheme`（200ms 插值），
      // 只 pump 一帧读到的仍是**旧主题**的色——第一版测试就是因此误判"桥接坏了"。
      await tester.pumpAndSettle();
      expect(
        _tablerColorOf(tester),
        _defaultIconColorOf(Brightness.dark),
        reason: '切换主题后图标必须重新取色（data 恒定 ⇒ 不通知 ⇒ 色不变）',
      );
    });

    testWidgets('显式色优先：图标自带 colorFilter 时不被桥接动过', (tester) async {
      const ColorFilter explicit = ColorFilter.mode(
        Color(0xFF00FF00),
        BlendMode.srcIn,
      );
      await tester.pumpWidget(
        _host(
          const AppIconTheme(
            child: IconTheme(
              data: IconThemeData(color: Color(0xFF111111)),
              child: tabler.Plus(colorFilter: explicit),
            ),
          ),
        ),
      );
      expect(
        _iconFilterArgOf(tester),
        explicit,
        reason: '调用点显式指定的色必须原样保留（否则等于把显式配色全改掉了）',
      );
    });

    testWidgets('外层 tabler IconTheme 显式色也优先（桥接只在没人管时才出手）', (
      tester,
    ) async {
      const Color tablerSide = Color(0xFF0000FF);
      await tester.pumpWidget(
        _host(
          const AppIconTheme(
            child: tabler.IconTheme(
              data: tabler.IconThemeData(color: tablerSide),
              child: IconTheme(
                data: IconThemeData(color: Color(0xFF111111)),
                child: tabler.Plus(),
              ),
            ),
          ),
        ),
      );
      expect(_tablerColorOf(tester), tablerSide);
    });
  });
}
