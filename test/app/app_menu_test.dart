import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/app_menu.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/domain/settings.dart';
import 'package:sinan/src/theme/app_float_surface.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sqlite3/sqlite3.dart';

/// **主菜单**（右上角那个）的回归。
///
/// 2026-09-22 它从 SDK 的 `PopupMenuButton` 换成自家锚定浮层（`AppPopover`），
/// 目的只有一个：**能加局部模糊**——SDK 的面板在 `_PopupMenuRoute` 内部，
/// 插不进 `BackdropFilter`（这就是"改了 Layer 却看不出"之后查出的路）。
///
/// 换件最容易丢的是行为，所以这里钉三件：
/// 1. 四项都在、点开即见；
/// 2. **磨砂档真的在**（`BackdropFilter` + 半透明底）——否则这次换件白做，
///    也防有人把它"顺手改回"实色浮层；
/// 3. 点一项**先关面板、再执行**（"选完即关"是菜单的常规行为）。
void main() {
  late Database db;
  late ProviderContainer container;

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    container = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(SettingsStore(db)),
        noteStoreProvider.overrideWithValue(NoteStore(db)),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    db.close();
  });

  Future<void> pumpMenu(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(body: Center(child: AppMenuButton())),
        ),
      ),
    );
  }

  testWidgets('点开：四项都在，且面板是磨砂档（局部模糊 + 半透明底）', (WidgetTester tester) async {
    await pumpMenu(tester);
    expect(find.text('设置'), findsNothing, reason: '还没点就展开了');

    await tester.tap(find.byTooltip('菜单'));
    await tester.pumpAndSettle();

    for (final String label in <String>['设置', '关于', '明暗切换', '退出']) {
      expect(find.text(label), findsOneWidget, reason: '菜单少了「$label」');
    }

    expect(
      find.descendant(
        of: find.byType(AppFloatSurface),
        matching: find.byType(BackdropFilter),
      ),
      findsOneWidget,
      reason: '主菜单的局部模糊没了（又被换回实色浮层了？）',
    );
    final AppFloatSurface surface = tester.widget<AppFloatSurface>(
      find.byType(AppFloatSurface),
    );
    expect(surface.blur, isTrue);
    expect(surface.color?.a, lessThan(1), reason: '模糊要看得出来，底色必须够透（实色会把模糊整块盖住）');
  });

  testWidgets('点「明暗切换」：面板收起 + 设置真的被写回', (WidgetTester tester) async {
    await pumpMenu(tester);
    // 初值是多少不重要（默认走 `light`），**是它翻过去了**才是判据。
    final ThemeBrightnessMode before = container
        .read(settingsProvider)
        .brightnessMode;

    await tester.tap(find.byTooltip('菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('明暗切换'));
    await tester.pumpAndSettle();

    expect(find.text('明暗切换'), findsNothing, reason: '选完没有收起面板');
    expect(
      container.read(settingsProvider).brightnessMode,
      isNot(before),
      reason: '明暗没有真的切（回调那条线断了）',
    );
  });
}
