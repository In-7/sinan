import 'dart:async';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import 'package:flutter_riverpod/flutter_riverpod.dart';import 'package:material_ui/material_ui.dart';

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
import '../theme/app_theme.dart';
import '../theme/noise_texture.dart';
import '../theme/tokens.dart';
import '../window/app_title_bar.dart';
import '../window/window_service.dart';

import '../domain/settings.dart';

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

    // ★ §5.6 阶段 2：**未选中 = 主页**（全窗口 Mica + 卡片入口分区）；选中 = 笔记 /
    // 画布页。同一个 `selectedNoteIdProvider` 驱动，不新增页面栈——切换，不是叠加。
    if (WindowService.isSupported && selectedId == null) {
      return Scaffold(
        // 主页的底就是窗口 Mica ⇒ Flutter 侧不铺任何底（见 [HomeHub] 的说明）。
        backgroundColor: Colors.transparent,
        // 导航板**铺满左侧**：上 / 左 / 下**不与窗口留缝**（2026-09-22 用户定，
        // 取代原先"三方各 6px"）⇒ 它是贴着窗口三边的**通高列**，不再是"浮在窗口里
        // 的一块板"（因此不再是四方圆角，见 [HubNav]）。
        // ⚠️ 顶条只管右半（拖拽 + 窗控），应用名不占主页顶条 ⇒ 板的上缘就是窗口顶。
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const HubNav(),
            Expanded(
              child: Column(
                children: <Widget>[
                  const WindowStrip(
                    trailing: <Widget>[
                      AppMenuButton(iconSize: 20, captionStyle: true),
                    ],
                  ),
                  // 内容区**不铺任何层**（与导航一致：直接坐窗口底）。0 号分区是
                  // 主页（[HomeHub]，Bento 卡片格）；其余分区给"还没建"的明示——
                  // 否则点了像没反应。接新页面：按 `hubNavSelectionProvider` 的
                  // index 在这里分发。
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Consumer(
                        builder:
                            (BuildContext context, WidgetRef ref, Widget? _) {
                              final int section = ref.watch(
                                hubNavSelectionProvider,
                              );
                              if (section == 0) {
                                return const HomeHub();
                              }
                              return _SectionPlaceholder(
                                label: hubNavItems[section].label,
                              );
                            },
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
      final List<Widget> sidebarActions = _sidebarActions(context, ref);
      // 标题栏里的菜单图标尺寸对齐窗控，且点击区/悬停与窗控完全一致。
      const Widget menu = AppMenuButton(iconSize: 20, captionStyle: true);

      if (isWide) {
        return Scaffold(
          // 窗口底**不在这里铺**：它由 `main.dart` 的 `MaterialApp.builder`
          // 统一铺一层纯色（`AppTheme.windowBackground`，亮 #F8F8F6 / 暗 #171715）
          // ⇒ 这里保持透明让它透出来（2026-09-22 取消窗口材质后就是这么分工的）。
          // 那层底可直接承载列表文字（对比度有测试钉着）；
          // 只有内容层（编辑区纸面）才是不透明的。
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
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      // 纸面噪点（暗 2% / 亮 0）：铺在**纸色之上、内容之下**，
                      // 见 [_PaperNoise] 的三条理由。
                      _PaperNoise(brightness: Theme.of(context).brightness),
                      Column(
                        children: <Widget>[
                          WindowStrip(
                            // 回主页：走 `locateProvider.goHome()`（写选中态的唯一通道）。
                            leading: <Widget>[
                              IconButton(
                                icon: tabler.TextDirectionLtr(height: 24, width: 24, strokeWidth: 1.5),
                                tooltip: '主页',
                                onPressed: () =>
                                    ref.read(locateProvider.notifier).goHome(),
                              ),
                            ],
                            trailing: const <Widget>[menu],
                          ),
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

      // 窄桌面兜底（最小窗宽即 720，正常不可达）：整宽一条
      // （动作 + 应用名 + 拖拽 + 窗控）+ 列表/编辑二选一。
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Column(
          children: <Widget>[
            WindowStrip(
              leading: <Widget>[
                IconButton(
                  icon: tabler.TextDirectionLtr(height: 24, width: 24, strokeWidth: 1.5),
                  tooltip: '主页',
                  onPressed: () => ref.read(locateProvider.notifier).goHome(),
                ),
                ...sidebarActions,
              ],
              trailing: const <Widget>[menu],
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
  List<Widget> _sidebarActions(BuildContext context, WidgetRef ref) => <Widget>[
    // 走命令层而不是就地调 notifier：按钮与 `Ctrl+N` 必须是**同一条路**
    // （§3.2 命令是权威面）——各留一份实现迟早漂移成"按钮能建、快捷键不能"。
    IconButton(
      icon: tabler.Plus(height: 24, width: 24, strokeWidth: 1.5),
      tooltip: '新建笔记',
      onPressed: () => unawaited(runCommandById(ref, 'note.new')),
    ),
    IconButton(
      icon: tabler.Search(height: 24, width: 24, strokeWidth: 1.5),
      tooltip: '搜索（开发中）',
      onPressed: () {},
    ),
    // 问笔记（AI 问答）：**没配就不露出入口**——点了只会得到一句报错，
    // 与「设置 → AI」默认关闭是同一口径（见 AppSettings.aiEnabled 的说明）。
    if (_aiReady(ref))
      const IconButton(
        icon: tabler.Sparkles(height: 24, width: 24, strokeWidth: 1.5),
        tooltip: '问笔记',
        onPressed: showAskPanel,
      ),
    // 新建画布笔记（[NoteKind.canvas]）：建好即选中，右栏直接出画布。
    // 不再是"全屏路由的实验页"——画布已与块编辑器同页共存。
    IconButton(
      icon: tabler.Crop(height: 24, width: 24, strokeWidth: 1.5),
      tooltip: '新建画布',
      onPressed: () => unawaited(runCommandById(ref, 'canvas.new')),
    ),
  ];

  /// 「问笔记」入口是否可用：AI 开关打开 **且** 对话模型名已填。
  ///
  /// 嵌入模型**不**作为门槛：没填它只是退化成纯关键词检索（6.4 的降级），
  /// 问答照样可用。
  bool _aiReady(WidgetRef ref) {
    final AppSettings settings = ref.watch(settingsProvider);
    return settings.aiEnabled && settings.aiModel.trim().isNotEmpty;
  }

  /// 移动端 AppBar 动作：新建 + 搜索 + 主菜单。
  List<Widget> _chromeActions(BuildContext context, WidgetRef ref) => <Widget>[
    ..._sidebarActions(context, ref),
    const AppMenuButton(),
  ];
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
          child: Stack(
            fit: StackFit.expand,
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

/// **纸面噪点**：一层极淡颗粒，铺在**纸色之上、内容之下**
/// （强度见 [AppTheme.paperNoiseAlpha]：暗 `2%` / 亮 `0` ⇒ 亮的直接不挂）。
///
/// ## 为什么必须夹在"纸色与内容之间"（三条，缺一条就白挂）
/// 1. **铺到内容之上** ⇒ 颗粒糊在字上，文字边缘被打散，比不铺更糟；
/// 2. **铺到纸色之下**（例如挂在 `main.dart` 的 builder 那层底上）⇒ 纸面**不透明**，
///    直接把噪点整块盖住，等于没挂；
/// 3. **圆角面板要一起裁**（[clipRadius]）⇒ 否则四角露出方形颗粒，一眼是 bug。
///
/// ## ⚠️ 它是**纯审美**，不治任何东西
/// 纸面是纯色 ⇒ **没有色带**（色带是渐变的产物；而独立噪点图层也治不了渐变的色带，
/// 2026-09-22 实测过）。所以唯一的理由是"纸感"——暗色下更能破掉纯黑的死板。
/// **代价**：纸面就是阅读面，颗粒直接铺在字下面（字本身不糊，但字周的局部对比被削
/// 一档）⇒ 上限压到 2%，比窗口底那档（≤5%）更保守。
class _PaperNoise extends StatelessWidget {
  const _PaperNoise({required this.brightness, this.clipRadius});

  final Brightness brightness;

  /// 内层裁切半径（圆角面板传它；直角页面不传）。
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
  Widget build(BuildContext context) => const Center(
        child: Text('选择左侧笔记，或新建一条'),
      );
}

/// 占位分区的内容：诚实地说明"还没建"，而不是让人以为点了没反应。
///
/// 接真实页面时删掉这个类，在 `Consumer` 的分发处直接建对应页面。
class _SectionPlaceholder extends StatelessWidget {
  const _SectionPlaceholder({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('「$label」还没建', style: theme.textTheme.titleMedium),
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
