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
///   ⇒ **整块**一起亮 —— 外观是"一个按钮"；
/// - **分区反馈**（2026-11-09 用户定，方案 A）：整块亮的同时，**当前那半再叠一层底**
///   （hover）/ 更深一档（按下），并在两半之间显 1px 发丝 ⇒ 鼠标在哪半一眼可见。
///   之前只有一个整块 `_hover`，两半反馈完全一样，实机"没提示也没触感"；
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
  /// 两半**各自**的 hover（由 [_SplitHalf] 回调上来）⇒ 整块是否亮、发丝是否显。
  bool _hoverPrimary = false;
  bool _hoverSecondary = false;
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
    final bool enabled =
        widget.onPrimary != null || widget.onSecondary != null;
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
      decoration: BoxDecoration(
        color: lit ? AppTheme.hoverOverlay(b) : Colors.transparent,
        borderRadius: BorderRadius.circular(Tokens.radiusButton),
      ),
      child: Stack(
        // 焦点环可能画到界外，别裁。
        clipBehavior: Clip.none,
        children: <Widget>[
          Row(
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
                padding: EdgeInsets.only(left: widget.edgePadding),
                alignment: Alignment.centerLeft,
                focused: _primaryFocus.hasFocus,
                onHoverChanged: (bool v) =>
                    setState(() => _hoverPrimary = v),
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
                // 左 2 = 半个间距；右 5 = 与主区同一右内边距。
                padding: EdgeInsets.only(
                  left: widget.gap / 2,
                  right: widget.edgePadding,
                ),
                alignment: Alignment.centerLeft,
                focused: _secondaryFocus.hasFocus,
                onHoverChanged: (bool v) =>
                    setState(() => _hoverSecondary = v),
              ),
            ],
          ),
          // 1px 发丝：**hover 时才显**，落在两半的间距中点。用 Positioned 叠上去
          // 而不是 Row 的 child ⇒ 不占布局宽度，控件总宽仍是 40（测试钉着）。
          Positioned(
            left: _primaryWidth,
            top: Tokens.spaceXs,
            bottom: Tokens.spaceXs,
            width: 1,
            child: IgnorePointer(
              child: ColoredBox(
                color: lit ? Bauhaus.line(b) : Colors.transparent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 半区：自己管 hover / 按下 / 焦点三种**分区反馈**，并画一层半透明底。
///
/// 父级已画整块底，这里再叠一层 ⇒ 当前半自然更深；按下再换更深一档。
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
    required this.alignment,
    required this.padding,
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

  /// 图标在半区里的对齐（两半都是 `centerLeft`，边距靠 [padding] 精确控制）。
  final Alignment alignment;

  /// 图标外侧的内缩：主区只缩左，下拉区缩左（半个间距）+ 右。
  final EdgeInsets padding;

  /// 键盘焦点是否落在本半区（由父级持有 FocusNode 后传入）。
  final bool focused;

  /// 通知父级整块是否该亮 / 发丝是否该显。
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

    final bool active = enabled && (_hover || _pressed || widget.focused);
    final Color halfBg = !active
        ? Colors.transparent
        : _pressed
        // 按下：比 hover 再深一档（同项目 selectedBg 的口径）。
        ? theme.colorScheme.onSurface.withValues(alpha: 0.10)
        // hover / 键盘焦点：与父级整块底同色，叠一层 ⇒ 本半更深。
        : AppTheme.hoverOverlay(b);

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
                  child: Padding(
                    padding: widget.padding,
                    child: Align(
                      alignment: widget.alignment,
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
      ),
    );
  }
}
