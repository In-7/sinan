import 'package:flutter/foundation.dart';

/// 把内部命令串（`Ctrl+Shift+B`）渲染成**当前平台习惯的写法**。
///
/// 菜单项右侧标注快捷键是桌面软件的通用惯例（VS Code / Office / Chrome 均是），
/// Material 的对应物是 `MenuItemButton.shortcut`。Windows 写 `Ctrl`，
/// macOS 写 `⌘`（Shift 两平台一致）。
String shortcutLabel(String shortcut) {
  final bool apple = defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS;
  if (!apple) return shortcut;
  return shortcut
      .replaceAll('Ctrl', '⌘')
      .replaceAll('Shift', '⇧')
      .replaceAll('Alt', '⌥');
}
