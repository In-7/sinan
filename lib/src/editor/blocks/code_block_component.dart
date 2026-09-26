import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../notes/services/note_code_syntax.dart';
import '../core/editor_typography.dart';

/// 代码块（type = `code`）：**官方 6.2.0 没有这个块组件**（实测其注册表
/// 只有 page/paragraph/todo_list/bulleted_list/numbered_list/quote/heading/
/// image/divider/table/table/cell），所以要自己写。
///
/// 与 Delta 的对应关系（见 `NoteDocumentAdapter`）：quill 的代码块是**行级
/// 布尔属性** `{"insert":"line1\nline2\n","attributes":{"code-block":true}}`
/// ——不含语言元数据（高亮走 highlight 的自动检测），因此 "文本 + 布尔"
/// ↔ `Node('code', {delta})` 往返**无信息可丢**。
///
/// 实现要点：
/// - 是**文本块**（可编辑/可选区），因此复用官方的 `AppFlowyRichText`
///   与文本块选择机制（结构对齐官方 quote 组件）；
/// - 高亮走 `note_code_syntax.dart` 的 `buildHighlightedCodeSpan`——
///   与 quill 侧共用同一份解析缓存与配色表；
/// - 回车由 [insertNewLineInCodeBlock] 接管：在块内换行，而不是像官方
///   `insertNewLine` 那样把块**拆成两段**。
class CodeBlockKeys {
  const CodeBlockKeys._();

  static const String type = 'code';
  static const String delta = blockComponentDelta;
}

/// 构造代码块节点（[delta] 为该块全部代码文本，可含换行）。
Node codeBlockNode({required Delta delta}) => Node(
  type: CodeBlockKeys.type,
  attributes: <String, dynamic>{CodeBlockKeys.delta: delta.toJson()},
);

/// 段落 ↔ 代码块（工具栏条目 / 快捷键 / 块操作菜单**共用同一实现**，
/// 避免多条路径行为分叉）。
///
/// 光标不在文本块里时返回 [KeyEventResult.ignored]，让按键继续冒泡
/// （表格单元格、图片块等不该被它吃掉）。
///
/// ⚠️ 2026-09-15 从 `toolbar/fixed_toolbar.dart` 迁到这里：它是**代码块的
/// 块级行为**，而块操作菜单（`blocks/block_action_menu.dart`）也要用它——
/// 留在工具栏会让 blocks 反向依赖 toolbar。
KeyEventResult toggleSinanCodeBlock(EditorState editorState) {
  final Selection? selection = editorState.selection;
  if (selection == null || !selection.isSingle) return KeyEventResult.ignored;
  final Node? node = editorState.getNodeAtPath(selection.start.path);
  if (node?.delta == null) return KeyEventResult.ignored;

  final bool isCodeBlock = node!.type == CodeBlockKeys.type;
  unawaited(
    editorState.formatNode(
      selection,
      (Node target) => target.copyWith(
        type: isCodeBlock ? ParagraphBlockKeys.type : CodeBlockKeys.type,
        attributes: <String, dynamic>{
          ...target.attributes,
          // CodeBlockKeys.delta 就是 blockComponentDelta（同一 key）。
          CodeBlockKeys.delta: (target.delta ?? Delta()).toJson(),
        },
      ),
    ),
  );
  return KeyEventResult.handled;
}

/// 代码块空着时显示的占位文案。
///
/// 同样被预算器复用：官方 `AppFlowyRichText` 把"占位符那层"与正文放在同一个
/// `Stack` 里取较高者，而**那层的高度取决于它排的是哪段字**（空串与汉字的行盒
/// 能差 1px）⇒ 预算器必须排**同一段文字**才对得上，不能随便拿个空格代替。
const String codeBlockPlaceholder = '代码块';

/// 代码块内层容器的内边距（左右 / 上下）——同样被预算器复用。
const EdgeInsets codeBlockInnerPadding = EdgeInsets.symmetric(
  horizontal: Tokens.spaceMd,
  vertical: Tokens.spaceSm,
);

/// 右上角复制按钮预留的宽度（按钮 28 + 间隙 8）。
///
/// 正文从右侧让开这一条，避免首行长文本钻到按钮底下；块高预算器同样
/// 要扣掉它（见 `block_height_predictor.dart` 的 `_codeBlockHeightOf`），
/// 否则预测比渲染多折一行。
const double codeBlockCopyZone = 36.0;

/// 代码块内的回车：**块内换行**（不拆块）。
///
/// 官方 `insertNewLine` 会把当前节点切开并把后半段放进新段落——对代码块
/// 是错的。这里返回 `false` 把非代码块的情形交还给标准处理器
/// （因此必须把本事件排在标准列表之前）。
final CharacterShortcutEvent insertNewLineInCodeBlock = CharacterShortcutEvent(
  key: 'insert new line in code block',
  character: '\n',
  handler: (EditorState editorState) async {
    final Selection? selection = editorState.selection?.normalized;
    if (selection == null || !selection.isCollapsed) return false;
    final Node? node = editorState.getNodeAtPath(selection.end.path);
    if (node == null || node.type != CodeBlockKeys.type) return false;

    final Transaction transaction = editorState.transaction
      ..insertText(node, selection.end.offset, '\n');
    transaction.afterSelection = Selection.collapsed(
      Position(path: selection.end.path, offset: selection.end.offset + 1),
    );
    await editorState.apply(transaction);
    return true;
  },
);

class CodeBlockComponentBuilder extends BlockComponentBuilder {
  CodeBlockComponentBuilder({super.configuration, required this.typography});

  /// 排版单一来源：代码的等宽样式（字号 / 行盒吸附整像素）由它给出，
  /// **块高预算器用同一份**（见 `EditorTypography.code`）。
  final EditorTypography typography;

  @override
  BlockComponentWidget build(BlockComponentContext blockComponentContext) {
    final Node node = blockComponentContext.node;
    return CodeBlockComponentWidget(
      key: node.key,
      node: node,
      typography: typography,
      configuration: configuration,
      showActions: showActions(node),
      actionBuilder: (context, state) =>
          actionBuilder(blockComponentContext, state),
      actionTrailingBuilder: (context, state) =>
          actionTrailingBuilder(blockComponentContext, state),
    );
  }

  @override
  BlockComponentValidate get validate =>
      (node) => node.delta != null;
}

class CodeBlockComponentWidget extends BlockComponentStatefulWidget {
  const CodeBlockComponentWidget({
    super.key,
    required super.node,
    required this.typography,
    super.showActions,
    super.actionBuilder,
    super.actionTrailingBuilder,
    super.configuration = const BlockComponentConfiguration(),
  });

  /// 排版单一来源（等宽样式见 `EditorTypography.code`）。
  final EditorTypography typography;

  @override
  State<CodeBlockComponentWidget> createState() =>
      _CodeBlockComponentWidgetState();
}

/// 结构对齐官方 quote 组件（同样的 mixin 组合与必要成员），
/// 差别只在内容：等宽字体 + 语法高亮的 `AppFlowyRichText`。
class _CodeBlockComponentWidgetState extends State<CodeBlockComponentWidget>
    with
        SelectableMixin<CodeBlockComponentWidget>,
        DefaultSelectableMixin,
        BlockComponentConfigurable<CodeBlockComponentWidget>,
        // 提供 editorState / node 的抽象声明（我们实现它们）与
        // calculateTextDirection（对齐官方 quote 的组合）。
        BlockComponentTextDirectionMixin,
        BlockComponentAlignMixin {
  @override
  final forwardKey = GlobalKey(debugLabel: 'flowy_rich_text');

  @override
  GlobalKey<State<StatefulWidget>> get containerKey => widget.node.key;

  @override
  GlobalKey<State<StatefulWidget>> blockComponentKey = GlobalKey(
    debugLabel: CodeBlockKeys.type,
  );

  @override
  BlockComponentConfiguration get configuration => widget.configuration;

  @override
  Node get node => widget.node;

  @override
  late final editorState = Provider.of<EditorState>(context, listen: false);

  /// 鼠标是否悬浮在本代码块内：只在块内出现复制按钮。
  /// 用 `ValueNotifier` 而非 `setState`，悬浮时只有按钮那块（经
  /// `ValueListenableBuilder`）重绘，重的 `AppFlowyRichText` 不重建。
  final ValueNotifier<bool> _hovering = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _hovering.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextStyle baseStyle =
        editorState.editorStyle.textStyleConfiguration.text;
    // 代码用等宽字体，字号比正文略小（与 quill 侧的观感一致）；
    // 字号与行盒都吸附整像素——单一来源是 `EditorTypography.code`，
    // 块高预算器用的是同一份（见那里的说明）。
    final TextStyle codeStyle = widget.typography.code(baseStyle);

    Widget child = Container(
      width: double.infinity,
      padding: codeBlockInnerPadding,
      decoration: BoxDecoration(
        color: AppTheme.editorCodeBlockBg(scheme.brightness),
        borderRadius: BorderRadius.circular(Tokens.radiusSm),
      ),
      // 整块卡片监听悬浮：进入才显示复制按钮（见 `_hovering`）。
      child: MouseRegion(
        onEnter: (_) => _hovering.value = true,
        onExit: (_) => _hovering.value = false,
        child: Stack(
          children: [
            // 正文右侧给复制按钮让出一条（见 [codeBlockCopyZone]），
            // 与预算器同口径，折行位置才对得上。
            Padding(
              padding: const EdgeInsets.only(right: codeBlockCopyZone),
              child: AppFlowyRichText(
                key: forwardKey,
                delegate: this,
                node: node,
                editorState: editorState,
                placeholderText: codeBlockPlaceholder,
                textAlign: alignment?.toTextAlign,
                cursorColor: editorState.editorStyle.cursorColor,
                selectionColor: editorState.editorStyle.selectionColor,
                cursorWidth: editorState.editorStyle.cursorWidth,
                // 高亮：整块文本按行交给 highlight 解析（与 quill 侧同一实现）。
                // 注意：块内的行内标记（粗体等）不参与着色——与 quill 侧同样折衷。
                textSpanDecorator: (TextSpan textSpan) =>
                    buildHighlightedCodeSpan(
                      context,
                      textSpan.toPlainText(),
                      codeStyle,
                    ),
                placeholderTextSpanDecorator: (TextSpan textSpan) =>
                    textSpan.updateTextStyle(
                      codeStyle.copyWith(
                        color: AppTheme.hintColor(scheme.onSurface),
                      ),
                    ),
              ),
            ),
            // 只在悬浮时出现：`Visibility`（`Offstage`，非 `Opacity`）显隐，
            // 不触发 saveLayer；`maintainState` 让复制成功的 ✓ 反馈在移出后仍能走完。
            Positioned(
              top: 0,
              right: 0,
              child: ValueListenableBuilder<bool>(
                valueListenable: _hovering,
                builder: (context, hovering, _) => Visibility(
                  visible: hovering,
                  maintainState: true,
                  maintainAnimation: true,
                  child: _CodeCopyButton(delta: node.delta),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    child = Container(key: blockComponentKey, padding: padding, child: child);

    child = BlockSelectionContainer(
      node: node,
      delegate: this,
      listenable: editorState.selectionNotifier,
      remoteSelection: editorState.remoteSelections,
      blockColor: editorState.editorStyle.selectionColor,
      supportTypes: const <BlockSelectionType>[BlockSelectionType.block],
      child: child,
    );

    if (widget.showActions && widget.actionBuilder != null) {
      child = BlockComponentActionWrapper(
        node: node,
        actionBuilder: widget.actionBuilder!,
        actionTrailingBuilder: widget.actionTrailingBuilder,
        child: child,
      );
    }

    return child;
  }
}

/// 右上角的"复制代码"按钮：点击把整块纯文本写入剪贴板，
/// 成功后短暂变 ✓（2 秒后回弹）。空块不响应（没东西可复制）。
class _CodeCopyButton extends StatefulWidget {
  const _CodeCopyButton({required this.delta});

  final Delta? delta;

  @override
  State<_CodeCopyButton> createState() => _CodeCopyButtonState();
}

class _CodeCopyButtonState extends State<_CodeCopyButton> {
  bool _copied = false;
  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  void _copy() {
    final String text = widget.delta?.toPlainText() ?? '';
    if (text.isEmpty) return;
    unawaited(AppFlowyClipboard.setData(text: text));
    setState(() => _copied = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 22px（14 图标 + 4×2 内边距）≤ 单行行盒（约 23px）：Stack 不裁按钮，
    // 也不侵占第二行——比 28 的默认命中区小，但代码块里可接受。
    return IconButton(
      tooltip: _copied ? '已复制' : '复制代码',
      icon: Icon(_copied ? Icons.check : Icons.copy_outlined),
      iconSize: 14,
      color: _copied ? scheme.primary : scheme.onSurfaceVariant,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
      visualDensity: VisualDensity.compact,
      onPressed: _copy,
    );
  }
}
