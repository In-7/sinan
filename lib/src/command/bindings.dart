import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'command.dart';
import 'commands.dart';

/// 全局快捷键分发器：把按键交给命令注册表（`docs/ui_rewrite_plan.md` §3.2 的①面）。
///
/// ## 为什么用 `HardwareKeyboard.addHandler`，而不是 `Shortcuts` / `Actions`
/// 计划里写的是"Shortcuts/Actions 按 scope 分层"，实现时按 SDK 源码改为**单一
/// 分发器 + [CommandRegistry.resolve]**。两条理由都是查证出来的（2026-09-21）：
///
/// 1. **分层要求"每个作用域边界是一个 widget 子树"**，而编辑器的边界在 vendored
///    appflowy 内部（它自带一套 `Shortcuts`）、画布用的是 `Focus.onKeyEvent`——
///    应用侧没有可插进去的层级。硬造一层等于把我们的快捷键语义绑到别人的树形上。
/// 2. **[CommandRegistry.resolve] 已经是同一套语义**（作用域按声明顺序、更深优先）
///    且是纯函数、已被单测钉住。同一语义不写两遍。
///
/// ## ⚠️ 必须知道的事实：本分发器**拦不下**按键
/// 查 SDK 源码（Flutter 3.47.4，`services/hardware_keyboard.dart`）：
/// ```dart
/// handled = _hardwareKeyboard.handleKeyEvent(event) || handled;            // 先跑所有 handler
/// handled = _dispatchKeyMessage(_keyEventsSinceLastMessage, rawEvent) || handled;  // 焦点树分发照常
/// ```
/// 且 `addHandler` 的文档明说返回值只影响"add-to-app 场景下是否传给 native"。
/// 也就是说 handler 是**旁观者**：它先看到按键，但不能阻止事件继续走进焦点树
/// （编辑器 / 画布仍在后面收到同一个键）。
///
/// 所以"不跟编辑器抢键"靠的是**键位占用图不重叠**（§3.4），不是靠消费事件。
/// 这条约定由元测试钉住（`test/command/command_meta_test.dart` 的键位占用断言）。
/// 将来若要加与编辑器**同键位**的命令，必须先解决"真消费"——改用焦点树祖先节点 +
/// `KeyEventResult.handled`，别只指望这里的返回值。
///
/// ## 返回值一律 false
/// 我们只执行自己的命令，不宣称"这个键被吃掉了"。返回 `true` 会阻止 add-to-app
/// 场景把它传给 native——对本应用无意义，却可能影响 IME 与系统级处理。
typedef CommandDispatcherHandle = void Function();

/// 安装分发器，返回**卸载函数**（热重载与测试都要能干净摘掉）。
///
/// 参数是 [WidgetRef]（不是 `Ref`）：装载点是应用外壳的 `State`，那里只有前者。
/// 两者在 Riverpod 里是**不同类型**，不能互相赋值——命令层因此提供两种入口：
/// 装配用的 `buildCommands(Ref)`（provider 内）与调用用的 [runCommandById]
/// / 本函数（widget 内）。
CommandDispatcherHandle installCommandDispatcher(WidgetRef ref) {
  bool onKey(KeyEvent event) {
    // 只认**按下**。`KeyRepeatEvent`（长按连发）与 `KeyUpEvent` 同样会让
    // `KeyBinding.matches` 命中——不排除的话，按一次 Ctrl+N 会新建两条笔记。
    if (event is! KeyDownEvent) return false;

    final Command? command = ref
        .read(commandRegistryProvider)
        .resolve(event, activeScopes: ref.read(activeCommandScopesProvider));
    if (command == null) return false;

    final CommandContext context = ref.read(commandContextProvider);
    // 置灰的命令，快捷键也不生效；但**不消费**按键（见类注释）。
    if (!command.isEnabled(context)) return false;

    unawaited(command.run(context));
    return false;
  }

  HardwareKeyboard.instance.addHandler(onKey);
  return () => HardwareKeyboard.instance.removeHandler(onKey);
}
