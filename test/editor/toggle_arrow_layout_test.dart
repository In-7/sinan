import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import '../support/app_font.dart';

import 'package:sinan/src/domain/settings.dart';
import 'package:sinan/src/editor/blocks/custom_block_components.dart';
import 'package:sinan/src/editor/blocks/toggle_block_component.dart';
import 'package:sinan/src/editor/core/editor_typography.dart';
import 'package:sinan/src/theme/app_theme.dart';

/// 折叠箭头的**几何契约**（2026-11-18 实测修后固化）：
/// 图标 = [toggleArrowIconSize]（20）、热区 ≥24（整列 26×行盒）、
/// 轴线与列表圆点同轴、正文左缘与其它块同起点。
///
/// 旧实现把 `SizedBox(26×26)` 热区塞进标记列 ⇒ 图标被撑到 26、列宽顶到 30、
/// 箭头右偏 2px——本文件就是防它复发的钉。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('折叠箭头：图标 20、热区 ≥24、与圆点同轴、正文同起点', (WidgetTester tester) async {
    await loadAppFont();
    const EditorTypography typography = EditorTypography(
      fontSize: AppSettings.defaultFontSize,
      lineHeight: AppSettings.defaultLineHeight,
    );
    final ThemeData theme = AppTheme.light();
    final TextStyleConfiguration config = typography.toTextStyleConfiguration(
      text: theme.colorScheme.onSurface,
      link: theme.colorScheme.primary,
      codeBackground: theme.colorScheme.surfaceContainerHighest,
      muted: theme.colorScheme.onSurfaceVariant,
    );
    final EditorState state = EditorState(
      document: Document(
        root: pageNode(
          children: <Node>[
            Node(
              type: ToggleListBlockKeys.type,
              attributes: <String, dynamic>{
                ToggleListBlockKeys.delta: (Delta()..insert('折叠标题')).toJson(),
                ToggleListBlockKeys.collapsed: true,
              },
            ),
            bulletedListNode(delta: Delta()..insert('圆点对照')),
          ],
        ),
      ),
    );
    final EditorScrollController scroll = EditorScrollController(
      editorState: state,
    );
    addTearDown(() {
      scroll.dispose();
      state.dispose();
    });

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
          body: AppFlowyEditor(
            editorState: state,
            editorScrollController: scroll,
            editorStyle: EditorStyle.desktop(
              padding: EditorTypography.blockPadding,
              maxWidth: 800,
              textStyleConfiguration: config,
            ),
            blockComponentBuilders: sinanBlockComponentBuilders(
              typography: typography,
              markerColor: theme.colorScheme.primary,
            ),
            characterShortcutEvents: const <CharacterShortcutEvent>[],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // ⓪ 常量的文档口径 = 20（本文件曾被"注释与取值不符"咬过两次，钉死）。
    expect(toggleArrowIconSize, 20, reason: '文档口径 20——改值先改文档与本断言');

    // ① 图标 = 声明尺寸（20）：紧约束挤大是回归红线。
    expect(
      tester.getSize(find.byType(tabler.ChevronRight)),
      const Size.square(toggleArrowIconSize),
      reason: '图标该按 toggleArrowIconSize 渲染',
    );

    // ② 热区 ≥ 24（a11y 触达下限）：现在是整个标记列（26×行盒）。
    final Size hit = tester.getSize(
      find
          .ancestor(
            of: find.byType(tabler.ChevronRight),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(hit.width, greaterThanOrEqualTo(24), reason: '热区不小于 24');
    expect(hit.height, greaterThanOrEqualTo(24), reason: '热区不小于 24');

    // ③ 轴线（几何契约）：正文左缘 − 26 + 11 = 标记内容中心——箭头必须在那。
    // （不与圆点字形比：`find.text` 量的是**字形盒**中心，墨迹中心有 ≤1px 离散。）
    final double toggleTextLeft = tester
        .getRect(find.text('折叠标题', findRichText: true))
        .left;
    expect(
      tester.getCenter(find.byType(tabler.ChevronRight)).dx,
      closeTo(toggleTextLeft - 15, 0.5),
      reason: '箭头在标记列内容中心（正文左缘 − 26 + 11）',
    );

    // ④ 正文左缘：折叠块与列表同起点（标记列占位同宽）。
    expect(
      tester.getRect(find.text('折叠标题', findRichText: true)).left,
      closeTo(tester.getRect(find.text('圆点对照', findRichText: true)).left, 0.5),
      reason: '正文左缘与列表块同起点',
    );
  });
}
