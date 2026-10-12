import 'dart:async';
import 'dart:ui' as ui;

import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/app_custom_icons.dart';
import '../theme/app_theme.dart';
import '../theme/focus_ring.dart';
import '../theme/tokens.dart';
import '../command/commands.dart';

/// **新建胶囊**（2026-10-12 定稿，当晚改**悬浮/键盘触发**）：立体拟态的"微凸
/// 托盘 + 可触发的『新建』枢纽 + 两枚同层按钮"。默认**收起**只显示「新建 ▾」；
/// 鼠标**悬停**托盘、或键盘 **Tab 聚焦**「新建」枢纽（见 [_NewNoteCapsuleState]
/// 的 `_hover` / `_scopeFocus`）时，托盘**展开**露出 笔记 / 画布两枚按钮——两者
/// 与托盘同层同色，边界用**凹陷槽**划出。鼠标移开且键盘焦点不在胶囊子树内时自动
/// 收起。
///
/// ## 演进记录（本轮全在这一个控件上）
/// 凹井（渐变下陷）→ 凸钮（内边缘高光/阴影）→ 纯扁平（无光影只留缝）→
/// 立体托盘 + 同层按钮 + 凹陷刻痕缝 → 有宽度的**凹陷槽**划界 → 高度降到 36 组
/// （托盘 36 / 槽 28 / 表面 22）→ 悬浮/键盘触发展开（`_hover || _pinned ||
/// _scopeFocus.hasFocus`）。托盘外框 2026-10-12 晚改为**锐利 bevel**
/// （[AppTheme.raisedBevel]：顶左亮 + 底右暗，无模糊阴影）。
///
/// ## 为什么是"枢纽"而非两枚常显按钮
/// 用户 2026-10-12 晚拍板：悬浮触发更轻，且键盘导航也能触发同一种展开。于是
/// 「新建」成为唯一焦点入口，展开后 Tab/方向键进入 笔记 / 画布，Enter 激活——
/// 全程无障碍可达（`FocusableActionDetector` + 统一 `FocusRing`）。
///
/// ## 走命令，不另起一条创建路径
/// 两枚按钮都经 `runCommandById`（`note.new` / `canvas.new`）⇒ 与全局键
/// `Ctrl+N` / `Ctrl+Shift+N` **同一条路**（§3.2 命令是权威面）。
///
/// ## 落点
/// 2026-10-12 晚从已删的左侧索引面板搬到工作区**左侧扁平导航** [HomeSidebar]
/// ——用户定"取消笔记索引面板、左侧只要扁平导航，新建直接可见"。
class NewNoteCapsule extends ConsumerStatefulWidget {
  const NewNoteCapsule({super.key});

  @override
  ConsumerState<NewNoteCapsule> createState() => _NewNoteCapsuleState();
}

class _NewNoteCapsuleState extends ConsumerState<NewNoteCapsule> {
  /// 外托盘高。
  static const double _kHeight = 36;

  /// 按钮槽（含凹陷槽）高：28 = 表面 22 + 上下各 3px 凹陷槽。
  static const double _kInnerHeight = 28;

  /// 托盘内边距 = (36 − 28) / 2 = 4，这条内边距就是凹陷槽与托盘边缘之间的
  /// **缝隙**（露出托盘色）。
  static const double _kPad = (_kHeight - _kInnerHeight) / 2;

  /// 展开后每枚按钮的固定宽（中文 2 字 + 图标 + 槽，留白到 80）。
  static const double _kButtonWidth = 80;

  /// 包住整条胶囊的 `Focus`：自己不抢焦点（`canRequestFocus: false`），只在
  /// 任一子孙（「新建」枢纽或某枚按钮）获得键盘焦点时 `hasFocus == true` ⇒
  /// 用作"键盘是否正在用这条胶囊"的判据，键盘从枢纽 Tab 到按钮也不会塌。
  final FocusNode _scopeFocus = FocusNode();

  /// 「新建」枢纽自己的焦点节点（焦点环 + 键盘激活都用它）。
  final FocusNode _triggerFocus = FocusNode();

  bool _hover = false;

  /// 点「新建」枢纽切换的"钉住展开"态：鼠标点击（无焦点也能）展开后保持，
  /// 再点收起。与 `_hover`（鼠标悬停）、`_scopeFocus.hasFocus`（键盘聚焦）三者
  /// 任一为真即展开。
  bool _pinned = false;

  @override
  void initState() {
    super.initState();
    _scopeFocus.addListener(_onScopeFocus);
  }

  @override
  void dispose() {
    _scopeFocus
      ..removeListener(_onScopeFocus)
      ..dispose();
    _triggerFocus.dispose();
    super.dispose();
  }

  void _onScopeFocus() {
    // 焦点变化在帧末结算，直接 setState 即可（见 focus_ring.dart 的调试经验）。
    if (mounted) setState(() {});
  }

  bool get _open => _hover || _pinned || _scopeFocus.hasFocus;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Brightness brightness = theme.brightness;
    final bool open = _open;

    return Focus(
      focusNode: _scopeFocus,
      canRequestFocus: false,
      // 左对齐：胶囊宽度随展开/收起变化（不被父级的 stretch 拉满整行宽）。
      // ⚠️ MouseRegion 必须放在 Align **里面**——Align 在 stretch 的容器里
      // 会被拉满整行，若 MouseRegion 包在 Align 外，悬停区域就变成整行空白
      // （鼠标没碰到胶囊也会触发）。放里面后 MouseRegion 只覆盖胶囊本身体积。
      child: Align(
        alignment: Alignment.centerLeft,
        child: MouseRegion(
          onEnter: (_) {
            if (!_hover) setState(() => _hover = true);
          },
          onExit: (_) {
            if (_hover) setState(() => _hover = false);
          },
          child: AnimatedSize(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            alignment: Alignment.centerLeft,
            child: Container(
              // 包豪斯扁平：实心蓝块 + 4px 硬边，无 bevel / 投影 / 渐变。
              height: _kHeight,
              decoration: BoxDecoration(
                color: Bauhaus.blue(brightness),
                borderRadius: Bauhaus.radius,
              ),
              padding: const EdgeInsets.symmetric(horizontal: _kPad),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _buildTrigger(theme, brightness, open),
                  if (open) ...<Widget>[
                    const SizedBox(width: Tokens.spaceSm),
                    SizedBox(
                      width: _kButtonWidth,
                      child: _TypeButton(
                        icon: tabler.FileText(
                          height: Tokens.iconSm,
                          width: Tokens.iconSm,
                          strokeWidth: Tokens.iconStroke,
                          colorFilter: ui.ColorFilter.mode(
                            Bauhaus.ink(brightness),
                            ui.BlendMode.srcIn,
                          ),
                        ),
                        label: '笔记',
                        tooltip: '新建笔记（Ctrl+N）',
                        onTap: () => unawaited(runCommandById(ref, 'note.new')),
                        brightness: brightness,
                        filled: true,
                      ),
                    ),
                    const SizedBox(width: Tokens.spaceSm),
                    SizedBox(
                      width: _kButtonWidth,
                      child: _TypeButton(
                        // 彩色插画**保留**（用户 2026-10-12 明确要插画）。
                        icon: CustomIcons.canvas(size: Tokens.iconSm + 2),
                        label: '画布',
                        tooltip: '新建画布（Ctrl+Shift+N）',
                        onTap: () => unawaited(runCommandById(ref, 'canvas.new')),
                        brightness: brightness,
                        filled: false,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 「新建」枢纽：`FocusableActionDetector` 让它可被键盘聚焦（Tab/Enter 切换
  /// 展开），统一 `FocusRing` 画焦点环；鼠标点击（无焦点）也切换展开（见
  /// `_pinned`）。右侧小箭头提示"还有更多"。
  Widget _buildTrigger(ThemeData theme, Brightness brightness, bool open) {
    return FocusableActionDetector(
      focusNode: _triggerFocus,
      mouseCursor: SystemMouseCursors.click,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<Intent>(
          onInvoke: (_) {
            // 键盘激活（Enter/Space）= 切换展开。
            if (mounted) setState(() => _pinned = !_pinned);
            return null;
          },
        ),
      },
      child: FocusRing(
        focusNode: _triggerFocus,
        borderRadius: Bauhaus.radius,
        child: GestureDetector(
          onTap: () {
            // 鼠标点击 = 切换展开（聚焦路径之外也能用）。
            setState(() => _pinned = !_pinned);
          },
          child: SizedBox(
            height: _kInnerHeight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceSm),
                  child: Text(
                    '新建',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Bauhaus.paper(brightness),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                tabler.ChevronDown(
                  height: Tokens.iconXs,
                  width: Tokens.iconXs,
                  strokeWidth: Tokens.iconStroke,
                  colorFilter: ui.ColorFilter.mode(
                    Bauhaus.paper(brightness),
                    ui.BlendMode.srcIn,
                  ),
                ),
                const SizedBox(width: Tokens.iconXs),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 蓝托盘上的一枚**扁平包豪斯按钮**：4px 硬边、无投影/渐变。两种变体用
/// **实心 vs 描边**区分（包豪斯的经典对比，不靠同色+凹槽）：
/// - `filled: true`（笔记）= 实心**纸面**块 + 墨字，hover 转**黄**；
/// - `filled: false`（画布）= **透明 + 2px 纸描边** + 纸字，hover 纸 20%。
/// 可键盘聚焦（`FocusableActionDetector` + `FocusRing`，与全仓一致）。
class _TypeButton extends StatefulWidget {
  const _TypeButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
    required this.brightness,
    required this.filled,
  });

  final Widget icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;
  final Brightness brightness;
  final bool filled;

  @override
  State<_TypeButton> createState() => _TypeButtonState();
}

class _TypeButtonState extends State<_TypeButton> {
  bool _hover = false;

  /// 自己的焦点节点：交给 `FocusRing`（画环）与 `FocusableActionDetector`
  /// （键盘聚焦/激活）共用——这是本仓焦点环基建的标准用法（见 focus_ring.dart）。
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
    final bool filled = widget.filled;
    final Color fg = filled ? Bauhaus.ink(b) : Bauhaus.paper(b);
    final Color bg = filled
        ? (_hover ? Bauhaus.yellow(b) : Bauhaus.paper(b))
        : (_hover
              ? Bauhaus.paper(b).withValues(alpha: 0.20)
              : Colors.transparent);
    return FocusRing(
      focusNode: _focus,
      borderRadius: Bauhaus.radius,
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
        // 鼠标点按仍走 InkWell（焦点/键盘激活走上面的 FocusableActionDetector）。
        child: Tooltip(
          message: widget.tooltip,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: Bauhaus.radius,
              hoverColor: Colors.transparent,
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
              child: MouseRegion(
                onEnter: (_) {
                  if (!_hover) setState(() => _hover = true);
                },
                onExit: (_) {
                  if (_hover) setState(() => _hover = false);
                },
                // 扁平块：实心（纸）或描边（2px 纸），4px 硬边。
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeOut,
                  height: _NewNoteCapsuleState._kInnerHeight,
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: Bauhaus.radius,
                    border: filled
                        ? null
                        : Border.all(color: Bauhaus.paper(b), width: 2),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      widget.icon,
                      const SizedBox(width: Tokens.spaceXs),
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
              ),
            ),
          ),
        ),
      ),
    );
  }
}
