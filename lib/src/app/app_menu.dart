import 'dart:async';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import 'package:flutter_riverpod/flutter_riverpod.dart';import 'package:material_ui/material_ui.dart';

import '../domain/settings.dart';
import '../theme/app_popover.dart';
import '../theme/tokens.dart';
import '../window/window_service.dart';
import 'providers.dart';
import 'settings_panel.dart';

/// **右上角主菜单**（设置 / 关于 / 明暗切换 / 退出）。
///
/// ## 为什么是自家浮层，而不是 `PopupMenuButton`（2026-09-22 换件）
/// SDK 的面板在 `_PopupMenuRoute` 内部，**插不进 `BackdropFilter`** ⇒ 做不出
/// "局部模糊（磨砂）"。换成 [AppPopover] + [AppFloatSurface] 之后，它与全仓浮层
/// 同一套令牌（三件套 + Layer + 磨砂），并且**可以被 widget 测试挂起来**
/// （`test/app/app_menu_test.dart`）——SDK 那条路由做不到。
///
/// ## 换件时逐条核对过的行为（别丢）
/// - **位置**：落在锚点下沿 + `Tokens.spaceXs`（旧版是 `PopupMenuPosition.under`
///   + 4px offset，且为了"菜单别压住按钮"把 padding 置零）；
/// - **按钮**：caption 档图标按钮（46×32 直角、中性悬停，见 [_captionButtonStyle]），
///   tooltip 仍是「菜单」，**移动端**走默认样式（`style == null`）；
/// - **关闭**：点面板外 / Esc 由 [AppPopover] 负责；**选完即关**由行自己调 `close()`。
///
/// ⚠️ 那个"按 0 padding + offset"的坑随 SDK 一起消失了：`AppPopover` 本来就把
/// 面板放在**锚点下方**，不存在"菜单顶边落进按钮内部"的问题。
class AppMenuButton extends ConsumerWidget {
  const AppMenuButton({
    super.key,
    this.iconSize = 24,
    this.captionStyle = false,
  });

  /// 标题栏里与窗控图标对齐时传 20；移动端 AppBar 走默认 24。
  final double iconSize;

  /// true = 复刻窗控按钮外观（点击区/悬停同窗控）；移动端 false。
  final bool captionStyle;

  /// 面板宽度：最宽那行是「明暗切换 + 右侧状态字」，180 留得住。
  static const double _panelWidth = 180;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ButtonStyle? style = captionStyle
        ? _captionButtonStyle(context)
        : null;

    return AppPopover(
      panelWidth: _panelWidth,
      // **磨砂档**：局部模糊 + 半透明底（两件事必须成套，见 [AppTheme.menuLayerAlpha]）。
      blur: true,
      anchorBuilder: (BuildContext _, VoidCallback toggle, bool isOpen) =>
          IconButton(
            tooltip: '菜单',
            onPressed: toggle,
            style: style,
            icon: tabler.ChevronDown(height: iconSize, width: iconSize, strokeWidth: 1.5),
          ),
      builder: (BuildContext ctx, VoidCallback close) {
        final ThemeBrightnessMode mode = ref
            .read(settingsProvider)
            .brightnessMode;

        void pick(_AppMenuItem item) {
          close();
          switch (item) {
            case _AppMenuItem.settings:
              unawaited(showSettingsPanel());
            case _AppMenuItem.about:
              showAboutPanel(context);
            case _AppMenuItem.toggleBrightness:
              final ThemeBrightnessMode cur = ref
                  .read(settingsProvider)
                  .brightnessMode;
              ref
                  .read(settingsProvider.notifier)
                  .setBrightnessMode(_nextBrightness(cur));
            case _AppMenuItem.exit:
              // `close()` 已经把面板收了，这里只管退：上下文不必再存活。
              unawaited(WindowService.close());
          }
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _MenuRow(
              icon: tabler.Settings(height: 24, width: 24, strokeWidth: 1.5),
              label: '设置',
              onTap: () => pick(_AppMenuItem.settings),
            ),
            _MenuRow(
              icon: tabler.InfoCircle(height: 24, width: 24, strokeWidth: 1.5),
              label: '关于',
              onTap: () => pick(_AppMenuItem.about),
            ),
            _MenuRow(
              // 图标表示「点此切换到的目标态」：浅色时点下去进深色 → 月亮；
              // 深色时 → 太阳。右侧文字仍是当前态提示，二者互补更直觉。
              icon: mode == ThemeBrightnessMode.light
                  ? tabler.Moon(height: 24, width: 24, strokeWidth: 1.5)
                  : tabler.Sun(height: 24, width: 24, strokeWidth: 1.5),
              label: '明暗切换',
              trailing: _brightnessLabel(mode),
              onTap: () => pick(_AppMenuItem.toggleBrightness),
            ),
            _MenuRow(
              icon: tabler.Logout(height: 24, width: 24, strokeWidth: 1.5),
              label: '退出',
              onTap: () => pick(_AppMenuItem.exit),
            ),
          ],
        );
      },
    );
  }
}

/// 菜单里的一行：图标 + 文字（+ 右侧状态）。高 40，悬停用浮层通用的状态层。
class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
  });

  final Widget icon;
  final String label;
  final String? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Material(
      // ⚠️ 显式透明（不是 null）：`Material(color: null)` 会落到 `canvasColor`
      // ⇒ 每一行自己画一块实色，把浮层底盖掉（导航项踩过同一个坑）。
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Tokens.spaceMd,
            vertical: Tokens.spaceSm,
          ),
          child: Row(
            children: <Widget>[
              icon,
              const SizedBox(width: Tokens.spaceSm + 4),
              Text(label, style: theme.textTheme.bodyMedium),
              if (trailing != null) ...<Widget>[
                const Spacer(),
                Text(
                  trailing!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 复刻 window_manager 的 `WindowCaptionButton`（最小化/最大化这类非关闭按钮）
/// 外观：46×32、直角、中性色悬停/按下、无水波纹。供标题栏菜单按钮对齐窗控
/// （关闭按钮是红色，菜单不套红色）。
ButtonStyle _captionButtonStyle(BuildContext context) {
  final bool dark = Theme.of(context).brightness == Brightness.dark;
  final Color hover = dark
      ? Colors.white.withValues(alpha: 0.0605)
      : Colors.black.withValues(alpha: 0.0373);
  final Color pressed = dark
      ? Colors.white.withValues(alpha: 0.0419)
      : Colors.black.withValues(alpha: 0.0241);
  return ButtonStyle(
    minimumSize: WidgetStateProperty.all(const Size(46, 32)),
    maximumSize: WidgetStateProperty.all(const Size(46, 32)),
    padding: WidgetStateProperty.all(EdgeInsets.zero),
    shape: WidgetStateProperty.all(const RoundedRectangleBorder()),
    backgroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
      if (states.contains(WidgetState.pressed)) return pressed;
      if (states.contains(WidgetState.hovered)) return hover;
      return Colors.transparent;
    }),
    // 窗控按钮没有水波纹，用透明 overlay 抑制 IconButton 默认 ripple。
    overlayColor: WidgetStateProperty.all(Colors.transparent),
  );
}

enum _AppMenuItem { settings, about, toggleBrightness, exit }

/// 当前明暗模式的短标签，挂在「明暗切换」菜单项右侧做状态提示。
String _brightnessLabel(ThemeBrightnessMode m) => switch (m) {
  ThemeBrightnessMode.light => '浅色',
  ThemeBrightnessMode.dark => '深色',
};

/// 明暗互切：浅 ↔ 深（不再有「跟随系统」第三态）。
ThemeBrightnessMode _nextBrightness(ThemeBrightnessMode cur) => switch (cur) {
  ThemeBrightnessMode.light => ThemeBrightnessMode.dark,
  ThemeBrightnessMode.dark => ThemeBrightnessMode.light,
};
