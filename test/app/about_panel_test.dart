import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/app_info.dart';
import 'package:sinan/src/app/settings_panel.dart';
import 'package:sinan/src/theme/app_float_surface.dart';
import 'package:sinan/src/theme/app_theme.dart';

/// **关于面板**（主菜单 →「关于」）的回归。
///
/// 2026-09-22 它从框架原生 `showAboutDialog` 换成**自绘玻璃面板**（实色底 + 光泽，
/// 与设置面板**同一档**）。换件的原因是外观：官方对话框的面板 Material 在
/// `_DialogRoute` 内部、而 `showAboutDialog` 又没有 `builder` 参数（SDK 签名里查过）
/// ⇒ 想给面板加任何自绘层都无处下手。
///
/// 换件最容易丢的是**功能**，所以这里钉五件：信息齐、玻璃档真在、**背后压暗且
/// 浓度与全 app 浮层一致**、能关、**许可入口还在**（那是官方对话框原来最值钱的一件）。
void main() {
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => FilledButton(
              onPressed: () => showAboutPanel(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('信息齐 + 玻璃光泽 + **实色**底（不透明）', (WidgetTester tester) async {
    await open(tester);

    expect(find.text('${AppInfo.name} ${AppInfo.version}'), findsOneWidget);
    expect(
      find.text(AppInfo.description),
      findsOneWidget,
      reason: '简介丢了 —— 那是旧对话框 applicationLegalese 那一格',
    );

    final AppFloatSurface surface = tester.widget<AppFloatSurface>(
      find.byType(AppFloatSurface),
    );
    expect(surface.glass, isTrue, reason: '面板的"玻璃感"全靠光泽 + 光边（实色底下没有透光可言）');
    expect(
      surface.color,
      AppTheme.floatSurface(Brightness.light),
      reason: '底必须取 floatSurface（与设置面板同一档），别手写颜色 / opacity',
    );
    expect(surface.color?.a, 1, reason: '底变半透 ⇒ 背后内容透出清晰字影（面积越大越明显）');
    expect(surface.blur, isFalse, reason: '实色底下模糊本来就看不见 ⇒ 留着只是白付一次 saveLayer');
    expect(
      find.descendant(
        of: find.byType(AppFloatSurface),
        matching: find.byType(BackdropFilter),
      ),
      findsNothing,
      reason: '实色 + BackdropFilter = 白付一次 saveLayer（没有观感收益）',
    );
  });

  /// 2026-11-09 用户定：全 app 四个浮层**共用一套幕布**（设置 / 关于 / 回收站 /
  /// 台账），都要有明确前后景。`showDialog` 默认那道 `Colors.black54` 是硬编码，
  /// 这里改用与设置同源的 [floatScrimAlpha] + M3 scrim 色角色。
  ///
  /// 判据取自 SDK 的真实分支（`ModalRoute.buildModalBarrier`，`widgets/routes.dart`）：
  /// `barrierColor.alpha != 0` ⇒ 生成 [AnimatedModalBarrier]；等于 0 ⇒ 只剩不带
  /// 颜色的 [ModalBarrier]。现在要钉的是**前者**，且浓度必须等于公共常量。
  testWidgets('背后压暗且浓度与全 app 浮层一致', (WidgetTester tester) async {
    await open(tester);

    final AnimatedModalBarrier barrier = tester.widget<AnimatedModalBarrier>(
      find.byType(AnimatedModalBarrier),
    );
    expect(
      barrier.color.value?.a,
      closeTo(floatScrimAlpha, 0.01),
      reason: '屏障浓度必须取 floatScrimAlpha（与设置 / 回收站 / 台账同源）',
    );
    final ModalBarrier modal = tester.widget<ModalBarrier>(
      find.byType(ModalBarrier).last,
    );
    expect(modal.dismissible, isTrue, reason: '屏障必须仍可点外关闭');
  });

  testWidgets('「关闭」关掉面板', (WidgetTester tester) async {
    await open(tester);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    expect(find.byType(AppFloatSurface), findsNothing, reason: '「关闭」没把关掉');
  });

  testWidgets('「查看许可」：先关面板再推许可页（不关会被面板压住）', (WidgetTester tester) async {
    await open(tester);
    await tester.tap(find.text('查看许可'));
    await tester.pumpAndSettle();

    expect(
      find.byType(AppFloatSurface),
      findsNothing,
      reason: '关于面板没关 —— 许可页是**路由**，会被它压住（点了像没反应）',
    );
    expect(find.byType(LicensePage), findsOneWidget);
  });
}
