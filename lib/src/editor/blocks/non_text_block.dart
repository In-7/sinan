import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

// 非文本块（公式 / 附件，以及将来的 Callout 等）的公共几何骨架。
//
// 官方对"非文本块"（见其 divider 组件）要求实现一整套 SelectableMixin 的
// 几何样板——选区矩形、光标矩形、命中判定、坐标换算。这些与内容无关，
// 故抽到这里：子类只需给出 contentKey 与 buildContent，再用
// buildNonTextBlock 组装。
//
// 只用 widgets / painting 层的绘制（不用需要 Material 祖先的 Material 层
// widget），保证在 appflowy 官方 Material 与我们 material_ui 的双主题
// 环境下都成立。

/// 非文本块的几何骨架（[SelectableMixin] 的实现）。
mixin NonTextBlockGeometry<W extends BlockComponentStatefulWidget>
    on State<W>, SelectableMixin<W>, BlockComponentConfigurable<W> {
  /// 内容锚点：选区/光标矩形按它计算（子类把它包在最外层内容上）。
  GlobalKey get contentKey;

  RenderBox? get _renderBox => context.findRenderObject() as RenderBox?;

  /// 子类的内容（不含 Padding / 选区容器 / 动作包裹）。
  Widget buildContent(BuildContext context);

  // ── [BlockComponentConfigurable] 要求的两个成员：从 widget 转发 ──

  @override
  BlockComponentConfiguration get configuration => widget.configuration;

  @override
  Node get node => widget.node;

  /// 统一组装：Padding(内容) → 选区容器 → 动作包裹。
  Widget buildNonTextBlock(BuildContext context) {
    final EditorState editorState = context.read<EditorState>();
    Widget child = Padding(
      key: contentKey,
      padding: padding,
      child: buildContent(context),
    );

    child = BlockSelectionContainer(
      node: node,
      delegate: this,
      listenable: editorState.selectionNotifier,
      remoteSelection: editorState.remoteSelections,
      blockColor: editorState.editorStyle.selectionColor,
      cursorColor: editorState.editorStyle.cursorColor,
      selectionColor: editorState.editorStyle.selectionColor,
      supportTypes: const <BlockSelectionType>[
        BlockSelectionType.block,
        BlockSelectionType.cursor,
        BlockSelectionType.selection,
      ],
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

  // ── 以下为 SelectableMixin 要求的几何实现（与官方 divider 同款语义）──

  @override
  Position start() => Position(path: node.path);

  @override
  Position end() => Position(path: node.path, offset: 1);

  @override
  Position getPositionInOffset(Offset start) => end();

  @override
  bool get shouldCursorBlink => false;

  @override
  CursorStyle get cursorStyle => CursorStyle.cover;

  @override
  Rect getBlockRect({bool shiftWithBaseOffset = false}) =>
      getRectsInSelection(Selection.invalid()).first;

  @override
  Rect? getCursorRectInPosition(
    Position position, {
    bool shiftWithBaseOffset = false,
  }) {
    if (_renderBox == null) return null;
    final List<Rect> rects = getRectsInSelection(
      Selection.collapsed(position),
      shiftWithBaseOffset: shiftWithBaseOffset,
    );
    return rects.isEmpty ? null : rects.first;
  }

  @override
  List<Rect> getRectsInSelection(
    Selection selection, {
    bool shiftWithBaseOffset = false,
  }) {
    if (_renderBox == null) return <Rect>[];
    final RenderObject? parentBox = context.findRenderObject();
    final RenderObject? contentBox = contentKey.currentContext
        ?.findRenderObject();
    if (parentBox is RenderBox && contentBox is RenderBox) {
      return <Rect>[
        (shiftWithBaseOffset
                ? contentBox.localToGlobal(Offset.zero, ancestor: parentBox)
                : Offset.zero) &
            contentBox.size,
      ];
    }
    return <Rect>[Offset.zero & _renderBox!.size];
  }

  @override
  Selection getSelectionInRange(Offset start, Offset end) =>
      Selection.single(path: node.path, startOffset: 0, endOffset: 1);

  @override
  Offset localToGlobal(Offset offset, {bool shiftWithBaseOffset = false}) =>
      _renderBox!.localToGlobal(offset);

  @override
  TextDirection textDirection() => TextDirection.ltr;
}
