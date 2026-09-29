import 'dart:async';

import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import 'dart:ui' as ui;

// 键盘事件类型（切换器的 ← / →）：KeyDownEvent / LogicalKeyboardKey 在
// `services.dart`，不由 material 转出。
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/note.dart';
import '../theme/app_custom_icons.dart';
import '../theme/app_theme.dart';
import '../theme/focus_ring.dart';
import '../theme/tokens.dart';
import '../app/undo_toast.dart';
import '../command/commands.dart' show runCommandById;
import 'providers.dart'
    show NotesNotifier, locateProvider, notesProvider, selectedNoteIdProvider;

/// 主页导航的分区（index 与 [hubNavSelectionProvider] 对应）。
///
/// ⚠️ 除 0（主页）与 [kSearchNavIndex]（搜索）外都是**占位**——对应页面还没建。
/// 接新页面时：往这里加一项、挂进 [hubNavGroups] 的某个组，再在
/// `home_screen.dart` 的主页分支按 index 分发。
///
/// 全局搜索的分区号（顶行搜索图标与主区分发共用这一个常量，别写死字面量）。
const int kSearchNavIndex = 3;

/// 全局搜索的分区号（顶行搜索图标与主区分发共用这一个常量，别写死字面量）。
///
/// ⚠️ 除 0（主页）与 [kSearchNavIndex]（搜索）外都是**占位**——对应页面还没建。
// 该空间的**内联列表**（真实笔记，按 kind 过滤）。
const int kFavoritesNavIndex = 4;
// ⚠️ 非 const：列表里混了外引彩色插画（CustomIcons.book/canvas 是方法调用，
// 不能进 const 表达式）。其余项仍是 const 构造，无性能影响。
List<({Widget icon, String label})> hubNavItems =
    <({Widget icon, String label})>[
      (
        icon: const tabler.LayoutDashboard(
          height: Tokens.iconMd,
          width: Tokens.iconMd,
          strokeWidth: 1.5,
        ),
        label: '主页',
      ),
      (
        // 彩色插画图标（2026-09-25 用户定：书籍.svg，原色渲染，不走单色线形语言）。
        icon: CustomIcons.book(),
        label: '笔记',
      ),
      (
        // 彩色插画图标（2026-09-24 用户定：阳光.svg，原色渲染）。
        icon: CustomIcons.canvas(),
        label: '画布',
      ),
      (
        // 全局搜索（2026-09-25）：入口是顶行搜索图标，这里只是主区分发的 label。
        // 单色线形——搜索是"工具"不是"空间"，不与笔记/画布的彩色插画混排。
        icon: const tabler.Search(
          height: Tokens.iconMd,
          width: Tokens.iconMd,
          strokeWidth: 1.5,
        ),
        label: '搜索',
      ),
    ];

/// **切换器选中的"空间"**：`false` = 笔记空间（除画布外的笔记），
/// `true` = 画布空间（[NoteKind.canvas]）。
///
/// ⚠️ 与 [hubNavSelectionProvider] **刻意解耦**（2026-09-24 用户定）：后者驱动
/// 主区（0 = 主页），本值只驱动切换器滑动 + 下面内联列表的**过滤**，**不切主区**
/// ——否则切一次空间，主区就被换成"_SectionPlaceholder"，主页没了。
final navSpaceProvider = NotifierProvider<NavSpace, bool>(NavSpace.new);

class NavSpace extends Notifier<bool> {
  @override
  bool build() => false; // 默认笔记空间

  void select(bool isCanvas) => state = isCanvas;
}

/// 从导航板顶行的「新建」新建一篇（菜单选了哪种就建哪种）。
///
/// 走 [runCommandById]（§3.2 命令是权威面：与 `Ctrl+N` / `Ctrl+Shift+N` **同一条
/// 路**，不就地调 notifier，否则迟早漂移成"按钮能建、快捷键不能"）。
///
/// ⚠️ **切空间这一步命令不做**（`runCreateNote` 只 create + locate）：不切的话，
/// 在笔记空间建画布 ⇒ 主区开了、侧栏列表却把新画布筛掉，正是"点了没反应"。
void createFromNav(WidgetRef ref, {required bool canvas}) {
  unawaited(runCommandById(ref, canvas ? 'canvas.new' : 'note.new'));
  ref.read(navSpaceProvider.notifier).select(canvas);
}

/// 主页导航当前选中的分区（0 = 主页）。
///
/// 骨架阶段它是唯一在动的导航状态。放在 provider 而不是组件的 `setState` 里：
/// **内容区也要读它**（占位分区要显示"还没建"），状态提升到双方共同的祖先之下。
final hubNavSelectionProvider = NotifierProvider<HubNavSelection, int>(
  HubNavSelection.new,
);

class HubNavSelection extends Notifier<int> {
  @override
  int build() => 0;

  void select(int index) => state = index;
}

/// 主页左侧的**导航板**（`docs/ui_rewrite_plan.md` §5.6，2026-09-22 对齐 Craft）。
///
/// 结构（2026-09-29 定）：全局工具图标已迁去主区顶条（home_screen.dart 的
/// [HomeNavButton] / [NavHistoryButton] / [SettingsNavButton]；同日 50px
/// 第一列总导航栏撤掉，[AppRail] 已删），
/// 本板只留"这个分区里的东西"——**空间切换器**（[_SpaceSwitch]，
/// 笔记 / 画布滑动切换，井内最右格「+」新建）→ **该空间的内联列表**
///（[_SpaceItemList]，按 [NoteKind] 过滤 [notesProvider]）。
/// 底 = [AppTheme.windowBackground]（与窗口同色平铺，见下）。
///
/// ## 切换器只换"看哪个空间"，不切主区（2026-09-24 用户定）
/// 原先「笔记 / 画布」是两行导航项（= 主区的目的地）。现在它们降级为**空间
/// 过滤器**：切换器写 [navSpaceProvider]（不碰 [hubNavSelectionProvider]，后者
/// 仍驱动主区 0 = 主页），下面列表随之过滤；点列表项才真的打开那篇笔记
/// （走 `locateProvider`）。
///
/// ## 主页不在列表里（2026-09-24 用户定）
/// 列表里的「主页」行撤掉，功能并入顶行主页图标：它既是入口（`select(0)`）
/// 也是"我在主页"的指示——`selected == 0` 时它披玻璃片（[_GlassSheet]），
/// 与列表项的选中语言完全同款。
///
/// ## 同色平铺（2026-09-24 用户定）：贴窗三边、无阴影无边距
/// 新拟态浮雕试了三轮后整体撤掉；列底与窗口底**同色**
/// （[AppTheme.windowBackground]），不靠色差也不靠阴影分层——整页恢复同色后，
/// 这一列在视觉上就是窗口的一部分。圆角回到"只圆右侧两角"：贴窗的两角必须是
/// 方角，否则窗口角露出两块窗口底的月牙。
class HubNav extends ConsumerWidget {
  const HubNav({super.key, this.width = 275});

  /// 板宽。**它就是这一列的全部宽度**（此前"不含窗口左缘 6px 间距"那句已作废：
  /// 间距取消了，宿主不再留缝）。
  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    // 当前空间（false = 笔记，true = 画布）：只驱动切换器 + 下面列表的过滤。
    final bool isCanvasSpace = ref.watch(navSpaceProvider);

    // 圆角：**只圆右边两角**——上 / 左 / 下贴窗（2026-09-24 用户定：恢复贴边），
    // 贴窗的两角若留圆角，窗口角会露出两块窗口底的月牙。
    const BorderRadius radius = BorderRadius.horizontal(
      right: Radius.circular(Tokens.radiusLg),
    );

    return SizedBox(
      width: width,
      child: DecoratedBox(
        decoration: BoxDecoration(
          // 整个页面**同色**（2026-09-24 用户定：撤掉浮雕后恢复平铺）——
          // 列底 = 窗口底，不靠色差也不靠阴影分层。
          color: AppTheme.windowBackground(theme.brightness),
          borderRadius: radius,
        ),
        // **必须裁切**：底色是满矩形，右边两角的圆角靠它收口。
        // 已经把底色画成圆角了，这里防的是列表行的 hover 底色块（矩形）滚到
        // 右上 / 右下圆角处露出方角。⚠️ 别因"底色本来就是圆的"就把它删了
        child: ClipRRect(
          borderRadius: radius,
          child: Column(
            crossAxisAlignment: .stretch,
            children: <Widget>[
              // 全局图标（主页 / 搜索 / 收藏 / 设置）2026-09-29 迁去最左的
              // 总导航栏 [AppRail]——本板只留"这个分区里的东西"：上呼吸后
              // 直接是空间切换器。
              const SizedBox(height: Tokens.spaceSm),
              // **空间切换器**：井内三格——笔记 / 画布（平分、滑块在其间滑）+
              // 最右一枚正方「+」格（和滑块同款凸玻璃，点它弹「新建笔记 / 新建画布」
              // 菜单）。三格共用一个胶囊控件，"切空间 + 给那个空间加一篇"在同一
              // 控件里，语义直给、分区明确（2026-09-26 定，第二版：+ 收进井里）。
              // 「+」格的回调见 [_SpaceSwitch] 的 onNewNote / onNewCanvas。
              _SpaceSwitch(
                selected: isCanvasSpace,
                onChanged: (bool v) =>
                    ref.read(navSpaceProvider.notifier).select(v),
                onNewNote: () => createFromNav(ref, canvas: false),
                onNewCanvas: () => createFromNav(ref, canvas: true),
              ),
              const SizedBox(height: Tokens.spaceMd),
              // 该空间的**内联列表**（真实笔记，按 kind 过滤）。
              const Expanded(child: _SpaceItemList()),
            ],
          ),
        ),
      ),
    );
  }
}

/// **玻璃片的三层光**（选中态共用）：内光泽 + 顶沿光边 + 底沿厚度边——
/// 顶沿吃光、底沿投影，一对方位边读出"一块薄玻璃片躺在板上"。
///
/// 全部**纯绘制**（三条渐变），无 saveLayer、不随重绘付费（Liquid Glass 的
/// 低配釉面版；透光/折射那件只有模糊能给，见 [AppTheme] 玻璃档说明）。
/// 全部 `IgnorePointer` 且画在内容之下——光改的是"材质"，不给内容加滤镜。
/// 宿主的 `Material(clipBehavior: Clip.antiAlias)` 负责把光收进圆角。
///
/// ⚠️ 必须放在 `Positioned.fill` 里用（本类是**铺满宿主**的光层）。
/// 加力系数走 [AppTheme.glassSheetBoost]（小面积玻璃片的专用档）。
class _GlassSheet extends StatelessWidget {
  const _GlassSheet({required this.brightness});

  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    const double boost = AppTheme.glassSheetBoost;

    /// 全部 `IgnorePointer` 且画在内容之下——光改的是"材质"，不给内容加滤镜。
    // 简化：此前三个装饰层各包一个，重复 3 次；提到外层语义等价、少 3 个 widget）
    return IgnorePointer(
      child: Stack(
        children: <Widget>[
          // ① 内光泽：竖向，上沿最亮 → 45% 归零。
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: AppTheme.glassSheen(brightness, alphaScale: boost),
              ),
            ),
          ),
          // ② 顶沿光边：一条亮线、两端淡出。
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: AppTheme.glassRim(brightness, alphaScale: boost),
              ),
              child: const SizedBox(height: 1),
            ),
          ),
          // ③ 底沿厚度边：一条影线、两端淡出——与 ② 成对读出厚度。
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: AppTheme.glassBaseEdge(brightness, alphaScale: boost),
              ),
              child: const SizedBox(height: 1),
            ),
          ),
        ],
      ),
    );
  }
}

/// **空间切换器**：「笔记 / 画布」两段，[ColorScheme.primaryContainer] 药丸滑块
/// 在 [ColorScheme.surfaceContainer] 平轨道里**滑动**（220ms）。
///
/// M3 药丸方案（2026-09-29 用户定，替掉原新拟态"井 + 凸玻璃"）：
/// - **轨道 = 平的**：[ColorScheme.surfaceContainer] 实色，**无内渐变**（不读作
///   "凹"）、无阴影；
/// - **滑块 = 药丸**：[ColorScheme.primaryContainer] 实色 + stadium 全圆角，
///   **无阴影、无玻璃三层光**；
/// - 两段标签**静止不动**（iOS 分段控件语言），滑块在其下滑动 ⇒ 文字不会跟着
///   位移、也不会被不透明滑块盖住（滑块画在标签**之下**）；
///
/// **为什么换掉新拟态**：凹凸感依赖"明度方向"，而暗色下表面阶梯是**翻转**的
/// （越浮起越亮、没有更深的井可挖）⇒ 明暗两套必然长得不一样（[AppTheme.raisedFill]
/// 注释记着两次失败尝试）。改纯 [ColorScheme] 驱动后明暗**天然对称**：选中信号
/// 由有色药丸给出，不再靠明度差。全控件纯色填充 ⇒ 无 saveLayer、无 blur。
///
/// ⚠️ 切换器**无阴影、无玻璃**（2026-09-29 改 M3 药丸）。
///
/// 整板浮雕是 2026-09-24 撤掉的方案；凸阴影曾是"只挂在滑块上"的唯一例外，
/// 现随新拟态一并去除——全控件只剩 [ColorScheme] 纯色填充，无 saveLayer。
class _SpaceSwitch extends StatefulWidget {
  const _SpaceSwitch({
    required this.selected,
    required this.onChanged,
    required this.onNewNote,
    required this.onNewCanvas,
  });

  /// `true` = 画布空间（滑块在右半边）。
  final bool selected;

  /// 切到哪个空间（`true` = 画布）。
  final ValueChanged<bool> onChanged;

  /// 点切换器最右那枚「+」方格 ⇒ 弹「新建笔记 / 新建画布」菜单。
  final VoidCallback onNewNote;

  /// 菜单里选了「新建画布」。
  final VoidCallback onNewCanvas;

  @override
  State<_SpaceSwitch> createState() => _SpaceSwitchState();
}

class _SpaceSwitchState extends State<_SpaceSwitch> {
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 轨道与滑块之间露出的那圈内边距。
    const double trackPad = 3;
    const double height = 36;
    // M3 药丸：轨道 = 中性 surface 一档，滑块 = 主色容器一档。两者都**只吃
    // ColorScheme**（明暗各自派生）⇒ 选中信号来自色相而非明度差，明暗对称。
    final Color trackFill = theme.colorScheme.surfaceContainer;
    final Color thumbFill = theme.colorScheme.primaryContainer;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: FocusRing(
        focusNode: _focus,
        // 焦点环跟着药丸走：半径 = 控件高的一半（stadium）。
        borderRadius: BorderRadius.circular(height / 2),
        child: Focus(
          focusNode: _focus,
          // ← / → 切空间（桌面端键盘流：整个切换器是一个 Tab 停靠点）。
          onKeyEvent: (FocusNode _, KeyEvent event) {
            if (event is KeyDownEvent) {
              if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                widget.onChanged(false);
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                widget.onChanged(true);
                return KeyEventResult.handled;
              }
            }
            return KeyEventResult.ignored;
          },
          child: LayoutBuilder(
            builder: (BuildContext _, BoxConstraints c) {
              // 布局：[笔记][画布] 平分剩余空间，最右一枚**正方「+」格**
              // （宽 = 高 = 滑块高，见下）。横向账（都用 trackPad 这一个厚度）：
              //   滑块左缩进 trackPad ｜ 笔记+画布（Expanded×2）｜ 缝 trackPad
              //   ｜「+」格 action ｜ 右侧井厚 trackPad
              // 滑块只盖笔记 / 画布（+ 是动作，不吃滑块），seg 比 Expanded 窄
              // 一个 trackPad——保证滑块左缘在"画布"起点、右缘距井右壁 trackPad，
              // 与两格版同样的对称几何。
              const double action = height - 2 * trackPad;
              final double seg = (c.maxWidth - 4 * trackPad - action) / 2;
              return SizedBox(
                height: height,
                child: Stack(
                  children: <Widget>[
                    // 轨道（平的 M3 surface 一档，无内渐变 ⇒ 不读作"凹"）
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: trackFill,
                          // 药丸：stadium（半径 = 高的一半），不写魔法数字。
                          borderRadius: BorderRadius.circular(height / 2),
                        ),
                      ),
                    ),
                    // ② 滑块（M3 药丸）：left 在 0 ↔ seg 之间动画。
                    AnimatedPositioned(
                      key: const Key('spaceThumb'),
                      left: trackPad + (widget.selected ? seg : 0),
                      top: trackPad,
                      width: seg,
                      height: height - 2 * trackPad,
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: thumbFill,
                          // 药丸：stadium（半径 = 滑块高的一半）。
                          borderRadius: BorderRadius.circular(
                            (height - 2 * trackPad) / 2,
                          ),
                        ),
                      ),
                    ),
                    // ③ 三格（画在滑块**之上** ⇒ 文字不会被不透明滑块盖住）。
                    // 前两格是空间切换（active 随选中态，Expanded 平分）；最右是
                    // 「+」正方格——和滑块同一枚凸玻璃材料，点它弹新建菜单
                    // （见 [_NewButton]）。
                    Row(
                      children: <Widget>[
                        _Segment(
                          icon: CustomIcons.book(size: 16),
                          label: '笔记',
                          active: !widget.selected,
                          onTap: () => widget.onChanged(false),
                        ),
                        _Segment(
                          icon: CustomIcons.canvas(size: 16),
                          label: '画布',
                          active: widget.selected,
                          onTap: () => widget.onChanged(true),
                        ),
                        // 井缝：把「+」格与滑块活动区分开（厚度与井壁一致）。
                        const SizedBox(width: trackPad),
                        SizedBox(
                          width: action,
                          height: action,
                          child: _NewButton(
                            onNewNote: widget.onNewNote,
                            onNewCanvas: widget.onNewCanvas,
                          ),
                        ),
                        // 右侧井厚：让「+」格与滑块同样缩进 trackPad。
                        const SizedBox(width: trackPad),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 切换器里的**一段**（左 = 笔记 / 右 = 画布）：彩色插画图标 + 标签，**静止不动**，
/// 由底下滑动的玻璃滑块指示"哪段是活的"。
///
/// 用 [GestureDetector] 而不是 `InkWell`：命中区要完全透明（滑块的凸阴影就是
/// 唯一的反馈），且不需要 `Material` 祖先去画水波纹。
class _Segment extends StatelessWidget {
  const _Segment({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final Widget icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Expanded(
      child: GestureDetector(
        behavior: .opaque,
        onTap: onTap,
        child: Center(
          child: Row(
            mainAxisSize: .min,
            children: <Widget>[
              icon,
              const SizedBox(width: 6),
              Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  // 激活段坐在 primaryContainer 药丸上 ⇒ 必须配 onPrimaryContainer
                  // （M3 容器/内容配对），沿用 onSurface 会和药丸底色打架。
                  color: active
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: active ? FontWeight.w600 : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 切换器**轨道里最右**那枚「新建」正方格（2026-09-26 定；2026-09-29 随切换器
/// 一起改平）：与轨道同一套 M3 语言——静止态**透明**（不抢药丸的选中信号），
/// hover 才浮出 [ColorScheme.surfaceContainerHighest] 一档。无阴影、无玻璃光。
///
/// 尺寸由父级给（切换器里 = 滑块高的正方）；它**不吃滑块**——滑块只管
/// 笔记 / 画布两空间，「+」是动作，永远可点。点它弹
/// 「新建笔记 / 新建画布」菜单（用户定：保留菜单，不改成"直接建当前空间"），
/// 锚点贴它右下角。
///
/// ⚠️ 不用 `Material`（拖进 InkWell 会撞"静止态落到 canvasColor 变黑块"
/// 那个坑，且会把 hub_nav_test 的 Material 计数顶上去）。
/// 反馈全靠 hover 换底色，纯 DecoratedBox 绘制，无 saveLayer。
class _NewButton extends StatefulWidget {
  const _NewButton({required this.onNewNote, required this.onNewCanvas});

  /// 菜单里选了「新建笔记」。
  final VoidCallback onNewNote;

  /// 菜单里选了「新建画布」。
  final VoidCallback onNewCanvas;

  @override
  State<_NewButton> createState() => _NewButtonState();
}

class _NewButtonState extends State<_NewButton> {
  /// 菜单锚点：贴按钮**右下角**弹出（与条目「···」菜单同款做法）。
  final GlobalKey _key = GlobalKey();
  bool _hover = false;

  Future<void> _openMenu() async {
    Offset position = Offset.zero;
    final RenderBox? box =
        _key.currentContext?.findRenderObject() as RenderBox?;
    if (box != null) {
      position = box.localToGlobal(Offset(box.size.width, box.size.height));
    }
    await showMenu<void>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: <PopupMenuEntry<void>>[
        _item(
          icon: CustomIcons.book(size: 16),
          label: '新建笔记',
          shortcut: 'Ctrl+N',
          onTap: widget.onNewNote,
        ),
        _item(
          icon: CustomIcons.canvas(size: 16),
          label: '新建画布',
          shortcut: 'Ctrl+Shift+N',
          onTap: widget.onNewCanvas,
        ),
      ],
    );
  }

  PopupMenuItem<void> _item({
    required Widget icon,
    required String label,
    required String shortcut,
    required VoidCallback onTap,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return PopupMenuItem<void>(
      onTap: onTap,
      child: Row(
        children: <Widget>[
          icon,
          const SizedBox(width: Tokens.spaceSm),
          Text(label, style: TextStyle(color: scheme.onSurface)),
          const SizedBox(width: Tokens.spaceMd),
          // 快捷键是**发现入口**（§3.5）：写在行尾，不抢标题。
          Text(
            shortcut,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 静止态透明（不抢药丸的选中信号），hover 才浮出一档 surface。尺寸**由父级给**
    // （切换器里 = 滑块高的正方，见 [_SpaceSwitchState]），这里只铺"底 + 图标"。
    final Color hoverFill = theme.colorScheme.surfaceContainerHighest;
    // 挂菜单锚点（GlobalKey）：不挂的话 `_key.currentContext` 恒为 null，
    // position 落在 Offset.zero ⇒ 菜单弹到屏幕左上角（2026-09-26 实机抓到）。
    return GestureDetector(
      // 菜单锚点。曾因漏挂这里菜单弹到屏幕左上（回归闸门：hub_nav_test 锚点断言）。
      key: _key,
      behavior: .opaque,
      onTap: _openMenu,
      child: MouseRegion(
        // MouseRegion 在 hover 中被卸载也会派发 onExit（列表被过滤/重建时
        // 就会发生），直接 setState 会撞 "setState after dispose"。
        onEnter: (_) {
          if (mounted) setState(() => _hover = true);
        },
        onExit: (_) {
          if (mounted) setState(() => _hover = false);
        },
        child: Tooltip(
          message: '新建',
          child: Stack(
            children: <Widget>[
              // ① 底：静止透明，hover 浮出 surface 一档（纯色、无阴影、无玻璃）。
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: _hover ? hoverFill : Colors.transparent,
                    borderRadius: BorderRadius.circular(Tokens.radiusLg),
                  ),
                ),
              ),
              // ② 「+」图标居中（中性灰，与空闲段文字同色）。
              Positioned.fill(
                child: Center(
                  child: CustomIcons.add(
                    size: Tokens.iconMdSm,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 导航板里的一行：图标 + 标签，高 36，圆角 8。
///
/// 状态：
/// - **选中 = 玻璃片**（2026-09-24 用户定，取代裸 tint pill）：底仍是
///   [AppTheme.navSelectedTint]（onSurface 10%，"我在哪"的中性读法不变），
///   之上叠三层**纯绘制的光**——内光泽 + 顶沿光边 + **底沿厚度边**
///   （[AppTheme.glassBaseEdge]）：顶沿吃光、底沿投影，一对方位边读出
///   "一块薄玻璃片躺在板上"。无 saveLayer、不随重绘付费（Liquid Glass 的
///   低配釉面版；透光/折射那件只有模糊能给，见 [AppTheme] 玻璃档说明）。
/// - 悬停 = [AppTheme.boardFillHover]（刻意轻，与全应用"再叠一档"同语言）。
///
/// ⚠️ 静止态**必须显式 `Colors.transparent`**，不能传 null：`Material(color: null)`
/// 会落到 canvasColor（= `surface` = 近黑的窗口底色）⇒ 每个未选中项都自己画一块
/// 黑方块，把板底盖住（2026-09-22 用户实报"还是黑色显示"）。
/// 切换器下面的**内联列表**：读 [notesProvider]，按当前空间（[navSpaceProvider]）
/// 过滤——笔记空间 = 除画布外的笔记，画布空间 = [NoteKind.canvas]。
///
/// 点行 = 打开那篇笔记，走 `locateProvider`（§4 的唯一跳转通道），**不改变
/// 当前空间**（空间是"看哪一类"，打开是"看哪一篇"，两件事）。
class _SpaceItemList extends ConsumerWidget {
  const _SpaceItemList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final bool isCanvasSpace = ref.watch(navSpaceProvider);
    final List<Note> all = ref.watch(notesProvider).value ?? const <Note>[];
    final String? openId = ref.watch(selectedNoteIdProvider);

    final List<Note> items = all
        .where(
          (Note n) => isCanvasSpace
              ? n.kind == NoteKind.canvas
              : n.kind != NoteKind.canvas,
        )
        .toList();

    if (items.isEmpty) {
      return Center(
        child: Text(
          isCanvasSpace ? '还没有画布' : '还没有笔记',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    // 删除 + 可撤销提示（与 [NoteListView] 同一个 [showUndoToast] 通道）。
    // ⚠️ 必须是 build 内的局部函数：ConsumerWidget 的 `ref` 只在 build 作用域
    // 可见，子方法读不到（2026-09-25 修）。
    Future<void> deleteNote(Note note) async {
      final NotesNotifier notifier = ref.read(notesProvider.notifier);
      final Note? removed = await notifier.deleteNote(note.id);
      if (removed == null || !context.mounted) return;
      final String title = removed.title.isNotEmpty ? removed.title : '无标题';
      showUndoToast(
        context,
        message: '已删除「$title」',
        onUndo: () => notifier.restoreNote(removed),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: items.length,
      itemBuilder: (BuildContext _, int i) => SpaceItemRow(
        note: items[i],
        open: items[i].id == openId,
        onTap: () =>
            ref.read(locateProvider.notifier).locate(noteId: items[i].id),
        // 右键 / 「···」菜单三件事，与左侧 [NoteListView] 的条目同源：
        // 重命名（就地）/ 收藏（togglePromoted）/ 删除（带撤销提示）。
        onRename: (String title) =>
            ref.read(notesProvider.notifier).saveTitle(items[i].id, title),
        onTogglePromoted: () =>
            ref.read(notesProvider.notifier).togglePromoted(items[i]),
        onDelete: () => deleteNote(items[i]),
      ),
    );
  }
}

/// 内联列表里的一行：标题 + 行尾相对时间，高 34（比导航项略紧，因为它是
/// "一页纸"里的文本行，不是按钮）。
///
/// 状态（与全列同语言）：
/// - **正在打开的那篇** = 玻璃片（[AppTheme.navSelectedTint] + [_GlassSheet]
///   三层光）——与顶行主页图标的选中态完全同款；
/// - 悬停 = [AppTheme.boardFillHover]（再叠一层）
///
/// ⚠️ 静止态**必须显式 `Colors.transparent`**，不能传 null：`Material(color: null)`
/// 会落进 canvasColor（近黑的窗口底色）——每行自己画一块黑方块盖住板底
/// 2026-09-22 用户实报"还是黑色显示"）
/// 内联列表里的一行：标题 + 行尾相对时间，高 34（比导航项略紧，因为它是
/// "一页纸"里的文本行，不是按钮）。
///
/// 状态（与全列同语言）：
/// - **正在打开的那篇** = 玻璃片（[AppTheme.navSelectedTint] + [_GlassSheet]
///   三层光）——与顶行主页图标的选中态完全同款；
/// - 悬停 = [AppTheme.boardFillHover]（再叠一层）
///
/// ## 操作入口（与 [NoteListView] 的条目同款）
/// 两条入口、同一个菜单：**右键条目** 与 **悬停时右侧浮出的「···」**。
/// 菜单三件事：重命名（就地改标题）/ 收藏（togglePromoted）/ 删除（带撤销）。
/// 收藏项标题前还钉一枚星标（与左侧列表一致）。
///
/// ⚠️ 静止态**必须显式 `Colors.transparent`**，不能传 null：`Material(color: null)`
/// 会落进 canvasColor（近黑的窗口底色）——每行自己画一块黑方块盖住板底
/// 2026-09-22 用户实报"还是黑色显示"）
class SpaceItemRow extends StatefulWidget {
  const SpaceItemRow({
    super.key,
    required this.note,
    required this.open,
    required this.onTap,
    required this.onRename,
    required this.onTogglePromoted,
    required this.onDelete,
    this.showKindIcon = false,
  });

  final Note note;

  /// 这篇就是主区当前打开的那篇。
  final bool open;

  final VoidCallback onTap;

  /// 就地改名后的回调（父层落库）。
  final ValueChanged<String> onRename;

  /// 收藏切换（togglePromoted）。
  final VoidCallback onTogglePromoted;

  /// 删除（带撤销提示）。
  final VoidCallback onDelete;

  /// 是否在行首额外标出形态图标（笔记/画布）。默认 false——导航板内联列表
  /// 不传（列表已按空间分形态，冗余）；收藏页两栏传 true，行上也能一眼区分。
  final bool showKindIcon;

  @override
  State<SpaceItemRow> createState() => SpaceItemRowState();
}

class SpaceItemRowState extends State<SpaceItemRow> {
  final FocusNode _focus = FocusNode();
  bool _hover = false;

  /// 本条目的菜单是否正开着（同 [NoteListView]）：菜单是模态路由，指针落到
  /// 菜单上 ⇒ `hovered` 变 false，行高亮与「···」会一起消失，断了"菜单对着
  /// 哪篇"的视觉联系。用 setState（低频一次性事件）即可。
  bool _menuOpen = false;

  /// 「···」按钮的锚点（菜单贴按钮右下角弹出）。
  final GlobalKey _moreKey = GlobalKey();

  /// 就地重命名的编辑态与控制器（同 [NoteListView]）。
  bool _renaming = false;
  final TextEditingController _renameController = TextEditingController();
  final FocusNode _renameFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _renameFocus.addListener(_onRenameFocusChanged);
  }

  void _onRenameFocusChanged() {
    if (!_renameFocus.hasFocus && _renaming) _commitRename();
  }

  @override
  void dispose() {
    _renameFocus.removeListener(_onRenameFocusChanged);
    _renameFocus.dispose();
    _renameController.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _startRename() {
    final String title = widget.note.title;
    _renameController
      ..text = title
      ..selection = TextSelection(baseOffset: 0, extentOffset: title.length);
    setState(() => _renaming = true);
    // 菜单刚 pop、焦点还在路由上：延到帧末再抢焦点，否则会被弹层收走。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _renameFocus.requestFocus();
    });
  }

  void _commitRename() {
    final String value = _renameController.text.trim();
    if (mounted) setState(() => _renaming = false);
    if (value != widget.note.title.trim()) widget.onRename(value);
  }

  /// 弹出条目菜单。[globalPosition] 为空时贴「···」按钮右下角。
  Future<void> _openMenu([Offset? globalPosition]) async {
    Offset position = globalPosition ?? Offset.zero;
    if (globalPosition == null) {
      final RenderBox? box =
          _moreKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null) {
        position = box.localToGlobal(Offset(box.size.width, box.size.height));
      }
    }

    setState(() => _menuOpen = true);

    final bool promoted = widget.note.promotedAt != null;
    await showMenu<void>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: <PopupMenuEntry<void>>[
        _menuItem(
          icon: const tabler.Edit(
            height: Tokens.iconMd,
            width: Tokens.iconMd,
            strokeWidth: 1.5,
          ),
          label: '重命名',
          onTap: _startRename,
        ),
        _menuItem(
          icon: promoted
              ? const tabler.StarFilled(
                  height: Tokens.iconMd,
                  width: Tokens.iconMd,
                  strokeWidth: 1.5,
                )
              : const tabler.Star(
                  height: Tokens.iconMd,
                  width: Tokens.iconMd,
                  strokeWidth: 1.5,
                ),
          label: promoted ? '取消收藏' : '收藏',
          onTap: widget.onTogglePromoted,
        ),
        const PopupMenuDivider(),
        _menuItem(
          icon: const tabler.Trash(
            height: Tokens.iconMd,
            width: Tokens.iconMd,
            strokeWidth: 1.5,
          ),
          label: '删除笔记',
          // 危险动作：图标与文字都用 error 色（M3 的 destructive 口径）。
          danger: true,
          onTap: widget.onDelete,
        ),
      ],
    );
    if (mounted) setState(() => _menuOpen = false);
  }

  PopupMenuItem<void> _menuItem({
    required Widget icon,
    required String label,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color color = danger ? scheme.error : scheme.onSurface;
    return PopupMenuItem<void>(
      onTap: onTap,
      child: Row(
        children: <Widget>[
          icon,
          const SizedBox(width: Tokens.spaceSm),
          Text(label, style: TextStyle(color: color)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Brightness brightness = theme.brightness;
    final ColorScheme scheme = theme.colorScheme;
    // "本条正被交互"：指针在行上，**或**本条的菜单开着。
    final bool active = _hover || _menuOpen;
    final Color fill = widget.open
        ? AppTheme.navSelectedTint(scheme.onSurface)
        : active
        ? AppTheme.boardFillHover(brightness)
        : Colors.transparent;

    // 悬浮跟踪用**外层 MouseRegion**（与左侧 [NoteListView] 的条目同款）：
    // InkWell 的 onHover 在这套 GestureDetector 嵌套里拿不到 hover，故显式跟踪
    // _hover，再由上面的 fill 决定底色（黑/白 5% 叠加档）。
    return MouseRegion(
      // 同 [_NewButton]：卸载中派发的 onExit 不许 setState。
      onEnter: (_) {
        if (mounted) setState(() => _hover = true);
      },
      onExit: (_) {
        if (mounted) setState(() => _hover = false);
      },
      child: GestureDetector(
        // 改名期间禁用整条点击：否则点击输入框会连带"切换笔记"。
        onTap: _renaming ? null : widget.onTap,
        // 右键（与左侧列表同款入口）：在指针处弹出条目菜单。
        onSecondaryTapDown: _renaming
            ? null
            : (TapDownDetails details) => _openMenu(details.globalPosition),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: FocusRing(
            focusNode: _focus,
            borderRadius: BorderRadius.circular(8),
            child: Material(
              color: fill,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: .antiAlias,
              // 命中区透明：整行可点，背景填色全靠上面的 fill。
              child: SizedBox(
                height: 34,
                width: double.infinity,
                child: Stack(
                  // ⚠️ 必须显式居中（同 [HubNav] 那个已修过的坑：Stack 默认
                  // topStart 会把非定位的 Row 钉在上沿）。
                  alignment: AlignmentDirectional.center,
                  children: <Widget>[
                    if (widget.open)
                      Positioned.fill(
                        child: _GlassSheet(brightness: brightness),
                      ),
                    Row(
                      children: <Widget>[
                        const SizedBox(width: 10),
                        // 形态图标（可选，仅收藏页两栏）：笔记=FileText / 画布=LayoutGrid。
                        // （AppIconTheme 桥接的 onSurfaceVariant）一致。
                        if (widget.showKindIcon) ...<Widget>[
                          widget.note.kind == NoteKind.canvas
                              ? tabler.LayoutGrid(
                                  height: Tokens.iconXs,
                                  width: Tokens.iconXs,
                                  strokeWidth: 1.5,
                                  colorFilter: ui.ColorFilter.mode(
                                    scheme.onSurfaceVariant,
                                    ui.BlendMode.srcIn,
                                  ),
                                )
                              : tabler.FileText(
                                  height: Tokens.iconXs,
                                  width: Tokens.iconXs,
                                  strokeWidth: 1.5,
                                  colorFilter: ui.ColorFilter.mode(
                                    scheme.onSurfaceVariant,
                                    ui.BlendMode.srcIn,
                                  ),
                                ),
                          const SizedBox(width: Tokens.spaceXs),
                        ],
                        // 收藏标记：星标紧贴标题（无收藏时不显示）。
                        if (widget.note.promotedAt != null) ...<Widget>[
                          tabler.StarFilled(
                            height: Tokens.iconXs,
                            width: Tokens.iconXs,
                            strokeWidth: 1.5,
                            colorFilter: ui.ColorFilter.mode(
                              scheme.onSurfaceVariant,
                              ui.BlendMode.srcIn,
                            ),
                          ),
                          const SizedBox(width: Tokens.spaceXs),
                        ],
                        Expanded(
                          child: _renaming
                              // 就地改名：同样的字号/字色，去掉装饰，读起来还是"标题"。
                              ? TextField(
                                  controller: _renameController,
                                  focusNode: _renameFocus,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: scheme.onSurface,
                                  ),
                                  cursorColor: scheme.onSurface,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                  onSubmitted: (_) => _commitRename(),
                                )
                              : Text(
                                  // 笔记标题可能是空串（新建未命名）⇒ 给可读兜底。
                                  widget.note.title.isEmpty
                                      ? '无标题'
                                      : widget.note.title,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: widget.open
                                        ? scheme.onSurface
                                        : scheme.onSurfaceVariant,
                                    fontWeight: widget.open
                                        ? FontWeight.w600
                                        : null,
                                  ),
                                  maxLines: 1,
                                  overflow: .ellipsis,
                                ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _relativeTime(widget.note.revisedAt),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: Tokens.spaceSm),
                        // 「···」入口：hover/选中/菜单开着时显形（同左侧列表），
                        // 但**位置始终占位**——否则显隐会让标题宽度跳动。改名期间
                        // 让位给输入框（同时避免误点）。
                        SizedBox(
                          width: Tokens.formatButtonHeight,
                          child: Visibility(
                            visible: !_renaming && (widget.open || active),
                            maintainSize: true,
                            maintainAnimation: true,
                            maintainState: true,
                            child: IconButton(
                              key: _moreKey,
                              tooltip: '更多',
                              padding: EdgeInsets.zero,
                              iconSize: Tokens.iconMd,
                              icon: const tabler.DotsVertical(
                                height: Tokens.iconMd,
                                width: Tokens.iconMd,
                                strokeWidth: 1.5,
                              ),
                              onPressed: _openMenu,
                            ),
                          ),
                        ),
                      ],
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

/// 相对时间（列表行尾的小灰字）。口径与 `home_hub.dart` 里的同名私有函数一致。
String _relativeTime(DateTime at) {
  final Duration d = DateTime.now().difference(at);
  if (d.inMinutes < 1) return '刚刚';
  if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
  if (d.inHours < 24) return '${d.inHours} 小时前';
  if (d.inDays < 7) return '${d.inDays} 天前';
  return '${at.month}/${at.day}';
}
