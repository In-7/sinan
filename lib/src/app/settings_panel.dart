import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/settings.dart';
import 'app_info.dart';
import 'providers.dart';
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
  ai,
  about,
}

extension _SettingsSectionSpec on _SettingsSection {
  String get label => switch (this) {
    _SettingsSection.appearance => '外观',
    _SettingsSection.editor => '编辑器',
    _SettingsSection.ai => 'AI',
    _SettingsSection.about => '关于',
  };

  IconData get icon => switch (this) {
    _SettingsSection.appearance => LucideIcons.palette300,
    _SettingsSection.editor => LucideIcons.penLine300,
    _SettingsSection.ai => LucideIcons.sparkles300,
    _SettingsSection.about => LucideIcons.info300,
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
                // 用 M3 的 scrim **色角色**而不是 `Colors.black`：默认值就是黑，
                // 观感不变，但不再是硬编码色（换主题时 scrim 若被定制会跟着走）。
                color: Theme.of(
                  context,
                ).colorScheme.scrim.withValues(alpha: _scrimAlpha),
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
      const _FontSizeRow(),
      const _LineHeightRow(),
    ],
    // AI 分区：画布的结构轨要用本地 LLM（Ollama）。默认**关闭**——
    // 没起服务时露出入口只会让用户点出一个报错，所以让它成为一次显式开启。
    _SettingsSection.ai => <Widget>[
      const _AiEnabledRow(),
      const _AiEndpointRow(),
      const _AiModelRow(),
    ],
    // 「关于」是设置页的固定分区（Win11 / macOS 系统设置都有）：应用信息、
    // 开源许可、数据目录。除了许可页本身，内容都是几行 `ListTile` ——
    // M3 没有专门的"关于"组件，官方口径就是 lists。
    _SettingsSection.about => <Widget>[_AboutSection(onClose: widget.onClose)],
  };

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    return Material(
      // 底色与「关于」对话框**同一档**：M3 的 `surfaceContainerHigh`
      // —— 官方 `Dialog`/`AlertDialog` 未显式设背景时的默认值（见
      // `material/dialog.dart`，M3 defaults 里就是它）。
      //
      // 为什么必须换掉原来的 [AppTheme.windowBackground]（2026-09-18 用户反馈
      // "设置页不如关于页好看"）：那是**窗口最底层**的底色（亮 #F3F3F3 /
      // 暗 #0A0A0A，比纸面还深一档、纯中性无微染），拿它当浮起面板的底 ⇒
      // 面板看着像"贴在窗口上的一块暗板"，既低于关于页一档，也不像浮层。
      // 也不用项目的 [AppTheme.floatSurface]：那一档是给**菜单/气泡**的
      // （比纸面抬一档的纯中性白），而设置面板与对话框同类（模态遮罩上的
      // 内容面板），走 M3 内容表面档才与关于页同一语言。
      color: scheme.surfaceContainerHigh,
      // **刻意不给 elevation**（默认 0，同 `dialogTheme`）：M3 里 elevation 会
      // 再叠一层 surface tint，把上面这个色又染偏；而且遮罩已经承担了"浮起"
      // 的读数 —— 关于页正是这样（无阴影、无 tint）。
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
                  // 左右之间刻意**不画分隔线**（2026-09-18 用户定）：与「关于」
                  // 对话框同一口径 —— M3 的 Dialog 靠留白与底色档差分块，不靠勾线；
                  // 左导航项自带 hover/选中底，已经够分明。
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
      // 选中态**视觉上有、语义上没有**（此前只有 secondaryContainer 底色）：
      // 读屏用户听不出"我在哪一页"。InkWell 自带 button 语义与键盘焦点，
      // 这里只补 selected。
      child: Semantics(
        selected: selected,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(Tokens.radiusSm),
            onTap: onTap,
            child: AnimatedContainer(
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
    return _SettingTile(
      label: '明暗',
      // M3 Lists 的 `subtitle` 正是放"这项影响什么"的地方 —— 这些理由此前只
      // 活在代码注释里，用户看不到。
      description: '只改界面配色（种子色不变），点一下立刻生效。',
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
    return _SettingTile(
      label: '正文宽度',
      description: '三档约 38 / 42 / 55 字每行（中文）。列宽不随窗口变宽 —— '
          '超过 45 字/行阅读会累，最宽档适合写稿。',
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
    return _SliderSetting(
      label: '正文字号',
      description: '${_minFontSize.round()}–${_maxFontSize.round()} px，整数档。'
          '行盒按它吸附到整像素 —— 每一档都是锐利的。',
      valueLabel: _formatFontSize(settings.fontSize),
      valueWidth: 32,
      slider: Slider(
        value: settings.fontSize.clamp(_minFontSize, _maxFontSize),
        min: _minFontSize,
        max: _maxFontSize,
        divisions: ((_maxFontSize - _minFontSize) / _fontSizeStep).round(),
        label: _formatFontSize(settings.fontSize),
        onChanged: (double value) =>
            ref.read(settingsProvider.notifier).setFontSize(value),
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
    return _SliderSetting(
      label: '行高（正文）',
      description: '$_minLineHeight–$_maxLineHeight 倍，步长 0.125 —— 每档都落在'
          '整像素上。标题行高固定 1.4，不跟随这个滑杆。',
      // 宽到能放下 "2.375"（步长 0.125 后最长的显示值）。
      valueLabel: _formatLineHeight(settings.lineHeight),
      valueWidth: 48,
      slider: Slider(
        // clamp：范围收窄过（下限 1.4→1.5、步长 0.05→0.125），
        // 存量库里可能存着越界值（如 1.4）——不夹住会让 Slider 断言失败。
        // 越界或不在网格上的旧值照原样渲染，拖动即吸附到最近的档。
        value: settings.lineHeight.clamp(_minLineHeight, _maxLineHeight),
        min: _minLineHeight,
        max: _maxLineHeight,
        // 格数由"范围 / 步长"推出（= 8），不再写一遍数字。
        divisions: ((_maxLineHeight - _minLineHeight) / _lineHeightStep).round(),
        label: _formatLineHeight(settings.lineHeight),
        onChanged: (double value) =>
            ref.read(settingsProvider.notifier).setLineHeight(value),
      ),
    );
  }
}

/// 一行设置项：**M3 [ListTile]**（标题 + 说明）右侧挂控件。
///
/// 为什么从自制的「88px 定宽标签 + 右控件」换成 `ListTile`：官方设置页的口径
/// 就是 lists —— `title`/`subtitle` 承载"这项是什么、影响什么"，`trailing` 放
/// 控件。换成官方组件顺带白拿 hover 高亮、正确的行距节奏、语义合并与键盘焦点
/// （自制 Row 三者都要自己补）。
class _SettingTile extends StatelessWidget {
  const _SettingTile({
    required this.label,
    required this.description,
    required this.control,
  });

  final String label;

  /// 一句话说明（M3 的 `subtitle`）：把"为什么是这个默认值"从代码注释搬到
  /// 用户眼前。
  final String description;

  final Widget control;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListTile(
      // 左对齐到分区标题（ListTile 默认有 16px 内边距，会把整列推歪）。
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: theme.textTheme.bodyLarge),
      subtitle: Text(
        description,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: control,
    );
  }
}

/// 一行**连续值**设置项：标题/说明在上，滑杆**独占下一行**。
///
/// 滑杆不能塞进 `trailing`：那里可用宽度只剩几十像素，根本拖不准。
/// 官方口径也是这个形态（Android 设置里的"亮度""字体大小"都是上下两行）。
class _SliderSetting extends StatelessWidget {
  const _SliderSetting({
    required this.label,
    required this.description,
    required this.valueLabel,
    required this.valueWidth,
    required this.slider,
  });

  final String label;
  final String description;

  /// 当前值的显示文本（与滑块气泡**同源格式化**，避免两处不一致）。
  final String valueLabel;

  /// 值显示区宽度（按最长可能值给，免得拖动时数字左右跳）。
  final double valueWidth;

  final Widget slider;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: Tokens.spaceMd),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(label, style: theme.textTheme.bodyLarge),
                    const SizedBox(height: 2),
                    Text(
                      description,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Tokens.spaceSm),
              SizedBox(
                width: valueWidth,
                child: Text(
                  valueLabel,
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.end,
                ),
              ),
            ],
          ),
        ),
        slider,
      ],
    );
  }
}

/// 弹出「关于」：走**框架原生** [showAboutDialog]。
///
/// 比手写 `AlertDialog` 多拿到两件自己做不划算的东西：
/// - **版本号有位置**（`applicationVersion`）—— 此前那个对话框没有版本；
/// - **自带「查看许可」入口** → [LicensePage]：它把 `LicenseRegistry` 里全部
///   依赖的许可收集成可搜索列表（要自己做得遍历整棵依赖树）。
///
/// 数据目录、依赖清单的常驻入口在**设置 → 关于**分区（见 [_AboutSection]）。
///
/// ⚠️ 返回 `void`（不是 `Future`）：官方 `showAboutDialog` 本身不回报"对话框
/// 关闭了"，包装成 Future 只会让调用方以为 await 到了关闭 —— 不如如实。
void showAboutPanel(BuildContext context) {
  final ColorScheme scheme = Theme.of(context).colorScheme;
  showAboutDialog(
    context: context,
    applicationName: AppInfo.name,
    applicationVersion: AppInfo.version,
    applicationIcon: Icon(LucideIcons.penLine300, color: scheme.primary),
    applicationLegalese: AppInfo.description,
  );
}

/// 「关于」分区：应用信息 + 开源许可 + 数据目录。
///
/// M3 没有专门的"关于"组件 —— 官方口径就是这里的几行 [ListTile]。
/// 许可页用框架原生的 [LicensePage]。
class _AboutSection extends ConsumerWidget {
  const _AboutSection({required this.onClose});

  /// 关掉设置面板的回调（推许可页之前必须先关，理由见 [_openLicenses]）。
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle? hint = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    // 数据目录由 main 注入（`appDataDirProvider`）；设置面板必在 ProviderScope
    // 之内（Overlay 挂在导航根上），直接读即可。
    final String dataDir = ref.read(appDataDirProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(LucideIcons.penLine300, color: scheme.primary),
          title: const Text('${AppInfo.name} ${AppInfo.version}'),
          subtitle: Text(AppInfo.tagline, style: hint),
          isThreeLine: true,
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            LucideIcons.scrollText300,
            color: scheme.onSurfaceVariant,
          ),
          title: const Text('开源许可'),
          subtitle: Text('第三方依赖的许可清单（由框架自动收集）', style: hint),
          trailing: Icon(
            LucideIcons.chevronRight300,
            size: Tokens.iconSm,
            color: scheme.onSurfaceVariant,
          ),
          onTap: () => _openLicenses(context),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            LucideIcons.folderOpen300,
            color: scheme.onSurfaceVariant,
          ),
          title: const Text('数据目录'),
          // 可选中：路径以 AppData 开头、肉眼抄不下。
          subtitle: SelectableText(dataDir, style: hint),
          trailing: IconButton(
            icon: const Icon(LucideIcons.copy300, size: Tokens.iconSm),
            tooltip: '复制路径',
            onPressed: () => _copyDataDir(context, dataDir),
          ),
        ),
      ],
    );
  }

  /// 打开许可页。
  ///
  /// ⚠️ **必须先关设置面板再推路由**：设置面板是一个插在 Navigator Overlay
  /// **顶层**的 `OverlayEntry`，而许可页是**路由** —— 不关的话它会被面板压在
  /// 下面（现象：点了没反应，其实是被盖住了）。
  /// 同时要在关闭**之前**取好 `NavigatorState`：`onClose()` 之后本 widget 的
  /// context 已经失效，那时再 `Navigator.of(context)` 会抛。
  void _openLicenses(BuildContext context) {
    final NavigatorState navigator = Navigator.of(context);
    final Widget page = LicensePage(
      applicationName: AppInfo.name,
      applicationVersion: AppInfo.version,
      applicationIcon: Icon(
        LucideIcons.penLine300,
        color: Theme.of(context).colorScheme.primary,
      ),
    );
    onClose();
    unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => page)));
  }

  static Future<void> _copyDataDir(BuildContext context, String path) async {
    await Clipboard.setData(ClipboardData(text: path));
    if (!context.mounted) return;
    // MaterialApp 在 Navigator **之上**提供了根 ScaffoldMessenger，
    // 所以从浮层里也能弹 SnackBar。
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('已复制数据目录路径')));
  }
}

// ───────────────────────────── AI 分区 ─────────────────────────────

/// 是否露出画布上的一句话 AI 入口。
class _AiEnabledRow extends ConsumerWidget {
  const _AiEnabledRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings = ref.watch(settingsProvider);
    return _SettingTile(
      label: '启用画布 AI',
      description: '在画布工具条上露出「AI」按钮：用一句中文指令让模型摆放卡片、'
          '连线、加形状。需要本机运行 Ollama。',
      control: Switch(
        value: settings.aiEnabled,
        onChanged: (bool value) =>
            ref.read(settingsProvider.notifier).setAiEnabled(value),
      ),
    );
  }
}

/// 模型服务地址（Ollama 的根地址）。
class _AiEndpointRow extends ConsumerWidget {
  const _AiEndpointRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings = ref.watch(settingsProvider);
    return _TextSettingRow(
      label: '服务地址',
      description: 'Ollama 的**根**地址，不带 /v1 或 /api —— '
          '结构化输出要用 /api/chat 的 format 参数。',
      value: settings.aiEndpoint,
      hint: AppSettings.defaultAiEndpoint,
      onCommit: (String value) =>
          ref.read(settingsProvider.notifier).setAiEndpoint(value),
    );
  }
}

/// 模型名（Ollama tag）。
class _AiModelRow extends ConsumerWidget {
  const _AiModelRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings = ref.watch(settingsProvider);
    return _TextSettingRow(
      label: '模型',
      description: 'Ollama 里的模型 tag（`ollama list` 可查），如 qwen3.5。'
          '留空则点 AI 按钮时会提示先来这里填写。',
      value: settings.aiModel,
      hint: 'qwen3.5',
      onCommit: (String value) =>
          ref.read(settingsProvider.notifier).setAiModel(value),
    );
  }
}

/// 一行**文本输入**设置项：本地维护草稿，**提交时才落盘**。
///
/// ## 为什么不是 onChanged 直接写
/// ① 每敲一个字都会写一次 SQLite，并让 `llmClientProvider`（watch 设置）重建
/// 客户端；② 端点写一半（`http://local`）就被拿去建客户端。
/// 提交时机取"回车 / 失焦"两个，与系统设置页一致。
class _TextSettingRow extends ConsumerStatefulWidget {
  const _TextSettingRow({
    required this.label,
    required this.description,
    required this.value,
    required this.hint,
    required this.onCommit,
  });

  final String label;
  final String description;
  final String value;
  final String hint;
  final void Function(String value) onCommit;

  @override
  ConsumerState<_TextSettingRow> createState() => _TextSettingRowState();
}

class _TextSettingRowState extends ConsumerState<_TextSettingRow> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value,
  );
  late final FocusNode _focus = FocusNode()..addListener(_onFocusChange);

  @override
  void didUpdateWidget(_TextSettingRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部值变了（另一处改了设置 / 点了恢复默认）⇒ 同步草稿。
    // ⚠️ 正在输入时**不**同步：那会把用户打到一半的字覆盖掉。
    if (!_focus.hasFocus && widget.value != _controller.text) {
      _controller.text = widget.value;
    }
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) _commit();
  }

  void _commit() {
    final String next = _controller.text.trim();
    if (next == widget.value) return;
    widget.onCommit(next);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _SettingTile(
      label: widget.label,
      description: widget.description,
      control: SizedBox(
        width: 240,
        child: TextField(
          controller: _controller,
          focusNode: _focus,
          decoration: InputDecoration(
            hintText: widget.hint,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (_) => _commit(),
        ),
      ),
    );
  }
}
