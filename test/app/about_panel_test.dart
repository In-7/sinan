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
/// 换件最容易丢的是**功能**，所以这里钉五件：信息齐、玻璃档真在、**背后不压暗**、
/// 能关、**许可入口还在**（那是官方对话框原来最值钱的一件）。
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

  /// 2026-09-22 用户定：两处面板**背后的处理必须一致**。
  /// `showDialog` 默认那道 `Colors.black54` 会把整屏压暗，而设置面板那层遮罩浓度已归 0
  /// ⇒ 不统一的话，"同款面板"在两种幕布上观感差得比材质本身还大。
  ///
  /// ⚠️ **要钉的是"不压暗"，不是"没有屏障"**：屏障仍在（点外面关闭、挡住误点）。
  /// 判据取自 SDK 的真实分支（`ModalRoute.buildModalBarrier`，`widgets/routes.dart`）：
  /// ```
  /// if (barrierColor != null && barrierColor!.alpha != 0 && !offstage) {
  ///   barrier = AnimatedModalBarrier(color: ..., ...);   // 会压暗
  /// } else {
  ///   barrier = ModalBarrier(dismissible: ..., ...);     // 不带 color
  /// }
  /// ```
  /// ⇒ 树里**出现 `AnimatedModalBarrier` 就说明有压暗**；透明时那个 `ModalBarrier`
  /// 的 `color` 是 **null**（不是 `Colors.transparent`）。
  testWidgets('背后**不压暗**（屏障留着、不带颜色）', (WidgetTester tester) async {
    await open(tester);

    expect(
      find.byType(AnimatedModalBarrier),
      findsNothing,
      reason:
          '树里有 AnimatedModalBarrier ⇒ barrierColor 的 alpha ≠ 0，又压暗了'
          '（`showDialog` 默认 black54），与设置面板不一致',
    );
    final ModalBarrier barrier = tester.widget<ModalBarrier>(
      find.byType(ModalBarrier).last,
    );
    expect(barrier.color, isNull, reason: '屏障带了颜色 ⇒ 面板背后被压暗了');
    expect(barrier.dismissible, isTrue, reason: '屏障必须仍可点外关闭（只去颜色，不去行为）');
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
