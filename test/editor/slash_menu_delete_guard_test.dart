// 只有 TextNode 暴露 delta setter；官方建议的 Paragraph 未从 appflowy_editor 导出，
// 测试里用它构造带文本的首段落，故整文件忽略弃用提示。
// ignore_for_file: deprecated_member_use

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

/// `SelectionMenuItem._deleteSlash` 的回归闸门。
///
/// 原版（vendored `selection_menu_widget.dart`）在 `lastIndexOf('/')` 返回 -1 时
/// 直接把 -1 喂给 `Transaction.deleteText`，触发越界断言、并打断整条手势/键盘分发
/// （实测：在 `/` 斜杠菜单里点任意条目即崩）。根因是光标落在 `/` 之前、或 IME
/// 合成态下 `/` 不在 `substring(0, end)` 里。补丁：找不到 `/` 就跳过删除。
///
/// 注意：门卫**不**兜底成 0 去删 `[0, end)`——`/` 永远是插入在光标处，若光标已跑到
/// `/` 之前，[0, end) 里有的是 `/` 之前合法文本，兜底 0 会误删。
class _FakeMenuService implements SelectionMenuService {
  @override
  Offset get offset => Offset.zero;
  @override
  Alignment get alignment => Alignment.topLeft;
  @override
  SelectionMenuStyle get style => SelectionMenuStyle.light;
  @override
  Future<void> show() async {}
  @override
  void dismiss() {}
  @override
  (double?, double?, double?, double?) getPosition() =>
      (null, null, null, null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final SelectionMenuService menuService = _FakeMenuService();

  SelectionMenuItem makeItem() => SelectionMenuItem(
        getName: () => 'x',
        icon: (EditorState e, bool s, SelectionMenuStyle st) =>
            const SizedBox.shrink(),
        keywords: const ['x'],
        // 无操作：只测 _deleteSlash 的越界防护，不真正插入节点。
        handler: (EditorState e, SelectionMenuService s, BuildContext c) {},
      );

  testWidgets('光标前无 "/" 时选条目不抛越界异常、且文本不变', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    final BuildContext context = tester.element(find.byType(SizedBox));

    final document = Document.blank();
    // 直接构造带文本的首段落（基类 Node 没有 delta setter，只有 TextNode 有）。
    // 只有 TextNode 暴露 delta setter；官方建议的 Paragraph 未从 appflowy_editor 导出。
    final TextNode textNode = TextNode(delta: Delta()..insert('abc'));
    document.root.insert(textNode, index: 0); // 没有触发字符 '/'
    final EditorState editorState = EditorState(document: document);
    editorState.selection = Selection.collapsed(
      Position(path: const [0], offset: 3),
    );

    final SelectionMenuItem item = makeItem()..deleteSlash = true;

    // 补丁前这里会抛 "index + length <= delta.length" 断言。
    expect(
      () => item.handler(editorState, menuService, context),
      returnsNormally,
    );
    // 找不到 '/' ⇒ 不删任何东西。
    expect(textNode.delta.toPlainText(), 'abc');
  });

  test('前置事实：`offset - 1` 喂给 deleteText 必然断言（补丁 18 防的就是它）', () {
    // 这条不是测修复，而是**证明断言真实存在**——否则下面那条 widget 用例可能是空转。
    final document = Document.blank();
    final TextNode textNode = TextNode(delta: Delta());
    document.root.insert(textNode, index: 0);
    final EditorState editorState = EditorState(document: document);

    expect(
      () => editorState.transaction..deleteText(textNode, -1, 1),
      throwsAssertionError,
    );
  });

  testWidgets('块首按退格：不抛越界断言（补丁 18，键盘路径）', (WidgetTester tester) async {
    final document = Document.blank();
    final TextNode textNode = TextNode(delta: Delta());
    document.root.insert(textNode, index: 0);
    final EditorState editorState = EditorState(document: document);
    // 关键前置：光标在**块首**（offset 0）而菜单还开着 ⇒ `offset - 1` 算成 -1。
    // 真实复现路径（2026-09-17 用户实机）：输入 "/" 打开菜单 → 退格删掉 "/"
    // （菜单 onExit 了，但这一帧仍挂着）→ 再按一次退格。
    // ⚠️ offset 就是 **0**（`Position` 的默认值，故不显式传）——这正是本用例的关键前置。
    editorState.selection = Selection.collapsed(Position(path: const [0]));

    bool exited = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionMenuWidget(
            items: <SelectionMenuItem>[makeItem()],
            maxItemInRow: 3,
            editorState: editorState,
            menuService: menuService,
            onExit: () => exited = true,
            onSelectionUpdate: () {},
            selectionMenuStyle: SelectionMenuStyle.light,
            itemCountFilter: 1,
            deleteSlashByDefault: false,
          ),
        ),
      ),
    );
    // `initState` 在 postFrame 里抢焦点——键盘得先有个焦点节点才发得到它。
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    // ⚠️ 这条同时排除了"测试空转"：`exited` 只可能由 `_onKeyEvent` 的退格分支置位，
    // 它 true ⇒ 按键**确实**到了 handler；于是下面那条断言才有意义。
    expect(exited, isTrue, reason: 'keyword 已空 ⇒ 菜单应当退出（按键没到 handler？）');
    expect(
      tester.takeException(),
      isNull,
      reason: '补丁前这里是 `The index(-1) or length(1) is out of range` 断言',
    );
    expect(textNode.delta.toPlainText(), '', reason: '块首没有可删的字符');
  });
}
