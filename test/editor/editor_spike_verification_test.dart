import 'package:appflowy_editor/appflowy_editor.dart';
// 官方 material：appflowy 内部用的是它。introspection 必须用官方类型，
// 否则 find.byType 找不到 appflowy 建立的 widget（material_ui 的同名
// Material 层类型是**另一套**）。加前缀避免与本文件的 material_ui 冲突。
import 'package:flutter/material.dart' as official;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/theme/app_theme.dart';

/// spike 验证（迁移前置门：5 项清单）的**可自动化部分**。
/// 结论文档见 `docs/editor_migration_spike.md`（spike 临时页已删除，
/// 本文件自带脚手架，不依赖它）。
///
/// 覆盖：
/// - ② 基础编辑：官方块组件清单（含"无代码块"这一事实）+ 六类块真实渲染；
/// - ③ 块虚拟化：400 块文档，统计实际构建的块数量；
/// - ④ 明暗主题：编辑器内部读到的官方 Theme 是否来自我们的主题；
/// - ⑤ material_ui 主题桥：带桥 / 不带桥的对照。
///
/// **不覆盖（必须人工，见 docs/editor_migration_spike.md）**：
/// - ① 中文输入法：微软拼音/搜狗的真实候选框、组合串上屏、退格删组合。
///   原因（实查）：appflowy 的输入服务只消费 IME **增量**（
///   `updateEditingValueWithDeltas`），而 Flutter 测试框架的 `TestTextInput`
///   **没有** delta 通道（`flutter_test/lib/src/test_text_input.dart` 无该方法），
///   且 appflowy 的 `updateEditingValue` 是空实现——测试框架无法驱动组合串。
/// - ④ 的视觉部分：窗口 Mica 与编辑器底色的融合观感。
void main() {
  group('spike ②：官方块组件清单（含"无代码块"这一事实）', () {
    testWidgets('官方自带 9 类块组件；代码块不在注册表内', (WidgetTester tester) async {
      await _pumpEditor(
        tester,
        theme: AppTheme.light(),
        document: _documentOf(<Node>[paragraphNode(text: '探针')]),
      );

      final Map<String, BlockComponentBuilder> builders = tester
          .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
          .blockComponentBuilders;

      // 报告用：把官方注册表实际内容打印出来（结论以此为准，不靠记忆）。
      debugPrint('[spike] 官方块组件注册表 keys = ${builders.keys.toList()}');

      expect(
        builders.keys,
        containsAll(<String>[
          'page',
          'paragraph',
          'heading',
          'bulleted_list',
          'numbered_list',
          'todo_list',
          'quote',
          'divider',
          'image',
          'table',
          'table/cell', // 实测键名是 table/cell（非 table_cell）
        ]),
      );

      // 关键缺口：官方 6.2.0 **没有**代码块块组件
      // （只有 Markdown 插件的 CodeBlockNodeParser——能解析，无渲染组件）。
      expect(builders.containsKey('codeBlock'), isFalse);
      expect(builders.containsKey('code'), isFalse);
    });
  });

  group('spike ②：六类块真实渲染', () {
    testWidgets('段落/标题/无序/有序/待办/引用/分隔线 全部出现在树上', (
      WidgetTester tester,
    ) async {
      final List<String> texts = <String>[
        '正文段落',
        '标题一',
        '无序项',
        '有序项',
        '待办已勾',
        '待办未勾',
        '引用文本',
      ];
      await _pumpEditor(
        tester,
        theme: AppTheme.light(),
        document: _documentOf(<Node>[
          paragraphNode(text: '正文段落'),
          headingNode(level: 1, text: '标题一'),
          bulletedListNode(text: '无序项'),
          numberedListNode(delta: Delta()..insert('有序项')),
          todoListNode(checked: true, text: '待办已勾'),
          todoListNode(checked: false, text: '待办未勾'),
          quoteNode(delta: Delta()..insert('引用文本')),
          dividerNode(),
          paragraphNode(text: '尾部'),
        ]),
      );

      final Set<String> rendered = _renderedPlainTexts(tester);
      for (final String t in texts) {
        expect(
          rendered.any((String r) => r.contains(t)),
          isTrue,
          reason: '块「$t」未出现在渲染树上',
        );
      }
    });
  });

  group('spike ③：块虚拟化', () {
    testWidgets('400 块的文档只构建视口内少量块（惰性渲染成立）', (
      WidgetTester tester,
    ) async {
      const int total = 400;
      await _pumpEditor(
        tester,
        theme: AppTheme.light(),
        document: _documentOf(<Node>[
          for (int i = 0; i < total; i++) paragraphNode(text: '段落 $i'),
        ]),
      );

      final int realized = _renderedPlainTexts(
        tester,
      ).where((String t) => RegExp(r'^段落 \d+$').hasMatch(t)).length;
      debugPrint('[spike] 400 块文档实际构建块数 = $realized');

      expect(realized, greaterThan(0), reason: '视口内应有块被构建');
      expect(
        realized,
        lessThan(total ~/ 4),
        reason: '若为全量构建（$total），说明虚拟化未生效',
      );
    });
  });

  group('spike ④/⑤：主题贯通与 material_ui 主题桥', () {
    testWidgets('带桥：编辑器内部读到的是我们的深色主题', (WidgetTester tester) async {
      final ThemeData our = AppTheme.dark();
      await _pumpEditor(
        tester,
        theme: our,
        document: _documentOf(<Node>[paragraphNode(text: '暗色正文')]),
      );

      // 官方 Theme.of 读到的 = appflowy 块组件实际拿到的主题。
      final official.ThemeData seen = official.Theme.of(
        _insideEditorContext(tester),
      );
      debugPrint(
        '[spike] 带桥 appflowy 读到的 official Theme: '
        'brightness=${seen.brightness}, '
        'scaffoldBackground=${seen.scaffoldBackgroundColor}, '
        'primary=${seen.colorScheme.primary}',
      );

      expect(seen.brightness, Brightness.dark);
    });

    testWidgets('不带桥（对照）：编辑器内部读到的不是我们的深色主题', (
      WidgetTester tester,
    ) async {
      await _pumpEditor(
        tester,
        theme: AppTheme.dark(),
        document: _documentOf(<Node>[paragraphNode(text: '暗色正文')]),
        bridge: false,
      );
      final official.ThemeData seen = official.Theme.of(
        _insideEditorContext(tester),
      );
      debugPrint(
        '[spike] 不带桥 appflowy 读到的 official Theme: '
        'brightness=${seen.brightness}',
      );
      expect(
        seen.brightness,
        isNot(Brightness.dark),
        reason: '不带桥却拿到了深色主题，说明颜色另有来源，桥的结论不成立',
      );
    });

    testWidgets('正文文字色取自我们主题（而非 EditorStyle.desktop 的硬编码黑）', (
      WidgetTester tester,
    ) async {
      final ThemeData our = AppTheme.dark();
      await _pumpEditor(
        tester,
        theme: our,
        document: _documentOf(<Node>[paragraphNode(text: '暗色正文')]),
      );

      final Color? color = _renderedColorOf(tester, '暗色正文');
      debugPrint(
        '[spike] 正文文字色 = $color；期望 onSurface = ${our.colorScheme.onSurface}',
      );
      expect(color, isNotNull, reason: '未取到正文文字色');
      expect(color, our.colorScheme.onSurface);
      expect(color, isNot(const Color(0xFF000000)), reason: '落回硬编码黑即为失败');
    });
  });

  // spike ①（输入面）：**无法在 flutter_test 内驱动**，故无自动化用例——
  // appflowy 只消费 IME 增量（`updateEditingValueWithDeltas`），而
  // `TestTextInput` 无 delta 通道、appflowy 的 `updateEditingValue` 又是空实现；
  // 裸按键只走命令类快捷键、不插字符。曾有一条 `skip: true` 的"直输字符"探针，
  // 但它永不可跑通，徒增一个 skipped 计数，已移除。① 现仅人工验证，清单见
  // `docs/editor_migration_spike.md`。
}

// ─────────────────────────── 测试脚手架 ───────────────────────────

/// **根节点必须是 `page`**（appflowy 的 `Document.blank()` 即 `Node(type:'page')`，
/// `PageBlockComponentBuilder` 只认 `PageBlockKeys.type`）。写成 `document`
/// 会整页空白——本文件最初就踩了，它同时暴露了适配器的同款 bug。
Document _documentOf(List<Node> children) =>
    Document(root: pageNode(children: children));

/// 编辑器子树内部的 BuildContext（用于读 appflowy 实际拿到的 official Theme）。
/// 不依赖具体 widget 类型——Scrollable 等在 appflowy 里未必都是官方 widgets 层类型。
BuildContext _insideEditorContext(WidgetTester tester) => tester.element(
  find
      .descendant(
        of: find.byType(AppFlowyEditor),
        matching: find.byWidgetPredicate((Widget w) => true),
      )
      .first,
);

Future<EditorState> _pumpEditor(
  WidgetTester tester, {
  required ThemeData theme,
  required Document document,
  bool bridge = true,
}) async {
  final EditorState state = EditorState(document: document);
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
      // 与 main.dart 同构：官方本地化委托 + appflowy 委托。
      // appflowy 的块组件占位符依赖它，缺失会抛
      // "AppFlowyEditorLocalizations not found"。
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        ...GlobalMaterialLocalizations.delegates,
        AppFlowyEditorLocalizations.delegate,
      ],
      supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
      builder: (BuildContext context, Widget? child) => bridge
          // 与 main.dart:254 同一处桥接。
          // ignore: deprecated_member_use
          ? MaterialUiCompatibilityBridge(child: child!)
          : child!,
      home: _EditorHarness(state: state, scroll: scroll),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

/// 编辑器配置载体：与迁移前 spike 页**逐项对齐**（spike 页已删除，
/// 故这里独立复刻，不依赖它）。
class _EditorHarness extends StatelessWidget {
  const _EditorHarness({required this.state, required this.scroll});

  final EditorState state;
  final EditorScrollController scroll;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: AppFlowyEditor(
        editorState: state,
        editorScrollController: scroll,
        autoFocus: true,
        editorStyle: EditorStyle.desktop(
          padding: const EdgeInsets.symmetric(horizontal: 72),
          cursorColor: scheme.primary,
          selectionColor: scheme.primary.withValues(alpha: 0.28),
          textStyleConfiguration: TextStyleConfiguration(
            text: TextStyle(
              fontSize: 16,
              height: 1.7,
              color: scheme.onSurface,
              fontFamily: AppTheme.editorFont,
            ),
            href: TextStyle(
              color: scheme.primary,
              decoration: TextDecoration.underline,
            ),
            code: TextStyle(
              fontFamily: AppTheme.monoFont,
              color: scheme.primary,
            ),
            autoComplete: TextStyle(color: scheme.onSurfaceVariant),
            lineHeight: 1.7,
          ),
        ),
      ),
    );
  }
}

/// 收集渲染树上所有文本的纯文本内容（appflowy 用官方 RichText 渲染正文）。
Set<String> _renderedPlainTexts(WidgetTester tester) {
  final Set<String> out = <String>{};
  for (final Widget w in tester.allWidgets) {
    if (w is official.RichText) {
      out.add(w.text.toPlainText());
    } else if (w is official.Text) {
      // Text.rich 走 textSpan，data 为 null——两种都要收。
      out.add(w.data ?? w.textSpan?.toPlainText() ?? '');
    }
  }
  return out;
}

/// 取"包含 [needle] 的文本"的颜色。
Color? _renderedColorOf(WidgetTester tester, String needle) {
  for (final Widget w in tester.allWidgets) {
    if (w is official.RichText && w.text.toPlainText().contains(needle)) {
      return w.text.style?.color;
    }
  }
  return null;
}
