import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/ask_panel.dart';
import 'package:sinan/src/app/settings_panel.dart' show appNavigatorKey;
import 'package:sinan/src/theme/app_float_surface.dart';
import 'package:sinan/src/theme/app_theme.dart';

/// 问笔记面板的**键盘可达性**（`docs/ui_rewrite_plan.md` §5.2）。
///
/// 只钉两件与焦点有关的事实，答案内容那条线由 `answer_service` 自己的测试负责：
/// 打开即聚焦输入框（面板的唯一目的就是"问一句"）、以及 Tab 不会漏到面板外。
void main() {
  /// 挂一个能打开面板的最小宿主：面板从 `appNavigatorKey` 的 Overlay 取出，
  /// 所以 MaterialApp 必须带上这个 key。
  ///
  /// 宿主里特意放一个 `autofocus` 的可聚焦控件，模拟"背后占着焦点的编辑器"——
  /// 有它，下面那条"Tab 不漏出面板"才是真闸门。
  Future<void> openPanel(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          navigatorKey: appNavigatorKey,
          theme: AppTheme.light(),
          home: const Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Focus(
                    autofocus: true,
                    child: SizedBox(width: 40, height: 20),
                  ),
                  FilledButton(onPressed: showAskPanel, child: Text('open')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('打开即聚焦输入框，且 Tab 一直在面板内（焦点陷阱）', (WidgetTester tester) async {
    await openPanel(tester);

    // ① 焦点落在输入框上：这个面板打开就是要打字。
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isTrue,
      reason: '打开后输入框没拿到焦点 ⇒ 还得先点一下才能打字',
    );

    // ② 焦点陷阱：Tab 不得漏到遮罩背后（背后那个 `autofocus` 的控件就是"外面"）。
    //
    // ⚠️ 判据的"面板根"要取**壳**（`AppFloatSurface`），不能取 `TextField`——
    // 取输入框的话，Tab 一移到面板内别的控件就会被误判成"漏出去了"。
    final Element panel = tester.element(find.byType(AppFloatSurface));
    bool insidePanel(FocusNode? node) {
      final BuildContext? ctx = node?.context;
      if (ctx == null) return false;
      if (ctx == panel) return true;
      bool found = false;
      ctx.visitAncestorElements((Element e) {
        if (e == panel) {
          found = true;
          return false;
        }
        return true;
      });
      return found;
    }

    for (int i = 0; i < 12; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        insidePanel(FocusManager.instance.primaryFocus),
        isTrue,
        reason: '第 ${i + 1} 次 Tab 漏出了面板（焦点陷阱失效）',
      );
    }
  });
}
