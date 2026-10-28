import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';
import 'focus_ring.dart';
import 'tokens.dart';

/// **分裂图标钮**（split button）：一枚控件外壳里装**两个动作**。
///
/// 形态（2026-10-28 用户定）——**整体按"一个按钮"的标准排，内部切两个功能区**：
/// ```
/// ┌──────────────────────────────┐
/// │ ␣␣␣ ＋ ␣␣ ▾ ␣␣␣ │   ← 边距 5 / 图标 18 / 间距 4 / 三角 8 / 边距 5
/// └──────────────────────────────┘        合计 40 × 28
/// ```
/// - **两侧边距与 [AppIconButton] 同一条**（`(28 − 18) / 2 = 5`）⇒ 它和搜索 / 筛选
///   并排时，图标到控件边缘的留白**完全对齐**；
/// - 中间 4（[Tokens.spaceXs]）把两个图标分开，**点击分界正好落在间距中点**：
///   左 25 宽主区、右 15 宽下拉区，各走各的动作；
/// - 底色画在**外层**：指针落在任一处（或任一半有键盘焦点、或菜单展开）
///   ⇒ **整块**一起亮 —— 外观是"一个按钮"，行为是两个动作；
/// - 两半仍**各自**是焦点站 + 语义按钮 ⇒ 键盘用户能分别触发。
///
/// ⚠️ 为什么总宽是 40 而不是与筛选相同的 28：**装不下**。
/// `5 + 18 + 4 + 8 + 5 = 40`；要压到 28 必须把主图标缩到 10、三角缩到 4，
/// 主图标就和同排的 18 不齐了。所以取"边距齐、图标齐、总宽多出 12"。
///
/// ⚠️ 为什么不给 [AppIconButton] 加 flat 模式：那会让"一个按钮一个动作"的组件
/// 长出 hover 归属、单侧圆角、形态分支。组合形态就新开一枚组件，视觉令牌仍同源。
///
/// ⚠️ 为什么不用现成组件：Material 3 没有 split button；`SegmentedButton` 是
/// **单选**语义；`MenuAnchor` 只管菜单不画外观；第三方包要额外依赖且样式不可控；
/// `fluent_ui` 的 `SplitButton` 是整站风格包，不能只借一个控件。自绘最省。
class AppSplitIconButton extends StatefulWidget {
  const AppSplitIconButton({
    super.key,
    required this.primaryIcon,
    required this.primaryTooltip,
    required this.onPrimary,
    required this.secondaryIcon,
    required this.secondaryTooltip,
    required this.onSecondary,
    this.height = Tokens.headerActionSize,
    this.edgePadding = (Tokens.headerActionSize - Tokens.iconSm) / 2,
    this.gap = Tokens.spaceXs,
    this.iconSize = Tokens.iconSm,
    this.secondaryIconSize = Tokens.iconMicro,
    this.secondaryActive = false,
  });

  final Widget primaryIcon;
  final String primaryTooltip;
  final VoidCallback? onPrimary;

  final Widget secondaryIcon;
  final String secondaryTooltip;
  final VoidCallback? onSecondary;

  final double height;

  /// 左右内边距，默认 `(28 − 18) / 2 = 5` —— 与 [AppIconButton] 的图标留白同值。
  final double edgePadding;

  /// 主图标与三角之间的间距（默认 [Tokens.spaceXs] = 4）。
  final double gap;

  final double iconSize;
  final double secondaryIconSize;

  /// 右半对应动作处于"激活"态（如菜单正在展开）——整块保持底色。
  final bool secondaryActive;

  @override
  State<AppSplitIconButton> createState() => _AppSplitIconButtonState();
}

class _AppSplitIconButtonState extends State<AppSplitIconButton> {
  bool _hover = false;
  final FocusNode _primaryFocus = FocusNode();
  final FocusNode _secondaryFocus = FocusNode();

  /// 主区宽 = 左内边距 + 图标 + 半个间距。
  double get _primaryWidth =>
      widget.edgePadding + widget.iconSize + widget.gap / 2;

  /// 下拉区宽 = 半个间距 + 三角 + 右内边距。
  double get _secondaryWidth =>
      widget.gap / 2 + widget.secondaryIconSize + widget.edgePadding;

  @override
  void initState() {
    super.initState();
    // 键盘焦点落在任一半 ⇒ 整块亮（外观上它是一枚控件）。
    _primaryFocus.addListener(_onFocusChanged);
    _secondaryFocus.addListener(_onFocusChanged);
  }

  void _onFocusChanged() => setState(() {});

  @override
  void dispose() {
    _primaryFocus
      ..removeListener(_onFocusChanged)
      ..dispose();
    _secondaryFocus
      ..removeListener(_onFocusChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Brightness b = theme.brightness;
    final bool enabled = widget.onPrimary != null || widget.onSecondary != null;
    // **整块**一起亮：hover 任一处 / 任一半有焦点 / 菜单展开。
    final bool lit =
        enabled &&
        (_hover ||
            _primaryFocus.hasFocus ||
            _secondaryFocus.hasFocus ||
            widget.secondaryActive);

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) {
        if (enabled && !_hover) setState(() => _hover = true);
      },
      onExit: (_) {
        if (_hover) setState(() => _hover = false);
      },
      child: AnimatedContainer(
        duration: Tokens.durationFast,
        curve: Curves.easeOut,
        height: widget.height,
        decoration: BoxDecoration(
          color: lit ? AppTheme.hoverOverlay(b) : Colors.transparent,
          borderRadius: BorderRadius.circular(Tokens.radiusButton),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _SplitHalf(
              icon: widget.primaryIcon,
              tooltip: widget.primaryTooltip,
              onPressed: widget.onPrimary,
              width: _primaryWidth,
              height: widget.height,
              iconSize: widget.iconSize,
              focusNode: _primaryFocus,
              leftRounded: true,
              // 左边距与 [AppIconButton] 同值：图标左基线跟同排按钮对齐。
              // 右侧剩下的就是半个间距（gap/2）。
              padding: EdgeInsets.only(left: widget.edgePadding),
              alignment: Alignment.centerLeft,
            ),
            _SplitHalf(
              icon: widget.secondaryIcon,
              tooltip: widget.secondaryTooltip,
              onPressed: widget.onSecondary,
              width: _secondaryWidth,
              height: widget.height,
              iconSize: widget.secondaryIconSize,
              focusNode: _secondaryFocus,
              leftRounded: false,
              // 左 2 = 半个间距（把"间距 4"拆到两半各一半，分界落在中点）；
              // 右 5 = 与主区同一右内边距，三角到控件右缘的留白也对齐。
              padding: EdgeInsets.only(
                left: widget.gap / 2,
                right: widget.edgePadding,
              ),
              alignment: Alignment.centerLeft,
            ),
          ],
        ),
      ),
    );
  }
}

/// 半区：只管**动作**（tooltip / 焦点 / 语义 / 手势 / 图标），
/// **不画底色**——底色归外层统一（所以 hover 是整块亮，不是半块亮）。
class _SplitHalf extends StatelessWidget {
  const _SplitHalf({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.width,
    required this.height,
    required this.iconSize,
    required this.focusNode,
    required this.leftRounded,
    required this.alignment,
    required this.padding,
  });

  final Widget icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double width;
  final double height;
  final double iconSize;
  final FocusNode focusNode;

  /// true ⇒ 外侧圆角在左（主区）；false ⇒ 在右（下拉区）。
  /// 焦点环跟着外壳形状走，视觉上仍是"整块"的轮廓。
  final bool leftRounded;

  /// 图标在半区里的对齐（两半都是 `centerLeft`，边距靠 [padding] 精确控制）。
  final Alignment alignment;

  /// 图标外侧的内缩：主区只缩左（[AppSplitIconButton.edgePadding]），
  /// 下拉区缩左（半个间距）+ 右（[AppSplitIconButton.edgePadding]）。
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool enabled = onPressed != null;
    // 色源单点：与 [AppIconButton] 同一条（常驻 onSurfaceVariant，禁用降一档）。
    final Color ink = enabled
        ? theme.colorScheme.onSurfaceVariant
        : AppTheme.disabledInk(theme.colorScheme.onSurfaceVariant);
    final BorderRadius radius = BorderRadius.horizontal(
      left: leftRounded
          ? const Radius.circular(Tokens.radiusButton)
          : Radius.zero,
      right: leftRounded
          ? Radius.zero
          : const Radius.circular(Tokens.radiusButton),
    );

    return Tooltip(
      message: tooltip,
      child: FocusableActionDetector(
        focusNode: focusNode,
        enabled: enabled,
        mouseCursor: SystemMouseCursors.click,
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<Intent>(
            onInvoke: (_) {
              onPressed?.call();
              return null;
            },
          ),
        },
        child: Semantics(
          button: true,
          enabled: enabled,
          label: tooltip,
          child: FocusRing(
            focusNode: focusNode,
            // 焦点环只给键盘（同 [AppIconButton] 口径）。
            keyboardOnly: true,
            borderRadius: radius,
            child: GestureDetector(
              onTap: onPressed,
              child: SizedBox(
                width: width,
                height: height,
                child: Padding(
                  padding: padding,
                  child: Align(
                    alignment: alignment,
                    child: IconTheme(
                      data: IconThemeData(color: ink, size: iconSize),
                      child: icon,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
