import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';

/// 引用块淡底的**内容内距**（2026-11-18 二次定：背景不带块手柄）。
///
/// 左 **0**：竖条贴标记列（与列表圆点同轴——其它块的标记列都从手柄右侧
/// 48px 起，旧实现的外层 12px 内距把手柄和竖条一起推偏了）；右 12、上下 8
/// 是内容呼吸。
///
/// ⚠️ **几何契约**：`BlockHeightPredictor` 的文字可用宽（`.horizontal`）与
/// 块高预测（`.vertical`）都从本常量取数——改这里预测自动跟着走，spike
/// 测试盯一致性（同 `calloutInnerPadding` 的先例）。
const EdgeInsets quoteBgPadding = EdgeInsets.fromLTRB(0, 8, 12, 8);

/// 引用块（type = `quote`）：官方原版 + **primary 淡底**（2026-11-18）。
///
/// - 背景：[Bauhaus.quoteTint]（亮 8% / 暗 12%，竖条同源 primary 的面化），
///   [Tokens.radiusSm](10) 圆角，内距 [quoteBgPadding]——**范围只盖内容**
///   （竖条 + 正文），不盖块手柄（用户定："背景不带块手柄好些"——手柄是
///   编辑器 chrome，被内容底色罩住会显得像引用的一部分）；
/// - 手柄：官方 [BlockComponentActionWrapper] 由本外壳包在淡底**外**——
///   官方 `QuoteBlockComponentWidget` 原样用、不带动作槽，零 fork；
///   手柄与竖条因此都回到标准标记列位置（与列表圆点同轴）；
/// - 与**高亮块**（Callout）分工：引用 = 左色带 + 极淡底、无图标；
///   高亮块 = 图标 + 更重的主题底、无色带——"谁说的" vs "注意！"。
class SinanQuoteBlockBuilder extends QuoteBlockComponentBuilder {
  // `iconBuilder` 不经 super 传——竖条由 [_QuoteShell] 直建官方 widget 时注入。
  // （官方构造非 const ⇒ 本构造也不能 const，lint 的"可 const"是误报。）
  // ignore: prefer_const_constructors_in_immutables
  SinanQuoteBlockBuilder({required super.configuration});
  @override
  BlockComponentWidget build(BlockComponentContext blockComponentContext) =>
      _QuoteShell(
        node: blockComponentContext.node,
        configuration: configuration,
        showActions: showActions(blockComponentContext.node),
        actionBuilder: (
          BuildContext context,
          BlockComponentActionState state,
        ) => actionBuilder(blockComponentContext, state),
        actionTrailingBuilder: (
          BuildContext context,
          BlockComponentActionState state,
        ) => actionTrailingBuilder(blockComponentContext, state),
      );
}

/// 引用块外壳：淡底在**手柄内侧**（结构：`ActionWrapper[手柄, 淡底[内容]]`）。
class _QuoteShell extends BlockComponentStatelessWidget {
  const _QuoteShell({
    required super.node,
    required super.configuration,
    required super.showActions,
    required super.actionBuilder,
    required super.actionTrailingBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    Widget content = DecoratedBox(
      decoration: BoxDecoration(
        color: Bauhaus.quoteTint(theme.brightness, theme.colorScheme.primary),
        borderRadius: BorderRadius.circular(Tokens.radiusSm),
      ),
      child: Padding(
        padding: quoteBgPadding,
        child: QuoteBlockComponentWidget(
          key: node.key,
          node: node,
          configuration: configuration,
          iconBuilder: _bar,
        ),
      ),
    );
    if (showActions && actionBuilder != null) {
      content = BlockComponentActionWrapper(
        node: node,
        actionBuilder: actionBuilder!,
        actionTrailingBuilder: actionTrailingBuilder,
        child: content,
      );
    }
    return content;
  }
}

/// 引用块竖条（几何**照官方 `_QuoteIcon` 复刻**）：quote 的
/// `Row(crossAxisAlignment: stretch)` 会把图标拉到**整块高**，竖条必须
/// 自己撑满——外层 26×22 最小约束 + 内层 4px 宽无高约束。
/// 色取主题 primary 原色，不削弱：与正文链接色同源，明暗切换自动跟随。
Widget _bar(BuildContext context, Node node) {
  final double tsf = context.read<EditorState>().editorStyle.textScaleFactor;
  return Container(
    alignment: Alignment.center,
    constraints: const BoxConstraints(minWidth: 26, minHeight: 22) * tsf,
    padding: const EdgeInsets.only(right: 4.0),
    child: Container(
      width: 4 * tsf,
      color: Theme.of(context).colorScheme.primary,
    ),
  );
}
