import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/editor/core/emoji_picker.dart';
import 'package:sinan/src/theme/tokens.dart';

/// 标题表情：按光标插入的纯逻辑 + 网格/分类/搜索。
///
/// 这两组是**不进编辑器**的廉价闸门：插入函数是纯逻辑，网格是独立小组件，
/// 都不必挂 appflowy 编辑器。整条"按钮 → 弹层 → 插入 → 落盘"链路由
/// `test/notes/note_editor_view_appflowy_test.dart` 的用例覆盖。
void main() {
  group('insertEmojiAtCursor（纯逻辑）', () {
    test('无有效光标 ⇒ 插到开头当首个字符（表情是标题图标位）', () {
      final TextEditingController c = TextEditingController(text: '标题');
      addTearDown(c.dispose);
      // 新建控制器的选区是 offset -1（无效）——正是"没点进过标题"的现场。
      insertEmojiAtCursor(c, '😀');
      expect(c.text, '😀标题');
      // 光标落到表情之后：😀 占 2 个 UTF-16 code unit。
      expect(c.selection.baseOffset, 2);
    });

    test('光标在中间 ⇒ 插到光标处', () {
      final TextEditingController c = TextEditingController(text: '标题');
      addTearDown(c.dispose);
      c.selection = const TextSelection.collapsed(offset: 1);
      insertEmojiAtCursor(c, '😀');
      expect(c.text, '标😀题');
      expect(c.selection.baseOffset, 1 + 2);
    });

    test('有选区 ⇒ 替换选区', () {
      final TextEditingController c = TextEditingController(text: '标题');
      addTearDown(c.dispose);
      c.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 2,
      ); // 选中「标题」
      insertEmojiAtCursor(c, '😀');
      expect(c.text, '😀');
      expect(c.selection.baseOffset, 2);
    });

    test('复合 emoji（多 code unit）参与光标定位', () {
      // ❤️ = U+2764 U+FE0F ⇒ length 2；光标必须再走 2 格，否则插在 emoji 中间。
      final TextEditingController c = TextEditingController(text: '标');
      addTearDown(c.dispose);
      c.selection = const TextSelection.collapsed(offset: 1);
      insertEmojiAtCursor(c, '❤️');
      expect(c.text, '标❤️');
      expect(c.selection.baseOffset, 1 + 2);
    });

    test('标题为空、无光标 ⇒ 只剩表情', () {
      final TextEditingController c = TextEditingController();
      addTearDown(c.dispose);
      insertEmojiAtCursor(c, '😀');
      expect(c.text, '😀');
      expect(c.selection.baseOffset, 2);
    });
  });

  group('EmojiPickerPanel（数据 / 网格 / 分类 / 搜索）', () {
    /// 扁平全表（跨分类）。
    List<String> allChars() => <String>[
      for (final EmojiCategory c in EmojiPickerPanel.categories)
        for (final EmojiEntry e in c.entries) e.char,
    ];

    /// 网格里的表情格（限在滚动区里）。
    ///
    /// ⚠️ 分类 chip 也用 emoji 当图标 ⇒ `find.text('😀')` 会同时命中 chip 和
    /// 格子。必须把查找**限到网格的 SingleChildScrollView**（chip 在它外面）。
    Finder gridCell(String emoji) => find.descendant(
      of: find.byType(SingleChildScrollView),
      matching: find.text(emoji),
    );

    test('数据规模：8 分类、200+ 表情，字符不重复', () {
      final List<String> chars = allChars();
      expect(EmojiPickerPanel.categories.length, 8);
      expect(chars.length, greaterThan(200), reason: '应有 200+ 表情');
      expect(chars.toSet().length, chars.length, reason: '表情字符不应重复');
    });

    testWidgets('网格 8 列排布、格子 32×32、换行正确', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: EmojiPickerPanel.width,
                child: EmojiPickerPanel(onPick: (String _) {}),
              ),
            ),
          ),
        ),
      );

      /// 某枚表情所在格子的 rect（最近的 Container 祖先 = 32×32 格；
      /// `gridCell` 命中的是 Text 墨迹框，非格子框）。
      Rect cellRect(String emoji) => tester.getRect(
        find
            .ancestor(of: gridCell(emoji), matching: find.byType(Container))
            .first,
      );

      // 默认显示首个分类（笑脸），取其前 9 枚看换行。
      final List<String> first = <String>[
        for (final EmojiEntry e in EmojiPickerPanel.categories.first.entries)
          e.char,
      ];
      expect(cellRect(first.first).width, 32, reason: '表情格应是 32×32');
      expect(cellRect(first.first).height, 32);
      expect(
        cellRect(first[7]).top,
        cellRect(first[0]).top,
        reason: '第 8 枚仍在第一行',
      );
      expect(
        cellRect(first[8]).top,
        greaterThan(cellRect(first[0]).top),
        reason: '第 9 枚应换行',
      );
    });

    test('面板宽度算式与 AppPopover 定位输入一致', () {
      // AppPopover 靠已知宽度把面板钳进屏幕内；这个值一旦和网格几何脱节，
      // 靠右的按钮弹面板就会溢出窗口。钉死算式：8 列 × 32 + 7 缝 + 两侧内距。
      expect(
        EmojiPickerPanel.width,
        8 * 32 + 7 * Tokens.spaceXs + Tokens.spaceMd * 2,
      );
    });

    testWidgets('点一枚回调那一枚', (WidgetTester tester) async {
      String? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmojiPickerPanel(onPick: (String e) => picked = e),
          ),
        ),
      );

      await tester.tap(gridCell('😀'));
      await tester.pump();
      expect(picked, '😀');
    });

    testWidgets('分类 Tab 切换实际生效（点「手势」chip → 换到手势）', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: EmojiPickerPanel(onPick: (String _) {})),
        ),
      );

      // 默认（笑脸）：😀 格子在，手势的 👋 不在。
      expect(gridCell('😀'), findsOneWidget);
      expect(gridCell('👋'), findsNothing);

      // 点「手势」chip（按 Tooltip 文案定位）。
      await tester.tap(find.byTooltip('手势'));
      await tester.pumpAndSettle();

      // 手势分类：👋 格子在，笑脸的 😀 不在。
      expect(gridCell('👋'), findsOneWidget);
      expect(gridCell('😀'), findsNothing);
    });

    testWidgets('搜索：中文名 / 英文关键词 两种都能命中（跨分类）', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: EmojiPickerPanel(onPick: (String _) {})),
        ),
      );

      final Finder search = find.byType(TextField);
      expect(search, findsOneWidget);

      // 中文名「开心」→ 😀（搜索时分类 Tab 隐藏，😀 只剩格子）。
      await tester.enterText(search, '开心');
      await tester.pumpAndSettle();
      expect(gridCell('😀'), findsOneWidget);

      // 英文关键词「rocket」→ 🚀（旅行分类，跨分类命中）。
      await tester.enterText(search, 'rocket');
      await tester.pumpAndSettle();
      expect(gridCell('🚀'), findsOneWidget);
      expect(gridCell('😀'), findsNothing);

      // 清空 ⇒ 回到默认分类（笑脸）。
      await tester.enterText(search, '');
      await tester.pumpAndSettle();
      expect(gridCell('😀'), findsOneWidget);
    });

    testWidgets('搜索无结果 ⇒ 空态文案', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: EmojiPickerPanel(onPick: (String _) {})),
        ),
      );
      await tester.enterText(find.byType(TextField), 'zzzzqqqq');
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的表情'), findsOneWidget);
    });

    testWidgets('hover 表情格不抛异常', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: EmojiPickerPanel(onPick: (String _) {})),
        ),
      );
      final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        mouse.hover(tester.getCenter(gridCell('😀'))),
      );
      await tester.pumpAndSettle();
      // hover 后不抛异常即可（视觉高亮是 Container 换色，非必断）。
      expect(tester.takeException(), isNull);
    });
  });
}
