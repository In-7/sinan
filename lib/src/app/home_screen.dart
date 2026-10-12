import 'dart:async';

import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../canvas/canvas_switch.dart';
import 'app_menu.dart';
import '../command/commands.dart';
import '../domain/note.dart';
import 'home_hub.dart';
import 'home_sidebar.dart';
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

/// 应用主外壳：桌面端自绘 chrome + 内嵌浮面，移动端标准单栏。
///
/// 桌面端（[WindowService.isSupported]）：
/// - 桌面外壳（2026-10-09 用户定，opencode 风"内嵌浮面"）：44 高全宽
///   [WindowStrip]——**四枚目的地图标（心流 / 全部 / 日历 / 收藏）精确几何居中**
///   （2026-10-11 用户定，靠 `center` 的 `Positioned.fill + Center`；左 `Expanded`
///   等分放历史键浮在「心流」左，不挤占导航位；设置钮在更右端紧贴最小化左——与窗控
///   成组）；窗控按钮在更右端；无分割线。**问笔记（AI）不是标题栏钮**——它 2026-10-11
///   起改为工作区右角折叠钮（见本文件工作区 [_RightRailToggleButton]）；左侧是扁平
///   导航 [HomeSidebar]（无折叠钮、常驻），AI 轨由这枚右角钮开合。
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
            // 标题栏不放导航（2026-10-12 用户定：取消左侧索引面板后，四枚目的地
            // + 新建胶囊搬到工作区左侧扁平导航 [HomeSidebar]）；上一步 / 下一步 的
            // UI 入口已撤——功能仍在全局键 `Alt+←/→`（`nav.back` / `nav.forward`）。
            // 问笔记（AI）是工作区右角折叠钮、不在条内。条内只剩：拖拽区 +
            // 最右 `trailing`（设置，紧贴最小化左，与窗控成组）+ 窗控按钮。
            // 拖拽带正中不放搜索入口（Ctrl+K 统一口径）。
            const WindowStrip(
              trailing: <Widget>[
                SettingsNavButton(),
              ],
            ),
            // 工作区：左 / 右 / 下各 4px 环缝，**顶部与标题条间距 0**
            //（2026-10-09 用户定）——浮面像从标题条下沿"长出来"，故卡片
            // 顶两角为直角（见 [_FloatingPanel]）；AI 打开时主卡 + 8 缝 + AI 卡（右
            // dock、推开内容）。左 dock 面板 2026-10-12 取消，主卡占满全宽。
            // 角落折叠钮（[_RightRailToggleButton]）浮在工作区之上、钉在内容卡内缘
            // 4px、y 与编辑器顶栏「标签」耳按钮同高；开合两态坐标不变
            //（2026-10-11 起：右角钮是 AI 面板唯一开合入口）。
            Expanded(
              // 左：扁平导航（无面板，贴窗口底）；右：内容浮面卡（4px 环缝内）。
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const HomeSidebar(),
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
                          // 右角折叠钮（AI）：唯一开合入口；开合两态坐标不变（2026-10-11）。
                          const Positioned(
                            // y 对齐编辑器顶栏「耳朵」带（标签所在那排）：32 高钮取 top 4
                            // ⇒ 中心 20，与耳朵中心（5 + 30/2 = 20）同高（2026-10-11 用户定）。
                            top: Tokens.spaceXs,
                            right: Tokens.spaceXs,
                            child: _RightRailToggleButton(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
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

/// 浮面卡统一圆角：包豪斯**全硬边留 4px**（[Bauhaus.radius]，2026-10-12 用户定）。
/// 主卡与 AI 卡共用，保证拼缝处半径一致。
const BorderRadius _kPanelRadius = Bauhaus.radius;

/// 工作区的**内嵌浮面卡**（2026-10-12 改包豪斯扁平）：[Bauhaus.surface] 实色 +
/// 4px 硬边 + 一圈 1px [Bauhaus.hairline] 发丝边，**无投影 / 无 bevel**；内容用
/// [ClipRRect] 裁进圆角，滚动条 / 铺底色块不会顶出方角。
///
/// 发丝边走 `foregroundDecoration` 画在内容**之上**：编辑器等子树会把底色铺到
/// 卡缘，普通 border 画在子层下面会被盖住。
class _FloatingPanel extends StatelessWidget {
  const _FloatingPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Brightness brightness = Theme.of(context).brightness;
    return Container(
      decoration: BoxDecoration(
        color: Bauhaus.surface(brightness),
        borderRadius: _kPanelRadius,
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: _kPanelRadius,
        border: Bauhaus.hairline(brightness),
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
    final Brightness brightness = Theme.of(context).brightness;
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
                // 包豪斯扁平：与主卡同款白面 + 发丝边 + 4px，无投影。
                decoration: BoxDecoration(
                  color: Bauhaus.surface(brightness),
                  borderRadius: _kPanelRadius,
                ),
                foregroundDecoration: BoxDecoration(
                  borderRadius: _kPanelRadius,
                  border: Bauhaus.hairline(brightness),
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
