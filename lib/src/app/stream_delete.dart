import 'dart:async';

import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, KeyEvent, LogicalKeyboardKey;
import 'package:material_ui/material_ui.dart';

/// 灵感删除确认：**软删进回收站**（可恢复 / 可彻底删除），不是立即销毁。
///
/// 返回 true = 用户确认。灵感列表、归档行、台账卡共用这一份，保证文案与
/// 按钮语义只有一处（2026-10-18 用户定：删除一律先进回收站）。
Future<bool> confirmTrashStream(BuildContext context, int count) {
  return showStreamConfirm(
    context: context,
    title: '移入回收站',
    message: '将 $count 条灵感移入回收站？可在回收站恢复或彻底删除。',
    confirmLabel: '移入回收站',
  );
}

/// 通用确认浮层：**手动插入 OverlayEntry**，不用 `showDialog`。
///
/// 为什么：灵感台账 / 回收站是手动插进**根 Overlay** 的浮层；`Navigator` 的
/// dialog route 会排在它**下面**（手动 entry 在 Navigator 管理范围之外），
/// 结果确认框被浮层盖住、按钮点不到。这里同样插到 Overlay 顶层，保证确认框
/// 一定在浮层之上；Esc / 点遮罩 = 取消。
Future<bool> showStreamConfirm({
  required BuildContext context,
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) {
  final OverlayState overlay = Overlay.of(context, rootOverlay: true);
  final Completer<bool> result = Completer<bool>();
  OverlayEntry? entry;
  late final bool Function(KeyEvent) esc;

  void finish(bool value) {
    if (result.isCompleted) return;
    result.complete(value);
    if (entry != null && entry!.mounted) entry!.remove();
    entry = null;
    HardwareKeyboard.instance.removeHandler(esc);
  }

  esc = (KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      finish(false);
    }
    return false;
  };
  HardwareKeyboard.instance.addHandler(esc);

  entry = OverlayEntry(
    builder: (BuildContext ctx) {
      final ThemeData theme = Theme.of(ctx);
      return Stack(
        children: <Widget>[
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => finish(false),
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.4),
              ),
            ),
          ),
          Center(
            child: AlertDialog(
              title: Text(title),
              content: Text(message),
              actions: <Widget>[
                TextButton(
                  onPressed: () => finish(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => finish(true),
                  style: destructive
                      ? FilledButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                        )
                      : null,
                  child: Text(confirmLabel),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
  overlay.insert(entry!);
  return result.future;
}
