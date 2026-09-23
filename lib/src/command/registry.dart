import 'package:flutter/services.dart';

import 'command.dart';

/// 命令注册表：**一处定义，四处消费**（快捷键 / 命令面板 / 右键菜单 / 工具条）。
///
/// ## 为什么把"冲突诊断"做进产品代码而不是只留在测试里
/// 快捷键冲突是**静默**的：两条命令同键位时，谁生效取决于遍历顺序，用户只会
/// 觉得"这个键时灵时不灵"。所以 [conflicts] 既是元测试的断言对象，也是应用
/// 启动时的 debug 断言（见 `app/providers.dart` 的装配）——**测试与运行期同
/// 一份判据**，不会漂移。
class CommandRegistry {
  CommandRegistry(List<Command> commands)
    : _commands = List<Command>.unmodifiable(commands) {
    assert(() {
      final List<String> problems = conflicts(_commands);
      if (problems.isNotEmpty) {
        throw StateError('命令注册表自检失败：\n${problems.join('\n')}');
      }
      return true;
    }());
  }

  final List<Command> _commands;

  List<Command> get all => _commands;

  Command? byId(String id) {
    for (final Command c in _commands) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// 面板用：按分组切好（空分组不出现）。
  Map<CommandGroup, List<Command>> grouped() {
    final Map<CommandGroup, List<Command>> out =
        <CommandGroup, List<Command>>{};
    for (final CommandGroup g in CommandGroup.values) {
      final List<Command> inGroup = <Command>[
        for (final Command c in _commands)
          if (c.group == g) c,
      ];
      if (inGroup.isNotEmpty) out[g] = inGroup;
    }
    return out;
  }

  /// 快捷键分发：在 [activeScopes]（由当前焦点/模式决定）下解析按键。
  ///
  /// **作用域优先级 = [CommandScope] 的声明顺序**（overlay 最高）。同一键位在
  /// 多个作用域都有绑定时，只有**最深且活跃**的那个生效，不再冒泡——这是
  /// "同键不同义"能被允许的前提（例：编辑器 `Ctrl+B` 加粗、列表上折叠侧栏）。
  ///
  /// 同作用域内的多条候选按注册顺序取第一条；[conflicts] 已保证同作用域同键位
  /// 不会出现两条，所以这里的顺序**不会**影响结果（不是"碰巧对"）。
  Command? resolve(KeyEvent event, {required Set<CommandScope> activeScopes}) {
    for (final CommandScope scope in CommandScope.values) {
      if (!activeScopes.contains(scope)) continue;
      for (final Command c in _commands) {
        if (c.scope != scope) continue;
        for (final KeyBinding b in c.keys) {
          if (b.matches(event)) return c;
        }
      }
    }
    return null;
  }

  /// 自检：id 重复、**同作用域**内键位重复。
  ///
  /// 跨作用域同键位**不报**——那是有意为之（见 [resolve] 的说明）。
  static List<String> conflicts(List<Command> commands) {
    final List<String> out = <String>[];

    final Set<String> ids = <String>{};
    for (final Command c in commands) {
      if (!ids.add(c.id)) out.add('id 重复：${c.id}');
    }

    // 键位判重按 (作用域, 键位文案) 分组：`label` 已经是"修饰键 + 键"的规范化
    // 写法，两条命令的 label 相同即为真冲突。
    final Map<String, List<String>> bySlot = <String, List<String>>{};
    for (final Command c in commands) {
      for (final KeyBinding b in c.keys) {
        bySlot
            .putIfAbsent('${c.scope.name}/${b.label}', () => <String>[])
            .add(c.id);
      }
    }
    for (final MapEntry<String, List<String>> e in bySlot.entries) {
      if (e.value.length > 1) {
        out.add('键位冲突：${e.key} 被 ${e.value.join(' / ')} 同时占用');
      }
    }
    return out;
  }
}
