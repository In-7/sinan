import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../canvas/canvas_switch.dart';
import '../domain/note.dart';
import '../editor/core/editor_switch.dart';
import '../notes/note_list_view.dart';
import 'providers.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../window/app_title_bar.dart';
import '../window/window_service.dart';
import 'settings_panel.dart';

import '../domain/settings.dart';

/// 右上角「菜单」下拉项的枚举（设置 / 关于 / 明暗切换 / 退出）。
enum _AppMenuItem { settings, about, toggleBrightness, exit }

/// 当前明暗模式的短标签，挂在「明暗切换」菜单项右侧做状态提示。
String _brightnessLabel(ThemeBrightnessMode m) => switch (m) {
      ThemeBrightnessMode.light => '浅色',
      ThemeBrightnessMode.dark => '深色',
    };

/// 明暗互切：浅 ↔ 深（不再有「跟随系统」第三态）。
ThemeBrightnessMode _nextBrightness(ThemeBrightnessMode cur) =>
    switch (cur) {
      ThemeBrightnessMode.light => ThemeBrightnessMode.dark,
      ThemeBrightnessMode.dark => ThemeBrightnessMode.light,
    };

/// 主界面（兼桌面窗口外壳）。
///
/// 桌面端为**左右分栏**布局（原生标题栏已隐藏）：
///
/// ```
/// ┌── 侧栏（通高列）─────┬──── 主区 ──────────────┐
/// │ [+] [🔍] [⚙]  sinan   │  拖拽区         [─][□][×] │
/// │ ┌──────────────────┐  ├────────────────────────┤
/// │ │ 笔记列表           │  │       编辑区            │
/// ```
///
/// - 侧栏头部（[SidebarHeader]）：功能按钮归属侧栏本体 + 拖拽移动窗口；
/// - 主区顶条（[WindowStrip]）：拖拽移动 + 双击最大化 + 窗控按钮。
///
/// 宽屏（>=720）：双栏；窄屏：列表 / 编辑器二选一，由
/// [selectedNoteIdProvider] 驱动（窗口最小宽度即 720，此分支为防御）。
/// 移动端：标准 [AppBar]。两份布局共用同一个 `selectedNoteId` 状态。
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  static const double _wideBreakpoint = 720;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? selectedId = ref.watch(selectedNoteIdProvider);
    final bool isWide =
        MediaQuery.of(context).size.width >= _wideBreakpoint;

    final Widget listPane = NoteListView(
      selectedId: selectedId,
      onPick: (id) => ref.read(selectedNoteIdProvider.notifier).select(id),
    );

    // 切换笔记/页面时淡入淡出，避免内容瞬跳。
    // M3 动效规范：过渡使用 emphasized easing（先快后缓收尾）。
    Widget withFade(Widget child) => AnimatedSwitcher(
          duration: Tokens.durationNormal,
          switchInCurve: Curves.easeInOutCubicEmphasized,
          switchOutCurve: Curves.easeInOutCubicEmphasized.flipped,
          child: child,
        );

    // 主区内容：空态 ↔ 笔记视图。笔记视图**按形态二选一**——画布笔记 →
    // 画布，其余（spark/note）→ 块编辑器。两者共用同一个内容面板，即
    // "在同一个页面里切换"：点列表里的文档笔记出编辑器，点画布笔记出画布。
    //
    // key 随笔记 id 变化强制重建视图 State，否则会残留上一篇的内容、防抖把
    // 旧内容写进新笔记 id 数据串台；外层 KeyedSubtree key 恒定——笔记↔笔记
    // 切换不触发淡入淡出。
    //
    // ⚠️ 取不到笔记（列表尚未装载 / 极短竞争窗口）时按"文档"处理，
    // 保持既有行为，不会闪空态。
    final bool isCanvas =
        _noteById(ref.watch(notesProvider).value, selectedId)?.kind ==
            NoteKind.canvas;
    Widget detailPane() => withFade(
          selectedId == null
              ? const _EmptyDetail(key: ValueKey<String>('empty'))
              : KeyedSubtree(
                  key: const ValueKey<String>('editor-pane'),
                  child: isCanvas
                      ? buildNoteCanvasView(
                          key: ValueKey<String>(selectedId),
                          noteId: selectedId,
                        )
                      : buildNoteEditorView(
                          key: ValueKey<String>(selectedId),
                          noteId: selectedId,
                        ),
                ),
        );

    if (WindowService.isSupported) {
      final List<Widget> sidebarActions = _sidebarActions(context, ref);
      // 标题栏里的菜单图标尺寸对齐窗控，且点击区/悬停与窗控完全一致。
      final Widget menu = _menuButton(
        context,
        ref,
        iconSize: 20,
        captionStyle: true,
      );

      if (isWide) {
        return Scaffold(
          // 窗口底 = 系统 Mica 材质本身，Flutter 不再铺任何蒙版。
          // 与 Win11 系统应用同构：Mica 自身亮度即背景色
          // （浅 ≈#F3F3F3 / 深 ≈#202020），可直接承载列表文字；
          // 只有内容层（编辑区白卡）才是不透明的。
          backgroundColor: Colors.transparent,
          body: Row(
            children: <Widget>[
              // 侧栏：通高列——头部（按钮 + 应用名 + 拖拽）+ 列表。
              SizedBox(
                width: 300,
                child: Column(
                  children: <Widget>[
                    SidebarHeader(title: 'sinan', actions: sidebarActions),
                    Expanded(child: listPane),
                  ],
                ),
              ),
              // 左右之间**不画线**（2026-09-18 用户定）：分界改由底色档差表达
              // ——左栏是系统 Mica（透出窗口底），右栏是铺满的纸面色，两者本就
              // 不同档。
              //
              // 这里原是**一条独立 1px 竖线**。若将来要加回来，注意不能用
              // "右栏 DecoratedBox 的 border"：border 画在子层之下，编辑器工具栏
              // /正文铺的不透明画布色会把它盖出断口（旧 `_ContentPanel` 踩过），
              // 当年的独立盒子正是为了谁也盖不住。
              // 右栏：整列铺编辑器画布底，与左栏 Mica 形成硬分区。
              // 顶条与内容面板都透出这层底色。
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppTheme.contentCanvas(Theme.of(context).brightness),
                  ),
                  child: Column(
                    children: <Widget>[
                      WindowStrip(trailing: <Widget>[menu]),
                      // 顶条与内容之间的分隔线（2026-09-14 用户定案）：
                      // 右列因此分成"标题带（拖拽 + 窗控）"与"内容"两段，
                      // 与左侧竖分界线用同一个语义令牌（[AppTheme.divider]）。
                      //
                      // ⚠️ 必须是**独立 1px 盒子**，两个理由：
                      // 1. 画成 border 会被铺底的子层盖住出断口——同左侧竖线；
                      // 2. 更不能加在 [WindowStrip] 自己的 border 上：那 1px 会
                      //    从 32px 的条里向内扣，而窗控按钮有 32 的 minHeight，
                      //    会被顶出容器（见 [Tokens.titleBarHeight]）。
                      Container(
                        height: 1,
                        color: AppTheme.divider(Theme.of(context).colorScheme),
                      ),
                      Expanded(
                        child: _ContentPanel(
                          partition: true,
                          child: detailPane(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      }

      // 窄桌面兜底（最小窗宽即 720，正常不可达）：整宽一条
      // （动作 + 应用名 + 拖拽 + 窗控）+ 列表/编辑二选一。
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Column(
          children: <Widget>[
            WindowStrip(
              leading: sidebarActions,
              trailing: <Widget>[menu],
              title: 'sinan',
            ),
            Expanded(
              child: withFade(
                selectedId == null
                    ? KeyedSubtree(
                        key: const ValueKey<String>('list'),
                        child: listPane,
                      )
                    : _ContentPanel(child: detailPane()),
              ),
            ),
          ],
        ),
      );
    }

    // 移动端：标准 AppBar。
    return Scaffold(
      appBar: AppBar(
        title: const Text('sinan'),
        actions: _chromeActions(context, ref),
      ),
      body: withFade(
        selectedId == null
            ? KeyedSubtree(
                key: const ValueKey<String>('list'),
                child: listPane,
              )
            : _ContentPanel(child: detailPane()),
      ),
    );
  }

  /// 从笔记列表里按 id 找笔记（用于判定形态：画布 / 文档）。
  static Note? _noteById(List<Note>? notes, String? id) {
    if (notes == null || id == null) return null;
    for (final Note n in notes) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// 侧栏头部 / 窄屏顶条左侧动作区：新建 + 搜索（不含主菜单——
  /// 主菜单在 [WindowStrip] 里紧贴「最小化」左侧成组）。
  List<Widget> _sidebarActions(BuildContext context, WidgetRef ref) =>
      <Widget>[
        IconButton(
          icon: const Icon(LucideIcons.plus300),
          tooltip: '新建笔记',
          onPressed: () async {
            final Note n = await ref.read(notesProvider.notifier).createNote();
            ref.read(selectedNoteIdProvider.notifier).select(n.id);
          },
        ),
        IconButton(
          icon: const Icon(LucideIcons.search300),
          tooltip: '搜索（开发中）',
          onPressed: () {},
        ),
        // 新建画布笔记（[NoteKind.canvas]）：建好即选中，右栏直接出画布。
        // 不再是"全屏路由的实验页"——画布已与块编辑器同页共存。
        IconButton(
          icon: const Icon(LucideIcons.frame300),
          tooltip: '新建画布',
          onPressed: () async {
            final Note n = await ref
                .read(notesProvider.notifier)
                .createNote(kind: NoteKind.canvas);
            ref.read(selectedNoteIdProvider.notifier).select(n.id);
          },
        ),
      ];

  /// 复刻 window_manager 的 [WindowCaptionButton]（最小化/最大化这类非关闭
  /// 按钮）外观：46×32、直角、中性色悬停/按下、无水波纹。供标题栏菜单按钮
  /// 对齐窗控（关闭按钮是红色，菜单不套红色）。
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
      shape: WidgetStateProperty.all(
        const RoundedRectangleBorder(),
      ),
      backgroundColor: WidgetStateProperty.resolveWith(
        (Set<WidgetState> states) {
          if (states.contains(WidgetState.pressed)) return pressed;
          if (states.contains(WidgetState.hovered)) return hover;
          return Colors.transparent;
        },
      ),
      // 窗控按钮没有水波纹，用透明 overlay 抑制 IconButton 默认 ripple。
      overlayColor: WidgetStateProperty.all(Colors.transparent),
    );
  }

  /// 主菜单下拉（设置 / 关于 / 明暗切换 / 退出）。单独抽出，便于挂到
  /// [WindowStrip] 的 [WindowStrip.trailing]，紧贴最小化按钮左侧。
  ///
  /// [iconSize]：标题栏里要与窗控图标对齐时传 16~18；移动端 AppBar 无窗控
  /// 按钮，走默认 24。
  /// [captionStyle]：true 时让按钮的点击区/悬停与窗控（46×32 直角、中性色
  /// 悬停）完全一致；移动端保持默认 AppBar 样式。
  Widget _menuButton(
    BuildContext context,
    WidgetRef ref, {
    double iconSize = 24,
    bool captionStyle = false,
  }) {
    // 窗控外观仅标题栏需要；移动端 AppBar 保持默认样式。
    final ButtonStyle? style = captionStyle ? _captionButtonStyle(context) : null;
    return PopupMenuButton<_AppMenuItem>(
      tooltip: '菜单',
      position: PopupMenuPosition.under,
      // ⚠️ 这个 0 是**功能性**的，不是省事——别"顺手清理"掉：
      // `PopupMenuPosition.under` 对"用 `icon`（而不是 `child`）"的按钮会自动
      // 上移 `padding.vertical / 2`（官方注释原文："Remove the padding of the
      // icon button"），默认 padding 各 8 ⇒ 菜单顶边落进**按钮内部**、压住按钮
      // 下沿 8px（用户实测："列表遮住按钮"）。置零即让那项补偿为 0。
      // 视觉无变化：[_captionButtonStyle] 的 46×32 已把盒子定死、图标照旧居中，
      // 而那个 style 里的 padding 本来就是 0；移动端（style=null）盒子由全局
      // `iconButtonTheme` 的 40×40 兜住，同样不影响观感。
      padding: EdgeInsets.zero,
      // 再补 4px 呼吸：菜单顶边落在顶条下沿（那条 1px 分隔线）之下一点，
      // 既不压按钮、也不贴线。
      offset: const Offset(0, Tokens.spaceXs),
      style: style,
      icon: Transform.translate(
          // chevron-down 的视觉重心偏下（V 尖端在下），与对称的窗控图标
          // 并列时看着偏低。向上平移 1px 补偿后视觉居中。
          offset: const Offset(0, 0),
          child: Icon(LucideIcons.chevronDown300, size: iconSize),
        ),
        itemBuilder: (BuildContext ctx) {
          final ThemeBrightnessMode mode =
              ref.read(settingsProvider).brightnessMode;
          Widget row(IconData icon, String label, [String? trailing]) => Row(
                children: <Widget>[
                  Icon(icon, size: 20),
                  const SizedBox(width: 12),
                  Text(label),
                  if (trailing != null) ...<Widget>[
                    const Spacer(),
                    Text(
                      trailing,
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                  ],
                ],
              );
          return <PopupMenuEntry<_AppMenuItem>>[
            PopupMenuItem<_AppMenuItem>(
              value: _AppMenuItem.settings,
              child: row(LucideIcons.settings300, '设置'),
            ),
            PopupMenuItem<_AppMenuItem>(
              value: _AppMenuItem.about,
              child: row(LucideIcons.info300, '关于'),
            ),
            PopupMenuItem<_AppMenuItem>(
              value: _AppMenuItem.toggleBrightness,
              // 图标表示「点此切换到的目标态」：浅色时点下去进深色 → 月亮；
              // 深色时 → 太阳。右侧文字仍是当前态提示，二者互补更直觉。
              child: row(
                mode == ThemeBrightnessMode.light
                    ? LucideIcons.moon300
                    : LucideIcons.sun300,
                '明暗切换',
                _brightnessLabel(mode),
              ),
            ),
            PopupMenuItem<_AppMenuItem>(
              value: _AppMenuItem.exit,
              child: row(LucideIcons.logOut300, '退出'),
            ),
          ];
        },
        onSelected: (item) async {
          switch (item) {
            case _AppMenuItem.settings:
              unawaited(showSettingsPanel(context));
            case _AppMenuItem.about:
              showAboutPanel(context);
            case _AppMenuItem.toggleBrightness:
              final ThemeBrightnessMode cur =
                  ref.read(settingsProvider).brightnessMode;
              ref
                  .read(settingsProvider.notifier)
                  .setBrightnessMode(_nextBrightness(cur));
            case _AppMenuItem.exit:
              await WindowService.close();
          }
        },
      );
  }

  /// 移动端 AppBar 动作：新建 + 搜索 + 主菜单。
  List<Widget> _chromeActions(BuildContext context, WidgetRef ref) =>
      <Widget>[..._sidebarActions(context, ref), _menuButton(context, ref)];
}

/// 内容分区面板：画布色 + 偏淡的细边框（对比阴影更克制）。
///
/// 边线用 outlineVariant 半透明——亮色下是极浅的灰勾边，深色下
/// 自然更亮一档；1px 描边 + 圆角，内层 ClipRRect 负责裁内容。
class _ContentPanel extends StatelessWidget {
  const _ContentPanel({required this.child, this.partition = false});

  final Widget child;

  /// 是否为宽屏左右分区模式。
  ///
  /// `true` 时：与左侧 Mica 侧栏做硬分隔——直角、只保留左边线、
  /// 顶边不画线（[WindowStrip] 与内容之间的那道 1px 分隔线由 `HomeScreen`
  /// 统一画在顶条下方，见那里的说明）。
  /// `false` 时：保持原来的卡片式圆角（左上/左下），用于窄屏/移动端。
  final bool partition;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    // 宽屏左右分区：右栏整体由外层 [DecoratedBox] 统一铺底色 + 左侧边线，
    // 这里只负责把内容撑满，不再自己画线，避免顶部出现断口。
    if (partition) {
      return SizedBox.expand(child: child);
    }

    // 窄屏/移动端：卡片式面板，右/下与窗口边缘打通（直接顶到
    // 窗口右下角，视觉上是一整块工作区）。
    //
    // 圆角只留左侧两个（左上/左下），右侧两个收直：
    // - 右上：紧贴窗口顶边与窗控按钮区，直角让顶边连贯；
    // - 右下：交给窗口自己的原生圆角去裁。面板若自留圆角，会在窗口圆角
    //   **内侧**多出一块深色空三角（实测观感："右下角有点空"）。
    const BorderRadius radius = BorderRadius.only(
      topLeft: Radius.circular(Tokens.radiusMd),
      bottomLeft: Radius.circular(Tokens.radiusMd),
    );
    // 内层裁切比外框小 1px：描边占掉的那一圈不该被内容压住。
    const BorderRadius innerRadius = BorderRadius.only(
      topLeft: Radius.circular(Tokens.radiusMd - 1),
      bottomLeft: Radius.circular(Tokens.radiusMd - 1),
    );
    // 描边只留左/上：右、下已与窗口边缘打通，窗口边框本身就是界线，
    // 再画一道会成双线。
    final Border border = Border(
      left: BorderSide(color: AppTheme.divider(scheme)),
      top: BorderSide(color: AppTheme.divider(scheme)),
    );

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // 底色 + 形状（**不画描边**——描边在上一层，见下）。
        DecoratedBox(
          decoration: BoxDecoration(
            color: AppTheme.contentCanvas(theme.brightness),
            borderRadius: radius,
          ),
          child: ClipRRect(borderRadius: innerRadius, child: child),
        ),
        // ⚠️ 描边**必须画在子层之上**：`DecoratedBox` 的边框画在子层之下，
        // 而编辑器顶部工具栏铺的是**不透明**的画布色（与面板同色）⇒ 边框被
        // 整条盖掉：顶边直接消失，左上圆角只剩裁切区外那 1px 的月牙，
        // 看着就像"圆角没加"。
        //
        // 这一层用**与外框同一个** `borderRadius`（不是内缩的那套）：圆角弧线
        // 与底色严丝合缝、和顶边/左边连成一条；`IgnorePointer` 保证它不抢
        // 正文的点击与悬停（它只是一圈线）。
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(border: border, borderRadius: radius),
          ),
        ),
      ],
    );
  }
}

class _EmptyDetail extends StatelessWidget {
  const _EmptyDetail({super.key});

  @override
  Widget build(BuildContext context) => const Center(
        child: Text('选择左侧笔记，或新建一条'),
      );
}
