import 'dart:async';

import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../canvas/canvas_switch.dart';
import 'app_menu.dart';
import '../command/commands.dart';
import '../domain/note.dart';
import 'home_hub.dart';
import '../editor/core/editor_switch.dart';
import '../notes/note_list_view.dart';
import 'ask_panel.dart';
import 'providers.dart';
import 'settings_panel.dart' show showSettingsPanel;
import '../theme/app_custom_icons.dart';
import '../theme/app_theme.dart';
import '../theme/noise_texture.dart';
import '../theme/tokens.dart';
import '../window/app_title_bar.dart';
import '../window/window_service.dart';

import '../domain/settings.dart';

/// 应用主外壳：桌面端自绘 chrome + 内嵌浮面，移动端标准单栏。
///
/// 桌面端（[WindowService.isSupported]）：
/// - 桌面外壳（2026-10-09 用户定，opencode 风"内嵌浮面"）：44 高全宽
///   [WindowStrip]——**四枚目的地图标（心流 / 全部 / 日历 / 收藏）精确几何居中**
///   （2026-10-11 用户定，靠 `center` 的 `Positioned.fill + Center`；左 `Expanded`
///   等分放历史键浮在「心流」左，不挤占导航位；设置钮在更右端紧贴最小化左——与窗控
///   成组）；窗控按钮在更右端；无分割线。**问笔记（AI）不是标题栏钮**——它 2026-10-11
///   起改为工作区右角折叠钮（见本文件工作区 [_RightRailToggleButton]），与规划中左面板
///   钮对称、开合两态坐标不变，好发现好记忆。
/// - 条下 4px 环缝内是一张（AI 打开时两张并排）圆角 12 的浮面卡，
///   `AppTheme.panelFill` 实色 + 一圈 1px `AppTheme.panelEdge` 光边、
///   **无投影**（主页 / 编辑器同色，点进笔记不"变色"）：立体感来自近底 vs
///   亮面的明度差、受光细边与 8px 暗缝三件套（量 opencode 像素定，2026-10-09）。
/// - 更早的轨迹：50 宽最左图标轨（同日下午撤入顶条）、导航板 [HubNav]
///   （2026-09-30）。
///
/// 移动端：标准 [AppBar] + 列表 / 编辑器二选一（由 [selectedNoteIdProvider]
/// 决定）。

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? selectedId = ref.watch(selectedNoteIdProvider);

    // ★ §5.6 阶段 2：**未选中 = 主页**（窗口底 + 卡片入口分区）；选中 = 笔记 /
    // 画布页。同一个 `selectedNoteIdProvider` 驱动，不新增页面栈——切换，不是叠加。
    //
    // 2026-09-25 统一桌面布局：右栏随 `selectedId` 在主页 / 编辑器之间切换——
    // **不进新路由**（旧的 [NoteListView] 侧栏已删）。桌面顶条左簇是 2026-10-09
    // 收编的四枚目的地图标（当日早上曾立 50 宽 `_AppIconRail`，下午撤入顶条）；
    // 更早的导航板 [HubNav]（2026-09-30）。
    // 具体分支见下方 `WindowService.isSupported`。

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
      // 桌面统一布局（2026-09-25）：随 `selectedId` 切换主页（[HomeHub]）/
      // 笔记·画布编辑器，不进新路由。
      //
      // 2026-10-09 用户定（opencode 风"内嵌浮面"，替代当日早上的 50 图标轨）：
      // 顶条 44 全宽——居中动作组（2026-10-11 用户定，靠 `center` 的
      // `Positioned.fill + Center`）：**四枚目的地图标精确几何居中**，左 `Expanded`
      // 等分放历史键（按可用态置灰）浮在「心流」左侧、各自留 16 隔、不挤占导航位；
      // 问笔记（AI）已改为工作区右角折叠钮（见下方工作区 [_RightRailToggleButton]）、
      // 设置钮在更右端紧贴最小化左。
      // 条下不再画 1px 分隔线：内容是 8px 环缝内的圆角浮面卡。分层三件套 =
      // 窗口底 vs panelFill 的明度差 + 卡缘 1px panelEdge 光边 + 4px 暗缝
      //（无投影；2026-10-09 量 opencode 像素定，量值与理由见 surface_ladder）。
      //
      // 2026-09-28 加 **AI 问答轨**（[AskRail]）：宽窗常驻右缘，呈现为第二张
      // 浮面卡；窄窗（< [Tokens.askRailBreakpoint]）降级回 [showAskPanel]
      // 浮层——状态只有 [aiPanelOpenProvider] 一个布尔，呈现形态归外壳按宽度选。
      //
      // 窗口底**不在这里铺**，而且现在也**不是** `MaterialApp.builder` 铺的
      // ——`WindowBase` 早在 2026-09-23 就删掉了那层自绘底（省掉每帧全屏 fill）。
      // 窗口底现在由**平台层**负责，两种互斥的走法（见 `WindowService`
      // `applyWindowBackground`）：
      //   · 开成 Mica ⇒ 平台窗口透明，DWM 在最底下画材质，这里透出的是**材质**；
      //   · 没开成（Win10 等）⇒ 平台铺不透明 `AppTheme.windowBackground`。
      // 两种都是"底下有底"，所以这里一律保持透明。

      final bool aiWanted = ref.watch(aiPanelOpenProvider);
      final bool railFits =
          MediaQuery.sizeOf(context).width >= Tokens.askRailBreakpoint;
      final bool aiInline = aiWanted && railFits;
      // 左面板（规划中）：与 AI 同档断点，宽窗才 dock；窄窗暂不降级（占位面板）。
      final bool leftWanted = ref.watch(leftPanelOpenProvider);
      final bool leftInline = leftWanted && railFits;

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
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // 居中组（[WindowStrip.center] 的 `Positioned.fill + Center` 居中）：
            // **四枚目的地图标（心流 / 全部 / 日历 / 收藏）精确几何居中**——左侧用
            // `Expanded` 等分放历史键（浮在「心流」左侧），中间导航药丸恒居正中、不被挤移
            // （2026-10-11 用户定：四个导航钮居中、其他钮浮在左右、不挤占其位）。问笔记
            // 2026-10-11 起移入 hub 头栏（贴「筛选与排序」右侧）；设置钮并入最右 `trailing`、
            // 紧贴最小化左侧（与窗控成组）。编辑态历史键按可用态置灰、导航常驻全灰。拖拽带
            // 正中不放搜索入口（Ctrl+K 统一口径）；窗控按钮在更右端。
            WindowStrip(
              // 四枚导航钮精确居中：左 `Expanded` 放历史键（内部居中），右 `Expanded` 留空
              // 仅用于等分；中间导航药丸恒居正中。问笔记（AI）已移出顶条、改为工作区右角
              // 折叠钮；设置钮并入最右 `trailing`（紧贴最小化左侧）；居中靠 Stack 兄弟层
              // （不进拖拽带竞技场）。
              center: Row(
                children: <Widget>[
                  Expanded(
                    // 次级按钮组在左留白区**居中**（非右对齐贴「心流」、也非贴最左缘）：
                    // 历史键明显左移、与导航保持距离，左右都有余量，读作"次级组浮在左侧"。
                    // 居中只发生在本 Expanded 内部，左右 Expanded 仍等分 ⇒ 导航钮精确居中不变。
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const <Widget>[
                        NavHistoryButton(),
                        SizedBox(width: Tokens.spaceLg),
                        NavHistoryButton(forward: true),
                      ],
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      for (int i = 0; i < kHomeTabs.length; i++) ...<Widget>[
                        if (i > 0) const SizedBox(width: Tokens.spaceLg),
                        NavDestinationButton(
                          view: kHomeTabs[i],
                          icon: kHomeTabs[i].icon,
                        ),
                      ],
                    ],
                  ),
                  // 右留白区：2026-10-11 起问笔记已移出顶条、改为工作区右角折叠钮，
                  // 此处留空 Expanded 仅用于与左 Expanded 等分、维持导航钮几何居中。
                  const Expanded(child: Row()),
                ],
              ),
              // 设置钮并入最右簇，紧贴最小化左侧（与窗控成组）。
              trailing: const <Widget>[
                SettingsNavButton(),
              ],
            ),
            // 工作区：左 / 右 / 下各 4px 环缝，**顶部与标题条间距 0**
            //（2026-10-09 用户定）——浮面像从标题条下沿"长出来"，故卡片
            // 顶两角为直角（见 [_FloatingPanel]）；AI 打开时主卡 + 8 缝 + AI 卡（右
            // dock、推开内容），左面板（规划中）同构从左侧 dock。
            // 角落折叠钮（[_RightRailToggleButton] / [_LeftRailToggleButton]）浮在工作区
            // 之上、钉在内容卡内缘 4px、y 与编辑器顶栏「标签」耳按钮同高；开合两态坐标不变
            //（2026-10-11 起：右角钮是 AI 面板唯一开合入口）。
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Tokens.appPanelInset,
                  0,
                  Tokens.appPanelInset,
                  Tokens.appPanelInset,
                ),
                child: Stack(
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _LeftRailSlot(open: leftInline),
                        Expanded(
                          child: _FloatingPanel(
                            child: selectedId == null
                                ? const HomeHub()
                                : detailPane(),
                          ),
                        ),
                        _AiRailSlot(open: aiInline),
                      ],
                    ),
                    // 左角折叠钮（左面板，规划中）：钉内容卡内缘 4px、y 对齐筛选排序。
                    Positioned(
                      // 与右角钮同高（对齐编辑器顶栏「耳朵」带，见
                      // [_RightRailToggleButton] 的注释）。
                      top: Tokens.spaceXs,
                      left: Tokens.spaceXs,
                      child: const _LeftRailToggleButton(),
                    ),
                    // 右角折叠钮（AI）：唯一开合入口；开合两态坐标不变（2026-10-11）。
                    Positioned(
                      // y 对齐编辑器顶栏「耳朵」带（标签所在那排）：32 高钮取 top 4
                      // ⇒ 中心 20，与耳朵中心（5 + 30/2 = 20）同高（2026-10-11 用户定）。
                      top: Tokens.spaceXs,
                      right: Tokens.spaceXs,
                      child: const _RightRailToggleButton(),
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

/// 移动端窄屏的卡片式内容面板（桌面端 2026-10-09 起统一走 [_FloatingPanel]）。
class _ContentPanel extends StatelessWidget {
  const _ContentPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

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

/// 浮面卡统一圆角：四角均为 [Tokens.radiusLg]（2026-10-09 晚用户定：顶两角
/// 恢复圆角——直角不好看）。顶边仍与 44 标题条 **0 间距**，圆角落出的小弧
/// 露出窗口底，正好充当卡顶的分缝。主卡与 AI 卡共用，保证拼缝处半径一致。
const BorderRadius _kPanelRadius = BorderRadius.all(
  Radius.circular(Tokens.radiusLg),
);

/// 工作区的**内嵌浮面卡**（2026-10-09 opencode 风外壳）：`panelFill` 实色 +
/// [_kPanelRadius]（四角 12 圆）+ 一圈 1px [AppTheme.panelEdge] 光边，
/// **无投影**；内容用 [ClipRRect] 裁进圆角，滚动条 / 铺底色块不会顶出方角。
///
/// 光边走 `foregroundDecoration` 画在内容**之上**：编辑器等子树会把底色铺到
/// 卡缘，普通 border 画在子层下面会被盖住。
class _FloatingPanel extends StatelessWidget {
  const _FloatingPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Brightness brightness = Theme.of(context).brightness;
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.panelFill(brightness),
        borderRadius: _kPanelRadius,
        // 亮面语言靠软投影（暗端空列表，继续走光边，见 AppTheme.panelShadow）。
        boxShadow: AppTheme.panelShadow(brightness),
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: _kPanelRadius,
        border: Border.all(color: AppTheme.panelEdge(brightness)),
      ),
      child: ClipRRect(borderRadius: _kPanelRadius, child: child),
    );
  }
}

/// 右侧 **AI 问答轨**的动画槽：关闭收为 0；打开时是第二张浮面卡——
/// 宽 [Tokens.askRailWidth]，左缘自带 [Tokens.appPanelInset] 卡缝（槽宽合计
/// askRailWidth + 8），故总宽在 0 ↔ 348 之间插值。
///
/// 做法与旧槽一致（[AnimatedContainer] 布局插值 + [ClipRect] 裁切 +
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
    const double seam = Tokens.appPanelInset;
    const double fullWidth = Tokens.askRailWidth + seam;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      width: open ? fullWidth : 0,
      child: ExcludeFocus(
        excluding: !open,
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            maxWidth: fullWidth,
            child: Padding(
              // 左 8 = 两张浮面卡之间的缝（露窗口底），与外环缝同档。
              padding: const EdgeInsets.only(left: seam),
              child: Container(
                decoration: BoxDecoration(
                  color: AppTheme.panelFill(Theme.of(context).brightness),
                  borderRadius: _kPanelRadius,
                  boxShadow: AppTheme.panelShadow(Theme.of(context).brightness),
                ),
                // 与主卡同一条 1px 光边（盖在内容之上，见 [_FloatingPanel]）。
                foregroundDecoration: BoxDecoration(
                  borderRadius: _kPanelRadius,
                  border: Border.all(
                    color: AppTheme.panelEdge(Theme.of(context).brightness),
                  ),
                ),
                child: const ClipRRect(
                  borderRadius: _kPanelRadius,
                  child: SizedBox(width: Tokens.askRailWidth, child: AskRail()),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 顶条左簇的单枚**目的地钮**（2026-10-09 下午从 50 图标轨移入）：
/// 工作区**右角折叠钮**（2026-10-11 起从 hub 头栏移此）：钉在内容卡内缘 4px、
/// y 与「筛选与排序」及编辑器顶栏「标签」耳按钮同高，是 AI 面板（[AskRail]）的
/// **唯一**开合入口——开态披中性 tint，关闭走 Esc 或本钮；开合两态坐标不变，好记忆。
class _RightRailToggleButton extends ConsumerWidget {
  const _RightRailToggleButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool open = ref.watch(aiPanelOpenProvider);
    return SizedBox(
      width: Tokens.toolbarButtonSize,
      height: Tokens.toolbarButtonSize,
      child: IconButton(
        icon: const tabler.Sparkles(
          height: Tokens.iconMdSm,
          width: Tokens.iconMdSm,
          strokeWidth: 1.5,
        ),
        tooltip: '问笔记（Ctrl+J）',
        style: IconButton.styleFrom(
          backgroundColor: open
              ? AppTheme.navSelectedTint(scheme.onSurface)
              : Colors.transparent,
        ),
        onPressed: () => unawaited(runCommandById(ref, 'ai.ask')),
      ),
    );
  }
}

/// 工作区**左角折叠钮**（左面板，规划中）：与 [_RightRailToggleButton] 对称，
/// 钉在内容卡内缘 4px、y 与右角钮同高；点击切换 [leftPanelOpenProvider]，
/// 开合两态坐标不变。当前左面板仅占位（见 [_LeftRailSlot]）。
class _LeftRailToggleButton extends ConsumerWidget {
  const _LeftRailToggleButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool open = ref.watch(leftPanelOpenProvider);
    return SizedBox(
      width: Tokens.toolbarButtonSize,
      height: Tokens.toolbarButtonSize,
      child: IconButton(
        icon: const tabler.MenuDeep(
          height: Tokens.iconMdSm,
          width: Tokens.iconMdSm,
          strokeWidth: 1.5,
        ),
        tooltip: '左面板（规划中）',
        style: IconButton.styleFrom(
          backgroundColor: open
              ? AppTheme.navSelectedTint(scheme.onSurface)
              : Colors.transparent,
        ),
        onPressed: () => ref.read(leftPanelOpenProvider.notifier).toggle(),
      ),
    );
  }
}

/// 左侧面板槽（规划中）：与 [_AiRailSlot] 对称——从**左**缘 dock、推开内容，
/// 关闭收 0、打开宽 [Tokens.leftRailWidth] + 缝；当前渲染占位空面板（见
/// [_LeftPanelPlaceholder]），真实左面板功能落地即替换内部内容。
class _LeftRailSlot extends StatelessWidget {
  const _LeftRailSlot({required this.open});

  final bool open;

  @override
  Widget build(BuildContext context) {
    const double seam = Tokens.appPanelInset;
    const double fullWidth = Tokens.leftRailWidth + seam;
    final Brightness brightness = Theme.of(context).brightness;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      width: open ? fullWidth : 0,
      child: ExcludeFocus(
        excluding: !open,
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.topRight,
            maxWidth: fullWidth,
            child: Padding(
              // 右 8 = 两张浮面卡之间的缝（露窗口底），与外环缝同档。
              padding: const EdgeInsets.only(right: seam),
              child: Container(
                decoration: BoxDecoration(
                  color: AppTheme.panelFill(brightness),
                  borderRadius: _kPanelRadius,
                  boxShadow: AppTheme.panelShadow(brightness),
                ),
                foregroundDecoration: BoxDecoration(
                  borderRadius: _kPanelRadius,
                  border: Border.all(color: AppTheme.panelEdge(brightness)),
                ),
                child: ClipRRect(
                  borderRadius: _kPanelRadius,
                  child: const _LeftPanelPlaceholder(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 左面板占位（规划中）：仅证明左侧 dock 布局与左角折叠钮联动；真实功能落地
/// 后替换。头部只留标题（关闭走 Esc 或左角折叠钮，与右 AI 面板同构）。
class _LeftPanelPlaceholder extends StatelessWidget {
  const _LeftPanelPlaceholder();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 标题靠右（朝主卡缝一侧）：镜像右 AI 面板（标题在左），让开左上角的
        // 左角折叠钮（见 [_LeftRailToggleButton]），避免叠字。
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Tokens.spaceXs,
            Tokens.spaceXs,
            Tokens.spaceMd,
            Tokens.spaceXs,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              Text('左面板', style: theme.textTheme.titleSmall),
            ],
          ),
        ),
        Container(height: 1, color: AppTheme.divider(scheme)),
        Expanded(
          child: Center(
            child: Text('规划中', style: theme.textTheme.labelSmall),
          ),
        ),
      ],
    );
  }
}

/// tooltip = 视图名（也是 a11y 标签）。
///
/// 行为与视图切换同源（[NavHistoryNotifier.selectHome]）⇒ 在编辑器里按下 =
/// 离开编辑器去那个视图，且进统一导航历史。主页态高亮当前视图（"我在哪"），
/// 编辑态全灰（"在笔记里"不属于任何目的地）。
class NavDestinationButton extends ConsumerWidget {
  const NavDestinationButton({
    super.key,
    required this.view,
    required this.icon,
  });

  final HomeView view;

  /// 图标按**当前色**现画（tabler 是自绘 widget，不读 IconTheme）。
  final Widget Function(Color color) icon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool onHome = ref.watch(selectedNoteIdProvider) == null;
    final bool active = onHome && ref.watch(navHistoryProvider).view == view;
    return IconButton(
      tooltip: view.label,
      style: IconButton.styleFrom(
        // 「当前项」统一读法：强调色药丸（2026-10-08 全局换装）。
        backgroundColor: active
            ? AppTheme.selectedPill(scheme)
            : Colors.transparent,
      ),
      icon: icon(active ? scheme.onSurface : scheme.onSurfaceVariant),
      onPressed: () => ref.read(navHistoryProvider.notifier).selectHome(view),
    );
  }
}

/// 顶条左缘的**上一步 / 下一步**（2026-09-29 用户定）：**统一导航历史**
/// （[navHistoryProvider]）的出口——主页视图切换与进入笔记 / 画布页都入栈
/// （2026-09-30 用户定），严格按点击顺序进退；编辑器也在栈里，退到一篇笔记
/// = 重新打开它。无可退 / 可进时按钮置灰（`onPressed: null`）。
class NavHistoryButton extends ConsumerWidget {
  const NavHistoryButton({super.key, this.forward = false});

  /// false = 上一步（退回），true = 下一步（重做）。
  final bool forward;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // watch 一次拿到「当前视图 + 历史可用态」：[NavHistoryState] 把两个 `canGo*`
    // 放在 state 里 ⇒ 导航后本 widget 重建，可用态自动跟着更新。
    // （不再读 notifier 的公开 getter——那是 `riverpod_lint` 禁止的，且拿不到
    // 重建通知。）
    final NavHistoryState navState = ref.watch(navHistoryProvider);
    final bool can = forward ? navState.canGoForward : navState.canGoBack;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 上一步 / 下一步（回退为 Remix 实心箭头，与主页一致）：[CustomIcons] 是
    // 裸 SVG，不读 Material IconTheme ⇒ 禁用色必须**自己算**（M3 禁用图标 =
    // onSurface 38%），否则置灰失效。
    final Color iconColor = can
        ? scheme.onSurfaceVariant
        : scheme.onSurface.withValues(alpha: 0.38);
    return IconButton(
      // 图标尺寸与顶条其它钮一致 = [Tokens.iconMdSm]（20），与「收藏」等目的地钮
      // 同大（2026-10-11 用户定统一大小）；[CustomIcons] 默认档 24 偏大，这里显式降。
      icon: forward
          ? CustomIcons.arrowRight(size: Tokens.iconMdSm, color: iconColor)
          : CustomIcons.arrowLeft(size: Tokens.iconMdSm, color: iconColor),
      tooltip: forward ? '下一步' : '上一步',
      onPressed: can
          ? () {
              // 直接走统一历史：退 / 进的落点是主页视图就离开编辑器，是某篇
              // 笔记就重新打开——栈里已记录完整点击顺序，无需先 goHome。
              final NavHistoryNotifier nav = ref.read(
                navHistoryProvider.notifier,
              );
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
