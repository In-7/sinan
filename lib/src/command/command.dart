import 'package:flutter/services.dart';

/// 命令的**作用域**——决定同键位冲突时谁优先。
///
/// ## 解析优先级 = 声明顺序（左边最高）
/// ```
/// overlay > canvas / editor > note > global
/// ```
/// 更深作用域有绑定 ⇒ 由它消费，不再冒泡。这是"同键不同义"能被允许的前提：
/// 例如编辑器内 `Ctrl+B` 是加粗，列表上可以留给别的意思（本方案最终改用
/// `Ctrl+\` 折叠侧栏，见 `docs/ui_rewrite_plan.md` §3.4）。
///
/// ⚠️ 顺序是**语义**，不是排版：加新作用域要么插在正确的位置，要么想清楚
/// 它与既有作用域的重叠关系。
enum CommandScope { overlay, canvas, editor, note, global }

/// 命令的面板分组（菜单/面板里的分节标题）。
enum CommandGroup { file, edit, navigate, view, insert, canvas, ai, app }

/// 一个键位绑定。**平台无关**：⌘/Ctrl 的符号化与替换放在平台适配层
/// （`docs/ui_rewrite_plan.md` §8），命令定义里只写"逻辑键 + 修饰键组合"。
class KeyBinding {
  const KeyBinding({
    required this.key,
    this.control = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
  });

  final LogicalKeyboardKey key;
  final bool control;
  final bool shift;
  final bool alt;
  final bool meta;

  /// 事件是否命中本绑定。
  ///
  /// **纯函数**——这正是快捷键这一层唯一值得单测的逻辑：不依赖 widget 树，
  /// 也就不需要 pump 一个界面才能验证"Ctrl+Shift+P 到底匹不匹配"。
  ///
  /// 语义：修饰键**精确匹配**（多按了 Shift 就不算命中），方向键/功能键等
  /// 不带修饰也能命中。这样"Ctrl+B"不会被"Ctrl+Shift+B"抢走——而
  /// appflowy 内核恰好两者都在用（加粗 / 正文样式），精确匹配是必需的。
  bool matches(KeyEvent event) {
    if (event.logicalKey != key) return false;
    final Set<LogicalKeyboardKey> pressed =
        HardwareKeyboard.instance.logicalKeysPressed;
    // 用**按下集合**而不是事件自带的修饰位：单测里可以构造事件，但真实
    // 场景下修饰键状态只有 HardwareKeyboard 知道（事件位在部分平台上不全）。
    return _isPressed(
              pressed,
              LogicalKeyboardKey.controlLeft,
              LogicalKeyboardKey.controlRight,
            ) ==
            control &&
        _isPressed(
              pressed,
              LogicalKeyboardKey.shiftLeft,
              LogicalKeyboardKey.shiftRight,
            ) ==
            shift &&
        _isPressed(
              pressed,
              LogicalKeyboardKey.altLeft,
              LogicalKeyboardKey.altRight,
            ) ==
            alt &&
        _isPressed(
              pressed,
              LogicalKeyboardKey.metaLeft,
              LogicalKeyboardKey.metaRight,
            ) ==
            meta;
  }

  static bool _isPressed(
    Set<LogicalKeyboardKey> pressed,
    LogicalKeyboardKey left,
    LogicalKeyboardKey right,
  ) => pressed.contains(left) || pressed.contains(right);

  /// 给面板/菜单显示的键位文案（如 `Ctrl+Shift+P`）。
  ///
  /// ⚠️ 这是 **Windows/macOS 共用一个写法**的简化版（Ctrl 字样）：真正的
  /// ⌘ 替换在阶段 3 的平台适配层做，本层不猜平台。
  String get label {
    final List<String> parts = <String>[
      if (control) 'Ctrl',
      if (shift) 'Shift',
      if (alt) 'Alt',
      if (meta) 'Meta',
      _keyLabel(key),
    ];
    return parts.join('+');
  }

  static String _keyLabel(LogicalKeyboardKey key) {
    // 少数键的显示名与 `keyLabel` 不同（逗号、反引号这类符号直接给字面量）。
    if (key == LogicalKeyboardKey.comma) return ',';
    if (key == LogicalKeyboardKey.backquote) return '`';
    if (key == LogicalKeyboardKey.backslash) return r'\';
    return key.keyLabel.isEmpty ? key.debugName ?? '?' : key.keyLabel;
  }

  @override
  String toString() => label;
}

/// 命令执行时可用的**上下文**：一切"能不能点"的依据都从这里取。
///
/// 刻意做成不可变值对象（而不是直接把 controllers 塞进命令）：命令因此
/// 不依赖任何 widget / notifier 类型，能纯单测（§11 的元测试就靠这一点）。
class CommandContext {
  const CommandContext({
    this.noteId,
    this.hasSelection = false,
    this.isCanvas = false,
    this.hasCanvasSelection = false,
    this.blockId,
  });

  /// 当前笔记；null = 列表/空态。
  final String? noteId;

  /// 编辑器里有选区（非折叠光标）。
  final bool hasSelection;

  /// 当前笔记是画布笔记。
  final bool isCanvas;

  /// 画布上有选中对象。
  final bool hasCanvasSelection;

  /// 光标所在块（块级命令用）。
  final String? blockId;

  bool get hasNote => noteId != null;
}

/// 一条命令。
///
/// ## id 是**稳定的对外契约**
/// 快捷键映射、面板里的 `ValueKey`、测试断言、"重写 UI 后肌肉记忆不丢"全靠它。
/// 换个外壳也**不要**改 id——改了等于把用户的快捷键与我的测试一起作废。
///
/// ## `enabled` 而不是 `hidden`（HIG 最硬的一条）
/// 不可用时命令**仍在面板里**，灰显并说明原因（"需要选中文本"）。命令永不消失
/// 是可发现性的来源。
///
/// **唯一例外**：依赖"未配置的外部服务"的命令（如 AI）不进注册表——
/// 那不是"暂不可用"，而是"点了也没有可执行语义"。此例外必须守住，
/// 否则会退化成"随便隐藏"。
class Command {
  const Command({
    required this.id,
    required this.title,
    required this.group,
    required this.run,
    this.hint,
    this.keys = const <KeyBinding>[],
    this.scope = CommandScope.note,
    this.enabled = _alwaysEnabled,
    this.dangerous = false,
    this.longRunning = false,
  });

  final String id;
  final String title;

  /// 面板里的补充说明（例如"需要选中文本"这类前置条件的正向描述）。
  final String? hint;

  final CommandGroup group;

  /// 可多套键位（如 `Ctrl+Y` 与 `Ctrl+Shift+Z` 都是重做——平台习惯差异）。
  final List<KeyBinding> keys;

  final CommandScope scope;

  /// 不可用时**置灰**（仍显示）。默认恒可用。
  final bool Function(CommandContext context) enabled;

  /// 危险动作（删除/清空/重置）⇒ 走 `error` 语义，不设为默认按钮。
  final bool dangerous;

  /// 长任务（索引/导入/导出/AI）⇒ 统一反馈通道：进度 + 可取消，见
  /// `docs/ui_rewrite_plan.md` §3.6。**禁止各自弹一套 UI**。
  final bool longRunning;

  final Future<void> Function(CommandContext context) run;

  static bool _alwaysEnabled(CommandContext context) => true;

  bool isEnabled(CommandContext context) => enabled(context);
}
