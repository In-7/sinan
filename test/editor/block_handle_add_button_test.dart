import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/editor/blocks/custom_block_components.dart';
import 'package:sinan/src/editor/core/editor_typography.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import '../support/app_font.dart';

/// 块手柄的两个按钮（**对齐官方 `BlockAddButton` / `OptionButton`**，2026-09-15）：
///
/// **“+”**：
/// - 默认在**下方**插入空段落；按住 **Alt** ⇒ 在**上方**插入
///   ——这两条正是 tooltip 里承诺的（"tooltip 声明的操作 = 真实绑定"是项目纪律，
///   所以必须有测试守着，否则提示就成了空话）；
/// - 当前块**已经是空段落**时**复用**它、不新建（防止连按 “+” 拉出一串空行）。
///
/// **“⠿”**：点击打开块操作菜单（转为 / 复制 / 删除）。
///
/// 交互前提：手柄由官方 `BlockComponentActionWrapper` 的 `MouseRegion` 控制，
/// 悬停块才浮出 ⇒ 每个用例先 hover 一次。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await loadAppFont();
  });

  testWidgets('默认：在下方插入空段落', (WidgetTester tester) async {
    final EditorState state = await _pump(tester, <String>['甲', '乙']);
    await _tapAdd(tester, blockIndex: 0, alt: false);

    expect(_types(state), <String>['paragraph', 'paragraph', 'paragraph']);
    expect(_texts(state), <String>['甲', '', '乙'], reason: '新段落应落在"甲"下方');
  });

  testWidgets('Alt：在上方插入空段落', (WidgetTester tester) async {
    final EditorState state = await _pump(tester, <String>['甲', '乙']);
    await _tapAdd(tester, blockIndex: 1, alt: true);

    expect(_texts(state), <String>[
      '甲',
      '',
      '乙',
    ], reason: 'Alt+点击应在"乙"上方插入（tooltip 里承诺的第二个动作）');
  });

  testWidgets('当前块已是空段落：复用，不新增节点', (WidgetTester tester) async {
    final EditorState state = await _pump(tester, <String>['甲', '']);
    await _tapAdd(tester, blockIndex: 1, alt: false);

    expect(_types(state), <String>[
      'paragraph',
      'paragraph',
    ], reason: '空段落上再点 “+” 应该复用它（否则连按会拉出一串空行）');
  });

  testWidgets('⠿ 点击打开块操作菜单：删除', (WidgetTester tester) async {
    final EditorState state = await _pump(tester, <String>['甲', '乙']);
    await _openActionsMenu(tester, blockIndex: 0);

    expect(find.text('转为'), findsOneWidget, reason: '菜单没打开');
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(_texts(state), <String>['乙'], reason: '删除应作用于整块');
  });

  testWidgets('⠿ 菜单「转为」：段落 → 引用', (WidgetTester tester) async {
    final EditorState state = await _pump(tester, <String>['甲']);
    await _openActionsMenu(tester, blockIndex: 0);

    await tester.tap(find.text('转为'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('引用'));
    await tester.pumpAndSettle();

    expect(_types(state), <String>['quote']);
    expect(_texts(state), <String>['甲'], reason: '换类型不该丢文本');
  });

  testWidgets('⠿ 菜单「转为」不带脏属性（标题 → 列表摘掉 level）', (WidgetTester tester) async {
    // 2026-11-19 修脏属性 bug：typeItem 原用 `copyWith(type:)` 保留全部旧属性
    // ⇒ 标题转列表留 `level`（脏属性跟着落库、导出 markdown 异常），且与正文/
    // 标题那条路径（applyBlockStyle 摘 level）口径不一致。现改白名单 ⇒ 摘掉。
    final EditorState state = await _pump(tester, <String>['甲']);
    // 共享同一 mouse pointer：本用例开两次菜单，两个 pointer 会撞 mouse tracker
    // 的「add/remove 必须交替」断言。
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    await _openActionsMenu(tester, blockIndex: 0, mouse: mouse);
    await tester.tap(find.text('转为'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标题 2'));
    await tester.pumpAndSettle();
    expect(
      state.document.root.children.first.attributes[HeadingBlockKeys.level],
      2,
      reason: '先转成标题 2（带 level）',
    );

    await _openActionsMenu(tester, blockIndex: 0, mouse: mouse);
    await tester.tap(find.text('转为'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('无序列表'));
    await tester.pumpAndSettle();

    final Node node = state.document.root.children.first;
    expect(node.type, BulletedListBlockKeys.type);
    expect(
      node.attributes.containsKey(HeadingBlockKeys.level),
      isFalse,
      reason: '标题的 level 不该留给列表（脏属性）',
    );
    expect(_texts(state), <String>['甲'], reason: '换类型不该丢文本');
  });

  testWidgets('⠿ 菜单「复制」：在下方插入副本', (WidgetTester tester) async {
    final EditorState state = await _pump(tester, <String>['甲']);
    await _openActionsMenu(tester, blockIndex: 0);

    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();

    expect(_texts(state), <String>['甲', '甲']);
  });

  testWidgets('+ 点击弹出斜杠菜单（锚点不落空）', (WidgetTester tester) async {
    // 钉「+」弹斜杠菜单链路：插空段落 → post-frame → 斜杠菜单（锚点 = 新块 rect）。
    // 2026-11-19 实测：外层 post-frame **必要**（去掉则 selectionRects 空、菜单不弹）。
    final EditorState state = await _pump(tester, <String>['甲']);
    await _tapAdd(tester, blockIndex: 0, alt: false);
    expect(
      find.byType(SelectionMenuWidget),
      findsOneWidget,
      reason: '点 + 后应弹斜杠菜单（锚点不能落空）',
    );
    expect(_texts(state), <String>['甲', ''], reason: '新段落落在下方');
  });

  testWidgets('⠿ 菜单「转为」：分三组 + 勾选当前块类型', (WidgetTester tester) async {
    // 2026-11-19 借鉴 Notion / 官方：分「标题类 / 列表类 / 其他」三组 + 勾选当前
    // 块类型（左侧 tabler.Check）。分隔线在 menuChildren（overlay），故按全树找。
    await _pump(tester, <String>['甲']);
    await _openActionsMenu(tester, blockIndex: 0);
    await tester.tap(find.text('转为'));
    await tester.pumpAndSettle();

    // 子菜单展开：各组的项都在（标题类「正文」、列表类「无序列表」、其他「代码块」）。
    expect(find.text('正文'), findsOneWidget, reason: '标题类项在');
    expect(find.text('无序列表'), findsOneWidget, reason: '列表类项在');
    expect(find.text('代码块'), findsOneWidget, reason: '其他组项在');
    expect(
      find.byType(tabler.Check),
      findsOneWidget,
      reason: '当前块类型（段落 ⇒「正文」）应勾选',
    );
  });
}

/// 悬停指定块 → 点它的 “⠿” 打开块操作菜单。
Future<void> _openActionsMenu(
  WidgetTester tester, {
  required int blockIndex,
  TestGesture? mouse,
}) async {
  final Finder block = _blockTextOf(blockIndex);
  // [mouse] 传入则复用同一 pointer（同一用例多次开菜单时避免 mouse tracker 的
  // 「add/remove 必须交替」断言）；否则新建并挂 teardown 清理。
  final TestGesture m =
      mouse ?? await tester.createGesture(kind: PointerDeviceKind.mouse);
  if (mouse == null) {
    await m.addPointer(location: Offset.zero);
    addTearDown(m.removePointer);
  }
  await m.moveTo(tester.getCenter(block));
  await tester.pumpAndSettle();

  final Finder dragHandle = find.descendant(
    of: find
        .ancestor(of: block, matching: find.byType(BlockComponentActionWrapper))
        .first,
    matching: find.byType(tabler.GripVertical),
  );
  expect(dragHandle, findsOneWidget, reason: '该块的 ⠿ 没浮出');
  await tester.tap(dragHandle);
  await tester.pumpAndSettle();
}

/// 悬停指定块 → 点**它自己的** “+”（[alt] 为 true 时全程按住 Alt）。
///
/// ⚠️ 必须按块定位手柄：`find.byType(tabler.Plus)` 会命中**每一个**块的手柄，
/// `.first` 是第 0 块的那个（第一版就是这么错点、断言全废的）。
Future<void> _tapAdd(
  WidgetTester tester, {
  required int blockIndex,
  required bool alt,
}) async {
  final Finder block = _blockTextOf(blockIndex);
  final Finder wrapper = find
      .ancestor(of: block, matching: find.byType(BlockComponentActionWrapper))
      .first;

  // 悬停块本体：官方 wrapper 的 MouseRegion 一进就把手柄浮出。
  final TestGesture mouse = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
  );
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await mouse.moveTo(tester.getCenter(block));
  await tester.pumpAndSettle();

  final Finder addButton = find.descendant(
    of: wrapper,
    matching: find.byType(tabler.Plus),
  );
  expect(addButton, findsOneWidget, reason: '该块的手柄没浮出（悬停没生效？）');

  if (alt) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  }
  try {
    await tester.tap(addButton);
    await tester.pumpAndSettle();
  } finally {
    if (alt) {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    }
  }
}

/// 第 [blockIndex] 块的**正文** RichText。
///
/// 空段落会多出一层"占位符" RichText ⇒ 不能简单按 `at(index)` 数（数错就会
/// 悬停到隔壁块）。这里按块的顶层子树取第一个（正文层排在占位层之前）。
Finder _blockTextOf(int blockIndex) => find
    .descendant(
      of: find.byType(BlockComponentActionWrapper).at(blockIndex),
      matching: find.byType(RichText),
    )
    .first;

List<String> _types(EditorState state) => <String>[
  for (final Node n in state.document.root.children) n.type,
];

List<String> _texts(EditorState state) => <String>[
  for (final Node n in state.document.root.children)
    n.delta?.toPlainText() ?? '',
];

Future<EditorState> _pump(WidgetTester tester, List<String> texts) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final Document document = Document(
    root: pageNode(
      children: <Node>[for (final String t in texts) paragraphNode(text: t)],
    ),
  );
  final EditorState state = EditorState(document: document);
  addTearDown(state.dispose);

  const EditorTypography typography = EditorTypography(
    fontSize: 17,
    lineHeight: 1.5,
  );
  final TextStyleConfiguration config = typography.toTextStyleConfiguration(
    text: const Color(0xFF000000),
    link: const Color(0xFF1565C0),
    codeBackground: const Color(0xFFEEEEEE),
    muted: const Color(0xFF757575),
  );

  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        ...GlobalMaterialLocalizations.delegates,
        AppFlowyEditorLocalizations.delegate,
      ],
      supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
      home: Scaffold(
        body: SizedBox(
          width: 1200,
          height: 900,
          child: AppFlowyEditor(
            editorState: state,
            editorStyle: EditorStyle.desktop(
              padding: EditorTypography.blockPadding,
              maxWidth: 720,
              textStyleConfiguration: config,
            ),
            blockComponentBuilders: sinanBlockComponentBuilders(
              typography: typography,
              markerColor: const Color(0xFF1565C0),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}
