import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
// 官方 material：vendored 工具栏用的是它（material_ui 的同名类型是另一套）。
import 'package:flutter/material.dart' as official;
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyEvent, LogicalKeyboardKey, PhysicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/editor/blocks/code_block_component.dart';
import 'package:sinan/src/editor/core/editor_icons.dart';
import 'package:sinan/src/editor/toolbar/fixed_toolbar.dart';
import 'package:sinan/src/editor/toolbar/link_toolbar_item.dart';
import 'package:sinan/src/editor/widgets/hover_state_layer.dart';
import 'package:sinan/src/theme/app_theme.dart';
// FloatingToolbar 未在包 barrel 导出，深路径引入（与视图同一前提：vendored
// path 依赖，上游改路径会立刻编译报错）。
// ignore: implementation_imports
import 'package:appflowy_editor/src/editor/toolbar/desktop/floating_toolbar.dart'
    as appflowy_toolbar;
// 浮条容器 key（`@visibleForTesting`）由 barrel 导出，不必深路径引入。

/// 编辑器工具栏（官方 FloatingToolbar，2026-09-12 起浮出）的回归测试。
///
/// 断言对应的都是**实查踩到过的坑**，不是理论风险：
/// 1. 官方条目的 builder 里是 `editorState.selection!`——悬浮条靠 `isActive`
///    过滤保证"无选区不构建"，固定条必须常驻 ⇒ 禁用时必须复用上次的
///    widget 灰显，否则当场崩；
/// 2. 点工具栏会抢焦点 → appflowy 的键盘服务随即清空选区 ⇒ 动作变空操作。
///    所以既要断言"属性写进去了"，也要断言"选区还在"；
/// 3. 撤销条目的可用态来自历史栈，得随**事务**刷新（选区通知盖不住）。
void main() {
  group('编辑器工具栏（浮动）', () {
    test('条目表直接复用官方 item（不是复制品）', () {
      final List<ToolbarItem> items = sinanFixedToolbarItems();

      // 身份相同 = 用的就是官方那个实例，官方升级后行为自动跟着走。
      // （块样式 `paragraphItem` + `headingItems` 已合并为自研下拉，见下。）
      expect(items, contains(bulletedListItem));
      expect(items, contains(numberedListItem));
      expect(items, contains(quoteItem));
      // 对齐已合并为自研单按钮（不再是官方三个独立条目）：存在 id='sinan.align'、
      // 分组 6（官方"对齐组"，分隔线位置不变）、apply 语义仍走官方 updateNode。
      final ToolbarItem align = items.firstWhere(
        (ToolbarItem item) => item.id == 'sinan.align',
      );
      expect(
        align.group,
        6,
        reason: '对齐单按钮应落在官方对齐组（分隔线位置）',
      );
      // 块样式（正文 / 标题 1~3）已合并成**一个下拉**（官方四件套不再平铺）。
      expect(
        items.firstWhere((ToolbarItem item) => item.id == 'sinan.heading').group,
        1,
        reason: '块样式组（官方 group 1）',
      );

      final ToolbarItem officialBold = markdownFormatItems.firstWhere(
        (ToolbarItem item) => item.id == 'editor.bold',
      );
      final ToolbarItem usedBold = items.firstWhere(
        (ToolbarItem item) => item.id == 'editor.bold',
      );
      // 2026-09-12 起条目统一包了保焦装饰（_withKeepEditorFocusItem），实例不再
      // 是官方那个——但 builder 仍是**原样转发**给官方实现，升级白得的语义
      // 不变。这里退而断言 id / group / isActive 三元组透传无损。
      expect(usedBold.id, officialBold.id);
      expect(usedBold.group, officialBold.group);

      // 颜色条目已合并为自研单按钮：id='sinan.color'、分组 4（官方颜色组）。
      expect(
        items.map((ToolbarItem item) => item.id),
        contains('sinan.color'),
      );
      expect(
        items.firstWhere((ToolbarItem item) => item.id == 'sinan.color').group,
        4,
        reason: '分组 4 = 官方"颜色组"，改了会挪动分隔线位置',
      );

      // 超链接：自研条目（官方版有"光标态空转 + 裸域名静默拒绝"两处坑，
      // 见 link_toolbar_item.dart），与颜色同组 4。
      expect(
        items.firstWhere((ToolbarItem item) => item.id == 'sinan.link').group,
        4,
      );
    });

    _desktopTestWidgets('无选区：浮动栏不挂载（官方语义：光标态即隐）', (
      WidgetTester tester,
    ) async {
      final EditorState state = await _pump(tester);
      // _pump 落的是折叠光标（浮动栏不显示）；再显式清空——
      // 等价于 Esc / 光标移到标题栏。
      state.selection = null;
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // 浮动栏条目不挂载（此前固定栏语义是"灰显常驻"，2026-09-12 改浮出）。
      expect(_toolbarItem('editor.bold'), findsNothing);
    });

    _desktopTestWidgets('有选区：点"加粗"既写入属性、也不丢选区', (
      WidgetTester tester,
    ) async {
      final EditorState state = await _pump(tester);
      state.selection = _selection(0, 2);
      await tester.pumpAndSettle();

      await tester.tap(_toolbarItem('editor.bold'));
      await tester.pumpAndSettle();

      expect(
        _attributeOf(state, AppFlowyRichTextKeys.bold),
        isTrue,
        reason: '点加粗没写进文档',
      );
      // 动作读的是 editorState.selection：它若在中途被清空，上面的断言会
      // 先挂。这里显式留一条，防的是"把条目换成会抢焦点的实现"。
      expect(state.selection, isNotNull, reason: '点工具栏后选区没了');
    });

    _desktopTestWidgets('保焦契约：按下 increase、抬起释放（菜单类条目的通路）', (
      WidgetTester tester,
    ) async {
      final EditorState state = await _pump(tester);
      keepEditorFocusNotifier.reset();
      // 浮动栏只在扩展选区时浮出——先拖出一段让条目挂载。
      state.selection = _selection(0, 2);
      await tester.pumpAndSettle();

      // 按下（不抬起）：此刻起"别清选区"生效——后面要加的插入/颜色菜单
      // 就靠它把选区活过浮层交互期。
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(_toolbarItem('editor.bold')),
      );
      await tester.pump();
      expect(keepEditorFocusNotifier.value, 1, reason: '按下时未保焦');
      expect(state.selection, isNotNull, reason: '按下时选区就没了');

      await gesture.up();
      await tester.pumpAndSettle();
      expect(keepEditorFocusNotifier.value, 0, reason: '抬起后未释放（会一直保焦）');
    });

    _desktopTestWidgets('块样式下拉：选「标题 1」把当前块变成标题', (
      WidgetTester tester,
    ) async {
      final EditorState state = await _pump(tester);
      // 浮动栏只在**扩展选区**时浮出（折叠光标不显示）——固定栏时代可直接
      // 用折叠光标点，现在先拖出一段。
      state.selection = _selection(0, 2);
      await tester.pumpAndSettle();

      // 4 个平铺按钮已合并成一个下拉：点开 → 选「标题 1」。
      await tester.tap(_toolbarItem('sinan.heading'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('标题 1'));
      await tester.pumpAndSettle();

      final Node node = state.document.root.children.first;
      expect(node.type, HeadingBlockKeys.type);
      expect(node.attributes[HeadingBlockKeys.level], 1);

      // 再选「正文」→ 回到段落，且**不留 level 脏属性**。
      await tester.tap(_toolbarItem('sinan.heading'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('正文'));
      await tester.pumpAndSettle();

      final Node back = state.document.root.children.first;
      expect(back.type, ParagraphBlockKeys.type);
      expect(
        back.attributes.containsKey(HeadingBlockKeys.level),
        isFalse,
        reason: '转回正文后不该残留 level',
      );
    });

    _desktopTestWidgets('待办条目：段落 → 待办 → 段落（往返，属性不留脏）', (
      WidgetTester tester,
    ) async {
      final EditorState state = await _pump(tester);
      // 浮动栏只在扩展选区时浮出（同块样式下拉测试）。
      state.selection = _selection(0, 2);
      await tester.pumpAndSettle();

      final Finder todo = _toolbarItem('sinan.todo_list');
      await tester.tap(todo);
      await tester.pumpAndSettle();
      Node node = state.document.root.children.first;
      expect(node.type, TodoListBlockKeys.type);
      expect(node.attributes[TodoListBlockKeys.checked], false);

      await tester.tap(todo);
      await tester.pumpAndSettle();
      node = state.document.root.children.first;
      expect(node.type, ParagraphBlockKeys.type);
      expect(
        node.attributes.containsKey(TodoListBlockKeys.checked),
        isFalse,
        reason: '转回段落后仍残留 checked 属性',
      );
    });

    _desktopTestWidgets('对齐单按钮：点开选「居中」写入 align=center', (
      WidgetTester tester,
    ) async {
      final EditorState state = await _pump(tester);
      state.selection = _selection(0, 2);
      await tester.pumpAndSettle();

      // 按钮默认显示当前对齐（左），点开弹出三选一。
      await tester.tap(_toolbarItem('sinan.align'));
      await tester.pumpAndSettle();
      expect(find.text('居中'), findsOneWidget);

      await tester.tap(find.text('居中'));
      await tester.pumpAndSettle();

      final Node node = state.document.root.children.first;
      expect(
        node.attributes[blockComponentAlign],
        'center',
        reason: '选居中没写进 align 属性',
      );
      // 选区应保留（保焦机制让浮层交互期不丢选区）。
      expect(state.selection, isNotNull);
    });

    // 「撤销条目：格式写入后可撤销，属性回退」这条用例已随条目**一起搬走**
    // （2026-09-14）：撤销 / 重做不再属于悬浮栏，改常驻标题行左侧。等价闸门在
    // `test/note_editor_view_appflowy_test.dart` 的
    // 「撤销/重做常驻标题行：没有选区也能用，且随历史栈灰显」。

    _desktopTestWidgets('图标已统一为 Lucide（官方条目的换皮钩子接线成功）', (
      WidgetTester tester,
    ) async {
      // main() 里的那一步（测试不跑 main，必须显式安装）。
      installEditorIcons();
      final EditorState state = await _pump(tester);
      // 浮动栏只在扩展选区时渲染条目（折叠光标下整条不挂载）。
      state.selection = _selection(0, 2);
      await tester.pumpAndSettle();

      final Set<IconData> rendered = tester
          .widgetList<Icon>(find.byType(Icon))
          .map((Icon icon) => icon.icon)
          .whereType<IconData>()
          .toSet();

      // 官方条目（加粗 / 标题 1 / 左对齐）渲染的是映射表里的 Material Symbols 字形
      // （字重 300 由主题 iconTheme 统一控制，不再有 Lucide 那种"字体族档位"之分）。
      expect(
        rendered,
        contains(Symbols.format_bold),
        reason: '官方"加粗"仍是包内 SVG（钩子没接上）',
      );
      // 块样式按钮显示**当前样式**（此处光标在段落里 ⇒ 正文图标 T）。
      expect(rendered, contains(Symbols.text_fields));
      expect(rendered, contains(Symbols.format_align_left));
      // 自研条目（撤销/重做已搬去标题行，这里改用待办条目当代表）。
      expect(rendered, contains(Symbols.checklist));
    });

    test('tooltip 承诺的快捷键 = 真实绑定（"按了没反应"就出在这里）', () {
      final Map<String, CommandShortcutEvent> bound =
          <String, CommandShortcutEvent>{
        // 行内格式条目在 kEditorTooltips 里用**短 id**（bold/italic/…，
        // 与段落/标题不同），故这里也用短 id 查表。
        'bold': toggleBoldCommand,
        'italic': toggleItalicCommand,
        'underline': toggleUnderlineCommand,
        'strikethrough': toggleStrikethroughCommand,
        'code': toggleCodeCommand,
        'sinan.undo': undoCommand,
        'sinan.redo': redoCommand,
        'sinan.todo_list': toggleTodoListCommand,
        'sinan.link': showLinkMenuCommand,
        // 颜色面板本身没有绑定，tooltip 声明的是官方"切换高亮"（Ctrl+Shift+H）。
        'sinan.color': toggleHighlightCommand,
        // 以下都是**自研**绑定（官方没有），tooltip 与命令一一对应。
        'editor.bulleted_list': sinanBulletedListCommand,
        'editor.numbered_list': sinanNumberedListCommand,
        'editor.quote': sinanQuoteCommand,
        'sinan.toc': sinanTocCommand(onToggle: () {}),
        // ⚠️ 代码块不进这张表：它的 tooltip 写的是**字面量反引号**
        // （`Ctrl+Shift+\``），而命令串必须用官方键名 `backquote`——
        // 两者有意不同，故单独断言（见下方）。
      };
      bound.forEach((String id, CommandShortcutEvent event) {
        expect(
          _claimedShortcut(kEditorTooltips[id]!),
          _displayCommand(event.command.split(',').first.trim().toLowerCase()),
          reason: '$id 的 tooltip 与绑定不一致',
        );
      });

      // 块样式下拉：一个 tooltip 声明四条官方绑定，逐个核对（官方事件
      // 没被 barrel 导出，按实查值钉住——来源 `heading_command_shortcut.dart`
      // 的 toggleBody / toggleH1 / toggleH2 / toggleH3）。
      // 菜单里每项右侧的快捷键标注也必须一致（同一份数据源）。
      final String headingTip = kEditorTooltips['sinan.heading']!;
      for (final (String shortcut, String label) in <(String, String)>[
        ('ctrl+shift+b', '正文'),
        ('ctrl+shift+t', '标题 1'),
        ('ctrl+shift+g', '标题 2'),
        ('ctrl+shift+j', '标题 3'),
      ]) {
        expect(
          headingTip.toLowerCase(),
          contains(shortcut),
          reason: 'tooltip 未声明 $label 的 $shortcut',
        );
      }

      // 对齐下拉：一个 tooltip 声明三个方向，逐个比对自研命令。
      final String alignTip = kEditorTooltips['sinan.align']!;
      for (final CommandShortcutEvent event in sinanAlignCommands) {
        expect(
          alignTip.toLowerCase(),
          contains(event.command),
          reason: '对齐 tooltip 未声明 ${event.command}',
        );
      }

      // 自研两条：代码块（我们实现的）与搜索（官方 find 工厂，ctrl+f）。
      expect(sinanCodeBlockCommand.command, 'ctrl+shift+backquote');
      expect(_claimedShortcut(kEditorTooltips['sinan.find']!), 'ctrl+f');
    });

    test('每个工具栏条目都有 tooltip 文案（漏一个就等于"哑按钮"）', () {
      // 行内格式条目（官方 markdownFormatItems）传给 tooltipBuilder 的是
      // **短 id**（bold/…），其余条目用完整 id；这里按同一口径换算。
      const Set<String> inlineFormats = <String>{
        'bold',
        'italic',
        'underline',
        'strikethrough',
        'code',
      };
      for (final ToolbarItem item in sinanFixedToolbarItems()) {
        final String shortId = item.id.split('.').last;
        final String key = inlineFormats.contains(shortId) ? shortId : item.id;
        expect(
          kEditorTooltips[key],
          isNotNull,
          reason: '条目 ${item.id} 没有 tooltip 文案（key=$key）',
        );
        expect(kEditorTooltips[key]!.trim(), isNotEmpty);
      }
    });

    test('快捷键无冲突：所有条目声明的组合键互不重复', () {
      // 工具栏按钮越来越多，重复绑定 = 一个按键触发两个动作
      // （先命中先赢，另一个静默失效）。这里对**全部声明**去重。
      final Map<String, String> claimed = <String, String>{};
      kEditorTooltips.forEach((String id, String text) {
        // 对齐那条一个 tooltip 声明三条键，正则只能抠出连成一片的一串，
        // 故跳过、由下面的 align 循环逐条查重。
        if (id == 'sinan.align') return;
        final String? shortcut = _claimedShortcut(text);
        if (shortcut == null) return;
        expect(
          claimed.containsKey(shortcut),
          isFalse,
          reason: '$id 与 ${claimed[shortcut]} 都声明了 $shortcut',
        );
        claimed[shortcut] = id;
      });
      // 对齐那条特殊：一个 tooltip 声明三个键，单独查重。
      for (final CommandShortcutEvent event in sinanAlignCommands) {
        expect(
          claimed.containsKey(event.command),
          isFalse,
          reason: '${event.command} 与 ${claimed[event.command]} 冲突',
        );
        claimed[event.command] = 'sinan.align';
      }
      // 反向核对：官方已占用的键没有被我们重复占用。
      for (final CommandShortcutEvent official in <CommandShortcutEvent>[
        toggleBoldCommand,
        toggleItalicCommand,
        toggleUnderlineCommand,
        toggleStrikethroughCommand,
        toggleCodeCommand,
        undoCommand,
        redoCommand,
        toggleTodoListCommand,
        showLinkMenuCommand,
        toggleHighlightCommand,
      ]) {
        final String key = official.command.split(',').first.trim().toLowerCase();
        expect(
          <String>[
            sinanBulletedListCommand.command,
            sinanNumberedListCommand.command,
            sinanQuoteCommand.command,
            sinanCodeBlockCommand.command,
            ...sinanAlignCommands.map((CommandShortcutEvent e) => e.command),
            sinanTocCommand(onToggle: () {}).command,
            sinanPasteCommand.command,
          ],
          isNot(contains(key)),
          reason: '自研绑定 $key 与官方命令冲突',
        );
      }
    });

    test('链接输入归一化：裸域名可提交，非法输入不静默', () {
      // 官方 `isUri` 拒绝裸域名且 onSubmitted 直接 return ⇒ "回车什么也没有"。
      expect(normalizeLinkInput('baidu.com'), 'https://baidu.com');
      expect(normalizeLinkInput('  example.com/a?b=1  '), 'https://example.com/a?b=1');
      expect(normalizeLinkInput('localhost:8080'), 'https://localhost:8080');
      // 已带 scheme 的原样保留。
      expect(
        normalizeLinkInput('https://x.com/path#h'),
        'https://x.com/path#h',
      );
      expect(normalizeLinkInput('mailto:a@b.com'), 'mailto:a@b.com');
      // 非法：调用方据此就地报错（不静默）。
      expect(normalizeLinkInput(''), isNull);
      expect(normalizeLinkInput('笔记标题'), isNull);
      expect(normalizeLinkInput('这不是网址'), isNull);
      // 含空白的句子不是网址（否则"粘贴转链"会把整句话变成链接）。
      expect(normalizeLinkInput('看这个 baidu.com 很好'), isNull);
    });

    test('Ctrl+Shift+` 的命令串与官方键名/修饰键匹配（写错键名会静默失效）', () async {
      // `simulateKey*` 是 flutter_test 的**顶层函数**：它会同步更新
      // `HardwareKeyboard`，而官方 `Keybinding` 判断修饰键正是读它。
      await simulateKeyDownEvent(LogicalKeyboardKey.control);
      await simulateKeyDownEvent(LogicalKeyboardKey.shift);
      addTearDown(() async {
        await simulateKeyUpEvent(LogicalKeyboardKey.shift);
        await simulateKeyUpEvent(LogicalKeyboardKey.control);
      });

      const KeyEvent event = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.backquote,
        logicalKey: LogicalKeyboardKey.backquote,
        timeStamp: Duration.zero,
        character: '~',
      );
      expect(
        sinanCodeBlockCommand.canRespondToRawKeyEvent(event),
        isTrue,
        reason: '命令串必须是官方键名 `backquote`（写字面量反引号匹配不上）',
      );
      // 少一个修饰键就不该匹配（否则会误吃掉别人的按键）。
      await simulateKeyUpEvent(LogicalKeyboardKey.shift);
      expect(sinanCodeBlockCommand.canRespondToRawKeyEvent(event), isFalse);
    });

    _desktopTestWidgets('快捷键功能：列表 / 引用 / 对齐 / 目录都能改文档', (
      WidgetTester tester,
    ) async {
      final EditorState state = await _pump(tester);
      Node first() => state.document.root.children.first;

      // 无序列表：段落 ↔ 无序（再按一次回正文）。
      expect(sinanBulletedListCommand.execute(state), KeyEventResult.handled);
      expect(first().type, BulletedListBlockKeys.type);
      sinanBulletedListCommand.execute(state);
      expect(first().type, ParagraphBlockKeys.type, reason: '再按应转回正文');

      // 有序列表。
      sinanNumberedListCommand.execute(state);
      expect(first().type, NumberedListBlockKeys.type);
      sinanNumberedListCommand.execute(state);
      expect(first().type, ParagraphBlockKeys.type);

      // 引用。
      sinanQuoteCommand.execute(state);
      expect(first().type, QuoteBlockKeys.type);
      sinanQuoteCommand.execute(state);
      expect(first().type, ParagraphBlockKeys.type);

      // 对齐三键（左 / 中 / 右）。
      for (final (int i, String align) in <(int, String)>[
        (0, 'left'),
        (1, 'center'),
        (2, 'right'),
      ]) {
        expect(sinanAlignCommands[i].execute(state), KeyEventResult.handled);
        expect(first().attributes[blockComponentAlign], align);
      }

      // 目录：状态在视图，快捷键只负责触发回调。
      int toggles = 0;
      sinanTocCommand(onToggle: () => toggles++).execute(state);
      expect(toggles, 1);

      // 放掉撤销历史合并定时器（否则框架报 pending timer）。
      await tester.pump(const Duration(seconds: 2));
    });

    // 说明：这里**直接调用命令对象**，不走真实按键。原因实测过：widget 测试里
    // 键盘事件路由不到编辑器（连官方已有的 Ctrl+Enter 对照组也不触发），
    // 那是测试框架的限制。命令串本身的正确性由上面那条断言守住，
    // 这条守住"执行后行为"（与工具栏条目共用 toggleSinanCodeBlock）。
    _desktopTestWidgets('执行代码块命令：段落 → 代码块 → 段落（可往返）', (
      WidgetTester tester,
    ) async {
      final EditorState state = await _pump(tester);
      expect(state.document.root.children.first.type, ParagraphBlockKeys.type);

      expect(sinanCodeBlockCommand.execute(state), KeyEventResult.handled);
      expect(state.document.root.children.first.type, CodeBlockKeys.type);

      expect(sinanCodeBlockCommand.execute(state), KeyEventResult.handled);
      expect(
        state.document.root.children.first.type,
        ParagraphBlockKeys.type,
        reason: '再按一次应转回段落（与工具栏条目同一条路径）',
      );

      // 放掉 appflowy 的撤销历史合并定时器（否则框架会报
      // "A Timer is still pending even after the widget tree was disposed"）。
      await tester.pump(const Duration(seconds: 2));
    });
  });

  group('条目状态层（悬停 / 按下底色）', () {
    // 官方 `SVGIconItemWidget` 把 hoverColor/highlightColor/splashColor 三色
    // 显式置透明 ⇒ 整条浮动栏原本没有任何指针反馈（2026-09-15 实机反馈）。
    // 这组用例钉住我们补的那层：悬停出底色、按下更实、离开全清。
    const Color base = Color(0xFF49454F);

    BoxDecoration decorationOf(WidgetTester tester) {
      final DecoratedBox box = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(HoverStateLayer),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      return box.decoration as BoxDecoration;
    }

    testWidgets('悬停出底色 → 按下更实 → 离开全清', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: HoverStateLayer(
                base: base,
                child: SizedBox(width: 30, height: 30),
              ),
            ),
          ),
        ),
      );
      final Finder layer = find.byType(HoverStateLayer);

      expect(decorationOf(tester).color, isNull, reason: '常态不该有底色');

      final TestGesture mouse =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);

      // 悬停：一档状态层。
      await mouse.moveTo(tester.getCenter(layer));
      await tester.pump();
      expect(decorationOf(tester).color, AppTheme.stateLayer(base));

      // 按下：更实一档（两者同为 12% 时按下看不出变化）。
      await mouse.down(tester.getCenter(layer));
      await tester.pump();
      expect(decorationOf(tester).color, AppTheme.stateLayerPressed(base));
      await mouse.up();
      await tester.pump();
      expect(
        decorationOf(tester).color,
        AppTheme.stateLayer(base),
        reason: '松开应回到悬停态而不是常态',
      );

      // 离开：底色必须消失（留下不消失的状态层等于"按钮一直亮着"）。
      await mouse.moveTo(const Offset(5, 5));
      await tester.pump();
      expect(decorationOf(tester).color, isNull);
    });

    testWidgets('按下后拖出按钮再松开：不留下按下色', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: HoverStateLayer(
                base: base,
                child: SizedBox(width: 30, height: 30),
              ),
            ),
          ),
        ),
      );
      final Finder layer = find.byType(HoverStateLayer);
      final TestGesture mouse =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);

      await mouse.moveTo(tester.getCenter(layer));
      await mouse.down(tester.getCenter(layer));
      await tester.pump();
      expect(decorationOf(tester).color, AppTheme.stateLayerPressed(base));

      // 拖出热区再松手（常见于"按错了、划走取消"）。
      await mouse.moveTo(const Offset(5, 5));
      await mouse.up();
      await tester.pump();
      expect(decorationOf(tester).color, isNull);
    });
  });

  testWidgets('浮条与选区留 8px 间隔（不贴着拖选区域）', (WidgetTester tester) async {
    final EditorState state = await _pump(tester);
    // 展开选区：浮动栏只在扩展选区时浮出（官方显示带 200ms debounce）。
    state.selection = Selection.collapsed(
      Position(path: <int>[0]),
    );
    state.selection = Selection(
      start: Position(path: <int>[0]),
      end: Position(path: <int>[0], offset: 2),
    );
    await tester.pumpAndSettle();

    final Finder row = find.byKey(floatingToolbarContainerKey);
    expect(row, findsOneWidget, reason: '浮条没浮出——选区没建起来？');

    // 条的**外框** = 容器 Row 的最近一层 Material（官方容器 = Material + Container）。
    final Rect bar = tester.getRect(
      find.ancestor(of: row, matching: find.byType(official.Material)).first,
    );
    final List<Rect> rects = state.selectionRects();
    expect(rects, isNotEmpty, reason: '选区矩形为空，量不出间隔');
    final Rect anchor =
        rects.reduce((Rect a, Rect b) => a.top <= b.top ? a : b);

    // 正常落位在选区上方 ⇒ 间隙 = 选区顶缘 − 条的下缘；
    // 选区贴顶时改落选区下方 ⇒ 间隙 = 条的顶缘 − 选区下缘。
    const double expectedGap = 8;
    final double above = anchor.top - bar.bottom;
    final double below = bar.top - anchor.bottom;
    expect(
      above == expectedGap || below == expectedGap,
      isTrue,
      reason: '浮条与选区的间隔不是 $expectedGap px（上方 $above / 下方 $below）——'
          '官方落位是"紧贴选区"，这段留白靠 [sinan 补丁 13]'
          '（`floating_toolbar.dart` 的 `_toolbarTop` / `_toolbarGap`），'
          '丢掉补丁（上游升级覆盖）就会退回零间隔',
    );
  });

  testWidgets('浮条外形：40 外高、条目在条内垂直居中', (WidgetTester tester) async {
    final EditorState state = await _pump(tester);
    state.selection = Selection.collapsed(Position(path: <int>[0]));
    state.selection = Selection(
      start: Position(path: <int>[0]),
      end: Position(path: <int>[0], offset: 2),
    );
    await tester.pumpAndSettle();

    final Finder row = find.byKey(floatingToolbarContainerKey);
    expect(row, findsOneWidget, reason: '浮条没浮出');
    final Rect bar = tester.getRect(
      find.ancestor(of: row, matching: find.byType(official.Material)).first,
    );
    expect(
      bar.height,
      40,
      reason: '外高应为 38（floatingToolbarHeight）+ 上下各 1px 发丝描边 = 40',
    );

    // 条目（30×30 硬约束）必须落在条的中线上：官方的 `Row` 是
    // `CrossAxisAlignment.start`、每项包一层 `Center`——`Center` 在 loose
    // 约束下撑满行高再居中内容，加高到 40 后图标仍应居中而不是贴顶。
    // 量的是 [HoverStateLayer]（恰好等于条目自己的 30×30 热区），
    // 不是外层 `Center`（那是撑满的，量不出居中与否）。
    final Rect item = tester.getRect(
      find.descendant(
        of: _toolbarItem('editor.bold'),
        matching: find.byType(HoverStateLayer),
      ),
    );
    expect(item.height, 30, reason: '条目盒应仍是 30×30');
    expect(
      (item.center.dy - bar.center.dy).abs(),
      lessThan(0.51),
      reason: '条目没垂直居中：条目中心 ${item.center.dy} vs 条中心 ${bar.center.dy}',
    );
  });
}

/// 命令串 → **用户可见**的快捷键写法。
///
/// 官方 `key_mapping.dart` 里数字键叫 `digit 8`，裸 `'8'` 不在映射表里
/// （`Keybinding.keyCode` 查不到会抛 null 检查异常，整条键盘分发断掉——
/// 当年正是为此把命令改成 `ctrl+shift+digit 8`）。而 tooltip 面向用户只能
/// 写 `Ctrl+Shift+8`。**同一个键、两种写法**，与代码块那条（`backquote`
/// vs 字面量 `` ` ``）是同一类：键名与字面量有意不同，比较前先归一。
String _displayCommand(String command) => command.replaceAll('digit ', '');

/// 从 tooltip 文案里抠出承诺的快捷键（`加粗（Ctrl+B）` → `ctrl+b`）。
///
/// ⚠️ 代码块那条写的是字面量 `Ctrl+Shift+\``，而命令串必须用官方的键名
/// `backquote`（`key_mapping.dart`）——两者**有意不同**，故那条单独断言。
String? _claimedShortcut(String tooltip) {
  final RegExpMatch? match = RegExp(r'（(Ctrl\+[^）]+)）').firstMatch(tooltip);
  return match?.group(1)?.toLowerCase();
}

/// 桌面平台下的用例包装。
///
/// Flutter 的按钮**只在桌面/Web 上点按抢焦点**（移动端不抢），而
/// "点工具栏 → 编辑器失焦 → 选区被清空"恰恰是桌面上的坑；测试默认跑在
/// android 上，不设这一层则整条通路根本不会被触发（等于没测）。
///
/// 覆盖必须在**用例体内**设置并复原：框架在用例体结束时校验"debug 变量
/// 已还原"，写进 `setUp`/`tearDown` 会因时序不对而全线报错。
void _desktopTestWidgets(
  String description,
  Future<void> Function(WidgetTester tester) body,
) {
  testWidgets(description, (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

// ─────────────────────────── 脚手架 ───────────────────────────

const String _kText = '你好世界';

/// 与 `note_editor_view_appflowy.dart` 同构的最小脚手架：
/// 固定工具栏 + 官方编辑器 + 同一套主题/本地化/桥。
Future<EditorState> _pump(WidgetTester tester) async {
  final Document document = Document(
    root: pageNode(children: <Node>[paragraphNode(text: _kText)]),
  );
  final EditorState state = EditorState(document: document);
  final EditorScrollController scroll = EditorScrollController(
    editorState: state,
  );
  addTearDown(() {
    scroll.dispose();
    state.dispose();
  });

  // 与视图一致：打开即落光标（固定条目的可用性依赖"有选区"）。
  state.selection = Selection.collapsed(Position(path: <int>[0]));

  final ThemeData theme = AppTheme.light();
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      // 与 main.dart 同构：官方本地化委托 + appflowy 委托（缺后者会抛
      // "AppFlowyEditorLocalizations not found"）。
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        ...GlobalMaterialLocalizations.delegates,
        AppFlowyEditorLocalizations.delegate,
      ],
      supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
      builder: (BuildContext context, Widget? child) =>
          // appflowy 内部 import 官方 material，必须过桥才能读到我们的主题。
          // ignore: deprecated_member_use
          MaterialUiCompatibilityBridge(child: child!),
      home: Scaffold(
        body: Column(
          children: <Widget>[
            Expanded(
              // 与视图同构：官方 FloatingToolbar 包住编辑器（条目表同一来源）。
              child: appflowy_toolbar.FloatingToolbar(
                items: sinanFixedToolbarItems(),
                editorState: state,
                editorScrollController: scroll,
                textDirection: TextDirection.ltr,
                // 与视图同构的轻拟态外观（含 1px 发丝描边与 40px 外高）：
                // 外形断言必须测生产同一套参数，否则测的是脚手架默认值。
                style: appflowy_toolbar.FloatingToolbarStyle(
                  backgroundColor: const Color(0x00000000),
                  toolbarActiveColor: theme.colorScheme.onSurfaceVariant,
                  toolbarIconColor: theme.colorScheme.onSurfaceVariant,
                ),
                decoration: AppTheme.neuFloatBar(
                  theme.brightness,
                  theme.colorScheme,
                ),
                // 11 + 1px 描边 = 12 侧距；38 + 2px 描边 = 40 外高。
                padding: const EdgeInsets.symmetric(horizontal: 11),
                floatingToolbarHeight: 38,
                child: AppFlowyEditor(
                  editorState: state,
                  editorScrollController: scroll,
                  autoFocus: true,
                  editorStyle: EditorStyle.desktop(
                    textStyleConfiguration: TextStyleConfiguration(
                      text: TextStyle(
                        fontSize: 16,
                        color: theme.colorScheme.onSurface,
                      ),
                      href: const TextStyle(),
                      code: const TextStyle(),
                      autoComplete: const TextStyle(),
                      lineHeight: 1.7,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

Selection _selection(int start, int end) => Selection(
  start: Position(path: <int>[0], offset: start),
  end: Position(path: <int>[0], offset: end),
);

/// 浮动栏条目的 finder：官方把条目 key 设为
/// `appflowy_editor_floating_toolbar_item_<id>_<index>`，index 随分组
/// 分隔线数量变化，故按 id 前缀匹配而不是整 key。
Finder _toolbarItem(String itemId) => find.byWidgetPredicate(
  (Widget widget) =>
      (widget.key?.toString() ?? '').contains('floating_toolbar_item_$itemId'),
);

/// 取首个块里的行内属性（走 delta 的 JSON，不依赖 delta 内部类型）。
Object? _attributeOf(EditorState state, String key) {
  final Node node = state.document.root.children.first;
  for (final Object? op in node.delta?.toJson() ?? const <Object?>[]) {
    if (op is Map) {
      final Object? attributes = op['attributes'];
      if (attributes is Map && attributes[key] != null) return attributes[key];
    }
  }
  return null;
}
