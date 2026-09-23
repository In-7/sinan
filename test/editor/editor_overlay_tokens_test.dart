import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart' as official;
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/editor/blocks/custom_block_components.dart';
import 'package:sinan/src/editor/core/editor_typography.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/tokens.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

/// **编辑器子树内两个浮层菜单的"浮层三件套"**（2026-09-15 探针实测后钉住）。
///
/// 背景：子树跑在官方 material + `MaterialUiCompatibilityBridge` 上，而那座桥
/// **不透传 `menuTheme`** ⇒ 子树里的 `MenuAnchor` 会落到 M3 默认（带种子色的
/// `surfaceContainerHigh` + elevation 3 + radius 4 + 无描边，实测亮色 `#E9EFEE`），
/// 与场外菜单（`floatSurface` + `menuBorder` + `menuElevation`）不是一族。
/// 修法：应用侧显式传 `MenuStyle`（`widgets/float_menu_style.dart`）；
/// 斜杠菜单的投影/描边是 vendored 硬编码，走补丁 14 对齐。
///
/// 这两条断言是**跨主题一致性**的闸门：谁把它改回 M3 默认，这里立刻红。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final FontLoader loader = FontLoader(AppTheme.editorFont)
      ..addFont(rootBundle.load('assets/fonts/LXGWNeoXiHeiScreen.ttf'));
    await loader.load();
  });

  testWidgets('块操作菜单：底色/描边/投影 = 浮层令牌', (WidgetTester tester) async {
    await _pumpEditor(tester);
    await _openBlockActionsMenu(tester);

    // 面板 = 弹层里 elevation 最高的那个 Material（0 的那些是条目自身的按钮）。
    final official.Material panel = tester
        .widgetList<official.Material>(find.byType(official.Material))
        .reduce((a, b) => a.elevation >= b.elevation ? a : b);

    expect(
      panel.color,
      AppTheme.floatSurface(Brightness.light),
      reason: '块菜单没走浮层底色（落到 M3 默认的染色 surface 了？）',
    );
    expect(panel.elevation, AppTheme.menuElevation, reason: '投影没对齐');
    final official.ShapeBorder shape = panel.shape!;
    expect(shape, isA<official.RoundedRectangleBorder>());
    expect(
      (shape as official.RoundedRectangleBorder).side.color,
      AppTheme.light().colorScheme.outlineVariant,
      reason: '描边没对齐（子树里取 outlineVariant，与 menuBorder 同源）',
    );
    expect(
      shape.borderRadius,
      BorderRadius.circular(Tokens.radiusSm),
      reason: '圆角应与场外菜单同一档',
    );
  });

  testWidgets('斜杠菜单：底色/描边/投影 = 浮层令牌（补丁 14）', (WidgetTester tester) async {
    await _pumpEditor(tester);
    // 点 “+” 会打开斜杠菜单（见 `_addBlock`）。
    await _tapHandle(tester, iconType: tabler.Plus);

    final Color expected = AppTheme.floatSurface(Brightness.light);
    final BoxDecoration panel = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .map((DecoratedBox d) => d.decoration)
        .whereType<BoxDecoration>()
        .firstWhere(
          (BoxDecoration d) => d.color == expected,
          orElse: () => throw StateError('没找到斜杠菜单面板（底色 $expected）'),
        );

    expect(
      (panel.border! as Border).top.color,
      AppTheme.light().colorScheme.outlineVariant,
      reason: '斜杠菜单没有描边 ⇒ 与应用侧菜单并置会显"扁"（补丁 14 被覆盖？）',
    );
    expect(panel.boxShadow, isNotEmpty, reason: '投影丢了');
    expect(
      panel.boxShadow!.first.blurRadius,
      greaterThan(6),
      reason: '投影仍是官方那套硬编码的短阴影（blur 5）⇒ 补丁 14 被覆盖？',
    );
  });
}

/// 悬停首块 → 点手柄上的某个按钮。
Future<void> _tapHandle(WidgetTester tester, {required Type iconType}) async {
  final Finder wrapper = find.byType(BlockComponentActionWrapper).first;
  final Finder block = find
      .descendant(of: wrapper, matching: find.byType(RichText))
      .first;

  final TestGesture mouse =
      await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await mouse.moveTo(tester.getCenter(block));
  await tester.pumpAndSettle();

  final Finder handle =
      find.descendant(of: wrapper, matching: find.byType(iconType));
  expect(handle, findsOneWidget, reason: '手柄没浮出（悬停没生效？）');
  await tester.tap(handle);
  await tester.pumpAndSettle();
}

Future<void> _openBlockActionsMenu(WidgetTester tester) =>
    _tapHandle(tester, iconType: tabler.GripVertical);

Future<void> _pumpEditor(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final ThemeData theme = AppTheme.light();
  final Document document = Document(
    root: pageNode(children: <Node>[paragraphNode(text: '甲')]),
  );
  final EditorState state = EditorState(document: document);
  addTearDown(state.dispose);

  const EditorTypography typography = EditorTypography(
    fontSize: 17,
    lineHeight: 1.5,
  );

  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        ...GlobalMaterialLocalizations.delegates,
        AppFlowyEditorLocalizations.delegate,
      ],
      supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
      builder: (BuildContext context, Widget? child) =>
          // ignore: deprecated_member_use
          MaterialUiCompatibilityBridge(child: child!),
      home: Scaffold(
        body: SizedBox(
          width: 1200,
          height: 900,
          child: AppFlowyEditor(
            editorState: state,
            editorStyle: EditorStyle.desktop(
              padding: EditorTypography.blockPadding,
              maxWidth: 720,
              textStyleConfiguration: typography.toTextStyleConfiguration(
                text: AppTheme.editorText(theme.brightness, theme.colorScheme),
                link: AppTheme.editorLink(theme.colorScheme),
                codeBackground: AppTheme.editorInlineCodeBg(theme.brightness),
                muted: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            blockComponentBuilders: sinanBlockComponentBuilders(
              typography: typography,
              markerColor: const Color(0xFF1565C0),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
