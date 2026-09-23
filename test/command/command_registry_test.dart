import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/command/command.dart';
import 'package:sinan/src/command/registry.dart';

/// 命令层**元测试**（`docs/ui_rewrite_plan.md` §11）：id 唯一、键位无冲突、
/// 解析遵守作用域优先级、`enabled` 判据被尊重。
///
/// 这些是"重写 UI 时的护栏"里最便宜也最耐用的那层——命令层不依赖 widget 树，
/// 所以它们都是纯函数测试，毫秒级。
Command _cmd(
  String id, {
  CommandScope scope = CommandScope.note,
  CommandGroup group = CommandGroup.edit,
  List<KeyBinding> keys = const <KeyBinding>[],
  bool Function(CommandContext)? enabled,
}) => Command(
  id: id,
  title: id,
  group: group,
  scope: scope,
  keys: keys,
  enabled: enabled ?? (CommandContext _) => true,
  run: (CommandContext _) async {},
);

KeyBinding _ctrl(
  LogicalKeyboardKey key, {
  bool shift = false,
  bool alt = false,
}) => KeyBinding(key: key, control: true, shift: shift, alt: alt);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('KeyBinding', () {
    test('label：修饰键顺序固定，符号键写字面量', () {
      expect(_ctrl(LogicalKeyboardKey.keyP, shift: true).label, 'Ctrl+Shift+P');
      expect(_ctrl(LogicalKeyboardKey.comma).label, 'Ctrl+,');
      expect(_ctrl(LogicalKeyboardKey.backslash).label, r'Ctrl+\');
    });

    test('matches：修饰键**精确**匹配（Ctrl+B 不会被 Ctrl+Shift+B 抢走）', () async {
      final KeyBinding ctrlB = _ctrl(LogicalKeyboardKey.keyB);
      const KeyDownEvent event = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyB,
        logicalKey: LogicalKeyboardKey.keyB,
        timeStamp: Duration.zero,
      );

      await simulateKeyDownEvent(LogicalKeyboardKey.controlLeft);
      expect(ctrlB.matches(event), isTrue);

      // 多按一个 Shift ⇒ 不再命中（内核里 Ctrl+B 是加粗、Ctrl+Shift+B 是正文，
      // 两者必须互不干扰）。
      await simulateKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      expect(ctrlB.matches(event), isFalse);

      await simulateKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await simulateKeyUpEvent(LogicalKeyboardKey.controlLeft);
      // 松开修饰键后也不命中。
      expect(ctrlB.matches(event), isFalse);
    });
  });

  group('冲突诊断', () {
    test('id 重复被发现', () {
      final List<String> problems = CommandRegistry.conflicts(<Command>[
        _cmd('note.new'),
        _cmd('note.new', group: CommandGroup.file),
      ]);
      expect(problems, hasLength(1));
      expect(problems.single, contains('id 重复：note.new'));
    });

    test('同作用域同键位被发现；跨作用域同键位**不算冲突**', () {
      final List<String> problems = CommandRegistry.conflicts(<Command>[
        _cmd(
          'a',
          scope: CommandScope.editor,
          keys: <KeyBinding>[_ctrl(LogicalKeyboardKey.keyB)],
        ),
        _cmd(
          'b',
          scope: CommandScope.editor,
          keys: <KeyBinding>[_ctrl(LogicalKeyboardKey.keyB)],
        ),
        // 同键位、不同作用域：有意为之（见 registry 的 resolve 说明）。
        _cmd('c', keys: <KeyBinding>[_ctrl(LogicalKeyboardKey.keyB)]),
      ]);
      expect(problems, hasLength(1));
      expect(problems.single, contains('键位冲突'));
      expect(problems.single, contains('a / b'));
    });

    test('注册表构造时会自检（debug 下 id 重复直接抛）', () {
      expect(
        () => CommandRegistry(<Command>[_cmd('x'), _cmd('x')]),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('快捷键解析', () {
    test('作用域优先级：overlay > editor > note > global', () async {
      final CommandRegistry registry = CommandRegistry(<Command>[
        _cmd(
          'g',
          scope: CommandScope.global,
          keys: <KeyBinding>[_ctrl(LogicalKeyboardKey.keyK)],
        ),
        _cmd(
          'e',
          scope: CommandScope.editor,
          keys: <KeyBinding>[_ctrl(LogicalKeyboardKey.keyK)],
        ),
        _cmd(
          'o',
          scope: CommandScope.overlay,
          keys: <KeyBinding>[_ctrl(LogicalKeyboardKey.keyK)],
        ),
      ]);
      const KeyDownEvent event = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyK,
        logicalKey: LogicalKeyboardKey.keyK,
        timeStamp: Duration.zero,
      );
      await simulateKeyDownEvent(LogicalKeyboardKey.controlLeft);

      expect(
        registry
            .resolve(
              event,
              activeScopes: const <CommandScope>{
                CommandScope.overlay,
                CommandScope.editor,
                CommandScope.global,
              },
            )
            ?.id,
        'o',
      );
      expect(
        registry
            .resolve(
              event,
              activeScopes: const <CommandScope>{
                CommandScope.editor,
                CommandScope.global,
              },
            )
            ?.id,
        'e',
        reason: 'overlay 不活跃时应落到 editor，而不是 global',
      );
      expect(
        registry
            .resolve(
              event,
              activeScopes: const <CommandScope>{CommandScope.global},
            )
            ?.id,
        'g',
      );
      await simulateKeyUpEvent(LogicalKeyboardKey.controlLeft);
    });

    test('未注册的键位返回 null（不吞按键）', () async {
      final CommandRegistry registry = CommandRegistry(<Command>[
        _cmd('p', keys: <KeyBinding>[_ctrl(LogicalKeyboardKey.keyP)]),
      ]);
      const KeyDownEvent event = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyZ,
        logicalKey: LogicalKeyboardKey.keyZ,
        timeStamp: Duration.zero,
      );
      await simulateKeyDownEvent(LogicalKeyboardKey.controlLeft);
      expect(
        registry.resolve(
          event,
          activeScopes: const <CommandScope>{CommandScope.note},
        ),
        isNull,
      );
      await simulateKeyUpEvent(LogicalKeyboardKey.controlLeft);
    });
  });

  group('enabled 判据被尊重', () {
    test('置灰而非消失：命令仍在册，只是 isEnabled 为 false', () {
      final CommandRegistry registry = CommandRegistry(<Command>[
        _cmd('editor.copy', enabled: (CommandContext c) => c.hasSelection),
      ]);
      expect(registry.byId('editor.copy'), isNotNull, reason: '命令不许消失');
      expect(
        registry.byId('editor.copy')!.isEnabled(const CommandContext()),
        isFalse,
      );
      expect(
        registry
            .byId('editor.copy')!
            .isEnabled(const CommandContext(hasSelection: true)),
        isTrue,
      );
    });

    test('空上下文下每条命令的 enabled 都不抛（元测试的固定项）', () {
      final CommandRegistry registry = CommandRegistry(<Command>[
        _cmd('a', enabled: (CommandContext c) => c.hasNote),
        _cmd(
          'b',
          enabled: (CommandContext c) => c.isCanvas && c.hasCanvasSelection,
        ),
        _cmd('c', enabled: (CommandContext c) => c.hasSelection),
      ]);
      for (final Command c in registry.all) {
        expect(() => c.isEnabled(const CommandContext()), returnsNormally);
      }
    });
  });

  group('查找与分组', () {
    test('grouped：空分组不出现，分组内容按注册顺序', () {
      final CommandRegistry registry = CommandRegistry(<Command>[
        _cmd('n1', group: CommandGroup.file),
        _cmd('e1'),
        _cmd('n2', group: CommandGroup.file),
      ]);
      final Map<CommandGroup, List<Command>> grouped = registry.grouped();
      expect(grouped.keys, <CommandGroup>[
        CommandGroup.file,
        CommandGroup.edit,
      ]);
      expect(
        <String>[for (final Command c in grouped[CommandGroup.file]!) c.id],
        <String>['n1', 'n2'],
      );
    });
  });
}
