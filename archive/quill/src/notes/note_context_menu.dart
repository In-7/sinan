import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

/// 嵌入元素（图片等）已自行处理本次右键：嵌入渲染在编辑器行内，
/// 其右键事件会沿 hit test 路径（leaf → root）先经过嵌入菜单、
/// 再到达包裹编辑器的正文右键监听器——不加抑制会双弹菜单。
///
/// 生命周期：编辑器右键**按下**时清零 → 嵌入菜单处理 up 事件时
/// 置位 → 正文监听器收到同一 up 时检测并跳过。
bool noteContextMenuEmbedHandled = false;

/// 统一的右键上下文菜单条目。
class NoteContextMenuEntry {
  const NoteContextMenuEntry({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.destructive = false,
    this.enabled = true,
    this.separatorBefore = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  /// 破坏性操作（删除等）：图标与文字用主题 error 色，
  /// 且固定排在菜单最后——成熟应用的统一惯例。
  final bool destructive;

  /// false 时条目灰显不可点（如无可撤销内容时的「撤销」）。
  final bool enabled;

  /// 条目上方渲染一条分隔线（功能分组用）。
  final bool separatorBefore;
}

/// 在 [position]（屏幕坐标）右下弹出**非模态**上下文菜单。
///
/// 与 showMenu（PopupRoute）的关键差异——本实现是 Overlay 浮层，
/// **不抢焦点、不吸收事件**：
/// - 编辑器选区高亮在菜单打开期间保持（焦点不移走）；
/// - 标题栏拖动、编辑器外的任何操作照常进行（不吞事件）；
/// - 点击菜单外（TapRegion）或 Esc 关闭；选择条目执行动作后关闭。
///
/// Future 以 **bool 完成且会等到菜单关闭**：true = 用户点了某个条目，
/// false = 点外部/Esc 直接关闭。调用方据此区分「动作已自行处理选区/
/// 焦点」（如全选须保持高亮）与「直接关闭需收尾」（如折叠选区）——
/// 若不区分，点条目后 close 先完成 Future，onPressed 设置的新选区
/// 会被调用方的关闭收尾立即撤销（全选点击无效的根因）。
Future<bool> showNoteContextMenu(
  BuildContext context, {
  required Offset position,
  required List<NoteContextMenuEntry> entries,
}) async {
  if (entries.isEmpty) return false;
  final OverlayState overlay = Overlay.of(context, rootOverlay: true);
  final ColorScheme scheme = Theme.of(context).colorScheme;
  final Size screen = MediaQuery.sizeOf(context);

  // 菜单尺寸估算（用于翻转与屏幕夹紧）：行高 40 + 上下边距。
  const double menuWidth = 190;
  final double menuHeight = entries.length * 40 + 8;

  double left = position.dx;
  double top = position.dy;
  if (left + menuWidth > screen.width - 8) {
    left = screen.width - menuWidth - 8;
  }
  if (top + menuHeight > screen.height - 8) {
    top = screen.height - menuHeight - 8;
  }

  final Completer<bool> closed = Completer<bool>();
  OverlayEntry? entry;
  // late：close 与 esc 处理器相互引用，用 late final 变量打破
  // 局部函数的「先声明后使用」限制（调用时均已初始化）。
  late final bool Function(KeyEvent event) handleEscKey;

  void close(bool itemTapped) {
    if (!closed.isCompleted) {
      closed.complete(itemTapped);
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
      close(false);
    }
    return false;
  };

  HardwareKeyboard.instance.addHandler(handleEscKey);

  entry = OverlayEntry(
    builder: (BuildContext overlayContext) => Positioned(
      left: left,
      top: top,
      child: TapRegion(
        // 点击菜单外：关闭菜单，**不消费事件**——下层（标题栏拖动/
        // 编辑器光标定位）照常响应，编辑页不干扰软件整体操作。
        onTapOutside: (_) => close(false),
        // TextFieldTapRegion：把菜单注册进 Flutter 的「编辑控件」
        // TapRegion 组（全局共享 group id，与编辑器同组）。缺了它，
        // 点菜单项对编辑器是外部点击 → 桌面默认行为 unfocus 编辑器
        // （raw_editor_state 的 _defaultOnTapOutside）→ 粘贴后无光标、
        // Ctrl+Z 失灵、还得再点正文恢复焦点。quill 官方
        // defaultContextMenuBuilder 包 TextFieldTapRegion 正是此用途。
        child: TextFieldTapRegion(
          child: Material(
            elevation: 8,
            color: scheme.surface,
            borderRadius: BorderRadius.circular(Tokens.radiusSm),
            child: IntrinsicWidth(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final NoteContextMenuEntry item in entries) ...<Widget>[
                    if (item.separatorBefore)
                      Divider(
                        height: 1,
                        thickness: 1,
                        color: scheme.outlineVariant,
                      ),
                    _MenuRow(
                      entry: item,
                      onTap: () {
                        // 先传「点了条目」再执行动作：调用方的 Future
                        // 收尾据此跳过选区收尾，onPressed 设置的新状态
                        // （如全选高亮）不会被撤销。
                        close(true);
                        item.onPressed();
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry!);
  return closed.future;
}

/// 菜单项行：图标 + 文字（M3 规范排法），InkWell 水波。
class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.entry, required this.onTap});

  final NoteContextMenuEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color fg = entry.destructive ? scheme.error : scheme.onSurface;
    return InkWell(
      onTap: entry.enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Tokens.spaceMd,
          vertical: 10,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              entry.icon,
              size: Tokens.iconSm,
              color: entry.enabled
                  ? (entry.destructive ? scheme.error : scheme.onSurfaceVariant)
                  : scheme.onSurface.withValues(alpha: 0.3),
            ),
            const SizedBox(width: Tokens.spaceMd),
            Text(
              entry.label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: entry.enabled
                    ? fg
                    : scheme.onSurface.withValues(alpha: 0.3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
