import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/editor/blocks/toggle_block_component.dart';
import 'package:sinan/src/editor/core/block_height_predictor.dart';
import 'package:sinan/src/editor/core/editor_typography.dart';

/// 折叠块（**容器**）的块高预测。
///
/// 为什么单独锁这几条：容器块的预测是"整体高度 = 自身 + 子块"，一旦折叠态
/// 忘了把子块记 0（或相反，展开时漏加子块），折叠块**后面**的所有块在
/// "块 ↔ 像素"换算里会整体偏移 —— 表现为目录跳转/查找定位落错位置。
/// 这里用纯逻辑（不开 widget）把三条口径钉死。
///
/// 真实排版下的"预测 vs 实测"由 `block_height_predictor_spike_test.dart`
/// 的通用管线把关（块类型无关），本文件只管**容器的加减法**。
void main() {
  const EditorTypography typography = EditorTypography(
    fontSize: 17,
    lineHeight: 1.5,
  );

  BlockHeightPredictor predictor() => BlockHeightPredictor(
    typography: typography,
    textStyleConfiguration: typography.toTextStyleConfiguration(
      text: const Color(0xFF000000),
      link: const Color(0xFF1565C0),
      codeBackground: const Color(0xFFEEEEEE),
      muted: const Color(0xFF757575),
    ),
    maxWidth: 720,
    blockPadding: EditorTypography.blockPadding,
  );

  /// 造一个折叠块节点（`level == null` ⇒ 折叠列表；有值 ⇒ 折叠标题）。
  Node toggle({
    bool collapsed = false,
    int? level,
    Iterable<Node> children = const <Node>[],
  }) => Node(
    type: ToggleListBlockKeys.type,
    attributes: <String, dynamic>{
      ToggleListBlockKeys.delta: (Delta()..insert('折叠标题')).toJson(),
      ToggleListBlockKeys.collapsed: collapsed,
      ToggleListBlockKeys.level: ?level,
    },
    children: children.toList(growable: false),
  );

  group('折叠块：容器几何', () {
    test('折叠 ⇒ 子块**不计入**（与没有子块的折叠块等高）', () {
      final BlockHeightPredictor p = predictor();
      final Node child = paragraphNode(text: '容器里的正文');

      final double collapsedEmpty = p.predict(toggle(collapsed: true))!;
      final double collapsedWithChild = p.predict(
        toggle(collapsed: true, children: <Node>[child]),
      )!;

      expect(collapsedWithChild, collapsedEmpty);
    });

    test('展开 ⇒ 高度 = 自身 + 子块高度之和', () {
      final BlockHeightPredictor p = predictor();
      final List<Node> children = <Node>[
        paragraphNode(text: '第一段子块'),
        paragraphNode(text: '第二段子块'),
      ];

      final double collapsed = p.predict(
        toggle(collapsed: true, children: children),
      )!;
      final double expanded = p.predict(toggle(children: children))!;
      final double childSum = children
          .map((Node child) => p.predict(child)!)
          .reduce((double a, double b) => a + b);

      expect(expanded, closeTo(collapsed + childSum, 0.01));
    });

    test('展开但还没有子块 ⇒ 多一行"点击添加内容"', () {
      final BlockHeightPredictor p = predictor();
      final double collapsed = p.predict(toggle(collapsed: true))!;
      final double expanded = p.predict(toggle())!;

      // 占位行 = 同一字号的一行文字 + [togglePlaceholderPadding]。
      expect(expanded, greaterThan(collapsed));
    });

    test('折叠标题比折叠列表高一档（同一份文本）', () {
      final BlockHeightPredictor p = predictor();
      final double list = p.predict(toggle(collapsed: true))!;
      final double heading1 = p.predict(toggle(collapsed: true, level: 1))!;
      final double heading2 = p.predict(toggle(collapsed: true, level: 2))!;

      expect(heading1, greaterThan(heading2));
      expect(heading2, greaterThan(list));
    });
  });
}
