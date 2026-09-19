import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart' as official;
import 'package:flutter_math_fork/flutter_math.dart' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/editor/blocks/attachment_block_component.dart';
import 'package:sinan/src/editor/blocks/callout_block_component.dart';
import 'package:sinan/src/editor/blocks/code_block_component.dart';
import 'package:sinan/src/editor/blocks/formula_block_component.dart';
import 'package:sinan/src/editor/blocks/ref_block_component.dart';
import 'package:sinan/src/editor/blocks/toggle_block_component.dart';
import 'package:sinan/src/editor/blocks/custom_block_components.dart';
import 'package:sinan/src/editor/core/editor_typography.dart';
import 'package:sinan/src/editor/core/note_document_adapter.dart';
import 'package:sinan/src/theme/app_theme.dart';

/// 被测排版：与编辑器视图同构（正文 16 / 行高 1.7）。
const EditorTypography _typography = EditorTypography(
  fontSize: 16,
  lineHeight: 1.7,
);

/// 自定义块组件（**代码块 / 公式 / 附件**）的验证。
///
/// 这些组件只有 **appflowy 编辑器**会消费——quill 仍是编辑器期间，
/// 它们只能靠测试验收。这里用真编辑器 + 真主题 + 主题桥渲染
/// （脚手架与迁移前 spike 验证同构），断言"能渲染 + 行为正确"。
void main() {
  group('注册表：官方标准件 + 我们的增量', () {
    test('三个自定义块都在，且官方件未被替换', () {
      final Map<String, BlockComponentBuilder> builders =
          sinanBlockComponentBuilders(
            typography: _typography,
            markerColor: const Color(0xFF3B6FD4),
          );

      expect(
        builders.keys,
        containsAll(<String>[
          CodeBlockKeys.type,
          FormulaBlockKeys.type,
          AttachmentBlockKeys.type,
          CalloutBlockKeys.type,
          ToggleListBlockKeys.type,
          RefBlockKeys.type,
        ]),
      );
      // 官方标准件仍在（我们是"展开标准表再增量"，不是替换）
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
          'table/cell',
        ]),
      );
    });

    test('回车快捷键：我们的两个（代码块 / 折叠块）都排在官方标准件之前', () {
      // 顺序有意义——**先命中先赢**：这两个各自只接管自己的块类型
      // （`code` / `toggle_list`），都必须早于官方 `insertNewLine`，
      // 否则那两类块会被拆成两段（见两个事件的说明）。
      final List<CharacterShortcutEvent> events = sinanCharacterShortcutEvents(
        slashMenuStyle: SelectionMenuStyle.light,
      );
      expect(events.first.key, 'insert new line in code block');
      expect(events[1].key, 'insert new line in toggle list');
      expect(events.length, greaterThan(2));
    });
  });

  group('折叠块（容器）：节点工厂', () {
    test('折叠标题把 level 钳到 1..6；折叠列表不带 level', () {
      expect(
        toggleHeadingNode(level: 9).attributes[ToggleListBlockKeys.level],
        6,
      );
      expect(
        toggleHeadingNode(level: 0).attributes[ToggleListBlockKeys.level],
        1,
      );
      final Node list = toggleListNode();
      expect(list.type, ToggleListBlockKeys.type);
      expect(list.attributes.containsKey(ToggleListBlockKeys.level), isFalse);
      // 缺省 = 展开（官方同款容错：读的时候 `?? false`）
      expect(list.attributes[ToggleListBlockKeys.collapsed], isFalse);
      expect(toggleHeadingNode(level: 2).attributes[ToggleListBlockKeys.level], 2);
    });

    test('plainText **递归**子块（容器里的正文不能漏）', () {
      // 只扫顶层会把折叠块里的整段漏掉 ⇒ 字数、AI 索引、全文检索全跟着错。
      final Document doc = NoteDocumentAdapter.documentFromStoredContent(
        jsonEncode(<String, dynamic>{
          'v': 2,
          'format': 'blocks',
          'document': <String, dynamic>{
            'id': 'r00t01',
            'type': 'page',
            'children': <dynamic>[
              <String, dynamic>{
                'id': 't0ggl1',
                'type': ToggleListBlockKeys.type,
                'data': <String, dynamic>{
                  'delta': <dynamic>[
                    <String, dynamic>{'insert': '折叠标题'},
                  ],
                  'collapsed': false,
                },
                'children': <dynamic>[
                  <String, dynamic>{
                    'id': 'kid001',
                    'type': 'paragraph',
                    'data': <String, dynamic>{
                      'delta': <dynamic>[
                        <String, dynamic>{'insert': '容器里的正文'},
                      ],
                    },
                  },
                ],
              },
              <String, dynamic>{
                'id': 'aftr01',
                'type': 'paragraph',
                'data': <String, dynamic>{
                  'delta': <dynamic>[
                    <String, dynamic>{'insert': '后面的段落'},
                  ],
                },
              },
            ],
          },
        }),
      );

      expect(doc.root.children.first.children, hasLength(1));
      expect(
        NoteDocumentAdapter.plainTextFromDocument(doc),
        '折叠标题\n容器里的正文\n后面的段落',
      );
      // 折叠态不影响：`collapsed` 只是视图状态，文字仍在文档里、仍要计入。
      expect(
        NoteDocumentAdapter.plainTextFromDocument(
          NoteDocumentAdapter.documentFromStoredContent(
            jsonEncode(<String, dynamic>{
              'v': 2,
              'format': 'blocks',
              'document': <String, dynamic>{
                'id': 'r00t02',
                'type': 'page',
                'children': <dynamic>[
                  <String, dynamic>{
                    'id': 't0ggl2',
                    'type': ToggleListBlockKeys.type,
                    'data': <String, dynamic>{
                      'delta': <dynamic>[
                        <String, dynamic>{'insert': '标题'},
                      ],
                      'collapsed': true,
                    },
                    'children': <dynamic>[
                      <String, dynamic>{
                        'id': 'kid002',
                        'type': 'paragraph',
                        'data': <String, dynamic>{
                          'delta': <dynamic>[
                            <String, dynamic>{'insert': '折叠着的正文'},
                          ],
                        },
                      },
                    ],
                  },
                ],
              },
            }),
          ),
        ),
        '标题\n折叠着的正文',
      );
    });
  });

  group('Delta → 块模型：代码块不再是段落', () {
    test('连续 code-block 行**合并为一个** code 块（数据形态实测自 quill）', () {
      // 形态由探针实测（真 quill formatText 后的 toDelta）：
      // **文本段不带属性，块级属性挂在换行段上**——适配器按此读取。
      final Document doc = NoteDocumentAdapter.documentFromStoredContent(
        jsonEncode(<dynamic>[
          <String, dynamic>{'insert': '说明'},
          <String, dynamic>{'insert': '\n'},
          <String, dynamic>{'insert': 'line1'},
          <String, dynamic>{
            'insert': '\n',
            'attributes': <String, dynamic>{'code-block': true},
          },
          <String, dynamic>{'insert': 'line2'},
          <String, dynamic>{
            'insert': '\n',
            'attributes': <String, dynamic>{'code-block': true},
          },
        ]),
      );

      final List<String> types = doc.root.children
          .map((Node n) => n.type)
          .toList();
      expect(types, <String>['paragraph', 'code'], reason: '代码块应合成一块，而非逐行降级');
      expect(doc.root.children.last.delta!.toPlainText(), 'line1\nline2');
    });
  });

  group('渲染（真编辑器）', () {
    testWidgets('代码块：代码文本渲染出来，且仍可被选为文本块', (
      WidgetTester tester,
    ) async {
      await _pumpEditor(
        tester,
        document: _documentOf(<Node>[
          codeBlockNode(delta: Delta()..insert('void main() {')),
        ]),
      );
      expect(
        _renderedPlainTexts(tester).any(
          (String t) => t.contains('void main() {'),
        ),
        isTrue,
      );
    });

    testWidgets('公式：用 flutter_math_fork 渲染', (WidgetTester tester) async {
      await _pumpEditor(
        tester,
        document: _documentOf(<Node>[
          formulaBlockNode(latex: r'E=mc^2'),
        ]),
      );
      expect(find.byType(math.Math), findsOneWidget);
    });

    testWidgets('附件：渲染出卡片（文件名 + 大小）', (WidgetTester tester) async {
      await _pumpEditor(
        tester,
        document: _documentOf(<Node>[
          attachmentBlockNode(
            metaJson: jsonEncode(<String, dynamic>{
              'path': r'C:\media\attachments\1.pdf',
              'name': '报告.pdf',
              'size': 1024,
            }),
          ),
        ]),
      );
      expect(find.text('报告.pdf'), findsOneWidget);
      expect(find.text('1.0 KB'), findsOneWidget);
    });

    testWidgets('脏数据不崩渲染（公式空串 / 附件非 JSON）', (WidgetTester tester) async {
      await _pumpEditor(
        tester,
        document: _documentOf(<Node>[
          formulaBlockNode(latex: ''),
          attachmentBlockNode(metaJson: '{ 不是 json'),
        ]),
      );
      expect(find.text('公式数据损坏'), findsOneWidget);
      expect(find.text('附件数据损坏'), findsOneWidget);
    });
  });

  group('代码块回车：块内换行（不拆块）', () {
    testWidgets('光标在块中 → 插入换行，块数不变、类型不变', (
      WidgetTester tester,
    ) async {
      final Document doc = _documentOf(<Node>[
        codeBlockNode(delta: Delta()..insert('abc')),
      ]);
      final EditorState state = await _pumpEditor(tester, document: doc);

      state.selection = Selection.collapsed(
        Position(path: <int>[0], offset: 1),
      );
      await tester.pumpAndSettle();

      final bool handled = await insertNewLineInCodeBlock.handler(state);
      await tester.pumpAndSettle();

      expect(handled, isTrue);
      expect(doc.root.children.length, 1, reason: '不应被拆成两个块');
      expect(doc.root.children.first.type, CodeBlockKeys.type);
      expect(doc.root.children.first.delta!.toPlainText(), 'a\nbc');
    });

    testWidgets('非代码块不接管（交还官方处理器）', (WidgetTester tester) async {
      final Document doc = _documentOf(<Node>[paragraphNode(text: '正文')]);
      final EditorState state = await _pumpEditor(tester, document: doc);

      state.selection = Selection.collapsed(
        Position(path: <int>[0], offset: 1),
      );
      await tester.pumpAndSettle();

      expect(await insertNewLineInCodeBlock.handler(state), isFalse);
    });
  });
}

// ─────────────────────────── 测试脚手架 ───────────────────────────

Document _documentOf(List<Node> children) =>
    Document(root: pageNode(children: children));

/// 用真编辑器渲染（与迁移前 spike 验证同构：真主题 + 主题桥 + 本地化）。
Future<EditorState> _pumpEditor(
  WidgetTester tester, {
  required Document document,
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
      theme: AppTheme.light(),
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
            // 与视图同一来源（按块生效，故只放水平值）。
            padding: EditorTypography.blockPadding,
            textStyleConfiguration: TextStyleConfiguration(
              text: TextStyle(
                fontSize: 16,
                height: 1.7,
                color: AppTheme.light().colorScheme.onSurface,
                fontFamily: AppTheme.editorFont,
              ),
              lineHeight: 1.7,
            ),
          ),
          // 被测对象：我们的注册表与快捷键（含官方标准件）。
          blockComponentBuilders: sinanBlockComponentBuilders(
            typography: _typography,
            // 列表/待办标记的主题色（本文件不测标记渲染，给固定值）。
            markerColor: const Color(0xFF3B6FD4),
          ),
          characterShortcutEvents: sinanCharacterShortcutEvents(
            // 本文件不测菜单配色（另有 slash_menu_items_test 守着）。
            slashMenuStyle: SelectionMenuStyle.light,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

/// 渲染树上全部纯文本（appflowy 用官方 RichText 渲染内容）。
Set<String> _renderedPlainTexts(WidgetTester tester) {
  final Set<String> out = <String>{};
  for (final Widget w in tester.allWidgets) {
    if (w is official.RichText) {
      out.add(w.text.toPlainText());
    } else if (w is official.Text) {
      out.add(w.data ?? w.textSpan?.toPlainText() ?? '');
    }
  }
  return out;
}
