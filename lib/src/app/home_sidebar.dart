import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/app_custom_icons.dart';
import '../theme/app_theme.dart';
import '../theme/focus_ring.dart';
import '../theme/tokens.dart';
import 'home_hub.dart' show HomeViewIcon, kHomeTabs;
import 'new_note_capsule.dart';
import 'providers.dart';
import 'search_palette.dart';

/// 工作区**左侧扁平导航**（2026-10-12 用户定，参考 Craft）：直接贴在窗口底上，
/// **不带面板**（无 panelFill / 描边 / 投影 / 圆角卡）——层次靠"在窗口底上"本身，
/// 而不是一块浮起的卡。右边的**内容区**才包浮面卡（见 [HomeScreen] 的
/// `_FloatingPanel`）⇒ 视图集中、左侧只是导航。
///
/// 内容 = 顶行（**搜索框** + **新建胶囊**）+ **四枚视图导航**（心流 / 全部 / 日历 / 收藏）。它在工作区
/// 级常驻（主页态与编辑器态都在），所以新建 / 切视图在编辑器里也够得着（与已删的
/// 左索引面板同一条"常驻"原则，但去掉了面板外壳）。
class HomeSidebar extends ConsumerWidget {
  const HomeSidebar({super.key});

  /// 固定宽 = [Tokens.sidebarWidth]（32×8 = 256，2026-10-15 定）。
  /// ⚠️ 硬约束是**顶行**：搜索框 + 8 缝 + 新建胶囊（最小宽 80）——256 时搜索框
  /// 分到 152，够放完整占位文字。导航项（图标 + 2 字标签 ≈72）很松，不构成约束。
  /// 胶囊早改成 Overlay 浮层（不再就地展开），"容展开态 246"的旧理由已不存在。
  static const double _width = Tokens.sidebarWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Brightness brightness = theme.brightness;
    final HomeView current = ref.watch(
      navHistoryProvider.select((NavHistoryState s) => s.view),
    );

    return SizedBox(
      width: _width,
      child: Padding(
        // 左 spaceMd / 右 spaceSm：给导航一点呼吸，又不至于太挤。
        padding: const EdgeInsets.fromLTRB(
          Tokens.spaceMd,
          // 顶端呼吸 = [AppTheme.surfaceRingRetreat]（1）：**与内容卡顶环缝同值**
          // ⇒ 侧栏页头与右栏那条撤销/重做带（同样 40 高）同起点、同高，严格重合。
          // ⚠️ 不再是 [NewNoteCapsule.bandTopOffset]（那是从 y=20 中心线反推的
          // 4，服务于已经作废的跨列行对齐——见 [Tokens.headerBandCenter]）。
          AppTheme.surfaceRingRetreat,
          // 侧栏↔内容卡总缝 = regionGap：这里放 regionGap − 环缝，环缝由
          // [HomeScreen] 的外层 Padding 补（appPanelInset）。
          Tokens.regionGap - Tokens.appPanelInset,
          Tokens.spaceSm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // 品牌行（页头带）：左 logo + 应用名，右 搜索/新建 图标——Linear / Notion
            // 同款侧栏页头（左品牌 + 右动作）。两枚图标热区 30（[Tokens.headerActionSize]）
            // 与右栏编辑器撤销/重做钮同大；图标 [Tokens.iconMd]（24），搜索小一档到
            // [Tokens.iconMdSm]（20，光学对齐）。
            // 两列顶端因此是"40 高 + 30 热区"的平行带（C 方案下唯一保留的跨列关系）。
            // 省掉一整条 32 高的带 + 其下方 12 间距 = 44px。
            const _BrandStrip(),
            // 页头↔导航：区块间距唯一常数（=12，与侧栏↔内容卡同值）。
            const SizedBox(height: Tokens.regionGap),
            // 四枚视图导航。
            for (final HomeView v in kHomeTabs)
              _SidebarItem(
                view: v,
                current: v == current,
                scheme: scheme,
                brightness: brightness,
                onTap: () =>
                    ref.read(navHistoryProvider.notifier).selectHome(v),
              ),
          ],
        ),
      ),
    );
  }
}

/// **应用品牌行**（2026-10-15 新增）：logo + 应用名，坐在搜索框 / 新建胶囊上方。
///
/// 高 = [Tokens.brandStripHeight]（**40**）——锚取自右栏编辑器「撤销 / 重做 + 双耳」
/// 那条头一带（5 + 30 + 4 = 39），取最近 4pt 倍数 ⇒ 两列顶端的动作区近同高
/// （C 方案下唯一保留的跨列关系），且整列仍全 4 倍数。
/// 行内补一档 [Tokens.spaceSm] ⇒ 本行**内容左缘 = 20**，与搜索框放大镜、导航项
/// 图标同一条竖线（侧栏左内距 12 + 行内距 8——三行共用，别漏掉哪一行）；
/// 名字因此比导航文字右 6px（logo 24 比导航图标 18 宽），可接受：品牌行要让的是
/// **行内容左基线**，不是文字基线。
/// 与下方顶带隔一档 [Tokens.regionGap]，**不画分割线**（Linear 式留白分层）。
/// 右端留位给后续要加的动作钮（左品牌 + 右动作同行，Linear 侧栏页头同结构）。
///
/// ⚠️ **logo 暂无正式资产**：现在是代码画的包豪斯三色条（蓝 = 主题点睛 /
/// 黄·绿 = 内容层两个 accent，24 方）当占位。拿到正式 SVG 后换成
/// [CustomIcons] 一枚即可（尺寸档 [Tokens.iconMd] 不变、行高不用动）。
///
/// ⚠️ 副作用：本行把侧栏顶带整体下推 56 ⇒ 不再与内容卡筛选行共享
/// [Tokens.headerBandCenter] 中心线（要恢复共享线只能把品牌行挪进标题栏左区，
/// 那时高度只剩标题栏的 32——与"比标题栏高一些"冲突，故取现在这版）。
class _BrandStrip extends StatelessWidget {
  const _BrandStrip();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Brightness b = theme.brightness;
    return SizedBox(
      height: Tokens.brandStripHeight,
      // ⚠️ 这一行**必须有和其它行同样的行内距**（[Tokens.spaceSm]）：本行内容
      // 若不缩进就比搜索框（放大镜）、导航项（图标）靠左 8px（12 vs 20），
      // 左基线断成两条（2026-10-15 盘点发现）。加了之后 logo 左缘 = 20，与那
      // 两行的内容左缘同一条竖线；将来给本行加 hover 背景 / 动作钮，命中区也
      // 自然与其它行同宽（背景仍由本行撑满侧栏宽，不受这层 padding 影响）。
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceSm),
        // 左品牌 + 右动作：名字用 Expanded 撑开，避免挤到右侧图标；右端两枚图标
        // 热区 30（[Tokens.headerActionSize]）、图标 24（[Tokens.iconMd]；
        // 搜索 20 = [Tokens.iconMdSm]，光学对齐新建那枚）。
        child: Row(
          children: <Widget>[
            // 占位 logo：包豪斯三色条（spaceBetween 均分 24 高，三条 6 高 + 3 缝；
            // 端头走 radiusFull 胶囊档——6 高的条子只有全圆端好看，别裸写 circular）。
            SizedBox(
              width: Tokens.iconMd,
              height: Tokens.iconMd,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final Color c in <Color>[
                    Bauhaus.blue(b),
                    Bauhaus.yellow(b),
                    Bauhaus.green(b),
                  ])
                    Container(
                      height: 6,
                      decoration: BoxDecoration(
                        color: c,
                        borderRadius: BorderRadius.circular(Tokens.radiusFull),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: Tokens.spaceSm),
            Expanded(
              child: Text(
                'sinan',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Bauhaus.ink(b),
                  fontWeight: FontWeight.w600,
                  // 紧字距：与「新建」胶囊同口径的包豪斯排印。
                  letterSpacing: -0.2,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // 右端：搜索（图标开门，接全局搜索面板）+ 新建（图标，向下展开菜单）。
            const _SidebarSearchBox(),
            const SizedBox(width: Tokens.spaceSm),
            const NewNoteCapsule(iconOnly: true),
          ],
        ),
      ),
    );
  }
}

String _viewLabel(HomeView v) => switch (v) {
  HomeView.timeline => '心流',
  HomeView.all => '全部',
  HomeView.calendar => '日历',
  HomeView.favorites => '收藏',
};

/// 侧栏页头**搜索图标钮**（2026-10-15 由内联触发条改为图标：搜索由"点图标打开
/// 全局搜索面板"完成，不做就地输入——面板即输入框，与 Ctrl+K 同源）。坐品牌行右端，
/// 与新建图标同规格（热区 30 = [Tokens.headerActionSize]）；图标 [Tokens.iconMdSm](20)，
/// 比新建那枚的 [Tokens.iconMd](24) 小一档——光学对齐（理由见下）。
///
/// 两枚同为 [Tokens.iconMd](24) 时搜索看着更大一圈：Remix `search-ai-line` 的放大镜
/// 环 + 斜柄 + 火花几乎占满 24 画板，而 `add-circle-line` 的环虽更满、对比度却更低
/// （主题蓝比亮白"显小"）。2026-10-15 用户看图后定：搜索降一档到 [Tokens.iconMdSm](20)。
///
/// ⚠️ 它只"开门"：真正的输入在 [showSearchPalette] 打开的面板里。a11y 标签由
/// Tooltip '搜索' 提供（图标化后屏幕无文字，标签不能丢）。
///
/// 图标走 **Remix `search-ai-line`**（[CustomIcons.search]），与右侧新建图标的
/// `add-circle-line` 同族（2026-10-15 用户定：tabler 的放大镜不好看）。
/// ⚠️ Remix 是**填充路径**、没有 strokeWidth 可调 ⇒ 着色走 `colorFilter.srcIn`，
/// **必须显式传 color**（见 [CustomIcons] 类文档），不传就是资产里的死黑。
class _SidebarSearchBox extends StatefulWidget {
  const _SidebarSearchBox();

  @override
  State<_SidebarSearchBox> createState() => _SidebarSearchBoxState();
}

class _SidebarSearchBoxState extends State<_SidebarSearchBox> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final Brightness b = Theme.of(context).brightness;
    return Tooltip(
      message: '搜索（Ctrl+K）',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: showSearchPalette,
          onHover: (bool? h) => setState(() => _hover = h ?? false),
          borderRadius: Bauhaus.radius,
          hoverColor: AppTheme.hoverOverlay(b),
          child: SizedBox(
            width: Tokens.headerActionSize,
            height: Tokens.headerActionSize,
            child: Center(
              // 光学补偿：放大镜是闭环 + 黑墨，同 24 时观感比新建（开放 + 蓝）更大，
              // 故 -2px → 22（2026-10-15 用户定）。悬浮时转 45°（与新建钮同理），
              // 给 Ctrl+K 同源的搜索钮一点 hover 反馈；时长走 [Tokens.durationHover] 档。
              child: AnimatedRotation(
                turns: _hover ? 0.25 : 0,
                duration: Tokens.durationHover,
                child: CustomIcons.search(
                  size: Tokens.iconMd - 2,
                  color: Bauhaus.ink(b),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarItem extends StatefulWidget {
  const _SidebarItem({
    required this.view,
    required this.current,
    required this.scheme,
    required this.brightness,
    required this.onTap,
  });

  final HomeView view;
  final bool current;
  final ColorScheme scheme;
  final Brightness brightness;
  final VoidCallback onTap;

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _hover = false;
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Brightness b = widget.brightness;
    final ColorScheme scheme = widget.scheme;
    final bool current = widget.current;
    // 选中态 = 设置/右角钮同款**中性浅覆**（navSelectedTint = onSurface@10%），不用
    // 色块；当前项加粗 + onSurface；其余 onSurfaceVariant。
    // hover = [AppTheme.hoverOverlay] **半透明**叠加（2026-10-15 二次修正）：曾改成
    // 烤实的中性灰 hoverOnWindow，但预设主题下窗口本身就是预设色（chromeColor）——
    // 中性灰补丁贴在彩色窗上每套预设一个样。半透明叠加随底自适应，全 App 一个口径。
    final Color fg = current ? scheme.onSurface : scheme.onSurfaceVariant;
    final Color bg = current
        ? AppTheme.navSelectedTint(scheme.onSurface, b)
        : (_hover ? AppTheme.hoverOverlay(b) : Colors.transparent);
    return MouseRegion(
      onEnter: (_) {
        if (!_hover) setState(() => _hover = true);
      },
      onExit: (_) {
        if (_hover) setState(() => _hover = false);
      },
      child: FocusableActionDetector(
        focusNode: _focus,
        mouseCursor: SystemMouseCursors.click,
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<Intent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: Semantics(
          // 读屏三件事：这是**按钮**、**可操作**、**当前是否被选中**。
          // 修前：button=false / selected=false / enabled=false ⇒ 读屏只念"心流"，
          // 既不知可点、也不知哪个视图是当前视图（a11y 审计发现）。
          button: true,
          enabled: true,
          selected: current,
          child: FocusRing(
            focusNode: _focus,
            borderRadius: Bauhaus.radius,
            child: GestureDetector(
              onTap: widget.onTap,
                child: Container(
                  height: Tokens.sidebarRowHeight,
                  padding: const EdgeInsets.symmetric(
                    horizontal: Tokens.spaceSm,
                  ),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: Bauhaus.radius,
                  ),
                  child: Row(
                    children: <Widget>[
                      // 图标是**装饰**（文字已给足标签）：退出语义，否则 tabler 的 SVG
                      // 会把 `isImage` 并进这个节点 ⇒ 读屏播成"心流，图像"。
                      Semantics(
                        excludeSemantics: true,
                        child: widget.view.icon(fg),
                      ),
                      const SizedBox(width: Tokens.spaceSm),
                      Text(
                        _viewLabel(widget.view),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: fg,
                          fontWeight: current ? FontWeight.w700 : FontWeight.w500,
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
