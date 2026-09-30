import 'dart:async' show unawaited;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryMouseButton;
// 官方 material：appflowy 内部用的是它，断言渲染树必须用官方类型
// （material_ui 的同名类型是另一套）。加前缀避免与本文件的 material_ui 冲突。
import 'package:flutter/material.dart' as official;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/domain/settings.dart';
import 'package:sinan/src/editor/core/note_document_adapter.dart';
import 'package:sinan/src/editor/panels/backlink_panel.dart';
import 'package:sinan/src/editor/panels/toc_panel.dart';
import 'package:sinan/src/editor/widgets/link_hover_tooltip.dart';
import 'package:sinan/src/notes/note_editor_view_appflowy.dart';
import 'package:sinan/src/app/pending_saves.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/theme/app_float_surface.dart';
import 'package:sinan/src/theme/app_theme.dart';

/// appflowy 编辑器视图的**装载 / 落盘 / 卸载**三条链路。
///
/// 为什么"不碰数据库"很关键：`notesProvider` / `settingsProvider` 用假
/// notifier 覆盖，因此不需要 sqlite3，也不碰文件系统——这段代码在切换
/// 开关之前**只被编译过、从未执行过**，正需要这种成本极低的覆盖。
///
/// 本文件的第一个用例守的是一个实测崩溃（用户实机报回来的）：
/// `dispose` 里用 `ref` 会抛
/// `Bad state: Using "ref" when a widget is about to or has been unmounted
/// is unsafe`——切笔记/关窗口必炸（那时正好要走兜底落盘）。
void main() {
  testWidgets('装载：笔记正文渲染出来（列表已加载的前提下）', (WidgetTester tester) async {
    final _FakeNotes notes = _FakeNotes(<Note>[_note()]);
    await _pumpView(tester, notes);

    expect(_renders(tester, '你好世界'), isTrue, reason: '正文没上树');
    expect(tester.takeException(), isNull);
  });

  testWidgets('反链面板贴在反链按钮下边（定位锚点没漏挂）', (WidgetTester tester) async {
    // 实测现场（2026-09-23）：面板飞到了**屏幕左上角**而不是按钮下方。
    // 根因不是定位算式，是那个 `GlobalKey` **漏挂**在按钮上 ⇒
    // `_backlinkButtonKey.currentContext == null` ⇒ 静默走兜底坐标
    // （`top: 56 / right: 16`）。这类 bug 编译期、数据层测试全都看不见，
    // 只有几何断言能钉住，所以补在这里。
    final _FakeNotes notes = _FakeNotes(<Note>[_note()]);
    await _pumpView(tester, notes);

    final Finder button = find.byKey(
      const ValueKey<String>('editor.ear.backlink'),
    );
    expect(button, findsOneWidget, reason: '反链按钮没渲染出来');

    await tester.tap(button);
    await tester.pumpAndSettle();

    final Finder panel = find.byType(BacklinkPanel);
    expect(panel, findsOneWidget, reason: '点了反链按钮但面板没打开');

    final Rect buttonRect = tester.getRect(button);
    final Rect panelRect = tester.getRect(panel);

    // 面板**右边缘**与按钮右边缘对齐（浮层右对齐），**顶边**与按钮底边无缝相接。
    expect(
      panelRect.right,
      closeTo(buttonRect.right, 1),
      reason: '面板右边缘没对齐按钮——多半是 `_backlinkButtonKey` 漏挂，'
          '定位回落到兜底坐标飞到左上角',
    );
    expect(
      panelRect.top,
      closeTo(buttonRect.bottom, 1),
      reason: '面板顶边没接住按钮底边',
    );
  });

  testWidgets('卸载兜底落盘：不碰 ref，且防抖里的编辑真的写下去', (WidgetTester tester) async {
    final _FakeNotes notes = _FakeNotes(<Note>[_note()]);
    await _pumpView(tester, notes);

    // 产生一次真实编辑（走事务 → 挂上 500ms 防抖），然后**立刻**卸载：
    // 不 settle，让防抖还挂着——这正是"关窗口丢最后一次编辑"的场景，
    // 也是唯一会走到 dispose 兜底落盘（原先用 ref 的那段）的路径。
    //
    // 工具栏浮动化（2026-09-12）后条目只在扩展选区时挂载：先拖出选区。
    await _expandSelection(tester);
    await tester.tap(_toolbarItem('sinan.todo_list'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());

    expect(
      tester.takeException(),
      isNull,
      reason: '卸载时抛异常（历史 bug：dispose 里用了 ref）',
    );
    expect(notes.savedContent, isNotNull, reason: '兜底落盘没发生，编辑丢了');
    expect(
      notes.savedContent,
      contains('todo_list'),
      reason: '落盘内容应是 v2 块树，且含刚切成的待办块',
    );
  });

  testWidgets('退出前落盘：防抖窗口内关窗口，最后那次编辑也要写下去', (WidgetTester tester) async {
    // 用户实测的丢数据现场（2026-09-17）：删掉一段文字 → 马上关窗口 → 重开后
    // 那段文字又回来了。原因是关窗口是**进程级退出**：走不到 dispose 兜底落盘，
    // 500ms 防抖也再没机会触发。本用例就钉这一条：退出路径必须能等到写完。
    final _FakeNotes notes = _FakeNotes(<Note>[_note()]);
    final PendingSaves saves = await _pumpView(tester, notes);

    // 一次真实编辑（走事务 ⇒ 挂上 500ms 防抖），但**不推进时间**。
    await _expandSelection(tester);
    await tester.tap(_toolbarItem('sinan.todo_list'));
    await tester.pump();
    expect(notes.savedContent, isNull, reason: '前置条件不成立：防抖已经自己落盘了，本用例就测不到退出路径');

    // 关窗口：引擎发来退出请求 → `didRequestAppExit` → 先等落盘
    // （见 `pending_saves.dart` 的 `flushThenExit`）。
    await saves.flushAll();

    expect(notes.savedContent, isNotNull, reason: '关窗口时最后一次编辑没写下去——用户实测丢的正是它');
    expect(notes.savedContent, contains('todo_list'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('退出前落盘：没有未落盘的编辑就不写（关窗口不该重写正文）', (WidgetTester tester) async {
    final _FakeNotes notes = _FakeNotes(<Note>[_note()]);
    final PendingSaves saves = await _pumpView(tester, notes);

    await saves.flushAll();

    // 与 dispose 兜底同一判据：打开看一眼就关窗口不该重写正文
    // （存量笔记会被重写一遍，而读入路径仍有有损项）。
    expect(notes.savedContent, isNull, reason: '什么都没改却重写了正文');
    expect(notes.savedTitle, isNull, reason: '什么都没改却重写了标题');
  });

  testWidgets('只打开不编辑就关闭 → 不写库（避免把存量笔记重写一遍）', (WidgetTester tester) async {
    final _FakeNotes notes = _FakeNotes(<Note>[_note()]);
    await _pumpView(tester, notes);

    await tester.pumpWidget(const SizedBox());

    expect(tester.takeException(), isNull);
    expect(notes.savedContent, isNull, reason: '什么都没改却重写了正文');
    expect(notes.savedTitle, isNull, reason: '什么都没改却重写了标题');
  });

  testWidgets('Ctrl+F 打开官方查找面板（此前 Ctrl+F 完全无效）', (WidgetTester tester) async {
    final _FakeNotes notes = _FakeNotes(<Note>[_note()]);
    await _pumpView(tester, notes);
    expect(find.byKey(const Key('closeButton')), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    // 官方面板的关闭钮 key（find_replace_widget.dart 里写死的稳定 key）。
    expect(find.byKey(const Key('closeButton')), findsOneWidget);
    // 外壳 = 统一浮层表面（2026-09-14 收进 L2）：不再是官方默认那块
    // "半透明选区色"面板。
    expect(
      find.ancestor(
        of: find.byKey(const Key('closeButton')),
        matching: find.byType(AppFloatSurface),
      ),
      findsOneWidget,
      reason: '查找面板没走浮层令牌（`_buildFindMenu` 的 findMenuBuilder 没生效）',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索耳走同一实现（与 Ctrl+F 行为一致）', (WidgetTester tester) async {
    final _FakeNotes notes = _FakeNotes(<Note>[_note()]);
    await _pumpView(tester, notes);

    await tester.tap(find.byKey(const ValueKey<String>('editor.ear.find')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('closeButton')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('目录远跳（官方 scrollTo 的双列表交叉淡入）不重复占用块 GlobalKey', (
    WidgetTester tester,
  ) async {
    // 目录只在窗口 ≥1100 时显示（与 quill 版同规则）。
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final _FakeNotes notes = _FakeNotes(<Note>[
      _note(content: _longNoteContent(sections: 150)),
    ]);
    await _pumpView(tester, notes);

    await tester.tap(find.byKey(const ValueKey<String>('editor.ear.toc')));
    await tester.pumpAndSettle();

    // 目录列表自己是懒加载的。
    final Finder tocList = find.descendant(
      of: find.byType(AppFlowyTocPanel),
      matching: find.byType(Scrollable),
    );
    // 目录内的条目：跳转后目标标题会**同时**出现在编辑器与目录里，
    // 所以查找必须限定在面板内（否则 find.text 会命中两个）。
    Finder tocEntry(String label) => find.descendant(
      of: find.byType(AppFlowyTocPanel),
      matching: find.text(label),
    );

    // 连点几条（用户实测是"点着点着"出现）。
    // 注意：这条用例是**冒烟守护**，不是那个 bug 的证明——官方动画版的双列表
    // 交叉淡入在测试的帧调度下不一定复现（实测复现不了）；真正的证据是实测栈：
    // A RenderLeaderLayer was mutated in RenderSliverList.performLayout +
    // Duplicate GlobalKey detected（落在 block_component_container 的 Consumer<Node>）。
    // 顺序**由前到后**：scrollUntilVisible 只会向后滚（往回要找会抛 No element）。
    for (final String label in <String>['第 20 节', '第 60 节', '第 150 节']) {
      await tester.scrollUntilVisible(
        tocEntry(label),
        300,
        scrollable: tocList,
      );
      await tester.tap(tocEntry(label));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '跳到「$label」后出错');
    }
  });

  testWidgets('目录跳转后在正文里短暂高亮落点块（位置线索的替代）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final _FakeNotes notes = _FakeNotes(<Note>[
      _note(content: _longNoteContent(sections: 6)),
    ]);
    await _pumpView(tester, notes);
    await tester.tap(find.byKey(const ValueKey<String>('editor.ear.toc')));
    await tester.pumpAndSettle();

    // 判据：编辑器内部出现**带底色**的块装饰（平时底色是 null）。
    // ⚠️ 类型必须是 material_ui 这一份——包装器是我们自己的代码
    // （`_flashWrapper`），官方内部那些 AnimatedContainer 是官方 material
    // 的同名不同类型，`find.byType` 不会命中它们。
    bool hasFlashingBlock() => tester
        .widgetList<AnimatedContainer>(
          find.descendant(
            of: find.byType(AppFlowyEditor),
            matching: find.byType(AnimatedContainer),
          ),
        )
        .any((AnimatedContainer c) {
          final Decoration? d = c.decoration;
          return d is BoxDecoration && d.color != null;
        });

    expect(hasFlashingBlock(), isFalse, reason: '未跳转时不该有高亮');

    final Finder entry = find.descendant(
      of: find.byType(AppFlowyTocPanel),
      matching: find.text('第 3 节'),
    );
    await tester.tap(entry);
    await tester.pump();
    expect(hasFlashingBlock(), isTrue, reason: '跳转后正文里对应的块应高亮');

    // **短暂**：到点自动淡出，不会留成"选中态"（同一条笔记连点几次也安全）。
    await tester.pump(const Duration(milliseconds: 900)); // 总时长到点
    await tester.pump(const Duration(milliseconds: 300)); // 淡出动画走完
    expect(hasFlashingBlock(), isFalse, reason: '高亮应自动消失');
  });

  testWidgets('末尾条目：落点高亮可用，且连点不再来回跳', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final _FakeNotes notes = _FakeNotes(<Note>[
      _note(content: _longNoteContent(sections: 150)),
    ]);
    await _pumpView(tester, notes);
    await tester.tap(find.byKey(const ValueKey<String>('editor.ear.toc')));
    await tester.pumpAndSettle();

    final Finder tocList = find.descendant(
      of: find.byType(AppFlowyTocPanel),
      matching: find.byType(Scrollable),
    );
    final Finder lastEntry = find.descendant(
      of: find.byType(AppFlowyTocPanel),
      matching: find.text('第 150 节'),
    );
    await tester.scrollUntilVisible(lastEntry, 300, scrollable: tocList);
    await tester.tap(lastEntry);
    await tester.pump();
    expect(_hasFlashingBlock(tester), isTrue, reason: '末尾条目也要有落点高亮');

    // 目录里那一行也必须是**激活态**（"到底兜底"）：末尾标题走不到"视口顶部
    // 之上"，没有这条兜底它永远不会高亮——用户实测"点最后一条，目录的指示条
    // 不显示"。
    await tester.pumpAndSettle();
    expect(
      _tocRowTint(tester, '第 150 节'),
      AppTheme.navSelectedTint(AppTheme.light().colorScheme.onSurface),
      reason: '末尾条目应当显示激活底色',
    );

    // 连点：**落定后位置必须一致**（不出现"跳一下又回来"）。
    //
    // ⚠️ 2026-09-14 留白回到官方一屏（600）后这条的行为变了：目标"够得到顶部"
    // 了，官方 `jumpTo` 会**真的跳**（留白只有 48px 时我们干脆**拒绝跳**，只给
    // 高亮——那是当时躲"跳下去又弹回来"的兜底）。跳的过程里 `jumpTo` 会先把
    // 内层**归零再重锚**，所以逐帧能看到中间帧的位移——那是官方动画的一部分，
    // 不是抖动。判据因此取**落定值**：连点多次，每次 `pumpAndSettle` 之后都必须
    // 停在同一位置（用户报的"来回跳"表现为落定值来回变）。
    await tester.pumpAndSettle();
    final double settled = _editorOffset(tester);
    for (int i = 0; i < 3; i++) {
      await tester.tap(lastEntry);
      await tester.pumpAndSettle();
      expect(
        _editorOffset(tester),
        closeTo(settled, 1),
        reason: '第 ${i + 2} 次点击后落点变了（连点应停在同一处）',
      );
    }
  });

  testWidgets('点击已在视口内的条目：瞬时到位 + 落点高亮（不能像按钮坏了）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // 30 节：够长到能滚（内容 > 一屏），又让"第 5 节"落在首屏里。
    final _FakeNotes notes = _FakeNotes(<Note>[
      _note(content: _longNoteContent(sections: 30)),
    ]);
    await _pumpView(tester, notes);
    await tester.tap(find.byKey(const ValueKey<String>('editor.ear.toc')));
    await tester.pumpAndSettle();

    final Finder entry = find.descendant(
      of: find.byType(AppFlowyTocPanel),
      matching: find.text('第 5 节'),
    );

    await tester.tap(entry);
    await tester.pump();
    expect(_hasFlashingBlock(tester), isTrue, reason: '点击应给出落点高亮');

    // "已在视口内"曾一度被实现成"什么都不做"（用户判为按钮失效）。现在一律走
    // 官方**瞬时** `jumpTo`，落点直接到位。
    //
    // ⚠️ 判据不能用编辑器内部滚动像素：官方 `jumpTo` 是"先把内层归零、再把
    // **锚点**挪到目标"，像素恒为 0，动的是锚点。可观测的证据是"视口顶部换成了
    // 第 5 节"——目录里那一行随之变成当前章节。
    await tester.pumpAndSettle();
    expect(
      _tocRowTint(tester, '第 5 节'),
      AppTheme.navSelectedTint(AppTheme.light().colorScheme.onSurface),
      reason: '跳转后「第 5 节」应当成为当前章节（页面确实动了）',
    );
  });

  testWidgets('标题改动走防抖，卸载时兜底保存', (WidgetTester tester) async {
    final _FakeNotes notes = _FakeNotes(<Note>[_note()]);
    await _pumpView(tester, notes);

    await tester.enterText(find.byType(TextField).first, '  新标题  ');
    await tester.pump();
    await tester.pumpWidget(const SizedBox());

    expect(tester.takeException(), isNull);
    // 与 quill 版同口径：标题两端裁剪后入库。
    expect(notes.savedTitle, '新标题');
  });

  // ─── 滚动高度稳定性（2026-09-14 立，防"离群项"回潮） ───
  //
  // 官方的懒构建列表**不知道**文档的真实总高：总高 = 已布局部分的实测高度
  // + 已布局块的平均高度 × 剩余块数（`_extrapolateMaxScrollOffset`，见
  // Flutter SDK `widgets/sliver.dart`）；整篇都布局完时（`lastIndex ==
  // childCount - 1`）才是精确值。滑动条的滑块长度 = 视口 /(视口 + 总高)，
  // 于是总高怎么变，滑块就怎么变。
  //
  // 2026-09-14 起滚动器不再走那套外推：应用侧逐块给出高度
  // （`EditorScrollController.itemExtentOf`，取值链见 `BlockHeights`），
  // 列表三段 sliver 各自求和 ⇒ 总高**从第一帧起精确**。于是这条闸门也随之
  // 收紧：整段滚动（**含末尾留白那一屏**）滑块都不许动。
  testWidgets('滚动中估计总高稳定（防止再引入离群项）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final List<Node> children = <Node>[
      for (int i = 0; i < 320; i++) paragraphNode(text: '短 $i'),
    ];
    final String content = NoteDocumentAdapter.storedContentFromDocument(
      Document(root: pageNode(children: children)),
    );

    final _FakeNotes notes = _FakeNotes(<Note>[_note(content: content)]);
    await _pumpView(tester, notes);

    final ScrollPosition pos = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(AppFlowyEditor),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;

    // 滚轮是真实路径（官方 `desktop_scroll_service` 就吃这个）。
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    final Offset center = tester.getCenter(find.byType(AppFlowyEditor));
    await tester.sendEventToBinding(mouse.hover(center));
    await tester.pump();

    final double first = pos.maxScrollExtent - pos.minScrollExtent;
    final double viewport = pos.viewportDimension;
    double lo = first;
    double hi = first;
    final int steps = (first / 400).ceil() + 4;
    for (int i = 0; i <= steps; i++) {
      final double total = pos.maxScrollExtent - pos.minScrollExtent;
      if (total < lo) lo = total;
      if (total > hi) hi = total;
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 400)));
      await tester.pumpAndSettle();
    }

    final double swing = (hi - lo) / first * 100;
    expect(
      swing,
      lessThan(1),
      reason:
          '滚动中总高波动 ${swing.toStringAsFixed(1)}% '
          '(${lo.toStringAsFixed(1)} ~ ${hi.toStringAsFixed(1)})：'
          '说明滚动器又回到"已布局块平均高度 × 剩余块数"的外推——离群项'
          '（末尾留白 / 高出正文的大块）会让滑块变长变短',
    );
    // 滑块长度（px）：thumb = 视口 / (视口 + 总高) × 视口。
    double thumb(double total) => viewport / (viewport + total) * viewport;
    expect(
      (thumb(lo) - thumb(hi)).abs(),
      lessThan(0.5),
      reason: '滑块长度变化超过半个像素',
    );
  });

  // ─── C：精确块高喂给滚动器（2026-09-14，vendored 补丁 10） ───
  //
  // 上面那条闸门量的是**官方外推**在均匀文档下的表现，并刻意排除了两种它治不了
  // 的情形（首屏高块扎堆、末尾一屏留白）。C 之后两条一并消失：应用侧通过
  // `EditorScrollController.itemExtentOf` 逐块给出高度（实测 → `TextPainter`
  // 预算 → 类型兜底），列表三段 sliver 各自求和 ⇒ **总高从第一帧起就是精确值**。
  testWidgets('C：总高从第一帧起精确——高矮块扎堆时全程不变', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // 故意让"首屏局部平均 ≫ 全篇平均"：20 个 6 行长段落在前 + 300 个单行段落。
    // 没有 C 时实测：初始估计 68646（真值 13864，放大 5 倍），滑块 6.9px 在滚动
    // 中一路"长"到 32.7px，且中段会猛滑一下（锚点制内容整体位移）。
    final List<Node> children = <Node>[
      for (int i = 0; i < 20; i++) paragraphNode(text: '长' * 300),
      for (int i = 0; i < 300; i++) paragraphNode(text: '短 $i'),
    ];
    final String content = NoteDocumentAdapter.storedContentFromDocument(
      Document(root: pageNode(children: children)),
    );

    final _FakeNotes notes = _FakeNotes(<Note>[_note(content: content)]);
    await _pumpView(tester, notes);

    final ScrollPosition pos = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(AppFlowyEditor),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;

    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    final Offset center = tester.getCenter(find.byType(AppFlowyEditor));
    await tester.sendEventToBinding(mouse.hover(center));
    await tester.pump();

    final double first = pos.maxScrollExtent - pos.minScrollExtent;
    final double viewport = pos.viewportDimension;
    double lo = first;
    double hi = first;
    final int steps = (first / 400).ceil() + 6;
    for (int i = 0; i <= steps; i++) {
      final double total = pos.maxScrollExtent - pos.minScrollExtent;
      if (total < lo) lo = total;
      if (total > hi) hi = total;
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 400)));
      await tester.pumpAndSettle();
    }

    // 滚到了底部（否则"不变"是空断言）。
    expect(
      pos.pixels,
      greaterThan(pos.maxScrollExtent * 0.8),
      reason: '没滚到底，测不到后段',
    );

    expect(
      hi - lo,
      lessThan(1),
      reason:
          '滚动中总高变了 ${(hi - lo).toStringAsFixed(1)}px（${lo.toStringAsFixed(1)} '
          '~ ${hi.toStringAsFixed(1)}）：说明滚动器仍在按"已布局块的平均高度 × '
          '剩余块数"外推 ⇒ `itemExtentOf` 那条链没接上或不生效 '
          '（查 `BlockHeights.predictor` 与 `EditorScrollController.itemExtentOf`）',
    );
    // 滑块长度全程不动——这才是用户看到的那个现象。
    double thumb(double total) => viewport / (viewport + total) * viewport;
    expect((thumb(lo) - thumb(hi)).abs(), lessThan(0.5));
  });

  testWidgets('点末尾留白 = 继续写（末尾补空段落；已是空段落则不重复加）', (WidgetTester tester) async {
    final _FakeNotes notes = _FakeNotes(<Note>[_note()]);
    await _pumpView(tester, notes);

    final EditorState state = tester
        .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
        .editorState;
    final Finder trailing = find.byKey(
      const ValueKey<String>('editor.trailingArea'),
    );
    expect(trailing, findsOneWidget, reason: '末尾留白热区没上树');

    final int before = state.document.root.children.length;
    await tester.tap(trailing);
    await tester.pumpAndSettle();

    // 末尾是"你好世界"（**非空**段落）⇒ 补一个空段落，光标落到它的行首。
    // 焦点由官方键盘服务随选区要回编辑器（见 `_focusEndOfDocument` 的注释）。
    expect(state.document.root.children.length, before + 1);
    expect(state.selection?.start.path, <int>[before]);
    expect(tester.takeException(), isNull);

    // 末尾已经是空段落 ⇒ 再点**不重复添加**，只把光标放进去。
    await tester.tap(trailing);
    await tester.pumpAndSettle();
    expect(state.document.root.children.length, before + 1);
    expect(state.selection?.start.path, <int>[before]);
  });

  // ─── 撤销 / 重做常驻标题行左侧（2026-09-14，从悬浮栏 group 0 搬出） ───
  //
  // 为什么搬：悬浮栏**只在有选区时出现**，而撤销最常用的时刻是"刚打完字、
  // 光标还停在那儿"——那时按钮够不着（用户实机反馈）。搬出来必须满足两件事：
  // ①**没有选区**也能点；②可用态跟着历史栈走（空则灰显，不假装能点）。
  testWidgets('撤销/重做常驻标题行：没有选区也能用，且随历史栈灰显', (WidgetTester tester) async {
    final _FakeNotes notes = _FakeNotes(<Note>[_note()]);
    await _pumpView(tester, notes);

    final EditorState state = tester
        .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
        .editorState;
    IconButton button(String key) =>
        tester.widget<IconButton>(find.byKey(ValueKey<String>(key)));

    /// 第 0 块里**任一** span 带该属性（与 `fixed_toolbar_test.dart` 的
    /// `_attributeOf` 同口径：加粗只覆盖选区那一段，属性落在切出来的那个 span 上）。
    bool hasAttribute(String key) {
      for (final Object? op
          in state.document.root.children.first.delta?.toJson() ??
              const <Object?>[]) {
        if (op is Map) {
          final Object? attributes = op['attributes'];
          if (attributes is Map && attributes[key] != null) return true;
        }
      }
      return false;
    }

    // 起始：没有任何历史 ⇒ 两个按钮都灰显（`onPressed: null` ⇒ M3 禁用态）。
    expect(button('editor.undo').onPressed, isNull);
    expect(button('editor.redo').onPressed, isNull);

    // 制造一步历史：选中一段 → 加粗（`_expandSelection` 是既有脚手架）。
    await _expandSelection(tester);
    await tester.tap(_toolbarItem('editor.bold'));
    await tester.pumpAndSettle();
    expect(hasAttribute(AppFlowyRichTextKeys.bold), isTrue, reason: '加粗没写进去');
    expect(
      state.undoManager.undoStack.isNonEmpty,
      isTrue,
      reason: '加粗没有留下历史（前置条件不成立，下面那条断言就是空转）',
    );
    // 可用态随**事务**刷新（选区通知盖不住历史栈的变化）。
    expect(button('editor.undo').onPressed, isNotNull, reason: '有历史了却仍灰显');
    expect(button('editor.redo').onPressed, isNull, reason: '没有重做历史却可点');

    // ★ 关键：**清掉选区**之后再撤销——这正是悬浮栏够不着的那个场景。
    state.selection = null;
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('editor.undo')));
    await tester.pumpAndSettle();
    expect(
      hasAttribute(AppFlowyRichTextKeys.bold),
      isFalse,
      reason: '没有选区时撤销没生效（按钮应直接吃 editorState）',
    );
    expect(button('editor.redo').onPressed, isNotNull, reason: '撤销后应可重做');

    await tester.tap(find.byKey(const ValueKey<String>('editor.redo')));
    await tester.pumpAndSettle();
    expect(hasAttribute(AppFlowyRichTextKeys.bold), isTrue, reason: '重做没恢复加粗');

    // 放掉 appflowy 的"历史合并"定时器（否则框架报 pending timer）。
    await tester.pump(const Duration(seconds: 2));
  });

  // ─── 多步重做（2026-09-14，vendored 补丁 12） ───
  //
  // 官方 `UndoManager.redo()` 用 `recordUndo: true` 应用重做事务（它应当成为一条
  // 新的撤销历史），于是也会走 `getUndoHistoryItem()`——而那里有一条
  // "**新的用户编辑**作废重做栈"的规则：
  //
  //   if (undoStack.last.sealed) redoStack.clear();
  //
  // 对"重做自身"显然不该生效 ⇒ 后果是**剩余的重做历史被清空**
  // （用户实测："重做好像只能重做一次"）。
  testWidgets('多步撤销 / 重做：重做要能一路做到头', (WidgetTester tester) async {
    final _FakeNotes notes = _FakeNotes(<Note>[_note()]);
    await _pumpView(tester, notes);

    final EditorState state = tester
        .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
        .editorState;
    String text() => state.document.root.children.first.delta!.toPlainText();

    // 三次真实编辑，各成**一步**历史（每次把 50ms 的"历史合并窗口"等过去，
    // 否则三次编辑会合并成同一个 HistoryItem）。
    for (int i = 0; i < 3; i++) {
      final Node node = state.document.root.children.first;
      unawaited(
        state.apply(
          state.transaction..insertText(node, node.delta!.length, '${i + 1}'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(text(), '你好世界123', reason: '前置：三次编辑没写进去');

    // 全部撤销 ⇒ 回到最初。
    for (int i = 0; i < 3; i++) {
      state.undoManager.undo();
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(text(), '你好世界', reason: '三次撤销没回到最初');

    // 全部重做 ⇒ 必须一路回到 '你好世界123'。
    final List<String> steps = <String>[];
    for (int i = 0; i < 3; i++) {
      state.undoManager.redo();
      await tester.pump(const Duration(milliseconds: 100));
      steps.add(text());
    }
    expect(
      steps,
      <String>['你好世界1', '你好世界12', '你好世界123'],
      reason:
          '重做只做到第 ${steps.length} 步就停住了 —— 剩余的重做历史被清空'
          '（`getUndoHistoryItem` 里那条 redoStack.clear 对"重做自身"也生效了）',
    );

    // 再撤销一遍：重做出来的内容必须能**逐条回退**（历史栈最常见的腐败点：
    // 重做只改内容、不记撤销历史 ⇒ 来回一趟就乱）。
    for (int i = 0; i < 3; i++) {
      state.undoManager.undo();
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(text(), '你好世界', reason: '重做后的内容没进撤销栈（一个来回就对不上了）');
  });

  // ─── 选区刷新防抖的悬垂引用（2026-09-14，vendored 补丁 11） ───
  //
  // 崩溃现场（用户连做几次热重启后报回，**未捕获异步异常**）：
  //   Null check operator used on a null value
  //   #0 _DesktopSelectionServiceWidgetState.didChangeMetrics.<anonymous closure>
  //      (desktop_selection_service.dart:84)
  //   #1 Debounce.debounce.<anonymous closure> (debounce.dart:22)
  //
  // 成因：官方在 `didChangeMetrics` 里判 `currentSelection.value != null` 只是
  // **排定**防抖，真正取值的 `currentSelection.value!` 在 **100ms 后的闭包**里；
  // 中间选区一被清空（`dispose()` → `clearSelection()`，切笔记 / 热重启都会走），
  // 闭包就对着 null 取 `!`。且 `dispose()` **不取消**这个定时器 ⇒ 卸载后照常执行。
  testWidgets('改窗口尺寸后立刻卸载：不留抛异常的选区刷新定时器', (WidgetTester tester) async {
    final _FakeNotes notes = _FakeNotes(<Note>[_note()]);
    await _pumpView(tester, notes);

    // 点正文落光标 —— 官方 `_onTapDown` → `updateSelection` ⇒ 选区非空，
    // 这正是"排定防抖"的前提（前提不成立本用例就是空转）。
    await tester.tap(find.text('你好世界', findRichText: true));
    await tester.pumpAndSettle();
    final EditorState state = tester
        .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
        .editorState;
    expect(state.selection, isNotNull, reason: '点正文没落光标，本用例前提不成立');

    // 窗口尺寸变化（拉窗口 / 热重启都会触发）⇒ 排定 100ms 后的"刷新选区"。
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pump();

    // 没到 100ms 就卸载：`dispose()` 里会 `clearSelection()` 把选区置空。
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);

    // 越过防抖窗口 —— 定时器若没被取消，就会对着已置空的选区取 `!` 抛异常。
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester.takeException(),
      isNull,
      reason: '卸载后仍执行了选区刷新防抖（官方 didChangeMetrics 的悬垂定时器）',
    );
  });

  // （临时探针已删：它量到的是"范围精确 + 视口=编辑区 + 轨道被我方主题内缩"，
  //  结论已落进 `AppTheme.scrollbarTheme` 的注释与 `app_theme_test.dart` 的断言。）

  testWidgets('正文右键：出菜单（此前 contextMenuBuilder 没接 ⇒ 毫无反应）', (
    WidgetTester tester,
  ) async {
    final _FakeNotes notes = _FakeNotes(<Note>[_note()]);
    await _pumpView(tester, notes);

    final Offset? center = _richTextCenterOf(tester, '你好世界');
    expect(center, isNotNull, reason: '没找到正文 RichText');
    await tester.tapAt(center!, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();

    expect(find.text('剪切'), findsOneWidget, reason: '官方链路没调我们的 builder？');
    expect(find.text('粘贴'), findsOneWidget);
    expect(find.text('全选'), findsOneWidget);
    // 面板走浮层令牌（与全场菜单同一族：AppFloatSurface = 三件套容器）。
    expect(
      find.ancestor(
        of: find.text('粘贴'),
        matching: find.byType(AppFloatSurface),
      ),
      findsOneWidget,
      reason: '右键菜单面板没走浮层令牌',
    );

    // 「全选」= 官方命令 handler，与 Ctrl+A 同一实现。
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    final EditorState state = tester
        .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
        .editorState;
    expect(state.selection?.start, Position(path: <int>[0]));
    expect(state.selection?.end.offset, 4, reason: '全选应覆盖"你好世界"四个字');
  });

  testWidgets('页面留白右键：同一个菜单（官方链路不管这片空白）', (WidgetTester tester) async {
    final _FakeNotes notes = _FakeNotes(<Note>[_note()]);
    await _pumpView(tester, notes);

    final Finder trailing = find.byKey(
      const ValueKey<String>('editor.trailingArea'),
    );
    expect(trailing, findsOneWidget, reason: '末尾留白热区没上树');

    await tester.tap(trailing, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('粘贴'), findsOneWidget, reason: '留白右键没弹菜单');
    expect(find.text('全选'), findsOneWidget);

    // 点别处 = 关（遮罩那层）。
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('粘贴'), findsNothing, reason: '菜单没被遮罩关掉');

    // 卸载时必须撤掉 overlay 条目，否则会挂在下一屏上。
    await tester.tap(trailing, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('链接悬浮提示：停在链接上浮出 URL 面板，移开收起', (WidgetTester tester) async {
    final _FakeNotes notes = _FakeNotes(<Note>[
      _note(content: _linkNoteContent()),
    ]);
    await _pumpView(tester, notes);

    final Rect linkRect = _firstLinkRect(tester);

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    // 抖动容忍（用户反馈："不太灵敏，有时候没有"）：指针沿文字走时，总有一两
    // 帧判不到链接（字形边界/跨字符）。旧写法每次判空都把待弹出的计时器清零，
    // 于是"必须一动不动盯满 showDelay"——这里用 3 次短促进出复现：
    // 累计已过 showDelay，但**任何一次停留都没到**。
    await mouse.moveTo(linkRect.center);
    for (int i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 60));
      await mouse.moveTo(Offset(linkRect.right + 60, linkRect.center.dy));
      await tester.pump(const Duration(milliseconds: 20));
      await mouse.moveTo(linkRect.center);
    }
    await tester.pump(const Duration(milliseconds: 40));
    expect(
      find.text('https://example.com/a?b=1'),
      findsOneWidget,
      reason: '抖了几次就不弹了（待弹出的计时器被误清零？）',
    );
    expect(find.text('打开'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    // 面板走浮层令牌（与全场菜单一族）。
    expect(
      find.ancestor(
        of: find.text('打开'),
        matching: find.byType(AppFloatSurface),
      ),
      findsOneWidget,
      reason: '悬浮面板没走浮层令牌',
    );

    // ── 用户实机反馈的回归："无法点击 / 离开内容就消失" ──────────────
    // 面板是根 overlay 里的另一棵子树：指针移过去时，编辑器那层会先收到
    // `onExit`（hover 命中被 overlay 挡），面板再收到 `onEnter`；中间还要
    // 穿过"链接↔面板"那段空隙。三步都必须活下来。
    final Rect panelRect = tester.getRect(
      find.ancestor(
        of: find.text('打开'),
        matching: find.byType(AppFloatSurface),
      ),
    );
    await mouse.moveTo(Offset(panelRect.center.dx, linkRect.bottom + 3)); // 空隙里
    await tester.pump(const Duration(milliseconds: 40));
    await mouse.moveTo(panelRect.center); // 面板上
    await tester.pump(
      LinkHoverTooltip.hideGrace + const Duration(milliseconds: 60),
    );
    expect(
      find.text('打开'),
      findsOneWidget,
      reason: '指针移到面板上后它被收掉了（宽限/命中区那两处退回旧写法了？）',
    );

    // 真的点得到：剪贴板走平台通道，测试里给个假 handler 收掉那次调用。
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(
      AppFlowyClipboard.lastText,
      'https://example.com/a?b=1',
      reason: '「复制」没把链接写进剪贴板（按钮没点着？）',
    );
    expect(find.text('打开'), findsNothing, reason: '点完应该收起');

    // 再悬停一次，移开编辑器 ⇒ 宽限后收起。
    await mouse.moveTo(linkRect.center);
    await tester.pump(
      LinkHoverTooltip.showDelay + const Duration(milliseconds: 50),
    );
    expect(find.text('打开'), findsOneWidget);
    await mouse.moveTo(const Offset(5, 5));
    await tester.pump(
      LinkHoverTooltip.hideGrace + const Duration(milliseconds: 60),
    );
    expect(find.text('打开'), findsNothing, reason: '移开后没收起');
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击链接：只弹链接编辑菜单，不再连带浮动工具栏', (WidgetTester tester) async {
    final _FakeNotes notes = _FakeNotes(<Note>[
      _note(content: _linkNoteContent()),
    ]);
    await _pumpView(tester, notes);

    await tester.tapAt(_firstLinkRect(tester).center);
    // 官方用 200ms 与双击区分，再等一帧给它的 postFrame 回调。
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pumpAndSettle();

    expect(
      find.text('https://example.com/a?b=1'),
      findsOneWidget,
      reason: '链接编辑菜单没弹（前置不成立，下面那条断言就是空转）',
    );
    // 浮动工具栏是跟着**选区**自己冒出来的：官方那次选链接没带"禁用工具栏"
    // 标记 ⇒ 两个浮层叠一起（补丁 15 修的正是这条）。
    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            (widget.key?.toString() ?? '').contains('floating_toolbar_item_'),
      ),
      findsNothing,
      reason: '浮动工具栏不该跟着弹（与链接编辑菜单叠在一起）',
    );
  });

  testWidgets('反复点格式按钮不撑高块（手柄对齐不累积，2026-09-15 实测 bug）', (
    WidgetTester tester,
  ) async {
    // 历史 bug：`_SinanBlockHandle._alignToFirstLine` 的手柄基准 Y 漏加了
    // 已生效的 `Padding(top: _top)`（RenderPadding 原点不含自己的内边距），
    // 每次事务（加粗/斜体等改 delta 的操作都会触发对齐）就把补偿再叠一遍，
    // 块高 34 → 35 → 43 → 51 → 58 一路涨、手柄一路往下走。
    final _FakeNotes notes = _FakeNotes(<Note>[_note()]);
    await _pumpView(tester, notes);
    await _expandSelection(tester);

    // 块高 = 「你好世界」RichText 祖先链上的最大 render box 高度
    // （手柄行 Row 是其中一层，累积 bug 就发生在这一层）。
    double blockHeight() {
      for (final Element e in find.byType(official.RichText).evaluate()) {
        final official.RichText rich = e.widget as official.RichText;
        if (!rich.text.toPlainText().contains('你好世界')) continue;
        double maxH = 0;
        final RenderBox self = e.renderObject! as RenderBox;
        if (self.hasSize) maxH = self.size.height;
        e.visitAncestorElements((Element ancestor) {
          final RenderObject? ro = ancestor.renderObject;
          if (ro is RenderBox && ro.hasSize && ro.size.height > maxH) {
            maxH = ro.size.height;
          }
          return true; // 走到根；祖先数量有限，开销可忽略
        });
        return maxH;
      }
      throw StateError('rich text not found');
    }

    final double before = blockHeight();
    for (int i = 1; i <= 4; i++) {
      await tester.tap(_toolbarItem('editor.bold'));
      await tester.pumpAndSettle();
    }
    await tester.tap(_toolbarItem('editor.underline'));
    await tester.pumpAndSettle();

    expect(blockHeight(), before, reason: '反复点格式按钮后块被撑高——手柄对齐在累积（见用例头注释）');
  });
}

/// 含链接的笔记内容：一个段落，前两个字带 `href`（block tree 路径，
/// 与 [_longNoteContent] 同法——绕开存量 Delta 的有损读入）。
String _linkNoteContent() => NoteDocumentAdapter.storedContentFromDocument(
  Document(
    root: pageNode(
      children: <Node>[
        paragraphNode(
          delta: Delta()
            ..insert(
              '官网',
              attributes: <String, dynamic>{
                AppFlowyRichTextKeys.href: 'https://example.com/a?b=1',
              },
            ),
        ),
      ],
    ),
  ),
);

/// 首块里链接段的**字形矩形**（全局坐标）。
///
/// 与生产同一套算法：`getRectsInSelection(+base)` → `transformRectToGlobal(+base)`
/// ——少做第二步的话矩形差一个编辑器原点，悬停/点击都判不中。
Rect _firstLinkRect(WidgetTester tester) {
  final EditorState state = tester
      .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
      .editorState;
  final Node node = state.document.root.children.first;
  final SelectableMixin selectable = node.selectable!;
  return selectable
      .getRectsInSelection(
        Selection.single(path: node.path, startOffset: 0, endOffset: 2),
        shiftWithBaseOffset: true,
      )
      .map(
        (Rect rect) =>
            selectable.transformRectToGlobal(rect, shiftWithBaseOffset: true),
      )
      .first;
}

/// 含 [needle] 的那段正文 RichText 的屏幕中心（右键点它 = 点在文本节点上）。
Offset? _richTextCenterOf(WidgetTester tester, String needle) {
  for (final Element e in find.byType(official.RichText).evaluate()) {
    final official.RichText rich = e.widget as official.RichText;
    if (!rich.text.toPlainText().contains(needle)) continue;
    final RenderBox box = e.renderObject! as RenderBox;
    if (!box.hasSize) continue;
    return box.localToGlobal(box.size.center(Offset.zero));
  }
  return null;
}

// ─────────────────────────── 脚手架 ───────────────────────────

const String _kDelta = '{"ops":[{"insert":"你好世界"},{"insert":"\\n"}]}';

/// 长文档：[sections] 组「H2 标题 + 段落」。够长（150 节 ≈ 8000px）时，
/// 跳到最后一条必然远到需要官方 `scrollTo` 的双列表交叉淡入——那是
/// GlobalKey 冲突的高危路径。
String _longNoteContent({int sections = 40}) {
  final List<Node> children = <Node>[];
  for (int i = 1; i <= sections; i++) {
    children.add(headingNode(level: 2, text: '第 $i 节'));
    children.add(paragraphNode(text: '正文 $i'));
  }
  return NoteDocumentAdapter.storedContentFromDocument(
    Document(root: pageNode(children: children)),
  );
}

Note _note({String? content}) => Note(
  id: 'n1',
  kind: NoteKind.note,
  title: '标题',
  content: content ?? _kDelta,
  plainText: '你好世界',
  summary: '你好世界',
  contentHash: 'h',
  createdAt: DateTime(2026),
  revisedAt: DateTime(2026),
);

/// 装载视图：先把笔记列表"加载完"再上树——与真实路径一致（用户是从列表
/// 里点进来的，视图 read 时列表必然已有值）。
/// 装载视图，并把本次装载用的**退出前落盘登记处**交回给用例（关窗口路径要用它）。
///
/// 返回值只在测退出路径的用例里被用上；其余用例忽略即可（Dart 允许丢弃返回值，
/// 所以加这个返回值没有惊动任何既有用例）。
Future<PendingSaves> _pumpView(WidgetTester tester, _FakeNotes notes) async {
  // 2026-09-12 起编辑器正文按 id 从存储**单行**取（列表快照不带 content），
  // 故脚手架需要一个真的 NoteStore——用内存 sqlite + restore 灌入假数据，
  // 依旧不碰文件系统。
  final Database db = sqlite3.openInMemory();
  // ignore: deprecated_member_use
  addTearDown(db.dispose);
  // 用生产迁移建同一份 schema（单一来源，见 AppDatabase 的测试口子）。
  AppDatabase.migrateForTesting(db);
  final NoteStore store = NoteStore(db);
  for (final Note note in notes.notes) {
    await store.restore(note);
  }

  final PendingSaves saves = PendingSaves();
  final ProviderContainer container = ProviderContainer(
    // 类型由参数推断：Riverpod 3 未公开导出 `Override` 类型名。
    overrides: [
      notesProvider.overrideWith(() => notes),
      settingsProvider.overrideWith(_FakeSettings.new),
      noteStoreProvider.overrideWithValue(store),
      pendingSavesProvider.overrideWithValue(saves),
    ],
  );
  addTearDown(container.dispose);
  await container.read(notesProvider.future);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(),
        // 与 main.dart 同构：官方本地化委托 + appflowy 委托。
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          ...GlobalMaterialLocalizations.delegates,
          AppFlowyEditorLocalizations.delegate,
        ],
        supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
        builder: (BuildContext context, Widget? child) =>
            // appflowy 内部 import 官方 material，必须过桥才能读到我们的主题。
            // ignore: deprecated_member_use
            MaterialUiCompatibilityBridge(child: child!),
        home: const Scaffold(body: NoteEditorViewAppFlowy(noteId: 'n1')),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return saves;
}

/// 编辑器内部是否出现了"落点高亮"（带底色的块装饰）。
///
/// ⚠️ 类型必须是 material_ui 这一份：包装器是我们自己的代码
/// （`_flashWrapper`），官方内部那些 `AnimatedContainer` 是官方 material 的
/// 同名不同类型，`find.byType` 不会命中它们。
bool _hasFlashingBlock(WidgetTester tester) => tester
    .widgetList<AnimatedContainer>(
      find.descendant(
        of: find.byType(AppFlowyEditor),
        matching: find.byType(AnimatedContainer),
      ),
    )
    .any((AnimatedContainer c) {
      final Decoration? d = c.decoration;
      return d is BoxDecoration && d.color != null;
    });

/// 目录里某条目的行底色（激活态 = `AppTheme.navSelectedTint`，见 toc_panel 的
/// `_itemOf`：条目 Container 的 decoration）。
Color? _tocRowTint(WidgetTester tester, String label) {
  final Finder container = find
      .ancestor(
        of: find.descendant(
          of: find.byType(AppFlowyTocPanel),
          matching: find.text(label),
        ),
        matching: find.byType(Container),
      )
      .first;
  return (tester.widget<Container>(container).decoration as BoxDecoration?)
      ?.color;
}

/// 编辑器滚动列表当前的像素偏移（主列表的 `Scrollable` 就是 `AppFlowyEditor`
/// 子树里的第一个——官方 `ScrollablePositionedList` 内部的
/// `UnboundedCustomScrollView`）。
double _editorOffset(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byType(AppFlowyEditor),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position
    .pixels;

/// 把光标拖成一段**扩展选区**：浮动工具栏（2026-09-12 起）只在扩展选区时
/// 挂载条目，点工具栏的用例都得先走这一步。直接操作从树上取到的
/// `EditorState`——widget 测试里键盘事件路由不到编辑器（见
/// fixed_toolbar_test.dart 的说明），手势模拟又脆， setter 是官方公开口子。
Future<void> _expandSelection(WidgetTester tester) async {
  final EditorState state = tester
      .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
      .editorState;
  state.selection = Selection.collapsed(Position(path: <int>[0]));
  state.selection = Selection(
    start: Position(path: <int>[0]),
    end: Position(path: <int>[0], offset: 2),
  );
  // 浮动栏显示带 200ms debounce（官方为省 rect 计算），settle 掉。
  await tester.pumpAndSettle();
}

/// 浮动栏条目的 finder（key = `appflowy_editor_floating_toolbar_item_<id>_<index>`，
/// index 随分组分隔线浮动，按 id 前缀匹配）。
Finder _toolbarItem(String itemId) => find.byWidgetPredicate(
  (Widget widget) =>
      (widget.key?.toString() ?? '').contains('floating_toolbar_item_$itemId'),
);

/// 渲染树上是否出现了某段纯文本（appflowy 用官方 RichText 渲染正文）。
bool _renders(WidgetTester tester, String needle) {
  for (final Widget widget in tester.allWidgets) {
    if (widget is official.RichText) {
      if (widget.text.toPlainText().contains(needle)) return true;
    } else if (widget is official.Text) {
      final String text = widget.data ?? widget.textSpan?.toPlainText() ?? '';
      if (text.contains(needle)) return true;
    }
  }
  return false;
}

/// 假的笔记 notifier：只记账，不落库（`NotesNotifier` 的 `_store` 一次都不会被读到）。
class _FakeNotes extends NotesNotifier {
  _FakeNotes(this.notes);

  final List<Note> notes;

  // 记账字段：这是**测试替身**，不是对外 API，所以不该走 `state`——riverpod_lint
  // 的 `avoid_public_notifier_properties` 会给它们报 info。
  //
  // ⚠️ 用 `@visibleForTesting` 豁免而不是 `// ignore:`：规则源码里，
  // `isVisibleOutsideTheNotifier` 明确把**带该注解**的成员视为"对外不可见"
  // 而跳过（同样被认可的还有 `@protected` / `@visibleForOverriding`）。
  // 这是官方留下的正路，比压告警更经得起来日重构。
  @visibleForTesting
  String? savedContent;
  @visibleForTesting
  String? savedTitle;
  @visibleForTesting
  String? savedPlainText;

  @override
  Future<List<Note>> build() async => notes;

  @override
  Future<void> saveContent(
    String id,
    String content, {
    required String plainText,
  }) async {
    savedContent = content;
    savedPlainText = plainText;
  }

  @override
  Future<void> saveTitle(String id, String title) async {
    savedTitle = title;
  }
}

/// 假的设置 notifier：默认设置，同样避开 settingsStore。
class _FakeSettings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}
