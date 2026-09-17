import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sinan/src/notes/services/note_code_syntax.dart';

/// 代码块语法高亮回归闸门。
///
/// 曾有一个"从不高亮"的 bug：highlight 的解析树里 className 挂在分支节点、
/// 叶子节点 className=null，`_appendTokenSpans` 递归时丢了父级 className，
/// 导致所有 token 无色。本文件锁住"token 必须真正着色"。
void main() {
  /// 收集 span 树里所有（文本, 样式）叶子。
  List<(String, TextStyle?)> leaves(InlineSpan span) {
    final List<(String, TextStyle?)> out = <(String, TextStyle?)>[];
    void walk(InlineSpan s) {
      final TextStyle? style = s.style;
      if (s is TextSpan) {
        if (s.text != null) out.add((s.text!, style));
        s.children?.forEach(walk);
      }
    }

    walk(span);
    return out;
  }

  Future<TextSpan> pumpSpan(WidgetTester tester, String code) async {
    late TextSpan captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            captured = buildHighlightedCodeSpan(context, code, null);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return captured;
  }

  testWidgets('关键字 / 字符串真正着色（分支节点 className 下传）', (tester) async {
    final TextSpan span = await pumpSpan(
      tester,
      "import { createApp } from 'vue'",
    );
    final List<(String, TextStyle?)> tokens = leaves(span);

    final (String, TextStyle?) importToken = tokens.firstWhere(
      (t) => t.$1 == 'import',
    );
    expect(importToken.$2?.color, isNotNull, reason: '关键字应有颜色');
    expect(importToken.$2?.fontWeight, FontWeight.w600);

    final (String, TextStyle?) stringToken = tokens.firstWhere(
      (t) => t.$1 == "'vue'",
    );
    expect(stringToken.$2?.color, isNotNull, reason: '字符串应有颜色');
  });

  testWidgets('多行逐行着色不丢行', (tester) async {
    final TextSpan span = await pumpSpan(tester, 'final a = 1;\nprint(a);');
    final List<(String, TextStyle?)> tokens = leaves(span);

    expect(tokens.any((t) => t.$1 == '\n'), isTrue, reason: '换行要保留');
    final (String, TextStyle?) finalToken = tokens.firstWhere(
      (t) => t.$1 == 'final',
    );
    expect(finalToken.$2?.color, isNotNull);
    final (String, TextStyle?) printToken = tokens.firstWhere(
      (t) => t.$1 == 'print',
    );
    expect(printToken.$2?.color, isNotNull, reason: 'built_in 应着色');
  });

  testWidgets('无法识别的纯文本回退无色渲染，不崩', (tester) async {
    final TextSpan span = await pumpSpan(tester, '………………');
    expect(leaves(span), isNotEmpty);
  });
}
