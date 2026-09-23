import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/command/command.dart';
import 'package:sinan/src/command/palette.dart';
import 'package:sinan/src/command/registry.dart';
import 'package:sinan/src/theme/app_theme.dart';

/// 命令面板的**行为**（`docs/ui_rewrite_plan.md` §3.5）。
///
/// 面板是"不需要记快捷键"的那条路，它错了的形态很具体：
/// 搜不到（拼音/分档错）、把不可用的命令执行了（置灰形同虚设）、
/// 或者回车执行了**另一条**命令（选中下标错位）——最后一种最危险，
/// 所以下面单独钉了 ↑↓ 与回车配对的那条。
Command _cmd(
  String id,
  String title,
  List<String> ran, {
  String? hint,
  bool enabled = true,
  CommandGroup group = CommandGroup.file,
  CommandScope scope = CommandScope.global,
  List<KeyBinding> keys = const <KeyBinding>[],
}) => Command(
  id: id,
  title: title,
  hint: hint,
  group: group,
  scope: scope,
  keys: keys,
  enabled: (CommandContext _) => enabled,
  run: (CommandContext _) async => ran.add(id),
);

Future<void> _pump(
  WidgetTester tester, {
  required CommandRegistry registry,
  required VoidCallback onClose,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: CommandPalette(
          registry: registry,
          // 空上下文 = 没选笔记（"收藏"这类命令据此置灰）。
          commandContext: const CommandContext(),
          onClose: onClose,
        ),
      ),
    ),
  );
  // 走一帧：`initState` 的 postFrame 聚焦回调在这一帧之后生效。
  await tester.pump();
}

/// 卸下树。`CommandPalette` 在 `initState` 里装了**全局键盘旁观者**，
/// 不卸干净会漏到下一个用例（表现为对已销毁的 State 调 setState）。
Future<void> _unmount(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox.shrink());

void main() {
  testWidgets('列出全部命令：不可用的也显示（置灰），右侧给键位/无快捷键', (tester) async {
    final CommandRegistry registry = CommandRegistry(<Command>[
      _cmd(
        'note.new',
        '新建笔记',
        <String>[],
        keys: <KeyBinding>[
          const KeyBinding(key: LogicalKeyboardKey.keyN, control: true),
        ],
      ),
      _cmd('note.promote', '收藏 / 取消收藏', <String>[], enabled: false),
    ]);
    await _pump(tester, registry: registry, onClose: () {});

    // 命令永不消失：不可用的那条仍在列表里（§3.1 的"置灰而非隐藏"）。
    expect(find.text('新建笔记'), findsOneWidget);
    expect(find.text('收藏 / 取消收藏'), findsOneWidget);
    // 右侧键位提示，"没有键位"也明说——这是键位的发现入口。
    expect(find.text('Ctrl+N'), findsOneWidget);
    expect(find.text('无快捷键'), findsOneWidget);

    await _unmount(tester);
  });

  testWidgets('输入即时过滤；拼音首字母可搜到', (tester) async {
    final CommandRegistry registry = CommandRegistry(<Command>[
      _cmd('note.new', '新建笔记', <String>[]),
      _cmd('canvas.new', '新建画布', <String>[]),
      _cmd('app.settings', '设置', <String>[]),
    ]);
    await _pump(tester, registry: registry, onClose: () {});

    await tester.enterText(find.byType(TextField), 'xjbj');
    await tester.pump();
    expect(find.text('新建笔记'), findsOneWidget);
    expect(find.text('设置'), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzzz');
    await tester.pump();
    expect(find.text('没有匹配的命令'), findsOneWidget);

    await _unmount(tester);
  });

  testWidgets('回车执行选中的命令，并先关掉面板', (tester) async {
    final List<String> ran = <String>[];
    bool closed = false;
    final CommandRegistry registry = CommandRegistry(<Command>[
      _cmd('note.new', '新建笔记', ran),
      _cmd('app.settings', '设置', ran),
    ]);
    await _pump(tester, registry: registry, onClose: () => closed = true);

    await tester.enterText(find.byType(TextField), '设置');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(ran, <String>['app.settings']);
    expect(closed, isTrue, reason: '命令要打开的界面不该被面板盖在下面');

    await _unmount(tester);
  });

  testWidgets('置灰的命令：回车什么都不发生', (tester) async {
    final List<String> ran = <String>[];
    final CommandRegistry registry = CommandRegistry(<Command>[
      _cmd('note.promote', '收藏 / 取消收藏', ran, enabled: false),
    ]);
    await _pump(tester, registry: registry, onClose: () {});

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(ran, isEmpty);

    await _unmount(tester);
  });

  testWidgets('↓ 到底后停住（不回绕到第一行）', (tester) async {
    final List<String> ran = <String>[];
    final CommandRegistry registry = CommandRegistry(<Command>[
      _cmd('a.first', '新第一个', ran),
      _cmd('b.second', '新第二个', ran),
    ]);
    await _pump(tester, registry: registry, onClose: () {});

    // ↓ 两次：第二次已在末行。回绕的话会跳回第一行，用户会选错目标。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(ran, <String>['b.second']);

    await _unmount(tester);
  });

  testWidgets('↑ 回顶后停住', (tester) async {
    final List<String> ran = <String>[];
    final CommandRegistry registry = CommandRegistry(<Command>[
      _cmd('a.first', '新第一个', ran),
      _cmd('b.second', '新第二个', ran),
    ]);
    await _pump(tester, registry: registry, onClose: () {});

    // ↓ 到第二行，再 ↑ 两次：第二次已在首行，必须停住。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(ran, <String>['a.first']);

    await _unmount(tester);
  });

  /// §5.2 的**第二条**浮层通则：Tab 不许漏到面板外。
  ///
  /// 与"打开即接管焦点"是两件事：焦点在面板内，只保证**起点**对；Tab 走到最后一个
  /// 控件后往哪去，由**作用域边界**决定（SDK `_moveFocus` 取 `nearestScope`）。
  /// 只接管焦点而不圈边界时，Tab 会走进遮罩背后的界面（2026-09-21 用户实报）。
  testWidgets('焦点陷阱：Tab 一直在面板内（不会漏到背后界面）', (tester) async {
    final CommandRegistry registry = CommandRegistry(<Command>[
      _cmd('note.new', '新建笔记', <String>[]),
      _cmd('note.promote', '收藏 / 取消收藏', <String>[]),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Column(
            children: <Widget>[
              // "背后界面"：一个 `autofocus` 的占位 + 一个按钮（真实场景里是编辑器
              // 与侧栏）。没有它们，这条用例在"没圈边界"时也可能碰巧通过。
              const Focus(
                autofocus: true,
                child: SizedBox(width: 40, height: 20),
              ),
              FilledButton(onPressed: () {}, child: const Text('背后')),
              Flexible(
                child: CommandPalette(
                  registry: registry,
                  commandContext: const CommandContext(),
                  onClose: () {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    // 走一帧：`initState` 的 postFrame 聚焦回调在这一帧之后生效。
    await tester.pump();

    final Element palette = tester.element(find.byType(CommandPalette));
    bool insidePalette(FocusNode? node) {
      final BuildContext? ctx = node?.context;
      if (ctx == null) return false;
      if (ctx == palette) return true;
      bool found = false;
      ctx.visitAncestorElements((Element e) {
        if (e == palette) {
          found = true;
          return false;
        }
        return true;
      });
      return found;
    }

    for (int i = 0; i < 12; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        insidePalette(FocusManager.instance.primaryFocus),
        isTrue,
        reason: '第 ${i + 1} 次 Tab 漏出了面板（焦点陷阱失效）',
      );
    }

    await _unmount(tester);
  });
}
