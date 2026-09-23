import 'dart:async';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;
import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';

/// 左下角的轻量通知条（"已删除 · 撤销"这类**可撤销**提示）。
///
/// ## 为什么不用 `SnackBar`
/// 1. **宽度**：SnackBar 由 [Scaffold] 铺满整行（实测截图里横跨整个窗口），
///    桌面上像一条横幅；这里要的是**贴着左下角的窄条**。
/// 2. **消失时机**：SnackBar 的自动消失依赖它自己的动画状态机；在本应用
///    （自绘标题栏 + 透明 Scaffold + 材质桥）上实测**不自动消失**，只能点
///    ✕。这里用自持 [Timer] 明确负责"到点就走"。
///
/// 行为：最多同时只有一条（新提示顶掉旧的）；入场淡入上浮、退场淡出；
/// 8 秒后自动消失；「撤销」或 ✕ 之后立即消失。
const Duration kUndoToastDuration = Duration(seconds: 8);

/// 当前正在显示的那条（新的顶掉旧的，避免叠成一摞）。
OverlayEntry? _currentEntry;

/// 在左下角弹一条可撤销通知。
void showUndoToast(
  BuildContext context, {
  required String message,
  required VoidCallback onUndo,
  String actionLabel = '撤销',
  Duration duration = kUndoToastDuration,
}) {
  final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;

  dismissUndoToast();

  // 先声明再赋值：`onGone` 要引用 entry 自身（自摘）。
  OverlayEntry? entry;
  entry = OverlayEntry(
    builder: (BuildContext context) => _UndoToast(
      message: message,
      actionLabel: actionLabel,
      duration: duration,
      onUndo: onUndo,
      // 自己摘掉自己：overlay 只是容器，不负责生命周期。
      onGone: () {
        if (identical(_currentEntry, entry)) _currentEntry = null;
        entry?.remove();
      },
    ),
  );
  _currentEntry = entry;
  overlay.insert(entry);
}

/// 主动收起当前通知（没有则什么都不做）。
void dismissUndoToast() {
  final OverlayEntry? entry = _currentEntry;
  _currentEntry = null;
  entry?.remove();
}

class _UndoToast extends StatefulWidget {
  const _UndoToast({
    required this.message,
    required this.actionLabel,
    required this.duration,
    required this.onUndo,
    required this.onGone,
  });

  final String message;
  final String actionLabel;
  final Duration duration;
  final VoidCallback onUndo;
  final VoidCallback onGone;

  @override
  State<_UndoToast> createState() => _UndoToastState();
}

class _UndoToastState extends State<_UndoToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Tokens.durationNormal,
  );
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _controller.forward();
    _scheduleDismiss(widget.duration);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _scheduleDismiss(Duration duration) {
    _timer?.cancel();
    _timer = Timer(duration, _dismiss);
  }

  /// 淡出后摘除（动画期间先撤掉定时器，避免重复触发）。
  Future<void> _dismiss() async {
    _timer?.cancel();
    _timer = null;
    if (!mounted) return;
    await _controller.reverse();
    if (!mounted) return;
    widget.onGone();
  }

  void _undo() {
    widget.onUndo();
    unawaited(_dismiss());
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // M3 的反色表面：深浅两套主题下都与背景区分明确。
    final Color background = scheme.inverseSurface;
    final Color foreground = scheme.onInverseSurface;
    final Color accent = scheme.inversePrimary;

    return Positioned(
      key: const ValueKey<String>('undo-toast'),
      // **左下角**：只占内容宽度，不横跨窗口。
      left: Tokens.spaceLg,
      bottom: Tokens.spaceLg,
      child: FadeTransition(
        opacity: _controller,
        child: SlideTransition(
          // 上浮入场（8px，够表态但不夸张）。
          position: Tween<Offset>(
            begin: const Offset(0, 0.25),
            end: Offset.zero,
          ).animate(
            CurvedAnimation(
              parent: _controller,
              curve: Curves.easeOutCubic,
            ),
          ),
          child: Material(
            color: background,
            elevation: 6,
            borderRadius: BorderRadius.circular(Tokens.radiusMd),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Tokens.spaceMd,
                  Tokens.spaceSm,
                  Tokens.spaceXs,
                  Tokens.spaceSm,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        widget.message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(color: foreground),
                      ),
                    ),
                    const SizedBox(width: Tokens.spaceSm),
                    TextButton(
                      onPressed: _undo,
                      style: TextButton.styleFrom(
                        foregroundColor: accent,
                        minimumSize: const Size(0, Tokens.formatButtonHeight),
                        padding: const EdgeInsets.symmetric(
                          horizontal: Tokens.spaceSm,
                        ),
                      ),
                      child: Text(widget.actionLabel),
                    ),
                    IconButton(
                      onPressed: _dismiss,
                      tooltip: '关闭',
                      visualDensity: VisualDensity.compact,
                      iconSize: Tokens.iconMd,
                      color: foreground,
                      icon: const tabler.X(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
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
