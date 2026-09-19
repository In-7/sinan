import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/app/settings_panel.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/domain/settings.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sqlite3/sqlite3.dart';

/// 设置面板的结构闸门（2026-09-18 重构：行组件换成 M3 `ListTile`、新增「关于」分区）。
///
/// 钉的是**结构性事实**，不是像素：三分区都在、默认落在「外观」、每个设置项都带
/// 说明文字（M3 `subtitle` —— 它正是"把设计理由从注释搬到 UI"的那一格）、
/// 「关于」里三条信息齐备。观感仍要靠上机看。
void main() {
  late Database db;
  late NoteStore notes;
  late SettingsStore settings;

  const String kDataDir = r'C:\Users\test\AppData\Roaming\sinan';

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    notes = NoteStore(db);
    settings = SettingsStore(db);
  });

  tearDown(() => db.close());

  /// 挂一个能打开设置面板的最小宿主：面板从 `appNavigatorKey` 的 Overlay 取出，
  /// 所以 MaterialApp 必须带上这个 key。
  Future<void> openPanel(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          noteStoreProvider.overrideWithValue(notes),
          settingsStoreProvider.overrideWithValue(settings),
          appDataDirProvider.overrideWithValue(kDataDir),
        ],
        child: MaterialApp(
          navigatorKey: appNavigatorKey,
          theme: AppTheme.light(),
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => showSettingsPanel(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> goto(WidgetTester tester, String section) async {
    await tester.tap(find.text(section));
    await tester.pumpAndSettle();
  }

  testWidgets('三分区都在，默认落在「外观」', (WidgetTester tester) async {
    await openPanel(tester);

    expect(find.text('设置'), findsOneWidget);
    // 分区名出现两次 = 左导航项 + 右侧分区标题；未选中的只有导航那一次。
    expect(find.text('外观'), findsNWidgets(2), reason: '默认分区标题应落在右侧');
    expect(find.text('编辑器'), findsOneWidget, reason: '导航少了分区：编辑器');
    expect(find.text('关于'), findsOneWidget, reason: '导航少了分区：关于');
    // 默认「外观」：明暗两档可见。
    expect(find.text('浅色'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);
  });

  testWidgets('「外观」的设置项带说明文字（M3 ListTile 的 subtitle）', (
    WidgetTester tester,
  ) async {
    await openPanel(tester);

    expect(find.text('明暗'), findsOneWidget);
    expect(
      find.textContaining('点一下立刻生效'),
      findsOneWidget,
      reason: '说明文字丢了 —— 设计理由又回到只有代码注释知道的状态',
    );
  });

  testWidgets('「编辑器」：三项都在，两个连续值项各带 Slider', (WidgetTester tester) async {
    await openPanel(tester);
    await goto(tester, '编辑器');

    expect(find.text('正文宽度'), findsOneWidget);
    expect(find.text('正文字号'), findsOneWidget);
    expect(find.text('行高（正文）'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(2));
    // 宽度是"少量互斥选项" ⇒ M3 的 SegmentedButton（不是 Radio / 下拉）。
    expect(find.byType(SegmentedButton<EditorWidthMode>), findsOneWidget);
    expect(find.text('窄'), findsOneWidget);
    expect(find.text('标准'), findsOneWidget);
    expect(find.text('宽'), findsOneWidget);
  });

  testWidgets('「关于」：应用信息 / 开源许可 / 数据目录', (WidgetTester tester) async {
    await openPanel(tester);
    await goto(tester, '关于');

    expect(find.text('开源许可'), findsOneWidget);
    expect(find.text('数据目录'), findsOneWidget);
    // 数据目录路径以可选中文本呈现（AppData 路径肉眼抄不下）。
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text(kDataDir), findsOneWidget);
  });
}
