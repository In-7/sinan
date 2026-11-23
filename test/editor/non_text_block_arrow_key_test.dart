import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 回归闸门（补丁 27）：非文字块（图片/分隔线）上按方向键不抛异常。
///
/// 原 bug：`SelectionTransform.moveCursor` 在 `node.delta == null` 时
/// `throw UnimplementedError()`，键盘分发链断裂。
void main() {
  testWidgets('非文字块（分隔线）上按方向键不抛异常', (WidgetTester tester) async {
    final EditorState editorState = EditorState(
      document: Document(
        root: pageNode(
          children: <Node>[
            paragraphNode(text: '前一段'),
            dividerNode(),
            paragraphNode(text: '后一段'),
          ],
        ),
      ),
    );
    addTearDown(editorState.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppFlowyEditor(
            editorState: editorState,
            commandShortcutEvents: <CommandShortcutEvent>[
              moveCursorLeftCommand,
              moveCursorRightCommand,
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 选中分隔线块（非文字块，delta == null）。
    editorState.selection = Selection.collapsed(
      Position(path: <int>[1]),
    );
    await tester.pumpAndSettle();

    // 按 Arrow Left / Right：修复前会抛 UnimplementedError。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('非文字块（图片）上按方向键不抛异常', (WidgetTester tester) async {
    final EditorState editorState = EditorState(
      document: Document(
        root: pageNode(
          children: <Node>[
            paragraphNode(text: '前一段'),
            imageNode(url: 'https://example.com/a.png'),
            paragraphNode(text: '后一段'),
          ],
        ),
      ),
    );
    addTearDown(editorState.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppFlowyEditor(
            editorState: editorState,
            commandShortcutEvents: <CommandShortcutEvent>[
              moveCursorLeftCommand,
              moveCursorRightCommand,
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 选中图片块（非文字块，delta == null）。
    editorState.selection = Selection.collapsed(
      Position(path: <int>[1]),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
