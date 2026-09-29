import 'dart:async';

import 'dart:ui' as ui;

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
import 'settings_panel.dart' show showSettingsPanel;
import '../theme/app_theme.dart';
import '../theme/noise_texture.dart';
import '../theme/tokens.dart';
import '../window/app_title_bar.dart';
import '../window/window_service.dart';

import '../domain/settings.dart';

///
///
///
///
/// ```
///
///
///
///
/// ```
///
///
///
///
///
///
/// - 主区顶条（[WindowStrip]）：拖拽移动 + 双击最大化 + 窗控按钮（编辑态额外带
///
///
/// 移动端：标准 [AppBar] + 列表 / 编辑器二选一（由 [selectedNoteIdProvider]
///
///
///

const double _navWidth = 275;

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? selectedId = ref.watch(selectedNoteIdProvider);

    // ★ §5.6 阶段 2：**未选中 = 主页**（全窗口 Mica + 卡片入口分区）；选中 = 笔记 /
    // 画布页。同一个 `selectedNoteIdProvider` 驱动，不新增页面栈——切换，不是叠加。
    //
    // 2026-09-25 统一桌面布局：左恒为 [HubNav]，右栏随 `selectedId` 在主页 / 编辑器
    // 之间切换——**不进新路由**、不重建左侧列表（旧的 [NoteListView] 侧栏已删，点
    // 导航列表直接在右栏打开文档）。具体分支见下方 `WindowService.isSupported`。

    final Widget listPane = NoteListView(
      selectedId: selectedId,
      // 不带 focus：从列表点开一篇时若把焦点抢进编辑器，键盘上下选笔记就断了。
      onPick: (id) => ref.read(locateProvider.notifier).locate(noteId: id),
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
      // 桌面统一布局（2026-09-25）：左恒为 [HubNav]，右栏随 `selectedId` 切换——
      // 主页（[HomeHub]）/ 笔记·画布编辑器。点导航列表直接在右栏打开，不进新路由，
      // 也不重建左侧列表（旧的 [NoteListView] 侧栏已删，那个分支看着像"跳新页面"）。
      //
      // 2026-09-28 加第三列 **AI 问答轨**（[AskRail]）：宽窗常驻右缘，窄窗
      // （< [kAskRailBreakpoint]）降级回 [showAskPanel] 浮层——状态只有
      // [aiPanelOpenProvider] 一个布尔，呈现形态归外壳按宽度选。
      //
      // 窗口底**不在这里铺**：它由 `main.dart` 的 `MaterialApp.builder` 统一铺一层
      // 纯色（`AppTheme.windowBackground`）⇒ 这里保持透明让它透出来。

      final bool aiWanted = ref.watch(aiPanelOpenProvider);
      final bool railFits =
          MediaQuery.sizeOf(context).width >= kAskRailBreakpoint;
      final bool aiInline = aiWanted && railFits;

      // 窄窗降级路径：轨放不下时，把"打开"翻译成"弹浮层"并立刻复位开关
      //（浮层的显隐不归这个布尔管，否则 Esc 关浮层时会反向点亮图标）。
      // 放在 post-frame 里、且进入时再读一次当前值——一道机制同时覆盖两种
      // 触发：① 窄窗里按 Ctrl+J / 点图标"打开"；② 开着轨把窗口拖过断点。
      // 首个回调复位后同帧的其余回调读到的已是 false ⇒ 浮层不会弹两层。
      if (aiWanted && !railFits) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!ref.read(aiPanelOpenProvider)) return;
          ref.read(aiPanelOpenProvider.notifier).close();
          unawaited(showAskPanel());
        });
      }

      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Row(
          crossAxisAlignment: .stretch,
          children: <Widget>[
            // 第二列 [HubNav]：折叠态（`navCollapsedProvider`）下宽度动画收为 0，
            // 只剩主区；展开时动画回 275。用 [AnimatedContainer] 做布局级宽度插值，
            // [ClipRect] 裁掉过渡期溢出的内容——纯 layout 动画，不触发 saveLayer
            // （符合 Impeller 性能规范）。右侧 Expanded 随之自动补满。
            // 折叠 / 展开由主区顶条的 [NavCollapseButton] 控制。
            // ⚠️ 第一列总导航栏（50px AppRail）已于 2026-09-29 撤掉：主页 /
            // 设置 / 上一步 / 下一步都搬进主区顶条（[WindowStrip]）——
            // 两枚图标撑不起一整列。
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              width: ref.watch(navCollapsedProvider) ? 0 : _navWidth,
              // 折叠动画期间容器宽度会小于板宽，若直接约束子节点，[HubNav] 内部
              // 的 Row（图标 + 标题 + 时间 + 「···」）会因空间不足而溢出报 layout
              // 错误。用 [OverflowBox] 让 [HubNav] 始终按完整板宽（[_navWidth]）布局，
              // 再由外层 [ClipRect] 裁掉可见区以外的部分——既平滑又不再溢出。
              child: const ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  maxWidth: _navWidth,
                  child: HubNav(),
                ),
              ),
            ),
            // 右栏：**全程与窗口底同色**（2026-09-29 用户定）。选中态曾经铺过
            // 一层"编辑器画布底 + 纸面噪点"想跟左栏形成硬分区，但画布底早已并入
            // 窗口底、噪点又把笔记页染得和主页不一样（用户实报"点进笔记会变色"）
            // ——两者都已撤掉。左栏 [HubNav] 同样取窗口底，主区/侧栏的分界现在
            // 只由窗控条那道 1px 分隔线表达（§5.6 的"同色平铺"）。
            Expanded(
              child: selectedId == null
                  ? Column(
                      children: <Widget>[
                        // 主页分支的顶条（2026-09-29 用户定）：左 = 主页 +
                        // 上一步/下一步（视图历史）+ 折叠面板钮；右 = 设置
                        // （紧挨 AI 开关）+ AI 轨开关。全局动作靠右、页面
                        // 导航靠左。
                        const WindowStrip(
                          leading: <Widget>[
                            HomeNavButton(),
                            NavHistoryButton(),
                            NavHistoryButton(forward: true),
                            NavCollapseButton(),
                          ],
                          trailing: <Widget>[
                            SettingsNavButton(),
                            AiRailToggleButton(),
                          ],
                        ),
                        Expanded(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              // 右侧 0（2026-09-26 用户定）：主区滚动
                              // viewport 必须触到窗口右缘，滚动条才永远贴边；
                              // 内容自身的呼吸（HomeHub 各有各的 padding）不受
                              // 影响。AI 轨收起时这里仍到右缘。
                              // 左 6 = 与导航板的间隙；上 6 = 与窗控条的间隙。
                              // 2026-09-29 主页重做：搜索 / 收藏 / 筛选都收进
                              // HomeHub 顶栏的视图切换里，主区不再按第二列
                              // 选中分区分发——未选中笔记时恒为 [HomeHub]。
                              const Expanded(
                                child: Padding(
                                  padding: EdgeInsets.fromLTRB(6, 6, 0, 6),
                                  child: HomeHub(),
                                ),
                              ),
                              // AI 问答轨（宽窗常驻；窄窗不渲染，改走浮层）。
                              _AiRailSlot(open: aiInline),
                            ],
                          ),
                        ),
                      ],
                    )
                  : DecoratedBox(
                      decoration: BoxDecoration(
                        // 2026-09-29 用户定：笔记 / 画布页的右侧主区**必须与主题
                        // 背景同色**——从主页点进笔记不许"变色"。故直取
                        // [windowBackground]（不再走语义上"可能再分档"的
                        // [contentCanvas]）：后者早已并入窗口底，本来就不产生色差，
                        // 真正把笔记页染出色差的是下面那层纸面噪点（已撤）。
                        color: AppTheme.windowBackground(
                          Theme.of(context).brightness,
                        ),
                      ),
                      child: Stack(
                        fit: .expand,
                        // [Stack] 现在只剩一个孩子，留着只为 `fit: expand`：
                        // 它把 [Column] 撑满整列高度，比依赖 Column 的
                        // `mainAxisSize.max` 更直白（这个结构承载过纸面噪点，
                        // 噪点已在 2026-09-29 撤掉，见上面的底色注释）。
                        children: <Widget>[
                          Column(
                            children: <Widget>[
                              WindowStrip(
                                // 左起：主页 + 上一步/下一步 + 折叠面板钮
                                // （2026-09-29 用户定：与主页分支同一簇，替换
                                // 旧的「上一页」单钮——编辑器不在视图历史栈里，
                                // 所以箭头按下时先回主页再走历史）。
                                leading: const <Widget>[
                                  HomeNavButton(),
                                  NavHistoryButton(),
                                  NavHistoryButton(forward: true),
                                  NavCollapseButton(),
                                ],
                                // 右端：设置 + AI 轨开关（紧贴「最小化」左侧）。
                                trailing: const <Widget>[
                                  SettingsNavButton(),
                                  AiRailToggleButton(),
                                ],
                              ),
                              // 顶条与内容之间的分隔线（2026-09-14 用户定案）：
                              // 右列因此分成"标题带（拖拽 + 窗控）"与"内容"两段。
                              //
                              // ⚠️ 必须是**独立 1px 盒子**（见旧实现的两条理由：
                              // border 会被铺底子层盖出断口；加在 [WindowStrip] 自己
                              // 的 border 上会被 32 高窗控按钮顶出容器）。
                              Container(
                                height: 1,
                                color: AppTheme.divider(
                                  Theme.of(context).colorScheme,
                                ),
                              ),
                              Expanded(
                                child: Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: <Widget>[
                                    Expanded(
                                      child: _ContentPanel(
                                        partition: true,
                                        child: detailPane(),
                                      ),
                                    ),
                                    // AI 问答轨：写正文时同屏对照答案/引用，
                                    // 轨底取窗口色把自己从"纸面"里分出来。
                                    _AiRailSlot(open: aiInline),
                                  ],
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

    // 移动端：标准 AppBar。
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

  ///
  static Note? _noteById(List<Note>? notes, String? id) {
    if (notes == null || id == null) return null;
    for (final Note n in notes) {
      if (n.id == id) return n;
    }
    return null;
  }

  ///
  ///
  List<Widget> _sidebarActions(BuildContext context, WidgetRef ref) => <Widget>[
    // 走命令层而不是就地调 notifier：按钮与 `Ctrl+N` 必须是**同一条路**
    // （§3.2 命令是权威面）——各留一份实现迟早漂移成"按钮能建、快捷键不能"。
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
    // 与「设置 → AI」默认关闭是同一口径（见 AppSettings.aiEnabled 的说明）。
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
    // 新建画布笔记（[NoteKind.canvas]）：建好即选中，右栏直接出画布。
    // 不再是"全屏路由的实验页"——画布已与块编辑器同页共存。
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

  ///
  ///
  ///
  ///
  bool _aiReady(WidgetRef ref) {
    final AppSettings settings = ref.watch(settingsProvider);
    return settings.aiEnabled && settings.aiModel.trim().isNotEmpty;
  }

  ///
  List<Widget> _chromeActions(BuildContext context, WidgetRef ref) => <Widget>[
    ..._sidebarActions(context, ref),
    const AppMenuButton(),
  ];
}

///
///
///
///
class _ContentPanel extends StatelessWidget {
  const _ContentPanel({required this.child, this.partition = false});

  final Widget child;

  ///
  ///
  ///
  /// 顶边不画线（[WindowStrip] 与内容之间的那道 1px 分隔线由 `HomeScreen`
  ///
  ///
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
      fit: .expand,
      children: <Widget>[
        // 底色 + 形状（**不画描边**——描边在上一层，见下）。
        DecoratedBox(
          decoration: BoxDecoration(
            color: AppTheme.contentCanvas(theme.brightness),
            borderRadius: radius,
          ),
          child: Stack(
            fit: .expand,
            children: <Widget>[
              // 纸面噪点（暗 2% / 亮 0）：夹在**纸色与内容之间**，见 [_PaperNoise]。
              // 圆角处必须一起裁，否则四个角会露出方形颗粒。
              _PaperNoise(
                brightness: theme.brightness,
                clipRadius: innerRadius,
              ),
              ClipRRect(borderRadius: innerRadius, child: child),
            ],
          ),
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

///
///
///
///
///
///
///
///
///
///
///
///
///
///
class _PaperNoise extends StatelessWidget {
  const _PaperNoise({required this.brightness, this.clipRadius});

  final Brightness brightness;

  ///
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

/// 右侧 **AI 问答轨**的动画槽：打开 [kAskRailWidth]、关闭收为 0。
///
/// 与左导航槽**同一套做法**（[AnimatedContainer] 布局插值 + [ClipRect] 裁切 +
/// [OverflowBox] 固定满宽布局）：纯 layout 动画、不触发 saveLayer；
/// 收起过渡期内部也不被窄约束顶出 overflow。问答体因此在开合之间**不销毁**
/// ——问题、答案、输入都保留。
///
/// 关闭时 [ExcludeFocus] 把整列移出 Tab 链：宽 0 的隐藏控件不许被键盘聚焦
///（打开聚焦由 [AskRail] 自己在开关翻转时处理）。
class _AiRailSlot extends StatelessWidget {
  const _AiRailSlot({required this.open});

  final bool open;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      width: open ? kAskRailWidth : 0,
      child: ExcludeFocus(
        excluding: !open,
        child: const ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            maxWidth: kAskRailWidth,
            child: AskRail(),
          ),
        ),
      ),
    );
  }
}

/// **AI 问答轨开关**（桌面顶条右端，紧贴「最小化」左侧）。
///
/// 与左端的 [NavCollapseButton] **左右对称**：一边管左栏、一边管右轨，两枚都
/// 钉在窗控条上——位置固定，不随"现在哪个分栏在显示"变（AI 轨在主页时同样能开）。
///
/// - 走命令层 `ai.ask`：按钮与 `Ctrl+J` 必须是**同一条路**（§3.2 命令是权威面）；
/// - 开态披一档中性 tint（[AppTheme.navSelectedTint]）——它是个开/关，得如实
///   显示现在开着；
/// - **不按"AI 是否配置"显隐**：未配置时点开，面板里的报错本身就是可操作的
///   说明；藏起来只会让人以为"这软件没有问答"。
class AiRailToggleButton extends ConsumerWidget {
  const AiRailToggleButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool open = ref.watch(aiPanelOpenProvider);
    return IconButton(
      icon: const tabler.Sparkles(
        height: Tokens.iconMdSm,
        width: Tokens.iconMdSm,
        strokeWidth: 1.5,
      ),
      // 键位写进 tooltip：顶条是它唯一的图标入口，这里不提就没人知道。
      tooltip: '问笔记（Ctrl+J）',
      style: IconButton.styleFrom(
        backgroundColor: open
            ? AppTheme.navSelectedTint(scheme.onSurface)
            : Colors.transparent,
      ),
      onPressed: () => unawaited(runCommandById(ref, 'ai.ask')),
    );
  }
}

///
///
/// 放在主区顶条最左：展开态可随时折叠，折叠态（此时 [HubNav] 不渲染）
/// 靠它重新展开。图标随状态切换：展开→`LayoutSidebarLeftCollapse`（提示可收起），
///
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

/// 顶条左缘的**主页**钮（2026-09-29 用户定：50px 第一列总导航栏撤掉，主页 /
/// 设置搬进标题栏——两枚图标撑不起一整列）。在主页上披主题色（延续 AppRail
/// 时代的 active 语义），在笔记 / 画布页点亮即回主页。
class HomeNavButton extends ConsumerWidget {
  const HomeNavButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool onHome = ref.watch(selectedNoteIdProvider) == null;
    return IconButton(
      icon: tabler.LayoutDashboard(
        height: Tokens.iconMdSm,
        width: Tokens.iconMdSm,
        strokeWidth: 1.5,
        colorFilter: ui.ColorFilter.mode(
          onHome ? scheme.primary : scheme.onSurfaceVariant,
          ui.BlendMode.srcIn,
        ),
      ),
      tooltip: '主页',
      onPressed: () {
        ref.read(hubNavSelectionProvider.notifier).select(0);
        ref.read(locateProvider.notifier).goHome();
      },
    );
  }
}

/// 顶条左缘的**上一步 / 下一步**（2026-09-29 用户定）：视图历史
/// （[HomeViewNotifier]）的出口。低频视图（笔记 / 画布）收进「更多」后是
/// 两跳目的地，靠这一对钮抹平往返。
///
/// 在编辑器页里按下 = 先回主页、再走历史——编辑器不在历史栈里，历史只记
/// 主页视图。无可退 / 可进时按钮置灰（`onPressed: null`）。
class NavHistoryButton extends ConsumerWidget {
  const NavHistoryButton({super.key, this.forward = false});

  /// false = 上一步（退回），true = 下一步（重做）。
  final bool forward;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 订阅视图 state：每次导航 state 都会变 ⇒ 重读 canGo* 拿到正确可用态。
    ref.watch(homeViewProvider);
    final HomeViewNotifier nav = ref.read(homeViewProvider.notifier);
    final bool can = forward ? nav.canGoForward : nav.canGoBack;
    return IconButton(
      icon: forward
          ? const tabler.ChevronRight(
              height: Tokens.iconMdSm,
              width: Tokens.iconMdSm,
              strokeWidth: 1.5,
            )
          : const tabler.ChevronLeft(
              height: Tokens.iconMdSm,
              width: Tokens.iconMdSm,
              strokeWidth: 1.5,
            ),
      tooltip: forward ? '下一步' : '上一步',
      onPressed: can
          ? () {
              final HomeViewNotifier nav = ref.read(homeViewProvider.notifier);
              if (ref.read(selectedNoteIdProvider) != null) {
                ref.read(locateProvider.notifier).goHome();
              }
              forward ? nav.goForward() : nav.goBack();
            }
          : null,
    );
  }
}

/// 顶条右端的**设置**钮（2026-09-29 用户定：从第一列底部搬来，紧挨 AI 开关
/// ——全局动作靠右、页面导航靠左）。点击弹 [showSettingsPanel] 浮层。
class SettingsNavButton extends ConsumerWidget {
  const SettingsNavButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const IconButton(
      icon: tabler.Settings(
        height: Tokens.iconMdSm,
        width: Tokens.iconMdSm,
        strokeWidth: 1.5,
      ),
      tooltip: '设置',
      onPressed: showSettingsPanel,
    );
  }
}
