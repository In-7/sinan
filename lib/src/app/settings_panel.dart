import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/settings.dart';
import 'providers.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// 行高滑杆的上下限与步长（值夹取 / Slider 范围 / 格数三处共用）。
///
/// - 下限 **1.25**：2026-09-11 换霞鹜新晰黑并修正行距几何后（行距 = 行盒 =
///   字号 × 值，滑杆值即**真实视觉倍数**），原下限 1.5 是按旧几何
///   （视觉 ≈(1+值)/2）定的——旧几何 1.5 的视觉密度（1.25×）只有放宽到
///   1.25 才够得着；1.25 仍不低于两家规范的"阅读类"下限的旧视觉口径。
/// - 上限 **2.5**：新几何下就是真 2.5 倍行距（旧几何需 4 倍才够到），
///   上限宽裕，保持不变。
/// - 步长 **0.125**：0.125 网格保证在整数字号下行盒（字号 × 值）吸附后
///   落在整像素上，每一档都锐利。
const double _minLineHeight = 1.25;
const double _maxLineHeight = 2.5;
const double _lineHeightStep = 0.125;

/// 字号滑杆的上下限与步长（值夹取 / Slider 范围 / 格数三处共用）。
///
/// - 下限 **12**：中文正文的舒适下限（再小屏幕沉浸阅读吃力）；
/// - 上限 **24**：大字号写稿 / 演示用，再大正文会顶满窄列；
/// - 步长 **1**：字号以 px 为最小粒度，整数档最直观。
const double _minFontSize = 12;
const double _maxFontSize = 24;
const double _fontSizeStep = 1;

/// 字号显示：取整（12 / 16 / 24）。
String _formatFontSize(double value) => value.round().toString();

/// 行高显示：**最多三位小数、去掉尾随零**（1.5 / 1.625 / 2.375）。
///
/// 步长 0.125 ⇒ 两位小数会把 1.625 舍成 1.63（与滑块气泡不一致），
/// 固定三位又会把 1.5 写成 1.500（难看）——故按需保留。
String _formatLineHeight(double value) =>
    value.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');

/// 应用导航根的 key：供**从 MaterialApp 之上**触发的浮层取 root Overlay。
///
/// 设置入口按钮构建于 MainApp 的 build（MaterialApp 之外），其闭包里的
/// context 向上找不到 Overlay（崩溃："No Overlay widget found" 的根源）。
/// 挂上这个 key 后，浮层一律从导航根取 Overlay，与触发处的 context 无关。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// 面板宽度：左侧目录导航（176）+ 内容列——够放下
/// 「标签 + SegmentedButton（三档）」同排不换行。
const double _panelWidth = 720;

/// 面板高度：两栏布局需要**稳定的高度**（单列时代的"内容多高面板多高"
/// 会让右侧滚动区高度随分区跳动）；窗口太矮时由外层 maxHeight 钳制。
const double _panelHeight = 560;

/// 左侧目录导航的分区。**加功能的入口**：枚举加一项 +
/// [_SettingsCardState._rowsFor] 加一个分支（行表照抄既有 Row 组件）。
enum _SettingsSection {
  appearance,
  editor,
}

extension _SettingsSectionSpec on _SettingsSection {
  String get label => switch (this) {
    _SettingsSection.appearance => '外观',
    _SettingsSection.editor => '编辑器',
  };

  IconData get icon => switch (this) {
    _SettingsSection.appearance => LucideIcons.palette300,
    _SettingsSection.editor => LucideIcons.penLine300,
  };
}

/// 遮罩浓度：压暗主界面以聚焦设置，**但不模糊**——
/// 用户要能透过它看到背后内容的实时变化（宽度/字号/主题）。
const double _scrimAlpha = 0.4;

/// 弹出设置面板：悬浮卡片 + 背后半透明遮罩，**非模态路由**。
///
/// 与 showDialog（PopupRoute）的关键差异——本实现是 Overlay：
/// - 背后的主界面**保持渲染且实时响应**设置变化（改宽度/字号/主题
///   当场看到效果），这是"设置页能看到页面内容变化"的实现基础；
/// - 不用路由栈，不影响导航历史。
///
/// 关闭：右上角 ✕ / 点遮罩 / Esc。
Future<void> showSettingsPanel(BuildContext context) {
  // 不用传入的 context 找 Overlay：触发处可能在 MaterialApp 之上
  // （见 appNavigatorKey 的说明），一律走导航根。
  final OverlayState overlay = appNavigatorKey.currentState!.overlay!;
  final Completer<void> closed = Completer<void>();
  OverlayEntry? entry;
  late final bool Function(KeyEvent event) handleEscKey;

  void close() {
    if (!closed.isCompleted) {
      closed.complete();
    }
    if (entry != null && entry!.mounted) {
      entry!.remove();
    }
    entry = null;
    HardwareKeyboard.instance.removeHandler(handleEscKey);
  }

  handleEscKey = (KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      close();
    }
    return false;
  };

  HardwareKeyboard.instance.addHandler(handleEscKey);

  entry = OverlayEntry(
    builder: (BuildContext overlayContext) =>
        _SettingsOverlay(onClose: close),
  );
  overlay.insert(entry!);
  return closed.future;
}

/// 遮罩 + 悬浮卡片（自带进出场动画）。
class _SettingsOverlay extends StatefulWidget {
  const _SettingsOverlay({required this.onClose});

  final VoidCallback onClose;

  @override
  State<_SettingsOverlay> createState() => _SettingsOverlayState();
}

class _SettingsOverlayState extends State<_SettingsOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    duration: const Duration(milliseconds: 220),
    vsync: this,
  )..forward();
  late final Animation<double> _fade = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeOut,
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    return Stack(
      children: <Widget>[
        // 遮罩：点击关闭（点卡片内不触发——卡片在其上层且吸收事件）。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
            child: FadeTransition(
              opacity: _fade,
              child: ColoredBox(
                color: Colors.black.withValues(alpha: _scrimAlpha),
              ),
            ),
          ),
        ),
        // 悬浮卡片：居中，高度不超过窗口 85%。
        Positioned.fill(
          child: Center(
            child: FadeTransition(
              opacity: _fade,
              child: ScaleTransition(
                // 轻微放大入场（0.96 → 1）：高级感的常见手法，
                // 幅度要小，过大会显得"弹窗"而非"页面"。
                scale: Tween<double>(begin: 0.96, end: 1).animate(_fade),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: _panelWidth,
                    maxHeight: screen.height * 0.85,
                  ),
                  child: _SettingsCard(onClose: widget.onClose),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 卡片本体：标题栏 + 可滚动的设置项 + 底部操作。
class _SettingsCard extends ConsumerStatefulWidget {
  const _SettingsCard({required this.onClose});

  final VoidCallback onClose;

  @override
  ConsumerState<_SettingsCard> createState() => _SettingsCardState();
}

class _SettingsCardState extends ConsumerState<_SettingsCard> {
  // thumbVisibility: true 要求显式 controller（桌面端没有可用的
  // PrimaryScrollController，缺失直接断言崩溃）。
  final ScrollController _scroll = ScrollController();
  _SettingsSection _section = _SettingsSection.appearance;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 各分区的设置行。**加功能的入口**（与 [_SettingsSectionSpec] 配套）：
  /// 照抄既有 Row 组件往对应分支里加即可，导航与标题自动生成。
  List<Widget> _rowsFor(_SettingsSection section) => switch (section) {
    _SettingsSection.appearance => <Widget>[
      const _BrightnessRow(),
    ],
    _SettingsSection.editor => <Widget>[
      const _WidthRow(),
      const SizedBox(height: Tokens.spaceLg),
      const _FontSizeRow(),
      const SizedBox(height: Tokens.spaceLg),
      const _LineHeightRow(),
    ],
  };

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    return Material(
      color: AppTheme.windowBackground(scheme.brightness),
      elevation: 12,
      borderRadius: BorderRadius.circular(Tokens.radiusLg),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: _panelHeight,
        child: Column(
          children: <Widget>[
            // 标题栏
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Tokens.spaceLg,
                Tokens.spaceMd,
                Tokens.spaceSm,
                Tokens.spaceMd,
              ),
              child: Row(
                children: <Widget>[
                  Text(
                    '设置',
                    style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(LucideIcons.x300, size: Tokens.iconSm),
                    tooltip: '关闭（Esc）',
                    onPressed: widget.onClose,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // 两栏：左侧目录导航 + 右侧分区内容
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // ── 左：目录导航（Win11 设置的布局语言）──
                  SizedBox(
                    width: 176,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Tokens.spaceSm,
                        vertical: Tokens.spaceMd,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          for (final _SettingsSection section
                              in _SettingsSection.values)
                            _NavTile(
                              section: section,
                              selected: section == _section,
                              onTap: () => setState(() => _section = section),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  // ── 右：分区标题 + 设置行（超高时滚动）──
                  Expanded(
                    child: Scrollbar(
                      controller: _scroll,
                      thumbVisibility: true,
                      child:                       SingleChildScrollView(
                        controller: _scroll,
                        padding: const EdgeInsets.all(Tokens.spaceLg),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              _section.label,
                              style: text.titleLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: Tokens.spaceLg),
                            ..._rowsFor(_section),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // 底部：恢复默认
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Tokens.spaceMd,
                vertical: Tokens.spaceSm,
              ),
              child: Row(
                children: <Widget>[
                  const Spacer(),
                  TextButton(
                    onPressed: () =>
                        ref.read(settingsProvider.notifier).reset(),
                    child: const Text('恢复默认'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 目录导航项：M3 选中态（secondaryContainer 圆角底 + 图标文字同色系）。
class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final _SettingsSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(Tokens.radiusSm),
          onTap: onTap,
          child:           AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(
              horizontal: Tokens.spaceMd,
              vertical: Tokens.spaceSm + 2,
            ),
            decoration: BoxDecoration(
              color: selected ? scheme.secondaryContainer : null,
              borderRadius: BorderRadius.circular(Tokens.radiusSm),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  section.icon,
                  size: Tokens.iconSm,
                  color: selected
                      ? scheme.onSecondaryContainer
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: Tokens.spaceSm),
                Text(
                  section.label,
                  style: text.bodyMedium?.copyWith(
                    color: selected
                        ? scheme.onSecondaryContainer
                        : scheme.onSurface,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 明暗模式：两档 SegmentedButton（浅色 / 深色）。
class _BrightnessRow extends ConsumerWidget {
  const _BrightnessRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings = ref.watch(settingsProvider);
    return _SettingRow(
      label: '明暗',
      control: SegmentedButton<ThemeBrightnessMode>(
        segments: const <ButtonSegment<ThemeBrightnessMode>>[
          ButtonSegment<ThemeBrightnessMode>(
            value: ThemeBrightnessMode.light,
            label: Text('浅色'),
          ),
          ButtonSegment<ThemeBrightnessMode>(
            value: ThemeBrightnessMode.dark,
            label: Text('深色'),
          ),
        ],
        selected: <ThemeBrightnessMode>{settings.brightnessMode},
        showSelectedIcon: false,
        onSelectionChanged: (Set<ThemeBrightnessMode> next) => ref
            .read(settingsProvider.notifier)
            .setBrightnessMode(next.first),
      ),
    );
  }
}

/// 正文宽度：三档（窄 / 标准 / 宽）——背后内容即时响应。
class _WidthRow extends ConsumerWidget {
  const _WidthRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings = ref.watch(settingsProvider);
    return _SettingRow(
      label: '正文宽度',
      control: SegmentedButton<EditorWidthMode>(
        segments: const <ButtonSegment<EditorWidthMode>>[
          ButtonSegment<EditorWidthMode>(
            value: EditorWidthMode.narrow,
            label: Text('窄'),
          ),
          ButtonSegment<EditorWidthMode>(
            value: EditorWidthMode.standard,
            label: Text('标准'),
          ),
          ButtonSegment<EditorWidthMode>(
            value: EditorWidthMode.wide,
            label: Text('宽'),
          ),
        ],
        selected: <EditorWidthMode>{settings.widthMode},
        showSelectedIcon: false,
        onSelectionChanged: (Set<EditorWidthMode> next) =>
            ref.read(settingsProvider.notifier).setWidthMode(next.first),
      ),
    );
  }
}

/// 正文字号：Slider（12 ~ 24，步长 1），实时显示数值。
class _FontSizeRow extends ConsumerWidget {
  const _FontSizeRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings = ref.watch(settingsProvider);
    final TextTheme text = Theme.of(context).textTheme;
    return _SettingRow(
      label: '正文字号',
      control: Row(
        children: <Widget>[
          Expanded(
            child: Slider(
              value: settings.fontSize.clamp(_minFontSize, _maxFontSize),
              min: _minFontSize,
              max: _maxFontSize,
              divisions: ((_maxFontSize - _minFontSize) / _fontSizeStep).round(),
              label: _formatFontSize(settings.fontSize),
              onChanged: (double value) =>
                  ref.read(settingsProvider.notifier).setFontSize(value),
            ),
          ),
          SizedBox(
            width: 32,
            child: Text(
              _formatFontSize(settings.fontSize),
              style: text.bodyMedium,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}

/// 行高（**正文**）：Slider（1.25 ~ 2.5，步长 0.125），实时显示数值。
///
/// 标签带"正文"二字是有意的：**标题行高固定 1.4**，不跟随这个滑杆
/// （汉字标题不需要正文那么散，见 `EditorTypography.headingLineHeight`）。
class _LineHeightRow extends ConsumerWidget {
  const _LineHeightRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings = ref.watch(settingsProvider);
    final TextTheme text = Theme.of(context).textTheme;
    return _SettingRow(
      label: '行高（正文）',
      control: Row(
        children: <Widget>[
          Expanded(
            child: Slider(
              // clamp：范围收窄过（下限 1.4→1.5、步长 0.05→0.125），
              // 存量库里可能存着越界值（如 1.4）——不夹住会让 Slider 断言失败。
              // 越界或不在网格上的旧值照原样渲染，拖动即吸附到最近的档。
              value: settings.lineHeight.clamp(_minLineHeight, _maxLineHeight),
              min: _minLineHeight,
              max: _maxLineHeight,
              // 格数由"范围 / 步长"推出（= 8），不再写一遍数字。
              divisions: ((_maxLineHeight - _minLineHeight) / _lineHeightStep)
                  .round(),
              label: _formatLineHeight(settings.lineHeight),
              onChanged: (double value) =>
                  ref.read(settingsProvider.notifier).setLineHeight(value),
            ),
          ),
          SizedBox(
            // 宽到能放下 "2.375"（步长 0.125 后最长的显示值）。
            width: 48,
            child: Text(
              // 与滑块气泡同源格式化，避免两处显示不一致。
              _formatLineHeight(settings.lineHeight),
              style: text.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// 一行设置项：左标签（定宽对齐）+ 右控件。
class _SettingRow extends StatelessWidget {
  const _SettingRow({required this.label, required this.control});

  final String label;
  final Widget control;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: text.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(child: control),
      ],
    );
  }
}

/// 弹出「关于」对话框：应用名 + 一句话简介。
///
/// 用标准 [AlertDialog]（项目已为其配 [AppTheme] 的 dialogTheme），
/// 走触发处 context 的导航根弹出即可。
Future<void> showAboutPanel(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext ctx) {
      final ColorScheme scheme = Theme.of(ctx).colorScheme;
      return AlertDialog(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(LucideIcons.penLine300, color: scheme.primary),
            const SizedBox(width: 8),
            const Text('sinan'),
          ],
        ),
        content: const SizedBox(
          width: 300,
          child: Text(
            '本地优先的流式写作工具：侧栏管理笔记，主区为沉浸式编辑器。'
            '所有数据存于本机，无云端同步。',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      );
    },
  );
}
