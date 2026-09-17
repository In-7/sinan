import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey, PhysicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import 'package:sinan/src/editor/blocks/toggle_block_component.dart';
import 'package:sinan/src/editor/toolbar/fixed_toolbar.dart';
import 'package:sinan/src/editor/toolbar/link_toolbar_item.dart';

/// 快捷键键名回归：**所有注册进编辑器的 [CommandShortcutEvent]**，其每个
/// keybinding 的键名都必须能在官方 `key_mapping.dart` 的 `keyToCodeMapping`
/// 里查到键码。
///
/// ## 为什么要有这个闸门
/// 官方 `Keybinding.keyCode` 原版是 `keyToCodeMapping[keyLabel]!`——键名写错
/// （例如裸数字 `'8'`，表里只有 `'digit 8'`）就返回 null 并在**按键消息处理器**
/// 里抛异常，把整条键盘分发链打断（实测症状：按住 Ctrl 再按 Shift 的瞬间，
/// 编辑器抛 "Null check operator used on a null value"）。
///
/// 双保险：
/// 1. vendored `keybinding.dart` 补丁——匹配走可空的 `keyCodeOrNull`，未映射
///    键名静默跳过（本文件第三条用例锁住这个行为）；
/// 2. 本文件第一条用例——注册表里**不许出现**未映射键名，写错了在这里红。
void main() {
  // `containsKeyEvent` 读 `HardwareKeyboard.instance`，需要先初始化 binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 生产注册表的全部命令（与 `note_editor_view_appflowy.dart` 的组装一致；
  /// `findAndReplaceCommands` 的 ctrl+f / ctrl+h 已含在官方标准表之外单独验证，
  /// 这里以导出的静态命令为准）。
  List<CommandShortcutEvent> allCommands() => <CommandShortcutEvent>[
    ...standardCommandShortcutEvents,
    sinanPasteCommand,
    toggleToggleListCommand,
    sinanBulletedListCommand,
    sinanNumberedListCommand,
    sinanQuoteCommand,
    ...sinanAlignCommands,
    sinanCodeBlockCommand,
    sinanTocCommand(onToggle: () {}),
  ];

  test('注册表里所有键名都在 keyToCodeMapping 里', () {
    final List<String> unmapped = <String>[
      for (final CommandShortcutEvent event in allCommands())
        for (final Keybinding kb in event.keybindings)
          if (kb.keyCodeOrNull == null)
            '${event.key}: "${kb.keyLabel}"（command="${event.command}"）',
    ];
    expect(
      unmapped,
      isEmpty,
      reason: '以下 keybinding 的键名查不到键码，按下相应修饰键组合时'
          '（vendored 补丁前）会让键盘分发崩溃：\n${unmapped.join('\n')}',
    );
  });

  test('digit 7 / digit 8 解析出正确键码与修饰键', () {
    final Keybinding digit8 = Keybinding.parse('ctrl+shift+digit 8');
    expect(digit8.keyCode, 0x38);
    expect(digit8.isControlPressed, isTrue);
    expect(digit8.isShiftPressed, isTrue);

    final Keybinding digit7 = Keybinding.parse('ctrl+shift+digit 7');
    expect(digit7.keyCode, 0x37);
  });

  test('未映射键名：匹配时静默跳过而不是抛异常（vendored 补丁行为）', () {
    // ignore: prefer_const_constructors
    final KeyDownEvent event = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: LogicalKeyboardKey.keyA,
      character: 'a',
      timeStamp: Duration.zero,
    );
    // 测试环境 HardwareKeyboard 无修饰键按下 ⇒ 无修饰键的 keybinding 会走到键码比对。
    expect(<Keybinding>[Keybinding.parse('a')].containsKeyEvent(event), isTrue);
    // 未映射键名 ⇒ keyCodeOrNull 为 null ≠ keyId ⇒ false，且**不抛异常**。
    expect(
      <Keybinding>[Keybinding.parse('foo')].containsKeyEvent(event),
      isFalse,
    );
  });
}
