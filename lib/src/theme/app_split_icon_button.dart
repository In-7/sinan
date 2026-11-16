import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';
import 'focus_ring.dart';
import 'tokens.dart';

/// **分裂图标钮**（split button）：一枚控件外壳里装**两个动作**。
///
/// 形态（2026-11-09 用户定：**两半各自居中 + 主次靠尺寸与颜色层级**）：
/// ```
/// ┌────────────────────────────┐
/// │  ␣4  ＋18  ␣4 │ ␣2 ▾8 ␣2 │  ← 合计 38 × 28
/// └────────────────────────────┘
///      主区 26       副区 12     ⇒ 2.17 : 1
/// ```
/// - 主区宽 = 图标 18 + 左右各 4；副区宽 = 三角 8 + 左右各 2。**两半都居中**，
///   点击分界就是两半的几何边界（x=26），不再藏在"间距中点"里；
/// - **主次靠尺寸 + 颜色层级**：副区只有 12 宽，且 hover 叠加底只有主区一半浓度
///   ⇒ 「更多」读成次级动作，不需要额外画分隔线；
/// - **不画分隔线**（2026-11-09 用户定）：线在说"这里分两段"，整块亮在说
///   "这是一个整体"，两者打架；而且 1px 线在 DPR 1.5 下是 1.5 物理像素，
///   必然摊成"一格满 + 一格半亮"的灰边；
/// - 底色画在**外层**：任一 hover / 焦点 / 菜单展开 ⇒ **整块**一起亮；
/// - **分区反馈**：整块亮的同时当前半再叠一层（hover）/ 更深一档（按下）；
/// - 两半仍**各自**是焦点站 + 语义按钮 ⇒ 键盘用户能分别触发。
///
/// ⚠️ **DPR 1.5 像素对齐**（2026-11-09 用户屏）：4 / 2 / 26 / 12 / 38 全是偶数
/// ⇒ ×1.5 得整数物理像素。旧值 5 / 25 / 15 是奇数 ⇒ 7.5 / 37.5 / 22.5 半像素
/// （尤其旧发丝线从 37.5 起、宽 1.5 物理像素，实机发虚）。
///
/// ⚠️ 为什么不用现成组件：Material 3 没有 split button；`SegmentedButton` 是
/// **单选**语义；`MenuAnchor` 只管菜单不画外观；第三方包样式不可控；
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
    this.primaryPadding = 4,
    this.secondaryPadding = 2,
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

  /// 主区**左右各**内留白（默认 4）⇒ 主区宽 = [iconSize] + 2×此值 = 26。
  final double primaryPadding;

  /// 副区**左右各**内留白（默认 2）⇒ 副区宽 = [secondaryIconSize] + 2×此值 = 12。
  final double secondaryPadding;

  final double iconSize;
  final double secondaryIconSize;

  /// 右半对应动作处于"激活"态（如菜单正在展开）——整块保持底色。
  final bool secondaryActive;

  @override
  State<AppSplitIconButton> createState() => _AppSplitIconButtonState();
}

class _AppSplitIconButtonState extends State<AppSplitIconButton> {
  /// 两半**各自**的 hover（由 [_SplitHalf] 回调上来）⇒ 整块是否亮。
  bool _hoverPrimary = false;
  bool _hoverSecondary = false;
  final FocusNode _primaryFocus = FocusNode();
  final FocusNode _secondaryFocus = FocusNode();

  double get _primaryWidth => widget.iconSize + widget.primaryPadding * 2;

  double get _secondaryWidth =>
      widget.secondaryIconSize + widget.secondaryPadding * 2;

  @override
  void initState() {
    super.initState();
    // 键盘焦点落在任一半 ⇒ 整块亮 + 该半分区高亮。
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
    final Brightness b = Theme.of(context).brightness;
    final bool enabled = widget.onPrimary != null || widget.onSecondary != null;
    // **整块**一起亮：任一半 hover / 任一半有焦点 / 菜单展开。
    final bool lit =
        enabled &&
        (_hoverPrimary ||
            _hoverSecondary ||
            _primaryFocus.hasFocus ||
            _secondaryFocus.hasFocus ||
            widget.secondaryActive);

    return AnimatedContainer(
      duration: Tokens.durationFast,
      curve: Curves.easeOut,
      height: widget.height,
      // **常驻浅底**（2026-11-16 用户定：主操作要有视觉权重），**不加描边**。
      // ⚠️ 用 [Bauhaus.controlFill]（墨打折的叠层）而不是 [Bauhaus.surface]：
      // surface 是固定纯白，亮色下与卡底只差 1 L*、实机看不出来（2026-11-16
      // 用户实报）。controlFill 相对卡底叠层，两主题都稳定有明度差。
      decoration: BoxDecoration(
        color: Bauhaus.controlFill(b),
        borderRadius: BorderRadius.circular(Tokens.radiusButton),
      ),
      // hover / 菜单展开的「整块亮」叠在常驻底**之上** ⇒ 静止有权重、
      // 悬浮仍有反馈；下面两半的分区色阶（副区取主区一半浓度）不变。
      child: AnimatedContainer(
        duration: Tokens.durationFast,
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: lit ? AppTheme.hoverOverlay(b) : Colors.transparent,
          borderRadius: BorderRadius.circular(Tokens.radiusButton),
        ),
        // 两半直接排一行即可：不再有发丝线覆盖层 ⇒ 不需要 Stack / Clip.none。
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
              secondary: false,
              focused: _primaryFocus.hasFocus,
              onHoverChanged: (bool v) => setState(() => _hoverPrimary = v),
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
              secondary: true,
              focused: _secondaryFocus.hasFocus,
              onHoverChanged: (bool v) => setState(() => _hoverSecondary = v),
            ),
          ],
        ),
      ),
    );
  }
}

/// 半区：自己管 hover / 按下 / 焦点三种**分区反馈**，并画一层半透明底。
///
/// 图标在半区里**居中**；父级已画整块底，这里再叠一层 ⇒ 当前半更深。
/// [secondary] 为 true 时叠加浓度减半（颜色层级：更多是次级动作）。
/// tooltip / 焦点 / 语义 / 手势也都在这里收口。
class _SplitHalf extends StatefulWidget {
  const _SplitHalf({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.width,
    required this.height,
    required this.iconSize,
    required this.focusNode,
    required this.leftRounded,
    required this.secondary,
    required this.focused,
    required this.onHoverChanged,
  });

  final Widget icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double width;
  final double height;
  final double iconSize;
  final FocusNode focusNode;

  /// true ⇒ 外侧圆角在左（主区）；false ⇒ 在右（下拉区）。
  final bool leftRounded;

  /// true ⇒ 副区：hover / pressed 的叠加底淡一档。
  final bool secondary;

  /// 键盘焦点是否落在本半区（由父级持有 FocusNode 后传入）。
  final bool focused;

  /// 通知父级整块是否该亮。
  final ValueChanged<bool> onHoverChanged;

  @override
  State<_SplitHalf> createState() => _SplitHalfState();
}

class _SplitHalfState extends State<_SplitHalf> {
  bool _hover = false;
  bool _pressed = false;

  void _setHover(bool v) {
    if (_hover == v) return;
    setState(() => _hover = v);
    widget.onHoverChanged(v);
  }

  void _setPressed(bool v) {
    if (_pressed == v) return;
    setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Brightness b = theme.brightness;
    final bool enabled = widget.onPressed != null;
    // 色源单点：与 [AppIconButton] 同一条（常驻 onSurfaceVariant，禁用降一档）。
    final Color ink = enabled
        ? theme.colorScheme.onSurfaceVariant
        : AppTheme.disabledInk(theme.colorScheme.onSurfaceVariant);
    final BorderRadius radius = BorderRadius.horizontal(
      left: widget.leftRounded
          ? const Radius.circular(Tokens.radiusButton)
          : Radius.zero,
      right: widget.leftRounded
          ? Radius.zero
          : const Radius.circular(Tokens.radiusButton),
    );

    // **颜色层级**：副区叠加底取主区的一半浓度。父级整块底仍同源，
    // 所以看起来还是"一枚按钮亮了"，只是主区更实、副区更轻。
    final Color overlay = AppTheme.hoverOverlay(b);
    final bool active = enabled && (_hover || _pressed || widget.focused);
    final Color halfBg = !active
        ? Colors.transparent
        : _pressed
        ? theme.colorScheme.onSurface.withValues(
            alpha: widget.secondary ? 0.06 : 0.10,
          )
        : overlay.withValues(alpha: overlay.a * (widget.secondary ? 0.5 : 1.0));

    return Tooltip(
      message: widget.tooltip,
      // 全局 `TooltipTheme.waitDuration` 是 400ms（防误触），但这枚钮靠 hover
      // 分区表达"两个动作" ⇒ 提示必须跟手。**只覆盖这一项、只覆盖这两枚**。
      //
      // ⚠️ `verticalOffset` / `preferBelow` **一律不传**：和 [AppIconButton]
      // 一样吃主题默认（24 / true）。曾传 `verticalOffset: 8` ⇒ 两枚 tooltip
      // 贴到按钮上、与同排搜索 / 筛选错开 16px（2026-11-09 实报）。
      waitDuration: const Duration(milliseconds: 150),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => _setHover(true),
        onExit: (_) => _setHover(false),
        child: FocusableActionDetector(
          focusNode: widget.focusNode,
          enabled: enabled,
          mouseCursor: SystemMouseCursors.click,
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<Intent>(
              onInvoke: (_) {
                widget.onPressed?.call();
                return null;
              },
            ),
          },
          child: Semantics(
            button: true,
            enabled: enabled,
            label: widget.tooltip,
            child: FocusRing(
              focusNode: widget.focusNode,
              keyboardOnly: true,
              borderRadius: radius,
              child: GestureDetector(
                onTap: widget.onPressed,
                onTapDown: enabled ? (_) => _setPressed(true) : null,
                onTapUp: enabled ? (_) => _setPressed(false) : null,
                onTapCancel: enabled ? () => _setPressed(false) : null,
                child: Container(
                  width: widget.width,
                  height: widget.height,
                  decoration: BoxDecoration(
                    color: halfBg,
                    borderRadius: radius,
                  ),
                  child: Center(
                    child: IconTheme(
                      data: IconThemeData(color: ink, size: widget.iconSize),
                      child: widget.icon,
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
