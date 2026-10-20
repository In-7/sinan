import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/command/command.dart';
import 'package:sinan/src/command/commands.dart';
import 'package:sinan/src/command/fuzzy.dart';
import 'package:sinan/src/command/registry.dart';

/// 命令层**元测试**：跑在**真注册表**上（`command_registry_test.dart` 用的是
/// 假命令，验的是机制；这里验的是我们实际注册进去的那批内容）。
///
/// 这些断言都属"错了不会崩、只会静默变坏"那一类，所以只能用测试兜：
/// 键位与编辑器撞车（表现为"某个键时灵时不灵"）、拼音表漏字（表现为"搜不到"）、
/// UI 按 id 取命令而 id 被改名（表现为"按钮点了没反应"）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late CommandRegistry registry;

  setUp(() {
    container = ProviderContainer();
    registry = container.read(commandRegistryProvider);
  });
  tearDown(() => container.dispose());

  test('真实注册表自身无冲突：id 唯一、同作用域键位不重复', () {
    expect(CommandRegistry.conflicts(registry.all), isEmpty);
  });

  test('键位**不占用编辑器的键**（§3.4 的占用图）', () {
    // ⚠️ 抄自 `docs/ui_rewrite_plan.md` §3.4。编辑器键位变动时要同步这张表——
    // 它变旧了不会报错，只会让这条断言变松（那是最坏的一种测试失效）。
    const Set<String> occupied = <String>{
      // 编辑基础
      'Ctrl+Z', 'Ctrl+Y', 'Ctrl+X', 'Ctrl+C', 'Ctrl+V', 'Ctrl+Shift+V',
      'Ctrl+A', 'Ctrl+Backspace', 'Ctrl+Delete',
      // 行内格式
      'Ctrl+B', 'Ctrl+I', 'Ctrl+U', 'Ctrl+Shift+S', 'Ctrl+E',
      'Alt+Enter',
      // ⚠️ Ctrl+K（原官方"插入链接"）2026-09-30 已从编辑器命令表摘除、让位给
      // 全局搜索 search.open（⌘K 范式）。链接改走工具栏按钮，不再是编辑器占用键。
      // 块样式
      'Ctrl+Shift+B', 'Ctrl+Shift+T', 'Ctrl+Shift+G', 'Ctrl+Shift+J',
      'Ctrl+Enter', 'Ctrl+Shift+H',
      // 本应用已加
      'Ctrl+F', 'Ctrl+H', 'Ctrl+Shift+7', 'Ctrl+Shift+8', 'Ctrl+Shift+Q',
      'Ctrl+Shift+L', 'Ctrl+Shift+E', 'Ctrl+Shift+R', r'Ctrl+Shift+`',
      'Ctrl+Shift+O',
      // 画布
      'Space', 'Ctrl+Shift+Z', 'Escape',
    };

    final List<String> offenders = <String>[
      for (final Command c in registry.all)
        for (final KeyBinding b in c.keys)
          if (occupied.contains(b.label)) '${c.id} → ${b.label}',
    ];

    expect(
      offenders,
      isEmpty,
      reason:
          '分发器是"旁观者"、拦不下事件（见 command/bindings.dart）：与编辑器同键位\n'
          '会让**两条命令同时执行**。要占就先让编辑器让位，或改用真消费的机制。',
    );
  });

  test('键位都落在 §3.4 划定的空闲区', () {
    const Set<String> declaredFree = <String>{
      'Ctrl+P',
      'Ctrl+Shift+P',
      'Ctrl+N',
      'Ctrl+Shift+N',
      'Ctrl+,',
      'Ctrl+W',
      r'Ctrl+\',
      'F1',
      // 2026-09-28：AI 问答轨开关（§3.4 空闲区新增）。单按 Ctrl+J 编辑器
      // 不占（占的是块样式 Ctrl+Shift+J），二者不撞。
      'Ctrl+J',
      // 2026-09-30：全局搜索浮层 search.open（⌘K 范式）。编辑器已摘除官方
      // 插入链接命令（note_editor_view 的命令表过滤），Ctrl+K 正式进入空闲区。
      'Ctrl+K',
      // 2026-10-06：nav.back / nav.forward（统一导航历史的键盘路）。Alt+←/→
      // 是 Windows 资源管理器 / 浏览器的"后退 / 前进"惯例，桌面用户零学习。
      // 编辑器不占这两个键（Alt+方向键在 appflowy 键表里无绑定）。
      'Alt+Arrow Left',
      'Alt+Arrow Right',
      // 2026-10-17：全局灵感 stream.capture（M = memo）。编辑器不占
      // Ctrl+Shift+M，与 Ctrl+M 也无冲突（后者同样空着）。
      'Ctrl+Shift+M',
    };
    final RegExp functionKeys = RegExp(r'^F([1-9]|1[0-2])$');
    bool isFree(String label) =>
        declaredFree.contains(label) ||
        label.startsWith('Ctrl+Alt+') ||
        functionKeys.hasMatch(label);

    final List<String> offenders = <String>[
      for (final Command c in registry.all)
        for (final KeyBinding b in c.keys)
          if (!isFree(b.label)) '${c.id} → ${b.label}',
    ];

    expect(
      offenders,
      isEmpty,
      reason:
          '新增键位必须先更新 §3.4 的占用图与空闲区，再写进命令——'
          '否则"这个键为什么被吃了"永远查不出来。',
    );
  });

  test('标题/说明里的汉字都在拼音表里（否则拼音检索**无声失效**）', () {
    final List<String> missing = <String>[
      for (final Command c in registry.all)
        for (final String text in <String>[
          c.title,
          if (c.hint != null) c.hint!,
        ])
          for (final String ch in uncoveredHanChars(text)) '${c.id}：「$ch」',
    ];

    expect(
      missing,
      isEmpty,
      reason: '在 `lib/src/command/fuzzy.dart` 的 _initialByRune 里补上首字母。',
    );
  });

  test('UI 依赖的命令 id 必须在册（按钮按 id 取命令）', () {
    // `home_screen` 的「新建笔记 / 新建画布」按钮走的就是这两个 id。
    // 改 id 不会编译报错，只会让按钮**静默失效**——所以在这里钉住。
    for (final String id in <String>[
      'note.new',
      'canvas.new',
      'note.promote',
      'search.open',
      'palette.open',
      'app.settings',
      'ai.ask',
    ]) {
      expect(registry.byId(id), isNotNull, reason: '缺命令 $id');
    }
  });

  test('空上下文下每条命令都能判可用性（不抛、不假设有笔记）', () {
    for (final Command c in registry.all) {
      expect(
        () => c.isEnabled(const CommandContext()),
        returnsNormally,
        reason: '${c.id} 的 enabled 在空上下文下抛了——面板一打开就会炸。',
      );
    }
  });
}
