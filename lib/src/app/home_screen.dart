import 'dart:async';

import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../canvas/canvas_switch.dart';
import 'app_menu.dart';
import '../command/commands.dart';
import '../domain/note.dart';
import 'home_hub.dart';
import 'hub_nav.dart';
import '../editor/core/editor_switch.dart';
import '../notes/note_list_view.dart';
import 'ask_panel.dart';
import 'providers.dart';
import 'search_section.dart';
import 'favorites_section.dart';
import '../theme/app_theme.dart';
import '../theme/noise_texture.dart';
import '../theme/tokens.dart';
import '../window/app_title_bar.dart';
import '../window/window_service.dart';

import '../domain/settings.dart';

/// 主界面（兼桌面窗口外壳）�?
///
/// 桌面端为**导航�?+ 主区**布局（原生标题栏已隐藏）�?
///
/// ```
/// ┌── 导航板（[HubNav]）──┬──── 主区 ──────────────�?
/// �?[⚙] [🔍] [🏠]         �? 拖拽�?        [─][□][×] �?
/// �?┌──────────────────�? ├────────────────────────�?
/// �?�?笔记 / 画布 列表    �? �? 主页（[HomeHub]�? 编辑�? �?
/// ```
///
/// 左栏恒为 [HubNav]（顶行图�?+ 空间切换�?+ 内联列表）；右栏�?
/// [selectedNoteIdProvider] 在主页与编辑器之间切换——点导航列表直接在右栏打开�?
/// 不进新路由、不重建左侧列表�?
///
/// - 导航板（[HubNav]）：列表项的重命�?收藏/删除入口�?
/// - 主区顶条（[WindowStrip]）：拖拽移动 + 双击最大化 + 窗控按钮（编辑态额外带
///   「主页」返回）�?
///
/// 移动端：标准 [AppBar] + 列表 / 编辑器二选一（由 [selectedNoteIdProvider]
/// 驱动，[NoteListView] 兜底）。桌面最小窗宽即 720，故不分宽窄两版�?
/// 左栏 [HubNav] 的板宽，�?`HubNav.width` 默认值保持一致（275）�?
/// 折叠动画的「展开宽度」就取它，避�?ClipRect 裁切错位�?
const double _navWidth = 275;

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? selectedId = ref.watch(selectedNoteIdProvider);

    // �?§5.6 阶段 2�?*未选中 = 主页**（全窗口 Mica + 卡片入口分区）；选中 = 笔记 /
    // 画布页。同一�?`selectedNoteIdProvider` 驱动，不新增页面栈——切换，不是叠加�?
    //
    // 2026-09-25 统一桌面布局：左恒为 [HubNav]，右栏随 `selectedId` 在主�?/ 编辑�?
    // 之间切换—�?*不进新路�?*、不重建左侧列表（旧�?[NoteListView] 侧栏已删，点
    // 导航列表直接在右栏打开文档）。具体分支见下方 `WindowService.isSupported`�?

    final Widget listPane = NoteListView(
      selectedId: selectedId,
      // 不带 focus：从列表点开一篇时若把焦点抢进编辑器，键盘上下选笔记就断了�?
      onPick: (id) => ref.read(locateProvider.notifier).locate(noteId: id),
    );

    // 切换笔记/页面时淡入淡出，避免内容瞬跳�?
    // M3 动效规范：过渡使�?emphasized easing（先快后缓收尾）�?
    Widget withFade(Widget child) => AnimatedSwitcher(
      duration: Tokens.durationNormal,
      switchInCurve: Curves.easeInOutCubicEmphasized,
      switchOutCurve: Curves.easeInOutCubicEmphasized.flipped,
      child: child,
    );

    // 主区内容：空�?�?笔记视图。笔记视�?*按形态二选一**——画布笔�?�?
    // 画布，其余（spark/note）→ 块编辑器。两者共用同一个内容面板，�?
    // "在同一个页面里切换"：点列表里的文档笔记出编辑器，点画布笔记出画布�?
    //
    // key 随笔�?id 变化强制重建视图 State，否则会残留上一篇的内容、防抖把
    // 旧内容写进新笔记 id 数据串台；外�?KeyedSubtree key 恒定——笔记↔笔记
    // 切换不触发淡入淡出�?
    //
    // ⚠️ 取不到笔记（列表尚未装载 / 极短竞争窗口）时�?文档"处理�""?
    // 保持既有行为，不会闪空态�?
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
      // 桌面统一布局�?026-09-25）：左恒�?[HubNav]，右栏随 `selectedId` 切换—�?
      // 主页（[HomeHub]�? 笔记·画布编辑器。点导航列表直接在右栏打开，不进新路由�?
      // 也不重建左侧列表（旧�?[NoteListView] 侧栏已删，那个分支看着�?跳新页面"）�""?
      //
      // 窗口�?*不在这里�?*：它�?`main.dart` �?`MaterialApp.builder` 统一铺一�?
      // 纯色（`AppTheme.windowBackground`）⇒ 这里保持透明让它透出来�?
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Row(
          crossAxisAlignment: .stretch,
          children: <Widget>[
            // 左侧 [HubNav]：折叠态（`navCollapsedProvider`）下宽度动画收为 0，整�?
            // 只剩主区；展开时动画回 275。用 [AnimatedContainer] 做布局级宽度插值，
            // [ClipRect] 裁掉过渡期溢出的内容——纯 layout 动画，不触发 saveLayer
            // （符�?Impeller 性能规范）。右�?Expanded 随之自动补满�?
            // 折叠 / 展开由主区顶条的 [NavCollapseButton] 控制�?
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              width: ref.watch(navCollapsedProvider) ? 0 : _navWidth,
              // 折叠动画期间容器宽度会小于板宽，若直接约束子节点，[HubNav] 内部
              // �?Row（图�?+ 标题 + 时间 + 「···」）会因空间不足而溢出报 layout
              // 错误。用 [OverflowBox] �?[HubNav] 始终按完整板宽（[_navWidth]）布局�?
              // 再由外层 [ClipRect] 裁掉可见区以外的部分——既平滑又不再溢出�?
              child: const ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  maxWidth: _navWidth,
                  child: HubNav(),
                ),
              ),
            ),
            // 右栏：选中态时整列铺编辑器画布底，与左�?Mica 形成硬分区；顶条�?
            // 内容面板都透出这层底色。主页时底色仍是同一窗口底（[HomeHub] 直接�?
            // 窗口底），不铺纸面�?
            Expanded(
              child: selectedId == null
                  ? Column(
                      children: <Widget>[
                        // 主页顶条只剩窗控：设置走导航板顶行，退出即关窗�?
                        // 左起第一枚是折叠面板按钮（展开态也要能再折叠）�?
                        const WindowStrip(
                          leading: <Widget>[NavCollapseButton()],
                        ),
                        Expanded(
                          child: Padding(
                            // 右侧 0�?026-09-26 用户定）：主区滚�?viewport 必须
                            // 触到窗口右缘，滚动条才永远贴边；内容自身的呼�?
                            // （HomeHub / 搜索 / 收藏各有�?padding）不受影响�?
                            // �?6 = 与导航板的间隙；�?6 = 与窗控条的间隙�?
                            padding: const EdgeInsets.fromLTRB(6, 6, 0, 6),
                            child: Consumer(
                              builder:
                                  (
                                    BuildContext context,
                                    WidgetRef ref,
                                    Widget? _,
                                  ) {
                                    final int section = ref.watch(
                                      hubNavSelectionProvider,
                                    );
                                    if (section == 0) return const HomeHub();
                                    if (section == kSearchNavIndex) {
                                      return const SearchSection();
                                    }
                                    if (section == kFavoritesNavIndex) {
                                      return const FavoritesSection();
                                    }
                                    return _SectionPlaceholder(
                                      label: hubNavItems[section].label,
                                    );
                                  },
                            ),
                          ),
                        ),
                      ],
                    )
                  : DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppTheme.contentCanvas(
                          Theme.of(context).brightness,
                        ),
                      ),
                      child: Stack(
                        fit: .expand,
                        children: <Widget>[
                          // 纸面噪点（暗 2% / �?0）：铺在**纸色之上、内容之�?*�?
                          _PaperNoise(brightness: Theme.of(context).brightness),
                          Column(
                            children: <Widget>[
                              WindowStrip(
                                // 左起：上一步（回主页）+ 折叠面板按钮�?026-09-25 曾把
                                // 上一步挪到右侧、折叠按钮占其左侧空位；用户随后要求上一�?
                                // 仍回左侧，故两者同列左侧（上一步最左、折叠按钮次之）�?
                                leading: <Widget>[
                                  const NavCollapseButton(),
                                  IconButton(
                                    icon: const tabler.ArrowLeft(
                                      height: Tokens.iconMd,
                                      width: Tokens.iconMd,
                                      strokeWidth: 1.5,
                                    ),
                                    tooltip: '上一页',
                                    onPressed: () => ref
                                        .read(locateProvider.notifier)
                                        .goHome(),
                                  ),
                                ],
                              ),
                              // 顶条与内容之间的分隔线（2026-09-14 用户定案）：
                              // 右列因此分成"标题带（拖拽 + 窗控�"?�?内容"两段�"?
                              //
                              // ⚠️ 必须�?*独立 1px 盒子**（见旧实现的两条理由�?
                              // border 会被铺底子层盖出断口；加�?[WindowStrip] 自己
                              // �?border 上会�?32 高窗控按钮顶出容器）�?
                              Container(
                                height: 1,
                                color: AppTheme.divider(
                                  Theme.of(context).colorScheme,
                                ),
                              ),
                              Expanded(
                                child: _ContentPanel(
                                  partition: true,
                                  child: detailPane(),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      );
    }

    // 移动端：标准 AppBar�?
    return Scaffold(
      appBar: AppBar(
        title: const Text('sinan'),
        actions: _chromeActions(context, ref),
      ),
      body: withFade(
        selectedId == null
            ? KeyedSubtree(key: const ValueKey<String>('list'), child: listPane)
            : _ContentPanel(child: detailPane()),
      ),
    );
  }

  /// 从笔记列表里�?id 找笔记（用于判定形态：画布 / 文档）�?
  static Note? _noteById(List<Note>? notes, String? id) {
    if (notes == null || id == null) return null;
    for (final Note n in notes) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// 侧栏头部 / 窄屏顶条左侧动作区：新建 + 搜索（不含主菜单—�?
  /// 主菜单在 [WindowStrip] 里紧贴「最小化」左侧成组）�?
  List<Widget> _sidebarActions(BuildContext context, WidgetRef ref) => <Widget>[
    // 走命令层而不是就地调 notifier：按钮与 `Ctrl+N` 必须�?*同一条路**
    // （�?.2 命令是权威面）——各留一份实现迟早漂移成"按钮能建、快捷键不能"�?
    IconButton(
      icon: const tabler.Plus(
        height: Tokens.iconMd,
        width: Tokens.iconMd,
        strokeWidth: 1.5,
      ),
      tooltip: '新建笔记',
      onPressed: () => unawaited(runCommandById(ref, 'note.new')),
    ),
    IconButton(
      icon: const tabler.Search(
        height: Tokens.iconMd,
        width: Tokens.iconMd,
        strokeWidth: 1.5,
      ),
      tooltip: '搜索（开发中）',
      onPressed: () {},
    ),
    // 问笔记（AI 问答）：**没配就不露出入口**——点了只会得到一句报错，
    // 与「设�?�?AI」默认关闭是同一口径（见 AppSettings.aiEnabled 的说明）�?
    if (_aiReady(ref))
      const IconButton(
        icon: tabler.Sparkles(
          height: Tokens.iconMd,
          width: Tokens.iconMd,
          strokeWidth: 1.5,
        ),
        tooltip: '问笔记',
        onPressed: showAskPanel,
      ),
    // 新建画布笔记（[NoteKind.canvas]）：建好即选中，右栏直接出画布�?
    // 不再�?全屏路由的实验页"——画布已与块编辑器同页共存�""?
    IconButton(
      icon: const tabler.Crop(
        height: Tokens.iconMd,
        width: Tokens.iconMd,
        strokeWidth: 1.5,
      ),
      tooltip: '新建画布',
      onPressed: () => unawaited(runCommandById(ref, 'canvas.new')),
    ),
  ];

  /// 「问笔记」入口是否可用：AI 开关打开 **�?* 对话模型名已填�?
  ///
  /// 嵌入模型**�?*作为门槛：没填它只是退化成纯关键词检索（6.4 的降级）�?
  /// 问答照样可用�?
  bool _aiReady(WidgetRef ref) {
    final AppSettings settings = ref.watch(settingsProvider);
    return settings.aiEnabled && settings.aiModel.trim().isNotEmpty;
  }

  /// 移动�?AppBar 动作：新�?+ 搜索 + 主菜单�?
  List<Widget> _chromeActions(BuildContext context, WidgetRef ref) => <Widget>[
    ..._sidebarActions(context, ref),
    const AppMenuButton(),
  ];
}

/// 内容分区面板：画布色 + 偏淡的细边框（对比阴影更克制）�?
///
/// 边线�?outlineVariant 半透明——亮色下是极浅的灰勾边，深色�?
/// 自然更亮一档；1px 描边 + 圆角，内�?ClipRRect 负责裁内容�?
class _ContentPanel extends StatelessWidget {
  const _ContentPanel({required this.child, this.partition = false});

  final Widget child;

  /// 是否为宽屏左右分区模式�?
  ///
  /// `true` 时：与左�?Mica 侧栏做硬分隔——直角、只保留左边线�?
  /// 顶边不画线（[WindowStrip] 与内容之间的那道 1px 分隔线由 `HomeScreen`
  /// 统一画在顶条下方，见那里的说明）�?
  /// `false` 时：保持原来的卡片式圆角（左�?左下），用于窄屏/移动端�?
  final bool partition;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    // 宽屏左右分区：右栏整体由外层 [DecoratedBox] 统一铺底�?+ 左侧边线�?
    // 这里只负责把内容撑满，不再自己画线，避免顶部出现断口�?
    if (partition) {
      return SizedBox.expand(child: child);
    }

    // 窄屏/移动端：卡片式面板，�?下与窗口边缘打通（直接顶到
    // 窗口右下角，视觉上是一整块工作区）�?
    //
    // 圆角只留左侧两个（左�?左下），右侧两个收直�?
    // - 右上：紧贴窗口顶边与窗控按钮区，直角让顶边连贯；
    // - 右下：交给窗口自己的原生圆角去裁。面板若自留圆角，会在窗口圆�?
    //   **内侧**多出一块深色空三角（实测观感："右下角有点空"）�?
    const BorderRadius radius = BorderRadius.only(
      topLeft: Radius.circular(Tokens.radiusMd),
      bottomLeft: Radius.circular(Tokens.radiusMd),
    );
    // 内层裁切比外框小 1px：描边占掉的那一圈不该被内容压住�?
    const BorderRadius innerRadius = BorderRadius.only(
      topLeft: Radius.circular(Tokens.radiusMd - 1),
      bottomLeft: Radius.circular(Tokens.radiusMd - 1),
    );
    // 描边只留�?上：右、下已与窗口边缘打通，窗口边框本身就是界线�?
    // 再画一道会成双线�?
    final Border border = Border(
      left: BorderSide(color: AppTheme.divider(scheme)),
      top: BorderSide(color: AppTheme.divider(scheme)),
    );

    return Stack(
      fit: .expand,
      children: <Widget>[
        // 底色 + 形状�?*不画描边**——描边在上一层，见下）�?
        DecoratedBox(
          decoration: BoxDecoration(
            color: AppTheme.contentCanvas(theme.brightness),
            borderRadius: radius,
          ),
          child: Stack(
            fit: .expand,
            children: <Widget>[
              // 纸面噪点（暗 2% / �?0）：夹在**纸色与内容之�?*，见 [_PaperNoise]�?
              // 圆角处必须一起裁，否则四个角会露出方形颗粒�?
              _PaperNoise(
                brightness: theme.brightness,
                clipRadius: innerRadius,
              ),
              ClipRRect(borderRadius: innerRadius, child: child),
            ],
          ),
        ),
        // ⚠️ 描边**必须画在子层之上**：`DecoratedBox` 的边框画在子层之下，
        // 而编辑器顶部工具栏铺的是**不透明**的画布色（与面板同色）⇒ 边框�?
        // 整条盖掉：顶边直接消失，左上圆角只剩裁切区外�?1px 的月牙，
        // 看着就像"圆角没加"�?
        //
        // 这一层用**与外框同一�?* `borderRadius`（不是内缩的那套）：圆角弧线
        // 与底色严丝合缝、和顶边/左边连成一条；`IgnorePointer` 保证它不�?
        // 正文的点击与悬停（它只是一圈线）�?
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(border: border, borderRadius: radius),
          ),
        ),
      ],
    );
  }
}

/// **纸面噪点**：一层极淡颗粒，铺在**纸色之上、内容之�?*
/// （强度见 [AppTheme.paperNoiseAlpha]：暗 `2%` / �?`0` �?亮的直接不挂）�?
///
/// ## 为什么必须夹�?纸色与内容之�?（三条，缺一条就白挂�?
/// 1. **铺到内容之上** �?颗粒糊在字上，文字边缘被打散，比不铺更糟�?
/// 2. **铺到纸色之下**（例如挂�?`main.dart` �?builder 那层底上）⇒ 纸面**不透明**�?
///    直接把噪点整块盖住，等于没挂�?
/// 3. **圆角面板要一起裁**（[clipRadius]）⇒ 否则四角露出方形颗粒，一眼是 bug�?
///
/// ## ⚠️ 它是**纯审�?*，不治任何东�?
/// 纸面是纯�?�?**没有色带**（色带是渐变的产物；而独立噪点图层也治不了渐变的色带�?
/// 2026-09-22 实测过）。所以唯一的理由是"纸感"——暗色下更能破掉纯黑的死板�?
/// **代价**：纸面就是阅读面，颗粒直接铺在字下面（字本身不糊，但字周的局部对比被�?
/// 一档）�?上限压到 2%，比窗口底那档（�?%）更保守�?
class _PaperNoise extends StatelessWidget {
  const _PaperNoise({required this.brightness, this.clipRadius});

  final Brightness brightness;

  /// 内层裁切半径（圆角面板传它；直角页面不传）�?
  final BorderRadius? clipRadius;

  @override
  Widget build(BuildContext context) {
    final double intensity = AppTheme.paperNoiseAlpha(brightness);
    if (intensity <= 0) return const SizedBox.shrink();
    final Widget noise = NoiseTexture(
      intensity: intensity,
      grain: AppTheme.windowNoiseGrain(brightness),
    );
    return clipRadius == null
        ? noise
        : ClipRRect(borderRadius: clipRadius!, child: noise);
  }
}

class _EmptyDetail extends StatelessWidget {
  const _EmptyDetail({super.key});

  @override
  Widget build(BuildContext context) =>
      const Center(child: Text('选择左侧笔记，或新建一篇'));
}

/// 占位分区的内容：诚实地说�?还没�?，而不是让人以为点了没反应�?
///
/// 接真实页面时删掉这个类，�?`Consumer` 的分发处直接建对应页面�?
class _SectionPlaceholder extends StatelessWidget {
  const _SectionPlaceholder({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: .min,
        children: <Widget>[
          Text('「$label」还没建'),
          const SizedBox(height: Tokens.spaceSm),
          Text(
            '占位页——页面实现接进来后本提示自动消失',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 折叠 / 展开左侧 [HubNav] 导航面板（[navCollapsedProvider]）�?
///
/// 放在主区顶条最左：展开态可随时折叠，折叠态（此时 [HubNav] 不渲染）
/// 靠它重新展开。图标随状态切换：展开→`LayoutSidebarLeftCollapse`（提示可收起），
/// 折叠→`LayoutSidebarLeftExpand`（提示可展开）�?
class NavCollapseButton extends ConsumerWidget {
  const NavCollapseButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool collapsed = ref.watch(navCollapsedProvider);
    return IconButton(
      icon: collapsed
          ? const tabler.LayoutSidebarLeftExpand(
              height: Tokens.iconMdSm,
              width: Tokens.iconMdSm,
              strokeWidth: 1.5,
            )
          : const tabler.LayoutSidebarLeftCollapse(
              height: Tokens.iconMdSm,
              width: Tokens.iconMdSm,
              strokeWidth: 1.5,
            ),
      tooltip: collapsed ? '展开面板' : '折叠面板',
      onPressed: () => ref.read(navCollapsedProvider.notifier).toggle(),
    );
  }
}
