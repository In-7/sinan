import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';
import 'focus_ring.dart';
import 'tokens.dart';

/// **自绘图标钮**（PC 观感）：列表头 / 工具行的**统一宿主**。
///
/// ## 为什么不用 M3 `IconButton`
/// 两个理由，第二个是要命的：
///
/// 1. **观感**：M3 `IconButton` 带 Ink 涟漪与 48dp tap target——触摸遗产，
///    不是 PC 观感（PC 要 hover 铺热区、无涟漪、紧凑密度）。
/// 2. **色源分叉**：`IconButton` 的图标色走**组件下发**链路（
///    `ButtonStyleButton` 把 `foregroundColor` 经 `IconTheme.merge` 塞给图标），
///    而手搓容器走**调用点钉色**（显式 `IconTheme(color: onSurfaceVariant)`）。
///    两条路字面都指向 `onSurfaceVariant`，真机却解析出两档灰
///    （2026-10-26 实测：同一行里同时出现 `33,34,34` 与 `76,76,76`）。
///
/// 本件把**图标色、图标档、热区、hover 底、焦点环**全部收在一处 ⇒ 宿主统一
/// 即颜色统一，不再依赖任何隐式下发链路。
///
/// ## 观感契约（PC）
/// - hover 铺 [AppTheme.hoverOverlay]（热区高亮，不是"再抬一层"）；
/// - 焦点环**只给键盘**（鼠标点过不戴环，避免误读成选中态，同 [_NoteRow] 口径）；
/// - 无 Ink 涟漪、无 M3 状态层；
/// - 热区 [Tokens.headerActionSize]（28）、图标 [Tokens.iconSm]（18）
///   ——与编辑页撤销 / 重做同档。
///
/// ⚠️ **调用点不要给图标传 `color`**：让它读这里的 [IconTheme]，否则又会长出
/// 第二个色源（SVG 的 `colorFilter` 直读传入色，`disabledInk` 也碰不到它，
/// 见 [AppTheme.disabledInk] 的坑注）。
class AppIconButton extends StatefulWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = Tokens.headerActionSize,
    this.width,
    this.iconSize = Tokens.iconSm,
  });

  /// 图标。**不要传 `color`**——色由本件单点下发。
  final Widget icon;

  /// tooltip（同时是读屏标签）。
  final String tooltip;

  /// 点击回调；`null` ⇒ 禁用：置灰、不可聚焦、hover 不铺底。
  final VoidCallback? onPressed;

  /// 热区高（默认 [Tokens.headerActionSize]）。
  final double size;

  /// 热区宽（默认与 [size] 同 ⇒ 正方）。窄钮（托盘箭头 22）传此值。
  final double? width;

  /// 图标档（默认 [Tokens.iconSm]=18）。行内装饰记号可传 [Tokens.iconXs]。
  final double iconSize;

  @override
  State<AppIconButton> createState() => _AppIconButtonState();
}

class _AppIconButtonState extends State<AppIconButton> {
  bool _hover = false;
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Brightness b = theme.brightness;
    final bool enabled = widget.onPressed != null;

    // **色源单点**：常驻 `onSurfaceVariant`（PC 观感的次级墨色），禁用降一档。
    // 既不靠 IconButton 的组件下发，也不让调用点硬编码——宿主统一即色统一。
    final Color ink = enabled
        ? theme.colorScheme.onSurfaceVariant
        : AppTheme.disabledInk(theme.colorScheme.onSurfaceVariant);
    final Color bg = (_hover && enabled)
        ? AppTheme.hoverOverlay(b)
        : Colors.transparent;

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: FocusableActionDetector(
          focusNode: _focus,
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
              focusNode: _focus,
              // 焦点环只给键盘：鼠标点过也戴环会被误读成选中态。
              keyboardOnly: true,
              borderRadius: BorderRadius.circular(Tokens.radiusButton),
              child: GestureDetector(
                onTap: widget.onPressed,
                child: Container(
                  width: widget.width ?? widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(Tokens.radiusButton),
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
