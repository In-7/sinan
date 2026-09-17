import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../core/editor_typography.dart';
import 'block_markers.dart';

/// 折叠块（type = `toggle_list`）：**容器**块，可折叠、可含子块。
///
/// ## 一个类型覆盖两个菜单项（官方口径，2026-09-14 对照 AppFlowy `main` 的
/// `editor_plugins/toggle/toggle_block_component.dart` 定案）
/// - `level == null` ⇒ **折叠列表**（`toggleListNode()`）；
/// - `level = 1..6` ⇒ **折叠标题 N**（`toggleHeadingNode(level:)`）。
///
/// 官方连**属性名**都保持同一套（`type='toggle_list'` / `collapsed` / `level`），
/// 我们也照抄 ⇒ 官方应用导出的文档里的折叠块，在我们这里能原样渲染。
///
/// ## 逐条采用的官方设计
/// - **折叠状态存节点属性、走事务写回**（`collapsed`）⇒ 自动随文档持久化、
///   可撤销/重做（官方 `onCollapsed` 同款事务写法）；
/// - **子块渲染交给官方**：`NestedListWidget` + `editorState.renderer.buildList`
///   （vendored 6.2.0 自带，见 `NestedBlockComponentStatefulWidgetMixin`），
///   缩进由 `indentPadding` 统一决定，本组件不自建列表、不自己算缩进；
/// - **折叠态不渲染子块**——⚠️ 这一条**必须自己 override `build()`**：vendored
///   mixin 的 `build()` 只看 `children.isEmpty`，不看 `collapsed`，照它走会在
///   折叠时照样把子块画出来（官方也是自己 override 的）；
/// - **展开/折叠无内容动画**（官方只有箭头 `AnimatedRotation` 200ms）——
///   我们保持一致：容器动画会牵动整个滚动列表高度，得不偿失。
///
/// ## 我们**有意不同**的两处
/// 1. **箭头**用 Lucide `chevronRight300`（官方 `Icons.arrow_right`），
///    占位宽度复用 [markerBox]（与列表圆点/序号同一口径）；
/// 2. **块高**：官方靠内容内在撑开，我们把块高喂给 `BlockHeights`（目录跳转、
///    查找定位要用）⇒ 预算器必须补一条"自身一行 + 子块之和（折叠记 0）"。
///
/// ## 回车语义（**已对齐**官方，也是 Notion 标杆）
/// 见 [insertNewLineInToggle]：展开时回车在内部第一个子位置插段落（光标后文本
/// 落入子块），折叠时按官方规则转/拆。`Ctrl/Cmd+Enter` 切换折叠见
/// [toggleToggleListCommand]。官方原本就有这套（`toggle_block_shortcuts.dart`
/// 的 `insertChildNodeInsideToggleList` / `toggleToggleListCommand`），并非
/// 官方"没有自定义回车"——此前我们读组件文件时漏看了这个独立快捷键文件。
class ToggleListBlockKeys {
  const ToggleListBlockKeys._();

  static const String type = 'toggle_list';

  /// 正文（与官方同用通用常量）。
  static const String delta = blockComponentDelta;

  /// 是否折叠（缺省 = 展开，官方同款容错）。
  static const String collapsed = 'collapsed';

  /// 非空即"折叠标题"，值 = 标题级别（1..6）。
  static const String level = 'level';
}

/// 折叠列表节点（`level` 不写 ⇒ 普通折叠列表）。
Node toggleListNode({Delta? delta, bool collapsed = false}) => Node(
  type: ToggleListBlockKeys.type,
  attributes: <String, dynamic>{
    ToggleListBlockKeys.delta: (delta ?? Delta()).toJson(),
    ToggleListBlockKeys.collapsed: collapsed,
  },
);

/// 折叠标题节点（**同一类型** + `level`，官方口径）。
///
/// `level` 主动 `clamp(1, 6)`（官方同款防御）：脏数据不会让它渲染成空块。
Node toggleHeadingNode({
  required int level,
  Delta? delta,
  bool collapsed = false,
}) => Node(
  type: ToggleListBlockKeys.type,
  attributes: <String, dynamic>{
    ToggleListBlockKeys.delta: (delta ?? Delta()).toJson(),
    ToggleListBlockKeys.level: level.clamp(1, 6),
    ToggleListBlockKeys.collapsed: collapsed,
  },
);

/// 展开着但**还没有子块**时，块内那行"点击添加内容"的文案。
const String toggleAddContentText = '点击添加内容';

/// 该行占位自己的内边距（**预算器按同一式子加**，见
/// `BlockHeightPredictor._toggleHeightOf`）。
const EdgeInsets togglePlaceholderPadding = EdgeInsets.only(top: Tokens.spaceXs);

/// 箭头图标直径（[Tokens.iconMd]，与工具栏/双耳同档）。
const double toggleArrowIconSize = Tokens.iconMd;

/// 折叠块的**回车**：与官方 `main` 的 `insertChildNodeInsideToggleList`
/// （`editor_plugins/toggle/toggle_block_shortcuts.dart`）对齐，**也即是 Notion
/// 折叠块"回车在容器内新增一行"的标杆语义**。
///
/// - **展开**时回车 ⇒ 在块**内部第一个子位置**（`path + [0]`）插一个段落；
///   光标之后的文本作为该子块内容（标题行从光标处切开：前半留标题、后半落入
///   子块）。无论块是否已有子块都成立——始终从 `[0]` 插，已有子块被推到后面，
///   **不会把 toggle 拆断**（旧实现一旦有孩子就交还默认，会把 toggle 断开成两段）。
/// - **折叠**时回车：
///   - 块为空 ⇒ 转成下方兄弟段落（清掉 toggle 格式）；
///   - 光标在块首（非空）⇒ 在上方插一个兄弟段落；
///   - 其余 ⇒ 从光标拆成两个兄弟 toggle（尾文本带走）。
///
/// ⚠️ 必须排在官方 `insertNewLine` 之前（同代码块的回车，见
/// `sinanCharacterShortcutEvents` 里的顺序说明）。
final CharacterShortcutEvent insertNewLineInToggle = CharacterShortcutEvent(
  key: 'insert new line in toggle list',
  character: '\n',
  handler: (EditorState editorState) async {
    final Selection? selection = editorState.selection?.normalized;
    if (selection == null || !selection.isCollapsed) return false;
    final Node? node = editorState.getNodeAtPath(selection.end.path);
    if (node == null || node.type != ToggleListBlockKeys.type) return false;
    final Delta? delta = node.delta;
    if (delta == null) return false;

    final int offset = selection.end.offset;
    final Delta slicedDelta = delta.slice(offset);
    final bool collapsed =
        (node.attributes[ToggleListBlockKeys.collapsed] as bool?) ?? false;
    final Transaction transaction = editorState.transaction;

    if (collapsed) {
      if (delta.isEmpty) {
        // 空折叠块回车 → 转成下方兄弟段落（清掉 toggle 格式）。
        transaction
          ..insertNode(selection.end.path.next, paragraphNode())
          ..deleteNode(node)
          ..afterSelection =
              Selection.collapsed(Position(path: selection.end.path));
      } else if (offset == 0) {
        // 折叠块首部回车 → 在上方插一个兄弟段落。
        transaction.insertNode(selection.end.path, paragraphNode());
        transaction.afterSelection =
            Selection.collapsed(Position(path: selection.end.path.next));
      } else {
        // 折叠块中间回车 → 拆成两个兄弟 toggle（尾文本带走）。
        transaction
          ..deleteText(node, offset, slicedDelta.length)
          ..insertNodes(
            selection.end.path.next,
            <Node>[toggleListNode(collapsed: true, delta: slicedDelta)],
          )
          ..afterSelection =
              Selection.collapsed(Position(path: selection.end.path.next));
      }
    } else {
      // 展开块回车 → 在内部第一个子位置插段落（尾文本带走）。
      transaction
        ..deleteText(node, offset, slicedDelta.length)
        ..insertNode(
          selection.end.path + <int>[0],
          paragraphNode(delta: slicedDelta),
        )
        ..afterSelection =
            Selection.collapsed(Position(path: selection.end.path + <int>[0]));
    }

    await editorState.apply(transaction);
    return true;
  },
);

/// 折叠键 **Ctrl / Cmd + Enter**：切换当前折叠块的展开/折叠，与官方
/// `toggleToggleListCommand` 对齐。仅当光标落在某个 `toggle_list` 节点上
/// （即标题行）时接管，落在子块里则交还默认（`KeyEventResult.ignored`）。
///
/// ⚠️ `CommandShortcutEvent` 的 handler 是**同步**的、返回 `KeyEventResult`
/// （不是 `Future<bool>`，那是 `CharacterShortcutEvent` 的口径）；事务直接
/// `apply` 不 await（`apply` 是微任务，返回 `handled` 即可）。
final CommandShortcutEvent toggleToggleListCommand = CommandShortcutEvent(
  key: 'toggle toggle list collapse',
  getDescription: () => '折叠/展开',
  command: 'ctrl+enter',
  macOSCommand: 'cmd+enter',
  handler: (EditorState editorState) {
    final Selection? selection = editorState.selection?.normalized;
    if (selection == null || !selection.isCollapsed) {
      return KeyEventResult.ignored;
    }
    final Node? node = editorState.getNodeAtPath(selection.end.path);
    if (node == null || node.type != ToggleListBlockKeys.type) {
      return KeyEventResult.ignored;
    }
    final bool collapsed =
        (node.attributes[ToggleListBlockKeys.collapsed] as bool?) ?? false;
    final Transaction transaction = editorState.transaction
      ..updateNode(node, <String, dynamic>{
        ToggleListBlockKeys.collapsed: !collapsed,
      });
    transaction.afterSelection = editorState.selection;
    unawaited(editorState.apply(transaction));
    return KeyEventResult.handled;
  },
);

/// 折叠块的占位文案（按级别区分，与标题块同款做法）。
String togglePlaceholderText(Node node) {
  final Object? level = node.attributes[ToggleListBlockKeys.level];
  if (level is int) return '折叠标题 $level';
  return '折叠列表';
}

class ToggleBlockComponentBuilder extends BlockComponentBuilder {
  ToggleBlockComponentBuilder({super.configuration, required this.typography});

  /// 排版单一来源：折叠标题的字号/行盒由它给（与正文 h1..h6 同源），
  /// **块高预算器用同一份**。
  final EditorTypography typography;

  @override
  BlockComponentWidget build(BlockComponentContext blockComponentContext) {
    final Node node = blockComponentContext.node;
    return ToggleBlockComponentWidget(
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
  BlockComponentValidate get validate => (node) => node.delta != null;
}

class ToggleBlockComponentWidget extends BlockComponentStatefulWidget {
  const ToggleBlockComponentWidget({
    super.key,
    required super.node,
    required this.typography,
    super.showActions,
    super.actionBuilder,
    super.actionTrailingBuilder,
    super.configuration = const BlockComponentConfiguration(),
  });

  final EditorTypography typography;

  @override
  State<ToggleBlockComponentWidget> createState() =>
      _ToggleBlockComponentWidgetState();
}

class _ToggleBlockComponentWidgetState extends State<ToggleBlockComponentWidget>
    with
        SelectableMixin,
        DefaultSelectableMixin,
        BlockComponentConfigurable,
        BlockComponentBackgroundColorMixin,
        NestedBlockComponentStatefulWidgetMixin,
        BlockComponentTextDirectionMixin,
        BlockComponentAlignMixin {
  @override
  final forwardKey = GlobalKey(debugLabel: 'flowy_rich_text');

  @override
  GlobalKey<State<StatefulWidget>> get containerKey => widget.node.key;

  @override
  GlobalKey<State<StatefulWidget>> blockComponentKey = GlobalKey(
    debugLabel: ToggleListBlockKeys.type,
  );

  @override
  BlockComponentConfiguration get configuration => widget.configuration;

  @override
  Node get node => widget.node;

  /// 折叠态（缺省展开）。
  bool get _collapsed =>
      (node.attributes[ToggleListBlockKeys.collapsed] as bool?) ?? false;

  /// 非空 = 折叠标题（1..6）。
  int? get _level {
    final Object? raw = node.attributes[ToggleListBlockKeys.level];
    return raw is int ? raw : null;
  }

  /// 正文样式：折叠标题套标题档位，折叠列表走默认正文。
  TextStyle get _textStyle =>
      _level == null ? const TextStyle() : widget.typography.heading(_level!);

  /// 首行行盒（标记盒与折叠标题对齐要用）。
  ///
  /// 折叠标题的首行比正文高，若仍按正文字号给标记盒，箭头会偏上
  /// （48px 的 h1 下能差出小半个字形）。
  double? get _lineBox {
    final int? level = _level;
    if (level == null) return null;
    final TextStyle style = widget.typography.heading(level);
    final double fontSize = style.fontSize ?? 16;
    return fontSize * (style.height ?? 1.35);
  }

  /// 折叠 / 展开：**走事务**（可撤销、随文档持久化、协同可同步）。
  ///
  /// `afterSelection` 保持原选区——官方同款处理：不设它的话折叠动作会把光标
  /// 顶走，用户接着打字会落到别处。
  Future<void> _toggleCollapsed() async {
    final Transaction transaction = editorState.transaction
      ..updateNode(node, <String, dynamic>{
        ToggleListBlockKeys.collapsed: !_collapsed,
      });
    transaction.afterSelection = editorState.selection;
    await editorState.apply(transaction);
  }

  /// 占位行"点击添加内容"：在**第一个子位置**插一个空段落并聚焦
  /// （官方 `onAddContent` 同款——插入后这个块立刻成了容器，后续按常规编辑）。
  Future<void> _addFirstChild() async {
    final Path path = node.path.child(0);
    final Transaction transaction = editorState.transaction
      ..insertNode(path, paragraphNode());
    transaction.afterSelection = Selection.collapsed(Position(path: path));
    await editorState.apply(transaction);
  }

  /// ⚠️ **必须自己 override**：vendored mixin 的 `build()` 只按
  /// `children.isEmpty` 分流，折叠时也照样渲染子块（官方同样是自己写的）。
  @override
  Widget build(BuildContext context) => _collapsed || node.children.isEmpty
      ? buildComponent(context)
      : buildComponentWithChildren(context);

  @override
  Widget buildComponent(
    BuildContext context, {
    bool withBackgroundColor = true,
  }) {
    final TextDirection textDirection = calculateTextDirection(
      layoutDirection: Directionality.maybeOf(context),
    );

    Widget child = Container(
      width: double.infinity,
      alignment: alignment,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        textDirection: textDirection,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            textDirection: textDirection,
            children: <Widget>[
              _buildArrow(context),
              Flexible(
                child: AppFlowyRichText(
                  key: forwardKey,
                  delegate: this,
                  node: node,
                  editorState: editorState,
                  textAlign: alignment?.toTextAlign ?? textAlign,
                  textSpanDecorator: (TextSpan textSpan) =>
                      textSpan.updateTextStyle(
                        textStyleWithTextSpan(textSpan: textSpan)
                            .merge(_textStyle),
                      ),
                  placeholderTextSpanDecorator: (TextSpan textSpan) =>
                      textSpan.updateTextStyle(
                        placeholderTextStyleWithTextSpan(textSpan: textSpan)
                            .merge(_textStyle),
                      ),
                  textDirection: textDirection,
                  cursorColor: editorState.editorStyle.cursorColor,
                  selectionColor: editorState.editorStyle.selectionColor,
                  cursorWidth: editorState.editorStyle.cursorWidth,
                ),
              ),
            ],
          ),
          // 展开着且还没有子块时，给一行"点击添加内容"（官方同款入口）。
          // 有子块 / 已折叠时不显示——它只是"如何长出第一个孩子"的提示。
          if (!_collapsed && node.children.isEmpty) _buildAddContent(context),
        ],
      ),
    );

    child = Container(
      key: blockComponentKey,
      decoration: withBackgroundColor ? decoration : null,
      padding: padding,
      child: child,
    );

    child = BlockSelectionContainer(
      node: node,
      delegate: this,
      listenable: editorState.selectionNotifier,
      remoteSelection: editorState.remoteSelections,
      blockColor: editorState.editorStyle.selectionColor,
      supportTypes: const <BlockSelectionType>[
        BlockSelectionType.block,
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

  /// 箭头：折叠时朝右、展开时朝下（`AnimatedRotation` 90°，200ms，官方口径）。
  ///
  /// 占位宽度走 [markerBox] ⇒ 与列表圆点/序号**同一口径**，也就是与
  /// `BlockHeightPredictor.markerWidth` 同一式子（预测不偏的前提）。
  Widget _buildArrow(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return markerBox(
      context,
      // 图标热区给足（26×26）：箭头是本块唯一的高频点击目标。
      SizedBox(
        width: 26,
        height: 26,
        child: InkWell(
          onTap: editorState.editable ? _toggleCollapsed : null,
          borderRadius: BorderRadius.circular(Tokens.radiusSm),
          child: AnimatedRotation(
            turns: _collapsed ? 0 : 0.25,
            duration: const Duration(milliseconds: 200),
            child: Icon(
              LucideIcons.chevronRight300,
              size: toggleArrowIconSize,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
      lineBox: _lineBox,
    );
  }

  /// "点击添加内容"：与子块**同一左缘**（`indentPadding.left`，官方用同一
  /// 口径），点一下长出第一个子块。
  Widget _buildAddContent(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        left: indentPadding.left,
        top: togglePlaceholderPadding.top,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: InkWell(
          onTap: editorState.editable ? _addFirstChild : null,
          borderRadius: BorderRadius.circular(Tokens.radiusSm),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Tokens.spaceXs,
              vertical: Tokens.spaceXxs,
            ),
            child: Text(
              toggleAddContentText,
              style: TextStyle(color: AppTheme.hintColor(scheme.onSurface)),
            ),
          ),
        ),
      ),
    );
  }
}
