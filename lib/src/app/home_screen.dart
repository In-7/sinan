import 'dart:async';
import 'dart:ui' as ui;

import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../canvas/canvas_switch.dart';
import 'app_menu.dart';
import '../command/commands.dart';
import '../domain/note.dart';
import 'app_icon_rail.dart';
import 'home_hub.dart';
import 'note_list_column.dart';
import '../editor/core/editor_switch.dart';
import '../notes/note_list_view.dart';
import 'ask_panel.dart';
import 'providers.dart';
import 'settings_panel.dart' show showSettingsPanel;
import 'stream_view.dart';
import '../theme/app_theme.dart';
import '../theme/noise_texture.dart';
import '../theme/tokens.dart';
import '../window/app_title_bar.dart';
import '../window/window_service.dart';

import '../domain/settings.dart';

/// 应用主外壳：桌面端自绘 chrome + 内嵌浮面，移动端标准单栏。
///
/// 桌面端（[WindowService.isSupported]）：
/// - 桌面外壳（2026-10-09 用户定，opencode 风"内嵌浮面"）：由
///   [Tokens.titleBarHeightMain] 定高（当前 **32**）的全宽 [WindowStrip]，仅含
///   拖拽带（可选应用名）+ 右端 `trailing` 设置钮（紧贴最小化左、与窗控成组）+
///   窗控按钮，**标题栏内不含导航**；导航（四枚目的地图标：心流 / 全部 / 日历 /
///   收藏 + 新建胶囊）落在最左 60 图标轨 [AppIconRail]（常驻脊梁、平铺窗口底）。
///   **问笔记（AI）是标题栏 `trailing` 钮**——2026-10-16 从工作区右角搬来，落在
///   设置右、最小化左；AI 轨由这枚钮开合（单一开合入口，其余入口走同一条
///   [aiPanelOpenProvider]）；无分割线。
/// - 条下 4px 环缝内是一张（AI 打开时两张并排）圆角 8 的浮面卡，
///   `AppTheme.panelFill` 实色、**无投影**（主页 / 编辑器同色，点进笔记不"变色"）：
///   立体感来自环缝露出的窗口底 vs 面板的明度差；描边按明暗分治——
///   **暗色零边框**（Linear 暗色语言），**亮色 1px 发丝边**（亮面与底只差
///   ~4 L\*，无边糊成一片；见 [_FloatingPanel]，2026-10-14 定）。
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
    // **不进新路由**（旧的 [NoteListView] 侧栏已删）。导航（四枚目的地图标 + 新建
    // 胶囊）2026-10-12 起落左侧导航（今为 [AppIconRail] 60 图标轨），标题栏只留
    // 拖拽带 + 设置钮 + 窗控；更早的 50 宽 `_AppIconRail`（2026-10-09 上午）、导航板
    // [HubNav]（2026-09-30）均已是历史。
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
      // 桌面统一布局（2026-09-25）：随 `selectedId` 切换主页（[CalendarPage]）/
      // 笔记·画布编辑器，不进新路由。
      //
      // 2026-10-09 用户定（opencode 风"内嵌浮面"，替代当日早上的 50 图标轨）：
      // 顶条由 [Tokens.titleBarHeightMain] 定高（当前 **32**）全宽——仅拖拽带 +
      // 右端 `trailing` 设置钮（紧贴最小化左、与窗控成组）+ 窗控按钮，**不含导航**
      // （四枚目的地图标 + 新建胶囊 2026-10-12 起移入左侧导航，今在最左 [AppIconRail]）；
      // 问笔记（AI）是顶条 `trailing` 钮（设置右、最小化左；2026-10-16 从工作区右角搬来）。
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
      // 列表列折叠态：标题栏最左折叠钮（Ctrl+B）手动折 + 窄窗自动折，合一显隐。
      // 窄窗（< [Tokens.noteListBreakpoint]）强制收起列表、把宽度让给编辑器；切笔记走
      // Ctrl+K 搜索面板（列表收起时也能跳）。
      final bool narrow =
          MediaQuery.sizeOf(context).width < Tokens.noteListBreakpoint;
      final bool listCollapsed =
          narrow || ref.watch(listCollapsedProvider);

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

      // 主从布局（2026-10-16 Option 2 进卡）：60 轨常驻（唯一平铺窗口底的脊梁，不折叠）；
      // 轨右边一张浮面卡，卡内两格 = [列表列 ┃ 详情]。列表列可折叠（标题栏最左折叠钮 /
      // Ctrl+B，走 [listCollapsedProvider]）——折叠时编辑器占满卡。日历视图例外：
      // 隐藏列表、卡整屏显示日历。详情实例只取一次 ⇒ 折叠动画每帧只重排 ClipRect 宽、
      // 不重建昂贵的编辑器子树（最简性能）。
      final Brightness brightness = Theme.of(context).brightness;
      final HomeView view = ref.watch(
        navHistoryProvider.select((NavHistoryState s) => s.view),
      );
      final Widget detail = detailPane();
      final bool isDark = brightness == Brightness.dark;
      final Widget cardChild = switch (view) {
        // **速记（心流）**：一页纸流，**不走主从布局**。
        // 速记没有"详情页"——右侧没有可展示的东西，240 列表列在这里只会与
        // 速记自己的时间流打架（2026-10-17 用户实报"打开没有任何变化"：
        // 速记页当年挂在日历页（原名 HomeHub）的 timeline 分支里，而新外壳
        // 早已改走 NoteListColumn ⇒ 那份实现成了孤儿。现在由外壳直接挂载）。
        HomeView.timeline => const StreamView(),
        // 日历：列表列无意义，整卡显示日历（选中某篇后仍出详情）。
        HomeView.calendar =>
          selectedId == null ? const CalendarPage() : detail,
        // 全部 / 收藏：主从（240 列表列 + 详情）。
        HomeView.all ||
        HomeView.favorites => TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 1.0, end: listCollapsed ? 0.0 : 1.0),
          duration: Tokens.durationNormal,
          curve: Curves.easeInOutCubic,
          builder: (BuildContext context, double t, Widget? _) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // 列表列：宽 noteListWidth×t，本体钉 noteListWidth（OverflowBox 不塌缩）、
                // ClipRect 从右裁；收起按**布尔**移出焦点 / 读屏。
                ExcludeFocus(
                  excluding: listCollapsed,
                  child: ExcludeSemantics(
                    excluding: listCollapsed,
                    child: ClipRect(
                      child: SizedBox(
                        width: Tokens.noteListWidth * t,
                        child: const OverflowBox(
                          alignment: Alignment.centerLeft,
                          minWidth: Tokens.noteListWidth,
                          maxWidth: Tokens.noteListWidth,
                          child: NoteListColumn(),
                        ),
                      ),
                    ),
                  ),
                ),
                // 列表↔详情发丝：贴列表右缘并随 t 淡出（颜色 alpha，不用 Opacity）。
                Container(
                  width: 1,
                  color: Bauhaus.ink(brightness)
                      .withValues(alpha: (isDark ? 0.16 : 0.14) * t),
                ),
                Expanded(child: detail),
              ],
            );
          },
        ),
      };

      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // 标题栏不放导航（2026-10-12 用户定：四枚目的地 + 新建胶囊在最左
            // [AppIconRail] 图标轨）；**上一步 / 下一步 2026-10-15 加回
            // 条内左端**（`leading`，左缘与内容卡对齐）。
            // 问笔记（AI）是条内 `trailing` 钮（设置右、最小化左，2026-10-16 搬入）；
            // 条内只剩：拖拽区 + 最右 `trailing`（问笔记 + 设置，紧贴最小化左，与窗控成组）
            // + 窗控按钮。
            // 拖拽带正中不放搜索入口（Ctrl+K 统一口径）。
            WindowStrip(
              // 最左缘：折叠 / 展开**列表列**（2026-10-16 起；60 轨常驻不折）。
              // 速记页没有列表列 ⇒ 这一视图里不出现折叠钮（否则按了什么都不动）。
              leadingEdge: view == HomeView.timeline
                  ? null
                  : const SidebarCollapseButton(),
              leading: _historyNavButtons(context, ref),
              // 左簇左缘与内容卡对齐 = 折叠钮 + (railWidth − chromeButtonSize) ⇒ 落在
              // 60 轨右缘。速记页没有折叠钮 ⇒ 那 32 由 inset 自己让出，仍然对齐 60。
              leadingInset: view == HomeView.timeline
                  ? Tokens.railWidth
                  : Tokens.railWidth - Tokens.chromeButtonSize,
              // 问笔记（AI）开合钮始终露出（设置右、最小化左）；未配 AI 时点按由
              // `ai.ask` 命令兜底报错，同原工作区右角钮口径。
              trailing: const <Widget>[
                SettingsNavButton(),
                _AskTitleBarButton(),
              ],
            ),
            // 工作区：浮面卡**右 / 下各 4px 环缝**（顶与左 0——2026-10-15 用户定），
            // 四角 8px 圆角；AI 打开时主卡 + 8 缝 + AI 卡（右 dock、推开内容）。
            // 左 dock 面板 2026-10-12 取消，主卡占满全宽。
            // 问笔记（AI）开合入口 2026-10-16 从工作区右角搬进顶条 `trailing`
            // （设置右、最小化左）；工作区不再浮角钮。开合仍走 [aiPanelOpenProvider]
            // 单布尔，呈现形态归外壳按宽度选（宽窗常驻右轨 / 窄窗降级浮层）。
            Expanded(
              // 左：扁平导航（无面板，贴窗口底）；右：内容浮面卡（4px 环缝内）。
              //
              // ⚠️ 焦点顺序必须按**控件树**走：默认的 ReadingOrder 策略按**几何位置**
              // 排序 ⇒ 侧栏与内容区会**交错**（实测：心流→全部→日历→卡片乙→收藏→
              // 卡片甲），读屏/键盘用户会在导航和内容间乱跳。改成 WidgetOrder 后是
              // 侧栏（新建→笔记→画布→四视图）→ 内容区。
              child: FocusTraversalGroup(
                policy: WidgetOrderTraversalPolicy(),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    // 60 图标轨：常驻脊梁，平铺窗口底，不折叠。
                    const AppIconRail(),
                    Expanded(
                      child: Padding(
                        // 环缝：**顶 1px / 左 0 / 右 4 / 底 4**（2026-10-15 用户定；
                        // 顶由 2 降到 1）。顶这道缝给卡的外扩亮线留落脚位——0 会让线
                        // 压到标题栏最后一行（读作"重叠"，用户实报过），1 正好够。
                        // 左缝 0：卡左缘贴 60 轨右界，外扩亮线落在轨那一列像素上。
                        padding: const EdgeInsets.fromLTRB(
                          0,
                          AppTheme.surfaceRingRetreat,
                          Tokens.appPanelInset,
                          Tokens.appPanelInset,
                        ),
                        child: Stack(
                          children: <Widget>[
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                Expanded(
                                  child: _FloatingPanel(child: cardChild),
                                ),
                                _AiRailSlot(open: aiInline),
                              ],
                            ),
                          ],
                        ),
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
  List<Widget> _chromeActions(BuildContext context, WidgetRef ref) => <Widget>[
    ..._sidebarActions(context, ref),
    const AppMenuButton(),
  ];

  /// 标题栏**左簇**：上一步 / 下一步（2026-10-15 用户定加回条内，左缘由
  /// [WindowStrip.leadingInset] 推到与内容卡对齐）。
  ///
  /// 两条纪律：
  /// 1. 走**命令层**（`nav.back` / `nav.forward`）而不是就地调 notifier——按钮与
  ///    `Alt+←/→` 必须是同一条路（§3.2 命令是权威面）；
  /// 2. 可用态取 [navHistoryProvider] 的 `canGoBack` / `canGoForward` 置灰
  ///    （命令自身在栈空时是 no-op，置灰只是反馈；且**禁用态不进 Tab 链**，
  ///    启动时两枚都灰 ⇒ 不改变既有的焦点顺序）。
  List<Widget> _historyNavButtons(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final NavHistoryState nav = ref.watch(navHistoryProvider);
    final AppSettings settings = ref.watch(settingsProvider);
    final Color? seed = settings.themeSeed == 0
        ? null
        : Color(settings.themeSeed);
    // 条内图标吃 onChrome（按 chrome 明度翻转的墨色）；⚠️ [CustomIcons] 是裸
    // SVG 资产、不读 IconTheme ⇒ 必须显式传色，不传就是死黑。
    final Color onChrome = AppTheme.onChrome(seed, theme.brightness);
    // 不可用态 = 同字形淡出到 0.38（[AppTheme.disabledInk]，VS Code / Chrome /
    // Finder 的 back·forward 口径：置灰不隐藏、几何稳定）。⚠️ 必须显式换色——
    // `onPressed: null` 只禁点击，SVG 不吃 disabledForegroundColor。
    final Color backInk = nav.canGoBack
        ? onChrome
        : AppTheme.disabledInk(onChrome);
    final Color forwardInk = nav.canGoForward
        ? onChrome
        : AppTheme.disabledInk(onChrome);
    return <Widget>[
      IconButton(
        tooltip: '上一步（Alt+←）',
        onPressed: nav.canGoBack
            ? () => unawaited(runCommandById(ref, 'nav.back'))
            : null,
        icon: tabler.ArrowLeft(
          height: Tokens.iconMdSm,
          width: Tokens.iconMdSm,
          colorFilter: ui.ColorFilter.mode(backInk, ui.BlendMode.srcIn),
        ),
      ),
      IconButton(
        tooltip: '下一步（Alt+→）',
        onPressed: nav.canGoForward
            ? () => unawaited(runCommandById(ref, 'nav.forward'))
            : null,
        icon: tabler.ArrowRight(
          height: Tokens.iconMdSm,
          width: Tokens.iconMdSm,
          colorFilter: ui.ColorFilter.mode(forwardInk, ui.BlendMode.srcIn),
        ),
      ),
    ];
  }
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

/// 浮面卡统一圆角：内面板 **10px**（2026-10-15 用户定；8 → 10，比默认
/// [Bauhaus.radius] 的 4px 更舒展）；主卡与 AI 卡共用，保证拼缝处半径一致。
const BorderRadius _kPanelRadius = BorderRadius.all(
  Radius.circular(Tokens.radiusMd),
);

/// 工作区的**内嵌浮面卡**（2026-10-14 统一到 surface_ladder 的 panel 档）：
/// [AppTheme.panelFill] 实色 + 8px 硬角，**无投影 / 无 bevel**；内容用
/// [ClipRRect] 裁进圆角，滚动条 / 铺底色块不会顶出方角。
///
/// 📌 底色**必须走 panelFill**（不再 Bauhaus.surface）：画布页
/// （`canvas_surface`）早就涂这一档，两处不同色 ⇒ 切笔记类型时卡片"变色"。
///
/// 描边按明暗分治（2026-10-14，与新建胶囊同规则）：
/// - **暗色不画边**：4px 环缝露出窗口底 + 面板对底的明度差已足够分层，
///   Linear 暗色语言 = 零边框；
/// - **亮色留 1px 发丝边**：亮 panel 与窗口底只差约 4 L\*，去边会糊成一片。
///
/// 📌 2026-10-15 起**暗色内容区也是浮面**（不垫的凹陷已废）：阶梯两侧单调向上
/// （底最深 → 面板 → 卡片 → 浮层），与 Linear 一致。
///
/// 亮色边仍走 `foregroundDecoration` 画在内容**之上**：编辑器等子树会把底色
/// 铺到卡缘，普通 border 画在子层下面会被盖住。
class _FloatingPanel extends StatelessWidget {
  const _FloatingPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Brightness brightness = Theme.of(context).brightness;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.panelFill(brightness),
        borderRadius: _kPanelRadius,
        // 发丝环（外扩 1px：**不占布局、不会被子级盖住**；无 blur、无 saveLayer）。
        // ⚠️ 明暗**同规则**（不再分治）：暗色零边那条 2026-10-15 已废——
        // 立体感 = 明度阶梯 + 这圈环 + 圆角，**不加柔影**（暗色黑影无对比度）。
        boxShadow: AppTheme.surfaceRing(brightness),
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
              child: DecoratedBox(
                // 与主卡同款：panelFill 实面 + 8px 硬角 + 发丝环（同
                // [AppTheme.surfaceRing]，见 [_FloatingPanel]），无柔影。
                decoration: BoxDecoration(
                  color: AppTheme.panelFill(brightness),
                  borderRadius: _kPanelRadius,
                  boxShadow: AppTheme.surfaceRing(brightness),
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

/// 顶条右簇的「问笔记（AI）」开合钮：2026-10-16 用户定从工作区右角搬来，落在
/// `trailing` 的设置之后、最小化之前。仍是 AI 面板（[AskRail]）的**唯一**开合入口，
/// 始终露出（未配 AI 时点按由 `ai.ask` 命令兜底报错，同原右角钮口径）；开态披中性 tint。
class _AskTitleBarButton extends ConsumerWidget {
  const _AskTitleBarButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool open = ref.watch(aiPanelOpenProvider);
    return IconButton(
      icon: const tabler.Sparkles(
        height: Tokens.iconMd,
        width: Tokens.iconMd,
        strokeWidth: 1.5,
      ),
      tooltip: '问笔记（Ctrl+J）',
      style: IconButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Tokens.radiusButton),
        ),
        minimumSize: const Size.square(Tokens.chromeButtonSize),
        maximumSize: const Size(
          Tokens.chromeButtonSize + 8,
          Tokens.chromeButtonSize,
        ),
        padding: EdgeInsets.zero,
        iconSize: Tokens.iconMd,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: open
            ? AppTheme.navSelectedTint(scheme.onSurface)
            : Colors.transparent,
      ),
      onPressed: () => unawaited(runCommandById(ref, 'ai.ask')),
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

/// 标题栏**最左缘**的「折叠 / 展开**列表列**」钮（2026-10-16 起改折卡内列表列；60 轨
/// 常驻不折）。点按切 [listCollapsedProvider]——本钮与 [HomeScreen] 卡内列表列
/// 共用这一个布尔（单一真相源）。
///
/// 窄窗（< [Tokens.noteListBreakpoint]）时列表被强制收起（见 [HomeScreen]）⇒ 钮置灰、
/// 给一句实话；宽窗才可手动折 / 展。
///
/// 不着色：标题栏 [WindowStrip] 已套 IconTheme(onChrome)，tabler 经 AppIconTheme
/// 桥接继承（同 [SettingsNavButton]）。
class SidebarCollapseButton extends ConsumerWidget {
  const SidebarCollapseButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool narrow =
        MediaQuery.sizeOf(context).width < Tokens.noteListBreakpoint;
    final bool collapsed = narrow || ref.watch(listCollapsedProvider);
    return IconButton(
      icon: const tabler.LayoutSidebar(
        height: Tokens.iconMdSm,
        width: Tokens.iconMdSm,
        strokeWidth: 1.5,
      ),
      tooltip: narrow
          ? '放宽窗口可展开列表'
          : (collapsed ? '展开列表' : '收起列表'),
      onPressed: narrow
          ? null
          : () => ref.read(listCollapsedProvider.notifier).toggle(),
    );
  }
}
