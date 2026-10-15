import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';

/// **统一焦点环**（`docs/ui_rewrite_plan.md` §5.2）。
///
/// ## 用法：把**控件自己的** `FocusNode` 交给它
/// ```dart
/// final FocusNode _focus = FocusNode();   // 同时给 InkWell/`Focus` 用
/// ...
/// FocusRing(
///   focusNode: _focus,
///   borderRadius: BorderRadius.circular(Tokens.radiusSm),
///   child: InkWell(focusNode: _focus, ...),
/// )
/// ```
///
/// ## 为什么接"控件自己的节点"，而不是自己造一个祖先探针
/// 第一版实现是**自跟踪**的：`Focus(canRequestFocus: false, onFocusChange: ...)`
/// 包住子控件，靠"祖先节点的 `hasFocus`"判断子树是否被聚焦。它**也能工作**，
/// 但语义绕了一层（依赖 `hasFocus` 向祖先传播的规则）；而调用方本来就持有那个
/// 控件自己的 `FocusNode`（`InkWell` / `FocusableActionDetector` 都要它）。
/// 直接监听它 = Flutter 里所有控件同款的机制，语义零歧义。
///
/// ## ⚠️ 一条调试经验（2026-09-21 实测，写下来免得下次再踩）
/// 焦点变化由 `FocusManager` 在**帧末**统一结算（防重入）⇒ 监听回调引发的重建
/// 落在**下一帧**。所以测试里 `requestFocus()` 之后要**多推一帧**再断言，否则断的
/// 是"上一帧的环"，表现为"环卡住不撤"的**假红**——第一版就是这么误诊的，
/// 当时还错怪了祖先探针的写法。
///
/// ## 为什么不用 `InkWell.focusColor` / `ButtonStyle`
/// 那些是**整块底色**（M3 语汇），而 §5.2 要的是**环**（桌面语汇：一眼看出
/// "键盘焦点在哪"）。两者语义不同，不能互相替代。
///
/// ## 画在边界内侧（`foregroundDecoration`）
/// 计划原文是"primary 2px + 1px 外间隙"。实现取画在边界**内侧**：
/// - 画在外面要占 3px 布局 —— 要么内容位移（列表行会跳），要么被父容器裁剪切掉；
/// - 1px 的外间隙在 32px 图标按钮 / 28px 列表行上视觉收益极小。
///
/// `foregroundDecoration` 画在子控件**之上**且**不参与布局**：环出现/消失时
/// 尺寸与位置逐像素不变（测试钉住了这一点）。
class FocusRing extends StatefulWidget {
  const FocusRing({
    super.key,
    required this.focusNode,
    required this.borderRadius,
    required this.child,
    this.color,
  });

  /// 要观察的焦点节点——**控件自己的那个**（同一个节点也要给控件用）。
  final FocusNode focusNode;

  /// 环的圆角——**应当与该控件的形状一致**（否则环会"错位"一个圆角）。
  final BorderRadius borderRadius;

  /// 环色（缺省 = `scheme.primary`）。方案 B（2026-10-15）起 primary 恒定
  /// 包豪斯蓝，两者同值；包豪斯平面的控件（如新建胶囊）仍显式传
  /// [Bauhaus.blue]——不依赖"primary 恰好是蓝"这个不变式，各自钉死。
  final Color? color;

  final Widget child;

  @override
  State<FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<FocusRing> {
  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(FocusRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChanged);
      widget.focusNode.addListener(_onFocusChanged);
    }
  }

  @override
  void dispose() {
    // 不摘监听：节点比本 widget 活得久（它归父控件所有）⇒ 会往已 dispose 的
    // State 上 setState。
    widget.focusNode.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      foregroundDecoration: widget.focusNode.hasFocus
          ? AppTheme.focusRing(
              Theme.of(context).colorScheme,
              borderRadius: widget.borderRadius,
              color: widget.color,
            )
          : null,
      child: widget.child,
    );
  }
}

/// `IconButton` + 统一焦点环——§5.2 第二步"铺开"用这一件。
///
/// ## 为什么需要它（而不是每个调用点自己写两行）
/// [FocusRing] 必须跟着**控件自己的** `FocusNode`（见 [FocusRing] 的说明），而
/// `IconButton` 的节点是它内部创建的、外面拿不到 ⇒ 得有人**持有节点并同时交给两边**。
/// 这个 `StatefulWidget` 就是那个人：`IconButton(focusNode: _focus, …)` +
/// `FocusRing(focusNode: _focus, …)`。设置面板 `_NavTile` 对 `InkWell` 做的是一次性
/// 写法；Material 按钮会出现很多处（画布工具条 / 标题栏 / 编辑器工具栏），所以抽出来。
///
/// ## 圆角默认"圆"
/// M3 的 `IconButton` 默认形状是 `CircleBorder`，而环应当与控件形状一致（否则圆角
/// "错位"）。默认给一个**远超尺寸的圆角**——`RRect` 会按矩形把它夹到半径上限，实际
/// 渲染就是圆。主题把按钮改成方角时（标题栏那类 `radiusSm` 方角图标按钮），显式传
/// `BorderRadius.circular(Tokens.radiusSm)`。
class FocusRingIconButton extends StatefulWidget {
  const FocusRingIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.style,
    this.isSelected,
    this.borderRadius = const BorderRadius.all(Radius.circular(999)),
  });

  final Widget icon;
  final String tooltip;

  /// 为 null 即禁用（与 `IconButton` 同语义）：禁用按钮不可聚焦 ⇒ 不会有环。
  final VoidCallback? onPressed;

  final ButtonStyle? style;

  /// 选中态（M3 `IconButton.isSelected`）：画布工具条那三块入口按钮用它表达
  /// "浮层开着 / 该工具生效中"。null = 不参与选中语义（与 `IconButton` 一致）。
  final bool? isSelected;

  final BorderRadius borderRadius;

  @override
  State<FocusRingIconButton> createState() => _FocusRingIconButtonState();
}

class _FocusRingIconButtonState extends State<FocusRingIconButton> {
  /// 同一个节点交给**两边**——这是本件存在的全部理由（见类文档）。
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FocusRing(
      focusNode: _focus,
      borderRadius: widget.borderRadius,
      child: IconButton(
        icon: widget.icon,
        tooltip: widget.tooltip,
        style: widget.style,
        isSelected: widget.isSelected,
        onPressed: widget.onPressed,
        focusNode: _focus,
      ),
    );
  }
}
