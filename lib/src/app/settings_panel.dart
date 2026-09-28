import 'dart:async';
import 'dart:ui' as ui;
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/settings.dart';
import 'app_info.dart';
import 'providers.dart';
import '../theme/app_float_surface.dart';
import '../theme/app_theme.dart';
import '../theme/focus_ring.dart';
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

  Widget get icon => switch (this) {
    _SettingsSection.appearance => const tabler.Palette(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
    _SettingsSection.editor => const tabler.Pencil(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
    _SettingsSection.ai => const tabler.Sparkles(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
    _SettingsSection.about => const tabler.InfoCircle(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
  };
}

/// 遮罩**颜色**的浓度。现值 **0 = 不压暗**（2026-09-22 用户定）。
///
/// ## 这里有两件事，别混
/// 1. **手势层**（`_SettingsOverlay` 里那层 `Positioned.fill` + `GestureDetector`）：
///    **必须有**——它负责"点面板外面关闭"，还挡住误点到背后控件。去掉它，
///    桌面端用户点外面**毫无反应**，像卡死。
/// 2. **压暗的颜色**：**可以不要**——本常量就是它，现在为 `0`（那层只剩行为、没有像素）。
///    压暗原本承担"聚焦 + 帮面板浮起"；取消后**面板浮起要由自己承担**（三件套，
///    或轻拟态的底差 / 光影 / 内边）。
///
/// ⚠️ **公开**（不是私有 `_`）：早期体检表拿"遮罩压在最坏内容上"当面板的合成底算过
/// 对比度，那个值必须与这里同源。
/// 📌 **现在体检表不再用它**（2026-09-22 面板改成**实色** ⇒ 背后那层影响不到面板，
/// 闸门按"面板色 + 光泽顶端"算就够）。保留公开、并在手势层里取它，是因为浓度随时
/// 可能被调回去——**调回去时体检表要跟着改回带遮罩的算式**。
/// 📌 **它曾经是承重的**：面板底还是半透（α 0.88）时，暗色下副标题靠这 0.4 遮罩才从
/// "不遮罩的 −55.2"回到 −61.7（过 60 档）。
const double settingsScrimAlpha = 0;

/// 弹出设置面板：悬浮卡片 + 背后半透明遮罩，**非模态路由**。
///
/// 与 showDialog（PopupRoute）的关键差异——本实现是 Overlay：
/// - 背后的主界面**保持渲染且实时响应**设置变化（改宽度/字号/主题
///   当场看到效果），这是"设置页能看到页面内容变化"的实现基础；
/// - 不用路由栈，不影响导航历史。
///
/// 关闭：右上角 ✕ / 点遮罩 / Esc。
Future<void> showSettingsPanel() {
  // 不接 context：触发处可能在 MaterialApp 之上（见 appNavigatorKey 的说明），
  // 也可能根本没有 context（命令层只能给不可变数据，见 command/command.dart 的
  // CommandContext），一律走导航根。
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

  /// 面板自己的**作用域**节点：打开时接管焦点，同时它就是 Tab 的**边界**。
  ///
  /// 为什么不能只靠 Esc 的全局 handler：那个拦得住 Esc，**拦不住 Tab**。
  /// 面板打开时焦点还留在编辑器（编辑器 `autoFocus: true`）⇒ 按 Tab 只是在
  /// 编辑器所在的作用域里转，面板里"按了毫无反应"（2026-09-21 用户实报）。
  ///
  /// 为什么要**作用域**节点而不是普通 `FocusNode`：Tab 的边界由 `nearestScope`
  /// 决定（SDK `FocusTraversalPolicy._moveFocus`），而作用域节点**不在** Tab 序列
  /// 里——它是"进第一个控件的入口"。用普通节点的话，绕回到头时会多出一格落在
  /// 面板本身、**没有焦点环的空档**。
  final FocusScopeNode _panelScope = FocusScopeNode(
    debugLabel: 'settings.panel',
  );

  @override
  void initState() {
    super.initState();
    // ⚠️ 用显式 `requestFocus()` 而不是 `Focus(autofocus: true)`：面板挂在
    // `navigator.overlay` 上，`autofocus` 只在"所属作用域内没有已聚焦节点"时才
    // 生效，而路由内的编辑器已经占着焦点 ⇒ 不保证生效。`requestFocus()` 可以
    // 跨作用域搬焦点（命令面板的输入框用的就是这条，已实测）。
    // 延到帧后：本 State 刚建、节点还没 attach，当场 request 无效。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _panelScope.requestFocus();
    });
  }

  @override
  void dispose() {
    _panelScope.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    return Stack(
      children: <Widget>[
        // 手势层：点击关闭（点卡片内不触发——卡片在其上层且吸收事件）。
        // ⚠️ 它是**行为**，不是视觉：颜色浓度由 [settingsScrimAlpha] 给，现在是 **0**
        // （2026-09-22 用户定"不要压暗"）⇒ 这一层只剩"点外关闭 + 挡住误点"。
        // 别因为"看不见"就把它删了——删掉就是"点外面没反应"。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
            child: FadeTransition(
              opacity: _fade,
              child: ColoredBox(
                // 用 M3 的 scrim **色角色**而不是 `Colors.black`：默认值就是黑，
                // 观感不变，但不再是硬编码色（换主题时 scrim 若被定制会跟着走）。
                color: Theme.of(context).colorScheme.scrim
                    .withValues(alpha: settingsScrimAlpha),
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
                  // Tab 顺序 = 视觉顺序（§5.2）。
                  child: FocusTraversalGroup(
                    // ⚠️ 圈住 traversal 的是**这个作用域**，不是上面的 group：
                    // SDK 里 `_moveFocus` 取 `nearestScope`，再
                    // `_sortAllDescendants(scope, …)` **只收该作用域的子孙**，走到
                    // 末尾按 `traversalEdgeBehavior`（默认 `closedLoop`）绕回本作用域
                    // 第一个。`FocusTraversalGroup` 只管**顺序**、不管边界——只加它
                    // 的话，Tab 走出最后一个控件就进了遮罩背后的主界面
                    // （2026-09-21 用户实报，那里几乎没人有焦点环，看起来像"没反应"）。
                    child: FocusScope(
                      node: _panelScope,
                      child: _SettingsCard(onClose: widget.onClose),
                    ),
                  ),
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
      const _AiEmbeddingModelRow(),
      const _BuildIndexRow(),
    ],
    // 「关于」是设置页的固定分区（Win11 / macOS 系统设置都有）：应用信息、
    // 开源许可、数据目录。除了许可页本身，内容都是几行 `ListTile` ——
    // M3 没有专门的"关于"组件，官方口径就是 lists。
    _SettingsSection.about => <Widget>[_AboutSection(onClose: widget.onClose)],
  };

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final Brightness brightness = Theme.of(context).brightness;

    // ## 底 = **实色** [AppTheme.floatSurface] + 玻璃光泽（与关于面板同一档）
    // 2026-09-22 用户定：两处面板**统一**成这一档（此前是 A/B 对照：设置 = 半透 0.98、
    // 关于 = 实色，实测两者只差 1~3 Lc、肉眼不可分 ⇒ 对照已无意义，只留一个）。四件别随手改：
    //
    // ① 底 = [AppTheme.floatSurface]（实色）。这里曾有一档 `panelFill`（0.80 → 0.88 →
    //    0.98，半透），删掉的理由见 `app_theme.dart` 里那段"面板"区块注释：**面积大 +
    //    不开模糊** ⇒ 鬼影既大又清晰，收到 0.98 时已与实色无差别。
    //    再往前这里是**不透明**的 `scheme.surfaceContainerHigh`（实测带种子色相：
    //    亮 `#E3E9E9` / 暗 `#242B2B`，与本文件头部"大面不染种子色"冲突）——换掉它
    //    另有两条老账：主菜单进浮层族后，"内容面板"该与它同族。
    // ② `glass: true` = 内光泽 + 顶沿光边。**这是面板现在唯一的"玻璃感"来源**
    //    （亮色下"透"本来就只差 1~2 级，见 [AppTheme.menuLayerAlpha] 的注释实测）。
    // ③ `blur` **留默认 `false`**（刻意，不是省略：写 `blur: false` 会撞
    //    `avoid_redundant_argument_values`，测试里有闸门）。成本 ∝ 面积 × 重绘次数，
    //    而拖字号 / 行高滑杆时背后**每帧重绘** ⇒ 那块滤镜要每帧重算。换来的是"背后
    //    内容清晰可辨"——正是本面板"改设置时能看见背后实时变化"的设计初衷。
    //    🔧 要开回来先按 [AppTheme.floatBlurSigma] 实测（profile + `F9` 看 p90）。
    // ④ 描边 + 双层投影由容器自带（浮层三件套），别另加。
    //
    // ⚠️ 合成色：**底是实色 ⇒ 背后是什么都影响不到面板**（遮罩浓度 `settingsScrimAlpha`
    //   也已归 0，见其说明）⇒ 面板上的对比度只由"面板色 + 光泽"决定。
    //   实测：底 `#FFFFFF` / `#2F2F2F`，**光泽顶端**（白 5%）`#FFFFFF` / `#464646`
    //   ⇒ 面板上 `onSurface` Lc **104.3 / −80.8**、`onSurfaceVariant` **93.4 / −62.1**
    //   （体检表"玻璃面板 光泽顶端"两行钉着）。
    //   📌 闸门按**顶端**算：光泽最亮的地方正是**标题栏**所在；标题之下只会更暗。
    //   ⚠️ 暗色的 −62.1 是**钳制出来的**（`onSurfaceVariant` 钳到 60 档，
    //   参考底 = [AppTheme.lightestDarkSurface]）⇒ 它就该贴着档位，不是"余量不足"。
    return AppFloatSurface(
      glass: true,
      color: AppTheme.floatSurface(brightness),
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
                    icon: const tabler.X(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
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

/// 目录导航项：选中态走 §5.1 的统一读法——**中性 tint 底 + 3px primary 左指示条 +
/// 字重 w600**。此前是 M3 的 `secondaryContainer`（带种子色的底）：同一个设置面板里，
/// 左导航与分段控件曾各画各的"选中"。
class _NavTile extends StatefulWidget {
  const _NavTile({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final _SettingsSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_NavTile> createState() => _NavTileState();
}

class _NavTileState extends State<_NavTile> {
  /// 焦点环要观察的节点——**同一个节点也要交给 InkWell**（见 [FocusRing] 的
  /// 说明：环必须跟着控件自己的节点，不能用"祖先探针"）。
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

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
        selected: widget.selected,
        // 焦点环跟的是 **InkWell 自己的节点**（`_focus`）：不能用"祖先探针"，
        // 实测那个在焦点移到别的控件时不回调（见 [FocusRing] 的说明）。
        child: FocusRing(
          focusNode: _focus,
          borderRadius: BorderRadius.circular(Tokens.radiusSm),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(Tokens.radiusSm),
              focusNode: _focus,
              onTap: widget.onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(
                  horizontal: Tokens.spaceMd,
                  vertical: Tokens.spaceSm + 2,
                ),
                decoration: BoxDecoration(
                  color: widget.selected
                      ? AppTheme.navSelectedTint(scheme.onSurface)
                      : null,
                  borderRadius: BorderRadius.circular(Tokens.radiusSm),
                ),
                // 左指示条走 `foregroundDecoration`（**不占位**）：写进 `border`
                // 会让内容在选中/未选中之间横移 3px——"文字跳一下"是最容易被忽略的
                // 粗糙感（编辑器跳转闪烁块用同一个手法）。
                foregroundDecoration: widget.selected
                    ? BoxDecoration(
                        borderRadius: BorderRadius.circular(Tokens.radiusSm),
                        border: Border(
                          left: BorderSide(
                            color: AppTheme.navIndicator(scheme),
                            width: Tokens.indicatorWidth,
                          ),
                        ),
                      )
                    : null,
                child: Row(
                  children: <Widget>[
                    widget.section.icon,
                    const SizedBox(width: Tokens.spaceSm),
                    Text(
                      widget.section.label,
                      style: text.bodyMedium?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: widget.selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ],
                ),
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

/// 弹出「关于」：**玻璃浮层**（自绘，2026-09-22 定）。
///
/// ## 为什么不走框架原生 [showAboutDialog] 了
/// 它的面板 Material 在 `_DialogRoute` **内部**，外面**插不进**任何自绘层；而
/// `showAboutDialog` 本身**没有 `builder` 参数**（SDK 签名里查过）⇒ 想给面板加
/// 模糊 / 内光泽都无处下手。现在面板由 [_AboutPanel] 自绘。
/// 它原来的两件好处照旧保留：
/// - **版本号有位置**；
/// - **「查看许可」入口** → [LicensePage]（把 `LicenseRegistry` 里全部依赖的许可
///   收集成可搜索列表，要自己做得遍历整棵依赖树）。
///
/// ⚠️ 面板底色**整个让给 [AppFloatSurface]**（`Dialog` 自己透明、elevation 0）：
/// 跟着 `dialogTheme` 走的话，框架那层不透明 Material 会盖住自绘的底与光泽。
///
/// ⚠️ 返回 `void`（不是 `Future`）：调用方是菜单项，按完就收菜单、不该 await
/// 对话框关闭（`app_menu.dart` 的 `pick`）。
void showAboutPanel(BuildContext context) {
  // `unawaited`：本函数刻意不返回 Future（见上），但 `showDialog` 会返回一个
  // 关闭才 complete 的 Future ⇒ 不接就会撞 `discarded_futures`。
  unawaited(
    showDialog<void>(
      context: context,
      // ⚠️ **不压暗**（2026-09-22 用户定）：默认的 `Colors.black54` 会把整屏压暗，
      // 而设置面板那层遮罩浓度已归 0 ⇒ 两处面板**背后的处理也必须一致**，
      // 否则"同款面板"在两种幕布上观感差得比材质本身还大。
      // 📌 屏障**仍在**（只是不带颜色）：点外面关闭、挡住误点，行为与默认完全一样。
      barrierColor: Colors.transparent,
      builder: (BuildContext _) => const Dialog(
        backgroundColor: Colors.transparent,
        // elevation 归零有两层含义：不叠 M3 的 surface tint（会把底染偏），
        // 也不与 [AppFloatSurface] 自带的双层软阴影打架。
        elevation: 0,
        child: _AboutPanel(),
      ),
    ),
  );
}

/// 「关于」面板本体：**玻璃浮层** + 应用信息 + 两个动作。
///
/// 结构照应官方 `AboutDialog`（图标 + 名称版本 + 简介 + 「查看许可」/「关闭」），
/// 但外观走项目自己的玻璃档（**实色底 + 光泽**，与设置面板**同一档**）——理由见
/// [_AboutPanel.build] 与 [showAboutPanel] 的文档。
class _AboutPanel extends StatelessWidget {
  const _AboutPanel();

  /// 面板宽度：够放下「sinan 0.1.0」一行 + 两三行简介 + 两个按钮，不拉成横幅。
  static const double _width = 380;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return AppFloatSurface(
      // ## 底 = **实色** + 玻璃光泽（与设置面板**同一档**，2026-09-22 用户定）
      // 底色用 [AppTheme.floatSurface]（**不透明**）⇒ 面板背后是什么都不影响它，
      // 读作"一块抛光的实板"；"玻璃"完全由内光泽 + 顶沿光边提供。
      // 📌 早先这里是"B 档"、设置面板是"半透的 A 档"，作为对照存在；实测两者只差
      // 1~3 Lc（肉眼不可分）⇒ 对照删掉，两处统一走这一档。
      // ⚠️ 因此 [AppFloatSurface.blur] 也一并去掉：实色底下模糊本来就看不见，
      //   留着只是白付一次 `saveLayer`（关于面板小、付得起，但没必要）。
      glass: true,
      color: AppTheme.floatSurface(theme.brightness),
      width: _width,
      padding: const EdgeInsets.all(Tokens.spaceLg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              tabler.Pencil(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5, colorFilter: ui.ColorFilter.mode(scheme.primary, ui.BlendMode.srcIn)),
              const SizedBox(width: Tokens.spaceMd),
              Expanded(
                child: Text(
                  '${AppInfo.name} ${AppInfo.version}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Tokens.spaceMd),
          Text(
            AppInfo.description,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Tokens.spaceLg),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              TextButton(
                onPressed: () => _openLicenses(context),
                child: const Text('查看许可'),
              ),
              const SizedBox(width: Tokens.spaceSm),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 打开许可页（框架原生 [LicensePage]，与设置面板的「关于」分区同一个页面）。
  ///
  /// ⚠️ 本面板是**路由**（`showDialog`），不是设置面板那种 OverlayEntry ⇒ 直接
  /// `pop()` 就行；但 `NavigatorState` 与主题色都要在 pop **之前**取好 ——
  /// pop 之后本 widget 的 context 已失效，那时再 `Navigator.of(context)` 会抛
  /// （设置面板那支 `_openLicenses` 踩过同一个坑）。
  void _openLicenses(BuildContext context) {
    final NavigatorState navigator = Navigator.of(context);
    final Color primary = Theme.of(context).colorScheme.primary;
    navigator.pop();
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (BuildContext _) => LicensePage(
            applicationName: AppInfo.name,
            applicationVersion: AppInfo.version,
            applicationIcon: tabler.Pencil(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5, colorFilter: ui.ColorFilter.mode(primary, ui.BlendMode.srcIn)),
          ),
        ),
      ),
    );
  }
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
          leading: tabler.Pencil(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5, colorFilter: ui.ColorFilter.mode(scheme.primary, ui.BlendMode.srcIn)),
          title: const Text('${AppInfo.name} ${AppInfo.version}'),
          subtitle: Text(AppInfo.tagline, style: hint),
          isThreeLine: true,
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: tabler.Article(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5, colorFilter: ui.ColorFilter.mode(scheme.onSurfaceVariant, ui.BlendMode.srcIn)),
          title: const Text('开源许可'),
          subtitle: Text('第三方依赖的许可清单（由框架自动收集）', style: hint),
          trailing: tabler.ChevronRight(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5, colorFilter: ui.ColorFilter.mode(scheme.onSurfaceVariant, ui.BlendMode.srcIn)),
          onTap: () => _openLicenses(context),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: tabler.FolderOpen(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5, colorFilter: ui.ColorFilter.mode(scheme.onSurfaceVariant, ui.BlendMode.srcIn)),
          title: const Text('数据目录'),
          // 可选中：路径以 AppData 开头、肉眼抄不下。
          subtitle: SelectableText(dataDir, style: hint),
          trailing: IconButton(
            icon: const tabler.Copy(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
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
      applicationIcon: tabler.Pencil(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5, colorFilter: ui.ColorFilter.mode(Theme.of(context).colorScheme.primary, ui.BlendMode.srcIn)),
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

/// 嵌入模型名（Ollama tag）。空 = 只用关键词检索。
class _AiEmbeddingModelRow extends ConsumerWidget {
  const _AiEmbeddingModelRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings = ref.watch(settingsProvider);
    return _TextSettingRow(
      label: '嵌入模型',
      description:
          '语义检索用的模型（`ollama list` 可查），如 bge-m3。'
          '留空 ⇒ 检索与索引自动只用关键词，功能照常可用。'
          '**换模型后要重建索引**（向量空间变了）。',
      value: settings.aiEmbeddingModel,
      hint: 'bge-m3',
      onCommit: (String value) =>
          ref.read(settingsProvider.notifier).setAiEmbeddingModel(value),
    );
  }
}

/// 「建立 / 更新索引」：待处理块数 + 一键增量索引（有进度、可取消）。
///
/// ## 为什么放在设置页
/// 它是 6.5 定的那个"**显式、可预期、可取消**的维护动作"，不属于日常写作路径。
/// 待处理数为 0 时按钮显示「已是最新」，用户一眼就知道不必点。
///
/// ## 没配嵌入模型也点得动
/// 那时只建**关键词**索引（本地 FTS5，不需要模型）——检索侧同样是"降级而非
/// 不可用"，这与 6.4 是一套口径。
class _BuildIndexRow extends ConsumerStatefulWidget {
  const _BuildIndexRow();

  @override
  ConsumerState<_BuildIndexRow> createState() => _BuildIndexRowState();
}

class _BuildIndexRowState extends ConsumerState<_BuildIndexRow> {
  int _pending = 0;
  IndexProgress? _progress;
  IndexCancelToken? _token;
  String? _message;

  @override
  void initState() {
    super.initState();
    // 打开设置面板就算一次待处理数（它是一次 COUNT 查询，成本可忽略）。
    _refreshPending();
  }

  void _refreshPending() {
    _pending = ref.read(indexJobProvider).pendingCount();
  }

  Future<void> _run() async {
    final IndexJob job = ref.read(indexJobProvider);
    final int total = job.pendingCount();
    if (total == 0) return;
    final IndexCancelToken token = IndexCancelToken();
    setState(() {
      _token = token;
      _message = null;
      _progress = (done: 0, total: total, failed: 0);
    });
    try {
      final IndexResult result = await job.run(
        onProgress: (IndexProgress p) {
          if (mounted) setState(() => _progress = p);
        },
        cancelToken: token,
      );
      if (!mounted) return;
      setState(() {
        _token = null;
        _progress = null;
        _refreshPending();
        _message =
            result.abortReason ??
            (result.cancelled
                ? '已取消（已写入的批次保持有效）'
                : '完成 ${result.done} 块'
                      '${result.failed > 0 ? '，失败 ${result.failed} 块（可再点重试）' : ''}');
      });
    } on Object catch (e) {
      // 索引任务只在"模型不可达/脏响应"时正常返回；能落到这里的是意外错误，
      // **显示出来**而不是吞掉（否则用户只看到按钮没反应）。
      if (!mounted) return;
      setState(() {
        _token = null;
        _progress = null;
        _refreshPending();
        _message = '索引失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool keywordOnly = ref
        .watch(settingsProvider)
        .aiEmbeddingModel
        .trim()
        .isEmpty;
    final IndexProgress? progress = _progress;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Tokens.spaceLg,
        Tokens.spaceSm,
        Tokens.spaceLg,
        Tokens.spaceSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text('建立 / 更新索引', style: theme.textTheme.bodyLarge),
              ),
              if (progress != null)
                TextButton(
                  onPressed: () => _token?.cancel(),
                  child: const Text('取消'),
                )
              else
                FilledButton(
                  onPressed: _run,
                  child: Text(_pending > 0 ? '建立索引（$_pending 块待处理）' : '已是最新'),
                ),
            ],
          ),
          const SizedBox(height: Tokens.spaceXs),
          Text(
            keywordOnly
                ? '未填嵌入模型 ⇒ 只建关键词索引（搜索照常可用，只是没有语义召回）。'
                : '增量更新：只重算内容变过的块，可随时取消。'
                      '嵌入模型换了要重建一次。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (progress != null) ...<Widget>[
            const SizedBox(height: Tokens.spaceSm),
            LinearProgressIndicator(
              value: progress.total == 0
                  ? null
                  : progress.done / progress.total,
            ),
            const SizedBox(height: Tokens.spaceXs),
            Text(
              '${progress.done} / ${progress.total}',
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (_message != null) ...<Widget>[
            const SizedBox(height: Tokens.spaceXs),
            Text(
              _message!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
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
