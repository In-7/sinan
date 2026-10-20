import 'dart:async';

import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'providers.dart';
import 'settings_panel.dart' show appNavigatorKey;
import '../theme/tokens.dart';

/// **全局灵感小窗**（2026-10-17，灵感/灵感 P1）。
///
/// 灵感的价值全在"不打断"：正在写笔记 / 画图时想起一句话，按一下快捷键、
/// 打完回车、窗就没了，人还留在原地。所以这里刻意只有三件事：
/// 一个输入框、Enter 存入、Esc 关闭。
///
/// - **不跳页**：存完原地关闭，不切到灵感视图（要去看再自己点）；
/// - **不写笔记**：只落 `stream_items`（独立表，与笔记/画布无外键）；
/// - **不弹确认**：存入即关，底部一行小字说明键位。
///
/// 入口是命令层 `stream.capture`（`Ctrl+Shift+M`，M = memo），
/// 与主页灵感输入条是同一个 `StreamNotifier.add`。
Future<void> showStreamCapture() async {
  final NavigatorState? navigator = appNavigatorKey.currentState;
  if (navigator == null) return;
  await showDialog<void>(
    context: navigator.context,
    builder: (BuildContext _) => const _StreamCaptureDialog(),
  );
}

class _StreamCaptureDialog extends ConsumerStatefulWidget {
  const _StreamCaptureDialog();

  @override
  ConsumerState<_StreamCaptureDialog> createState() =>
      _StreamCaptureDialogState();
}

class _StreamCaptureDialogState extends ConsumerState<_StreamCaptureDialog> {
  final TextEditingController _controller = TextEditingController();
  late final FocusNode _focus = FocusNode(onKeyEvent: _onKey);
  bool _canSend = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged() {
    final bool can = _controller.text.trim().isNotEmpty;
    if (can != _canSend) setState(() => _canSend = can);
  }

  /// Enter 存入 / Shift+Enter 换行。挂在输入框自己的焦点节点上，返回
  /// `handled` 后换行符不会插进文本（与灵感输入条同一口径）。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      unawaited(_submit());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _submit() async {
    final String text = _controller.text.trim();
    if (text.isEmpty) return;
    // 先拿到 notifier 再动窗口：`pop()` 后本 State 会随路由卸载，之后再 `ref.read`
    // 属于"已销毁的 State 上取 provider"。
    final notifier = ref.read(streamProvider.notifier);
    // **写成功才关窗**：失败时留在这里，文本还在，可以重按 Enter。
    try {
      await notifier.add(text);
    } on Object {
      if (!mounted) return;
      setState(() {}); // 让按钮状态重新评估
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('没记下来，请重试')));
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return AlertDialog(
      title: const Text('灵感'),
      content: SizedBox(
        // 与页面内的捕获区同档：**先给出一块能写的区域**，而不是一条窄输入框
        // （2026-10-17 用户实报"输入框太小、没有重心"）。
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              controller: _controller,
              focusNode: _focus,
              autofocus: true,
              minLines: 4,
              maxLines: 12,
              style: theme.textTheme.bodyLarge?.copyWith(height: 1.7),
              cursorColor: scheme.primary,
              decoration: InputDecoration(
                hintText: '记下此刻的想法…',
                hintStyle: theme.textTheme.bodyLarge?.copyWith(height: 1.7),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: Tokens.spaceSm),
            Text(
              'Enter 记下 · Shift+Enter 换行 · Esc 关闭',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _canSend ? _submit : null,
          child: const Text('记下'),
        ),
      ],
    );
  }
}
