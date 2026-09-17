import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../notes/services/formula_render.dart';
import 'non_text_block.dart';

/// 公式块（type = `formula`）：属性 `latex` = LaTeX 源串。
///
/// 与 Delta 嵌入的对应关系（见 `NoteDocumentAdapter`）：
/// `{"insert":{"formula":"E=mc^2"}}` ↔ `Node('formula', {latex: 'E=mc^2'})`。
/// 公式在 quill 侧本就是**独占一行的块级嵌入**，因此天然对齐 appflowy
/// 的块模型——迁移不需要改数据，只缺一个渲染组件（就是本文件）。
///
/// 渲染与对话框走 `formula_render.dart`（与 quill 侧共用同一实现）。
/// 编辑用官方事务（`editorState.transaction` + `apply`），**可撤销**。
class FormulaBlockKeys {
  const FormulaBlockKeys._();

  static const String type = 'formula';
  static const String latex = 'latex';
}

/// 构造公式块节点。
Node formulaBlockNode({required String latex}) => Node(
  type: FormulaBlockKeys.type,
  attributes: <String, dynamic>{FormulaBlockKeys.latex: latex},
);

class FormulaBlockComponentBuilder extends BlockComponentBuilder {
  FormulaBlockComponentBuilder({super.configuration});

  @override
  BlockComponentWidget build(BlockComponentContext blockComponentContext) {
    final Node node = blockComponentContext.node;
    return FormulaBlockComponentWidget(
      key: node.key,
      node: node,
      configuration: configuration,
      showActions: showActions(node),
      actionBuilder: (context, state) =>
          actionBuilder(blockComponentContext, state),
      actionTrailingBuilder: (context, state) =>
          actionTrailingBuilder(blockComponentContext, state),
    );
  }

  /// 非文本块：不接受子块（与官方 divider 的判定一致）。
  @override
  BlockComponentValidate get validate => (node) => node.children.isEmpty;
}

class FormulaBlockComponentWidget extends BlockComponentStatefulWidget {
  const FormulaBlockComponentWidget({
    super.key,
    required super.node,
    super.showActions,
    super.actionBuilder,
    super.actionTrailingBuilder,
    super.configuration = const BlockComponentConfiguration(),
  });

  @override
  State<FormulaBlockComponentWidget> createState() =>
      _FormulaBlockComponentWidgetState();
}

class _FormulaBlockComponentWidgetState
    extends State<FormulaBlockComponentWidget>
    with
        SelectableMixin<FormulaBlockComponentWidget>,
        BlockComponentConfigurable<FormulaBlockComponentWidget>,
        NonTextBlockGeometry<FormulaBlockComponentWidget> {
  @override
  final GlobalKey contentKey = GlobalKey(debugLabel: 'formula_block');

  // 本状态自己持有 editorState（骨架的混入组合里没有声明它，故不是 override）。
  late final EditorState editorState = Provider.of<EditorState>(
    context,
    listen: false,
  );

  @override
  Widget build(BuildContext context) => buildNonTextBlock(context);

  @override
  Widget buildContent(BuildContext context) {
    // 属性在 ListenableBuilder 内读取：事务改完 latex 后 node 会 notify，
    // 这样读到的是新值（在外面读会拿到陈旧闭包值）。
    return ListenableBuilder(
      listenable: node,
      builder: (BuildContext context, Widget? child) {
        final String latex =
            (node.attributes[FormulaBlockKeys.latex] as String?) ?? '';
        if (latex.isEmpty) {
          return Text(
            '公式数据损坏',
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.error,
            ),
          );
        }
        return GestureDetector(
          // 双击编辑（与 quill 侧嵌入的行为一致）。
          onDoubleTap: editorState.editable
              ? () => _editFormula(context, latex)
              : null,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: renderFormula(
                  context,
                  latex,
                  // 用编辑器正文样式：公式字号随设置的正文字号档位缩放。
                  editorState.editorStyle.textStyleConfiguration.text,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _editFormula(BuildContext context, String current) async {
    final String? next = await showFormulaDialog(context, initial: current);
    if (next == null || next == current) return;
    final Transaction transaction = editorState.transaction
      ..updateNode(node, <String, dynamic>{FormulaBlockKeys.latex: next});
    await editorState.apply(transaction);
  }
}
