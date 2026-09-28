import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:material_ui/material_ui.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';

/// Callout 块（type = `callout`）：一个**带图标与底色**的强调块。
///
/// ## 与官方应用的对齐关系（2026-09-14 对照 AppFlowy `main` 的
/// `editor_plugins/callout/callout_block_component.dart` 定案）
///
/// 逐条采用的官方设计：
/// - **属性**：`delta`（正文）+ `icon`（图标字符）+ `backgroundColor`
///   （**复用官方的通用常量** `blockComponentBackgroundColor`，不自造 key）；
/// - **底色懒解析**：节点里存 `transparent` 哨兵、**渲染时**才回退到主题色
///   （[AppTheme.calloutBackground]）⇒ 明暗切换零迁移、旧数据自动跟随主题；
/// - **插入语义**：斜杠菜单里"空块则原地替换、否则插到下一行"，光标落块首
///   （走官方 `SelectionMenuItem.node`，与代码块那三条同一条路子）；
/// - **`validate`**：只认 `delta != null` 的节点（官方同款约束）。
///
/// ## 我们**有意不同**的两处（别当成漏做）
/// 1. **图标固定 `📌`**（官方是 emoji 选择器 + 自定义图标上传）：数据模型已
///    预留 `icon` 字段，将来加选择器**不需要迁移数据**；
/// 2. **块高走我们的预算器**（`BlockHeightPredictor`）：官方靠内容内在撑开，
///    而我们把精确块高喂给滚动器，所以这个类型必须在预算器里登记
///    （见 `block_height_predictor.dart` 里 callout 的说明）。
///
/// ## increment 2（未做，等定案）
/// 官方 Callout 是**容器**（可含子块，背景铺 `Positioned.fill` 底层 +
/// `NestedListWidget` 缩进）。我们这版是**扁平**的：图标 + 正文。
/// 升级成容器要同时补三处（都不是这一块自己的事）：
/// `plainTextFromDocument` 递归子块（否则字数/索引漏掉嵌套文本）、
/// 预算器递归子块高度、以及子块测量在嵌套下的回归。
class CalloutBlockKeys {
  const CalloutBlockKeys._();

  static const String type = 'callout';

  /// 正文（与官方同用通用常量，免得同一个概念两个 key）。
  static const String delta = blockComponentDelta;

  /// 图标字符（emoji 字符串；官方同名字段，支持将来的选择器）。
  static const String icon = 'icon';

  /// 底色 hex（**复用官方通用常量**）。缺省即 `transparent` 哨兵 ⇒ 渲染时
  /// 回退主题色。见 [AppTheme.calloutBackground]。
  static const String backgroundColor = blockComponentBackgroundColor;

  /// 默认图标（与官方 `calloutNode()` 的默认值一致）。
  static const String defaultIcon = '📌';
}

/// 构造 Callout 节点。
///
/// [backgroundColor] 为 `transparent`（默认）时**不写该属性**——省一次序列化，
/// 而且"缺省 = 用主题色"这条语义比写死一个 hex 更抗主题变更（官方写哨兵值，
/// 我们直接省略，效果等价）。
Node calloutNode({
  Delta? delta,
  String icon = CalloutBlockKeys.defaultIcon,
  Color backgroundColor = Colors.transparent,
}) {
  final Attributes attributes = <String, dynamic>{
    CalloutBlockKeys.delta: (delta ?? Delta()).toJson(),
    CalloutBlockKeys.icon: icon,
  };
  if (backgroundColor != Colors.transparent) {
    attributes[CalloutBlockKeys.backgroundColor] = _hexOf(backgroundColor);
  }
  return Node(type: CalloutBlockKeys.type, attributes: attributes);
}

/// `#AARRGGBB`（与项目里其它块属性同一形态；官方 `Color.toHex()` 出自
/// `flowy_infra`，不在本项目的依赖里，故自带一个三行的等价实现）。
String _hexOf(Color color) =>
    '#${color.toARGB32().toRadixString(16).padLeft(8, '0')}';

/// Callout 空着时的占位文案（同样被预算器复用，理由见
/// `code_block_component.dart` 里 `codeBlockPlaceholder` 的说明）。
const String calloutPlaceholder = '输入内容…';

/// Callout 的内边距（被预算器复用：官方把内容放在 `Container(padding)` 里，
/// 预测高度必须加同一份内边距）。
const EdgeInsets calloutInnerPadding = EdgeInsets.symmetric(
  horizontal: Tokens.spaceMd,
  vertical: Tokens.spaceSm,
);

/// 图标与正文之间的距离（同样被预算器复用）。
const double calloutIconGap = Tokens.spaceSm;

/// 图标字号相对正文字号的倍数（官方口径：emoji 跟随正文字号）。
const double calloutIconScale = 1.0;

class CalloutBlockComponentBuilder extends BlockComponentBuilder {
  CalloutBlockComponentBuilder({super.configuration});

  @override
  BlockComponentWidget build(BlockComponentContext blockComponentContext) {
    final Node node = blockComponentContext.node;
    return CalloutBlockComponentWidget(
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

  @override
  BlockComponentValidate get validate =>
      (node) => node.delta != null;
}

class CalloutBlockComponentWidget extends BlockComponentStatefulWidget {
  const CalloutBlockComponentWidget({
    super.key,
    required super.node,
    super.showActions,
    super.actionBuilder,
    super.actionTrailingBuilder,
    super.configuration = const BlockComponentConfiguration(),
  });

  @override
  State<CalloutBlockComponentWidget> createState() =>
      _CalloutBlockComponentWidgetState();
}

/// 结构对齐官方 callout 组件（同样的 mixin 组合与必要成员），
/// 差别只在"扁平 vs 容器"与图标来源（见 [CalloutBlockKeys] 的说明）。
class _CalloutBlockComponentWidgetState
    extends State<CalloutBlockComponentWidget>
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
    debugLabel: CalloutBlockKeys.type,
  );

  @override
  BlockComponentConfiguration get configuration => widget.configuration;

  @override
  Node get node => widget.node;

  /// 图标字符（容错：属性损坏或为空时回退默认值，官方同款行为）。
  String get _icon {
    final Object? raw = node.attributes[CalloutBlockKeys.icon];
    if (raw is! String || raw.isEmpty) return CalloutBlockKeys.defaultIcon;
    return raw;
  }

  /// **懒解析**底色（官方技巧）：节点里没存颜色 ⇒ 现场取主题色
  /// ⇒ 明暗切换/改主题时旧数据自动跟着变，不需要迁移文档。
  ///
  /// ⚠️ increment 1 **只认主题色**：`backgroundColor` 属性已经预留
  /// （[CalloutBlockKeys.backgroundColor]，`calloutNode` 只在显式传色时才写），
  /// 但 6.2.0 的 `BlockComponentBackgroundColorMixin` 只提供 `decoration`、
  /// 没有可复用的"解析 hex → Color"入口 ⇒ 等做取色器时再接解析
  /// （官方对应 `flowy_infra` 的 `Color.toHex()` / 反向解析，不在我们依赖里）。
  Color _background(BuildContext context) =>
      AppTheme.calloutBackground(Theme.of(context).brightness);

  @override
  Widget buildComponent(
    BuildContext context, {
    bool withBackgroundColor = true,
  }) {
    final TextDirection textDirection = calculateTextDirection(
      layoutDirection: Directionality.maybeOf(context),
    );
    final TextStyle textStyle = textStyleWithTextSpan(
      textSpan: const TextSpan(),
    );
    final double iconSize =
        (textStyle.fontSize ?? Tokens.fontSizeMd) * calloutIconScale;

    Widget child = Container(
      width: double.infinity,
      alignment: alignment,
      padding: calloutInnerPadding,
      // 扁平版的底色画在这里；将来升级成容器时，这一层要让位给
      // "背景铺 Positioned.fill 底层 + 前景不带色"（官方做法）。
      decoration: withBackgroundColor
          ? BoxDecoration(
              color: _background(context),
              borderRadius: BorderRadius.circular(Tokens.radiusSm),
            )
          : null,
      child: Row(
        crossAxisAlignment: .start,
        textDirection: textDirection,
        children: <Widget>[
          // 图标：纯文本（emoji）。用行盒高度对齐首行，不额外撑高块。
          SizedBox(
            width: iconSize + calloutIconGap,
            child: Text(
              _icon,
              style: TextStyle(fontSize: iconSize),
              textDirection: textDirection,
            ),
          ),
          Expanded(
            child: AppFlowyRichText(
              key: forwardKey,
              delegate: this,
              node: node,
              editorState: editorState,
              textAlign: alignment?.toTextAlign ?? textAlign,
              placeholderText: calloutPlaceholder,
              textSpanDecorator: (TextSpan textSpan) => textSpan
                  .updateTextStyle(textStyleWithTextSpan(textSpan: textSpan)),
              placeholderTextSpanDecorator: (TextSpan textSpan) =>
                  textSpan.updateTextStyle(
                    placeholderTextStyleWithTextSpan(textSpan: textSpan),
                  ),
              textDirection: textDirection,
              cursorColor: editorState.editorStyle.cursorColor,
              selectionColor: editorState.editorStyle.selectionColor,
              cursorWidth: editorState.editorStyle.cursorWidth,
            ),
          ),
        ],
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
