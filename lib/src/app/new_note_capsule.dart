import 'dart:async';

import 'package:flutter/services.dart'
    show KeyDownEvent, KeyRepeatEvent, LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/app_custom_icons.dart';
import '../theme/app_float_surface.dart';
import '../theme/app_theme.dart';
import '../theme/focus_ring.dart';
import '../theme/tokens.dart';
import '../command/commands.dart';

/// **新建胶囊**（2026-10-14 定稿：官方 [MenuAnchor] **向下展开**）：
/// 收起态只显示一枚 32 高的「新建 ▾」按钮（与搜索框同高、同在 y=20 顶部带）；
/// 悬停 / 点击 / 键盘聚焦即把 **笔记 / 画布** 作为 Overlay 浮层从按钮**正下方**
/// 向下展开——`AlignmentDirectional.bottomStart`：托盘左缘与按钮左缘对齐、
/// 顶边贴住按钮底边，浮层飘在内容之上、**零布局位移**。自带官方展开动画、
/// 键盘焦点 / 方向键导航 / Esc 关闭 / 点外部关闭。
///
/// ⚠️ 两枚菜单项必须**竖排**直接交给 [MenuAnchor]：MenuAnchor 是纯竖排组件——
/// 面板用 `IntrinsicWidth` 量宽（menu_anchor.dart `_intrinsicCrossSize`），而
/// `MenuItemButton` 内部 `_MenuItemLabel` 自带 `Expanded` 嵌套结构。把
/// [MenuItemButton] 横排（外包 Row）塞进 `menuChildren` 会让固有宽度测量算出
/// ∞ ⇒ 面板被以无界宽度布局 ⇒ `Expanded` 直接崩（2026-10-14 实测）。
///
/// 外观（2026-10-14 定稿）：触发钮走 Linear 式扁平（[AppTheme.floatSurface] 面 +
/// 亮度阶梯分层，暗色无描边 / 亮色 1px 发丝边，hover / 展开叠
/// [AppTheme.hoverOverlay] 活性底）；**弹出托盘走 Tooltip 同款实色**（2026-10-15
/// 用户定"面板改 tooltip 色"）——底色 = 官方 Tooltip 默认（亮色深灰 / 暗色近白），
/// 与搜索钮的 Tooltip('搜索（Ctrl+K）') 同色系，不再磨砂。
/// 展开线索 = 箭头翻转 + Semantics expanded。点睛两处：触发钮**加号图标 =
/// 主题色**（[ColorScheme.primary]）与焦点环——方案 B（2026-10-15）起 primary
/// 恒定包豪斯蓝（不随窗口预设变），两处同源同值。包豪斯层保留在内容上：
/// 两枚菜单项静止黑块、hover / 聚焦整块转各自 accent 原色（笔记=黄 /
/// 画布=绿）。两钮都经 `runCommandById`
/// （`note.new` / `canvas.new`）⇒ 与 `Ctrl+N` / `Ctrl+Shift+N` 同一条路
/// （命令是权威面）。
///
/// ## 落点
/// **图标模式**（[iconOnly] = true，2026-10-15 起侧栏的默认用法）：坐
/// [HomeSidebar] 品牌行右端，一枚 30 热区（[Tokens.headerActionSize]）+ 24 图标
/// （[Tokens.iconMd]）的 + 钮，与同行的搜索图标同规格。a11y 标签由 [Semantics.label]
/// ='新建' 提供（不悬浮 Tooltip：点按弹面板即提示，再悬浮标签是重复）。
/// **完整模式**（默认 iconOnly = false）："新建 ▾" 文字钮，高 [kHeight]=32、有最小宽
/// ——保留给未来侧栏展开等需要文字标签的场景（当前侧栏不这么用）。
class NewNoteCapsule extends ConsumerStatefulWidget {
  const NewNoteCapsule({super.key, this.iconOnly = false});

  /// **图标模式**：只画一枚 + 图标、不画"新建"文字、不撑最小宽（坐品牌行右端）。
  /// 默认 false = 完整文字钮模式。
  final bool iconOnly;

  /// 外高（完整模式公开；图标模式用 [Tokens.headerActionSize]）。
  static const double kHeight = 32;

  /// 顶部带落点 = [Tokens.headerBandCenter] − 托盘高的一半 = 4（完整模式的参考值）。
  /// ⚠️ 侧栏已改用图标模式放进品牌行，此公式不再用于侧栏落点——保留作完整模式的
  /// 几何参考（内容卡 / 编辑器仍按 [Tokens.headerBandCenter] 算）。
  static const double bandTopOffset = Tokens.headerBandCenter - kHeight / 2;

  @override
  ConsumerState<NewNoteCapsule> createState() => _NewNoteCapsuleState();
}

class _NewNoteCapsuleState extends ConsumerState<NewNoteCapsule> {
  /// 触发钮焦点节点：交给触发钮自己的 [Focus]（Tab 链里的一站 + 键盘事件入口）、
  /// [MenuAnchor.childFocusNode]（官方浮层认这个节点）与统一的 [FocusRing]
  /// （画焦点环）共用——本仓焦点基建标准用法。
  final FocusNode _triggerFocus = FocusNode();

  /// 两枚菜单项的焦点节点：官方 MenuAnchor 只对 SubmenuButton 自动移焦，
  /// standalone 菜单打开后焦点仍留在触发钮——而浮层不在常规 Tab 链里，方向键
  /// 永远进不去。键盘展开时**手动落焦第一枚**（[_openFromKeyboard]）。
  final FocusNode _noteTileFocus = FocusNode();
  final FocusNode _canvasTileFocus = FocusNode();

  /// 官方 MenuController：在 [MenuAnchor.builder] 里拿到。
  /// open / close / isOpen 都走它。
  MenuController? _ctrl;

  bool _isOpen = false;

  /// 悬停态（Linear 的 hover tint 口径：窗口底上叠一层半透明 hoverOverlay）。
  bool _hover = false;

  /// 触发钮最小宽：保证 ≥ 菜单自然宽（行内容 图标16 + 距4 + 两字28 + 行内边距16
  /// = 64，再留面板 padding 余量），浮层取此宽时内容装得下、与按钮严格齐平。
  static const double _kMinTriggerWidth = 80;

  /// 图标模式下浮层的**固定最小宽**（2026-10-15 用户定"弹出页加大"）：图标模式
  /// 触发钮量不到宽（[_triggerWidth]=0）时，面板取此宽——比内容自然宽宽出一档，
  /// 读数更舒展。
  static const double _kMenuMinWidth = 112;

  /// 浮层宽度：优先与触发钮等宽（完整模式两侧齐平）；图标模式量不到（0）时取
  /// [_kMenuMinWidth]。
  double get _menuWidth => _triggerWidth > 0 ? _triggerWidth : _kMenuMinWidth;

  /// 触发钮的 [GlobalKey]：用来测量它的实际宽度，回填 [_triggerWidth] 让浮层与按钮
  /// **等宽**（两侧齐平）。不用固定宽度常量——字号缩放 / 文字长度变了都能自适应。
  final GlobalKey _triggerKey = GlobalKey();

  /// 浮层宽度 = 触发钮宽度（0 = 还没量到，此时浮层按内容宽度，先展开一帧再对齐）。
  double _triggerWidth = 0;

  /// 帧末测量触发钮宽度并回填。变了才 setState，避免每帧重建死循环。
  void _syncMenuWidth() {
    if (!mounted) return;
    final RenderBox? box =
        _triggerKey.currentContext?.findRenderObject() as RenderBox?;
    final double w = (box != null && box.hasSize) ? box.size.width : 0;
    if (w > 0 && (w - _triggerWidth).abs() > 0.5) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _triggerWidth = w);
      });
    }
  }

  /// 悬停离开后的延迟关闭定时器：给"从触发钮挪到浮层"留 200ms 过渡，
  /// 浮层 onEnter / 菜单项 onHover 都会清掉它 ⇒ 不会闪退。
  Timer? _closeTimer;

  @override
  void dispose() {
    _closeTimer?.cancel();
    _triggerFocus.dispose();
    _noteTileFocus.dispose();
    _canvasTileFocus.dispose();
    super.dispose();
  }

  void _cancelClose() => _closeTimer?.cancel();

  void _scheduleClose() {
    _closeTimer?.cancel();
    _closeTimer =
        Timer(const Duration(milliseconds: 200), () => _ctrl?.close());
  }

  /// 键盘展开（触发钮上 Enter / Space / 数字小键盘 Enter）：打开后帧末落焦
  /// 第一枚菜单项（笔记）。
  void _openFromKeyboard() {
    _ctrl?.open();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _noteTileFocus.requestFocus();
    });
  }

  /// 触发钮键盘事件：激活键开菜单，其余放行。
  KeyEventResult _handleTriggerKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter ||
          event.logicalKey == LogicalKeyboardKey.space) {
        _openFromKeyboard();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Brightness b = theme.brightness;
    // 量一次触发钮宽度回填浮层（内部只在宽度变化时才 setState，不会每帧重建）。
    _syncMenuWidth();

    return MenuAnchor(
      // 浮层托盘：**Tooltip 同款实色**（2026-10-15 用户定"面板改 tooltip 色"）——
      // MenuStyle 只负责定位/裁剪/透明底，真正的面由 menuChildren 里的
      // [AppFloatSurface]（blur/glass 关掉、底色 = Tooltip 默认）画，与搜索钮
      // 的 Tooltip 同色系。从按钮**正下方**向下展开
      // （bottomStart：左缘对齐、顶边贴按钮底边）——零布局位移。
      style: MenuStyle(
        elevation: const WidgetStatePropertyAll<double?>(0.0),
        // 面板本身不涂色：磨砂面（模糊 + 半透明底）必须由 widget 层画，
        // MenuStyle 的纯色+统一描边表达不了。
        backgroundColor: const WidgetStatePropertyAll<Color?>(Colors.transparent),
        side: const WidgetStatePropertyAll<BorderSide?>(BorderSide.none),
        // **四角全圆角**（2026-10-14 定）：面板现在是浮起的磨砂面，不再与按钮
        // 拼成一条连续轮廓 ⇒ 上缘不必直角，四角统一 [Bauhaus.radius]。
        shape: WidgetStatePropertyAll<OutlinedBorder?>(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(Tokens.radiusLg)),
        ),
        padding: const WidgetStatePropertyAll<EdgeInsetsGeometry?>(EdgeInsets.zero),
        // ⚠️ MenuStyle.alignment 是**浮层相对锚点的定位对齐**（不是内容对齐）：
        // bottomStart ⇒ 托盘左上角对齐按钮左下角，从按钮正下方向下展开。
        alignment: AlignmentDirectional.bottomStart,
        // 托盘宽 ≥ [_menuWidth]（完整模式 = 触发钮宽，两侧齐平；图标模式 = 固定
        // [_kMenuMinWidth]，2026-10-15 用户定"弹出页加大"）。
        minimumSize: WidgetStatePropertyAll<Size?>(
          Size(_menuWidth, 0),
        ),
      ),
      // 与按钮留 2px 缝：四角全圆后若仍严丝合缝贴着按钮，接缝处会出现
      // "两个圆角对捏"的缺口。2px 由 200ms 延迟收起的宽容期覆盖（鼠标
      // 从按钮移到面板不会误关）。
      //
      // ⚠️ alignmentOffset 是 [MenuAnchor] 自己的参数（不是 MenuStyle 的）。
      alignmentOffset: const Offset(0, Tokens.spaceXxs),
      // ⚠️ 不传 childFocusNode：官方在打开菜单时会强制 requestFocus 它
      // （raw_menu_anchor.dart:753）⇒ 悬停展开也把触发钮聚焦、蓝色焦点环
      // 跟着亮（2026-10-14 用户实报"悬停变蓝"）。键盘路径的焦点完全由
      // [_openFromKeyboard] / 触发钮自己的 Focus 管理，不需要它。
      onOpen: () => setState(() => _isOpen = true),
      onClose: () => setState(() => _isOpen = false),
      // builder 拿得到官方 MenuController：存起来，并用 MouseRegion 实现
      // "悬停即开"；鼠标移开先延迟关闭（浮层会 cancel）。悬停同时驱动触发钮
      // 的活性底（Linear 的 hover tint 口径）。
      builder: (BuildContext context, MenuController controller, Widget? child) {
        _ctrl = controller;
        return MouseRegion(
          onEnter: (_) {
            _cancelClose();
            if (!_hover) setState(() => _hover = true);
            controller.open();
          },
          onExit: (_) {
            if (_hover) setState(() => _hover = false);
            _scheduleClose();
          },
          child: child,
        );
      },
      // 浮层内容：两枚菜单项**竖排**（见类注释的崩溃警告，切勿横排包 Row），
      // 外裹 MouseRegion 让"在浮层内"取消延迟关闭；Column.stretch 让两枚铺满托盘宽。
      // 托盘 = Tooltip 同款实色面，两枚之间夹一条 1px 发丝分隔线。
      menuChildren: <Widget>[
        MouseRegion(
          onEnter: (_) => _cancelClose(),
          onExit: (_) => _scheduleClose(),
          child: AppFloatSurface(
            // 实色气泡（不再磨砂）：底色 = Tooltip 同款（2026-10-15 用户定
            // "面板改 tooltip 色"）——亮色深灰 / 暗色近白，与搜索钮的
            // Tooltip('搜索（Ctrl+K）') 同色系。blur/glass 默认都关，纯实色浮层。
            // 底色走 [Bauhaus.tooltipSurface]（= Tooltip 默认，令牌层定义）——
            // 让面板与搜索钮的 Tooltip 同色系（2026-10-15 用户定"面板改 tooltip 色"）。
            color: Bauhaus.tooltipSurface(b),
            // 四角全圆角（与 MenuStyle.shape 同值，浮层档 16）。
            borderRadius: BorderRadius.circular(Tokens.radiusLg),
            // ⚠️ 宽度**显式钉成 [_menuWidth]**：面板只给最小宽，内层若随内容
            // 收缩就会比按钮窄 ⇒ 两侧对不齐；图标模式取固定宽（加大）。
            width: _menuWidth,
            // 内边距 0（2026-10-15 用户定"按钮直接铺满面板"）：两枚菜单项方角贴
            // 边铺满，圆角交给面板的 Material 裁切收口。
            padding: EdgeInsets.zero,
            // 两枚菜单项**竖向排布**（同 36 高、无偏重），宽度由 stretch 撑满内区。
            // ⚠️ 不能用 Expanded：面板高度是无界的，Expanded 会直接崩（
            // 与"MenuAnchor 竖排面板"那类越界同一个坑）。
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // 弹窗首行：新建提示字（非交互标签）。文字色随面板底反相——
                // 亮色深灰底用纸色字、暗色近白底用墨色字（同 Tooltip 文字配色）。
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Tokens.spaceMd,
                    vertical: Tokens.spaceXs,
                  ),
                  child: Text(
                    '新建',
                    style: theme.textTheme.bodySmall?.copyWith(
                      // 同 [_MenuTile] 的 fg：暗色近白底用深墨（[Bauhaus.onAccent]）、
                      // 亮色深灰底用纸色——不能取主题 [Bauhaus.ink]（暗色下是浅色）。
                      color: b == Brightness.dark
                          ? Bauhaus.onAccent(b)
                          : Bauhaus.paper(b),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: Tokens.spaceXs),
                _MenuTile(
                  focusNode: _noteTileFocus,
                  iconBuilder: (Color fg) => CustomIcons.edit19(
                    size: Tokens.iconMdSm,
                    color: fg,
                  ),
                  label: '笔记',
                  tooltip: '新建笔记（Ctrl+N）',
                  onTap: () => unawaited(runCommandById(ref, 'note.new')),
                  brightness: b,
                  accent: Bauhaus.yellow(b),
                ),
                // 两枚之间的 **1px 发丝分隔线**（2026-10-15 用户定）：与面板底反相，
                // 两种底色下都"分得开"；弱于浮层描边（只需分、不必挑）。
                Container(height: 1, color: Bauhaus.tooltipDivider(b)),
                _MenuTile(
                  focusNode: _canvasTileFocus,
                  // 下载图标 197_画笔（2026-10-15 用户定）：新建菜单「画布」项，
                  // 随面板对比色 fg 染（明暗都可见；不用原色——原黑在亮色深灰底会消失）。
                  iconBuilder: (Color fg) => CustomIcons.brush(
                    size: Tokens.iconMdSm + 2,
                    color: fg,
                  ),
                  label: '画布',
                  tooltip: '新建画布（Ctrl+Shift+N）',
                  onTap: () => unawaited(runCommandById(ref, 'canvas.new')),
                  brightness: b,
                  accent: Bauhaus.green(b),
                ),
              ],
            ),
          ),
        ),
      ],
      // 收起态：一枚 32 高的「新建 ▾」按钮，与搜索框同高。
      child: _buildTrigger(theme, b),
    );
  }

  Widget _buildTrigger(ThemeData theme, Brightness b) {
    // **不垫浮层档**（2026-10-15 用户定：与侧栏导航项 [HomeSidebar] 完全同口径
    // ——静止**透明**（直接坐窗口底），只有 hover / 展开才铺一层 hover 热区色。
    // ⚠️ 用**半透明**的 [AppTheme.hoverOverlay]（黑 4% / 白 12%）而不是烤实的中性
    // 灰：预设主题下窗口本身就是预设色（chromeColor，见 main.dart），烤实的灰补丁
    // 贴在彩色窗上每套预设一个样；半透明叠加随底自适应。侧栏导航项同口径。
    // 身份只由**字重（w600）+ 动作（弹新建菜单）+ Remix 圆环加号**承担，
    // 不靠"静止时垫一块更亮的面"来分级；可点击性由热区 + 蓝焦点环表达。
    final Color surface =
        _isOpen || _hover ? AppTheme.hoverOverlay(b) : Colors.transparent;
    // + 图标（始终在）：旋转 90° 表展开；颜色恒定主题蓝。
    // 尺寸固定 [Tokens.iconMd]（24）：2026-10-15 用户定"热区 30 ⇒ 图标 24"，新建/搜索统一 24。
    final Widget icon = AnimatedRotation(
      turns: _isOpen ? 0.25 : 0,
      duration: const Duration(milliseconds: 120),
      // lucide:circle-plus（用户 2026-10-15 定）：新建触发钮图标从 tabler 换 lucide，
      // 与搜索钮统一到 lucide 一套（SVG 资产走 [CustomIcons]）。
      child: CustomIcons.circlePlus(
        color: theme.colorScheme.primary,
      ),
    );

    // 图标模式（品牌行右端）：30 热区方钮，无文字、无最小宽——和搜索图标同档。
    // 不包 Tooltip：点按即弹出「笔记 / 画布」面板，本身就是触达提示，再悬浮'新建'
    // 标签纯属重复（2026-10-15 用户定）。a11y 标签改由 [Semantics.label]='新建'
    // 提供（屏幕阅读器要，home_a11y_test 的「焦点顺序」也靠它定位）；Key 供测试定位。
    if (widget.iconOnly) {
      return FocusRing(
        focusNode: _triggerFocus,
        borderRadius: Bauhaus.radius,
        color: Bauhaus.blue(b),
        child: Focus(
          focusNode: _triggerFocus,
          onKeyEvent: _handleTriggerKey,
          child: GestureDetector(
            onTap: () => _ctrl?.open(),
            child: Semantics(
              button: true,
              expanded: _isOpen,
              label: '新建',
              child: Container(
                key: const Key('new-note-trigger'),
                width: Tokens.headerActionSize,
                height: Tokens.headerActionSize,
                decoration: BoxDecoration(
                  color: surface,
                  borderRadius: BorderRadius.circular(Tokens.radiusLg),
                ),
                child: Center(child: icon),
              ),
            ),
          ),
        ),
      );
    }

    // 完整模式：文字 + 加号、居中、有最小宽（保留给非图标场景）。
    return Semantics(
      button: true,
      expanded: _isOpen,
      child: FocusRing(
        focusNode: _triggerFocus,
        borderRadius: Bauhaus.radius,
        // 环色钉定稿包豪斯蓝：全控件唯一的蓝（2026-10-14 定稿：底层包豪斯 +
        // 焦点环点睛，面本身走 Linear 式无装饰扁平）。
        color: Bauhaus.blue(b),
        child: Focus(
          // 触发钮自己的焦点站：Tab 链里的一站 + 键盘激活入口（Enter/Space
          // 开菜单）。同一个节点也交给 MenuAnchor.childFocusNode 与 FocusRing。
          focusNode: _triggerFocus,
          onKeyEvent: _handleTriggerKey,
          child: GestureDetector(
            // 点击 = **钉住展开**（已展开则 no-op）：悬停先展开了，再点不许把它
            // 点没了（title_bar_nav_test 钉的契约）；收起只靠 鼠标离开 / Esc /
            // 点外部 / 选中菜单项（closeOnActivate）。
            onTap: () => _ctrl?.open(),
            child: ConstrainedBox(
              // 触发钮不窄于菜单自然宽（图标 + 两字 + 内边距 + 面板 padding），
              // 这样浮层 minimumSize 取触发钮宽时，内容装得下、两侧严格齐平；
              // 同时也给"内容居中"留出可居中的宽度（见下面 Row 的 center）。
              constraints: const BoxConstraints(minWidth: _kMinTriggerWidth),
              child: Container(
                key: _triggerKey,
                // Linear 式扁平按钮：floatSurface 面 + hover/展开活性底；
                // **无拟态、无描边**（明暗两档都不画，2026-10-14 用户定）。
                // 高 32，与搜索框同高。
                height: NewNoteCapsule.kHeight,
                padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceSm),
                decoration: BoxDecoration(
                  color: surface,
                  borderRadius: BorderRadius.circular(Tokens.radiusLg),
                ),
                child: Row(
                  // 内容**居中**（2026-10-14 用户定）：文字 + 加号在一枚 ≥80 宽的
                  // 按钮里居中，比贴左更平衡（Linear 的 "+ New" 同口径）。
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Text(
                      '新建',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Bauhaus.ink(b),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: Tokens.spaceXs),
                    icon,
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

/// 托盘里的一枚菜单项：**静止透明底**（2026-10-15 起去掉黑块——面板已是 Tooltip
/// 同款实色底，菜单项不再叠第二层墨底），hover / 键盘聚焦整块转各自 accent 原色 +
/// [Bauhaus.onAccent] 字；方角、贴边铺满（不要胶囊）。用官方 [MenuItemButton] 获得
/// 焦点 / 方向键 / Enter 激活 / 自动关闭；hover 用本地状态驱动图标与文字同色
/// （tabler 不读主题，需手动染色）。
class _MenuTile extends StatefulWidget {
  const _MenuTile({
    required this.focusNode,
    required this.iconBuilder,
    required this.label,
    required this.tooltip,
    required this.onTap,
    required this.brightness,
    required this.accent,
  });

  /// 菜单项焦点节点（胶囊持有的受控节点，键盘展开时落焦用）。
  final FocusNode focusNode;
  final Widget Function(Color fg) iconBuilder;
  final String label;
  final String tooltip;
  final VoidCallback onTap;
  final Brightness brightness;
  final Color accent;

  @override
  State<_MenuTile> createState() => _MenuTileState();
}

class _MenuTileState extends State<_MenuTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Brightness b = widget.brightness;
    // 无黑块（2026-10-15 用户定）：静止**透明底**，只留 hover / 聚焦时的各自
    // accent 原色整块高亮。文字 / 图标色必须随**面板底**走——面板 = [Bauhaus.tooltipSurface]，
    // **随主题反相**（亮色深灰底 / 暗色近白底，用户 2026-10-15 确认"跟随 tooltip"）。
    // ⚠️ 不能取主题前景 [Bauhaus.ink]：它暗色下翻成浅色 #F3F0EA，落近白底会消失——
    // 这正是暗色下"没颜色"的根因。与 [Bauhaus.tooltipDivider] 同口径：亮色用纸色、
    // 暗色用深墨（[Bauhaus.onAccent] = _inkLight）；hover 铺 accent 亮底也用深墨字。
    final Color fg = (_hover || b == Brightness.dark)
        ? Bauhaus.onAccent(b)
        : Bauhaus.paper(b);
    final Color bg = _hover ? widget.accent : Colors.transparent;
    return Tooltip(
      message: widget.tooltip,
      child: MenuItemButton(
        focusNode: widget.focusNode,
        onPressed: widget.onTap,
        onHover: (bool h) {
          if (h != _hover) setState(() => _hover = h);
        },
        onFocusChange: (bool f) {
          if (f != _hover) setState(() => _hover = f);
        },
        style: ButtonStyle(
          backgroundColor: WidgetStatePropertyAll<Color?>(bg),
          foregroundColor: WidgetStatePropertyAll<Color?>(fg),
          overlayColor: const WidgetStatePropertyAll<Color?>(Colors.transparent),
          // 不要胶囊（2026-10-15 用户定）：方角、贴边铺满，hover 高亮整块铺满行宽。
          shape: const WidgetStatePropertyAll<OutlinedBorder?>(
            RoundedRectangleBorder(),
          ),
          // ⚠️ 必须压掉 [MenuItemButton] 的 Material 触控默认（最小 64×48），否则每行
          // 被撑到 ~48 高。压到 36（2026-10-15 用户定"弹出页加大"，原 28 偏挤）。
          minimumSize: const WidgetStatePropertyAll<Size?>(Size(0, 36)),
          maximumSize: const WidgetStatePropertyAll<Size?>(
            Size(double.infinity, 36),
          ),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
          // 块内内容**左对齐**（竖排全宽行：图标 + 文字靠左铺排）。
          alignment: AlignmentDirectional.centerStart,
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry?>(
            EdgeInsets.symmetric(horizontal: Tokens.spaceMd),
          ),
        ),
        // 图标 + 文字左对齐一行（不用 leadingIcon，自己排以便精确控距）。
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            widget.iconBuilder(fg),
            const SizedBox(width: Tokens.spaceSm),
            Text(
              widget.label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
